// src/ui/js/model_view.js — 模型视图：统一树 + 聚合档位 + 按位置分组

// ---------------- State ----------------
window._mv = {
  level: null,
  showEmpty: false,
  showHidden: false,
  mergeSame: false,
  searchQuery: '',
  expandedNodes: {},
  sortCol: null,
  sortDir: 'asc'
};

// ---------------- Node classification ----------------
function classifyNodes(data) {
  if (data._classification) return;
  var cls = {};
  var usagesByEid = data._usagesByEntityId || {};
  var unresolvedSet = {};
  (data.unresolved || []).forEach(function(n) { unresolvedSet[n] = true; });
  var ignoredSet = {};
  (data.ignored || []).forEach(function(n) { ignoredSet[n] = true; });

  function walk(node) {
    if (node.hidden) {
      cls[node.entity_id] = 'hidden_skipped';
      node.children.forEach(walk);
      return;
    }
    var usages = usagesByEid[node.entity_id] || [];
    var hasFace = false, hasInst = false;
    usages.forEach(function(u) {
      if (u.is_instance) hasInst = true;
      else hasFace = true;
    });
    var childTags = [];
    node.children.forEach(function(c) {
      walk(c);
      childTags.push(cls[c.entity_id]);
    });
    var childHasStats = childTags.some(function(t) {
      return t === 'has_face_items' || t === 'has_instance_items' ||
             t === 'has_descendant_stats' || t === 'actionable_empty';
    });
    var tag;
    if (hasFace) {
      tag = 'has_face_items';
    } else if (hasInst && !hasFace) {
      tag = 'has_instance_items';
    } else if (childHasStats) {
      tag = 'has_descendant_stats';
    } else if (node.kind === 'component_instance') {
      tag = 'actionable_empty';
    } else {
      tag = 'pure_organizational';
    }
    cls[node.entity_id] = tag;
  }
  walk(data.hierarchy);
  data._classification = cls;
}

// ---------------- Merge helper ----------------
// 返回合并键：同名组件定义或同名群组
function getMergeKey(node) {
  if (node.kind === 'component_instance' && node.definition_name) {
    return 'comp:' + node.definition_name;
  }
  if (node.kind === 'group' && node.name) {
    return 'grp:' + node.name;
  }
  return null; // 不可合并（根节点、无定义名等）
}

// 合并多个节点的 stats（rollupStats 的聚合版）
function mergeStats(nodes, data) {
  var merged = { area: 0, length: 0, volume: 0, count: 0, floor: 0, wall: 0, ceiling: 0, unresolvedCount: 0 };
  nodes.forEach(function(n) {
    var s = rollupStats(n, data);
    merged.area    += s.area;
    merged.length  += s.length;
    merged.volume  += s.volume;
    merged.count   += s.count;
    merged.floor   += s.floor;
    merged.wall    += s.wall;
    merged.ceiling += s.ceiling;
    merged.unresolvedCount += s.unresolvedCount;
  });
  return merged;
}

// 合并多个节点的 selfUsages
function mergeSelfUsages(nodes, data) {
  var usagesByEid = data._usagesByEntityId || {};
  var result = [];
  var seenMat = {};
  nodes.forEach(function(n) {
    (usagesByEid[n.entity_id] || []).forEach(function(u) {
      var key = u.su_material + '|' + (u.is_instance ? 'inst' : 'face') + '|' + (u.unit || '');
      if (!seenMat[key]) {
        seenMat[key] = true;
        result.push(u);
      }
    });
  });
  return result;
}

// ---------------- Rollup stats ----------------
function rollupStats(node, data) {
  var usagesByEid = data._usagesByEntityId || {};
  var cls = data._classification || {};
  var unresolvedSet = {};
  (data.unresolved || []).forEach(function(n) { unresolvedSet[n] = true; });
  var ignoredSet = {};
  (data.ignored || []).forEach(function(n) { ignoredSet[n] = true; });
  var materials = {};
  var result = { area: 0, length: 0, volume: 0, count: 0, floor: 0, wall: 0, ceiling: 0, matCount: 0, unresolvedCount: 0 };

  // Self usages
  var selfUsages = usagesByEid[node.entity_id] || [];
  selfUsages.forEach(function(u) {
    if (u.is_instance) {
      result.count += u.qty_count || u.qty || 0;
    } else {
      var area = u.qty_area || 0;
      var length = u.qty_length || 0;
      var count = u.qty_count || 0;
      if (area === 0 && length === 0 && count === 0) {
        if (u.unit === 'm') length = u.qty;
        else if (u.unit !== 'm³') area = u.qty;
      }
      result.area += area;
      result.length += length * 1000;
      result.volume += u.qty_volume || 0;
      result.count += count;
      if (u.by_part) {
        result.floor += u.by_part.floor || 0;
        result.wall += u.by_part.wall || 0;
        result.ceiling += u.by_part.ceiling || 0;
      }
      if (!ignoredSet[u.su_material]) {
        materials[u.su_material] = true;
        if (unresolvedSet[u.su_material]) result.unresolvedCount++;
      }
    }
  });

  // Recursive children
  node.children.forEach(function(c) {
    if (c.hidden && !_mv.showHidden) return;
    var tag = cls[c.entity_id];
    if (tag === 'hidden_skipped') return;
    if (tag === 'pure_organizational' && !_mv.showEmpty) return;
    var child = rollupStats(c, data);
    result.area += child.area;
    result.length += child.length;
    result.volume += child.volume;
    result.count += child.count;
    result.floor += child.floor;
    result.wall += child.wall;
    result.ceiling += child.ceiling;
    result.unresolvedCount += child.unresolvedCount;
    for (var m in child._materials) materials[m] = true;
  });
  result._materials = materials;
  result.matCount = Object.keys(materials).length;
  return result;
}

// ---------------- Default level ----------------
function renderToolbar(data, container) {
  var tb = document.createElement('div');
  tb.className = 'mv-toolbar';

  // Row 1: switches + search + export
  var row2 = document.createElement('div');
  row2.className = 'mv-toolbar-row';

  var swWrap = document.createElement('div');
  swWrap.className = 'mv-switches';
  var swLabel = document.createElement('span');
  swLabel.className = 'mv-toolbar-label';
  swLabel.textContent = '显示:';
  swWrap.appendChild(swLabel);

  var switches = [
    { key: 'showEmpty', label: '空容器' },
    { key: 'showHidden', label: '隐藏项' },
    { key: 'mergeSame', label: '合并相同组件' }
  ];
  switches.forEach(function(sw) {
    var cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.checked = _mv[sw.key];
    cb.className = 'mv-switch';
    cb.id = 'mv-sw-' + sw.key;
    cb.onchange = function() {
      _mv[sw.key] = cb.checked;
      renderPositionView(data);
    };
    var lbl = document.createElement('label');
    lbl.className = 'mv-switch-label';
    lbl.textContent = sw.label;
    lbl.setAttribute('for', cb.id);
    swWrap.appendChild(cb);
    swWrap.appendChild(lbl);
  });
  row2.appendChild(swWrap);

  // Search
  var searchWrap = document.createElement('div');
  searchWrap.className = 'mv-search-wrap';
  var searchInput = document.createElement('input');
  searchInput.type = 'text';
  searchInput.className = 'mv-search';
  searchInput.placeholder = '搜索名称/材质…';
  searchInput.value = _mv.searchQuery;
  searchInput.oninput = function() {
    _mv.searchQuery = searchInput.value.trim();
    renderPositionView(data);
  };
  searchWrap.appendChild(searchInput);
  row2.appendChild(searchWrap);

  // Export
  var exportBtn = document.createElement('button');
  exportBtn.className = 'mv-export-btn';
  exportBtn.textContent = '⤓ 导出';
  exportBtn.onclick = function() { exportModelCsv(data); };
  row2.appendChild(exportBtn);
  tb.appendChild(row2);

  container.appendChild(tb);
}

// ---------------- Position mode: tree table ----------------
// Sortable column keys mapped to column index
var POS_SORT_COLS = { 1: 'name', 3: 'tag', 4: 'area', 5: 'length', 6: 'volume', 7: 'count', 8: 'floor', 9: 'wall', 10: 'ceiling', 11: 'unresolved' };

function renderPositionTable(data, container) {
  var cls = data._classification;
  var usagesByEid = data._usagesByEntityId;
  var hierarchy = data.hierarchy;

  if (!hierarchy) {
    var err = document.createElement('div');
    err.className = 'mv-error';
    err.textContent = '需要更新插件（hierarchy 数据缺失）';
    container.appendChild(err);
    return;
  }

  var table = document.createElement('table');
  table.className = 'mv-table';

  // Header with sort indicators
  var thead = document.createElement('thead');
  var hrow = document.createElement('tr');
  var cols = ['#', '名称 / 材质', '产品信息', '算量标签', '面积(m²)', '长度(mm)', '体积(m³)', '件数', '地面', '墙面', '天花', '待处理', '操作'];
  cols.forEach(function(c, i) {
    var th = document.createElement('th');
    if (i >= 3 && i <= 9) th.className = 'mv-th-num';
    var sortKey = POS_SORT_COLS[i];
    if (sortKey) {
      th.className = (th.className ? th.className + ' ' : '') + 'mv-th-sortable';
      th.onclick = function() {
        if (_mv.sortCol === sortKey) {
          _mv.sortDir = _mv.sortDir === 'asc' ? 'desc' : 'asc';
        } else {
          _mv.sortCol = sortKey;
          _mv.sortDir = 'asc';
        }
        renderModelView(data || window._workbench);
      };
      // Sort indicator
      if (_mv.sortCol === sortKey) {
        var indicator = document.createElement('span');
        indicator.className = 'mv-sort-indicator';
        indicator.textContent = _mv.sortDir === 'asc' ? ' ↑' : ' ↓';
        th.appendChild(document.createTextNode(c));
        th.appendChild(indicator);
      } else {
        th.textContent = c;
      }
    } else {
      th.textContent = c;
    }
    hrow.appendChild(th);
  });
  thead.appendChild(hrow);
  table.appendChild(thead);

  var tbody = document.createElement('tbody');
  var seq = 0;

  // Search matching
  var searchMatches = {};
  if (_mv.searchQuery) {
    findSearchMatches(hierarchy, _mv.searchQuery, data, searchMatches);
  }

  // Sort hierarchy (siblings only, preserving tree structure)
  var sortedHierarchy = sortHierarchySiblings(hierarchy, data, cls);

  renderNodeRows(sortedHierarchy, data, cls, usagesByEid, tbody, seq, searchMatches);
  table.appendChild(tbody);
  container.appendChild(table);
}

// Sort sibling nodes at each level without breaking tree structure
function sortHierarchySiblings(node, data, cls) {
  if (!_mv.sortCol) return node;
  var sorted = { name: node.name, entity_id: node.entity_id, kind: node.kind,
    definition_name: node.definition_name, depth: node.depth, hidden: node.hidden,
    children: node.children.map(function(c) { return sortHierarchySiblings(c, data, cls); }) };

  if (sorted.children.length > 1) {
    sorted.children.sort(function(a, b) {
      var aVisible = isNodeVisibleForSort(a, cls);
      var bVisible = isNodeVisibleForSort(b, cls);
      if (aVisible !== bVisible) return aVisible ? -1 : 1;

      var aVal = getSortValue(a, data, cls, _mv.sortCol);
      var bVal = getSortValue(b, data, cls, _mv.sortCol);
      var cmp = 0;
      if (typeof aVal === 'string' && typeof bVal === 'string') {
        cmp = aVal.localeCompare(bVal, 'zh');
      } else {
        cmp = (aVal || 0) - (bVal || 0);
      }
      return _mv.sortDir === 'desc' ? -cmp : cmp;
    });
  }
  return sorted;
}

function isNodeVisibleForSort(node, cls) {
  if (node.hidden && !_mv.showHidden) return false;
  var tag = cls[node.entity_id];
  if (tag === 'hidden_skipped') return false;
  if (tag === 'pure_organizational' && !_mv.showEmpty) return false;
  return true;
}

function getSortValue(node, data, cls, col) {
  if (col === 'name') return node.name;
  var stats = rollupStats(node, data);
  return stats[col] || 0;
}

function findSearchMatches(node, query, data, matches) {
  var usagesByEid = data._usagesByEntityId || {};
  var nameMatch = node.name.toLowerCase().indexOf(query.toLowerCase()) >= 0;
  var matMatch = false;
  var usages = usagesByEid[node.entity_id] || [];
  usages.forEach(function(u) {
    if (u.su_material && u.su_material.toLowerCase().indexOf(query.toLowerCase()) >= 0) matMatch = true;
  });
  if (nameMatch || matMatch) {
    matches[node.entity_id] = true;
  }
  node.children.forEach(function(c) {
    findSearchMatches(c, query, data, matches);
    if (matches[c.entity_id]) matches[node.entity_id] = true;
  });
}

function getSelfMatCount(selfUsages) {
  var mats = {};
  selfUsages.forEach(function(u) {
    if (!u.is_instance && u.su_material) mats[u.su_material] = true;
  });
  return Object.keys(mats).length;
}

// 规格分组行：按面尺寸（宽×高 mm）聚合
function renderSpecGroupRow(dimLabel, faces, usage, depth, matKey, tbody) {
  var specKey = matKey + '|spec|' + dimLabel;
  _mv.expandedSpecs = _mv.expandedSpecs || {};
  var isExpanded = _mv.expandedSpecs[specKey];

  // 聚合组内数据
  var totalArea = 0, totalLength = 0, totalVolume = 0;
  var partFloor = 0, partWall = 0, partCeiling = 0;
  faces.forEach(function(f) {
    var fm = f.resolved_method || (usage.unit === 'm' ? 'length' : 'area');
    if (fm === 'length') {
      totalLength += f.height || 0;
    } else if (fm === 'volume') {
      totalVolume += f.volume || 0;
    } else {
      totalArea += f.area || 0;
    }
    if (f.part === 'floor') partFloor += f.area || 0;
    else if (f.part === 'wall') partWall += f.area || 0;
    else if (f.part === 'ceiling') partCeiling += f.area || 0;
  });

  var row = document.createElement('tr');
  row.className = 'mv-face-row';

  var tdSeq = document.createElement('td');
  tdSeq.className = 'mv-col-seq mv-face-seq';
  row.appendChild(tdSeq);

  var tdName = document.createElement('td');
  tdName.className = 'mv-col-name mv-face-name';
  var indent = document.createElement('span');
  indent.className = 'mv-indent';
  indent.style.paddingLeft = (depth * 16) + 'px';
  tdName.appendChild(indent);
  var toggle = document.createElement('span');
  toggle.className = 'mv-toggle';
  toggle.textContent = isExpanded ? '▾' : '▸';
  toggle.onclick = function(e) {
    e.stopPropagation();
    _mv.expandedSpecs[specKey] = !isExpanded;
    renderModelView(window._workbench);
  };
  tdName.appendChild(toggle);
  tdName.appendChild(document.createTextNode(' ' + dimLabel + ' mm'));
  var cnt = document.createElement('span');
  cnt.className = 'mv-mat-summary-faces';
  cnt.textContent = ' ' + faces.length + '面';
  tdName.appendChild(cnt);
  row.appendChild(tdName);

  var tdInfo = document.createElement('td');
  row.appendChild(tdInfo);

  var tdTag = document.createElement('td');
  tdTag.className = 'mv-col-tag';
  row.appendChild(tdTag);

  var isLinear = usage.unit === 'm';
  var isVolume = usage.unit === 'm³';
  var numCols = [
    (!isLinear && !isVolume && totalArea > 0) ? fmtNum(totalArea) : '-',
    totalLength > 0 ? fmtNum(totalLength * 1000) : '-',
    totalVolume > 0 ? fmtNum(totalVolume) : '-',
    '-',
    fmtNum(partFloor),
    fmtNum(partWall),
    fmtNum(partCeiling),
    '-'
  ];
  numCols.forEach(function(v) {
    var td = document.createElement('td');
    td.className = 'mv-col-num mv-face-num';
    td.textContent = v;
    row.appendChild(td);
  });

  var tdAct = document.createElement('td');
  tdAct.className = 'mv-col-act';
  row.appendChild(tdAct);

  tbody.appendChild(row);

  // 展开后渲染每个面
  if (isExpanded) {
    faces.forEach(function(f) {
      renderFaceDetailRow(f, usage, depth + 1, tbody);
    });
  }
}

function renderFaceDetailRow(face, usage, depth, tbody) {
  var row = document.createElement('tr');
  row.className = 'mv-face-row';
  row.dataset.faceId = face.face_id;
  if (_mv.highlightFaceKey) {
    var faceKey = face.face_id + ':' + (face.path_ids || []).join(',');
    if (_mv.highlightFaceKey === faceKey) {
      row.classList.add('mv-highlight');
    }
  }

  var tdSeq = document.createElement('td');
  tdSeq.className = 'mv-col-seq mv-face-seq';
  row.appendChild(tdSeq);

  var tdName = document.createElement('td');
  tdName.className = 'mv-col-name mv-face-name';
  var indent = document.createElement('span');
  indent.className = 'mv-indent';
  indent.style.paddingLeft = (depth * 16) + 'px';
  tdName.appendChild(indent);
  var bullet = document.createElement('span');
  bullet.className = 'mv-face-bullet';
  bullet.textContent = '└ ';
  tdName.appendChild(bullet);
  var dims = (face.width && face.height) ? '  ' + Math.round(face.width * 1000) + '×' + Math.round(face.height * 1000) + ' mm' : '';
  tdName.appendChild(document.createTextNode('#' + face.face_id + dims));
  row.appendChild(tdName);

  // 产品信息（空白列）
  var tdInfo = document.createElement('td');
  row.appendChild(tdInfo);

  // 空标记列（面对齐表头）
  var tdTag = document.createElement('td');
  tdTag.className = 'mv-col-tag';
  row.appendChild(tdTag);

  // 按面自身的 resolved_method 判定，而非 usage 的 unit（同材质合并后可能混合）
  var faceMethod = face.resolved_method || (usage.unit === 'm' ? 'length' : 'area');
  var isLinear = faceMethod === 'length';
  var isVolume = faceMethod === 'volume';
  var partArea = {};
  partArea[face.part] = face.area;

  var tdArea = document.createElement('td');
  tdArea.className = 'mv-col-num mv-face-num';
  tdArea.textContent = (isLinear || isVolume) ? '-' : fmtNum(face.area);
  row.appendChild(tdArea);

  var tdLen = document.createElement('td');
  tdLen.className = 'mv-col-num mv-face-num';
  tdLen.textContent = isLinear && face.height ? fmtNum(face.height * 1000) : '-';
  row.appendChild(tdLen);

  var tdVol = document.createElement('td');
  tdVol.className = 'mv-col-num mv-face-num';
  tdVol.textContent = isVolume && face.volume ? fmtNum(face.volume) : '-';
  row.appendChild(tdVol);

  var tdCount = document.createElement('td');
  tdCount.className = 'mv-col-num mv-face-num';
  tdCount.textContent = '-';
  row.appendChild(tdCount);

  ['floor', 'wall', 'ceiling'].forEach(function(pk) {
    var td = document.createElement('td');
    td.className = 'mv-col-num mv-face-num';
    td.textContent = fmtNum(partArea[pk] || 0);
    row.appendChild(td);
  });

  var tdUnr = document.createElement('td');
  tdUnr.className = 'mv-col-num mv-face-num';
  tdUnr.textContent = '-';
  row.appendChild(tdUnr);

  var tdAct = document.createElement('td');
  tdAct.className = 'mv-col-act';
  var locateBtn = document.createElement('button');
  locateBtn.className = 'mv-locate-btn mv-face-locate';
  locateBtn.textContent = '⌖';
  locateBtn.title = '定位到面';
  locateBtn.onclick = function() { locateFace(face.face_id, face.path_ids || []); };
  tdAct.appendChild(locateBtn);
  row.appendChild(tdAct);

  tbody.appendChild(row);
}

function renderMaterialSummaryRow(usage, depth, parentEntityId, tbody, data) {
  var matKey = parentEntityId + ':' + usage.su_material;
  var isMatExpanded = _mv.expandedMaterials && _mv.expandedMaterials[matKey];
  var isLinear = usage.unit === 'm';
  var unresolvedSet = {};
  (data.unresolved || []).forEach(function(n) { unresolvedSet[n] = true; });
  var ignoredSet = {};
  (data.ignored || []).forEach(function(n) { ignoredSet[n] = true; });
  var matStatus = 'mapped';
  if (ignoredSet[usage.su_material]) matStatus = 'ignored';
  else if (unresolvedSet[usage.su_material]) matStatus = 'unresolved';

  var row = document.createElement('tr');
  row.className = 'mv-mat-summary-row mv-mat-summary-' + matStatus;
  row.dataset.matKey = matKey;

  var tdSeq = document.createElement('td');
  tdSeq.className = 'mv-col-seq';
  row.appendChild(tdSeq);

  var tdName = document.createElement('td');
  tdName.className = 'mv-col-name';
  var indent = document.createElement('span');
  indent.className = 'mv-indent';
  indent.style.paddingLeft = (depth * 16) + 'px';
  tdName.appendChild(indent);

  var hasFaces = (usage.face_count || 0) > 0;
  if (hasFaces) {
    var toggle = document.createElement('span');
    toggle.className = 'mv-toggle';
    toggle.textContent = isMatExpanded ? '▾' : '▸';
    toggle.onclick = function(e) {
      e.stopPropagation();
      _mv.expandedMaterials = _mv.expandedMaterials || {};
      _mv.expandedMaterials[matKey] = !isMatExpanded;
      renderModelView(data || window._workbench);
    };
    tdName.appendChild(toggle);
  } else {
    var spacer = document.createElement('span');
    spacer.className = 'mv-indent';
    spacer.style.minWidth = '14px';
    spacer.textContent = ' ';
    tdName.appendChild(spacer);
  }

  var matName = document.createElement('span');
  matName.className = 'mv-mat-summary-name';
  matName.textContent = usage.su_material;
  tdName.appendChild(matName);

  var faceCountSpan = document.createElement('span');
  faceCountSpan.className = 'mv-mat-summary-faces';
  faceCountSpan.textContent = ' ' + usage.face_count + '面';
  tdName.appendChild(faceCountSpan);

  row.appendChild(tdName);

  // 产品信息（材料汇总行内联选择关联 SKU：编码 + 名称）
  var tdInfo = document.createElement('td');
  tdInfo.className = 'col-sku';
  var skuInput = document.createElement('input');
  skuInput.type = 'text';
  skuInput.className = 'u-sku';
  skuInput.autocomplete = 'off';
  skuInput.placeholder = '搜索SKU';
  skuInput.value = usage.sku_code ? (usage.sku_code + ' ' + (usage.sku_name || '')) : '';
  tdInfo.appendChild(skuInput);
  var skuDd = document.createElement('div');
  skuDd.className = 'sku-dropdown';
  skuDd.style.display = 'none';
  tdInfo.appendChild(skuDd);
  if (typeof bindSkuAutocomplete === 'function') {
    var suMat = usage.su_material;
    bindSkuAutocomplete(tdInfo, function(item) {
      callSketchUp('set_material_sku', JSON.stringify({
        su_name: suMat,
        platform_sku_id: item.sku_id || '',
        platform_sku_code: item.code || '',
        platform_sku_name: item.name || ''
      }));
    });
  }
  row.appendChild(tdInfo);

  // 空标记列（对齐表头）
  var tdTag = document.createElement('td');
  tdTag.className = 'mv-col-tag';
  row.appendChild(tdTag);

  var byPart = usage.by_part || {};
  var hasArea = (usage.qty_area || 0) > 0;
  var hasLength = (usage.qty_length || 0) > 0;
  // 回退旧格式：无新字段时按 unit 判断（排除 m³，体积不应进入面积列）
  var areaVal = hasArea ? usage.qty_area : (usage.unit !== 'm' && usage.unit !== 'm³' && !isLinear ? usage.qty : 0);
  var lenVal = hasLength ? usage.qty_length : (isLinear ? usage.qty : 0);
  var hasVolume = (usage.qty_volume || 0) > 0;
  var volVal = hasVolume ? usage.qty_volume : 0;
  var numCols = [
    areaVal > 0 ? fmtNum(areaVal) : '-',
    lenVal > 0 ? fmtNum(lenVal * 1000) : '-',
    volVal > 0 ? fmtNum(volVal) : '-',
    usage.qty_count > 0 ? fmtNum(usage.qty_count) : '-',
    fmtNum(byPart.floor || 0),
    fmtNum(byPart.wall || 0),
    fmtNum(byPart.ceiling || 0),
    unresolvedSet[usage.su_material] ? '待' : '-'
  ];
  numCols.forEach(function(v) {
    var td = document.createElement('td');
    td.className = 'mv-col-num';
    td.textContent = v;
    row.appendChild(td);
  });

  var tdAct = document.createElement('td');
  tdAct.className = 'mv-col-act';
  row.appendChild(tdAct);

  tbody.appendChild(row);

  if (isMatExpanded && hasFaces) {
    var cacheKey = usage.entity_id + ':' + usage.su_material;
    var facesCache = window._workbench && window._workbench._facesCache;
    var faces = facesCache && facesCache[cacheKey];
    if (faces) {
      // 按规格（宽×高 mm）分组
      var specGroups = {};
      faces.forEach(function(f) {
        var dimKey = (f.width && f.height)
          ? Math.round(f.width * 1000) + '×' + Math.round(f.height * 1000)
          : '—';
        if (!specGroups[dimKey]) specGroups[dimKey] = [];
        specGroups[dimKey].push(f);
      });
      Object.keys(specGroups).forEach(function(dimKey) {
        renderSpecGroupRow(dimKey, specGroups[dimKey], usage, depth + 1, matKey, tbody);
      });
    } else {
      // 懒加载：显示占位行，向 Ruby 请求面详情
      var loadRow = document.createElement('tr');
      loadRow.className = 'mv-face-row';
      var loadTd = document.createElement('td');
      loadTd.colSpan = 13;
      loadTd.style.cssText = 'text-align:center;color:#6c7086;font-size:12px;padding:6px';
      loadTd.textContent = '加载面详情…';
      loadRow.appendChild(loadTd);
      tbody.appendChild(loadRow);
      window._facesRequested = window._facesRequested || {};
      if (!window._facesRequested[cacheKey]) {
        window._facesRequested[cacheKey] = true;
        callSketchUp('get_faces', JSON.stringify({ entity_id: usage.entity_id, su_material: usage.su_material }));
      }
    }
  }
}

function renderNodeRows(node, data, cls, usagesByEid, tbody, seq, searchMatches, depthOverride, skipSearch, ancestorHasTag) {
  var tag = cls[node.entity_id];
  if (!tag) return seq;

  // Skip hidden
  if (node.hidden && !_mv.showHidden) return seq;
  if (tag === 'hidden_skipped' && !_mv.showHidden) return seq;

  // Skip empty (pure_organizational)
  if (tag === 'pure_organizational' && !_mv.showEmpty) return seq;

  // Search: skip nodes not in match path (skipSearch bypasses for promoted children)
  if (_mv.searchQuery && !skipSearch && !searchMatches[node.entity_id]) return seq;

  var effectiveDepth = depthOverride !== undefined ? depthOverride : node.depth;
  var hasChildren = node.children.length > 0;
  var isExpanded = isNodeExpanded(node, searchMatches);

  // Component instance with children: always show row, children indented when expanded

  var stats = rollupStats(node, data);
  var selfUsages = usagesByEid[node.entity_id] || [];

  // Determine display values based on tag
  var area = '-', length = '-', volume = '-', count = '-', floor = '-', wall = '-', ceiling = '-';
  var unresolved = '-';

  if (tag === 'has_face_items' || tag === 'has_descendant_stats') {
    area = fmtNum(stats.area);
    length = fmtNum(stats.length);
    volume = stats.volume > 0 ? fmtNum(stats.volume) : '-';
    count = stats.count > 0 ? fmtNum(stats.count) : '-';
    floor = fmtNum(stats.floor);
    wall = fmtNum(stats.wall);
    ceiling = fmtNum(stats.ceiling);
    unresolved = stats.unresolvedCount > 0 ? stats.unresolvedCount : '-';
  } else if (tag === 'has_instance_items') {
    area = '-';
    length = '-';
    volume = '-';
    count = fmtNum(stats.count);
  }
  // actionable_empty and pure_organizational: all '-'

  seq++;
  var row = document.createElement('tr');
  row.className = 'mv-row mv-row-' + tag;
  row.dataset.entityId = node.entity_id;

  // Seq
  var tdSeq = document.createElement('td');
  tdSeq.className = 'mv-col-seq';
  tdSeq.textContent = seq;
  row.appendChild(tdSeq);

  // Name
  var tdName = document.createElement('td');
  tdName.className = 'mv-col-name';
  var indent = document.createElement('span');
  indent.className = 'mv-indent';
  indent.style.paddingLeft = (effectiveDepth * 16) + 'px';
  tdName.appendChild(indent);

  // Toggle icon
  var hasFaceItems = selfUsages.some(function(u) { return !u.is_instance && (u.face_count || 0) > 0; });
  var hasExpandable = hasChildren || hasFaceItems;
  if (hasExpandable) {
    var toggle = document.createElement('span');
    toggle.className = 'mv-toggle';
    toggle.textContent = isExpanded ? '▾' : '▸';
    toggle.onclick = function(e) {
      e.stopPropagation();
      _mv.expandedNodes[node.entity_id] = !isExpanded;
      renderModelView(data || window._workbench);
    };
    tdName.appendChild(toggle);
  } else if (tag === 'actionable_empty') {
    var diamond = document.createElement('span');
    diamond.className = 'mv-toggle mv-toggle-diamond';
    diamond.textContent = '◇';
    tdName.appendChild(diamond);
  } else {
    var empty = document.createElement('span');
    empty.className = 'mv-indent';
    empty.style.minWidth = '14px';
    empty.textContent = ' ';
    tdName.appendChild(empty);
  }

  var nameSpan = document.createElement('span');
  nameSpan.className = 'mv-node-name';
  nameSpan.textContent = node.name;
  tdName.appendChild(nameSpan);

  // Component definition name label (always shown for component instances)
  if (node.kind === 'component_instance' && node.definition_name) {
    var defLabel = document.createElement('span');
    defLabel.className = 'mv-def-label';
    defLabel.textContent = node.definition_name;
    tdName.appendChild(defLabel);
  }

  // Tag badge (标记系统)
  if (node.tag) {
    var tagBadge = document.createElement('span');
    tagBadge.className = 'mv-tag-badge';
    tagBadge.textContent = node.tag;
    var tagDefs = _mv.tagDefs || (window._workbench && window._workbench.tag_defs) || {};
    var tagMethod = tagDefs[node.tag];
    if (tagMethod) {
      var methods = tagMethod.split('+').map(function(s) { return s.trim(); });
      if (methods.indexOf('count') >= 0) tagBadge.classList.add('mv-tag-badge-count');
      if (methods.indexOf('length') >= 0) tagBadge.classList.add('mv-tag-badge-length');
      if (methods.indexOf('volume') >= 0) tagBadge.classList.add('mv-tag-badge-volume');
      if (methods.indexOf('area') >= 0 || methods.length === 0) tagBadge.classList.add('mv-tag-badge-area');
      // 复合标签用特殊样式
      if (methods.length >= 2) tagBadge.classList.add('mv-tag-badge-combo');
    } else {
      tagBadge.classList.add('mv-tag-badge-area');
    }
    tdName.appendChild(tagBadge);
  }

  // Part badge
  if (tag === 'has_face_items') {
    var badge = renderPartBadge(stats, true);
    if (badge) tdName.appendChild(badge);
  }

  // Material count badge
  if (tag === 'has_face_items' || tag === 'has_descendant_stats') {
    var matCount = getSelfMatCount(selfUsages);
    if (matCount > 0) {
      var matBadge = document.createElement('span');
      matBadge.className = 'mv-mat-count-badge';
      matBadge.textContent = matCount + '种';
      tdName.appendChild(matBadge);
    }
  }

  // Pure organizational chip
  if (tag === 'pure_organizational') {
    var pchip = document.createElement('span');
    pchip.className = 'mv-chip mv-chip-empty';
    pchip.textContent = '空分组';
    tdName.appendChild(pchip);
  }

  row.appendChild(tdName);

  // 产品信息（空白列）
  var tdInfo = document.createElement('td');
  row.appendChild(tdInfo);

  // Tag column
  var tdTag = document.createElement('td');
  tdTag.className = 'mv-col-tag';
  var isContainer = node.kind === 'group' || node.kind === 'component_instance';
  // 祖先已打标签时子级不显示下拉（标签从父级传播，避免冲突）
  if (isContainer && !ancestorHasTag) {
    var allTagDefs = _mv.tagDefs || (window._workbench && window._workbench.tag_defs) || {};
    var tagNames = Object.keys(allTagDefs);
    if (tagNames.length > 0) {
      var tagSelect = document.createElement('select');
      tagSelect.className = 'mv-tag-select';
      var optClear = document.createElement('option');
      optClear.value = '';
      optClear.textContent = '—';
      tagSelect.appendChild(optClear);
      tagNames.forEach(function(tn) {
        var opt = document.createElement('option');
        opt.value = tn;
        opt.textContent = tn;
        if (node.tag === tn) opt.selected = true;
        tagSelect.appendChild(opt);
      });
      tagSelect.onchange = function() {
        callSketchUp('set_entity_tag', JSON.stringify({
          entity_id: node.entity_id,
          tag_name: tagSelect.value
        }));
      };
      tdTag.appendChild(tagSelect);
    }
  }
  row.appendChild(tdTag);

  // Numeric cols
  var numCols = [area, length, volume, count, floor, wall, ceiling, unresolved];
  numCols.forEach(function(v) {
    var td = document.createElement('td');
    td.className = 'mv-col-num';
    td.textContent = v;
    row.appendChild(td);
  });

  // Actions
  var tdAct = document.createElement('td');
  tdAct.className = 'mv-col-act';
  if (node.entity_id !== 0) {
    var locateBtn = document.createElement('button');
    locateBtn.className = 'mv-locate-btn';
    locateBtn.textContent = '⌖';
    locateBtn.title = '定位到模型';
    locateBtn.onclick = function() {
      callSketchUp('locate_entity', String(node.entity_id));
    };
    tdAct.appendChild(locateBtn);
  }
  row.appendChild(tdAct);

  tbody.appendChild(row);

  // Expansion area: material summary rows + child component rows
  if (isExpanded) {
    // Material summary rows (only this entity's own face usages)
    var faceUsages = selfUsages.filter(function(u) { return !u.is_instance && (u.face_count || 0) > 0; });
    if (faceUsages.length > 0) {
      faceUsages.forEach(function(u) {
        renderMaterialSummaryRow(u, effectiveDepth + 1, node.entity_id, tbody, data);
      });
    }

    // Child component rows
    if (hasChildren) {
      if (_mv.mergeSame) {
        // 按 merge key 分组，同 key 的节点合并为一行
        var groups = {};
        var groupOrder = []; // 保持出现顺序
        node.children.forEach(function(c) {
          var mk = getMergeKey(c);
          if (mk) {
            if (!groups[mk]) { groups[mk] = []; groupOrder.push(mk); }
            groups[mk].push(c);
          } else {
            // 不可合并的节点直接用自身标识作为 key
            var soloKey = 'solo:' + c.entity_id;
            groups[soloKey] = [c];
            groupOrder.push(soloKey);
          }
        });
        groupOrder.forEach(function(mk) {
          var grp = groups[mk];
          if (grp.length === 1) {
            seq = renderNodeRows(grp[0], data, cls, usagesByEid, tbody, seq, searchMatches, effectiveDepth + 1, false, ancestorHasTag || !!node.tag);
          } else {
            seq = renderMergedRow(grp, data, cls, usagesByEid, tbody, seq, searchMatches, effectiveDepth + 1, ancestorHasTag || !!node.tag);
          }
        });
      } else {
        node.children.forEach(function(c) {
          seq = renderNodeRows(c, data, cls, usagesByEid, tbody, seq, searchMatches, effectiveDepth + 1, false, ancestorHasTag || !!node.tag);
        });
      }
    }
  }

  return seq;
}

// 合并行渲染：将同定义名的多个组件实例合并为一行
function renderMergedRow(nodes, data, cls, usagesByEid, tbody, seq, searchMatches, depth, ancestorHasTag) {
  var first = nodes[0];
  var mergedStats = mergeStats(nodes, data);
  var mergedUsages = mergeSelfUsages(nodes, data);
  var allChildren = [];
  nodes.forEach(function(n) { n.children.forEach(function(c) { allChildren.push(c); }); });

  var expandKey = 'merged:' + getMergeKey(first);
  _mv.expandedNodes = _mv.expandedNodes || {};
  var isExpanded = _mv.expandedNodes[expandKey] !== undefined ? _mv.expandedNodes[expandKey] : false;

  seq++;
  var row = document.createElement('tr');
  row.className = 'mv-row mv-row-has_face_items mv-row-merged';

  // Seq
  var tdSeq = document.createElement('td');
  tdSeq.className = 'mv-col-seq';
  tdSeq.textContent = seq;
  row.appendChild(tdSeq);

  // Name
  var tdName = document.createElement('td');
  tdName.className = 'mv-col-name';
  var indent = document.createElement('span');
  indent.className = 'mv-indent';
  indent.style.paddingLeft = (depth * 16) + 'px';
  tdName.appendChild(indent);

  var hasExpandable = allChildren.length > 0 || mergedUsages.some(function(u) { return !u.is_instance && (u.face_count || 0) > 0; });
  if (hasExpandable) {
    var toggle = document.createElement('span');
    toggle.className = 'mv-toggle';
    toggle.textContent = isExpanded ? '▾' : '▸';
    toggle.onclick = function(e) {
      e.stopPropagation();
      _mv.expandedNodes[expandKey] = !isExpanded;
      renderModelView(data || window._workbench);
    };
    tdName.appendChild(toggle);
  } else {
    var emptyIcon = document.createElement('span');
    emptyIcon.className = 'mv-indent';
    emptyIcon.style.minWidth = '14px';
    emptyIcon.textContent = ' ';
    tdName.appendChild(emptyIcon);
  }

  var nameSpan = document.createElement('span');
  nameSpan.className = 'mv-node-name';
  nameSpan.textContent = first.definition_name || first.name;
  tdName.appendChild(nameSpan);

  // Definition name label
  if (first.definition_name) {
    var defLabel = document.createElement('span');
    defLabel.className = 'mv-def-label';
    defLabel.textContent = first.definition_name;
    tdName.appendChild(defLabel);
  }

  // Instance count badge
  var cntBadge = document.createElement('span');
  cntBadge.className = 'mv-merge-count-badge';
  cntBadge.textContent = '×' + nodes.length;
  tdName.appendChild(cntBadge);

  // Tag badge（取第一个节点的 tag，合并组内应一致）
  if (first.tag) {
    var tagBadge = document.createElement('span');
    tagBadge.className = 'mv-tag-badge';
    tagBadge.textContent = first.tag;
    var tagDefs = _mv.tagDefs || (window._workbench && window._workbench.tag_defs) || {};
    var tagMethod = tagDefs[first.tag];
    if (tagMethod) {
      var methods = tagMethod.split('+').map(function(s) { return s.trim(); });
      if (methods.indexOf('count') >= 0) tagBadge.classList.add('mv-tag-badge-count');
      if (methods.indexOf('length') >= 0) tagBadge.classList.add('mv-tag-badge-length');
      if (methods.indexOf('volume') >= 0) tagBadge.classList.add('mv-tag-badge-volume');
      if (methods.indexOf('area') >= 0 || methods.length === 0) tagBadge.classList.add('mv-tag-badge-area');
      if (methods.length >= 2) tagBadge.classList.add('mv-tag-badge-combo');
    } else {
      tagBadge.classList.add('mv-tag-badge-area');
    }
    tdName.appendChild(tagBadge);
  }

  row.appendChild(tdName);

  // 产品信息（空白列）
  var tdInfo = document.createElement('td');
  row.appendChild(tdInfo);

  // Tag column
  var tdTag = document.createElement('td');
  tdTag.className = 'mv-col-tag';
  var isContainer = first.kind === 'group' || first.kind === 'component_instance';
  if (isContainer && !ancestorHasTag) {
    var allTagDefs = _mv.tagDefs || (window._workbench && window._workbench.tag_defs) || {};
    var tagNames = Object.keys(allTagDefs);
    if (tagNames.length > 0) {
      var tagSelect = document.createElement('select');
      tagSelect.className = 'mv-tag-select';
      var optClear = document.createElement('option');
      optClear.value = '';
      optClear.textContent = '—';
      tagSelect.appendChild(optClear);
      tagNames.forEach(function(tn) {
        var opt = document.createElement('option');
        opt.value = tn;
        opt.textContent = tn;
        if (first.tag === tn) opt.selected = true;
        tagSelect.appendChild(opt);
      });
      tagSelect.onchange = function() {
        // 为合并组内所有实例打标签
        nodes.forEach(function(n) {
          callSketchUp('set_entity_tag', JSON.stringify({
            entity_id: n.entity_id,
            tag_name: tagSelect.value
          }));
        });
      };
      tdTag.appendChild(tagSelect);
    }
  }
  row.appendChild(tdTag);

  // Numeric cols
  var area   = fmtNum(mergedStats.area);
  var length = fmtNum(mergedStats.length);
  var volume = mergedStats.volume > 0 ? fmtNum(mergedStats.volume) : '-';
  var count  = mergedStats.count > 0 ? fmtNum(mergedStats.count) : '-';
  var floor  = fmtNum(mergedStats.floor);
  var wall   = fmtNum(mergedStats.wall);
  var ceiling = fmtNum(mergedStats.ceiling);
  var unresolved = mergedStats.unresolvedCount > 0 ? mergedStats.unresolvedCount : '-';

  [area, length, volume, count, floor, wall, ceiling, unresolved].forEach(function(v) {
    var td = document.createElement('td');
    td.className = 'mv-col-num';
    td.textContent = v;
    row.appendChild(td);
  });

  // Actions — 定位到第一个实例
  var tdAct = document.createElement('td');
  tdAct.className = 'mv-col-act';
  var locateBtn = document.createElement('button');
  locateBtn.className = 'mv-locate-btn';
  locateBtn.textContent = '⌖';
  locateBtn.title = '定位到模型（第一个实例）';
  locateBtn.onclick = function() {
    callSketchUp('locate_entity', String(first.entity_id));
  };
  tdAct.appendChild(locateBtn);
  row.appendChild(tdAct);

  tbody.appendChild(row);

  // 展开区域
  if (isExpanded) {
    // 材质汇总（合并后的 usages）
    var faceUsages = mergedUsages.filter(function(u) { return !u.is_instance && (u.face_count || 0) > 0; });
    if (faceUsages.length > 0) {
      faceUsages.forEach(function(u) {
        renderMaterialSummaryRow(u, depth + 1, first.entity_id, tbody, data);
      });
    }

    // 所有子节点
    if (allChildren.length > 0) {
      allChildren.forEach(function(c) {
        seq = renderNodeRows(c, data, cls, usagesByEid, tbody, seq, searchMatches, depth + 1, false, ancestorHasTag || !!first.tag);
      });
    }
  }

  return seq;
}

function isNodeExpanded(node, searchMatches) {
  if (_mv.expandedNodes[node.entity_id] !== undefined) {
    return _mv.expandedNodes[node.entity_id];
  }
  if (_mv.searchQuery && searchMatches[node.entity_id]) {
    return true;
  }
  // 默认展开根节点，显示第一层子节点
  if (node.depth === 0) {
    return true;
  }
  return false;
}

function renderPartBadge(stats, isSelf) {
  var total = stats.floor + stats.wall + stats.ceiling;
  if (total <= 0) return null;
  var dominant = null;
  if (stats.floor / total >= 0.8) dominant = 'floor';
  else if (stats.wall / total >= 0.8) dominant = 'wall';
  else if (stats.ceiling / total >= 0.8) dominant = 'ceiling';
  if (!dominant) {
    // mixed badge
    var badge = document.createElement('span');
    badge.className = 'mv-badge mv-badge-mixed';
    badge.textContent = '混合';
    return badge;
  }
  var badge = document.createElement('span');
  badge.className = 'mv-badge mv-badge-' + dominant;
  var labels = { floor: '地面', wall: '墙面', ceiling: '天花' };
  badge.textContent = labels[dominant];
  return badge;
}

// ---------------- Main entries ----------------
function renderPositionView(data) {
  if (!data || !data.hierarchy) {
    var container = document.getElementById('page-position');
    container.innerHTML = '<div class="mv-error">需要更新插件（hierarchy 数据缺失）</div>';
    return;
  }

  classifyNodes(data);

  _mv.level = data._maxDepth || 0;
  _mv.tagDefs = data.tag_defs || {};

  var container = document.getElementById('page-position');
  var existingEmpty = container.querySelector('.empty-state');
  if (existingEmpty && !data.hierarchy.children.length && !data.geometry_usages.length) {
    return;
  }
  container.innerHTML = '';

  renderToolbar(data, container);
  renderPositionTable(data, container);
}

// Legacy entry
function renderModelView(data) {
  try {
    renderPositionView(data);
  } catch(e) {
    console.error('renderModelView error:', e);
    var container = document.getElementById('page-position');
    container.innerHTML = '<div class="mv-error">渲染错误: ' + e.message + '</div>';
  }
}

// ---------------- CSV export ----------------
function exportModelCsv(data) {
  var rows = [];
  rows.push(['#', '名称 / 材质', '产品信息', '算量标签', '面积(m²)', '长度(mm)', '体积(m³)', '件数', '地面', '墙面', '天花', '待处理']);
  var seq = 0;
  collectPositionCsvRows(data.hierarchy, data, rows, seq);

  var csv = '﻿'; // BOM
  rows.forEach(function(r) {
    csv += r.map(csvEscape).join(',') + '\n';
  });
  var blob = new Blob([csv], { type: 'text/csv;charset=utf-8' });
  var a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'model_view_按组件.csv';
  a.click();
}

function collectPositionCsvRows(node, data, rows, seq) {
  var cls = data._classification || {};
  var tag = cls[node.entity_id];
  if (!tag) return seq;
  if (node.hidden && !_mv.showHidden) return seq;
  if (tag === 'hidden_skipped') return seq;
  if (tag === 'pure_organizational' && !_mv.showEmpty) return seq;

  // Skip component_instance summary rows — include children directly
  if (node.kind === 'component_instance' && node.children.length > 0) {
    if (isNodeExpanded(node, {})) {
      node.children.forEach(function(c) {
        seq = collectPositionCsvRows(c, data, rows, seq);
      });
    }
    return seq;
  }

  var stats = rollupStats(node, data);
  var selfUsages = (data._usagesByEntityId || {})[node.entity_id] || [];
  seq++;
  rows.push([
    seq,
    node.name,
    '',
    node.tag || '',
    fmtNum(stats.area),
    fmtNum(stats.length),
    fmtNum(stats.volume),
    fmtNum(stats.count),
    fmtNum(stats.floor),
    fmtNum(stats.wall),
    fmtNum(stats.ceiling),
    stats.unresolvedCount
  ]);

  if (isNodeExpanded(node, {})) {
    node.children.forEach(function(c) {
      seq = collectPositionCsvRows(c, data, rows, seq);
    });
  }
  return seq;
}

// ---------------- Helpers ----------------
function fmtNum(n) {
  if (n === '-' || n === undefined || n === null) return '-';
  if (typeof n !== 'number') return String(n);
  if (n === 0) return '-';
  return n.toFixed(2);
}