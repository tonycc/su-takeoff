# 按组件维度统计 — 设计文档

## 目标

将统计页面（Phase 3）的默认视图改为「按组件」树形表格，组件行可展开显示面明细。

## 数据结构

### Ruby → JS 数据传递

`dialog.rb` 的 `finalize_and_compute` 在现有 `data` hash 中新增两个字段：

```ruby
data = {
  phase: 'done',
  by_space: usages.map(&:to_h),       # 不变
  by_material: ...,                     # 不变
  items: @last_scan[:items].map(&:to_h),    # 新增：去重后的 ScanItem
  openings: @last_scan[:openings].map(&:to_h) # 新增：洞口列表
}
```

`items` 已经过 Calculator 薄板去重，与 `by_space` 中的 MaterialUsage 数据一致。

### JS 内存树结构

前端按 `component_path` 构建嵌套树：

```js
{
  name: "客厅",                          // 组件名（path 最后一级）
  path: ["住宅", "1层", "客厅"],          // 完整路径
  faces: [                               // 直接归属的面
    { face_id, su_material, qty, part, normal, width, height, layer_name }
  ],
  children: [ /* 子组件节点，同结构 */ ],
  stats: {                               // 聚合含子节点
    face_count: 6,
    total_area: 37.0,
    by_part: { floor: 25.0, wall: 12.0, ceiling: 0 },
    material_names: ["瓷砖-灰", "涂料-白"],
    material_count: 2
  }
}
```

## UI 设计

### 视图栏

新增「按组件」按钮作为第一个视图，设为默认 active：

```
[按组件(active)] [按空间汇总] [按材料汇总] [展开明细]
```

### 树形表格

HTML `<table>` 实现，层级靠缩进（padding-left）表达，不嵌套子 table。

- **组件行**：展开/折叠箭头 + 组件名 + 面数 + 总面积 + 地面/墙面/天花面积 + 材质数 + 材质列表
- **面行**：缩进更深，无箭头，显示面 ID + 面积 + 部位 + SU 材质色块 + 材质名
- **点击组件行**：切换 `display` 展开/折叠其子行（子组件 + 面行）
- **默认展开第一级**，其余折叠

### 列定义

| 列 | 组件行 | 面行 |
|---|---|---|
| 展开 | ▾/▸ | — |
| 名称 | 组件名 | 面 ID + SU材质色块 |
| 面数 | ✓ | — |
| 面积(m²) | ✓ | ✓（单面面积） |
| 地面 | ✓ | 有则填 |
| 墙面 | ✓ | 有则填 |
| 天花 | ✓ | 有则填 |
| 材质数 | ✓ | — |
| 材质 | 材质名列表 | 单一材质名 |

## 实现

### 文件改动

| 文件 | 改动 |
|---|---|
| `src/ui/dialog.rb` | `finalize_and_compute` 额外传 `items` + `openings` |
| `src/ui/index.html` | 视图栏新增「按组件」按钮，调整默认 active |
| `src/ui/app.js` | 新增 `buildComponentTree()` + `renderComponentView()`；`renderResults` 支持 `by-component` 视图；默认视图改为 `by-component` |
| `src/ui/styles.css` | 组件树表格行样式（缩进层级、展开态） |

### JS 核心函数

- `buildComponentTree(items)` — 按 `component_path` 分组构建嵌套树，递归聚合 `stats`
- `renderComponentView(tree, usages)` — 递归渲染 `<tr>` 行，返回 HTML 字符串
- `toggleComponentRow(rowId)` — 切换子行显示/隐藏

### 边界情况

- **空 component_path**：归入「模型根层级」节点
- **深层嵌套**：每级缩进 18px，路径列 CSS `text-overflow: ellipsis`
- **无面中间节点**：仅含子组件无直接面时，面数/面积显示子节点汇总
- **nil 材质面**：显示「未赋材质」

## 不改动

- Calculator 计算逻辑
- 现有三个视图（按空间/按材料/明细）
- MaterialMapping / ProcessLibrary
- Phase 1/2 流程
