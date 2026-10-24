#!/bin/bash
# =============================================================================
# Script   : 80-patch_java_os.sh
# Purpose  : Phase 8 maintenance wrapper – Java layer of an ALREADY-RUNNING,
#            already-installed environment: upgrade the Oracle JDK at JDK_HOME
#            (outside the Oracle Home) to the JDK of the patch repository.
#              - Since the NFTC for JDK 21 ended (September 2026) updates exist
#                only as MOS Patch JDK_PATCH_NR (oracle_software_version.conf).
#              - The patch is downloaded ONCE, with all other patches, by
#                09-Install/04-oracle_pre_download.sh --apply --mos into
#                $PATCH_STORAGE/patches/<JDK_PATCH_NR>/ – this script never
#                downloads: patch missing → WARN, not newer → OK.
#              - The installation logic lives once in
#                09-Install/02b-root_os_java.sh --upgrade-jdk (new JDK next to
#                the old one, JDK_HOME symlink repointed, SHA-256 against
#                SHA256_VALUES of the patch, SecureRandom fix of the new
#                java.security). This wrapper adds the hard "domain stopped"
#                gate and the follow-up checks.
#            The FMW-bundled JDK ($ORACLE_HOME/oracle_common/jdk, OPatch
#            component oracle.jdk) is NOT handled here – OPatch patch
#            FMW_JDK_PATCH_NR (to be determined) via 82-patch_forms_reports.sh.
# Call     : ./07-Maintenance/80-patch_java_os.sh            # read-only
#            ./07-Maintenance/80-patch_java_os.sh --apply    # upgrade (domain stopped)
# Options  : --apply   upgrade JDK_HOME from the patch repository
#            --help    Show usage
# Delegates: 09-Install/02b-root_os_java.sh --upgrade-jdk, 02-Checks/java_check.sh,
#            07-Maintenance/domain_jdk_path.sh (read-only check)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 07-Maintenance/README.md, 09-Install/docs/01-root_setup_java.md
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
APPLY=0
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        --help)
            printf "Usage: %s [--apply]\n" "$(basename "$0")"
            printf "  (none)   java_check.sh + which JDK is in the patch repository (dry-run of 02b --upgrade-jdk)\n"
            printf "  --apply  domain stopped → install the JDK of patches/<JDK_PATCH_NR>/ if newer\n"
            printf "  The JDK patch is downloaded by 09-Install/04-oracle_pre_download.sh --apply --mos\n"
            exit 0
            ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$arg" >&2; exit 2 ;;
    esac
done

UPGRADE_SH="$ROOT_DIR/09-Install/02b-root_os_java.sh"

# =============================================================================
# Pre-checks
# =============================================================================
section "Pre-checks"
if [ "$APPLY" -eq 1 ]; then
    require_wls_stopped || { print_summary; exit 2; }
else
    check_wls_stopped || warn "WebLogic is running – fine for this read-only view; --apply needs the domain stopped (01-Run/startStop.sh stop-all --apply)"
fi

# Other JVMs on JDK_HOME, outside the domain – startStop.sh does not stop them
# (e.g. ORDS standalone, 12-APEX-Ords, own systemd unit). 02b refuses to swap
# the JDK under a running JVM; name the service here (found 2026-10-24).
JDK_PIDS="$(pgrep -f "$(readlink -f "${JDK_HOME:-/nonexistent}")/bin/java|${JDK_HOME:-/nonexistent}/bin/java" 2>/dev/null)"
for _pid in $JDK_PIDS; do
    _unit="$(ps -o unit= -p "$_pid" 2>/dev/null | xargs)"
    if tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null | grep -q 'oracle.dbtools.cmdline.home'; then
        _what="ORDS"
    else
        _what="$(tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null | cut -c1-80)"
    fi
    _msg="$(printf "JVM on JDK_HOME: %s (PID %s%s)" "$_what" "$_pid" "${_unit:+, unit $_unit}")"
    if [ "$APPLY" -eq 1 ]; then
        fail "$_msg – stop it before the JDK upgrade"
        case "$_unit" in
            *.service) info "  sudo systemctl stop $_unit   (start it again after the upgrade)" ;;
        esac
    else
        warn "$_msg – --apply needs it stopped"
    fi
done
if [ "$APPLY" -eq 1 ] && [ -n "$JDK_PIDS" ]; then
    print_summary; exit 2
fi
unset _pid _unit _what _msg
if [ "$APPLY" -eq 1 ]; then
    confirm_snapshot || { print_summary; exit 2; }
fi

# =============================================================================
# JDK upgrade from the patch repository (logic in 02b-root_os_java.sh)
# =============================================================================
section "JDK_HOME – patch repository vs. installed"
_old_target="$(readlink -f "${JDK_HOME:-/nonexistent}" 2>/dev/null)"
if [ "$APPLY" -eq 1 ]; then
    "$UPGRADE_SH" --apply --upgrade-jdk
else
    "$UPGRADE_SH" --upgrade-jdk
fi
UP_RC=$?
_new_target="$(readlink -f "${JDK_HOME:-/nonexistent}" 2>/dev/null)"
[ "$UP_RC" -ge 2 ] && fail "02b-root_os_java.sh --upgrade-jdk failed (rc=$UP_RC) – see the output above"

# =============================================================================
# After an upgrade: domain must not pin the old jdk-21.0.x directory
# =============================================================================
if [ "$APPLY" -eq 1 ] && [ -n "$_old_target" ] && [ "$_old_target" != "$_new_target" ]; then
    section "Domain / oui pinned to the old JDK directory?"
    ok "$(printf "JDK_HOME switched: %s → %s" "$_old_target" "$_new_target")"
    "$SCRIPT_DIR/domain_jdk_path.sh"
    [ $? -ne 0 ] && warn "Pinned JDK paths found – run: 07-Maintenance/domain_jdk_path.sh --apply"
    info "Rollback: sudo ln -sfn $_old_target $JDK_HOME"
fi

# =============================================================================
# Current Java environment
# =============================================================================
section "Current Java Environment"
"$ROOT_DIR/02-Checks/java_check.sh"
JC_RC=$?
[ "$JC_RC" -ne 0 ] && warn "02-Checks/java_check.sh reported issues (rc=$JC_RC) – review output above"

if [ "$APPLY" -eq 1 ]; then
    info "Start the domain: 01-Run/startStop.sh start-all --apply"
fi
info "FMW-bundled JDK (oracle_common/jdk, OPatch component oracle.jdk): not handled here –"
info "  OPatch patch FMW_JDK_PATCH_NR (oracle_software_version.conf, still to be determined)"

printLine
print_summary
exit $EXIT_CODE
