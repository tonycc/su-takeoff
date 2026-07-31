# 彻底删除材料映射 设计文档

- 日期：2026-07-31
- 状态：待实现
- 分支：建议在 `feat/remove-material-mapping` 上分阶段提交

## 1. 背景与目标

插件原有的「材料映射」（`MaterialMapping`：SU 材质 → 真实材料/分类/单位/平台标签）是算量第 3 档决议与云端推送 `material_tag` 的来源。产品方向调整为**以组件为中心**：算量改靠**算量标签（第1档）/图层规则（第2档）/几何启发（第4档）**，与服务端的关联改用**组件级产品 code**（另立任务实现）。因此整个材料映射概念需彻底删除。

**目标**：干净地移除材料映射的数据模型、UI 页面、算量第 3/3.5 档、推送 `material_tag` 来源、忽略材料功能及相关配置/测试，同时**保留**组件映射、算量标签、图层规则、几何启发、组件级 SKU。

## 2. 范围

### 删除
- **数据模型**：`src/mapping.rb`（`MaterialMapping`/`MappingRecord`）、`data/default_mapping.json`、`src/main.rb` 与 `su_takeoff.rb` 中的装配/require。
- **算量**：`TakeoffPolicy` 第 3 档（材质 unit）与第 3.5 档（自动匹配）；`Calculator` 的 mapping 兜底/`unmapped_materials`/lookup 的 mapping 分支；`WorkbenchPresenter` 的 unresolved/mapped/ignored 统计。
- **3.5 档专用策略**：`SkirtingLinear`、`WirePath` 及其在 `Builtin` 的注册、`data/strategies.json` 对应变体、专属测试；仅被它们独占的长度算法（如 `SegmentedPath`，若仅 WirePath 使用）一并清理。
- **推送**：`QuantityPayloadBuilder` 的 `material_tag`、未映射/缺标签拦截、忽略跳过；`QuantitySyncService` 的 mapping 参数。**删除后推送因服务端 `material_tag` 必填而返回 422（暂时不可用，产品 code 关联另立任务）**。
- **UI**：材料映射页（`index.html` 导航按钮/`#page-mapping`/两个行模板/`mapping.js` 引用）、`src/ui/js/mapping.js`、`app.js` 的 `get_mappings` 路由、`dialog.rb` 的 `get/save/delete_mapping` 与 `import/export_csv` 回调；设置页「材料分类（material_category_units）」「可选单位（units）」配置卡；`model_view.js` 的「待处理」列与忽略展示。
- **忽略材料功能**：`PluginState` 的 `@ignored`、`ignored_materials.json`、`dialog.rb` 的 `ignore_material/unignore/clear_ignored` 回调、设置页「忽略材料」卡、presenter 的 ignored 统计、payload 的忽略跳过、config 的 ignored 相关。
- **配置**：config 的 `material_category_units`、`units`（`main.rb#save_config` 对应参数与 `load_data` 迁移逻辑）。
- **测试**：删除 `test/test_mapping.rb`；改造所有构造 `MaterialMapping` 或测试第 3 档/material_tag 的用例。

### 保留
- `ComponentMapping`（组件映射）+ `comp_mapping.js` + 设置页「组件分类」。
- 算量标签 `tag_defs`（第1档）+ 图层规则 `layer_rules`（第2档）+ 几何启发（第4档）+ 设置页对应配置。
- 组件级 SKU（`ComponentSkuMapping`）+ 模型视图「产品信息」列。
- 长度算法中被共用的部分（`Baseline`/`VolumeBased`/`EdgeBased`/`Chained`，`Chained` 默认链仍用 `EdgeBased`）。

## 3. 分阶段计划（每阶段保持可运行/可测）

- **P0 准备**：把 SKU 自动补全函数（`bindSkuAutocomplete`/`receiveSkuResults`/`skuOption`/`_ensureSkuCloser`/`_skuReqId`/`_skuActiveRow`）从 `mapping.js` 迁移到 `model_view.js`（其唯一使用者）。无行为变化。
- **P1 删映射页 UI**：移除 `index.html`（导航按钮、`#page-mapping`、`tmpl-mapping-row`/`tmpl-mapping-unmapped-row`、`<script src="js/mapping.js">`）、删除 `mapping.js`、`app.js` 的 `get_mappings` 路由、`dialog.rb` 的 `get/save/delete_mapping` + `import/export_csv` 回调与方法。此时 `MaterialMapping` 数据模型仍在，算量/推送照常工作。
- **P2 算量去 mapping**：
  - `TakeoffPolicy`：删除第 3 档与第 3.5 档（`auto_match_strategy`/`build_match_context`/resolve 中 mapping 分支）、`initialize` 的 `mapping:` 参数、`method_from_unit`（若仅 3 档用）。保留第 1/2/4 档与 `classify_unit`（仍被组件映射 unit→method 使用）。
  - `Calculator`：`initialize` 去掉 mapping 参数（改为 `(component_mapping = nil, policy: nil)`）；删除 `unmapped_materials`、mapping 兜底分支、`lookup_record` 的 mapping 分支（face 返回 nil）、`unit_for` 中依赖 mapping record 的逻辑（保留 component_mapping record 对 instance 的 unit）。
  - 同步更新 `Calculator.new` 的两处调用方：`WorkbenchPresenter`（P2）与 `QuantityPayloadBuilder`（P2 改调用签名，P3 再去 material_tag）。
  - `WorkbenchPresenter`：删除 `@mapping`、`unresolved_names`、`mapped_names`、`ignored_names`、overview 的 `ignored_count`/`unresolved_count`、build 输出的 `ignored`/`unresolved` 键；`Calculator.new` 去掉 mapping。
- **P3 推送去 material_tag**：`QuantityPayloadBuilder` 删除 `lookup_record`/record/`material_tag`/未映射拦截/缺标签拦截/`ignored?` 跳过；face 输出 `{code, area_m2}`，part 输出 `{code, name, quantity, unit}`（part 的 name 退回 `item.su_material`）；`initialize` 去掉 `mapping:`/`ignored:`。`QuantitySyncService` 去掉 mapping/ignored 传参。**此后推送返回 422。**
- **P4 删数据模型 + ignore**：删除 `src/mapping.rb`、`su_takeoff.rb` 的 require、`main.rb` 的 `@mapping`/`mapping_path`/`save_mapping_to_model_dict`/`load_data` mapping 分支/`load_from_model_dict` mapping/`reset` mapping；删除 `data/default_mapping.json`。删除 ignore 功能：`PluginState` 的 `@ignored`/`ignore!`/`set_ignored!`/`unignore!`/`save_ignored*`/`ignored_path`、`dialog.rb` 的 ignore 回调与方法、`data/ignored_materials.json`、`.gitignore` 中对应行。删除 3.5 专用策略：`src/strategies/skirting_linear.rb`、`src/strategies/wire_path.rb`、`Builtin` 注册、`data/strategies.json` 中 `skirting_linear_default`/`pipe_length_default`/`handrail_length_default` 等依赖名称匹配的变体、`src/length_calculators/segmented_path.rb`（若仅 WirePath 使用，需先核实）、对应测试。
- **P5 收尾**：设置页删除「材料分类」「可选单位」「忽略材料」卡（`settings.js`），`save_config`/config 清理 `material_category_units`/`units`/ignored；`model_view.js` 删除「待处理」列（表头/单元格/CSV）与忽略展示（`ignoredSet`/unresolved 高亮）；删除/改造受影响测试；全量测试 + 打包验证。

## 4. 关键行为变化

1. **无标签、无图层规则的面**：失去第 3 档兜底，落到第 4 档几何启发（仅窄长垂直面判线材）或 `:skip`。前提是模型按算量标签/图层规则配置。
2. **踢脚线/电线管材的名称自动识别（3.5 档）消失**：需改用算量标签或图层规则触发。
3. **推送**：payload 不再含 `material_tag`，服务端必填校验返回 422，推送暂时不可用（产品 code 关联另立任务）。
4. **「待处理」列、未映射高亮、忽略材料**：从界面消失。

## 5. 测试策略

- 删除 `test/test_mapping.rb`、3.5 专用策略测试、`SegmentedPath` 测试（若删除该算法）。
- 改造 `test/test_takeoff_policy.rb`（去 `mapping:` 参数与第 3 档用例，保留 1/2/4 档）、`test/test_compute_geometry_only.rb`（去 `Calculator.new` 的 mapping 参与 mapping 兜底用例）、`test/test_wall_model.rb`、`test/test_quantity_payload_builder.rb`（去 material_tag/未映射拦截用例，改为校验无 material_tag 的结构）、`test/test_strategy_*`（去 SkirtingLinear/WirePath 相关）。
- 每个阶段结束跑全量：`ruby -Itest -e "Dir.glob('test/test_*.rb').each { |f| require f.sub('test/', '') }"`，保持 0 failures。
- 前端（dialog/model_view/settings）依赖 SU，手动验证：映射页消失、设置页材料卡消失、产品信息列与组件级 SKU 仍可用、推送报 422。

## 6. 风险与注意

- **`mapping.js` 含 model_view 复用的 SKU 自动补全函数**：必须先 P0 迁移再删文件，否则组件行 SKU 选择失效。
- **`Calculator` 签名变更影响两个调用方**（presenter / payload_builder）：P2 需同时更新两处，避免编译/运行错误。
- **删除 3.5 专用策略前核实长度算法依赖**：`EdgeBased` 被 `Chained`（默认长度链）使用，须保留；`SegmentedPath` 若仅 `WirePath` 使用才可删。
- **config 迁移逻辑**（`load_data` 中 `category_units → material_category_units`）随材料分类删除而清理，注意不破坏 `component_category_units`/`tag_defs`/`layer_rules`/`heuristics`。
- **推送 422 为预期状态**：非缺陷，产品 code 关联为后续独立任务。
