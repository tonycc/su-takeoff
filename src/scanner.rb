require 'set'

module SuTakeoff
  class Scanner
    attr_reader :material_colors, :entity_contexts

    IDENTITY = Geom::Transformation.new

    # 小于此面积的面视为建模碎片（CAD 导入圆弧炸开等），不参与统计
    MIN_FACE_AREA_M2 = 0.001  # 10 cm²

    DEBUG = false

    def initialize
      @model = Sketchup.active_model
      @material_colors = {}
      @entity_contexts = {}
      begin
        @policy = PluginState.instance.takeoff_policy
      rescue => e
        puts "[SuTakeoff] Warning: failed to build TakeoffPolicy: #{e.message}"
        @policy = nil
      end
      # 模型单位 → 米的换算系数
      @model_unit_to_m = case (@model.options['UnitsOptions']['LengthUnit'] rescue 0)
        when 0 then 0.0254  # inches
        when 1 then 0.3048  # feet
        when 2 then 0.001   # mm
        when 3 then 0.01    # cm
        when 4 then 1.0     # m
        else 0.0254
      end
    end

    # Scan entire model or selected faces
    def scan(selection_only: false)
      items = []
      openings = []
      face_set = Set.new
      opening_face_ids = Set.new
      @pending_opening_info = []

      selection_context = selection_only && !@model.selection.empty?
      entities =
        if selection_context
          @model.selection.to_a
        else
          @model.entities.to_a
        end

      if DEBUG
        puts "[Scanner] 顶层实体 #{entities.size} 个:"
        entities.each do |e|
          type = e.is_a?(Sketchup::Group) ? 'Group' : (e.is_a?(Sketchup::ComponentInstance) ? 'Component' : e.class.to_s)
          name = (e.respond_to?(:name) && e.name) || (e.respond_to?(:definition) && e.definition.name) || '(无名)'
          layer = (e.respond_to?(:layer) && e.layer) ? e.layer.name : '?'
          mat = (e.respond_to?(:material) && e.material) ? e.material.name : '(无材质)'
          puts "  [#{type}] name=\"#{name}\" eid=#{e.entityID} layer=\"#{layer}\" mat=\"#{mat}\""
        end
      end

      base_path = selection_context ? Array(@model.active_path) : []
      base_transform = selection_context ? (@model.edit_transform rescue IDENTITY) : IDENTITY

      entities.each do |entity|
        collect_faces(entity, base_path, base_transform, face_set, items, openings, opening_face_ids)
      end

      if DEBUG
        puts "[Scanner] 收集完成: items=#{items.size} openings=#{openings.size}"
        items.group_by { |i| i.kind }.each { |k, v| puts "  kind=#{k}: #{v.size} 个" }
      end

      # ---- 洞口-母面关联 ----
      associate_openings_to_hosts(items, openings, @pending_opening_info)

      hierarchy = collect_hierarchy(entities, base_path)

      { items: items, openings: openings, hierarchy: hierarchy }
    end

    # 局部重扫：只重扫 entity_id 对应的容器子树，返回 { items:, openings: }。
    # ctx 来自主扫描时按完整实例路径存入的 entity_contexts[path_key]。
    def scan_entity(entity_id, ctx)
      entity = @model.find_entity_by_id(entity_id)
      return nil unless entity

      path      = (ctx[:path_ids] || []).map { |id| @model.find_entity_by_id(id) }.compact
      transform = Geom::Transformation.new(ctx[:transform])

      new_items            = []
      new_openings         = []
      @pending_opening_info = []
      face_set             = Set.new
      opening_face_ids     = Set.new

      collect_faces(entity, path, transform, face_set,
                    new_items, new_openings, opening_face_ids,
                    ctx[:effective_layer], ctx[:effective_tag], ctx[:effective_method])
      associate_openings_to_hosts(new_items, new_openings, @pending_opening_info)

      { items: new_items, openings: new_openings }
    end

    private

    # effective_layer: 父级容器有图层规则时，传播其图层名以覆盖子面自身的图层。
    def collect_faces(entity, path, transform, face_set, items, openings, opening_face_ids,
                      effective_layer = nil, effective_tag = nil, effective_method = nil)
      case entity
      when Sketchup::Face
        collect_face(entity, path, transform, face_set, items, openings, opening_face_ids,
                     effective_layer, effective_tag, effective_method)

      when Sketchup::ComponentInstance, Sketchup::Group
        collect_container(entity, path, transform, items, openings, opening_face_ids,
                          effective_layer, effective_tag, effective_method)

      when Sketchup::Image
        # Skip images
      end
    end

    # ---- Face 分支 ----

    def collect_face(entity, path, transform, face_set, items, openings, opening_face_ids,
                     effective_layer, effective_tag, effective_method)
      comp_path_ids = path.map { |c| c.respond_to?(:entityID) ? c.entityID : 0 }
      occurrence_key = ScanItem.path_key(comp_path_ids + [entity.entityID])
      return if face_set.include?(occurrence_key)
      face_set.add(occurrence_key)
      return if entity.hidden? || !entity.visible?

      mat = entity.material || entity.back_material
      mat_name = mat&.name

      # 面自身没赋材质时，向上取容器的材质（给群组赋材质而未给面赋材质的常见做法）
      if mat_name.nil? && !path.empty?
        parent = path.last
        pmat = (parent.respond_to?(:material) && parent.material) || nil
        mat_name = pmat&.name
        if DEBUG && mat_name
          puts "[Scanner] Face ##{entity.entityID} 材质继承自容器: \"#{mat_name}\""
        end
      end

      comp_path     = path.map { |c| container_display_name(c) }
      comp_path_persistent_ids = path.map { |c| persistent_id(c) }

      area_m2 = compute_area(entity, transform)
      if DEBUG
        puts "[Scanner] Face ##{entity.entityID} mat=\"#{mat_name}\" " \
             "layer=\"#{effective_layer || entity.layer.name}\" area=#{area_m2.round(4)}"
      end

      world_points = transformed_face_points(entity, transform)
      world_normal = transformed_face_normal(entity, transform, world_points)
      bb_center_world = points_center(world_points) || entity.bounds.center.transform(transform)
      z_center_m = bb_center_world.z * 0.0254

      return if area_m2 < MIN_FACE_AREA_M2

      if mat&.alpha && mat.alpha < 0.5
        unless opening_face_ids.include?(occurrence_key)
          openings << Opening.new(
            entity.entityID, area_m2, [], comp_path_ids, persistent_id(entity), [],
            (bb_center_world.x * 0.0254).round(4),
            (bb_center_world.y * 0.0254).round(4),
            z_center_m.round(4),
            [world_normal.x, world_normal.y, world_normal.z]
          )
          @pending_opening_info << {
            index: openings.size - 1,
            normal: [world_normal.x, world_normal.y, world_normal.z],
            component_path_ids: comp_path_ids,
            center_x: bb_center_world.x * 0.0254,
            center_y: bb_center_world.y * 0.0254,
            z_center: z_center_m.round(4),
            area: area_m2
          }
          opening_face_ids.add(occurrence_key)
        end
        return
      end

      w, h = face_dimensions_m(world_points, world_normal)

      face_tags = read_takeoff_tags(entity)
      if effective_method && (face_tags.nil? || !face_tags[:method])
        face_tags ||= {}
        face_tags[:method] = effective_method.to_s
      end
      face_tag = (face_tags && face_tags[:tag]) || effective_tag

      items << ScanItem.face(
        face_id: entity.entityID,
        su_material: mat_name,
        area: area_m2,
        normal: [world_normal.x, world_normal.y, world_normal.z],
        width: w.round(4),
        height: h.round(4),
        layer_name: effective_layer || entity.layer.name,
        component_path: comp_path,
        component_path_ids: comp_path_ids,
        z_center: z_center_m.round(4),
        tags: face_tags,
        tag: face_tag,
        center_x: (bb_center_world.x * 0.0254).round(4),
        center_y: (bb_center_world.y * 0.0254).round(4),
        face_persistent_id: persistent_id(entity),
        component_path_persistent_ids: comp_path_persistent_ids
      )
    end

    # ---- Container 分支（ComponentInstance / Group 共用） ----
    #
    # 两者的差异已由 helper 封装：
    #   container_definition_name → ComponentInstance: definition.name; Group: name
    #   definition_entities       → ComponentInstance: definition.entities; Group: entities

    def collect_container(entity, path, transform, items, openings, opening_face_ids,
                          effective_layer, effective_tag, effective_method)
      return if entity.hidden? || !entity.visible? || (entity.layer && !entity.layer.visible?)

      # 记录本容器的扫描上下文，供 set_entity_tag 局部重扫使用
      entity_path_ids = path.map { |c| c.respond_to?(:entityID) ? c.entityID : 0 } + [entity.entityID]
      @entity_contexts[ScanItem.path_key(entity_path_ids)] = {
        entity_id:        entity.entityID,
        entity_path_ids:  entity_path_ids,
        path_ids:         path.map { |c| c.respond_to?(:entityID) ? c.entityID : 0 },
        transform:        transform.to_a,
        effective_layer:  effective_layer,
        effective_tag:    effective_tag,
        effective_method: effective_method
      }

      # 复合标签：method 含 '+' 时拆开，产出多条容器级 ScanItem，不再下钻
      tags = read_takeoff_tags(entity)
      if tags && tags[:method] && tags[:method].to_s.include?('+')
        compound_methods = tags[:method].to_s.split('+').map(&:strip).map(&:to_sym)
        compound_methods.each do |sym|
          next unless %i[count length volume].include?(sym)
          result = emit_solid_by_method(entity, path, transform, sym, tags, effective_tag)
          items << result if result
        end
        return unless compound_methods.include?(:area)

        # 复合标签包含 area 时，其余量纲已按容器产出，面积继续下钻到面并显式传播。
        effective_tag = tags[:tag] || effective_tag
        effective_method = :area
      end

      def_name = container_definition_name(entity)

      # 容器级整体量取（标签/图层规则命中 length/volume/count → 不下钻）
      if (solid_item = try_emit_solid(entity, path, transform, effective_tag))
        puts "[Scanner] #{entity.class} ##{entity.entityID} → solid #{solid_item.kind} mat=#{solid_item.su_material}" if DEBUG
        items << solid_item
        return
      end

      # 纯边线容器（无面/子组件/子群组）：
      #   - 决议判定 method：AttrDict / 图层 / 几何启发
      #   - :length → 用 PathSum 累加所有 Edge 长度，emit :linear_solid
      #   - 其他 → 兼容旧行为 emit_edge_only_item（按件数）
      unless has_collectable_geometry?(entity)
        if has_any_edge?(entity)
          method = decide_pure_edges_method(entity)
          if method == :length
            length_m = compute_path_length(entity, transform)
            if length_m && length_m > 0
              puts "[Scanner] #{entity.class} ##{entity.entityID} \"#{def_name}\" 纯边线 → 路径长度 #{length_m}m" if DEBUG
              items << emit_path_linear_solid(entity, path, transform, length_m, effective_tag)
              return
            end
          end
          puts "[Scanner] #{entity.class} ##{entity.entityID} \"#{def_name}\" 无线框面 → 按件数统计" if DEBUG
          items << emit_edge_only_item(entity, path, effective_tag)
        end
        return
      end

      puts "[Scanner] #{entity.class} ##{entity.entityID} \"#{def_name}\" layer=\"#{entity.layer&.name || '?'}\" → 下钻" if DEBUG

      new_path      = path + [entity]
      new_transform = transform * entity.transformation
      # 每个容器使用独立 face_set：ComponentInstance 共享定义故必须；Group 也独立以防冲突
      local_face_set = Set.new
      child_layer   = container_effective_layer(entity, effective_layer)
      child_tag     = container_effective_tag(entity, effective_tag)
      child_method  = container_effective_method(entity, effective_method)

      if DEBUG
        puts "[Scanner]   effective_layer=#{effective_layer.inspect} → child_layer=#{child_layer.inspect}"
        child_count = 0
      end

      child_ents = definition_entities(entity)
      child_ents.each do |child|
        child_count += 1 if DEBUG && child.is_a?(Sketchup::Face)
        collect_faces(child, new_path, new_transform, local_face_set,
                      items, openings, opening_face_ids, child_layer, child_tag, child_method)
      end
      puts "[Scanner]   #{entity.class} ##{entity.entityID} 子面数=#{child_count}" if DEBUG

      # 命名洞口组件：把内部面注册为洞口
      return unless opening_name?(def_name)

      # 门窗实体通常有前后两个等面积面；只用最大直接子面代表净洞口，避免双扣。
      opening_face = child_ents.select { |child| child.is_a?(Sketchup::Face) }
                               .max_by { |child| compute_area(child, new_transform) }
      return unless opening_face

      opening_path_ids = new_path.map { |c| c.respond_to?(:entityID) ? c.entityID : 0 }
      opening_key = ScanItem.path_key(opening_path_ids + [opening_face.entityID])
      return if opening_face_ids.include?(opening_key)

      a = compute_area(opening_face, new_transform)
      opening_points = transformed_face_points(opening_face, new_transform)
      child_normal = transformed_face_normal(opening_face, new_transform, opening_points)
      child_center = points_center(opening_points) || opening_face.bounds.center.transform(new_transform)
      child_z_center = child_center.z * 0.0254
      openings << Opening.new(
        opening_face.entityID, a, [], opening_path_ids, persistent_id(opening_face), [],
        (child_center.x * 0.0254).round(4), (child_center.y * 0.0254).round(4),
        child_z_center.round(4), [child_normal.x, child_normal.y, child_normal.z]
      )
      @pending_opening_info << {
        index: openings.size - 1,
        normal: [child_normal.x, child_normal.y, child_normal.z],
        component_path_ids: opening_path_ids,
        center_x: child_center.x * 0.0254,
        center_y: child_center.y * 0.0254,
        z_center: child_z_center.round(4),
        area: a
      }
      opening_face_ids.add(opening_key)
    end

    # ---- 以下方法保持不变 ----

    def compute_area(face, transform)
      face.area(transform) * 0.00064516
    end

    def transformed_face_points(face, transform)
      vertices = face.respond_to?(:outer_loop) ? face.outer_loop.vertices : face.vertices
      vertices.map { |vertex| vertex.position.transform(transform) }
    rescue
      []
    end

    def transformed_face_normal(face, transform, points)
      vectors = []
      if points.length >= 3
        origin = points.first
        points[1..].each { |point| vectors << (point - origin) }
      end
      normal = nil
      vectors.each_with_index do |a, index|
        vectors[(index + 1)..].to_a.each do |b|
          candidate = vector_cross(a, b)
          if candidate.length > 1.0e-9
            normal = candidate
            break
          end
        end
        break if normal
      end
      fallback = face.normal.transform(transform)
      normal ||= fallback
      normal.normalize! if normal.length > 0
      normal
    end

    def points_center(points)
      return nil if points.empty?
      Geom::Point3d.new(
        points.sum(&:x) / points.length.to_f,
        points.sum(&:y) / points.length.to_f,
        points.sum(&:z) / points.length.to_f
      )
    end

    def face_dimensions_m(points, normal)
      return [0.0, 0.0] if points.length < 2
      edge_vectors = points.each_with_index.map { |point, index| points[(index + 1) % points.length] - point }
      u_axis = edge_vectors.max_by(&:length)
      return [0.0, 0.0] unless u_axis && u_axis.length > 0
      u_axis = u_axis.normalize
      v_axis = vector_cross(normal, u_axis)
      v_axis.normalize! if v_axis.length > 0
      origin = points.first
      u_values = points.map { |point| vector_dot(point - origin, u_axis) }
      v_values = points.map { |point| vector_dot(point - origin, v_axis) }
      dims = [(u_values.max - u_values.min).abs, (v_values.max - v_values.min).abs].sort
      [dims[0].to_f * 0.0254, dims[1].to_f * 0.0254]
    end

    def vector_dot(a, b)
      a.x * b.x + a.y * b.y + a.z * b.z
    end

    def vector_cross(a, b)
      Geom::Vector3d.new(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x
      )
    end

    def read_takeoff_tags(entity)
      return nil unless entity.respond_to?(:attribute_dictionary)
      dict = entity.attribute_dictionary('su_takeoff') rescue nil
      return nil unless dict
      out = {}
      out[:method]      = dict['method']      if dict['method']
      out[:material]    = dict['material']    if dict['material']
      out[:tag]         = dict['tag']         if dict['tag']
      # 新模型优先保存 persistent_id；baseline_id 仅兼容旧数据/当前会话。
      out[:baseline_id] = dict['baseline_persistent_id'] || dict['baseline_id'] if dict['baseline_persistent_id'] || dict['baseline_id']
      out.empty? ? nil : out
    end

    def try_emit_solid(entity, path, transform, effective_tag = nil)
      return nil unless @policy
      tags        = read_takeoff_tags(entity)
      attr_method = tags && tags[:method]
      layer       = entity.layer && entity.layer.name

      # 档 1+2：AttrDict / 图层规则（原有）
      method = @policy.resolve_container(layer_name: layer, attr_method: attr_method)

      # 档 3：策略自动匹配（命名约定；当前无策略带匹配规则，处于休眠）
      if method.nil?
        matched_strategy = find_container_strategy(entity)
        if matched_strategy && %i[length count volume].include?(matched_strategy.method)
          method = matched_strategy.method
        end
      end

      return nil unless method
      emit_solid_by_method(entity, path, transform, method, tags, effective_tag)
    end

    # 容器级策略匹配：根据 entity 的 definition_name 查找命名匹配的非默认策略。
    # （当前内置策略均无 match_rules，本方法处于休眠，命中恒为 nil。）
    def find_container_strategy(entity)
      return nil unless @policy
      def_name = container_definition_name(entity)
      return nil if def_name.nil? || def_name.empty?
      registry = @policy.strategies
      context = { definition_name: def_name }
      registry.all.each do |s|
        next if s.name == registry.default_for(s.method)&.name
        return s if s.matches?(nil, context)
      end
      nil
    end

    def emit_solid_by_method(entity, path, transform, method, tags, effective_tag = nil)
      comp_path     = path.map { |c| container_display_name(c) } + [container_display_name(entity)]
      comp_path_ids = path.map { |c| c.respond_to?(:entityID) ? c.entityID : 0 } + [entity.entityID]
      comp_path_persistent_ids = path.map { |c| persistent_id(c) } + [persistent_id(entity)]

      content_transform = transform * entity.transformation
      local_bounds = entity.respond_to?(:definition) ? entity.definition.bounds : entity.bounds
      dims_in = transformed_local_bounds_dimensions(local_bounds, content_transform).sort
      w = (dims_in[0] || 0) * 0.0254
      h = (dims_in[1] || 0) * 0.0254
      d = (dims_in[2] || 0) * 0.0254

      mat_name =
        (tags && tags[:material]) ||
        (entity.respond_to?(:material) && entity.material&.name) ||
        first_child_face_material(entity) ||
        container_definition_name(entity)

      bb_center_world = local_bounds.center.transform(content_transform)
      z_center_m      = bb_center_world.z * 0.0254
      layer           = entity.layer && entity.layer.name
      item_tag        = (tags && tags[:tag]) || effective_tag

      case method
      when :length
        length_m = compute_length_via_strategy(entity, transform) ||
                   compute_linear_length(entity, transform) || d
        item = ScanItem.linear_solid(
          face_id: entity.entityID, su_material: mat_name,
          length: length_m.round(4), width: w.round(4), height: h.round(4), depth: d.round(4),
          layer_name: layer, component_path: comp_path, component_path_ids: comp_path_ids,
          z_center: z_center_m.round(4), tags: tags, tag: item_tag,
          face_persistent_id: persistent_id(entity),
          component_path_persistent_ids: comp_path_persistent_ids
        )
        if DEBUG
          puts "[Scanner] emit_solid :length → qty_length=#{item.qty_length}m " \
               "bbox w=#{w.round(4)} h=#{h.round(4)} d=#{d.round(4)} mat=#{mat_name}"
        end
        item
      when :volume
        vol_in3 = entity.respond_to?(:volume) ? entity.volume : 0
        vol_m3  = if vol_in3.is_a?(Numeric) && vol_in3 > 0
                    vol_in3 * 1.6387e-5 * transformation_volume_scale(transform)
                  else
                    w * h * d
                  end
        ScanItem.solid(
          face_id: entity.entityID, su_material: mat_name,
          volume: vol_m3.round(4), width: w.round(4), height: h.round(4), depth: d.round(4),
          layer_name: layer, component_path: comp_path, component_path_ids: comp_path_ids,
          z_center: z_center_m.round(4), tags: tags, tag: item_tag,
          face_persistent_id: persistent_id(entity),
          component_path_persistent_ids: comp_path_persistent_ids
        )
      when :count
        ScanItem.count_solid(
          face_id: entity.entityID, su_material: mat_name,
          layer_name: layer, component_path: comp_path, component_path_ids: comp_path_ids,
          tags: tags, tag: item_tag,
          face_persistent_id: persistent_id(entity),
          component_path_persistent_ids: comp_path_persistent_ids
        )
      end
    end

    # 找匹配的 Strategy，如果它暴露 compute_length 就用，让专用算法生效
    # （如某些专用策略可强制使用 EdgeBased 等算法）。
    # 找不到匹配策略或策略没有 compute_length 时返回 nil，
    # 调用方走默认 compute_linear_length（Chained）。
    def compute_length_via_strategy(entity, transform)
      return nil unless @policy
      def_name = container_definition_name(entity)
      return nil if def_name.nil? || def_name.empty?

      context = { definition_name: def_name, hint_method: :length }
      registry = @policy.strategies
      default = registry.default_for(:length)
      strategy = registry.all.find do |s|
        s.method == :length &&
          (default.nil? || s.name != default.name) &&
          s.matches?(nil, context)
      end
      return nil unless strategy && strategy.respond_to?(:compute_length)

      ctx = build_length_ctx(entity, transform)
      return nil unless ctx
      strategy.compute_length(entity, ctx)
    end

    def container_effective_layer(entity, parent_effective)
      return parent_effective unless @policy
      layer = entity.layer&.name
      return parent_effective unless layer
      @policy.layer_has_rule?(layer) ? layer : parent_effective
    end

    def container_effective_tag(entity, parent_effective_tag)
      return parent_effective_tag unless @policy
      tags     = read_takeoff_tags(entity)
      tag_name = tags && tags[:tag]
      return parent_effective_tag unless tag_name
      @policy.tag_has_def?(tag_name) ? tag_name : parent_effective_tag
    end

    def container_effective_method(entity, parent_method)
      return parent_method if parent_method
      tags = read_takeoff_tags(entity)
      return nil unless tags && tags[:method]
      m = tags[:method].to_sym
      m if TakeoffPolicy::METHODS.include?(m)
    end

    def compute_linear_length(entity, transform)
      def_name = container_definition_name(entity)
      puts "[linear_length] ====== 实体: \"#{def_name}\" entityID=#{entity.entityID} ======" if DEBUG

      ctx = build_length_ctx(entity, transform)
      return nil unless ctx

      chained = LengthCalculators::Chained.new(
        LengthCalculators::Baseline.new,
        LengthCalculators::VolumeBased.new,
        LengthCalculators::EdgeBased.new
      )
      chained.compute(entity, ctx)
    end

    def build_length_ctx(entity, parent_transform)
      ents = definition_entities(entity)
      return nil unless ents

      content_transform = parent_transform * entity.transformation
      edges = collect_edges(ents, content_transform)
      # Baseline 也可能位于嵌套容器中，不能因直接子级没有边就提前返回。
      return nil if edges.empty?

      tags = read_takeoff_tags(entity)
      {
        entities:        ents,
        edges:           edges,
        edge_scale:      1.0,
        scale:           1.0,
        model_unit_to_m: @model_unit_to_m,
        baseline_id:     tags && tags[:baseline_id],
        volume_m3:       volume_m3_for(entity, parent_transform),
        debug:           DEBUG
      }
    end

    def collect_edges(ents, transform)
      edges = []
      ents.each do |e|
        if e.is_a?(Sketchup::Edge)
          start_point = e.start.position.transform(transform)
          end_point = e.end.position.transform(transform)
          vector = end_point - start_point
          next if vector.length <= 0
          dir = vector.normalize
          len_m = vector.length.to_f * 0.0254
          dkey = [dir.x.round(3).abs, dir.y.round(3).abs, dir.z.round(3).abs]
          edges << {
            dkey: dkey, len: len_m, len_raw: vector.length,
            entity_id: e.entityID, persistent_id: persistent_id(e)
          }
        elsif e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
          child_entities = definition_entities(e)
          edges.concat(collect_edges(child_entities, transform * e.transformation)) if child_entities
        end
      end
      edges
    end

    def transformed_local_bounds_dimensions(bounds, transform)
      origin = bounds.min
      x_point = Geom::Point3d.new(bounds.max.x, origin.y, origin.z).transform(transform)
      y_point = Geom::Point3d.new(origin.x, bounds.max.y, origin.z).transform(transform)
      z_point = Geom::Point3d.new(origin.x, origin.y, bounds.max.z).transform(transform)
      world_origin = origin.transform(transform)
      [x_point.distance(world_origin), y_point.distance(world_origin), z_point.distance(world_origin)]
    end

    def transformation_volume_scale(transform)
      x = transform.xaxis
      y = transform.yaxis
      z = transform.zaxis
      vector_dot(x, vector_cross(y, z)).abs
    rescue
      transform.xscale.abs * transform.yscale.abs * transform.zscale.abs
    end

    def volume_m3_for(entity, parent_transform)
      return nil unless entity.respond_to?(:volume)
      volume = entity.volume
      return nil unless volume.is_a?(Numeric) && volume > 0
      volume * 1.6387e-5 * transformation_volume_scale(parent_transform)
    end

    def first_child_face_material(entity)
      ents = definition_entities(entity)
      return nil unless ents
      ents.each do |e|
        if e.is_a?(Sketchup::Face)
          mat = e.material || e.back_material
          return mat.name if mat&.name
        end
      end
      nil
    end

    def container_definition_name(entity)
      if entity.respond_to?(:definition)
        entity.definition.name
      elsif entity.respond_to?(:name)
        entity.name
      end
    end

    def container_display_name(entity)
      explicit = entity.respond_to?(:name) ? entity.name.to_s.strip : ''
      explicit.empty? ? container_definition_name(entity).to_s : explicit
    end

    def persistent_id(entity)
      return nil unless entity.respond_to?(:persistent_id)

      entity.persistent_id
    rescue
      nil
    end

    def definition_entities(entity)
      if entity.respond_to?(:definition)
        entity.definition.entities
      elsif entity.respond_to?(:entities)
        entity.entities
      end
    end

    def has_collectable_geometry?(entity)
      ents = definition_entities(entity)
      return false unless ents
      ents.any? { |e| e.is_a?(Sketchup::Face) || e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
    end

    def has_any_edge?(entity)
      ents = definition_entities(entity)
      return false unless ents
      ents.any? { |e| e.is_a?(Sketchup::Edge) }
    end

    def emit_edge_only_item(entity, path, effective_tag)
      tags     = read_takeoff_tags(entity)
      mat_name = (tags && tags[:material]) ||
                 (entity.respond_to?(:material) && entity.material&.name) ||
                 container_definition_name(entity)

      comp_path     = path.map { |c| container_display_name(c) } + [container_display_name(entity)]
      comp_path_ids = path.map { |c| c.respond_to?(:entityID) ? c.entityID : 0 } + [entity.entityID]
      comp_path_persistent_ids = path.map { |c| persistent_id(c) } + [persistent_id(entity)]

      ScanItem.instance(
        face_id: entity.entityID,
        su_material: mat_name,
        layer_name: entity.layer.name,
        component_path: comp_path,
        component_path_ids: comp_path_ids,
        face_persistent_id: persistent_id(entity),
        component_path_persistent_ids: comp_path_persistent_ids,
        tag: (tags && tags[:tag]) || effective_tag
      )
    end

    # 纯边线容器的 method 决议（3 档优先级）：
    #   1. AttrDict 显式 method
    #   2. 图层规则
    #   3. 几何启发：≥2 个不同方向的边 = 路径线 → :length
    # 都未命中 → :count（兼容旧行为）
    def decide_pure_edges_method(entity)
      # 1. AttrDict
      tags = read_takeoff_tags(entity)
      if tags && tags[:method]
        sym = tags[:method].to_sym
        return sym if %i[length count volume].include?(sym)
      end

      # 2. 图层规则
      if @policy
        layer = entity.layer && entity.layer.name
        if layer
          m = @policy.resolve_container(layer_name: layer)
          return m if m
        end
      end

      # 3. 几何启发
      return :length if @policy&.heuristics_enabled? && path_like_geometry?(entity)

      :count
    end

    # 几何特征：纯边线且至少 2 个不同方向 → 折线路径（电线/管道特征）。
    # 单段直线不算（避免误判单一杆件）。
    def path_like_geometry?(entity)
      ents = definition_entities(entity)
      return false unless ents
      edges = ents.select { |e| e.is_a?(Sketchup::Edge) }
      return false if edges.size < 2
      dkeys = edges.map { |e|
        dir = e.line[1].normalize! rescue nil
        next nil unless dir
        [dir.x.round(3).abs, dir.y.round(3).abs, dir.z.round(3).abs]
      }.compact.uniq
      dkeys.size >= 2
    end

    # 纯边线容器的路径总长（PathSum）。
    def compute_path_length(entity, transform)
      ctx = build_length_ctx(entity, transform)
      return nil unless ctx
      LengthCalculators::PathSum.new.compute(entity, ctx)
    end

    # 产出路径长度 ScanItem（kind=:linear_solid）。
    def emit_path_linear_solid(entity, path, transform, length_m, effective_tag)
      tags = read_takeoff_tags(entity)
      comp_path     = path.map { |c| container_display_name(c) } + [container_display_name(entity)]
      comp_path_ids = path.map { |c| c.respond_to?(:entityID) ? c.entityID : 0 } + [entity.entityID]
      comp_path_persistent_ids = path.map { |c| persistent_id(c) } + [persistent_id(entity)]
      mat_name = (tags && tags[:material]) ||
                 (entity.respond_to?(:material) && entity.material&.name) ||
                 container_definition_name(entity)
      bb_center_world = entity.bounds.center.transform(transform)
      z_center_m      = bb_center_world.z * 0.0254
      layer           = entity.layer && entity.layer.name
      item_tag        = (tags && tags[:tag]) || effective_tag

      ScanItem.linear_solid(
        face_id: entity.entityID,
        su_material: mat_name,
        length: length_m.round(4),
        layer_name: layer,
        component_path: comp_path,
        component_path_ids: comp_path_ids,
        face_persistent_id: persistent_id(entity),
        component_path_persistent_ids: comp_path_persistent_ids,
        z_center: z_center_m.round(4),
        tags: tags,
        tag: item_tag
      )
    end

    def opening_name?(name)
      return false if name.nil? || name.empty?
      n = name.downcase
      n.include?('窗') || n.include?('门') ||
        n.include?('window') || n.include?('door')
    end

    def associate_openings_to_hosts(items, openings, pending_info)
      return if pending_info.empty?

      # 按完整实例路径建索引，避免同名/共享定义实例串联。
      path_index = {}
      items.each do |item|
        next if item.normal.nil?
        (path_index[ScanItem.path_key(item.component_path_ids)] ||= []) << item
      end

      pending_info.each do |info|
        op_idx      = info[:index]
        op_normal   = info[:normal]
        op_area     = info[:area]
        op_path     = Array(info[:component_path_ids])
        parent_path = op_path[0..-2]

        candidate_paths = [op_path, parent_path].uniq
        candidates = candidate_paths.flat_map { |p| path_index[ScanItem.path_key(p)] || [] }.select do |item|
          dot = (op_normal[0] * item.normal[0] +
                 op_normal[1] * item.normal[1] +
                 op_normal[2] * item.normal[2]).abs
          dot > 0.99 && item.qty > op_area && opening_center_on_face?(info, item)
        end

        next unless candidates.any?
        host = candidates.min_by(&:qty)
        openings[op_idx].host_face_ids = [host.face_id]
        openings[op_idx].host_face_keys = [host.face_occurrence_key]
      end
    end

    def opening_center_on_face?(info, item)
      return false if item.center_x.nil? || item.center_y.nil? || item.z_center.nil?
      return false if info[:center_x].nil? || info[:center_y].nil? || info[:z_center].nil?

      dx = info[:center_x].to_f - item.center_x.to_f
      dy = info[:center_y].to_f - item.center_y.to_f
      dz = info[:z_center].to_f - item.z_center.to_f
      n = item.normal
      plane_distance = (dx * n[0] + dy * n[1] + dz * n[2]).abs
      return false if plane_distance > 0.05

      total_sq = dx * dx + dy * dy + dz * dz
      in_plane_distance = Math.sqrt([total_sq - plane_distance * plane_distance, 0.0].max)
      host_extent = [item.width, item.height].compact.map(&:to_f).max.to_f / 2.0
      opening_extent = Math.sqrt(info[:area].to_f) / 2.0
      in_plane_distance <= host_extent + opening_extent
    end

    def collect_hierarchy(entities, base_path = [])
      base_ids = base_path.map { |e| e.respond_to?(:entityID) ? e.entityID : 0 }
      base_persistent_ids = base_path.map { |e| persistent_id(e) }
      children = collect_hierarchy_children(
        entities, base_path.length + 1, base_ids, base_persistent_ids
      )
      unless base_path.empty?
        nested_children = children
        base_path.each_with_index.to_a.reverse_each do |(entity, index)|
          path_ids = base_ids.first(index + 1)
          persistent_path_ids = base_persistent_ids.first(index + 1)
          nested_children = [hierarchy_node_for_entity(
            entity, index + 1, path_ids, persistent_path_ids, nested_children
          )]
        end
        children = nested_children
      end

      {
        name: '(模型根)',
        entity_id: 0,
        occurrence_key: '',
        component_path_ids: [],
        component_path_persistent_ids: [],
        kind: 'root',
        definition_name: nil,
        depth: 0,
        hidden: false,
        children: children
      }
    end

    def collect_hierarchy_children(entities, depth = 1, parent_ids = [], parent_persistent_ids = [])
      nodes = []
      entities.each do |e|
        case e
        when Sketchup::ComponentInstance, Sketchup::Group
          is_hidden  = e.hidden? || !e.visible? || (e.layer && !e.layer.visible?)
          # 组件用定义名；群组也给内部定义名（如 Group#3，模型内唯一），供「产品信息」列 SKU 关联
          def_name   = (e.definition.name rescue nil)
          def_name   = e.name if (def_name.nil? || def_name.empty?) && e.is_a?(Sketchup::ComponentInstance)
          child_ents = definition_entities(e)
          path_ids = parent_ids + [e.entityID]
          persistent_path_ids = parent_persistent_ids + [persistent_id(e)]
          children = collect_hierarchy_children(child_ents, depth + 1, path_ids, persistent_path_ids)
          # 群组的内部定义名不做展示 fallback，避免 UI 出现 "Group#3" 这类系统名
          fallback   = e.is_a?(Sketchup::Group) || def_name.nil? ? '(未命名群组)' : def_name
          node_name  = (!e.name.nil? && !e.name.empty?) ? e.name : fallback
          entity_tag = ((t = read_takeoff_tags(e)) && t[:tag])
          nodes << hierarchy_node_for_entity(e, depth, path_ids, persistent_path_ids, children,
                                             name: node_name, definition_name: def_name,
                                             hidden: is_hidden, tag: entity_tag)
        end
      end
      nodes
    end

    def hierarchy_node_for_entity(entity, depth, path_ids, persistent_path_ids, children,
                                  name: nil, definition_name: nil, hidden: nil, tag: nil)
      definition_name ||= (entity.definition.name rescue nil)
      if name.nil?
        fallback = entity.is_a?(Sketchup::Group) || definition_name.nil? ? '(未命名群组)' : definition_name
        name = (!entity.name.nil? && !entity.name.empty?) ? entity.name : fallback
      end
      hidden = entity.hidden? || !entity.visible? || (entity.layer && !entity.layer.visible?) if hidden.nil?
      tag ||= ((takeoff_tags = read_takeoff_tags(entity)) && takeoff_tags[:tag])
      {
        name: name,
        entity_id: entity.entityID,
        occurrence_key: ScanItem.path_key(path_ids),
        component_path_ids: path_ids,
        component_path_persistent_ids: persistent_path_ids,
        kind: entity.is_a?(Sketchup::ComponentInstance) ? 'component_instance' : 'group',
        definition_name: definition_name,
        depth: depth,
        hidden: hidden,
        children: children,
        tag: tag
      }
    end
  end
end
