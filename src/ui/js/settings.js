// src/ui/js/settings.js — 设置页：分类单位、可选单位、工艺管理、忽略材料

function renderProcesses(data) {
  window._processData = data;
  var container = document.getElementById('settings-content');
  if (!container) return;

  var html = '';
  html += '<div class="settings-card">' + renderCategoryUnitConfig('材料分类', 'material_category_units', data.material_category_units || data.category_units || []) + '</div>';
  html += '<div class="settings-card">' + renderCategoryUnitConfig('组件分类', 'component_category_units', data.component_category_units || []) + '</div>';
  html += '<div class="settings-card">' + renderUnitTagConfig(data.config_units || []) + '</div>';
  html += '<div class="settings-card">' + renderTagDefsConfig(data.tag_defs || {}) + '</div>';
  html += '<div class="settings-card">' + renderHeuristicsConfig(data.heuristics_enabled !== false) + '</div>';
  html += '<div class="settings-card">' + renderHeuristicThresholdsConfig(data.heuristic_thresholds || {}) + '</div>';
  html += '<div class="settings-card">' + renderProcessSection(data.processes || []) + '</div>';
  html += '<div class="settings-card">' + renderIgnoredSection(data.ignored || []) + '</div>';
  container.innerHTML = html;
}

// ---------------- Category-unit config ----------------
function renderCategoryUnitConfig(title, key, categoryUnits) {
  var cfgUnits = (window._processData && window._processData.config_units) || [];
  var unitOptions = cfgUnits.map(function(u) {
    return '<option value="' + esc(u) + '">' + esc(u) + '</option>';
  }).join('');

  var html = '<div class="sc-head">' + title + '</div>';
  html += '<div class="sc-body">';
  html += '<div class="cu-grid" id="cu-grid-' + key + '">';
  categoryUnits.forEach(function(cu) {
    html += '<div class="cu-card">' +
      '<span class="cu-card-name">' + esc(cu.category) + '</span>' +
      '<span class="cu-card-unit">' + esc(cu.unit) + '</span>' +
      '<button onclick="removeCategoryUnit(this, \'' + key + '\')" class="cu-card-del">×</button>' +
      '</div>';
  });
  html += '</div>';
  html += '<div class="cu-add-row">' +
    '<input type="text" class="cu-new-cat-' + key + '" placeholder="分类名">' +
    '<select class="cu-new-unit-' + key + '">' + unitOptions + '</select>' +
    '<button onclick="addCategoryUnit(\'' + key + '\')" class="primary-btn">添加</button>' +
    '</div>';
  html += '</div>';
  return html;
}

function addCategoryUnit(key) {
  var catInput = document.querySelector('.cu-new-cat-' + key);
  var unitSelect = document.querySelector('.cu-new-unit-' + key);
  var cat = catInput.value.trim();
  var unit = unitSelect.value;
  if (!cat) return;

  var data = window._processData;
  var list = data[key] || [];
  list.push({ category: cat, unit: unit });
  data[key] = list;
  persistConfig();

  var card = document.createElement('div');
  card.className = 'cu-card';
  card.innerHTML =
    '<span class="cu-card-name">' + esc(cat) + '</span>' +
    '<span class="cu-card-unit">' + esc(unit) + '</span>' +
    '<button onclick="removeCategoryUnit(this, \'' + key + '\')" class="cu-card-del">×</button>';
  document.getElementById('cu-grid-' + key).appendChild(card);
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

function removeCategoryUnit(btn, key) {
  var card = btn.closest('.cu-card');
  var cat = card.querySelector('.cu-card-name').textContent;
  var data = window._processData;
  data[key] = (data[key] || []).filter(function(cu) { return cu.category !== cat; });
  persistConfig();
  card.remove();
}

function persistConfig() {
  var data = window._processData;
  callSketchUp('save_config', JSON.stringify({
    material_category_units: data.material_category_units || [],
    component_category_units: data.component_category_units || [],
    units: data.config_units || [],
    heuristics_enabled: data.heuristics_enabled !== false,
    heuristic_thresholds: data.heuristic_thresholds || {},
    tag_defs: data.tag_defs || {}
  }));
}

// ---------------- Tag definitions config ----------------
// 算量标签 —— 定义标签名称和对应的计量方式。
// 在"按组件"视图可为群组/组件分配标签，写入实体 AttrDict（P1 优先级）。
function renderTagDefsInner(rules) {
  var keys = Object.keys(rules || {});
  if (keys.length === 0) {
    return '<p class="hint">未配置标签。示例：添加"踢脚线"→长度、"墙体"→面积。</p>';
  }
  var html = '<table style="width:100%"><thead><tr>' +
    '<th style="width:50%">标签名</th><th>计量方式</th><th style="width:80px"></th>' +
    '</tr></thead><tbody>';
  keys.forEach(function(tag) {
    html += renderTagDefRow(tag, rules[tag]);
  });
  html += '</tbody></table>';
  return html;
}

function renderTagDefsConfig(rules) {
  var html = '<div class="sc-head">算量标签 ' +
    '<span style="font-weight:normal;font-size:11px;color:#6c7086">' +
    '（定义标签及计量方式；支持多选组合，如「件数+长度」）' +
    '</span></div>';
  html += '<div class="sc-body">';
  html += '<div id="tag-defs-list">' + renderTagDefsInner(rules) + '</div>';
  html += '<div class="cu-add-row" style="margin-top:8px;flex-wrap:wrap;gap:8px;align-items:center">' +
    '<input type="text" id="td-new-tag" placeholder="标签名（如: 线灯）" style="width:160px">' +
    renderMethodCheckboxes('td-new') +
    '<button onclick="addTagDef()" class="primary-btn">添加</button>' +
    '</div>';
  html += '</div>';
  return html;
}

function renderMethodCheckboxes(idPrefix) {
  var methods = [
    { value: 'area',   label: '面积' },
    { value: 'length', label: '长度' },
    { value: 'volume', label: '体积' },
    { value: 'count',  label: '件数' }
  ];
  return methods.map(function(m) {
    return '<label style="font-size:11px;display:inline-flex;align-items:center;gap:2px;margin-right:6px">' +
      '<input type="checkbox" class="' + idPrefix + '-method" value="' + m.value + '"> ' + m.label +
      '</label>';
  }).join('');
}

function getCheckedMethods(idPrefix) {
  var cbs = document.querySelectorAll('.' + idPrefix + '-method');
  var methods = [];
  cbs.forEach(function(cb) { if (cb.checked) methods.push(cb.value); });
  return methods.length > 0 ? methods.join('+') : 'area';
}

function setCheckedMethods(idPrefix, methodStr) {
  var methods = (methodStr || 'area').split('+').map(function(s) { return s.trim(); });
  var cbs = document.querySelectorAll('.' + idPrefix + '-method');
  cbs.forEach(function(cb) { cb.checked = methods.indexOf(cb.value) >= 0; });
}

function formatMethodLabels(methodStr) {
  var labels = { area: '面积', length: '长度', volume: '体积', count: '件数' };
  return (methodStr || 'area').split('+').map(function(m) {
    var v = m.trim();
    return '<span class="tag-chip" style="font-size:10px;padding:1px 5px;margin:1px">' + (labels[v] || v) + '</span>';
  }).join('');
}

function renderTagDefRow(tag, method) {
  var methods = ['area','length','volume','count'];
  var selected = (method || 'area').split('+').map(function(s) { return s.trim(); });
  return '<tr data-tag="' + escAttr(tag) + '">' +
    '<td>' + esc(tag) + '</td>' +
    '<td>' +
      methods.map(function(m) {
        var checked = selected.indexOf(m) >= 0 ? ' checked' : '';
        return '<label style="font-size:11px;display:inline-flex;align-items:center;gap:2px;margin-right:6px">' +
          '<input type="checkbox" value="' + m + '"' + checked +
          ' onchange="updateTagDefCb(\'' + escAttr(tag) + '\')"> ' +
          ({area:'面积',length:'长度',volume:'体积',count:'件数'})[m] +
          '</label>';
      }).join('') +
    '</td>' +
    '<td><button onclick="removeTagDef(\'' + escAttr(tag) + '\')">删除</button></td>' +
    '</tr>';
}

function addTagDef() {
  var input = document.getElementById('td-new-tag');
  var tag = input.value.trim();
  if (!tag) return;
  var method = getCheckedMethods('td-new');
  var data = window._processData;
  data.tag_defs = data.tag_defs || {};
  data.tag_defs[tag] = method;
  persistConfig();
  refreshTagDefsCard();
  input.value = '';
}

function updateTagDefCb(tag) {
  var row = document.querySelector('tr[data-tag="' + escAttr(tag) + '"]');
  if (!row) return;
  var cbs = row.querySelectorAll('input[type="checkbox"]');
  var methods = [];
  cbs.forEach(function(cb) { if (cb.checked) methods.push(cb.value); });
  var method = methods.length > 0 ? methods.join('+') : 'area';
  var data = window._processData;
  data.tag_defs = data.tag_defs || {};
  data.tag_defs[tag] = method;
  persistConfig();
}

function removeTagDef(tag) {
  var data = window._processData;
  if (data.tag_defs) {
    delete data.tag_defs[tag];
  }
  persistConfig();
  refreshTagDefsCard();
}

function refreshTagDefsCard() {
  var container = document.getElementById('tag-defs-list');
  if (!container) return;
  var data = window._processData;
  container.innerHTML = renderTagDefsInner(data.tag_defs || {});
}

// ---------------- Heuristics toggle ----------------
function renderHeuristicsConfig(enabled) {
  var html = '<div class="sc-head">几何启发式判定 ' +
    '<span style="font-weight:normal;font-size:11px;color:#6c7086">' +
    '（自动识别极窄长面为线材，结果以红行待用户确认；不会直接覆盖显式规则）' +
    '</span></div>';
  html += '<div class="sc-body">';
  html += '<label style="display:flex;align-items:center;gap:8px">' +
    '<input type="checkbox" id="heuristics-toggle"' +
      (enabled ? ' checked' : '') +
      ' onchange="toggleHeuristics(this.checked)">' +
    '<span>开启启发式判定</span>' +
    '</label>';
  html += '<p class="hint" style="margin-top:6px">' +
    '关闭后，未在图层规则或材质映射中显式标注的窄长面将不会被自动判定为线材。' +
    '</p>';
  html += '</div>';
  return html;
}

function toggleHeuristics(enabled) {
  var data = window._processData;
  data.heuristics_enabled = !!enabled;
  persistConfig();
}

// ---------------- Heuristic thresholds ----------------
// 启发式判定阈值与竖直薄板去重阈值。开放给高级用户调优。
function renderHeuristicThresholdsConfig(th) {
  var minAspect    = th.linear_min_aspect_ratio   || 15;
  var maxShortEdge = th.linear_max_short_edge_m   || 0.2;
  var slabGap      = th.vertical_slab_gap_m       || 0.05;
  var slabAreaTol  = th.vertical_slab_area_tolerance || 0.02;

  var html = '<div class="sc-head">启发式阈值 ' +
    '<span style="font-weight:normal;font-size:11px;color:#6c7086">' +
    '（仅在启发式判定开启时生效；改动后立即重算）' +
    '</span></div>';
  html += '<div class="sc-body">';
  html += '<div class="cu-add-row" style="flex-wrap:wrap;gap:12px">';
  html += thresholdField('线材最小长宽比', 'linear_min_aspect_ratio', minAspect, 1, 50, 1,
    '面的长边/短边比超过此值且垂直时，提示按长度计量');
  html += thresholdField('线材最大短边 (m)', 'linear_max_short_edge_m', maxShortEdge, 0.01, 1.0, 0.01,
    '面的短边大于此值时不会被启发式判为线材（防止窗台板误判）');
  html += thresholdField('竖直薄板配对最大间距 (m)', 'vertical_slab_gap_m', slabGap, 0.01, 0.3, 0.01,
    '两面 bbox 中心距小于此值才会被视为薄板背靠背的两面');
  html += thresholdField('竖直薄板面积容差', 'vertical_slab_area_tolerance', slabAreaTol, 0, 0.2, 0.01,
    '两面面积差占比小于此值才视为同一薄板（0.02 = 2%）');
  html += '</div>';
  html += '</div>';
  return html;
}

function thresholdField(label, key, value, min, max, step, hint) {
  return '<div style="display:flex;flex-direction:column;gap:2px;min-width:180px">' +
    '<label style="font-size:11px;color:#a6adc8">' + esc(label) + '</label>' +
    '<input type="number" value="' + value + '" min="' + min + '" max="' + max + '" step="' + step + '"' +
      ' onchange="updateThreshold(\'' + key + '\', this.value)" style="width:120px">' +
    '<span style="font-size:10px;color:#6c7086">' + esc(hint) + '</span>' +
    '</div>';
}

function updateThreshold(key, val) {
  var data = window._processData;
  data.heuristic_thresholds = data.heuristic_thresholds || {};
  var num = parseFloat(val);
  if (isNaN(num)) return;
  data.heuristic_thresholds[key] = num;
  persistConfig();
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
  var cu = cfg.material_category_units || cfg.category_units || [];
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
            ((cfg.config_units && cfg.config_units.length > 0) ? cfg.config_units : ['m²','m','m³','个']).map(function(u) {
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
  var cu = cfg.material_category_units || cfg.category_units || [];
  var cats = cu.map(function(x) { return x.category; });
  var derivCatOptions = cats.map(function(c) {
    return '<option value="' + esc(c) + '">' + esc(c) + '</option>';
  }).join('');
  var units = (cfg.config_units && cfg.config_units.length > 0) ? cfg.config_units : ['m²','m','m³','个'];
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
