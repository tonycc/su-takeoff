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
      Debug.section "【计算阶段】开始"
      Debug.log "输入面数: #{items.size}"
      Debug.log "输入洞口数: #{openings.size}"

      items_before = items.size
      items = dedup_thin_slabs(items)
      Debug.log "薄板去重后剩余面数: #{items.size} (移除 #{items_before - items.size} 面)" if items_before != items.size

      # 1. Map openings to their host face IDs for fast lookup
      opening_area_by_face = {}
      openings.each do |op|
        op.host_face_ids.each do |fid|
          opening_area_by_face[fid] ||= 0.0
          opening_area_by_face[fid] += op.area
        end
      end

      if opening_area_by_face.any?
        Debug.subsection "洞口扣减映射"
        opening_area_by_face.each do |fid, area|
          Debug.log "  面ID=#{fid} 扣减=#{area.round(3)}m²"
        end
      else
        Debug.log "洞口扣减映射为空 (host_face_ids 全部为空，扣减未生效)"
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
        space = item.component_path.last || '未分组'
        key = [space, part, item.su_material, item.unit]
        groups[key] << item
      end

      if skipped_unmapped.any?
        Debug.subsection "跳过未映射材质 (#{skipped_unmapped.size}面)"
        skipped_unmapped.group_by(&:su_material).each do |mat, grp|
          Debug.log "  ✗ #{mat}: #{grp.size}面 #{grp.sum(&:qty).round(2)}m²"
        end
      end
      if skipped_nil_mat.any?
        Debug.log "✗ 跳过无材质面: #{skipped_nil_mat.size}面 #{skipped_nil_mat.sum(&:qty).round(2)}m²"
      end

      Debug.subsection "分组结果 (#{groups.size}组)"
      Debug.log

      # 3. Build MaterialUsage for each group (fan-out via derivations)
      usages = groups.flat_map do |(space, part, su_mat, item_unit), grp_items|
        record = @mapping.get(su_mat)
        gross = grp_items.sum(&:qty).round(3)
        total_deduction = grp_items.sum { |it| opening_area_by_face[it.face_id] || 0.0 }.round(3)
        net_area = grp_items.sum { |it|
          deduction = opening_area_by_face[it.face_id] || 0.0
          [it.qty - deduction, 0.0].max
        }

        Debug.log "  [#{space}] #{part} | #{record.material_name} (#{su_mat})"
        Debug.log "    面数: #{grp_items.size} | 毛面积: #{gross}m² | 扣减: #{total_deduction}m² | 净面积: #{net_area.round(3)}m²"

        # Find the process (with optional override)
        process = if process_overrides[su_mat]
          @processes.processes_for(record.category).find { |p|
            p.name == process_overrides[su_mat]
          }
        else
          @processes.processes_for(record.category).first
        end

        if process && process.derivations && !process.derivations.empty?
          # Fan-out: each derivation produces one MaterialUsage
          process.derivations.map do |deriv|
            deriv_qty = eval_formula(deriv.formula, net_area)
            usage = MaterialUsage.new(
              space: space, part: part,
              material_name: deriv.layer,
              category: deriv.category,
              spec: record.spec,
              net_area: deriv_qty.round(4),
              waste_rate: deriv.waste_rate,
              su_material_name: su_mat,
              layer: deriv.layer,
              parent_su_material: su_mat,
              unit: deriv.unit
            )
            usage.items = grp_items
            Debug.log "    派生: #{deriv.layer} | 数量: #{deriv_qty.round(3)}#{deriv.unit} | 损耗率: #{(deriv.waste_rate*100).round(1)}% | 采购量: #{usage.purchase_qty}#{deriv.unit}"
            usage
          end
        else
          # Fallback: single usage with mapping's default waste_rate
          waste_rate = record.default_waste_rate
          usage = MaterialUsage.new(
            space: space, part: part,
            material_name: record.material_name,
            category: record.category,
            spec: record.spec,
            net_area: net_area.round(4),
            waste_rate: waste_rate,
            su_material_name: su_mat,
            unit: item_unit
          )
          usage.items = grp_items
          Debug.log "    损耗率: #{(waste_rate*100).round(1)}% | 采购量: #{usage.purchase_qty}m²"
          [usage]
        end
      end

      Debug.subsection "统计结果汇总 (#{usages.size}条)"
      total_net = usages.sum(&:net_area).round(2)
      total_purchase = usages.sum(&:purchase_qty).round(2)
      Debug.log "总净面积: #{total_net} m²"
      Debug.log "总采购量: #{total_purchase} m²"
      Debug.log

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
      Debug.subsection "薄板去重"
      Debug.log "薄板判定容差: 面积差≤#{(SLAB_AREA_TOLERANCE*100).round(0)}%, 高度差≤#{SLAB_Z_TOLERANCE_M}m"

      # Compute per-space vertical midpoint across ALL items in the space,
      # so a slab can be located in its global context rather than against
      # only its own two faces.
      items_by_space = items.group_by { |it| it.component_path.last || '未分组' }
      space_z_mid = {}
      items_by_space.each do |sp, sp_items|
        zs = sp_items.map(&:z_center).compact
        next if zs.empty?
        space_z_mid[sp] = (zs.min + zs.max) / 2.0
        Debug.log "空间 [#{sp}] Z范围: #{zs.min.round(3)}~#{zs.max.round(3)}m 中线: #{space_z_mid[sp].round(3)}m"
      end

      grouped = items.group_by { |it| [it.component_path.last || '未分组', it.su_material] }
      drop_ids = {}
      total_dropped = 0

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
            drop_ids[pair.face_id] = true  # low slab: drop back (ceiling) face
            Debug.log "  ✅ 去重: [#{space}] 低处薄板 | 保留顶面 ID=#{up.face_id}(Z=#{up.z_center.round(3)}) | 移除底面 ID=#{pair.face_id}(Z=#{pair.z_center.round(3)}) | 板中心Z=#{slab_z.round(3)} ≤ 空间中线#{mid.round(3)}"
          else
            drop_ids[up.face_id] = true    # high slab: drop back (floor) face
            Debug.log "  ✅ 去重: [#{space}] 高处薄板 | 保留底面 ID=#{pair.face_id}(Z=#{pair.z_center.round(3)}) | 移除顶面 ID=#{up.face_id}(Z=#{up.z_center.round(3)}) | 板中心Z=#{slab_z.round(3)} > 空间中线#{mid.round(3)}"
          end
          total_dropped += 1
        end
      end

      if total_dropped.zero?
        Debug.log "  未发现可去重的薄板对"
      else
        Debug.log "  共去重 #{total_dropped} 对薄板"
      end

      items.reject { |it| drop_ids[it.face_id] }
    end
  end
end