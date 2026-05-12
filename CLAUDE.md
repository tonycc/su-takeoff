# CLAUDE.md

本文件为 Claude Code（claude.ai/code）在此仓库中工作时提供指导。

## 项目概述

SketchUp 插件，用于装修面材用量统计。扫描 SU 模型面，按空间/部位/材料分组，计入损耗率，输出采购量报表。

## 运行测试

```bash
ruby -Itest test/test_data_models.rb
ruby -Itest test/test_mapping.rb
ruby -Itest test/test_process_library.rb
ruby -Itest test/test_calculator.rb
```

测试使用 Minitest，独立于 SketchUp 运行时执行。Scanner、Marker、Dialog 无自动化测试，需在 SketchUp 内手动验证。

## 架构

插件通过 `su_takeoff.rb` 加载 —— 一条扁平的 require 链引入 `src/` 下所有模块。所有代码位于 `module SuTakeoff` 内。

**数据层（可单元测试，无 SU 依赖）：**
- `data_models.rb` — `ScanItem`（单面）、`MaterialUsage`（分组结果）、`Opening`（门窗洞口）结构体
- `mapping.rb` — `MaterialMapping`：SU 材质名 → 真实材料（分类、单位、规格、损耗率）。支持 JSON 持久化与 CSV 导入/导出
- `process_library.rb` — `ProcessLibrary`：按分类的工艺做法（如瓷砖→密缝铺贴），提供替代损耗率
- `calculator.rb` — `Calculator`：将 ScanItem 按（空间, 部位, SU 材质）分组，扣除洞口面积，应用材料/工艺损耗率，输出 `MaterialUsage` 数组。同时处理薄板去重（仅保留楼板/天花面向居住者的那一面）

**SU 运行时层（依赖 Sketchup API）：**
- `scanner.rb` — `Scanner`：递归遍历模型实体（面、组件、群组），收集 `ScanItem` 与 `Opening`（透明面或命名为窗/门/window/door 的组件）
- `marker.rb` — `Marker`：通过 SU 属性字典（`su_takeoff_marking`）读写面上的手动材料标记
- `ui/dialog.rb` — `Dialog`：HtmlDialog 桥接层。注册 JS → Ruby 回调。实现两阶段工作流：阶段 1 扫描并推送待处理材质到 UI 供用户审核；阶段 2 完成映射后执行统计
- `main.rb` — `PluginState` 单例（持有 mapping + processes + ignored 列表），注册 SU 菜单/工具栏

**前端（在 HtmlDialog 内运行）：**
- `ui/index.html` — 四标签页布局：统计、未映射、映射、设置
- `ui/app.js` — 渲染审核表格（含每材质的面数、面积、部位分布、色块），批量映射保存，三种统计视图（按空间/按材料/明细），手动标记弹窗
- `ui/styles.css` — Catppuccin 深色主题

**数据文件（JSON）：**
- `data/default_mapping.json` — 预设 SU→真实材料映射
- `data/default_processes.json` — 预设分类→工艺定义
- `data/ignored_materials.json` — 持久化的忽略材质列表（自动生成）

## 关键约束

- 测试不得依赖 `sketchup` gem 或任何 SketchUp 运行时模块（Scanner、Marker、Dialog），直接构造 `ScanItem`/`Opening` 进行测试
- 面积换算：`face.area(transform)` 返回 in²，乘以 `0.00064516` 得到 m²
- 面朝向判定阈值：`|normal.z| > 0.866`（约 cos 30°），区分水平面（地面/天花）与垂直面（墙面）
- HtmlDialog 桥接：Ruby 端使用 `add_action_callback`，JS 端使用 `sketchup.<action>()`，数据通过 `execute_script("window.renderX(...)")` 以 JSON 序列化传递
