module SuTakeoff
  # Calculator 只负责两件事：
  #   1. 薄板去重（水平楼板 + 竖直薄板）
  #   2. 走 Policy 决议每个 item 的计量方式
  #
  # 不再做"按 (space, part, material) 聚合"——产品已删除该视图。
  # 量纲累加、洞口扣减、单位选择都交给消费方（WorkbenchPresenter）。
  class Calculator
    # 两个同材质水平面，面积近似且 z_center 接近，视为薄板的两面（楼板/天花板）。
    SLAB_AREA_TOLERANCE = 0.02      # 2% area diff
    SLAB_Z_TOLERANCE_M = 0.15       # 15 cm thickness max

    # 竖直薄板（散面建模的踢脚线/装饰条）背靠背两面的配对阈值。
    VERTICAL_SLAB_AREA_TOLERANCE = 0.02
    VERTICAL_SLAB_GAP_M = 0.05      # 5 cm 薄板厚度

    def initialize(mapping, component_mapping = nil, policy: nil)
      @mapping = mapping
      @component_mapping = component_mapping
      @policy = policy
    end

    attr_accessor :policy

    # 几何决议：dedup + Policy 决议。
    # 返回 [{ item: ScanItem, method: Symbol, source: Symbol, unit: String,
    #         strategy_name: Symbol }, ...]
    # —— 跳过 nil 材质和 :skip 决议；items 顺序保留。
    def compute_geometry_only(items, _openings = nil)
      # 清除上次调用写入的缓存，确保 settings 变更后重新决议
      items.each { |it| it.resolved_method = nil; it.source = nil; it.strategy_name = nil }
      items = dedup_thin_slabs(items)
      # 全量决议并缓存，供 dedup_vertical_slabs 直接读取
      items.each { |it| cache_resolve(it) unless it.su_material.nil? }
      items = dedup_vertical_slabs(items)
      out = []
      items.each do |item|
        next if item.su_material.nil?
        next unless item.resolved_method
        next if item.resolved_method == :skip
        out << {
          item: item,
          method: item.resolved_method,
          source: item.source,
          unit: unit_for(item, item.resolved_method, item.source),
          strategy_name: item.strategy_name
        }
      end
      out
    end

    # Returns the unmapped material names from items
    def unmapped_materials(items)
      @mapping.unmapped_materials(items.map(&:su_material).compact)
    end

    def self.face_orientation(normal)
      return 'object' if normal.nil? || normal[2].nil?
      z = normal[2].abs
      if z > 0.866  # ~30° from vertical
        normal[2] > 0 ? 'floor' : 'ceiling'
      else
        'wall'
      end
    end

    # Extract room name from the first element of component_path.
    # When the model uses naming prefix convention like "主卧-涂料",
    # the part before the first "-" is the room name.
    def self.extract_space(item)
      raw = item.component_path.first || '未分组'
      raw.include?('-') ? raw.split('-', 2).first : raw
    end

    private

    # 把 Policy 决议结果写入 item.resolved_method / item.source / item.strategy_name
    # （幂等，已缓存则跳过）
    def cache_resolve(item)
      return if item.resolved_method  # 已缓存
      r = resolve_method(item)
      item.resolved_method = r[:method]
      item.source = r[:source]
      item.strategy_name = r[:strategy_name]
    end

    # 决议单个 item 的 method + source + strategy_name + unit。
    # 优先走注入的 Policy；缺失时回到 mapping 兜底 + 未映射启发，保持旧调用兼容。
    def resolve_method(item)
      if @policy
        r = @policy.resolve(item)
        # 启发兜底（policy 决议 :skip + :default）
        if r.method == :skip && r.source == :default
          return geometry_unmapped_fallback(item)
        end
        return {
          method: r.method,
          source: r.source,
          strategy_name: r.strategy && r.strategy.name,
          unit: unit_for(item, r.method, r.source)
        }
      end

      # policy 缺失：mapping 兜底
      record = lookup_record(item)
      if record
        method = item.kind == :instance ? :count : TakeoffPolicy.classify_unit(record.unit)
        strategies = @policy&.strategies || Strategies::Registry.global
        strategy = strategies.default_for(method)
        return {
          method: method,
          source: :mapping,
          strategy_name: strategy && strategy.name,
          unit: unit_for(item, method, :mapping, record)
        }
      end

      geometry_unmapped_fallback(item)
    end

    # 未映射面 item 的兜底判定：长宽比 > 15 视为线材，否则面材。
    def geometry_unmapped_fallback(item)
      is_linear = item.kind == :face && item.width && item.width > 0 &&
                  item.height && (item.height / item.width) > 15
      method = is_linear ? :length : :area
      # 启发线材用 face_linear（含 height fallback），启发面材用 face_area
      strategy_name = is_linear ? :face_linear : :face_area
      {
        method: method,
        source: :heuristic,
        strategy_name: strategy_name,
        unit: method == :length ? 'm' : 'm²'
      }
    end

    # 单位选择：method 决定语义，source/record 决定细节。
    #   :count   → record.unit（个/件/套），缺省回退 item.unit → Registry.default_for(:count)
    #   :length  → mapping 兜底时尊重 record.unit（'m'/'mm' 都可），其他档位用 Registry 默认
    #   :volume  → Registry.default_for(:volume)（'m³'）
    #   :area    → record.unit（m²），缺省回退 item.unit → Registry.default_for(:area)
    def unit_for(item, method, source, record = nil)
      record ||= lookup_record(item)
      strategies = @policy&.strategies || Strategies::Registry.global
      case method
      when :length
        # mapping 兜底时尊重 record.unit（'m'/'mm' 都可），其他档位用 strategy 默认
        if source == :mapping && record && TakeoffPolicy.classify_unit(record.unit) == :length
          record.unit
        else
          strategies.default_for(:length)&.default_unit || 'm'
        end
      when :count
        record&.unit || item.unit || strategies.default_for(:count)&.default_unit || '个'
      when :area
        record&.unit || item.unit || strategies.default_for(:area)&.default_unit || 'm²'
      else
        # :volume :skip 等
        strategies.default_for(method)&.default_unit || ''
      end
    end

    def lookup_record(item)
      if item.kind == :instance
        @component_mapping&.get(item.su_material)
      else
        @mapping.get(item.su_material)
      end
    end

    # ---- 字段读取兜底（仅 dedup 内部使用）----
    def area_qty(item)
      v = item.qty_area
      return v.to_f if v
      (item.qty || 0).to_f
    end

    # Remove the "back side" of thin horizontal slabs.
    #
    # A thin slab (e.g. a floor plate, a ceiling plate, a found-level screed)
    # is modeled as a thin volume with the same material on top and bottom.
    # Naive counting doubles the area — once as floor, once as ceiling.
    #
    # We detect pairs within (space, material) where one face points up,
    # another points down, areas match within SLAB_AREA_TOLERANCE, and their
    # z_centers are within SLAB_Z_TOLERANCE_M. For each pair we keep the
    # face whose orientation matches the slab's vertical position within
    # the space:
    #   - slab in the lower half of the space  -> keep the 'floor' face (top)
    #   - slab in the upper half               -> keep the 'ceiling' face (bottom)
    # This mirrors which side is actually visible to occupants.
    def dedup_thin_slabs(items)
      # Compute per-space vertical midpoint across ALL items in the space,
      # so a slab can be located in its global context rather than against
      # only its own two faces.
      items_by_space = items.group_by { |it| Calculator.extract_space(it) }
      space_z_mid = {}
      items_by_space.each do |sp, sp_items|
        zs = sp_items.map(&:z_center).compact
        next if zs.empty?
        space_z_mid[sp] = (zs.min + zs.max) / 2.0
      end

      grouped = items.group_by { |it| [Calculator.extract_space(it), it.su_material] }
      drop_ids = {}

      grouped.each do |(space, _mat), group|
        next if group.empty?
        mid = space_z_mid[space]
        next unless mid

        ups = group.select { |it| it.normal && it.normal[2] && it.normal[2] > 0.866 }
        downs = group.select { |it| it.normal && it.normal[2] && it.normal[2] < -0.866 }
        matched_down = {}

        next if ups.empty? || downs.empty?

        ups.each do |up|
          pair = downs.find do |dn|
            !matched_down[dn.face_id] &&
              area_qty(up) > 0 &&
              (area_qty(up) - area_qty(dn)).abs / area_qty(up) <= SLAB_AREA_TOLERANCE &&
              (up.z_center - dn.z_center).abs <= SLAB_Z_TOLERANCE_M
          end
          next unless pair

          matched_down[pair.face_id] = true
          slab_z = (up.z_center + pair.z_center) / 2.0
          if slab_z <= mid
            drop_ids[pair.face_id] = true
          else
            drop_ids[up.face_id] = true
          end
        end
      end

      items.reject { |it| drop_ids[it.face_id] }
    end

    # P4: 去掉竖直薄板背靠背的另一面。
    #
    # 散面建模的踢脚线/装饰条常被画成有厚度的薄板（盒子），其长立面是两片
    # 法线相反、面积近似、距离很近（薄板厚度）的面，朴素累加会算两次长度。
    #
    # 配对要求（保守阈值，避免误伤普通墙面）：
    #   - 两面都是竖直面（|normal.z| < 0.5）
    #   - 法线接近反向（dot < -0.95）
    #   - 同 (space, su_material)
    #   - bbox 中心距 ≤ VERTICAL_SLAB_GAP_M（默认 5cm）
    #   - 面积差 ≤ VERTICAL_SLAB_AREA_TOLERANCE（默认 2%）
    #
    # 仅作用于 policy 决议为 :length 的面 —— policy 缺失时直接跳过，行为零变化。
    def dedup_vertical_slabs(items)
      return items unless @policy

      gap_m = vertical_slab_gap
      area_tol = vertical_slab_area_tol

      # 按 (space, su_material) 分组，且只看 method == :length 的竖直面
      candidates = items.select do |it|
        next false unless it.kind == :face
        next false unless it.normal && it.normal[2]
        next false if it.normal[2].abs >= 0.5
        next false unless area_qty(it) > 0
        next false if it.center_x.nil? || it.center_y.nil?
        it.resolved_method == :length
      end
      return items if candidates.size < 2

      grouped = candidates.group_by { |it|
        [Calculator.extract_space(it), it.su_material]
      }
      drop_ids = {}
      matched = {}

      grouped.each do |_, group|
        next if group.size < 2
        # 双重循环找配对（数据量小，不必建空间索引）
        group.each_with_index do |a, i|
          next if matched[a.face_id]
          group[(i + 1)..].each do |b|
            next if matched[b.face_id]
            next unless anti_parallel?(a.normal, b.normal)
            next unless area_close?(area_qty(a), area_qty(b), area_tol)
            dx = a.center_x - b.center_x
            dy = a.center_y - b.center_y
            dz = (a.z_center || 0) - (b.z_center || 0)
            dist = Math.sqrt(dx * dx + dy * dy + dz * dz)
            next if dist > gap_m

            matched[a.face_id] = true
            matched[b.face_id] = true
            # 留 a 删 b（length 累加结果相同；选择固定避免不确定性）
            drop_ids[b.face_id] = true
            break
          end
        end
      end

      items.reject { |it| drop_ids[it.face_id] }
    end

    def anti_parallel?(n1, n2)
      return false unless n1 && n2
      dot = n1[0] * n2[0] + n1[1] * n2[1] + n1[2] * n2[2]
      dot < -0.95
    end

    def area_close?(a, b, tol)
      return false if a <= 0 || b <= 0
      ((a - b).abs / [a, b].max) <= tol
    end

    def vertical_slab_gap
      @policy&.vertical_slab_gap || VERTICAL_SLAB_GAP_M
    end

    def vertical_slab_area_tol
      @policy&.vertical_slab_area_tol || VERTICAL_SLAB_AREA_TOLERANCE
    end
  end
end
