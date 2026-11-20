/*
 * wlsmon_libs.js: ui.json and the APEX libraries under /i/ (IHateWeblogic wlsmon)
 *
 * ui.json is written by 01-install-wlsmon_fmw.sh:
 *   { "locale": "de-DE",
 *     "charts": "jet",                              optional, "svg" = no JET
 *     "libs": { "font_apex": "/i/libraries/font-apex/2.5.1",
 *               "jet":       "/i/libraries/oraclejet/20.1.4",
 *               "jquery":    "/i/libraries/jquery/3.7.1/jquery-3.7.1.min.js",
 *               "jquery_ui": "/i/libraries/jquery-ui/1.14.1/jquery-ui-apex.min.js",
 *               "knockout":  "/i/libraries/oraclejet/20.1.4/js/libs/knockout/knockout-3.5.1" },
 *     "jet_theme": true }                           default true: load oj-redwood-notag
 * Without "libs" (repository default) the page runs on its own inline SVG
 * icons and SVG charts.
 *
 * Icons: font-apex (concept section 7). The inline SVG of the prototype stays
 * as the fallback when the font does not load - a status never depends on a
 * library (colour + icon + word, interface design section 3).
 *
 * Security: only same-origin paths of a fixed form are accepted, no inline
 * code, no innerHTML - every value goes through textContent / setAttribute.
 * Plain ES5 (checked with tools/js_syntax_check.sh).
 */
(function (global) {
  'use strict';

  var FA = {             // status icon name of the prototype -> font-apex class
    check: 'fa-check-circle',
    triangle: 'fa-exclamation-triangle',
    times: 'fa-times-circle',
    clock: 'fa-clock-o',
    refresh: 'fa-refresh'
  };
  var PATH_RE = /^\/?i\/[A-Za-z0-9._\/-]+$/;
  var LOCALE_RE = /^[a-z]{2}(-[A-Z]{2})?$/;
  var FONT_TIMEOUT_MS = 2500;

  var lib = {
    ui: { locale: 'de-DE', charts: 'svg', libs: {} },
    iconFont: false,
    loaded: null,
    notes: []          // why a library is not used - shown in the footer
  };

  function safePath(p) {
    return typeof p === 'string' && PATH_RE.test(p) && p.indexOf('..') < 0 ? p : null;
  }

  function validate(raw) {
    var ui = { locale: 'de-DE', charts: 'svg', libs: {} };
    if (!raw || typeof raw !== 'object') return ui;
    if (typeof raw.locale === 'string' && LOCALE_RE.test(raw.locale)) ui.locale = raw.locale;
    var l = raw.libs && typeof raw.libs === 'object' ? raw.libs : {};
    ['font_apex', 'jet', 'jquery', 'jquery_ui', 'knockout'].forEach(function (k) {
      var p = safePath(l[k]);
      if (p) ui.libs[k] = p;
      else if (l[k] !== undefined) lib.notes.push('ui.json: libs.' + k + ' ignored (not an /i/ path)');
    });
    ui.charts = raw.charts === 'svg' ? 'svg' : (ui.libs.jet ? 'jet' : 'svg');
    // oj-redwood-notag: needed - without it oj-chart shows its unstyled
    // "loading" text (JET spike 2026-11-19); false only for a comparison test
    ui.jet_theme = raw.jet_theme !== false;
    return ui;
  }

  function addCss(href) {
    return new Promise(function (resolve, reject) {
      var l = document.createElement('link');
      l.rel = 'stylesheet';
      l.href = href;
      l.onload = function () { resolve(); };
      l.onerror = function () { reject(new Error('stylesheet not found: ' + href)); };
      document.head.appendChild(l);
    });
  }

  function timeout(ms, what) {
    return new Promise(function (resolve, reject) {
      setTimeout(function () { reject(new Error(what + ': timeout')); }, ms);
    });
  }

  function loadFont(base) {
    if (!base) return Promise.resolve(false);
    if (!document.fonts || !document.fonts.load) return Promise.resolve(false);
    var css = addCss(base.replace(/\/$/, '') + '/css/font-apex.min.css').then(function () {
      return document.fonts.load('16px "Font APEX Small"');
    }).then(function (faces) {
      if (!faces || !faces.length) throw new Error('font-apex: font face not loaded');
      return true;
    });
    return Promise.race([css, timeout(FONT_TIMEOUT_MS, 'font-apex')]).catch(function (e) {
      lib.notes.push(e.message + ' - inline SVG icons');
      return false;
    });
  }

  /* load(): ui.json once, then font-apex; resolves with the validated ui object */
  lib.load = function () {
    if (lib.loaded) return lib.loaded;
    lib.loaded = fetch('ui.json', { cache: 'no-store', credentials: 'same-origin' })
      .then(function (r) { return r.ok ? r.json() : {}; })
      .catch(function () { return {}; })
      .then(function (raw) {
        lib.ui = validate(raw);
        document.documentElement.setAttribute('data-locale', lib.ui.locale);
        return loadFont(lib.ui.libs.font_apex);
      })
      .then(function (ok) {
        lib.iconFont = ok;
        if (ok) {
          document.documentElement.classList.add('fa-ready');
          lib.upgradeIcons(document);
        }
        return lib.ui;
      });
    return lib.loaded;
  };

  /* faIcon(name): <span class="fa fa-..."> for a prototype icon name, or null */
  lib.faIcon = function (name) {
    if (!lib.iconFont || !FA[name]) return null;
    var s = document.createElement('span');
    s.className = 'icon fa ' + FA[name];
    s.setAttribute('aria-hidden', 'true');
    return s;
  };

  /* upgradeIcons(root): static inline SVG icons with data-icon="<name>" -> font-apex */
  lib.upgradeIcons = function (root) {
    if (!lib.iconFont) return;
    var list = (root || document).querySelectorAll('svg[data-icon]');
    Array.prototype.forEach.call(list, function (svgEl) {
      var f = lib.faIcon(svgEl.getAttribute('data-icon'));
      if (f && svgEl.parentNode) svgEl.parentNode.replaceChild(f, svgEl);
    });
  };

  global.WLSMON_LIBS = lib;
})(window);
