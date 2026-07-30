# src/api/project_binding.rb
require 'json'
require 'securerandom'
require 'time'

module SuTakeoff
  module Api
    class ProjectBinding
      DICT_NAME = 'su_takeoff_cloud'.freeze
      KEY = 'binding'.freeze

      ATTRIBUTES = %w[
        project_code
        project_name
        model_key
        last_payload_hash
        last_idempotency_key
        last_sheet_id
        last_model_version_id
        last_synced_at
      ].freeze

      attr_reader(*ATTRIBUTES.map(&:to_sym))

      def self.load(model, dict_name: DICT_NAME)
        new(model: model, dict_name: dict_name).tap(&:load!)
      end

      def initialize(model:, dict_name: DICT_NAME, uuid_generator: -> { SecureRandom.uuid },
                     time_source: -> { Time.now })
        @model = model
        @dict_name = dict_name
        @uuid_generator = uuid_generator
        @time_source = time_source
        reset!
      end

      def load!
        data = read_hash
        ATTRIBUTES.each do |key|
          instance_variable_set("@#{key}", data[key])
        end
        missing_model_key = @model_key.nil? || @model_key.to_s.empty?
        ensure_model_key!
        save! if missing_model_key
        self
      end

      def update_project!(project_code:, project_name:)
        @project_code = project_code.to_s.strip
        @project_name = project_name.to_s.strip
        save!
      end

      def mark_synced!(payload_hash:, idempotency_key:, sheet_id:, model_version_id:)
        @last_payload_hash = payload_hash
        @last_idempotency_key = idempotency_key
        @last_sheet_id = sheet_id
        @last_model_version_id = model_version_id
        @last_synced_at = @time_source.call.iso8601
        save!
      end

      def ensure_model_key!
        @model_key = @uuid_generator.call if @model_key.nil? || @model_key.to_s.empty?
        @model_key
      end

      def valid_project?
        !@project_code.to_s.strip.empty? && !@project_name.to_s.strip.empty?
      end

      def to_h
        ATTRIBUTES.each_with_object({}) do |key, memo|
          value = public_send(key)
          memo[key] = value unless value.nil?
        end
      end

      def save!
        dict = @model.attribute_dictionary(@dict_name, true)
        dict[KEY] = JSON.generate(to_h)
        self
      end

      private

      def reset!
        ATTRIBUTES.each do |key|
          instance_variable_set("@#{key}", nil)
        end
      end

      def read_hash
        dict = @model.attribute_dictionary(@dict_name, false)
        return {} unless dict && dict[KEY]

        parsed = JSON.parse(dict[KEY])
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end
    end
  end
end
