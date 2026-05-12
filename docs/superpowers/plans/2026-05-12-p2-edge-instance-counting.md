# P2: 边长与实例计数通道 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scanner 同时采集三种实体（face/edge/instance），Calculator 按 unit 分组，报表按单位分列展示，覆盖踢脚线（米）和门窗灯具（个）等线性与离散材料。

**Architecture:** ScanItem 增加 `kind` 和 `unit` 字段，`area` 改名 `qty`（语义是数量）。Scanner 新增 `collect_edges` 和 `collect_instances` 分支。Calculator 分组键扩展为 `[space, part, su_material, unit]`。Mapping 增加 `kind` 约束。

**Tech Stack:** Ruby, Minitest, SketchUp API

---

### Task 1: 改造 ScanItem 数据结构

**Files:**
- Modify: `src/data_models.rb`
- Modify: `test/test_data_models.rb`
- Modify: `src/calculator.rb`
- Modify: `test/test_calculator.rb`
- Modify: `src/scanner.rb`

**注意**：这是一个破坏性变更——`ScanItem.area` 改名为 `ScanItem.qty`，影响所有消费 `.area` 的代码。需要全局搜索替换。

- [ ] **Step 1: 改造 ScanItem struct**

当前（data_models.rb line 3）：
```ruby
ScanItem = Struct.new(:face_id, :su_material, :area, :normal, :width, :height, :layer_name, :component_path, :z_center)
```

改为：
```ruby
ScanItem = Struct.new(:face_id, :su_material, :qty, :unit, :kind, :normal, :width, :height, :layer_name, :component_path, :z_center)
```

- `area` → `qty`（语义是数量：m²/m/个）
- 新增 `unit`（'m2' / 'm' / '个'）
- 新增 `kind`（`:face` / `:edge` / `:instance`）

- [ ] **Step 2: 全局替换 ScanItem.area → ScanItem.qty**

需要修改的文件：
- `src/calculator.rb` — 所有 `.area` 调用改为 `.qty`
- `src/scanner.rb` — 创建 ScanItem 时传入 qty 而不是 area
- `src/ui/dialog.rb` — `build_material_info` 中的 `.area` 改为 `.qty`
- `test/test_calculator.rb` — 所有构造 ScanItem 的测试用 `.qty`
- `test/test_data_models.rb` — ScanItem 创建测试

搜索命令确认所有 `.area` 引用：
```bash
grep -rn '\.area' src/ test/ | grep -v 'area_m2' | grep -v 'opening_area' | grep -v 'net_area'
```

逐个文件修改，确保 `.area` → `.qty` 替换完整。

- [ ] **Step 3: 更新 Scanner 中 ScanItem 创建**

当前（scanner.rb line 177-187）：
```ruby
ScanItem.new(
  entity.entityID,
  mat_name,
  area_m2,
  world_normal,
  width_m,
  height_m,
  layer_name,
  path,
  z_center_m
)
```

改为：
```ruby
ScanItem.new(
  entity.entityID,
  mat_name,
  area_m2,         # qty
  'm2',            # unit
  :face,           # kind
  world_normal,
  width_m,
  height_m,
  layer_name,
  path,
  z_center_m
)
```

- [ ] **Step 4: 更新 Calculator.compute 中的分组键**

当前分组键（calculator.rb line 45-63）是 `[space, part, su_material]`。改为 `[space, part, su_material, unit]`。

- [ ] **Step 5: 更新所有测试用例**

在 test/test_calculator.rb 中所有 ScanItem 创建处增加 unit 和 kind 参数：

```ruby
ScanItem.new(1, 'tile_302', 50.0, 'm2', :face, [0,1,0], 5.0, 10.0, '墙面', ['客厅'], 0.0)
```

在 test/test_data_models.rb 中：
```ruby
def test_scan_item_creation
  item = ScanItem.new(1, 'tile_302', 10.0, 'm2', :face, [0,1,0], 3.0, 3.0, '墙面', ['客厅'], 0.0)
  assert_equal 1, item.face_id
  assert_equal 10.0, item.qty
  assert_equal 'm2', item.unit
  assert_equal :face, item.kind
end
```

- [ ] **Step 6: 运行全部测试确认替换完整**

Run: `ruby -Itest test/test_calculator.rb && ruby -Itest test/test_data_models.rb`
Expected: 全部 PASS

- [ ] **Step 7: 提交 ScanItem 结构改造**

```bash
git add src/data_models.rb src/calculator.rb src/scanner.rb src/ui/dialog.rb test/test_calculator.rb test/test_data_models.rb
git commit -m "refactor: ScanItem.area → .qty, add unit and kind fields"
```

---

### Task 2: Scanner 新增 Edge 和 Instance 采集

**Files:**
- Modify: `src/scanner.rb`

- [ ] **Step 1: 在 collect_faces 中增加 Edge 分支**

在 `collect_faces` 方法（scanner.rb line 125-243）中，当前只处理 `Sketchup::Face`、`Sketchup::ComponentInstance`、`Sketchup::Group`。需要在 `Sketchup::Face` 之前增加 `Sketchup::Edge` 分支。

```ruby
when Sketchup::Edge
  # 只采集赋了材质的边，或位于"线性 layer 列表"的边
  mat_name = entity.material ? entity.material.name : nil
  layer_name = entity.layer ? entity.layer.name : ''

  # 优先级：有材质名 或 layer 名匹配踢脚线等关键词
  unless mat_name || @linear_layers.include?(layer_name)
    next  # skip unmaterialized edges not in linear layers
  end

  length_m = entity.length.to_m
  next if length_m < 0.01  # skip tiny edges

  items.push ScanItem.new(
    entity.entityID,
    mat_name || layer_name,  # su_material: use material name or layer name
    length_m,                # qty: 长度（米）
    'm',                     # unit
    :edge,                   # kind
    [0, 0, 0],               # normal: edges don't have normals
    length_m, 0.0,           # width=length, height=0
    layer_name,
    path,
    entity.bounds.center.z / 1000.0  # z_center in meters
  )
```

- [ ] **Step 2: 在构造函数中初始化 linear_layers**

在 Scanner 构造函数（line 12-21）中添加：
```ruby
@linear_layers = ['踢脚线', '阴阳角', '石膏线', '门套']  # 可配置
```

- [ ] **Step 3: 增加 ComponentInstance 的实例计数**

当前 ComponentInstance（line 194-215）只做递归遍历和 opening 检测。需要在非 opening 的 ComponentInstance 上也做实例计数。

修改逻辑：如果一个 ComponentInstance 的 definition.name 在 mapping 表中有匹配，且不是 opening，则产出一条 instance ScanItem：

```ruby
when Sketchup::ComponentInstance
  name = entity.definition.name

  if opening_name?(name)
    # existing opening detection logic (unchanged)
    ...
  elsif @mapping_instance_names.include?(name)
    # 实例计数：产出 kind=:instance 的 ScanItem
    mat_name = name  # 用 definition name 作为 su_material
    layer_name = entity.layer ? entity.layer.name : ''
    center_z = entity.bounds.center.z / 1000.0

    items.push ScanItem.new(
      entity.entityID,
      mat_name,
      1.0,              # qty: 1 个
      '个',             # unit
      :instance,        # kind
      [0, 0, 0],        # normal
      0.0, 0.0,         # width/height: not applicable
      layer_name,
      path,
      center_z
    )
  end

  # 仍然递归遍历子实体
  ...
```

- [ ] **Step 4: 在构造函数中初始化 mapping_instance_names**

在 Scanner 构造函数中添加：
```ruby
@mapping_instance_names = []  # 从 PluginState.mapping 获取可匹配的 instance 名称
```

或者改为让 Scanner.scan 接受一个 `instance_names` 参数：
```ruby
def scan(selection_only: false, instance_names: [])
  @mapping_instance_names = instance_names
  ...
end
```

Dialog.do_scan 调用时传入：
```ruby
instance_names = PluginState.instance.mapping.all.select { |r| r.unit == '个' }.map(&:su_material_name)
```

- [ ] **Step 5: 手动验证**

在包含踢脚线 edge 和门组件的测试模型上运行扫描，确认 items 中包含 `kind=:edge` 和 `kind=:instance` 的 ScanItem。

---

### Task 3: Calculator 支持不同 unit 分组

**Files:**
- Modify: `src/calculator.rb`
- Modify: `test/test_calculator.rb`

- [ ] **Step 1: 编写 edge 和 instance 计算测试**

```ruby
def test_edge_item_counted_in_meters
  edge = ScanItem.new(1, '踢脚线', 12.0, 'm', :edge, [0,0,0], 12.0, 0.0, '墙面', ['客厅'], 0.0)
  mapping = MaterialMapping.new
  mapping.add('踢脚线', '实木踢脚线', '木材', 'm', '', 0.05)

  calc = Calculator.new(mapping, ProcessLibrary.new)
  usages = calc.compute([edge], [], {})
  assert_equal 1, usages.size
  assert_equal 12.0, usages.first.net_area   # qty in meters
  assert_equal 'm', usages.first.unit
end

def test_instance_item_counted_by_unit
  door = ScanItem.new(1, '木门', 1.0, '个', :instance, [0,0,0], 0.0, 0.0, '墙面', ['卧室'], 0.0)
  mapping = MaterialMapping.new
  mapping.add('木门', '实木门', '门窗', '个', '', 0.0)

  calc = Calculator.new(mapping, ProcessLibrary.new)
  usages = calc.compute([door], [], {}, instance_names: ['木门'])
  assert_equal 1, usages.size
  assert_equal 1.0, usages.first.net_area  # qty = 1
  assert_equal '个', usages.first.unit
end
```

- [ ] **Step 2: 修改 Calculator 分组键扩展**

当前分组键 `[space, part, su_material]` 改为 `[space, part, su_material, unit]`。不同 unit 的 ScanItem 不合并。

修改 `compute` 方法中的 group_by 逻辑。

- [ ] **Step 3: 运行测试**

Run: `ruby -Itest test/test_calculator.rb`
Expected: 全部 PASS

- [ ] **Step 4: 提交**

```bash
git add src/calculator.rb test/test_calculator.rb src/scanner.rb
git commit -m "feat: scanner collects edges and instances, calculator groups by unit"
```

---

### Task 4: UI 报表按 unit 分列展示

**Files:**
- Modify: `src/ui/app.js`
- Modify: `src/ui/styles.css`

- [ ] **Step 1: 报表增加单位列**

修改 `renderResults` 中的表格渲染，增加单位列。不同 unit 的行显示不同单位标签（m²/m/个）。

- [ ] **Step 2: 手动验证**

在 SketchUp 中确认报表正确展示不同单位的行。

- [ ] **Step 3: 提交**

```bash
git add src/ui/app.js src/ui/styles.css
git commit -m "feat: report table shows unit column for mixed quantity types"
```