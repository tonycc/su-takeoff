require 'csv'
require 'json'

module SuTakeoff
  MappingRecord = Struct.new(
    :su_material_name, :material_name, :category,
    :unit, :spec, :default_waste_rate, keyword_init: true
  )

  class MaterialMapping
    def initialize
      @records = {}
    end

    def add(su_name, material_name, category, unit = 'm²',
            spec = '', default_waste_rate = 0.05)
      @records[su_name] = MappingRecord.new(
        su_material_name: su_name,
        material_name: material_name,
        category: category,
        unit: unit,
        spec: spec,
        default_waste_rate: default_waste_rate
      )
    end

    def get(su_name)
      @records[su_name]
    end

    def delete(su_name)
      @records.delete(su_name)
    end

    def all
      @records.values
    end

    def unmapped_materials(su_material_names)
      su_material_names.uniq - @records.keys
    end

    def export_csv(path)
      CSV.open(path, 'w') do |csv|
        csv << %w[su_material_name material_name category unit spec default_waste_rate]
        @records.each_value do |r|
          csv << [r.su_material_name, r.material_name, r.category,
                  r.unit, r.spec, r.default_waste_rate]
        end
      end
    end

    def import_csv(path)
      CSV.foreach(path, headers: true) do |row|
        add(
          row['su_material_name'],
          row['material_name'],
          row['category'],
          row['unit'] || 'm²',
          row['spec'] || '',
          (row['default_waste_rate'] || '0.05').to_f
        )
      end
    end

    def save_json(path)
      File.write(path, JSON.pretty_generate(@records.transform_values { |r|
        {
          material_name: r.material_name, category: r.category,
          unit: r.unit, spec: r.spec, default_waste_rate: r.default_waste_rate
        }
      }))
    end

    def load_json(path)
      return unless File.exist?(path)
      data = JSON.parse(File.read(path))
      data.each do |su_name, h|
        add(su_name, h['material_name'], h['category'],
            h['unit'], h['spec'] || '', h['default_waste_rate'].to_f)
      end
    end

    def bulk_set_waste_rate(category, rate)
      @records.each_value do |r|
        r.default_waste_rate = rate if r.category == category
      end
    end
  end
end
