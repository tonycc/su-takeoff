// src/ui/app.js — 核心：导航、桥接、状态、工具函数

// ---------------- Sidebar navigation ----------------
document.querySelectorAll('.sb-nav').forEach(function(btn) {
  btn.addEventListener('click', function() {
    switchPage(btn.dataset.page);
  });
});

function switchPage(page) {
  window._currentPage = page;
  document.querySelectorAll('.sb-nav').forEach(function(b) { b.classList.remove('active'); });
  document.querySelector('.sb-nav[data-page="' + page + '"]').classList.add('active');
  document.querySelectorAll('.page-content').forEach(function(p) { p.style.display = 'none'; });
  document.getElementById('page-' + page).style.display = 'block';
  var isStat = page === 'component' || page === 'material' || page === 'zone';
  var bar = document.getElementById('summary-bar');
  if (bar) bar.style.display = (isStat && window._workbench) ? 'flex' : 'none';
  if (page === 'mapping') callSketchUp('get_mappings');
  if (page === 'settings') callSketchUp('get_processes');
  if (isStat) renderCurrentPage();
}

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
window._workbench = null;
window._currentPage = 'component';
window._faceMaterialTab = 'material';

function renderWorkbench(data) {
  window._workbench = data;
  document.querySelectorAll('.page-content .empty-state').forEach(function(el) { el.style.display = 'none'; });
  var bar = document.getElementById('summary-bar');
  bar.style.display = 'flex';
  renderSummaryBar(data);
  renderCurrentPage();
}

function switchFaceMaterialTab(tab) {
  window._faceMaterialTab = tab;
  var page = window._currentPage;
  if (page === 'component' || page === 'zone') renderCurrentPage();
}

function renderCurrentPage() {
  if (!window._workbench) return;
  var page = window._currentPage;
  if (page === 'component') renderComponentView(window._workbench);
  else if (page === 'material') renderMaterialView(window._workbench);
  else if (page === 'zone') renderZoneView(window._workbench);
}

// ---------------- Summary bar ----------------
function renderSummaryBar(data) {
  var ov = data.overview || {};
  var unresolved = ov.unresolved_count || 0;
  var text = (ov.total_faces || 0) + ' 面 · ' + (ov.total_area || 0) + ' m² · ' +
    (ov.material_count || 0) + ' 种材质 · 已映射 ' + (ov.mapped || 0) + ' · 待 ' + unresolved +
    ' · 已忽略 ' + (ov.ignored_count || 0) + ' · 洞口 ' + (ov.total_openings || 0) + ' / ' + (ov.total_opening_area || 0) + ' m²';
  var bar = document.getElementById('summary-bar');
  bar.textContent = text;
  if (unresolved > 0) {
    bar.classList.add('clickable');
    bar.onclick = function() { jumpToUnresolved(); };
  } else {
    bar.classList.remove('clickable');
    bar.onclick = null;
  }
}

function jumpToUnresolved() {
  switchPage('material');
}

// ---------------- Shared helpers ----------------
function esc(s) {
  if (s === null || s === undefined) return '';
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
                  .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function escAttr(s) { return esc(s).replace(/'/g, "\\'"); }

function csvEscape(v) {
  var s = String(v == null ? '' : v);
  if (s.indexOf(',') >= 0 || s.indexOf('"') >= 0 || s.indexOf('\n') >= 0) {
    return '"' + s.replace(/"/g, '""') + '"';
  }
  return s;
}

var DEFAULT_CATEGORIES = ['瓷砖', '石材', '涂料', '木材', '墙纸', '玻璃', '金属', '其他'];

function locateMaterial(suName) {
  callSketchUp('locate_material', suName);
}

function locateFace(faceId) {
  callSketchUp('locate_face', String(faceId));
}

// ---------------- Component tree toggle ----------------
function toggleComponent(nodeId) {
  var rows = document.querySelectorAll('[data-parent="' + nodeId + '"]');
  var toggle = document.getElementById(nodeId + '-toggle');
  if (!rows.length) return;
  var isHidden = rows[0].style.display === 'none';
  rows.forEach(function(row) { row.style.display = isHidden ? '' : 'none'; });
  if (toggle) toggle.textContent = isHidden ? '▾' : '▸';
}

// ---------------- Zone view shared state ----------------
window._zonePartFilter = window._zonePartFilter || 'all';

function setZonePartFilter(value) {
  window._zonePartFilter = value;
  renderZoneView(window._workbench);
}

function toggleZoneDetail(rowId) {
  var row = document.getElementById(rowId);
  if (!row) return;
  var isHidden = row.style.display === 'none';
  row.style.display = isHidden ? '' : 'none';
  var prevRow = row.previousElementSibling;
  if (prevRow) {
    var btn = prevRow.querySelector('button');
    if (btn) btn.textContent = isHidden ? '▼' : '▶';
  }
}
