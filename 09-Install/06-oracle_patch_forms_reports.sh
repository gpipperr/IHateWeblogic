#!/bin/bash
# =============================================================================
# Script   : 06-oracle_patch_forms_reports.sh
# Purpose  : Apply Forms & Reports specific patches after base F&R install.
#            Patches are listed in INSTALL_PATCHES_REPORTS / INSTALL_PATCHES_FORMS
#            (oracle_software_version.conf) and applied only for the component(s)
#            actually present in ORACLE_HOME (Reports-only installs supported —
#            Forms patches are skipped automatically if forms/ does not exist).
#            Superseded QPRs (see SUPERSEDES map in this script) are rolled back
#            automatically before the replacing patch is applied.
#            If no applicable patch is configured, the script exits OK.
#            OPatch upgrade is NOT repeated here (done in 05-oracle_patch_weblogic.sh).
# Call     : ./09-Install/06-oracle_patch_forms_reports.sh
#            ./09-Install/06-oracle_patch_forms_reports.sh --apply
#            ./09-Install/06-oracle_patch_forms_reports.sh --check-only
#            ./09-Install/06-oracle_patch_forms_reports.sh --help
# Options  : (none)        Dry-run: show pending Forms/Reports patches
#            --apply       Apply applicable patches, skip already-installed
#            --check-only  Conflict check only, do not apply
#            --help        Show usage
# Runs as  : oracle
# Requires : 06-oracle_install_forms_reports.sh completed (forms/ and/or reports/ exists)
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
    printf "  Run first: 00-Setup/init_env.sh --apply\n" >&2; exit 2
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
    printf "  %-14s %s\n" "(none)"       "Dry-run: show pending Forms/Reports patches for installed components"
    printf "  %-14s %s\n" "--apply"      "Apply applicable patches, skip already-installed"
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

# Component detection: this project supports Reports-only installs, so
# neither forms/ nor reports/ is individually mandatory – but at least one
# of them must exist (06-oracle_install_forms_reports.sh must have run).
HAS_FORMS=false
[ -d "$ORACLE_HOME/forms" ] && HAS_FORMS=true
HAS_REPORTS=false
[ -d "$ORACLE_HOME/reports" ] && HAS_REPORTS=true

if ! $HAS_FORMS && ! $HAS_REPORTS; then
    fail "Neither forms/ nor reports/ found under $ORACLE_HOME"
    fail "  Run 06-oracle_install_forms_reports.sh --apply first"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

$HAS_FORMS   && ok "Forms installed: $ORACLE_HOME/forms"   || info "Forms not installed – Forms-specific patches will be skipped"
$HAS_REPORTS && ok "Reports installed: $ORACLE_HOME/reports" || info "Reports not installed – Reports-specific patches will be skipped"

# Cross-check against the declared intent (informational only – the
# directory check above is the authoritative source of truth)
case "${INSTALL_COMPONENTS:-}" in
    FORMS_ONLY)
        $HAS_REPORTS && warn "INSTALL_COMPONENTS=FORMS_ONLY but reports/ exists in ORACLE_HOME" ;;
    REPORTS_ONLY)
        $HAS_FORMS && warn "INSTALL_COMPONENTS=REPORTS_ONLY but forms/ exists in ORACLE_HOME" ;;
esac

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

# --- Compose the wanted patch list from component detection -------------------
# INSTALL_PATCHES_REPORTS always applies (if reports/ exists); FORMS and the
# bidi one-off only apply when their precondition is met.
PATCHES_WANTED=""
$HAS_REPORTS && PATCHES_WANTED="$PATCHES_WANTED ${INSTALL_PATCHES_REPORTS:-}"
$HAS_FORMS   && PATCHES_WANTED="$PATCHES_WANTED ${INSTALL_PATCHES_FORMS:-}"
[ "${REPORTS_BIDIPARENTHESIS:-}" = "YES" ] && PATCHES_WANTED="$PATCHES_WANTED ${INSTALL_PATCHES_FR_OPTIONAL:-}"
PATCHES_WANTED="$(printf "%s" "$PATCHES_WANTED" | xargs)"   # normalize whitespace

printList "INSTALL_PATCHES_REPORTS" 28 "${INSTALL_PATCHES_REPORTS:-(empty)}"
printList "INSTALL_PATCHES_FORMS"   28 "${INSTALL_PATCHES_FORMS:-(empty)}"
printList "Wanted (this host)"      28 "${PATCHES_WANTED:-(none)}"

if [ -z "$PATCHES_WANTED" ]; then
    printf "\n" | tee -a "$LOG_FILE"
    ok "No Forms/Reports-specific patches apply to this host – nothing to do."
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

# --- Automatic rollback of superseded QPRs -------------------------------------
# A newer QPR supersedes (and conflicts with) the one it replaces – roll the
# old one back first, same idiom as the 23335292 pre-check in
# 05-oracle_patch_weblogic.sh.
declare -A SUPERSEDES=(
    [39600348]=38827528   # Reports QPR Aug 2026 supersedes Jan 2026
    [39842516]=38874285   # Forms QPR Sep 2026 supersedes Jan 2026
)
for _new in $PATCHES_WANTED; do
    _old="${SUPERSEDES[$_new]:-}"
    [ -z "$_old" ] && continue
    if echo "$CURRENT_PATCHES" | grep -q "^${_old};"; then
        warn "Patch $_old is superseded by $_new – rolling back $_old first"
        if $APPLY; then
            "$OPATCH" rollback -id "$_old" "${INVPTR_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"
            ROLLBACK_RC=${PIPESTATUS[0]}
            if [ "$ROLLBACK_RC" -ne 0 ]; then
                fail "Rollback of superseded patch $_old failed (rc=$ROLLBACK_RC)"
                EXIT_CODE=2; print_summary; exit $EXIT_CODE
            fi
            ok "Patch $_old rolled back"
            CURRENT_PATCHES="$("$OPATCH" lspatches "${INVPTR_ARGS[@]}" 2>/dev/null)"
        else
            info "Would roll back patch $_old before applying $_new (use --apply)"
        fi
    fi
done
unset _new _old

PATCHES_TO_APPLY=""
for _p in $PATCHES_WANTED; do
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
    ok "All applicable Forms/Reports patches already installed – nothing to do"
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
