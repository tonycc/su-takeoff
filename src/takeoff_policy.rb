module SuTakeoff
  # 算量策略 —— 4 档优先级链
  #
  #   1. AttributeDictionary（每实例覆盖）  显式 · ScanItem.tags[:method]
  #   2. 图层规则                          显式 · layer_rules[layer_name]
  #   3. 材质映射 unit                     显式 · 由 unit 词表反推
  #   4. 几何启发                          自动 · 弱信号 · 仅当面满足严格条件且前三档均未命中
  #
  # 任意一档命中即返回，下面不再考虑。
  #
  # 不在内部读 PluginState/config.json，而是构造时注入 —— 单元测试可以直接造一个
  # Policy 实例不依赖 SU 运行时。
  class TakeoffPolicy
    ResolveResult = Struct.new(:method, :source, keyword_init: true)

    METHODS = %i[area length volume count skip].freeze

    DEFAULT_LENGTH_UNITS = %w[m mm cm dm km].freeze
    DEFAULT_COUNT_UNITS  = %w[个 件 套 组 台 只].freeze
    DEFAULT_VOLUME_UNITS = %w[m³ m3 L 立方].freeze

    DEFAULT_MIN_ASPECT      = 15
    DEFAULT_MAX_SHORT_EDGE  = 0.2  # m

    # mapping: MaterialMapping 实例（用于 unit 兜底）
    # layer_rules: { '线条' => :length, '砌体' => :volume, ... }
    #              值可以是 String 或 Symbol，内部归一为 Symbol
    # heuristics_enabled: 启发式开关
    # length_units / count_units / volume_units: unit 词表（nil 用默认）
    # thresholds: { linear_min_aspect_ratio:, linear_max_short_edge_m: }
    def initialize(mapping:, layer_rules: {}, heuristics_enabled: true,
                   length_units: nil, count_units: nil, volume_units: nil,
                   tag_defs: {}, thresholds: {})
      @mapping = mapping
      @layer_rules = normalize_layer_rules(layer_rules)
      @tag_defs = tag_defs || {}
      @heuristics = heuristics_enabled
      @length_units = (length_units && !length_units.empty?) ? length_units : DEFAULT_LENGTH_UNITS
      @count_units  = (count_units  && !count_units.empty?)  ? count_units  : DEFAULT_COUNT_UNITS
      @volume_units = (volume_units && !volume_units.empty?) ? volume_units : DEFAULT_VOLUME_UNITS
      @min_aspect      = thresholds[:linear_min_aspect_ratio] || DEFAULT_MIN_ASPECT
      @max_short_edge  = thresholds[:linear_max_short_edge_m] || DEFAULT_MAX_SHORT_EDGE
    end

    # 面级判定。返回 ResolveResult。
    def resolve(item)
      # instance：永远按整件统计，绕过 4 档策略
      if item.kind == :instance
        return ResolveResult.new(method: :count, source: :mapping)
      end

      # P3: 容器级整体量取已固化为 ScanItem.kind，Calculator 直接信任。
      if item.kind == :solid
        return ResolveResult.new(method: :volume, source: :layer)
      end
      if item.kind == :linear_solid
        return ResolveResult.new(method: :length, source: :layer)
      end
      if item.kind == :count_solid
        return ResolveResult.new(method: :count, source: :layer)
      end

      # 1. AttrDict 覆盖
      if item.tags && (m = item.tags[:method])
        sym = m.to_sym
        return ResolveResult.new(method: sym, source: :attr) if METHODS.include?(sym)
      end

      # 2. 图层规则
      if item.layer_name && (m = @layer_rules[item.layer_name])
        return ResolveResult.new(method: m, source: :layer)
      end

      # 3. 材质映射 unit
      if @mapping && (record = @mapping.get(item.su_material))
        return ResolveResult.new(method: method_from_unit(record.unit), source: :mapping)
      end

      # 4. 启发式（弱信号，仅产生待确认建议；仅在没有显式配置时触发）
      if @heuristics && linear_face?(item)
        return ResolveResult.new(method: :length, source: :heuristic)
      end

      ResolveResult.new(method: :skip, source: :default)
    end

    # 容器级判定（Scanner 在 ComponentInstance/Group 分支调用）。
    # :length / :volume / :count 返回 method 让 Scanner 整体量取；
    # :area 返回 nil 让 Scanner 正常下钻子面（面需要逐个扣洞口）。
    def resolve_container(layer_name:, attr_method: nil)
      if attr_method
        sym = attr_method.to_s.to_sym
        return sym if %i[length volume count].include?(sym)
      end
      if layer_name && (m = @layer_rules[layer_name])
        return m if %i[length volume count].include?(m)
      end
      nil
    end

    # 某图层是否配置了任何算量规则（供 Scanner 决定是否传播容器图层到子面）
    def layer_has_rule?(layer_name)
      return false unless layer_name
      @layer_rules.key?(layer_name)
    end

    # 某标记是否已定义（供 Scanner 决定是否传播容器标记到子面）
    def tag_has_def?(tag_name)
      return false unless tag_name
      @tag_defs.key?(tag_name)
    end

    # 将单位转为计量方式（供 Scanner 传播组件映射的 unit → method）
    def method_for_unit(unit)
      return :length if @length_units.include?(unit)
      return :volume if @volume_units.include?(unit)
      return :count  if @count_units.include?(unit)
      :area
    end

    private

    # 严格的几何启发：必须是垂直面 + 横向窄长
    #   - |normal.z| < 0.5    排除水平面（地/顶不该被判线材）
    #   - width <= 0.2 m      排除宽面（窗台板那种短粗形状）
    #   - height/width > 15   长宽比下限
    def linear_face?(item)
      return false unless item.kind == :face
      return false if item.normal.nil?
      nz = (item.normal[2] || 0).abs
      return false if nz > 0.5
      return false if item.width.nil? || item.width <= 0
      return false if item.width > @max_short_edge
      return false if item.height.nil? || item.height <= 0
      (item.height / item.width) > @min_aspect
    end

    def method_from_unit(unit)
      return :length if @length_units.include?(unit)
      return :volume if @volume_units.include?(unit)
      return :count  if @count_units.include?(unit)
      :area
    end

    def normalize_layer_rules(rules)
      out = {}
      (rules || {}).each do |k, v|
        next if k.nil? || v.nil?
        sym = v.to_s.to_sym
        next unless METHODS.include?(sym)
        out[k.to_s] = sym
      end
      out
    end
  end
end
