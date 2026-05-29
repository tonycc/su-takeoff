# src/ui/dialog.rb
module SuTakeoff
  class FaceSelectionObserver < Sketchup::SelectionObserver
    def initialize(html_dialog)
      @html_dialog = html_dialog
    end

    def onSelectionBulkChange(selection)
      return unless @html_dialog.visible?
      entity = selection.first
      return unless entity.is_a?(Sketchup::Face)

      # 获取当前编辑路径（用于区分同名定义在不同实例中的面）
      model = Sketchup.active_model
      path_ids = (model.active_path || []).map(&:entityID)

      @html_dialog.execute_script("window.highlightFaceInUI(#{entity.entityID}, #{JSON.generate(path_ids)})")
    rescue
      # 静默失败，不干扰用户操作
    end

    def onSelectionCleared(selection)
      return unless @html_dialog.visible?
      @html_dialog.execute_script("window.clearFaceHighlight()")
    rescue
    end
  end

  class Dialog
    def initialize
      @dialog = UI::HtmlDialog.new(
        dialog_title: 'SU Takeoff — 材料统计',
        preferences_key: 'su_takeoff_dialog',
        scrollable: true,
        resizable: true,
        width: 1000,
        height: 600,
        left: 200,
        top: 200,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      @dialog.set_file(File.join(__dir__, 'index.html'))
      @last_scan = nil

      @dialog.add_action_callback('scan_all') { |_ctx| do_scan(selection_only: false) }
      @dialog.add_action_callback('scan_selected') { |_ctx| do_scan(selection_only: true) }

      @dialog.add_action_callback('set_ignored') { |_ctx, json| set_ignored(json) }
      @dialog.add_action_callback('get_mappings') { |_ctx| send_mappings }
      @dialog.add_action_callback('save_mapping') { |_ctx, json| save_mapping(json) }
      @dialog.add_action_callback('delete_mapping') { |_ctx, su_name| delete_mapping(su_name) }
      @dialog.add_action_callback('import_csv') { |_ctx| import_csv_dialog }
      @dialog.add_action_callback('export_csv') { |_ctx| export_csv_dialog }
      @dialog.add_action_callback('get_processes') { |_ctx| send_processes }

      @dialog.add_action_callback('locate_material') { |_ctx, su_name| locate_material(su_name) }
      @dialog.add_action_callback('locate_face') { |_ctx, json| locate_face(json) }
      @dialog.add_action_callback('locate_entity') { |_ctx, json| locate_entity(json) }
      @dialog.add_action_callback('save_process') { |_ctx, json| save_process(json) }
      @dialog.add_action_callback('delete_process') { |_ctx, json| delete_process(json) }
      @dialog.add_action_callback('ignore_material') { |_ctx, name| ignore_material(name) }
      @dialog.add_action_callback('unignore') { |_ctx, name| unignore(name) }
      @dialog.add_action_callback('clear_ignored') { |_ctx| clear_ignored }
      @dialog.add_action_callback('save_config') { |_ctx, json| save_config(json) }

      @dialog.add_action_callback('get_component_mappings') { |_ctx| send_component_mappings }
      @dialog.add_action_callback('get_tag_mappings') { |_ctx| send_tag_mappings }
      @dialog.add_action_callback('save_tag_mapping') { |_ctx, json| save_tag_mapping(json) }
      @dialog.add_action_callback('save_component_mapping') { |_ctx, json| save_component_mapping(json) }
      @dialog.add_action_callback('delete_component_mapping') { |_ctx, def_name| delete_component_mapping(def_name) }

      # P2: 红行确认 —— 把用户选择的计量方式写入对应 entity 的 AttributeDictionary
      @dialog.add_action_callback('set_takeoff_method_batch') { |_ctx, json| set_takeoff_method_batch(json) }
      # 标记系统 —— 为群组/组件分配/清除标记
      @dialog.add_action_callback('set_entity_tag') { |_ctx, json| set_entity_tag(json) }
    end

    def show
      @dialog.show
      model = Sketchup.active_model
      @selection_observer = FaceSelectionObserver.new(@dialog)
      model.selection.add_observer(@selection_observer)
    end

    private

    def do_scan(selection_only:)
      clear_face_highlight  # 尽力清除，失败不阻塞
      begin
        scanner = Scanner.new
        result = scanner.scan(selection_only: selection_only)

        all_items = result[:items]

        @last_scan = {
          items: all_items,
          openings: result[:openings],
          hierarchy: result[:hierarchy],
          colors: scanner.material_colors
        }

        send_workbench_state
      rescue => e
        msg = JSON.generate({ error: e.message, backtrace: e.backtrace.first(5) })
        @dialog.execute_script("window.renderWorkbenchError(#{msg})")
      end
    end

    # Unified state push — called after scan and after any mapping/ignored change.
    # Computes usages for all mapped materials; unmapped are returned for editing UI.
    def send_workbench_state
      return unless @last_scan
      begin
      mapping = PluginState.instance.mapping
      ignored = PluginState.instance.ignored
      processes = PluginState.instance.processes
      all_items = @last_scan[:items]
      face_items = all_items.reject { |it| it.kind == :instance }
      instance_items = all_items.select { |it| it.kind == :instance }

      used_names = face_items.map(&:su_material).compact.uniq
      unresolved = used_names.reject { |n| mapping.get(n) || ignored.include?(n) }
      mapped_names = used_names.select { |n| mapping.get(n) }
      ignored_names = ignored & used_names

      # Recompute usages for all mapped materials. Unmapped materials are
      # filtered by Calculator (no record in mapping → skipped).
      policy = PluginState.instance.takeoff_policy
      calc = Calculator.new(mapping, processes, PluginState.instance.component_mapping, policy: policy)
      usages = calc.compute(all_items, @last_scan[:openings], {})
      info = build_material_info(used_names, all_items, @last_scan[:colors])

      # 几何用量（不含损耗率），直接从 items 按 (entity_id, su_material, unit) 聚合
      # 先跑 compute_geometry_only 获取去重后的 items 列表
      geo_usages = calc.compute_geometry_only(all_items, @last_scan[:openings])
      deduped_items = geo_usages.flat_map(&:items)

      # 构建洞口扣减 map
      opening_area_by_face = {}
      @last_scan[:openings].each do |op|
        op.host_face_ids.each do |fid|
          opening_area_by_face[fid] ||= 0.0
          opening_area_by_face[fid] += op.area
        end
      end

      # 按 entity_id 分组，再按 su_material 子分组（同材质不同计量方式合并）
      geo_agg = {}
      deduped_items.each do |it|
        next if it.su_material.nil?
        # 取最内层容器的 entityID（嵌套群组时面归属到直接父容器）
        eid = it.component_path_ids.last || 0
        if it.kind == :instance
          cm_rec = PluginState.instance.component_mapping.get(it.su_material)
          unit = cm_rec ? cm_rec.unit : '个'
        else
          # P2: 走 policy 决议 unit，与 Calculator 保持一致
          r = policy.resolve(it)
          method = r.method
          map_rec = PluginState.instance.mapping.get(it.su_material)
          unit =
            case method
            when :length then 'm'
            when :volume then 'm³'
            when :count  then (map_rec&.unit || '个')
            else (map_rec&.unit || 'm²')
            end
          # 把决议结果暂存到 item，供下面按面渲染
          it.resolved_method = method
          it.source = r.source
        end
        key = [eid, it.su_material]
        geo_agg[key] ||= []
        geo_agg[key] << it
      end

      puts "[Dialog] geo_agg 分组: #{geo_agg.size} 个 (eid, su_mat) 键" if Scanner::DEBUG
      geo_agg.each do |(eid, su_mat), mat_items|
        kinds = mat_items.map(&:kind).uniq.join(',')
        puts "  eid=#{eid} su_mat=\"#{su_mat}\" items=#{mat_items.size} kinds=#{kinds}" if Scanner::DEBUG
      end

      geometry_usages_list = geo_agg.map do |(eid, su_mat), mat_items|
        face_items = mat_items.reject { |i| i.kind == :instance }
        is_instance = mat_items.any? { |i| i.kind == :instance } && face_items.empty?

        part_counts = Hash.new(0.0)
        face_items.each do |i|
          part_counts[Calculator.face_orientation(i.normal)] += i.qty if i.kind == :face
        end

        # 按 resolved_method 分别累加各量纲（同材质合并后不再由 unit 主导）
        qty_area = 0.0
        qty_length = 0.0
        qty_volume = 0.0
        qty_count = 0

        if is_instance
          qty_count = mat_items.sum { |i| i.qty.to_f }
        else
          face_items.each do |i|
            case i.resolved_method
            when :length
              qty_length += (i.qty_length || i.height || 0).to_f
            when :volume
              qty_volume += (i.qty_volume || 0).to_f
            when :count
              # face 每面算 1 件；instance/linear_solid 用自带的 qty_count/qty
              qty_count += if i.kind == :face
                1.0
              else
                (i.qty_count || i.qty || 0).to_f
              end
            else
              deduction = opening_area_by_face[i.face_id] || 0.0
              qty_area += [i.qty - deduction, 0.0].max
            end
          end
        end

        primary_qty, primary_unit =
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

        # P2: row-level confidence —— 有任何启发式判定的面就标 heuristic
        any_heuristic = face_items.any? { |i| i.source == :heuristic }
        confidence = any_heuristic ? 'heuristic' : 'explicit'

        faces_detail = face_items.map { |i|
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
            source: i.source&.to_s
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
          face_count: face_items.size,
          by_part: part_counts.transform_values { |v| v.round(2) },
          is_instance: is_instance,
          faces: faces_detail,
          confidence: confidence
        }
      end

      puts "[Dialog] geometry_usages_list: #{geometry_usages_list.size} 条" if Scanner::DEBUG
      geometry_usages_list.each do |u|
        puts "  eid=#{u[:entity_id]} su_mat=#{u[:su_material]} unit=#{u[:unit]} qty=#{u[:qty]} qty_area=#{u[:qty_area]} qty_length=#{u[:qty_length]} faces=#{u[:face_count]}" if Scanner::DEBUG
      end

      data = {
        overview: {
          total_faces: face_items.size,
          total_area: face_items.sum(&:qty).round(2),
          instance_count: instance_items.size,
          instance_total: instance_items.sum(&:qty).round(0),
          total_openings: @last_scan[:openings].size,
          total_opening_area: @last_scan[:openings].sum(&:area).round(2),
          material_count: used_names.size,
          mapped: mapped_names.size,
          ignored_count: ignored_names.size,
          unresolved_count: unresolved.size
        },
        items: all_items.map { |it|
          h = it.to_h
          h[:normal] = it.normal
          h[:component_path] = it.component_path
          h[:component_path_ids] = it.component_path_ids
          h[:part] = Calculator.face_orientation(it.normal)
          h
        },
        openings: @last_scan[:openings].map(&:to_h),
        ignored: ignored_names,
        unresolved: unresolved,
        materials_info: info,
        categories: processes.all_categories,
        length_units: PluginState.instance.config['length_units'] || [],
        usages: usages.map(&:to_h),
        hierarchy: @last_scan[:hierarchy],
        geometry_usages: geometry_usages_list,
        tag_defs: PluginState.instance.config['tag_defs'] || {},
        by_material: {}
      }
      @dialog.execute_script("window.renderWorkbench(#{JSON.generate(data)})")
      send_mappings
      send_component_mappings
      rescue => e
        msg = JSON.generate({ error: e.message, backtrace: e.backtrace.first(5) })
        @dialog.execute_script("window.renderWorkbenchError(#{msg})")
      end
    end

    # Build per-material context (faces / area / part breakdown / spaces / color / suggested unit)
    def build_material_info(names, items, colors)
      mapping = PluginState.instance.mapping
      face_items = items.reject { |it| it.kind == :instance }
      by_name = Hash.new { |h, k| h[k] = [] }
      face_items.each { |it| by_name[it.su_material] << it if it.su_material }

      names.map do |name|
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
        record = mapping.get(name)
        {
          su_name: name,
          face_count: group.size,
          total_area: group.sum(&:qty).round(2),
          total_length: total_length.round(2),
          parts: parts.transform_values { |a| a.round(2) },
          spaces: spaces.sort_by { |_, a| -a }.first(3).map { |s, a| { name: s, area: a.round(2) } },
          color: colors[name],
          suggested_unit: suggested_unit,
          mapped_unit: record&.unit,
          material_name: record&.material_name,
          category: record&.category,
          spec: record&.spec,
          waste_rate: record&.default_waste_rate
        }
      end
    end

    def set_ignored(json)
      names = JSON.parse(json)
      PluginState.instance.set_ignored!(names)
      send_workbench_state if @last_scan
    end

    def locate_material(su_name)
      model = Sketchup.active_model
      faces = []
      collect_faces_with_material(model.entities, su_name, faces)
      if faces.empty?
        UI.messagebox("未找到材质 \"#{su_name}\" 的面")
        return
      end
      model.selection.clear
      model.selection.add(faces)
      model.active_view.zoom(faces)
    end

    def collect_faces_with_material(entities, su_name, result)
      entities.each do |e|
        case e
        when Sketchup::Face
          result << e if (e.material&.name == su_name) || (e.back_material&.name == su_name)
        when Sketchup::ComponentInstance
          collect_faces_with_material(e.definition.entities, su_name, result)
        when Sketchup::Group
          collect_faces_with_material(e.entities, su_name, result)
        end
      end
    end

    def locate_face(json)
      data = JSON.parse(json)
      face_id = data['face_id'].to_i
      path_ids = data['path_ids'] || []

      model = Sketchup.active_model

      # 按 path_ids 导航到正确的组件实例
      if path_ids.any?
        ancestors = path_ids.map { |eid| model.find_entity_by_id(eid) }.compact
        model.active_path = ancestors if ancestors.any?
      end

      # 从路径最内层容器开始搜索，而非从模型根
      search_root = if path_ids.any?
        inner = model.find_entity_by_id(path_ids.last)
        if inner&.respond_to?(:definition)
          inner.definition.entities
        elsif inner&.respond_to?(:entities)
          inner.entities
        end
      end
      search_root ||= model.entities

      face = find_face(search_root, face_id)
      unless face
        UI.messagebox("未找到面 ##{face_id}")
        return
      end

      # Restore previous highlight
      restore_highlight_face

      @last_face = face
      @last_front_mat = face.material
      @last_back_mat = face.back_material

      # 持久化原始材质名，即使插件重载也能恢复
      save_highlight_origin(face)

      highlight = model.materials['Takeoff 定位'] || model.materials.add('Takeoff 定位')
      highlight.color = Sketchup::Color.new(255, 180, 0)
      face.material = highlight
      face.back_material = highlight

      # 先推送 UI 高亮（在模型操作之前，确保不受模型异常影响）
      @dialog.execute_script("window.highlightFaceInUI(#{face_id}, #{JSON.generate(path_ids)})")

      model.rendering_options['XRayMode'] = true rescue nil
      model.selection.clear
      model.selection.add(face)
    end

    def save_highlight_origin(face)
      dict = face.attribute_dictionary('su_takeoff_highlight', true)
      dict['front'] = face.material&.name
      dict['back'] = face.back_material&.name
    end

    def restore_highlight_face
      if @last_face && @last_face.valid?
        @last_face.material = @last_front_mat
        @last_face.back_material = @last_back_mat
      end
      @last_face = nil
      @last_front_mat = nil
      @last_back_mat = nil
    end

    def clear_face_highlight
      restore_highlight_face
      # 兜底：遍历模型，根据持久化属性恢复所有高亮面
      model = Sketchup.active_model
      restore_all_highlight_faces(model.entities, model)
    rescue
      @last_face = nil
      @last_front_mat = nil
      @last_back_mat = nil
    end

    def restore_all_highlight_faces(entities, model)
      entities.each do |e|
        if e.is_a?(Sketchup::Face) && e.material&.name == 'Takeoff 定位'
          dict = e.attribute_dictionary('su_takeoff_highlight')
          e.material = model.materials[dict['front']] if dict && dict['front']
          e.back_material = model.materials[dict['back']] if dict && dict['back']
          e.delete_attribute('su_takeoff_highlight', 'front') rescue nil
          e.delete_attribute('su_takeoff_highlight', 'back') rescue nil
          e.attribute_dictionary_delete('su_takeoff_highlight') rescue nil
        elsif e.respond_to?(:entities)
          restore_all_highlight_faces(e.entities, model)
        elsif e.respond_to?(:definition)
          restore_all_highlight_faces(e.definition.entities, model)
        end
      end
    end

    def locate_entity(json)
      eid = JSON.parse(json)
      model = Sketchup.active_model
      entity = model.find_entity_by_id(eid)
      return unless entity
      model.selection.clear
      model.selection.add(entity)
      # 逐层展开父级容器，确保 zoom 不会跳转到错误的坐标空间
      parents = []
      p = entity.parent
      while p && !p.is_a?(Sketchup::Model)
        parents.unshift(p) if p.is_a?(Sketchup::Group) || p.is_a?(Sketchup::ComponentInstance)
        p = p.parent
      end
      begin
        model.active_path = parents unless parents.empty?
      rescue
        # 某些容器可能无法作为编辑路径打开，忽略继续
      end
      model.active_view.zoom(entity)
    rescue
      model.active_view.zoom_extents
    end

    def find_face(entities, target_id)
      entities.each do |e|
        return e if e.entityID == target_id
        next unless e.respond_to?(:definition) || e.respond_to?(:entities)

        children = e.respond_to?(:definition) ? e.definition.entities : e.entities
        result = find_face(children, target_id)
        return result if result
      end
      nil
    end

    def send_mappings
      mappings = PluginState.instance.mapping.all.map(&:to_h)
      # 每次从文件读取最新配置，避免因插件加载时序导致使用旧默认值
      cfg = if File.exist?(PluginState.config_path)
              JSON.parse(File.read(PluginState.config_path))
            else
              {}
            end
      config = {
        category_units: cfg['material_category_units'] || cfg['category_units'] || [],
        config_units: cfg['units'] || []
      }
      @dialog.execute_script("window.renderMappings(#{JSON.generate(mappings)}, #{JSON.generate(config)})")
    end

    def save_mapping(json)
      data = JSON.parse(json)
      m = PluginState.instance.mapping
      m.add(data['su_name'], data['material_name'], data['category'],
            data['unit'], data['spec'], data['waste_rate'].to_f)
      m.save_json(PluginState.mapping_path)
      send_mappings
      send_workbench_state if @last_scan
    end

    def delete_mapping(su_name)
      m = PluginState.instance.mapping
      m.delete(su_name)
      m.save_json(PluginState.mapping_path)
      send_mappings
      send_workbench_state if @last_scan
    end

    def send_tag_mappings
      state = PluginState.instance
      layer_rules = state.config['layer_rules'] || {}

      model = Sketchup.active_model
      model_layers = Set.new
      collect_model_layers(model.entities, model_layers)

      all_layers = (model_layers.to_a + layer_rules.keys).uniq.sort

      rows = all_layers.map do |layer|
        {
          name: layer,
          kind: 'layer',
          method: layer_rules[layer],
          in_model: model_layers.include?(layer)
        }
      end

      @dialog.execute_script("window.renderTagMappings(#{JSON.generate(rows)})")
    end

    def collect_model_layers(entities, layers)
      entities.each do |e|
        if e.respond_to?(:layer) && e.layer
          name = e.layer.name
          layers.add(name) if name && !name.empty? && name != 'Layer0'
        end
        if e.is_a?(Sketchup::Group)
          collect_model_layers(e.entities, layers)
        elsif e.is_a?(Sketchup::ComponentInstance)
          collect_model_layers(e.definition.entities, layers)
        end
      end
    end

    def save_tag_mapping(json)
      data = JSON.parse(json)
      name = data['name']
      method = data['method']
      return unless name && !name.empty?

      state = PluginState.instance
      state.config['layer_rules'] ||= {}
      if method.nil? || method.empty?
        state.config['layer_rules'].delete(name)
      else
        state.config['layer_rules'][name] = method
      end
      path = PluginState.config_path
      File.write(path, JSON.pretty_generate(state.config))
      send_tag_mappings
      send_workbench_state if @last_scan
    end

    def send_component_mappings
      mappings = PluginState.instance.component_mapping.all.map(&:to_h)
      model = Sketchup.active_model
      # 组件定义名 (kind: 'component')
      comp_names = model.definitions.reject(&:group?).map(&:name).reject { |n| n.nil? || n.empty? }.uniq
      # 群组名 (kind: 'group')
      group_set = Set.new
      collect_group_names(model.entities, group_set)
      group_names = group_set.to_a
      # 合并：带 kind 信息
      entries = comp_names.map { |n| { name: n, kind: 'component' } } +
                group_names.map { |n| { name: n, kind: 'group' } }
      entries.sort_by! { |e| e[:name] }
      # Read config
      cfg = if File.exist?(PluginState.config_path)
              JSON.parse(File.read(PluginState.config_path))
            else
              {}
            end
      config = {
        category_units: cfg['component_category_units'] || [],
        config_units: cfg['units'] || []
      }
      @dialog.execute_script("window.renderComponentMappings(#{JSON.generate(mappings)}, #{JSON.generate(entries)}, #{JSON.generate(config)})")
    end

    def collect_group_names(entities, result)
      entities.each do |e|
        if e.is_a?(Sketchup::Group)
          name = e.name
          result.add(name) if name && !name.empty?
          collect_group_names(e.entities, result)
        elsif e.is_a?(Sketchup::ComponentInstance)
          collect_group_names(e.definition.entities, result)
        end
      end
    end

    def save_component_mapping(json)
      data = JSON.parse(json)
      cm = PluginState.instance.component_mapping
      cm.add(data['definition_name'], data['material_name'], data['category'],
             data['unit'] || '个', data['spec'] || '', data['waste_rate'].to_f,
             data['counting_method'] || 'expand')
      cm.save_json(PluginState.component_mapping_path)
      send_component_mappings
      send_workbench_state if @last_scan
    end

    def delete_component_mapping(def_name)
      cm = PluginState.instance.component_mapping
      cm.delete(def_name)
      cm.save_json(PluginState.component_mapping_path)
      send_component_mappings
      send_workbench_state if @last_scan
    end

    def import_csv_dialog
      path = UI.openpanel('选择映射CSV文件', '', 'CSV Files|*.csv||')
      return unless path
      PluginState.instance.mapping.import_csv(path)
      PluginState.instance.mapping.save_json(PluginState.mapping_path)
      send_mappings
    end

    def export_csv_dialog
      path = UI.savepanel('导出映射CSV', '', 'material_mapping.csv')
      return unless path
      PluginState.instance.mapping.export_csv(path)
    end

    def send_processes
      state = PluginState.instance
      data = {
        processes: state.processes.all_categories.map { |cat|
          {
            category: cat,
            processes: state.processes.processes_for(cat).map { |p|
              h = p.to_h
              h[:derivations] = (p.derivations || []).map(&:to_h)
              h
            }
          }
        },
        ignored: state.ignored,
        material_category_units: state.config['material_category_units'] || [],
        component_category_units: state.config['component_category_units'] || [],
        config_units: state.config['units'] || [],
        length_units: state.config['length_units'] || [],
        count_units: state.config['count_units'] || [],
        volume_units: state.config['volume_units'] || [],
        layer_rules: state.config['layer_rules'] || {},
        tag_defs: state.config['tag_defs'] || {},
        heuristics_enabled: state.config.fetch('heuristics_enabled', true),
        heuristic_thresholds: state.config['heuristic_thresholds'] || {}
      }
      @dialog.execute_script("window.renderProcesses(#{JSON.generate(data)})")
    end

    def save_config(json)
      data = JSON.parse(json)
      PluginState.instance.save_config(
        data['material_category_units'] || data['category_units'] || [],
        data['component_category_units'] || [],
        data['units'] || [],
        data['length_units'],
        data['count_units'],
        data['layer_rules'],
        data['heuristics_enabled'],
        data['volume_units'],
        data['heuristic_thresholds'],
        data['tag_defs']
      )
      send_workbench_state if @last_scan
    end
    def save_process(json)
      data = JSON.parse(json)
      p = PluginState.instance.processes
      old_cat = data['old_category'] || data['category']
      old_name = data['old_name'] || data['name']
      p.delete_process(old_cat, old_name)
      p.add_process(data['category'], data['name'], data['waste_rate'].to_f,
                    data['derivations'] || [])
      p.save_json(PluginState.processes_path)
      send_processes
    end

    def delete_process(json)
      data = JSON.parse(json)
      PluginState.instance.processes.delete_process(data['category'], data['name'])
      PluginState.instance.processes.save_json(PluginState.processes_path)
      send_processes
    end

    def ignore_material(name)
      PluginState.instance.ignore!(name)
      send_workbench_state if @last_scan
    end

    def unignore(name)
      PluginState.instance.unignore!(name)
      send_processes
    end

    def clear_ignored
      PluginState.instance.set_ignored!([])
      send_processes
    end

    # P2 新增：把红行确认结果写回 entity 的 AttributeDictionary。
    # 入参 JSON：
    #   { face_ids: [123, 456], path_ids: [[101], [101]], method: 'length' }
    # 行为：
    #   - 对每对 (face_id, path_ids) 通过 path_ids 导航到正确容器后定位 entity
    #   - 写 entity.set_attribute('su_takeoff', 'method', method)
    #   - method == 'clear' 时删除该字段
    #   - 完成后重跑 Calculator + 推前端，红行升级为白行（confidence: explicit, source: attr）
    def set_takeoff_method_batch(json)
      data = JSON.parse(json)
      method = data['method']
      face_ids = data['face_ids'] || []
      path_ids_list = data['path_ids_list'] || []
      return if face_ids.empty?

      model = Sketchup.active_model
      face_ids.each_with_index do |fid, i|
        path_ids = path_ids_list[i] || []
        entities = nil
        if path_ids.any?
          inner = model.find_entity_by_id(path_ids.last)
          if inner&.respond_to?(:definition)
            entities = inner.definition.entities
          elsif inner&.respond_to?(:entities)
            entities = inner.entities
          end
        end
        entities ||= model.entities
        entity = find_face(entities, fid.to_i)
        next unless entity

        if method == 'clear'
          entity.delete_attribute('su_takeoff', 'method') rescue nil
        else
          entity.set_attribute('su_takeoff', 'method', method)
        end
      end

      # 重新扫描以拾取最新的 attr dict 标签（标签在 Scanner.read_takeoff_tags 读取）
      do_scan(selection_only: false)
    rescue => e
      msg = JSON.generate({ error: e.message, backtrace: e.backtrace.first(5) })
      @dialog.execute_script("window.renderWorkbenchError(#{msg})")
    end

    def set_entity_tag(json)
      data = JSON.parse(json)
      entity_id = data['entity_id'].to_i
      tag_name = data['tag_name']  # nil / '' 表示清除

      model = Sketchup.active_model
      entity = model.find_entity_by_id(entity_id)
      return unless entity
      return unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)

      model.start_operation('设置标记', true)
      if tag_name.nil? || tag_name.empty?
        entity.delete_attribute('su_takeoff', 'tag') rescue nil
        entity.delete_attribute('su_takeoff', 'method') rescue nil
        entity.delete_attribute('su_takeoff', 'material') rescue nil
      else
        tag_defs = PluginState.instance.config['tag_defs'] || {}
        method = tag_defs[tag_name]
        entity.set_attribute('su_takeoff', 'tag', tag_name)
        entity.set_attribute('su_takeoff', 'method', method) if method
      end
      model.commit_operation

      do_scan(selection_only: false)
    rescue => e
      msg = JSON.generate({ error: e.message, backtrace: e.backtrace.first(5) })
      @dialog.execute_script("window.renderWorkbenchError(#{msg})")
    end

  end
end
