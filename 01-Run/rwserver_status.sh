#!/bin/bash
# =============================================================================
# Script   : rwserver_status.sh
# Purpose  : Show Oracle Reports Server engine health beyond WLS server status:
#            configured min/max engines, running engine process count,
#            live idle/busy engine state and job queue via rwservlet HTTP.
# Call     : ./rwserver_status.sh
#            ./rwserver_status.sh --port 9002
#            ./rwserver_status.sh --server rep_wls_reports
# Options  : --port   N    WLS_REPORTS listen port (auto-detected from config.xml)
#            --server NAME Reports Server name (auto-detected from rwserver.conf)
#            --help        Show usage
# Requires : curl (for HTTP status), pgrep, awk
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
    printf "  %s\n"                    "$(basename "$0")"
    printf "  %s --port 9002\n"        "$(basename "$0")"
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
# Banner
# =============================================================================

printLine
section "Reports Server Status – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-26s %s\n" "Host:"             "$(hostname -f 2>/dev/null || hostname)" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "DOMAIN_HOME:"      "${DOMAIN_HOME}"                          | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "WLS_MANAGED_SERVER:" "${WLS_MANAGED_SERVER:-WLS_REPORTS}"    | tee -a "${LOG_FILE:-/dev/null}"
printLine

# =============================================================================
# 1. Configuration – parse rwserver.conf
# =============================================================================

section "Engine Configuration (rwserver.conf)"

RWSERVER_CONF="${RWSERVER_CONF:-}"

# Re-discover if not set in environment.conf
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

    # Extract <server name="..."> attribute
    RS_NAME="$(awk 'match($0, /<server[[:space:]]+[^>]*name="([^"]+)"/, m) { print m[1]; exit }' \
        "$RWSERVER_CONF" 2>/dev/null)"

    # Extract engine attributes from <engine ... minEngines="N" maxEngines="N" ...>
    _engine_attr() {
        local attr="$1"
        awk -v a="$attr" '
            /<engine/ {
                while (match($0, a "=\"([^\"]+)\"", m)) {
                    print m[1]; exit
                }
                # multi-line: accumulate until >
                while ($0 !~ />/) {
                    getline line; $0 = $0 " " line
                }
                if (match($0, a "=\"([^\"]+)\"", m)) { print m[1]; exit }
            }
        ' "$RWSERVER_CONF" 2>/dev/null
    }

    CFG_MIN_ENGINES="$(_engine_attr "minEngines")"
    CFG_MAX_ENGINES="$(_engine_attr "maxEngines")"
    CFG_MAX_IDLE="$(_engine_attr "maxIdle")"
    CFG_ENGINE_TYPE="$(_engine_attr "engineType")"

    printf "  %-26s %s\n" "Config file:"      "$RWSERVER_CONF"     | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "Server name:"      "${RS_NAME:-(not found)}"  | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "Engine type:"      "${CFG_ENGINE_TYPE:--}"    | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "minEngines:"       "${CFG_MIN_ENGINES:--}"    | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "maxEngines:"       "${CFG_MAX_ENGINES:--}"    | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "maxIdle:"          "${CFG_MAX_IDLE:--}"       | tee -a "${LOG_FILE:-/dev/null}"
fi

# Apply overrides
[ -n "$OVERRIDE_SERVER" ] && RS_NAME="$OVERRIDE_SERVER"

# =============================================================================
# 2. Process Status – running engine and server processes
# =============================================================================

printLine
section "Process Status"

# Main Reports Server process (Java / rwserver wrapper)
WLS_PID="$(pgrep -f "Dweblogic.Name=${WLS_MANAGED_SERVER:-WLS_REPORTS}" 2>/dev/null | head -1)"
if [ -n "$WLS_PID" ]; then
    ok "WLS managed server (${WLS_MANAGED_SERVER:-WLS_REPORTS}) RUNNING  (PID $WLS_PID)"
else
    warn "WLS managed server (${WLS_MANAGED_SERVER:-WLS_REPORTS}) not detected via pgrep"
    info "Start it first: ./01-Run/startStop.sh start ${WLS_MANAGED_SERVER:-WLS_REPORTS} --apply"
fi

# rwengine native processes (spawned by the Reports JVM)
RWENG_COUNT="$(pgrep -c -f "rwengine" 2>/dev/null || printf "0")"
RWENG_PIDS="$(pgrep -d ',' -f "rwengine" 2>/dev/null || printf "")"

if [ "$RWENG_COUNT" -gt 0 ]; then
    ok "rwengine processes: ${RWENG_COUNT}  (PID: ${RWENG_PIDS})"

    # Compare against configured max
    if [ -n "$CFG_MAX_ENGINES" ] && [ "$CFG_MAX_ENGINES" != "-" ]; then
        if [ "$RWENG_COUNT" -ge "$CFG_MAX_ENGINES" ]; then
            warn "Engine count ${RWENG_COUNT} >= maxEngines ${CFG_MAX_ENGINES} – pool at capacity"
        fi
    fi
    if [ -n "$CFG_MIN_ENGINES" ] && [ "$CFG_MIN_ENGINES" != "-" ]; then
        if [ "$RWENG_COUNT" -lt "$CFG_MIN_ENGINES" ]; then
            warn "Engine count ${RWENG_COUNT} < minEngines ${CFG_MIN_ENGINES} – fewer than expected"
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
# 3. Determine WLS_REPORTS port for HTTP status
# =============================================================================

printLine
section "HTTP Engine Status (rwservlet)"

# Find WLS_REPORTS listen port from config.xml
WLS_REPORTS_PORT="${OVERRIDE_PORT:-}"
WLS_REPORTS_HOST="localhost"

if [ -z "$WLS_REPORTS_PORT" ]; then
    CONFIG_XML="$DOMAIN_HOME/config/config.xml"
    if [ -f "$CONFIG_XML" ]; then
        # Extract port for WLS_MANAGED_SERVER from config.xml
        WLS_REPORTS_PORT="$(awk -v srv="${WLS_MANAGED_SERVER:-WLS_REPORTS}" '
            BEGIN { in_srv=0; name=""; port="" }
            /<server>$/   { in_srv=1; name=""; port=""; addr="" }
            /<\/server>$/ {
                if (in_srv && name == srv) { print port; exit }
                in_srv=0
            }
            in_srv && !/<ssl>/ {
                if (match($0, /<name>([^<]+)<\/name>/, m))         name = m[1]
                if (match($0, /<listen-port>([^<]+)<\/listen-port>/, m)) port = m[1]
                if (match($0, /<listen-address>([^<]+)<\/listen-address>/, m)) addr = m[1]
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
    # Build status URL
    SERVLET_BASE="http://${WLS_REPORTS_HOST}:${WLS_REPORTS_PORT}/reports/rwservlet"
    if [ -n "$RS_NAME" ]; then
        STATUS_URL="${SERVLET_BASE}?getserverinfo&server=${RS_NAME}&statusformat=xml"
    else
        STATUS_URL="${SERVLET_BASE}?getserverinfo&statusformat=xml"
    fi

    HTTP_BODY="$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 --max-time 10 "$STATUS_URL" 2>/dev/null)"

    # Try to get actual body for parsing
    HTTP_XML="$(curl -s --connect-timeout 5 --max-time 10 "$STATUS_URL" 2>/dev/null)"
    HTTP_CODE="$(printf "%s" "$HTTP_BODY")"

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
# 4. Engine + Job summary table (populated by _parse_rwservlet_xml)
# =============================================================================

# (called inline above when HTTP 200 is received)
_parse_rwservlet_xml() {
    local xml="$1"
    [ -z "$xml" ] && return

    printLine
    section "Engine Pool"

    # Count engines by status: idle / busy / total
    local total_eng idle_eng busy_eng
    total_eng="$(printf "%s" "$xml" | grep -oc '<engine '   2>/dev/null || printf "0")"
    idle_eng="$( printf "%s" "$xml" | grep -c 'status="idle"' 2>/dev/null || printf "0")"
    busy_eng="$( printf "%s" "$xml" | grep -c 'status="busy"' 2>/dev/null || printf "0")"

    printf "  %-26s %s\n" "Total engines (live):" "$total_eng"  | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "Idle:"                 "$idle_eng"   | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "Busy:"                 "$busy_eng"   | tee -a "${LOG_FILE:-/dev/null}"

    if [ -n "$CFG_MAX_ENGINES" ] && [ "$CFG_MAX_ENGINES" != "-" ]; then
        printf "  %-26s %s / %s (min %s)\n" \
            "Configured:" "$total_eng" "$CFG_MAX_ENGINES" "${CFG_MIN_ENGINES:--}" \
            | tee -a "${LOG_FILE:-/dev/null}"
    fi

    if [ "$busy_eng" -gt 0 ] && [ "$total_eng" -gt 0 ] && \
       [ "$busy_eng" -eq "$total_eng" ]; then
        warn "All engines busy – consider increasing maxEngines in rwserver.conf"
    elif [ "$busy_eng" -gt 0 ]; then
        ok "${busy_eng} engine(s) processing jobs"
    else
        ok "All engines idle"
    fi

    # Per-engine details
    if [ "$total_eng" -gt 0 ]; then
        printf "\n  \033[1m%-8s  %-8s  %-8s  %s\033[0m\n" \
            "ID" "Status" "Type" "PID" | tee -a "${LOG_FILE:-/dev/null}"
        printLine
        printf "%s" "$xml" | awk '
            /<engine / {
                id=""; status=""; etype=""; pid=""
                if (match($0, /id="([^"]+)"/, m))     id = m[1]
                if (match($0, /status="([^"]+)"/, m)) status = m[1]
                if (match($0, /type="([^"]+)"/, m))   etype = m[1]
                if (match($0, /pid="([^"]+)"/, m))    pid = m[1]
                printf "  %-8s  %-8s  %-8s  %s\n", id, status, etype, pid
            }
        ' | tee -a "${LOG_FILE:-/dev/null}"
    fi

    printLine
    section "Job Queue"

    # Parse job counts – format varies by Reports version
    local pending running finished failed
    # Format A: <jobs pending="N" running="N" finished="N" failed="N"/>
    pending="$( printf "%s" "$xml" | awk 'match($0, /pending="([0-9]+)"/, m)  { print m[1]; exit }')"
    running="$( printf "%s" "$xml" | awk 'match($0, /running="([0-9]+)"/, m)  { print m[1]; exit }')"
    finished="$(printf "%s" "$xml" | awk 'match($0, /finished="([0-9]+)"/, m) { print m[1]; exit }')"
    failed="$(  printf "%s" "$xml" | awk 'match($0, /failed="([0-9]+)"/, m)   { print m[1]; exit }')"
    # Format B: <queue ... runningJobs="N" scheduledJobs="N" .../>
    [ -z "$running"  ] && running="$( printf "%s" "$xml" | awk 'match($0, /runningJobs="([0-9]+)"/, m)   { print m[1]; exit }')"
    [ -z "$pending"  ] && pending="$( printf "%s" "$xml" | awk 'match($0, /scheduledJobs="([0-9]+)"/, m) { print m[1]; exit }')"
    [ -z "$failed"   ] && failed="$(  printf "%s" "$xml" | awk 'match($0, /failedJobs="([0-9]+)"/, m)    { print m[1]; exit }')"
    [ -z "$finished" ] && finished="$(printf "%s" "$xml" | awk 'match($0, /successJobs="([0-9]+)"/, m)   { print m[1]; exit }')"

    printf "  %-26s %s\n" "Pending:"  "${pending:--}"  | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "Running:"  "${running:--}"  | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "Finished:" "${finished:--}" | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "Failed:"   "${failed:--}"   | tee -a "${LOG_FILE:-/dev/null}"

    if [ -n "$failed" ] && [ "$failed" != "-" ] && [ "$failed" -gt 0 ]; then
        warn "${failed} failed job(s) – check Reports Server logs"
        info "Search: ./03-Logs/grep_logs.sh 'REP-' --component WLS_REPORTS"
    fi
    if [ -n "$pending" ] && [ "$pending" != "-" ] && [ "$pending" -gt 0 ]; then
        info "${pending} job(s) waiting in queue"
    fi
    if [ -n "$running" ] && [ "$running" != "-" ] && [ "$running" -gt 0 ]; then
        ok "${running} job(s) currently running"
    fi
}

# =============================================================================
# Summary
# =============================================================================

print_summary
exit "$EXIT_CODE"
