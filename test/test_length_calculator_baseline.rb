require_relative 'test_helper'
require 'src/length_calculators/base'
require 'src/length_calculators/baseline'

# Sketchup::Edge / Group / ComponentInstance 在测试环境不存在，
# 用 mock 模块定义最小占位类型，让 is_a?(Sketchup::Edge) 能匹配。
module Sketchup
end unless defined?(::Sketchup)

class ::Sketchup::Edge
end unless defined?(::Sketchup::Edge)

class ::Sketchup::Group
end unless defined?(::Sketchup::Group)

class ::Sketchup::ComponentInstance
end unless defined?(::Sketchup::ComponentInstance)

module SuTakeoff
  class TestLengthCalculatorBaseline < Minitest::Test

    class FakeEdge < ::Sketchup::Edge
      attr_reader :entityID, :length
      def initialize(id, len)
        @entityID = id
        @length = len
      end
    end

    def test_compute_is_abstract_on_base
      assert_raises(NotImplementedError) { LengthCalculators::Base.new.compute(nil, {}) }
    end

    def test_returns_nil_when_baseline_id_absent
      ctx = {
        baseline_id: nil,
        entities: [FakeEdge.new(1, 5.0)],
        model_unit_to_m: 1.0,
        edge_scale: 1.0
      }
      assert_nil LengthCalculators::Baseline.new.compute(nil, ctx)
    end

    def test_returns_length_when_baseline_matches
      edge = FakeEdge.new(42, 5.0)
      ctx = {
        baseline_id: 42,
        entities: [edge],
        model_unit_to_m: 1.0,
        edge_scale: 1.0
      }
      assert_in_delta 5.0, LengthCalculators::Baseline.new.compute(nil, ctx), 0.001
    end

    def test_returns_nil_when_baseline_id_does_not_match
      edge = FakeEdge.new(1, 5.0)
      ctx = {
        baseline_id: 99,
        entities: [edge],
        model_unit_to_m: 1.0,
        edge_scale: 1.0
      }
      assert_nil LengthCalculators::Baseline.new.compute(nil, ctx)
    end

    def test_applies_model_unit_and_edge_scale
      # 边长 2.0 × model_unit_to_m 0.0254 × edge_scale 2.0 = 0.1016
      edge = FakeEdge.new(7, 2.0)
      ctx = {
        baseline_id: 7,
        entities: [edge],
        model_unit_to_m: 0.0254,
        edge_scale: 2.0
      }
      assert_in_delta 0.1016, LengthCalculators::Baseline.new.compute(nil, ctx), 0.0001
    end
  end
end
