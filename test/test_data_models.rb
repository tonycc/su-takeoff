require_relative 'test_helper'

module SuTakeoff
  class TestMaterialUsage < Minitest::Test
    def test_initializes_with_correct_defaults
      mu = MaterialUsage.new(space: '客厅', part: 'floor', material_name: '瓷砖')
      assert_equal '客厅', mu.space
      assert_equal 'floor', mu.part
      assert_equal '瓷砖', mu.material_name
      assert_equal 0.05, mu.waste_rate
      assert_equal 0.0, mu.net_area
    end

    def test_purchase_qty_calculation
      mu = MaterialUsage.new(space: '客厅', part: 'floor', material_name: '瓷砖',
                              net_area: 27.0, waste_rate: 0.05)
      assert_equal 28.35, mu.purchase_qty
    end

    def test_recalc_updates_purchase_qty
      mu = MaterialUsage.new(space: '客厅', part: 'floor', material_name: '瓷砖',
                              net_area: 10.0, waste_rate: 0.05)
      mu.net_area = 20.0
      mu.recalc!
      assert_equal 21.0, mu.purchase_qty
    end

    def test_to_h_returns_hash
      mu = MaterialUsage.new(space: '客厅', part: 'floor', material_name: '瓷砖',
                              net_area: 10.0, waste_rate: 0.05, spec: '600×600')
      h = mu.to_h
      assert_equal '客厅', h[:space]
      assert_equal 10.0, h[:net_area]
      assert_equal '600×600', h[:spec]
    end

    def test_sets_purchase_qty_on_init
      mu = MaterialUsage.new(space: '主卧', part: 'floor', material_name: '大理石',
                              net_area: 16.2, waste_rate: 0.08)
      assert_equal 17.5, mu.purchase_qty  # 16.2 * 1.08 = 17.496 → 17.5
    end

    def test_items_defaults_to_empty
      mu = MaterialUsage.new(space: 'X', part: 'wall', material_name: 'Y')
      assert_empty mu.items
    end
  end

  class TestScanItem < Minitest::Test
    def test_scan_item_creation
      item = ScanItem.new(1, 'marble', 5.0, 'm2', :face, [0,0,1], 2.0, 2.5, 'Layer0', ['客厅'], 1.5)
      assert_equal 1, item.face_id
      assert_equal 'marble', item.su_material
      assert_equal 5.0, item.qty
    end
  end

  class TestOpening < Minitest::Test
    def test_opening_creation
      op = Opening.new(10, 1.5, [1, 2])
      assert_equal 10, op.entity_id
      assert_equal 1.5, op.area
      assert_equal [1, 2], op.host_face_ids
    end
  end
end
