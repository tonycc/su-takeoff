module SuTakeoff
  module Strategies
    # 算量策略抽象基类。
    #
    # 每个具体策略封装一种"算量方式"，包含：
    #   - method: 量纲（:area/:length/:volume/:count/:skip）
    #   - default_unit: 显示单位字符串
    #   - emit_from_container(entity, ctx): 容器级策略从 SU 实体产出 ScanItem
    #     （面级策略返回 nil，由 Scanner 走默认的收集子面流程）
    #   - aggregate(items, ctx): Presenter 用，把多条 ScanItem 累加成最终量
    class Base
      attr_reader :name, :method, :default_unit

      def initialize(name:, method:, default_unit:)
        @name = name
        @method = method
        @default_unit = default_unit
      end

      # Scanner 侧：从一个 ComponentInstance/Group 产出一条 ScanItem。
      # 面级策略不需要从容器 emit，返回 nil（Scanner 走默认下钻流程）。
      def emit_from_container(_entity, _ctx)
        nil
      end

      # Presenter 侧：把同 (entity_id, su_material) 下的 items 累加成最终量。
      # ctx 提供辅助数据：opening_area_by_face 等。
      def aggregate(_items, _ctx)
        raise NotImplementedError, "#{self.class}#aggregate must be implemented"
      end
    end
  end
end
