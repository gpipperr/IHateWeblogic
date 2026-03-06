#!/bin/bash
# =============================================================================
# Script   : engine_perf_analyse.sh
# Purpose  : Analyse Oracle Reports Server performance:
#            - Job statistics + response times via getserverinfo XML
#            - Live engine pool state (idle/busy per engine instance)
#            - WLS_REPORTS log scan for ORA- / REP- errors and OOM events
#            - Consolidated recommendations
# Call     : ./engine_perf_analyse.sh
#            ./engine_perf_analyse.sh --port 9012
#            ./engine_perf_analyse.sh --server repserver01
#            ./engine_perf_analyse.sh --lines 1000
#            ./engine_perf_analyse.sh --no-http
# Options  : --port   N    WLS_REPORTS listen port (auto-detect from config.xml)
#            --server NAME Reports Server name (auto-detect from rwserver.conf)
#            --lines  N    Last N log lines to scan (default: 500)
#            --no-http     Skip HTTP getserverinfo call
#            --help        Show usage
# Requires : curl (HTTP sections), pgrep, awk, sed
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 05-ReportsPerformance/README.md
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
# XML helper functions
# =============================================================================

# Extract element value <tag>value</tag> from an XML string (not a file)
_xval()      { printf "%s" "$1" | sed -n "s|.*<${2}>\([^<]*\)</${2}>.*|\1|p" | head -1; }

# Extract a named attribute from a single XML tag line
_xline_attr() { printf "%s" "$1" | sed -n "s/.*[[:space:]]${2}=\"\([^\"]*\)\".*/\1/p"; }

# Extract the value of <property name="N" value="V"/> from an XML string
_xprop()     { printf "%s" "$1" | grep "name=\"${2}\"" | sed -n 's/.*value="\([^"]*\)".*/\1/p' | head -1; }

# =============================================================================
# Engine configuration helpers (from rwserver.conf)
# =============================================================================

_xml_attr() {
    local file="$1"
    local attr="$2"
    { tr -d '\n' < "$file"; printf "\n"; } \
        | sed -n "s/.*[[:space:]]${attr}=\"\([^\"]*\)\".*/\1/p"
}
_engine_attr() {
    local file="$1"; local base="$2"; local val
    val="$(_xml_attr "$file" "${base}")"
    [ -z "$val" ] && val="$(_xml_attr "$file" "${base}s")"
    printf "%s" "$val"
}

# =============================================================================
# Arguments
# =============================================================================

OVERRIDE_PORT=""
OVERRIDE_SERVER=""
LOG_LINES=500
HTTP_SKIP=0

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-24s %s\n" "--port N"      "WLS_REPORTS listen port (default: auto-detect)"
    printf "  %-24s %s\n" "--server NAME" "Reports Server name (default: from rwserver.conf)"
    printf "  %-24s %s\n" "--lines N"     "Last N log lines to scan (default: 500)"
    printf "  %-24s %s\n" "--no-http"     "Skip HTTP getserverinfo call"
    printf "  %-24s %s\n" "--help"        "Show this help"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --port)    OVERRIDE_PORT="$2";   shift 2 ;;
        --server)  OVERRIDE_SERVER="$2"; shift 2 ;;
        --lines)   LOG_LINES="$2";       shift 2 ;;
        --no-http) HTTP_SKIP=1;          shift   ;;
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
section "Reports Engine Performance Analysis – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-26s %s\n" "Host:"        "$(hostname -f 2>/dev/null || hostname)" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "DOMAIN_HOME:" "${DOMAIN_HOME}"                          | tee -a "${LOG_FILE:-/dev/null}"
printLine

# =============================================================================
# Load rwserver.conf values (needed for context and recommendations)
# =============================================================================

RWSERVER_CONF="${RWSERVER_CONF:-}"
if [ -z "$RWSERVER_CONF" ] || [ ! -f "$RWSERVER_CONF" ]; then
    RWSERVER_CONF="$(find "${DOMAIN_HOME}/config" -name "rwserver.conf" 2>/dev/null | head -1)"
fi

CFG_MIN="-"; CFG_MAX="-"; CFG_JVM=""
RS_NAME="${OVERRIDE_SERVER:-}"
if [ -n "$RWSERVER_CONF" ] && [ -f "$RWSERVER_CONF" ]; then
    [ -z "$RS_NAME" ] && RS_NAME="$(sed -n 's/.*<server[^>]*name="\([^"]*\)".*/\1/p' \
        "$RWSERVER_CONF" 2>/dev/null | head -1)"
    CFG_MIN="$(_engine_attr "$RWSERVER_CONF" "minEngine")"
    CFG_MAX="$(_engine_attr "$RWSERVER_CONF" "maxEngine")"
    CFG_JVM="$(_xml_attr    "$RWSERVER_CONF" "jvmOptions")"
    info "Using rwserver.conf: $RWSERVER_CONF"
else
    warn "rwserver.conf not found – configuration context unavailable"
fi

# =============================================================================
# HTTP: getserverinfo XML
# =============================================================================

HTTP_XML=""
HTTP_CODE=""
STATUS_URL=""

if [ "$HTTP_SKIP" -eq 0 ]; then

    # Detect WLS_REPORTS port
    WLS_REPORTS_PORT="${OVERRIDE_PORT:-}"
    if [ -z "$WLS_REPORTS_PORT" ]; then
        CONFIG_XML="$DOMAIN_HOME/config/config.xml"
        if [ -f "$CONFIG_XML" ]; then
            WLS_REPORTS_SRV="${OVERRIDE_SERVER:-WLS_REPORTS}"
            WLS_REPORTS_PORT="$(awk -v srv="$WLS_REPORTS_SRV" '
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
        fi
        [ -z "$WLS_REPORTS_PORT" ] && WLS_REPORTS_PORT="9002"
    fi

    SERVLET_BASE="http://localhost:${WLS_REPORTS_PORT}/reports/rwservlet"
    if [ -n "${RS_NAME:-}" ]; then
        STATUS_URL="${SERVLET_BASE}/getserverinfo?server=${RS_NAME}&statusformat=XML"
    else
        STATUS_URL="${SERVLET_BASE}/getserverinfo?statusformat=XML"
    fi

    if ! command -v curl > /dev/null 2>&1; then
        warn "curl not found – HTTP analysis skipped (install: sudo dnf install curl)"
        HTTP_SKIP=1
    else
        info "Fetching: $STATUS_URL"
        HTTP_XML="$(curl -s --connect-timeout 5 --max-time 10 "$STATUS_URL" 2>/dev/null)"
        HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 5 --max-time 10 "$STATUS_URL" 2>/dev/null)"

        case "$HTTP_CODE" in
            200) ok "rwservlet reachable (HTTP 200)" ;;
            000) warn "No response from rwservlet (port ${WLS_REPORTS_PORT}) – server running?"; HTTP_SKIP=1 ;;
            401|403)
                warn "HTTP ${HTTP_CODE} – authentication required; run with secured credentials"
                HTTP_SKIP=1
                ;;
            404) warn "HTTP 404 – rwservlet not found at: $STATUS_URL"; HTTP_SKIP=1 ;;
            *)   warn "HTTP ${HTTP_CODE} – unexpected response"; HTTP_SKIP=1 ;;
        esac
    fi
fi

# =============================================================================
# 1. Job Statistics
# =============================================================================

printLine
section "Job Statistics (since server start)"

if [ "$HTTP_SKIP" -eq 0 ] && [ -n "$HTTP_XML" ]; then
    p_ok="$(    _xprop "$HTTP_XML" "successfulJobs")"
    p_cur="$(   _xprop "$HTTP_XML" "currentJobs")"
    p_fut="$(   _xprop "$HTTP_XML" "futureJobs")"
    p_fail="$(  _xprop "$HTTP_XML" "failedJobs")"
    p_long="$(  _xprop "$HTTP_XML" "longRunningJobs")"
    p_run="$(   _xprop "$HTTP_XML" "potentialRunawayJobs")"
    p_trans="$( _xprop "$HTTP_XML" "transferredJobs")"

    printf "  %-28s %s\n" "Successful jobs:"        "${p_ok:--}"    | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-28s %s\n" "Failed jobs:"            "${p_fail:--}"  | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-28s %s\n" "Current jobs:"           "${p_cur:--}"   | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-28s %s\n" "Future (scheduled) jobs:""${p_fut:--}"   | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-28s %s\n" "Transferred jobs:"       "${p_trans:--}" | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-28s %s\n" "Long running jobs:"      "${p_long:--}"  | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-28s %s\n" "Potential runaway jobs:"  "${p_run:--}"   | tee -a "${LOG_FILE:-/dev/null}"

    # Error rate
    if [ -n "$p_ok" ] && [ -n "$p_fail" ] \
       && [ "$p_ok"   -ge 0 ] 2>/dev/null \
       && [ "$p_fail" -ge 0 ] 2>/dev/null; then
        total=$(( p_ok + p_fail ))
        if [ "$total" -gt 0 ]; then
            pct=$(( p_fail * 100 / total ))
            printf "  %-28s %s%%  (%s of %s)\n" "Failure rate:" "$pct" "$p_fail" "$total" \
                | tee -a "${LOG_FILE:-/dev/null}"
            if [ "$pct" -ge 5 ]; then
                fail "$(printf "Failure rate %s%% >= 5%% – investigate reports errors" "$pct")"
            elif [ "$p_fail" -gt 0 ]; then
                warn "$(printf "%s failed job(s) – check Reports Server logs (REP- errors)" "$p_fail")"
            else
                ok "No failed jobs"
            fi
        fi
    fi

    [ -n "$p_run" ] && [ "$p_run" != "-" ] && [ "$p_run" -gt 0 ] 2>/dev/null && \
        fail "$(printf "%s potential runaway job(s) – investigate immediately" "$p_run")"
    [ -n "$p_long" ] && [ "$p_long" != "-" ] && [ "$p_long" -gt 0 ] 2>/dev/null && \
        warn "$(printf "%s long-running job(s) – check for slow DB queries or large reports" "$p_long")"
    [ "${p_cur:-0}" -gt 0 ] 2>/dev/null && \
        ok "$(printf "%s job(s) currently executing" "$p_cur")"
else
    info "Job statistics unavailable (HTTP call skipped or failed)"
fi

# =============================================================================
# 2. Response Times
# =============================================================================

printLine
section "Response Times (averages since server start)"

BOTTLENECK_ENGINE=0   # flag for recommendations

if [ "$HTTP_SKIP" -eq 0 ] && [ -n "$HTTP_XML" ]; then
    p_resp="$(  _xprop "$HTTP_XML" "averageResponseTime")"
    p_elap="$(  _xprop "$HTTP_XML" "averageElapsedTime")"
    p_queue="$( _xprop "$HTTP_XML" "avgQueuingTime")"

    printf "  %-32s %s ms\n" "Avg response time (end-to-end):"  "${p_resp:--}"  | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-32s %s ms\n" "Avg elapsed time (engine work):"  "${p_elap:--}"  | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-32s %s ms\n" "Avg queuing time (wait for eng):" "${p_queue:--}" | tee -a "${LOG_FILE:-/dev/null}"

    if [ -n "$p_queue" ] && [ -n "$p_elap" ] \
       && [ "$p_queue" -gt 0 ] 2>/dev/null && [ "$p_elap" -gt 0 ] 2>/dev/null; then
        if [ "$p_queue" -gt "$p_elap" ] 2>/dev/null; then
            warn "Queuing time (${p_queue} ms) > elapsed time (${p_elap} ms) – queue bottleneck"
            info "  Engines are saturated; reports wait longer in queue than they take to run"
            info "  Recommendation: increase maxEngine in rwserver.conf"
            BOTTLENECK_ENGINE=1
        else
            ok "Queuing time within normal range (${p_queue} ms vs elapsed ${p_elap} ms)"
        fi
    fi

    # Connection pool
    c_used="$(  printf "%s" "$HTTP_XML" | sed -n 's/.*<connection[^>]*connectionsUsed="\([^"]*\)".*/\1/p'      | head -1)"
    c_avail="$( printf "%s" "$HTTP_XML" | sed -n 's/.*<connection[^>]*connectionsAvailable="\([^"]*\)".*/\1/p' | head -1)"
    if [ -n "$c_used" ] || [ -n "$c_avail" ]; then
        printf "  %-32s %s\n" "Connections used:"      "${c_used:--}"  | tee -a "${LOG_FILE:-/dev/null}"
        printf "  %-32s %s\n" "Connections available:" "${c_avail:--}" | tee -a "${LOG_FILE:-/dev/null}"
        if [ -n "$c_avail" ] && [ "$c_avail" = "0" ] \
           && [ -n "$c_used" ]  && [ "$c_used" -gt 0 ] 2>/dev/null; then
            warn "Connection pool exhausted (used=${c_used}, available=0)"
        fi
    fi
else
    info "Response time data unavailable (HTTP call skipped or failed)"
fi

# =============================================================================
# 3. Live Engine Pool
# =============================================================================

printLine
section "Live Engine Pool"

if [ "$HTTP_SKIP" -eq 0 ] && [ -n "$HTTP_XML" ]; then
    # Summary line per <engine ...>
    while IFS= read -r _eline; do
        [ -z "$_eline" ] && continue
        eid="$(   _xline_attr "$_eline" "id")"
        eact="$(  _xline_attr "$_eline" "activeEngine")"
        erun="$(  _xline_attr "$_eline" "runningEngine")"
        ebusy="$( _xline_attr "$_eline" "totalBusyEngines")"
        eidle="$( _xline_attr "$_eline" "totalIdleEngines")"
        printf "\n  Engine \033[1m%-20s\033[0m  Active:%-3s  Running:%-3s  Busy:%-3s  Idle:%-3s\n" \
            "${eid:-(?)}" "${eact:--}" "${erun:--}" "${ebusy:--}" "${eidle:--}" \
            | tee -a "${LOG_FILE:-/dev/null}"
        if [ "${ebusy:-0}" -gt 0 ] && [ "${eidle:-1}" -eq 0 ] 2>/dev/null; then
            warn "Engine '${eid}' – all instances busy, consider increasing maxEngine"
            BOTTLENECK_ENGINE=1
        fi
    done < <(printf "%s" "$HTTP_XML" | grep '<engine ')

    # Per-instance table
    inst_lines="$(printf "%s" "$HTTP_XML" | grep '<engineInstance')"
    if [ -n "$inst_lines" ]; then
        printf "\n  \033[1m%-14s %-8s %-8s %-14s %-8s %-9s %-9s %s\033[0m\n" \
            "Instance" "PID" "Status" "Job ID" "Idle(s)" "Jobs run" "Life left" "NLS" \
            | tee -a "${LOG_FILE:-/dev/null}"
        while IFS= read -r _iline; do
            [ -z "$_iline" ] && continue
            iname="$(  _xline_attr "$_iline" "name")"
            ipid="$(   _xline_attr "$_iline" "processId")"
            istatus="$(_xline_attr "$_iline" "status")"
            ijob="$(   _xline_attr "$_iline" "runJobId")"
            iidle="$(  _xline_attr "$_iline" "idleTime")"
            injobs="$( _xline_attr "$_iline" "numJobsRun")"
            ilife="$(  _xline_attr "$_iline" "lifeLeft")"
            inls="$(   _xline_attr "$_iline" "nls")"
            case "$istatus" in
                1) status_str="IDLE" ;;
                2) status_str=$'\033[33mBUSY\033[0m' ;;
                0) status_str=$'\033[31mDEAD\033[0m' ;;
                *) status_str="UNK(${istatus})" ;;
            esac
            [ "$ijob" = "-1" ] && ijob="(none)"
            printf "  %-14s %-8s %-8b %-14s %-8s %-9s %-9s %s\n" \
                "${iname:--}" "${ipid:--}" "$status_str" "$ijob" \
                "${iidle:--}" "${injobs:--}" "${ilife:--}" "${inls:--}" \
                | tee -a "${LOG_FILE:-/dev/null}"
        done <<< "$inst_lines"
    fi
else
    # Fallback: show pgrep count only
    RWENG_COUNT="$(pgrep -f "rwengine" 2>/dev/null | wc -l | tr -d ' ')"
    printf "  %-26s %s\n" "Running rwengine processes:" "$RWENG_COUNT" | tee -a "${LOG_FILE:-/dev/null}"
    info "(HTTP not available – detailed engine state requires getserverinfo)"
fi

# =============================================================================
# 4. Log Analysis
# =============================================================================

printLine
section "Log Analysis (last ${LOG_LINES} lines)"

LOG_ORA_COUNT=0
LOG_REP_COUNT=0
LOG_OOM_COUNT=0
LOG_ENG_START=0

# Locate WLS_REPORTS log directory
LOG_DIR="${DOMAIN_HOME}/servers/WLS_REPORTS/logs"
if [ ! -d "$LOG_DIR" ]; then
    # Try to find it with a wildcard for server name
    LOG_DIR="$(find "${DOMAIN_HOME}/servers" -maxdepth 2 -name "*.log" 2>/dev/null \
        | grep -i "report" | head -1 | xargs -I{} dirname {})"
fi

if [ -z "$LOG_DIR" ] || [ ! -d "$LOG_DIR" ]; then
    warn "WLS_REPORTS log directory not found – log analysis skipped"
    info "  Expected: ${DOMAIN_HOME}/servers/WLS_REPORTS/logs/"
else
    ok "Log directory: $LOG_DIR"

    # Find the most recent server log
    LOGFILE="$(ls -t "${LOG_DIR}"/*.log 2>/dev/null | head -1)"
    if [ -z "$LOGFILE" ]; then
        warn "No .log file found in $LOG_DIR"
    else
        info "Scanning: $LOGFILE (last ${LOG_LINES} lines)"
        LOG_TAIL="$(tail -n "$LOG_LINES" "$LOGFILE" 2>/dev/null)"

        LOG_ORA_COUNT="$( printf "%s" "$LOG_TAIL" | grep -c 'ORA-'             2>/dev/null || printf 0)"
        LOG_REP_COUNT="$( printf "%s" "$LOG_TAIL" | grep -c 'REP-'             2>/dev/null || printf 0)"
        LOG_OOM_COUNT="$( printf "%s" "$LOG_TAIL" | grep -c 'OutOfMemoryError' 2>/dev/null || printf 0)"
        LOG_ENG_START="$( printf "%s" "$LOG_TAIL" | grep -ic 'engine.*start'   2>/dev/null || printf 0)"

        printf "  %-32s %s\n" "ORA- errors:"              "$LOG_ORA_COUNT" | tee -a "${LOG_FILE:-/dev/null}"
        printf "  %-32s %s\n" "REP- errors:"              "$LOG_REP_COUNT" | tee -a "${LOG_FILE:-/dev/null}"
        printf "  %-32s %s\n" "OutOfMemoryError events:"  "$LOG_OOM_COUNT" | tee -a "${LOG_FILE:-/dev/null}"
        printf "  %-32s %s\n" "Engine start events:"      "$LOG_ENG_START" | tee -a "${LOG_FILE:-/dev/null}"

        [ "$LOG_ORA_COUNT" -gt 0 ] 2>/dev/null && \
            warn "$(printf "%s ORA- error(s) in last %s log lines – DB connectivity issue?" \
                "$LOG_ORA_COUNT" "$LOG_LINES")"
        [ "$LOG_REP_COUNT" -gt 0 ] 2>/dev/null && \
            warn "$(printf "%s REP- error(s) in last %s log lines" "$LOG_REP_COUNT" "$LOG_LINES")"
        [ "$LOG_OOM_COUNT" -gt 0 ] 2>/dev/null && \
            fail "$(printf "%s OutOfMemoryError event(s) – engine heap too small" "$LOG_OOM_COUNT")"
        [ "$LOG_ORA_COUNT" -eq 0 ] && [ "$LOG_REP_COUNT" -eq 0 ] && [ "$LOG_OOM_COUNT" -eq 0 ] && \
            ok "No ORA- / REP- / OOM errors in last ${LOG_LINES} lines"

        # Show last 3 ORA- lines as sample
        if [ "$LOG_ORA_COUNT" -gt 0 ] 2>/dev/null; then
            printf "\n  Last ORA- occurrences:\n" | tee -a "${LOG_FILE:-/dev/null}"
            printf "%s" "$LOG_TAIL" | grep 'ORA-' | tail -3 \
                | while IFS= read -r ln; do
                    printf "    %s\n" "$ln" | tee -a "${LOG_FILE:-/dev/null}"
                  done
        fi
        if [ "$LOG_REP_COUNT" -gt 0 ] 2>/dev/null; then
            printf "\n  Last REP- occurrences:\n" | tee -a "${LOG_FILE:-/dev/null}"
            printf "%s" "$LOG_TAIL" | grep 'REP-' | tail -3 \
                | while IFS= read -r ln; do
                    printf "    %s\n" "$ln" | tee -a "${LOG_FILE:-/dev/null}"
                  done
        fi
    fi
fi

# =============================================================================
# 5. Recommendations
# =============================================================================

printLine
section "Recommendations"

RECS=0

if [ "$BOTTLENECK_ENGINE" -eq 1 ]; then
    RECS=$(( RECS + 1 ))
    printf "  [%d] \033[33mEngine bottleneck detected\033[0m\n" "$RECS" | tee -a "${LOG_FILE:-/dev/null}"
    printf "      → Increase maxEngine in rwserver.conf (current: %s)\n" "${CFG_MAX:--}" \
        | tee -a "${LOG_FILE:-/dev/null}"
    printf "      → Apply: ./05-ReportsPerformance/engine_perf_settings.sh --apply\n" \
        | tee -a "${LOG_FILE:-/dev/null}"
fi

if [ "$LOG_OOM_COUNT" -gt 0 ] 2>/dev/null; then
    JVM_XMX="$(printf "%s" "${CFG_JVM:-}" | grep -oE '\-Xmx[0-9]+[mMgG]' | head -1)"
    RECS=$(( RECS + 1 ))
    printf "  [%d] \033[31mOutOfMemoryError – engine heap exhausted\033[0m\n" "$RECS" \
        | tee -a "${LOG_FILE:-/dev/null}"
    printf "      → Current -Xmx: %s\n" "${JVM_XMX:-(not set)}" | tee -a "${LOG_FILE:-/dev/null}"
    printf "      → Increase -Xmx in jvmOptions in rwserver.conf\n" | tee -a "${LOG_FILE:-/dev/null}"
    printf "      → Apply: ./05-ReportsPerformance/engine_perf_settings.sh --apply\n" \
        | tee -a "${LOG_FILE:-/dev/null}"
fi

if [ "$LOG_ORA_COUNT" -gt 0 ] 2>/dev/null; then
    RECS=$(( RECS + 1 ))
    printf "  [%d] ORA- errors detected – DB connection issue\033[0m\n" "$RECS" \
        | tee -a "${LOG_FILE:-/dev/null}"
    printf "      → Run: ./02-Checks/db_connect_check.sh\n" | tee -a "${LOG_FILE:-/dev/null}"
fi

if [ "$LOG_REP_COUNT" -gt 0 ] 2>/dev/null; then
    RECS=$(( RECS + 1 ))
    printf "  [%d] REP- errors detected – Reports engine errors\033[0m\n" "$RECS" \
        | tee -a "${LOG_FILE:-/dev/null}"
    printf "      → Run: ./03-Logs/grep_logs.sh 'REP-'\n" | tee -a "${LOG_FILE:-/dev/null}"
fi

if [ "$RECS" -eq 0 ]; then
    ok "No performance issues detected"
fi

# =============================================================================
# Summary
# =============================================================================

print_summary
exit "$EXIT_CODE"
