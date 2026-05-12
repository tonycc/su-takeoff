# P1: 派生项（ProcessLibrary 扩展为派生规则）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 一个 SU 材质产出多条材料记录（主材 + 辅材 + 基层），覆盖装修用量中缺失最大的部分。

**Architecture:** 将 ProcessLibrary 从"替代损耗率表"扩展为"派生规则表"。一条工艺 = 多条派生项（Derivation）。Calculator fan-out：每个 SU 材质分组 → 查工艺 → 每条 derivation 生成一条 MaterialUsage。老 schema（仅 waste_rate）自动兼容转换。

**Tech Stack:** Ruby, Minitest, JSON

---

### Task 1: 定义 Derivation 数据结构

**Files:**
- Modify: `src/data_models.rb`
- Modify: `src/process_library.rb`
- Modify: `test/test_data_models.rb`
- Modify: `test/test_process_library.rb`

- [ ] **Step 1: 在 data_models.rb 中定义 Derivation struct**

在 `Opening` 定义之前（line 50 之前），添加：

```ruby
Derivation = Struct.new(:layer, :unit, :formula, :waste_rate, :category, keyword_init: true)
```

- [ ] **Step 2: 扩展 ProcessDef struct**

当前 `ProcessDef`（process_library.rb line 4）：
```ruby
ProcessDef = Struct.new(:category, :name, :waste_rate, keyword_init: true)
```

改为：
```ruby
ProcessDef = Struct.new(:category, :name, :derivations, keyword_init: true)
```

- [ ] **Step 3: 添加 ProcessDef 兼容方法**

老 schema 的 ProcessDef 只有 waste_rate，需要能转换。在 process_library.rb 中给 ProcessDef 添加方法：

```ruby
# 在 ProcessDef 定义后添加
class ProcessDef
  def waste_rate
    derivations&.first&.waste_rate || 0.05
  end
end
```

这样 `default_waste_rate` 方法仍然能工作。

- [ ] **Step 4: 为 MaterialUsage 增加 layer 和 parent_su_material 字段**

当前 `MaterialUsage`（data_models.rb line 16-47）的 attr_accessor 是：
```ruby
attr_accessor :space, :part, :material_name, :category, :spec,
              :net_area, :waste_rate, :purchase_qty, :items, :su_material_name
```

增加两个：
```ruby
attr_accessor :space, :part, :material_name, :category, :spec,
              :net_area, :waste_rate, :purchase_qty, :items, :su_material_name,
              :layer, :parent_su_material
```

在 `initialize` 方法（line 21-33）中增加默认值：
```ruby
layer: ''
parent_su_material: ''
```

在 `to_h` 方法（line 39-46）中增加：
```ruby
layer: @layer,
parent_su_material: @parent_su_material
```

- [ ] **Step 5: 编写 Derivation 和扩展 ProcessDef 的测试**

在 test_data_models.rb 底部添加：

```ruby
class TestDerivation < Minitest::Test
  def test_derivation_creation
    d = Derivation.new(layer: '瓷砖', unit: 'm2', formula: 'area', waste_rate: 0.05, category: '主材')
    assert_equal '瓷砖', d.layer
    assert_equal 'm2', d.unit
    assert_equal 'area', d.formula
    assert_equal 0.05, d.waste_rate
    assert_equal '主材', d.category
  end
end
```

在 test_process_library.rb 中修改 setup 和测试以适配新结构：

```ruby
def setup
  @lib = ProcessLibrary.new
  @lib.add_process('瓷砖', '密缝铺贴', [
    Derivation.new(layer: '基层处理', unit: 'm2', formula: 'area', waste_rate: 0.02, category: '辅材'),
    Derivation.new(layer: '瓷砖', unit: 'm2', formula: 'area', waste_rate: 0.05, category: '主材')
  ])
end

def test_get_processes_for_category
  processes = @lib.processes_for('瓷砖')
  assert_equal 1, processes.size
  assert_equal 2, processes.first.derivations.size
end

def test_get_default_waste_rate
  rate = @lib.default_waste_rate('瓷砖')
  assert_equal 0.02, rate  # first derivation's waste_rate
end
```

- [ ] **Step 6: 运行测试验证结构定义正确**

Run: `ruby -Itest test/test_data_models.rb && ruby -Itest test/test_process_library.rb`
Expected: FAIL（因为 ProcessLibrary.add_process 签名和 load_json 还未适配新结构）

---

### Task 2: 改造 ProcessLibrary 适配新 schema

**Files:**
- Modify: `src/process_library.rb`
- Modify: `test/test_process_library.rb`

- [ ] **Step 1: 改造 ProcessLibrary.add_process 签名**

当前（line 11-13）：
```ruby
def add_process(category, name, waste_rate)
  @processes << ProcessDef.new(category: category, name: name, waste_rate: waste_rate)
end
```

改为：
```ruby
def add_process(category, name, derivations)
  @processes << ProcessDef.new(category: category, name: name, derivations: derivations)
end
```

- [ ] **Step 2: 改造 ProcessLibrary.load_json 适配新 schema**

当前（line 34-42）：
```ruby
def load_json(path)
  data = JSON.parse(File.read(path))
  @processes.clear
  data.each do |cat, procs|
    procs.each do |p|
      add_process(cat, p['name'], p['waste_rate'])
    end
  end
end
```

改为：
```ruby
def load_json(path)
  data = JSON.parse(File.read(path))
  @processes.clear
  data.each do |cat, procs|
    procs.each do |p|
      derivations = if p['derivations']
        # 新 schema：每条含 layer/unit/formula/waste_rate/category
        p['derivations'].map { |d|
          Derivation.new(
            layer: d['layer'],
            unit: d['unit'] || 'm2',
            formula: d['formula'] || 'area',
            waste_rate: d['waste_rate'],
            category: d['category'] || '主材'
          )
        }
      else
        # 老 schema 兼容：自动包一层 derivation
        [Derivation.new(
          layer: cat,
          unit: 'm2',
          formula: 'area',
          waste_rate: p['waste_rate'],
          category: '主材'
        )]
      end
      add_process(cat, p['name'], derivations)
    end
  end
end
```

- [ ] **Step 3: 改造 ProcessLibrary.save_json 适配新 schema**

当前（line 28-32）：
```ruby
def save_json(path)
  grouped = @processes.group_by(&:category)
  json = grouped.transform_values { |procs|
    procs.map { |p| { 'name' => p.name, 'waste_rate' => p.waste_rate } }
  }
  File.write(path, JSON.generate(json))
end
```

改为：
```ruby
def save_json(path)
  grouped = @processes.group_by(&:category)
  json = grouped.transform_values { |procs|
    procs.map { |p|
      {
        'name' => p.name,
        'derivations' => p.derivations.map { |d|
          { 'layer' => d.layer, 'unit' => d.unit, 'formula' => d.formula,
            'waste_rate' => d.waste_rate, 'category' => d.category }
        }
      }
    }
  }
  File.write(path, JSON.generate(json))
end
```

- [ ] **Step 4: 改造 default_waste_rate 方法**

当前（line 19-22）：
```ruby
def default_waste_rate(category)
  proc = @processes.find { |p| p.category == category }
  proc ? proc.waste_rate : 0.05
end
```

ProcessDef 已通过 Step 3 中的类扩展方法提供 `waste_rate`（取第一个 derivation 的 waste_rate），所以此方法无需改动。

- [ ] **Step 5: 更新 test_process_library.rb 测试覆盖新 schema**

完整重写 test/test_process_library.rb：

```ruby
require 'test_helper'
require 'src/mapping'
require 'src/process_library'

module SuTakeoff
  class TestProcessLibrary < Minitest::Test
    def setup
      @lib = ProcessLibrary.new
      @lib.add_process('瓷砖', '密缝铺贴', [
        Derivation.new(layer: '基层处理', unit: 'm2', formula: 'area', waste_rate: 0.02, category: '辅材'),
        Derivation.new(layer: '瓷砖粘结剂', unit: 'kg', formula: 'area * 5', waste_rate: 0.05, category: '辅材'),
        Derivation.new(layer: '瓷砖', unit: 'm2', formula: 'area', waste_rate: 0.05, category: '主材'),
        Derivation.new(layer: '填缝剂', unit: 'kg', formula: 'area * 0.3', waste_rate: 0.10, category: '辅材')
      ])
    end

    def test_get_processes_for_category
      processes = @lib.processes_for('瓷砖')
      assert_equal 1, processes.size
      assert_equal 4, processes.first.derivations.size
    end

    def test_get_default_waste_rate_from_first_derivation
      rate = @lib.default_waste_rate('瓷砖')
      assert_equal 0.02, rate
    end

    def test_process_for_nonexistent_category
      assert_empty @lib.processes_for('木材')
    end

    def test_save_and_load_json_new_schema
      path = File.join(__dir__, 'tmp_processes.json')
      @lib.save_json(path)
      lib2 = ProcessLibrary.new
      lib2.load_json(path)
      procs = lib2.processes_for('瓷砖')
      assert_equal 1, procs.size
      assert_equal 4, procs.first.derivations.size
      assert_equal '基层处理', procs.first.derivations[0].layer
      assert_equal 'kg', procs.first.derivations[1].unit
      FileUtils.rm(path) if File.exist?(path)
    end

    def test_load_old_schema_compat
      # 老格式: { "瓷砖": [{ "name": "密缝铺贴", "waste_rate": 0.05 }] }
      old_json = JSON.generate({ '瓷砖' => [{ 'name' => '密缝铺贴', 'waste_rate' => 0.05 }] })
      path = File.join(__dir__, 'tmp_old_processes.json')
      File.write(path, old_json)
      lib = ProcessLibrary.new
      lib.load_json(path)
      procs = lib.processes_for('瓷砖')
      assert_equal 1, procs.size
      assert_equal 1, procs.first.derivations.size
      assert_equal '密缝铺贴', procs.first.name
      assert_equal 0.05, procs.first.derivations.first.waste_rate
      FileUtils.rm(path) if File.exist?(path)
    end
  end
end
```

- [ ] **Step 6: 运行测试验证 ProcessLibrary 改造**

Run: `ruby -Itest test/test_process_library.rb`
Expected: 全部 PASS

- [ ] **Step 7: 提交 ProcessLibrary 改造**

```bash
git add src/data_models.rb src/process_library.rb test/test_data_models.rb test/test_process_library.rb
git commit -m "feat: expand ProcessDef with Derivation array for derived material items"
```

---

### Task 3: 改造 Calculator 支持 fan-out

**Files:**
- Modify: `src/calculator.rb`
- Modify: `test/test_calculator.rb`

- [ ] **Step 1: 编写 fan-out 测试用例**

在 test/test_calculator.rb 中添加：

```ruby
def test_derivation_fan_out_produces_multiple_usages
  # 1 张 10m2 墙砖面 → 期望产出 4 条 MaterialUsage
  item = ScanItem.new(
    1, 'tile_302', 10.0,
    [0, 1, 0], 3.0, 3.0,
    '墙面', ['客厅'], 0.0
  )

  # ProcessLibrary 配了密缝铺贴（4 条 derivation）
  lib = ProcessLibrary.new
  lib.add_process('瓷砖', '密缝铺贴', [
    Derivation.new(layer: '基层处理', unit: 'm2', formula: 'area', waste_rate: 0.02, category: '辅材'),
    Derivation.new(layer: '瓷砖粘结剂', unit: 'kg', formula: 'area * 5', waste_rate: 0.05, category: '辅材'),
    Derivation.new(layer: '瓷砖', unit: 'm2', formula: 'area', waste_rate: 0.05, category: '主材'),
    Derivation.new(layer: '填缝剂', unit: 'kg', formula: 'area * 0.3', waste_rate: 0.10, category: '辅材')
  ])
  calc = Calculator.new(@mapping, lib)

  usages = calc.compute([item], [], {})
  # 当前只产出 1 条 MaterialUsage（fan-out 未实现）
  # 期望产出 4 条
  assert_equal 4, usages.size

  # 验证每条 usage 的字段
  base = usages.find { |u| u.layer == '基层处理' }
  assert_equal 10.0, base.net_area
  assert_equal 0.02, base.waste_rate
  assert_equal 'm2', base.unit

  glue = usages.find { |u| u.layer == '瓷砖粘结剂' }
  assert_equal 50.0, glue.net_area   # area * 5 = 10 * 5
  assert_equal 0.05, glue.waste_rate
  assert_equal 'kg', glue.unit
end
```

- [ ] **Step 2: 运行测试验证它失败**

Run: `ruby -Itest test/test_calculator.rb`
Expected: FAIL — 当前只产出 1 条 MaterialUsage

- [ ] **Step 3: 改造 Calculator.compute 的分组→产出逻辑**

当前 Calculator.compute（line 79-112）的逻辑是：每个分组产出一条 MaterialUsage。需要改为：每个分组查工艺 → 遍历 derivations → 每条 derivation 产出一条 MaterialUsage。

修改 `compute` 方法中的产出循环（line 79-112）：

```ruby
# 替换 line 79-112 的整个产出块
grp_items.each do |grp_key, grp_items_list|
  space, part, su_mat = grp_key

  gross = grp_items_list.sum(&:area)
  total_deduction = grp_items_list.sum { |it| opening_area_by_face[it.face_id] || 0.0 }
  net_area_per_item = grp_items_list.map { |it|
    [it.area - (opening_area_by_face[it.face_id] || 0.0), 0.0].max
  }
  net_area = net_area_per_item.sum

  mapping_rec = @mapping.get(su_mat)
  next unless mapping_rec

  # 查工艺的派生规则
  process = @processes.processes_for(mapping_rec.category).first
  derivations = process ? process.derivations : nil

  if derivations && !derivations.empty?
    # Fan-out: 每条 derivation 产出一条 MaterialUsage
    derivations.each do |deriv|
      deriv_qty = eval_formula(deriv.formula, net_area)
      usage = MaterialUsage.new(
        space: space,
        part: part,
        material_name: deriv.layer,
        category: deriv.category,
        spec: mapping_rec.spec,
        net_area: deriv_qty,
        waste_rate: deriv.waste_rate,
        su_material_name: su_mat,
        layer: deriv.layer,
        parent_su_material: su_mat
      )
      usage.items = grp_items_list
      group_results << usage
    end
  else
    # 无工艺或无派生规则：回退到单条产出（兼容老逻辑）
    waste_rate = process ? process.waste_rate : mapping_rec.default_waste_rate
    usage = MaterialUsage.new(
      space: space,
      part: part,
      material_name: mapping_rec.material_name,
      category: mapping_rec.category,
      spec: mapping_rec.spec,
      net_area: net_area,
      waste_rate: waste_rate,
      su_material_name: su_mat
    )
    usage.items = grp_items_list
    group_results << usage
  end
end
```

- [ ] **Step 4: 添加 eval_formula 辅助方法**

在 Calculator 私有方法区域添加（暂时只支持简单表达式，P3 会替换为正式 Formula 类）：

```ruby
def eval_formula(formula, area)
  # 简化版：只支持 area 变量和基本运算
  # P3 会替换为 Formula.eval
  case formula
  when 'area'
    area
  else
    # 尝试解析 "area * N" 格式
    if formula.match?(/^area\s*\*\s*[\d.]+$/)
      multiplier = formula.split('*').last.strip.to_f
      area * multiplier
    else
      area  # fallback: 无法解析的表达式按 area 处理
    end
  end
end
```

- [ ] **Step 5: 修改 MaterialUsage 初始化逻辑支持 unit 字段**

MaterialUsage 目前不存储 `unit`。在 MaterialUsage 的 attr_accessor 中增加 `:unit`：

```ruby
attr_accessor :space, :part, :material_name, :category, :spec,
              :net_area, :waste_rate, :purchase_qty, :items, :su_material_name,
              :layer, :parent_su_material, :unit
```

在 `initialize` 中增加 `unit: 'm2'` 默认值。
在 `to_h` 中增加 `unit: @unit`。

同时，`purchase_qty` 的计算逻辑需要考虑 `unit`：
- 对于 m2 单位：`net_area * (1 + waste_rate)`
- 对于 kg/个 等单位：`net_area * (1 + waste_rate)`（net_area 实际是 qty，公式相同）

暂时保持公式不变（`net_area * (1 + waste_rate).round(2)`），因为 `net_area` 在 derivation 场景中已经是公式算出的数量值。

- [ ] **Step 6: 运行测试验证 fan-out**

Run: `ruby -Itest test/test_calculator.rb`
Expected: 全部 PASS（新 test_derivation_fan_out 和所有旧测试）

- [ ] **Step 7: 提交 Calculator fan-out**

```bash
git add src/calculator.rb src/data_models.rb test/test_calculator.rb
git commit -m "feat: calculator fan-out produces multiple MaterialUsage per derivation"
```

---

### Task 4: 重写 default_processes.json 为新 schema

**Files:**
- Modify: `data/default_processes.json`

- [ ] **Step 1: 用新 schema 重写 default_processes.json**

```json
{
  "瓷砖": [
    {
      "name": "密缝铺贴",
      "derivations": [
        { "layer": "基层处理", "unit": "m2", "formula": "area", "waste_rate": 0.02, "category": "辅材" },
        { "layer": "瓷砖粘结剂", "unit": "kg", "formula": "area * 5", "waste_rate": 0.05, "category": "辅材" },
        { "layer": "瓷砖", "unit": "m2", "formula": "area", "waste_rate": 0.05, "category": "主材" },
        { "layer": "填缝剂", "unit": "kg", "formula": "area * 0.3", "waste_rate": 0.10, "category": "辅材" }
      ]
    },
    {
      "name": "留缝铺贴",
      "derivations": [
        { "layer": "基层处理", "unit": "m2", "formula": "area", "waste_rate": 0.02, "category": "辅材" },
        { "layer": "瓷砖粘结剂", "unit": "kg", "formula": "area * 5", "waste_rate": 0.05, "category": "辅材" },
        { "layer": "瓷砖", "unit": "m2", "formula": "area", "waste_rate": 0.08, "category": "主材" },
        { "layer": "填缝剂", "unit": "kg", "formula": "area * 0.5", "waste_rate": 0.10, "category": "辅材" }
      ]
    },
    {
      "name": "斜铺",
      "derivations": [
        { "layer": "基层处理", "unit": "m2", "formula": "area", "waste_rate": 0.02, "category": "辅材" },
        { "layer": "瓷砖粘结剂", "unit": "kg", "formula": "area * 6", "waste_rate": 0.05, "category": "辅材" },
        { "layer": "瓷砖", "unit": "m2", "formula": "area", "waste_rate": 0.15, "category": "主材" },
        { "layer": "填缝剂", "unit": "kg", "formula": "area * 0.5", "waste_rate": 0.10, "category": "辅材" }
      ]
    },
    {
      "name": "人字拼",
      "derivations": [
        { "layer": "基层处理", "unit": "m2", "formula": "area", "waste_rate": 0.02, "category": "辅材" },
        { "layer": "瓷砖粘结剂", "unit": "kg", "formula": "area * 6", "waste_rate": 0.05, "category": "辅材" },
        { "layer": "瓷砖", "unit": "m2", "formula": "area", "waste_rate": 0.20, "category": "主材" },
        { "layer": "填缝剂", "unit": "kg", "formula": "area * 0.5", "waste_rate": 0.10, "category": "辅材" }
      ]
    }
  ],
  "石材": [
    {
      "name": "干挂",
      "derivations": [
        { "layer": "基层处理", "unit": "m2", "formula": "area", "waste_rate": 0.02, "category": "辅材" },
        { "layer": "干挂骨架", "unit": "m2", "formula": "area", "waste_rate": 0.05, "category": "辅材" },
        { "layer": "石材", "unit": "m2", "formula": "area", "waste_rate": 0.05, "category": "主材" }
      ]
    },
    {
      "name": "湿贴",
      "derivations": [
        { "layer": "基层处理", "unit": "m2", "formula": "area", "waste_rate": 0.02, "category": "辅材" },
        { "layer": "水泥砂浆", "unit": "m2", "formula": "area", "waste_rate": 0.03, "category": "辅材" },
        { "layer": "石材", "unit": "m2", "formula": "area", "waste_rate": 0.08, "category": "主材" }
      ]
    }
  ],
  "涂料": [
    {
      "name": "喷涂",
      "derivations": [
        { "layer": "基层处理", "unit": "m2", "formula": "area", "waste_rate": 0.02, "category": "辅材" },
        { "layer": "腻子", "unit": "m2", "formula": "area", "waste_rate": 0.03, "category": "辅材" },
        { "layer": "涂料", "unit": "m2", "formula": "area", "waste_rate": 0.05, "category": "主材" }
      ]
    },
    {
      "name": "滚涂",
      "derivations": [
        { "layer": "基层处理", "unit": "m2", "formula": "area", "waste_rate": 0.02, "category": "辅材" },
        { "layer": "腻子", "unit": "m2", "formula": "area", "waste_rate": 0.03, "category": "辅材" },
        { "layer": "涂料", "unit": "m2", "formula": "area", "waste_rate": 0.05, "category": "主材" }
      ]
    }
  ],
  "墙纸": [
    {
      "name": "对缝",
      "derivations": [
        { "layer": "基层处理", "unit": "m2", "formula": "area", "waste_rate": 0.02, "category": "辅材" },
        { "layer": "墙纸胶", "unit": "m2", "formula": "area", "waste_rate": 0.03, "category": "辅材" },
        { "layer": "墙纸", "unit": "m2", "formula": "area", "waste_rate": 0.10, "category": "主材" }
      ]
    },
    {
      "name": "不对缝",
      "derivations": [
        { "layer": "基层处理", "unit": "m2", "formula": "area", "waste_rate": 0.02, "category": "辅材" },
        { "layer": "墙纸胶", "unit": "m2", "formula": "area", "waste_rate": 0.03, "category": "辅材" },
        { "layer": "墙纸", "unit": "m2", "formula": "area", "waste_rate": 0.05, "category": "主材" }
      ]
    }
  ],
  "木材": [
    {
      "name": "直铺",
      "derivations": [
        { "layer": "防潮膜", "unit": "m2", "formula": "area", "waste_rate": 0.02, "category": "辅材" },
        { "layer": "木地板", "unit": "m2", "formula": "area", "waste_rate": 0.05, "category": "主材" }
      ]
    },
    {
      "name": "人字拼",
      "derivations": [
        { "layer": "防潮膜", "unit": "m2", "formula": "area", "waste_rate": 0.02, "category": "辅材" },
        { "layer": "木地板", "unit": "m2", "formula": "area", "waste_rate": 0.15, "category": "主材" }
      ]
    }
  ]
}
```

- [ ] **Step 2: 验证 load_json 兼容**

由于 `default_processes.json` 已改为新 schema，确认 `PluginState.load_data` 能正确加载。

Run: `ruby -Itest test/test_process_library.rb`
Expected: 全部 PASS

- [ ] **Step 3: 提交数据文件**

```bash
git add data/default_processes.json
git commit -m "feat: rewrite default_processes.json with derivation schema"
```

---

### Task 5: UI 适配派生项展示（按材料汇总报表）

**Files:**
- Modify: `src/ui/app.js`
- Modify: `src/ui/dialog.rb`

- [ ] **Step 1: Dialog.finalize_and_compute 传递工艺信息到 UI**

当前 `finalize_and_compute`（dialog.rb line 104-143）推送的 result 数据只含 usages 的 to_h 数组。派生项产出多条 usage 后，UI 需要按 layer 和 unit 分组展示。

修改 `finalize_and_compute` 中构建 results 的逻辑，确保每条 MaterialUsage.to_h 包含 `layer`、`unit`、`parent_su_material` 字段（这些已在 Task 1/Step 4 中添加到 to_h）。

无需额外改动——MaterialUsage.to_h 已包含新字段。

- [ ] **Step 2: app.js 报表渲染适配多派生项**

修改 `renderResults`（app.js line 234-278）中"按材料汇总"视图，增加 unit 列和 layer 显示：

当前表格列：`材料名 | 分类 | 净面积 | 损耗率 | 采购量`

改为：`材料名 | 分类 | 层名 | 单位 | 数量 | 损耗率 | 采购量`

对于"按空间"视图，在空间下按 layer 分行展示。

具体修改：在 `renderResults` 的 table header 和 row 渲染中增加 `layer`、`unit` 列。`net_area` 列名改为"数量"（因为不再一定是面积）。

- [ ] **Step 3: 手动验证 UI**

在 SketchUp 中打开模型 → 扫描 → 完成映射 → 统计 → 确认报表中出现辅材独立行，单位列正确显示 m²/kg。

---

### Task 6: 最终验证与提交

- [ ] **Step 1: 运行全部测试**

Run: `ruby -Itest test/test_calculator.rb && ruby -Itest test/test_data_models.rb && ruby -Itest test/test_mapping.rb && ruby -Itest test/test_process_library.rb`
Expected: 全部 PASS

- [ ] **Step 2: 提交 UI 适配**

```bash
git add src/ui/app.js src/ui/dialog.rb src/ui/styles.css
git commit -m "feat: UI adapts to derivation items with layer/unit columns"
```