module SuTakeoff
  module Strategies
    # 实例件数：组件映射 counting_method='aggregate' 时使用。
    class InstanceCount < Base
      def initialize
        super(name: :instance_count, method: :count, default_unit: '个')
      end

      def aggregate(items, _ctx)
        items.sum { |i| i.qty.to_f }
      end
    end
  end
end
