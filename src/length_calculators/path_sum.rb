module SuTakeoff
  module LengthCalculators
    # 路径累加：直接 sum 所有 Edge 长度，不分方向、不取最长、不除任何系数。
    # 适用于：纯边线组件（电线/管道路径折线），或边线数据已经是"逐段路径"形式。
    #
    # ctx 仅需 :edges（同 EdgeBased/VolumeBased 的格式：[{ len:, dkey:, ... }, ...]）。
    class PathSum < Base
      def compute(_entity, ctx)
        edges = ctx[:edges] || []
        return nil if edges.empty?
        total = edges.sum { |e| e[:len].to_f }
        return nil if total <= 0
        total.round(4)
      end
    end
  end
end
