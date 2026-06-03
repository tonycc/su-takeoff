module SuTakeoff
  module Strategies
    # 实例件数：组件映射 counting_method='aggregate' 时使用。
    class InstanceCount < Base
      def initialize(name: :instance_count, match_rules: {})
        super(name: name, method: :count, default_unit: '个', match_rules: match_rules)
      end

      def aggregate(items, _ctx)
        items.sum { |i| i.qty.to_f }
      end
    end
  end
end
