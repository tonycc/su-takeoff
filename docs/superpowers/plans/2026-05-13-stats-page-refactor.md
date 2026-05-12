# 统计页面交互重构 — 实现计划

> **For agentic workers:** 使用 superpowers:executing-plans 按任务逐步实现（推荐本会话内执行，因为前端改动需要用户验证）。步骤使用 checkbox (`- [ ]`) 语法跟踪。

**目标:** 把当前 Phase 1/2/3 线性流程重构为"同页多视图"工作台，扫描一次后在组件/材料/采购量三个视图间自由切换，映射就地编辑并即时重算。

**架构:** Ruby 端统一一个 `send_workbench_state` 方法，扫描后和映射变化后都调用它，把 items/openings/mapping/usages/counts 一次性推给前端。前端拆分为"骨架 + 视图渲染器 + 状态"，用 `window._workbench` 缓存数据，切视图只重绘 DOM 不调 Ruby。

**技术栈:** Ruby (SketchUp HtmlDialog API) + JavaScript (vanilla) + HTML/CSS

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `src/ui/dialog.rb` | 合并三阶段的数据推送为 `send_workbench_state`；映射变更后自动重算 Calculator |
| `src/ui/index.html` | 删除 phase-scan/phase-mapping/phase-stats 三卡片；改为扫描栏 + 摘要条 + 视图切换 + 视图容器 |
| `src/ui/app.js` | 删除 phase 切换；新增组件/材料/采购量三个视图渲染器；摘要条与筛选栏交互；视图状态保留 |
| `src/ui/styles.css` | 摘要条、筛选栏、警告条等新样式 |

---

### Task 1: Ruby — 统一数据推送

**Files:**
- Modify: `src/ui/dialog.rb`

**为什么**: 现在 `send_review_state`（Phase 1+2 用）和 `finalize_and_compute`（Phase 3 用）分别推送不同的 data hash。重构后所有视图同源，需要一个统一的 payload。

- [ ] **Step 1: 添加 `send_workbench_state` 方法，替代 `send_review_state` + `finalize_and_compute`**

在 `src/ui/dialog.rb` 中，把 `send_review_state` 和 `finalize_and_compute` 两个方法替换为单个 `send_workbench_state`。在文件 `private` 之后插入新方法，删除旧的两个：

```ruby
    # Unified state push — called after scan and after any mapping/ignored change.
    # Computes usages for all mapped materials; unmapped are returned for editing UI.
    def send_workbench_state
      return unless @last_scan

      mapping = PluginState.instance.mapping
      ignored = PluginState.instance.ignored
      processes = PluginState.instance.processes
      all_items = @last_scan[:items]

      used_names = all_items.map(&:su_material).compact.uniq
      unresolved = used_names.reject { |n| mapping.get(n) || ignored.include?(n) }
      mapped_names = used_names.select { |n| mapping.get(n) }
      ignored_names = ignored & used_names

      # Recompute usages for all mapped materials. Unmapped materials are
      # filtered by Calculator (no record in mapping → skipped).
      calc = Calculator.new(mapping, processes)
      usages = calc.compute(all_items, @last_scan[:openings], {})
      by_material = calc.group_by_material(usages)

      info = build_material_info(used_names, all_items, @last_scan[:colors])

      data = {
        overview: {
          total_faces: all_items.size,
          total_area: all_items.sum(&:qty).round(2),
          total_openings: @last_scan[:openings].size,
          total_opening_area: @last_scan[:openings].sum(&:area).round(2),
          material_count: used_names.size,
          mapped: mapped_names.size,
          ignored_count: ignored_names.size,
          unresolved_count: unresolved.size
        },
        items: all_items.map { |it|
          h = it.to_h
          h[:normal] = it.normal
          h[:component_path] = it.component_path
          h[:component_path_ids] = it.component_path_ids
          h[:part] = Calculator.face_orientation(it.normal)
          h
        },
        openings: @last_scan[:openings].map(&:to_h),
        ignored: ignored_names,
        unresolved: unresolved,
        materials_info: info,
        categories: processes.all_categories,
        usages: usages.map(&:to_h),
        by_material: by_material.transform_values { |v|
          { net_area: v[:net_area], purchase_qty: v[:purchase_qty] }
        }
      }
      @dialog.execute_script("window.renderWorkbench(#{JSON.generate(data)})")
    end
```

- [ ] **Step 2: 删除旧的 `send_review_state` 方法**

在同一文件中查找 `def send_review_state` 方法块（约 66-120 行）并整体删除。新的 `send_workbench_state` 取代它的全部功能。

- [ ] **Step 3: 删除旧的 `finalize_and_compute` 方法**

查找 `def finalize_and_compute` 方法块（约 122-170 行）并整体删除。映射变更后由 `send_workbench_state` 自动处理重算。

- [ ] **Step 4: 把所有旧方法的调用点替换为 `send_workbench_state`**

在 `src/ui/dialog.rb` 中查找并替换所有 `send_review_state` 和 `finalize_and_compute` 的调用：

```ruby
# do_scan 方法末尾：
send_review_state  →  send_workbench_state

# save_mappings_batch 方法末尾：
send_review_state if @last_scan  →  send_workbench_state if @last_scan

# set_ignored 方法末尾：
send_review_state if @last_scan  →  send_workbench_state if @last_scan

# load_from_model 方法末尾：
send_review_state if @last_scan  →  send_workbench_state if @last_scan
```

- [ ] **Step 5: 移除 `finalize_compute` action callback（不再需要）**

在 `initialize` 方法中删除这一行：

```ruby
@dialog.add_action_callback('finalize_compute') { |_ctx| finalize_and_compute }
```

- [ ] **Step 6: 验证 Ruby 语法**

Run: `ruby -c src/ui/dialog.rb`
Expected: `Syntax OK`

- [ ] **Step 7: Commit**

```bash
git add src/ui/dialog.rb
git commit -m "feat: unify stats data push into send_workbench_state"
```

---

### Task 2: HTML — 重构统计标签页骨架

**Files:**
- Modify: `src/ui/index.html`

**为什么**: 需要移除 phase 切换的三卡片结构，改为扫描栏 + 摘要条 + 视图切换 + 单一视图容器。

- [ ] **Step 1: 替换 `<div id="tab-statistics">` 的全部内容**

找到 `<div id="tab-statistics" class="tab-content active">` 开始到其闭合 `</div>` 的全部内容，替换为：

```html
  <!-- Tab 1: Statistics — unified workbench -->
  <div id="tab-statistics" class="tab-content active">

    <!-- Scan controls (always visible) -->
    <div id="scan-controls" class="toolbar">
      <button onclick="scanAll()">扫描全部</button>
      <button onclick="scanSelected()">仅选中面</button>
      <button onclick="manualMark()">手动标记面</button>
    </div>

    <!-- Empty state (before first scan) -->
    <div id="empty-state" class="empty-state">
      <p>🔍 请先点击「扫描全部」或「仅选中面」</p>
    </div>

    <!-- Workbench (shown after scan) -->
    <div id="workbench" style="display:none">

      <!-- Summary bar -->
      <div id="summary-bar" class="summary-bar"></div>

      <!-- View switcher -->
      <div class="view-bar">
        <button class="view-btn active" data-view="component" onclick="switchWorkbenchView('component')">按组件</button>
        <button class="view-btn" data-view="material" onclick="switchWorkbenchView('material')">按材料</button>
        <button class="view-btn" data-view="purchase" onclick="switchWorkbenchView('purchase')">采购量</button>
      </div>

      <!-- View containers (only one visible at a time) -->
      <div id="view-component" class="view-container"></div>
      <div id="view-material" class="view-container" style="display:none"></div>
      <div id="view-purchase" class="view-container" style="display:none"></div>
    </div>
  </div>
```

- [ ] **Step 2: 验证 HTML 结构合法**

用编辑器或浏览器打开 `src/ui/index.html`，确保其他 tab（映射、设置）和 marking-dialog 未被影响，文件末尾的 `<script src="app.js"></script>` 仍然存在。

- [ ] **Step 3: Commit**

```bash
git add src/ui/index.html
git commit -m "feat: replace phase cards with unified workbench skeleton"
```

---

### Task 3: JavaScript — 重写骨架（扫描、摘要条、视图切换）

**Files:**
- Modify: `src/ui/app.js`

**为什么**: 删除 phase 切换相关逻辑，新增 `renderWorkbench` 入口和视图切换机制。后续视图渲染器 task 都挂在这个骨架上。

- [ ] **Step 1: 删除旧的 phase 切换与合并后不再需要的代码**

在 `src/ui/app.js` 中：

1. 删除 `function showPhase(phase)` 定义和 `goToMapping` / `goToScan` 函数
2. 删除 `function renderReview(data)` 整个函数（约 44-192 行）
3. 删除 `function renderMappingPhase()` 和 `function renderReviewTable(data)`（及其辅助 `renderNameCell`, `renderContextCell`, `renderEditCells`）
4. 删除 `function renderResults(data, view)` 整个函数
5. 删除文件末尾的 `_origRenderReview` / `_origGoToMapping` 的 monkey-patch 代码
6. 保留：`switchView` 改为 `switchWorkbenchView`（下面 Step 2 重写）、`callSketchUp`、`scanAll`、`scanSelected`、`callSketchUp` 系列辅助函数、`esc`、`escAttr`、`DEFAULT_CATEGORIES`、`guessCategory`、`locateMaterial`、`finalizeCompute`（可删除）、`renderMappings`、`filterMappings`、`importCsv`、`exportCsv`、`openAddMapping`、`deleteMapping`、`renderProcesses`、手动标记相关函数、`snapshotToModel`、`loadFromModel`

实际操作：Rewrite 整个 `app.js`，见下面 Step 2 的完整内容。

- [ ] **Step 2: 完整写入新的 `app.js` 顶部骨架（保留辅助函数与其他 tab 功能）**

保留文件开头的 tab 切换逻辑（顶部标签栏 `统计 / 映射 / 设置`），直到 `finalizeCompute` 之前的大量 phase 逻辑全部换成骨架：

```js
// ---------------- Tab switching ----------------
document.querySelectorAll('.tab-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
    document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
    btn.classList.add('active');
    document.getElementById('tab-' + btn.dataset.tab).classList.add('active');
  });
});

// ---------------- Bridge ----------------
function callSketchUp(action, json) {
  if (typeof sketchup !== 'undefined') {
    sketchup[action](json || '');
  } else {
    console.warn('Not running in SketchUp HtmlDialog');
  }
}

// ---------------- Scan entry ----------------
function scanAll() { callSketchUp('scan_all'); }
function scanSelected() { callSketchUp('scan_selected'); }

// ---------------- Workbench state ----------------
window._workbench = null;  // latest data from Ruby
window._workbenchView = 'component';  // current view
window._materialFilter = 'all';  // all | unresolved | mapped | ignored
window._materialSearch = '';

// Entry point called by Ruby after scan or mapping change.
function renderWorkbench(data) {
  window._workbench = data;
  document.getElementById('empty-state').style.display = 'none';
  document.getElementById('workbench').style.display = 'block';
  renderSummaryBar(data);
  renderCurrentView();
}

function switchWorkbenchView(view) {
  window._workbenchView = view;
  document.querySelectorAll('.view-btn').forEach(b => b.classList.remove('active'));
  document.querySelector('.view-btn[data-view="' + view + '"]').classList.add('active');
  ['component', 'material', 'purchase'].forEach(function(v) {
    document.getElementById('view-' + v).style.display = (v === view ? 'block' : 'none');
  });
  renderCurrentView();
}

function renderCurrentView() {
  if (!window._workbench) return;
  var view = window._workbenchView;
  if (view === 'component') renderComponentView(window._workbench);
  else if (view === 'material') renderMaterialView(window._workbench);
  else if (view === 'purchase') renderPurchaseView(window._workbench);
}

// ---------------- Summary bar ----------------
function renderSummaryBar(data) {
  var ov = data.overview || {};
  var unresolved = ov.unresolved_count || 0;
  var unresolvedStyle = unresolved > 0 ? 'color:#f38ba8;cursor:pointer' : 'color:#a6e3a1';
  var unresolvedClick = unresolved > 0 ? 'onclick="jumpToUnresolved()"' : '';

  document.getElementById('summary-bar').innerHTML =
    '<span class="sum-item">' + (ov.total_faces || 0) + ' 面</span>' +
    '<span class="sum-item">' + (ov.total_area || 0) + ' m²</span>' +
    '<span class="sum-item">' + (ov.material_count || 0) + ' 种材质</span>' +
    '<span class="sum-item">已映射 ' + (ov.mapped || 0) + '</span>' +
    '<span class="sum-item"><span style="' + unresolvedStyle + '" ' + unresolvedClick + '>待 ' + unresolved + '</span></span>' +
    '<span class="sum-item">已忽略 ' + (ov.ignored_count || 0) + '</span>' +
    '<span class="sum-item">洞口 ' + (ov.total_openings || 0) + ' / ' + (ov.total_opening_area || 0) + ' m²</span>';
}

function jumpToUnresolved() {
  window._materialFilter = 'unresolved';
  switchWorkbenchView('material');
}

// ---------------- View renderers (stubs — filled in later tasks) ----------------
function renderComponentView(data) {
  document.getElementById('view-component').innerHTML = '<p class="hint">组件视图 (待实现)</p>';
}
function renderMaterialView(data) {
  document.getElementById('view-material').innerHTML = '<p class="hint">材料视图 (待实现)</p>';
}
function renderPurchaseView(data) {
  document.getElementById('view-purchase').innerHTML = '<p class="hint">采购量视图 (待实现)</p>';
}
```

把上述代码替换 `app.js` 中旧的 phase/tab 逻辑（从 `document.querySelectorAll('.tab-btn')` 开始到旧的 `function renderResults` 结束）。保留文件后半段的 mapping tab、settings、marking dialog 相关函数以及 `esc` / `escAttr` 辅助函数。

- [ ] **Step 3: 保留并调整文件后半部分（mapping tab、marking、settings、helpers）**

确认以下函数仍在文件里（不要改动）：
- `renderMappings`, `filterMappings`, `deleteMapping`, `importCsv`, `exportCsv`, `openAddMapping`
- `renderProcesses`
- `manualMark`, `closeMarkDialog`, `confirmMark`
- `snapshotToModel`, `loadFromModel`
- `esc`, `escAttr`

删除（不再需要）：`finalizeCompute`、`goToMapping`、`goToScan`、`showPhase`、`toggleGroup`、`switchView`（被 `switchWorkbenchView` 替代）、`DEFAULT_CATEGORIES` 和 `guessCategory`（后面 Task 5 重新使用，保留即可）、`fillCommonDefaults`、`ignoreAllUnresolved`、`toggleIgnore`、`saveUnmappedBatch`、`locateMaterial`（保留，material view 使用）。

实际删除清单：`showPhase`、`goToMapping`、`goToScan`、`finalizeCompute`、`switchView`、`toggleGroup`、`fillCommonDefaults`、`ignoreAllUnresolved`、`toggleIgnore`、`saveUnmappedBatch`、旧的 `buildComponentTree`、`aggregateComponentStats`、`dominantPartBadge`、`renderComponentView`、`renderComponentNode`、`renderFaceRow`、`toggleComponent`（这些在 Task 4 重新实现）。

保留：`DEFAULT_CATEGORIES`、`guessCategory`、`locateMaterial`。

- [ ] **Step 4: Commit**

```bash
git add src/ui/app.js
git commit -m "refactor: replace phase-based JS with workbench skeleton"
```

---

### Task 4: JavaScript — 组件视图（含采购量列）

**Files:**
- Modify: `src/ui/app.js`

- [ ] **Step 1: 在 app.js 中找到 `function renderComponentView(data)` stub 并用下面的完整实现替换**

```js
// ---------------- Component view ----------------
function renderComponentView(data) {
  var tree = buildComponentTree(data.items || []);
  var purchaseBySu = buildPurchaseBySuMaterial(data.usages || []);
  var html = renderComponentTable(tree, purchaseBySu);
  document.getElementById('view-component').innerHTML = html;
  document.querySelectorAll('#view-component .comp-row').forEach(function(row) {
    row.addEventListener('click', function() {
      var toggle = row.querySelector('.comp-toggle');
      if (toggle) toggleComponent(toggle.id.replace('-toggle', ''));
    });
  });
}

function buildComponentTree(items) {
  var root = { name: '', path: [], path_ids: [], faces: [], children: [], childrenMap: {} };
  items.forEach(function(item) {
    var path = item.component_path || [];
    var ids = item.component_path_ids || [];
    var node = root;
    path.forEach(function(name, idx) {
      var id = ids[idx];
      var key = id != null ? String(id) : ('name:' + name + ':' + idx);
      if (!node.childrenMap[key]) {
        var child = {
          name: name, id: id,
          path: path.slice(0, idx + 1),
          path_ids: ids.slice(0, idx + 1),
          faces: [], children: [], childrenMap: {}
        };
        node.children.push(child);
        node.childrenMap[key] = child;
      }
      node = node.childrenMap[key];
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
    material_names: {}, material_count: 0,
    purchase_qty: 0.0, any_unmapped: false
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

function dominantPartBadge(stats) {
  var total = (stats.by_part.floor || 0) + (stats.by_part.wall || 0) + (stats.by_part.ceiling || 0);
  if (total <= 0) return '';
  var threshold = 0.8;
  var labels = { floor: '地面', wall: '墙面', ceiling: '天花' };
  var dominant = null;
  ['floor', 'wall', 'ceiling'].forEach(function(p) {
    if ((stats.by_part[p] || 0) / total >= threshold) dominant = p;
  });
  if (dominant) {
    return ' <span class="part-badge part-badge-' + dominant + '">' + labels[dominant] + '</span>';
  }
  return ' <span class="part-badge part-badge-mixed">混合</span>';
}

// Build { su_material_name => purchase_qty } from usages
function buildPurchaseBySuMaterial(usages) {
  var result = {};
  usages.forEach(function(u) {
    var su = u.su_material_name;
    if (!su) return;
    result[su] = (result[su] || 0) + (u.purchase_qty || 0);
  });
  Object.keys(result).forEach(function(k) { result[k] = +result[k].toFixed(2); });
  return result;
}

function renderComponentTable(tree, purchaseBySu) {
  if (tree.faces.length > 0) {
    var orphan = {
      name: '模型根层级', path: [], path_ids: [], faces: tree.faces,
      children: [], childrenMap: {}
    };
    aggregateComponentStats(orphan);
    tree.children.unshift(orphan);
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
    '<th style="text-align:right">采购量</th>' +
    '</tr></thead><tbody>';
  var rootId = 'comp-root';
  tree.children.forEach(function(child) {
    html += renderComponentNode(child, 1, rootId, purchaseBySu);
  });
  html += '</tbody></table>';
  return html;
}

function renderComponentNode(node, depth, parentId, purchaseBySu) {
  var html = '';
  var idKey = (node.path_ids || []).join('-') || 'noid-' + node.path.join('-');
  var nodeId = 'comp-' + idKey.replace(/[^a-zA-Z0-9\-]/g, '_');
  var indent = depth * 18;
  var hasChildren = node.children.length > 0 || node.faces.length > 0;
  var hidden = depth > 1 ? ' style="display:none"' : '';
  var partBadge = dominantPartBadge(node.stats);

  // Compute node's purchase_qty total (sum over faces' materials)
  var mats = Object.keys(node.stats.material_names);
  var purchaseTotal = 0;
  var anyUnmapped = false;
  mats.forEach(function(m) {
    if (purchaseBySu[m] != null) purchaseTotal += purchaseBySu[m];
    else anyUnmapped = true;
  });
  var purchaseCell = mats.length === 0 ? '—' :
    (anyUnmapped
      ? '<span style="color:#6c7086" title="含未映射材质">' + purchaseTotal.toFixed(2) + ' *</span>'
      : purchaseTotal.toFixed(2));

  html += '<tr class="comp-row" data-depth="' + depth + '" data-parent="' + parentId + '"' + hidden + '>' +
    '<td style="padding-left:' + (indent + 6) + 'px">';
  if (hasChildren) {
    html += '<span class="comp-toggle" id="' + nodeId + '-toggle">' + (depth === 1 ? '▾' : '▸') + '</span> ';
  } else {
    html += '<span class="comp-toggle-empty"></span> ';
  }
  html += esc(node.name) + partBadge + '</td>' +
    '<td style="text-align:right">' + node.stats.face_count + '</td>' +
    '<td style="text-align:right">' + node.stats.total_area + '</td>' +
    '<td style="text-align:right">' + (node.stats.by_part.floor > 0 ? node.stats.by_part.floor : '—') + '</td>' +
    '<td style="text-align:right">' + (node.stats.by_part.wall > 0 ? node.stats.by_part.wall : '—') + '</td>' +
    '<td style="text-align:right">' + (node.stats.by_part.ceiling > 0 ? node.stats.by_part.ceiling : '—') + '</td>' +
    '<td style="text-align:right">' + node.stats.material_count + '</td>' +
    '<td style="font-size:11px">' + esc(mats.join(', ') || '—') + '</td>' +
    '<td style="text-align:right">' + purchaseCell + '</td>' +
    '</tr>';

  node.children.forEach(function(child) {
    html += renderComponentNode(child, depth + 1, nodeId, purchaseBySu);
  });
  node.faces.forEach(function(face) {
    html += renderFaceRow(face, depth + 1, nodeId, purchaseBySu);
  });
  return html;
}

function renderFaceRow(face, depth, parentId, purchaseBySu) {
  var indent = depth * 18;
  var mapped = face.su_material && purchaseBySu[face.su_material] != null;
  var statusIcon = !face.su_material ? '' :
    (mapped ? '<span style="color:#a6e3a1">✓</span> ' : '<span style="color:#f38ba8">●</span> ');
  return '<tr class="face-row" data-depth="' + depth + '" data-parent="' + parentId + '" style="display:none">' +
    '<td style="padding-left:' + (indent + 6) + 'px; font-size:10px; color:#6c7086;">' + statusIcon + '面 #' + esc(face.face_id) + '</td>' +
    '<td></td>' +
    '<td style="text-align:right">' + (face.qty || 0) + '</td>' +
    '<td style="text-align:right">' + (face.part === 'floor' ? (face.qty || 0) : '—') + '</td>' +
    '<td style="text-align:right">' + (face.part === 'wall' ? (face.qty || 0) : '—') + '</td>' +
    '<td style="text-align:right">' + (face.part === 'ceiling' ? (face.qty || 0) : '—') + '</td>' +
    '<td></td>' +
    '<td style="font-size:10px">' + esc(face.su_material || '未赋材质') + '</td>' +
    '<td></td>' +
    '</tr>';
}

function toggleComponent(nodeId) {
  var rows = document.querySelectorAll('[data-parent="' + nodeId + '"]');
  var toggle = document.getElementById(nodeId + '-toggle');
  if (!rows.length) return;
  var isHidden = rows[0].style.display === 'none';
  rows.forEach(function(row) { row.style.display = isHidden ? '' : 'none'; });
  if (toggle) toggle.textContent = isHidden ? '▾' : '▸';
}
```

- [ ] **Step 2: Commit**

```bash
git add src/ui/app.js
git commit -m "feat: implement component view with purchase_qty column"
```

---

### Task 5: JavaScript — 材料视图（就地映射）

**Files:**
- Modify: `src/ui/app.js`

**为什么**: 这是方案 C 的核心——让用户在同一张表里看材料分布、直接填写映射、按需忽略。替换旧的 Phase 2 review 表。

- [ ] **Step 1: 替换 `function renderMaterialView(data)` stub**

```js
// ---------------- Material view ----------------
function renderMaterialView(data) {
  var container = document.getElementById('view-material');
  var counts = computeMaterialCounts(data);

  var html = '<div class="material-filter-bar">' +
    filterButton('all', '全部', counts.all) +
    filterButton('unresolved', '待映射', counts.unresolved) +
    filterButton('mapped', '已映射', counts.mapped) +
    filterButton('ignored', '已忽略', counts.ignored) +
    '<input type="text" id="material-search" placeholder="🔍 搜索..." value="' + esc(window._materialSearch || '') + '" oninput="onMaterialSearch(this.value)">' +
    '</div>' +
    '<table id="material-table"><thead><tr>' +
      '<th style="width:4%">状态</th>' +
      '<th style="width:20%">SU材质</th>' +
      '<th style="width:12%">面数/面积</th>' +
      '<th style="width:14%">部位分布</th>' +
      '<th>真实材料名</th>' +
      '<th>分类</th>' +
      '<th>规格</th>' +
      '<th>损耗率</th>' +
      '<th style="width:5%">忽略</th>' +
      '<th style="width:5%">定位</th>' +
    '</tr></thead><tbody id="material-tbody"></tbody></table>' +
    '<div class="toolbar" style="margin-top:12px">' +
      '<button onclick="fillDefaultMaterialNames()">一键填默认</button>' +
      '<button onclick="saveMaterialMappings()" class="primary-btn">保存映射</button>' +
      '<button onclick="ignoreAllUnresolved()">全部忽略</button>' +
    '</div>';
  container.innerHTML = html;
  renderMaterialTableBody(data);
}

function computeMaterialCounts(data) {
  var all = (data.materials_info || []).length;
  var unresolvedSet = {}; (data.unresolved || []).forEach(function(n) { unresolvedSet[n] = true; });
  var ignoredSet = {}; (data.ignored || []).forEach(function(n) { ignoredSet[n] = true; });
  var unresolved = (data.materials_info || []).filter(function(i) { return unresolvedSet[i.su_name]; }).length;
  var ignored = (data.materials_info || []).filter(function(i) { return ignoredSet[i.su_name]; }).length;
  return { all: all, unresolved: unresolved, ignored: ignored, mapped: all - unresolved - ignored };
}

function filterButton(key, label, count) {
  var active = window._materialFilter === key ? ' active' : '';
  return '<button class="filter-btn' + active + '" onclick="setMaterialFilter(\'' + key + '\')">' + label + ' (' + count + ')</button>';
}

function setMaterialFilter(key) {
  window._materialFilter = key;
  renderMaterialView(window._workbench);
}

function onMaterialSearch(value) {
  window._materialSearch = value;
  renderMaterialTableBody(window._workbench);
}

function renderMaterialTableBody(data) {
  var tbody = document.getElementById('material-tbody');
  if (!tbody) return;
  var unresolvedSet = {}; (data.unresolved || []).forEach(function(n) { unresolvedSet[n] = true; });
  var ignoredSet = {}; (data.ignored || []).forEach(function(n) { ignoredSet[n] = true; });
  var filter = window._materialFilter || 'all';
  var q = (window._materialSearch || '').toLowerCase();
  var partLabels = { floor: '地', wall: '墙', ceiling: '顶' };

  tbody.innerHTML = '';
  (data.materials_info || []).forEach(function(info) {
    var name = info.su_name;
    var isIgnored = !!ignoredSet[name];
    var isUnresolved = !!unresolvedSet[name];
    var isMapped = !isIgnored && !isUnresolved;

    if (filter === 'unresolved' && !isUnresolved) return;
    if (filter === 'mapped' && !isMapped) return;
    if (filter === 'ignored' && !isIgnored) return;
    if (q && name.toLowerCase().indexOf(q) === -1) return;

    var status = isMapped
      ? '<span class="tag tag-mapped">✓</span>'
      : (isIgnored ? '<span class="tag tag-ignored">○</span>' : '<span class="tag tag-unresolved">●</span>');

    var c = info.color || {};
    var swatch = info.color
      ? '<span class="swatch" style="background:rgba(' + c.r + ',' + c.g + ',' + c.b + ',' + (c.a || 1) + ')"></span>'
      : '<span class="swatch swatch-empty">?</span>';

    var partsHtml = '';
    if (info.parts) {
      Object.keys(info.parts).forEach(function(p) {
        partsHtml += '<span class="pill pill-' + p + '">' + (partLabels[p] || p) + ' ' + info.parts[p] + '</span>';
      });
    }

    var editable = !isMapped;
    var dis = editable ? '' : ' disabled';
    var cats = (window._workbench.categories && window._workbench.categories.length)
      ? window._workbench.categories : DEFAULT_CATEGORIES;
    var catOptions = cats.map(function(cat) {
      var sel = cat === guessCategory(name) ? ' selected' : '';
      return '<option value="' + esc(cat) + '"' + sel + '>' + esc(cat) + '</option>';
    }).join('');

    var tr = document.createElement('tr');
    tr.className = 'row-' + (isMapped ? 'mapped' : (isIgnored ? 'ignored' : 'unresolved'));
    tr.innerHTML =
      '<td>' + status + '</td>' +
      '<td><div class="u-name-row">' + swatch +
        '<span class="u-name" title="' + esc(name) + '">' + esc(name) + '</span>' +
      '</div><input type="hidden" class="u-su" value="' + esc(name) + '"></td>' +
      '<td>' + (info.face_count || 0) + ' 面 / ' + (info.total_area || 0) + ' m²</td>' +
      '<td>' + partsHtml + '</td>' +
      '<td><input type="text" class="u-mat" placeholder="留空跳过"' + dis + '></td>' +
      '<td><select class="u-cat"' + dis + '>' + catOptions + '</select></td>' +
      '<td><input type="text" class="u-spec" placeholder="可选"' + dis + '></td>' +
      '<td><input type="number" class="u-waste" step="0.01" value="0.05" style="width:60px"' + dis + '></td>' +
      '<td><input type="checkbox" class="u-ignore"' + (isIgnored ? ' checked' : '') +
         ' onchange="toggleMaterialIgnore(\'' + escAttr(name) + '\', this.checked)"></td>' +
      '<td><button onclick="locateMaterial(\'' + escAttr(name) + '\')">🎯</button></td>';
    tbody.appendChild(tr);
  });
}

function fillDefaultMaterialNames() {
  document.querySelectorAll('#material-tbody tr.row-unresolved').forEach(function(tr) {
    var mat = tr.querySelector('.u-mat');
    if (mat && !mat.value) mat.value = tr.querySelector('.u-su').value;
  });
}

function saveMaterialMappings() {
  var rows = [];
  document.querySelectorAll('#material-tbody tr.row-unresolved').forEach(function(tr) {
    if (tr.querySelector('.u-ignore').checked) return;
    var mat = tr.querySelector('.u-mat').value.trim();
    if (!mat) return;
    rows.push({
      su_name: tr.querySelector('.u-su').value,
      material_name: mat,
      category: tr.querySelector('.u-cat').value,
      spec: tr.querySelector('.u-spec').value,
      unit: 'm²',
      waste_rate: parseFloat(tr.querySelector('.u-waste').value) || 0.05
    });
  });
  if (rows.length === 0) {
    alert('没有可保存的映射 — 请先填写"真实材料名"');
    return;
  }
  callSketchUp('save_mappings_batch', JSON.stringify(rows));
}

function ignoreAllUnresolved() {
  var names = [];
  document.querySelectorAll('#material-tbody tr.row-unresolved').forEach(function(tr) {
    names.push(tr.querySelector('.u-su').value);
  });
  if (names.length === 0) return;
  if (!confirm('将忽略 ' + names.length + ' 种待处理材质，确认？')) return;
  var current = (window._workbench && window._workbench.ignored) || [];
  var set = {};
  current.forEach(function(n) { set[n] = true; });
  names.forEach(function(n) { set[n] = true; });
  callSketchUp('set_ignored', JSON.stringify(Object.keys(set)));
}

function toggleMaterialIgnore(name, on) {
  var current = (window._workbench && window._workbench.ignored) || [];
  var set = {};
  current.forEach(function(n) { set[n] = true; });
  if (on) set[name] = true; else delete set[name];
  callSketchUp('set_ignored', JSON.stringify(Object.keys(set)));
}
```

- [ ] **Step 2: Commit**

```bash
git add src/ui/app.js
git commit -m "feat: implement material view with inline mapping"
```

---

### Task 6: JavaScript — 采购量视图（按材料/按空间/CSV 导出）

**Files:**
- Modify: `src/ui/app.js`

- [ ] **Step 1: 替换 `function renderPurchaseView(data)` stub**

```js
// ---------------- Purchase view ----------------
window._purchaseMode = 'by-material';  // by-material | by-space

function renderPurchaseView(data) {
  var container = document.getElementById('view-purchase');
  var unresolved = (data.overview && data.overview.unresolved_count) || 0;
  var warning = unresolved > 0
    ? '<div class="warning-bar">⚠ 还有 ' + unresolved + ' 种材质未映射，未计入采购量 ' +
      '<button onclick="jumpToUnresolved()">前往材料视图</button></div>'
    : '';
  var toolbar =
    '<div class="toolbar">' +
      '<span>汇总方式：</span>' +
      '<button class="pm-btn' + (window._purchaseMode === 'by-material' ? ' active' : '') + '" onclick="setPurchaseMode(\'by-material\')">按材料</button>' +
      '<button class="pm-btn' + (window._purchaseMode === 'by-space' ? ' active' : '') + '" onclick="setPurchaseMode(\'by-space\')">按空间</button>' +
      '<span style="flex:1"></span>' +
      '<button onclick="exportPurchaseCsv()">导出 CSV</button>' +
    '</div>';
  container.innerHTML = warning + toolbar + renderPurchaseTable(data);
}

function setPurchaseMode(mode) {
  window._purchaseMode = mode;
  renderPurchaseView(window._workbench);
}

function renderPurchaseTable(data) {
  if (window._purchaseMode === 'by-space') return renderPurchaseBySpace(data);
  return renderPurchaseByMaterial(data);
}

function renderPurchaseByMaterial(data) {
  var usages = data.usages || [];
  var grouped = {};
  usages.forEach(function(u) {
    var key = u.material_name || '—';
    if (!grouped[key]) grouped[key] = {
      material_name: u.material_name, category: u.category || '',
      spec: u.spec || '', unit: u.unit || 'm2',
      net_area: 0, waste_rate: u.waste_rate || 0, purchase_qty: 0
    };
    grouped[key].net_area += u.net_area || 0;
    grouped[key].purchase_qty += u.purchase_qty || 0;
  });
  var rows = Object.values(grouped);
  var totalPurchase = rows.reduce(function(s, r) { return s + r.purchase_qty; }, 0) || 1;
  rows.sort(function(a, b) { return b.purchase_qty - a.purchase_qty; });

  if (rows.length === 0) {
    return '<p class="hint">暂无已映射材质</p>';
  }
  var html = '<table><thead><tr>' +
    '<th>材料</th><th>分类</th><th>规格</th><th>单位</th>' +
    '<th style="text-align:right">净面积</th><th style="text-align:right">损耗率</th>' +
    '<th style="text-align:right">采购量</th><th style="text-align:right">占比</th>' +
    '</tr></thead><tbody>';
  var totalNet = 0;
  rows.forEach(function(r) {
    totalNet += r.net_area;
    var pct = (r.purchase_qty / totalPurchase * 100).toFixed(0) + '%';
    html += '<tr>' +
      '<td>' + esc(r.material_name) + '</td>' +
      '<td>' + esc(r.category) + '</td>' +
      '<td>' + esc(r.spec || '-') + '</td>' +
      '<td>' + esc(r.unit) + '</td>' +
      '<td style="text-align:right">' + r.net_area.toFixed(2) + '</td>' +
      '<td style="text-align:right">' + (r.waste_rate * 100).toFixed(0) + '%</td>' +
      '<td style="text-align:right">' + r.purchase_qty.toFixed(2) + '</td>' +
      '<td style="text-align:right">' + pct + '</td>' +
      '</tr>';
  });
  html += '<tr style="font-weight:bold;background:#313244">' +
    '<td>合计</td><td></td><td></td><td></td>' +
    '<td style="text-align:right">' + totalNet.toFixed(2) + '</td>' +
    '<td></td>' +
    '<td style="text-align:right">' + totalPurchase.toFixed(2) + '</td>' +
    '<td></td>' +
    '</tr>';
  html += '</tbody></table>';
  return html;
}

function renderPurchaseBySpace(data) {
  var usages = data.usages || [];
  if (usages.length === 0) return '<p class="hint">暂无已映射材质</p>';
  var partLabels = { floor: '地面', wall: '墙面', ceiling: '天花' };
  var html = '<table><thead><tr>' +
    '<th>空间</th><th>部位</th><th>材料</th><th>分类</th><th>规格</th><th>单位</th>' +
    '<th style="text-align:right">净面积</th><th style="text-align:right">损耗率</th>' +
    '<th style="text-align:right">采购量</th>' +
    '</tr></thead><tbody>';
  usages.forEach(function(u) {
    html += '<tr>' +
      '<td>' + esc(u.space || '—') + '</td>' +
      '<td>' + esc(partLabels[u.part] || u.part || '—') + '</td>' +
      '<td>' + esc(u.material_name) + '</td>' +
      '<td>' + esc(u.category || '') + '</td>' +
      '<td>' + esc(u.spec || '-') + '</td>' +
      '<td>' + esc(u.unit || 'm2') + '</td>' +
      '<td style="text-align:right">' + (u.net_area || 0) + '</td>' +
      '<td style="text-align:right">' + ((u.waste_rate || 0) * 100).toFixed(0) + '%</td>' +
      '<td style="text-align:right">' + (u.purchase_qty || 0) + '</td>' +
      '</tr>';
  });
  html += '</tbody></table>';
  return html;
}

function exportPurchaseCsv() {
  var data = window._workbench;
  if (!data) return;
  var lines = [];
  if (window._purchaseMode === 'by-space') {
    lines.push(['空间', '部位', '材料', '分类', '规格', '单位', '净面积', '损耗率', '采购量'].join(','));
    (data.usages || []).forEach(function(u) {
      lines.push([
        u.space || '', u.part || '', u.material_name || '', u.category || '',
        u.spec || '', u.unit || 'm2', u.net_area || 0,
        ((u.waste_rate || 0) * 100).toFixed(0) + '%', u.purchase_qty || 0
      ].map(csvEscape).join(','));
    });
  } else {
    lines.push(['材料', '分类', '规格', '单位', '净面积', '损耗率', '采购量'].join(','));
    var grouped = {};
    (data.usages || []).forEach(function(u) {
      var key = u.material_name || '—';
      if (!grouped[key]) grouped[key] = {
        material_name: u.material_name, category: u.category || '',
        spec: u.spec || '', unit: u.unit || 'm2',
        net_area: 0, waste_rate: u.waste_rate || 0, purchase_qty: 0
      };
      grouped[key].net_area += u.net_area || 0;
      grouped[key].purchase_qty += u.purchase_qty || 0;
    });
    Object.values(grouped).forEach(function(r) {
      lines.push([
        r.material_name, r.category, r.spec || '', r.unit,
        r.net_area.toFixed(2), (r.waste_rate * 100).toFixed(0) + '%', r.purchase_qty.toFixed(2)
      ].map(csvEscape).join(','));
    });
  }
  var csv = '﻿' + lines.join('\n');  // BOM for Excel
  var blob = new Blob([csv], { type: 'text/csv;charset=utf-8' });
  var url = URL.createObjectURL(blob);
  var a = document.createElement('a');
  a.href = url;
  a.download = 'purchase_' + window._purchaseMode + '.csv';
  a.click();
  URL.revokeObjectURL(url);
}

function csvEscape(v) {
  var s = String(v == null ? '' : v);
  if (s.indexOf(',') >= 0 || s.indexOf('"') >= 0 || s.indexOf('\n') >= 0) {
    return '"' + s.replace(/"/g, '""') + '"';
  }
  return s;
}
```

- [ ] **Step 2: Commit**

```bash
git add src/ui/app.js
git commit -m "feat: implement purchase view with by-material/by-space and CSV export"
```

---

### Task 7: CSS — 新样式

**Files:**
- Modify: `src/ui/styles.css`

- [ ] **Step 1: 在 styles.css 末尾追加以下样式**

```css
/* ---------- Workbench ---------- */
.empty-state { padding: 80px 20px; text-align: center; color: #6c7086; font-size: 14px; }

.summary-bar {
  display: flex; gap: 20px; flex-wrap: wrap;
  background: #181825; border: 1px solid #45475a; border-radius: 6px;
  padding: 10px 14px; margin-bottom: 12px; font-size: 12px;
}
.summary-bar .sum-item { color: #cdd6f4; }
.summary-bar .sum-item::before { content: '· '; color: #6c7086; }
.summary-bar .sum-item:first-child::before { content: ''; }

.view-container { min-height: 200px; }

/* ---------- Material view filter bar ---------- */
.material-filter-bar {
  display: flex; gap: 6px; margin-bottom: 10px; align-items: center; flex-wrap: wrap;
}
.filter-btn {
  padding: 4px 12px; border: 1px solid #45475a; border-radius: 4px;
  background: transparent; color: #a6adc8; cursor: pointer; font-size: 12px;
}
.filter-btn.active { background: #89b4fa; color: #1e1e2e; border-color: #89b4fa; }
#material-search {
  flex: 1; min-width: 160px; padding: 5px 10px; border: 1px solid #45475a;
  border-radius: 4px; background: #313244; color: #cdd6f4; font-size: 12px;
}

#material-tbody input[type=text], #material-tbody input[type=number], #material-tbody select {
  width: 100%; padding: 4px 6px; border: 1px solid #45475a; border-radius: 3px;
  background: #1e1e2e; color: #cdd6f4; font-size: 12px;
}
#material-tbody td { vertical-align: middle; }
#material-tbody .u-name-row { display: flex; align-items: center; gap: 6px; }
#material-tbody .u-name {
  font-weight: 500; overflow: hidden; text-overflow: ellipsis;
  white-space: nowrap; max-width: 170px;
}
#material-tbody .swatch {
  display: inline-block; width: 16px; height: 16px; border-radius: 3px;
  border: 1px solid #45475a; flex-shrink: 0;
}
#material-tbody .swatch-empty {
  background: repeating-linear-gradient(45deg, #313244, #313244 3px, #1e1e2e 3px, #1e1e2e 6px);
  color: #6c7086; font-size: 10px; text-align: center; line-height: 16px;
}
#material-tbody .pill {
  display: inline-block; padding: 1px 6px; margin: 1px 2px 1px 0;
  border-radius: 8px; font-size: 10px; background: #313244; color: #cdd6f4;
}
#material-tbody .pill-floor { background: #313a4a; color: #89b4fa; }
#material-tbody .pill-wall { background: #3a3148; color: #cba6f7; }
#material-tbody .pill-ceiling { background: #2f3a31; color: #a6e3a1; }
#material-tbody button {
  padding: 4px 8px; border: 1px solid #45475a; border-radius: 3px;
  background: #313244; color: #cdd6f4; cursor: pointer;
}
#material-tbody button:hover { background: #89b4fa; color: #1e1e2e; }
#material-tbody tr.row-mapped td { opacity: 0.75; }
#material-tbody tr.row-ignored td { opacity: 0.5; }
#material-tbody tr.row-unresolved { background: rgba(243, 139, 168, 0.04); }

/* ---------- Purchase view ---------- */
.warning-bar {
  background: #3b1a1a; border: 1px solid #f38ba8; color: #f38ba8;
  padding: 8px 12px; border-radius: 4px; margin-bottom: 10px;
  display: flex; align-items: center; gap: 10px; font-size: 12px;
}
.warning-bar button {
  margin-left: auto; padding: 3px 10px; border: 1px solid #f38ba8;
  border-radius: 3px; background: transparent; color: #f38ba8;
  cursor: pointer; font-size: 11px;
}
.pm-btn {
  padding: 4px 12px; border: 1px solid #45475a; border-radius: 4px;
  background: transparent; color: #a6adc8; cursor: pointer;
}
.pm-btn.active { background: #89b4fa; color: #1e1e2e; border-color: #89b4fa; }
```

- [ ] **Step 2: Commit**

```bash
git add src/ui/styles.css
git commit -m "feat: add styles for workbench summary bar, material filter, purchase warning"
```

---

### Task 8: 验证

**Files:** 无

- [ ] **Step 1: 运行所有单元测试**

```bash
ruby -Itest test/test_data_models.rb
ruby -Itest test/test_mapping.rb
ruby -Itest test/test_process_library.rb
ruby -Itest test/test_calculator.rb
```

Expected: 所有测试通过（数据层没改，应该全绿）

- [ ] **Step 2: Ruby 语法检查**

```bash
ruby -c src/ui/dialog.rb
ruby -c src/main.rb
ruby -c src/scanner.rb
ruby -c src/marker.rb
```

Expected: `Syntax OK` × 4

- [ ] **Step 3: 让用户在 SketchUp 中手动验证**

告诉用户：
1. 在 SketchUp 中使用「重新加载插件」菜单，或重启 SU
2. 打开「材料统计」对话框，点击「扫描全部」
3. 应该看到：
   - 顶部「统计 / 映射 / 设置」标签栏不变
   - 扫描按钮常驻
   - 扫描后出现摘要条（面数/面积/材质数/已映射/待/已忽略/洞口）
   - 视图切换 `[按组件] [按材料] [采购量]`，默认在按组件
   - **按组件**：树形表格，同名实例分开，部位徽标，采购量列（未映射时显示 `—`）
   - **按材料**：筛选栏（全部/待映射/已映射/已忽略）+ 搜索框 + 就地编辑表格
   - **采购量**：未映射警告条 + 按材料/按空间切换 + 导出 CSV
4. 点摘要条里的"待 N"应该跳到材料视图且筛选到待映射
5. 在材料视图填写一个映射并点「保存映射」，应该：
   - 该行变成已映射状态
   - 摘要条的"已映射"数字 +1、"待 N"数字 -1
   - 切到按组件视图，对应组件行的采购量列出现数字
   - 切到采购量视图，看到这个材料的一行

- [ ] **Step 4: 提示用户报告问题**

告诉用户：如有任何渲染错位、按钮无响应、数据不对，截图或描述具体位置，便于定位修正。
