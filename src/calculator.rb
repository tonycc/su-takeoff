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
    HORIZONTAL_INDEX_CELL_M = 0.1

    def initialize(policy: nil)
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
      # 先决议，再按量纲去重，避免显式标签在 Policy 生效前被同尺寸面误删。
      items.each { |it| cache_resolve(it) unless it.su_material.nil? }
      items = dedup_thin_slabs(items)
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
    # 优先走注入的 Policy；policy 缺失时直接走启发兜底（保持旧调用兼容）。
    def resolve_method(item)
      if @policy
        r = @policy.resolve(item)
        # 普通未映射面仍按面积计量，这是面几何的确定性默认值；只有 Policy
        # 严格命中的窄长竖直面才标为 heuristic/length。
        return geometry_default_area(item) if r.method == :skip && r.source == :default
        return {
          method: r.method,
          source: r.source,
          strategy_name: r.strategy && r.strategy.name,
          unit: unit_for(item, r.method, r.source)
        }
      end

      geometry_unmapped_fallback(item)
    end

    def geometry_default_area(_item)
      {
        method: :area,
        source: :default,
        strategy_name: :face_area,
        unit: 'm²'
      }
    end

    # 仅供没有 Policy 的旧调用兼容。注入 Policy 后必须尊重其 :skip，
    # 否则会绕过 heuristics_enabled、面朝向和用户阈值。
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

    # 单位选择：method 决定语义。
    #   :count   → item.unit（个/件/套），缺省回退 Registry.default_for(:count)
    #   :length  → Registry.default_for(:length)（'m'）
    #   :volume  → Registry.default_for(:volume)（'m³'）
    #   :area    → item.unit（m²），缺省回退 Registry.default_for(:area)
    def unit_for(item, method, _source)
      strategies = @policy&.strategies || Strategies::Registry.global
      case method
      when :length
        strategies.default_for(:length)&.default_unit || 'm'
      when :count
        item.unit || strategies.default_for(:count)&.default_unit || '个'
      when :area
        item.unit || strategies.default_for(:area)&.default_unit || 'm²'
      else
        # :volume :skip 等
        strategies.default_for(method)&.default_unit || ''
      end
    end

    # ---- 字段读取兜底（仅 dedup 内部使用）----
    def area_qty(item)
      v = item.qty_area
      return v.to_f if v
      (item.qty || 0).to_f
    end

    def occurrence_key(item)
      item.respond_to?(:face_occurrence_key) ? item.face_occurrence_key : item.face_id
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
      items_by_space = items.group_by do |it|
        [Array(it.component_path_ids), Calculator.extract_space(it)]
      end
      space_z_mid = {}
      items_by_space.each do |sp, sp_items|
        zs = sp_items.map(&:z_center).compact
        next if zs.empty?
        space_z_mid[sp] = (zs.min + zs.max) / 2.0
      end

      grouped = items.group_by do |it|
        [Array(it.component_path_ids), Calculator.extract_space(it), it.su_material, it.resolved_method]
      end
      drop_ids = {}

      grouped.each do |(path_ids, space, _mat, _method), group|
        next if group.empty?
        mid = space_z_mid[[path_ids, space]]
        next unless mid

        ups = group.select do |it|
          it.resolved_method == :area && it.normal && it.normal[2] && it.normal[2] > 0.866
        end
        downs = group.select do |it|
          it.resolved_method == :area && it.normal && it.normal[2] && it.normal[2] < -0.866
        end
        matched_down = {}

        next if ups.empty? || downs.empty?

        down_index = Hash.new { |hash, key| hash[key] = [] }
        downs.each { |down| down_index[horizontal_index_key(down)] << down }

        ups.each do |up|
          pair = find_indexed_candidate(horizontal_neighbor_keys(up), down_index) do |dn|
            !matched_down[occurrence_key(dn)] && area_close?(area_qty(up), area_qty(dn), SLAB_AREA_TOLERANCE) &&
              (up.z_center - dn.z_center).abs <= SLAB_Z_TOLERANCE_M && centers_overlap?(up, dn)
          end
          next unless pair

          matched_down[occurrence_key(pair)] = true
          slab_z = (up.z_center + pair.z_center) / 2.0
          if slab_z <= mid
            drop_ids[occurrence_key(pair)] = true
          else
            drop_ids[occurrence_key(up)] = true
          end
        end
      end

      items.reject { |it| drop_ids[occurrence_key(it)] }
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
        [Array(it.component_path_ids), Calculator.extract_space(it), it.su_material]
      }
      drop_ids = {}
      matched = {}

      grouped.each do |_, group|
        next if group.size < 2
        spatial_index = Hash.new { |hash, key| hash[key] = [] }
        group.each do |item|
          next if matched[occurrence_key(item)]
          pair = find_indexed_candidate(spatial_neighbor_keys(item, gap_m), spatial_index) do |candidate|
            !matched[occurrence_key(candidate)] &&
              anti_parallel?(item.normal, candidate.normal) &&
              area_close?(area_qty(item), area_qty(candidate), area_tol) &&
              center_distance(item, candidate) <= gap_m
          end
          if pair
            matched[occurrence_key(pair)] = true
            matched[occurrence_key(item)] = true
            drop_ids[occurrence_key(item)] = true
          else
            spatial_index[spatial_index_key(item, gap_m)] << item
          end
        end
      end

      items.reject { |it| drop_ids[occurrence_key(it)] }
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

    def centers_overlap?(a, b)
      return false if a.center_x.nil? || a.center_y.nil? || b.center_x.nil? || b.center_y.nil?
      reach = [a.width, a.height, b.width, b.height].compact.map(&:to_f).max.to_f
      return false if reach <= 0
      (a.center_x - b.center_x).abs <= reach && (a.center_y - b.center_y).abs <= reach
    end

    def horizontal_index_key(item)
      area_bucket = Math.log([area_qty(item), 1.0e-9].max) / Math.log(1.0 + SLAB_AREA_TOLERANCE)
      [
        (item.center_x.to_f / HORIZONTAL_INDEX_CELL_M).floor,
        (item.center_y.to_f / HORIZONTAL_INDEX_CELL_M).floor,
        (item.z_center.to_f / SLAB_Z_TOLERANCE_M).floor,
        area_bucket.floor
      ]
    end

    def horizontal_neighbor_keys(item)
      base = horizontal_index_key(item)
      keys = []
      (-1..1).each do |dx|
        (-1..1).each do |dy|
          (-1..1).each do |dz|
            (-2..2).each { |da| keys << [base[0] + dx, base[1] + dy, base[2] + dz, base[3] + da] }
          end
        end
      end
      keys
    end

    def spatial_index_key(item, cell_size)
      [
        (item.center_x.to_f / cell_size).floor,
        (item.center_y.to_f / cell_size).floor,
        (item.z_center.to_f / cell_size).floor
      ]
    end

    def spatial_neighbor_keys(item, cell_size)
      base = spatial_index_key(item, cell_size)
      (-1..1).flat_map do |dx|
        (-1..1).flat_map do |dy|
          (-1..1).map { |dz| [base[0] + dx, base[1] + dy, base[2] + dz] }
        end
      end
    end

    def center_distance(a, b)
      dx = a.center_x.to_f - b.center_x.to_f
      dy = a.center_y.to_f - b.center_y.to_f
      dz = a.z_center.to_f - b.z_center.to_f
      Math.sqrt(dx * dx + dy * dy + dz * dz)
    end

    def find_indexed_candidate(keys, index)
      keys.each do |key|
        index[key].reverse_each do |candidate|
          return candidate if yield(candidate)
        end
      end
      nil
    end

    def vertical_slab_gap
      @policy&.vertical_slab_gap || VERTICAL_SLAB_GAP_M
    end

    def vertical_slab_area_tol
      @policy&.vertical_slab_area_tol || VERTICAL_SLAB_AREA_TOLERANCE
    end
  end
end
