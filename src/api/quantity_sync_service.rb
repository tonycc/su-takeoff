# src/api/quantity_sync_service.rb
require_relative 'api_error'
require_relative 'quantity_payload_builder'
require_relative 'sync_outbox'

module SuTakeoff
  module Api
    class QuantitySyncService
      SyncResult = Struct.new(
        :success,
        :payload,
        :payload_hash,
        :issues,
        :response,
        :error,
        :attempts,
        :outbox_record,
        keyword_init: true
      ) do
        def success?
          !!success
        end
      end

      DEFAULT_RETRY_DELAYS = [1, 2, 4].freeze

      def initialize(api_client:, auth_session:, outbox:, binding:, mapping:, component_mapping:,
                     policy:, ignored: [], retry_delays: DEFAULT_RETRY_DELAYS,
                     sleeper: ->(seconds) { sleep(seconds) }, jitter: ->(_attempt) { 0.0 },
                     persist_success: true)
        @api_client = api_client
        @auth_session = auth_session
        @outbox = outbox
        @binding = binding
        @mapping = mapping
        @component_mapping = component_mapping
        @policy = policy
        @ignored = ignored || []
        @retry_delays = retry_delays
        @sleeper = sleeper
        @jitter = jitter
        @persist_success = persist_success
        @busy = false
      end

      def busy?
        @busy
      end

      def push(items:, openings:)
        raise ApiError.new('已有推送任务正在执行', code: 'SYNC_BUSY', retryable: false) if @busy

        @busy = true
        result = build_payload(items, openings)
        return result unless result.issues.empty?

        do_push_built(result)
      ensure
        @busy = false
      end

      def push_built(build_result)
        raise ApiError.new('已有推送任务正在执行', code: 'SYNC_BUSY', retryable: false) if @busy

        @busy = true
        do_push_built(build_result)
      ensure
        @busy = false
      end

      private

      def do_push_built(result)
        attempts = 0
        begin
          attempts += 1
          response = @auth_session.with_access_token_retry do |token|
            @api_client.push_quantities(payload: result.payload, access_token: token)
          end
          mark_success!(result, response) if @persist_success
          @outbox.delete(result.payload[:idempotency_key])
          SyncResult.new(
            success: true,
            payload: result.payload,
            payload_hash: result.payload_hash,
            issues: [],
            response: response,
            attempts: attempts
          )
        rescue ApiError => e
          if e.retryable? && attempts <= @retry_delays.length
            wait_before_retry(attempts)
            retry
          end
          record = save_failure(result, e)
          SyncResult.new(
            success: false,
            payload: result.payload,
            payload_hash: result.payload_hash,
            issues: [],
            error: e,
            attempts: attempts,
            outbox_record: record
          )
        end
      end

      def build_payload(items, openings)
        build = QuantityPayloadBuilder.new(
          items: items,
          openings: openings,
          mapping: @mapping,
          component_mapping: @component_mapping,
          policy: @policy,
          binding: @binding,
          ignored: @ignored
        ).build

        return build if build.issues.empty?

        SyncResult.new(
          success: false,
          payload: build.payload,
          payload_hash: build.payload_hash,
          issues: build.issues,
          attempts: 0
        )
      end

      def wait_before_retry(attempts)
        delay = @retry_delays[attempts - 1].to_f + @jitter.call(attempts).to_f
        @sleeper.call(delay) if delay.positive?
      end

      def mark_success!(build, response)
        @binding.mark_synced!(
          payload_hash: build.payload_hash,
          idempotency_key: build.payload[:idempotency_key],
          sheet_id: response && response['sheet_id'],
          model_version_id: response && response['model_version_id']
        )
      end

      def save_failure(build, error)
        @outbox.upsert(
          idempotency_key: build.payload[:idempotency_key],
          payload: build.payload,
          payload_hash: build.payload_hash,
          error_code: error.code,
          error_message: error.message
        )
      end
    end
  end
end
