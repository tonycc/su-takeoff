module SuTakeoff
  module Strategies
    # 内置策略注册器。
    # PluginState 初始化时调用 register_all! 一次（Task 1.6 接入）。
    module Builtin
      def self.register_all!
        Registry.register(FaceArea.new,       default_for: :area)
        Registry.register(FaceLinear.new)
        Registry.register(InstanceCount.new)
        Registry.register(SolidVolume.new,    default_for: :volume)
        Registry.register(SolidLinear.new,    default_for: :length)
        Registry.register(SolidCount.new,     default_for: :count)
        Registry.register(Skip.new,           default_for: :skip)
      end
    end
  end
end
