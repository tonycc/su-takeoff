# src/main.rb
module SuTakeoff
  PLUGIN_DIR = File.dirname(__dir__)

  # Singleton plugin state
  class PluginState
    include Singleton

    attr_reader :mapping, :component_mapping, :processes, :ignored, :config

    DICT_NAME = 'su_takeoff_data'

    def initialize
      @mapping = MaterialMapping.new
      @processes = ProcessLibrary.new
      @component_mapping = ComponentMapping.new
      @ignored = []
      @config = { 'material_category_units' => [], 'component_category_units' => [],
                  'units' => [],
                  'length_units' => %w[m mm cm dm km],
                  'count_units' => %w[个 件 套 组 台 只] }
      load_data
    end

    def ignore!(names)
      @ignored = (@ignored + Array(names)).uniq
      save_ignored
    end

    # Replace the entire ignored list (not additive) — used when UI sends the
    # complete current state.
    def set_ignored!(names)
      @ignored = Array(names).uniq
      save_ignored
    end

    def unignore!(name)
      @ignored.delete(name)
      save_ignored
    end

    def self.mapping_path
      File.join(PLUGIN_DIR, 'data', 'default_mapping.json')
    end

    def self.processes_path
      File.join(PLUGIN_DIR, 'data', 'default_processes.json')
    end

    def self.component_mapping_path
      File.join(PLUGIN_DIR, 'data', 'default_component_mapping.json')
    end

    def self.ignored_path
      File.join(PLUGIN_DIR, 'data', 'ignored_materials.json')
    end

    def self.config_path
      File.join(PLUGIN_DIR, 'data', 'config.json')
    end

    def save_config(material_category_units, component_category_units, units, length_units = nil, count_units = nil)
      length_units ||= @config['length_units'] || %w[m mm cm dm km]
      count_units ||= @config['count_units'] || %w[个 件 套 组 台 只]
      @config = { 'material_category_units' => material_category_units,
                  'component_category_units' => component_category_units,
                  'units' => units,
                  'length_units' => length_units, 'count_units' => count_units }
      path = self.class.config_path
      File.write(path, JSON.pretty_generate(@config))
    end

    private

    def load_data
      # Priority: model attribute dict > local JSON files > empty defaults
      model_dict = load_from_model_dict

      if model_dict[:mapping]
        @mapping.load_json_string(model_dict[:mapping])
      else
        @mapping.load_json(self.class.mapping_path)
      end

      if model_dict[:processes]
        @processes.load_json_string(model_dict[:processes])
      else
        @processes.load_json(self.class.processes_path)
      end

      if model_dict[:component_mapping]
        @component_mapping.load_json_string(model_dict[:component_mapping])
      else
        @component_mapping.load_json(self.class.component_mapping_path)
      end

      if model_dict[:ignored]
        @ignored = JSON.parse(model_dict[:ignored])
      elsif File.exist?(self.class.ignored_path)
        @ignored = JSON.parse(File.read(self.class.ignored_path))
      end

      if File.exist?(self.class.config_path)
        @config = JSON.parse(File.read(self.class.config_path))
        # Migrate old single category_units to material_category_units
        if @config['category_units'] && !@config['material_category_units']
          @config['material_category_units'] = @config['category_units']
        end
        @config['material_category_units'] ||= []
        @config['component_category_units'] ||= []
      end
    end

    def save_ignored
      File.write(self.class.ignored_path, JSON.pretty_generate(@ignored))
    end

    def load_from_model_dict
      model = Sketchup.active_model
      dict = model.attribute_dictionary(DICT_NAME)
      return {} unless dict

      result = {}
      result[:mapping] = dict['mapping'] if dict['mapping']
      result[:processes] = dict['processes'] if dict['processes']
      result[:component_mapping] = dict['component_mapping'] if dict['component_mapping']
      result[:ignored] = dict['ignored'] if dict['ignored']
      result
    end
  end

  unless file_loaded?(__FILE__)
    # Add menu
    ui_menu = UI.menu('Plugins').add_submenu('SU Takeoff')
    ui_menu.add_item('材料统计') { Dialog.new.show }
    ui_menu.add_separator
    ui_menu.add_item('重新加载插件') {
      Dir.glob(File.join(PLUGIN_DIR, 'src/**/*.rb')).sort.each { |f| load f }
      # Reset singleton so PluginState picks up fresh data
      PluginState.instance.instance_variable_set(:@mapping, MaterialMapping.new)
      PluginState.instance.instance_variable_set(:@processes, ProcessLibrary.new)
      PluginState.instance.instance_variable_set(:@component_mapping, ComponentMapping.new)
      PluginState.instance.instance_variable_set(:@ignored, [])
      PluginState.instance.send(:load_data)
      UI.messagebox("SU Takeoff 插件已重新加载")
    }

    # Toolbar
    toolbar = UI::Toolbar.new('SU Takeoff')
    cmd = UI::Command.new('SU Takeoff') { Dialog.new.show }
    cmd.tooltip = 'SU Takeoff — 装修面材用量统计'
    toolbar = toolbar.add_item(cmd)
    toolbar.show

    file_loaded(__FILE__)
  end
end