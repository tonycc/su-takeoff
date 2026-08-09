module SuTakeoff
  # 构建前端工作台所需的全部数据（geometry_usages、hierarchy、overview 等）。
  # Dialog 不再重复做 policy 决议、unit 选择、geometry 聚合，只负责 IO。
  class WorkbenchPresenter
    def initialize(items:, openings:, hierarchy:, colors:,
                   policy:,
                   tag_defs: {}, component_sku: nil)
      @items = items
      @openings = openings
      @hierarchy = hierarchy
      @colors = colors
      @policy = policy
      @tag_defs = tag_defs
      @component_sku = component_sku
    end

    def build(compact: false)
      geometry_usages = build_geometry_usages
      result = {
        hierarchy: @hierarchy,
        geometry_usages: geometry_usages,
        # 页面按组件行使用的最终汇总值。推送也复用这份数据，避免标签变更后
        # 页面与服务端分别聚合导致数值不一致。
        component_rows: build_component_rows(geometry_usages),
        component_skus: build_component_skus,
        tag_defs: @tag_defs
      }
      unless compact
        result[:overview] = build_overview
        result[:items] = serialize_items
        result[:openings] = @openings.map(&:to_h)
      end
      result
    end

    # 返回按组件视图的最终行数据。
    # 数值单位与页面保持一致：面积 m²、长度 mm、体积 m³、件数个。
    # 模型根也返回给页面使用，但推送构建器会显式排除 entity_id=0。
    def build_component_rows(geometry_usages = nil)
      return [] unless @hierarchy.is_a?(Hash)

      usages = geometry_usages || build_geometry_usages
      usages_by_path = usages.group_by { |usage| path_key(usage[:component_path_ids]) }
      classifications = {}
      classify_component_node(@hierarchy, [], usages_by_path, classifications)
      stats_cache = {}
      rows = []

      stats_for = lambda do |node, parent_path|
        path_ids = component_path_for_node(node, parent_path)
        key = path_key(path_ids)
        return stats_cache[key] if stats_cache.key?(key)

        result = empty_component_stats
        Array(usages_by_path[key]).each do |usage|
          add_usage_to_component_stats!(result, usage)
        end

        Array(node_value(node, :children)).each do |child|
          next if node_value(child, :hidden)

          child_path = component_path_for_node(child, path_ids)
          child_tag = classifications[path_key(child_path)]
          next if %w[hidden_skipped pure_organizational].include?(child_tag)

          merge_component_stats!(result, stats_for.call(child, path_ids))
        end

        stats_cache[key] = result
      end

      walk = lambda do |node, parent_path|
        eid = node_value(node, :entity_id).to_i
        path_ids = component_path_for_node(node, parent_path)
        key = path_key(path_ids)
        classification = classifications[key]
        stats = stats_for.call(node, parent_path)
        display = if classification == 'has_instance_items'
                    stats.merge(area: 0.0, length: 0.0, volume: 0.0)
                  else
                    stats
                  end

        rows << {
          entity_id: eid,
          occurrence_key: key,
          component_path_ids: path_ids,
          component_path_persistent_ids: persistent_path_for_node(node, path_ids),
          name: component_display_name(node, path_ids),
          kind: node_value(node, :kind).to_s,
          component_type: component_type_for_node(node, eid),
          definition_name: node_value(node, :definition_name),
          tag: node_value(node, :tag),
          depth: node_value(node, :depth).to_i,
          hidden: !!node_value(node, :hidden),
          classification: classification,
          area_m2: display[:area].to_f,
          length_mm: display[:length].to_f,
          volume_m3: display[:volume].to_f,
          count: display[:count].to_f,
          floor: display[:floor].to_f,
          wall: display[:wall].to_f,
          ceiling: display[:ceiling].to_f,
          materials: display[:materials].keys
        }

        Array(node_value(node, :children)).each { |child| walk.call(child, path_ids) }
      end

      walk.call(@hierarchy, [])
      rows
    end

    private

    def node_value(node, key)
      return nil unless node.is_a?(Hash)

      node[key] || node[key.to_s]
    end

    def classify_component_node(node, parent_path, usages_by_path, classifications)
      path_ids = component_path_for_node(node, parent_path)
      key = path_key(path_ids)
      usages = usages_by_path[key] || []
      has_face = usages.any? { |usage| !usage[:is_instance] }
      has_instance = usages.any? { |usage| usage[:is_instance] }
      child_tags = Array(node_value(node, :children)).map do |child|
        classify_component_node(child, path_ids, usages_by_path, classifications)
      end
      child_has_stats = child_tags.any? do |tag|
        %w[has_face_items has_instance_items has_descendant_stats actionable_empty].include?(tag)
      end

      classification = if node_value(node, :hidden)
                         'hidden_skipped'
                       elsif has_face
                         'has_face_items'
                       elsif has_instance && !has_face
                         'has_instance_items'
                       elsif child_has_stats
                         'has_descendant_stats'
                       elsif node_value(node, :kind).to_s == 'component_instance'
                         'actionable_empty'
                       else
                         'pure_organizational'
                       end
      classifications[key] = classification
    end

    def empty_component_stats
      {
        area: 0.0,
        length: 0.0,
        volume: 0.0,
        count: 0.0,
        floor: 0.0,
        wall: 0.0,
        ceiling: 0.0,
        materials: {}
      }
    end

    def numeric_value(value)
      value.nil? ? 0.0 : value.to_f
    end

    def add_usage_to_component_stats!(stats, usage)
      if usage[:is_instance]
        count = numeric_value(usage[:qty_count])
        count = numeric_value(usage[:qty]) if count.zero?
        stats[:count] += count
        return
      end

      area = numeric_value(usage[:qty_area])
      length = numeric_value(usage[:qty_length])
      count = numeric_value(usage[:qty_count])
      if area.zero? && length.zero? && count.zero?
        if usage[:unit] == 'm'
          length = numeric_value(usage[:qty])
        elsif usage[:unit] != 'm³'
          area = numeric_value(usage[:qty])
        end
      end

      stats[:area] += area
      stats[:length] += length * 1000.0
      stats[:volume] += numeric_value(usage[:qty_volume])
      stats[:count] += count
      by_part = usage[:by_part] || {}
      stats[:floor] += numeric_value(by_part[:floor] || by_part['floor'])
      stats[:wall] += numeric_value(by_part[:wall] || by_part['wall'])
      stats[:ceiling] += numeric_value(by_part[:ceiling] || by_part['ceiling'])
      material = usage[:su_material]
      stats[:materials][material] = true unless material.nil?
    end

    def merge_component_stats!(target, source)
      %i[area length volume count floor wall ceiling].each do |key|
        target[key] += source[key].to_f
      end
      source[:materials].each_key { |material| target[:materials][material] = true }
      target
    end

    def component_display_name(node, path_ids)
      name = node_value(node, :name).to_s.strip
      return name unless name.empty?

      item = item_by_component_path[path_key(path_ids)]
      item_name = item && Array(item.component_path).last.to_s.strip
      return item_name unless item_name.to_s.empty?

      path_ids.empty? ? '(模型根)' : '未命名组件'
    end

    def component_type_for_node(node, eid)
      return 'model_root' if eid.zero?

      kind = node_value(node, :kind).to_s
      kind.empty? ? 'component_instance' : kind
    end

    def persistent_path_for_entity_path(path_ids)
      return [] if path_ids.empty?

      found = persistent_path_by_component_path[path_key(path_ids)]
      return found if found

      path_ids
    end

    def persistent_path_for_node(node, path_ids)
      explicit = Array(node_value(node, :component_path_persistent_ids)).compact
      return explicit if explicit.length == path_ids.length

      persistent_path_for_entity_path(path_ids)
    end

    def path_key(path_ids)
      ScanItem.path_key(path_ids)
    end

    def component_path_for_node(node, parent_path)
      explicit = node_value(node, :component_path_ids)
      return Array(explicit).map(&:to_i) if explicit

      eid = node_value(node, :entity_id).to_i
      eid.zero? ? Array(parent_path) : Array(parent_path) + [eid]
    end

    def build_item_path_indexes
      return if defined?(@item_by_component_path) && @item_by_component_path

      @item_by_component_path = {}
      @persistent_path_by_component_path = {}
      @items.each do |item|
        ids = Array(item.component_path_ids).map(&:to_i)
        pids = Array(item.component_path_persistent_ids).compact
        next if ids.empty?

        @item_by_component_path[path_key(ids)] ||= item
        1.upto([ids.length, pids.length].min) do |length|
          @persistent_path_by_component_path[path_key(ids.first(length))] ||= pids.first(length)
        end
      end
    end

    def item_by_component_path
      build_item_path_indexes
      @item_by_component_path
    end

    def persistent_path_by_component_path
      build_item_path_indexes
      @persistent_path_by_component_path
    end

    # 组件级项目产品关联表：definition_name => 项目产品与实际产品字段
    def build_component_skus
      return {} unless @component_sku

      @component_sku.all.each_with_object({}) do |r, memo|
        memo[r.definition_name] = {
          sku_id: r.platform_sku_id,
          sku_code: r.platform_sku_code,
          sku_name: r.platform_sku_name,
          project_product_id: r.project_product_id,
          product_id: r.product_id,
          catalog_code: r.catalog_code,
          product_name: r.product_name,
          project_product_code: r.project_product_code
        }
      end
    end

    def face_items
      @face_items ||= @items.reject { |it| it.kind == :instance }
    end

    def instance_items
      @instance_items ||= @items.select { |it| it.kind == :instance }
    end

    def used_names
      @used_names ||= face_items.map(&:su_material).compact.uniq
    end

    def calc
      @calc ||= Calculator.new(policy: @policy)
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
        material_count: used_names.size
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
      resolutions = calc.compute_geometry_only(@items, @openings)
      opening_area_by_face = build_opening_area_map

      # 按 (完整实例路径, su_material) 聚合。末级 entity_id 在共享定义中并不唯一。
      # 复合标签（如 count+length）会产出多条 item 共享同一 eid，全部保留
      geo_agg = {}
      resolutions.each do |r|
        it = r[:item]
        component_path_ids = Array(it.component_path_ids).map(&:to_i)
        key = [path_key(component_path_ids), it.su_material]
        geo_agg[key] ||= []
        geo_agg[key] << it
      end

      geo_agg.map do |(_occurrence_key, su_mat), mat_items|
        build_geometry_usage_entry(Array(mat_items.first.component_path_ids), su_mat, mat_items, opening_area_by_face)
      end
    end

    def build_opening_area_map
      map = {}
      @openings.each do |op|
        keys = Array(op.host_face_keys).compact
        keys = Array(op.host_face_ids) if keys.empty?
        keys.each do |face_key|
          map[face_key] ||= 0.0
          map[face_key] += op.area
        end
      end
      map
    end

    def build_geometry_usage_entry(component_path_ids, su_mat, mat_items, opening_area_by_face)
      component_path_ids = Array(component_path_ids).map(&:to_i)
      eid = component_path_ids.last || 0
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
      ctx = { opening_area_by_face: opening_area_by_face }

      if is_instance
        qty_count = mat_items.sum { |i| i.qty.to_f }
      else
        # 按 resolved_method 分桶，每桶调对应策略的 aggregate
        strategies = @policy&.strategies || Strategies::Registry.global
        face_linear  = strategies.get(:face_linear)
        solid_volume = strategies.get(:solid_volume)
        face_area    = strategies.get(:face_area)

        items_by_method = face_items_in_group.group_by { |i| i.resolved_method || :area }

        items_by_method.each do |method, sub_items|
          case method
          when :length
            # face_linear.aggregate 含 height fallback，兼容 face 和 linear_solid 两种 item
            qty_length += face_linear ? face_linear.aggregate(sub_items, ctx)
                                      : sub_items.sum { |i| (i.qty_length || i.height || 0).to_f }
          when :volume
            qty_volume += solid_volume ? solid_volume.aggregate(sub_items, ctx)
                                       : sub_items.sum { |i| (i.qty_volume || 0).to_f }
          when :count
            # 临时保留 face→+1.0 的兼容行为；Stage 4 引入 FaceCount 后清理
            qty_count += sub_items.sum { |i|
              i.kind == :face ? 1.0 : (i.qty_count || i.qty || 0).to_f
            }
          when :area
            qty_area += face_area ? face_area.aggregate(sub_items, ctx)
                                  : sub_items.sum { |i|
                                      d = opening_area_by_face[i.face_occurrence_key]
                                      d = opening_area_by_face[i.face_id] if d.nil?
                                      d ||= 0.0
                                      [i.qty - d, 0.0].max
                                    }
          end
          # :skip 及未知 method 跳过（理论上不会到这里 —— cache_resolve 已过滤）
        end
      end

      primary_qty, primary_unit = pick_primary(qty_area, qty_length, qty_volume, qty_count)

      any_heuristic = face_items_in_group.any? { |i| i.source == :heuristic }
      confidence = any_heuristic ? 'heuristic' : 'explicit'

      # 紧凑索引：仅 face_id + path_ids，用于前端面定位/高亮（不含宽高面积等大字段）
      face_refs = face_items_in_group.map { |i|
        { face_id: i.face_id, path_ids: i.component_path_ids }
      }

      faces_detail = face_items_in_group.map { |i|
        {
          face_id: i.face_id,
          path_ids: i.component_path_ids,
          width: i.width&.round(2),
          height: (i.qty_length || i.height)&.round(4),
          volume: i.qty_volume&.round(4),
          area: i.qty.round(3),
          kind: i.kind,
          part: Calculator.face_orientation(i.normal),
          resolved_method: i.resolved_method&.to_s,
          source: i.source&.to_s,
          strategy_name: i.strategy_name&.to_s
        }
      }

      {
        entity_id: eid,
        occurrence_key: path_key(component_path_ids),
        component_path_ids: component_path_ids,
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
        face_refs: face_refs,
        faces: faces_detail,
        confidence: confidence,
        strategies: face_items_in_group.map(&:strategy_name).compact.uniq.map(&:to_s)
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

  end
end
