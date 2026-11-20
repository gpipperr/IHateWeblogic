/*
 * wlsmon.js: frontend of the WLS monitor (IHateWeblogic)
 *
 * Loads the static JSON files (now, day, week, history, patch, security, logs)
 * and renders the host view. Charts through wlsmon_charts.js (Oracle JET from
 * /i/, SVG fallback), icons through wlsmon_libs.js (font-apex, SVG fallback).
 * Masters: 11-wlsmon/docs/02-wlsmon_interface_design.md (colours, texts,
 * formats), 01-wlsmon_concept.md section 3.5 (fields).
 * Taken over from the prototype v3 (2026-11-19).
 *
 * Security rules:
 *  - no innerHTML, no eval: every value goes through textContent / setAttribute
 *  - level values only from a whitelist (LEVEL) into CSS classes
 *  - fetch same-origin only; the browser sends Basic Auth automatically
 *
 * Formats: texts English, date and numbers per locale from ui.json
 * (default de-DE), times in the time zone of the measuring host.
 */
(function () {
  'use strict';

  var API = 'api/';
  var REFRESH_MS = 5 * 60 * 1000; // auto refresh: all data every 5 min (button shows the countdown)
  var SPARK_POINTS = 48; // 4 h at 5-min values

  var LEVEL = {
    ok:    { word: 'OK',    icon: 'check' },
    warn:  { word: 'WARN',  icon: 'triangle' },
    crit:  { word: 'CRIT',  icon: 'times' },
    stale: { word: 'STALE', icon: 'clock' }
  };

  // Fixed colour per entity (rule: the colour follows the entity)
  var ENTITY_SERIES = { WLS_FORMS: 's-1', WLS_REPORTS: 's-2', AdminServer: 's-3' };

  var CHARTS = [
    { title: 'Forms sessions', unit: '', decimals: 0, series: [{ key: 'forms_sessions' }] },
    { title: 'Heap per managed server', unit: ' %', decimals: 0, fixedMax: 100, thr: 'heap_max_pct',
      series: [{ key: 'heap_pct_WLS_FORMS', entity: 'WLS_FORMS' }, { key: 'heap_pct_WLS_REPORTS', entity: 'WLS_REPORTS' }],
      fallback: { key: 'heap_max_pct', title: 'Heap max over all servers' } },
    { title: 'Load (1 min)', unit: '', decimals: 1, thr: 'load1', series: [{ key: 'load1' }] }
  ];

  var RANGE_NOTE = {
    day: '5-minute values · day.json',
    week: 'hourly maximum · week.json',
    history: '12-hour values · history.json'
  };

  var state = { range: 'day', lastGenerated: null, now: null, day: null, cache: {}, demo: null, locale: 'de-DE', tz: undefined };

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

  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }

  // Status icons: font-apex when loaded (wlsmon_libs.js), otherwise inline SVG
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

  // Badge: colour + icon + word
  function badge(level, word) {
    var k = lv(level);
    var b = el('span', 'badge lvl-' + k);
    b.appendChild(icon(LEVEL[k].icon));
    b.appendChild(document.createTextNode(word || LEVEL[k].word));
    return b;
  }

  /* ---------- formats (Intl, no library) ---------- */

  // Time zone of the measuring host from the ISO offset, e.g. +01:00 -> Etc/GMT-1
  function tzFromIso(iso) {
    var m = /([+-])(\d{2}):(\d{2})$/.exec(iso || '');
    if (!m || m[3] !== '00') return undefined;
    var h = parseInt(m[2], 10);
    if (h === 0) return 'UTC';
    return 'Etc/GMT' + (m[1] === '+' ? '-' : '+') + h;
  }

  function fmtNum(v, d) {
    if (!num(v)) return '';
    return new Intl.NumberFormat(state.locale, { minimumFractionDigits: d || 0, maximumFractionDigits: d || 0 }).format(v);
  }

  function fmtDate(d, opts) {
    var o = Object.assign({ timeZone: state.tz }, opts);
    try { return new Intl.DateTimeFormat(state.locale, o).format(d); }
    catch (e) { delete o.timeZone; return new Intl.DateTimeFormat(state.locale, o).format(d); }
  }

  function fmtStamp(iso) {
    var d = new Date(iso);
    if (isNaN(d)) return 'unknown';
    return fmtDate(d, { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false });
  }

  function getJson(name) {
    return fetch(API + name, { cache: 'no-store', credentials: 'same-origin' }).then(function (r) {
      if (!r.ok) throw new Error(name + ': HTTP ' + r.status);
      return r.json();
    });
  }

  /* ---------- render ---------- */

  // Environment: known keys get a fixed word, anything else is shown as given
  var ENV = { prod: 'Production', qa: 'Quality assurance', test: 'Test', dev: 'Development' };

  function renderHeader(now) {
    var product = now.product || 'wlsmon';
    $('product').textContent = product;
    var envKey = typeof now.environment === 'string' ? now.environment.toLowerCase() : '';
    var envBox = $('env');
    var envText = ENV[envKey] || now.environment || '';
    envBox.textContent = envText;
    envBox.hidden = !envText;
    envBox.className = 'env' + (ENV[envKey] ? ' env-' + envKey : '');
    document.title = product + (envText ? ' · ' + envText : '') + ' · wlsmon';
    $('domain').textContent = now.domain || '';
    $('host').textContent = now.host || '';
    $('interval').textContent = fmtNum((now.interval_sec || 300) / 60) + ' min';
    var st = $('stamp-top');
    st.textContent = fmtStamp(now.generated_at);
    st.setAttribute('title', now.generated_at + (state.tz ? ' (' + state.tz + ')' : ''));
    $('poll').textContent = fmtNum(REFRESH_MS / 60000) + ' min';
    $('locale').textContent = state.locale;
    var col = now.collector || {};
    $('collector-info').textContent = (col.version || '?') + (num(col.duration_ms) ? ' · ' + fmtNum(col.duration_ms) + ' ms' : '');
  }

  function renderOverall(now, stale, ageMin) {
    var key = stale ? 'stale' : lv(now.overall && now.overall.level);
    $('overall').className = 'overall lvl-' + key;
    var b = $('overall-badge');
    clear(b);
    b.appendChild(icon(LEVEL[key].icon));
    b.appendChild(el('span', null, stale ? 'STALE ' + fmtNum(ageMin) + ' min' : LEVEL[key].word));

    var s = $('stamp');
    s.textContent = fmtStamp(now.generated_at);
    s.setAttribute('title', now.generated_at + (state.tz ? ' (' + state.tz + ')' : ''));
    $('freshness').textContent = stale
      ? fmtNum(ageMin) + ' min ago, older than 2 intervals'
      : 'current · interval ' + fmtNum((now.interval_sec || 300) / 60) + ' min';

    var r = $('reasons');
    clear(r);
    var list = [];
    if (stale) {
      list.push({ level: 'stale', text: 'No new data for ' + fmtNum(ageMin) + ' min: check the collector' });
    } else if (now.overall && Array.isArray(now.overall.reasons) && now.overall.reasons.length) {
      list = now.overall.reasons.slice(0, 4);
    } else {
      list.push({ level: 'ok', text: 'All components and key figures within limits' });
    }
    // collector errors (broken rule, 401 pause ...) as their own chips, they do not change the host level
    var cerr = now.collector && Array.isArray(now.collector.errors) ? now.collector.errors : [];
    cerr.forEach(function (e) {
      var t = typeof e === 'string' ? { level: 'warn', text: e } : e;
      list.push({ level: t.level || 'warn', text: 'Collector: ' + t.text, collector: true });
    });
    list.forEach(function (x) {
      var k = lv(x.level);
      var c = el('span', 'chip lvl-' + k + (x.collector ? ' collector' : ''));
      c.appendChild(icon(LEVEL[k].icon));
      c.appendChild(el('span', 'sr-word', LEVEL[k].word + ': '));
      c.appendChild(document.createTextNode(x.text));
      r.appendChild(c);
    });
  }

  /* Components from outside to inside: host contains everything,
   * layout.stages gives the order (e.g. nginx → AdminServer|NodeManager →
   * WLS_FORMS → WLS_REPORTS → Database), "parent" nests a component
   * (report servers inside WLS_REPORTS). A component whose requirement or
   * parent is DOWN is shown as blocked: CRIT, with the root cause named. */
  function renderComponents(now, stale) {
    var box = $('components');
    clear(box);
    var comps = now.components || [];
    var byId = {};
    comps.forEach(function (c) { byId[c.id] = c; });

    function rootDown(c, seen) {
      seen = seen || {};
      var req = (c.requires || []).concat(c.parent ? [c.parent] : []);
      for (var i = 0; i < req.length; i++) {
        var p = byId[req[i]];
        if (!p || seen[p.id]) continue;
        seen[p.id] = true;
        if (p.down) return p;
        var rd = rootDown(p, seen);
        if (rd) return rd;
      }
      return null;
    }

    function eff(c) {
      if (stale) return { k: 'stale', word: null, state: c.state };
      var rd = rootDown(c);
      if (rd) return { k: 'crit', word: 'CRIT', state: 'blocked by ' + rd.name, blocked: true };
      return { k: lv(c.level), word: c.word, state: c.state };
    }

    function card(c) {
      var e = eff(c);
      var el1 = el('div', 'comp lvl-' + e.k + (e.blocked ? ' blocked' : ''));
      var head = el('div', 'comp-head');
      head.appendChild(el('span', 'comp-name', c.name));
      head.appendChild(badge(e.k, e.word));
      el1.appendChild(head);
      el1.appendChild(el('span', 'comp-state', e.state));
      if (c.detail) el1.appendChild(el('span', 'comp-detail', c.detail));
      var kids = comps.filter(function (x) { return x.parent === c.id; });
      if (kids.length) {
        var ul = el('ul', 'comp-children');
        ul.setAttribute('aria-label', c.name + ': ' + kids.length + ' servers');
        kids.forEach(function (k) {
          var ek = eff(k);
          var li = el('li', 'child lvl-' + ek.k);
          var top = el('div', 'child-head');
          top.appendChild(el('span', 'child-name', k.name));
          top.appendChild(badge(ek.k, ek.word));
          li.appendChild(top);
          li.appendChild(el('span', 'comp-detail', ek.blocked ? ek.state : (k.detail || k.state)));
          ul.appendChild(li);
        });
        el1.appendChild(ul);
      }
      return el1;
    }

    var host = comps.filter(function (c) { return c.type === 'host'; })[0];
    var stages = now.layout && Array.isArray(now.layout.stages) ? now.layout.stages : null;

    if (!host || !stages) {
      // fallback without layout: flat grid
      var grid = el('div', 'grid grid-comp');
      comps.filter(function (c) { return !c.parent && c.type !== 'host'; }).forEach(function (c) { grid.appendChild(card(c)); });
      box.appendChild(grid);
      return;
    }

    var eh = eff(host);
    var topo = el('div', 'topo lvl-' + eh.k);
    var th = el('div', 'topo-head');
    var tn = el('div', 'topo-name');
    tn.appendChild(el('span', 'eyebrow', 'Server'));
    tn.appendChild(el('span', 'topo-host', host.name));
    // uptime: up since <date>, <n> days (boot time from /proc/stat btime)
    var since = host.since ? new Date(host.since) : null;
    if (since && !isNaN(since)) {
      var ref = (state.demo && now.demo_reference) ? Date.parse(now.demo_reference) : Date.now();
      var days = Math.floor((ref - since.getTime()) / 86400000);
      var up = el('span', 'topo-uptime', 'up since ' + fmtStamp(host.since) + ' · ' + fmtNum(days) + (days === 1 ? ' day' : ' days'));
      up.setAttribute('title', host.since);
      tn.appendChild(up);
    }
    th.appendChild(tn);
    th.appendChild(badge(eh.k, eh.word));
    // host key figures, formatted in the browser
    var hm = el('div', 'topo-metrics');
    var mById = {};
    (now.metrics || []).forEach(function (m) { mById[m.id] = m; });
    [['load1', 'load ', ''], ['cpu_pct', 'CPU ', ' %'], ['mem_free_pct', 'mem free ', ' %'], ['disk_max_pct', 'disk ', ' %']].forEach(function (d) {
      var m = mById[d[0]];
      if (!m || !num(m.value)) return;
      var k = stale ? 'stale' : lv(m.level);
      var sp = el('span', 'topo-metric lvl-' + k);
      if (k !== 'ok') sp.appendChild(icon(LEVEL[k].icon));
      sp.appendChild(document.createTextNode(d[1] + fmtNum(m.value, m.decimals) + d[2]));
      hm.appendChild(sp);
    });
    th.appendChild(hm);
    topo.appendChild(th);

    var flow = el('div', 'flow');
    stages.forEach(function (ids, i) {
      if (i > 0) {
        var ar = el('span', 'flow-arrow', '\u2192');
        ar.setAttribute('aria-hidden', 'true');
        flow.appendChild(ar);
      }
      var st = el('div', 'stage');
      ids.forEach(function (id) { if (byId[id]) st.appendChild(card(byId[id])); });
      flow.appendChild(st);
    });
    topo.appendChild(flow);
    box.appendChild(topo);
  }

  function metricCard(m, ser, stale) {
    var k = stale ? 'stale' : lv(m.level);
    var card = el('div', 'kpi lvl-' + k);
    var head = el('div', 'kpi-head');
    head.appendChild(el('span', 'kpi-label', m.short || m.label));
    head.appendChild(badge(k));
    card.appendChild(head);
    var val = el('div', 'kpi-val');
    var shown = num(m.value) ? fmtNum(m.value, m.decimals) : (m.display !== undefined && m.display !== null ? m.display : 'n/a');
    val.appendChild(el('span', 'kpi-num', shown));
    if (m.unit) val.appendChild(el('span', 'kpi-unit', m.unit));
    card.appendChild(val);
    if (m.series && Array.isArray(ser[m.series])) {
      window.WlsmonCharts.spark(card, ser[m.series].slice(-SPARK_POINTS));
    }
    if (Array.isArray(m.items) && m.items.length) {
      var ul = el('ul', 'kpi-items');
      m.items.forEach(function (it) {
        var ik = stale ? 'stale' : lv(it.level);
        var li = el('li', 'kpi-item lvl-' + ik);
        li.appendChild(el('span', null, it.name));
        var v = el('span', 'kpi-item-val');
        if (ik !== 'ok') v.appendChild(icon(LEVEL[ik].icon));
        v.appendChild(document.createTextNode(fmtNum(it.value, it.decimals) + (it.unit ? ' ' + it.unit : '')));
        li.appendChild(v);
        if (num(it.value) && it.unit === '%') {
          var bar = el('span', 'kpi-item-bar');
          var fill = el('span');
          fill.style.width = Math.max(0, Math.min(100, it.value)) + '%';
          bar.appendChild(fill);
          li.appendChild(bar);
        }
        if (it.sub) li.appendChild(el('span', 'kpi-item-sub', it.sub));
        ul.appendChild(li);
      });
      card.appendChild(ul);
    }
    card.appendChild(el('span', 'kpi-sub', m.sub));
    return card;
  }

  /* Daily facts (concept 4.1): certificate days, patch cycle, Derby, GUI library paths */
  function renderDaily(now, stale) {
    var box = $('daily');
    clear(box);
    var d = now.daily;
    if (!d || !Array.isArray(d.facts)) { box.appendChild(el('span', 'muted small', 'no daily facts yet')); return; }
    $('daily-note').textContent = 'checked ' + fmtStamp(d.generated_at) + ' · once a day';
    d.facts.forEach(function (f) {
      var k = stale ? 'stale' : lv(f.level);
      var c = el('div', 'fact lvl-' + k);
      var h = el('div', 'fact-head');
      h.appendChild(el('span', null, f.label));
      h.appendChild(badge(k));
      c.appendChild(h);
      var val = num(f.value) ? fmtNum(f.value, f.decimals) + (f.unit ? ' ' + f.unit : '') : (f.display || 'n/a');
      c.appendChild(el('span', 'fact-val', val));
      if (f.sub) c.appendChild(el('span', 'fact-sub', f.sub));
      box.appendChild(c);
    });
  }

  /* Key figures follow the component logic: one block per component from
   * outside to inside (Server | nginx | Forms | Reports | Database), each with
   * its own log errors and core dumps. Order from layout.metric_groups. */
  function renderMetrics(now, day, stale) {
    var box = $('metrics');
    clear(box);
    var ser = (day && day.series) || {};
    var metrics = now.metrics || [];
    var groups = now.layout && Array.isArray(now.layout.metric_groups) ? now.layout.metric_groups : null;

    if (!groups) {
      var grid = el('div', 'grid grid-kpi');
      metrics.forEach(function (m) { grid.appendChild(metricCard(m, ser, stale)); });
      box.appendChild(grid);
      return;
    }
    var rank = { ok: 0, warn: 1, crit: 2 };
    var flow = el('div', 'flow kpi-flow');
    groups.forEach(function (g, i) {
      var ms = metrics.filter(function (m) { return m.group === g.id; });
      if (!ms.length) return;
      if (flow.childNodes.length) {
        var ar = el('span', 'flow-arrow', '\u2192');
        ar.setAttribute('aria-hidden', 'true');
        flow.appendChild(ar);
      }
      var worst = 'ok';
      ms.forEach(function (m) { var l = lv(m.level); if (rank[l] > rank[worst]) worst = l; });
      var col = el('div', 'stage kpi-group');
      col.setAttribute('role', 'group');
      col.setAttribute('aria-label', g.title);
      var gh = el('div', 'kpi-group-head lvl-' + (stale ? 'stale' : worst));
      gh.appendChild(el('span', 'kpi-group-title', g.title));
      gh.appendChild(badge(stale ? 'stale' : worst));
      col.appendChild(gh);
      ms.forEach(function (m) { col.appendChild(metricCard(m, ser, stale)); });
      flow.appendChild(col);
    });
    box.appendChild(flow);
  }

  function axisLabels(ts, res) {
    if (!Array.isArray(ts) || ts.length < 2) return [];
    var out = [];
    for (var i = 0; i < 5; i++) {
      var idx = Math.round(i * (ts.length - 1) / 4);
      var d = new Date(ts[idx] * 1000);
      var o = res <= 300 ? { hour: '2-digit', minute: '2-digit', hour12: false }
        : res <= 3600 ? { weekday: 'short', day: '2-digit', month: '2-digit' }
        : { month: 'short', year: 'numeric' };
      out.push(i === 4 ? 'now' : fmtDate(d, o));
    }
    return out;
  }

  function renderTrend(data) {
    var box = $('charts');
    clear(box);
    $('range-note').textContent = RANGE_NOTE[state.range] || '';
    var ser = (data && data.series) || {};
    var thrAll = (data && data.thresholds) || {};

    CHARTS.forEach(function (c) {
      // Series present? Otherwise fall back to the single series (e.g. history)
      var list = c.series.filter(function (s) { return Array.isArray(ser[s.key]); });
      var title = c.title;
      if (!list.length && c.fallback && Array.isArray(ser[c.fallback.key])) {
        list = [{ key: c.fallback.key }];
        title = c.fallback.title;
      }
      var multi = list.length > 1;

      var wrap = el('div', 'chart');
      var head = el('div', 'chart-head');
      head.appendChild(el('span', 'chart-title', title));
      var sum = el('span', 'chart-sum');
      head.appendChild(sum);
      wrap.appendChild(head);

      if (multi) {
        var lg = el('div', 'legend');
        list.forEach(function (s) {
          var it = el('span', 'legend-item');
          var sw = el('span', 'legend-swatch ' + (ENTITY_SERIES[s.entity] || 's-1'));
          it.appendChild(sw);
          it.appendChild(document.createTextNode(s.entity));
          lg.appendChild(it);
        });
        wrap.appendChild(lg);
      }

      var cb = el('div', 'chart-box');
      wrap.appendChild(cb);
      box.appendChild(wrap);

      var all = [];
      list.forEach(function (x) { all = all.concat(ser[x.key].filter(num)); });
      if (all.length > 1) {
        var parts = [];
        list.forEach(function (x) {
          var arr = ser[x.key].filter(num);
          if (!arr.length) return;
          var m = Math.max.apply(null, arr);
          var avg = arr.reduce(function (a, b) { return a + b; }, 0) / arr.length;
          parts.push((multi ? x.entity + ' ' : '') + 'max ' + fmtNum(m, c.decimals) + c.unit + ' · avg ' + fmtNum(avg, c.decimals) + c.unit);
        });
        sum.textContent = parts.join('  |  ');
        var ts = ser.ts || [];
        window.WlsmonCharts.line(cb, {
          title: title,
          height: 110,
          multi: multi,
          top: c.fixedMax || null,
          thresholds: c.thr && Array.isArray(thrAll[c.thr]) ? thrAll[c.thr] : null,
          series: list.map(function (x) {
            var cls = multi ? (ENTITY_SERIES[x.entity] || 's-1') : 's-single';
            return { key: x.key, name: x.entity || title, values: ser[x.key], cls: cls,
                     token: '--wm-series-' + (cls === 's-single' ? 'single' : cls.slice(2)) };
          }),
          tip: function (i, name, v) {
            var when = num(ts[i]) ? fmtStamp(new Date(ts[i] * 1000).toISOString()) : '';
            return when + ' · ' + (multi ? name + ' ' : '') + fmtNum(v, c.decimals) + c.unit;
          }
        });
      } else {
        sum.textContent = 'no data';
      }
    });

    var ax = $('axis');
    clear(ax);
    axisLabels(ser.ts, data && data.resolution_sec).forEach(function (l) { ax.appendChild(el('span', null, l)); });
  }

  function renderAgg(hist) {
    var body = $('agg');
    clear(body);
    var s = (hist && hist.series) || {};
    var ts = s.ts || [];
    var res = (hist && hist.resolution_sec) || 43200;
    function v(a, j) { return Array.isArray(a) && num(a[j]) ? a[j] : null; }
    function hour(d) { return fmtDate(d, { hour: '2-digit', hour12: false }).replace(/\D/g, ''); }

    for (var i = ts.length - 1; i >= Math.max(0, ts.length - 6); i--) {
      var from = new Date(ts[i] * 1000);
      var to = new Date((ts[i] + res) * 1000);
      var hTo = hour(to) === '00' ? '24' : hour(to);
      var period = fmtDate(from, { day: '2-digit', month: '2-digit' }) + ' ' + hour(from) + ':00–' + hTo + ':00' +
        (i === ts.length - 1 ? ' (running)' : '');
      var err = v(s.log_errors, i), core = v(s.core_dumps, i);
      var tr = el('tr');
      tr.appendChild(el('td', null, period));
      var st = el('td');
      st.appendChild(badge(s.level && s.level[i]));
      tr.appendChild(st);
      tr.appendChild(el('td', 'num', fmtNum(v(s.forms_sessions, i))));
      tr.appendChild(el('td', 'num', fmtNum(v(s.reports_jobs, i))));
      tr.appendChild(el('td', 'num', num(v(s.heap_max_pct, i)) ? fmtNum(v(s.heap_max_pct, i)) + ' %' : ''));
      tr.appendChild(el('td', 'num', fmtNum(v(s.load1, i), 1)));
      tr.appendChild(el('td', 'num', num(v(s.mem_free_pct, i)) ? fmtNum(v(s.mem_free_pct, i)) + ' %' : ''));
      tr.appendChild(el('td', 'num' + (err > 0 ? ' hl' : ''), fmtNum(err)));
      tr.appendChild(el('td', 'num' + (core > 0 ? ' hl' : ''), fmtNum(core)));
      body.appendChild(tr);
    }
  }

  /* ---------- loading ---------- */

  function showError(msg) { $('fetch-error').textContent = msg || ''; }

  function loadRange(force) {
    var name = state.range + '.json';
    if (!force && state.cache[state.range]) { renderTrend(state.cache[state.range]); return Promise.resolve(); }
    return getJson(name).then(function (d) {
      state.cache[state.range] = d;
      if (state.range === 'day') state.day = d;
      renderTrend(d);
    });
  }

  function refresh() {
    return getJson('now.json').then(function (now) {
      state.now = now;
      state.tz = tzFromIso(now.generated_at);
      var interval = (now.interval_sec || 300) * 1000;
      // demo mode: age relative to the creation time of the sample data
      var ref = (state.demo && now.demo_reference) ? Date.parse(now.demo_reference) : Date.now();
      var age = ref - Date.parse(now.generated_at);
      var stale = !(age >= 0 && age <= 2 * interval) && !(age < 0 && age > -interval);
      var ageMin = Math.max(0, Math.round(age / 60000));
      var changed = now.generated_at !== state.lastGenerated;

      var staleChanged = state.stale !== stale;
      state.stale = stale;
      renderHeader(now);
      renderOverall(now, stale, ageMin);
      setTabBadge('overview', stale ? 'stale' : lv(now.overall && now.overall.level));
      renderComponents(now, stale);
      renderDaily(now, stale);

      var jobs = [];
      if (changed) {
        state.lastGenerated = now.generated_at;
        state.cache = {};
        jobs.push(getJson('day.json').then(function (d) { state.day = d; state.cache.day = d; }));
        jobs.push(getJson('history.json').then(function (h) { state.cache.history = h; renderAgg(h); }));
        jobs.push(loadExtras());
      } else if (staleChanged) {
        renderPatch(state.extra.patch, stale); renderSecurity(state.extra.security, stale); renderLogs(state.extra.logs, stale);
      }
      return Promise.all(jobs).then(function () {
        renderMetrics(now, state.day, stale);
        return loadRange(false);
      });
    }).then(function () {
      showError('');
    }).catch(function (e) {
      showError('Loading failed: ' + e.message);
      $('overall').className = 'overall lvl-stale';
      var b = $('overall-badge');
      clear(b);
      b.appendChild(icon('clock'));
      b.appendChild(el('span', null, 'STALE'));
    });
  }

  function loadUi() {
    // ui.json (written by 01-install-wlsmon_fmw.sh): locale and the /i/ library paths
    return window.WLSMON_LIBS.load().then(function (ui) {
      state.locale = ui.locale;
      return window.WlsmonCharts.init(ui);
    }).then(function () {
      var notes = window.WLSMON_LIBS.notes.concat([window.WlsmonCharts.note]);
      $('libs-info').textContent = notes.filter(Boolean).join(' · ');
    });
  }

  // redraw the charts after a theme switch (colours come from the CSS tokens)
  function redrawCharts() {
    if (!state.now) return;
    renderMetrics(state.now, state.day, state.stale);
    if (state.cache[state.range]) renderTrend(state.cache[state.range]);
  }

  function initRangeButtons() {
    var btns = document.querySelectorAll('.seg button[data-range]');
    Array.prototype.forEach.call(btns, function (b) {
      b.addEventListener('click', function () {
        state.range = b.getAttribute('data-range');
        Array.prototype.forEach.call(btns, function (x) { x.setAttribute('aria-pressed', x === b ? 'true' : 'false'); });
        loadRange(false).catch(function (e) { showError('Loading failed: ' + e.message); });
      });
    });
  }

  /* ---------- tabs: Overview | Patch level | Security | Log viewer ---------- */

  var TABS = ['overview', 'patch', 'security', 'logs'];
  state.extra = { patch: null, security: null, logs: null };
  state.logFilter = { sev: 'all', server: '', q: '' };

  function selectTab(name, focus) {
    if (TABS.indexOf(name) < 0) name = 'overview';
    TABS.forEach(function (t) {
      var b = $('tab-' + t), p = $('panel-' + t);
      var on = t === name;
      b.setAttribute('aria-selected', on ? 'true' : 'false');
      b.setAttribute('tabindex', on ? '0' : '-1');
      p.hidden = !on;
      if (on && focus) b.focus();
    });
    try { localStorage.setItem('wlsmon-tab', name); } catch (e) { /* not available */ }
  }

  function initTabs() {
    var btns = document.querySelectorAll('.tabs [role="tab"]');
    Array.prototype.forEach.call(btns, function (b) {
      b.addEventListener('click', function () { selectTab(b.getAttribute('data-tab')); });
      // arrow keys move between tabs (WAI-ARIA tabs pattern)
      b.addEventListener('keydown', function (ev) {
        var i = TABS.indexOf(b.getAttribute('data-tab'));
        if (ev.key === 'ArrowRight') { selectTab(TABS[(i + 1) % TABS.length], true); ev.preventDefault(); }
        if (ev.key === 'ArrowLeft') { selectTab(TABS[(i + TABS.length - 1) % TABS.length], true); ev.preventDefault(); }
        if (ev.key === 'Home') { selectTab(TABS[0], true); ev.preventDefault(); }
        if (ev.key === 'End') { selectTab(TABS[TABS.length - 1], true); ev.preventDefault(); }
      });
    });
    var t = 'overview';
    try { t = localStorage.getItem('wlsmon-tab') || 'overview'; } catch (e) { /* not available */ }
    selectTab(t);
  }

  function setTabBadge(name, level, word) {
    var box = document.querySelector('.tab-badge[data-badge="' + name + '"]');
    if (!box) return;
    clear(box);
    if (level) box.appendChild(badge(level, word));
  }

  function fmtDay(iso) {
    var d = new Date(iso);
    return isNaN(d) ? '' : fmtDate(d, { day: '2-digit', month: '2-digit', year: 'numeric' });
  }
  function fmtShort(iso) {
    var d = new Date(iso);
    return isNaN(d) ? '' : fmtDate(d, { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false });
  }
  function td(text, cls) { return el('td', cls || null, text); }
  function tdBadge(level, word) { var c = el('td'); c.appendChild(badge(level, word)); return c; }
  function emptyRow(body, cols, text) {
    var tr = el('tr'); var c = el('td', 'muted', text); c.setAttribute('colspan', cols); tr.appendChild(c); body.appendChild(tr);
  }

  function renderPatch(d, stale) {
    var comps = $('patch-components'), list = $('patch-list'), sum = $('patch-summary');
    clear(comps); clear(list); clear(sum);
    if (!d) { emptyRow(comps, 6, 'patch.json not available'); setTabBadge('patch', null); return; }
    var k = stale ? 'stale' : lv(d.level);
    setTabBadge('patch', k);
    $('patch-note').textContent = 'checked ' + fmtShort(d.generated_at) + ' · daily';
    sum.appendChild(badge(k));
    if (d.baseline) {
      var b = el('span');
      b.appendChild(document.createTextNode('Expected CPU '));
      b.appendChild(el('strong', null, d.baseline.cpu));
      b.appendChild(document.createTextNode(' · installed '));
      b.appendChild(el('strong', null, d.baseline.installed));
      if (d.baseline.text) b.appendChild(document.createTextNode(' · ' + d.baseline.text));
      sum.appendChild(b);
    }
    (d.components || []).forEach(function (c) {
      var tr = el('tr');
      tr.appendChild(td(c.name));
      tr.appendChild(tdBadge(stale ? 'stale' : c.level));
      tr.appendChild(td(c.version, 'mono'));
      tr.appendChild(td(c.patch_level));
      tr.appendChild(td(c.applied ? fmtDay(c.applied) : ''));
      tr.appendChild(td(c.note || '', 'wrap-text'));
      comps.appendChild(tr);
    });
    (d.patches || []).forEach(function (p) {
      var tr = el('tr');
      tr.appendChild(td(p.id, 'mono'));
      tr.appendChild(td(p.description, 'wrap-text'));
      tr.appendChild(td(p.home, 'mono'));
      tr.appendChild(td(fmtDay(p.applied)));
      list.appendChild(tr);
    });
    if (!(d.patches || []).length) emptyRow(list, 4, 'no patches listed');
  }

  function renderSecurity(d, stale) {
    var body = $('sec-checks'), sum = $('sec-summary');
    clear(body); clear(sum);
    if (!d) { emptyRow(body, 5, 'security.json not available'); setTabBadge('security', null); return; }
    var k = stale ? 'stale' : lv(d.level);
    setTabBadge('security', k);
    $('sec-note').textContent = 'checked ' + fmtShort(d.generated_at) + ' · hourly';
    var cnt = { ok: 0, warn: 0, crit: 0 };
    (d.checks || []).forEach(function (c) { var l = lv(c.level); if (cnt[l] !== undefined) cnt[l]++; });
    sum.appendChild(badge(k));
    sum.appendChild(el('span', null, (d.checks || []).length + ' checks · ' + cnt.crit + ' CRIT · ' + cnt.warn + ' WARN · ' + cnt.ok + ' OK'));
    var rank = { crit: 0, warn: 1, ok: 2, stale: 3 };
    (d.checks || []).slice().sort(function (a, b) { return rank[lv(a.level)] - rank[lv(b.level)]; }).forEach(function (c) {
      var tr = el('tr');
      tr.appendChild(tdBadge(stale ? 'stale' : c.level));
      tr.appendChild(td(c.area));
      tr.appendChild(td(c.name));
      tr.appendChild(td(c.result, 'wrap-text'));
      tr.appendChild(td(c.hint || '', 'wrap-text muted'));
      body.appendChild(tr);
    });
  }

  var SEV = { critical: { level: 'crit', word: 'CRITICAL' }, error: { level: 'warn', word: 'ERROR' } };

  function renderLogs(d, stale) {
    var body = $('logs-events'), sum = $('logs-summary');
    clear(body); clear(sum);
    if (!d) { emptyRow(body, 7, 'logs.json not available'); clear($('logs-rules')); setTabBadge('logs', null); return; }
    var k = stale ? 'stale' : lv(d.level);
    var tot = d.totals || {};
    setTabBadge('logs', k, k === 'ok' || k === 'stale' ? null : String((tot.critical || 0) + (tot.error || 0)));
    $('logs-note').textContent = 'window ' + (d.window || '24 h') + ' · updated ' + fmtShort(d.generated_at);
    sum.appendChild(badge(k));
    sum.appendChild(el('span', null, fmtNum(tot.critical || 0) + ' critical · ' + fmtNum(tot.error || 0) + ' error · ' + fmtNum(tot.warning || 0) + ' warning' + (num(d.ignored) ? ' · ' + fmtNum(d.ignored) + ' ignored by rules' : '')));

    // server list for the filter (keep the selection)
    var sel = $('logs-server'), cur = state.logFilter.server;
    var servers = {};
    (d.events || []).forEach(function (e) { servers[e.server] = true; });
    while (sel.options.length > 1) sel.remove(1);
    Object.keys(servers).sort().forEach(function (n) {
      var o = el('option', null, n); o.value = n; if (n === cur) o.selected = true; sel.appendChild(o);
    });

    var f = state.logFilter, q = f.q.toLowerCase();
    var rows = (d.events || []).filter(function (e) {
      if (f.sev !== 'all' && e.severity !== f.sev) return false;
      if (f.server && e.server !== f.server) return false;
      if (q && (String(e.code) + ' ' + String(e.rule) + ' ' + String(e.text)).toLowerCase().indexOf(q) < 0) return false;
      return true;
    }).sort(function (a, b) { return Date.parse(b.last_seen) - Date.parse(a.last_seen); });

    rows.forEach(function (e) {
      var tr = el('tr');
      tr.appendChild(td(fmtShort(e.last_seen)));
      var sv = SEV[e.severity];
      if (sv && !stale) tr.appendChild(tdBadge(sv.level, sv.word));
      else { var c = el('td'); c.appendChild(el('span', 'sev-plain', String(e.severity || '').toUpperCase())); tr.appendChild(c); }
      tr.appendChild(td(e.code, 'mono'));
      tr.appendChild(td(e.rule || '', 'mono'));
      tr.appendChild(td(e.server));
      tr.appendChild(td(fmtNum(e.count), 'num'));
      tr.appendChild(td(e.text, 'wrap-text'));
      body.appendChild(tr);
    });
    if (!rows.length) emptyRow(body, 7, 'no events for this filter');
    renderRules(d);
  }

  // hits per rule id, ignored entries included: a rule that suddenly drops thousands stands out
  function renderRules(d) {
    var body = $('logs-rules');
    clear(body);
    var rules = (d && d.rules) || [];
    rules.slice().sort(function (a, b) {
      if (a.type !== b.type) return a.type === 'match' ? -1 : 1;
      return (b.hits || 0) - (a.hits || 0);
    }).forEach(function (r) {
      var tr = el('tr', r.type === 'ignore' ? 'rule-ignore' : null);
      tr.appendChild(td(r.id, 'mono'));
      tr.appendChild(td(r.type));
      if (r.type === 'match' && LEVEL[r.level]) tr.appendChild(tdBadge(r.level));
      else { var c = el('td'); c.appendChild(el('span', 'sev-plain', r.type === 'ignore' ? 'IGNORE' : String(r.level))); tr.appendChild(c); }
      tr.appendChild(td(r.source, 'mono'));
      tr.appendChild(td(fmtNum(r.hits || 0), 'num' + (r.hits ? ' hl' : '')));
      tr.appendChild(td(r.reason || '', 'wrap-text'));
      body.appendChild(tr);
    });
    if (!rules.length) emptyRow(body, 6, 'no rule statistics in logs.json');
  }

  function initLogFilter() {
    var btns = document.querySelectorAll('.seg button[data-sev]');
    Array.prototype.forEach.call(btns, function (b) {
      b.addEventListener('click', function () {
        state.logFilter.sev = b.getAttribute('data-sev');
        Array.prototype.forEach.call(btns, function (x) { x.setAttribute('aria-pressed', x === b ? 'true' : 'false'); });
        renderLogs(state.extra.logs, state.stale);
      });
    });
    $('logs-server').addEventListener('change', function () {
      state.logFilter.server = this.value; renderLogs(state.extra.logs, state.stale);
    });
    $('logs-search').addEventListener('input', function () {
      state.logFilter.q = this.value; renderLogs(state.extra.logs, state.stale);
    });
  }

  function loadExtras() {
    function opt(name) { return getJson(name).catch(function () { return null; }); }
    return Promise.all([opt('patch.json'), opt('security.json'), opt('logs.json')]).then(function (r) {
      state.extra.patch = r[0]; state.extra.security = r[1]; state.extra.logs = r[2];
      renderPatch(r[0], state.stale); renderSecurity(r[1], state.stale); renderLogs(r[2], state.stale);
    });
  }

  /* ---------- auto refresh: countdown in the header, click = reload now ---------- */

  var refreshAt = 0, refreshBusy = false;

  function fmtCountdown(ms) {
    var sec = Math.max(0, Math.ceil(ms / 1000));
    var m = Math.floor(sec / 60), s2 = sec % 60;
    return m + ':' + (s2 < 10 ? '0' : '') + s2;
  }

  function reloadAll() {
    if (refreshBusy) return;
    refreshBusy = true;
    var btn = $('refresh-btn');
    btn.classList.add('busy');
    btn.setAttribute('aria-busy', 'true');
    // force a full reload of every file (not only when now.json changed)
    state.lastGenerated = null;
    state.cache = {};
    refresh().then(function () {
      refreshBusy = false;
      btn.classList.remove('busy');
      btn.removeAttribute('aria-busy');
      refreshAt = Date.now() + REFRESH_MS;
      tick();
    });
  }

  function tick() {
    var left = refreshAt - Date.now();
    if (left <= 0 && !refreshBusy) { reloadAll(); return; }
    var txt = fmtCountdown(left);
    $('refresh-timer').textContent = txt;
    $('refresh-btn').setAttribute('aria-label', 'Refresh now, next automatic refresh in ' + txt);
  }

  function initAutoRefresh() {
    $('refresh-btn').addEventListener('click', reloadAll);
    reloadAll();
    setInterval(tick, 1000);
  }

  /* ---------- colour mode: auto (system) / light / dark ---------- */

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
      redrawCharts();
    });
  }

  /* ---------- demo mode (development / presentation only) ----------
   * Active with #demo-<scenario> in the URL or data-demo="<scenario>" on <body>.
   * Then loads api/demo/<scenario>/*.json (see tools/gen_sample_data.py --all-scenarios).
   * Without either: production mode with api/*.json. */
  var DEMO = { normal: 'Normal', warn: 'Warning', crit: 'Critical', nginxdown: 'nginx down', rcu: 'RCU login', stale: 'Stale data' };

  function demoScenario() {
    var m = /^#demo-([a-z]+)$/.exec(location.hash || '');
    if (m && DEMO[m[1]]) return m[1];
    var b = document.body.getAttribute('data-demo');
    return b && DEMO[b] ? b : null;
  }

  // Which host: ?host=<id> reads the pulled copy hosts/<id>/ on the GUI host A
  // (concept 3.3); without it the own data in api/ (phase 1, single host).
  function hostParam() {
    var m = /[?&]host=([A-Za-z0-9._-]{1,64})(&|$)/.exec(location.search || '');
    return m ? m[1] : null;
  }

  function applyMode() {
    var sc = demoScenario();
    state.demo = sc;
    var h = hostParam();
    API = sc ? 'api/demo/' + sc + '/' : (h ? 'hosts/' + h + '/' : 'api/');
    state.cache = {};
    state.lastGenerated = null;
    var box = $('demo');
    if (!box) return;
    clear(box);
    box.hidden = !sc;
    if (!sc) return;
    box.appendChild(el('span', 'muted small', 'Demo scenario'));
    Object.keys(DEMO).forEach(function (k) {
      var a = el('a', 'demo-link', DEMO[k]);
      a.setAttribute('href', '#demo-' + k);
      if (k === sc) a.setAttribute('aria-current', 'true');
      box.appendChild(a);
    });
  }

  document.addEventListener('DOMContentLoaded', function () {
    initTheme();
    applyMode();
    window.addEventListener('hashchange', function () { applyMode(); refresh(); });
    initRangeButtons();
    initTabs();
    initLogFilter();
    loadUi().then(function () {
      initAutoRefresh();
    });
  });
})();
