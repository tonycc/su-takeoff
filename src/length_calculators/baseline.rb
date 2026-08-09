module SuTakeoff
  module LengthCalculators
    # 优先使用用户在 AttrDict 标注的 baseline_id 边长度。
    # 找不到 baseline_id 或对应边时返回 nil（让 Chained 尝试下一个算法）。
    class Baseline < Base
      def compute(_entity, ctx)
        baseline_id = ctx[:baseline_id]
        return nil unless baseline_id

        # Scanner 已把嵌套变换应用到边端点，优先使用预计算的米制长度。
        parsed = Array(ctx[:edges]).find do |candidate|
          candidate[:entity_id].to_s == baseline_id.to_s ||
            candidate[:persistent_id].to_s == baseline_id.to_s
        end
        return parsed[:len].to_f if parsed

        edges = ctx[:entities] || []
        edge = find_edge_by_id(edges, baseline_id.to_i)
        return nil unless edge
        scale = (ctx[:edge_scale] || 1.0).to_f
        length = edge.length
        return length.to_m.to_f * scale if length.respond_to?(:to_m)

        # 仅为脱离 SketchUp 的旧调用兼容；生产 Length 对象不使用显示单位系数。
        length.to_f * (ctx[:model_unit_to_m] || 0.0254).to_f * scale
      end

      private

      # 递归查找指定 entityID 的边（穿透 Group / ComponentInstance）。
      def find_edge_by_id(entities, target_id)
        entities.each do |e|
          return e if e.is_a?(Sketchup::Edge) && e.entityID == target_id
          if e.is_a?(Sketchup::Group)
            found = find_edge_by_id(e.entities, target_id)
            return found if found
          elsif e.is_a?(Sketchup::ComponentInstance)
            found = find_edge_by_id(e.definition.entities, target_id)
            return found if found
          end
        end
        nil
      end
    end
  end
end
