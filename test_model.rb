# test_model.rb — 在 SketchUp Ruby 控制台中运行
# load '/Users/max/projects/su-takeoff/test_model.rb'
#
# 运行后在插件中添加映射:
#   【组件映射】台灯 → 床头台灯 / 灯具 / 个 / 整件统计
#   【组件映射】开关面板 → 86型开关 / 电气 / 个 / 整件统计
#   【材料映射】乳胶漆 → 乳胶漆 / 涂料 / m²
#   【材料映射】木地板 → 木地板 / 木材 / m²
#   【材料映射】金属装饰条 → 装饰条 / 金属 / mm
#   【材料映射】窗玻璃 → 玻璃 / 玻璃 / m²

module SuTakeoffTest
  def self.run
    model = Sketchup.active_model
    model.start_operation('生成测试模型', true)
    model.entities.clear!
    ents = model.entities

    # ---------- 材质 ----------
    m = {}
    {
      '乳胶漆'     => [250, 248, 240],
      '木地板'     => [180, 140, 100],
      '金属装饰条' => [160, 160, 160],
      '窗玻璃'     => [180, 210, 240],
    }.each do |name, rgb|
      mat = model.materials.add(name)
      mat.color = Sketchup::Color.new(*rgb)
      m[name] = mat
    end
    # 透明窗玻璃 → 洞口识别
    glass = model.materials.add('透明玻璃')
    glass.color = Sketchup::Color.new(180, 210, 240)
    glass.alpha = 0.2
    # 开关外壳
    switch_mat = model.materials.add('开关塑料')
    switch_mat.color = Sketchup::Color.new(245, 245, 245)

    # ========== 1. 立方体房间 ==========
    room = ents.add_group
    room.name = '主卧'

    # 地板
    floor = room.entities.add_face(
      [0,    0, 0], [120.inch, 0, 0],
      [120.inch, 120.inch, 0], [0, 120.inch, 0]
    )
    floor.material = m['木地板']

    # 后墙
    f = room.entities.add_face(
      [0, 120.inch, 0], [120.inch, 120.inch, 0],
      [120.inch, 120.inch, 100.inch], [0, 120.inch, 100.inch]
    )
    f.material = m['乳胶漆']; f.pushpull(8.inch)

    # 左墙
    f = room.entities.add_face(
      [0, 0, 0], [0, 120.inch, 0],
      [0, 120.inch, 100.inch], [0, 0, 100.inch]
    )
    f.material = m['乳胶漆']; f.pushpull(8.inch)

    # 右墙
    f = room.entities.add_face(
      [120.inch, 0, 0], [120.inch, 120.inch, 0],
      [120.inch, 120.inch, 100.inch], [120.inch, 0, 100.inch]
    )
    f.material = m['乳胶漆']; f.pushpull(8.inch)

    # 前墙（下半墙）
    f = room.entities.add_face(
      [0, 0, 0], [120.inch, 0, 0],
      [120.inch, 0, 60.inch], [0, 0, 60.inch]
    )
    f.material = m['乳胶漆']; f.pushpull(8.inch)

    # ========== 2. 窗户（墙上的洞口） ==========
    # 在后墙上开窗 — 放一个透明面
    win_grp = room.entities.add_group
    win_grp.name = '窗'
    win_face = win_grp.entities.add_face(
      [35.inch, 120.inch, 30.inch], [85.inch, 120.inch, 30.inch],
      [85.inch, 120.inch, 80.inch], [35.inch, 120.inch, 80.inch]
    )
    win_face.material = glass

    # ========== 3. 开关面板 ==========
    sw_def = model.definitions.add('开关面板')
    sw_face = sw_def.entities.add_face(
      [0, 0, 0], [3.inch, 0, 0],
      [3.inch, 5.inch, 0], [0, 5.inch, 0]
    )
    sw_face.material = switch_mat
    sw_face.pushpull(0.8.inch)
    # 安置在右墙
    room.entities.add_instance(sw_def, Geom::Transformation.new([120.inch, 60.inch, 45.inch]))

    # ========== 4. 弧形地台（带高度） ==========
    platform = room.entities.add_group
    platform.name = '弧形地台'

    # 半圆形底面：从 -x 到 +x 的弧 + 弦封闭
    cx, cy, cz = 60.inch, 40.inch, 0
    radius = 25.inch
    segments = 24
    arc_pts = (0..segments).map do |i|
      angle = Math::PI * i / segments  # 0° → 180°
      [cx + radius * Math.cos(angle), cy + radius * Math.sin(angle), cz]
    end
    platform.entities.add_curve(arc_pts)
    # 封闭弧形成面
    platform.entities.add_line(arc_pts.first, arc_pts.last)

    plat_face = platform.entities.grep(Sketchup::Face).first
    if plat_face
      plat_face.material = m['木地板']
      plat_face.pushpull(6.inch)
      # 侧面赋乳胶漆
      platform.entities.grep(Sketchup::Face).each do |f|
        if f.normal.z.abs < 0.01
          f.material = m['乳胶漆']
        end
      end
    end

    # ========== 5. 台灯 ==========
    lamp_def = model.definitions.add('台灯')
    # 底座（圆柱近似 → 方柱）
    lb = lamp_def.entities.add_face(
      [-3.inch, -3.inch, 0], [3.inch, -3.inch, 0],
      [3.inch, 3.inch, 0], [-3.inch, 3.inch, 0]
    )
    lb.material = m['金属装饰条']
    lb.pushpull(1.5.inch)
    # 灯杆
    lp = lamp_def.entities.add_face(
      [-0.4.inch, -0.4.inch, 1.5.inch], [0.4.inch, -0.4.inch, 1.5.inch],
      [0.4.inch, 0.4.inch, 1.5.inch], [-0.4.inch, 0.4.inch, 1.5.inch]
    )
    lp.material = m['金属装饰条']
    lp.pushpull(14.inch)
    # 灯罩（梯形）
    ls = lamp_def.entities.add_face(
      [-5.inch, -5.inch, 15.5.inch], [5.inch, -5.inch, 15.5.inch],
      [5.inch, 5.inch, 15.5.inch], [-5.inch, 5.inch, 15.5.inch]
    )
    ls.material = m['乳胶漆']
    ls.pushpull(5.inch)

    # 台灯放在地台旁边（右侧）
    room.entities.add_instance(lamp_def, Geom::Transformation.new(
      [cx + radius + 10.inch, cy, 0]
    ))

    # ========== 6. 踢脚线（线材） ==========
    baseboard = room.entities.add_group
    baseboard.name = '踢脚线'
    bb_face = baseboard.entities.add_face(
      [0, 0, 0], [120.inch, 0, 0],
      [120.inch, 0, 4.inch], [0, 0, 4.inch]
    )
    bb_face.material = m['金属装饰条']
    bb_face.pushpull(0.5.inch)
    baseboard.move!(Geom::Transformation.new([0, 0, 0]))

    model.commit_operation
    puts_component_stats(model, m)
  end

  def self.puts_component_stats(model, m)
    defs = model.definitions.map(&:name).reject(&:empty?)
    faces = 0
    model.entities.each { |e| faces += count_faces(e) }

    puts "=" * 50
    puts "测试模型已生成"
    puts "=" * 50
    puts "组件定义: #{defs.join(', ')}"
    puts "总面数: #{faces}"
    puts
    puts "--- 场景覆盖 ---"
    puts "  立方体房间 — 四面墙 + 地板，主卧"
    puts "  窗户 — 后墙透明面，应识别为洞口扣除"
    puts "  开关面板 — 右墙，组件映射为整件统计"
    puts "  弧形地台 — 半圆形，6 寸高，木地板 + 侧面乳胶漆"
    puts "  台灯 — 地台旁，多面组件，整件统计"
    puts "  踢脚线 — 线材 mm"
    puts
    puts "--- 映射配置 ---"
    puts "  【组件映射】台灯 → 床头台灯 / 灯具 / 个 / 整件统计"
    puts "  【组件映射】开关面板 → 86型开关 / 电气 / 个 / 整件统计"
    puts "  【材料映射】乳胶漆 → 乳胶漆 / 涂料 / m²"
    puts "  【材料映射】木地板 → 木地板 / 木材 / m²"
    puts "  【材料映射】金属装饰条 → 装饰条 / 金属 / mm"
    puts "  【材料映射】窗玻璃 → 玻璃 / 玻璃 / m²"
  end

  def self.count_faces(entity)
    n = 0
    case entity
    when Sketchup::Face then 1
    when Sketchup::Group then entity.entities.sum { |e| count_faces(e) }
    when Sketchup::ComponentInstance
      entity.definition.entities.sum { |e| count_faces(e) }
    else 0
    end
  end
end

SuTakeoffTest.run
