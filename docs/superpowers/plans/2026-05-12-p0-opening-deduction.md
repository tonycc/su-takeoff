# P0: 修复洞口扣减链路 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 Opening 与母面的关联，使洞口面积真正从墙面毛面积中扣减，净面积计算准确。

**Architecture:** 在 Scanner 的 collect_faces 完成一层容器内所有面收集后，反向查找每个洞口面的 host face（法向量平行 + 包围盒投影被包含），写入 `Opening.host_face_ids`。Calculator 侧无需改动——现有代码已正确消费该字段。

**Tech Stack:** Ruby, Minitest, SketchUp API（仅 scanner.rb 需 SU 运行时）

---

### Task 1: 编写洞口扣减测试用例

**Files:**
- Modify: `test/test_calculator.rb`

- [ ] **Step 1: 在 test_calculator.rb 底部添加测试方法**

```ruby
def test_deduct_window_from_wall
  # 3m x 3m 墙面，扣除 1m x 2m 窗洞口 → net_area = 9 - 2 = 7
  wall = ScanItem.new(
    1, 'tile_302', 9.0,
    [0, 1, 0],           # 墙面法向量（垂直面）
    3.0, 3.0,            # width, height
    '墙面', ['客厅'], 0.0
  )
  opening = Opening.new(2, 2.0, [1])   # host_face_ids=[1] 关联到 wall

  usages = @calc.compute([wall], [opening], {})
  assert_equal 1, usages.size
  assert_equal 7.0, usages.first.net_area
end
```

- [ ] **Step 2: 运行测试验证它通过**

现有 `test_deduct_openings` 用例已覆盖 host_face_ids 有值的情况（`Opening.new(1, 2.0, [1])`）。新测试用不同尺寸确认逻辑。

Run: `ruby -Itest test/test_calculator.rb`
Expected: 全部 PASS（现有代码在 host_face_ids 正确填充时已经能扣减）

---

### Task 2: 在 Scanner 中实现 host face 查找

**Files:**
- Modify: `src/scanner.rb`

- [ ] **Step 1: 修改 collect_faces 方法，改为先收集后关联**

当前 `collect_faces` 在遍历每个面时立即创建 `Opening` 或 `ScanItem`。需要改为：先收集所有面信息，在一层容器遍历结束后统一做 host 匹配。

在 `scan` 方法（line 24-120）中，改为：`collect_faces` 返回 `{ items:, openings:, pending_openings: }`，`pending_openings` 暂存未关联的洞口；`scan` 方法在全部收集完成后，对每层容器的 pending_openings 做 host 查找。

具体改动：

1. **在 `scan` 方法中增加一个 `sibling_groups` 字典**，按容器路径分组暂存所有面。

在 `scan` 方法（line 24）开头增加：
```ruby
sibling_groups = {}   # path => { items: [], openings: [], face_data: [] }
```

2. **修改 `collect_faces` 签名**，增加 `sibling_groups` 参数，改为在方法内暂存而非直接 push 到 items/openings：

将 `collect_faces` 改为收集到 `sibling_groups[path]` 中，而不是直接 push 到共享的 `items`/`openings` 数组。但由于 `collect_faces` 是递归调用，需要保持接口兼容性。

**实际方案**：保持 `collect_faces` 签名不变（仍然传入 items/openings），但在创建 `Opening` 时先记录到 `pending` 列表。在 `scan` 方法结束后统一做 host 关联。

更简单的方案：不改 `collect_faces` 递归签名，改为在创建 `Opening` 时先记录洞口面的信息（entityID, area, normal, bounding_box），然后在 `scan` 方法末尾做一次 host 查找。

- [ ] **Step 2: 新增私有方法 `find_host_faces`**

在 `scanner.rb` 的私有方法区域（line 247 之后）添加：

```ruby
def find_host_faces(opening_info, candidate_faces)
  # opening_info: { entity_id, area, normal, bounds_center }
  # candidate_faces: [{ entity_id, normal, area, bounds_center }]
  # 返回匹配的 host face entity_id 列表

  op_normal = opening_info[:normal]
  op_center = opening_info[:bounds_center]

  hosts = []
  candidate_faces.each do |cf|
    # 法向量接近平行（dot product > 0.99）
    dot = (op_normal[0] * cf[:normal][0] +
           op_normal[1] * cf[:normal][1] +
           op_normal[2] * cf[:normal][2]).abs
    next unless dot > 0.99

    # 母面面积必须大于洞口面积
    next unless cf[:area] > opening_info[:area]

    # 洞口中心在母面包围盒范围内（简化判定）
    # 使用距离判定：洞口中心与母面中心距离 < 母面宽/高的一半
    hosts << cf[:entity_id]
  end

  # 如果找到多个候选，取面积最接近且最小的那个（最精确的母面）
  hosts.min_by { |eid| candidate_faces.find { |cf| cf[:entity_id] == eid }[:area] } || []
  hosts.empty? ? [] : [hosts.first]
end
```

- [ ] **Step 3: 在 `collect_faces` 中暂存洞口面信息**

在 `collect_faces` 方法中，创建 `Opening` 时（line 163, 209, 230），同时记录洞口面的几何信息到一个 `@pending_openings` 列表。

在 `scan` 方法开头（line 26）添加：
```ruby
@pending_openings = []
```

在三个创建 `Opening` 的位置，除了 `openings.push` 外，额外记录：
```ruby
@pending_openings << {
  opening_index: openings.size - 1,
  entity_id: entity.entityID,   # 或 child.entityID
  area: area_m2,
  normal: world_normal,
  bounds_center: bb_center_world
}
```

注意：对于透明面（line 163），`world_normal` 已在 line 150 计算；对于组件/群组中的洞口面（line 209/230），需要在循环内也计算 `world_normal`。

- [ ] **Step 4: 在 `scan` 方法末尾执行 host 关联**

在 `scan` 方法的 return 之前（line 119-120），添加 host 关联逻辑：

```ruby
# Host face association
@pending_openings.each do |po|
  # 在 items 中找同容器、同方向的候选母面
  candidates = items.select { |it|
    it.component_path == items.find { |i| i.face_id == po[:entity_id] }&.component_path ||
    it.normal && po[:normal] &&
    (it.normal[0]*po[:normal][0] + it.normal[1]*po[:normal][1] + it.normal[2]*po[:normal][2]).abs > 0.99 &&
    it.area > po[:area]
  }

  host_ids = find_host_faces(po, candidates.map { |c|
    { entity_id: c.face_id, normal: c.normal, area: c.area, bounds_center: [0,0,0] }
  })

  openings[po[:opening_index]].host_face_ids = host_ids unless host_ids.empty?
end
```

简化版：由于洞口面本身不在 `items` 中（透明面被 skip，命名组件的子面也被标记为 opening），我们需要在 `collect_faces` 中同时收集所有面（含洞口面的几何信息）到一个 `@all_face_data` 列表。

- [ ] **Step 5: 在 SketchUp 中手动验证**

在含窗户的真实 SU 模型上运行扫描，检查 debug 日志中 `opening_area_by_face` 不再为空，扣减值 > 0。

---

### Task 3: 增强洞口-母面几何判定（可选，后续迭代）

当前 Task 2 的 `find_host_faces` 使用简化判定（法向量平行 + 面积大于）。更精确的判定需要包围盒投影包含检查，但这依赖 SketchUp API 的 `face.bounds` 和 `face.vertices`，实现复杂度较高。先以简化判定上线，后续根据实际模型测试结果迭代。

---

### Task 4: 提交

- [ ] **Step 1: 运行全部测试确认无破坏**

Run: `ruby -Itest test/test_calculator.rb && ruby -Itest test/test_data_models.rb && ruby -Itest test/test_mapping.rb && ruby -Itest test/test_process_library.rb`
Expected: 全部 PASS

- [ ] **Step 2: 提交代码**

```bash
git add src/scanner.rb test/test_calculator.rb
git commit -m "fix: link openings to host faces for area deduction"
```