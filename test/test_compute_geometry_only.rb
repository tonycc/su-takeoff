require_relative 'test_helper'
require 'src/calculator'
require 'src/takeoff_policy'

module SuTakeoff
  # Calculator 的新职责只剩两件事：
  #   1. 薄板去重
  #   2. 走 Policy 决议每个 item 的 method/source/unit
  # 量纲累加、洞口扣减由 Presenter 负责，本测试只关心决议层面。
  class TestComputeGeometryOnly < Minitest::Test
    def setup
      @policy = TakeoffPolicy.new
      @calc = Calculator.new(policy: @policy)
    end

    def test_basic_area
      items = [
        ScanItem.face(face_id: 1, su_material: 'tile_302', area: 100.0,
                      normal: [0,0,1], width: 10, height: 10,
                      layer_name: 'Layer0', component_path: ['客厅'], component_path_ids: [101]),
      ]
      geo = @calc.compute_geometry_only(items, [])
      assert_equal 1, geo.size
      assert_equal :area, geo[0][:method]
      # 普通面是确定性的面积默认值，不应被标为待确认启发。
      assert_equal :default, geo[0][:source]
      assert_equal 'm²', geo[0][:unit]
      assert_equal 'tile_302', geo[0][:item].su_material
    end

    def test_instance_counting
      items = [
        ScanItem.instance(face_id: 100, su_material: 'lamp_01', unit: '个',
                          layer_name: 'Layer0', component_path: ['客厅'], component_path_ids: [103]),
      ]
      geo = @calc.compute_geometry_only(items, [])
      assert_equal 1, geo.size
      assert_equal :count, geo[0][:method]
      assert_equal '个', geo[0][:unit]
    end

    def test_linear_length
      items = [
        ScanItem.face(face_id: 1, su_material: 'skirting_m', area: 2.0,
                      normal: [0,1,0], width: 0.02, height: 10,
                      layer_name: 'Layer0', component_path: ['客厅'], component_path_ids: [101],
                      z_center: 0.5),
      ]
      geo = @calc.compute_geometry_only(items, [])
      assert_equal 1, geo.size
      assert_equal :length, geo[0][:method]
      # 启发判定线材后，unit 走 SolidLinear 默认 'm'
      assert_equal 'm', geo[0][:unit]
    end

    def test_nil_material_skipped
      items = [
        ScanItem.face(face_id: 1, su_material: nil, area: 10.0,
                      normal: [0,0,1], width: 2, height: 5,
                      layer_name: 'Layer0', component_path: ['客厅'], component_path_ids: [101]),
      ]
      geo = @calc.compute_geometry_only(items, [])
      assert_empty geo
    end

    def test_skip_method_filtered_out
      # AttrDict 标记 skip 的 item 不应出现在结果中
      item = ScanItem.face(
        face_id: 1, su_material: 'marble_01', area: 5.0,
        normal: [0, 1, 0], width: 2.0, height: 2.5,
        layer_name: 'Layer0', component_path: ['客厅'], component_path_ids: [101],
        tags: { method: 'skip' }
      )
      geo = @calc.compute_geometry_only([item], [])
      assert_empty geo
    end

    # ---- 决议结果不再依赖 policy 时的兼容路径 ----

    def test_no_policy_unmapped_uses_heuristic_fallback
      calc = Calculator.new  # 不传 policy，走启发兜底
      # 长宽比 16，启发为线材
      items = [
        ScanItem.face(face_id: 1, su_material: 'unknown', area: 1.0,
                      normal: [0,1,0], width: 0.05, height: 0.8,
                      layer_name: 'Layer0', component_path: ['客厅'], component_path_ids: [101]),
      ]
      geo = calc.compute_geometry_only(items, [])
      assert_equal :length, geo[0][:method]
      assert_equal 'm', geo[0][:unit]
    end

    def test_disabled_heuristics_never_classifies_horizontal_narrow_face_as_length
      policy = TakeoffPolicy.new(heuristics_enabled: false)
      calc = Calculator.new(policy: policy)
      item = ScanItem.face(
        face_id: 9, su_material: 'unknown', area: 0.4,
        normal: [0, 0, 1], width: 0.05, height: 8.0,
        layer_name: 'Layer0', component_path: ['楼板'], component_path_ids: [10]
      )

      result = calc.compute_geometry_only([item], [])

      assert_equal :area, result.first[:method]
      assert_equal :default, result.first[:source]
    end

    def test_horizontal_slab_dedup_requires_spatial_overlap
      faces = [0.0, 20.0].map.with_index do |center_x, index|
        ScanItem.face(
          face_id: index + 1, su_material: '地砖', area: 4.0,
          normal: index.zero? ? [0, 0, 1] : [0, 0, -1],
          width: 2.0, height: 2.0, layer_name: 'Layer0',
          component_path: ['空间'], component_path_ids: [10],
          z_center: 0.05, center_x: center_x, center_y: 0.0
        )
      end

      assert_equal 2, @calc.compute_geometry_only(faces, []).size
    end

    def test_horizontal_slab_dedup_removes_only_one_overlapping_side
      faces = [1, -1].map.with_index do |normal_z, index|
        ScanItem.face(
          face_id: index + 1, su_material: '地砖', area: 4.0,
          normal: [0, 0, normal_z], width: 2.0, height: 2.0,
          layer_name: 'Layer0', component_path: ['空间'], component_path_ids: [10],
          z_center: index * 0.05, center_x: 0.0, center_y: 0.0
        )
      end

      assert_equal 1, @calc.compute_geometry_only(faces, []).size
    end
  end
end
