require 'json'

module SuTakeoff
  ComponentSkuRecord = Struct.new(
    :definition_name, :platform_sku_id, :platform_sku_code, :platform_sku_name,
    keyword_init: true
  )

  # 组件级 SKU 关联（按组件定义名 definition_name）。
  # 独立于 ComponentMapping，仅用于选型展示，
  # 不参与算量决议——选择/更换 SKU 不会改变算量结果。
  class ComponentSkuMapping
    def initialize
      @records = {}
    end

    def set(definition_name, sku_id, sku_code, sku_name)
      return if definition_name.nil? || definition_name.to_s.strip.empty?

      @records[definition_name] = ComponentSkuRecord.new(
        definition_name: definition_name,
        platform_sku_id: normalize_optional(sku_id),
        platform_sku_code: normalize_optional(sku_code),
        platform_sku_name: normalize_optional(sku_name)
      )
    end

    def get(definition_name)
      return nil if definition_name.nil? || definition_name.to_s.empty?

      @records[definition_name]
    end

    def delete(definition_name)
      @records.delete(definition_name)
    end

    def all
      @records.values
    end

    def to_h
      @records.transform_values { |r|
        {
          platform_sku_id: r.platform_sku_id,
          platform_sku_code: r.platform_sku_code,
          platform_sku_name: r.platform_sku_name
        }
      }
    end

    def save_json(path)
      File.write(path, JSON.pretty_generate(to_h))
    end

    def load_json(path)
      return unless File.exist?(path)

      load_from_parsed(JSON.parse(File.read(path)))
    end

    def save_json_string
      JSON.generate(to_h)
    end

    def load_json_string(json_str)
      load_from_parsed(JSON.parse(json_str))
    end

    private

    def load_from_parsed(data)
      data.each do |def_name, h|
        set(def_name, h['platform_sku_id'], h['platform_sku_code'], h['platform_sku_name'])
      end
    end

    def normalize_optional(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end
  end
end
