#!/usr/bin/env python3
# =============================================================================
# Script   : gen_sample_data.py
# Purpose  : Sample data in the wlsmon JSON contract (schema 1) - the 7 files
#            now / day / week / history / patch / security / logs and, with
#            --all-scenarios, the demo hosts.json for the overview page. The GUI
#            is developed and tested against these files without WebLogic.
#            Taken over from the prototype v3 (2026-11-19).
# Call     : python3 -I tools/gen_sample_data.py --scenario warn --out <dir>
#            python3 -I tools/gen_sample_data.py --all-scenarios --out <dir>/api
#              scenarios: normal | warn | crit | nginxdown | rcu | stale
#              --all-scenarios writes <out>/demo/<scenario>/ + <out>/demo/hosts.json
#              (demo mode of the GUI: host.html#demo-<scenario>)
# Note     : never write into 11-wlsmon/www/ of the repository - use a scratch
#            directory; the collector never writes "demo_reference"
# Needs    : python3 (3.6+), standard library only
# License  : Apache 2.0
# =============================================================================
import argparse
import json
import math
import os
import tempfile
import time
from datetime import datetime, timezone

SCHEMA = 1
INTERVAL = 300

THRESHOLDS = {
    "heap_max_pct": [80, 90],
    "load1": [8, 16],
    "cpu_pct": [80, 95],
    "mem_used_pct": [85, 95],
    "disk_max_pct": [80, 90],
}


def rnd(i, s):
    x = math.sin(i * 12.9898 + s * 78.233) * 43758.5453
    return x - math.floor(x)


def level(v, warn, crit):
    if v >= crit:
        return "crit"
    if v >= warn:
        return "warn"
    return "ok"


def iso(ts):
    return datetime.fromtimestamp(ts, tz=timezone.utc).astimezone().isoformat(timespec="seconds")


def workday_curve(ts):
    lt = time.localtime(ts)
    if lt.tm_wday >= 5:
        return 0.12 * _day(lt)
    return _day(lt)


def _day(lt):
    h = lt.tm_hour + lt.tm_min / 60.0
    return math.sin((h - 7) / 10 * math.pi) if 7 <= h <= 17 else 0.0


def write_atomic(path, obj):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp_", suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
    os.chmod(tmp, 0o640)
    os.replace(tmp, path)


def series(n, step, end_ts, sc, seed):
    ts, sess, heap, load, mem, err, core, jobs, hr = [], [], [], [], [], [], [], [], []
    for i in range(n):
        t = end_ts - (n - 1 - i) * step
        c = workday_curve(t)
        ts.append(t)
        sess.append(round(3 + 50 * c + 6 * rnd(i, seed + 1)))
        h = 48 + (i % 11) / 11 * 24 + 5 * rnd(i, seed + 2)
        if sc == "warn" and i > n - 24 and step == INTERVAL:
            h += (i - (n - 24)) * 0.6
        heap.append(round(min(h, 97), 1))
        hr.append(round(42 + (i % 13) / 13 * 20 + 5 * rnd(i, seed + 6), 1))
        l1 = 0.5 + 2.2 * c + 0.7 * rnd(i, seed + 3)
        if sc == "crit" and i > n - 20 and step == INTERVAL:
            l1 += 5
        load.append(round(l1, 2))
        mem.append(round(40 - 18 * c - 3 * rnd(i, seed + 4), 1))
        e = 1 if rnd(i, seed + 5) > 0.97 else 0
        if step == INTERVAL and i >= n - 4:
            e += {"warn": 1, "crit": 4}.get(sc, 0)
        err.append(e * max(1, step // INTERVAL // 6))
        core.append(1 if (sc == "crit" and step == INTERVAL and i == n - 3) else 0)
        jobs.append(round((1 + 6 * c) * max(1, step // INTERVAL)))
    return {
        "ts": ts,
        "forms_sessions": sess,
        "heap_max_pct": [round(max(a, b), 1) for a, b in zip(heap, hr)],
        "heap_pct_WLS_FORMS": heap,
        "heap_pct_WLS_REPORTS": hr,
        "load1": load,
        # CPU % average over the interval, from the /proc/stat delta between two runs
        "cpu_pct": [round(min(99, 6 + 52 * workday_curve(t) + 8 * rnd(i, seed + 9) + (38 if (sc == "crit" and step == INTERVAL and i > n - 20) else 0)), 1)
                    for i, t in enumerate(ts)],
        "mem_free_pct": mem,
        "log_errors": err,
        "core_dumps": core,
        "reports_jobs": jobs,
        # per component (key figures follow the component logic)
        "nginx_rpm": [round((40 + 900 * workday_curve(t)) * (0.9 + 0.2 * rnd(i, seed + 7))) for i, t in enumerate(ts)],
        "log_errors_nginx": [1 if rnd(i, seed + 8) > 0.985 else 0 for i in range(n)],
        "log_errors_forms": [round(e * 0.4) for e in err],
        "log_errors_reports": [e - round(e * 0.4) for e in err],
        "core_dumps_forms": core,
        "core_dumps_reports": [0] * n,
    }


def series_file(gen, res, n, end_ts, sc, seed, agg_note, with_level=False):
    s = series(n, res, end_ts, sc, seed)
    if with_level:
        s.pop("heap_pct_WLS_FORMS", None)
        s.pop("heap_pct_WLS_REPORTS", None)
        lv = []
        for i in range(n):
            worst = level(s["heap_max_pct"][i], 80, 90)
            if s["log_errors"][i] > 0 and worst == "ok":
                worst = "warn"
            if s["core_dumps"][i] > 0 or s["log_errors"][i] > 9:
                worst = "crit"
            lv.append(worst)
        s["level"] = lv
    return {
        "schema": SCHEMA,
        "generated_at": iso(gen),
        "resolution_sec": res,
        "aggregation": agg_note,
        "thresholds": THRESHOLDS,
        "series": s,
    }


def now_file(gen, sc, day):
    crit = sc == "crit"
    warn = sc == "warn"
    heap_forms = 71 if crit else 84 if warn else 68
    log_err = 17 if crit else 3 if warn else 0
    sess = day["series"]["forms_sessions"][-1]
    load1 = day["series"]["load1"][-1]
    mem_free = day["series"]["mem_free_pct"][-1]
    day["series"]["heap_pct_WLS_FORMS"][-1] = heap_forms

    # Texts English (02-wlsmon_interface_design.md, section 8);
    # numbers stay plain, formatting happens in the browser
    ngx_down = sc == "nginxdown"
    rcu_fail = sc == "rcu"
    # Components from outside to inside. "requires": the component cannot work
    # when one of these is DOWN. "parent": shown nested inside that component.
    comps = [
        {"id": "host", "type": "host", "name": "[HOST]", "state": "up", "level": "ok",
         "since": iso(gen - 16 * 86400 - 8 * 3600 - 23 * 60)},   # boot time: /proc/stat btime
        {"id": "nginx", "name": "nginx", "requires": ["host"],
         "state": "not running" if ngx_down else "active",
         "detail": "port 443 refused" if ngx_down else "TLS · Basic Auth",
         "level": "crit" if ngx_down else "ok", "down": ngx_down},
        {"id": "AdminServer", "name": "AdminServer", "requires": ["host"], "state": "RUNNING",
         "detail": "port 7001 · health OK", "level": "ok"},
        {"id": "NodeManager", "name": "NodeManager", "requires": ["host"], "state": "reachable",
         "detail": "port 5556", "level": "ok"},
        {"id": "WLS_FORMS", "name": "WLS_FORMS", "requires": ["nginx", "DB"], "state": "RUNNING",
         "detail": f"heap {heap_forms} %", "level": level(heap_forms, 80, 90)},
        {"id": "WLS_REPORTS", "name": "WLS_REPORTS", "requires": ["nginx", "DB"],
         "state": "FAILED" if crit else "RUNNING",
         "detail": "health FAILED" if crit else "heap 61 %", "level": "crit" if crit else "ok", "down": crit},
        {"id": "rep_reptool01", "name": "reptool01", "parent": "WLS_REPORTS", "state": "ready",
         "detail": "engines 2 / 3 busy · queue 1", "level": "ok"},
        {"id": "rep_itsutf8", "name": "itsutf8", "parent": "WLS_REPORTS", "state": "ready",
         "detail": "engines 1 / 3 busy · queue 0", "level": "ok"},
        {"id": "rep_def25", "name": "def25", "parent": "WLS_REPORTS", "state": "ready",
         "detail": "engines 0 / 2 busy · queue 0", "level": "ok"},
        {"id": "DB", "name": "Database", "requires": ["host"], "state": "JDBC OK",
         "detail": "data sources 2 / 2 · RCU login failed" if rcu_fail else "data sources 2 / 2 · RCU ok",
         "level": "crit" if rcu_fail else "ok"},
    ]
    for c in comps:
        if c.get("down"):
            c["word"] = "DOWN"
        else:
            c.pop("down", None)
    # Host level from the host key figures (load, memory, disk, core dumps)
    layout = {"stages": [["nginx"], ["AdminServer", "NodeManager"], ["WLS_FORMS"], ["WLS_REPORTS"], ["DB"]]}

    rpm = 0 if ngx_down else day["series"]["nginx_rpm"][-1]
    cpu = day["series"]["cpu_pct"][-1]
    le_forms = 3 if warn else 2 if crit else 0
    le_reports = 15 if crit else 0
    le_nginx = 12 if ngx_down else 0
    # "group": the component block the key figure belongs to (same logic as the
    # components, from outside to inside). "label" is the full name for the
    # reasons, "short" the name on the card inside its block.
    metrics = [
        {"id": "load1", "group": "host", "label": "Load (8 cores)", "short": "Load (8 cores)", "value": load1, "decimals": 1,
         "unit": "1 min", "sub": "limits 8 / 16", "level": level(load1, 8, 16), "series": "load1"},
        {"id": "cpu_pct", "group": "host", "label": "CPU", "short": "CPU", "value": cpu, "decimals": 0,
         "unit": "%", "sub": "iowait 2 % · steal 0 % · 5 min avg", "level": level(cpu, 80, 95), "series": "cpu_pct"},
        {"id": "mem_free_pct", "group": "host", "label": "Memory free", "short": "Memory free", "value": mem_free, "decimals": 0,
         "unit": "%", "sub": "swap 0 MB", "level": level(100 - mem_free, 85, 95), "series": "mem_free_pct"},
        {"id": "disk_max_pct", "group": "host", "label": "Disk max", "short": "Disk", "value": 71, "decimals": 0, "unit": "% max",
         "sub": "limits 80 / 90 %", "level": "ok", "series": None,
         "items": [
             {"name": "/u01 (domain)", "value": 58, "unit": "%", "level": "ok"},
             {"name": "/u01/logs", "value": 71, "unit": "%", "level": "ok"},
             {"name": "Reports cache", "value": 44, "unit": "%", "level": "ok"},
             {"name": "/tmp", "value": 12, "unit": "%", "level": "ok"},
             {"name": "/var/tmp/core", "value": 9, "unit": "%", "level": "ok", "sub": "38 GB free (core ≈ heap size)"},
         ]},

        {"id": "nginx_rpm", "group": "nginx", "label": "nginx requests", "short": "Requests", "value": None if ngx_down else rpm,
         "display": "n/a" if ngx_down else None, "decimals": 0, "unit": "" if ngx_down else "per min",
         "sub": "not running" if ngx_down else "HTTP 5xx 0 · 4xx 3", "level": "crit" if ngx_down else "ok", "series": "nginx_rpm"},
        {"id": "log_errors_nginx", "group": "nginx", "label": "nginx log errors (5 min)", "short": "Log errors (5 min)",
         "value": le_nginx, "decimals": 0, "unit": "entries", "sub": "error.log",
         "level": "warn" if le_nginx else "ok", "series": "log_errors_nginx"},

        {"id": "forms_sessions", "group": "forms", "label": "Forms sessions", "short": "Sessions", "value": sess, "decimals": 0,
         "unit": "active", "sub": "prestart pool 10 · 4 idle", "level": "ok", "series": "forms_sessions"},
        {"id": "heap_forms_pct", "group": "forms", "label": "Heap used WLS_FORMS", "short": "Heap used", "value": heap_forms, "decimals": 0,
         "unit": "%", "sub": "of max heap 2 GB · WLS_FORMS JVM w/o frmweb · limits 80 / 90 %", "level": level(heap_forms, 80, 90), "series": "heap_pct_WLS_FORMS"},
        {"id": "threads_forms", "group": "forms", "label": "Stuck · hogging threads WLS_FORMS", "short": "Stuck · hogging threads",
         "value": None, "display": "0 · 2" if warn else "0 · 0", "unit": "threads", "sub": "thread pool",
         "level": "warn" if warn else "ok", "series": None},
        {"id": "log_errors_forms", "group": "forms", "label": "Forms log errors (5 min)", "short": "Log errors (5 min)",
         "value": le_forms, "decimals": 0, "unit": "entries", "sub": "FRM-93652 · BEA-002936" if le_forms else "server and Forms logs",
         "level": "warn" if le_forms else "ok", "series": "log_errors_forms"},
        {"id": "core_dumps_forms", "group": "forms", "label": "Forms core dumps (24 h)", "short": "Core dumps (24 h)",
         "value": 1 if crit else 0, "decimals": 0, "unit": "new", "sub": "frmweb · core.48211" if crit else "frmweb core*",
         "level": "crit" if crit else "ok", "series": "core_dumps_forms"},

        {"id": "reports_jobs", "group": "reports", "label": "Reports jobs", "short": "Jobs", "value": None,
         "display": "0 · 9 · 4" if crit else "3 · 1 · 0", "unit": "running · queued · failed",
         "sub": "queue is growing" if crit else "3 report servers", "level": "crit" if crit else "ok", "series": "reports_jobs"},
        {"id": "reports_engines", "group": "reports", "label": "Reports engines busy · idle", "short": "Engines busy · idle",
         "value": None, "display": "0 · 0" if crit else "3 · 5", "unit": "engines",
         "sub": "no engine reachable" if crit else "getserverinfo · 8 configured", "level": "crit" if crit else "ok", "series": None},
        {"id": "heap_reports_pct", "group": "reports", "label": "Heap used WLS_REPORTS", "short": "Heap used", "value": None if crit else 61,
         "decimals": 0, "display": "n/a" if crit else None, "unit": "" if crit else "%",
         "sub": "server FAILED" if crit else "of max heap 2 GB · WLS_REPORTS JVM w/o engines · limits 80 / 90 %", "level": "crit" if crit else "ok", "series": "heap_pct_WLS_REPORTS"},
        {"id": "threads_reports", "group": "reports", "label": "Stuck · hogging threads WLS_REPORTS", "short": "Stuck · hogging threads",
         "value": None, "display": "2 · 6" if crit else "0 · 1", "unit": "threads", "sub": "thread pool",
         "level": "crit" if crit else "ok", "series": None},
        {"id": "log_errors_reports", "group": "reports", "label": "Reports log errors (5 min)", "short": "Log errors (5 min)",
         "value": le_reports, "decimals": 0, "unit": "entries", "sub": "critical 4 · BEA-000337" if crit else "server and Reports logs",
         "level": "crit" if crit else "ok", "series": "log_errors_reports"},
        {"id": "core_dumps_reports", "group": "reports", "label": "Reports core dumps (24 h)", "short": "Core dumps (24 h)",
         "value": 0, "decimals": 0, "unit": "new", "sub": "rwEngine core* · hs_err_pid*", "level": "ok", "series": "core_dumps_reports"},

        {"id": "jdbc", "group": "db", "label": "JDBC connections", "short": "JDBC connections", "value": None,
         "display": "14 · 0", "unit": "active · waiting", "sub": "4 RCU data sources · not the Forms / Reports app sessions", "level": "ok", "series": None},
        # RCU: a failed schema login shows only at the next restart of the domain,
        # so it is checked on its own (concept 4.1)
        {"id": "rcu", "group": "db", "label": "RCU schema login", "short": "RCU login", "value": None,
         "display": "login failed" if rcu_fail else "login ok", "unit": "",
         "sub": "DEV_STB: ORA-28000 account locked · next restart will fail" if rcu_fail
                else "DB reachable · 5 schemas OPEN · password expires in 143 days",
         "level": "crit" if rcu_fail else "ok", "series": None},
    ]
    metric_groups = [
        {"id": "host", "title": "Server"}, {"id": "nginx", "title": "nginx"},
        {"id": "forms", "title": "Forms"}, {"id": "reports", "title": "Reports"}, {"id": "db", "title": "Database"},
    ]
    layout["metric_groups"] = metric_groups
    collector_errors = []
    if sc == "warn":
        collector_errors.append({"level": "warn", "text": "rule my_rule skipped: invalid regex (wlsmon_rules.local.cfg)"})
    if sc == "nginxdown":
        collector_errors.append({"level": "warn", "text": "monitor login refused (HTTP 401), WebLogic REST paused for 30 min"})
    rank = {"ok": 0, "warn": 1, "crit": 2}
    host = comps[0]
    host_lv = "ok"
    for m in metrics:
        if m.get("group") == "host" and rank[m["level"]] > rank[host_lv]:
            host_lv = m["level"]
    host["level"] = host_lv

    # Dependencies: a component whose requirement (or parent) is DOWN is blocked.
    # Only the root cause becomes a reason, the blocked ones are counted.
    by_id = {c["id"]: c for c in comps}

    def root_down(c, seen=None):
        seen = seen or set()
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
        rd = root_down(c)
        if rd:
            blocked.setdefault(rd["id"], []).append(c["name"])

    worst, reasons = "ok", []
    for x in comps + metrics:
        if rank[x["level"]] > rank[worst]:
            worst = x["level"]
        if blocked and worst != "crit":
            worst = "crit"
        if x.get("type") == "host":
            continue
        if "name" in x and not x.get("down"):
            continue   # degraded components show up through their key figure (RCU: the RCU tile)
        if x["level"] != "ok":
            if "name" in x:
                txt = f'{x["name"]}: {x["state"]}'
                if x["id"] in blocked:
                    txt += f' · blocks {", ".join(blocked[x["id"]])}'
            else:
                v = x.get("display") if x.get("value") is None else x["value"]
                txt = f'{x["label"]}: {v} {x["unit"]}'.strip()
            reasons.append({"level": x["level"], "text": txt})
    reasons.sort(key=lambda r: -rank[r["level"]])
    return {
        "schema": SCHEMA,
        "generated_at": iso(gen),
        "interval_sec": INTERVAL,
        "product": "GPIStudio",        # WLSMON_PRODUCT in wlsmon.conf
        "environment": "prod",         # WLSMON_ENV: prod | qa | test | dev
        "domain": "[DOMAIN]",
        "host": "[HOST]",
        "collector": {"version": "0.1-sample", "duration_ms": 840, "errors": collector_errors},
        # once a day, cheap (concept 4.1 "daily facts")
        "daily": {"generated_at": iso(gen - 6 * 3600), "facts": [
            {"id": "cert_days", "label": "Next certificate expiry", "value": 21, "decimals": 0, "unit": "days",
             "sub": "nginx server certificate", "level": "warn"},
            {"id": "patch_cycle", "label": "Patch cycle", "display": "CPU 2026-07", "sub": "expected CPU 2026-10 · from the inventory files",
             "level": "warn"},
            {"id": "derby", "label": "Derby", "display": "not running", "sub": "as expected", "level": "ok"},
            {"id": "gui_libs", "label": "GUI libraries", "display": "found", "sub": "JET 20.1.4 · font-apex 2.5.1 (ui.json)", "level": "ok"},
        ]},
        "overall": {"level": worst, "reasons": reasons[:6]},
        "components": comps,
        "layout": layout,
        "metrics": metrics,
    }


def extras(gen, sc):
    """patch.json (daily), security.json (hourly), logs.json (every 5 min).
    All values are sample data; patch ids and versions are placeholders."""
    crit = sc == "crit"
    day = 86400
    patch = {
        "schema": SCHEMA, "generated_at": iso(gen - 3 * 3600), "level": "warn",
        "baseline": {"cpu": "2026-10", "installed": "2026-07", "text": "one CPU behind",
                     "source": "WLSMON_PATCH_BASELINE in wlsmon.conf"},
        "components": [
            {"name": "Oracle Home (FMW Infrastructure)", "version": "14.1.2.0.0", "patch_level": "CPU 2026-07",
             "applied": iso(gen - 95 * day), "level": "warn", "note": "CPU 2026-10 available"},
            {"name": "WebLogic Server", "version": "14.1.2.0.0", "patch_level": "Stack Patch Bundle CPU 2026-07",
             "applied": iso(gen - 95 * day), "level": "warn", "note": "follows the Oracle Home"},
            {"name": "Forms & Reports", "version": "14.1.2.0.0", "patch_level": "Bundle CPU 2026-07",
             "applied": iso(gen - 95 * day), "level": "warn", "note": ""},
            {"name": "OPatch", "version": "13.9.4.2.x", "patch_level": "current", "applied": iso(gen - 96 * day),
             "level": "ok", "note": ""},
            {"name": "JDK", "version": "21.0.x", "patch_level": "CPU 2026-10", "applied": iso(gen - 20 * day),
             "level": "ok", "note": "JAVA_HOME of the domain"},
            {"name": "Operating system", "version": "Oracle Linux 9.x", "patch_level": "dnf: 12 updates pending",
             "applied": iso(gen - 34 * day), "level": "warn", "note": "kernel restart pending"},
            {"name": "nginx", "version": "1.2x", "patch_level": "repo current", "applied": iso(gen - 34 * day),
             "level": "ok", "note": ""},
        ],
        "patches": [
            {"id": "sample-1001", "description": "WLS Stack Patch Bundle (CPU 2026-07)", "home": "/u01/oracle/fmw",
             "applied": iso(gen - 95 * day)},
            {"id": "sample-1002", "description": "Forms & Reports bundle patch (CPU 2026-07)", "home": "/u01/oracle/fmw",
             "applied": iso(gen - 95 * day)},
            {"id": "sample-1003", "description": "One-off: Reports PDF font fix", "home": "/u01/oracle/fmw",
             "applied": iso(gen - 60 * day)},
            {"id": "sample-1004", "description": "OPatch update", "home": "/u01/oracle/fmw",
             "applied": iso(gen - 96 * day)},
        ],
    }
    checks = [
        {"id": "tls_cert", "area": "nginx", "name": "TLS certificate expiry", "result": "expires in 21 days",
         "level": "warn", "hint": "renew before 30 days are left"},
        {"id": "tls_proto", "area": "nginx", "name": "TLS protocols", "result": "TLSv1.2, TLSv1.3", "level": "ok", "hint": ""},
        {"id": "basic_auth", "area": "nginx", "name": "Basic Auth on /wlsmon/", "result": "active", "level": "ok", "hint": ""},
        {"id": "mgmt_exposed", "area": "nginx", "name": "/console and /management not proxied",
         "result": "not reachable from outside", "level": "ok", "hint": ""},
        {"id": "auth_fail", "area": "nginx", "name": "Failed logins (401) in 24 h", "result": "37 from 2 addresses",
         "level": "warn", "hint": "check the access log; limit_req is active"},
        {"id": "prod_mode", "area": "WebLogic", "name": "Production mode", "result": "enabled", "level": "ok", "hint": ""},
        {"id": "demo_certs", "area": "WebLogic", "name": "Demo identity / trust keystores",
         "result": "DemoIdentity in use on WLS_REPORTS" if crit else "custom keystores", "level": "crit" if crit else "ok",
         "hint": "replace demo certificates with your own keystore" if crit else ""},
        {"id": "lockout", "area": "WebLogic", "name": "User lockout", "result": "enabled (5 attempts)", "level": "ok", "hint": ""},
        {"id": "monitor_user", "area": "wlsmon", "name": "Monitoring user only in group Monitors", "result": "yes",
         "level": "ok", "hint": ""},
        {"id": "file_perms", "area": "wlsmon", "name": "netrc / htpasswd permissions", "result": "600 / 640",
         "level": "ok", "hint": ""},
        {"id": "ports", "area": "OS", "name": "Listening ports", "result": "443, 7001 (localhost), 5556 (localhost), 9001, 9002",
         "level": "ok", "hint": "compared with the expected list in wlsmon.conf"},
    ]
    worst = "ok"
    rank = {"ok": 0, "warn": 1, "crit": 2}
    for c in checks:
        if rank[c["level"]] > rank[worst]:
            worst = c["level"]
    security = {"schema": SCHEMA, "generated_at": iso(gen - 20 * 60), "level": worst, "checks": checks}

    ev = [
        ("warning", "BEA-000449", "WLS_FORMS", 14, 6, "Closing the socket, it was idle", 2),
        ("error", "FRM-93652", "WLS_FORMS", 3, 1, "The runtime process has terminated abnormally", 40),
        ("warning", "BEA-090078", "AdminServer", 2, 20, "Invalid login attempts, account locked", 300),
        ("error", "REP-50125", "WLS_REPORTS", 1, 5, "An exception occurred while running a report", 90),
    ]
    if sc == "rcu":
        ev.append(("error", "ORA-28000", "AdminServer", 3, 1, "The account is locked (RCU schema login, data source test)", 6))
    if sc in ("warn", "crit"):
        ev.append(("error", "BEA-002936", "WLS_FORMS", 3, 0.2, "Maximum thread constraint reached", 4))
    if crit:
        ev += [
            ("critical", "BEA-000337", "WLS_REPORTS", 4, 0.3, "Thread has been busy for longer than the stuck thread time", 3),
            ("critical", "BEA-000383", "WLS_REPORTS", 1, 0.4, "A critical service failed; the server will shut itself down", 25),
            ("error", "REP-56048", "WLS_REPORTS", 6, 0.2, "Engine crashed", 8),
            ("error", "FRM-92101", "WLS_FORMS", 9, 0.1, "Failure in the Forms server during startup", 2),
        ]
    rule_of = {"BEA-000449": "unclassified", "FRM-93652": "frm_abnormal", "BEA-090078": "wls_lockout",
               "REP-50125": "rep_exception", "BEA-002936": "thread_constraint", "BEA-000337": "stuck",
               "BEA-000383": "critical_service", "REP-56048": "rep_engine_crash", "FRM-92101": "frm_startup",
               "ORA-28000": "rcu_login"}
    events, tot = [], {"critical": 0, "error": 0, "warning": 0}
    for sev, code, srv, cnt, first_h, text, last_min in ev:
        events.append({"severity": sev, "code": code, "rule": rule_of.get(code, "unclassified"), "server": srv, "count": cnt,
                       "first_seen": iso(gen - int(first_h * 3600) - last_min * 60),
                       "last_seen": iso(gen - last_min * 60), "text": text})
        tot[sev] += cnt
    lv = "crit" if tot["critical"] else "warn" if tot["error"] else "ok"
    # hits per rule id, the ignored entries included (concept 4.3: nothing disappears silently)
    hits = {}
    for e in events:
        hits[e["rule"]] = hits.get(e["rule"], 0) + e["count"]
    rules = [
        {"id": "stuck", "type": "match", "level": "crit", "source": "wls", "hits": hits.get("stuck", 0), "reason": "stuck thread"},
        {"id": "critical_service", "type": "match", "level": "crit", "source": "wls", "hits": hits.get("critical_service", 0), "reason": "critical service failed"},
        {"id": "oom", "type": "match", "level": "crit", "source": "wls", "hits": 0, "reason": "heap exhausted"},
        {"id": "rep_engine_crash", "type": "match", "level": "crit", "source": "reports", "hits": hits.get("rep_engine_crash", 0), "reason": "Reports engine crashed"},
        {"id": "frm_abnormal", "type": "match", "level": "warn", "source": "forms", "hits": hits.get("frm_abnormal", 0), "reason": "Forms runtime ended abnormally"},
        {"id": "frm_startup", "type": "match", "level": "warn", "source": "forms", "hits": hits.get("frm_startup", 0), "reason": "Forms server start failure"},
        {"id": "thread_constraint", "type": "match", "level": "warn", "source": "wls", "hits": hits.get("thread_constraint", 0), "reason": "max thread constraint"},
        {"id": "rep_exception", "type": "match", "level": "warn", "source": "reports", "hits": hits.get("rep_exception", 0), "reason": "report failed"},
        {"id": "rep_login", "type": "match", "level": "warn", "source": "reports", "hits": 0, "reason": "failed Reports login (REP-50171, LDAP 49)"},
        {"id": "rcu_login", "type": "match", "level": "crit", "source": "wls", "hits": hits.get("rcu_login", 0), "reason": "RCU schema login refused (ORA-01017, ORA-28000, ORA-28001)"},
        {"id": "wls_lockout", "type": "match", "level": "warn", "source": "wls", "hits": hits.get("wls_lockout", 0), "reason": "account locked after invalid logins"},
        {"id": "unclassified", "type": "match", "level": "warn", "source": "*", "hits": hits.get("unclassified", 0), "reason": "<Error>/<Critical> without a rule"},
        {"id": "wls_noise_01", "type": "ignore", "level": "-", "source": "wls", "hits": 1284, "reason": "known harmless message (sample reference)"},
        {"id": "wls_noise_02", "type": "ignore", "level": "-", "source": "wls", "hits": 96, "reason": "known harmless message (sample reference)"},
    ]
    logs = {"schema": SCHEMA, "generated_at": iso(gen), "window": "24 h", "level": lv, "totals": tot,
            "ignored": 1284 + 96, "events": events, "rules": rules}
    return patch, security, logs


def build_hosts(out):
    """hosts.json for the overview page (written by 'wlsmon.py pull' on A).
    Demo: every host points to one of the scenario data sets."""
    demo_hosts = [
        ("wlsprod01", "GPIStudio", "prod", "frm_gpi_prod", "warn"),
        ("wlsprod02", "GPIStudio", "prod", "frm_gpi_prod", "normal"),
        ("wlsqs01", "GPIStudio", "qa", "frm_gpi_qs", "rcu"),
        ("wlsdev01", "GPIStudio", "dev", "frm_gpi_dev", "stale"),
        ("hrprod01", "HR Forms", "prod", "frm_hr_prod", "crit"),
        ("hrtest01", "HR Forms", "test", "frm_hr_test", "nginxdown"),
    ]
    hosts, ref = [], None
    for hid, product, env, domain, sc in demo_hosts:
        with open(os.path.join(out, "demo", sc, "now.json"), encoding="utf-8") as fh:
            now = json.load(fh)
        ref = now.get("demo_reference")
        m = {x["id"]: x for x in now["metrics"]}
        host_comp = next(c for c in now["components"] if c.get("type") == "host")

        def val(i):
            x = m.get(i, {})
            return x.get("value") if x.get("value") is not None else x.get("display")
        hosts.append({
            "id": hid, "name": hid, "product": product, "environment": env, "domain": domain,
            "level": now["overall"]["level"], "generated_at": now["generated_at"],
            "interval_sec": now["interval_sec"],
            "reasons": now["overall"]["reasons"][:3],
            "collector_errors": len(now["collector"].get("errors", [])),
            "summary": {"forms_sessions": val("forms_sessions"), "heap_forms_pct": val("heap_forms_pct"),
                        "load1": val("load1"), "cpu_pct": val("cpu_pct"), "since": host_comp.get("since")},
            "link": "host.html#demo-" + sc,      # demo only; real links: host.html?host=<id>
        })
    obj = {"schema": SCHEMA, "generated_at": ref, "interval_sec": INTERVAL, "hosts": hosts, "demo_reference": ref}
    write_atomic(os.path.join(out, "demo", "hosts.json"), obj)
    print("hosts.json (demo) written")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenario", choices=["normal", "warn", "crit", "nginxdown", "rcu", "stale"], default="warn")
    ap.add_argument("--all-scenarios", action="store_true",
                    help="write every scenario to <out>/demo/<scenario>/ (demo mode of the GUI)")
    ap.add_argument("--out", required=True, help="target directory (a scratch directory, not www/)")
    a = ap.parse_args()
    if a.all_scenarios:
        for sc in ("normal", "warn", "crit", "nginxdown", "rcu", "stale"):
            build(sc, os.path.join(a.out, "demo", sc))
        build_hosts(a.out)
    else:
        build(a.scenario, a.out)


def build(scenario, out):
    os.makedirs(out, exist_ok=True)

    now = int(time.time()) // INTERVAL * INTERVAL
    gen = now - 45 * 60 if scenario == "stale" else now
    sc = "warn" if scenario == "stale" else scenario

    day = series_file(gen, INTERVAL, 288, gen, sc, 0, "raw values per 5 min")
    week = series_file(gen, 3600, 168, gen // 3600 * 3600, sc, 10,
                       "per hour: maximum; log_errors/core_dumps/reports_jobs as sum")
    hist = series_file(gen, 43200, 730, gen // 43200 * 43200, sc, 20,
                       "per 12 h: maximum; mem_free_pct minimum; log_errors/core_dumps/reports_jobs as sum",
                       with_level=True)
    now_obj = now_file(gen, sc, day)

    # demo mode only: reference time the GUI computes the data age against
    for obj in (day, week, hist, now_obj):
        obj["demo_reference"] = iso(now)
    patch, security, logs = extras(gen, sc)
    for obj in (patch, security, logs):
        obj["demo_reference"] = iso(now)
    for name, obj in (("patch.json", patch), ("security.json", security), ("logs.json", logs)):
        write_atomic(os.path.join(out, name), obj)
    for name, obj in (("day.json", day), ("week.json", week), ("history.json", hist), ("now.json", now_obj)):
        write_atomic(os.path.join(out, name), obj)
    print("sample data (%s) written to %s" % (scenario, os.path.abspath(out)))


if __name__ == "__main__":
    main()
