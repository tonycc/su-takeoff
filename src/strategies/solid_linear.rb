module SuTakeoff
  module Strategies
    # 容器级长度：标签或图层规则命中 :length 时使用（默认线材策略）。
    # emit_from_container 在 Stage 2 接入 LengthCalculator 后完整实现。
    class SolidLinear < Base
      def initialize
        super(name: :solid_linear, method: :length, default_unit: 'm')
      end

      def aggregate(items, _ctx)
        items.sum { |i| (i.qty_length || 0).to_f }
      end
    end
  end
end
