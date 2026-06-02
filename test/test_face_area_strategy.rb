require_relative 'test_helper'
require 'src/strategies/base'
require 'src/strategies/face_area'

module SuTakeoff
  class TestFaceAreaStrategy < Minitest::Test
    def test_basic_attrs
      s = Strategies::FaceArea.new
      assert_equal :face_area, s.name
      assert_equal :area, s.method
      assert_equal 'm²', s.default_unit
    end

    def test_aggregate_sums_qty_with_opening_deduction
      items = [
        ScanItem.face(face_id: 1, su_material: 'paint', area: 20.0,
                      normal: [0,1,0], width: 5, height: 4,
                      layer_name: 'L0', component_path: ['R1'], component_path_ids: [1]),
        ScanItem.face(face_id: 2, su_material: 'paint', area: 10.0,
                      normal: [0,1,0], width: 5, height: 2,
                      layer_name: 'L0', component_path: ['R1'], component_path_ids: [1]),
      ]
      ctx = { opening_area_by_face: { 1 => 3.0 } }   # face_id=1 扣 3.0
      assert_in_delta 27.0, Strategies::FaceArea.new.aggregate(items, ctx), 0.001
    end

    def test_aggregate_handles_missing_opening_map
      items = [
        ScanItem.face(face_id: 1, su_material: 'paint', area: 5.0,
                      normal: [0,1,0], width: 1, height: 5,
                      layer_name: 'L0', component_path: ['R1'], component_path_ids: [1]),
      ]
      assert_in_delta 5.0, Strategies::FaceArea.new.aggregate(items, {}), 0.001
    end

    def test_aggregate_clamps_negative_to_zero
      # 洞口面积比面积还大 → 净 0，不为负
      items = [
        ScanItem.face(face_id: 1, su_material: 'paint', area: 2.0,
                      normal: [0,1,0], width: 1, height: 2,
                      layer_name: 'L0', component_path: ['R1'], component_path_ids: [1]),
      ]
      ctx = { opening_area_by_face: { 1 => 5.0 } }
      assert_in_delta 0.0, Strategies::FaceArea.new.aggregate(items, ctx), 0.001
    end
  end
end
