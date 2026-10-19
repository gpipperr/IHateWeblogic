#!/bin/bash
# =============================================================================
# Script   : engine_perf_settings.sh
# Purpose  : Read and evaluate the tuning parameters of the standalone Oracle
#            Reports server (rwserver.conf: report engine, queue, connection,
#            cache) against Oracle's tuning rules, compare them with
#            environment.conf, check the engine JVM heap against the RAM and
#            (optionally) update the engine parameters.
# Call     : ./engine_perf_settings.sh
#            ./engine_perf_settings.sh --apply
#            ./engine_perf_settings.sh --conf /path/to/rwserver.conf
#            ./engine_perf_settings.sh --server repserver01
# Options  : --apply         Interactive dialog to update parameters (with backup)
#            --conf PATH     Explicit path to rwserver.conf
#            --server NAME   Reports server component (default: REPORTS_SERVER_NAME)
#            --help          Show usage
# Rules    : 80-FMW-Architecture/report_engine_architecture.md section 6
#            (Oracle "Tuning Reports Server Configuration")
# Requires : pgrep, sed, awk, python3 (--apply)
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

# =============================================================================
# Helpers
# =============================================================================

# _to_mb 256M|1g|1024m -> MB
_to_mb() {
    local v="${1#-Xmx}" n u
    n="${v%[mMgGkK]}"; u="${v: -1}"
    case "$u" in
        [gG]) printf "%s" $(( n * 1024 )) ;;
        [kK]) printf "%s" $(( n / 1024 )) ;;
        [mM]) printf "%s" "$n" ;;
        *)    printf "%s" $(( n / 1024 / 1024 )) ;;
    esac
}

_show() { printf "  %-26s %s\n" "$1" "$2" | tee -a "${LOG_FILE:-/dev/null}"; }

_is_num() { [[ "$1" =~ ^[0-9]+$ ]]; }

# =============================================================================
# Arguments
# =============================================================================

APPLY_MODE=0
OVERRIDE_CONF=""
OVERRIDE_SERVER=""

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-24s %s\n" "--apply"       "Interactive update of the engine parameters (backup first)"
    printf "  %-24s %s\n" "--conf PATH"   "Explicit path to rwserver.conf"
    printf "  %-24s %s\n" "--server NAME" "Reports server component (default: REPORTS_SERVER_NAME)"
    printf "  %-24s %s\n" "--help"        "Show this help"
    printf "\nExamples:\n"
    printf "  %s\n"          "$(basename "$0")"
    printf "  %s --apply\n"  "$(basename "$0")"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)    APPLY_MODE=1; shift ;;
        --conf)     OVERRIDE_CONF="$2"; shift 2 ;;
        --server)   OVERRIDE_SERVER="$2"; shift 2 ;;
        --help|-h)  _usage ;;
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
section "Reports Engine Performance Settings – $(date '+%Y-%m-%d %H:%M:%S')"
_show "Host:"        "$(hostname -f 2>/dev/null || hostname)"
_show "DOMAIN_HOME:" "${DOMAIN_HOME}"
[ "$APPLY_MODE" -eq 1 ] && _show "Mode:" "APPLY (will write changes)"
printLine

# =============================================================================
# 1. Locate rwserver.conf
# =============================================================================

section "Locating rwserver.conf"

ENV_RWSERVER_CONF="${RWSERVER_CONF:-}"
if [ -n "$OVERRIDE_CONF" ]; then
    RWSERVER_CONF="$OVERRIDE_CONF"
    RWS_COMP_NAME="${OVERRIDE_SERVER:-${REPORTS_SERVER_NAME:-}}"
else
    rws_find_conf "$OVERRIDE_SERVER"
fi

if [ -z "$RWSERVER_CONF" ] || [ ! -f "$RWSERVER_CONF" ]; then
    fail "rwserver.conf not found under $DOMAIN_HOME/config"
    info "Re-run: 00-Setup/init_env.sh to detect the Reports component path"
    print_summary
    exit "$EXIT_CODE"
fi

ok "Found: $RWSERVER_CONF"
_show "Reports server:" "${RWS_COMP_NAME:-(unknown)}"
case "$RWSERVER_CONF" in
    */components/ReportsServerComponent/*) ;;
    *) warn "Not the standalone server's file – the in-process server of WLS_REPORTS (or a copy) is evaluated" ;;
esac
if [ -n "$ENV_RWSERVER_CONF" ] && [ "$ENV_RWSERVER_CONF" != "$RWSERVER_CONF" ]; then
    info "environment.conf RWSERVER_CONF points to another file (in-process server of WLS_REPORTS):"
    info "  $ENV_RWSERVER_CONF"
fi

# =============================================================================
# 2. Report engine
# =============================================================================

printLine
section "Report Engine (rwserver.conf)"

ENG_ID="$(   rws_engine_id   "$RWSERVER_CONF")"
ENG_INIT="$( rws_engine_attr "$RWSERVER_CONF" "initEngine")"
ENG_MIN="$(  rws_engine_attr "$RWSERVER_CONF" "minEngine")"
ENG_MAX="$(  rws_engine_attr "$RWSERVER_CONF" "maxEngine")"
ENG_LIFE="$( rws_engine_attr "$RWSERVER_CONF" "engLife")"
ENG_IDLE="$( rws_engine_attr "$RWSERVER_CONF" "maxIdle")"
ENG_CB="$(   rws_engine_attr "$RWSERVER_CONF" "callbackTimeOut")"
ENG_RESP="$( rws_engine_attr "$RWSERVER_CONF" "engineResponseTimeOut")"
ENG_JVM="$(  rws_engine_attr "$RWSERVER_CONF" "jvmOptions")"
NCPU="$(nproc 2>/dev/null || printf 1)"

_show "Engine id:"                 "${ENG_ID:-(not found)}"
_show "initEngine:"                "${ENG_INIT:-(default 1)}"
_show "minEngine:"                 "${ENG_MIN:-(default 0)}"
_show "maxEngine:"                 "${ENG_MAX:-(default 1)}"
_show "engLife:"                   "${ENG_LIFE:-(default 50)}"
_show "maxIdle (min):"             "${ENG_IDLE:-(default 30)}"
_show "callbackTimeOut (ms):"      "${ENG_CB:-(default 90000)}"
_show "engineResponseTimeOut:"     "${ENG_RESP:-(not set)}"
_show "jvmOptions:"                "${ENG_JVM:-(not set)}"
_show "CPUs:"                      "$NCPU"

_min="${ENG_MIN:-0}"; _max="${ENG_MAX:-1}"; _init="${ENG_INIT:-1}"; _life="${ENG_LIFE:-50}"

if [ "$_min" -eq 0 ] 2>/dev/null; then
    warn "minEngine=0 – no engine kept running, a request after maxIdle triggers a cold start"
    info "  production: minEngine >= 1 (this repository: 2)"
else
    ok "$(printf "minEngine=%s – engines kept running" "$_min")"
fi

if [ "$_min" -gt "$_init" ] 2>/dev/null; then
    warn "$(printf "minEngine (%s) > initEngine (%s) – Oracle: minEngine between 0 and initEngine" "$_min" "$_init")"
fi

if [ "$_max" -lt "$_min" ] 2>/dev/null || [ "$_max" -lt "$_init" ] 2>/dev/null; then
    fail "$(printf "maxEngine (%s) < minEngine (%s) / initEngine (%s)" "$_max" "$_min" "$_init")"
elif [ "$_max" -le 1 ] 2>/dev/null; then
    warn "maxEngine=${_max} – one engine, concurrent reports queue"
elif [ "$_max" -gt $(( NCPU * 4 )) ] 2>/dev/null; then
    warn "$(printf "maxEngine=%s > 4 x %s CPUs – Oracle: maximum throughput at 2-4 engines per CPU, more overloads the host" "$_max" "$NCPU")"
else
    ok "$(printf "maxEngine=%s (Oracle: <= 2-4 per CPU = %s-%s)" "$_max" $(( NCPU * 2 )) $(( NCPU * 4 )))"
fi

if [ "$_life" -gt 1000 ] 2>/dev/null; then
    warn "$(printf "engLife=%s – engines rarely recycled (Oracle: engLife thwarts memory leaks)" "$_life")"
else
    ok "$(printf "engLife=%s jobs per engine" "$_life")"
fi

[ -z "$ENG_RESP" ] && \
    info "engineResponseTimeOut not set – a hanging engine (job without status update) is never killed"

if rws_has_url_engine "$RWSERVER_CONF"; then
    info "URL engine (rwURLEng) active – Oracle: comment it out if URL jobs (jobType=rwurl) are not used"
fi

# =============================================================================
# 3. Engine JVM heap vs. RAM
# =============================================================================

printLine
section "Engine JVM Heap"

RWS_PID="$(rws_server_pid "${RWS_COMP_NAME:-}")"
ENG_PIDS="$(rws_engine_pids "$RWS_PID")"

XMX_CFG="$(printf "%s" "${ENG_JVM:-}" | grep -oE '\-Xmx[0-9]+[kKmMgG]?' | tail -1)"
XMX_LIVE=""
ENG_RSS_MB=0
if [ -n "$ENG_PIDS" ]; then
    for _p in ${ENG_PIDS//,/ }; do
        _x="$(tr '\0' '\n' < "/proc/$_p/cmdline" 2>/dev/null | grep -E '^-Xmx' | tail -1)"
        [ -n "$_x" ] && XMX_LIVE="$_x"
        _r="$(awk '/^VmRSS/ {print int($2/1024)}' "/proc/$_p/status" 2>/dev/null)"
        ENG_RSS_MB=$(( ENG_RSS_MB + ${_r:-0} ))
        _show "Engine PID $_p:" "$(printf "%s, RSS %s MB" "${_x:-(no -Xmx)}" "${_r:--}")"
    done
fi

if [ -n "$XMX_CFG" ]; then
    XMX="$XMX_CFG"; _src="jvmOptions"
elif [ -n "$XMX_LIVE" ]; then
    XMX="$XMX_LIVE"; _src="running engines (Reports default, jvmOptions not set)"
else
    XMX=""; _src=""
fi

if [ -z "$XMX" ]; then
    info "Engine -Xmx unknown (jvmOptions not set, no engine running) – heap check skipped"
else
    xmx_mb="$(_to_mb "$XMX")"
    total_heap_mb=$(( xmx_mb * _max ))
    avail_mb="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    usable_mb=$(( ${avail_mb:-0} + ENG_RSS_MB ))
    _show "Engine -Xmx:"           "$XMX  ($_src)"
    _show "maxEngine x -Xmx:"      "$(printf "%s x %s MB = %s MB" "$_max" "$xmx_mb" "$total_heap_mb")"
    _show "RAM for engines:"       "$(printf "%s MB (MemAvailable %s + running engines %s)" "$usable_mb" "${avail_mb:--}" "$ENG_RSS_MB")"
    if [ "$usable_mb" -gt 0 ] && [ "$total_heap_mb" -gt $(( usable_mb * 80 / 100 )) ]; then
        warn "Full engine pool would need > 80% of the RAM left – reduce maxEngine or -Xmx, or add RAM"
    else
        ok "Full engine pool fits into the available RAM"
    fi
    info "  heap = only part of an engine process – native Reports code + metaspace come on top"
fi

# =============================================================================
# 4. Queue, connections, cache
# =============================================================================

printLine
section "Queue, Connections, Cache (rwserver.conf)"

Q_MAX="$(    rws_elem_attr  "$RWSERVER_CONF" "queue"      "maxQueueSize")"
C_MAX="$(    rws_elem_attr  "$RWSERVER_CONF" "connection" "maxConnect")"
C_IDLE="$(   rws_elem_attr  "$RWSERVER_CONF" "connection" "idleTimeOut")"
CACHE_SIZE="$(rws_cache_prop "$RWSERVER_CONF" "cacheSize")"
CACHE_DIR="$( rws_cache_prop "$RWSERVER_CONF" "cacheDir")"
[ -z "$CACHE_DIR" ] && CACHE_DIR="$DOMAIN_HOME/reports/cache"

_show "maxQueueSize:"      "${Q_MAX:--}"
_show "maxConnect:"        "${C_MAX:--}"
_show "idleTimeOut:"       "${C_IDLE:--}"
_show "cacheSize (MB):"    "${CACHE_SIZE:--}"
if [ -d "$CACHE_DIR" ]; then
    _show "Cache dir:"     "$(printf "%s (%s, %s files)" "$CACHE_DIR" "$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)" "$(find "$CACHE_DIR" -type f 2>/dev/null | wc -l)")"
else
    info "Cache dir not found: $CACHE_DIR"
fi
info "  Oracle sizing: maxQueueSize = jobs/min x expiration; cacheSize = maxQueueSize x average output size"

# =============================================================================
# 5. Drift against environment.conf (09-Install/13- rewrites rwserver.conf)
# =============================================================================

printLine
section "rwserver.conf vs. environment.conf"

DRIFT=0
_cmp() {
    local label="$1" envval="$2" confval="$3"
    [ -z "$envval" ] && return
    if [ "$envval" = "$confval" ]; then
        ok "$(printf "%-14s %s" "$label" "$confval")"
    else
        warn "$(printf "%-14s rwserver.conf=%s  environment.conf=%s" "$label" "${confval:--}" "$envval")"
        DRIFT=1
    fi
}
_cmp "initEngine"   "${REPORTS_ENGINE_INIT:-}" "$ENG_INIT"
_cmp "minEngine"    "${REPORTS_ENGINE_MIN:-}"  "$ENG_MIN"
_cmp "maxEngine"    "${REPORTS_ENGINE_MAX:-}"  "$ENG_MAX"
_cmp "maxConnect"   "${REPORTS_MAX_CONNECT:-}" "$C_MAX"
_cmp "maxQueueSize" "${REPORTS_MAX_QUEUE:-}"   "$Q_MAX"
[ "$DRIFT" -eq 1 ] && \
    info "  09-Install/13-oracle_setup_reports.sh --apply rewrites rwserver.conf from environment.conf"

# =============================================================================
# 6. Live engine processes
# =============================================================================

printLine
section "Live Engine Processes"

ENG_COUNT=0
[ -n "$ENG_PIDS" ] && ENG_COUNT="$(printf '%s\n' "$ENG_PIDS" | tr ',' '\n' | wc -l)"
_show "Reports server PID:" "${RWS_PID:-(not running)}"
_show "Engine processes:"   "$(printf "%s  (PID: %s)" "$ENG_COUNT" "${ENG_PIDS:--}")"

if [ -z "$RWS_PID" ]; then
    warn "Reports server '${RWS_COMP_NAME:-?}' not running"
    info "  Start: ./01-Run/startStop.sh start ${RWS_COMP_NAME:-repserver01} --apply"
elif [ "$ENG_COUNT" -lt "$_min" ] 2>/dev/null; then
    warn "$(printf "Running engines (%s) < minEngine (%s)" "$ENG_COUNT" "$_min")"
elif [ "$ENG_COUNT" -ge "$_max" ] 2>/dev/null; then
    warn "$(printf "Running engines (%s) = maxEngine (%s) – pool at capacity" "$ENG_COUNT" "$_max")"
    info "  Load analysis: ./05-ReportsPerformance/engine_perf_analyse.sh"
else
    ok "$(printf "Engine count %s within [%s-%s]" "$ENG_COUNT" "$_min" "$_max")"
fi

# =============================================================================
# 7. Interactive apply (report engine only)
# =============================================================================

if [ "$APPLY_MODE" -eq 1 ]; then
    printLine
    section "Apply – Update Report Engine '${ENG_ID:-?}'"

    if [ -z "$ENG_ID" ]; then
        fail "Report engine element not found – nothing changed"
        print_summary; exit "$EXIT_CODE"
    fi
    command -v python3 > /dev/null 2>&1 || { fail "python3 not found – needed to edit rwserver.conf"; print_summary; exit "$EXIT_CODE"; }

    info "Current values shown in brackets. Press Enter to keep."
    printf "\n"

    _prompt_num() {
        local label="$1" current="$2" answer
        while true; do
            printf "  %s [%s]: " "$label" "${current:--}" >&2
            read -r answer
            answer="${answer:-$current}"
            if [ -z "$answer" ] || _is_num "$answer"; then printf "%s" "$answer"; return; fi
            printf "  numbers only\n" >&2
        done
    }

    NEW_INIT="$(_prompt_num "initEngine"    "$ENG_INIT")"
    NEW_MIN="$( _prompt_num "minEngine"     "$ENG_MIN")"
    NEW_MAX="$( _prompt_num "maxEngine"     "$ENG_MAX")"
    NEW_LIFE="$(_prompt_num "engLife"       "$ENG_LIFE")"
    NEW_IDLE="$(_prompt_num "maxIdle (min)" "$ENG_IDLE")"
    while true; do
        printf "  %s [%s]: " "engine -Xmx (e.g. 512m, 1g; Enter = keep)" "${XMX_CFG#-Xmx}" >&2
        read -r NEW_XMX
        [ -z "$NEW_XMX" ] || [[ "$NEW_XMX" =~ ^[0-9]+[mMgG]$ ]] && break
        printf "  format: <number>m or <number>g\n" >&2
    done

    if [ "${NEW_MAX:-1}" -lt "${NEW_MIN:-0}" ] || [ "${NEW_MAX:-1}" -lt "${NEW_INIT:-1}" ]; then
        fail "maxEngine must be >= minEngine and >= initEngine – nothing changed"
        print_summary; exit "$EXIT_CODE"
    fi

    CHANGES=()
    [ "$NEW_INIT" != "$ENG_INIT" ] && CHANGES+=("initEngine=$NEW_INIT")
    [ "$NEW_MIN"  != "$ENG_MIN"  ] && CHANGES+=("minEngine=$NEW_MIN")
    [ "$NEW_MAX"  != "$ENG_MAX"  ] && CHANGES+=("maxEngine=$NEW_MAX")
    [ "$NEW_LIFE" != "$ENG_LIFE" ] && CHANGES+=("engLife=$NEW_LIFE")
    [ "$NEW_IDLE" != "$ENG_IDLE" ] && CHANGES+=("maxIdle=$NEW_IDLE")
    if [ -n "$NEW_XMX" ]; then
        if [ -n "$XMX_CFG" ]; then
            NEW_JVM="$(printf "%s" "$ENG_JVM" | sed "s/-Xmx[0-9][0-9]*[kKmMgG]\?/-Xmx${NEW_XMX}/")"
        else
            NEW_JVM="$(printf "%s -Xmx%s" "$ENG_JVM" "$NEW_XMX" | sed 's/^ //')"
        fi
        CHANGES+=("jvmOptions=$NEW_JVM")
    fi

    if [ "${#CHANGES[@]}" -eq 0 ]; then
        info "No changes"
        print_summary; exit "$EXIT_CODE"
    fi

    printf "\n  Changes to apply (engine %s):\n" "$ENG_ID"
    for _c in "${CHANGES[@]}"; do printf "    %s\n" "$_c"; done
    printf "\n"

    if ! askYesNo "Proceed and write rwserver.conf?" "n"; then
        info "Aborted – no changes written"
        print_summary
        exit 0
    fi

    backup_file "$RWSERVER_CONF" || { fail "Backup failed – aborting"; print_summary; exit 2; }

    for _c in "${CHANGES[@]}"; do
        if rws_set_engine_attr "$RWSERVER_CONF" "${_c%%=*}" "${_c#*=}"; then
            ok "$(printf "%s set" "$_c")"
        else
            fail "$(printf "%s could not be written" "$_c")"
        fi
    done

    # Keep environment.conf in line – 13- rewrites rwserver.conf from it
    _env_set() {
        local key="$1" val="$2"
        grep -q "^${key}=" "$ENV_CONF" || return 0
        sed -i --follow-symlinks "s|^${key}=.*|${key}=\"${val}\"|" "$ENV_CONF" \
            && ok "$(printf "environment.conf %s=%s" "$key" "$val")"
    }
    if [ "$NEW_INIT" != "$ENG_INIT" ] || [ "$NEW_MIN" != "$ENG_MIN" ] || [ "$NEW_MAX" != "$ENG_MAX" ]; then
        backup_file "$ENV_CONF" > /dev/null
        [ "$NEW_INIT" != "$ENG_INIT" ] && _env_set REPORTS_ENGINE_INIT "$NEW_INIT"
        [ "$NEW_MIN"  != "$ENG_MIN"  ] && _env_set REPORTS_ENGINE_MIN  "$NEW_MIN"
        [ "$NEW_MAX"  != "$ENG_MAX"  ] && _env_set REPORTS_ENGINE_MAX  "$NEW_MAX"
    fi
    if [ "$NEW_LIFE" != "$ENG_LIFE" ] || [ "$NEW_IDLE" != "$ENG_IDLE" ] || [ -n "$NEW_XMX" ]; then
        warn "engLife / maxIdle / jvmOptions are not in environment.conf – 13-oracle_setup_reports.sh --apply resets them"
    fi

    ok "rwserver.conf updated: $RWSERVER_CONF"
    info "Restart the Reports server to apply the changes:"
    info "  ./01-Run/startStop.sh stop ${RWS_COMP_NAME:-repserver01} --apply && ./01-Run/startStop.sh start ${RWS_COMP_NAME:-repserver01} --apply"
fi

# =============================================================================
# Summary
# =============================================================================

print_summary
exit "$EXIT_CODE"
