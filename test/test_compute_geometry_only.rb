require_relative 'test_helper'
require 'src/calculator'
require 'src/component_mapping'
require 'src/takeoff_policy'

module SuTakeoff
  # Calculator 的新职责只剩两件事：
  #   1. 薄板去重
  #   2. 走 Policy 决议每个 item 的 method/source/unit
  # 量纲累加、洞口扣减由 Presenter 负责，本测试只关心决议层面。
  class TestComputeGeometryOnly < Minitest::Test
    def setup
      @cm = ComponentMapping.new
      @cm.add('lamp_01', '台灯', '灯具', '个', '', 0.0, 'aggregate')

      @policy = TakeoffPolicy.new
      @calc = Calculator.new(@cm, policy: @policy)
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
      # mapping 档已移除：无标签/无图层规则的普通面积面落到启发兜底，
      # source 由 :mapping 变为 :heuristic（计量方式仍是 :area，量不变）。
      assert_equal :heuristic, geo[0][:source]
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
      calc = Calculator.new(@cm)  # 不传 policy，走启发兜底
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
  end
end
