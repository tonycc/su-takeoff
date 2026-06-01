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
      data = WorkbenchPresenter.new(
        items: @last_scan[:items],
        openings: @last_scan[:openings],
        hierarchy: @last_scan[:hierarchy],
        colors: @last_scan[:colors],
        mapping: PluginState.instance.mapping,
        component_mapping: PluginState.instance.component_mapping,
        policy: PluginState.instance.takeoff_policy,
        processes: PluginState.instance.processes,
        ignored: PluginState.instance.ignored,
        tag_defs: PluginState.instance.config['tag_defs'] || {}
      ).build
      @dialog.execute_script("window.renderWorkbench(#{JSON.generate(data)})")
      send_mappings
      send_component_mappings
      rescue => e
        msg = JSON.generate({ error: e.message, backtrace: e.backtrace.first(5) })
        @dialog.execute_script("window.renderWorkbenchError(#{msg})")
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
      PluginState.instance.save_mapping_to_model_dict
      send_mappings
      send_workbench_state if @last_scan
    end

    def delete_mapping(su_name)
      m = PluginState.instance.mapping
      m.delete(su_name)
      m.save_json(PluginState.mapping_path)
      PluginState.instance.save_mapping_to_model_dict
      send_mappings
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
      PluginState.instance.save_component_mapping_to_model_dict
      send_component_mappings
      send_workbench_state if @last_scan
    end

    def delete_component_mapping(def_name)
      cm = PluginState.instance.component_mapping
      cm.delete(def_name)
      cm.save_json(PluginState.component_mapping_path)
      PluginState.instance.save_component_mapping_to_model_dict
      send_component_mappings
      send_workbench_state if @last_scan
    end

    def import_csv_dialog
      path = UI.openpanel('选择映射CSV文件', '', 'CSV Files|*.csv||')
      return unless path
      PluginState.instance.mapping.import_csv(path)
      PluginState.instance.mapping.save_json(PluginState.mapping_path)
      PluginState.instance.save_mapping_to_model_dict
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
        nil,
        nil,
        nil,
        data['heuristics_enabled'],
        nil,
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
      PluginState.instance.save_processes_to_model_dict
      send_processes
    end

    def delete_process(json)
      data = JSON.parse(json)
      PluginState.instance.processes.delete_process(data['category'], data['name'])
      PluginState.instance.processes.save_json(PluginState.processes_path)
      PluginState.instance.save_processes_to_model_dict
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
