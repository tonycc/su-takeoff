require_relative 'test_helper'
require 'src/calculator'
require 'src/mapping'
require 'src/process_library'

module SuTakeoff
  class TestCalculator < Minitest::Test
    def setup
      @mapping = MaterialMapping.new
      @mapping.add('marble_01', '爵士白大理石', '石材', 'm²', '大板', 0.08)
      @mapping.add('tile_302', '马可波罗灰砖', '瓷砖', 'm²', '600×600', 0.05)
      @mapping.add('paint_w', '多乐士净味白', '涂料', 'm²', '18L/桶', 0.05)

      @processes = ProcessLibrary.new
      @processes.add_process('瓷砖', '密缝铺贴', 0.05)
      @processes.add_process('石材', '干挂', 0.08)

      @calc = Calculator.new(@mapping, @processes)
    end

    def test_group_by_space_and_part
      items = [
        ScanItem.new(1, 'tile_302', 15.0, [0,0,1], 3, 5, 'Layer0', ['客厅']),
        ScanItem.new(2, 'tile_302', 12.0, [0,0,1], 3, 4, 'Layer0', ['客厅']),
        ScanItem.new(3, 'paint_w', 48.5, [0,1,0], 3, 5, 'Layer0', ['客厅']),
      ]
      result = @calc.compute(items, [], {})

      floor_usages = result.select { |u| u.space == '客厅' && u.part == 'floor' }
      assert_equal 1, floor_usages.size
      assert_equal 27.0, floor_usages[0].net_area
      assert_equal '马可波罗灰砖', floor_usages[0].material_name
    end

    def test_apply_waste_rate_from_process
      items = [
        ScanItem.new(1, 'tile_302', 100.0, [0,0,1], 10, 10, 'Layer0', ['客厅']),
      ]
      result = @calc.compute(items, [], { 'tile_302' => '斜铺' })
      # 斜铺 not found in process library for 瓷砖 (only 密缝铺贴/干挂 exist)
      # falls back to default_waste_rate 0.05 → purchase_qty = 105.0
      assert_equal 105.0, result[0].purchase_qty
    end

    def test_deduct_openings
      items = [
        ScanItem.new(1, 'paint_w', 50.0, [0,1,0], 5, 10, 'Layer0', ['客厅']),
      ]
      openings = [Opening.new(10, 2.0, [1])]  # 2m² opening on face 1
      result = @calc.compute(items, openings, {})
      wall = result.find { |u| u.part == 'wall' }
      refute_nil wall
      assert_in_delta 48.0, wall.net_area, 0.01  # 50 - 2 = 48
    end

    def test_unmapped_materials_excluded
      items = [
        ScanItem.new(1, 'unknown_mat', 10.0, [0,0,1], 2, 5, 'Layer0', ['客厅']),
      ]
      result = @calc.compute(items, [], {})
      assert result.empty?  # unmapped materials excluded from stats
    end

    def test_group_by_material
      items = [
        ScanItem.new(1, 'tile_302', 27.0, [0,0,1], 3, 9, 'Layer0', ['客厅']),
        ScanItem.new(2, 'tile_302', 20.0, [0,0,1], 4, 5, 'Layer0', ['主卧']),
      ]
      result = @calc.compute(items, [], {})
      material_groups = @calc.group_by_material(result)
      assert material_groups.key?('马可波罗灰砖')
      assert_in_delta 47.0, material_groups['马可波罗灰砖'][:net_area], 0.01
    end

    def test_face_orientation_floor
      assert_equal 'floor', Calculator.face_orientation([0, 0, 1])
    end

    def test_face_orientation_wall
      assert_equal 'wall', Calculator.face_orientation([0, 1, 0])
    end

    def test_face_orientation_ceiling
      assert_equal 'ceiling', Calculator.face_orientation([0, 0, -1])
    end
  end
end
