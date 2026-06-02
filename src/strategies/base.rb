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
    #   - matches?(item, context): 是否匹配此 item / context（用于自动决议）
    class Base
      attr_reader :name, :method, :default_unit, :match_rules

      def initialize(name:, method:, default_unit:, match_rules: {})
        @name = name
        @method = method
        @default_unit = default_unit
        @match_rules = match_rules || {}
      end

      # 是否匹配此 item / context（用于自动决议）。
      # match_rules 支持：
      #   definition_name_includes: [String, ...] —— 组件定义名含任一关键字
      #   definition_name_pattern: String/Regexp —— 正则匹配
      #   layer: [String, ...] —— 图层名精确匹配
      #   unit: [String, ...] —— mapping 表中 unit 匹配
      # 无规则的策略不自动匹配，返回 false。
      def matches?(item, context = {})
        return false unless any_rule?
        matches_definition_name?(context) ||
          matches_layer?(item) ||
          matches_unit?(context)
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

      private

      def any_rule?
        @match_rules && !@match_rules.empty?
      end

      def matches_definition_name?(context)
        name = context[:definition_name]
        return false unless name && !name.empty?
        if (kws = @match_rules[:definition_name_includes])
          return true if kws.any? { |k| name.include?(k) }
        end
        if (pat = @match_rules[:definition_name_pattern])
          re = pat.is_a?(Regexp) ? pat : Regexp.new(pat.to_s)
          return true if name =~ re
        end
        false
      end

      def matches_layer?(item)
        layers = @match_rules[:layer]
        return false unless layers && item && item.layer_name
        layers.include?(item.layer_name)
      end

      def matches_unit?(context)
        units = @match_rules[:unit]
        return false unless units && context[:unit]
        units.include?(context[:unit])
      end
    end
  end
end
