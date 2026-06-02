# src/main.rb
module SuTakeoff
  PLUGIN_DIR = File.dirname(__dir__)

  # Singleton plugin state
  class PluginState
    include Singleton

    attr_reader :mapping, :component_mapping, :ignored, :config

    DICT_NAME = 'su_takeoff_data'

    def initialize
      @mapping = MaterialMapping.new
      @component_mapping = ComponentMapping.new
      @ignored = []
      @config = { 'material_category_units' => [], 'component_category_units' => [],
                  'units' => [],
                  'layer_rules' => {},
                  'tag_defs' => {},
                  'heuristics_enabled' => true }
      load_data
      # 注册内置策略（幂等：Registry.register 同对象重复注册是 no-op）
      Strategies::Builtin.register_all! if Strategies::Registry.all.empty?
    end

    # 算量策略：基于当前 mapping + config 构造一个 TakeoffPolicy。
    # 每次调用都拿最新配置，避免缓存陈旧规则。
    def takeoff_policy
      TakeoffPolicy.new(
        mapping: @mapping,
        layer_rules: @config['layer_rules'] || {},
        tag_defs: @config['tag_defs'] || {},
        heuristics_enabled: @config.fetch('heuristics_enabled', true),
        thresholds: (@config['heuristic_thresholds'] || {}).transform_keys(&:to_sym)
      )
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

    def self.component_mapping_path
      File.join(PLUGIN_DIR, 'data', 'default_component_mapping.json')
    end

    def self.ignored_path
      File.join(PLUGIN_DIR, 'data', 'ignored_materials.json')
    end

    def self.config_path
      File.join(PLUGIN_DIR, 'data', 'config.json')
    end

    def save_config(material_category_units:, component_category_units:, units:,
                    layer_rules: nil, heuristics_enabled: nil,
                    heuristic_thresholds: nil, tag_defs: nil)
      @config = {
        'material_category_units' => material_category_units,
        'component_category_units' => component_category_units,
        'units' => units,
        'layer_rules' => layer_rules || @config['layer_rules'] || {},
        'tag_defs' => tag_defs || @config['tag_defs'] || {},
        'heuristics_enabled' => heuristics_enabled.nil? ? @config.fetch('heuristics_enabled', true) : heuristics_enabled,
        'heuristic_thresholds' => heuristic_thresholds || @config['heuristic_thresholds'] || {}
      }
      File.write(self.class.config_path, JSON.pretty_generate(@config))
      save_config_to_model_dict
    end

    def save_config_to_model_dict
      model = Sketchup.active_model
      dict = model.attribute_dictionary(DICT_NAME, true)
      dict['config'] = JSON.generate(@config)
    rescue => e
      puts "[SuTakeoff] Warning: #{__method__} failed: #{e.message}"
    end

    def save_mapping_to_model_dict
      model = Sketchup.active_model
      dict = model.attribute_dictionary(DICT_NAME, true)
      dict['mapping'] = @mapping.save_json_string
    rescue => e
      puts "[SuTakeoff] Warning: #{__method__} failed: #{e.message}"
    end

    def save_component_mapping_to_model_dict
      model = Sketchup.active_model
      dict = model.attribute_dictionary(DICT_NAME, true)
      dict['component_mapping'] = @component_mapping.save_json_string
    rescue => e
      puts "[SuTakeoff] Warning: #{__method__} failed: #{e.message}"
    end

    def save_ignored_to_model_dict
      model = Sketchup.active_model
      dict = model.attribute_dictionary(DICT_NAME, true)
      dict['ignored'] = JSON.generate(@ignored)
    rescue => e
      puts "[SuTakeoff] Warning: #{__method__} failed: #{e.message}"
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

      if model_dict[:config]
        @config = JSON.parse(model_dict[:config])
      elsif File.exist?(self.class.config_path)
        @config = JSON.parse(File.read(self.class.config_path))
      end
      # Migrate old single category_units to material_category_units
      if @config['category_units'] && !@config['material_category_units']
        @config['material_category_units'] = @config['category_units']
      end
      @config['material_category_units'] ||= []
      @config['component_category_units'] ||= []
      @config['layer_rules']         ||= {}
      # 首次迁移：layer_rules 非空且 tag_defs 不存在时，复制为初始标记
      if @config['layer_rules'] && !@config['layer_rules'].empty? && !@config['tag_defs']
        @config['tag_defs'] = @config['layer_rules'].dup
      end
      @config['tag_defs']            ||= {}
      @config['heuristics_enabled']    = true if @config['heuristics_enabled'].nil?
    end

    def save_ignored
      File.write(self.class.ignored_path, JSON.pretty_generate(@ignored))
      save_ignored_to_model_dict
    end

    def load_from_model_dict
      model = Sketchup.active_model
      dict = model.attribute_dictionary(DICT_NAME)
      return {} unless dict

      result = {}
      result[:mapping] = dict['mapping'] if dict['mapping']
      result[:component_mapping] = dict['component_mapping'] if dict['component_mapping']
      result[:ignored] = dict['ignored'] if dict['ignored']
      result[:config] = dict['config'] if dict['config']
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