# 按组件统计视图 — 实现计划

> **For agentic workers:** 使用 superpowers:subagent-driven-development 按任务逐步实现。步骤使用 checkbox (`- [ ]`) 语法跟踪。

**目标:** 在统计页面新增按组件维度的树形表格视图，设为默认，组件行点击可展开显示子组件和面明细。

**架构:** Ruby 端 `finalize_and_compute` 额外传递 `ScanItem` 和 `Opening` 数据；前端新增 `buildComponentTree` 构建嵌套树，`renderComponentView` 渲染树形表格，通过 `data-parent` 属性 + `toggleComponent` 实现行展开/折叠。

**技术栈:** Ruby (SketchUp API) + JavaScript (vanilla) + HTML/CSS

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `src/ui/dialog.rb` | 修改 `finalize_and_compute`，额外传 items + openings |
| `src/ui/index.html` | 视图栏新增「按组件」按钮，设为默认 active |
| `src/ui/app.js` | 新增 `buildComponentTree`、`renderComponentView`、`toggleComponent`；修改 `renderResults` 支持 `by-component` 视图并设默认 |
| `src/ui/styles.css` | 新增 `.comp-row`、`.face-row`、`.comp-toggle` 样式 |

---

### Task 1: Ruby 端 — finalize_and_compute 传递 items + openings

**Files:**
- Modify: `src/ui/dialog.rb:153-159`

- [ ] **Step 1: 在 data hash 中新增 items 和 openings 字段**

修改 `src/ui/dialog.rb`，在 `finalize_and_compute` 方法的 `data` hash 末尾追加两个字段。定位到第 153-159 行：

```ruby
      data = {
        phase: 'done',
        by_space: usages.map(&:to_h),
        by_material: by_material.transform_values { |v|
          { net_area: v[:net_area], purchase_qty: v[:purchase_qty] }
        },
        items: @last_scan[:items].map { |it|
          h = it.to_h
          h[:normal] = it.normal
          h[:component_path] = it.component_path
          h[:part] = Calculator.face_orientation(it.normal)
          h
        },
        openings: @last_scan[:openings].map(&:to_h)
      }
```

- [ ] **Step 2: 验证 Ruby 语法无报错**

```bash
ruby -c src/ui/dialog.rb
```

- [ ] **Step 3: Commit**

```bash
git add src/ui/dialog.rb
git commit -m "feat: pass scan items and openings to stats phase for component view"
```

---

### Task 2: HTML — 视图栏新增「按组件」按钮

**Files:**
- Modify: `src/ui/index.html:104-108`

- [ ] **Step 1: 在视图栏最前面插入「按组件」按钮，设为默认 active，其余按钮移除 active**

将第 104-108 行：
```html
      <div class="view-bar">
        <button class="view-btn active" data-view="by-space" onclick="switchView('by-space')">按空间汇总</button>
        <button class="view-btn" data-view="by-material" onclick="switchView('by-material')">按材料汇总</button>
        <button class="view-btn" data-view="detail" onclick="switchView('detail')">展开明细</button>
      </div>
```

替换为：
```html
      <div class="view-bar">
        <button class="view-btn active" data-view="by-component" onclick="switchView('by-component')">按组件</button>
        <button class="view-btn" data-view="by-space" onclick="switchView('by-space')">按空间汇总</button>
        <button class="view-btn" data-view="by-material" onclick="switchView('by-material')">按材料汇总</button>
        <button class="view-btn" data-view="detail" onclick="switchView('detail')">展开明细</button>
      </div>
```

- [ ] **Step 2: Commit**

```bash
git add src/ui/index.html
git commit -m "feat: add by-component view button as default in stats phase"
```

---

### Task 3: JavaScript — 新增 buildComponentTree 函数

**Files:**
- Modify: `src/ui/app.js`（在 `renderResults` 函数之前插入）

- [ ] **Step 1: 新增 `buildComponentTree` 函数**

在 `app.js` 中，`renderResults` 函数（约第 392 行）之前插入：

```js
// ---------------- Component tree builder ----------------
function buildComponentTree(items) {
  var root = { name: '', path: [], faces: [], children: [], childrenMap: {} };

  items.forEach(function(item) {
    var path = item.component_path || [];
    var node = root;
    path.forEach(function(name, idx) {
      if (!node.childrenMap[name]) {
        var child = {
          name: name,
          path: path.slice(0, idx + 1),
          faces: [],
          children: [],
          childrenMap: {}
        };
        node.children.push(child);
        node.childrenMap[name] = child;
      }
      node = node.childrenMap[name];
    });
    node.faces.push(item);
  });

  aggregateComponentStats(root);
  return root;
}

function aggregateComponentStats(node) {
  var stats = {
    face_count: 0, total_area: 0.0,
    by_part: { floor: 0.0, wall: 0.0, ceiling: 0.0 },
    material_names: {}, material_count: 0
  };

  node.children.forEach(function(child) {
    var cs = aggregateComponentStats(child);
    stats.face_count += cs.face_count;
    stats.total_area += cs.total_area;
    stats.by_part.floor += cs.by_part.floor;
    stats.by_part.wall += cs.by_part.wall;
    stats.by_part.ceiling += cs.by_part.ceiling;
    Object.keys(cs.material_names).forEach(function(m) { stats.material_names[m] = true; });
  });

  node.faces.forEach(function(face) {
    stats.face_count += 1;
    stats.total_area += face.qty || 0;
    if (face.part) stats.by_part[face.part] = (stats.by_part[face.part] || 0) + (face.qty || 0);
    if (face.su_material) stats.material_names[face.su_material] = true;
  });

  stats.material_count = Object.keys(stats.material_names).length;
  stats.total_area = +stats.total_area.toFixed(2);
  stats.by_part.floor = +stats.by_part.floor.toFixed(2);
  stats.by_part.wall = +stats.by_part.wall.toFixed(2);
  stats.by_part.ceiling = +stats.by_part.ceiling.toFixed(2);
  node.stats = stats;
  return stats;
}
```

- [ ] **Step 2: Commit**

```bash
git add src/ui/app.js
git commit -m "feat: add buildComponentTree and aggregateComponentStats functions"
```

---

### Task 4: JavaScript — 新增 renderComponentView 和 toggleComponent

**Files:**
- Modify: `src/ui/app.js`（在 buildComponentTree 之后插入）

- [ ] **Step 1: 新增渲染和切换函数**

在 `aggregateComponentStats` 函数之后、`renderResults` 之前插入：

```js
function renderComponentView(tree) {
  // Wrap orphan faces (empty component_path) in a synthetic "模型根层级" node
  if (tree.faces.length > 0) {
    var orphanNode = {
      name: '模型根层级', path: [], faces: tree.faces,
      children: [], childrenMap: {}
    };
    aggregateComponentStats(orphanNode);
    tree.children.unshift(orphanNode);
    tree.faces = [];
  }

  var html = '<table><thead><tr>' +
    '<th>组件 / 面</th>' +
    '<th style="text-align:right">面数</th>' +
    '<th style="text-align:right">面积(m²)</th>' +
    '<th style="text-align:right">地面</th>' +
    '<th style="text-align:right">墙面</th>' +
    '<th style="text-align:right">天花</th>' +
    '<th style="text-align:right">材质数</th>' +
    '<th>材质</th>' +
    '</tr></thead><tbody>';

  var rootId = 'comp-root';
  tree.children.forEach(function(child) {
    html += renderComponentNode(child, 1, rootId);
  });

  html += '</tbody></table>';
  return html;
}

function renderComponentNode(node, depth, parentId) {
  var html = '';
  var nodeId = 'comp-' + node.path.map(function(s) {
    return String(s).replace(/[^a-zA-Z0-9一-鿿]/g, '_');
  }).join('-');
  var indent = depth * 18;
  var hasChildren = node.children.length > 0 || node.faces.length > 0;
  var hidden = depth > 1 ? ' style="display:none"' : '';

  html += '<tr class="comp-row" data-depth="' + depth + '" data-parent="' + parentId + '"' + hidden + '>' +
    '<td style="padding-left:' + (indent + 6) + 'px">';
  if (hasChildren) {
    html += '<span class="comp-toggle" id="' + nodeId + '-toggle">' + (depth === 1 ? '▾' : '▸') + '</span> ';
  }
  html += esc(node.name) + '</td>' +
    '<td style="text-align:right">' + node.stats.face_count + '</td>' +
    '<td style="text-align:right">' + node.stats.total_area + '</td>' +
    '<td style="text-align:right">' + (node.stats.by_part.floor > 0 ? node.stats.by_part.floor : '—') + '</td>' +
    '<td style="text-align:right">' + (node.stats.by_part.wall > 0 ? node.stats.by_part.wall : '—') + '</td>' +
    '<td style="text-align:right">' + (node.stats.by_part.ceiling > 0 ? node.stats.by_part.ceiling : '—') + '</td>' +
    '<td style="text-align:right">' + node.stats.material_count + '</td>' +
    '<td style="font-size:11px">' + esc(Object.keys(node.stats.material_names).join(', ') || '—') + '</td>' +
    '</tr>';

  node.children.forEach(function(child) {
    html += renderComponentNode(child, depth + 1, nodeId);
  });
  node.faces.forEach(function(face) {
    html += renderFaceRow(face, depth + 1, nodeId);
  });

  return html;
}

function renderFaceRow(face, depth, parentId) {
  var indent = depth * 18;
  return '<tr class="face-row" data-depth="' + depth + '" data-parent="' + parentId + '" style="display:none">' +
    '<td style="padding-left:' + (indent + 6) + 'px; font-size:10px; color:#6c7086;">面 #' + esc(face.face_id) + '</td>' +
    '<td></td>' +
    '<td style="text-align:right">' + (face.qty || 0) + '</td>' +
    '<td style="text-align:right">' + (face.part === 'floor' ? (face.qty || 0) : '—') + '</td>' +
    '<td style="text-align:right">' + (face.part === 'wall' ? (face.qty || 0) : '—') + '</td>' +
    '<td style="text-align:right">' + (face.part === 'ceiling' ? (face.qty || 0) : '—') + '</td>' +
    '<td></td>' +
    '<td style="font-size:10px">' + esc(face.su_material || '未赋材质') + '</td>' +
    '</tr>';
}

function toggleComponent(nodeId) {
  var rows = document.querySelectorAll('[data-parent="' + nodeId + '"]');
  var toggle = document.getElementById(nodeId + '-toggle');
  if (!rows.length) return;
  var isHidden = rows[0].style.display === 'none';
  rows.forEach(function(row) {
    row.style.display = isHidden ? '' : 'none';
  });
  if (toggle) {
    toggle.textContent = isHidden ? '▾' : '▸';
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add src/ui/app.js
git commit -m "feat: add renderComponentView, renderComponentNode, renderFaceRow, toggleComponent"
```

---

### Task 5: JavaScript — 修改 renderResults 支持 by-component 视图并设默认

**Files:**
- Modify: `src/ui/app.js:392-446`

- [ ] **Step 1: 修改 renderResults 函数，添加 by-component 分支并作为默认视图**

修改 `renderResults` 函数第一行（默认视图）并添加 `by-component` 分支：

将第 395 行：
```js
  var activeView = view || document.querySelector('.view-btn.active')?.dataset.view || 'by-space';
```

改为：
```js
  var activeView = view || document.querySelector('.view-btn.active')?.dataset.view || 'by-component';
```

在 `container.innerHTML = '';` 之后、现有 `if` 之前插入 `by-component` 分支：

```js
  if (activeView === 'by-component' && data.items) {
    var tree = buildComponentTree(data.items);
    container.innerHTML = renderComponentView(tree);
    showPhase('stats');
    return;
  }

  var tableHtml = '<table><thead><tr>';
  // ... 现有代码保持不变 ...
```

完整修改后的函数开头（第 392-400 行）：

```js
function renderResults(data, view) {
  window._lastStats = data;

  var container = document.getElementById('stats-table-container');
  var activeView = view || document.querySelector('.view-btn.active')?.dataset.view || 'by-component';

  container.innerHTML = '';

  if (activeView === 'by-component' && data.items) {
    var tree = buildComponentTree(data.items);
    container.innerHTML = renderComponentView(tree);
    showPhase('stats');
    return;
  }

  var tableHtml = '<table><thead><tr>';
  if (activeView === 'by-space') {
    // ... 后续保持不变 ...
```

- [ ] **Step 2: 给组件行绑定点击事件**

表行上的 `onclick` 属性在 `innerHTML` 赋值后不会自动生效。需要在 `renderComponentView` 返回 HTML 并写入 DOM 后，手动绑定事件。修改 `by-component` 分支：

```js
  if (activeView === 'by-component' && data.items) {
    var tree = buildComponentTree(data.items);
    container.innerHTML = renderComponentView(tree);
    container.querySelectorAll('.comp-row').forEach(function(row) {
      row.addEventListener('click', function() {
        var children = document.querySelectorAll('[data-parent="' + row.dataset.parent + '"]');
        // Find the nodeId by looking at the toggle inside this row
        var toggle = row.querySelector('.comp-toggle');
        if (toggle) {
          var nodeId = toggle.id.replace('-toggle', '');
          toggleComponent(nodeId);
        }
      });
    });
    showPhase('stats');
    return;
  }
```

- [ ] **Step 3: Commit**

```bash
git add src/ui/app.js
git commit -m "feat: integrate by-component view into renderResults as default"
```

---

### Task 6: CSS — 新增组件树表格样式

**Files:**
- Modify: `src/ui/styles.css`（末尾追加）

- [ ] **Step 1: 追加组件树行样式**

在 `styles.css` 末尾追加：

```css
/* Component tree table */
.comp-row { cursor: pointer; }
.comp-row:hover { background: #1e1e3e; }
.comp-row td { border: 1px solid #45475a; padding: 6px 8px; }
.comp-row td:first-child { font-weight: 500; color: #cdd6f4; }
.comp-toggle { color: #89b4fa; font-size: 12px; font-weight: bold; min-width: 14px; display: inline-block; cursor: pointer; user-select: none; }
.face-row td { border: 1px solid #2a2a3a; padding: 3px 8px; color: #a6adc8; font-size: 11px; }
.face-row { background: #16161e; }
.face-row:hover { background: #1c1c28; }
```

- [ ] **Step 2: Commit**

```bash
git add src/ui/styles.css
git commit -m "feat: add component tree table styles"
```

---

### Task 7: 验证 — 运行测试确保不破坏现有功能

**Files:** 无

- [ ] **Step 1: 运行所有单元测试**

```bash
ruby -Itest test/test_data_models.rb
ruby -Itest test/test_mapping.rb
ruby -Itest test/test_process_library.rb
ruby -Itest test/test_calculator.rb
```

预期：全部 PASS。这些测试不依赖 SU 运行时，验证计算逻辑未被改动。

- [ ] **Step 2: 检查 Ruby 语法**

```bash
ruby -c src/ui/dialog.rb
ruby -c src/main.rb
```

预期：`Syntax OK`

- [ ] **Step 3: 最终 commit（如有 lint 修正）**

```bash
git add -A
git commit -m "chore: verify all tests pass after component stats changes"
```
（仅当有修正时提交；如无改动则跳过）
