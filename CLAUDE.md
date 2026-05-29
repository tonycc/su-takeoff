# CLAUDE.md

本文件为 Claude Code（claude.ai/code）在此仓库中工作时提供指导。

## 项目概述

SketchUp 插件，用于装修用量统计。扫描 SU 模型面/容器，按组件层级 / 空间 / 部位 / 材料分组，计入损耗率，输出采购量报表。支持四种计量方式：**面积（m²）/ 长度（m）/ 体积（m³）/ 件数（个）**，由 `TakeoffPolicy` 4 档优先级决议。

## 运行测试

```bash
# 全部测试
ruby -Itest -e "Dir.glob('test/test_*.rb').each { |f| require f.sub('test/', '') }"

# 单独运行
ruby -Itest test/test_takeoff_policy.rb
ruby -Itest test/test_same_material_multi_method.rb
ruby -Itest test/test_calculator_volume.rb
ruby -Itest test/test_calculator.rb
```

测试使用 Minitest，独立于 SketchUp 运行时执行。Scanner、Dialog 无自动化测试，需在 SketchUp 内手动验证。`test_model.rb`（根目录）是 SU 控制台内运行的测试模型生成器。

## 架构

插件通过 `su_takeoff.rb` 加载 —— 一条扁平的 require 链引入 `src/` 下所有模块。所有代码位于 `module SuTakeoff` 内。

### 数据层（可单元测试，无 SU 依赖）

- **`takeoff_policy.rb`** — 算量策略决议器（核心）。4 档优先级：`AttrDict 标签 → 图层规则 → 材质映射 unit → 几何启发式`。任意一档命中即返回。`resolve(item)` 返回 `ResolveResult(method, source)`；`resolve_container` 供 Scanner 容器级整体量取判定用。构造时注入依赖，不读 PluginState/config.json。
- **`data_models.rb`** — `ScanItem`（单个算量单元，`kind` 区分 `:face`/`:instance`/`:solid`/`:linear_solid`/`:count_solid`）含 `qty_area/qty_length/qty_volume/qty_count` 量纲字段。`MaterialUsage`（分组结果，`confidence` + `source` 决定前端是否染红）。`Opening`（门窗洞口）。
- **`calculator.rb`** — 两条路径：`compute`（含损耗与派生，供采购量报表）和 `compute_geometry_only`（纯几何，供组件树）。分组 key 含 `method/confidence/source`，同 SU 材质可在不同 method 下产出独立 MaterialUsage（同材多算）。`:count_solid`/`:linear_solid`/`:solid` 三种容器级 kind 免除材质映射检查（用户显式意图）。
- **`mapping.rb`** — SU 材质 → 真实材料映射（分类、单位、规格、损耗率）。
- **`component_mapping.rb`** — 组件定义名 → 材料映射。`counting_method`: `expand` 展开统计面材 / `aggregate` 整件统计个数。
- **`process_library.rb`** — 按分类的工艺做法，提供替代损耗率与派生项。
- **`formula.rb`** — 派生项公式求值（变量 `area/length/volume/count` + 基础算术 + `ceil/floor/round/min/max`）。

### SU 运行时层（依赖 SketchUp API）

- **`scanner.rb`** — 递归遍历模型实体收集 `ScanItem` 与 `Opening`。ComponentInstance/Group 分支判定顺序：(1) 复合标签 method 含 `+` → 拆开产出多条容器级 ScanItem；(2) `aggregate` → 整件 `:instance`；(3) `try_emit_solid`（标签/图层规则命中 `:length`/`:volume`/`:count`) → `:linear_solid`/`:solid`/`:count_solid`，不下钻；(4) 正常下钻子面。`compute_linear_length` 有三条路径：基线边 → Solid 体积法 → 边线法（5×gap 判定长/截面方向，最长法累加）。非方条形几何（≥4 边的方向组 > 5 个，如圆柱面）跳过体积法和边线法，走简化最长法。边缘单位校准：bbox（永为英寸）和边缘值对比，ratio > 10 时修正英寸/mm 误判。`Scanner::DEBUG = true` 可开启详细调试日志。
- **`ui/dialog.rb`** — HtmlDialog 桥接。`send_workbench_state` 推数据，`set_takeoff_method_batch` 写 AttrDict 后重扫。
- **`main.rb`** — `PluginState` 单例，管理配置持久化。注册菜单、工具栏。

### 前端（HtmlDialog 内运行）

- `ui/index.html` — 左侧菜单栏 + 五页面
- `ui/js/model_view.js` — 按组件（树形，用 geometry_usages）+ 按材料（用 usages）。启发式行橙色边框 +「待确认」徽标。**按规格（宽×高 mm）总在前端展开**，单规格也展示分组行。标签徽章支持复合方法多色叠加。
- `ui/js/settings.js` — 设置页含**标签定义**（方法支持多选复选框，复合如 `count+length`）、图层规则、启发式开关与阈值、单位词表、工艺库、忽略材料。

### 算量策略优先级

```
1. AttrDict 标签   显式 · entity 上 set_attribute('su_takeoff', 'method', 'xxx')
                   来源：红行确认按钮
                   → confidence: :explicit, source: :attr

2. 图层规则         显式 · 设置页配置 layer_rules[layer_name]
                   → confidence: :explicit, source: :layer

3. 材质映射 unit    显式 · 映射表 unit 反向推导
                   m²→area, m→length, m³→volume, 个→count
                   → confidence: :explicit, source: :mapping

4. 几何启发式       自动 · 仅窄长垂直面 (|normal.z|<0.5, width≤0.2m, ratio>15)
                   前三档全未命中时才触发
                   → confidence: :heuristic, source: :heuristic
```

**复合标签**：设置页标签定义选择多个 method（如 `count+length`），Scanner 在 ComponentInstance/Group 分支顶部拆开，调用 `emit_solid_by_method` 产出多条不同 kind 的 ScanItem。Calculator 按同材多算自动分为独立 MaterialUsage。

## 关键约束

- **测试不得依赖 SU 运行时**。test_helper 只 require 数据层模块。
- **面积换算**：`face.area(transform)` 返回 in²，× `0.00064516` → m²。体积 in³ × `1.6387e-5 * scale³`。bbox 永远英寸。
- **边缘长度**：`e.length` 可能返回原始 Float（非 Length 对象）且单位可能是英寸（定义来自英寸模型），需校准后才能与 bbox 对应。
- **面朝向**：`|normal.z| > 0.866`（≈cos 30°）区分水平/垂直面。
- **同名实例区分**：`component_path` 仅显示，识别用 `component_path_ids`（entityID 数组）。
- **AttrDict = 用户决定**：启发式绝不写 `entity.set_attribute`，否则污染下次扫描。
- **HtmlDialog 桥接**：Ruby `add_action_callback` + JS `sketchup.<action>()`，数据通过 `execute_script` 以 JSON 传递。
- **响应式数据流**：任何变更触发 `send_workbench_state` → 前端 `_workbench` 被替换 → 所有视图重绘。切视图不调 Ruby。
- **ComponentInstance vs Group 的坐标空间差异**：`entity.definition.entities` 返回定义层边（不含实例 scale），`entity.volume` 和 `entity.bounds` 含实例 transform。`compute_linear_length` 内 `edge_scale = parent_scale × entity_scale` 统一两套坐标系。
- **显式优于隐式**：会改变算量结果的判定必须有视觉锚点。几何启发只能产生「待确认建议」，不默默改结果。

## 沟通语言

始终使用中文回复。

## 工作流

```
扫描（Scanner 走 Policy 决定容器是否整体量取）
    ↓
send_workbench_state（items + usages + geometry_usages + materials_info + counts）
    ↓
前端缓存 _workbench，按组件/按材料视图自由切换（不调 Ruby）
    ↓
用户操作 → callSketchUp → Ruby 写持久化 → send_workbench_state → 前端重绘
```
