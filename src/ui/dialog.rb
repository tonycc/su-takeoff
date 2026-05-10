# src/ui/dialog.rb
module SuTakeoff
  class Dialog
    def initialize
      @dialog = UI::WebDialog.new('SU Takeoff — 材料统计',
                                  'su_takeoff_dialog',
                                  1000, 600, 200, 200, true)
      @dialog.set_file(File.join(__dir__, 'index.html'))

      # Bridge callbacks
      @dialog.add_action_callback('scan_all') { |_, _| execute_scan(selection_only: false) }
      @dialog.add_action_callback('scan_selected') { |_, _| execute_scan(selection_only: true) }
      @dialog.add_action_callback('get_mappings') { |_, _| send_mappings }
      @dialog.add_action_callback('save_mapping') { |_, json| save_mapping(json) }
      @dialog.add_action_callback('delete_mapping') { |_, su_name| delete_mapping(su_name) }
      @dialog.add_action_callback('import_csv') { |_, _| import_csv_dialog }
      @dialog.add_action_callback('export_csv') { |_, _| export_csv_dialog }
      @dialog.add_action_callback('get_unmapped') { |_, _| send_unmapped }
      @dialog.add_action_callback('get_processes') { |_, _| send_processes }
      @dialog.add_action_callback('apply_marking') { |_, json| apply_marking(json) }
    end

    def show
      @dialog.show
    end

    private

    def execute_scan(selection_only:)
      scanner = Scanner.new
      result = scanner.scan(selection_only: selection_only)
      marker_items = Marker.to_scan_items
      all_items = result[:items] + marker_items

      mapping = PluginState.instance.mapping
      processes = PluginState.instance.processes
      calc = Calculator.new(mapping, processes)
      usages = calc.compute(all_items, result[:openings], {})
      by_material = calc.group_by_material(usages)
      unmapped = calc.unmapped_materials(all_items)

      data = {
        by_space: usages.map(&:to_h),
        by_material: by_material.transform_values { |v|
          { net_area: v[:net_area], purchase_qty: v[:purchase_qty] }
        },
        unmapped: unmapped
      }
      @dialog.execute_script("window.renderResults(#{JSON.generate(data)})")
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

    def send_unmapped
      # Stub — requires scan context
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
  end
end
