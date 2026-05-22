# 模型选中面 → UI 自动高亮

## 概述

用户在 SketchUp 模型中选中面时，插件 UI 的「按组件」视图中自动展开树并高亮对应的面行，同时滚动到可视区域。

## 范围

- 仅在「按组件」视图中响应，不在该视图时忽略
- 多选时只取第一个面
- 非 Face 实体（边、组件等）的选中忽略
- 不自动切换视图

## 架构

```
SU 用户选中面
    ↓
SelectionObserver#onSelectionBulkChange 触发
    ↓
Dialog 读取选中面 entityID，判断是否为 Face
    ↓
execute_script("window.highlightFaceInUI(#{face_id})")
    ↓
前端: 找到面 → 展开祖先 → 重绘 → 高亮行 + scrollIntoView
```

## Ruby 端

### FaceSelectionObserver（`dialog.rb` 内新增）

- 继承 `Sketchup::SelectionObserver`
- `onSelectionBulkChange(selection)`: 取 `selection.first`，若为 `Sketchup::Face`，调用 `@dialog.execute_script("window.highlightFaceInUI(#{entity.entityID})")`
- `onSelectionCleared(selection)`: 调用 `@dialog.execute_script("window.clearFaceHighlight()")`

### 生命周期

- `Dialog#show` 时 attach observer 到 `Sketchup.active_model.selection`
- 使用 `@dialog.set_on_close` 回调 detach observer
- 多个 dialog 实例互不冲突（每次 show 创建新 observer）

## 前端

### app.js 新增两个全局函数

**`window.highlightFaceInUI(faceId)`**
1. 判断 `window._currentPage === 'position'`，否→忽略
2. 在 `window._workbench.geometry_usages` 中搜索 `faces` 数组里 `face_id === faceId` 的 usage
3. 取出该 usage 的 `entity_id`，沿 `hierarchy` 树展开从根到该节点的所有祖先
4. 设置 `_mv.highlightFaceId = faceId`
5. 调用 `renderPositionView(data)` 重绘

**`window.clearFaceHighlight()`**
1. 清除 `_mv.highlightFaceId`
2. 移除 DOM 中所有 `.mv-highlight` 类

### model_view.js 修改

- `renderFaceDetailRow`: 给 `<tr>` 添加 `data-face-id` 属性，若匹配 `_mv.highlightFaceId` 则添加 `mv-highlight` 类
- 重绘后通过 `requestAnimationFrame` + `querySelector('.mv-highlight')` + `scrollIntoView({ block: 'nearest' })` 滚动到高亮行

### styles.css 新增

```css
.mv-highlight {
  background: rgba(255, 180, 0, 0.15) !important;
  transition: background 0.3s;
}
```

## 测试

手动在 SketchUp 中验证：
1. 扫描模型后，选中一个面 → UI 自动展开树并高亮该面行
2. 清除选中 → 高亮消失
3. 切换到材料视图后选中面 → 不触发高亮（不切换视图）
4. 选中边或组件 → 无反应
5. dialog 关闭后 observer 正常 detach，无异常
