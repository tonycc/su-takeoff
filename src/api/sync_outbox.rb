# src/api/sync_outbox.rb
require 'digest'
require 'fileutils'
require 'json'
require 'time'

module SuTakeoff
  module Api
    class SyncOutbox
      DEFAULT_MAX_RECORDS = 50
      DEFAULT_MAX_BYTES = 10 * 1024 * 1024

      attr_reader :dir

      def initialize(dir:, max_records: DEFAULT_MAX_RECORDS, max_bytes: DEFAULT_MAX_BYTES,
                     time_source: -> { Time.now })
        @dir = dir
        @max_records = max_records
        @max_bytes = max_bytes
        @time_source = time_source
        FileUtils.mkdir_p(@dir)
      end

      def upsert(idempotency_key:, payload:, payload_hash:, error_code:, error_message:)
        record = {
          idempotency_key: idempotency_key,
          payload_hash: payload_hash,
          payload: payload,
          error_code: error_code,
          error_message: error_message.to_s,
          updated_at: @time_source.call.iso8601
        }
        record[:created_at] = existing(idempotency_key)&.fetch('created_at', nil) || record[:updated_at]
        write_record(record)
        enforce_limits!
        record
      end

      def delete(idempotency_key)
        FileUtils.rm_f(record_path(idempotency_key))
        true
      end

      def all
        record_paths.map { |path| read_record(path) }.compact.sort_by { |r| r['updated_at'].to_s }
      end

      def find(idempotency_key)
        read_record(record_path(idempotency_key))
      end

      private

      def existing(idempotency_key)
        find(idempotency_key)
      end

      def write_record(record)
        File.write(record_path(record[:idempotency_key]), JSON.pretty_generate(record))
      end

      def read_record(path)
        return nil unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        nil
      end

      def record_path(idempotency_key)
        File.join(@dir, "#{Digest::SHA256.hexdigest(idempotency_key.to_s)}.json")
      end

      def record_paths
        Dir.glob(File.join(@dir, '*.json'))
      end

      def enforce_limits!
        paths = record_paths.sort_by { |path| File.mtime(path) }
        while paths.length > @max_records
          FileUtils.rm_f(paths.shift)
        end

        while total_bytes(paths) > @max_bytes && paths.length > 1
          FileUtils.rm_f(paths.shift)
        end
      end

      def total_bytes(paths)
        paths.select { |p| File.exist?(p) }.sum { |p| File.size(p) }
      end
    end
  end
end
