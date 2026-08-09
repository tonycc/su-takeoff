# src/main.rb
module SuTakeoff
  PLUGIN_DIR = File.dirname(__dir__) unless const_defined?(:PLUGIN_DIR)
  VERSION = File.read(File.join(PLUGIN_DIR, 'VERSION'), encoding: 'UTF-8').strip.freeze unless const_defined?(:VERSION)

  # Singleton plugin state
  class PluginState
    include Singleton

    DICT_NAME = 'su_takeoff_data'

    def initialize
      @component_sku = ComponentSkuMapping.new
      @config = { 'component_category_units' => [],
                  'layer_rules' => {},
                  'tag_defs' => {},
                  'heuristics_enabled' => true }
      @model_identity = current_model_identity
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
      ensure_current_model!
      TakeoffPolicy.new(
        layer_rules: @config['layer_rules'] || {},
        tag_defs: @config['tag_defs'] || {},
        heuristics_enabled: @config.fetch('heuristics_enabled', true),
        thresholds: (@config['heuristic_thresholds'] || {}).transform_keys(&:to_sym)
      )
    end

    def component_sku
      ensure_current_model!
      @component_sku
    end

    def config
      ensure_current_model!
      @config
    end

    def self.component_sku_path
      File.join(PLUGIN_DIR, 'data', 'component_sku_mapping.json')
    end

    def self.config_path
      File.join(PLUGIN_DIR, 'data', 'config.json')
    end

    def save_config(component_category_units:, layer_rules: nil, heuristics_enabled: nil,
                    heuristic_thresholds: nil, tag_defs: nil)
      ensure_current_model!
      new_config = {
        'component_category_units' => component_category_units,
        'layer_rules' => layer_rules || @config['layer_rules'] || {},
        'tag_defs' => tag_defs || @config['tag_defs'] || {},
        'heuristics_enabled' => heuristics_enabled.nil? ? @config.fetch('heuristics_enabled', true) : heuristics_enabled,
        'heuristic_thresholds' => heuristic_thresholds || @config['heuristic_thresholds'] || {}
      }
      atomic_write(self.class.config_path, JSON.pretty_generate(new_config))
      @config = new_config
      save_config_to_model_dict
    end

    def save_config_to_model_dict
      ensure_current_model!
      model = Sketchup.active_model
      dict = model.attribute_dictionary(DICT_NAME, true)
      dict['config'] = JSON.generate(@config)
    rescue => e
      puts "[SuTakeoff] Warning: #{__method__} failed: #{e.message}"
    end

    def save_component_sku_to_model_dict
      ensure_current_model!
      model = Sketchup.active_model
      dict = model.attribute_dictionary(DICT_NAME, true)
      dict['component_sku'] = @component_sku.save_json_string
    rescue => e
      puts "[SuTakeoff] Warning: #{__method__} failed: #{e.message}"
    end

    private

    def current_model_identity
      model = Sketchup.active_model
      model ? model.object_id : nil
    rescue
      nil
    end

    def ensure_current_model!
      identity = current_model_identity
      return if identity == @model_identity

      @model_identity = identity
      @component_sku = ComponentSkuMapping.new
      @config = {
        'component_category_units' => [],
        'layer_rules' => {},
        'tag_defs' => {},
        'heuristics_enabled' => true
      }
      load_data
    end

    def load_data
      # Priority: model attribute dict > local JSON files > empty defaults
      model_dict = load_from_model_dict

      if model_dict[:component_sku]
        begin
          @component_sku.load_json_string(model_dict[:component_sku])
        rescue JSON::ParserError, TypeError => e
          puts "[SuTakeoff] Warning: invalid model component_sku: #{e.message}"
        end
      else
        begin
          @component_sku.load_json(self.class.component_sku_path)
        rescue JSON::ParserError, TypeError => e
          puts "[SuTakeoff] Warning: invalid component_sku file: #{e.message}"
        end
      end

      if model_dict[:config]
        parsed = JSON.parse(model_dict[:config]) rescue nil
        @config = parsed if parsed.is_a?(Hash)
      elsif File.exist?(self.class.config_path)
        parsed = JSON.parse(File.read(self.class.config_path)) rescue nil
        @config = parsed if parsed.is_a?(Hash)
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

    def atomic_write(path, content)
      temp_path = "#{path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
      File.open(temp_path, 'wb') do |file|
        file.write(content)
        file.flush
        file.fsync rescue nil
      end
      File.rename(temp_path, path)
    ensure
      File.delete(temp_path) if temp_path && File.exist?(temp_path)
    end

    def load_from_model_dict
      model = Sketchup.active_model
      dict = model.attribute_dictionary(DICT_NAME)
      return {} unless dict

      result = {}
      result[:component_sku] = dict['component_sku'] if dict['component_sku']
      result[:config] = dict['config'] if dict['config']
      result
    end
  end

  def self.reset_plugin_state!
    Strategies::Registry.reset!
    Strategies::Builtin.register_all!
    strategies_path = File.join(PLUGIN_DIR, 'data', 'strategies.json')
    Strategies::Loader.load_from_file!(strategies_path)
    state = PluginState.instance
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
      ok =
        if SuTakeoff.respond_to?(:reload_sources!)
          SuTakeoff.reload_sources!
        else
          Dir.glob(File.join(PLUGIN_DIR, 'src/**/*.rb')).sort.each { |f| load f }
          SuTakeoff.reset_plugin_state!
          true
        end
      UI.messagebox(ok ? "#{menu_name} 源码已重新加载\n#{PLUGIN_DIR}" :
                         "#{menu_name} 重新加载失败，详见 Ruby 控制台")
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
