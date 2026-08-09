# src/ui/dialog.rb
require 'timeout'
require 'thread'
require 'uri'

module SuTakeoff
  class FaceSelectionObserver < Sketchup::SelectionObserver
    def initialize(html_dialog)
      @html_dialog = html_dialog
    end

    def onSelectionBulkChange(selection)
      return unless @html_dialog.visible?
      entity = selection.first
      return unless entity.is_a?(Sketchup::Face)

      # 获取当前编辑路径（用于区分同名定义在不同实例中的面）
      model = Sketchup.active_model
      path_ids = (model.active_path || []).map(&:entityID)

      @html_dialog.execute_script("window.highlightFaceInUI(#{entity.entityID}, #{JSON.generate(path_ids)})")
    rescue
      # 静默失败，不干扰用户操作
    end

    def onSelectionCleared(selection)
      return unless @html_dialog.visible?
      @html_dialog.execute_script("window.clearFaceHighlight()")
    rescue
    end
  end

  class Dialog
    CLOUD_LOGIN_TIMEOUT_SECONDS = 15 unless const_defined?(:CLOUD_LOGIN_TIMEOUT_SECONDS)
    DEV_API_BASE_URL = 'http://127.0.0.1:8001'.freeze unless const_defined?(:DEV_API_BASE_URL)
    CLOUD_PUSH_VERSION_MAX_LENGTH = 64 unless const_defined?(:CLOUD_PUSH_VERSION_MAX_LENGTH)
    CLOUD_PUSH_UPDATE_CONTENT_MAX_LENGTH = 2000 unless const_defined?(:CLOUD_PUSH_UPDATE_CONTENT_MAX_LENGTH)

    def initialize
      @dialog = UI::HtmlDialog.new(
        dialog_title: dialog_title,
        preferences_key: 'su_takeoff_dialog',
        scrollable: true,
        resizable: true,
        width: 1000,
        height: 600,
        left: 200,
        top: 200,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      load_dialog_file
      @last_scan = nil

      @dialog.add_action_callback('scan_all') { |_ctx| require_login! && do_scan(selection_only: false) }
      @dialog.add_action_callback('scan_selected') { |_ctx| require_login! && do_scan(selection_only: true) }

      @dialog.add_action_callback('search_skus') { |_ctx, json| require_login! && search_skus(json) }
      @dialog.add_action_callback('set_component_sku') { |_ctx, json| require_login! && set_component_sku(json) }
      @dialog.add_action_callback('set_component_skus') { |_ctx, json| require_login! && set_component_skus(json) }
      @dialog.add_action_callback('get_settings') { |_ctx| require_login! && send_settings }

      @dialog.add_action_callback('locate_material') { |_ctx, su_name| require_login! && locate_material(su_name) }
      @dialog.add_action_callback('locate_face') { |_ctx, json| require_login! && locate_face(json) }
      @dialog.add_action_callback('locate_entity') { |_ctx, json| require_login! && locate_entity(json) }
      @dialog.add_action_callback('save_config') { |_ctx, json| require_login! && save_config(json) }

      # 标记系统 —— 为群组/组件分配/清除标记
      @dialog.add_action_callback('set_entity_tag') { |_ctx, json| require_login! && set_entity_tag(json) }
      @dialog.add_action_callback('set_entity_tags') { |_ctx, json| require_login! && set_entity_tags(json) }

      # 按需加载面详情（懒加载，减小初始 JSON 体积）
      @dialog.add_action_callback('get_faces') { |_ctx, json| require_login! && get_faces(json) }

      # 项目绑定与云端推送
      @dialog.add_action_callback('get_cloud_state') { |_ctx| send_cloud_state }
      @dialog.add_action_callback('cloud_login') { |_ctx, json| cloud_login(json) }
      @dialog.add_action_callback('cloud_logout') { |_ctx| cloud_logout }
      @dialog.add_action_callback('search_projects') { |_ctx, json| require_login! && search_projects(json) }
      @dialog.add_action_callback('save_project_binding') { |_ctx, json| save_project_binding(json) }
      @dialog.add_action_callback('cloud_push') { |_ctx, json| cloud_push(json) }

      @faces_cache = {}
      @cloud_busy = false
      @sku_search_pending = 0
      @project_search_pending = 0
      @cloud_ui_queue = Queue.new
      @cloud_login_request_id = nil
      @cloud_ui_pump_timer = nil
      @selection_model = nil
      @dialog.set_on_closed do
        clear_face_highlight
        detach_selection_observer
      end
    end

    def show
      @dialog.show
      ensure_selection_observer_for_active_model
      send_cloud_state(status_message: '正在校验登录状态...', force_login: true, checking: true)
      restore_cloud_session
    end

    private

    def dialog_title
      dev_mode? ? 'SU Takeoff Dev — 材料统计' : 'SU Takeoff — 材料统计'
    end

    def dev_mode?
      SuTakeoff.respond_to?(:dev_mode?) && SuTakeoff.dev_mode?
    end

    def load_dialog_file
      index_path = File.join(__dir__, 'index.html')
      return @dialog.set_file(index_path) unless dev_mode?

      stamp = Time.now.to_i.to_s
      base_href = "file://#{File.expand_path(__dir__).gsub(' ', '%20')}/"
      html = File.read(index_path)
      html = html.sub('<head>', "<head>\n  <base href=\"#{base_href}\">")
      html = html.gsub(/(src|href)="([^"]+\.(?:js|css))(?:\?v=[^"]*)?"/) do
        "#{Regexp.last_match(1)}=\"#{Regexp.last_match(2)}?v=#{stamp}\""
      end
      @dialog.set_html(html)
    rescue => e
      puts "[SuTakeoff] Warning: dev HtmlDialog load failed: #{e.message}"
      @dialog.set_file(File.join(__dir__, 'index.html'))
    end

    def require_login!
      ensure_selection_observer_for_active_model
      return true if auth_session.signed_in?

      send_cloud_state(
        error: { message: '请先登录平台账号后再使用插件功能' },
        force_login: true
      )
      false
    end

    def ensure_selection_observer_for_active_model
      model = Sketchup.active_model
      return if @selection_model.equal?(model) && @selection_observer

      detach_selection_observer
      @selection_observer = FaceSelectionObserver.new(@dialog)
      model.selection.add_observer(@selection_observer)
      @selection_model = model
    rescue => e
      puts "[SuTakeoff] selection observer rebind failed: #{e.message}"
    end

    def do_scan(selection_only:)
      clear_face_highlight  # 尽力清除，失败不阻塞
      begin
        scanner = Scanner.new
        result = scanner.scan(selection_only: selection_only)

        all_items = result[:items]

        @last_scan = {
          items:            all_items,
          openings:         result[:openings],
          hierarchy:        result[:hierarchy],
          colors:           scanner.material_colors,
          entity_contexts:  scanner.entity_contexts,
          model_identity:   Sketchup.active_model.object_id
        }

        send_workbench_state
      rescue => e
        msg = JSON.generate({ error: e.message, backtrace: e.backtrace.first(5) })
        @dialog.execute_script("window.renderWorkbenchError(#{msg})")
      end
    end

    def detach_selection_observer
      if @selection_model && @selection_observer
        @selection_model.selection.remove_observer(@selection_observer) rescue nil
      end
      @selection_model = nil
      @selection_observer = nil
    end

    def scan_for_active_model?
      @last_scan && @last_scan[:model_identity] == Sketchup.active_model.object_id
    rescue
      false
    end

    # 局部重扫：只重扫 entity_id 对应容器的子树，比全量 do_scan 快一到两个数量级。
    # 当 entity_contexts 中找不到该容器（首次扫描前、隐藏容器等）时回退全量扫描。
    def partial_rescan_entity(entity_id, component_path_ids, tag_name)
      component_path_ids = Array(component_path_ids).map(&:to_i)
      context_key = ScanItem.path_key(component_path_ids)
      contexts = @last_scan && @last_scan[:entity_contexts]
      ctx = contexts && contexts[context_key]
      return do_scan(selection_only: false) unless ctx

      # 定义内嵌实例会在多个外层 occurrence 中共享同一个实体对象。修改属性会影响
      # 所有 occurrence，此时必须全量重扫，不能只替换其中一条路径。
      duplicate_contexts = contexts.keys.count do |key|
        Array(contexts[key][:entity_path_ids]).last.to_i == entity_id.to_i
      end
      return do_scan(selection_only: false) if duplicate_contexts > 1

      # 先完整构造新子树；失败时保持 @last_scan 原样。
      scanner = Scanner.new
      result  = scanner.scan_entity(entity_id, ctx)
      return do_scan(selection_only: false) unless result

      in_subtree = lambda do |path|
        ids = Array(path).map(&:to_i)
        ids.first(component_path_ids.length) == component_path_ids
      end

      new_items = @last_scan[:items].reject { |it| in_subtree.call(it.component_path_ids) }
      new_items.concat(result[:items])
      new_openings = @last_scan[:openings].reject do |opening|
        in_subtree.call(opening.component_path_ids)
      end
      new_openings.concat(result[:openings])
      new_contexts = @last_scan[:entity_contexts].reject do |key, _value|
        in_subtree.call(key.to_s.split('/'))
      end
      new_contexts.merge!(scanner.entity_contexts)

      # 合并颜色与子容器上下文
      @last_scan[:colors].merge!(scanner.material_colors)
      @last_scan[:items] = new_items
      @last_scan[:openings] = new_openings
      @last_scan[:entity_contexts] = new_contexts
      update_hierarchy_node_tag(@last_scan[:hierarchy], component_path_ids, tag_name)

      send_workbench_state
    end

    # 递归更新层级树中 entity_id 对应节点的 tag 字段。
    def update_hierarchy_node_tag(node, component_path_ids, tag_name)
      return false unless node
      if Array(node[:component_path_ids]).map(&:to_i) == Array(component_path_ids).map(&:to_i)
        node[:tag] = (tag_name.nil? || tag_name.empty?) ? nil : tag_name
        return true
      end
      (node[:children] || []).any? do |child|
        update_hierarchy_node_tag(child, component_path_ids, tag_name)
      end
    end

    # Unified state push — 扫描后及任何影响结果的变更（设置保存、标记变更等）后调用。
    # Computes usages for all materials.
    # faces 数组从 geometry_usages 中剥除并缓存在服务端，前端通过 get_faces 按需请求。
    def send_workbench_state
      unless scan_for_active_model?
        @last_scan = nil if @last_scan
        return
      end
      begin
        data = WorkbenchPresenter.new(
          items: @last_scan[:items],
          openings: @last_scan[:openings],
          hierarchy: @last_scan[:hierarchy],
          colors: @last_scan[:colors],
          policy: PluginState.instance.takeoff_policy,
          tag_defs: PluginState.instance.config['tag_defs'] || {},
          component_sku: PluginState.instance.component_sku
        ).build(compact: true)

        # 剥除 faces 并缓存：避免初始 JSON 过大
        @faces_cache = {}
        data[:geometry_usages].each do |usage|
          key = "#{ScanItem.path_key(usage[:component_path_ids])}:#{usage[:su_material]}"
          @faces_cache[key] = usage.delete(:faces) || []
        end

        @dialog.execute_script("window.renderWorkbench(#{JSON.generate(data)})")
        # 工作台和云端状态是两个独立的数据通道。扫描/重扫后同步刷新
        # has_scan，确保按组件页的推送按钮不会继续使用旧的 false 状态。
        send_cloud_state
      rescue => e
        msg = JSON.generate({ error: e.message, backtrace: e.backtrace.first(5) })
        @dialog.execute_script("window.renderWorkbenchError(#{msg})")
      end
    end

    def get_faces(json)
      data = JSON.parse(json)
      component_path_ids = Array(data['component_path_ids']).map(&:to_i)
      component_path_ids = [data['entity_id'].to_i] if component_path_ids.empty? && data['entity_id'].to_i != 0
      key = "#{ScanItem.path_key(component_path_ids)}:#{data['su_material']}"
      faces = @faces_cache.fetch(key, [])
      result = { entity_id: data['entity_id'].to_i, component_path_ids: component_path_ids,
                 su_material: data['su_material'], faces: faces }
      @dialog.execute_script("window.receiveFaces(#{JSON.generate(result)})")
    rescue => e
      begin
        result = { entity_id: data['entity_id'].to_i,
                   component_path_ids: Array(data['component_path_ids']).map(&:to_i),
                   su_material: data['su_material'], faces: [] }
        @dialog.execute_script("window.receiveFaces(#{JSON.generate(result)})")
      rescue; end
    end

    def locate_material(su_name)
      model = Sketchup.active_model
      faces = []
      collect_faces_with_material(model.entities, su_name, faces)
      if faces.empty?
        UI.messagebox("未找到材质 \"#{su_name}\" 的面")
        return
      end
      model.selection.clear
      model.selection.add(faces)
      model.active_view.zoom(faces)
    end

    def collect_faces_with_material(entities, su_name, result)
      entities.each do |e|
        case e
        when Sketchup::Face
          result << e if (e.material&.name == su_name) || (e.back_material&.name == su_name)
        when Sketchup::ComponentInstance
          collect_faces_with_material(e.definition.entities, su_name, result)
        when Sketchup::Group
          collect_faces_with_material(e.entities, su_name, result)
        end
      end
    end

    def locate_face(json)
      data = JSON.parse(json)
      face_id = data['face_id'].to_i
      path_ids = data['path_ids'] || []

      model = Sketchup.active_model

      # 按 path_ids 导航到正确的组件实例
      if path_ids.any?
        ancestors = path_ids.map { |eid| model.find_entity_by_id(eid) }.compact
        model.active_path = ancestors if ancestors.any?
      else
        model.active_path = nil
      end

      # 从路径最内层容器开始搜索，而非从模型根
      search_root = if path_ids.any?
        inner = model.find_entity_by_id(path_ids.last)
        if inner&.respond_to?(:definition)
          inner.definition.entities
        elsif inner&.respond_to?(:entities)
          inner.entities
        end
      end
      search_root ||= model.entities

      face = find_face(search_root, face_id)
      unless face
        UI.messagebox("未找到面 ##{face_id}")
        return
      end

      # Restore previous highlight
      restore_highlight_face

      # 先推送 UI 高亮（在模型操作之前，确保不受模型异常影响）
      @dialog.execute_script("window.highlightFaceInUI(#{face_id}, #{JSON.generate(path_ids)})")

      # 使用 SketchUp 原生选择高亮，不改定义面材质；共享定义的其他实例不会被污染。
      model.selection.clear
      model.selection.add(face)
    end

    def restore_highlight_face
      @last_face = nil
      @last_front_mat = nil
      @last_back_mat = nil
    end

    def clear_face_highlight
      restore_highlight_face
      # 旧版本曾直接改面材质；每个模型只需做一次全量兼容清理。
      model = Sketchup.active_model
      model_identity = model.object_id
      return if @legacy_highlights_cleaned_model_identity == model_identity

      @restored_highlight_definitions = {}
      restore_all_highlight_faces(model.entities, model)
      @legacy_highlights_cleaned_model_identity = model_identity
    rescue
      @last_face = nil
      @last_front_mat = nil
      @last_back_mat = nil
    end

    def restore_all_highlight_faces(entities, model)
      @restored_highlight_definitions ||= {}
      entities.each do |e|
        if e.is_a?(Sketchup::Face) && e.material&.name == 'Takeoff 定位'
          dict = e.attribute_dictionary('su_takeoff_highlight')
          if dict
            front_name = dict['front']
            back_name = dict['back']
            e.material = front_name ? model.materials[front_name] : nil
            e.back_material = back_name ? model.materials[back_name] : nil
          else
            # 插件专用材质但恢复字典已丢失时，宁可清除旧定位色，避免永久污染模型。
            e.material = nil
            e.back_material = nil
          end
          e.delete_attribute('su_takeoff_highlight', 'front') rescue nil
          e.delete_attribute('su_takeoff_highlight', 'back') rescue nil
          e.attribute_dictionary_delete('su_takeoff_highlight') rescue nil
        elsif e.respond_to?(:definition)
          definition = e.definition
          key = definition.respond_to?(:persistent_id) ? definition.persistent_id : definition.object_id
          next if @restored_highlight_definitions[key]
          @restored_highlight_definitions[key] = true
          restore_all_highlight_faces(definition.entities, model)
        elsif e.respond_to?(:entities)
          restore_all_highlight_faces(e.entities, model)
        end
      end
    end

    def locate_entity(json)
      parsed = JSON.parse(json)
      if parsed.is_a?(Hash)
        eid = parsed['entity_id'].to_i
        path_ids = Array(parsed['component_path_ids']).map(&:to_i)
      else
        eid = parsed.to_i
        path_ids = [eid]
      end
      model = Sketchup.active_model
      entity = model.find_entity_by_id(eid)
      return unless entity
      ancestors = path_ids[0...-1].map { |id| model.find_entity_by_id(id) }.compact
      model.active_path = ancestors.empty? ? nil : ancestors
      model.selection.clear
      model.selection.add(entity)
      model.active_view.zoom(entity)
    rescue
      model.active_view.zoom_extents
    end

    def find_face(entities, target_id)
      entities.each do |e|
        return e if e.entityID == target_id
        next unless e.respond_to?(:definition) || e.respond_to?(:entities)

        children = e.respond_to?(:definition) ? e.definition.entities : e.entities
        result = find_face(children, target_id)
        return result if result
      end
      nil
    end

    # 模型视图「产品信息」列组件级选择：按组件定义名存项目产品关联（独立存储，不影响算量），
    # 保存后刷新工作台，使所有同定义名的组件行同步显示。
    def set_component_sku(json)
      data = JSON.parse(json)
      store = PluginState.instance.component_sku
      apply_component_sku_data(store, data)
      persist_component_skus(store)
    end

    def set_component_skus(json)
      data = JSON.parse(json)
      store = PluginState.instance.component_sku
      Array(data['items']).each { |item| apply_component_sku_data(store, item) if item.is_a?(Hash) }
      persist_component_skus(store)
    end

    def apply_component_sku_data(store, data)
      association_fields = %w[
        platform_sku_id platform_sku_code platform_sku_name
        project_product_id product_id catalog_code product_name project_product_code
      ]
      # 关联字段全空 = 前端「清除关联」
      if association_fields.all? { |k| data[k].to_s.strip.empty? }
        store.delete(data['definition_name'])
      elsif %w[project_product_id product_id catalog_code product_name project_product_code].any? do |key|
        !data[key].to_s.strip.empty?
      end
        store.set_project_product(
          data['definition_name'],
          project_product_id: data['project_product_id'],
          product_id: data['product_id'],
          catalog_code: data['catalog_code'],
          product_name: data['product_name'],
          project_product_code: data['project_product_code']
        )
      else
        store.set(data['definition_name'], data['platform_sku_id'],
                  data['platform_sku_code'], data['platform_sku_name'])
      end
    end

    def persist_component_skus(store)
      PluginState.instance.save_component_sku_to_model_dict
      store.save_json(PluginState.component_sku_path)
      if @last_scan
        payload = store.all.each_with_object({}) do |record, memo|
          memo[record.definition_name] = {
            sku_id: record.platform_sku_id,
            sku_code: record.platform_sku_code,
            sku_name: record.platform_sku_name,
            project_product_id: record.project_product_id,
            product_id: record.product_id,
            catalog_code: record.catalog_code,
            product_name: record.product_name,
            project_product_code: record.project_product_code
          }
        end
        @dialog.execute_script("window.updateComponentSkus(#{JSON.generate(payload)})")
      end
    end

    def send_settings
      state = PluginState.instance
      data = {
        component_category_units: state.config['component_category_units'] || [],
        tag_defs: state.config['tag_defs'] || {},
        heuristics_enabled: state.config.fetch('heuristics_enabled', true),
        heuristic_thresholds: state.config['heuristic_thresholds'] || {}
      }
      @dialog.execute_script("window.renderSettings(#{JSON.generate(data)})")
    end

    def save_config(json)
      data = JSON.parse(json)
      new_tag_defs = data['tag_defs'] || {}
      state = PluginState.instance
      previous_config = JSON.parse(JSON.generate(state.config))
      begin
        state.save_config(
          component_category_units: data['component_category_units'] || [],
          heuristics_enabled: data['heuristics_enabled'],
          heuristic_thresholds: data['heuristic_thresholds'],
          tag_defs: new_tag_defs
        )
        migrate_entity_tag_methods(new_tag_defs)
      rescue => original_error
        begin
          state.save_config(
            component_category_units: previous_config['component_category_units'] || [],
            layer_rules: previous_config['layer_rules'] || {},
            heuristics_enabled: previous_config['heuristics_enabled'],
            heuristic_thresholds: previous_config['heuristic_thresholds'] || {},
            tag_defs: previous_config['tag_defs'] || {}
          )
        rescue => rollback_error
          puts "[SuTakeoff] Warning: config rollback failed: #{rollback_error.message}"
        end
        raise original_error
      end
      @last_scan ? do_scan(selection_only: false) : send_settings
    end

    def migrate_entity_tag_methods(tag_defs)
      model = Sketchup.active_model
      visited_definitions = {}
      model.start_operation('更新算量标签定义', true)
      migrate_tags_in_entities(model.entities, tag_defs, visited_definitions)
      model.commit_operation
    rescue => e
      model.abort_operation rescue nil
      raise e
    end

    def migrate_tags_in_entities(entities, tag_defs, visited_definitions)
      entities.each do |entity|
        next unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)

        tag_name = entity.get_attribute('su_takeoff', 'tag') rescue nil
        if tag_name
          method = tag_defs[tag_name]
          if method.to_s.strip.empty?
            entity.delete_attribute('su_takeoff', 'tag') rescue nil
            entity.delete_attribute('su_takeoff', 'method') rescue nil
          else
            entity.set_attribute('su_takeoff', 'method', method)
          end
        end

        definition = entity.respond_to?(:definition) ? entity.definition : nil
        next unless definition
        definition_key = definition.respond_to?(:persistent_id) ? definition.persistent_id : definition.object_id
        next if visited_definitions[definition_key]
        visited_definitions[definition_key] = true
        migrate_tags_in_entities(definition.entities, tag_defs, visited_definitions)
      end
    end

    # P2 新增：把红行确认结果写回 entity 的 AttributeDictionary。
    # 入参 JSON：
    #   { face_ids: [123, 456], path_ids: [[101], [101]], method: 'length' }
    # 行为：
    #   - 对每对 (face_id, path_ids) 通过 path_ids 导航到正确容器后定位 entity
    #   - 写 entity.set_attribute('su_takeoff', 'method', method)
    #   - method == 'clear' 时删除该字段
    #   - 完成后重跑 Calculator + 推前端，红行升级为白行（confidence: explicit, source: attr）
    def set_entity_tag(json)
      data = JSON.parse(json)
      entity_id = data['entity_id'].to_i
      component_path_ids = Array(data['component_path_ids']).map(&:to_i)
      component_path_ids = [entity_id] if component_path_ids.empty?
      tag_name = data['tag_name']  # nil / '' 表示清除

      model = Sketchup.active_model
      entity = model.find_entity_by_id(entity_id)
      return unless entity
      return unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)

      model.start_operation('设置标记', true)
      operation_open = true
      if tag_name.nil? || tag_name.empty?
        entity.delete_attribute('su_takeoff', 'tag') rescue nil
        entity.delete_attribute('su_takeoff', 'method') rescue nil
        entity.delete_attribute('su_takeoff', 'material') rescue nil
      else
        tag_defs = PluginState.instance.config['tag_defs'] || {}
        method = tag_defs[tag_name]
        entity.set_attribute('su_takeoff', 'tag', tag_name)
        if method
          entity.set_attribute('su_takeoff', 'method', method)
        else
          entity.delete_attribute('su_takeoff', 'method') rescue nil
        end
      end
      model.commit_operation
      operation_open = false

      partial_rescan_entity(entity_id, component_path_ids, tag_name)
    rescue => e
      model.abort_operation rescue nil if operation_open
      msg = JSON.generate({ error: e.message, backtrace: e.backtrace.first(5) })
      @dialog.execute_script("window.renderWorkbenchError(#{msg})")
    end

    def set_entity_tags(json)
      data = JSON.parse(json)
      entries = Array(data['entities'])
      tag_name = data['tag_name']
      model = Sketchup.active_model
      tag_defs = PluginState.instance.config['tag_defs'] || {}
      method = tag_defs[tag_name]

      model.start_operation('批量设置标记', true)
      operation_open = true
      entries.each do |entry|
        next unless entry.is_a?(Hash)
        entity = model.find_entity_by_id(entry['entity_id'].to_i)
        next unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        if tag_name.to_s.empty?
          entity.delete_attribute('su_takeoff', 'tag') rescue nil
          entity.delete_attribute('su_takeoff', 'method') rescue nil
          entity.delete_attribute('su_takeoff', 'material') rescue nil
        else
          entity.set_attribute('su_takeoff', 'tag', tag_name)
          entity.set_attribute('su_takeoff', 'method', method) if method
        end
      end
      model.commit_operation
      operation_open = false
      do_scan(selection_only: false)
    rescue => e
      model.abort_operation rescue nil if operation_open
      msg = JSON.generate({ error: e.message, backtrace: e.backtrace.first(5) })
      @dialog.execute_script("window.renderWorkbenchError(#{msg})")
    end

    def send_cloud_state(extra = {})
      extra = normalize_cloud_state_extra(extra)
      data = {
        plugin_version: SuTakeoff::VERSION,
        api_configured: api_configured?,
        api_environment: api_config['environment'],
        api_base_url: api_config['base_url'],
        auth: auth_state_hash,
        binding: project_binding_hash,
        has_scan: scan_for_active_model?,
        busy: @cloud_busy
      }.merge(extra)
      # 会话恢复进行中：除显式覆盖外，所有状态都标记 checking，
      # 前端只显示「正在校验」加载面板，不渲染登录表单
      data[:checking] = true if @session_restoring && !data.key?(:checking)
      json = JSON.generate(data)
      @dialog.execute_script("window.renderCloudState && window.renderCloudState(#{json}); window.renderLoginState && window.renderLoginState(#{json});")
    rescue => e
      # execute_script 自身失败时不能再经 send_cloud_error → send_cloud_state 递归。
      puts "[SuTakeoff] send_cloud_state failed: #{e.class}: #{e.message}"
      nil
    end

    def cloud_login(json)
      data = JSON.parse(json)
      return send_cloud_error_message('API Base URL 未配置') unless api_configured?
      return send_cloud_error_message('请输入账号') if data['username'].to_s.strip.empty?

      username = data['username'].to_s
      password = data['password'].to_s
      tenant_id = data['tenant_id']
      return send_cloud_error_message('请输入密码', login_username: username) if password.empty?

      @cloud_busy = true
      @cloud_login_request_id = next_cloud_request_id
      request_id = @cloud_login_request_id
      send_cloud_state(
        status_message: '正在登录...',
        login_username: username
      )
      ensure_cloud_ui_pump
      schedule_cloud_login_timeout(request_id, username)
      session = build_auth_session
      Thread.new do
        begin
          state = Timeout.timeout(CLOUD_LOGIN_TIMEOUT_SECONDS) do
            session.login(username: username, password: password, tenant_id: tenant_id)
          end
          run_on_ui_thread do
            if active_cloud_login_request?(request_id)
              @auth_session = session
              @cloud_busy = false
              @cloud_login_request_id = nil
              if state[:status] == :tenant_selection_required
                send_cloud_state(
                  status_message: '请选择租户后重新登录',
                  login_username: username,
                  force_login: true
                )
              else
                save_last_account(username)
                send_cloud_state(status_message: '登录状态已更新', clear_password: true)
              end
            end
          end
        rescue Timeout::Error
          run_on_ui_thread do
            finish_cloud_login_error(request_id, '登录超时，请检查网络连接后重试', username)
          end
        rescue => e
          run_on_ui_thread do
            finish_cloud_login_error(request_id, e, username)
          end
        end
      end
    rescue => e
      @cloud_busy = false
      @cloud_login_request_id = nil
      send_cloud_error(e)
    end

    def cloud_logout
      @cloud_busy = true
      send_cloud_state(status_message: '正在退出登录...', logging_out: true)
      ensure_cloud_ui_pump
      Thread.new do
        auth_session.logout
        run_on_ui_thread do
          @cloud_busy = false
          clear_last_account
          send_cloud_state(status_message: '已退出登录')
        end
      rescue => e
        run_on_ui_thread do
          @cloud_busy = false
          send_cloud_error(e)
        end
      end
    end

    # 项目绑定页的项目选择：从平台项目接口检索当前账号可访问的项目。
    # 结果通过独立回调返回，避免把网络请求阻塞在 HtmlDialog UI 线程。
    def search_projects(json)
      data = JSON.parse(json.to_s.empty? ? '{}' : json)
      keyword = data['keyword'].to_s.strip
      req_id = data['req_id']
      @project_search_pending = @project_search_pending.to_i + 1
      ensure_cloud_ui_pump
      Thread.new do
        begin
          result = auth_session.with_access_token_retry do |token|
            api_client.projects(
              access_token: token,
              keyword: keyword.empty? ? nil : keyword
            )
          end
          items = normalize_projects(result)
          total = result.is_a?(Hash) ? (result['total'] || items.size) : items.size
          payload = JSON.generate({ req_id: req_id, total: total, items: items })
          run_on_ui_thread do
            @project_search_pending = [@project_search_pending.to_i - 1, 0].max
            @dialog.execute_script("window.receiveProjectResults(#{payload})") rescue nil
          end
        rescue => e
          err = JSON.generate({ req_id: req_id, error: login_error_message(e) })
          run_on_ui_thread do
            @project_search_pending = [@project_search_pending.to_i - 1, 0].max
            @dialog.execute_script("window.receiveProjectResults(#{err})") rescue nil
          end
        end
      end
    end

    def search_skus(json)
      data = JSON.parse(json)
      keyword = data['keyword'].to_s
      req_id = data['req_id']
      page_size = [[data['page_size'].to_i, 1].max, 100].min
      binding = Api::ProjectBinding.load(Sketchup.active_model)
      unless binding.valid_project?
        error = Api::ApiError.new('请先在项目绑定页保存平台项目绑定', code: 'PROJECT_BINDING_REQUIRED')
        payload = JSON.generate({ req_id: req_id, error: login_error_message(error) })
        @dialog.execute_script("window.receiveSkuResults(#{payload})")
        return
      end
      project_code = binding.project_code
      project_id = binding.project_id.to_s.strip
      @sku_search_pending = @sku_search_pending.to_i + 1
      ensure_cloud_ui_pump
      Thread.new do
        begin
          result = auth_session.with_access_token_retry do |token|
            project = if project_id.empty?
                        project_result = api_client.projects(
                          access_token: token,
                          keyword: project_code
                        )
                        find_bound_project(project_result, project_code)
                      else
                        { 'id' => project_id }
                      end
            unless project && project['id']
              raise Api::ApiError.new(
                '未找到对应的平台项目，请检查项目编号',
                status: 404,
                code: 'PROJECT_NOT_FOUND',
                retryable: false
              )
            end

            api_client.project_products(
              access_token: token,
              project_id: project['id'],
              keyword: keyword.empty? ? nil : keyword,
              page_size: page_size
            )
          end
          items = normalize_project_products(result)
          total = result.is_a?(Hash) ? (result['total'] || items.size) : items.size
          payload = JSON.generate({ req_id: req_id, total: total, items: items })
          run_on_ui_thread do
            @sku_search_pending = [@sku_search_pending.to_i - 1, 0].max
            @dialog.execute_script("window.receiveSkuResults(#{payload})") rescue nil
          end
        rescue => e
          err = JSON.generate({ req_id: req_id, error: login_error_message(e) })
          run_on_ui_thread do
            @sku_search_pending = [@sku_search_pending.to_i - 1, 0].max
            @dialog.execute_script("window.receiveSkuResults(#{err})") rescue nil
          end
        end
      end
    end

    def normalize_projects(result)
      projects = if result.is_a?(Hash)
                   raw = result['items'] || result['data'] || result['results'] || []
                   raw.is_a?(Hash) ? Array(raw['items']) : Array(raw)
                 else
                   Array(result)
                 end
      projects.each_with_object([]) do |item, normalized|
        next unless item.is_a?(Hash)

        project_id = item['id'] || item['project_id']
        project_code = item['code'] || item['project_code'] || item['number']
        project_name = item['name'] || item['project_name']
        next if project_id.to_s.strip.empty? && project_code.to_s.strip.empty? && project_name.to_s.strip.empty?

        normalized << {
          'id' => project_id,
          'code' => project_code,
          'name' => project_name,
          'status' => item['status']
        }
      end
    end

    def find_bound_project(result, project_code, project_id = nil)
      projects = normalize_projects(result)
      code = project_code.to_s.strip
      id = project_id.to_s.strip
      projects.find do |project|
        next false unless project.is_a?(Hash)
        id.empty? ? project['code'].to_s.strip == code : project['id'].to_s.strip == id
      end
    end

    def normalize_project_products(result)
      products = result.is_a?(Hash) ? Array(result['items']) : Array(result)
      products.each_with_object([]) do |item, normalized|
        next unless item.is_a?(Hash)

        catalog_code = item['catalog_code'].to_s.strip
        project_product_code = item['project_product_code'].to_s.strip
        normalized << {
          'project_product_id' => item['id'],
          'product_id' => item['product_id'],
          'catalog_code' => catalog_code.empty? ? nil : catalog_code,
          'product_name' => item['product_name'],
          'project_product_code' => project_product_code.empty? ? nil : project_product_code,
          # 前端下拉沿用 code/name 字段，但 code 必须显示项目自定义编号，
          # 不能回退到产品目录编号（catalog_code）。
          'code' => project_product_code.empty? ? catalog_code : project_product_code,
          'name' => item['product_name'],
          'category_name' => item['category_name'],
          'brand' => { 'name' => item['brand_name'] },
          'tag_names' => item['tag_names'] || []
        }
      end
    end

    def save_project_binding(json)
      return unless require_login!

      data = JSON.parse(json)
      project_id = data['project_id'].to_s.strip
      project_code = data['project_code'].to_s.strip
      project_name = data['project_name'].to_s.strip
      return send_cloud_error_message('请选择一个平台项目') if project_id.empty?
      return send_cloud_error_message('所选项目缺少项目编号或项目名称') if project_code.empty? || project_name.empty?

      binding = Api::ProjectBinding.load(Sketchup.active_model)
      binding.update_project!(
        project_id: project_id,
        project_code: project_code,
        project_name: project_name
      )
      send_cloud_state(status_message: '项目绑定已保存')
    rescue => e
      send_cloud_error(e)
    end

    def cloud_push(json = nil)
      puts '[SuTakeoff] cloud_push: received confirmation'
      return unless require_login!

      return send_cloud_error_message('请先扫描当前模型') unless scan_for_active_model?
      return send_cloud_error_message('API Base URL 未配置') unless api_configured?
      return send_cloud_error_message('请先登录平台账号') unless auth_session.signed_in?
      return send_cloud_error_message('当前账号缺少 quantity:ingest 权限') unless auth_session.can_push?
      return send_cloud_error_message('已有推送任务正在执行') if @cloud_busy

      push_metadata = parse_cloud_push_metadata(json)
      unless push_metadata[:issues].empty?
        send_cloud_state(sync_result: { success: false, issues: push_metadata[:issues] })
        return
      end

      binding = Api::ProjectBinding.load(Sketchup.active_model)
      unless binding.valid_project?
        send_cloud_state(sync_result: {
                           success: false,
                           issues: [{ code: :missing_project_binding,
                                      message: '请先在项目绑定页选择并保存平台项目' }]
                         })
        return
      end
      if push_metadata[:visible_component_paths]&.empty?
        send_cloud_state(sync_result: {
                           success: false,
                           issues: [{ code: :empty_visible_components,
                                      message: '当前视图没有可推送的组件，请清除搜索条件或重新扫描模型' }]
                         })
        return
      end

      build = Api::QuantityPayloadBuilder.new(
        items: @last_scan[:items],
        openings: @last_scan[:openings],
        policy: PluginState.instance.takeoff_policy,
        binding: binding,
        component_sku: PluginState.instance.component_sku,
        hierarchy: @last_scan[:hierarchy],
        model_version_no: push_metadata[:model_version_no],
        update_content: push_metadata[:update_content],
        visible_component_paths: push_metadata[:visible_component_paths],
        designer_account: auth_session.account
      ).build

      unless build.issues.empty?
        puts "[SuTakeoff] cloud_push: preflight failed #{build.issues.map { |issue| issue[:code] }.join(',')}"
        send_cloud_state(sync_result: { success: false, issues: build.issues })
        return
      end

      component_count = Array(build.payload[:components]).length
      payload_bytes = JSON.generate(build.payload).bytesize
      puts "[SuTakeoff] cloud_push: prepared components=#{component_count} bytes=#{payload_bytes}"

      @cloud_busy = true
      send_cloud_state(status_message: '正在上传算量数据...')
      ensure_cloud_ui_pump
      sync_policy = PluginState.instance.takeoff_policy
      sync_component_sku = PluginState.instance.component_sku
      sync_hierarchy = @last_scan[:hierarchy]
      sync_designer_account = auth_session.account

      Thread.new do
        puts "[SuTakeoff] cloud_push: POST #{api_config['base_url']}#{Api::ApiClient::QUANTITIES_PATH}"
        outbox = Api::SyncOutbox.new(dir: cloud_outbox_dir)
        sync = Api::QuantitySyncService.new(
          api_client: api_client,
          auth_session: auth_session,
          outbox: outbox,
          binding: binding,
          policy: sync_policy,
          persist_success: false,
          component_sku: sync_component_sku,
          hierarchy: sync_hierarchy,
          designer_account: sync_designer_account
        )
        result = sync.push_built(build)
        puts "[SuTakeoff] cloud_push: finished success=#{result.success?} attempts=#{result.attempts} code=#{result.error&.code}"
        run_on_ui_thread { finish_cloud_push(binding, build, result) }
      rescue => e
        puts "[SuTakeoff] cloud_push thread failed: #{e.class}: #{e.message}"
        puts e.backtrace.first(5)
        run_on_ui_thread do
          @cloud_busy = false
          send_cloud_error(e)
        end
      end
    rescue => e
      puts "[SuTakeoff] cloud_push failed: #{e.class}: #{e.message}"
      puts e.backtrace.first(5)
      @cloud_busy = false
      send_cloud_error(e)
    end

    def finish_cloud_push(binding, build, result)
      @cloud_busy = false
      if result.success?
        response = result.response || {}
        binding.mark_synced!(
          payload_hash: build.payload_hash,
          idempotency_key: build.payload[:idempotency_key],
          sheet_id: response['sheet_id'],
          model_version_id: response['model_version_id']
        )
      end
      send_cloud_state(sync_result: serialize_sync_result(result))
    rescue => e
      send_cloud_error(e)
    end

    def serialize_sync_result(result)
      {
        success: result.success?,
        attempts: result.attempts,
        issues: result.issues || [],
        response: result.response,
        error: result.error && {
          status: result.error.status,
          code: result.error.code,
          message: result.error.message,
          retryable: result.error.retryable?
        },
        outbox_saved: !!result.outbox_record,
        payload_hash: result.payload_hash,
        idempotency_key: result.payload && result.payload[:idempotency_key],
        model_version_no: result.payload && result.payload[:model_version_no],
        update_content: result.payload && result.payload[:update_content]
      }
    end

    def parse_cloud_push_metadata(json)
      data = if json.to_s.strip.empty?
               {}
             else
               JSON.parse(json)
             end
      data = {} unless data.is_a?(Hash)

      model_version_no = data['model_version_no'].to_s.strip
      update_content = data['update_content'].to_s.strip
      visible_component_paths = if data.key?('visible_component_paths')
                                  normalize_visible_component_paths(data['visible_component_paths'])
                                end
      issues = []
      issues << { code: :missing_model_version_no, message: '请填写版本号' } if model_version_no.empty?
      issues << { code: :model_version_no_too_long, message: "版本号不能超过 #{CLOUD_PUSH_VERSION_MAX_LENGTH} 个字符" } if model_version_no.length > CLOUD_PUSH_VERSION_MAX_LENGTH
      issues << { code: :missing_update_content, message: '请填写更新内容' } if update_content.empty?
      issues << { code: :update_content_too_long, message: "更新内容不能超过 #{CLOUD_PUSH_UPDATE_CONTENT_MAX_LENGTH} 个字符" } if update_content.length > CLOUD_PUSH_UPDATE_CONTENT_MAX_LENGTH

      {
        model_version_no: model_version_no,
        update_content: update_content,
        visible_component_paths: visible_component_paths,
        issues: issues
      }
    rescue JSON::ParserError
      {
        model_version_no: '',
        update_content: '',
        visible_component_paths: nil,
        issues: [{ code: :invalid_push_metadata, message: '推送版本信息格式错误，请重新填写' }]
      }
    end

    def normalize_visible_component_paths(paths)
      return [] unless paths.is_a?(Array)

      paths.each_with_object([]) do |raw_path, result|
        next unless raw_path.is_a?(Array)

        ids = raw_path.each_with_object([]) do |raw_id, memo|
          begin
            id = Integer(raw_id)
            memo << id if id.positive?
          rescue ArgumentError, TypeError
            # 忽略前端异常值，真正的节点仍由 hierarchy 再次校验。
          end
        end
        result << ids unless ids.empty?
      end.uniq
    end

    def auth_state_hash
      return { status: 'unconfigured', can_push: false } unless api_configured?

      state = auth_session.state
      state[:status] = state[:status].to_s
      if auth_session.last_error
        state[:last_error] = {
          code: auth_session.last_error.code,
          message: login_error_message(auth_session.last_error)
        }
      end
      state
    rescue => e
      { status: 'error', can_push: false, last_error: { message: login_error_message(e) } }
    end

    def project_binding_hash
      Api::ProjectBinding.load(Sketchup.active_model).to_h
    rescue
      {}
    end

    def auth_session
      @auth_session ||= build_auth_session
    end

    def build_auth_session
      Api::AuthSession.new(
        api_client: api_client,
        credential_store: Api::CredentialStore.default(namespace: credential_namespace)
      )
    end

    def credential_namespace
      env = api_config['environment'].to_s.strip
      host = begin
        URI.parse(api_config['base_url'].to_s).host
      rescue
        nil
      end
      suffix = [env.empty? ? 'production' : env, host.to_s].reject(&:empty?).join(':')
      "su_takeoff_api:#{suffix}"
    end

    def restore_cloud_session
      return send_cloud_state(status_message: '请先配置 API 地址', force_login: true) unless api_configured?

      account = last_account.to_s.strip
      if account.empty?
        send_cloud_state(status_message: '请先登录平台账号', force_login: true)
        return
      end

      @cloud_busy = true
      @session_restoring = true
      send_cloud_state(status_message: '正在恢复登录状态...', force_login: true, checking: true)
      ensure_cloud_ui_pump
      Thread.new do
        begin
          auth_session.restore(username: account)
          run_on_ui_thread do
            @cloud_busy = false
            @session_restoring = false
            message = auth_session.signed_in? ? '登录状态已恢复' : '请先登录平台账号'
            send_cloud_state(status_message: message, force_login: !auth_session.signed_in?)
          end
        rescue => e
          run_on_ui_thread do
            @cloud_busy = false
            @session_restoring = false
            send_cloud_error(e, force_login: true)
          end
        end
      end
    rescue => e
      @cloud_busy = false
      @session_restoring = false
      send_cloud_error(e)
    end

    def save_last_account(username)
      Sketchup.write_default('SuTakeoff', 'api_last_account', username.to_s.strip)
    rescue
      @last_account_fallback = username.to_s.strip
    end

    def last_account
      Sketchup.read_default('SuTakeoff', 'api_last_account', '') rescue @last_account_fallback
    end

    def clear_last_account
      Sketchup.write_default('SuTakeoff', 'api_last_account', '')
    rescue
      @last_account_fallback = ''
    end

    def api_client
      cfg = api_config
      Api::ApiClient.new(
        base_url: cfg['base_url'],
        environment: cfg['environment'] || 'production'
      )
    end

    def api_config
      @api_config ||= begin
        path = File.join(PLUGIN_DIR, 'data', 'api_config.json')
        config = if File.exist?(path)
                   parsed = JSON.parse(File.read(path)) rescue nil
                   parsed.is_a?(Hash) ? parsed : {}
                 else
                   {}
                 end
        if dev_mode?
          development_base_url = config['development_base_url'].to_s.strip
          config.merge(
            'environment' => 'development',
            'base_url' => development_base_url.empty? ? DEV_API_BASE_URL : development_base_url
          )
        else
          config
        end
      end
    end

    def api_configured?
      !api_config['base_url'].to_s.strip.empty?
    end

    def cloud_outbox_dir
      File.join(PLUGIN_DIR, 'data', 'sync_outbox')
    end

    def run_on_ui_thread(&block)
      if defined?(UI) && UI.respond_to?(:start_timer)
        @cloud_ui_queue ||= Queue.new
        @cloud_ui_queue << block
      else
        block.call
      end
    end

    def ensure_cloud_ui_pump
      return unless defined?(UI) && UI.respond_to?(:start_timer)
      return if @cloud_ui_pump_timer

      @cloud_ui_queue ||= Queue.new
      @cloud_ui_pump_timer = UI.start_timer(0.2, true) do
        drain_cloud_ui_queue
        next if @cloud_busy || @sku_search_pending.to_i > 0 || @project_search_pending.to_i > 0 || !@cloud_ui_queue.empty?

        UI.stop_timer(@cloud_ui_pump_timer) rescue nil
        @cloud_ui_pump_timer = nil
      end
    end

    def drain_cloud_ui_queue
      loop do
        callback = @cloud_ui_queue.pop(true)
        callback.call
      end
    rescue ThreadError
      nil
    rescue => e
      puts "[SuTakeoff] Warning: cloud UI callback failed: #{e.message}"
    end

    def next_cloud_request_id
      @cloud_request_seq = (@cloud_request_seq || 0) + 1
    end

    def active_cloud_login_request?(request_id)
      @cloud_busy && @cloud_login_request_id == request_id
    end

    def schedule_cloud_login_timeout(request_id, username)
      return unless defined?(UI) && UI.respond_to?(:start_timer)

      UI.start_timer(CLOUD_LOGIN_TIMEOUT_SECONDS, false) do
        finish_cloud_login_error(request_id, '登录超时，请检查网络连接后重试', username)
      end
    end

    def finish_cloud_login_error(request_id, error_or_message, username)
      return unless active_cloud_login_request?(request_id)

      @cloud_busy = false
      @cloud_login_request_id = nil
      send_cloud_error_message(
        login_error_message(error_or_message),
        login_username: username,
        force_login: true
      )
    end

    def send_cloud_error(error, extra = {})
      send_cloud_error_message(login_error_message(error), extra)
    end

    def send_cloud_error_message(message, extra = {})
      send_cloud_state({ error: { message: login_error_message(message) } }.merge(extra))
    end

    def login_error_message(error_or_message)
      if defined?(Api::ErrorTranslator)
        Api::ErrorTranslator.login_message(error_or_message)
      else
        error_or_message.respond_to?(:message) ? error_or_message.message.to_s : error_or_message.to_s
      end
    end

    def normalize_cloud_state_extra(extra)
      normalized = extra.dup
      error = normalized[:error] || normalized['error']
      if error.is_a?(Hash)
        key = error.key?(:message) ? :message : 'message'
        normalized_error = error.dup
        normalized_error[key] = login_error_message(normalized_error[key]) if normalized_error[key]
        normalized[:error] = normalized_error
        normalized.delete('error')
      elsif error
        normalized[:error] = { message: login_error_message(error) }
        normalized.delete('error')
      end
      normalized
    end

  end
end
