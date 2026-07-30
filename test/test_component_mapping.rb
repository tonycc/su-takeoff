require_relative 'test_helper'
require 'tempfile'
require 'src/component_mapping'

module SuTakeoff
  class TestComponentMapping < Minitest::Test
    def test_platform_fields_roundtrip_json
      mapping = ComponentMapping.new
      mapping.add('柜体', '地柜', '柜体', '套', '', 0.0, 'aggregate', 'wood', 'cabinet')
      file = Tempfile.new(['component_mapping', '.json'])

      mapping.save_json(file.path)
      loaded = ComponentMapping.new
      loaded.load_json(file.path)
      record = loaded.get('柜体')

      assert_equal 'wood', record.platform_material_tag
      assert_equal 'cabinet', record.platform_component_type
      assert_equal 'aggregate', record.counting_method
    end

    def test_old_json_without_platform_fields_still_loads
      file = Tempfile.new(['component_mapping', '.json'])
      file.write(JSON.generate('柜体' => {
        material_name: '地柜',
        category: '柜体',
        unit: '套',
        spec: '',
        default_waste_rate: 0.0,
        counting_method: 'aggregate'
      }))
      file.close

      mapping = ComponentMapping.new
      mapping.load_json(file.path)
      record = mapping.get('柜体')

      assert_equal '地柜', record.material_name
      assert_nil record.platform_material_tag
      assert_nil record.platform_component_type
    end
  end
end
