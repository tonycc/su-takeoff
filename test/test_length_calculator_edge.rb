require_relative 'test_helper'
require 'src/length_calculators/base'
require 'src/length_calculators/edge_based'

module SuTakeoff
  class TestLengthCalculatorEdgeBased < Minitest::Test
    def test_empty_edges_returns_nil
      assert_nil LengthCalculators::EdgeBased.new.compute(nil, { edges: [] })
    end

    def test_simple_straight_line_excludes_cross_section_edges
      # 一条 5m 直线 + 截面 0.1×0.1：
      # 长方向最大 5.0，截面方向最大 0.1，5/0.1 = 50 > 5 → 截面被排除
      # 结果 = 5.0
      ctx = {
        edges: [
          { dkey: [1,0,0], len: 5.0 }, { dkey: [1,0,0], len: 5.0 },
          { dkey: [1,0,0], len: 5.0 }, { dkey: [1,0,0], len: 5.0 },
          { dkey: [0,1,0], len: 0.1 }, { dkey: [0,1,0], len: 0.1 },
          { dkey: [0,1,0], len: 0.1 }, { dkey: [0,1,0], len: 0.1 },
          { dkey: [0,0,1], len: 0.1 }, { dkey: [0,0,1], len: 0.1 },
          { dkey: [0,0,1], len: 0.1 }, { dkey: [0,0,1], len: 0.1 },
        ]
      }
      assert_in_delta 5.0, LengthCalculators::EdgeBased.new.compute(nil, ctx), 0.001
    end

    def test_l_shape_two_long_directions
      # L 型：3m + 2m，gap 1.5 < 5 → 两个方向都累加
      # 注意：每方向必须 ≥1 条边，但 regular 路径不要求 ≥4
      # 此用例每方向给 1 条边以测试 regular 路径
      ctx = {
        edges: [
          { dkey: [1,0,0], len: 3.0 },
          { dkey: [0,1,0], len: 2.0 },
        ]
      }
      assert_in_delta 5.0, LengthCalculators::EdgeBased.new.compute(nil, ctx), 0.001
    end

    def test_t_shape_three_long_directions
      # T 型：5 + 3 + 2，相邻 gap 都 < 5 → 累加 10
      ctx = {
        edges: [
          { dkey: [1,0,0], len: 5.0 },
          { dkey: [0,1,0], len: 3.0 },
          { dkey: [0,0,1], len: 2.0 },
        ]
      }
      assert_in_delta 10.0, LengthCalculators::EdgeBased.new.compute(nil, ctx), 0.001
    end

    def test_non_box_geometry_with_many_arc_groups
      # 圆柱面细分：6 组 ≥4 边 → 触发非方条形路径
      # 各组最长边 2.0, 2.1, 2.2, 2.3, 2.4, 2.5（差异小，全部累加）
      edges = []
      6.times do |i|
        4.times do
          edges << { dkey: [i, 0, 0], len: 2.0 + i * 0.1 }
        end
      end
      ctx = { edges: edges }
      result = LengthCalculators::EdgeBased.new.compute(nil, ctx)
      # 降序累加：2.5 + 2.4 + 2.3 + 2.2 + 2.1 + 2.0 = 13.5
      assert_in_delta 13.5, result, 0.001
    end

    def test_non_box_geometry_stops_at_5x_gap
      # 非方条形：第一个 gap > 5 时停止累加
      # 各组最长边降序：10, 1.5（gap 10/1.5 ≈ 6.67 > 5）→ 只累加 10
      # 后续 1.0, 0.5, 0.1, 0.05 不再累加
      edges = []
      6.times do |i|
        4.times do
          edges << { dkey: [i, 0, 0], len: [10, 1.5, 1.0, 0.5, 0.1, 0.05][i] }
        end
      end
      ctx = { edges: edges }
      result = LengthCalculators::EdgeBased.new.compute(nil, ctx)
      assert_in_delta 10.0, result, 0.001
    end

    def test_regular_branch_with_4_edges_per_direction
      # 边数刚好 4 的常规情况：长 + 短 各 4 条
      # 5m × 4 + 0.05m × 4，gap 5/0.05 = 100 > 5 → 排除短
      # 结果 = 5.0
      ctx = {
        edges: [
          { dkey: [1,0,0], len: 5.0 }, { dkey: [1,0,0], len: 5.0 },
          { dkey: [1,0,0], len: 5.0 }, { dkey: [1,0,0], len: 5.0 },
          { dkey: [0,1,0], len: 0.05 }, { dkey: [0,1,0], len: 0.05 },
          { dkey: [0,1,0], len: 0.05 }, { dkey: [0,1,0], len: 0.05 },
        ]
      }
      assert_in_delta 5.0, LengthCalculators::EdgeBased.new.compute(nil, ctx), 0.001
    end
  end
end
