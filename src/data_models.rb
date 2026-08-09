module SuTakeoff
  # Result of scanning one face, edge, or instance.
  #
  # 所有字段均通过 keyword_init: true 构造，推荐使用下方工厂方法。
  #
  # 字段说明：
  #   qty_area / qty_length / qty_volume / qty_count
  #     按量纲拆分的几何量，由 Scanner 同时填充。Calculator 优先使用这些字段，
  #     回退到 qty 兼容旧调用。
  #   depth   solid bbox 第三维（P3 体积场景启用）
  #   tags    AttributeDictionary 读出的覆盖标签 { method:, material: }
  #   resolved_method / source
  #     Policy 决议结果占位（P2 启用）
  #   strategy_name
  #     Policy 决议得到的 Strategy 名称（Symbol，如 :face_area / :solid_linear）
  #     由 Calculator#cache_resolve 写入，Presenter 用于调试输出。
  #   face_persistent_id / component_path_persistent_ids
  #     平台推送用稳定编码来源；entityID 仍保留给当前会话内 UI 定位。
  scan_item_members = [
    :face_id,
    :su_material,
    :qty,
    :unit,
    :kind,           # :face / :edge / :instance / :solid / :linear_solid
    :normal,
    :width,
    :height,
    :layer_name,
    :component_path,
    :component_path_ids,
    :z_center,
    :qty_area,
    :qty_length,
    :qty_volume,
    :qty_count,
    :depth,
    :tags,
    :tag,             # 标记名（来自标记系统，如 "踢脚线"）
    :resolved_method,
    :source,
    :center_x,       # P4: bbox 中心世界坐标 X（米）—— 竖直薄板配对用
    :center_y,       # P4: bbox 中心世界坐标 Y（米）
    :strategy_name,  # Stage 3: Strategy 名称（Symbol）
    :face_persistent_id,
    :component_path_persistent_ids
  ]
  if const_defined?(:ScanItem, false)
    unless ScanItem.members == scan_item_members
      raise 'ScanItem 字段已变化，请重启 SketchUp 以完成开发版更新'
    end
  else
    ScanItem = Struct.new(*scan_item_members, keyword_init: true)
  end

  # ---- Keyword factories for ScanItem ----
  # 推荐使用以下工厂方法替代直接 ScanItem.new，一次调用完成所有字段初始化。

  class ScanItem
    # entityID 只标识定义中的实体；同一定义被多个实例复用时，必须用完整路径
    # 区分模型中的每个出现位置。
    def component_occurrence_key
      self.class.path_key(component_path_ids)
    end

    def face_occurrence_key
      self.class.path_key(Array(component_path_ids) + [face_id])
    end

    def self.path_key(ids)
      Array(ids).compact.map(&:to_i).join('/')
    end

    def self.face(face_id:, su_material:, area:, normal:, width:, height:,
                  layer_name:, component_path:, component_path_ids:,
                  z_center: 0, tags: nil, tag: nil, center_x: nil, center_y: nil,
                  face_persistent_id: nil, component_path_persistent_ids: nil)
      new(
        face_id: face_id, su_material: su_material,
        qty: area, unit: 'm²', kind: :face,
        normal: normal, width: width, height: height,
        layer_name: layer_name,
        component_path: component_path, component_path_ids: component_path_ids,
        z_center: z_center,
        qty_area: area, qty_length: nil, qty_volume: 0, qty_count: 0,
        tags: tags, tag: tag,
        center_x: center_x, center_y: center_y,
        face_persistent_id: face_persistent_id,
        component_path_persistent_ids: component_path_persistent_ids
      )
    end

    def self.instance(face_id:, su_material:, unit: '个',
                      layer_name:, component_path:, component_path_ids:,
                      tags: nil, tag: nil, face_persistent_id: nil,
                      component_path_persistent_ids: nil)
      new(
        face_id: face_id, su_material: su_material,
        qty: 1, unit: unit, kind: :instance,
        normal: nil, width: 0, height: 0,
        layer_name: layer_name,
        component_path: component_path, component_path_ids: component_path_ids,
        z_center: 0,
        qty_count: 1, qty_area: 0, qty_length: 0, qty_volume: 0,
        tags: tags, tag: tag,
        face_persistent_id: face_persistent_id,
        component_path_persistent_ids: component_path_persistent_ids
      )
    end

    def self.solid(face_id:, su_material:, volume:, width:, height:, depth:,
                   layer_name:, component_path:, component_path_ids:,
                   z_center: 0, tags: nil, tag: nil, face_persistent_id: nil,
                   component_path_persistent_ids: nil)
      new(
        face_id: face_id, su_material: su_material,
        qty: 0, unit: 'm³', kind: :solid,
        normal: nil, width: width, height: height,
        layer_name: layer_name,
        component_path: component_path, component_path_ids: component_path_ids,
        z_center: z_center,
        qty_volume: volume, qty_area: 0, qty_length: depth, qty_count: 0,
        depth: depth,
        tags: tags, tag: tag,
        face_persistent_id: face_persistent_id,
        component_path_persistent_ids: component_path_persistent_ids
      )
    end

    def self.linear_solid(face_id:, su_material:, length:,
                          width: 0, height: 0, depth: 0,
                          layer_name:, component_path:, component_path_ids:,
                          z_center: 0, tags: nil, tag: nil, face_persistent_id: nil,
                          component_path_persistent_ids: nil)
      new(
        face_id: face_id, su_material: su_material,
        qty: 0, unit: 'm', kind: :linear_solid,
        normal: nil, width: width, height: height,
        layer_name: layer_name,
        component_path: component_path, component_path_ids: component_path_ids,
        z_center: z_center,
        qty_length: length, qty_area: 0, qty_volume: 0,
        depth: depth,
        tags: tags, tag: tag,
        face_persistent_id: face_persistent_id,
        component_path_persistent_ids: component_path_persistent_ids
      )
    end

    def self.count_solid(face_id:, su_material:, unit: '个',
                         layer_name:, component_path:, component_path_ids:,
                         tags: nil, tag: nil, face_persistent_id: nil,
                         component_path_persistent_ids: nil)
      new(
        face_id: face_id, su_material: su_material,
        qty: 1, unit: unit, kind: :count_solid,
        normal: nil, width: 0, height: 0,
        layer_name: layer_name,
        component_path: component_path, component_path_ids: component_path_ids,
        z_center: 0,
        qty_count: 1, qty_area: 0, qty_length: 0, qty_volume: 0,
        tags: tags, tag: tag,
        face_persistent_id: face_persistent_id,
        component_path_persistent_ids: component_path_persistent_ids
      )
    end
  end

  # Result of hole/window/opening detection
  opening_members = [
    :entity_id, :area, :host_face_ids,
    :component_path_ids, :persistent_id, :host_face_keys,
    :center_x, :center_y, :z_center, :normal
  ]
  if const_defined?(:Opening, false)
    unless Opening.members == opening_members
      raise 'Opening 字段已变化，请重启 SketchUp 以完成开发版更新'
    end
  else
    Opening = Struct.new(*opening_members)
  end

  class Opening
    def occurrence_key
      ScanItem.path_key(Array(component_path_ids) + [entity_id])
    end
  end
end
