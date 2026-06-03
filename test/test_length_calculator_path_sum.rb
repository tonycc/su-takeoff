require_relative 'test_helper'
require 'src/length_calculators/base'
require 'src/length_calculators/path_sum'

module SuTakeoff
  class TestLengthCalculatorPathSum < Minitest::Test
    def test_returns_nil_when_no_edges
      assert_nil LengthCalculators::PathSum.new.compute(nil, { edges: [] })
    end

    def test_returns_nil_when_ctx_missing_edges
      assert_nil LengthCalculators::PathSum.new.compute(nil, {})
    end

    def test_sums_all_edge_lengths_regardless_of_direction
      # L 形路径：4m 斜段 + 1.2m 水平 + 1.4m 竖直 = 6.6m
      ctx = {
        edges: [
          { dkey: [0.8, 0.6, 0], len: 4.0 },
          { dkey: [1, 0, 0],     len: 1.2 },
          { dkey: [0, 0, 1],     len: 1.4 },
        ]
      }
      assert_in_delta 6.6, LengthCalculators::PathSum.new.compute(nil, ctx), 0.001
    end

    def test_sums_repeated_same_direction
      ctx = {
        edges: [
          { dkey: [1, 0, 0], len: 1.0 },
          { dkey: [1, 0, 0], len: 2.0 },
          { dkey: [1, 0, 0], len: 1.5 },
        ]
      }
      assert_in_delta 4.5, LengthCalculators::PathSum.new.compute(nil, ctx), 0.001
    end

    def test_returns_nil_when_total_zero
      ctx = { edges: [{ dkey: [1,0,0], len: 0 }] }
      assert_nil LengthCalculators::PathSum.new.compute(nil, ctx)
    end

    def test_rounds_to_4_decimals
      ctx = { edges: [{ dkey: [1,0,0], len: 1.123456789 }] }
      assert_equal 1.1235, LengthCalculators::PathSum.new.compute(nil, ctx)
    end
  end
end
