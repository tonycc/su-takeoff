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

function mvNodeKey(node) {
  return nodeOccurrenceKey(node);
}

function mvNodeUsages(node, data) {
  var byPath = data._usagesByPath || {};
  var found = byPath[mvNodeKey(node)];
  if (found) return found;
  return (data._usagesByEntityId || {})[node.entity_id] || [];
}

function mvMergedKey(node) {
  var parentPath = (node.component_path_ids || []).slice(0, -1);
  return 'merged:' + occurrencePathKey(parentPath) + ':' + getMergeKey(node);
}

// ---------------- Node classification ----------------
function classifyNodes(data) {
  if (data._classification) return;
  var cls = {};
  var usagesByPath = data._usagesByPath || {};

  function walk(node) {
    var nodeKey = mvNodeKey(node);
    if (node.hidden) {
      cls[nodeKey] = 'hidden_skipped';
      node.children.forEach(walk);
      return;
    }
    var usages = usagesByPath[nodeKey] || mvNodeUsages(node, data);
    var hasFace = false, hasInst = false;
    usages.forEach(function(u) {
      if (u.is_instance) hasInst = true;
      else hasFace = true;
    });
    var childTags = [];
    node.children.forEach(function(c) {
      walk(c);
      childTags.push(cls[mvNodeKey(c)]);
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
    cls[nodeKey] = tag;
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
  var merged = { area: 0, length: 0, volume: 0, count: 0, floor: 0, wall: 0, ceiling: 0 };
  nodes.forEach(function(n) {
    var s = rollupStats(n, data);
    merged.area    += s.area;
    merged.length  += s.length;
    merged.volume  += s.volume;
    merged.count   += s.count;
    merged.floor   += s.floor;
    merged.wall    += s.wall;
    merged.ceiling += s.ceiling;
  });
  return merged;
}

// 合并多个节点的 selfUsages
function mergeSelfUsages(nodes, data) {
  var result = [];
  nodes.forEach(function(n) {
    mvNodeUsages(n, data).forEach(function(u) {
      // 每个 occurrence 的 usage 都保留；共享定义的 entity_id 相同并不代表重复数据。
      result.push(u);
    });
  });
  return result;
}

// ---------------- Rollup stats ----------------
function rollupStats(node, data) {
  var cls = data._classification || {};
  var materials = {};
  var result = { area: 0, length: 0, volume: 0, count: 0, floor: 0, wall: 0, ceiling: 0, matCount: 0 };

  // Ruby Presenter 已按页面规则完成组件树汇总；优先使用它，避免前端再次
  // 聚合出与推送构建器不同的结果。旧状态没有 component_rows 时保留下方兼容逻辑。
  var displayRow = (data._componentRowsByPath || {})[mvNodeKey(node)] ||
    (data._componentRowsByEntityId || {})[node.entity_id];
  if (displayRow) {
    result.area = displayRow.area_m2 || 0;
    result.length = displayRow.length_mm || 0;
    result.volume = displayRow.volume_m3 || 0;
    result.count = displayRow.count || 0;
    result.floor = displayRow.floor || 0;
    result.wall = displayRow.wall || 0;
    result.ceiling = displayRow.ceiling || 0;
    (displayRow.materials || []).forEach(function(material) { materials[material] = true; });
    result._materials = materials;
    result.matCount = Object.keys(materials).length;
    return result;
  }

  // Self usages
  var selfUsages = mvNodeUsages(node, data);
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
      materials[u.su_material] = true;
    }
  });

  // Recursive children
  node.children.forEach(function(c) {
    if (c.hidden && !_mv.showHidden) return;
    var tag = cls[mvNodeKey(c)];
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
    clearTimeout(_mv.searchTimer);
    _mv.searchTimer = setTimeout(function() {
      renderPositionView(data);
      var replacement = document.querySelector('.mv-search');
      if (replacement) {
        replacement.focus();
        replacement.setSelectionRange(replacement.value.length, replacement.value.length);
      }
    }, 150);
  };
  searchWrap.appendChild(searchInput);
  row2.appendChild(searchWrap);

  // Export
  var exportBtn = document.createElement('button');
  exportBtn.className = 'mv-export-btn';
  exportBtn.textContent = '⤓ 导出';
  exportBtn.onclick = function() { exportModelCsv(data); };
  row2.appendChild(exportBtn);

  // 推送入口放在按组件页面，推送状态仍由项目绑定与云端推送状态统一驱动。
  var cloudState = window._cloudState || {};
  var cloudAuth = cloudState.auth || {};
  var bindingReady = cloudBindingReady(cloudState);
  var pushBtn = document.createElement('button');
  pushBtn.className = 'mv-push-btn primary-btn';
  pushBtn.textContent = cloudState.busy ? '推送中…' : '推送算量';
  pushBtn.disabled = !!cloudState.busy || !cloudState.has_scan || !cloudAuth.can_push || !bindingReady;
  pushBtn.title = cloudPushDisabledReason(cloudState);
  pushBtn.onclick = function() {
    if (!pushBtn.disabled && typeof window.cloudPush === 'function') window.cloudPush();
  };
  var pushSpacer = document.createElement('span');
  pushSpacer.className = 'mv-toolbar-spacer';
  var pushFeedback = document.createElement('span');
  pushFeedback.className = 'mv-push-feedback';
  applyPositionCloudFeedback(pushFeedback, cloudState);
  row2.appendChild(pushSpacer);
  row2.appendChild(pushFeedback);
  row2.appendChild(pushBtn);
  tb.appendChild(row2);

  container.appendChild(tb);
}

window.updatePositionCloudControls = function updatePositionCloudControls() {
  var button = document.querySelector('.mv-push-btn');
  if (!button) return;
  var state = window._cloudState || {};
  var auth = state.auth || {};
  button.textContent = state.busy ? '推送中…' : '推送算量';
  button.disabled = !!state.busy || !state.has_scan || !auth.can_push || !cloudBindingReady(state);
  button.title = cloudPushDisabledReason(state);
  var feedback = document.querySelector('.mv-push-feedback');
  if (feedback) applyPositionCloudFeedback(feedback, state);
};

function cloudBindingReady(state) {
  var binding = (state && state.binding) || {};
  return !!String(binding.project_code || '').trim() && !!String(binding.project_name || '').trim();
}

function cloudPushDisabledReason(state) {
  state = state || {};
  var auth = state.auth || {};
  if (state.busy) return '已有推送任务正在执行';
  if (!state.has_scan) return '请先扫描当前模型';
  if (!auth.can_push) return '当前账号未登录或缺少算量推送权限';
  if (!cloudBindingReady(state)) return '请先在项目绑定页选择并保存项目';
  return '';
}

function positionCloudFeedback(state) {
  state = state || {};
  if (state.error) {
    return { kind: 'error', text: String(state.error.message || state.error) };
  }

  var result = state.sync_result;
  if (result) {
    if (result.success) return { kind: 'success', text: '推送成功' };
    if (result.issues && result.issues.length) {
      return {
        kind: 'error',
        text: result.issues.map(function(issue) { return issue.message || issue.code; }).join('；')
      };
    }
    if (result.error) {
      return { kind: 'error', text: String(result.error.message || result.error.code || '推送失败') };
    }
  }

  if (state.busy) return { kind: 'pending', text: state.status_message || '正在推送…' };
  if (!cloudBindingReady(state)) return { kind: 'warning', text: '请先绑定平台项目' };
  return { kind: '', text: '' };
}

function applyPositionCloudFeedback(element, state) {
  var feedback = positionCloudFeedback(state);
  element.className = 'mv-push-feedback' + (feedback.kind ? ' mv-push-feedback-' + feedback.kind : '');
  element.textContent = feedback.text;
  element.title = feedback.text;
}

// ---------------- Position mode: tree table ----------------
// Sortable column keys mapped to column index
var POS_SORT_COLS = { 1: 'name', 3: 'tag', 4: 'area', 5: 'length', 6: 'volume', 7: 'count', 8: 'floor', 9: 'wall', 10: 'ceiling' };

function renderPositionTable(data, container) {
  var cls = data._classification;
  var usagesByEid = data._usagesByPath;
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
  var cols = ['#', '名称 / 材质', '产品信息', '算量标签', '面积(m²)', '长度(mm)', '体积(m³)', '件数', '地面', '墙面', '天花', '操作'];
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
    tag: node.tag, occurrence_key: node.occurrence_key,
    component_path_ids: (node.component_path_ids || []).slice(),
    component_path_persistent_ids: (node.component_path_persistent_ids || []).slice(),
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
  var tag = cls[mvNodeKey(node)];
  if (tag === 'hidden_skipped') return false;
  if (tag === 'pure_organizational' && !_mv.showEmpty) return false;
  return true;
}

function getSortValue(node, data, cls, col) {
  if (col === 'name') return node.name;
  if (col === 'tag') return node.tag || '';
  var stats = rollupStats(node, data);
  return stats[col] || 0;
}

function findSearchMatches(node, query, data, matches) {
  var nameMatch = node.name.toLowerCase().indexOf(query.toLowerCase()) >= 0;
  var matMatch = false;
  var usages = mvNodeUsages(node, data);
  usages.forEach(function(u) {
    if (u.su_material && u.su_material.toLowerCase().indexOf(query.toLowerCase()) >= 0) matMatch = true;
  });
  if (nameMatch || matMatch) {
    matches[mvNodeKey(node)] = true;
  }
  node.children.forEach(function(c) {
    findSearchMatches(c, query, data, matches);
    if (matches[mvNodeKey(c)]) matches[mvNodeKey(node)] = true;
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
    fmtNum(partCeiling)
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
  var occurrenceKey = usage.occurrence_key || occurrencePathKey(usage.component_path_ids || [parentEntityId]);
  var matKey = occurrenceKey + ':' + usage.su_material;
  var isMatExpanded = _mv.expandedMaterials && _mv.expandedMaterials[matKey];
  var isLinear = usage.unit === 'm';

  var row = document.createElement('tr');
  row.className = 'mv-mat-summary-row ' +
    (usage.confidence === 'heuristic' ? 'mv-mat-heuristic' : 'mv-mat-summary-mapped');
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

  if (usage.confidence === 'heuristic') {
    var confidenceBadge = document.createElement('span');
    confidenceBadge.className = 'tag-heuristic';
    confidenceBadge.textContent = '待确认';
    confidenceBadge.title = '该计量方式来自几何启发，请通过算量标签确认';
    tdName.appendChild(confidenceBadge);
  }

  row.appendChild(tdName);

  // 产品信息（材料汇总行不展示 SKU；SKU 关联在组件行维度）
  var tdInfo = document.createElement('td');
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
    fmtNum(byPart.ceiling || 0)
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
    var cacheKey = occurrenceKey + ':' + usage.su_material;
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
      loadTd.colSpan = 12;
      loadTd.style.cssText = 'text-align:center;color:#6c7086;font-size:12px;padding:6px';
      loadTd.textContent = '加载面详情…';
      loadRow.appendChild(loadTd);
      tbody.appendChild(loadRow);
      window._facesRequested = window._facesRequested || {};
      if (!window._facesRequested[cacheKey]) {
        window._facesRequested[cacheKey] = true;
        callSketchUp('get_faces', JSON.stringify({
          entity_id: usage.entity_id,
          component_path_ids: usage.component_path_ids || [],
          su_material: usage.su_material
        }));
      }
    }
  }
}

// 构建组件行「产品信息」单元格：从当前项目产品库选择实际产品，选中即存到组件级关联。
// definitionKeys 为单个定义名或定义名数组（合并行传入组内全部成员的定义名，
// 选择/清除时逐一关联，与合并行标签下拉循环打标同一模式）。
function componentProductCode(record) {
  record = record || {};
  // 产品信息列显示项目自定义编号；旧数据没有项目编号时才回退目录编号。
  return record.project_product_code || record.catalog_code || record.sku_code || '';
}

function componentProductName(record) {
  record = record || {};
  return record.product_name || record.sku_name || '';
}

function buildSkuCell(definitionKeys, data) {
  var keys = Array.isArray(definitionKeys) ? definitionKeys : [definitionKeys];
  var primaryKey = keys[0];
  var td = document.createElement('td');
  td.className = 'col-sku';
  var skus = (data && data.component_skus) || {};
  var cur = skus[primaryKey] || {};

  var wrap = document.createElement('div');
  wrap.className = 'sku-input-wrap';

  var input = document.createElement('input');
  input.type = 'text';
  input.className = 'u-sku';
  input.autocomplete = 'off';
  input.placeholder = '模糊搜索项目产品';
  input.value = componentProductCode(cur)
    ? (componentProductCode(cur) + ' ' + componentProductName(cur)) : '';

  var clearBtn = document.createElement('button');
  clearBtn.type = 'button';
  clearBtn.className = 'sku-clear';
  clearBtn.title = '清除关联';
  clearBtn.textContent = '×';

  function refreshState() {
    var hasText = !!input.value;
    clearBtn.style.display = hasText ? 'block' : 'none';
    var code = componentProductCode(cur);
    var name = componentProductName(cur);
    input.classList.toggle('has-value', !!code && input.value === (code + ' ' + name));
  }

  wrap.appendChild(input);
  wrap.appendChild(clearBtn);
  td.appendChild(wrap);

  var dd = document.createElement('div');
  dd.className = 'sku-dropdown';
  dd.style.display = 'none';
  td.appendChild(dd);

  input.addEventListener('input', refreshState);
  // 选择/清除时对组内每个定义名逐一持久化
  function persistSku(fields) {
    var items = keys.map(function(k) {
      var payload = { definition_name: k };
      for (var prop in fields) {
        if (Object.prototype.hasOwnProperty.call(fields, prop)) payload[prop] = fields[prop];
      }
      return payload;
    });
    if (items.length === 1) callSketchUp('set_component_sku', JSON.stringify(items[0]));
    else callSketchUp('set_component_skus', JSON.stringify({ items: items }));
  }
  clearBtn.addEventListener('click', function() {
    input.value = '';
    cur = {};
    td.dataset.skuId = '';
    td.dataset.skuCode = '';
    td.dataset.skuName = '';
    refreshState();
    dd.style.display = 'none';
    persistSku({
      project_product_id: '', product_id: '', catalog_code: '',
      product_name: '', project_product_code: ''
    });
  });

  if (typeof bindSkuAutocomplete === 'function') {
    bindSkuAutocomplete(td, function(item) {
      cur = {
        project_product_id: item.project_product_id || '',
        product_id: item.product_id || '',
        catalog_code: item.catalog_code || item.code || '',
        product_name: item.product_name || item.name || '',
        project_product_code: item.project_product_code || ''
      };
      refreshState();
      persistSku({
        project_product_id: cur.project_product_id,
        product_id: cur.product_id,
        catalog_code: cur.catalog_code,
        product_name: cur.product_name,
        project_product_code: cur.project_product_code
      });
    });
  }
  refreshState();
  return td;
}

function renderNodeRows(node, data, cls, usagesByEid, tbody, seq, searchMatches, depthOverride, skipSearch, ancestorHasTag) {
  var nodeKey = mvNodeKey(node);
  var tag = cls[nodeKey];  if (!tag) return seq;

  // Skip hidden
  if (node.hidden && !_mv.showHidden) return seq;
  if (tag === 'hidden_skipped' && !_mv.showHidden) return seq;

  // Skip empty (pure_organizational)
  if (tag === 'pure_organizational' && !_mv.showEmpty) return seq;

  // Search: skip nodes not in match path (skipSearch bypasses for promoted children)
  if (_mv.searchQuery && !skipSearch && !searchMatches[nodeKey]) return seq;

  var effectiveDepth = depthOverride !== undefined ? depthOverride : node.depth;
  var hasChildren = node.children.length > 0;
  var isExpanded = isNodeExpanded(node, searchMatches);

  // Component instance with children: always show row, children indented when expanded

  var stats = rollupStats(node, data);
  var selfUsages = usagesByEid[nodeKey] || mvNodeUsages(node, data);

  // Determine display values based on tag
  var area = '-', length = '-', volume = '-', count = '-', floor = '-', wall = '-', ceiling = '-';

  if (tag === 'has_face_items' || tag === 'has_descendant_stats') {
    area = fmtNum(stats.area);
    length = fmtNum(stats.length);
    volume = stats.volume > 0 ? fmtNum(stats.volume) : '-';
    count = stats.count > 0 ? fmtNum(stats.count) : '-';
    floor = fmtNum(stats.floor);
    wall = fmtNum(stats.wall);
    ceiling = fmtNum(stats.ceiling);
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
  row.dataset.occurrenceKey = nodeKey;

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
      _mv.expandedNodes[nodeKey] = !isExpanded;
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

  // 产品信息（组件/群组项目产品选择：有定义名即可选产品，群组用内部定义名）
  var tdInfo = node.definition_name
    ? buildSkuCell(node.definition_name, data)
    : document.createElement('td');
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
          component_path_ids: node.component_path_ids || [],
          tag_name: tagSelect.value
        }));
      };
      tdTag.appendChild(tagSelect);
    }
  }
  row.appendChild(tdTag);

  // Numeric cols
  var numCols = [area, length, volume, count, floor, wall, ceiling];
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
      callSketchUp('locate_entity', JSON.stringify({
        entity_id: node.entity_id,
        component_path_ids: node.component_path_ids || []
      }));
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
            var soloKey = 'solo:' + mvNodeKey(c);
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

// 返回当前按组件页面真正显示的“组件树节点”路径。
// 只记录组件/群组行，不记录材料汇总行、规格行和具体面；父节点折叠时，
// 子节点不会被记录。路径使用 entity_id 数组，避免重复组件定义的子节点串线。
window.getVisibleComponentPathsForPush = function getVisibleComponentPathsForPush(data) {
  data = data || window._workbench;
  if (!data || !data.hierarchy) return [];

  classifyNodes(data);
  var cls = data._classification || {};
  var searchMatches = {};
  if (_mv.searchQuery) findSearchMatches(data.hierarchy, _mv.searchQuery, data, searchMatches);
  var result = [];

  function isVisible(node) {
    var key = mvNodeKey(node);
    var tag = cls[key];
    if (!tag) return false;
    if (node.hidden && !_mv.showHidden) return false;
    if (tag === 'hidden_skipped' && !_mv.showHidden) return false;
    if (tag === 'pure_organizational' && !_mv.showEmpty) return false;
    if (_mv.searchQuery && !searchMatches[key]) return false;
    return true;
  }

  function addPath(path) {
    if (path.length === 0) return;
    var key = path.join('/');
    for (var i = 0; i < result.length; i++) {
      if (result[i].join('/') === key) return;
    }
    result.push(path.slice());
  }

  function walk(node, parentPath, forceVisible) {
    if (!forceVisible && !isVisible(node)) return;

    var path = Array.isArray(node.component_path_ids)
      ? node.component_path_ids.slice()
      : (node.entity_id === 0 ? parentPath.slice() : parentPath.concat([node.entity_id]));
    if (node.entity_id !== 0) addPath(path);

    if (!isNodeExpanded(node, searchMatches)) return;
    if (!node.children || node.children.length === 0) return;

    if (_mv.mergeSame) {
      var groups = {};
      var order = [];
      node.children.forEach(function(child) {
        var mergeKey = getMergeKey(child);
        var key = mergeKey || ('solo:' + mvNodeKey(child));
        if (!groups[key]) {
          groups[key] = [];
          order.push(key);
        }
        groups[key].push(child);
      });

      order.forEach(function(key) {
        var group = groups[key];
        if (group.length > 1) {
          // 合并行仍代表组内每个真实树节点，但成员不会各自触发展开逻辑。
          group.forEach(function(child) {
            addPath((child.component_path_ids || path.concat([child.entity_id])).slice());
          });
          var mergedExpandKey = mvMergedKey(group[0]);
          if (_mv.expandedNodes[mergedExpandKey]) {
            var allChildren = [];
            group.forEach(function(member) {
              (member.children || []).forEach(function(child) { allChildren.push(child); });
            });
            allChildren.forEach(function(child) {
              var childParent = (child.component_path_ids || []).slice(0, -1);
              walk(child, childParent, false);
            });
          }
        } else {
          walk(group[0], path, false);
        }
      });
      return;
    }

    node.children.forEach(function(child) { walk(child, path, false); });
  }

  // 根节点只负责提供展开上下文，本身不进入返回值。
  walk(data.hierarchy, [], false);
  return result;
};

// 合并行渲染：将同定义名的多个组件实例合并为一行
function renderMergedRow(nodes, data, cls, usagesByEid, tbody, seq, searchMatches, depth, ancestorHasTag) {
  var first = nodes[0];
  var mergedStats = mergeStats(nodes, data);
  var mergedUsages = mergeSelfUsages(nodes, data);
  var allChildren = [];
  nodes.forEach(function(n) { n.children.forEach(function(c) { allChildren.push(c); }); });

  var expandKey = mvMergedKey(first);
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
  // 群组的 definition_name 是内部名（Group#3），不做展示，只用节点名
  var mergedDefName = first.kind === 'component_instance' ? first.definition_name : null;
  nameSpan.textContent = mergedDefName || first.name;
  tdName.appendChild(nameSpan);

  // Definition name label
  if (mergedDefName) {
    var defLabel = document.createElement('span');
    defLabel.className = 'mv-def-label';
    defLabel.textContent = mergedDefName;
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

  // 产品信息（合并行：项目产品选择应用到组内每个成员的定义名，组件/群组均可选）
  var skuKeys = [];
  nodes.forEach(function(n) {
    if (n.definition_name && skuKeys.indexOf(n.definition_name) < 0) skuKeys.push(n.definition_name);
  });
  var tdInfo = skuKeys.length > 0
    ? buildSkuCell(skuKeys, data)
    : document.createElement('td');
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
        callSketchUp('set_entity_tags', JSON.stringify({
          entities: nodes.map(function(n) { return {
            entity_id: n.entity_id,
            component_path_ids: n.component_path_ids || []
          }; }),
          tag_name: tagSelect.value
        }));
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

  [area, length, volume, count, floor, wall, ceiling].forEach(function(v) {
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
    callSketchUp('locate_entity', JSON.stringify({
      entity_id: first.entity_id,
      component_path_ids: first.component_path_ids || []
    }));
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
  var key = mvNodeKey(node);
  if (_mv.expandedNodes[key] !== undefined) {
    return _mv.expandedNodes[key];
  }
  if (_mv.searchQuery && searchMatches[key]) {
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
    container.innerHTML = '';
    var errorBox = document.createElement('div');
    errorBox.className = 'mv-error';
    errorBox.textContent = '渲染错误: ' + e.message;
    container.appendChild(errorBox);
  }
}

// ---------------- CSV export ----------------
function exportModelCsv(data) {
  var rows = [];
  rows.push(['#', '名称 / 材质', '产品信息', '算量标签', '面积(m²)', '长度(mm)', '体积(m³)', '件数', '地面', '墙面', '天花']);
  // 直接导出当前可见组件行，天然遵循搜索、排序、合并和展开状态。
  var table = document.querySelector('#page-position .mv-table');
  if (table) {
    table.querySelectorAll('tbody tr.mv-row').forEach(function(row) {
      var cells = row.querySelectorAll('td');
      var values = [];
      for (var i = 0; i < 11 && i < cells.length; i++) {
        values.push(cells[i].textContent.trim());
      }
      rows.push(values);
    });
  }

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

// ---------------- Helpers ----------------
function fmtNum(n) {
  if (n === '-' || n === undefined || n === null) return '-';
  if (typeof n !== 'number') return String(n);
  if (n === 0) return '-';
  return n.toFixed(2);
}

// ---------------- 项目产品下拉选择（组合框：点击展开列表，支持模糊搜索）----------------
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
  tr._skuOnSelect = onSelect; // 选中项目产品后的回调（buildSkuCell 用它直接持久化组件级关联）
  window._ensureSkuCloser();

  // 状态：_skuItems = 当前候选列表（null = 未加载）；_skuError = 最近一次错误
  tr._skuItems = null;
  tr._skuError = null;
  tr._skuTotal = 0;
  tr._skuActiveIdx = -1;
  tr._skuCategory = '';
  var timer = null;

  function isOpen() { return dd.style.display !== 'none'; }
  function openDropdown() { dd.style.display = ''; }
  function closeDropdown() { dd.style.display = 'none'; tr._skuActiveIdx = -1; }

  // 已选中状态下输入框显示的是标签而非过滤词，此时按空过滤词展示全量候选
  function currentFilter() {
    return input.classList.contains('has-value') ? '' : input.value.trim();
  }

  function categoryNames(items) {
    var names = {};
    (items || []).forEach(function(item) {
      var name = String(item.category_name || '').trim();
      if (name) names[name] = true;
    });
    return Object.keys(names).sort(function(a, b) { return a.localeCompare(b, 'zh-CN'); });
  }

  function renderFilterBar() {
    var bar = document.createElement('div');
    bar.className = 'sku-filter-bar';

    var label = document.createElement('span');
    label.className = 'sku-filter-label';
    label.textContent = '类目';
    bar.appendChild(label);

    var select = document.createElement('select');
    select.className = 'sku-category-filter';
    var all = document.createElement('option');
    all.value = '';
    all.textContent = '全部类目';
    select.appendChild(all);

    var categories = categoryNames(tr._skuItems || []);
    if (tr._skuCategory && categories.indexOf(tr._skuCategory) < 0) {
      categories.unshift(tr._skuCategory);
    }
    categories.forEach(function(category) {
      var option = document.createElement('option');
      option.value = category;
      option.textContent = category;
      select.appendChild(option);
    });
    select.value = tr._skuCategory;
    select.disabled = !tr._skuItems || tr._skuItems.length === 0;
    select.addEventListener('change', function() {
      tr._skuCategory = select.value;
      tr._skuActiveIdx = -1;
      render();
    });
    bar.appendChild(select);
    return bar;
  }

  function filterItems(items, keyword) {
    var category = tr._skuCategory;
    var categoryItems = (items || []).filter(function(item) {
      return !category || String(item.category_name || '').trim() === category;
    });
    return keyword ? fuzzyFilterSkus(categoryItems, keyword) : categoryItems;
  }

  function render() {
    dd.innerHTML = '';
    dd.appendChild(renderFilterBar());
    if (tr._skuItems === null) {
      dd.appendChild(skuInfoOption('加载中…'));
      return;
    }
    if (tr._skuError) {
      dd.appendChild(skuInfoOption('查询失败：' + tr._skuError));
      return;
    }
    var kw = currentFilter();
    var filtered = filterItems(tr._skuItems, kw);
    if (filtered.length === 0) {
      dd.appendChild(skuInfoOption(tr._skuCategory ? '当前类目下无匹配产品' : '无匹配产品'));
      return;
    }
    filtered.forEach(function(it, idx) {
      var opt = skuOption(it, tr);
      if (idx === tr._skuActiveIdx) opt.classList.add('active');
      dd.appendChild(opt);
    });
    var foot = document.createElement('div');
    foot.className = 'sku-opt sku-foot';
    foot.textContent = (kw || tr._skuCategory)
      ? '匹配 ' + filtered.length + ' / ' + tr._skuItems.length + ' 条'
      : '共 ' + (tr._skuTotal || tr._skuItems.length) + ' 条';
    dd.appendChild(foot);
  }
  tr._skuRender = render;

  function fetchSkus(keyword) {
    window._skuReqId += 1;
    window._skuActiveRow = tr;
    callSketchUp('search_skus', JSON.stringify({
      keyword: keyword, req_id: window._skuReqId, page_size: 100
    }));
  }

  // 点击/聚焦：展开下拉；首次打开时拉取默认列表
  function activate() {
    openDropdown();
    render();
    if (tr._skuItems === null) fetchSkus('');
  }
  input.addEventListener('focus', activate);
  input.addEventListener('click', activate);

  // 输入：即时本地模糊过滤 + 防抖请求平台更新候选
  input.addEventListener('input', function() {
    clearTimeout(timer);
    // 手动编辑即视为撤销已选，需重新从下拉选择才会写回 sku 字段
    input.classList.remove('has-value');
    tr.dataset.skuId = '';
    tr.dataset.skuCode = '';
    tr.dataset.skuName = '';
    tr._skuActiveIdx = -1;
    openDropdown();
    render(); // 先用现有候选即时过滤，不等网络
    var kw = input.value.trim();
    timer = setTimeout(function() { fetchSkus(kw); }, 300);
  });

  // 键盘导航：↑/↓ 移动高亮，Enter 选中，Esc 关闭
  input.addEventListener('keydown', function(e) {
    if (e.key === 'Escape') { closeDropdown(); return; }
    if (!isOpen()) {
      if (e.key === 'ArrowDown') { activate(); e.preventDefault(); }
      return;
    }
    var opts = dd.querySelectorAll('.sku-opt:not(.sku-opt-info):not(.sku-foot)');
    if (opts.length === 0) return;
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      var delta = e.key === 'ArrowDown' ? 1 : -1;
      tr._skuActiveIdx = (tr._skuActiveIdx + delta + opts.length) % opts.length;
      render();
      var active = dd.querySelectorAll('.sku-opt:not(.sku-opt-info):not(.sku-foot)')[tr._skuActiveIdx];
      if (active && active.scrollIntoView) active.scrollIntoView({ block: 'nearest' });
    } else if (e.key === 'Enter') {
      if (tr._skuActiveIdx >= 0 && opts[tr._skuActiveIdx]) {
        e.preventDefault();
        opts[tr._skuActiveIdx].click();
      }
    }
  });
}

window.receiveSkuResults = function(data) {
  if (Number(data.req_id) !== window._skuReqId) return; // 丢弃过期响应
  var tr = window._skuActiveRow;
  if (!tr || !tr.isConnected) return; // 行已重建/分离则忽略
  if (data.error) {
    tr._skuError = data.error;
    tr._skuItems = tr._skuItems || [];
  } else {
    tr._skuError = null;
    tr._skuItems = data.items || [];
    tr._skuTotal = data.total || tr._skuItems.length;
  }
  tr._skuActiveIdx = -1;
  if (tr._skuRender) tr._skuRender();
};

// 模糊过滤：优先子串命中，其次子序列（逐字乱序跳跃）命中；大小写不敏感
function fuzzyFilterSkus(items, kw) {
  var q = kw.toLowerCase();
  var sub = [], fuzzy = [];
  items.forEach(function(it) {
    var displayCode = it.project_product_code || it.code || it.catalog_code || '';
    var t = (displayCode + ' ' + (it.name || '') + ' ' + (it.spec || '') + ' ' +
             ((it.brand && it.brand.name) || '') + ' ' + (it.category_name || '')).toLowerCase();
    if (t.indexOf(q) >= 0) sub.push(it);
    else if (skuSubsequenceMatch(t, q)) fuzzy.push(it);
  });
  return sub.concat(fuzzy);
}

function skuSubsequenceMatch(text, query) {
  var i = 0;
  for (var j = 0; j < text.length && i < query.length; j++) {
    if (text[j] === query[i]) i++;
  }
  return i === query.length;
}

// 提示性占位项（加载中 / 无结果 / 失败），不可点击
function skuInfoOption(text) {
  var div = document.createElement('div');
  div.className = 'sku-opt sku-opt-info';
  div.textContent = text;
  return div;
}

// 项目产品选项：主行 = 项目产品自定义编号 + 名称，副行 = 规格 / 品牌 / 分类
function skuOption(item, tr) {
  var div = document.createElement('div');
  div.className = 'sku-opt';

  var main = document.createElement('div');
  main.className = 'sku-opt-main';
  var code = document.createElement('span');
  code.className = 'sku-opt-code';
  code.textContent = item.project_product_code || item.code || item.catalog_code || '(无编号)';
  main.appendChild(code);
  if (item.name) {
    var name = document.createElement('span');
    name.className = 'sku-opt-name';
    name.textContent = item.name;
    main.appendChild(name);
  }
  div.appendChild(main);

  var subParts = [];
  if (item.spec) subParts.push(item.spec);
  if (item.brand && item.brand.name) subParts.push(item.brand.name);
  if (item.category_name) subParts.push(item.category_name);
  if (subParts.length > 0) {
    var sub = document.createElement('div');
    sub.className = 'sku-opt-sub';
    sub.textContent = subParts.join(' · ');
    div.appendChild(sub);
  }

  div.onclick = function() {
    var input = tr.querySelector('.u-sku');
    var displayCode = item.project_product_code || item.code || item.catalog_code || '';
    input.value = displayCode + ' ' + (item.name || '');
    tr.dataset.skuId = item.project_product_id || item.product_id || item.sku_id || '';
    tr.dataset.skuCode = displayCode;
    tr.dataset.skuName = item.name || '';
    tr.querySelector('.sku-dropdown').style.display = 'none';
    if (tr._skuOnSelect) tr._skuOnSelect(item);
  };
  return div;
}
