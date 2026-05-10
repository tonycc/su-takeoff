require 'json'

module SuTakeoff
  ProcessDef = Struct.new(:category, :name, :waste_rate, keyword_init: true)

  class ProcessLibrary
    def initialize
      @processes = []  # Array of ProcessDef
    end

    def add_process(category, name, waste_rate)
      @processes << ProcessDef.new(category: category, name: name, waste_rate: waste_rate)
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
        ps.map { |p| { name: p.name, waste_rate: p.waste_rate } }
      }
      File.write(path, JSON.pretty_generate(grouped))
    end

    def load_json(path)
      return unless File.exist?(path)
      @processes.clear
      data = JSON.parse(File.read(path))
      data.each do |category, procs|
        procs.each { |p| add_process(category, p['name'], p['waste_rate']) }
      end
    end
  end
end
