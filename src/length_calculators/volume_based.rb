module SuTakeoff
  module LengthCalculators
    # Solid 体积法：volume / 截面高 / 截面厚 = 长度。
    # 需要至少 2 个 ≥4 边的"截面候选"方向组（边长 0.001~0.1m）。
    # 不适用时返回 nil（让 Chained 尝试下一个算法）。
    class VolumeBased < Base
      # 截面候选边的长度范围（米）
      CROSS_SECTION_MIN_M = 0.001  # 1mm，排除圆柱面细分弧边
      CROSS_SECTION_MAX_M = 0.1    # 截面边须严格小于 10cm（与原 Scanner 行为一致）

      def compute(entity, ctx)
        vol_m3 = resolve_volume(entity, ctx)
        return nil unless vol_m3 && vol_m3 > 0

        edges = ctx[:edges] || []
        cross_sections = find_cross_section_candidates(edges)
        return nil if cross_sections.size < 2

        h_m, t_m = cross_sections[0], cross_sections[1]
        (vol_m3 / h_m / t_m).round(4)
      end

      private

      # 体积换算：测试通过 ctx[:volume_m3] 直接给体积绕过 SU API；
      # 生产用 entity.volume × in³→m³ × scale³。
      def resolve_volume(entity, ctx)
        return ctx[:volume_m3] if ctx[:volume_m3]
        return nil unless entity.respond_to?(:volume) &&
                          entity.volume.is_a?(Numeric) &&
                          entity.volume > 0
        entity.volume * 1.6387e-5 * (ctx[:scale] || 1.0)**3
      end

      # 返回截面候选的最长边数组（升序的前 N 个）。
      def find_cross_section_candidates(edges)
        groups = edges.group_by { |e| e[:dkey] }
        group_info = groups.map { |dkey, es|
          [dkey, es.map { |e| e[:len] }.max, es.size]
        }.sort_by { |_, m, _| m }
        meaningful = group_info.select { |_, _, cnt| cnt >= 4 }
        meaningful.select { |_, m, _| m >= CROSS_SECTION_MIN_M && m < CROSS_SECTION_MAX_M }
                  .map { |_, m, _| m }
      end
    end
  end
end
