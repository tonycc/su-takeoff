require_relative 'test_helper'
require 'src/strategies/base'
require 'src/strategies/registry'

module SuTakeoff
  class TestStrategyRegistry < Minitest::Test
    def setup
      Strategies::Registry.reset!
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
  end
end
