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

          # 同名重复：warn（允许覆盖，方便插件 reload 和 Loader 自定义策略覆盖内置）
          if @strategies.key?(strategy.name) && @strategies[strategy.name] != strategy
            warn "[SuTakeoff::Strategies::Registry] strategy :#{strategy.name} re-registered"
          end
          @strategies[strategy.name] = strategy

          # 同 method 默认覆盖：raise（这是配置 bug，应早暴露）
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
