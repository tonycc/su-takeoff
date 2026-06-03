module SuTakeoff
  module LengthCalculators
    # 按长度分桶累加：识别"重复段"建模的路径长度。
    #
    # 适用：3D 虚线渲染的电线/管材，每段虚段被重复画多次
    # （如 24 个虚段同长度 3.30m 叠加 → 真实路径段长度仍是 3.30m）。
    #
    # 算法：
    #   1. 过滤极短边（< MIN_LENGTH，默认 5mm）—— 排除虚点装饰
    #   2. 按长度排序，相邻差 ≤ BUCKET_TOLERANCE（默认 5%）的边视为同段
    #   3. 每桶取最大值代表该段，累加所有桶
    #
    # 例：边 [0.001, 0.001, 3.30, 3.30, 3.30, 1.57, 1.57, 0.85] →
    #     过滤 → [3.30, 3.30, 3.30, 1.57, 1.57, 0.85] →
    #     分桶 [3.30, 1.57, 0.85] →
    #     和 = 5.72m
    class SegmentedPath < Base
      MIN_LENGTH = 0.005       # 5mm 以下忽略（虚点装饰边）
      BUCKET_TOLERANCE = 0.05  # 5% 差异内视为同段

      def compute(_entity, ctx)
        edges = ctx[:edges] || []
        return nil if edges.empty?
        significant = edges.map { |e| e[:len].to_f }
                           .select { |l| l >= MIN_LENGTH }
                           .sort
        return nil if significant.empty?

        buckets = group_by_length(significant)
        buckets.map(&:max).sum.round(4)
      end

      private

      # 按长度排序后，相邻差 ≤ tolerance 的归同桶。
      def group_by_length(sorted_lengths)
        buckets = []
        current = [sorted_lengths.first]
        sorted_lengths[1..].each do |len|
          base = current.first
          if (len - base) / base <= BUCKET_TOLERANCE
            current << len
          else
            buckets << current
            current = [len]
          end
        end
        buckets << current
        buckets
      end
    end
  end
end
