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
  document.getElementById('view-component').innerHTML = '<p class="hint">组件视图 (待实现)</p>';
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
