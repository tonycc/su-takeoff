// src/ui/js/comp_mapping.js — 组件定义→材料映射 CRUD

function renderComponentMappings(mappings, definitions, config) {
  mappings = mappings || [];
  definitions = definitions || [];
  config = config || {};

  // Sync config data for consistent category/unit lists
  window._sharedConfig = window._sharedConfig || {};
  if (config.category_units) window._sharedConfig.category_units = config.category_units;
  if (config.config_units) window._sharedConfig.config_units = config.config_units;

  // Index existing mappings by definition_name
  var mappedByDef = {};
  mappings.forEach(function(m) {
    mappedByDef[m.definition_name] = m;
  });

  // Index definitions by name for quick lookup
  var defByName = {};
  definitions.forEach(function(entry) {
    defByName[entry.name] = entry.kind;
  });

  // Merge: all definitions from model, with mapping data where available
  var rows = definitions.map(function(entry) {
    var m = mappedByDef[entry.name];
    return {
      definition_name: entry.name,
      kind: entry.kind || 'component',
      material_name: m ? m.material_name : '',
      category: m ? m.category : '其他',
      unit: m ? m.unit : '个',
      spec: m ? m.spec : '',
      counting_method: m ? (m.counting_method || 'expand') : 'expand',
      is_mapped: !!m
    };
  });

  // Also include any mappings whose definition is not currently in the model
  mappings.forEach(function(m) {
    if (!defByName[m.definition_name]) {
      rows.push({
        definition_name: m.definition_name,
        kind: 'component',
        material_name: m.material_name || '',
        category: m.category || '其他',
        unit: m.unit || '个',
        spec: m.spec || '',
        counting_method: m.counting_method || 'expand',
        is_mapped: true,
        not_in_model: true
      });
    }
  });

  window._componentMappings = mappings;

  var container = document.getElementById('comp-mapping-content');
  if (!container) return;

  var mappedCount = mappings.length;
  var totalDefs = definitions.length;

  var html = '';

  html += '<div class="toolbar" style="gap:8px;margin-bottom:10px">';
  html += '<span style="font-weight:600;color:#cdd6f4">群组/组件映射</span>';
  var compCount = rows.filter(function(r) { return r.kind === 'component'; }).length;
  var groupCount = rows.filter(function(r) { return r.kind === 'group'; }).length;
  html += '<span style="color:#6c7086;font-size:12px">组件 ' + compCount + ' 个，群组 ' + groupCount + ' 个，已映射 ' + mappedCount + ' 个</span>';
  html += '<span style="flex:1"></span>';
  html += '<input type="text" id="comp-mapping-search" placeholder="搜索组件名..." style="width:160px" oninput="filterCompMappingRows()">';
  html += '<button onclick="addComponentMapping()">+ 新增</button>';
  html += '</div>';

  if (rows.length === 0) {
    html += '<p class="hint">模型中暂无群组或组件。请先在 SketchUp 中创建。</p>';
  } else {
    html += '<table style="table-layout:fixed"><thead><tr>' +
      '<th style="width:36px">#</th>' +
      '<th style="width:50px">类型</th>' +
      '<th style="width:150px">名称</th>' +
      '<th style="width:110px">自定义名称</th>' +
      '<th style="width:70px">分类</th>' +
      '<th style="width:50px">单位</th>' +
      '<th style="width:80px">计量方式</th>' +
      '<th style="width:90px">操作</th>' +
      '</tr></thead><tbody id="comp-mapping-tbody"></tbody></table>';
  }

  container.innerHTML = html;

  var tbody = document.getElementById('comp-mapping-tbody');
  if (!tbody) return;

  var cats = (window._sharedConfig && window._sharedConfig.category_units || [])
    .map(function(x) { return x.category; });
  if (cats.length === 0) cats = DEFAULT_CATEGORIES;

  function buildCatOpts(sel) {
    return cats.map(function(c) {
      var s = c === (sel || '其他') ? ' selected' : '';
      return '<option value="' + esc(c) + '"' + s + '>' + esc(c) + '</option>';
    }).join('');
  }

  rows.forEach(function(row, idx) {
    var tr = document.createElement('tr');
    tr.setAttribute('data-def', row.definition_name);
    if (row.is_mapped) tr.classList.add('row-mapped');
    if (row.not_in_model) tr.classList.add('row-not-in-model');

    var kindLabel = row.kind === 'group' ? '群组' : '组件';
    var kindClass = row.kind === 'group' ? 'mv-tag-badge-count' : 'mv-tag-badge-area';
    var nameDisplay = esc(row.definition_name);
    if (row.not_in_model) nameDisplay += ' <span style="color:#f38ba8;font-size:10px">(不在模型中)</span>';

    tr.innerHTML =
      '<td style="text-align:right;color:#6c7086;font-size:11px">' + (idx + 1) + '</td>' +
      '<td><span class="mv-tag-badge ' + kindClass + '" style="font-size:10px">' + kindLabel + '</span></td>' +
      '<td><code style="color:#89b4fa">' + nameDisplay + '</code></td>' +
      '<td><input type="text" class="u-mat" value="' + esc(row.material_name) + '"></td>' +
      '<td><select class="u-cat" onchange="onCompMappingCatChange(this)">' + buildCatOpts(row.category) + '</select></td>' +
      '<td><input type="text" class="u-unit" value="' + esc(row.unit) + '" style="width:50px" readonly></td>' +
      '<td><select class="u-method">' +
        '<option value="expand"' + (row.counting_method !== 'aggregate' ? ' selected' : '') + '>展开面材</option>' +
        '<option value="aggregate"' + (row.counting_method === 'aggregate' ? ' selected' : '') + '>整件统计</option>' +
      '</select></td>' +
      '<td>' +
        '<button class="primary-btn">保存</button>' +
        (row.is_mapped ? ' <button>删除</button>' : '') +
      '</td>';
    tr.querySelector('.primary-btn').onclick = function() { saveCompMappingRow(row.definition_name); };
    if (row.is_mapped) {
      tr.querySelectorAll('button')[1].onclick = function() { deleteCompMapping(row.definition_name); };
    }
    tbody.appendChild(tr);
  });
}

function onCompMappingCatChange(sel) {
  var cfg = (window._sharedConfig) || {};
  var cu = cfg.category_units || [];
  for (var i = 0; i < cu.length; i++) {
    if (cu[i].category === sel.value) {
      var row = sel.closest('tr');
      var unitInput = row.querySelector('.u-unit');
      if (unitInput) unitInput.value = cu[i].unit;
      return;
    }
  }
}

function filterCompMappingRows() {
  var q = (document.getElementById('comp-mapping-search') || {}).value || '';
  q = q.toLowerCase();
  var rows = document.querySelectorAll('#comp-mapping-tbody tr');
  rows.forEach(function(tr) {
    var name = (tr.getAttribute('data-def') || '').toLowerCase();
    tr.style.display = q ? (name.indexOf(q) >= 0 ? '' : 'none') : '';
  });
}

function addComponentMapping() {
  var defName = prompt('组件定义名称（需与 SketchUp 中组件/群组名称完全一致）:');
  if (!defName || !defName.trim()) return;
  defName = defName.trim();
  var matName = prompt('真实组件名称:') || '';
  callSketchUp('save_component_mapping', JSON.stringify({
    definition_name: defName,
    material_name: matName,
    category: '其他',
    unit: '个',
    spec: '',
    waste_rate: 0.0,
    counting_method: 'expand'
  }));
}

function saveCompMappingRow(defName) {
  var rows = document.querySelectorAll('#comp-mapping-tbody tr');
  var tr = null;
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].getAttribute('data-def') === defName) { tr = rows[i]; break; }
  }
  if (!tr) return;
  callSketchUp('save_component_mapping', JSON.stringify({
    definition_name: defName,
    material_name: tr.querySelector('.u-mat').value.trim(),
    category: tr.querySelector('.u-cat').value,
    unit: tr.querySelector('.u-unit').value.trim() || '个',
    spec: '',
    waste_rate: 0.0,
    counting_method: tr.querySelector('.u-method').value
  }));
}

function deleteCompMapping(defName) {
  if (!confirm('删除组件映射：' + defName + '？')) return;
  callSketchUp('delete_component_mapping', defName);
}
