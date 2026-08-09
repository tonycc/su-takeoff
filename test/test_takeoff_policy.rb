require_relative 'test_helper'
require 'src/takeoff_policy'

module SuTakeoff
  class TestTakeoffPolicy < Minitest::Test
    # 构造一个 :face ScanItem。所有调用都使用默认 kind: :face。
    # su_material 仅作为标签保留，不再参与 policy 决议（材料映射已移除）。
    def make_item(su_material: 'marble_01',
                  normal: [0, 1, 0], width: 5.0, height: 3.0,
                  layer_name: 'Layer0', tags: nil)
      ScanItem.face(
        face_id: 1, su_material: su_material,
        area: width * height, normal: normal,
        width: width, height: height,
        layer_name: layer_name,
        component_path: ['客厅'], component_path_ids: [101],
        z_center: 1.5, tags: tags
      )
    end

    # ---- 优先级 1: AttrDict ----

    def test_attr_dict_overrides_everything
      policy = TakeoffPolicy.new(layer_rules: { 'Layer0' => :area })
      item = make_item(tags: { method: 'length' })
      r = policy.resolve(item)
      assert_equal :length, r.method
      assert_equal :attr, r.source
    end

    def test_attr_dict_skip
      policy = TakeoffPolicy.new
      item = make_item(tags: { method: 'skip' })
      r = policy.resolve(item)
      assert_equal :skip, r.method
      assert_equal :attr, r.source
    end

    def test_attr_dict_invalid_method_falls_through
      policy = TakeoffPolicy.new
      item = make_item(tags: { method: 'bogus' })
      r = policy.resolve(item)
      # 无效 method 不命中任何档 → default skip（材料映射已移除）
      assert_equal :skip, r.method
      assert_equal :default, r.source
    end

    # ---- 优先级 2: layer_rules ----

    def test_layer_rule_length
      policy = TakeoffPolicy.new(layer_rules: { '线条' => :length })
      item = make_item(layer_name: '线条')
      r = policy.resolve(item)
      assert_equal :length, r.method
      assert_equal :layer, r.source
    end

    def test_layer_rule_string_value_normalized
      policy = TakeoffPolicy.new(layer_rules: { '线条' => 'length' })
      item = make_item(layer_name: '线条')
      assert_equal :length, policy.resolve(item).method
    end

    def test_layer_rule_unknown_layer_falls_through
      policy = TakeoffPolicy.new(layer_rules: { '线条' => :length })
      item = make_item(layer_name: 'Layer0')
      r = policy.resolve(item)
      # 无规则命中 → default skip（材料映射已移除）
      assert_equal :skip, r.method
      assert_equal :default, r.source
    end

    def test_layer_rule_invalid_method_dropped
      policy = TakeoffPolicy.new(layer_rules: { 'Layer0' => :bogus })
      item = make_item(layer_name: 'Layer0')
      r = policy.resolve(item)
      # 规则被 normalize 丢弃 → default skip
      assert_equal :skip, r.method
      assert_equal :default, r.source
    end

    # ---- 优先级 4: 启发式（弱信号，仅产生待确认建议）----

    def test_heuristic_recognizes_narrow_vertical_face
      policy = TakeoffPolicy.new
      # 0.05m 短边 + 8m 长边，长宽比 160 → 命中
      item = make_item(su_material: 'unknown', normal: [0, 1, 0],
                       width: 0.05, height: 8.0)
      r = policy.resolve(item)
      assert_equal :length, r.method
      assert_equal :heuristic, r.source
    end

    def test_heuristic_excludes_horizontal_face
      policy = TakeoffPolicy.new
      # 顶面，即使形状窄长也不应被判线材
      item = make_item(su_material: 'unknown', normal: [0, 0, 1],
                       width: 0.05, height: 8.0)
      r = policy.resolve(item)
      assert_equal :skip, r.method
    end

    def test_heuristic_excludes_wide_face
      policy = TakeoffPolicy.new
      # 短边 0.5m > 阈值 0.2m，不算线材（窗台板那种）
      item = make_item(su_material: 'unknown', normal: [0, 1, 0],
                       width: 0.5, height: 9.0)
      r = policy.resolve(item)
      assert_equal :skip, r.method
    end

    def test_heuristic_excludes_low_aspect_ratio
      policy = TakeoffPolicy.new
      # 长宽比 10 < 15
      item = make_item(su_material: 'unknown', normal: [0, 1, 0],
                       width: 0.1, height: 1.0)
      r = policy.resolve(item)
      assert_equal :skip, r.method
    end

    def test_heuristic_disabled_falls_through
      policy = TakeoffPolicy.new(heuristics_enabled: false)
      item = make_item(su_material: 'unknown', normal: [0, 1, 0],
                       width: 0.05, height: 8.0)
      r = policy.resolve(item)
      # 启发式关 → default skip
      assert_equal :skip, r.method
    end

    def test_unmapped_no_heuristic_no_layer_skip
      policy = TakeoffPolicy.new(heuristics_enabled: false)
      item = make_item(su_material: 'unknown')
      r = policy.resolve(item)
      assert_equal :skip, r.method
      assert_equal :default, r.source
    end

    # ---- instance 分支 ----

    def test_instance_always_count
      policy = TakeoffPolicy.new
      item = ScanItem.instance(face_id: 100, su_material: 'lamp_01', unit: '个',
                               layer_name: 'Layer0', component_path: ['客厅'],
                               component_path_ids: [101])
      r = policy.resolve(item)
      assert_equal :count, r.method
      assert_equal :component, r.source
    end

    # ---- resolve_container ----

    def test_container_attr_length
      policy = TakeoffPolicy.new
      assert_equal :length, policy.resolve_container(layer_name: 'X', attr_method: 'length')
    end

    def test_container_attr_volume
      policy = TakeoffPolicy.new
      assert_equal :volume, policy.resolve_container(layer_name: 'X', attr_method: :volume)
    end

    def test_container_attr_area_returns_nil
      # 容器级只识别 length/volume；area 让 Scanner 正常下钻
      policy = TakeoffPolicy.new
      assert_nil policy.resolve_container(layer_name: 'X', attr_method: 'area')
    end

    def test_container_layer_rule
      policy = TakeoffPolicy.new(layer_rules: { '线条' => :length, '砌体' => :volume })
      assert_equal :length, policy.resolve_container(layer_name: '线条')
      assert_equal :volume, policy.resolve_container(layer_name: '砌体')
    end

    def test_container_layer_rule_area_returns_nil
      policy = TakeoffPolicy.new(layer_rules: { '面砖' => :area })
      assert_nil policy.resolve_container(layer_name: '面砖')
    end

    # ---- 阈值可配 ----

    def test_threshold_override
      policy = TakeoffPolicy.new(thresholds: { linear_min_aspect_ratio: 5,
                                               linear_max_short_edge_m: 0.5 })
      # 长宽比 6, 短边 0.3 → 默认会被排除，覆盖后命中
      item = make_item(su_material: 'unknown', normal: [0, 1, 0],
                       width: 0.3, height: 1.8)
      r = policy.resolve(item)
      assert_equal :length, r.method
      assert_equal :heuristic, r.source
    end

    # ---- Stage 3: ResolveResult.strategy ----

    def test_resolve_returns_face_linear_for_heuristic
      policy = TakeoffPolicy.new
      item = make_item(su_material: 'unknown', normal: [0, 1, 0],
                       width: 0.05, height: 8.0)
      r = policy.resolve(item)
      # 启发判定为线材时应用 face_linear（含 height fallback）
      assert_equal :face_linear, r.strategy.name
      assert_equal :length, r.method
      assert_equal :heuristic, r.source
    end

    def test_resolve_instance_returns_solid_count_strategy
      policy = TakeoffPolicy.new
      item = ScanItem.instance(face_id: 100, su_material: 'lamp_01', unit: '个',
                               layer_name: 'Layer0', component_path: ['客厅'], component_path_ids: [101])
      r = policy.resolve(item)
      assert_equal :solid_count, r.strategy.name
      assert_equal :count, r.method
      assert_equal :component, r.source
    end

    def test_container_item_preserves_attribute_source
      policy = TakeoffPolicy.new
      item = ScanItem.linear_solid(
        face_id: 100, su_material: '踢脚线', length: 2.0,
        layer_name: 'Layer0', component_path: ['踢脚线'], component_path_ids: [101],
        tags: { method: 'length' }
      )

      assert_equal :attr, policy.resolve(item).source
    end
  end
end
