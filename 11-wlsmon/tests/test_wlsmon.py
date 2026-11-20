"""Development steps 5 - 7: wlsmon.py on fixtures - no WebLogic, Reports or nginx.

System files (/proc ...) come from a fake root (WLSMON_TEST_ROOT), network calls
(http, port checks, TLS, local nginx probe) and subprocesses are replaced.
Only demo names (orafusion01, fr_domain, repserver01).
"""
import contextlib
import io
import json
import os
import stat
import time
import unittest

from tests.helpers import FIXTURES, TempDir, read_json
import check_contract
import wlsmon

PROC_STAT = """cpu  {u} 0 {s} {i} {w} 0 0 {st} 0 0
cpu0 1 0 1 1 0 0 0 0 0 0
btime 1792000000
"""
MEMINFO = """MemTotal:       16000000 kB
MemFree:         2000000 kB
MemAvailable:    4000000 kB
SwapTotal:       2000000 kB
SwapFree:        2000000 kB
"""
WLS_ENTRY = ("####<Nov 19, 2026, 10:00:00,000 AM CET> <{sev}> <WebLogicServer> <orafusion01.pipperr.local> "
             "<{srv}> <main> <<WLS Kernel>> <> <> <1> <> <{code}> <{text}>")


def text(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def write(path, text, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    if mode is not None:
        os.chmod(path, mode)


class Fake(object):
    """replaces network and subprocess calls of wlsmon"""

    def __init__(self):
        self.search = text(os.path.join(FIXTURES, "wls", "search_ok.json"))
        self.servers = text(os.path.join(FIXTURES, "wls", "servers.json"))
        self.serverinfo = text(os.path.join(FIXTURES, "reports", "serverinfo_ok.xml"))
        self.rest_code = 200
        self.open_ports = {"7001", "9001", "9002", "5556", "443"}
        self.calls = []

    def http(self, url, data=None, user=None, password=None, headers=None, timeout=20, cafile=None, method=None):
        self.calls.append(url)
        if "/domainRuntime/search" in url:
            return (self.rest_code, self.search if self.rest_code == 200 else "")
        if "/domainConfig/servers" in url:
            return 200, self.servers
        if "/getserverinfo" in url:
            assert "authid=" in data and "authid" not in url     # POST body only
            return 200, self.serverinfo
        if url.endswith("/weblogic/ready"):
            return 200, ""
        return 0, "no route"

    def port_open(self, host, port, timeout=3):
        return str(port) in self.open_ports

    def run(self, cmd, timeout=15, stdin_text=None):
        if cmd[0] == "rpm":
            return 0, "1.20.1-28.el9"
        return 127, "not in test"


class Env(object):
    """fake system root + WLSMON_BASE + domain, patched wlsmon module"""

    def __init__(self, d):
        self.d = d
        self.root = os.path.join(d, "root")
        self.base = os.path.join(d, "base")
        self.dom = os.path.join(d, "domains", "fr_domain")
        self.fake = Fake()
        write(os.path.join(self.root, "proc/stat"), PROC_STAT.format(u=1000, s=500, i=8000, w=100, st=0))
        write(os.path.join(self.root, "proc/loadavg"), "0.50 0.40 0.30 1/200 12345\n")
        write(os.path.join(self.root, "proc/meminfo"), MEMINFO)
        write(os.path.join(self.root, "proc/sys/kernel/core_pattern"), os.path.join(d, "core", "core_%e_%p") + "\n")
        write(os.path.join(self.root, "proc/net/tcp"), "  sl  local_address rem_address   st\n")
        write(os.path.join(self.root, "run/nginx.pid"), "4242\n")
        os.makedirs(os.path.join(self.root, "proc/4242"))
        os.makedirs(os.path.join(d, "core"))
        for srv in ("AdminServer", "WLS_FORMS", "WLS_REPORTS"):
            write(os.path.join(self.dom, "servers", srv, "logs", srv + ".log"), "")
        write(os.path.join(self.dom, "servers", "repserver01", "logs", "rwserver_diagnostic.log"), "")
        write(os.path.join(self.dom, "config", "config.xml"),
              "<domain><production-mode-enabled>true</production-mode-enabled></domain>")
        write(os.path.join(d, "nginx", "access.log"), "")
        write(os.path.join(d, "nginx", "error.log"), "")
        write(os.path.join(self.base, "share", "wlsmon_rules.cfg"),
              text(os.path.join(os.path.dirname(FIXTURES), "..", "rules", "wlsmon_rules.cfg")))
        write(os.path.join(self.base, "www", "ui.json"), '{"locale": "de-DE"}')
        os.makedirs(os.path.join(self.base, "etc", "creds"))
        os.chmod(os.path.join(self.base, "etc", "creds"), 0o700)
        self.conf({})
        self.creds = os.path.join(d, "creds")
        write(os.path.join(self.creds, "wls_monitor"), "secret-1\n")
        write(os.path.join(self.creds, "reports_mon"), "secret-2\n")

    def conf(self, extra):
        lines = {"WLSMON_HOST_ID": "orafusion01", "WLSMON_PRODUCT": "Demo", "WLSMON_ENV": "test",
                 "WLSMON_DOMAIN_HOME": self.dom, "WLSMON_REPORTS_SERVERS": "repserver01",
                 "WLSMON_NGINX_ACCESS_LOG": os.path.join(self.d, "nginx", "access.log"),
                 "WLSMON_NGINX_ERROR_LOG": os.path.join(self.d, "nginx", "error.log"),
                 "WLSMON_NGINX_CONF_DIRS": os.path.join(self.d, "nginxconf"),
                 "WLSMON_DISKS": "domain=%s" % self.d, "WLSMON_LOAD": "8,16",
                 "WLSMON_ORACLE_HOME": os.path.join(self.d, "fmw")}
        lines.update(extra)
        write(os.path.join(self.base, "etc", "wlsmon.conf"),
              "\n".join("%s=%s" % kv for kv in sorted(lines.items())) + "\n", 0o600)

    def __enter__(self):
        self.saved = dict((k, getattr(wlsmon, k)) for k in
                          ("TEST_ROOT", "http", "port_open", "run", "cert_days_tls", "local_probe"))
        wlsmon.TEST_ROOT = self.root
        wlsmon.http = self.fake.http
        wlsmon.port_open = self.fake.port_open
        wlsmon.run = self.fake.run
        wlsmon.cert_days_tls = lambda port, name: 90
        wlsmon.local_probe = lambda port, path, host=None: 404
        os.environ["WLSMON_BASE"] = self.base
        os.environ["CREDENTIALS_DIRECTORY"] = self.creds
        return self

    def __exit__(self, *exc):
        for k, v in self.saved.items():
            setattr(wlsmon, k, v)
        os.environ.pop("CREDENTIALS_DIRECTORY", None)
        os.environ.pop("WLSMON_BASE", None)

    def collect(self):
        rc = wlsmon.collect(["--out", os.path.join(self.base, "api"), "--state", os.path.join(self.base, "state")])
        assert rc == 0
        return dict((n, read_json(os.path.join(self.base, "api", n + ".json"))) for n in wlsmon.FILES)

    def append_log(self, srv, text):
        p = os.path.join(self.dom, "servers", srv, "logs", srv + ".log")
        with open(p, "a", encoding="utf-8") as fh:
            fh.write(text + "\n")


def comp(now, cid):
    return next(c for c in now["components"] if c["id"] == cid)


def metric(now, mid):
    return next(m for m in now["metrics"] if m["id"] == mid)


class ConfigTest(unittest.TestCase):

    def test_parse(self):
        with TempDir() as d:
            write(os.path.join(d, "etc", "wlsmon.conf"),
                  "# comment\nWLSMON_ENV=\"qa\"\nWLSMON_HEAP_PCT=75,85\nNO_SUCH_KEY=1\n")
            cfg = wlsmon.Config(d)
            self.assertEqual(cfg.get("WLSMON_ENV"), "qa")
            self.assertEqual(cfg.pair("WLSMON_HEAP_PCT"), [75, 85])
            self.assertEqual(cfg.get("WLSMON_CPU_PCT"), "80,95")          # default
            self.assertEqual(len(cfg.unknown), 1)

    def test_secret_from_credentials_directory(self):
        with TempDir() as d:
            write(os.path.join(d, "x"), "pw\n")
            os.environ["CREDENTIALS_DIRECTORY"] = d
            try:
                self.assertEqual(wlsmon.secret("x"), "pw")
                self.assertIsNone(wlsmon.secret("missing"))
            finally:
                del os.environ["CREDENTIALS_DIRECTORY"]

    def test_secret_fallback_needs_mode_400(self):
        with TempDir() as d:
            os.environ["WLSMON_BASE"] = d
            try:
                write(os.path.join(d, "etc", "creds", "x"), "pw", 0o644)
                self.assertIsNone(wlsmon.secret("x"))                     # readable by others: refused
                os.chmod(os.path.join(d, "etc", "creds", "x"), 0o400)
                self.assertEqual(wlsmon.secret("x"), "pw")
            finally:
                del os.environ["WLSMON_BASE"]

    def test_atomic_write(self):
        with TempDir() as d:
            p = os.path.join(d, "a.json")
            wlsmon.write_json(p, {"a": 1})
            self.assertEqual(read_json(p), {"a": 1})
            self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), 0o640)
            self.assertEqual([f for f in os.listdir(d) if f.startswith(".tmp_")], [])

    def test_parse_iso(self):
        self.assertEqual(wlsmon.parse_iso("2026-11-19T10:00:00+01:00"), wlsmon.parse_iso("2026-11-19T09:00:00Z"))


class ReportsTest(unittest.TestCase):

    def test_serverinfo(self):
        info = wlsmon.parse_serverinfo(text(os.path.join(FIXTURES, "reports", "serverinfo_ok.xml")))
        self.assertEqual((info["busy"], info["idle"], info["current"], info["failed"]), (1, 3, 4, 24))

    def test_serverinfo_error(self):
        info = wlsmon.parse_serverinfo(text(os.path.join(FIXTURES, "reports", "serverinfo_50171.xml")))
        self.assertIn("REP-50171", info["error"])

    def test_real_rest_answer_14_1_2(self):
        """the captured answer of the test host parses into heap / threads / JDBC"""
        import json as _json
        data = _json.loads(text(os.path.join(FIXTURES, "wls", "search_real_14.1.2.json")))
        servers = dict((s["name"], s) for s in wlsmon.items(data, "serverRuntimes"))
        self.assertEqual(sorted(servers), ["AdminServer", "WLS_FORMS", "WLS_REPORTS"])
        self.assertEqual(wlsmon.heap_pct(servers["WLS_FORMS"]["JVMRuntime"]), 37)
        ds = wlsmon.items(servers["AdminServer"]["JDBCServiceRuntime"], "JDBCDataSourceRuntimeMBeans")
        self.assertIn("LocalSvcTblDataSource", [d["name"] for d in ds])

    def test_no_serverinfo(self):
        self.assertIn("error", wlsmon.parse_serverinfo("<html>Oracle SSO</html>"))


class RulesTest(unittest.TestCase):

    def rules(self, text):
        with TempDir() as d:
            write(os.path.join(d, "r.cfg"), text)
            errs = []
            return wlsmon.load_rules([os.path.join(d, "r.cfg")], errs), errs

    def test_load_errors(self):
        rules, errs = self.rules("match;a;crit;wls;BEA-1;x\nignore;b;-;wls;BEA-2;\nmatch;c;crit;wls;([;x\n"
                                 "match;d;yellow;wls;x;x\n")
        self.assertEqual([r.id for r in rules], ["a"])
        self.assertEqual(len(errs), 3)

    def test_local_file_replaces_id(self):
        with TempDir() as d:
            write(os.path.join(d, "a.cfg"), "match;x;crit;wls;BEA-1;default\n")
            write(os.path.join(d, "b.cfg"), "match;x;warn;wls;BEA-1;local\n")
            rules = wlsmon.load_rules([os.path.join(d, "a.cfg"), os.path.join(d, "b.cfg")], [])
            self.assertEqual([(r.id, r.level) for r in rules], [("x", "warn")])

    def test_ignore_first_and_highest_match(self):
        rules, _ = self.rules("match;w;warn;wls;BEA-000337;w\nmatch;c;crit;wls;stuck;c\n"
                              "ignore;i;-;wls;harmless;known\n")
        e1 = WLS_ENTRY.format(sev="Error", srv="WLS_FORMS", code="BEA-000337", text="stuck thread")
        r, sev, code = wlsmon.classify(e1, ("wls",), rules)
        self.assertEqual((r.id, code), ("c", "BEA-000337"))
        e2 = WLS_ENTRY.format(sev="Error", srv="WLS_FORMS", code="BEA-000337", text="harmless stuck")
        r, sev, code = wlsmon.classify(e2, ("wls",), rules)
        self.assertEqual(r.type, "ignore")

    def test_entries_with_stack_trace(self):
        text = "\n".join([WLS_ENTRY.format(sev="Error", srv="X", code="BEA-1", text="a"),
                          "java.lang.Exception: boom", "\tat a.b.C(C.java:1)",
                          "[2026-11-19T10:00:00.000+01:00] [reports] [ERROR] [REP-50125] [m] text",
                          "\tat x", "plain .out line", "  indented continuation", "next line"])
        entries = list(wlsmon.split_entries(text))
        self.assertEqual(len(entries), 2)
        self.assertEqual(entries[1].count("\n"), 4)      # ODL entry keeps every line until the next start
        out = list(wlsmon.split_entries("plain .out line\n  indented continuation\nnext line"))
        self.assertEqual(len(out), 2)

    def test_short_text_masks(self):
        e = WLS_ENTRY.format(sev="Error", srv="X", code="BEA-090078",
                             text="User scott in security realm locked, from 192.0.2.17 file /u01/a/b.log")
        t = wlsmon.short_text(e, "BEA-090078")
        self.assertNotIn("192.0.2.17", t)
        self.assertNotIn("/u01/a/b.log", t)
        self.assertLessEqual(len(t), 120)


NGINX_CONF = """
upstream wls_admin { server 127.0.0.1:7001; }
server {
    listen 443 ssl;
    server_name orafusion01.pipperr.local;
    location /console { allow 10.0.0.0/8; deny all; proxy_pass http://wls_admin; }
    location /em { proxy_pass http://wls_admin; }       # forgotten restriction
    # location /management { proxy_pass http://wls_admin; }   (comment, ignored)
    location /forms/ { proxy_pass http://127.0.0.1:9001; }
}
"""


class NginxCheckTest(unittest.TestCase):

    def test_parser(self):
        ups = wlsmon.nginx_upstreams(NGINX_CONF)
        locs = wlsmon.nginx_locations(NGINX_CONF)
        admin = [p for _m, p, b in locs if wlsmon.proxies_to_port(b, ups, 7001)]
        self.assertEqual(admin, ["/console", "/em"])
        self.assertEqual(wlsmon.nginx_server_name(NGINX_CONF), "orafusion01.pipperr.local")

    def security(self, d, conf, probe_code=404, listen_ext=False):
        with Env(d) as env:
            # system path: read through the test root like /proc
            write(os.path.join(env.root, d.lstrip("/"), "nginxconf", "oracle-wls.conf"), conf)
            if listen_ext:                     # 0.0.0.0:7001 LISTEN (0x1B59)
                write(os.path.join(env.root, "proc/net/tcp"),
                      "  sl  local_address rem_address   st\n   0: 00000000:1B59 00000000:0000 0A\n")
            wlsmon.local_probe = lambda port, path, host=None: probe_code
            return dict((c["id"], c) for c in env.collect()["security"]["checks"])

    def test_admin_open_and_mgmt_routed(self):
        with TempDir() as d:
            conf = NGINX_CONF.replace("# location /management", "location /management")
            chk = self.security(d, conf, probe_code=401, listen_ext=True)
            self.assertEqual(chk["mgmt_rest_proxied"]["level"], "crit")
            self.assertEqual(chk["admin_locations"]["level"], "warn")
            self.assertIn("/em", chk["admin_locations"]["result"])
            self.assertEqual(chk["admin_listen"]["level"], "warn")

    def test_clean(self):
        with TempDir() as d:
            conf = NGINX_CONF.replace("location /em { proxy_pass", "location /em { allow 10.0.0.0/8; deny all; proxy_pass")
            chk = self.security(d, conf)
            self.assertEqual(chk["mgmt_rest_proxied"]["level"], "ok")
            self.assertEqual(chk["admin_locations"]["level"], "ok")
            self.assertNotIn("admin_listen", chk)          # port not listening at all in the fixture


class OffsetsTest(unittest.TestCase):

    def test_first_sight_rotation_truncation(self):
        with TempDir() as d:
            p = os.path.join(d, "a.log")
            write(p, "old\n")
            st = {}
            self.assertEqual(wlsmon.read_new(p, st, 1 << 20)[0], "")          # first sight: start at the end
            with open(p, "a") as fh:
                fh.write("new\n")
            self.assertEqual(wlsmon.read_new(p, st, 1 << 20)[0], "new\n")
            os.rename(p, p + ".1")
            write(p, "rotated\n")                                            # new inode
            self.assertEqual(wlsmon.read_new(p, st, 1 << 20)[0], "rotated\n")
            write(p, "x\n")                                                  # truncated, same inode
            self.assertEqual(wlsmon.read_new(p, st, 1 << 20)[0], "x\n")


class RollupTest(unittest.TestCase):

    def test_merge_rules(self):
        b = {}
        wlsmon.merge(b, {"load1": 1, "mem_free_pct": 40, "log_errors_forms": 2, "level": "ok"})
        wlsmon.merge(b, {"load1": 3, "mem_free_pct": 20, "log_errors_forms": 5, "level": "warn"})
        wlsmon.merge(b, {"load1": 2, "mem_free_pct": None, "log_errors_forms": 1, "level": "ok"})
        self.assertEqual(b, {"load1": 3, "mem_free_pct": 20, "log_errors_forms": 8, "level": "warn"})


class CollectTest(unittest.TestCase):

    def test_round_matches_contract(self):
        with TempDir() as d, Env(d) as env:
            files = env.collect()
            self.assertEqual(check_contract.check_dir(os.path.join(env.base, "api"), real=True), [])
            now = files["now"]
            self.assertEqual(comp(now, "WLS_FORMS")["state"], "RUNNING")
            self.assertEqual(metric(now, "heap_forms_pct")["value"], 84)
            self.assertEqual(metric(now, "heap_forms_pct")["level"], "warn")
            self.assertEqual(metric(now, "threads_forms")["display"], "0 · 2")
            self.assertEqual(comp(now, "rep_repserver01")["parent"], "WLS_REPORTS")
            self.assertEqual(metric(now, "reports_engines")["display"], "1 · 3")
            self.assertEqual(now["overall"]["level"], "warn")

    def test_cpu_delta_and_rollups_over_rounds(self):
        with TempDir() as d, Env(d) as env:
            env.collect()
            write(os.path.join(env.root, "proc/stat"), PROC_STAT.format(u=1600, s=600, i=8300, w=100, st=0))
            files = env.collect()
            self.assertEqual(metric(files["now"], "cpu_pct")["value"], 70.0)    # 700 busy of 1000
            self.assertEqual(len(files["day"]["series"]["ts"]), 2)
            self.assertEqual(files["history"]["series"]["level"][-1], files["now"]["overall"]["level"])

    def test_reports_failed_jobs_are_a_delta(self):
        with TempDir() as d, Env(d) as env:
            env.collect()
            env.fake.serverinfo = env.fake.serverinfo.replace('"failedJobs" value="24"', '"failedJobs" value="26"')
            now = env.collect()["now"]
            self.assertEqual(metric(now, "reports_jobs")["display"], "1 · 3 · 2")
            self.assertEqual(metric(now, "reports_jobs")["level"], "warn")

    def test_401_pauses_the_monitor_user(self):
        with TempDir() as d, Env(d) as env:
            env.fake.rest_code = 401
            now = env.collect()["now"]
            self.assertTrue(any("HTTP 401" in e["text"] for e in now["collector"]["errors"]))
            env.fake.calls = []
            env.fake.rest_code = 200
            now = env.collect()["now"]
            self.assertFalse(any("/domainRuntime/search" in u for u in env.fake.calls))   # paused, no retry
            self.assertTrue(any("paused until" in e["text"] for e in now["collector"]["errors"]))

    def test_admin_down_falls_back_to_ports(self):
        with TempDir() as d, Env(d) as env:
            env.fake.rest_code = 0
            env.fake.open_ports.discard("7001")
            env.fake.open_ports.discard("9002")
            now = env.collect()["now"]
            self.assertTrue(comp(now, "AdminServer").get("down"))
            self.assertEqual(comp(now, "WLS_FORMS")["level"], "ok")
            self.assertEqual(check_contract.check_dir(os.path.join(env.base, "api"), real=True), [])

    def test_nginx_down_blocks_only_root_cause(self):
        with TempDir() as d, Env(d) as env:
            os.rmdir(os.path.join(env.root, "proc/4242"))
            env.fake.open_ports.discard("443")
            now = env.collect()["now"]
            self.assertEqual(comp(now, "WLS_FORMS")["state"], "blocked by nginx")
            self.assertEqual(comp(now, "rep_repserver01")["state"], "blocked by nginx")
            down_reasons = [r for r in now["overall"]["reasons"] if r["text"].startswith("nginx")]
            self.assertEqual(len(down_reasons), 1)
            self.assertIn("blocks WLS_FORMS", down_reasons[0]["text"])
            self.assertFalse(any(r["text"].startswith("WLS_FORMS") for r in now["overall"]["reasons"]))

    def test_nginx_own_probe_not_counted(self):
        with TempDir() as d, Env(d) as env:
            env.collect()                                            # first round sets the offset
            with open(os.path.join(d, "nginx", "error.log"), "a") as fh:
                fh.write('2026/11/20 12:02:05 [error] 1#1: *286 open() "/usr/share/nginx/html/management/weblogic'
                         '/latest" failed (2: No such file or directory), client: 127.0.0.1, server: x, request: '
                         '"GET /management/weblogic/latest HTTP/1.1", host: "x"\n'
                         '2026/11/20 12:03:00 [error] 1#1: *290 upstream timed out, client: 192.0.2.17, server: x, '
                         'request: "GET /forms/frmservlet HTTP/1.1", host: "x"\n')
            now = env.collect()["now"]
            m = [x for x in now["metrics"] if x["id"] == "log_errors_nginx"][0]
            self.assertEqual(m["value"], 1)                          # only the real one

    def test_log_errors_counted_per_component(self):
        with TempDir() as d, Env(d) as env:
            env.collect()                                                    # offsets at the end
            env.append_log("WLS_FORMS", WLS_ENTRY.format(sev="Error", srv="WLS_FORMS", code="FRM-93652",
                                                         text="runtime ended"))
            env.append_log("WLS_REPORTS", WLS_ENTRY.format(sev="Critical", srv="WLS_REPORTS",
                                                           code="BEA-000337", text="stuck"))
            env.append_log("WLS_REPORTS", WLS_ENTRY.format(sev="Notice", srv="WLS_REPORTS",
                                                           code="BEA-000365", text="state RUNNING"))
            files = env.collect()
            now, logs = files["now"], files["logs"]
            self.assertEqual(metric(now, "log_errors_forms")["value"], 1)
            self.assertEqual(metric(now, "log_errors_reports")["value"], 1)
            self.assertEqual(metric(now, "log_errors_reports")["level"], "crit")
            self.assertEqual(sorted(e["code"] for e in logs["events"]), ["BEA-000337", "FRM-93652"])
            hits = dict((r["id"], r["hits"]) for r in logs["rules"])
            self.assertEqual((hits["stuck"], hits["frm_abnormal"]), (1, 1))
            raw = json.dumps(logs)
            self.assertNotIn("####<", raw)

    def test_new_core_dump_is_crit(self):
        with TempDir() as d, Env(d) as env:
            env.collect()
            time.sleep(1.1)
            write(os.path.join(d, "core", "core_frmweb_4711"), "x")
            now = env.collect()["now"]
            self.assertEqual(metric(now, "core_dumps_forms")["level"], "crit")
            self.assertEqual(now["overall"]["level"], "crit")

    def test_patch_level_from_inventory(self):
        with TempDir() as d, Env(d) as env:
            inv = os.path.join(d, "fmw", "inventory")
            write(os.path.join(inv, "registry.xml"),
                  '<x><patch install-date="2026-11-18T14:26:15.161+01:00" patch-id="40289390" status="installed"/></x>')
            write(os.path.join(inv, "patches", "40289390.xml"),
                  '<patch-def unique-patch-id="1" patch-id="40289390" '
                  'description="WLS STACK PATCH BUNDLE 14.1.2.0.261112 (Patch 40289362)"/>')
            env.conf({"WLSMON_PATCH_BASELINE": "2027-01"})
            patch = env.collect()["patch"]
            self.assertEqual(patch["baseline"]["installed"], "2026-11")
            self.assertEqual(patch["level"], "warn")                            # two months behind
            self.assertEqual(patch["patches"][0]["id"], "40289390")


if __name__ == "__main__":
    unittest.main()


class ThresholdTest(unittest.TestCase):
    """WLSMON_SWAP_MB instead of 'any swap = WARN'; unreadable thresholds reported;
    wlsmon.py thresholds (overview + --check) for 03-set-thresholds.sh"""

    def swap(self, env, used_kb):
        write(os.path.join(env.root, "proc/meminfo"),
              MEMINFO.replace("SwapFree:        2000000", "SwapFree:        %7d" % (2000000 - used_kb)))

    def test_swap_levels(self):
        with TempDir() as d, Env(d) as env:
            self.swap(env, 100 * 1024)                       # 100 MB < 512
            self.assertEqual(metric(env.collect()["now"], "mem_free_pct")["level"], "ok")
            self.swap(env, 600 * 1024)                       # 600 MB >= 512
            files = env.collect()
            self.assertEqual(metric(files["now"], "mem_free_pct")["level"], "warn")
            self.assertEqual(files["day"]["series"]["swap_mb"][-1], 600)
            self.assertEqual(files["day"]["thresholds"]["swap_mb"], [512, 2048])
            env.conf({"WLSMON_SWAP_MB": "1024,4096"})
            self.assertEqual(metric(env.collect()["now"], "mem_free_pct")["level"], "ok")

    def test_unreadable_threshold_is_reported(self):
        with TempDir() as d, Env(d) as env:
            env.conf({"WLSMON_HEAP_PCT": "85;95"})
            now = env.collect()["now"]
            texts = [e["text"] for e in now["collector"]["errors"]]
            self.assertTrue(any("WLSMON_HEAP_PCT=85;95 unreadable" in t and "80,90" in t for t in texts), texts)

    def test_check_values(self):
        c = wlsmon.threshold_check
        self.assertEqual(c("WLSMON_HEAP_PCT", "85,95"), "")
        self.assertIn("lower than crit", c("WLSMON_HEAP_PCT", "95,85"))
        self.assertIn("0..100", c("WLSMON_DISK_PCT", "90,120"))
        self.assertIn("numbers", c("WLSMON_HEAP_PCT", "85;95"))
        self.assertIn("two numbers", c("WLSMON_HEAP_PCT", "85"))
        self.assertEqual(c("WLSMON_CERT_DAYS", "30,7"), "")
        self.assertIn("greater than crit", c("WLSMON_CERT_DAYS", "7,30"))
        self.assertEqual(c("WLSMON_FORMS_SESSIONS", ""), "")           # empty default = no limit
        self.assertIn("--reset", c("WLSMON_HEAP_PCT", ""))
        self.assertEqual(c("WLSMON_RCU_DAYS", "14"), "")
        self.assertIn("not a threshold", c("WLSMON_ROLE", "both"))
        self.assertEqual(c("WLSMON_SWAP_MB", "512,2048"), "")

    def test_overview(self):
        with TempDir() as d, Env(d) as env:
            env.collect()
            env.collect()
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = wlsmon.thresholds([])
            self.assertEqual(rc, 0)
            rows = dict((r["key"], r) for r in json.loads(out.getvalue())["rows"])
            self.assertEqual(rows["WLSMON_LOAD"]["effective"], [8, 16])
            self.assertEqual(rows["WLSMON_MEM_USED_PCT"]["now"], 75.0)       # 100 - 25 % available
            self.assertEqual(rows["WLSMON_MEM_USED_PCT"]["max_24h"], 75.0)
            self.assertEqual(rows["WLSMON_SWAP_MB"]["now"], 0)
            self.assertTrue(rows["WLSMON_HEAP_PCT"]["valid"])
