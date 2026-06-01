module SuTakeoff
  # Result of scanning one face, edge, or instance.
  #
  # 历史字段（前 12 个）保持位置不变，老调用 ScanItem.new(face_id, su_material, qty,
  # unit, kind, normal, width, height, layer_name, component_path,
  # component_path_ids, z_center) 仍然有效，新增字段默认为 nil。
  #
  # 新字段说明（P1 仅扩展数据载体，未引入语义变化）：
  #   qty_area / qty_length / qty_volume / qty_count
  #     按量纲拆分的几何量，由 Scanner 同时填充。Calculator 优先使用这些字段，
  #     回退到 qty 兼容旧调用。
  #   depth   solid bbox 第三维（P3 体积场景启用）
  #   tags    AttributeDictionary 读出的覆盖标签 { method:, material: }
  #   resolved_method / source
  #     Policy 决议结果占位（P2 启用）
  ScanItem = Struct.new(
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
    :center_y        # P4: bbox 中心世界坐标 Y（米）
  )

  # ---- Keyword factories for ScanItem ----
  # 推荐使用以下工厂方法替代直接 ScanItem.new，一次调用完成所有字段初始化。

  class ScanItem
    def self.face(face_id:, su_material:, area:, normal:, width:, height:,
                  layer_name:, component_path:, component_path_ids:,
                  z_center: 0, tags: nil, tag: nil, center_x: nil, center_y: nil)
      item = new(
        face_id, su_material, area, 'm²', :face,
        normal, width, height, layer_name,
        component_path, component_path_ids, z_center
      )
      item.qty_area = area
      item.qty_length = height
      item.qty_count = 0
      item.tags = tags
      item.tag = tag
      item.center_x = center_x
      item.center_y = center_y
      item
    end

    def self.instance(face_id:, su_material:, unit: '个',
                      layer_name:, component_path:, component_path_ids:,
                      tags: nil, tag: nil)
      item = new(
        face_id, su_material, 1, unit, :instance,
        nil, 0, 0, layer_name,
        component_path, component_path_ids, 0
      )
      item.qty_count = 1
      item.qty_area = 0
      item.qty_length = 0
      item.tags = tags
      item.tag = tag
      item
    end

    def self.solid(face_id:, su_material:, volume:, width:, height:, depth:,
                   layer_name:, component_path:, component_path_ids:,
                   z_center: 0, tags: nil, tag: nil)
      item = new(
        face_id, su_material, 0, 'm³', :solid,
        nil, width, height, layer_name,
        component_path, component_path_ids, z_center
      )
      item.qty_volume = volume
      item.qty_area = 0
      item.qty_length = depth
      item.depth = depth
      item.tags = tags
      item.tag = tag
      item
    end

    def self.linear_solid(face_id:, su_material:, length:,
                          width: 0, height: 0, depth: 0,
                          layer_name:, component_path:, component_path_ids:,
                          z_center: 0, tags: nil, tag: nil)
      item = new(
        face_id, su_material, 0, 'm', :linear_solid,
        nil, width, height, layer_name,
        component_path, component_path_ids, z_center
      )
      item.qty_length = length
      item.qty_area = 0
      item.qty_volume = 0
      item.depth = depth
      item.tags = tags
      item.tag = tag
      item
    end

    def self.count_solid(face_id:, su_material:, unit: '个',
                         layer_name:, component_path:, component_path_ids:,
                         tags: nil, tag: nil)
      item = new(
        face_id, su_material, 1, unit, :count_solid,
        nil, 0, 0, layer_name,
        component_path, component_path_ids, 0
      )
      item.qty_count = 1
      item.qty_area = 0
      item.qty_length = 0
      item.qty_volume = 0
      item.tags = tags
      item.tag = tag
      item
    end
  end

  # One derived material item from a process/工艺
  Derivation = Struct.new(:layer, :unit, :formula, :waste_rate, :category, keyword_init: true)

  # Grouped scan item with resolved material info
  class MaterialUsage
    attr_accessor :space, :part, :material_name, :category, :spec,
                  :net_area, :waste_rate, :purchase_qty, :items,
                  :su_material_name, :layer, :parent_su_material, :unit,
                  :detail, :confidence, :source

    def initialize(space:, part:, material_name:, category: '', spec: '',
                   net_area: 0.0, waste_rate: 0.05, su_material_name: '',
                   layer: '', parent_su_material: '', unit: 'm2', detail: nil,
                   confidence: :explicit, source: :mapping)
      @space = space
      @part = part           # 'floor', 'wall', 'ceiling'
      @material_name = material_name
      @category = category
      @spec = spec
      @net_area = net_area
      @waste_rate = waste_rate
      @purchase_qty = (net_area * (1 + waste_rate)).round(2)
      @items = []
      @su_material_name = su_material_name
      @layer = layer
      @parent_su_material = parent_su_material
      @unit = unit
      @detail = detail
      @confidence = confidence  # :explicit / :heuristic
      @source = source          # :attr / :layer / :heuristic / :mapping / :default
    end

    def recalc!
      @purchase_qty = (@net_area * (1 + @waste_rate)).round(2)
    end

    def to_h
      {
        space: @space, part: @part, material_name: @material_name,
        category: @category, spec: @spec, net_area: @net_area.round(2),
        waste_rate: @waste_rate, purchase_qty: @purchase_qty,
        su_material_name: @su_material_name,
        layer: @layer, parent_su_material: @parent_su_material, unit: @unit,
        detail: @detail,
        confidence: @confidence, source: @source
      }
    end
  end

  # Result of hole/window/opening detection
  Opening = Struct.new(:entity_id, :area, :host_face_ids)
end
