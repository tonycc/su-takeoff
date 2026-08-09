// src/ui/js/system_management.js — 系统管理页：登录信息和退出登录

function systemIdentityValue(auth, key) {
  var identity = auth.identity || {};
  var subject = auth.subject || {};
  var nestedSubject = identity.subject || {};
  if (identity[key] !== undefined && identity[key] !== null) return identity[key];
  if (nestedSubject[key] !== undefined && nestedSubject[key] !== null) return nestedSubject[key];
  if (subject[key] !== undefined && subject[key] !== null) return subject[key];
  return '';
}

function systemErrorMessage(message) {
  return typeof cloudMessage === 'function' ? cloudMessage(message) : String(message || '');
}

window.renderSystemManagement = function renderSystemManagement(state) {
  state = state || {};
  var container = document.getElementById('system-content');
  if (!container) return;

  var auth = state.auth || {};
  var busy = !!state.busy;
  var signedIn = auth.status === 'signed_in';
  var tenantName = systemIdentityValue(auth, 'tenant_name') || systemIdentityValue(auth, 'tenantName');
  var tenantId = systemIdentityValue(auth, 'tenant_id') || systemIdentityValue(auth, 'tenantId');
  var tenant = tenantName && tenantId && tenantName !== tenantId ? tenantName + '（' + tenantId + '）' : (tenantName || tenantId || '-');
  var status = signedIn ? '已登录' : (auth.status || '未登录');
  var permission = auth.can_push ? '可推送算量' : '无 quantity:ingest 权限';

  var html = '<div class="toolbar" style="gap:8px;margin-bottom:12px">';
  html += '<span style="font-weight:600;color:#cdd6f4">系统管理</span>';
  html += '<span style="color:#6c7086;font-size:12px">' + esc(state.api_environment || '-') + ' · ' + esc(state.api_base_url || '未配置') + '</span>';
  html += '</div>';

  if (state.error) {
    html += '<div class="mv-error" style="margin-bottom:12px">' + esc(systemErrorMessage(state.error.message)) + '</div>';
  }
  if (state.status_message) {
    html += '<p class="cloud-hint">' + esc(state.status_message) + '</p>';
  }

  html += '<section class="panel" style="padding:14px;max-width:620px">';
  html += '<h3 style="margin:0 0 12px;font-size:15px">登录信息</h3>';
  html += '<div style="display:grid;grid-template-columns:140px 1fr;gap:10px;align-items:center">';
  html += '<label>登录状态</label><span>' + esc(status) + '</span>';
  html += '<label>账号</label><span>' + esc(auth.account || '-') + '</span>';
  html += '<label>租户</label><span>' + esc(tenant) + '</span>';
  html += '<label>算量推送权限</label><span style="color:' + (auth.can_push ? '#a6e3a1' : '#f38ba8') + '">' + esc(permission) + '</span>';
  html += '</div>';
  if (!auth.can_push && auth.last_error) {
    html += '<p class="cloud-hint" style="color:#f38ba8">' + esc(systemErrorMessage(auth.last_error.message)) + '</p>';
  }
  html += '<div style="margin-top:14px"><button onclick="cloudLogout()" ' + (busy ? 'disabled' : '') + '>退出登录</button></div>';
  html += '</section>';
  html += '<section class="panel" style="padding:14px;max-width:620px;margin-top:12px">';
  html += '<h3 style="margin:0 0 12px;font-size:15px">软件信息</h3>';
  html += '<div style="display:grid;grid-template-columns:140px 1fr;gap:10px;align-items:center">';
  html += '<label>软件版本</label><span>' + esc(state.plugin_version || '-') + '</span>';
  html += '</div>';
  html += '</section>';
  container.innerHTML = html;
};
