#!/bin/bash
# =============================================================================
# Script   : 06-oracle_patch_forms_reports.sh
# Purpose  : Apply Forms & Reports specific patches after base F&R install.
#            Patches are listed in INSTALL_PATCHES_FR (oracle_software_version.conf).
#            If INSTALL_PATCHES_FR is empty, the script exits OK — no FR-specific
#            patches configured.
#            OPatch upgrade is NOT repeated here (done in 05-oracle_patch_weblogic.sh).
# Call     : ./09-Install/06-oracle_patch_forms_reports.sh
#            ./09-Install/06-oracle_patch_forms_reports.sh --apply
#            ./09-Install/06-oracle_patch_forms_reports.sh --check-only
#            ./09-Install/06-oracle_patch_forms_reports.sh --help
# Options  : (none)        Dry-run: show pending FR patches
#            --apply       Apply INSTALL_PATCHES_FR, skip already-installed
#            --check-only  Conflict check only, do not apply
#            --help        Show usage
# Runs as  : oracle
# Requires : 06-oracle_install_forms_reports.sh completed (ORACLE_HOME/forms/ exists)
#            05-oracle_patch_weblogic.sh completed (OPatch already upgraded)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/docs/06-oracle_patch_forms_reports.md
#            09-Install/oracle_software_version.conf
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"
SW_CONF="$SCRIPT_DIR/oracle_software_version.conf"

# --- Source library -----------------------------------------------------------
if [ ! -f "$LIB" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB" >&2; exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"

# --- Source environment.conf --------------------------------------------------
if [ ! -f "$ENV_CONF" ]; then
    printf "\033[31mFATAL\033[0m: environment.conf not found: %s\n" "$ENV_CONF" >&2
    printf "  Run first: 00-Setup/env_check.sh --apply\n" >&2; exit 2
fi
# shellcheck source=../environment.conf
source "$ENV_CONF"

# --- Source oracle_software_version.conf --------------------------------------
if [ ! -f "$SW_CONF" ]; then
    printf "\033[31mFATAL\033[0m: oracle_software_version.conf not found: %s\n" "$SW_CONF" >&2; exit 2
fi
# shellcheck source=./oracle_software_version.conf
source "$SW_CONF"

# --- Bootstrap log ------------------------------------------------------------
DIAG_LOG_DIR="${DIAG_LOG_DIR:-$ROOT_DIR/log/$(date +%Y%m%d)}"
init_log "$DIAG_LOG_DIR"

# =============================================================================
# Arguments
# =============================================================================

APPLY=false
CHECK_ONLY=false

_usage() {
    printf "Usage: %s [--apply] [--check-only] [--help]\n\n" "$(basename "$0")"
    printf "  %-14s %s\n" "(none)"       "Dry-run: show pending FR patches from INSTALL_PATCHES_FR"
    printf "  %-14s %s\n" "--apply"      "Apply patches from INSTALL_PATCHES_FR, skip already-installed"
    printf "  %-14s %s\n" "--check-only" "Conflict check only, do not apply"
    printf "  %-14s %s\n" "--help"       "Show this help"
    printf "\nRuns as: oracle\n"
    printf "Requires: 06-oracle_install_forms_reports.sh and 05-oracle_patch_weblogic.sh done.\n"
    exit 0
}

for _arg in "$@"; do
    case "$_arg" in
        --apply)       APPLY=true ;;
        --check-only)  CHECK_ONLY=true ;;
        --help|-h)     _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$_arg" >&2; exit 1 ;;
    esac
done
unset _arg

# =============================================================================
# Banner
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – Forms & Reports 14.1.2 Patch Apply\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"              | tee -a "$LOG_FILE"
printf "  Date        : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"  | tee -a "$LOG_FILE"
printf "  Apply       : %s\n" "$APPLY"                         | tee -a "$LOG_FILE"
printf "  Check-only  : %s\n" "$CHECK_ONLY"                    | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"                      | tee -a "$LOG_FILE"
printLine

# =============================================================================
# Pre-checks
# =============================================================================

section "Pre-checks"

# --- ORACLE_HOME + F&R install ------------------------------------------------
[ -n "$ORACLE_HOME" ] \
    && ok "ORACLE_HOME = $ORACLE_HOME" \
    || { fail "ORACLE_HOME not set in environment.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -d "$ORACLE_HOME/forms" ] \
    && ok "Forms installed: $ORACLE_HOME/forms" \
    || { fail "Forms not found – run 06-oracle_install_forms_reports.sh --apply first"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# --- OPatch binary -----------------------------------------------------------
OPATCH="$ORACLE_HOME/OPatch/opatch"
[ -x "$OPATCH" ] \
    && ok "OPatch found: $OPATCH" \
    || { fail "OPatch not executable: $OPATCH"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

OPATCH_VER="$("$OPATCH" version 2>/dev/null | grep 'OPatch Version' | awk '{print $NF}')"
ok "$(printf "%-28s %s" "OPatch version:" "${OPATCH_VER:-unknown}")"

# --- Java + PATCH_STORAGE ----------------------------------------------------
[ -x "$JDK_HOME/bin/java" ] \
    && ok "JDK_HOME = $JDK_HOME" \
    || { fail "java not executable: $JDK_HOME/bin/java"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -n "$PATCH_STORAGE" ] \
    && ok "PATCH_STORAGE = $PATCH_STORAGE" \
    || { fail "PATCH_STORAGE not set in environment.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# --- oraInst.loc (system-wide pointer, created by root in 03-root_user_oracle.sh) ---
ORA_INST_LOC="/etc/oraInst.loc"
INVPTR_ARGS=()
[ -f "$ORA_INST_LOC" ] \
    && { ok "oraInst.loc found: $ORA_INST_LOC"; INVPTR_ARGS=(-invPtrLoc "$ORA_INST_LOC"); } \
    || warn "oraInst.loc not found – opatch will use system default"

# --- INSTALL_PATCHES_FR -------------------------------------------------------
printList "INSTALL_PATCHES_FR" 28 "${INSTALL_PATCHES_FR:-(empty – no FR-specific patches)}"

if [ -z "${INSTALL_PATCHES_FR:-}" ]; then
    printf "\n" | tee -a "$LOG_FILE"
    ok "INSTALL_PATCHES_FR is empty – no FR-specific patches to apply."
    info "  To add FR patches: set INSTALL_PATCHES_FR in oracle_software_version.conf"
    info "  WLS patches (INSTALL_PATCHES) already cover the shared ORACLE_HOME."
    print_summary
    exit $EXIT_CODE
fi

# =============================================================================
# Current patch inventory
# =============================================================================

section "Installed Patch Inventory"

CURRENT_PATCHES="$("$OPATCH" lspatches "${INVPTR_ARGS[@]}" 2>/dev/null)"
printf "%s\n" "$CURRENT_PATCHES" | tee -a "$LOG_FILE"

PATCHES_TO_APPLY=""
for _p in $INSTALL_PATCHES_FR; do
    if echo "$CURRENT_PATCHES" | grep -q "^${_p};"; then
        ok "$(printf "Patch %-12s already installed – skip" "$_p")"
    else
        PATCHES_TO_APPLY="$PATCHES_TO_APPLY $_p"
        info "$(printf "Patch %-12s not installed – will check/apply" "$_p")"
    fi
done
unset _p
PATCHES_TO_APPLY="${PATCHES_TO_APPLY# }"

if [ -z "$PATCHES_TO_APPLY" ]; then
    ok "All patches from INSTALL_PATCHES_FR already installed – nothing to do"
    print_summary
    exit $EXIT_CODE
fi

# =============================================================================
# Dry-run exit
# =============================================================================

if ! $APPLY && ! $CHECK_ONLY; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "Dry-run – pass --apply to apply patches, --check-only for conflict check."
    info "Would apply patches (in order):"
    for _p in $PATCHES_TO_APPLY; do
        info "  Patch $_p  →  $PATCH_STORAGE/patches/$_p/"
    done
    unset _p
    print_summary
    exit $EXIT_CODE
fi

# =============================================================================
# Extract + Conflict check
# =============================================================================

section "Conflict Check"

STAGING_BASE="$ORACLE_BASE/tmp/fr_patches_$$"
mkdir -p "$STAGING_BASE" || {
    fail "Cannot create patch staging directory: $STAGING_BASE"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
}

for _p in $PATCHES_TO_APPLY; do
    PATCH_ZIP="$(ls "$PATCH_STORAGE/patches/$_p"/p${_p}_*.zip 2>/dev/null | head -1)"
    if [ -z "$PATCH_ZIP" ]; then
        fail "Patch ZIP not found for patch $_p in: $PATCH_STORAGE/patches/$_p/"
        fail "  Expected: p${_p}_*.zip"
        info "  Download first: 04-oracle_pre_download.sh --apply --mos"
        rm -rf "$STAGING_BASE"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi
    ok "Patch $_p ZIP: $(basename "$PATCH_ZIP")"

    info "Extracting patch $_p to staging..."
    unzip -q "$PATCH_ZIP" -d "$STAGING_BASE" || {
        fail "unzip failed: $PATCH_ZIP"
        rm -rf "$STAGING_BASE"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    }
    ok "Patch $_p extracted"
done
unset _p

CONFLICT_FOUND=false
for _p in $PATCHES_TO_APPLY; do
    PATCH_EXTRACT_DIR="$STAGING_BASE/$_p"
    [ -d "$PATCH_EXTRACT_DIR" ] || { warn "Patch dir not found after extract: $PATCH_EXTRACT_DIR – skip"; continue; }

    info "Conflict check: patch $_p"
    pushd "$PATCH_EXTRACT_DIR" > /dev/null
    "$OPATCH" prereq CheckConflictAgainstOHWithDetail \
        -ph . \
        "${INVPTR_ARGS[@]}" \
        2>&1 | tee -a "$LOG_FILE"
    PREREQ_RC=${PIPESTATUS[0]}
    popd > /dev/null

    [ "$PREREQ_RC" -eq 0 ] \
        && ok "No conflicts for patch $_p" \
        || { fail "Conflict check failed for patch $_p (rc=$PREREQ_RC)"; CONFLICT_FOUND=true; }
done
unset _p

if $CONFLICT_FOUND; then
    fail "Conflicts detected – aborting. Resolve conflicts before applying."
    rm -rf "$STAGING_BASE"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

if $CHECK_ONLY; then
    ok "Check-only mode – conflict check passed for all patches, none applied"
    rm -rf "$STAGING_BASE"
    print_summary; exit $EXIT_CODE
fi

# =============================================================================
# Apply Patches
# =============================================================================

section "Apply Patches"

PATCHES_APPLIED=""
for _p in $PATCHES_TO_APPLY; do
    PATCH_EXTRACT_DIR="$STAGING_BASE/$_p"

    printf "\n" | tee -a "$LOG_FILE"
    info "$(printf "Applying patch %-12s ..." "$_p")"
    printLine
    printf "  Apply started: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"

    pushd "$PATCH_EXTRACT_DIR" > /dev/null
    "$OPATCH" apply \
        -silent \
        -jdk "$JDK_HOME" \
        "${INVPTR_ARGS[@]}" \
        2>&1 | tee -a "$LOG_FILE"
    APPLY_RC=${PIPESTATUS[0]}
    popd > /dev/null

    printf "  Apply finished: %s  (rc=%s)\n" \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$APPLY_RC" | tee -a "$LOG_FILE"

    if [ "$APPLY_RC" -ne 0 ]; then
        fail "opatch apply failed for patch $_p (rc=$APPLY_RC)"
        fail "  Check: $ORACLE_HOME/cfgtoollogs/opatch/"
        rm -rf "$STAGING_BASE"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi
    ok "Patch $_p applied successfully"
    PATCHES_APPLIED="$PATCHES_APPLIED $_p"
done
unset _p

rm -rf "$STAGING_BASE"
info "Patch staging directory removed"

# =============================================================================
# Verification
# =============================================================================

section "Verification"

printf "\n" | tee -a "$LOG_FILE"
info "Running: opatch lspatches"
"$OPATCH" lspatches "${INVPTR_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"

FINAL_INVENTORY="$("$OPATCH" lspatches "${INVPTR_ARGS[@]}" 2>/dev/null)"
for _p in $PATCHES_APPLIED; do
    if echo "$FINAL_INVENTORY" | grep -q "^${_p};"; then
        PATCH_DESC="$(echo "$FINAL_INVENTORY" | grep "^${_p};" | cut -d';' -f2)"
        ok "$(printf "Patch %-12s confirmed: %s" "$_p" "$PATCH_DESC")"
    else
        fail "$(printf "Patch %-12s NOT found after apply!" "$_p")"
    fi
done
unset _p

printf "\n" | tee -a "$LOG_FILE"
info "Next step: create FMW repository schemas"
info "  00-Setup/database_rcu_sec.sh --apply  (if not already done)"
info "  09-Install/07-oracle_setup_repository.sh --apply"

# =============================================================================
print_summary
exit $EXIT_CODE
