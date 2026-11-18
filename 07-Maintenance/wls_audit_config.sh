#!/bin/bash
# =============================================================================
# Script   : wls_audit_config.sh
# Purpose  : Audit trail of the WebLogic domain (DISA STIG V-235931/33/34/35,
#            80-FMW-Architecture/stig_weblogic_forms_reports.md §5 step 1):
#              1 configuration audit of the domain = "logaudit" (Change Log and
#                Audit: every configuration change / deployment in the server
#                log + to the auditing provider)
#              2 auditing provider "IHW_DefaultAuditor" in the realm
#                (weblogic.security.providers.audit.DefaultAuditor, severity
#                ERROR = ERROR + SUCCESS + FAILURE events, i.e. successful and
#                failed logins; file servers/<srv>/logs/DefaultAuditRecorder.log,
#                rotated daily, 50 files kept - provider defaults)
#              3 OPSS audit policy filterPreset (default Low) -> audit loader
#                -> <prefix>_IAU_APPEND (data source opss-audit-DBDS)
#            Default: read-only - current values (WLST online) + plan.
#            --apply: backup of config.xml, the three changes; restart of the
#            domain needed for the new auditing provider (printed).
#            --undo : configuration audit none, IHW_DefaultAuditor removed,
#            filterPreset None (the way back).
# Call     : ./07-Maintenance/wls_audit_config.sh                 (show + plan)
#            ./07-Maintenance/wls_audit_config.sh --apply [--preset Low|Medium]
#            ./07-Maintenance/wls_audit_config.sh --undo --apply
# Requires : AdminServer running, weblogic_sec.conf.des3
# Runs as  : oracle
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 80-FMW-Architecture/stig_weblogic_forms_reports.md, 07-Maintenance/README.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
[ -f "$LIB" ] || { printf "\033[31mERROR\033[0m Cannot find IHateWeblogic_lib.sh: %s\n" "$LIB" >&2; exit 2; }
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"
check_env_conf "$ENV_CONF" || exit 2
# shellcheck disable=SC1090
source "$ENV_CONF"
init_log

APPLY=false; UNDO=false; PRESET="${WLS_OPSS_AUDIT_PRESET:-Low}"
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)  APPLY=true ;;
        --undo)   UNDO=true ;;
        --preset) shift; PRESET="${1:-Low}" ;;
        --help|-h)
            printf "Usage: %s [--apply] [--preset Low|Medium] | --undo [--apply]\n\n" "$(basename "$0")"
            printf "  %-16s %s\n" "--apply" "configuration audit logaudit + IHW_DefaultAuditor + OPSS filterPreset"
            printf "  %-16s %s\n" "--preset P" "OPSS audit filterPreset (Low default, Medium)"
            printf "  %-16s %s\n" "--undo" "back to: configuration audit none, no IHW_DefaultAuditor, filterPreset None"
            exit 0 ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
    shift
done
case "$PRESET" in Low|Medium) ;; *) fail "--preset must be Low or Medium (got: $PRESET)"; print_summary; exit 2 ;; esac
CONFIG_XML="$DOMAIN_HOME/config/config.xml"
WLST="$ORACLE_HOME/oracle_common/common/bin/wlst.sh"

printLine
printf "\n\033[1m  IHateWeblogic – WebLogic audit trail (configuration audit, auditing provider, OPSS)\033[0m\n" | tee -a "$LOG_FILE"
printList "Domain"  20 "$DOMAIN_HOME"
printList "Mode"    20 "$($UNDO && printf 'UNDO' || printf "audit on (OPSS preset %s)" "$PRESET")$($APPLY || printf ' – dry-run')"
printLine

load_weblogic_password > /dev/null || { fail "WebLogic password not loaded"; print_summary; exit 2; }
_url="${WL_ADMIN_URL:-t3://${WLS_LISTEN_ADDRESS:-localhost}:${WLS_ADMIN_PORT:-7001}}"

# _wlst MODE - MODE show | apply | undo; prints IHW:<key>:<value> lines
_wlst() {
    local py out; py="$(mktemp /tmp/wls_audit_XXXXXX.py)"; chmod 600 "$py"
    cat > "$py" <<'WLST_EOF'
import os
_ihw_mode = os.environ['_IHW_MODE']
_ihw_preset = os.environ['_IHW_PRESET']
connect(os.environ['_IHW_WL_USER'], os.environ['_IHW_WL_PWD'], os.environ['_IHW_WL_URL'])
_ihw_dom = cmo.getName()
def _ihw_show():
    serverConfig()
    cd('/')
    print('IHW:CONFAUDIT:' + str(cmo.getConfigurationAuditType()))
    _r = cmo.getSecurityConfiguration().getDefaultRealm()
    print('IHW:REALM:' + _r.getName())
    for _a in _r.getAuditors():
        print('IHW:AUDITOR:' + _a.getName() + ':' + str(_a.getProviderClassName()))
    try:
        getAuditPolicy()
    except:
        print('IHW:OPSSERR:getAuditPolicy failed')
if _ihw_mode == 'show':
    _ihw_show()
else:
    edit()
    startEdit()
    cd('/')
    _r = cmo.getSecurityConfiguration().getDefaultRealm()
    if _ihw_mode == 'apply':
        cmo.setConfigurationAuditType('logaudit')
        print('IHW:SET:configuration audit logaudit')
        if _r.lookupAuditor('IHW_DefaultAuditor') is None and len(_r.getAuditors()) == 0:
            _r.createAuditor('IHW_DefaultAuditor', 'weblogic.security.providers.audit.DefaultAuditor')
            print('IHW:SET:auditing provider IHW_DefaultAuditor created (severity ERROR = ERROR + SUCCESS + FAILURE)')
        else:
            print('IHW:KEEP:auditing provider already present')
    else:
        cmo.setConfigurationAuditType('none')
        print('IHW:SET:configuration audit none')
        _a = _r.lookupAuditor('IHW_DefaultAuditor')
        if _a is not None:
            _r.destroyAuditor(_a)
            print('IHW:SET:auditing provider IHW_DefaultAuditor removed')
    save()
    activate(block='true')
    try:
        if _ihw_mode == 'apply':
            setAuditPolicy(filterPreset=_ihw_preset)
            print('IHW:SET:OPSS audit filterPreset ' + _ihw_preset)
        else:
            setAuditPolicy(filterPreset='None')
            print('IHW:SET:OPSS audit filterPreset None')
    except:
        print('IHW:OPSSERR:setAuditPolicy failed')
    _ihw_show()
print('IHW:DONE')
disconnect()
WLST_EOF
    out="$(_IHW_MODE="$1" _IHW_PRESET="$PRESET" _IHW_WL_USER="$WL_USER" _IHW_WL_PWD="$INTERNAL_WL_PWD" \
           _IHW_WL_URL="$_url" "$WLST" "$py" 2>&1)"
    rm -f "$py"
    printf '%s\n' "$out" >> "${LOG_FILE:-/dev/null}"
    # getAuditPolicy() prints its result ("FilterPreset: <value>") instead of returning it
    printf '%s\n' "$out" | sed -n 's/^FilterPreset:[[:space:]]*\([A-Za-z]*\).*/IHW:OPSS:\1/p; /^IHW:/p'
}

# =============================================================================
section "1. Current state (WLST online, read-only)"
# =============================================================================
_cur="$(_wlst show)"
printf '%s' "$_cur" | grep -q '^IHW:DONE' || { fail "WLST failed – see $LOG_FILE (AdminServer running?)"; INTERNAL_WL_PWD=""; print_summary; exit 2; }
_show() {
    local s="$1" ca aud opss
    ca="$(printf '%s\n' "$s" | sed -n 's/^IHW:CONFAUDIT://p' | tail -1)"
    aud="$(printf '%s\n' "$s" | sed -n 's/^IHW:AUDITOR://p' | paste -sd' ' -)"
    opss="$(printf '%s\n' "$s" | sed -n 's/^IHW:OPSS://p' | tail -1)"
    printList "  configuration audit" 26 "${ca:-?}"
    printList "  auditing provider(s)" 26 "${aud:-none}"
    printList "  OPSS audit filterPreset" 26 "${opss:-?}"
    printf '%s\n' "$s" | grep -q '^IHW:OPSSERR' && warn "  OPSS: $(printf '%s\n' "$s" | sed -n 's/^IHW:OPSSERR://p' | tail -1)"
}
_show "$_cur"

# =============================================================================
section "2. Plan"
# =============================================================================
if $UNDO; then
    info "  configuration audit -> none; auditing provider IHW_DefaultAuditor removed (others stay); OPSS filterPreset -> None"
else
    info "  configuration audit -> logaudit (Change Log and Audit) – every change / deployment / activation in <server>.log + auditing provider"
    info "  auditing provider -> IHW_DefaultAuditor (DefaultAuditor, severity ERROR = ERROR + SUCCESS + FAILURE: logins ok / failed, admin actions)"
    info "                       file servers/<server>/logs/DefaultAuditRecorder.log, rotated daily, 50 files kept"
    info "                       only created when the realm has no auditing provider yet"
    info "  OPSS audit policy  -> filterPreset $PRESET (audit loader -> ${DB_SCHEMA_PREFIX:-DEV}_IAU_APPEND via opss-audit-DBDS)"
    info "  afterwards: restart the domain (stop-all / start-all) – a new security provider is active after a restart only"
fi

if ! $APPLY; then
    warn "Dry-run – use --apply to change (backup of config.xml first)"
    INTERNAL_WL_PWD=""; print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
section "3. Apply"
# =============================================================================
backup_file "$CONFIG_XML" > /dev/null && ok "  config.xml backed up (config.xml.bak_<time> next to it)"
_res="$(_wlst "$($UNDO && printf undo || printf apply)")"
INTERNAL_WL_PWD=""
if printf '%s' "$_res" | grep -q '^IHW:DONE'; then
    printf '%s\n' "$_res" | sed -n 's/^IHW:SET://p' | while IFS= read -r _l; do ok "  $_l"; done
    printf '%s\n' "$_res" | sed -n 's/^IHW:KEEP://p' | while IFS= read -r _l; do info "  $_l"; done
    printf '%s\n' "$_res" | grep -q '^IHW:OPSSERR' && warn "  OPSS audit policy not changed – see $LOG_FILE"
    section "4. New state (config.xml – active after the restart)"
    # configuration audit type and auditing provider are non-dynamic: the runtime
    # view of WLST shows the old values until the restart - read config.xml
    printList "  configuration audit" 26 "$(grep -o '<configuration-audit-type>[^<]*' "$CONFIG_XML" | sed 's/.*>//' | head -1)"
    printList "  auditing provider(s)" 26 "$(tr -d '\n' < "$CONFIG_XML" | grep -o '<sec:auditor[^>]*>[[:space:]]*<sec:name>[^<]*' | sed 's/.*<sec:name>//' | paste -sd' ' -)"
    printList "  OPSS audit filterPreset" 26 "$(printf '%s\n' "$_res" | sed -n 's/^IHW:OPSS://p' | tail -1) (active at once)"
    info "  Restart the domain now (non-dynamic attributes, new auditing provider):"
    info "    ./01-Run/startStop.sh stop-all --apply; ./01-Run/startStop.sh start-all --apply"
    info "  Check afterwards: ./02-Checks/domain_secret_check.sh (section 7), servers/*/logs/DefaultAuditRecorder.log"
else
    fail "WLST failed – see $LOG_FILE; config.xml backup next to the file"
fi

print_summary
exit "$EXIT_CODE"
