module SuTakeoff
  # Result of scanning one face
  ScanItem = Struct.new(
    :face_id,       # SU face entity_id
    :su_material,   # SU material name (string) or nil
    :area,          # Float area in m²
    :normal,        # [x, y, z] normal vector
    :width,         # Float estimated width
    :height,        # Float estimated height
    :layer_name,    # String SU layer name
    :component_path # Array of ancestor component names
  )

  # Grouped scan item with resolved material info
  class MaterialUsage
    attr_accessor :space, :part, :material_name, :category, :spec,
                  :net_area, :waste_rate, :purchase_qty, :items,
                  :su_material_name

    def initialize(space:, part:, material_name:, category: '', spec: '',
                   net_area: 0.0, waste_rate: 0.05, su_material_name: '')
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
    end

    def recalc!
      @purchase_qty = (@net_area * (1 + @waste_rate)).round(2)
    end

    def to_h
      {
        space: @space, part: @part, material_name: @material_name,
        category: @category, spec: @spec, net_area: @net_area.round(2),
        waste_rate: @waste_rate, purchase_qty: @purchase_qty,
        su_material_name: @su_material_name
      }
    end
  end

  # Result of hole/window/opening detection
  Opening = Struct.new(:entity_id, :area, :host_face_ids)
end
