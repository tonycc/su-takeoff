require_relative 'test_helper'
require 'src/calculator'
require 'src/mapping'
require 'src/process_library'

module SuTakeoff
  # 真实户型场景：客厅 + 主卧 + 卫生间，含门窗洞口、踢脚线等
  class TestWallModel < Minitest::Test
    def setup
      @mapping = MaterialMapping.new
      @mapping.add('marble_01',  '爵士白大理石', '石材', 'm²', '大板',      0.08)
      @mapping.add('tile_302',   '马可波罗灰砖',   '瓷砖', 'm²', '600×600',  0.05)
      @mapping.add('paint_w',    '多乐士净味白',   '涂料', 'm²', '18L/桶',   0.05)
      @mapping.add('wood_oak',   '橡木复合地板',   '木材', 'm²', '1200×200', 0.05)
      @mapping.add('skirting',   '实木踢脚线',     '木材', 'm',  '80mm',     0.05)

      @processes = ProcessLibrary.new
      @processes.add_process('瓷砖', '密缝铺贴', 0.05)
      @processes.add_process('石材', '干挂',     0.08)
      @processes.add_process('木材', '悬浮铺装', 0.05)

      @calc = Calculator.new(@mapping, @processes)
    end

    # ================================================================
    # 构建真实户型数据
    # ================================================================

    # 房间尺寸: 客厅 8m×5m, 主卧 5m×4m, 卫生间 3m×2m
    #
    # 每面墙: width=墙长, height=层高2.8m
    # 天花/地面: width=房间宽, height=房间进深
    #
    # Z 坐标: 地面 z=0, 天花 z=2.8
    # 主卧在客厅的东侧, 卫生间在主卧南侧

    def living_floor
      ScanItem.new(1, 'marble_01', 40.0, 'm2', :face, [0,0,1], 8.0, 5.0, 'Layer0',
                   ['客厅'], [101], 0.02)
    end

    def living_ceiling
      ScanItem.new(2, 'paint_w', 40.0, 'm2', :face, [0,0,-1], 8.0, 5.0, 'Layer0',
                   ['客厅'], [101], 2.78)
    end

    # 客厅四面墙: 北(8m) 南(8m) 东(5m) 西(5m), 层高2.8m
    def living_wall_north
      ScanItem.new(3, 'paint_w', 22.4, 'm2', :face, [0,1,0], 8.0, 2.8, 'Layer0',
                   ['客厅'], [101], 1.4)
    end

    def living_wall_south
      ScanItem.new(4, 'paint_w', 22.4, 'm2', :face, [0,-1,0], 8.0, 2.8, 'Layer0',
                   ['客厅'], [101], 1.4)
    end

    def living_wall_east
      ScanItem.new(5, 'paint_w', 14.0, 'm2', :face, [1,0,0], 5.0, 2.8, 'Layer0',
                   ['客厅'], [101], 1.4)
    end

    def living_wall_west
      ScanItem.new(6, 'paint_w', 14.0, 'm2', :face, [-1,0,0], 5.0, 2.8, 'Layer0',
                   ['客厅'], [101], 1.4)
    end

    # 客厅踢脚线 — 绕墙一圈 (8+5)*2 = 26m, 高80mm 宽80mm → 长宽比 2.8/0.08 >15 → 线材
    def living_skirting
      face_ids = (7..10).to_a
      walls = [
        { id: 7,  w: 8.0, normal: [0,1,0],  cp: ['客厅'], cid: [101] },
        { id: 8,  w: 8.0, normal: [0,-1,0], cp: ['客厅'], cid: [101] },
        { id: 9,  w: 5.0, normal: [1,0,0],  cp: ['客厅'], cid: [101] },
        { id: 10, w: 5.0, normal: [-1,0,0], cp: ['客厅'], cid: [101] },
      ]
      walls.map do |w|
        ScanItem.new(w[:id], 'skirting', w[:w] * 0.08, 'm2', :face, w[:normal],
                     0.08, w[:w], 'Layer0', w[:cp], w[:cid], 0.04)
      end
    end

    # ---- 主卧 (5m × 4m, 层高2.8m) ----
    def bedroom_floor
      ScanItem.new(20, 'wood_oak', 20.0, 'm2', :face, [0,0,1], 5.0, 4.0, 'Layer0',
                   ['主卧'], [201], 0.02)
    end

    def bedroom_ceiling
      ScanItem.new(21, 'paint_w', 20.0, 'm2', :face, [0,0,-1], 5.0, 4.0, 'Layer0',
                   ['主卧'], [201], 2.78)
    end

    def bedroom_wall_north
      ScanItem.new(22, 'paint_w', 14.0, 'm2', :face, [0,1,0], 5.0, 2.8, 'Layer0',
                   ['主卧'], [201], 1.4)
    end

    def bedroom_wall_south
      ScanItem.new(23, 'paint_w', 14.0, 'm2', :face, [0,-1,0], 5.0, 2.8, 'Layer0',
                   ['主卧'], [201], 1.4)
    end

    def bedroom_wall_east
      ScanItem.new(24, 'paint_w', 11.2, 'm2', :face, [1,0,0], 4.0, 2.8, 'Layer0',
                   ['主卧'], [201], 1.4)
    end

    def bedroom_wall_west
      ScanItem.new(25, 'paint_w', 11.2, 'm2', :face, [-1,0,0], 4.0, 2.8, 'Layer0',
                   ['主卧'], [201], 1.4)
    end

    # ---- 卫生间 (3m × 2m, 层高2.8m) ----
    def bathroom_floor
      ScanItem.new(30, 'tile_302', 6.0, 'm2', :face, [0,0,1], 3.0, 2.0, 'Layer0',
                   ['卫生间'], [301], 0.02)
    end

    def bathroom_ceiling
      ScanItem.new(31, 'paint_w', 6.0, 'm2', :face, [0,0,-1], 3.0, 2.0, 'Layer0',
                   ['卫生间'], [301], 2.78)
    end

    def bathroom_wall_north
      ScanItem.new(32, 'tile_302', 8.4, 'm2', :face, [0,1,0], 3.0, 2.8, 'Layer0',
                   ['卫生间'], [301], 1.4)
    end

    def bathroom_wall_south
      ScanItem.new(33, 'tile_302', 8.4, 'm2', :face, [0,-1,0], 3.0, 2.8, 'Layer0',
                   ['卫生间'], [301], 1.4)
    end

    def bathroom_wall_east
      ScanItem.new(34, 'tile_302', 5.6, 'm2', :face, [1,0,0], 2.0, 2.8, 'Layer0',
                   ['卫生间'], [301], 1.4)
    end

    def bathroom_wall_west
      ScanItem.new(35, 'tile_302', 5.6, 'm2', :face, [-1,0,0], 2.0, 2.8, 'Layer0',
                   ['卫生间'], [301], 1.4)
    end

    # ================================================================
    # 组装全部模型数据
    # ================================================================

    def all_items
      [
        living_floor, living_ceiling,
        living_wall_north, living_wall_south, living_wall_east, living_wall_west,
        *living_skirting,
        bedroom_floor, bedroom_ceiling,
        bedroom_wall_north, bedroom_wall_south, bedroom_wall_east, bedroom_wall_west,
        bathroom_floor, bathroom_ceiling,
        bathroom_wall_north, bathroom_wall_south, bathroom_wall_east, bathroom_wall_west,
      ]
    end

    # 门窗洞口 — 客厅东墙窗户 + 客厅南墙门 + 主卧南墙窗户 + 主卧西墙门 + 卫生间东墙门
    def all_openings
      [
        Opening.new(100, 3.0,  [5]),    # 客厅东墙窗户 2m×1.5m
        Opening.new(101, 2.1,  [4]),    # 客厅南墙门 1m×2.1m
        Opening.new(200, 2.25, [23]),   # 主卧南墙窗户 1.5m×1.5m
        Opening.new(201, 2.1,  [25]),   # 主卧西墙门 1m×2.1m
        Opening.new(300, 1.68, [34]),   # 卫生间东墙门 0.8m×2.1m
      ]
    end

    # ================================================================
    # 测试用例
    # ================================================================

    def test_total_faces
      assert_equal 22, all_items.size
    end

    def test_total_openings
      assert_equal 5, all_openings.size
    end

    def test_all_mapped_materials_present
      result = @calc.compute(all_items, all_openings, {})
      refute_empty result, '至少应有已映射材质的结果'

      names = result.map(&:material_name).uniq
      assert_includes names, '爵士白大理石'
      assert_includes names, '多乐士净味白'
      assert_includes names, '马可波罗灰砖'
      assert_includes names, '橡木复合地板'
      assert_includes names, '实木踢脚线'
    end

    def test_living_room_marble_floor
      result = @calc.compute(all_items, all_openings, {})
      floor_usage = result.find { |u| u.space == '客厅' && u.part == 'floor' }

      refute_nil floor_usage
      assert_equal '爵士白大理石', floor_usage.material_name
      assert_in_delta 40.0, floor_usage.net_area, 0.01
      # 石材干挂损耗率 0.08 → 40 * 1.08 = 43.2
      assert_in_delta 43.2, floor_usage.purchase_qty, 0.01
    end

    def test_living_room_walls_with_opening_deduction
      result = @calc.compute(all_items, all_openings, {})

      # 客厅墙面: paint_w, 四面总计 22.4+22.4+14+14 = 72.8 m² 毛面积
      # 扣减: 南墙门 2.1m² + 东墙窗户 3.0m² = 5.1m²
      # 净面积 = 72.8 - 5.1 = 67.7m²
      living_walls = result.select { |u| u.space == '客厅' && u.part == 'wall' && u.material_name == '多乐士净味白' }
      refute_empty living_walls
      net = living_walls.sum(&:net_area).round(2)
      assert_in_delta 67.7, net, 0.05
    end

    def test_bedroom_wood_floor
      result = @calc.compute(all_items, all_openings, {})
      floor_usage = result.find { |u| u.space == '主卧' && u.part == 'floor' }

      refute_nil floor_usage
      assert_equal '橡木复合地板', floor_usage.material_name
      assert_in_delta 20.0, floor_usage.net_area, 0.01
      # 木材悬浮铺装损耗率 0.05 → 20 * 1.05 = 21.0
      assert_in_delta 21.0, floor_usage.purchase_qty, 0.01
    end

    def test_bedroom_walls_with_opening_deduction
      result = @calc.compute(all_items, all_openings, {})

      # 主卧墙面: 北14 + 南14 + 东11.2 + 西11.2 = 50.4 m² 毛面积
      # 扣减: 南墙窗户 2.25m² + 西墙门 2.1m² = 4.35m²
      # 净面积 = 50.4 - 4.35 = 46.05m²
      bedroom_walls = result.select { |u| u.space == '主卧' && u.part == 'wall' && u.material_name == '多乐士净味白' }
      refute_empty bedroom_walls
      net = bedroom_walls.sum(&:net_area).round(2)
      assert_in_delta 46.05, net, 0.05
    end

    def test_bathroom_full_tile
      result = @calc.compute(all_items, all_openings, {})

      # 卫生间: 地面 6m² marble → tile_302, 墙面 8.4+8.4+5.6+5.6 = 28m² tile_302
      # 扣减: 东墙门 1.68m² → 净墙面 = 28 - 1.68 = 26.32m²
      # 天花: paint_w 6m²

      bathroom_floor = result.find { |u| u.space == '卫生间' && u.part == 'floor' }
      refute_nil bathroom_floor
      assert_equal '马可波罗灰砖', bathroom_floor.material_name
      assert_in_delta 6.0, bathroom_floor.net_area, 0.01
      # 瓷砖密缝铺贴损耗率 0.05 → 6 * 1.05 = 6.3
      assert_in_delta 6.3, bathroom_floor.purchase_qty, 0.01

      bathroom_walls = result.select { |u| u.space == '卫生间' && u.part == 'wall' && u.material_name == '马可波罗灰砖' }
      net_wall = bathroom_walls.sum(&:net_area).round(2)
      assert_in_delta 26.32, net_wall, 0.05
    end

    def test_bathroom_ceiling_paint
      result = @calc.compute(all_items, all_openings, {})
      ceiling = result.find { |u| u.space == '卫生间' && u.part == 'ceiling' }

      refute_nil ceiling
      assert_equal '多乐士净味白', ceiling.material_name
      assert_in_delta 6.0, ceiling.net_area, 0.01
    end

    def test_total_paint_wall_area_across_all_rooms
      result = @calc.compute(all_items, all_openings, {})

      # 客厅墙面净 67.7 + 主卧墙面净 46.05 = 113.75 m² paint_w
      all_paint_walls = result.select { |u| u.part == 'wall' && u.material_name == '多乐士净味白' }
      net_paint = all_paint_walls.sum(&:net_area).round(2)
      assert_in_delta 113.75, net_paint, 0.1
    end

    def test_skirting_linear_material
      result = @calc.compute(all_items, all_openings, {})

      # 踢脚线: unit == 'm', 累加 height (即墙面长度)
      # 客厅四面踢脚线: 8+8+5+5 = 26m
      skirtings = result.select { |u| u.material_name == '实木踢脚线' }
      refute_empty skirtings, '踢脚线应被识别为线材并计入结果'

      total_length = skirtings.sum(&:net_area).round(2)
      assert_in_delta 26.0, total_length, 0.01
    end

    def test_group_by_material_aggregation
      result = @calc.compute(all_items, all_openings, {})
      groups = @calc.group_by_material(result)

      # 涂料（多乐士净味白）应覆盖三个房间的天花 + 两个房间的墙面
      assert groups.key?('多乐士净味白')
      # 客厅天花40 + 主卧天花20 + 卫生间天花6 + 墙面净 ≈ 113.75 = ~179.75
      paint_net = groups['多乐士净味白'][:net_area]
      assert_in_delta 179.75, paint_net, 1.0

      # 瓷砖（马可波罗灰砖）应覆盖卫生间全部
      assert groups.key?('马可波罗灰砖')
      tile_net = groups['马可波罗灰砖'][:net_area]
      assert_in_delta 32.32, tile_net, 0.5 # 地面6 + 墙面净26.32

      # 石材（爵士白大理石）仅客厅地面
      assert groups.key?('爵士白大理石')
      assert_in_delta 40.0, groups['爵士白大理石'][:net_area], 0.01
    end

    def test_material_count_in_result
      result = @calc.compute(all_items, all_openings, {})

      # 材料种类: 爵士白大理石(1) + 多乐士净味白(3 ceiling + 2 wall) + 马可波罗灰砖(2) + 橡木复合地板(1) + 实木踢脚线(1)
      # = 至少 10 条 usage
      assert result.size >= 9, "应为 9+ 条 usage，实际 #{result.size} 条"
    end

    def test_component_path_preserved
      result = @calc.compute(all_items, [], {})

      living_usages = result.select { |u| u.space == '客厅' }
      refute_empty living_usages
      assert_equal '客厅', living_usages.first.space
    end

    def test_ceiling_paint_in_all_rooms
      result = @calc.compute(all_items, all_openings, {})

      %w[客厅 主卧 卫生间].each do |room|
        ceiling = result.find { |u| u.space == room && u.part == 'ceiling' }
        refute_nil ceiling, "#{room} 应有天花"
        assert_equal '多乐士净味白', ceiling.material_name, "#{room} 天花应为涂料"
      end
    end

    def test_no_ceiling_openings_deduction
      # 天花不应有洞口扣减（洞口在墙上）
      result = @calc.compute(all_items, all_openings, {})
      result.select { |u| u.part == 'ceiling' }.each do |ceiling|
        assert_equal ceiling.net_area, ceiling.net_area, "#{ceiling.space} 天花不应被扣减"
      end
    end

    def test_face_id_uniqueness
      ids = all_items.map(&:face_id)
      assert_equal ids.uniq.size, ids.size, '所有面的 face_id 应唯一'
    end
  end
end
