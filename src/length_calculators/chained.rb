module SuTakeoff
  module LengthCalculators
    # 按顺序尝试一组算法，返回第一个 non-nil 结果。
    # 默认顺序：Baseline → VolumeBased → EdgeBased。
    class Chained < Base
      def initialize(*calculators)
        @calculators = calculators
      end

      def compute(entity, ctx)
        @calculators.each do |calc|
          result = calc.compute(entity, ctx)
          return result if result
        end
        nil
      end
    end
  end
end
