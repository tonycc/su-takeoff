// src/ui/js/settings.js — 设置页：分类单位、可选单位、工艺管理、忽略材料

function renderProcesses(data) {
  window._processData = data;
  var container = document.getElementById('settings-content');
  if (!container) return;

  var html = '';
  html += '<div class="settings-card">' + renderCategoryUnitConfig(data.category_units || []) + '</div>';
  html += '<div class="settings-card">' + renderUnitTagConfig(data.config_units || []) + '</div>';
  html += '<div class="settings-card">' + renderProcessSection(data.processes || []) + '</div>';
  html += '<div class="settings-card">' + renderIgnoredSection(data.ignored || []) + '</div>';
  container.innerHTML = html;
}

// ---------------- Category-unit config ----------------
function renderCategoryUnitConfig(categoryUnits) {
  var cfgUnits = (window._processData && window._processData.config_units) || [];
  var unitOptions = cfgUnits.map(function(u) {
    return '<option value="' + esc(u) + '">' + esc(u) + '</option>';
  }).join('');

  var html = '<div class="sc-head">分类与默认单位</div>';
  html += '<div class="sc-body">';
  html += '<div class="cu-grid">';
  categoryUnits.forEach(function(cu) {
    html += '<div class="cu-card">' +
      '<span class="cu-card-name">' + esc(cu.category) + '</span>' +
      '<span class="cu-card-unit">' + esc(cu.unit) + '</span>' +
      '<button onclick="removeCategoryUnit(this)" class="cu-card-del">×</button>' +
      '</div>';
  });
  html += '</div>';
  html += '<div class="cu-add-row">' +
    '<input type="text" class="cu-new-cat" placeholder="分类名">' +
    '<select class="cu-new-unit">' + unitOptions + '</select>' +
    '<button onclick="addCategoryUnit()" class="primary-btn">添加</button>' +
    '</div>';
  html += '</div>';
  return html;
}

function addCategoryUnit() {
  var catInput = document.querySelector('.cu-new-cat');
  var unitSelect = document.querySelector('.cu-new-unit');
  var cat = catInput.value.trim();
  var unit = unitSelect.value;
  if (!cat) return;

  var data = window._processData;
  data.category_units.push({ category: cat, unit: unit });
  persistConfig();

  var card = document.createElement('div');
  card.className = 'cu-card';
  card.innerHTML =
    '<span class="cu-card-name">' + esc(cat) + '</span>' +
    '<span class="cu-card-unit">' + esc(unit) + '</span>' +
    '<button onclick="removeCategoryUnit(this)" class="cu-card-del">×</button>';
  document.querySelector('.cu-grid').appendChild(card);
  catInput.value = '';
  unitSelect.selectedIndex = 0;
}

// ---------------- Unit tag config ----------------
function renderUnitTagConfig(units) {
  var html = '<div class="sc-head">可选单位</div>';
  html += '<div class="sc-body">';
  html += '<div class="tag-list" id="unit-tag-list">';
  units.forEach(function(u) {
    html += '<span class="tag-chip">' + esc(u) +
      '<button onclick="removeUnitTag(this, \'' + escAttr(u) + '\')" class="tag-chip-del">×</button></span>';
  });
  html += '</div>';
  html += '<div class="cu-add-row" style="margin-top:8px">' +
    '<input type="text" id="new-unit-input" placeholder="新单位" style="width:100px">' +
    '<button onclick="addUnitTag()" class="primary-btn">添加</button>' +
    '</div>';
  html += '</div>';
  return html;
}

function addUnitTag() {
  var input = document.getElementById('new-unit-input');
  var val = input.value.trim();
  if (!val) return;
  var data = window._processData;
  if (data.config_units.indexOf(val) >= 0) return;
  data.config_units.push(val);
  persistConfig();
  var chip = document.createElement('span');
  chip.className = 'tag-chip';
  chip.innerHTML = esc(val) + ' <button onclick="removeUnitTag(this, \'' + escAttr(val) + '\')" class="tag-chip-del">×</button>';
  document.getElementById('unit-tag-list').appendChild(chip);
  input.value = '';
}

function removeUnitTag(btn, val) {
  var data = window._processData;
  var idx = data.config_units.indexOf(val);
  if (idx >= 0) data.config_units.splice(idx, 1);
  persistConfig();
  btn.parentElement.remove();
}

function removeCategoryUnit(btn) {
  var card = btn.closest('.cu-card');
  var cat = card.querySelector('.cu-card-name').textContent;
  var data = window._processData;
  data.category_units = data.category_units.filter(function(cu) { return cu.category !== cat; });
  persistConfig();
  card.remove();
}

function persistConfig() {
  var data = window._processData;
  callSketchUp('save_config', JSON.stringify({
    category_units: data.category_units || [],
    units: data.config_units || []
  }));
}

// ---------------- Process section ----------------
function renderProcessSection(processList) {
  var allProcs = [];
  (processList || []).forEach(function(cat) {
    (cat.processes || []).forEach(function(p) {
      allProcs.push({ category: cat.category, name: p.name, waste_rate: p.waste_rate, derivations: p.derivations || [] });
    });
  });

  var cfg = (window._processData) || {};
  var cu = cfg.category_units || [];
  var categories = cu.map(function(x) { return x.category; });
  var catOptions = categories.map(function(c) {
    return '<option value="' + esc(c) + '">' + esc(c) + '</option>';
  }).join('');

  var html = '<div class="sc-head">工艺管理</div>';
  html += '<div class="sc-body">';
  html += '<div class="toolbar" style="margin-bottom:10px">' +
    '<select id="new-process-category"><option value="">选择分类</option>' + catOptions + '</select>' +
    '<input type="text" id="new-process-name" placeholder="工艺名称">' +
    '<input type="number" id="new-process-waste" step="1" min="0" max="100" value="5"> %' +
    '<button onclick="addNewProcess()" class="primary-btn">+ 添加</button>' +
    '</div>';

  if (allProcs.length === 0) {
    html += '<p class="hint">暂无工艺数据，请添加</p>';
  } else {
    html += '<div style="max-height:500px;overflow-y:auto"><table id="process-table"><thead><tr>' +
      '<th>分类</th><th>工艺名称</th><th>损耗率</th><th>衍生项</th><th>操作</th>' +
      '</tr></thead><tbody>';

    allProcs.forEach(function(proc) {
      var wastePct = (proc.waste_rate * 100).toFixed(0);
      var derivs = proc.derivations || [];
      var rowKey = escAttr(proc.category) + '|||' + escAttr(proc.name);
      var derivId = 'proc-deriv-' + rowKey.replace(/[^a-zA-Z0-9]/g, '_');
      var derivText = derivs.length > 0
        ? derivs.map(function(d) { return d.layer || d.name || '(无名称)'; }).join(', ')
        : '无';

      html += '<tr data-category="' + escAttr(proc.category) + '" data-name="' + escAttr(proc.name) + '">' +
        '<td><select class="u-pcat" style="width:100%">' +
          categories.map(function(c) {
            return '<option value="' + esc(c) + '"' + (c === proc.category ? ' selected' : '') + '>' + esc(c) + '</option>';
          }).join('') +
        '</select></td>' +
        '<td><input type="text" class="u-pname" value="' + esc(proc.name) + '"></td>' +
        '<td><input type="number" class="u-pwaste" step="1" min="0" max="100" value="' + wastePct + '"> %</td>' +
        '<td style="font-size:11px">' +
          '<span class="u-deriv-summary">' + esc(derivText) + '</span>' +
          ' <button onclick="toggleDerivEditor(\'' + derivId + '\')" style="font-size:10px;padding:1px 5px">编辑</button>' +
        '</td>' +
        '<td>' +
          '<button onclick="saveProcessRow(\'' + escAttr(proc.category) + '\', \'' + escAttr(proc.name) + '\')" class="primary-btn">保存</button>' +
          '<button onclick="deleteProcess(\'' + escAttr(proc.category) + '\', \'' + escAttr(proc.name) + '\')">删除</button>' +
        '</td>' +
        '</tr>';

      html += '<tr id="' + derivId + '" class="deriv-editor-row" style="display:none">' +
        '<td colspan="5" style="padding:8px 12px">' +
          '<div class="deriv-editor-card">' +
            '<table class="deriv-table"><thead><tr>' +
              '<th>衍生名称</th><th>公式</th><th>单位</th><th>损耗率</th><th>分类</th><th></th>' +
            '</tr></thead><tbody class="deriv-tbody">';

      derivs.forEach(function(der) {
        var dw = ((der.waste_rate || 0) * 100).toFixed(0);
        html += '<tr class="deriv-row">' +
          '<td><input type="text" class="u-dlayer" value="' + esc(der.layer || '') + '" placeholder="如: 抹灰找平层"></td>' +
          '<td><input type="text" class="u-dformula" value="' + esc(der.formula || 'area') + '" style="width:100px"></td>' +
          '<td><select class="u-dunit">' +
            ['m²','m','m³','个','kg','桶'].map(function(u) {
              var s = u === (der.unit || 'm²') ? ' selected' : '';
              return '<option value="' + u + '"' + s + '>' + u + '</option>';
            }).join('') +
          '</select></td>' +
          '<td><input type="number" class="u-dwaste" step="1" min="0" max="100" value="' + dw + '" style="width:50px"> %</td>' +
          '<td><select class="u-dcat" style="width:100%">' +
          categories.map(function(c) {
            return '<option value="' + esc(c) + '"' + (c === (der.category || '') ? ' selected' : '') + '>' + esc(c) + '</option>';
          }).join('') +
        '</select></td>' +
          '<td><button onclick="this.closest(\'.deriv-row\').remove()" style="font-size:10px">✕</button></td>' +
          '</tr>';
      });

      html += '</tbody></table>' +
            '<button onclick="addDerivRow(this)" style="font-size:11px;margin-top:6px">+ 添加衍生项</button>' +
          '</div>' +
        '</td>' +
        '</tr>';
    });

    html += '</tbody></table></div>';
  }
  html += '</div>';
  return html;
}

function toggleDerivEditor(derivId) {
  var row = document.getElementById(derivId);
  if (!row) return;
  var isHidden = row.style.display === 'none';
  row.style.display = isHidden ? '' : 'none';
}

function addDerivRow(btn) {
  var tbody = btn.parentElement.querySelector('.deriv-tbody');
  if (!tbody) return;
  var cfg = (window._processData) || {};
  var cu = cfg.category_units || [];
  var cats = cu.map(function(x) { return x.category; });
  var derivCatOptions = cats.map(function(c) {
    return '<option value="' + esc(c) + '">' + esc(c) + '</option>';
  }).join('');
  var units = (cfg.config_units && cfg.config_units.length > 0) ? cfg.config_units : ['m²','m','个'];
  var derivUnitOptions = units.map(function(u) {
    return '<option value="' + esc(u) + '">' + esc(u) + '</option>';
  }).join('');

  var tr = document.createElement('tr');
  tr.className = 'deriv-row';
  tr.innerHTML =
    '<td><input type="text" class="u-dlayer" placeholder="如: 抹灰找平层"></td>' +
    '<td><input type="text" class="u-dformula" value="area" style="width:100px"></td>' +
    '<td><select class="u-dunit">' + derivUnitOptions + '</select></td>' +
    '<td><input type="number" class="u-dwaste" step="1" min="0" max="100" value="5" style="width:50px"> %</td>' +
    '<td><select class="u-dcat" style="width:100%"><option value="">-</option>' + derivCatOptions + '</select></td>' +
    '<td><button onclick="this.closest(\'.deriv-row\').remove()" style="font-size:10px">✕</button></td>';
  tbody.appendChild(tr);
}

// ---------------- Ignored materials ----------------
function renderIgnoredSection(ignored) {
  var html = '<div class="sc-head">忽略材料管理</div>';
  html += '<div class="sc-body">';
  if (!ignored || ignored.length === 0) {
    html += '<p class="hint">当前没有被忽略的材料</p>';
  } else {
    html += '<div class="toolbar">' +
      '<button onclick="clearAllIgnored()" style="color:#f38ba8;border-color:#f38ba8">清空全部</button>' +
      '</div><table><thead><tr><th>SU 材质名</th><th>操作</th></tr></thead><tbody>';
    ignored.forEach(function(name) {
      html += '<tr>' +
        '<td>' + esc(name) + '</td>' +
        '<td><button onclick="unignoreMaterial(\'' + escAttr(name) + '\')">取消忽略</button></td>' +
        '</tr>';
    });
    html += '</tbody></table>';
  }
  html += '</div>';
  return html;
}

// ---------------- Process CRUD ----------------
function addNewProcess() {
  var category = document.getElementById('new-process-category').value.trim();
  var name = document.getElementById('new-process-name').value.trim();
  var wastePct = parseFloat(document.getElementById('new-process-waste').value);
  if (!category) { alert('请输入分类'); return; }
  if (!name) { alert('请输入工艺名称'); return; }
  if (isNaN(wastePct) || wastePct < 0) wastePct = 5;
  callSketchUp('save_process', JSON.stringify({
    category: category, name: name,
    waste_rate: wastePct / 100, derivations: []
  }));
}

function saveProcessRow(category, oldName) {
  var rows = document.querySelectorAll('#process-table tbody tr');
  var tr = null, derivTr = null;
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].getAttribute('data-category') === category &&
        rows[i].getAttribute('data-name') === oldName) {
      tr = rows[i];
      derivTr = rows[i + 1];
      break;
    }
  }
  if (!tr) return;
  var newCat = tr.querySelector('.u-pcat').value.trim();
  var newName = tr.querySelector('.u-pname').value.trim();
  var wastePct = parseFloat(tr.querySelector('.u-pwaste').value);
  if (!newCat) { alert('请输入分类'); return; }
  if (!newName) { alert('请输入工艺名称'); return; }
  if (isNaN(wastePct) || wastePct < 0) wastePct = 5;

  var derivations = [];
  if (derivTr) {
    derivTr.querySelectorAll('.deriv-row').forEach(function(dr) {
      var layer = dr.querySelector('.u-dlayer').value.trim();
      if (!layer) return;
      var dwPct = parseFloat(dr.querySelector('.u-dwaste').value);
      if (isNaN(dwPct) || dwPct < 0) dwPct = 5;
      derivations.push({
        layer: layer,
        formula: dr.querySelector('.u-dformula').value.trim() || 'area',
        unit: dr.querySelector('.u-dunit').value,
        waste_rate: dwPct / 100,
        category: dr.querySelector('.u-dcat').value.trim() || newCat
      });
    });
  }

  callSketchUp('save_process', JSON.stringify({
    old_category: category, old_name: oldName,
    category: newCat, name: newName,
    waste_rate: wastePct / 100, derivations: derivations
  }));
}

function deleteProcess(category, name) {
  if (!confirm('删除工艺：' + name + ' (' + category + ')？')) return;
  callSketchUp('delete_process', JSON.stringify({ category: category, name: name }));
}

function unignoreMaterial(name) {
  callSketchUp('unignore', name);
}

function clearAllIgnored() {
  if (!confirm('确认清空全部忽略材料？')) return;
  callSketchUp('clear_ignored');
}
