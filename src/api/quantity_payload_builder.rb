# src/api/quantity_payload_builder.rb
require 'digest'
require 'json'
require_relative 'project_binding'

module SuTakeoff
  module Api
    class QuantityPayloadBuilder
      BuildResult = Struct.new(:payload, :payload_hash, :issues, keyword_init: true)

      def initialize(items:, openings:, mapping:, component_mapping:, policy:, binding:, ignored: [])
        @items = items
        @openings = openings || []
        @mapping = mapping
        @component_mapping = component_mapping
        @policy = policy
        @binding = binding
        @ignored = ignored || []
      end

      def build
        issues = []
        validate_project!(issues)

        components = build_components(issues)
        issues << issue(:empty_payload, '没有可推送的算量结果') if components.empty?

        business_payload = {
          protocol_version: 2,
          project: {
            code: @binding.project_code.to_s,
            name: @binding.project_name.to_s
          },
          model_key: @binding.ensure_model_key!,
          components: components
        }
        payload_hash = Digest::SHA256.hexdigest(JSON.generate(business_payload))
        payload = {
          protocol_version: 2,
          idempotency_key: "su-v2-#{@binding.model_key}-#{payload_hash[0, 16]}",
          project: business_payload[:project],
          model_key: business_payload[:model_key],
          # source_version 服务端上限 64 字符（联调实测 64→200 / 65→500）。
          # 取 hash 前 16 位（与 idempotency_key 截断一致），内容派生且稳定，共 23 字符。
          source_version: "sha256:#{payload_hash[0, 16]}",
          components: components
        }

        BuildResult.new(payload: payload, payload_hash: payload_hash, issues: issues)
      end

      private

      def validate_project!(issues)
        issues << issue(:missing_project_code, '请先填写平台项目编号') if @binding.project_code.to_s.strip.empty?
        issues << issue(:missing_project_name, '请先填写项目名称') if @binding.project_name.to_s.strip.empty?
      end

      def build_components(issues)
        resolutions = Calculator.new(@component_mapping, policy: @policy)
                                .compute_geometry_only(@items, @openings)
        opening_area_by_face = build_opening_area_map
        grouped = {}

        resolutions.each do |resolution|
          item = resolution[:item]
          next if ignored?(item.su_material)

          record = lookup_record(item)
          unless record
            issues << issue(:unmapped_material, "未映射材料：#{item.su_material}", material: item.su_material)
            next
          end
          material_tag = record.respond_to?(:platform_material_tag) ? record.platform_material_tag : nil
          if material_tag.to_s.strip.empty?
            issues << issue(:missing_platform_material_tag, "缺少平台材料标签：#{item.su_material}", material: item.su_material)
            next
          end

          component_code = component_code_for(item)
          grouped[component_code] ||= {
            code: component_code,
            name: component_name_for(item),
            component_type: component_type_for(item),
            faces: [],
            part_accumulator: {}
          }

          if resolution[:method] == :area && item.kind == :face
            grouped[component_code][:faces] << {
              code: face_code_for(item),
              material_tag: material_tag,
              area_m2: round_quantity([(item.qty_area || item.qty).to_f - (opening_area_by_face[item.face_id] || 0.0), 0.0].max)
            }
          else
            add_part(grouped[component_code], item, resolution, record, material_tag)
          end
        end

        grouped.values.map do |component|
          parts = component.delete(:part_accumulator).values.map do |part|
            part.merge(quantity: round_quantity(part[:quantity]))
          end.sort_by { |p| p[:code] }
          component[:faces] = component[:faces].sort_by { |f| f[:code] }
          component[:parts] = parts
          component
        end.sort_by { |c| c[:code] }
      end

      def build_opening_area_map
        @openings.each_with_object({}) do |opening, memo|
          Array(opening.host_face_ids).each do |face_id|
            memo[face_id] ||= 0.0
            memo[face_id] += opening.area.to_f
          end
        end
      end

      def add_part(component, item, resolution, record, material_tag)
        method = resolution[:method]
        unit = resolution[:unit].to_s.empty? ? item.unit.to_s : resolution[:unit].to_s
        spec = record.respond_to?(:spec) ? record.spec.to_s : ''
        name = record.respond_to?(:material_name) ? record.material_name.to_s : item.su_material.to_s
        key = [component[:code], material_tag, method, unit, spec, name].join('|')
        code = code_with_prefix('p', key)
        component[:part_accumulator][code] ||= {
          code: code,
          name: name,
          quantity: 0.0,
          unit: unit,
          material_tag: material_tag
        }
        component[:part_accumulator][code][:quantity] += quantity_for(item, method)
      end

      def quantity_for(item, method)
        case method
        when :length
          (item.qty_length || item.height || item.qty || 0).to_f
        when :volume
          (item.qty_volume || item.qty || 0).to_f
        when :count
          (item.qty_count || item.qty || 0).to_f
        else
          (item.qty_area || item.qty || 0).to_f
        end
      end

      def lookup_record(item)
        if %i[instance count_solid].include?(item.kind)
          @component_mapping.get(item.su_material) || @mapping.get(item.su_material)
        else
          @mapping.get(item.su_material) || @component_mapping.get(item.su_material)
        end
      end

      def component_code_for(item)
        ids = stable_component_path(item)
        return 'c-model-root' if ids.empty?

        code_with_prefix('c', ids.join('/'))
      end

      def face_code_for(item)
        raw = [stable_component_path(item).join('/'), item.face_persistent_id || item.face_id].join('|')
        code_with_prefix('f', raw)
      end

      def component_name_for(item)
        item.component_path && item.component_path.last ? item.component_path.last : '模型根'
      end

      def component_type_for(item)
        record = @component_mapping.get(item.su_material)
        if record && record.respond_to?(:platform_component_type) && record.platform_component_type
          record.platform_component_type
        elsif stable_component_path(item).empty?
          'model_root'
        else
          'component_instance'
        end
      end

      def stable_component_path(item)
        ids = Array(item.component_path_persistent_ids).compact
        ids = Array(item.component_path_ids).compact if ids.empty?
        ids
      end

      def code_with_prefix(prefix, raw)
        "#{prefix}-#{Digest::SHA256.hexdigest(raw.to_s)[0, 16]}"
      end

      def ignored?(material)
        @ignored.include?(material)
      end

      def round_quantity(value)
        value.to_f.round(4)
      end

      def issue(code, message, extra = {})
        { code: code, message: message }.merge(extra)
      end
    end
  end
end
