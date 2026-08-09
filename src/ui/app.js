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
  if (!window._pluginUnlocked && page !== 'login') {
    page = 'login';
  }
  var previousPage = window._currentPage;
  window._currentPage = page;
  document.body.classList.toggle('login-page-active', page === 'login');
  document.querySelectorAll('.sb-nav').forEach(function(b) { b.classList.remove('active'); });
  var nav = document.querySelector('.sb-nav[data-page="' + page + '"]');
  if (nav) nav.classList.add('active');
  document.querySelectorAll('.page-content').forEach(function(p) { p.style.display = 'none'; });
  document.getElementById('page-' + page).style.display = 'block';
  if (page === 'login' && previousPage !== 'login') callSketchUp('get_cloud_state');
  if (page === 'settings') callSketchUp('get_settings');
  if (page === 'cloud') callSketchUp('get_cloud_state');
  if (page === 'system') {
    if (typeof window.renderSystemManagement === 'function') {
      window.renderSystemManagement(window._cloudState || { status_message: '正在加载系统信息…' });
    }
    callSketchUp('get_cloud_state');
  }
  if (window._workbench) renderCurrentPage();
}

// ---------------- Bridge ----------------
function callSketchUp(action, json) {
  if (typeof sketchup !== 'undefined' && sketchup[action]) {
    sketchup[action](json || '');
  } else {
    handleBrowserPreview(action, json || '');
  }
}

function browserPreviewCloudState(extra) {
  var signedIn = !!window._browserPreviewSignedIn;
  var state = {
    api_configured: true,
    plugin_version: 'browser-preview',
    api_environment: 'browser-preview',
    api_base_url: 'http://127.0.0.1:8000',
    auth: {
      status: signedIn ? 'signed_in' : 'signed_out',
      account: window._browserPreviewAccount || '',
      can_push: signedIn
    },
    binding: { model_key: 'browser-preview-model' },
    has_scan: false,
    busy: false,
    force_login: !signedIn
  };
  Object.keys(extra || {}).forEach(function(key) { state[key] = extra[key]; });
  if (typeof window.renderCloudState === 'function') window.renderCloudState(state);
  if (typeof window.renderLoginState === 'function') window.renderLoginState(state);
}

function handleBrowserPreview(action, json) {
  if (action === 'get_cloud_state') {
    browserPreviewCloudState({
      status_message: window._browserPreviewSignedIn ? '浏览器预览：已模拟登录' : '浏览器预览：请登录后继续'
    });
    return;
  }
  if (action === 'cloud_login') {
    var data = {};
    try { data = JSON.parse(json || '{}'); } catch(e) { data = {}; }
    if (!String(data.username || '').trim()) {
      browserPreviewCloudState({ error: { message: '请输入账号' } });
      return;
    }
    if (!String(data.password || '')) {
      browserPreviewCloudState({
        error: { message: '请输入密码' },
        login_username: String(data.username || '').trim()
      });
      return;
    }
    window._browserPreviewSignedIn = true;
    window._browserPreviewAccount = String(data.username || '').trim();
    browserPreviewCloudState({ status_message: '浏览器预览：登录状态已更新', clear_password: true });
    return;
  }
  if (action === 'cloud_logout') {
    window._browserPreviewSignedIn = false;
    window._browserPreviewAccount = '';
    browserPreviewCloudState({ status_message: '浏览器预览：已退出登录', force_login: true });
    return;
  }
  if (action === 'search_projects') {
    var projectRequest = {};
    try { projectRequest = JSON.parse(json || '{}'); } catch(e) { projectRequest = {}; }
    if (typeof window.receiveProjectResults === 'function') {
      window.receiveProjectResults({
        req_id: projectRequest.req_id,
        items: [],
        error: '浏览器预览不会调用真实项目接口，请在 SketchUp 插件中查询项目'
      });
    }
    return;
  }
  if (!window._pluginUnlocked) {
    browserPreviewCloudState({ error: { message: '请先登录平台账号后再使用插件功能' }, force_login: true });
    return;
  }
  console.warn('Not running in SketchUp HtmlDialog:', action);
}

// ---------------- Scan entry ----------------
function showLoading() {
  if (!window._pluginUnlocked) {
    switchPage('login');
    return;
  }
  document.getElementById('loading-overlay').style.display = 'flex';
  document.querySelectorAll('.sb-btn').forEach(function(b) { b.disabled = true; });
}
function hideLoading() {
  document.getElementById('loading-overlay').style.display = 'none';
  refreshNavState();
}

function scanAll() {
  if (!window._pluginUnlocked) { switchPage('login'); return; }
  showLoading(); callSketchUp('scan_all');
}
function scanSelected() {
  if (!window._pluginUnlocked) { switchPage('login'); return; }
  showLoading(); callSketchUp('scan_selected');
}

// ---------------- Workbench state ----------------
window._workbench = null;
window._currentPage = 'login';
window._pluginUnlocked = false;
window._cloudLoggingOut = false;

// 导航/扫描按钮的可用状态 = 已登录 且 不在退出登录流程中
function refreshNavState() {
  var disabled = !window._pluginUnlocked || window._cloudLoggingOut;
  document.querySelectorAll('.sb-btn').forEach(function(b) { b.disabled = disabled; });
  document.querySelectorAll('.sb-nav').forEach(function(b) { b.disabled = disabled; });
}

function setPluginUnlocked(unlocked) {
  window._pluginUnlocked = !!unlocked;
  refreshNavState();
  if (!window._pluginUnlocked && window._currentPage !== 'login') switchPage('login');
}

setPluginUnlocked(false);

window.receiveFaces = function(data) {
  if (!window._workbench) return;
  if (!window._workbench._facesCache) window._workbench._facesCache = {};
  var cacheKey = occurrencePathKey(data.component_path_ids || [data.entity_id]) + ':' + data.su_material;
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
    container.innerHTML = '';
    var errorBox = document.createElement('div');
    errorBox.className = 'mv-error';
    errorBox.textContent = '渲染错误: ' + e.message;
    container.appendChild(errorBox);
    console.error('renderWorkbench error:', e);
  }
}

window.updateComponentSkus = function updateComponentSkus(componentSkus) {
  if (!window._workbench) return;
  window._workbench.component_skus = componentSkus || {};
  if (window._currentPage === 'position') renderPositionView(window._workbench);
};

function buildWorkbenchIndexes(data) {
  var h = data.hierarchy;
  var byId = {};
  var byPath = {};
  if (h) {
    function walk(node, parentPath) {
      var path = Array.isArray(node.component_path_ids)
        ? node.component_path_ids.slice()
        : (node.entity_id === 0 ? parentPath.slice() : parentPath.concat([node.entity_id]));
      node.component_path_ids = path;
      node.occurrence_key = occurrencePathKey(path);
      byId[node.entity_id] = node;
      byPath[node.occurrence_key] = node;
      (node.children || []).forEach(function(child) { walk(child, path); });
    }
    walk(h, []);
  }
  data._byEntityId = byId;
  data._byOccurrenceKey = byPath;

  var maxDepth = 0;
  if (h) {
    function findDepth(node) {
      if (node.depth > maxDepth) maxDepth = node.depth;
      (node.children || []).forEach(findDepth);
    }
    findDepth(h);
  }
  data._maxDepth = maxDepth;

  // 主索引使用完整出现路径；entity_id 索引仅保留旧状态兼容。
  var usagesByEid = {};
  var usagesByPath = {};
  var usageByFaceOccurrence = {};
  (data.geometry_usages || []).forEach(function(u) {
    var eid = u.entity_id;
    var key = u.occurrence_key || occurrencePathKey(u.component_path_ids || [eid]);
    u.occurrence_key = key;
    usagesByEid[eid] = usagesByEid[eid] || [];
    usagesByEid[eid].push(u);
    usagesByPath[key] = usagesByPath[key] || [];
    usagesByPath[key].push(u);
    (u.face_refs || []).forEach(function(ref) {
      usageByFaceOccurrence[ref.face_id + ':' + occurrencePathKey(ref.path_ids || [])] = u;
    });
  });
  data._usagesByEntityId = usagesByEid;
  data._usagesByPath = usagesByPath;
  data._usageByFaceOccurrence = usageByFaceOccurrence;

  // Ruby 侧按组件视图计算出的最终汇总行。页面数值优先使用这份数据，
  // 推送构建器也复用同一份汇总逻辑，确保算量标签变更后两端一致。
  var componentRowsByEid = {};
  var componentRowsByPath = {};
  (data.component_rows || []).forEach(function(row) {
    var key = row.occurrence_key || occurrencePathKey(row.component_path_ids || [row.entity_id]);
    row.occurrence_key = key;
    componentRowsByEid[row.entity_id] = row;
    componentRowsByPath[key] = row;
  });
  data._componentRowsByEntityId = componentRowsByEid;
  data._componentRowsByPath = componentRowsByPath;
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

function occurrencePathKey(pathIds) {
  return (pathIds || []).map(function(id) { return parseInt(id, 10) || 0; }).join('/');
}

function nodeOccurrenceKey(node) {
  return node && (node.occurrence_key || occurrencePathKey(node.component_path_ids || [node.entity_id]));
}

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
  var targetPathIds = null;

  // 按完整路径匹配面：face_id 相同 + path_ids 相同 = 同一实例中的同一个面
  // 使用 face_refs（紧凑索引），避免依赖懒加载的 faces 数组
  var pathIds = activePathIds || [];
  var targetUsage = (data._usageByFaceOccurrence || {})[
    faceId + ':' + occurrencePathKey(pathIds)
  ];
  if (targetUsage) targetPathIds = targetUsage.component_path_ids || pathIds;

  if (targetPathIds === null) return;

  // 展开从根到目标 entity 路径上的所有祖先节点
  expandAncestorsToPath(targetPathIds);

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

function expandAncestorsToPath(pathIds) {
  for (var i = 1; i <= pathIds.length; i++) {
    _mv.expandedNodes[occurrencePathKey(pathIds.slice(0, i))] = true;
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
