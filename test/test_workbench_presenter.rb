require_relative 'test_helper'
require 'src/mapping'
require 'src/component_mapping'
require 'src/component_sku_mapping'
require 'src/takeoff_policy'
require 'src/calculator'
require 'src/workbench_presenter'

module SuTakeoff
  class TestWorkbenchPresenterSku < Minitest::Test
    def build_usages(mapping)
      items = [ScanItem.face(face_id: 1, su_material: 'paint', area: 10.0,
                             normal: [0, 0, 1], width: 2, height: 5,
                             layer_name: '墙面', component_path: ['客厅'],
                             component_path_ids: [10])]
      policy = TakeoffPolicy.new(mapping: mapping)
      WorkbenchPresenter.new(
        items: items, openings: [],
        hierarchy: { name: '(root)', entity_id: 0, kind: 'root',
                     definition_name: nil, depth: 0, hidden: false, children: [] },
        colors: {}, mapping: mapping, component_mapping: ComponentMapping.new,
        policy: policy, ignored: [], tag_defs: {}
      ).build[:geometry_usages]
    end

    def test_usage_carries_sku_when_mapping_has_sku
      mapping = MaterialMapping.new
      mapping.add('paint', '乳胶漆', '涂料', 'm²', '', 0.0, 'paint',
                  'sku-1', 'SKU-001', '白橡木饰面板 18mm')
      usage = build_usages(mapping).find { |u| u[:su_material] == 'paint' }
      assert_equal 'SKU-001', usage[:sku_code]
      assert_equal '白橡木饰面板 18mm', usage[:sku_name]
    end

    def test_usage_sku_nil_when_mapping_without_sku
      mapping = MaterialMapping.new
      mapping.add('paint', '乳胶漆', '涂料', 'm²', '', 0.0, 'paint')
      usage = build_usages(mapping).find { |u| u[:su_material] == 'paint' }
      assert_nil usage[:sku_code]
      assert_nil usage[:sku_name]
    end

    def test_usage_sku_nil_when_material_unmapped
      mapping = MaterialMapping.new # 空映射，'paint' 完全未映射
      usage = build_usages(mapping).find { |u| u[:su_material] == 'paint' }
      refute_nil usage, '未映射材质仍应出现在 geometry_usages'
      assert_nil usage[:sku_code]
      assert_nil usage[:sku_name]
    end

    def test_build_includes_component_skus
      store = ComponentSkuMapping.new
      store.set('橱柜', 'sku-1', 'SKU-001', '白橡木饰面板 18mm')
      mapping = MaterialMapping.new
      presenter = WorkbenchPresenter.new(
        items: [], openings: [],
        hierarchy: { name: '(root)', entity_id: 0, kind: 'root',
                     definition_name: nil, depth: 0, hidden: false, children: [] },
        colors: {}, mapping: mapping, component_mapping: ComponentMapping.new,
        policy: TakeoffPolicy.new(mapping: mapping), ignored: [], tag_defs: {},
        component_sku: store
      )
      skus = presenter.build[:component_skus]
      assert_equal 'SKU-001', skus['橱柜'][:sku_code]
      assert_equal '白橡木饰面板 18mm', skus['橱柜'][:sku_name]
    end

    def test_build_component_skus_empty_without_store
      mapping = MaterialMapping.new
      presenter = WorkbenchPresenter.new(
        items: [], openings: [],
        hierarchy: { name: '(root)', entity_id: 0, kind: 'root',
                     definition_name: nil, depth: 0, hidden: false, children: [] },
        colors: {}, mapping: mapping, component_mapping: ComponentMapping.new,
        policy: TakeoffPolicy.new(mapping: mapping), ignored: [], tag_defs: {}
      )
      assert_equal({}, presenter.build[:component_skus])
    end
  end
end
