#!/bin/bash
# =============================================================================
# Script   : forms_perf_analyse.sh
# Purpose  : How does the Forms server carry its load?
#            - frmweb processes per config section: count, memory, age,
#              CPU time, DB connection -> prestart pool vs. user session
#            - memory of WLS_FORMS + all frmweb vs. RAM and maxRuntimeProcesses
#            - WLS_FORMS access.log: requests per config section, HTTP status,
#              response time (only if the log has a time-taken field)
#            - Forms logs (WLS_FORMS-diagnostic.log, formsapp-diagnostic.log):
#              FRM- / ORA- / OutOfMemoryError, most frequent FRM codes
#            - crash dumps in FORMS_TRACE_DIR
# Call     : ./forms_perf_analyse.sh
#            ./forms_perf_analyse.sh --lines 5000
#            ./forms_perf_analyse.sh --no-log
# Options  : --lines N   Last N lines per log file (default: 2000)
#            --no-log    Skip access log and server log analysis
#            --help      Show usage
# Read-only.
# Requires : awk, sed, ss (DB connection per frmweb)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 06-FormsDiag/README.md, 80-FMW-Architecture/forms_runtime_architecture.md
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

# shellcheck source=forms_lib.sh
source "$SCRIPT_DIR/forms_lib.sh"
# shellcheck source=../03-Logs/log_locations.sh
source "$ROOT_DIR/03-Logs/log_locations.sh"

_show() { printf "  %-30s %s\n" "$1" "$2" | tee -a "${LOG_FILE:-/dev/null}"; }

# =============================================================================
# Arguments
# =============================================================================

LOG_LINES=2000
SKIP_LOG=0

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-20s %s\n" "--lines N" "Last N lines per log file (default: 2000)"
    printf "  %-20s %s\n" "--no-log"  "Skip access log and server log analysis"
    printf "  %-20s %s\n" "--help"    "Show this help"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --lines)   LOG_LINES="$2"; shift 2 ;;
        --no-log)  SKIP_LOG=1;     shift   ;;
        --help|-h) _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
    esac
done
[[ "$LOG_LINES" =~ ^[0-9]+$ ]] || { printf "\033[31mERROR\033[0m --lines needs a number\n" >&2; exit 2; }

# =============================================================================
# Banner
# =============================================================================

printLine
section "Forms Load Analysis – $(date '+%Y-%m-%d %H:%M:%S')"
_show "Host:"        "$(hostname -f 2>/dev/null || hostname)"
_show "DOMAIN_HOME:" "${DOMAIN_HOME}"
printLine

frm_find_files || warn "formsweb.cfg not found – prestart / limits unknown"
WLS_FORMS_SRV="$(frm_wls_server)"
WLS_FORMS_PID="$(frm_wls_pid "$WLS_FORMS_SRV")"

REC_POOL=0 REC_MEM=0 REC_LIMIT=0 REC_OOM=0 REC_FRM=0 REC_ORA=0 REC_5XX=0 REC_DUMP=0

# =============================================================================
# 1. frmweb processes per section
# =============================================================================

section "frmweb Processes per Config Section"

if [ -z "$WLS_FORMS_PID" ]; then
    warn "$WLS_FORMS_SRV not running – no Forms runtimes"
    info "  Start: ./01-Run/startStop.sh start $WLS_FORMS_SRV --apply"
    FRM_LIST=""
else
    _show "$WLS_FORMS_SRV PID:" "$WLS_FORMS_PID"
    FRM_LIST="$(frm_frmweb_list "$WLS_FORMS_PID")"
fi

# PIDs with an established TCP connection (DB) – logged-on sessions
DB_PIDS="$(ss -tnpH state established 2>/dev/null | grep -o 'frmweb",pid=[0-9]*' | sed 's/.*pid=//' | sort -u)"

TOTAL_N=0 TOTAL_RSS=0 TOTAL_SESS=0 SESS_RSS=0
if [ -n "$FRM_LIST" ]; then
    printf "\n  \033[1m%-23s %5s %8s %8s %9s %8s %s\033[0m\n" "Section" "procs" "RSS MB" "max MB" "with DB" "CPU>0" "prestart" | tee -a "${LOG_FILE:-/dev/null}"
    for _s in $(printf '%s\n' "$FRM_LIST" | cut -f2 | sort -u); do
        _lines="$(printf '%s\n' "$FRM_LIST" | awk -F'\t' -v s="$_s" '$2==s')"
        _n="$(printf '%s\n' "$_lines" | wc -l)"
        _rss="$(printf '%s\n' "$_lines" | awk -F'\t' '{t+=$3} END {print t+0}')"
        _max="$(printf '%s\n' "$_lines" | awk -F'\t' '$3>m {m=$3} END {print m+0}')"
        _db=0 _cpu=0
        for _p in $(printf '%s\n' "$_lines" | cut -f1); do
            printf '%s\n' "$DB_PIDS" | grep -qx "$_p" && _db=$(( _db + 1 ))
            [ "$(ps -o cputimes= -p "$_p" 2>/dev/null | tr -d ' ')" != "0" ] && _cpu=$(( _cpu + 1 ))
        done
        _pre="-"
        if [ -n "${FRM_CFG:-}" ] && [ "$(frm_cfg_get "$FRM_CFG" "$_s" prestartRuntimes | tr 'A-Z' 'a-z')" = "true" ]; then
            _pre="init $(frm_cfg_get "$FRM_CFG" "$_s" prestartInit)"
        fi
        printf "  %-23s %5s %8s %8s %9s %8s %s\n" "$_s" "$_n" "$_rss" "$_max" "$_db" "$_cpu" "$_pre" | tee -a "${LOG_FILE:-/dev/null}"
        TOTAL_N=$(( TOTAL_N + _n )); TOTAL_RSS=$(( TOTAL_RSS + _rss )); TOTAL_SESS=$(( TOTAL_SESS + _db ))
        SESS_RSS=$(( SESS_RSS + $(printf '%s\n' "$_lines" | while IFS=$'\t' read -r _p _x _r _e; do
            printf '%s\n' "$DB_PIDS" | grep -qx "$_p" && printf '%s\n' "$_r"; done | awk '{t+=$1} END {print t+0}') ))
    done
    printf "\n" | tee -a "${LOG_FILE:-/dev/null}"
    _show "frmweb total:" "$(printf "%s processes, %s MB RSS" "$TOTAL_N" "$TOTAL_RSS")"
    _show "with DB connection (sessions):" "$TOTAL_SESS"
    _show "without (pool / not logged on):" "$(( TOTAL_N - TOTAL_SESS ))"
    info "  assumption: no DB connection and no CPU time = prestarted pool runtime (not yet tested with a real client session)"
    if [ $(( TOTAL_N - TOTAL_SESS )) -gt 20 ]; then
        warn "$(printf "%s frmweb processes without a session – prestart pool in many sections?" $(( TOTAL_N - TOTAL_SESS )))"
        REC_POOL=1
    fi
else
    info "No frmweb processes"
fi

# =============================================================================
# 2. Memory and limit
# =============================================================================

printLine
section "Memory and Session Limit"

MEM_TOTAL="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
MEM_AVAIL="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)"
WLS_RSS=0
[ -n "$WLS_FORMS_PID" ] && WLS_RSS="$(awk '/^VmRSS/ {print int($2/1024)}' "/proc/$WLS_FORMS_PID/status" 2>/dev/null)"
_show "RAM total / available:" "${MEM_TOTAL} / ${MEM_AVAIL} MB"
_show "$WLS_FORMS_SRV JVM RSS:" "${WLS_RSS:-0} MB  (heap: ./02-Checks/weblogic_performance.sh)"
_show "frmweb RSS total:" "${TOTAL_RSS} MB"
if [ "$TOTAL_SESS" -gt 0 ]; then
    AVG_SESS=$(( SESS_RSS / TOTAL_SESS ))
    _show "RSS per session (avg):" "$AVG_SESS MB"
    [ "$AVG_SESS" -gt 0 ] && _show "Sessions that fit (RAM avail):" "~$(( (MEM_AVAIL + SESS_RSS) / AVG_SESS ))"
else
    info "No session with a DB connection – RSS per session cannot be measured now (measure under real load)"
fi
info "  FMX code and boilerplate are shared between sessions of the same form (Oracle) – only the data part grows per session"

MRP="$( [ -n "${FRM_CFG:-}" ] && frm_cfg_get "$FRM_CFG" default maxRuntimeProcesses)"
if [ -z "$MRP" ] || [ "$MRP" = "0" ]; then
    warn "maxRuntimeProcesses not set – nothing stops new frmweb processes before the RAM runs out"
    REC_LIMIT=1
else
    _show "maxRuntimeProcesses:" "$MRP  (in use: $TOTAL_N)"
    [ "$TOTAL_N" -ge $(( MRP * 90 / 100 )) ] && { warn "frmweb processes at >= 90% of maxRuntimeProcesses"; REC_LIMIT=1; }
fi
if [ "$MEM_AVAIL" -lt $(( MEM_TOTAL / 10 )) ]; then
    warn "Less than 10% RAM available – memory pressure"
    REC_MEM=1
else
    ok "RAM available: ${MEM_AVAIL} MB"
fi

# =============================================================================
# 3. Access log
# =============================================================================

FORMS_LOG_DIR="$(ihw_log_groups "$WLS_FORMS_SRV" 2>/dev/null | awk -F'\t' '{print $3; exit}')"

printLine
section "HTTP Requests (access.log, last ${LOG_LINES} lines)"

ACCESS_LOG="${FORMS_LOG_DIR:+$FORMS_LOG_DIR/access.log}"
if [ "$SKIP_LOG" -eq 1 ]; then
    info "skipped (--no-log)"
elif [ -z "$ACCESS_LOG" ] || [ ! -f "$ACCESS_LOG" ]; then
    info "access.log of $WLS_FORMS_SRV not found (HTTP access logging off?)"
else
    FIELDS="$(grep -m1 '^#Fields:' "$ACCESS_LOG" | sed 's/^#Fields:[[:space:]]*//')"
    _show "Log:" "$ACCESS_LOG"
    _show "Fields:" "${FIELDS:-(no #Fields header)}"
    # column numbers from the #Fields header (tab separated, WebLogic extended format)
    _col() { printf '%s\n' "$FIELDS" | tr -s ' \t' '\n' | grep -nx "$1" | cut -d: -f1; }
    C_URI="$(_col cs-uri)"; C_ST="$(_col sc-status)"; C_TT="$(_col time-taken)"; C_TIME="$(_col time)"
    if [ -z "$C_URI" ] || [ -z "$C_ST" ]; then
        info "cs-uri / sc-status not in the log format – analysis skipped"
    else
        _tail="$(tail -n "$LOG_LINES" "$ACCESS_LOG" | grep -v '^#')"
        printf "\n  Requests to frmservlet per config section:\n" | tee -a "${LOG_FILE:-/dev/null}"
        printf '%s\n' "$_tail" | awk -F'\t' -v u="$C_URI" '$u ~ /\/forms\/frmservlet/ {
                c="default"; if (match($u, /config=[^&]*/)) c=substr($u, RSTART+7, RLENGTH-7); n[c]++ }
            END { for (k in n) printf "    %6d  %s\n", n[k], k }' | sort -rn | tee -a "${LOG_FILE:-/dev/null}"
        _ls="$(printf '%s\n' "$_tail" | awk -F'\t' -v u="$C_URI" '$u ~ /\/forms\/lservlet/' | wc -l)"
        _show "lservlet requests (session traffic):" "$_ls"
        printf "\n  HTTP status:\n" | tee -a "${LOG_FILE:-/dev/null}"
        printf '%s\n' "$_tail" | awk -F'\t' -v s="$C_ST" -v u="$C_URI" '$u ~ /^\/forms\// { n[$s]++ }
            END { for (k in n) printf "    %6d  %s\n", n[k], k }' | sort -k2 | tee -a "${LOG_FILE:-/dev/null}"
        N5XX="$(printf '%s\n' "$_tail" | awk -F'\t' -v s="$C_ST" -v u="$C_URI" '$u ~ /^\/forms\// && $s ~ /^5/' | wc -l)"
        if [ "$N5XX" -gt 0 ]; then
            warn "$N5XX HTTP 5xx answer(s) for /forms/ in the last $LOG_LINES lines"; REC_5XX=1
        else
            ok "No HTTP 5xx for /forms/"
        fi
        if [ -n "$C_TT" ]; then
            printf '%s\n' "$_tail" | awk -F'\t' -v t="$C_TT" -v u="$C_URI" '$u ~ /\/forms\/frmservlet/ && $t ~ /^[0-9.]+$/ {
                    s+=$t; n++; if ($t>m) m=$t }
                END { if (n) printf "  %-30s avg %.3f s, max %.3f s (%d requests)\n", "frmservlet time-taken:", s/n, m, n }' \
                | tee -a "${LOG_FILE:-/dev/null}"
        else
            info "No time-taken field – response times are not logged (WLS: server > Logging > HTTP, extended format fields 'time-taken')"
        fi
    fi
fi

# =============================================================================
# 4. Forms server logs
# =============================================================================

printLine
section "Forms Logs (last ${LOG_LINES} lines per file)"

CNT_FRM=0 CNT_ORA=0 CNT_OOM=0
if [ "$SKIP_LOG" -eq 1 ]; then
    info "skipped (--no-log)"
elif [ -z "$FORMS_LOG_DIR" ] || [ ! -d "$FORMS_LOG_DIR" ]; then
    warn "Log directory of $WLS_FORMS_SRV not found"
else
    _all="$(
        for _f in "$FORMS_LOG_DIR/${WLS_FORMS_SRV}-diagnostic.log" "$FORMS_LOG_DIR/formsapp-diagnostic.log" "$FORMS_LOG_DIR/${WLS_FORMS_SRV}.out"; do
            [ -f "$_f" ] && tail -n "$LOG_LINES" "$_f" | sed "s|^|$(basename "$_f"): |"
        done
    )"
    # ODL format: [time] [server] [LEVEL] [MSG-ID] ... message – judge by level,
    # FRM-934xx are NOTIFICATIONs (e.g. prestart pool), not errors
    _err="$(printf '%s\n' "$_all" | grep -E '\] \[(ERROR|INCIDENT_ERROR|WARNING)(:[0-9]+)?\] ')"
    _note="$(printf '%s\n' "$_all" | grep -E '\] \[NOTIFICATION(:[0-9]+)?\] \[FRM-')"
    CNT_FRM="$(printf '%s\n' "$_err" | grep -c 'FRM-[0-9]')"
    CNT_ORA="$(printf '%s\n' "$_all" | grep -c 'ORA-[0-9]')"
    CNT_OOM="$(printf '%s\n' "$_all" | grep -c 'OutOfMemoryError')"
    _show "Files:" "${WLS_FORMS_SRV}-diagnostic.log, formsapp-diagnostic.log, ${WLS_FORMS_SRV}.out"
    _show "ERROR/WARNING lines:" "$(printf '%s\n' "$_err" | grep -c .)"
    _show "  with FRM- / ORA- / OOM:" "$CNT_FRM / $CNT_ORA / $CNT_OOM"
    if [ -n "$_err" ]; then
        printf "\n  Most frequent ERROR/WARNING message ids:\n" | tee -a "${LOG_FILE:-/dev/null}"
        printf '%s\n' "$_err" | sed -n 's/^[^[]*\[[^]]*\] \[[^]]*\] \[\([A-Z_]*\)[^]]*\] \[\([^]]*\)\].*/\1 \2/p' \
            | sort | uniq -c | sort -rn | head -5 \
            | while read -r _c _lvl _id; do
                _ex="$(printf '%s\n' "$_err" | grep -m1 -F "[$_id]" | sed 's/.*\] //' | cut -c1-90)"
                printf "    %5s x %-14s %-10s %s\n" "$_c" "$_lvl" "$_id" "$_ex" | tee -a "${LOG_FILE:-/dev/null}"
              done
        [ "$CNT_FRM" -gt 0 ] && { REC_FRM=1; warn "$CNT_FRM ERROR/WARNING line(s) with FRM- codes"; }
    fi
    if [ -n "$_note" ]; then
        printf "\n  FRM notifications (information, e.g. runtime pool):\n" | tee -a "${LOG_FILE:-/dev/null}"
        printf '%s\n' "$_note" | grep -o '\[FRM-[0-9]*\]' | sort | uniq -c | sort -rn | head -4 \
            | while read -r _c _id; do
                _ex="$(printf '%s\n' "$_note" | grep -m1 -F "$_id" | sed 's/.*\] //' | cut -c1-90)"
                printf "    %5s x %-10s %s\n" "$_c" "${_id//[\[\]]/}" "$_ex" | tee -a "${LOG_FILE:-/dev/null}"
              done
    fi
    [ "$CNT_ORA" -gt 0 ] && { REC_ORA=1; warn "$CNT_ORA log line(s) with ORA- errors"; }
    [ "$CNT_OOM" -gt 0 ] && { REC_OOM=1; fail "$CNT_OOM OutOfMemoryError line(s) – WLS_FORMS heap (servlet / listener)"; }
    [ "$CNT_FRM" -eq 0 ] && [ "$CNT_ORA" -eq 0 ] && [ "$CNT_OOM" -eq 0 ] && ok "No FRM- / ORA- / OutOfMemoryError in the Forms logs"
fi

# =============================================================================
# 5. Crash dumps
# =============================================================================

printLine
section "frmweb Crash Dumps / Trace Files"

TRACE_DIR="$( [ -n "${FRM_ENV:-}" ] && frm_env_get "$FRM_ENV" FORMS_TRACE_DIR)"
INST_NAME="$(basename "$( [ -n "${FRM_ENV:-}" ] && frm_env_get "$FRM_ENV" FORMS_INSTANCE)")"
[ -z "$TRACE_DIR" ] && TRACE_DIR="$DOMAIN_HOME/system_component/FORMS/${INST_NAME:-${FORMS_INSTANCE_NAME:-forms1}}/trace"
_show "FORMS_TRACE_DIR:" "$TRACE_DIR"
if [ -d "$TRACE_DIR" ]; then
    _new="$(find "$TRACE_DIR" -type f -mtime -7 2>/dev/null | wc -l)"
    _show "Files changed in the last 7 days:" "$_new"
    [ "$_new" -gt 0 ] && { warn "$_new new dump/trace file(s) – frmweb crashes or active Forms Trace?"; REC_DUMP=1; }
else
    ok "Directory does not exist – no dump written yet (Oracle default, created on the first crash)"
fi

# =============================================================================
# 6. Recommendations
# =============================================================================

printLine
section "Recommendations"

RECS=0
_rec() { RECS=$(( RECS + 1 )); printf "  [%d] %s\n" "$RECS" "$1" | tee -a "${LOG_FILE:-/dev/null}"; shift
         for _x in "$@"; do printf "      -> %s\n" "$_x" | tee -a "${LOG_FILE:-/dev/null}"; done; }

[ "$REC_POOL" -eq 1 ]  && _rec "Many idle frmweb processes" \
    "prestart only in the section used in production: ./06-FormsDiag/forms_perf_settings.sh --apply --fix-prestart <section>"
[ "$REC_LIMIT" -eq 1 ] && _rec "Session limit" \
    "set maxRuntimeProcesses in [default] (Oracle: 0 is vulnerable to Denial of Service)" \
    "./06-FormsDiag/forms_perf_settings.sh --apply --section default --set maxRuntimeProcesses=<n>"
[ "$REC_MEM" -eq 1 ]   && _rec "Memory pressure" "fewer sessions per host (maxRuntimeProcesses), more RAM, or a second Forms server"
[ "$REC_OOM" -eq 1 ]   && _rec "OutOfMemoryError in WLS_FORMS" "heap: ./02-Checks/weblogic_performance.sh --apply"
[ "$REC_FRM" -eq 1 ]   && _rec "FRM- errors" "./03-Logs/grep_logs.sh 'FRM-'" "FRM-40010 (cannot read form): module not in FORMS_PATH – ./06-FormsDiag/forms_settings.sh"
[ "$REC_ORA" -eq 1 ]   && _rec "ORA- errors" "./02-Checks/db_connect_check.sh"
[ "$REC_5XX" -eq 1 ]   && _rec "HTTP 5xx from the Forms servlet" "./03-Logs/grep_logs.sh --component forms 'Error'"
[ "$REC_DUMP" -eq 1 ]  && _rec "New crash dumps" "check $TRACE_DIR, Oracle Support with the dump file"

[ "$RECS" -eq 0 ] && ok "No issues detected"

# =============================================================================
# Summary
# =============================================================================

print_summary
exit "$EXIT_CODE"
