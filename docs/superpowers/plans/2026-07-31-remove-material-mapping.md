# 彻底删除材料映射 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 彻底删除材料映射（MaterialMapping）数据模型、UI 页面、算量第 3/3.5 档、推送 material_tag、忽略材料功能及相关配置/测试，保留组件映射/算量标签/图层规则/几何启发/组件级 SKU。

**Architecture:** 分 6 阶段（P0-P5），每阶段保持代码可运行、全量测试可绿。P0 先把 model_view 复用的 SKU 自动补全从 mapping.js 迁出；P1 删映射页 UI；P2 算量去 mapping（policy/calculator/presenter）；P3 推送去 material_tag（之后推送报 422）；P4 删数据模型+ignore+3.5 策略；P5 设置页/视图收尾+测试清理。

**Tech Stack:** Ruby（SketchUp 插件，Minitest 独立于 SU）、原生 JS（HtmlDialog 全局命名空间）。

**通用约定：**
- 分支：`git checkout -b feat/remove-material-mapping`（开工前创建）。
- 全量测试命令：`ruby -Itest -e "Dir.glob('test/test_*.rb').each { |f| require f.sub('test/', '') }"`，每阶段结束须 0 failures。
- 单文件语法：`ruby -c <file>`；JS：`node --check <file>`。
- 提交信息中文 conventional。每个任务结束提交。
- 设计文档：`docs/superpowers/specs/2026-07-31-remove-material-mapping-design.md`。

---

## Phase P0 — 准备：迁移 SKU 自动补全

### Task 1: 把 SKU 自动补全从 mapping.js 迁到 model_view.js

**Files:**
- Modify: `src/ui/js/mapping.js`（删除自动补全块）
- Modify: `src/ui/js/model_view.js`（接收自动补全块）

> 背景：`model_view.js` 的 `buildSkuCell`（组件行 SKU 选择）调用 `bindSkuAutocomplete`，该函数当前定义在 `mapping.js`。P1 要删 `mapping.js`，故先把这块迁到唯一使用者 `model_view.js`。

- [ ] **Step 1: 从 mapping.js 剪切自动补全块**

删除 `src/ui/js/mapping.js` 中从注释行 `// ---------------- SKU 自动补全（供模型视图组件行 buildSkuCell 复用）----------------` 开始到文件结尾的全部内容（含 `window._skuReqId`、`window._skuActiveRow`、`_ensureSkuCloser` IIFE、`bindSkuAutocomplete`、`window.receiveSkuResults`、`skuOption`）。

- [ ] **Step 2: 粘贴到 model_view.js 末尾**

把上一步剪下的整块代码原样追加到 `src/ui/js/model_view.js` 文件末尾（在最后一个函数之后）。无需改动其内容（它只用全局 `callSketchUp`，与文件无关）。

- [ ] **Step 3: 语法校验**

Run: `node --check src/ui/js/mapping.js && node --check src/ui/js/model_view.js`
Expected: 无输出（通过）。

- [ ] **Step 4: 提交**

```bash
git add src/ui/js/mapping.js src/ui/js/model_view.js
git commit -m "refactor(ui): SKU 自动补全从 mapping.js 迁移到 model_view.js（唯一使用者）"
```

---

## Phase P1 — 删除材料映射页 UI

### Task 2: 删除 index.html 中映射页元素

**Files:**
- Modify: `src/ui/index.html`

- [ ] **Step 1: 删除导航按钮**

删除 line 28 整行：
```html
      <button class="sb-nav" data-page="mapping" disabled>材料映射</button>
```

- [ ] **Step 2: 删除映射页容器**

删除 line 60-62 的 `#page-mapping` 块：
```html
    <div id="page-mapping" class="page-content" style="display:none">
      <div id="mapping-content"></div>
    </div>
```

- [ ] **Step 3: 删除两个行模板**

删除 `<template id="tmpl-mapping-row">...</template>`（约 line 77-87）与 `<template id="tmpl-mapping-unmapped-row">...</template>`（约 line 89-106）两个完整 template 块。

- [ ] **Step 4: 删除 mapping.js 脚本引用**

删除 line 110 整行：
```html
<script src="js/mapping.js"></script>
```

- [ ] **Step 5: 提交**

```bash
git add src/ui/index.html
git commit -m "refactor(ui): index.html 移除材料映射页导航/容器/行模板/脚本引用"
```

### Task 3: 删除 mapping.js 文件与 app.js 路由

**Files:**
- Delete: `src/ui/js/mapping.js`
- Modify: `src/ui/app.js`

- [ ] **Step 1: 删除 mapping.js**

Run: `git rm src/ui/js/mapping.js`

- [ ] **Step 2: 删除 app.js 的 get_mappings 路由**

`src/ui/app.js` 删除这一行（约 line 31）：
```js
  if (page === 'mapping') callSketchUp('get_mappings');
```

- [ ] **Step 3: 语法校验**

Run: `node --check src/ui/app.js`
Expected: 通过。

- [ ] **Step 4: 提交**

```bash
git add src/ui/app.js
git commit -m "refactor(ui): 删除 mapping.js 与 app.js 的 get_mappings 路由"
```

### Task 4: 删除 dialog.rb 的映射回调与方法

**Files:**
- Modify: `src/ui/dialog.rb`

- [ ] **Step 1: 删除回调注册**

删除这几行回调注册（约 line 54-60 区域）：
```ruby
      @dialog.add_action_callback('get_mappings') { |_ctx| require_login! && send_mappings }
      @dialog.add_action_callback('save_mapping') { |_ctx, json| require_login! && save_mapping(json) }
      @dialog.add_action_callback('delete_mapping') { |_ctx, su_name| require_login! && delete_mapping(su_name) }
      @dialog.add_action_callback('import_csv') { |_ctx| require_login! && import_csv_dialog }
      @dialog.add_action_callback('export_csv') { |_ctx| require_login! && export_csv_dialog }
```
（保留 `get_component_mappings`/`save_component_mapping`/`delete_component_mapping`/`search_skus`/`set_component_sku` 等其它回调。）

- [ ] **Step 2: 删除映射方法**

删除以下方法定义：`send_mappings`、`save_mapping`、`delete_mapping`、`import_csv_dialog`、`export_csv_dialog`（约 line 410-531 区域）。保留 `send_component_mappings`/`save_component_mapping`/`delete_component_mapping`/`set_component_sku`。

- [ ] **Step 3: 语法校验**

Run: `ruby -c src/ui/dialog.rb`
Expected: `Syntax OK`。

- [ ] **Step 4: 提交**

```bash
git add src/ui/dialog.rb
git commit -m "refactor(dialog): 移除材料映射 CRUD 与 CSV 导入导出回调"
```

> 注：此阶段结束，映射页 UI 已消失，但 `MaterialMapping` 数据模型与算量/推送仍在用（P2-P4 处理）。全量测试此时仍应绿（test_mapping.rb 等仍在，mapping.rb 未删）。

---

## Phase P2 — 算量去 mapping

### Task 5: TakeoffPolicy 移除第 3/3.5 档与 mapping 参数

**Files:**
- Modify: `src/takeoff_policy.rb`
- Test: `test/test_takeoff_policy.rb`

- [ ] **Step 1: 先调整测试（去掉 mapping 与第 3 档用例）**

`test/test_takeoff_policy.rb`：
- 所有 `TakeoffPolicy.new(mapping: ..., ...)` 去掉 `mapping:` 参数（改为 `TakeoffPolicy.new(layer_rules: ..., tag_defs: ..., ...)`；构造 mapping 的 setup 行删除）。
- 删除专门测试第 3 档（材质 unit→method）与第 3.5 档（auto_match，如 `assert_includes [:skirting_linear, :skirting_linear_default]`、`[:pipe_length_default, :wire_path]` 的用例，约 line 289/307-309）的测试方法。
- 保留第 1 档（AttrDict tag）、第 2 档（layer_rules）、第 4 档（heuristic）、instance/solid 等用例。

- [ ] **Step 2: 运行测试确认失败**

Run: `ruby -Itest test/test_takeoff_policy.rb`
Expected: FAIL（`initialize` 仍要求/接受 mapping；第 3 档仍在）。

- [ ] **Step 3: 修改 initialize 去掉 mapping**

`src/takeoff_policy.rb`，`initialize` 签名去掉 `mapping:`，删除 `@mapping = mapping`：
```ruby
    def initialize(layer_rules: {}, heuristics_enabled: true,
                   tag_defs: {}, thresholds: {}, strategies: nil)
      @layer_rules = normalize_layer_rules(layer_rules)
      @tag_defs = tag_defs || {}
      @heuristics = heuristics_enabled
      @min_aspect      = thresholds[:linear_min_aspect_ratio] || DEFAULT_MIN_ASPECT
      @max_short_edge  = thresholds[:linear_max_short_edge_m] || DEFAULT_MAX_SHORT_EDGE
      @vertical_slab_gap     = thresholds[:vertical_slab_gap_m] || DEFAULT_VERTICAL_SLAB_GAP
      @vertical_slab_area_tol = thresholds[:vertical_slab_area_tolerance] || DEFAULT_VERTICAL_SLAB_TOL
      @strategies = strategies || Strategies::Registry.global
    end
```
（同时删除 initialize 上方注释里 `# mapping: MaterialMapping 实例（用于 unit 兜底）` 一行。）

- [ ] **Step 4: 重写 resolve（去第 3/3.5 档）**

把 `resolve(item)` 改为：
```ruby
    def resolve(item)
      # instance：永远按整件统计，绕过策略链
      if item.kind == :instance
        return result_for(:count, :component)
      end

      # 容器级整体量取已固化为 ScanItem.kind，Calculator 直接信任
      if item.kind == :solid
        return result_for(:volume, :layer)
      end
      if item.kind == :linear_solid
        return result_for(:length, :layer)
      end
      if item.kind == :count_solid
        return result_for(:count, :layer)
      end

      # 1. AttrDict 覆盖
      if item.tags && (m = item.tags[:method])
        sym = m.to_sym
        return result_for(sym, :attr) if METHODS.include?(sym)
      end

      # 2. 图层规则
      if item.layer_name && (m = @layer_rules[item.layer_name])
        return result_for(m, :layer)
      end

      # 4. 启发式（弱信号，仅产生待确认建议）
      if @heuristics && linear_face?(item)
        strategy = @strategies.get(:face_linear) || @strategies.default_for(:length)
        return ResolveResult.new(strategy: strategy, source: :heuristic)
      end

      result_for(:skip, :default)
    end
```

- [ ] **Step 5: 删除 3.5 档相关私有方法**

删除 `auto_match_strategy`、`build_match_context`、`method_from_unit` 三个私有方法。保留 `result_for`、`linear_face?`、`normalize_layer_rules`、`self.classify_unit`、`method_for_unit`（`method_for_unit` 仍被 Scanner 用于组件映射 unit→method）。

- [ ] **Step 6: 同步修改 main.rb#takeoff_policy（关键，否则运行时报 unknown keyword）**

`src/main.rb` 的 `takeoff_policy` 方法删除 `mapping: @mapping,` 一行：
```ruby
    def takeoff_policy
      TakeoffPolicy.new(
        layer_rules: @config['layer_rules'] || {},
        tag_defs: @config['tag_defs'] || {},
        heuristics_enabled: @config.fetch('heuristics_enabled', true),
        thresholds: (@config['heuristic_thresholds'] || {}).transform_keys(&:to_sym)
      )
    end
```
（`@mapping` 此时仍存在，P4 才删；此处仅停止把它传给 Policy。）

- [ ] **Step 7: 运行测试确认通过**

Run: `ruby -Itest test/test_takeoff_policy.rb && ruby -c src/main.rb`
Expected: PASS + `Syntax OK`。

- [ ] **Step 8: 提交**

```bash
git add src/takeoff_policy.rb src/main.rb test/test_takeoff_policy.rb
git commit -m "refactor(policy): 移除算量第 3 档（材质 unit）与 3.5 档（自动匹配）及 mapping 参数"
```

### Task 6: Calculator 去 mapping 依赖

**Files:**
- Modify: `src/calculator.rb`
- Test: `test/test_compute_geometry_only.rb`

- [ ] **Step 1: 调整测试**

`test/test_compute_geometry_only.rb`：
- `Calculator.new(@mapping, @cm, policy: @policy)` 改为 `Calculator.new(@cm, policy: @policy)`；`Calculator.new(@mapping, @cm)` 改为 `Calculator.new(@cm)`。
- 删除依赖 mapping 的用例：`test_unmapped_materials_included`（调 `unmapped_materials`）、以及"不传 policy 走 mapping 兜底"的用例（约 line 105/117，`Calculator.new(@mapping, @cm)` 后断言 source==:mapping 的）。setup 中 `@mapping = MaterialMapping.new ...` 若仅服务于这些用例可删除（若其它用例仍用 mapping 构造 item 材质名，材质名字符串保留即可，不必有 MaterialMapping 实例）。

- [ ] **Step 2: 运行测试确认失败**

Run: `ruby -Itest test/test_compute_geometry_only.rb`
Expected: FAIL（签名/方法不匹配）。

- [ ] **Step 3: 修改 initialize 与 lookup_record**

`src/calculator.rb`：
```ruby
    def initialize(component_mapping = nil, policy: nil)
      @component_mapping = component_mapping
      @policy = policy
    end
```
删除 `unmapped_materials` 方法。`lookup_record` 改为只对 instance 查组件映射：
```ruby
    def lookup_record(item)
      return @component_mapping&.get(item.su_material) if item.kind == :instance

      nil
    end
```

- [ ] **Step 4: 删除 mapping 兜底分支与 unit_for 的 mapping 情形**

`resolve_method` 删除 `if @policy ... else (mapping 兜底) end` 中的 else 分支（policy 缺失时的 mapping 兜底），改为无 policy 时直接走启发兜底：
```ruby
    def resolve_method(item)
      if @policy
        r = @policy.resolve(item)
        if r.method == :skip && r.source == :default
          return geometry_unmapped_fallback(item)
        end
        return {
          method: r.method,
          source: r.source,
          strategy_name: r.strategy && r.strategy.name,
          unit: unit_for(item, r.method, r.source)
        }
      end

      geometry_unmapped_fallback(item)
    end
```
`unit_for` 删除 `:length` 中 `source == :mapping && record...` 特例，简化为：
```ruby
    def unit_for(item, method, source, record = nil)
      record ||= lookup_record(item)
      strategies = @policy&.strategies || Strategies::Registry.global
      case method
      when :length
        strategies.default_for(:length)&.default_unit || 'm'
      when :count
        record&.unit || item.unit || strategies.default_for(:count)&.default_unit || '个'
      when :area
        record&.unit || item.unit || strategies.default_for(:area)&.default_unit || 'm²'
      else
        strategies.default_for(method)&.default_unit || ''
      end
    end
```
（`source` 参数保留以兼容调用签名，但不再用于 :mapping 判断。）

- [ ] **Step 5: 运行测试确认通过**

Run: `ruby -Itest test/test_compute_geometry_only.rb`
Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add src/calculator.rb test/test_compute_geometry_only.rb
git commit -m "refactor(calculator): 移除 mapping 兜底/unmapped_materials/lookup 的 mapping 分支"
```

### Task 7: WorkbenchPresenter 去 mapping 与 unresolved/ignored

**Files:**
- Modify: `src/workbench_presenter.rb`
- Modify: `src/api/quantity_payload_builder.rb`（仅改 `Calculator.new` 调用签名）
- Test: `test/test_wall_model.rb`、`test/test_workbench_presenter.rb`

- [ ] **Step 1: 调整测试**

- `test/test_wall_model.rb`：`usages_for` 辅助方法中 `WorkbenchPresenter.new(... mapping: @mapping ...)` 去掉 `mapping:`；setup 中仅为 mapping 而建的 `@mapping`（若 component_mapping/policy 不依赖它）可删；删除断言 `unresolved`/`ignored`/`mapped` 的用例（若有）。
- `test/test_workbench_presenter.rb`：现有两个 `component_skus` 测试中 `WorkbenchPresenter.new(... mapping: mapping ...)` 去掉 `mapping:` 参数（`mapping = MaterialMapping.new` 行删除）。

- [ ] **Step 2: 运行测试确认失败**

Run: `ruby -Itest test/test_workbench_presenter.rb test/test_wall_model.rb`
Expected: FAIL（仍要求 mapping:）。

- [ ] **Step 3: 修改 WorkbenchPresenter**

`src/workbench_presenter.rb`：
- `initialize` 去掉 `mapping:` 参数与 `@mapping = mapping`。
- 删除 `unresolved_names`、`ignored_names`、`mapped_names` 方法。
- `calc` 改为 `@calc ||= Calculator.new(@component_mapping, policy: @policy)`。
- `build` 输出删除 `ignored: ignored_names` 与 `unresolved: unresolved_names` 两键。
- `build_overview` 中删除 `ignored_count: ignored_names.size` 与 `unresolved_count: unresolved_names.size`（若 overview 引用了它们；保留其它统计）。

- [ ] **Step 4: 同步修改 payload_builder 的 Calculator.new 调用**

`src/api/quantity_payload_builder.rb` line 60：
```ruby
        resolutions = Calculator.new(@component_mapping, policy: @policy)
                                .compute_geometry_only(@items, @openings)
```
（此处仅改 Calculator 调用签名；payload_builder 自身的 `@mapping`/material_tag 在 P3 处理。）

- [ ] **Step 5: 运行测试确认通过**

Run: `ruby -Itest test/test_workbench_presenter.rb test/test_wall_model.rb`
Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add src/workbench_presenter.rb src/api/quantity_payload_builder.rb test/test_wall_model.rb test/test_workbench_presenter.rb
git commit -m "refactor(presenter): 移除 mapping 依赖与 unresolved/mapped/ignored 统计"
```

> P2 结束跑全量：`ruby -Itest -e "Dir.glob('test/test_*.rb').each { |f| require f.sub('test/', '') }"` 须 0 failures。

---

## Phase P3 — 推送去 material_tag（之后推送报 422）

### Task 8: QuantityPayloadBuilder 移除 material_tag/未映射拦截/忽略

**Files:**
- Modify: `src/api/quantity_payload_builder.rb`
- Test: `test/test_quantity_payload_builder.rb`

- [ ] **Step 1: 调整测试**

`test/test_quantity_payload_builder.rb`：
- 构造器去掉 `mapping:`/`ignored:`（改为 `QuantityPayloadBuilder.new(items:, openings:, component_mapping:, policy:, binding:)`）。
- 删除断言 `material_tag`、`unmapped_material`、`missing_platform_material_tag`、忽略跳过的用例。
- 保留/改写：payload 顶层结构、幂等 hash 稳定、source_version ≤64、组件/面/part 编码等用例——其中 face 断言改为不含 material_tag（`{code, area_m2}`），part 断言改为 `{code, name, quantity, unit}`（name 取自 `item.su_material`）。

- [ ] **Step 2: 运行测试确认失败**

Run: `ruby -Itest test/test_quantity_payload_builder.rb`
Expected: FAIL。

- [ ] **Step 3: 修改 initialize**

```ruby
      def initialize(items:, openings:, component_mapping:, policy:, binding:)
        @items = items
        @openings = openings || []
        @component_mapping = component_mapping
        @policy = policy
        @binding = binding
      end
```

- [ ] **Step 4: 重写 build_components（去 material_tag/未映射/忽略）**

```ruby
      def build_components(issues)
        resolutions = Calculator.new(@component_mapping, policy: @policy)
                                .compute_geometry_only(@items, @openings)
        opening_area_by_face = build_opening_area_map
        grouped = {}

        resolutions.each do |resolution|
          item = resolution[:item]
          component_code = component_code_for(item)
          grouped[component_code] ||= {
            code: component_code,
            name: component_name_for(item),
            component_type: component_type_for(item),
            faces: [],
            part_accumulator: {}
          }

          if resolution[:method] == :area && item.kind == :face
            grouped[component_code][:faces] << {
              code: face_code_for(item),
              area_m2: round_quantity([(item.qty_area || item.qty).to_f - (opening_area_by_face[item.face_id] || 0.0), 0.0].max)
            }
          else
            add_part(grouped[component_code], item, resolution)
          end
        end

        grouped.values.map do |component|
          parts = component.delete(:part_accumulator).values.map do |part|
            part.merge(quantity: round_quantity(part[:quantity]))
          end.sort_by { |p| p[:code] }
          component[:faces] = component[:faces].sort_by { |f| f[:code] }
          component[:parts] = parts
          component
        end.sort_by { |c| c[:code] }
      end
```

- [ ] **Step 5: 重写 add_part（去 record/material_tag）**

```ruby
      def add_part(component, item, resolution)
        method = resolution[:method]
        unit = resolution[:unit].to_s.empty? ? item.unit.to_s : resolution[:unit].to_s
        name = item.su_material.to_s
        key = [component[:code], method, unit, name].join('|')
        code = code_with_prefix('p', key)
        component[:part_accumulator][code] ||= {
          code: code,
          name: name,
          quantity: 0.0,
          unit: unit
        }
        component[:part_accumulator][code][:quantity] += quantity_for(item, method)
      end
```

- [ ] **Step 6: 删除 lookup_record 与 ignored?**

删除 `lookup_record` 与 `ignored?` 两个私有方法。保留 `component_code_for`/`face_code_for`/`component_name_for`/`component_type_for`/`stable_component_path`/`code_with_prefix`/`quantity_for`/`round_quantity`/`issue`/`build_opening_area_map`/`validate_project!`。

- [ ] **Step 7: 运行测试确认通过**

Run: `ruby -Itest test/test_quantity_payload_builder.rb`
Expected: PASS。

- [ ] **Step 8: 提交**

```bash
git add src/api/quantity_payload_builder.rb test/test_quantity_payload_builder.rb
git commit -m "refactor(api): 推送 payload 移除 material_tag/未映射拦截/忽略跳过（推送将报 422，产品code关联另立任务）"
```

### Task 9: QuantitySyncService 去 mapping/ignored 传参

**Files:**
- Modify: `src/api/quantity_sync_service.rb`
- Modify: `src/ui/dialog.rb`（cloud_push 构造 service 处）
- Test: `test/test_quantity_sync_service.rb`

- [ ] **Step 1: 调整测试**

`test/test_quantity_sync_service.rb`：构造 `QuantitySyncService.new(...)` 去掉 `mapping:`/`ignored:` 参数；删除/调整依赖 mapping 的断言。

- [ ] **Step 2: 修改 initialize 与 build_payload**

`src/api/quantity_sync_service.rb`：
- `initialize` 去掉 `mapping:`/`ignored:` 参数与 `@mapping`/`@ignored` 赋值（保留 `component_mapping:`）。
- `build_payload` 中 `QuantityPayloadBuilder.new(...)` 去掉 `mapping: @mapping`/`ignored: @ignored`：
```ruby
        build = QuantityPayloadBuilder.new(
          items: items,
          openings: openings,
          component_mapping: @component_mapping,
          policy: @policy,
          binding: @binding
        ).build
```

- [ ] **Step 3: 修改 dialog.rb 的 cloud_push**

`src/ui/dialog.rb` 中 `cloud_push` 构造 `QuantitySyncService.new(...)`（约 line 738/769/793 区域）去掉 `mapping: ...`/`ignored: ...` 传参（保留 `component_mapping:`）。

- [ ] **Step 4: 校验**

Run: `ruby -c src/api/quantity_sync_service.rb && ruby -c src/ui/dialog.rb && ruby -Itest test/test_quantity_sync_service.rb`
Expected: `Syntax OK` + PASS。

- [ ] **Step 5: 提交**

```bash
git add src/api/quantity_sync_service.rb src/ui/dialog.rb test/test_quantity_sync_service.rb
git commit -m "refactor(api): QuantitySyncService 去除 mapping/ignored 传参"
```

> P3 结束跑全量须 0 failures。此时推送因缺 material_tag 会收到服务端 422（预期）。

---

## Phase P4 — 删除数据模型 + ignore + 3.5 策略

### Task 10: 删除 MaterialMapping 数据模型与装配

**Files:**
- Delete: `src/mapping.rb`、`test/test_mapping.rb`、`data/default_mapping.json`
- Modify: `su_takeoff.rb`、`src/main.rb`

- [ ] **Step 1: 删除文件**

Run: `git rm src/mapping.rb test/test_mapping.rb data/default_mapping.json`

- [ ] **Step 2: su_takeoff.rb 去 require**

`su_takeoff.rb` 的 SOURCE_FILES 数组删除 `'src/mapping',` 一行。

- [ ] **Step 3: main.rb 去 mapping 装配**

`src/main.rb`：
- `attr_reader :mapping, :component_mapping, :component_sku, :ignored, :config` → 去掉 `:mapping,`。
- `initialize` 删除 `@mapping = MaterialMapping.new`。
- 删除 `self.mapping_path` 方法。
- 删除 `save_mapping_to_model_dict` 方法。
- `load_data` 删除 mapping 分支：
  ```ruby
      if model_dict[:mapping]
        @mapping.load_json_string(model_dict[:mapping])
      else
        @mapping.load_json(self.class.mapping_path)
      end
  ```
- `load_from_model_dict` 删除 `result[:mapping] = dict['mapping'] if dict['mapping']`。
- `reset_plugin_state!` 删除 `state.instance_variable_set(:@mapping, MaterialMapping.new)`。
- （`takeoff_policy` 的 `mapping: @mapping` 已在 Task 5 删除，此处无需再改。）

- [ ] **Step 4: 校验**

Run: `ruby -c src/main.rb && ruby -c su_takeoff.rb`
Expected: `Syntax OK`。

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "refactor: 删除 MaterialMapping 数据模型、装配与默认数据文件"
```

### Task 11: 删除忽略材料功能

**Files:**
- Modify: `src/main.rb`、`src/ui/dialog.rb`、`src/ui/js/settings.js`（忽略卡 P5 删，本任务删回调）
- Delete: `data/ignored_materials.json`（若存在）
- Modify: `.gitignore`

- [ ] **Step 1: main.rb 去 ignored**

`src/main.rb`：
- `attr_reader` 去掉 `:ignored`。
- `initialize` 删除 `@ignored = []`。
- 删除 `ignore!`/`set_ignored!`/`unignore!`/`save_ignored`/`save_ignored_to_model_dict`/`self.ignored_path` 方法。
- `load_data` 删除 ignored 分支（`if model_dict[:ignored] ... elsif File.exist?(self.class.ignored_path) ...`）。
- `load_from_model_dict` 删除 `result[:ignored] = dict['ignored'] if dict['ignored']`。
- `reset_plugin_state!` 删除 `state.instance_variable_set(:@ignored, [])`。

- [ ] **Step 2: dialog.rb 去 ignore 回调与方法**

删除回调注册：
```ruby
      @dialog.add_action_callback('ignore_material') { |_ctx, name| require_login! && ignore_material(name) }
      @dialog.add_action_callback('unignore') { |_ctx, name| require_login! && unignore(name) }
      @dialog.add_action_callback('clear_ignored') { |_ctx| require_login! && clear_ignored }
```
删除方法 `ignore_material`/`unignore`/`clear_ignored`。`send_settings` 中删除 `ignored: state.ignored,` 一行。

- [ ] **Step 3: 删除 ignored_materials.json 与 .gitignore 行**

Run: `git rm data/ignored_materials.json` （若文件不存在则跳过此命令）
`.gitignore` 删除 `data/ignored_materials.json` 一行。

- [ ] **Step 4: 校验**

Run: `ruby -c src/main.rb && ruby -c src/ui/dialog.rb`
Expected: `Syntax OK`。

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "refactor: 删除忽略材料功能（PluginState/dialog 回调/数据文件）"
```

### Task 12: 删除 3.5 档专用策略与独占长度算法

**Files:**
- Delete: `src/strategies/skirting_linear.rb`、`src/strategies/wire_path.rb`、`src/length_calculators/segmented_path.rb`、`test/test_skirting_linear_strategy.rb`、`test/test_length_calculator_segmented_path.rb`
- Modify: `src/strategies/builtin.rb`、`data/strategies.json`、`test/test_helper.rb`、`test/test_strategies_builtin_registration.rb`、`su_takeoff.rb`

> 前置核实：`EdgeBased` 被 `Chained`（默认长度链）使用，**保留**；`SegmentedPath` 仅 `WirePath` 使用，可删。

- [ ] **Step 1: 删除策略与算法文件及测试**

Run:
```bash
git rm src/strategies/skirting_linear.rb src/strategies/wire_path.rb \
       src/length_calculators/segmented_path.rb \
       test/test_skirting_linear_strategy.rb test/test_length_calculator_segmented_path.rb
```

- [ ] **Step 2: builtin.rb 去注册**

`src/strategies/builtin.rb` 删除：
```ruby
        Registry.register(SkirtingLinear.new)   # 不传 default_for（避免与 SolidLinear 冲突）
        Registry.register(WirePath.new)         # 电线/管材：SegmentedPath 算法
```

- [ ] **Step 3: strategies.json 清空名称匹配变体**

`data/strategies.json` 内容改为空对象：
```json
{}
```
（删除 `skirting_linear_default`/`pipe_length_default`/`handrail_length_default`——它们仅经 3.5 档名称匹配触发，3.5 已删。）

- [ ] **Step 4: su_takeoff.rb 去 require**

`su_takeoff.rb` SOURCE_FILES 删除 `'src/strategies/skirting_linear'`、`'src/strategies/wire_path'`、`'src/length_calculators/segmented_path'` 三行。

- [ ] **Step 5: test_helper.rb 去 require**

`test/test_helper.rb` 删除：
```ruby
require 'src/length_calculators/segmented_path'
require 'src/strategies/skirting_linear'
require 'src/strategies/wire_path'
```

- [ ] **Step 6: 调整注册测试**

`test/test_strategies_builtin_registration.rb`：删除/修正断言 `skirting_linear`/`wire_path` 已注册的用例（约 line 52 注释与相关断言），保留 FaceArea/FaceLinear/InstanceCount/SolidVolume/SolidLinear/SolidCount/Skip 的注册断言。

- [ ] **Step 7: 校验**

Run: `ruby -Itest -e "Dir.glob('test/test_*.rb').each { |f| require f.sub('test/', '') }"`
Expected: 0 failures, 0 errors。

- [ ] **Step 8: 提交**

```bash
git add -A
git commit -m "refactor(strategies): 删除 3.5 档专用策略 SkirtingLinear/WirePath 与独占算法 SegmentedPath"
```

> P4 结束跑全量须 0 failures。

---

## Phase P5 — 设置页/视图收尾 + 测试清理

### Task 13: 设置页移除材料分类/可选单位/忽略材料卡

**Files:**
- Modify: `src/ui/js/settings.js`
- Modify: `src/ui/dialog.rb`（send_settings/save_config）
- Modify: `src/main.rb`（save_config 参数与 config 迁移）

> 注意：`renderCategoryUnitConfig` 同时被「材料分类」（删）与「组件分类」（留）使用，故保留该函数；但其单位下拉原取自 `config_units`（可选单位，删），改为硬编码默认单位列表，使「组件分类」仍可选单位。

- [ ] **Step 1: settings.js 删除三张卡**

`src/ui/js/settings.js` 的 `renderSettings` 中删除：
```js
  html += '<div class="settings-card">' + renderCategoryUnitConfig('材料分类', 'material_category_units', data.material_category_units || data.category_units || []) + '</div>';
  html += '<div class="settings-card">' + renderUnitTagConfig(data.config_units || []) + '</div>';
  html += '<div class="settings-card">' + renderIgnoredSection(data.ignored || []) + '</div>';
```
保留「组件分类」「算量标签」「几何启发式」「启发式阈值」四张卡。

- [ ] **Step 2: renderCategoryUnitConfig 单位选项改用默认列表**

`renderCategoryUnitConfig` 中：
```js
  var cfgUnits = (window._sharedConfig && window._sharedConfig.config_units) || [];
```
改为：
```js
  var cfgUnits = ['m²', 'm', 'm³', '个'];
```

- [ ] **Step 3: 删除可选单位与忽略材料的函数**

删除 `renderUnitTagConfig`/`addUnitTag`/`removeUnitTag`（可选单位）与 `renderIgnoredSection`/`unignoreMaterial`/`clearAllIgnored`（忽略材料）这些函数。保留 `renderCategoryUnitConfig`/`addCategoryUnit`/`removeCategoryUnit`。

- [ ] **Step 4: persistConfig 去 material_category_units/units**

`persistConfig` 改为：
```js
function persistConfig() {
  var data = window._sharedConfig;
  callSketchUp('save_config', JSON.stringify({
    component_category_units: data.component_category_units || [],
    heuristics_enabled: data.heuristics_enabled !== false,
    heuristic_thresholds: data.heuristic_thresholds || {},
    tag_defs: data.tag_defs || {}
  }));
}
```

- [ ] **Step 5: 启发式提示文案去"材质映射"**

`renderHeuristicsConfig` 中 hint 文案：
```js
    '关闭后，未在图层规则或材质映射中显式标注的窄长面将不会被自动判定为线材。' +
```
改为：
```js
    '关闭后，未在图层规则或算量标签中显式标注的窄长面将不会被自动判定为线材。' +
```

- [ ] **Step 6: dialog.rb send_settings/save_config 去材料字段**

`send_settings` 的 data 删除 `material_category_units:` 与 `config_units:` 两行（保留 component_category_units/tag_defs/heuristics/thresholds）。
`save_config` 调用 `PluginState.instance.save_config(...)` 去掉 `material_category_units:` 与 `units:` 两个参数。

- [ ] **Step 7: main.rb save_config 去材料参数与迁移逻辑**

`src/main.rb` 的 `save_config` 方法：
- 签名去掉 `material_category_units:` 与 `units:` 参数。
- 方法体 `@config = {...}` 删除 `'material_category_units' => ...` 与 `'units' => ...` 两项。
- `load_data` 删除迁移逻辑：
  ```ruby
      if @config['category_units'] && !@config['material_category_units']
        @config['material_category_units'] = @config['category_units']
      end
      @config['material_category_units'] ||= []
      @config['component_category_units'] ||= []
  ```
  改为仅保留：
  ```ruby
      @config['component_category_units'] ||= []
  ```

- [ ] **Step 8: 校验**

Run: `node --check src/ui/js/settings.js && ruby -c src/ui/dialog.rb && ruby -c src/main.rb`
Expected: 通过。

- [ ] **Step 9: 提交**

```bash
git add src/ui/js/settings.js src/ui/dialog.rb src/main.rb
git commit -m "refactor(settings): 移除材料分类/可选单位/忽略材料配置卡及相关 config 字段"
```

### Task 14: model_view 移除「待处理」列与忽略展示

**Files:**
- Modify: `src/ui/js/model_view.js`

> 「待处理」列与忽略展示依赖 presenter 已删除的 `data.unresolved`/`data.ignored`，需一并清理。

- [ ] **Step 1: 删除 unresolvedSet/ignoredSet 构建**

删除三处（约 line 20-23、114-117、564-567）形如：
```js
  var unresolvedSet = {};
  (data.unresolved || []).forEach(function(n) { unresolvedSet[n] = true; });
  var ignoredSet = {};
  (data.ignored || []).forEach(function(n) { ignoredSet[n] = true; });
```

- [ ] **Step 2: 表头与排序去掉「待处理」列**

- `POS_SORT_COLS`（约 line 240）删除 `, 11: 'unresolved'`。
- 表头数组（约 line 261）`var cols = [..., '天花', '待处理', '操作'];` 删除 `'待处理',`。
- CSV 表头（约 line 1243）`rows.push([..., '天花', '待处理']);` 删除 `'待处理'`。

- [ ] **Step 3: 删除统计中的 unresolvedCount**

`rollupStats`/合并统计中删除 `unresolvedCount` 的初始化与累加（约 line 78、88、119、143-145、164），以及 `if (!ignoredSet[u.su_material]) {...}` 包裹改为直接统计（去掉 ignoredSet 判断）。

- [ ] **Step 4: 删除各行「待处理」单元格与忽略状态**

- 材料汇总行 `matStatus`（约 line 569-570）删除 `ignored`/`unresolved` 判定（及相关 `tr.unmapped`/`tr.unresolved` 染色逻辑）。
- 面明细行「待」单元格（约 line 644）`unresolvedSet[usage.su_material] ? '待' : '-'` 所在 td 删除。
- 组件节点行（约 line 749、759、914）与合并行（约 line 1125、1127）的 `unresolved` 变量与对应列删除。
- CSV 数据行（约 line 1291）删除 `stats.unresolvedCount` 一列。

- [ ] **Step 5: 清理 styles.css 中 unmapped/unresolved 行样式（可选）**

`src/ui/styles.css` 删除 `tr.unmapped`、`.unmapped-row` 等仅服务于已删功能的样式（约 line 70-71、383-384）。

- [ ] **Step 6: 校验**

Run: `node --check src/ui/js/model_view.js`
Expected: 通过。

- [ ] **Step 7: 提交**

```bash
git add src/ui/js/model_view.js src/ui/styles.css
git commit -m "refactor(ui): model_view 移除「待处理」列与忽略材料展示"
```

### Task 15: 全量验证 + 打包 + 文档

**Files:**
- Modify: `CLAUDE.md`（更新架构说明）
- 验证：全量测试、打包

- [ ] **Step 1: 全量测试**

Run: `ruby -Itest -e "Dir.glob('test/test_*.rb').each { |f| require f.sub('test/', '') }"`
Expected: 0 failures, 0 errors。若有残留引用 mapping 的测试报错，按报错逐个清理（删除或改造）。

- [ ] **Step 2: 打包**

Run: `ruby tools/pack_rbz.rb`
Expected: 成功生成 rbz，无报错。

- [ ] **Step 3: 更新 CLAUDE.md**

`CLAUDE.md`：
- 数据层说明删除 `mapping.rb` 条目。
- Strategy 架构说明删除 SkirtingLinear/WirePath 条目与 3.5 档相关描述；长度算法库删除 SegmentedPath 条目。
- 「算量策略优先级（4+1 档）」改为「3 档」：删除第 3 档（材质映射 unit）与 3.5 档（策略自动匹配），保留 1（AttrDict）/2（图层）/4（几何启发）。
- 云端同步层 payload 说明：注明 material_tag 已移除、推送暂时报 422、产品 code 关联另立任务。
- 关键约束中删除/更新与材质映射、忽略材料相关的条目。

- [ ] **Step 4: 提交**

```bash
git add CLAUDE.md
git commit -m "docs: 更新 CLAUDE.md 反映材料映射/3.5档/忽略材料的移除"
```

- [ ] **Step 5: 手动验证清单（需在 SketchUp 内）**

  - 侧边栏无「材料映射」入口；设置页无「材料分类/可选单位/忽略材料」卡。
  - 扫描后「按组件」视图无「待处理」列；打了算量标签/图层规则的对象按标签/图层计量。
  - 组件行「产品信息」列 SKU 选择仍可用（组件级 SKU）。
  - 云端推送点击后收到 422（预期，产品 code 关联另立任务）。

---

## 验收标准

1. 全量测试 0 failures；打包成功。
2. 代码中无 `MaterialMapping`/`material_category_units`/`ignored`/`material_tag`/`SkirtingLinear`/`WirePath`/`SegmentedPath` 残留引用（`grep` 核验）。
3. 算量仅由 算量标签/图层规则/几何启发 驱动；组件映射保留。
4. 组件级 SKU 与产品信息列不受影响。
5. 推送因缺 material_tag 报 422（预期，另立任务修复）。
