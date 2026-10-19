#!/bin/bash
# =============================================================================
# Script   : forms_perf_settings.sh
# Purpose  : Do the Forms session / runtime parameters fit together and follow
#            Oracle's rules (Working with Oracle Forms 14.1.2)?
#            - timeout chain per config section:
#              heartBeat (formsweb.cfg, minutes) < FORMS_TIMEOUT (envFile)
#              and heartBeat < WLS session-timeout of the Forms servlet
#            - global parameters (only honoured in [default]):
#              maxRuntimeProcesses, allowNewConnections
#            - runtime pooling (prestartRuntimes …) incl. inheritance from [default]
#            - startup / network parameters (networkRetries, gzipCompressApplet)
#            --apply changes single keys in ONE section (backup first).
# Call     : ./forms_perf_settings.sh
#            ./forms_perf_settings.sh --apply --section default --set maxRuntimeProcesses=200
#            ./forms_perf_settings.sh --apply --section sepwin --unset heartBeat
#            ./forms_perf_settings.sh --apply --fix-prestart webstart
#            ./forms_perf_settings.sh --cfg /path/to/formsweb.cfg
# Options  : --cfg PATH            Evaluate / change another formsweb.cfg
#            --apply               Write the changes given by the options below
#            --section NAME        Section for --set / --unset (default: default)
#            --set KEY=VALUE       Set a key in the section (repeatable)
#            --unset KEY           Remove a key from the section (repeatable)
#            --fix-prestart NAME   Move prestart* from [default] into section NAME
#                                  (Oracle: do not set prestartRuntimes in [default])
#            --help                Show usage
# Requires : awk, sed, python3 (--apply), unzip (session-timeout)
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

_show() { printf "  %-30s %s\n" "$1" "$2" | tee -a "${LOG_FILE:-/dev/null}"; }
# _flt A OP B – decimal compare (heartBeat may be 0.5)
_flt() { awk -v a="$1" -v b="$3" -v op="$2" 'BEGIN { if (op=="<") exit !(a+0 < b+0); if (op==">=") exit !(a+0 >= b+0); exit 1 }'; }

# Global system parameters: Oracle reads them only from [default]
GLOBAL_KEYS="maxRuntimeProcesses allowNewConnections"
PRESTART_KEYS="prestartRuntimes prestartInit prestartMin prestartIncrement prestartTimeout"

# =============================================================================
# Arguments
# =============================================================================

OVERRIDE_CFG="" APPLY_MODE=0 TARGET_SECTION="default" FIX_PRESTART=""
SET_LIST=() UNSET_LIST=()

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-24s %s\n" "--cfg PATH"          "Evaluate / change another formsweb.cfg"
    printf "  %-24s %s\n" "--apply"             "Write the changes below (backup first)"
    printf "  %-24s %s\n" "--section NAME"      "Section for --set / --unset (default: default)"
    printf "  %-24s %s\n" "--set KEY=VALUE"     "Set a key (repeatable)"
    printf "  %-24s %s\n" "--unset KEY"         "Remove a key (repeatable)"
    printf "  %-24s %s\n" "--fix-prestart NAME" "Move prestart* from [default] into section NAME"
    printf "  %-24s %s\n" "--help"              "Show this help"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --cfg)          OVERRIDE_CFG="$2";   shift 2 ;;
        --apply)        APPLY_MODE=1;        shift ;;
        --section)      TARGET_SECTION="$2"; shift 2 ;;
        --set)          SET_LIST+=("$2");    shift 2 ;;
        --unset)        UNSET_LIST+=("$2");  shift 2 ;;
        --fix-prestart) FIX_PRESTART="$2";   shift 2 ;;
        --help|-h)      _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
    esac
done
for _kv in "${SET_LIST[@]}"; do
    [[ "$_kv" =~ ^[A-Za-z_][A-Za-z0-9_.]*=.*$ ]] || { printf "\033[31mERROR\033[0m --set needs KEY=VALUE: %s\n" "$_kv" >&2; exit 2; }
done

# =============================================================================
# Banner + files
# =============================================================================

printLine
section "Forms Session / Runtime Parameters – $(date '+%Y-%m-%d %H:%M:%S')"
_show "Host:"        "$(hostname -f 2>/dev/null || hostname)"
_show "DOMAIN_HOME:" "${DOMAIN_HOME}"
[ "$APPLY_MODE" -eq 1 ] && _show "Mode:" "APPLY (will write changes)"
printLine

if ! frm_find_files "$OVERRIDE_CFG"; then
    fail "formsweb.cfg not found – see ./06-FormsDiag/forms_settings.sh"
    print_summary; exit "$EXIT_CODE"
fi
ok "formsweb.cfg: $FRM_CFG"
mapfile -t SECTIONS < <(frm_sections "$FRM_CFG")

# =============================================================================
# 1. Timeout chain per section
# =============================================================================

section "Timeout Chain (heartBeat < FORMS_TIMEOUT, heartBeat < session-timeout)"

SESS_MIN="$(frm_session_timeout_min)"
_show "WLS session-timeout:" "$( [ -n "$SESS_MIN" ] && printf "%s min (formsapp.ear weblogic.xml)" "$SESS_MIN" || printf "(not readable)")"

printf "\n  \033[1m%-23s %-16s %-26s %s\033[0m\n" "Section" "heartBeat (min)" "FORMS_TIMEOUT (min)" "envFile" | tee -a "${LOG_FILE:-/dev/null}"
CHAIN_ERR=0
for _s in "${SECTIONS[@]}"; do
    _hb="$(frm_cfg_get "$FRM_CFG" "$_s" heartBeat)"; _hbs="set"
    [ -z "$_hb" ] && { _hb=2; _hbs="default"; }
    _ef="$(frm_cfg_get "$FRM_CFG" "$_s" envFile)"; _ef="${_ef:-default.env}"
    case "$_ef" in /*) _efp="$_ef" ;; *) _efp="$FRM_CONFIG_DIR/$_ef" ;; esac
    _to="$( [ -f "$_efp" ] && frm_env_get "$_efp" FORMS_TIMEOUT)"; _tos="set"
    [ -z "$_to" ] && { _to=15; _tos="default"; }
    # Oracle: valid 3-1440, 1/2 are treated like 3, > 1440 like 1440
    _toe="$_to"; [ "$_to" -lt 3 ] 2>/dev/null && _toe=3; [ "$_to" -gt 1440 ] 2>/dev/null && _toe=1440
    printf "  %-23s %-16s %-26s %s\n" "$_s" "$_hb ($_hbs)" "$_to ($_tos$( [ "$_toe" != "$_to" ] && printf ', acts as %s' "$_toe"))" "$_ef" | tee -a "${LOG_FILE:-/dev/null}"
    if ! _flt "$_hb" "<" "$_toe"; then
        fail "[$_s] heartBeat $_hb >= FORMS_TIMEOUT $_toe – Oracle: the runtime is terminated, the session becomes unresponsive"
        CHAIN_ERR=1
    fi
    if [ -n "$SESS_MIN" ] && ! _flt "$_hb" "<" "$SESS_MIN"; then
        warn "[$_s] heartBeat $_hb >= session-timeout $SESS_MIN – Oracle: session-timeout takes precedence"
        CHAIN_ERR=1
    fi
    _flt "$_hb" "<" "0.5" && warn "[$_s] heartBeat $_hb min – Oracle: too low causes a significant increase in network traffic"
done
printf "\n" | tee -a "${LOG_FILE:-/dev/null}"
[ "$CHAIN_ERR" -eq 0 ] && ok "Timeout chain consistent in all sections"
info "  FORMS_TIMEOUT = minutes without client contact before frmweb is terminated; heartBeat keeps idle sessions alive"

# =============================================================================
# 2. Global parameters ([default] only)
# =============================================================================

printLine
section "Global Parameters ([default] only)"

MRP="$(frm_cfg_get "$FRM_CFG" default maxRuntimeProcesses)"
ANC="$(frm_cfg_get "$FRM_CFG" default allowNewConnections)"
_show "maxRuntimeProcesses:" "${MRP:-(not set = 0, no limit)}"
_show "allowNewConnections:" "${ANC:-(not set = TRUE)}"

if [ -z "$MRP" ] || [ "$MRP" = "0" ]; then
    warn "maxRuntimeProcesses=0 – Oracle: no limit is not recommended, the system is vulnerable to Denial of Service"
    _avail="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    info "$(printf "  size it from RAM: (MemAvailable %s MB + frmweb RSS) / RSS of a real session under load" "${_avail:--}")"
    info "  RSS per session: ./06-FormsDiag/forms_perf_analyse.sh (measure with real users, idle pool processes are small)"
else
    ok "$(printf "maxRuntimeProcesses=%s" "$MRP")"
fi
case "${ANC,,}" in
    false) warn "allowNewConnections=FALSE – no new Forms sessions are accepted (maintenance mode?)" ;;
esac
for _s in "${SECTIONS[@]}"; do
    [ "$_s" = "default" ] && continue
    for _k in $GLOBAL_KEYS; do
        [ "$(frm_cfg_where "$FRM_CFG" "$_s" "$_k")" = "$_s" ] && \
            warn "[$_s] sets $_k – global parameter, Oracle reads it only from [default]"
    done
done

# =============================================================================
# 3. Runtime pooling (prestart)
# =============================================================================

printLine
section "Runtime Pooling (prestartRuntimes)"

PRE_DEF="$(frm_cfg_get "$FRM_CFG" default prestartRuntimes)"
EXPECT=0
printf "  \033[1m%-23s %-20s %-6s %-6s %-6s %s\033[0m\n" "Section" "prestartRuntimes" "Init" "Min" "Incr" "Timeout(min)" | tee -a "${LOG_FILE:-/dev/null}"
for _s in "${SECTIONS[@]}"; do
    _p="$(frm_cfg_get "$FRM_CFG" "$_s" prestartRuntimes)"
    [ "${_p,,}" = "true" ] || continue
    _w="$(frm_cfg_where "$FRM_CFG" "$_s" prestartRuntimes)"
    _i="$(frm_cfg_get "$FRM_CFG" "$_s" prestartInit)";  _i="${_i:-1}"
    _m="$(frm_cfg_get "$FRM_CFG" "$_s" prestartMin)";   _m="${_m:-0}"
    _n="$(frm_cfg_get "$FRM_CFG" "$_s" prestartIncrement)"
    _t="$(frm_cfg_get "$FRM_CFG" "$_s" prestartTimeout)"
    printf "  %-23s %-20s %-6s %-6s %-6s %s\n" "$_s" "true ($( [ "$_w" = "$_s" ] && printf own || printf 'from default'))" \
        "$_i" "$_m" "${_n:-0}" "${_t:-0 = never}" | tee -a "${LOG_FILE:-/dev/null}"
    EXPECT=$(( EXPECT + _i ))
    [ "$_m" -gt "$_i" ] 2>/dev/null && warn "[$_s] prestartMin ($_m) > prestartInit ($_i) – Oracle: Min must be <= Init"
done
if [ "$EXPECT" -eq 0 ]; then
    info "Runtime pooling not active (Oracle default) – each session starts its frmweb on connect"
else
    _show "Prestarted frmweb expected:" "$EXPECT (per WLS_FORMS JVM)"
fi
if [ "${PRE_DEF,,}" = "true" ]; then
    warn "prestartRuntimes=true in [default] – Oracle: \"Doing so will result in processes being started for all other configurations\""
    info "  fix: ./06-FormsDiag/forms_perf_settings.sh --apply --fix-prestart <section used in production>"
fi
info "  prestart* are read only at frmservlet initialization – restart WLS_FORMS after a change"

# =============================================================================
# 4. Startup / network parameters
# =============================================================================

printLine
section "Startup / Network Parameters ([default])"

NR="$(frm_cfg_get "$FRM_CFG" default networkRetries)"
GZ="$(frm_cfg_get "$FRM_CFG" default gzipCompressApplet)"
IT="$(frm_cfg_get "$FRM_CFG" default idleTimeout)"
_show "networkRetries:"     "${NR:-(not set = 0)}"
_show "gzipCompressApplet:" "${GZ:-(not set = FALSE)}"
_show "idleTimeout (s):"    "${IT:-(not set = no SYSTEM_CLIENT_IDLE event)}"
[ "${GZ,,}" = "true" ] || info "gzipCompressApplet=FALSE – Oracle: TRUE can reduce application start-up time (HTML/JNLP compressed)"

info "WLS_FORMS JVM heap (servlet + listener, NOT the frmweb sessions): ./02-Checks/weblogic_performance.sh"

# =============================================================================
# 5. Apply
# =============================================================================

if [ "$APPLY_MODE" -eq 1 ]; then
    printLine
    section "Apply"

    if [ -n "$FIX_PRESTART" ]; then
        printf '%s\n' "${SECTIONS[@]}" | grep -qx "$FIX_PRESTART" \
            || { fail "Section [$FIX_PRESTART] not in formsweb.cfg"; print_summary; exit "$EXIT_CODE"; }
        [ "$FIX_PRESTART" = "default" ] && { fail "--fix-prestart needs a named section, not default"; print_summary; exit "$EXIT_CODE"; }
    fi
    if [ "${#SET_LIST[@]}" -eq 0 ] && [ "${#UNSET_LIST[@]}" -eq 0 ] && [ -z "$FIX_PRESTART" ]; then
        info "Nothing to change – use --set / --unset / --fix-prestart"
        print_summary; exit "$EXIT_CODE"
    fi
    printf '%s\n' "${SECTIONS[@]}" | grep -qx "$TARGET_SECTION" \
        || { fail "Section [$TARGET_SECTION] not in formsweb.cfg"; print_summary; exit "$EXIT_CODE"; }
    command -v python3 > /dev/null 2>&1 || { fail "python3 not found"; print_summary; exit "$EXIT_CODE"; }

    for _kv in "${SET_LIST[@]}"; do
        for _g in $GLOBAL_KEYS; do
            [ "${_kv%%=*}" = "$_g" ] && [ "$TARGET_SECTION" != "default" ] && \
                warn "${_g} is global – Oracle reads it only from [default] (use --section default)"
        done
    done

    backup_file "$FRM_CFG" || { fail "Backup failed – aborting"; print_summary; exit 2; }

    for _kv in "${SET_LIST[@]}"; do
        frm_cfg_set "$FRM_CFG" "$TARGET_SECTION" "${_kv%%=*}" "${_kv#*=}" \
            && ok "[$TARGET_SECTION] $_kv" || fail "[$TARGET_SECTION] $_kv not written"
    done
    for _k in "${UNSET_LIST[@]}"; do
        frm_cfg_unset "$FRM_CFG" "$TARGET_SECTION" "$_k" \
            && ok "[$TARGET_SECTION] $_k removed" || fail "[$TARGET_SECTION] $_k not removed"
    done

    if [ -n "$FIX_PRESTART" ]; then
        for _k in $PRESTART_KEYS; do
            _v="$(frm_cfg_get "$FRM_CFG" "$FIX_PRESTART" "$_k")"
            [ -z "$_v" ] && continue
            [ "$(frm_cfg_where "$FRM_CFG" "$FIX_PRESTART" "$_k")" = "default" ] || continue
            frm_cfg_set "$FRM_CFG" "$FIX_PRESTART" "$_k" "$_v" && ok "[$FIX_PRESTART] $_k=$_v"
        done
        for _k in $PRESTART_KEYS; do
            [ "$(frm_cfg_where "$FRM_CFG" default "$_k")" = "default" ] || continue
            frm_cfg_unset "$FRM_CFG" default "$_k" && ok "[default] $_k removed"
        done
        info "  persistent for re-installations: FORMS_PRESTART_SECTION=\"$FIX_PRESTART\" in environment.conf (14-oracle_setup_forms.sh)"
    fi

    ok "formsweb.cfg updated: $FRM_CFG"
    info "Restart WLS_FORMS for prestart changes (other keys apply to new sessions):"
    info "  ./01-Run/startStop.sh stop $(frm_wls_server) --apply && ./01-Run/startStop.sh start $(frm_wls_server) --apply"
fi

# =============================================================================
# Summary
# =============================================================================

print_summary
exit "$EXIT_CODE"
