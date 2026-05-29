require_relative 'test_helper'
require 'src/calculator'
require 'src/mapping'
require 'src/process_library'
require 'src/component_mapping'
require 'src/takeoff_policy'

module SuTakeoff
  # P3 体积场景：Scanner 在容器级判定为 :volume 后，产出 :solid kind 的 ScanItem
  # 携带 qty_volume；:linear_solid 同样产出但量取长度。
  class TestCalculatorVolume < Minitest::Test
    def setup
      @mapping = MaterialMapping.new
      @mapping.add('concrete_c30', '混凝土C30', '混凝土', 'm³', '', 0.05)
      @mapping.add('brick_red',    '红砖墙体',  '砌体',   'm³', '240厚', 0.03)
      @mapping.add('door_frame',   '门套线',    '木材',   'm',  '60mm',  0.05)

      @processes = ProcessLibrary.new
      # 砌体派生：1m³ 砖墙带 0.06m³ 砂浆
      @processes.add_process('砌体', '砖砌', 0.03, [
        Derivation.new(layer: '砌筑砂浆', unit: 'm³', formula: 'volume*0.06',
                       waste_rate: 0.05, category: '砌体')
      ])
      # 混凝土派生：1m³ 混凝土带 8kg 钢筋（这里用 kg 单位作字符串保留即可）
      @processes.add_process('混凝土', '现浇', 0.02, [
        Derivation.new(layer: '钢筋', unit: 'kg', formula: 'volume*8',
                       waste_rate: 0.02, category: '钢材')
      ])

      @cm = ComponentMapping.new
      @policy = TakeoffPolicy.new(mapping: @mapping)
      @calc = Calculator.new(@mapping, @processes, @cm, policy: @policy)
    end

    # 构造一个 :solid kind 的 ScanItem
    def make_solid(face_id:, su_material:, volume:, w: 1.0, h: 2.0, d: 0.24)
      it = ScanItem.new(face_id, su_material, 0, 'm³', :solid,
                        nil, w, h, 'Layer0', ['客厅'], [101], 1.5)
      it.qty_volume = volume
      it.qty_area = 0
      it.qty_length = h
      it.depth = d
      it
    end

    def make_linear_solid(face_id:, su_material:, length:)
      it = ScanItem.new(face_id, su_material, 0, 'm', :linear_solid,
                        nil, 0.06, length, 'Layer0', ['客厅'], [101], 1.5)
      it.qty_length = length
      it.qty_area = 0
      it.qty_volume = 0
      it
    end

    def test_solid_volume_accumulation
      items = [
        make_solid(face_id: 1, su_material: 'concrete_c30', volume: 2.5),
        make_solid(face_id: 2, su_material: 'concrete_c30', volume: 1.8),
      ]
      result = @calc.compute(items, [], {})

      primary = result.find { |u| u.parent_su_material.empty? }
      refute_nil primary
      assert_equal 'm³', primary.unit
      assert_in_delta 4.3, primary.net_area, 0.001
      assert_equal '混凝土C30', primary.material_name
    end

    def test_solid_no_opening_deduction
      items = [
        make_solid(face_id: 1, su_material: 'concrete_c30', volume: 5.0),
      ]
      # 即使提供了洞口，也不应扣减体积（洞口语义不适用）
      openings = [Opening.new(99, 1.0, [1])]
      result = @calc.compute(items, openings, {})

      primary = result.find { |u| u.parent_su_material.empty? }
      assert_in_delta 5.0, primary.net_area, 0.001
    end

    def test_volume_derivation_via_formula
      items = [
        make_solid(face_id: 1, su_material: 'brick_red', volume: 10.0),
      ]
      result = @calc.compute(items, [], {})

      primary = result.find { |u| u.parent_su_material.empty? }
      mortar = result.find { |u| u.layer == '砌筑砂浆' }

      refute_nil primary
      refute_nil mortar, '应展开砂浆派生项'

      # 主材：10 m³ 红砖墙体
      assert_in_delta 10.0, primary.net_area, 0.001
      assert_equal 'm³', primary.unit

      # 派生：10 * 0.06 = 0.6 m³ 砂浆
      assert_in_delta 0.6, mortar.net_area, 0.001
      assert_equal 'm³', mortar.unit
    end

    def test_volume_derivation_to_other_unit
      items = [
        make_solid(face_id: 1, su_material: 'concrete_c30', volume: 1.0),
      ]
      result = @calc.compute(items, [], {})

      rebar = result.find { |u| u.layer == '钢筋' }
      refute_nil rebar
      # 1 m³ × 8 = 8 kg
      assert_in_delta 8.0, rebar.net_area, 0.001
      assert_equal 'kg', rebar.unit
    end

    def test_linear_solid_goes_through_length_branch
      items = [
        make_linear_solid(face_id: 1, su_material: 'door_frame', length: 5.4),
        make_linear_solid(face_id: 2, su_material: 'door_frame', length: 2.1),
      ]
      result = @calc.compute(items, [], {})

      primary = result.find { |u| u.parent_su_material.empty? }
      assert_equal 'm', primary.unit
      assert_in_delta 7.5, primary.net_area, 0.01
      assert_equal '门套线', primary.material_name
      # source 应是 :layer（policy 在 :linear_solid kind 上直接返回 :length, source :layer）
      assert_equal :explicit, primary.confidence
    end

    def test_solid_kind_bypasses_4_tier_policy
      # :solid / :linear_solid / :count_solid 是用户显式标签产出，即使材质没映射也应通过，
      # 不因 mapping 检查而丢弃（用户意图明确，不应藏在映射缺失后面）。
      no_map = make_solid(face_id: 99, su_material: 'unmapped_solid', volume: 1.0)
      result = @calc.compute([no_map], [], {})
      refute_empty result, '显式标签的 :solid 不应被 mapping 检查跳过'
      assert_equal 'unmapped_solid', result.first.material_name
    end

    def test_volume_grouping_separates_materials
      items = [
        make_solid(face_id: 1, su_material: 'concrete_c30', volume: 2.0),
        make_solid(face_id: 2, su_material: 'brick_red',    volume: 3.0),
      ]
      result = @calc.compute(items, [], {})

      primaries = result.select { |u| u.parent_su_material.empty? }
      assert_equal 2, primaries.size
      assert(primaries.find { |u| u.material_name == '混凝土C30' && (u.net_area - 2.0).abs < 0.01 })
      assert(primaries.find { |u| u.material_name == '红砖墙体' && (u.net_area - 3.0).abs < 0.01 })
    end

    def test_compute_geometry_only_volume
      items = [
        make_solid(face_id: 1, su_material: 'concrete_c30', volume: 4.5),
      ]
      result = @calc.compute_geometry_only(items, [])
      assert_equal 1, result.size
      u = result.first
      assert_equal 'm³', u.unit
      assert_in_delta 4.5, u.net_area, 0.001
      assert_equal 0, u.waste_rate
    end
  end
end
