"""Development step 8: the templates render for every role, nginx accepts them
and - when nginx can run as this user on the loopback - the access rules hold.

The loopback test starts a throwaway nginx with its own prefix in a temporary
directory on 127.0.0.1 (no system file is touched) and checks concept 6:
401 without login, 200 with login, POST refused, everything outside the
whitelist 404. It found the nested "location ^~" bug on 2026-11-19.
"""
import os
import re
import shutil
import socket
import subprocess
import time
import unittest
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from base64 import b64encode

from tests.helpers import BASE, TempDir
import render_template

TPL = os.path.join(BASE, "templates")
NGINX = shutil.which("nginx") or ("/usr/sbin/nginx" if os.access("/usr/sbin/nginx", os.X_OK) else None)


def tpl(name):
    with open(os.path.join(TPL, name), encoding="utf-8") as fh:
        return fh.read()


VALUES = {"WLSMON_BASE": "/u01/app/oracle/admin/wlsmon", "ADMIN_IP_RANGE": "10.10.10.0/24 127.0.0.1",
          "WLSMON_GUI_IP": "10.10.10.5", "WLSMON_STYLE_SRC": "'self'", "WLSMON_I_DIR": "/srv/i",
          "FMW_OWNER": "oracle", "FMW_GROUP": "oinstall"}


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class RenderTest(unittest.TestCase):

    def test_every_template_renders(self):
        conf_values = dict((k, "x") for k in re.findall(r"##([A-Z0-9_]+)##", tpl("wlsmon.conf.template")))
        for name in sorted(os.listdir(TPL)):
            values = conf_values if name == "wlsmon.conf.template" else VALUES
            text, errors = render_template.render(tpl(name), values, {"WLSMON_GUI", "CREDS"})
            self.assertEqual(errors, [], name)
            body = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
            self.assertNotIn("##", body, name)

    def test_roles(self):
        gui, _ = render_template.render(tpl("wlsmon-nginx.conf.template"), VALUES, {"WLSMON_GUI"},
                                        {"ADMIN_IP_RANGE"})
        data, _ = render_template.render(tpl("wlsmon-nginx.conf.template"), VALUES, {"WLSMON_DATA"})
        self.assertIn("allow                10.10.10.0/24;", gui)
        self.assertIn("allow                127.0.0.1;", gui)
        self.assertNotIn("pull_htpasswd", gui)
        self.assertIn("allow                10.10.10.5;", data)
        self.assertNotIn("/www/", data)
        self.assertNotIn("location /i/", gui + data)
        self.assertNotIn("location ^~ /wlsmon/api/", gui)    # would hide the whitelist regexes

    def test_any_removes_allow(self):
        v = dict(VALUES, ADMIN_IP_RANGE="any")
        gui, _ = render_template.render(tpl("wlsmon-nginx.conf.template"), v, {"WLSMON_GUI"}, {"ADMIN_IP_RANGE"})
        body = "\n".join(l for l in gui.splitlines() if not l.lstrip().startswith("#"))
        self.assertNotIn("allow ", body)
        self.assertNotIn("deny ", body.split("limit_except")[0])     # "deny all" of the allow list gone too

    def test_comma_list(self):
        v = dict(VALUES, ADMIN_IP_RANGE="192.0.2.0/24,198.51.100.0/24")
        gui, _ = render_template.render(tpl("wlsmon-nginx.conf.template"), v, {"WLSMON_GUI"}, {"ADMIN_IP_RANGE"})
        self.assertEqual(len(re.findall(r"^\s+allow\s", gui, re.M)), 2)

    def test_errors(self):
        _t, err = render_template.render("a ##NOPE##\n#@X_BEGIN@\n", {}, set())
        self.assertEqual(len(err), 2)

    def test_ol8_without_credentials(self):
        text, _ = render_template.render(tpl("wlsmon-collect.service.template"), VALUES, set())
        self.assertNotIn("LoadCredentialEncrypted", text)
        self.assertIn("ExecStart=/usr/bin/flock -n /u01/app/oracle/admin/wlsmon/state/collect.lock", text)


@unittest.skipUnless(NGINX, "nginx not installed")
class NginxLoopbackTest(unittest.TestCase):

    def setUp(self):
        self.tmp = TempDir()
        self.d = self.tmp.__enter__()
        d = self.d
        self.port = free_port()
        base = os.path.join(d, "base")
        for sub in ("www/js", "api/demo/warn", "hosts", "nginx"):
            os.makedirs(os.path.join(base, sub) if sub != "nginx" else os.path.join(d, "nginx"))
        for rel, text in (("www/index.html", "<html></html>"), ("www/js/a.js", "1;"),
                          ("api/now.json", "{}"), ("api/.tmp_x.json", "{}"), ("api/demo/warn/now.json", "{}")):
            with open(os.path.join(base, rel), "w") as fh:
                fh.write(text)
        ngx = os.path.join(d, "nginx")
        v = dict(VALUES, WLSMON_BASE=base, ADMIN_IP_RANGE="127.0.0.1")
        gui, err = render_template.render(tpl("wlsmon-nginx.conf.template"), v, {"WLSMON_GUI"}, {"ADMIN_IP_RANGE"})
        hdr, err2 = render_template.render(tpl("wlsmon-headers.conf.template"), v, set())
        self.assertEqual(err + err2, [])
        with open(os.path.join(ngx, "gui.conf"), "w") as fh:
            fh.write(gui.replace("/etc/nginx/wlsmon/", ngx + "/"))
        with open(os.path.join(ngx, "headers.conf"), "w") as fh:
            fh.write(hdr)
        r = subprocess.run(["openssl", "passwd", "-6", "-stdin"], input="test-only-pw\n",
                           stdout=subprocess.PIPE, universal_newlines=True)
        with open(os.path.join(ngx, "htpasswd"), "w") as fh:
            fh.write("tester:%s\n" % r.stdout.strip())
        temps = " ".join("%s_temp_path %s/t%d;" % (k, ngx, i) for i, k in
                         enumerate(("client_body", "proxy", "fastcgi", "uwsgi", "scgi")))
        with open(os.path.join(ngx, "nginx.conf"), "w") as fh:
            fh.write("pid %s/nginx.pid;\nerror_log %s/error.log;\nevents {}\nhttp {\n  access_log off; %s\n"
                     "  limit_req_zone $binary_remote_addr zone=wlsmon:1m rate=10r/s;\n"
                     "  server { listen 127.0.0.1:%d; include %s/gui.conf; }\n}\n"
                     % (ngx, ngx, temps, self.port, ngx))
        self.ngx = ngx
        t = subprocess.run([NGINX, "-t", "-p", ngx, "-c", ngx + "/nginx.conf"], stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, universal_newlines=True)
        self.assertEqual(t.returncode, 0, t.stdout)
        s = subprocess.run([NGINX, "-p", ngx, "-c", ngx + "/nginx.conf"], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
        if s.returncode != 0:
            self.skipTest("nginx cannot run as this user")
        for _i in range(50):
            if os.path.isfile(ngx + "/nginx.pid"):
                break
            time.sleep(0.1)

    def tearDown(self):
        pid_file = os.path.join(self.ngx, "nginx.pid") if hasattr(self, "ngx") else None
        if pid_file and os.path.isfile(pid_file):
            with open(pid_file) as fh:
                os.kill(int(fh.read().strip()), 15)
            for _i in range(50):
                if not os.path.isfile(pid_file):
                    break
                time.sleep(0.1)
        self.tmp.__exit__(None, None, None)

    def status(self, path, auth=True, method="GET"):
        req = Request("http://127.0.0.1:%d%s" % (self.port, path), method=method,
                      data=b"x" if method == "POST" else None)
        if auth:
            req.add_header("Authorization", "Basic " + b64encode(b"tester:test-only-pw").decode())
        try:
            with urlopen(req, timeout=5) as resp:
                return resp.status, dict(resp.headers)
        except HTTPError as exc:
            exc.close()
            return exc.code, dict(exc.headers)
        except URLError:
            return None, {}

    def test_access_rules(self):
        self.assertEqual(self.status("/wlsmon/", auth=False)[0], 401)
        self.assertEqual(self.status("/wlsmon/api/now.json", auth=False)[0], 401)
        code, hdr = self.status("/wlsmon/api/now.json")
        self.assertEqual(code, 200)
        self.assertEqual(hdr.get("Cache-Control"), "no-store")
        self.assertIn("script-src 'self'", hdr.get("Content-Security-Policy", ""))
        self.assertIn(self.status("/wlsmon/api/now.json", method="POST")[0], (403, 405))
        self.assertEqual(self.status("/wlsmon/api/.tmp_x.json")[0], 404)
        self.assertEqual(self.status("/wlsmon/api/demo/warn/now.json")[0], 404)
        self.assertEqual(self.status("/wlsmon/js/a.js")[0], 200)
        self.assertEqual(self.status("/console")[0], 404)


if __name__ == "__main__":
    unittest.main()
