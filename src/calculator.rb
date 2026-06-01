module SuTakeoff
  class Calculator
    # Two horizontal faces with same material, near-equal area and close z_center
    # are treated as two sides of a thin slab (e.g. floor plate, ceiling plate).
    SLAB_AREA_TOLERANCE = 0.02      # 2% area diff
    SLAB_Z_TOLERANCE_M = 0.15       # 15 cm thickness max

    # P4: Vertical slab dedup —— 散面踢脚线/装饰条建模时常出现的薄板背靠背两面同材质场景。
    # 配对要求：法线反向 + 面积近似相等 + 两面 bbox 中心距 ≤ 此阈值。
    VERTICAL_SLAB_AREA_TOLERANCE = 0.02
    VERTICAL_SLAB_GAP_M = 0.05      # 5 cm 薄板厚度

    # Fallback constants used when config.json is unavailable (e.g. tests).
    # In production, unit classification comes from config.json.
    FALLBACK_LENGTH_UNITS = %w[m mm cm dm km].freeze
    FALLBACK_COUNT_UNITS = %w[个 件 套 组 台 只].freeze

    def initialize(mapping, process_library, component_mapping = nil, policy: nil)
      @mapping = mapping
      @processes = process_library
      @component_mapping = component_mapping
      @policy = policy
    end

    attr_accessor :policy

    # Returns Array of MaterialUsage
    # items: Array of ScanItem
    # openings: Array of Opening
    # process_overrides: Hash { su_material_name => process_name }
    def compute(items, openings, process_overrides)
      opening_area_by_face, openings_by_face = build_opening_index(openings)

      # 薄板去重（水平楼板/天花板 + 竖直薄板踢脚线）
      items = dedup_thin_slabs(items)
      items = dedup_vertical_slabs(items)

      # Group items by (space, part, su_material_name, method, confidence, source)
      groups = Hash.new { |h, k| h[k] = [] }
      items.each do |item|
        if item.kind == :instance
          # 纯边线组件无映射也算件数，不跳过
        elsif item.kind == :count_solid || item.kind == :linear_solid || item.kind == :solid
          # layer rule / 标签 容器级整体量取，无需 mapping 检查
        else
          next unless @mapping.get(item.su_material)
        end

        method, confidence, source = resolve_method(item)
        next if method == :skip

        part = self.class.face_orientation(item.normal)
        space = self.class.extract_space(item)
        key = [space, part, item.su_material, item.unit, method, confidence, source]
        groups[key] << item
      end

      # Build MaterialUsage for each group (fan-out via derivations)
      usages = groups.flat_map do |key, grp_items|
        space, part, su_mat, item_unit, method, confidence, source = key
        first_item = grp_items.first
        is_instance = first_item&.kind == :instance

        record = if is_instance
          component_mapping.get(su_mat)
        else
          @mapping.get(su_mat)
        end
        # :count_solid from layer rule may not be mapped; guard with safe navigation below

        geom = build_geometry(method, grp_items, opening_area_by_face, openings_by_face)
        is_count  = (method == :count)
        is_linear = (method == :length)

        # Find the process (with optional override)
        process = if process_overrides[su_mat]
          @processes.processes_for(record&.category || '').find { |p|
            p.name == process_overrides[su_mat]
          }
        else
          @processes.processes_for(record&.category || '').first
        end

        waste_rate = record&.default_waste_rate || 0.0
        detail = if is_count
          { gross: geom[:gross], deduction: 0, instance_count: grp_items.size,
            instances: geom[:faces_detail] }
        else
          { gross: geom[:gross].round(3), deduction: geom[:total_deduction].round(3),
            face_count: grp_items.size, faces: geom[:faces_detail] }
        end

        primary = MaterialUsage.new(
          space: space, part: part,
          material_name: record&.material_name || su_mat,
          category: record&.category || '',
          spec: record&.spec || '',
          net_area: geom[:net_area].round(is_count ? 0 : 4),
          waste_rate: process&.waste_rate || waste_rate,
          su_material_name: su_mat,
          unit: unit_for_method(method, record, source, item_unit),
          detail: detail,
          confidence: confidence,
          source: source
        )
        primary.items = grp_items
        usages = [primary]

        # Fan-out derivations as additional usages
        if process && process.derivations && !process.derivations.empty?
          process.derivations.each do |deriv|
            # 派生公式上下文按 method 注入：area/length/volume 取对应几何量，
            # 其余维度为 0。允许公式跨维度（如 volume*0.06 求砂浆 m³）。
            base_ctx = {
              area:   (method == :area)   ? geom[:net_area] : 0,
              length: (method == :length) ? geom[:net_area] : 0,
              volume: (method == :volume) ? geom[:net_area] : 0,
              count:  (method == :count)  ? geom[:net_area] : 0
            }
            deriv_qty = eval_formula(deriv.formula, base_ctx)
            derived = MaterialUsage.new(
              space: space, part: part,
              material_name: deriv.layer,
              category: deriv.category,
              spec: record&.spec || '',
              net_area: deriv_qty.round(4),
              waste_rate: deriv.waste_rate,
              su_material_name: su_mat,
              layer: deriv.layer,
              parent_su_material: su_mat,
              unit: deriv.unit,
              detail: {
                formula: deriv.formula,
                base_value: geom[:net_area].round(is_count ? 0 : 3),
                base_unit: is_count ? record.unit : base_unit_for(method),
                instance_count: grp_items.size
              },
              confidence: confidence, source: source
            )
            derived.items = grp_items
            usages << derived
          end
        end
        usages
      end

      usages
    end

    # 几何用量计算：含洞口扣减、薄板去重、面/线材识别，不含损耗率与工艺做法
    # 不接受 process_overrides 参数，内部不使用 @processes
    # 与 compute 的关键差异：面 item 不要求映射，未映射材质也产出记录
    def compute_geometry_only(items, openings)
      opening_area_by_face, openings_by_face = build_opening_index(openings)

      # 薄板去重（水平楼板/天花板 + 竖直薄板踢脚线）
      items = dedup_thin_slabs(items)
      items = dedup_vertical_slabs(items)

      groups = Hash.new { |h, k| h[k] = [] }
      items.each do |item|
        # nil su_material 无意义，跳过（instance 类由 def_name 填充，不为 nil）
        next if item.su_material.nil?

        method, confidence, source = resolve_method_geometry(item)
        next if method == :skip

        part = self.class.face_orientation(item.normal)
        space = self.class.extract_space(item)
        key = [space, part, item.su_material, method, confidence, source]
        groups[key] << item
      end

      groups.map do |key, grp_items|
        space, part, su_mat, method, confidence, source = key
        first_item = grp_items.first
        is_instance = first_item&.kind == :instance

        record = if is_instance
          component_mapping.get(su_mat)
        else
          @mapping.get(su_mat)
        end

        is_count = (method == :count)
        unit = unit_for_method(method, record, source, nil)
        geom = build_geometry(method, grp_items, opening_area_by_face, openings_by_face)

        detail = if is_count
          { gross: geom[:gross], deduction: 0, instance_count: grp_items.size,
            instances: geom[:faces_detail] }
        else
          { gross: geom[:gross].round(3), deduction: geom[:total_deduction].round(3),
            face_count: grp_items.size, faces: geom[:faces_detail] }
        end

        primary = MaterialUsage.new(
          space: space, part: part,
          material_name: record&.material_name || '',
          category: record&.category || '',
          spec: record&.spec || '',
          net_area: geom[:net_area].round(is_count ? 0 : 4),
          waste_rate: 0,
          su_material_name: su_mat,
          unit: unit,
          detail: detail,
          confidence: confidence, source: source
        )
        primary.items = grp_items
        primary
      end
    end

    # Returns Hash { material_name => { net_area:, purchase_qty:, items: [MaterialUsage] } }
    def group_by_material(usages)
      grouped = Hash.new { |h, k| h[k] = { net_area: 0.0, purchase_qty: 0.0, items: [] } }
      usages.each do |u|
        grouped[u.material_name][:net_area] += u.net_area
        grouped[u.material_name][:purchase_qty] += u.purchase_qty
        grouped[u.material_name][:items] << u
      end
      grouped.each_value do |v|
        v[:net_area] = v[:net_area].round(2)
        v[:purchase_qty] = v[:purchase_qty].round(2)
      end
      grouped
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

    def length_units
      @policy&.length_units || FALLBACK_LENGTH_UNITS
    end

    def count_units
      @policy&.count_units || FALLBACK_COUNT_UNITS
    end

    def component_mapping
      @component_mapping
    end

    def eval_formula(formula, geom)
      ctx =
        if geom.is_a?(Hash)
          {
            area:   geom[:area]   || geom[:net_area] || 0,
            length: geom[:length] || geom[:net_length] || 0,
            volume: geom[:volume] || geom[:net_volume] || 0,
            count:  geom[:count]  || 0
          }
        else
          # 兼容老调用：传单个数字时按 area 处理
          { area: geom, length: 0, volume: 0, count: 0 }
        end
      Formula.eval(formula, ctx)
    end

    # ---- 方法决议 ----
    # 返回 [method, confidence, source]
    #
    # 有 policy 时走 4 档优先级。无 policy 时按映射 unit 兜底（与 P1 之前的行为
    # 等价），便于现有调用零变更。
    def resolve_method(item)
      if @policy
        r = @policy.resolve(item)
        confidence = (r.source == :heuristic) ? :heuristic : :explicit
        return [r.method, confidence, r.source]
      end

      record = if item.kind == :instance
        component_mapping.get(item.su_material)
      else
        @mapping.get(item.su_material)
      end

      # 纯边线组件无映射默认按件数统计
      if item.kind == :instance && record.nil?
        return [:count, :explicit, :mapping]
      end

      return [:skip, :explicit, :default] unless record

      method =
        if item.kind == :instance || count_units.include?(record.unit)
          :count
        elsif length_units.include?(record.unit)
          :length
        else
          :area
        end
      [method, :explicit, :mapping]
    end

    # compute_geometry_only 专用：允许未映射面 item，按面长宽比兜底判定线材。
    # 与 resolve_method 的差异：未映射时不返回 :skip，而是按几何特征判定。
    def resolve_method_geometry(item)
      if @policy
        r = @policy.resolve(item)
        # 启发式或显式得到 :skip 也仍尝试出图（compute_geometry_only 兜底语义），
        # 但若是 :skip 由 default 给出（无映射 + 无规则 + 启发式关），按面长宽比兜底
        if r.method == :skip && r.source == :default
          return geometry_unmapped_fallback(item)
        end
        confidence = (r.source == :heuristic) ? :heuristic : :explicit
        return [r.method, confidence, r.source]
      end

      record = if item.kind == :instance
        component_mapping.get(item.su_material)
      else
        @mapping.get(item.su_material)
      end

      if record
        method =
          if item.kind == :instance || count_units.include?(record.unit)
            :count
          elsif length_units.include?(record.unit)
            :length
          else
            :area
          end
        [method, :explicit, :mapping]
      else
        geometry_unmapped_fallback(item)
      end
    end

    # 未映射面 item 的兜底判定：长宽比 > 15 视为线材，否则面材。
    def geometry_unmapped_fallback(item)
      is_linear = item.kind == :face && item.width && item.width > 0 &&
                  item.height && (item.height / item.width) > 15
      [is_linear ? :length : :area, :heuristic, :heuristic]
    end

    # 按 method 选择对应的 build_*_geometry 实现。
    def build_geometry(method, grp_items, opening_area_by_face, openings_by_face)
      case method
      when :count
        build_count_geometry(grp_items)
      when :length
        build_length_geometry(grp_items)
      when :volume
        build_volume_geometry(grp_items)
      else
        build_area_geometry(grp_items, opening_area_by_face, openings_by_face)
      end
    end

    # 派生项展示用的基准单位标签
    def base_unit_for(method)
      case method
      when :length then 'm'
      when :volume then 'm³'
      when :count  then '件'
      else 'm²'
      end
    end

    # 单位显示：method 决定语义，source 决定细节
    #   :count   → record.unit（个/件/套），缺省回退 item_unit
    #   :length  → mapping 兜底时尊重 record.unit（'m'/'mm' 都可），其他档位强制 'm'
    #   :volume  → 强制 'm³'
    #   :area    → record.unit（m²），缺省回退 item_unit / 'm²'
    def unit_for_method(method, record, source, item_unit)
      case method
      when :count
        record&.unit || item_unit || '个'
      when :length
        if source == :mapping && record && length_units.include?(record.unit)
          record.unit
        else
          'm'
        end
      when :volume
        'm³'
      else
        record&.unit || item_unit || 'm²'
      end
    end

    # ---- 量纲分支：build_*_geometry ----
    #
    # 把几何累加从 compute / compute_geometry_only 中抽出来。返回
    #   { gross:, total_deduction:, net_area:, faces_detail: }
    # 使二次调用 0 复制。新字段优先：qty_area / qty_length / qty_count；
    # 老 ScanItem（位置参数构造、未填新字段）回退到 qty / height。

    def build_count_geometry(grp_items)
      gross = grp_items.sum { |it| count_qty(it) }.round(0)
      faces_detail = grp_items.map { |it|
        { face_id: it.face_id, count: count_qty(it),
          component_path: it.component_path }
      }
      { gross: gross, total_deduction: 0.0, net_area: gross.to_f,
        faces_detail: faces_detail }
    end

    def build_length_geometry(grp_items)
      gross = grp_items.sum { |it| length_qty(it) }.round(3)
      faces_detail = grp_items.map { |it|
        { face_id: it.face_id, width: (it.width || 0).round(2),
          height: (it.height || 0).round(4),
          area: area_qty(it).round(3), length: length_qty(it).round(3),
          part: Calculator.face_orientation(it.normal),
          component_path: it.component_path }
      }
      { gross: gross, total_deduction: 0.0, net_area: gross,
        faces_detail: faces_detail }
    end

    # P3: 体积统计 —— 累加 qty_volume，不扣洞口、不分朝向。
    # 入参既可以是 :solid kind（容器整体量取），也可以是手工填了 qty_volume 的 :face。
    def build_volume_geometry(grp_items)
      gross = grp_items.sum { |it| volume_qty(it) }.round(4)
      faces_detail = grp_items.map { |it|
        { face_id: it.face_id,
          width: (it.width || 0).round(4),
          height: (it.height || 0).round(4),
          depth: (it.depth || 0).round(4),
          volume: volume_qty(it).round(4),
          component_path: it.component_path }
      }
      { gross: gross, total_deduction: 0.0, net_area: gross,
        faces_detail: faces_detail }
    end

    def build_area_geometry(grp_items, opening_area_by_face, openings_by_face)
      gross = grp_items.sum { |it| area_qty(it) }.round(3)
      total_deduction = grp_items.sum { |it|
        opening_area_by_face[it.face_id] || 0.0
      }.round(3)
      net_area = grp_items.sum { |it|
        deduction = opening_area_by_face[it.face_id] || 0.0
        [area_qty(it) - deduction, 0.0].max
      }
      faces_detail = grp_items.map { |it|
        a = area_qty(it)
        d = (opening_area_by_face[it.face_id] || 0.0).round(3)
        ops = openings_by_face[it.face_id] || []
        { face_id: it.face_id, width: (it.width || 0).round(4),
          height: (it.height || 0).round(4),
          area: a.round(3), deduction: d, net: (a - d).round(3),
          part: Calculator.face_orientation(it.normal),
          component_path: it.component_path,
          openings: ops }
      }
      { gross: gross, total_deduction: total_deduction, net_area: net_area,
        faces_detail: faces_detail }
    end

    # 字段读取兜底：新字段优先，回退到老字段。
    def area_qty(item)
      v = item.qty_area
      return v.to_f if v
      (item.qty || 0).to_f
    end

    def length_qty(item)
      v = item.qty_length
      return v.to_f if v
      (item.height || 0).to_f
    end

    def count_qty(item)
      v = item.qty_count
      return v.to_f if v
      (item.qty || 0).to_f
    end

    def volume_qty(item)
      v = item.qty_volume
      return v.to_f if v
      0.0
    end

    def build_opening_index(openings)
      opening_area_by_face = {}
      openings_by_face = Hash.new { |h, k| h[k] = [] }
      openings.each do |op|
        op.host_face_ids.each do |fid|
          opening_area_by_face[fid] ||= 0.0
          opening_area_by_face[fid] += op.area
          openings_by_face[fid] << { entity_id: op.entity_id, area: op.area.round(3) }
        end
      end
      [opening_area_by_face, openings_by_face]
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
        @policy.resolve(it).method == :length
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
