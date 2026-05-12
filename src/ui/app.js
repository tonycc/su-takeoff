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

// ---------------- View renderers (stubs — replaced in subsequent tasks) ----------------
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

function renderMaterialView(data) {
  document.getElementById('view-material').innerHTML = '<p class="hint">材料视图 (待实现)</p>';
}
function renderPurchaseView(data) {
  document.getElementById('view-purchase').innerHTML = '<p class="hint">采购量视图 (待实现)</p>';
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

// ---------------- Helpers ----------------
function esc(s) {
  if (s === null || s === undefined) return '';
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
                  .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function escAttr(s) { return esc(s).replace(/'/g, "\\'"); }
