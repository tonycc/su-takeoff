require_relative 'test_helper'
require 'tmpdir'

class TestSyncOutbox < Minitest::Test
  def test_upsert_replaces_same_idempotency_key
    Dir.mktmpdir do |dir|
      outbox = SuTakeoff::Api::SyncOutbox.new(
        dir: dir,
        time_source: -> { Time.new(2026, 7, 27, 10, 0, 0, '+08:00') }
      )

      outbox.upsert(
        idempotency_key: 'same-key',
        payload: { idempotency_key: 'same-key', components: [] },
        payload_hash: 'hash-1',
        error_code: 'NETWORK_ERROR',
        error_message: 'first'
      )
      outbox.upsert(
        idempotency_key: 'same-key',
        payload: { idempotency_key: 'same-key', components: [] },
        payload_hash: 'hash-2',
        error_code: 'HTTP_500',
        error_message: 'second'
      )

      records = outbox.all
      assert_equal 1, records.size
      assert_equal 'hash-2', records.first['payload_hash']
      assert_equal 'HTTP_500', records.first['error_code']
    end
  end

  def test_delete_removes_record
    Dir.mktmpdir do |dir|
      outbox = SuTakeoff::Api::SyncOutbox.new(dir: dir)
      outbox.upsert(
        idempotency_key: 'key',
        payload: { idempotency_key: 'key' },
        payload_hash: 'hash',
        error_code: 'NETWORK_ERROR',
        error_message: 'failed'
      )

      assert outbox.find('key')
      outbox.delete('key')
      assert_nil outbox.find('key')
    end
  end

  def test_max_record_limit_drops_oldest_records
    Dir.mktmpdir do |dir|
      index = 0
      outbox = SuTakeoff::Api::SyncOutbox.new(
        dir: dir,
        max_records: 2,
        time_source: -> {
          index += 1
          Time.new(2026, 7, 27, 10, 0, index, '+08:00')
        }
      )

      3.times do |i|
        outbox.upsert(
          idempotency_key: "key-#{i}",
          payload: { idempotency_key: "key-#{i}" },
          payload_hash: "hash-#{i}",
          error_code: 'NETWORK_ERROR',
          error_message: 'failed'
        )
      end

      assert_equal 2, outbox.all.size
      assert_nil outbox.find('key-0')
    end
  end
end
