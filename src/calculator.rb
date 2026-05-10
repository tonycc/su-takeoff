module SuTakeoff
  class Calculator
    def initialize(mapping, process_library)
      @mapping = mapping
      @processes = process_library
    end

    # Returns Array of MaterialUsage
    # items: Array of ScanItem
    # openings: Array of Opening
    # process_overrides: Hash { su_material_name => process_name }
    def compute(items, openings, process_overrides)
      # 1. Map openings to their host face IDs for fast lookup
      opening_area_by_face = {}
      openings.each do |op|
        op.host_face_ids.each do |fid|
          opening_area_by_face[fid] ||= 0.0
          opening_area_by_face[fid] += op.area
        end
      end

      # 2. Group items by (space, part, su_material_name)
      groups = Hash.new { |h, k| h[k] = [] }
      items.each do |item|
        next unless @mapping.get(item.su_material)

        part = self.class.face_orientation(item.normal)
        space = item.component_path.last || '未分组'
        key = [space, part, item.su_material]
        groups[key] << item
      end

      # 3. Build MaterialUsage for each group
      groups.map do |(space, part, su_mat), grp_items|
        record = @mapping.get(su_mat)
        net_area = grp_items.sum { |it|
          deduction = opening_area_by_face[it.face_id] || 0.0
          [it.area - deduction, 0.0].max
        }

        waste_rate = if process_overrides[su_mat]
          proc_def = @processes.processes_for(record.category).find { |p|
            p.name == process_overrides[su_mat]
          }
          proc_def&.waste_rate || record.default_waste_rate
        else
          record.default_waste_rate
        end

        usage = MaterialUsage.new(
          space: space, part: part,
          material_name: record.material_name,
          category: record.category,
          spec: record.spec,
          net_area: net_area.round(4),
          waste_rate: waste_rate,
          su_material_name: su_mat
        )
        usage.items = grp_items
        usage
      end
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
  end
end
