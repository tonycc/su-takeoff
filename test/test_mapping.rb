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

    def test_platform_material_tag_roundtrips_json_and_csv
      @mapping.add('a', 'A', 'cat', 'm²', '', 0.05, 'wood')

      json_file = Tempfile.new(['mapping', '.json'])
      @mapping.save_json(json_file.path)
      from_json = MaterialMapping.new
      from_json.load_json(json_file.path)
      assert_equal 'wood', from_json.get('a').platform_material_tag

      csv_file = Tempfile.new(['mapping', '.csv'])
      @mapping.export_csv(csv_file.path)
      from_csv = MaterialMapping.new
      from_csv.import_csv(csv_file.path)
      assert_equal 'wood', from_csv.get('a').platform_material_tag
    end

    def test_old_json_without_platform_material_tag_still_loads
      file = Tempfile.new(['mapping', '.json'])
      file.write(JSON.generate('a' => {
        material_name: 'A',
        category: 'cat',
        unit: 'm²',
        spec: '',
        default_waste_rate: 0.05
      }))
      file.close

      @mapping.load_json(file.path)

      assert_equal 'A', @mapping.get('a').material_name
      assert_nil @mapping.get('a').platform_material_tag
    end

    def test_platform_sku_roundtrips_json_and_csv
      @mapping.add('a', 'A', 'cat', 'm²', '', 0.05, 'wood', 'sku-1', 'SKU-001', '白橡木饰面板 18mm')

      json_file = Tempfile.new(['mapping', '.json'])
      @mapping.save_json(json_file.path)
      from_json = MaterialMapping.new
      from_json.load_json(json_file.path)
      assert_equal 'sku-1', from_json.get('a').platform_sku_id
      assert_equal 'SKU-001', from_json.get('a').platform_sku_code
      assert_equal '白橡木饰面板 18mm', from_json.get('a').platform_sku_name

      csv_file = Tempfile.new(['mapping', '.csv'])
      @mapping.export_csv(csv_file.path)
      from_csv = MaterialMapping.new
      from_csv.import_csv(csv_file.path)
      assert_equal 'sku-1', from_csv.get('a').platform_sku_id
      assert_equal 'SKU-001', from_csv.get('a').platform_sku_code
      assert_equal '白橡木饰面板 18mm', from_csv.get('a').platform_sku_name
    end

    def test_platform_sku_empty_string_normalizes_to_nil
      @mapping.add('a', 'A', 'cat', 'm²', '', 0.05, 'wood', '', '  ', nil)
      assert_nil @mapping.get('a').platform_sku_id
      assert_nil @mapping.get('a').platform_sku_code
      assert_nil @mapping.get('a').platform_sku_name
    end

    def test_old_json_without_sku_still_loads_nil
      file = Tempfile.new(['mapping', '.json'])
      file.write(JSON.generate('a' => {
        material_name: 'A', category: 'cat', unit: 'm²', spec: '',
        default_waste_rate: 0.05, platform_material_tag: 'wood'
      }))
      file.close
      @mapping.load_json(file.path)
      assert_nil @mapping.get('a').platform_sku_id
      assert_nil @mapping.get('a').platform_sku_code
      assert_nil @mapping.get('a').platform_sku_name
    end

    def test_update_sku_preserves_existing_mapping_fields
      @mapping.add('a', 'A材料', '瓷砖', 'm²', '600×600', 0.08, 'tile-tag')
      @mapping.update_sku('a', 'sku-9', 'SKU-9', '某SKU 18mm')
      r = @mapping.get('a')
      assert_equal 'sku-9', r.platform_sku_id
      assert_equal 'SKU-9', r.platform_sku_code
      assert_equal '某SKU 18mm', r.platform_sku_name
      # 其余字段保持不变
      assert_equal 'A材料', r.material_name
      assert_equal '瓷砖', r.category
      assert_equal 'm²', r.unit
      assert_equal '600×600', r.spec
      assert_equal 0.08, r.default_waste_rate
      assert_equal 'tile-tag', r.platform_material_tag
    end

    def test_update_sku_creates_mapping_for_unmapped_material
      @mapping.update_sku('newmat', 'sku-1', 'SKU-1', '白橡木饰面板 18mm')
      r = @mapping.get('newmat')
      refute_nil r, '未映射材质应被自动建立映射'
      assert_equal '白橡木饰面板 18mm', r.material_name # 默认取 SKU 名称
      assert_equal 'SKU-1', r.platform_sku_code
      assert_equal '白橡木饰面板 18mm', r.platform_sku_name
    end

  end
end
