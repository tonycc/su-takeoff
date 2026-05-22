# 模型选中面 → UI 自动高亮 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用户在 SketchUp 模型中选中面时，插件 UI 自动展开组件树并高亮对应面行。

**Architecture:** Ruby 端新增 `FaceSelectionObserver`（`Sketchup::SelectionObserver` 子类）监听选中变化，通过 `execute_script` 推送到前端。前端新增 `highlightFaceInUI` / `clearFaceHighlight` 全局函数，在 `geometry_usages` 中定位面所属容器，沿 hierarchy 树展开祖先节点后重绘，面行添加 `mv-highlight` CSS 类并滚动到可见区域。

**Tech Stack:** Ruby (SketchUp SelectionObserver API), vanilla JS, CSS

---

### Task 1: Ruby — 新增 FaceSelectionObserver

**Files:**
- Modify: `src/ui/dialog.rb`

- [ ] **Step 1: 在 Dialog 类外部定义 FaceSelectionObserver 类**

在 `module SuTakeoff` 内、`class Dialog` 之前添加：

```ruby
class FaceSelectionObserver < Sketchup::SelectionObserver
  def initialize(html_dialog)
    @html_dialog = html_dialog
  end

  def onSelectionBulkChange(selection)
    return unless @html_dialog.visible?
    entity = selection.first
    return unless entity.is_a?(Sketchup::Face)
    @html_dialog.execute_script("window.highlightFaceInUI(#{entity.entityID})")
  rescue => e
    # 静默失败，不干扰用户操作
  end

  def onSelectionCleared(selection)
    return unless @html_dialog.visible?
    @html_dialog.execute_script("window.clearFaceHighlight()")
  rescue => e
  end
end
```

- [ ] **Step 2: 在 Dialog#show 中 attach observer**

修改 `show` 方法，attach observer 到 model selection：

```ruby
def show
  @dialog.show
  model = Sketchup.active_model
  @selection_observer = FaceSelectionObserver.new(@dialog)
  model.selection.add_observer(@selection_observer)
end
```

- [ ] **Step 3: 提交**

```bash
git add src/ui/dialog.rb
git commit -m "feat: add FaceSelectionObserver to detect face selection in model"
```

---

### Task 2: 前端 — 新增 highlightFaceInUI 和 clearFaceHighlight

**Files:**
- Modify: `src/ui/app.js`

- [ ] **Step 1: 在 app.js 末尾添加两个全局函数**

```javascript
// ---------------- Model → UI face highlight ----------------
window.highlightFaceInUI = function(faceId) {
  if (window._currentPage !== 'position') return;
  if (!window._workbench) return;

  var data = window._workbench;
  var geoUsages = data.geometry_usages || [];
  var targetEntityId = null;

  // 查找包含该 face_id 的 geometry_usage 的 entity_id
  for (var i = 0; i < geoUsages.length; i++) {
    var faces = geoUsages[i].faces || [];
    for (var j = 0; j < faces.length; j++) {
      if (faces[j].face_id === faceId) {
        targetEntityId = geoUsages[i].entity_id;
        break;
      }
    }
    if (targetEntityId !== null) break;
  }

  if (targetEntityId === null) return;

  // 展开从根到目标 entity 路径上的所有祖先节点
  _mv.expandedNodes = _mv.expandedNodes || {};
  expandAncestorsToEntity(data.hierarchy, targetEntityId);

  // 设置高亮面 ID 并重绘
  _mv.highlightFaceId = faceId;
  renderPositionView(data);

  // 滚动到高亮行
  requestAnimationFrame(function() {
    var el = document.querySelector('.mv-highlight');
    if (el) el.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  });
};

window.clearFaceHighlight = function() {
  delete _mv.highlightFaceId;
  var els = document.querySelectorAll('.mv-highlight');
  for (var i = 0; i < els.length; i++) {
    els[i].classList.remove('mv-highlight');
  }
};

// 沿 hierarchy 树查找从根到 targetEid 的路径，展开所有祖先
function expandAncestorsToEntity(root, targetEid) {
  function findPath(node, target, path) {
    if (node.entity_id === target) {
      path.push(node.entity_id);
      return true;
    }
    for (var i = 0; i < node.children.length; i++) {
      if (findPath(node.children[i], target, path)) {
        path.push(node.entity_id);
        return true;
      }
    }
    return false;
  }

  var path = [];
  findPath(root, targetEid, path);
  for (var i = 0; i < path.length; i++) {
    if (path[i] !== 0) {
      _mv.expandedNodes[path[i]] = true;
    }
  }
}
```

- [ ] **Step 2: 提交**

```bash
git add src/ui/app.js
git commit -m "feat: add highlightFaceInUI and clearFaceHighlight for model-to-UI face selection"
```

---

### Task 3: 前端 — model_view.js 面行添加高亮支持

**Files:**
- Modify: `src/ui/js/model_view.js`

- [ ] **Step 1: 修改 renderFaceDetailRow，添加 data-face-id 和高亮类**

找到 `renderFaceDetailRow` 函数（约第357行），在 `var row = document.createElement('tr');` 之后添加两行：

```javascript
function renderFaceDetailRow(face, usage, depth, tbody) {
  var row = document.createElement('tr');
  row.className = 'mv-face-row';
  row.dataset.faceId = face.face_id;               // ← 新增
  if (_mv.highlightFaceId === face.face_id) {       // ← 新增
    row.classList.add('mv-highlight');              // ← 新增
  }                                                  // ← 新增

  var tdSeq = document.createElement('td');
  // ... 其余不变
```

- [ ] **Step 2: 提交**

```bash
git add src/ui/js/model_view.js
git commit -m "feat: add data-face-id and mv-highlight class to face detail rows"
```

---

### Task 4: CSS — 添加高亮样式

**Files:**
- Modify: `src/ui/styles.css`

- [ ] **Step 1: 在 styles.css 末尾添加 .mv-highlight 规则**

```css
/* 模型选中面 → UI 高亮 */
.mv-highlight {
  background: rgba(255, 180, 0, 0.18) !important;
  transition: background 0.25s;
}
```

- [ ] **Step 2: 提交**

```bash
git add src/ui/styles.css
git commit -m "style: add mv-highlight CSS for face selection highlight"
```

---

### Task 5: 手动验证

在 SketchUp 中验证以下场景：

- [ ] 扫描模型后，选中一个面 → UI 自动展开组件树并高亮该面行，自动滚动到该行
- [ ] 清除选中（点击空白区域）→ 高亮消失
- [ ] 切换到「按材料」视图后选中面 → 不触发高亮（不自动切换视图）
- [ ] 选中边或组件 → 无反应
- [ ] 多层嵌套组件内的面 → 能正确展开所有祖先层级
- [ ] dialog 关闭后重新打开 → observer 正常 attach，无异常
