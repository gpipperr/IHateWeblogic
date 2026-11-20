/*
 * wlsmon_charts.js: chart layer of the wlsmon GUI (IHateWeblogic)
 *
 * One interface, two renderers (development plan step 4):
 *   - "jet": Oracle JET oj-chart from the APEX libraries under /i/ (decision
 *     2026-11-19: JET only for the charts). Loaded like APEX does it: jQuery and
 *     jQuery UI as globals first, then RequireJS with small AMD shims, then
 *     ojs/ojchart + ojs/ojarraydataprovider. No Knockout, no binding
 *     expressions - every property is set from JavaScript, so the strict CSP
 *     (no unsafe-eval) stays; data-oj-binding-provider="none" tells JET not to
 *     wait for Knockout.
 *   - "svg": the own SVG of the prototype - the fallback when ui.json has no
 *     JET path, a library is missing or does not load in time.
 *
 * Colours come from the CSS tokens of wlsmon.css (interface design section 4),
 * read at draw time, so a theme switch only needs a redraw.
 *
 *   WlsmonCharts.init(ui)            -> Promise<"jet"|"svg">
 *   WlsmonCharts.spark(box, values)  sparkline in a key-figure tile
 *   WlsmonCharts.line(box, spec)     trend chart, spec:
 *       { title, height, series: [{ key, name, values, token, cls }], multi,
 *         top, thresholds: [warn, crit] | null, tip: function (i, name, v) }
 *
 * Plain ES5, no innerHTML (checked with tools/js_syntax_check.sh).
 */
(function (global) {
  'use strict';

  var LOAD_TIMEOUT_MS = 10000;
  var SVGNS = 'http://www.w3.org/2000/svg';

  var charts = { renderer: 'svg', note: '', jet: null };

  function num(v) { return typeof v === 'number' && isFinite(v); }

  function svg(tag, attrs) {
    var e = document.createElementNS(SVGNS, tag);
    Object.keys(attrs || {}).forEach(function (k) { e.setAttribute(k, attrs[k]); });
    return e;
  }

  function token(name, fallback) {
    var v = getComputedStyle(document.documentElement).getPropertyValue(name);
    v = (v || '').trim();
    return v || fallback;
  }

  function scaleTop(all, spec) {
    var mx = Math.max.apply(null, all);
    var t = spec.thresholds;
    return spec.top || Math.max(mx * 1.15, t ? t[0] * 1.1 : 0, 1);
  }

  /* ---------- loading JET ---------- */

  function loadScript(src) {
    return new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = src;
      s.async = false;
      s.onload = function () { resolve(); };
      s.onerror = function () { reject(new Error('not found: ' + src)); };
      document.head.appendChild(s);
    });
  }

  function addCss(href) {
    return new Promise(function (resolve, reject) {
      var l = document.createElement('link');
      l.rel = 'stylesheet';
      l.href = href;
      l.onload = function () { resolve(); };
      l.onerror = function () { reject(new Error('not found: ' + href)); };
      document.head.appendChild(l);
    });
  }

  // AMD shims for the globals, as in APEX libraries/apex/requirejs.jetConfig.js
  function configureRequire(jetBase, locale, knockout) {
    var $ = global.jQuery;
    var d = global.define;
    d('jquery', [], function () { return $; });
    d('hammerjs', [], function () { return global.Hammer || {}; });
    d('jqueryui-amd/widget', [], function () { return $.widget; });
    d('jqueryui-amd/focusable', [], function () { return $.ui.focusable; });
    d('jqueryui-amd/keycode', [], function () { return $.ui.keyCode; });
    d('jqueryui-amd/unique-id', [], function () { return $.fn; });
    d('jqueryui-amd/tabbable', [], function () { return $.ui.tabbable || {}; });
    d('jqueryui-amd/position', [], function () { return $.ui.position; });
    var libs = jetBase.replace(/\/$/, '') + '/js/libs/';
    var v = /\/(\d+\.\d+\.\d+)\/?$/.exec(jetBase);
    var ver = v ? v[1] : '';
    global.requirejs.config({
      baseUrl: libs,
      waitSeconds: Math.round(LOAD_TIMEOUT_MS / 1000),
      paths: {
        'ojs': 'oj/' + ver + '/min',
        'ojL10n': 'oj/' + ver + '/ojL10n',
        'ojtranslations': 'oj/' + ver + '/resources',
        'ojdnd': 'dnd-polyfill/dnd-polyfill-1.0.2.min',
        'touchr': 'touchr/touchr',
        'signals': 'js-signals/signals.min',
        'text': 'require/text',
        'css': 'require-css/css.min',
        'normalize': 'require-css/normalize',
        '@oracle/oraclejet-preact': 'oraclejet-preact/amd',
        'preact': 'preact/dist/preact.umd',
        'preact/hooks': 'preact/hooks/dist/hooks.umd',
        'preact/compat': 'preact/compat/dist/compat.umd',
        'preact/jsx-runtime': 'preact/jsx-runtime/dist/jsxRuntime.umd',
        // the DVT DataProvider path loads ojtemplateengine-ko, which requires
        // knockout - loaded, never bound (no ko.applyBindings, no eval)
        'knockout': knockout
      },
      config: { ojL10n: { locale: (locale || 'en').toLowerCase() } }
    });
  }

  function requireP(mods) {
    return new Promise(function (resolve, reject) {
      global.requirejs(mods, function () { resolve(Array.prototype.slice.call(arguments)); },
        function (err) { reject(new Error('RequireJS: ' + (err && err.message ? err.message : err))); });
    });
  }

  function loadJet(ui) {
    var l = ui.libs || {};
    if (!l.jet) return Promise.reject(new Error('no JET path in ui.json'));
    if (!l.jquery || !l.jquery_ui) return Promise.reject(new Error('jQuery paths missing in ui.json'));
    if (!l.knockout) return Promise.reject(new Error('knockout path missing in ui.json (DVT template engine)'));
    var jet = l.jet.replace(/\/$/, '');
    var chain = Promise.resolve();
    if (ui.jet_theme) {
      chain = chain.then(function () {
        var v = /\/(\d+\.\d+\.\d+)$/.exec(jet);
        return addCss(jet + '/css/libs/oj/' + (v ? v[1] : '') + '/redwood/oj-redwood-notag-min.css');
      });
    }
    chain = chain
      .then(function () { return global.jQuery ? null : loadScript(l.jquery); })
      .then(function () { return global.jQuery.ui ? null : loadScript(l.jquery_ui); })
      .then(function () { return loadScript(jet + '/js/libs/require/require.js'); })
      .then(function () {
        configureRequire(jet, ui.locale, l.knockout);
        return requireP(['ojs/ojarraydataprovider', 'ojs/ojchart']);
      })
      .then(function (mods) {
        var ADP = mods[0] && mods[0]['default'] ? mods[0]['default'] : mods[0];
        if (typeof ADP !== 'function') throw new Error('ArrayDataProvider not loaded');
        return ADP;
      });
    var limit = new Promise(function (resolve, reject) {
      setTimeout(function () { reject(new Error('JET: timeout after ' + LOAD_TIMEOUT_MS / 1000 + ' s')); },
        LOAD_TIMEOUT_MS);
    });
    return Promise.race([chain, limit]);
  }

  charts.init = function (ui) {
    if (!ui || ui.charts !== 'jet') {
      charts.renderer = 'svg';
      charts.note = 'SVG charts (no JET path in ui.json)';
      return Promise.resolve(charts.renderer);
    }
    var t0 = Date.now();
    return loadJet(ui).then(function (ADP) {
      charts.jet = { ADP: ADP, ms: Date.now() - t0 };
      charts.renderer = 'jet';
      charts.note = 'Oracle JET charts (' + charts.jet.ms + ' ms)';
      return 'jet';
    }).catch(function (e) {
      charts.renderer = 'svg';
      charts.note = 'SVG charts - JET not used: ' + e.message;
      if (global.console) global.console.warn('wlsmon: ' + charts.note);
      return 'svg';
    });
  };

  /* ---------- SVG renderer (prototype) ---------- */

  function svgSpark(box, values) {
    var a = values.filter(num);
    if (a.length < 2) return false;
    var mn = Math.min.apply(null, a), mx = Math.max.apply(null, a), d = (mx - mn) || 1;
    var pts = a.map(function (v, i) {
      return (i * 100 / (a.length - 1)).toFixed(1) + ',' + (26 - ((v - mn) / d) * 24).toFixed(1);
    }).join(' ');
    var s = svg('svg', { viewBox: '0 0 100 28', preserveAspectRatio: 'none', 'class': 'spark', 'aria-hidden': 'true' });
    s.appendChild(svg('polyline', { points: pts }));
    box.appendChild(s);
    return true;
  }

  function svgLine(box, spec) {
    var H = spec.height || 110;
    var s = svg('svg', { viewBox: '0 0 1000 ' + H, preserveAspectRatio: 'none', role: 'img', 'aria-label': spec.title });
    var all = [];
    spec.series.forEach(function (x) { all = all.concat(x.values.filter(num)); });
    if (all.length > 1) {
      var t = spec.thresholds;
      var top = scaleTop(all, spec);
      var y = function (v) { return (H - Math.min(v, top) / top * (H - 6)).toFixed(1); };
      [0.25, 0.5, 0.75].forEach(function (f) {
        s.appendChild(svg('line', { x1: 0, x2: 1000, y1: y(top * f), y2: y(top * f), 'class': 'grid-line' }));
      });
      if (t) {
        if (t[0] <= top) s.appendChild(svg('line', { x1: 0, x2: 1000, y1: y(t[0]), y2: y(t[0]), 'class': 'thr-warn' }));
        if (t[1] <= top) s.appendChild(svg('line', { x1: 0, x2: 1000, y1: y(t[1]), y2: y(t[1]), 'class': 'thr-crit' }));
      }
      spec.series.forEach(function (x) {
        var arr = x.values.filter(num);
        if (arr.length < 2) return;
        var pts = arr.map(function (v, i) { return (i * 1000 / (arr.length - 1)).toFixed(1) + ',' + y(v); }).join(' ');
        if (!spec.multi) s.appendChild(svg('polygon', { points: '0,' + H + ' ' + pts + ' 1000,' + H, 'class': x.cls }));
        s.appendChild(svg('polyline', { points: pts, 'class': x.cls }));
      });
    }
    box.appendChild(s);
  }

  /* ---------- JET renderer ---------- */

  // tip(i, name, v) -> text: becomes shortDesc, which JET shows as the tooltip
  // (and reads to screen readers) - no tooltip renderer, no DOM of our own
  function jetItems(series, tip) {
    var items = [];
    series.forEach(function (x) {
      x.values.forEach(function (v, i) {
        if (!num(v)) return;
        // groupId is an ARRAY (hierarchical groups) - a string is split into characters
        var it = { id: x.key + '_' + i, seriesId: x.name || x.key, groupId: [String(i)], value: v };
        if (tip) it.shortDesc = tip(i, x.name || x.key, v);
        items.push(it);
      });
    });
    return items;
  }

  function jetChart(box, cls, height) {
    // Without Knockout a JET element waits for a binding provider and never
    // renders (properties stay pending). "none" lets it render at once - the
    // attribute is looked up on the element and its ancestors.
    box.setAttribute('data-oj-binding-provider', 'none');
    var ch = document.createElement('oj-chart');
    ch.setAttribute('data-oj-binding-provider', 'none');
    ch.className = cls;
    ch.animationOnDisplay = 'none';
    ch.animationOnDataChange = 'none';
    ch.hoverBehavior = 'none';
    ch.legend = { rendered: 'off' };
    ch.orientation = 'vertical';
    box.appendChild(ch);
    return ch;
  }

  function jetSpark(box, values) {
    var a = values.filter(num);
    if (a.length < 2) return false;
    var ch = jetChart(box, 'spark jet-spark', 28);
    var c = token('--wm-series-single', '#333333');
    ch.type = 'line';
    ch.styleDefaults = { colors: [c], lineWidth: 1.5, markerDisplayed: 'off' };
    ch.xAxis = { rendered: 'off' };
    ch.yAxis = { rendered: 'off', min: Math.min.apply(null, a), max: Math.max.apply(null, a) };
    ch.plotArea = { backgroundColor: 'rgba(0,0,0,0)', borderWidth: 0 };
    ch.tooltip = { renderer: function () { return { preventDefault: true }; } };
    ch.data = new charts.jet.ADP(jetItems([{ key: 's', values: a }]), { keyAttributes: 'id' });
    return true;
  }

  function jetLine(box, spec) {
    var all = [];
    spec.series.forEach(function (x) { all = all.concat(x.values.filter(num)); });
    if (all.length < 2) return;
    var top = scaleTop(all, spec);
    var ink2 = token('--wm-ink-2', '#333333');
    var grid = token('--wm-grid', '#e8e8e8');
    var axis = token('--wm-axis', '#888888');
    var refs = [];
    var t = spec.thresholds;
    if (t) {
      // location front: a "back" line on a major tick (80 of 0..100) is hidden by the grid line
      if (t[0] <= top) refs.push({ type: 'line', value: t[0], color: token('--wm-warn', '#e67700'), lineStyle: 'dashed', lineWidth: 1.5, text: 'warn limit ' + t[0], location: 'front', displayInLegend: 'off' });
      if (t[1] <= top) refs.push({ type: 'line', value: t[1], color: token('--wm-crit', '#d03b3b'), lineStyle: 'dashed', lineWidth: 1.5, text: 'crit limit ' + t[1], location: 'front', displayInLegend: 'off' });
    }
    var ch = jetChart(box, 'jet-chart', spec.height || 110);
    ch.type = spec.multi ? 'line' : 'lineWithArea';
    ch.styleDefaults = {
      colors: spec.series.map(function (x) { return token(x.token, '#333333'); }),
      lineWidth: 2,
      markerDisplayed: 'off',
      dataItemGaps: 'auto',
      tooltipLabelStyle: { color: ink2 }
    };
    ch.xAxis = { tickLabel: { rendered: 'off' }, majorTick: { rendered: 'off' }, axisLine: { lineColor: axis } };
    ch.yAxis = {
      min: 0, max: top,
      majorTick: { lineColor: grid, lineWidth: 1 },
      axisLine: { lineColor: axis },
      tickLabel: { style: { color: ink2, fontSize: '11px' } },
      referenceObjects: refs
    };
    ch.plotArea = { backgroundColor: token('--wm-surface', '#ffffff') };
    // lines without markers get a tooltip only through the data cursor
    // ("auto" = touch devices only); snap = nearest point of the time axis
    ch.dataCursor = 'on';
    ch.dataCursorBehavior = 'snap';
    ch.hoverBehavior = 'dim';
    ch.data = new charts.jet.ADP(jetItems(spec.series, spec.tip), { keyAttributes: 'id' });
  }

  /* ---------- public, with fallback per chart ---------- */

  charts.spark = function (box, values) {
    if (charts.renderer === 'jet') {
      try { return jetSpark(box, values); } catch (e) { charts.note = 'JET sparkline failed: ' + e.message; }
    }
    return svgSpark(box, values);
  };

  charts.line = function (box, spec) {
    if (charts.renderer === 'jet') {
      try { jetLine(box, spec); return; } catch (e) { charts.note = 'JET chart failed: ' + e.message; }
      while (box.firstChild) box.removeChild(box.firstChild);
    }
    svgLine(box, spec);
  };

  global.WlsmonCharts = charts;
})(window);
