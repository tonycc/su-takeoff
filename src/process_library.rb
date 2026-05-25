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

    def delete_process(category, name)
      @processes.reject! { |p| p.category == category && p.name == name }
    end

    def processes_for(category)
      @processes.select { |p| p.category == category }
    end

    def all_categories
      @processes.map(&:category).uniq
    end

    def save_json(path)
      File.write(path, JSON.pretty_generate(grouped_for_json))
    end

    def load_json(path)
      return unless File.exist?(path)
      @processes.clear
      data = JSON.parse(File.read(path))
      data.each do |category, procs|
        procs.each { |p| add_process(category, p['name'], p['waste_rate'], build_derivations(p['derivations'])) }
      end
    end

    def load_json_string(json_str)
      data = JSON.parse(json_str)
      @processes.clear
      data.each do |category, procs|
        procs.each { |p| add_process(category, p['name'], p['waste_rate'], build_derivations(p['derivations'])) }
      end
    end

    def build_derivations(raw)
      return [] unless raw
      raw.map { |d| Derivation.new(layer: d['layer'], unit: d['unit'], formula: d['formula'], waste_rate: d['waste_rate'].to_f, category: d['category']) }
    end

    def save_json_string
      JSON.generate(grouped_for_json)
    end

    def grouped_for_json
      @processes.group_by(&:category).transform_values { |ps|
        ps.map { |p|
          h = { 'name' => p.name, 'waste_rate' => p.waste_rate }
          if p.derivations && !p.derivations.empty?
            h['derivations'] = p.derivations.map { |d|
              { 'layer' => d.layer, 'unit' => d.unit, 'formula' => d.formula,
                'waste_rate' => d.waste_rate, 'category' => d.category }
            }
          end
          h
        }
      }
    end
  end
end