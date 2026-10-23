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

# shellcheck source=reports_server_lib.sh
source "$SCRIPT_DIR/reports_server_lib.sh"

# =============================================================================
# Helper functions  (defined before their call sites)
# Shared Reports helpers (rws_*): reports_server_lib.sh
# =============================================================================

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
    srv_host="$(  rws_xval "$xml" "host")"
    srv_pid="$(   rws_xval "$xml" "processId")"
    start_ms="$(  rws_xval "$xml" "startTime")"
    is_secure="$( rws_xval "$xml" "isSecure")"
    avg_auth="$(  rws_xval "$xml" "avgAuthTime")"
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
        eid="$(   rws_xline_attr "$_eline" "id")"
        eact="$(  rws_xline_attr "$_eline" "activeEngine")"
        erun="$(  rws_xline_attr "$_eline" "runningEngine")"
        ebusy="$( rws_xline_attr "$_eline" "totalBusyEngines")"
        eidle="$( rws_xline_attr "$_eline" "totalIdleEngines")"
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
            iname="$(  rws_xline_attr "$_iline" "name")"
            ipid="$(   rws_xline_attr "$_iline" "processId")"
            istatus="$(rws_xline_attr "$_iline" "status")"
            ijob="$(   rws_xline_attr "$_iline" "runJobId")"
            iidle="$(  rws_xline_attr "$_iline" "idleTime")"
            injobs="$( rws_xline_attr "$_iline" "numJobsRun")"
            ilife="$(  rws_xline_attr "$_iline" "lifeLeft")"
            inls="$(   rws_xline_attr "$_iline" "nls")"
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
    p_ok="$(    rws_xprop "$xml" "successfulJobs")"
    p_cur="$(   rws_xprop "$xml" "currentJobs")"
    p_fut="$(   rws_xprop "$xml" "futureJobs")"
    p_trans="$( rws_xprop "$xml" "transferredJobs")"
    p_fail="$(  rws_xprop "$xml" "failedJobs")"
    p_long="$(  rws_xprop "$xml" "longRunningJobs")"
    p_run="$(   rws_xprop "$xml" "potentialRunawayJobs")"
    p_resp="$(  rws_xprop "$xml" "averageResponseTime")"
    p_elap="$(  rws_xprop "$xml" "averageElapsedTime")"
    p_queue="$( rws_xprop "$xml" "avgQueuingTime")"

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
        --auth)
            # without a value "shift 2" fails and the loop never ends (found 2026-10-23)
            [ -n "${2:-}" ] || { printf "\033[31mERROR\033[0m --auth needs a mode: auto|mon|admin|none\n" >&2; exit 2; }
            AUTH_MODE="${2,,}"; shift 2 ;;
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

WLS_REPORTS_SERVER="${OVERRIDE_SERVER:-$(rws_detect_wls_server)}"

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

# Standalone Reports server (system component) first – RWSERVER_CONF from
# environment.conf may point to the in-process server of WLS_REPORTS
rws_find_conf "${OVERRIDE_SERVER:-}"
RS_COMP_NAME="$RWS_COMP_NAME"

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
    CFG_MIN_ENGINES="$(rws_engine_attr "$RWSERVER_CONF" "minEngine")"
    CFG_MAX_ENGINES="$(rws_engine_attr "$RWSERVER_CONF" "maxEngine")"
    CFG_MAX_IDLE="$(   rws_engine_attr "$RWSERVER_CONF" "maxIdle")"
    CFG_ENGINE_TYPE="$(rws_engine_attr "$RWSERVER_CONF" "engineType")"

    printf "  %-26s %s\n" "Config file:"  "$RWSERVER_CONF"           | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "Server name:"  "${RS_NAME:-(not found)}"  | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "Engine type:"  "${CFG_ENGINE_TYPE:--}"    | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "minEngine:"    "${CFG_MIN_ENGINES:--}"    | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "maxEngine:"    "${CFG_MAX_ENGINES:--}"    | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "maxIdle:"      "${CFG_MAX_IDLE:--}"       | tee -a "${LOG_FILE:-/dev/null}"
fi

# =============================================================================
# 1b. Web command security (doc 81, tests A-D 2026-10-23)
# =============================================================================
if [ -n "$RWSERVER_CONF" ] && [ -f "$RWSERVER_CONF" ]; then
    section "Web Command Security (rwserver.conf / rwservlet.properties)"
    if grep -q '<job[^>]*jobType="report"[^>]*securityId=' "$RWSERVER_CONF"; then
        ok "  securityId on the report job – secured server (roles: monUser/RW_MONITOR for status)"
    else
        info "  no securityId – unsecured server: web commands only for the <identifier> admin"
    fi
    _idl="$(grep -m1 '<identifier' "$RWSERVER_CONF")"
    if [ -z "$_idl" ]; then
        warn "  <identifier> missing – nobody can use getserverinfo/showjobs/stopserver on an unsecured server (test A)"
        info "    09-Install/13-oracle_setup_reports.sh --apply (reports_admin_sec.conf.des3)"
    elif printf '%s' "$_idl" | grep -q '<identifier[^>]*>[[:space:]]*</identifier>'; then
        fail "  <identifier> EMPTY – the Reports server cannot start (REP-50125 NullPointerException, restart loop, test B)"
        info "    09-Install/13-oracle_setup_reports.sh --apply or Reports_kochbuch_de.txt 9.7"
    elif printf '%s' "$_idl" | grep -q 'encrypted="yes"'; then
        ok "  <identifier> set (encrypted by the server)"
    else
        info "  <identifier> set, still clear text – the server encrypts it at its next start"
    fi
    _rwp="$(ls "$DOMAIN_HOME"/config/fmwconfig/servers/*/applications/reports_*/configuration/rwservlet.properties 2>/dev/null | head -1)"
    if [ -n "$_rwp" ]; then
        _wca="$(sed -n 's:.*<webcommandaccess>\([^<]*\)</webcommandaccess>.*:\1:p' "$_rwp" | head -1)"
        _sso="$(sed -n 's:.*<singlesignon>\([^<]*\)</singlesignon>.*:\1:p' "$_rwp" | head -1)"
        case "${_wca:-no}" in
            no|L0|L1) ok "$(printf "  webcommandaccess=%s, singlesignon=%s" "${_wca:-(default no)}" "${_sso:-(default)}")" ;;
            *) fail "$(printf "  webcommandaccess=%s – every web command (getserverinfo, showjobs, showenv, showmap, killjobid) WITHOUT login, also through Nginx (test C)" "$_wca")"
               info "    set L1 (09-Install/13-oracle_setup_reports.sh --apply), restart WLS_REPORTS" ;;
        esac
    fi
    unset _idl _rwp _wca _sso
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
RWS_PID="$(rws_server_pid "${RS_NAME:-}")"
if [ -n "$RWS_PID" ]; then
    ok "Reports server '${RS_NAME}' process RUNNING  (PID $RWS_PID)"
else
    [ -n "${RS_NAME:-}" ] && warn "Reports server process 'rwserver server=${RS_NAME}' not found"
fi
# in-process server / older releases (no rwserver PID): native rwengine processes
RWENG_PIDS="$(rws_engine_pids "$RWS_PID")"
RWENG_COUNT=0
[ -n "$RWENG_PIDS" ] && RWENG_COUNT="$(printf '%s\n' "$RWENG_PIDS" | tr ',' '\n' | wc -l)"

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

[ -z "$WLS_REPORTS_PORT" ] && WLS_REPORTS_PORT="$(rws_wls_port "$WLS_REPORTS_SERVER")"

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

    rws_fetch_serverinfo "$STATUS_URL" "$AUTH_MODE"
    if [ -n "$RWS_AUTH_USER" ]; then
        printf "  %-26s %s  (%s)\n" "authid:" "$RWS_AUTH_USER/****" "$RWS_AUTH_SRC" | tee -a "${LOG_FILE:-/dev/null}"
    else
        printf "  %-26s %s\n" "authid:" "none (--auth ${AUTH_MODE})" | tee -a "${LOG_FILE:-/dev/null}"
    fi
    if rws_http_verdict; then
        _parse_rwservlet_xml "$RWS_HTTP_XML"
    elif [ "$RWS_HTTP_CODE" = "000" ]; then
        info "Check port: ss -tlnp | grep ${WLS_REPORTS_PORT}"
    fi
fi

# =============================================================================
# Summary
# =============================================================================

print_summary
exit "$EXIT_CODE"
