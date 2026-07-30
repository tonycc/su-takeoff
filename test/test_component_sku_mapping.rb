require_relative 'test_helper'
require 'tempfile'
require 'src/component_sku_mapping'

module SuTakeoff
  class TestComponentSkuMapping < Minitest::Test
    def setup
      @store = ComponentSkuMapping.new
    end

    def test_set_and_get
      @store.set('橱柜', 'sku-1', 'SKU-001', '白橡木饰面板 18mm')
      r = @store.get('橱柜')
      assert_equal 'sku-1', r.platform_sku_id
      assert_equal 'SKU-001', r.platform_sku_code
      assert_equal '白橡木饰面板 18mm', r.platform_sku_name
    end

    def test_set_overwrites
      @store.set('a', 's1', 'C1', 'N1')
      @store.set('a', 's2', 'C2', 'N2')
      assert_equal 'C2', @store.get('a').platform_sku_code
    end

    def test_blank_definition_name_ignored
      @store.set('', 's1', 'C1', 'N1')
      @store.set(nil, 's1', 'C1', 'N1')
      assert_equal 0, @store.all.size
    end

    def test_empty_sku_normalized_to_nil
      @store.set('a', '', '  ', nil)
      r = @store.get('a')
      assert_nil r.platform_sku_id
      assert_nil r.platform_sku_code
      assert_nil r.platform_sku_name
    end

    def test_json_roundtrip
      @store.set('a', 's1', 'C1', 'N1')
      file = Tempfile.new(['comp_sku', '.json'])
      @store.save_json(file.path)
      store2 = ComponentSkuMapping.new
      store2.load_json(file.path)
      assert_equal 'C1', store2.get('a').platform_sku_code
    end

    def test_json_string_roundtrip
      @store.set('a', 's1', 'C1', 'N1')
      store2 = ComponentSkuMapping.new
      store2.load_json_string(@store.save_json_string)
      assert_equal 'N1', store2.get('a').platform_sku_name
    end

    def test_delete
      @store.set('a', 's1', 'C1', 'N1')
      @store.delete('a')
      assert_nil @store.get('a')
    end
  end
end
