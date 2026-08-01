// src/ui/js/settings.js — 设置页：分类单位、标签定义、启发式、启发式阈值

function renderSettings(data) {
  window._sharedConfig = data;
  var container = document.getElementById('settings-content');
  if (!container) return;

  var html = '';
  html += '<div class="settings-card">' + renderCategoryUnitConfig('组件分类', 'component_category_units', data.component_category_units || []) + '</div>';
  html += '<div class="settings-card">' + renderTagDefsConfig(data.tag_defs || {}) + '</div>';
  html += '<div class="settings-card">' + renderHeuristicsConfig(data.heuristics_enabled !== false) + '</div>';
  html += '<div class="settings-card">' + renderHeuristicThresholdsConfig(data.heuristic_thresholds || {}) + '</div>';
  container.innerHTML = html;
}

// ---------------- Category-unit config ----------------
function renderCategoryUnitConfig(title, key, categoryUnits) {
  var cfgUnits = ['m²', 'm', 'm³', '个'];
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

  var data = window._sharedConfig;
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

function removeCategoryUnit(btn, key) {
  var card = btn.closest('.cu-card');
  var cat = card.querySelector('.cu-card-name').textContent;
  var data = window._sharedConfig;
  data[key] = (data[key] || []).filter(function(cu) { return cu.category !== cat; });
  persistConfig();
  card.remove();
}

function persistConfig() {
  var data = window._sharedConfig;
  callSketchUp('save_config', JSON.stringify({
    component_category_units: data.component_category_units || [],
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
  var data = window._sharedConfig;
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
  var data = window._sharedConfig;
  data.tag_defs = data.tag_defs || {};
  data.tag_defs[tag] = method;
  persistConfig();
}

function removeTagDef(tag) {
  var data = window._sharedConfig;
  if (data.tag_defs) {
    delete data.tag_defs[tag];
  }
  persistConfig();
  refreshTagDefsCard();
}

function refreshTagDefsCard() {
  var container = document.getElementById('tag-defs-list');
  if (!container) return;
  var data = window._sharedConfig;
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
    '关闭后，未在图层规则或算量标签中显式标注的窄长面将不会被自动判定为线材。' +
    '</p>';
  html += '</div>';
  return html;
}

function toggleHeuristics(enabled) {
  var data = window._sharedConfig;
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
  var data = window._sharedConfig;
  data.heuristic_thresholds = data.heuristic_thresholds || {};
  var num = parseFloat(val);
  if (isNaN(num)) return;
  data.heuristic_thresholds[key] = num;
  persistConfig();
}

