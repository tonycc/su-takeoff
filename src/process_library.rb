require 'json'

module SuTakeoff
  ProcessDef = Struct.new(:category, :name, :waste_rate, :derivations, keyword_init: true) do
    def initialize(category:, name:, waste_rate:, derivations: [])
      super
    end
  end

  class ProcessLibrary
    def initialize
      @processes = []  # Array of ProcessDef
    end

    def add_process(category, name, waste_rate, derivations = [])
      @processes << ProcessDef.new(category: category, name: name, waste_rate: waste_rate, derivations: derivations)
    end

    def processes_for(category)
      @processes.select { |p| p.category == category }
    end

    def default_waste_rate(category)
      first = @processes.find { |p| p.category == category }
      first&.waste_rate || 0.05
    end

    def all_categories
      @processes.map(&:category).uniq
    end

    def save_json(path)
      grouped = @processes.group_by(&:category).transform_values { |ps|
        ps.map { |p|
          h = { name: p.name, waste_rate: p.waste_rate }
          h[:derivations] = p.derivations if p.derivations && !p.derivations.empty?
          h
        }
      }
      File.write(path, JSON.pretty_generate(grouped))
    end

    def load_json(path)
      return unless File.exist?(path)
      @processes.clear
      data = JSON.parse(File.read(path))
      data.each do |category, procs|
        procs.each { |p| add_process(category, p['name'], p['waste_rate'], p['derivations'] || []) }
      end
    end

    def load_json_string(json_str)
      data = JSON.parse(json_str)
      @processes.clear
      data.each do |category, procs|
        procs.each { |p| add_process(category, p['name'], p['waste_rate'], p['derivations'] || []) }
      end
    end

    def save_json_string
      grouped = @processes.group_by(&:category).transform_values { |ps|
        ps.map { |p|
          h = { name: p.name, waste_rate: p.waste_rate }
          h[:derivations] = p.derivations if p.derivations && !p.derivations.empty?
          h
        }
      }
      JSON.generate(grouped)
    end
  end
end