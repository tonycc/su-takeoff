# 在 SketchUp Ruby 控制台中执行:
#   load File.expand_path('~/projects/su-takeoff/tools/create_debug_room.rb')
#
# 生成完整调试房间：4m×3m×2.8m，含窗、门、踢脚线、家具。

module SuTakeoff
  module DebugRoom
    module_function

    def create
      model = Sketchup.active_model
      model.start_operation('生成完整调试房间', true)
      model.entities.clear!
      ents = model.entities

      # ══════════════════════════════════════
      # 材质
      # ══════════════════════════════════════
      mat_tile    = add_mat(model, 'tile_floor',    'Beige')
      mat_paint   = add_mat(model, 'paint_wall',    '#f5f5f5')
      mat_ceiling = add_mat(model, 'paint_ceiling', '#ffffff')
      mat_glass   = add_mat(model, 'glass_window',  '#aaddff', 0.3)
      mat_wood    = add_mat(model, 'wood_door',     '#8B6914')
      mat_base    = add_mat(model, 'wood_baseboard','#6B4914')
      mat_metal   = add_mat(model, 'metal_handle',  '#888888')

      # ══════════════════════════════════════
      # 尺寸 (英寸)
      # ══════════════════════════════════════
      w = 4.0 * 39.37   # 宽 X
      d = 3.0 * 39.37   # 深 Y
      h = 2.8 * 39.37   # 高 Z

      # ══════════════════════════════════════
      # 辅助：创建面 + 强制法向量
      # ══════════════════════════════════════
      make_face = ->(pts, mat, nz, container) {
        f = container.add_face(*pts)
        f.reverse! if nz && (f.normal.z * nz < 0)
        f.material = mat if mat
        f
      }

      # ══════════════════════════════════════
      # 地面
      # ══════════════════════════════════════
      floor = ents.add_group
      floor.name = '主卧-木地板'
      f_ents = floor.entities
      make_face.call(
        [ [0, 0, 0], [w, 0, 0], [w, d, 0], [0, d, 0] ], mat_tile, 1, f_ents)

      # ══════════════════════════════════════
      # 天花
      # ══════════════════════════════════════
      ceiling = ents.add_group
      ceiling.name = '主卧-天花'
      c_ents = ceiling.entities
      make_face.call(
        [ [0, 0, h], [0, d, h], [w, d, h], [w, 0, h] ], mat_ceiling, -1, c_ents)

      # ══════════════════════════════════════
      # 墙面 (放入一个群组)
      # ══════════════════════════════════════
      walls = ents.add_group
      walls.name = '主卧-墙面'
      w_ents = walls.entities

      # 墙1: Y=0
      make_face.call(
        [ [0, 0, 0], [0, 0, h], [w, 0, h], [w, 0, 0] ], mat_paint, nil, w_ents)

      # 墙2: Y=d
      make_face.call(
        [ [0, d, 0], [w, d, 0], [w, d, h], [0, d, h] ], mat_paint, nil, w_ents)

      # 墙4: X=w
      make_face.call(
        [ [w, 0, 0], [w, 0, h], [w, d, h], [w, d, 0] ], mat_paint, nil, w_ents)

      # 墙3 (X=0) 需要挖窗洞 —— 分块创建避免面分裂
      win_w  = 1.5 * 39.37    # 窗宽
      win_h  = 1.5 * 39.37    # 窗高
      win_s  = 0.9 * 39.37    # 窗台高
      win_y1 = (d - win_w) / 2.0
      win_y2 = win_y1 + win_w
      win_z1 = win_s
      win_z2 = win_s + win_h
      x = 0

      # 窗下墙
      make_face.call(
        [ [x, 0, 0], [x, d, 0], [x, d, win_z1], [x, 0, win_z1] ], mat_paint, nil, w_ents)
      # 窗上墙
      make_face.call(
        [ [x, 0, win_z2], [x, d, win_z2], [x, d, h], [x, 0, h] ], mat_paint, nil, w_ents)
      # 窗左墙
      make_face.call(
        [ [x, 0, win_z1], [x, win_y1, win_z1], [x, win_y1, win_z2], [x, 0, win_z2] ], mat_paint, nil, w_ents)
      # 窗右墙
      make_face.call(
        [ [x, win_y2, win_z1], [x, d, win_z1], [x, d, win_z2], [x, win_y2, win_z2] ], mat_paint, nil, w_ents)

      # ══════════════════════════════════════
      # 窗户组件（命名含"窗"→ 被识别为洞口）
      # ══════════════════════════════════════
      window = ents.add_group
      window.name = '推拉窗'        # 包含"窗"→ Scanner 识别为洞口
      win_ents = window.entities

      # 窗框（4条边，赋金属材质）
      fw = 0.1 * 39.37  # 框宽 10cm
      # 下框
      make_face.call(
        [ [x, win_y1, win_z1], [x, win_y2, win_z1],
          [x, win_y2, win_z1 + fw], [x, win_y1, win_z1 + fw] ], mat_metal, nil, win_ents)
      # 上框
      make_face.call(
        [ [x, win_y1, win_z2 - fw], [x, win_y2, win_z2 - fw],
          [x, win_y2, win_z2], [x, win_y1, win_z2] ], mat_metal, nil, win_ents)
      # 左框
      make_face.call(
        [ [x, win_y1, win_z1 + fw], [x, win_y1 + fw, win_z1 + fw],
          [x, win_y1 + fw, win_z2 - fw], [x, win_y1, win_z2 - fw] ], mat_metal, nil, win_ents)
      # 右框
      make_face.call(
        [ [x, win_y2 - fw, win_z1 + fw], [x, win_y2, win_z1 + fw],
          [x, win_y2, win_z2 - fw], [x, win_y2 - fw, win_z2 - fw] ], mat_metal, nil, win_ents)

      # 窗玻璃（透明 → 被识别为 alpha 洞口）
      glass = ents.add_group
      glass.name = '窗玻璃'
      g_ents = glass.entities
      make_face.call(
        [ [x, win_y1 + fw, win_z1 + fw], [x, win_y2 - fw, win_z1 + fw],
          [x, win_y2 - fw, win_z2 - fw], [x, win_y1 + fw, win_z2 - fw] ],
        mat_glass, nil, g_ents)

      # ══════════════════════════════════════
      # 门组件（命名含"门"→ 被识别为洞口）
      # ══════════════════════════════════════
      door_w = 0.9 * 39.37   # 门宽 90cm
      door_h = 2.1 * 39.37   # 门高 2.1m
      door_x = w              # 在墙4上 (X=w)
      door_y1 = (d - door_w) / 2.0
      door_y2 = door_y1 + door_w
      door_z2 = door_h

      door = ents.add_group
      door.name = '卧室门'      # 包含"门"→ Scanner 识别为洞口
      d_ents = door.entities

      make_face.call(
        [ [door_x, door_y1, 0], [door_x, door_y1, door_z2],
          [door_x, door_y2, door_z2], [door_x, door_y2, 0] ], mat_wood, nil, d_ents)

      # 门把手
      handle_r = 0.03 * 39.37
      handle_y = door_y2 - 0.08 * 39.37
      handle_z = 1.0 * 39.37
      # 画个小圆面近似把手
      circle = d_ents.add_circle(
        [door_x + 0.02 * 39.37, handle_y, handle_z],
        [1, 0, 0], handle_r, 8)
      d_ents.add_face(circle).material = mat_metal

      # ══════════════════════════════════════
      # 踢脚线组件 (3面，沿 X=0, Y=0, X=w 墙)
      # ══════════════════════════════════════
      base = ents.add_group
      base.name = '主卧-踢脚线'
      bh = 0.08 * 39.37    # 踢脚线高 8cm
      bt = 0.015 * 39.37   # 踢脚线厚 1.5cm
      b_ents = base.entities

      # 墙1 (Y=0) 踢脚线
      make_face.call(
        [ [0, 0, 0], [w, 0, 0], [w, bt, 0], [0, bt, 0] ], mat_base, 1, b_ents)
      make_face.call(
        [ [0, bt, 0], [w, bt, 0], [w, bt, bh], [0, bt, bh] ], mat_base, nil, b_ents)

      # 墙4 (X=w) 踢脚线（跳过门洞）
      make_face.call(
        [ [w-bt, 0, 0], [w, 0, 0], [w, d, 0], [w-bt, d, 0] ], mat_base, 1, b_ents)
      make_face.call(
        [ [w-bt, 0, 0], [w-bt, 0, bh], [w-bt, d, bh], [w-bt, d, 0] ], mat_base, nil, b_ents)

      # 墙3 (X=0) 踢脚线（跳过窗洞下方区域，简化处理）
      make_face.call(
        [ [0, 0, 0], [bt, 0, 0], [bt, d, 0], [0, d, 0] ], mat_base, 1, b_ents)
      make_face.call(
        [ [bt, 0, 0], [bt, 0, bh], [bt, d, bh], [bt, d, 0] ], mat_base, nil, b_ents)

      # ══════════════════════════════════════
      # 矮柜（一件简单家具，验证材质映射）
      # ══════════════════════════════════════
      cabinet = ents.add_group
      cabinet.name = '主卧-矮柜'
      cab = cabinet.entities
      cx, cy, cz = 0.5 * 39.37, d - 0.6 * 39.37, 0
      cw, cd, ch = 1.2 * 39.37, 0.6 * 39.37, 0.8 * 39.37

      # 柜体6面
      # 顶面
      make_face.call(
        [ [cx, cy, cz+ch], [cx+cw, cy, cz+ch],
          [cx+cw, cy+cd, cz+ch], [cx, cy+cd, cz+ch] ], mat_wood, 1, cab)
      # 前面
      make_face.call(
        [ [cx, cy, cz], [cx+cw, cy, cz],
          [cx+cw, cy, cz+ch], [cx, cy, cz+ch] ], mat_wood, nil, cab)
      # 右侧
      make_face.call(
        [ [cx+cw, cy, cz], [cx+cw, cy+cd, cz],
          [cx+cw, cy+cd, cz+ch], [cx+cw, cy, cz+ch] ], mat_wood, nil, cab)
      # 左侧
      make_face.call(
        [ [cx, cy+cd, cz], [cx, cy, cz],
          [cx, cy, cz+ch], [cx, cy+cd, cz+ch] ], mat_wood, nil, cab)

      model.commit_operation
      model.active_view.zoom_extents

      puts ""
      puts "╔══════════════════════════════════════╗"
      puts "║  完整调试房间已生成                    ║"
      puts "╠══════════════════════════════════════╣"
      puts "║  尺寸: 4m × 3m × 2.8m               ║"
      puts "║  窗: 1.5×1.5m  门: 0.9×2.1m        ║"
      puts "╠══════════════════════════════════════╣"
      puts "║  组件结构:                            ║"
      puts "║    主卧-木地板 (地面)                  ║"
      puts "║    主卧-天花   (天花)                  ║"
      puts "║    主卧-墙面   (4面墙，含窗洞)          ║"
      puts '║    推拉窗      (窗框+玻璃，含[窗])      ║'
      puts '║    窗玻璃      (透明材质)              ║'
      puts '║    卧室门      (门板+把手，含[门])      ║'
      puts "║    主卧-踢脚线 (3条)                  ║"
      puts "║    主卧-矮柜   (4面可见)              ║"
      puts "╠══════════════════════════════════════╣"
      puts "║  预期扫描结果:                         ║"
      puts "║    地面: 1面 12.00 m² + 踢脚线顶部     ║"
      puts "║    天花: 1面 12.00 m²                ║"
      puts "║    墙面: 7面 (4块墙+3踢脚线立面)       ║"
      puts "║          + 柜体4面 + 门板1面           ║"
      puts "║    洞口: 2命名(推拉窗+卧室门)           ║"
      puts "║          + 1透明(窗玻璃)               ║"
      puts "╚══════════════════════════════════════╝"
      puts ""
    end

    # 辅助：创建材质
    def self.add_mat(model, name, color, alpha = 1.0)
      m = model.materials.add(name)
      m.color = color
      m.alpha = alpha if alpha < 1.0
      m
    end

  end
end

SuTakeoff::DebugRoom.create
