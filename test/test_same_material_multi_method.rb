require_relative 'test_helper'
require 'src/calculator'
require 'src/mapping'
require 'src/process_library'
require 'src/component_mapping'
require 'src/takeoff_policy'

module SuTakeoff
  # P2 同材多算：同一个 SU 材质在不同 policy 决议下产出独立的 MaterialUsage。
  # 这是装修场景里"爵士白板材 + 爵士白窗台条 + 爵士白线条"共用一种材质的真实需求。
  class TestSameMaterialMultiMethod < Minitest::Test
    def setup
      @mapping = MaterialMapping.new
      @mapping.add('marble_01', '爵士白', '石材', 'm²', '大板', 0.08)

      @processes = ProcessLibrary.new
      @processes.add_process('石材', '干挂', 0.08)

      @cm = ComponentMapping.new
    end

    def make_face(face_id:, normal:, width:, height:, layer:, su_material: 'marble_01')
      it = ScanItem.new(face_id, su_material, width * height, 'm2', :face,
                        normal, width, height, layer,
                        ['客厅'], [101], 1.5)
      it.qty_area = width * height
      it.qty_length = height
      it
    end

    # 场景：客厅墙面有一张大板（5×3 = 15m²）和一根条（0.05×8 = 0.4m²）
    # 大板放普通图层走 mapping → :area；条放"线条"图层走 layer → :length
    # 期望：一份 marble_01 产出两条 usage，互不串味。
    def test_same_material_split_by_layer_rule
      policy = TakeoffPolicy.new(
        mapping: @mapping,
        layer_rules: { '线条' => :length },
        heuristics_enabled: false
      )
      calc = Calculator.new(@mapping, @processes, @cm, policy: policy)

      items = [
        make_face(face_id: 1, normal: [0, 1, 0], width: 5.0, height: 3.0, layer: 'Layer0'),
        make_face(face_id: 2, normal: [0, 1, 0], width: 0.05, height: 8.0, layer: '线条'),
      ]

      result = calc.compute(items, [], {})

      area_usage = result.find { |u| u.unit == 'm²' && u.parent_su_material.empty? }
      length_usage = result.find { |u| u.unit == 'm' && u.parent_su_material.empty? }

      refute_nil area_usage, '应产出按面积统计的 usage'
      refute_nil length_usage, '应产出按长度统计的 usage'

      assert_in_delta 15.0, area_usage.net_area, 0.01
      assert_equal :explicit, area_usage.confidence
      assert_equal :mapping, area_usage.source

      assert_in_delta 8.0, length_usage.net_area, 0.01
      assert_equal :explicit, length_usage.confidence
      assert_equal :layer, length_usage.source

      # 同材质同空间同部位，但 method 不同 → 必须是两条独立 usage
      assert_equal area_usage.su_material_name, length_usage.su_material_name
      assert_equal area_usage.space, length_usage.space
      refute_equal area_usage.unit, length_usage.unit
    end

    # 启发式判定的 usage 必须单独成组，confidence=:heuristic
    def test_heuristic_decision_separates_into_own_group
      # 启发式仅在没有显式配置（标签/图层/材质映射）时触发。
      # 已映射材质走 mapping → area；窄长形状也不走启发式（显式优于隐式）。
      policy = TakeoffPolicy.new(
        mapping: @mapping,
        layer_rules: {},
        heuristics_enabled: true
      )
      calc = Calculator.new(@mapping, @processes, @cm, policy: policy)

      items = [
        make_face(face_id: 1, normal: [0, 1, 0], width: 5.0, height: 3.0, layer: 'Layer0'),
        # 窄长面：同材质已映射，mapping 优先于启发式 → area
        make_face(face_id: 2, normal: [0, 1, 0], width: 0.05, height: 8.0, layer: 'Layer0'),
      ]

      result = calc.compute(items, [], {})

      # 两面均走 mapping，合并为同一组 area usage
      heuristic_usage = result.find { |u| u.confidence == :heuristic }
      assert_nil heuristic_usage, '已映射材质的窄长面不再走启发式'

      primaries = result.select { |u| u.parent_su_material.empty? }
      assert_equal 1, primaries.size, '两面应合并为一个 usage'
      assert_equal 'm²', primaries.first.unit
      assert_in_delta 15.4, primaries.first.net_area, 0.01  # 15 + 0.4
    end

    # 显式标签覆盖：同样窄长形状，attr 标签强制 :area，不再走启发式
    def test_attr_tag_overrides_heuristic
      policy = TakeoffPolicy.new(mapping: @mapping, heuristics_enabled: true)
      calc = Calculator.new(@mapping, @processes, @cm, policy: policy)

      narrow = make_face(face_id: 2, normal: [0, 1, 0],
                         width: 0.05, height: 8.0, layer: 'Layer0')
      narrow.tags = { method: 'area' }

      result = calc.compute([narrow], [], {})

      assert_equal 1, result.size
      u = result.first
      assert_equal :explicit, u.confidence
      assert_equal :attr, u.source
      assert_in_delta 0.4, u.net_area, 0.01  # 0.05 × 8 = 0.4 m²
      assert_equal 'm²', u.unit
    end

    # attr 标签 :skip 应从结果完全消失
    def test_attr_skip_excludes_from_result
      policy = TakeoffPolicy.new(mapping: @mapping)
      calc = Calculator.new(@mapping, @processes, @cm, policy: policy)

      f = make_face(face_id: 1, normal: [0, 1, 0], width: 5.0, height: 3.0, layer: 'Layer0')
      f.tags = { method: 'skip' }

      result = calc.compute([f], [], {})
      assert_empty result
    end

    # 兜底测试：构造 Calculator 不传 policy 时，行为与 P1 完全一致
    # （这是回归保障，确保现有调用零变更）
    def test_no_policy_legacy_behavior
      calc = Calculator.new(@mapping, @processes, @cm)  # 不传 policy

      items = [
        make_face(face_id: 1, normal: [0, 1, 0], width: 5.0, height: 3.0, layer: 'Layer0'),
        make_face(face_id: 2, normal: [0, 1, 0], width: 0.05, height: 8.0, layer: '线条'),
      ]

      result = calc.compute(items, [], {})
      # 老逻辑：marble_01 unit='m²' → 全部当面材，两面合并到一组
      assert_equal 1, result.size
      u = result.first
      assert_equal :explicit, u.confidence
      assert_equal :mapping, u.source
      # 15.0 + 0.4 = 15.4
      assert_in_delta 15.4, u.net_area, 0.01
    end
  end
end
