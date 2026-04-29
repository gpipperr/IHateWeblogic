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

    # Strategy 1: extract server name first, then filter by name (not full cmdline).
    # Full cmdline often contains "report" via domain path (e.g. fr_domain),
    # which would wrongly match AdminServer.
    found="$(pgrep -a -f 'weblogic.Name=' 2>/dev/null \
        | sed -n 's/.*-Dweblogic\.Name=\([^ ]*\).*/\1/p' \
        | grep -i 'report' \
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

# Extract element value <tag>value</tag> from an XML string (not a file).
# Usage: _xval "$xml" "tagname"
_xval() { printf "%s" "$1" | sed -n "s|.*<${2}>\([^<]*\)</${2}>.*|\1|p" | head -1; }

# Extract a named attribute from a single XML tag line.
# Usage: _xline_attr "$line" "attrname"
_xline_attr() { printf "%s" "$1" | sed -n "s/.*[[:space:]]${2}=\"\([^\"]*\)\".*/\1/p"; }

# Extract the value of <property name="N" value="V"/> from an XML string.
# Usage: _xprop "$xml" "propertyName"
_xprop() { printf "%s" "$1" | grep "name=\"${2}\"" | sed -n 's/.*value="\([^"]*\)".*/\1/p' | head -1; }

# Parse the rwservlet XML response (getserverinfo?statusformat=XML) and display
# four sections: Server Info, Engine Pool, Performance, Connections.
# Must be defined before its call site.
_parse_rwservlet_xml() {
    local xml="$1"
    [ -z "$xml" ] && return

    # ─── A: Server Info ───────────────────────────────────────────────────────
    section "Server Info"

    local srv_name srv_ver srv_host srv_pid start_ms is_secure avg_auth queue_max
    srv_name="$(  printf "%s" "$xml" | sed -n 's/.*<serverInfo[^>]*name="\([^"]*\)".*/\1/p'    | head -1)"
    srv_ver="$(   printf "%s" "$xml" | sed -n 's/.*<serverInfo[^>]*version="\([^"]*\)".*/\1/p' | head -1)"
    srv_host="$(  _xval "$xml" "host")"
    srv_pid="$(   _xval "$xml" "processId")"
    start_ms="$(  _xval "$xml" "startTime")"
    is_secure="$( _xval "$xml" "isSecure")"
    avg_auth="$(  _xval "$xml" "avgAuthTime")"
    queue_max="$( printf "%s" "$xml" | sed -n 's/.*<queue[^>]*maxQueueSize="\([^"]*\)".*/\1/p' | head -1)"

    # startTime is epoch-milliseconds → human readable + uptime
    local start_human="" uptime_str=""
    if [ -n "$start_ms" ] && [ "$start_ms" -gt 0 ] 2>/dev/null; then
        local ep=$(( start_ms / 1000 ))
        start_human="$(date -d "@${ep}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
        local now up d h m
        now="$(date +%s)"
        up=$(( now - ep ))
        d=$(( up / 86400 ))
        h=$(( (up % 86400) / 3600 ))
        m=$(( (up % 3600) / 60 ))
        uptime_str="${d}d ${h}h ${m}m"
    fi

    local secure_label
    case "${is_secure:-}" in 1) secure_label="Yes (HTTPS)";; 0) secure_label="No (HTTP)";; *) secure_label="${is_secure:-(unknown)}";; esac

    printf "  %-28s %s\n" "Server name:"    "${srv_name:-(unknown)}"
    printf "  %-28s %s\n" "Version:"        "${srv_ver:-(unknown)}"
    printf "  %-28s %s\n" "Host:"           "${srv_host:-(unknown)}"
    [ -n "$srv_pid" ]     && printf "  %-28s %s\n"    "Process ID:"    "$srv_pid"
    [ -n "$start_human" ] && printf "  %-28s %s  (up: %s)\n" "Running since:" "$start_human" "$uptime_str"
    printf "  %-28s %s\n" "Secured:"        "$secure_label"
    [ -n "$avg_auth" ]    && printf "  %-28s %s ms\n" "Avg auth time:" "$avg_auth"
    [ -n "$queue_max" ]   && printf "  %-28s %s\n"    "Max queue size:" "$queue_max"

    # ─── B: Engine Pool ───────────────────────────────────────────────────────
    printLine
    section "Engine Pool"

    local _eline
    while IFS= read -r _eline; do
        [ -z "$_eline" ] && continue
        local eid eact erun ebusy eidle
        eid="$(   _xline_attr "$_eline" "id")"
        eact="$(  _xline_attr "$_eline" "activeEngine")"
        erun="$(  _xline_attr "$_eline" "runningEngine")"
        ebusy="$( _xline_attr "$_eline" "totalBusyEngines")"
        eidle="$( _xline_attr "$_eline" "totalIdleEngines")"
        printf "\n  Engine \033[1m%-20s\033[0m  Active:%-3s  Running:%-3s  Busy:%-3s  Idle:%-3s\n" \
            "${eid:-(?)}" "${eact:--}" "${erun:--}" "${ebusy:--}" "${eidle:--}"
        if [ "${ebusy:-0}" -gt 0 ] && [ "${eidle:-1}" -eq 0 ] 2>/dev/null; then
            warn "  Engine '${eid}' – all instances busy, consider increasing maxEngine"
        fi
    done < <(printf "%s" "$xml" | grep '<engine ')

    # Per-instance detail table
    local inst_lines
    inst_lines="$(printf "%s" "$xml" | grep '<engineInstance')"
    if [ -n "$inst_lines" ]; then
        printf "\n  \033[1m%-14s %-8s %-8s %-14s %-8s %-9s %-9s %s\033[0m\n" \
            "Instance" "PID" "Status" "Job ID" "Idle(s)" "Jobs run" "Life left" "NLS"
        while IFS= read -r _iline; do
            [ -z "$_iline" ] && continue
            local iname ipid istatus ijob iidle injobs ilife inls status_str
            iname="$(  _xline_attr "$_iline" "name")"
            ipid="$(   _xline_attr "$_iline" "processId")"
            istatus="$(_xline_attr "$_iline" "status")"
            ijob="$(   _xline_attr "$_iline" "runJobId")"
            iidle="$(  _xline_attr "$_iline" "idleTime")"
            injobs="$( _xline_attr "$_iline" "numJobsRun")"
            ilife="$(  _xline_attr "$_iline" "lifeLeft")"
            inls="$(   _xline_attr "$_iline" "nls")"
            case "$istatus" in
                1)  status_str="IDLE" ;;
                2)  status_str=$'\033[33mBUSY\033[0m' ;;
                0)  status_str=$'\033[31mDEAD\033[0m' ;;
                *)  status_str="UNK(${istatus})" ;;
            esac
            [ "$ijob" = "-1" ] && ijob="(none)"
            printf "  %-14s %-8s %-8b %-14s %-8s %-9s %-9s %s\n" \
                "${iname:--}" "${ipid:--}" "$status_str" "$ijob" \
                "${iidle:--}" "${injobs:--}" "${ilife:--}" "${inls:--}"
        done <<< "$inst_lines"
    fi

    # ─── C: Performance ───────────────────────────────────────────────────────
    printLine
    section "Performance"

    local p_ok p_cur p_fut p_trans p_fail p_long p_run p_resp p_elap p_queue
    p_ok="$(    _xprop "$xml" "successfulJobs")"
    p_cur="$(   _xprop "$xml" "currentJobs")"
    p_fut="$(   _xprop "$xml" "futureJobs")"
    p_trans="$( _xprop "$xml" "transferredJobs")"
    p_fail="$(  _xprop "$xml" "failedJobs")"
    p_long="$(  _xprop "$xml" "longRunningJobs")"
    p_run="$(   _xprop "$xml" "potentialRunawayJobs")"
    p_resp="$(  _xprop "$xml" "averageResponseTime")"
    p_elap="$(  _xprop "$xml" "averageElapsedTime")"
    p_queue="$( _xprop "$xml" "avgQueuingTime")"

    printf "  %-28s %s\n"    "Successful jobs:"        "${p_ok:--}"
    printf "  %-28s %s\n"    "Current jobs:"           "${p_cur:--}"
    printf "  %-28s %s\n"    "Future jobs:"            "${p_fut:--}"
    printf "  %-28s %s\n"    "Transferred jobs:"       "${p_trans:--}"
    printf "  %-28s %s\n"    "Failed jobs:"            "${p_fail:--}"
    printf "  %-28s %s\n"    "Long running jobs:"      "${p_long:--}"
    printf "  %-28s %s\n"    "Potential runaway jobs:" "${p_run:--}"
    printf "  %-28s %s ms\n" "Avg response time:"      "${p_resp:--}"
    printf "  %-28s %s ms\n" "Avg elapsed time:"       "${p_elap:--}"
    printf "  %-28s %s ms\n" "Avg queuing time:"       "${p_queue:--}"

    if [ -n "$p_run" ] && [ "$p_run" != "-" ] && [ "$p_run" -gt 0 ] 2>/dev/null; then
        fail "${p_run} potential runaway job(s) – investigate immediately"
    fi
    if [ -n "$p_long" ] && [ "$p_long" != "-" ] && [ "$p_long" -gt 0 ] 2>/dev/null; then
        warn "${p_long} long-running job(s)"
    fi
    if [ -n "$p_fail" ] && [ "$p_fail" != "-" ] && [ "$p_fail" -gt 0 ] 2>/dev/null; then
        warn "${p_fail} failed job(s) – check Reports Server logs"
        info "  Search: ./03-Logs/grep_logs.sh 'REP-'"
    else
        ok "No failed jobs"
    fi
    if [ "${p_cur:-0}" -gt 0 ] 2>/dev/null; then
        ok "${p_cur} job(s) currently executing"
    fi

    # ─── D: Connections ───────────────────────────────────────────────────────
    printLine
    section "Connections"

    local c_used c_avail e_maxused e_avgused
    c_used="$(   printf "%s" "$xml" | sed -n 's/.*<connection[^>]*connectionsUsed="\([^"]*\)".*/\1/p'      | head -1)"
    c_avail="$(  printf "%s" "$xml" | sed -n 's/.*<connection[^>]*connectionsAvailable="\([^"]*\)".*/\1/p' | head -1)"
    e_maxused="$(printf "%s" "$xml" | sed -n 's/.*<engineInfo[^>]*maxEnginesUsed="\([^"]*\)".*/\1/p'      | head -1)"
    e_avgused="$(printf "%s" "$xml" | sed -n 's/.*<engineInfo[^>]*avgEnginesUsed="\([^"]*\)".*/\1/p'      | head -1)"

    printf "  %-28s %s\n" "Connections used:"      "${c_used:--}"
    printf "  %-28s %s\n" "Connections available:" "${c_avail:--}"
    printf "  %-28s %s\n" "Max engines used:"      "${e_maxused:--}"
    printf "  %-28s %s\n" "Avg engines used:"      "${e_avgused:--}"

    if [ -n "$c_avail" ] && [ "$c_avail" = "0" ] && \
       [ -n "$c_used" ]  && [ "$c_used" -gt 0 ] 2>/dev/null; then
        warn "Connection pool exhausted (used=${c_used}, available=0)"
    else
        ok "Connection pool OK"
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
    info "Re-run 00-Setup/init_env.sh to detect the Reports component path"
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
            /<server>$/   { in_srv=1; in_ssl=0; name=""; port="" }
            /<\/server>$/ {
                if (in_srv && name == srv && port != "") { print port; exit }
                in_srv=0; in_ssl=0
            }
            in_srv && /<ssl>$/   { in_ssl=1 }
            in_srv && /<\/ssl>$/ { in_ssl=0 }
            in_srv && !in_ssl {
                if ($0 ~ /<name>/) {
                    n=$0; gsub(/.*<name>/, "", n); gsub(/<\/name>.*/, "", n)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", n)
                    if (n != "") name=n
                }
                if ($0 ~ /<listen-port>/) {
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
        STATUS_URL="${SERVLET_BASE}/getserverinfo?server=${RS_NAME}&statusformat=XML"
    else
        STATUS_URL="${SERVLET_BASE}/getserverinfo?statusformat=XML"
    fi
    printf "  %-26s %s\n" "Status URL:" "$STATUS_URL"

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
