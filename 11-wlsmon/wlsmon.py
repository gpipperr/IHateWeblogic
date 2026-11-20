#!/usr/bin/python3
# =============================================================================
# Script   : wlsmon.py
# Purpose  : wlsmon - lightweight read-only runtime monitor for Oracle Forms &
#            Reports 14.1.2 (11-wlsmon/docs/01-wlsmon_concept.md = master).
#            One program, python3 standard library only, 3.6-compatible (OL8).
#              collect   one round of the data role: host, WebLogic REST,
#                        Reports getserverinfo, Forms sessions, nginx, logs with
#                        the rules file, core dumps, RCU (optional), daily patch
#                        level / certificates, hourly security checks -> levels,
#                        topology, rollups -> the 7 JSON files of the contract
#              pull      GUI role (P2) - fetch the data hosts, write hosts.json
#              rules     test the rules file against one log file
#              defaults  the built-in configuration defaults (KEY=value)
#              monitor-user check|create|reset  the WebLogic monitor user (REST)
#              detect    state of this host as JSON for the install scripts
#                        (patch cycle, listening ports, core dir, /i/ libraries)
#              version
# Call     : wlsmon.py collect [--check] [--out DIR] [--state DIR] [--secrets-stdin]
#            wlsmon.py rules --test LOGFILE [--source wls|reports|forms|nginx]
#            wlsmon.py version
#            started by systemd (wlsmon-collect.service, User = FMW owner);
#            configuration only from $WLSMON_BASE/etc/wlsmon.conf, secrets only
#            from $CREDENTIALS_DIRECTORY (systemd credentials, concept 3b)
# Exit     : 0 = round written (errors are in now.json collector.errors),
#            1 = configuration error, 2 = usage
# Safety   : read-only - never changes WebLogic, Reports or nginx; one REST POST
#            per round; after HTTP 401 the monitor user is paused (no lockout);
#            every HTTP request has a timeout; raw log lines never leave the host
# License  : Apache 2.0
# =============================================================================
import calendar
import fcntl
import glob
import json
import os
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from base64 import b64encode
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen, HTTPSHandler, build_opener

VERSION = "0.1.0"
SCHEMA = 1
INTERVAL = 300
RANK = {"ok": 0, "warn": 1, "crit": 2}
FILES = ("now", "day", "week", "history", "patch", "security", "logs")
DAY_POINTS, WEEK_POINTS, HIST_POINTS = 288, 168, 730
CODE_RE = re.compile(r"\b((?:BEA|REP|FRM|ORA|OHS|JPS|OWS|DFW|JBO|WSM|OPSS|IAU|ADF|ODL)-\d{3,6})\b")
SUM_KEYS = ("log_errors", "core_dumps", "reports_jobs")
MIN_KEYS = ("mem_free_pct",)

# Test hook: a prefix for the system paths (/proc, /etc, /run ...), so every part
# runs on fixtures (development plan step 5). Empty in production.
TEST_ROOT = os.environ.get("WLSMON_TEST_ROOT", "")


def P(path):
    """system path, with the test prefix"""
    return os.path.join(TEST_ROOT, path.lstrip("/")) if TEST_ROOT else path


# =============================================================================
# Configuration
# =============================================================================
DEFAULTS = {
    "WLSMON_ROLE": "both",                 # gui | data | both
    "WLSMON_HOST_ID": "",                  # default: short host name
    "WLSMON_PRODUCT": "Forms & Reports",
    "WLSMON_ENV": "prod",                  # prod | qa | test | dev
    "WLSMON_LOCALE": "de-DE",
    "WLSMON_DOMAIN_HOME": "/u01/app/oracle/domains/fr_domain",
    "WLSMON_ORACLE_HOME": "/u01/app/oracle/fmw",
    "WLSMON_JAVA_HOME": "",                # default: ORACLE_HOME/oracle_common/jdk
    "WLSMON_ADMIN_URL": "http://localhost:7001",
    "WLSMON_ADMIN_SERVER": "AdminServer",
    "WLSMON_FORMS_SERVER": "WLS_FORMS",
    "WLSMON_REPORTS_SERVER": "WLS_REPORTS",
    "WLSMON_SERVER_PORTS": "AdminServer:7001 WLS_FORMS:9001 WLS_REPORTS:9002",
    "WLSMON_NM_HOST": "localhost",
    "WLSMON_NM_PORT": "5556",
    "WLSMON_MON_USER": "wlsmon_monitor",   # WebLogic user, group Monitors only
    "WLSMON_REPORTS_URL": "http://localhost:9002/reports/rwservlet",
    "WLSMON_REPORTS_SERVERS": "",          # e.g. "repserver01 rep02"
    "WLSMON_REPORTS_MON_USER": "monUser",
    "WLSMON_NGINX_PID": "/run/nginx.pid",
    "WLSMON_NGINX_ACCESS_LOG": "/var/log/nginx/access.log",
    "WLSMON_NGINX_ERROR_LOG": "/var/log/nginx/error.log",
    "WLSMON_NGINX_CONF_DIRS": "/etc/nginx /etc/nginx/conf.d /etc/nginx/oracle-wls.d",
    "WLSMON_NGINX_PORT": "443",
    "WLSMON_DISKS": "",                    # "label=path ..." default: domain, logs, /tmp
    "WLSMON_LOG_GLOBS": "",                # default: DOMAIN_HOME/servers/*/logs/*.log + *.out
    "WLSMON_LOG_MAX_MB": "20",
    "WLSMON_CORE_DIR": "",                 # default: from kernel.core_pattern
    "WLSMON_CERT_FILES": "",               # default: ssl_certificate of the nginx config
    "WLSMON_PATCH_BASELINE": "",           # expected CPU, e.g. 2026-11
    "WLSMON_APEX_DIR": "/srv/apex/apex_1", # /i/ on disk - checks the GUI library paths
    "WLSMON_EXPECTED_PORTS": "443 7001 5556 9001 9002",
    "WLSMON_RCU_CHECK": "false",
    "WLSMON_RCU_PREFIX": "DEV",
    "WLSMON_RCU_CONNECT": "",              # host:port/service, default from the STB data source
    "WLSMON_SQLPLUS": "",                  # default: ORACLE_HOME/bin/sqlplus
    "WLSMON_DB_MON_USER": "",
    # thresholds "warn,crit" (concept 4.2)
    "WLSMON_HEAP_PCT": "80,90",
    "WLSMON_LOAD": "",                     # default: cores,2*cores
    "WLSMON_CPU_PCT": "80,95",
    "WLSMON_MEM_USED_PCT": "85,95",
    "WLSMON_DISK_PCT": "80,90",
    "WLSMON_LOG_ERRORS": "1,10",
    "WLSMON_FORMS_SESSIONS": "",           # empty = no limit (per environment)
    "WLSMON_REPORTS_QUEUE": "5,20",
    "WLSMON_CERT_DAYS": "30,7",
    "WLSMON_RCU_DAYS": "30",
    "WLSMON_401_PAUSE_MIN": "30",
    "WLSMON_HTTP_TIMEOUT": "20",
    "WLSMON_PULL_HOSTS": "",               # GUI role (P2): "id=https://host ..."
    "WLSMON_PULL_CAFILE": "",
    "WLSMON_PULL_USER": "wlsmon_pull",
    # installation keys - read by the install scripts, not by the collector
    "WLSMON_BASE": "",
    "WLSMON_ADMIN_IP_RANGE": "",           # GUI role: networks of the people (nginx allow)
    "WLSMON_GUI_IP": "",                   # data role: IP of the GUI host A (nginx allow)
    "WLSMON_GUI_USERS": "",                # GUI role: Basic Auth user names (hashes in etc/pending)
    "WLSMON_STYLE_SRC": "'self'",          # CSP style-src of the nginx include
}


class Config(object):
    def __init__(self, base, path=None):
        self.base = base
        self.path = path or os.path.join(base, "etc", "wlsmon.conf")
        self.values = dict(DEFAULTS)
        self.unknown = []
        self.loaded = False
        if os.path.isfile(self.path):
            self.read(self.path)

    def read(self, path):
        with open(path, "r", encoding="utf-8") as fh:
            for no, line in enumerate(fh, 1):
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, val = line.split("=", 1)
                key, val = key.strip(), val.strip()
                # only double quotes are syntax - 'self' (CSP) keeps its single quotes
                if len(val) >= 2 and val[0] == val[-1] == '"':
                    val = val[1:-1]
                if key in DEFAULTS:
                    self.values[key] = val
                else:
                    self.unknown.append("%s:%d %s" % (os.path.basename(path), no, key))
        self.loaded = True

    def get(self, key):
        return self.values.get(key, "")

    def int(self, key, default=0):
        try:
            return int(self.get(key))
        except ValueError:
            return default

    def words(self, key):
        return self.get(key).split()

    def pair(self, key, default=None):
        """'warn,crit' -> [warn, crit] as numbers, or default"""
        v = self.get(key)
        try:
            a, b = [float(x) for x in v.split(",")]
            return [int(a) if a.is_integer() else a, int(b) if b.is_integer() else b]
        except ValueError:
            return default

    def bool(self, key):
        return self.get(key).lower() in ("1", "true", "yes", "on")


# =============================================================================
# Small helpers
# =============================================================================
def now_ts():
    return int(time.time())


def iso(ts):
    return datetime.fromtimestamp(ts, tz=timezone.utc).astimezone().isoformat(timespec="seconds")


def parse_iso(text):
    """ISO 8601 with offset -> epoch seconds (python 3.6: no fromisoformat)"""
    m = re.match(r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d)(?::(\d\d))?(?:\.\d+)?(Z|[+-]\d\d:\d\d)?$", text or "")
    if not m:
        return None
    y, mo, d, h, mi, s = [int(x or 0) for x in m.groups()[:6]]
    ts = calendar.timegm((y, mo, d, h, mi, s))
    tz = m.group(7)
    if tz and tz != "Z":
        off = int(tz[1:3]) * 3600 + int(tz[4:6]) * 60
        ts -= off if tz[0] == "+" else -off
    return ts


def level_of(value, thr, reverse=False):
    """level for a value against [warn, crit]; reverse = lower is worse"""
    if value is None or not thr:
        return "ok"
    w, c = thr
    if reverse:
        return "crit" if value <= c else "warn" if value <= w else "ok"
    return "crit" if value >= c else "warn" if value >= w else "ok"


def worst(levels):
    out = "ok"
    for lv in levels:
        if RANK.get(lv, 0) > RANK[out]:
            out = lv
    return out


def read_text(path, limit=1 << 20):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read(limit)
    except OSError:
        return None


def load_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def write_json(path, obj, mode=0o640):
    """atomic: temporary file in the target directory, then os.replace"""
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp_", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, ensure_ascii=False, separators=(",", ":"))
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def run(cmd, timeout=15, stdin_text=None):
    """subprocess without a shell; returns (rc, stdout) - rc 127 = not found"""
    try:
        p = subprocess.run(cmd, input=stdin_text, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True, timeout=timeout)
        return p.returncode, p.stdout
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, str(exc)


STDIN_SECRETS = {}


def read_stdin_secrets():
    """collect --secrets-stdin: 'name=value' lines on stdin, kept in memory only.
    For a run by hand (test host, development) - under systemd the credentials
    come from $CREDENTIALS_DIRECTORY. Never from argv or the environment."""
    if sys.stdin is None or sys.stdin.isatty():
        return
    for line in sys.stdin.read().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            if re.match(r"^[a-z_]{1,40}$", k.strip()) and v:
                STDIN_SECRETS[k.strip()] = v


def secret(name):
    """a systemd credential (concept 3b); OL8 fallback: etc/creds/<name> mode 400"""
    if name in STDIN_SECRETS:
        return STDIN_SECRETS[name]
    d = os.environ.get("CREDENTIALS_DIRECTORY", "")
    candidates = [os.path.join(d, name)] if d else []
    base = os.environ.get("WLSMON_BASE", "")
    if base:
        candidates.append(os.path.join(base, "etc", "creds", name))
    for p in candidates:
        try:
            st = os.stat(p)
        except OSError:
            continue
        if p.startswith(os.path.join(base, "etc", "creds")) and st.st_mode & 0o077:
            continue          # fallback file readable by others - never used
        with open(p, "r", encoding="utf-8") as fh:
            val = fh.read().strip()
        if val:
            return val
    return None


def http(url, data=None, user=None, password=None, headers=None, timeout=20, cafile=None, method=None):
    """one HTTP request -> (status, body text); status 0 = no connection"""
    hdr = {"User-Agent": "wlsmon/" + VERSION}
    hdr.update(headers or {})
    if user is not None and password is not None:
        tok = b64encode(("%s:%s" % (user, password)).encode("utf-8")).decode("ascii")
        hdr["Authorization"] = "Basic " + tok
    body = data.encode("utf-8") if isinstance(data, str) else data
    req = Request(url, data=body, headers=hdr, method=method)
    try:
        if url.startswith("https:"):
            ctx = ssl.create_default_context(cafile=cafile or None)
            opener = build_opener(HTTPSHandler(context=ctx))
            resp = opener.open(req, timeout=timeout)
        else:
            resp = urlopen(req, timeout=timeout)
        with resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except HTTPError as exc:
        try:
            text = exc.read().decode("utf-8", "replace")
        except OSError:
            text = ""
        return exc.code, text
    except (URLError, OSError, socket.timeout, ssl.SSLError) as exc:
        return 0, str(getattr(exc, "reason", exc))


def port_open(host, port, timeout=3):
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True
    except (OSError, ValueError):
        return False


def proc_cmdlines():
    """{pid: cmdline} of all processes (own user readable)"""
    out = {}
    for d in glob.glob(P("/proc/[0-9]*")):
        try:
            with open(os.path.join(d, "cmdline"), "rb") as fh:
                raw = fh.read()
        except OSError:
            continue
        if raw:
            out[int(os.path.basename(d))] = raw.replace(b"\0", b" ").decode("utf-8", "replace").strip()
    return out


# =============================================================================
# The round: what every part contributes
# =============================================================================
class Round(object):
    def __init__(self, cfg, state, ts, check=False):
        self.cfg = cfg
        self.state = state
        self.ts = ts
        self.check = check
        self.components = []
        self.metrics = []
        self.series = {}          # day series values of this round
        self.errors = []          # collector.errors {level, text}
        self.info = {}            # facts shared between parts
        self.files = {}           # patch / security / logs objects

    def error(self, text, level="warn"):
        self.errors.append({"level": level, "text": text})

    def comp(self, **kw):
        kw.setdefault("level", "ok")
        self.components.append(kw)
        return kw

    def metric(self, mid, group, label, short, value=None, display=None, unit="", sub="",
               level="ok", series=None, decimals=0, items=None):
        m = {"id": mid, "group": group, "label": label, "short": short, "value": value,
             "decimals": decimals, "unit": unit, "sub": sub, "level": level, "series": series}
        if value is None:
            m["display"] = display if display is not None else "n/a"
            if m["display"] == "n/a":
                m["unit"] = ""
        if items is not None:
            m["items"] = items
        self.metrics.append(m)
        return m


def part(fn):
    """a part never breaks the round: an exception becomes a collector error"""
    def wrapper(rnd):
        try:
            fn(rnd)
        except Exception as exc:  # noqa: BLE001 - by design, see docstring
            rnd.error("%s failed: %s: %s" % (fn.__name__, type(exc).__name__, exc))
    wrapper.__name__ = fn.__name__
    return wrapper


# =============================================================================
# 6a Host: uptime, load, CPU (delta of /proc/stat), memory, disks
# =============================================================================
def cpu_counters():
    text = read_text(P("/proc/stat")) or ""
    btime = None
    cpu = None
    for line in text.splitlines():
        if line.startswith("cpu "):
            cpu = [int(x) for x in line.split()[1:]]
        elif line.startswith("btime "):
            btime = int(line.split()[1])
    return cpu, btime


def meminfo():
    out = {}
    for line in (read_text(P("/proc/meminfo")) or "").splitlines():
        parts = line.replace(":", " ").split()
        if len(parts) >= 2 and parts[1].isdigit():
            out[parts[0]] = int(parts[1])   # kB
    return out


def default_disks(cfg):
    dom = cfg.get("WLSMON_DOMAIN_HOME")
    return [("domain", dom), ("logs", os.path.join(dom, "servers")), ("/tmp", "/tmp")]


@part
def part_host(rnd):
    cfg, st = rnd.cfg, rnd.state
    cores = os.cpu_count() or 1
    cpu, btime = cpu_counters()
    load1 = None
    la = read_text(P("/proc/loadavg"))
    if la:
        load1 = float(la.split()[0])
    thr_load = cfg.pair("WLSMON_LOAD") or [cores, 2 * cores]
    rnd.info["thr_load"] = thr_load
    rnd.series["load1"] = load1
    rnd.metric("load1", "host", "Load (%d cores)" % cores, "Load (%d cores)" % cores, load1, decimals=1,
               unit="1 min", sub="limits %s / %s" % tuple(thr_load), level=level_of(load1, thr_load),
               series="load1")

    # CPU % as the average over the interval: delta to the counters of the last run
    cpu_pct, sub = None, "first run - needs two rounds"
    prev = st.get("cpu")
    if cpu and prev and len(prev) == len(cpu):
        d = [a - b for a, b in zip(cpu, prev)]
        total = sum(d[:8]) if len(d) >= 8 else sum(d)
        if total > 0:
            idle = d[3] + (d[4] if len(d) > 4 else 0)
            cpu_pct = round(100.0 * (total - idle) / total, 1)
            iow = round(100.0 * d[4] / total, 1) if len(d) > 4 else 0
            steal = round(100.0 * d[7] / total, 1) if len(d) > 7 else 0
            sub = "iowait %s %% · steal %s %% · avg since last run" % (iow, steal)
    if cpu:
        st["cpu"] = cpu
    thr_cpu = cfg.pair("WLSMON_CPU_PCT", [80, 95])
    rnd.series["cpu_pct"] = cpu_pct
    rnd.metric("cpu_pct", "host", "CPU", "CPU", cpu_pct, decimals=0, unit="%", sub=sub,
               level=level_of(cpu_pct, thr_cpu), series="cpu_pct")

    mi = meminfo()
    free_pct, swap_used, mem_lv = None, 0, "ok"
    if mi.get("MemTotal"):
        avail = mi.get("MemAvailable", mi.get("MemFree", 0))
        free_pct = round(100.0 * avail / mi["MemTotal"], 1)
        swap_used = max(0, mi.get("SwapTotal", 0) - mi.get("SwapFree", 0)) // 1024
        mem_lv = level_of(100 - free_pct, cfg.pair("WLSMON_MEM_USED_PCT", [85, 95]))
        if swap_used > 0 and mem_lv == "ok":
            mem_lv = "warn"
    rnd.series["mem_free_pct"] = free_pct
    rnd.metric("mem_free_pct", "host", "Memory free", "Memory free", free_pct, decimals=0, unit="%",
               sub="swap %d MB" % swap_used, level=mem_lv, series="mem_free_pct")

    thr_disk = cfg.pair("WLSMON_DISK_PCT", [80, 90])
    disks = []
    spec = cfg.words("WLSMON_DISKS")
    pairs = [tuple(x.split("=", 1)) if "=" in x else (x, x) for x in spec] if spec else default_disks(cfg)
    core_dir = rnd.info.get("core_dir")
    if core_dir and core_dir not in [p for _l, p in pairs]:
        pairs.append((core_dir, core_dir))
    seen_dev = set()
    for label, path in pairs:
        try:
            du = shutil.disk_usage(path)
            dev = os.stat(path).st_dev
        except OSError:
            disks.append({"name": label, "value": None, "unit": "%", "level": "warn", "sub": "not found"})
            continue
        pct = int(round(100.0 * du.used / du.total)) if du.total else 0
        item = {"name": label, "value": pct, "unit": "%", "level": level_of(pct, thr_disk)}
        if path == core_dir:
            item["sub"] = "%d GB free (core ≈ heap size)" % (du.free // (1 << 30))
        if dev in seen_dev and path != core_dir:
            item["sub"] = "same file system as above"
        seen_dev.add(dev)
        disks.append(item)
    vals = [d["value"] for d in disks if d["value"] is not None]
    dmax = max(vals) if vals else None
    rnd.series["disk_max_pct"] = dmax
    rnd.metric("disk_max_pct", "host", "Disk max", "Disk", dmax, decimals=0, unit="% max",
               sub="limits %s / %s %%" % tuple(thr_disk), level=worst(d["level"] for d in disks),
               items=disks)

    since = iso(btime) if btime else None
    host = rnd.comp(id="host", type="host", name=rnd.info["host_id"], state="up")
    if since:
        host["since"] = since
    rnd.info["since"] = since


# =============================================================================
# 6b WebLogic REST: one search POST + the expected server list
# =============================================================================
# Field names follow the prototype plan 6.1 - TO VERIFY on 14.1.2 (development
# plan step 6b: first a read-only verification, the answer becomes the fixture).
SEARCH = {
    "links": [], "fields": [],
    "children": {
        "serverRuntimes": {
            "links": [], "fields": ["name", "state", "healthState", "openSocketsCurrentCount"],
            "children": {
                "JVMRuntime": {"links": [], "fields": ["heapSizeCurrent", "heapFreeCurrent",
                                                       "heapSizeMax", "heapFreePercent"]},
                "threadPoolRuntime": {"links": [], "fields": ["hoggingThreadCount", "stuckThreadCount",
                                                              "pendingUserRequestCount",
                                                              "executeThreadTotalCount"]},
                "JDBCServiceRuntime": {"links": [], "fields": [], "children": {
                    "JDBCDataSourceRuntimeMBeans": {"links": [], "fields": [
                        "name", "state", "activeConnectionsCurrentCount",
                        "waitingForConnectionCurrentCount"]}}},
            },
        },
    },
}
REST_HDR = {"X-Requested-By": "wlsmon", "Accept": "application/json", "Content-Type": "application/json"}


def items(obj, key):
    v = (obj or {}).get(key)
    if isinstance(v, dict):
        return v.get("items", []) or []
    return v if isinstance(v, list) else []


def heap_pct(jvm):
    if not jvm:
        return None
    if jvm.get("heapFreePercent") is not None:
        return 100 - int(jvm["heapFreePercent"])
    cur, free = jvm.get("heapSizeCurrent"), jvm.get("heapFreeCurrent")
    mx = jvm.get("heapSizeMax") or cur
    if cur and mx and free is not None:
        return round(100.0 * (cur - free) / mx)
    return None


def wls_fetch(rnd):
    """-> (servers {name: runtime}, expected [names]) or (None, None) when not usable"""
    cfg, st = rnd.cfg, rnd.state
    pause = st.get("rest_pause_until", 0)
    if pause > rnd.ts:
        rnd.error("monitor login refused earlier (HTTP 401) - WebLogic REST paused until %s"
                  % time.strftime("%H:%M", time.localtime(pause)))
        return None, None
    pwd = secret("wls_monitor")
    if pwd is None:
        rnd.error("WebLogic REST: no credential wls_monitor (needs the service context, concept 3b)")
        return None, None
    user = cfg.get("WLSMON_MON_USER")
    base = cfg.get("WLSMON_ADMIN_URL").rstrip("/") + "/management/weblogic/latest"
    tmo = cfg.int("WLSMON_HTTP_TIMEOUT", 20)
    code, body = http(base + "/domainRuntime/search", json.dumps(SEARCH), user, pwd, REST_HDR, tmo)
    if code == 401:
        mins = cfg.int("WLSMON_401_PAUSE_MIN", 30)
        st["rest_pause_until"] = rnd.ts + mins * 60
        rnd.error("monitor login refused (HTTP 401), WebLogic REST paused for %d min" % mins, "crit")
        return None, None
    if code != 200:
        rnd.error("WebLogic REST search: %s" % ("no connection (%s)" % body[:80] if code == 0 else "HTTP %d" % code))
        return None, None
    data = json.loads(body)
    servers = dict((s.get("name"), s) for s in items(data, "serverRuntimes"))
    expected = None
    code, body = http(base + "/domainConfig/servers?fields=name&links=none", None, user, pwd,
                      {"Accept": "application/json", "X-Requested-By": "wlsmon"}, tmo)
    if code == 200:
        expected = [s.get("name") for s in json.loads(body).get("items", [])]
    return servers, expected


@part
def part_wls(rnd):
    cfg = rnd.cfg
    admin, forms, reports = (cfg.get("WLSMON_ADMIN_SERVER"), cfg.get("WLSMON_FORMS_SERVER"),
                             cfg.get("WLSMON_REPORTS_SERVER"))
    ports = dict(x.split(":", 1) for x in cfg.words("WLSMON_SERVER_PORTS") if ":" in x)
    servers, expected = wls_fetch(rnd)
    rnd.info["rest_ok"] = servers is not None
    thr_heap = cfg.pair("WLSMON_HEAP_PCT", [80, 90])
    heap_all, jdbc = [], []
    names = [admin, forms, reports]
    for extra in (expected or []):
        if extra not in names:
            names.append(extra)
    for name in names:
        if not name:
            continue
        rt = (servers or {}).get(name)
        port = ports.get(name)
        if rt is not None:
            state = rt.get("state", "UNKNOWN")
            hs = rt.get("healthState") or {}
            health = (hs.get("state") if isinstance(hs, dict) else str(hs)) or ""
            hp = heap_pct(rt.get("JVMRuntime"))
            tp = rt.get("threadPoolRuntime") or {}
            stuck, hog = tp.get("stuckThreadCount"), tp.get("hoggingThreadCount")
            down = state not in ("RUNNING", "ADMIN") or health.lower() in ("failed", "critical")
            lv = "crit" if down else ("warn" if health.lower() in ("warning", "overloaded") else "ok")
            detail = "health %s" % (health.upper() if health else "n/a")
            if hp is not None:
                detail = "heap %d %%" % hp if not down else detail
                heap_all.append(hp)
                rnd.series["heap_pct_" + name] = hp
            for ds in items(rt.get("JDBCServiceRuntime") or {}, "JDBCDataSourceRuntimeMBeans"):
                jdbc.append((name, ds))
            rnd.info.setdefault("threads", {})[name] = (stuck, hog)
            rnd.info.setdefault("heap", {})[name] = hp
        else:
            # not in serverRuntimes (or REST not usable): port / ready probe
            listening = port_open("localhost", port) if port else False
            ready = None
            if listening and port:
                code, _ = http("http://localhost:%s/weblogic/ready" % port, timeout=5)
                ready = code == 200
            if servers is not None:
                state, down = ("SHUTDOWN", True) if not listening else ("RUNNING (port only)", False)
            else:
                state = "port %s open" % port if listening else "port %s closed" % port if port else "unknown"
                down = port is not None and not listening
            lv = "crit" if down else "ok" if ready or servers is None else "warn"
            detail = ("ready" if ready else "not ready") if ready is not None else ("REST n/a" if servers is None else "")
        c = rnd.comp(id=name, name=name, state=state, detail=detail, level=lv, requires=["host"])
        if name in (forms, reports):
            c["requires"] = ["nginx", "DB"]
        if down:
            c["down"] = True
            c["word"] = "DOWN"
    rnd.series["heap_max_pct"] = max(heap_all) if heap_all else None
    rnd.info["thr_heap"] = thr_heap
    rnd.info["jdbc"] = jdbc

    # Node Manager: port check only (management plane)
    nm_ok = port_open(cfg.get("WLSMON_NM_HOST"), cfg.get("WLSMON_NM_PORT"))
    c = rnd.comp(id="NodeManager", name="NodeManager", state="reachable" if nm_ok else "not reachable",
                 detail="port %s" % cfg.get("WLSMON_NM_PORT"), level="ok" if nm_ok else "crit",
                 requires=["host"])
    if not nm_ok:
        c["down"], c["word"] = True, "DOWN"

    # heap and thread metrics of the two managed servers
    for name, group, label in ((forms, "forms", "Forms"), (reports, "reports", "Reports")):
        rnd.series.setdefault("heap_pct_" + name, None)
        hp = rnd.info.get("heap", {}).get(name)
        down = any(c.get("down") for c in rnd.components if c["id"] == name)
        rnd.metric("heap_%s_pct" % group, group, "Heap " + name, "Heap", None if down else hp,
                   display="n/a", unit="%" if hp is not None and not down else "",
                   sub="server DOWN" if down else "limits %s / %s %%" % tuple(thr_heap),
                   level="crit" if down else level_of(hp, thr_heap), series="heap_pct_" + name)
        stuck, hog = rnd.info.get("threads", {}).get(name, (None, None))
        if stuck is None and hog is None:
            rnd.metric("threads_" + group, group, "Stuck · hogging threads " + name,
                       "Stuck · hogging threads", None, display="n/a", unit="threads",
                       sub="REST n/a", level="ok")
        else:
            lv = "crit" if (stuck or 0) > 0 else "warn" if (hog or 0) > 0 else "ok"
            rnd.metric("threads_" + group, group, "Stuck · hogging threads " + name,
                       "Stuck · hogging threads", None, display="%s · %s" % (stuck or 0, hog or 0),
                       unit="threads", sub="thread pool", level=lv)


# =============================================================================
# DB component: JDBC data sources from the REST answer (+ RCU, 6h)
# =============================================================================
def jdbc_url_from_domain(cfg):
    """host:port/service of the STB (LocalSvcTbl) data source, else the first one"""
    files = sorted(glob.glob(os.path.join(cfg.get("WLSMON_DOMAIN_HOME"), "config", "jdbc", "*.xml")))
    files.sort(key=lambda f: 0 if "localsvctbl" in f.lower() or "stb" in f.lower() else 1)
    for f in files:
        text = read_text(f) or ""
        m = re.search(r"<url>\s*jdbc:oracle:thin:@(?://)?([^<\s]+)\s*</url>", text)
        if m:
            return m.group(1)
    return None


def rcu_check(rnd):
    """hourly: account status / expiry of the RCU schemas (concept 4.1) -> metric dict"""
    cfg, st = rnd.cfg, rnd.state
    if not cfg.bool("WLSMON_RCU_CHECK"):
        return {"display": "not checked", "sub": "WLSMON_RCU_CHECK=false", "level": "ok"}
    cache = st.get("rcu") or {}
    if cache and rnd.ts - cache.get("ts", 0) < 3600:
        return cache["metric"]
    user, pwd = cfg.get("WLSMON_DB_MON_USER"), secret("db_monitor")
    connect = cfg.get("WLSMON_RCU_CONNECT") or jdbc_url_from_domain(cfg)
    sqlplus = cfg.get("WLSMON_SQLPLUS") or os.path.join(cfg.get("WLSMON_ORACLE_HOME"), "bin", "sqlplus")
    if not (user and pwd and connect):
        m = {"display": "not checked", "sub": "DB monitor user / credential db_monitor / connect missing",
             "level": "warn"}
    elif not os.access(sqlplus, os.X_OK):
        m = {"display": "not checked", "sub": "sqlplus not found: %s" % sqlplus, "level": "warn"}
    else:
        prefix = re.sub(r"[^A-Za-z0-9_]", "", cfg.get("WLSMON_RCU_PREFIX")).upper()
        script = ("whenever sqlerror exit 3\nconnect %s/\"%s\"@//%s\nset heading off feedback off pagesize 0 "
                  "linesize 200\nselect username||';'||account_status||';'||"
                  "nvl(to_char(trunc(expiry_date - sysdate)),'-') from dba_users where username like "
                  "'%s\\_%%' escape '\\' order by 1;\nexit\n") % (user, pwd, connect, prefix)
        env_home = cfg.get("WLSMON_ORACLE_HOME")
        os.environ.setdefault("ORACLE_HOME", env_home)
        rc, out = run([sqlplus, "-S", "-L", "/nolog"], timeout=60, stdin_text=script)
        pwd = None
        rows = [l.strip().split(";") for l in out.splitlines() if l.count(";") == 2]
        if rc != 0 or not rows:
            errs = CODE_RE.findall(out)
            m = {"display": "check failed", "sub": "sqlplus rc %d %s" % (rc, " ".join(errs[:2])), "level": "warn"}
        else:
            bad = [r for r in rows if not r[1].startswith("OPEN")]
            soon = [r for r in rows if r[2] not in ("-", "") and int(r[2]) < cfg.int("WLSMON_RCU_DAYS", 30)]
            if bad:
                m = {"display": "login failed", "level": "crit",
                     "sub": "%s: %s · next restart will fail" % (bad[0][0], bad[0][1])}
            elif soon:
                m = {"display": "expires soon", "level": "warn",
                     "sub": "%s: password expires in %s days" % (soon[0][0], soon[0][2])}
            else:
                days = [int(r[2]) for r in rows if r[2] not in ("-", "")]
                m = {"display": "login ok", "level": "ok", "sub": "DB reachable · %d schemas OPEN%s" % (
                    len(rows), " · password expires in %d days" % min(days) if days else "")}
    st["rcu"] = {"ts": rnd.ts, "metric": m}
    return m


@part
def part_db(rnd):
    jdbc = rnd.info.get("jdbc") or []
    seen = {}
    for _srv, ds in jdbc:
        seen.setdefault(ds.get("name"), []).append(ds)
    total = len(seen)
    running = sum(1 for dss in seen.values() if all((d.get("state") or "").lower() == "running" for d in dss))
    active = sum(int(d.get("activeConnectionsCurrentCount") or 0) for _s, d in jdbc)
    waiting = sum(int(d.get("waitingForConnectionCurrentCount") or 0) for _s, d in jdbc)
    rcu = rcu_check(rnd)
    if not rnd.info.get("rest_ok"):
        state, lv, down, detail = "n/a", "ok", False, "REST n/a"
    elif total == 0:
        state, lv, down, detail = "no data sources", "warn", False, ""
    else:
        down = running == 0
        state = "JDBC OK" if running == total else "JDBC %d / %d" % (running, total)
        lv = "crit" if running < total else "ok"
        detail = "data sources %d / %d" % (running, total)
    if rcu["level"] == "crit":
        lv = "crit"
        detail += " · RCU " + rcu["display"]
    c = rnd.comp(id="DB", name="Database", state=state, detail=detail, level=lv, requires=["host"])
    if down:
        c["down"], c["word"] = True, "DOWN"
    if rnd.info.get("rest_ok"):
        rnd.metric("jdbc", "db", "JDBC connections", "JDBC connections", None,
                   display="%d · %d" % (active, waiting), unit="active · waiting",
                   sub="%d data sources" % total, level="warn" if waiting > 0 else "ok")
    else:
        rnd.metric("jdbc", "db", "JDBC connections", "JDBC connections", None, display="n/a",
                   unit="", sub="REST n/a", level="ok")
    rnd.metric("rcu", "db", "RCU schema login", "RCU login", None, display=rcu["display"], unit="",
               sub=rcu["sub"], level=rcu["level"])


# =============================================================================
# 6c Reports: getserverinfo per server (POST, all parameters in the body)
# =============================================================================
REP_HINT = {"50171": "login refused (password, or AdminServer / LDAP down)",
            "56071": "monUser without RW_MONITOR", "52262": "server not secured - caller not <identifier>",
            "51002": "Reports server not reachable"}


def parse_serverinfo(text):
    """getserverinfo XML -> dict, or {'error': ...}"""
    m = re.search(r'<error\s+code="(\d+)"[^>]*message="([^"]*)"', text or "")
    if m:
        return {"error": "REP-%s %s" % (m.group(1), REP_HINT.get(m.group(1), m.group(2)[:80]))}
    if "<serverInfo" not in (text or ""):
        return {"error": "no <serverInfo> in the answer"}
    root = ET.fromstring(text.encode("utf-8") if isinstance(text, str) else text)
    perf = dict((p.get("name"), p.get("value")) for p in root.iter("property"))
    busy = idle = configured = 0
    dead = 0
    for eng in root.iter("engine"):
        busy += int(eng.get("totalBusyEngines") or 0)
        idle += int(eng.get("totalIdleEngines") or 0)
    for inst in root.iter("engineInstance"):
        configured += 1
        if inst.get("status") == "0":
            dead += 1

    def ival(k):
        try:
            return int(float(perf.get(k) or 0))
        except ValueError:
            return 0
    return {"name": root.get("name"), "busy": busy, "idle": idle, "instances": configured, "dead": dead,
            "current": ival("currentJobs"), "successful": ival("successfulJobs"), "failed": ival("failedJobs"),
            "runaway": ival("potentialRunawayJobs"), "long": ival("longRunningJobs")}


@part
def part_reports(rnd):
    cfg, st = rnd.cfg, rnd.state
    names = cfg.words("WLSMON_REPORTS_SERVERS")
    reports_srv = cfg.get("WLSMON_REPORTS_SERVER")
    if not names:
        rnd.metric("reports_jobs", "reports", "Reports jobs", "Jobs", None, display="n/a",
                   unit="running · queued · failed", sub="WLSMON_REPORTS_SERVERS empty", series="reports_jobs")
        return
    pwd = secret("reports_mon")
    user = cfg.get("WLSMON_REPORTS_MON_USER")
    url = cfg.get("WLSMON_REPORTS_URL").rstrip("/") + "/getserverinfo"
    prev = st.get("reports") or {}
    new_prev = {}
    run_n = queue_n = failed_n = done_n = busy_n = idle_n = 0
    lv_all, subs = [], []
    thr_q = cfg.pair("WLSMON_REPORTS_QUEUE", [5, 20])
    for name in names:
        cid = "rep_" + re.sub(r"[^A-Za-z0-9_.-]", "_", name)
        if pwd is None:
            info = {"error": "no credential reports_mon (needs the service context)"}
        else:
            body = {"server": name, "statusformat": "XML", "authid": "%s/%s" % (user, pwd)}
            code, text = http(url, urlencode(body), timeout=cfg.int("WLSMON_HTTP_TIMEOUT", 20) * 3,
                              headers={"Content-Type": "application/x-www-form-urlencoded"})
            if code == 200:
                try:
                    info = parse_serverinfo(text)
                except ET.ParseError as exc:
                    info = {"error": "XML: %s" % exc}
            else:
                info = {"error": "no connection" if code == 0 else "HTTP %d" % code}
        if "error" in info:
            c = rnd.comp(id=cid, name=name, parent=reports_srv, state="no answer", detail=info["error"],
                         level="crit")
            if "50171" in info["error"] or "credential" in info["error"]:
                c["level"] = "warn"          # monitoring problem, not proof of an outage
                c["state"] = "not checked"
            else:
                c["down"], c["word"] = True, "DOWN"
            lv_all.append(c["level"])
            continue
        p = prev.get(name) or {}
        restarted = p and (info["successful"] < p.get("successful", 0) or info["failed"] < p.get("failed", 0))
        d_fail = 0 if not p or restarted else info["failed"] - p.get("failed", 0)
        d_done = 0 if not p or restarted else (info["successful"] - p.get("successful", 0)) + d_fail
        new_prev[name] = {"successful": info["successful"], "failed": info["failed"]}
        queued = max(0, info["current"] - info["busy"])
        run_n += info["busy"]
        queue_n += queued
        failed_n += d_fail
        done_n += d_done
        busy_n += info["busy"]
        idle_n += info["idle"]
        lv = worst([level_of(queued, thr_q), "warn" if d_fail > 0 else "ok",
                    "crit" if info["runaway"] > 0 else "ok",
                    "crit" if info["busy"] + info["idle"] == 0 else "ok"])
        lv_all.append(lv)
        rnd.comp(id=cid, name=name, parent=reports_srv, state="ready",
                 detail="engines %d / %d busy · queue %d" % (info["busy"], info["busy"] + info["idle"], queued),
                 level=lv)
        subs.append(name)
    st["reports"] = new_prev
    rnd.series["reports_jobs"] = done_n
    if not subs:
        rnd.series["reports_jobs"] = None
        rnd.metric("reports_jobs", "reports", "Reports jobs", "Jobs", None, display="n/a",
                   sub="no Reports server answered", level=worst(lv_all), series="reports_jobs")
    else:
        jobs_lv = worst([level_of(queue_n, thr_q), "warn" if failed_n else "ok"])
        rnd.metric("reports_jobs", "reports", "Reports jobs", "Jobs", None,
                   display="%d · %d · %d" % (run_n, queue_n, failed_n), unit="running · queued · failed",
                   sub="%d jobs finished since last run" % done_n, level=jobs_lv, series="reports_jobs")
    eng_lv = "crit" if subs and busy_n + idle_n == 0 else "warn" if subs and idle_n == 0 and busy_n else "ok"
    rnd.metric("reports_engines", "reports", "Reports engines busy · idle", "Engines busy · idle", None,
               display="%d · %d" % (busy_n, idle_n) if subs else "n/a", unit="engines",
               sub="getserverinfo · %d server(s)" % len(names), level=eng_lv if subs else worst(lv_all))


# =============================================================================
# 6d Forms: frmweb processes, session = connection from the WLS_FORMS JVM
# =============================================================================
def socket_table():
    """{inode: (local_port, remote 'ip:port', state)} from /proc/net/tcp + tcp6"""
    out = {}
    for f in ("/proc/net/tcp", "/proc/net/tcp6"):
        for line in (read_text(P(f), 1 << 24) or "").splitlines()[1:]:
            parts = line.split()
            if len(parts) < 10:
                continue
            lport = int(parts[1].rsplit(":", 1)[1], 16)
            raddr, rport = parts[2].rsplit(":", 1)
            out[parts[9]] = (lport, "%s:%d" % (raddr, int(rport, 16)), parts[3], parts[1])
    return out


def pid_sockets(pid):
    inodes = []
    for fd in glob.glob(P("/proc/%d/fd/*" % pid)):
        try:
            target = os.readlink(fd)
        except OSError:
            continue
        m = re.match(r"socket:\[(\d+)\]", target)
        if m:
            inodes.append(m.group(1))
    return inodes


@part
def part_forms(rnd):
    cfg = rnd.cfg
    cmds = rnd.info.get("cmdlines") or proc_cmdlines()
    forms_srv = cfg.get("WLSMON_FORMS_SERVER")
    frm = [pid for pid, c in cmds.items() if re.search(r"(^|/)frmweb(\s|$)", c)]
    jvm = [pid for pid, c in cmds.items() if "-Dweblogic.Name=%s " % forms_srv in c + " "]
    sessions = 0
    if frm:
        table = socket_table()
        jvm_local = set()
        for pid in jvm:
            for ino in pid_sockets(pid):
                t = table.get(ino)
                if t and t[2] == "01":                    # ESTABLISHED
                    jvm_local.add(t[3])                    # 'ADDR:PORT' hex local of the JVM side
        for pid in frm:
            for ino in pid_sockets(pid):
                t = table.get(ino)
                if not t or t[2] != "01":
                    continue
                # remote of the frmweb socket in hex form = local of the JVM socket
                raddr = t[1].rsplit(":", 1)
                hexform = "%s:%04X" % (raddr[0], int(raddr[1]))
                if hexform in jvm_local:
                    sessions += 1
                    break
    pool = len(frm) - sessions
    rnd.series["forms_sessions"] = sessions
    thr = cfg.pair("WLSMON_FORMS_SESSIONS")
    rnd.metric("forms_sessions", "forms", "Forms sessions", "Sessions", sessions, unit="active",
               sub="%d frmweb · %d without a client (prestart pool)" % (len(frm), pool),
               level=level_of(sessions, thr), series="forms_sessions")


# =============================================================================
# 6e nginx: process, requests per minute, 4xx / 5xx, error.log
# =============================================================================
ACCESS_RE = re.compile(r'"\s(\d{3})\s')


def read_new(path, st_offsets, max_bytes):
    """new bytes of a log since the last run (inode + offset; rotation = start
    again; first sight = start at the end). -> (text or None, note)"""
    try:
        s = os.stat(path)
    except OSError:
        return None, "not found"
    key = path
    rec = st_offsets.get(key)
    if rec is None or rec.get("ino") != s.st_ino or s.st_size < rec.get("off", 0):
        start = s.st_size if rec is None else 0
    else:
        start = rec["off"]
    note = ""
    if s.st_size - start > max_bytes:
        note = "skipped %d MB (more than WLSMON_LOG_MAX_MB)" % ((s.st_size - start - max_bytes) >> 20)
        start = s.st_size - max_bytes
    try:
        with open(path, "rb") as fh:
            fh.seek(start)
            data = fh.read(s.st_size - start)
    except OSError as exc:
        return None, "not readable (%s)" % exc.strerror
    st_offsets[key] = {"ino": s.st_ino, "off": start + len(data), "seen": int(time.time())}
    return data.decode("utf-8", "replace"), note


@part
def part_nginx(rnd):
    cfg, st = rnd.cfg, rnd.state
    pid_text = read_text(P(cfg.get("WLSMON_NGINX_PID")))
    running = bool(pid_text and pid_text.strip().isdigit()
                   and os.path.isdir(P("/proc/%s" % pid_text.strip())))
    port = cfg.get("WLSMON_NGINX_PORT")
    if not running:
        running = port_open("localhost", port)
    c = rnd.comp(id="nginx", name="nginx", state="active" if running else "not running",
                 detail="port %s" % port if running else "port %s refused" % port,
                 level="ok" if running else "crit", requires=["host"])
    if not running:
        c["down"], c["word"] = True, "DOWN"
    offsets = st.setdefault("offsets", {})
    maxb = cfg.int("WLSMON_LOG_MAX_MB", 20) << 20
    last = st.get("last_ts")
    minutes = max(1.0, (rnd.ts - last) / 60.0) if last else INTERVAL / 60.0
    text, note = read_new(cfg.get("WLSMON_NGINX_ACCESS_LOG"), offsets, maxb)
    if text is None:
        rnd.metric("nginx_rpm", "nginx", "nginx requests", "Requests", None, display="n/a", unit="",
                   sub="access.log %s" % note, level="crit" if not running else "ok", series="nginx_rpm")
        rnd.series["nginx_rpm"] = None
        if running:
            rnd.error("nginx access.log %s - 02-install-wlsmon_root.sh grants read access" % note, "warn")
    else:
        codes = ACCESS_RE.findall(text)
        n = len(codes)
        c5 = sum(1 for x in codes if x.startswith("5"))
        c4 = sum(1 for x in codes if x.startswith("4"))
        c401 = sum(1 for x in codes if x == "401")
        rpm = round(n / minutes)
        rnd.series["nginx_rpm"] = rpm
        win = [x for x in st.get("auth401", []) if x[0] > rnd.ts - 86400]
        if c401:
            win.append([rnd.ts, c401])
        st["auth401"] = win
        rnd.info["auth401_24h"] = sum(x[1] for x in win)
        lv = "crit" if not running else "warn" if n and c5 * 10 > n else "ok"
        rnd.metric("nginx_rpm", "nginx", "nginx requests", "Requests", rpm if running else None,
                   display="n/a", unit="per min" if running else "",
                   sub="HTTP 5xx %d · 4xx %d" % (c5, c4) if running else "not running", level=lv,
                   series="nginx_rpm")
    text, note = read_new(cfg.get("WLSMON_NGINX_ERROR_LOG"), offsets, maxb)
    errs = None
    if text is not None:
        # not counted: our own hourly security probe (security.json mgmt_rest_proxied)
        # from the loopback - nginx logs its 404 / "forbidden" as [error]
        own = re.compile(r'client: (127\.0\.0\.1|::1), .*request: "GET /management/weblogic/latest HTTP')
        errs = sum(1 for l in text.splitlines()
                   if re.search(r"\[(error|crit|alert|emerg)\]", l) and not own.search(l))
    rnd.series["log_errors_nginx"] = errs
    rnd.info.setdefault("log_errors", {})["nginx"] = errs or 0
    thr = cfg.pair("WLSMON_LOG_ERRORS", [1, 10])
    rnd.metric("log_errors_nginx", "nginx", "nginx log errors (5 min)", "Log errors (5 min)", errs,
               display="n/a", unit="entries" if errs is not None else "",
               sub="error.log" if errs is not None else "error.log %s" % note,
               level=level_of(errs, thr) if errs else "ok", series="log_errors_nginx")


# =============================================================================
# 6f Logs and rules: per log entry, ignore first, then match (concept 4.3)
# =============================================================================
class Rule(object):
    __slots__ = ("type", "id", "level", "source", "regex", "reason", "hits")

    def __init__(self, typ, rid, level, source, regex, reason):
        self.type, self.id, self.level, self.source = typ, rid, level, source
        self.regex, self.reason, self.hits = regex, reason, 0


def load_rules(paths, errors):
    """rules files in order (default, local); a rule id of a later file replaces it"""
    rules = {}
    for path in paths:
        if not path or not os.path.isfile(path):
            continue
        with open(path, "r", encoding="utf-8") as fh:
            for no, line in enumerate(fh, 1):
                line = line.rstrip("\n")
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                f = line.split(";", 5)
                where = "%s:%d" % (os.path.basename(path), no)
                if len(f) != 6:
                    errors.append("rule %s skipped: needs 6 fields" % where)
                    continue
                typ, rid, level, source, regex, reason = [x.strip() for x in f[:5]] + [f[5].strip()]
                if typ not in ("match", "ignore") or not re.match(r"^[a-z0-9_]+$", rid):
                    errors.append("rule %s skipped: type or id invalid" % where)
                    continue
                if typ == "ignore" and not reason:
                    errors.append("rule %s skipped: ignore rule without a reason" % rid)
                    continue
                if typ == "match" and level not in ("warn", "crit"):
                    errors.append("rule %s skipped: level must be warn or crit" % rid)
                    continue
                try:
                    rx = re.compile(regex)
                except re.error as exc:
                    errors.append("rule %s skipped: invalid regex (%s, %s)" % (rid, exc, os.path.basename(path)))
                    continue
                rules[rid] = Rule(typ, rid, level if typ == "match" else "-", source, rx, reason)
    return list(rules.values())


ENTRY_START = re.compile(r"^(####<|\[\d{4}-\d\d-\d\dT)")
WLS_SEV = re.compile(r"^####<[^>]*> <(\w+)>")
ODL_SEV = re.compile(r"^\[[^\]]*\] \[[^\]]*\] \[([A-Z_]+)(?::\d+)?\]")
SEVERITY = {"emergency": "critical", "alert": "critical", "critical": "critical", "incident_error": "critical",
            "error": "error", "warning": "warning"}


def split_entries(text):
    """log text -> entries. A WebLogic (####<) or ODL ([2026-...) entry keeps all
    following lines (stack trace) until the next entry start; in unstructured
    files (.out) every line is an entry, indented lines belong to the one above."""
    entry = []
    structured = False
    for line in text.splitlines():
        if ENTRY_START.match(line):
            new, structured = True, True
        elif not entry:
            new, structured = True, False
        elif structured:
            new = False
        else:
            new = not line[:1].isspace()
        if new:
            if entry:
                yield "\n".join(entry)
            entry = [line]
        else:
            entry.append(line)
    if entry:
        yield "\n".join(entry)


def entry_severity(entry):
    m = WLS_SEV.match(entry) or ODL_SEV.match(entry)
    if m:
        return SEVERITY.get(m.group(1).lower())
    if "OutOfMemoryError" in entry or "SIGSEGV" in entry:
        return "critical"
    return None


def classify(entry, sources, rules):
    """-> (rule or None, severity or None, code); ignore wins, then the highest match"""
    best = None
    for r in rules:
        if r.type != "ignore" or not (r.source == "*" or r.source in sources):
            continue
        if r.regex.search(entry):
            r.hits += 1
            return r, None, None
    for r in rules:
        if r.type != "match" or not (r.source == "*" or r.source in sources):
            continue
        if r.regex.search(entry) and (best is None or RANK[r.level] > RANK[best.level]):
            best = r
    sev = entry_severity(entry)
    m = CODE_RE.search(entry)
    code = m.group(1) if m else ("OOM" if "OutOfMemoryError" in entry else "-")
    if best:
        best.hits += 1
        if sev is None:
            sev = "critical" if best.level == "crit" else "error"
    return best, sev, code


def short_text(entry, code):
    """a short message per code - the first words after the code, never a whole line"""
    first = entry.split("\n", 1)[0]
    i = first.find(code) if code not in ("-", "OOM") else -1
    rest = first[i + len(code):] if i >= 0 else first[-160:]
    rest = re.sub(r"<[^>]*>|\[[^\]]*\]", " ", rest)
    rest = re.sub(r"\s+", " ", rest).strip(" :>-")
    rest = re.sub(r"(/[\w.-]+){2,}", "<path>", rest)            # paths
    rest = re.sub(r"\b\d{1,3}(\.\d{1,3}){3}\b", "<ip>", rest)   # IPs
    rest = re.sub(r"(user(name)?|for)\s*[=:]?\s*['\"]?[\w.@-]+", r"\1 <user>", rest, flags=re.I)
    return rest[:120] or code


def log_files(cfg):
    """(path, sources, component, server) of the logs to read"""
    globs = cfg.words("WLSMON_LOG_GLOBS")
    dom = cfg.get("WLSMON_DOMAIN_HOME")
    if not globs:
        globs = [os.path.join(dom, "servers", "*", "logs", "*.log"),
                 os.path.join(dom, "servers", "*", "logs", "*.out")]
    forms, reports, admin = (cfg.get("WLSMON_FORMS_SERVER"), cfg.get("WLSMON_REPORTS_SERVER"),
                             cfg.get("WLSMON_ADMIN_SERVER"))
    rep_servers = cfg.words("WLSMON_REPORTS_SERVERS")
    out = []
    for g in globs:
        for path in sorted(glob.glob(g)):
            name = os.path.basename(path)
            server = os.path.basename(os.path.dirname(os.path.dirname(path)))
            if server in rep_servers:
                if not re.match(r"^(rwserver|rwEng-\d+)_diagnostic\.log$|^%s\.out$" % re.escape(server), name):
                    continue
                out.append((path, ("reports",), "reports", server))
                continue
            if not re.match(r"^%s(-diagnostic)?\.(log|out)$" % re.escape(server), name):
                continue                                   # access.log, fr_domain.log (duplicate) ...
            if server == forms:
                out.append((path, ("wls", "forms"), "forms", server))
            elif server == reports:
                out.append((path, ("wls", "reports"), "reports", server))
            elif server == admin:
                out.append((path, ("wls",), "admin", server))
            else:
                out.append((path, ("wls",), "wls", server))
    return out


@part
def part_logs(rnd):
    cfg, st = rnd.cfg, rnd.state
    base = rnd.info["base"]
    rules_paths = [rnd.info.get("rules_file") or os.path.join(base, "share", "wlsmon_rules.cfg"),
                   os.path.join(base, "etc", "wlsmon_rules.local.cfg")]
    errs = []
    rules = load_rules(rules_paths, errs)
    for e in errs:
        rnd.error(e)
    if not rules:
        rnd.error("no log rules loaded (share/wlsmon_rules.cfg missing?) - only <Error>/<Critical> counted")
    offsets = st.setdefault("offsets", {})
    maxb = cfg.int("WLSMON_LOG_MAX_MB", 20) << 20
    counts = {"forms": 0, "reports": 0, "admin": 0, "wls": 0}
    crit_counts = dict(counts)
    codes = {"forms": {}, "reports": {}}
    events = dict((tuple(e["k"]), e) for e in st.get("events", []))
    unclassified = 0
    for path, sources, comp, server in log_files(cfg):
        text, note = read_new(path, offsets, maxb)
        if note and text is not None:
            rnd.error("%s: %s" % (os.path.basename(path), note))
        if not text:
            continue
        for entry in split_entries(text):
            rule, sev, code = classify(entry, sources, rules)
            if rule is not None and rule.type == "ignore":
                continue
            if rule is None:
                if sev not in ("critical", "error"):
                    continue
                unclassified += 1
                rid = "unclassified"
            else:
                rid = rule.id
            counts[comp] += 1
            if sev == "critical" or (rule is not None and rule.level == "crit"):
                crit_counts[comp] += 1
            if comp in codes:
                codes[comp][code] = codes[comp].get(code, 0) + 1
            k = (code, server, sev or "error", rid)
            e = events.get(k)
            if e is None:
                events[k] = e = {"k": list(k), "count": 0, "first": rnd.ts, "text": short_text(entry, code)}
            e["count"] += 1
            e["last"] = rnd.ts
    # drop pruned offsets of files that no longer exist (rotation leftovers)
    for k in list(offsets):
        if offsets[k].get("seen", 0) < rnd.ts - 7 * 86400:
            del offsets[k]
    # 24-h window of events (counts per round would need per-round buckets: the
    # window keeps a code until it was not seen for 24 h - documented in logs.json)
    events = dict((k, e) for k, e in events.items() if e["last"] > rnd.ts - 86400)
    st["events"] = list(events.values())
    thr = cfg.pair("WLSMON_LOG_ERRORS", [1, 10])
    for comp, label in (("forms", "Forms"), ("reports", "Reports")):
        n = counts[comp]
        top = sorted(codes[comp].items(), key=lambda x: -x[1])[:2]
        lv = "crit" if crit_counts[comp] else level_of(n, thr)
        rnd.series["log_errors_" + comp] = n
        rnd.metric("log_errors_" + comp, comp, "%s log errors (5 min)" % label, "Log errors (5 min)", n,
                   unit="entries", sub=" · ".join(c for c, _n in top) if top else "server and %s logs" % label,
                   level=lv, series="log_errors_" + comp)
    total = sum(counts.values()) + (rnd.info.get("log_errors", {}).get("nginx") or 0)
    rnd.series["log_errors"] = total
    # logs.json
    ev_list, tot = [], {"critical": 0, "error": 0, "warning": 0}
    for e in sorted(events.values(), key=lambda x: -x["last"]):
        code, server, sev, rid = e["k"]
        sev = sev if sev in tot else "error"
        tot[sev] += e["count"]
        ev_list.append({"severity": sev, "code": code, "rule": rid, "server": server, "count": e["count"],
                        "first_seen": iso(e["first"]), "last_seen": iso(e["last"]), "text": e["text"]})
    hits = st.setdefault("rule_hits", {})
    win = [h for h in hits.get("window", []) if h[0] > rnd.ts - 86400]
    this = dict((r.id, r.hits) for r in rules if r.hits)
    if unclassified:
        this["unclassified"] = unclassified
    if this:
        win.append([rnd.ts, this])
    hits["window"] = win
    agg = {}
    for _ts, d in win:
        for k, v in d.items():
            agg[k] = agg.get(k, 0) + v
    rule_list = [{"id": r.id, "type": r.type, "level": r.level, "source": r.source, "hits": agg.get(r.id, 0),
                  "reason": r.reason} for r in rules]
    rule_list.append({"id": "unclassified", "type": "match", "level": "warn", "source": "*",
                      "hits": agg.get("unclassified", 0), "reason": "<Error>/<Critical> without a rule"})
    rule_list.sort(key=lambda r: (r["type"] != "match", -r["hits"], r["id"]))
    ignored = sum(agg.get(r.id, 0) for r in rules if r.type == "ignore")
    lv = "crit" if tot["critical"] else "warn" if tot["error"] else "ok"
    rnd.files["logs"] = {"schema": SCHEMA, "generated_at": iso(rnd.ts), "window": "24 h", "level": lv,
                         "totals": tot, "ignored": ignored, "events": ev_list[:200], "rules": rule_list}


# =============================================================================
# 6g Core dumps: kernel.core_pattern, coredumpctl, hs_err_pid*.log
# =============================================================================
def core_dir(cfg):
    if cfg.get("WLSMON_CORE_DIR"):
        return cfg.get("WLSMON_CORE_DIR"), False
    pat = (read_text(P("/proc/sys/kernel/core_pattern")) or "core").strip()
    if pat.startswith("|"):
        return None, True                          # systemd-coredump
    d = os.path.dirname(pat)
    return (d if d.startswith("/") else None), False


@part
def part_cores(rnd):
    cfg, st = rnd.cfg, rnd.state
    d, systemd = core_dir(cfg)
    since = st.get("core_since") or rnd.ts
    new = {"forms": [], "reports": [], "other": []}

    def kind(name):
        n = name.lower()
        if "frmweb" in n:
            return "forms"
        if "rwengine" in n or "rwserver" in n or "rweng" in n:
            return "reports"
        return "other"
    if systemd:
        rc, out = run(["coredumpctl", "list", "--no-pager", "--no-legend",
                       "--since", "@%d" % since], timeout=20)
        if rc == 0:
            for line in out.splitlines():
                parts = line.split()
                if len(parts) >= 9:
                    new[kind(parts[-2] if parts[-1] in ("present", "missing", "none") else parts[-1])].append(parts[-2])
    elif d:
        for f in glob.glob(os.path.join(d, "*")):
            try:
                if os.stat(f).st_mtime > since:
                    new[kind(os.path.basename(f))].append(os.path.basename(f))
            except OSError:
                pass
    for f in glob.glob(os.path.join(cfg.get("WLSMON_DOMAIN_HOME"), "hs_err_pid*.log")):
        try:
            if os.stat(f).st_mtime > since:
                text = read_text(f, 4096) or ""
                new["reports" if "rwEngine" in text or "rwserver" in text else "other"].append(os.path.basename(f))
        except OSError:
            pass
    st["core_since"] = rnd.ts
    win = [x for x in st.get("cores", []) if x[0] > rnd.ts - 86400]
    for k, names in new.items():
        for n in names:
            win.append([rnd.ts, k, n])
    st["cores"] = win
    rnd.info["core_dir"] = d
    total_now = sum(len(v) for v in new.values())
    rnd.series["core_dumps"] = total_now
    for comp, label, sub in (("forms", "Forms", "frmweb core*"), ("reports", "Reports", "rwEngine core* · hs_err_pid*")):
        n24 = [x for x in win if x[1] == comp or (comp == "reports" and x[1] == "other")]
        rnd.series["core_dumps_" + comp] = len(new[comp]) + (len(new["other"]) if comp == "reports" else 0)
        rnd.metric("core_dumps_" + comp, comp, "%s core dumps (24 h)" % label, "Core dumps (24 h)", len(n24),
                   unit="new", sub=" · ".join(x[2] for x in n24[-2:]) if n24 else sub,
                   level="crit" if n24 else "ok", series="core_dumps_" + comp)


# =============================================================================
# 6i Daily facts: patch level (inventory files, no OPatch JVM), certificates,
# Derby, GUI library paths
# =============================================================================
def inventory_patches(oh):
    """[(id, description, install-date ISO)] from inventory/patches/*.xml + registry.xml"""
    dates = {}
    reg = read_text(os.path.join(oh, "inventory", "registry.xml"), 1 << 24) or ""
    for m in re.finditer(r'<patch install-date="([^"]+)" patch-id="(\d+)" status="installed"', reg):
        dates[m.group(2)] = max(dates.get(m.group(2), ""), m.group(1))
    out = []
    for f in glob.glob(os.path.join(oh, "inventory", "patches", "*.xml")):
        head = read_text(f, 4096) or ""
        m = re.search(r'\spatch-id="(\d+)"[^>]*?description="([^"]*)"', head)
        if m and m.group(1) in dates:
            out.append((m.group(1), m.group(2), dates[m.group(1)]))
    out.sort(key=lambda x: x[2], reverse=True)
    return out


def bundle_cycle(desc):
    """'WLS STACK PATCH BUNDLE 14.1.2.0.261112 (...)' -> '2026-11'"""
    m = re.search(r"\.(\d{2})(\d{2})(\d{2})\b", desc)
    return "20%s-%s" % (m.group(1), m.group(2)) if m else None


def months_between(a, b):
    ya, ma = [int(x) for x in a.split("-")]
    yb, mb = [int(x) for x in b.split("-")]
    return (yb - ya) * 12 + (mb - ma)


def domain_java_home(cfg, cmdlines):
    """JAVA_HOME the domain really runs with: the java binary of the AdminServer
    (or any WebLogic) process - the bundled JDK and JDK_HOME may differ"""
    admin = cfg.get("WLSMON_ADMIN_SERVER")
    procs = sorted(cmdlines.values(), key=lambda c: 0 if "-Dweblogic.Name=%s " % admin in c + " " else 1)
    for c in procs:
        if "-Dweblogic.Name=" in c:
            java = c.split()[0]
            if java.endswith("/bin/java"):
                return os.path.dirname(os.path.dirname(java))
    return None


def java_version(java_home):
    text = read_text(os.path.join(java_home, "release")) or ""
    m = re.search(r'JAVA_VERSION="([^"]+)"', text)
    return m.group(1) if m else None


def patch_file(rnd):
    cfg = rnd.cfg
    oh = cfg.get("WLSMON_ORACLE_HOME")
    patches = inventory_patches(oh)
    spb = next((p for p in patches if "STACK PATCH BUNDLE" in p[1].upper()), None)
    installed = bundle_cycle(spb[1]) if spb else None
    baseline = cfg.get("WLSMON_PATCH_BASELINE")
    lv, text = "ok", "no baseline set (WLSMON_PATCH_BASELINE)"
    if baseline and installed:
        behind = months_between(installed, baseline)
        if behind <= 0:
            text = "patch level as expected"
        else:
            lv = "crit" if behind >= 3 else "warn"
            text = "%d month(s) behind" % behind
    elif baseline:
        lv, text = "warn", "no Stack Patch Bundle in the inventory"
    jh = (cfg.get("WLSMON_JAVA_HOME") or domain_java_home(cfg, rnd.info.get("cmdlines") or {})
          or os.path.join(oh, "oracle_common", "jdk"))
    opv = (read_text(os.path.join(oh, "OPatch", "version.txt")) or "").replace("OPATCH_VERSION:", "").strip()
    osr = read_text(P("/etc/os-release")) or ""
    m = re.search(r'PRETTY_NAME="([^"]+)"', osr)
    rc, ngx = run(["rpm", "-q", "--qf", "%{VERSION}-%{RELEASE}", "nginx"], timeout=10)

    def first(word):
        return next((p for p in patches if word in p[1].upper()), None)
    psu = first("WLS PATCH SET UPDATE")
    comps = [
        {"name": "WebLogic Server", "version": "14.1.2.0.0",
         "patch_level": spb[1] if spb else "no Stack Patch Bundle", "applied": spb[2] if spb else None,
         "level": lv if baseline else "ok", "note": "Stack Patch Bundle (inventory)"},
        {"name": "WLS Patch Set Update", "version": "14.1.2.0.0", "patch_level": psu[1] if psu else "-",
         "applied": psu[2] if psu else None, "level": "ok", "note": ""},
        {"name": "OPatch", "version": opv or "?", "patch_level": "-", "applied": None, "level": "ok", "note": ""},
        {"name": "JDK", "version": java_version(jh) or "?", "patch_level": "-", "applied": None, "level": "ok",
         "note": "JAVA_HOME of the running domain: " + jh},
        {"name": "Operating system", "version": m.group(1) if m else "?", "patch_level": "not checked",
         "applied": None, "level": "ok", "note": "dnf is not called by the monitor"},
        {"name": "nginx", "version": ngx.strip() if rc == 0 else "?", "patch_level": "rpm", "applied": None,
         "level": "ok", "note": ""},
    ]
    for c in comps:
        if not c["applied"]:
            del c["applied"]
    return {"schema": SCHEMA, "generated_at": iso(rnd.ts), "level": lv if baseline else "ok",
            "baseline": {"cpu": baseline or "-", "installed": installed or "-", "text": text,
                         "source": "WLSMON_PATCH_BASELINE in wlsmon.conf"},
            "components": comps,
            "patches": [{"id": p[0], "description": p[1], "home": oh, "applied": p[2]} for p in patches]}


def nginx_conf_files(cfg):
    out = []
    for d in cfg.words("WLSMON_NGINX_CONF_DIRS"):
        out.extend(sorted(glob.glob(os.path.join(P(d), "*.conf"))))
    return out


def cert_days(path):
    rc, out = run(["openssl", "x509", "-noout", "-enddate", "-in", P(path)], timeout=10)
    m = re.search(r"notAfter=(.+)", out or "")
    if rc != 0 or not m:
        return None
    try:
        t = calendar.timegm(time.strptime(m.group(1).strip().replace("  ", " "), "%b %d %H:%M:%S %Y GMT"))
    except ValueError:
        return None
    return int((t - time.time()) // 86400)


def cert_days_tls(port, server_name):
    """days left of the certificate nginx presents (public, read from the TLS
    handshake - the key files in /etc/nginx/ssl stay root-only)"""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with socket.create_connection(("127.0.0.1", int(port)), timeout=5) as sock:
            with ctx.wrap_socket(sock, server_hostname=server_name or None) as tls:
                der = tls.getpeercert(binary_form=True)
    except (OSError, ValueError, ssl.SSLError):
        return None
    try:
        p = subprocess.run(["openssl", "x509", "-inform", "DER", "-noout", "-enddate"], input=der,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"notAfter=(.+)", p.stdout.decode("ascii", "replace"))
    if not m:
        return None
    try:
        t = calendar.timegm(time.strptime(m.group(1).strip().replace("  ", " "), "%b %d %H:%M:%S %Y GMT"))
    except ValueError:
        return None
    return int((t - time.time()) // 86400)


def daily_facts(rnd, patch):
    cfg = rnd.cfg
    facts = []
    days = [(cert_days(f), os.path.basename(f)) for f in cfg.words("WLSMON_CERT_FILES")]
    tls = cert_days_tls(cfg.get("WLSMON_NGINX_PORT"), socket.getfqdn())
    if tls is not None:
        days.append((tls, "nginx server certificate (port %s)" % cfg.get("WLSMON_NGINX_PORT")))
    days = [d for d in days if d[0] is not None]
    thr = cfg.pair("WLSMON_CERT_DAYS", [30, 7])
    if days:
        d, f = min(days)
        facts.append({"id": "cert_days", "label": "Next certificate expiry", "value": d, "decimals": 0,
                      "unit": "days", "sub": f, "level": level_of(d, thr, reverse=True)})
    else:
        facts.append({"id": "cert_days", "label": "Next certificate expiry", "display": "n/a",
                      "sub": "nginx not reachable over TLS, no WLSMON_CERT_FILES", "level": "ok"})
    b = patch["baseline"]
    facts.append({"id": "patch_cycle", "label": "Patch cycle", "display": "CPU %s" % b["installed"],
                  "sub": ("expected CPU %s · " % b["cpu"] if b["cpu"] != "-" else "") + "from the inventory files",
                  "level": patch["level"]})
    derby = any("derby" in c.lower() and "networkserver" in c.lower() for c in proc_cmdlines().values())
    facts.append({"id": "derby", "label": "Derby", "display": "running" if derby else "not running",
                  "sub": "demo database - should not run" if derby else "as expected",
                  "level": "warn" if derby else "ok"})
    ui = load_json(os.path.join(rnd.info["base"], "www", "ui.json"), {}) or {}
    libs = ui.get("libs") or {}
    apex = cfg.get("WLSMON_APEX_DIR")
    missing = [k for k, v in libs.items() if not os.path.exists(os.path.join(apex, v[len("/i/"):]))]
    if not libs:
        facts.append({"id": "gui_libs", "label": "GUI libraries", "display": "own SVG",
                      "sub": "no /i/ paths in ui.json", "level": "ok"})
    else:
        facts.append({"id": "gui_libs", "label": "GUI libraries", "display": "moved" if missing else "found",
                      "sub": ("run 01-install-wlsmon_fmw.sh --apply: " + ", ".join(missing)) if missing else
                      " · ".join(v.split("/")[3] + " " + v.split("/")[4] for v in libs.values()
                                 if v.count("/") >= 4 and "jquery" not in v),
                      "level": "warn" if missing else "ok"})
    return {"generated_at": iso(rnd.ts), "facts": facts}


# =============================================================================
# 6j Security checks (hourly)
# =============================================================================
def listening_sockets():
    """[(port, loopback, inode)] of the TCP LISTEN sockets (tcp + tcp6)"""
    out = []
    for f in ("/proc/net/tcp", "/proc/net/tcp6"):
        for line in (read_text(P(f), 1 << 24) or "").splitlines()[1:]:
            parts = line.split()
            if len(parts) > 3 and parts[3] == "0A":           # LISTEN
                addr, port = parts[1].rsplit(":", 1)
                loop = addr in ("0100007F", "00000000000000000000000001000000") or addr.endswith("0100007F")
                out.append((int(port, 16), loop, parts[9] if len(parts) > 9 else ""))
    return out


def listening_ports():
    return set((p, loop) for p, loop, _i in listening_sockets())


def ephemeral_start():
    """first port of the ephemeral range (random ports of processes that bind to 0)"""
    try:
        return int((read_text(P("/proc/sys/net/ipv4/ip_local_port_range")) or "32768").split()[0])
    except ValueError:
        return 32768


def socket_owners():
    """{socket inode: process name} for the processes this user can read"""
    out = {}
    for d in glob.glob(P("/proc/[0-9]*")):
        comm = (read_text(os.path.join(d, "comm")) or "?").strip()
        for fd in glob.glob(os.path.join(d, "fd", "*")):
            try:
                m = re.match(r"socket:\[(\d+)\]", os.readlink(fd))
            except OSError:
                continue
            if m:
                out[m.group(1)] = comm
    return out


def port_survey():
    """-> (fixed non-loopback ports below the ephemeral range, {process: count} of
    non-loopback listeners on random ports) - the random ones change at every
    restart (Forms prestart frmweb, Coherence, DB dispatchers), so they are
    counted, not compared with a list"""
    start = ephemeral_start()
    owners = None
    fixed, random_by = set(), {}
    for port, loop, ino in listening_sockets():
        if loop:
            continue
        if port < start:
            fixed.add(port)
            continue
        if owners is None:
            owners = socket_owners()
        name = owners.get(ino, "other user")
        random_by.setdefault(name, set()).add(port)
    return sorted(fixed), dict((k, len(v)) for k, v in random_by.items())


LOC_RE = re.compile(r"\blocation\s+(=|~\*?|\^~)?\s*([^\s{]+)\s*\{")


def nginx_locations(text):
    """[(modifier, path, body)] of every location block (nested ones included);
    body without the nested blocks. Comments removed first."""
    text = re.sub(r"#[^\n]*", "", text)
    out = []
    for m in LOC_RE.finditer(text):
        depth, i, body = 1, m.end(), []
        while i < len(text) and depth:
            ch = text[i]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
            elif depth == 1:
                body.append(ch)
            i += 1
        out.append((m.group(1) or "", m.group(2), "".join(body)))
    return out


def nginx_upstreams(text):
    """{name: [ports]} of the upstream blocks"""
    out = {}
    for m in re.finditer(r"\bupstream\s+(\S+)\s*\{([^}]*)\}", re.sub(r"#[^\n]*", "", text)):
        out[m.group(1)] = re.findall(r"\bserver\s+[^:;\s]+:(\d+)", m.group(2))
    return out


def proxies_to_port(body, upstreams, port):
    m = re.search(r"\bproxy_pass\s+https?://([^/;\s]+)", body)
    if not m:
        return False
    target = m.group(1)
    if ":" in target:
        return target.rsplit(":", 1)[1] == str(port)
    return str(port) in upstreams.get(target, [])


def nginx_server_name(text):
    """first real server_name of a server block that listens on 443"""
    for blk in re.findall(r"listen\s+(?:\[::\]:)?443[^;]*;(.*?)(?=\bserver\s*\{|\Z)", text, re.S):
        m = re.search(r"\bserver_name\s+([^;]+);", blk)
        if m:
            names = [n for n in m.group(1).split() if n != "_"]
            if names:
                return names[0]
    return None


def local_probe(port, path, host=None):
    """HTTP status of an anonymous GET through our own nginx (127.0.0.1, with the
    Host / SNI of the server block), or None. No certificate check: a local
    probe of the own web tier, no data is sent."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        if host:
            # raw request: SNI and Host of the server block, not of 127.0.0.1
            with socket.create_connection(("127.0.0.1", int(port)), timeout=5) as sock:
                with ctx.wrap_socket(sock, server_hostname=host) as tls:
                    tls.sendall(("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: wlsmon/%s\r\n"
                                 "Connection: close\r\n\r\n" % (path, host, VERSION)).encode("ascii"))
                    first = tls.recv(256).decode("ascii", "replace").split("\r\n", 1)[0]
            m = re.match(r"HTTP/\d(?:\.\d)? (\d{3})", first)
            return int(m.group(1)) if m else None
        req = Request("https://127.0.0.1:%s%s" % (port, path), headers={"User-Agent": "wlsmon/" + VERSION})
        with build_opener(HTTPSHandler(context=ctx)).open(req, timeout=5) as resp:
            return resp.status
    except HTTPError as exc:
        return exc.code
    except (URLError, OSError, socket.timeout, ssl.SSLError):
        return None


def security_file(rnd, daily):
    cfg = rnd.cfg
    checks = []

    def add(cid, area, name, result, level, hint=""):
        checks.append({"id": cid, "area": area, "name": name, "result": result, "level": level, "hint": hint})
    cd = next((f for f in daily["facts"] if f["id"] == "cert_days"), None)
    if cd and cd.get("value") is not None:
        add("tls_cert", "nginx", "TLS certificate expiry", "expires in %d days" % cd["value"], cd["level"],
            "renew before 30 days are left" if cd["level"] != "ok" else "")
    confs = "\n".join(read_text(f) or "" for f in nginx_conf_files(cfg))
    if confs:
        protos = re.findall(r"^\s*ssl_protocols\s+([^;]+);", confs, re.M)
        weak = [p for p in " ".join(protos).split() if p in ("SSLv3", "TLSv1", "TLSv1.1")]
        add("tls_proto", "nginx", "TLS protocols", ", ".join(sorted(set(" ".join(protos).split()))) or "nginx default",
            "warn" if weak else "ok", "remove %s" % ", ".join(weak) if weak else "")
        m = re.search(r"location\s+[^{]*/wlsmon/[^{]*\{[^}]*auth_basic\s+\"", confs)
        add("basic_auth", "nginx", "Basic Auth on /wlsmon/", "active" if m else "not found in the nginx config",
            "ok" if m else "warn", "" if m else "02-install-wlsmon_root.sh writes the include")
    else:
        add("nginx_conf", "nginx", "nginx configuration", "not readable", "warn",
            "the FMW owner needs read access to the nginx include files")
    # --- WebLogic administration behind nginx (concept 6, weblogic_rest_monitoring.md)
    ports = dict(x.split(":", 1) for x in cfg.words("WLSMON_SERVER_PORTS") if ":" in x)
    admin_port = ports.get(cfg.get("WLSMON_ADMIN_SERVER"), "7001")
    ups = nginx_upstreams(confs)
    locs = nginx_locations(confs)
    mgmt = [p for mod, p, b in locs if p.lstrip("^").startswith("/management")]
    catch_all = [p for mod, p, b in locs if p == "/" and proxies_to_port(b, ups, admin_port)]
    host = nginx_server_name(confs) or socket.getfqdn()
    code = local_probe(cfg.get("WLSMON_NGINX_PORT"), "/management/weblogic/latest", host)
    bad = mgmt + catch_all
    reach = code is not None and code not in (403, 404, 444)
    if confs:
        result = ("nginx location %s" % ", ".join(bad)) if bad else "no nginx location"
        result += " · /management through nginx: %s" % ("HTTP %s" % code if code is not None else "no answer")
        add("mgmt_rest_proxied", "nginx", "/management (WebLogic REST) not routed through nginx", result,
            "crit" if bad or reach else "ok",
            "remove the location - the REST API stays on localhost, never through the web tier"
            if bad or reach else "")
    # admin applications (console, EM): routed on purpose, but only for ADMIN_IP_RANGE
    admin_locs = [(p, b) for mod, p, b in locs if proxies_to_port(b, ups, admin_port) and p != "/"]
    open_locs, allows = [], set()
    for p, b in admin_locs:
        al = re.findall(r"\ballow\s+([^;]+);", b)
        allows.update(a.strip() for a in al)
        if not re.search(r"\bdeny\s+all\s*;", b) or "all" in [a.strip() for a in al]:
            open_locs.append(p)
    if admin_locs:
        add("admin_locations", "nginx", "Admin console / EM only for the admin network",
            "%s: %s" % (", ".join(p for p, _b in admin_locs),
                        "OPEN for every client: " + ", ".join(open_locs) if open_locs
                        else "allow " + ", ".join(sorted(allows)) + ", deny all"),
            "warn" if open_locs else "ok",
            "allow ADMIN_IP_RANGE + deny all in these locations (09-Install/04-root_nginx.sh)" if open_locs else "")
    # the AdminServer itself: listening beyond the loopback bypasses nginx entirely
    lst = [(pt, loop) for pt, loop in listening_ports() if str(pt) == str(admin_port)]
    if lst:
        ext = [pt for pt, loop in lst if not loop]
        add("admin_listen", "WebLogic", "AdminServer port %s only on the loopback" % admin_port,
            "listens on a network address - /console and /management reachable without nginx" if ext
            else "127.0.0.1 only", "warn" if ext else "ok",
            "listen address localhost (concept: WebLogic behind nginx, 09-Install)" if ext else "")
    a401 = rnd.info.get("auth401_24h")
    if a401 is not None:
        add("auth_fail", "nginx", "Failed logins (401) in 24 h", "%d" % a401, "warn" if a401 > 20 else "ok",
            "check the access log; limit_req is active" if a401 > 20 else "")
    cx = read_text(os.path.join(cfg.get("WLSMON_DOMAIN_HOME"), "config", "config.xml"), 1 << 24)
    if cx:
        prod = re.search(r"<production-mode-enabled>\s*true", cx) is not None
        add("prod_mode", "WebLogic", "Production mode", "enabled" if prod else "disabled",
            "ok" if prod else "warn", "" if prod else "enable production mode")
        demo = re.findall(r"<name>([^<]+)</name>(?:(?!</server>).)*?<key-stores>DemoIdentityAndDemoTrust",
                          cx, re.S)
        add("demo_certs", "WebLogic", "Demo identity / trust keystores",
            "DemoIdentity in use on " + ", ".join(demo) if demo else "custom or none",
            "crit" if demo else "ok", "replace demo certificates with your own keystore" if demo else "")
        lock_off = re.search(r"<lockout-enabled>\s*false", cx) is not None
        add("lockout", "WebLogic", "User lockout", "disabled" if lock_off else "enabled",
            "warn" if lock_off else "ok", "enable the lockout (wls_lockout_config.sh)" if lock_off else "")
    base = rnd.info["base"]
    bad = []
    for sub, maxmode in (("etc", 0o750), ("etc/creds", 0o700), ("state", 0o700)):
        try:
            mode = os.stat(os.path.join(base, sub)).st_mode & 0o777
            if mode & ~maxmode:
                bad.append("%s %o" % (sub, mode))
        except OSError:
            pass
    add("file_perms", "wlsmon", "wlsmon directory permissions", ", ".join(bad) if bad else "ok",
        "warn" if bad else "ok", "chmod as in concept 9.1" if bad else "")
    expected = set(int(x) for x in cfg.words("WLSMON_EXPECTED_PORTS") if x.isdigit())
    fixed, random_by = port_survey()
    unexpected = [p for p in fixed if p not in expected]
    rnd_txt = ", ".join("%s %d" % (k, v) for k, v in sorted(random_by.items()))
    add("ports", "OS", "Listening ports (not loopback)",
        ", ".join(str(p) for p in fixed) + (" · random ports: " + rnd_txt if rnd_txt else ""),
        "warn" if unexpected else "ok",
        ("unexpected: %s - compare with WLSMON_EXPECTED_PORTS" % ", ".join(str(p) for p in unexpected))
        if unexpected else "fixed ports as WLSMON_EXPECTED_PORTS; random ports (ephemeral range) are only counted")
    if random_by.get("frmweb"):
        add("forms_listeners", "Forms", "Forms prestart runtimes listen on all interfaces",
            "%d frmweb listener(s) on random ports, not only on the loopback" % random_by["frmweb"], "ok",
            "the host firewall must block the ephemeral range from outside (only nginx 443 open)")
    lv = worst(c["level"] for c in checks)
    return {"schema": SCHEMA, "generated_at": iso(rnd.ts), "level": lv, "checks": checks}


@part
def part_periodic(rnd):
    """daily patch.json + facts, hourly security.json - from the stamps in state"""
    st, out = rnd.state, rnd.info["out"]
    cache = st.setdefault("periodic", {})
    daily_due = rnd.ts - cache.get("daily_ts", 0) >= 86400 or not os.path.isfile(os.path.join(out, "patch.json"))
    if daily_due or "daily" not in cache:
        patch = patch_file(rnd)
        cache["patch"] = patch
        cache["daily"] = daily_facts(rnd, patch)
        cache["daily_ts"] = rnd.ts
    rnd.files["patch"] = cache["patch"]
    rnd.info["daily"] = cache["daily"]
    hourly_due = rnd.ts - cache.get("hourly_ts", 0) >= 3600 or not os.path.isfile(os.path.join(out, "security.json"))
    if hourly_due or "security" not in cache:
        cache["security"] = security_file(rnd, cache["daily"])
        cache["hourly_ts"] = rnd.ts
    rnd.files["security"] = cache["security"]


# =============================================================================
# 7 Build: topology, levels, now.json, ring + rollups
# =============================================================================
STAGES = [["nginx"], ["ADMIN", "NodeManager"], ["FORMS"], ["REPORTS"], ["DB"]]
METRIC_GROUPS = [{"id": "host", "title": "Server"}, {"id": "nginx", "title": "nginx"},
                 {"id": "forms", "title": "Forms"}, {"id": "reports", "title": "Reports"},
                 {"id": "db", "title": "Database"}]


def topology(rnd):
    """blocked propagation (only DOWN propagates) -> overall level and reasons"""
    comps, metrics = rnd.components, rnd.metrics
    by_id = dict((c["id"], c) for c in comps)

    def root_down(c, seen):
        for r in c.get("requires", []) + ([c["parent"]] if c.get("parent") else []):
            if r in seen or r not in by_id:
                continue
            seen.add(r)
            p = by_id[r]
            if p.get("down"):
                return p
            rd = root_down(p, seen)
            if rd:
                return rd
        return None
    blocked = {}
    for c in comps:
        rd = root_down(c, set())
        if rd and not c.get("down"):
            blocked.setdefault(rd["id"], []).append(c["name"])
            c["level"] = "crit"
            c["state"] = "blocked by %s" % rd["name"]
    host = by_id.get("host")
    if host:
        host["level"] = worst(m["level"] for m in metrics if m["group"] == "host")
        bad = [m["label"] for m in metrics if m["group"] == "host" and m["level"] != "ok"]
        if bad and not host.get("detail"):
            host["detail"] = ", ".join(bad)          # why the host tile is not green
    reasons = []
    for c in comps:
        if c.get("down"):
            txt = "%s: %s" % (c["name"], c["state"])
            if c["id"] in blocked:
                txt += " · blocks " + ", ".join(blocked[c["id"]])
            reasons.append({"level": "crit", "text": txt})
        elif c["level"] != "ok" and c.get("type") != "host" and not c["state"].startswith("blocked") \
                and c["id"] != "DB":
            reasons.append({"level": c["level"], "text": "%s: %s" % (c["name"], c.get("detail") or c["state"])})
    # key figures of a component that is DOWN stay red on their tiles, but the
    # outage is already the root-cause reason - no second reason for it
    cfg = rnd.cfg
    group_comp = {"nginx": "nginx", "forms": cfg.get("WLSMON_FORMS_SERVER"),
                  "reports": cfg.get("WLSMON_REPORTS_SERVER"), "db": "DB"}
    for m in metrics:
        if m["level"] == "ok":
            continue
        gc = by_id.get(group_comp.get(m["group"]))
        if gc is not None and gc.get("down"):
            continue
        v = m["display"] if m["value"] is None else m["value"]
        reasons.append({"level": m["level"], "text": ("%s: %s %s" % (m["label"], v, m["unit"])).strip()})
    reasons.sort(key=lambda r: -RANK[r["level"]])
    overall = worst([c["level"] for c in comps] + [m["level"] for m in metrics])
    return overall, reasons[:6]


def layout(rnd):
    cfg = rnd.cfg
    names = {"ADMIN": cfg.get("WLSMON_ADMIN_SERVER"), "FORMS": cfg.get("WLSMON_FORMS_SERVER"),
             "REPORTS": cfg.get("WLSMON_REPORTS_SERVER")}
    ids = set(c["id"] for c in rnd.components)
    stages = []
    for st in STAGES:
        s = [names.get(x, x) for x in st if names.get(x, x) in ids]
        if s:
            stages.append(s)
    staged = set(x for s in stages for x in s)
    rest = [c["id"] for c in rnd.components
            if c["id"] not in staged and c.get("type") != "host" and not c.get("parent")]
    if rest:
        stages.insert(len(stages) - 1 if stages and stages[-1] == ["DB"] else len(stages), rest)
    return {"stages": stages, "metric_groups": METRIC_GROUPS}


def agg_rule(key):
    if key == "level":
        return "worst"
    if key.startswith(SUM_KEYS):
        return "sum"
    if key.startswith(MIN_KEYS):
        return "min"
    return "max"


def merge(bucket, values):
    for k, v in values.items():
        if v is None:
            continue
        old = bucket.get(k)
        rule = agg_rule(k)
        if old is None:
            bucket[k] = v
        elif rule == "sum":
            bucket[k] = old + v
        elif rule == "min":
            bucket[k] = min(old, v)
        elif rule == "worst":
            bucket[k] = worst([old, v])
        else:
            bucket[k] = max(old, v)


def columns(points, keys):
    """[{'ts':..,k:v}] -> column series with every key"""
    ser = {"ts": [p["ts"] for p in points]}
    for k in sorted(keys):
        ser[k] = [p.get(k) for p in points]
    return ser


def series_files(rnd, thresholds):
    st = rnd.series_state
    values = dict((k, v) for k, v in rnd.series.items())
    point = dict(values)
    point["ts"] = rnd.ts
    day = [p for p in st.get("day", []) if p["ts"] > rnd.ts - 86400 + 60]
    day.append(point)
    st["day"] = day[-DAY_POINTS:]
    out = {}
    for name, res, maxn, key in (("week", 3600, WEEK_POINTS, "week"), ("history", 43200, HIST_POINTS, "history")):
        buckets = dict((int(b["ts"]), b) for b in st.get(key, []))
        bts = rnd.ts // res * res
        b = buckets.setdefault(bts, {"ts": bts})
        v = dict(values)
        if key == "history":
            v["level"] = rnd.overall
        merge(b, v)
        lst = sorted(buckets.values(), key=lambda x: x["ts"])[-maxn:]
        st[key] = lst
        out[name] = lst
    keys = set()
    for p in st["day"]:
        keys.update(k for k in p if k != "ts")
    hist_keys = set(k for p in out["history"] for k in p if k != "ts" and not k.startswith("heap_pct_"))
    week_keys = set(k for p in out["week"] for k in p if k != "ts")
    base = {"schema": SCHEMA, "generated_at": iso(rnd.ts), "thresholds": thresholds}
    files = {
        "day": dict(base, resolution_sec=INTERVAL, aggregation="raw values per 5 min",
                    series=columns(st["day"], keys)),
        "week": dict(base, resolution_sec=3600,
                     aggregation="per hour: maximum; log_errors/core_dumps/reports_jobs as sum; mem_free_pct minimum",
                     series=columns(out["week"], week_keys)),
        "history": dict(base, resolution_sec=43200,
                        aggregation="per 12 h: maximum; mem_free_pct minimum; log_errors/core_dumps/reports_jobs as sum",
                        series=columns(out["history"], hist_keys | {"level"})),
    }
    return files


def build(rnd):
    cfg = rnd.cfg
    overall, reasons = topology(rnd)
    rnd.overall = overall
    thr_load = rnd.info.get("thr_load") or [os.cpu_count() or 1, 2 * (os.cpu_count() or 1)]
    thresholds = {"heap_max_pct": cfg.pair("WLSMON_HEAP_PCT", [80, 90]), "load1": thr_load,
                  "cpu_pct": cfg.pair("WLSMON_CPU_PCT", [80, 95]),
                  "mem_used_pct": cfg.pair("WLSMON_MEM_USED_PCT", [85, 95]),
                  "disk_max_pct": cfg.pair("WLSMON_DISK_PCT", [80, 90])}
    files = series_files(rnd, thresholds)
    files["now"] = {
        "schema": SCHEMA, "generated_at": iso(rnd.ts), "interval_sec": INTERVAL,
        "product": cfg.get("WLSMON_PRODUCT"), "environment": cfg.get("WLSMON_ENV"),
        "domain": os.path.basename(cfg.get("WLSMON_DOMAIN_HOME").rstrip("/")), "host": rnd.info["host_id"],
        "collector": {"version": VERSION, "duration_ms": int((time.time() - rnd.t0) * 1000),
                      "errors": rnd.errors[:20]},
        "daily": rnd.info.get("daily") or {"generated_at": iso(rnd.ts), "facts": []},
        "overall": {"level": overall, "reasons": reasons},
        "components": rnd.components,
        "layout": layout(rnd),
        "metrics": rnd.metrics,
    }
    for name in ("patch", "security", "logs"):
        files[name] = rnd.files.get(name)
    return files


# =============================================================================
# monitor-user: the WebLogic monitor user through REST (01-install-wlsmon_fmw.sh)
# =============================================================================
# Verified on 14.1.2 (2026-11-20): realm myrealm, DefaultAuthenticator offers
# userExists, groupExists, isMember, listMemberGroups (read) and createUser,
# addMemberToGroup, resetUserPassword, removeUser (write) under serverConfig -
# no edit session. Secrets on stdin (admin_user, admin_password, wls_monitor).
def _auth_url(cfg, realm, provider):
    return (cfg.get("WLSMON_ADMIN_URL").rstrip("/") + "/management/weblogic/latest/serverConfig/"
            "securityConfiguration/realms/%s/authenticationProviders/%s" % (realm, provider))


def _op(url, body, user, pwd, timeout):
    code, text = http(url, json.dumps(body), user, pwd, REST_HDR, timeout)
    try:
        return code, json.loads(text) if text else {}
    except ValueError:
        return code, {"raw": text[:200]}


def monitor_user(argv):
    """wlsmon.py monitor-user check|create|reset --secrets-stdin [--realm R] [--provider P]
    check  read-only: exists, member of Monitors, member of nothing else, login works
    create createUser + addMemberToGroup Monitors (only when it does not exist)
    reset  resetUserPassword to the wls_monitor secret
    -> JSON on stdout; exit 0 ok, 1 action needed / failed, 2 usage"""
    action = argv[0] if argv and not argv[0].startswith("--") else ""
    if action not in ("check", "create", "reset"):
        print("usage: wlsmon.py monitor-user check|create|reset --secrets-stdin", file=sys.stderr)
        return 2
    if "--secrets-stdin" in argv:
        read_stdin_secrets()
    cfg = Config(base_dir(), opt(argv, "--config"))
    realm = opt(argv, "--realm") or "myrealm"
    provider = opt(argv, "--provider") or "DefaultAuthenticator"
    url = _auth_url(cfg, realm, provider)
    tmo = cfg.int("WLSMON_HTTP_TIMEOUT", 20)
    mon = cfg.get("WLSMON_MON_USER")
    au, ap, mp = secret("admin_user"), secret("admin_password"), secret("wls_monitor")
    res = {"user": mon, "realm": realm, "provider": provider}
    if not (au and ap):
        res["error"] = "admin_user / admin_password missing on stdin"
        print(json.dumps(res))
        return 1
    code, r = _op(url + "/userExists", {"userName": mon}, au, ap, tmo)
    if code != 200:
        res["error"] = "userExists: %s" % ("no connection" if code == 0 else "HTTP %d" % code)
        if code == 401:
            res["error"] += " - admin login refused, stop (lockout 3/30/15)"
        print(json.dumps(res))
        return 1
    res["exists"] = bool(r.get("return"))
    if action == "create" and not res["exists"]:
        if not mp:
            res["error"] = "wls_monitor secret missing on stdin (00-setup-interview.sh --apply)"
            print(json.dumps(res))
            return 1
        code, r = _op(url + "/createUser", {"userName": mon, "password": mp,
                                             "description": "wlsmon read-only runtime monitor (11-wlsmon)"},
                      au, ap, tmo)
        if code not in (200, 201, 204):
            res["error"] = "createUser: HTTP %d %s" % (code, json.dumps(r)[:200])
            print(json.dumps(res))
            return 1
        code, r = _op(url + "/addMemberToGroup", {"groupName": "Monitors", "memberUserOrGroupName": mon},
                      au, ap, tmo)
        if code not in (200, 201, 204):
            res["error"] = "addMemberToGroup Monitors: HTTP %d" % code
            print(json.dumps(res))
            return 1
        res["created"] = True
        res["exists"] = True
    if action == "reset" and res["exists"]:
        if not mp:
            res["error"] = "wls_monitor secret missing on stdin"
            print(json.dumps(res))
            return 1
        code, r = _op(url + "/resetUserPassword", {"userName": mon, "newPassword": mp}, au, ap, tmo)
        if code not in (200, 201, 204):
            res["error"] = "resetUserPassword: HTTP %d" % code
            print(json.dumps(res))
            return 1
        res["password_reset"] = True
    if res["exists"]:
        res["groups"] = _member_groups(url, mon, au, ap, tmo)
        res["only_monitors"] = res["groups"] == ["Monitors"]
        if mp:
            # login test with the monitor password: one read-only GET (X-Requested-By
            # is required on 14.1.2 even for a GET - without it HTTP 400)
            code, _t = http(cfg.get("WLSMON_ADMIN_URL").rstrip("/") +
                            "/management/weblogic/latest/domainRuntime/serverRuntimes?fields=name&links=none",
                            None, mon, mp, {"Accept": "application/json", "X-Requested-By": "wlsmon"}, tmo)
            res["login"] = code
    ok_ = res.get("exists") and res.get("only_monitors") and res.get("login", 200) == 200
    # "error" = the REST call itself failed (01-install stops); "reason" = the
    # state is not as wanted (e.g. user missing -> 01-install creates it).
    # Putting "user does not exist" into "error" stopped the create (2026-11-20).
    if not ok_ and "error" not in res:
        why = []
        if not res.get("exists"):
            why.append("user does not exist")
        elif res.get("groups") is None:
            why.append("groups not readable (listMemberGroups)")
        elif not res.get("only_monitors"):
            why.append("groups %s - expected only Monitors" % ",".join(res["groups"]))
        if res.get("login", 200) != 200:
            why.append("login test HTTP %s" % res["login"])
        res["reason"] = "; ".join(why)
    print(json.dumps(res))
    return 0 if ok_ else 1


def _member_groups(url, mon, au, ap, tmo):
    """listMemberGroups returns a cursor name (e.g. "Cursor_95"), not a list:
    haveCurrent / getCurrentName / advance, then close. None = not readable."""
    code, r = _op(url + "/listMemberGroups", {"memberUserOrGroupName": mon}, au, ap, tmo)
    cur = r.get("return") if code == 200 else None
    if isinstance(cur, list):                  # in case a release answers with a list
        return sorted(cur)
    if not cur:
        return None
    groups = []
    try:
        for _i in range(200):
            code, h = _op(url + "/haveCurrent", {"cursor": cur}, au, ap, tmo)
            if code != 200:
                return None
            if not h.get("return"):
                break
            code, n = _op(url + "/getCurrentName", {"cursor": cur}, au, ap, tmo)
            if code != 200:
                return None
            groups.append(n.get("return"))
            _op(url + "/advance", {"cursor": cur}, au, ap, tmo)
    finally:
        _op(url + "/close", {"cursor": cur}, au, ap, tmo)
    return sorted(groups)


# =============================================================================
# detect: the state of this host for the install scripts (one place)
# =============================================================================
def _version_key(name):
    return tuple(int(x) for x in name.split(".") if x.isdigit())


def _newest(directory):
    try:
        names = [n for n in os.listdir(directory)
                 if re.match(r"^\d+(\.\d+)+$", n) and os.path.isdir(os.path.join(directory, n))]
    except OSError:
        return None
    return max(names, key=_version_key) if names else None


def find_libs(apex):
    """/i/ paths of the newest font-apex, Oracle JET (+ its knockout), jQuery and
    jQuery UI below an APEX images directory -> dict for ui.json "libs".
    Used by 01-install-wlsmon_fmw.sh (ui.json), devserver.py and the daily fact."""
    libs = {}
    if not apex or not os.path.isdir(apex):
        return libs
    base = os.path.join(apex, "libraries")
    v = _newest(os.path.join(base, "font-apex"))
    if v and os.path.isfile(os.path.join(base, "font-apex", v, "css", "font-apex.min.css")):
        libs["font_apex"] = "/i/libraries/font-apex/" + v
    v = _newest(os.path.join(base, "oraclejet"))
    if v and os.path.isfile(os.path.join(base, "oraclejet", v, "js", "libs", "require", "require.js")):
        libs["jet"] = "/i/libraries/oraclejet/" + v
        # the DVT DataProvider path loads ojtemplateengine-ko -> RequireJS needs knockout
        kdir = os.path.join(base, "oraclejet", v, "js", "libs", "knockout")
        ko = sorted(f for f in os.listdir(kdir) if re.match(r"^knockout-[\d.]+\.js$", f)) \
            if os.path.isdir(kdir) else []
        if ko:
            libs["knockout"] = libs["jet"] + "/js/libs/knockout/" + ko[-1][:-3]
    v = _newest(os.path.join(base, "jquery"))
    if v and os.path.isfile(os.path.join(base, "jquery", v, "jquery-%s.min.js" % v)):
        libs["jquery"] = "/i/libraries/jquery/%s/jquery-%s.min.js" % (v, v)
    v = _newest(os.path.join(base, "jquery-ui"))
    if v and os.path.isfile(os.path.join(base, "jquery-ui", v, "jquery-ui-apex.min.js")):
        libs["jquery_ui"] = "/i/libraries/jquery-ui/%s/jquery-ui-apex.min.js" % v
    return libs


def detect(argv):
    """wlsmon.py detect [--oracle-home DIR] [--apex DIR] -> JSON on stdout"""
    oh = opt(argv, "--oracle-home") or DEFAULTS["WLSMON_ORACLE_HOME"]
    apex = opt(argv, "--apex") or DEFAULTS["WLSMON_APEX_DIR"]
    patches = inventory_patches(oh)
    spb = next((p for p in patches if "STACK PATCH BUNDLE" in p[1].upper()), None)
    fixed, random_by = port_survey()
    cdir, systemd = core_dir(Config("/nonexistent"))
    libs = find_libs(apex)
    out = {"host": socket.gethostname().split(".")[0], "fqdn": socket.getfqdn(),
           "patch_cycle": bundle_cycle(spb[1]) if spb else None, "spb": spb[1] if spb else None,
           "fixed_ports": fixed, "random_listeners": random_by, "core_dir": cdir, "core_systemd": systemd,
           "apex_dir": apex if libs else None, "libs": libs,
           "python": sys.version.split()[0], "systemd_creds": shutil.which("systemd-creds") is not None}
    print(json.dumps(out, indent=1))
    return 0


# =============================================================================
# Commands
# =============================================================================
def base_dir():
    b = os.environ.get("WLSMON_BASE")
    if b:
        return b
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.dirname(here) if os.path.basename(here) == "bin" else here


def collect(argv):
    check = "--check" in argv
    if "--secrets-stdin" in argv:
        read_stdin_secrets()
    base = base_dir()
    os.environ["WLSMON_BASE"] = base
    out = opt(argv, "--out") or os.path.join(base, "api")
    state_dir = opt(argv, "--state") or os.path.join(base, "state")
    cfg = Config(base, opt(argv, "--config"))
    if check:
        state_dir = tempfile.mkdtemp(prefix="wlsmon_check_")
        out = opt(argv, "--out") or state_dir
    for d in (out, state_dir):
        os.makedirs(d, exist_ok=True)
    # own lock file - the systemd unit holds flock on state/collect.lock itself
    with open(os.path.join(state_dir, "run.lock"), "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("wlsmon: another collect run is active", file=sys.stderr)
            return 0
        return collect_round(argv, cfg, base, out, state_dir, check)


def collect_round(argv, cfg, base, out, state_dir, check):
    state_path = os.path.join(state_dir, "state.json")
    series_path = os.path.join(state_dir, "series.json")
    state = load_json(state_path, {}) or {}
    rnd = Round(cfg, state, now_ts(), check)
    rnd.t0 = time.time()
    rnd.series_state = load_json(series_path, {}) or {}
    rnd.info["base"] = base
    rnd.info["out"] = out
    rnd.info["host_id"] = cfg.get("WLSMON_HOST_ID") or socket.gethostname().split(".")[0]
    rnd.info["cmdlines"] = proc_cmdlines()
    if opt(argv, "--rules"):
        rnd.info["rules_file"] = opt(argv, "--rules")
    if not cfg.loaded:
        rnd.error("no wlsmon.conf (%s) - built-in defaults used" % cfg.path)
    for u in cfg.unknown:
        rnd.error("unknown key in wlsmon.conf: %s" % u)
    # core dir first (the host part lists its free space), then the rest
    rnd.info["core_dir"] = core_dir(cfg)[0]
    for fn in (part_host, part_nginx, part_wls, part_db, part_reports, part_forms, part_logs, part_cores,
               part_periodic):
        fn(rnd)
    state["last_ts"] = rnd.ts
    files = build(rnd)
    for name in FILES:
        if files.get(name) is not None:
            write_json(os.path.join(out, name + ".json"), files[name])
    write_json(state_path, state, 0o600)
    write_json(series_path, rnd.series_state, 0o600)
    if not check:
        local_hosts(cfg, base, out, files["now"], rnd)
    if check:
        now = files["now"]
        print("wlsmon %s collect --check  host %s  overall %s  (%d ms)" % (
            VERSION, now["host"], now["overall"]["level"].upper(), now["collector"]["duration_ms"]))
        for c in now["components"]:
            print("  %-5s %-14s %-22s %s" % (c["level"].upper(), c["id"], c["state"][:22], c.get("detail", "")))
        for m in now["metrics"]:
            v = m["display"] if m["value"] is None else m["value"]
            print("  %-5s %-22s %s %s  (%s)" % (m["level"].upper(), m["id"], v, m["unit"], m["sub"]))
        for e in now["collector"]["errors"]:
            print("  ERROR %s" % e["text"])
        if opt(argv, "--out"):
            print("files: %s" % out)
        else:
            shutil.rmtree(state_dir, ignore_errors=True)     # temporary - nothing left behind
    return 0


def host_tile(now, cfg):
    """one entry of hosts.json (concept 3.2) from a now.json - also for pull (P2)"""
    m = {x["id"]: x for x in now.get("metrics", [])}
    host = next((c for c in now.get("components", []) if c.get("type") == "host"), {})

    def val(i):
        x = m.get(i, {})
        return x.get("value") if x.get("value") is not None else x.get("display")
    return {"id": now.get("host"), "name": now.get("host"), "product": now.get("product"),
            "environment": now.get("environment"), "domain": now.get("domain"),
            "level": now["overall"]["level"], "generated_at": now["generated_at"],
            "interval_sec": now.get("interval_sec"), "reasons": now["overall"]["reasons"][:3],
            "collector_errors": len(now.get("collector", {}).get("errors", [])),
            "summary": {"forms_sessions": val("forms_sessions"), "heap_forms_pct": val("heap_forms_pct"),
                        "load1": val("load1"), "cpu_pct": val("cpu_pct"), "since": host.get("since")}}


def local_hosts(cfg, base, out, now, rnd):
    """GUI role on a single host (gui | both, no WLSMON_PULL_HOSTS): this host is
    the only data host. hosts/<id> -> ../api (the host view reads hosts/<id>/,
    the same path as a pulled host) and hosts/hosts.json with its own tile.
    With pull hosts, "wlsmon.py pull" owns hosts.json (P2)."""
    if cfg.get("WLSMON_ROLE") == "data" or cfg.get("WLSMON_PULL_HOSTS"):
        return
    hosts_dir = os.path.join(base, "hosts")
    if not os.path.isdir(hosts_dir):
        return
    hid = now.get("host") or ""
    if not re.match(r"^[A-Za-z0-9._-]+$", hid) or hid.startswith("."):
        return
    link = os.path.join(hosts_dir, hid)
    target = os.path.relpath(out, hosts_dir)
    try:
        if os.path.islink(link) and os.readlink(link) != target:
            os.remove(link)
        if not os.path.lexists(link):
            os.symlink(target, link)
    except OSError as exc:
        rnd.error("hosts/%s: %s" % (hid, exc))
    write_json(os.path.join(hosts_dir, "hosts.json"),
               {"schema": SCHEMA, "generated_at": now["generated_at"], "interval_sec": now.get("interval_sec"),
                "hosts": [host_tile(now, cfg)]})


def rules_test(argv):
    path = opt(argv, "--test")
    if not path:
        print("usage: wlsmon.py rules --test LOGFILE [--source wls] [--rules FILE ...]", file=sys.stderr)
        return 2
    base = base_dir()
    files = [opt(argv, "--rules") or os.path.join(base, "share", "wlsmon_rules.cfg"),
             os.path.join(base, "etc", "wlsmon_rules.local.cfg")]
    if not os.path.isfile(files[0]):
        files[0] = os.path.join(base, "rules", "wlsmon_rules.cfg")       # repository layout
    errs = []
    rules = load_rules(files, errs)
    for e in errs:
        print("RULE  " + e)
    sources = tuple((opt(argv, "--source") or "wls,forms,reports").split(","))
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    n = 0
    uncl = {}
    sev_n = {}
    for entry in split_entries(text):
        n += 1
        rule, sev, code = classify(entry, sources, rules)
        if rule is None and sev in ("critical", "error"):
            uncl[code] = uncl.get(code, 0) + 1
        if sev:
            sev_n[sev] = sev_n.get(sev, 0) + 1
    print("%s: %d entries · severities %s" % (path, n, json.dumps(sev_n)))
    for r in sorted(rules, key=lambda r: -r.hits):
        print("  %-7s %-24s %6d  %s" % (r.type, r.id, r.hits, r.reason))
    print("unclassified <Error>/<Critical> by code (candidates for rules):")
    for code, cnt in sorted(uncl.items(), key=lambda x: -x[1])[:25]:
        print("  %6d  %s" % (cnt, code))
    return 0


def pull(argv):
    print("wlsmon pull: GUI role, phase P2 - not implemented yet", file=sys.stderr)
    return 2


def opt(argv, name):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return None


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__ or "usage: wlsmon.py collect|pull|rules|version")
        print("usage: wlsmon.py collect [--check] [--out DIR] [--state DIR] [--config FILE] [--secrets-stdin]\n"
              "       wlsmon.py rules --test LOGFILE [--source wls,forms,reports] [--rules FILE]\n"
              "       wlsmon.py detect [--oracle-home DIR] [--apex DIR]\n"
              "       wlsmon.py pull | version")
        return 2
    cmd = argv[1]
    if cmd == "collect":
        return collect(argv[2:])
    if cmd == "rules":
        return rules_test(argv[2:])
    if cmd == "pull":
        return pull(argv[2:])
    if cmd == "detect":
        return detect(argv[2:])
    if cmd == "monitor-user":
        return monitor_user(argv[2:])
    if cmd == "defaults":
        # KEY=value of the built-in defaults - the interview starts from these
        for k in sorted(DEFAULTS):
            print("%s=%s" % (k, DEFAULTS[k]))
        return 0
    if cmd == "version":
        print("wlsmon %s (schema %d, python %s)" % (VERSION, SCHEMA, sys.version.split()[0]))
        return 0
    print("unknown command: %s" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
