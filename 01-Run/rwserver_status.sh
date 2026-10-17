#!/bin/bash
# =============================================================================
# Script   : rwserver_status.sh
# Purpose  : Show Oracle Reports Server engine health beyond WLS server status:
#            configured min/max engines, running engine process count,
#            live idle/busy engine state and job queue via rwservlet HTTP.
# Call     : ./rwserver_status.sh
#            ./rwserver_status.sh --port 9012
#            ./rwserver_status.sh --server repServer01
#            ./rwserver_status.sh --auth admin
# Options  : --port   N    WLS_REPORTS listen port (auto-detected from config.xml)
#            --server NAME Reports Server name (auto-detected from rwserver.conf)
#            --auth   MODE authid for getserverinfo: auto (default) | mon | admin | none
#            --help        Show usage
# Auth     : getserverinfo needs an authid on a secured / hardened server
#            (REP-52262, HTTP 499 without). auto = REPORTS_SECURITY=ldap ->
#            monUser (RW_MONITOR) from reports_users.conf.des3, otherwise the
#            Reports server administrator (<identifier>) from
#            reports_admin_sec.conf.des3; falls back to the other one. The
#            password goes to curl via a config on stdin - not in the
#            process list, not printed.
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
# Reads the attribute from the REPORT engine only - rwserver.conf also has the
# URL engine (rwURLEng, maxEngine=1 minEngine=0), a greedy match over the
# whole file returned its values. Engine = the one of <job jobType="report"
# engineId=...>, else the first engine that is not the URL engine.
_engine_attr() {
    local file="$1"
    local base="$2"
    local flat eid line val
    flat="$(tr -d '\n' < "$file" | sed 's/</\n</g')"
    eid="$(printf '%s\n' "$flat" | grep '^<job ' | grep 'jobType="report"' \
           | sed -n 's/.*engineId="\([^"]*\)".*/\1/p' | head -1)"
    if [ -n "$eid" ]; then
        line="$(printf '%s\n' "$flat" | grep "^<engine " | grep "id=\"${eid}\"" | head -1)"
    fi
    [ -z "$line" ] && line="$(printf '%s\n' "$flat" | grep '^<engine ' | grep -v 'URLEngineImpl' | head -1)"
    val="$(printf '%s' "$line" | sed -n "s/.*[[:space:]]${base}=\"\([^\"]*\)\".*/\1/p")"
    [ -z "$val" ] && val="$(printf '%s' "$line" | sed -n "s/.*[[:space:]]${base}s=\"\([^\"]*\)\".*/\1/p")"
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
AUTH_MODE="auto"

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-24s %s\n" "--port N"       "WLS_REPORTS listen port (default: auto-detect)"
    printf "  %-24s %s\n" "--server NAME"  "Reports Server name (default: from rwserver.conf)"
    printf "  %-24s %s\n" "--auth MODE"    "authid: auto (default) | mon | admin | none"
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
        --auth)    AUTH_MODE="${2,,}";   shift 2 ;;
        --help|-h) _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
    esac
done

case "$AUTH_MODE" in
    auto|mon|admin|none) ;;
    *) printf "\033[31mERROR\033[0m --auth must be auto, mon, admin or none\n" >&2; exit 2 ;;
esac

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

# Standalone Reports server (system component): name = component directory,
# its own rwserver.conf under components/ReportsServerComponent/<name>/.
# RWSERVER_CONF from environment.conf may point to the in-process server of
# WLS_REPORTS (applications/reports_*/configuration) - prefer the component.
RS_COMP_NAME="${OVERRIDE_SERVER:-${REPORTS_SERVER_NAME:-}}"
if [ -z "$RS_COMP_NAME" ] && [ -f "$DOMAIN_HOME/config/config.xml" ]; then
    RS_COMP_NAME="$(awk '
        /<system-component>/ { n=""; t="" }
        /<name>/ && n=="" { n=$0; gsub(/.*<name>|<\/name>.*/, "", n) }
        /<component-type>ReportsServerComponent</ { t="R" }
        /<\/system-component>/ { if (t=="R") { print n; exit } }
    ' "$DOMAIN_HOME/config/config.xml")"
fi
_comp_conf="$DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent/${RS_COMP_NAME}/rwserver.conf"
if [ -n "$RS_COMP_NAME" ] && [ -f "$_comp_conf" ]; then
    RWSERVER_CONF="$_comp_conf"
else
    RWSERVER_CONF="${RWSERVER_CONF:-}"
fi
unset _comp_conf

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
    # 12c/14c files carry no name attribute - use the component name
    [ -z "$RS_NAME" ] && RS_NAME="$RS_COMP_NAME"

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

# Standalone Reports server (system component, started by the Node Manager):
# process "rwserver server=<name>"; its engines are Java child processes
# (14.1.2 - there is no "rwengine" process name any more)
RWS_PID=""
if [ -n "${RS_NAME:-}" ]; then
    RWS_PID="$(pgrep -f "rwserver server=${RS_NAME}( |\$)" 2>/dev/null | head -1)"
fi
if [ -n "$RWS_PID" ]; then
    ok "Reports server '${RS_NAME}' process RUNNING  (PID $RWS_PID)"
    RWENG_COUNT="$(pgrep -P "$RWS_PID" 2>/dev/null | wc -l | tr -d ' ')"
    RWENG_PIDS="$(pgrep -d ',' -P "$RWS_PID" 2>/dev/null || printf "")"
else
    [ -n "${RS_NAME:-}" ] && warn "Reports server process 'rwserver server=${RS_NAME}' not found"
    # in-process server / older releases: native rwengine processes
    RWENG_COUNT="$(pgrep -f "rwengine" 2>/dev/null | wc -l | tr -d ' ')"
    RWENG_PIDS="$(pgrep -d ',' -f "rwengine" 2>/dev/null || printf "")"
fi

if [ "${RWENG_COUNT:-0}" -gt 0 ]; then
    ok "Engine processes: ${RWENG_COUNT}  (PID: ${RWENG_PIDS})"

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
        warn "No engine processes found – engines may still be initializing"
        info "Check: pgrep -a -P <rwserver PID>"
    else
        info "No engine processes (WLS managed server not running)"
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

    # --- authid (see header "Auth") ---------------------------------------------
    AUTH_USER="" AUTH_PWD="" AUTH_SRC=""
    _load_mon() {
        local f="$ROOT_DIR/reports_users.conf.des3"
        [ -f "$f" ] && load_secrets_file "$f" > /dev/null 2>&1 \
            && [ -n "${REPORTS_MON_USER:-}" ] && [ -n "${REPORTS_MON_PWD:-}" ] || return 1
        AUTH_USER="$REPORTS_MON_USER"; AUTH_PWD="$REPORTS_MON_PWD"
        AUTH_SRC="monitoring user (reports_users.conf.des3)"
    }
    _load_admin() {
        local f="$ROOT_DIR/reports_admin_sec.conf.des3"
        [ -f "$f" ] && load_secrets_file "$f" > /dev/null 2>&1 \
            && [ -n "${REPORTS_ADMIN_USER:-}" ] && [ -n "${REPORTS_ADMIN_PWD:-}" ] || return 1
        AUTH_USER="$REPORTS_ADMIN_USER"; AUTH_PWD="$REPORTS_ADMIN_PWD"
        AUTH_SRC="Reports server admin <identifier> (reports_admin_sec.conf.des3)"
    }
    case "$AUTH_MODE" in
        mon)   _load_mon   || warn "Monitoring user not found in reports_users.conf.des3 (12-oracle_reports_users.sh)" ;;
        admin) _load_admin || warn "Reports server admin not found in reports_admin_sec.conf.des3 (13-oracle_setup_reports.sh)" ;;
        auto)
            if [ "${REPORTS_SECURITY:-ldap}" = "ldap" ]; then
                _load_mon || _load_admin
            else
                _load_admin || _load_mon
            fi ;;
    esac
    unset REPORTS_MON_PWD REPORTS_EXEC_PWD REPORTS_ADMIN_PWD
    if [ -n "$AUTH_USER" ]; then
        printf "  %-26s %s  (%s)\n" "authid:" "$AUTH_USER/****" "$AUTH_SRC" | tee -a "${LOG_FILE:-/dev/null}"
    else
        printf "  %-26s %s\n" "authid:" "none (--auth ${AUTH_MODE})" | tee -a "${LOG_FILE:-/dev/null}"
    fi

    # One request; URL incl. authid via curl config on stdin (not in argv)
    _tmp_body="$(mktemp)"
    HTTP_CODE="$( {
        printf 'url = "%s"\n' "$STATUS_URL"
        if [ -n "$AUTH_USER" ]; then
            printf 'get\n'
            printf 'data-urlencode = "authid=%s/%s"\n' "$AUTH_USER" "$AUTH_PWD"
        fi
    } | curl -s --connect-timeout 5 --max-time 30 -K - -o "$_tmp_body" -w "%{http_code}" 2>/dev/null )"
    HTTP_XML="$(cat "$_tmp_body" 2>/dev/null)"
    rm -f "$_tmp_body"
    AUTH_PWD=""
    REP_ERR="$(printf '%s' "$HTTP_XML" | sed -n 's/.*<error code="\([0-9]*\)"[^>]*message="\([^"]*\)".*/REP-\1 \2/p' | head -1)"
    [ -z "$REP_ERR" ] && REP_ERR="$(printf '%s' "$HTTP_XML" | grep -o 'REP-[0-9]*[^<]\{0,80\}' | head -1)"

    case "$HTTP_CODE" in
        200)
            if [ -n "$REP_ERR" ]; then
                fail "rwservlet answered with an error: $REP_ERR"
                case "$REP_ERR" in
                    REP-52262*) info "  Diagnostic output disabled for this user – unsecured server: use --auth admin (<identifier>); secured: monUser needs RW_MONITOR" ;;
                    REP-50171*) info "  Authentication failed – wrong password in the .des3 file, or (securityId without LDAP identity store) see doc 13 Step 5a" ;;
                    REP-56071*) info "  User not authorized for web commands – role RW_MONITOR / WebCommandPermission missing (12-oracle_reports_users.sh)" ;;
                esac
            else
                ok "rwservlet reachable (HTTP 200)"
                _parse_rwservlet_xml "$HTTP_XML"
            fi
            ;;
        499)
            fail "HTTP 499 – login required (secured Reports server) and no valid authid"
            info "  Store the monitoring user: 09-Install/12-oracle_reports_users.sh"
            ;;
        000)
            warn "No response from rwservlet – WLS_REPORTS not running or port wrong?"
            info "Check port: ss -tlnp | grep ${WLS_REPORTS_PORT}"
            ;;
        401|403)
            warn "HTTP ${HTTP_CODE} – Authentication required on rwservlet"
            info "  Try --auth mon / --auth admin (credentials from the *.des3 files)"
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
