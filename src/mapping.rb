require 'csv'
require 'json'

module SuTakeoff
  MappingRecord = Struct.new(
    :su_material_name, :material_name, :category,
    :unit, :spec, :default_waste_rate, :platform_material_tag,
    :platform_sku_id, :platform_sku_code, :platform_sku_name, keyword_init: true
  )

  class MaterialMapping
    def initialize
      @records = {}
    end

    def add(su_name, material_name, category, unit = 'm²',
            spec = '', default_waste_rate = 0.05, platform_material_tag = nil,
            platform_sku_id = nil, platform_sku_code = nil, platform_sku_name = nil)
      @records[su_name] = MappingRecord.new(
        su_material_name: su_name,
        material_name: material_name,
        category: category,
        unit: unit,
        spec: spec,
        default_waste_rate: default_waste_rate,
        platform_material_tag: normalize_optional(platform_material_tag),
        platform_sku_id: normalize_optional(platform_sku_id),
        platform_sku_code: normalize_optional(platform_sku_code),
        platform_sku_name: normalize_optional(platform_sku_name)
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
        csv << %w[su_material_name material_name category unit spec default_waste_rate platform_material_tag platform_sku_id platform_sku_code platform_sku_name]
        @records.each_value do |r|
          csv << [r.su_material_name, r.material_name, r.category,
                  r.unit, r.spec, r.default_waste_rate, r.platform_material_tag,
                  r.platform_sku_id, r.platform_sku_code, r.platform_sku_name]
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
          (row['default_waste_rate'] || '0.05').to_f,
          row['platform_material_tag'],
          row['platform_sku_id'],
          row['platform_sku_code'],
          row['platform_sku_name']
        )
      end
    end

    def save_json(path)
      File.write(path, JSON.pretty_generate(@records.transform_values { |r|
        {
          material_name: r.material_name, category: r.category,
          unit: r.unit, spec: r.spec, default_waste_rate: r.default_waste_rate,
          platform_material_tag: r.platform_material_tag,
          platform_sku_id: r.platform_sku_id,
          platform_sku_code: r.platform_sku_code,
          platform_sku_name: r.platform_sku_name
        }
      }))
    end

    def load_json(path)
      return unless File.exist?(path)
      data = JSON.parse(File.read(path))
      data.each do |su_name, h|
        add(su_name, h['material_name'], h['category'],
            h['unit'], h['spec'] || '', h['default_waste_rate'].to_f,
            h['platform_material_tag'],
            h['platform_sku_id'], h['platform_sku_code'], h['platform_sku_name'])
      end
    end

    def load_json_string(json_str)
      data = JSON.parse(json_str)
      data.each do |su_name, h|
        add(su_name, h['material_name'], h['category'],
            h['unit'], h['spec'] || '', h['default_waste_rate'].to_f,
            h['platform_material_tag'],
            h['platform_sku_id'], h['platform_sku_code'], h['platform_sku_name'])
      end
    end

    def save_json_string
      JSON.generate(@records.transform_values { |r|
        {
          material_name: r.material_name, category: r.category,
          unit: r.unit, spec: r.spec, default_waste_rate: r.default_waste_rate,
          platform_material_tag: r.platform_material_tag,
          platform_sku_id: r.platform_sku_id,
          platform_sku_code: r.platform_sku_code,
          platform_sku_name: r.platform_sku_name
        }
      })
    end

    private

    def normalize_optional(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end

  end
end
