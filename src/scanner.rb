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
      @component_mapping = PluginState.instance.component_mapping
    end

    # Scan entire model or selected faces
    def scan(selection_only: false)
      items = []
      openings = []
      face_set = Set.new
      opening_face_ids = Set.new
      @pending_opening_info = []

      entities =
        if selection_only && !@model.selection.empty?
          @model.selection.to_a
        else
          @model.entities.to_a
        end

      entities.each do |entity|
        collect_faces(entity, [], IDENTITY, face_set, items, openings, opening_face_ids)
      end

      # ---- 洞口-母面关联 ----
      associate_openings_to_hosts(items, openings, @pending_opening_info)

      hierarchy = collect_hierarchy(entities)

      { items: items, openings: openings, hierarchy: hierarchy }
    end

    private

    def collect_faces(entity, path, transform, face_set, items, openings, opening_face_ids)
      case entity
      when Sketchup::Face
        return if face_set.include?(entity.entityID)
        face_set.add(entity.entityID)

        if entity.hidden? || !entity.visible?
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

        area_m2 = compute_area(entity, transform)
        world_normal = entity.normal.transform(transform)
        world_normal.normalize! if world_normal.length > 0

        # World-space center Z of the face's bounding box, in meters.
        # Used by Calculator for thin-slab dedup (locate slab within space's z range).
        bb_center_world = entity.bounds.center.transform(transform)
        z_center_m = bb_center_world.z * 0.0254

        if area_m2 < MIN_FACE_AREA_M2
          return
        end

        if mat&.alpha && mat.alpha < 0.5
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

      when Sketchup::ComponentInstance
        if entity.hidden? || !entity.visible? || (entity.layer && !entity.layer.visible?)
          return
        end
        # Check component mapping before recursing into children
        def_name = entity.definition.name
        cm_record = @component_mapping.get(def_name)
        if cm_record && cm_record.counting_method == 'aggregate' && def_name && !def_name.empty?
          comp_path = path.map { |c| c.respond_to?(:name) ? c.name : c.to_s }
          comp_path_ids = path.map { |c| c.respond_to?(:entityID) ? c.entityID : 0 } + [entity.entityID]
          items << ScanItem.new(
            entity.entityID,
            def_name,
            1,
            cm_record.unit || '个',
            :instance,
            nil,
            0,
            0,
            entity.layer.name,
            comp_path,
            comp_path_ids,
            0
          )
          return
        end

        new_path = path + [entity]
        new_transform = transform * entity.transformation
        # 每个组件实例使用独立的 face_set，避免共享定义导致面被去重
        inst_face_set = Set.new
        entity.definition.entities.each do |child|
          collect_faces(child, new_path, new_transform, inst_face_set, items, openings, opening_face_ids)
        end

        if opening_name?(entity.definition.name)
          parent_comp_path = new_path.map { |c| c.respond_to?(:name) ? c.name : c.to_s }
          entity.definition.entities.each do |child|
            if child.is_a?(Sketchup::Face) && !opening_face_ids.include?(child.entityID)
              a = compute_area(child, new_transform)
              child_normal = child.normal.transform(new_transform)
              child_normal.normalize! if child_normal.length > 0
              child_z_center = child.bounds.center.transform(new_transform).z * 0.0254
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
        end

      when Sketchup::Group
        if entity.hidden? || !entity.visible? || (entity.layer && !entity.layer.visible?)
          return
        end
        def_name = entity.name
        cm_record = @component_mapping.get(def_name)
        if cm_record && cm_record.counting_method == 'aggregate' && def_name && !def_name.empty?
          comp_path = path.map { |c| c.respond_to?(:name) ? c.name : c.to_s }
          comp_path_ids = path.map { |c| c.respond_to?(:entityID) ? c.entityID : 0 } + [entity.entityID]
          items << ScanItem.new(
            entity.entityID,
            def_name,
            1,
            cm_record.unit || '个',
            :instance,
            nil,
            0,
            0,
            entity.layer.name,
            comp_path,
            comp_path_ids,
            0
          )
          return
        end

        new_path = path + [entity]
        new_transform = transform * entity.transformation
        entity.entities.each do |child|
          collect_faces(child, new_path, new_transform, face_set, items, openings, opening_face_ids)
        end

        if opening_name?(entity.name)
          parent_comp_path = new_path.map { |c| c.respond_to?(:name) ? c.name : c.to_s }
          entity.entities.each do |child|
            if child.is_a?(Sketchup::Face) && !opening_face_ids.include?(child.entityID)
              a = compute_area(child, new_transform)
              child_normal = child.normal.transform(new_transform)
              child_normal.normalize! if child_normal.length > 0
              child_z_center = child.bounds.center.transform(new_transform).z * 0.0254
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
      pending_info.each do |info|
        op_idx = info[:index]
        op_normal = info[:normal]
        op_area = info[:area]
        op_path = info[:component_path]

        # 洞口所在的容器层级（透明面与母面同级；命名洞口在子组件内）
        parent_path = op_path[0..-2]

        candidates = items.select do |item|
          # instance 项无法向量，不可能是洞口的母面
          next if item.normal.nil?
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
        end
      end

    end

    # 模型层级骨架：单根树，根节点 entity_id=0 承载根级面
    def collect_hierarchy(entities)
      children = collect_hierarchy_children(entities)
      {
        name: '(模型根)',
        entity_id: 0,
        kind: 'root',
        definition_name: nil,
        depth: 0,
        hidden: false,
        children: children
      }
    end

    private

    def collect_hierarchy_children(entities, depth = 1)
      nodes = []
      entities.each do |e|
        case e
        when Sketchup::ComponentInstance
          def_name = e.definition.name rescue e.name
          is_hidden = e.hidden? || !e.visible? || (e.layer && !e.layer.visible?)
          children = collect_hierarchy_children(e.definition.entities, depth + 1)
          node_name = (!e.name.nil? && !e.name.empty?) ? e.name : def_name
          nodes << {
            name: node_name,
            entity_id: e.entityID,
            kind: 'component_instance',
            definition_name: def_name,
            depth: depth,
            hidden: is_hidden,
            children: children
          }
        when Sketchup::Group
          is_hidden = e.hidden? || !e.visible? || (e.layer && !e.layer.visible?)
          children = collect_hierarchy_children(e.entities, depth + 1)
          nodes << {
            name: (!e.name.nil? && !e.name.empty?) ? e.name : '(未命名群组)',
            entity_id: e.entityID,
            kind: 'group',
            definition_name: nil,
            depth: depth,
            hidden: is_hidden,
            children: children
          }
        end
      end
      nodes
    end
  end
end