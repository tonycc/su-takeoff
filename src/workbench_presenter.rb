module SuTakeoff
  # 构建前端工作台所需的全部数据（geometry_usages、hierarchy、overview 等）。
  # Dialog 不再重复做 policy 决议、unit 选择、geometry 聚合，只负责 IO。
  class WorkbenchPresenter
    def initialize(items:, openings:, hierarchy:, colors:,
                   mapping:, component_mapping:, policy:,
                   ignored: [], tag_defs: {})
      @items = items
      @openings = openings
      @hierarchy = hierarchy
      @colors = colors
      @mapping = mapping
      @component_mapping = component_mapping
      @policy = policy
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
        hierarchy: @hierarchy,
        geometry_usages: build_geometry_usages,
        tag_defs: @tag_defs
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
      @calc ||= Calculator.new(@mapping, @component_mapping, policy: @policy)
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
      resolutions = calc.compute_geometry_only(@items, @openings)
      opening_area_by_face = build_opening_area_map

      # 按 (entity_id, su_material) 重新聚合，供前端组件树视图消费
      # 复合标签（如 count+length）会产出多条 item 共享同一 eid，全部保留
      geo_agg = {}
      resolutions.each do |r|
        it = r[:item]
        eid = it.component_path_ids.last || 0
        key = [eid, it.su_material]
        geo_agg[key] ||= []
        geo_agg[key] << it
      end

      geo_agg.map do |(eid, su_mat), mat_items|
        build_geometry_usage_entry(eid, su_mat, mat_items, opening_area_by_face)
      end
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

    def build_geometry_usage_entry(eid, su_mat, mat_items, opening_area_by_face)
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
                                      d = opening_area_by_face[i.face_id] || 0.0
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
