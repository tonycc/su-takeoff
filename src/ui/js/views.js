// src/ui/js/views.js — 统计视图：按组件、按材料、按区域

// ========================== 按组件视图 ==========================

function renderComponentView(data) {
  var items = data.items || [];
  var infos = data.materials_info || [];
  var linearityByMaterial = buildLinearityByMaterial(infos);
  var suToMapped = buildSuToMapped(infos);

  var matItems = items.filter(function(it) { return it.su_material; });
  var nomatItems = items.filter(function(it) { return !it.su_material; });
  var tab = window._faceMaterialTab || 'material';

  var html = '';

  html += '<div class="face-material-toggle">';
  html += '<button class="fmt-btn' + (tab === 'material' ? ' active' : '') +
    '" onclick="switchFaceMaterialTab(\'material\')">有材质面 · ' + matItems.length + ' 面</button>';
  html += '<button class="fmt-btn' + (tab === 'unmaterial' ? ' active' : '') +
    '" onclick="switchFaceMaterialTab(\'unmaterial\')">无材质面 · ' + nomatItems.length + ' 面</button>';
  html += '</div>';

  if (tab === 'material') {
    if (matItems.length > 0) {
      var matTree = buildComponentTree(matItems);
      aggregateComponentStats(matTree, linearityByMaterial);
      html += renderComponentTable(matTree, linearityByMaterial, suToMapped);
    } else {
      html += '<p class="hint">无有材质面</p>';
    }
  } else {
    if (nomatItems.length > 0) {
      var nomatTree = buildComponentTree(nomatItems);
      aggregateComponentStats(nomatTree, linearityByMaterial);
      html += renderComponentTable(nomatTree, linearityByMaterial, suToMapped);
    } else {
      html += '<p class="hint">无未赋材质面</p>';
    }
  }

  document.getElementById('page-component').innerHTML = html;

  document.querySelectorAll('#page-component .comp-row').forEach(function(row) {
    row.addEventListener('click', function() {
      var toggle = row.querySelector('.comp-toggle');
      if (toggle) toggleComponent(toggle.id.replace('-toggle', ''));
    });
  });
}

function buildLinearityByMaterial(infos) {
  var result = {};
  infos.forEach(function(info) {
    if (info.mapped_unit === 'm') result[info.su_name] = 'linear';
    else if (info.mapped_unit) result[info.su_name] = 'area';
  });
  return result;
}

function buildSuToMapped(infos) {
  var result = {};
  infos.forEach(function(info) {
    if (info.material_name) result[info.su_name] = info.material_name;
  });
  return result;
}

function isFaceLinear(face, linearityByMaterial) {
  var matVerdict = face.su_material && linearityByMaterial[face.su_material];
  if (matVerdict === 'linear') return true;
  if (matVerdict === 'area') return false;
  var w = face.width || 0;
  var h = face.height || 0;
  return w > 0 && h > 0 && (h / w) > 15;
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
  return root;
}

function aggregateComponentStats(node, linearityByMaterial) {
  linearityByMaterial = linearityByMaterial || {};
  var stats = {
    face_count: 0, total_area: 0.0,
    by_part: { floor: 0.0, wall: 0.0, ceiling: 0.0 },
    material_names: {}, material_count: 0,
    linear_length: 0.0, linear_face_count: 0,
    material_face_count: 0, unmaterial_face_count: 0
  };
  node.children.forEach(function(child) {
    var cs = aggregateComponentStats(child, linearityByMaterial);
    stats.face_count += cs.face_count;
    stats.total_area += cs.total_area;
    stats.by_part.floor += cs.by_part.floor;
    stats.by_part.wall += cs.by_part.wall;
    stats.by_part.ceiling += cs.by_part.ceiling;
    stats.linear_length += cs.linear_length;
    stats.linear_face_count += cs.linear_face_count;
    stats.material_face_count += cs.material_face_count;
    stats.unmaterial_face_count += cs.unmaterial_face_count;
    Object.keys(cs.material_names).forEach(function(m) { stats.material_names[m] = true; });
  });
  node.faces.forEach(function(face) {
    stats.face_count += 1;
    if (face.su_material) {
      stats.material_names[face.su_material] = true;
      stats.material_face_count += 1;
    } else {
      stats.unmaterial_face_count += 1;
    }
    if (isFaceLinear(face, linearityByMaterial)) {
      stats.linear_length += (face.height || 0);
      stats.linear_face_count += 1;
    } else {
      stats.total_area += face.qty || 0;
      if (face.part) stats.by_part[face.part] = (stats.by_part[face.part] || 0) + (face.qty || 0);
    }
  });
  stats.material_count = Object.keys(stats.material_names).length;
  stats.total_area = +stats.total_area.toFixed(2);
  stats.by_part.floor = +stats.by_part.floor.toFixed(2);
  stats.by_part.wall = +stats.by_part.wall.toFixed(2);
  stats.by_part.ceiling = +stats.by_part.ceiling.toFixed(2);
  stats.linear_length = +stats.linear_length.toFixed(2);
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

function renderComponentTable(tree, linearityByMaterial, suToMapped) {
  if (tree.faces.length > 0) {
    var orphan = {
      name: '模型根层级', path: [], path_ids: [], faces: tree.faces,
      children: [], childrenMap: {}
    };
    aggregateComponentStats(orphan, linearityByMaterial);
    tree.children.unshift(orphan);
    tree.faces = [];
  }
  var html = '<table><thead><tr>' +
    '<th style="width:40px">#</th>' +
    '<th>组件 / 面</th>' +
    '<th style="text-align:right">面数</th>' +
    '<th style="text-align:right">面积(m²)</th>' +
    '<th style="text-align:right">长度(m)</th>' +
    '<th style="text-align:right">地面</th>' +
    '<th style="text-align:right">墙面</th>' +
    '<th style="text-align:right">天花</th>' +
    '<th style="text-align:right">材质数</th>' +
    '<th>材质</th>' +
    '<th>映射材料</th>' +
    '</tr></thead><tbody>';
  var rootId = 'comp-root';
  var counter = { n: 0 };
  tree.children.forEach(function(child) {
    html += renderComponentNode(child, 1, rootId, counter, linearityByMaterial, suToMapped);
  });
  html += '</tbody></table>';
  return html;
}

function renderComponentNode(node, depth, parentId, counter, linearityByMaterial, suToMapped) {
  var html = '';
  var idKey = (node.path_ids || []).join('-') || 'noid-' + node.path.join('-');
  var nodeId = 'comp-' + idKey.replace(/[^a-zA-Z0-9\-]/g, '_');
  var indent = depth * 18;
  var hasChildren = node.children.length > 0 || node.faces.length > 0;
  var hidden = depth > 1 ? ' style="display:none"' : '';
  var partBadge = dominantPartBadge(node.stats);

  var mats = Object.keys(node.stats.material_names);
  var mappedNames = mats.map(function(m) { return (suToMapped || {})[m] || '—'; });

  counter.n += 1;
  html += '<tr class="comp-row" data-depth="' + depth + '" data-parent="' + parentId + '"' + hidden + '>' +
    '<td style="text-align:right; color:#6c7086; font-size:11px;">' + counter.n + '</td>' +
    '<td style="padding-left:' + (indent + 6) + 'px">';
  if (hasChildren) {
    html += '<span class="comp-toggle" id="' + nodeId + '-toggle">' + (depth === 1 ? '▾' : '▸') + '</span> ';
  } else {
    html += '<span class="comp-toggle-empty"></span> ';
  }
  var areaCell = node.stats.total_area > 0 ? node.stats.total_area : '—';
  var lengthCell = node.stats.linear_length > 0 ? node.stats.linear_length : '—';
  html += esc(node.name) + partBadge + '</td>' +
    '<td style="text-align:right">' + node.stats.face_count + '</td>' +
    '<td style="text-align:right">' + areaCell + '</td>' +
    '<td style="text-align:right">' + lengthCell + '</td>' +
    '<td style="text-align:right">' + (node.stats.by_part.floor > 0 ? node.stats.by_part.floor : '—') + '</td>' +
    '<td style="text-align:right">' + (node.stats.by_part.wall > 0 ? node.stats.by_part.wall : '—') + '</td>' +
    '<td style="text-align:right">' + (node.stats.by_part.ceiling > 0 ? node.stats.by_part.ceiling : '—') + '</td>' +
    '<td style="text-align:right">' + node.stats.material_count + '</td>' +
    '<td style="font-size:11px">' + esc(mats.join(', ') || '—') + '</td>' +
    '<td style="font-size:11px">' + esc(mappedNames.join(', ') || '—') + '</td>' +
    '</tr>';

  node.children.forEach(function(child) {
    html += renderComponentNode(child, depth + 1, nodeId, counter, linearityByMaterial, suToMapped);
  });
  node.faces.forEach(function(face) {
    counter.n += 1;
    html += renderFaceRow(face, depth + 1, nodeId, counter.n, linearityByMaterial, suToMapped);
  });
  return html;
}

function renderFaceRow(face, depth, parentId, serial, linearityByMaterial, suToMapped) {
  var indent = depth * 18;
  var suName = face.su_material || '';
  var mappedName = suName ? ((suToMapped || {})[suName] || '—') : '—';
  var qty = +(face.qty || 0).toFixed(2);
  var h = face.height || 0;
  var isLinear = isFaceLinear(face, linearityByMaterial || {});
  var areaCell = isLinear ? '—' : qty;
  var lengthCell = isLinear ? (+h.toFixed(2)) : '—';
  var floorCell = (!isLinear && face.part === 'floor') ? qty : '—';
  var wallCell = (!isLinear && face.part === 'wall') ? qty : '—';
  var ceilingCell = (!isLinear && face.part === 'ceiling') ? qty : '—';
  return '<tr class="face-row" data-depth="' + depth + '" data-parent="' + parentId + '" style="display:none">' +
    '<td style="text-align:right; font-size:10px; color:#6c7086;">' + (serial || '') + '</td>' +
    '<td style="padding-left:' + (indent + 6) + 'px; font-size:10px; color:#6c7086;">面 #' + esc(face.face_id) +
      ' <button onclick="locateFace(\'' + face.face_id + '\')" style="font-size:10px;padding:0 4px">🎯</button></td>' +
    '<td></td>' +
    '<td style="text-align:right">' + areaCell + '</td>' +
    '<td style="text-align:right">' + lengthCell + '</td>' +
    '<td style="text-align:right">' + floorCell + '</td>' +
    '<td style="text-align:right">' + wallCell + '</td>' +
    '<td style="text-align:right">' + ceilingCell + '</td>' +
    '<td></td>' +
    '<td style="font-size:10px">' + esc(face.su_material || '未赋材质') + '</td>' +
    '<td style="font-size:10px">' + esc(mappedName) + '</td>' +
    '<td></td>' +
    '</tr>';
}

// ========================== 按材料视图 ==========================

function renderMaterialView(data) {
  var container = document.getElementById('page-material');
  var html = '<table id="material-table"><thead><tr>' +
      '<th style="width:40px">#</th>' +
      '<th style="width:4%">状态</th>' +
      '<th style="width:18%">SU材质</th>' +
      '<th style="width:12%">面数/面积</th>' +
      '<th style="width:14%">部位分布</th>' +
      '<th>真实材料名</th>' +
      '<th>分类</th>' +
      '<th>规格</th>' +
      '<th style="width:6%">单位</th>' +
      '<th>损耗率</th>' +
      '<th style="width:5%">定位</th>' +
    '</tr></thead><tbody id="material-tbody"></tbody></table>';
  container.innerHTML = html;
  renderMaterialTableBody(data);
}

function renderMaterialTableBody(data) {
  var tbody = document.getElementById('material-tbody');
  if (!tbody) return;
  var unresolvedSet = {}; (data.unresolved || []).forEach(function(n) { unresolvedSet[n] = true; });
  var ignoredSet = {}; (data.ignored || []).forEach(function(n) { ignoredSet[n] = true; });
  var partLabels = { floor: '地', wall: '墙', ceiling: '顶' };

  tbody.innerHTML = '';
  var serial = 0;
  (data.materials_info || []).forEach(function(info) {
    var name = info.su_name;
    var isIgnored = !!ignoredSet[name];
    var isUnresolved = !!unresolvedSet[name];
    var isMapped = !isIgnored && !isUnresolved;

    serial += 1;

    var status = isMapped
      ? '<span class="tag tag-mapped">✓</span>'
      : (isIgnored ? '<span class="tag tag-ignored">○</span>' : '<span class="tag tag-unresolved">●</span>');

    var c = info.color || {};
    var swatch = info.color
      ? '<span class="swatch" style="background:rgba(' + c.r + ',' + c.g + ',' + c.b + ',' + (c.a || 1) + ')"></span>'
      : '<span class="swatch swatch-empty">?</span>';

    var partsHtml = '';
    if (info.parts) {
      Object.keys(info.parts).forEach(function(p) {
        partsHtml += '<span class="pill pill-' + p + '">' + (partLabels[p] || p) + ' ' + info.parts[p] + '</span>';
      });
    }

    var suggested = info.suggested_unit || 'm²';
    var quantitySummary = suggested === 'm'
      ? (info.face_count || 0) + ' 面 / ' + (info.total_length || 0) + ' m'
      : (info.face_count || 0) + ' 面 / ' + (info.total_area || 0) + ' m²';

    var matName = info.material_name || (isUnresolved ? '—' : '');
    var category = info.category || '—';
    var spec = info.spec || '—';
    var unit = info.mapped_unit || info.suggested_unit || 'm²';
    var wasteStr = info.waste_rate != null ? (info.waste_rate * 100).toFixed(0) + '%' : '5%';

    var tr = document.createElement('tr');
    tr.className = 'row-' + (isMapped ? 'mapped' : (isIgnored ? 'ignored' : 'unresolved'));
    tr.innerHTML =
      '<td style="text-align:right; color:#6c7086; font-size:11px;">' + serial + '</td>' +
      '<td>' + status + '</td>' +
      '<td><div class="u-name-row">' + swatch +
        '<span class="u-name" title="' + esc(name) + '">' + esc(name) + '</span></div></td>' +
      '<td>' + quantitySummary + '</td>' +
      '<td>' + partsHtml + '</td>' +
      '<td>' + esc(matName) + '</td>' +
      '<td>' + esc(category) + '</td>' +
      '<td>' + esc(spec) + '</td>' +
      '<td>' + esc(unit) + '</td>' +
      '<td>' + wasteStr + '</td>' +
      '<td><button onclick="locateMaterial(\'' + escAttr(name) + '\')">🎯</button></td>';
    tbody.appendChild(tr);
  });
}

// ========================== 按区域视图 ==========================

function renderZoneView(data) {
  var container = document.getElementById('page-zone');
  if (!container) return;

  var partLabels = { floor: '地面', wall: '墙面', ceiling: '天花' };
  var partOrder = ['floor', 'wall', 'ceiling'];
  var items = data.items || [];
  var matItems = items.filter(function(it) { return it.su_material; });
  var nomatItems = items.filter(function(it) { return !it.su_material; });
  var tab = window._faceMaterialTab || 'material';

  var html = '';
  var partFilter = window._zonePartFilter || 'all';

  html += '<div class="toolbar" style="gap:8px;margin-bottom:10px">';
  html += '<button class="fmt-btn' + (tab === 'material' ? ' active' : '') +
    '" onclick="switchFaceMaterialTab(\'material\')">有材质面 · ' + matItems.length + '</button>';
  html += '<button class="fmt-btn' + (tab === 'unmaterial' ? ' active' : '') +
    '" onclick="switchFaceMaterialTab(\'unmaterial\')">无材质面 · ' + nomatItems.length + '</button>';
  html += '<span style="color:#45475a;margin:0 4px">│</span>';
  html += '<span style="font-size:12px;color:#6c7086">部位:</span>' +
    '<select onchange="setZonePartFilter(this.value)" style="padding:4px 8px;border:1px solid #45475a;border-radius:4px;background:#1e1e2e;color:#cdd6f4;font-size:12px">' +
      '<option value="all"' + (partFilter === 'all' ? ' selected' : '') + '>全部</option>' +
      '<option value="floor"' + (partFilter === 'floor' ? ' selected' : '') + '>地面</option>' +
      '<option value="wall"' + (partFilter === 'wall' ? ' selected' : '') + '>墙面</option>' +
      '<option value="ceiling"' + (partFilter === 'ceiling' ? ' selected' : '') + '>天花</option>' +
    '</select>' +
    '<span style="flex:1"></span>' +
    '<button onclick="exportZoneCsv()" style="font-size:11px">导出 CSV</button>' +
    '</div>';

  if (tab === 'material') {
    if (matItems.length > 0) {
      html += renderSimpleZoneTable(matItems, partLabels, partOrder, partFilter, true);
    } else {
      html += '<p class="hint">无有材质面</p>';
    }
  } else {
    if (nomatItems.length > 0) {
      html += renderSimpleZoneTable(nomatItems, partLabels, partOrder, partFilter, false);
    } else {
      html += '<p class="hint">无未赋材质面</p>';
    }
  }

  container.innerHTML = html;
}

function renderSimpleZoneTable(items, partLabels, partOrder, partFilter, hasMaterial) {
  var groups = {};
  var keys = [];
  items.forEach(function(it) {
    var space = (it.component_path && it.component_path[0]) || '未分组';
    var part = it.part || 'wall';
    if (partFilter !== 'all' && part !== partFilter) return;
    var suMat = hasMaterial ? (it.su_material || '') : '';
    var key = hasMaterial ? (space + '|' + part + '|' + suMat) : (space + '|' + part);
    if (!groups[key]) {
      groups[key] = { space: space, part: part, su_material: suMat, count: 0, area: 0 };
      keys.push(key);
    }
    groups[key].count += 1;
    groups[key].area += it.qty || 0;
  });

  if (keys.length === 0) return '<p class="hint">无匹配数据</p>';

  var rows = [];
  keys.forEach(function(key) {
    var g = groups[key];
    rows.push({ space: g.space, part: g.part,
      su_material: g.su_material, count: g.count, area: +g.area.toFixed(2) });
  });

  var totalCount = 0, totalArea = 0;
  rows.forEach(function(r) { totalCount += r.count; totalArea += r.area; });

  var colSpan = hasMaterial ? 5 : 4;
  var html = '<table><thead><tr>' +
    '<th style="width:40px">#</th><th>功能区域</th><th>区域分项</th>';
  if (hasMaterial) html += '<th>SU材质</th>';
  html += '<th style="text-align:right">面数</th><th style="text-align:right">面积(m²)</th>' +
    '</tr></thead><tbody>';

  var spaceSpans = [], partSpans = [];
  var si = 0;
  while (si < rows.length) {
    var sj = si + 1;
    while (sj < rows.length && rows[sj].space === rows[si].space) sj++;
    var pi = si;
    while (pi < sj) {
      var pj = pi + 1;
      while (pj < sj && rows[pj].part === rows[pi].part) pj++;
      partSpans.push({ start: pi, count: pj - pi });
      pi = pj;
    }
    spaceSpans.push({ start: si, count: sj - si });
    si = sj;
  }

  var sSpanIdx = 0, pSpanIdx = 0, serial = 0;
  for (var r = 0; r < rows.length; r++) {
    serial++;
    var row = rows[r];
    var sSpan = spaceSpans[sSpanIdx];
    var pSpan = partSpans[pSpanIdx];
    if (r >= sSpan.start + sSpan.count - 1) sSpanIdx++;
    if (r >= pSpan.start + pSpan.count - 1) pSpanIdx++;

    html += '<tr>';
    html += '<td style="text-align:right;color:#6c7086;font-size:11px">' + serial + '</td>';
    if (r === sSpan.start) {
      html += '<td rowspan="' + sSpan.count + '">' + esc(row.space) + '</td>';
    }
    if (r === pSpan.start) {
      html += '<td rowspan="' + pSpan.count + '"><span class="pill pill-' + row.part + '">' + (partLabels[row.part] || row.part) + '</span></td>';
    }
    if (hasMaterial) html += '<td>' + esc(row.su_material) + '</td>';
    html += '<td style="text-align:right">' + row.count + '</td>' +
      '<td style="text-align:right">' + row.area.toFixed(2) + '</td></tr>';
  }

  html += '<tr class="zone-total-row"><td></td>' +
    '<td colspan="' + colSpan + '"><strong>合计</strong> — ' +
    totalCount + ' 面 / ' + totalArea.toFixed(2) + ' m²</td></tr>';
  html += '</tbody></table>';
  return html;
}

function exportZoneCsv() {
  var data = window._workbench;
  if (!data) return;
  var items = data.items || [];
  if (items.length === 0) return;

  var partLabels = { floor: '地面', wall: '墙面', ceiling: '天花' };

  var groups = {};
  var keys = [];
  items.forEach(function(it) {
    var space = (it.component_path && it.component_path[0]) || '未分组';
    var part = it.part || 'wall';
    var suMat = it.su_material || '(无材质)';
    var key = space + '|' + part + '|' + suMat;
    if (!groups[key]) {
      groups[key] = { space: space, part: part, su_material: suMat, count: 0, area: 0 };
      keys.push(key);
    }
    groups[key].count += 1;
    groups[key].area += it.qty || 0;
  });

  var lines = [];
  lines.push(['功能区域', '区域分项', 'SU材质', '面数', '面积(m²)'].join(','));
  keys.forEach(function(key) {
    var g = groups[key];
    lines.push([
      g.space, partLabels[g.part] || g.part, g.su_material, g.count, g.area.toFixed(2)
    ].map(csvEscape).join(','));
  });

  var csv = '﻿' + lines.join('\n');
  var blob = new Blob([csv], { type: 'text/csv;charset=utf-8' });
  var url = URL.createObjectURL(blob);
  var a = document.createElement('a');
  a.href = url;
  a.download = 'zone_export.csv';
  a.click();
  URL.revokeObjectURL(url);
}
