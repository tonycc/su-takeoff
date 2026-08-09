// src/ui/js/cloud_sync.js — 云端登录、项目绑定和算量推送

window._cloudState = null;
window._cloudProjects = [];
window._cloudProjectAccount = '';
window._cloudProjectLoadedFor = '';
window._cloudProjectLoading = false;
window._cloudProjectError = '';
window._cloudProjectRequestId = 0;

function cloudMessage(message) {
  message = String(message || '').trim();
  if (!message) return '';
  if (/invalid credentials|invalid username|invalid password|bad credentials/i.test(message)) return '账号或密码错误，请重新输入';
  if (/unauthorized|HTTP_401|\b401\b/i.test(message)) return '账号或密码错误，请重新输入';
  if (/validation|String should have|unprocessable|HTTP_422|\b422\b/i.test(message)) return '账号或密码格式不正确，请检查后重试';
  if (/Net::OpenTimeout|Net::ReadTimeout|execution expired|timed out|timeout/i.test(message)) return '请求超时，请检查网络连接后重试';
  if (/SocketError|getaddrinfo|nodename nor servname|Name or service not known/i.test(message)) return '无法解析 API 域名，请检查网络或 API 地址';
  if (/ECONNREFUSED|Connection refused/i.test(message)) return '无法连接 API 服务，请检查服务是否可用';
  if (/ECONNRESET|Connection reset|EOFError|end of file/i.test(message)) return '网络连接被中断，请稍后重试';
  if (/certificate|SSL|OpenSSL/i.test(message)) return 'HTTPS 证书校验失败，请检查系统时间或证书配置';
  if (/HTTP_429|\b429\b|rate limit|too many requests/i.test(message)) return '登录请求过于频繁，请稍后重试';
  if (/HTTP_500|HTTP_502|HTTP_503|HTTP_504|\b50[0-4]\b|server error|server down/i.test(message)) return '平台服务异常，请稍后重试';
  if (/[\u4e00-\u9fff]/.test(message)) return message;
  return '登录失败，请稍后重试';
}

function cloudSyncMessage(error) {
  error = error || {};
  var code = String(error.code || '').trim();
  if (code === 'VALIDATION_ERROR') {
    return '算量数据格式不符合接口要求，请检查项目编号、组件名称和计量单位';
  }
  if (code === 'INVALID_PROJECT_PRODUCT') {
    return '组件关联的项目产品无效、已停用或不属于当前项目';
  }
  if (code === 'INVALID_QUANTITY_PAYLOAD') {
    return '算量数据不符合接口要求，请检查项目绑定和算量结果';
  }
  return cloudMessage(error.message || '-');
}

window.renderLoginState = function renderLoginState(state) {
  state = state || {};
  var auth = state.auth || {};
  var busy = !!state.busy;
  var tenants = auth.available_tenants || [];
  var unlocked = auth.status === 'signed_in';
  // 同步「退出登录中」标志（需在 setPluginUnlocked 之前，其内部会刷新按钮可用态）
  window._cloudLoggingOut = !!state.logging_out;
  if (typeof window.setPluginUnlocked === 'function') window.setPluginUnlocked(unlocked);

  if (unlocked && window._currentPage === 'login') {
    switchPage('position');
    return;
  }
  if (!unlocked && (state.force_login || window._currentPage !== 'login')) {
    switchPage('login');
  }

  // 会话校验中：只展示加载面板，不渲染登录表单，
  // 避免用户在等待恢复登录的几秒内误以为需要输入账号密码
  if (state.checking) {
    var checkingContainer = document.getElementById('login-content');
    if (checkingContainer) {
      checkingContainer.innerHTML =
        '<div class="login-shell"><section class="panel login-panel login-checking">' +
        '<div class="loading-spinner"></div>' +
        '<p class="login-checking-text">' + esc(state.status_message || '正在校验登录状态…') + '</p>' +
        '</section></div>';
    }
    return;
  }

  var container = document.getElementById('login-content');
  if (!container) return;
  var existingPassword = '';
  var existingPasswordInput = document.getElementById('login-password');
  if (!state.clear_password && existingPasswordInput) existingPassword = existingPasswordInput.value;

  var html = '<div class="login-shell">';
  html += '<section class="panel login-panel">';
  html += '<h2>登录 SU Takeoff</h2>';
  html += '<p class="cloud-hint">请先登录平台账号，登录成功后才能使用扫描、映射、参数管理和项目绑定与云端推送功能。</p>';

  if (state.error) {
    html += '<div class="login-error">' + esc(cloudMessage(state.error.message)) + '</div>';
  }
  if (state.status_message) {
    html += '<p class="cloud-hint">' + esc(state.status_message) + '</p>';
  }

  var loginAccount = state.login_username || auth.account || '';
  html += '<label>账号</label><input id="login-username" type="text" value="' + escAttr(loginAccount) + '">';
  html += '<label>密码</label><input id="login-password" type="password" value="' + escAttr(existingPassword) + '">';
  if (tenants.length > 0) {
    html += '<label>租户</label><select id="login-tenant">';
    tenants.forEach(function(t) {
      html += '<option value="' + escAttr(t.tenant_id) + '">' + esc(t.tenant_name || t.tenant_id) + '</option>';
    });
    html += '</select>';
  }
  html += '<button class="primary-btn" onclick="cloudLoginFromLoginPage()" ' + (busy ? 'disabled' : '') + '>登录</button>';
  html += '<p class="cloud-hint">当前环境：' + esc(state.api_environment || '-') + ' · ' + esc(state.api_base_url || '未配置') + '</p>';
  html += '</section></div>';
  container.innerHTML = html;

  if (state.clear_password) {
    setTimeout(function() {
      var pwd = document.getElementById('login-password');
      if (pwd) pwd.value = '';
    }, 0);
  }
};

window.renderCloudState = function renderCloudState(state) {
  window._cloudState = state || {};
  if (typeof window.renderSystemManagement === 'function') window.renderSystemManagement(window._cloudState);
  var container = document.getElementById('cloud-content');
  if (!container) return;

  var auth = state.auth || {};
  var binding = state.binding || {};
  var result = state.sync_result || null;
  var busy = !!state.busy;
  var unlocked = auth.status === 'signed_in';
  var projectAccount = String(auth.account || '');
  if (!unlocked) {
    window._cloudProjects = [];
    window._cloudProjectAccount = '';
    window._cloudProjectLoadedFor = '';
    window._cloudProjectLoading = false;
    window._cloudProjectError = '';
  } else if (window._cloudProjectAccount !== projectAccount) {
    window._cloudProjects = [];
    window._cloudProjectAccount = projectAccount;
    window._cloudProjectLoadedFor = '';
    window._cloudProjectLoading = false;
    window._cloudProjectError = '';
  }
  // 同步「退出登录中」标志（需在 setPluginUnlocked 之前，其内部会刷新按钮可用态）
  window._cloudLoggingOut = !!state.logging_out;
  if (typeof window.setPluginUnlocked === 'function') window.setPluginUnlocked(unlocked);
  if (!unlocked && (state.force_login || window._currentPage !== 'login')) switchPage('login');

  var html = '';
  html += '<div class="toolbar" style="gap:8px;margin-bottom:12px">';
  html += '<span style="font-weight:600;color:#cdd6f4">项目绑定</span>';
  html += '<span style="color:#6c7086;font-size:12px">' + esc(state.api_environment || '-') + ' · ' + esc(state.api_base_url || '未配置') + '</span>';
  html += '</div>';

  if (state.error) {
    html += '<div class="mv-error" style="margin-bottom:12px">' + esc(cloudMessage(state.error.message)) + '</div>';
  }
  if (state.status_message) {
    html += '<p class="cloud-hint">' + esc(state.status_message) + '</p>';
  }
  if (state.clear_password) {
    setTimeout(function() {
      var pwd = document.getElementById('cloud-password');
      if (pwd) pwd.value = '';
    }, 0);
  }

  html += renderProjectPanel(binding, state, result, busy);

  container.innerHTML = html;

  // 按组件页面也有推送入口，需要在推送状态变化时同步按钮状态。
  if (window._currentPage === 'position' && window._workbench &&
      typeof window.updatePositionCloudControls === 'function') {
    window.updatePositionCloudControls();
  }

  // 打开项目绑定页时自动加载项目列表；后续由 receiveProjectResults 标记已加载，避免重复请求。
  if (unlocked && window._currentPage === 'cloud' &&
      !window._cloudProjectLoadedFor && !window._cloudProjectLoading) {
    setTimeout(function() {
      if (window._currentPage === 'cloud' && !window._cloudProjectLoadedFor &&
          !window._cloudProjectLoading) loadCloudProjects();
    }, 0);
  }
};

function projectLabel(project) {
  var code = String(project.code || '').trim();
  var name = String(project.name || '').trim();
  if (code && name) return code + ' · ' + name;
  return code || name || String(project.id || '-');
}

function renderProjectPanel(binding, state, result, busy) {
  var projects = (window._cloudProjects || []).slice();
  var selectedId = String(binding.project_id || '').trim();
  var selectedProject = null;
  if (selectedId) {
    selectedProject = projects.find(function(project) {
      return String(project.id || '').trim() === selectedId;
    }) || null;
  }
  if (!selectedProject && binding.project_code) {
    selectedProject = projects.find(function(project) {
      return String(project.code || '').trim() === String(binding.project_code).trim();
    }) || null;
    if (selectedProject) selectedId = String(selectedProject.id || '').trim();
  }

  // 兼容旧模型：旧绑定只有编号/名称，列表加载前仍显示原绑定，但保存时要求重新选择接口项目。
  var legacyProject = null;
  if (binding.project_code || binding.project_name) {
    legacyProject = {
      id: String(binding.project_id || '').trim(),
      code: binding.project_code || '',
      name: binding.project_name || ''
    };
    var exists = projects.some(function(project) {
      return (legacyProject.id && String(project.id || '').trim() === legacyProject.id) ||
        (!legacyProject.id && String(project.code || '').trim() === String(legacyProject.code).trim());
    });
    if (!exists) projects.unshift(legacyProject);
  }

  // 新模型没有旧绑定时，默认选中第一条接口项目，编号和名称随下拉选项立即带出。
  if (!selectedProject && !selectedId && !binding.project_code && !binding.project_name) {
    selectedProject = projects.find(function(project) {
      return String(project.id || '').trim();
    }) || null;
    if (selectedProject) selectedId = String(selectedProject.id || '').trim();
  }

  var selectedCode = selectedProject ? selectedProject.code : (binding.project_code || '');
  var selectedName = selectedProject ? selectedProject.name : (binding.project_name || '');
  var html = '<section class="panel" style="padding:14px">';
  html += '<h3 style="margin:0 0 10px;font-size:15px">项目绑定</h3>';
  html += '<div style="display:grid;grid-template-columns:140px 1fr;gap:8px;align-items:center;max-width:620px">';
  html += '<label>选择平台项目</label><select id="cloud-project-select" onchange="selectCloudProject(this.value)" ' + (busy ? 'disabled' : '') + '>';
  if (projects.length === 0) {
    html += '<option value="">暂无可绑定项目</option>';
  } else {
    projects.forEach(function(project) {
      var projectId = String(project.id || '').trim();
      var selected = projectId && projectId === selectedId ? ' selected' : '';
      html += '<option value="' + escAttr(projectId) + '"' + selected + '>' + esc(projectLabel(project)) + '</option>';
    });
  }
  html += '</select>';
  html += '<label>平台项目编号</label><input id="cloud-project-code" type="text" value="' + escAttr(selectedCode) + '" readonly>';
  html += '<label>项目名称</label><input id="cloud-project-name" type="text" value="' + escAttr(selectedName) + '" readonly>';
  html += '<label>模型标识</label><code class="cloud-model-key" title="' + escAttr(binding.model_key || '-') + '">' + esc(binding.model_key || '-') + '</code>';
  var canSave = !busy && !window._cloudProjectLoading && !!state.auth && state.auth.status === 'signed_in' && !!selectedId;
  html += '<span></span><button onclick="saveProjectBinding()" ' + (canSave ? '' : 'disabled') + '>保存项目绑定</button>';
  html += '</div>';

  if (window._cloudProjectLoading) html += '<p class="cloud-hint">正在加载平台项目…</p>';
  if (window._cloudProjectError) html += '<p class="cloud-hint" style="color:#f38ba8">' + esc(window._cloudProjectError) + '</p>';

  if (!state.has_scan) html += '<p class="cloud-hint">推送前需要先扫描模型。</p>';

  if (result) html += renderSyncResult(result);
  html += renderLastSync(binding);
  html += '</section>';
  return html;
}

function renderSyncResult(result) {
  var html = '<div style="margin-top:14px">';
  if (result.model_version_no || result.update_content) {
    html += '<p class="cloud-hint">版本号：' + esc(result.model_version_no || '-') +
      '<br>更新内容：' + esc(result.update_content || '-') + '</p>';
  }
  if (result.success) {
    html += '<p style="color:#a6e3a1;margin:0 0 6px">推送成功</p>';
    var response = result.response || {};
    html += '<p class="cloud-hint">sheet_id：' + esc(response.sheet_id || '-') + '<br>model_version_id：' + esc(response.model_version_id || '-') + '</p>';
  } else if (result.issues && result.issues.length) {
    html += '<p style="color:#f38ba8;margin:0 0 6px">推送前校验未通过</p>';
    html += '<ul style="margin:0;padding-left:18px">';
    result.issues.forEach(function(issue) {
      html += '<li>' + esc(issue.message || issue.code) + '</li>';
    });
    html += '</ul>';
  } else if (result.error) {
    html += '<p style="color:#f38ba8;margin:0 0 6px">推送失败</p>';
    html += '<p class="cloud-hint">' + esc(result.error.code || '-') + ' · ' + esc(cloudSyncMessage(result.error)) + '</p>';
    if (result.outbox_saved) html += '<p class="cloud-hint">失败 payload 已保存到本地待重试队列。</p>';
  }
  html += '</div>';
  return html;
}

function renderLastSync(binding) {
  if (!binding.last_synced_at) return '';
  return '<p class="cloud-hint">最近同步：' + esc(binding.last_synced_at) +
    '<br>sheet_id：' + esc(binding.last_sheet_id || '-') +
    '<br>model_version_id：' + esc(binding.last_model_version_id || '-') + '</p>';
}

window.cloudLogin = function cloudLogin() {
  callSketchUp('cloud_login', JSON.stringify({
    username: (document.getElementById('login-username') || {}).value || '',
    password: (document.getElementById('login-password') || {}).value || '',
    tenant_id: (document.getElementById('login-tenant') || {}).value || ''
  }));
};

window.cloudLoginFromLoginPage = window.cloudLogin;

window.cloudLogout = function cloudLogout() {
  // 点击立即禁用全部导航/操作按钮，不等待后端状态回传
  window._cloudLoggingOut = true;
  if (typeof refreshNavState === 'function') refreshNavState();
  document.querySelectorAll('#cloud-content button').forEach(function(b) { b.disabled = true; });
  callSketchUp('cloud_logout');
};

window.loadCloudProjects = function loadCloudProjects() {
  window._cloudProjectLoading = true;
  window._cloudProjectError = '';
  window._cloudProjectRequestId += 1;
  var reqId = window._cloudProjectRequestId;
  if (window._cloudState) renderCloudState(window._cloudState);
  callSketchUp('search_projects', JSON.stringify({ keyword: '', req_id: reqId }));
};

window.receiveProjectResults = function receiveProjectResults(payload) {
  payload = payload || {};
  if (String(payload.req_id || '') !== String(window._cloudProjectRequestId || '')) return;
  window._cloudProjectLoading = false;
  window._cloudProjectLoadedFor = window._cloudProjectAccount || 'signed-in';
  if (payload.error) {
    window._cloudProjects = [];
    window._cloudProjectError = cloudMessage(payload.error);
  } else {
    window._cloudProjects = Array.isArray(payload.items) ? payload.items : [];
    window._cloudProjectError = window._cloudProjects.length ? '' : '未找到可绑定的项目';
  }
  if (window._cloudState) renderCloudState(window._cloudState);
};

window.selectCloudProject = function selectCloudProject(projectId) {
  projectId = String(projectId || '').trim();
  var project = (window._cloudProjects || []).find(function(item) {
    return String(item.id || '').trim() === projectId;
  });
  if (!project && window._cloudState && window._cloudState.binding &&
      String(window._cloudState.binding.project_id || '').trim() === projectId) {
    project = {
      id: projectId,
      code: window._cloudState.binding.project_code,
      name: window._cloudState.binding.project_name
    };
  }
  var code = document.getElementById('cloud-project-code');
  var name = document.getElementById('cloud-project-name');
  if (code) code.value = project ? (project.code || '') : '';
  if (name) name.value = project ? (project.name || '') : '';
  var save = document.querySelector('#cloud-content button[onclick="saveProjectBinding()"]');
  if (save) save.disabled = !projectId;
  window._cloudProjectError = projectId ? '' : '请选择一个平台项目';
};

window.saveProjectBinding = function saveProjectBinding() {
  var select = document.getElementById('cloud-project-select');
  var projectId = (select || {}).value || '';
  if (!projectId) {
    window._cloudProjectError = '请选择一个平台项目';
    if (window._cloudState) renderCloudState(window._cloudState);
    return;
  }
  callSketchUp('save_project_binding', JSON.stringify({
    project_id: projectId,
    project_code: (document.getElementById('cloud-project-code') || {}).value || '',
    project_name: (document.getElementById('cloud-project-name') || {}).value || ''
  }));
};

function removeCloudPushModal() {
  var modal = document.getElementById('cloud-push-modal');
  if (modal && modal.parentNode) modal.parentNode.removeChild(modal);
}

function showCloudPushModalError(message) {
  var error = document.getElementById('cloud-push-modal-error');
  if (error) error.textContent = String(message || '推送准备失败，请重试');
  var submit = document.getElementById('cloud-push-confirm');
  if (submit) {
    submit.disabled = false;
    submit.textContent = '确认推送';
  }
}

window.cloudCancelPush = function cloudCancelPush() {
  removeCloudPushModal();
};

window.cloudConfirmPush = function cloudConfirmPush() {
  var versionInput = document.getElementById('cloud-push-model-version-no');
  var contentInput = document.getElementById('cloud-push-update-content');
  var error = document.getElementById('cloud-push-modal-error');
  var version = ((versionInput || {}).value || '').trim();
  var updateContent = ((contentInput || {}).value || '').trim();
  var messages = [];

  if (!version) messages.push('请填写版本号');
  if (version.length > 64) messages.push('版本号不能超过 64 个字符');
  if (!updateContent) messages.push('请填写更新内容');
  if (updateContent.length > 2000) messages.push('更新内容不能超过 2000 个字符');
  if (messages.length) {
    if (error) error.textContent = messages.join('；');
    if (!version && versionInput) versionInput.focus();
    else if (!updateContent && contentInput) contentInput.focus();
    return;
  }

  var visibleComponentPaths;
  try {
    if (typeof window.getVisibleComponentPathsForPush !== 'function') {
      throw new Error('当前页面缺少组件路径收集器，请关闭插件窗口后重新打开');
    }
    visibleComponentPaths = window.getVisibleComponentPathsForPush(window._workbench);
    if (!Array.isArray(visibleComponentPaths) || visibleComponentPaths.length === 0) {
      throw new Error('当前视图没有可推送的组件，请清除搜索条件或重新扫描模型');
    }
  } catch (pathError) {
    console.error('collect visible component paths failed:', pathError);
    showCloudPushModalError(pathError && pathError.message ? pathError.message : pathError);
    return;
  }

  var submit = document.getElementById('cloud-push-confirm');
  if (submit) {
    submit.disabled = true;
    submit.textContent = '正在准备…';
  }

  var previousCloudState = window._cloudState ? Object.assign({}, window._cloudState) : window._cloudState;
  if (window._cloudState) {
    window._cloudState.busy = true;
    window._cloudState.status_message = '正在准备算量数据…';
    window._cloudState.sync_result = null;
    window._cloudState.error = null;
  }
  if (typeof window.updatePositionCloudControls === 'function') {
    window.updatePositionCloudControls();
  }

  try {
    callSketchUp('cloud_push', JSON.stringify({
      model_version_no: version,
      update_content: updateContent,
      visible_component_paths: visibleComponentPaths
    }));
  } catch (bridgeError) {
    console.error('cloud push bridge failed:', bridgeError);
    window._cloudState = previousCloudState;
    if (typeof window.updatePositionCloudControls === 'function') {
      window.updatePositionCloudControls();
    }
    showCloudPushModalError(bridgeError && bridgeError.message ? bridgeError.message : bridgeError);
    return;
  }

  removeCloudPushModal();
};

window.cloudPush = function cloudPush() {
  if (document.getElementById('cloud-push-modal')) return;

  var modal = document.createElement('div');
  modal.id = 'cloud-push-modal';
  modal.className = 'cloud-push-modal-backdrop';
  modal.innerHTML =
    '<section class="cloud-push-modal" role="dialog" aria-modal="true" aria-labelledby="cloud-push-modal-title">' +
      '<div class="cloud-push-modal-header">' +
        '<h3 id="cloud-push-modal-title">确认推送算量</h3>' +
        '<button class="cloud-push-modal-close" type="button" onclick="cloudCancelPush()" aria-label="关闭">×</button>' +
      '</div>' +
      '<p class="cloud-hint">本次推送会创建一个新的模型版本。版本号和更新内容会同步到后端，并参与幂等 key 生成。</p>' +
      '<label for="cloud-push-model-version-no">版本号 <span class="cloud-push-required">*</span></label>' +
      '<input id="cloud-push-model-version-no" type="text" maxlength="64" placeholder="例如：V2026.08.05">' +
      '<label for="cloud-push-update-content">更新内容 <span class="cloud-push-required">*</span></label>' +
      '<textarea id="cloud-push-update-content" maxlength="2000" rows="5" placeholder="请填写本次算量调整内容"></textarea>' +
      '<div id="cloud-push-modal-error" class="cloud-push-modal-error" role="alert"></div>' +
      '<div class="cloud-push-modal-actions">' +
        '<button type="button" onclick="cloudCancelPush()">取消</button>' +
        '<button id="cloud-push-confirm" type="button" class="primary-btn" onclick="cloudConfirmPush()">确认推送</button>' +
      '</div>' +
    '</section>';
  modal.addEventListener('click', function(event) {
    if (event.target === modal) cloudCancelPush();
  });
  document.body.appendChild(modal);

  var versionInput = document.getElementById('cloud-push-model-version-no');
  if (versionInput) versionInput.focus();
};

window.renderLoginState({
  auth: { status: 'signed_out' },
  api_environment: '-',
  api_base_url: '',
  status_message: '正在校验登录状态…',
  checking: true,
  force_login: true
});
callSketchUp('get_cloud_state');
