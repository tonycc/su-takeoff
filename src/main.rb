# src/main.rb
module SuTakeoff
  PLUGIN_DIR = File.dirname(__dir__)

  # Singleton plugin state
  class PluginState
    include Singleton

    attr_reader :mapping, :processes

    def initialize
      @mapping = MaterialMapping.new
      @processes = ProcessLibrary.new
      load_data
    end

    def self.mapping_path
      File.join(PLUGIN_DIR, 'data', 'default_mapping.json')
    end

    def self.processes_path
      File.join(PLUGIN_DIR, 'data', 'default_processes.json')
    end

    private

    def load_data
      @mapping.load_json(self.class.mapping_path)
      @processes.load_json(self.class.processes_path)
    end
  end

  unless file_loaded?(__FILE__)
    # Add menu
    ui_menu = UI.menu('Plugins').add_submenu('SU Takeoff')
    ui_menu.add_item('材料统计') { Dialog.new.show }

    # Toolbar
    toolbar = UI::Toolbar.new('SU Takeoff')
    cmd = UI::Command.new('SU Takeoff') { Dialog.new.show }
    cmd.tooltip = 'SU Takeoff — 装修面材用量统计'
    toolbar = toolbar.add_item(cmd)
    toolbar.show

    file_loaded(__FILE__)
  end
end
