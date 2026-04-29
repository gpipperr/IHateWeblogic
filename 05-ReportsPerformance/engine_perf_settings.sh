#!/bin/bash
# =============================================================================
# Script   : engine_perf_settings.sh
# Purpose  : Read, evaluate and (optionally) update Oracle Reports engine and
#            cache tuning parameters in rwserver.conf.
# Call     : ./engine_perf_settings.sh
#            ./engine_perf_settings.sh --apply
#            ./engine_perf_settings.sh --conf /path/to/rwserver.conf
# Options  : --apply         Interactive dialog to update parameters (with backup)
#            --conf PATH     Explicit path to rwserver.conf
#            --help          Show usage
# Requires : pgrep, sed, awk
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
# Helper: extract XML attribute from a file (join lines first)
# =============================================================================
_xml_attr() {
    local file="$1"
    local attr="$2"
    { tr -d '\n' < "$file"; printf "\n"; } \
        | sed -n "s/.*[[:space:]]${attr}=\"\([^\"]*\)\".*/\1/p"
}

# Extract engine attribute – tries singular and plural form (minEngine / minEngines)
_engine_attr() {
    local file="$1"
    local base="$2"
    local val
    val="$(_xml_attr "$file" "${base}")"
    [ -z "$val" ] && val="$(_xml_attr "$file" "${base}s")"
    printf "%s" "$val"
}

# Update a single XML attribute in a file via sed (in-place with backup extension).
# Usage: _set_attr FILE attrname newvalue
_set_attr() {
    local file="$1"
    local attr="$2"
    local newval="$3"
    # Match both minEngine="..." and minEngines="..."
    sed -i "s/\b${attr}s\?=\"[^\"]*\"/${attr}=\"${newval}\"/g" "$file"
}

# =============================================================================
# Arguments
# =============================================================================

APPLY_MODE=0
OVERRIDE_CONF=""

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-24s %s\n" "--apply"       "Interactive update of tuning parameters (backup first)"
    printf "  %-24s %s\n" "--conf PATH"   "Explicit path to rwserver.conf"
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
printf "  %-26s %s\n" "Host:"        "$(hostname -f 2>/dev/null || hostname)"  | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "DOMAIN_HOME:" "${DOMAIN_HOME}"                           | tee -a "${LOG_FILE:-/dev/null}"
[ "$APPLY_MODE" -eq 1 ] && \
    printf "  %-26s %s\n" "Mode:" "APPLY (will write changes)"  | tee -a "${LOG_FILE:-/dev/null}"
printLine

# =============================================================================
# 1. Locate rwserver.conf
# =============================================================================

section "Locating rwserver.conf"

RWSERVER_CONF="${OVERRIDE_CONF:-${RWSERVER_CONF:-}}"

if [ -z "$RWSERVER_CONF" ] || [ ! -f "$RWSERVER_CONF" ]; then
    RWSERVER_CONF="$(find "${DOMAIN_HOME}/config" -name "rwserver.conf" 2>/dev/null | head -1)"
fi

if [ -z "$RWSERVER_CONF" ] || [ ! -f "$RWSERVER_CONF" ]; then
    fail "rwserver.conf not found under $DOMAIN_HOME/config"
    info "Re-run: 00-Setup/init_env.sh to detect the Reports component path"
    print_summary
    exit "$EXIT_CODE"
fi

ok "Found: $RWSERVER_CONF"

# =============================================================================
# 2. Engine Parameters
# =============================================================================

printLine
section "Engine Parameters (rwserver.conf)"

RS_NAME="$(sed -n 's/.*<server[^>]*name="\([^"]*\)".*/\1/p' "$RWSERVER_CONF" 2>/dev/null | head -1)"
ENG_MIN="$(  _engine_attr "$RWSERVER_CONF" "minEngine")"
ENG_MAX="$(  _engine_attr "$RWSERVER_CONF" "maxEngine")"
ENG_LIFE="$( _engine_attr "$RWSERVER_CONF" "engLife")"
ENG_INIT="$( _xml_attr    "$RWSERVER_CONF" "initTime")"
ENG_IDLE="$( _xml_attr    "$RWSERVER_CONF" "maxIdle")"
ENG_TYPE="$( _xml_attr    "$RWSERVER_CONF" "engineType")"
ENG_JVM="$(  _xml_attr    "$RWSERVER_CONF" "jvmOptions")"

printf "  %-26s %s\n" "Server name:"  "${RS_NAME:-(not found)}" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "Engine type:"  "${ENG_TYPE:--}"          | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "minEngine:"    "${ENG_MIN:--}"           | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "maxEngine:"    "${ENG_MAX:--}"           | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "engLife:"      "${ENG_LIFE:--}"          | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "initTime:"     "${ENG_INIT:--}"          | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "maxIdle:"      "${ENG_IDLE:--}"          | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "jvmOptions:"   "${ENG_JVM:--}"           | tee -a "${LOG_FILE:-/dev/null}"

# Extract -Xms / -Xmx from jvmOptions
JVM_XMS="$(printf "%s" "${ENG_JVM:-}" | grep -oE '\-Xms[0-9]+[mMgG]' | head -1)"
JVM_XMX="$(printf "%s" "${ENG_JVM:-}" | grep -oE '\-Xmx[0-9]+[mMgG]' | head -1)"
[ -n "$JVM_XMS" ] && printf "  %-26s %s\n" "  → Initial heap (-Xms):" "$JVM_XMS" | tee -a "${LOG_FILE:-/dev/null}"
[ -n "$JVM_XMX" ] && printf "  %-26s %s\n" "  → Max heap (-Xmx):"     "$JVM_XMX" | tee -a "${LOG_FILE:-/dev/null}"

# --- Evaluations ---

# minEngine cold-start risk
if [ -n "$ENG_MIN" ]; then
    if [ "$ENG_MIN" -eq 0 ] 2>/dev/null; then
        warn "minEngine=0 – no pre-started engine, first report request triggers cold start"
        info "  Recommendation: set minEngine >= 1 (production: >= 2)"
    elif [ "$ENG_MIN" -eq 1 ] 2>/dev/null; then
        warn "minEngine=1 – only one pre-started engine; concurrent requests may queue"
        info "  Recommendation: set minEngine >= 2 for production workloads"
    else
        ok "$(printf "minEngine=%s – pre-started engines available" "$ENG_MIN")"
    fi
fi

# maxEngine single-threaded bottleneck
if [ -n "$ENG_MAX" ]; then
    if [ "$ENG_MAX" -le 1 ] 2>/dev/null; then
        warn "maxEngine=${ENG_MAX} – single-threaded bottleneck; concurrent reports will queue"
        info "  Recommendation: set maxEngine >= 2"
    else
        ok "$(printf "maxEngine=%s" "$ENG_MAX")"
    fi
fi

# engLife – very high values mean engines never recycle (memory leak risk)
if [ -n "$ENG_LIFE" ] && [ "$ENG_LIFE" -gt 0 ] 2>/dev/null; then
    if [ "$ENG_LIFE" -gt 1000 ] 2>/dev/null; then
        warn "$(printf "engLife=%s – very high; engines will rarely recycle (memory leak risk)" "$ENG_LIFE")"
        info "  Recommendation: engLife 50–500"
    else
        ok "$(printf "engLife=%s" "$ENG_LIFE")"
    fi
fi

# Xmx vs available RAM (rough check)
if [ -n "$JVM_XMX" ] && [ -n "$ENG_MAX" ]; then
    # Convert Xmx to MB
    xmx_raw="${JVM_XMX#-Xmx}"
    xmx_unit="${xmx_raw: -1}"
    xmx_num="${xmx_raw%[mMgG]}"
    case "$xmx_unit" in
        [gG]) xmx_mb=$(( xmx_num * 1024 )) ;;
        *)    xmx_mb="$xmx_num" ;;
    esac
    total_heap_mb=$(( xmx_mb * ENG_MAX ))

    avail_mb="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    if [ -n "$avail_mb" ] && [ "$avail_mb" -gt 0 ]; then
        printf "  %-26s %s MB  (maxEngine × -Xmx = %s × %s MB)\n" \
            "Total engine heap:" "$total_heap_mb" "$ENG_MAX" "$xmx_mb" \
            | tee -a "${LOG_FILE:-/dev/null}"
        printf "  %-26s %s MB\n" "Available RAM:" "$avail_mb" | tee -a "${LOG_FILE:-/dev/null}"
        usage_pct=$(( total_heap_mb * 100 / avail_mb ))
        if [ "$usage_pct" -gt 80 ] 2>/dev/null; then
            warn "$(printf "Engine heap (%s MB) uses %s%% of available RAM – reduce maxEngine or -Xmx" \
                "$total_heap_mb" "$usage_pct")"
        else
            ok "$(printf "Engine heap %s MB = %s%% of available RAM" "$total_heap_mb" "$usage_pct")"
        fi
    fi
fi

# =============================================================================
# 3. Cache Parameters
# =============================================================================

printLine
section "Cache Parameters (rwserver.conf)"

CACHE_SIZE="$(   _xml_attr "$RWSERVER_CONF" "cacheSize")"
CACHE_MAXJOB="$( _xml_attr "$RWSERVER_CONF" "maxJobSize")"
CACHE_PURGE="$(  _xml_attr "$RWSERVER_CONF" "purgeTime")"

printf "  %-26s %s\n" "cacheSize:"   "${CACHE_SIZE:--}"   | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "maxJobSize:"  "${CACHE_MAXJOB:--}" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "purgeTime:"   "${CACHE_PURGE:--}"  | tee -a "${LOG_FILE:-/dev/null}"

# Cache directory size (if detectable)
CACHE_DIR="${DOMAIN_HOME}/servers/WLS_REPORTS/tmp/cache" 2>/dev/null
if [ -d "$CACHE_DIR" ]; then
    cache_du="$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)"
    printf "  %-26s %s\n" "Cache dir size:" "${cache_du:--}" | tee -a "${LOG_FILE:-/dev/null}"
    ok "Cache directory found: $CACHE_DIR"
else
    info "Cache directory not found at default path: $CACHE_DIR"
fi

# =============================================================================
# 4. Live Process Check
# =============================================================================

printLine
section "Live Engine Process Check"

RWENG_COUNT="$(pgrep -f "rwengine" 2>/dev/null | wc -l | tr -d ' ')"
RWENG_PIDS="$( pgrep -d ',' -f "rwengine" 2>/dev/null || printf "(none)")"

printf "  %-26s %s\n"    "Configured minEngine:" "${ENG_MIN:--}"    | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n"    "Configured maxEngine:" "${ENG_MAX:--}"    | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n"    "Running rwengine:"     "$RWENG_COUNT"     | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n"    "PIDs:"                 "$RWENG_PIDS"      | tee -a "${LOG_FILE:-/dev/null}"

if [ "$RWENG_COUNT" -eq 0 ] 2>/dev/null; then
    warn "No rwengine processes running – is the Reports Server started?"
    info "  Start: ./01-Run/startStop.sh start WLS_REPORTS --apply"
elif [ -n "$ENG_MIN" ] && [ "$RWENG_COUNT" -lt "$ENG_MIN" ] 2>/dev/null; then
    warn "$(printf "Running engines (%s) < minEngine (%s) – fewer engines than configured minimum" \
        "$RWENG_COUNT" "$ENG_MIN")"
elif [ -n "$ENG_MAX" ] && [ "$RWENG_COUNT" -ge "$ENG_MAX" ] 2>/dev/null; then
    warn "$(printf "Running engines (%s) >= maxEngine (%s) – pool at or near capacity" \
        "$RWENG_COUNT" "$ENG_MAX")"
    info "  Consider: increase maxEngine if reports are queuing"
else
    ok "$(printf "Engine count %s is within configured range [%s-%s]" \
        "$RWENG_COUNT" "${ENG_MIN:--}" "${ENG_MAX:--}")"
fi

# =============================================================================
# 5. Interactive Apply
# =============================================================================

if [ "$APPLY_MODE" -eq 1 ]; then
    printLine
    section "Apply – Update Engine Parameters"

    info "Current values shown in brackets. Press Enter to keep."
    printf "\n"

    # Helper: prompt for a numeric value
    _prompt_num() {
        local label="$1"
        local current="$2"
        local answer
        printf "  %s [%s]: " "$label" "${current:--}" >&2
        read -r answer
        answer="${answer:-$current}"
        printf "%s" "$answer"
    }

    NEW_MIN="$(  _prompt_num "minEngine"                      "$ENG_MIN")"
    NEW_MAX="$(  _prompt_num "maxEngine"                      "$ENG_MAX")"
    NEW_LIFE="$( _prompt_num "engLife"                        "$ENG_LIFE")"
    NEW_INIT="$( _prompt_num "initTime"                       "$ENG_INIT")"
    NEW_IDLE="$( _prompt_num "maxIdle"                        "$ENG_IDLE")"

    # JVM heap: prompt for Xmx separately (simpler UX)
    printf "  %s [%s]: " "jvmOptions -Xmx (e.g. 512m, 1g)" "${JVM_XMX#-Xmx}" >&2
    read -r NEW_XMX_RAW
    NEW_XMX_RAW="${NEW_XMX_RAW:-}"

    printf "\n"
    printf "  Changes to apply:\n"
    [ "$NEW_MIN"  != "$ENG_MIN"  ] && printf "    minEngine:  %s → %s\n" "${ENG_MIN:--}"  "$NEW_MIN"
    [ "$NEW_MAX"  != "$ENG_MAX"  ] && printf "    maxEngine:  %s → %s\n" "${ENG_MAX:--}"  "$NEW_MAX"
    [ "$NEW_LIFE" != "$ENG_LIFE" ] && printf "    engLife:    %s → %s\n" "${ENG_LIFE:--}" "$NEW_LIFE"
    [ "$NEW_INIT" != "$ENG_INIT" ] && printf "    initTime:   %s → %s\n" "${ENG_INIT:--}" "$NEW_INIT"
    [ "$NEW_IDLE" != "$ENG_IDLE" ] && printf "    maxIdle:    %s → %s\n" "${ENG_IDLE:--}" "$NEW_IDLE"
    [ -n "$NEW_XMX_RAW"         ] && printf "    -Xmx:       %s → %s\n" "${JVM_XMX#-Xmx}" "$NEW_XMX_RAW"
    printf "\n"

    if ! askYesNo "Proceed and write rwserver.conf?" "n"; then
        info "Aborted – no changes written"
        print_summary
        exit 0
    fi

    # Backup first
    backup_file "$RWSERVER_CONF" || { fail "Backup failed – aborting"; print_summary; exit 2; }

    # Write changes
    [ "$NEW_MIN"  != "$ENG_MIN"  ] && _set_attr "$RWSERVER_CONF" "minEngine" "$NEW_MIN"
    [ "$NEW_MAX"  != "$ENG_MAX"  ] && _set_attr "$RWSERVER_CONF" "maxEngine" "$NEW_MAX"
    [ "$NEW_LIFE" != "$ENG_LIFE" ] && _set_attr "$RWSERVER_CONF" "engLife"   "$NEW_LIFE"
    [ "$NEW_INIT" != "$ENG_INIT" ] && _set_attr "$RWSERVER_CONF" "initTime"  "$NEW_INIT"
    [ "$NEW_IDLE" != "$ENG_IDLE" ] && _set_attr "$RWSERVER_CONF" "maxIdle"   "$NEW_IDLE"

    if [ -n "$NEW_XMX_RAW" ]; then
        if [ -n "$JVM_XMX" ]; then
            # Replace existing -Xmx value
            sed -i "s/-Xmx[0-9][0-9]*[mMgG]/-Xmx${NEW_XMX_RAW}/" "$RWSERVER_CONF"
        else
            warn "-Xmx not found in jvmOptions – cannot update automatically"
            info "  Add manually to jvmOptions in: $RWSERVER_CONF"
        fi
    fi

    ok "rwserver.conf updated: $RWSERVER_CONF"
    info "Restart WLS_REPORTS to apply changes: ./01-Run/startStop.sh restart WLS_REPORTS --apply"
fi

# =============================================================================
# Summary
# =============================================================================

print_summary
exit "$EXIT_CODE"
