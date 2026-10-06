/**
 * KemoFi Admin Panel — OpenWrt
 * Pure ES5. No frameworks.
 */
(function () {
  var API = '/api/admin';
  var sqmAvailable = true;
  var OTA_UPDATE_TIMEOUT_MS = 180000;
  // Detect remote access context (loaded in iframe via vendor platform)
  // Rewrite API base to route XHR through the remote proxy tunnel
  if (window.location.pathname.indexOf('/api/remote/') === 0) {
    var _m = window.location.pathname.match(/^\/api\/remote\/[^\/]+/);
    if (_m) API = _m[0] + '/admin';
  }
  // Auth uses cookie (kemofi_admin) set by server on login. No token header needed.

  // ── Helpers ─────────────────────────────────────────────────────────────
  function xhr(method, url, body, cb, timeoutMs) {
    var req = new XMLHttpRequest();
    req.open(method, url, true);
    req.withCredentials = true;
    req.setRequestHeader('Content-Type', 'application/json');
    req.timeout = timeoutMs || 10000;
    req.onload = function () {
      if (req.status === 401) { cb({status: 401}, null); return; }
      try { cb(null, JSON.parse(req.responseText)); } catch (e) { cb(e, null); }
    };
    req.onerror = req.ontimeout = function () { cb(new Error('network'), null); };
    req.send(body ? JSON.stringify(body) : null);
  }

  // ── Button loading state helper ─────────────────────────────────────────
  function setLoading(btn, loading, label) {
    if (!btn) return;
    if (loading) {
      btn._origText = btn.innerHTML;
      btn._origAriaBusy = btn.getAttribute('aria-busy');
      btn.disabled = true;
      btn.setAttribute('aria-busy', 'true');
      btn.innerHTML = '<span style="display:inline-flex;align-items:center;gap:6px"><svg style="animation:firmware-spin .7s linear infinite;width:14px;height:14px" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" aria-hidden="true"><path d="M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83"/></svg>' + (label || 'Saving...') + '</span>';
    } else {
      btn.disabled = false;
      btn.innerHTML = btn._origText || btn.innerHTML;
      if (btn._origAriaBusy === null || typeof btn._origAriaBusy === 'undefined') btn.removeAttribute('aria-busy');
      else btn.setAttribute('aria-busy', btn._origAriaBusy);
    }
  }

  function setFirmwareProgress(prefix, percent, label, active) {
    var progress = $(prefix + '-progress');
    var bar = $(prefix + '-progress-bar');
    var bounded = Math.max(0, Math.min(100, Number(percent) || 0));
    if (progress) {
      progress.style.display = '';
      if (progress.classList) {
        if (active) progress.classList.add('is-active');
        else progress.classList.remove('is-active');
      }
      var track = progress.querySelector('[role="progressbar"]');
      if (track) {
        track.setAttribute('aria-valuenow', String(bounded));
        if (active) track.setAttribute('aria-busy', 'true');
        else track.removeAttribute('aria-busy');
      }
    }
    if (bar) bar.style.width = bounded + '%';
    setText(prefix + '-progress-text', label || '');
  }

  function hideFirmwareProgress(prefix) {
    var progress = $(prefix + '-progress');
    if (!progress) return;
    progress.style.display = 'none';
    if (progress.classList) progress.classList.remove('is-active');
    var track = progress.querySelector('[role="progressbar"]');
    if (track) track.removeAttribute('aria-busy');
  }

  function $(id) { return document.getElementById(id); }
  function setText(id, value) { var el = $(id); if (el) el.textContent = value; }
  function show(el) { if (el) el.style.display = ''; }
  function hide(el) { if (el) el.style.display = 'none'; }

  function setSqmVisibility(available) {
    sqmAvailable = available !== false;
    var sqmCard = $('sqm-settings-card');
    var gamingNav = $('gaming-priority-nav');
    var gamingTab = $('tab-gaming-priority');
    if (sqmCard) sqmCard.style.display = sqmAvailable ? '' : 'none';
    if (gamingNav) gamingNav.style.display = sqmAvailable ? '' : 'none';
    if (gamingTab) gamingTab.style.display = sqmAvailable ? '' : 'none';
    if (!sqmAvailable && activeAdminTab === 'gaming-priority') switchTab('settings');
  }

  // ── Toast Notification ──────────────────────────────────────────────────
  var _toastTimer = null;
  function showToast(msg, type) {
    var el = $('admin-toast');
    if (!el) {
      el = document.createElement('div');
      el.id = 'admin-toast';
      el.style.cssText = 'position:fixed;bottom:24px;left:50%;transform:translateX(-50%);'
        + 'padding:12px 24px;border-radius:8px;font-size:14px;font-weight:600;'
        + 'z-index:9999;pointer-events:none;transition:opacity .3s;max-width:90vw;text-align:center;';
      document.body.appendChild(el);
    }
    el.textContent = msg;
    el.style.background = (type === 'error') ? '#7f1d1d' : '#064e3b';
    el.style.color = (type === 'error') ? '#fca5a5' : '#6ee7b7';
    el.style.border = '1px solid ' + ((type === 'error') ? '#b91c1c' : '#059669');
    el.style.opacity = '1';
    el.style.display = 'block';
    if (_toastTimer) clearTimeout(_toastTimer);
    _toastTimer = setTimeout(function () {
      el.style.opacity = '0';
      setTimeout(function () { el.style.display = 'none'; }, 300);
    }, 3000);
  }

  function formatTime(seconds) {
    if (!seconds || seconds <= 0) return '--';
    var d = Math.floor(seconds / 86400);
    var h = Math.floor((seconds % 86400) / 3600);
    var m = Math.floor((seconds % 3600) / 60);
    if (d > 0) return d + 'd ' + h + 'h';
    if (h > 0) return h + 'h ' + m + 'm';
    return m + 'm';
  }

  // Router releases have used a few names for the same system fields. Keep
  // the dashboard resilient when an older backend omits a newer alias.
  function firstDefined() {
    for (var i = 0; i < arguments.length; i++) {
      var value = arguments[i];
      if (value !== undefined && value !== null && value !== '') return value;
    }
    return '';
  }

  function renderSystemInfo(data) {
    data = data || {};
    var nested = data.system || data.system_info || data.info || {};
    var fallback = lastDashboardSystem || {};
    var uptime = firstDefined(
      data.uptime_seconds, data.uptime, nested.uptime_seconds, nested.uptime,
      fallback.uptime_seconds, fallback.uptime
    );
    var ramTotal = firstDefined(
      data.ram_total_mb, data.memory_total_mb, data.ram_total,
      nested.ram_total_mb, nested.memory_total_mb, nested.ram_total,
      fallback.ram_total_mb, fallback.memory_total_mb
    );
    var ramUsed = firstDefined(
      data.ram_used_mb, data.memory_used_mb, data.ram_used,
      nested.ram_used_mb, nested.memory_used_mb, nested.ram_used,
      fallback.ram_used_mb, fallback.memory_used_mb
    );
    var hostname = firstDefined(data.hostname, nested.hostname);
    var model = firstDefined(data.model, nested.model, data.device_model);
    var lanIp = firstDefined(
      data.lan_ip, data.lan_address, data.local_ip, nested.lan_ip,
      nested.lan_address, nested.local_ip
    );
    var wanIp = firstDefined(
      data.wan_ip, data.wan_address, data.internet_ip, nested.wan_ip,
      nested.wan_address, nested.internet_ip
    );

    if (hostname !== '') setText('sys-hostname', hostname);
    if (model !== '') setText('sys-model', model);
    if (uptime !== '') setText('sys-uptime', formatTime(uptime));
    if (ramTotal !== '') {
      setText('sys-ram', (ramUsed === '' ? '--' : ramUsed) + 'MB / ' + ramTotal + 'MB');
    }
    if (lanIp !== '') setText('sys-lan-ip', lanIp);
    if (wanIp !== '') setText('sys-wan-ip', wanIp);
  }

  function formatMinutes(m) {
    if (!m) return '0m';
    m = Math.round(m);
    if (m >= 60) return Math.floor(m / 60) + 'h ' + (m % 60) + 'm';
    return m + 'm';
  }

  function formatBytes(b) {
    if (!b) return '--';
    if (b > 1048576) return (b / 1048576).toFixed(1) + ' MB';
    return (b / 1024).toFixed(0) + ' KB';
  }

  function shortMac(mac) { return mac || '--'; }

  function escapeHtml(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function formatRemaining(seconds) {
    seconds = Math.max(0, Math.floor(Number(seconds) || 0));
    var days = Math.floor(seconds / 86400);
    var hours = Math.floor((seconds % 86400) / 3600);
    var minutes = Math.floor((seconds % 3600) / 60);
    var secs = seconds % 60;
    function pad(value) { return value < 10 ? '0' + value : String(value); }
    var clock = pad(hours) + ':' + pad(minutes) + ':' + pad(secs);
    return days > 0 ? days + 'd ' + clock : clock;
  }

  function timeAgo(ts) {
    if (!ts) return '--';
    var diff = Math.floor(Date.now() / 1000) - ts;
    if (diff < 60) return 'just now';
    if (diff < 3600) return Math.floor(diff / 60) + 'm ago';
    if (diff < 86400) return Math.floor(diff / 3600) + 'h ago';
    return Math.floor(diff / 86400) + 'd ago';
  }

  function formatDateTime(ts) {
    if (!ts) return '--';
    var d = new Date(Number(ts) * 1000);
    if (isNaN(d.getTime())) return '--';
    return d.toLocaleString();
  }

  function epochSeconds(value) {
    if (typeof value === 'number') return Math.floor(value);
    if (!value) return 0;
    var text = String(value).trim();
    if (/^\d+$/.test(text)) return Number(text);
    var parsed = Date.parse(text);
    return isNaN(parsed) ? 0 : Math.floor(parsed / 1000);
  }

  // ── Tab Navigation ──────────────────────────────────────────────────────
  // Support both .nav-item (dashboard.html sidebar) and .tab (legacy index.html)
  var tabs = document.querySelectorAll('.nav-item[data-tab], .tab[data-tab]');
  var contents = document.querySelectorAll('.tab-content');
  var activeAdminTab = '';
  var dashboardPollTimer = null;
  var dashboardRequestActive = false;
  var lastDashboardSystem = {};
  var DASHBOARD_POLL_MS = 10000;
  var ADMIN_TAB_META = {
    dashboard: { kicker: 'Overview', title: 'Dashboard' },
    sessions: { kicker: 'Management', title: 'Sessions' },
    'gaming-priority': { kicker: 'Traffic Control', title: 'Gaming Priority' },
    vouchers: { kicker: 'Management', title: 'Vouchers' },
    settings: { kicker: 'Configuration', title: 'Settings' },
    wan: { kicker: 'Connectivity', title: 'Internet / WAN' },
    license: { kicker: 'Configuration', title: 'License' },
    rates: { kicker: 'Configuration', title: 'WiFi Rates' },
    branding: { kicker: 'Configuration', title: 'Branding' },
    vendos: { kicker: 'Hardware', title: 'Coinslot' },
    remote: { kicker: 'Connectivity', title: 'Remote Access' },
    system: { kicker: 'System', title: 'System' }
  };

  function formatRemoteBytes(value) {
    value = Number(value || 0);
    if (value <= 0) return '0 KB';
    if (value >= 1048576) return (value / 1048576).toFixed(1) + ' MB';
    return (value / 1024).toFixed(1) + ' KB';
  }

  function renderRemoteAccess(data) {
    var nav = $('remote-nav');
    if (!nav) return;
    if (!data || data.status === 'disabled') {
      nav.hidden = true;
      if (activeAdminTab === 'remote') switchTab('dashboard');
      return;
    }
    nav.hidden = false;
    var lite = String(data.transport || '').toLowerCase().indexOf('https') >= 0 ||
      typeof data.connection_status !== 'undefined';
    var connected = lite ? data.connection_status === 'Connected' : data.vpn_status === 'Connected';
    var status = $('remote-vpn-status');
    if (status) {
      status.textContent = lite ? (data.agent_status || 'Unavailable') : (data.vpn_status || 'Unavailable');
      status.style.color = connected ? 'var(--green)' : 'var(--red)';
    }
    if ($('remote-label-status')) $('remote-label-status').textContent = lite ? 'HTTPS Agent' : 'Connection';
    if ($('remote-label-service')) $('remote-label-service').textContent = lite ? 'Enrollment' : 'Service';
    if ($('remote-label-interface')) $('remote-label-interface').textContent = lite ? 'Transport' : 'Interface';
    if ($('remote-label-handshake')) $('remote-label-handshake').textContent = lite ? 'Command Polling' : 'Last Handshake';
    if ($('remote-label-transfer')) $('remote-label-transfer').textContent = lite ? 'Outbound Relay' : 'Data Transfer';
    if ($('remote-label-ready')) $('remote-label-ready').textContent = lite ? 'Endpoint' : 'Ready Since';
    if ($('remote-vpn-edition')) $('remote-vpn-edition').textContent = data.edition || '--';
    if ($('remote-vpn-service')) $('remote-vpn-service').textContent = data.enrolled ? 'Enrolled' : 'Not enrolled';
    if ($('remote-vpn-interface')) $('remote-vpn-interface').textContent = lite ? 'Signed HTTPS' : (data.interface_state || '--');
    if ($('remote-vpn-handshake')) {
      $('remote-vpn-handshake').textContent = lite ? (data.polling_active ? 'Active' : 'Inactive') :
        (data.handshake_age == null ? 'No handshake yet' : data.handshake_age + 's ago');
    }
    if ($('remote-vpn-transfer')) {
      $('remote-vpn-transfer').textContent = lite ? (data.relay_status || 'Not provisioned') :
        (formatRemoteBytes(data.rx_bytes) + ' / ' + formatRemoteBytes(data.tx_bytes));
    }
    if ($('remote-vpn-license')) $('remote-vpn-license').textContent = data.license_status || '--';
    if ($('remote-vpn-ready')) $('remote-vpn-ready').textContent = lite ?
      (data.endpoint || 'https://kemofi.com') : (data.provisioned_at || '--');
  }

  function loadRemoteAccess() {
    if (!$('remote-nav')) return;
    xhr('GET', API + '/remote/status', null, function (err, data) {
      if (err || !data) return;
      renderRemoteAccess(data);
    });
  }

  function renderRemoteDiagnostics(data) {
    var output = $('remote-diagnostics');
    if (!output || !data) return;
    if (data.status === 'disabled') {
      output.textContent = data.message || 'Remote Access is not enabled on this firmware.';
      return;
    }
    var lite = String(data.transport || '').toLowerCase().indexOf('https') >= 0 ||
      typeof data.agent_running !== 'undefined';
    var rows = lite ? [
      ['HTTPS remote agent is running', data.agent_running],
      ['Agent is enrolled', data.enrolled],
      ['VPS hostname is reachable', data.vps_reachable],
      ['TLS certificate bundle is installed', data.tls_ca_bundle],
      ['Command polling is active', data.command_polling],
      ['Outbound reverse-SSH relay is connected', data.relay_connected],
    ] : [
      ['Remote service is ready', data.interface_up],
      ['Remote service is reachable', data.endpoint_resolves],
      ['Secure management route is ready', data.management_route],
      ['Customer traffic remains isolated', data.guest_isolation],
    ];
    output.innerHTML = '';
    for (var i = 0; i < rows.length; i++) {
      var row = document.createElement('div');
      row.textContent = (rows[i][1] ? '✓ ' : '• ') + rows[i][0];
      row.style.color = rows[i][1] ? 'var(--green)' : 'var(--amber)';
      output.appendChild(row);
    }
    var last = document.createElement('div');
    last.style.marginTop = '8px';
    last.textContent = lite ? 'Lite Remote uses outbound signed HTTPS. Customer Internet remains on WAN.' :
      ('Last connection: ' + (data.handshake_age == null ? 'none' : data.handshake_age + ' seconds ago') + '. Customer Internet remains on WAN.');
    output.appendChild(last);
  }

  function switchTab(tabName) {
    if (tabName === 'gaming-priority' && sqmAvailable === false) tabName = 'settings';
    activeAdminTab = tabName;
    sessionStorage.setItem('admin_tab', tabName);
    // Deactivate all nav items
    for (var j = 0; j < tabs.length; j++) {
      tabs[j].classList.remove('active');
    }
    // Hide all tab contents
    for (var k = 0; k < contents.length; k++) {
      contents[k].classList.remove('active');
    }
    // Activate the clicked nav item
    for (var m = 0; m < tabs.length; m++) {
      if (tabs[m].getAttribute('data-tab') === tabName) {
        tabs[m].classList.add('active');
      }
    }
    // Show the target tab content
    var target = $('tab-' + tabName);
    if (target) target.classList.add('active');
    var tabMeta = ADMIN_TAB_META[tabName] || ADMIN_TAB_META.dashboard;
    if ($('page-kicker')) $('page-kicker').textContent = tabMeta.kicker;
    if ($('page-title')) $('page-title').textContent = tabMeta.title;
    // Refresh data
    if (tabName === 'dashboard') {
      startDashboardPolling();
      // Dashboard data omits static device metadata; load it once so the
      // moved System Info card is populated without adding work to polling.
      loadSystem();
      loadRemoteAccess();
    } else {
      stopDashboardPolling();
    }
    if (tabName === 'sessions') {
      startSessionsPolling();
      loadSessions(true);
    } else {
      stopSessionsPolling();
    }
    if (tabName === 'vouchers') loadVouchers();
    if (tabName === 'settings') loadSettings();
    if (tabName === 'wan') loadWanConfig();
    if (tabName === 'license') loadLicense();
    if (tabName === 'rates') loadRates();
    if (tabName === 'gaming-priority') loadGamingPriority();
    if (tabName === 'system') loadSystem();
    if (tabName === 'vendos') loadVendos();
    if (tabName === 'remote') loadRemoteAccess();
  }

  for (var i = 0; i < tabs.length; i++) {
    (function (t) {
      t.addEventListener('click', function () {
        var tabName = t.getAttribute('data-tab');
        if (tabName) switchTab(tabName);
      });
    })(tabs[i]);
  }

  // ── Login ───────────────────────────────────────────────────────────────
  var loginForm = $('login-form');
  var loginError = $('login-error');
  var loginScreen = $('login-screen');
  var app = $('app');

  function adminPortalAssetUrl(file, version) {
    var asset = String(file || '').replace(/^\s+|\s+$/g, '');
    if (!/^logo\.[A-Za-z0-9]+$/.test(asset)) return '';
    return API + '/portal-asset?type=logo&v=' + encodeURIComponent(String(version || asset));
  }

  function applyLoginBranding(value, branding) {
    var name = String(value || '').replace(/^\s+|\s+$/g, '') || 'KemoFi LiteV2';
    var title = $("login-title");
    if (title) title.textContent = name + ' Admin';
    document.title = name + ' Admin';
    var logoUrl = adminPortalAssetUrl(branding && branding.portal_logo_file, branding && branding.portal_logo_version);
    if (logoUrl) {
      var favicon = $('admin-favicon');
      var appleIcon = $('admin-apple-touch-icon');
      var loginLogo = $('admin-login-logo');
      var sidebarLogo = $('admin-sidebar-logo');
      var mobileLogo = $('admin-mobile-logo');
      if (favicon) favicon.href = logoUrl;
      if (appleIcon) appleIcon.href = logoUrl;
      if (loginLogo) loginLogo.src = logoUrl;
      if (sidebarLogo) sidebarLogo.src = logoUrl;
      if (mobileLogo) mobileLogo.src = logoUrl;
    }
  }

  function loadLoginBranding() {
    xhr('GET', '/api/portal/branding', null, function (err, data) {
      if (!err && data) applyAdminBranding(data.business_name, data);
    });
  }

  loadLoginBranding();

  loginForm.addEventListener('submit', function (e) {
    e.preventDefault();
    var pw = $('login-password').value;
    xhr('POST', API + '/login', {password: pw}, function (err, data) {
      if (err || !data || data.error) {
        show(loginError);
        loginError.textContent = (data && data.error) || 'Login failed';
        return;
      }
      // Auth cookie is set by server automatically on login response
      hide(loginScreen);
      show(app);
      switchTab('dashboard');
      loadSettings();
    });
  });

  // Password show/hide toggle
  var pwToggleBtn = $('pw-toggle-btn');
  if (pwToggleBtn) {
    pwToggleBtn.addEventListener('click', function () {
      var inp = $('login-password');
      var showing = inp.type === 'text';
      inp.type = showing ? 'password' : 'text';
      var icon = $('pw-eye-icon');
      if (icon) icon.style.opacity = showing ? '1' : '0.4';
    });
  }

  // Logout
  $('logout-btn').addEventListener('click', function () {
    activeAdminTab = '';
    stopDashboardPolling();
    stopSessionsPolling();
    xhr('POST', API + '/logout', {}, function () {});
    show(loginScreen);
    hide(app);
    $('login-password').value = '';
  });

  // ── Auto-login: check existing session cookie on page load ────────────────
  // The server sets a kemofi_admin cookie on login. On refresh, the browser
  // sends it automatically. We just need to verify it's still valid.
  (function checkSession() {
    var req = new XMLHttpRequest();
    req.open('GET', API + '/system/ping', true);
    req.withCredentials = true;
    req.timeout = 5000;
    req.onload = function () {
      if (req.status === 200) {
        // Cookie is valid — skip login, go straight to dashboard
        hide(loginScreen);
        show(app);
        // Restore last active tab from sessionStorage
        var lastTab = sessionStorage.getItem('admin_tab') || 'dashboard';
        switchTab(lastTab);
        loadSettings();
      }
      // If 401 or error — stay on login screen (default)
    };
    req.onerror = req.ontimeout = function () {}; // stay on login
    req.send();
  })();

  // ── Forgot Password ────────────────────────────────────────────────────
  var forgotModal = $('forgot-modal');
  $('forgot-password-btn').addEventListener('click', function () { forgotModal.className = 'modal open'; });
  $('close-forgot').addEventListener('click', function () { forgotModal.className = 'modal'; });
  $('forgot-submit').addEventListener('click', function () {
    var lic = $('forgot-license-input').value.trim();
    var newPw = $('forgot-new-password').value;
    if (!lic || !newPw) { show($('forgot-error')); $('forgot-error').textContent = 'Both fields required'; return; }
    if (newPw.length < 4) { show($('forgot-error')); $('forgot-error').textContent = 'Password must have at least 4 characters'; return; }
    xhr('POST', API + '/forgot-password', {license_key: lic, new_password: newPw}, function (err, data) {
      if (err || !data || data.error) { show($('forgot-error')); $('forgot-error').textContent = (data && data.message) || (data && data.error) || 'Failed'; return; }
      forgotModal.className = 'modal';
      $('forgot-license-input').value = '';
      $('forgot-new-password').value = '';
      showToast('Password reset! Login with new password.');
    });
  });

  // ── Dashboard ───────────────────────────────────────────────────────────
  function stopDashboardPolling() {
    if (dashboardPollTimer) clearInterval(dashboardPollTimer);
    dashboardPollTimer = null;
  }

  function startDashboardPolling() {
    stopDashboardPolling();
    if (document.hidden || activeAdminTab !== 'dashboard') return;
    loadDashboard(false);
    dashboardPollTimer = setInterval(function () { loadDashboard(true); }, DASHBOARD_POLL_MS);
  }

  function loadDashboard(healthOnly) {
    if (dashboardRequestActive) return;
    dashboardRequestActive = true;
    xhr('GET', API + '/dashboard', null, function (err, data) {
      dashboardRequestActive = false;
      if (err || !data) return;
      var sys = data.system || data.system_info || {};
      lastDashboardSystem = sys;
      renderSystemInfo(data);
      if (!healthOnly) {
        $('stat-active').textContent = data.active_sessions || 0;
        $('stat-today-earnings').textContent = '\u20B1' + (data.today_earnings || 0);
        $('stat-total-earnings').textContent = '\u20B1' + (data.total_earnings || 0);
        $('stat-transactions').textContent = data.today_transactions || 0;
      }
      // Health
      var healthUptime = firstDefined(sys.uptime_seconds, sys.uptime);
      setText('health-uptime', healthUptime === '' ? '--' : formatTime(healthUptime));
      var healthRamTotal = firstDefined(sys.ram_total_mb, sys.memory_total_mb, sys.ram_total);
      var healthRamUsed = firstDefined(sys.ram_used_mb, sys.memory_used_mb, sys.ram_used);
      var healthRamAvailable = firstDefined(sys.ram_available_mb, sys.memory_available_mb, sys.ram_available);
      if (healthRamTotal !== '' && Number(healthRamTotal) > 0) {
        var ramPct = Math.round((Number(healthRamUsed || 0) / Number(healthRamTotal)) * 100);
        setText('health-ram', ramPct + '%');
        setText('health-ram-detail', (healthRamAvailable === '' ? '--' : healthRamAvailable) + ' MB available');
        var ramHealth = $('health-ram');
        if (ramHealth) ramHealth.classList.toggle('is-warning', Number(healthRamAvailable || 0) < 8);
      }
      if (sys.disk_total_mb) setText('health-flash', sys.disk_used_mb + '/' + sys.disk_total_mb + 'MB');
      var cpuLoad = firstDefined(sys.load_avg, sys.cpu_load, sys.cpu, data.load_avg, data.cpu_load);
      setText('health-cpu', cpuLoad === '' ? '--' : cpuLoad);
      var wifiClients = firstDefined(
        sys.wifi_clients, sys.wifi_client_count, data.wifi_clients,
        data.wifi_client_count, sys.dhcp_clients, data.dhcp_clients
      );
      setText('health-wifi', wifiClients === '' ? '--' : wifiClients);
      var wanState = firstDefined(data.wan_online, data.wan_status, sys.wan_online, sys.wan_status);
      if (wanState === '') {
        setText('health-wan', '--');
      } else {
        var wanOnline = wanState === true || wanState === 1 || wanState === '1' || wanState === 'online' || wanState === 'Online';
        setText('health-wan', wanOnline ? 'Online' : 'Offline');
        var wanHealth = $('health-wan');
        if (wanHealth) wanHealth.style.color = wanOnline ? '#7ee787' : '#f85149';
      }
      // Recent transactions
      if (!healthOnly) {
        var tbody = $('recent-tx-body');
        tbody.innerHTML = '';
        if (data.recent_transactions) {
          for (var i = 0; i < data.recent_transactions.length && i < 10; i++) {
            var tx = data.recent_transactions[i];
            var tr = document.createElement('tr');
            var source = tx.source || 'coin';
            var coins = source === 'coin' ? (Number(tx.coin_count) || 1) : '--';
            tr.innerHTML = '<td>' + timeAgo(tx.created_at) + '</td><td>' + shortMac(tx.mac) + '</td><td>\u20B1' + (tx.amount || 0) + '</td><td>' + formatRateMinutes(tx.minutes || 0) + '</td><td>' + coins + '</td><td>' + source + '</td>';
            tbody.appendChild(tr);
          }
        }
      }
    });
  }

  var resetEarningsBtn = $('reset-earnings-btn');
  if (resetEarningsBtn) resetEarningsBtn.addEventListener('click', function () {
    var confirmation = prompt(
      'Reset the displayed earnings and sales period? Historical records will be kept.\n\nType RESET to continue.'
    );
    if (confirmation === null) return;
    if (confirmation !== 'RESET') {
      showToast('Reset cancelled. Type RESET exactly.', 'error');
      return;
    }

    setLoading(resetEarningsBtn, true);
    xhr('POST', API + '/earnings/reset', {confirmation: confirmation}, function (err, data) {
      setLoading(resetEarningsBtn, false);
      if (err || !data || data.error) {
        showToast((data && data.message) || 'Earnings reset failed.', 'error');
        return;
      }
      showToast('Earnings reset. Historical records were kept.');
      loadDashboard(false);
    });
  });

  // ── Coinslot ─────────────────────────────────────────────────────────
  var coinNodesById = {};
  function loadVendos() {
    xhr('GET', API + '/coin-nodes', null, function (err, data) {
      if (err || !data) return;
      var nodes = data.nodes || [];
      coinNodesById = {};
      for (var nodeIndex = 0; nodeIndex < nodes.length; nodeIndex++) {
        if (nodes[nodeIndex].node_id) coinNodesById[nodes[nodeIndex].node_id] = nodes[nodeIndex];
      }
      $('vendo-count').textContent = nodes.length;
      var tbody = $('vendos-body');
      tbody.innerHTML = '';
      if (nodes.length === 0) {
        $('vendo-empty').style.display = '';
        if ($('vendos-table-wrap')) $('vendos-table-wrap').style.display = 'none';
        return;
      }
      $('vendo-empty').style.display = 'none';
      if ($('vendos-table-wrap')) $('vendos-table-wrap').style.display = '';
      for (var i = 0; i < nodes.length; i++) {
        var n = nodes[i];
        var online = n.online;
        var statusHtml = online
          ? '<span style="color:#7ee787;font-weight:600">&#9679; Online</span>'
          : '<span style="color:#8b949e">&#9679; Offline</span>';
        var coinPin = n.coin_dpin !== undefined ? 'D' + n.coin_dpin : '--';
        var relayPin = n.relay_dpin !== undefined ? 'D' + n.relay_dpin : '--';
        var pinsLabel = coinPin + ' / ' + relayPin;
        var pulseLabel = n.amount_php_per_pulse !== undefined ? '&#8369;' + escapeHtml(String(n.amount_php_per_pulse)) : '--';
        var modeLabel = n.conn_mode === 'wired'
          ? '<span style="display:inline-flex;align-items:center;gap:5px"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" style="width:15px;height:15px" aria-hidden="true"><path d="M9.5 14.5l5-5"/><path d="M7.4 17.6l-1.1 1.1a3.2 3.2 0 01-4.5-4.5l3.1-3.1a3.2 3.2 0 014.5 0"/><path d="M16.6 6.4l1.1-1.1a3.2 3.2 0 014.5 4.5l-3.1 3.1a3.2 3.2 0 01-4.5 0"/></svg> Wired</span>'
          : '<span style="display:inline-flex;align-items:center;gap:5px"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" style="width:15px;height:15px" aria-hidden="true"><path d="M2.5 8.8a15 15 0 0119 0"/><path d="M5.8 12.2a9.8 9.8 0 0112.4 0"/><path d="M9.2 15.6a5 5 0 015.6 0"/><path d="M12 19.2h.01"/></svg> WiFi</span>';
        var firmwareVersion = String(n.fw_version || '').replace(/^v/i, '');
        var firmwareLabel = firmwareVersion ? 'v' + escapeHtml(firmwareVersion) : '--';
        var shortId = n.node_id ? n.node_id.split(':').slice(-3).join('') : '--';
        var tr = document.createElement('tr');
        tr.title = 'ID: ' + (n.node_id || '') + ' | FW: ' + (n.fw_version || '--') + ' | Coin GPIO' + (n.coin_gpio||'?') + ' / Relay GPIO' + (n.relay_gpio||'?');
        tr.innerHTML =
          '<td>' + (n.name || n.node_id) + '</td>' +
          '<td style="font-family:monospace;font-size:.78rem;color:var(--text2)">' + firmwareLabel + '</td>' +
          '<td style="font-family:monospace;font-size:.78rem;color:var(--text2)" title="' + (n.node_id||'') + '">' + shortId + '</td>' +
          '<td>' + (n.ip_address || '--') + '</td>' +
          '<td>' + modeLabel + '</td>' +
          '<td style="font-size:.78rem;color:var(--text2)">' + pinsLabel + '</td>' +
          '<td style="font-size:.78rem;color:var(--text2)">' + pulseLabel + '</td>' +
          '<td style="text-align:center">' + (n.total_coins || 0) + '</td>' +
          '<td>' + statusHtml + '</td>' +
          '<td>' + timeAgo(n.last_heartbeat) + '</td>' +
          '<td style="white-space:nowrap">' +
            '<button class="action-btn" onclick="configureVendo(\'' + n.node_id + '\')" title="Configure hardware">Configure</button> ' +
            '<button class="action-btn" onclick="renameVendo(\'' + n.node_id + '\')" title="Rename">Rename</button> ' +
            '<button class="action-btn danger" onclick="unbindVendo(\'' + n.node_id + '\')" title="Unbind this coinslot">Unbind</button>' +
          '</td>';
        tbody.appendChild(tr);
      }
    });
  }

  window.configureVendo = function (node_id) {
    var node = coinNodesById[node_id];
    if (!node) return;
    $('coin-settings-node-id').value = node_id;
    $('coin-settings-name').value = node.name || 'KemoFi Coinslot';
    $('coin-settings-coin-gpio').value = node.coin_gpio !== undefined ? node.coin_gpio : 2;
    $('coin-settings-relay-gpio').value = node.relay_gpio !== undefined ? node.relay_gpio : 15;
    $('coin-settings-modal').style.display = 'flex';
    $('coin-settings-modal').setAttribute('aria-hidden', 'false');
  };

  function closeCoinSettingsModal() {
    $('coin-settings-modal').style.display = 'none';
    $('coin-settings-modal').setAttribute('aria-hidden', 'true');
  }

  var _coinSettingsModal = $('coin-settings-modal');
  if (_coinSettingsModal) _coinSettingsModal.addEventListener('click', function (event) {
    if (event.target === _coinSettingsModal) closeCoinSettingsModal();
  });
  document.addEventListener('keydown', function (event) {
    if (event.key === 'Escape' && _coinSettingsModal && _coinSettingsModal.getAttribute('aria-hidden') === 'false') {
      closeCoinSettingsModal();
    }
  });

  var _saveCoinSettingsBtn = $('save-coin-settings');
  if (_saveCoinSettingsBtn) _saveCoinSettingsBtn.addEventListener('click', function () {
    var btn = this;
    setLoading(btn, true);
    xhr('POST', API + '/coin-nodes/settings', {
      node_id: $('coin-settings-node-id').value,
      name: $('coin-settings-name').value,
      coin_gpio: $('coin-settings-coin-gpio').value,
      relay_gpio: $('coin-settings-relay-gpio').value
    }, function (err, data) {
      setLoading(btn, false);
      if (err || !data || data.error) {
        showToast((data && (data.message || data.error)) || 'Failed to save Coinslot settings', 'error');
        return;
      }
      closeCoinSettingsModal();
      showToast('Coinslot settings saved. The ESP will apply them automatically.', 'success');
      loadVendos();
    });
  });
  var _cancelCoinSettingsBtn = $('cancel-coin-settings');
  if (_cancelCoinSettingsBtn) _cancelCoinSettingsBtn.addEventListener('click', closeCoinSettingsModal);
  var _closeCoinSettingsBtn = $('close-coin-settings-modal');
  if (_closeCoinSettingsBtn) _closeCoinSettingsBtn.addEventListener('click', closeCoinSettingsModal);

  window.renameVendo = function (node_id) {
    var name = prompt('Enter new name for this node:');
    if (!name || !name.trim()) return;
    xhr('POST', API + '/coin-nodes/rename', {node_id: node_id, name: name.trim()}, function (err, data) {
      if (err || !data || data.error) { showToast('Failed to rename', 'error'); return; }
      loadVendos();
    });
  };

  window.unbindVendo = function (node_id) {
    if (!confirm('Unbind this coinslot (' + node_id + ')?\n\nIt will be denied immediately and must be paired again. Coin history and earnings will be kept.')) return;
    xhr('POST', API + '/coin-nodes/delete', {node_id: node_id}, function (err, data) {
      if (err || !data || data.error) { showToast('Failed to unbind coinslot', 'error'); return; }
      showToast('Coinslot unbound. Pair it again before reuse.', 'success');
      loadVendos();
    });
  };

  // ── Bind Code Modal ──────────────────────────────────────────────────────
  var _refreshVendosBtn = $('btn-refresh-vendos');
  if (_refreshVendosBtn) _refreshVendosBtn.addEventListener('click', loadVendos);

  // ── Sessions ─────────────────────────────────────────────────────────────────
  var sessionsRequest = null;
  var sessionsPollTimer = null;
  var sessionsClockTimer = null;
  var renderedSessions = [];

  function stopSessionsPolling() {
    if (sessionsPollTimer) clearInterval(sessionsPollTimer);
    if (sessionsClockTimer) clearInterval(sessionsClockTimer);
    if (sessionsRequest) sessionsRequest.abort();
    sessionsPollTimer = null;
    sessionsClockTimer = null;
    sessionsRequest = null;
  }

  function startSessionsPolling() {
    stopSessionsPolling();
    if (document.hidden || activeAdminTab !== 'sessions') return;
    sessionsPollTimer = setInterval(function () { loadSessions(false); }, 5000);
    sessionsClockTimer = setInterval(updateSessionCountdowns, 1000);
  }

  function loadSessions(showLoading) {
    var tbody = document.getElementById('sessions-body');
    if (!tbody || sessionsRequest) return;
    if (showLoading && renderedSessions.length === 0) {
      tbody.innerHTML = '<tr><td colspan="5" style="text-align:center;padding:18px;color:var(--text2);">Loading sessions...</td></tr>';
    }

    var req = new XMLHttpRequest();
    sessionsRequest = req;
    req.open('GET', API + '/sessions', true);
    req.withCredentials = true;
    req.timeout = 10000;
    req.onload = function () {
      sessionsRequest = null;
      if (req.status === 200) {
        try {
          renderSessions(JSON.parse(req.responseText));
        } catch (e) {
          tbody.innerHTML = '<tr><td colspan="5" style="text-align:center;padding:18px;color:#f85149;">Could not read session data.</td></tr>';
        }
      } else if (req.status === 401) {
        stopSessionsPolling();
        tbody.innerHTML = '<tr><td colspan="5" style="text-align:center;padding:18px;color:#f85149;">Session expired. Log in again.</td></tr>';
      } else if (renderedSessions.length === 0) {
        tbody.innerHTML = '<tr><td colspan="5" style="text-align:center;padding:18px;color:#f85149;">Unable to load sessions.</td></tr>';
      }
    };
    req.onerror = req.ontimeout = function () {
      sessionsRequest = null;
      if (renderedSessions.length === 0) {
        tbody.innerHTML = '<tr><td colspan="5" style="text-align:center;padding:18px;color:#f85149;">Router did not respond.</td></tr>';
      }
    };
    req.onabort = function () { sessionsRequest = null; };
    req.send();
  }

  function updateSessionCountdowns() {
    var now = Date.now();
    for (var i = 0; i < renderedSessions.length; i++) {
      var sessionRow = renderedSessions[i];
      var element = document.getElementById('session-time-' + i);
      if (!element) continue;
      if (sessionRow.member) {
        element.textContent = 'Unlimited';
        continue;
      }
      if (sessionRow.status === 'idle') {
        element.textContent = '--';
        continue;
      }
      var remaining = sessionRow._remainingAtSync;
      if (sessionRow.status === 'active') {
        remaining -= Math.floor((now - sessionRow._syncedAt) / 1000);
      }
      element.textContent = formatRemaining(remaining);
    }
  }

  function renderSessions(data) {
    var tbody = document.getElementById('sessions-body');
    tbody.innerHTML = '';
    var sessions = data.sessions || [];
    renderMembers(data.members || []);
    var receivedAt = Date.now();
    renderedSessions = sessions;
    for (var syncIndex = 0; syncIndex < sessions.length; syncIndex++) {
      sessions[syncIndex]._remainingAtSync = Number(sessions[syncIndex].remaining_seconds) || 0;
      sessions[syncIndex]._syncedAt = receivedAt;
    }
    var sc = document.getElementById('session-count');
    if (sc) sc.textContent = sessions.length;

    if (sessions.length === 0) {
      tbody.innerHTML = '<tr><td colspan="5" style="text-align:center;padding:18px;color:var(--text2);">No connected devices or saved sessions.</td></tr>';
      renderDevices(data.devices || []);
      return;
    }

    var statusLabels = {
      active: {text: 'Active', css: 'badge-green'},
      paused: {text: 'Paused', css: 'badge-blue'},
      idle: {text: 'Idle', css: 'badge-gray'}
    };
    for (var i = 0; i < sessions.length; i++) {
      var s = sessions[i];
      var tr = document.createElement('tr');
      var status = s.member ? {text: 'Member', css: 'badge-green'} : (statusLabels[s.status] || statusLabels.idle);
      var sName = s.device_name || s.name || shortMac(s.mac);
      var connection = s.connected ? (s.ssid || s.interface || 'Connected') : 'Not on WiFi';
      var finalAction = s.member ? '' : (s.status === 'idle'
        ? '<button class="action-btn danger" onclick="adminAction(\x27forget\x27,\x27' + s.mac + '\x27)">Forget</button>'
        : '<button class="action-btn danger" onclick="adminAction(\x27reset\x27,\x27' + s.mac + '\x27)">Reset</button>');
      tr.innerHTML = '<td><strong>' + escapeHtml(sName) + '</strong><div style="font-size:.7rem;color:var(--text2);margin-top:2px">' + escapeHtml(s.mac) + '</div></td>' +
        '<td id="session-time-' + i + '">--</td>' +
        '<td>' + escapeHtml(s.ip || '--') + '<div style="font-size:.7rem;color:var(--text2);margin-top:2px">' + escapeHtml(connection) + '</div></td>' +
        '<td><span class="badge ' + status.css + '">' + status.text + '</span></td>' +
        '<td><button class="action-btn" onclick="adminAction(\x27rename\x27,\x27' + s.mac + '\x27)">Name</button> ' +
        (s.member ? '' : '<button class="action-btn" onclick="adminAction(\x27promote-member\x27,\x27' + s.mac + '\x27)">Make Member</button> ') +
        (s.member ? '' : '<button class="action-btn" onclick="adminAction(\x27edit-time\x27,\x27' + s.mac + '\x27)">Time</button> ') +
        '<button class="action-btn danger" onclick="adminAction(\x27block\x27,\x27' + s.mac + '\x27)">Block</button> ' +
        finalAction + '</td>';
      tbody.appendChild(tr);
    }
    updateSessionCountdowns();
    renderDevices(data.devices || []);
  }

  function renderMembers(members) {
    var body = document.getElementById('members-body');
    if (!body) return;
    body.innerHTML = '';
    if (!members.length) {
      body.innerHTML = '<tr><td colspan="4" style="text-align:center;padding:18px;color:var(--text2)">No members yet. Promote a device from Sessions or Known Devices.</td></tr>';
      return;
    }
    for (var i = 0; i < members.length; i++) {
      var member = members[i];
      var row = document.createElement('tr');
      row.innerHTML = '<td><strong>' + escapeHtml(member.name || shortMac(member.mac)) + '</strong><div style="font-size:.7rem;color:var(--text2);margin-top:2px">' + escapeHtml(member.mac) + '</div></td>' +
        '<td>' + timeAgo(member.member_since) + '</td>' +
        '<td><span class="badge badge-green">Unlimited</span></td>' +
        '<td><button class="action-btn danger" onclick="adminAction(\x27remove-member\x27,\x27' + member.mac + '\x27)">Remove Membership</button></td>';
      body.appendChild(row);
    }
  }
  
  function renderDevices(devices) {
    var devBody = document.getElementById('devices-body');
    if (!devBody) return;
    devBody.innerHTML = '';
    for (var j = 0; j < devices.length; j++) {
      var d = devices[j];
      var dtr = document.createElement('tr');
      var blocked = d.blocked ? '<span style="color:#f85149">Blocked</span>' : '<span style="color:#8b949e">OK</span>';
      var dNameLabel = d.name ? 'Rename' : 'Name';
      dtr.innerHTML = '<td>' + (d.name || shortMac(d.mac)) + '</td>' +
        '<td>' + timeAgo(d.last_seen) + '</td>' +
        '<td>' + (d.total_sessions != null ? d.total_sessions : "--") + '</td>' +
        '<td>' + (d.member ? '<span class="badge badge-green">Member</span>' : blocked) + '</td>' +
        '<td><button class="action-btn" onclick="adminAction(\x27rename\x27,\x27' + d.mac + '\x27)">' + dNameLabel + '</button> ' +
        (d.member ? '' : '<button class="action-btn" onclick="adminAction(\x27promote-member\x27,\x27' + d.mac + '\x27)">Make Member</button> ') +
        (d.blocked ? '<button class="action-btn" onclick="adminAction(\x27unblock\x27,\x27' + d.mac + '\x27)">Unblock</button>' : '<button class="action-btn danger" onclick="adminAction(\x27block\x27,\x27' + d.mac + '\x27)">Block</button>') +
        '</td>';
      devBody.appendChild(dtr);
    }
  }
  window.loadSessions = function () { loadSessions(true); };
  window.loadDevices = function () { loadSessions(false); };

  document.addEventListener('visibilitychange', function () {
    if (document.hidden) {
      stopDashboardPolling();
      stopSessionsPolling();
    } else if (activeAdminTab === 'dashboard') {
      startDashboardPolling();
    } else if (activeAdminTab === 'sessions') {
      startSessionsPolling();
      loadSessions(false);
    }
  });

  // Session actions (global)
  window.adminAction = function (action, mac) {
    var endpoint = '';
    var payload = {mac: mac};
    if (action === 'rename') {
      var name = prompt('Enter device name:');
      if (!name) return;
      endpoint = '/sessions/set-name';
      payload.name = name;
    } else if (action === 'edit-time') {
      var mins = prompt('Set remaining minutes:');
      if (!mins) return;
      payload.minutes = parseInt(mins, 10);
      if (!isFinite(payload.minutes) || payload.minutes < 1) { showToast('Enter valid minutes', 'error'); return; }
      endpoint = '/sessions/edit-time';
    } else if (action === 'block') {
      if (!confirm('Block this device?')) return;
      endpoint = '/sessions/block';
    } else if (action === 'unblock') {
      endpoint = '/sessions/unblock';
    } else if (action === 'promote-member') {
      if (!confirm('Give this household/staff device unlimited access?')) return;
      endpoint = '/sessions/promote-member';
    } else if (action === 'remove-member') {
      if (!confirm('Remove unlimited member access from this device?')) return;
      endpoint = '/sessions/remove-member';
    } else if (action === 'reset') {
      if (!confirm('Reset session for this device? Time will be lost.')) return;
      endpoint = '/sessions/reset';
    } else if (action === 'forget') {
      if (!confirm('Forget this idle device? Saved identity will be removed. Sales history will be kept.')) return;
      endpoint = '/sessions/forget';
    } else {
      return;
    }
    xhr('POST', API + endpoint, payload, function (err, data) {
      if (err || !data || data.error) {
        showToast((data && (data.message || data.error)) || 'Action failed', 'error');
        return;
      }
      if (action === 'forget') {
        showToast('Saved device identity removed. Connected devices remain visible while online.', 'success');
      }
      loadSessions();
    });
  };

  function cleanupSessionRecords(button, endpoint, promptText, resultLabel) {
    if (!button || !confirm(promptText)) return;
    button.disabled = true;
    xhr('POST', API + endpoint, {}, function (err, data) {
      button.disabled = false;
      if (err || !data || data.error) {
        showToast((data && (data.message || data.error)) || 'Cleanup failed', 'error');
        return;
      }
      showToast((Number(data.removed) || 0) + ' ' + resultLabel, 'success');
      loadSessions(false);
    });
  }

  var clearExpiredSessionsBtn = $('clear-expired-sessions-btn');
  if (clearExpiredSessionsBtn) clearExpiredSessionsBtn.addEventListener('click', function () {
    cleanupSessionRecords(
      clearExpiredSessionsBtn,
      '/sessions/clear-expired',
      'Clear expired and zero-time session records? Active and paused sessions will be kept.',
      'expired session(s) removed'
    );
  });

  var forgetStaleDevicesBtn = $('forget-stale-devices-btn');
  if (forgetStaleDevicesBtn) forgetStaleDevicesBtn.addEventListener('click', function () {
    cleanupSessionRecords(
      forgetStaleDevicesBtn,
      '/sessions/forget-stale',
      'Forget unnamed, unblocked devices disconnected for more than 30 days? Sales history will be kept.',
      'stale device(s) forgotten'
    );
  });

  // ── Vouchers ────────────────────────────────────────────────────────────
  var voucherGenForm = $('voucher-gen-form');
  var voucherValidity = $('voucher-validity');
  var voucherValidityUnit = $('voucher-validity-unit');

  function syncVoucherValidityInput() {
    var never = voucherValidityUnit.value === 'never';
    voucherValidity.disabled = never;
    voucherValidity.style.opacity = never ? '.45' : '1';
  }

  function voucherValiditySeconds() {
    if (voucherValidityUnit.value === 'never') return 0;
    var value = parseFloat(voucherValidity.value);
    if (!isFinite(value) || value <= 0) return null;
    var factors = {
      hours: 3600,
      days: 86400,
      weeks: 604800,
      months: 2592000
    };
    return Math.round(value * factors[voucherValidityUnit.value]);
  }

  function formatVoucherDuration(minutes) {
    var m = Number(minutes) || 0;
    if (m >= 60 * 24 * 30 && m % (60 * 24 * 30) === 0) {
      return (m / (60 * 24 * 30)) + ' month' + (m / (60 * 24 * 30) > 1 ? 's' : '');
    }
    if (m >= 60 * 24 && m % (60 * 24) === 0) {
      return (m / (60 * 24)) + ' day' + (m / (60 * 24) > 1 ? 's' : '');
    }
    if (m >= 60 && m % 60 === 0) {
      return (m / 60) + ' hr' + (m / 60 > 1 ? 's' : '');
    }
    return m + ' min';
  }

  function formatVoucherValidity(voucher) {
    var validitySeconds = Number(voucher.validity_seconds) || 0;
    if (!voucher.used) {
      if (validitySeconds <= 0) return 'No expiry';
      return formatVoucherDuration(validitySeconds / 60) + ' after redeem';
    }
    var validUntil = Number(voucher.valid_until) || 0;
    if (validUntil <= 0) return 'No expiry';
    return new Date(validUntil * 1000).toLocaleString();
  }

  function updateVoucherSelection() {
    var boxes = document.querySelectorAll('.v-sel-cb');
    var selected = 0;
    var available = 0;
    for (var i = 0; i < boxes.length; i++) {
      if (!boxes[i].disabled) {
        available++;
        if (boxes[i].checked) selected++;
      }
      if (boxes[i].parentNode && boxes[i].parentNode.parentNode) {
        boxes[i].parentNode.parentNode.classList.toggle('selected-row', boxes[i].checked);
      }
    }
    $('selected-count').textContent = selected;
    $('btn-delete-selected').disabled = selected === 0;
    $('btn-delete-selected').style.opacity = selected === 0 ? '.4' : '1';
    $('btn-delete-selected').style.cursor = selected === 0 ? 'not-allowed' : 'pointer';
    $('voucher-select-all').checked = available > 0 && selected === available;
    $('voucher-select-all').indeterminate = selected > 0 && selected < available;
  }

  voucherValidityUnit.addEventListener('change', syncVoucherValidityInput);
  syncVoucherValidityInput();
  $('btn-gen-vouchers').addEventListener('click', function () {
    voucherGenForm.style.display = voucherGenForm.style.display === 'none' ? '' : 'none';
  });
  $('voucher-gen-cancel').addEventListener('click', function () { hide(voucherGenForm); });
  $('voucher-gen-submit').addEventListener('click', function () {
    var submitBtn = $('voucher-gen-submit');
    var qty = parseInt($('voucher-qty').value, 10);
    var duration = parseFloat($('voucher-duration').value);
    var unit = $('voucher-duration-unit').value;
    var mins;
    if (unit === 'minutes') mins = duration;
    else if (unit === 'hours') mins = duration * 60;
    else if (unit === 'days') mins = duration * 60 * 24;
    else if (unit === 'months') mins = duration * 60 * 24 * 30;
    else mins = duration;
    mins = Math.round(mins);
    var price = parseFloat($('voucher-price').value);
    var label = $('voucher-label').value.trim();
    var validitySeconds = voucherValiditySeconds();
    var codeType = $('voucher-code-type').value;
    var codeLength = parseInt($('voucher-code-length').value, 10);
    if (!isFinite(qty) || qty < 1 || qty > 500) {
      showToast('Quantity must be between 1 and 500.', 'error');
      return;
    }
    if (!isFinite(mins) || mins <= 0) {
      showToast('Duration must be greater than zero.', 'error');
      return;
    }
    if (!isFinite(price) || price < 0) {
      showToast('Price cannot be negative.', 'error');
      return;
    }
    if (validitySeconds === null) {
      showToast('Validity must be greater than zero.', 'error');
      return;
    }
    if (['numbers', 'letters', 'mixed'].indexOf(codeType) === -1) {
      showToast('Select a valid code format.', 'error');
      return;
    }
    if (!isFinite(codeLength) || codeLength < 4 || codeLength > 8) {
      showToast('Code length must be between 4 and 8.', 'error');
      return;
    }
    setLoading(submitBtn, true);
    xhr('POST', API + '/vouchers/generate', {
      quantity: qty,
      minutes: mins,
      price: price,
      label: label,
      validity_seconds: validitySeconds,
      code_type: codeType,
      code_length: codeLength
    }, function (err, data) {
      setLoading(submitBtn, false);
      if (err || !data || data.error) {
        showToast((data && data.error) || 'Failed to generate vouchers.', 'error');
        return;
      }
      hide(voucherGenForm);
      loadVouchers();
      showToast('Generated ' + (data.count || qty) + ' vouchers!');
    });
  });

  function loadVouchers() {
    xhr('GET', API + '/vouchers', null, function (err, data) {
      if (err || !data) return;
      var tbody = $('vouchers-body');
      tbody.innerHTML = '';
      var vouchers = data.vouchers || [];
      if (vouchers.length === 0) {
        tbody.innerHTML = '<tr><td colspan="8" style="text-align:center;padding:18px;color:var(--text2)">No vouchers yet.</td></tr>';
        updateVoucherSelection();
        return;
      }
      for (var i = 0; i < vouchers.length; i++) {
        var v = vouchers[i];
        var statusColor = v.expired ? '#f85149' : (v.used ? '#8b949e' : '#7ee787');
        var statusText = v.expired ? 'Expired' : (v.used ? 'Used' : 'Available');
        var tr = document.createElement('tr');
        if (v.used) tr.className = 'used-row';
        tr.innerHTML =
          '<td>' + (v.used ? '' : '<input type="checkbox" class="v-sel-cb" data-id="' + Number(v.id) + '">') + '</td>' +
          '<td style="font-family:monospace;letter-spacing:1px">' + escapeHtml(v.code) + '</td>' +
          '<td>' + escapeHtml(formatVoucherDuration(v.minutes)) + '</td>' +
          '<td>\u20B1' + escapeHtml(v.price) + '</td>' +
          '<td style="color:' + statusColor + '">' + statusText + '</td>' +
          '<td>' + escapeHtml(formatVoucherValidity(v)) + '</td>' +
          '<td>' + escapeHtml(v.batch || '--') + '</td>' +
          '<td>' + (v.used ? '' : '<button class="action-btn danger voucher-delete-btn" data-id="' + Number(v.id) + '" data-code="' + escapeHtml(v.code) + '">Delete</button>') + '</td>';
        tbody.appendChild(tr);
      }

      var checkboxes = document.querySelectorAll('.v-sel-cb');
      for (var c = 0; c < checkboxes.length; c++) {
        checkboxes[c].addEventListener('change', updateVoucherSelection);
      }
      var deleteButtons = document.querySelectorAll('.voucher-delete-btn');
      for (var d = 0; d < deleteButtons.length; d++) {
        deleteButtons[d].addEventListener('click', function () {
          deleteVoucher(Number(this.getAttribute('data-id')), this.getAttribute('data-code'));
        });
      }
      updateVoucherSelection();
    });
  }

  function deleteVoucher(id, code) {
    if (!confirm('Delete voucher ' + code + '?')) return;
    xhr('POST', API + '/vouchers/delete', {id: id}, function (err, data) {
      if (err || !data || data.error) {
        showToast((data && data.error) || 'Failed to delete voucher.', 'error');
        return;
      }
      loadVouchers();
      showToast(data.deleted ? 'Voucher deleted.' : 'Voucher was already used.');
    });
  }

  $('voucher-select-all').addEventListener('change', function () {
    var boxes = document.querySelectorAll('.v-sel-cb');
    for (var i = 0; i < boxes.length; i++) {
      if (!boxes[i].disabled) boxes[i].checked = this.checked;
    }
    updateVoucherSelection();
  });

  $('btn-delete-selected').addEventListener('click', function () {
    var boxes = document.querySelectorAll('.v-sel-cb:checked');
    var ids = [];
    for (var i = 0; i < boxes.length; i++) ids.push(Number(boxes[i].getAttribute('data-id')));
    if (ids.length === 0 || !confirm('Delete ' + ids.length + ' selected voucher(s)?')) return;
    xhr('POST', API + '/vouchers/delete', {ids: ids}, function (err, data) {
      if (err || !data || data.error) {
        showToast((data && data.error) || 'Failed to delete selected vouchers.', 'error');
        return;
      }
      loadVouchers();
      showToast('Deleted ' + (data.deleted || 0) + ' voucher(s).');
    });
  });

  $('btn-delete-used').addEventListener('click', function () {
    if (!confirm('Archive all used vouchers?')) return;
    xhr('POST', API + '/vouchers/delete', {delete_used: true}, function (err, data) {
      if (err || !data || data.error) {
        showToast((data && data.error) || 'Failed to archive used vouchers.', 'error');
        return;
      }
      loadVouchers();
      showToast('Archived ' + (data.deleted || 0) + ' used voucher(s).');
    });
  });

  $('print-vouchers-btn').addEventListener('click', function () { window.print(); });

  // ── Rate Tier UI ────────────────────────────────────────────────────────
  function rateUnitMultiplier(unit) {
    if (unit === 'days') return 1440;
    if (unit === 'hours') return 60;
    return 1;
  }

  function rateDurationFromMinutes(minutes) {
    var total = Math.max(0, Math.round(Number(minutes) || 0));
    if (total > 0 && total % 1440 === 0) return {value: total / 1440, unit: 'days'};
    if (total > 0 && total % 60 === 0) return {value: total / 60, unit: 'hours'};
    return {value: total || '', unit: 'minutes'};
  }

  function rateMinutesForRow(row) {
    var value = Number(row.querySelector('.tier-duration').value);
    var unit = row.querySelector('.tier-unit').value;
    var minutes = value * rateUnitMultiplier(unit);
    return value > 0 && Math.floor(minutes) === minutes ? minutes : 0;
  }

  function formatRateMinutes(minutes) {
    var duration = rateDurationFromMinutes(minutes);
    if (!duration.value) return '0 min';
    var label = duration.unit.slice(0, -1);
    return duration.value + ' ' + label + (duration.value === 1 ? '' : 's');
  }

  function syncRateTextarea() {
    var rows = $('rate-rows').querySelectorAll('.rate-tier-row');
    var lines = [];
    rows.forEach(function (row) {
      var php = row.querySelector('.tier-php').value.trim();
      var mins = rateMinutesForRow(row);
      var pauseLimit = row.querySelector('.tier-pause-limit').value.trim();
      if (!pauseLimit) pauseLimit = '0';
      var validityValue = row.querySelector('.tier-validity-value').value.trim();
      var validityUnit = row.querySelector('.tier-validity-unit').value;
      if (!validityValue) validityValue = '0';
      if (php && mins) lines.push(php + ':' + mins + ':' + pauseLimit + ':' + validityValue + ':' + validityUnit);
    });
    $('set-rates').value = lines.join('\n');
    $('rate-empty').style.display = rows.length ? 'none' : '';
  }

  function addRateTierRow(php, mins, pauseLimit, validityValue, validityUnit) {
    var container = $('rate-rows');
    var row = document.createElement('div');
    row.className = 'rate-tier-row';
    var phpVal = php !== undefined ? php : '';
    var duration = rateDurationFromMinutes(mins);
    var durationVal = duration.value;
    var unitVal = duration.unit;
    var pauseLimitVal = pauseLimit !== undefined ? pauseLimit : '';
    var validityValueVal = validityValue !== undefined ? validityValue : '';
    var validityUnitVal = validityUnit !== undefined ? validityUnit.toUpperCase() : 'D';
    row.innerHTML =
      '<div class="rate-tier-field"><label>\u20B1 Amount</label>' +
      '<input type="number" class="tier-php" min="1" step="1" value="' + escapeHtml(phpVal) + '" placeholder="e.g. 5"></div>' +
      '<div class="rate-tier-sep">=</div>' +
      '<div class="rate-tier-field"><label>Time</label>' +
      '<input type="number" class="tier-duration" min="1" step="1" value="' + escapeHtml(durationVal) + '" placeholder="e.g. 2"></div>' +
      '<div class="rate-tier-field"><label>Unit</label>' +
      '<select class="tier-unit"><option value="minutes">Minutes</option><option value="hours">Hours</option><option value="days">Days</option></select></div>' +
      '<div class="rate-tier-field"><label>Pause limit (times)</label>' +
      '<input type="number" class="tier-pause-limit" min="0" step="1" value="' + escapeHtml(pauseLimitVal) + '" placeholder="Unlimited"></div>' +
      '<div class="rate-tier-field"><label>Valid for</label>' +
      '<input type="number" class="tier-validity-value" min="0" step="1" value="' + escapeHtml(validityValueVal) + '" placeholder="Unlimited"></div>' +
      '<div class="rate-tier-field"><label>Validity unit</label>' +
      '<select class="tier-validity-unit"><option value="D">Days</option><option value="H">Hours</option><option value="M">Minutes</option></select></div>' +
      '<div class="rate-tier-badge tier-preview">--</div>' +
      '<button type="button" class="rate-tier-del" title="Remove">&#x2715;</button>';
    row.querySelector('.tier-unit').value = unitVal;
    row.querySelector('.tier-validity-unit').value = ['D', 'H', 'M'].indexOf(validityUnitVal) >= 0 ? validityUnitVal : 'D';
    row.querySelector('.rate-tier-del').addEventListener('click', function () {
      row.remove(); syncRateTextarea();
    });
    function updatePreview() {
      var p = row.querySelector('.tier-php').value.trim();
      var m = rateMinutesForRow(row);
      var v = Number(row.querySelector('.tier-validity-value').value) || 0;
      var unit = row.querySelector('.tier-validity-unit').value;
      var unitLabel = unit === 'D' ? 'day' : (unit === 'H' ? 'hour' : 'minute');
      var validity = v > 0 ? 'valid for ' + v + ' ' + unitLabel + (v === 1 ? '' : 's') : 'unlimited validity';
      var pause = Number(row.querySelector('.tier-pause-limit').value) || 0;
      var pauseLabel = pause > 0 ? 'up to ' + pause + ' pause' + (pause === 1 ? '' : 's') : 'unlimited pauses';
      row.querySelector('.tier-preview').textContent = (p && m) ? '\u20B1' + p + ' = ' + formatRateMinutes(m) + ' \u00b7 ' + validity + ' \u00b7 ' + pauseLabel : '--';
      syncRateTextarea();
    }
    row.querySelector('.tier-php').addEventListener('input', updatePreview);
    row.querySelector('.tier-duration').addEventListener('input', updatePreview);
    row.querySelector('.tier-unit').addEventListener('change', updatePreview);
    row.querySelector('.tier-pause-limit').addEventListener('input', updatePreview);
    row.querySelector('.tier-validity-value').addEventListener('input', updatePreview);
    row.querySelector('.tier-validity-unit').addEventListener('change', updatePreview);
    container.appendChild(row);
    $('rate-empty').style.display = 'none';
    updatePreview();
  }

  $('btn-add-tier').addEventListener('click', function () { addRateTierRow(); });

  function renderRateTiers(rawStr) {
    $('rate-rows').innerHTML = '';
    var lines = (rawStr || '').split('\n').filter(function (l) { return l.trim(); });
    if (lines.length === 0) {
      $('rate-empty').style.display = '';
      $('set-rates').value = '';
      return;
    }
    lines.forEach(function (line) {
      var parts = line.split(':');
      if (parts.length >= 2) addRateTierRow(
        parts[0].trim(), parts[1].trim(), parts[2] ? parts[2].trim() : '',
        parts[3] ? parts[3].trim() : '', parts[4] ? parts[4].trim() : 'D'
      );
    });
    syncRateTextarea();
  }

  // ── Bandwidth mode toggle ────────────────────────────────────────────────
  window._bwSelect = function (mode) {
    var perClient = $('bw-per-client');
    var shared = $('bw-shared');
    if (perClient) perClient.style.display = mode === 'per_client' ? '' : 'none';
    if (shared) shared.style.display = mode === 'shared' ? '' : 'none';
  };

  // ── Settings ────────────────────────────────────────────────────────────
  function applyAdminBranding(value, branding) {
    var name = String(value || '').replace(/^\s+|\s+$/g, '') || 'KemoFi';
    applyLoginBranding(name, branding);
    var sidebarName = $('admin-business-name');
    var mobileName = $('mobile-business-name');
    if (sidebarName) { sidebarName.textContent = name; sidebarName.title = name; }
    if (mobileName) { mobileName.textContent = name; mobileName.title = name; }
  }

  function loadSettings() {
    xhr('GET', API + '/settings', null, function (err, data) {
      if (err || !data) return;
      setSqmVisibility(data.sqm_available !== false);
      var s = data.settings || data;  // API returns flat object
      $('set-business-name').value = s.business_name || 'KemoFi';
      $('set-portal-name').value = s.portal_name || 'KemoFi WiFi';
      $('set-portal-footer-text').value = s.portal_footer_text || '';
      $('set-portal-footer-link').value = s.portal_footer_link || 'https://kemofi.com/';
      applyAdminBranding(s.business_name, s);
      $('set-show-rates').checked = String(s.portal_show_rates || '1') !== '0';
      $('set-show-voucher').checked = String(s.portal_show_voucher || s.show_voucher || '1') !== '0';
      $('set-show-coin').checked = String(s.portal_show_coin || '1') !== '0';
      $('set-hide-device-info').value = s.portal_hide_device_info || s.hide_device_info || '0';
      renderRateTiers(s.portal_rates || '1:12\n5:60\n10:120');
      $('set-flat-rate').value = s.coin_min_per_php || '';
      $('set-coin-timeout').value = s.coinslot_timeout_seconds || s.portal_coin_timeout_seconds || '60';
      $('set-busy-lock').value = s.coinslot_busy_lock || s.coin_busy_lock || '1';
      $('set-max-empty').value = s.coinslot_max_empty_opens || s.coin_max_empty_opens || '3';
      $('set-empty-cooldown').value = s.coinslot_empty_open_cooldown_seconds || s.coin_empty_cooldown || '120';
      $('set-pause-penalty').value = s.pause_penalty_minutes || '0';
      $('set-auto-pause').value = s.auto_pause_on_disconnect || '1';
      if ($('set-auto-resume')) $('set-auto-resume').value = s.auto_resume_on_reconnect || '1';
      // Preserve both per-device and shared router bandwidth modes.
      var savedBwMode = s.bw_mode || s.bandwidth_mode;
      var bwMode = savedBwMode === 'per_client' || savedBwMode === 'shared' ? savedBwMode : 'off';
      var bwControl = $('bw-device-enabled');
      if (bwControl) { bwControl.value = bwMode; _bwSelect(bwMode); }
      $('bw-per-client-down').value = s.bw_per_client_down_kbps || '';
      $('bw-per-client-up').value = s.bw_per_client_up_kbps || '';
      if ($('bw-shared-down')) $('bw-shared-down').value = s.bw_total_down_kbps || '';
      if ($('bw-shared-up')) $('bw-shared-up').value = s.bw_total_up_kbps || '';
      if ($('bw-exempt-macs')) $('bw-exempt-macs').value = s.bw_exempt_macs || '';
      $('set-sqm-enabled').value = s.sqm_enabled || '1';
      $('sqm-download').value = s.sqm_download_kbps || '10240';
      $('sqm-upload').value = s.sqm_upload_kbps || '10240';
      $('sqm-linklayer').value = s.sqm_linklayer || 'ethernet';
      $('sqm-overhead').value = s.sqm_overhead || '0';
      $('sqm-host-fairness').value = s.sqm_host_fairness || '1';
      $('set-free-enabled').value = s.free_time_enabled || '0';
      $('set-free-minutes').value = s.free_time_minutes || '5';
      $('set-free-limit').value = s.free_time_daily_limit || '1';
    });
  }

  function loadRates() {
    xhr('GET', API + '/rates', null, function (err, data) {
      if (err || !data) return;
      renderRateTiers(data.rates || '1:12\n5:60\n10:120');
      if ($('set-flat-rate')) $('set-flat-rate').value = data.coin_min_per_php || '';
    });
  }

  function loadWifiConfig() {
    xhr('GET', API + '/system/wifi', null, function (err, data) {
      if (err || !data || data.error) return;
      var radios = data.radios || {};
      var radio2g = radios['2g'] || {};
      var radio5g = radios['5g'] || {};
      var input2g = $('wifi-ssid-2g');
      var input5g = $('wifi-ssid-5g');
      if (input2g) {
        input2g.value = radio2g.ssid || '';
        input2g.disabled = radio2g.available === false;
        input2g.placeholder = radio2g.available === false ? '2.4 GHz unavailable' : '';
      }
      if (input5g) {
        input5g.value = radio5g.ssid || '';
        input5g.disabled = radio5g.available === false;
        input5g.placeholder = radio5g.available === false ? '5 GHz unavailable' : '';
      }
    });
  }

  var wanPollTimer = null;
  var wanPollDeadline = 0;

  function setWanStatus(message, error) {
    var status = $('wan-save-status');
    if (status) {
      status.textContent = message || '';
      status.style.color = error ? 'var(--red)' : 'var(--text2)';
    }
  }

  function renderWanRuntime(runtime) {
    runtime = runtime || {};
    var state = $('wan-runtime-status');
    if (state) {
      state.textContent = runtime.online ? 'Connected' : 'Offline';
      state.style.color = runtime.online ? 'var(--green)' : 'var(--amber)';
    }
    setText('wan-runtime-interface', runtime.interface || '--');
    setText('wan-runtime-ip', runtime.ip || '--');
    setText('wan-runtime-gateway', runtime.gateway || '--');
  }

  function setWanMode(mode) {
    mode = mode || 'dhcp';
    var dhcp = $('wan-dhcp-fields');
    var stat = $('wan-static-fields');
    if (dhcp) dhcp.style.display = mode === 'dhcp' ? '' : 'none';
    if (stat) stat.style.display = mode === 'static' ? '' : 'none';
  }

  function renderWanConfig(data) {
    if (!data || data.error) return;
    var config = data.config || {};
    var proto = config.proto || 'dhcp';
    var selector = $('wan-proto');
    if (selector) {
      selector.value = proto;
      setWanMode(selector.value);
    }
    if ($('wan-hostname')) $('wan-hostname').value = config.hostname || '';
    if ($('wan-ipaddr')) $('wan-ipaddr').value = config.ipaddr || '';
    if ($('wan-netmask')) $('wan-netmask').value = config.netmask || '';
    if ($('wan-gateway')) $('wan-gateway').value = config.gateway || '';
    if ($('wan-static-dns')) $('wan-static-dns').value = proto === 'static' ? (config.dns || '') : '';
    renderWanRuntime(data.runtime || {});
    var pending = !!data.pending;
    var pendingCard = $('wan-pending-card');
    var applyButton = $('wan-apply-btn');
    if (pendingCard) pendingCard.style.display = pending ? '' : 'none';
    if (applyButton) applyButton.disabled = pending;
    if (pending) {
      wanPollDeadline = Number(data.deadline || 0);
      var remaining = wanPollDeadline ? Math.max(0, wanPollDeadline - Math.floor(Date.now() / 1000)) : 0;
      setText('wan-pending-copy', remaining ?
        'Verify the Internet connection, then keep this configuration within ' + remaining + ' seconds.' :
        'Verify the Internet connection, then keep or restore the configuration.');
      if (!wanPollTimer) wanPollTimer = setInterval(loadWanConfig, 2000);
    } else if (wanPollTimer) {
      clearInterval(wanPollTimer);
      wanPollTimer = null;
      wanPollDeadline = 0;
    }
  }

  function loadWanConfig() {
    xhr('GET', API + '/system/wan', null, function (err, data) {
      if (err) {
        setWanStatus('WAN status request interrupted.', true);
        return;
      }
      if (!data || data.error) {
        setWanStatus((data && (data.message || data.error)) || 'Unable to read WAN configuration.', true);
        return;
      }
      renderWanConfig(data);
    });
  }

  function wanFormPayload() {
    return {
      proto: $('wan-proto') ? $('wan-proto').value : 'dhcp',
      hostname: $('wan-hostname') ? $('wan-hostname').value : '',
      ipaddr: $('wan-ipaddr') ? $('wan-ipaddr').value : '',
      netmask: $('wan-netmask') ? $('wan-netmask').value : '',
      gateway: $('wan-gateway') ? $('wan-gateway').value : '',
      dns: $('wan-static-dns') ? $('wan-static-dns').value : ''
    };
  }

  if ($('wan-proto')) $('wan-proto').addEventListener('change', function () {
    setWanMode(this.value);
  });
  if ($('wan-refresh-btn')) $('wan-refresh-btn').addEventListener('click', loadWanConfig);
  if ($('wan-test-btn')) $('wan-test-btn').addEventListener('click', function () {
    var btn = this;
    setLoading(btn, true, 'Testing...');
    xhr('GET', API + '/system/wan/test', null, function (err, data) {
      setLoading(btn, false);
      if (err || !data || data.error) {
        setWanStatus((data && (data.message || data.error)) || 'WAN test failed.', true);
        return;
      }
      renderWanRuntime(data.runtime || {});
      setWanStatus(data.online ? 'WAN is connected.' : 'WAN is offline.', !data.online);
    });
  });
  if ($('wan-apply-btn')) $('wan-apply-btn').addEventListener('click', function () {
    if (!window.confirm('Apply this WAN connection? Internet may disconnect briefly.')) return;
    var btn = this;
    setLoading(btn, true, 'Applying...');
    setWanStatus('Saving WAN configuration...');
    xhr('POST', API + '/system/wan', wanFormPayload(), function (err, data) {
      setLoading(btn, false);
      if (err) {
        setWanStatus('Request interrupted. Check WAN status; the safety timer is still protecting the previous configuration.', true);
        loadWanConfig();
        return;
      }
      if (!data || data.error) {
        setWanStatus((data && (data.message || data.error)) || 'WAN configuration was rejected.', true);
        return;
      }
      setWanStatus('Applied. Verify the connection before confirming.');
      loadWanConfig();
    });
  });
  if ($('wan-confirm-btn')) $('wan-confirm-btn').addEventListener('click', function () {
    var btn = this;
    setLoading(btn, true, 'Keeping...');
    xhr('POST', API + '/system/wan/confirm', {}, function (err, data) {
      setLoading(btn, false);
      if (err || !data || data.error) {
        setWanStatus((data && (data.message || data.error)) || 'The WAN configuration was not confirmed.', true);
        return;
      }
      setWanStatus('WAN configuration kept.');
      loadWanConfig();
    });
  });
  if ($('wan-rollback-btn')) $('wan-rollback-btn').addEventListener('click', function () {
    if (!window.confirm('Restore the previous WAN configuration now?')) return;
    var btn = this;
    setLoading(btn, true, 'Restoring...');
    xhr('POST', API + '/system/wan/rollback', {}, function (err, data) {
      setLoading(btn, false);
      if (err || !data || data.error) {
        setWanStatus((data && (data.message || data.error)) || 'The previous WAN configuration could not be restored.', true);
        return;
      }
      setWanStatus('Previous WAN configuration restored.');
      loadWanConfig();
    });
  });

  if ($('save-wifi-btn')) {
    $('save-wifi-btn').addEventListener('click', function () {
      if (!window.confirm('Save the new WiFi names? Connected WiFi devices will disconnect briefly.')) return;
      var btn = this;
      var status = $('wifi-save-status');
      setLoading(btn, true);
      if (status) status.textContent = 'Saving...';
      xhr('POST', API + '/system/wifi', {
        ssid_2g: $('wifi-ssid-2g') && !$('wifi-ssid-2g').disabled ? $('wifi-ssid-2g').value : '',
        ssid_5g: $('wifi-ssid-5g') && !$('wifi-ssid-5g').disabled ? $('wifi-ssid-5g').value : ''
      }, function (err, data) {
        setLoading(btn, false);
        if (err) {
          if (status) status.textContent = 'Connection interrupted. Check the WiFi names and reconnect.';
          return;
        }
        if (!data || data.error) {
          if (status) status.textContent = (data && (data.message || data.error)) || 'Unable to save WiFi names.';
          return;
        }
        if (data.reconnect_required) {
          if (status) status.textContent = 'Saved. Reconnect using the new WiFi name.';
          showToast('WiFi names saved. Reconnect to the selected network.');
        } else if (status) {
          status.textContent = 'No changes needed.';
        }
      });
    });
  }

  $('save-settings-btn').addEventListener('click', function () {
    var btn = this; setLoading(btn, true);
    var settings = {
      business_name: $('set-business-name').value,
      portal_name: $('set-portal-name').value,
      portal_footer_text: $('set-portal-footer-text').value,
      portal_footer_link: $('set-portal-footer-link').value,
      portal_show_rates: $('set-show-rates').checked ? '1' : '0',
      portal_show_voucher: $('set-show-voucher').checked ? '1' : '0',
      portal_show_coin: $('set-show-coin').checked ? '1' : '0',
      portal_hide_device_info: $('set-hide-device-info').value,
      portal_rates: $('set-rates').value,
      coin_min_per_php: $('set-flat-rate').value,
      coinslot_timeout_seconds: $('set-coin-timeout').value,
      coinslot_busy_lock: $('set-busy-lock').value,
      coinslot_max_empty_opens: $('set-max-empty').value,
      coinslot_empty_open_cooldown_seconds: $('set-empty-cooldown').value,
      pause_penalty_minutes: $('set-pause-penalty').value,
      auto_pause_on_disconnect: $('set-auto-pause').value,
      auto_resume_on_reconnect: $('set-auto-resume').value,
      bw_mode: $('bw-device-enabled') ? $('bw-device-enabled').value : 'off',
      bw_per_client_down_kbps: $('bw-per-client-down').value,
      bw_per_client_up_kbps: $('bw-per-client-up').value,
      bw_total_down_kbps: $('bw-shared-down').value,
      bw_total_up_kbps: $('bw-shared-up').value,
      bw_exempt_macs: $('bw-exempt-macs').value,
      free_time_enabled: $('set-free-enabled').value,
      free_time_minutes: $('set-free-minutes').value,
      free_time_daily_limit: $('set-free-limit').value
    };
    if (sqmAvailable) {
      settings.sqm_enabled = $('set-sqm-enabled').value;
      settings.sqm_download_kbps = $('sqm-download').value;
      settings.sqm_upload_kbps = $('sqm-upload').value;
      settings.sqm_linklayer = $('sqm-linklayer').value;
      settings.sqm_overhead = $('sqm-overhead').value;
      settings.sqm_host_fairness = $('sqm-host-fairness').value;
    }
    xhr('POST', API + '/settings', settings, function (err, data) {
      setLoading(btn, false);
      if (err || !data || data.error) { showToast('Failed to save: ' + ((data && (data.message || data.error)) || 'error'), 'error'); return; }
      applyAdminBranding(settings.business_name);
      showToast('Settings saved! ✓');
    });
  });

  if ($('save-rates-btn')) {
    $('save-rates-btn').addEventListener('click', function () {
      var btn = this;
      var status = $('rates-save-status');
      syncRateTextarea();
      setLoading(btn, true);
      if (status) status.textContent = 'Saving...';
      xhr('POST', API + '/rates', {
        rates: $('set-rates').value,
        coin_min_per_php: $('set-flat-rate').value
      }, function (err, data) {
        setLoading(btn, false);
        if (err || !data || data.error) {
          if (status) status.textContent = 'Unable to save rates.';
          showToast((data && (data.message || data.error)) || 'Failed to save WiFi rates.', 'error');
          return;
        }
        if (status) status.textContent = '✓ Rates saved';
        showToast('WiFi rates saved! ✓');
        setTimeout(function () { if (status) status.textContent = ''; }, 4000);
      });
    });
  }

  // ── System ──────────────────────────────────────────────────────────────
  // ── Gaming Priority ───────────────────────────────────────────────────────
  var gamingRules = [];
  var gamingEditingIndex = -1;
  var gamingSqmEnabled = false;
  var gamingPriorityLoading = false;
  var gamingPrioritySaving = false;
  var gamingMessageTimer = null;

  function gamingMessage(message, error) {
    var el = $('gp-toast');
    if (!el) return;
    el.textContent = message;
    el.style.display = 'block';
    el.style.background = error ? '#fff1f2' : '#f0fdf4';
    el.style.borderColor = error ? '#fecaca' : '#bbf7d0';
    el.style.color = error ? '#b91c1c' : '#15803d';
    if (gamingMessageTimer) clearTimeout(gamingMessageTimer);
    gamingMessageTimer = setTimeout(function () {
      el.style.display = 'none';
    }, 2600);
  }

  function syncGamingToggle() {
    var toggle = $('gp-toggle');
    if (!toggle) return;
    var enabled = !!toggle.checked;
    setText('gp-toggle-text', enabled ? 'Enabled' : 'Disabled');
    setText('gp-service-status', enabled ? (gamingSqmEnabled ? 'Enabled' : 'SQM off') : 'Disabled');
  }

  function renderGamingRules() {
    var body = $('gp-rules-body');
    var empty = $('gp-empty');
    if (!body || !empty) return;
    body.innerHTML = '';
    empty.style.display = gamingRules.length ? 'none' : 'block';

    for (var i = 0; i < gamingRules.length; i++) {
      var rule = gamingRules[i] || {};
      var tr = document.createElement('tr');
      var nameCell = document.createElement('td');
      var name = document.createElement('strong');
      name.textContent = rule.name || '';
      nameCell.appendChild(name);
      tr.appendChild(nameCell);

      var protocolCell = document.createElement('td');
      var protocol = document.createElement('span');
      protocol.className = 'gp-badge gp-proto';
      protocol.textContent = rule.protocol || '';
      protocolCell.appendChild(protocol);
      tr.appendChild(protocolCell);

      var rangeCell = document.createElement('td');
      rangeCell.textContent = Number(rule.startPort) === Number(rule.endPort) ?
        String(rule.startPort) : String(rule.startPort) + '-' + String(rule.endPort);
      tr.appendChild(rangeCell);

      var priorityCell = document.createElement('td');
      var priority = document.createElement('span');
      priority.className = 'gp-badge ' +
        (rule.priority === 'High' ? 'gp-high' :
          rule.priority === 'Medium' ? 'gp-medium' : 'gp-low');
      priority.textContent = rule.priority || '';
      priorityCell.appendChild(priority);
      tr.appendChild(priorityCell);

      var actionsCell = document.createElement('td');
      var actions = document.createElement('div');
      actions.className = 'gp-actions';
      var edit = document.createElement('button');
      edit.type = 'button';
      edit.className = 'gp-action';
      edit.textContent = 'Edit';
      edit.setAttribute('data-gp-edit', String(i));
      var del = document.createElement('button');
      del.type = 'button';
      del.className = 'gp-action gp-delete';
      del.textContent = 'Delete';
      del.setAttribute('data-gp-delete', String(i));
      actions.appendChild(edit);
      actions.appendChild(del);
      actionsCell.appendChild(actions);
      tr.appendChild(actionsCell);
      body.appendChild(tr);
    }

    setText('gp-rule-count', String(gamingRules.length));
    var high = 0;
    for (var j = 0; j < gamingRules.length; j++) {
      if (gamingRules[j].priority === 'High') high++;
    }
    setText('gp-high-count', String(high));
  }

  function resetGamingForm() {
    if ($('gp-game-name')) $('gp-game-name').value = '';
    if ($('gp-start-port')) $('gp-start-port').value = '';
    if ($('gp-end-port')) $('gp-end-port').value = '';
    if ($('gp-protocol')) $('gp-protocol').value = 'UDP';
    if ($('gp-priority')) $('gp-priority').value = 'High';
    gamingEditingIndex = -1;
    if ($('gp-add-btn')) $('gp-add-btn').textContent = '+ Add Rule';
  }

  function readGamingRule() {
    var name = $('gp-game-name').value.replace(/^\s+|\s+$/g, '');
    var start = Number($('gp-start-port').value);
    var end = Number($('gp-end-port').value);
    if (!name) {
      gamingMessage('Enter a game or application name.', true);
      $('gp-game-name').focus();
      return null;
    }
    if (!isFinite(start) || Math.floor(start) !== start || start < 1 || start > 65535) {
      gamingMessage('Invalid start port.', true);
      $('gp-start-port').focus();
      return null;
    }
    if (!isFinite(end) || Math.floor(end) !== end || end < 1 || end > 65535) {
      gamingMessage('Invalid end port.', true);
      $('gp-end-port').focus();
      return null;
    }
    if (end < start) {
      gamingMessage('End port cannot be lower than start port.', true);
      $('gp-end-port').focus();
      return null;
    }
    return {
      name: name,
      protocol: $('gp-protocol').value,
      startPort: start,
      endPort: end,
      priority: $('gp-priority').value
    };
  }

  function loadGamingPriority() {
    if (!sqmAvailable) return;
    if (gamingPriorityLoading) return;
    gamingPriorityLoading = true;
    xhr('GET', API + '/gaming-priority', null, function (err, data) {
      gamingPriorityLoading = false;
      if (err || !data || data.error || !Array.isArray(data.rules)) {
        gamingMessage((data && (data.message || data.error)) ||
          'Unable to load Gaming Priority configuration.', true);
        return;
      }
      gamingRules = data.rules;
      gamingSqmEnabled = data.sqm_enabled === true;
      $('gp-toggle').checked = data.enabled !== false;
      syncGamingToggle();
      renderGamingRules();
    });
  }

  if ($('gp-toggle')) {
    $('gp-toggle').addEventListener('change', function () {
      syncGamingToggle();
      gamingMessage('Unsaved change. Click Save Configuration.');
    });
  }

  if ($('gp-add-btn')) {
    $('gp-add-btn').addEventListener('click', function () {
      var rule = readGamingRule();
      if (!rule) return;
      if (gamingEditingIndex >= 0) {
        gamingRules[gamingEditingIndex] = rule;
        gamingMessage('Rule updated locally. Save Configuration to apply it.');
      } else {
        gamingRules.push(rule);
        gamingMessage('Rule added locally. Save Configuration to apply it.');
      }
      resetGamingForm();
      renderGamingRules();
    });
  }

  if ($('gp-rules-body')) {
    $('gp-rules-body').addEventListener('click', function (event) {
      var target = event.target;
      while (target && target !== this &&
          !target.getAttribute('data-gp-edit') &&
          !target.getAttribute('data-gp-delete')) {
        target = target.parentNode;
      }
      if (!target || target === this) return;
      var editIndex = target.getAttribute('data-gp-edit');
      var deleteIndex = target.getAttribute('data-gp-delete');
      if (editIndex !== null) {
        var editRule = gamingRules[Number(editIndex)];
        if (!editRule) return;
        $('gp-game-name').value = editRule.name;
        $('gp-protocol').value = editRule.protocol;
        $('gp-start-port').value = editRule.startPort;
        $('gp-end-port').value = editRule.endPort;
        $('gp-priority').value = editRule.priority;
        gamingEditingIndex = Number(editIndex);
        $('gp-add-btn').textContent = 'Update Rule';
        $('gp-game-name').focus();
        return;
      }
      if (deleteIndex !== null) {
        var deleteAt = Number(deleteIndex);
        var deleteRule = gamingRules[deleteAt];
        if (!deleteRule || !window.confirm('Delete "' + deleteRule.name + '" rule?')) return;
        gamingRules.splice(deleteAt, 1);
        resetGamingForm();
        renderGamingRules();
        gamingMessage('Rule removed locally. Save Configuration to apply it.');
      }
    });
  }

  if ($('gp-save-btn')) {
    $('gp-save-btn').addEventListener('click', function () {
      if (gamingPrioritySaving) return;
      var btn = this;
      gamingPrioritySaving = true;
      setLoading(btn, true);
      xhr('POST', API + '/gaming-priority', {
        enabled: !!$('gp-toggle').checked,
        rules: gamingRules
      }, function (err, data) {
        gamingPrioritySaving = false;
        setLoading(btn, false);
        if (err || !data || data.error) {
          gamingMessage((data && (data.message || data.error)) ||
            'Unable to save Gaming Priority configuration.', true);
          return;
        }
        if (Array.isArray(data.rules)) gamingRules = data.rules;
        renderGamingRules();
        syncGamingToggle();
        gamingMessage('Gaming Priority configuration applied.');
      });
    });
  }
 function setManualUpdateMessage(text, type) {
    var el = $('manual-update-message');
    if (!el) return;
    el.textContent = text || '';
    el.style.color = type === 'error' ? '#f0883e' : 'var(--text2)';
  }

  function renderLicense(data) {
    if (!data) return;
    var status = $('license-status');
    if (status && data.license_status) {
      var licenseStatus = data.license_status;
      status.textContent = licenseStatus === 'unknown' ? 'Checking license...' : licenseStatus;
      status.style.color = licenseStatus === 'active' ? '#7ee787' : licenseStatus === 'unknown' ? '#58a6ff' : '#f0883e';
    }
    var used = $('license-used');
    if (used) used.textContent = data.license_key_masked || 'Not configured';
    var key = $('license-key');
    if (key) key.value = '';
  }

  function loadLicense() {
    xhr('GET', API + '/system/info', null, function (err, data) {
      if (err || !data) return;
      renderLicense(data);
    });
  }

  function loadSystem() {
    xhr('GET', API + '/system/info', null, function (err, data) {
      if (err || !data) return;
      renderSystemInfo(data);
      setText('sys-firmware', data.fw_version || data.firmware || '--');
      setText('sys-build', data.build_commit || '--');
      setText('sys-kernel', data.kernel || '--');
      setText('sys-flash', data.disk_used_mb !== undefined ? data.disk_used_mb + '/' + data.disk_total_mb + 'MB' : '--');
      renderLicense(data);
      // Trial banner
      var trialBanner = $('trial-banner');
      if (trialBanner) {
        var trialExpiresAt = epochSeconds(data.trial_expires_at);
        var expiredLicense = data.license_status === 'expired' || data.license_status === 'trial_expired';
        if (expiredLicense) {
          trialBanner.style.display = 'flex';
          trialBanner.style.background = 'linear-gradient(90deg,#7f1d1d,#991b1b)';
          trialBanner.style.borderColor = '#dc2626';
          trialBanner.querySelector('strong').textContent = 'TRIAL EXPIRED';
          trialBanner.querySelector('strong').style.color = '#fca5a5';
          trialBanner.querySelector('p').textContent = 'Portal is locked. Activate a license key to restore service.';
          trialBanner.querySelector('p').style.color = '#fca5a5';
          $('trial-countdown').textContent = 'EXPIRED';
          $('trial-countdown').style.color = '#f85149';
        } else if (data.license_status === 'trial' && trialExpiresAt) {
          var now = Math.floor(Date.now() / 1000);
          var remaining = trialExpiresAt - now;
          trialBanner.style.display = 'flex';
          if (remaining <= 0) {
            // Expired state
            trialBanner.style.background = 'linear-gradient(90deg,#7f1d1d,#991b1b)';
            trialBanner.style.borderColor = '#dc2626';
            trialBanner.querySelector('strong').textContent = 'TRIAL EXPIRED';
            trialBanner.querySelector('strong').style.color = '#fca5a5';
            trialBanner.querySelector('p').textContent = 'Portal is locked. Activate a license key to restore service.';
            trialBanner.querySelector('p').style.color = '#fca5a5';
            $('trial-countdown').textContent = 'EXPIRED';
            $('trial-countdown').style.color = '#f85149';
          } else {
            _startTrialCountdown(trialExpiresAt);
          }
        } else {
          trialBanner.style.display = 'none';
        }
      }
    });
    xhr('GET', API + '/reboot-schedule', null, function (err, data) {
      if (err || !data || data.error) return;
      $('set-reboot-enabled').value = data.enabled ? '1' : '0';
      $('set-reboot-time').value = data.time || '03:00';
      $('set-reboot-days').value = data.days || 'daily';
    });
  }

  // ── OTA Firmware Update ────────────────────────────────────────────
  var _otaManifest = null;
  var otaCheckBtn = $('ota-check-btn');
  if (otaCheckBtn) otaCheckBtn.addEventListener('click', function () {
    var btn = this;
    setLoading(btn, true);
    $('ota-status').textContent = 'Checking...';
    $('ota-status').style.color = '';
    xhr('GET', API + '/system/check-update', null, function (err, data) {
      setLoading(btn, false);
      if (err || !data || data.error) {
        $('ota-status').textContent = (data && data.error) || 'Check failed';
        $('ota-status').style.color = '#f0883e';
        return;
      }
      $('ota-latest-ver').textContent = 'v' + data.version;
      _otaManifest = data;
      if (data.update_available) {
        $('ota-status').textContent = 'Update available!';
        $('ota-status').style.color = '#7ee787';
        $('ota-update-btn').style.display = '';
      } else {
        $('ota-status').textContent = 'Up to date';
        $('ota-status').style.color = '#7ee787';
        $('ota-update-btn').style.display = 'none';
      }
      if (data.notes) {
        $('ota-notes').textContent = data.notes;
        $('ota-notes').style.display = '';
      } else {
        $('ota-notes').style.display = 'none';
      }
    });
  });
  var otaUpdateBtn = $('ota-update-btn');
  if (otaUpdateBtn) otaUpdateBtn.addEventListener('click', function () {
    if (!_otaManifest || !_otaManifest.update_available) {
      showToast('No update available. Check for updates first.', 'error');
      return;
    }
    if (!confirm('Apply firmware update v' + _otaManifest.version + '?\n\nYour settings will be preserved. The router will reboot after update.')) return;
    var btn = this;
    setLoading(btn, true);
    $('ota-status').textContent = 'Downloading & verifying...';
    $('ota-progress').style.display = '';
    $('ota-progress-bar').style.width = '20%';
    $('ota-progress-text').textContent = 'Downloading firmware...';
    // Only send version — server fetches the URL and token itself (security)
    xhr('POST', API + '/system/update', { version: _otaManifest.version }, function (err, data) {
      setLoading(btn, false);
      if (err || !data || data.error) {
        $('ota-status').textContent = (data && data.error) || 'Update failed';
        $('ota-status').style.color = '#f0883e';
        $('ota-progress').style.display = 'none';
        return;
      }
      $('ota-progress-bar').style.width = '100%';
      $('ota-progress-text').textContent = 'Applying update... Settings preserved. Router will reboot.';
      $('ota-status').textContent = 'Rebooting...';
      // Show reboot overlay after a moment
      setTimeout(function () {
        var overlay = $('reboot-overlay');
        if (overlay) overlay.style.display = 'flex';
      }, 2000);
    }, OTA_UPDATE_TIMEOUT_MS);
  });

  var manualUpdateBtn = $('manual-update-btn');
  if (manualUpdateBtn) manualUpdateBtn.addEventListener('click', function () {
    var fileInput = $('manual-firmware-file');
    var modeInput = $('manual-firmware-mode');
    var progress = $('manual-update-progress');
    var progressBar = $('manual-update-progress-bar');
    if (!fileInput || !fileInput.files || !fileInput.files[0]) {
      setManualUpdateMessage('Choose a firmware .bin file first.', 'error');
      showToast('Choose a firmware .bin file first.', 'error');
      return;
    }
    var file = fileInput.files[0];
    var mode = modeInput ? modeInput.value : 'preserve';
    if (!/\.bin$/i.test(file.name || '')) {
      setManualUpdateMessage('Firmware file must be a .bin file.', 'error');
      showToast('Firmware file must be a .bin file.', 'error');
      return;
    }
    if (file.size < 1048576) {
      setManualUpdateMessage('Firmware file is too small.', 'error');
      showToast('Firmware file is too small.', 'error');
      return;
    }
    if (file.size > 16 * 1024 * 1024) {
      setManualUpdateMessage('Firmware file is too large.', 'error');
      showToast('Firmware file is too large.', 'error');
      return;
    }
    var prompt = mode === 'check'
      ? 'Download and validate this firmware only? No flash, settings change, or reboot will occur.'
      : mode === 'preserve'
        ? 'Install this firmware and preserve settings? The router will reboot.'
        : 'Fresh install this firmware? Current settings and data will be erased.';
    if (!confirm(prompt)) return;

    var btn = this;
    setLoading(btn, true, 'Uploading...');
    setManualUpdateMessage('Uploading firmware...');
    if (progress) progress.style.display = '';
    if (progressBar) progressBar.style.width = '3%';

    var safeMode = mode;
    var uploadId = Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10);
    var chunkSize = 256 * 1024;

    function failManualUpdate(message) {
      setLoading(btn, false);
      setManualUpdateMessage(message, 'error');
      showToast(message, 'error');
      if (progress) progress.style.display = 'none';
    }

    function finishManualUpdate(data) {
      setLoading(btn, false);
      if (progressBar) progressBar.style.width = '100%';
      setManualUpdateMessage(data.message || (mode === 'check'
        ? 'Firmware downloaded and validated. No flash was performed.'
        : 'Firmware update started. Router will reboot.'));
      showToast(mode === 'check' ? 'Firmware validation passed; no flash performed' : 'Firmware update started');
      if (mode !== 'check') {
        setTimeout(function () {
          var overlay = $('reboot-overlay');
          if (overlay) overlay.style.display = 'flex';
        }, 1500);
      }
    }

    function sendFirmwareChunk(offset) {
      var end = Math.min(offset + chunkSize, file.size);
      var chunk = file.slice(offset, end);
      var finalChunk = end >= file.size ? '1' : '0';
      var uploadUrl = API + '/system/manual-update/chunk'
        + '?mode=' + encodeURIComponent(safeMode)
        + '&upload_id=' + encodeURIComponent(uploadId)
        + '&offset=' + encodeURIComponent(String(offset))
        + '&total=' + encodeURIComponent(String(file.size))
        + '&final=' + finalChunk;
      var req = new XMLHttpRequest();
      req.open('POST', uploadUrl, true);
      req.withCredentials = true;
      req.setRequestHeader('Content-Type', 'application/octet-stream');
      req.setRequestHeader('X-Kemofi-Firmware-Name', file.name || 'firmware.bin');
      req.timeout = 180000;
      if (req.upload && progressBar) {
        req.upload.onprogress = function (event) {
          if (!event.lengthComputable) return;
          var loaded = offset + event.loaded;
          var pct = Math.max(3, Math.min(90, Math.round((loaded / file.size) * 90)));
          progressBar.style.width = pct + '%';
        };
      }
      req.onload = function () {
        var data = null;
        try { data = JSON.parse(req.responseText || '{}'); } catch (e) {}
        if (req.status !== 200 || !data || data.error) {
          failManualUpdate((data && (data.message || data.error)) || 'Firmware update failed');
          return;
        }
        if (data.status === 'chunk_received') {
          var received = Number(data.received || end);
          var pct = Math.max(3, Math.min(90, Math.round((received / file.size) * 90)));
          if (progressBar) progressBar.style.width = pct + '%';
          setManualUpdateMessage('Uploading firmware... ' + Math.round((received / file.size) * 100) + '%');
          sendFirmwareChunk(received);
          return;
        }
        finishManualUpdate(data);
      };
      req.onerror = req.ontimeout = function () {
        failManualUpdate('Firmware upload failed');
      };
      req.send(chunk);
    }

    sendFirmwareChunk(0);
  });

  var urlUpdateBtn = $('url-update-btn');
  if (urlUpdateBtn) urlUpdateBtn.addEventListener('click', function () {
    if (this._firmwareUpdateBusy) return;
    var urlInput = $('firmware-url');
    var modeInput = $('url-firmware-mode');
    var url = (urlInput && urlInput.value || '').trim();
    var mode = (modeInput && modeInput.value || 'preserve');
    var message = $('url-update-message');
    if (!/^https:\/\/[^\s]+$/i.test(url)) {
      if (message) message.textContent = 'Enter a valid HTTPS firmware or supported share URL.';
      showToast('Enter a valid HTTPS firmware or supported share URL.', 'error');
      return;
    }
    var checkOnly = mode === 'check';
    if (!confirm(checkOnly
      ? 'Download and validate this firmware only? No flash, settings change, or reboot will occur.'
      : mode === 'preserve'
        ? 'Download and install this firmware while preserving settings?'
        : 'Fresh install this firmware and erase settings?')) return;
    var btn = this;
    btn._firmwareUpdateBusy = true;
    setLoading(btn, true, checkOnly ? 'Validating...' : 'Downloading...');
    if (urlInput) urlInput.disabled = true;
    if (modeInput) modeInput.disabled = true;
    setFirmwareProgress('url-update', 35, checkOnly
      ? 'Downloading and validating firmware. Keep power connected.'
      : 'Downloading and validating firmware. Keep power connected during the update.', true);
    if (message) message.textContent = checkOnly
      ? 'Downloading and validating firmware...'
      : 'Downloading, validating, and preparing the update...';

    function restoreUrlControls() {
      btn._firmwareUpdateBusy = false;
      setLoading(btn, false);
      if (urlInput) urlInput.disabled = false;
      if (modeInput) modeInput.disabled = false;
    }

    xhr('POST', API + '/system/url-update', {url:url, mode:mode}, function (err, data) {
      restoreUrlControls();
      if (err || !data || data.error) {
        var failure = (data && (data.message || data.error)) || 'Firmware download failed.';
        if (message) message.textContent = failure;
        hideFirmwareProgress('url-update');
        showToast(failure, 'error');
        return;
      }
      var successMessage = data.message || (checkOnly
        ? 'Firmware downloaded and validated. No flash was performed.'
        : 'Firmware update started. Router will reboot.');
      setFirmwareProgress('url-update', 100, checkOnly
        ? 'Download and validation complete. No flash was performed.'
        : 'Validated. Applying update... Keep power connected; router will reboot.', false);
      if (message) message.textContent = successMessage;
      if (!checkOnly) setTimeout(function () { var overlay = $('reboot-overlay'); if (overlay) overlay.style.display = 'flex'; }, 1500);
    }, 180000);
  });

  var remoteReconnectBtn = $('remote-reconnect-btn');
  if (remoteReconnectBtn) remoteReconnectBtn.addEventListener('click', function () {
    var button = this;
    setLoading(button, true);
    xhr('POST', API + '/remote/reconnect', {}, function (err, data) {
      setLoading(button, false);
      if (err || !data || data.status === 'error') {
        showToast((data && data.message) || 'Remote Access reconnect failed', 'error');
        return;
      }
      showToast(data.message || 'Remote Access reconnect requested');
      loadRemoteAccess();
    });
  });

  var remoteDiagnosticsBtn = $('remote-diagnostics-btn');
  if (remoteDiagnosticsBtn) remoteDiagnosticsBtn.addEventListener('click', function () {
    var button = this;
    var output = $('remote-diagnostics');
    setLoading(button, true);
    if (output) output.textContent = 'Running safe diagnostics...';
    xhr('POST', API + '/remote/diagnostics', {}, function (err, data) {
      setLoading(button, false);
      if (err || !data || data.status === 'error') {
        if (output) output.textContent = (data && data.message) || 'Diagnostics failed';
        showToast((data && data.message) || 'Remote Access diagnostics failed', 'error');
        return;
      }
      renderRemoteDiagnostics(data);
    });
  });

  // Change password
  $('change-pw-btn').addEventListener('click', function () {
    var btn = this;
    var currentPw = $('current-password').value;
    var pw = $('new-password').value;
    var confirm = $('confirm-password').value;
    if (!currentPw) { showToast('Enter current password', 'error'); return; }
    if (!pw || pw.length < 4) { showToast('Password too short', 'error'); return; }
    if (pw !== confirm) { showToast('Passwords do not match', 'error'); return; }
    setLoading(btn, true);
    xhr('POST', API + '/password', {new_password: pw, current_password: currentPw}, function (err, data) {
      setLoading(btn, false);
      if (err || !data || data.error) { showToast((data && data.error) || 'Failed', 'error'); return; }
      showToast('Password changed. Login again.');
      $('current-password').value = '';
      $('new-password').value = '';
      $('confirm-password').value = '';
      activeAdminTab = '';
      stopSessionsPolling();
      hide(app);
      show(loginScreen);
    });
  });

  // Reboot schedule
  $('save-reboot-btn').addEventListener('click', function () {
    var btn = this; setLoading(btn, true);
    xhr('POST', API + '/reboot-schedule', {
      enabled: $('set-reboot-enabled').value === '1',
      time: $('set-reboot-time').value,
      days: $('set-reboot-days').value
    }, function (err, data) {
      setLoading(btn, false);
      if (err || !data || data.error) { showToast('Failed', 'error'); return; }
      showToast('Reboot schedule saved! ✓');
    });
  });

  // Reboot / Shutdown
  $('reboot-btn').addEventListener('click', function () {
    if (!confirm('Reboot the router now?')) return;
    var overlay = $('reboot-overlay');
    overlay.style.display = 'flex';
    xhr('POST', API + '/system/reboot', null, function (err, data) {
      if (err || (data && data.error)) {
        overlay.style.display = 'none';
        showToast((data && data.error) || 'Reboot failed', 'error');
        return;
      }
      // Router is shutting down — start polling until it comes back
      var attempts = 0;
      var maxAttempts = 60; // 2 min max
      function pollOnline() {
        attempts++;
        if (attempts > maxAttempts) {
          $('reboot-overlay-msg').textContent = 'Router took too long to come back. Please refresh manually.';
          return;
        }
        var req = new XMLHttpRequest();
        req.open('GET', API + '/system/ping', true);
        req.timeout = 3000;
        req.onload = function () {
          if (req.status === 200 || req.status === 401) {
            // Router is back online — redirect to login
            overlay.style.display = 'none';
            window.location.href = '/';
          } else {
            setTimeout(pollOnline, 2000);
          }
        };
        req.onerror = req.ontimeout = function () { setTimeout(pollOnline, 2000); };
        req.send();
      }
      // Wait 5s for router to start shutting down before polling
      setTimeout(pollOnline, 5000);
    });
  });
  $('shutdown-btn').addEventListener('click', function () {
    if (!confirm('Shutdown the router? You will need physical access to power it back on.')) return;
    xhr('POST', API + '/system/shutdown', null, function () { showToast('Shutting down...'); });
  });

  // Backup
  if ($('backup-btn')) $('backup-btn').addEventListener('click', function () {
    xhr('GET', API + '/backup', null, function (err, data) {
      if (err || !data) { showToast('Backup failed', 'error'); return; }
      var blob = new Blob([JSON.stringify(data, null, 2)], {type: 'application/json'});
      var url = URL.createObjectURL(blob);
      var a = document.createElement('a');
      a.href = url; a.download = 'kemofi-backup-' + new Date().toISOString().slice(0, 10) + '.json';
      a.click(); URL.revokeObjectURL(url);
    });
  });

  // Restore
  if ($('restore-file')) $('restore-file').addEventListener('change', function (e) {
    var file = e.target.files[0];
    if (!file) return;
    if (!confirm('Restore from backup? This will overwrite current settings and data.')) return;
    var reader = new FileReader();
    reader.onload = function () {
      try {
        var data = JSON.parse(reader.result);
        xhr('POST', API + '/restore', data, function (err, res) {
          if (err || !res || res.error) { showToast('Restore failed', 'error'); return; }
          showToast('Restored! Reloading...');
          location.reload();
        });
      } catch (ex) { showToast('Invalid backup file', 'error'); }
    };
    reader.readAsText(file);
  });

  // License
  $('activate-license-btn').addEventListener('click', function () {
    var btn = this;
    var key = $('license-key').value.trim();
    if (!key) { showToast('Enter a license key', 'error'); return; }
    setLoading(btn, true);
    xhr('POST', API + '/activate-license', {license_key: key}, function (err, data) {
      setLoading(btn, false);
      if (err || !data || data.error) { showToast((data && data.message) || (data && data.error) || 'Activation failed', 'error'); return; }
      showToast(data.message || 'License activated! ✓');
      loadLicense();
    });
  });

  // ── Online portal updater ────────────────────────────────────────────
  window.applyPortalPackage = function () {
    var input = $('portal-package-file');
    if (!input || !input.files || !input.files[0]) {
      showToast('Select a KemoFi theme package first', 'error');
      return;
    }
    var file = input.files[0];
    if (file.size > 96 * 1024) {
      showToast('Theme package is too large (maximum 96KB)', 'error');
      return;
    }
    var reader = new FileReader();
    reader.onload = function () {
      var payload;
      try { payload = JSON.parse(reader.result); } catch (e) {
        showToast('Theme package is not valid JSON', 'error');
        return;
      }
      if (!payload || payload.schema !== 'kemofi-portal-theme') {
        showToast('Select a KemoFi portal theme package', 'error');
        return;
      }
      if (!window.confirm('Apply this portal update? Customer sessions stay online and the router will not flash or reboot.')) return;
      var button = $('apply-portal-package-btn');
      var status = $('portal-update-status');
      if (status) status.textContent = 'Applying...';
      setLoading(button, true, 'Applying...');
      xhr('POST', API + '/portal/update', payload, function (err, data) {
        setLoading(button, false);
        if (err || !data || data.error) {
          if (status) status.textContent = 'Update failed';
          showToast((data && (data.message || data.error)) || 'Portal update failed', 'error');
          return;
        }
        if (status) status.textContent = 'Applied without flash or reboot';
        showToast('Portal update applied successfully', 'success');
      }, 90000);
    };
    reader.onerror = function () { showToast('Could not read the theme package', 'error'); };
    reader.readAsText(file);
  };

  window.restorePortalStyle = function () {
    if (!window.confirm('Restore the firmware portal style? The uploaded presentation override will be removed.')) return;
    var button = $('restore-portal-style-btn');
    var status = $('portal-update-status');
    if (status) status.textContent = 'Restoring...';
    setLoading(button, true, 'Restoring...');
    xhr('POST', API + '/portal/update', {restore_defaults: true}, function (err, data) {
      setLoading(button, false);
      if (err || !data || data.error) {
        if (status) status.textContent = 'Restore failed';
        showToast((data && (data.message || data.error)) || 'Portal style restore failed', 'error');
        return;
      }
      if (status) status.textContent = 'Firmware portal style restored';
      showToast('Default portal style restored', 'success');
    });
  };

  // ── Asset Upload (multipart/form-data) ─────────────────────────────
  // Global function called by inline onclick in HTML
  window.uploadAsset = function (type, inputId) {
    var input = $(inputId);
    if (!input || !input.files || !input.files[0]) {
      showToast('Select a file first', 'error');
      return;
    }
    var file = input.files[0];
    // Size limits (match backend)
    var limits = { coin_sound: 819200, tick_sound: 204800, logo: 512000, hero: 512000 };
    var maxBytes = limits[type] || 512000;
    if (file.size > maxBytes) {
      showToast('File too large. Max: ' + Math.floor(maxBytes/1024) + 'KB', 'error');
      return;
    }
    var statusEl = $(type.replace('_','-') + '-status');
    if (statusEl) statusEl.textContent = 'Uploading...';

    var formData = new FormData();
    formData.append('type', type);
    formData.append('file', file);

    var xh = new XMLHttpRequest();
    xh.open('POST', API + '/upload', true);
    // Include auth cookie
    xh.withCredentials = true;
    // Get session token from cookie
    var token = document.cookie.replace(/(?:(?:^|.*;\s*)session\s*=\s*([^;]*).*$)|^.*$/, '$1');
    if (token) xh.setRequestHeader('Cookie', 'session=' + token);
    xh.onload = function () {
      try {
        var resp = JSON.parse(xh.responseText);
        if (xh.status === 200 && resp.ok) {
          showToast(type.replace('_',' ') + ' uploaded! (' + Math.floor(resp.size/1024) + 'KB)');
          if (statusEl) statusEl.textContent = '✓ ' + resp.file;
        } else {
          showToast(resp.message || resp.error || 'Upload failed', 'error');
          if (statusEl) statusEl.textContent = '';
        }
      } catch (e) {
        showToast('Upload failed', 'error');
        if (statusEl) statusEl.textContent = '';
      }
    };
    xh.onerror = function () {
      showToast('Upload failed (network error)', 'error');
      if (statusEl) statusEl.textContent = '';
    };
    xh.send(formData);
  };

  // ── Content Filtering Tab ─────────────────────────────────────────
  var filterDomains = [];

  function renderDomainList() {
    var list = $('domain-list');
    if (!list) return;
    list.innerHTML = '';
    if (filterDomains.length === 0) {
      list.innerHTML = '<div style="color:var(--text2);font-size:.85rem;padding:8px 0">No domains blocked yet.</div>';
      return;
    }
    filterDomains.forEach(function (domain, idx) {
      var row = document.createElement('div');
      row.style.cssText = 'display:flex;align-items:center;gap:8px;padding:6px 10px;background:var(--card-bg);border-radius:6px;border:1px solid var(--border)';
      var label = document.createElement('span');
      label.style.cssText = 'flex:1;font-family:monospace;font-size:.9rem;overflow-wrap:anywhere';
      label.textContent = domain;
      var remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'btn btn-sm btn-danger';
      remove.textContent = 'Remove';
      remove.addEventListener('click', function () {
        filterDomains.splice(idx, 1);
        renderDomainList();
      });
      row.appendChild(label);
      row.appendChild(remove);
      list.appendChild(row);
    });
  }

  function loadFiltering() {
    xhr('GET', API + '/settings', null, function (err, data) {
      if (err || !data) return;
      var d = data.settings || data;
      var enabled = d.site_blocking_enabled === '1' || d.site_blocking_enabled === true;
      var el = $('filter-enabled');
      if (el) el.checked = enabled;
      var sites = d.blocked_sites || '';
      filterDomains = sites.split('\n').map(function (s) { return s.trim(); }).filter(function (s) { return s !== ''; });
      renderDomainList();
    });
  }

  if ($('btn-add-domain')) {
    $('btn-add-domain').addEventListener('click', function () {
      show($('domain-add-row'));
      $('domain-input').focus();
    });
  }
  if ($('btn-cancel-domain')) {
    $('btn-cancel-domain').addEventListener('click', function () {
      hide($('domain-add-row'));
      $('domain-input').value = '';
    });
  }
  if ($('btn-confirm-domain')) {
    $('btn-confirm-domain').addEventListener('click', function () {
      var val = $('domain-input').value.trim().toLowerCase();
      if (!val) return;
      // Strip protocol/path if pasted as URL
      val = val.replace(/^https?:\/\//, '').replace(/\/.*$/, '');
      if (!/^[a-z0-9.-]+$/.test(val) || val.indexOf('.') === -1 || val.indexOf('..') !== -1) {
        showToast('Enter a valid domain such as example.com.', 'error');
        return;
      }
      if (filterDomains.indexOf(val) === -1) {
        filterDomains.push(val);
        renderDomainList();
      }
      hide($('domain-add-row'));
      $('domain-input').value = '';
    });
  }
  if ($('btn-save-filtering')) {
    $('btn-save-filtering').addEventListener('click', function () {
      var enabled = $('filter-enabled') && $('filter-enabled').checked ? '1' : '0';
      var sites = filterDomains.join('\n');
      var status = $('filter-save-status');
      if (status) status.textContent = 'Saving…';
      xhr('POST', API + '/settings', {
        site_blocking_enabled: enabled,
        blocked_sites: sites
      }, function (err, data) {
        if (err || !data || data.error) {
          if (status) status.textContent = (data && (data.message || data.error)) || 'Error saving';
          return;
        }
        if (status) status.textContent = '\u2713 Network rules applied';
        setTimeout(function () { if (status) status.textContent = ''; }, 4000);
      });
    });
  }

  // Load filtering data when settings tab opens
  var _origSwitchTab = switchTab;
  switchTab = function (tabName) {
    _origSwitchTab(tabName);
    if (tabName === 'settings') {
      loadFiltering();
      loadWifiConfig();
    }
  };

  // ── Mobile Hamburger Menu ──────────────────────────────────────────
  (function () {
    var sidebar = $('admin-sidebar');
    var backdrop = $('sidebar-backdrop');
    var menuBtn = $('mobile-menu-btn');
    if (!sidebar || !backdrop || !menuBtn) return;

    function openSidebar() {
      sidebar.classList.add('mobile-open');
      backdrop.classList.add('visible');
      document.body.style.overflow = 'hidden';
    }
    function closeSidebar() {
      sidebar.classList.remove('mobile-open');
      backdrop.classList.remove('visible');
      document.body.style.overflow = '';
    }

    menuBtn.addEventListener('click', openSidebar);
    backdrop.addEventListener('click', closeSidebar);

    // Close sidebar when a nav item is clicked on mobile
    var navItems = sidebar.querySelectorAll('.nav-item');
    for (var i = 0; i < navItems.length; i++) {
      navItems[i].addEventListener('click', function () {
        if (window.innerWidth <= 768) closeSidebar();
      });
    }
  }());

  // ── Trial Countdown Timer ─────────────────────────────────────────
  var _trialInterval = null;
  function _startTrialCountdown(expiresAt) {
    expiresAt = epochSeconds(expiresAt);
    if (!expiresAt) return;
    if (_trialInterval) clearInterval(_trialInterval);
    function update() {
      var now = Math.floor(Date.now() / 1000);
      var remaining = expiresAt - now;
      var el = $('trial-countdown');
      if (!el) return;
      if (remaining <= 0) {
        el.textContent = 'EXPIRED';
        el.style.color = '#f85149';
        if (_trialInterval) clearInterval(_trialInterval);
        return;
      }
      var h = Math.floor(remaining / 3600);
      var m = Math.floor((remaining % 3600) / 60);
      var s = remaining % 60;
      el.textContent = h + 'h ' + m + 'm ' + s + 's remaining';
    }
    update();
    _trialInterval = setInterval(update, 1000);
  }

})();
