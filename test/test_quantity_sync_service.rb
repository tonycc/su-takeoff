require_relative 'test_helper'
require 'tmpdir'
require 'src/component_mapping'
require 'src/takeoff_policy'
require 'src/calculator'

class TestQuantitySyncService < Minitest::Test
  class Binding
    attr_accessor :project_code, :project_name, :model_key
    attr_reader :synced

    def initialize
      @project_code = 'XM-001'
      @project_name = '样板房'
      @model_key = 'model-uuid'
      @synced = []
    end

    def ensure_model_key!
      @model_key
    end

    def mark_synced!(payload_hash:, idempotency_key:, sheet_id:, model_version_id:)
      @synced << {
        payload_hash: payload_hash,
        idempotency_key: idempotency_key,
        sheet_id: sheet_id,
        model_version_id: model_version_id
      }
    end
  end

  class Auth
    attr_reader :tokens_used

    def initialize(token: 'access-token')
      @token = token
      @tokens_used = []
    end

    def with_access_token_retry
      @tokens_used << @token
      yield @token
    end
  end

  class Client
    attr_reader :calls

    def initialize(*responses)
      @responses = responses
      @calls = []
    end

    def push_quantities(payload:, access_token:)
      @calls << { payload: payload, access_token: access_token }
      response = @responses.shift
      raise response if response.is_a?(Exception)

      response
    end
  end

  def setup
    @component_mapping = SuTakeoff::ComponentMapping.new
    @policy = SuTakeoff::TakeoffPolicy.new
    @binding = Binding.new
  end

  def item
    SuTakeoff::ScanItem.face(
      face_id: 1,
      face_persistent_id: 101,
      su_material: 'paint',
      area: 10.0,
      normal: [0, 0, 1],
      width: 2.0,
      height: 5.0,
      layer_name: '墙面',
      component_path: [],
      component_path_ids: []
    )
  end

  def service(client:, outbox:, auth: Auth.new, retry_delays: [])
    SuTakeoff::Api::QuantitySyncService.new(
      api_client: client,
      auth_session: auth,
      outbox: outbox,
      binding: @binding,
      component_mapping: @component_mapping,
      policy: @policy,
      retry_delays: retry_delays,
      sleeper: ->(_seconds) {}
    )
  end

  def builder_result
    SuTakeoff::Api::QuantityPayloadBuilder.new(
      items: [item],
      openings: [],
      component_mapping: @component_mapping,
      policy: @policy,
      binding: @binding
    ).build
  end

  def test_success_push_marks_binding_and_clears_outbox
    Dir.mktmpdir do |dir|
      outbox = SuTakeoff::Api::SyncOutbox.new(dir: dir)
      client = Client.new({ 'sheet_id' => 'sheet-1', 'model_version_id' => 'version-1' })
      sync = service(client: client, outbox: outbox)

      result = sync.push(items: [item], openings: [])

      assert result.success?
      assert_equal 1, client.calls.size
      assert_equal 'access-token', client.calls.first[:access_token]
      assert_equal 'sheet-1', @binding.synced.first[:sheet_id]
      assert_equal 'version-1', @binding.synced.first[:model_version_id]
      assert_empty outbox.all
    end
  end

  def test_validation_failure_does_not_call_api_or_write_outbox
    Dir.mktmpdir do |dir|
      @binding.project_code = ''
      outbox = SuTakeoff::Api::SyncOutbox.new(dir: dir)
      client = Client.new
      sync = service(client: client, outbox: outbox)

      result = sync.push(items: [item], openings: [])

      refute result.success?
      assert_includes result.issues.map { |i| i[:code] }, :missing_project_code
      assert_empty client.calls
      assert_empty outbox.all
    end
  end

  def test_retryable_error_retries_then_succeeds
    Dir.mktmpdir do |dir|
      outbox = SuTakeoff::Api::SyncOutbox.new(dir: dir)
      error = SuTakeoff::Api::ApiError.new('rate limited', status: 429, code: 'RATE_LIMITED', retryable: true)
      client = Client.new(error, { 'sheet_id' => 'sheet-1', 'model_version_id' => 'version-1' })
      sync = service(client: client, outbox: outbox, retry_delays: [0])

      result = sync.push(items: [item], openings: [])

      assert result.success?
      assert_equal 2, client.calls.size
      assert_empty outbox.all
    end
  end

  def test_final_failure_is_written_to_outbox
    Dir.mktmpdir do |dir|
      outbox = SuTakeoff::Api::SyncOutbox.new(dir: dir)
      error = SuTakeoff::Api::ApiError.new('server down', status: 500, code: 'HTTP_500', retryable: true)
      client = Client.new(error, error)
      sync = service(client: client, outbox: outbox, retry_delays: [0])

      result = sync.push(items: [item], openings: [])

      refute result.success?
      assert_equal 2, result.attempts
      assert_equal 'HTTP_500', result.error.code
      records = outbox.all
      assert_equal 1, records.size
      assert_equal result.payload[:idempotency_key], records.first['idempotency_key']
      assert_equal 'HTTP_500', records.first['error_code']
    end
  end

  def test_non_retryable_error_is_not_retried_but_is_stored
    Dir.mktmpdir do |dir|
      outbox = SuTakeoff::Api::SyncOutbox.new(dir: dir)
      error = SuTakeoff::Api::ApiError.new('invalid payload', status: 422, code: 'INVALID_QUANTITY_PAYLOAD', retryable: false)
      client = Client.new(error)
      sync = service(client: client, outbox: outbox, retry_delays: [0, 0])

      result = sync.push(items: [item], openings: [])

      refute result.success?
      assert_equal 1, client.calls.size
      assert_equal 1, outbox.all.size
    end
  end

  def test_busy_guard_prevents_concurrent_push
    Dir.mktmpdir do |dir|
      outbox = SuTakeoff::Api::SyncOutbox.new(dir: dir)
      client = Client.new({ 'sheet_id' => 'sheet-1', 'model_version_id' => 'version-1' })
      sync = service(client: client, outbox: outbox)
      sync.instance_variable_set(:@busy, true)

      error = assert_raises(SuTakeoff::Api::ApiError) do
        sync.push(items: [item], openings: [])
      end

      assert_equal 'SYNC_BUSY', error.code
    end
  end

  def test_push_built_can_skip_binding_persistence_for_background_thread
    Dir.mktmpdir do |dir|
      outbox = SuTakeoff::Api::SyncOutbox.new(dir: dir)
      client = Client.new({ 'sheet_id' => 'sheet-1', 'model_version_id' => 'version-1' })
      sync = SuTakeoff::Api::QuantitySyncService.new(
        api_client: client,
        auth_session: Auth.new,
        outbox: outbox,
        binding: @binding,
        component_mapping: @component_mapping,
        policy: @policy,
        retry_delays: [],
        sleeper: ->(_seconds) {},
        persist_success: false
      )

      result = sync.push_built(builder_result)

      assert result.success?
      assert_empty @binding.synced
    end
  end
end
