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
      return if face_set.include?(entity.entityID)
      face_set.add(entity.entityID)
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

      comp_path     = path.map { |c| c.respond_to?(:name) ? c.name : c.to_s }
      comp_path_ids = path.map { |c| c.respond_to?(:entityID) ? c.entityID : 0 }

      area_m2 = compute_area(entity, transform)
      if DEBUG
        puts "[Scanner] Face ##{entity.entityID} mat=\"#{mat_name}\" " \
             "layer=\"#{effective_layer || entity.layer.name}\" area=#{area_m2.round(4)}"
      end

      world_normal = entity.normal.transform(transform)
      world_normal.normalize! if world_normal.length > 0

      bb_center_world = entity.bounds.center.transform(transform)
      z_center_m = bb_center_world.z * 0.0254

      return if area_m2 < MIN_FACE_AREA_M2

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

      bb    = entity.bounds
      scale = [transform.xscale.abs, transform.yscale.abs, transform.zscale.abs].max
      dims  = [bb.width * scale, bb.height * scale, bb.depth * scale].sort
      w = (dims[-2] || 0) * 0.0254
      h = (dims[-1] || 0) * 0.0254

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
        center_y: (bb_center_world.y * 0.0254).round(4)
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

      # 复合标签：method 含 '+' 时拆开，产出多条容器级 ScanItem，不再下钻
      tags = read_takeoff_tags(entity)
      if tags && tags[:method] && tags[:method].to_s.include?('+')
        tags[:method].to_s.split('+').map(&:strip).each do |m|
          sym = m.to_sym
          next unless %i[count length volume].include?(sym)
          result = emit_solid_by_method(entity, path, transform, sym, tags, effective_tag)
          items << result if result
        end
        return
      end

      # 组件映射 aggregate → 整件统计，不下钻
      def_name  = container_definition_name(entity)
      cm_record = @component_mapping.get(def_name)
      if cm_record && cm_record.counting_method == 'aggregate' && def_name && !def_name.empty?
        comp_path     = path.map { |c| c.respond_to?(:name) ? c.name : c.to_s }
        comp_path_ids = path.map { |c| c.respond_to?(:entityID) ? c.entityID : 0 } + [entity.entityID]
        items << ScanItem.instance(
          face_id: entity.entityID,
          su_material: def_name,
          unit: cm_record.unit || '个',
          layer_name: entity.layer.name,
          component_path: comp_path,
          component_path_ids: comp_path_ids
        )
        return
      end

      # 容器级整体量取（标签/图层规则命中 length/volume/count → 不下钻）
      if (solid_item = try_emit_solid(entity, path, transform, effective_tag))
        puts "[Scanner] #{entity.class} ##{entity.entityID} → solid #{solid_item.kind} mat=#{solid_item.su_material}" if DEBUG
        items << solid_item
        return
      end

      # 纯边线容器（无面/子组件）→ 按件数统计
      unless has_collectable_geometry?(entity)
        if has_any_edge?(entity)
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
      child_method  = container_effective_method(entity, effective_method) ||
                      component_mapping_method(entity, effective_method)

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

      parent_comp_path = new_path.map { |c| c.respond_to?(:name) ? c.name : c.to_s }
      child_ents.each do |child|
        next unless child.is_a?(Sketchup::Face) && !opening_face_ids.include?(child.entityID)
        a            = compute_area(child, new_transform)
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

    # ---- 以下方法保持不变 ----

    def compute_area(face, transform)
      face.area(transform) * 0.00064516
    end

    def read_takeoff_tags(entity)
      return nil unless entity.respond_to?(:attribute_dictionary)
      dict = entity.attribute_dictionary('su_takeoff') rescue nil
      return nil unless dict
      out = {}
      out[:method]      = dict['method']      if dict['method']
      out[:material]    = dict['material']    if dict['material']
      out[:tag]         = dict['tag']         if dict['tag']
      out[:baseline_id] = dict['baseline_id'] if dict['baseline_id']
      out.empty? ? nil : out
    end

    def try_emit_solid(entity, path, transform, effective_tag = nil)
      return nil unless @policy
      tags        = read_takeoff_tags(entity)
      attr_method = tags && tags[:method]
      layer       = entity.layer && entity.layer.name
      method      = @policy.resolve_container(layer_name: layer, attr_method: attr_method)
      if DEBUG
        puts "[Scanner] try_emit_solid ##{entity.entityID} layer=\"#{layer}\" " \
             "attr_method=#{attr_method.inspect} → #{method.inspect}"
      end
      return nil unless method
      emit_solid_by_method(entity, path, transform, method, tags, effective_tag)
    end

    def emit_solid_by_method(entity, path, transform, method, tags, effective_tag = nil)
      comp_path     = path.map { |c| c.respond_to?(:name) ? c.name : c.to_s }
      comp_path_ids = path.map { |c| c.respond_to?(:entityID) ? c.entityID : 0 } + [entity.entityID]

      bb       = entity.bounds
      scale    = [transform.xscale.abs, transform.yscale.abs, transform.zscale.abs].max
      dims_in  = [bb.width * scale, bb.height * scale, bb.depth * scale].sort
      w = (dims_in[0] || 0) * 0.0254
      h = (dims_in[1] || 0) * 0.0254
      d = (dims_in[2] || 0) * 0.0254

      mat_name =
        (tags && tags[:material]) ||
        (entity.respond_to?(:material) && entity.material&.name) ||
        first_child_face_material(entity) ||
        container_definition_name(entity)

      bb_center_world = bb.center.transform(transform)
      z_center_m      = bb_center_world.z * 0.0254
      layer           = entity.layer && entity.layer.name
      item_tag        = (tags && tags[:tag]) || effective_tag

      case method
      when :length
        length_m = compute_linear_length(entity, scale) || d
        item = ScanItem.linear_solid(
          face_id: entity.entityID, su_material: mat_name,
          length: length_m.round(4), width: w.round(4), height: h.round(4), depth: h.round(4),
          layer_name: layer, component_path: comp_path, component_path_ids: comp_path_ids,
          z_center: z_center_m.round(4), tags: tags, tag: item_tag
        )
        if DEBUG
          puts "[Scanner] emit_solid :length → qty_length=#{item.qty_length}m " \
               "bbox w=#{w.round(4)} h=#{h.round(4)} d=#{d.round(4)} mat=#{mat_name}"
        end
        item
      when :volume
        vol_in3 = entity.respond_to?(:volume) ? entity.volume : 0
        vol_m3  = if vol_in3.is_a?(Numeric) && vol_in3 > 0
                    vol_in3 * 1.6387e-5 * (scale**3)
                  else
                    w * h * d
                  end
        ScanItem.solid(
          face_id: entity.entityID, su_material: mat_name,
          volume: vol_m3.round(4), width: w.round(4), height: h.round(4), depth: d.round(4),
          layer_name: layer, component_path: comp_path, component_path_ids: comp_path_ids,
          z_center: z_center_m.round(4), tags: tags, tag: item_tag
        )
      when :count
        ScanItem.count_solid(
          face_id: entity.entityID, su_material: mat_name,
          layer_name: layer, component_path: comp_path, component_path_ids: comp_path_ids,
          tags: tags, tag: item_tag
        )
      end
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

    def component_mapping_method(entity, parent_method)
      return parent_method if parent_method
      return nil unless @policy
      def_name = container_definition_name(entity)
      return nil if def_name.nil? || def_name.empty?
      cm = @component_mapping.get(def_name)
      return nil unless cm && cm.counting_method == 'expand' && cm.unit
      @policy.method_for_unit(cm.unit)
    end

    def compute_linear_length(entity, scale)
      def_name = container_definition_name(entity)
      puts "[linear_length] ====== 实体: \"#{def_name}\" entityID=#{entity.entityID} ======" if DEBUG

      entity_scale = if entity.respond_to?(:transformation)
        t = entity.transformation
        [t.xscale.abs, t.yscale.abs, t.zscale.abs].max
      else
        1.0
      end
      edge_scale = scale * entity_scale

      if DEBUG
        entity_type = entity.is_a?(Sketchup::ComponentInstance) ? 'ComponentInstance' :
                      (entity.is_a?(Sketchup::Group) ? 'Group' : entity.class.to_s)
        t = entity.respond_to?(:transformation) ? entity.transformation : nil
        puts "[linear_length] entity_type=#{entity_type} parent_scale=#{scale} " \
             "entity_scale=#{entity_scale} edge_scale=#{edge_scale}"
        puts "[linear_length] entity.transformation=#{t ? t.to_a.inspect : 'nil'}"
      end

      ents = definition_entities(entity)
      if DEBUG && ents
        counts = Hash.new(0)
        ents.each { |e| counts[e.class.to_s] += 1 }
        puts "[linear_length] definition entities: #{counts.inspect}"
      end
      return nil unless ents

      # ---- 1. Baseline ----
      tags        = read_takeoff_tags(entity)
      baseline_id = tags && tags[:baseline_id]
      if baseline_id
        baseline_edge = find_edge_by_id(ents, baseline_id.to_i)
        if baseline_edge
          len = baseline_edge.length.to_f * @model_unit_to_m * edge_scale
          puts "[linear_length] baseline edge ##{baseline_id} = #{len.round(4)}m" if DEBUG
          return len
        end
      end

      # 收集所有边：方向、长度
      edges = []
      ents.each do |e|
        next unless e.is_a?(Sketchup::Edge)
        len_raw = e.length * edge_scale
        next if len_raw <= 0
        dir = e.line[1].normalize! rescue next
        len_m = if defined?(Length) && len_raw.is_a?(Length)
                  len_raw.to_m
                else
                  len_raw.to_f * @model_unit_to_m
                end
        dkey = [dir.x.round(3).abs, dir.y.round(3).abs, dir.z.round(3).abs]
        puts "[linear_length]   边 ##{e.entityID}: 方向=#{dkey.inspect} 长=#{len_m.round(4)}m" if DEBUG
        edges << { dkey: dkey, len: len_m, len_raw: len_raw }
      end
      return nil if edges.empty?

      puts "[linear_length] bbox (in): #{[entity.bounds.width, entity.bounds.height, entity.bounds.depth].sort.map { |v| v.round(2) }.join(' x ')}, scale=#{scale}" if DEBUG

      # 校准：用 bbox 最长边判断 Float 是否需从英寸换算
      is_len_obj = defined?(Length) && edges.first && edges.first[:len_raw].is_a?(Length)
      unless is_len_obj
        bb        = entity.bounds
        bb_max_m  = [bb.width, bb.height, bb.depth].max * 0.0254
        edge_max  = edges.map { |e| e[:len] }.max
        if edge_max > 0 && bb_max_m / edge_max > 10
          puts "[linear_length] 校准: 边值=#{edge_max.round(4)}m, bbox=#{bb_max_m.round(4)}m → 改英寸换算" if DEBUG
          edges.each { |e| e[:len] = e[:len_raw].to_f * 0.0254 }
        end
      end
      puts "[linear_length] 总边数=#{edges.size} model_unit=#{@model.options['UnitsOptions']['LengthUnit']} factor=#{@model_unit_to_m}" if DEBUG

      # 非方条形检测（圆柱/圆角等）
      dir_groups      = edges.group_by { |e| e[:dkey] }
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

      # ---- 2. Solid 体积法 ----
      if entity.respond_to?(:volume) && entity.volume.is_a?(Numeric) && entity.volume > 0
        groups     = edges.group_by { |e| e[:dkey] }
        group_info = groups.map { |dkey, es| [dkey, es.map { |e| e[:len] }.max, es.size] }
                           .sort_by { |_, m, _| m }
        if DEBUG
          puts "[linear_length] Solid 体积法 —— 方向组详情："
          group_info.each do |dkey, max, cnt|
            flag = cnt >= 4 ? (max < 0.1 ? '✓ 截面候选' : '  长边') : '  排除(边<4)'
            puts "  #{flag} 方向#{dkey.inspect} max=#{max.round(6)}m edges=#{cnt}"
          end
        end
        meaningful       = group_info.select { |_, _, cnt| cnt >= 4 }
        short_meaningful = meaningful.select { |_, m, _| m >= 0.001 && m < 0.1 }
        puts "[linear_length] 截面候选 meaningful=#{meaningful.size} short=#{short_meaningful.size}" if DEBUG
        if short_meaningful.size >= 2
          h_m    = short_meaningful[0][1]
          t_m    = short_meaningful[1][1]
          vol_m3 = entity.volume * 1.6387e-5 * (scale**3)
          result = vol_m3 / h_m / t_m
          puts "[linear_length] Solid 体积法: #{vol_m3.round(6)}m³ / #{h_m.round(4)}m / #{t_m.round(4)}m = #{result.round(4)}m" if DEBUG
          return result.round(4)
        else
          puts "[linear_length] Solid 体积法：截面不足，退到边线法" if DEBUG
        end
      end

      # ---- 3. 边线法 ----
      groups      = edges.group_by { |e| e[:dkey] }
      group_maxes = groups.map { |dkey, es| [dkey, es.map { |e| e[:len] }.max, es] }.sort_by { |_, m, _| -m }
      puts "[linear_length] 方向组数=#{group_maxes.size} 各向最长(m)=#{group_maxes.map { |_, m| m.round(4) }.join(', ')}" if DEBUG
      long_groups = []
      last_max    = nil
      group_maxes.each do |dkey, max, es|
        if last_max.nil? || (last_max / max) < 5
          long_groups << es
          last_max = max
        else
          puts "[linear_length] 截面方向#{dkey.inspect} max=#{max.round(4)}m 排除" if DEBUG
          break
        end
      end
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

      comp_path     = path.map { |c| c.respond_to?(:name) ? c.name : c.to_s }
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

    def opening_name?(name)
      return false if name.nil? || name.empty?
      n = name.downcase
      n.include?('窗') || n.include?('门') ||
        n.include?('window') || n.include?('door')
    end

    def associate_openings_to_hosts(items, openings, pending_info)
      pending_info.each do |info|
        op_idx    = info[:index]
        op_normal = info[:normal]
        op_area   = info[:area]
        op_path   = info[:component_path]
        parent_path = op_path[0..-2]

        candidates = items.select do |item|
          next if item.normal.nil?
          dot = (op_normal[0] * item.normal[0] +
                 op_normal[1] * item.normal[1] +
                 op_normal[2] * item.normal[2]).abs
          dot > 0.99 &&
            item.qty > op_area &&
            (item.component_path == op_path || item.component_path == parent_path)
        end

        if candidates.any?
          best = candidates.min_by(&:qty)
          openings[op_idx].host_face_ids = [best.face_id]
        end
      end
    end

    def collect_hierarchy(entities)
      {
        name: '(模型根)',
        entity_id: 0,
        kind: 'root',
        definition_name: nil,
        depth: 0,
        hidden: false,
        children: collect_hierarchy_children(entities)
      }
    end

    def collect_hierarchy_children(entities, depth = 1)
      nodes = []
      entities.each do |e|
        case e
        when Sketchup::ComponentInstance, Sketchup::Group
          is_hidden  = e.hidden? || !e.visible? || (e.layer && !e.layer.visible?)
          def_name   = e.is_a?(Sketchup::ComponentInstance) ? (e.definition.name rescue e.name) : nil
          child_ents = definition_entities(e)
          children   = collect_hierarchy_children(child_ents, depth + 1)
          fallback   = def_name || '(未命名群组)'
          node_name  = (!e.name.nil? && !e.name.empty?) ? e.name : fallback
          entity_tag = ((t = read_takeoff_tags(e)) && t[:tag])
          nodes << {
            name: node_name,
            entity_id: e.entityID,
            kind: e.is_a?(Sketchup::ComponentInstance) ? 'component_instance' : 'group',
            definition_name: def_name,
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
