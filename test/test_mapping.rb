require_relative 'test_helper'
require 'tempfile'
require 'src/mapping'

module SuTakeoff
  class TestMaterialMapping < Minitest::Test
    def setup
      @mapping = MaterialMapping.new
    end

    def test_add_mapping
      @mapping.add('marble_01', '爵士白大理石', '石材', 'm²', '大板', 0.08)
      record = @mapping.get('marble_01')
      assert_equal '爵士白大理石', record.material_name
      assert_equal '石材', record.category
      assert_equal 0.08, record.default_waste_rate
    end

    def test_duplicate_add_overwrites
      @mapping.add('a', 'name1', 'cat', 'm²', '', 0.05)
      @mapping.add('a', 'name2', 'cat', 'm²', '', 0.10)
      assert_equal 'name2', @mapping.get('a').material_name
    end

    def test_get_nonexistent_returns_nil
      assert_nil @mapping.get('nonexistent')
    end

    def test_get_all_mapped
      @mapping.add('a', 'A', 'cat', 'm²', '', 0.05)
      @mapping.add('b', 'B', 'cat', 'm²', '', 0.05)
      assert_equal 2, @mapping.all.size
    end

    def test_delete
      @mapping.add('a', 'A', 'cat', 'm²', '', 0.05)
      @mapping.delete('a')
      assert_nil @mapping.get('a')
    end

    def test_unmapped_materials
      @mapping.add('a', 'A', 'cat', 'm²', '', 0.05)
      unmapped = @mapping.unmapped_materials(['a', 'b', 'c'])
      assert_equal %w[b c], unmapped
    end

    def test_export_csv_roundtrip
      @mapping.add('a', 'A', 'cat', 'm²', 'spec', 0.05)
      file = Tempfile.new(['mapping', '.csv'])
      @mapping.export_csv(file.path)
      mapping2 = MaterialMapping.new
      mapping2.import_csv(file.path)
      assert_equal 'A', mapping2.get('a').material_name
      assert_equal 0.05, mapping2.get('a').default_waste_rate
    end

    def test_save_and_load_json
      @mapping.add('a', 'A', 'cat', 'm²', '', 0.05)
      file = Tempfile.new(['mapping', '.json'])
      @mapping.save_json(file.path)
      mapping2 = MaterialMapping.new
      mapping2.load_json(file.path)
      assert_equal 'A', mapping2.get('a').material_name
    end

    def test_bulk_set_waste_rate_by_category
      @mapping.add('a', 'A', '瓷砖', 'm²', '', 0.05)
      @mapping.add('b', 'B', '瓷砖', 'm²', '', 0.08)
      @mapping.add('c', 'C', '石材', 'm²', '', 0.10)
      @mapping.bulk_set_waste_rate('瓷砖', 0.06)
      assert_equal 0.06, @mapping.get('a').default_waste_rate
      assert_equal 0.06, @mapping.get('b').default_waste_rate
      assert_equal 0.10, @mapping.get('c').default_waste_rate
    end
  end
end
