require_relative 'test_helper'
require 'src/component_sku_mapping'
require 'src/takeoff_policy'
require 'src/calculator'

class TestQuantityPayloadBuilder < Minitest::Test
  def setup
    @policy = SuTakeoff::TakeoffPolicy.new
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

  def build(items, openings = [], component_sku: nil, hierarchy: nil, model_version_no: nil,
            update_content: nil, visible_component_paths: nil, designer_account: nil)
    SuTakeoff::Api::QuantityPayloadBuilder.new(
      items: items,
      openings: openings,
      policy: @policy,
      binding: @binding,
      component_sku: component_sku,
      hierarchy: hierarchy,
      model_version_no: model_version_no,
      update_content: update_content,
      visible_component_paths: visible_component_paths,
      designer_account: designer_account
    ).build
  end

  def test_builds_area_face_payload_with_opening_deduction
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
    refute component.key?(:faces)
    assert_equal 1, component[:parts].size
    assert_equal 'paint', component[:parts].first[:name]
    assert_equal 8.75, component[:parts].first[:quantity]
    assert_equal 'm2', component[:parts].first[:unit]
    refute component.key?(:project_product_id)
  end

  def test_includes_project_product_id_from_component_definition_mapping
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
    component_sku = SuTakeoff::ComponentSkuMapping.new
    component_sku.set_project_product(
      '橱柜',
      project_product_id: 'project-product-1',
      product_id: 'product-1',
      catalog_code: 'P-001',
      product_name: '白橡木柜体',
      project_product_code: 'XM-P-001'
    )
    hierarchy = {
      entity_id: 0,
      definition_name: nil,
      children: [
        { entity_id: 10, definition_name: '橱柜', children: [] }
      ]
    }

    result = build([item], [], component_sku: component_sku, hierarchy: hierarchy)

    component = result.payload[:components].first
    assert_equal 'project-product-1', component[:project_product_id]
  end

  def test_includes_component_quantity_tag_from_current_component_row
    item = SuTakeoff::ScanItem.face(
      face_id: 1,
      face_persistent_id: 101,
      su_material: '线材',
      area: 0.2,
      normal: [1, 0, 0],
      width: 0.1,
      height: 1.2,
      layer_name: '墙面',
      tags: { method: :length },
      component_path: ['组件A'],
      component_path_ids: [10],
      component_path_persistent_ids: [1001]
    )
    hierarchy = {
      entity_id: 0,
      definition_name: nil,
      children: [
        { entity_id: 10, definition_name: '组件A', tag: '按长度+个数', children: [] }
      ]
    }

    result = build([item], [], hierarchy: hierarchy)

    assert_equal '按长度+个数', result.payload[:components].first[:quantity_tag]
  end

  def test_aggregates_area_faces_into_component_part_without_face_details
    items = [1, 2].map do |face_id|
      SuTakeoff::ScanItem.face(
        face_id: face_id,
        face_persistent_id: 100 + face_id,
        su_material: '瓷砖',
        area: face_id.to_f,
        normal: [0, 0, 1],
        width: 1.0,
        height: face_id.to_f,
        layer_name: '墙面',
        component_path: ['卫生间'],
        component_path_ids: [10],
        component_path_persistent_ids: [1001]
      )
    end

    result = build(items)

    component = result.payload[:components].first
    refute component.key?(:faces)
    assert_equal 1, component[:parts].size
    assert_equal '瓷砖', component[:parts].first[:name]
    assert_equal 3.0, component[:parts].first[:quantity]
    assert_equal 'm2', component[:parts].first[:unit]
  end

  def test_project_product_id_changes_payload_version
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
    hierarchy = {
      entity_id: 0,
      definition_name: nil,
      children: [
        { entity_id: 10, definition_name: '橱柜', children: [] }
      ]
    }
    component_sku = SuTakeoff::ComponentSkuMapping.new
    component_sku.set_project_product(
      '橱柜',
      project_product_id: 'project-product-1',
      product_id: 'product-1',
      catalog_code: 'P-001',
      product_name: '白橡木柜体'
    )

    without_product = build([item])
    with_product = build([item], [], component_sku: component_sku, hierarchy: hierarchy)

    refute_equal without_product.payload_hash, with_product.payload_hash
    refute_equal without_product.payload[:idempotency_key], with_product.payload[:idempotency_key]
  end

  def test_nested_component_uses_deepest_definition_mapping
    item = SuTakeoff::ScanItem.face(
      face_id: 1,
      face_persistent_id: 101,
      su_material: 'paint',
      area: 2.0,
      normal: [0, 0, 1],
      width: 1.0,
      height: 2.0,
      layer_name: '墙面',
      component_path: ['外层', '内层'],
      component_path_ids: [10, 20],
      component_path_persistent_ids: [1001, 2001]
    )
    component_sku = SuTakeoff::ComponentSkuMapping.new
    component_sku.set_project_product(
      '外层',
      project_product_id: 'outer-product',
      product_id: 'product-outer',
      catalog_code: 'OUTER',
      product_name: '外层产品'
    )
    component_sku.set_project_product(
      '内层',
      project_product_id: 'inner-product',
      product_id: 'product-inner',
      catalog_code: 'INNER',
      product_name: '内层产品'
    )
    hierarchy = {
      entity_id: 0,
      definition_name: nil,
      children: [
        {
          entity_id: 10,
          definition_name: '外层',
          children: [{ entity_id: 20, definition_name: '内层', children: [] }]
        }
      ]
    }

    result = build([item], [], component_sku: component_sku, hierarchy: hierarchy)

    assert_equal 'inner-product', result.payload[:components].first[:project_product_id]
  end

  def test_nested_component_falls_back_to_outer_definition_mapping
    item = SuTakeoff::ScanItem.face(
      face_id: 1, face_persistent_id: 101, su_material: 'paint', area: 2.0,
      normal: [0, 0, 1], width: 1.0, height: 2.0, layer_name: '墙面',
      component_path: ['外层', '内层'], component_path_ids: [10, 20],
      component_path_persistent_ids: [1001, 2001]
    )
    component_sku = SuTakeoff::ComponentSkuMapping.new
    component_sku.set_project_product(
      '外层', project_product_id: 'outer-product', product_id: 'product-outer',
      catalog_code: 'OUTER', product_name: '外层产品'
    )
    hierarchy = {
      entity_id: 0, definition_name: nil, children: [{
        entity_id: 10, definition_name: '外层', children: [{
          entity_id: 20, definition_name: nil, children: []
        }]
      }]
    }

    result = build([item], [], component_sku: component_sku, hierarchy: hierarchy)

    assert_equal 'outer-product', result.payload[:components].first[:project_product_id]
  end

  def test_uses_non_empty_fallback_name_for_blank_component_definition
    item = SuTakeoff::ScanItem.face(
      face_id: 1,
      face_persistent_id: 101,
      su_material: 'paint',
      area: 2.0,
      normal: [0, 0, 1],
      width: 1.0,
      height: 2.0,
      layer_name: '墙面',
      component_path: [''],
      component_path_ids: [10],
      component_path_persistent_ids: [1001]
    )

    result = build([item])

    assert_empty result.issues
    assert_equal '未命名组件', result.payload[:components].first[:name]
  end

  def test_aggregates_length_items_into_parts
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
    assert_equal 'skirting', part[:name]
    assert_equal 5.5, part[:quantity]
    assert_equal 'm', part[:unit]
  end

  def test_same_input_produces_same_hash_and_idempotency_key
    item = SuTakeoff::ScanItem.face(
      face_id: 1,
      face_persistent_id: 101,
      su_material: 'paint',
      area: 10.0,
      normal: [0, 0, 1],
      width: 2.0,
      height: 5.0,
      layer_name: '墙面',
      component_path: ['墙面组件'],
      component_path_ids: [10],
      component_path_persistent_ids: [1001]
    )

    first = build([item])
    second = build([item])

    assert_equal first.payload_hash, second.payload_hash
    assert_equal first.payload[:idempotency_key], second.payload[:idempotency_key]
  end

  def test_push_metadata_is_sent_and_generates_a_new_idempotency_key
    first = build([item_for_metadata_test], [], model_version_no: 'V001', update_content: '调整卫生间龙头数量')
    same = build([item_for_metadata_test], [], model_version_no: 'V001', update_content: '调整卫生间龙头数量')
    changed = build([item_for_metadata_test], [], model_version_no: 'V002', update_content: '新增灯具')

    assert_equal 'V001', first.payload[:model_version_no]
    assert_equal '调整卫生间龙头数量', first.payload[:update_content]
    assert_equal first.payload_hash, same.payload_hash
    assert_equal first.payload[:idempotency_key], same.payload[:idempotency_key]
    refute_equal first.payload_hash, changed.payload_hash
    refute_equal first.payload[:idempotency_key], changed.payload[:idempotency_key]
    refute_equal first.payload[:source_version], changed.payload[:source_version]
  end

  def test_designer_account_is_sent_and_participates_in_payload_version
    first = build([item_for_metadata_test], [], designer_account: 'designer@example.com')
    same = build([item_for_metadata_test], [], designer_account: 'designer@example.com')
    changed = build([item_for_metadata_test], [], designer_account: 'another@example.com')

    assert_equal 'designer@example.com', first.payload[:designer_account]
    assert_equal first.payload_hash, same.payload_hash
    assert_equal first.payload[:idempotency_key], same.payload[:idempotency_key]
    refute_equal first.payload_hash, changed.payload_hash
    refute_equal first.payload[:idempotency_key], changed.payload[:idempotency_key]
  end

  def test_source_version_within_server_limit_and_stable
    item = SuTakeoff::ScanItem.face(
      face_id: 1,
      face_persistent_id: 101,
      su_material: 'paint',
      area: 10.0,
      normal: [0, 0, 1],
      width: 2.0,
      height: 5.0,
      layer_name: '墙面',
      component_path: ['墙面组件'],
      component_path_ids: [10],
      component_path_persistent_ids: [1001]
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

  def test_does_not_sync_model_root_items
    root_item = SuTakeoff::ScanItem.face(
      face_id: 1,
      face_persistent_id: 101,
      su_material: 'root-paint',
      area: 10.0,
      normal: [0, 0, 1],
      width: 2.0,
      height: 5.0,
      layer_name: '墙面',
      component_path: [],
      component_path_ids: []
    )
    component_item = SuTakeoff::ScanItem.face(
      face_id: 2,
      face_persistent_id: 102,
      su_material: 'component-paint',
      area: 2.0,
      normal: [0, 0, 1],
      width: 1.0,
      height: 2.0,
      layer_name: '墙面',
      component_path: ['卫生间'],
      component_path_ids: [10],
      component_path_persistent_ids: [1001]
    )

    result = build([root_item, component_item])

    assert_empty result.issues
    assert_equal 1, result.payload[:components].size
    assert_equal '卫生间', result.payload[:components].first[:name]
    refute_equal '模型根', result.payload[:components].first[:name]
    refute result.payload[:components].any? { |component| component[:name] == '模型根' }
  end

  def test_hierarchy_payload_uses_same_component_row_values_as_page
    items = [
      SuTakeoff::ScanItem.face(
        face_id: 1, face_persistent_id: 101, su_material: '墙漆', area: 2.5,
        normal: [0, 0, 1], width: 1.0, height: 2.5, layer_name: '墙面',
        component_path: ['组件A'], component_path_ids: [10],
        component_path_persistent_ids: [1001]
      ),
      SuTakeoff::ScanItem.face(
        face_id: 2, face_persistent_id: 102, su_material: '线材', area: 0.2,
        normal: [1, 0, 0], width: 0.1, height: 1.2, layer_name: '墙面',
        tags: { method: :length },
        component_path: ['组件A'], component_path_ids: [10],
        component_path_persistent_ids: [1001]
      ),
      SuTakeoff::ScanItem.face(
        face_id: 3, face_persistent_id: 103, su_material: '开关', area: 0.3,
        normal: [0, 0, 1], width: 0.5, height: 0.6, layer_name: '墙面',
        tags: { method: :count },
        component_path: ['组件A'], component_path_ids: [10],
        component_path_persistent_ids: [1001]
      )
    ]
    hierarchy = {
      name: '(模型根)', entity_id: 0, kind: 'root', definition_name: nil,
      depth: 0, hidden: false,
      children: [{
        name: '组件A', entity_id: 10, kind: 'component_instance',
        definition_name: '组件A', depth: 1, hidden: false, children: []
      }]
    }
    policy = SuTakeoff::TakeoffPolicy.new(heuristics_enabled: false)
    binding = @binding
    result = SuTakeoff::Api::QuantityPayloadBuilder.new(
      items: items, openings: [], policy: policy, binding: binding, hierarchy: hierarchy
    ).build

    component = result.payload[:components].find { |entry| entry[:name] == '组件A' }
    parts = component[:parts].each_with_object({}) { |part, memo| memo[part[:name]] = part }

    assert_equal 2.5, parts['面积'][:quantity]
    assert_equal 'm2', parts['面积'][:unit]
    assert_equal 1.2, parts['长度'][:quantity]
    assert_equal 'm', parts['长度'][:unit]
    assert_equal 1.0, parts['件数'][:quantity]
    assert_equal '个', parts['件数'][:unit]
    refute result.payload[:components].any? { |entry| entry[:name] == '(模型根)' }
  end

  def test_pushes_visible_empty_component_and_excludes_collapsed_child
    items = [
      SuTakeoff::ScanItem.face(
        face_id: 1, face_persistent_id: 101, su_material: '墙漆', area: 2.5,
        normal: [0, 0, 1], width: 1.0, height: 2.5, layer_name: '墙面',
        component_path: ['父组件', '折叠子组件'], component_path_ids: [10, 20],
        component_path_persistent_ids: [1001, 2001]
      )
    ]
    hierarchy = {
      name: '(模型根)', entity_id: 0, kind: 'root', definition_name: nil,
      depth: 0, hidden: false,
      children: [
        {
          name: '父组件', entity_id: 10, kind: 'group', definition_name: 'Group#1',
          depth: 1, hidden: false,
          children: [{
            name: '折叠子组件', entity_id: 20, kind: 'component_instance',
            definition_name: '折叠子组件', depth: 2, hidden: false, children: []
          }]
        },
        {
          name: '卫-淋浴门框', entity_id: 30, kind: 'component_instance',
          definition_name: '卫-淋浴门框', depth: 1, hidden: false, children: []
        }
      ]
    }

    result = build(
      items,
      [],
      hierarchy: hierarchy,
      visible_component_paths: [[10], [30]]
    )

    components = result.payload[:components]
    assert_equal ['父组件', '卫-淋浴门框'].sort, components.map { |component| component[:name] }.sort
    empty_component = components.find { |component| component[:name] == '卫-淋浴门框' }
    assert_equal [], empty_component[:parts]
    refute components.any? { |component| component[:name] == '折叠子组件' }
    refute components.any? { |component| component[:name] == '(模型根)' }
  end

  def test_expanded_parent_and_child_do_not_duplicate_rollup_quantity
    item = SuTakeoff::ScanItem.face(
      face_id: 1, face_persistent_id: 101, su_material: '墙漆', area: 2.0,
      normal: [0, 0, 1], width: 1.0, height: 2.0, layer_name: '墙面',
      component_path: ['父组件', '子组件'], component_path_ids: [10, 20],
      component_path_persistent_ids: [1001, 2001]
    )
    hierarchy = {
      name: '(模型根)', entity_id: 0, kind: 'root', depth: 0, hidden: false,
      children: [{
        name: '父组件', entity_id: 10, kind: 'group', definition_name: 'Group#1',
        depth: 1, hidden: false, children: [{
          name: '子组件', entity_id: 20, kind: 'component_instance',
          definition_name: '子组件', depth: 2, hidden: false, children: []
        }]
      }]
    }

    result = build([item], [], hierarchy: hierarchy, visible_component_paths: [[10], [10, 20]])
    quantities = result.payload[:components].flat_map { |component| component[:parts] }
                       .select { |part| part[:unit] == 'm2' }.sum { |part| part[:quantity] }

    assert_equal 2.0, quantities
    parent = result.payload[:components].find { |component| component[:name] == '父组件' }
    assert_equal [], parent[:parts]
  end

  def test_shared_nested_entity_id_uses_full_occurrence_path
    items = [[10, 20], [11, 20]].map do |path|
      SuTakeoff::ScanItem.face(
        face_id: 7, face_persistent_id: 700, su_material: '共享面材', area: 2.0,
        normal: [0, 0, 1], width: 1.0, height: 2.0, layer_name: 'Layer0',
        component_path: ['外层', '内层'], component_path_ids: path,
        component_path_persistent_ids: path.map { |id| id + 1000 }
      )
    end
    hierarchy = {
      name: '(模型根)', entity_id: 0, kind: 'root', depth: 0, hidden: false, children: [10, 11].map do |parent_id|
        {
          name: "外层#{parent_id}", entity_id: parent_id, kind: 'component_instance',
          definition_name: '外层', depth: 1, hidden: false, children: [{
            name: '共享内层', entity_id: 20, kind: 'component_instance',
            definition_name: '共享内层', depth: 2, hidden: false, children: []
          }]
        }
      end
    }

    result = build(
      items, [], hierarchy: hierarchy,
      visible_component_paths: [[10, 20], [11, 20]]
    )
    quantities = result.payload[:components].map do |component|
      component[:parts].find { |part| part[:unit] == 'm2' }[:quantity]
    end

    assert_equal [2.0, 2.0], quantities.sort
  end

  private

  def item_for_metadata_test
    SuTakeoff::ScanItem.face(
      face_id: 1,
      face_persistent_id: 101,
      su_material: 'paint',
      area: 10.0,
      normal: [0, 0, 1],
      width: 2.0,
      height: 5.0,
      layer_name: '墙面',
      component_path: ['墙面组件'],
      component_path_ids: [10],
      component_path_persistent_ids: [1001]
    )
  end
end
