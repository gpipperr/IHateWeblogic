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
#            start-all           Start: NM -> AdminServer -> Managed -> Reports -> OHS -> ORDS
#            stop-all            Stop:  ORDS -> OHS -> Reports -> Managed -> AdminServer -> NM
#            --apply             Execute write operations (default: dry-run)
#            --help              Show usage
# Requires : ss (or netstat), pgrep, wlst.sh (stop; start/stop of Reports servers)
#            weblogic_sec.conf.des3 (stop; start/stop of Reports servers)
# Reports  : Reports server system components (config.xml component-type
#            ReportsServerComponent) are started/stopped through the Node
#            Manager (nmConnect with the admin credentials, nmStart / nmKill -
#            what startComponent.sh / stopComponent.sh do, without their
#            password prompt). restartComponent.sh is not supported for them.
# Node Mgr : Servers must be started the way the Node Manager knows about
#            them - a server started with startWebLogic.sh /
#            startManagedWebLogic.sh is "SHUTDOWN" for the NM: fmw_ctl.sh /
#            systemd skip it and the next nmStart fails (port in use). So:
#            1. autostart configured (30-configure_autostart.sh,
#               $ORACLE_BASE/admin/<domain>/ctrl/fmw_ctl.sh): start/stop of
#               AdminServer, managed servers, Reports servers and
#               start-all/stop-all are delegated to fmw_ctl.sh (= systemd way)
#            2. NM running, no autostart: AdminServer via nmStart, managed
#               servers via start() through the AdminServer (NM-controlled)
#            3. NM not running: start scripts (as before)
#            The status table shows per server "Ctrl" NM | script and warns
#            about servers running outside the Node Manager.
# ORDS     : ORDS standalone instances of 12-APEX-Ords (ORDS_<n>_PORT in
#            environment.conf) run as systemd units ords@ords_<n>.service on
#            the JDK at JDK_HOME - started / stopped with systemctl via sudo,
#            also in start-all (last) / stop-all (first), so a JDK upgrade
#            (07-Maintenance/80-) finds no JVM left on JDK_HOME.
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
    printf "  %-30s %s\n" "start-all"               "Start all in order (NM->Admin->Managed->Reports->OHS->ORDS)"
    printf "  %-30s %s\n" "stop-all"                "Stop all in reverse (ORDS->OHS->Reports->Managed->Admin->NM)"
    printf "  %-30s %s\n" "--apply"                 "Execute operations (default: dry-run)"
    printf "\nExamples:\n"
    printf "  %s\n"                                  "$(basename "$0")"
    printf "  %s start AdminServer --apply\n"        "$(basename "$0")"
    printf "  %s stop  WLS_REPORTS --apply\n"        "$(basename "$0")"
    printf "  %s start repserver01 --apply   (Reports server component)\n" "$(basename "$0")"
    printf "  %s stop  ords@ords_1 --apply   (ORDS systemd unit, sudo)\n" "$(basename "$0")"
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
declare -a C_TYPE=()    # NM | ADMIN | MANAGED | REPORTS | OHS | ORDS
declare -a C_HOST=()    # configured listen address
declare -a C_PORT=()    # primary port
declare -a C_STATUS=()  # RUNNING | STOPPED | UNKNOWN
declare -a C_PID=()     # PID or ""
declare -a C_CTRL=()    # NM | script | systemd | "" (who started a running server)

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
            # no <listen-port> in config.xml = WebLogic default 7001 (AdminServer here)
            C_HOST+=("${listen_addr:-localhost}"); C_PORT+=("${listen_port:-7001}")
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

    # --- 3. Reports server system components ---
    # ReportsToolsComponent / FORMS are configuration only (no own process)
    if [ -f "$config_xml" ]; then
        local rep_name
        while IFS= read -r rep_name; do
            [ -z "$rep_name" ] && continue
            C_NAME+=("$rep_name"); C_TYPE+=("REPORTS")
            C_HOST+=("-");         C_PORT+=("")
            C_STATUS+=("UNKNOWN"); C_PID+=("")
        done < <(awk '
            /<system-component>/   { in_sc=1; name=""; type="" }
            in_sc && match($0, /<name>([^<]+)<\/name>/, m)                     { name = m[1] }
            in_sc && match($0, /<component-type>([^<]+)<\/component-type>/, m) { type = m[1] }
            /<\/system-component>/ {
                if (type == "ReportsServerComponent" && name != "") print name
                in_sc=0
            }
        ' "$config_xml")
    fi

    # --- 4. OHS system components (if present) ---
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

    # --- 5. ORDS standalone instances (12-APEX-Ords, systemd ords@ords_<n>) ---
    # ORDS_<n>_PORT in environment.conf = one instance; only if the template
    # unit is installed (04-install-ords.sh)
    if [ -f /etc/systemd/system/ords@.service ]; then
        local v n
        for v in $(compgen -v | grep -E '^ORDS_[0-9]+_PORT$'); do
            n="${v#ORDS_}"; n="${n%_PORT}"
            C_NAME+=("ords@ords_${n}"); C_TYPE+=("ORDS")
            C_HOST+=("127.0.0.1");     C_PORT+=("${!v}")
            C_STATUS+=("UNKNOWN");     C_PID+=("")
        done
    fi
}

# =============================================================================
# Node Manager / autostart helpers
# =============================================================================

_nm_pid() { pgrep -f 'java .*weblogic\.NodeManager' 2>/dev/null | head -1; }

# _under_nm pid - true if the process was started by the running Node Manager
# (NM -> startWebLogic.sh -> java; NM -> rwserver). Started by hand:
# startManagedWebLogic.sh -> startWebLogic.sh -> java, no NM in the chain.
_under_nm() {
    local p="$1" nm n
    nm="$(_nm_pid)"
    [ -z "$nm" ] && return 1
    for n in 1 2 3 4; do
        p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
        [ -z "$p" ] || [ "$p" -le 1 ] && return 1
        [ "$p" = "$nm" ] && return 0
    done
    return 1
}

# Autostart control script of 09-Install/30-configure_autostart.sh
DOMAIN_NAME_CFG="$(grep -m1 -o '<name>[^<]*</name>' "$DOMAIN_HOME/config/config.xml" 2>/dev/null \
                   | sed 's/<[^>]*>//g')"
DOMAIN_NAME_CFG="${DOMAIN_NAME_CFG:-$(basename "$DOMAIN_HOME")}"
FMW_CTL="${ORACLE_BASE:-/u01/app/oracle}/admin/${DOMAIN_NAME_CFG}/ctrl/fmw_ctl.sh"
[ -x "$FMW_CTL" ] || FMW_CTL=""
FMW_UNIT="fmw-${DOMAIN_NAME_CFG}.service"

# _fmw_ctl start|stop all|<name> - delegate to fmw_ctl.sh (keyfiles, no password)
_fmw_ctl() {
    local rc
    info "via autostart control: $(basename "$FMW_CTL") $1 $2"
    "$FMW_CTL" "$1" "$2" 2>&1 | sed 's/^[0-9-]* [0-9:]*  /    /' | tee -a "${LOG_FILE:-/dev/null}"
    rc=${PIPESTATUS[0]}
    if [ "$rc" -eq 0 ]; then
        ok "$2: $1 done (Node Manager)"
    else
        fail "$2: $1 failed (rc=$rc) - log: $(dirname "$FMW_CTL")/log/"
    fi
    return "$rc"
}

# _wls_start_via_admin <managed> - start() through the AdminServer: the
# AdminServer asks the Node Manager of the server's machine (startup
# properties incl. admin URL), so the NM controls the server afterwards
_wls_start_via_admin() {
    local name="$1" out
    if [ -z "${INTERNAL_WL_PWD:-}" ]; then
        load_weblogic_password "${ROOT_DIR}/weblogic_sec.conf.des3" > /dev/null || return 1
    fi
    _find_wlst || return 1
    export _IHW_SRV="$name"
    out="$(_run_wlst "$(cat <<'STEOF'
import os
e = os.environ
try:
    connect(e['_IHW_WL_USER'], e['_IHW_WL_PWD'], e['_IHW_WL_URL'])
    start(e['_IHW_SRV'], 'Server', block='true')
    print('IHW:OK')
except Exception, ex:
    print('IHW:FAIL:' + str(ex).split('\n')[0])
exit()
STEOF
)" 2>&1)"
    unset _IHW_SRV
    printf '%s\n' "$out" >> "${LOG_FILE:-/dev/null}"
    printf '%s\n' "$out" | grep -q '^IHW:OK' && return 0
    fail "$name: $(printf '%s\n' "$out" | sed -n 's/^IHW:FAIL://p' | head -1)"
    info "  AdminServer running? Machine of $name assigned to this Node Manager?"
    return 1
}

# =============================================================================
# Refresh status for all components
# =============================================================================

_refresh_status() {
    local i
    # New snapshot each time - the one from the script start still showed the
    # ports of servers stopped in this run ("RUNNING port" after stop-all)
    SS_CACHE="$(ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null)"
    for (( i=0; i < ${#C_NAME[@]}; i++ )); do
        local name="${C_NAME[$i]}" ctype="${C_TYPE[$i]}" port="${C_PORT[$i]}"
        local pid=""

        case "$ctype" in
            NM)
                # Only the NM JVM (main class weblogic.NodeManager). A bare
                # "NodeManager" pattern also matched this script's own command
                # line ("startStop.sh stop NodeManager") and any shell running
                # such a command -> phantom RUNNING with changing PIDs (2026-10-15)
                pid="$(pgrep -f 'java .*weblogic\.NodeManager' 2>/dev/null | head -1)"
                ;;
            ADMIN|MANAGED)
                pid="$(pgrep -f "Dweblogic.Name=${name}" 2>/dev/null | head -1)"
                ;;
            REPORTS)
                # rwserver binary started by the NM: ".../bin/rwserver server=<name> batch=yes ..."
                pid="$(pgrep -f "rwserver server=${name}( |\$)" 2>/dev/null | head -1)"
                ;;
            OHS)
                pid="$(pgrep -f "OHS/${name}" 2>/dev/null | head -1)"
                [ -z "$pid" ] && pid="$(pgrep -f "ohs/${name}" 2>/dev/null | head -1)"
                ;;
            ORDS)
                pid="$(systemctl show -p MainPID --value "${name}.service" 2>/dev/null)"
                [ "$pid" = "0" ] && pid=""
                ;;
        esac

        C_PID[$i]="${pid:-}"
        C_CTRL[$i]=""
        if [ -n "$pid" ] && [[ "$ctype" =~ ^(ADMIN|MANAGED|REPORTS)$ ]]; then
            _under_nm "$pid" && C_CTRL[$i]="NM" || C_CTRL[$i]="script"
        fi
        [ "$ctype" = "ORDS" ] && C_CTRL[$i]="systemd"

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
    printf "  \033[1m%-4s  %-24s  %-8s  %-10s  %-6s  %-8s  %s\033[0m\n" \
        "#" "Component" "Type" "Status" "Port" "PID" "Ctrl" | tee -a "${LOG_FILE:-/dev/null}"
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
        printf "${status_col}  \033[0m%-6s  %-8s  %s\n" \
            "${C_PORT[$i]:--}" "${C_PID[$i]:--}" "${C_CTRL[$i]:--}" | tee -a "${LOG_FILE:-/dev/null}"
    done
    printLine
}

# _warn_outside_nm - servers running past a running Node Manager
_warn_outside_nm() {
    local i found=""
    [ -z "$(_nm_pid)" ] && return 0
    for (( i=0; i < ${#C_NAME[@]}; i++ )); do
        [ "${C_CTRL[$i]}" = "script" ] && found="$found ${C_NAME[$i]}"
    done
    [ -z "$found" ] && return 0
    warn "Running OUTSIDE the Node Manager:$found"
    info "  The NM sees them as SHUTDOWN - fmw_ctl.sh / systemctl skip them, the next"
    info "  nmStart fails (port in use). Fix: stop <name> --apply, then start <name> --apply"
    info "  (this script now starts through the Node Manager)."
}

# =============================================================================
# Helpers: find wlst.sh; run a WLST Python script non-interactively
# =============================================================================

WLST_SH=""

_find_wlst() {
    WLST_SH="${ORACLE_HOME}/oracle_common/common/bin/wlst.sh"
    if [ ! -x "$WLST_SH" ]; then
        local alt="${WL_HOME:-${ORACLE_HOME}/wlserver}/common/bin/wlst.sh"
        if [ -x "$alt" ]; then
            WLST_SH="$alt"
        else
            fail "wlst.sh not found: $WLST_SH"
            info "Check ORACLE_HOME in environment.conf"
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

# _run_nm_action start|stop <name> [log] - Reports server component via the Node
# Manager. startComponent.sh / stopComponent.sh do the same, but prompt for
# the NM password unless a WLST user config was stored. The NM credentials
# are the admin credentials (09-Install/11-oracle_nodemanager.sh sets them).
_run_nm_action() {
    local action="$1" name="$2" out_log="${3:-/dev/null}" stype="${4:-ReportsServerComponent}"
    local nm_props="$DOMAIN_HOME/nodemanager/nodemanager.properties"
    local nm_host nm_port nm_sec nm_type="ssl" nm_domain

    if [ -z "${INTERNAL_WL_PWD:-}" ]; then
        load_weblogic_password "${ROOT_DIR}/weblogic_sec.conf.des3" > /dev/null || return 1
    fi
    _find_wlst || return 1

    nm_host="$(grep -i '^ListenAddress' "$nm_props" 2>/dev/null | cut -d= -f2 | tr -d ' \r')"
    nm_port="$(grep -i '^ListenPort'    "$nm_props" 2>/dev/null | cut -d= -f2 | tr -d ' \r')"
    nm_sec="$(grep -i '^SecureListener' "$nm_props" 2>/dev/null | cut -d= -f2 | tr -d ' \r')"
    [ "${nm_sec,,}" = "false" ] && nm_type="plain"
    nm_domain="$(grep -m1 -o '<name>[^<]*</name>' "$DOMAIN_HOME/config/config.xml" 2>/dev/null \
                 | sed 's/<[^>]*>//g')"

    export _IHW_NM_HOST="${nm_host:-localhost}" _IHW_NM_PORT="${nm_port:-5556}"
    export _IHW_NM_TYPE="$nm_type" _IHW_NM_DOMAIN="${nm_domain:-$(basename "$DOMAIN_HOME")}"
    export _IHW_DOMAIN_HOME="$DOMAIN_HOME" _IHW_COMP="$name" _IHW_ACTION="$action" _IHW_STYPE="$stype"

    local out rc
    out="$(_run_wlst "$(cat <<'NMEOF'
import os
e = os.environ
try:
    nmConnect(e['_IHW_WL_USER'], e['_IHW_WL_PWD'], e['_IHW_NM_HOST'], e['_IHW_NM_PORT'],
              e['_IHW_NM_DOMAIN'], e['_IHW_DOMAIN_HOME'], e['_IHW_NM_TYPE'])
except Exception, ex:
    print('IHW:FAIL:nmConnect: ' + str(ex).split('\n')[0])
    exit(exitcode=1)
try:
    if e['_IHW_STYPE'] == 'Server':
        if e['_IHW_ACTION'] == 'start':
            nmStart(e['_IHW_COMP'])
        else:
            nmKill(e['_IHW_COMP'])
    elif e['_IHW_ACTION'] == 'start':
        nmStart(serverName=e['_IHW_COMP'], serverType=e['_IHW_STYPE'])
    else:
        nmKill(serverName=e['_IHW_COMP'], serverType=e['_IHW_STYPE'])
    print('IHW:OK')
except Exception, ex:
    print('IHW:FAIL:' + str(ex).split('\n')[0])
nmDisconnect()
exit()
NMEOF
)" 2>&1)"
    rc=$?
    unset _IHW_NM_HOST _IHW_NM_PORT _IHW_NM_TYPE _IHW_NM_DOMAIN _IHW_DOMAIN_HOME _IHW_COMP _IHW_ACTION _IHW_STYPE
    printf '%s\n' "$out" | tee -a "$out_log" >> "${LOG_FILE:-/dev/null}"

    if printf '%s\n' "$out" | grep -q '^IHW:OK'; then
        return 0
    fi
    fail "$name: $(printf '%s\n' "$out" | sed -n 's/^IHW:FAIL://p' | head -1)"
    if printf '%s\n' "$out" | grep -q 'IHW:FAIL:nmConnect'; then
        info "  Node Manager running? NM credentials = admin credentials?"
        info "  Check: ./09-Install/11-oracle_nodemanager.sh (nmConnect test)"
    else
        info "  Logs: $DOMAIN_HOME/servers/$name/logs/ and nodemanager/nodemanager.log"
    fi
    [ "$rc" -eq 0 ] && rc=1
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

# _check_early_exit pid log name – a server that dies within the first seconds
# (boot identity, port in use, ...) must not be reported as started; the
# status table right after the start only sees a short-lived PID
_check_early_exit() {
    local pid="$1" log="$2" name="$3"
    sleep 8
    if ! kill -0 "$pid" 2>/dev/null; then
        fail "$name exited right after the start – last lines of $log:"
        tail -5 "$log" 2>/dev/null | while IFS= read -r _l; do info "    $_l"; done
        return 1
    fi
    return 0
}

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
            local boot_props="$DOMAIN_HOME/servers/AdminServer/security/boot.properties"
            if [ ! -f "$boot_props" ]; then
                # Production mode + nohup: no console for the password prompt –
                # the server dies at once (BEA-090782, shutDownStatus=255,
                # confirmed 2026-10-15). Do not start at all.
                fail "boot.properties not found: $boot_props"
                fail "  Production mode cannot prompt for the password without a console – start aborted"
                info "  Fix: ./09-Install/10-oracle_boot_properties.sh --apply"
                return 1
            fi
            # libOVD lock left by the Reports server (rwserver initialises libOVD
            # in the same directory): an AdminServer started while it exists
            # builds no DefaultAuthenticator adapter -> EM "Add Principal" finds
            # no users (proven 2026-10-16). Not held open - safe to remove here.
            local ovd_lok="$DOMAIN_HOME/config/fmwconfig/ovd/default/ovd.lok"
            if [ -e "$ovd_lok" ]; then
                mv -f "$ovd_lok" "${ovd_lok}.stale" \
                    && info "Removed stale libOVD lock: $ovd_lok"
            fi
            if [ -n "$FMW_CTL" ]; then
                _fmw_ctl start "$name"; return $?
            elif [ -n "$(_nm_pid)" ]; then
                # NM running: nmStart, otherwise the NM does not know the server
                _run_nm_action start "$name" "$start_log" Server || return 1
                ok "$name started (Node Manager)"
                return 0
            fi
            nohup "$wl_sh" > "$start_log" 2>&1 &
            _check_early_exit $! "$start_log" "AdminServer" || return 1
            ok "AdminServer start initiated (PID $!) – allow ~60s to come up"
            ;;
        MANAGED)
            local mgd_sh="$DOMAIN_HOME/bin/startManagedWebLogic.sh"
            if [ ! -f "$mgd_sh" ]; then fail "Not found: $mgd_sh"; return 1; fi
            local boot_props="$DOMAIN_HOME/servers/$name/security/boot.properties"
            if [ ! -f "$boot_props" ]; then
                # Production mode + nohup: no console for the password prompt –
                # the server dies at once (BEA-090782, shutDownStatus=255,
                # confirmed 2026-10-15). Do not start at all.
                fail "boot.properties not found: $boot_props"
                fail "  Production mode cannot prompt for the password without a console – start aborted"
                info "  Fix: ./09-Install/10-oracle_boot_properties.sh --apply"
                return 1
            fi
            if [ -n "$FMW_CTL" ]; then
                _fmw_ctl start "$name"; return $?
            elif [ -n "$(_nm_pid)" ]; then
                _wls_start_via_admin "$name" || return 1
                ok "$name started (via AdminServer / Node Manager)"
                return 0
            fi
            nohup "$mgd_sh" "$name" "${WL_ADMIN_URL:-t3://localhost:7001}" \
                > "$start_log" 2>&1 &
            _check_early_exit $! "$start_log" "$name" || return 1
            ok "$name start initiated (PID $!) – allow ~60s to come up"
            ;;
        REPORTS)
            if ! pgrep -f 'java .*weblogic\.NodeManager' > /dev/null 2>&1; then
                fail "Node Manager not running - Reports servers are started through it"
                info "  ./01-Run/startStop.sh start NodeManager --apply"
                return 1
            fi
            [ -n "$FMW_CTL" ] && { _fmw_ctl start "$name"; return $?; }
            # nmStart returns when the NM reports the component as started
            _run_nm_action start "$name" "$start_log" || return 1
            ok "$name started (Node Manager)"
            ;;
        OHS)
            local start_sh="$DOMAIN_HOME/bin/startComponent.sh"
            if [ ! -f "$start_sh" ]; then fail "Not found: $start_sh"; return 1; fi
            "$start_sh" "$name" >> "$start_log" 2>&1
            local rc=$?
            [ "$rc" -eq 0 ] && ok "$name started" || fail "$name start failed (rc=$rc)"
            return $rc
            ;;
        ORDS)
            ihw_run_root systemctl start "${name}.service" \
                && ok "$name started (systemd)" \
                || { fail "$name start failed – systemctl status ${name}.service"; return 1; }
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
    local name="$1" ctype="$2" pid="$3" ctrl="${4:-}"

    info "Stopping $name (type=$ctype) ..."

    # Autostart configured: same orderly shutdown / nmKill as systemd. Not for
    # a server started past the NM - fmw_ctl.sh sees it as SHUTDOWN and skips
    # it; that one is shut down through the AdminServer (WLST) below.
    if [ -n "$FMW_CTL" ] && [ "$ctrl" != "script" ] && [[ "$ctype" =~ ^(ADMIN|MANAGED|REPORTS)$ ]]; then
        _fmw_ctl stop "$name"; return $?
    fi
    if [[ "$ctype" =~ ^(ADMIN|MANAGED)$ ]] && [ -z "${INTERNAL_WL_PWD:-}" ]; then
        load_weblogic_password "${ROOT_DIR}/weblogic_sec.conf.des3" > /dev/null || return 1
    fi

    case "$ctype" in
        NM)
            if [ -n "$pid" ] && [[ "$pid" =~ ^[0-9]+$ ]]; then
                kill "$pid" 2>/dev/null \
                    && ok "NodeManager (PID $pid) stopped" \
                    || { fail "kill $pid failed"; return 1; }
            else
                # never pkill a bare "NodeManager" - that can hit this script
                pkill -f 'java .*weblogic\.NodeManager' 2>/dev/null \
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

        REPORTS)
            # Same as stopComponent.sh: nmKill through the Node Manager. A
            # rwserver started without the NM is unknown to it -> fallback kill
            if pgrep -f 'java .*weblogic\.NodeManager' > /dev/null 2>&1 \
               && _run_nm_action stop "$name"; then
                ok "$name stopped (Node Manager)"
            elif [ -n "$pid" ] && [[ "$pid" =~ ^[0-9]+$ ]]; then
                warn "$name: stop through the Node Manager failed - SIGTERM to PID $pid"
                kill "$pid" 2>/dev/null && ok "$name (PID $pid) stopped" \
                    || { fail "kill $pid failed"; return 1; }
            else
                return 1
            fi
            ;;

        OHS)
            local stop_sh="$DOMAIN_HOME/bin/stopComponent.sh"
            if [ ! -f "$stop_sh" ]; then fail "Not found: $stop_sh"; return 1; fi
            "$stop_sh" "$name"
            local rc=$?
            [ "$rc" -eq 0 ] && ok "$name stopped" || fail "$name stop failed (rc=$rc)"
            return $rc
            ;;

        ORDS)
            ihw_run_root systemctl stop "${name}.service" \
                && ok "$name stopped (systemd)" \
                || { fail "$name stop failed – systemctl status ${name}.service"; return 1; }
            ;;

        *)
            fail "Unknown component type '$ctype'"
            return 1
            ;;
    esac
}

# =============================================================================
# Start-all: NM -> AdminServer -> Managed -> Reports -> OHS -> ORDS
# =============================================================================

# systemd keeps its own view: "active (exited)" after start, independent of
# what fmw_ctl.sh did by hand afterwards
_systemd_note() {
    systemctl is-enabled "$FMW_UNIT" > /dev/null 2>&1 || return 0
    info "systemd unit $FMW_UNIT: $(systemctl is-active "$FMW_UNIT" 2>/dev/null)"
    info "  As root the same is: systemctl start|stop $FMW_UNIT. After a manual stop-all the"
    info "  unit still shows 'active' - 'systemctl start' then does nothing, use 'restart'."
}

_start_all() {
    local i
    for ctype in "NM" "ADMIN" "MANAGED" "REPORTS" "OHS" "ORDS"; do
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

# _ords_all start|stop - the ORDS units besides fmw_ctl.sh (not part of the domain)
_ords_all() {
    local i
    for (( i=0; i < ${#C_NAME[@]}; i++ )); do
        [ "${C_TYPE[$i]}" = "ORDS" ] || continue
        if [ "$1" = "start" ] && [ "${C_STATUS[$i]}" != "RUNNING" ]; then
            section "Starting ${C_NAME[$i]}"
            _start_comp "${C_NAME[$i]}" ORDS || true
        elif [ "$1" = "stop" ] && [ "${C_STATUS[$i]}" != "STOPPED" ]; then
            section "Stopping ${C_NAME[$i]}"
            _stop_comp "${C_NAME[$i]}" ORDS "${C_PID[$i]}" systemd || true
        fi
    done
}

# =============================================================================
# Stop-all: ORDS -> OHS -> Reports -> Managed -> AdminServer -> NM
# =============================================================================

_stop_all() {
    local i
    for ctype in "ORDS" "OHS" "REPORTS" "MANAGED" "ADMIN" "NM"; do
        for (( i=0; i < ${#C_NAME[@]}; i++ )); do
            [ "${C_TYPE[$i]}" != "$ctype" ] && continue
            if [ "${C_STATUS[$i]}" = "STOPPED" ]; then
                info "${C_NAME[$i]} already STOPPED – skipping"
                continue
            fi
            section "Stopping ${C_NAME[$i]}"
            _stop_comp "${C_NAME[$i]}" "${C_TYPE[$i]}" "${C_PID[$i]}" "${C_CTRL[$i]}" || true
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
_warn_outside_nm

if [ "$ACTION" = "list" ]; then
    print_summary
    exit "$EXIT_CODE"
fi

# ---- Stop actions require WLST credentials; start actions use boot.properties ----
if [ -n "$FMW_CTL" ]; then
    info "Autostart configured: $FMW_CTL"
    info "  start/stop of servers and Reports components go through it (Node Manager)"
fi

case "$ACTION" in
    stop|stop-all)
        # with fmw_ctl.sh the keyfiles of the autostart are used
        if [ -z "$FMW_CTL" ]; then
            section "Loading Credentials"
            load_weblogic_password "${ROOT_DIR}/weblogic_sec.conf.des3" || { print_summary; exit 2; }
        fi
        ;;
esac

if ! $APPLY; then
    printf "\n"
    if [ -n "$FMW_CTL" ]; then
        info "Would run through: $FMW_CTL (Node Manager)"
    elif [ -n "$(_nm_pid)" ]; then
        info "Node Manager running: AdminServer via nmStart, managed servers via the AdminServer"
    fi
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
        _stop_comp "${C_NAME[$idx]}" "${C_TYPE[$idx]}" "${C_PID[$idx]}" "${C_CTRL[$idx]}"
        ;;

    start-all)
        section "Starting All Components"
        if [ -n "$FMW_CTL" ]; then
            _fmw_ctl start all
            _ords_all start
            _systemd_note
        else
            _start_all
        fi
        ;;

    stop-all)
        section "Stopping All Components"
        if [ -n "$FMW_CTL" ]; then
            _ords_all stop
            # servers started past the NM first - fmw_ctl.sh would skip them
            for (( i=0; i < ${#C_NAME[@]}; i++ )); do
                [ "${C_CTRL[$i]}" = "script" ] && [ "${C_TYPE[$i]}" = "MANAGED" ] \
                    && { _stop_comp "${C_NAME[$i]}" "${C_TYPE[$i]}" "${C_PID[$i]}" script || true; }
            done
            _fmw_ctl stop all
            for (( i=0; i < ${#C_NAME[@]}; i++ )); do
                [ "${C_CTRL[$i]}" = "script" ] && [ "${C_TYPE[$i]}" = "ADMIN" ] \
                    && { _stop_comp "${C_NAME[$i]}" ADMIN "${C_PID[$i]}" script || true; }
            done
            _systemd_note
        else
            _stop_all
        fi
        ;;
esac

# Refresh and show updated status after action
sleep 2
_refresh_status
section "Updated Status"
_print_table

print_summary
exit "$EXIT_CODE"
