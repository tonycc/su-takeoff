require 'set'

module SuTakeoff
  class Scanner
    attr_reader :material_colors

    IDENTITY = Geom::Transformation.new

    # 小于此面积的面视为建模碎片（CAD 导入圆弧炸开等），不参与统计
    MIN_FACE_AREA_M2 = 0.001  # 10 cm²

    DEBUG = false

    def initialize
      @model = Sketchup.active_model
      @material_colors = {}
      @component_mapping = PluginState.instance.component_mapping
      @policy = PluginState.instance.takeoff_policy rescue nil
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

      entities =
        if selection_only && !@model.selection.empty?
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

      entities.each do |entity|
        collect_faces(entity, [], IDENTITY, face_set, items, openings, opening_face_ids)
      end

      if DEBUG
        puts "[Scanner] 收集完成: items=#{items.size} openings=#{openings.size}"
        items.group_by { |i| i.kind }.each { |k, v| puts "  kind=#{k}: #{v.size} 个" }
      end

      # ---- 洞口-母面关联 ----
      associate_openings_to_hosts(items, openings, @pending_opening_info)

      hierarchy = collect_hierarchy(entities)

      { items: items, openings: openings, hierarchy: hierarchy }
    end

    private

    # effective_layer: 父级容器有图层规则时，传播其图层名以覆盖子面自身的图层。
    # 解决「只对 length 有效」问题 —— area/count 不会触发 try_emit_solid，
    # 子面仍用自己的图层（通常是 Layer0），导致图层规则匹配失败。
    def collect_faces(entity, path, transform, face_set, items, openings, opening_face_ids, effective_layer = nil, effective_tag = nil, effective_method = nil)
      case entity
      when Sketchup::Face
        return if face_set.include?(entity.entityID)
        face_set.add(entity.entityID)

        if entity.hidden? || !entity.visible?
          return
        end

        mat = entity.material || entity.back_material
        mat_name = mat&.name

        # 面自身没赋材质时，向上取容器的材质（给群组赋材质而未给面赋材质的常见做法）
        if mat_name.nil? && !path.empty?
          parent = path.last
          pmat = (parent.respond_to?(:material) && parent.material) || nil
          mat_name = pmat&.name
          puts "[Scanner] Face ##{entity.entityID} 材质继承自容器: \"#{mat_name}\"" if DEBUG && mat_name
          if pmat && mat_name && !@material_colors.key?(mat_name)
            @material_colors[mat_name] = {
              r: pmat.color.red, g: pmat.color.green, b: pmat.color.blue, a: pmat.alpha
            }
          end
        end

        if mat && mat_name && !@material_colors.key?(mat_name)
          color = mat.color
          @material_colors[mat_name] = {
            r: color.red, g: color.green, b: color.blue, a: mat.alpha
          }
        end

        comp_path = path.map { |c| c.respond_to?(:name) ? c.name : c.to_s }
        comp_path_ids = path.map { |c| c.respond_to?(:entityID) ? c.entityID : 0 }

        area_m2 = compute_area(entity, transform)
        puts "[Scanner] Face ##{entity.entityID} mat=\"#{mat_name}\" layer=\"#{effective_layer || entity.layer.name}\" area=#{area_m2.round(4)}" if DEBUG
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

        # 读取 entity 的算量标签，合并容器传播的 method 覆盖
        face_tags = read_takeoff_tags(entity)
        if effective_method && (face_tags.nil? || !face_tags[:method])
          face_tags ||= {}
          face_tags[:method] = effective_method.to_s
        end
        face_tag = (face_tags && face_tags[:tag]) || effective_tag

        face_item = ScanItem.face(
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
          center_y: (bb_center_world.y * 0.0254).round(4)
        )
        items << face_item

      when Sketchup::ComponentInstance
        if entity.hidden? || !entity.visible? || (entity.layer && !entity.layer.visible?)
          return
        end

        # 复合标签：method 含 '+' 时拆开，产出一条以上容器级 ScanItem
        inst_tags = read_takeoff_tags(entity)
        if inst_tags && inst_tags[:method] && inst_tags[:method].to_s.include?('+')
          inst_tags[:method].to_s.split('+').map(&:strip).each do |m|
            sym = m.to_sym
            if %i[count length volume].include?(sym)
              items << emit_solid_by_method(entity, path, transform, sym, inst_tags, effective_tag)
            end
          end
          return
        end

        # Check component mapping before recursing into children
        def_name = entity.definition.name
        cm_record = @component_mapping.get(def_name)
        if cm_record && cm_record.counting_method == 'aggregate' && def_name && !def_name.empty?
          comp_path = path.map { |c| c.respond_to?(:name) ? c.name : c.to_s }
          comp_path_ids = path.map { |c| c.respond_to?(:entityID) ? c.entityID : 0 } + [entity.entityID]
          inst_item = ScanItem.instance(
            face_id: entity.entityID,
            su_material: def_name,
            unit: cm_record.unit || '个',
            layer_name: entity.layer.name,
            component_path: comp_path,
            component_path_ids: comp_path_ids
          )
          items << inst_item
          return
        end

        # P3: 容器级整体量取（在递归子面之前判定）
        if (solid_item = try_emit_solid(entity, path, transform, effective_tag))
          puts "[Scanner] Component ##{entity.entityID} → try_emit_solid #{solid_item.kind} mat=#{solid_item.su_material}" if DEBUG
          items << solid_item
          return
        end

        # 纯边线组件（无线框面）：按件数统计，不下钻
        unless has_collectable_geometry?(entity)
          if has_any_edge?(entity)
            if DEBUG
              def_name = entity.definition.name rescue '(无)'
              puts "[Scanner] Component ##{entity.entityID} \"#{def_name}\" 无线框面 → 按件数统计"
            end
            items << emit_edge_only_item(entity, path, effective_tag)
          end
          return
        end

        if DEBUG
          def_name = entity.definition.name rescue '(无)'
          layer = entity.layer&.name || '?'
          puts "[Scanner] Component ##{entity.entityID} \"#{def_name}\" layer=\"#{layer}\" → 下钻子面"
        end

        new_path = path + [entity]
        new_transform = transform * entity.transformation
        # 每个组件实例使用独立的 face_set，避免共享定义导致面被去重
        inst_face_set = Set.new
        child_layer = container_effective_layer(entity, effective_layer)
        child_tag = container_effective_tag(entity, effective_tag)
        child_method = container_effective_method(entity, effective_method) || component_mapping_method(entity, effective_method)
        if DEBUG
          puts "[Scanner]   effective_layer=#{effective_layer.inspect} → child_layer=#{child_layer.inspect}"
          child_count = 0
        end
        entity.definition.entities.each do |child|
          child_count += 1 if DEBUG && child.is_a?(Sketchup::Face)
          collect_faces(child, new_path, new_transform, inst_face_set, items, openings, opening_face_ids, child_layer, child_tag, child_method)
        end
        puts "[Scanner]   Component ##{entity.entityID} 子面数=#{child_count}" if DEBUG

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

        # 复合标签：method 含 '+' 时拆开，产出一条以上容器级 ScanItem
        grp_tags = read_takeoff_tags(entity)
        if grp_tags && grp_tags[:method] && grp_tags[:method].to_s.include?('+')
          grp_tags[:method].to_s.split('+').map(&:strip).each do |m|
            sym = m.to_sym
            if %i[count length volume].include?(sym)
              items << emit_solid_by_method(entity, path, transform, sym, grp_tags, effective_tag)
            end
          end
          return
        end

        def_name = entity.name
        cm_record = @component_mapping.get(def_name)
        if cm_record && cm_record.counting_method == 'aggregate' && def_name && !def_name.empty?
          comp_path = path.map { |c| c.respond_to?(:name) ? c.name : c.to_s }
          comp_path_ids = path.map { |c| c.respond_to?(:entityID) ? c.entityID : 0 } + [entity.entityID]
          grp_item = ScanItem.instance(
            face_id: entity.entityID,
            su_material: def_name,
            unit: cm_record.unit || '个',
            layer_name: entity.layer.name,
            component_path: comp_path,
            component_path_ids: comp_path_ids
          )
          items << grp_item
          return
        end

        # P3: 容器级整体量取（在递归子面之前判定）
        if (solid_item = try_emit_solid(entity, path, transform, effective_tag))
          puts "[Scanner] Group ##{entity.entityID} → try_emit_solid #{solid_item.kind} mat=#{solid_item.su_material}" if DEBUG
          items << solid_item
          return
        end

        # 纯边线群组（无线框面）：按件数统计，不下钻
        unless has_collectable_geometry?(entity)
          if has_any_edge?(entity)
            if DEBUG
              name = entity.name || '(未命名)'
              puts "[Scanner] Group ##{entity.entityID} \"#{name}\" 无线框面 → 按件数统计"
            end
            items << emit_edge_only_item(entity, path, effective_tag)
          end
          return
        end

        if DEBUG
          name = entity.name || '(未命名)'
          layer = entity.layer&.name || '?'
          mat = (entity.respond_to?(:material) && entity.material) ? entity.material.name : '(无)'
          puts "[Scanner] Group ##{entity.entityID} \"#{name}\" layer=\"#{layer}\" mat=\"#{mat}\" → 下钻子面"
        end

        new_path = path + [entity]
        new_transform = transform * entity.transformation
        # 每个群组也使用独立 face_set，避免未知情况下面 entityID 跨群组冲突
        grp_face_set = Set.new
        child_layer = container_effective_layer(entity, effective_layer)
        child_tag = container_effective_tag(entity, effective_tag)
        child_method = container_effective_method(entity, effective_method) || component_mapping_method(entity, effective_method)
        if DEBUG
          puts "[Scanner]   effective_layer=#{effective_layer.inspect} → child_layer=#{child_layer.inspect}"
          child_count = 0
        end
        entity.entities.each do |child|
          child_count += 1 if DEBUG && child.is_a?(Sketchup::Face)
          collect_faces(child, new_path, new_transform, grp_face_set, items, openings, opening_face_ids, child_layer, child_tag, child_method)
        end
        puts "[Scanner]   Group ##{entity.entityID} 子面数=#{child_count}" if DEBUG

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

    # 读取 entity 的算量标签字典（P2 新增）。
    # 返回 Hash { method:, material: } 或 nil。
    # 这是 Policy 优先级第 1 档「每实例覆盖」的数据来源。
    def read_takeoff_tags(entity)
      return nil unless entity.respond_to?(:attribute_dictionary)
      dict = entity.attribute_dictionary('su_takeoff') rescue nil
      return nil unless dict
      out = {}
      out[:method]   = dict['method']   if dict['method']
      out[:material] = dict['material'] if dict['material']
      out[:tag]      = dict['tag']      if dict['tag']
      out.empty? ? nil : out
    end

    # P3: 容器级整体量取。当 ComponentInstance / Group 的标签或图层规则
    # 命中 :length / :volume 时，产出一条 :solid / :linear_solid ScanItem，
    # 不再下钻子面 —— 这是踢脚线 6 面同材质场景的根本解。
    #
    # 返回 ScanItem 或 nil（nil 表示走原有递归子面流程）。
    def try_emit_solid(entity, path, transform, effective_tag = nil)
      return nil unless @policy
      tags = read_takeoff_tags(entity)
      attr_method = tags && tags[:method]
      layer = entity.layer && entity.layer.name
      method = @policy.resolve_container(layer_name: layer, attr_method: attr_method)
      if DEBUG
        eid = entity.entityID
        puts "[Scanner] try_emit_solid ##{eid} layer=\"#{layer}\" attr_method=#{attr_method.inspect} → #{method.inspect}"
      end
      return nil unless method
      emit_solid_by_method(entity, path, transform, method, tags, effective_tag)
    end

    # 按指定 method 产出一条容器级 ScanItem（count/length/volume）。
    # 与 try_emit_solid 共用同一套构造逻辑，拆出来供复合标签复用。
    def emit_solid_by_method(entity, path, transform, method, tags, effective_tag = nil)
      comp_path = path.map { |c| c.respond_to?(:name) ? c.name : c.to_s }
      comp_path_ids = path.map { |c| c.respond_to?(:entityID) ? c.entityID : 0 } + [entity.entityID]

      bb = entity.bounds
      scale = [transform.xscale.abs, transform.yscale.abs, transform.zscale.abs].max
      dims_in = [bb.width * scale, bb.height * scale, bb.depth * scale].sort
      w = (dims_in[0] || 0) * 0.0254
      h = (dims_in[1] || 0) * 0.0254
      d = (dims_in[2] || 0) * 0.0254

      mat_name =
        (tags && tags[:material]) ||
        (entity.respond_to?(:material) && entity.material&.name) ||
        first_child_face_material(entity) ||
        container_definition_name(entity)

      bb_center_world = bb.center.transform(transform)
      z_center_m = bb_center_world.z * 0.0254
      layer = entity.layer && entity.layer.name

      item_tag = (tags && tags[:tag]) || effective_tag

      case method
      when :length
        length_m = compute_linear_length(entity, scale) || d
        item = ScanItem.linear_solid(
          face_id: entity.entityID,
          su_material: mat_name,
          length: length_m.round(4),
          width: w.round(4),
          height: h.round(4),
          depth: h.round(4),
          layer_name: layer,
          component_path: comp_path,
          component_path_ids: comp_path_ids,
          z_center: z_center_m.round(4),
          tags: tags,
          tag: item_tag
        )
        puts "[Scanner] emit_solid_by_method :length → qty_length=#{item.qty_length}m bbox w=#{w.round(4)} h=#{h.round(4)} d=#{d.round(4)} mat=#{mat_name}" if DEBUG
        item
      when :volume
        vol_in3 = entity.respond_to?(:volume) ? entity.volume : 0
        vol_m3 = if vol_in3.is_a?(Numeric) && vol_in3 > 0
                   vol_in3 * 1.6387e-5 * (scale**3)
                 else
                   w * h * d
                 end
        ScanItem.solid(
          face_id: entity.entityID,
          su_material: mat_name,
          volume: vol_m3.round(4),
          width: w.round(4),
          height: h.round(4),
          depth: d.round(4),
          layer_name: layer,
          component_path: comp_path,
          component_path_ids: comp_path_ids,
          z_center: z_center_m.round(4),
          tags: tags,
          tag: item_tag
        )
      when :count
        ScanItem.count_solid(
          face_id: entity.entityID,
          su_material: mat_name,
          layer_name: layer,
          component_path: comp_path,
          component_path_ids: comp_path_ids,
          tags: tags,
          tag: item_tag
        )
      end
    end

    # 判断容器是否有图层规则。如果有，返回容器图层名以传播给子面；
    # 否则沿上级 effective_layer 继续传递。
    def container_effective_layer(entity, parent_effective)
      return parent_effective unless @policy
      layer = entity.layer&.name
      return parent_effective unless layer
      @policy.layer_has_rule?(layer) ? layer : parent_effective
    end

    # 判断容器是否有显式标记。如果有，返回标记名以传播给子面；
    # 否则沿上级 effective_tag 继续传递。
    def container_effective_tag(entity, parent_effective_tag)
      return parent_effective_tag unless @policy
      dict = entity.attribute_dictionary('su_takeoff') rescue nil
      tag_name = dict ? dict['tag'] : nil
      return parent_effective_tag unless tag_name
      @policy.tag_has_def?(tag_name) ? tag_name : parent_effective_tag
    end

    # 容器有算量标签时，读取其 method 并传播给子面（P1 覆盖）。
    # 对 :area 特别重要：resolve_container 对 area 返回 nil（需下钻面），
    # 但标签的 method 必须让子面强制走对应计量方式。
    def container_effective_method(entity, parent_method)
      return parent_method if parent_method
      tags = read_takeoff_tags(entity)
      return nil unless tags && tags[:method]
      m = tags[:method].to_sym
      m if TakeoffPolicy::METHODS.include?(m)
    end

    # 容器在组件映射中设了 expand 时，取其 unit 对应的 method 传播给子面。
    def component_mapping_method(entity, parent_method)
      return parent_method if parent_method
      return nil unless @policy
      def_name = entity.respond_to?(:definition) ? entity.definition.name : entity.name
      return nil if def_name.nil? || def_name.empty?
      cm = @component_mapping.get(def_name)
      return nil unless cm && cm.counting_method == 'expand' && cm.unit
      @policy.method_for_unit(cm.unit)
    end

    # 计算线性构件的总长度（米）
    # 1. 优先 baseline（用户手动指定的基准边）
    # 2. Solid → 体积 / 截面高度 / 截面厚度
    # 3. 非 Solid → 边线法：排除截面边后，长边总和 ÷ 4
    def compute_linear_length(entity, scale)
      def_name = container_definition_name(entity)
      puts "[linear_length] ====== 实体: \"#{def_name}\" entityID=#{entity.entityID} ======" if DEBUG

      # 边缘来自 definition（ComponentInstance）或 entities（Group），均在局部空间。
      # entity.transformation 将局部映射到父空间，其 scale 分量需乘入总缩放因子。
      entity_scale = if entity.respond_to?(:transformation)
        t = entity.transformation
        [t.xscale.abs, t.yscale.abs, t.zscale.abs].max
      else
        1.0
      end
      edge_scale = scale * entity_scale
      if DEBUG
        entity_type = entity.is_a?(Sketchup::ComponentInstance) ? 'ComponentInstance' : (entity.is_a?(Sketchup::Group) ? 'Group' : entity.class.to_s)
        t = entity.respond_to?(:transformation) ? entity.transformation : nil
        puts "[linear_length] entity_type=#{entity_type} parent_scale=#{scale} entity_scale=#{entity_scale} edge_scale=#{edge_scale}"
        puts "[linear_length] entity.transformation=#{t ? t.to_a.inspect : 'nil'}"
      end

      ents =
        if entity.respond_to?(:definition)
          entity.definition.entities
        elsif entity.respond_to?(:entities)
          entity.entities
        end
      if DEBUG && ents
        counts = Hash.new(0)
        ents.each { |e| counts[e.class.to_s] += 1 }
        puts "[linear_length] definition entities: #{counts.inspect}"
      end
      return nil unless ents

      # ---- 1. Baseline ----
      dict = entity.attribute_dictionary('su_takeoff') rescue nil
      baseline_id = dict ? dict['baseline_id'] : nil
      if baseline_id
        baseline_edge = find_edge_by_id(ents, baseline_id.to_i)
        if baseline_edge
          len = baseline_edge.length.to_f * @model_unit_to_m * edge_scale
          puts "[linear_length] baseline edge ##{baseline_id} = #{len.round(4)}m" if DEBUG
          return len
        end
      end

      # 收集所有边：方向、长度、中点
      edges = []
      ents.each do |e|
        next unless e.is_a?(Sketchup::Edge)
        len_raw = e.length * edge_scale
        next if len_raw <= 0
        dir = e.line[1].normalize! rescue next
        if defined?(Length) && len_raw.is_a?(Length)
          len_m = len_raw.to_m
        else
          len_m = len_raw.to_f * @model_unit_to_m
        end
        dkey = [dir.x.round(3).abs, dir.y.round(3).abs, dir.z.round(3).abs]
        puts "[linear_length]   边 ##{e.entityID}: 方向=#{dkey.inspect} 长=#{len_m.round(4)}m len_raw=#{len_raw}" if DEBUG
        edges << { dkey: dkey, len: len_m, edge: e, len_raw: len_raw }
      end
      return nil if edges.empty?

      # bbox 维度对比
      bb = entity.bounds
      bb_dims = [bb.width, bb.height, bb.depth].sort
      puts "[linear_length] bbox (in): #{bb_dims.map { |v| v.round(2) }.join(' x ')}, scale=#{scale}" if DEBUG

      # 校准：用 bbox 最长边判断 Float 是否需从英寸换算。
      # bbox 永远英寸。当 e.length 返回原始 Float（非 Length 对象）时，
      # 值可能是英寸（定义来自英寸模型），用 bbox/edge 比值检测并校准。
      is_len_obj = defined?(Length) && edges.first && edges.first[:len_raw].is_a?(Length)
      if !is_len_obj && !edges.empty?
        bb = entity.bounds
        bb_max_m = [bb.width, bb.height, bb.depth].max * 0.0254  # bbox 最长边(m)
        edge_max = edges.map { |e| e[:len] }.max
        if edge_max > 0 && bb_max_m / edge_max > 10
          puts "[linear_length] 校准: 边值(模型单位)=#{edge_max.round(4)}m, bbox=#{bb_max_m.round(4)}m → 改英寸换算" if DEBUG
          edges.each { |e| e[:len] = e[:len_raw].to_f * 0.0254 }
        end
      end
      puts "[linear_length] 总边数=#{edges.size} model_unit=#{@model.options['UnitsOptions']['LengthUnit']} factor=#{@model_unit_to_m}" if DEBUG

      # 非方条形检测：圆柱/圆角等几何有大量斜向弧边组（>5），体积法与÷4法均不适用。
      # 用 5× gap 判定长方向（与原边线法一致），排除截面方向的弧边组。
      dir_groups = edges.group_by { |e| e[:dkey] }
      meaningful_groups = dir_groups.select { |_, es| es.size >= 4 }
      if meaningful_groups.size > 5
        sorted_maxes = meaningful_groups.map { |_, es| es.map { |e| e[:len] }.max }.sort.reverse
        result = sorted_maxes.first || 0
        sorted_maxes.each_cons(2) do |prev, cur|
          break if prev / cur > 5
          result += cur
        end
        puts "[linear_length] 非方条形（#{meaningful_groups.size}组≥4边）→ 累加=#{result.round(4)}m" if DEBUG
        return result.round(4)
      end

      # ---- 2. Solid 体积法（需至少2个截面方向） ----
      if entity.respond_to?(:volume) && entity.volume.is_a?(Numeric) && entity.volume > 0
        groups = edges.group_by { |e| e[:dkey] }
        # 每组取 [dkey, 最长边, 边数]，按长度升序
        group_info = groups.map { |dkey, es| [dkey, es.map { |e| e[:len] }.max, es.size] }
                         .sort_by { |_, m, _| m }
        if DEBUG
          puts "[linear_length] Solid 体积法 —— 方向组详情："
          group_info.each do |dkey, max, cnt|
            flag = cnt >= 4 ? (max < 0.1 ? '✓ 截面候选' : '  长边') : '  排除(边<4)'
            puts "  #{flag} 方向#{dkey.inspect} max=#{max.round(6)}m edges=#{cnt}"
          end
        end
        meaningful = group_info.select { |_, _, cnt| cnt >= 4 }
        # 截面尺寸须 ≥ 0.001m (1mm)，排除圆柱面细分的弧边（~0.00005m）
        short_meaningful = meaningful.select { |_, m, _| m >= 0.001 && m < 0.1 }
        puts "[linear_length] 截面候选 meaningful=#{meaningful.size} short=#{short_meaningful.size}" if DEBUG
        if short_meaningful.size >= 2
          h_m = short_meaningful[0][1]
          t_m = short_meaningful[1][1]
          vol_m3 = entity.volume * 1.6387e-5 * (scale**3)
          result = vol_m3 / h_m / t_m
          puts "[linear_length] Solid 体积法: #{vol_m3.round(6)}m³ / #{h_m.round(4)}m / #{t_m.round(4)}m = #{result.round(4)}m" if DEBUG
          return result.round(4)
        else
          puts "[linear_length] Solid 体积法：截面不足（需≥2），退到边线法" if DEBUG
        end
      end

      # ---- 3. 边线法：排除截面边后累加长边 ÷ 4 ----
      # 按方向分组，每组取最大边长
      groups = edges.group_by { |e| e[:dkey] }
      group_maxes = groups.map { |dkey, es| [dkey, es.map { |e| e[:len] }.max, es] }.sort_by { |_, m, _| -m }
      puts "[linear_length] 方向组数=#{group_maxes.size} 各向最长(m)=#{group_maxes.map { |_, m| m.round(4) }.join(', ')}" if DEBUG
      long_groups = []
      last_max = nil
      group_maxes.each do |dkey, max, es|
        if last_max.nil? || (last_max / max) < 5
          long_groups << es
          last_max = max
        else
          puts "[linear_length] 截面方向#{dkey.inspect} max=#{max.round(4)}m 排除，后续全部忽略" if DEBUG
          break
        end
      end

      # 每方向取最长边累加（L/T/直线型正确；平行同向墙段应拆成不同群组）
      # 直接以各向最长累加作为长度，不除以 4（÷4 假设 4 条平行边，圆柱等几何不适用）
      result = long_groups.map { |es| es.map { |e| e[:len] }.max }.sum
      puts "[linear_length] 各向最长累加=#{result.round(4)}m" if DEBUG
      result.round(4)
    end

    def find_edge_by_id(entities, target_id)
      entities.each do |e|
        return e if e.is_a?(Sketchup::Edge) && e.entityID == target_id
        if e.is_a?(Sketchup::Group)
          found = find_edge_by_id(e.entities, target_id)
          return found if found
        elsif e.is_a?(Sketchup::ComponentInstance)
          found = find_edge_by_id(e.definition.entities, target_id)
          return found if found
        end
      end
      nil
    end

    # 取容器内第一个有材质的子面材质名 —— 当 Group 自身没赋材质时常见。
    def first_child_face_material(entity)
      ents =
        if entity.respond_to?(:definition)
          entity.definition.entities
        elsif entity.respond_to?(:entities)
          entity.entities
        end
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

    # 获取实体内部子元素的集合（Group 和 ComponentInstance 通用）。
    def definition_entities(entity)
      if entity.respond_to?(:definition)
        entity.definition.entities
      elsif entity.respond_to?(:entities)
        entity.entities
      end
    end

    # 实体是否包含可收集的几何（面/子组件/子群组）。
    def has_collectable_geometry?(entity)
      ents = definition_entities(entity)
      return false unless ents
      ents.any? { |e| e.is_a?(Sketchup::Face) || e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
    end

    # 实体是否包含边线。
    def has_any_edge?(entity)
      ents = definition_entities(entity)
      return false unless ents
      ents.any? { |e| e.is_a?(Sketchup::Edge) }
    end

    # 纯边线组件按件数统计。
    def emit_edge_only_item(entity, path, effective_tag)
      tags = read_takeoff_tags(entity)
      mat_name = (tags && tags[:material]) ||
        (entity.respond_to?(:material) && entity.material&.name) ||
        (entity.respond_to?(:definition) ? entity.definition.name : entity.name)

      comp_path = path.map { |c| c.respond_to?(:name) ? c.name : c.to_s }
      comp_path_ids = path.map { |c| c.respond_to?(:entityID) ? c.entityID : 0 } + [entity.entityID]

      ScanItem.instance(
        face_id: entity.entityID,
        su_material: mat_name,
        layer_name: entity.layer.name,
        component_path: comp_path,
        component_path_ids: comp_path_ids,
        tag: (tags && tags[:tag]) || effective_tag
      )
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
          entity_tag = ((d = e.attribute_dictionary('su_takeoff') rescue nil) && d['tag'])
          nodes << {
            name: node_name,
            entity_id: e.entityID,
            kind: 'component_instance',
            definition_name: def_name,
            depth: depth,
            hidden: is_hidden,
            children: children,
            tag: entity_tag
          }
        when Sketchup::Group
          is_hidden = e.hidden? || !e.visible? || (e.layer && !e.layer.visible?)
          children = collect_hierarchy_children(e.entities, depth + 1)
          entity_tag = ((d = e.attribute_dictionary('su_takeoff') rescue nil) && d['tag'])
          nodes << {
            name: (!e.name.nil? && !e.name.empty?) ? e.name : '(未命名群组)',
            entity_id: e.entityID,
            kind: 'group',
            definition_name: nil,
            depth: depth,
            hidden: is_hidden,
            children: children,
            tag: entity_tag
          }
        end
      end
      nodes
    end
  end
end