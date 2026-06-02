require_relative 'test_helper'
require 'src/length_calculators/base'
require 'src/length_calculators/chained'

module SuTakeoff
  class TestLengthCalculatorChained < Minitest::Test
    class FakeCalc
      def initialize(result) @result = result end
      def compute(_entity, _ctx) @result end
    end

    def test_returns_first_non_nil
      chained = LengthCalculators::Chained.new(
        FakeCalc.new(nil),
        FakeCalc.new(7.5),
        FakeCalc.new(99.0)
      )
      assert_equal 7.5, chained.compute(nil, {})
    end

    def test_returns_nil_if_all_nil
      chained = LengthCalculators::Chained.new(FakeCalc.new(nil), FakeCalc.new(nil))
      assert_nil chained.compute(nil, {})
    end

    def test_empty_chain_returns_nil
      assert_nil LengthCalculators::Chained.new.compute(nil, {})
    end

    def test_short_circuits_after_first_non_nil
      called = []
      first = Class.new {
        define_method(:compute) { |*| called << :first; 10.0 }
      }.new
      second = Class.new {
        define_method(:compute) { |*| called << :second; 20.0 }
      }.new
      LengthCalculators::Chained.new(first, second).compute(nil, {})
      assert_equal [:first], called
    end
  end
end
