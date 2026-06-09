// src/ui/app.js — 核心：导航、桥接、状态、工具函数

function renderWorkbenchError(info) {
  hideLoading();
  var container = document.getElementById('page-position');
  container.innerHTML = '<div class="mv-error">' + esc(info.error) + '<br><small>' +
    (info.backtrace || []).map(esc).join('<br>') + '</small></div>';
  console.error('Workbench error:', info);
}

// ---------------- Sidebar navigation ----------------
document.querySelectorAll('.sb-nav').forEach(function(btn) {
  btn.addEventListener('click', function() {
    switchPage(btn.dataset.page);
  });
});

function switchPage(page) {
  window._currentPage = page;
  document.querySelectorAll('.sb-nav').forEach(function(b) { b.classList.remove('active'); });
  document.querySelector('.sb-nav[data-page="' + page + '"]').classList.add('active');
  document.querySelectorAll('.page-content').forEach(function(p) { p.style.display = 'none'; });
  document.getElementById('page-' + page).style.display = 'block';
  if (page === 'mapping') callSketchUp('get_mappings');
  if (page === 'comp-mapping') callSketchUp('get_component_mappings');
  if (page === 'settings') callSketchUp('get_settings');
  if (isView) renderCurrentPage();
}

// ---------------- Bridge ----------------
function callSketchUp(action, json) {
  if (typeof sketchup !== 'undefined') {
    sketchup[action](json || '');
  } else {
    console.warn('Not running in SketchUp HtmlDialog');
  }
}

// ---------------- Scan entry ----------------
function showLoading() {
  document.getElementById('loading-overlay').style.display = 'flex';
  document.querySelectorAll('.sb-btn').forEach(function(b) { b.disabled = true; });
}
function hideLoading() {
  document.getElementById('loading-overlay').style.display = 'none';
  document.querySelectorAll('.sb-btn').forEach(function(b) { b.disabled = false; });
}

function scanAll() { showLoading(); callSketchUp('scan_all'); }
function scanSelected() { showLoading(); callSketchUp('scan_selected'); }

// ---------------- Workbench state ----------------
window._workbench = null;
window._currentPage = 'position';

window.receiveFaces = function(data) {
  if (!window._workbench) return;
  if (!window._workbench._facesCache) window._workbench._facesCache = {};
  var cacheKey = data.entity_id + ':' + data.su_material;
  window._workbench._facesCache[cacheKey] = data.faces || [];
  if (window._facesRequested) delete window._facesRequested[cacheKey];
  renderModelView(window._workbench);
};

function renderWorkbench(data) {
  hideLoading();
  try {
    window._workbench = data;
    window._workbench._facesCache = {};
    window._facesRequested = {};
    buildWorkbenchIndexes(data);
    // 保留已有展开状态（标签/映射变更触发重扫时避免折叠）
    if (!_mv.expandedNodes) _mv.expandedNodes = {};
    if (!_mv.expandedSpecs) _mv.expandedSpecs = {};
    document.querySelectorAll('.page-content .empty-state').forEach(function(el) { el.style.display = 'none'; });
    renderCurrentPage();
  } catch(e) {
    var container = document.getElementById('page-position');
    container.innerHTML = '<div class="mv-error">渲染错误: ' + e.message + '</div>';
    console.error('renderWorkbench error:', e);
  }
}

function buildWorkbenchIndexes(data) {
  var h = data.hierarchy;
  var byId = {};
  if (h) {
    function walk(node) {
      byId[node.entity_id] = node;
      (node.children || []).forEach(walk);
    }
    walk(h);
  }
  data._byEntityId = byId;

  var maxDepth = 0;
  if (h) {
    function findDepth(node) {
      if (node.depth > maxDepth) maxDepth = node.depth;
      (node.children || []).forEach(findDepth);
    }
    findDepth(h);
  }
  data._maxDepth = maxDepth;

  // Index geometry_usages by entity_id
  var usagesByEid = {};
  (data.geometry_usages || []).forEach(function(u) {
    var eid = u.entity_id;
    usagesByEid[eid] = usagesByEid[eid] || [];
    usagesByEid[eid].push(u);
  });
  data._usagesByEntityId = usagesByEid;
}

function renderCurrentPage() {
  if (!window._workbench) return;
  var page = window._currentPage;
  if (page === 'position') renderPositionView(window._workbench);
}

// ---------------- Shared helpers ----------------
function esc(s) {
  if (s === null || s === undefined) return '';
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
                  .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function escAttr(s) { return esc(s).replace(/'/g, "\\'"); }

function csvEscape(v) {
  var s = String(v == null ? '' : v);
  if (s.indexOf(',') >= 0 || s.indexOf('"') >= 0 || s.indexOf('\n') >= 0) {
    return '"' + s.replace(/"/g, '""') + '"';
  }
  return s;
}

var DEFAULT_CATEGORIES = ['瓷砖', '石材', '涂料', '木材', '墙纸', '玻璃', '金属', '其他'];

function locateMaterial(suName) {
  callSketchUp('locate_material', suName);
}

function locateFace(faceId, pathIds) {
  callSketchUp('locate_face', JSON.stringify({ face_id: faceId, path_ids: pathIds || [] }));
}

function locateEntity(entityId) {
  callSketchUp('locate_entity', String(entityId));
}

// ---------------- Model → UI face highlight ----------------
window.highlightFaceInUI = function(faceId, activePathIds) {
  if (!window._workbench) return;

  var data = window._workbench;
  var geoUsages = data.geometry_usages || [];
  var targetEntityId = null;
  var targetUsage = null;

  // 按完整路径匹配面：face_id 相同 + path_ids 相同 = 同一实例中的同一个面
  // 使用 face_refs（紧凑索引），避免依赖懒加载的 faces 数组
  var pathIds = activePathIds || [];
  for (var i = 0; i < geoUsages.length; i++) {
    var faceRefs = geoUsages[i].face_refs || [];
    for (var j = 0; j < faceRefs.length; j++) {
      if (faceRefs[j].face_id === faceId && arraysEqual(faceRefs[j].path_ids, pathIds)) {
        targetEntityId = geoUsages[i].entity_id;
        targetUsage = geoUsages[i];
        break;
      }
    }
    if (targetEntityId !== null) break;
  }

  if (targetEntityId === null) return;

  // 展开从根到目标 entity 路径上的所有祖先节点
  expandAncestorsToEntity(data.hierarchy, targetEntityId);

  // 设置高亮面 key（face_id + 路径）并重绘
  _mv.highlightFaceKey = faceId + ':' + pathIds.join(',');
  renderPositionView(data);

  // 滚动到高亮行
  requestAnimationFrame(function() {
    var el = document.querySelector('.mv-highlight');
    if (el) el.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  });
};

window.clearFaceHighlight = function() {
  delete _mv.highlightFaceKey;
  var els = document.querySelectorAll('.mv-highlight');
  for (var i = 0; i < els.length; i++) {
    els[i].classList.remove('mv-highlight');
  }
};

// 沿 hierarchy 树查找从根到 targetEid 的路径，展开所有祖先
function expandAncestorsToEntity(root, targetEid) {
  function findPath(node, target, path) {
    if (node.entity_id === target) {
      path.push(node.entity_id);
      return true;
    }
    for (var i = 0; i < node.children.length; i++) {
      if (findPath(node.children[i], target, path)) {
        path.push(node.entity_id);
        return true;
      }
    }
    return false;
  }

  var path = [];
  findPath(root, targetEid, path);
  for (var i = 0; i < path.length; i++) {
    if (path[i] !== 0) {
      _mv.expandedNodes[path[i]] = true;
    }
  }
}

function arraysEqual(a, b) {
  if (!a || !b) return (!a || a.length === 0) && (!b || b.length === 0);
  if (a.length !== b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}
