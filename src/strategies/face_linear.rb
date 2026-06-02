module SuTakeoff
  module Strategies
    # 面级线材策略：用于窄长面（如启发判定为线材的踢脚线面）。
    # 不从容器 emit，由 Scanner 正常收集子面后累加。
    class FaceLinear < Base
      def initialize
        super(name: :face_linear, method: :length, default_unit: 'm')
      end

      def aggregate(items, _ctx)
        items.sum { |i| (i.qty_length || i.height || 0).to_f }
      end
    end
  end
end
