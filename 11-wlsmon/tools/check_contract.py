#!/usr/bin/env python3
# =============================================================================
# Script   : check_contract.py
# Purpose  : Checks a directory against the wlsmon JSON contract (schema 1,
#            concept sections 3.1, 3.2 and 3.5): the 7 files now / day / week /
#            history / patch / security / logs, plus hosts.json when present.
#            The same check runs on the sample data (development step 1), on the
#            real output of the collector (step 7) and on the pulled data (P2).
# Call     : python3 -I tools/check_contract.py <dir> [--real] [--quiet]
#              --real   real collector output: "demo_reference" is a finding
# Exit     : 0 = contract ok, 1 = finding(s), 2 = usage / missing directory
# Needs    : python3 (3.6+), standard library only
# License  : Apache 2.0
# =============================================================================
import json
import numbers
import os
import re
import sys

SCHEMA = 1
LEVELS = ("ok", "warn", "crit")
ENVIRONMENTS = ("prod", "qa", "test", "dev")
SEVERITIES = ("critical", "error", "warning")
FILES = ("now", "day", "week", "history", "patch", "security", "logs")
SERIES_FILES = {"day": (300, 288), "week": (3600, 168), "history": (43200, 730)}
ISO_RE = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d(:\d\d(\.\d+)?)?([+-]\d\d:\d\d|Z)$")
# keys that could carry a raw log line - never allowed in logs.json
RAW_KEYS = ("line", "lines", "raw", "message", "msg", "excerpt", "stack")
MAX_TEXT = 200


class Checker(object):
    def __init__(self, real=False):
        self.real = real
        self.findings = []

    def add(self, fname, where, text):
        self.findings.append("%s.json: %s: %s" % (fname, where, text))

    # --- helpers --------------------------------------------------------------
    def need(self, fname, obj, keys, where="top"):
        ok = True
        if not isinstance(obj, dict):
            self.add(fname, where, "is not an object")
            return False
        for k in keys:
            if k not in obj:
                self.add(fname, where, "missing key '%s'" % k)
                ok = False
        return ok

    def level(self, fname, where, value, allowed=LEVELS):
        if value not in allowed:
            self.add(fname, where, "level %r not in %s" % (value, "|".join(allowed)))

    def iso(self, fname, where, value):
        if not isinstance(value, str) or not ISO_RE.match(value):
            self.add(fname, where, "not ISO 8601 with offset: %r" % (value,))

    def number_or_none(self, fname, where, value):
        if value is not None and (isinstance(value, bool)
                                  or not isinstance(value, numbers.Number)):
            self.add(fname, where, "value must be a plain number or null, got %r"
                     % (value,))

    def header(self, fname, obj):
        if not self.need(fname, obj, ("schema", "generated_at")):
            return
        if obj["schema"] != SCHEMA:
            self.add(fname, "schema", "expected %d, got %r" % (SCHEMA, obj["schema"]))
        self.iso(fname, "generated_at", obj["generated_at"])
        if self.real and "demo_reference" in obj:
            self.add(fname, "demo_reference", "only allowed in sample data")

    # --- now.json -------------------------------------------------------------
    def check_now(self, now, day_series):
        f = "now"
        self.header(f, now)
        if not self.need(f, now, ("interval_sec", "host", "domain", "product",
                                  "environment", "collector", "overall",
                                  "components", "metrics", "layout", "daily")):
            return
        if now["environment"] not in ENVIRONMENTS:
            self.add(f, "environment", "%r not in %s" % (now["environment"],
                                                       "|".join(ENVIRONMENTS)))
        col = now["collector"]
        if self.need(f, col, ("version", "duration_ms", "errors"), "collector"):
            for i, e in enumerate(col["errors"]):
                w = "collector.errors[%d]" % i
                if self.need(f, e, ("level", "text"), w):
                    self.level(f, w, e["level"])
        ov = now["overall"]
        if self.need(f, ov, ("level", "reasons"), "overall"):
            self.level(f, "overall.level", ov["level"])
            for i, r in enumerate(ov["reasons"]):
                w = "overall.reasons[%d]" % i
                if self.need(f, r, ("level", "text"), w):
                    self.level(f, w, r["level"])

        comps = now["components"]
        ids = {}
        hosts = 0
        for i, c in enumerate(comps):
            w = "components[%d]" % i
            if not self.need(f, c, ("id", "name", "state", "level"), w):
                continue
            if c["id"] in ids:
                self.add(f, w, "duplicate id %r" % c["id"])
            ids[c["id"]] = c
            self.level(f, w + ".level", c["level"])
            if c.get("type") == "host":
                hosts += 1
                if "since" in c:
                    self.iso(f, w + ".since", c["since"])
            if c.get("down") and c["level"] != "crit":
                self.add(f, w, "down component must be crit")
        if hosts != 1:
            self.add(f, "components", "exactly one component of type host expected, "
                     "found %d" % hosts)
        for c in comps:
            for r in c.get("requires", []):
                if r not in ids:
                    self.add(f, "components[%s].requires" % c.get("id"),
                             "unknown id %r" % r)
            if c.get("parent") and c["parent"] not in ids:
                self.add(f, "components[%s].parent" % c.get("id"),
                         "unknown id %r" % c["parent"])

        lay = now["layout"]
        groups = set()
        if self.need(f, lay, ("stages", "metric_groups"), "layout"):
            staged = []
            for stage in lay["stages"]:
                for cid in stage:
                    staged.append(cid)
                    if cid not in ids:
                        self.add(f, "layout.stages", "unknown id %r" % cid)
            for cid, c in ids.items():
                if c.get("type") == "host" or c.get("parent"):
                    continue
                n = staged.count(cid)
                if n != 1:
                    self.add(f, "layout.stages", "component %r staged %d times"
                             % (cid, n))
            for g in lay["metric_groups"]:
                if self.need(f, g, ("id", "title"), "layout.metric_groups"):
                    groups.add(g["id"])

        mids = set()
        for i, m in enumerate(now["metrics"]):
            w = "metrics[%s]" % (m.get("id", i) if isinstance(m, dict) else i)
            if not self.need(f, m, ("id", "group", "label", "level"), w):
                continue
            if m["id"] in mids:
                self.add(f, w, "duplicate id")
            mids.add(m["id"])
            self.level(f, w + ".level", m["level"])
            if m["group"] not in groups:
                self.add(f, w, "group %r not in layout.metric_groups" % m["group"])
            self.number_or_none(f, w + ".value", m.get("value"))
            if m.get("value") is None and not isinstance(m.get("display"), str):
                self.add(f, w, "value null needs a display text")
            if "decimals" in m and not isinstance(m["decimals"], int):
                self.add(f, w, "decimals must be an integer")
            s = m.get("series")
            if s is not None and day_series is not None and s not in day_series:
                self.add(f, w, "series %r not in day.json" % s)
            for j, it in enumerate(m.get("items", [])):
                iw = "%s.items[%d]" % (w, j)
                if self.need(f, it, ("name", "level"), iw):
                    self.level(f, iw, it["level"])
                    self.number_or_none(f, iw + ".value", it.get("value"))

        d = now["daily"]
        if self.need(f, d, ("generated_at", "facts"), "daily"):
            self.iso(f, "daily.generated_at", d["generated_at"])
            for i, fa in enumerate(d["facts"]):
                w = "daily.facts[%d]" % i
                if self.need(f, fa, ("id", "label", "level"), w):
                    self.level(f, w, fa["level"])
                    self.number_or_none(f, w + ".value", fa.get("value"))

    # --- day / week / history -------------------------------------------------
    def check_series(self, fname, obj):
        self.header(fname, obj)
        if not self.need(fname, obj, ("resolution_sec", "series", "thresholds")):
            return None
        res, maxlen = SERIES_FILES[fname]
        if obj["resolution_sec"] != res:
            self.add(fname, "resolution_sec", "expected %d, got %r"
                     % (res, obj["resolution_sec"]))
        for k, v in obj["thresholds"].items():
            if not (isinstance(v, list) and len(v) == 2
                    and all(isinstance(x, numbers.Number) for x in v)):
                self.add(fname, "thresholds." + k, "must be [warn, crit]")
        ser = obj["series"]
        if not self.need(fname, ser, ("ts",), "series"):
            return None
        n = len(ser["ts"])
        if n > maxlen:
            self.add(fname, "series.ts", "%d points, at most %d" % (n, maxlen))
        if any(not isinstance(t, int) for t in ser["ts"]):
            self.add(fname, "series.ts", "epoch seconds (integers) expected")
        elif ser["ts"] != sorted(ser["ts"]):
            self.add(fname, "series.ts", "not ascending")
        for k, vals in ser.items():
            if not isinstance(vals, list):
                self.add(fname, "series." + k, "not a list")
                continue
            if len(vals) != n:
                self.add(fname, "series." + k, "%d values, ts has %d" % (len(vals), n))
            if k == "level":
                for v in vals:
                    if v not in LEVELS and v is not None:
                        self.add(fname, "series.level", "invalid level %r" % (v,))
                        break
            elif k != "ts":
                for v in vals:
                    if v is not None and (isinstance(v, bool)
                                          or not isinstance(v, numbers.Number)):
                        self.add(fname, "series." + k, "non-number %r" % (v,))
                        break
        if fname == "history" and "level" not in ser:
            self.add(fname, "series", "history needs series.level")
        return ser

    # --- patch / security / logs ----------------------------------------------
    def check_patch(self, obj):
        f = "patch"
        self.header(f, obj)
        if not self.need(f, obj, ("level", "baseline", "components", "patches")):
            return
        self.level(f, "level", obj["level"])
        self.need(f, obj["baseline"], ("cpu", "installed"), "baseline")
        for i, c in enumerate(obj["components"]):
            w = "components[%d]" % i
            if self.need(f, c, ("name", "version", "patch_level", "level"), w):
                self.level(f, w, c["level"])
                if c.get("applied"):
                    self.iso(f, w + ".applied", c["applied"])
        for i, p in enumerate(obj["patches"]):
            self.need(f, p, ("id", "description", "home"), "patches[%d]" % i)

    def check_security(self, obj):
        f = "security"
        self.header(f, obj)
        if not self.need(f, obj, ("level", "checks")):
            return
        self.level(f, "level", obj["level"])
        seen = set()
        for i, c in enumerate(obj["checks"]):
            w = "checks[%d]" % i
            if self.need(f, c, ("id", "area", "name", "result", "level", "hint"), w):
                self.level(f, w, c["level"])
                if c["id"] in seen:
                    self.add(f, w, "duplicate id %r" % c["id"])
                seen.add(c["id"])
                if c["level"] != "ok" and not c["hint"]:
                    self.add(f, w, "a warn / crit check needs a hint")

    def check_logs(self, obj):
        f = "logs"
        self.header(f, obj)
        if not self.need(f, obj, ("level", "totals", "ignored", "events", "rules")):
            return
        self.level(f, "level", obj["level"])
        self.need(f, obj["totals"], SEVERITIES, "totals")
        if not isinstance(obj["ignored"], int):
            self.add(f, "ignored", "count (integer) expected")
        for i, e in enumerate(obj["events"]):
            w = "events[%d]" % i
            if not self.need(f, e, ("severity", "code", "rule", "server", "count",
                                    "first_seen", "last_seen", "text"), w):
                continue
            if e["severity"] not in SEVERITIES:
                self.add(f, w, "severity %r" % e["severity"])
            if not isinstance(e["count"], int):
                self.add(f, w, "count must be an integer")
            self.iso(f, w + ".first_seen", e["first_seen"])
            self.iso(f, w + ".last_seen", e["last_seen"])
            if len(e["text"]) > MAX_TEXT or "\n" in e["text"]:
                self.add(f, w, "text longer than %d characters or multi-line - "
                         "short text per code only, never a log line" % MAX_TEXT)
            for k in e:
                if k in RAW_KEYS:
                    self.add(f, w, "key %r could carry a raw log line" % k)
        for i, r in enumerate(obj["rules"]):
            w = "rules[%d]" % i
            if not self.need(f, r, ("id", "type", "level", "source", "hits", "reason"), w):
                continue
            if r["type"] not in ("match", "ignore"):
                self.add(f, w, "type %r" % r["type"])
            elif r["type"] == "match":
                self.level(f, w, r["level"])
            if r["type"] == "ignore" and not r["reason"]:
                self.add(f, w, "ignore rule without a reason")
            if not isinstance(r["hits"], int):
                self.add(f, w, "hits must be an integer")

    # --- hosts.json (GUI host) ------------------------------------------------
    def check_hosts(self, obj):
        f = "hosts"
        self.header(f, obj)
        if not self.need(f, obj, ("interval_sec", "hosts")):
            return
        for i, h in enumerate(obj["hosts"]):
            w = "hosts[%d]" % i
            if not self.need(f, h, ("id", "name", "product", "environment", "domain",
                                    "level", "generated_at", "interval_sec",
                                    "reasons", "collector_errors", "summary"), w):
                continue
            self.level(f, w, h["level"])
            self.iso(f, w + ".generated_at", h["generated_at"])
            if h["environment"] not in ENVIRONMENTS:
                self.add(f, w, "environment %r" % h["environment"])
            if len(h["reasons"]) > 3:
                self.add(f, w, "at most 3 reasons")
            if not re.match(r"^[A-Za-z0-9._-]+$", h["id"]):
                self.add(f, w, "id must be a plain host name (used in the URL)")


def load(path, fname, chk):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except ValueError as exc:
        chk.add(fname, "parse", str(exc))
    return None


def check_dir(directory, real=False):
    """Return the list of findings for one data directory."""
    chk = Checker(real=real)
    data = {}
    for name in FILES:
        p = os.path.join(directory, name + ".json")
        if not os.path.isfile(p):
            chk.add(name, "file", "missing")
            continue
        data[name] = load(p, name, chk)
    day_series = None
    for name in ("day", "week", "history"):
        if data.get(name) is not None:
            ser = chk.check_series(name, data[name])
            if name == "day":
                day_series = ser
    if data.get("now") is not None:
        chk.check_now(data["now"], day_series)
    if data.get("patch") is not None:
        chk.check_patch(data["patch"])
    if data.get("security") is not None:
        chk.check_security(data["security"])
    if data.get("logs") is not None:
        chk.check_logs(data["logs"])
    hp = os.path.join(directory, "hosts.json")
    if os.path.isfile(hp):
        obj = load(hp, "hosts", chk)
        if obj is not None:
            chk.check_hosts(obj)
    return chk.findings


def check_hosts_file(path, real=False):
    chk = Checker(real=real)
    obj = load(path, "hosts", chk)
    if obj is not None:
        chk.check_hosts(obj)
    return chk.findings


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    real = "--real" in argv
    quiet = "--quiet" in argv
    if len(args) != 1 or not os.path.isdir(args[0]):
        print("usage: check_contract.py <dir> [--real] [--quiet]", file=sys.stderr)
        return 2
    findings = check_dir(args[0], real=real)
    for line in findings:
        print("FAIL  " + line)
    if not quiet or findings:
        print("%s  %s: %d finding(s)" % ("OK  " if not findings else "FAIL",
                                         args[0], len(findings)))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
