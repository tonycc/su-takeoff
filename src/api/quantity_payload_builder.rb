# src/api/quantity_payload_builder.rb
require 'digest'
require 'json'
require_relative 'project_binding'
require_relative '../workbench_presenter' unless defined?(SuTakeoff::WorkbenchPresenter)

module SuTakeoff
  module Api
    class QuantityPayloadBuilder
      build_result_members = %i[payload payload_hash issues]
      if const_defined?(:BuildResult, false)
        unless BuildResult.members == build_result_members
          raise 'BuildResult 字段已变化，请重启 SketchUp 以完成开发版更新'
        end
      else
        BuildResult = Struct.new(*build_result_members, keyword_init: true)
      end

      def initialize(items:, openings:, policy:, binding:, component_sku: nil, hierarchy: nil,
                     model_version_no: nil, update_content: nil, visible_component_paths: nil,
                     designer_account: nil)
        @items = items
        @openings = openings || []
        @policy = policy
        @binding = binding
        @component_sku = component_sku
        @hierarchy = hierarchy
        # 用户在推送确认窗口填写的版本信息属于业务内容，必须参与 hash，
        # 否则用户修改版本号/更新内容后仍会命中旧的幂等键。
        @model_version_no = model_version_no.to_s.strip
        @update_content = update_content.to_s.strip
        @designer_account = designer_account.to_s.strip
        # 按组件页面确认推送时传入当前可见的树节点路径。
        # nil 表示兼容旧调用，数组（包括空数组）表示严格按页面可见节点筛选。
        @visible_component_path_keys = normalize_visible_component_paths(visible_component_paths)
        @definition_names_by_entity_path = build_definition_name_index(hierarchy)
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
        business_payload.merge!(push_metadata)
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
        }.merge(push_metadata)

        BuildResult.new(payload: payload, payload_hash: payload_hash, issues: issues)
      end

      private

      def validate_project!(issues)
        issues << issue(:missing_project_code, '请先填写平台项目编号') if @binding.project_code.to_s.strip.empty?
        issues << issue(:missing_project_name, '请先填写项目名称') if @binding.project_name.to_s.strip.empty?
      end

      # 只在有值时发送，保持脱离 UI 的旧调用和旧测试兼容。
      # 正式云端推送由 Dialog 在进入 Builder 前强制要求两个字段都有值。
      def push_metadata
        metadata = {}
        metadata[:designer_account] = @designer_account unless @designer_account.empty?
        metadata[:model_version_no] = @model_version_no unless @model_version_no.empty?
        metadata[:update_content] = @update_content unless @update_content.empty?
        metadata
      end

      def build_components(issues)
        return build_components_from_display_rows if @hierarchy.is_a?(Hash)

        build_components_from_items(issues)
      end

      # 生产推送路径：直接使用按组件页面的最终行汇总，并按确认推送时页面可见的
      # 树节点路径筛选。数量全为 0 的可见节点也要发送，此时 parts 为空数组。
      # parts 只是当前后端协议承载多个计量列的兼容容器，不代表插件内部存在部品对象。
      def build_components_from_display_rows
        geometry_presenter = WorkbenchPresenter.new(
          items: @items,
          openings: @openings,
          hierarchy: @hierarchy,
          colors: {},
          policy: @policy,
          component_sku: @component_sku
        )
        rows = geometry_presenter.build_component_rows
        components = []
        push_rows = rows.reject { |row| row[:entity_id].to_i.zero? }
                        .select { |row| pushable_display_row?(row) }

        push_rows.each do |row|
          # 页面行是递归汇总。若父子行同时可见，从父行减去最近的可见子树汇总，
          # 使同一几何量在本次扁平 Payload 中只出现一次；父行折叠时仍保留完整汇总。
          quantities = exclusive_display_quantities(row, push_rows)

          path = Array(row[:component_path_persistent_ids]).compact
          entity_path = Array(row[:component_path_ids]).compact
          path = entity_path if path.empty?
          next if entity_path.empty?
          next if path.empty?

          component_code = code_with_prefix('c', path.join('/'))
          component = {
            code: component_code,
            name: row[:name].to_s.strip.empty? ? '未命名组件' : row[:name].to_s,
            component_type: row[:component_type].to_s.empty? ? 'component_instance' : row[:component_type],
            part_accumulator: {}
          }
          quantity_tag = row[:tag].to_s.strip
          component[:quantity_tag] = quantity_tag unless quantity_tag.empty?
          project_product_id = project_product_id_for_path(
            entity_path,
            preferred_name: row[:definition_name]
          )
          component[:project_product_id] = project_product_id if project_product_id

          add_display_part(component, '面积', quantities[:area], 'm2') if quantities[:area].positive?
          add_display_part(component, '长度', quantities[:length], 'm') if quantities[:length].positive?
          add_display_part(component, '体积', quantities[:volume], 'm3') if quantities[:volume].positive?
          add_display_part(component, '件数', quantities[:count], '个') if quantities[:count].positive?

          component[:parts] = component.delete(:part_accumulator).values.map do |part|
            part.merge(quantity: round_quantity(part[:quantity]))
          end.sort_by { |part| part[:code] }
          components << component
        end

        components.sort_by { |component| component[:code] }
      end

      def display_quantities(row)
        {
          area: row[:area_m2].to_f,
          length: row[:length_mm].to_f / 1000.0,
          volume: row[:volume_m3].to_f,
          count: row[:count].to_f
        }
      end

      def exclusive_display_quantities(row, selected_rows)
        own_path = Array(row[:component_path_ids]).map(&:to_i)
        quantities = display_quantities(row)
        descendants = selected_rows.select do |candidate|
          path = Array(candidate[:component_path_ids]).map(&:to_i)
          path.length > own_path.length && path.first(own_path.length) == own_path
        end
        nearest = descendants.reject do |candidate|
          candidate_path = Array(candidate[:component_path_ids]).map(&:to_i)
          descendants.any? do |middle|
            middle_path = Array(middle[:component_path_ids]).map(&:to_i)
            middle_path.length < candidate_path.length &&
              middle_path.length > own_path.length &&
              candidate_path.first(middle_path.length) == middle_path
          end
        end
        nearest.each do |child|
          child_quantities = display_quantities(child)
          quantities.each_key { |key| quantities[key] -= child_quantities[key] }
        end
        quantities.transform_values { |value| value.abs < 1.0e-9 ? 0.0 : [value, 0.0].max }
      end

      def add_display_part(component, name, quantity, unit)
        key = [component[:code], name, unit].join('|')
        code = code_with_prefix('p', key)
        component[:part_accumulator][code] = {
          code: code,
          name: name,
          quantity: quantity.to_f,
          unit: unit
        }
      end

      def pushable_display_row?(row)
        if @visible_component_path_keys
          entity_path = Array(row[:component_path_ids]).compact
          return @visible_component_path_keys.include?(path_key(entity_path))
        end

        # 没有页面可见路径时保留旧调用的安全过滤；正式页面推送会走上面的
        # 严格路径筛选，因此 showEmpty/showHidden 的页面状态不会丢失。
        return false if row[:hidden]
        return false if %w[hidden_skipped pure_organizational].include?(row[:classification])

        true
      end

      def normalize_visible_component_paths(paths)
        return nil if paths.nil?

        Array(paths).each_with_object({}) do |raw_path, result|
          next unless raw_path.is_a?(Array)

          ids = raw_path.each_with_object([]) do |raw_id, memo|
            begin
              id = Integer(raw_id)
              memo << id if id.positive?
            rescue ArgumentError, TypeError
              # 忽略前端异常值；模型根及空路径不属于可推送节点。
            end
          end
          result[path_key(ids)] = true unless ids.empty?
        end
      end

      def path_key(path)
        Array(path).map(&:to_i).join('/')
      end

      def project_product_id_for_definition(definition_name)
        return nil unless @component_sku && @component_sku.respond_to?(:get)

        name = definition_name.to_s.strip
        return nil if name.empty?

        record = @component_sku.get(name)
        return nil unless record && record.respond_to?(:project_product_id)

        value = record.project_product_id.to_s.strip
        value.empty? ? nil : value
      end

      # 从当前容器向外逐级查找产品关联。嵌套节点没有定义名或没有单独关联时，
      # 继承最近祖先组件的关联；显式的内层关联始终优先。
      def project_product_id_for_path(entity_path, preferred_name: nil, fallback_names: [])
        names = [preferred_name]
        ids = Array(entity_path).compact.map(&:to_i)
        ids.length.downto(1) do |length|
          names << @definition_names_by_entity_path[ids.first(length).join('/')]
        end
        names.concat(Array(fallback_names).reverse)

        names.each do |name|
          project_product_id = project_product_id_for_definition(name)
          return project_product_id if project_product_id
        end
        nil
      end

      # 无 hierarchy 时保留旧的构建路径，供脱离 SketchUp 的兼容调用和单测使用。
      def build_components_from_items(issues)
        resolutions = Calculator.new(policy: @policy)
                                .compute_geometry_only(@items, @openings)
        opening_area_by_face = build_opening_area_map
        grouped = {}

        resolutions.each do |resolution|
          item = resolution[:item]
          # 模型根只用于「按组件」视图的总计，不是可同步的群组/组件行。
          # 根直属面的 path 为空，直接排除，避免把模型总计误作为一个组件上传。
          next if stable_component_path(item).empty?

          component_code = component_code_for(item)
          grouped[component_code] ||= {
            code: component_code,
            name: component_name_for(item),
            component_type: component_type_for(item),
            part_accumulator: {}
          }
          add_quantity_tag(grouped[component_code], item.tag)
          project_product_id = project_product_id_for(item)
          grouped[component_code][:project_product_id] ||= project_product_id if project_product_id

          if resolution[:method] == :area && item.kind == :face
            deduction = opening_area_by_face[item.face_occurrence_key]
            deduction = opening_area_by_face[item.face_id] if deduction.nil?
            area = [(item.qty_area || item.qty).to_f - (deduction || 0.0), 0.0].max
            # 不上传具体面：面积按组件、材质聚合为部品，保留算量结果但隐藏几何明细。
            add_part(
              grouped[component_code],
              item,
              resolution,
              quantity: area,
              unit: 'm2'
            )
          else
            add_part(grouped[component_code], item, resolution)
          end
        end

        grouped.values.map do |component|
          parts = component.delete(:part_accumulator).values.map do |part|
            part.merge(quantity: round_quantity(part[:quantity]))
          end.sort_by { |p| p[:code] }
          component[:parts] = parts
          component
        end.sort_by { |c| c[:code] }
      end

      def build_opening_area_map
        @openings.each_with_object({}) do |opening, memo|
          keys = Array(opening.host_face_keys).compact
          keys = Array(opening.host_face_ids) if keys.empty?
          keys.each do |face_key|
            memo[face_key] ||= 0.0
            memo[face_key] += opening.area.to_f
          end
        end
      end

      def add_part(component, item, resolution, quantity: nil, unit: nil)
        method = resolution[:method]
        unit = unit.to_s.strip
        if unit.empty?
          unit = resolution[:unit].to_s.strip
          unit = item.unit.to_s.strip if unit.empty?
        end
        unit = 'm2' if method == :area
        unit = 'm3' if method == :volume && unit == 'm³'
        name = item.su_material.to_s
        key = [component[:code], method, unit, name].join('|')
        code = code_with_prefix('p', key)
        component[:part_accumulator][code] ||= {
          code: code,
          name: name,
          quantity: 0.0,
          unit: unit
        }
        component[:part_accumulator][code][:quantity] += quantity.nil? ? quantity_for(item, method) : quantity.to_f
      end

      # quantity_tag 是组件级字段。无 hierarchy 的兼容路径可能把多个带标签的
      # item 聚合到同一个组件，因此将不同标签合并成一个复合标签字符串。
      def add_quantity_tag(component, value)
        tag = value.to_s.strip
        return if tag.empty?

        existing = component[:quantity_tag].to_s.strip
        tags = existing.split('+').map(&:strip).reject(&:empty?)
        tags.concat(tag.split('+').map(&:strip).reject(&:empty?))
        component[:quantity_tag] = tags.uniq.join('+') unless tags.empty?
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

      def component_code_for(item)
        ids = stable_component_path(item)
        return 'c-model-root' if ids.empty?

        code_with_prefix('c', ids.join('/'))
      end

      def component_name_for(item)
        name = item.component_path && item.component_path.last
        name = name.to_s.strip
        return name unless name.empty?

        stable_component_path(item).empty? ? '模型根' : '未命名组件'
      end

      # 项目产品关联按组件定义名持久化，而算量 item 只携带当前会话的组件实体路径。
      # 通过扫描层级中的完整 entity_id 路径 → definition_name 索引，取最内层容器的定义名。
      # 使用完整路径而非单一 entity_id，避免可复用 ComponentDefinition 的子实体 ID 冲突。
      def project_product_id_for(item)
        project_product_id_for_path(
          item.component_path_ids,
          fallback_names: item.component_path
        )
      end

      def build_definition_name_index(node, index = {}, parent_path = [])
        return index unless node.is_a?(Hash)

        entity_id = node[:entity_id] || node['entity_id']
        definition_name = node[:definition_name] || node['definition_name']
        explicit_path = node[:component_path_ids] || node['component_path_ids']
        current_path = if explicit_path.is_a?(Array)
                         explicit_path.map(&:to_i)
                       elsif entity_id.to_i.zero?
                         parent_path
                       else
                         parent_path + [entity_id.to_i]
                       end
        if entity_id && !definition_name.to_s.strip.empty?
          index[current_path.join('/')] = definition_name.to_s unless current_path.empty?
        end

        children = node[:children] || node['children'] || []
        Array(children).each do |child|
          build_definition_name_index(child, index, current_path)
        end
        index
      end

      def component_type_for(item)
        if stable_component_path(item).empty?
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

      def round_quantity(value)
        value.to_f.round(4)
      end

      def issue(code, message, extra = {})
        { code: code, message: message }.merge(extra)
      end
    end
  end
end
