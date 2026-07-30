require_relative 'test_helper'
require 'src/mapping'
require 'src/component_mapping'
require 'src/takeoff_policy'
require 'src/calculator'

class TestQuantityPayloadBuilder < Minitest::Test
  def setup
    @mapping = SuTakeoff::MaterialMapping.new
    @component_mapping = SuTakeoff::ComponentMapping.new
    @policy = SuTakeoff::TakeoffPolicy.new(mapping: @mapping)
    @binding = Struct.new(
      :project_code,
      :project_name,
      :model_key,
      keyword_init: true
    ) do
      def ensure_model_key!
        self.model_key ||= 'model-uuid'
      end
    end.new(project_code: 'XM-001', project_name: '样板房', model_key: 'model-uuid')
  end

  def build(items, openings = [])
    SuTakeoff::Api::QuantityPayloadBuilder.new(
      items: items,
      openings: openings,
      mapping: @mapping,
      component_mapping: @component_mapping,
      policy: @policy,
      binding: @binding
    ).build
  end

  def test_builds_area_face_payload_with_opening_deduction
    @mapping.add('paint', '乳胶漆', '涂料', 'm²', '', 0.0, 'paint')
    item = SuTakeoff::ScanItem.face(
      face_id: 1,
      face_persistent_id: 101,
      su_material: 'paint',
      area: 10.0,
      normal: [0, 0, 1],
      width: 2.0,
      height: 5.0,
      layer_name: '墙面',
      component_path: ['客厅'],
      component_path_ids: [10],
      component_path_persistent_ids: [1001]
    )
    opening = SuTakeoff::Opening.new(9, 1.25, [1])

    result = build([item], [opening])

    assert_empty result.issues
    payload = result.payload
    assert_equal 2, payload[:protocol_version]
    assert_equal 'XM-001', payload[:project][:code]
    assert_match(/\Asu-v2-model-uuid-[a-f0-9]{16}\z/, payload[:idempotency_key])
    component = payload[:components].first
    assert_equal 'component_instance', component[:component_type]
    assert_equal 1, component[:faces].size
    assert_equal 'paint', component[:faces].first[:material_tag]
    assert_equal 8.75, component[:faces].first[:area_m2]
    assert_empty component[:parts]
  end

  def test_aggregates_length_items_into_parts
    @mapping.add('skirting', '踢脚线', '线材', 'm', '', 0.0, 'skirting')
    a = SuTakeoff::ScanItem.linear_solid(
      face_id: 1,
      face_persistent_id: 101,
      su_material: 'skirting',
      length: 2.5,
      layer_name: '线材',
      component_path: ['卧室'],
      component_path_ids: [10],
      component_path_persistent_ids: [1001]
    )
    b = SuTakeoff::ScanItem.linear_solid(
      face_id: 2,
      face_persistent_id: 102,
      su_material: 'skirting',
      length: 3.0,
      layer_name: '线材',
      component_path: ['卧室'],
      component_path_ids: [10],
      component_path_persistent_ids: [1001]
    )

    result = build([a, b])

    assert_empty result.issues
    part = result.payload[:components].first[:parts].first
    assert_equal '踢脚线', part[:name]
    assert_equal 5.5, part[:quantity]
    assert_equal 'm', part[:unit]
    assert_equal 'skirting', part[:material_tag]
  end

  def test_missing_platform_material_tag_is_reported
    @mapping.add('paint', '乳胶漆', '涂料', 'm²')
    item = SuTakeoff::ScanItem.face(
      face_id: 1,
      su_material: 'paint',
      area: 10.0,
      normal: [0, 0, 1],
      width: 2.0,
      height: 5.0,
      layer_name: '墙面',
      component_path: [],
      component_path_ids: []
    )

    result = build([item])

    assert_equal [:missing_platform_material_tag, :empty_payload], result.issues.map { |i| i[:code] }
    assert_empty result.payload[:components]
  end

  def test_same_input_produces_same_hash_and_idempotency_key
    @mapping.add('paint', '乳胶漆', '涂料', 'm²', '', 0.0, 'paint')
    item = SuTakeoff::ScanItem.face(
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

    first = build([item])
    second = build([item])

    assert_equal first.payload_hash, second.payload_hash
    assert_equal first.payload[:idempotency_key], second.payload[:idempotency_key]
  end

  def test_source_version_within_server_limit_and_stable
    @mapping.add('paint', '乳胶漆', '涂料', 'm²', '', 0.0, 'paint')
    item = SuTakeoff::ScanItem.face(
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

    first = build([item])
    second = build([item])

    # 服务端 source_version 字段上限为 64 字符（联调实测 len=64→200, len=65→500）。
    # 超限会触发服务端未捕获异常返回 500，必须截断。
    assert_operator first.payload[:source_version].length, :<=, 64,
                    "source_version 超过服务端 64 字符上限：#{first.payload[:source_version]}"
    # 内容派生且稳定：相同输入产生相同 source_version
    assert_equal first.payload[:source_version], second.payload[:source_version]
    assert_match(/\Asha256:[a-f0-9]+\z/, first.payload[:source_version])
  end
end
