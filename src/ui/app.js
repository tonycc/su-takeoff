// src/ui/app.js

// Tab switching
document.querySelectorAll('.tab-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
    document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
    btn.classList.add('active');
    document.getElementById('tab-' + btn.dataset.tab).classList.add('active');
  });
});

// View switching
function switchView(view) {
  document.querySelectorAll('.view-btn').forEach(b => b.classList.remove('active'));
  document.querySelector(`.view-btn[data-view="${view}"]`).classList.add('active');
  if (window._lastStats) renderResults(window._lastStats, view);
}

// Bridge: call SU Ruby
function callSketchUp(action, json) {
  if (typeof sketchup !== 'undefined') {
    sketchup[action](json || '');
  } else {
    console.warn('Not running in SketchUp WebDialog');
  }
}

// Scan
function scanAll() { callSketchUp('scan_all'); }
function scanSelected() { callSketchUp('scan_selected'); }

// Render statistics
function renderResults(data, view) {
  window._lastStats = data;
  const container = document.getElementById('stats-table-container');
  const activeView = view || document.querySelector('.view-btn.active')?.dataset.view || 'by-space';

  container.innerHTML = '';

  if (data.unmapped && data.unmapped.length > 0) {
    const warn = document.createElement('div');
    warn.style.cssText = 'background:#3b1a1a;border:1px solid #f38ba8;border-radius:4px;padding:8px;margin-bottom:8px;color:#f38ba8;';
    warn.textContent = '⚠️ 未映射材质：' + data.unmapped.join(', ');
    container.appendChild(warn);
  }

  let tableHtml = '<table><thead><tr>';
  if (activeView === 'by-space') {
    tableHtml += '<th>空间</th><th>部位</th><th>材料</th><th>净面积(m²)</th><th>损耗率</th><th>采购量(m²)</th><th>规格</th>';
  } else if (activeView === 'by-material') {
    tableHtml += '<th>材料</th><th>净面积(m²)</th><th>采购量(m²)</th>';
  } else {
    tableHtml += '<th>空间</th><th>部位</th><th>材料</th><th>面积(m²)</th><th>SU材质</th><th>面ID</th>';
  }
  tableHtml += '</tr></thead><tbody>';

  if (activeView === 'by-space' && data.by_space) {
    data.by_space.forEach(function(r) {
      var wastePct = (r.waste_rate * 100).toFixed(0);
      tableHtml += '<tr>' +
        '<td>' + r.space + '</td><td>' + r.part + '</td><td>' + r.material_name + '</td>' +
        '<td>' + r.net_area + '</td><td>' + wastePct + '%</td><td>' + r.purchase_qty + '</td>' +
        '<td>' + (r.spec || '-') + '</td>' +
        '</tr>';
    });
  } else if (activeView === 'by-material' && data.by_material) {
    Object.entries(data.by_material).forEach(function(entry) {
      var name = entry[0], v = entry[1];
      tableHtml += '<tr><td>' + name + '</td><td>' + v.net_area + '</td><td>' + v.purchase_qty + '</td></tr>';
    });
  }

  tableHtml += '</tbody></table>';
  container.innerHTML += tableHtml;
}

// Mapping management
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
      '<td><button onclick="editProcess(\'' + esc(m.su_material_name) + '\')">选择工艺</button></td>' +
      '<td><button onclick="deleteMapping(\'' + esc(m.su_material_name) + '\')">删除</button></td>';
    tbody.appendChild(tr);
  });
  filterMappings();
}

function esc(s) {
  if (!s) return '';
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function filterMappings() {
  var q = document.getElementById('search-mapping').value.toLowerCase();
  document.querySelectorAll('#mapping-body tr').forEach(function(tr) {
    tr.style.display = tr.textContent.toLowerCase().includes(q) ? '' : 'none';
  });
}

function deleteMapping(suName) {
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

// Manual marking
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
