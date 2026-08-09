require_relative 'test_helper'
require 'src/component_sku_mapping'
require 'src/takeoff_policy'
require 'src/calculator'
require 'src/workbench_presenter'

module SuTakeoff
  class TestWorkbenchPresenterComponentSku < Minitest::Test
    def test_build_includes_component_skus
      store = ComponentSkuMapping.new
      store.set('橱柜', 'sku-1', 'SKU-001', '白橡木饰面板 18mm')
      presenter = WorkbenchPresenter.new(
        items: [], openings: [],
        hierarchy: { name: '(root)', entity_id: 0, kind: 'root',
                     definition_name: nil, depth: 0, hidden: false, children: [] },
        colors: {},
        policy: TakeoffPolicy.new, tag_defs: {},
        component_sku: store
      )
      skus = presenter.build[:component_skus]
      assert_equal 'SKU-001', skus['橱柜'][:sku_code]
      assert_equal '白橡木饰面板 18mm', skus['橱柜'][:sku_name]
    end

    def test_build_component_skus_empty_without_store
      presenter = WorkbenchPresenter.new(
        items: [], openings: [],
        hierarchy: { name: '(root)', entity_id: 0, kind: 'root',
                     definition_name: nil, depth: 0, hidden: false, children: [] },
        colors: {},
        policy: TakeoffPolicy.new, tag_defs: {}
      )
      assert_equal({}, presenter.build[:component_skus])
    end

    def test_compact_build_omits_redundant_raw_collections
      presenter = WorkbenchPresenter.new(
        items: [], openings: [],
        hierarchy: { name: '(root)', entity_id: 0, kind: 'root',
                     definition_name: nil, depth: 0, hidden: false, children: [] },
        colors: {}, policy: TakeoffPolicy.new, tag_defs: {}
      )

      result = presenter.build(compact: true)

      refute result.key?(:items)
      refute result.key?(:openings)
      refute result.key?(:overview)
    end

    def test_component_rows_use_page_units_and_count_face_as_one
      items = [
        ScanItem.face(
          face_id: 1, face_persistent_id: 101, su_material: '墙漆', area: 2.5,
          normal: [0, 0, 1], width: 1.0, height: 2.5, layer_name: '墙面',
          component_path: ['组件A'], component_path_ids: [10],
          component_path_persistent_ids: [1001]
        ),
        ScanItem.face(
          face_id: 2, face_persistent_id: 102, su_material: '线材', area: 0.2,
          normal: [1, 0, 0], width: 0.1, height: 1.2, layer_name: '墙面',
          tags: { method: :length },
          component_path: ['组件A'], component_path_ids: [10],
          component_path_persistent_ids: [1001]
        ),
        ScanItem.face(
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
      presenter = WorkbenchPresenter.new(
        items: items, openings: [], hierarchy: hierarchy, colors: {},
        policy: TakeoffPolicy.new(heuristics_enabled: false), tag_defs: {}
      )

      rows = presenter.build[:component_rows]
      root = rows.find { |row| row[:entity_id] == 0 }
      component = rows.find { |row| row[:entity_id] == 10 }

      assert_equal 2.5, component[:area_m2]
      assert_equal 1200.0, component[:length_mm]
      assert_equal 1.0, component[:count]
      assert_equal 2.5, root[:area_m2]
      assert_equal 1200.0, root[:length_mm]
      assert_equal 1.0, root[:count]
    end

    def test_shared_nested_definition_is_aggregated_per_occurrence_path
      items = [[10, 20], [11, 20]].map do |path|
        ScanItem.face(
          face_id: 99, face_persistent_id: 9099,
          su_material: '共享面材', area: 2.0,
          normal: [0, 0, 1], width: 1.0, height: 2.0,
          layer_name: 'Layer0', component_path: ['外层', '内层'],
          component_path_ids: path,
          component_path_persistent_ids: path.map { |id| id + 1000 }
        )
      end
      child = lambda do |parent_id|
        {
          name: '内层', entity_id: 20, kind: 'component_instance',
          definition_name: '共享内层', depth: 2, hidden: false,
          component_path_ids: [parent_id, 20], children: []
        }
      end
      hierarchy = {
        name: '(模型根)', entity_id: 0, kind: 'root', depth: 0, hidden: false,
        component_path_ids: [], children: [10, 11].map do |parent_id|
          {
            name: "外层#{parent_id}", entity_id: parent_id, kind: 'component_instance',
            definition_name: '外层', depth: 1, hidden: false,
            component_path_ids: [parent_id], children: [child.call(parent_id)]
          }
        end
      }
      presenter = WorkbenchPresenter.new(
        items: items, openings: [], hierarchy: hierarchy, colors: {},
        policy: TakeoffPolicy.new(heuristics_enabled: false), tag_defs: {}
      )

      rows = presenter.build[:component_rows]
      root = rows.find { |row| row[:component_path_ids].empty? }
      first_parent = rows.find { |row| row[:component_path_ids] == [10] }
      second_parent = rows.find { |row| row[:component_path_ids] == [11] }
      first_child = rows.find { |row| row[:component_path_ids] == [10, 20] }
      second_child = rows.find { |row| row[:component_path_ids] == [11, 20] }

      assert_equal 4.0, root[:area_m2]
      assert_equal 2.0, first_parent[:area_m2]
      assert_equal 2.0, second_parent[:area_m2]
      assert_equal 2.0, first_child[:area_m2]
      assert_equal 2.0, second_child[:area_m2]
    end

    def test_build_includes_project_product_fields
      store = ComponentSkuMapping.new
      store.set_project_product(
        '橱柜',
        project_product_id: 'pp-1',
        product_id: 'product-1',
        catalog_code: 'P-001',
        product_name: '白橡木柜体'
      )
      presenter = WorkbenchPresenter.new(
        items: [], openings: [],
        hierarchy: { name: '(root)', entity_id: 0, kind: 'root',
                     definition_name: nil, depth: 0, hidden: false, children: [] },
        colors: {},
        policy: TakeoffPolicy.new, tag_defs: {},
        component_sku: store
      )

      product = presenter.build[:component_skus]['橱柜']
      assert_equal 'pp-1', product[:project_product_id]
      assert_equal 'P-001', product[:catalog_code]
      assert_equal '白橡木柜体', product[:product_name]
    end
  end
end
