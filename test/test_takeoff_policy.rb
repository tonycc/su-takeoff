require_relative 'test_helper'
require 'src/mapping'
require 'src/takeoff_policy'

module SuTakeoff
  class TestTakeoffPolicy < Minitest::Test
    def setup
      @mapping = MaterialMapping.new
      @mapping.add('marble_01', '爵士白', '石材', 'm²', '大板', 0.08)
      @mapping.add('skirting_m', '踢脚线', '木材', 'm', '80mm', 0.05)
      @mapping.add('lamp_01', '台灯', '灯具', '个', '', 0)
    end

    # 构造一个 ScanItem。新字段用 keyword_set 风格便于测试。
    def make_item(kind: :face, su_material: 'marble_01',
                  normal: [0, 1, 0], width: 5.0, height: 3.0,
                  layer_name: 'Layer0', tags: nil)
      item = ScanItem.new(1, su_material, width * height, 'm2', kind,
                          normal, width, height, layer_name,
                          ['客厅'], [101], 1.5)
      item.qty_area = width * height
      item.qty_length = height
      item.tags = tags
      item
    end

    # ---- 优先级 1: AttrDict ----

    def test_attr_dict_overrides_everything
      policy = TakeoffPolicy.new(mapping: @mapping,
                                 layer_rules: { 'Layer0' => :area })
      item = make_item(tags: { method: 'length' })
      r = policy.resolve(item)
      assert_equal :length, r.method
      assert_equal :attr, r.source
    end

    def test_attr_dict_skip
      policy = TakeoffPolicy.new(mapping: @mapping)
      item = make_item(tags: { method: 'skip' })
      r = policy.resolve(item)
      assert_equal :skip, r.method
      assert_equal :attr, r.source
    end

    def test_attr_dict_invalid_method_falls_through
      policy = TakeoffPolicy.new(mapping: @mapping)
      item = make_item(tags: { method: 'bogus' })
      r = policy.resolve(item)
      # 落入 mapping 兜底（marble_01 → area）
      assert_equal :area, r.method
      assert_equal :mapping, r.source
    end

    # ---- 优先级 2: layer_rules ----

    def test_layer_rule_length
      policy = TakeoffPolicy.new(mapping: @mapping,
                                 layer_rules: { '线条' => :length })
      item = make_item(layer_name: '线条')
      r = policy.resolve(item)
      assert_equal :length, r.method
      assert_equal :layer, r.source
    end

    def test_layer_rule_string_value_normalized
      policy = TakeoffPolicy.new(mapping: @mapping,
                                 layer_rules: { '线条' => 'length' })
      item = make_item(layer_name: '线条')
      assert_equal :length, policy.resolve(item).method
    end

    def test_layer_rule_unknown_layer_falls_through
      policy = TakeoffPolicy.new(mapping: @mapping,
                                 layer_rules: { '线条' => :length })
      item = make_item(layer_name: 'Layer0')
      r = policy.resolve(item)
      assert_equal :area, r.method
      assert_equal :mapping, r.source
    end

    def test_layer_rule_invalid_method_dropped
      policy = TakeoffPolicy.new(mapping: @mapping,
                                 layer_rules: { 'Layer0' => :bogus })
      item = make_item(layer_name: 'Layer0')
      r = policy.resolve(item)
      # 规则被 normalize 丢弃，落 mapping
      assert_equal :area, r.method
      assert_equal :mapping, r.source
    end

    # ---- 优先级 3: 启发式 ----

    def test_heuristic_recognizes_narrow_vertical_face
      policy = TakeoffPolicy.new(mapping: @mapping)
      # 0.05m 短边 + 8m 长边，长宽比 160 → 命中
      item = make_item(su_material: 'unknown', normal: [0, 1, 0],
                       width: 0.05, height: 8.0)
      r = policy.resolve(item)
      assert_equal :length, r.method
      assert_equal :heuristic, r.source
    end

    def test_heuristic_excludes_horizontal_face
      policy = TakeoffPolicy.new(mapping: @mapping)
      # 顶面，即使形状窄长也不应被判线材
      item = make_item(su_material: 'unknown', normal: [0, 0, 1],
                       width: 0.05, height: 8.0)
      r = policy.resolve(item)
      # mapping 不存在 unknown，落 default skip
      assert_equal :skip, r.method
    end

    def test_heuristic_excludes_wide_face
      policy = TakeoffPolicy.new(mapping: @mapping)
      # 短边 0.5m > 阈值 0.2m，不算线材（窗台板那种）
      item = make_item(su_material: 'unknown', normal: [0, 1, 0],
                       width: 0.5, height: 9.0)
      r = policy.resolve(item)
      assert_equal :skip, r.method
    end

    def test_heuristic_excludes_low_aspect_ratio
      policy = TakeoffPolicy.new(mapping: @mapping)
      # 长宽比 10 < 15
      item = make_item(su_material: 'unknown', normal: [0, 1, 0],
                       width: 0.1, height: 1.0)
      r = policy.resolve(item)
      assert_equal :skip, r.method
    end

    def test_heuristic_disabled_falls_through
      policy = TakeoffPolicy.new(mapping: @mapping, heuristics_enabled: false)
      item = make_item(su_material: 'unknown', normal: [0, 1, 0],
                       width: 0.05, height: 8.0)
      r = policy.resolve(item)
      # 启发式关 → 落 default skip（无映射）
      assert_equal :skip, r.method
    end

    def test_mapping_overrides_heuristic
      # 材质映射（显式配置）优先级高于几何启发式（自动猜测）
      policy = TakeoffPolicy.new(mapping: @mapping)
      item = make_item(su_material: 'marble_01', normal: [0, 1, 0],
                       width: 0.05, height: 8.0)
      r = policy.resolve(item)
      assert_equal :area, r.method
      assert_equal :mapping, r.source
    end

    # ---- 优先级 4: mapping 兜底 ----

    def test_mapping_area
      policy = TakeoffPolicy.new(mapping: @mapping)
      item = make_item(su_material: 'marble_01')
      r = policy.resolve(item)
      assert_equal :area, r.method
      assert_equal :mapping, r.source
    end

    def test_mapping_length_unit
      policy = TakeoffPolicy.new(mapping: @mapping)
      item = make_item(su_material: 'skirting_m', width: 1.0, height: 5.0)
      r = policy.resolve(item)
      assert_equal :length, r.method
      assert_equal :mapping, r.source
    end

    def test_mapping_count_unit
      policy = TakeoffPolicy.new(mapping: @mapping)
      item = make_item(su_material: 'lamp_01')
      r = policy.resolve(item)
      assert_equal :count, r.method
      assert_equal :mapping, r.source
    end

    def test_unmapped_no_heuristic_no_layer_skip
      policy = TakeoffPolicy.new(mapping: @mapping, heuristics_enabled: false)
      item = make_item(su_material: 'unknown')
      r = policy.resolve(item)
      assert_equal :skip, r.method
      assert_equal :default, r.source
    end

    # ---- instance 分支 ----

    def test_instance_always_count
      policy = TakeoffPolicy.new(mapping: @mapping)
      item = ScanItem.new(100, 'lamp_01', 1, '个', :instance, nil, 0, 0,
                          'Layer0', ['客厅'], [101], 0)
      r = policy.resolve(item)
      assert_equal :count, r.method
    end

    # ---- resolve_container ----

    def test_container_attr_length
      policy = TakeoffPolicy.new(mapping: @mapping)
      assert_equal :length, policy.resolve_container(layer_name: 'X', attr_method: 'length')
    end

    def test_container_attr_volume
      policy = TakeoffPolicy.new(mapping: @mapping)
      assert_equal :volume, policy.resolve_container(layer_name: 'X', attr_method: :volume)
    end

    def test_container_attr_area_returns_nil
      # 容器级只识别 length/volume；area 让 Scanner 正常下钻
      policy = TakeoffPolicy.new(mapping: @mapping)
      assert_nil policy.resolve_container(layer_name: 'X', attr_method: 'area')
    end

    def test_container_layer_rule
      policy = TakeoffPolicy.new(mapping: @mapping,
                                 layer_rules: { '线条' => :length, '砌体' => :volume })
      assert_equal :length, policy.resolve_container(layer_name: '线条')
      assert_equal :volume, policy.resolve_container(layer_name: '砌体')
    end

    def test_container_layer_rule_area_returns_nil
      policy = TakeoffPolicy.new(mapping: @mapping,
                                 layer_rules: { '面砖' => :area })
      assert_nil policy.resolve_container(layer_name: '面砖')
    end

    # ---- 阈值可配 ----

    def test_threshold_override
      policy = TakeoffPolicy.new(mapping: @mapping,
                                 thresholds: { linear_min_aspect_ratio: 5,
                                               linear_max_short_edge_m: 0.5 })
      # 长宽比 6, 短边 0.3 → 默认会被排除，覆盖后命中
      item = make_item(su_material: 'unknown', normal: [0, 1, 0],
                       width: 0.3, height: 1.8)
      r = policy.resolve(item)
      assert_equal :length, r.method
      assert_equal :heuristic, r.source
    end
  end
end
