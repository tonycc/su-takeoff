module SuTakeoff
  class Calculator
    # Two horizontal faces with same material, near-equal area and close z_center
    # are treated as two sides of a thin slab (e.g. floor plate, ceiling plate).
    SLAB_AREA_TOLERANCE = 0.02      # 2% area diff
    SLAB_Z_TOLERANCE_M = 0.15       # 15 cm thickness max

    def initialize(mapping, process_library)
      @mapping = mapping
      @processes = process_library
    end

    # Returns Array of MaterialUsage
    # items: Array of ScanItem
    # openings: Array of Opening
    # process_overrides: Hash { su_material_name => process_name }
    def compute(items, openings, process_overrides)
      items = dedup_thin_slabs(items)

      # 1. Map openings to their host face IDs for fast lookup
      opening_area_by_face = {}
      openings_by_face = Hash.new { |h, k| h[k] = [] }
      openings.each do |op|
        op.host_face_ids.each do |fid|
          opening_area_by_face[fid] ||= 0.0
          opening_area_by_face[fid] += op.area
          openings_by_face[fid] << { entity_id: op.entity_id, area: op.area.round(3) }
        end
      end


      # 2. Group items by (space, part, su_material_name, unit)
      groups = Hash.new { |h, k| h[k] = [] }
      skipped_unmapped = []
      skipped_nil_mat = []

      items.each do |item|
        unless @mapping.get(item.su_material)
          if item.su_material.nil?
            skipped_nil_mat << item
          else
            skipped_unmapped << item
          end
          next
        end

        part = self.class.face_orientation(item.normal)
        space = self.class.extract_space(item)
        key = [space, part, item.su_material, item.unit]
        groups[key] << item
      end


      # 3. Build MaterialUsage for each group (fan-out via derivations)
      usages = groups.flat_map do |(space, part, su_mat, item_unit), grp_items|
        record = @mapping.get(su_mat)
        # When mapping unit is 'm' (linear), sum face heights (longest edge)
        # instead of areas; skip opening deduction (line items have no openings).
        is_linear = record.unit == 'm'
        if is_linear
          gross = grp_items.sum { |it| (it.height || 0).to_f }.round(3)
          total_deduction = 0.0
          net_area = gross
          faces_detail = grp_items.map { |it|
            { face_id: it.face_id, width: (it.width || 0).round(2),
              height: (it.height || 0).round(2),
              area: it.qty.round(3), length: (it.height || 0).round(3),
              part: Calculator.face_orientation(it.normal),
              component_path: it.component_path }
          }
        else
          gross = grp_items.sum(&:qty).round(3)
          total_deduction = grp_items.sum { |it| opening_area_by_face[it.face_id] || 0.0 }.round(3)
          net_area = grp_items.sum { |it|
            deduction = opening_area_by_face[it.face_id] || 0.0
            [it.qty - deduction, 0.0].max
          }
          faces_detail = grp_items.map { |it|
            d = (opening_area_by_face[it.face_id] || 0.0).round(3)
            ops = openings_by_face[it.face_id] || []
            { face_id: it.face_id, width: (it.width || 0).round(2),
              height: (it.height || 0).round(2),
              area: it.qty.round(3), deduction: d, net: (it.qty - d).round(3),
              part: Calculator.face_orientation(it.normal),
              component_path: it.component_path,
              openings: ops }
          }
        end

        # Find the process (with optional override)
        process = if process_overrides[su_mat]
          @processes.processes_for(record.category).find { |p|
            p.name == process_overrides[su_mat]
          }
        else
          @processes.processes_for(record.category).first
        end

        waste_rate = record.default_waste_rate
        detail = {
          gross: gross.round(3),
          deduction: total_deduction.round(3),
          face_count: grp_items.size,
          faces: faces_detail
        }

        # Always create the primary usage (represents the main material)
        primary = MaterialUsage.new(
          space: space, part: part,
          material_name: record.material_name,
          category: record.category,
          spec: record.spec,
          net_area: net_area.round(4),
          waste_rate: process&.waste_rate || waste_rate,
          su_material_name: su_mat,
          unit: record.unit || item_unit,
          detail: detail
        )
        primary.items = grp_items
        usages = [primary]

        # Fan-out derivations as additional usages
        if process && process.derivations && !process.derivations.empty?
          process.derivations.each do |deriv|
            deriv_qty = eval_formula(deriv.formula, net_area)
            derived = MaterialUsage.new(
              space: space, part: part,
              material_name: deriv.layer,
              category: deriv.category,
              spec: record.spec,
              net_area: deriv_qty.round(4),
              waste_rate: deriv.waste_rate,
              su_material_name: su_mat,
              layer: deriv.layer,
              parent_su_material: su_mat,
              unit: deriv.unit,
              detail: {
                formula: deriv.formula,
                base_value: net_area.round(3),
                base_unit: is_linear ? 'm' : 'm²',
                face_count: grp_items.size
              }
            )
            derived.items = grp_items
            usages << derived
          end
        end
        usages
      end

      usages
    end

    # Returns Hash { material_name => { net_area:, purchase_qty:, items: [MaterialUsage] } }
    def group_by_material(usages)
      grouped = Hash.new { |h, k| h[k] = { net_area: 0.0, purchase_qty: 0.0, items: [] } }
      usages.each do |u|
        grouped[u.material_name][:net_area] += u.net_area
        grouped[u.material_name][:purchase_qty] += u.purchase_qty
        grouped[u.material_name][:items] << u
      end
      grouped.each_value do |v|
        v[:net_area] = v[:net_area].round(2)
        v[:purchase_qty] = v[:purchase_qty].round(2)
      end
      grouped
    end

    # Returns the unmapped material names from items
    def unmapped_materials(items)
      @mapping.unmapped_materials(items.map(&:su_material).compact)
    end

    def self.face_orientation(normal)
      z = normal[2].abs
      if z > 0.866  # ~30° from vertical
        normal[2] > 0 ? 'floor' : 'ceiling'
      else
        'wall'
      end
    end

    # Extract room name from the first element of component_path.
    # When the model uses naming prefix convention like "主卧-涂料",
    # the part before the first "-" is the room name.
    def self.extract_space(item)
      raw = item.component_path.first || '未分组'
      raw.include?('-') ? raw.split('-', 2).first : raw
    end

    private

    def eval_formula(formula, net_area, item = nil)
      vars = { area: net_area }
      if item
        vars[:length] = item.qty if item.kind == :edge
        vars[:count] = item.qty if item.kind == :instance
      end
      Formula.eval(formula, vars)
    end

    # Remove the "back side" of thin horizontal slabs.
    #
    # A thin slab (e.g. a floor plate, a ceiling plate, a found-level screed)
    # is modeled as a thin volume with the same material on top and bottom.
    # Naive counting doubles the area — once as floor, once as ceiling.
    #
    # We detect pairs within (space, material) where one face points up,
    # another points down, areas match within SLAB_AREA_TOLERANCE, and their
    # z_centers are within SLAB_Z_TOLERANCE_M. For each pair we keep the
    # face whose orientation matches the slab's vertical position within
    # the space:
    #   - slab in the lower half of the space  -> keep the 'floor' face (top)
    #   - slab in the upper half               -> keep the 'ceiling' face (bottom)
    # This mirrors which side is actually visible to occupants.
    def dedup_thin_slabs(items)
      # Compute per-space vertical midpoint across ALL items in the space,
      # so a slab can be located in its global context rather than against
      # only its own two faces.
      items_by_space = items.group_by { |it| Calculator.extract_space(it) }
      space_z_mid = {}
      items_by_space.each do |sp, sp_items|
        zs = sp_items.map(&:z_center).compact
        next if zs.empty?
        space_z_mid[sp] = (zs.min + zs.max) / 2.0
      end

      grouped = items.group_by { |it| [Calculator.extract_space(it), it.su_material] }
      drop_ids = {}

      grouped.each do |(space, _mat), group|
        next if group.empty?
        mid = space_z_mid[space]
        next unless mid

        ups = group.select { |it| it.normal[2] > 0.866 }
        downs = group.select { |it| it.normal[2] < -0.866 }
        matched_down = {}

        next if ups.empty? || downs.empty?

        ups.each do |up|
          pair = downs.find do |dn|
            !matched_down[dn.face_id] &&
              up.qty > 0 &&
              (up.qty - dn.qty).abs / up.qty <= SLAB_AREA_TOLERANCE &&
              (up.z_center - dn.z_center).abs <= SLAB_Z_TOLERANCE_M
          end
          next unless pair

          matched_down[pair.face_id] = true
          slab_z = (up.z_center + pair.z_center) / 2.0
          if slab_z <= mid
            drop_ids[pair.face_id] = true
          else
            drop_ids[up.face_id] = true
          end
        end
      end

      items.reject { |it| drop_ids[it.face_id] }
    end
  end
end