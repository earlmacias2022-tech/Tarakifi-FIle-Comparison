/**
 * TarakiFi OpenWrt Portal — Premium Dark
 * Pure ES5. No fetch/Promise. Works on old Android WebViews.
 * Uses XHR polling (no SSE on OpenWrt uhttpd).
 */
(function () {
  var API = '/api/portal';
  var PORTAL_URL = 'http://10.0.0.1/';
  var TIMEOUT_S = 60;
  var POLL_MS = 300;  // fast poll while coin modal is open — router is local 10.0.0.1
  var COIN_FINALIZE_MAX_RETRIES = 2;
  var COIN_FINALIZE_RETRY_MS = 350;
  var COIN_READY_POLL_MS = 150;
  var COIN_READY_MAX_ATTEMPTS = 34;
  var captiveLoginCompleting = false;
  var statusInitialized = false;

  function queryValue(name) {
    var query = String(window.location.search || '').replace(/^\?/, '').split('&');
    for (var i = 0; i < query.length; i++) {
      var pair = query[i].split('=');
      if (decodeURIComponent(pair[0] || '') === name) {
        return decodeURIComponent((pair[1] || '').replace(/\+/g, ' '));
      }
    }
    return '';
  }
  var captiveMode = queryValue('cna');

  // ── Sound Engine ─────────────────────────────────────────────────────
  // Inline WAV sounds (base64). No external files. ES5 compatible.
  var _soundEnabled = { tick: true };
  var _audioCtx = null;
  function _getAudioCtx() {
    if (!_audioCtx) {
      try { _audioCtx = new (window.AudioContext || window.webkitAudioContext)(); }
      catch (e) { _audioCtx = null; }
    }
    return _audioCtx;
  }
  function _b64ToArrayBuffer(b64) {
    var bin = atob(b64), buf = new ArrayBuffer(bin.length), v = new Uint8Array(buf);
    for (var i = 0; i < bin.length; i++) v[i] = bin.charCodeAt(i);
    return buf;
  }
  var _COIN_B64 = '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';
  var _TICK_B64 = 'UklGRioGAABXQVZFZm10IBAAAAABAAEAIlYAAESsAAACABAAZGF0YQYGAAAAAGgizTu0Rao91iVuBBLik8e1u2/BMNdN93gZ6jSiQiw/hCvMDPbqtc5Cv4PADtJL76kQki2hPoU/GTBrFKbzOdavw7nABs4U6CEI7CXSOcU+lDM2G//7+d3ZyP7BGMu54QAAHR5WNAE99zUdIeADzuWezjzEPslI3GP4ShZPLlE6STcWJjMLl+3d1FfHcMjK12HxlQ7iJ9A2lzcYKt4RMfVw2zbLoMhD1BHrHQcwIZoy7zYkLdAXf/w44rvPvMmz0YHlAABaGs0tYzU6L/scZQMU6cnUscsU0L7gVvmBE4coCTNjMFQhzQnj7z/aas5gz8/cNfPDDOgi+C+nMNckow+K9gHgzdGJz7nZru06BgsdSSwTMIEn1xTv/PDlwtWC0HrXz+gAABAXFSi5LlUpXRn4AvDrLto50hDWpeQr+hIReCOqLFgqKx2UCObx9t6b1HLVNOHN9CsLjB77KZQqPiCvDbn3/+OS15bVgN7373MFaxnCJhMqkyI9ElH9MekI23DWidy16wAALxQUI+QoLCQyFpkCce7m3vDXTNsP6Ob68A4LHxcnDyWHGYIHqfMV4wXawtoM5TP2xgm8Gr4kQyU3HPoLwfh+557c4dqv4vjxxQQ/Fush0iRCHvYPp/0K7KXfoNv34D3uAACqEbMeySOoH20TRgKi8Ajj8Nzh3wzrifsTDSsbNiJvIFcWkgYz9bLmw95o32nobfeNCGYXJyCcILIYewqp+Y3qCOGE31jmuPMsBHgTrx06IHsa+A3y/Yjur+Mq4NbkdfAAAHYP3hpSH7UbABH9AY3ypuZR4ePjqu0X/HELxxfwHWIcjRPABYz22unp4nnjW+t/+HwHehQkHIocnRUsCXP6O+3m5JLjjOlB9acDChH7GTQcLRc6DDT+tvA45yTkOuhm8gAAiA2EF2kbPxjhDr4BO/TQ6SXlZuf075T8AwrPFDQa1xgcEQgFuvee7IvmCefv7W/5jQbrEaEY+hjqEgcIJfuT70joHudZ7Jj2MgPpDrwWrxhIFLMKbf6f8lDqnucy6xj0AADXC5QU/Rc4FQUNhgGz9ZXsgOh46vXxAv3DCDYS7ha9FfoOZwTD+ArvuOkn6jDwQfq7Ba8PjhXcFY0QBwfA+6DxPus66s3uxffMAg0N5hOaFcARXQmf/kr0Be2p6svtlfUAAF0KAhL+FJISZQtVAf32Au9v6yjttfNh/asH8A8RFAcTGw3aA6r5KPGA7OHsKvL4+gQFug3dEiETfA4mBkj8a/PW7fHs8/DM+HICbAtqEecSiQ8yCMv+wfVk71PtEfDi9gAAEgnDD18SQRD5CSsBHfgh8QDugu8+9bX9tgbyDZARpxB4C18DdfoC8/DuRO/k85n7ZAQDDIIQvhCtDGEFv/z99BrwUu/U8rL5JAL/CT0PixCYDSwH8v4I93fxqO8O8gX4AADwB8sNFBA5DroIBQEZ+fzyP/CR8Zb2//3gBTUMXw+SDgoK8wIm+6H0EfFb8Wf1JvzYA4MKcg6nDhgLtQQn/V32FvJn8Xn0fPrgAb8IVg17DuYLRwYU/yf4R/Oy8czzBPkAAPIGEgwSDnMMowflAPX5nPQ38l/zw/c//iQFrwp0DcEMyQiVAsH7Dfbu8i/zuvah/F0DMwmlDNMMtgkfBIL9kffT8zrz6fUs+6QBqAesC6wMaQp+BTH/Ivne9HzzUvXk+QAAFAaRClEM5QqvBsgAt/oI9u/z8vTK+Hf+gARZCcYLKQuwB0ICSfxL95D0yfTi9w398QINCBELOQt/CJsD0v2f+Fj10vQs98b7bwGzBjcKFwsdCc4ES//9+UL2DPWn9qf6AABSBT8JxwqJCdkFrwBg+0f3cfVU9rH5qP7wAy4ITQrECboG+gHA/GH4/vUv9ub4a/2TAgwHrwnSCXAHKAMX/ov5rfY49kb4TfxBAd0F8Ai0CfkHNQRi/736efdq9tL3UvsAAKgEFwhuCVgIHgWZAPP7XvjC9on3evrT/nIDKQcECYwI4wW7ASj9Vfk992n3yfm+/UECKgZ5CJgIggbDAlX+WfrX93D3Pfk=';
  var _coinBuf = null, _tickBuf = null;
  var _customCoinFile = null, _customTickFile = null;
  var _soundAssetVersion = null;

  function _soundAssetUrl(filename) {
    var url = '/' + filename;
    if (_soundAssetVersion && _soundAssetVersion > 0) {
      url += '?v=' + _soundAssetVersion;
    }
    return url;
  }

  // Try to load a custom sound file via XHR, fall back to base64 built-in
  function _loadSoundFile(url, fallbackB64, callback) {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', url, true);
    xhr.responseType = 'arraybuffer';
    xhr.onload = function () {
      if (xhr.status === 200 && xhr.response && xhr.response.byteLength > 0) {
        var ctx = _getAudioCtx(); if (!ctx) { callback(null); return; }
        ctx.decodeAudioData(xhr.response, function (buf) { callback(buf); }, function () {
          // Decode failed, use fallback
          var ctx2 = _getAudioCtx(); if (!ctx2) { callback(null); return; }
          ctx2.decodeAudioData(_b64ToArrayBuffer(fallbackB64), function (b) { callback(b); });
        });
      } else {
        // File not found, use fallback
        var ctx3 = _getAudioCtx(); if (!ctx3) { callback(null); return; }
        ctx3.decodeAudioData(_b64ToArrayBuffer(fallbackB64), function (b) { callback(b); });
      }
    };
    xhr.onerror = function () {
      var ctx4 = _getAudioCtx(); if (!ctx4) { callback(null); return; }
      ctx4.decodeAudioData(_b64ToArrayBuffer(fallbackB64), function (b) { callback(b); });
    };
    xhr.send();
  }

  function _loadSounds() {
    var ctx = _getAudioCtx(); if (!ctx) return;
    if (!_coinBuf) {
      if (_customCoinFile) {
        _loadSoundFile(_soundAssetUrl(_customCoinFile), _COIN_B64, function (b) { _coinBuf = b; });
      } else {
        ctx.decodeAudioData(_b64ToArrayBuffer(_COIN_B64), function(b){ _coinBuf = b; });
      }
    }
    if (!_tickBuf) {
      if (_customTickFile) {
        _loadSoundFile(_soundAssetUrl(_customTickFile), _TICK_B64, function (b) { _tickBuf = b; });
      } else {
        ctx.decodeAudioData(_b64ToArrayBuffer(_TICK_B64), function(b){ _tickBuf = b; });
      }
    }
  }
  var _coinSource = null; // active looping source for coin insert sound
  function _playBuf(buf) {
    var ctx = _getAudioCtx(); if (!ctx || !buf) return;
    try { var s = ctx.createBufferSource(); s.buffer = buf; s.connect(ctx.destination); s.start(0); } catch(e){}
  }
  // Coin Insert Sound: loops while modal is open
  function startCoinSound() {
    var ctx = _getAudioCtx(); if (!ctx || !_coinBuf) return;
    if (ctx.state === 'suspended') ctx.resume();
    stopCoinSound(); // stop any existing loop
    try {
      _coinSource = ctx.createBufferSource();
      _coinSource.buffer = _coinBuf;
      _coinSource.loop = true;
      _coinSource.connect(ctx.destination);
      _coinSource.start(0);
    } catch(e){}
  }
  function stopCoinSound() {
    if (_coinSource) { try { _coinSource.stop(); } catch(e){} _coinSource = null; }
  }
  // Tick Sound: plays once per coin detection
  function playTickSound() {
    if (!_soundEnabled.tick) return;
    var ctx = _getAudioCtx(); if (ctx && ctx.state === 'suspended') ctx.resume();
    _playBuf(_tickBuf);
  }
  // Pre-load on first user interaction (browser autoplay policy)
  document.addEventListener('click', function _initSounds() {
    _loadSounds(); document.removeEventListener('click', _initSounds);
  }, { once: true });


  // DOM refs
  var businessName = document.getElementById('business-name');
  var portalName = document.getElementById('portal-name');
  var portalLogo = document.getElementById('portal-logo');
  var portalHero = document.getElementById('portal-hero');
  var portalHeroImage = document.getElementById('portal-hero-image');
  var operatorFooter = document.getElementById('operator-footer');
  var descriptionMeta = document.querySelector('meta[name="description"]');
  var applicationNameMeta = document.querySelector('meta[name="application-name"]');
  var appleApplicationNameMeta = document.querySelector('meta[name="apple-mobile-web-app-title"]');
  var wanBadge = document.getElementById('wan-badge');
  var wanLabel = wanBadge ? wanBadge.querySelector('.wan-label') : null;
  var statusPanel = document.getElementById('status-panel');
  var statusValue = document.getElementById('status-value');
  var statusDetail = document.getElementById('status-detail');
  var validityNotice = document.getElementById('validity-notice');
  var validityTime = document.getElementById('validity-time');
  var devicePanel = document.getElementById('device-panel');
  var deviceIp = document.getElementById('device-ip');
  var deviceMac = document.getElementById('device-mac');
  var openCoinBtn = document.getElementById('open-coin-btn');
  var openCoinLabel = document.getElementById('open-coin-label');
  var connectedActions = document.getElementById('connected-actions');
  var pausedActions = document.getElementById('paused-actions');
  var btnPause = document.getElementById('btn-pause');
  var btnResume = document.getElementById('btn-resume');
  var btnAddTime = document.getElementById('btn-add-time');
  var addTimeLabel = document.getElementById('add-time-label');
  var btnAddTimePaused = document.getElementById('btn-add-time-paused');
  var addTimePausedLabel = document.getElementById('add-time-paused-label');
  var ratesBtn = document.getElementById('toggle-rates-btn');
  var ratesPanel = document.getElementById('premium-rates-panel');
  var ratesBody = document.getElementById('rates-body');
  var coinBtnNotice = document.getElementById('coin-btn-notice');
  var freeTimeSection = document.getElementById('free-time-section');
  var btnFreeTime = document.getElementById('btn-free-time');
  var freeTimeHint = document.getElementById('free-time-hint');
  var voucherSection = document.getElementById('voucher-section');
  var btnVoucher = document.getElementById('btn-voucher');

  // Modal refs
  var modal = document.getElementById('coin-modal');
  var closeBtn = document.getElementById('close-coin-btn');
  var backdrop = modal ? modal.querySelector('[data-close]') : null;
  var balanceEl = document.getElementById('balance-min');
  var coinBalanceRow = document.getElementById('coin-balance-row');
  var coinModalTitle = document.getElementById('coin-modal-title');
  var countdownEl = document.getElementById('countdown');
  var coinCountdownRow = document.getElementById('coin-countdown-row');
  var connectBtn = document.getElementById('connect-btn');
  var coinAmountEl = document.getElementById('coin-amount');
  var coinCountRow = document.getElementById('coin-count-row');
  var coinCountEl = document.getElementById('coin-count');
  var coinCountLabelEl = document.getElementById('coin-count-label');

  // Voucher modal refs
  var voucherModal = document.getElementById('voucher-modal');
  var closeVoucherBtn = document.getElementById('close-voucher-btn');
  var voucherBackdrop = voucherModal ? voucherModal.querySelector('[data-close]') : null;
  var voucherInput = document.getElementById('voucher-input');
  var voucherError = document.getElementById('voucher-error');
  var redeemBtn = document.getElementById('redeem-btn');

  // Theme is set by operator via admin settings (portal_theme).
  // Applied from the status API response in updateStatus().
  function applyTheme(t) {
    document.body.className = (t === 'light') ? 'theme-light' : 'theme-premium-dark';
  }

  function safeAssetFilename(value) {
    value = String(value || '');
    return /^[A-Za-z0-9_.-]+$/.test(value) ? value : '';
  }

  function applyImageAsset(image, container, customFile, fallbackFile, version) {
    if (!image) return;
    var safeFile = safeAssetFilename(customFile);
    var desired = '/' + (safeFile || fallbackFile);
    if (safeFile && Number(version || 0) > 0) desired += '?v=' + Number(version);
    if (image.getAttribute('data-current-src') === desired) return;
    image.setAttribute('data-current-src', desired);
    image.setAttribute('data-fallback-used', safeFile ? '0' : '1');
    image.onload = function () {
      image.style.display = '';
      if (container) container.style.display = '';
    };
    image.onerror = function () {
      if (image.getAttribute('data-fallback-used') !== '1') {
        image.setAttribute('data-fallback-used', '1');
        image.setAttribute('data-current-src', '/' + fallbackFile);
        image.src = '/' + fallbackFile;
      } else {
        image.style.display = 'none';
        if (container) container.style.display = 'none';
      }
    };
    image.src = desired;
  }

  // State
  var state = {
    connected: false,
    paused: false,
    minutesRemaining: 0,
    expiresAt: 0,
    validityExpiresAt: 0,
    mac: '',
    coinCount: 0,
    secondsLeft: TIMEOUT_S,
    countdownTimer: null,
    pollTimer: null,
    coinPollTimer: null,
    coinReadyTimer: null,
    remainingTimer: null,
    roamRetryTimer: null,
    hideDeviceInfo: false,
    hidePauseButton: false,
    freeTimeEnabled: false,
    showVoucher: false,
    lastCreditedAt: 0,
    sessionMinutesAdded: 0,
    sessionAmountPhp: 0,
    modalBaseMinutes: 0,
    coinFinalizing: false,
    coinPreparing: false,
    wanOnline: false,
    coinslotOnline: false,
    coinslotBusy: false,
    coinslotReady: false,
    trialExpired: false,
    showCoin: true,
    voucherRedeeming: false
  };

  // ── XHR Helper ──────────────────────────────────────────────────────────
  function xhr(method, url, body, cb) {
    try {
      var req = new XMLHttpRequest();
      req.open(method, url, true);
      if (body) req.setRequestHeader('Content-Type', 'application/json');
      req.timeout = 5000;
      req.onload = function () {
        try { cb(null, JSON.parse(req.responseText)); } catch (e) { cb(e, null); }
      };
      req.onerror = req.ontimeout = function () { cb(new Error('network'), null); };
      req.send(body ? JSON.stringify(body) : null);
    } catch (e) { cb(e, null); }
  }

  // ── Authoritative device identity helpers ────────────────────────────────
  function _fpQuery(url) {
    var sep = url.indexOf('?') === -1 ? '?' : '&';
    var did = window.__TARAKIFI_DEVICE_ID__ || '';
    if (did) url += sep + 'device_id=' + encodeURIComponent(did);
    return url;
  }
  function _fpBody(body) {
    var obj = body || {};
    var did = window.__TARAKIFI_DEVICE_ID__ || '';
    if (did) obj.device_id = did;
    return obj;
  }

  // ── Format time ─────────────────────────────────────────────────────────
  function formatMinutes(m) {
    m = Math.round(m);
    if (m >= 60) {
      var h = Math.floor(m / 60);
      var mm = m % 60;
      return h + 'h ' + (mm < 10 ? '0' : '') + mm + 'm';
    }
    return m + ' min';
  }

  function formatHMS(secs) {
    if (secs < 0) secs = 0;
    var h = Math.floor(secs / 3600);
    var m = Math.floor((secs % 3600) / 60);
    var s = Math.floor(secs % 60);
    return (h < 10 ? '0' : '') + h + ':' + (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s;
  }

  function formatExpiry(epochSeconds) {
    var date = new Date(Number(epochSeconds || 0) * 1000);
    if (!epochSeconds || isNaN(date.getTime())) return '';
    var months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    var hour = date.getHours();
    var minute = date.getMinutes();
    var period = hour >= 12 ? 'PM' : 'AM';
    hour = hour % 12 || 12;
    return months[date.getMonth()] + ' ' + date.getDate() + ', ' +
      date.getFullYear() + ', ' + hour + ':' + (minute < 10 ? '0' : '') +
      minute + ' ' + period;
  }

  function updateValidityNotice() {
    if (!validityNotice || !validityTime) return;
    var visible = state.validityExpiresAt > 0 && (state.connected || state.paused);
    validityNotice.style.display = visible ? '' : 'none';
    validityTime.textContent = visible ? formatExpiry(state.validityExpiresAt) : '';
  }

  // ── UI Updates ──────────────────────────────────────────────────────────
  function setWan(online) {
    if (!wanBadge) return;
    wanBadge.className = 'wan-badge ' + (online ? 'wan-badge--online' : 'wan-badge--offline');
    if (wanLabel) wanLabel.textContent = online ? 'Internet: Online' : 'Internet: Offline';
  }

  function updateActionAvailability() {
    var creditDisabled = !state.wanOnline || state.trialExpired;
    var coinDisabled = !state.showCoin || creditDisabled || !state.coinslotOnline || state.coinslotBusy || state.coinPreparing;
    [openCoinBtn, btnAddTime, btnAddTimePaused].forEach(function (button) {
      if (!button) return;
      button.disabled = coinDisabled;
      button.setAttribute('aria-disabled', coinDisabled ? 'true' : 'false');
    });
    if (btnVoucher) {
      btnVoucher.disabled = creditDisabled;
      btnVoucher.setAttribute('aria-disabled', creditDisabled ? 'true' : 'false');
    }
    if (redeemBtn) {
      redeemBtn.disabled = creditDisabled || state.voucherRedeeming;
      redeemBtn.setAttribute('aria-disabled', redeemBtn.disabled ? 'true' : 'false');
    }
    if (btnFreeTime) btnFreeTime.disabled = state.trialExpired;

    var coinLabel = state.coinPreparing ? 'Preparing...' :
      (state.coinslotBusy ? 'Coinslot Busy' :
        (!state.coinslotOnline ? 'Coinslot Offline' : 'Insert Coin'));
    var addLabel = state.coinPreparing ? 'Preparing...' :
      (state.coinslotBusy ? 'Coinslot Busy' :
        (!state.coinslotOnline ? 'Coinslot Offline' : '+ Add Time'));
    if (openCoinLabel) openCoinLabel.textContent = coinLabel;
    if (addTimeLabel) addTimeLabel.textContent = addLabel;
    if (addTimePausedLabel) addTimePausedLabel.textContent = addLabel;
  }

  function updateUI(data) {
    if (!data) return;
    applyPortalBranding(data);
    // Operator theme
    if (data.portal_theme) applyTheme(data.portal_theme);
    // MAC / IP
    if (data.mac && deviceMac) deviceMac.textContent = data.mac;
    if (data.client_ip && deviceIp) deviceIp.textContent = data.client_ip;
    state.mac = data.mac || '';
    state.trialExpired = data.trial_expired === true;
    state.validityExpiresAt = Number(data.validity_expires_at || 0);
    state.hidePauseButton = data.hide_pause_button === true;

    // Trial mode badge + expired lockout
    var trialBadge = document.getElementById('portal-trial-badge');
    if (trialBadge) {
      if (data.trial_expired) {
        trialBadge.style.display = '';
        trialBadge.style.background = '#7f1d1d';
        trialBadge.style.borderColor = '#dc2626';
        trialBadge.querySelector('span').innerHTML = '&#9940; TRIAL EXPIRED';
        trialBadge.querySelector('span').style.color = '#fca5a5';
        var cdEl = document.getElementById('portal-trial-countdown');
        if (cdEl) { cdEl.textContent = 'Contact your vendor to activate a license.'; cdEl.style.color = '#fca5a5'; }
      } else if (data.is_trial) {
        trialBadge.style.display = '';
        var cdEl = document.getElementById('portal-trial-countdown');
        if (cdEl) cdEl.textContent = 'Trial — activate a license to remove';
      } else {
        trialBadge.style.display = 'none';
      }
    }

    // Sound settings from server
    if (data.portal_tick_sound_enabled !== undefined) _soundEnabled.tick = data.portal_tick_sound_enabled;
    // Custom sound files reload when either the filename or asset version changes.
    var nextSoundAssetVersion = Number(data.portal_asset_version || 0);
    var soundAssetsChanged = _soundAssetVersion !== null &&
      nextSoundAssetVersion !== _soundAssetVersion;
    _soundAssetVersion = nextSoundAssetVersion;
    var reloadSounds = false;
    if (data.portal_coin_sound_file !== undefined &&
        (data.portal_coin_sound_file !== (_customCoinFile || '') || soundAssetsChanged)) {
      _customCoinFile = data.portal_coin_sound_file || null;
      _coinBuf = null;
      reloadSounds = true;
    }
    if (data.portal_tick_sound_file !== undefined &&
        (data.portal_tick_sound_file !== (_customTickFile || '') || soundAssetsChanged)) {
      _customTickFile = data.portal_tick_sound_file || null;
      _tickBuf = null;
      reloadSounds = true;
    }
    if (reloadSounds) _loadSounds();
    // Hide device info if configured
    if (data.hide_device_info) {
      state.hideDeviceInfo = true;
      if (devicePanel) devicePanel.style.display = 'none';
    } else {
      state.hideDeviceInfo = false;
      if (devicePanel) devicePanel.style.display = '';
    }

    // Free time
    if (data.free_time_enabled) {
      state.freeTimeEnabled = true;
      if (freeTimeSection) freeTimeSection.style.display = '';
      if (freeTimeHint) freeTimeHint.textContent = data.free_time_minutes + ' min free';
    } else {
      state.freeTimeEnabled = false;
      if (freeTimeSection) freeTimeSection.style.display = 'none';
    }

    // Voucher
    if (data.show_voucher) {
      state.showVoucher = true;
      if (voucherSection) voucherSection.style.display = '';
    } else {
      state.showVoucher = false;
      if (voucherSection) voucherSection.style.display = 'none';
    }

    state.showCoin = data.show_coin !== false;

    // WAN status
    setWan(data.wan_online !== false);
    state.wanOnline = data.wan_online !== false;
    state.coinslotOnline = data.coinslot_online !== false;
    state.coinslotBusy = data.coinslot_busy === true;
    state.coinslotReady = data.coinslot_ready === true;

    if (data.connected) {
      state.connected = true; state.paused = false;
      state.minutesRemaining = data.minutes_remaining || 0;
      state.expiresAt = data.expires_at || 0;
      statusPanel.className = 'status-panel connected';
      statusValue.textContent = 'Connected';
      statusDetail.style.display = '';
      statusDetail.innerHTML = '<strong id="live-remaining" style="font-variant-numeric:tabular-nums;letter-spacing:.02em">' + formatHMS(state.expiresAt ? Math.max(0, state.expiresAt - Math.floor(Date.now()/1000)) : state.minutesRemaining * 60) + '</strong> remaining';
      startRemainingCountdown();
      if (connectedActions) connectedActions.style.display = '';
      if (btnAddTime) btnAddTime.style.display = state.showCoin ? '' : 'none';
      if (btnPause) btnPause.style.display = state.hidePauseButton ? 'none' : '';
      if (pausedActions) pausedActions.style.display = 'none';
      if (openCoinBtn) openCoinBtn.parentElement.style.display = 'none';
    } else if (data.paused) {
      state.connected = false; state.paused = true;
      state.minutesRemaining = data.minutes_remaining || 0;
      statusPanel.className = 'status-panel paused';
      statusValue.textContent = 'Paused';
      statusDetail.style.display = '';
      stopRemainingCountdown();
      statusDetail.innerHTML = '<strong>' + formatMinutes(state.minutesRemaining) + '</strong> saved';
      if (connectedActions) connectedActions.style.display = 'none';
      if (pausedActions) pausedActions.style.display = '';
      if (btnAddTimePaused) btnAddTimePaused.style.display = state.showCoin ? '' : 'none';
      if (openCoinBtn) openCoinBtn.parentElement.style.display = 'none';
    } else {
      state.connected = false; state.paused = false;
      statusPanel.className = 'status-panel disconnected';
      statusValue.textContent = 'Disconnected';
      statusDetail.style.display = 'none';
      stopRemainingCountdown();
      if (connectedActions) connectedActions.style.display = 'none';
      if (pausedActions) pausedActions.style.display = 'none';
      if (openCoinBtn) openCoinBtn.parentElement.style.display = state.showCoin ? '' : 'none';
    }
    updateValidityNotice();
    updateActionAvailability();
  }

  function applyPortalBranding(data) {
    var name = typeof data.business_name === 'string' && data.business_name ? data.business_name : 'TarakiFi';
    var subtitle = typeof data.portal_name === 'string' ? data.portal_name : 'TarakiFi WiFi';
    var footer = typeof data.portal_footer_text === 'string' ? data.portal_footer_text : '';
    if (businessName) {
      businessName.textContent = name;
      businessName.hidden = data.show_business_name === false;
    }
    if (portalName) {
      portalName.textContent = subtitle;
      portalName.hidden = !subtitle;
    }
    if (operatorFooter) {
      operatorFooter.textContent = footer;
      operatorFooter.hidden = !footer;
    }
    applyImageAsset(
      portalLogo, null, data.portal_logo_file, 'logo.png', data.portal_asset_version
    );
    applyImageAsset(
      portalHeroImage, portalHero, data.portal_hero_file, 'hero.jpg',
      data.portal_asset_version
    );
    document.title = subtitle ? name + ' - ' + subtitle : name;
    if (descriptionMeta) descriptionMeta.content = 'Connect to ' + name + ' WiFi.';
    if (applicationNameMeta) applicationNameMeta.content = name;
    if (appleApplicationNameMeta) appleApplicationNameMeta.content = name;
  }

  // ── Live Remaining Countdown ─────────────────────────────────────────────
  function startRemainingCountdown() {
    stopRemainingCountdown();
    state.remainingTimer = setInterval(function () {
      if (state.paused || !state.connected || !state.expiresAt) return;
      var nowSec = Math.floor(Date.now() / 1000);
      var secsLeft = state.expiresAt - nowSec;
      if (secsLeft <= 0) {
        stopRemainingCountdown();
        window.location.replace(PORTAL_URL + '?expired=1&t=' + Date.now());
        return;
      }
      var el = document.getElementById('live-remaining');
      if (el) el.textContent = formatHMS(secsLeft);
    }, 1000);
  }
  function stopRemainingCountdown() {
    if (state.remainingTimer) { clearInterval(state.remainingTimer); state.remainingTimer = null; }
  }

  // ── Rates ───────────────────────────────────────────────────────────────
  function loadRates() {
    xhr('GET', API + '/rates', null, function (err, data) {
      if (err || !data) return;
      if (data.timeout_seconds) TIMEOUT_S = data.timeout_seconds;
      applyPortalBranding(data);
      if (data.show_rates && data.rates && data.rates.length && ratesBody) {
        var html = '';
        for (var i = 0; i < data.rates.length; i++) {
          var r = data.rates[i];
          html += '<tr><td>\u20B1' + r.php + '</td><td>' + formatMinutes(r.minutes) + '</td></tr>';
        }
        ratesBody.innerHTML = html;
      }
    });
  }

  // ── Status Polling ──────────────────────────────────────────────────────
  function pollStatus() {
    xhr('GET', _fpQuery(API + '/status'), null, function (err, data) {
      if (err) {
        state.wanOnline = false;
        setWan(false);
        updateActionAvailability();
        return;
      }
      setWan(true);
      var becameConnected = statusInitialized && !state.connected && data.connected;
      updateUI(data);
      statusInitialized = true;
      if (data.roaming_pending && !state.roamRetryTimer) {
        state.roamRetryTimer = setTimeout(function () {
          state.roamRetryTimer = null;
          pollStatus();
        }, 1200);
      } else if (!data.roaming_pending && state.roamRetryTimer) {
        clearTimeout(state.roamRetryTimer);
        state.roamRetryTimer = null;
      }
      if (captiveMode && (data.identity_rebound || becameConnected) && data.connected && !captiveLoginCompleting) {
        captiveLoginCompleting = true;
        setTimeout(function () { completeCaptiveLogin(0); }, 100);
      }
    });
  }

  function completeCaptiveLogin(attempt) {
    if (!captiveMode) {
      captiveLoginCompleting = false;
      return;
    }
    captiveLoginCompleting = true;
    xhr('GET', _fpQuery(API + '/status'), null, function (err, data) {
      if (!err && data) {
        setWan(true);
        updateUI(data);
        if (data.connected) {
          var successUrl = '';
          if (captiveMode === 'apple') {
            successUrl = 'http://captive.apple.com/hotspot-detect.html';
          } else if (captiveMode === 'android') {
            successUrl = 'http://connectivitycheck.gstatic.com/generate_204';
          } else if (captiveMode === 'windows') {
            successUrl = 'http://www.msftconnecttest.com/connecttest.txt';
          }
          if (successUrl) window.location.replace(successUrl);
          return;
        }
      }

      if (attempt < 7) {
        setTimeout(function () { completeCaptiveLogin(attempt + 1); }, 350);
      } else {
        captiveLoginCompleting = false;
        pollStatus();
      }
    });
  }

  // ── Coin Modal ──────────────────────────────────────────────────────────
  function openModal() {
    // Validate WAN and coinslot before opening
    if (!state.wanOnline) { showNotice('No internet connection. Cannot insert coin.', 'error'); return; }
    if (state.trialExpired) { showNotice('Service is unavailable. Please contact the operator.', 'error'); return; }
    if (!state.coinslotOnline) { showNotice('No coinslot available. Please check the device.', 'error'); return; }
    if (state.coinslotBusy) { showNotice('Coinslot Busy. Another customer is inserting coins.', 'warn'); return; }
    if (state.coinPreparing) return;
    state.coinPreparing = true;
    updateActionAvailability();
    xhr('POST', API + '/insert-coin', _fpBody(null), function (err, data) {
      if (err) {
        state.coinPreparing = false;
        updateActionAvailability();
        showNotice('Coinslot is unavailable. Please try again.', 'error');
        return;
      }
      if (data && data.error === 'another_customer_waiting') {
        state.coinPreparing = false;
        state.coinslotBusy = true;
        updateActionAvailability();
        showNotice('Coinslot Busy. Another customer is inserting coins.', 'warn');
        return;
      }
      if (data && data.error === 'abuse_blocked') {
        state.coinPreparing = false;
        updateActionAvailability();
        showNotice('Too many empty opens. Please wait ' + (data.cooldown_remaining || 120) + 's.', 'error');
        return;
      }
      if (data && data.error === 'blocked') {
        state.coinPreparing = false;
        updateActionAvailability();
        showNotice('Your device has been blocked by the administrator.', 'error');
        return;
      }
      if (data && data.error) {
        state.coinPreparing = false;
        if (data.error === 'wan_offline') state.wanOnline = false;
        updateActionAvailability();
        showNotice(data.message || 'Unable to prepare the coinslot.', 'error');
        return;
      }
      showCoinPreparing();
      waitForCoinReady(0);
    });
  }

  function showCoinPreparing() {
      stopCoinModalActivity();
      modal.className = 'modal open';
      modal.setAttribute('aria-hidden', 'false');
      if (coinModalTitle) coinModalTitle.textContent = 'Preparing coinslot...';
      if (coinBalanceRow) coinBalanceRow.style.display = 'none';
      if (coinCountRow) coinCountRow.style.display = 'none';
      if (coinCountdownRow) coinCountdownRow.style.display = 'none';
      if (connectBtn) { connectBtn.disabled = true; connectBtn.textContent = 'Please wait...'; }
  }

  function waitForCoinReady(attempt) {
    if (!state.coinPreparing) return;
    xhr('GET', _fpQuery(API + '/coin-status'), null, function (err, data) {
      if (!err && data && data.coinslot_ready) {
        activateCoinModal();
        return;
      }
      if (!err && data && data.coinslot_busy) {
        failCoinPreparation('Coinslot Busy. Another customer is inserting coins.');
        return;
      }
      if (attempt >= COIN_READY_MAX_ATTEMPTS) {
        failCoinPreparation('Coinslot did not respond. Please try again.');
        return;
      }
      state.coinReadyTimer = setTimeout(function () {
        state.coinReadyTimer = null;
        waitForCoinReady(attempt + 1);
      }, COIN_READY_POLL_MS);
    });
  }

  function failCoinPreparation(message) {
    state.coinPreparing = false;
    hideCoinModal();
    updateActionAvailability();
    showNotice(message, 'error');
    xhr('POST', API + '/cancel-insert', _fpBody(null), function () {});
  }

  function activateCoinModal() {
      state.coinPreparing = false;
      state.coinslotReady = true;
      updateActionAvailability();
      if (coinModalTitle) coinModalTitle.textContent = 'Insert coin into the vendo';
      if (coinBalanceRow) coinBalanceRow.style.display = '';
      if (coinCountRow) coinCountRow.style.display = '';
      if (coinCountdownRow) coinCountdownRow.style.display = '';
      if (connectBtn) connectBtn.disabled = false;
      startCoinSound(); // loop background sound while modal is open
      state.secondsLeft = TIMEOUT_S;
      state.coinCount = 0;
      state.lastCreditedAt = 0;
      state.sessionMinutesAdded = 0;
      state.sessionAmountPhp = 0;
      // Capture current balance as baseline so sessionMinutesAdded is always
      // relative to what the customer had BEFORE opening this modal session.
      state.modalBaseMinutes = state.minutesRemaining;
      setCoinFinalizing(false);
      updateCoinCount(0);
      if (coinAmountEl) coinAmountEl.textContent = '\u20b10';
      if (balanceEl) balanceEl.textContent = '0';
      renderCountdown();
      // Done btn always enabled
      state.countdownTimer = setInterval(tick, 1000);
      state.coinPollTimer = setInterval(pollCoin, POLL_MS);
      pollCoin();
  }

  function hideCoinModal() {
    modal.className = 'modal';
    modal.setAttribute('aria-hidden', 'true');
    stopCoinModalActivity();
  }

  function stopCoinModalActivity() {
    stopCoinSound();
    if (state.countdownTimer) { clearInterval(state.countdownTimer); state.countdownTimer = null; }
    if (state.coinPollTimer) { clearInterval(state.coinPollTimer); state.coinPollTimer = null; }
    if (state.coinReadyTimer) { clearTimeout(state.coinReadyTimer); state.coinReadyTimer = null; }
  }

  function setCoinFinalizing(finalizing) {
    state.coinFinalizing = finalizing;
    if (!connectBtn) return;
    connectBtn.textContent = finalizing ? 'Activating...' : 'Done';
    connectBtn.disabled = finalizing || state.coinPreparing;
    connectBtn.setAttribute('aria-busy', finalizing ? 'true' : 'false');
    connectBtn.setAttribute('aria-disabled', finalizing ? 'true' : 'false');
  }

  function afterCoinFinalize(data) {
    state.coinPreparing = false;
    hideCoinModal();
    setCoinFinalizing(false);
    if (data && data.status === 'activated' && captiveMode) {
      completeCaptiveLogin(0);
    } else {
      pollStatus();
    }
  }

  function finishCoinRecovery() {
    hideCoinModal();
    setCoinFinalizing(false);
    showNotice('Your coin is saved. Access will activate automatically.', 'warn');
    pollStatus();
  }

  function retryCoinFinalize(attempt) {
    if (!state.coinFinalizing) return;
    xhr('POST', API + '/finish-coin', _fpBody(null), function (err, data) {
      if (!err && data && !data.error) {
        afterCoinFinalize(data);
        return;
      }
      verifyCoinFinalize(attempt);
    });
  }

  function verifyCoinFinalize(attempt) {
    if (!state.coinFinalizing) return;
    var url = API + '/coin-status';
    if (state.lastCreditedAt) url += '?last_credited_at=' + state.lastCreditedAt;
    xhr('GET', _fpQuery(url), null, function (coinErr, coinData) {
      if (!coinErr && coinData && coinData.finalized) {
        afterCoinFinalize({status: coinData.paused ? 'paused' : 'activated'});
        return;
      }
      xhr('GET', _fpQuery(API + '/status'), null, function (statusErr, statusData) {
        if (!statusErr && statusData && (statusData.connected || statusData.paused)) {
          afterCoinFinalize({status: statusData.paused ? 'paused' : 'activated'});
          return;
        }
        if (attempt >= COIN_FINALIZE_MAX_RETRIES) {
          finishCoinRecovery();
          return;
        }
        setTimeout(function () {
          retryCoinFinalize(attempt + 1);
        }, COIN_FINALIZE_RETRY_MS);
      });
    });
  }

  function finishCoin() {
    if (state.coinFinalizing || state.coinPreparing) return;
    setCoinFinalizing(true);
    stopCoinModalActivity();
    xhr('POST', API + '/finish-coin', _fpBody(null), function (err, data) {
      if (err || (data && data.error)) {
        verifyCoinFinalize(0);
        return;
      }
      afterCoinFinalize(data || {});
    });
  }

  function closeModal() {
    if (state.coinFinalizing) return;
    state.coinPreparing = false;
    state.coinFinalizing = true;
    hideCoinModal();
    xhr('POST', API + '/cancel-insert', _fpBody(null), function (err, data) {
      state.coinFinalizing = false;
      if (!err && data && data.status === 'activated') {
        if (captiveMode) completeCaptiveLogin(0);
        else pollStatus();
      }
    });
  }

  function tick() {
    state.secondsLeft -= 1;
    renderCountdown();
    if (state.secondsLeft <= 0) {
      finishCoin();
    }
  }

  function renderCountdown() {
    if (countdownEl) countdownEl.textContent = String(state.secondsLeft);
  }

  function updateCoinCount(n) {
    state.coinCount = n;
    if (coinCountEl) coinCountEl.textContent = String(n);
    if (coinCountLabelEl) coinCountLabelEl.textContent = n === 1 ? 'coin inserted' : 'coins inserted';
  }

  function pollCoin() {
    var url = API + '/coin-status';
    if (state.lastCreditedAt) url += '?last_credited_at=' + state.lastCreditedAt;
    url = _fpQuery(url);
    xhr('GET', url, null, function (err, data) {
      if (err || !data) return;
      if (data.received) {
        var newCount = Number(data.pending_coin_count || 0);
        var isNewCredit = newCount > state.coinCount;
        if (data.last_credited_at) state.lastCreditedAt = data.last_credited_at;
        state.sessionMinutesAdded = Number(data.pending_minutes || 0);
        state.sessionAmountPhp = Number(data.pending_amount_php || 0);
        if (isNewCredit) {
          updateCoinCount(newCount);
          playTickSound();
        }
        if (balanceEl) {
          balanceEl.textContent = formatMinutes(state.sessionMinutesAdded > 0 ? state.sessionMinutesAdded : 0);
          balanceEl.className = 'balance bump';
          setTimeout(function () { balanceEl.className = 'balance'; }, 200);
        }
        if (coinAmountEl) coinAmountEl.textContent = '\u20b1' + String(state.sessionAmountPhp);
        if (isNewCredit) {
          state.secondsLeft = TIMEOUT_S;
          renderCountdown();
        }
      } else if (data.finalized) {
        afterCoinFinalize({status: data.connected ? 'activated' : 'paused'});
      } else if (data.timeout) {
        hideCoinModal();
        state.coinFinalizing = false;
      }
    });
  }

  // ── Free Time ───────────────────────────────────────────────────────────
  function claimFreeTime() {
    if (btnFreeTime) btnFreeTime.disabled = true;
    xhr('POST', API + '/free-time', _fpBody(null), function (err, data) {
      if (btnFreeTime) btnFreeTime.disabled = false;
      if (err) { showNotice('Network error. Try again.', 'error'); return; }
      if (data && data.error) {
        showNotice(data.message || data.error, 'error');
        return;
      }
      if (data && data.success) {
        showNotice('Free time activated! ' + formatMinutes(data.minutes || 5), 'success');
        setTimeout(pollStatus, 1000);
      }
    });
  }

  // ── Voucher ─────────────────────────────────────────────────────────────
  function openVoucherModal() {
    if (!state.wanOnline) { showNotice('No internet connection. Voucher is unavailable.', 'error'); return; }
    if (state.trialExpired) { showNotice('Service is unavailable. Please contact the operator.', 'error'); return; }
    voucherModal.className = 'modal open';
    voucherModal.setAttribute('aria-hidden', 'false');
    if (voucherInput) { voucherInput.value = ''; voucherInput.focus(); }
    if (voucherError) voucherError.style.display = 'none';
  }

  function closeVoucherModal() {
    voucherModal.className = 'modal';
    voucherModal.setAttribute('aria-hidden', 'true');
  }

  function setVoucherRedeeming(active) {
    state.voucherRedeeming = active;
    if (redeemBtn) redeemBtn.textContent = active ? 'Redeeming...' : 'Redeem';
    updateActionAvailability();
  }

  function finishVoucherRedeem(minutes, verifiedStatus, validityExpiresAt) {
    setVoucherRedeeming(false);
    closeVoucherModal();
    if (voucherError) voucherError.style.display = 'none';
    showNotice(minutes > 0 ? 'Voucher redeemed! +' + formatMinutes(minutes) : 'Voucher redeemed!', 'success');
    if (Number(validityExpiresAt || 0) > 0) {
      state.validityExpiresAt = Number(validityExpiresAt);
    }

    if (verifiedStatus) {
      setWan(true);
      updateUI(verifiedStatus);
      statusInitialized = true;
      if (captiveMode && verifiedStatus.connected && !captiveLoginCompleting) {
        captiveLoginCompleting = true;
        setTimeout(function () { completeCaptiveLogin(0); }, 100);
      }
    } else {
      setTimeout(pollStatus, 100);
    }
  }

  function verifyVoucherRedeem(baseline, attempt) {
    xhr('GET', _fpQuery(API + '/status'), null, function (err, data) {
      if (!err && data) {
        var nowConnected = !!data.connected;
        var nowPaused = !!data.paused;
        var minutesIncreased = Number(data.minutes_remaining || 0) > baseline.minutes + 0.01;
        var expiryIncreased = Number(data.expires_at || 0) > baseline.expiresAt + 1;
        var newlyActive = !baseline.connected && !baseline.paused && (nowConnected || nowPaused);

        if (newlyActive || expiryIncreased || (baseline.paused && minutesIncreased)) {
          finishVoucherRedeem(0, data, data.validity_expires_at);
          return;
        }
      }

      if (attempt < 4) {
        setTimeout(function () { verifyVoucherRedeem(baseline, attempt + 1); }, 350);
        return;
      }

      setVoucherRedeeming(false);
      if (voucherError) {
        voucherError.textContent = 'Could not confirm redemption. Check your session status.';
        voucherError.style.display = '';
      }
    });
  }

  function redeemVoucher() {
    if (state.voucherRedeeming) return;
    if (!state.wanOnline) {
      if (voucherError) { voucherError.textContent = 'No internet connection.'; voucherError.style.display = ''; }
      return;
    }
    if (state.trialExpired) {
      if (voucherError) { voucherError.textContent = 'Service is unavailable.'; voucherError.style.display = ''; }
      return;
    }
    var code = voucherInput ? voucherInput.value.trim() : '';
    if (!code) {
      if (voucherError) { voucherError.textContent = 'Please enter a voucher code.'; voucherError.style.display = ''; }
      return;
    }
    var baseline = {
      connected: state.connected,
      paused: state.paused,
      minutes: Number(state.minutesRemaining || 0),
      expiresAt: Number(state.expiresAt || 0)
    };
    if (voucherError) voucherError.style.display = 'none';
    setVoucherRedeeming(true);
    xhr('POST', API + '/redeem-voucher', _fpBody({code: code}), function (err, data) {
      if (err) {
        verifyVoucherRedeem(baseline, 0);
        return;
      }
      if (data && data.error) {
        setVoucherRedeeming(false);
        if (voucherError) { voucherError.textContent = data.message || data.error; voucherError.style.display = ''; }
        return;
      }
      if (data && (data.success === true || data.status === 'ok')) {
        finishVoucherRedeem(
          Number(data.minutes || 0), null, Number(data.validity_expires_at || 0)
        );
        return;
      }
      setVoucherRedeeming(false);
      if (voucherError) {
        voucherError.textContent = 'Voucher response was not recognized. Please try again.';
        voucherError.style.display = '';
      }
    });
  }

  // ── Actions ─────────────────────────────────────────────────────────────
  function pauseSession() {
    xhr('POST', API + '/pause', _fpBody(null), function (err, data) {
      if (err || !data || data.error || data.status !== 'paused') {
        showNotice((data && data.message) || 'Unable to pause your time. Please try again.', 'error');
        return;
      }
      pollStatus();
    });
  }

  function resumeSession() {
    xhr('POST', API + '/resume', _fpBody(null), function (err, data) {
      if (err || !data || data.error || data.status !== 'resumed') {
        showNotice((data && data.message) || 'Unable to resume your time. Please try again.', 'error');
        return;
      }
      pollStatus();
    });
  }

  function showNotice(msg, type) {
    if (!coinBtnNotice) return;
    coinBtnNotice.textContent = msg;
    coinBtnNotice.style.display = 'block';
    if (type === 'error') {
      coinBtnNotice.style.background = '#1a0800';
      coinBtnNotice.style.color = '#ff4444';
      coinBtnNotice.style.border = '1px solid #cc3300';
    } else if (type === 'success') {
      coinBtnNotice.style.background = '#001a0a';
      coinBtnNotice.style.color = '#44ff88';
      coinBtnNotice.style.border = '1px solid #00cc44';
    } else {
      coinBtnNotice.style.background = '#1a1400';
      coinBtnNotice.style.color = '#ffb347';
      coinBtnNotice.style.border = '1px solid #ff8c00';
    }
    coinBtnNotice.style.borderRadius = '6px';
    coinBtnNotice.style.padding = '.5rem .75rem';
    coinBtnNotice.style.marginTop = '.5rem';
    coinBtnNotice.style.fontSize = '.85rem';
    coinBtnNotice.style.textAlign = 'center';
    setTimeout(function () { coinBtnNotice.style.display = 'none'; }, 5000);
  }

  // ── Event Listeners ─────────────────────────────────────────────────────
  if (openCoinBtn) openCoinBtn.addEventListener('click', function () { openModal(); });
  if (btnAddTime) btnAddTime.addEventListener('click', function () { openModal(); });
  if (btnAddTimePaused) btnAddTimePaused.addEventListener('click', function () { openModal(); });
  if (closeBtn) closeBtn.addEventListener('click', closeModal);
  if (backdrop) backdrop.addEventListener('click', closeModal);
  if (btnPause) btnPause.addEventListener('click', pauseSession);
  if (btnResume) btnResume.addEventListener('click', resumeSession);
  if (connectBtn) {
    connectBtn.addEventListener('click', function () {
      finishCoin();
    });
  }
  // Free time
  if (btnFreeTime) btnFreeTime.addEventListener('click', claimFreeTime);
  // Voucher
  if (btnVoucher) btnVoucher.addEventListener('click', openVoucherModal);
  if (closeVoucherBtn) closeVoucherBtn.addEventListener('click', closeVoucherModal);
  if (voucherBackdrop) voucherBackdrop.addEventListener('click', closeVoucherModal);
  if (redeemBtn) redeemBtn.addEventListener('click', redeemVoucher);
  if (voucherInput) {
    voucherInput.addEventListener('keydown', function (e) {
      if (e.keyCode === 13) redeemVoucher();
    });
  }
  // Rates toggle
  if (ratesBtn && ratesPanel) {
    ratesBtn.addEventListener('click', function () {
      var open = ratesPanel.style.display !== 'none';
      ratesPanel.style.display = open ? 'none' : 'block';
      ratesBtn.setAttribute('aria-expanded', open ? 'false' : 'true');
    });
  }
  // ESC closes modals
  document.addEventListener('keydown', function (e) {
    if (e.keyCode === 27) {
      if (modal.className.indexOf('open') !== -1) closeModal();
      if (voucherModal.className.indexOf('open') !== -1) closeVoucherModal();
    }
  });

  // ── Init ────────────────────────────────────────────────────────────────
  loadRates();
  pollStatus();
  state.pollTimer = setInterval(pollStatus, 5000);
})();
