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
      @dialog.add_action_callback('save_mappings_batch') { |_ctx, json| save_mappings_batch(json) }
      @dialog.add_action_callback('set_ignored') { |_ctx, json| set_ignored(json) }
      @dialog.add_action_callback('get_mappings') { |_ctx| send_mappings }
      @dialog.add_action_callback('save_mapping') { |_ctx, json| save_mapping(json) }
      @dialog.add_action_callback('delete_mapping') { |_ctx, su_name| delete_mapping(su_name) }
      @dialog.add_action_callback('import_csv') { |_ctx| import_csv_dialog }
      @dialog.add_action_callback('export_csv') { |_ctx| export_csv_dialog }
      @dialog.add_action_callback('get_processes') { |_ctx| send_processes }
      @dialog.add_action_callback('apply_marking') { |_ctx, json| apply_marking(json) }
      @dialog.add_action_callback('locate_material') { |_ctx, su_name| locate_material(su_name) }
      @dialog.add_action_callback('snapshot_to_model') { |_ctx| snapshot_to_model }
      @dialog.add_action_callback('load_from_model') { |_ctx| load_from_model }
    end

    def show
      @dialog.show
      send_mappings
      send_processes
    end

    private

    # Phase 1 — scan only. Reports unmapped materials; does NOT compute stats yet.
    def do_scan(selection_only:)
      Debug.section "【阶段一】扫描开始"

      scanner = Scanner.new
      result = scanner.scan(selection_only: selection_only)

      Debug.subsection "人工标注面采集"
      marker_items = Marker.to_scan_items
      all_items = result[:items] + marker_items

      Debug.log
      Debug.log "合并后总面数: #{all_items.size} (扫描: #{result[:items].size} + 标注: #{marker_items.size})"

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

      Debug.subsection "工作台状态推送"
      Debug.log "材质种类: #{used_names.size} | 已映射: #{mapped_names.size} | 已忽略: #{ignored_names.size} | 待处理: #{unresolved.size}"

      # Recompute usages for all mapped materials. Unmapped materials are
      # filtered by Calculator (no record in mapping → skipped).
      calc = Calculator.new(mapping, processes)
      usages = calc.compute(all_items, @last_scan[:openings], {})
      by_material = calc.group_by_material(usages)

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
        by_material: by_material.transform_values { |v|
          { net_area: v[:net_area], purchase_qty: v[:purchase_qty] }
        }
      }
      @dialog.execute_script("window.renderWorkbench(#{JSON.generate(data)})")
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
          mapped_unit: record&.unit
        }
      end
    end

    def save_mappings_batch(json)
      rows = JSON.parse(json)
      m = PluginState.instance.mapping
      rows.each do |row|
        next if row['material_name'].to_s.strip.empty?
        m.add(row['su_name'], row['material_name'], row['category'] || '其他',
              row['unit'] || 'm²', row['spec'] || '', (row['waste_rate'] || 0.05).to_f)
      end
      m.save_json(PluginState.mapping_path)
      send_workbench_state if @last_scan
      send_mappings
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

    def send_mappings
      mappings = PluginState.instance.mapping.all.map(&:to_h)
      @dialog.execute_script("window.renderMappings(#{JSON.generate(mappings)})")
    end

    def save_mapping(json)
      data = JSON.parse(json)
      m = PluginState.instance.mapping
      m.add(data['su_name'], data['material_name'], data['category'],
            data['unit'], data['spec'], data['waste_rate'].to_f)
      m.save_json(PluginState.mapping_path)
      send_mappings
    end

    def delete_mapping(su_name)
      m = PluginState.instance.mapping
      m.delete(su_name)
      m.save_json(PluginState.mapping_path)
      send_mappings
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
      data = PluginState.instance.processes.all_categories.map { |cat|
        { category: cat, processes: PluginState.instance.processes.processes_for(cat) }
      }
      @dialog.execute_script("window.renderProcesses(#{JSON.generate(data)})")
    end

    def apply_marking(json)
      data = JSON.parse(json)
      Marker.apply(data)
    end

    def snapshot_to_model
      PluginState.instance.snapshot_to_model
      UI.messagebox('规则已保存到模型属性字典。下次打开此模型时将自动加载。')
    end

    def load_from_model
      if PluginState.instance.load_from_model_dialog
        send_mappings
        send_processes
        send_workbench_state if @last_scan
        UI.messagebox('已从模型属性字典加载规则并同步到本地文件。')
      end
    end
  end
end
