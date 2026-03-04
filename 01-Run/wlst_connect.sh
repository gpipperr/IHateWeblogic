#!/bin/bash
# =============================================================================
# Script   : wlst_connect.sh
# Purpose  : Open an interactive WLST shell connected to the AdminServer.
#            Credentials are loaded from the encrypted weblogic_sec.conf.des3.
#            Uses WLST's interact() to remain in the shell after auto-connect.
# Call     : ./wlst_connect.sh
#            ./wlst_connect.sh --url t3://adminhost:7001
#            ./wlst_connect.sh --user weblogic
# Options  : --url    T3 URL to AdminServer (overrides WL_ADMIN_URL)
#            --user   WebLogic admin username (overrides WL_USER)
#            --help   Show usage
# Requires : wlst.sh ($FMW_HOME/oracle_common/common/bin/wlst.sh)
#            weblogic_sec.conf.des3 (created by 00-Setup/weblogic_sec.sh --apply)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 01-Run/README.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"

LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m IHateWeblogic_lib.sh not found: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"

check_env_conf "$ENV_CONF" || exit 2
source "$ENV_CONF"
init_log

# =============================================================================
# Arguments
# =============================================================================

OVERRIDE_URL=""
OVERRIDE_USER=""

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-26s %s\n" "--url T3_URL"  "Override AdminServer URL (default: from weblogic_sec.conf.des3)"
    printf "  %-26s %s\n" "--user NAME"   "Override WebLogic admin username"
    printf "  %-26s %s\n" "--help"        "Show this help"
    printf "\nExamples:\n"
    printf "  %s\n"                          "$(basename "$0")"
    printf "  %s --url t3://adminhost:7001\n" "$(basename "$0")"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --url)     OVERRIDE_URL="$2";   shift 2 ;;
        --user)    OVERRIDE_USER="$2";  shift 2 ;;
        --help|-h) _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
    esac
done

# =============================================================================
# Banner
# =============================================================================

printLine
section "WLST Connect – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-22s %s\n" "Host:"        "$(hostname -f 2>/dev/null || hostname)" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-22s %s\n" "DOMAIN_HOME:" "${DOMAIN_HOME}"                          | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-22s %s\n" "FMW_HOME:"    "${FMW_HOME}"                             | tee -a "${LOG_FILE:-/dev/null}"
printLine

# =============================================================================
# Load encrypted credentials
# =============================================================================

section "Loading Credentials"

SEC_CONF="${ROOT_DIR}/weblogic_sec.conf.des3"
load_weblogic_password "$SEC_CONF" || { print_summary; exit 2; }

# Apply overrides after loading (URL and user from weblogic_sec may be overridden)
[ -n "$OVERRIDE_URL" ]  && WL_ADMIN_URL="$OVERRIDE_URL"
[ -n "$OVERRIDE_USER" ] && WL_USER="$OVERRIDE_USER"

printf "  %-22s %s\n" "Admin URL:" "${WL_ADMIN_URL}" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-22s %s\n" "User:"      "${WL_USER}"      | tee -a "${LOG_FILE:-/dev/null}"

# =============================================================================
# Locate wlst.sh
# =============================================================================

section "Locating WLST"

WLST_SH="${FMW_HOME}/oracle_common/common/bin/wlst.sh"

if [ ! -x "$WLST_SH" ]; then
    # Alternate: under WL_HOME (FMW 12.x layout)
    _alt="${WL_HOME:-${FMW_HOME}/wlserver}/common/bin/wlst.sh"
    if [ -x "$_alt" ]; then
        WLST_SH="$_alt"
    else
        fail "wlst.sh not found: $WLST_SH"
        info "Check FMW_HOME in environment.conf – re-run 00-Setup/env_check.sh"
        print_summary
        exit 2
    fi
fi

ok "Found: $WLST_SH"

# =============================================================================
# Set domain environment
# =============================================================================

SETENV_SH="${DOMAIN_HOME}/bin/setDomainEnv.sh"
if [ -f "$SETENV_SH" ]; then
    info "Sourcing: $SETENV_SH"
    # shellcheck source=/dev/null
    source "$SETENV_SH" > /dev/null 2>&1
    ok "Domain environment set"
else
    warn "setDomainEnv.sh not found – using current environment"
    info "Expected: $SETENV_SH"
fi

if [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ]; then
    ok "JAVA_HOME: $JAVA_HOME"
else
    warn "JAVA_HOME not set or invalid – WLST may use system JDK"
    info "Set JAVA_HOME in environment.conf or run 00-Setup/env_check.sh"
fi

# =============================================================================
# Cleanup trap – removes temp script and clears password from environment
# =============================================================================

TMP_PY=""

_cleanup() {
    [ -n "$TMP_PY" ] && rm -f "$TMP_PY" 2>/dev/null
    INTERNAL_WL_PWD=""
    unset _IHW_WL_PWD _IHW_WL_USER _IHW_WL_URL 2>/dev/null || true
}

trap _cleanup EXIT INT TERM

# =============================================================================
# Build WLST bootstrap – credentials passed via environment variables
# (keeps password out of the temp .py file)
# =============================================================================

TMP_PY="$(mktemp /tmp/wlst_connect_XXXXXX.py)"
chmod 600 "$TMP_PY"

# Export env vars for the WLST Jython process; use distinct prefix to avoid
# collision with WebLogic's own environment variable names.
export _IHW_WL_USER="${WL_USER}"
export _IHW_WL_PWD="${INTERNAL_WL_PWD}"
export _IHW_WL_URL="${WL_ADMIN_URL}"

cat > "$TMP_PY" <<'PYEOF'
# WLST bootstrap - generated by wlst_connect.sh
import os

_wl_user = os.environ.get('_IHW_WL_USER', '')
_wl_pwd  = os.environ.get('_IHW_WL_PWD',  '')
_wl_url  = os.environ.get('_IHW_WL_URL',  '')

connect(_wl_user, _wl_pwd, _wl_url)

# Clear password from Jython namespace immediately after connect
del _wl_pwd

# Drop into interactive WLST mode - user can now issue WLST commands
interact()
PYEOF

ok "Bootstrap script ready (password passed via env, not stored in file)"

# =============================================================================
# Launch WLST
# =============================================================================

printLine
section "Starting WLST Interactive Shell"
printf "  Connecting to: %s as %s\n\n" "${WL_ADMIN_URL}" "${WL_USER}" \
    | tee -a "${LOG_FILE:-/dev/null}"
printf "  Type exit() or press Ctrl+D to leave WLST.\n\n" \
    | tee -a "${LOG_FILE:-/dev/null}"

"$WLST_SH" "$TMP_PY"
WLST_RC=$?

# =============================================================================
# Post-exit summary
# =============================================================================

printLine
if [ "$WLST_RC" -eq 0 ]; then
    ok "WLST session ended normally (rc=0)"
else
    warn "WLST exited with rc=${WLST_RC}"
fi

print_summary
exit $WLST_RC
