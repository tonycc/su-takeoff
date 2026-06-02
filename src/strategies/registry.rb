module SuTakeoff
  module Strategies
    # 策略注册中心（单例）。
    #
    # 内置策略在插件加载时（main.rb）批量注册。
    # 通过 default_for: 标记每个 method 的默认策略，供未自动匹配命中时兜底。
    class Registry
      class << self
        def register(strategy, default_for: nil)
          @strategies ||= {}
          @defaults   ||= {}
          @strategies[strategy.name] = strategy
          @defaults[default_for] = strategy if default_for
        end

        def get(name)
          @strategies ||= {}
          @strategies[name]
        end

        def default_for(method)
          @defaults ||= {}
          @defaults[method]
        end

        def all
          @strategies ||= {}
          @strategies.values
        end

        # 测试用：重置注册状态
        def reset!
          @strategies = {}
          @defaults = {}
        end
      end
    end
  end
end
