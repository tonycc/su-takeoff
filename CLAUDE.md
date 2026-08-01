# CLAUDE.md

本文件为 Claude Code（claude.ai/code）在此仓库中工作时提供指导。

## 项目概述

SketchUp 插件，用于装修用量统计。扫描 SU 模型面/容器，按组件层级 / 空间 / 部位 / 材料分组，输出几何量报表。支持四种计量方式：**面积（m²）/ 长度（m）/ 体积（m³）/ 件数（个）**，由 `TakeoffPolicy` 3 档优先级决议，每个量纲背后由独立的 `Strategy` 类承担"如何聚合/如何从容器产出/默认单位"。前端仅保留按组件树视图。v1.1.0 新增**云端同步**能力：登录认证、项目绑定、算量数据推送至供应链平台（`src/api/` 模块）。

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

# 云端同步相关
ruby -Itest test/test_api_client.rb
ruby -Itest test/test_auth_session.rb
ruby -Itest test/test_quantity_payload_builder.rb
ruby -Itest test/test_quantity_sync_service.rb
```

测试使用 Minitest，独立于 SketchUp 运行时。`test_helper.rb` require 数据层 + 全部 Strategy + LengthCalculator + 全部 API 模块，并在加载时执行 `Strategies::Builtin.register_all!` 与 `Strategies::Loader.load_from_file!(data/strategies.json)` —— 任何单测都拿到一个完整的 Strategy Registry 和可用的 API 类。Scanner、Dialog 无自动化测试，需在 SketchUp 内手动验证。

CSV 字节序列错误属于 Ruby 2.6 系统环境问题，与项目代码无关。

## 打包

```bash
ruby tools/pack_rbz.rb    # 生成 su-takeoff-v1.0.0.rbz
```

## 架构

插件通过 `su_takeoff.rb` 加载 —— 一条扁平的 require 链按顺序引入 `src/` 下所有模块：数据层 → Strategy → LengthCalculator → Mapping → API → Policy → Calculator → Presenter → Scanner → UI。所有代码位于 `module SuTakeoff` 内，API 模块位于 `SuTakeoff::Api`。

### 数据层（可单元测试，无 SU 依赖）

- **`takeoff_policy.rb`** — 算量策略决议器（核心）。3 档优先级：`AttrDict 标签 → 图层规则 → 几何启发式`。任意一档命中即返回。`resolve(item)` 返回 `ResolveResult(strategy, source)`；`strategy` 是 `Strategies::Base` 子类对象，`method` 由 `strategy.method` 派生（向后兼容）。`resolve_container` 供 Scanner 容器级判定。**构造时注入所有依赖**（layer_rules, tag_defs, thresholds, strategies），不读 PluginState/config.json。`strategies:` 不传时默认走 `Strategies::Registry.global`；测试可注入独立 Registry。单位 → 计量方式由 `classify_unit` 类方法通过字符串启发直接判断（含 `³`/`3`/`L`/`立方`→体积，中文量词→件数，`m`/`mm`/`cm`→长度，其余→面积），无需配置分类列表。
- **`data_models.rb`** — `ScanItem`（keyword_init）含 `kind` 区分 `:face`/`:instance`/`:solid`/`:linear_solid`/`:count_solid`，`qty_area/qty_length/qty_volume/qty_count` 量纲字段统一以米（m）为单位；新增 `strategy_name`（Symbol，缓存决议出的策略名，前端调试用）。类方法 `ScanItem.face/instance/solid/linear_solid/count_solid` 是推荐的工厂入口。`Opening`（门窗洞口）保留不变。
- **`calculator.rb`** — `compute_geometry_only`：纯几何决议 + 薄板去重。先 `dedup_thin_slabs`（水平楼板），再 `cache_resolve` 全量决议，再 `dedup_vertical_slabs`（竖直薄板，仅作用于 method==:length 的面），最后输出 `{item:, method:, source:, unit:, strategy_name:}` 数组。`unit_for` 走 `Strategies::Registry.default_for(method).default_unit`；无显式决议的面用 `geometry_unmapped_fallback`（长宽比 > 15 视线材）。
- **`component_mapping.rb`** — 组件定义名 → 材料映射。`counting_method`: `expand` 展开统计面材 / `aggregate` 整件统计个数。
- **`component_sku_mapping.rb`** — 组件定义名 → 平台 SKU 关联（`platform_sku_id/code/name`）。**独立于算量**，仅用于模型视图「产品信息」列的选型展示，按 definition_name 持久化到 `data/component_sku_mapping.json` + 模型 AttributeDictionary。

### Strategy 架构（`src/strategies/`）

每个量纲背后都是一个 `Strategy` 对象，封装：`name`（Symbol）、`method`（量纲）、`default_unit`、`match_rules`（自动匹配规则）、`aggregate(items, ctx)`（Presenter 累加）以及可选的 `emit_from_container` / `compute_length`。新增计量方式只需写一个 Strategy 类 + 在 Builtin 注册。

- **`base.rb`** — 抽象基类。`matches?(item, context)` 支持四种规则：`definition_name_includes`（关键字数组）/ `definition_name_pattern`（String 或 Regexp）/ `layer`（图层名数组）/ `unit`（unit 数组）；无规则的策略不自动匹配。
- **`registry.rb`** — 实例化 Registry。`register(strategy, default_for: nil)` 注册策略，可选标记为某 method 的默认；`get(name)` / `default_for(method)` / `all` 检索；DI 友好。类方法 `Registry.register/get/...` 委托给 `Registry.global` 单例，向后兼容。`Registry.reset!` 重置 global，测试用。
- **7 个内置策略**：
  - `FaceArea`（:area，默认）— `aggregate` 含洞口扣减
  - `FaceLinear`（:length）— 启发式线材，`qty_length || height` 兜底
  - `InstanceCount`（:count）— 组件 aggregate 整件
  - `SolidVolume`（:volume，默认）
  - `SolidLinear`（:length，默认）
  - `SolidCount`（:count，默认）
  - `Skip`（:skip，默认）— 占位，主流程过滤不调 aggregate
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

### SU 运行时层（依赖 SketchUp API）

- **`scanner.rb`** — 递归遍历模型实体收集 `ScanItem` 与 `Opening`。`collect_faces` 入口按实体类型分派 `collect_face`（~95 行）与 `collect_container`（~110 行）。
  - **`collect_container` 决议顺序**：(1) 复合标签 method 含 `+` → 拆开产出多条容器级 ScanItem；(2) 组件映射 `aggregate` → 整件 `:instance`；(3) `try_emit_solid`（4 档决议命中 `:length`/`:volume`/`:count`）→ 不下钻；(4) 纯边线分支（无面/无子容器但有边）→ `decide_pure_edges_method` 4 档判 method，length 走 PathSum 出 `:linear_solid`，其他出 `:instance` 按件；(5) 正常下钻子面。
  - **`try_emit_solid` 3 档**：AttrDict method → 图层规则 → 组件映射 unit 推导。（原第 4 档"策略自动匹配 `find_container_strategy`"仍在代码中，但策略已无匹配规则，处于休眠。）
  - **`emit_solid_by_method`** 按 method 产出 `:linear_solid`/`:solid`/`:count_solid`。`:length` 优先调 `compute_length_via_strategy`（让暴露 `compute_length` 的专用策略接管），fallback 到 `compute_linear_length`（Chained）。
  - **`build_length_ctx`** 统一组装 entities/edges/edge_scale，`calibrate_inch_edges` 处理 e.length 单位混淆。
  - `Scanner::DEBUG = true` 开启详细调试日志。
- **`workbench_presenter.rb`** — 把 Scanner 结果加工成前端 `_workbench`。`build_geometry_usages` 按 (entity_id, su_material) 聚合后，按 `resolved_method` 分桶调对应策略的 `aggregate`；输出含 `strategies: [...]` 字段（本聚合涉及的全部策略名）供前端调试。
- **`ui/dialog.rb`** — HtmlDialog 桥接。`send_workbench_state` 推全量数据，所有回调通过 `add_action_callback` + JS `sketchup.<action>()` 通信，数据以 JSON 经 `execute_script` 传递。
- **`main.rb`** — `PluginState` 单例，管理配置持久化。初始化时调 `Strategies::Builtin.register_all!` + `Strategies::Loader.load_from_file!`（仅首次，幂等）。`takeoff_policy` 每次返回基于最新 config 的新 Policy（避免缓存陈旧规则）。注册菜单、工具栏。

### 云端同步层（`src/api/`，可单元测试，无 SU 依赖）

v1.1.0 新增。实现登录认证、项目绑定、算量 Payload 构建与推送。设计基线见 `docs/API对接设计方案.md`，服务端契约见 `docs/su-plugin-integration.md`。客户端标识 `CLIENT_ID = 'su-plugin'`，协议版本 SU v2。

- **`api_error.rb`** — `ApiError < StandardError`，字段 `status/code/details/retryable/body`。所有 HTTP 错误统一转为此异常。
- **`http_response.rb`** — `HttpResponse` 值对象（status/body/headers），`ApiClient` 内部使用。
- **`api_client.rb`** — HTTP 客户端。6 个接口：`login` / `refresh` / `logout` / `me`（`/identity/me`）/ `push_quantities` / `materials`（`GET /api/v1/su/materials` 供应链 SKU/产品查询，支持 `keyword`/`category_id`/`brand_id`/`status`/`page`/`page_size`）。超时配置：连接 10s、登录 30s、推送 120s。`normalize_base_url` 在 `environment=production` 时强制 HTTPS。支持 `transport:` 注入（测试用 mock）。
- **`credential_store.rb`** — Token 安全存储抽象。`CredentialStore.default` 按平台分派：macOS → `MacOSKeychainStore`（系统 Keychain），其他 → `UnavailableStore`（降级为进程内会话）。`MemoryCredentialStore` 供测试。**当前仅实现 macOS Keychain，Windows Credential Manager 未实现**。
- **`auth_session.rb`** — 会话状态机。状态：`signed_out → authenticating → signed_in / tenant_selection_required / error`。`login` 支持多租户（`TENANT_SELECTION_REQUIRED` 时返回租户列表）；`restore` 从安全存储恢复会话；`refresh!` 刷新 access_token；`with_access_token_retry` 401 单次重试（防循环）；`can_push?` 校验 `quantity:ingest` 权限。access_token 存内存，refresh_token 存 CredentialStore。
- **`project_binding.rb`** — 项目绑定，持久化到模型 `AttributeDictionary`（`su_takeoff_cloud` / `binding`）。字段：`project_code` / `project_name` / `model_key`（自动生成 UUID）/ `last_payload_hash` / `last_idempotency_key` / `last_sheet_id` / `last_model_version_id` / `last_synced_at`。`mark_synced!` 在推送成功后更新。
- **`quantity_payload_builder.rb`** — 消费 Scanner 结果 + 组件映射 + Policy + Binding，输出 `BuildResult(payload, payload_hash, issues)`。稳定编码：`c-<SHA256[0,16]>` / `f-<SHA256[0,16]>` / `p-<SHA256[0,16]>`（前缀区分 component/face/part）。规范化：按 code 排序、4 位小数、洞口扣减。`payload_hash = SHA256(JSON)`，用于幂等。**注意：face/part 已不再含 `material_tag`（材质映射已删除），而服务端契约仍必填 `material_tag`，故当前推送会返回 422；改用组件级产品 code 关联的推送重构另立任务。**
- **`sync_outbox.rb`** — 失败推送的发件箱。按 `idempotency_key` 哈希命名 JSON 文件，`upsert` / `delete` / `all` / `find`。限制：最多 50 条 / 10MB。同一 key 只保留一条（保留原始 `created_at`）。
- **`quantity_sync_service.rb`** — 推送编排。`busy` 锁防并发；`build_payload` → `do_push_built`（401 重试 via `with_access_token_retry`）→ 退避重试（1/2/4 秒 + 抖动，最多 3 次）→ 成功更新 binding / 失败写 outbox。返回 `SyncResult(success, payload, payload_hash, issues, response, error, attempts, outbox_record)`。

**登录门禁**：进入插件先校验登录状态，未登录锁定扫描/组件映射/设置/定位/标签功能；登录后缺 `quantity:ingest` 权限时仅禁用云端推送。

**实施进度**（详见设计文档 §13）：
- ✅ 阶段 1：HTTP 与认证（ApiClient / CredentialStore / AuthSession / 登录 UI）
- ✅ 阶段 2：稳定编码和项目绑定（persistent_id / ProjectBinding / 绑定 UI）
- ✅ 阶段 3：材料标签和 Payload Builder（platform_material_tag / QuantityPayloadBuilder）
- ✅ 阶段 4：推送和失败恢复（SyncService / Outbox / 推送 UI / 后台线程）
- ⬜ 阶段 0：服务端契约确认（生产 URL / 错误结构 / component_type 枚举 / payload 限制等 10 项待确认）
- ⬜ 阶段 5：联调与发布（测试租户验证 / 多租户 / 幂等 / 大模型 413 / Windows 安全存储）

### 前端（HtmlDialog 内运行，全局命名空间）

- `ui/js/model_view.js` — 按组件树形视图。每节点展开后显示材质汇总行 → 按规格（宽×高 mm）分组 → 面明细。启发式行橙色边框 +「待确认」徽标。支持搜索、空容器/隐藏项开关、合并相同组件、CSV 导出。
- `ui/js/settings.js` — 设置页：组件分类单位配置、算量标签定义（支持多选复合如 `count+length`）、启发式开关与阈值。
- `ui/js/comp_mapping.js` — 组件映射管理。
- `ui/js/cloud_sync.js` — 云端同步页：独立登录页（账号/密码/租户下拉/环境信息）、云端同步主页（推送按钮/账号摘要/项目绑定面板/结果展示）。通过 `callSketchUp` 调用 Ruby 回调（`cloudLogin` / `cloudLogout` / `saveProjectBinding` / `cloudPush` / `get_cloud_state`）。

### 数据文件（`data/` 目录）

- `config.json` — 标签定义、图层规则、启发式阈值
- `default_component_mapping.json` — 组件定义 → 材料
- `strategies.json` — 用户自定义 Strategy 变体（base_strategy + match_rules）。当前为空 `{}`（原名称匹配变体已随策略自动匹配机制移除）
- `api_config.json` — 云端同步环境配置（`environment` + `base_url`）。当前默认 `development` / `http://127.0.0.1:8000`（本地联调）。正式发布前必须改为生产 HTTPS 域名。`environment=production` 时 ApiClient 强制 HTTPS，前端不可覆盖 Base URL。

配置优先级：模型 AttributeDictionary（随 SKP 文件走）> `data/` JSON 文件 > 默认值。

### 算量策略优先级（3 档）

```
1. AttrDict 标签   显式 · entity 上 set_attribute('su_takeoff', 'method', 'xxx')
                   → source: :attr

2. 图层规则        显式 · config.json 中 layer_rules[layer_name]
                   → source: :layer

3. 几何启发式      自动 · 仅窄长垂直面 (|normal.z|<0.5, width≤0.2m, ratio>15)
                   前面均未命中时才触发
                   → source: :heuristic
```

每档命中时返回的 strategy：1/2 走 `Registry.default_for(method)`，3 走 `face_linear`（启发线材）或 `face_area`。

**容器决议（Scanner `try_emit_solid` 3 档）**：AttrDict method → 图层规则 → 组件映射 unit 推导。命中 `:length`/`:volume`/`:count` 时整体量取不下钻；`:area` 或全未命中则下钻子面。

**纯边线组件决议（Scanner `decide_pure_edges_method` 4 档）**：AttrDict → 图层 → 组件映射 unit → 几何启发（≥2 个不同方向的边 = 折线路径 → :length）。length 时调 `PathSum` 算路径总长产 `:linear_solid`；其他按件兼容旧行为。

**复合标签**：设置页标签定义选择多个 method（如 `count+length`），Scanner 在 ComponentInstance/Group 分支顶部拆开，调用 `emit_solid_by_method` 产出多条不同 kind 的 ScanItem。

### 数据流

```
Scanner → WorkbenchPresenter → JSON → frontend _workbench → renderPositionView
                                          │
                                   send_workbench_state 在任何变更后重新触发
                                   （扫描、组件映射增删改、设置保存、标签变更）
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
- **Token 安全**：access_token 仅存内存，refresh_token 存系统安全存储（macOS Keychain）。密码不入日志、不持久化。安全存储不可用时降级为进程内会话（重启需重新登录）。
- **推送幂等**：`idempotency_key = su-v2-<model_key>-<payload_hash[0,16]>`，payload_hash 基于规范化 JSON 的 SHA256。同一模型内容不变则 key 不变，服务端据此去重。
- **`source_version` 服务端上限 64 字符**：联调实测 64→200 / 65→500（超长触发服务端未捕获异常，返回 500 而非 422）。`QuantityPayloadBuilder` 必须用 `sha256:<payload_hash[0,16]>`（23 字符），切勿改回完整 64 位 hash（71 字符会恒 500）。payload_hash 不含 source_version，截断不影响幂等键。
- **云端同步不阻塞 UI**：推送在后台线程执行（`Thread.new`），结果通过 `dialog.execute_script` 回主线程派发。Dialog 销毁后安全跳过回调。
- **API 测试不依赖网络和 SU 运行时**：通过 `transport:` 注入 mock HTTP 层、`sleeper:` / `jitter:` 注入跳过真实等待、`persist_success: false` 跳过模型写入。
- **服务端错误响应格式（FastAPI）**：业务错误为 `{"detail": {"code": "...", "message": "..."}}`，422 校验为 `{"detail": [{type, loc, msg}]}` 数组。`ApiClient#unwrap_detail` 统一解包。`ApiError.body` 保留原始响应（含 `detail` 信封），上层（如 `AuthSession#tenant_options_from`）从 `body['detail']` 读取扩展字段。生产 Base URL：`https://gzzyai.com`。

## 扩展须知

- **新增计量方式（如 weight/kg）**：写一个 `Strategy` 子类（实现 `aggregate`，可选 `emit_from_container`/`compute_length`），在 `Builtin.register_all!` 中 `register(..., default_for: :weight)` 注册；`TakeoffPolicy::METHODS` 加新枚举值；`unit_for` / `pick_primary` 等自动通过 `Registry.default_for(method).default_unit` 获取单位。前端 JS 仍需手工加显示列。
- **新增命名约定策略（如 龙骨/防水）**：写一个继承 `SolidLinear` 或对应基类的 Strategy，`Builtin.register_all!` 注册（不传 `default_for` 避免冲突）；或写进 `data/strategies.json` 复用现有 base。注意：策略自动匹配（原 3.5 档）已移除，名称/图层匹配需通过**算量标签**或**图层规则**触发；Scanner 容器级 `find_container_strategy` 仍会对带 match_rules 的策略调用 `matches?`（当前无此类策略，休眠）。
- **新增长度算法**：写一个 `LengthCalculators::Base` 子类实现 `compute`，在专用 Strategy 中持有实例 + 暴露 `compute_length(entity, ctx)`；Scanner `compute_length_via_strategy` 会自动接管。
- **Scanner `collect_container`（~110 行）是容器决议的核心**。修改时注意 5 条分支（复合标签 / aggregate / try_emit_solid / 纯边线 / 下钻）的互斥与顺序。
- **新增 API 接口**：在 `ApiClient` 中添加方法（参照现有 6 个接口的模式），`AuthSession` 或 `QuantitySyncService` 中编排调用。所有 HTTP 错误统一转 `ApiError`。测试通过 `transport:` mock 注入，不发真实请求。
- **Payload 字段变更**：修改 `QuantityPayloadBuilder` 时注意稳定编码（code 排序 + 4 位小数 + SHA256 幂等 hash）。任何字段变更都会改变 `payload_hash`，触发重新推送。设计文档 §7 和契约文档 `su-plugin-integration.md` 是字段定义的权威来源。
- **CredentialStore 平台扩展**：当前仅实现 macOS Keychain（`security` CLI）。新增平台需继承 `CredentialStore` 基类实现 `read/write/delete`，并在 `CredentialStore.default` 中注册平台判断。

## 沟通语言

始终使用中文回复。
