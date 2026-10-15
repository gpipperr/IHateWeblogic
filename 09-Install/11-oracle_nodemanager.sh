#!/bin/bash
# =============================================================================
# Script   : 11-oracle_nodemanager.sh
# Purpose  : Configure NodeManager for plain (non-SSL) communication.
#            Autostart at boot (systemd, Node Manager controlled):
#            09-Install/30-configure_autostart.sh
#
#            By default WebLogic configures NodeManager with SecureListener=true
#            (SSL). For internal environments without a proper PKI this causes
#            "Unrecognized SSL message, plaintext connection?" errors when
#            starting managed servers.
#
#            This script:
#              1. Sets SecureListener=false in nodemanager.properties
#              2. Aligns the domain's NodeManager type to "Plain" via WLST
#              3. Verifies the final configuration
#
# Call     : ./09-Install/11-oracle_nodemanager.sh
#            ./09-Install/11-oracle_nodemanager.sh --apply
#            ./09-Install/11-oracle_nodemanager.sh --apply --skip-wlst
#
#            Without --apply  : dry-run, show current settings, no changes
#            --skip-wlst      : skip domain config update (AdminServer not running)
#
# Requires : environment.conf (DOMAIN_HOME, ORACLE_HOME)
#            weblogic_sec.conf.des3 (for WLST authentication)
# Runs as  : oracle
# Ref      : 09-Install/docs/11-oracle_nodemanager.md
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_SH="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"

# --- Source library -----------------------------------------------------------
if [ ! -f "$LIB_SH" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB_SH" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB_SH"

# --- Source environment.conf --------------------------------------------------
check_env_conf "$ROOT_DIR/environment.conf" || exit 2
# shellcheck source=../environment.conf
source "$ROOT_DIR/environment.conf"

# --- Arguments ----------------------------------------------------------------
APPLY=false
SKIP_WLST=false
_NM_CREDS_CHANGED=false

for _arg in "$@"; do
    case "$_arg" in
        --apply)      APPLY=true ;;
        --skip-wlst)  SKIP_WLST=true ;;
        --help|-h)
            printf "Usage: %s [--apply] [--skip-wlst]\n\n" "$(basename "$0")"
            printf "  %-16s %s\n" "--apply"      "Write changes to nodemanager.properties and domain config"
            printf "  %-16s %s\n" "--skip-wlst"  "Skip WLST domain update (use if AdminServer is not running)"
            printf "\nWithout --apply: dry-run, no files changed.\n"
            exit 0 ;;
        *) warn "Unknown argument: $_arg" ;;
    esac
done
unset _arg

# --- Log setup ----------------------------------------------------------------
LOG_FILE="$ROOT_DIR/log/$(date +%Y%m%d)/nodemanager_$(date +%H%M%S).log"
mkdir -p "$(dirname "$LOG_FILE")"
{
    printf "# 11-oracle_nodemanager.sh log\n"
    printf "# Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# Host    : %s\n" "$(_get_hostname)"
    printf "# Apply   : %s\n" "$APPLY"
} > "$LOG_FILE"

# =============================================================================
# Header
# =============================================================================
printLine
printf "\n\033[1m  IHateWeblogic – NodeManager Configuration\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"  | tee -a "$LOG_FILE"
printf "  DOMAIN_HOME : %s\n" "${DOMAIN_HOME:-?}" | tee -a "$LOG_FILE"
printf "  Apply       : %s\n" "$APPLY"             | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"           | tee -a "$LOG_FILE"
printLine

# =============================================================================
# 1. Prerequisites
# =============================================================================
section "Prerequisites"

if [ -z "${DOMAIN_HOME:-}" ]; then
    fail "DOMAIN_HOME is not set in environment.conf"
    print_summary; exit "$EXIT_CODE"
fi

if [ ! -d "$DOMAIN_HOME" ]; then
    fail "DOMAIN_HOME directory does not exist: $DOMAIN_HOME"
    info "  Run 08-oracle_setup_domain.sh first"
    print_summary; exit "$EXIT_CODE"
fi
ok "DOMAIN_HOME exists: $DOMAIN_HOME"

if [ -z "${ORACLE_HOME:-}" ]; then
    fail "ORACLE_HOME is not set in environment.conf"
    print_summary; exit "$EXIT_CODE"
fi
ok "ORACLE_HOME: $ORACLE_HOME"

WLST_SH="$ORACLE_HOME/oracle_common/common/bin/wlst.sh"
if [ -f "$WLST_SH" ]; then
    ok "wlst.sh found: $WLST_SH"
else
    warn "wlst.sh not found at: $WLST_SH"
    info "  WLST step will be skipped"
    SKIP_WLST=true
fi

# =============================================================================
# 2. nodemanager.properties
# =============================================================================
section "NodeManager Properties File"

NM_PROPS="$DOMAIN_HOME/nodemanager/nodemanager.properties"

if [ ! -f "$NM_PROPS" ]; then
    fail "nodemanager.properties not found: $NM_PROPS"
    info "  Domain not yet created or NodeManager not yet configured"
    info "  Run 08-oracle_setup_domain.sh first"
    print_summary; exit "$EXIT_CODE"
fi
ok "File found: $NM_PROPS"

# Show current SSL-relevant settings
info "Current settings:"
for _key in SecureListener ListenAddress ListenPort StartScriptEnabled; do
    _val="$(grep -i "^${_key}" "$NM_PROPS" 2>/dev/null | head -1)"
    if [ -n "$_val" ]; then
        printf "  %-28s %s\n" "" "$_val" | tee -a "$LOG_FILE"
    else
        printf "  %-28s %s\n" "" "${_key}=(not set)" | tee -a "$LOG_FILE"
    fi
done
unset _key _val

# Check current SecureListener value
_current_secure="$(grep -i '^SecureListener' "$NM_PROPS" 2>/dev/null | cut -d= -f2 | tr -d ' ')"
if [ "${_current_secure,,}" = "false" ]; then
    ok "SecureListener is already false – no change needed"
    _nm_change_needed=false
else
    warn "SecureListener=${_current_secure:-true} → will set to false"
    _nm_change_needed=true
fi
unset _current_secure

# StartScriptEnabled: default true since WLS 12.1.2 – only an explicit
# "false" needs a change. Before 2026-10-15 it was only written together
# with SecureListener (08- already sets SecureListener=false, so never).
_current_sse="$(grep -i '^StartScriptEnabled' "$NM_PROPS" 2>/dev/null | cut -d= -f2 | tr -d ' ')"
if [ "${_current_sse,,}" = "false" ]; then
    warn "StartScriptEnabled=false → will set to true"
    _nm_change_needed=true
else
    ok "StartScriptEnabled=${_current_sse:-not set (default true)} – no change needed"
fi
unset _current_sse

if $APPLY && $_nm_change_needed; then
    # Backup
    _backup="$NM_PROPS.bak_$(date +%Y%m%d_%H%M%S)"
    cp "$NM_PROPS" "$_backup"
    ok "Backup: $_backup"

    # Set SecureListener=false (replace existing or append)
    if grep -qi '^SecureListener' "$NM_PROPS"; then
        sed -i 's/^[Ss]ecure[Ll]istener=.*/SecureListener=false/' "$NM_PROPS"
    else
        printf "SecureListener=false\n" >> "$NM_PROPS"
    fi
    ok "SecureListener=false written to $NM_PROPS"

    # Ensure StartScriptEnabled=true (required to start managed servers via NM)
    if grep -qi '^StartScriptEnabled' "$NM_PROPS"; then
        sed -i 's/^[Ss]tart[Ss]cript[Ee]nabled=.*/StartScriptEnabled=true/' "$NM_PROPS"
    else
        printf "StartScriptEnabled=true\n" >> "$NM_PROPS"
    fi
    ok "StartScriptEnabled=true written"
    # NodeManager reads (and rewrites) the file at startup
    if pgrep -f "weblogic.NodeManager" > /dev/null 2>&1; then
        warn "NodeManager is running – restart it to load the change:"
        info "  01-Run/startStop.sh stop NodeManager --apply && 01-Run/startStop.sh start NodeManager --apply"
    fi

    unset _backup
elif ! $APPLY && $_nm_change_needed; then
    info "  Dry-run – would set: SecureListener=false"
    info "  Dry-run – would set: StartScriptEnabled=true"
fi
unset _nm_change_needed

# =============================================================================
# 3. Domain Configuration via WLST (Machine NodeManagerMBean NMType = Plain)
# =============================================================================
section "Domain NodeManager Type (WLST)"

if $SKIP_WLST; then
    info "Skipping WLST step (--skip-wlst or wlst.sh not found)"
    info "  Set NodeManager type manually in EM:"
    info "  fr_domain → WebLogic Domain → Environment → Machines → <machine>"
    info "  → Configuration → Node Manager tab → Type: Plain → Lock & Edit → Save → Activate"
else
    # Check AdminServer port is open
    _adm_port="${WLS_ADMIN_PORT:-7001}"
    _adm_url="${WLS_ADMIN_URL:-t3://localhost:${_adm_port}}"

    # The AdminServer needs ~30-60s after "startStop.sh start AdminServer"
    # before it listens – wait instead of failing (a run 29s after the start
    # missed RUNNING by 6s, 2026-10-15)
    _adm_wait="${ADMIN_WAIT_SECONDS:-120}"
    _adm_up=false
    _waited=0
    while :; do
        if timeout 3 bash -c "echo >/dev/tcp/localhost/${_adm_port}" 2>/dev/null; then
            _adm_up=true; break
        fi
        [ "$_waited" -ge "$_adm_wait" ] && break
        [ "$_waited" -eq 0 ] && \
            info "AdminServer not (yet) listening on port $_adm_port – waiting up to ${_adm_wait}s ..."
        sleep 5; _waited=$(( _waited + 5 ))
    done
    unset _waited _adm_wait

    if ! $_adm_up; then
        warn "AdminServer not reachable on port $_adm_port"
        info "  Start AdminServer first, then re-run without --skip-wlst:"
        info "    01-Run/startStop.sh start AdminServer --apply"
    else
        ok "AdminServer reachable on port $_adm_port"

        if $APPLY; then
            # Load credentials
            if ! load_weblogic_password; then
                fail "Cannot load WebLogic credentials – run 00-Setup/weblogic_sec.sh --apply"
                print_summary; exit "$EXIT_CODE"
            fi

            # Determine domain name from DOMAIN_HOME
            _domain_name="$(basename "$DOMAIN_HOME")"

            # Write WLST script to temp file
            _wlst_script="$(mktemp --suffix=.py)"
            cat > "$_wlst_script" <<WLST_EOF
import os, sys

wl_user = os.environ.get('_IHW_WL_USER', '')
wl_pass = os.environ.get('_IHW_WL_PASS', '')
adm_url = os.environ.get('_IHW_ADM_URL', 't3://localhost:7001')
domain  = os.environ.get('_IHW_DOMAIN',  'fr_domain')

# NOTE: NodeManagerType does NOT live on SecurityConfigurationMBean in
# WLS 14.1.2 (confirmed live against a real 14.1.2 domain via dir(cmo) -
# only NodeManagerUsername/NodeManagerPassword(Encrypted)/SecureMode are
# present there, cmo.setNodeManagerType() raises AttributeError). The
# attribute lives on the NodeManagerMBean under the domain's Machine
# instead, and is called NMType there.
try:
    connect(wl_user, wl_pass, adm_url)
    edit()
    startEdit()
    cd('/')
    machines = cmo.getMachines()
    if len(machines) != 1:
        print('IHW:FAIL:Expected exactly 1 Machine in the domain, found ' + str(len(machines)) + ' - cannot determine which one to configure automatically, set NMType=Plain manually in EM (WebLogic Domain -> Environment -> Machines -> <machine> -> Node Manager)')
        sys.exit(1)
    machine_name = machines[0].getName()
    cd('/Machines/' + machine_name + '/NodeManager/' + machine_name)
    cmo.setNMType('Plain')
    # Node Manager credentials = admin credentials. A domain written by WLST
    # offline in production mode gets RANDOM ones (user e.g. "o2HTp584LE",
    # password unknown to anybody, confirmed 2026-10-15) - startComponent.sh,
    # nmConnect and the autostart (30-) then cannot authenticate.
    cd('/')
    dom_name = cmo.getName()
    cd('/SecurityConfiguration/' + dom_name)
    cmo.setNodeManagerUsername(wl_user)
    # set('NodeManagerPasswordEncrypted', <clear text>) is refused in
    # production mode - setNodeManagerPassword() takes clear text and stores
    # it encrypted (2026-10-15)
    cmo.setNodeManagerPassword(wl_pass)
    save()
    activate(block='true')
    print('IHW:OK:NMType set to Plain (Machine ' + machine_name + ')')
    print('IHW:OK:Node Manager credentials set to the admin user ' + wl_user)
    disconnect()
except Exception as e:
    print('IHW:FAIL:WLST error: ' + str(e))
    # do not leave the edit session locked
    try:
        cancelEdit('y')
    except Exception:
        pass
    sys.exit(1)
WLST_EOF

            export _IHW_WL_USER="$WL_USER"
            export _IHW_WL_PASS="$INTERNAL_WL_PWD"
            export _IHW_ADM_URL="$_adm_url"
            export _IHW_DOMAIN="$_domain_name"

            _wlst_out="$("$WLST_SH" "$_wlst_script" 2>&1)"

            # Clear credentials immediately
            unset _IHW_WL_USER _IHW_WL_PASS INTERNAL_WL_PWD

            # Parse sentinel output
            while IFS= read -r _line; do
                case "$_line" in
                    IHW:OK:*)   ok "$(printf '%s' "$_line" | cut -d: -f3-)" ;;
                    IHW:WARN:*) warn "$(printf '%s' "$_line" | cut -d: -f3-)" ;;
                    IHW:FAIL:*) fail "$(printf '%s' "$_line" | cut -d: -f3-)" ;;
                esac
            done <<< "$_wlst_out"

            rm -f "$_wlst_script"
            printf '%s' "$_wlst_out" | grep -q 'IHW:OK:Node Manager credentials' && _NM_CREDS_CHANGED=true
            if printf '%s' "$_wlst_out" | grep -q 'IHW:OK:Node Manager credentials'; then
                info "  NodeManager reads config/nodemanager/nm_password.properties at startup – restart it:"
                info "    01-Run/startStop.sh stop NodeManager --apply && 01-Run/startStop.sh start NodeManager --apply"
            fi
            unset _wlst_script _wlst_out _domain_name WL_USER

        else
            info "Dry-run – would connect to $_adm_url, set Machine NodeManagerMBean NMType=Plain and NM credentials = admin user"
        fi
    fi
    unset _adm_port _adm_url
fi

# =============================================================================
# 4. Verification
# =============================================================================
section "Verification"

_sec="$(grep -i '^SecureListener' "$NM_PROPS" 2>/dev/null | cut -d= -f2 | tr -d ' ')"
if [ "${_sec,,}" = "false" ]; then
    ok "nodemanager.properties: SecureListener=false"
else
    warn "nodemanager.properties: SecureListener=${_sec:-not set} (expected false)"
fi
unset _sec

_sse="$(grep -i '^StartScriptEnabled' "$NM_PROPS" 2>/dev/null | cut -d= -f2 | tr -d ' ')"
if [ "${_sse,,}" = "false" ]; then
    warn "nodemanager.properties: StartScriptEnabled=false (expected true)"
else
    ok "nodemanager.properties: StartScriptEnabled=${_sse:-not set (default true)}"
fi
unset _sse

# --- nmConnect test with the admin credentials (A5, 2026-10-15) ---------------
# connect() to the AdminServer working does NOT mean nmConnect() works: the
# Node Manager checks its own hash in config/nodemanager/nm_password.properties
# (customer 2026-10-15). Test exactly what startComponent.sh / the autostart
# need. Host/port/type come from nodemanager.properties (a NM listening on
# 127.0.0.1 refuses connections to the host name).
_nm_host="$(grep -E '^ListenAddress=' "$NM_PROPS" 2>/dev/null | cut -d= -f2 | tr -d ' ')"
_nm_port="$(grep -E '^ListenPort=' "$NM_PROPS" 2>/dev/null | cut -d= -f2 | tr -d ' ')"
_nm_host="${_nm_host:-localhost}"; _nm_port="${_nm_port:-${WLS_NODEMANAGER_PORT:-5556}}"
_nm_sec="$(grep -i '^SecureListener' "$NM_PROPS" 2>/dev/null | cut -d= -f2 | tr -d ' ')"
_nm_type="ssl"; [ "${_nm_sec,,}" = "false" ] && _nm_type="plain"
_nm_domain="$(grep -m1 -o '<name>[^<]*</name>' "$DOMAIN_HOME/config/config.xml" 2>/dev/null | sed 's/<[^>]*>//g')"
_nm_domain="${_nm_domain:-$(basename "$DOMAIN_HOME")}"

_nm_connect_test() {
    local py out
    py="$(mktemp --suffix=.py)"
    cat > "$py" << 'NMT_EOF'
import os
try:
    nmConnect(os.environ['_IHW_U'], os.environ['_IHW_P'], os.environ['_IHW_H'],
              os.environ['_IHW_PORT'], os.environ['_IHW_D'], os.environ['_IHW_DH'],
              os.environ['_IHW_T'])
    print('IHW:NM_OK')
    nmDisconnect()
except Exception, e:
    print('IHW:NM_FAIL:' + str(e).split('\n')[0])
exit()
NMT_EOF
    out="$(_IHW_U="$WL_USER" _IHW_P="$INTERNAL_WL_PWD" _IHW_H="$_nm_host" _IHW_PORT="$_nm_port" \
           _IHW_D="$_nm_domain" _IHW_DH="$DOMAIN_HOME" _IHW_T="$_nm_type" \
           "$WLST_SH" "$py" 2>&1)"
    rm -f "$py"
    if printf '%s\n' "$out" | grep -q '^IHW:NM_OK'; then
        ok "nmConnect as ${WL_USER} to ${_nm_host}:${_nm_port} (${_nm_type}, domain ${_nm_domain}) works"
        return 0
    fi
    fail "nmConnect as ${WL_USER} to ${_nm_host}:${_nm_port} failed: $(printf '%s\n' "$out" | sed -n 's/^IHW:NM_FAIL://p' | head -1)"
    return 1
}

if [ ! -f "$WLST_SH" ]; then
    info "wlst.sh not found – nmConnect test skipped"
elif ! timeout 3 bash -c "echo >/dev/tcp/${_nm_host}/${_nm_port}" 2>/dev/null; then
    info "Node Manager not listening on ${_nm_host}:${_nm_port} – nmConnect test skipped"
    info "  Start it, then re-run this script: 01-Run/startStop.sh start NodeManager --apply"
elif ! load_weblogic_password > /dev/null 2>&1; then
    warn "Cannot load WebLogic credentials – nmConnect test skipped"
else
    if ! _nm_connect_test; then
        if $_NM_CREDS_CHANGED; then
            # The NM reads nm_password.properties only at startup
            info "  The Node Manager credentials were changed in this run – the NM still uses the old ones"
            if $APPLY && askYesNo "Restart the Node Manager now (running servers keep running)?" "y"; then
                "$DOMAIN_HOME/bin/stopNodeManager.sh" > /dev/null 2>&1
                sleep 3
                nohup "$DOMAIN_HOME/bin/startNodeManager.sh" > "$DOMAIN_HOME/nodemanager/nm_start.log" 2>&1 &
                _w=0
                until timeout 3 bash -c "echo >/dev/tcp/${_nm_host}/${_nm_port}" 2>/dev/null || [ "$_w" -ge 60 ]; do
                    sleep 3; _w=$(( _w + 3 ))
                done
                unset _w
                _nm_connect_test || info "  See docs/80-oracle_security.md section 5.2"
            else
                info "  Restart the Node Manager, then re-run this script:"
                info "    01-Run/startStop.sh stop NodeManager --apply && 01-Run/startStop.sh start NodeManager --apply"
            fi
        else
            info "  The Node Manager password differs from the WebLogic admin password."
            info "  Fix: re-run with --apply (sets the NM credentials via WLST), restart the NM"
            info "  Background: docs/80-oracle_security.md section 5.2"
        fi
    fi
    unset INTERNAL_WL_PWD
fi
unset _nm_host _nm_port _nm_sec _nm_type _nm_domain

# =============================================================================
# 5. Next steps
# =============================================================================
section "Next Steps"
if $SKIP_WLST; then
    info "1. Start NodeManager and AdminServer:"
    info "     01-Run/startStop.sh start NodeManager --apply"
    info "     01-Run/startStop.sh start AdminServer --apply"
    info "2. Set Machine NMType=Plain via WLST (waits for the AdminServer):"
    info "     09-Install/11-oracle_nodemanager.sh --apply"
else
    info "1. Status of all components:"
    info "     01-Run/startStop.sh"
    info "2. Continue: 12-oracle_reports_users.sh --apply, 13-root_reports_fix.sh (root),"
    info "   13-oracle_setup_reports.sh --apply, 14-oracle_setup_forms.sh --apply"
    info "3. After the first start of WLS_FORMS/WLS_REPORTS (creates servers/<name>/):"
    info "     09-Install/10-oracle_boot_properties.sh --apply"
fi
info "Start / stop the whole domain later:"
info "     01-Run/startStop.sh start-all --apply"
info "     01-Run/startStop.sh stop-all  --apply"

# =============================================================================
print_summary
exit "$EXIT_CODE"
