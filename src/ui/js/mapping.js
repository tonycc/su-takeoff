// src/ui/js/mapping.js — 映射管理：双表切换、CRUD、搜索导入导出

// ---------------- Data loading ----------------
function renderMappings(mappings, config) {
  if (config) {
    if (!window._sharedConfig) window._sharedConfig = {};
    window._sharedConfig.category_units = config.category_units || [];
    window._sharedConfig.config_units = config.config_units || [];
  }
  var allRows = mappings.slice();
  if (window._workbench) {
    var unresolved = window._workbench.unresolved || [];
    var mappedSet = {};
    allRows.forEach(function(m) { mappedSet[m.su_material_name] = true; });
    unresolved.forEach(function(name) {
      if (!mappedSet[name]) {
        allRows.push({
          su_material_name: name, material_name: '', category: '其他',
          unit: 'm²', spec: ''
        });
      }
    });
  }
  renderSimpleMappingTable(allRows);
}

// ---------------- Toggle state ----------------
window._mappingTab = window._mappingTab || 'mapped';

function switchMappingTab(tab) {
  window._mappingTab = tab;
  if (window._lastMappings) renderSimpleMappingTable(window._lastMappings);
}

// ---------------- Main render ----------------
function renderSimpleMappingTable(mappings) {
  window._lastMappings = mappings;
  var container = document.getElementById('mapping-content');
  if (!container) return;

  var cfg = (window._sharedConfig) || {};
  var cu = cfg.category_units || [];
  var cats = cu.length > 0 ? cu.map(function(x) { return x.category; }) : DEFAULT_CATEGORIES;
  var units = (cfg.config_units && cfg.config_units.length > 0) ? cfg.config_units : ['m²', 'm', 'm³', '个'];
  var partLabels = { floor: '地', wall: '墙', ceiling: '顶' };

  var infoMap = {};

  var mapped = [], unmapped = [];
  mappings.forEach(function(m) {
    if (m.material_name) { mapped.push(m); } else { unmapped.push(m); }
  });

  var tab = window._mappingTab || 'mapped';
  var unitDatalistId = 'mapping-unit-list';
  var unitOptions = units.map(function(u) { return '<option value="' + esc(u) + '">'; }).join('');

  var html = '';

  // Toolbar: toggle + search + actions
  html += '<div class="toolbar" style="gap:8px;margin-bottom:10px">';
  html += '<button class="fmt-btn' + (tab === 'mapped' ? ' active' : '') +
    '" onclick="switchMappingTab(\'mapped\')">已映射 · ' + mapped.length + '</button>';
  html += '<button class="fmt-btn' + (tab === 'unmapped' ? ' active' : '') +
    '" onclick="switchMappingTab(\'unmapped\')">未映射 · ' + unmapped.length + '</button>';
  html += '<span style="flex:1"></span>';
  html += '<input type="text" id="search-mapping" placeholder="搜索SU材质..." oninput="filterSimpleMappings()" style="width:180px;flex:0">';
  html += '<button onclick="importCsv()">导入CSV</button>';
  html += '<button onclick="exportCsv()">导出CSV</button>';
  html += '<button onclick="openAddMapping()">+ 新增</button>';
  html += '</div>';
  html += '<datalist id="' + unitDatalistId + '">' + unitOptions + '</datalist>';

  // Build category options once (shared across rows)
  function buildCatOptions(selected) {
    return cats.map(function(c) {
      var sel = c === (selected || '其他') ? ' selected' : '';
      return '<option value="' + esc(c) + '"' + sel + '>' + esc(c) + '</option>';
    }).join('');
  }

  // Table area — render shell as string, then populate rows from templates
  if (tab === 'mapped') {
    if (mapped.length > 0) {
      html += '<table><thead><tr>' +
        '<th style="width:40px">#</th>' +
        '<th>SU材质</th>' +
        '<th>真实材料名</th>' +
        '<th style="width:100px">平台标签</th>' +
        '<th style="width:160px">平台SKU</th>' +
        '<th style="width:80px">分类</th>' +
        '<th style="width:60px">单位</th>' +
        '<th style="width:100px">操作</th>' +
        '</tr></thead><tbody id="mapping-tbody"></tbody></table>';
    } else {
      html += '<p class="hint">暂无已映射项</p>';
    }
  } else {
    if (unmapped.length > 0) {
      html += '<table><thead><tr>' +
        '<th style="width:40px">#</th>' +
        '<th>SU材质</th>' +
        '<th>面数/面积</th>' +
        '<th>部位分布</th>' +
        '<th>真实材料名</th>' +
        '<th style="width:100px">平台标签</th>' +
        '<th style="width:160px">平台SKU</th>' +
        '<th style="width:80px">分类</th>' +
        '<th style="width:60px">单位</th>' +
        '<th style="width:100px">操作</th>' +
        '</tr></thead><tbody id="mapping-tbody"></tbody></table>';
    } else {
      html += '<p class="hint">所有材质已映射</p>';
    }
  }

  container.innerHTML = html;

  // Populate rows from templates
  var tbody = document.getElementById('mapping-tbody');
  if (!tbody) return;

  if (tab === 'mapped') {
    var tpl = document.getElementById('tmpl-mapping-row');
    mapped.forEach(function(m, idx) {
      var tr = tpl.content.firstElementChild.cloneNode(true);
      tr.setAttribute('data-su', m.su_material_name);
      tr.querySelector('.col-seq').textContent = idx + 1;
      tr.querySelector('.col-su-name').textContent = m.su_material_name;
      tr.querySelector('.u-mat').value = m.material_name || '';
      tr.querySelector('.u-platform-tag').value = m.platform_material_tag || '';
      tr.querySelector('.u-cat').innerHTML = buildCatOptions(m.category);
      tr.querySelector('.u-unit').value = m.unit || 'm²';
      tr.dataset.skuId = m.platform_sku_id || '';
      tr.dataset.skuCode = m.platform_sku_code || '';
      tr.dataset.skuName = m.platform_sku_name || '';
      tr.querySelector('.u-sku').value =
        m.platform_sku_code ? (m.platform_sku_code + ' ' + (m.platform_sku_name || '')) : '';
      bindSkuAutocomplete(tr);

      var actions = tr.querySelector('.col-actions');
      actions.innerHTML = '<button>保存</button><button>删除</button>';
      actions.children[0].onclick = function() { saveMappingRow(m.su_material_name); };
      actions.children[1].onclick = function() { deleteMapping(m.su_material_name); };

      tbody.appendChild(tr);
    });
  } else {
    var tplU = document.getElementById('tmpl-mapping-unmapped-row');
    unmapped.forEach(function(m, idx) {
      var info = infoMap[m.su_material_name] || {};
      var tr = tplU.content.firstElementChild.cloneNode(true);
      tr.setAttribute('data-su', m.su_material_name);
      tr.querySelector('.col-seq').textContent = idx + 1;

      // Swatch
      var c = info.color || {};
      var swatch = tr.querySelector('.swatch');
      if (info.color) {
        swatch.style.background = 'rgba(' + c.r + ',' + c.g + ',' + c.b + ',' + (c.a || 1) + ')';
      } else {
        swatch.classList.add('swatch-empty');
        swatch.textContent = '?';
      }

      tr.querySelector('.u-name').textContent = m.su_material_name;
      tr.querySelector('.u-name').title = m.su_material_name;

      var suggested = info.suggested_unit || 'm²';
      tr.querySelector('.col-quantity').textContent = suggested === 'm'
        ? (info.face_count || 0) + ' 面 / ' + (info.total_length || 0) + ' m'
        : (info.face_count || 0) + ' 面 / ' + (info.total_area || 0) + ' m²';

      // Parts pills
      var partsCell = tr.querySelector('.col-parts');
      if (info.parts) {
        Object.keys(info.parts).forEach(function(p) {
          var pill = document.createElement('span');
          pill.className = 'pill pill-' + p;
          pill.textContent = (partLabels[p] || p) + ' ' + info.parts[p];
          partsCell.appendChild(pill);
        });
      }

      tr.querySelector('.u-mat').value = '';
      tr.querySelector('.u-platform-tag').value = m.platform_material_tag || '';
      tr.querySelector('.u-cat').innerHTML = buildCatOptions('其他');
      tr.querySelector('.u-unit').value = suggested;
      tr.dataset.skuId = m.platform_sku_id || '';
      tr.dataset.skuCode = m.platform_sku_code || '';
      tr.dataset.skuName = m.platform_sku_name || '';
      tr.querySelector('.u-sku').value =
        m.platform_sku_code ? (m.platform_sku_code + ' ' + (m.platform_sku_name || '')) : '';
      bindSkuAutocomplete(tr);

      var actions = tr.querySelector('.col-actions');
      actions.innerHTML = '<button>保存</button><button>忽略</button>';
      actions.children[0].onclick = function() { saveMappingRow(m.su_material_name); };
      actions.children[1].onclick = function() { ignoreMaterial(m.su_material_name); };

      tbody.appendChild(tr);
    });
  }
}

// ---------------- Row actions ----------------
function onMappingCatChange(sel) {
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

function filterSimpleMappings() {
  var q = document.getElementById('search-mapping').value.toLowerCase();
  var tbody = document.getElementById('mapping-tbody');
  if (!tbody) return;
  tbody.querySelectorAll('tr').forEach(function(tr) {
    var haystack = tr.textContent || '';
    tr.querySelectorAll('input, select').forEach(function(el) {
      haystack += ' ' + (el.value || '');
    });
    tr.style.display = haystack.toLowerCase().includes(q) ? '' : 'none';
  });
}

function saveMappingRow(suName) {
  var rows = document.querySelectorAll('#mapping-tbody tr');
  var tr = null;
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].getAttribute('data-su') === suName) { tr = rows[i]; break; }
  }
  if (!tr) return;
  var matName = tr.querySelector('.u-mat').value.trim();
  if (!matName) { alert('请输入真实材料名'); return; }
  callSketchUp('save_mapping', JSON.stringify({
    su_name: suName,
    material_name: matName,
    platform_material_tag: (tr.querySelector('.u-platform-tag') || {}).value || '',
    category: tr.querySelector('.u-cat').value,
    unit: tr.querySelector('.u-unit').value,
    spec: (tr.querySelector('.u-spec') || {}).value || '',
    platform_sku_id: tr.dataset.skuId || '',
    platform_sku_code: tr.dataset.skuCode || '',
    platform_sku_name: tr.dataset.skuName || '',
    waste_rate: 0.0
  }));
}

function ignoreMaterial(suName) {
  callSketchUp('ignore_material', suName);
}

function deleteMapping(suName) {
  if (!confirm('删除映射：' + suName + '？')) return;
  callSketchUp('delete_mapping', suName);
}

// ---------------- Import / Export / Add ----------------
function importCsv() { callSketchUp('import_csv'); }
function exportCsv() { callSketchUp('export_csv'); }

function openAddMapping() {
  var suName = prompt('SU材质名:');
  if (!suName) return;
  var matName = prompt('真实材料名:');
  if (!matName) return;
  var cat = prompt('分类 (瓷砖/石材/涂料/木材/墙纸/玻璃/金属/其他):') || '其他';
  var spec = prompt('规格 (可选):') || '';
  callSketchUp('save_mapping', JSON.stringify({
    su_name: suName, material_name: matName, category: cat,
    platform_material_tag: '',
    unit: 'm²', spec: spec, waste_rate: 0.0
  }));
}

// ---------------- SKU 自动补全 ----------------
window._skuReqId = 0;
window._skuActiveRow = null;

(function() {
  var bound = false;
  window._ensureSkuCloser = function() {
    if (bound) return;
    bound = true;
    document.addEventListener('click', function(e) {
      document.querySelectorAll('.sku-dropdown').forEach(function(dd) {
        var tr = dd.closest('tr');
        if (!tr || !tr.contains(e.target)) dd.style.display = 'none';
      });
    });
  };
})();

function bindSkuAutocomplete(tr, onSelect) {
  var input = tr.querySelector('.u-sku');
  var dd = tr.querySelector('.sku-dropdown');
  if (!input || !dd) return;
  tr._skuOnSelect = onSelect; // 可选：选中 SKU 后的回调（映射页留空走保存按钮，模型视图直接持久化）
  window._ensureSkuCloser();
  var timer = null;
  input.addEventListener('input', function() {
    clearTimeout(timer);
    // 手动编辑即视为撤销已选，需重新从下拉选择才会写回 sku 字段
    tr.dataset.skuId = '';
    tr.dataset.skuCode = '';
    tr.dataset.skuName = '';
    var kw = input.value.trim();
    timer = setTimeout(function() {
      window._skuReqId += 1;
      window._skuActiveRow = tr;
      callSketchUp('search_skus', JSON.stringify({ keyword: kw, req_id: window._skuReqId }));
    }, 300);
  });
  input.addEventListener('focus', function() {
    if (dd.children.length > 0) dd.style.display = '';
  });
}

window.receiveSkuResults = function(data) {
  if (Number(data.req_id) !== window._skuReqId) return; // 丢弃过期响应
  var tr = window._skuActiveRow;
  if (!tr || !tr.isConnected) return; // 行已重建/分离则忽略
  var dd = tr.querySelector('.sku-dropdown');
  if (!dd) return;
  dd.innerHTML = '';
  if (data.error) {
    dd.appendChild(skuOption('查询失败：' + data.error, null, tr));
    dd.style.display = '';
    return;
  }
  var items = data.items || [];
  if (items.length === 0) {
    dd.appendChild(skuOption('无匹配产品', null, tr));
    dd.style.display = '';
    return;
  }
  items.forEach(function(it) {
    var label = (it.code || '') + ' · ' + (it.name || '');
    if (it.spec) label += ' · ' + it.spec;
    if (it.brand && it.brand.name) label += ' · ' + it.brand.name;
    dd.appendChild(skuOption(label, it, tr));
  });
  var foot = document.createElement('div');
  foot.className = 'sku-opt sku-foot';
  foot.textContent = '共 ' + (data.total || items.length) + ' 条';
  dd.appendChild(foot);
  dd.style.display = '';
};

function skuOption(label, item, tr) {
  var div = document.createElement('div');
  div.className = 'sku-opt';
  div.textContent = label;
  if (item) {
    div.onclick = function() {
      var input = tr.querySelector('.u-sku');
      input.value = (item.code || '') + ' ' + (item.name || '');
      tr.dataset.skuId = item.sku_id || '';
      tr.dataset.skuCode = item.code || '';
      tr.dataset.skuName = item.name || '';
      tr.querySelector('.sku-dropdown').style.display = 'none';
      if (tr._skuOnSelect) tr._skuOnSelect(item);
    };
  }
  return div;
}
