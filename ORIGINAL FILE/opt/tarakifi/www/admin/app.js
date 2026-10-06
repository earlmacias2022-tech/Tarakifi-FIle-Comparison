/**
 * TarakiFi Admin Panel — OpenWrt
 * Pure ES5. No frameworks.
 */
(function () {
  var API = '/api/admin';
  var PORTAL_API = '/api/portal';
  var OTA_UPDATE_TIMEOUT_MS = 180000;
  // Detect remote access context (loaded in iframe via vendor platform)
  // Rewrite API base to route XHR through the remote proxy tunnel
  if (window.location.pathname.indexOf('/api/remote/') === 0) {
    var _m = window.location.pathname.match(/^\/api\/remote\/[^\/]+/);
    if (_m) {
      API = _m[0] + '/admin';
      PORTAL_API = _m[0] + '/portal';
    }
  }
  // Auth uses cookie (tarakifi_admin) set by server on login. No token header needed.

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
  function setLoading(btn, loading) {
    if (!btn) return;
    if (loading) {
      btn._origText = btn.innerHTML;
      btn.disabled = true;
      btn.innerHTML = '<span style="display:inline-flex;align-items:center;gap:6px"><svg style="animation:spin .7s linear infinite;width:14px;height:14px" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83"/></svg>Saving...</span>';
    } else {
      btn.disabled = false;
      btn.innerHTML = btn._origText || btn.innerHTML;
    }
  }

  function $(id) { return document.getElementById(id); }
  function show(el) { if (el) el.style.display = ''; }
  function hide(el) { if (el) el.style.display = 'none'; }

  window.togglePw = function (inputId, button) {
    var input = $(inputId);
    if (!input) return;
    var reveal = input.type === 'password';
    input.type = reveal ? 'text' : 'password';
    if (button) {
      button.setAttribute('aria-label', reveal ? 'Hide password' : 'Show password');
      button.setAttribute('aria-pressed', reveal ? 'true' : 'false');
    }
  };

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

  function safeAssetFilename(value) {
    value = String(value || '');
    return /^[A-Za-z0-9_.-]+$/.test(value) ? value : '';
  }

  function assetUrl(filename, version) {
    var safe = safeAssetFilename(filename);
    if (!safe) return '';
    return '/' + safe + (Number(version || 0) > 0 ? '?v=' + Number(version) : '');
  }

  function setImageSource(image, customUrl, fallbackUrl) {
    if (!image) return;
    var desired = customUrl || fallbackUrl;
    if (image.getAttribute('data-current-src') === desired) return;
    image.setAttribute('data-current-src', desired);
    image.setAttribute('data-fallback-used', customUrl ? '0' : '1');
    image.onload = function () { image.style.display = ''; };
    image.onerror = function () {
      if (image.getAttribute('data-fallback-used') !== '1') {
        image.setAttribute('data-fallback-used', '1');
        image.setAttribute('data-current-src', fallbackUrl);
        image.src = fallbackUrl;
      } else {
        image.style.display = 'none';
      }
    };
    image.src = desired;
  }

  function applyAdminMedia(files) {
    files = files || {};
    if (Object.prototype.hasOwnProperty.call(files, 'portal_logo_file')) {
      var logoUrl = assetUrl(files.portal_logo_file, files.portal_asset_version);
      var logos = document.querySelectorAll('[data-brand-logo]');
      for (var i = 0; i < logos.length; i++) setImageSource(logos[i], logoUrl, '/logo.png');
      var logoPreview = $('logo-upload-preview');
      if (logoPreview) {
        logoPreview.style.display = logoUrl ? 'block' : 'none';
        if (logoUrl) setImageSource(logoPreview, logoUrl, '/logo.png');
      }
    }
    if (Object.prototype.hasOwnProperty.call(files, 'portal_hero_file')) {
      var heroUrl = assetUrl(files.portal_hero_file, files.portal_asset_version);
      var heroPreview = $('hero-upload-preview');
      if (heroPreview) {
        heroPreview.style.display = heroUrl ? 'block' : 'none';
        if (heroUrl) setImageSource(heroPreview, heroUrl, '/hero.jpg');
      }
    }
  }

  function loadPublicMedia() {
    var req = new XMLHttpRequest();
    req.open('GET', PORTAL_API + '/status', true);
    req.timeout = 5000;
    req.onload = function () {
      if (req.status !== 200) return;
      try { applyAdminMedia(JSON.parse(req.responseText)); } catch (e) {}
    };
    req.onerror = req.ontimeout = function () {};
    req.send(null);
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

  function formatStorage(usedMb, totalMb, usedKb, totalKb) {
    var uKb = parseInt(usedKb, 10) || 0;
    var tKb = parseInt(totalKb, 10) || 0;
    var uMb = parseInt(usedMb, 10) || 0;
    var tMb = parseInt(totalMb, 10) || 0;
    if (tKb > 0 && tKb < 1024) return uKb + '/' + tKb + 'KB';
    if (tMb > 0) return uMb + '/' + tMb + 'MB';
    if (tKb > 0) return uKb + '/' + tKb + 'KB';
    return '--';
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

  function formatDateTime(value) {
    if (!value) return '--';
    var text = String(value);
    var date = /^\d+$/.test(text) ? new Date(Number(text) * 1000) : new Date(text);
    if (isNaN(date.getTime())) return '--';
    return date.toLocaleString();
  }

  function epochSeconds(value) {
    if (typeof value === 'number') return Math.floor(value);
    if (!value) return 0;
    var text = String(value).trim();
    if (/^\d+$/.test(text)) return Number(text);
    var ms = Date.parse(text);
    return isNaN(ms) ? 0 : Math.floor(ms / 1000);
  }

  // ── Tab Navigation ──────────────────────────────────────────────────────
  // Support both .nav-item (dashboard.html sidebar) and .tab (legacy index.html)
  var tabs = document.querySelectorAll('.nav-item[data-tab], .tab[data-tab]');
  var contents = document.querySelectorAll('.tab-content');
  var activeAdminTab = '';
  var dashboardPollTimer = null;
  var dashboardRequestActive = false;
  var DASHBOARD_POLL_MS = 10000;
  var cloudBackupConfigured = false;

  function switchTab(tabName) {
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
    // Refresh data
    if (tabName === 'dashboard') {
      startDashboardPolling();
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
    if (tabName === 'system') loadSystem();
    if (tabName === 'vendos') loadVendos();
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
  // The server sets a tarakifi_admin cookie on login. On refresh, the browser
  // sends it automatically. We just need to verify it's still valid.
  (function checkSession() {
    loadPublicMedia();
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
      var sys = data.system || {};
      if (!healthOnly) {
        $('stat-active').textContent = data.active_sessions || 0;
        $('stat-today-earnings').textContent = '\u20B1' + (data.today_earnings || 0);
        $('stat-total-earnings').textContent = '\u20B1' + (data.total_earnings || 0);
        $('stat-transactions').textContent = data.today_transactions || 0;
      }
      // Health
      if (sys.uptime_seconds) $('health-uptime').textContent = formatTime(sys.uptime_seconds);
      if (sys.ram_total_mb) {
        var ramPct = Math.round((sys.ram_used_mb / sys.ram_total_mb) * 100);
        $('health-ram').textContent = ramPct + '%';
        $('health-ram-detail').textContent = (sys.ram_available_mb || 0) + ' MB available';
        $('health-ram').classList.toggle('is-warning', sys.ram_available_mb < 8);
      }
      var zramTotal = sys.zram_total_mb || 0;
      var zramUsed = sys.zram_used_mb || 0;
      var zramPct = zramTotal ? Math.round((zramUsed / zramTotal) * 100) : 0;
      $('health-zram').textContent = zramTotal ? zramUsed + '/' + zramTotal + ' MB' : 'Off';
      $('health-zram-detail').textContent = zramTotal ? zramPct + '% used' : 'Not configured';
      $('health-zram').classList.toggle('is-warning', zramTotal > 0 && zramPct >= 75);
      $('health-flash').textContent = formatStorage(
        sys.disk_used_mb, sys.disk_total_mb, sys.disk_used_kb, sys.disk_total_kb
      );
      if (sys.load_avg) $('health-cpu').textContent = sys.load_avg;
      $('health-wifi').textContent = sys.wifi_clients || 0;
      $('health-wan').textContent = data.wan_online ? 'Online' : 'Offline';
      $('health-wan').style.color = data.wan_online ? '#7ee787' : '#f85149';
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
  function loadVendos() {
    xhr('GET', API + '/coin-nodes', null, function (err, data) {
      if (err || !data) return;
      var nodes = data.nodes || [];
      $('vendo-count').textContent = nodes.length;
      var addVendoBtn = $('btn-add-vendo');
      if (addVendoBtn) {
        addVendoBtn.disabled = nodes.length >= 1;
        addVendoBtn.title = nodes.length >= 1
          ? 'Unbind the current coinslot before adding another.'
          : 'Bind a NodeMCU coinslot';
      }
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
        var modeLabel = n.conn_mode === 'wired' ? '&#128279; Wired' : '&#128246; WiFi';
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
          '<td style="text-align:center">' + (n.total_coins || 0) + '</td>' +
          '<td>' + statusHtml + '</td>' +
          '<td>' + timeAgo(n.last_heartbeat) + '</td>' +
          '<td style="white-space:nowrap">' +
            '<button class="action-btn" onclick="renameVendo(\'' + n.node_id + '\')" title="Rename">Rename</button> ' +
            '<button class="action-btn danger" onclick="unbindVendo(\'' + n.node_id + '\')" title="Unbind this coinslot">Unbind</button>' +
          '</td>';
        tbody.appendChild(tr);
      }
    });
  }

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
  var bindTimerInterval = null;

  function openBindModal() {
    xhr('POST', API + '/coin-nodes/generate-bind', {}, function (err, data) {
      if (err || !data || data.error) {
        showToast((data && data.message) || 'Failed to generate bind code', 'error');
        return;
      }
      $('bind-code-display').textContent = data.code || data.bind_code || '------';
      $('bind-modal').style.display = 'flex';
      $('bind-modal').setAttribute('aria-hidden', 'false');
      // Start countdown timer
      if (bindTimerInterval) clearInterval(bindTimerInterval);
      var expiresAt = data.expires || data.expires_at;
      function updateTimer() {
        var remaining = expiresAt - Math.floor(Date.now() / 1000);
        if (remaining <= 0) {
          clearInterval(bindTimerInterval);
          $('bind-timer').textContent = 'Expired — generate a new code';
          $('bind-timer').style.color = '#f85149';
          return;
        }
        var m = Math.floor(remaining / 60);
        var s = remaining % 60;
        $('bind-timer').textContent = 'Valid for ' + m + ':' + (s < 10 ? '0' : '') + s;
        $('bind-timer').style.color = remaining < 60 ? '#f0883e' : '#8b949e';
      }
      updateTimer();
      bindTimerInterval = setInterval(updateTimer, 1000);
    });
  }

  function closeBindModal() {
    $('bind-modal').style.display = 'none';
    $('bind-modal').setAttribute('aria-hidden', 'true');
    if (bindTimerInterval) { clearInterval(bindTimerInterval); bindTimerInterval = null; }
  }

  // Wire bind modal buttons (inline — DOM already ready since script is at bottom)
  var _addVendoBtn = $('btn-add-vendo');
  if (_addVendoBtn) _addVendoBtn.addEventListener('click', openBindModal);
  var _closeBindBtn = $('close-bind-modal');
  if (_closeBindBtn) _closeBindBtn.addEventListener('click', closeBindModal);
  var _regenBindBtn = $('btn-regen-bind');
  if (_regenBindBtn) _regenBindBtn.addEventListener('click', openBindModal);
  var _bindBackdrop = document.querySelector('#bind-modal [data-close]');
  if (_bindBackdrop) _bindBackdrop.addEventListener('click', closeBindModal);

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
      var status = statusLabels[s.status] || statusLabels.idle;
      var sName = s.device_name || s.name || shortMac(s.mac);
      var connection = s.connected ? (s.ssid || s.interface || 'Connected') : 'Not on WiFi';
      var finalAction = s.status === 'idle'
        ? '<button class="action-btn danger" onclick="adminAction(\x27forget\x27,\x27' + s.mac + '\x27)">Forget</button>'
        : '<button class="action-btn danger" onclick="adminAction(\x27reset\x27,\x27' + s.mac + '\x27)">Reset</button>';
      tr.innerHTML = '<td><strong>' + escapeHtml(sName) + '</strong><div style="font-size:.7rem;color:var(--text2);margin-top:2px">' + escapeHtml(s.mac) + '</div></td>' +
        '<td id="session-time-' + i + '">--</td>' +
        '<td>' + escapeHtml(s.ip || '--') + '<div style="font-size:.7rem;color:var(--text2);margin-top:2px">' + escapeHtml(connection) + '</div></td>' +
        '<td><span class="badge ' + status.css + '">' + status.text + '</span></td>' +
        '<td><button class="action-btn" onclick="adminAction(\x27rename\x27,\x27' + s.mac + '\x27)">Name</button> ' +
        '<button class="action-btn" onclick="adminAction(\x27edit-time\x27,\x27' + s.mac + '\x27)">Time</button> ' +
        '<button class="action-btn danger" onclick="adminAction(\x27block\x27,\x27' + s.mac + '\x27)">Block</button> ' +
        finalAction + '</td>';
      tbody.appendChild(tr);
    }
    updateSessionCountdowns();
    renderDevices(data.devices || []);
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
        '<td>' + blocked + '</td>' +
        '<td><button class="action-btn" onclick="adminAction(\x27rename\x27,\x27' + d.mac + '\x27)">' + dNameLabel + '</button> ' +
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
      if (php && mins) lines.push(php + ':' + mins);
    });
    $('set-rates').value = lines.join('\n');
    $('rate-empty').style.display = rows.length ? 'none' : '';
  }

  function addRateTierRow(php, mins) {
    var container = $('rate-rows');
    var row = document.createElement('div');
    row.className = 'rate-tier-row';
    var phpVal = php !== undefined ? php : '';
    var duration = rateDurationFromMinutes(mins);
    var durationVal = duration.value;
    var unitVal = duration.unit;
    var computed = (phpVal && durationVal) ? '\u20B1' + phpVal + ' = ' + formatRateMinutes(mins) : '--';
    row.innerHTML =
      '<div class="rate-tier-field"><label>\u20B1 Amount</label>' +
      '<input type="number" class="tier-php" min="1" step="1" value="' + escapeHtml(phpVal) + '" placeholder="e.g. 5"></div>' +
      '<div class="rate-tier-sep">=</div>' +
      '<div class="rate-tier-field"><label>Duration</label>' +
      '<input type="number" class="tier-duration" min="1" step="1" value="' + escapeHtml(durationVal) + '" placeholder="e.g. 2"></div>' +
      '<div class="rate-tier-field"><label>Unit</label>' +
      '<select class="tier-unit"><option value="minutes">Minutes</option><option value="hours">Hours</option><option value="days">Days</option></select></div>' +
      '<div class="rate-tier-badge tier-preview">' + escapeHtml(computed) + '</div>' +
      '<button type="button" class="rate-tier-del" title="Remove">&#x2715;</button>';
    row.querySelector('.tier-unit').value = unitVal;
    row.querySelector('.rate-tier-del').addEventListener('click', function () {
      row.remove(); syncRateTextarea();
    });
    function updatePreview() {
      var p = row.querySelector('.tier-php').value.trim();
      var m = rateMinutesForRow(row);
      row.querySelector('.tier-preview').textContent = (p && m) ? '\u20B1' + p + ' = ' + formatRateMinutes(m) : '--';
      syncRateTextarea();
    }
    row.querySelector('.tier-php').addEventListener('input', updatePreview);
    row.querySelector('.tier-duration').addEventListener('input', updatePreview);
    row.querySelector('.tier-unit').addEventListener('change', updatePreview);
    container.appendChild(row);
    $('rate-empty').style.display = 'none';
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
      if (parts.length === 2) addRateTierRow(parts[0].trim(), parts[1].trim());
    });
    syncRateTextarea();
  }

  // ── Pause Rule UI ────────────────────────────────────────────────────────
  function syncPauseTextarea() {
    var rows = $('pause-rule-rows').querySelectorAll('.pause-rule-row');
    var lines = [];
    rows.forEach(function (row) {
      var from = row.querySelector('.rule-from').value.trim();
      var to = row.querySelector('.rule-to').value.trim();
      var max = row.querySelector('.rule-max').value.trim();
      if (from && to && max) lines.push(from + '-' + to + ':' + max);
    });
    $('set-pause-rules').value = lines.join('\n');
    $('pause-rule-empty').style.display = rows.length ? 'none' : '';
  }

  function addPauseRuleRow(from, to, max) {
    var container = $('pause-rule-rows');
    var row = document.createElement('div');
    row.className = 'pause-rule-row';
    row.style.cssText = 'display:flex;align-items:flex-end;gap:8px;padding:10px 0;border-top:1px solid var(--border);flex-wrap:wrap;';
    row.innerHTML =
      '<div class="rate-tier-field"><label>From (min)</label>' +
      '<input type="number" class="rule-from" min="0" step="1" value="' + (from || '') + '" placeholder="0" style="width:80px;"></div>' +
      '<div class="rate-tier-sep">&ndash;</div>' +
      '<div class="rate-tier-field"><label>To (min)</label>' +
      '<input type="number" class="rule-to" min="1" step="1" value="' + (to || '') + '" placeholder="60" style="width:80px;"></div>' +
      '<div class="rate-tier-sep">&rarr;</div>' +
      '<div class="rate-tier-field"><label>Max Pauses</label>' +
      '<input type="number" class="rule-max" min="0" step="1" value="' + (max || '') + '" placeholder="3" style="width:80px;"></div>' +
      '<button type="button" class="rate-tier-del" title="Remove">&#x2715;</button>';
    row.querySelector('.rate-tier-del').addEventListener('click', function () {
      row.remove(); syncPauseTextarea();
    });
    ['rule-from', 'rule-to', 'rule-max'].forEach(function (cls) {
      row.querySelector('.' + cls).addEventListener('input', syncPauseTextarea);
    });
    container.appendChild(row);
    $('pause-rule-empty').style.display = 'none';
  }

  $('btn-add-pause-rule').addEventListener('click', function () { addPauseRuleRow(); });

  function renderPauseRules(rawStr) {
    $('pause-rule-rows').innerHTML = '';
    var lines = (rawStr || '').split('\n').filter(function (l) { return l.trim(); });
    if (lines.length === 0) {
      $('pause-rule-empty').style.display = '';
      $('set-pause-rules').value = '';
      return;
    }
    lines.forEach(function (line) {
      var m = line.match(/^(\d+)-(\d+):(\d+)$/);
      if (m) addPauseRuleRow(m[1], m[2], m[3]);
    });
    syncPauseTextarea();
  }

  // ── Bandwidth mode toggle ────────────────────────────────────────────────
  window._bwSelect = function (mode) {
    var perClient = $('bw-per-client');
    var shared = $('bw-shared');
    if (perClient) perClient.style.display = mode === 'per_client' ? '' : 'none';
    if (shared) shared.style.display = mode === 'shared' ? '' : 'none';
  };

  // ── Settings ────────────────────────────────────────────────────────────
  function applyAdminBranding(value) {
    var name = String(value || '').replace(/^\s+|\s+$/g, '') || 'TarakiFi';
    var sidebarName = $('admin-business-name');
    var mobileName = $('mobile-business-name');
    if (sidebarName) { sidebarName.textContent = name; sidebarName.title = name; }
    if (mobileName) { mobileName.textContent = name; mobileName.title = name; }
  }

  function loadSettings() {
    xhr('GET', API + '/settings', null, function (err, data) {
      if (err || !data) return;
      var s = data.settings || data;  // API returns flat object
      $('set-business-name').value = s.business_name || 'TarakiFi';
      $('set-show-business-name').value = s.portal_show_business_name || '0';
      $('set-portal-name').value = s.portal_name || 'TarakiFi WiFi';
      $('set-portal-footer-text').value = s.portal_footer_text || '';
      applyAdminBranding(s.business_name);
      applyAdminMedia(s);
      $('set-show-rates').value = s.portal_show_rates || '1';
      $('set-show-voucher').value = s.portal_show_voucher || s.show_voucher || '0';
      $('set-show-coin').value = s.portal_show_coin || '1';
      $('set-hide-device-info').value = s.portal_hide_device_info || s.hide_device_info || '0';
      $('set-hide-pause-button').value = s.portal_hide_pause_button || '0';
      if ($('set-portal-theme')) $('set-portal-theme').value = s.portal_theme || 'dark';
      renderRateTiers(s.portal_rates || '1:12\n5:60\n10:120');
      $('set-flat-rate').value = s.coin_min_per_php || '';
      $('set-coin-timeout').value = s.coinslot_timeout_seconds || s.portal_coin_timeout_seconds || '60';
      $('set-busy-lock').value = s.coinslot_busy_lock || s.coin_busy_lock || '1';
      $('set-max-empty').value = s.coinslot_max_empty_opens || s.coin_max_empty_opens || '3';
      $('set-empty-cooldown').value = s.coinslot_empty_open_cooldown_seconds || s.coin_empty_cooldown || '120';
      renderPauseRules(s.pause_rules || '');
      $('set-pause-penalty').value = s.pause_penalty_minutes || '0';
      $('set-auto-pause').value = s.auto_pause_on_disconnect || '0';
      // Bandwidth mode - radio buttons
      var bwMode = s.bw_mode || s.bandwidth_mode || 'off';
      var bwRadio = document.querySelector('input[name="bw_mode"][value="' + bwMode + '"]');
      if (bwRadio) { bwRadio.checked = true; _bwSelect(bwMode); }
      $('bw-per-client-down').value = s.bw_per_client_down_kbps || '';
      $('bw-per-client-up').value = s.bw_per_client_up_kbps || '';
      $('bw-total-down').value = s.bw_total_down_kbps || '';
      $('bw-total-up').value = s.bw_total_up_kbps || '';
      if ($('bw-exempt-macs')) $('bw-exempt-macs').value = s.bw_exempt_macs || '';
      $('set-free-enabled').value = s.free_time_enabled || '0';
      $('set-free-minutes').value = s.free_time_minutes || '5';
      $('set-free-limit').value = s.free_time_daily_limit || '1';
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
      portal_show_business_name: $('set-show-business-name').value,
      portal_name: $('set-portal-name').value,
      portal_footer_text: $('set-portal-footer-text').value,
      portal_show_rates: $('set-show-rates').value,
      portal_show_voucher: $('set-show-voucher').value,
      portal_show_coin: $('set-show-coin').value,
      portal_hide_device_info: $('set-hide-device-info').value,
      portal_hide_pause_button: $('set-hide-pause-button').value,
      portal_theme: $('set-portal-theme') ? $('set-portal-theme').value : 'dark',
      portal_rates: $('set-rates').value,
      pause_rules: $('set-pause-rules').value,
      coin_min_per_php: $('set-flat-rate').value,
      coinslot_timeout_seconds: $('set-coin-timeout').value,
      coinslot_busy_lock: $('set-busy-lock').value,
      coinslot_max_empty_opens: $('set-max-empty').value,
      coinslot_empty_open_cooldown_seconds: $('set-empty-cooldown').value,
      pause_penalty_minutes: $('set-pause-penalty').value,
      auto_pause_on_disconnect: $('set-auto-pause').value,
      bw_mode: document.querySelector('input[name="bw_mode"]:checked') ? document.querySelector('input[name="bw_mode"]:checked').value : 'off',
      bw_per_client_down_kbps: $('bw-per-client-down').value,
      bw_per_client_up_kbps: $('bw-per-client-up').value,
      bw_total_down_kbps: $('bw-total-down').value,
      bw_total_up_kbps: $('bw-total-up').value,
      bw_exempt_macs: $('bw-exempt-macs').value,
      free_time_enabled: $('set-free-enabled').value,
      free_time_minutes: $('set-free-minutes').value,
      free_time_daily_limit: $('set-free-limit').value
    };
    xhr('POST', API + '/settings', settings, function (err, data) {
      setLoading(btn, false);
      if (err || !data || data.error) { showToast('Failed to save: ' + ((data && (data.message || data.error)) || 'error'), 'error'); return; }
      applyAdminBranding(settings.business_name);
      showToast('Settings saved! ✓');
    });
  });

  // ── System ──────────────────────────────────────────────────────────────
  var wanPasswordConfigured = false;
  var wanPppoeSupported = false;

  function updateWanFields() {
    var modeInput = $('wan-connection-mode');
    var mode = modeInput.value;
    if (mode === 'pppoe' && !wanPppoeSupported) {
      mode = 'dhcp';
      modeInput.value = mode;
    }
    $('wan-pppoe-fields').style.display = mode === 'pppoe' ? '' : 'none';
    $('wan-pppoe-unavailable').style.display = wanPppoeSupported ? 'none' : '';
    $('wan-password-status').textContent = mode === 'pppoe' && wanPasswordConfigured ?
      'A password is saved. Leave this field blank to keep it.' : '';
  }

  function renderWanConfig(data) {
    if (!data) return;
    wanPppoeSupported = data.pppoe_supported === true;
    var pppoeOption = $('wan-pppoe-option');
    pppoeOption.disabled = !wanPppoeSupported;
    pppoeOption.hidden = !wanPppoeSupported;
    var mode = data.mode === 'pppoe' && wanPppoeSupported ? 'pppoe' : 'dhcp';
    $('wan-connection-mode').value = mode;
    $('wan-pppoe-username').value = data.username || '';
    $('wan-pppoe-password').value = '';
    wanPasswordConfigured = data.password_configured === true;
    updateWanFields();

    var status = $('wan-config-status');
    if (data.connected === true) {
      status.textContent = 'Connected';
      status.className = 'badge badge-green';
    } else if (data.connecting === true) {
      status.textContent = 'Connecting';
      status.className = 'badge badge-gray';
    } else {
      status.textContent = 'Offline';
      status.className = 'badge badge-red';
    }
    $('wan-config-interface').textContent = data.l3_interface || data.physical_interface || '--';
  }

  function loadWanConfig() {
    xhr('GET', API + '/system/wan', null, function (err, data) {
      if (err || !data || data.error) {
        $('wan-config-status').textContent = 'Unavailable';
        $('wan-config-status').className = 'badge badge-red';
        return;
      }
      renderWanConfig(data);
    });
  }

  function renderWanAccess(data) {
    if (!data) return;
    var active = data.active === true;
    var status = $('wan-access-status');
    status.textContent = active ? 'Open' : 'Closed';
    status.className = 'badge ' + (active ? 'badge-green' : 'badge-gray');
    var url = $('wan-access-url');
    url.textContent = data.admin_url || '--';
    url.href = data.admin_url || '#';
    $('wan-access-expires').textContent = active && data.expires_at ?
      new Date(data.expires_at * 1000).toLocaleString() : '--';
    $('wan-access-disable-btn').disabled = !active;
    if (active) {
      $('wan-access-mode').value = data.mode || 'admin';
      $('wan-access-source').value = data.source || '';
    }
  }

  function loadWanAccess() {
    xhr('GET', API + '/system/wan-access', null, function (err, data) {
      if (err || !data || data.error) return;
      renderWanAccess(data);
    });
  }

  function setCloudBackupMessage(text, type) {
    var el = $('cloud-backup-message');
    if (!el) return;
    el.textContent = text || '';
    el.style.color = type === 'error' ? '#f0883e' : 'var(--text2)';
  }

  function setManualUpdateMessage(text, type) {
    var el = $('manual-update-message');
    if (!el) return;
    el.textContent = text || '';
    el.style.color = type === 'error' ? '#f0883e' : 'var(--text2)';
  }

  function renderCloudBackup(data) {
    var enabled = data && data.enabled === true;
    var configured = data && data.configured === true;
    var latest = data && data.latest;
    var status = $('cloud-backup-status');
    var toggle = $('cloud-backup-enabled');
    var backupBtn = $('cloud-backup-now-btn');
    var restoreBtn = $('cloud-restore-btn');

    cloudBackupConfigured = configured;
    if (toggle) {
      toggle.checked = configured && enabled;
      toggle.disabled = !configured;
    }
    if (status) {
      status.className = 'badge ' + (enabled && configured ? 'badge-green' : 'badge-gray');
      status.textContent = configured ? (enabled ? 'On' : 'Off') : 'License Required';
    }
    if ($('cloud-backup-last')) {
      $('cloud-backup-last').textContent = formatDateTime((latest && latest.created_at) || (data && data.last_backup_at));
    }
    if ($('cloud-backup-total')) {
      $('cloud-backup-total').textContent = configured && data.total_backups !== undefined ? data.total_backups : '--';
    }
    if ($('cloud-backup-version')) {
      $('cloud-backup-version').textContent = latest && latest.firmware_version ? 'v' + latest.firmware_version : '--';
    }
    if (backupBtn) backupBtn.disabled = !enabled || !configured;
    if (restoreBtn) restoreBtn.disabled = !configured;

    if (!configured) {
      setCloudBackupMessage('Activate license first.');
    } else if (!enabled) {
      setCloudBackupMessage('Automatic backup is off.');
    } else if (latest && latest.created_at) {
      setCloudBackupMessage('Latest backup is available.');
    } else {
      setCloudBackupMessage('Ready for first backup.');
    }
  }

  function loadCloudBackup() {
    if (!$('cloud-backup-enabled')) return;
    xhr('GET', API + '/cloud-backup/status', null, function (err, data) {
      if (err || !data || data.error) {
        setCloudBackupMessage('Cloud backup status unavailable.', 'error');
        return;
      }
      renderCloudBackup(data);
    });
  }

  function loadSystem() {
    xhr('GET', API + '/system/info', null, function (err, data) {
      if (err || !data) return;
      $('sys-hostname').textContent = data.hostname || '--';
      $('sys-model').textContent = data.model || '--';
      setCustomMediaUploadSupport(data.custom_media_uploads_supported !== false);
      $('sys-firmware').textContent = data.fw_version || data.firmware || '--';
      $('sys-build').textContent = data.build_commit || '--';
      $('sys-kernel').textContent = data.kernel || '--';
      $('sys-uptime').textContent = formatTime(data.uptime_seconds || data.uptime) || '--';
      if (data.ram_total_mb) {
        $('sys-ram').textContent = data.ram_used_mb + 'MB / ' + data.ram_total_mb + 'MB';
      }
      $('sys-flash').textContent = formatStorage(
        data.disk_used_mb, data.disk_total_mb, data.disk_used_kb, data.disk_total_kb
      );
      $('sys-lan-ip').textContent = data.lan_ip || '--';
      $('sys-wan-ip').textContent = data.wan_ip || '--';
      // License
      if (data.license_status) {
        var licenseStatus = data.license_status;
        $('license-status').textContent = licenseStatus === 'unknown' ? 'Checking license...' : licenseStatus;
        $('license-status').style.color = licenseStatus === 'active' ? '#7ee787' : licenseStatus === 'unknown' ? '#58a6ff' : '#f0883e';
      }
      if ($('license-used')) {
        $('license-used').textContent = data.license_key_masked || 'Not configured';
      }
      $('license-key').value = '';
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
    loadWanConfig();
    loadWanAccess();
    loadCloudBackup();
    // Populate OTA current version from system info
    xhr('GET', API + '/system/info', null, function (err, data) {
      if (!err && data && data.fw_version) {
        $('ota-current-ver').textContent = 'v' + data.fw_version;
      }
    });
  }

  // ── OTA Firmware Update ────────────────────────────────────────────
  var _otaManifest = null;
  if ($('ota-check-btn')) $('ota-check-btn').addEventListener('click', function () {
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
  if ($('ota-update-btn')) $('ota-update-btn').addEventListener('click', function () {
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
    xhr('POST', API + '/system/update', { version: _otaManifest.version }, function (err, data) {
      setLoading(btn, false);
      if (err || !data || data.error) {
        $('ota-status').textContent = (data && (data.message || data.error)) || 'Update failed';
        $('ota-status').style.color = '#f0883e';
        $('ota-progress').style.display = 'none';
        return;
      }
      $('ota-progress-bar').style.width = '100%';
      $('ota-progress-text').textContent = 'Applying update... Settings preserved. Router will reboot.';
      $('ota-status').textContent = 'Rebooting...';
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
    var mode = modeInput ? modeInput.value : 'fresh';
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
    var prompt = mode === 'preserve'
      ? 'Install this firmware and preserve settings? The router will reboot.'
      : 'Fresh install this firmware? Current settings and data will be erased.';
    if (!confirm(prompt)) return;

    var btn = this;
    setLoading(btn, true);
    setManualUpdateMessage('Uploading firmware...');
    if (progress) progress.style.display = '';
    if (progressBar) progressBar.style.width = '3%';

    var safeMode = mode === 'preserve' ? 'preserve' : 'fresh';
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
      setManualUpdateMessage(data.message || 'Firmware update started. Router will reboot.');
      showToast('Firmware update started');
      setTimeout(function () {
        var overlay = $('reboot-overlay');
        if (overlay) overlay.style.display = 'flex';
      }, 1500);
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
      req.setRequestHeader('X-Tarakifi-Firmware-Name', file.name || 'firmware.bin');
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

  $('wan-connection-mode').addEventListener('change', updateWanFields);

  $('save-wan-config-btn').addEventListener('click', function () {
    var button = this;
    var mode = $('wan-connection-mode').value;
    var username = $('wan-pppoe-username').value.trim();
    var password = $('wan-pppoe-password').value;
    if (mode === 'pppoe' && !wanPppoeSupported) {
      showToast('PPPoE is not available on this router model', 'error');
      return;
    }
    if (mode === 'pppoe' && !username) {
      showToast('Enter the PPPoE username from your internet provider', 'error');
      return;
    }
    if (mode === 'pppoe' && !password && !wanPasswordConfigured) {
      showToast('Enter the PPPoE password from your internet provider', 'error');
      return;
    }
    if (!window.confirm('Save this internet connection? Customer internet will restart briefly.')) return;

    setLoading(button, true);
    $('wan-config-message').textContent = 'Applying connection settings...';
    xhr('POST', API + '/system/wan', {
      mode: mode,
      username: mode === 'pppoe' ? username : '',
      password: mode === 'pppoe' ? password : ''
    }, function (err, data) {
      setLoading(button, false);
      $('wan-pppoe-password').value = '';
      if (err || !data || data.error) {
        var message = (data && data.message) || 'Internet connection settings were not saved';
        $('wan-config-message').textContent = message;
        showToast(message, 'error');
        return;
      }
      renderWanConfig(data);
      $('wan-config-message').textContent = 'Saved. Checking internet connection...';
      showToast('Internet connection settings saved');
      window.setTimeout(loadWanConfig, 5000);
    }, 30000);
  });

  $('wan-access-enable-btn').addEventListener('click', function () {
    var button = this;
    var source = $('wan-access-source').value.trim();
    if (!source) { showToast('Enter a trusted source address', 'error'); return; }
    setLoading(button, true);
    xhr('POST', API + '/system/wan-access', {
      enabled: true,
      mode: $('wan-access-mode').value,
      source: source,
      duration_seconds: Number($('wan-access-duration').value)
    }, function (err, data) {
      setLoading(button, false);
      if (err || !data || data.error) {
        showToast((data && data.message) || 'Access could not be opened', 'error');
        return;
      }
      renderWanAccess(data);
      showToast('WAN troubleshooting access opened');
    });
  });

  $('wan-access-disable-btn').addEventListener('click', function () {
    var button = this;
    setLoading(button, true);
    xhr('POST', API + '/system/wan-access', {enabled: false, mode: 'off'}, function (err, data) {
      setLoading(button, false);
      if (err || !data || data.error) {
        showToast((data && data.message) || 'Access could not be closed', 'error');
        return;
      }
      renderWanAccess(data);
      showToast('WAN troubleshooting access closed');
    });
  });

  var cloudToggle = $('cloud-backup-enabled');
  if (cloudToggle) cloudToggle.addEventListener('change', function () {
    var toggle = this;
    var enabled = toggle.checked;
    if (enabled && !cloudBackupConfigured) {
      toggle.checked = false;
      setCloudBackupMessage('Activate license first.', 'error');
      showToast('Activate license first.', 'error');
      return;
    }
    toggle.disabled = true;
    setCloudBackupMessage('Saving...');
    xhr('POST', API + '/cloud-backup/settings', {enabled: enabled ? '1' : '0'}, function (err, data) {
      toggle.disabled = false;
      if (!cloudBackupConfigured) toggle.disabled = true;
      if (err || !data || data.error) {
        toggle.checked = !enabled;
        var message = (data && (data.message || data.error)) || 'Cloud backup setting was not saved';
        setCloudBackupMessage(message, 'error');
        showToast(message, 'error');
        loadCloudBackup();
        return;
      }
      setCloudBackupMessage(enabled ? 'Cloud backup is on.' : 'Cloud backup is off.');
      showToast(enabled ? 'Cloud backup enabled' : 'Cloud backup disabled');
      loadCloudBackup();
    });
  });

  var cloudBackupBtn = $('cloud-backup-now-btn');
  if (cloudBackupBtn) cloudBackupBtn.addEventListener('click', function () {
    var btn = this;
    setLoading(btn, true);
    setCloudBackupMessage('Starting backup...');
    xhr('POST', API + '/cloud-backup/backup', {}, function (err, data) {
      setLoading(btn, false);
      if (err || !data || data.error) {
        var message = (data && (data.message || data.error)) || 'Backup could not start';
        setCloudBackupMessage(message, 'error');
        showToast(message, 'error');
        loadCloudBackup();
        return;
      }
      showToast('Backup started');
      setCloudBackupMessage('Backup started.');
      setTimeout(loadCloudBackup, 3000);
    });
  });

  var cloudRestoreBtn = $('cloud-restore-btn');
  if (cloudRestoreBtn) cloudRestoreBtn.addEventListener('click', function () {
    if (!confirm('Restore latest cloud backup? Current router settings will be replaced and the router may restart.')) return;
    var btn = this;
    setLoading(btn, true);
    setCloudBackupMessage('Starting restore...');
    xhr('POST', API + '/cloud-backup/restore', {}, function (err, data) {
      setLoading(btn, false);
      if (err || !data || data.error) {
        showToast((data && data.error) || 'Restore could not start', 'error');
        loadCloudBackup();
        return;
      }
      showToast('Restore started');
      setCloudBackupMessage('Restore started. Router may restart.');
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
            // Preserve the vendor tunnel URL remotely; local reload returns to login.
            overlay.style.display = 'none';
            window.location.reload();
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
      a.href = url; a.download = 'tarakifi-backup-' + new Date().toISOString().slice(0, 10) + '.json';
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
      loadSystem();
    });
  });

  // ── Asset Upload (multipart/form-data) ─────────────────────────────
  var ASSET_RULES = {
    coin_sound: {max: 921600, exts: ['mp3', 'wav', 'ogg'], kind: 'audio'},
    tick_sound: {max: 204800, exts: ['mp3', 'wav', 'ogg'], kind: 'audio'},
    logo: {max: 512000, exts: ['png', 'jpg', 'jpeg', 'webp'], kind: 'logo'},
    hero: {max: 921600, exts: ['png', 'jpg', 'jpeg', 'webp'], kind: 'hero'}
  };
  var customMediaUploadsSupported = true;

  function setCustomMediaUploadSupport(supported) {
    customMediaUploadsSupported = supported;
    if (supported) return;
    Object.keys(ASSET_RULES).forEach(function (type) {
      var input = $('upload-' + type.replace('_', '-'));
      if (!input) return;
      input.disabled = true;
      var button = input.parentNode && input.parentNode.querySelector('button');
      if (button) button.disabled = true;
      assetFeedback(type, 'Built-in media only on CF-E314N v2 (limited flash).', false);
    });
  }

  function assetFeedback(type, message, isError) {
    var statusEl = $(type.replace('_', '-') + '-status');
    if (!statusEl) return;
    statusEl.textContent = message || '';
    statusEl.className = 'asset-feedback' + (message ? (isError ? ' is-error' : ' is-success') : '');
  }

  function fileExtension(name) {
    var match = String(name || '').toLowerCase().match(/\.([a-z0-9]+)$/);
    return match ? match[1] : '';
  }

  function detectedMediaFormat(bytes) {
    function ascii(pos, length) {
      var out = '';
      for (var i = pos; i < pos + length && i < bytes.length; i++) {
        out += String.fromCharCode(bytes[i]);
      }
      return out;
    }
    if (bytes.length >= 12 && ascii(0, 4) === 'RIFF' && ascii(8, 4) === 'WAVE') return 'wav';
    if (bytes.length >= 4 && ascii(0, 4) === 'OggS') return 'ogg';
    function hasMp3Frame(pos) {
      if (pos + 2 >= bytes.length || bytes[pos] !== 255 || bytes[pos + 1] < 224) return false;
      var version = Math.floor(bytes[pos + 1] / 8) % 4;
      var layer = Math.floor(bytes[pos + 1] / 2) % 4;
      var bitrate = Math.floor(bytes[pos + 2] / 16);
      var sampleRate = Math.floor(bytes[pos + 2] / 4) % 4;
      return version !== 1 && layer !== 0 && bitrate !== 0 && bitrate !== 15 && sampleRate !== 3;
    }
    var mp3Start = 0;
    if (bytes.length >= 10 && ascii(0, 3) === 'ID3') {
      if (bytes[6] >= 128 || bytes[7] >= 128 || bytes[8] >= 128 || bytes[9] >= 128) return '';
      var tagSize = (bytes[6] * 2097152) + (bytes[7] * 16384) + (bytes[8] * 128) + bytes[9];
      mp3Start = 10 + tagSize + ((Math.floor(bytes[5] / 16) % 2) ? 10 : 0);
    }
    for (var pos = mp3Start; pos <= Math.min(bytes.length - 3, mp3Start + 64); pos++) {
      if (hasMp3Frame(pos)) return 'mp3';
    }
    if (bytes.length >= 8 && bytes[0] === 137 && ascii(1, 3) === 'PNG' &&
        bytes[4] === 13 && bytes[5] === 10 && bytes[6] === 26 && bytes[7] === 10) return 'png';
    if (bytes.length >= 3 && bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) return 'jpeg';
    if (bytes.length >= 12 && ascii(0, 4) === 'RIFF' && ascii(8, 4) === 'WEBP') return 'webp';
    return '';
  }

  function validateAssetFile(type, file, callback) {
    var rule = ASSET_RULES[type];
    if (!rule) { callback('Unknown upload type.'); return; }
    if (!file || !file.size) { callback('The selected file is empty.'); return; }
    if (file.size > rule.max) {
      callback('File is too large. Maximum: ' + Math.floor(rule.max / 1024) + ' KB.');
      return;
    }
    var ext = fileExtension(file.name);
    if (rule.exts.indexOf(ext) === -1) {
      callback('Allowed formats: .' + rule.exts.join(', .') + '.');
      return;
    }

    var reader = new FileReader();
    reader.onerror = function () { callback('The selected file could not be read.'); };
    reader.onload = function () {
      var detected = detectedMediaFormat(new Uint8Array(reader.result));
      var normalizedExt = (ext === 'jpg' || ext === 'jpeg') ? 'jpeg' : ext;
      if (!detected) {
        callback(rule.kind === 'audio' ?
          'This is not a valid MP3, WAV, or OGG audio file.' :
          'This is not a valid PNG, JPEG, or WebP image.');
        return;
      }
      if (detected !== normalizedExt) {
        callback('The file content does not match its .' + ext + ' extension.');
        return;
      }
      if (rule.kind === 'audio') { callback(null, {}); return; }

      var objectUrl = (window.URL || window.webkitURL).createObjectURL(file);
      var image = new Image();
      image.onload = function () {
        (window.URL || window.webkitURL).revokeObjectURL(objectUrl);
        var width = image.naturalWidth || image.width;
        var height = image.naturalHeight || image.height;
        if (rule.kind === 'hero') {
          var ratio = width / height;
          if (width < 640 || height < 320 || width > 1920 || height > 1080 ||
              ratio < 1.5 || ratio > 2.0) {
            callback('Hero must be 640x320 to 1920x1080 with a 1.5:1 to 2:1 ratio. Selected: ' +
              width + 'x' + height + '.');
            return;
          }
        } else if (width < 64 || height < 64 || width > 1024 || height > 1024) {
          callback('Logo must be 64x64 to 1024x1024. Selected: ' + width + 'x' + height + '.');
          return;
        }
        callback(null, {width: width, height: height});
      };
      image.onerror = function () {
        (window.URL || window.webkitURL).revokeObjectURL(objectUrl);
        callback('The selected image is damaged or cannot be decoded.');
      };
      image.src = objectUrl;
    };
    reader.readAsArrayBuffer(file);
  }

  function sendAssetUpload(type, input, file) {
    assetFeedback(type, 'Uploading...', false);
    var formData = new FormData();
    formData.append('type', type);
    formData.append('file', file);

    var xh = new XMLHttpRequest();
    xh.open('POST', API + '/upload', true);
    xh.withCredentials = true;
    xh.onload = function () {
      try {
        var resp = JSON.parse(xh.responseText);
        if (xh.status === 200 && resp.ok) {
          var dimensions = resp.width && resp.height ? ' - ' + resp.width + 'x' + resp.height : '';
          assetFeedback(type, 'Uploaded: ' + resp.file + dimensions, false);
          showToast(type.replace('_', ' ') + ' uploaded!');
          input.value = '';
          var media = {portal_asset_version: resp.asset_version || Date.now()};
          media['portal_' + type + '_file'] = resp.file;
          applyAdminMedia(media);
        } else {
          var message = resp.message || resp.error || 'Upload failed.';
          assetFeedback(type, message, true);
          showToast(message, 'error');
        }
      } catch (e) {
        assetFeedback(type, 'Upload failed. The router returned an invalid response.', true);
        showToast('Upload failed', 'error');
      }
    };
    xh.onerror = function () {
      assetFeedback(type, 'Upload failed due to a network error.', true);
      showToast('Upload failed (network error)', 'error');
    };
    xh.send(formData);
  }

  // Global function called by inline onclick in HTML.
  window.uploadAsset = function (type, inputId) {
    if (!customMediaUploadsSupported) {
      showToast('Custom media uploads are unavailable on CF-E314N v2.', 'error');
      return;
    }
    var input = $(inputId);
    if (!input || !input.files || !input.files[0]) {
      assetFeedback(type, 'Select a file first.', true);
      showToast('Select a file first', 'error');
      return;
    }
    var file = input.files[0];
    assetFeedback(type, 'Checking file...', false);
    validateAssetFile(type, file, function (validationError, details) {
      if (validationError) {
        assetFeedback(type, validationError, true);
        showToast(validationError, 'error');
        return;
      }
      sendAssetUpload(type, input, file);
    });
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
      if ($('upstream-protection-enabled')) {
        $('upstream-protection-enabled').checked = d.upstream_ip_blocking_enabled !== '0' && d.upstream_ip_blocking_enabled !== false;
      }
      if ($('blocked-upstream-ips')) $('blocked-upstream-ips').value = d.blocked_upstream_ips || '';
      if ($('anti-tethering-enabled')) {
        $('anti-tethering-enabled').checked = d.anti_tethering_enabled === '1' || d.anti_tethering_enabled === true;
      }
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
        blocked_sites: sites,
        upstream_ip_blocking_enabled: $('upstream-protection-enabled') && $('upstream-protection-enabled').checked ? '1' : '0',
        blocked_upstream_ips: $('blocked-upstream-ips') ? $('blocked-upstream-ips').value : '',
        anti_tethering_enabled: $('anti-tethering-enabled') && $('anti-tethering-enabled').checked ? '1' : '0'
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
