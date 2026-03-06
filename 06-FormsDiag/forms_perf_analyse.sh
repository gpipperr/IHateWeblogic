#!/bin/bash
# =============================================================================
# Script   : forms_perf_analyse.sh
# Purpose  : Analyse Oracle Forms Server performance:
#            - Active session count and memory consumption (frmweb processes)
#            - HTTP response times from WLS_FORMS access log
#            - WLS_FORMS server log scan (ORA-, timeout, OOM events)
#            - Consolidated recommendations
# Call     : ./forms_perf_analyse.sh
#            ./forms_perf_analyse.sh --lines 1000
#            ./forms_perf_analyse.sh --no-log
# Options  : --lines N   Last N log lines to scan (default: 500)
#            --no-log    Skip log file analysis
#            --help      Show usage
# Requires : pgrep, ps, awk, grep, tail
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 06-FormsDiag/README.md
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

LOG_LINES=500
SKIP_LOG=0

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-20s %s\n" "--lines N"  "Last N log lines to scan (default: 500)"
    printf "  %-20s %s\n" "--no-log"   "Skip WLS_FORMS log analysis"
    printf "  %-20s %s\n" "--help"     "Show this help"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --lines)  LOG_LINES="$2"; shift 2 ;;
        --no-log) SKIP_LOG=1;     shift   ;;
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
section "Forms Performance Analysis – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-26s %s\n" "Host:"        "$(hostname -f 2>/dev/null || hostname)" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "DOMAIN_HOME:" "${DOMAIN_HOME}"                          | tee -a "${LOG_FILE:-/dev/null}"
printLine

# Track findings for recommendations section
BOTTLENECK_MEMORY=0
BOTTLENECK_LOG_ORA=0
BOTTLENECK_LOG_TIMEOUT=0
BOTTLENECK_LOG_OOM=0
BOTTLENECK_SLOW_RESPONSE=0

# =============================================================================
# 1. Active Sessions (frmweb)
# =============================================================================

section "Active Sessions"

WLS_FORMS_PID="$(pgrep -f 'weblogic.Name=WLS_FORMS' 2>/dev/null | head -1)"
FRMWEB_PIDS=($(pgrep -f "frmweb" 2>/dev/null))
FRMWEB_COUNT="${#FRMWEB_PIDS[@]}"

printf "  %-26s %s\n" "WLS_FORMS JVM PID:" "${WLS_FORMS_PID:-(not running)}" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "Active frmweb sessions:" "$FRMWEB_COUNT"               | tee -a "${LOG_FILE:-/dev/null}"

if [ -z "$WLS_FORMS_PID" ]; then
    warn "WLS_FORMS JVM not running – no active Forms sessions possible"
    info "  Start: ./01-Run/startStop.sh start WLS_FORMS --apply"
elif [ "$FRMWEB_COUNT" -eq 0 ]; then
    ok "WLS_FORMS running – no active frmweb sessions"
else
    ok "$(printf "WLS_FORMS running – %s active session(s)" "$FRMWEB_COUNT")"

    # Memory per frmweb process
    TOTAL_FRMWEB_RSS=0
    MIN_RSS=999999; MAX_RSS=0
    for pid in "${FRMWEB_PIDS[@]}"; do
        rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
        [ -z "$rss" ] && continue
        rss_mb=$(( rss / 1024 ))
        TOTAL_FRMWEB_RSS=$(( TOTAL_FRMWEB_RSS + rss_mb ))
        [ "$rss_mb" -lt "$MIN_RSS" ] && MIN_RSS="$rss_mb"
        [ "$rss_mb" -gt "$MAX_RSS" ] && MAX_RSS="$rss_mb"
    done

    if [ "$FRMWEB_COUNT" -gt 0 ] && [ "$TOTAL_FRMWEB_RSS" -gt 0 ]; then
        AVG_RSS=$(( TOTAL_FRMWEB_RSS / FRMWEB_COUNT ))
        printf "  %-26s %s MB\n" "Total frmweb RSS:"   "$TOTAL_FRMWEB_RSS" | tee -a "${LOG_FILE:-/dev/null}"
        printf "  %-26s %s MB  (min: %s MB, max: %s MB)\n" \
            "Avg RSS per session:" "$AVG_RSS" "$MIN_RSS" "$MAX_RSS" \
            | tee -a "${LOG_FILE:-/dev/null}"
    fi

    # WLS_FORMS JVM memory
    if [ -n "$WLS_FORMS_PID" ]; then
        WLS_RSS="$(ps -o rss= -p "$WLS_FORMS_PID" 2>/dev/null | tr -d ' ')"
        WLS_RSS_MB=$(( ${WLS_RSS:-0} / 1024 ))
        JVM_CMDLINE="$(tr '\0' ' ' < "/proc/${WLS_FORMS_PID}/cmdline" 2>/dev/null)"
        JVM_XMX="$(printf "%s" "$JVM_CMDLINE" | grep -oE '\-Xmx[0-9]+[mMgG]' | head -1)"

        printf "  %-26s %s MB\n" "WLS_FORMS JVM RSS:"  "$WLS_RSS_MB"           | tee -a "${LOG_FILE:-/dev/null}"
        printf "  %-26s %s\n"    "WLS_FORMS JVM -Xmx:" "${JVM_XMX:-(unknown)}" | tee -a "${LOG_FILE:-/dev/null}"

        # Warn if total RSS (JVM + sessions) exceeds available RAM threshold
        AVAIL_MB="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
        if [ -n "$AVAIL_MB" ] && [ "$AVAIL_MB" -gt 0 ]; then
            TOTAL_FORMS_MB=$(( WLS_RSS_MB + TOTAL_FRMWEB_RSS ))
            pct=$(( TOTAL_FORMS_MB * 100 / AVAIL_MB ))
            printf "  %-26s %s MB = %s%% of available RAM\n" \
                "Total Forms memory:" "$TOTAL_FORMS_MB" "$pct" \
                | tee -a "${LOG_FILE:-/dev/null}"
            if [ "$pct" -gt 80 ] 2>/dev/null; then
                warn "$(printf "Forms processes use %s%% of available RAM – memory pressure" "$pct")"
                BOTTLENECK_MEMORY=1
            else
                ok "$(printf "Memory usage %s%% of available RAM" "$pct")"
            fi
        fi
    fi
fi

# =============================================================================
# 2. HTTP Response Times (access log)
# =============================================================================

printLine
section "HTTP Response Times (access.log)"

ACCESS_LOG=""
# Standard WLS access log paths
for candidate in \
    "${DOMAIN_HOME}/servers/WLS_FORMS/logs/access.log" \
    "${DOMAIN_HOME}/servers/WLS_FORMS/logs/WLS_FORMS_access.log"; do
    [ -f "$candidate" ] && { ACCESS_LOG="$candidate"; break; }
done

# Broader search if not found
if [ -z "$ACCESS_LOG" ]; then
    ACCESS_LOG="$(find "${DOMAIN_HOME}/servers" -maxdepth 4 \
        -name "access.log" -path "*/WLS_FORMS/*" 2>/dev/null | head -1)"
fi

if [ -z "$ACCESS_LOG" ] || [ ! -f "$ACCESS_LOG" ]; then
    warn "WLS_FORMS access.log not found – HTTP response time analysis skipped"
    info "  Enable WLS HTTP access log in WebLogic Console:"
    info "  Domain > WLS_FORMS > Logging > HTTP > Enable HTTP Access Log"
else
    ok "Access log: $ACCESS_LOG"
    info "Analysing last ${LOG_LINES} lines for /forms/frmservlet requests"

    # WLS combined log format: IP - - [date] "METHOD URL HTTP/x.x" STATUS BYTES ELAPSED_MS
    # Column positions vary; we look for lines with /forms/ and extract last numeric field
    LOG_SAMPLE="$(tail -n "$LOG_LINES" "$ACCESS_LOG" 2>/dev/null \
        | grep -i '/forms/frmservlet\|/forms/lservlet\|/forms/' | head -500)"

    FORMS_REQUESTS="$(printf "%s" "$LOG_SAMPLE" | wc -l | tr -d ' ')"
    printf "  %-30s %s\n" "Forms requests in sample:" "$FORMS_REQUESTS" \
        | tee -a "${LOG_FILE:-/dev/null}"

    if [ "$FORMS_REQUESTS" -gt 0 ]; then
        # Extract response time (last numeric field, if present – depends on WLS log format)
        # Some WLS versions log elapsed time as the last field in ms
        TIMING="$(printf "%s" "$LOG_SAMPLE" | awk '{
            # last field numeric = elapsed ms
            n=NF; if ($n ~ /^[0-9]+$/ && $n > 0) { sum+=$n; cnt++; if($n>max) max=$n; if(min==0||$n<min) min=$n }
        } END {
            if(cnt>0) printf "%d %.0f %d %d", cnt, sum/cnt, min, max
        }')"

        if [ -n "$TIMING" ]; then
            read -r t_cnt t_avg t_min t_max <<< "$TIMING"
            printf "  %-30s %s\n" "Requests with timing:" "$t_cnt"        | tee -a "${LOG_FILE:-/dev/null}"
            printf "  %-30s %s ms\n" "Avg response time:"  "$t_avg"       | tee -a "${LOG_FILE:-/dev/null}"
            printf "  %-30s %s ms\n" "Min response time:"  "$t_min"       | tee -a "${LOG_FILE:-/dev/null}"
            printf "  %-30s %s ms\n" "Max response time:"  "$t_max"       | tee -a "${LOG_FILE:-/dev/null}"

            if [ "$t_avg" -gt 5000 ] 2>/dev/null; then
                fail "$(printf "Avg response time %s ms > 5s – severe performance issue" "$t_avg")"
                BOTTLENECK_SLOW_RESPONSE=1
            elif [ "$t_avg" -gt 2000 ] 2>/dev/null; then
                warn "$(printf "Avg response time %s ms > 2s – slower than expected" "$t_avg")"
                BOTTLENECK_SLOW_RESPONSE=1
            else
                ok "$(printf "Avg response time %s ms – acceptable" "$t_avg")"
            fi
        else
            info "Elapsed time column not found in access log (depends on WLS log format)"
        fi

        # HTTP status code distribution
        STATUS_DIST="$(printf "%s" "$LOG_SAMPLE" | awk '{
            for(i=1;i<=NF;i++) { if($i~/^[2345][0-9][0-9]$/) { cnt[$i]++ } }
        } END { for(s in cnt) printf "%s: %d\n", s, cnt[s] }' | sort)"
        if [ -n "$STATUS_DIST" ]; then
            printf "\n  HTTP status distribution:\n" | tee -a "${LOG_FILE:-/dev/null}"
            printf "%s" "$STATUS_DIST" | while IFS= read -r ln; do
                printf "    %s\n" "$ln" | tee -a "${LOG_FILE:-/dev/null}"
            done
            # Warn on 5xx errors
            ERR_5XX="$(printf "%s" "$STATUS_DIST" | grep '^5' | awk '{sum+=$2} END{print sum+0}')"
            [ "$ERR_5XX" -gt 0 ] && \
                warn "$(printf "%s HTTP 5xx error(s) in last %s log lines" "$ERR_5XX" "$LOG_LINES")"
        fi
    else
        info "No Forms servlet requests found in last ${LOG_LINES} access log lines"
    fi
fi

# =============================================================================
# 3. WLS_FORMS Server Log Analysis
# =============================================================================

printLine
section "Server Log Analysis (last ${LOG_LINES} lines)"

if [ "$SKIP_LOG" -eq 1 ]; then
    info "Log analysis skipped (--no-log)"
else
    # Locate WLS_FORMS server log
    SERVER_LOG=""
    for candidate in \
        "${DOMAIN_HOME}/servers/WLS_FORMS/logs/WLS_FORMS.log" \
        "${DOMAIN_HOME}/servers/WLS_FORMS/logs/WLS_FORMS-diagnostic.log"; do
        [ -f "$candidate" ] && { SERVER_LOG="$candidate"; break; }
    done

    if [ -z "$SERVER_LOG" ]; then
        SERVER_LOG="$(find "${DOMAIN_HOME}/servers" -maxdepth 4 \
            -name "*.log" -path "*/WLS_FORMS/*" ! -name "access.log" 2>/dev/null | head -1)"
    fi

    if [ -z "$SERVER_LOG" ] || [ ! -f "$SERVER_LOG" ]; then
        warn "WLS_FORMS server log not found"
        info "  Expected: ${DOMAIN_HOME}/servers/WLS_FORMS/logs/"
    else
        ok "Server log: $SERVER_LOG"
        LOG_TAIL="$(tail -n "$LOG_LINES" "$SERVER_LOG" 2>/dev/null)"

        CNT_ORA="$(   printf "%s" "$LOG_TAIL" | grep -c 'ORA-'             2>/dev/null || printf 0)"
        CNT_TIMEOUT="$(printf "%s" "$LOG_TAIL" | grep -ic 'timeout\|timed out' 2>/dev/null || printf 0)"
        CNT_OOM="$(   printf "%s" "$LOG_TAIL" | grep -c 'OutOfMemoryError' 2>/dev/null || printf 0)"
        CNT_CONNREF="$(printf "%s" "$LOG_TAIL" | grep -ic 'Connection refused\|ECONNREFUSED' 2>/dev/null || printf 0)"
        CNT_FRM="$(   printf "%s" "$LOG_TAIL" | grep -c 'FRM-'             2>/dev/null || printf 0)"

        printf "  %-32s %s\n" "ORA- errors:"              "$CNT_ORA"     | tee -a "${LOG_FILE:-/dev/null}"
        printf "  %-32s %s\n" "FRM- errors:"              "$CNT_FRM"     | tee -a "${LOG_FILE:-/dev/null}"
        printf "  %-32s %s\n" "Timeout events:"           "$CNT_TIMEOUT" | tee -a "${LOG_FILE:-/dev/null}"
        printf "  %-32s %s\n" "OutOfMemoryError events:"  "$CNT_OOM"     | tee -a "${LOG_FILE:-/dev/null}"
        printf "  %-32s %s\n" "Connection refused events:""$CNT_CONNREF" | tee -a "${LOG_FILE:-/dev/null}"

        [ "$CNT_ORA"     -gt 0 ] 2>/dev/null && \
            warn "$(printf "%s ORA- error(s) – DB connectivity issue?" "$CNT_ORA")" && \
            BOTTLENECK_LOG_ORA=1
        [ "$CNT_TIMEOUT" -gt 0 ] 2>/dev/null && \
            warn "$(printf "%s timeout event(s) – check heartbeatInterval and LB idle timeout" "$CNT_TIMEOUT")" && \
            BOTTLENECK_LOG_TIMEOUT=1
        [ "$CNT_OOM"     -gt 0 ] 2>/dev/null && \
            fail "$(printf "%s OutOfMemoryError – WLS_FORMS heap too small" "$CNT_OOM")" && \
            BOTTLENECK_LOG_OOM=1
        [ "$CNT_FRM"     -gt 0 ] 2>/dev/null && \
            warn "$(printf "%s FRM- error(s) – Forms application errors" "$CNT_FRM")"

        if [ "$CNT_ORA" -eq 0 ] && [ "$CNT_OOM" -eq 0 ] && \
           [ "$CNT_TIMEOUT" -eq 0 ] && [ "$CNT_FRM" -eq 0 ]; then
            ok "No ORA- / FRM- / OOM / timeout events in last ${LOG_LINES} lines"
        fi

        # Show last 3 ORA- and FRM- lines as samples
        for pattern in "ORA-" "FRM-"; do
            cnt_var="CNT_ORA"
            [ "$pattern" = "FRM-" ] && cnt_var="CNT_FRM"
            cnt_val="${!cnt_var:-0}"
            if [ "$cnt_val" -gt 0 ] 2>/dev/null; then
                printf "\n  Last %s occurrences:\n" "$pattern" | tee -a "${LOG_FILE:-/dev/null}"
                printf "%s" "$LOG_TAIL" | grep "$pattern" | tail -3 \
                    | while IFS= read -r ln; do
                        printf "    %s\n" "$ln" | tee -a "${LOG_FILE:-/dev/null}"
                      done
            fi
        done
    fi
fi

# =============================================================================
# 4. Recommendations
# =============================================================================

printLine
section "Recommendations"

RECS=0

if [ "$BOTTLENECK_MEMORY" -eq 1 ]; then
    RECS=$(( RECS + 1 ))
    printf "  [%d] \033[33mMemory pressure detected\033[0m\n" "$RECS"          | tee -a "${LOG_FILE:-/dev/null}"
    printf "      → Increase WLS_FORMS JVM -Xmx in setDomainEnv.sh\n"          | tee -a "${LOG_FILE:-/dev/null}"
    printf "      → Or reduce concurrent sessions via load balancer limits\n"   | tee -a "${LOG_FILE:-/dev/null}"
    printf "      → Review: ./06-FormsDiag/forms_perf_settings.sh\n"            | tee -a "${LOG_FILE:-/dev/null}"
fi

if [ "$BOTTLENECK_LOG_OOM" -eq 1 ]; then
    RECS=$(( RECS + 1 ))
    printf "  [%d] \033[31mOutOfMemoryError – WLS_FORMS heap exhausted\033[0m\n" "$RECS" | tee -a "${LOG_FILE:-/dev/null}"
    printf "      → Increase -Xmx in setDomainEnv.sh for WLS_FORMS\n"                    | tee -a "${LOG_FILE:-/dev/null}"
    printf "      → Check for Forms session memory leaks (long-running sessions)\n"       | tee -a "${LOG_FILE:-/dev/null}"
fi

if [ "$BOTTLENECK_SLOW_RESPONSE" -eq 1 ]; then
    RECS=$(( RECS + 1 ))
    printf "  [%d] \033[33mSlow response times detected\033[0m\n" "$RECS"     | tee -a "${LOG_FILE:-/dev/null}"
    printf "      → Check DB response time: ./02-Checks/db_connect_check.sh\n" | tee -a "${LOG_FILE:-/dev/null}"
    printf "      → Increase maxEventBunchSize in formsweb.cfg\n"               | tee -a "${LOG_FILE:-/dev/null}"
    printf "      → Review network path between client, Forms server and DB\n"  | tee -a "${LOG_FILE:-/dev/null}"
fi

if [ "$BOTTLENECK_LOG_ORA" -eq 1 ]; then
    RECS=$(( RECS + 1 ))
    printf "  [%d] ORA- database errors in Forms log\033[0m\n" "$RECS"        | tee -a "${LOG_FILE:-/dev/null}"
    printf "      → Run: ./02-Checks/db_connect_check.sh\n"                    | tee -a "${LOG_FILE:-/dev/null}"
fi

if [ "$BOTTLENECK_LOG_TIMEOUT" -eq 1 ]; then
    RECS=$(( RECS + 1 ))
    printf "  [%d] Session timeout events detected\033[0m\n" "$RECS"                  | tee -a "${LOG_FILE:-/dev/null}"
    printf "      → Align heartbeatInterval with load balancer idle timeout\n"         | tee -a "${LOG_FILE:-/dev/null}"
    printf "      → Review: ./06-FormsDiag/forms_perf_settings.sh\n"                   | tee -a "${LOG_FILE:-/dev/null}"
fi

if [ "$RECS" -eq 0 ]; then
    ok "No performance issues detected"
fi

# =============================================================================
# Summary
# =============================================================================

print_summary
exit "$EXIT_CODE"
