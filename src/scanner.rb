require 'set'

module SuTakeoff
  class Scanner
    attr_reader :material_colors

    IDENTITY = Geom::Transformation.new

    # 小于此面积的面视为建模碎片（CAD 导入圆弧炸开等），不参与统计
    MIN_FACE_AREA_M2 = 0.001  # 10 cm²

    def initialize
      @model = Sketchup.active_model
      @material_colors = {}
      @progress_total = 0     # 已扫描面数
      @skipped_hidden = 0     # 跳过隐藏面
      @skipped_transparent = 0 # 跳过透明面（洞口）
      @skipped_tiny = 0       # 跳过极小面
      @named_openings = 0     # 命名门窗洞口数
      @progress_step = 50     # 每 N 个面输出一次进度
    end

    # Scan entire model or selected faces
    def scan(selection_only: false)
      items = []
      openings = []
      face_set = Set.new
      opening_face_ids = Set.new     # 防重：同一面不重复标记为洞口
      @pending_opening_info = []    # 洞口几何信息，用于关联母面
      @progress_total = 0
      @skipped_hidden = 0
      @skipped_transparent = 0
      @skipped_tiny = 0
      @named_openings = 0

      entities =
        if selection_only && !@model.selection.empty?
          @model.selection.to_a
        else
          @model.entities.to_a
        end

      Debug.section "【扫描阶段】开始"
      Debug.log "扫描模式: #{selection_only && !@model.selection.empty? ? '仅选中面' : '全部模型'}"
      Debug.log "顶层实体数: #{entities.size}"
      entities.first(10).each do |e|
        Debug.log "  顶层: #{e.class.name.split('::').last} name=#{e.respond_to?(:name) ? e.name.inspect : 'N/A'} def_name=#{e.respond_to?(:definition) && e.definition ? e.definition.name.inspect : 'N/A'}"
      end

      entities.each do |entity|
        collect_faces(entity, [], IDENTITY, face_set, items, openings, opening_face_ids)
      end

      # ---- 洞口-母面关联 ----
      associate_openings_to_hosts(items, openings, @pending_opening_info)

      # ---- 输出扫描汇总 ----
      Debug.section "扫描结果汇总"
      Debug.log "有效面: #{items.size}"
      Debug.log "跳过微小面: #{@skipped_tiny} (面积<#{MIN_FACE_AREA_M2}m²)"
      Debug.log "透明洞口: #{@skipped_transparent} (alpha<0.5)"
      Debug.log "命名门窗: #{@named_openings}"
      Debug.log "跳过隐藏面: #{@skipped_hidden}"
      Debug.log "洞口合计: #{openings.size}"

      # 按部位统计
      by_part = items.group_by { |i| Calculator.face_orientation(i.normal) }
      Debug.log
      Debug.log "部位分布:"
      Debug.log "  地面 (floor):   #{by_part['floor']&.size || 0}面 #{by_part['floor']&.sum(&:qty)&.round(2) || 0}m²"
      Debug.log "  墙面 (wall):    #{by_part['wall']&.size || 0}面 #{by_part['wall']&.sum(&:qty)&.round(2) || 0}m²"
      Debug.log "  天花 (ceiling): #{by_part['ceiling']&.size || 0}面 #{by_part['ceiling']&.sum(&:qty)&.round(2) || 0}m²"

      # 按空间（组件层级）分解 —— 定位面从哪里来
      by_container = items.group_by { |i| i.component_path.first || "(模型根层级)" }
      Debug.log
      Debug.log "按空间/容器分解:"
      Debug.log
      container_rows = by_container.sort_by { |_, g| -g.size }.map do |name, grp|
        parts = grp.group_by { |i| Calculator.face_orientation(i.normal) }
        f = (parts['floor'] || []).size
        w = (parts['wall'] || []).size
        c = (parts['ceiling'] || []).size
        [name, grp.size.to_s, "#{grp.sum(&:qty).round(2)}m²", "地#{f}", "墙#{w}", "顶#{c}"]
      end
      Debug.table(
        ["容器/空间", "面数", "总面积", "地面", "墙面", "天花"],
        container_rows
      )

      # 按材质分组统计
      mat_groups = items.group_by(&:su_material)
      Debug.log
      Debug.log "材质种类: #{mat_groups.size}"
      Debug.log

      rows = mat_groups.sort_by { |_, g| -g.sum(&:qty) }.map do |mat_name, grp|
        name = mat_name || "(未赋材质)"
        part_groups = grp.group_by { |i| Calculator.face_orientation(i.normal) }
        floor_area = (part_groups['floor'] || []).sum(&:qty).round(2)
        wall_area  = (part_groups['wall']  || []).sum(&:qty).round(2)
        ceil_area  = (part_groups['ceiling'] || []).sum(&:qty).round(2)
        total_area = grp.sum(&:qty).round(2)
        [
          name,
          grp.size.to_s,
          total_area.to_s,
          floor_area > 0 ? floor_area.to_s : "-",
          wall_area > 0 ? wall_area.to_s : "-",
          ceil_area > 0 ? ceil_area.to_s : "-"
        ]
      end

      Debug.table(
        ["材质名", "面数", "总面积(m²)", "地面(m²)", "墙面(m²)", "天花(m²)"],
        rows
      )

      # 洞口详情
      if openings.any?
        Debug.subsection "洞口详情"
        openings.group_by { |o| o.host_face_ids.empty? ? "独立洞口(host为空)" : "关联洞口" }.each do |type, ops|
          Debug.log "#{type}: #{ops.size}个, 总面积=#{ops.sum(&:area).round(2)}m²"
        end
      end

      { items: items, openings: openings }
    end

    private

    def collect_faces(entity, path, transform, face_set, items, openings, opening_face_ids)
      case entity
      when Sketchup::Face
        return if face_set.include?(entity.entityID)
        face_set.add(entity.entityID)

        if entity.hidden? || !entity.visible?
          @skipped_hidden += 1
          return
        end

        mat = entity.material || entity.back_material
        mat_name = mat&.name

        if mat && mat_name && !@material_colors.key?(mat_name)
          color = mat.color
          @material_colors[mat_name] = {
            r: color.red, g: color.green, b: color.blue, a: mat.alpha
          }
        end

        comp_path = path.map { |c| c.respond_to?(:name) ? c.name : c.to_s }
        comp_path_ids = path.map { |c| c.respond_to?(:entityID) ? c.entityID : 0 }

        # DEBUG: print path for first few faces
        if items.size < 3
          path_detail = path.map { |c| "#{c.class.name.split('::').last}(name=#{c.respond_to?(:name) ? c.name.inspect : 'N/A'}, entityID=#{c.respond_to?(:entityID) ? c.entityID : 'N/A'})" }
          Debug.log "  [scanner debug] face ##{items.size} path=#{path_detail.inspect} len=#{path.length}"
          Debug.log "    → comp_path=#{comp_path.inspect}"
        end

        area_m2 = compute_area(entity, transform)
        world_normal = entity.normal.transform(transform)
        world_normal.normalize! if world_normal.length > 0

        # World-space center Z of the face's bounding box, in meters.
        # Used by Calculator for thin-slab dedup (locate slab within space's z range).
        bb_center_world = entity.bounds.center.transform(transform)
        z_center_m = bb_center_world.z * 0.0254

        if area_m2 < MIN_FACE_AREA_M2
          @skipped_tiny += 1
          return
        end

        if mat&.alpha && mat.alpha < 0.5
          @skipped_transparent += 1
          unless opening_face_ids.include?(entity.entityID)
            openings << Opening.new(entity.entityID, area_m2, [])
            @pending_opening_info << {
              index: openings.size - 1,
              normal: [world_normal.x, world_normal.y, world_normal.z],
              component_path: comp_path,
              z_center: z_center_m.round(4),
              area: area_m2
            }
            opening_face_ids.add(entity.entityID)
          end
          return
        end

        bb = entity.bounds
        scale = [transform.xscale.abs, transform.yscale.abs, transform.zscale.abs].max
        dims = [bb.width * scale, bb.height * scale, bb.depth * scale].sort
        w = (dims[-2] || 0) * 0.0254
        h = (dims[-1] || 0) * 0.0254

        items << ScanItem.new(
          entity.entityID,
          mat_name,
          area_m2,
          'm2',
          :face,
          [world_normal.x, world_normal.y, world_normal.z],
          w.round(4),
          h.round(4),
          entity.layer.name,
          comp_path,
          comp_path_ids,
          z_center_m.round(4)
        )

        @progress_total += 1
        if @progress_total % @progress_step == 0
          Debug.log "  ...已扫描 #{@progress_total} 面"
        end

      when Sketchup::ComponentInstance
        new_path = path + [entity]
        new_transform = transform * entity.transformation
        entity.definition.entities.each do |child|
          collect_faces(child, new_path, new_transform, face_set, items, openings, opening_face_ids)
        end

        if opening_name?(entity.definition.name)
          op_count = 0
          op_area = 0.0
          parent_comp_path = new_path.map { |c| c.respond_to?(:name) ? c.name : c.to_s }
          entity.definition.entities.each do |child|
            if child.is_a?(Sketchup::Face) && !opening_face_ids.include?(child.entityID)
              a = compute_area(child, new_transform)
              child_normal = child.normal.transform(new_transform)
              child_normal.normalize! if child_normal.length > 0
              child_z_center = child.bounds.center.transform(new_transform).z * 0.0254
              op_area += a
              op_count += 1
              openings << Opening.new(child.entityID, a, [])
              @pending_opening_info << {
                index: openings.size - 1,
                normal: [child_normal.x, child_normal.y, child_normal.z],
                component_path: parent_comp_path,
                z_center: child_z_center.round(4),
                area: a
              }
              opening_face_ids.add(child.entityID)
            end
          end
          @named_openings += 1 if op_count > 0
          Debug.log "  🚪 命名洞口(组件): #{entity.definition.name} | #{op_count}面 | #{op_area.round(2)}m²" if op_count > 0
        end

      when Sketchup::Group
        new_path = path + [entity]
        new_transform = transform * entity.transformation
        entity.entities.each do |child|
          collect_faces(child, new_path, new_transform, face_set, items, openings, opening_face_ids)
        end

        if opening_name?(entity.name)
          op_count = 0
          op_area = 0.0
          parent_comp_path = new_path.map { |c| c.respond_to?(:name) ? c.name : c.to_s }
          entity.entities.each do |child|
            if child.is_a?(Sketchup::Face) && !opening_face_ids.include?(child.entityID)
              a = compute_area(child, new_transform)
              child_normal = child.normal.transform(new_transform)
              child_normal.normalize! if child_normal.length > 0
              child_z_center = child.bounds.center.transform(new_transform).z * 0.0254
              op_area += a
              op_count += 1
              openings << Opening.new(child.entityID, a, [])
              @pending_opening_info << {
                index: openings.size - 1,
                normal: [child_normal.x, child_normal.y, child_normal.z],
                component_path: parent_comp_path,
                z_center: child_z_center.round(4),
                area: a
              }
              opening_face_ids.add(child.entityID)
            end
          end
          @named_openings += 1 if op_count > 0
          Debug.log "  🚪 命名洞口(Group): #{entity.name} | #{op_count}面 | #{op_area.round(2)}m²" if op_count > 0
        end

      when Sketchup::Image
        # Skip images
      end
    end

    # Returns face area in m² after applying accumulated transformation.
    # face.area(transformation) returns inches² with scale applied; 1 in² = 0.00064516 m²
    def compute_area(face, transform)
      face.area(transform) * 0.00064516
    end

    # 检查名称是否匹配门窗关键词。用 .include? 避免 SketchUp 内嵌 Ruby 的正则编码问题。
    def opening_name?(name)
      return false if name.nil? || name.empty?
      n = name.downcase
      n.include?('窗') || n.include?('门') ||
        n.include?('window') || n.include?('door')
    end

    # 将洞口关联到母面：基于法向量平行 + 同容器 + 面积大于洞口
    def associate_openings_to_hosts(items, openings, pending_info)
      Debug.subsection "洞口-母面关联"

      pending_info.each do |info|
        op_idx = info[:index]
        op_normal = info[:normal]
        op_area = info[:area]
        op_path = info[:component_path]

        # 洞口所在的容器层级（透明面与母面同级；命名洞口在子组件内）
        parent_path = op_path[0..-2]

        candidates = items.select do |item|
          # 法向量平行判定
          dot = (op_normal[0] * item.normal[0] +
                 op_normal[1] * item.normal[1] +
                 op_normal[2] * item.normal[2]).abs
          dot > 0.99 &&
            item.qty > op_area &&
            (item.component_path == op_path || item.component_path == parent_path)
        end

        if candidates.any?
          # 取面积最小的候选母面（最精确的宿主）
          best = candidates.min_by(&:qty)
          openings[op_idx].host_face_ids = [best.face_id]
          Debug.log "  洞口 ID=#{openings[op_idx].entity_id} (#{op_area.round(2)}m²) → 母面 ID=#{best.face_id} (#{best.qty.round(2)}m²)"
        else
          Debug.log "  洞口 ID=#{openings[op_idx].entity_id} (#{op_area.round(2)}m²) → 未找到母面"
        end
      end

      linked = openings.count { |o| !o.host_face_ids.empty? }
      unlinked = openings.count { |o| o.host_face_ids.empty? }
      Debug.log "  关联结果: #{linked}个已关联 / #{unlinked}个未关联"
    end
  end
end