require_relative 'test_helper'
require 'src/strategies/loader'
require 'tempfile'
require 'json'

module SuTakeoff
  class TestStrategiesLoader < Minitest::Test
    def setup
      Strategies::Registry.reset!
      Strategies::Builtin.register_all!
    end

    def teardown
      Strategies::Registry.reset!
      Strategies::Builtin.register_all!
    end

    def test_loads_variant_from_json
      Tempfile.create(['strategies', '.json']) do |f|
        f.write(JSON.generate({
          'my_skirting' => {
            'base_strategy' => 'solid_linear',
            'match_rules' => {
              'definition_name_includes' => ['踢脚']
            }
          }
        }))
        f.close
        Strategies::Loader.load_from_file!(f.path)
        loaded = Strategies::Registry.get(:my_skirting)
        refute_nil loaded
        assert_equal :length, loaded.method
        assert_equal :my_skirting, loaded.name
        assert_equal ['踢脚'], loaded.match_rules[:definition_name_includes]
        assert_kind_of Strategies::SolidLinear, loaded
      end
    end

    def test_silently_skips_invalid_base_strategy
      Tempfile.create(['strategies', '.json']) do |f|
        f.write(JSON.generate({
          'bad' => { 'base_strategy' => 'nonexistent', 'match_rules' => {} }
        }))
        f.close
        Strategies::Loader.load_from_file!(f.path)
        assert_nil Strategies::Registry.get(:bad)
      end
    end

    def test_missing_file_does_not_crash
      Strategies::Loader.load_from_file!('/tmp/nonexistent_strategies.json')
      assert true
    end

    def test_malformed_json_warns_and_does_not_crash
      Tempfile.create(['strategies', '.json']) do |f|
        f.write('{ bad json')
        f.close
        _, err = capture_io { Strategies::Loader.load_from_file!(f.path) }
        assert_match(/JSON parse failed/, err)
      end
    end

    def test_loaded_variant_uses_base_aggregate_logic
      Tempfile.create(['strategies', '.json']) do |f|
        f.write(JSON.generate({
          'custom_linear' => {
            'base_strategy' => 'solid_linear',
            'match_rules' => { 'layer' => ['CustomLayer'] }
          }
        }))
        f.close
        Strategies::Loader.load_from_file!(f.path)
        variant = Strategies::Registry.get(:custom_linear)
        item = ScanItem.linear_solid(
          face_id: 1, su_material: 'x', length: 3.5,
          layer_name: 'L0', component_path: ['R'], component_path_ids: [1]
        )
        assert_in_delta 3.5, variant.aggregate([item], {}), 0.001
      end
    end

    def test_loaded_variant_match_rules_work
      Tempfile.create(['strategies', '.json']) do |f|
        f.write(JSON.generate({
          'custom' => {
            'base_strategy' => 'solid_linear',
            'match_rules' => {
              'definition_name_includes' => ['XX']
            }
          }
        }))
        f.close
        Strategies::Loader.load_from_file!(f.path)
        variant = Strategies::Registry.get(:custom)
        item = ScanItem.face(
          face_id: 1, su_material: 'x', area: 1, normal: [0,0,1],
          width: 1, height: 1, layer_name: 'L', component_path: ['R'], component_path_ids: [1]
        )
        assert variant.matches?(item, definition_name: 'XX-001')
        refute variant.matches?(item, definition_name: 'YY')
      end
    end
  end
end
