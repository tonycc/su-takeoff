# src/main.rb
module SuTakeoff
  PLUGIN_DIR = File.dirname(__dir__) unless const_defined?(:PLUGIN_DIR)

  # Singleton plugin state
  class PluginState
    include Singleton

    attr_reader :component_mapping, :component_sku, :config

    DICT_NAME = 'su_takeoff_data'

    def initialize
      @component_mapping = ComponentMapping.new
      @component_sku = ComponentSkuMapping.new
      @config = { 'component_category_units' => [],
                  'layer_rules' => {},
                  'tag_defs' => {},
                  'heuristics_enabled' => true }
      load_data
      # 注册内置策略（幂等：Registry.register 同对象重复注册是 no-op）
      if Strategies::Registry.all.empty?
        Strategies::Builtin.register_all!
        strategies_path = File.join(PLUGIN_DIR, 'data', 'strategies.json')
        Strategies::Loader.load_from_file!(strategies_path)
      end
    end

    # 算量策略：基于当前 config 构造一个 TakeoffPolicy。
    # 每次调用都拿最新配置，避免缓存陈旧规则。
    def takeoff_policy
      TakeoffPolicy.new(
        layer_rules: @config['layer_rules'] || {},
        tag_defs: @config['tag_defs'] || {},
        heuristics_enabled: @config.fetch('heuristics_enabled', true),
        thresholds: (@config['heuristic_thresholds'] || {}).transform_keys(&:to_sym)
      )
    end

    def self.component_mapping_path
      File.join(PLUGIN_DIR, 'data', 'default_component_mapping.json')
    end

    def self.component_sku_path
      File.join(PLUGIN_DIR, 'data', 'component_sku_mapping.json')
    end

    def self.config_path
      File.join(PLUGIN_DIR, 'data', 'config.json')
    end

    def save_config(component_category_units:, layer_rules: nil, heuristics_enabled: nil,
                    heuristic_thresholds: nil, tag_defs: nil)
      @config = {
        'component_category_units' => component_category_units,
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

    def save_component_mapping_to_model_dict
      model = Sketchup.active_model
      dict = model.attribute_dictionary(DICT_NAME, true)
      dict['component_mapping'] = @component_mapping.save_json_string
    rescue => e
      puts "[SuTakeoff] Warning: #{__method__} failed: #{e.message}"
    end

    def save_component_sku_to_model_dict
      model = Sketchup.active_model
      dict = model.attribute_dictionary(DICT_NAME, true)
      dict['component_sku'] = @component_sku.save_json_string
    rescue => e
      puts "[SuTakeoff] Warning: #{__method__} failed: #{e.message}"
    end

    private

    def load_data
      # Priority: model attribute dict > local JSON files > empty defaults
      model_dict = load_from_model_dict

      if model_dict[:component_mapping]
        @component_mapping.load_json_string(model_dict[:component_mapping])
      else
        @component_mapping.load_json(self.class.component_mapping_path)
      end

      if model_dict[:component_sku]
        @component_sku.load_json_string(model_dict[:component_sku])
      else
        @component_sku.load_json(self.class.component_sku_path)
      end

      if model_dict[:config]
        @config = JSON.parse(model_dict[:config])
      elsif File.exist?(self.class.config_path)
        @config = JSON.parse(File.read(self.class.config_path))
      end
      @config['component_category_units'] ||= []
      @config['layer_rules']         ||= {}
      # 首次迁移：layer_rules 非空且 tag_defs 不存在时，复制为初始标记
      if @config['layer_rules'] && !@config['layer_rules'].empty? && !@config['tag_defs']
        @config['tag_defs'] = @config['layer_rules'].dup
      end
      @config['tag_defs']            ||= {}
      @config['heuristics_enabled']    = true if @config['heuristics_enabled'].nil?
    end

    def load_from_model_dict
      model = Sketchup.active_model
      dict = model.attribute_dictionary(DICT_NAME)
      return {} unless dict

      result = {}
      result[:component_mapping] = dict['component_mapping'] if dict['component_mapping']
      result[:component_sku] = dict['component_sku'] if dict['component_sku']
      result[:config] = dict['config'] if dict['config']
      result
    end
  end

  def self.reset_plugin_state!
    state = PluginState.instance
    state.instance_variable_set(:@component_mapping, ComponentMapping.new)
    state.instance_variable_set(:@component_sku, ComponentSkuMapping.new)
    state.instance_variable_set(:@config, {
      'component_category_units' => [],
      'layer_rules' => {},
      'tag_defs' => {},
      'heuristics_enabled' => true
    })
    state.send(:load_data)
  end

  def self.development_loader?
    respond_to?(:dev_mode?) && dev_mode?
  end

  unless file_loaded?(__FILE__)
    # Add menu
    menu_name = development_loader? ? 'SU Takeoff Dev' : 'SU Takeoff'
    ui_menu = UI.menu('Plugins').add_submenu(menu_name)
    ui_menu.add_item('材料统计') { Dialog.new.show }
    ui_menu.add_separator
    ui_menu.add_item('重新加载插件') {
      if SuTakeoff.respond_to?(:reload_sources!)
        SuTakeoff.reload_sources!
      else
        Dir.glob(File.join(PLUGIN_DIR, 'src/**/*.rb')).sort.each { |f| load f }
        SuTakeoff.reset_plugin_state!
      end
      UI.messagebox("#{menu_name} 源码已重新加载\n#{PLUGIN_DIR}")
    }

    # Toolbar
    toolbar = UI::Toolbar.new(menu_name)
    cmd = UI::Command.new(menu_name) { Dialog.new.show }
    cmd.tooltip = 'SU Takeoff — 装修面材用量统计'
    toolbar = toolbar.add_item(cmd)
    toolbar.show

    file_loaded(__FILE__)
  end
end
