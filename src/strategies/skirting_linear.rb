require_relative '../length_calculators/base'
require_relative '../length_calculators/edge_based'

module SuTakeoff
  module Strategies
    # 踢脚线专用策略：强制用 EdgeBased（绕墙一圈累加），不走 baseline / volume 算法。
    # 自动匹配：组件定义名含"踢脚"/"skirting"，或图层名为"踢脚线"。
    class SkirtingLinear < Base
      def initialize
        super(
          name: :skirting_linear,
          method: :length,
          default_unit: 'm',
          match_rules: {
            definition_name_includes: ['踢脚', 'skirting'],
            layer: ['踢脚线']
          }
        )
        @calculator = LengthCalculators::EdgeBased.new
      end

      def aggregate(items, _ctx)
        items.sum { |i| (i.qty_length || 0).to_f }
      end

      # 暴露给 Scanner，强制用 EdgeBased
      def compute_length(entity, ctx)
        @calculator.compute(entity, ctx)
      end
    end
  end
end
