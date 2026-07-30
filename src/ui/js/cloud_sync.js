// src/ui/js/cloud_sync.js — 云端登录、项目绑定和算量推送

window._cloudState = null;

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

window.renderLoginState = function renderLoginState(state) {
  state = state || {};
  var auth = state.auth || {};
  var busy = !!state.busy;
  var tenants = auth.available_tenants || [];
  var unlocked = auth.status === 'signed_in';
  if (typeof window.setPluginUnlocked === 'function') window.setPluginUnlocked(unlocked);

  if (unlocked && window._currentPage === 'login') {
    switchPage('position');
    return;
  }
  if (!unlocked && (state.force_login || window._currentPage !== 'login')) {
    switchPage('login');
  }

  var container = document.getElementById('login-content');
  if (!container) return;
  var existingPassword = '';
  var existingPasswordInput = document.getElementById('login-password');
  if (!state.clear_password && existingPasswordInput) existingPassword = existingPasswordInput.value;

  var html = '<div class="login-shell">';
  html += '<section class="panel login-panel">';
  html += '<h2>登录 SU Takeoff</h2>';
  html += '<p class="cloud-hint">请先登录平台账号，登录成功后才能使用扫描、映射、设置和云端同步功能。</p>';

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
  var container = document.getElementById('cloud-content');
  if (!container) return;

  var auth = state.auth || {};
  var binding = state.binding || {};
  var result = state.sync_result || null;
  var busy = !!state.busy;
  var tenants = auth.available_tenants || [];
  var unlocked = auth.status === 'signed_in';
  if (typeof window.setPluginUnlocked === 'function') window.setPluginUnlocked(unlocked);
  if (!unlocked && (state.force_login || window._currentPage !== 'login')) switchPage('login');

  var html = '';
  html += '<div class="toolbar" style="gap:8px;margin-bottom:12px">';
  html += '<span style="font-weight:600;color:#cdd6f4">云端同步</span>';
  html += '<span style="color:#6c7086;font-size:12px">' + esc(state.api_environment || '-') + ' · ' + esc(state.api_base_url || '未配置') + '</span>';
  html += '<span style="flex:1"></span>';
  html += '<button class="primary-btn" onclick="cloudPush()" ' + (busy || !state.has_scan || !auth.can_push ? 'disabled' : '') + '>推送算量</button>';
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

  html += '<div style="display:grid;grid-template-columns:minmax(260px,360px) 1fr;gap:16px;align-items:start">';
  html += renderAccountSummary(auth, busy);
  html += renderProjectPanel(binding, state, result, busy);
  html += '</div>';

  container.innerHTML = html;
};

function renderAccountSummary(auth, busy) {
  var html = '<section class="panel" style="padding:14px">';
  html += '<h3 style="margin:0 0 10px;font-size:15px">账号</h3>';
  html += '<p style="margin:0 0 8px">已登录：<strong>' + esc(auth.account || '-') + '</strong></p>';
  if (!auth.can_push && auth.last_error) {
    html += '<p class="cloud-hint" style="color:#f38ba8">缺少推送权限：' + esc(cloudMessage(auth.last_error.message)) + '</p>';
  }
  html += '<button onclick="cloudLogout()" ' + (busy ? 'disabled' : '') + '>退出登录</button>';
  html += '</section>';
  return html;
}

function renderProjectPanel(binding, state, result, busy) {
  var html = '<section class="panel" style="padding:14px">';
  html += '<h3 style="margin:0 0 10px;font-size:15px">项目绑定</h3>';
  html += '<div style="display:grid;grid-template-columns:140px 1fr;gap:8px;align-items:center;max-width:620px">';
  html += '<label>平台项目编号</label><input id="cloud-project-code" type="text" value="' + escAttr(binding.project_code || '') + '">';
  html += '<label>项目名称</label><input id="cloud-project-name" type="text" value="' + escAttr(binding.project_name || '') + '">';
  html += '<label>模型标识</label><code class="cloud-model-key" title="' + escAttr(binding.model_key || '-') + '">' + esc(binding.model_key || '-') + '</code>';
  html += '<span></span><button onclick="saveProjectBinding()" ' + (busy || !state.auth || state.auth.status !== 'signed_in' ? 'disabled' : '') + '>保存项目绑定</button>';
  html += '</div>';

  if (!state.has_scan) html += '<p class="cloud-hint">推送前需要先扫描模型。</p>';

  if (result) html += renderSyncResult(result);
  html += renderLastSync(binding);
  html += '</section>';
  return html;
}

function renderSyncResult(result) {
  var html = '<div style="margin-top:14px">';
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
    html += '<p class="cloud-hint">' + esc(result.error.code || '-') + ' · ' + esc(cloudMessage(result.error.message || '-')) + '</p>';
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
  callSketchUp('cloud_logout');
};

window.saveProjectBinding = function saveProjectBinding() {
  callSketchUp('save_project_binding', JSON.stringify({
    project_code: (document.getElementById('cloud-project-code') || {}).value || '',
    project_name: (document.getElementById('cloud-project-name') || {}).value || ''
  }));
};

window.cloudPush = function cloudPush() {
  callSketchUp('cloud_push');
};

window.renderLoginState({
  auth: { status: 'signed_out' },
  api_environment: '-',
  api_base_url: '',
  status_message: '正在校验登录状态...',
  force_login: true
});
callSketchUp('get_cloud_state');
