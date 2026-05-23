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
      @dialog.add_action_callback('save_component_mapping') { |_ctx, json| save_component_mapping(json) }
      @dialog.add_action_callback('delete_component_mapping') { |_ctx, def_name| delete_component_mapping(def_name) }
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
      calc = Calculator.new(mapping, processes)
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

      # 按 entity_id 分组，再按 (su_material, unit) 子分组
      geo_agg = {}
      deduped_items.each do |it|
        next if it.su_material.nil?
        eid = it.component_path_ids.last || 0
        if it.kind == :instance
          cm_rec = PluginState.instance.component_mapping.get(it.su_material)
          unit = cm_rec ? cm_rec.unit : '个'
        else
          map_rec = PluginState.instance.mapping.get(it.su_material)
          if map_rec
            raw_unit = map_rec.unit
            length_units = PluginState.instance.config['length_units'] || %w[m mm cm dm km]
            unit = length_units.include?(raw_unit) ? 'm' : raw_unit
          elsif it.width && it.width > 0 && it.height && (it.height / it.width) > 15
            unit = 'm'
          else
            unit = 'm²'
          end
        end
        key = [eid, it.su_material, unit]
        geo_agg[key] ||= []
        geo_agg[key] << it
      end

      geometry_usages_list = geo_agg.map do |(eid, su_mat, unit), mat_items|
        face_items = mat_items.reject { |i| i.kind == :instance }
        is_instance = mat_items.any? { |i| i.kind == :instance } && face_items.empty?

        part_counts = Hash.new(0.0)
        face_items.each do |i|
          part_counts[Calculator.face_orientation(i.normal)] += i.qty if i.kind == :face
        end

        qty = if is_instance
          mat_items.sum { |i| i.qty.to_f }.round(4)
        elsif unit == 'm'
          face_items.sum { |i| (i.height || 0).to_f }.round(4)
        else
          face_items.sum { |i|
            deduction = opening_area_by_face[i.face_id] || 0.0
            [i.qty - deduction, 0.0].max
          }.round(4)
        end

        faces_detail = face_items.map { |i|
          {
            face_id: i.face_id,
            path_ids: i.component_path_ids,
            width: i.width&.round(2),
            height: i.height&.round(2),
            area: i.qty.round(3),
            kind: i.kind,
            part: Calculator.face_orientation(i.normal)
          }
        }

        {
          entity_id: eid,
          su_material: su_mat,
          unit: unit,
          qty: qty,
          face_count: face_items.size,
          by_part: part_counts.transform_values { |v| v.round(2) },
          is_instance: is_instance,
          faces: faces_detail
        }
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
      @dialog.execute_script("dlog('Ruby locate_face entered')")
      begin
        data = JSON.parse(json)
        face_id = data['face_id'].to_i
        path_ids = data['path_ids'] || []
        @dialog.execute_script("dlog('Ruby parsed: face_id=#{face_id} path_ids=[#{path_ids.join(',')}]')")

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

      model.rendering_options['XRayMode'] = true
      model.selection.clear
      model.selection.add(face)

      # 直接推送 UI 高亮（不依赖 SelectionObserver 回传）
      @dialog.execute_script("dlog('Ruby calling highlightFaceInUI')")
      @dialog.execute_script("window.highlightFaceInUI(#{face_id}, #{JSON.generate(path_ids)})")
      @dialog.execute_script("dlog('Ruby done')")
      rescue => e
        @dialog.execute_script("dlog('Ruby ERROR: #{e.message.gsub("'", "\\\\'")}')")
      end
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

    def find_face_with_ancestors(entities, target_id, ancestors)
      entities.each do |e|
        return [e, ancestors] if e.entityID == target_id
        next unless e.respond_to?(:definition) || e.respond_to?(:entities)

        children = e.respond_to?(:definition) ? e.definition.entities : e.entities
        result = find_face_with_ancestors(children, target_id, ancestors + [e])
        return result if result
      end
      nil
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

    def send_component_mappings
      mappings = PluginState.instance.component_mapping.all.map(&:to_h)
      # Collect all component/group definition names from the model
      model = Sketchup.active_model
      def_names = model.definitions.reject(&:group?).map(&:name).reject { |n| n.nil? || n.empty? }.uniq.sort
      # Read config for category and unit lists
      cfg = if File.exist?(PluginState.config_path)
              JSON.parse(File.read(PluginState.config_path))
            else
              {}
            end
      config = {
        category_units: cfg['component_category_units'] || [],
        config_units: cfg['units'] || []
      }
      @dialog.execute_script("window.renderComponentMappings(#{JSON.generate(mappings)}, #{JSON.generate(def_names)}, #{JSON.generate(config)})")
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
        count_units: state.config['count_units'] || []
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
        data['count_units']
      )
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

  end
end
