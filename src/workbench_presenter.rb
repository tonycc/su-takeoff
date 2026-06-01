module SuTakeoff
  # 构建前端工作台所需的全部数据（usages、geometry_usages、materials_info、overview 等）。
  # Dialog 不再重复做 policy 决议、unit 选择、geometry 聚合，只负责 IO。
  class WorkbenchPresenter
    def initialize(items:, openings:, hierarchy:, colors:,
                   mapping:, component_mapping:, policy:, processes:,
                   ignored: [], tag_defs: {})
      @items = items
      @openings = openings
      @hierarchy = hierarchy
      @colors = colors
      @mapping = mapping
      @component_mapping = component_mapping
      @policy = policy
      @processes = processes
      @ignored = ignored
      @tag_defs = tag_defs
    end

    def build
      {
        overview: build_overview,
        items: serialize_items,
        openings: @openings.map(&:to_h),
        ignored: ignored_names,
        unresolved: unresolved_names,
        materials_info: build_materials_info,
        categories: @processes.all_categories,
        length_units: @policy.length_units,
        usages: usages.map(&:to_h),
        hierarchy: @hierarchy,
        geometry_usages: build_geometry_usages,
        tag_defs: @tag_defs,
        by_material: {}
      }
    end

    private

    def face_items
      @face_items ||= @items.reject { |it| it.kind == :instance }
    end

    def instance_items
      @instance_items ||= @items.select { |it| it.kind == :instance }
    end

    def used_names
      @used_names ||= face_items.map(&:su_material).compact.uniq
    end

    def unresolved_names
      @unresolved_names ||= used_names.reject { |n| @mapping.get(n) || @ignored.include?(n) }
    end

    def ignored_names
      @ignored_names ||= @ignored & used_names
    end

    def mapped_names
      @mapped_names ||= used_names.select { |n| @mapping.get(n) }
    end

    def calc
      @calc ||= Calculator.new(@mapping, @processes, @component_mapping, policy: @policy)
    end

    def usages
      @usages ||= calc.compute(@items, @openings, {})
    end

    # ---- overview ----

    def build_overview
      {
        total_faces: face_items.size,
        total_area: face_items.sum(&:qty).round(2),
        instance_count: instance_items.size,
        instance_total: instance_items.sum(&:qty).round(0),
        total_openings: @openings.size,
        total_opening_area: @openings.sum(&:area).round(2),
        material_count: used_names.size,
        mapped: mapped_names.size,
        ignored_count: ignored_names.size,
        unresolved_count: unresolved_names.size
      }
    end

    # ---- items serialization ----

    def serialize_items
      @items.map do |it|
        h = it.to_h
        h[:normal] = it.normal
        h[:component_path] = it.component_path
        h[:component_path_ids] = it.component_path_ids
        h[:part] = Calculator.face_orientation(it.normal)
        h
      end
    end

    # ---- geometry_usages (per-entity aggregation) ----

    def build_geometry_usages
      geo_usages = calc.compute_geometry_only(@items, @openings)
      deduped_items = geo_usages.flat_map(&:items)
      item_lookup = build_item_resolution_lookup(geo_usages)

      opening_area_by_face = build_opening_area_map

      geo_agg = {}
      deduped_items.each do |it|
        next if it.su_material.nil?
        eid = it.component_path_ids.last || 0
        key = [eid, it.su_material]
        geo_agg[key] ||= []
        geo_agg[key] << it
      end

      geo_agg.map do |(eid, su_mat), mat_items|
        build_geometry_usage_entry(eid, su_mat, mat_items, item_lookup, opening_area_by_face)
      end
    end

    # 从 compute_geometry_only 的 MaterialUsage 反查每个 item 的决议结果，
    # 避免重复调 policy.resolve 和手写 unit 选择逻辑。
    def build_item_resolution_lookup(geo_usages)
      lookup = {}
      geo_usages.each do |u|
        method = method_from_usage(u)
        source = u.source
        unit = u.unit
        u.items.each do |it|
          lookup[it.face_id] = { method: method, source: source, unit: unit }
        end
      end
      lookup
    end

    def method_from_usage(usage)
      unit = usage.unit
      return :length if @policy.length_units.include?(unit)
      return :volume if @policy.volume_units.include?(unit)
      return :count  if @policy.count_units.include?(unit)
      :area
    end

    def build_opening_area_map
      map = {}
      @openings.each do |op|
        op.host_face_ids.each do |fid|
          map[fid] ||= 0.0
          map[fid] += op.area
        end
      end
      map
    end

    def build_geometry_usage_entry(eid, su_mat, mat_items, item_lookup, opening_area_by_face)
      face_items_in_group = mat_items.reject { |i| i.kind == :instance }
      is_instance = mat_items.any? { |i| i.kind == :instance } && face_items_in_group.empty?

      part_counts = Hash.new(0.0)
      face_items_in_group.each do |i|
        part_counts[Calculator.face_orientation(i.normal)] += i.qty if i.kind == :face
      end

      qty_area = 0.0
      qty_length = 0.0
      qty_volume = 0.0
      qty_count = 0

      if is_instance
        qty_count = mat_items.sum { |i| i.qty.to_f }
      else
        face_items_in_group.each do |i|
          res = item_lookup[i.face_id]
          method = res ? res[:method] : :area
          case method
          when :length
            qty_length += (i.qty_length || i.height || 0).to_f
          when :volume
            qty_volume += (i.qty_volume || 0).to_f
          when :count
            qty_count += if i.kind == :face then 1.0 else (i.qty_count || i.qty || 0).to_f end
          else
            deduction = opening_area_by_face[i.face_id] || 0.0
            qty_area += [i.qty - deduction, 0.0].max
          end
        end
      end

      primary_qty, primary_unit = pick_primary(qty_area, qty_length, qty_volume, qty_count)

      any_heuristic = face_items_in_group.any? { |i|
        (item_lookup[i.face_id] && item_lookup[i.face_id][:source] == :heuristic)
      }
      confidence = any_heuristic ? 'heuristic' : 'explicit'

      faces_detail = face_items_in_group.map { |i|
        res = item_lookup[i.face_id]
        {
          face_id: i.face_id,
          path_ids: i.component_path_ids,
          width: i.width&.round(2),
          height: (i.qty_length || i.height)&.round(4),
          volume: i.qty_volume&.round(4),
          area: i.qty.round(3),
          kind: i.kind,
          part: Calculator.face_orientation(i.normal),
          resolved_method: res&.dig(:method)&.to_s,
          source: res&.dig(:source)&.to_s
        }
      }

      {
        entity_id: eid,
        su_material: su_mat,
        unit: primary_unit,
        qty: primary_qty.round(4),
        qty_area: qty_area.round(4),
        qty_length: qty_length.round(4),
        qty_volume: qty_volume.round(4),
        qty_count: qty_count.round(4),
        face_count: face_items_in_group.size,
        by_part: part_counts.transform_values { |v| v.round(2) },
        is_instance: is_instance,
        faces: faces_detail,
        confidence: confidence
      }
    end

    def pick_primary(qty_area, qty_length, qty_volume, qty_count)
      if qty_area > 0
        [qty_area, 'm²']
      elsif qty_length > 0
        [qty_length, 'm']
      elsif qty_volume > 0
        [qty_volume, 'm³']
      elsif qty_count > 0
        [qty_count, '个']
      else
        [0, 'm²']
      end
    end

    # ---- materials_info ----

    def build_materials_info
      by_name = Hash.new { |h, k| h[k] = [] }
      face_items.each { |it| by_name[it.su_material] << it if it.su_material }

      used_names.map do |name|
        group = by_name[name] || []
        parts = Hash.new(0.0)
        spaces = Hash.new(0.0)
        linear_count = 0
        total_length = 0.0
        group.each do |it|
          parts[Calculator.face_orientation(it.normal)] += it.qty
          spaces[Calculator.extract_space(it)] += it.qty
          if it.width && it.width > 0 && it.height && (it.height / it.width) > 15
            linear_count += 1
            total_length += it.height
          end
        end
        suggested_unit = (group.size > 0 && linear_count.to_f / group.size > 0.5) ? 'm' : 'm²'
        record = @mapping.get(name)
        color = @colors[name] || @colors.values.first || { r: 128, g: 128, b: 128, a: 255 }

        {
          su_name: name,
          material_name: record&.material_name || '',
          category: record&.category || '',
          mapped_unit: record&.unit,
          spec: record&.spec || '',
          waste_rate: record&.default_waste_rate || 0.0,
          face_count: group.size,
          total_area: group.sum(&:qty).round(2),
          total_length: total_length.round(2),
          linear_count: linear_count,
          parts: parts.transform_values { |v| v.round(2) },
          spaces: spaces.sort_by { |_, a| -a }.first(3).map { |s, a| { name: s, area: a.round(2) } },
          suggested_unit: suggested_unit,
          color: color
        }
      end
    end
  end
end
