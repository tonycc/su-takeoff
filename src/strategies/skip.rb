module SuTakeoff
  module Strategies
    # 占位策略：Policy 决议为 :skip 时返回此对象。
    # 主流程在拿到 Skip 策略时直接过滤，不调用 aggregate。
    class Skip < Base
      def initialize
        super(name: :skip, method: :skip, default_unit: '')
      end

      def aggregate(_items, _ctx)
        0
      end
    end
  end
end
