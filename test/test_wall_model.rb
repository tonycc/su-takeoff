require_relative 'test_helper'
require 'src/calculator'
require 'src/component_mapping'
require 'src/takeoff_policy'
require 'src/workbench_presenter'

module SuTakeoff
  # 真实户型场景：客厅 + 主卧 + 卫生间，含门窗洞口、踢脚线等
  #
  # 按 (space, part, material) 聚合的视图已经下线，本测试改为通过
  # WorkbenchPresenter 的 geometry_usages（按 entity_id × su_material 聚合）
  # 验证：洞口扣减、薄板去重、踢脚线线材识别仍然正确。
  class TestWallModel < Minitest::Test
    def setup
      @cm = ComponentMapping.new
      # 踢脚线通过图层规则触发 :length → solid_linear 路由
      # （3.5 档策略自动匹配已随材料映射移除，改由第 2 档图层规则触发）
      @policy = TakeoffPolicy.new(layer_rules: { '踢脚线' => :length })
    end

    # 各房间的 entity_id：客厅=101 主卧=201 卫生间=301
    LIVING_EID = 101
    BEDROOM_EID = 201
    BATHROOM_EID = 301

    # ================================================================
    # 构建真实户型数据
    # 房间尺寸: 客厅 8m×5m, 主卧 5m×4m, 卫生间 3m×2m; 层高 2.8m
    # Z: 地面 0, 天花 2.8。主卧在客厅东侧, 卫生间在主卧南侧。
    # ================================================================

    def living_floor
      ScanItem.face(face_id: 1, su_material: 'marble_01', area: 40.0,
                    normal: [0,0,1], width: 8.0, height: 5.0,
                    layer_name: 'Layer0', component_path: ['客厅'],
                    component_path_ids: [LIVING_EID], z_center: 0.02)
    end

    def living_ceiling
      ScanItem.face(face_id: 2, su_material: 'paint_w', area: 40.0,
                    normal: [0,0,-1], width: 8.0, height: 5.0,
                    layer_name: 'Layer0', component_path: ['客厅'],
                    component_path_ids: [LIVING_EID], z_center: 2.78)
    end

    # 客厅四面墙: 北(8m) 南(8m) 东(5m) 西(5m), 层高2.8m
    def living_wall_north
      ScanItem.face(face_id: 3, su_material: 'paint_w', area: 22.4,
                    normal: [0,1,0], width: 8.0, height: 2.8,
                    layer_name: 'Layer0', component_path: ['客厅'],
                    component_path_ids: [LIVING_EID], z_center: 1.4)
    end

    def living_wall_south
      ScanItem.face(face_id: 4, su_material: 'paint_w', area: 22.4,
                    normal: [0,-1,0], width: 8.0, height: 2.8,
                    layer_name: 'Layer0', component_path: ['客厅'],
                    component_path_ids: [LIVING_EID], z_center: 1.4)
    end

    def living_wall_east
      ScanItem.face(face_id: 5, su_material: 'paint_w', area: 14.0,
                    normal: [1,0,0], width: 5.0, height: 2.8,
                    layer_name: 'Layer0', component_path: ['客厅'],
                    component_path_ids: [LIVING_EID], z_center: 1.4)
    end

    def living_wall_west
      ScanItem.face(face_id: 6, su_material: 'paint_w', area: 14.0,
                    normal: [-1,0,0], width: 5.0, height: 2.8,
                    layer_name: 'Layer0', component_path: ['客厅'],
                    component_path_ids: [LIVING_EID], z_center: 1.4)
    end

    # 客厅踢脚线 — 绕墙一圈 (8+5)*2 = 26m, 高80mm 宽80mm → 长宽比 2.8/0.08 >15 → 线材
    # layer_name='踢脚线' + policy.layer_rules={'踢脚线'=>:length} → solid_linear 路由
    def living_skirting
      walls = [
        { id: 7,  w: 8.0, normal: [0,1,0] },
        { id: 8,  w: 8.0, normal: [0,-1,0] },
        { id: 9,  w: 5.0, normal: [1,0,0] },
        { id: 10, w: 5.0, normal: [-1,0,0] },
      ]
      walls.map do |w|
        ScanItem.face(face_id: w[:id], su_material: 'skirting', area: w[:w] * 0.08,
                      normal: w[:normal], width: 0.08, height: w[:w],
                      layer_name: '踢脚线', component_path: ['客厅'],
                      component_path_ids: [LIVING_EID], z_center: 0.04)
      end
    end

    # ---- 主卧 (5m × 4m, 层高2.8m) ----
    def bedroom_floor
      ScanItem.face(face_id: 20, su_material: 'wood_oak', area: 20.0,
                    normal: [0,0,1], width: 5.0, height: 4.0,
                    layer_name: 'Layer0', component_path: ['主卧'],
                    component_path_ids: [BEDROOM_EID], z_center: 0.02)
    end

    def bedroom_ceiling
      ScanItem.face(face_id: 21, su_material: 'paint_w', area: 20.0,
                    normal: [0,0,-1], width: 5.0, height: 4.0,
                    layer_name: 'Layer0', component_path: ['主卧'],
                    component_path_ids: [BEDROOM_EID], z_center: 2.78)
    end

    def bedroom_wall_north
      ScanItem.face(face_id: 22, su_material: 'paint_w', area: 14.0,
                    normal: [0,1,0], width: 5.0, height: 2.8,
                    layer_name: 'Layer0', component_path: ['主卧'],
                    component_path_ids: [BEDROOM_EID], z_center: 1.4)
    end

    def bedroom_wall_south
      ScanItem.face(face_id: 23, su_material: 'paint_w', area: 14.0,
                    normal: [0,-1,0], width: 5.0, height: 2.8,
                    layer_name: 'Layer0', component_path: ['主卧'],
                    component_path_ids: [BEDROOM_EID], z_center: 1.4)
    end

    def bedroom_wall_east
      ScanItem.face(face_id: 24, su_material: 'paint_w', area: 11.2,
                    normal: [1,0,0], width: 4.0, height: 2.8,
                    layer_name: 'Layer0', component_path: ['主卧'],
                    component_path_ids: [BEDROOM_EID], z_center: 1.4)
    end

    def bedroom_wall_west
      ScanItem.face(face_id: 25, su_material: 'paint_w', area: 11.2,
                    normal: [-1,0,0], width: 4.0, height: 2.8,
                    layer_name: 'Layer0', component_path: ['主卧'],
                    component_path_ids: [BEDROOM_EID], z_center: 1.4)
    end

    # ---- 卫生间 (3m × 2m, 层高2.8m) ----
    def bathroom_floor
      ScanItem.face(face_id: 30, su_material: 'tile_302', area: 6.0,
                    normal: [0,0,1], width: 3.0, height: 2.0,
                    layer_name: 'Layer0', component_path: ['卫生间'],
                    component_path_ids: [BATHROOM_EID], z_center: 0.02)
    end

    def bathroom_ceiling
      ScanItem.face(face_id: 31, su_material: 'paint_w', area: 6.0,
                    normal: [0,0,-1], width: 3.0, height: 2.0,
                    layer_name: 'Layer0', component_path: ['卫生间'],
                    component_path_ids: [BATHROOM_EID], z_center: 2.78)
    end

    def bathroom_wall_north
      ScanItem.face(face_id: 32, su_material: 'tile_302', area: 8.4,
                    normal: [0,1,0], width: 3.0, height: 2.8,
                    layer_name: 'Layer0', component_path: ['卫生间'],
                    component_path_ids: [BATHROOM_EID], z_center: 1.4)
    end

    def bathroom_wall_south
      ScanItem.face(face_id: 33, su_material: 'tile_302', area: 8.4,
                    normal: [0,-1,0], width: 3.0, height: 2.8,
                    layer_name: 'Layer0', component_path: ['卫生间'],
                    component_path_ids: [BATHROOM_EID], z_center: 1.4)
    end

    def bathroom_wall_east
      ScanItem.face(face_id: 34, su_material: 'tile_302', area: 5.6,
                    normal: [1,0,0], width: 2.0, height: 2.8,
                    layer_name: 'Layer0', component_path: ['卫生间'],
                    component_path_ids: [BATHROOM_EID], z_center: 1.4)
    end

    def bathroom_wall_west
      ScanItem.face(face_id: 35, su_material: 'tile_302', area: 5.6,
                    normal: [-1,0,0], width: 2.0, height: 2.8,
                    layer_name: 'Layer0', component_path: ['卫生间'],
                    component_path_ids: [BATHROOM_EID], z_center: 1.4)
    end

    def all_items
      [
        living_floor, living_ceiling,
        living_wall_north, living_wall_south, living_wall_east, living_wall_west,
        *living_skirting,
        bedroom_floor, bedroom_ceiling,
        bedroom_wall_north, bedroom_wall_south, bedroom_wall_east, bedroom_wall_west,
        bathroom_floor, bathroom_ceiling,
        bathroom_wall_north, bathroom_wall_south, bathroom_wall_east, bathroom_wall_west,
      ]
    end

    # 门窗洞口 — 客厅东墙窗户 + 客厅南墙门 + 主卧南墙窗户 + 主卧西墙门 + 卫生间东墙门
    def all_openings
      [
        Opening.new(100, 3.0,  [5]),    # 客厅东墙窗户 2m×1.5m
        Opening.new(101, 2.1,  [4]),    # 客厅南墙门 1m×2.1m
        Opening.new(200, 2.25, [23]),   # 主卧南墙窗户 1.5m×1.5m
        Opening.new(201, 2.1,  [25]),   # 主卧西墙门 1m×2.1m
        Opening.new(300, 1.68, [34]),   # 卫生间东墙门 0.8m×2.1m
      ]
    end

    # ================================================================
    # 测试辅助
    # ================================================================

    def usages_for(items, openings)
      WorkbenchPresenter.new(
        items: items, openings: openings,
        hierarchy: { name: '(root)', entity_id: 0, kind: 'root',
                     definition_name: nil, depth: 0, hidden: false, children: [] },
        colors: {},
        component_mapping: @cm,
        policy: @policy, tag_defs: {}
      ).build[:geometry_usages]
    end

    def find_usage(usages, entity_id, su_material)
      usages.find { |u| u[:entity_id] == entity_id && u[:su_material] == su_material }
    end

    # ================================================================
    # 测试用例（按 entity_id × material 聚合）
    # ================================================================

    def test_total_faces
      assert_equal 22, all_items.size
    end

    def test_total_openings
      assert_equal 5, all_openings.size
    end

    def test_living_room_marble_floor
      usages = usages_for(all_items, all_openings)
      floor = find_usage(usages, LIVING_EID, 'marble_01')
      refute_nil floor
      assert_in_delta 40.0, floor[:qty_area], 0.01
      # 无显式标签/图层规则时落到几何启发式 → confidence='heuristic'
      # （材料映射档已移除，原 mapping unit 触发的 'explicit' 不再适用）
      assert_equal 'heuristic', floor[:confidence]
    end

    def test_living_paint_combines_walls_and_ceiling_with_opening_deduction
      # 客厅 paint_w 同时覆盖墙面（4 面合计 72.8 m² 毛）和天花（40 m²）
      # 扣减: 南墙门 2.1 + 东墙窗 3.0 = 5.1
      # 净 area = 72.8 + 40 - 5.1 = 107.7
      usages = usages_for(all_items, all_openings)
      paint = find_usage(usages, LIVING_EID, 'paint_w')
      refute_nil paint
      assert_in_delta 107.7, paint[:qty_area], 0.05

      # by_part 是毛面积，可单独验证墙/天花
      assert_in_delta 72.8, paint[:by_part]['wall'],    0.05
      assert_in_delta 40.0, paint[:by_part]['ceiling'], 0.05
    end

    def test_bedroom_wood_floor
      usages = usages_for(all_items, all_openings)
      floor = find_usage(usages, BEDROOM_EID, 'wood_oak')
      refute_nil floor
      assert_in_delta 20.0, floor[:qty_area], 0.01
    end

    def test_bedroom_paint_with_opening_deduction
      # 墙: 14+14+11.2+11.2 = 50.4 毛, 天花 20
      # 扣: 南窗 2.25 + 西门 2.1 = 4.35
      # 净 = 50.4 + 20 - 4.35 = 66.05
      usages = usages_for(all_items, all_openings)
      paint = find_usage(usages, BEDROOM_EID, 'paint_w')
      refute_nil paint
      assert_in_delta 66.05, paint[:qty_area], 0.05
    end

    def test_bathroom_tile_floor_and_walls
      # 卫生间 tile_302 = 地面 6 + 墙面 28 毛 − 东墙门 1.68 = 32.32
      usages = usages_for(all_items, all_openings)
      tile = find_usage(usages, BATHROOM_EID, 'tile_302')
      refute_nil tile
      assert_in_delta 32.32, tile[:qty_area], 0.05
    end

    def test_bathroom_ceiling_paint
      usages = usages_for(all_items, all_openings)
      paint = find_usage(usages, BATHROOM_EID, 'paint_w')
      refute_nil paint
      assert_in_delta 6.0, paint[:qty_area], 0.01
    end

    def test_skirting_recognized_as_linear_material
      # 踢脚线 unit='m', 8+8+5+5 = 26m
      usages = usages_for(all_items, all_openings)
      skirting = find_usage(usages, LIVING_EID, 'skirting')
      refute_nil skirting, '踢脚线应被识别为线材并出现在 geometry_usages'
      assert_in_delta 26.0, skirting[:qty_length], 0.01
      assert_equal 'm', skirting[:unit]
    end

    def test_no_opening_deduction_in_pure_ceiling_room
      # 卫生间天花没有洞口，毛=净=6m²
      usages = usages_for(all_items, all_openings)
      paint = find_usage(usages, BATHROOM_EID, 'paint_w')
      assert_in_delta 6.0, paint[:by_part]['ceiling'], 0.01
      assert_in_delta 6.0, paint[:qty_area], 0.01
    end

    def test_face_id_uniqueness
      ids = all_items.map(&:face_id)
      assert_equal ids.uniq.size, ids.size, '所有面的 face_id 应唯一'
    end

    def test_face_count_in_usages
      # 4 间 × 平均 ~5 材质 → 至少 7 条 usage
      usages = usages_for(all_items, all_openings)
      assert usages.size >= 7, "应为 7+ 条 usage，实际 #{usages.size} 条"
    end

    def test_compound_tag_count_plus_length_both_accumulated
      # 复合标签 count+length：同一实体产出 count_solid + linear_solid 两条 item，
      # 共享相同 face_id/path_ids。Presenter 应同时累加 qty_count 和 qty_length，
      # 而不是因 key 碰撞导致其中一个被覆盖为 0。
      count_item = ScanItem.count_solid(
        face_id: 99, su_material: 'skirting',
        layer_name: 'Layer0', component_path: ['客厅'], component_path_ids: [LIVING_EID]
      )
      linear_item = ScanItem.linear_solid(
        face_id: 99, su_material: 'skirting', length: 3.0,
        layer_name: 'Layer0', component_path: ['客厅'], component_path_ids: [LIVING_EID]
      )
      usages = usages_for([count_item, linear_item], [])
      u = find_usage(usages, LIVING_EID, 'skirting')
      refute_nil u, '复合标签 item 应出现在 geometry_usages'
      assert_in_delta 1.0, u[:qty_count],  0.01, '件数应为 1'
      assert_in_delta 3.0, u[:qty_length], 0.01, '长度应为 3m'
    end

    def test_geometry_usage_includes_strategy_debug_field
      # Stage 3: geometry_usages 暴露 strategy_name 调试字段
      usages = usages_for(all_items, [])
      marble = find_usage(usages, LIVING_EID, 'marble_01')
      refute_nil marble
      refute_nil marble[:strategies]
      assert_includes marble[:strategies], 'face_area'
    end

    def test_faces_detail_includes_strategy_name
      usages = usages_for(all_items, [])
      marble = find_usage(usages, LIVING_EID, 'marble_01')
      face = marble[:faces].first
      refute_nil face
      assert_equal 'face_area', face[:strategy_name]
    end

    def test_skirting_strategy_name_in_geometry_usage
      # 踢脚线 layer_name='踢脚线' + policy layer_rules={'踢脚线'=>:length}
      # → 第 2 档图层规则决议为 :length → solid_linear 默认策略
      # （原 3.5 档 SkirtingLinear 自动匹配已随材料映射移除）
      usages = usages_for(all_items, [])
      skirting = find_usage(usages, LIVING_EID, 'skirting')
      refute_nil skirting
      assert_includes skirting[:strategies], 'solid_linear'
    end
  end
end
