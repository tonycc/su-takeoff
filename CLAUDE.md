# CLAUDE.md

本文件为 Claude Code（claude.ai/code）在此仓库中工作时提供指导。

## 项目概述

SketchUp 插件，用于装修面材用量统计。扫描 SU 模型面，按组件层级 / 空间 / 部位 / 材料分组，计入损耗率，输出采购量报表。支持面材（m²）和线材（m）两种计量。

## 运行测试

```bash
# 全部测试
ruby -Itest test/test_data_models.rb test/test_mapping.rb test/test_process_library.rb test/test_calculator.rb test/test_formula.rb test/test_compute_geometry_only.rb test/test_wall_model.rb

# 单独运行
ruby -Itest test/test_data_models.rb
ruby -Itest test/test_mapping.rb
ruby -Itest test/test_process_library.rb
ruby -Itest test/test_calculator.rb
ruby -Itest test/test_formula.rb
ruby -Itest test/test_compute_geometry_only.rb
ruby -Itest test/test_wall_model.rb
```

测试使用 Minitest，独立于 SketchUp 运行时执行。Scanner、Dialog 无自动化测试，需在 SketchUp 内手动验证。

`test_model.rb`（根目录）是 SU 控制台内运行的测试模型生成器，不是单元测试。

## 架构

插件通过 `su_takeoff.rb` 加载 —— 一条扁平的 require 链引入 `src/` 下所有模块。所有代码位于 `module SuTakeoff` 内。

**数据层（可单元测试，无 SU 依赖）：**
- `data_models.rb` — `ScanItem`（单面，含 `component_path` 名字数组与 `component_path_ids` entityID 数组并行存在，`kind` 区分 `:face` 和 `:instance`）、`MaterialUsage`（分组结果）、`Opening`（门窗洞口）
- `mapping.rb` — `MaterialMapping`：SU 材质名 → 真实材料（分类、单位、规格、损耗率）。支持 JSON 持久化与 CSV 导入/导出
- `component_mapping.rb` — `ComponentMapping`：组件定义名 → 真实材料映射。`counting_method` 区分 `expand`（展开统计面材）和 `aggregate`（整件统计个数，如灯具/开关）。支持 JSON 持久化
- `process_library.rb` — `ProcessLibrary`：按分类的工艺做法（如瓷砖→密缝铺贴），提供替代损耗率与派生项（多层做法）
- `calculator.rb` — `Calculator`：两个计算路径：
  - `compute(items, openings, process_overrides)` — 完整计算：分组 → 洞口扣减 → 材料/工艺损耗 → 派生项展开 → `MaterialUsage` 数组。当映射 `unit == 'm'` 时按 `face.height` 累加长度并跳过洞口扣减。处理薄板去重（仅保留楼板/天花面向居住者的那一面）
  - `compute_geometry_only(items, openings)` — 纯几何计算：不应用材料映射/工艺损耗/派生项，供组件视图按 entityID 汇总净量
- `formula.rb` — `Formula`：派生项的公式求值器（支持 `area`、`length`、`count` 等变量与基础算术、`ceil/floor/round/min/max`）

**SU 运行时层（依赖 Sketchup API）：**
- `scanner.rb` — `Scanner`：递归遍历模型实体，收集 `ScanItem` 与 `Opening`（透明面或命名为窗/门/window/door 的组件）。同时累积每级容器的 `name` 和 `entityID`，使同名实例可区分
- `ui/dialog.rb` — `Dialog`：HtmlDialog 桥接层。注册 JS → Ruby 回调。统一通过 `send_workbench_state` 推送数据：扫描后或任何映射/忽略变更后，重跑 Calculator 并把 items + usages + counts 一次性推给前端
- `main.rb` — `PluginState` 单例（持有 mapping + component_mapping + processes + ignored + config），注册 SU 菜单/工具栏。`ignore!` 是追加语义；`set_ignored!` 是替换语义（前端发送完整集合时用）。`config` 含 `material_category_units`、`component_category_units`、`units`、`length_units`、`count_units`，持久化到 `data/config.json`。菜单含「重新加载插件」项，无需重启 SU 即可热加载所有模块

**前端（在 HtmlDialog 内运行）：**
- `ui/index.html` — 左侧菜单栏 + 右侧五页面：按组件、按材料、材料映射、组件映射、设置
- `ui/app.js` — 应用入口：侧边导航切换、`switchPage`、公共工具函数（`esc`、`round`、颜色映射）、组件树构建（`buildComponentTree`、`collectLeafPaths`）、扫描触发（`scanAll`/`scanSelected`）、摘要条渲染（`renderSummary`）
- `ui/js/model_view.js` — 统计视图：按组件（树形表格，entityID 区分同名实例，部位徽标 ≥80%，净面积来自 `compute_geometry_only`）+ 按材料（筛选栏 + 搜索 + 就地映射 + 单位/损耗编辑 + 忽略/取消忽略）。摘要条「待 N」点击跳转到材料视图并自动筛选
- `ui/js/mapping.js` — 材料映射管理页：已映射/未映射两表，支持搜索、编辑、删除、CSV 导入导出
- `ui/js/comp_mapping.js` — 组件映射管理页：组件定义 → 材料映射，统计方式（展开/整件）
- `ui/js/settings.js` — 设置页：分类单位配置、工艺库查看、规则写入/读取 SU 模型属性字典
- `ui/styles.css` — Catppuccin 深色主题

**数据文件（JSON）：**
- `data/default_mapping.json` — 预设 SU 材质→真实材料映射
- `data/default_component_mapping.json` — 预设组件定义→材料映射
- `data/default_processes.json` — 预设分类→工艺定义
- `data/config.json` — 单位分类配置（material/component category_units, units, length_units, count_units）
- `data/ignored_materials.json` — 持久化的忽略材质列表（自动生成）

**工具脚本：**
- `tools/create_wall_model.rb` — 生成墙体测试模型的 Ruby 脚本（独立运行，不依赖 SU）
- `test_model.rb`（根目录） — 在 SketchUp Ruby 控制台中加载，生成含材质/组件的完整测试场景

## 关键约束

- **测试不得依赖 SU 运行时**（Scanner、Dialog 不可被测试用），直接构造 `ScanItem`/`Opening` 进行测试。test_helper 只 require 数据层和工具模块（debug、formula、data_models 等）
- **面积换算**：`face.area(transform)` 返回 in²，乘以 `0.00064516` 得到 m²
- **面朝向判定阈值**：`|normal.z| > 0.866`（约 cos 30°），区分水平面（地面/天花）与垂直面（墙面）
- **同名实例区分**：`component_path` 仅做显示，识别身份用 `component_path_ids`（entityID 数组）。前端构建组件树时以 ID 作 key，name 作显示
- **线材识别优先级**：材质映射 `unit == 'm'` > 面长宽比 `height/width > 15`（仅当材质未映射时）。识别后，Calculator 累加 `face.height`，不扣洞口
- **HtmlDialog 桥接**：Ruby 端使用 `add_action_callback`，JS 端使用 `sketchup.<action>()`，数据通过 `execute_script("window.renderX(...)")` 以 JSON 序列化传递
- **数据流是响应式的**：任何映射/组件映射/忽略变更触发 `send_workbench_state`，前端 `_workbench` 缓存被替换，所有视图按需重绘；切视图不调 Ruby
- **双计算路径**：`compute` 产出 `usages`（完整材料/工艺损耗，供材料视图和采购量汇总），`compute_geometry_only` 产出 `geometry_usages`（纯几何净量，供组件视图按 entityID 汇总）。前端同时持有两份数据，按视图选用

## 沟通语言

始终使用中文回复。

## 工作流

```
扫描全部/仅选中
    ↓
send_workbench_state（含 items + usages + geometry_usages + materials_info + counts）
    ↓
前端缓存 _workbench
    ↓
按组件（geometry_usages）/ 按材料（usages）视图自由切换（不调 Ruby）
    ↓
材料视图保存映射 → callSketchUp('save_mappings_batch')
组件映射页保存 → callSketchUp('save_component_mappings_batch')
    ↓
Ruby 写映射/组件映射 + send_workbench_state（重跑 Calculator）
    ↓
前端再次重绘所有视图
```
