#!/bin/bash
# =============================================================================
# Script   : apply_customer_conf.sh
# Purpose  : Way 2 of the customer import (09-Install/docs/17-customer_conf_import.md):
#            apply the customer overlay (CUSTOMER_CONF_DIR, written by
#            00-Setup/customer_conf_import.sh) to an EXISTING environment that
#            was built with the library. Only a sequence - no own logic:
#              1. 09-Install/14b-oracle_reports_fonts.sh   fonts, uifont.ali, cgicmd.dat
#              2. 09-Install/14-oracle_setup_forms.sh      formsweb.cfg, env files, WebUtil, jars
#              3. 09-Install/13-oracle_setup_reports.sh    Reports servers (+ <environment> per server)
#              4. --apply: 01-Run/startStop.sh stop-all / start-all (unless --no-restart)
#              5. --apply: 09-Install/15- smoke test, 09-Install/90-oracle_validate.sh
#            Without --apply every script shows what it would change.
# Call     : ./07-Maintenance/apply_customer_conf.sh [--apply] [--no-restart]
# Before   : ./07-Maintenance/backup_config.sh --apply
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
[ -f "$LIB" ] || { printf "Cannot find IHateWeblogic_lib.sh: %s\n" "$LIB" >&2; exit 2; }
source "$LIB"
check_env_conf "$ENV_CONF" || exit 2
source "$ENV_CONF"
init_log

APPLY=false; RESTART=true
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=true ;;
        --no-restart) RESTART=false ;;
        --help) sed -n '2,18p' "$0"; exit 0 ;;
        *) printf "Unknown option: %s (see --help)\n" "$arg" >&2; exit 2 ;;
    esac
done
FLAG=""; $APPLY && FLAG="--apply"

section "Customer overlay (Way 2)"
if [ -z "${CUSTOMER_CONF_DIR:-}" ] || [ ! -d "$CUSTOMER_CONF_DIR/forms" ]; then
    fail "CUSTOMER_CONF_DIR not set or without forms/ - run 00-Setup/customer_conf_import.sh --apply first"
    print_summary; exit 2
fi
printList "CUSTOMER_CONF_DIR" 20 "$CUSTOMER_CONF_DIR"
printList "Mode" 20 "$($APPLY && printf 'APPLY' || printf 'dry run')"
printList "Log (all steps)" 20 "${LOG_FILE:-}"
printList "Conf" 20 "$(readlink -f "$ENV_CONF")"
printList "Servers" 20 "${REPORTS_SERVER_INSTANCES:-<not set>}"
[ -f "$CUSTOMER_CONF_DIR/IMPORT_DECISIONS.md" ] && info "decisions: $CUSTOMER_CONF_DIR/IMPORT_DECISIONS.md"

# Reports server names: the overlay, REPORTS_SERVER_INSTANCES,
# REPORTS_SERVER_NAME and the domain must agree - otherwise 13- creates other
# servers than the overlay describes and 14b- writes cgicmd.dat for an old one
section "Reports server names"
_inst=" ${REPORTS_SERVER_INSTANCES:-} "
printList "REPORTS_SERVER_INSTANCES" 26 "${REPORTS_SERVER_INSTANCES:-<not set>}   (13- creates these)"
# the interview writes the array REPORTS_SERVER_NAMES as well - 13- uses
# REPORTS_SERVER_INSTANCES first; two different lists = the wrong servers
if [ "$(declare -p REPORTS_SERVER_NAMES 2>/dev/null | cut -c1-10)" = "declare -a" ]; then
    _names="${REPORTS_SERVER_NAMES[*]}"
else
    _names="${REPORTS_SERVER_NAMES:-}"
fi
if [ -n "$_names" ]; then
    printList "REPORTS_SERVER_NAMES" 26 "$_names"
    if [ "$(printf '%s\n' $_names | sort | xargs)" != "$(printf '%s\n' ${REPORTS_SERVER_INSTANCES:-} | sort | xargs)" ]; then
        warn "REPORTS_SERVER_NAMES and REPORTS_SERVER_INSTANCES differ - set both to the same list in $(basename "$(readlink -f "$ENV_CONF")")"
    fi
fi
unset _names
# a server of the list without overlay values (typo, e.g. repsrv_utf8 for repsrv_utf)
if ls "$CUSTOMER_CONF_DIR"/reports/*.env >/dev/null 2>&1; then
    for _n in ${REPORTS_SERVER_INSTANCES:-}; do
        [ -f "$CUSTOMER_CONF_DIR/reports/$_n.env" ] || \
            warn "$(printf "  %-16s in REPORTS_SERVER_INSTANCES, no customer values in the overlay (reports/%s.env) - typo? servers of the export: %s" "$_n" "$_n" "$(ls "$CUSTOMER_CONF_DIR"/reports/*.env | xargs -n1 basename | sed 's/\.env$//' | xargs)")"
    done
fi
for _e in "$CUSTOMER_CONF_DIR"/reports/*.env; do
    [ -f "$_e" ] || continue
    _n="$(basename "$_e" .env)"
    case "$_inst" in
        *" $_n "*) ok "$(printf "  %-16s overlay + REPORTS_SERVER_INSTANCES" "$_n")" ;;
        *) warn "$(printf "  %-16s in the overlay, NOT in REPORTS_SERVER_INSTANCES - 13- does not create it (add it in %s)" "$_n" "$(basename "$(readlink -f "$ENV_CONF")")")" ;;
    esac
done
if [ -n "${REPORTS_SERVER_NAME:-}" ]; then
    case "$_inst" in
        *" $REPORTS_SERVER_NAME "*) ok "$(printf "  %-16s REPORTS_SERVER_NAME (default server: cgicmd.dat, 15-, status tools)" "$REPORTS_SERVER_NAME")" ;;
        *) warn "$(printf "  REPORTS_SERVER_NAME=%s is not in REPORTS_SERVER_INSTANCES - 14b- would write cgicmd.dat for it; set it to one of: %s" "$REPORTS_SERVER_NAME" "${REPORTS_SERVER_INSTANCES:-?}")" ;;
    esac
fi
_cdir="${DOMAIN_HOME:-}/config/fmwconfig/components/ReportsServerComponent"
for _d in "$_cdir"/*/; do
    [ -f "$_d/rwserver.conf" ] || continue   # a server, not mbeans/ etc.
    _n="$(basename "$_d")"
    case "$_inst" in
        *" $_n "*) ;;
        *) info "$(printf "  %-16s exists in the domain, not in REPORTS_SERVER_INSTANCES - after the switch: 01-Run/startStop.sh stop %s, then 09-Install/13-oracle_setup_reports.sh --remove-server %s" "$_n" "$_n" "$_n")" ;;
    esac
done
unset _inst _e _n _cdir _d
if $APPLY; then
    _lb="$(ls -td "$ROOT_DIR"/07-Maintenance/ConfigBackup/*/ 2>/dev/null | head -1)"
    if [ -z "$_lb" ] || [ -n "$(find "$_lb" -maxdepth 0 -mmin +240 2>/dev/null)" ]; then
        warn "no configuration backup of the last 4 hours - run 07-Maintenance/backup_config.sh --apply first"
        if [ -t 0 ]; then
            read -r -p "  continue without a fresh backup? (yes/no) " _a
            [ "$_a" = yes ] || { print_summary; exit 2; }
        fi
    else
        ok "configuration backup: $_lb"
    fi
fi

RC=0
# every step: full output on the screen AND in this log (one file to send);
# the step script writes its own log as well
_step() {   # title script args...
    local t="$1"; shift
    section "$t"
    printf '\n# ===== %s - %s =====\n# $ %s\n' "$(date '+%F %T')" "$t" "$*" >> "${LOG_FILE:-/dev/null}"
    "$@" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; local rc=${PIPESTATUS[0]}
    printf '# ===== end %s: rc %s =====\n' "$t" "$rc" >> "${LOG_FILE:-/dev/null}"
    if [ "$rc" -eq 0 ]; then ok "$t: rc 0"
    elif [ "$rc" -eq 1 ]; then warn "$t: rc 1 (warnings - see the output above)"; [ "$RC" -lt 1 ] && RC=1
    else fail "$t: rc $rc"; RC=2; fi
    return "$rc"
}
_step "14b- Reports fonts / cgicmd.dat" "$ROOT_DIR/09-Install/14b-oracle_reports_fonts.sh" $FLAG
_step "14- Forms configuration"         "$ROOT_DIR/09-Install/14-oracle_setup_forms.sh" $FLAG
_step "13- Reports servers"             "$ROOT_DIR/09-Install/13-oracle_setup_reports.sh" $FLAG

if $APPLY && [ "$RC" -lt 2 ]; then
    if $RESTART; then
        _step "stop-all"  "$ROOT_DIR/01-Run/startStop.sh" stop-all --apply
        _step "start-all" "$ROOT_DIR/01-Run/startStop.sh" start-all --apply
        _step "15- smoke test" "$ROOT_DIR/09-Install/15-deploy-test-report-forms_template.sh" --apply
        _step "90- validate"   "$ROOT_DIR/09-Install/90-oracle_validate.sh"
    else
        info "--no-restart: the changes take effect after 01-Run/startStop.sh stop-all / start-all --apply"
    fi
elif $APPLY; then
    fail "a step failed - no restart; fix it and re-run (the scripts are idempotent), or 07-Maintenance/restore_config.sh --apply"
else
    info "Dry run - nothing changed. Apply with --apply (after backup_config.sh --apply)"
fi
[ "$RC" -gt "${EXIT_CODE:-0}" ] && EXIT_CODE="$RC"
print_summary
exit "$EXIT_CODE"
