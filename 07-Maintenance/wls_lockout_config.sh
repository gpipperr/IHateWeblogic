#!/bin/bash
# =============================================================================
# Script   : wls_lockout_config.sh
# Purpose  : Account lockout of the WebLogic realm (DISA STIG V-235936-38,
#            80-FMW-Architecture/stig_weblogic_forms_reports.md §5 step 3) and
#            the operational view the service users need:
#              1 current lockout settings (config.xml)
#              2 runtime of the lockout manager of every running server
#                (locked users now, invalid logins, lockouts) + lock state of
#                every realm user (WLST online, read-only)
#              3 lockout events in the server logs: BEA-090078 (locked, with
#                client address), BEA-090067 (unlocked) - last LOCKOUT_LOG_DAYS
#            --apply : threshold 3 (STIG), duration 30 min (Oracle's production
#                      mode check BEA-090978 warns below 30; STIG says 15 -
#                      30 is the stricter value), reset duration 15 min (STIG)
#            --undo  : WebLogic defaults 5 / 30 / 5
#            --unlock USER : clears the lockout of USER on every running server
#                      (e.g. RepRunner after a guessing attack) - no --apply needed
# Call     : ./07-Maintenance/wls_lockout_config.sh                    (show + plan)
#            ./07-Maintenance/wls_lockout_config.sh --apply [--threshold N --duration M --reset R]
#            ./07-Maintenance/wls_lockout_config.sh --undo --apply
#            ./07-Maintenance/wls_lockout_config.sh --unlock RepRunner
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

APPLY=false; UNDO=false; UNLOCK=""
THR="${WLS_LOCKOUT_THRESHOLD:-3}"; DUR="${WLS_LOCKOUT_DURATION:-30}"; RST="${WLS_LOCKOUT_RESET:-15}"
LOGDAYS="${LOCKOUT_LOG_DAYS:-30}"
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)     APPLY=true ;;
        --undo)      UNDO=true ;;
        --unlock)    shift; UNLOCK="${1:?--unlock needs a user name}" ;;
        --threshold) shift; THR="${1:-3}" ;;
        --duration)  shift; DUR="${1:-30}" ;;
        --reset)     shift; RST="${1:-15}" ;;
        --help|-h)
            printf "Usage: %s [--apply] [--threshold N --duration M --reset R] | --undo [--apply] | --unlock USER\n\n" "$(basename "$0")"
            printf "  %-14s %s\n" "--apply" "lockout threshold 3, duration 30 min, reset duration 15 min"
            printf "  %-14s %s\n" "--undo" "WebLogic defaults 5 / 30 / 5"
            printf "  %-14s %s\n" "--unlock USER" "clear the lockout of USER on every running server"
            exit 0 ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
    shift
done
$UNDO && { THR=5; DUR=30; RST=5; }
for _n in "$THR" "$DUR" "$RST"; do
    case "$_n" in ''|*[!0-9]*) fail "threshold / duration / reset must be numbers"; print_summary; exit 2 ;; esac
done
[ "$DUR" -lt 30 ] && warn "duration $DUR < 30 min – WebLogic logs BEA-090978 at every start in production mode"
CONFIG_XML="$DOMAIN_HOME/config/config.xml"
WLST="$ORACLE_HOME/oracle_common/common/bin/wlst.sh"

printLine
printf "\n\033[1m  IHateWeblogic – account lockout of the WebLogic realm\033[0m\n" | tee -a "$LOG_FILE"
printList "Domain" 20 "$DOMAIN_HOME"
if [ -n "$UNLOCK" ]; then printList "Mode" 20 "unlock $UNLOCK"
else printList "Mode" 20 "$($UNDO && printf 'UNDO – defaults 5 / 30 / 5' || printf 'threshold %s, duration %s min, reset %s min' "$THR" "$DUR" "$RST")$($APPLY || printf ' – dry-run')"; fi
printLine

load_weblogic_password > /dev/null || { fail "WebLogic password not loaded"; print_summary; exit 2; }
_url="${WL_ADMIN_URL:-t3://${WLS_LISTEN_ADDRESS:-localhost}:${WLS_ADMIN_PORT:-7001}}"

# _wlst MODE - show | apply | unlock; prints IHW:<key>:<value>
_wlst() {
    local py out; py="$(mktemp /tmp/wls_lockout_XXXXXX.py)"; chmod 600 "$py"
    cat > "$py" <<'WLST_EOF'
import os
_ihw_mode = os.environ['_IHW_MODE']
connect(os.environ['_IHW_WL_USER'], os.environ['_IHW_WL_PWD'], os.environ['_IHW_WL_URL'])
serverConfig()
cd('/')
_ihw_realm = cmo.getSecurityConfiguration().getDefaultRealm().getName()
_ihw_users = []
for _p in cmo.getSecurityConfiguration().getDefaultRealm().getAuthenticationProviders():
    try:
        _c = _p.listUsers('*', 0)
        while _p.haveCurrent(_c):
            _ihw_users.append(_p.getCurrentName(_c))
            _p.advance(_c)
        _p.close(_c)
    except:
        pass
if _ihw_mode == 'apply':
    edit()
    startEdit()
    cd('/')
    _m = cmo.getSecurityConfiguration().getDefaultRealm().getUserLockoutManager()
    _m.setLockoutEnabled(True)
    _m.setLockoutThreshold(int(os.environ['_IHW_THR']))
    _m.setLockoutDuration(long(os.environ['_IHW_DUR']))
    _m.setLockoutResetDuration(long(os.environ['_IHW_RST']))
    print('IHW:SET:lockout enabled, threshold ' + os.environ['_IHW_THR'] + ', duration ' + os.environ['_IHW_DUR'] + ' min, reset ' + os.environ['_IHW_RST'] + ' min')
    save()
    activate(block='true')
domainRuntime()
for _s in domainRuntimeService.getServerRuntimes():
    _n = _s.getName()
    try:
        _l = _s.getServerSecurityRuntime().lookupRealmRuntime(_ihw_realm).getUserLockoutManagerRuntime()
    except:
        print('IHW:RTERR:' + _n)
        continue
    if _ihw_mode == 'unlock':
        _u = os.environ['_IHW_UNLOCK']
        _was = _l.isLockedOut(_u)
        _l.clearLockout(_u)
        print('IHW:UNLOCK:' + _n + ':' + _u + ':was_locked=' + str(_was) + ':now_locked=' + str(_l.isLockedOut(_u)))
        continue
    print('IHW:RT:' + _n + ':locked_now=' + str(_l.getLockedUsersCurrentCount()) + ':invalid_logins=' + str(_l.getInvalidLoginAttemptsTotalCount()) + ':lockouts=' + str(_l.getUserLockoutTotalCount()))
    for _u in _ihw_users:
        if _l.isLockedOut(_u):
            print('IHW:LOCKED:' + _n + ':' + _u)
print('IHW:DONE')
disconnect()
WLST_EOF
    out="$(_IHW_MODE="$1" _IHW_THR="$THR" _IHW_DUR="$DUR" _IHW_RST="$RST" _IHW_UNLOCK="$UNLOCK" \
           _IHW_WL_USER="$WL_USER" _IHW_WL_PWD="$INTERNAL_WL_PWD" _IHW_WL_URL="$_url" "$WLST" "$py" 2>&1)"
    rm -f "$py"
    printf '%s\n' "$out" >> "${LOG_FILE:-/dev/null}"
    printf '%s\n' "$out" | grep -E '^IHW:|non-dynamic|restarted'
}

# --unlock: operational, no --apply
if [ -n "$UNLOCK" ]; then
    section "Unlock $UNLOCK"
    _r="$(_wlst unlock)"; INTERNAL_WL_PWD=""
    printf '%s' "$_r" | grep -q '^IHW:DONE' || { fail "WLST failed – see $LOG_FILE"; print_summary; exit 2; }
    printf '%s\n' "$_r" | sed -n 's/^IHW:UNLOCK://p' | while IFS=: read -r _s _u _w _n; do
        ok "$(printf "  %-14s %s  %s -> %s" "$_s" "$_u" "${_w#was_locked=}" "${_n#now_locked=}" | sed 's/True/locked/; s/False/unlocked/; s/True/locked/; s/False/unlocked/')"
    done
    print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
section "1. Current settings (config.xml)"
# =============================================================================
# config.xml writes the realm elements with the prefix "sec:" (14.1.2)
_ulm="$(tr -d '\n' < "$CONFIG_XML" | grep -oE '<(sec:)?user-lockout-manager>.*</(sec:)?user-lockout-manager>' | head -1 | sed 's#<\(/\{0,1\}\)sec:#<\1#g')"
_g() { printf '%s' "$_ulm" | grep -o "<$1>[^<]*" | sed 's/.*>//' | head -1; }
printList "  lockout enabled"        28 "$(_v="$(_g lockout-enabled)"; printf '%s' "${_v:-true (default)}")"
printList "  threshold"              28 "$(_v="$(_g lockout-threshold)"; printf '%s' "${_v:-5 (default)}")"
printList "  duration (min)"         28 "$(_v="$(_g lockout-duration)"; printf '%s' "${_v:-30 (default)}")"
printList "  reset duration (min)"   28 "$(_v="$(_g lockout-reset-duration)"; printf '%s' "${_v:-5 (default)}")"

# =============================================================================
section "2. Lockout runtime (WLST online, read-only)"
# =============================================================================
_cur="$(_wlst show)"
printf '%s' "$_cur" | grep -q '^IHW:DONE' || { fail "WLST failed – see $LOG_FILE (AdminServer running?)"; INTERNAL_WL_PWD=""; print_summary; exit 2; }
printf '%s\n' "$_cur" | sed -n 's/^IHW:RT://p' | while IFS=: read -r _s _ln _il _lo; do
    info "$(printf "  %-14s locked now %s, invalid logins %s, lockouts %s (since start)" "$_s" "${_ln#locked_now=}" "${_il#invalid_logins=}" "${_lo#lockouts=}")"
done
_locked="$(printf '%s\n' "$_cur" | sed -n 's/^IHW:LOCKED://p')"
if [ -n "$_locked" ]; then
    printf '%s\n' "$_locked" | while IFS=: read -r _s _u; do warn "  $_u is LOCKED on $_s – $(basename "$0") --unlock $_u"; done
else
    ok "  no realm user locked"
fi

# =============================================================================
section "3. Lockout events in the server logs (last $LOGDAYS days)"
# =============================================================================
_ev="$( { find "$DOMAIN_HOME/servers" -path '*/logs/*' -name '*.log*' -mtime "-$LOGDAYS" -type f -print0; } 2>/dev/null \
       | xargs -0 -r grep -h 'BEA-090078' 2>/dev/null \
       | sed -n 's/.*User \([^ ]*\) in security realm.*locking account for \([0-9]*\) minutes\. Client address: \([^ >]*[^ >.]\).*/\1;\3/p')"
if [ -z "$_ev" ]; then
    ok "  no lockout (BEA-090078) in the logs"
else
    printf '%s\n' "$_ev" | sort | uniq -c | sort -rn | head -10 | while read -r _c _x; do
        warn "$(printf "  %4s lockout message(s): user %s from %s" "$_c" "${_x%%;*}" "${_x#*;}")"
    done
    info "  WebLogic logs BEA-090078 at the lockout and again for each attempt on the locked account"
    info "  Service users (RepRunner, monUser, OracleSystemUser) in this list = jobs / monitoring fail while locked"
fi

# =============================================================================
section "4. Plan"
# =============================================================================
info "  lockout enabled, threshold $THR, duration $DUR min, reset duration $RST min"
info "  Exposure of the service users: realm logins over /em and /console (ADMIN_IP_RANGE only);"
info "  the standalone Reports server checks authid against the embedded LDAP via OPSS JSE – whether"
info "  those failures count for the realm lockout is part of the live test (stig_weblogic_forms_reports.md)"
if ! $APPLY; then
    warn "Dry-run – use --apply to change (backup of config.xml first)"
    INTERNAL_WL_PWD=""; print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
section "5. Apply"
# =============================================================================
backup_file "$CONFIG_XML" > /dev/null && ok "  config.xml backed up (config.xml.bak_<time> next to it)"
_res="$(_wlst apply)"; INTERNAL_WL_PWD=""
if printf '%s' "$_res" | grep -q '^IHW:DONE'; then
    printf '%s\n' "$_res" | sed -n 's/^IHW:SET://p' | while IFS= read -r _l; do ok "  $_l"; done
    if printf '%s' "$_res" | grep -qi 'non-dynamic\|restarted'; then
        info "  WebLogic: non-dynamic – restart the domain: ./01-Run/startStop.sh stop-all --apply; ./01-Run/startStop.sh start-all --apply"
    else
        ok "  active at once (dynamic attributes – no restart needed)"
    fi
    info "  Check: ./02-Checks/domain_secret_check.sh (sections 5 + 7)"
else
    fail "WLST failed – see $LOG_FILE; config.xml backup next to the file"
fi

print_summary
exit "$EXIT_CODE"
