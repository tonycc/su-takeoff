require_relative 'test_helper'
require 'src/strategies/base'

module SuTakeoff
  class TestStrategyMatching < Minitest::Test
    def make_item(layer: 'L0', material: 'x')
      ScanItem.face(
        face_id: 1, su_material: material, area: 1.0,
        normal: [0,0,1], width: 1, height: 1,
        layer_name: layer, component_path: ['R'], component_path_ids: [1]
      )
    end

    def test_no_rules_does_not_auto_match
      s = Strategies::Base.new(name: :x, method: :length, default_unit: 'm')
      refute s.matches?(make_item, {})
    end

    def test_explicit_empty_rules_does_not_match
      s = Strategies::Base.new(name: :x, method: :length, default_unit: 'm', match_rules: {})
      refute s.matches?(make_item, {})
    end

    def test_matches_by_definition_name_includes
      s = Strategies::Base.new(
        name: :skirting, method: :length, default_unit: 'm',
        match_rules: { definition_name_includes: ['踢脚', 'skirting'] }
      )
      assert s.matches?(make_item, definition_name: '主卧踢脚线-001')
      assert s.matches?(make_item, definition_name: 'wood_skirting_v2')
      refute s.matches?(make_item, definition_name: '墙面')
    end

    def test_matches_by_definition_name_pattern_with_regexp
      s = Strategies::Base.new(
        name: :pipe, method: :length, default_unit: 'm',
        match_rules: { definition_name_pattern: /管道|管材|PVC|DN\d+/ }
      )
      assert s.matches?(make_item, definition_name: 'PVC管道-DN50')
      assert s.matches?(make_item, definition_name: 'DN100 主水管')
      refute s.matches?(make_item, definition_name: '木板')
    end

    def test_matches_by_definition_name_pattern_with_string
      # JSON 配置加载时 pattern 是字符串；matches? 必须能转 Regexp
      s = Strategies::Base.new(
        name: :pipe, method: :length, default_unit: 'm',
        match_rules: { definition_name_pattern: '管道|管材' }
      )
      assert s.matches?(make_item, definition_name: '排水管材')
    end

    def test_matches_by_layer
      s = Strategies::Base.new(
        name: :rule, method: :length, default_unit: 'm',
        match_rules: { layer: ['踢脚线'] }
      )
      assert s.matches?(make_item(layer: '踢脚线'), {})
      refute s.matches?(make_item(layer: 'Layer0'), {})
    end

    def test_matches_by_unit
      s = Strategies::Base.new(
        name: :rule, method: :length, default_unit: 'm',
        match_rules: { unit: ['m'] }
      )
      assert s.matches?(make_item, unit: 'm')
      refute s.matches?(make_item, unit: 'mm')
    end

    def test_matches_definition_name_empty_string_returns_false
      s = Strategies::Base.new(
        name: :x, method: :length, default_unit: 'm',
        match_rules: { definition_name_includes: ['踢脚'] }
      )
      refute s.matches?(make_item, definition_name: '')
      refute s.matches?(make_item, definition_name: nil)
    end

    def test_nil_item_safe_for_layer_match
      s = Strategies::Base.new(
        name: :x, method: :length, default_unit: 'm',
        match_rules: { layer: ['踢脚线'] }
      )
      refute s.matches?(nil, {})
    end
  end
end
