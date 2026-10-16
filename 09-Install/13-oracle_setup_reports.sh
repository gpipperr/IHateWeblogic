#!/bin/bash
# =============================================================================
# Script   : 13-oracle_setup_reports.sh
# Purpose  : Phase 6 – Configure Oracle Reports Server system components:
#              1. Create ReportsTools + ReportsServer instances (WLST)
#              2. Set unique broadcasting port in rwnetwork.conf (3 locations)
#              3. Write rwservlet.properties (servlet → server mapping)
#              4. Write rwserver.conf per ReportsServer instance (engine tuning)
#                 REPORTS_SECURITY=ldap (default): secured Reports server -
#                 securityId on the report job, OPSS JSE identity store
#                 (jps-config-jse.xml) = WebLogic embedded LDAP, bind user from
#                 the credential store (createCred) - WebLogic users/roles
#                 (RW_MONITOR, RW_EXECREPORTS) work for the standalone server
#              5. Patch reports.sh (NLS_LANG, fonts, REPORTS_PATH,
#                 REPORTS_JVM_OPTIONS of the rwserver: process reaper fix +
#                 ORB connect timeout) and setUserOverrides.sh (ORB connect
#                 timeout of WLS_REPORTS)
#            Background: 80-FMW-Architecture/reports_user_local_ldap.md
# Call     : ./09-Install/13-oracle_setup_reports.sh
#            ./09-Install/13-oracle_setup_reports.sh --apply
#            ./09-Install/13-oracle_setup_reports.sh --apply --skip-wlst
# Options  : --apply       Write all configuration files
#            --skip-wlst   Skip WLST instance creation (AdminServer not running)
#            --help        Show usage
# Requires : environment.conf with Reports variables (init_env.sh --apply)
#            weblogic_sec.conf.des3 (for WLST credential loading)
#            embedded_ldap_sec.conf.des3 (REPORTS_SECURITY=ldap: password of
#              the embedded LDAP administrator cn=Admin, asked by
#              01-setup-interview.sh; if the domain still has the random one,
#              13 sets it via WLST - then restart the AdminServer, re-run 13)
#            AdminServer running unless --skip-wlst
#            13-root_reports_fix.sh done (libnsl.so.2 symlink)
# Runs as  : oracle
# Ref      : 09-Install/docs/13-reports-detail-settings.md
#            Oracle Support Doc ID 437228.1 (broadcasting port)
#            Oracle Support Doc ID 3069675.1 (libnsl)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_SH="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"

if [ ! -f "$LIB_SH" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB_SH" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB_SH"

check_env_conf "$ROOT_DIR/environment.conf" || exit 2
# shellcheck source=../environment.conf
source "$ROOT_DIR/environment.conf"

# =============================================================================
# Arguments
# =============================================================================

APPLY=false
SKIP_WLST=false

for _arg in "$@"; do
    case "$_arg" in
        --apply)      APPLY=true ;;
        --skip-wlst)  SKIP_WLST=true ;;
        --help|-h)
            printf "Usage: %s [--apply] [--skip-wlst]\n\n" "$(basename "$0")"
            printf "  %-16s %s\n" "--apply"      "Write all configuration files"
            printf "  %-16s %s\n" "--skip-wlst"  "Skip WLST instance creation (AdminServer not running)"
            printf "\nWithout --apply: dry-run, no files changed.\n"
            exit 0 ;;
        *) warn "Unknown argument: $_arg" ;;
    esac
done
unset _arg

# =============================================================================
# Log setup
# =============================================================================

LOG_FILE="$ROOT_DIR/log/$(date +%Y%m%d)/reports_setup_$(date +%H%M%S).log"
mkdir -p "$(dirname "$LOG_FILE")"
{
    printf "# 13-oracle_setup_reports.sh log\n"
    printf "# Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# Host    : %s\n" "$(_get_hostname)"
    printf "# Apply   : %s\n" "$APPLY"
} > "$LOG_FILE"

# =============================================================================
# Header
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – Reports Server Setup\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host              : %s\n" "$(_get_hostname)"               | tee -a "$LOG_FILE"
printf "  DOMAIN_HOME       : %s\n" "${DOMAIN_HOME:-?}"              | tee -a "$LOG_FILE"
printf "  Tools instance    : %s\n" "${REPORTS_TOOLS_INSTANCE:-?}"   | tee -a "$LOG_FILE"
printf "  Server instance(s): %s\n" "${REPORTS_SERVER_INSTANCES:-?}" | tee -a "$LOG_FILE"
printf "  Broadcast port    : %s\n" "${REPORTS_BROADCAST_PORT:-?}"   | tee -a "$LOG_FILE"
printf "  Apply             : %s\n" "$APPLY"                         | tee -a "$LOG_FILE"
printf "  Log               : %s\n" "$LOG_FILE"                      | tee -a "$LOG_FILE"
printLine

# =============================================================================
# 1. Prerequisites
# =============================================================================

section "Prerequisites"

_prereq_fail=false
for _var in ORACLE_HOME DOMAIN_HOME WLS_MANAGED_SERVER \
            REPORTS_TOOLS_INSTANCE REPORTS_SERVER_INSTANCES \
            REPORTS_BROADCAST_PORT REPORTS_PATH REPORTS_TMP; do
    if [ -z "${!_var:-}" ]; then
        fail "$_var is not set in environment.conf"
        _prereq_fail=true
    else
        ok "$(printf "  %-28s = %s" "$_var" "${!_var}")"
    fi
done
unset _var
$_prereq_fail && info "  Runtime parameters are added by: 00-Setup/init_env.sh --apply (after 08-)"
$_prereq_fail && { print_summary; exit "$EXIT_CODE"; }
unset _prereq_fail

[ ! -d "$ORACLE_HOME" ] && { fail "ORACLE_HOME not found: $ORACLE_HOME"; print_summary; exit "$EXIT_CODE"; }
ok "ORACLE_HOME exists"

[ ! -d "$DOMAIN_HOME" ] && {
    fail "DOMAIN_HOME not found: $DOMAIN_HOME"
    info "  Run 08-oracle_setup_domain.sh first"
    print_summary; exit "$EXIT_CODE"
}
ok "DOMAIN_HOME exists"

WLST_SH="$ORACLE_HOME/oracle_common/common/bin/wlst.sh"
if [ -f "$WLST_SH" ]; then
    ok "wlst.sh found"
else
    warn "wlst.sh not found – WLST step will be skipped"
    SKIP_WLST=true
fi

# Detect reports application directory (version is part of the name, e.g. reports_14.1.2.0.0)
_REPORTS_APP_BASE="$DOMAIN_HOME/config/fmwconfig/servers/${WLS_MANAGED_SERVER}/applications"
_REPORTS_APP_DIR=""
if [ -d "$_REPORTS_APP_BASE" ]; then
    _REPORTS_APP_DIR="$(find "$_REPORTS_APP_BASE" -maxdepth 1 -type d -name 'reports_*' 2>/dev/null \
        | sort | tail -1)"
fi
if [ -n "$_REPORTS_APP_DIR" ]; then
    ok "Reports app dir: $_REPORTS_APP_DIR"
else
    warn "Reports app dir not found under: $_REPORTS_APP_BASE"
    info "  rwnetwork.conf (WLS_REPORTS location) and rwservlet.properties will be skipped"
fi

# Generate REPORTS_COOKIE_KEY if empty
if [ -z "${REPORTS_COOKIE_KEY:-}" ]; then
    REPORTS_COOKIE_KEY="$(openssl rand -hex 16 2>/dev/null \
        || tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c 32)"
    # Persist with --apply – otherwise every run generated a new key
    # (rwservlet.properties must keep a stable one). environment.conf is a
    # symlink into 00-Setup/environments/ – sed must follow it.
    _env_conf="$ROOT_DIR/environment.conf"
    if $APPLY; then
        if grep -q '^REPORTS_COOKIE_KEY=' "$_env_conf"; then
            sed -i --follow-symlinks "s/^REPORTS_COOKIE_KEY=.*/REPORTS_COOKIE_KEY=\"${REPORTS_COOKIE_KEY}\"/" "$_env_conf"
        else
            printf 'REPORTS_COOKIE_KEY="%s"\n' "$REPORTS_COOKIE_KEY" >> "$(readlink -f "$_env_conf")"
        fi
        ok "REPORTS_COOKIE_KEY generated and saved to environment.conf"
    else
        info "REPORTS_COOKIE_KEY is empty – --apply generates one and saves it to environment.conf"
    fi
    unset _env_conf
fi

# First entry of REPORTS_SERVER_INSTANCES is the default servlet target
_FIRST_SERVER_INST="${REPORTS_SERVER_INSTANCES%% *}"

# =============================================================================
# 2. WLST – Create System Component Instances
# =============================================================================

section "WLST – Create System Component Instances"

# Check existing component directories
_TOOLS_CONF_BASE="$DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent"
_REPSERV_CONF_BASE="$DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent"

if [ -d "$_TOOLS_CONF_BASE/$REPORTS_TOOLS_INSTANCE" ]; then
    ok "ReportsTools instance already exists: $REPORTS_TOOLS_INSTANCE"
    _wlst_tools_needed=false
else
    warn "ReportsTools instance not found: $REPORTS_TOOLS_INSTANCE"
    _wlst_tools_needed=true
fi

_wlst_servers_needed=false
for _inst in $REPORTS_SERVER_INSTANCES; do
    if [ -d "$_REPSERV_CONF_BASE/$_inst" ]; then
        ok "ReportsServer instance already exists: $_inst"
    else
        warn "ReportsServer instance not found: $_inst"
        _wlst_servers_needed=true
    fi
done
unset _inst

if $SKIP_WLST; then
    info "WLST skipped (--skip-wlst or wlst.sh not found)"
    info "  Create instances manually in WLST:"
    info "  connect(user, password, 't3://localhost:${WLS_ADMIN_PORT:-7001}')"
    info "  createReportsToolsInstance(instanceName='$REPORTS_TOOLS_INSTANCE', machine='AdminServerMachine')"
    for _inst in $REPORTS_SERVER_INSTANCES; do
        info "  createReportsServerInstance(instanceName='$_inst', machine='AdminServerMachine')"
    done
    unset _inst
elif ! $_wlst_tools_needed && ! $_wlst_servers_needed; then
    ok "All instances already exist – WLST not needed"
else
    _adm_port="${WLS_ADMIN_PORT:-7001}"
    if ! timeout 3 bash -c "echo >/dev/tcp/localhost/${_adm_port}" 2>/dev/null; then
        warn "AdminServer not reachable on port $_adm_port – skipping WLST"
        info "  Start AdminServer first, then re-run without --skip-wlst"
    elif $APPLY; then
        ok "AdminServer reachable on port $_adm_port"
        # createReportsServerInstance needs the MBean ReportsServerComponentManager.
        # The AdminServer registers it from components/ReportsServerComponent/
        # mbeans/mbeans.xml, which only the domain template "Oracle Reports
        # Server" (oracle.reports_server_template.jar) brings - the Reports app
        # template only pulls in "Oracle Reports Tools" (confirmed 2026-10-15:
        # WLS_REPORTS running did not help, the MBean was simply not defined).
        _srv_mbeans="$DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent/mbeans/mbeans.xml"
        _skip_servers=0
        if $_wlst_servers_needed && [ ! -f "$_srv_mbeans" ]; then
            fail "Domain lacks the template 'Oracle Reports Server' – ReportsServer instance(s) cannot be created"
            info "  Missing: $_srv_mbeans"
            info "  Extend the domain offline (all servers stopped), then restart and re-run this script:"
            info "    readDomain('$DOMAIN_HOME')"
            info "    addTemplate('$ORACLE_HOME/ReportsServerComponent/common/templates/wls/oracle.reports_server_template.jar')"
            info "    updateDomain(); closeDomain()"
            info "  See docs/13-reports-detail-settings.md (08- adds it since 2026-10-15)"
            _skip_servers=1
        fi
        if ! load_weblogic_password; then
            fail "Cannot load WebLogic credentials – run 00-Setup/weblogic_sec.sh --apply"
            print_summary; exit "$EXIT_CODE"
        fi

        _wlst_script="$(mktemp --suffix=.py)"
        cat > "$_wlst_script" <<'WLST_SCRIPT'
import os, sys

wl_user      = os.environ.get('_IHW_WL_USER', '')
wl_pass      = os.environ.get('_IHW_WL_PASS', '')
adm_url      = os.environ.get('_IHW_ADM_URL', 't3://localhost:7001')
tools_inst   = os.environ.get('_IHW_TOOLS_INST', 'reptools_ent')
server_insts = [s for s in os.environ.get('_IHW_SERVER_INSTS', 'repserver_ent').split() if s]
machine      = os.environ.get('_IHW_MACHINE', 'AdminServerMachine')

try:
    connect(wl_user, wl_pass, adm_url)

    # ReportsTools instance (skipped when it already exists - a second
    # createReportsToolsInstance reported "Created" again, 2026-10-15)
    if os.environ.get('_IHW_SKIP_TOOLS', '0') == '1':
        tools_inst = ''
    try:
        if not tools_inst:
            raise Exception('already exists')
        createReportsToolsInstance(instanceName=tools_inst, machine=machine)
        print('IHW:OK:Created ReportsTools instance: ' + tools_inst)
    except Exception as ex:
        msg = str(ex).lower()
        if 'already exists' in msg or 'duplicate' in msg:
            print('IHW:INFO:ReportsTools instance already exists: ' + tools_inst)
        else:
            print('IHW:FAIL:createReportsToolsInstance failed: ' + str(ex))
            sys.exit(1)

    # ReportsServer instances (skipped when the domain lacks the server template)
    if os.environ.get('_IHW_SKIP_SERVERS', '0') == '1':
        server_insts = []
    for inst in server_insts:
        try:
            createReportsServerInstance(instanceName=inst, machine=machine)
            print('IHW:OK:Created ReportsServer instance: ' + inst)
        except Exception as ex:
            msg = str(ex).lower()
            if 'already exists' in msg or 'duplicate' in msg:
                print('IHW:INFO:ReportsServer instance already exists: ' + inst)
            else:
                print('IHW:FAIL:createReportsServerInstance failed for ' + inst + ': ' + str(ex))
                sys.exit(1)

    disconnect()
except Exception as e:
    print('IHW:FAIL:WLST error: ' + str(e))
    sys.exit(1)
WLST_SCRIPT

        export _IHW_WL_USER="$WL_USER"
        export _IHW_WL_PASS="$INTERNAL_WL_PWD"
        export _IHW_ADM_URL="t3://localhost:${_adm_port}"
        export _IHW_TOOLS_INST="$REPORTS_TOOLS_INSTANCE"
        export _IHW_SERVER_INSTS="$REPORTS_SERVER_INSTANCES"
        export _IHW_MACHINE="AdminServerMachine"
        export _IHW_SKIP_SERVERS="$_skip_servers"
        export _IHW_SKIP_TOOLS="$($_wlst_tools_needed && printf 0 || printf 1)"

        _wlst_out="$("$WLST_SH" "$_wlst_script" 2>&1)"

        unset _IHW_WL_USER _IHW_WL_PASS INTERNAL_WL_PWD _IHW_SKIP_SERVERS _IHW_SKIP_TOOLS

        while IFS= read -r _line; do
            case "$_line" in
                IHW:OK:*)   ok   "$(printf '%s' "$_line" | cut -d: -f3-)" ;;
                IHW:INFO:*) info "$(printf '%s' "$_line" | cut -d: -f3-)" ;;
                IHW:WARN:*) warn "$(printf '%s' "$_line" | cut -d: -f3-)" ;;
                IHW:FAIL:*) fail "$(printf '%s' "$_line" | cut -d: -f3-)" ;;
            esac
        done <<< "$_wlst_out"

        rm -f "$_wlst_script"
        unset _wlst_script _wlst_out WL_USER _srv_mbeans _skip_servers
    else
        ok "AdminServer reachable – dry-run would create instances via WLST"
    fi
    unset _adm_port
fi
unset _wlst_tools_needed _wlst_servers_needed

# =============================================================================
# 3. Broadcasting Port – rwnetwork.conf (3 locations)
# =============================================================================

section "rwnetwork.conf – Broadcasting Port (Doc ID 437228.1)"

_update_rwnetwork() {
    local file="$1" label="$2"
    if [ ! -f "$file" ]; then
        warn "rwnetwork.conf not found: $label"
        info "  Expected: $file"
        return 1
    fi
    # 14.1.2: <multicast channel=".." port="14021" .../>; older releases: <cluster port=..>
    # (the <cluster> pattern alone failed on 14.1.2, 2026-10-15)
    local current_port
    current_port="$(sed -nE 's/.*<(multicast|cluster)[^>]*port="([0-9]*)".*/\2/p' "$file" 2>/dev/null | head -1)"
    printf "  %-52s port=%s\n" "$label" "${current_port:-(not found)}" \
        | tee -a "${LOG_FILE:-/dev/null}"

    if [ "$current_port" = "$REPORTS_BROADCAST_PORT" ]; then
        ok "Port already correct: $REPORTS_BROADCAST_PORT"
        return 0
    fi

    warn "Port is '${current_port:-unknown}' – target: $REPORTS_BROADCAST_PORT"
    if $APPLY; then
        cp "$file" "${file}.bak_$(date +%Y%m%d_%H%M%S)"
        sed -i -E "s/(<(multicast|cluster)[^>]*port=\")[0-9]*/\1${REPORTS_BROADCAST_PORT}/" "$file"
        local new_port
        new_port="$(sed -nE 's/.*<(multicast|cluster)[^>]*port="([0-9]*)".*/\2/p' "$file" 2>/dev/null | head -1)"
        if [ "$new_port" = "$REPORTS_BROADCAST_PORT" ]; then
            ok "Updated port to $REPORTS_BROADCAST_PORT in $label"
        else
            fail "sed did not update port in $label – verify XML pattern"
            info "  Expected: <multicast ... port=\"NNNN\" .../> (or <cluster ...> before 14.1.2)"
            info "  File: $file"
        fi
    else
        info "  Dry-run – would change port to $REPORTS_BROADCAST_PORT"
    fi
}

# Multicast discovery prerequisites (2026-10-15): route, MULTICAST flag,
# firewall UDP port, send/receive self-test - done by
# 02-Checks/reports_network_scan.sh (also scans the network for other Reports
# servers when called without --no-scan). Without multicast reception the
# Reports server stops at once with REP-50600 and the Node Manager restarts it
# in a loop (customer 2026-10-15).
_scan="$ROOT_DIR/02-Checks/reports_network_scan.sh"
if [ -x "$_scan" ]; then
    info "Multicast checks: 02-Checks/reports_network_scan.sh --no-scan --port ${REPORTS_BROADCAST_PORT}"
    bash "$_scan" --no-scan --port "${REPORTS_BROADCAST_PORT}" 2>&1 \
        | sed -n '/=== Multicast Prerequisites/,/=== Summary/p' | grep -vE '=== Summary|^-{20,}' \
        | tee -a "$LOG_FILE"
    _scan_rc=${PIPESTATUS[0]}
    case "$_scan_rc" in
        0) ok   "Multicast prerequisites OK" ;;
        1) warn "Multicast prerequisites: warnings – see above" ;;
        *) fail "Multicast prerequisites failed – the Reports server would stop with REP-50600" ;;
    esac
    info "  Other Reports servers in the network: 02-Checks/reports_network_scan.sh (port scan)"
    unset _scan_rc
else
    warn "02-Checks/reports_network_scan.sh not found – multicast checks skipped"
fi
unset _scan

# Location 1: ReportsToolsComponent
_update_rwnetwork \
    "$_TOOLS_CONF_BASE/$REPORTS_TOOLS_INSTANCE/rwnetwork.conf" \
    "ReportsToolsComponent/$REPORTS_TOOLS_INSTANCE"

# Location 2: ReportsServerComponent (one per instance)
for _inst in $REPORTS_SERVER_INSTANCES; do
    _update_rwnetwork \
        "$_REPSERV_CONF_BASE/$_inst/rwnetwork.conf" \
        "ReportsServerComponent/$_inst"
done
unset _inst

# Location 3: WLS_REPORTS application config
if [ -n "$_REPORTS_APP_DIR" ]; then
    _update_rwnetwork \
        "$_REPORTS_APP_DIR/configuration/rwnetwork.conf" \
        "WLS_REPORTS/$(basename "$_REPORTS_APP_DIR")"
else
    warn "Skipping WLS_REPORTS rwnetwork.conf – application dir not found"
fi

# =============================================================================
# 4. rwservlet.properties
# =============================================================================

section "rwservlet.properties"

if [ -z "$_REPORTS_APP_DIR" ]; then
    warn "Skipping rwservlet.properties – Reports application dir not found"
else
    _RWSERVLET="$_REPORTS_APP_DIR/configuration/rwservlet.properties"
    printf "  %-26s %s\n" "File:" "$_RWSERVLET" | tee -a "${LOG_FILE:-/dev/null}"

    if [ -f "$_RWSERVLET" ]; then
        _cur_server="$(sed -n 's/.*<server>\([^<]*\)<.*/\1/p' "$_RWSERVLET" 2>/dev/null | head -1)"
        _cur_inproc="$(sed -n 's/.*<inprocess>\([^<]*\)<.*/\1/p' "$_RWSERVLET" 2>/dev/null | head -1)"
        printf "  %-26s server=%-24s  inprocess=%s\n" "Current:" \
            "${_cur_server:-(not set)}" "${_cur_inproc:-(not set)}" \
            | tee -a "${LOG_FILE:-/dev/null}"
        if [ "${_cur_server}" = "$_FIRST_SERVER_INST" ] && [ "${_cur_inproc}" = "no" ]; then
            ok "rwservlet.properties already configured correctly"
        else
            warn "rwservlet.properties needs update"
        fi
        unset _cur_server _cur_inproc
    else
        warn "rwservlet.properties not found – will create on --apply"
    fi

    if $APPLY; then
        [ -f "$_RWSERVLET" ] && cp "$_RWSERVLET" "${_RWSERVLET}.bak_$(date +%Y%m%d_%H%M%S)"
        # Write the file (no heredoc quoting – variables expand as intended)
        {
            printf '<?xml version="1.0" encoding="UTF-8"?>\n'
            printf '<rwservlet xmlns="http://xmlns.oracle.com/reports/rwservlet"\n'
            printf '           xmlns:xsd="http://www.w3.org/2001/XMLSchema">\n'
            printf '  <server>%s</server>\n'        "$_FIRST_SERVER_INST"
            printf '  <singlesignon>yes</singlesignon>\n'
            printf '  <inprocess>no</inprocess>\n'
            printf '  <webcommandaccess>L1</webcommandaccess>\n'
            printf '  <cookie cookieexpire="30" encryptionkey="%s"/>\n' "$REPORTS_COOKIE_KEY"
            printf '</rwservlet>\n'
        } > "$_RWSERVLET"
        ok "rwservlet.properties written (server=$_FIRST_SERVER_INST, inprocess=no)"
    else
        info "Dry-run – would write rwservlet.properties:"
        info "  <server>$_FIRST_SERVER_INST</server>  <inprocess>no</inprocess>"
    fi
    unset _RWSERVLET
fi

# =============================================================================
# 4b. Report directories (REPORTS_PATH entries + REPORTS_TMP)
#     Default layout (since 2026-10-16): $ORACLE_BASE/reports/source (reports),
#     .../images (images, Link File / Read from File), .../tmp (output) - outside
#     ORACLE_HOME and outside /tmp (cleaned at reboot). <folderAccess> grants
#     exactly these directories (no subdirectories).
# =============================================================================

section "Report Directories"

_report_dirs=()
IFS=':' read -r -a _rp_dirs <<< "$REPORTS_PATH"
for _d in "${_rp_dirs[@]}" "$REPORTS_TMP"; do
    [ -n "$_d" ] && _report_dirs+=("$_d")
done
for _d in "${_report_dirs[@]}"; do
    if [ -d "$_d" ]; then
        if [ -w "$_d" ]; then
            ok "$(printf "  exists   %s" "$_d")"
        else
            warn "$(printf "  exists, not writable for %s: %s" "$(id -un)" "$_d")"
        fi
    elif $APPLY; then
        if mkdir -p "$_d" && chmod 750 "$_d"; then
            ok "$(printf "  created  %s (750)" "$_d")"
        else
            fail "$(printf "  cannot create %s - create it as root and chown to %s" "$_d" "$(id -un)")"
        fi
    else
        info "$(printf "  dry-run - would create %s (750)" "$_d")"
    fi
done
unset _report_dirs _rp_dirs _d

# =============================================================================
# 4c. Reports server security - OPSS JSE identity store (REPORTS_SECURITY)
#     The standalone Reports server (rwserver, Java SE) reads OPSS from
#     jps-config-jse.xml: policy/credential store = shared DB (OPSS schema),
#     identity store = XML (system-jazn-data.xml) -> WebLogic users unknown.
#     ldap: identity store -> WebLogic embedded LDAP of the AdminServer, then
#           securityId="rwJaznSec" on the report job (5.) - users and roles
#           of the realm work (monUser/RW_MONITOR, RepRunner/RW_EXECREPORTS).
#     identifier: no securityId - web commands only for the <identifier>
#           server admin, report jobs WITHOUT any user check.
#     Tested 2026-10-16 (80-FMW-Architecture/reports_user_local_ldap.md).
# =============================================================================

section "Reports Server Security (REPORTS_SECURITY=${REPORTS_SECURITY:-ldap})"

REPORTS_SECURITY="${REPORTS_SECURITY:-ldap}"
SEC_LDAP=false
_JSE="$DOMAIN_HOME/config/fmwconfig/jps-config-jse.xml"
_ELDAP_SEC="$ROOT_DIR/embedded_ldap_sec.conf.des3"
_dom="$(grep -m1 -o '<name>[^<]*</name>' "$DOMAIN_HOME/config/config.xml" 2>/dev/null | sed 's/<[^>]*>//g')"
_dom="${_dom:-$(basename "$DOMAIN_HOME")}"
_ldap_url="ldap://localhost:${WLS_ADMIN_PORT:-7001}"
_ldap_base="ou=myrealm,dc=${_dom}"

if [ "$REPORTS_SECURITY" != "ldap" ]; then
    warn "REPORTS_SECURITY=$REPORTS_SECURITY - Reports server NOT secured:"
    info "  web commands (getserverinfo) only for the <identifier> admin,"
    info "  report jobs without user check (only DB userid + folderAccess)"
elif [ ! -f "$_JSE" ]; then
    fail "jps-config-jse.xml not found: $_JSE"
elif [ ! -f "$_ELDAP_SEC" ]; then
    warn "Password of the embedded LDAP administrator not stored: $_ELDAP_SEC"
    info "  Normally asked by 09-Install/01-setup-interview.sh (REPORTS_SECURITY=ldap)."
    info "  Or manually (once), then re-run this script - 13 sets it in the domain:"
    info "   1. choose a password (letters/digits), store it encrypted:"
    info "      read -s -p 'Embedded-LDAP password: ' P; echo"
    info "      bash -c 'source 00-Setup/IHateWeblogic_lib.sh; _write_secrets_file $_ELDAP_SEC \"EMBEDDED_LDAP_USER=cn=Admin\" \"EMBEDDED_LDAP_PWD=\$1\"' _ \"\$P\"; unset P"
    info "  Until then the Reports server stays unsecured (no securityId)."
else
    ok "$(printf "Identity store target: %s  %s" "$_ldap_url" "$_ldap_base")"

    # --- a) bind user into the OPSS credential store + LDAP bind check (WLST)
    _cred_ok=false
    if ! $APPLY; then
        info "Dry-run - would check the LDAP bind as cn=Admin and createCred(map='reports.idstore', key='embeddedldap')"
        _cred_ok=true
    elif $SKIP_WLST; then
        warn "--skip-wlst: credential + LDAP bind not checked - re-run without --skip-wlst"
    elif ! timeout 3 bash -c "echo >/dev/tcp/localhost/${WLS_ADMIN_PORT:-7001}" 2>/dev/null; then
        warn "AdminServer not reachable on port ${WLS_ADMIN_PORT:-7001} - security step skipped"
    elif load_weblogic_password > /dev/null 2>&1 && load_secrets_file "$_ELDAP_SEC" > /dev/null 2>&1; then
        _sec_py="$(mktemp --suffix=.py)"; chmod 600 "$_sec_py"
        cat > "$_sec_py" << 'SEC_PY'
import os
from java.util import Hashtable
from javax.naming import Context
from javax.naming.directory import InitialDirContext
e = os.environ
env = Hashtable()
env.put(Context.INITIAL_CONTEXT_FACTORY, 'com.sun.jndi.ldap.LdapCtxFactory')
env.put(Context.PROVIDER_URL, e['_IHW_LDAP_URL'])
env.put(Context.SECURITY_AUTHENTICATION, 'simple')
env.put(Context.SECURITY_PRINCIPAL, 'cn=Admin')
env.put(Context.SECURITY_CREDENTIALS, e['_IHW_LDAP_PWD'])
bind_ok = 0
try:
    InitialDirContext(env).close()
    print('IHW:OK:LDAP bind as cn=Admin to ' + e['_IHW_LDAP_URL'])
    bind_ok = 1
except Exception, ex:
    print('IHW:INFO:LDAP bind as cn=Admin failed (' + str(ex).split('\n')[0] + ')')
try:
    connect(e['_IHW_WL_USER'], e['_IHW_WL_PASS'], e['_IHW_ADM_URL'])
    if not bind_ok:
        # the domain still has the random password of the domain creation:
        # set the one from embedded_ldap_sec.conf.des3 (read at AdminServer start)
        edit()
        startEdit()
        cd('/EmbeddedLDAP/' + e['_IHW_DOMAIN'])
        cmo.setCredential(e['_IHW_LDAP_PWD'])
        save()
        activate(block='true')
        print('IHW:RESTART:embedded LDAP password set in the domain - restart the AdminServer, then re-run this script')
        disconnect()
        exit()
    try:
        createCred(map='reports.idstore', key='embeddedldap', user='cn=Admin',
                   password=e['_IHW_LDAP_PWD'], desc='Bind user of the Reports JSE identity store')
        print('IHW:OK:createCred reports.idstore/embeddedldap')
    except Exception, ex:
        updateCred(map='reports.idstore', key='embeddedldap', user='cn=Admin',
                   password=e['_IHW_LDAP_PWD'], desc='Bind user of the Reports JSE identity store')
        print('IHW:OK:updateCred reports.idstore/embeddedldap (already existed)')
    disconnect()
except Exception, ex:
    print('IHW:FAIL:credential store: ' + str(ex).split('\n')[0])
    exit(exitcode=1)
exit()
SEC_PY
        _sec_out="$(_IHW_LDAP_URL="$_ldap_url" _IHW_LDAP_PWD="$EMBEDDED_LDAP_PWD" _IHW_DOMAIN="$_dom" \
                    _IHW_WL_USER="$WL_USER" _IHW_WL_PASS="$INTERNAL_WL_PWD" \
                    _IHW_ADM_URL="t3://localhost:${WLS_ADMIN_PORT:-7001}" \
                    "$WLST_SH" "$_sec_py" 2>&1)"
        rm -f "$_sec_py"
        unset EMBEDDED_LDAP_PWD INTERNAL_WL_PWD
        while IFS= read -r _line; do
            case "$_line" in
                IHW:OK:*)      ok   "$(printf '%s' "$_line" | cut -d: -f3-)" ;;
                IHW:INFO:*)    info "$(printf '%s' "$_line" | cut -d: -f3-)" ;;
                IHW:RESTART:*) warn "$(printf '%s' "$_line" | cut -d: -f3-)"
                               info "  e.g. \$ORACLE_BASE/admin/<domain>/ctrl/fmw_ctl.sh stop AdminServer && ... start AdminServer"
                               info "  (managed servers and the Reports server keep running)" ;;
                IHW:FAIL:*)    fail "$(printf '%s' "$_line" | cut -d: -f3-)" ;;
            esac
        done <<< "$_sec_out"
        printf '%s\n' "$_sec_out" | grep -q '^IHW:OK:.*Cred' && _cred_ok=true
        unset _sec_py _sec_out _line
    else
        fail "Cannot load weblogic_sec.conf.des3 / $_ELDAP_SEC"
    fi

    # --- b) identity store instance in jps-config-jse.xml (idempotent)
    if $_cred_ok; then
        if grep -q 'serviceInstanceRef ref="idstore.ldap.embedded"' "$_JSE"; then
            ok "jps-config-jse.xml: identity store idstore.ldap.embedded already active"
            SEC_LDAP=true
        elif ! $APPLY; then
            info "Dry-run - would add idstore.ldap.embedded to $_JSE and replace idstore.xml in the default context"
            SEC_LDAP=true
        else
            cp -p "$_JSE" "${_JSE}.bak_$(date +%Y%m%d_%H%M%S)"
            if python3 - "$_JSE" "$_ldap_url" "$_ldap_base" << 'JSE_PY'
import sys
p, url, base = sys.argv[1:4]
s = open(p, encoding='utf-8').read()
inst = """        <!-- IHateWeblogic 13-oracle_setup_reports.sh: identity store = WebLogic embedded LDAP -->
        <serviceInstance name="idstore.ldap.embedded" provider="idstore.ldap.provider">
            <description>WebLogic embedded LDAP of the AdminServer (realm myrealm)</description>
            <property name="idstore.type" value="OPEN_LDAP"/>
            <property name="ldap.url" value="%s"/>
            <property name="security.principal.alias" value="reports.idstore"/>
            <property name="security.principal.key" value="embeddedldap"/>
            <property name="subscriber.name" value="%s"/>
            <property name="username.attr" value="uid"/>
            <property name="groupname.attr" value="cn"/>
            <extendedProperty>
                <name>user.search.bases</name>
                <values><value>ou=people,%s</value></values>
            </extendedProperty>
            <extendedProperty>
                <name>group.search.bases</name>
                <values><value>ou=groups,%s</value></values>
            </extendedProperty>
        </serviceInstance>
""" % (url, base, base, base)
if 'name="idstore.ldap.embedded"' not in s:
    i = s.index('    </serviceInstances>')
    s = s[:i] + inst + s[i:]
old = '            <serviceInstanceRef ref="idstore.xml"/>\n'
if s.count(old) != 1:
    sys.exit('default context: expected exactly one active idstore.xml reference')
s = s.replace(old, '            <!--serviceInstanceRef ref="idstore.xml"/-->\n'
                   '            <serviceInstanceRef ref="idstore.ldap.embedded"/>\n', 1)
open(p, 'w', encoding='utf-8').write(s)
JSE_PY
            then
                ok "jps-config-jse.xml: identity store switched to idstore.ldap.embedded"
                SEC_LDAP=true
            else
                fail "jps-config-jse.xml not changed - check $_JSE"
            fi
        fi
    fi
fi
$SEC_LDAP && info "  rwserver.conf gets securityId=\"rwJaznSec\" on the report job"
unset _JSE _ELDAP_SEC _dom _ldap_url _ldap_base _cred_ok

# =============================================================================
# 5. rwserver.conf (per ReportsServer instance)
# =============================================================================

section "rwserver.conf"

_ENG_INIT="${REPORTS_ENGINE_INIT:-2}"
_ENG_MAX="${REPORTS_ENGINE_MAX:-5}"
_ENG_MIN="${REPORTS_ENGINE_MIN:-2}"
_MAX_CONN="${REPORTS_MAX_CONNECT:-300}"
_MAX_QUEUE="${REPORTS_MAX_QUEUE:-4000}"
_NLS="${NLS_LANG:-GERMAN_GERMANY.AL32UTF8}"

# Reports server administrator (<identifier>, not a WebLogic user) from
# reports_admin_sec.conf.des3 (asked by 01-setup-interview.sh). Missing ->
# with --apply a random password is generated and stored there.
_RADM_SEC="$ROOT_DIR/reports_admin_sec.conf.des3"
_RADM_USER="${REPORTS_ADMIN_USER:-rep_admin}"
_RADM_PWD=""
if [ -f "$_RADM_SEC" ]; then
    if load_secrets_file "$_RADM_SEC" > /dev/null 2>&1 && [ -n "${REPORTS_ADMIN_PWD:-}" ]; then
        _RADM_USER="${REPORTS_ADMIN_USER:-$_RADM_USER}"
        _RADM_PWD="$REPORTS_ADMIN_PWD"
        ok "Reports server admin <identifier>: $_RADM_USER (password from $(basename "$_RADM_SEC"))"
    else
        fail "Cannot read $_RADM_SEC - re-run 01-setup-interview.sh --reset or delete the file"
    fi
elif $APPLY; then
    _RADM_PWD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-20)"
    if _write_secrets_file "$_RADM_SEC" "REPORTS_ADMIN_USER=$_RADM_USER" "REPORTS_ADMIN_PWD=$_RADM_PWD" > /dev/null; then
        warn "Reports server admin password not stored - generated a random one: $(basename "$_RADM_SEC")"
        info "  show: bash -c 'source 00-Setup/IHateWeblogic_lib.sh; load_secrets_file $_RADM_SEC; printf \"%s\\n\" \"\$REPORTS_ADMIN_PWD\"'"
    else
        _RADM_PWD=""
        fail "Could not store $_RADM_SEC"
    fi
else
    info "Dry-run - $(basename "$_RADM_SEC") missing: --apply generates a random <identifier> password"
fi
unset REPORTS_ADMIN_PWD
case "$_RADM_USER/$_RADM_PWD" in
    */*/*|*[\&\<\>\"\'\ ]*)
        fail "Reports server admin user/password contains / & < > quote or blank - not usable in <identifier>"
        _RADM_PWD="" ;;
esac

for _inst in $REPORTS_SERVER_INSTANCES; do
    _RWSERVER="$_REPSERV_CONF_BASE/$_inst/rwserver.conf"
    printf "  %-26s %s\n" "Instance:" "$_inst" | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "File:" "$_RWSERVER"  | tee -a "${LOG_FILE:-/dev/null}"

    if [ ! -d "$_REPSERV_CONF_BASE/$_inst" ]; then
        warn "Component dir missing: $_REPSERV_CONF_BASE/$_inst"
        info "  WLST step 2 must complete first"
        continue
    fi

    if [ -f "$_RWSERVER" ]; then
        ok "Existing rwserver.conf found – will backup and overwrite"
    else
        warn "rwserver.conf not found – will create"
    fi

    if $APPLY; then
        [ -f "$_RWSERVER" ] && cp "$_RWSERVER" "${_RWSERVER}.bak_$(date +%Y%m%d_%H%M%S)"

        # Build optional TNS_ADMIN line
        _tns_line=""
        [ -n "${TNS_ADMIN:-}" ] && \
            _tns_line="    <envVariable name=\"TNS_ADMIN\"           value=\"${TNS_ADMIN}\"/>"

        {
            printf '<?xml version="1.0" encoding="ISO-8859-1"?>\n'
            printf '<server xmlns="http://xmlns.oracle.com/reports/server"\n'
            printf '        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\n'
            printf '\n'
            printf '  <cache class="oracle.reports.cache.RWCache">\n'
            printf '    <property name="cacheSize" value="50"/>\n'
            printf '  </cache>\n'
            printf '\n'
            printf '  <!-- Engine configuration (tune to available CPUs and load) -->\n'
            printf '  <!-- initEngine = pre-started processes; keep equal to minEngine -->\n'
            printf '  <engine id="rwEng" class="oracle.reports.engine.EngineImpl"\n'
            printf '          initEngine="%s" maxEngine="%s" minEngine="%s"\n' \
                "$_ENG_INIT" "$_ENG_MAX" "$_ENG_MIN"
            printf '          engLife="50" defaultEnvId="QS"/>\n'
            printf '  <engine id="rwURLEng" class="oracle.reports.urlengine.URLEngineImpl"\n'
            printf '          maxEngine="1" minEngine="0" engLife="50"/>\n'
            printf '\n'
            printf '  <!-- Environment QS: variables passed to each report engine process -->\n'
            printf '  <environment id="QS">\n'
            printf '    <envVariable name="REPORTS_PATH"        value="%s"/>\n' "$REPORTS_PATH"
            printf '    <envVariable name="REPORTS_TMP"         value="%s"/>\n' "$REPORTS_TMP"
            printf '    <envVariable name="NLS_LANG"            value="%s"/>\n' "$_NLS"
            [ -n "$_tns_line" ] && printf '%s\n' "$_tns_line"
            # -DORBWaitForResponseTimeout is REQUIRED as soon as REPORTS_JVM_OPTIONS
            # is set: oracle.reports.utility.Utility.getOrbProperties (Reports QPR
            # 39600348) reads the timeout only from this variable and puts null
            # into Properties when it is missing -> engine NPE REP-50125 every
            # minute, getserverinfo "The server is initializing" forever
            # (confirmed 2026-10-15; unset variable -> default 999999999)
            printf '    <envVariable name="REPORTS_JVM_OPTIONS" value="-Djobid=random -DORBWaitForResponseTimeout=999999999"/>\n'
            printf '  </environment>\n'
            printf '\n'
            printf '  <!-- Security: JAZN-based (WebLogic security realm) -->\n'
            printf '  <security id="rwJaznSec" class="oracle.reports.server.RWJAZNSecurity"/>\n'
            printf '\n'
            printf '  <!-- Destination plugins -->\n'
            printf '  <destination destype="ftp"    class="oracle.reports.plugin.destination.ftp.DesFTP"/>\n'
            printf '  <destination destype="WebDav" class="oracle.reports.plugin.destination.webdav.DesWebDAV"/>\n'
            printf '\n'
            if $SEC_LDAP; then
                printf '  <!-- securityId: users/roles checked against the JSE identity store\n'
                printf '       (jps-config-jse.xml -> WebLogic embedded LDAP, 13- step 4c) -->\n'
            else
                printf '  <!-- no securityId: the JSE identity store is XML (system-jazn-data.xml),\n'
                printf '       WebLogic users would fail with REP-50171 (REPORTS_SECURITY=ldap secures it) -->\n'
            fi
            printf '  <!-- (causes engine startup errors with JAZN security) -->\n'
            if $SEC_LDAP; then
                printf '  <job jobType="report" engineId="rwEng" securityId="rwJaznSec" retry="3"/>\n'
            else
                printf '  <job jobType="report" engineId="rwEng" retry="3"/>\n'
            fi
            printf '  <job jobType="rwurl"  engineId="rwURLEng"/>\n'
            printf '\n'
            printf '  <notification id="mailNotify" class="oracle.reports.server.MailNotify">\n'
            printf '    <property name="succnotefile" value="succnote.txt"/>\n'
            printf '    <property name="failnotefile" value="failnote.txt"/>\n'
            printf '  </notification>\n'
            printf '\n'
            printf '  <!-- jobStatusRepository: uncomment to store job history in Oracle DB\n'
            printf '  <jobStatusRepository class="oracle.reports.server.JobRepositoryDB">\n'
            printf '    <property name="dbuser"     value="..."/>\n'
            printf '    <property name="dbpassword" value="csf:..."/>\n'
            printf '    <property name="dbconn"     value="..."/>\n'
            printf '  </jobStatusRepository>\n'
            printf '  -->\n'
            printf '\n'
            printf '  <connection maxConnect="%s" idleTimeOut="15"/>\n' "$_MAX_CONN"
            printf '  <queue maxQueueSize="%s"/>\n'                       "$_MAX_QUEUE"
            printf '\n'
            # <read> is a single element (rwserverconf.xsd); several directories
            # are separated by ";" - also on Linux. REPORTS_PATH uses ":" - as
            # "dir1:dir2" in <read> every report fails with REP-56132; two <read>
            # elements: only the last counts; subdirectories are not included
            # (test series 2026-10-16, 80-FMW-Architecture/report_server_image_handling.md)
            printf '  <!-- folderAccess: read = report source dirs (";"-separated, no subdirs), write = temp output dir -->\n'
            printf '  <folderAccess>\n'
            printf '    <read>%s</read>\n'  "${REPORTS_PATH//:/;}"
            printf '    <write>%s</write>\n' "$REPORTS_TMP"
            printf '  </folderAccess>\n'
            printf '\n'
            # encrypted="no": the Reports server encrypts it at the next start
            printf '  <!-- Reports server administrator (not a WebLogic user), from reports_admin_sec.conf.des3 -->\n'
            if [ -n "$_RADM_PWD" ]; then
                printf '  <identifier encrypted="no">%s/%s</identifier>\n' "$_RADM_USER" "$_RADM_PWD"
            else
                printf '  <!-- <identifier encrypted="no">rep_admin/PASSWORD</identifier>  (reports_admin_sec.conf.des3 missing) -->\n'
            fi
            printf '\n'
            printf '  <proxyInfo>\n'
            printf '    <proxyServers>\n'
            printf '      <proxyServer name="$$Self.proxyHost$$" port="$$Self.proxyPort$$" protocol="all"/>\n'
            printf '    </proxyServers>\n'
            printf '    <bypassProxy>\n'
            printf '      <domain>$$Self.proxyByPass$$</domain>\n'
            printf '    </bypassProxy>\n'
            printf '  </proxyInfo>\n'
            printf '\n'
            printf '  <pluginParam name="mailServer" value="%%MAILSERVER_NAME%%"/>\n'
            printf '</server>\n'
        } > "$_RWSERVER"
        chmod 640 "$_RWSERVER"

        ok "rwserver.conf written: $_inst (engines: init=$_ENG_INIT max=$_ENG_MAX min=$_ENG_MIN)"
    else
        info "Dry-run – would write rwserver.conf for $_inst:"
        info "  engines: init=$_ENG_INIT  max=$_ENG_MAX  min=$_ENG_MIN"
        info "  connect: maxConnect=$_MAX_CONN  maxQueue=$_MAX_QUEUE"
        info "  REPORTS_PATH=$REPORTS_PATH  REPORTS_TMP=$REPORTS_TMP"
    fi
done
unset _inst _RWSERVER _ENG_INIT _ENG_MAX _ENG_MIN _MAX_CONN _MAX_QUEUE _NLS _tns_line

# =============================================================================
# 6. reports.sh – NLS_LANG + font environment variables
# =============================================================================

section "reports.sh"

_REPORTS_SH="$DOMAIN_HOME/reports/bin/reports.sh"
printf "  %-26s %s\n" "File:" "$_REPORTS_SH" | tee -a "${LOG_FILE:-/dev/null}"

if [ ! -f "$_REPORTS_SH" ]; then
    warn "reports.sh not found: $_REPORTS_SH"
    info "  Verify domain creation completed (08-oracle_setup_domain.sh)"
elif grep -q 'IHateWeblogic Settings' "$_REPORTS_SH" 2>/dev/null; then
    ok "reports.sh: IHateWeblogic block already present"
    # REPORTS_PATH for the Reports server process and the tools (rwrun,
    # rwconverter) - added 2026-10-16, older blocks lack it
    # JVM of the rwserver process (librw.so reads REPORTS_JVM_OPTIONS, default
    # -Xmx256M): process reaper fix (first authentication waited ~4 min) +
    # ORB connect timeout 5 s instead of 60 s (engine crash) - 2026-10-16
    if grep -q 'processReaperUseDefaultStackSize' "$_REPORTS_SH"; then
        ok "reports.sh: REPORTS_JVM_OPTIONS (reaper + ORB timeout) present"
    elif $APPLY; then
        cp "$_REPORTS_SH" "${_REPORTS_SH}.bak_$(date +%Y%m%d_%H%M%S)"
        sed -i '/^REPORTS_ENHANCED_FONTHANDLING=YES; export REPORTS_ENHANCED_FONTHANDLING/a REPORTS_JVM_OPTIONS="-Xmx256M -Djdk.lang.processReaperUseDefaultStackSize=true -DORBWaitForResponseTimeout=999999999 -Dcom.sun.corba.ee.transport.ORBTCPConnectTimeouts=250:5000:100:1000"; export REPORTS_JVM_OPTIONS' "$_REPORTS_SH"
        ok "reports.sh: REPORTS_JVM_OPTIONS added (reaper + ORB timeout)"
    else
        info "Dry-run – would add REPORTS_JVM_OPTIONS (reaper + ORB timeout) to reports.sh"
    fi
    if grep -qF "REPORTS_PATH=\${REPORTS_PATH}:${REPORTS_PATH};" "$_REPORTS_SH"; then
        ok "reports.sh: REPORTS_PATH line present"
    elif $APPLY; then
        cp "$_REPORTS_SH" "${_REPORTS_SH}.bak_$(date +%Y%m%d_%H%M%S)"
        sed -i "/^REPORTS_ENHANCED_FONTHANDLING=YES; export REPORTS_ENHANCED_FONTHANDLING/a REPORTS_PATH=\${REPORTS_PATH}:${REPORTS_PATH}; export REPORTS_PATH" "$_REPORTS_SH"
        ok "reports.sh: REPORTS_PATH line added ($REPORTS_PATH)"
    else
        info "Dry-run – would add REPORTS_PATH=\${REPORTS_PATH}:$REPORTS_PATH to reports.sh"
    fi
else
    warn "reports.sh: NLS_LANG/font block not yet added"
    if $APPLY; then
        cp "$_REPORTS_SH" "${_REPORTS_SH}.bak_$(date +%Y%m%d_%H%M%S)"
        {
            printf '\n'
            printf '# ── IHateWeblogic Settings ──────────────────────────────────────────────────\n'
            printf 'export NLS_LANG=%s\n' "${NLS_LANG:-GERMAN_GERMANY.AL32UTF8}"
            printf '\n'
            printf '# Font configuration (must match rwserver.conf envVariable entries)\n'
            printf 'REPORTS_FONT_DIRECTORY=${DOMAIN_HOME}/reports/fonts; export REPORTS_FONT_DIRECTORY\n'
            printf 'REPORTS_ENHANCED_FONTHANDLING=YES; export REPORTS_ENHANCED_FONTHANDLING\n'
            printf 'REPORTS_PATH=${REPORTS_PATH}:%s; export REPORTS_PATH\n' "$REPORTS_PATH"
            printf '# rwserver JVM: process reaper fix + ORB connect timeout (80-FMW-Architecture/reports_user_local_ldap.md)\n'
            printf 'REPORTS_JVM_OPTIONS="-Xmx256M -Djdk.lang.processReaperUseDefaultStackSize=true -DORBWaitForResponseTimeout=999999999 -Dcom.sun.corba.ee.transport.ORBTCPConnectTimeouts=250:5000:100:1000"; export REPORTS_JVM_OPTIONS\n'
            printf '# ────────────────────────────────────────────────────────────────────────────\n'
        } >> "$_REPORTS_SH"
        ok "reports.sh updated with NLS_LANG and font variables"
    else
        info "Dry-run – would append NLS_LANG + REPORTS_FONT_DIRECTORY to reports.sh"
    fi
fi
unset _REPORTS_SH

# =============================================================================
# 6b. setUserOverrides.sh - ORB connect timeout of WLS_REPORTS
#     The rwservlet keeps the CORBA reference of the Reports server; after a
#     restart of the Reports server (new port) the ORB retries the dead port
#     60 s (default ORBTCPConnectTimeouts 250:60000:100:5000) - 5 s with this.
# =============================================================================

section "setUserOverrides.sh (WLS_REPORTS ORB timeout)"

_UO="$DOMAIN_HOME/bin/setUserOverrides.sh"
_ORB="-Dcom.sun.corba.ee.transport.ORBTCPConnectTimeouts=250:5000:100:1000"
_MS="${WLS_MANAGED_SERVER:-WLS_REPORTS}"
if [ -f "$_UO" ] && grep -q 'ORBTCPConnectTimeouts' "$_UO"; then
    ok "setUserOverrides.sh: ORB connect timeout present"
elif ! $APPLY; then
    info "Dry-run – would add $_ORB for $_MS to $_UO"
else
    [ -f "$_UO" ] && cp -p "$_UO" "${_UO}.bak_$(date +%Y%m%d_%H%M%S)"
    if [ -f "$_UO" ] && grep -q "^if \[ \"\${SERVER_NAME}\" = \"${_MS}\" \]; then" "$_UO"; then
        sed -i "/^if \[ \"\${SERVER_NAME}\" = \"${_MS}\" \]; then/a \    export EXTRA_JAVA_PROPERTIES=\"\${EXTRA_JAVA_PROPERTIES} ${_ORB}\"" "$_UO"
    else
        {
            printf '\n# rwservlet ORB connect timeout (13-oracle_setup_reports.sh)\n'
            printf 'if [ "${SERVER_NAME}" = "%s" ]; then\n' "$_MS"
            printf '    export EXTRA_JAVA_PROPERTIES="${EXTRA_JAVA_PROPERTIES} %s"\n' "$_ORB"
            printf 'fi\n'
        } >> "$_UO"
        chmod 750 "$_UO"
    fi
    grep -q 'ORBTCPConnectTimeouts' "$_UO" \
        && ok "setUserOverrides.sh: $_ORB for $_MS added" \
        || fail "setUserOverrides.sh: ORB timeout not written - check $_UO"
fi
unset _UO _ORB _MS

# =============================================================================
# 7. Verification
# =============================================================================

section "Verification – Component Directories"

_check_dir() {
    local label="$1" dir="$2"
    if [ -d "$dir" ]; then
        ok "$(printf "  %-10s %s" "$label" "$dir")"
    else
        warn "$(printf "  %-10s %s  (missing)" "$label" "$dir")"
    fi
}

_check_dir "tools:" "$_TOOLS_CONF_BASE/$REPORTS_TOOLS_INSTANCE"
for _inst in $REPORTS_SERVER_INSTANCES; do
    _check_dir "server:" "$_REPSERV_CONF_BASE/$_inst"
done
unset _inst

section "Verification – Configuration Files"

_check_file() {
    local label="$1" file="$2"
    if [ -f "$file" ]; then
        ok "$(printf "  %-18s %s" "$label" "$file")"
    else
        warn "$(printf "  %-18s %s  (not yet created)" "$label" "$file")"
    fi
}

if [ -n "$_REPORTS_APP_DIR" ]; then
    _check_file "rwservlet.prop:" "$_REPORTS_APP_DIR/configuration/rwservlet.properties"
    _check_file "rwnetwork(wls):" "$_REPORTS_APP_DIR/configuration/rwnetwork.conf"
fi
_check_file "rwnetwork(tools):" \
    "$_TOOLS_CONF_BASE/$REPORTS_TOOLS_INSTANCE/rwnetwork.conf"
for _inst in $REPORTS_SERVER_INSTANCES; do
    _check_file "rwserver[$_inst]:" "$_REPSERV_CONF_BASE/$_inst/rwserver.conf"
    _check_file "rwnetwork[$_inst]:" "$_REPSERV_CONF_BASE/$_inst/rwnetwork.conf"
done
unset _inst

# =============================================================================
# 8. Next Steps
# =============================================================================

section "Next Steps"
info "Start sequence (after 13-root_reports_fix.sh and font setup):"
info "  1.  \$DOMAIN_HOME/bin/startWebLogic.sh &"
info "  2.  \$DOMAIN_HOME/bin/startManagedWebLogic.sh $WLS_MANAGED_SERVER t3://localhost:${WLS_ADMIN_PORT:-7001} &"
info "  3.  \$DOMAIN_HOME/bin/startComponent.sh $REPORTS_TOOLS_INSTANCE"
_step=4
for _inst in $REPORTS_SERVER_INSTANCES; do
    info "  ${_step}.  \$DOMAIN_HOME/bin/startComponent.sh $_inst"
    _step=$(( _step + 1 ))
done
unset _inst _step
info ""
info "Verify (Nginx proxy port or WLS_REPORTS port):"
info "  curl -s \"http://localhost:${WLS_REPORTS_PORT:-9002}/reports/rwservlet/getserverinfo?server=${_FIRST_SERVER_INST}&statusformat=XML\""
info ""
info "Fonts, uifont.ali, cgicmd.dat (after 14- and the first start of WLS_REPORTS):"
info "  09-Install/14b-oracle_reports_fonts.sh --apply"

unset _REPORTS_APP_DIR _REPORTS_APP_BASE _FIRST_SERVER_INST
unset _TOOLS_CONF_BASE _REPSERV_CONF_BASE

# =============================================================================
print_summary
exit "$EXIT_CODE"
