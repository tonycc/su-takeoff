module SuTakeoff
  module Strategies
    # 策略注册中心。
    #
    # 用法：
    #   - 生产代码：通过 PluginState 启动时注册到全局 Registry.global，
    #     Policy 默认使用 Registry.global，无需显式传参。
    #   - 测试：可以 Registry.new 创建独立实例，传给 TakeoffPolicy.new(strategies:)
    #     避免污染全局；不需要 teardown 恢复。
    #
    # 类方法 register/get/default_for/all/reset! 委托给 global，向后兼容。
    class Registry
      def initialize
        @strategies = {}
        @defaults = {}
      end

      def register(strategy, default_for: nil)
        if @strategies.key?(strategy.name) && @strategies[strategy.name] != strategy
          warn "[SuTakeoff::Strategies::Registry] strategy :#{strategy.name} re-registered"
        end
        @strategies[strategy.name] = strategy

        if default_for
          existing = @defaults[default_for]
          if existing && existing != strategy
            raise ArgumentError,
                  "default strategy for :#{default_for} already set to :#{existing.name}, " \
                  "cannot override with :#{strategy.name}"
          end
          @defaults[default_for] = strategy
        end
      end

      def get(name)
        @strategies[name]
      end

      def default_for(method)
        @defaults[method]
      end

      def all
        @strategies.values
      end

      # 全局默认实例 + 类方法委托
      class << self
        def global
          @global ||= new
        end

        def register(strategy, default_for: nil)
          global.register(strategy, default_for: default_for)
        end

        def get(name)
          global.get(name)
        end

        def default_for(method)
          global.default_for(method)
        end

        def all
          global.all
        end

        # 测试用：重置 global 实例（替换为新空实例）
        def reset!
          @global = new
        end
      end
    end
  end
end
