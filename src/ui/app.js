// src/ui/app.js

// ---------------- Tab switching ----------------
document.querySelectorAll('.tab-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
    document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
    btn.classList.add('active');
    document.getElementById('tab-' + btn.dataset.tab).classList.add('active');
  });
});

function switchView(view) {
  document.querySelectorAll('.view-btn').forEach(b => b.classList.remove('active'));
  document.querySelector('.view-btn[data-view="' + view + '"]').classList.add('active');
  if (window._lastStats) renderResults(window._lastStats, view);
}

// ---------------- Phase switching ----------------
function showPhase(phase) {
  document.getElementById('phase-scan').style.display = phase === 'scan' ? 'block' : 'none';
  document.getElementById('phase-mapping').style.display = phase === 'mapping' ? 'block' : 'none';
  document.getElementById('phase-stats').style.display = phase === 'stats' ? 'block' : 'none';
}

function goToMapping() { showPhase('mapping'); }
function goToScan() { showPhase('scan'); }

// ---------------- Bridge ----------------
function callSketchUp(action, json) {
  if (typeof sketchup !== 'undefined') {
    sketchup[action](json || '');
  } else {
    console.warn('Not running in SketchUp HtmlDialog');
  }
}

// ---------------- Phase 1: Scan ----------------
function scanAll() { callSketchUp('scan_all'); }
function scanSelected() { callSketchUp('scan_selected'); }

// Called by Ruby after scan (and after mapping/ignore changes)
// data = { phase, overview, items, openings, ignored, unresolved, materials_info, categories }
function renderReview(data) {
  window._reviewState = data;
  if (data.categories) window._categories = data.categories;

  // Show scan results, hide scan buttons
  document.getElementById('scan-controls').style.display = 'none';
  document.getElementById('scan-results').style.display = 'block';

  // Overview
  var ov = data.overview || {};
  var ovHtml = '<div class="ov-grid">' +
    '<div class="ov-item"><div class="ov-label">总面数</div><div class="ov-value">' + (ov.total_faces || 0) + '</div></div>' +
    '<div class="ov-item"><div class="ov-label">总面积</div><div class="ov-value">' + (ov.total_area || 0) + ' m²</div></div>' +
    '<div class="ov-item"><div class="ov-label">材质种类</div><div class="ov-value">' + (ov.material_count || 0) + '</div></div>' +
    '<div class="ov-item"><div class="ov-label">已映射</div><div class="ov-value">' + (ov.mapped || 0) + '</div></div>' +
    '<div class="ov-item"><div class="ov-label">已忽略</div><div class="ov-value">' + (ov.ignored_count || 0) + '</div></div>' +
    '<div class="ov-item"><div class="ov-label">待处理</div><div class="ov-value" style="color:' + ((ov.unresolved_count || 0) > 0 ? '#f38ba8' : '#a6e3a1') + '">' + (ov.unresolved_count || 0) + '</div></div>' +
    '<div class="ov-item"><div class="ov-label">洞口数</div><div class="ov-value">' + (ov.total_openings || 0) + '</div></div>' +
    '<div class="ov-item"><div class="ov-label">洞口面积</div><div class="ov-value">' + (ov.total_opening_area || 0) + ' m²</div></div>' +
    '</div>';
  document.getElementById('scan-overview').innerHTML = ovHtml;

  // Group items by container path IDs (distinguishes same-named instances)
  var groups = {};
  (data.items || []).forEach(function(it) {
    var ids = it.component_path_ids || [];
    var key = ids.join('/') || '_root';
    if (!groups[key]) groups[key] = { path: it.component_path || [], path_ids: ids, items: [] };
    groups[key].items.push(it);
  });

  // Sort groups: root first, then alphabetically by name path
  var groupKeys = Object.keys(groups).sort(function(a, b) {
    if (a === '_root') return -1;
    if (b === '_root') return 1;
    return groups[a].path.join('/').localeCompare(groups[b].path.join('/'));
  });

  var partLabels = { floor: '地面', wall: '墙面', ceiling: '天花' };
  var kindLabels = { face: '面', edge: '边', instance: '实例' };

  // ---- Container summary table ----
  var ctbody = document.getElementById('container-body');
  ctbody.innerHTML = '';
  groupKeys.forEach(function(key) {
    var g = groups[key];
    var displayName = g.path.length > 0 ? g.path[g.path.length - 1] : '模型根层级';
    var pathStr = g.path.join(' / ') || '—';
    var totalArea = 0;
    var parts = { floor: 0, wall: 0, ceiling: 0 };
    var matSet = {};
    g.items.forEach(function(it) {
      totalArea += it.qty || 0;
      if (it.part) parts[it.part] = (parts[it.part] || 0) + (it.qty || 0);
      if (it.su_material) matSet[it.su_material] = true;
    });
    var matNames = Object.keys(matSet).join(', ') || '—';
    var tr = document.createElement('tr');
    tr.innerHTML =
      '<td>' + esc(displayName) + '</td>' +
      '<td style="font-size:11px;max-width:160px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">' + esc(pathStr) + '</td>' +
      '<td>' + g.items.length + '</td>' +
      '<td>' + totalArea.toFixed(2) + '</td>' +
      '<td>' + (parts.floor > 0 ? parts.floor.toFixed(2) : '—') + '</td>' +
      '<td>' + (parts.wall > 0 ? parts.wall.toFixed(2) : '—') + '</td>' +
      '<td>' + (parts.ceiling > 0 ? parts.ceiling.toFixed(2) : '—') + '</td>' +
      '<td>' + Object.keys(matSet).length + '</td>' +
      '<td style="font-size:11px">' + esc(matNames) + '</td>';
    ctbody.appendChild(tr);
  });

  // ---- Collapsible detail tree ----
  var container = document.getElementById('scan-tree-container');
  container.innerHTML = '';

  groupKeys.forEach(function(key) {
    var g = groups[key];
    var displayName = g.path.length > 0 ? g.path[g.path.length - 1] : '模型根层级';

    // Compute group stats
    var totalArea = 0;
    var parts = { floor: 0, wall: 0, ceiling: 0 };
    var matSet = {};
    g.items.forEach(function(it) {
      totalArea += it.qty || 0;
      if (it.part) parts[it.part] = (parts[it.part] || 0) + (it.qty || 0);
      if (it.su_material) matSet[it.su_material] = true;
    });
    var matCount = Object.keys(matSet).length;

    var statsHtml = '<span>' + g.items.length + '面</span>' +
      '<span>' + totalArea.toFixed(2) + 'm²</span>' +
      (parts.floor > 0 ? '<span class="pill pill-floor">地 ' + parts.floor.toFixed(2) + '</span>' : '') +
      (parts.wall > 0 ? '<span class="pill pill-wall">墙 ' + parts.wall.toFixed(2) + '</span>' : '') +
      (parts.ceiling > 0 ? '<span class="pill pill-ceiling">顶 ' + parts.ceiling.toFixed(2) + '</span>' : '') +
      '<span>' + matCount + '种材质</span>';

    var nodeId = 'group-' + key.replace(/[^a-zA-Z0-9]/g, '_');

    var node = document.createElement('div');
    node.className = 'group-node';
    node.innerHTML =
      '<div class="group-header" onclick="toggleGroup(\'' + nodeId + '\')">' +
        '<span class="group-toggle" id="' + nodeId + '-toggle">+</span>' +
        '<span class="group-name">' + esc(displayName) + '</span>' +
        '<div class="group-stats">' + statsHtml + '</div>' +
      '</div>' +
      '<div class="group-detail" id="' + nodeId + '-detail">' +
        '<table><thead><tr>' +
          '<th>ID</th><th>SU材质</th><th>数量</th><th>单位</th><th>类型</th><th>部位</th><th>法向量</th><th>宽(m)</th><th>高(m)</th><th>图层</th><th>Z中心(m)</th>' +
        '</tr></thead><tbody id="' + nodeId + '-tbody"></tbody></table>' +
      '</div>';
    container.appendChild(node);

    // Fill face rows
    var tbody = document.getElementById(nodeId + '-tbody');
    g.items.forEach(function(it) {
      var normalStr = (it.normal || []).map(function(n) { return n.toFixed(2); }).join(', ');
      var tr = document.createElement('tr');
      tr.innerHTML =
        '<td>' + esc(it.face_id) + '</td>' +
        '<td>' + esc(it.su_material || '未赋材质') + '</td>' +
        '<td>' + (it.qty || 0) + '</td>' +
        '<td>' + esc(it.unit || '-') + '</td>' +
        '<td>' + esc(kindLabels[it.kind] || it.kind || '-') + '</td>' +
        '<td>' + esc(partLabels[it.part] || '-') + '</td>' +
        '<td style="font-size:11px">' + normalStr + '</td>' +
        '<td>' + (it.width || 0) + '</td>' +
        '<td>' + (it.height || 0) + '</td>' +
        '<td>' + esc(it.layer_name || '-') + '</td>' +
        '<td>' + (it.z_center || 0) + '</td>';
      tbody.appendChild(tr);
    });
  });

  // Opening table
  var opTbody = document.getElementById('opening-body');
  opTbody.innerHTML = '';
  (data.openings || []).forEach(function(op) {
    var hosts = (op.host_face_ids || []).join(', ') || '未关联';
    var tr = document.createElement('tr');
    tr.innerHTML =
      '<td>' + esc(op.entity_id) + '</td>' +
      '<td>' + (op.area || 0) + '</td>' +
      '<td>' + esc(hosts) + '</td>';
    opTbody.appendChild(tr);
  });

  showPhase('scan');
}

// ---------------- Phase 2: Mapping ----------------
// Called when user clicks "下一步 → 处理映射" and also when review data refreshes
function renderMappingPhase() {
  var data = window._reviewState;
  if (!data) return;
  renderReviewTable(data);

  // Show/hide the proceed button
  var proceed = document.getElementById('mapping-proceed');
  if ((data.unresolved || []).length === 0) {
    proceed.style.display = 'block';
  } else {
    proceed.style.display = 'none';
  }
}

// Render the review table inside mapping phase
function renderReviewTable(data) {
  var infoMap = {};
  (data.materials_info || []).forEach(function(i) { infoMap[i.su_name] = i; });
  var ignoredSet = {};
  (data.ignored || []).forEach(function(n) { ignoredSet[n] = true; });

  var allNames = (data.materials_info || []).map(function(i) { return i.su_name; });
  var unresolvedSet = {};
  (data.unresolved || []).forEach(function(n) { unresolvedSet[n] = true; });

  var tbody = document.getElementById('review-body');
  tbody.innerHTML = '';
  allNames.forEach(function(name) {
    var info = infoMap[name] || {};
    var isIgnored = !!ignoredSet[name];
    var isUnresolved = !!unresolvedSet[name];
    var isMapped = !isIgnored && !isUnresolved;

    var tr = document.createElement('tr');
    tr.className = isMapped ? 'row-mapped' : (isIgnored ? 'row-ignored' : 'row-unresolved');

    var statusHtml = isMapped
      ? '<span class="tag tag-mapped">✓ 已映射</span>'
      : (isIgnored ? '<span class="tag tag-ignored">已忽略</span>'
                   : '<span class="tag tag-unresolved">待处理</span>');

    tr.innerHTML =
      '<td>' + statusHtml + '</td>' +
      '<td>' + renderNameCell(name, info) + '</td>' +
      '<td>' + renderContextCell(info) + '</td>' +
      renderEditCells(name, isMapped || isIgnored) +
      '<td><input type="checkbox" class="u-ignore"' + (isIgnored ? ' checked' : '') +
           ' onchange="toggleIgnore(\'' + escAttr(name) + '\', this.checked)"></td>' +
      '<td><button onclick="locateMaterial(\'' + escAttr(name) + '\')">🎯</button></td>';
    tbody.appendChild(tr);
  });

  var s = (data.unresolved || []).length === 0
    ? '所有材质已处理 — 点击「确认并统计」查看结果'
    : '待处理 ' + data.unresolved.length + ' 项 — 点 🎯 定位到面；填写材料名→「保存映射」，或勾「忽略」跳过';
  document.getElementById('mapping-summary').textContent = s;
}

function renderNameCell(name, info) {
  var swatch;
  if (info.color) {
    var c = info.color;
    swatch = '<span class="swatch" style="background:rgba(' + c.r + ',' + c.g + ',' + c.b + ',' + (c.a || 1) + ')"></span>';
  } else {
    swatch = '<span class="swatch swatch-empty" title="无颜色">?</span>';
  }
  var meta = '<div class="u-meta">' +
    (info.face_count ? '<span>' + info.face_count + ' 面</span>' : '') +
    (info.total_area ? '<span>' + info.total_area + ' m²</span>' : '') +
    '</div>';
  return '<div class="u-name-row">' + swatch +
    '<span class="u-name" title="' + esc(name) + '">' + esc(name) + '</span>' +
    '</div>' + meta +
    '<input type="hidden" class="u-su" value="' + esc(name) + '">';
}

function renderContextCell(info) {
  var partLabels = { floor: '地', wall: '墙', ceiling: '顶' };
  var partsHtml = '';
  if (info.parts) {
    Object.keys(info.parts).forEach(function(p) {
      partsHtml += '<span class="pill pill-' + p + '">' + (partLabels[p] || p) + ' ' + info.parts[p] + '</span>';
    });
  }
  var spacesHtml = '';
  if (info.spaces && info.spaces.length) {
    spacesHtml = '<div class="u-spaces">' +
      info.spaces.map(function(s) { return esc(s.name) + ' (' + s.area + ')'; }).join(', ') +
      '</div>';
  }
  return partsHtml + spacesHtml;
}

function renderEditCells(name, disabled) {
  var cats = window._categories && window._categories.length ? window._categories : DEFAULT_CATEGORIES;
  var catOptions = cats.map(function(c) {
    var selected = c === guessCategory(name) ? ' selected' : '';
    return '<option value="' + esc(c) + '"' + selected + '>' + esc(c) + '</option>';
  }).join('');
  var dis = disabled ? ' disabled' : '';
  return '<td><input type="text" class="u-mat" placeholder="留空则跳过"' + dis + '></td>' +
         '<td><select class="u-cat"' + dis + '>' + catOptions + '</select></td>' +
         '<td><input type="text" class="u-spec" placeholder="可选"' + dis + '></td>' +
         '<td><input type="number" class="u-waste" step="0.01" value="0.05" style="width:70px"' + dis + '></td>';
}

// ---------------- Mapping actions ----------------
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

function fillCommonDefaults() {
  document.querySelectorAll('#review-body tr.row-unresolved').forEach(function(tr) {
    var matInput = tr.querySelector('.u-mat');
    if (matInput && !matInput.value) matInput.value = tr.querySelector('.u-su').value;
  });
}

function ignoreAllUnresolved() {
  var names = [];
  document.querySelectorAll('#review-body tr.row-unresolved').forEach(function(tr) {
    names.push(tr.querySelector('.u-su').value);
  });
  if (names.length === 0) return;
  if (!confirm('将忽略 ' + names.length + ' 种待处理材质，确认？')) return;
  callSketchUp('set_ignored', JSON.stringify(names));
}

function toggleIgnore(name, on) {
  var current = (window._reviewState && window._reviewState.ignored) || [];
  var set = {};
  current.forEach(function(n) { set[n] = true; });
  if (on) { set[name] = true; } else { delete set[name]; }
  callSketchUp('set_ignored', JSON.stringify(Object.keys(set)));
}

function saveUnmappedBatch() {
  var rows = [];
  document.querySelectorAll('#review-body tr.row-unresolved').forEach(function(tr) {
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

function locateMaterial(suName) {
  callSketchUp('locate_material', suName);
}

function finalizeCompute() {
  callSketchUp('finalize_compute');
}

// When renderReview is called again (after mapping/ignore changes while in mapping phase),
// also refresh the mapping table.
var _origRenderReview = renderReview;
renderReview = function(data) {
  _origRenderReview(data);
  // If user is already in mapping phase, refresh the mapping table too
  if (document.getElementById('phase-mapping').style.display !== 'none') {
    renderMappingPhase();
  }
};

// Override goToMapping to also populate the mapping table
var _origGoToMapping = goToMapping;
goToMapping = function() {
  renderMappingPhase();
  showPhase('mapping');
};

// ---------------- Phase 3: Statistics results ----------------

// ---------------- Component tree builder ----------------
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
          name: name,
          id: id,
          path: path.slice(0, idx + 1),
          path_ids: ids.slice(0, idx + 1),
          faces: [],
          children: [],
          childrenMap: {}
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

// Determine dominant part for a node (≥80% of area in one part).
// Returns HTML for a badge, or empty string if no faces.
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

// ---------------- Component tree renderer ----------------
function renderComponentView(tree) {
  if (tree.faces.length > 0) {
    var orphanNode = {
      name: '模型根层级', path: [], path_ids: [], faces: tree.faces,
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
  var idKey = (node.path_ids || []).join('-') || 'noid-' + node.path.join('-');
  var nodeId = 'comp-' + idKey.replace(/[^a-zA-Z0-9\-]/g, '_');
  var indent = depth * 18;
  var hasChildren = node.children.length > 0 || node.faces.length > 0;
  var hidden = depth > 1 ? ' style="display:none"' : '';
  var partBadge = dominantPartBadge(node.stats);

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

function renderResults(data, view) {
  window._lastStats = data;

  var container = document.getElementById('stats-table-container');
  var activeView = view || document.querySelector('.view-btn.active')?.dataset.view || 'by-component';

  container.innerHTML = '';

  if (activeView === 'by-component' && data.items) {
    var tree = buildComponentTree(data.items);
    container.innerHTML = renderComponentView(tree);
    container.querySelectorAll('.comp-row').forEach(function(row) {
      row.addEventListener('click', function() {
        var toggle = row.querySelector('.comp-toggle');
        if (toggle) {
          toggleComponent(toggle.id.replace('-toggle', ''));
        }
      });
    });
    showPhase('stats');
    return;
  }

  var tableHtml = '<table><thead><tr>';
  if (activeView === 'by-space') {
    tableHtml += '<th>空间</th><th>部位</th><th>层名</th><th>材料</th><th>单位</th><th>数量</th><th>损耗率</th><th>采购量</th><th>规格</th>';
  } else if (activeView === 'by-material') {
    tableHtml += '<th>材料</th><th>分类</th><th>单位</th><th>数量</th><th>采购量</th>';
  } else {
    tableHtml += '<th>空间</th><th>部位</th><th>层名</th><th>材料</th><th>单位</th><th>数量</th><th>SU材质</th>';
  }
  tableHtml += '</tr></thead><tbody>';

  if (activeView === 'by-space' && data.by_space) {
    data.by_space.forEach(function(r) {
      var wastePct = (r.waste_rate * 100).toFixed(0);
      var unitLabel = r.unit || 'm2';
      tableHtml += '<tr>' +
        '<td>' + esc(r.space) + '</td><td>' + esc(r.part) + '</td>' +
        '<td>' + esc(r.layer || '') + '</td><td>' + esc(r.material_name) + '</td>' +
        '<td>' + unitLabel + '</td><td>' + r.net_area + '</td>' +
        '<td>' + wastePct + '%</td><td>' + r.purchase_qty + '</td>' +
        '<td>' + esc(r.spec || '-') + '</td>' +
        '</tr>';
    });
  } else if (activeView === 'by-material' && data.by_material) {
    Object.entries(data.by_material).forEach(function(entry) {
      var name = entry[0], v = entry[1];
      var sampleItem = v.items && v.items[0] ? v.items[0] : {};
      var unitLabel = sampleItem.unit || 'm2';
      var category = sampleItem.category || '';
      tableHtml += '<tr><td>' + esc(name) + '</td><td>' + esc(category) + '</td>' +
        '<td>' + unitLabel + '</td><td>' + v.net_area + '</td><td>' + v.purchase_qty + '</td></tr>';
    });
  } else if (activeView === 'detail' && data.by_space) {
    data.by_space.forEach(function(r) {
      var unitLabel = r.unit || 'm2';
      tableHtml += '<tr>' +
        '<td>' + esc(r.space) + '</td><td>' + esc(r.part) + '</td>' +
        '<td>' + esc(r.layer || '') + '</td><td>' + esc(r.material_name) + '</td>' +
        '<td>' + unitLabel + '</td><td>' + r.net_area + '</td><td>' + esc(r.su_material_name || '-') + '</td>' +
        '</tr>';
    });
  }

  tableHtml += '</tbody></table>';
  container.innerHTML += tableHtml;

  showPhase('stats');
}

// ---------------- Mapping management tab ----------------
function renderMappings(mappings) {
  var tbody = document.getElementById('mapping-body');
  tbody.innerHTML = '';
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
  filterMappings();
}

function filterMappings() {
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

// ---------------- helpers ----------------
function toggleGroup(nodeId) {
  var detail = document.getElementById(nodeId + '-detail');
  var toggle = document.getElementById(nodeId + '-toggle');
  if (detail.classList.contains('expanded')) {
    detail.classList.remove('expanded');
    toggle.textContent = '+';
  } else {
    detail.classList.add('expanded');
    toggle.textContent = '−';
  }
}
function esc(s) {
  if (s === null || s === undefined) return '';
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
                  .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function escAttr(s) { return esc(s).replace(/'/g, "\\'"); }