#!/bin/bash
# =============================================================================
# Script   : rwserver_status.sh
# Purpose  : Show Oracle Reports Server engine health beyond WLS server status:
#            configured min/max engines, running engine process count,
#            live idle/busy engine state and job queue via rwservlet HTTP.
# Call     : ./rwserver_status.sh
#            ./rwserver_status.sh --port 9012
#            ./rwserver_status.sh --server repServer01
# Options  : --port   N    WLS_REPORTS listen port (auto-detected from config.xml)
#            --server NAME Reports Server name (auto-detected from rwserver.conf)
#            --help        Show usage
# Requires : curl (for HTTP status), pgrep, sed
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 01-Run/README.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"

LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m IHateWeblogic_lib.sh not found: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"

check_env_conf "$ENV_CONF" || exit 2
source "$ENV_CONF"
init_log

# =============================================================================
# Helper functions  (defined before their call sites)
# =============================================================================

# Detect the Reports WLS managed server name.
# Priority:
#   1. Running process with "report" in -Dweblogic.Name=...
#   2. config.xml server name containing "report"
#   3. WLS_MANAGED_SERVER from environment.conf (if it differs from domain name)
#   4. Fallback: WLS_REPORTS
_detect_wls_reports_server() {
    local config_xml="$DOMAIN_HOME/config/config.xml"
    local domain_name found

    domain_name="$(basename "${DOMAIN_HOME:-/}")"

    # Strategy 1: running processes
    found="$(pgrep -a -f 'weblogic.Name=' 2>/dev/null \
        | grep -i 'report' \
        | sed -n 's/.*-Dweblogic\.Name=\([^ ]*\).*/\1/p' \
        | head -1)"
    [ -n "$found" ] && { printf "%s" "$found"; return 0; }

    # Strategy 2: config.xml server names
    if [ -f "$config_xml" ]; then
        found="$(awk '
            /<server>$/   { in_srv=1; name="" }
            /<\/server>$/ { in_srv=0 }
            in_srv && /<name>/ {
                n=$0
                gsub(/.*<name>/, "", n); gsub(/<\/name>.*/, "", n)
                if (tolower(n) ~ /report/) { print n; exit }
            }
        ' "$config_xml" 2>/dev/null)"
        [ -n "$found" ] && { printf "%s" "$found"; return 0; }
    fi

    # Strategy 3: WLS_MANAGED_SERVER from environment.conf (if != domain name)
    if [ -n "${WLS_MANAGED_SERVER:-}" ] && [ "${WLS_MANAGED_SERVER}" != "$domain_name" ]; then
        printf "%s" "${WLS_MANAGED_SERVER}"
        return 0
    fi

    # Fallback
    printf "WLS_REPORTS"
}

# Extract an XML attribute value from a file.
# Joins all lines first (handles multi-line elements).
# Usage: _xml_attr FILE attribute_name
_xml_attr() {
    local file="$1"
    local attr="$2"
    { tr -d '\n' < "$file"; printf "\n"; } \
        | sed -n "s/.*[[:space:]]${attr}=\"\([^\"]*\)\".*/\1/p"
}

# Extract engine attribute – tries singular and plural form (minEngine / minEngines).
# Usage: _engine_attr FILE base_name   (e.g. _engine_attr rwserver.conf minEngine)
_engine_attr() {
    local file="$1"
    local base="$2"
    local val
    val="$(_xml_attr "$file" "${base}")"
    [ -z "$val" ] && val="$(_xml_attr "$file" "${base}s")"
    printf "%s" "$val"
}

# Parse the rwservlet XML response and print engine pool + job queue tables.
# Must be defined before its call site.
_parse_rwservlet_xml() {
    local xml="$1"
    [ -z "$xml" ] && return

    printLine
    section "Engine Pool"

    local total_eng idle_eng busy_eng
    total_eng="$(printf "%s" "$xml" | grep -c '<engine '   2>/dev/null || printf "0")"
    idle_eng="$( printf "%s" "$xml" | grep -c 'status="idle"' 2>/dev/null || printf "0")"
    busy_eng="$( printf "%s" "$xml" | grep -c 'status="busy"' 2>/dev/null || printf "0")"

    printf "  %-26s %s\n" "Total engines (live):" "$total_eng" | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "Idle:"                 "$idle_eng"  | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "Busy:"                 "$busy_eng"  | tee -a "${LOG_FILE:-/dev/null}"

    if [ -n "${CFG_MAX_ENGINES:-}" ] && [ "$CFG_MAX_ENGINES" != "-" ]; then
        printf "  %-26s %s / %s  (min %s)\n" \
            "Configured:" "$total_eng" "$CFG_MAX_ENGINES" "${CFG_MIN_ENGINES:--}" \
            | tee -a "${LOG_FILE:-/dev/null}"
    fi

    if   [ "$busy_eng" -gt 0 ] && [ "$total_eng" -gt 0 ] && [ "$busy_eng" -eq "$total_eng" ]; then
        warn "All engines busy – consider increasing maxEngine in rwserver.conf"
    elif [ "$busy_eng" -gt 0 ]; then
        ok "${busy_eng} engine(s) processing jobs"
    else
        ok "All engines idle"
    fi

    # Per-engine details
    if [ "$total_eng" -gt 0 ]; then
        printf "\n  \033[1m%-8s  %-8s  %-14s  %s\033[0m\n" \
            "ID" "Status" "Type" "PID" | tee -a "${LOG_FILE:-/dev/null}"
        printf "%s" "$xml" | grep '<engine ' | while IFS= read -r line; do
            local _id _st _ty _pid
            _id="$( printf "%s" "$line" | sed -n 's/.*[[:space:]]id="\([^"]*\)".*/\1/p')"
            _st="$( printf "%s" "$line" | sed -n 's/.*status="\([^"]*\)".*/\1/p')"
            _ty="$( printf "%s" "$line" | sed -n 's/.*type="\([^"]*\)".*/\1/p')"
            _pid="$(printf "%s" "$line" | sed -n 's/.*pid="\([^"]*\)".*/\1/p')"
            printf "  %-8s  %-8s  %-14s  %s\n" \
                "${_id:--}" "${_st:--}" "${_ty:--}" "${_pid:--}"
        done | tee -a "${LOG_FILE:-/dev/null}"
    fi

    printLine
    section "Job Queue"

    local pending running finished failed
    # Format A: <jobs pending="N" running="N" finished="N" failed="N"/>
    pending="$( printf "%s" "$xml" | sed -n 's/.*pending="\([0-9]*\)".*/\1/p'  | head -1)"
    running="$( printf "%s" "$xml" | sed -n 's/.*running="\([0-9]*\)".*/\1/p'  | head -1)"
    finished="$(printf "%s" "$xml" | sed -n 's/.*finished="\([0-9]*\)".*/\1/p' | head -1)"
    failed="$(  printf "%s" "$xml" | sed -n 's/.*failed="\([0-9]*\)".*/\1/p'   | head -1)"
    # Format B: <queue runningJobs="N" scheduledJobs="N" .../>
    [ -z "$running"  ] && running="$( printf "%s" "$xml" | sed -n 's/.*runningJobs="\([0-9]*\)".*/\1/p'   | head -1)"
    [ -z "$pending"  ] && pending="$( printf "%s" "$xml" | sed -n 's/.*scheduledJobs="\([0-9]*\)".*/\1/p' | head -1)"
    [ -z "$failed"   ] && failed="$(  printf "%s" "$xml" | sed -n 's/.*failedJobs="\([0-9]*\)".*/\1/p'    | head -1)"
    [ -z "$finished" ] && finished="$(printf "%s" "$xml" | sed -n 's/.*successJobs="\([0-9]*\)".*/\1/p'   | head -1)"

    printf "  %-26s %s\n" "Pending:"  "${pending:--}"  | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "Running:"  "${running:--}"  | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "Finished:" "${finished:--}" | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "Failed:"   "${failed:--}"   | tee -a "${LOG_FILE:-/dev/null}"

    if [ -n "$failed" ] && [ "$failed" != "-" ] && [ "$failed" -gt 0 ]; then
        warn "${failed} failed job(s) – check Reports Server logs"
        info "Search: ./03-Logs/grep_logs.sh 'REP-'"
    fi
    if [ -n "$pending" ] && [ "$pending" != "-" ] && [ "$pending" -gt 0 ]; then
        info "${pending} job(s) waiting in queue"
    fi
    if [ -n "$running" ] && [ "$running" != "-" ] && [ "$running" -gt 0 ]; then
        ok "${running} job(s) currently running"
    fi
}

# =============================================================================
# Arguments
# =============================================================================

OVERRIDE_PORT=""
OVERRIDE_SERVER=""

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-24s %s\n" "--port N"       "WLS_REPORTS listen port (default: auto-detect)"
    printf "  %-24s %s\n" "--server NAME"  "Reports Server name (default: from rwserver.conf)"
    printf "  %-24s %s\n" "--help"         "Show this help"
    printf "\nExamples:\n"
    printf "  %s\n"              "$(basename "$0")"
    printf "  %s --port 9012\n"  "$(basename "$0")"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --port)    OVERRIDE_PORT="$2";   shift 2 ;;
        --server)  OVERRIDE_SERVER="$2"; shift 2 ;;
        --help|-h) _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
    esac
done

# =============================================================================
# Detect Reports WLS managed server (before banner so it can be shown)
# =============================================================================

WLS_REPORTS_SERVER="${OVERRIDE_SERVER:-$(_detect_wls_reports_server)}"

# =============================================================================
# Banner
# =============================================================================

printLine
section "Reports Server Status – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-26s %s\n" "Host:"               "$(hostname -f 2>/dev/null || hostname)" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "DOMAIN_HOME:"        "${DOMAIN_HOME}"                          | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "Reports WLS server:" "${WLS_REPORTS_SERVER}"                   | tee -a "${LOG_FILE:-/dev/null}"
printLine

# =============================================================================
# 1. Configuration – parse rwserver.conf
# =============================================================================

section "Engine Configuration (rwserver.conf)"

RWSERVER_CONF="${RWSERVER_CONF:-}"

# Re-discover if not set or file missing
if [ -z "$RWSERVER_CONF" ] || [ ! -f "$RWSERVER_CONF" ]; then
    RWSERVER_CONF="$(find "${DOMAIN_HOME}/config" -name "rwserver.conf" 2>/dev/null | head -1)"
fi

if [ -z "$RWSERVER_CONF" ] || [ ! -f "$RWSERVER_CONF" ]; then
    warn "rwserver.conf not found – configuration section skipped"
    info "Re-run 00-Setup/env_check.sh to detect the Reports component path"
    RS_NAME=""
    CFG_MIN_ENGINES="-"
    CFG_MAX_ENGINES="-"
    CFG_MAX_IDLE="-"
    CFG_ENGINE_TYPE="-"
else
    ok "Found: $RWSERVER_CONF"

    # <server name="..."> – attribute may appear anywhere in the tag
    RS_NAME="$(sed -n 's/.*<server[^>]*name="\([^"]*\)".*/\1/p' \
        "$RWSERVER_CONF" 2>/dev/null | head -1)"

    # Engine attributes: singular (maxEngine) and plural (maxEngines) both occur in the wild
    CFG_MIN_ENGINES="$(_engine_attr "$RWSERVER_CONF" "minEngine")"
    CFG_MAX_ENGINES="$(_engine_attr "$RWSERVER_CONF" "maxEngine")"
    CFG_MAX_IDLE="$(   _xml_attr    "$RWSERVER_CONF" "maxIdle")"
    CFG_ENGINE_TYPE="$(_xml_attr    "$RWSERVER_CONF" "engineType")"

    printf "  %-26s %s\n" "Config file:"  "$RWSERVER_CONF"           | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "Server name:"  "${RS_NAME:-(not found)}"  | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "Engine type:"  "${CFG_ENGINE_TYPE:--}"    | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "minEngine:"    "${CFG_MIN_ENGINES:--}"    | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "maxEngine:"    "${CFG_MAX_ENGINES:--}"    | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "maxIdle:"      "${CFG_MAX_IDLE:--}"       | tee -a "${LOG_FILE:-/dev/null}"
fi

# --server overrides the Reports Server logical name used for HTTP query
[ -n "$OVERRIDE_SERVER" ] && RS_NAME="$OVERRIDE_SERVER"

# =============================================================================
# 2. Process Status
# =============================================================================

printLine
section "Process Status"

# WLS managed server process (JVM with -Dweblogic.Name=<server>)
WLS_PID="$(pgrep -f "weblogic.Name=${WLS_REPORTS_SERVER}" 2>/dev/null | head -1)"
if [ -n "$WLS_PID" ]; then
    ok "WLS managed server '${WLS_REPORTS_SERVER}' RUNNING  (PID $WLS_PID)"
else
    warn "WLS managed server '${WLS_REPORTS_SERVER}' not detected via pgrep"
    info "Start it first: ./01-Run/startStop.sh start ${WLS_REPORTS_SERVER} --apply"
fi

# rwengine native processes (spawned by the Reports JVM)
RWENG_COUNT="$(pgrep -f "rwengine" 2>/dev/null | wc -l | tr -d ' ')"
RWENG_PIDS="$(pgrep -d ',' -f "rwengine" 2>/dev/null || printf "")"

if [ "${RWENG_COUNT:-0}" -gt 0 ]; then
    ok "rwengine processes: ${RWENG_COUNT}  (PID: ${RWENG_PIDS})"

    if [ -n "${CFG_MAX_ENGINES:-}" ] && [ "$CFG_MAX_ENGINES" != "-" ]; then
        if [ "$RWENG_COUNT" -ge "$CFG_MAX_ENGINES" ]; then
            warn "Engine count ${RWENG_COUNT} >= maxEngine ${CFG_MAX_ENGINES} – pool at capacity"
        fi
    fi
    if [ -n "${CFG_MIN_ENGINES:-}" ] && [ "$CFG_MIN_ENGINES" != "-" ]; then
        if [ "$RWENG_COUNT" -lt "$CFG_MIN_ENGINES" ]; then
            warn "Engine count ${RWENG_COUNT} < minEngine ${CFG_MIN_ENGINES} – fewer than expected"
        fi
    fi
else
    if [ -n "$WLS_PID" ]; then
        warn "No rwengine processes found – engines may still be initializing"
        info "Check: pgrep -a -f rwengine"
    else
        info "No rwengine processes (WLS managed server not running)"
    fi
fi

# =============================================================================
# 3. HTTP Engine Status (rwservlet)
# =============================================================================

printLine
section "HTTP Engine Status (rwservlet)"

WLS_REPORTS_PORT="${OVERRIDE_PORT:-}"
WLS_REPORTS_HOST="localhost"

if [ -z "$WLS_REPORTS_PORT" ]; then
    CONFIG_XML="$DOMAIN_HOME/config/config.xml"
    if [ -f "$CONFIG_XML" ]; then
        # Extract listen-port for the detected Reports WLS server from config.xml.
        # Uses plain awk (no 3-arg match) – gsub strips tags in-place.
        WLS_REPORTS_PORT="$(awk -v srv="$WLS_REPORTS_SERVER" '
            /<server>$/   { in_srv=1; name=""; port="" }
            /<\/server>$/ {
                if (in_srv && name == srv && port != "") { print port; exit }
                in_srv=0
            }
            in_srv {
                if ($0 ~ /<name>/) {
                    n=$0; gsub(/.*<name>/, "", n); gsub(/<\/name>.*/, "", n)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", n)
                    if (n != "") name=n
                }
                if ($0 ~ /<listen-port>/ && $0 !~ /<ssl>/) {
                    p=$0; gsub(/.*<listen-port>/, "", p); gsub(/<\/listen-port>.*/, "", p)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", p)
                    if (p != "") port=p
                }
            }
        ' "$CONFIG_XML" 2>/dev/null)"
        [ -z "$WLS_REPORTS_PORT" ] && WLS_REPORTS_PORT="9002"
    else
        WLS_REPORTS_PORT="9002"
        info "config.xml not found – using default port 9002"
    fi
fi

printf "  %-26s %s\n" "Reports servlet URL:" \
    "http://${WLS_REPORTS_HOST}:${WLS_REPORTS_PORT}/reports/rwservlet" \
    | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "Reports Server name:" "${RS_NAME:-(unknown)}" \
    | tee -a "${LOG_FILE:-/dev/null}"

if ! command -v curl > /dev/null 2>&1; then
    warn "curl not found – HTTP status check skipped"
    info "Install: sudo dnf install curl"
else
    SERVLET_BASE="http://${WLS_REPORTS_HOST}:${WLS_REPORTS_PORT}/reports/rwservlet"
    if [ -n "${RS_NAME:-}" ]; then
        STATUS_URL="${SERVLET_BASE}?getserverinfo&server=${RS_NAME}&statusformat=xml"
    else
        STATUS_URL="${SERVLET_BASE}?getserverinfo&statusformat=xml"
    fi

    # Fetch XML body and HTTP status code in two calls (avoids -w/%{http_code} + body mix)
    HTTP_XML="$(curl -s --connect-timeout 5 --max-time 10 "$STATUS_URL" 2>/dev/null)"
    HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 --max-time 10 "$STATUS_URL" 2>/dev/null)"

    case "$HTTP_CODE" in
        200)
            ok "rwservlet reachable (HTTP 200)"
            _parse_rwservlet_xml "$HTTP_XML"
            ;;
        000)
            warn "No response from rwservlet – WLS_REPORTS not running or port wrong?"
            info "Check port: ss -tlnp | grep ${WLS_REPORTS_PORT}"
            ;;
        401|403)
            warn "HTTP ${HTTP_CODE} – Authentication required on rwservlet"
            info "The getserverinfo command may need a secured URL or admin credentials"
            ;;
        404)
            warn "HTTP 404 – rwservlet not found at: $STATUS_URL"
            info "Reports may not be deployed or the context path differs"
            ;;
        *)
            warn "HTTP ${HTTP_CODE} – unexpected response from rwservlet"
            ;;
    esac
fi

# =============================================================================
# Summary
# =============================================================================

print_summary
exit "$EXIT_CODE"
