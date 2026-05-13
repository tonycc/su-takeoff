// src/ui/app.js

// ---------------- Tab switching ----------------
document.querySelectorAll('.tab-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
    document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
    btn.classList.add('active');
    document.getElementById('tab-' + btn.dataset.tab).classList.add('active');
    if (btn.dataset.tab === 'mapping') callSketchUp('get_mappings');
    if (btn.dataset.tab === 'settings') callSketchUp('get_processes');
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
window._workbench = null;             // latest data from Ruby
window._workbenchView = 'component';  // current view
window._materialFilter = 'all';       // all | unresolved | mapped | ignored
window._materialSearch = '';

// Entry point called by Ruby after scan or mapping change.
function renderWorkbench(data) {
  window._workbench = data;
  document.getElementById('empty-state').style.display = 'none';
  document.getElementById('workbench').style.display = 'block';
  renderSummaryBar(data);
  renderCurrentView();
  // Refresh mapping tab rich editor if rendered
  if (document.getElementById('mapping-edit-table')) {
    renderMappingEditTableBody();
  }
}

function switchWorkbenchView(view) {
  window._workbenchView = view;
  document.querySelectorAll('.view-btn').forEach(b => b.classList.remove('active'));
  document.querySelector('.view-btn[data-view="' + view + '"]').classList.add('active');
  ['component', 'material', 'purchase', 'zone'].forEach(function(v) {
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
  else if (view === 'zone') renderZoneView(window._workbench);
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

// ---------------- View renderers (stubs — replaced in subsequent tasks) ----------------
function renderComponentView(data) {
  var linearityByMaterial = buildLinearityByMaterial(data.materials_info || []);
  var tree = buildComponentTree(data.items || []);
  var purchaseBySu = buildPurchaseBySuMaterial(data.usages || []);
  aggregateComponentStats(tree, linearityByMaterial);
  var html = renderComponentTable(tree, purchaseBySu, linearityByMaterial);
  document.getElementById('view-component').innerHTML = html;
  document.querySelectorAll('#view-component .comp-row').forEach(function(row) {
    row.addEventListener('click', function() {
      var toggle = row.querySelector('.comp-toggle');
      if (toggle) toggleComponent(toggle.id.replace('-toggle', ''));
    });
  });
}

// Returns { material_name => 'linear' | 'area' } for materials with explicit mapping.
// Materials not in the map fall back to per-face aspect-ratio detection.
function buildLinearityByMaterial(infos) {
  var result = {};
  infos.forEach(function(info) {
    if (info.mapped_unit === 'm') result[info.su_name] = 'linear';
    else if (info.mapped_unit) result[info.su_name] = 'area';
  });
  return result;
}

function isFaceLinear(face, linearityByMaterial) {
  var matVerdict = face.su_material && linearityByMaterial[face.su_material];
  if (matVerdict === 'linear') return true;
  if (matVerdict === 'area') return false;
  var w = face.width || 0;
  var h = face.height || 0;
  return w > 0 && h > 0 && (h / w) > 15;
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
  return root;
}

function aggregateComponentStats(node, linearityByMaterial) {
  linearityByMaterial = linearityByMaterial || {};
  var stats = {
    face_count: 0, total_area: 0.0,
    by_part: { floor: 0.0, wall: 0.0, ceiling: 0.0 },
    material_names: {}, material_count: 0,
    linear_length: 0.0, linear_face_count: 0
  };
  node.children.forEach(function(child) {
    var cs = aggregateComponentStats(child, linearityByMaterial);
    stats.face_count += cs.face_count;
    stats.total_area += cs.total_area;
    stats.by_part.floor += cs.by_part.floor;
    stats.by_part.wall += cs.by_part.wall;
    stats.by_part.ceiling += cs.by_part.ceiling;
    stats.linear_length += cs.linear_length;
    stats.linear_face_count += cs.linear_face_count;
    Object.keys(cs.material_names).forEach(function(m) { stats.material_names[m] = true; });
  });
  node.faces.forEach(function(face) {
    stats.face_count += 1;
    if (face.su_material) stats.material_names[face.su_material] = true;
    if (isFaceLinear(face, linearityByMaterial)) {
      stats.linear_length += (face.height || 0);
      stats.linear_face_count += 1;
    } else {
      stats.total_area += face.qty || 0;
      if (face.part) stats.by_part[face.part] = (stats.by_part[face.part] || 0) + (face.qty || 0);
    }
  });
  stats.material_count = Object.keys(stats.material_names).length;
  stats.total_area = +stats.total_area.toFixed(2);
  stats.by_part.floor = +stats.by_part.floor.toFixed(2);
  stats.by_part.wall = +stats.by_part.wall.toFixed(2);
  stats.by_part.ceiling = +stats.by_part.ceiling.toFixed(2);
  stats.linear_length = +stats.linear_length.toFixed(2);
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

function renderComponentTable(tree, purchaseBySu, linearityByMaterial) {
  if (tree.faces.length > 0) {
    var orphan = {
      name: '模型根层级', path: [], path_ids: [], faces: tree.faces,
      children: [], childrenMap: {}
    };
    aggregateComponentStats(orphan, linearityByMaterial);
    tree.children.unshift(orphan);
    tree.faces = [];
  }
  var html = '<table><thead><tr>' +
    '<th style="width:40px">#</th>' +
    '<th>组件 / 面</th>' +
    '<th style="text-align:right">面数</th>' +
    '<th style="text-align:right">面积(m²)</th>' +
    '<th style="text-align:right">长度(m)</th>' +
    '<th style="text-align:right">地面</th>' +
    '<th style="text-align:right">墙面</th>' +
    '<th style="text-align:right">天花</th>' +
    '<th style="text-align:right">材质数</th>' +
    '<th>材质</th>' +
    '<th style="text-align:right">采购量</th>' +
    '</tr></thead><tbody>';
  var rootId = 'comp-root';
  var counter = { n: 0 };
  tree.children.forEach(function(child) {
    html += renderComponentNode(child, 1, rootId, purchaseBySu, counter, linearityByMaterial);
  });
  html += '</tbody></table>';
  return html;
}

function renderComponentNode(node, depth, parentId, purchaseBySu, counter, linearityByMaterial) {
  var html = '';
  var idKey = (node.path_ids || []).join('-') || 'noid-' + node.path.join('-');
  var nodeId = 'comp-' + idKey.replace(/[^a-zA-Z0-9\-]/g, '_');
  var indent = depth * 18;
  var hasChildren = node.children.length > 0 || node.faces.length > 0;
  var hidden = depth > 1 ? ' style="display:none"' : '';
  var partBadge = dominantPartBadge(node.stats);

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

  counter.n += 1;
  html += '<tr class="comp-row" data-depth="' + depth + '" data-parent="' + parentId + '"' + hidden + '>' +
    '<td style="text-align:right; color:#6c7086; font-size:11px;">' + counter.n + '</td>' +
    '<td style="padding-left:' + (indent + 6) + 'px">';
  if (hasChildren) {
    html += '<span class="comp-toggle" id="' + nodeId + '-toggle">' + (depth === 1 ? '▾' : '▸') + '</span> ';
  } else {
    html += '<span class="comp-toggle-empty"></span> ';
  }
  var areaCell = node.stats.total_area > 0 ? node.stats.total_area : '—';
  var lengthCell = node.stats.linear_length > 0 ? node.stats.linear_length : '—';
  html += esc(node.name) + partBadge + '</td>' +
    '<td style="text-align:right">' + node.stats.face_count + '</td>' +
    '<td style="text-align:right">' + areaCell + '</td>' +
    '<td style="text-align:right">' + lengthCell + '</td>' +
    '<td style="text-align:right">' + (node.stats.by_part.floor > 0 ? node.stats.by_part.floor : '—') + '</td>' +
    '<td style="text-align:right">' + (node.stats.by_part.wall > 0 ? node.stats.by_part.wall : '—') + '</td>' +
    '<td style="text-align:right">' + (node.stats.by_part.ceiling > 0 ? node.stats.by_part.ceiling : '—') + '</td>' +
    '<td style="text-align:right">' + node.stats.material_count + '</td>' +
    '<td style="font-size:11px">' + esc(mats.join(', ') || '—') + '</td>' +
    '<td style="text-align:right">' + purchaseCell + '</td>' +
    '</tr>';

  node.children.forEach(function(child) {
    html += renderComponentNode(child, depth + 1, nodeId, purchaseBySu, counter, linearityByMaterial);
  });
  node.faces.forEach(function(face) {
    counter.n += 1;
    html += renderFaceRow(face, depth + 1, nodeId, purchaseBySu, counter.n, linearityByMaterial);
  });
  return html;
}

function renderFaceRow(face, depth, parentId, purchaseBySu, serial, linearityByMaterial) {
  var indent = depth * 18;
  var mapped = face.su_material && purchaseBySu[face.su_material] != null;
  var statusIcon = !face.su_material ? '' :
    (mapped ? '<span style="color:#a6e3a1">✓</span> ' : '<span style="color:#f38ba8">●</span> ');
  var qty = +(face.qty || 0).toFixed(2);
  var h = face.height || 0;
  var isLinear = isFaceLinear(face, linearityByMaterial || {});
  var areaCell = isLinear ? '—' : qty;
  var lengthCell = isLinear ? (+h.toFixed(2)) : '—';
  var floorCell = (!isLinear && face.part === 'floor') ? qty : '—';
  var wallCell = (!isLinear && face.part === 'wall') ? qty : '—';
  var ceilingCell = (!isLinear && face.part === 'ceiling') ? qty : '—';
  return '<tr class="face-row" data-depth="' + depth + '" data-parent="' + parentId + '" style="display:none">' +
    '<td style="text-align:right; font-size:10px; color:#6c7086;">' + (serial || '') + '</td>' +
    '<td style="padding-left:' + (indent + 6) + 'px; font-size:10px; color:#6c7086;">' + statusIcon + '面 #' + esc(face.face_id) + '</td>' +
    '<td></td>' +
    '<td style="text-align:right">' + areaCell + '</td>' +
    '<td style="text-align:right">' + lengthCell + '</td>' +
    '<td style="text-align:right">' + floorCell + '</td>' +
    '<td style="text-align:right">' + wallCell + '</td>' +
    '<td style="text-align:right">' + ceilingCell + '</td>' +
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
      '<th style="width:40px">#</th>' +
      '<th style="width:4%">状态</th>' +
      '<th style="width:18%">SU材质</th>' +
      '<th style="width:12%">面数/面积</th>' +
      '<th style="width:14%">部位分布</th>' +
      '<th>真实材料名</th>' +
      '<th>分类</th>' +
      '<th>规格</th>' +
      '<th style="width:6%">单位</th>' +
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
  var serial = 0;
  (data.materials_info || []).forEach(function(info) {
    var name = info.su_name;
    var isIgnored = !!ignoredSet[name];
    var isUnresolved = !!unresolvedSet[name];
    var isMapped = !isIgnored && !isUnresolved;

    if (filter === 'unresolved' && !isUnresolved) return;
    if (filter === 'mapped' && !isMapped) return;
    if (filter === 'ignored' && !isIgnored) return;
    if (q && name.toLowerCase().indexOf(q) === -1) return;

    serial += 1;

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

    var suggested = info.suggested_unit || 'm²';
    var unitOptions = ['m²', 'm', '个'].map(function(u) {
      var sel = u === suggested ? ' selected' : '';
      return '<option value="' + u + '"' + sel + '>' + u + '</option>';
    }).join('');

    var quantitySummary = suggested === 'm'
      ? (info.face_count || 0) + ' 面 / ' + (info.total_length || 0) + ' m'
      : (info.face_count || 0) + ' 面 / ' + (info.total_area || 0) + ' m²';

    var tr = document.createElement('tr');
    tr.className = 'row-' + (isMapped ? 'mapped' : (isIgnored ? 'ignored' : 'unresolved'));
    tr.innerHTML =
      '<td style="text-align:right; color:#6c7086; font-size:11px;">' + serial + '</td>' +
      '<td>' + status + '</td>' +
      '<td><div class="u-name-row">' + swatch +
        '<span class="u-name" title="' + esc(name) + '">' + esc(name) + '</span>' +
      '</div><input type="hidden" class="u-su" value="' + esc(name) + '"></td>' +
      '<td>' + quantitySummary + '</td>' +
      '<td>' + partsHtml + '</td>' +
      '<td><input type="text" class="u-mat" placeholder="留空跳过"' + dis + '></td>' +
      '<td><select class="u-cat"' + dis + '>' + catOptions + '</select></td>' +
      '<td><input type="text" class="u-spec" placeholder="可选"' + dis + '></td>' +
      '<td><select class="u-unit"' + dis + '>' + unitOptions + '</select></td>' +
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
      unit: tr.querySelector('.u-unit').value,
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
window._purchaseMode = 'by-material';

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
    var key = (u.material_name || '—') + '|' + (u.unit || 'm2');
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
    '<th style="width:40px">#</th>' +
    '<th>材料</th><th>分类</th><th>规格</th><th>单位</th>' +
    '<th style="text-align:right">净面积</th><th style="text-align:right">损耗率</th>' +
    '<th style="text-align:right">采购量</th><th style="text-align:right">占比</th>' +
    '</tr></thead><tbody>';
  var totalNet = 0;
  rows.forEach(function(r, i) {
    totalNet += r.net_area;
    var pct = (r.purchase_qty / totalPurchase * 100).toFixed(0) + '%';
    html += '<tr>' +
      '<td style="text-align:right; color:#6c7086; font-size:11px;">' + (i + 1) + '</td>' +
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
    '<td></td>' +
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
    '<th style="width:40px">#</th>' +
    '<th>空间</th><th>部位</th><th>材料</th><th>分类</th><th>规格</th><th>单位</th>' +
    '<th style="text-align:right">净面积</th><th style="text-align:right">损耗率</th>' +
    '<th style="text-align:right">采购量</th>' +
    '</tr></thead><tbody>';
  usages.forEach(function(u, i) {
    html += '<tr>' +
      '<td style="text-align:right; color:#6c7086; font-size:11px;">' + (i + 1) + '</td>' +
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
  var csv = '﻿' + lines.join('\n');
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

// ---------------- Material categorization helpers ----------------
var DEFAULT_CATEGORIES = ['瓷砖', '石材', '涂料', '木材', '墙纸', '玻璃', '金属', '其他'];

function guessCategory(name) {
  var n = (name || '').toLowerCase();
  if (/tile|瓷砖|砖/.test(n)) return '瓷砖';
  if (/marble|stone|石|大理石/.test(n)) return '石材';
  if (/paint|漆|涂|乳胶/.test(n)) return '涂料';
  if (/wood|木/.test(n)) return '木材';
  if (/wallpaper|墙纸|壁纸/.test(n)) return '墙纸';
  if (/glass|玻璃/.test(n)) return '玻璃';
  if (/steel|metal|金属|铁|钢|铝/.test(n)) return '金属';
  if (/石膏板|龙骨|找平/.test(n)) return '其他';
  return '其他';
}

function locateMaterial(suName) {
  callSketchUp('locate_material', suName);
}

// ---------------- Mapping management tab ----------------
function renderMappings(mappings) {
  if (window._workbench) {
    renderMappingWithContext();
  } else {
    renderSimpleMappingTable(mappings);
  }
}

function filterSimpleMappings() {
  var q = document.getElementById('search-mapping').value.toLowerCase();
  document.querySelectorAll('#mapping-body tr').forEach(function(tr) {
    tr.style.display = tr.textContent.toLowerCase().includes(q) ? '' : 'none';
  });
}

function deleteMapping(suName) {
  if (!confirm('删除映射：' + suName + '？')) return;
  callSketchUp('delete_mapping', suName);
}

function importCsv() { callSketchUp('import_csv'); }
function exportCsv() { callSketchUp('export_csv'); }

function openAddMapping() {
  var suName = prompt('SU材质名:');
  if (!suName) return;
  var matName = prompt('真实材料名:');
  if (!matName) return;
  var cat = prompt('分类 (瓷砖/石材/涂料/木材/墙纸/玻璃/金属/其他):') || '其他';
  var spec = prompt('规格 (可选):') || '';
  var waste = parseFloat(prompt('默认损耗率 (如0.05):') || '0.05');
  callSketchUp('save_mapping', JSON.stringify({
    su_name: suName, material_name: matName, category: cat,
    unit: 'm²', spec: spec, waste_rate: waste
  }));
}

function renderProcesses(processData) {
  window._processData = processData;
}

// ---------------- Manual marking ----------------
function manualMark() {
  document.getElementById('marking-dialog').style.display = 'flex';
}

function closeMarkDialog() {
  document.getElementById('marking-dialog').style.display = 'none';
}

function confirmMark() {
  var data = {
    material_name: document.getElementById('mark-material').value,
    part: document.getElementById('mark-part').value,
    space: document.getElementById('mark-space').value,
    waste_rate: parseFloat(document.getElementById('mark-waste').value) || 0.05
  };
  callSketchUp('apply_marking', JSON.stringify(data));
  closeMarkDialog();
}

// ---------------- Settings ----------------
function snapshotToModel() { callSketchUp('snapshot_to_model'); }
function loadFromModel() { callSketchUp('load_from_model'); }

// ---------------- Helpers ----------------
function esc(s) {
  if (s === null || s === undefined) return '';
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
                  .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function escAttr(s) { return esc(s).replace(/'/g, "\\'"); }

// ---------------- Zone view ----------------
function renderZoneView(data) {
  var usages = data.usages || [];
  var container = document.getElementById('view-zone');
  if (!container) return;

  if (usages.length === 0) {
    container.innerHTML = '<p class="hint">暂无已映射材质</p>';
    return;
  }

  var partLabels = { floor: '地面', wall: '墙面', ceiling: '天花' };
  var partOrder = ['floor', 'wall', 'ceiling'];

  // Group by space, then by part. Preserve insertion order.
  var spaceMap = {};
  var spaceOrder = [];
  usages.forEach(function(u) {
    var space = u.space || '未分组';
    if (!spaceMap[space]) {
      spaceMap[space] = {};
      spaceOrder.push(space);
    }
    var part = u.part || 'wall';
    if (!spaceMap[space][part]) spaceMap[space][part] = [];
    spaceMap[space][part].push(u);
  });

  // Build flat row list: subtotal + detail rows per space
  var rows = [];
  spaceOrder.forEach(function(space) {
    var spaceNet = 0, spacePurchase = 0;
    var detailRows = [];

    partOrder.forEach(function(part) {
      var items = spaceMap[space][part];
      if (!items || items.length === 0) return;

      items.forEach(function(u) {
        spaceNet += u.net_area || 0;
        spacePurchase += u.purchase_qty || 0;
        detailRows.push({
          type: 'detail',
          space: space,
          part: part,
          material_name: u.material_name || '',
          category: u.category || '',
          spec: u.spec || '',
          unit: u.unit || 'm2',
          net_area: u.net_area || 0,
          waste_rate: u.waste_rate || 0,
          purchase_qty: u.purchase_qty || 0
        });
      });
    });

    if (detailRows.length > 0) {
      rows.push({
        type: 'subtotal',
        space: space,
        net_area: +spaceNet.toFixed(2),
        purchase_qty: +spacePurchase.toFixed(2)
      });
      rows = rows.concat(detailRows);
    }
  });

  // Compute grand totals
  var totalNet = 0, totalPurchase = 0;
  rows.forEach(function(r) {
    if (r.type === 'detail') {
      totalNet += r.net_area;
      totalPurchase += r.purchase_qty;
    }
  });

  // Render table
  var html = '<table><thead><tr>' +
    '<th style="width:40px">#</th>' +
    '<th>功能区域</th>' +
    '<th>区域分项</th>' +
    '<th>材料</th>' +
    '<th>分类</th>' +
    '<th>规格</th>' +
    '<th>单位</th>' +
    '<th style="text-align:right">净面积</th>' +
    '<th style="text-align:right">损耗率</th>' +
    '<th style="text-align:right">采购量</th>' +
    '</tr></thead><tbody>';

  var serial = 0;
  var lastShownSpace = null;

  rows.forEach(function(row) {
    if (row.type === 'subtotal') {
      html += '<tr class="zone-subtotal-row">' +
        '<td></td>' +
        '<td colspan="9"><strong>' + esc(row.space) + '</strong> 小计 — ' +
        '净面积 ' + row.net_area.toFixed(2) + ' / 采购量 ' + row.purchase_qty.toFixed(2) + '</td>' +
        '</tr>';
    } else {
      serial++;
      var showSpace = (row.space !== lastShownSpace);
      if (showSpace) lastShownSpace = row.space;

      html += '<tr>' +
        '<td style="text-align:right; color:#6c7086; font-size:11px;">' + serial + '</td>' +
        '<td>' + (showSpace ? esc(row.space) : '') + '</td>' +
        '<td><span class="pill pill-' + row.part + '">' + (partLabels[row.part] || row.part) + '</span></td>' +
        '<td>' + esc(row.material_name) + '</td>' +
        '<td>' + esc(row.category) + '</td>' +
        '<td>' + esc(row.spec || '-') + '</td>' +
        '<td>' + esc(row.unit) + '</td>' +
        '<td style="text-align:right">' + row.net_area.toFixed(2) + '</td>' +
        '<td style="text-align:right">' + (row.waste_rate * 100).toFixed(0) + '%</td>' +
        '<td style="text-align:right">' + row.purchase_qty.toFixed(2) + '</td>' +
        '</tr>';
    }
  });

  // Grand total
  html += '<tr class="zone-total-row">' +
    '<td></td>' +
    '<td colspan="9"><strong>合计</strong> — ' +
    '净面积 ' + totalNet.toFixed(2) + ' / 采购量 ' + totalPurchase.toFixed(2) + '</td>' +
    '</tr>';

  html += '</tbody></table>';
  container.innerHTML = html;
}

// ---------------- Mapping tab: simple read-only table (pre-scan) ----------------
function renderSimpleMappingTable(mappings) {
  var container = document.getElementById('mapping-content');
  if (!container) return;

  var html = '<div class="toolbar">' +
    '<input type="text" id="search-mapping" placeholder="搜索SU材质..." oninput="filterSimpleMappings()">' +
    '<button onclick="importCsv()">导入CSV</button>' +
    '<button onclick="exportCsv()">导出CSV</button>' +
    '<button onclick="openAddMapping()">+ 新增</button>' +
    '</div>' +
    '<table id="mapping-table"><thead><tr>' +
      '<th>SU材质名</th>' +
      '<th>真实材料名</th>' +
      '<th>分类</th>' +
      '<th>单位</th>' +
      '<th>规格</th>' +
      '<th>默认损耗率</th>' +
      '<th>工艺</th>' +
      '<th>操作</th>' +
    '</tr></thead><tbody id="mapping-body"></tbody></table>';

  container.innerHTML = html;

  var tbody = document.getElementById('mapping-body');
  mappings.forEach(function(m) {
    var wastePct = (m.default_waste_rate * 100).toFixed(0);
    var tr = document.createElement('tr');
    tr.innerHTML =
      '<td>' + esc(m.su_material_name) + '</td>' +
      '<td>' + esc(m.material_name) + '</td>' +
      '<td>' + esc(m.category) + '</td>' +
      '<td>' + esc(m.unit) + '</td>' +
      '<td>' + (m.spec ? esc(m.spec) : '-') + '</td>' +
      '<td>' + wastePct + '%</td>' +
      '<td>-</td>' +
      '<td><button onclick="deleteMapping(\'' + escAttr(m.su_material_name) + '\')">删除</button></td>';
    tbody.appendChild(tr);
  });
}

// ---------------- Mapping tab rich editor (post-scan) ----------------
function renderMappingWithContext() {
  var data = window._workbench;
  if (!data) return;
  var container = document.getElementById('mapping-content');
  if (!container) return;

  var counts = computeMaterialCounts(data);

  var html = '<div class="material-filter-bar">' +
    filterButton('all', '全部', counts.all) +
    filterButton('unresolved', '待映射', counts.unresolved) +
    filterButton('mapped', '已映射', counts.mapped) +
    filterButton('ignored', '已忽略', counts.ignored) +
    '<input type="text" id="mapping-search" placeholder="搜索..." ' +
      'value="' + esc(window._mappingSearch || '') + '" ' +
      'oninput="onMappingSearch(this.value)">' +
    '</div>' +
    '<table id="mapping-edit-table"><thead><tr>' +
      '<th style="width:40px">#</th>' +
      '<th style="width:4%">状态</th>' +
      '<th style="width:18%">SU材质</th>' +
      '<th style="width:12%">面数/面积</th>' +
      '<th style="width:14%">部位分布</th>' +
      '<th>真实材料名</th>' +
      '<th>分类</th>' +
      '<th>规格</th>' +
      '<th style="width:6%">单位</th>' +
      '<th>损耗率</th>' +
      '<th style="width:5%">忽略</th>' +
      '<th style="width:5%">定位</th>' +
    '</tr></thead><tbody id="mapping-edit-tbody"></tbody></table>' +
    '<div class="toolbar" style="margin-top:12px">' +
      '<button onclick="fillDefaultMappingTabNames()">一键填默认</button>' +
      '<button onclick="saveMappingTabMappings()" class="primary-btn">保存映射</button>' +
      '<button onclick="ignoreAllMappingTabUnresolved()">全部忽略</button>' +
    '</div>';
  container.innerHTML = html;
  renderMappingEditTableBody();
}

function renderMappingEditTableBody() {
  var data = window._workbench;
  var tbody = document.getElementById('mapping-edit-tbody');
  if (!tbody) return;

  var unresolvedSet = {}; (data.unresolved || []).forEach(function(n) { unresolvedSet[n] = true; });
  var ignoredSet = {}; (data.ignored || []).forEach(function(n) { ignoredSet[n] = true; });
  var filter = window._mappingFilter || 'all';
  var q = (window._mappingSearch || '').toLowerCase();
  var partLabels = { floor: '地', wall: '墙', ceiling: '顶' };

  tbody.innerHTML = '';
  var serial = 0;
  (data.materials_info || []).forEach(function(info) {
    var name = info.su_name;
    var isIgnored = !!ignoredSet[name];
    var isUnresolved = !!unresolvedSet[name];
    var isMapped = !isIgnored && !isUnresolved;

    if (filter === 'unresolved' && !isUnresolved) return;
    if (filter === 'mapped' && !isMapped) return;
    if (filter === 'ignored' && !isIgnored) return;
    if (q && name.toLowerCase().indexOf(q) === -1) return;

    serial += 1;

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
    var cats = (data.categories && data.categories.length)
      ? data.categories : DEFAULT_CATEGORIES;
    var catOptions = cats.map(function(cat) {
      var sel = cat === (info.category || guessCategory(name)) ? ' selected' : '';
      return '<option value="' + esc(cat) + '"' + sel + '>' + esc(cat) + '</option>';
    }).join('');

    var suggested = info.suggested_unit || 'm²';
    var unitOptions = ['m²', 'm', '个'].map(function(u) {
      var sel = u === (info.mapped_unit || suggested) ? ' selected' : '';
      return '<option value="' + u + '"' + sel + '>' + u + '</option>';
    }).join('');

    var wasteVal = info.waste_rate != null ? info.waste_rate : 0.05;
    var matVal = info.material_name || '';

    var quantitySummary = suggested === 'm'
      ? (info.face_count || 0) + ' 面 / ' + (info.total_length || 0) + ' m'
      : (info.face_count || 0) + ' 面 / ' + (info.total_area || 0) + ' m²';

    var tr = document.createElement('tr');
    tr.className = 'row-' + (isMapped ? 'mapped' : (isIgnored ? 'ignored' : 'unresolved'));
    tr.innerHTML =
      '<td style="text-align:right; color:#6c7086; font-size:11px;">' + serial + '</td>' +
      '<td>' + status + '</td>' +
      '<td><div class="u-name-row">' + swatch +
        '<span class="u-name" title="' + esc(name) + '">' + esc(name) + '</span>' +
      '</div><input type="hidden" class="u-su" value="' + esc(name) + '"></td>' +
      '<td>' + quantitySummary + '</td>' +
      '<td>' + partsHtml + '</td>' +
      '<td><input type="text" class="u-mat" value="' + esc(matVal) + '" placeholder="留空跳过"' + dis + '></td>' +
      '<td><select class="u-cat"' + dis + '>' + catOptions + '</select></td>' +
      '<td><input type="text" class="u-spec" value="' + esc(info.spec || '') + '" placeholder="可选"' + dis + '></td>' +
      '<td><select class="u-unit"' + dis + '>' + unitOptions + '</select></td>' +
      '<td><input type="number" class="u-waste" step="0.01" value="' + wasteVal + '" style="width:60px"' + dis + '></td>' +
      '<td><input type="checkbox" class="u-ignore"' + (isIgnored ? ' checked' : '') +
         ' onchange="toggleMappingTabIgnore(\'' + escAttr(name) + '\', this.checked)"></td>' +
      '<td><button onclick="locateMaterial(\'' + escAttr(name) + '\')">🎯</button></td>';
    tbody.appendChild(tr);
  });
}

// ---------------- Mapping tab action handlers ----------------
window._mappingFilter = 'all';
window._mappingSearch = '';

function setMappingFilter(key) {
  window._mappingFilter = key;
  renderMappingEditTableBody();
}

function onMappingSearch(value) {
  window._mappingSearch = value;
  renderMappingEditTableBody();
}

function fillDefaultMappingTabNames() {
  document.querySelectorAll('#mapping-edit-tbody tr.row-unresolved').forEach(function(tr) {
    var mat = tr.querySelector('.u-mat');
    if (mat && !mat.value) mat.value = tr.querySelector('.u-su').value;
  });
}

function saveMappingTabMappings() {
  var rows = [];
  document.querySelectorAll('#mapping-edit-tbody tr.row-unresolved').forEach(function(tr) {
    if (tr.querySelector('.u-ignore').checked) return;
    var mat = tr.querySelector('.u-mat').value.trim();
    if (!mat) return;
    rows.push({
      su_name: tr.querySelector('.u-su').value,
      material_name: mat,
      category: tr.querySelector('.u-cat').value,
      spec: tr.querySelector('.u-spec').value,
      unit: tr.querySelector('.u-unit').value,
      waste_rate: parseFloat(tr.querySelector('.u-waste').value) || 0.05
    });
  });
  if (rows.length === 0) {
    alert('没有可保存的映射 — 请先填写"真实材料名"');
    return;
  }
  callSketchUp('save_mappings_batch', JSON.stringify(rows));
}

function ignoreAllMappingTabUnresolved() {
  var names = [];
  document.querySelectorAll('#mapping-edit-tbody tr.row-unresolved').forEach(function(tr) {
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

function toggleMappingTabIgnore(name, on) {
  var current = (window._workbench && window._workbench.ignored) || [];
  var set = {};
  current.forEach(function(n) { set[n] = true; });
  if (on) set[name] = true; else delete set[name];
  callSketchUp('set_ignored', JSON.stringify(Object.keys(set)));
}
