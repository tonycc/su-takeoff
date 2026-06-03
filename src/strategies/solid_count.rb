module SuTakeoff
  module Strategies
    # 容器级件数：标签或图层规则命中 :count 时使用。
    class SolidCount < Base
      def initialize(name: :solid_count, match_rules: {})
        super(name: name, method: :count, default_unit: '个', match_rules: match_rules)
      end

      def aggregate(items, _ctx)
        items.sum { |i| (i.qty_count || i.qty || 0).to_f }
      end
    end
  end
end
