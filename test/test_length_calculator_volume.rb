require_relative 'test_helper'
require 'src/length_calculators/base'
require 'src/length_calculators/volume_based'

module SuTakeoff
  class TestLengthCalculatorVolumeBased < Minitest::Test
    # 用 ctx[:volume_m3] 直接给体积，绕过 SU API entity.volume

    class FakeEntity
      attr_reader :volume
      def initialize(volume) @volume = volume end
      def respond_to?(m) m == :volume end
    end

    def test_returns_nil_when_no_short_meaningful_groups
      # 只有一组边方向（4 条 5m 长边），不足 2 组截面
      ctx = {
        edges: [
          { dkey: [1,0,0], len: 5.0 }, { dkey: [1,0,0], len: 5.0 },
          { dkey: [1,0,0], len: 5.0 }, { dkey: [1,0,0], len: 5.0 },
        ],
        scale: 1.0,
        volume_m3: 0.05
      }
      assert_nil LengthCalculators::VolumeBased.new.compute(nil, ctx)
    end

    def test_computes_when_two_short_groups
      # 4 条长边（5m）+ 4 条短边 0.08m + 4 条短边 0.05m → 截面 0.05×0.08
      # 体积 0.02 m³ → length = 0.02 / 0.05 / 0.08 = 5.0
      # 注意：截面上限是严格小于 0.1m，故不能直接用 0.1
      ctx = {
        edges: [
          { dkey: [1,0,0], len: 5.0 }, { dkey: [1,0,0], len: 5.0 },
          { dkey: [1,0,0], len: 5.0 }, { dkey: [1,0,0], len: 5.0 },
          { dkey: [0,1,0], len: 0.08 }, { dkey: [0,1,0], len: 0.08 },
          { dkey: [0,1,0], len: 0.08 }, { dkey: [0,1,0], len: 0.08 },
          { dkey: [0,0,1], len: 0.05 }, { dkey: [0,0,1], len: 0.05 },
          { dkey: [0,0,1], len: 0.05 }, { dkey: [0,0,1], len: 0.05 },
        ],
        scale: 1.0,
        volume_m3: 0.02
      }
      assert_in_delta 5.0, LengthCalculators::VolumeBased.new.compute(nil, ctx), 0.001
    end

    def test_excludes_section_at_exactly_max_threshold
      # 边界精确测试：0.1m 是严格小于的上限，不计入截面
      ctx = {
        edges: [
          { dkey: [1,0,0], len: 5.0 }, { dkey: [1,0,0], len: 5.0 },
          { dkey: [1,0,0], len: 5.0 }, { dkey: [1,0,0], len: 5.0 },
          { dkey: [0,1,0], len: 0.1 }, { dkey: [0,1,0], len: 0.1 },
          { dkey: [0,1,0], len: 0.1 }, { dkey: [0,1,0], len: 0.1 },
          { dkey: [0,0,1], len: 0.05 }, { dkey: [0,0,1], len: 0.05 },
          { dkey: [0,0,1], len: 0.05 }, { dkey: [0,0,1], len: 0.05 },
        ],
        scale: 1.0,
        volume_m3: 0.025
      }
      assert_nil LengthCalculators::VolumeBased.new.compute(nil, ctx)
    end

    def test_returns_nil_when_volume_zero
      ctx = { edges: [], scale: 1.0, volume_m3: 0 }
      assert_nil LengthCalculators::VolumeBased.new.compute(nil, ctx)
    end

    def test_returns_nil_when_volume_missing_and_entity_has_no_volume
      ctx = { edges: [], scale: 1.0 }
      entity = FakeEntity.new(nil)
      assert_nil LengthCalculators::VolumeBased.new.compute(entity, ctx)
    end

    def test_excludes_arc_edges_below_threshold
      # 圆柱面细分边长 0.00005m < 0.001m，应被排除
      # 这里 4 条 0.05m + 4 条 0.0005m，只有一组有效截面
      ctx = {
        edges: [
          { dkey: [1,0,0], len: 5.0 }, { dkey: [1,0,0], len: 5.0 },
          { dkey: [1,0,0], len: 5.0 }, { dkey: [1,0,0], len: 5.0 },
          { dkey: [0,1,0], len: 0.05 }, { dkey: [0,1,0], len: 0.05 },
          { dkey: [0,1,0], len: 0.05 }, { dkey: [0,1,0], len: 0.05 },
          { dkey: [0,0,1], len: 0.0005 }, { dkey: [0,0,1], len: 0.0005 },
          { dkey: [0,0,1], len: 0.0005 }, { dkey: [0,0,1], len: 0.0005 },
        ],
        scale: 1.0,
        volume_m3: 0.001
      }
      assert_nil LengthCalculators::VolumeBased.new.compute(nil, ctx)
    end

    def test_excludes_long_edges_above_threshold
      # 0.15m > 0.1m 上限，不算截面
      ctx = {
        edges: [
          { dkey: [1,0,0], len: 5.0 }, { dkey: [1,0,0], len: 5.0 },
          { dkey: [1,0,0], len: 5.0 }, { dkey: [1,0,0], len: 5.0 },
          { dkey: [0,1,0], len: 0.15 }, { dkey: [0,1,0], len: 0.15 },
          { dkey: [0,1,0], len: 0.15 }, { dkey: [0,1,0], len: 0.15 },
          { dkey: [0,0,1], len: 0.05 }, { dkey: [0,0,1], len: 0.05 },
          { dkey: [0,0,1], len: 0.05 }, { dkey: [0,0,1], len: 0.05 },
        ],
        scale: 1.0,
        volume_m3: 0.05
      }
      assert_nil LengthCalculators::VolumeBased.new.compute(nil, ctx)
    end
  end
end
