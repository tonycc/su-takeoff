module SuTakeoff
  module LengthCalculators
    # 长度算法基类。
    #
    # 每个具体算法实现 compute(entity, ctx) -> Float | nil
    # 返回 nil 表示"本算法不适用，请尝试下一个算法"（供 Chained 用）。
    #
    # ctx 包含：
    #   entities: definition 内子实体集合（Sketchup::Entities 或 array）
    #   edges: 已应用完整实例变换的边数组 [{ dkey:, len:, entity_id:, persistent_id: }, ...]
    #   baseline_id: AttrDict 中的 entityID / persistent_id
    #   edge_scale / model_unit_to_m: 仅供旧调用兼容
    #   volume_m3: 测试支持显式给体积，绕过 entity.volume
    #   debug: 是否输出调试日志
    class Base
      def compute(_entity, _ctx)
        raise NotImplementedError, "#{self.class}#compute must be implemented"
      end
    end
  end
end
