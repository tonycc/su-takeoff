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
require 'src/takeoff_policy'

module SuTakeoff
  class TestStrategyRegistry < Minitest::Test
    def setup
      Strategies::Registry.reset!
    end

    def teardown
      # 恢复全局 Registry 到默认 builtin 状态，避免污染其他测试
      Strategies::Registry.reset!
      Strategies::Builtin.register_all!
      strategies_json = File.join(File.expand_path('..', __dir__), 'data', 'strategies.json')
      Strategies::Loader.load_from_file!(strategies_json)
    end

    def test_register_and_get
      s = Strategies::Base.new(name: :foo, method: :area, default_unit: 'm²')
      Strategies::Registry.register(s)
      assert_equal s, Strategies::Registry.get(:foo)
    end

    def test_get_missing_returns_nil
      assert_nil Strategies::Registry.get(:nonexistent)
    end

    def test_default_for_method
      s = Strategies::Base.new(name: :foo, method: :area, default_unit: 'm²')
      Strategies::Registry.register(s, default_for: :area)
      assert_equal s, Strategies::Registry.default_for(:area)
    end

    def test_default_for_method_returns_nil_when_unset
      assert_nil Strategies::Registry.default_for(:area)
    end

    def test_register_without_default_for_does_not_set_default
      s = Strategies::Base.new(name: :foo, method: :area, default_unit: 'm²')
      Strategies::Registry.register(s)
      assert_nil Strategies::Registry.default_for(:area)
    end

    def test_all_strategies
      s1 = Strategies::Base.new(name: :a, method: :area, default_unit: 'm²')
      s2 = Strategies::Base.new(name: :b, method: :length, default_unit: 'm')
      Strategies::Registry.register(s1)
      Strategies::Registry.register(s2)
      assert_equal 2, Strategies::Registry.all.size
    end

    def test_register_same_name_twice_warns_and_overwrites
      s1 = Strategies::Base.new(name: :foo, method: :area, default_unit: 'm²')
      s2 = Strategies::Base.new(name: :foo, method: :length, default_unit: 'm')
      Strategies::Registry.register(s1)
      _out, err = capture_io { Strategies::Registry.register(s2) }
      assert_match(/re-registered/, err)
      assert_equal s2, Strategies::Registry.get(:foo)
    end

    def test_register_same_object_twice_does_not_warn
      s = Strategies::Base.new(name: :foo, method: :area, default_unit: 'm²')
      Strategies::Registry.register(s)
      _out, err = capture_io { Strategies::Registry.register(s) }
      assert_equal '', err
    end

    def test_register_conflicting_default_for_raises
      s1 = Strategies::Base.new(name: :a, method: :area, default_unit: 'm²')
      s2 = Strategies::Base.new(name: :b, method: :area, default_unit: 'm²')
      Strategies::Registry.register(s1, default_for: :area)
      assert_raises(ArgumentError) do
        Strategies::Registry.register(s2, default_for: :area)
      end
    end

    def test_register_same_object_with_same_default_for_is_idempotent
      s = Strategies::Base.new(name: :a, method: :area, default_unit: 'm²')
      Strategies::Registry.register(s, default_for: :area)
      # 不应 raise
      Strategies::Registry.register(s, default_for: :area)
      assert_equal s, Strategies::Registry.default_for(:area)
    end

    # ---- 实例 API ----

    def test_instance_methods_work_independently
      registry = Strategies::Registry.new
      s = Strategies::Base.new(name: :iso, method: :area, default_unit: 'm²')
      registry.register(s, default_for: :area)
      assert_equal s, registry.get(:iso)
      assert_equal s, registry.default_for(:area)
    end

    def test_instance_does_not_pollute_global
      Strategies::Registry.reset!
      Strategies::Builtin.register_all!
      before = Strategies::Registry.all.size

      isolated = Strategies::Registry.new
      isolated.register(Strategies::Base.new(name: :iso2, method: :area, default_unit: 'm²'))
      assert_equal 1, isolated.all.size
      assert_equal before, Strategies::Registry.all.size
    end

    def test_global_class_methods_delegate_to_singleton
      Strategies::Registry.reset!
      s = Strategies::Base.new(name: :delegate_test, method: :length, default_unit: 'm')
      Strategies::Registry.register(s)
      assert_equal s, Strategies::Registry.global.get(:delegate_test)
    end

    def test_policy_uses_injected_registry
      isolated = Strategies::Registry.new
      isolated.register(Strategies::FaceArea.new, default_for: :area)
      isolated.register(Strategies::SolidLinear.new, default_for: :length)
      isolated.register(Strategies::SolidVolume.new, default_for: :volume)
      isolated.register(Strategies::SolidCount.new, default_for: :count)
      isolated.register(Strategies::Skip.new, default_for: :skip)
      isolated.register(Strategies::InstanceCount.new)
      isolated.register(Strategies::FaceLinear.new)

      # 材料映射已移除：用 layer_rules 触发 :area 决议，验证注入的 Registry
      # 的 default_for(:area) 被使用（而非 global）。
      policy = SuTakeoff::TakeoffPolicy.new(strategies: isolated,
                                            layer_rules: { 'L0' => :area })
      item = SuTakeoff::ScanItem.face(
        face_id: 1, su_material: 'xxx', area: 5.0, normal: [0,0,1],
        width: 2.0, height: 2.5, layer_name: 'L0',
        component_path: ['R'], component_path_ids: [1]
      )
      r = policy.resolve(item)
      assert_equal :face_area, r.strategy.name
    end
  end
end
