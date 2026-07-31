require_relative 'test_helper'
require 'src/component_mapping'
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
        colors: {}, component_mapping: ComponentMapping.new,
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
        colors: {}, component_mapping: ComponentMapping.new,
        policy: TakeoffPolicy.new, tag_defs: {}
      )
      assert_equal({}, presenter.build[:component_skus])
    end
  end
end
