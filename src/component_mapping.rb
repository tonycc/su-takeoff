require 'json'

module SuTakeoff
  ComponentMappingRecord = Struct.new(
    :definition_name, :material_name, :category,
    :unit, :spec, :default_waste_rate, :counting_method,
    :platform_material_tag, :platform_component_type, keyword_init: true
  )

  class ComponentMapping
    def initialize
      @records = {}
    end

    def add(definition_name, material_name, category, unit = '个',
            spec = '', default_waste_rate = 0.0, counting_method = 'expand',
            platform_material_tag = nil, platform_component_type = nil)
      return if definition_name.nil? || definition_name.empty?

      @records[definition_name] = ComponentMappingRecord.new(
        definition_name: definition_name,
        material_name: material_name,
        category: category,
        unit: unit,
        spec: spec,
        default_waste_rate: default_waste_rate,
        counting_method: counting_method,
        platform_material_tag: normalize_optional(platform_material_tag),
        platform_component_type: normalize_optional(platform_component_type)
      )
    end

    def get(definition_name)
      return nil if definition_name.nil? || definition_name.empty?
      @records[definition_name]
    end

    def delete(definition_name)
      @records.delete(definition_name)
    end

    def all
      @records.values
    end

    def save_json(path)
      File.write(path, JSON.pretty_generate(@records.transform_values { |r|
        {
          material_name: r.material_name, category: r.category,
          unit: r.unit, spec: r.spec, default_waste_rate: r.default_waste_rate,
          counting_method: r.counting_method || 'expand',
          platform_material_tag: r.platform_material_tag,
          platform_component_type: r.platform_component_type
        }
      }))
    end

    def load_json(path)
      return unless File.exist?(path)
      data = JSON.parse(File.read(path))
      data.each do |def_name, h|
        add(def_name, h['material_name'], h['category'],
            h['unit'] || '个', h['spec'] || '', h['default_waste_rate'].to_f,
            h['counting_method'] || 'expand', h['platform_material_tag'],
            h['platform_component_type'])
      end
    end

    def save_json_string
      JSON.generate(@records.transform_values { |r|
        {
          material_name: r.material_name, category: r.category,
          unit: r.unit, spec: r.spec, default_waste_rate: r.default_waste_rate,
          counting_method: r.counting_method || 'expand',
          platform_material_tag: r.platform_material_tag,
          platform_component_type: r.platform_component_type
        }
      })
    end

    def load_json_string(json_str)
      data = JSON.parse(json_str)
      data.each do |def_name, h|
        add(def_name, h['material_name'], h['category'],
            h['unit'] || '个', h['spec'] || '', h['default_waste_rate'].to_f,
            h['counting_method'] || 'expand', h['platform_material_tag'],
            h['platform_component_type'])
      end
    end

    private

    def normalize_optional(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end
  end
end
