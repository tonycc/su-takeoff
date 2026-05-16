# tools/create_wall_model.rb
# 在 SketchUp Ruby 控制台中运行，生成单房间测试模型
#
# 用法：
#   1. 打开 SketchUp，新建空白文件
#   2. Window → Ruby Console
#   3. load '/Users/max/projects/su-takeoff/tools/create_wall_model.rb'
#
# 客厅 6m×4m×2.8m，覆盖群组/组件/图层，透明洞口+命名门窗两种检测路径
#
# 注意：所有尺寸使用 .m 方法转换为 SU 内部单位（英寸），
# 确保在任何模型单位设置下都正确。

module SuTakeoff
  module WallModelBuilder
    H  = 2.8.m   # 层高
    RW = 6.0.m   # 房间宽 X
    RD = 4.0.m   # 房间深 Y
    SH = 0.08.m  # 踢脚线高

    def self.create
      model = Sketchup.active_model
      model.start_operation('生成单间测试模型', true)
      ents = model.active_entities

      # ---- 1. 图层 ----
      tag_struct  = model.layers.add('结构')
      tag_opening = model.layers.add('门窗')
      tag_deco    = model.layers.add('装饰')

      # ---- 2. 材质 ----
      mat = {}
      { 'tile_302' => [180, 175, 165],
        'paint_w'  => [250, 248, 245],
        'skirting' => [140, 100, 60],
      }.each do |name, rgb|
        m = model.materials[name] || model.materials.add(name)
        m.color = Sketchup::Color.new(*rgb)
        mat[name] = m
      end

      glass = model.materials['_glass'] || model.materials.add('_glass')
      glass.color = Sketchup::Color.new(180, 210, 230, 100)

      # ---- 3. 房间 Group "客厅" ----
      room = ents.add_group
      room.name = '客厅'
      room.layer = tag_struct

      # 3a. 地面
      fg = room.entities.add_group
      fg.name = '地面'
      fg.layer = tag_struct
      ff = fg.entities.add_face([0,0,0], [RW,0,0], [RW,RD,0], [0,RD,0])
      ff.reverse! unless ff.normal.z > 0
      ff.material = mat['tile_302']

      # 3b. 天花
      cg = room.entities.add_group
      cg.name = '天花'
      cg.layer = tag_struct
      cf = cg.entities.add_face([0,0,H], [0,RD,H], [RW,RD,H], [RW,0,H])
      cf.reverse! unless cf.normal.z < 0
      cf.material = mat['paint_w']

      # 3c. 墙体
      wg = room.entities.add_group
      wg.name = '墙体'
      wg.layer = tag_struct

      # 南墙 6m，开窗洞 1.5×1.5m，离地0.9m（透明玻璃 → Scanner 透明检测路径）
      s = wg.entities.add_face([0,0,0], [RW,0,0], [RW,0,H], [0,0,H])
      s.material = mat['paint_w']
      wx1, wz1 = 2.0.m, 0.9.m; ww1, wh1 = 1.5.m, 1.5.m
      w1 = wg.entities.add_face(
        [wx1, 0, wz1], [wx1+ww1, 0, wz1],
        [wx1+ww1, 0, wz1+wh1], [wx1, 0, wz1+wh1])
      w1.material = glass; w1.back_material = glass if w1

      # 北墙 6m，无洞口
      n = wg.entities.add_face([0,RD,0], [0,RD,H], [RW,RD,H], [RW,RD,0])
      n.material = mat['paint_w']

      # 东墙 4m（洞口由命名组件"门-M0921"提供）
      e = wg.entities.add_face([RW,0,0], [RW,RD,0], [RW,RD,H], [RW,0,H])
      e.material = mat['paint_w']

      # 西墙 4m，开窗洞 1.5×1.5m
      w = wg.entities.add_face([0,0,0], [0,0,H], [0,RD,H], [0,RD,0])
      w.material = mat['paint_w']
      wx2, wz2 = 1.0.m, 0.9.m; ww2, wh2 = 1.5.m, 1.5.m
      w2 = wg.entities.add_face(
        [0, wx2, wz2], [0, wx2+ww2, wz2],
        [0, wx2+ww2, wz2+wh2], [0, wx2, wz2+wh2])
      w2.material = glass; w2.back_material = glass if w2

      # ---- 4. 命名门组件 "门-M0921" ----
      door_w, door_h = 1.0.m, 2.1.m
      door_def = model.definitions.add('门-M0921')
      df = door_def.entities.add_face(
        [0,0,0], [door_w,0,0], [door_w,door_h,0], [0,door_h,0])
      df.material = glass; df.back_material = glass if df

      door_inst = wg.entities.add_instance(door_def,
        Geom::Transformation.new([RW, 1.5.m, 0]))
      door_inst.layer = tag_opening

      # ---- 5. 重复组件 "墙板-600" ----
      ps = 0.6.m  # 面板边长
      panel_def = model.definitions.add('墙板-600')
      pf = panel_def.entities.add_face([0,0,0], [ps,0,0], [ps,ps,0], [0,ps,0])
      pf.material = mat['paint_w']; pf.back_material = mat['paint_w'] if pf

      pa1 = wg.entities.add_instance(panel_def,
        Geom::Transformation.new([0.5.m, 0, 1.5.m]))
      pa1.layer = tag_deco

      pa2 = wg.entities.add_instance(panel_def,
        Geom::Transformation.new([0.5.m, RD, 1.5.m]))
      pa2.layer = tag_deco

      # ---- 6. 踢脚线（模型根层级，4 段独立 Group） ----
      [
        [[0,0,0], [RW,0,0], [RW,0,SH], [0,0,SH]],           # 南 6m
        [[0,RD,0], [RW,RD,0], [RW,RD,SH], [0,RD,SH]],       # 北 6m
        [[RW,0,0], [RW,RD,0], [RW,RD,SH], [RW,0,SH]],       # 东 4m
        [[0,0,0], [0,RD,0], [0,RD,SH], [0,0,SH]],           # 西 4m
      ].each_with_index do |pts, i|
        g = ents.add_group
        g.layer = tag_deco
        g.name = '踢脚线'
        sf = g.entities.add_face(*pts)
        if sf
          sf.material = mat['skirting']
          printf("  踢脚线 #%d: 面ID=%d area=%.4f m²\n", i+1, sf.entityID, sf.area * 0.00064516)
        else
          puts "  ⚠ 踢脚线 ##{i+1}: add_face 失败!"
        end
      end

      model.commit_operation
      verify(model, ents)
    rescue => e
      puts "错误: #{e.message}"
      puts e.backtrace.first(6).join("\n")
    end

    def self.verify(model, entities)
      puts "\n--- 模型验证 ---"
      entities.each do |e|
        case e
        when Sketchup::Group
          fc = e.entities.grep(Sketchup::Face).size
          printf("  Group \"%s\": %d面 layer=%s entityID=%d\n",
                 e.name, fc, e.layer&.name, e.entityID)
        when Sketchup::ComponentInstance
          fc = e.definition.entities.grep(Sketchup::Face).size
          printf("  Component \"%s\": %d面 layer=%s entityID=%d\n",
                 e.definition.name, fc, e.layer&.name, e.entityID)
        end
      end
      puts ""
    end
  end
end

SuTakeoff::WallModelBuilder.create
