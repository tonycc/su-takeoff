require_relative 'test_helper'
require 'src/calculator'
require 'src/mapping'
require 'src/process_library'
require 'src/component_mapping'

module SuTakeoff
  class TestComputeGeometryOnly < Minitest::Test
    def setup
      @mapping = MaterialMapping.new
      @mapping.add('marble_01', '爵士白大理石', '石材', 'm²', '大板', 0.08)
      @mapping.add('tile_302', '马可波罗灰砖', '瓷砖', 'm²', '600×600', 0.05)
      @mapping.add('paint_w', '多乐士净味白', '涂料', 'm²', '18L/桶', 0.05)
      @mapping.add('skirting_m', '踢脚线', '木材', 'm', '80mm', 0.05)

      @processes = ProcessLibrary.new
      @processes.add_process('瓷砖', '密缝铺贴', 0.05)
      @processes.add_process('石材', '干挂', 0.08)

      @cm = ComponentMapping.new
      @cm.add('lamp_01', '台灯', '灯具', '个', '', 0.0, 'aggregate')

      @calc = Calculator.new(@mapping, @processes, @cm)
    end

    def test_purchase_qty_equals_net_area
      items = [
        ScanItem.new(1, 'tile_302', 100.0, 'm2', :face, [0,0,1], 10, 10, 'Layer0', ['客厅'], [101], 0),
      ]
      geo = @calc.compute_geometry_only(items, [])
      assert_equal 1, geo.size
      assert_in_delta geo[0].net_area, geo[0].purchase_qty, 0.01
    end

    def test_waste_rate_is_zero
      items = [
        ScanItem.new(1, 'marble_01', 50.0, 'm2', :face, [0,0,1], 5, 10, 'Layer0', ['客厅'], [101], 0),
      ]
      geo = @calc.compute_geometry_only(items, [])
      assert_equal 0, geo[0].waste_rate
    end

    def test_no_derivation_items
      # 涂料 category has a process that could produce derivations
      # but compute_geometry_only should not fan-out
      @processes.add_process('涂料', '乳胶漆', 0.05, [
        Derivation.new(layer: '底漆', unit: 'm²', formula: 'area*0.3', waste_rate: 0.02, category: '涂料')
      ])
      items = [
        ScanItem.new(1, 'paint_w', 50.0, 'm2', :face, [0,1,0], 5, 10, 'Layer0', ['客厅'], [101], 1.5),
      ]
      geo = @calc.compute_geometry_only(items, [])
      # Only primary item, no derivation fan-out
      assert_equal 1, geo.size
      assert_equal '', geo[0].layer
    end

    def test_opening_deduction_still_works
      items = [
        ScanItem.new(1, 'paint_w', 50.0, 'm2', :face, [0,1,0], 5, 10, 'Layer0', ['客厅'], [101], 1.5),
      ]
      openings = [Opening.new(10, 2.0, [1])]
      geo = @calc.compute_geometry_only(items, openings)
      wall = geo.find { |u| u.part == 'wall' }
      refute_nil wall
      assert_in_delta 48.0, wall.net_area, 0.01
    end

    def test_unmapped_materials_included
      items = [
        ScanItem.new(1, 'unknown_mat', 10.0, 'm2', :face, [0,0,1], 2, 5, 'Layer0', ['客厅'], [101], 0),
      ]
      geo = @calc.compute_geometry_only(items, [])
      assert_equal 1, geo.size
      assert_equal 'unknown_mat', geo[0].su_material_name
      assert_equal '', geo[0].material_name
      assert_equal 'm²', geo[0].unit
      assert_in_delta 10.0, geo[0].net_area, 0.01
    end

    def test_instance_counting
      items = [
        ScanItem.new(100, 'lamp_01', 1, '个', :instance, nil, 0, 0, 'Layer0', ['客厅'], [103], 0),
      ]
      geo = @calc.compute_geometry_only(items, [])
      assert_equal 1, geo.size
      assert_equal '个', geo[0].unit
      assert_in_delta 1, geo[0].net_area, 0.01
    end

    def test_linear_length
      items = [
        ScanItem.new(1, 'skirting_m', 2.0, 'm', :face, [0,1,0], 0.02, 10, 'Layer0', ['客厅'], [101], 0.5),
      ]
      geo = @calc.compute_geometry_only(items, [])
      assert_equal 1, geo.size
      assert_equal 'm', geo[0].unit
    end
  end
end