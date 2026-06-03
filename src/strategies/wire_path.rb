require_relative '../length_calculators/segmented_path'

module SuTakeoff
  module Strategies
    # 电线/管材专用策略：强制用 SegmentedPath（按长度分桶）算法。
    #
    # 解决问题：3D 虚线渲染建模的电线（每段虚段画多次叠加），
    # 默认 Chained (Baseline → VolumeBased → EdgeBased) 会把虚点装饰的
    # 1.3mm 装饰边当截面 → VolumeBased 算出错误的超大长度。
    #
    # SegmentedPath 通过"过滤短边 + 长度分桶"提取真实路径段长度。
    # 自动匹配：组件定义名含"电线/电敷线/电管/管材/导线/wire/cable/pipe"等关键字。
    class WirePath < SolidLinear
      DEFAULT_MATCH_RULES = {
        definition_name_includes: [
          '电线', '电敷线', '电管', '电缆', '金属线', '导线', '数据线', '网线', '信号线',
          '线管', 'PVC管', '镀锌管', '管材', '管道',
          'wire', 'cable', 'pipe', 'conduit'
        ]
      }.freeze

      def initialize(name: :wire_path, match_rules: DEFAULT_MATCH_RULES)
        super(name: name, match_rules: match_rules)
        @calculator = LengthCalculators::SegmentedPath.new
      end

      def aggregate(items, _ctx)
        items.sum { |i| (i.qty_length || 0).to_f }
      end

      # 暴露给 Scanner，强制用 SegmentedPath（跳过 Chained 的 VolumeBased 误判）
      def compute_length(entity, ctx)
        @calculator.compute(entity, ctx)
      end
    end
  end
end
