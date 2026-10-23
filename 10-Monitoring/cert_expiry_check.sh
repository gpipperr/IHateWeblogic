#!/bin/bash
# =============================================================================
# Script   : cert_expiry_check.sh
# Purpose  : Scheduled certificate expiry check (cron, oracle) – calls the
#            read-only checks of 08-SSL and keeps their exit codes:
#              1. 08-SSL/ssl_config.sh --expiry   certificate Nginx serves
#              2. 08-SSL/ssl_local_ca.sh status   own root CA, server and
#                                                 code-signing certificate
#                                                 (only if the local CA exists)
#            WARN / FAIL also go to the system journal (logger -t ihw-cert),
#            so a log monitor or "journalctl -t ihw-cert" sees them.
#            --cron shows the crontab line, --cron --apply installs it in the
#            crontab of the running user (daily 06:15, idempotent, marker).
# Call     : ./10-Monitoring/cert_expiry_check.sh
#            ./10-Monitoring/cert_expiry_check.sh --cron [--apply]
#            ./10-Monitoring/cert_expiry_check.sh --cron --remove --apply
# Exit     : 0 ok, 1 a certificate expires within 30 days / missing,
#            2 expired / broken (the highest of the called checks)
# Doc      : 10-Monitoring/README.md, section "Certificate expiry"
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
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

init_log

CRON=false; APPLY=false; REMOVE=false
for _arg in "$@"; do
    case "$_arg" in
        --cron)   CRON=true ;;
        --apply)  APPLY=true ;;
        --remove) REMOVE=true ;;
        --help|-h)
            printf "Usage: %s [--cron [--remove] [--apply]]\n" "$(basename "$0")"
            printf "  (none)          run the certificate checks now\n"
            printf "  --cron          show the crontab line (daily 06:15)\n"
            printf "  --cron --apply  install it in the crontab of %s\n" "$(id -un)"
            printf "  --remove        with --cron --apply: remove the line\n"
            exit 0 ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$_arg" >&2; exit 2 ;;
    esac
done
unset _arg

MARK="# IHW cert_expiry_check"
CRON_LINE="15 6 * * * $SCRIPT_DIR/$(basename "$0") >/dev/null 2>&1 $MARK"

# =============================================================================
# --cron: show / install / remove the crontab line
# =============================================================================
if $CRON; then
    section "Crontab of $(id -un)"
    _cur="$(crontab -l 2>/dev/null)"
    if printf '%s\n' "$_cur" | grep -qF "$MARK"; then
        ok "installed: $(printf '%s\n' "$_cur" | grep -F "$MARK")"
        _have=true
    else
        info "not installed"
        _have=false
    fi
    if ! $APPLY; then
        info "line: $CRON_LINE"
        $REMOVE && info "Dry-run – --cron --remove --apply removes it" \
                || info "Dry-run – --cron --apply installs it"
    elif $REMOVE; then
        $_have && { printf '%s\n' "$_cur" | grep -vF "$MARK" | crontab - && ok "removed"; } || info "nothing to remove"
    elif $_have; then
        printf '%s\n' "$_cur" | grep -vF "$MARK" | { cat; printf '%s\n' "$CRON_LINE"; } | crontab - \
            && ok "updated: $CRON_LINE"
    else
        { [ -n "$_cur" ] && printf '%s\n' "$_cur"; printf '%s\n' "$CRON_LINE"; } | crontab - \
            && ok "installed: $CRON_LINE"
    fi
    unset _cur _have
    print_summary
    exit "$EXIT_CODE"
fi

# =============================================================================
# Run the checks
# =============================================================================
section "Certificate expiry ($(date '+%Y-%m-%d %H:%M:%S'))"
RC_MAX=0
_run() {   # _run LABEL SCRIPT ARGS…
    local label="$1" rc out; shift
    out="$("$@" 2>&1)"; rc=$?
    printf '%s\n' "$out" >> "${LOG_FILE:-/dev/null}"
    # the result lines of the called check (OK / WARN / FAIL), without colours
    printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -E '^ *(OK|WARN|FAIL) ' | grep -vE '^ *(OK|WARN|FAIL) *:' | sed 's/^/    /' \
        | tee -a "${LOG_FILE:-/dev/null}"
    case "$rc" in
        0) ok   "$(printf "%-28s ok" "$label")" ;;
        1) warn "$(printf "%-28s expires soon / missing (rc 1)" "$label")"
           logger -t ihw-cert -p user.warning "$label: certificate expires within 30 days or is missing - $LOG_FILE" 2>/dev/null ;;
        *) fail "$(printf "%-28s EXPIRED / broken (rc %s)" "$label" "$rc")"
           logger -t ihw-cert -p user.err "$label: certificate expired or broken - $LOG_FILE" 2>/dev/null ;;
    esac
    [ "$rc" -gt "$RC_MAX" ] && RC_MAX="$rc"
    return 0
}

_run "Nginx (served certificate)" "$ROOT_DIR/08-SSL/ssl_config.sh" --expiry
# SSL_CA_DIR lives in 08-SSL/ssl.conf (the SSL module's config), default as there
_ca_dir="$(sed -n 's/^SSL_CA_DIR="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$ROOT_DIR/08-SSL/ssl.conf" 2>/dev/null | tail -1)"
_ca_dir="${_ca_dir:-${ORACLE_BASE:-/u01/app/oracle}/admin/pki}"
if [ -d "$_ca_dir/ca" ]; then
    _run "Local CA / server / codesign" "$ROOT_DIR/08-SSL/ssl_local_ca.sh" status
else
    info "No local CA (08-SSL/ssl_local_ca.sh) – only the served certificate is checked"
fi

printLine
print_summary
[ "$RC_MAX" -gt "$EXIT_CODE" ] && EXIT_CODE="$RC_MAX"
exit "$EXIT_CODE"
