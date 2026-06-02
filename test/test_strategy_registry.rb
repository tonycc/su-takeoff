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

module SuTakeoff
  class TestStrategyRegistry < Minitest::Test
    def setup
      Strategies::Registry.reset!
    end

    def teardown
      # 恢复全局 Registry 到默认 builtin 状态，避免污染其他测试
      Strategies::Registry.reset!
      Strategies::Builtin.register_all!
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
  end
end
