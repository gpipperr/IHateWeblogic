#!/bin/bash
# =============================================================================
# Script   : wls_password_rule.sh
# Purpose  : Password rule of the WebLogic realm (SystemPasswordValidator,
#            DISA STIG V-235966-70, 80-FMW-Architecture/stig_weblogic_forms_reports.md
#            §5 step 2). The rule applies to every user of the realm (admin,
#            monUser, RepRunner, Reports users) whenever a password is SET -
#            existing passwords keep working (only hashes are stored).
#            Default: read-only -
#              1 current rule (config.xml)
#              2 users of the realm (WLST online, read-only)
#              3 the passwords this library stores (weblogic_sec.conf.des3,
#                reports_users.conf.des3) checked locally against the new rule -
#                nothing printed but the failed criteria; a password that fails
#                cannot be set again after the change (e.g. 12- on a new domain)
#            --apply: backup of config.xml, new rule: min length (--min-length,
#            default 12; STIG 15), >= 1 upper case, lower case, digit and
#            non-alphanumeric character, password must not contain the user name.
#            --undo : back to the values of the domain template (8 characters,
#            1 digit or special character, nothing else).
# Call     : ./07-Maintenance/wls_password_rule.sh [--min-length N]   (show + plan)
#            ./07-Maintenance/wls_password_rule.sh --apply [--min-length N]
#            ./07-Maintenance/wls_password_rule.sh --undo --apply
# Requires : AdminServer running, weblogic_sec.conf.des3
# Runs as  : oracle
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 80-FMW-Architecture/stig_weblogic_forms_reports.md, 07-Maintenance/docs/03-security_hardening.md
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

APPLY=false; UNDO=false; MINLEN="${WLS_PWD_MIN_LENGTH:-12}"
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)      APPLY=true ;;
        --undo)       UNDO=true ;;
        --min-length) shift; MINLEN="${1:-12}" ;;
        --help|-h)
            printf "Usage: %s [--apply] [--min-length N] | --undo [--apply]\n\n" "$(basename "$0")"
            printf "  %-16s %s\n" "--apply" "new rule: min length N, upper + lower + digit + special, no user name"
            printf "  %-16s %s\n" "--min-length N" "minimum length (default 12, STIG 15, 8..64)"
            printf "  %-16s %s\n" "--undo" "back to the domain template: 8 characters, 1 digit or special"
            exit 0 ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
    shift
done
case "$MINLEN" in ''|*[!0-9]*) fail "--min-length must be a number"; print_summary; exit 2 ;; esac
{ [ "$MINLEN" -ge 8 ] && [ "$MINLEN" -le 64 ]; } || { fail "--min-length 8..64 (got $MINLEN)"; print_summary; exit 2; }
CONFIG_XML="$DOMAIN_HOME/config/config.xml"
WLST="$ORACLE_HOME/oracle_common/common/bin/wlst.sh"

# target values: name of the WLST setter -> value
if $UNDO; then
    TARGET="MinPasswordLength=8 MinNumericOrSpecialCharacters=1 MinUppercaseCharacters=0 MinLowercaseCharacters=0 MinNumericCharacters=0 MinNonAlphanumericCharacters=0 RejectEqualOrContainUsername=false"
else
    TARGET="MinPasswordLength=$MINLEN MinNumericOrSpecialCharacters=1 MinUppercaseCharacters=1 MinLowercaseCharacters=1 MinNumericCharacters=1 MinNonAlphanumericCharacters=1 RejectEqualOrContainUsername=true"
fi
_t() { printf '%s\n' $TARGET | sed -n "s/^$1=//p"; }

printLine
printf "\n\033[1m  IHateWeblogic – password rule of the WebLogic realm\033[0m\n" | tee -a "$LOG_FILE"
printList "Domain" 20 "$DOMAIN_HOME"
printList "Mode"   20 "$($UNDO && printf 'UNDO (template values)' || printf 'new rule, min length %s' "$MINLEN")$($APPLY || printf ' – dry-run')"
printLine

# =============================================================================
section "1. Current rule (config.xml)"
# =============================================================================
_pv="$(tr -d '\n' < "$CONFIG_XML" | grep -o '<sec:password-validator.*</sec:password-validator>' | head -1)"
_v() { printf '%s' "$_pv" | grep -o "<pas:$1>[^<]*" | sed 's/.*>//' | head -1; }
if [ -z "$_pv" ]; then
    warn "  no SystemPasswordValidator in config.xml"
else
    for _a in min-password-length min-numeric-or-special-characters min-uppercase-characters min-lowercase-characters min-numeric-characters min-non-alphanumeric-characters reject-equal-or-contain-username; do
        _val="$(_v "$_a")"; printList "  $_a" 40 "${_val:-(not set = 0 / false)}"
    done
fi

# =============================================================================
section "2. Users of the realm (WLST online, read-only)"
# =============================================================================
load_weblogic_password > /dev/null || { fail "WebLogic password not loaded"; print_summary; exit 2; }
_url="${WL_ADMIN_URL:-t3://${WLS_LISTEN_ADDRESS:-localhost}:${WLS_ADMIN_PORT:-7001}}"
ADMIN_PWD_LOCAL="$INTERNAL_WL_PWD"   # for the local rule check in section 3

# _wlst MODE - show | apply; prints IHW:<key>:<value>
_wlst() {
    local py out; py="$(mktemp /tmp/wls_pwrule_XXXXXX.py)"; chmod 600 "$py"
    cat > "$py" <<'WLST_EOF'
import os
_ihw_mode = os.environ['_IHW_MODE']
connect(os.environ['_IHW_WL_USER'], os.environ['_IHW_WL_PWD'], os.environ['_IHW_WL_URL'])
serverConfig()
cd('/')
_r = cmo.getSecurityConfiguration().getDefaultRealm()
if _ihw_mode == 'show':
    for _p in _r.getAuthenticationProviders():
        try:
            _c = _p.listUsers('*', 0)
            while _p.haveCurrent(_c):
                print('IHW:USER:' + _p.getName() + ':' + _p.getCurrentName(_c))
                _p.advance(_c)
            _p.close(_c)
        except:
            pass
else:
    edit()
    startEdit()
    cd('/')
    _r = cmo.getSecurityConfiguration().getDefaultRealm()
    _v = _r.lookupPasswordValidator('SystemPasswordValidator')
    if _v is None:
        print('IHW:ERR:no SystemPasswordValidator in the realm')
        cancelEdit('y')
    else:
        for _kv in os.environ['_IHW_TARGET'].split(' '):
            _k, _val = _kv.split('=')
            if _val in ('true', 'false'):
                getattr(_v, 'set' + _k)(_val == 'true')
            else:
                getattr(_v, 'set' + _k)(int(_val))
            print('IHW:SET:' + _k + ' = ' + _val)
        save()
        activate(block='true')
print('IHW:DONE')
disconnect()
WLST_EOF
    out="$(_IHW_MODE="$1" _IHW_TARGET="$TARGET" _IHW_WL_USER="$WL_USER" _IHW_WL_PWD="$INTERNAL_WL_PWD" \
           _IHW_WL_URL="$_url" "$WLST" "$py" 2>&1)"
    rm -f "$py"
    printf '%s\n' "$out" >> "${LOG_FILE:-/dev/null}"
    printf '%s\n' "$out" | grep -E '^IHW:|restarted|non-dynamic'
}
_cur="$(_wlst show)"
printf '%s' "$_cur" | grep -q '^IHW:DONE' || { fail "WLST failed – see $LOG_FILE (AdminServer running?)"; INTERNAL_WL_PWD=""; print_summary; exit 2; }
printf '%s\n' "$_cur" | sed -n 's/^IHW:USER://p' | while IFS=: read -r _prov _u; do
    info "$(printf "  %-28s (%s)" "$_u" "$_prov")"
done
info "  The rule is checked when a password is SET (create user, change / reset) – the passwords above keep working."

# =============================================================================
section "3. Passwords stored by this library vs. the $($UNDO && printf 'template' || printf 'new') rule (local, nothing printed)"
# =============================================================================
# rule spec of the target values for the lib check wls_pwd_rule_fail
SPEC="len=$(_t MinPasswordLength) upper=$(_t MinUppercaseCharacters) lower=$(_t MinLowercaseCharacters) digit=$(_t MinNumericCharacters) special=$(_t MinNonAlphanumericCharacters) numspecial=$(_t MinNumericOrSpecialCharacters) nouser=$([ "$(_t RejectEqualOrContainUsername)" = true ] && printf 1 || printf 0)"
info "  Rule: $(wls_pwd_rule_text "$SPEC")"
_chk() {   # label user password
    local r; [ -n "$3" ] || { info "$(printf "  %-26s not stored" "$1")"; return; }
    r="$(wls_pwd_rule_fail "$3" "$2" "$SPEC")"
    if [ -z "$r" ]; then ok "$(printf "  %-26s meets the rule" "$1")"
    else warn "$(printf "  %-26s fails: %s – cannot be set again after the change (new domain, 12- on a new realm, password reset)" "$1" "$r")"; fi
}
_chk "admin ($WL_USER)" "$WL_USER" "$ADMIN_PWD_LOCAL"
ADMIN_PWD_LOCAL=""
_rus="$ROOT_DIR/reports_users.conf.des3"
if [ -f "$_rus" ] && load_secrets_file "$_rus" 2>/dev/null; then
    _chk "monitor (${REPORTS_MON_USER:-monUser})" "${REPORTS_MON_USER:-monUser}" "${REPORTS_MON_PWD:-}"
    _chk "reports exec (${REPORTS_EXEC_USER:-RepRunner})" "${REPORTS_EXEC_USER:-RepRunner}" "${REPORTS_EXEC_PWD:-}"
    REPORTS_MON_PWD=""; REPORTS_EXEC_PWD=""
else
    info "  reports_users.conf.des3 not present / not readable – monUser / RepRunner not checked"
fi

# =============================================================================
section "4. Plan"
# =============================================================================
for _kv in $TARGET; do info "  ${_kv%%=*} -> ${_kv#*=}"; done
info "  Not affected: Node Manager password (config.xml + nm_password.properties), embedded LDAP cn=Admin,"
info "  Reports server <identifier>, DB / RCU passwords – they are not realm users."
if ! $APPLY; then
    warn "Dry-run – use --apply to change (backup of config.xml first)"
    INTERNAL_WL_PWD=""; print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
section "5. Apply"
# =============================================================================
backup_file "$CONFIG_XML" > /dev/null && ok "  config.xml backed up (config.xml.bak_<time> next to it)"
_res="$(_wlst apply)"
INTERNAL_WL_PWD=""
if printf '%s' "$_res" | grep -q '^IHW:DONE' && ! printf '%s' "$_res" | grep -q '^IHW:ERR'; then
    printf '%s\n' "$_res" | sed -n 's/^IHW:SET://p' | while IFS= read -r _l; do ok "  $_l"; done
    if printf '%s' "$_res" | grep -qi 'non-dynamic\|restarted'; then
        info "  WebLogic: non-dynamic – restart the domain: ./01-Run/startStop.sh stop-all --apply; ./01-Run/startStop.sh start-all --apply"
    else
        ok "  active at once (dynamic attributes – no restart needed)"
    fi
    info "  Check: ./02-Checks/domain_secret_check.sh (section 7)"
else
    fail "WLST failed: $(printf '%s\n' "$_res" | sed -n 's/^IHW:ERR://p' | head -1) – see $LOG_FILE; config.xml backup next to the file"
fi

print_summary
exit "$EXIT_CODE"
