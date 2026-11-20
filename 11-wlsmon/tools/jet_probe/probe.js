/*
 * probe.js: JET spike of the wlsmon development plan (step 3). Loads JET the
 * same way as the GUI (wlsmon_charts.js), draws the three chart kinds and
 * reports load time, renderer and whether the charts produced SVG content.
 */
(function () {
  'use strict';
  function out(text) {
    var li = document.createElement('li');
    li.textContent = text;
    document.getElementById('result').appendChild(li);
    if (window.console) window.console.warn('probe: ' + text);
  }
  function wave(n, base, amp, seed) {
    var a = [];
    for (var i = 0; i < n; i++) a.push(Math.round((base + amp * Math.sin((i + seed) / 9) + 3 * Math.cos(i / 2)) * 10) / 10);
    return a;
  }
  document.addEventListener('DOMContentLoaded', function () {
    var t0 = Date.now();
    window.WLSMON_LIBS.load().then(function (ui) {
      out('probe v3 (binding provider none) · ui.json libs: ' + JSON.stringify(ui.libs) +
          ' · icon font: ' + window.WLSMON_LIBS.iconFont);
      return window.WlsmonCharts.init(ui);
    }).then(function (r) {
      out('renderer: ' + r + ' · ' + window.WlsmonCharts.note + ' · total ' + (Date.now() - t0) + ' ms');
      var C = window.WlsmonCharts;
      C.line(document.getElementById('c1'), {
        title: 'probe 1', height: 110, multi: true, top: 100, thresholds: [80, 90],
        series: [{ key: 'a', name: 'WLS_FORMS', values: wave(288, 60, 20, 0), token: '--wm-series-1', cls: 's-1' },
                 { key: 'b', name: 'WLS_REPORTS', values: wave(288, 50, 15, 30), token: '--wm-series-2', cls: 's-2' }],
        tip: function (i, name, v) { return 'point ' + i + ' · ' + name + ' ' + v + ' %'; }
      });
      C.line(document.getElementById('c2'), {
        title: 'probe 2', height: 110, multi: false, top: null, thresholds: [8, 16],
        series: [{ key: 'l', name: 'Load', values: wave(168, 3, 2, 5), token: '--wm-series-single', cls: 's-single' }],
        tip: function (i, name, v) { return 'point ' + i + ' · ' + v; }
      });
      C.spark(document.getElementById('c3'), wave(48, 40, 10, 2));
      setTimeout(function () {
        var charts = document.querySelectorAll('oj-chart');
        var withSvg = 0;
        Array.prototype.forEach.call(charts, function (c) { if (c.querySelector('svg')) withSvg++; });
        out('oj-chart elements: ' + charts.length + ' · rendered with SVG content: ' + withSvg +
            (C.note ? ' · note: ' + C.note : ''));
        // diagnosis when nothing rendered: upgrade state, size, theme CSS
        out('customElements oj-chart defined: ' + !!(window.customElements && customElements.get('oj-chart')) +
            ' · JET theme CSS variables: ' + (getComputedStyle(document.documentElement)
              .getPropertyValue('--oj-core-text-color-primary').trim() || 'none') +
            ' · ui.json jet_theme: ' + !!window.WLSMON_LIBS.ui.jet_theme);
        Array.prototype.forEach.call(charts, function (c, i) {
          out('chart ' + (i + 1) + ': class="' + c.className + '" · ' + c.offsetWidth + 'x' + c.offsetHeight +
              ' px · children ' + c.childElementCount + ' · data ' + (c.data ? 'set' : 'missing') +
              ' · binding provider ' + (c.closest('[data-oj-binding-provider]') ?
                c.closest('[data-oj-binding-provider]').getAttribute('data-oj-binding-provider') : 'none set'));
        });
        if (window.performance && performance.getEntriesByType) {
          var res = performance.getEntriesByType('resource');
          var bytes = 0, n = 0;
          res.forEach(function (e) { if (/\/i\//.test(e.name)) { n++; bytes += e.transferSize || e.encodedBodySize || 0; } });
          out('/i/ resources: ' + n + ' files · ' + Math.round(bytes / 1024) + ' KB transferred');
        }
      }, 3000);
    });
  });
})();
