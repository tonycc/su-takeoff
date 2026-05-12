# P4: 规则写入模型属性字典 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mapping + Processes 快照可写入 SU 模型属性字典，随 .skp 文件走，团队成员换机不丢失配置。

**Architecture:** 仿照 Marker 的 `set_attribute` 思路，PluginState.load_data 按优先级加载（模型属性字典 > 本地 JSON > 空默认值）。UI 增加"快照到模型"/"从模型加载"按钮，显式操作避免静默修改 .skp。

**Tech Stack:** Ruby, SketchUp API, JSON

---

### Task 1: PluginState.load_data 增加模型属性字典加载优先级

**Files:**
- Modify: `src/main.rb`

**注意**：此功能依赖 SketchUp 运行时（`Sketchup.active_model`），无法单元测试，需手动验证。

- [ ] **Step 1: 修改 load_data 方法**

当前（main.rb line 42-48）：
```ruby
def load_data
  @mapping.load_json(PluginState.mapping_path)
  @processes.load_json(PluginState.processes_path)
  ignored_data = JSON.parse(File.read(PluginState.ignored_path))
  @ignored = ignored_data
end
```

改为：
```ruby
def load_data
  # Priority 1: model attribute dictionary
  model_data = load_from_model

  # Priority 2: local JSON files (fallback)
  @mapping.load_json(PluginState.mapping_path)
  @processes.load_json(PluginState.processes_path)
  ignored_data = JSON.parse(File.read(PluginState.ignored_path))
  @ignored = ignored_data

  # Override with model data if present and schema version matches
  if model_data && model_data['schema_version'] == 1
    @mapping.load_json_string(model_data['mapping']) if model_data['mapping']
    @processes.load_json_string(model_data['processes']) if model_data['processes']
    @ignored = model_data['ignored'] || []
  end
end

def load_from_model
  model = Sketchup.active_model
  return nil unless model

  dict = model.attribute_dictionary('su_takeoff')
  return nil unless dict

  {
    'schema_version' => dict['schema_version'],
    'mapping' => dict['mapping'],
    'processes' => dict['processes'],
    'ignored' => dict['ignored']
  }
end
```

- [ ] **Step 2: 在 MaterialMapping 和 ProcessLibrary 中增加 load_json_string 方法**

在 mapping.rb 中添加：
```ruby
def load_json_string(json_string)
  data = JSON.parse(json_string)
  @records.clear
  data.each { |su_name, attrs| add(su_name, *attrs.values_at('material_name', 'category', 'unit', 'spec', 'default_waste_rate')) }
end
```

在 process_library.rb 中添加：
```ruby
def load_json_string(json_string)
  data = JSON.parse(json_string)
  @processes.clear
  data.each do |cat, procs|
    procs.each { |p| add_process(cat, p['name'], parse_derivations(p)) }
  end
end
```

---

### Task 2: 增加快照到模型和从模型加载的 action callback

**Files:**
- Modify: `src/ui/dialog.rb`

- [ ] **Step 1: 在 Dialog 构造函数中注册新 action callback**

在 dialog.rb line 30 区域（现有 callback 注册之后）添加：

```ruby
@dialog.add_action_callback('snapshot_to_model') { |action_context|
  snapshot_to_model
  nil
}
@dialog.add_action_callback('load_from_model') { |action_context|
  load_from_model_dialog
  nil
}
```

- [ ] **Step 2: 实现 snapshot_to_model 方法**

```ruby
def snapshot_to_model
  model = Sketchup.active_model
  return unless model

  mapping_json = PluginState.instance.mapping.save_json_string
  processes_json = PluginState.instance.processes.save_json_string
  ignored_json = JSON.generate(PluginState.instance.ignored)

  model.set_attribute('su_takeoff', 'mapping', mapping_json)
  model.set_attribute('su_takeoff', 'processes', processes_json)
  model.set_attribute('su_takeoff', 'ignored', ignored_json)
  model.set_attribute('su_takeoff', 'schema_version', 1)

  @dialog.execute_script("alert('配置已快照到模型')")
end
```

- [ ] **Step 3: 实现 load_from_model_dialog 方法**

```ruby
def load_from_model_dialog
  model_data = PluginState.instance.load_from_model
  if model_data.nil?
    @dialog.execute_script("alert('模型中无 SU Takeoff 配置数据')")
    return
  end

  if model_data['schema_version'] != 1
    @dialog.execute_script("alert('配置版本不匹配，请升级插件后再加载')")
    return
  end

  PluginState.instance.load_data  # 会优先从模型加载
  send_review_state
  send_mappings
  send_processes
  @dialog.execute_script("alert('已从模型加载配置')")
end
```

- [ ] **Step 4: 在 MaterialMapping 和 ProcessLibrary 中增加 save_json_string 方法**

mapping.rb：
```ruby
def save_json_string
  json = @records.transform_values { |r|
    { 'material_name' => r.material_name, 'category' => r.category,
      'unit' => r.unit, 'spec' => r.spec, 'default_waste_rate' => r.default_waste_rate }
  }
  JSON.generate(json)
end
```

process_library.rb：
```ruby
def save_json_string
  grouped = @processes.group_by(&:category)
  json = grouped.transform_values { |procs|
    procs.map { |p|
      { 'name' => p.name, 'derivations' => p.derivations.map { |d|
        { 'layer' => d.layer, 'unit' => d.unit, 'formula' => d.formula,
          'waste_rate' => d.waste_rate, 'category' => d.category }
      } }
    }
  }
  JSON.generate(json)
end
```

---

### Task 3: UI 增加快照按钮

**Files:**
- Modify: `src/ui/app.js`
- Modify: `src/ui/index.html`
- Modify: `src/ui/styles.css`

- [ ] **Step 1: 在设置页增加快照/加载按钮**

在 app.js 中添加：
```javascript
function snapshotToModel() {
  callSketchUp('snapshot_to_model', '{}');
}

function loadFromModel() {
  callSketchUp('load_from_model', '{}');
}
```

在 index.html 设置区域增加按钮：
```html
<button onclick="snapshotToModel()">快照配置到模型</button>
<button onclick="loadFromModel()">从模型加载配置</button>
```

- [ ] **Step 2: 手动验证完整流程**

A 机：配置 mapping → 点击"快照到模型" → 保存 .skp → 发送给 B 机
B 机：打开 .skp → 点击"从模型加载" → 确认 mapping 自动恢复

- [ ] **Step 3: 提交**

```bash
git add src/main.rb src/ui/dialog.rb src/ui/app.js src/ui/index.html src/ui/styles.css src/mapping.rb src/process_library.rb
git commit -m "feat: snapshot/load mapping and processes from model attribute dictionary"
```