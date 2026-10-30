#!/bin/bash
# =============================================================================
# Script   : cve_watch.sh
# Purpose  : CVE watch step 2 – early warning between the Oracle releases
#            (read-only, never downloads or applies a patch). Reads the
#            inventory.json of cve_inventory.sh (products, versions, JDKs,
#            third-party jars – no host data) and checks it against:
#              - Oracle Security Alerts page: new CPU / CSPU / Security Alert
#                after the applied cycle (alerts also by revision)
#              - NVD API 2.0: all CVEs of the CNA Oracle (secalert_us@oracle.com)
#                since the last run, matched by the CNA "affected" product +
#                version – works on release day, no need to wait for the CPE
#              - OSV.dev: third-party jars in the Oracle Home (Spring, jackson,
#                Bouncy Castle …) – public long before Oracle ships the fix
#              - CISA KEV: known exploited -> CRIT; EPSS: exploit probability
#              - heise security feed: press / exploit reports (keyword filter)
#            Alerts only on NEW findings (state in reports/cve_watch_state.json);
#            the first run is the baseline. WARN / CRIT also go to the journal
#            (logger -t ihw-cve). Runs on any host with internet and a copied
#            inventory.json – environment.conf is not needed (customer hosts
#            without egress: inventory there, watch on the admin / share host).
# Call     : ./10-Monitoring/cve_watch.sh [--inventory FILE] [--with-inventory]
#                [--since DAYS] [--sources LIST] [--no-epss]
#                [--offline DIR | --save-fixtures DIR] [--reset]
#            ./10-Monitoring/cve_watch.sh --cron [--remove] [--apply]
#              --inventory F     inventory.json (default: newest
#                                10-Monitoring/reports/inventory_*.json)
#              --with-inventory  run cve_inventory.sh --no-os first (needs
#                                environment.conf – the server itself)
#              --since DAYS      NVD window on the first run (default 119,
#                                API limit 120); later: since the last run
#              --sources LIST    oracle,nvd,osv,kev,heise (default: all)
#              --no-epss         no EPSS lookup
#              --offline DIR     read the sources from saved files (self-test)
#              --save-fixtures D save the downloaded sources to D
#              --state-dir DIR   state, report, cve_seen.csv, cve_accepted.txt
#                                (default 10-Monitoring/reports) – one per
#                                watched installation / customer inventory
#              --reset           forget the state (next run = new baseline)
#              --cron            crontab line (daily 07:10), --apply installs
# Config   : environment (optional): NVD_API_KEY (50 instead of 5 requests /
#            30 s), CVE_MIN_CVSS (7.0), CVE_CRIT_CVSS (9.0),
#            CVE_EXPOSED_PROTOCOLS ("HTTP HTTPS"), https_proxy;
#            accepted CVEs: 10-Monitoring/reports/cve_accepted.txt
#            (CVE;reason;date – reported as INFO)
# Output   : console + log, 10-Monitoring/reports/cve_watch_<date>.md
#            (SEVERITY block), reports/cve_seen.csv, reports/cve_watch_state.json
# Exit     : 0 nothing new >= WARN, 1 new WARN / a source failed, 2 new CRIT
#            or error
# Doc      : 10-Monitoring/README.md, section "CVE Watch"
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"

if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m Cannot find IHateWeblogic_lib.sh: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"
# environment.conf is optional here: the watcher also runs on a host without
# the FMW installation (copied inventory.json)
# shellcheck source=../environment.conf
[ -f "$ENV_CONF" ] && source "$ENV_CONF"

init_log

# =============================================================================
# Arguments
# =============================================================================
REPORT_DIR="$SCRIPT_DIR/reports"
INVENTORY=""; WITH_INV=false; SINCE=119; SOURCES="oracle,nvd,osv,kev,heise"
EPSS=true; OFFLINE=""; SAVE_FIX=""; RESET=false; STATE_DIR=""

CRON=false; APPLY=false; REMOVE=false

_usage() {
    sed -n '2,53p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}
while [ $# -gt 0 ]; do
    case "$1" in
        --inventory)      INVENTORY="${2:?--inventory needs a file}"; shift ;;
        --with-inventory) WITH_INV=true ;;
        --since)          SINCE="${2:?--since needs days}"; shift ;;
        --sources)        SOURCES="${2:?--sources needs a list}"; shift ;;
        --no-epss)        EPSS=false ;;
        --offline)        OFFLINE="${2:?--offline needs a directory}"; shift ;;
        --save-fixtures)  SAVE_FIX="${2:?--save-fixtures needs a directory}"; shift ;;
        --state-dir)      STATE_DIR="${2:?--state-dir needs a directory}"; shift ;;
        --reset)          RESET=true ;;
        --cron)           CRON=true ;;
        --apply)          APPLY=true ;;
        --remove)         REMOVE=true ;;
        --help|-h)        _usage ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 2 ;;
    esac
    shift
done
[[ "$SINCE" =~ ^[0-9]+$ ]] && [ "$SINCE" -ge 1 ] && [ "$SINCE" -le 119 ] \
    || { fail "--since: 1..119 days (NVD API limit 120)"; print_summary; exit 2; }

# =============================================================================
# --cron: show / install / remove the crontab line (pattern of cert_expiry_check.sh)
# =============================================================================
MARK="# IHW cve_watch"
_cron_args=""; [ -f "$ENV_CONF" ] && _cron_args=" --with-inventory"
CRON_LINE="10 7 * * * $SCRIPT_DIR/$(basename "$0")$_cron_args >/dev/null 2>&1 $MARK"
if $CRON; then
    section "Crontab of $(id -un)"
    _cur="$(crontab -l 2>/dev/null)"
    if printf '%s\n' "$_cur" | grep -qF "$MARK"; then
        ok "installed: $(printf '%s\n' "$_cur" | grep -F "$MARK")"; _have=true
    else
        info "not installed"; _have=false
    fi
    if ! $APPLY; then
        info "line: $CRON_LINE"
        $REMOVE && info "Dry-run – --cron --remove --apply removes it" \
                || info "Dry-run – --cron --apply installs it"
    elif $REMOVE; then
        $_have && { printf '%s\n' "$_cur" | grep -vF "$MARK" | crontab - && ok "removed"; } || info "nothing to remove"
    elif $_have; then
        printf '%s\n' "$_cur" | grep -vF "$MARK" | { cat; printf '%s\n' "$CRON_LINE"; } | crontab - \
            && ok "updated: $CRON_LINE"
    else
        { [ -n "$_cur" ] && printf '%s\n' "$_cur"; printf '%s\n' "$CRON_LINE"; } | crontab - \
            && ok "installed: $CRON_LINE"
    fi
    unset _cur _have
    print_summary
    exit "$EXIT_CODE"
fi

# =============================================================================
# Inventory
# =============================================================================
mkdir -p "$REPORT_DIR"
if $WITH_INV; then
    [ -f "$ENV_CONF" ] || { fail "--with-inventory needs environment.conf (run it on the server)"; print_summary; exit 2; }
    INVENTORY="$REPORT_DIR/inventory_$(date +%Y%m%d).json"
    info "Running cve_inventory.sh --no-os --json $INVENTORY ..."
    "$SCRIPT_DIR/cve_inventory.sh" --no-os --json "$INVENTORY" > /dev/null 2>&1
    [ -f "$INVENTORY" ] || { fail "cve_inventory.sh wrote no inventory"; print_summary; exit 2; }
fi
[ -z "$INVENTORY" ] && INVENTORY="$(ls -1 "$REPORT_DIR"/inventory_*.json 2>/dev/null | sort | tail -1)"
if [ -z "$INVENTORY" ] || [ ! -f "$INVENTORY" ]; then
    fail "No inventory.json – run 10-Monitoring/cve_inventory.sh first (or --inventory FILE)"
    print_summary; exit 2
fi

# offline (self-test) keeps the state only with an explicit --state-dir
SAVE_STATE=true; [ -n "$OFFLINE" ] && [ -z "$STATE_DIR" ] && SAVE_STATE=false
STATE_DIR="${STATE_DIR:-$REPORT_DIR}"
mkdir -p "$STATE_DIR" || { fail "Cannot create $STATE_DIR"; print_summary; exit 2; }
STATE="$STATE_DIR/cve_watch_state.json"
if $RESET && [ -f "$STATE" ]; then
    mv -f "$STATE" "$STATE.bak_$(date +%Y%m%d_%H%M%S)" && info "State reset – this run is the new baseline"
fi
REPORT_MD="$STATE_DIR/cve_watch_$(date +%Y%m%d).md"

printLine
section "CVE watch – $(date '+%Y-%m-%d %H:%M:%S')"
printList "Inventory" 14 "$INVENTORY ($(date -r "$INVENTORY" '+%Y-%m-%d %H:%M'))"
printList "Sources"   14 "$SOURCES$($EPSS && printf ' + EPSS')"
[ -n "$OFFLINE" ] && printList "Offline" 14 "$OFFLINE"
printList "State"     14 "$STATE"
_age=$(( ( $(date +%s) - $(date -r "$INVENTORY" +%s) ) / 86400 ))
[ "$_age" -gt 7 ] && warn "Inventory is $_age days old – refresh it (cve_inventory.sh) so new patches / JDKs count"
printLine

# =============================================================================
# The watch itself (python: fetch, match, state, report) – prints
# "LEVEL<TAB>text" lines, the last one "RC<TAB>n"
# =============================================================================
_out="$(mktemp)"
CVE_MIN_CVSS="${CVE_MIN_CVSS:-7.0}" CVE_CRIT_CVSS="${CVE_CRIT_CVSS:-9.0}" \
CVE_EXPOSED_PROTOCOLS="${CVE_EXPOSED_PROTOCOLS:-HTTP HTTPS}" NVD_API_KEY="${NVD_API_KEY:-}" \
python3 -I - "$INVENTORY" "$STATE" "$REPORT_MD" "$SINCE" "$SOURCES" "$EPSS" \
    "${OFFLINE:-}" "${SAVE_FIX:-}" "$STATE_DIR/cve_accepted.txt" "$STATE_DIR/cve_seen.csv" "$SAVE_STATE" \
    > "$_out" 2>&1 <<'PYEOF'
import json, os, re, sys, time, math, datetime, urllib.request, urllib.parse
import xml.etree.ElementTree as ET

(inv_f, state_f, report_f, since_days, sources, use_epss, offline, save_fix,
 accepted_f, seen_csv, save_state) = sys.argv[1:12]
SOURCES = set(s.strip() for s in sources.split(",") if s.strip())
USE_EPSS = use_epss == "true"
MIN_CVSS = float(os.environ.get("CVE_MIN_CVSS", "7.0"))
CRIT_CVSS = float(os.environ.get("CVE_CRIT_CVSS", "9.0"))
EXPOSED = set(os.environ.get("CVE_EXPOSED_PROTOCOLS", "HTTP HTTPS").upper().split())
NVD_KEY = os.environ.get("NVD_API_KEY", "")
NOW = datetime.datetime.now(datetime.timezone.utc)
TODAY = NOW.date().isoformat()
UA = "Mozilla/5.0 (IHateWeblogic cve_watch)"
LEVELS = {"INFO": 0, "WARN": 1, "CRIT": 2}

def out(level, text): print("%s\t%s" % (level, text), flush=True)

# --- fetch (online / offline fixtures) ---------------------------------------
_fix_n = {}
def fetch(key, url, data=None, headers=None, timeout=90):
    """key = fixture name; returns bytes or raises"""
    if offline:
        n = _fix_n.get(key, 0); _fix_n[key] = n + 1
        p = os.path.join(offline, "%s%s" % (key, "" if n == 0 else "_%d" % n))
        with open(p, "rb") as f:
            return f.read()
    h = {"User-Agent": UA}
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, headers=h)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = r.read()
    if save_fix:
        os.makedirs(save_fix, exist_ok=True)
        n = _fix_n.get(key, 0); _fix_n[key] = n + 1
        with open(os.path.join(save_fix, "%s%s" % (key, "" if n == 0 else "_%d" % n)), "wb") as f:
            f.write(body)
    return body

SRC_STATE = {}   # source -> "ok …" / "FAILED …"

# --- CVSS 3.x base score from the vector --------------------------------------
def cvss3(vec):
    try:
        m = dict(x.split(":") for x in vec.split("/")[1:])
        S = m["S"] == "C"
        AV = {"N": .85, "A": .62, "L": .55, "P": .2}[m["AV"]]
        AC = {"L": .77, "H": .44}[m["AC"]]
        PR = {"N": .85, "L": .68 if S else .62, "H": .5 if S else .27}[m["PR"]]
        UI = {"N": .85, "R": .62}[m["UI"]]
        C, I, A = ({"H": .56, "L": .22, "N": 0}[m[k]] for k in ("C", "I", "A"))
    except Exception:
        return None
    iss = 1 - (1 - C) * (1 - I) * (1 - A)
    imp = 7.52 * (iss - 0.029) - 3.25 * (iss - 0.02) ** 15 if S else 6.42 * iss
    if imp <= 0:
        return 0.0
    exp = 8.22 * AV * AC * PR * UI
    x = min(1.08 * (imp + exp), 10) if S else min(imp + exp, 10)
    i = round(x * 100000)
    return i / 100000.0 if i % 10000 == 0 else (math.floor(i / 10000) + 1) / 10.0

def remote_noauth(vec):
    return bool(vec) and "AV:N" in vec and "PR:N" in vec

# --- inventory -----------------------------------------------------------------
inv = json.load(open(inv_f, encoding="utf-8"))
cycle = inv.get("patch_cycle") or {}
CYCLE_NAME = cycle.get("name") or "?"
CYCLE_DATE = cycle.get("release_date") or ""
# inventory product -> CNA product names (NVD "affected") – as seen in the
# CPU Jul–Oct 2026 records
PRODUCT_MAP = {
    "Oracle WebLogic Server": ["Oracle WebLogic Server"],
    "Oracle Fusion Middleware (JRF / Infrastructure)": [
        "Oracle Middleware Common Libraries and Tools", "Oracle JDeveloper",
        "Oracle Web Services Manager", "Oracle Fusion Middleware Control",
        "Oracle Fusion Middleware"],
    "Oracle Platform Security for Java": ["Oracle Platform Security for Java"],
    "Oracle Coherence": ["Oracle Coherence"],
    "Oracle Forms": ["Oracle Forms"],
    "Oracle Reports": ["Oracle Reports Developer", "Oracle Reports"],
    "Oracle HTTP Server": ["Oracle HTTP Server"],
    "Oracle Access Manager WebGate": ["Oracle Access Manager WebGate", "Oracle WebGate"],
}
INSTALLED = {}   # CNA product -> set(version)
for p in inv.get("products", []):
    for cna in PRODUCT_MAP.get(p.get("product"), []):
        INSTALLED.setdefault(cna, set()).add(p.get("version", ""))
JAVAS = [(j.get("home"), j.get("version", "")) for j in inv.get("java", []) if j.get("version")]
JARS = inv.get("jars", [])

def vtuple(v):
    v = v.strip()
    m = re.match(r"^1\.8\.0_(\d+)|^8u(\d+)", v)
    if m:
        return (8, 0, int(m.group(1) or m.group(2)))
    return tuple(int(x) for x in re.findall(r"\d+", v)[:5])

def java_affected(installed, listed):
    a, b = vtuple(installed), vtuple(listed)
    if not a or not b or a[0] != b[0]:
        return False
    n = max(len(a), len(b))
    return a + (0,) * (n - len(a)) <= b + (0,) * (n - len(b))

# --- accepted / state ----------------------------------------------------------
ACCEPTED = {}
if os.path.exists(accepted_f):
    for l in open(accepted_f, encoding="utf-8"):
        l = l.strip()
        if l and not l.startswith("#"):
            f = (l.split(";") + ["", ""])[:3]
            ACCEPTED[f[0].strip()] = "%s (%s)" % (f[1].strip(), f[2].strip())
try:
    STATE = json.load(open(state_f, encoding="utf-8"))
except Exception:
    STATE = {}
BASELINE = not STATE.get("last_run")
SEEN = STATE.setdefault("seen", {})
OSV_CACHE = STATE.setdefault("osv_cache", {})
HEISE_SEEN = set(STATE.setdefault("heise_seen", []))

# --- findings ------------------------------------------------------------------
FINDINGS = {}    # key -> dict
def add(key, **f):
    f.setdefault("kev", False); f.setdefault("epss", None)
    f.setdefault("cvss", None); f.setdefault("vector", "")
    f.setdefault("note", ""); f.setdefault("link", "")
    FINDINGS[key] = f

def level_of(f):
    # info_only first: an Oracle Security Alert / KEV entry for a product we do
    # not have stays INFO even when it is exploited
    if f.get("accepted") or f.get("info_only"):
        return "INFO"
    if f["kev"] and not f.get("covered"):
        return "CRIT"
    if f.get("covered") or f.get("vendor_build"):
        return "INFO"
    s = f["cvss"] or 0
    if f["source"] == "oracle" and s >= CRIT_CVSS and remote_noauth(f["vector"]) \
            and (f.get("protocol", "").upper() in EXPOSED or not f.get("protocol")):
        return "CRIT"
    return "WARN" if s >= MIN_CVSS else "INFO"

# =============================================================================
# 1. Oracle Security Alerts page
# =============================================================================
ALERT_CVES = []
if "oracle" in SOURCES:
    out("SECTION", "Oracle security advisories after %s (%s)" % (CYCLE_NAME, CYCLE_DATE or "?"))
    try:
        html = fetch("oracle_index.html", "https://www.oracle.com/security-alerts/").decode("utf-8", "replace")
        text = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", html))
        mon = {m: i for i, m in enumerate(["jan", "feb", "mar", "apr", "may", "jun", "jul",
                                           "aug", "sep", "oct", "nov", "dec"], 1)}
        n_new = 0
        for a in sorted(set(re.findall(r"c(?:s)?pu[a-z]{3}\d{4}\.html", html))):
            name = a[:-5]; typ = "CSPU" if name.startswith("cspu") else "CPU"
            mm = mon.get(name[-7:-4]); yy = int(name[-4:])
            if not mm:
                continue
            d1 = datetime.date(yy, mm, 1)
            rel = d1 + datetime.timedelta(days=(1 - d1.weekday()) % 7 + 14)   # third Tuesday
            if CYCLE_DATE and rel.isoformat() <= CYCLE_DATE:
                continue
            state = "announced" if rel.isoformat() > TODAY else "released"
            key = "advisory:%s" % name
            add(key, source="oracle-advisory", cve="", product=typ, version=name,
                cvss=None, published=rel.isoformat(), covered=False, info_only=(state == "announced"),
                note="%s %s %s – NOT covered by %s" % (typ, name, state, CYCLE_NAME),
                link="https://www.oracle.com/security-alerts/" + a)
            if state == "released":
                FINDINGS[key]["cvss"] = MIN_CVSS   # a released, unapplied cycle is at least WARN
                n_new += 1
        for cve, rev, dt in re.findall(r"Alert for (CVE-\d{4}-\d+) Rev (\d+), (\d{1,2} \w+ \d{4})", text):
            try:
                d = datetime.datetime.strptime(dt, "%d %B %Y").date().isoformat()
            except ValueError:
                continue
            if CYCLE_DATE and d < CYCLE_DATE:
                continue
            ALERT_CVES.append((cve, rev, d))
        SRC_STATE["oracle"] = "ok – %d newer CPU/CSPU, %d Security Alert(s) since %s" % (n_new, len(ALERT_CVES), CYCLE_DATE)
    except Exception as e:
        SRC_STATE["oracle"] = "FAILED (%s)" % e

# =============================================================================
# 2. NVD – Oracle CNA records (+ the Security Alert CVEs)
# =============================================================================
def nvd_get(params, key):
    hdr = {"apiKey": NVD_KEY} if NVD_KEY else {}
    url = "https://services.nvd.nist.gov/rest/json/cves/2.0?" + urllib.parse.urlencode(params)
    for attempt in range(3):
        try:
            return json.loads(fetch(key, url, headers=hdr, timeout=120))
        except urllib.error.HTTPError as e:
            if e.code in (403, 429, 503) and attempt < 2 and not offline:
                time.sleep(30)
                continue
            raise
    return {}

def nvd_sleep():
    if not offline:
        time.sleep(0.7 if NVD_KEY else 6.5)

# NVD is read incrementally (since the last run) – the records of our product
# families are kept in the state and re-matched on every run against the
# CURRENT inventory (a JDK upgrade / a newer applied cycle clears them)
NVD_KEEP = STATE.setdefault("nvd_records", {})
RELEVANT = {n for names in PRODUCT_MAP.values() for n in names}
def keep_record(c, via):
    prods = {x.get("product", "") for b in c.get("affected", []) for x in b.get("affectedData", [])}
    if not any(p in RELEVANT or p.startswith("Oracle Java SE") for p in prods):
        return
    m = {}
    for mk in ("cvssMetricV31", "cvssMetricV30"):
        if c.get("metrics", {}).get(mk):
            m = {mk: c["metrics"][mk][:1]}
            break
    NVD_KEEP[c["id"]] = {"id": c["id"], "published": c.get("published", ""), "via": via, "metrics": m,
                         "descriptions": [d for d in c.get("descriptions", []) if d.get("lang") == "en"][:1],
                         "affected": c.get("affected", [])}

def oracle_record(c, via):
    """match one NVD record of the CNA Oracle against the inventory"""
    cid = c["id"]
    desc = next((d["value"] for d in c.get("descriptions", []) if d.get("lang") == "en"), "")
    vec, score = "", None
    for mk in ("cvssMetricV31", "cvssMetricV30"):
        for m in c.get("metrics", {}).get(mk, []):
            vec = m["cvssData"].get("vectorString", ""); score = m["cvssData"].get("baseScore")
            break
        if vec:
            break
    if not vec:
        mv = re.search(r"\(CVSS:3\.\d/[^)]+\)", desc)
        if mv:
            vec = mv.group(0).strip("()"); score = cvss3(vec)
    proto = (re.search(r"network access via ([A-Za-z0-9 ,/]+?) to compromise", desc) or [None, ""])[1]
    pub = c.get("published", "")[:10]
    hits = []
    for b in c.get("affected", []):
        for x in b.get("affectedData", []):
            for v in x.get("versions", []):
                if v.get("status", "affected") != "affected":
                    continue
                prod, ver = x.get("product", ""), v.get("version", "")
                if ":" in ver:            # "Oracle Java SE:21.0.12" in combined records
                    prod, ver = ver.split(":", 1)
                if prod == "Oracle Java SE" or prod.startswith("Oracle Java SE"):
                    for home, jv in JAVAS:
                        if java_affected(jv, ver):
                            hits.append(("Oracle Java SE (%s)" % home, jv, False))
                elif ver in INSTALLED.get(prod, ()):
                    covered = bool(CYCLE_DATE) and pub <= CYCLE_DATE
                    hits.append((prod, ver, covered))
    for prod, ver, covered in hits:
        key = "oracle:%s:%s" % (cid, prod)
        add(key, source="oracle", cve=cid, product=prod, version=ver, cvss=score, vector=vec,
            protocol=proto.split(",")[0].strip() if proto else "", published=pub, covered=covered,
            note=("covered by the applied cycle %s" % CYCLE_NAME) if covered else via,
            link="https://nvd.nist.gov/vuln/detail/" + cid)
    return bool(hits)

if "nvd" in SOURCES:
    out("SECTION", "NVD – CVEs of the CNA Oracle, matched by product + version")
    try:
        last = STATE.get("nvd_last")
        start = (datetime.datetime.fromisoformat(last) - datetime.timedelta(days=2)) if last \
            else NOW - datetime.timedelta(days=int(since_days))
        start = max(start, NOW - datetime.timedelta(days=119))
        params = {"sourceIdentifier": "secalert_us@oracle.com",
                  "pubStartDate": start.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                  "pubEndDate": NOW.strftime("%Y-%m-%dT%H:%M:%S.000Z"), "resultsPerPage": 2000}
        total, idx, n_rec, n_hit = None, 0, 0, 0
        while total is None or idx < total:
            params["startIndex"] = idx
            d = nvd_get(params, "nvd_oracle.json")
            total = d.get("totalResults", 0)
            vulns = d.get("vulnerabilities", [])
            for v in vulns:
                n_rec += 1
                keep_record(v["cve"], "Oracle CNA record (%s)" % v["cve"].get("published", "")[:10])
            idx += len(vulns)
            if not vulns:
                break
            if idx < total:
                nvd_sleep()
        for cve, rev, d in ALERT_CVES:
            nvd_sleep()
            r = nvd_get({"cveId": cve}, "nvd_alert.json")
            matched, prods = False, []
            for v in r.get("vulnerabilities", []):
                keep_record(v["cve"], "Oracle Security Alert %s Rev %s (%s)" % (cve, rev, d))
                matched = oracle_record(v["cve"], "Oracle Security Alert %s Rev %s (%s)" % (cve, rev, d)) or matched
                prods += [x.get("product", "") for b in v["cve"].get("affected", []) for x in b.get("affectedData", [])]
            # the alert itself is INFO – a match is reported as its own NVD finding
            add("alert:%s:%s" % (cve, rev), source="oracle-advisory", cve=cve, product="Security Alert",
                version="Rev " + rev, published=d, covered=False, info_only=True,
                note="%s (%s): %s – %s" % ("Security Alert Rev " + rev, d, ", ".join(sorted(set(prods)))[:80] or "?",
                                           "affects an installed product" if matched else "not installed / version not affected"),
                link="https://www.oracle.com/security-alerts/alert-%s.html" % cve.lower())
        # re-match every kept record (this window + earlier runs), drop records > 400 days
        cutoff = (NOW - datetime.timedelta(days=400)).date().isoformat()
        for cid in list(NVD_KEEP):
            if NVD_KEEP[cid]["published"][:10] < cutoff:
                del NVD_KEEP[cid]
                continue
            n_hit += oracle_record(NVD_KEEP[cid], NVD_KEEP[cid]["via"])
        SRC_STATE["nvd"] = "ok – %d Oracle records since %s; %d kept for our products, %d match the inventory" % (
            n_rec, start.date(), len(NVD_KEEP), n_hit)
        STATE["nvd_last"] = NOW.isoformat()
    except Exception as e:
        SRC_STATE["nvd"] = "FAILED (%s)" % e

# =============================================================================
# 3. OSV.dev – third-party jars
# =============================================================================
def vendor_build(v):
    return bool(re.search(r"INTERNAL|[Oo]racle|redhat", v)) or len(re.findall(r"\d+", v)) >= 5

if "osv" in SOURCES and JARS:
    out("SECTION", "OSV.dev – %d third-party library versions in the Oracle Home" % len(JARS))
    try:
        n_vuln = 0
        for i in range(0, len(JARS), 500):
            chunk = JARS[i:i + 500]
            q = {"queries": [{"package": {"ecosystem": "Maven", "name": j["coord"]}, "version": j["version"]}
                             for j in chunk]}
            res = json.loads(fetch("osv_batch.json", "https://api.osv.dev/v1/querybatch",
                                   data=json.dumps(q).encode(), headers={"Content-Type": "application/json"}))
            for j, r in zip(chunk, res.get("results", [])):
                for v in r.get("vulns", []):
                    vid, mod = v["id"], v.get("modified", "")
                    det = OSV_CACHE.get(vid)
                    if not det or det.get("modified") != mod:
                        raw = json.loads(fetch("osv_vuln_%s.json" % vid, "https://api.osv.dev/v1/vulns/" + vid))
                        vec = next((s["score"] for s in raw.get("severity", []) if s.get("type") == "CVSS_V3"), "")
                        det = {"modified": mod, "aliases": [a for a in raw.get("aliases", []) if a.startswith("CVE-")],
                               "summary": (raw.get("summary") or raw.get("details", "")[:120]).strip(),
                               "published": raw.get("published", "")[:10], "vector": vec,
                               "severity": (raw.get("database_specific") or {}).get("severity", "")}
                        OSV_CACHE[vid] = det
                    score = cvss3(det["vector"]) if det["vector"] else \
                        {"CRITICAL": 9.0, "HIGH": 7.5, "MODERATE": 5.0, "LOW": 2.0}.get(det["severity"].upper())
                    cve = (det["aliases"] or [vid])[0]
                    vb = vendor_build(j["version"])
                    add("osv:%s:%s@%s" % (vid, j["coord"], j["version"]), source="osv", cve=cve,
                        product=j["coord"], version=j["version"], cvss=score, vector=det["vector"],
                        published=det["published"], covered=False, vendor_build=vb,
                        note=("Oracle build – fix may be backported, check KA1182 / next CPU; " if vb else "")
                             + det["summary"][:100] + " | " + ", ".join(j.get("paths", [])[:2]),
                        link="https://osv.dev/vulnerability/" + vid)
                    n_vuln += 1
        SRC_STATE["osv"] = "ok – %d library vulnerabilities (%d distinct ids)" % (
            n_vuln, len({k.split(":")[1] for k in FINDINGS if k.startswith("osv:")}))
    except Exception as e:
        SRC_STATE["osv"] = "FAILED (%s)" % e

# =============================================================================
# 4. heise security feed
# =============================================================================
HEISE = []
HEISE_RX = re.compile(r"WebLogic|Oracle Forms|Oracle Reports|Fusion Middleware|Java SE|Oracle[- ]Java|"
                      r"Oracle.{0,40}(Lücke|Sicherheitslücke|Angriff|Exploit|Patch)", re.I)
if "heise" in SOURCES:
    try:
        xml = fetch("heise_feed.xml", "https://www.heise.de/security/feed.xml")
        ns = {"a": "http://www.w3.org/2005/Atom"}
        root = ET.fromstring(xml)
        for e in root.findall("a:entry", ns):
            eid = e.findtext("a:id", "", ns); title = e.findtext("a:title", "", ns)
            summ = e.findtext("a:summary", "", ns); cont = e.findtext("a:content", "", ns)
            link = (e.find("a:link", ns).get("href") if e.find("a:link", ns) is not None else "")
            if not HEISE_RX.search(title + " " + summ):
                continue
            cves = sorted(set(re.findall(r"CVE-\d{4}-\d{4,}", title + summ + cont)))
            HEISE.append({"id": eid, "title": title, "link": link, "cves": cves,
                          "updated": e.findtext("a:updated", "", ns)[:10], "new": eid not in HEISE_SEEN})
        SRC_STATE["heise"] = "ok – %d matching article(s) in the feed" % len(HEISE)
    except Exception as e:
        SRC_STATE["heise"] = "FAILED (%s)" % e

# =============================================================================
# 5. CISA KEV + EPSS
# =============================================================================
KEV_RECENT = []
if "kev" in SOURCES:
    try:
        kev = json.loads(fetch("kev.json",
                               "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"))
        kmap = {v["cveID"]: v for v in kev.get("vulnerabilities", [])}
        for f in FINDINGS.values():
            if f.get("cve") in kmap:
                f["kev"] = True
                f["note"] = "KNOWN EXPLOITED (CISA KEV %s); " % kmap[f["cve"]].get("dateAdded", "") + f["note"]
        words = ("WebLogic", "Fusion Middleware", "Forms", "Reports", "Java SE", "HTTP Server", "Coherence")
        cutoff = (NOW - datetime.timedelta(days=30)).date().isoformat()
        for v in kev.get("vulnerabilities", []):
            if v.get("vendorProject", "").lower() == "oracle" and v.get("dateAdded", "") >= cutoff:
                KEV_RECENT.append(v)
                if any(w.lower() in v.get("product", "").lower() for w in words) \
                        and not any(f.get("cve") == v["cveID"] for f in FINDINGS.values()):
                    add("kev:%s" % v["cveID"], source="kev", cve=v["cveID"], product="Oracle " + v.get("product", ""),
                        version="", published=v.get("dateAdded", ""), covered=False, info_only=True,
                        note="KEV entry for an Oracle product we use – installed version not affected per NVD "
                             "or not in the NVD window: " + v.get("vulnerabilityName", ""),
                        link="https://nvd.nist.gov/vuln/detail/" + v["cveID"])
        SRC_STATE["kev"] = "ok – %d KEV entries, %d Oracle entries added in the last 30 days" % (len(kmap), len(KEV_RECENT))
    except Exception as e:
        SRC_STATE["kev"] = "FAILED (%s)" % e

for f in FINDINGS.values():
    if f.get("cve") in ACCEPTED:
        f["accepted"] = True
        f["note"] = "accepted: %s; " % ACCEPTED[f["cve"]] + f["note"]
    f["level"] = level_of(f)

if USE_EPSS:
    cves = sorted({f["cve"] for f in FINDINGS.values() if f["level"] != "INFO" and f.get("cve", "").startswith("CVE-")})
    try:
        epss = {}
        for i in range(0, len(cves), 80):
            r = json.loads(fetch("epss.json", "https://api.first.org/data/v1/epss?cve=" + ",".join(cves[i:i + 80])))
            epss.update({d["cve"]: (float(d["epss"]), float(d["percentile"])) for d in r.get("data", [])})
        for f in FINDINGS.values():
            if f.get("cve") in epss:
                f["epss"] = epss[f["cve"]]
        SRC_STATE["epss"] = "ok – %d scores" % len(epss)
    except Exception as e:
        SRC_STATE["epss"] = "FAILED (%s)" % e

# =============================================================================
# New vs. known, state, output
# =============================================================================
new, changed = [], []
for k, f in FINDINGS.items():
    old = SEEN.get(k)
    if old is None:
        f["status"] = "new"
        new.append(k)
    else:
        f["status"] = "known"
        if LEVELS[f["level"]] > LEVELS.get(old.get("level", "INFO"), 0) or (f["kev"] and not old.get("kev")):
            f["status"] = "changed"; changed.append(k)
    SEEN[k] = {"first_seen": (old or {}).get("first_seen", TODAY), "level": f["level"], "kev": f["kev"],
               "cve": f.get("cve", ""), "product": f["product"], "cvss": f["cvss"]}
# forget findings that are gone (fixed / inventory changed) – only for sources
# that answered this run, a failed source must not turn into a new alert flood
_ok = lambda s: SRC_STATE.get(s, "").startswith("ok")
_src_of = {"oracle": "nvd", "alert": "oracle", "advisory": "oracle", "osv": "osv", "kev": "kev"}
for k in list(SEEN):
    if k not in FINDINGS and _ok(_src_of.get(k.split(":")[0], "")):
        del SEEN[k]

def fmt(f):
    sc = "%.1f" % f["cvss"] if isinstance(f["cvss"], (int, float)) else "-"
    ep = " EPSS %.1f%%" % (f["epss"][0] * 100) if f["epss"] else ""
    rn = " remote w/o auth" if remote_noauth(f["vector"]) else ""
    ver = (" " + f["version"]) if f["version"] else ""
    return "%-16s %-4s %s%s%s%s – %s" % (f.get("cve") or "-", sc, f["product"], ver, rn, ep, f["note"][:140])

order = lambda k: (-LEVELS[FINDINGS[k]["level"]], -(FINDINGS[k]["cvss"] or 0), k)
alert_keys = [] if BASELINE else sorted([k for k in new + changed if FINDINGS[k]["level"] != "INFO"], key=order)
open_keys = sorted([k for k in FINDINGS if FINDINGS[k]["level"] != "INFO" and k not in alert_keys], key=order)

out("SECTION", "Sources")
for s in ("oracle", "nvd", "osv", "kev", "heise", "epss"):
    if s in SRC_STATE:
        out("FAIL" if SRC_STATE[s].startswith("FAILED") else "OK", "%-6s %s" % (s, SRC_STATE[s]))

if BASELINE:
    out("SECTION", "Baseline (first run) – %d findings recorded, alerts start with the next run" % len(FINDINGS))
else:
    out("SECTION", "NEW / changed since the last run (%s)" % STATE.get("last_run", "")[:16])
    if not alert_keys:
        out("OK", "nothing new >= WARN")
    for k in alert_keys:
        f = FINDINGS[k]
        out(f["level"] if f["level"] == "WARN" else "FAIL", ("[KEV] " if f["kev"] else "") + fmt(f))
        out("LOG", "%s %s" % (f["level"], fmt(f)))

out("SECTION", "Open findings (known, not yet fixed) – %d" % len(open_keys))
by_src = {}
for k in open_keys:
    by_src.setdefault(FINDINGS[k]["source"], []).append(k)
for src, keys in sorted(by_src.items()):
    out("INFO", "%s: %d (%d CRIT)" % (src, len(keys), sum(1 for k in keys if FINDINGS[k]["level"] == "CRIT")))
    for k in keys[:12]:
        out("INFO", "  " + ("%-4s " % FINDINGS[k]["level"]) + fmt(FINDINGS[k]))
    if len(keys) > 12:
        out("INFO", "  … %d more in the report" % (len(keys) - 12))
n_cov = sum(1 for f in FINDINGS.values() if f.get("covered"))
n_vb = sum(1 for f in FINDINGS.values() if f.get("vendor_build"))
out("INFO", "covered by the applied cycle %s: %d Oracle CVE matches; Oracle library builds (INFO): %d" % (CYCLE_NAME, n_cov, n_vb))

if HEISE:
    out("SECTION", "heise security – Oracle / Java related articles")
    for h in HEISE:
        rel = [c for c in h["cves"] if any(f.get("cve") == c for f in FINDINGS.values())]
        lvl = "WARN" if (rel and h["new"] and not BASELINE) else "INFO"
        out(lvl, "%s %s%s – %s%s" % (h["updated"], "NEW " if h["new"] else "", h["title"][:110], h["link"],
                                    (" – matches our findings: " + ", ".join(rel)) if rel else ""))
        if lvl == "WARN":
            out("LOG", "WARN heise: %s %s" % (h["title"][:100], h["link"]))
        HEISE_SEEN.add(h["id"])

# --- report (markdown) ---------------------------------------------------------
crit = [k for k in alert_keys if FINDINGS[k]["level"] == "CRIT"]
warnk = [k for k in alert_keys if FINDINGS[k]["level"] == "WARN"]
sev = "CRIT" if crit else ("WARN" if warnk else "OK")
lines = ["# CVE watch %s" % TODAY, "",
         "Inventory: `%s` – applied cycle **%s** (%s)" % (os.path.basename(inv_f), CYCLE_NAME, CYCLE_DATE), "",
         "```",
         "SEVERITY: %s" % sev,
         "FINDING: %s" % ("baseline run – %d findings recorded" % len(FINDINGS) if BASELINE else
                          "%d new CRIT, %d new WARN since the last run; %d open known" % (len(crit), len(warnk), len(open_keys))),
         "ROOT_CAUSE: %s" % ("; ".join(fmt(FINDINGS[k])[:120] for k in (crit + warnk)[:3]) or "-"),
         "RECOMMENDED_ACTION: %s" % ("check KA1182 / the advisory, plan the patch cycle (07-Maintenance), "
                                     "accepted -> 10-Monitoring/reports/cve_accepted.txt" if crit or warnk else "-"),
         "TICKET_RELEVANCE: %s" % ("yes" if crit else "no"),
         "```", "", "## Sources", ""]
lines += ["- %s: %s" % (s, SRC_STATE[s]) for s in SRC_STATE]
def table(title, keys):
    if not keys:
        return
    lines.extend(["", "## %s" % title, "", "| Level | CVE / id | CVSS | Product | Version | Note |", "|---|---|---|---|---|---|"])
    for k in keys:
        f = FINDINGS[k]
        lines.append("| %s%s | [%s](%s) | %s | %s | %s | %s |" % (
            f["level"], " KEV" if f["kev"] else "", f.get("cve") or "-", f["link"],
            "%.1f" % f["cvss"] if isinstance(f["cvss"], (int, float)) else "-",
            f["product"], f["version"], f["note"].replace("|", "/")[:200]))
table("New / changed", alert_keys)
table("Open (known)", open_keys)
if HEISE:
    lines += ["", "## heise security", ""] + ["- %s [%s](%s) %s" % (h["updated"], h["title"], h["link"], " ".join(h["cves"])) for h in HEISE]
with open(report_f, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
out("INFO", "Report: %s" % report_f)

with open(seen_csv, "w", encoding="utf-8") as fh:
    fh.write("key;cve;product;cvss;level;kev;first_seen\n")
    for k, s in sorted(SEEN.items()):
        fh.write("%s;%s;%s;%s;%s;%s;%s\n" % (k, s.get("cve", ""), s.get("product", ""), s.get("cvss") or "",
                                            s.get("level", ""), "yes" if s.get("kev") else "", s.get("first_seen", "")))

if save_state == "true":
    STATE["last_run"] = NOW.isoformat()
    STATE["heise_seen"] = sorted(HEISE_SEEN)[-500:]
    tmp = state_f + ".tmp"
    json.dump(STATE, open(tmp, "w", encoding="utf-8"), indent=1)
    os.replace(tmp, state_f)
for _f in (state_f, report_f, seen_csv):
    try:
        os.chmod(_f, 0o640)
    except OSError:
        pass

failed = any(v.startswith("FAILED") for v in SRC_STATE.values())
print("RC\t%d" % (2 if crit else (1 if (warnk or failed) else 0)))
PYEOF
_prc=$?

RC=2
while IFS=$'\t' read -r _lvl _txt; do
    case "$_lvl" in
        SECTION) section "$_txt" ;;
        OK)      ok "$_txt" ;;
        INFO)    info "$_txt" ;;
        WARN)    warn "$_txt" ;;
        FAIL)    fail "$_txt" ;;
        LOG)     logger -t ihw-cve -p "$( [[ "$_txt" == CRIT* ]] && printf user.err || printf user.warning )" "$_txt" 2>/dev/null ;;
        RC)      RC="$_txt" ;;
        *)       printf '%s\t%s\n' "$_lvl" "$_txt" | tee -a "${LOG_FILE:-/dev/null}" ;;
    esac
done < "$_out"
rm -f "$_out"
[ "$_prc" -ne 0 ] && fail "cve_watch python part failed (rc $_prc) – see the lines above"

print_summary
# exit = the watch result (new findings), not the count of open known ones
exit "$( [ "$_prc" -ne 0 ] && printf 2 || printf '%s' "$RC" )"
