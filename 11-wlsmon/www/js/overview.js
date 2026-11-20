/*
 * overview.js: entry page of wlsmon on the GUI host A (concept 3.2)
 *
 * Reads hosts.json (written by "wlsmon.py pull" after each round) and shows
 * one tile per host, grouped by product and environment. A click on a tile
 * opens the host view host.html?host=<id> (concept 3.3).
 *
 * Same rules as wlsmon.js: no innerHTML, no eval, values via textContent,
 * levels only from a whitelist. Helpers are duplicated on purpose for the
 * prototype; in the repository they move to one shared file.
 */
(function () {
  'use strict';

  var REFRESH_MS = 5 * 60 * 1000;

  var LEVEL = {
    ok:    { word: 'OK',    icon: 'check' },
    warn:  { word: 'WARN',  icon: 'triangle' },
    crit:  { word: 'CRIT',  icon: 'times' },
    stale: { word: 'STALE', icon: 'clock' }
  };
  var RANK = { crit: 0, stale: 1, warn: 2, ok: 3 };
  var ENV = { prod: 'Production', qa: 'Quality assurance', test: 'Test', dev: 'Development' };
  var ENV_ORDER = { prod: 0, qa: 1, test: 2, dev: 3 };

  var state = { data: null, locale: 'de-DE', env: 'all', q: '' };

  /* ---------- helpers ---------- */

  function $(id) { return document.getElementById(id); }
  function lv(x) { return Object.prototype.hasOwnProperty.call(LEVEL, x) ? x : 'stale'; }
  function num(v) { return typeof v === 'number' && isFinite(v); }
  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = String(text);
    return e;
  }
  function svg(tag, attrs) {
    var e = document.createElementNS('http://www.w3.org/2000/svg', tag);
    Object.keys(attrs || {}).forEach(function (k) { e.setAttribute(k, attrs[k]); });
    return e;
  }
  function clear(n) { while (n.firstChild) n.removeChild(n.firstChild); }

  // font-apex when loaded (wlsmon_libs.js), otherwise inline SVG
  function icon(name) {
    var fa = window.WLSMON_LIBS && window.WLSMON_LIBS.faIcon(name);
    if (fa) return fa;
    var s = svg('svg', { viewBox: '0 0 24 24', 'class': 'icon', 'aria-hidden': 'true', focusable: 'false' });
    if (name === 'check') {
      s.appendChild(svg('circle', { cx: 12, cy: 12, r: 9.5 }));
      s.appendChild(svg('polyline', { points: '7.5 12.5 10.5 15.5 16.5 9' }));
    } else if (name === 'triangle') {
      s.appendChild(svg('path', { d: 'M12 3 L22 20.5 H2 Z' }));
      s.appendChild(svg('line', { x1: 12, y1: 9.5, x2: 12, y2: 14 }));
      s.appendChild(svg('line', { x1: 12, y1: 17.2, x2: 12, y2: 17.3 }));
    } else if (name === 'times') {
      s.appendChild(svg('circle', { cx: 12, cy: 12, r: 9.5 }));
      s.appendChild(svg('line', { x1: 8.5, y1: 8.5, x2: 15.5, y2: 15.5 }));
      s.appendChild(svg('line', { x1: 15.5, y1: 8.5, x2: 8.5, y2: 15.5 }));
    } else {
      s.appendChild(svg('circle', { cx: 12, cy: 12, r: 9.5 }));
      s.appendChild(svg('polyline', { points: '12 7 12 12 15.5 14' }));
    }
    return s;
  }
  function badge(level, word) {
    var k = lv(level);
    var b = el('span', 'badge lvl-' + k);
    b.appendChild(icon(LEVEL[k].icon));
    b.appendChild(document.createTextNode(word || LEVEL[k].word));
    return b;
  }
  function fmtNum(v, d) {
    if (!num(v)) return '';
    return new Intl.NumberFormat(state.locale, { minimumFractionDigits: d || 0, maximumFractionDigits: d || 0 }).format(v);
  }
  function tzFromIso(iso) {
    var m = /([+-])(\d{2}):(\d{2})$/.exec(iso || '');
    if (!m || m[3] !== '00') return undefined;
    var h = parseInt(m[2], 10);
    return h === 0 ? 'UTC' : 'Etc/GMT' + (m[1] === '+' ? '-' : '+') + h;
  }
  // times in the time zone of the host that measured them (interface design 8)
  function fmtStamp(iso, withDate) {
    var d = new Date(iso);
    if (isNaN(d)) return 'unknown';
    var o = withDate === false ? { hour: '2-digit', minute: '2-digit', hour12: false }
      : { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false };
    o.timeZone = tzFromIso(iso);
    try { return new Intl.DateTimeFormat(state.locale, o).format(d); }
    catch (e) { delete o.timeZone; return new Intl.DateTimeFormat(state.locale, o).format(d); }
  }
  function getJson(url) {
    return fetch(url, { cache: 'no-store', credentials: 'same-origin' }).then(function (r) {
      if (!r.ok) throw new Error(url + ': HTTP ' + r.status);
      return r.json();
    });
  }

  /* ---------- render ---------- */

  // demo mode: data-demo on <body> or #demo in the URL (development / presentation)
  function demoMode() { return document.body.hasAttribute('data-demo') || location.hash === '#demo'; }

  function refTime() {
    // demo files carry demo_reference so their age stays constant; real files never do
    var d = state.data;
    var demo = demoMode();
    return demo && d && d.demo_reference ? Date.parse(d.demo_reference) : Date.now();
  }

  // effective level of a host: STALE when its data is older than two intervals
  function hostState(h) {
    var interval = (h.interval_sec || 300) * 1000;
    var age = refTime() - Date.parse(h.generated_at);
    var ageMin = Math.max(0, Math.round(age / 60000));
    var stale = !(age >= -interval && age <= 2 * interval);
    return { level: stale ? 'stale' : lv(h.level), stale: stale, ageMin: ageMin };
  }

  function hostLink(h) {
    // demo: the link in the file; real: host view of the pulled copy
    if (demoMode() && typeof h.link === 'string' && /^host\.html#demo-[a-z]+$/.test(h.link)) return h.link;
    return 'host.html?host=' + encodeURIComponent(h.id);
  }

  function renderCounts(list) {
    var box = $('ov-counts');
    clear(box);
    var c = { crit: 0, warn: 0, stale: 0, ok: 0 };
    list.forEach(function (h) { c[hostState(h).level]++; });
    box.appendChild(el('span', 'ov-total', list.length + (list.length === 1 ? ' host' : ' hosts')));
    ['crit', 'warn', 'stale', 'ok'].forEach(function (k) {
      var b = badge(k, LEVEL[k].word + ' ' + c[k]);
      if (!c[k]) b.classList.add('ov-zero');
      box.appendChild(b);
    });
  }

  function tile(h) {
    var st = hostState(h);
    var a = el('a', 'host-tile lvl-' + st.level);
    a.setAttribute('href', hostLink(h));

    var head = el('div', 'host-head');
    head.appendChild(el('span', 'host-name', h.name || h.id));
    head.appendChild(badge(st.level, st.stale ? 'STALE ' + fmtNum(st.ageMin) + ' min' : null));
    a.appendChild(head);

    var meta = el('div', 'host-meta');
    var envKey = String(h.environment || '').toLowerCase();
    if (h.environment) {
      var env = el('span', 'env env-small' + (ENV[envKey] ? ' env-' + envKey : ''), ENV[envKey] || h.environment);
      meta.appendChild(env);
    }
    meta.appendChild(el('span', 'host-domain', h.domain || ''));
    a.appendChild(meta);

    var age = el('div', 'host-age');
    age.appendChild(document.createTextNode(st.stale
      ? 'last data ' + fmtStamp(h.generated_at) + ' · check the pull / collector'
      : 'updated ' + fmtStamp(h.generated_at, false) + ' · ' + (st.ageMin < 1 ? 'just now' : fmtNum(st.ageMin) + ' min ago')));
    age.setAttribute('title', h.generated_at);
    a.appendChild(age);

    var rs = el('ul', 'host-reasons');
    var reasons = Array.isArray(h.reasons) ? h.reasons.slice(0, 3) : [];
    if (!reasons.length && st.level === 'ok') reasons = [{ level: 'ok', text: 'all within limits' }];
    reasons.forEach(function (r) {
      var k = lv(r.level);
      var li = el('li', 'host-reason lvl-' + k);
      li.appendChild(icon(LEVEL[k].icon));
      li.appendChild(el('span', null, r.text));
      rs.appendChild(li);
    });
    if (h.collector_errors) {
      var li2 = el('li', 'host-reason lvl-warn');
      li2.appendChild(icon('triangle'));
      li2.appendChild(el('span', null, 'Collector: ' + h.collector_errors + (h.collector_errors === 1 ? ' error' : ' errors')));
      rs.appendChild(li2);
    }
    a.appendChild(rs);

    var s = h.summary || {};
    var parts = [];
    if (num(s.forms_sessions)) parts.push('Forms ' + fmtNum(s.forms_sessions));
    if (num(s.heap_forms_pct)) parts.push('heap ' + fmtNum(s.heap_forms_pct) + ' %');
    if (num(s.load1)) parts.push('load ' + fmtNum(s.load1, 1));
    if (num(s.cpu_pct)) parts.push('CPU ' + fmtNum(s.cpu_pct) + ' %');
    if (s.since) {
      var days = Math.floor((refTime() - Date.parse(s.since)) / 86400000);
      if (days >= 0) parts.push('up ' + fmtNum(days) + (days === 1 ? ' day' : ' days'));
    }
    if (parts.length) a.appendChild(el('div', 'host-summary', parts.join(' · ')));

    a.appendChild(el('span', 'host-open', 'Open host view →'));
    a.setAttribute('aria-label', (h.name || h.id) + ', ' + (ENV[envKey] || h.environment || '') + ', status ' +
      (st.stale ? 'STALE' : LEVEL[st.level].word) + ', open host view');
    return a;
  }

  function render() {
    var d = state.data;
    var groups = $('ov-groups');
    clear(groups);
    if (!d || !Array.isArray(d.hosts)) return;
    $('ov-stamp').textContent = d.generated_at ? fmtStamp(d.generated_at) : '…';
    $('locale').textContent = state.locale;

    var q = state.q.toLowerCase();
    var list = d.hosts.filter(function (h) {
      if (state.env !== 'all' && String(h.environment).toLowerCase() !== state.env) return false;
      if (q && [h.id, h.name, h.product, h.domain].join(' ').toLowerCase().indexOf(q) < 0) return false;
      return true;
    });
    renderCounts(list);
    var products = {};
    d.hosts.forEach(function (h) { products[h.product || 'Other'] = true; });
    $('ov-subtitle').textContent = 'Forms & Reports hosts · ' + d.hosts.length + ' hosts · ' + Object.keys(products).length + ' products';

    // group by product; inside: environment order, then worst level first
    var byProd = {};
    list.forEach(function (h) { var p = h.product || 'Other'; (byProd[p] = byProd[p] || []).push(h); });
    Object.keys(byProd).sort().forEach(function (p) {
      var hs = byProd[p].sort(function (a, b) {
        var ea = ENV_ORDER[String(a.environment).toLowerCase()], eb = ENV_ORDER[String(b.environment).toLowerCase()];
        ea = ea === undefined ? 9 : ea; eb = eb === undefined ? 9 : eb;
        if (ea !== eb) return ea - eb;
        return RANK[hostState(a).level] - RANK[hostState(b).level];
      });
      var worst = 'ok';
      hs.forEach(function (h) { var l = hostState(h).level; if (RANK[l] < RANK[worst]) worst = l; });
      var sec = el('section', 'block ov-group');
      var head = el('div', 'block-head');
      var h2 = el('h2', null, p);
      head.appendChild(h2);
      var right = el('span', 'ov-group-meta');
      right.appendChild(el('span', 'muted small', hs.length + (hs.length === 1 ? ' host' : ' hosts')));
      right.appendChild(badge(worst));
      head.appendChild(right);
      sec.appendChild(head);
      var grid = el('div', 'grid grid-hosts');
      hs.forEach(function (h) { grid.appendChild(tile(h)); });
      sec.appendChild(grid);
      groups.appendChild(sec);
    });
    if (!list.length) groups.appendChild(el('p', 'muted', 'No host matches the filter.'));
  }

  /* ---------- load, refresh, theme ---------- */

  function load() {
    var url = document.body.getAttribute('data-hosts') || (demoMode() ? 'api/demo/hosts.json' : 'hosts.json');
    return getJson(url).then(function (d) { state.data = d; render(); $('fetch-error').textContent = ''; })
      .catch(function (e) { $('fetch-error').textContent = 'Loading failed: ' + e.message; });
  }

  var refreshAt = 0, busy = false;
  function reloadAll() {
    if (busy) return;
    busy = true;
    var btn = $('refresh-btn');
    btn.classList.add('busy');
    load().then(function () {
      busy = false; btn.classList.remove('busy');
      refreshAt = Date.now() + REFRESH_MS; tick();
    });
  }
  function tick() {
    var left = refreshAt - Date.now();
    if (left <= 0 && !busy) { reloadAll(); return; }
    var sec = Math.max(0, Math.ceil(left / 1000));
    var txt = Math.floor(sec / 60) + ':' + (sec % 60 < 10 ? '0' : '') + (sec % 60);
    $('refresh-timer').textContent = txt;
    $('refresh-btn').setAttribute('aria-label', 'Refresh now, next automatic refresh in ' + txt);
  }

  var THEMES = ['auto', 'light', 'dark'];
  function applyTheme(t) {
    if (t === 'light' || t === 'dark') document.documentElement.setAttribute('data-theme', t);
    else document.documentElement.removeAttribute('data-theme');
    $('theme-btn').textContent = 'Theme: ' + t;
  }
  function initTheme() {
    var t = 'auto';
    try { t = localStorage.getItem('wlsmon-theme') || 'auto'; } catch (e) { /* not available */ }
    if (THEMES.indexOf(t) < 0) t = 'auto';
    applyTheme(t);
    $('theme-btn').addEventListener('click', function () {
      t = THEMES[(THEMES.indexOf(t) + 1) % THEMES.length];
      applyTheme(t);
      try { localStorage.setItem('wlsmon-theme', t); } catch (e) { /* not available */ }
    });
  }

  function initFilter() {
    var btns = document.querySelectorAll('.seg button[data-env]');
    Array.prototype.forEach.call(btns, function (b) {
      b.addEventListener('click', function () {
        state.env = b.getAttribute('data-env');
        Array.prototype.forEach.call(btns, function (x) { x.setAttribute('aria-pressed', x === b ? 'true' : 'false'); });
        render();
      });
    });
    $('ov-search').addEventListener('input', function () { state.q = this.value; render(); });
  }

  function loadUi() {
    return window.WLSMON_LIBS.load().then(function (ui) { state.locale = ui.locale; });
  }

  document.addEventListener('DOMContentLoaded', function () {
    initTheme();
    initFilter();
    $('refresh-btn').addEventListener('click', reloadAll);
    loadUi().then(function () { reloadAll(); setInterval(tick, 1000); });
  });
})();
