require_relative 'test_helper'
require 'src/strategies/base'

module SuTakeoff
  class TestStrategyBase < Minitest::Test
    def test_has_required_readers
      strategy = Strategies::Base.new(name: :test, method: :area, default_unit: 'm²')
      assert_equal :test, strategy.name
      assert_equal :area, strategy.method
      assert_equal 'm²', strategy.default_unit
    end

    def test_aggregate_is_abstract
      strategy = Strategies::Base.new(name: :test, method: :area, default_unit: 'm²')
      assert_raises(NotImplementedError) { strategy.aggregate([], {}) }
    end

    def test_emit_from_container_returns_nil_by_default
      # 面级策略不需要从容器 emit；默认返回 nil 表示"由 Scanner 收集子面"
      strategy = Strategies::Base.new(name: :test, method: :area, default_unit: 'm²')
      assert_nil strategy.emit_from_container(nil, {})
    end
  end
end
