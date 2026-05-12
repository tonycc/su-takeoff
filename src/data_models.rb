module SuTakeoff
  # Result of scanning one face, edge, or instance
  ScanItem = Struct.new(
    :face_id,       # SU entity_id
    :su_material,   # SU material name (string) or nil
    :qty,           # Float quantity (m²/m/个 depending on unit)
    :unit,          # 'm2' / 'm' / '个'
    :kind,          # :face / :edge / :instance
    :normal,        # [x, y, z] world-space normal vector (nil for edge/instance)
    :width,         # Float estimated width in m
    :height,        # Float estimated height in m
    :layer_name,    # String SU layer name
    :component_path,# Array of ancestor component names
    :z_center       # Float bounds center Z in meters (world space)
  )

  # One derived material item from a process/工艺
  Derivation = Struct.new(:layer, :unit, :formula, :waste_rate, :category, keyword_init: true)

  # Grouped scan item with resolved material info
  class MaterialUsage
    attr_accessor :space, :part, :material_name, :category, :spec,
                  :net_area, :waste_rate, :purchase_qty, :items,
                  :su_material_name, :layer, :parent_su_material, :unit

    def initialize(space:, part:, material_name:, category: '', spec: '',
                   net_area: 0.0, waste_rate: 0.05, su_material_name: '',
                   layer: '', parent_su_material: '', unit: 'm2')
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
        layer: @layer, parent_su_material: @parent_su_material, unit: @unit
      }
    end
  end

  # Result of hole/window/opening detection
  Opening = Struct.new(:entity_id, :area, :host_face_ids)
end