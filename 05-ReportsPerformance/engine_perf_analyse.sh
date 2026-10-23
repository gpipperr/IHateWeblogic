#!/bin/bash
# =============================================================================
# Script   : engine_perf_analyse.sh
# Purpose  : Evaluate the load of the standalone Oracle Reports server:
#            - job statistics, failure rate, queuing share (getserverinfo XML)
#            - engine pool usage vs. maxEngine, dead / long-busy engines
#            - memory of the engine processes
#            - Reports server + engine logs (rwserver_diagnostic.log,
#              rwEng-N_diagnostic.log): ORA- / REP- / OutOfMemoryError
#            - consolidated recommendations
#            The plain status snapshot (is it running, which engines) is
#            01-Run/rwserver_status.sh – this script evaluates the numbers.
# Call     : ./engine_perf_analyse.sh
#            ./engine_perf_analyse.sh --port 9002
#            ./engine_perf_analyse.sh --server repserver01
#            ./engine_perf_analyse.sh --lines 2000
#            ./engine_perf_analyse.sh --no-http
# Options  : --port   N    WLS_REPORTS listen port (auto-detect from config.xml)
#            --server NAME Reports server component (default: REPORTS_SERVER_NAME)
#            --auth   MODE authid for getserverinfo: auto (default) | mon | admin | none
#            --lines  N    Last N lines per log file to scan (default: 1000)
#            --no-http     Skip the getserverinfo call (only processes + logs)
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

# shellcheck source=../01-Run/reports_server_lib.sh
source "$ROOT_DIR/01-Run/reports_server_lib.sh"
# shellcheck source=../03-Logs/log_locations.sh
source "$ROOT_DIR/03-Logs/log_locations.sh"

_show() { printf "  %-32s %s\n" "$1" "$2" | tee -a "${LOG_FILE:-/dev/null}"; }

# _fgt A B – A > B for decimal values (getserverinfo returns e.g. 2134.06)
_fgt() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { exit !(a+0 > b+0) }'; }

# =============================================================================
# Arguments
# =============================================================================

OVERRIDE_PORT=""
OVERRIDE_SERVER=""
AUTH_MODE="auto"
LOG_LINES=1000
HTTP_SKIP=0

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-24s %s\n" "--port N"      "WLS_REPORTS listen port (default: auto-detect)"
    printf "  %-24s %s\n" "--server NAME" "Reports server component (default: REPORTS_SERVER_NAME)"
    printf "  %-24s %s\n" "--auth MODE"   "authid: auto (default) | mon | admin | none"
    printf "  %-24s %s\n" "--lines N"     "Last N lines per log file (default: 1000)"
    printf "  %-24s %s\n" "--no-http"     "Skip the getserverinfo call"
    printf "  %-24s %s\n" "--help"        "Show this help"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --port)    OVERRIDE_PORT="$2";   shift 2 ;;
        --server)  OVERRIDE_SERVER="$2"; shift 2 ;;
        --auth)    AUTH_MODE="${2,,}";   shift 2 ;;
        --lines)   LOG_LINES="$2";       shift 2 ;;
        --no-http) HTTP_SKIP=1;          shift   ;;
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
[[ "$LOG_LINES" =~ ^[0-9]+$ ]] || { printf "\033[31mERROR\033[0m --lines needs a number\n" >&2; exit 2; }

# =============================================================================
# Banner + configuration context
# =============================================================================

printLine
section "Reports Engine Performance Analysis – $(date '+%Y-%m-%d %H:%M:%S')"
_show "Host:"        "$(hostname -f 2>/dev/null || hostname)"
_show "DOMAIN_HOME:" "${DOMAIN_HOME}"

CFG_MIN="" CFG_MAX="" CFG_JVM=""
if rws_find_conf "$OVERRIDE_SERVER"; then
    CFG_MIN="$(rws_engine_attr "$RWSERVER_CONF" "minEngine")"
    CFG_MAX="$(rws_engine_attr "$RWSERVER_CONF" "maxEngine")"
    CFG_JVM="$(rws_engine_attr "$RWSERVER_CONF" "jvmOptions")"
    _show "Reports server:" "${RWS_COMP_NAME:-(unknown)}"
    _show "rwserver.conf:"  "$RWSERVER_CONF"
    _show "Engines min/max:" "${CFG_MIN:-0} / ${CFG_MAX:-1}"
else
    warn "rwserver.conf not found – configuration context unavailable"
fi
RS_NAME="${OVERRIDE_SERVER:-${RWS_COMP_NAME:-}}"
printLine

# Flags for the recommendations
REC_POOL=0 REC_FAIL=0 REC_OOM=0 REC_ORA=0 REC_REP=0 REC_DEAD=0 REC_QUEUE=0 REC_ERT=0

# =============================================================================
# getserverinfo
# =============================================================================

HTTP_OK=0
if [ "$HTTP_SKIP" -eq 0 ]; then
    section "getserverinfo (rwservlet)"
    if ! command -v curl > /dev/null 2>&1; then
        warn "curl not found – HTTP analysis skipped (install: sudo dnf install curl)"
    else
        WLS_REPORTS_SERVER="$(rws_detect_wls_server)"
        WLS_REPORTS_PORT="${OVERRIDE_PORT:-$(rws_wls_port "$WLS_REPORTS_SERVER")}"
        STATUS_URL="http://localhost:${WLS_REPORTS_PORT}/reports/rwservlet/getserverinfo?statusformat=XML"
        [ -n "$RS_NAME" ] && STATUS_URL="http://localhost:${WLS_REPORTS_PORT}/reports/rwservlet/getserverinfo?server=${RS_NAME}&statusformat=XML"
        _show "Status URL:" "$STATUS_URL"
        rws_fetch_serverinfo "$STATUS_URL" "$AUTH_MODE"
        _show "authid:" "$( [ -n "$RWS_AUTH_USER" ] && printf "%s/****  (%s)" "$RWS_AUTH_USER" "$RWS_AUTH_SRC" || printf "none (--auth %s)" "$AUTH_MODE")"
        rws_http_verdict && HTTP_OK=1
    fi
    printLine
fi
XML="$RWS_HTTP_XML"

# =============================================================================
# 1. Jobs
# =============================================================================

section "Jobs"

if [ "$HTTP_OK" -eq 1 ]; then
    p_ok="$(   rws_xprop "$XML" "successfulJobs")"
    p_fail="$( rws_xprop "$XML" "failedJobs")"
    p_cur="$(  rws_xprop "$XML" "currentJobs")"
    p_long="$( rws_xprop "$XML" "longRunningJobs")"
    p_run="$(  rws_xprop "$XML" "potentialRunawayJobs")"
    start_ms="$(rws_xval "$XML" "startTime")"
    [ -n "$start_ms" ] && _show "Reports server started:" "$(date -d "@$(( start_ms / 1000 ))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    _show "Successful / failed jobs:" "${p_ok:--} / ${p_fail:--}"
    _show "Current / long running / runaway:" "${p_cur:--} / ${p_long:--} / ${p_run:--}"

    total=$(( ${p_ok:-0} + ${p_fail:-0} ))
    if [ "$total" -gt 0 ]; then
        pct=$(( ${p_fail:-0} * 100 / total ))
        _show "Failure rate:" "$(printf "%s%%  (%s of %s)" "$pct" "${p_fail:-0}" "$total")"
        if [ "$pct" -ge 5 ]; then
            fail "$(printf "Failure rate %s%% >= 5%% – failing reports, not a tuning question (see logs below)" "$pct")"
            REC_FAIL=1
        elif [ "${p_fail:-0}" -gt 0 ]; then
            warn "$(printf "%s failed job(s)" "$p_fail")"
            REC_FAIL=1
        else
            ok "No failed jobs"
        fi
    else
        info "No jobs yet – job statistics not meaningful"
    fi
    [ "${p_run:-0}" -gt 0 ] 2>/dev/null && fail "$(printf "%s potential runaway job(s) – investigate immediately" "$p_run")"
    [ "${p_long:-0}" -gt 0 ] 2>/dev/null && warn "$(printf "%s long-running job(s) – slow SQL or large report?" "$p_long")"
else
    info "Job statistics unavailable (getserverinfo skipped or failed)"
fi

# =============================================================================
# 2. Response times
# =============================================================================

printLine
section "Response Times (averages)"

if [ "$HTTP_OK" -eq 1 ]; then
    p_resp="$(  rws_xprop "$XML" "averageResponseTime")"
    p_elap="$(  rws_xprop "$XML" "averageElapsedTime")"
    p_queue="$( rws_xprop "$XML" "avgQueuingTime")"
    _show "Avg response time (end-to-end):" "${p_resp:--} ms"
    _show "Avg elapsed time (engine):"      "${p_elap:--} ms"
    _show "Avg queuing time (wait):"        "${p_queue:--} ms"

    if _fgt "$p_resp" 0; then
        q_share="$(awk -v q="${p_queue:-0}" -v r="$p_resp" 'BEGIN { printf "%d", q*100/r }')"
        _show "Queuing share of response:" "${q_share}%"
        if [ "$q_share" -ge 50 ]; then
            warn "$(printf "Jobs spend %s%% of their response time waiting in the queue" "$q_share")"
            REC_QUEUE=1
        else
            ok "$(printf "Queuing share %s%% – jobs are not waiting for engines" "$q_share")"
        fi
    fi
    _fgt "$p_elap" 0 || info "averageElapsedTime is 0 – engine time not reported, judged via the queuing share instead"
else
    info "Response times unavailable"
fi

# =============================================================================
# 2b. Job run times (showjobs) vs. engineResponseTimeOut
# =============================================================================

printLine
section "Job Run Times (showjobs) vs. engineResponseTimeOut"

CFG_ERT="$(rws_engine_attr "${RWSERVER_CONF:-}" engineResponseTimeOut 2>/dev/null)"
if [ "$HTTP_OK" -eq 1 ]; then
    # all jobs only for the server admin <identifier> - monUser sees its own
    _sj="${STATUS_URL/getserverinfo/showjobs}"
    rws_fetch_serverinfo "$_sj" admin
    read -r _n _max _p95 <<< "$(rws_job_runtimes "$RWS_HTTP_XML")"
    if [ -z "${_n:-}" ]; then
        info "No finished jobs with timing information (showjobs)"
    else
        _show "Past jobs:"              "$_n"
        _show "Longest / 95 % run time:" "$(printf "%s s / %s s" "$_max" "$_p95")"
        _show "engineResponseTimeOut:"  "${CFG_ERT:-(not set)}${CFG_ERT:+ min}"
        _prop="$(rws_ert_proposal "$_max")"
        if [ -z "$CFG_ERT" ]; then
            warn "$(printf "engineResponseTimeOut not set – proposal %s min (2 x longest job, >= 5)" "$_prop")"
            REC_ERT=1
        elif [ "$_max" -ge $(( CFG_ERT * 60 )) ]; then
            warn "$(printf "Longest job (%s s) >= engineResponseTimeOut (%s min) – such a job would be killed; proposal %s min" "$_max" "$CFG_ERT" "$_prop")"
            REC_ERT=1
        else
            ok "$(printf "engineResponseTimeOut %s min covers the longest job (%s s); measured proposal %s min" "$CFG_ERT" "$_max" "$_prop")"
        fi
    fi
    unset _sj _n _max _p95
else
    info "showjobs unavailable (no getserverinfo)"
fi

# =============================================================================
# 3. Engine pool
# =============================================================================

printLine
section "Engine Pool Usage"

if [ "$HTTP_OK" -eq 1 ]; then
    e_maxused="$(printf "%s" "$XML" | sed -n 's/.*<engineInfo[^>]*maxEnginesUsed="\([^"]*\)".*/\1/p' | head -1)"
    e_avgused="$(printf "%s" "$XML" | sed -n 's/.*<engineInfo[^>]*avgEnginesUsed="\([^"]*\)".*/\1/p' | head -1)"
    c_used="$(   printf "%s" "$XML" | sed -n 's/.*<connection[^>]*connectionsUsed="\([^"]*\)".*/\1/p' | head -1)"
    c_avail="$(  printf "%s" "$XML" | sed -n 's/.*<connection[^>]*connectionsAvailable="\([^"]*\)".*/\1/p' | head -1)"
    _show "Engines used max / avg:" "${e_maxused:--} / ${e_avgused:--}  (maxEngine ${CFG_MAX:-?})"
    _show "Connections used / free:" "${c_used:--} / ${c_avail:--}"

    if [ -n "$e_maxused" ] && [ -n "$CFG_MAX" ] && [ "$e_maxused" -ge "$CFG_MAX" ] 2>/dev/null; then
        warn "$(printf "Engine pool reached maxEngine (%s) – reports had to wait for a free engine" "$CFG_MAX")"
        REC_POOL=1
    elif [ -n "$e_maxused" ]; then
        ok "$(printf "Pool never full (max %s of %s engines used)" "$e_maxused" "${CFG_MAX:-?}")"
    fi
    [ "${c_avail:-1}" = "0" ] && warn "Connection pool exhausted – raise maxConnect"

    # per instance: dead engines, engines busy for a long time, life left
    while IFS= read -r _l; do
        [ -z "$_l" ] && continue
        _n="$(rws_xline_attr "$_l" name)"; _st="$(rws_xline_attr "$_l" status)"
        _ex="$(rws_xline_attr "$_l" curJobExecTime)"; _jobs="$(rws_xline_attr "$_l" numJobsRun)"
        _life="$(rws_xline_attr "$_l" lifeLeft)"
        _show "  ${_n}:" "$(printf "status %s, jobs %s, life left %s, current job %s" \
            "$( case "$_st" in 1) printf IDLE;; 2) printf BUSY;; 0) printf DEAD;; *) printf "?%s" "$_st";; esac )" \
            "${_jobs:--}" "${_life:--}" "$( [ "${_ex:--1}" = "-1" ] && printf '-' || printf '%s ms' "$_ex")")"
        if [ "$_st" = "0" ]; then
            fail "Engine ${_n} is DEAD"; REC_DEAD=1
        fi
    done < <(printf "%s\n" "$XML" | grep '<engineInstance')
else
    info "Engine pool usage unavailable"
fi

# =============================================================================
# 4. Engine processes (memory)
# =============================================================================

printLine
section "Engine Processes"

RWS_PID="$(rws_server_pid "${RS_NAME:-}")"
ENG_PIDS="$(rws_engine_pids "$RWS_PID")"
if [ -z "$ENG_PIDS" ]; then
    warn "No engine processes found (Reports server ${RS_NAME:-?} PID: ${RWS_PID:-not running})"
else
    for _p in ${ENG_PIDS//,/ }; do
        _x="$(tr '\0' '\n' < "/proc/$_p/cmdline" 2>/dev/null | grep -E '^-Xmx' | tail -1)"
        _r="$(awk '/^VmRSS/ {print int($2/1024)}' "/proc/$_p/status" 2>/dev/null)"
        _t="$(ps -o etime= -p "$_p" 2>/dev/null | tr -d ' ')"
        _show "PID $_p:" "$(printf "RSS %s MB, %s, up %s" "${_r:--}" "${_x:-no -Xmx}" "${_t:--}")"
    done
    info "  heap settings: ./05-ReportsPerformance/engine_perf_settings.sh"
fi

# =============================================================================
# 5. Logs of the Reports server and its engines
# =============================================================================

printLine
section "Reports Server Logs (last ${LOG_LINES} lines per file)"

LOG_ORA=0 LOG_REP=0 LOG_OOM=0
RS_LOG_DIR="$(ihw_log_groups "${RS_NAME:-reports}" 2>/dev/null | awk -F'\t' '$1=="Reports server" {print $3; exit}')"
if [ -z "$RS_LOG_DIR" ] || [ ! -d "$RS_LOG_DIR" ]; then
    warn "Log directory of the Reports server not found (expected: \$DOMAIN_HOME/servers/<repserver>/logs)"
else
    _show "Log directory:" "$RS_LOG_DIR"
    _tail_all="$(
        for _f in "$RS_LOG_DIR"/rwserver_diagnostic.log "$RS_LOG_DIR"/rwEng-*_diagnostic.log; do
            [ -f "$_f" ] && tail -n "$LOG_LINES" "$_f" | sed "s|^|$(basename "$_f"): |"
        done
    )"
    LOG_ORA="$(printf "%s\n" "$_tail_all" | grep -c 'ORA-[0-9]')"
    LOG_REP="$(printf "%s\n" "$_tail_all" | grep -c 'REP-[0-9]')"
    LOG_OOM="$(printf "%s\n" "$_tail_all" | grep -c 'OutOfMemoryError')"
    _show "Lines with ORA- / REP- / OOM:" "$LOG_ORA / $LOG_REP / $LOG_OOM"

    if [ "$LOG_REP" -gt 0 ]; then
        REC_REP=1
        printf "\n  Most frequent REP- codes:\n" | tee -a "${LOG_FILE:-/dev/null}"
        printf "%s\n" "$_tail_all" | grep -o 'REP-[0-9]*' | sed 's/REP-0*/REP-/' \
            | sort | uniq -c | sort -rn | head -5 \
            | while read -r _c _code; do
                _ex="$(printf "%s\n" "$_tail_all" | grep -m1 -E "REP-0*${_code#REP-}([^0-9]|$)" \
                       | sed 's/^\([^:]*\): .*\(REP-[0-9]*[^]]\{0,70\}\).*/\1: \2/; s/ *\[\[.*//')"
                printf "    %5s x %-10s %s\n" "$_c" "$_code" "$_ex" | tee -a "${LOG_FILE:-/dev/null}"
              done
        warn "$(printf "%s log line(s) with REP- errors" "$LOG_REP")"
    fi
    if [ "$LOG_ORA" -gt 0 ]; then
        REC_ORA=1
        warn "$(printf "%s log line(s) with ORA- errors" "$LOG_ORA")"
        printf "%s\n" "$_tail_all" | grep 'ORA-[0-9]' | tail -3 | cut -c1-160 \
            | while IFS= read -r _ln; do printf "    %s\n" "$_ln" | tee -a "${LOG_FILE:-/dev/null}"; done
    fi
    if [ "$LOG_OOM" -gt 0 ]; then
        REC_OOM=1
        fail "$(printf "%s OutOfMemoryError line(s) – engine heap too small" "$LOG_OOM")"
    fi
    [ "$LOG_ORA" -eq 0 ] && [ "$LOG_REP" -eq 0 ] && [ "$LOG_OOM" -eq 0 ] && \
        ok "No ORA- / REP- / OutOfMemoryError in the Reports server logs"
fi

# =============================================================================
# 6. Recommendations
# =============================================================================

printLine
section "Recommendations"

RECS=0
_rec() { RECS=$(( RECS + 1 )); printf "  [%d] %s\n" "$RECS" "$1" | tee -a "${LOG_FILE:-/dev/null}"; shift
         for _x in "$@"; do printf "      -> %s\n" "$_x" | tee -a "${LOG_FILE:-/dev/null}"; done; }

[ "$REC_POOL" -eq 1 ] && _rec "Engine pool at maxEngine" \
    "raise maxEngine (Oracle: up to 2-4 engines per CPU, heap must fit the RAM)" \
    "./05-ReportsPerformance/engine_perf_settings.sh --apply"
[ "$REC_QUEUE" -eq 1 ] && [ "$REC_POOL" -eq 0 ] && _rec "High queuing share, but the pool was never full" \
    "waiting is not caused by maxEngine: engine start (initEngine/minEngine), failed jobs, retries" \
    "compare after a restart under real load"
[ "$REC_QUEUE" -eq 1 ] && [ "$REC_POOL" -eq 1 ] && _rec "Queuing caused by the full pool – see [1]"
[ "$REC_DEAD" -eq 1 ] && _rec "Dead engine(s)" \
    "engine logs: ./03-Logs/grep_logs.sh 'REP-' (rwEng-N_diagnostic.log)" \
    "background: 80-FMW-Architecture/report_engine_architecture.md"
_xmx_cfg="$(printf "%s" "${CFG_JVM:-}" | grep -oE '\-Xmx[0-9]+[kKmMgG]?' | tail -1)"
[ "$REC_OOM" -eq 1 ] && _rec "OutOfMemoryError in the engines" \
    "engine -Xmx: ${_xmx_cfg:-jvmOptions not set (Reports default, see Engine Processes)}" \
    "raise -Xmx in jvmOptions: ./05-ReportsPerformance/engine_perf_settings.sh --apply"
[ "$REC_FAIL" -eq 1 ] || [ "$REC_REP" -eq 1 ] && _rec "Failed jobs / REP- errors – fix the cause before tuning" \
    "./03-Logs/grep_logs.sh 'REP-'" \
    "REP-56132 / REP-108 (images, folderAccess): 80-FMW-Architecture/report_server_image_handling.md"
[ "$REC_ORA" -eq 1 ] && _rec "ORA- errors – database side" "./02-Checks/db_connect_check.sh"
[ "$REC_ERT" -eq 1 ] && _rec "engineResponseTimeOut does not match the measured run times (see Job Run Times)" \
    "./05-ReportsPerformance/engine_perf_settings.sh --apply (writes REPORTS_ENGINE_RESPONSE_TIMEOUT)" \
    "batch reports with long run times: own Reports server (Oracle)"

[ "$RECS" -eq 0 ] && ok "No performance issues detected"

# =============================================================================
# Summary
# =============================================================================

print_summary
exit "$EXIT_CODE"
