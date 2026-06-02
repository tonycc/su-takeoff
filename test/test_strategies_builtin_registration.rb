require_relative 'test_helper'
require 'src/strategies/base'
require 'src/strategies/registry'
require 'src/strategies/face_area'
require 'src/strategies/face_linear'
require 'src/strategies/instance_count'
require 'src/strategies/solid_volume'
require 'src/strategies/solid_linear'
require 'src/strategies/solid_count'
require 'src/strategies/skip'
require 'src/strategies/builtin'
require 'src/strategies/loader'

module SuTakeoff
  class TestStrategiesBuiltinRegistration < Minitest::Test
    def setup
      Strategies::Registry.reset!
      Strategies::Builtin.register_all!
    end

    def teardown
      # 恢复全局 Registry 到默认 builtin 状态，避免污染其他测试
      Strategies::Registry.reset!
      Strategies::Builtin.register_all!
      strategies_json = File.join(File.expand_path('..', __dir__), 'data', 'strategies.json')
      Strategies::Loader.load_from_file!(strategies_json)
    end

    def test_face_area_registered_and_default_for_area
      assert_kind_of Strategies::FaceArea, Strategies::Registry.get(:face_area)
      assert_equal :face_area, Strategies::Registry.default_for(:area).name
    end

    def test_solid_linear_default_for_length
      assert_equal :solid_linear, Strategies::Registry.default_for(:length).name
    end

    def test_solid_volume_default_for_volume
      assert_equal :solid_volume, Strategies::Registry.default_for(:volume).name
    end

    def test_solid_count_default_for_count
      assert_equal :solid_count, Strategies::Registry.default_for(:count).name
    end

    def test_skip_default_for_skip
      assert_equal :skip, Strategies::Registry.default_for(:skip).name
    end

    def test_all_seven_strategies_registered
      # face_area, face_linear, instance_count, solid_volume,
      # solid_linear, solid_count, skip
      assert_equal 7, Strategies::Registry.all.size
    end

    def test_face_linear_registered_without_default
      # face_linear 也是 method=:length，但不是 default_for(:length)
      # default_for(:length) 应该是 solid_linear，face_linear 通过 get 取
      assert_kind_of Strategies::FaceLinear, Strategies::Registry.get(:face_linear)
    end

    def test_instance_count_registered_without_default
      # instance_count 也是 method=:count，但 default 是 solid_count
      assert_kind_of Strategies::InstanceCount, Strategies::Registry.get(:instance_count)
    end
  end
end
