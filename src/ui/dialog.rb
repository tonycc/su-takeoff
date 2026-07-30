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

      @dialog.add_action_callback('get_mappings') { |_ctx| require_login! && send_mappings }
      @dialog.add_action_callback('save_mapping') { |_ctx, json| require_login! && save_mapping(json) }
      @dialog.add_action_callback('delete_mapping') { |_ctx, su_name| require_login! && delete_mapping(su_name) }
      @dialog.add_action_callback('import_csv') { |_ctx| require_login! && import_csv_dialog }
      @dialog.add_action_callback('export_csv') { |_ctx| require_login! && export_csv_dialog }
      @dialog.add_action_callback('get_settings') { |_ctx| require_login! && send_settings }

      @dialog.add_action_callback('locate_material') { |_ctx, su_name| require_login! && locate_material(su_name) }
      @dialog.add_action_callback('locate_face') { |_ctx, json| require_login! && locate_face(json) }
      @dialog.add_action_callback('locate_entity') { |_ctx, json| require_login! && locate_entity(json) }
      @dialog.add_action_callback('ignore_material') { |_ctx, name| require_login! && ignore_material(name) }
      @dialog.add_action_callback('unignore') { |_ctx, name| require_login! && unignore(name) }
      @dialog.add_action_callback('clear_ignored') { |_ctx| require_login! && clear_ignored }
      @dialog.add_action_callback('save_config') { |_ctx, json| require_login! && save_config(json) }

      @dialog.add_action_callback('get_component_mappings') { |_ctx| require_login! && send_component_mappings }
      @dialog.add_action_callback('save_component_mapping') { |_ctx, json| require_login! && save_component_mapping(json) }
      @dialog.add_action_callback('delete_component_mapping') { |_ctx, def_name| require_login! && delete_component_mapping(def_name) }

      # 标记系统 —— 为群组/组件分配/清除标记
      @dialog.add_action_callback('set_entity_tag') { |_ctx, json| require_login! && set_entity_tag(json) }

      # 按需加载面详情（懒加载，减小初始 JSON 体积）
      @dialog.add_action_callback('get_faces') { |_ctx, json| require_login! && get_faces(json) }

      # 云端同步
      @dialog.add_action_callback('get_cloud_state') { |_ctx| send_cloud_state }
      @dialog.add_action_callback('cloud_login') { |_ctx, json| cloud_login(json) }
      @dialog.add_action_callback('cloud_logout') { |_ctx| cloud_logout }
      @dialog.add_action_callback('save_project_binding') { |_ctx, json| save_project_binding(json) }
      @dialog.add_action_callback('cloud_push') { |_ctx| cloud_push }

      @faces_cache = {}
      @cloud_busy = false
      @cloud_ui_queue = Queue.new
      @cloud_login_request_id = nil
      @cloud_ui_pump_timer = nil
    end

    def show
      @dialog.show
      model = Sketchup.active_model
      @selection_observer = FaceSelectionObserver.new(@dialog)
      model.selection.add_observer(@selection_observer)
      send_cloud_state(status_message: '正在校验登录状态...', force_login: true)
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
      return true if auth_session.signed_in?

      send_cloud_state(
        error: { message: '请先登录平台账号后再使用插件功能' },
        force_login: true
      )
      false
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
          entity_contexts:  scanner.entity_contexts
        }

        send_workbench_state
      rescue => e
        msg = JSON.generate({ error: e.message, backtrace: e.backtrace.first(5) })
        @dialog.execute_script("window.renderWorkbenchError(#{msg})")
      end
    end

    # 局部重扫：只重扫 entity_id 对应容器的子树，比全量 do_scan 快一到两个数量级。
    # 当 entity_contexts 中找不到该容器（首次扫描前、隐藏容器等）时回退全量扫描。
    def partial_rescan_entity(entity_id, tag_name)
      ctx = @last_scan && @last_scan[:entity_contexts]&.fetch(entity_id, nil)
      return do_scan(selection_only: false) unless ctx

      # 剔除属于该容器子树的旧 item（comp_path_ids 中含 entity_id 的全部条目）
      @last_scan[:items].reject! { |it| it.component_path_ids.include?(entity_id) }

      # 仅重扫该容器
      scanner = Scanner.new
      result  = scanner.scan_entity(entity_id, ctx)
      return do_scan(selection_only: false) unless result

      # 合并颜色与子容器上下文
      @last_scan[:colors].merge!(scanner.material_colors)
      @last_scan[:entity_contexts].merge!(scanner.entity_contexts)

      # 洞口去重合并：以新扫描中出现的透明面 id 为准
      new_op_ids = result[:openings].map(&:entity_id).to_set
      @last_scan[:openings].reject! { |op| new_op_ids.include?(op.entity_id) }
      @last_scan[:openings].concat(result[:openings])

      # 合并新 item，并更新层级树节点的 tag 字段
      @last_scan[:items].concat(result[:items])
      update_hierarchy_node_tag(@last_scan[:hierarchy], entity_id, tag_name)

      send_workbench_state
    end

    # 递归更新层级树中 entity_id 对应节点的 tag 字段。
    def update_hierarchy_node_tag(node, entity_id, tag_name)
      return false unless node
      if node[:entity_id] == entity_id
        node[:tag] = (tag_name.nil? || tag_name.empty?) ? nil : tag_name
        return true
      end
      (node[:children] || []).any? { |child| update_hierarchy_node_tag(child, entity_id, tag_name) }
    end

    # Unified state push — called after scan and after any mapping/ignored change.
    # Computes usages for all mapped materials; unmapped are returned for editing UI.
    # faces 数组从 geometry_usages 中剥除并缓存在服务端，前端通过 get_faces 按需请求。
    def send_workbench_state
      return unless @last_scan
      begin
        data = WorkbenchPresenter.new(
          items: @last_scan[:items],
          openings: @last_scan[:openings],
          hierarchy: @last_scan[:hierarchy],
          colors: @last_scan[:colors],
          mapping: PluginState.instance.mapping,
          component_mapping: PluginState.instance.component_mapping,
          policy: PluginState.instance.takeoff_policy,
          ignored: PluginState.instance.ignored,
          tag_defs: PluginState.instance.config['tag_defs'] || {}
        ).build

        # 剥除 faces 并缓存：避免初始 JSON 过大
        @faces_cache = {}
        data[:geometry_usages].each do |usage|
          key = "#{usage[:entity_id]}:#{usage[:su_material]}"
          @faces_cache[key] = usage.delete(:faces) || []
        end

        @dialog.execute_script("window.renderWorkbench(#{JSON.generate(data)})")
      rescue => e
        msg = JSON.generate({ error: e.message, backtrace: e.backtrace.first(5) })
        @dialog.execute_script("window.renderWorkbenchError(#{msg})")
      end
    end

    def get_faces(json)
      data = JSON.parse(json)
      key = "#{data['entity_id']}:#{data['su_material']}"
      faces = @faces_cache.fetch(key, [])
      result = { entity_id: data['entity_id'].to_i, su_material: data['su_material'], faces: faces }
      @dialog.execute_script("window.receiveFaces(#{JSON.generate(result)})")
    rescue => e
      begin
        result = { entity_id: data['entity_id'].to_i, su_material: data['su_material'], faces: [] }
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

      @last_face = face
      @last_front_mat = face.material
      @last_back_mat = face.back_material

      # 持久化原始材质名，即使插件重载也能恢复
      save_highlight_origin(face)

      highlight = model.materials['Takeoff 定位'] || model.materials.add('Takeoff 定位')
      highlight.color = Sketchup::Color.new(255, 180, 0)
      face.material = highlight
      face.back_material = highlight

      # 先推送 UI 高亮（在模型操作之前，确保不受模型异常影响）
      @dialog.execute_script("window.highlightFaceInUI(#{face_id}, #{JSON.generate(path_ids)})")

      model.rendering_options['XRayMode'] = true rescue nil
      model.selection.clear
      model.selection.add(face)
    end

    def save_highlight_origin(face)
      dict = face.attribute_dictionary('su_takeoff_highlight', true)
      dict['front'] = face.material&.name
      dict['back'] = face.back_material&.name
    end

    def restore_highlight_face
      if @last_face && @last_face.valid?
        @last_face.material = @last_front_mat
        @last_face.back_material = @last_back_mat
      end
      @last_face = nil
      @last_front_mat = nil
      @last_back_mat = nil
    end

    def clear_face_highlight
      restore_highlight_face
      # 兜底：遍历模型，根据持久化属性恢复所有高亮面
      model = Sketchup.active_model
      restore_all_highlight_faces(model.entities, model)
    rescue
      @last_face = nil
      @last_front_mat = nil
      @last_back_mat = nil
    end

    def restore_all_highlight_faces(entities, model)
      entities.each do |e|
        if e.is_a?(Sketchup::Face) && e.material&.name == 'Takeoff 定位'
          dict = e.attribute_dictionary('su_takeoff_highlight')
          e.material = model.materials[dict['front']] if dict && dict['front']
          e.back_material = model.materials[dict['back']] if dict && dict['back']
          e.delete_attribute('su_takeoff_highlight', 'front') rescue nil
          e.delete_attribute('su_takeoff_highlight', 'back') rescue nil
          e.attribute_dictionary_delete('su_takeoff_highlight') rescue nil
        elsif e.respond_to?(:entities)
          restore_all_highlight_faces(e.entities, model)
        elsif e.respond_to?(:definition)
          restore_all_highlight_faces(e.definition.entities, model)
        end
      end
    end

    def locate_entity(json)
      eid = JSON.parse(json)
      model = Sketchup.active_model
      entity = model.find_entity_by_id(eid)
      return unless entity
      model.selection.clear
      model.selection.add(entity)
      # 逐层展开父级容器，确保 zoom 不会跳转到错误的坐标空间
      parents = []
      p = entity.parent
      while p && !p.is_a?(Sketchup::Model)
        parents.unshift(p) if p.is_a?(Sketchup::Group) || p.is_a?(Sketchup::ComponentInstance)
        p = p.parent
      end
      begin
        model.active_path = parents unless parents.empty?
      rescue
        # 某些容器可能无法作为编辑路径打开，忽略继续
      end
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

    def send_mappings
      mappings = PluginState.instance.mapping.all.map(&:to_h)
      # 每次从文件读取最新配置，避免因插件加载时序导致使用旧默认值
      cfg = if File.exist?(PluginState.config_path)
              JSON.parse(File.read(PluginState.config_path))
            else
              {}
            end
      config = {
        category_units: cfg['material_category_units'] || cfg['category_units'] || [],
        config_units: cfg['units'] || []
      }
      @dialog.execute_script("window.renderMappings(#{JSON.generate(mappings)}, #{JSON.generate(config)})")
    end

    def save_mapping(json)
      data = JSON.parse(json)
      m = PluginState.instance.mapping
      m.add(data['su_name'], data['material_name'], data['category'],
            data['unit'], data['spec'], (data['waste_rate'] || 0.0).to_f,
            data['platform_material_tag'])
      m.save_json(PluginState.mapping_path)
      PluginState.instance.save_mapping_to_model_dict
      send_mappings
      send_workbench_state if @last_scan
    end

    def delete_mapping(su_name)
      m = PluginState.instance.mapping
      m.delete(su_name)
      m.save_json(PluginState.mapping_path)
      PluginState.instance.save_mapping_to_model_dict
      send_mappings
      send_workbench_state if @last_scan
    end

    def send_component_mappings
      mappings = PluginState.instance.component_mapping.all.map(&:to_h)
      model = Sketchup.active_model
      # 组件定义名 (kind: 'component')
      comp_names = model.definitions.reject(&:group?).map(&:name).reject { |n| n.nil? || n.empty? }.uniq
      # 群组名 (kind: 'group')
      group_set = Set.new
      collect_group_names(model.entities, group_set)
      group_names = group_set.to_a
      # 合并：带 kind 信息
      entries = comp_names.map { |n| { name: n, kind: 'component' } } +
                group_names.map { |n| { name: n, kind: 'group' } }
      entries.sort_by! { |e| e[:name] }
      # Read config
      cfg = if File.exist?(PluginState.config_path)
              JSON.parse(File.read(PluginState.config_path))
            else
              {}
            end
      config = {
        category_units: cfg['component_category_units'] || [],
        config_units: cfg['units'] || []
      }
      @dialog.execute_script("window.renderComponentMappings(#{JSON.generate(mappings)}, #{JSON.generate(entries)}, #{JSON.generate(config)})")
    end

    def collect_group_names(entities, result)
      entities.each do |e|
        if e.is_a?(Sketchup::Group)
          name = e.name
          result.add(name) if name && !name.empty?
          collect_group_names(e.entities, result)
        elsif e.is_a?(Sketchup::ComponentInstance)
          collect_group_names(e.definition.entities, result)
        end
      end
    end

    def save_component_mapping(json)
      data = JSON.parse(json)
      cm = PluginState.instance.component_mapping
      cm.add(data['definition_name'], data['material_name'], data['category'],
             data['unit'] || '个', data['spec'] || '', data['waste_rate'].to_f,
             data['counting_method'] || 'expand', data['platform_material_tag'],
             data['platform_component_type'])
      cm.save_json(PluginState.component_mapping_path)
      PluginState.instance.save_component_mapping_to_model_dict
      send_component_mappings
      send_workbench_state if @last_scan
    end

    def delete_component_mapping(def_name)
      cm = PluginState.instance.component_mapping
      cm.delete(def_name)
      cm.save_json(PluginState.component_mapping_path)
      PluginState.instance.save_component_mapping_to_model_dict
      send_component_mappings
      send_workbench_state if @last_scan
    end

    def import_csv_dialog
      path = UI.openpanel('选择映射CSV文件', '', 'CSV Files|*.csv||')
      return unless path
      PluginState.instance.mapping.import_csv(path)
      PluginState.instance.mapping.save_json(PluginState.mapping_path)
      PluginState.instance.save_mapping_to_model_dict
      send_mappings
    end

    def export_csv_dialog
      path = UI.savepanel('导出映射CSV', '', 'material_mapping.csv')
      return unless path
      PluginState.instance.mapping.export_csv(path)
    end

    def send_settings
      state = PluginState.instance
      data = {
        ignored: state.ignored,
        material_category_units: state.config['material_category_units'] || [],
        component_category_units: state.config['component_category_units'] || [],
        config_units: state.config['units'] || [],
        tag_defs: state.config['tag_defs'] || {},
        heuristics_enabled: state.config.fetch('heuristics_enabled', true),
        heuristic_thresholds: state.config['heuristic_thresholds'] || {}
      }
      @dialog.execute_script("window.renderSettings(#{JSON.generate(data)})")
    end

    def save_config(json)
      data = JSON.parse(json)
      PluginState.instance.save_config(
        material_category_units: data['material_category_units'] || data['category_units'] || [],
        component_category_units: data['component_category_units'] || [],
        units: data['units'] || [],
        heuristics_enabled: data['heuristics_enabled'],
        heuristic_thresholds: data['heuristic_thresholds'],
        tag_defs: data['tag_defs']
      )
      send_workbench_state if @last_scan
    end

    def ignore_material(name)
      PluginState.instance.ignore!(name)
      send_workbench_state if @last_scan
    end

    def unignore(name)
      PluginState.instance.unignore!(name)
      send_settings
      send_workbench_state if @last_scan
    end

    def clear_ignored
      PluginState.instance.set_ignored!([])
      send_settings
      send_workbench_state if @last_scan
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
      tag_name = data['tag_name']  # nil / '' 表示清除

      model = Sketchup.active_model
      entity = model.find_entity_by_id(entity_id)
      return unless entity
      return unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)

      model.start_operation('设置标记', true)
      if tag_name.nil? || tag_name.empty?
        entity.delete_attribute('su_takeoff', 'tag') rescue nil
        entity.delete_attribute('su_takeoff', 'method') rescue nil
        entity.delete_attribute('su_takeoff', 'material') rescue nil
      else
        tag_defs = PluginState.instance.config['tag_defs'] || {}
        method = tag_defs[tag_name]
        entity.set_attribute('su_takeoff', 'tag', tag_name)
        entity.set_attribute('su_takeoff', 'method', method) if method
      end
      model.commit_operation

      partial_rescan_entity(entity_id, tag_name)
    rescue => e
      msg = JSON.generate({ error: e.message, backtrace: e.backtrace.first(5) })
      @dialog.execute_script("window.renderWorkbenchError(#{msg})")
    end

    def send_cloud_state(extra = {})
      extra = normalize_cloud_state_extra(extra)
      data = {
        api_configured: api_configured?,
        api_environment: api_config['environment'],
        api_base_url: api_config['base_url'],
        auth: auth_state_hash,
        binding: project_binding_hash,
        has_scan: !!@last_scan,
        busy: @cloud_busy
      }.merge(extra)
      json = JSON.generate(data)
      @dialog.execute_script("window.renderCloudState && window.renderCloudState(#{json}); window.renderLoginState && window.renderLoginState(#{json});")
    rescue => e
      send_cloud_error(e)
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
      send_cloud_state(status_message: '正在退出登录...')
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

    def save_project_binding(json)
      return unless require_login!

      data = JSON.parse(json)
      binding = Api::ProjectBinding.load(Sketchup.active_model)
      binding.update_project!(
        project_code: data['project_code'],
        project_name: data['project_name']
      )
      send_cloud_state(status_message: '项目绑定已保存')
    rescue => e
      send_cloud_error(e)
    end

    def cloud_push
      return unless require_login!

      return send_cloud_error_message('请先扫描模型') unless @last_scan
      return send_cloud_error_message('API Base URL 未配置') unless api_configured?
      return send_cloud_error_message('请先登录平台账号') unless auth_session.signed_in?
      return send_cloud_error_message('当前账号缺少 quantity:ingest 权限') unless auth_session.can_push?
      return send_cloud_error_message('已有推送任务正在执行') if @cloud_busy

      binding = Api::ProjectBinding.load(Sketchup.active_model)
      build = Api::QuantityPayloadBuilder.new(
        items: @last_scan[:items],
        openings: @last_scan[:openings],
        mapping: PluginState.instance.mapping,
        component_mapping: PluginState.instance.component_mapping,
        policy: PluginState.instance.takeoff_policy,
        binding: binding,
        ignored: PluginState.instance.ignored
      ).build

      unless build.issues.empty?
        send_cloud_state(sync_result: { success: false, issues: build.issues })
        return
      end

      @cloud_busy = true
      send_cloud_state(status_message: '正在上传算量数据...')
      ensure_cloud_ui_pump

      Thread.new do
        outbox = Api::SyncOutbox.new(dir: cloud_outbox_dir)
        sync = Api::QuantitySyncService.new(
          api_client: api_client,
          auth_session: auth_session,
          outbox: outbox,
          binding: binding,
          mapping: PluginState.instance.mapping,
          component_mapping: PluginState.instance.component_mapping,
          policy: PluginState.instance.takeoff_policy,
          ignored: PluginState.instance.ignored,
          persist_success: false
        )
        result = sync.push_built(build)
        run_on_ui_thread { finish_cloud_push(binding, build, result) }
      rescue => e
        run_on_ui_thread do
          @cloud_busy = false
          send_cloud_error(e)
        end
      end
    rescue => e
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
        idempotency_key: result.payload && result.payload[:idempotency_key]
      }
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
      send_cloud_state(status_message: '正在恢复登录状态...', force_login: true)
      ensure_cloud_ui_pump
      Thread.new do
        begin
          auth_session.restore(username: account)
          run_on_ui_thread do
            @cloud_busy = false
            message = auth_session.signed_in? ? '登录状态已恢复' : '请先登录平台账号'
            send_cloud_state(status_message: message, force_login: !auth_session.signed_in?)
          end
        rescue => e
          run_on_ui_thread do
            @cloud_busy = false
            send_cloud_error(e, force_login: true)
          end
        end
      end
    rescue => e
      @cloud_busy = false
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
        File.exist?(path) ? JSON.parse(File.read(path)) : {}
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
        next if @cloud_busy || !@cloud_ui_queue.empty?

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
