#!/bin/bash
# =============================================================================
# Script   : 13-oracle_setup_reports.sh
# Purpose  : Phase 7 – Configure Oracle Reports Server system components:
#              1. Create ReportsTools + ReportsServer instances (WLST)
#              2. Set unique broadcasting port in rwnetwork.conf (3 locations)
#              3. Write rwservlet.properties (servlet → server mapping)
#              4. Write rwserver.conf per ReportsServer instance (engine tuning)
#              5. Patch reports.sh (NLS_LANG + font environment)
# Call     : ./09-Install/13-oracle_setup_reports.sh
#            ./09-Install/13-oracle_setup_reports.sh --apply
#            ./09-Install/13-oracle_setup_reports.sh --apply --skip-wlst
# Options  : --apply       Write all configuration files
#            --skip-wlst   Skip WLST instance creation (AdminServer not running)
#            --help        Show usage
# Requires : environment.conf with Reports variables (init_env.sh --apply)
#            weblogic_sec.conf.des3 (for WLST credential loading)
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
    warn "REPORTS_COOKIE_KEY was empty – generated: $REPORTS_COOKIE_KEY"
    info "  Save to environment.conf: REPORTS_COOKIE_KEY=$REPORTS_COOKIE_KEY"
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

    # ReportsTools instance
    try:
        createReportsToolsInstance(instanceName=tools_inst, machine=machine)
        print('IHW:OK:Created ReportsTools instance: ' + tools_inst)
    except Exception as ex:
        msg = str(ex).lower()
        if 'already exists' in msg or 'duplicate' in msg:
            print('IHW:INFO:ReportsTools instance already exists: ' + tools_inst)
        else:
            print('IHW:FAIL:createReportsToolsInstance failed: ' + str(ex))
            sys.exit(1)

    # ReportsServer instances
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

        _wlst_out="$("$WLST_SH" "$_wlst_script" 2>&1)"

        unset _IHW_WL_USER _IHW_WL_PASS INTERNAL_WL_PWD

        while IFS= read -r _line; do
            case "$_line" in
                IHW:OK:*)   ok   "$(printf '%s' "$_line" | cut -d: -f3-)" ;;
                IHW:INFO:*) info "$(printf '%s' "$_line" | cut -d: -f3-)" ;;
                IHW:WARN:*) warn "$(printf '%s' "$_line" | cut -d: -f3-)" ;;
                IHW:FAIL:*) fail "$(printf '%s' "$_line" | cut -d: -f3-)" ;;
            esac
        done <<< "$_wlst_out"

        rm -f "$_wlst_script"
        unset _wlst_script _wlst_out WL_USER
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
    local current_port
    current_port="$(sed -n 's/.*<cluster[^>]*port="\([0-9]*\)".*/\1/p' "$file" 2>/dev/null | head -1)"
    printf "  %-52s port=%s\n" "$label" "${current_port:-(not found)}" \
        | tee -a "${LOG_FILE:-/dev/null}"

    if [ "$current_port" = "$REPORTS_BROADCAST_PORT" ]; then
        ok "Port already correct: $REPORTS_BROADCAST_PORT"
        return 0
    fi

    warn "Port is '${current_port:-unknown}' – target: $REPORTS_BROADCAST_PORT"
    if $APPLY; then
        cp "$file" "${file}.bak_$(date +%Y%m%d_%H%M%S)"
        sed -i "s/\(<cluster[^>]*port=\"\)[0-9]*/\1${REPORTS_BROADCAST_PORT}/" "$file"
        local new_port
        new_port="$(sed -n 's/.*<cluster[^>]*port="\([0-9]*\)".*/\1/p' "$file" 2>/dev/null | head -1)"
        if [ "$new_port" = "$REPORTS_BROADCAST_PORT" ]; then
            ok "Updated port to $REPORTS_BROADCAST_PORT in $label"
        else
            fail "sed did not update port in $label – verify XML pattern"
            info "  Expected: <cluster ... port=\"NNNN\" .../>"
            info "  File: $file"
        fi
    else
        info "  Dry-run – would change port to $REPORTS_BROADCAST_PORT"
    fi
}

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
# 5. rwserver.conf (per ReportsServer instance)
# =============================================================================

section "rwserver.conf"

_ENG_INIT="${REPORTS_ENGINE_INIT:-2}"
_ENG_MAX="${REPORTS_ENGINE_MAX:-5}"
_ENG_MIN="${REPORTS_ENGINE_MIN:-2}"
_MAX_CONN="${REPORTS_MAX_CONNECT:-300}"
_MAX_QUEUE="${REPORTS_MAX_QUEUE:-4000}"
_NLS="${NLS_LANG:-GERMAN_GERMANY.AL32UTF8}"

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
            printf '    <envVariable name="REPORTS_JVM_OPTIONS" value="-Djobid=random"/>\n'
            printf '  </environment>\n'
            printf '\n'
            printf '  <!-- Security: JAZN-based (WebLogic security realm) -->\n'
            printf '  <security id="rwJaznSec" class="oracle.reports.server.RWJAZNSecurity"/>\n'
            printf '\n'
            printf '  <!-- Destination plugins -->\n'
            printf '  <destination destype="ftp"    class="oracle.reports.plugin.destination.ftp.DesFTP"/>\n'
            printf '  <destination destype="WebDav" class="oracle.reports.plugin.destination.webdav.DesWebDAV"/>\n'
            printf '\n'
            printf '  <!-- IMPORTANT: SecurityId must NOT be present on job element -->\n'
            printf '  <!-- (causes engine startup errors with JAZN security) -->\n'
            printf '  <job jobType="report" engineId="rwEng" retry="3"/>\n'
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
            printf '  <!-- folderAccess: read = report source dir, write = temp output dir -->\n'
            printf '  <folderAccess>\n'
            printf '    <read>%s</read>\n'  "$REPORTS_PATH"
            printf '    <write>%s</write>\n' "$REPORTS_TMP"
            printf '  </folderAccess>\n'
            printf '\n'
            printf '  <!-- Internal Reports admin credentials (not the WebLogic admin user) -->\n'
            printf '  <identifier encrypted="no">rep_admin/wls_team</identifier>\n'
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
            printf '# ────────────────────────────────────────────────────────────────────────────\n'
        } >> "$_REPORTS_SH"
        ok "reports.sh updated with NLS_LANG and font variables"
    else
        info "Dry-run – would append NLS_LANG + REPORTS_FONT_DIRECTORY to reports.sh"
    fi
fi
unset _REPORTS_SH

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
info "Font setup:"
info "  04-ReportsFonts/uifont_ali_update.sh --apply"
info "  04-ReportsFonts/font_cache_reset.sh --apply"

unset _REPORTS_APP_DIR _REPORTS_APP_BASE _FIRST_SERVER_INST
unset _TOOLS_CONF_BASE _REPSERV_CONF_BASE

# =============================================================================
print_summary
exit "$EXIT_CODE"
