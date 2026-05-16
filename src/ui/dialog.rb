# src/ui/dialog.rb
module SuTakeoff
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
      @dialog.add_action_callback('locate_face') { |_ctx, id| locate_face(id.to_i) }
      @dialog.add_action_callback('save_process') { |_ctx, json| save_process(json) }
      @dialog.add_action_callback('delete_process') { |_ctx, json| delete_process(json) }
      @dialog.add_action_callback('ignore_material') { |_ctx, name| ignore_material(name) }
      @dialog.add_action_callback('unignore') { |_ctx, name| unignore(name) }
      @dialog.add_action_callback('clear_ignored') { |_ctx| clear_ignored }
      @dialog.add_action_callback('save_config') { |_ctx, json| save_config(json) }
    end

    def show
      @dialog.show
    end

    private

    # Phase 1 — scan only. Reports unmapped materials; does NOT compute stats yet.
    def do_scan(selection_only:)
      scanner = Scanner.new
      result = scanner.scan(selection_only: selection_only)

      all_items = result[:items]

      @last_scan = {
        items: all_items,
        openings: result[:openings],
        colors: scanner.material_colors
      }

      send_workbench_state
    end

    # Unified state push — called after scan and after any mapping/ignored change.
    # Computes usages for all mapped materials; unmapped are returned for editing UI.
    def send_workbench_state
      return unless @last_scan

      mapping = PluginState.instance.mapping
      ignored = PluginState.instance.ignored
      processes = PluginState.instance.processes
      all_items = @last_scan[:items]

      used_names = all_items.map(&:su_material).compact.uniq
      unresolved = used_names.reject { |n| mapping.get(n) || ignored.include?(n) }
      mapped_names = used_names.select { |n| mapping.get(n) }
      ignored_names = ignored & used_names

      # Recompute usages for all mapped materials. Unmapped materials are
      # filtered by Calculator (no record in mapping → skipped).
      calc = Calculator.new(mapping, processes)
      usages = calc.compute(all_items, @last_scan[:openings], {})
      info = build_material_info(used_names, all_items, @last_scan[:colors])

      data = {
        overview: {
          total_faces: all_items.size,
          total_area: all_items.sum(&:qty).round(2),
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
        usages: usages.map(&:to_h),
        by_material: {}
      }
      @dialog.execute_script("window.renderWorkbench(#{JSON.generate(data)})")
      send_mappings
    end

    # Build per-material context (faces / area / part breakdown / spaces / color / suggested unit)
    def build_material_info(names, items, colors)
      mapping = PluginState.instance.mapping
      by_name = Hash.new { |h, k| h[k] = [] }
      items.each { |it| by_name[it.su_material] << it if it.su_material }

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

    def locate_face(entity_id)
      model = Sketchup.active_model
      tid = entity_id.to_i
      result = find_face_with_ancestors(model.entities, tid, [])
      unless result
        UI.messagebox("未找到面 ##{tid}")
        return
      end

      face, ancestors = result

      # Enter component hierarchy so zoom targets the right instance
      model.active_path = ancestors if ancestors.any?

      # Restore previous face
      if @last_face && @last_face.valid?
        @last_face.material = @last_front_mat
        @last_face.back_material = @last_back_mat
      end

      @last_face = face
      @last_front_mat = face.material
      @last_back_mat = face.back_material

      # Paint + select
      highlight = model.materials['Takeoff 定位'] || model.materials.add('Takeoff 定位')
      highlight.color = Sketchup::Color.new(255, 180, 0)
      face.material = highlight
      face.back_material = highlight

      model.rendering_options['XRayMode'] = true
      model.selection.clear
      model.selection.add(face)
      model.active_view.zoom(face)
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
        category_units: cfg['category_units'] || [],
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
        category_units: state.config['category_units'] || [],
        config_units: state.config['units'] || []
      }
      @dialog.execute_script("window.renderProcesses(#{JSON.generate(data)})")
    end

    def save_config(json)
      data = JSON.parse(json)
      PluginState.instance.save_config(
        data['category_units'] || [],
        data['units'] || []
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
