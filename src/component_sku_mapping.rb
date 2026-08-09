require 'json'

module SuTakeoff
  component_sku_record_members = [
    :definition_name,
    :platform_sku_id, :platform_sku_code, :platform_sku_name,
    :project_product_id, :product_id, :catalog_code, :product_name, :project_product_code
  ]
  if const_defined?(:ComponentSkuRecord, false)
    unless ComponentSkuRecord.members == component_sku_record_members
      raise 'ComponentSkuRecord 字段已变化，请重启 SketchUp 以完成开发版更新'
    end
  else
    ComponentSkuRecord = Struct.new(*component_sku_record_members, keyword_init: true)
  end

  # 组件级项目产品关联（按组件定义名 definition_name）。
  # 独立于算量数据，仅用于选型展示；旧 platform_sku_* 字段保留兼容历史数据。
  # 不参与算量决议——选择/更换实际产品不会改变算量结果。
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
        platform_sku_name: normalize_optional(sku_name),
        project_product_id: nil,
        product_id: nil,
        catalog_code: nil,
        product_name: nil,
        project_product_code: nil
      )
    end

    def set_project_product(definition_name, project_product_id:, product_id:, catalog_code:,
                            product_name:, project_product_code: nil)
      return if definition_name.nil? || definition_name.to_s.strip.empty?

      @records[definition_name] = ComponentSkuRecord.new(
        definition_name: definition_name,
        platform_sku_id: nil,
        platform_sku_code: nil,
        platform_sku_name: nil,
        project_product_id: normalize_optional(project_product_id),
        product_id: normalize_optional(product_id),
        catalog_code: normalize_optional(catalog_code),
        product_name: normalize_optional(product_name),
        project_product_code: normalize_optional(project_product_code)
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
          platform_sku_name: r.platform_sku_name,
          project_product_id: r.project_product_id,
          product_id: r.product_id,
          catalog_code: r.catalog_code,
          product_name: r.product_name,
          project_product_code: r.project_product_code
        }
      }
    end

    def save_json(path)
      temp_path = "#{path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
      File.open(temp_path, 'wb') do |file|
        file.write(JSON.pretty_generate(to_h))
        file.flush
        file.fsync rescue nil
      end
      File.rename(temp_path, path)
    ensure
      File.delete(temp_path) if temp_path && File.exist?(temp_path)
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
      return unless data.is_a?(Hash)
      data.each do |def_name, h|
        next unless h.is_a?(Hash)
        has_project_product = h.is_a?(Hash) && %w[project_product_id product_id catalog_code product_name project_product_code].any? do |key|
          h.key?(key) && !h[key].to_s.strip.empty?
        end
        if has_project_product
          set_project_product(
            def_name,
            project_product_id: h['project_product_id'],
            product_id: h['product_id'],
            catalog_code: h['catalog_code'],
            product_name: h['product_name'],
            project_product_code: h['project_product_code']
          )
        else
          set(def_name, h['platform_sku_id'], h['platform_sku_code'], h['platform_sku_name'])
        end
      end
    end

    def normalize_optional(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end
  end
end
