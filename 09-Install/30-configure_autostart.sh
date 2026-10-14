#!/bin/bash
# =============================================================================
# Script   : 30-configure_autostart.sh
# Purpose  : Autostart of the FMW domain at boot (systemd), all components
#            controlled through the Node Manager. Renders the control scripts
#            from 09-Install/autostart_templates/ into
#            $ORACLE_BASE/admin/<DOMAIN_NAME>/ctrl, creates the encrypted
#            WLST key files (no prompt, password from weblogic_sec.conf.des3)
#            and installs/enables the unit fmw-<DOMAIN_NAME>.service.
# Call     : ./09-Install/30-configure_autostart.sh                  (dry-run)
#            ./09-Install/30-configure_autostart.sh --apply
#            ./09-Install/30-configure_autostart.sh --remove [--apply]
# Options  : --apply    Deploy scripts, key files and the systemd unit
#            --remove   Disable/remove the unit and delete the ctrl directory
#                       (running servers are NOT stopped)
#            --help     Show usage
# Requires : Domain + Node Manager running (for the key files),
#            servers/AdminServer/security/boot.properties, weblogic_sec.conf.des3
# Runs as  : oracle (systemd part via sudo, otherwise commands are printed)
# Ref      : 09-Install/docs/30-configure_autostart.md
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
REMOVE=false

for _arg in "$@"; do
    case "$_arg" in
        --apply)   APPLY=true ;;
        --remove)  REMOVE=true ;;
        --help|-h)
            printf "Usage: %s [--apply] [--remove] [--help]\n\n" "$(basename "$0")"
            printf "  %-10s %s\n" "(none)"   "Dry-run: show components and target files"
            printf "  %-10s %s\n" "--apply"  "Deploy control scripts, key files and the systemd unit"
            printf "  %-10s %s\n" "--remove" "Remove unit + ctrl directory (with --apply); servers keep running"
            printf "  %-10s %s\n" "--help"   "Show this help"
            printf "\nRef: 09-Install/docs/30-configure_autostart.md\n"
            exit 0 ;;
        *) warn "Unknown argument: $_arg" ;;
    esac
done
unset _arg

# =============================================================================
# Log setup
# =============================================================================

LOG_FILE="$ROOT_DIR/log/$(date +%Y%m%d)/configure_autostart_$(date +%H%M%S).log"
mkdir -p "$(dirname "$LOG_FILE")"
{
    printf "# 30-configure_autostart.sh log\n"
    printf "# Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# Host    : %s\n" "$(_get_hostname)"
    printf "# Apply   : %s  Remove: %s\n" "$APPLY" "$REMOVE"
} > "$LOG_FILE"

_abort() {
    fail "$1"
    [ -n "${2:-}" ] && info "$2"
    print_summary
    exit 2
}

# =============================================================================
# Root / sudo helpers (same pattern as 02b-root_os_java.sh)
# =============================================================================

_can_sudo() { sudo -n true 2>/dev/null; }

_run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif _can_sudo; then
        sudo "$@"
    else
        warn "No root/sudo for: $*"
        info "  Run manually as root: $*"
        return 1
    fi
}

# =============================================================================
# Paths
# =============================================================================

for _var in ORACLE_BASE ORACLE_HOME DOMAIN_HOME; do
    [ -n "${!_var:-}" ] || _abort "$_var is not set in environment.conf"
done
unset _var

DOMAIN_NAME="${DOMAIN_NAME:-$(basename "$DOMAIN_HOME")}"
CTRL_DIR="$ORACLE_BASE/admin/$DOMAIN_NAME/ctrl"
TPL_DIR="$SCRIPT_DIR/autostart_templates"
UNIT_NAME="fmw-${DOMAIN_NAME}.service"
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"
CONFIG_XML="$DOMAIN_HOME/config/config.xml"
NM_PROPS="$DOMAIN_HOME/nodemanager/nodemanager.properties"
WLST_SH="$ORACLE_HOME/oracle_common/common/bin/wlst.sh"

printLine
printf "\n\033[1m  IHateWeblogic – Configure FMW Autostart\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)" | tee -a "$LOG_FILE"
printf "  DOMAIN_HOME : %s\n" "$DOMAIN_HOME"     | tee -a "$LOG_FILE"
printf "  Ctrl dir    : %s\n" "$CTRL_DIR"        | tee -a "$LOG_FILE"
printf "  Unit        : %s\n" "$UNIT_PATH"       | tee -a "$LOG_FILE"
printf "  Apply       : %s  Remove: %s\n" "$APPLY" "$REMOVE" | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"        | tee -a "$LOG_FILE"
printLine

# =============================================================================
# --remove
# =============================================================================

if $REMOVE; then
    section "Remove Autostart"
    [ -f "$UNIT_PATH" ] && info "Unit present: $UNIT_PATH" || info "Unit not installed: $UNIT_PATH"
    [ -d "$CTRL_DIR" ]  && info "Ctrl dir present: $CTRL_DIR" || info "Ctrl dir not present: $CTRL_DIR"
    if ! $APPLY; then
        warn "Dry-run – re-run with --remove --apply to remove (servers keep running)"
        print_summary; exit "$EXIT_CODE"
    fi
    if [ -f "$UNIT_PATH" ]; then
        _run_root systemctl disable "$UNIT_NAME" >/dev/null 2>&1
        _run_root rm -f "$UNIT_PATH" && ok "Unit removed: $UNIT_PATH"
        _run_root systemctl daemon-reload && ok "systemd reloaded"
    fi
    # Guard: only ever delete exactly <ORACLE_BASE>/admin/<DOMAIN_NAME>/ctrl
    if [ -d "$CTRL_DIR" ] && [ "$CTRL_DIR" = "$ORACLE_BASE/admin/$DOMAIN_NAME/ctrl" ] \
       && [ -n "$DOMAIN_NAME" ]; then
        rm -rf -- "$CTRL_DIR" && ok "Removed: $CTRL_DIR"
        rmdir "$ORACLE_BASE/admin/$DOMAIN_NAME" 2>/dev/null \
            && ok "Removed empty: $ORACLE_BASE/admin/$DOMAIN_NAME"
    fi
    info "Running servers were not stopped – use 01-Run/startStop.sh if needed"
    print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# Prerequisites
# =============================================================================

section "Prerequisites"

[ -f "$CONFIG_XML" ] && ok "config.xml found" || _abort "config.xml not found: $CONFIG_XML" "Create the domain first (08-oracle_setup_domain.sh)"
[ -x "$WLST_SH" ]    && ok "wlst.sh found"    || _abort "wlst.sh not found: $WLST_SH"
[ -x "$DOMAIN_HOME/bin/startNodeManager.sh" ] && ok "startNodeManager.sh found" \
    || _abort "startNodeManager.sh not found in $DOMAIN_HOME/bin"
for _t in fmw_env.sh fmw_ctl.sh wls_start.py wls_stop.py wls_status.py fmw.service; do
    [ -f "$TPL_DIR/$_t.template" ] || _abort "Template missing: $TPL_DIR/$_t.template"
done
ok "Templates found: $TPL_DIR"
unset _t

# =============================================================================
# Discover components from config.xml
# =============================================================================

section "Domain Components"

ADMIN_SERVER="$(sed -n 's|.*<admin-server-name>\([^<]*\)</admin-server-name>.*|\1|p' "$CONFIG_XML" | head -1)"
ADMIN_SERVER="${ADMIN_SERVER:-AdminServer}"

# Servers (same parsing as 01-Run/startStop.sh::_discover, skips <ssl> blocks)
ALL_SERVERS="$(awk '
    BEGIN { in_srv=0; in_ssl=0 }
    /<server>$/   { in_srv=1; name="" }
    /<\/server>$/ {
        if (in_srv && name != "" && name != "TEMPLATE" && name != "template") print name
        in_srv=0; in_ssl=0
    }
    in_srv && /<ssl>$/   { in_ssl=1 }
    in_srv && /<\/ssl>$/ { in_ssl=0 }
    in_srv && !in_ssl { if (match($0, /<name>([^<]+)<\/name>/, m)) name = m[1] }
' "$CONFIG_XML")"
MANAGED_SERVERS="$(printf '%s\n' $ALL_SERVERS | grep -vx "$ADMIN_SERVER" | tr '\n' ' ' | sed 's/ $//')"

# Admin listen port (fallback WLS_ADMIN_PORT)
ADMIN_PORT="$(awk -v a="$ADMIN_SERVER" '
    /<server>$/ { in_srv=1; name=""; port="" }
    in_srv && /<ssl>$/ { in_ssl=1 } in_srv && /<\/ssl>$/ { in_ssl=0 }
    in_srv && !in_ssl && match($0, /<name>([^<]+)<\/name>/, m) { name=m[1] }
    in_srv && !in_ssl && match($0, /<listen-port>([^<]+)<\/listen-port>/, m) { port=m[1] }
    /<\/server>$/ { if (name == a) print port; in_srv=0 }
' "$CONFIG_XML" | head -1)"
ADMIN_PORT="${ADMIN_PORT:-${WLS_ADMIN_PORT:-7001}}"
ADMIN_URL="t3://localhost:${ADMIN_PORT}"

# System components with a process of their own (Reports server, OHS)
SYSTEM_COMPONENTS="$(awk '
    /<system-component>/  { in_c=1; name=""; type="" }
    in_c && match($0, /<name>([^<]+)<\/name>/, m)                     { name=m[1] }
    in_c && match($0, /<component-type>([^<]+)<\/component-type>/, m) { type=m[1] }
    /<\/system-component>/ {
        if (type == "ReportsServerComponent" || type == "OHS") print name ":" type
        in_c=0
    }
' "$CONFIG_XML" | tr '\n' ' ' | sed 's/ $//')"

# Node Manager listen address/port
NM_HOST="localhost"; NM_PORT="${WLS_NODEMANAGER_PORT:-5556}"
if [ -f "$NM_PROPS" ]; then
    _h="$(sed -n 's/^ListenAddress=\(.*\)$/\1/p' "$NM_PROPS" | tr -d ' \r' | head -1)"
    _p="$(sed -n 's/^ListenPort=\(.*\)$/\1/p'    "$NM_PROPS" | tr -d ' \r' | head -1)"
    NM_HOST="${_h:-$NM_HOST}"; NM_PORT="${_p:-$NM_PORT}"
    unset _h _p
fi

printList "AdminServer"       26 "$ADMIN_SERVER  ($ADMIN_URL)"
printList "Managed servers"   26 "${MANAGED_SERVERS:-(none)}"
printList "System components" 26 "${SYSTEM_COMPONENTS:-(none)}"
printList "Node Manager"      26 "$NM_HOST:$NM_PORT"
[ -n "$MANAGED_SERVERS" ] || warn "No managed servers found in config.xml"

# DB dependency (repository DB on this host)
DB_UNITS=""
if [ "${LOCAL_REP_DB:-false}" = "true" ]; then
    for _u in oracle-db.service oracle-listener.service; do
        systemctl list-unit-files "$_u" 2>/dev/null | grep -q "^$_u" && DB_UNITS="$DB_UNITS $_u"
    done
    unset _u
    [ -n "$DB_UNITS" ] && ok "LOCAL_REP_DB=true – unit ordered after:$DB_UNITS" \
                       || warn "LOCAL_REP_DB=true but no oracle-db/oracle-listener unit found"
fi

[ -f "$DOMAIN_HOME/servers/$ADMIN_SERVER/security/boot.properties" ] \
    && ok "boot.properties for $ADMIN_SERVER present (needed by nmStart)" \
    || _abort "boot.properties missing: $DOMAIN_HOME/servers/$ADMIN_SERVER/security/boot.properties" \
              "Create it first: 09-Install/10-oracle_boot_properties.sh --apply"

# =============================================================================
# Dry-run exit
# =============================================================================

if ! $APPLY; then
    printf "\n" | tee -a "$LOG_FILE"
    info "Would deploy to $CTRL_DIR:"
    info "  fmw_env.sh  fmw_ctl.sh  wls_start.py  wls_stop.py  wls_status.py  keyfile/  log/"
    info "Would install + enable: $UNIT_PATH"
    warn "Dry-run – re-run with --apply"
    print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# Domain must be running (WLST key files need live connections)
# =============================================================================

section "Running Domain"

pgrep -f "Dweblogic.Name=${ADMIN_SERVER}( |$)" >/dev/null \
    && ok "$ADMIN_SERVER is running" \
    || _abort "$ADMIN_SERVER is not running" "Start the domain first: 01-Run/startStop.sh start-all --apply"
ss -tln 2>/dev/null | grep -qE "[:.]${NM_PORT}[[:space:]]" \
    && ok "Node Manager listening on port $NM_PORT" \
    || _abort "Node Manager not listening on port $NM_PORT" "Start it first: 01-Run/startStop.sh start-all --apply"

# =============================================================================
# Render templates
# =============================================================================

section "Deploy Control Scripts"

mkdir -p "$CTRL_DIR/keyfile" "$CTRL_DIR/log" || _abort "Cannot create $CTRL_DIR"
chmod 700 "$CTRL_DIR/keyfile"

_ts="$(date +%Y%m%d_%H%M%S)"
if ls "$CTRL_DIR"/*.sh "$CTRL_DIR"/*.py >/dev/null 2>&1; then
    mkdir -p "$CTRL_DIR/backup_$_ts"
    cp -p "$CTRL_DIR"/*.sh "$CTRL_DIR"/*.py "$CTRL_DIR/backup_$_ts/" 2>/dev/null
    ok "Previous scripts saved: $CTRL_DIR/backup_$_ts"
fi
unset _ts

declare -A RENDER=(
    [ORACLE_HOME]="$ORACLE_HOME"            [DOMAIN_HOME]="$DOMAIN_HOME"
    [DOMAIN_NAME]="$DOMAIN_NAME"            [CTRL_DIR]="$CTRL_DIR"
    [NM_HOST]="$NM_HOST"                    [NM_PORT]="$NM_PORT"
    [ADMIN_URL]="$ADMIN_URL"                [ADMIN_SERVER]="$ADMIN_SERVER"
    [MANAGED_SERVERS]="$MANAGED_SERVERS"    [SYSTEM_COMPONENTS]="$SYSTEM_COMPONENTS"
    [DB_UNITS]="$DB_UNITS"
    [OS_USER]="$(id -un)"                   [OS_GROUP]="$(id -gn)"
    [ULIMIT_NOFILE]="${ULIMIT_NOFILE:-65536}" [ULIMIT_NPROC]="${ULIMIT_NPROC:-16384}"
)

# _render  template  output
_render() {
    local args=() k
    for k in "${!RENDER[@]}"; do
        args+=(-e "s|##${k}##|${RENDER[$k]}|g")
    done
    sed "${args[@]}" "$1" > "$2" || return 1
    if grep -q '##[A-Z_]*##' "$2"; then
        fail "Unreplaced placeholder in $2: $(grep -o '##[A-Z_]*##' "$2" | sort -u | tr '\n' ' ')"
        return 1
    fi
    ok "Rendered: $2"
}

for _f in fmw_env.sh fmw_ctl.sh wls_start.py wls_stop.py wls_status.py; do
    _render "$TPL_DIR/$_f.template" "$CTRL_DIR/$_f" || _abort "Rendering failed: $_f"
done
_render "$TPL_DIR/fmw.service.template" "$CTRL_DIR/$UNIT_NAME" || _abort "Rendering failed: $UNIT_NAME"
unset _f
chmod 750 "$CTRL_DIR"/*.sh
chmod 640 "$CTRL_DIR"/*.py "$CTRL_DIR/$UNIT_NAME"

for _s in fmw_env.sh fmw_ctl.sh; do
    bash -n "$CTRL_DIR/$_s" || _abort "Syntax error in rendered $_s"
done
unset _s
ok "Rendered shell scripts pass bash -n"

# =============================================================================
# WLST key files (no prompt)
# =============================================================================

section "WLST Key Files"

load_weblogic_password >/dev/null 2>&1 \
    || _abort "Cannot load WebLogic credentials" "Run first: 00-Setup/weblogic_sec.sh --apply"

_key_py="$(mktemp "$ORACLE_BASE/tmp/ihw_keys_XXXXXX.py" 2>/dev/null || mktemp --suffix=.py)"
cat > "$_key_py" <<'WLST_EOF'
import os
u    = os.environ['_IHW_WL_USER']
p    = os.environ['_IHW_WL_PASS']
ctrl = os.environ['_IHW_CTRL']
try:
    connect(u, p, os.environ['_IHW_ADMIN_URL'])
    storeUserConfig(ctrl + '/keyfile/admin_config', ctrl + '/keyfile/admin_key')
    disconnect()
    print('IHW:OK:Admin key files created (connect)')
except Exception as e:
    print('IHW:FAIL:Admin key files: ' + str(e).split('\n')[0])
    exit(defaultAnswer='y', exitcode=1)
try:
    nmConnect(u, p, os.environ['_IHW_NM_HOST'], os.environ['_IHW_NM_PORT'],
              os.environ['_IHW_DOMAIN_NAME'], os.environ['_IHW_DOMAIN_HOME'], 'plain')
    storeUserConfig(ctrl + '/keyfile/nm_config', ctrl + '/keyfile/nm_key', 'true')
    nmDisconnect()
    print('IHW:OK:Node Manager key files created (nmConnect)')
except Exception as e:
    print('IHW:FAIL:Node Manager key files – are the NM credentials the admin user? ' + str(e).split('\n')[0])
    exit(defaultAnswer='y', exitcode=1)
exit(defaultAnswer='y', exitcode=0)
WLST_EOF

_wlst_out="$(
    _IHW_WL_USER="$WL_USER" _IHW_WL_PASS="$INTERNAL_WL_PWD" _IHW_CTRL="$CTRL_DIR" \
    _IHW_ADMIN_URL="$ADMIN_URL" _IHW_NM_HOST="$NM_HOST" _IHW_NM_PORT="$NM_PORT" \
    _IHW_DOMAIN_NAME="$DOMAIN_NAME" _IHW_DOMAIN_HOME="$DOMAIN_HOME" \
    WLST_PROPERTIES="-Dweblogic.management.confirmKeyfileCreation=true" \
    "$WLST_SH" "$_key_py" 2>&1
)"
_key_rc=$?
rm -f "$_key_py"
unset INTERNAL_WL_PWD _key_py

while IFS= read -r _line; do
    case "$_line" in
        IHW:OK:*)   ok   "${_line#IHW:OK:}" ;;
        IHW:FAIL:*) fail "${_line#IHW:FAIL:}" ;;
    esac
done <<< "$_wlst_out"
unset _wlst_out _line
[ "$_key_rc" -eq 0 ] || _abort "WLST key file creation failed (rc=$_key_rc)" "Details: $LOG_FILE"
chmod 600 "$CTRL_DIR"/keyfile/* 2>/dev/null
ok "Key files: $CTRL_DIR/keyfile (mode 600)"
unset _key_rc

# =============================================================================
# systemd unit
# =============================================================================

section "systemd Unit"

if _run_root install -m 644 "$CTRL_DIR/$UNIT_NAME" "$UNIT_PATH"; then
    ok "Installed: $UNIT_PATH"
    _run_root systemctl daemon-reload && ok "systemd reloaded"
    _run_root systemctl enable "$UNIT_NAME" >/dev/null 2>&1 \
        && ok "Enabled: $UNIT_NAME (starts at next boot)" \
        || fail "systemctl enable $UNIT_NAME failed"
else
    warn "Unit not installed – run as root:"
    info "  install -m 644 $CTRL_DIR/$UNIT_NAME $UNIT_PATH"
    info "  systemctl daemon-reload && systemctl enable $UNIT_NAME"
fi

# =============================================================================
# Self-test
# =============================================================================

section "Self-test (fmw_ctl.sh status)"

"$CTRL_DIR/fmw_ctl.sh" status 2>&1 | tee -a "$LOG_FILE"
if [ "${PIPESTATUS[0]}" -eq 0 ]; then
    ok "All components RUNNING under Node Manager control"
else
    warn "Not all components report RUNNING via the Node Manager"
    info "  Servers started with startWebLogic.sh/startManagedWebLogic.sh show UNKNOWN."
    info "  Switch over once: 01-Run/startStop.sh stop-all --apply, then (as root)"
    info "  systemctl start $UNIT_NAME"
fi

printLine
info "Operate: $CTRL_DIR/fmw_ctl.sh {start|stop|restart|status} [all|<component>]"
info "         systemctl {start|stop|status} $UNIT_NAME"
printLine

print_summary
exit "$EXIT_CODE"
