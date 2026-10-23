#!/bin/bash
# =============================================================================
# Script   : tns_admin_check.sh
# Purpose  : One Oracle Net directory for every process: check that TNS_ADMIN
#            of environment.conf is used everywhere a Forms / Reports /
#            WebLogic process or the oracle shell reads Oracle Net settings:
#              - the directory itself (tnsnames.ora, sqlnet.ora, aliases)
#              - Forms runtime        default.env           (written by 14-)
#              - Reports engines      rwserver.conf QS env  (written by 13-)
#              - Reports server/tools reports.sh            (written by 13-)
#              - WebLogic JVMs        setUserOverrides.sh   (THIS script --apply)
#              - oracle shell         ~oracle/.bash_profile (written by 03-, root)
#              - running processes    /proc/<pid>/environ of frmweb / rwserver
#            --apply writes only the setUserOverrides.sh block; for the other
#            files it names the script that owns them.
# Call     : ./02-Checks/tns_admin_check.sh
#            ./02-Checks/tns_admin_check.sh --apply
# Options  : --apply   Write the TNS_ADMIN block into setUserOverrides.sh (backup)
#            --help    Show usage
# Runs as  : oracle
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 02-Checks/README.md (tns_admin_check.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"

LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m Cannot find IHateWeblogic_lib.sh: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"
check_env_conf "$ENV_CONF" || exit 2
# shellcheck source=../environment.conf
source "$ENV_CONF"
# shellcheck source=../06-FormsDiag/forms_lib.sh
source "$ROOT_DIR/06-FormsDiag/forms_lib.sh"
# shellcheck source=../01-Run/reports_server_lib.sh
source "$ROOT_DIR/01-Run/reports_server_lib.sh"

init_log

APPLY=false
for _arg in "$@"; do
    case "$_arg" in
        --apply) APPLY=true ;;
        --help|-h)
            printf "Usage: %s [--apply]\n" "$(basename "$0")"
            printf "  (none)   check every place that reads Oracle Net settings\n"
            printf "  --apply  write the TNS_ADMIN block into setUserOverrides.sh\n"
            exit 0 ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$_arg" >&2; exit 2 ;;
    esac
done
unset _arg

TNS="${TNS_ADMIN:-}"
TNS="${TNS%/}"
MARK_BEGIN="# --- IHW TNS_ADMIN (02-Checks/tns_admin_check.sh) ---"
MARK_END="# --- IHW TNS_ADMIN END ---"

_cmp() {   # _cmp label value [owner-hint]
    local label="$1" val="${2%/}" hint="${3:-}"
    if [ -z "$val" ]; then
        warn "$(printf "%-26s not set%s" "$label" "${hint:+  -> $hint}")"
    elif [ "$val" = "$TNS" ]; then
        ok "$(printf "%-26s %s" "$label" "$val")"
    else
        warn "$(printf "%-26s %s  (environment.conf: %s)%s" "$label" "$val" "$TNS" "${hint:+  -> $hint}")"
    fi
}

printLine
section "TNS_ADMIN – one Oracle Net directory ($(date '+%Y-%m-%d %H:%M:%S'))"

# =============================================================================
# 1. environment.conf and the directory
# =============================================================================
section "environment.conf / directory"
if [ -z "$TNS" ]; then
    fail "TNS_ADMIN not set in environment.conf"
    info "  Set it with 09-Install/01-setup-interview.sh (default \$ORACLE_BASE/admin/tns_names)"
    print_summary; exit 2
fi
ok "$(printf "%-26s %s" "TNS_ADMIN:" "$TNS")"
if [ ! -d "$TNS" ]; then
    fail "Directory missing: $TNS (created by 09-Install/03-root_user_oracle.sh --apply)"
else
    if [ -f "$TNS/tnsnames.ora" ]; then
        _aliases="$(grep -oiE '^[A-Za-z0-9_.-]+[[:space:]]*=' "$TNS/tnsnames.ora" | sed 's/[[:space:]]*=$//' | xargs)"
        ok "$(printf "%-26s %s alias(es): %s" "tnsnames.ora:" "$(printf '%s\n' $_aliases | grep -c .)" "${_aliases:-(none)}")"
        unset _aliases
    else
        warn "No tnsnames.ora in $TNS – only EZConnect strings (host:port/service) work"
    fi
    if [ -f "$TNS/sqlnet.ora" ]; then
        _np="$(grep -iE '^[[:space:]]*NAMES\.DIRECTORY_PATH' "$TNS/sqlnet.ora" | tail -1 | sed 's/.*=[[:space:]]*//')"
        ok "$(printf "%-26s NAMES.DIRECTORY_PATH=%s" "sqlnet.ora:" "${_np:-(default)}")"
        unset _np
    else
        info "$(printf "%-26s %s" "sqlnet.ora:" "none (defaults: TNSNAMES, EZCONNECT)")"
    fi
fi

# =============================================================================
# 2. Forms runtime – default.env (14-)
# =============================================================================
if [ "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" != "REPORTS_ONLY" ]; then
    section "Forms runtime – default.env"
    if frm_find_files && [ -n "$FRM_ENV" ]; then
        _cmp "default.env:" "$(frm_env_get "$FRM_ENV" TNS_ADMIN)" "09-Install/14-oracle_setup_forms.sh --apply"
    else
        info "default.env not found (Forms not configured yet?)"
    fi
fi

# =============================================================================
# 3. Reports – rwserver.conf + reports.sh (13-)
# =============================================================================
if [ "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" != "FORMS_ONLY" ]; then
    section "Reports – rwserver.conf / reports.sh"
    _found=false
    for _conf in "$DOMAIN_HOME"/config/fmwconfig/components/ReportsServerComponent/*/rwserver.conf; do
        [ -f "$_conf" ] || continue
        _found=true
        _cmp "rwserver.conf [$(basename "$(dirname "$_conf")")]:" "$(rws_env_var "$_conf" TNS_ADMIN)" \
            "09-Install/13-oracle_setup_reports.sh --apply"
    done
    $_found || info "No standalone Reports server (rwserver.conf) found"
    _rsh="$DOMAIN_HOME/reports/bin/reports.sh"
    if [ -f "$_rsh" ]; then
        _cmp "reports.sh:" "$(sed -n 's/^TNS_ADMIN=\([^;]*\);.*/\1/p' "$_rsh" | tail -1 | tr -d '"')" \
            "09-Install/13-oracle_setup_reports.sh --apply"
    else
        info "reports.sh not found: $_rsh"
    fi
    unset _found _conf _rsh
fi

# =============================================================================
# 4. WebLogic JVMs – setUserOverrides.sh (this script)
# =============================================================================
section "WebLogic JVMs – setUserOverrides.sh"
UO="$DOMAIN_HOME/bin/setUserOverrides.sh"
_uo_val=""
[ -f "$UO" ] && _uo_val="$(sed -n "/^${MARK_BEGIN//\//\\/}/,/^${MARK_END}/s/^export TNS_ADMIN=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$UO" | tail -1)"
if [ "${_uo_val%/}" = "$TNS" ]; then
    ok "$(printf "%-26s %s (+ -Doracle.net.tns_admin)" "setUserOverrides.sh:" "$_uo_val")"
elif ! $APPLY; then
    _cmp "setUserOverrides.sh:" "$_uo_val" "$(basename "$0") --apply"
elif [ ! -f "$UO" ]; then
    fail "setUserOverrides.sh not found: $UO (domain created?)"
else
    backup_file "$UO" > /dev/null
    _tmp="$(mktemp)"
    sed "/^${MARK_BEGIN//\//\\/}/,/^${MARK_END}/d" "$UO" > "$_tmp"
    {
        printf '%s\n' "$MARK_BEGIN"
        printf '# one Oracle Net directory for all JVMs (value: environment.conf TNS_ADMIN)\n'
        printf 'export TNS_ADMIN="%s"\n' "$TNS"
        printf 'export EXTRA_JAVA_PROPERTIES="${EXTRA_JAVA_PROPERTIES} -Doracle.net.tns_admin=%s"\n' "$TNS"
        printf '%s\n' "$MARK_END"
    } >> "$_tmp"
    cat "$_tmp" > "$UO" && rm -f "$_tmp"
    ok "setUserOverrides.sh: TNS_ADMIN block written ($TNS) – effective at the next server start"
    unset _tmp
fi
unset _uo_val

# =============================================================================
# 5. oracle shell – .bash_profile (03-, root)
# =============================================================================
section "oracle shell – .bash_profile"
_prof="$(getent passwd oracle | cut -d: -f6)/.bash_profile"
if [ -r "$_prof" ]; then
    _cmp ".bash_profile:" "$(sed -n 's/^export TNS_ADMIN=//p' "$_prof" | tail -1 | tr -d '"')" \
        "09-Install/03-root_user_oracle.sh --apply (root)"
else
    info ".bash_profile of oracle not readable: $_prof"
fi
unset _prof

# =============================================================================
# 6. Running processes – what they really use
# =============================================================================
section "Running processes (/proc/<pid>/environ)"
_seen=false
for _p in $(pgrep -f '/bin/frmweb( |$)' 2>/dev/null | head -1) \
          $(pgrep -f 'rwserver server=' 2>/dev/null | head -1) \
          $(pgrep -f 'weblogic.Name=WLS_FORMS( |$)' 2>/dev/null | head -1) \
          $(pgrep -f 'weblogic.Name=WLS_REPORTS( |$)' 2>/dev/null | head -1); do
    [ -r "/proc/$_p/environ" ] || continue
    _seen=true
    _name="$(tr '\0' ' ' < "/proc/$_p/cmdline" | grep -oE 'frmweb|rwserver server=[^ ]+|weblogic.Name=[^ ]+' | head -1)"
    _cmp "PID $_p ${_name}:" "$(tr '\0' '\n' < "/proc/$_p/environ" | sed -n 's/^TNS_ADMIN=//p')" \
        "restart after fixing the files above"
done
$_seen || info "No frmweb / rwserver / WLS_FORMS / WLS_REPORTS process running"
unset _seen _p _name

printLine
print_summary
exit $EXIT_CODE
