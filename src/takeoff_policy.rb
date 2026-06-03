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
    # Stage 3: ResolveResult 内部 strategy 是 Strategies::Base 对象。
    # method 字段由 strategy.method 派生（向后兼容）。
    ResolveResult = Struct.new(:strategy, :source, keyword_init: true) do
      def method
        strategy && strategy.method
      end
    end

    METHODS = %i[area length volume count skip].freeze

    # 单位 → 计量方式启发（直接匹配单位字符串，不需要额外配置）
    LENGTH_UNITS = %w[m mm cm dm km].freeze
    COUNT_UNITS  = %w[个 件 套 组 台 只 根 把 支 块 条 片 张 卷 桶 包 箱 瓶 罐 袋 盒].freeze
    # 体积：含 ³ / 3 / L / 立方 等

    DEFAULT_MIN_ASPECT           = 15
    DEFAULT_MAX_SHORT_EDGE       = 0.2  # m
    DEFAULT_VERTICAL_SLAB_GAP    = 0.05 # m
    DEFAULT_VERTICAL_SLAB_TOL    = 0.02

    attr_reader :vertical_slab_gap, :vertical_slab_area_tol, :strategies

    # mapping: MaterialMapping 实例（用于 unit 兜底）
    # layer_rules: { '线条' => :length, '砌体' => :volume, ... }
    #              值可以是 String 或 Symbol，内部归一为 Symbol
    # heuristics_enabled: 启发式开关
    # thresholds: { linear_min_aspect_ratio:, linear_max_short_edge_m: }
    # strategies: Strategies::Registry 实例；不传则使用 Registry.global
    def initialize(mapping:, layer_rules: {}, heuristics_enabled: true,
                   tag_defs: {}, thresholds: {}, strategies: nil)
      @mapping = mapping
      @layer_rules = normalize_layer_rules(layer_rules)
      @tag_defs = tag_defs || {}
      @heuristics = heuristics_enabled
      @min_aspect      = thresholds[:linear_min_aspect_ratio] || DEFAULT_MIN_ASPECT
      @max_short_edge  = thresholds[:linear_max_short_edge_m] || DEFAULT_MAX_SHORT_EDGE
      @vertical_slab_gap     = thresholds[:vertical_slab_gap_m] || DEFAULT_VERTICAL_SLAB_GAP
      @vertical_slab_area_tol = thresholds[:vertical_slab_area_tolerance] || DEFAULT_VERTICAL_SLAB_TOL
      @strategies = strategies || Strategies::Registry.global
    end

    # 面级判定。返回 ResolveResult（携带 Strategy 对象）。
    def resolve(item)
      # instance：永远按整件统计，绕过 4 档策略
      if item.kind == :instance
        return result_for(:count, :mapping)
      end

      # P3: 容器级整体量取已固化为 ScanItem.kind，Calculator 直接信任。
      if item.kind == :solid
        return result_for(:volume, :layer)
      end
      if item.kind == :linear_solid
        return result_for(:length, :layer)
      end
      if item.kind == :count_solid
        return result_for(:count, :layer)
      end

      # 1. AttrDict 覆盖
      if item.tags && (m = item.tags[:method])
        sym = m.to_sym
        return result_for(sym, :attr) if METHODS.include?(sym)
      end

      # 2. 图层规则
      if item.layer_name && (m = @layer_rules[item.layer_name])
        return result_for(m, :layer)
      end

      # 3. 材质映射 unit（+ 3.5 自动匹配同 method 下的专用策略）
      if @mapping && (record = @mapping.get(item.su_material))
        hint_method = method_from_unit(record.unit)
        if (matched = auto_match_strategy(item, hint_method, record))
          return ResolveResult.new(strategy: matched, source: :auto_match)
        end
        return result_for(hint_method, :mapping)
      end

      # 4. 启发式（弱信号，仅产生待确认建议；仅在没有显式配置时触发）
      if @heuristics && linear_face?(item)
        # 启发判定线材：用 face_linear（含 height fallback）而非 solid_linear
        strategy = @strategies.get(:face_linear) || @strategies.default_for(:length)
        return ResolveResult.new(strategy: strategy, source: :heuristic)
      end

      result_for(:skip, :default)
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

    # 单位 → 计量方式（供 Scanner 传播组件映射的 unit → method）
    def method_for_unit(unit)
      self.class.classify_unit(unit)
    end

    # 单位字符串直接推导计量方式，无需分类配置列表。
    def self.classify_unit(unit)
      return :area   if unit.nil? || unit.empty?
      return :volume if unit.match?(/[³3]/) || unit == 'L' || unit == '立方'
      return :count  if COUNT_UNITS.include?(unit)
      return :length if LENGTH_UNITS.include?(unit)
      :area
    end

    private

    # 根据 method 查 default strategy 构造 ResolveResult。
    def result_for(method, source)
      strategy = @strategies.default_for(method)
      ResolveResult.new(strategy: strategy, source: source)
    end

    # 遍历同 method 下的非默认策略，第一个 matches? 命中的返回。
    # 跳过 default_for(method) 那个（避免默认策略反复命中自己）。
    def auto_match_strategy(item, hint_method, record)
      context = build_match_context(item, hint_method, record)
      default = @strategies.default_for(hint_method)
      @strategies.all.each do |s|
        next if s.method != hint_method
        next if default && s.name == default.name
        return s if s.matches?(item, context)
      end
      nil
    end

    def build_match_context(item, hint_method, record)
      def_name = item.component_path && item.component_path.last
      {
        definition_name: def_name,
        unit: record && record.unit,
        hint_method: hint_method
      }
    end

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
      self.class.classify_unit(unit)
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
