# CLAUDE.md

本文件为 Claude Code（claude.ai/code）在此仓库中工作时提供指导。

## 项目概述

SketchUp 插件，用于装修用量统计。扫描 SU 模型面/容器，按组件层级 / 空间 / 部位 / 材料分组，输出几何量报表。支持四种计量方式：**面积（m²）/ 长度（m）/ 体积（m³）/ 件数（个）**，由 `TakeoffPolicy` 4+1 档优先级决议，每个量纲背后由独立的 `Strategy` 类承担"如何聚合/如何从容器产出/默认单位"。前端仅保留按组件树视图。

## 运行测试

```bash
# 全部测试
ruby -Itest -e "Dir.glob('test/test_*.rb').each { |f| require f.sub('test/', '') }"

# 单独运行
ruby -Itest test/test_takeoff_policy.rb
ruby -Itest test/test_strategy_matching.rb
ruby -Itest test/test_length_calculator_chained.rb
ruby -Itest test/test_compute_geometry_only.rb
ruby -Itest test/test_wall_model.rb
```

测试使用 Minitest，独立于 SketchUp 运行时。`test_helper.rb` require 数据层 + 全部 Strategy + LengthCalculator，并在加载时执行 `Strategies::Builtin.register_all!` 与 `Strategies::Loader.load_from_file!(data/strategies.json)` —— 任何单测都拿到一个完整的 Strategy Registry。Scanner、Dialog 无自动化测试，需在 SketchUp 内手动验证。

CSV 字节序列错误属于 Ruby 2.6 系统环境问题，与项目代码无关。

## 打包

```bash
ruby tools/pack_rbz.rb    # 生成 su-takeoff-v1.0.0.rbz
```

## 架构

插件通过 `su_takeoff.rb` 加载 —— 一条扁平的 require 链按顺序引入 `src/` 下所有模块：数据层 → Strategy → LengthCalculator → Mapping → Policy → Calculator → Presenter → Scanner → UI。所有代码位于 `module SuTakeoff` 内。

### 数据层（可单元测试，无 SU 依赖）

- **`takeoff_policy.rb`** — 算量策略决议器（核心）。4+1 档优先级：`AttrDict 标签 → 图层规则 → 材质映射 unit → 策略自动匹配 → 几何启发式`。任意一档命中即返回。`resolve(item)` 返回 `ResolveResult(strategy, source)`；`strategy` 是 `Strategies::Base` 子类对象，`method` 由 `strategy.method` 派生（向后兼容）。`resolve_container` 供 Scanner 容器级判定。**构造时注入所有依赖**（mapping, layer_rules, tag_defs, thresholds, strategies），不读 PluginState/config.json。`strategies:` 不传时默认走 `Strategies::Registry.global`；测试可注入独立 Registry。单位 → 计量方式由 `classify_unit` 类方法通过字符串启发直接判断（含 `³`/`3`/`L`/`立方`→体积，中文量词→件数，`m`/`mm`/`cm`→长度，其余→面积），无需配置分类列表。
- **`data_models.rb`** — `ScanItem`（keyword_init）含 `kind` 区分 `:face`/`:instance`/`:solid`/`:linear_solid`/`:count_solid`，`qty_area/qty_length/qty_volume/qty_count` 量纲字段统一以米（m）为单位；新增 `strategy_name`（Symbol，缓存决议出的策略名，前端调试用）。类方法 `ScanItem.face/instance/solid/linear_solid/count_solid` 是推荐的工厂入口。`Opening`（门窗洞口）保留不变。
- **`calculator.rb`** — `compute_geometry_only`：纯几何决议 + 薄板去重。先 `dedup_thin_slabs`（水平楼板），再 `cache_resolve` 全量决议，再 `dedup_vertical_slabs`（竖直薄板，仅作用于 method==:length 的面），最后输出 `{item:, method:, source:, unit:, strategy_name:}` 数组。`unit_for` 走 `Strategies::Registry.default_for(method).default_unit`；未映射面用 `geometry_unmapped_fallback`（长宽比 > 15 视线材）。
- **`mapping.rb`** — SU 材质 → 真实材料映射（分类、单位、规格）。`default_waste_rate` 字段保留兼容旧数据，几何用量链路不读取。
- **`component_mapping.rb`** — 组件定义名 → 材料映射。`counting_method`: `expand` 展开统计面材 / `aggregate` 整件统计个数。

### Strategy 架构（`src/strategies/`）

每个量纲背后都是一个 `Strategy` 对象，封装：`name`（Symbol）、`method`（量纲）、`default_unit`、`match_rules`（自动匹配规则）、`aggregate(items, ctx)`（Presenter 累加）以及可选的 `emit_from_container` / `compute_length`。新增计量方式只需写一个 Strategy 类 + 在 Builtin 注册。

- **`base.rb`** — 抽象基类。`matches?(item, context)` 支持四种规则：`definition_name_includes`（关键字数组）/ `definition_name_pattern`（String 或 Regexp）/ `layer`（图层名数组）/ `unit`（mapping unit 数组）；无规则的策略不自动匹配。
- **`registry.rb`** — 实例化 Registry。`register(strategy, default_for: nil)` 注册策略，可选标记为某 method 的默认；`get(name)` / `default_for(method)` / `all` 检索；DI 友好。类方法 `Registry.register/get/...` 委托给 `Registry.global` 单例，向后兼容。`Registry.reset!` 重置 global，测试用。
- **9 个内置策略**：
  - `FaceArea`（:area，默认）— `aggregate` 含洞口扣减
  - `FaceLinear`（:length）— 启发式线材，`qty_length || height` 兜底
  - `InstanceCount`（:count）— 组件 aggregate 整件
  - `SolidVolume`（:volume，默认）
  - `SolidLinear`（:length，默认）
  - `SolidCount`（:count，默认）
  - `Skip`（:skip，默认）— 占位，主流程过滤不调 aggregate
  - `SkirtingLinear` — 自动匹配"踢脚/skirting"或图层"踢脚线"，强制用 `EdgeBased`
  - `WirePath`（继承 `SolidLinear`）— 自动匹配 18 关键字（电线/电敷线/电管/电缆/金属线/导线/数据线/网线/信号线/线管/PVC管/镀锌管/管材/管道/wire/cable/pipe/conduit），强制用 `SegmentedPath`（跳过 Chained 的 VolumeBased 误判）
- **`builtin.rb`** — `register_all!` 在 PluginState 初始化时调用一次。
- **`loader.rb`** — 从 `data/strategies.json` 加载用户变体。每个 entry 形如 `{ "name": { "base_strategy": "solid_linear", "match_rules": {...} } }`，复用 base 的实现但用自定义名与规则。通过公开的 keyword 构造注入（`base.class.new(name:, match_rules:)`），无反射。

### 长度算法库（`src/length_calculators/`）

容器级 :length 决议后，Scanner 调用算法计算米数。每个算法实现 `compute(entity, ctx) -> Float | nil`，nil 表示"不适用，请尝试下一个"（供 `Chained` 串联）。`ctx` 含 `entities/edges/baseline_id/edge_scale/model_unit_to_m/scale/volume_m3/debug`。

- **`base.rb`** — 抽象基类。
- **`baseline.rb`** — 用户在 AttrDict 标注 `baseline_id` 时直接取该边长度。
- **`volume_based.rb`** — Solid 体积法：volume ÷ 截面高 ÷ 截面厚。截面候选边长 0.001~0.1m，至少 2 个 ≥4 边的方向组。
- **`edge_based.rb`** — 边线法。两个分支：方向组 ≤5 时按各方向最长边降序累加，5× gap 截断（截面方向）；>5 个方向组（圆柱/圆角）走非方条形分支。
- **`chained.rb`** — 按序尝试一组算法，返回首个 non-nil。Scanner 默认链 = `Baseline → VolumeBased → EdgeBased`。
- **`path_sum.rb`** — 纯路径累加：sum 所有 Edge 长度，不分方向。用于纯边线组件（电线/管道折线）。
- **`segmented_path.rb`** — 按长度分桶 + 过滤 < 5mm 装饰边 + 5% 容差。专为 3D 虚线渲染电线/管材路径设计：每段虚段被画多次叠加，分桶后每桶取最大值代表该段。

### SU 运行时层（依赖 SketchUp API）

- **`scanner.rb`** — 递归遍历模型实体收集 `ScanItem` 与 `Opening`。`collect_faces` 入口按实体类型分派 `collect_face`（~95 行）与 `collect_container`（~110 行）。
  - **`collect_container` 决议顺序**：(1) 复合标签 method 含 `+` → 拆开产出多条容器级 ScanItem；(2) 组件映射 `aggregate` → 整件 `:instance`；(3) `try_emit_solid`（4 档决议命中 `:length`/`:volume`/`:count`）→ 不下钻；(4) 纯边线分支（无面/无子容器但有边）→ `decide_pure_edges_method` 4 档判 method，length 走 PathSum 出 `:linear_solid`，其他出 `:instance` 按件；(5) 正常下钻子面。
  - **`try_emit_solid` 4 档**：AttrDict method → 图层规则 → 组件映射 unit 推导 → 策略自动匹配（`find_container_strategy`，按 definition_name 命中非默认策略）。
  - **`emit_solid_by_method`** 按 method 产出 `:linear_solid`/`:solid`/`:count_solid`。`:length` 优先调 `compute_length_via_strategy`（让 SkirtingLinear/WirePath 等暴露 `compute_length` 的策略接管），fallback 到 `compute_linear_length`（Chained）。
  - **`build_length_ctx`** 统一组装 entities/edges/edge_scale，`calibrate_inch_edges` 处理 e.length 单位混淆。
  - `Scanner::DEBUG = true` 开启详细调试日志（含 PATH_DEBUG 系列）。
- **`workbench_presenter.rb`** — 把 Scanner 结果加工成前端 `_workbench`。`build_geometry_usages` 按 (entity_id, su_material) 聚合后，按 `resolved_method` 分桶调对应策略的 `aggregate`；输出含 `strategies: [...]` 字段（本聚合涉及的全部策略名）供前端调试。
- **`ui/dialog.rb`** — HtmlDialog 桥接。`send_workbench_state` 推全量数据，所有回调通过 `add_action_callback` + JS `sketchup.<action>()` 通信，数据以 JSON 经 `execute_script` 传递。
- **`main.rb`** — `PluginState` 单例，管理配置持久化。初始化时调 `Strategies::Builtin.register_all!` + `Strategies::Loader.load_from_file!`（仅首次，幂等）。`takeoff_policy` 每次返回基于最新 config 的新 Policy（避免缓存陈旧规则）。注册菜单、工具栏。

### 前端（HtmlDialog 内运行，全局命名空间）

- `ui/js/model_view.js` — 按组件树形视图。每节点展开后显示材质汇总行 → 按规格（宽×高 mm）分组 → 面明细。启发式行橙色边框 +「待确认」徽标。支持搜索、空容器/隐藏项开关、合并相同组件、CSV 导出。
- `ui/js/settings.js` — 设置页：分类单位配置、算量标签定义（支持多选复合如 `count+length`）、启发式开关与阈值、忽略材料。
- `ui/js/mapping.js` — 材料映射管理（含未映射材料快速映射）。
- `ui/js/comp_mapping.js` — 组件映射管理。

### 数据文件（`data/` 目录）

- `config.json` — 标签定义、图层规则、启发式阈值、单位词表
- `default_mapping.json` — SU 材质 → 真实材料
- `default_component_mapping.json` — 组件定义 → 材料
- `ignored_materials.json` — 忽略的材质列表
- `strategies.json` — 用户自定义 Strategy 变体（base_strategy + match_rules），目前内置 3 个示例：`skirting_linear_default` / `pipe_length_default`（正则匹配管道|管材|PVC|PPR|DN\d+）/ `handrail_length_default`（扶手/栏杆）

配置优先级：模型 AttributeDictionary（随 SKP 文件走）> `data/` JSON 文件 > 默认值。

### 算量策略优先级（4+1 档）

```
1. AttrDict 标签   显式 · entity 上 set_attribute('su_takeoff', 'method', 'xxx')
                   → source: :attr

2. 图层规则        显式 · config.json 中 layer_rules[layer_name]
                   → source: :layer

3. 材质映射 unit   显式 · 映射表 unit 经 classify_unit 推导
                   含 ³/3/L/立方 → volume, 中文量词 → count, m/mm/cm → length, 其余 → area
                   → source: :mapping

3.5 策略自动匹配   显式 · 遍历同 method 下非默认策略，命中 matches? 即返回
                   （definition_name_includes / pattern / layer / unit 任一规则匹配）
                   → source: :auto_match

4. 几何启发式      自动 · 仅窄长垂直面 (|normal.z|<0.5, width≤0.2m, ratio>15)
                   前面均未命中时才触发
                   → source: :heuristic
```

每档命中时返回的 strategy：1/2/4 走 `Registry.default_for(method)`，3.5 直接返回匹配到的非默认策略，3 走默认（除非 3.5 抢先）。

**容器决议（Scanner `try_emit_solid` 4 档）**：AttrDict method → 图层规则 → 组件映射 unit 推导 → 策略自动匹配。命中 `:length`/`:volume`/`:count` 时整体量取不下钻；`:area` 或全未命中则下钻子面。

**纯边线组件决议（Scanner `decide_pure_edges_method` 4 档）**：AttrDict → 图层 → 组件映射 unit → 几何启发（≥2 个不同方向的边 = 折线路径 → :length）。length 时调 `PathSum` 算路径总长产 `:linear_solid`；其他按件兼容旧行为。

**复合标签**：设置页标签定义选择多个 method（如 `count+length`），Scanner 在 ComponentInstance/Group 分支顶部拆开，调用 `emit_solid_by_method` 产出多条不同 kind 的 ScanItem。

### 数据流

```
Scanner → WorkbenchPresenter → JSON → frontend _workbench → renderPositionView
                                          │
                                   send_workbench_state 在任何变更后重新触发
                                   （扫描、映射增删改、设置保存、标签变更）
```

## 关键约束

- **测试不得依赖 SU 运行时**。test_helper 自动 register 内置策略 + 加载 strategies.json，单测可直接构造 Policy 与 Strategy 实例。
- **所有长度内部存储为米（m）**。前端显示 ×1000 转 mm。面积 in² × `0.00064516` → m²。体积 in³ × `1.6387e-5 * scale³`。bbox 永远英寸。
- **边缘长度**：`e.length` 可能返回原始 Float（非 Length 对象）且单位随模型设置。校准逻辑：bbox 最长边 / 边缘最长值 > 10 时视为英寸，× 0.0254 修正（`calibrate_inch_edges`）。`@model_unit_to_m` 提供模型单位 → 米的换算系数。
- **面朝向**：`|normal.z| > 0.866`（≈cos 30°）区分水平/垂直面。
- **同名实例区分**：`component_path` 仅显示，识别用 `component_path_ids`（entityID 数组）。
- **AttrDict = 用户决定**：启发式绝不写 `entity.set_attribute`，否则污染下次扫描。
- **响应式数据流**：任何变更触发 `send_workbench_state` → 前端 `_workbench` 被替换 → 所有视图重绘。切视图不调 Ruby。
- **ComponentInstance vs Group 坐标空间**：`entity.definition.entities` 返回定义层边（不含实例 scale），`entity.volume` 和 `entity.bounds` 含实例 transform。`build_length_ctx` 中 `edge_scale = parent_scale × entity_scale` 统一两套坐标系。
- **显式优于隐式**：会改变算量结果的判定必须有视觉锚点。几何启发只能产生「待确认建议」，不默默改结果。

## 扩展须知

- **新增计量方式（如 weight/kg）**：写一个 `Strategy` 子类（实现 `aggregate`，可选 `emit_from_container`/`compute_length`），在 `Builtin.register_all!` 中 `register(..., default_for: :weight)` 注册；`TakeoffPolicy::METHODS` 加新枚举值；`unit_for` / `pick_primary` 等自动通过 `Registry.default_for(method).default_unit` 获取单位。前端 JS 仍需手工加显示列。
- **新增命名约定策略（如 龙骨/防水）**：写一个继承 `SolidLinear` 或对应基类的 Strategy，`DEFAULT_MATCH_RULES` 配关键字，`Builtin.register_all!` 注册（不传 `default_for` 避免冲突）；或写进 `data/strategies.json` 复用现有 base。
- **新增长度算法**：写一个 `LengthCalculators::Base` 子类实现 `compute`，在专用 Strategy 中持有实例 + 暴露 `compute_length(entity, ctx)`；Scanner `compute_length_via_strategy` 会自动接管。
- **Scanner `collect_container`（~110 行）是容器决议的核心**。修改时注意 5 条分支（复合标签 / aggregate / try_emit_solid / 纯边线 / 下钻）的互斥与顺序。

## 沟通语言

始终使用中文回复。
