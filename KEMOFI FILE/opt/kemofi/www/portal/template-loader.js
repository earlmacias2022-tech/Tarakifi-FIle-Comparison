/*
 * KemoFi exact portal template loader.
 * Presentation-only: the existing portal/app.js remains the source of truth
 * for sessions, coin, voucher, rates, pause/resume, WAN, and branding.
 */
(function () {
  'use strict';

  var ACTIVE_TEMPLATE_URL = 'templates/active.html';
  var COMPAT_STYLE_ID = 'kemofi-template-compat-style';
  var templateObserver = null;
  var templateMirrorTimer = null;
  var isPreview = /(?:^|[?&])preview=1(?:&|$)/.test(window.location.search || '');

  function requestText(url) {
    try {
      var request = new XMLHttpRequest();
      request.open('GET', url + '?_=' + Date.now(), false);
      request.send(null);
      if (request.status >= 200 && request.status < 300) return request.responseText || '';
    } catch (error) {}
    return '';
  }

  function addCompatStyle() {
    if (document.getElementById(COMPAT_STYLE_ID)) return;
    var style = document.createElement('style');
    style.id = COMPAT_STYLE_ID;
    style.textContent =
      '#kemofi-template-compat{position:absolute!important;left:-10000px!important;top:0!important;width:1px!important;height:1px!important;overflow:hidden!important;z-index:-1!important;opacity:0!important;pointer-events:none!important}' +
      '#kemofi-template-compat .kemofi-template-compat-control{position:absolute!important;left:-10000px!important;top:0!important;width:1px!important;height:1px!important;min-width:1px!important;min-height:1px!important;margin:0!important;padding:0!important;overflow:hidden!important;opacity:0!important;pointer-events:none!important;border:0!important}' +
      '#kemofi-template-compat #portal-hero,#kemofi-template-compat #wan-badge,#kemofi-template-compat #portal-trial-badge,#kemofi-template-compat #status-panel,#kemofi-template-compat #device-details,#kemofi-template-compat #device-panel,#kemofi-template-compat #free-time-section,#kemofi-template-compat #voucher-section,#kemofi-template-compat #coin-actions,#kemofi-template-compat #connected-actions,#kemofi-template-compat #paused-actions,#kemofi-template-compat #rates-section,#kemofi-template-compat #coin-btn-notice,#kemofi-template-compat #operator-footer{position:absolute!important;left:-10000px!important;top:0!important;width:1px!important;height:1px!important;min-width:1px!important;min-height:1px!important;margin:0!important;padding:0!important;overflow:hidden!important;opacity:0!important;pointer-events:none!important;border:0!important}' +
      '#kemofi-template-compat .modal,#kemofi-template-compat .modal.open{position:absolute!important;left:-10000px!important;top:0!important;width:1px!important;height:1px!important;z-index:-1!important;display:block!important;overflow:hidden!important;pointer-events:none!important;opacity:0!important;visibility:hidden!important}' +
      '#kemofi-template-compat .modal[aria-hidden="true"]{display:block!important}' +
      '#kemofi-template-compat .modal.open{display:block!important}' +
      '#kemofi-template-compat input{pointer-events:auto!important;position:static!important;width:auto!important;height:auto!important;opacity:1!important}';
    document.head.appendChild(style);
  }

  function compatibilityMarkup() {
    return '' +
      '<div id="kemofi-template-compat">' +
        '<div class="kemofi-template-compat-control brand-lockup" aria-label="KemoFi WiFi">' +
          '<img class="brand-logo-image" alt="" hidden>' +
          '<span id="business-name"></span><span id="brand-business-name"></span>' +
          '<span id="portal-name"></span>' +
        '</div>' +
        '<div id="portal-hero" class="kemofi-template-compat-control" aria-hidden="true"><img id="portal-hero-image" alt=""></div>' +
        '<div id="wan-badge" class="kemofi-template-compat-control wan-badge wan-badge--offline"><span class="wan-label">Internet: Offline</span></div>' +
        '<div id="portal-trial-badge" class="kemofi-template-compat-control"><span></span><span id="portal-trial-countdown"></span></div>' +
        '<div id="status-panel" class="kemofi-template-compat-control status-panel disconnected">' +
          '<span id="status-value">DISCONNECTED</span><span id="status-detail"></span>' +
          '<span id="remaining-time-data" data-state="disconnected">--</span><span id="session-policy"></span>' +
          '<span id="session-validity">--</span><span id="session-pauses-remaining">--</span>' +
        '</div>' +
        '<details id="device-details" class="kemofi-template-compat-control"><summary>Device details</summary><span id="device-ip">--</span><span id="device-mac">--</span></details>' +
        '<div id="device-panel" class="kemofi-template-compat-control"><span id="device-ip-copy"></span><span id="device-mac-copy"></span></div>' +
        '<div id="free-time-section" class="kemofi-template-compat-control"><button id="btn-free-time" type="button">Free WiFi</button><span id="free-time-hint"></span></div>' +
        '<div id="voucher-section" class="kemofi-template-compat-control"><button id="btn-voucher" type="button">Use Voucher</button></div>' +
        '<div id="coin-actions" class="kemofi-template-compat-control"><button id="open-coin-btn" type="button"><span id="open-coin-label">Insert Coin</span></button></div>' +
        '<div id="connected-actions" class="kemofi-template-compat-control"><button id="btn-add-time" type="button"><span id="add-time-label">Extend</span></button><button id="btn-pause" type="button">Pause</button></div>' +
        '<div id="paused-actions" class="kemofi-template-compat-control"><button id="btn-add-time-paused" type="button"><span id="add-time-paused-label">Extend</span></button><button id="btn-resume" type="button">Resume</button></div>' +
        '<div id="rates-section" class="kemofi-template-compat-control"><button id="toggle-rates-btn" type="button" aria-expanded="false">WiFi Rates</button></div>' +
        '<div id="coin-btn-notice" class="kemofi-template-compat-control action-notice" style="display:none"></div>' +
        '<div id="coin-modal" class="modal" aria-hidden="true"><div class="modal-backdrop" data-close></div><div class="coin-modal-card">' +
          '<button id="close-coin-btn" type="button">Close</button><div id="coin-modal-title">Insert Coin</div><div class="coin-ready">Coinslot Ready</div>' +
          '<div id="coin-balance-row"><span id="balance-min">00H 00M 00S</span></div><div id="coin-count-row"><span id="coin-count">0</span><span id="coin-count-label">Coins</span></div>' +
          '<div id="coin-countdown-row"><span id="countdown">60</span></div><div id="coin-policy"></div><div id="coin-amount">₱0</div>' +
          '<button id="connect-btn" type="button">Connect</button>' +
        '</div></div>' +
        '<div id="voucher-modal" class="modal" aria-hidden="true"><div class="modal-backdrop" data-close></div><div class="modal-card">' +
          '<button id="close-voucher-btn" type="button">Close</button><input id="voucher-input" type="text"><p id="voucher-error" style="display:none"></p><button id="redeem-btn" type="button">Redeem</button>' +
        '</div></div>' +
        '<div id="rates-modal" class="modal" aria-hidden="true"><div class="modal-backdrop" data-close></div><div class="modal-card">' +
          '<button id="close-rates-btn" type="button">Close</button><table><tbody id="rates-body"></tbody></table>' +
        '</div></div>' +
        '<div id="operator-footer" class="kemofi-template-compat-control"></div>' +
      '</div>';
  }

  function appendCompatibilityDom() {
    addCompatStyle();
    var previous = document.getElementById('kemofi-template-compat');
    if (previous && previous.parentNode) previous.parentNode.removeChild(previous);
    var wrapper = document.createElement('div');
    wrapper.innerHTML = compatibilityMarkup();
    while (wrapper.firstChild) document.body.appendChild(wrapper.firstChild);
  }

  function textOf(selector) {
    var element = document.querySelector(selector);
    return element ? (element.textContent || '').replace(/\s+/g, ' ').trim() : '';
  }

  function slots(name) {
    return document.querySelectorAll('[data-kemofi-slot="' + name + '"]');
  }

  function mirrorSlot(name, value) {
    var items = slots(name);
    for (var i = 0; i < items.length; i++) {
      var item = items[i];
      if (item.querySelector && item.querySelector('br')) {
        if (item.textContent !== value) item.textContent = value;
      } else if (item.children && item.children.length) {
        var child = item.firstChild;
        while (child && child.nodeType !== 3) child = child.nextSibling;
        if (child && child.nodeValue !== value + ' ') child.nodeValue = value + ' ';
      } else if (item.textContent !== value) {
        item.textContent = value;
      }
    }
  }

  function syncTemplateBranding() {
    var source = document.querySelector('.brand-logo-image');
    var fallback = 'kemofi-logo.webp';
    var sourceUrl = source && (source.getAttribute('data-asset-url') || source.getAttribute('src') || source.getAttribute('data-default-src')) || fallback;
    var logos = document.querySelectorAll('[data-kemofi-template-logo]');
    for (var i = 0; i < logos.length; i++) {
      var logo = logos[i];
      if (logo.getAttribute('data-kemofi-logo-url') !== sourceUrl) {
        logo.setAttribute('data-kemofi-logo-url', sourceUrl);
        logo.removeAttribute('data-kemofi-logo-fallback');
        logo.onerror = function () {
          if (this.getAttribute('data-kemofi-logo-fallback') === 'true') return;
          this.setAttribute('data-kemofi-logo-fallback', 'true');
          this.src = fallback;
        };
        logo.src = sourceUrl;
      }
      logo.hidden = false;
    }
  }

  function actionTargets(name) {
    return document.querySelectorAll('[data-kemofi-action="' + name + '"]');
  }

  function templateModal(kind) {
    return document.querySelector('[data-kemofi-template-modal="' + kind + '"]');
  }

  function templateModalFor(node) {
    while (node && node !== document.body) {
      if (node.getAttribute && node.getAttribute('data-kemofi-template-modal')) return node;
      node = node.parentNode;
    }
    return null;
  }

  function hiddenModalOpen(id) {
    var modal = document.getElementById(id);
    return !!modal && (modal.className.indexOf('open') !== -1 || modal.getAttribute('aria-hidden') === 'false');
  }

  function setTemplateModalOpen(modal, open) {
    if (!modal) return;
    var wasOpen = modal.getAttribute('data-kemofi-open') === '1';
    var legacy = modal.classList && modal.classList.contains('overlay');
    if (modal.classList) {
      modal.classList.toggle(legacy ? 'show' : 'is-open', !!open);
      if (legacy) modal.classList.remove('is-open');
      else modal.classList.remove('show');
    }
    modal.setAttribute('aria-hidden', open ? 'false' : 'true');
    modal.setAttribute('data-kemofi-open', open ? '1' : '0');
    if (open && !wasOpen) {
      var focusable = modal.querySelector('[data-kemofi-template-voucher-input], [data-kemofi-modal-submit], [data-kemofi-modal-close], button, input');
      if (focusable && typeof focusable.focus === 'function') {
        window.setTimeout(function () { try { focusable.focus(); } catch (error) {} }, 0);
      }
    }
  }

  function setTemplateText(modal, selector, source, fallback) {
    var target = modal && modal.querySelector(selector);
    if (!target || !source) return;
    var value = (source.textContent || '').replace(/\s+/g, ' ').trim();
    if (!value && fallback !== undefined) value = fallback;
    if (target.textContent !== value) target.textContent = value;
  }

  function setTemplateDisabled(modal, selector, source) {
    var target = modal && modal.querySelector(selector);
    if (!target || !source) return;
    target.disabled = !!source.disabled;
    target.setAttribute('aria-disabled', source.disabled ? 'true' : 'false');
    var label = (source.textContent || '').replace(/\s+/g, ' ').trim();
    if (label && target.textContent !== label) target.textContent = label;
  }

  function syncTemplateRates(modal) {
    var source = document.getElementById('rates-body');
    if (!modal || !source || !source.innerHTML.trim()) return;
    var targetBody = modal.querySelector('[data-kemofi-template-rates-body]');
    if (targetBody) {
      if (targetBody.innerHTML !== source.innerHTML) targetBody.innerHTML = source.innerHTML;
      return;
    }
    var targetCards = modal.querySelector('[data-kemofi-template-rates]');
    if (!targetCards) return;
    var rows = source.querySelectorAll('tr');
    var html = '';
    for (var i = 0; i < rows.length; i++) {
      var cells = rows[i].querySelectorAll('td');
      if (!cells.length) continue;
      html += '<div class="rate-item"><strong>' + (cells[0].innerHTML || '') + '</strong><span>' + (cells[1] ? cells[1].innerHTML : '') + (cells[2] ? '<small>' + cells[2].innerHTML + '</small>' : '') + (cells[3] ? '<small>' + cells[3].innerHTML + '</small>' : '') + '</span></div>';
    }
    if (html && targetCards.innerHTML !== html) targetCards.innerHTML = html;
  }

  function syncTemplateModals() {
    var coin = templateModal('insert');
    var rates = templateModal('rates');
    var voucher = templateModal('voucher');
    setTemplateModalOpen(coin, hiddenModalOpen('coin-modal'));
    setTemplateModalOpen(rates, hiddenModalOpen('rates-modal'));
    setTemplateModalOpen(voucher, hiddenModalOpen('voucher-modal'));

    var hiddenCoin = document.getElementById('coin-modal');
    if (coin && hiddenCoin) {
      setTemplateText(coin, '[data-kemofi-template-coin-ready]', hiddenCoin.querySelector('.coin-ready'), 'Coinslot Ready');
      setTemplateText(coin, '[data-kemofi-template-coin-amount]', hiddenCoin.querySelector('#coin-amount'), '₱0');
      setTemplateText(coin, '[data-kemofi-template-coin-time]', hiddenCoin.querySelector('#balance-min'), '00H 00M 00S');
      setTemplateText(coin, '[data-kemofi-template-coin-count]', hiddenCoin.querySelector('#coin-count'), '0');
      setTemplateText(coin, '[data-kemofi-template-countdown]', hiddenCoin.querySelector('#countdown'), '60');
      setTemplateText(coin, '[data-kemofi-template-coin-policy]', hiddenCoin.querySelector('#coin-policy'), '');
      setTemplateDisabled(coin, '[data-kemofi-modal-submit="connect"]', hiddenCoin.querySelector('#connect-btn'));
      var hiddenTitle = hiddenCoin.querySelector('#coin-modal-title');
      setTemplateText(coin, '.kemofi-template-modal-title', hiddenTitle, 'Insert Coin');
      var ready = hiddenCoin.querySelector('.coin-ready');
      var readyTarget = coin.querySelector('[data-kemofi-template-coin-ready]');
      if (readyTarget && ready) readyTarget.className = 'kemofi-template-modal-status' + (ready.className.indexOf('is-loading') !== -1 ? ' is-loading' : '');
    }
    syncTemplateRates(rates);

    var hiddenVoucher = document.getElementById('voucher-modal');
    if (voucher && hiddenVoucher) {
      var hiddenError = hiddenVoucher.querySelector('#voucher-error');
      var errorTarget = voucher.querySelector('[data-kemofi-template-voucher-error]');
      if (errorTarget && hiddenError) {
        errorTarget.textContent = hiddenError.textContent || '';
        errorTarget.hidden = hiddenError.style.display === 'none' || !hiddenError.textContent;
      }
      setTemplateDisabled(voucher, '[data-kemofi-modal-submit="voucher"]', hiddenVoucher.querySelector('#redeem-btn'));
    }
  }

  function bindTemplateModalControls() {
    var controls = document.querySelectorAll('[data-kemofi-modal-close], [data-kemofi-modal-submit]');
    for (var i = 0; i < controls.length; i++) {
      if (controls[i].getAttribute('data-kemofi-modal-bound') === 'true') continue;
      controls[i].setAttribute('data-kemofi-modal-bound', 'true');
      (function (control) {
        control.addEventListener('click', function (event) {
          event.preventDefault();
          event.stopPropagation();
          var modal = templateModalFor(control);
          var kind = modal ? modal.getAttribute('data-kemofi-template-modal') : '';
          var submit = control.getAttribute('data-kemofi-modal-submit');
          var targetId = kind === 'insert' ? (submit === 'connect' ? 'connect-btn' : 'close-coin-btn') :
            kind === 'rates' ? 'close-rates-btn' : kind === 'voucher' ? (submit === 'voucher' ? 'redeem-btn' : 'close-voucher-btn') : '';
          if (submit === 'voucher' && modal) {
            var visibleInput = modal.querySelector('[data-kemofi-template-voucher-input]');
            var hiddenInput = document.getElementById('voucher-input');
            if (visibleInput && hiddenInput) hiddenInput.value = visibleInput.value;
          }
          var target = targetId ? document.getElementById(targetId) : null;
          if (target && !target.disabled) target.click();
          else if (!submit) setTemplateModalOpen(modal, false);
          syncTemplateModals();
        });
      })(controls[i]);
    }
    var inputs = document.querySelectorAll('[data-kemofi-template-voucher-input]');
    for (i = 0; i < inputs.length; i++) {
      if (inputs[i].getAttribute('data-kemofi-modal-bound') === 'true') continue;
      inputs[i].setAttribute('data-kemofi-modal-bound', 'true');
      inputs[i].addEventListener('keydown', function (event) {
        if (event.key === 'Enter' || event.keyCode === 13) {
          var modal = templateModalFor(event.currentTarget);
          var submit = modal && modal.querySelector('[data-kemofi-modal-submit="voucher"]');
          if (submit) submit.click();
        }
      });
    }
  }

  function hiddenVisible(id) {
    var element = document.getElementById(id);
    if (!element) return false;
    return element.style.display !== 'none';
  }

  function hiddenEnabled(id) {
    var element = document.getElementById(id);
    return !!element && element.style.display !== 'none' && !element.disabled;
  }

  function setActionVisible(name, visible) {
    var items = actionTargets(name);
    for (var i = 0; i < items.length; i++) {
      var display = visible ? '' : 'none';
      var ariaHidden = visible ? 'false' : 'true';
      if (items[i].style.display !== display) items[i].style.display = display;
      if (items[i].getAttribute('aria-hidden') !== ariaHidden) items[i].setAttribute('aria-hidden', ariaHidden);
    }
  }

  function setActionEnabled(name, enabled) {
    var items = actionTargets(name);
    for (var i = 0; i < items.length; i++) {
      if ('disabled' in items[i]) items[i].disabled = !enabled;
      if (items[i].getAttribute('aria-disabled') !== (enabled ? 'false' : 'true')) items[i].setAttribute('aria-disabled', enabled ? 'false' : 'true');
      if (items[i].classList) items[i].classList.toggle('kemofi-action-disabled', !enabled);
    }
  }

  function refreshActionGroups() {
    var groups = document.querySelectorAll('[data-kemofi-live-action-group]');
    for (var i = 0; i < groups.length; i++) {
      var visible = false;
      var actions = groups[i].querySelectorAll('[data-kemofi-action]');
      for (var j = 0; j < actions.length; j++) {
        if (actions[j].style.display !== 'none') { visible = true; break; }
      }
      groups[i].style.display = visible ? '' : 'none';
    }
  }

  function slotVisibilityTarget(item) {
    var parent = item && item.parentNode;
    return parent && parent.getAttribute && parent.getAttribute('data-kemofi-live-slot-wrapper') ? parent : item;
  }

  function configured(name, fallback) {
    var value = document.body.getAttribute('data-kemofi-show-' + name);
    return value === null ? fallback : value !== '0';
  }

  function bindActions() {
    var items = document.querySelectorAll('[data-kemofi-action]');
    for (var i = 0; i < items.length; i++) {
      if (items[i].getAttribute('data-kemofi-bound') === 'true') continue;
      items[i].setAttribute('data-kemofi-bound', 'true');
      (function (item) {
        item.addEventListener('click', function (event) {
          var action = item.getAttribute('data-kemofi-action');
          if (action === 'online') {
            event.preventDefault();
            var notice = document.getElementById('coin-btn-notice');
            if (notice) {
              notice.textContent = 'Use Insert Coin or Voucher to connect.';
              notice.style.display = 'block';
              window.setTimeout(function () { notice.style.display = 'none'; }, 3500);
            }
            return;
          }
          if (action === 'device') {
            var details = document.getElementById('device-details');
            var open = details ? !details.open : true;
            if (details) details.open = open;
            var liveDetails = document.querySelectorAll('[data-kemofi-live-device]');
            for (var liveIndex = 0; liveIndex < liveDetails.length; liveIndex++) liveDetails[liveIndex].open = open;
            var templateDetails = document.querySelectorAll('[data-kemofi-template-details]');
            for (var templateIndex = 0; templateIndex < templateDetails.length; templateIndex++) {
              var templateDetail = templateDetails[templateIndex];
              if ('open' in templateDetail) templateDetail.open = open;
              if (templateDetail.classList) templateDetail.classList.toggle('open', open);
              var detailButton = templateDetail.querySelector('[data-kemofi-action="device"], #detailBtn');
              if (detailButton) detailButton.setAttribute('aria-expanded', open ? 'true' : 'false');
            }
            return;
          }
          var targetId = action === 'insert' ? 'open-coin-btn' :
            action === 'voucher' ? 'btn-voucher' :
            action === 'rates' ? 'toggle-rates-btn' :
            action === 'pause' ? ((document.getElementById('btn-pause') && document.getElementById('btn-pause').style.display !== 'none') ? 'btn-pause' : 'btn-resume') :
            action === 'extend' ? ((document.getElementById('btn-add-time') && document.getElementById('btn-add-time').style.display !== 'none') ? 'btn-add-time' : 'btn-add-time-paused') :
            action === 'free' ? 'btn-free-time' : '';
          var target = targetId ? document.getElementById(targetId) : null;
          if (target && !target.disabled) target.click();
          if (action === 'voucher' && target) {
            var visibleVoucher = templateModal('voucher');
            var hiddenVoucherInput = document.getElementById('voucher-input');
            var visibleVoucherInput = visibleVoucher && visibleVoucher.querySelector('[data-kemofi-template-voucher-input]');
            if (visibleVoucherInput && hiddenVoucherInput) visibleVoucherInput.value = hiddenVoucherInput.value || '';
          }
          syncTemplateModals();
        });
      })(items[i]);
    }
  }

  function mirror() {
    if (!window.__KEMOFI_TEMPLATE_ACTIVE__) return;
    bindActions();
    bindTemplateModalControls();

    var business = textOf('#brand-business-name') || textOf('#business-name') || 'KemoFi';
    var portal = textOf('#portal-name');
    var wan = textOf('#wan-badge .wan-label');
    var status = textOf('#status-value');
    var remaining = textOf('#remaining-time-data') || '--';
    var validity = textOf('#session-validity') || '--';
    var pausesRemaining = textOf('#session-pauses-remaining') || '--';
    var ip = textOf('#device-ip');
    var mac = textOf('#device-mac');
    var footer = textOf('#operator-footer');

    mirrorSlot('business', business);
    mirrorSlot('portal', portal);
    mirrorSlot('wan', wan);
    mirrorSlot('status', status);
    mirrorSlot('remaining-time', remaining);
    mirrorSlot('validity', validity);
    mirrorSlot('pauses-remaining', pausesRemaining);
    mirrorSlot('device-ip', ip);
    mirrorSlot('device-mac', mac);
    mirrorSlot('footer', footer);
    syncTemplateBranding();

    var panel = document.getElementById('status-panel');
    var statusSlots = slots('status');
    for (var i = 0; i < statusSlots.length; i++) {
      var statusDisplay = configured('status', true) ? '' : 'none';
      var statusTarget = slotVisibilityTarget(statusSlots[i]);
      if (statusTarget.style.display !== statusDisplay) statusTarget.style.display = statusDisplay;
      var statusClass = statusSlots[i].className.replace(/\b(kemofi-status-connected|kemofi-status-paused|kemofi-status-disconnected)\b/g, '');
      if (panel && panel.className.indexOf(' connected') >= 0) statusClass += ' kemofi-status-connected';
      else if (panel && panel.className.indexOf(' paused') >= 0) statusClass += ' kemofi-status-paused';
      else statusClass += ' kemofi-status-disconnected';
      if (statusSlots[i].className !== statusClass) statusSlots[i].className = statusClass;
    }

    var actionsEnabled = configured('actions', true);
    var insertVisible = actionsEnabled && configured('coin', true) && hiddenVisible('coin-actions');
    var voucherVisible = actionsEnabled && configured('voucher', true) && hiddenVisible('voucher-section');
    var ratesVisible = actionsEnabled && configured('rates', true);
    var pauseVisible = actionsEnabled && configured('pause', true) && (hiddenVisible('connected-actions') || hiddenVisible('paused-actions'));
    var extendVisible = actionsEnabled && configured('extend', true) && (hiddenVisible('btn-add-time') || hiddenVisible('btn-add-time-paused'));
    var deviceVisible = configured('device', true) && (hiddenVisible('device-details') || hiddenVisible('device-panel'));
    var freeVisible = actionsEnabled && configured('free-time', true) && hiddenVisible('free-time-section');
    setActionVisible('insert', insertVisible);
    setActionEnabled('insert', insertVisible && hiddenEnabled('open-coin-btn'));
    setActionVisible('voucher', voucherVisible);
    setActionEnabled('voucher', voucherVisible && hiddenEnabled('btn-voucher'));
    setActionVisible('rates', ratesVisible);
    setActionEnabled('rates', ratesVisible && hiddenEnabled('toggle-rates-btn'));
    setActionVisible('pause', pauseVisible);
    setActionEnabled('pause', pauseVisible && (hiddenEnabled('btn-pause') || hiddenEnabled('btn-resume')));
    setActionVisible('extend', extendVisible);
    setActionEnabled('extend', extendVisible && (hiddenEnabled('btn-add-time') || hiddenEnabled('btn-add-time-paused')));
    setActionVisible('device', deviceVisible);
    setActionEnabled('device', deviceVisible);
    setActionVisible('free', freeVisible);
    setActionEnabled('free', freeVisible && hiddenEnabled('btn-free-time'));
    var footerItems = slots('footer');
    var footerDisplay = configured('footer', true) ? '' : 'none';
    for (i = 0; i < footerItems.length; i++) if (footerItems[i].style.display !== footerDisplay) footerItems[i].style.display = footerDisplay;
    var deviceSlots = document.querySelectorAll('[data-kemofi-slot="device-ip"],[data-kemofi-slot="device-mac"]');
    for (i = 0; i < deviceSlots.length; i++) deviceSlots[i].style.display = deviceVisible ? '' : 'none';
    var liveDevices = document.querySelectorAll('[data-kemofi-live-device]');
    for (i = 0; i < liveDevices.length; i++) liveDevices[i].style.display = deviceVisible ? '' : 'none';
    var templateDetails = document.querySelectorAll('[data-kemofi-template-details]');
    for (i = 0; i < templateDetails.length; i++) templateDetails[i].style.display = deviceVisible ? '' : 'none';
    refreshActionGroups();
    syncTemplateModals();
  }

  function installTemplateParts(sourceBody, styleContents) {
    if (!sourceBody || !document.body) return false;
    var scripts = sourceBody.getElementsByTagName('script');
    while (scripts.length) scripts[0].parentNode.removeChild(scripts[0]);

    document.body.className = sourceBody.getAttribute('class') || '';
    for (var i = 0; i < sourceBody.attributes.length; i++) {
      var attribute = sourceBody.attributes[i];
      if (attribute.name.indexOf('data-kemofi-') === 0) document.body.setAttribute(attribute.name, attribute.value);
    }
    document.body.innerHTML = sourceBody.innerHTML;

    var previousStyles = document.querySelectorAll('#kemofi-active-template-style');
    for (i = 0; i < previousStyles.length; i++) {
      if (previousStyles[i].parentNode) previousStyles[i].parentNode.removeChild(previousStyles[i]);
    }
    var styles = styleContents || [];
    for (i = 0; i < styles.length; i++) {
      var style = document.createElement('style');
      style.id = i === 0 ? 'kemofi-active-template-style' : '';
      style.textContent = typeof styles[i] === 'string' ? styles[i] : (styles[i].textContent || '');
      document.head.appendChild(style);
    }

    window.__KEMOFI_TEMPLATE_ACTIVE__ = true;
    appendCompatibilityDom();
    mirror();
    if (templateObserver && templateObserver.disconnect) templateObserver.disconnect();
    templateObserver = null;
    if (templateMirrorTimer) window.clearInterval(templateMirrorTimer);
    // The hidden compatibility portal and the visible exact template both
    // update the DOM. Observing the whole document creates a feedback loop
    // because mirroring itself is a DOM mutation. A bounded timer keeps the
    // visible template in sync without allowing that loop to lock the page.
    templateMirrorTimer = window.setInterval(mirror, 1000);
    return true;
  }

  function installTemplate() {
    var markup = requestText(ACTIVE_TEMPLATE_URL);
    if (!markup || !document.body || !window.DOMParser) return false;
    var parsed;
    try { parsed = new DOMParser().parseFromString(markup, 'text/html'); } catch (error) { return false; }
    var sourceBody = parsed && parsed.getElementsByTagName('body')[0];
    if (!sourceBody || sourceBody.getAttribute('data-kemofi-template') === null) return false;
    var styles = parsed.getElementsByTagName('style');
    return installTemplateParts(sourceBody, styles);
  }

  function installPreviewTemplateParts(sourceBody, styleContents) {
    if (!sourceBody || !document.body) return false;
    var runtime = document.getElementById('kemofi-template-compat');
    if (!runtime) {
      var originalPortal = document.getElementById('status-panel');
      if (!originalPortal) return installTemplateParts(sourceBody, styleContents);
      runtime = document.createElement('div');
      runtime.id = 'kemofi-template-compat';
      runtime.setAttribute('aria-hidden', 'true');
      while (document.body.firstChild) runtime.appendChild(document.body.firstChild);
      document.body.appendChild(runtime);
      addCompatStyle();
    }

    var previousVisible = document.getElementById('kemofi-template-visible');
    if (previousVisible && previousVisible.parentNode) previousVisible.parentNode.removeChild(previousVisible);
    var previousStyles = document.querySelectorAll('#kemofi-active-template-style');
    for (var i = 0; i < previousStyles.length; i++) {
      if (previousStyles[i].parentNode) previousStyles[i].parentNode.removeChild(previousStyles[i]);
    }

    document.body.className = sourceBody.getAttribute('class') || '';
    for (i = 0; i < sourceBody.attributes.length; i++) {
      var attribute = sourceBody.attributes[i];
      if (attribute.name.indexOf('data-kemofi-') === 0) document.body.setAttribute(attribute.name, attribute.value);
    }

    var visible = document.createElement('div');
    visible.id = 'kemofi-template-visible';
    visible.style.display = 'contents';
    while (sourceBody.firstChild) visible.appendChild(sourceBody.firstChild);
    document.body.appendChild(visible);

    var styles = styleContents || [];
    for (i = 0; i < styles.length; i++) {
      var style = document.createElement('style');
      style.id = i === 0 ? 'kemofi-active-template-style' : '';
      style.textContent = typeof styles[i] === 'string' ? styles[i] : (styles[i].textContent || '');
      document.head.appendChild(style);
    }

    window.__KEMOFI_TEMPLATE_ACTIVE__ = true;
    mirror();
    if (templateObserver && templateObserver.disconnect) templateObserver.disconnect();
    templateObserver = null;
    if (templateMirrorTimer) window.clearInterval(templateMirrorTimer);
    templateMirrorTimer = window.setInterval(mirror, 1000);
    return true;
  }

  function installPreviewTemplate(payload) {
    if (!isPreview || !payload || !payload.template || !window.DOMParser) return false;
    var template = payload.template;
    var templateId = String(template.template_id || '');
    if (!/^(?:kingfi-luxury|kingfi-cyber|kingfi-gaming|kingfi-glass|kingfi-crown|kingfi-premium)$/.test(templateId)) return false;
    if (typeof template.body !== 'string' || typeof template.css !== 'string') return false;
    var state = payload.state && typeof payload.state === 'object' ? payload.state : {};
    var settings = template.settings && typeof template.settings === 'object' ? template.settings : {};
    var html = '<!doctype html><html><head><meta charset="utf-8"></head><body' +
      ' data-kemofi-template="' + templateId + '"' +
      ' data-kemofi-show-status="' + (state.showStatus === false ? '0' : '1') + '"' +
      ' data-kemofi-show-device="' + (settings.portal_hide_device_info === '1' || state.showDevice === false ? '0' : '1') + '"' +
      ' data-kemofi-show-coin="' + (settings.portal_show_coin === '0' || state.showCoin === false ? '0' : '1') + '"' +
      ' data-kemofi-show-rates="' + (settings.portal_show_rates === '0' || state.showRates === false ? '0' : '1') + '"' +
      ' data-kemofi-show-voucher="' + (settings.portal_show_voucher === '0' || state.showVoucher === false ? '0' : '1') + '"' +
      ' data-kemofi-show-footer="' + (state.showFooter === false ? '0' : '1') + '"' +
      ' data-kemofi-show-pause="' + (state.showPause === false ? '0' : '1') + '"' +
      ' data-kemofi-show-extend="' + (state.showExtend === false ? '0' : '1') + '"' +
      ' data-kemofi-show-actions="' + (state.showActions === false ? '0' : '1') + '">' +
      template.body + '</body></html>';
    var parsed;
    try { parsed = new DOMParser().parseFromString(html, 'text/html'); } catch (error) { return false; }
    var sourceBody = parsed && parsed.getElementsByTagName('body')[0];
    if (!sourceBody) return false;
    return installPreviewTemplateParts(sourceBody, [template.css]);
  }

  if (isPreview) {
    window.addEventListener('message', function (event) {
      if (event.source !== window.parent || !event.data || event.data.type !== 'kemofi-portal-preview') return;
      installPreviewTemplate(event.data);
    });
  }

  installTemplate();
})();
