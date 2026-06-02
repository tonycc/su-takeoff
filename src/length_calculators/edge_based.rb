module SuTakeoff
  module LengthCalculators
    # 边线法：各方向取最长边累加（排除截面方向）。
    # 含非方条形检测分支：>5 个 ≥4 边的方向组（圆柱/圆角等）→ 按 5× gap 累加。
    class EdgeBased < Base
      # 与原 Scanner 一致的阈值
      MIN_GROUP_EDGE_COUNT = 4    # 方向组至少 4 条边才计入
      LENGTH_GAP_RATIO = 5        # 长方向 vs 截面方向的 5× gap 判定
      NON_BOX_GROUP_THRESHOLD = 5 # 触发非方条形分支的最少方向组数

      def compute(_entity, ctx)
        edges = ctx[:edges] || []
        return nil if edges.empty?

        dir_groups = edges.group_by { |e| e[:dkey] }
        meaningful_groups = dir_groups.select { |_, es| es.size >= MIN_GROUP_EDGE_COUNT }

        # 分支 1：非方条形几何
        return non_box_aggregate(meaningful_groups) if meaningful_groups.size > NON_BOX_GROUP_THRESHOLD

        # 分支 2：常规边线法
        regular_aggregate(dir_groups)
      end

      private

      # 非方条形：各组最长边降序累加，遇 5× gap 停止
      def non_box_aggregate(meaningful_groups)
        sorted_maxes = meaningful_groups.map { |_, es| es.map { |e| e[:len] }.max }.sort.reverse
        result = sorted_maxes.first || 0
        sorted_maxes.each_cons(2) do |prev, cur|
          break if prev / cur > LENGTH_GAP_RATIO
          result += cur
        end
        result.round(4)
      end

      # 常规：按各方向最长边降序，遇 5× gap 截断（视为截面方向）
      def regular_aggregate(dir_groups)
        group_maxes = dir_groups.map { |dkey, es| [dkey, es.map { |e| e[:len] }.max] }
                                .sort_by { |_, m| -m }
        result = 0.0
        last_max = nil
        group_maxes.each do |_, max|
          if last_max.nil? || (last_max / max) < LENGTH_GAP_RATIO
            result += max
            last_max = max
          else
            break
          end
        end
        result.round(4)
      end
    end
  end
end
