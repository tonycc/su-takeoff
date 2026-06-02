require_relative 'test_helper'

module SuTakeoff
  class TestScanItem < Minitest::Test
    def test_scan_item_creation
      item = ScanItem.face(
        face_id: 1, su_material: 'marble', area: 5.0,
        normal: [0, 0, 1], width: 2.0, height: 2.5,
        layer_name: 'Layer0', component_path: ['客厅'], component_path_ids: [101],
        z_center: 1.5
      )
      assert_equal 1, item.face_id
      assert_equal 'marble', item.su_material
      assert_equal 5.0, item.qty
      assert_equal [101], item.component_path_ids
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
