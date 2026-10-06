(function () {
  'use strict';
  var tab = document.getElementById('tab-settings');
  var pause = document.getElementById('set-pause-rules');
  if (!tab || !pause || document.getElementById('coin-validity-card')) return;
  while (pause && !pause.classList.contains('form-card')) pause = pause.parentElement;
  if (!pause) return;

  var api = '/api/admin/settings';
  var remote = window.location.pathname.match(/^\/api\/remote\/[^/]+/);
  if (remote) api = remote[0] + '/admin/settings';
  var card = document.createElement('form');
  card.id = 'coin-validity-card';
  card.className = 'form-card';
  card.innerHTML = '<h3 class="form-title">Session Validity Rules</h3>' +
    '<p class="validity-help">Validity for coin-purchased time. Leave empty to disable for new purchases.</p>' +
    '<fieldset disabled><div class="rate-tier-panel"><div class="rate-tier-panel-header">' +
      '<span class="rate-tier-panel-label">WiFi time → Validity</span>' +
      '<button type="button" class="btn btn-outline btn-sm" id="btn-add-validity-rule">+ Add rule</button>' +
    '</div><div id="validity-rule-rows"></div>' +
    '<div id="validity-rule-empty" class="rate-tier-empty">No rules. Add a rule to set validity.</div></div>' +
    '<p class="validity-help">Uses total purchased time. Add Time can extend, never shorten, validity.</p>' +
    '<button type="submit" class="btn btn-primary" id="btn-save-validity-rules">Save Validity Rules</button>' +
    '</fieldset><p id="validity-rule-status" role="status" aria-live="polite"></p>' +
    '<button type="button" class="btn btn-outline btn-sm" id="btn-retry-validity-rules" hidden>Retry</button>';
  pause.insertAdjacentElement('afterend', card);

  var rows = card.querySelector('#validity-rule-rows');
  var empty = card.querySelector('#validity-rule-empty');
  var status = card.querySelector('#validity-rule-status');
  var fields = card.querySelector('fieldset');
  var retry = card.querySelector('#btn-retry-validity-rules');
  var add = card.querySelector('#btn-add-validity-rule');
  var loaded = false, busy = false, nextId = 0;

  function message(text, error) {
    status.textContent = text;
    status.classList.toggle('validity-error', !!error);
  }
  function request(method, body, done) {
    var xhr = new XMLHttpRequest();
    xhr.open(method, api, true);
    xhr.withCredentials = true;
    xhr.timeout = 15000;
    xhr.setRequestHeader('Content-Type', 'application/json');
    xhr.onload = function () {
      var data;
      try { data = JSON.parse(xhr.responseText); } catch (ignore) {}
      if (xhr.status === 401) return done('Sign in again, then retry.');
      if (xhr.status < 200 || xhr.status >= 300 || !data || typeof data !== 'object') {
        return done((data && data.message) || 'Could not save or load validity rules. Retry.');
      }
      done(null, data);
    };
    xhr.onerror = xhr.ontimeout = function () { done('Router unavailable. Retry.'); };
    xhr.send(body === null ? null : JSON.stringify(body));
  }
  function reindex() {
    Array.prototype.forEach.call(rows.children, function (row, i) {
      row.querySelector('.rate-tier-index').textContent = i + 1;
      row.querySelector('button').setAttribute('aria-label', 'Remove validity rule ' + (i + 1));
    });
    empty.hidden = rows.children.length > 0;
    add.disabled = rows.children.length >= 100;
  }
  function unitMultiplier(unit, canonicalUnit) {
    if (canonicalUnit === 'minutes') {
      if (unit === 'days') return 1440;
      if (unit === 'hours') return 60;
    } else if (canonicalUnit === 'hours' && unit === 'days') {
      return 24;
    }
    return 1;
  }
  function displayValue(value, canonicalUnit) {
    var total = Math.max(0, Math.floor(Number(value) || 0));
    if (canonicalUnit === 'minutes') {
      if (total > 0 && total % 1440 === 0) return {value: total / 1440, unit: 'days'};
      if (total > 0 && total % 60 === 0) return {value: total / 60, unit: 'hours'};
      return {value: total || '', unit: 'minutes'};
    }
    if (total > 0 && total % 24 === 0) return {value: total / 24, unit: 'days'};
    return {value: total || '', unit: 'hours'};
  }
  function setUnitMaximum(input, select, canonicalUnit) {
    input.max = String(Math.floor(99999 / unitMultiplier(select.value, canonicalUnit)));
  }
  function canonicalValue(row, valueSelector, unitSelector, canonicalUnit) {
    var value = Number(row.querySelector(valueSelector).value);
    var unit = row.querySelector(unitSelector).value;
    var result = value * unitMultiplier(unit, canonicalUnit);
    return value > 0 && Math.floor(result) === result && result <= 99999 ? result : 0;
  }
  function addRow(minutes, hours) {
    if (rows.children.length >= 100) return;
    var id = ++nextId;
    var wifi = displayValue(minutes, 'minutes');
    var validity = displayValue(hours, 'hours');
    var row = document.createElement('div');
    row.className = 'coin-validity-row';
    row.innerHTML = '<span class="rate-tier-index"></span>' +
      '<div class="rate-tier-field"><label for="validity-wifi-' + id + '">Purchased WiFi time</label>' +
      '<div class="validity-value-unit"><input id="validity-wifi-' + id + '" class="validity-wifi-value" type="number" min="1" step="1" required placeholder="e.g. 2">' +
      '<select class="validity-wifi-unit" aria-label="Purchased WiFi time unit"><option value="minutes">Minutes</option><option value="hours">Hours</option><option value="days">Days</option></select></div></div>' +
      '<span class="validity-arrow" aria-hidden="true">→</span>' +
      '<div class="rate-tier-field"><label for="validity-duration-' + id + '">Valid for</label>' +
      '<div class="validity-value-unit"><input id="validity-duration-' + id + '" class="validity-duration-value" type="number" min="1" step="1" required placeholder="e.g. 30">' +
      '<select class="validity-duration-unit" aria-label="Validity unit"><option value="hours">Hours</option><option value="days">Days</option></select></div></div>' +
      '<button type="button" class="rate-tier-del" title="Remove rule">×</button>';
    var wifiValue = row.querySelector('.validity-wifi-value');
    var wifiUnit = row.querySelector('.validity-wifi-unit');
    var validityValue = row.querySelector('.validity-duration-value');
    var validityUnit = row.querySelector('.validity-duration-unit');
    wifiValue.value = wifi.value;
    wifiUnit.value = wifi.unit;
    validityValue.value = validity.value;
    validityUnit.value = hours ? validity.unit : 'days';
    setUnitMaximum(wifiValue, wifiUnit, 'minutes');
    setUnitMaximum(validityValue, validityUnit, 'hours');
    wifiUnit.onchange = function () { setUnitMaximum(wifiValue, wifiUnit, 'minutes'); };
    validityUnit.onchange = function () { setUnitMaximum(validityValue, validityUnit, 'hours'); };
    row.querySelector('button').onclick = function () { row.remove(); reindex(); };
    rows.appendChild(row);
    reindex();
  }
  function parse(raw) {
    if (typeof raw !== 'string' || raw.length > 4096) throw new Error('Invalid saved validity rules.');
    var seen = {}, result = [];
    raw.split(/[\r\n]+/).forEach(function (line) {
      if (!line.trim()) return;
      var parts = line.match(/^\s*(\d+)\s*:\s*(\d+)\s*$/);
      var min = parts && Number(parts[1]), hrs = parts && Number(parts[2]);
      if (!parts || min < 1 || hrs < 1 || min > 99999 || hrs > 99999 || result.length >= 100) {
        throw new Error('Use whole numbers from 1 to 99999 (up to 100 rules).');
      }
      if (seen[min]) throw new Error('Each WiFi time must be unique.');
      seen[min] = true;
      result.push([min, hrs]);
    });
    return result.sort(function (a, b) { return a[0] - b[0]; });
  }
  function render(rules) {
    rows.textContent = '';
    rules.forEach(function (rule) { addRow(rule[0], rule[1]); });
    reindex();
  }
  function load() {
    if (loaded || busy) return;
    busy = true;
    retry.hidden = true;
    message('Loading validity rules…');
    request('GET', null, function (error, data) {
      busy = false;
      if (!error) {
        try { render(parse(data.session_validity_rules)); } catch (err) { error = err.message; }
      }
      if (error) { message(error, true); retry.hidden = false; return; }
      loaded = true;
      fields.disabled = false;
      message('');
    });
  }
  add.onclick = function () {
    addRow();
    rows.lastElementChild.querySelector('input').focus();
  };
  retry.onclick = load;
  card.onsubmit = function (event) {
    event.preventDefault();
    if (!loaded || busy || !card.reportValidity()) return;
    var rules;
    try {
      rules = parse(Array.prototype.map.call(rows.children, function (row) {
        return canonicalValue(row, '.validity-wifi-value', '.validity-wifi-unit', 'minutes') + ':' +
          canonicalValue(row, '.validity-duration-value', '.validity-duration-unit', 'hours');
      }).join('\n'));
    } catch (err) { message(err.message, true); return; }
    var raw = rules.map(function (rule) { return rule.join(':'); }).join('\n');
    busy = true;
    fields.disabled = true;
    message('Saving…');
    // Only this key is submitted: no rates, pause, coin hardware or media fields.
    request('POST', {session_validity_rules: raw}, function (error, data) {
      busy = false;
      fields.disabled = false;
      if (error || data.status !== 'ok') { message(error || 'Save failed. Retry.', true); return; }
      render(rules);
      message('Saved. Existing deadlines are unchanged.');
    });
  };
  // Load on Settings entry, after authentication. No background polling.
  new MutationObserver(function () {
    if (tab.classList.contains('active')) load();
  }).observe(tab, {attributes: true, attributeFilter: ['class']});
  if (tab.classList.contains('active')) load();
})();
