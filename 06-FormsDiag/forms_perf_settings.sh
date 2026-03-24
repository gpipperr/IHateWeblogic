#!/bin/bash
# =============================================================================
# Script   : forms_perf_settings.sh
# Purpose  : Read and evaluate Oracle Forms performance-relevant parameters:
#            formsweb.cfg tuning settings, default.env timeouts,
#            WLS_FORMS JVM heap, session capacity estimate.
# Call     : ./forms_perf_settings.sh
#            ./forms_perf_settings.sh --forms-home /u01/oracle/fmw/forms
# Options  : --forms-home PATH   Explicit Forms home directory
#            --help              Show usage
# Requires : pgrep, grep, awk
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

OVERRIDE_FORMS_HOME=""

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-28s %s\n" "--forms-home PATH" "Explicit Forms home directory"
    printf "  %-28s %s\n" "--help"            "Show this help"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --forms-home) OVERRIDE_FORMS_HOME="$2"; shift 2 ;;
        --help|-h)    _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
    esac
done

# =============================================================================
# Config file detection helpers
# =============================================================================

_detect_forms_home() {
    local _oh="${ORACLE_HOME:-${FMW_HOME}}"
    [ -n "$OVERRIDE_FORMS_HOME" ] && { printf "%s" "$OVERRIDE_FORMS_HOME"; return; }
    [ -n "${ORACLE_FORMS_HOME:-}" ] && [ -d "$ORACLE_FORMS_HOME" ] && \
        { printf "%s" "$ORACLE_FORMS_HOME"; return; }
    local c="${_oh}/forms"
    [ -d "$c" ] && { printf "%s" "$c"; return; }
    find "${_oh:-/u01/oracle/fmw}" -maxdepth 4 -name "frmcmp" 2>/dev/null \
        | head -1 | sed 's|/bin/frmcmp||'
}

_find_formsweb_cfg() {
    local fh="$1"
    find "${DOMAIN_HOME}/config/fmwconfig/servers" \
        -maxdepth 5 -name "formsweb.cfg" 2>/dev/null | head -1 && return
    [ -f "${fh}/server/formsweb.cfg" ] && printf "%s" "${fh}/server/formsweb.cfg" && return
    find "${ORACLE_HOME:-${FMW_HOME:-/u01/oracle/fmw}}" -maxdepth 6 -name "formsweb.cfg" 2>/dev/null | head -1
}

_find_default_env() {
    local fh="$1"
    find "${DOMAIN_HOME}/config/fmwconfig/servers" \
        -maxdepth 5 -name "default.env" 2>/dev/null | head -1 && return
    [ -f "${fh}/server/default.env" ] && printf "%s" "${fh}/server/default.env" && return
    find "${ORACLE_HOME:-${FMW_HOME:-/u01/oracle/fmw}}" -maxdepth 6 -name "default.env" 2>/dev/null | head -1
}

# Read a key=value from formsweb.cfg (last occurrence wins, matches global + per-section)
_cfg_val() {
    local file="$1"
    local key="$2"
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null \
        | tail -1 | sed "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//"
}

# Read a key=value from default.env (shell variable assignment syntax)
_env_val() {
    local file="$1"
    local key="$2"
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null \
        | tail -1 | sed "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//" \
        | tr -d '"'"'"
}

# =============================================================================
# Banner
# =============================================================================

printLine
section "Forms Performance Settings – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-26s %s\n" "Host:"        "$(hostname -f 2>/dev/null || hostname)" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "DOMAIN_HOME:" "${DOMAIN_HOME}"                          | tee -a "${LOG_FILE:-/dev/null}"
printLine

FORMS_HOME="$(_detect_forms_home)"
FORMSWEB_CFG="$(_find_formsweb_cfg "$FORMS_HOME")"
DEFAULT_ENV_FILE="$(_find_default_env "$FORMS_HOME")"

[ -n "$FORMSWEB_CFG"    ] && ok "formsweb.cfg:  $FORMSWEB_CFG"    || warn "formsweb.cfg not found"
[ -n "$DEFAULT_ENV_FILE" ] && ok "default.env:   $DEFAULT_ENV_FILE" || warn "default.env not found"

# =============================================================================
# 1. formsweb.cfg – Performance Parameters
# =============================================================================

printLine
section "formsweb.cfg – Performance Parameters"

if [ -n "$FORMSWEB_CFG" ] && [ -f "$FORMSWEB_CFG" ]; then

    HBEAT="$(      _cfg_val "$FORMSWEB_CFG" "heartbeatInterval")"
    MAXEVT="$(     _cfg_val "$FORMSWEB_CFG" "maxEventBunchSize")"
    NETRETRY="$(   _cfg_val "$FORMSWEB_CFG" "networkRetries")"
    LOOK="$(       _cfg_val "$FORMSWEB_CFG" "lookAndFeel")"
    SEPFRAME="$(   _cfg_val "$FORMSWEB_CFG" "separateFrame")"
    LOGO="$(       _cfg_val "$FORMSWEB_CFG" "logo")"
    SPLASHSCREEN="$(_cfg_val "$FORMSWEB_CFG" "splashScreen")"
    DOWNSIZING="$( _cfg_val "$FORMSWEB_CFG" "downsizing")"
    ENVFILE="$(    _cfg_val "$FORMSWEB_CFG" "envFile")"
    JINITIATOR="$( _cfg_val "$FORMSWEB_CFG" "jinit_version")"

    printf "  %-32s %s\n" "heartbeatInterval:"   "${HBEAT:-(default: 120s)}"   | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-32s %s\n" "maxEventBunchSize:"   "${MAXEVT:-(default: 25)}"    | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-32s %s\n" "networkRetries:"      "${NETRETRY:-(default: 3)}"   | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-32s %s\n" "lookAndFeel:"         "${LOOK:-(default: Generic)}" | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-32s %s\n" "separateFrame:"       "${SEPFRAME:-(default: true)}"|  tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-32s %s\n" "splashScreen:"        "${SPLASHSCREEN:-(default)}"  | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-32s %s\n" "downsizing:"          "${DOWNSIZING:-(default)}"    | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-32s %s\n" "envFile:"             "${ENVFILE:-(default.env)}"   | tee -a "${LOG_FILE:-/dev/null}"

    # --- Evaluations ---

    # heartbeatInterval: 0 = disabled (sessions may timeout on some load balancers)
    #                    very small (< 30s) = unnecessary network load
    if [ -n "$HBEAT" ]; then
        if [ "$HBEAT" -eq 0 ] 2>/dev/null; then
            warn "heartbeatInterval=0 – keepalive disabled; load balancers may drop idle sessions"
            info "  Recommendation: set heartbeatInterval=120 (or match LB idle timeout)"
        elif [ "$HBEAT" -lt 30 ] 2>/dev/null; then
            warn "$(printf "heartbeatInterval=%s s – very frequent; increases server load" "$HBEAT")"
            info "  Recommendation: heartbeatInterval >= 60 (production: 120)"
        else
            ok "$(printf "heartbeatInterval=%s s" "$HBEAT")"
        fi
    fi

    # maxEventBunchSize: too small = more round-trips, too large = single large payload
    if [ -n "$MAXEVT" ]; then
        if [ "$MAXEVT" -lt 10 ] 2>/dev/null; then
            warn "$(printf "maxEventBunchSize=%s – low; more network round-trips per action" "$MAXEVT")"
            info "  Recommendation: maxEventBunchSize=25 (default) or higher on LAN"
        elif [ "$MAXEVT" -gt 100 ] 2>/dev/null; then
            warn "$(printf "maxEventBunchSize=%s – very high; large payloads per round-trip" "$MAXEVT")"
        else
            ok "$(printf "maxEventBunchSize=%s" "$MAXEVT")"
        fi
    fi

    # lookAndFeel: Oracle look = heavier JS; Generic = lighter
    case "${LOOK,,}" in
        oracle)
            info "lookAndFeel=Oracle – richer UI, slightly heavier client-side rendering"
            ;;
        generic|"")
            ok "lookAndFeel=Generic (or default) – lighter client rendering"
            ;;
    esac

    # splashScreen / logo: can be set to no to speed up initial load
    if [ "${SPLASHSCREEN,,}" = "yes" ] || [ "${SPLASHSCREEN,,}" = "true" ]; then
        info "splashScreen enabled – adds perceived startup time on first load"
    fi

else
    warn "formsweb.cfg not available – performance parameter evaluation skipped"
fi

# =============================================================================
# 2. default.env – Timeout and Environment Settings
# =============================================================================

printLine
section "default.env – Timeouts and Environment"

if [ -n "$DEFAULT_ENV_FILE" ] && [ -f "$DEFAULT_ENV_FILE" ]; then

    FORMS_TIMEOUT="$(_env_val "$DEFAULT_ENV_FILE" "FORMS_TIMEOUT")"
    FORMS_USERENV="$(_env_val "$DEFAULT_ENV_FILE" "FORMS_USERENV")"
    ORACLE_HOME_ENV="$(_env_val "$DEFAULT_ENV_FILE" "ORACLE_HOME")"
    TWO_TASK="$(_env_val "$DEFAULT_ENV_FILE" "TWO_TASK")"
    TNS_ADMIN="$(_env_val "$DEFAULT_ENV_FILE" "TNS_ADMIN")"

    printf "  %-26s %s\n" "FORMS_TIMEOUT:"  "${FORMS_TIMEOUT:-(not set, OS default)}" | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "FORMS_USERENV:"  "${FORMS_USERENV:-(not set)}"             | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "ORACLE_HOME:"    "${ORACLE_HOME_ENV:-(not set)}"           | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "TWO_TASK:"       "${TWO_TASK:-(not set)}"                  | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "TNS_ADMIN:"      "${TNS_ADMIN:-(not set)}"                 | tee -a "${LOG_FILE:-/dev/null}"

    # Evaluations
    if [ -n "$FORMS_TIMEOUT" ] && [ "$FORMS_TIMEOUT" -gt 0 ] 2>/dev/null; then
        if [ "$FORMS_TIMEOUT" -lt 10 ] 2>/dev/null; then
            warn "$(printf "FORMS_TIMEOUT=%s min – very short; sessions may expire during normal use" \
                "$FORMS_TIMEOUT")"
            info "  Recommendation: FORMS_TIMEOUT=60 or higher"
        else
            ok "$(printf "FORMS_TIMEOUT=%s min" "$FORMS_TIMEOUT")"
        fi
    else
        info "FORMS_TIMEOUT not set – using OS/WLS session timeout default"
    fi

    if [ -n "$TNS_ADMIN" ] && [ ! -d "$TNS_ADMIN" ]; then
        warn "TNS_ADMIN directory not found: $TNS_ADMIN"
    fi

    ok "default.env parsed"
else
    warn "default.env not available – timeout evaluation skipped"
fi

# =============================================================================
# 3. WLS_FORMS JVM Heap
# =============================================================================

printLine
section "WLS_FORMS JVM Heap"

WLS_FORMS_PID="$(pgrep -f 'weblogic.Name=WLS_FORMS' 2>/dev/null | head -1)"

if [ -n "$WLS_FORMS_PID" ]; then
    ok "WLS_FORMS running (PID $WLS_FORMS_PID)"

    # Extract -Xms/-Xmx from process command line
    JVM_CMDLINE="$(tr '\0' ' ' < "/proc/${WLS_FORMS_PID}/cmdline" 2>/dev/null)"
    JVM_XMS="$(printf "%s" "$JVM_CMDLINE" | grep -oE '\-Xms[0-9]+[mMgG]' | head -1)"
    JVM_XMX="$(printf "%s" "$JVM_CMDLINE" | grep -oE '\-Xmx[0-9]+[mMgG]' | head -1)"

    printf "  %-26s %s\n" "JVM -Xms:" "${JVM_XMS:-(not found in cmdline)}" | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "JVM -Xmx:" "${JVM_XMX:-(not found in cmdline)}" | tee -a "${LOG_FILE:-/dev/null}"

    # RSS of WLS_FORMS JVM
    WLS_RSS="$(ps -o rss= -p "$WLS_FORMS_PID" 2>/dev/null | tr -d ' ')"
    if [ -n "$WLS_RSS" ]; then
        WLS_RSS_MB=$(( WLS_RSS / 1024 ))
        printf "  %-26s %s MB\n" "WLS_FORMS JVM RSS:" "$WLS_RSS_MB" | tee -a "${LOG_FILE:-/dev/null}"
    fi

    # Session capacity estimate
    FRMWEB_COUNT="$(pgrep -f "frmweb" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${FRMWEB_COUNT:-0}" -gt 0 ] && [ -n "$WLS_RSS" ]; then
        # Each frmweb session adds roughly 50–150 MB RSS to the native processes
        AVG_FRMWEB_MB=80  # conservative estimate
        EST_MAX=$(( WLS_RSS_MB / AVG_FRMWEB_MB ))
        printf "  %-26s %s (active now: %s)\n" "Est. max sessions:" \
            "~${EST_MAX} (at ${AVG_FRMWEB_MB} MB/session)" "$FRMWEB_COUNT" \
            | tee -a "${LOG_FILE:-/dev/null}"
    fi

    # Check setDomainEnv.sh for Forms JVM settings
    SET_DOMAIN_ENV="${DOMAIN_HOME}/bin/setDomainEnv.sh"
    if [ -f "$SET_DOMAIN_ENV" ]; then
        FORMS_JVM_ARGS="$(grep -A2 'WLS_FORMS\|FORMS_JVM\|forms.*Xmx\|Xmx.*forms' \
            "$SET_DOMAIN_ENV" 2>/dev/null | head -5)"
        if [ -n "$FORMS_JVM_ARGS" ]; then
            printf "\n  From setDomainEnv.sh:\n" | tee -a "${LOG_FILE:-/dev/null}"
            printf "%s" "$FORMS_JVM_ARGS" | while IFS= read -r ln; do
                printf "    %s\n" "$ln" | tee -a "${LOG_FILE:-/dev/null}"
            done
        fi
    fi
else
    warn "WLS_FORMS not running – JVM heap check skipped"
    info "  Check JVM settings in: ${DOMAIN_HOME}/bin/setDomainEnv.sh"

    # Try to extract from setDomainEnv.sh statically
    SET_DOMAIN_ENV="${DOMAIN_HOME}/bin/setDomainEnv.sh"
    if [ -f "$SET_DOMAIN_ENV" ]; then
        FORMS_JVM_LINE="$(grep -i 'FORMS\|WLS_FORMS' "$SET_DOMAIN_ENV" 2>/dev/null \
            | grep -i 'Xmx\|heap' | head -3)"
        if [ -n "$FORMS_JVM_LINE" ]; then
            printf "\n  From setDomainEnv.sh (server not running):\n" \
                | tee -a "${LOG_FILE:-/dev/null}"
            printf "%s" "$FORMS_JVM_LINE" | while IFS= read -r ln; do
                printf "    %s\n" "$ln" | tee -a "${LOG_FILE:-/dev/null}"
            done
        else
            info "No Forms-specific JVM heap settings found in setDomainEnv.sh"
        fi
    fi
fi

# =============================================================================
# Summary
# =============================================================================

print_summary
exit "$EXIT_CODE"
