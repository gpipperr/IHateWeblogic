#!/bin/bash
# =============================================================================
# Script   : 80-patch_java_os.sh
# Purpose  : Phase 8 maintenance wrapper - Java/OS layer, for an
#            ALREADY-RUNNING, already-installed environment. MVP is
#            READ-ONLY: runs 02-Checks/java_check.sh and prints a manual
#            JDK-upgrade checklist. Does NOT call 09-Install/02b-root_os_java.sh
#            automatically - its behavior when installing a NEWER JDK
#            alongside an already-provisioned, already-patched host (rather
#            than a fresh empty host) is unverified. Three open questions
#            before that can be wired in safely:
#              1. Its only idempotency guard is "[ -x "$JDK_HOME/bin/java" ]"
#                 against the CURRENT JDK_HOME - unverified whether
#                 installing a newer version side-by-side, and repointing
#                 `alternatives`, behaves correctly.
#              2. It does not touch environment.conf's JDK_HOME or
#                 $DOMAIN_HOME/bin/setDomainEnv.sh - a successful JDK
#                 install would not make WebLogic use the new JDK by itself.
#              3. Unverified whether the SecureRandom fix in java.security
#                 is correctly (re)applied to a newly-installed JDK sitting
#                 next to an existing one.
#            These need to be confirmed on a disposable host (not a live
#            production-like sandbox) before this script is extended with a
#            real --apply upgrade path. See 07-Maintenance/README.md.
# Call     : ./07-Maintenance/80-patch_java_os.sh [--help]
# Options  : (none)   Read-only: run java_check.sh + print checklist
#            --help   Show usage
# Delegates: 02-Checks/java_check.sh (unchanged, already read-only)
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
# Parse arguments
# =============================================================================
for arg in "$@"; do
    case "$arg" in
        --help)
            printf "Usage: %s [--help]\n" "$(basename "$0")"
            printf "  Read-only MVP: runs 02-Checks/java_check.sh, then prints a manual\n"
            printf "  JDK-upgrade checklist. No --apply flag yet - see script header for why.\n"
            exit 0
            ;;
    esac
done

# =============================================================================
# Pre-checks
# =============================================================================
section "Pre-checks"
check_wls_stopped || warn "WebLogic is currently running - fine just to view the current Java status below, but stop it first (01-Run/startStop.sh stop-all --apply) before actually performing a JDK upgrade"

# =============================================================================
# Current Java Environment
# =============================================================================
section "Current Java Environment"
"$ROOT_DIR/02-Checks/java_check.sh"
JC_RC=$?
[ "$JC_RC" -ne 0 ] && warn "02-Checks/java_check.sh reported issues (rc=$JC_RC) - review output above"

# =============================================================================
# Manual JDK Upgrade Checklist (CPU/CSPU cycle)
# =============================================================================
section "Manual JDK Upgrade Checklist (CPU/CSPU cycle)"
info "1. Download the new Oracle JDK tarball into \$PATCH_STORAGE"
info "2. Stop WebLogic: 01-Run/startStop.sh stop-all --apply"
info "3. Run: 09-Install/02b-root_os_java.sh --apply"
info "   NOT YET VERIFIED for an upgrade-alongside-existing-JDK scenario - see script header"
info "4. If the JDK install path changed, update JDK_HOME in environment.conf"
info "5. Re-run this script (80-patch_java_os.sh) to confirm java_check.sh now shows the new version"
info "6. Restart: 01-Run/startStop.sh start-all --apply"

printLine
print_summary
exit $EXIT_CODE
