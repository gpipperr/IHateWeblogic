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
#                 ORB connect timeout, ORB on 127.0.0.1) and setUserOverrides.sh (ORB connect
#                 timeout of WLS_REPORTS)
#            Background: 80-FMW-Architecture/reports_user_local_ldap.md
# Call     : ./09-Install/13-oracle_setup_reports.sh
#            ./09-Install/13-oracle_setup_reports.sh --apply
#            ./09-Install/13-oracle_setup_reports.sh --apply --skip-wlst
#            ./09-Install/13-oracle_setup_reports.sh --remove-server <name> [--apply]
# Options  : --apply       Write all configuration files
#            --skip-wlst   Skip WLST instance creation (AdminServer not running)
#            --remove-server NAME   ONLY remove the Reports server instance NAME
#                          (WLST deleteReportsServerInstance, AdminServer running,
#                          server stopped, NAME not in REPORTS_SERVER_INSTANCES);
#                          backup of config.xml + component directories first,
#                          lists the files that still name it - nothing else runs
#            --help        Show usage
# Requires : environment.conf with Reports variables (detect_env_conf.sh --apply)
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

ENV_CONF="$ROOT_DIR/environment.conf"
check_env_conf "$ENV_CONF" || exit 2
# shellcheck source=../environment.conf
source "$ROOT_DIR/environment.conf"

# =============================================================================
# Arguments
# =============================================================================

APPLY=false
SKIP_WLST=false

REMOVE_SERVER=""
while [ $# -gt 0 ]; do
    _arg="$1"
    case "$_arg" in
        --apply)      APPLY=true ;;
        --skip-wlst)  SKIP_WLST=true ;;
        --remove-server)
            REMOVE_SERVER="${2:-}"; shift
            [[ "$REMOVE_SERVER" =~ ^[A-Za-z0-9_.-]+$ ]] || { printf "\033[31mERROR\033[0m --remove-server <name>\n" >&2; exit 1; } ;;
        --help|-h)
            printf "Usage: %s [--apply] [--skip-wlst] | --remove-server <name> [--apply]\n\n" "$(basename "$0")"
            printf "  %-22s %s\n" "--apply"      "Write all configuration files"
            printf "  %-22s %s\n" "--skip-wlst"  "Skip WLST instance creation (AdminServer not running)"
            printf "  %-22s %s\n" "--remove-server NAME" "only remove the Reports server instance NAME (backup first)"
            printf "\nWithout --apply: dry-run, no files changed.\n"
            exit 0 ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$_arg" >&2; exit 1 ;;
    esac
    shift
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
    [ -n "$REMOVE_SERVER" ] && printf "# Mode    : --remove-server %s\n" "$REMOVE_SERVER"
    printf "# User    : %s\n" "$(id -un)"
    printf "# Conf    : %s\n" "$(readlink -f "$ENV_CONF" 2>/dev/null || printf '%s' "$ENV_CONF")"
} > "$LOG_FILE"

# =============================================================================
# Header
# =============================================================================

# Server list: REPORTS_SERVER_INSTANCES (detect_env_conf.sh) or the array
# REPORTS_SERVER_NAMES of the interview (same list, two names until 2026-11-04)
if [ -z "${REPORTS_SERVER_INSTANCES:-}" ]; then
    if [ "$(declare -p REPORTS_SERVER_NAMES 2>/dev/null | cut -c1-10)" = "declare -a" ]; then
        REPORTS_SERVER_INSTANCES="${REPORTS_SERVER_NAMES[*]}"
    else
        REPORTS_SERVER_INSTANCES="${REPORTS_SERVER_NAMES:-${REPORTS_SERVER_NAME:-}}"
    fi
fi
# Customer overlay (import): per server <environment> values
CC_DIR="${CUSTOMER_CONF_DIR:-}"

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
$_prereq_fail && info "  Runtime parameters are added by: 00-Setup/detect_env_conf.sh --apply (after 08-)"
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

# =============================================================================
# --remove-server NAME - remove one Reports server instance, nothing else
#   order: 1. remove NAME from REPORTS_SERVER_INSTANCES (and REPORTS_SERVER_NAME)
#          2. 13- / 14b- --apply (new servers, rwservlet.properties, cgicmd.dat)
#          3. stop NAME   4. this step
# =============================================================================
if [ -n "$REMOVE_SERVER" ]; then
    section "Remove Reports server instance: $REMOVE_SERVER"
    _rn="$REMOVE_SERVER"; _blocked=0
    _cfgxml="$DOMAIN_HOME/config/config.xml"
    _dirs=()
    for _d in "$DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent/$_rn" \
              "$DOMAIN_HOME/system_components/ReportsServerComponent/$_rn" \
              "$DOMAIN_HOME/servers/$_rn"; do
        [ -d "$_d" ] && _dirs+=("$_d")
    done
    printList "config.xml" 26 "$_cfgxml"
    if awk -v n="$_rn" '/<system-component>/{s=1;nm="";t=""} s&&/<name>/{nm=$0;gsub(/.*<name>|<\/name>.*/,"",nm)} s&&/<component-type>/{t=$0;gsub(/.*<component-type>|<\/component-type>.*/,"",t)} /<\/system-component>/{if(s&&nm==n&&t=="ReportsServerComponent")f=1;s=0} END{exit !f}' "$_cfgxml"; then
        ok "$(printf "  %-24s %s" "system component" "$_rn (ReportsServerComponent) found in config.xml")"
    else
        warn "$(printf "  %-24s %s" "system component" "$_rn not in config.xml (already removed?)")"
        [ ${#_dirs[@]} -eq 0 ] && { info "nothing to remove"; print_summary; exit "$EXIT_CODE"; }
    fi
    for _d in "${_dirs[@]}"; do info "$(printf "  %-24s %s (%s)" "directory" "$_d" "$(du -sh "$_d" 2>/dev/null | cut -f1)")"; done
    # still in the configuration of the library? 13- would create it again
    case " ${REPORTS_SERVER_INSTANCES:-} " in
        *" $_rn "*) fail "$_rn is still in REPORTS_SERVER_INSTANCES ($REPORTS_SERVER_INSTANCES) - remove it in $(readlink -f "$ENV_CONF") first"; _blocked=1 ;;
        *) ok "$(printf "  %-24s %s" "REPORTS_SERVER_INSTANCES" "${REPORTS_SERVER_INSTANCES:-<empty>} (without $_rn)")" ;;
    esac
    [ "${REPORTS_SERVER_NAME:-}" = "$_rn" ] && warn "REPORTS_SERVER_NAME=$_rn (default server of 15- / status tools) - set it to one of: ${REPORTS_SERVER_INSTANCES:-?}"
    # running?
    _rp="$(ps -eo pid,args 2>/dev/null | grep -E "rwserver[^ ]* .*server=${_rn}( |$)" | grep -v grep | awk '{print $1}' | paste -sd' ')"
    if [ -n "$_rp" ]; then
        fail "Reports server $_rn is running (pid $_rp) - stop it first: 01-Run/startStop.sh stop $_rn --apply (or stopComponent('$_rn') in WLST)"
        _blocked=1
    else
        ok "$(printf "  %-24s %s" "process" "$_rn not running")"
    fi
    _adm_port="${WLS_ADMIN_PORT:-7001}"
    if timeout 3 bash -c "echo >/dev/tcp/localhost/${_adm_port}" 2>/dev/null; then
        ok "$(printf "  %-24s %s" "AdminServer" "reachable on port $_adm_port")"
    else
        fail "AdminServer not reachable on port $_adm_port - deleteReportsServerInstance needs it (start it, then re-run)"; _blocked=1
    fi
    # files that still name the server (active files only, no .bak_*)
    section "References to $_rn (must point to another server)"
    _refs="$(timeout 60 grep -rlw -- "$_rn" "$DOMAIN_HOME/config/fmwconfig/servers" "$DOMAIN_HOME/reports/bin" "$DOMAIN_HOME/bin" "$(readlink -f "$ENV_CONF")" 2>/dev/null \
             | grep -vE '\.bak|\.log$|/components/ReportsServerComponent/' )"
    if [ -n "$_refs" ]; then
        while IFS= read -r _f; do
            warn "$(printf "  %s: %s" "$_f" "$(grep -nw -- "$_rn" "$_f" | sed -E 's/((userid|authid|password|pwd)[[:space:]]*=)[^[:space:]&]*/\1***/Ig' | head -3 | cut -c1-120 | paste -sd'|')")"
        done <<< "$_refs"
        info "  rwservlet.properties / cgicmd.dat: 13- / 14b- --apply rewrite them from REPORTS_SERVER_NAME / REPORTS_SERVER_INSTANCES"
    else
        ok "no active file names $_rn"
    fi
    if [ "$_blocked" -ne 0 ]; then
        fail "not removed - solve the FAIL points above"; print_summary; exit "$EXIT_CODE"
    fi
    if ! $APPLY; then
        info "Dry-run - would: backup config.xml + ${#_dirs[@]} directory(ies), WLST deleteReportsServerInstance(instanceName='$_rn'), move left-over directories into the backup"
        print_summary; exit "$EXIT_CODE"
    fi
    # backup
    section "Backup"
    _bk="$ROOT_DIR/07-Maintenance/ConfigBackup/remove_reports_${_rn}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$_bk" && chmod 700 "$_bk"
    cp -p "$_cfgxml" "$_bk/config.xml" && ok "config.xml -> $_bk/config.xml"
    if [ ${#_dirs[@]} -gt 0 ]; then
        tar -czf "$_bk/component_dirs.tgz" "${_dirs[@]}" 2>>"$LOG_FILE" && ok "$(printf "component directories -> %s (%s)" "$_bk/component_dirs.tgz" "$(du -h "$_bk/component_dirs.tgz" | cut -f1)")" \
            || { fail "backup of the component directories failed - nothing removed"; print_summary; exit "$EXIT_CODE"; }
    fi
    # WLST
    section "WLST deleteReportsServerInstance"
    if ! load_weblogic_password; then
        fail "Cannot load WebLogic credentials - run 00-Setup/weblogic_sec.sh --apply"; print_summary; exit "$EXIT_CODE"
    fi
    _wlst_script="$(mktemp --suffix=.py)"
    cat > "$_wlst_script" <<'WLST_DEL'
import os, sys
inst = os.environ.get('_IHW_DEL_INST', '')
try:
    connect(os.environ.get('_IHW_WL_USER', ''), os.environ.get('_IHW_WL_PASS', ''), os.environ.get('_IHW_ADM_URL', 't3://localhost:7001'))
    cd('/')
    before = [str(x) for x in ls('SystemComponents', returnMap='true')]
    print('IHW:INFO:system components before: ' + ', '.join(before))
    if inst not in before:
        print('IHW:WARN:' + inst + ' is no system component of the domain - nothing to delete in WLST')
    else:
        deleteReportsServerInstance(instanceName=inst)
        cd('/')
        after = [str(x) for x in ls('SystemComponents', returnMap='true')]
        print('IHW:INFO:system components after: ' + ', '.join(after))
        if inst in after:
            print('IHW:FAIL:' + inst + ' is still a system component after deleteReportsServerInstance')
            sys.exit(1)
        print('IHW:OK:Deleted ReportsServer instance: ' + inst)
    disconnect()
except Exception, e:
    print('IHW:FAIL:WLST error: ' + str(e))
    sys.exit(1)
WLST_DEL
    _wlst_out="$(_IHW_WL_USER="$WL_USER" _IHW_WL_PASS="$INTERNAL_WL_PWD" _IHW_ADM_URL="t3://localhost:${_adm_port}" _IHW_DEL_INST="$_rn" \
                 "$WLST_SH" "$_wlst_script" 2>&1)"; _wrc=$?
    unset INTERNAL_WL_PWD
    rm -f "$_wlst_script"
    { printf '# --- WLST output (deleteReportsServerInstance %s, rc %s) ---\n' "$_rn" "$_wrc"
      printf '%s\n' "$_wlst_out" | grep -viE 'password|passwd'
      printf '# --- end WLST output ---\n'; } >> "$LOG_FILE"
    _wfail=0
    while IFS= read -r _line; do
        case "$_line" in
            IHW:OK:*)   ok   "$(printf '%s' "$_line" | cut -d: -f3-)" ;;
            IHW:INFO:*) info "$(printf '%s' "$_line" | cut -d: -f3-)" ;;
            IHW:WARN:*) warn "$(printf '%s' "$_line" | cut -d: -f3-)" ;;
            IHW:FAIL:*) fail "$(printf '%s' "$_line" | cut -d: -f3-)"; _wfail=1 ;;
        esac
    done <<< "$_wlst_out"
    if [ "$_wfail" -ne 0 ] || [ "$_wrc" -ne 0 ]; then
        fail "WLST rc $_wrc - full WLST output in $LOG_FILE; backup: $_bk (restore config.xml only with the domain stopped)"
        print_summary; exit "$EXIT_CODE"
    fi
    # left-over directories (WLST removes the component config; logs / runtime dirs may stay)
    section "Left-over directories"
    for _d in "${_dirs[@]}"; do
        if [ -d "$_d" ]; then
            _t="$_bk/leftover$(printf '%s' "$_d" | tr '/' '_')"
            mv "$_d" "$_t" && ok "$(printf "moved %s -> %s" "$_d" "$_t")" || warn "could not move $_d"
        else
            ok "$(printf "removed by WLST: %s" "$_d")"
        fi
    done
    grep -q "<name>${_rn}</name>" "$_cfgxml" && warn "config.xml still contains <name>$_rn</name> - check $_cfgxml" || ok "config.xml: $_rn gone"
    info "Backup: $_bk  |  log: $LOG_FILE"
    _drift="$(autostart_drift "$DOMAIN_HOME")"
    if [ -n "$_drift" ]; then
        warn "Autostart scripts still list the removed server ($_drift)"
        info "  re-render: ./09-Install/30-configure_autostart.sh --apply"
    fi
    unset _drift
    info "Next: 09-Install/30-configure_autostart.sh --apply (when autostart is set up), 01-Run/rwserver_status.sh, 70-Customer-Projects/tools/bash/status.sh -q"
    print_summary; exit "$EXIT_CODE"
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
    skip_tools = os.environ.get('_IHW_SKIP_TOOLS', '0') == '1'
    try:
        if skip_tools:
            raise Exception('already exists')
        createReportsToolsInstance(instanceName=tools_inst, machine=machine)
        print('IHW:OK:Created ReportsTools instance: ' + tools_inst)
    except Exception as ex:
        msg = str(ex).lower()
        if 'already exists' in msg or 'duplicate' in msg:
            # skipped: the shell side already printed OK for it - no second line
            if not skip_tools:
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
        _PORT_PENDING=true
    fi
}
_PORT_PENDING=false

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

# Multicast discovery prerequisites (2026-10-15) - AFTER the port update:
# WLST creates a new server with Oracle's default port 14021, the scan before
# the update reported that as FAIL although 13- fixed it (customer 2026-11-05).
# Checks: route, MULTICAST flag,
# firewall UDP port, send/receive self-test - done by
# 02-Checks/reports_network_scan.sh (also scans the network for other Reports
# servers when called without --no-scan). Without multicast reception the
# Reports server stops at once with REP-50600 and the Node Manager restarts it
# in a loop (customer 2026-10-15).
_scan="$ROOT_DIR/02-Checks/reports_network_scan.sh"
if [ -x "$_scan" ]; then
    info "Multicast checks: 02-Checks/reports_network_scan.sh --no-scan --port ${REPORTS_BROADCAST_PORT}"
    bash "$_scan" --no-scan --port "${REPORTS_BROADCAST_PORT}" 2>&1 \
        | sed -n -e '/=== Discovery Configuration/,/=== Multicast Prerequisites/{/FAIL\|WARN\|Fix:/p}' \
                 -e '/=== Multicast Prerequisites/,/=== Summary/p' | grep -vE '=== Summary|^-{20,}' \
        | tee -a "$LOG_FILE"
    _scan_rc=${PIPESTATUS[0]}
    case "$_scan_rc" in
        0) ok   "Multicast prerequisites OK" ;;
        1) warn "Multicast prerequisites: warnings – see above" ;;
        *) if $_PORT_PENDING; then
               # dry run: the port mismatch the scan sees is fixed by --apply above
               warn "Multicast check sees different ports – --apply aligns them (see above); re-check after --apply"
           else
               fail "Multicast prerequisites failed – the Reports server would stop with REP-50600"
           fi ;;
    esac
    info "  Other Reports servers in the network: 02-Checks/reports_network_scan.sh (port scan)"
    unset _scan_rc
else
    warn "02-Checks/reports_network_scan.sh not found – multicast checks skipped"
fi
unset _scan _PORT_PENDING

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
    info "  never webcommandaccess=L2 - opens every web command without login (doc 81)"
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
    elif $SKIP_WLST || ! timeout 3 bash -c "echo >/dev/tcp/localhost/${WLS_ADMIN_PORT:-7001}" 2>/dev/null; then
        if $SKIP_WLST; then
            warn "--skip-wlst: credential + LDAP bind not checked - re-run without --skip-wlst"
        else
            warn "AdminServer not reachable on port ${WLS_ADMIN_PORT:-7001} - credential + LDAP bind not checked"
        fi
        # an earlier run already switched the identity store: keep the secured
        # server - else this run would write rwserver.conf WITHOUT securityId
        # (silently unsecured, until 2026-11-03)
        if grep -q 'serviceInstanceRef ref="idstore.ldap.embedded"' "$_JSE"; then
            info "  jps-config-jse.xml already uses idstore.ldap.embedded - securityId is kept"
            _cred_ok=true
        else
            warn "  rwserver.conf is written WITHOUT securityId (unsecured) until a run with the AdminServer"
        fi
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
                # FAIL, not WARN: until the AdminServer restart every managed
                # server that STARTS gets "LDAPException: error result (49);
                # Invalid credentials" while deploying its roles and goes to
                # FAILED (customer 2026-11-03: WLS_FORMS started after 13-)
                IHW:RESTART:*) fail "$(printf '%s' "$_line" | cut -d: -f3-)"
                               fail "  RESTART THE ADMINSERVER NOW - until then NO managed server starts"
                               info "  (a start fails with 'LDAPException: error result (49); Invalid credentials')"
                               info "    01-Run/startStop.sh stop-all --apply; 01-Run/startStop.sh start-all --apply"
                               info "    09-Install/13-oracle_setup_reports.sh --apply      (second run: credential + securityId)"
                               warn "  rwserver.conf of this run has NO securityId - the re-run writes it" ;;
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
_ENG_LIFE="${REPORTS_ENGINE_LIFE:-50}"
_ENG_IDLE="${REPORTS_ENGINE_MAX_IDLE:-}"        # empty = Oracle default 30 min
_ENG_JVM="${REPORTS_ENGINE_JVM_OPTIONS:-}"      # empty = engines with -Xmx256M
_ENG_ERT="${REPORTS_ENGINE_RESPONSE_TIMEOUT-360}" # minutes (default 6 h safety net), empty = no timeout (Oracle default)
_MAX_CONN="${REPORTS_MAX_CONNECT:-300}"
_MAX_QUEUE="${REPORTS_MAX_QUEUE:-4000}"
_NLS="${NLS_LANG:-GERMAN_GERMANY.AL32UTF8}"
case "$_ENG_JVM" in
    *[\"\&\<\>]*)
        fail "REPORTS_ENGINE_JVM_OPTIONS contains \" & < or > - not usable in an XML attribute, ignored"
        _ENG_JVM="" ;;
esac
# Engine jvmOptions REPLACE the REPORTS_JVM_OPTIONS the engines would inherit
# from the server (reports.sh) - without ORBServerHost there the engine ORB
# listens on 0.0.0.0 (customer 2026-11-10), and like in reports.sh the ORB
# timeout belongs to it (REP-50125 on the server without it). Always added here.
if [ -n "$_ENG_JVM" ]; then
    printf '%s' "$_ENG_JVM" | grep -q 'ORBWaitForResponseTimeout=' \
        || _ENG_JVM="${_ENG_JVM} -DORBWaitForResponseTimeout=999999999"
    printf '%s' "$_ENG_JVM" | grep -q 'ORBServerHost=' \
        || _ENG_JVM="${_ENG_JVM} -Dcom.sun.corba.ee.ORBServerHost=127.0.0.1"
fi
_eng_extra=""
[ -n "$_ENG_IDLE" ] && _eng_extra="${_eng_extra} maxIdle=\"${_ENG_IDLE}\""
[ -n "$_ENG_JVM" ]  && _eng_extra="${_eng_extra} jvmOptions=\"${_ENG_JVM}\""
[ -n "$_ENG_ERT" ]  && _eng_extra="${_eng_extra} engineResponseTimeOut=\"${_ENG_ERT}\""
info "$(printf "Report engine: init=%s min=%s max=%s engLife=%s maxIdle=%s engineResponseTimeOut=%s jvmOptions=%s" \
    "$_ENG_INIT" "$_ENG_MIN" "$_ENG_MAX" "$_ENG_LIFE" "${_ENG_IDLE:-(default 30)}" "${_ENG_ERT:-(none)}" "${_ENG_JVM:-(default)}")"

# Reports server administrator (<identifier>, not a WebLogic user) from
# reports_admin_sec.conf.des3 (asked by 01-setup-interview.sh). Missing ->
# with --apply a random password is generated and stored there.
_RADM_SEC="$ROOT_DIR/reports_admin_sec.conf.des3"
_RADM_USER="${REPORTS_ADMIN_USER:-repadmin}"
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

# Never an empty <identifier>: the server does not start (REP-50125 NPE in
# ServerConfig.open, restart loop); missing = no admin for web commands /
# stopserver (doc 81 tests A/B, 2026-10-23)
if $APPLY && [ -z "$_RADM_PWD" ]; then
    fail "No Reports server admin password - rwserver.conf gets no <identifier> (web commands / stopserver impossible on an unsecured server)"
fi

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

        # Customer overlay of this server (CUSTOMER_CONF_DIR/reports/<inst>.env):
        # KEY=VALUE lines override the <envVariable> values below, other keys
        # are added to the environment (e.g. NLS_LANG per server)
        declare -A _CC_ENV=()
        _cc_env="${CC_DIR:+$CC_DIR/reports/${_inst}.env}"
        if [ -n "$_cc_env" ] && [ -f "$_cc_env" ]; then
            while IFS='=' read -r _k _v; do
                case "$_k" in ''|\#*) continue ;; esac
                _CC_ENV[$_k]="$_v"
            done < "$_cc_env"
            info "  + customer overlay $_cc_env (${#_CC_ENV[@]} value(s))"
        fi
        _envvar() {   # name default - one <envVariable> line, overlay value wins
            local v="$2"
            [ -n "${_CC_ENV[$1]+x}" ] && { v="${_CC_ENV[$1]}"; unset "_CC_ENV[$1]"; }
            printf '    <envVariable name="%s"%*s value="%s"/>\n' "$1" $(( 19 - ${#1} )) "" "$v"
        }

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
            printf '          engLife="%s"%s defaultEnvId="QS"/>\n' "$_ENG_LIFE" "$_eng_extra"
            printf '  <engine id="rwURLEng" class="oracle.reports.urlengine.URLEngineImpl"\n'
            printf '          maxEngine="1" minEngine="0" engLife="50"/>\n'
            printf '\n'
            printf '  <!-- Environment QS: variables passed to each report engine process -->\n'
            printf '  <environment id="QS">\n'
            _envvar REPORTS_PATH "$REPORTS_PATH"
            _envvar REPORTS_TMP  "$REPORTS_TMP"
            _envvar NLS_LANG     "$_NLS"
            [ -n "$_tns_line" ] && [ -z "${_CC_ENV[TNS_ADMIN]+x}" ] && printf '%s\n' "$_tns_line"
            # remaining customer values of this server (not REPORTS_JVM_OPTIONS - fixed below)
            for _k in "${!_CC_ENV[@]}"; do
                [ "$_k" = REPORTS_JVM_OPTIONS ] && continue
                _envvar "$_k" "${_CC_ENV[$_k]}"
            done
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
                printf '  <!-- <identifier encrypted="no">repadmin/PASSWORD</identifier>  (reports_admin_sec.conf.des3 missing) -->\n'
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
        unset _CC_ENV _cc_env _k _v

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

# JVM of the rwserver process and - inherited - of the engines (librw.so reads
# REPORTS_JVM_OPTIONS, default -Xmx256M): process reaper fix (first
# authentication waited ~4 min) + ORB connect timeout 5 s instead of 60 s
# (2026-10-16) + ORB (GlassFish CORBA) bound to 127.0.0.1 instead of all
# interfaces (2026-10-23, 80-FMW-Architecture/clone_golden_image.md)
_RWS_JVM_LINE='REPORTS_JVM_OPTIONS="-Xmx256M -Djdk.lang.processReaperUseDefaultStackSize=true -DORBWaitForResponseTimeout=999999999 -Dcom.sun.corba.ee.transport.ORBTCPConnectTimeouts=250:5000:100:1000 -Dcom.sun.corba.ee.ORBServerHost=127.0.0.1"; export REPORTS_JVM_OPTIONS'
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
    if grep -qxF "$_RWS_JVM_LINE" "$_REPORTS_SH"; then
        ok "reports.sh: REPORTS_JVM_OPTIONS (reaper + ORB timeout + ORB on 127.0.0.1) present"
    elif $APPLY; then
        cp "$_REPORTS_SH" "${_REPORTS_SH}.bak_$(date +%Y%m%d_%H%M%S)"
        if grep -q '^REPORTS_JVM_OPTIONS=' "$_REPORTS_SH"; then
            # older block without ORBServerHost (before 2026-10-23) - replace
            _l="$_RWS_JVM_LINE" awk '/^REPORTS_JVM_OPTIONS=/ { print ENVIRON["_l"]; next } { print }' \
                "$_REPORTS_SH" > "${_REPORTS_SH}.tmp" && cat "${_REPORTS_SH}.tmp" > "$_REPORTS_SH" && rm -f "${_REPORTS_SH}.tmp"
        else
            _l="$_RWS_JVM_LINE" awk '{ print } /^REPORTS_ENHANCED_FONTHANDLING=YES; export REPORTS_ENHANCED_FONTHANDLING/ { print ENVIRON["_l"] }' \
                "$_REPORTS_SH" > "${_REPORTS_SH}.tmp" && cat "${_REPORTS_SH}.tmp" > "$_REPORTS_SH" && rm -f "${_REPORTS_SH}.tmp"
        fi
        grep -qxF "$_RWS_JVM_LINE" "$_REPORTS_SH" \
            && ok "reports.sh: REPORTS_JVM_OPTIONS written (reaper + ORB timeout + ORB on 127.0.0.1) – Reports server restart" \
            || fail "reports.sh: REPORTS_JVM_OPTIONS not written – check $_REPORTS_SH"
    else
        info "Dry-run – would write REPORTS_JVM_OPTIONS (reaper + ORB timeout + ORB on 127.0.0.1) to reports.sh"
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
            # one Oracle Net directory (environment.conf) - overrides Oracle's
            # default above (/etc or $DOMAIN_HOME/config/fmwconfig)
            [ -n "${TNS_ADMIN:-}" ] && printf 'TNS_ADMIN=%s; export TNS_ADMIN\n' "$TNS_ADMIN"
            printf '# rwserver JVM: process reaper fix + ORB connect timeout (80-FMW-Architecture/reports_user_local_ldap.md)\n'
            printf '%s\n' "$_RWS_JVM_LINE"
            printf '# ────────────────────────────────────────────────────────────────────────────\n'
        } >> "$_REPORTS_SH"
        ok "reports.sh updated with NLS_LANG and font variables"
    else
        info "Dry-run – would append NLS_LANG + REPORTS_FONT_DIRECTORY to reports.sh"
    fi
fi
# TNS_ADMIN of environment.conf for the Reports server process and the tools
# (rwrun, rwconverter) - Oracle's block above sets it only when it is empty
# (2026-10-23); the engines get it from rwserver.conf (envVariable, step 5)
if [ -f "$_REPORTS_SH" ] && [ -n "${TNS_ADMIN:-}" ] && grep -q 'IHateWeblogic Settings' "$_REPORTS_SH"; then
    if grep -qx "TNS_ADMIN=${TNS_ADMIN}; export TNS_ADMIN" "$_REPORTS_SH"; then
        ok "reports.sh: TNS_ADMIN=$TNS_ADMIN"
    elif $APPLY; then
        cp "$_REPORTS_SH" "${_REPORTS_SH}.bak_$(date +%Y%m%d_%H%M%S)"
        if grep -q '^TNS_ADMIN=' "$_REPORTS_SH"; then
            sed -i "s|^TNS_ADMIN=.*|TNS_ADMIN=${TNS_ADMIN}; export TNS_ADMIN|" "$_REPORTS_SH"
        else
            sed -i "/^REPORTS_ENHANCED_FONTHANDLING=YES; export REPORTS_ENHANCED_FONTHANDLING/a TNS_ADMIN=${TNS_ADMIN}; export TNS_ADMIN" "$_REPORTS_SH"
        fi
        grep -qx "TNS_ADMIN=${TNS_ADMIN}; export TNS_ADMIN" "$_REPORTS_SH" \
            && ok "reports.sh: TNS_ADMIN set ($TNS_ADMIN)" \
            || fail "reports.sh: TNS_ADMIN not written - check $_REPORTS_SH"
    else
        info "Dry-run – would set TNS_ADMIN=$TNS_ADMIN in reports.sh"
    fi
elif [ -z "${TNS_ADMIN:-}" ]; then
    warn "TNS_ADMIN not set in environment.conf – Oracle default (\$DOMAIN_HOME/config/fmwconfig) stays"
fi
unset _REPORTS_SH

# =============================================================================
# 6b. setUserOverrides.sh - ORB connect timeout of WLS_REPORTS
#     The rwservlet keeps the CORBA reference of the Reports server; after a
#     restart of the Reports server (new port) the ORB retries the dead port
#     60 s (default ORBTCPConnectTimeouts 250:60000:100:5000) - 5 s with this.
#     ORBServerHost=127.0.0.1: the rwservlet ORB listens on loopback instead of
#     all interfaces (2026-10-23, 80-FMW-Architecture/clone_golden_image.md).
# =============================================================================

section "setUserOverrides.sh (WLS_REPORTS ORB timeout + 127.0.0.1)"

_UO="$DOMAIN_HOME/bin/setUserOverrides.sh"
_ORB="-Dcom.sun.corba.ee.transport.ORBTCPConnectTimeouts=250:5000:100:1000 -Dcom.sun.corba.ee.ORBServerHost=127.0.0.1"
_MS="${WLS_MANAGED_SERVER:-WLS_REPORTS}"
if [ -f "$_UO" ] && grep -qF -- "$_ORB" "$_UO"; then
    ok "setUserOverrides.sh: ORB connect timeout + ORB on 127.0.0.1 present"
elif ! $APPLY; then
    info "Dry-run – would add $_ORB for $_MS to $_UO"
elif [ -f "$_UO" ] && grep -q 'ORBTCPConnectTimeouts=250:5000:100:1000"' "$_UO"; then
    # older line without ORBServerHost (before 2026-10-23) - extend it
    cp -p "$_UO" "${_UO}.bak_$(date +%Y%m%d_%H%M%S)"
    sed -i 's|-Dcom.sun.corba.ee.transport.ORBTCPConnectTimeouts=250:5000:100:1000"|-Dcom.sun.corba.ee.transport.ORBTCPConnectTimeouts=250:5000:100:1000 -Dcom.sun.corba.ee.ORBServerHost=127.0.0.1"|' "$_UO"
    grep -qF -- "$_ORB" "$_UO" \
        && ok "setUserOverrides.sh: ORBServerHost=127.0.0.1 added for $_MS – server restart" \
        || fail "setUserOverrides.sh: ORBServerHost not written - check $_UO"
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
    grep -qF -- "$_ORB" "$_UO" \
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

# Autostart (30-) renders the system components into its scripts - a server
# created here is not started by start-all / systemd until it is re-rendered
_drift="$(autostart_drift "$DOMAIN_HOME")"
if [ -n "$_drift" ]; then
    section "Autostart"
    if $APPLY; then
        warn "Autostart scripts out of date ($_drift)"
    else
        info "Autostart scripts would be out of date after --apply ($_drift)"
    fi
    info "  re-render: ./09-Install/30-configure_autostart.sh --apply (apply_customer_conf.sh does it)"
fi
unset _drift

section "Next Steps"
# README Phase 6: the files are written while the domain runs and become
# active with the restart after 14- (WLS_REPORTS, Reports server component)
info "Next (09-Install/README.md, Phase 6):"
info "  1. 09-Install/14-oracle_setup_forms.sh --apply"
info "  2. 01-Run/startStop.sh stop-all --apply; 01-Run/startStop.sh start-all --apply"
info "     (start-all also starts the Reports server component(s): $REPORTS_SERVER_INSTANCES)"
info "  3. 01-Run/rwserver_status.sh --auth       (getserverinfo as monUser, engine states)"
info "  4. 09-Install/14b-oracle_reports_fonts.sh --apply   (fonts, uifont.ali, cgicmd.dat)"

unset _REPORTS_APP_DIR _REPORTS_APP_BASE _FIRST_SERVER_INST
unset _TOOLS_CONF_BASE _REPSERV_CONF_BASE

# =============================================================================
print_summary
exit "$EXIT_CODE"
