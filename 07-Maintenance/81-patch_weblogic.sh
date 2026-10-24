#!/bin/bash
# =============================================================================
# Script   : 81-patch_weblogic.sh
# Purpose  : Phase 8 maintenance wrapper - WLS FMW Basis layer, for patching
#            an ALREADY-RUNNING, already-installed environment (e.g. a future
#            CPU/CSPU cycle). Thin wrapper only: enforces the "domain must be
#            stopped" gate (not implemented anywhere before this script),
#            then delegates 100% of patch logic to the unchanged
#            09-Install/05-oracle_patch_weblogic.sh - no patch logic is
#            reimplemented here. That script is already idempotent (skips
#            whatever is already applied), so it is safe to re-run.
# Call     : ./07-Maintenance/81-patch_weblogic.sh [--apply] [--check-only] [--help]
# Delegates: 09-Install/05-oracle_patch_weblogic.sh "$@"  (same flags, unchanged)
# New code : require_wls_stopped()/check_wls_stopped() gate only
#            (00-Setup/IHateWeblogic_lib.sh)
# Workflow : see 07-Maintenance/README.md "Patching an Already-Running
#            Environment" for the full sequence (backup, stop, patch, start)
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
# shellcheck source=00-Setup/IHateWeblogic_lib.sh
source "$LIB"

check_env_conf "$ENV_CONF" || exit 2
source "$ENV_CONF"

init_log

# =============================================================================
# Parse arguments - forwarded verbatim to the delegated script, no translation
# =============================================================================
APPLY=false
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=true ;;
        --help)
            printf "Usage: %s [--apply] [--check-only] [--help]\n" "$(basename "$0")"
            printf "  Thin wrapper: enforces the WLS-stopped gate, then runs\n"
            printf "  09-Install/05-oracle_patch_weblogic.sh with the same flags.\n"
            printf "  Default: dry-run (shows what 05-oracle_patch_weblogic.sh would do)\n"
            printf "  --apply:      stop-gate is HARD (aborts if WLS is running), then patches\n"
            printf "  --check-only: stop-gate is a warning only, conflict-check without applying\n"
            exit 0
            ;;
    esac
done

# =============================================================================
# Pre-checks
# =============================================================================
section "Pre-checks"

if $APPLY; then
    require_wls_stopped || { EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
    confirm_snapshot    || { EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
else
    check_wls_stopped || warn "WebLogic is currently running - fine for dry-run/--check-only, but --apply will hard-fail until the domain is stopped (01-Run/startStop.sh stop-all --apply)"
fi

# =============================================================================
# Delegate to 09-Install/05-oracle_patch_weblogic.sh
# =============================================================================
section "Delegating to 09-Install/05-oracle_patch_weblogic.sh"
info "Running: 09-Install/05-oracle_patch_weblogic.sh $*"

"$ROOT_DIR/09-Install/05-oracle_patch_weblogic.sh" "$@"
DELEGATE_RC=$?

section "Summary (81-patch_weblogic.sh)"
# Same 3-tier convention as every script in this codebase: 0=OK, 1=WARN, 2=FAIL.
case "$DELEGATE_RC" in
    0) ok   "09-Install/05-oracle_patch_weblogic.sh completed (rc=0)" ;;
    1) warn "09-Install/05-oracle_patch_weblogic.sh completed with warnings (rc=1) - see log above" ;;
    *) fail "09-Install/05-oracle_patch_weblogic.sh failed (rc=$DELEGATE_RC)" ;;
esac
$APPLY && info "Next: 07-Maintenance/82-patch_forms_reports.sh --apply, then 01-Run/startStop.sh start-all --apply"

printLine
print_summary
[ "$DELEGATE_RC" -gt "$EXIT_CODE" ] && EXIT_CODE=$DELEGATE_RC
exit $EXIT_CODE
