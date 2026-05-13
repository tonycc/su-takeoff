# 按区域查看视图 — 设计文档

**日期：** 2026-05-13
**状态：** 已确认

## 概述

在统计页工作台新增第 4 个查看维度——按区域（地面/墙面/天花）分组展示材料用量明细。

## 数据来源

使用现有 `window._workbench.usages` 数组（由 Ruby `send_workbench_state` 推送），每个元素已包含所需全部字段。纯前端分组渲染，**零 Ruby 变更**。

## 入口

统计页视图切换栏新增按钮「按区域」，与「按组件」「按材料」「采购量」平级。

## 表格结构

列：序号 | 功能区域 | 区域分项 | 材料 | 分类 | 规格 | 单位 | 净面积 | 损耗率 | 采购量

### 分组与排序

1. `usages` 按 `space` 分组
2. 每组内按 `part` 再分组，固定顺序：floor → wall → ceiling
3. 空间保持 `usages` 数组的原始顺序（Calculator 输出顺序已确定）

### 行类型

- **明细行** — 每个 MaterialUsage 一行，有序号（从 1 开始连续编号）
- **空间小计行** — 每个空间前一行，加粗、浅色底，span 功能区域列，其余列显示该空间的 net_area 和 purchase_qty 汇总。不编号
- **总计行** — 表格末尾，加粗，所有空间汇总。不编号

### 显示约定

- 同一空间内，仅首行显示「功能区域」名称，后续行留空
- 区域分项用现有 CSS 类 `.pill-floor` / `.pill-wall` / `.pill-ceiling` 彩色徽标
- 损耗率以百分比显示（如 `5%`）

## 改动文件

| 文件 | 改动 |
|---|---|
| `src/ui/index.html` | 视图按钮栏 + 1 按钮；新增 `<div id="view-zone">` 容器；`switchWorkbenchView` 视图列表加 `'zone'` |
| `src/ui/app.js` | `switchWorkbenchView` 加 `'zone'` 分支；`renderCurrentView` 加 `'zone'` 分支；新增 `renderZoneView()` |
| `src/ui/styles.css` | 小计行样式（如需），现有样式基本够用 |

## 不包含

- CSV 导出（后续开发）

## 测试

在 SketchUp 内手动验证：扫描模型 → 切换到按区域视图 → 确认分组正确、小计行数据正确、总计行数据正确。
