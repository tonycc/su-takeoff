require_relative 'test_helper'
require 'src/length_calculators/base'
require 'src/length_calculators/segmented_path'

module SuTakeoff
  class TestLengthCalculatorSegmentedPath < Minitest::Test
    def test_returns_nil_when_no_edges
      assert_nil LengthCalculators::SegmentedPath.new.compute(nil, { edges: [] })
    end

    def test_returns_nil_when_all_edges_below_min_length
      # 全是装饰短边 < 5mm
      ctx = { edges: [
        { len: 0.001 }, { len: 0.0013 }, { len: 0.002 }
      ] }
      assert_nil LengthCalculators::SegmentedPath.new.compute(nil, ctx)
    end

    def test_three_distinct_segments_no_repeats
      # 简单 L 型：3 段不同长度
      ctx = { edges: [
        { len: 3.30 },
        { len: 1.57 },
        { len: 0.85 },
      ] }
      assert_in_delta 5.72, LengthCalculators::SegmentedPath.new.compute(nil, ctx), 0.001
    end

    def test_repeated_segments_collapse_to_one_bucket
      # 同段重复 5 次 → 1 桶 → 取最大 = 3.30
      ctx = { edges: [
        { len: 3.30 }, { len: 3.30 }, { len: 3.30 }, { len: 3.30 }, { len: 3.30 },
      ] }
      assert_in_delta 3.30, LengthCalculators::SegmentedPath.new.compute(nil, ctx), 0.001
    end

    def test_real_wire_scenario_with_decoration_edges
      # 模拟客-电敷线场景：3 段路径 + 大量虚点装饰
      edges = []
      # 50 条虚点装饰边 1.3mm（应被过滤）
      50.times { edges << { len: 0.0013 } }
      # 15 条 3.30m 路径段重复（同桶）
      15.times { edges << { len: 3.30 + rand(-0.005..0.005) } }
      # 14 条 1.57m 路径段
      14.times { edges << { len: 1.57 + rand(-0.005..0.005) } }
      # 13 条 0.85m 路径段
      13.times { edges << { len: 0.85 + rand(-0.005..0.005) } }
      ctx = { edges: edges }
      result = LengthCalculators::SegmentedPath.new.compute(nil, ctx)
      # 期望 ≈ 3.305 + 1.575 + 0.855 = 5.735m
      assert_in_delta 5.735, result, 0.05
    end

    def test_tolerance_separates_distinct_segments
      # 0.85 和 0.95 差 11% > 5% → 不同桶
      ctx = { edges: [
        { len: 0.85 }, { len: 0.85 },
        { len: 0.95 }, { len: 0.95 },
      ] }
      result = LengthCalculators::SegmentedPath.new.compute(nil, ctx)
      assert_in_delta 1.80, result, 0.001
    end

    def test_tolerance_merges_similar_segments
      # 1.565 和 1.575 差 < 5% → 同桶 → 取最大
      ctx = { edges: [
        { len: 1.565 }, { len: 1.566 }, { len: 1.575 },
      ] }
      result = LengthCalculators::SegmentedPath.new.compute(nil, ctx)
      assert_in_delta 1.575, result, 0.001
    end
  end
end
