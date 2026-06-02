module SuTakeoff
  module Strategies
    # 容器级体积：标签或图层规则命中 :volume 时使用。
    class SolidVolume < Base
      def initialize
        super(name: :solid_volume, method: :volume, default_unit: 'm³')
      end

      def aggregate(items, _ctx)
        items.sum { |i| (i.qty_volume || 0).to_f }
      end
    end
  end
end
