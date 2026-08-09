require_relative 'test_helper'

class TestProjectBinding < Minitest::Test
  class FakeModel
    def initialize
      @dicts = {}
    end

    def attribute_dictionary(name, create = false)
      return @dicts[name] if @dicts.key?(name)
      return nil unless create

      @dicts[name] = {}
    end
  end

  def test_load_generates_and_persists_model_key
    model = FakeModel.new
    binding = SuTakeoff::Api::ProjectBinding.new(
      model: model,
      uuid_generator: -> { 'model-uuid' }
    )

    binding.load!

    assert_equal 'model-uuid', binding.model_key
    saved = JSON.parse(model.attribute_dictionary('su_takeoff_cloud')['binding'])
    assert_equal 'model-uuid', saved['model_key']
  end

  def test_load_reuses_persisted_model_key
    model = FakeModel.new
    calls = 0
    generator = -> {
      calls += 1
      "model-uuid-#{calls}"
    }

    first = SuTakeoff::Api::ProjectBinding.new(model: model, uuid_generator: generator)
    first.load!
    second = SuTakeoff::Api::ProjectBinding.new(model: model, uuid_generator: generator)
    second.load!

    assert_equal 'model-uuid-1', first.model_key
    assert_equal 'model-uuid-1', second.model_key
    assert_equal 1, calls
  end

  def test_project_and_sync_result_roundtrip
    model = FakeModel.new
    binding = SuTakeoff::Api::ProjectBinding.new(
      model: model,
      uuid_generator: -> { 'model-uuid' },
      time_source: -> { Time.new(2026, 7, 27, 10, 30, 0, '+08:00') }
    )

    binding.load!
    binding.update_project!(project_id: ' project-1 ', project_code: ' XM-001 ', project_name: ' 样板房 ')
    binding.mark_synced!(
      payload_hash: 'hash',
      idempotency_key: 'su-v2-model-uuid-hash',
      sheet_id: 'sheet-1',
      model_version_id: 'version-1'
    )

    loaded = SuTakeoff::Api::ProjectBinding.load(model)
    assert_equal 'project-1', loaded.project_id
    assert_equal 'XM-001', loaded.project_code
    assert_equal '样板房', loaded.project_name
    assert_equal 'model-uuid', loaded.model_key
    assert_equal 'sheet-1', loaded.last_sheet_id
    assert_equal 'version-1', loaded.last_model_version_id
    assert_equal '2026-07-27T10:30:00+08:00', loaded.last_synced_at
  end

  def test_invalid_existing_json_is_ignored
    model = FakeModel.new
    model.attribute_dictionary('su_takeoff_cloud', true)['binding'] = '{'
    binding = SuTakeoff::Api::ProjectBinding.new(
      model: model,
      uuid_generator: -> { 'fresh-model-uuid' }
    )

    binding.load!

    assert_equal 'fresh-model-uuid', binding.model_key
    refute binding.valid_project?
  end
end
