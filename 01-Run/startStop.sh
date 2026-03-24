#!/bin/bash
# =============================================================================
# Script   : startStop.sh
# Purpose  : Show WebLogic/Forms/Reports component status and start or stop
#            individual components or all in the correct sequence.
# Call     : ./startStop.sh
#            ./startStop.sh start AdminServer --apply
#            ./startStop.sh stop  WLS_REPORTS --apply
#            ./startStop.sh start-all --apply
#            ./startStop.sh stop-all  --apply
# Options  : list                Show status table (default)
#            start <component>   Start a specific component
#            stop  <component>   Stop a specific component
#            start-all           Start: NM -> AdminServer -> Managed -> OHS
#            stop-all            Stop:  OHS -> Managed -> AdminServer -> NM
#            --apply             Execute write operations (default: dry-run)
#            --help              Show usage
# Requires : ss (or netstat), pgrep, wlst.sh (for stop operations)
#            weblogic_sec.conf.des3 (for start/stop)
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
# Arguments
# =============================================================================

ACTION="list"
COMP_ARG=""
APPLY=false

_usage() {
    printf "Usage: %s [action] [component] [--apply]\n\n" "$(basename "$0")"
    printf "  %-30s %s\n" "(no args) | list"        "Show component status table"
    printf "  %-30s %s\n" "start <component>"       "Start a specific component"
    printf "  %-30s %s\n" "stop  <component>"       "Stop a specific component"
    printf "  %-30s %s\n" "start-all"               "Start all in order (NM->Admin->Managed->OHS)"
    printf "  %-30s %s\n" "stop-all"                "Stop all in reverse (OHS->Managed->Admin->NM)"
    printf "  %-30s %s\n" "--apply"                 "Execute operations (default: dry-run)"
    printf "\nExamples:\n"
    printf "  %s\n"                                  "$(basename "$0")"
    printf "  %s start AdminServer --apply\n"        "$(basename "$0")"
    printf "  %s stop  WLS_REPORTS --apply\n"        "$(basename "$0")"
    printf "  %s start-all --apply\n"                "$(basename "$0")"
    printf "  %s stop-all  --apply\n"                "$(basename "$0")"
    exit 1
}

while [ $# -gt 0 ]; do
    case "${1,,}" in
        list)       ACTION="list";      shift ;;
        start)      ACTION="start";     COMP_ARG="${2:-}"; shift; [ -n "$COMP_ARG" ] && shift ;;
        stop)       ACTION="stop";      COMP_ARG="${2:-}"; shift; [ -n "$COMP_ARG" ] && shift ;;
        start-all)  ACTION="start-all"; shift ;;
        stop-all)   ACTION="stop-all";  shift ;;
        --apply)    APPLY=true;         shift ;;
        --help|-h)  _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown argument: %s\n" "$1" >&2
            _usage
            ;;
    esac
done

if [[ "$ACTION" == "start" || "$ACTION" == "stop" ]] && [ -z "$COMP_ARG" ]; then
    printf "\033[31mERROR\033[0m '%s' requires a component name.\n" "$ACTION" >&2
    printf "  Example: %s %s AdminServer --apply\n" "$(basename "$0")" "$ACTION" >&2
    exit 1
fi

# =============================================================================
# Component registry  (parallel arrays – filled by _discover)
# =============================================================================

declare -a C_NAME=()    # component name
declare -a C_TYPE=()    # NM | ADMIN | MANAGED | OHS
declare -a C_HOST=()    # configured listen address
declare -a C_PORT=()    # primary port
declare -a C_STATUS=()  # RUNNING | STOPPED | UNKNOWN
declare -a C_PID=()     # PID or ""

# =============================================================================
# SS/netstat snapshot (reused for all port checks)
# =============================================================================

SS_CACHE="$(ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null)"

_port_listening() {
    echo "$SS_CACHE" | awk '{print $4}' | grep -qE ":${1}$"
}

# =============================================================================
# Discover components
# =============================================================================

_discover() {
    # --- 1. NodeManager ---
    local nm_props="$DOMAIN_HOME/nodemanager/nodemanager.properties"
    local nm_port="5556" nm_addr="localhost"
    if [ -f "$nm_props" ]; then
        local _p _a
        _p="$(grep -i '^ListenPort'    "$nm_props" 2>/dev/null | cut -d= -f2 | tr -d ' \r')"
        _a="$(grep -i '^ListenAddress' "$nm_props" 2>/dev/null | cut -d= -f2 | tr -d ' \r')"
        nm_port="${_p:-$nm_port}"
        nm_addr="${_a:-$nm_addr}"
    fi
    C_NAME+=("NodeManager"); C_TYPE+=("NM");
    C_HOST+=("$nm_addr");    C_PORT+=("$nm_port")
    C_STATUS+=("UNKNOWN");   C_PID+=("")

    # --- 2. WLS servers from config.xml ---
    local config_xml="$DOMAIN_HOME/config/config.xml"
    if [ -f "$config_xml" ]; then
        while IFS='|' read -r srv_name listen_addr listen_port _; do
            [ -z "$srv_name" ] && continue
            local ctype="MANAGED"
            [ "$srv_name" = "AdminServer" ] && ctype="ADMIN"
            C_NAME+=("$srv_name"); C_TYPE+=("$ctype")
            C_HOST+=("${listen_addr:-localhost}"); C_PORT+=("${listen_port:-}")
            C_STATUS+=("UNKNOWN"); C_PID+=("")
        done < <(awk '
            BEGIN { in_srv=0; in_ssl=0 }
            /<server>$/   { in_srv=1; name=""; addr=""; port="" }
            /<\/server>$/ {
                if (in_srv && name != "" && name != "TEMPLATE" && name != "template")
                    print name "|" addr "|" port "|"
                in_srv=0; in_ssl=0
            }
            in_srv && /<ssl>$/    { in_ssl=1 }
            in_srv && /<\/ssl>$/  { in_ssl=0 }
            in_srv && !in_ssl {
                if (match($0, /<name>([^<]+)<\/name>/, m))         name = m[1]
                if (match($0, /<listen-port>([^<]+)<\/listen-port>/, m)) port = m[1]
                if (match($0, /<listen-address>([^<]+)<\/listen-address>/, m)) addr = m[1]
            }
        ' "$config_xml")
    else
        # Fallback: AdminServer from WL_ADMIN_URL
        local fb_host fb_port
        fb_host="$(printf "%s" "${WL_ADMIN_URL:-t3://localhost:7001}" | sed 's|.*://||; s|:.*||')"
        fb_port="$(printf "%s" "${WL_ADMIN_URL:-t3://localhost:7001}" | sed 's|.*:||')"
        C_NAME+=("AdminServer"); C_TYPE+=("ADMIN")
        C_HOST+=("$fb_host");    C_PORT+=("$fb_port")
        C_STATUS+=("UNKNOWN");   C_PID+=("")
        warn "config.xml not found – only AdminServer (from WL_ADMIN_URL) listed"
    fi

    # --- 3. OHS system components (if present) ---
    local ohs_base="$DOMAIN_HOME/system_components/OHS"
    if [ -d "$ohs_base" ]; then
        for ohsdir in "$ohs_base"/*/; do
            [ -d "$ohsdir" ] || continue
            local ohs_name ohs_port=""
            ohs_name="$(basename "$ohsdir")"
            local httpd_conf="$ohsdir/httpd.conf"
            [ -f "$httpd_conf" ] && \
                ohs_port="$(grep -i '^Listen ' "$httpd_conf" 2>/dev/null | awk '{print $2}' | head -1)"
            C_NAME+=("$ohs_name"); C_TYPE+=("OHS")
            C_HOST+=("*");         C_PORT+=("${ohs_port:-8890}")
            C_STATUS+=("UNKNOWN"); C_PID+=("")
        done
    fi
}

# =============================================================================
# Refresh status for all components
# =============================================================================

_refresh_status() {
    local i
    for (( i=0; i < ${#C_NAME[@]}; i++ )); do
        local name="${C_NAME[$i]}" ctype="${C_TYPE[$i]}" port="${C_PORT[$i]}"
        local pid=""

        case "$ctype" in
            NM)
                pid="$(pgrep -f 'weblogic.nodemanager' 2>/dev/null | head -1)"
                [ -z "$pid" ] && pid="$(pgrep -f 'NodeManager' 2>/dev/null | head -1)"
                ;;
            ADMIN|MANAGED)
                pid="$(pgrep -f "Dweblogic.Name=${name}" 2>/dev/null | head -1)"
                ;;
            OHS)
                pid="$(pgrep -f "OHS/${name}" 2>/dev/null | head -1)"
                [ -z "$pid" ] && pid="$(pgrep -f "ohs/${name}" 2>/dev/null | head -1)"
                ;;
        esac

        C_PID[$i]="${pid:-}"

        if [ -n "$pid" ]; then
            C_STATUS[$i]="RUNNING"
        elif [ -n "$port" ] && _port_listening "$port"; then
            C_STATUS[$i]="RUNNING"
            C_PID[$i]="${pid:-port}"
        else
            C_STATUS[$i]="STOPPED"
        fi
    done
}

# =============================================================================
# Status table
# =============================================================================

_print_table() {
    printf "\n"
    printf "  \033[1m%-4s  %-24s  %-8s  %-10s  %-6s  %s\033[0m\n" \
        "#" "Component" "Type" "Status" "Port" "PID" | tee -a "${LOG_FILE:-/dev/null}"
    printLine
    local i
    for (( i=0; i < ${#C_NAME[@]}; i++ )); do
        local status="${C_STATUS[$i]}"
        local status_col
        case "$status" in
            RUNNING) status_col="\033[32m${status}\033[0m" ;;
            STOPPED) status_col="\033[31m${status}\033[0m" ;;
            *)       status_col="\033[33m${status}\033[0m" ;;
        esac
        printf "  %-4s  %-24s  %-8s  " \
            "$((i+1))" "${C_NAME[$i]}" "${C_TYPE[$i]}" | tee -a "${LOG_FILE:-/dev/null}"
        printf "${status_col}  \033[0m%-6s  %s\n" \
            "${C_PORT[$i]:--}" "${C_PID[$i]:--}"       | tee -a "${LOG_FILE:-/dev/null}"
    done
    printLine
}

# =============================================================================
# Helpers: find wlst.sh; run a WLST Python script non-interactively
# =============================================================================

WLST_SH=""

_find_wlst() {
    # ORACLE_HOME is the canonical variable in environment.conf; FMW_HOME is a legacy alias
    local _fmw_base="${ORACLE_HOME:-${FMW_HOME}}"
    WLST_SH="${_fmw_base}/oracle_common/common/bin/wlst.sh"
    if [ ! -x "$WLST_SH" ]; then
        local alt="${WL_HOME:-${_fmw_base}/wlserver}/common/bin/wlst.sh"
        if [ -x "$alt" ]; then
            WLST_SH="$alt"
        else
            fail "wlst.sh not found: $WLST_SH"
            info "Check FMW_HOME in environment.conf"
            return 1
        fi
    fi
    return 0
}

_run_wlst() {
    local py_content="$1"
    local tmp_py
    tmp_py="$(mktemp /tmp/wlst_action_XXXXXX.py)"
    chmod 600 "$tmp_py"
    printf "%s\n" "$py_content" > "$tmp_py"

    export _IHW_WL_USER="${WL_USER}"
    export _IHW_WL_PWD="${INTERNAL_WL_PWD}"
    export _IHW_WL_URL="${WL_ADMIN_URL}"

    "$WLST_SH" "$tmp_py"
    local rc=$?

    rm -f "$tmp_py"
    unset _IHW_WL_USER _IHW_WL_PWD _IHW_WL_URL 2>/dev/null || true
    return $rc
}

# =============================================================================
# Find component index by name (case-insensitive)
# =============================================================================

_find_comp() {
    local target="${1,,}"
    local i
    for (( i=0; i < ${#C_NAME[@]}; i++ )); do
        [ "${C_NAME[$i],,}" = "$target" ] && printf "%d" "$i" && return 0
    done
    return 1
}

# =============================================================================
# Start a component
# =============================================================================

_start_comp() {
    local name="$1" ctype="$2"
    local start_log="${DIAG_LOG_DIR:-/tmp}/start_${name}_$(date +%H%M%S).log"

    info "Starting $name (type=$ctype) ..."
    info "Output log: $start_log"

    case "$ctype" in
        NM)
            local nm_sh="$DOMAIN_HOME/bin/startNodeManager.sh"
            if [ ! -f "$nm_sh" ]; then fail "Not found: $nm_sh"; return 1; fi
            nohup "$nm_sh" > "$start_log" 2>&1 &
            ok "NodeManager start initiated (PID $!) – allow ~15s to come up"
            ;;
        ADMIN)
            local wl_sh="$DOMAIN_HOME/bin/startWebLogic.sh"
            if [ ! -f "$wl_sh" ]; then fail "Not found: $wl_sh"; return 1; fi
            nohup "$wl_sh" > "$start_log" 2>&1 &
            ok "AdminServer start initiated (PID $!) – allow ~60s to come up"
            ;;
        MANAGED)
            local mgd_sh="$DOMAIN_HOME/bin/startManagedWebLogic.sh"
            if [ ! -f "$mgd_sh" ]; then fail "Not found: $mgd_sh"; return 1; fi
            nohup "$mgd_sh" "$name" "${WL_ADMIN_URL:-t3://localhost:7001}" \
                > "$start_log" 2>&1 &
            ok "$name start initiated (PID $!) – allow ~60s to come up"
            ;;
        OHS)
            local start_sh="$DOMAIN_HOME/bin/startComponent.sh"
            if [ ! -f "$start_sh" ]; then fail "Not found: $start_sh"; return 1; fi
            "$start_sh" "$name" >> "$start_log" 2>&1
            local rc=$?
            [ "$rc" -eq 0 ] && ok "$name started" || fail "$name start failed (rc=$rc)"
            return $rc
            ;;
        *)
            fail "Unknown component type '$ctype'"
            return 1
            ;;
    esac
}

# =============================================================================
# Stop a component
# =============================================================================

_stop_comp() {
    local name="$1" ctype="$2" pid="$3"

    info "Stopping $name (type=$ctype) ..."

    case "$ctype" in
        NM)
            if [ -n "$pid" ] && [[ "$pid" =~ ^[0-9]+$ ]]; then
                kill "$pid" 2>/dev/null \
                    && ok "NodeManager (PID $pid) stopped" \
                    || { fail "kill $pid failed"; return 1; }
            else
                pkill -f 'weblogic.nodemanager' 2>/dev/null \
                    || pkill -f 'NodeManager'  2>/dev/null \
                    && ok "NodeManager stopped" \
                    || { fail "NodeManager process not found"; return 1; }
            fi
            ;;

        ADMIN)
            _find_wlst || return 1
            _run_wlst "$(cat <<'PYEOF'
import os
_u   = os.environ.get('_IHW_WL_USER', '')
_p   = os.environ.get('_IHW_WL_PWD',  '')
_url = os.environ.get('_IHW_WL_URL',  '')
connect(_u, _p, _url)
del _p
shutdown('AdminServer', 'Server', ignoreSessions='true', timeOut=60)
exit()
PYEOF
)" && ok "AdminServer shutdown complete" \
            || { fail "AdminServer shutdown via WLST failed"; return 1; }
            ;;

        MANAGED)
            _find_wlst || return 1
            # Note: heredoc unquoted so ${name} expands
            _run_wlst "$(cat <<PYEOF
import os
_u   = os.environ.get('_IHW_WL_USER', '')
_p   = os.environ.get('_IHW_WL_PWD',  '')
_url = os.environ.get('_IHW_WL_URL',  '')
connect(_u, _p, _url)
del _p
shutdown('${name}', 'Server', ignoreSessions='true', timeOut=60)
disconnect()
exit()
PYEOF
)" && ok "$name shutdown complete" \
            || { fail "$name shutdown via WLST failed"; return 1; }
            ;;

        OHS)
            local stop_sh="$DOMAIN_HOME/bin/stopComponent.sh"
            if [ ! -f "$stop_sh" ]; then fail "Not found: $stop_sh"; return 1; fi
            "$stop_sh" "$name"
            local rc=$?
            [ "$rc" -eq 0 ] && ok "$name stopped" || fail "$name stop failed (rc=$rc)"
            return $rc
            ;;

        *)
            fail "Unknown component type '$ctype'"
            return 1
            ;;
    esac
}

# =============================================================================
# Start-all: NM -> AdminServer -> Managed -> OHS
# =============================================================================

_start_all() {
    local i
    for ctype in "NM" "ADMIN" "MANAGED" "OHS"; do
        for (( i=0; i < ${#C_NAME[@]}; i++ )); do
            [ "${C_TYPE[$i]}" != "$ctype" ] && continue
            if [ "${C_STATUS[$i]}" = "RUNNING" ]; then
                info "${C_NAME[$i]} already RUNNING – skipping"
                continue
            fi
            section "Starting ${C_NAME[$i]}"
            _start_comp "${C_NAME[$i]}" "${C_TYPE[$i]}" || true
            # Brief pause after NM/Admin before starting dependents
            case "$ctype" in
                NM)    sleep 8  ;;
                ADMIN) sleep 12 ;;
            esac
        done
    done
}

# =============================================================================
# Stop-all: OHS -> Managed -> AdminServer -> NM
# =============================================================================

_stop_all() {
    local i
    for ctype in "OHS" "MANAGED" "ADMIN" "NM"; do
        for (( i=0; i < ${#C_NAME[@]}; i++ )); do
            [ "${C_TYPE[$i]}" != "$ctype" ] && continue
            if [ "${C_STATUS[$i]}" = "STOPPED" ]; then
                info "${C_NAME[$i]} already STOPPED – skipping"
                continue
            fi
            section "Stopping ${C_NAME[$i]}"
            _stop_comp "${C_NAME[$i]}" "${C_TYPE[$i]}" "${C_PID[$i]}" || true
        done
    done
}

# =============================================================================
# Main
# =============================================================================

printLine
section "Start/Stop Manager – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-22s %s\n" "Host:"        "$(hostname -f 2>/dev/null || hostname)" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-22s %s\n" "DOMAIN_HOME:" "${DOMAIN_HOME}"                          | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-22s %s\n" "Action:"      "${ACTION}${COMP_ARG:+ $COMP_ARG}"        | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-22s %s\n" "Mode:"        "$($APPLY && printf 'apply' || printf 'dry-run')" | tee -a "${LOG_FILE:-/dev/null}"
printLine

_discover
_refresh_status

section "Component Status"
_print_table

if [ "$ACTION" = "list" ]; then
    print_summary
    exit "$EXIT_CODE"
fi

# ---- Actions require credentials ----
section "Loading Credentials"
load_weblogic_password "${ROOT_DIR}/weblogic_sec.conf.des3" || { print_summary; exit 2; }

if ! $APPLY; then
    printf "\n"
    info "DRY-RUN: add --apply to execute."
    info "  Example: $(basename "$0") $ACTION${COMP_ARG:+ $COMP_ARG} --apply"
    print_summary
    exit 0
fi

case "$ACTION" in
    start)
        idx="$(_find_comp "$COMP_ARG")" || {
            fail "Component not found: $COMP_ARG"
            info "Known: ${C_NAME[*]}"
            print_summary; exit 2
        }
        section "Starting ${C_NAME[$idx]}"
        _start_comp "${C_NAME[$idx]}" "${C_TYPE[$idx]}"
        ;;

    stop)
        idx="$(_find_comp "$COMP_ARG")" || {
            fail "Component not found: $COMP_ARG"
            info "Known: ${C_NAME[*]}"
            print_summary; exit 2
        }
        section "Stopping ${C_NAME[$idx]}"
        _stop_comp "${C_NAME[$idx]}" "${C_TYPE[$idx]}" "${C_PID[$idx]}"
        ;;

    start-all)
        section "Starting All Components"
        _start_all
        ;;

    stop-all)
        section "Stopping All Components"
        _stop_all
        ;;
esac

# Refresh and show updated status after action
sleep 2
_refresh_status
section "Updated Status"
_print_table

print_summary
exit "$EXIT_CODE"
