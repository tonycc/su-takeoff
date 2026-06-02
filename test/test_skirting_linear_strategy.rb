require_relative 'test_helper'

module SuTakeoff
  class TestSkirtingLinearStrategy < Minitest::Test
    def make_face_item(layer: 'L0')
      ScanItem.face(
        face_id: 1, su_material: 'sk', area: 1.0,
        normal: [0,1,0], width: 0.1, height: 5.0,
        layer_name: layer, component_path: ['R'], component_path_ids: [1]
      )
    end

    def test_basic_attrs
      s = Strategies::SkirtingLinear.new
      assert_equal :skirting_linear, s.name
      assert_equal :length, s.method
      assert_equal 'm', s.default_unit
    end

    def test_match_rules_present
      s = Strategies::SkirtingLinear.new
      rules = s.match_rules
      assert_equal ['踢脚', 'skirting'], rules[:definition_name_includes]
      assert_equal ['踢脚线'], rules[:layer]
    end

    def test_matches_skirting_definition_name
      s = Strategies::SkirtingLinear.new
      assert s.matches?(make_face_item, definition_name: '主卧踢脚线-001')
      assert s.matches?(make_face_item, definition_name: 'wood_skirting_v2')
      refute s.matches?(make_face_item, definition_name: '墙面')
    end

    def test_matches_skirting_layer
      s = Strategies::SkirtingLinear.new
      assert s.matches?(make_face_item(layer: '踢脚线'), {})
      refute s.matches?(make_face_item(layer: 'Layer0'), {})
    end

    def test_aggregate_sums_qty_length
      a = ScanItem.linear_solid(
        face_id: 1, su_material: 'sk', length: 5.0,
        layer_name: 'L0', component_path: ['R'], component_path_ids: [1]
      )
      b = ScanItem.linear_solid(
        face_id: 2, su_material: 'sk', length: 3.5,
        layer_name: 'L0', component_path: ['R'], component_path_ids: [1]
      )
      assert_in_delta 8.5, Strategies::SkirtingLinear.new.aggregate([a, b], {}), 0.001
    end

    def test_compute_length_uses_edge_based
      # L 型：3m + 2m，EdgeBased 累加 = 5m
      ctx = {
        edges: [
          { dkey: [1,0,0], len: 3.0 },
          { dkey: [0,1,0], len: 2.0 },
        ]
      }
      result = Strategies::SkirtingLinear.new.compute_length(nil, ctx)
      assert_in_delta 5.0, result, 0.001
    end

    def test_registered_in_builtin
      # 验证 Builtin 注册后 SkirtingLinear 已加入 Registry（无 default_for）
      assert_kind_of Strategies::SkirtingLinear, Strategies::Registry.get(:skirting_linear)
      # default for :length 应仍是 SolidLinear（SkirtingLinear 没有设 default）
      assert_equal :solid_linear, Strategies::Registry.default_for(:length).name
    end
  end
end
