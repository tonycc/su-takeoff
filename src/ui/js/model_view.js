// src/ui/js/model_view.js — 模型视图：统一树 + 聚合档位 + 按位置/按材料分组

// ---------------- State ----------------
window._mv = {
  level: null,
  showEmpty: false,
  showHidden: false,
  mergeSame: false,
  searchQuery: '',
  materialFilter: 'all',
  expandedNodes: {},
  expandedMaterials: {},
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

// ---------------- Rollup stats ----------------
function rollupStats(node, data) {
  var usagesByEid = data._usagesByEntityId || {};
  var cls = data._classification || {};
  var unresolvedSet = {};
  (data.unresolved || []).forEach(function(n) { unresolvedSet[n] = true; });
  var ignoredSet = {};
  (data.ignored || []).forEach(function(n) { ignoredSet[n] = true; });
  var materials = {};
  var result = { area: 0, length: 0, count: 0, floor: 0, wall: 0, ceiling: 0, matCount: 0, unresolvedCount: 0 };

  // Self usages
  var selfUsages = usagesByEid[node.entity_id] || [];
  selfUsages.forEach(function(u) {
    if (u.is_instance) {
      result.count += u.qty;
    } else if (u.unit === 'm' || u.unit === 'm²') {
      // m or m²
      if (u.unit === 'm') {
        result.length += u.qty * 1000;
      } else {
        result.area += u.qty;
      }
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
function renderToolbar(data, container, mode) {
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
    var renderFn = mode === 'position' ? renderPositionView : renderMaterialView;
    cb.onchange = function() {
      _mv[sw.key] = cb.checked;
      renderFn(data);
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
  var renderFn = mode === 'position' ? renderPositionView : renderMaterialView;
  searchInput.oninput = function() {
    _mv.searchQuery = searchInput.value.trim();
    renderFn(data);
  };
  searchWrap.appendChild(searchInput);
  row2.appendChild(searchWrap);

  // Export
  var exportBtn = document.createElement('button');
  exportBtn.className = 'mv-export-btn';
  exportBtn.textContent = '⤓ 导出';
  exportBtn.onclick = function() { exportModelCsv(data, mode); };
  row2.appendChild(exportBtn);
  tb.appendChild(row2);

  // Material filter (material mode only)
  if (mode === 'material') {
    var filterRow = document.createElement('div');
    filterRow.className = 'mv-toolbar-row';
    var filterWrap = document.createElement('div');
    filterWrap.className = 'mv-filter-tabs';
    var fLabel = document.createElement('span');
    fLabel.className = 'mv-toolbar-label';
    fLabel.textContent = '筛选:';
    filterWrap.appendChild(fLabel);

    var filters = ['all', 'unresolved', 'mapped', 'ignored'];
    var filterLabels = { all: '全部', unresolved: '待映射', mapped: '已映射', ignored: '已忽略' };
    filters.forEach(function(f) {
      var btn = document.createElement('button');
      btn.className = 'mv-filter-btn' + ((_mv.materialFilter === f) ? ' active' : '');
      btn.textContent = filterLabels[f];
      btn.onclick = function() {
        _mv.materialFilter = f;
        renderMaterialView(data);
      };
      filterWrap.appendChild(btn);
    });
    filterRow.appendChild(filterWrap);
    tb.appendChild(filterRow);
  }

  container.appendChild(tb);
}

// ---------------- Position mode: tree table ----------------
// Sortable column keys mapped to column index
var POS_SORT_COLS = { 1: 'name', 2: 'area', 3: 'length', 4: 'count', 5: 'floor', 6: 'wall', 7: 'ceiling', 8: 'unresolved' };

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
  var cols = ['#', '名称 / 材质', '面积(m²)', '长度(mm)', '件数', '地面', '墙面', '天花', '待处理', '操作'];
  cols.forEach(function(c, i) {
    var th = document.createElement('th');
    if (i >= 2 && i <= 8) th.className = 'mv-th-num';
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
        renderModelView(data);
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

  renderNodeRows(sortedHierarchy, data, cls, usagesByEid, tbody, seq, searchMatches, 0);
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

function renderFaceDetailRow(face, usage, depth, tbody) {
  var row = document.createElement('tr');
  row.className = 'mv-face-row';
  row.dataset.faceId = face.face_id;
  if (_mv.highlightFaceId === face.face_id) {
    row.classList.add('mv-highlight');
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

  var isLinear = usage.unit === 'm';
  var partArea = {};
  partArea[face.part] = face.area;

  var tdArea = document.createElement('td');
  tdArea.className = 'mv-col-num mv-face-num';
  tdArea.textContent = isLinear ? '-' : fmtNum(face.area);
  row.appendChild(tdArea);

  var tdLen = document.createElement('td');
  tdLen.className = 'mv-col-num mv-face-num';
  tdLen.textContent = isLinear && face.height ? fmtNum(face.height * 1000) : '-';
  row.appendChild(tdLen);

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
  locateBtn.onclick = function() { callSketchUp('locate_face', String(face.face_id)); };
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

  var hasFaces = usage.faces && usage.faces.length > 0;
  if (hasFaces) {
    var toggle = document.createElement('span');
    toggle.className = 'mv-toggle';
    toggle.textContent = isMatExpanded ? '▾' : '▸';
    toggle.onclick = function(e) {
      e.stopPropagation();
      _mv.expandedMaterials = _mv.expandedMaterials || {};
      _mv.expandedMaterials[matKey] = !isMatExpanded;
      renderModelView(data);
    };
    tdName.appendChild(toggle);
  } else {
    var spacer = document.createElement('span');
    spacer.className = 'mv-indent';
    spacer.style.minWidth = '14px';
    spacer.textContent = ' ';
    tdName.appendChild(spacer);
  }

  var materialsInfo = data.materials_info || [];
  var info = null;
  for (var i = 0; i < materialsInfo.length; i++) {
    if (materialsInfo[i].su_name === usage.su_material) { info = materialsInfo[i]; break; }
  }
  if (info && info.color) {
    var swatch = document.createElement('span');
    swatch.className = 'mv-mat-swatch';
    swatch.style.background = info.color;
    tdName.appendChild(swatch);
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

  var byPart = usage.by_part || {};
  var numCols = [
    isLinear ? '-' : fmtNum(usage.qty),
    isLinear ? fmtNum(usage.qty * 1000) : '-',
    '-',
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
    usage.faces.forEach(function(f) {
      renderFaceDetailRow(f, usage, depth + 1, tbody);
    });
  }
}

function renderNodeRows(node, data, cls, usagesByEid, tbody, seq, searchMatches, parentVisible, depthOverride, skipSearch) {
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
  var area = '-', length = '-', count = '-', floor = '-', wall = '-', ceiling = '-';
  var unresolved = '-';

  if (tag === 'has_face_items' || tag === 'has_descendant_stats') {
    area = fmtNum(stats.area);
    length = fmtNum(stats.length);
    count = stats.count > 0 ? fmtNum(stats.count) : '-';
    floor = fmtNum(stats.floor);
    wall = fmtNum(stats.wall);
    ceiling = fmtNum(stats.ceiling);
    unresolved = stats.unresolvedCount > 0 ? stats.unresolvedCount : '-';
  } else if (tag === 'has_instance_items') {
    area = '-';
    length = '-';
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
  var hasFaceItems = selfUsages.some(function(u) { return !u.is_instance && u.faces && u.faces.length > 0; });
  var hasExpandable = hasChildren || hasFaceItems;
  if (hasExpandable) {
    var toggle = document.createElement('span');
    toggle.className = 'mv-toggle';
    toggle.textContent = isExpanded ? '▾' : '▸';
    toggle.onclick = function(e) {
      e.stopPropagation();
      _mv.expandedNodes[node.entity_id] = !isExpanded;
      renderModelView(data);
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

  // Numeric cols
  var numCols = [area, length, count, floor, wall, ceiling, unresolved];
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
    var faceUsages = selfUsages.filter(function(u) { return !u.is_instance && u.faces && u.faces.length > 0; });
    if (faceUsages.length > 0) {
      faceUsages.forEach(function(u) {
        renderMaterialSummaryRow(u, effectiveDepth + 1, node.entity_id, tbody, data);
      });
    }

    // Child component rows
    if (hasChildren) {
      node.children.forEach(function(c) {
        seq = renderNodeRows(c, data, cls, usagesByEid, tbody, seq, searchMatches, 1, effectiveDepth + 1);
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

// ---------------- Material mode: flat table ----------------
var MAT_SORT_COLS = { 2: 'su_material', 3: 'qty', 4: 'face_count', 5: 'locationCount', 7: 'materialName' };

function renderMaterialTable(data, container) {
  var hierarchy = data.hierarchy;
  var usagesByEid = data._usagesByEntityId;
  var materialsInfo = data.materials_info || [];
  var unresolved = data.unresolved || [];
  var ignored = data.ignored || [];
  var mapping = {};
  materialsInfo.forEach(function(m) { mapping[m.su_name] = m; });

  // Group geometry_usages by su_material (non-instance only)
  var byMaterial = {};
  var instanceCount = 0;
  (data.geometry_usages || []).forEach(function(u) {
    if (u.is_instance) { instanceCount++; return; }
    var key = u.su_material || '(无材质)';
    byMaterial[key] = byMaterial[key] || [];
    byMaterial[key].push(u);
  });

  // Determine status
  var unresolvedSet = {};
  unresolved.forEach(function(n) { unresolvedSet[n] = true; });
  var ignoredSet = {};
  ignored.forEach(function(n) { ignoredSet[n] = true; });

  // Apply filter
  var filter = _mv.materialFilter;
  var materialKeys = Object.keys(byMaterial);
  if (filter !== 'all') {
    materialKeys = materialKeys.filter(function(key) {
      var status = getMaterialStatus(key, unresolvedSet, ignoredSet, mapping);
      if (filter === 'unresolved' && status !== 'unresolved') return false;
      if (filter === 'mapped' && status !== 'mapped') return false;
      if (filter === 'ignored' && status !== 'ignored') return false;
      return true;
    });
  }

  // Search
  if (_mv.searchQuery) {
    var q = _mv.searchQuery.toLowerCase();
    materialKeys = materialKeys.filter(function(key) {
      return key.toLowerCase().indexOf(q) >= 0;
    });
  }

  // Pre-compute aggregates for sorting
  var matAgg = {};
  materialKeys.forEach(function(key) {
    var usages = byMaterial[key];
    var info = mapping[key] || {};
    var totalArea = 0, totalLength = 0, totalFace = 0;
    var partFloor = 0, partWall = 0, partCeil = 0;
    var locations = {};
    usages.forEach(function(u) {
      totalFace += u.face_count || 0;
      if (u.unit === 'm') totalLength += u.qty * 1000;
      else totalArea += u.qty;
      partFloor += (u.by_part && u.by_part.floor) || 0;
      partWall += (u.by_part && u.by_part.wall) || 0;
      partCeil += (u.by_part && u.by_part.ceiling) || 0;
      var topGroup = findTopLevelGroup(u.entity_id, hierarchy);
      if (topGroup) locations[topGroup.name] = true;
    });
    matAgg[key] = {
      totalArea: totalArea, totalLength: totalLength, totalFace: totalFace,
      partFloor: partFloor, partWall: partWall, partCeil: partCeil,
      locations: locations, info: info,
      qty: totalArea > 0 ? totalArea : totalLength,
      locationCount: Object.keys(locations).length,
      materialName: info.material_name || ''
    };
  });

  // Sort material keys
  if (_mv.sortCol) {
    materialKeys.sort(function(a, b) {
      var aggA = matAgg[a], aggB = matAgg[b];
      var aVal, bVal;
      if (_mv.sortCol === 'su_material') { aVal = a; bVal = b; }
      else if (_mv.sortCol === 'qty') { aVal = aggA.qty; bVal = aggB.qty; }
      else if (_mv.sortCol === 'face_count') { aVal = aggA.totalFace; bVal = aggB.totalFace; }
      else if (_mv.sortCol === 'locationCount') { aVal = aggA.locationCount; bVal = aggB.locationCount; }
      else if (_mv.sortCol === 'materialName') { aVal = aggA.materialName; bVal = aggB.materialName; }
      else { aVal = 0; bVal = 0; }
      var cmp = 0;
      if (typeof aVal === 'string' && typeof bVal === 'string') {
        cmp = aVal.localeCompare(bVal, 'zh');
      } else {
        cmp = (aVal || 0) - (bVal || 0);
      }
      return _mv.sortDir === 'desc' ? -cmp : cmp;
    });
  }

  // Instance banner
  if (instanceCount > 0) {
    var banner = document.createElement('div');
    banner.className = 'mv-banner';
    banner.textContent = '另含 ' + instanceCount + ' 个组件实例（见按位置模式）';
    container.appendChild(banner);
  }

  // Table with sortable headers
  var table = document.createElement('table');
  table.className = 'mv-table mv-material-table';

  var thead = document.createElement('thead');
  var hrow = document.createElement('tr');
  var mCols = ['#', '状态', 'SU材质', '面数/用量', '部位分布', '位置数', '位置', '真实材料', '操作'];
  mCols.forEach(function(c, i) {
    var th = document.createElement('th');
    var sortKey = MAT_SORT_COLS[i];
    if (sortKey) {
      th.className = 'mv-th-sortable';
      th.onclick = function() {
        if (_mv.sortCol === sortKey) {
          _mv.sortDir = _mv.sortDir === 'asc' ? 'desc' : 'asc';
        } else {
          _mv.sortCol = sortKey;
          _mv.sortDir = 'asc';
        }
        renderModelView(data);
      };
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
  materialKeys.forEach(function(key, idx) {
    var usages = byMaterial[key];
    var agg = matAgg[key];
    var info = agg.info;
    var status = getMaterialStatus(key, unresolvedSet, ignoredSet, mapping);
    var totalArea = agg.totalArea, totalLength = agg.totalLength, totalFace = agg.totalFace;
    var partFloor = agg.partFloor, partWall = agg.partWall, partCeil = agg.partCeil;
    var locNames = Object.keys(agg.locations);

    var row = document.createElement('tr');
    row.className = 'mv-row mv-mat-row mv-mat-' + status;

    // Seq
    var tdSeq = document.createElement('td');
    tdSeq.textContent = idx + 1;
    row.appendChild(tdSeq);

    // Status
    var tdStatus = document.createElement('td');
    var statusTag = document.createElement('span');
    statusTag.className = 'tag tag-' + status;
    var statusLabels = { mapped: '已映射', unresolved: '待', ignored: '已忽略' };
    statusTag.textContent = statusLabels[status];
    tdStatus.appendChild(statusTag);
    row.appendChild(tdStatus);

    // SU Material
    var tdMat = document.createElement('td');
    tdMat.className = 'mv-col-mat';
    if (info.color) {
      var swatch = document.createElement('span');
      swatch.className = 'swatch';
      swatch.style.background = info.color;
      tdMat.appendChild(swatch);
      tdMat.appendChild(document.createTextNode(' '));
    }
    var matName = document.createElement('span');
    matName.textContent = key;
    tdMat.appendChild(matName);
    row.appendChild(tdMat);

    // Face count / qty
    var tdQty = document.createElement('td');
    var mainQty = totalArea > 0 ? fmtNum(totalArea) + ' m²' : fmtNum(totalLength) + ' mm';
    tdQty.textContent = totalFace + ' 面 / ' + mainQty;
    row.appendChild(tdQty);

    // Part distribution
    var tdPart = document.createElement('td');
    tdPart.className = 'mv-col-parts';
    if (partFloor > 0) { var p = document.createElement('span'); p.className = 'pill pill-floor'; p.textContent = '地 ' + fmtNum(partFloor); tdPart.appendChild(p); }
    if (partWall > 0) { var p2 = document.createElement('span'); p2.className = 'pill pill-wall'; p2.textContent = '墙 ' + fmtNum(partWall); tdPart.appendChild(p2); }
    if (partCeil > 0) { var p3 = document.createElement('span'); p3.className = 'pill pill-ceiling'; p3.textContent = '天 ' + fmtNum(partCeil); tdPart.appendChild(p3); }
    row.appendChild(tdPart);

    // Location count
    var tdLocCount = document.createElement('td');
    tdLocCount.textContent = agg.locationCount;
    row.appendChild(tdLocCount);

    // Top locations
    var tdLoc = document.createElement('td');
    var locText = locNames.slice(0, 3).join(', ');
    if (locNames.length > 3) locText += ' 等 ' + locNames.length + ' 处';
    tdLoc.textContent = locText;
    row.appendChild(tdLoc);

    // Real material name
    var tdReal = document.createElement('td');
    tdReal.textContent = info.material_name || '—';
    row.appendChild(tdReal);

    // Actions
    var tdAct = document.createElement('td');
    var locateBtn = document.createElement('button');
    locateBtn.className = 'mv-locate-btn';
    locateBtn.textContent = '⌖';
    locateBtn.title = '定位材质';
    locateBtn.onclick = function() { callSketchUp('locate_material', key); };
    tdAct.appendChild(locateBtn);
    row.appendChild(tdAct);

    tbody.appendChild(row);
  });
  table.appendChild(tbody);
  container.appendChild(table);

  if (materialKeys.length === 0) {
    var empty = document.createElement('div');
    empty.className = 'mv-empty';
    empty.textContent = _mv.searchQuery ? '无匹配，调整搜索词或开关' : '无面材数据';
    container.appendChild(empty);
  }
}

function getMaterialStatus(name, unresolvedSet, ignoredSet, mapping) {
  if (ignoredSet[name]) return 'ignored';
  if (unresolvedSet[name]) return 'unresolved';
  var info = mapping[name];
  if (info && info.material_name) return 'mapped';
  return 'unresolved';
}

function findTopLevelGroup(entityId, hierarchy) {
  // Find the topmost (depth=1) group that contains this entity_id
  var byId = window._workbench._byEntityId || {};
  var node = byId[entityId];
  if (!node) return null;
  // Walk up the hierarchy to find the depth=1 ancestor
  return findAncestorAtDepth(hierarchy, entityId, 1);
}

function findAncestorAtDepth(root, targetEid, targetDepth) {
  // DFS: track ancestor chain
  function walk(node, ancestors) {
    if (node.entity_id === targetEid) {
      // Found, return ancestor at targetDepth
      return ancestors.filter(function(a) { return a.depth === targetDepth; })[0] || root;
    }
    var newAncestors = ancestors.concat([node]);
    for (var i = 0; i < node.children.length; i++) {
      var result = walk(node.children[i], newAncestors);
      if (result) return result;
    }
    return null;
  }
  return walk(root, []);
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

  var container = document.getElementById('page-position');
  var existingEmpty = container.querySelector('.empty-state');
  if (existingEmpty && !data.hierarchy.children.length && !data.geometry_usages.length) {
    return;
  }
  container.innerHTML = '';

  renderToolbar(data, container, 'position');
  renderPositionTable(data, container);
}

function renderMaterialView(data) {
  if (!data || !data.hierarchy) {
    var container = document.getElementById('page-material');
    container.innerHTML = '<div class="mv-error">需要更新插件（hierarchy 数据缺失）</div>';
    return;
  }

  classifyNodes(data);

  var container = document.getElementById('page-material');
  var existingEmpty = container.querySelector('.empty-state');
  if (existingEmpty && !data.geometry_usages.length) {
    return;
  }
  container.innerHTML = '';

  renderToolbar(data, container, 'material');
  renderMaterialTable(data, container);
}

// Legacy entry — routes based on current page
function renderModelView(data) {
  var page = window._currentPage;
  if (page === 'material') renderMaterialView(data);
  else renderPositionView(data);
}

// ---------------- Filter setter ----------------
function setModelFilter(filter) {
  _mv.materialFilter = filter;
  if (window._workbench) renderMaterialView(window._workbench);
}

// ---------------- CSV export ----------------
function exportModelCsv(data, mode) {
  var rows = [];
  var groupLabel = mode === 'position' ? '按位置' : '按材料';

  if (mode === 'position') {
    rows.push(['#', '名称 / 材质', '面积(m²)', '长度(mm)', '件数', '地面', '墙面', '天花', '待处理']);
    var seq = 0;
    collectPositionCsvRows(data.hierarchy, data, rows, seq);
  } else {
    rows.push(['#', '状态', 'SU材质', '面数/用量', '部位分布', '位置数', '位置', '真实材料']);
    var materialsInfo = data.materials_info || [];
    var unresolved = data.unresolved || [];
    var ignored = data.ignored || [];
    var unresolvedSet = {};
    unresolved.forEach(function(n) { unresolvedSet[n] = true; });
    var ignoredSet = {};
    ignored.forEach(function(n) { ignoredSet[n] = true; });
    var mapping = {};
    materialsInfo.forEach(function(m) { mapping[m.su_name] = m; });

    var byMaterial = {};
    (data.geometry_usages || []).forEach(function(u) {
      if (u.is_instance) return;
      var key = u.su_material || '(无材质)';
      byMaterial[key] = byMaterial[key] || [];
      byMaterial[key].push(u);
    });

    Object.keys(byMaterial).forEach(function(key, idx) {
      var usages = byMaterial[key];
      var info = mapping[key] || {};
      var status = getMaterialStatus(key, unresolvedSet, ignoredSet, mapping);
      var totalArea = 0, totalLength = 0, totalFace = 0;
      var partFloor = 0, partWall = 0, partCeil = 0;
      var locs = {};
      usages.forEach(function(u) {
        totalFace += u.face_count || 0;
        if (u.unit === 'm') totalLength += u.qty * 1000;
        else totalArea += u.qty;
        partFloor += (u.by_part && u.by_part.floor) || 0;
        partWall += (u.by_part && u.by_part.wall) || 0;
        partCeil += (u.by_part && u.by_part.ceiling) || 0;
        var top = findTopLevelGroup(u.entity_id, data.hierarchy);
        if (top) locs[top.name] = true;
      });
      var mainQty = totalArea > 0 ? fmtNum(totalArea) + ' m²' : fmtNum(totalLength) + ' mm';
      var parts = '';
      if (partFloor > 0) parts += '地' + fmtNum(partFloor) + ' ';
      if (partWall > 0) parts += '墙' + fmtNum(partWall) + ' ';
      if (partCeil > 0) parts += '天' + fmtNum(partCeil);
      var locNames = Object.keys(locs);
      rows.push([idx + 1, status, key, totalFace + '面/' + mainQty, parts, locNames.length, locNames.slice(0, 3).join(','), info.material_name || '—']);
    });
  }

  var csv = '﻿'; // BOM
  rows.forEach(function(r) {
    csv += r.map(csvEscape).join(',') + '\n';
  });
  var blob = new Blob([csv], { type: 'text/csv;charset=utf-8' });
  var a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'model_view_完整_' + groupLabel + '.csv';
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
    fmtNum(stats.area),
    fmtNum(stats.length),
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
  return n < 1 ? n.toFixed(2) : n < 100 ? n.toFixed(1) : Math.round(n).toString();
}