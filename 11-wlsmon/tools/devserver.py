#!/usr/bin/env python3
# =============================================================================
# Script   : devserver.py
# Purpose  : Local test server for the wlsmon GUI (development plan steps 2-4,
#            12). Serves the GUI like the production Nginx will:
#              /wlsmon/            11-wlsmon/www/ of the repository
#              /wlsmon/api/        a data directory (sample data or collector
#                                  output), only the 7 contract files + demo/
#              /wlsmon/ui.json     generated: locale + the newest /i/ library
#                                  versions found below --apex (or none)
#              /i/                 the APEX images directory (--apex)
#            with the strict security headers of concept section 6, so CSP
#            problems show up before the real installation.
#            Development aids (never in production):
#              - CSP violations are reported to /__dev/csp and printed here;
#              - every HTML page gets /__dev/report.js, which sends JS errors
#                and console warnings of the browser to /__dev/log - printed
#                here, so a browser test can be followed in this terminal.
# Call     : python3 -I tools/devserver.py --data <dir> [--apex /srv/apex/apex_1]
#                 [--port 8090] [--no-jet] [--no-jet-theme] [--style-inline]
#              open http://127.0.0.1:8090/wlsmon/host.html#demo-warn
#                   http://127.0.0.1:8090/wlsmon/__probe/probe.html  (JET spike)
#                   http://127.0.0.1:8090/wlsmon/index.html#demo
#              (over SSH: ssh -L 8090:127.0.0.1:8090 <host>)
# Note     : binds to 127.0.0.1 only; read-only, GET / HEAD only (+ the two
#            development POST endpoints)
# Needs    : python3 (3.6+), standard library only
# License  : Apache 2.0
# =============================================================================
import argparse
import json
import os
import posixpath
import re
import sys
from http.server import HTTPServer, SimpleHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.parse import unquote, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
WWW = os.path.join(os.path.dirname(HERE), "www")
API_RE = re.compile(r"^/wlsmon/api/(demo/[a-z]+/)?(now|day|week|history|patch|security|logs)\.json$")
HOSTS_RE = re.compile(r"^/wlsmon/(api/demo/)?hosts\.json$")

REPORT_JS = b"""(function () {
  'use strict';
  function send(kind, text) {
    try {
      fetch('/__dev/log', { method: 'POST', body: JSON.stringify({ kind: kind, page: location.pathname + location.hash, text: String(text).slice(0, 2000) }) });
    } catch (e) { /* ignore */ }
  }
  window.addEventListener('error', function (e) {
    send('error', (e.message || e) + ' @ ' + (e.filename || '') + ':' + (e.lineno || ''));
  });
  window.addEventListener('unhandledrejection', function (e) { send('promise', e.reason && e.reason.stack || e.reason); });
  ['warn', 'error'].forEach(function (k) {
    var orig = console[k];
    console[k] = function () {
      send('console.' + k, Array.prototype.slice.call(arguments).join(' '));
      return orig.apply(console, arguments);
    };
  });
  window.addEventListener('load', function () {
    setTimeout(function () {
      var info = document.getElementById('libs-info');
      send('info', 'loaded; ' + (info ? info.textContent : '') + '; oj-chart elements: ' +
        document.querySelectorAll('oj-chart').length + '; fa icons: ' + document.querySelectorAll('.fa').length);
    }, 4000);
  });
})();
"""


def version_key(name):
    return tuple(int(x) for x in name.split(".") if x.isdigit())


def newest(directory):
    """newest x.y.z subdirectory, or None"""
    try:
        names = [n for n in os.listdir(directory)
                 if re.match(r"^\d+(\.\d+)+$", n) and os.path.isdir(os.path.join(directory, n))]
    except OSError:
        return None
    return max(names, key=version_key) if names else None


def find_libs(apex):
    """The /i/ library paths for ui.json - the same rules as 01-install-wlsmon_fmw.sh."""
    libs = {}
    if not apex or not os.path.isdir(apex):
        return libs
    base = os.path.join(apex, "libraries")
    v = newest(os.path.join(base, "font-apex"))
    if v and os.path.isfile(os.path.join(base, "font-apex", v, "css", "font-apex.min.css")):
        libs["font_apex"] = "/i/libraries/font-apex/" + v
    v = newest(os.path.join(base, "oraclejet"))
    if v and os.path.isfile(os.path.join(base, "oraclejet", v, "js", "libs", "require", "require.js")):
        libs["jet"] = "/i/libraries/oraclejet/" + v
    if "jet" in libs:
        # DVT always loads a template engine for a DataProvider; for a page
        # without Preact that is the Knockout one, so RequireJS needs the path
        # (as APEX: libraries/apex/requirejs.jetConfig.js). No bindings are used.
        kdir = os.path.join(base, libs["jet"][len("/i/libraries/"):], "js", "libs", "knockout")
        ko = sorted(f for f in os.listdir(kdir) if re.match(r"^knockout-[\d.]+\.js$", f)) if os.path.isdir(kdir) else []
        if ko:
            libs["knockout"] = libs["jet"] + "/js/libs/knockout/" + ko[-1][:-3]
    v = newest(os.path.join(base, "jquery"))
    if v and os.path.isfile(os.path.join(base, "jquery", v, "jquery-%s.min.js" % v)):
        libs["jquery"] = "/i/libraries/jquery/%s/jquery-%s.min.js" % (v, v)
    v = newest(os.path.join(base, "jquery-ui"))
    if v and os.path.isfile(os.path.join(base, "jquery-ui", v, "jquery-ui-apex.min.js")):
        libs["jquery_ui"] = "/i/libraries/jquery-ui/%s/jquery-ui-apex.min.js" % v
    return libs


class Server(ThreadingMixIn, HTTPServer):
    daemon_threads = True


def make_handler(opts):
    style_src = "'self' 'unsafe-inline'" if opts.style_inline else "'self'"
    csp = ("default-src 'none'; script-src 'self'; style-src %s; img-src 'self' data:; "
           "font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; "
           "form-action 'none'; report-uri /__dev/csp" % style_src)
    ui = {"locale": opts.locale}
    if not opts.no_jet or opts.apex:
        libs = find_libs(opts.apex)
        if libs:
            ui["libs"] = libs
        if opts.no_jet:
            ui["charts"] = "svg"
        if opts.no_jet_theme:
            ui["jet_theme"] = False
    ui_bytes = json.dumps(ui).encode("utf-8")
    print("ui.json: %s" % ui_bytes.decode())
    print("CSP:     %s" % csp)

    class Handler(SimpleHTTPRequestHandler):
        server_version = "wlsmon-devserver"
        sys_version = ""

        def log_message(self, fmt, *args):
            if opts.verbose:
                sys.stderr.write("%s\n" % (fmt % args))

        def headers_common(self, ctype, length):
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(length))
            self.send_header("Content-Security-Policy", csp)
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Cache-Control", "no-store")

        def send_bytes(self, data, ctype, status=200):
            self.send_response(status)
            self.headers_common(ctype, len(data))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)

        def send_file(self, path):
            if not os.path.isfile(path):
                return self.send_bytes(b"not found\n", "text/plain", 404)
            ctype = self.guess_type(path)
            if path.endswith(".js"):
                ctype = "application/javascript"
            with open(path, "rb") as fh:
                data = fh.read()
            if path.endswith(".html"):
                data = data.replace(b"</head>", b'<script src="/__dev/report.js"></script>\n</head>', 1)
                ctype = "text/html; charset=utf-8"
            return self.send_bytes(data, ctype)

        def under(self, root, rel):
            full = os.path.realpath(os.path.join(root, rel))
            if not full.startswith(os.path.realpath(root) + os.sep):
                return None
            return full

        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            path = posixpath.normpath(unquote(urlsplit(self.path).path))
            if path in ("/", "/wlsmon"):
                self.send_response(302)
                self.send_header("Location", "/wlsmon/index.html#demo")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if path == "/__dev/report.js":
                return self.send_bytes(REPORT_JS, "application/javascript")
            if path in ("/wlsmon/ui.json", "/wlsmon/__probe/ui.json"):     # probe page fetches it relative
                return self.send_bytes(ui_bytes, "application/json")
            if API_RE.match(path) or HOSTS_RE.match(path):
                rel = path[len("/wlsmon/"):]
                if rel.startswith("api/"):
                    rel = rel[len("api/"):]
                full = self.under(opts.data, rel)
                return self.send_file(full) if full else self.send_bytes(b"", "text/plain", 404)
            if path.startswith("/wlsmon/__probe/"):                         # JET spike page
                full = self.under(os.path.join(HERE, "jet_probe"), path[len("/wlsmon/__probe/"):])
                return self.send_file(full) if full else self.send_bytes(b"", "text/plain", 404)
            if path.startswith("/wlsmon/api/"):
                return self.send_bytes(b"not found\n", "text/plain", 404)   # like the Nginx whitelist
            if path.startswith("/wlsmon/"):
                full = self.under(WWW, path[len("/wlsmon/"):])
                return self.send_file(full) if full else self.send_bytes(b"", "text/plain", 404)
            if path.startswith("/i/") and opts.apex:
                full = self.under(opts.apex, path[len("/i/"):])
                return self.send_file(full) if full else self.send_bytes(b"", "text/plain", 404)
            return self.send_bytes(b"not found\n", "text/plain", 404)

        def do_POST(self):
            path = urlsplit(self.path).path
            length = min(int(self.headers.get("Content-Length") or 0), 65536)
            body = self.rfile.read(length).decode("utf-8", "replace")
            if path == "/__dev/csp":
                try:
                    rep = json.loads(body).get("csp-report", {})
                    print("CSP VIOLATION  %s  blocked=%s  directive=%s  source=%s:%s" % (
                        rep.get("document-uri", ""), rep.get("blocked-uri", ""),
                        rep.get("violated-directive", ""), rep.get("source-file", ""),
                        rep.get("line-number", "")))
                except ValueError:
                    print("CSP VIOLATION  %s" % body[:500])
            elif path == "/__dev/log":
                try:
                    msg = json.loads(body)
                    print("BROWSER %-14s %s  %s" % (msg.get("kind"), msg.get("page"), msg.get("text")))
                except ValueError:
                    print("BROWSER %s" % body[:500])
            else:
                return self.send_bytes(b"", "text/plain", 405)
            sys.stdout.flush()
            return self.send_bytes(b"", "text/plain", 204)

    return Handler


def main():
    ap = argparse.ArgumentParser(description="wlsmon GUI test server (127.0.0.1 only)")
    ap.add_argument("--data", required=True, help="data directory (gen_sample_data.py --out ...)")
    ap.add_argument("--apex", default="", help="APEX images directory served as /i/")
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--locale", default="de-DE")
    ap.add_argument("--no-jet", action="store_true", help="ui.json charts=svg (fallback test)")
    ap.add_argument("--no-jet-theme", action="store_true", help="ui.json jet_theme=false (comparison only)")
    ap.add_argument("--style-inline", action="store_true", help="CSP style-src 'unsafe-inline' (spike comparison)")
    ap.add_argument("--verbose", action="store_true", help="log every request")
    opts = ap.parse_args()
    opts.data = os.path.abspath(opts.data)
    if not os.path.isdir(opts.data):
        print("data directory not found: %s" % opts.data, file=sys.stderr)
        return 2
    srv = Server(("127.0.0.1", opts.port), make_handler(opts))
    print("wlsmon devserver: http://127.0.0.1:%d/wlsmon/host.html#demo-warn" % opts.port)
    print("                  http://127.0.0.1:%d/wlsmon/index.html#demo" % opts.port)
    print("                  http://127.0.0.1:%d/wlsmon/__probe/probe.html  (JET spike)" % opts.port)
    sys.stdout.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
