#!/bin/bash
# =============================================================================
# Script   : 05-oracle_patch_weblogic.sh
# Purpose  : Update OPatch to the required version, then apply all WLS patches
#            listed in INSTALL_PATCHES (oracle_software_version.conf).
#            Must run after 05-oracle_install_weblogic.sh.
# Call     : ./09-Install/05-oracle_patch_weblogic.sh
#            ./09-Install/05-oracle_patch_weblogic.sh --apply
#            ./09-Install/05-oracle_patch_weblogic.sh --check-only
#            ./09-Install/05-oracle_patch_weblogic.sh --help
# Options  : (none)        Dry-run: show OPatch version, list patches to apply
#            --apply       Update OPatch (if needed) and apply INSTALL_PATCHES
#            --check-only  Run conflict check only, do not apply
#            --help        Show usage
# Runs as  : oracle
# Requires : JDK_HOME/bin/java, ORACLE_HOME/OPatch/opatch
#            PATCH_STORAGE/patches/<nr>/p<nr>_*.zip for each patch
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/docs/05-oracle_patch_weblogic.md
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
    printf "  %-14s %s\n" "(none)"       "Dry-run: show OPatch version, list patches to apply"
    printf "  %-14s %s\n" "--apply"      "Update OPatch (if needed) and apply INSTALL_PATCHES"
    printf "  %-14s %s\n" "--check-only" "Run conflict check only, do not apply"
    printf "  %-14s %s\n" "--help"       "Show this help"
    printf "\nRuns as: oracle\n"
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
printf "\n\033[1m  IHateWeblogic – FMW 14.1.2 OPatch Upgrade + Patch Apply\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"              | tee -a "$LOG_FILE"
printf "  Date        : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"  | tee -a "$LOG_FILE"
printf "  Apply       : %s\n" "$APPLY"                         | tee -a "$LOG_FILE"
printf "  Check-only  : %s\n" "$CHECK_ONLY"                    | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"                      | tee -a "$LOG_FILE"
printLine

# =============================================================================
# Helper: version comparison
# =============================================================================

# _version_lt  ver_a  ver_b
# Returns 0 (true) if ver_a < ver_b (strict), 1 otherwise.
_version_lt() {
    local a="$1" b="$2"
    [ "$a" = "$b" ] && return 1
    local lowest
    lowest="$(printf '%s\n%s' "$a" "$b" | sort -V | head -1)"
    [ "$lowest" = "$a" ]
}

# =============================================================================
# Pre-checks
# =============================================================================

section "Pre-checks"

# --- ORACLE_HOME --------------------------------------------------------------
[ -n "$ORACLE_HOME" ] \
    && ok "ORACLE_HOME = $ORACLE_HOME" \
    || { fail "ORACLE_HOME not set in environment.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -d "$ORACLE_HOME" ] \
    && ok "ORACLE_HOME exists" \
    || { fail "ORACLE_HOME does not exist – run 05-oracle_install_weblogic.sh --apply first"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# --- OPatch binary ------------------------------------------------------------
OPATCH="$ORACLE_HOME/OPatch/opatch"
[ -x "$OPATCH" ] \
    && ok "OPatch found: $OPATCH" \
    || { fail "OPatch not executable: $OPATCH"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# --- Java ---------------------------------------------------------------------
[ -n "$JDK_HOME" ] \
    && ok "JDK_HOME = $JDK_HOME" \
    || { fail "JDK_HOME not set in environment.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -x "$JDK_HOME/bin/java" ] \
    && ok "java found: $JDK_HOME/bin/java" \
    || { fail "java not executable: $JDK_HOME/bin/java"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# --- ORACLE_BASE + PATCH_STORAGE ----------------------------------------------
[ -n "$ORACLE_BASE" ] \
    && ok "ORACLE_BASE = $ORACLE_BASE" \
    || { fail "ORACLE_BASE not set in environment.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -n "$PATCH_STORAGE" ] \
    && ok "PATCH_STORAGE = $PATCH_STORAGE" \
    || { fail "PATCH_STORAGE not set in environment.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# --- INSTALL_PATCHES ----------------------------------------------------------
[ -n "$INSTALL_PATCHES" ] \
    && ok "INSTALL_PATCHES = $INSTALL_PATCHES" \
    || { fail "INSTALL_PATCHES not set in oracle_software_version.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# --- oraInst.loc – required for OPatch operations ----------------------------
# /etc/oraInst.loc is the system-wide pointer (root-owned, created by 03-root_user_oracle.sh)
ORA_INST_LOC="/etc/oraInst.loc"
ORA_INVENTORY="${ORACLE_INVENTORY:-$(dirname "$ORACLE_BASE")/oraInventory}"
[ -f "$ORA_INST_LOC" ] \
    && ok "oraInst.loc found: $ORA_INST_LOC" \
    || warn "oraInst.loc not found: $ORA_INST_LOC  (opatch will use system default)"

# Build -invPtrLoc argument array (empty if file absent)
INVPTR_ARGS=()
[ -f "$ORA_INST_LOC" ] && INVPTR_ARGS=(-invPtrLoc "$ORA_INST_LOC")

# =============================================================================
# OPatch Version Check
# =============================================================================

section "OPatch Version Check"

OPATCH_VER_CURRENT="$("$OPATCH" version 2>/dev/null | grep 'OPatch Version' | awk '{print $NF}')"
OPATCH_VER_MIN="${OPATCH_VERSION_MIN:-13.9.4.2.17}"
OPATCH_VER_TARGET="${OPATCH_VERSION_INSTALL:-13.9.4.2.22}"
OPATCH_UPGRADE_NR="${OPATCH_UPGRADE_PATCH_NR:-28186730}"

printList "Current OPatch"    28 "${OPATCH_VER_CURRENT:-unknown}"
printList "Minimum required"  28 "$OPATCH_VER_MIN  (required by INSTALL_PATCHES)"
printList "Install target"    28 "$OPATCH_VER_TARGET  (Patch $OPATCH_UPGRADE_NR)"
printList "INSTALL_PATCHES"   28 "$INSTALL_PATCHES"

OPATCH_NEEDS_UPGRADE=false
if [ -z "$OPATCH_VER_CURRENT" ]; then
    warn "Could not determine current OPatch version – assuming upgrade needed"
    OPATCH_NEEDS_UPGRADE=true
elif _version_lt "$OPATCH_VER_CURRENT" "$OPATCH_VER_MIN"; then
    warn "OPatch $OPATCH_VER_CURRENT < $OPATCH_VER_MIN – upgrade required"
    OPATCH_NEEDS_UPGRADE=true
else
    ok "OPatch $OPATCH_VER_CURRENT >= $OPATCH_VER_MIN – no upgrade needed"
fi

# =============================================================================
# Dry-run exit (before OPatch upgrade / conflict check)
# =============================================================================

if ! $APPLY && ! $CHECK_ONLY; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "Dry-run – pass --apply to upgrade OPatch and apply patches, --check-only for conflict check."
    if $OPATCH_NEEDS_UPGRADE; then
        info "Would upgrade OPatch: $OPATCH_VER_CURRENT → $OPATCH_VER_TARGET via Patch $OPATCH_UPGRADE_NR"
        [ -n "${WLS_SPB_PATCH_NR:-}" ] && info "  (preferring the build bundled inside SPB $WLS_SPB_PATCH_NR if present, else the standalone download)"
    fi
    if [ -n "${WLS_SPB_PATCH_NR:-}" ]; then
        if [ -n "${WLS_SPB_MARKER_PATCH:-}" ] && "$OPATCH" lspatches "${INVPTR_ARGS[@]}" 2>/dev/null | grep -q "^${WLS_SPB_MARKER_PATCH};"; then
            info "WLS Stack Patch Bundle $WLS_SPB_PATCH_NR already applied (marker $WLS_SPB_MARKER_PATCH present)"
        else
            info "Would apply WLS Stack Patch Bundle: $WLS_SPB_PATCH_NR (${WLS_SPB_VERSION:-see oracle_software_version.conf})"
            info "  via: opatch napply -phBaseFile <patchlist>  (needs ~4 GB free outside \$ORACLE_HOME)"
        fi
    fi
    info "Would apply patches (in order):"
    for _p in $INSTALL_PATCHES; do
        info "  Patch $_p  →  $PATCH_STORAGE/patches/$_p/"
    done
    unset _p
    print_summary
    exit $EXIT_CODE
fi

# =============================================================================
# WLS Stack Patch Bundle (SPB) – staging only. Unzipped ONCE here (reused by
# both the OPatch upgrade below and the napply step further down) instead of
# twice, since the archive is multi-GB. The SPB has been observed to bundle a
# newer opatch_generic.jar (tools/opatch/generic/) than the standalone Patch
# 28186730 download currently offers – see the caveat in
# docs/05-oracle_patch_weblogic.md.
# =============================================================================

SPB_DIR=""
SPB_STAGE=""
SPB_ALREADY_APPLIED=false
SPB_MARKER="${WLS_SPB_MARKER_PATCH:-}"

if [ -n "${WLS_SPB_PATCH_NR:-}" ]; then
    section "WLS Stack Patch Bundle ($WLS_SPB_PATCH_NR) – Staging"

    if [ -n "$SPB_MARKER" ] && "$OPATCH" lspatches "${INVPTR_ARGS[@]}" 2>/dev/null | grep -q "^${SPB_MARKER};"; then
        SPB_ALREADY_APPLIED=true
        ok "SPB $WLS_SPB_PATCH_NR already applied (marker patch $SPB_MARKER present) – skip staging"
    else
        SPB_ZIP="$(ls "$PATCH_STORAGE/patches/$WLS_SPB_PATCH_NR"/p${WLS_SPB_PATCH_NR}_*.zip 2>/dev/null | head -1)"
        if [ -z "$SPB_ZIP" ]; then
            fail "SPB ZIP not found for patch $WLS_SPB_PATCH_NR in: $PATCH_STORAGE/patches/$WLS_SPB_PATCH_NR/"
            fail "  Expected: p${WLS_SPB_PATCH_NR}_*.zip"
            info "  Download first: 04-oracle_pre_download.sh --apply --mos"
            EXIT_CODE=2; print_summary; exit $EXIT_CODE
        fi
        ok "SPB ZIP found: $(basename "$SPB_ZIP")"

        SPB_STAGE="$ORACLE_BASE/tmp/wls_spb_$$"
        mkdir -p "$SPB_STAGE" || {
            fail "Cannot create SPB staging directory: $SPB_STAGE"
            EXIT_CODE=2; print_summary; exit $EXIT_CODE
        }

        info "Unzipping SPB (this can take a while, several hundred MB, needs ~4 GB free)..."
        unzip -q "$SPB_ZIP" -d "$SPB_STAGE" || {
            fail "unzip failed: $SPB_ZIP"
            rm -rf "$SPB_STAGE"
            EXIT_CODE=2; print_summary; exit $EXIT_CODE
        }

        # Top-level directory name changes with the SPB version – discover it,
        # do not hardcode (e.g. WLS_SPB_14.1.2.0.260825).
        SPB_DIR="$(find "$SPB_STAGE" -maxdepth 1 -mindepth 1 -type d -name 'WLS_SPB_*' | head -1)"
        if [ -z "$SPB_DIR" ]; then
            fail "Could not find WLS_SPB_* directory after unzip in: $SPB_STAGE"
            rm -rf "$SPB_STAGE"
            EXIT_CODE=2; print_summary; exit $EXIT_CODE
        fi
        ok "SPB directory: $(basename "$SPB_DIR")"

        SPB_PATCHLIST="$SPB_DIR/binary_patches/${WLS_SPB_PATCHLIST_FILE:-linux64_patchlist.txt}"
        if [ ! -f "$SPB_PATCHLIST" ]; then
            fail "SPB patch list not found: $SPB_PATCHLIST"
            rm -rf "$SPB_STAGE"
            EXIT_CODE=2; print_summary; exit $EXIT_CODE
        fi
        ok "SPB patch list: $SPB_PATCHLIST"
    fi
else
    info "WLS_SPB_PATCH_NR not set in oracle_software_version.conf – skipping SPB staging"
fi

# =============================================================================
# OPatch Upgrade (--apply only, if version below minimum)
# =============================================================================

if $OPATCH_NEEDS_UPGRADE && $APPLY; then

    section "OPatch Upgrade – Patch $OPATCH_UPGRADE_NR"

    OPATCH_UPGRADE_ZIP=""
    OPATCH_SOURCE="standalone download"

    # Prefer the OPatch build bundled inside the SPB (staged above) – it has
    # been observed to be newer than the standalone Patch 28186730 download
    # (e.g. 13.9.4.2.24 bundled vs. 13.9.4.2.22 standalone). See the caveat
    # in docs/05-oracle_patch_weblogic.md.
    if [ -n "$SPB_DIR" ]; then
        OPATCH_UPGRADE_ZIP="$(ls "$SPB_DIR"/tools/opatch/generic/p${OPATCH_UPGRADE_NR}_*.zip 2>/dev/null | head -1)"
        [ -n "$OPATCH_UPGRADE_ZIP" ] && OPATCH_SOURCE="bundled in SPB $WLS_SPB_PATCH_NR"
    fi

    if [ -z "$OPATCH_UPGRADE_ZIP" ]; then
        OPATCH_UPGRADE_DIR="$PATCH_STORAGE/patches/$OPATCH_UPGRADE_NR"
        OPATCH_UPGRADE_ZIP="$(ls "$OPATCH_UPGRADE_DIR"/p${OPATCH_UPGRADE_NR}_*.zip 2>/dev/null | head -1)"

        if [ -z "$OPATCH_UPGRADE_ZIP" ]; then
            fail "OPatch upgrade ZIP not found in: $OPATCH_UPGRADE_DIR"
            fail "  Expected pattern: p${OPATCH_UPGRADE_NR}_*.zip"
            info "  Download first: 04-oracle_pre_download.sh --apply --mos"
            EXIT_CODE=2; print_summary; exit $EXIT_CODE
        fi
    fi
    ok "OPatch upgrade ZIP found ($OPATCH_SOURCE): $OPATCH_UPGRADE_ZIP"

    # --- Step 1: Check for patch 23335292 (must be rolled back first) ---------
    info "Checking for patch 23335292 (mandatory pre-check per OPatch README)..."
    if "$OPATCH" lspatches "${INVPTR_ARGS[@]}" 2>/dev/null | grep -q "^23335292"; then
        warn "Patch 23335292 found – rolling back before OPatch upgrade (required by README)"
        "$OPATCH" rollback -id 23335292 -oh "$ORACLE_HOME" "${INVPTR_ARGS[@]}" \
            2>&1 | tee -a "$LOG_FILE"
        ROLLBACK_RC=${PIPESTATUS[0]}
        if [ "$ROLLBACK_RC" -ne 0 ]; then
            fail "Rollback of patch 23335292 failed (rc=$ROLLBACK_RC)"
            EXIT_CODE=2; print_summary; exit $EXIT_CODE
        fi
        ok "Patch 23335292 rolled back"
        info "Waiting 20 seconds after rollback (required by OPatch README)..."
        sleep 20
        ok "Wait complete"
    else
        ok "Patch 23335292 not present – no rollback needed"
    fi

    # --- Step 2: Backup OPatch directory and Central Inventory ----------------
    section "OPatch Upgrade – Backup"

    BACKUP_TS="$(date +%Y%m%d)"
    OPATCH_BAK="$ORACLE_HOME/OPatch.bak_${BACKUP_TS}"
    INVENTORY_BAK="${ORA_INVENTORY}.bak_${BACKUP_TS}"

    info "Backing up $ORACLE_HOME/OPatch → $OPATCH_BAK"
    cp -a "$ORACLE_HOME/OPatch" "$OPATCH_BAK" \
        && ok "OPatch backup: $OPATCH_BAK" \
        || { fail "OPatch backup failed"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

    if [ -d "$ORA_INVENTORY" ]; then
        info "Backing up Central Inventory → $INVENTORY_BAK"
        cp -a "$ORA_INVENTORY" "$INVENTORY_BAK" \
            && ok "Inventory backup: $INVENTORY_BAK" \
            || warn "Inventory backup failed – continuing without backup"
    else
        info "oraInventory not found at $ORA_INVENTORY – skipping inventory backup"
    fi

    # --- Step 3: Unzip to staging and install via opatch_generic.jar ----------
    section "OPatch Upgrade – Install"

    OPATCH_STAGE="$ORACLE_BASE/tmp/opatch_upgrade_$$"
    mkdir -p "$OPATCH_STAGE" || {
        fail "Cannot create staging directory: $OPATCH_STAGE"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    }
    info "Staging directory: $OPATCH_STAGE"

    info "Unzipping: $(basename "$OPATCH_UPGRADE_ZIP")"
    unzip -q "$OPATCH_UPGRADE_ZIP" -d "$OPATCH_STAGE" || {
        fail "unzip failed: $OPATCH_UPGRADE_ZIP"
        rm -rf "$OPATCH_STAGE"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    }

    OPATCH_GENERIC_JAR="$OPATCH_STAGE/6880880/opatch_generic.jar"
    [ -f "$OPATCH_GENERIC_JAR" ] \
        && ok "opatch_generic.jar found" \
        || { fail "opatch_generic.jar not found after unzip: $OPATCH_GENERIC_JAR"; rm -rf "$OPATCH_STAGE"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

    # Use ORACLE_BASE/tmp as JVM tmpdir – avoids failures on noexec /tmp
    mkdir -p "$ORACLE_BASE/tmp"

    printList "Installer"   24 "$OPATCH_GENERIC_JAR"
    printList "ORACLE_HOME" 24 "$ORACLE_HOME"
    printLine

    printf "\n  OPatch install started: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"

    if [ "${#INVPTR_ARGS[@]}" -gt 0 ]; then
        "$JDK_HOME/bin/java" \
            -Djava.io.tmpdir="$ORACLE_BASE/tmp" \
            -jar "$OPATCH_GENERIC_JAR" \
            -silent \
            oracle_home="$ORACLE_HOME" \
            "${INVPTR_ARGS[@]}" \
            2>&1 | tee -a "$LOG_FILE"
    else
        "$JDK_HOME/bin/java" \
            -Djava.io.tmpdir="$ORACLE_BASE/tmp" \
            -jar "$OPATCH_GENERIC_JAR" \
            -silent \
            oracle_home="$ORACLE_HOME" \
            2>&1 | tee -a "$LOG_FILE"
    fi
    OPATCH_INSTALL_RC=${PIPESTATUS[0]}

    printf "  OPatch install finished: %s  (rc=%s)\n" \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$OPATCH_INSTALL_RC" | tee -a "$LOG_FILE"

    rm -rf "$OPATCH_STAGE"
    info "Staging directory removed"

    if [ "$OPATCH_INSTALL_RC" -ne 0 ]; then
        fail "opatch_generic.jar install failed (rc=$OPATCH_INSTALL_RC)"
        fail "  Check: $ORA_INVENTORY/logs/"
        fail "  See:   $ORACLE_BASE/tmp/OraInstall*/  and Doc ID 2759112.1"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi

    # --- Step 4: Verify new OPatch version ------------------------------------
    OPATCH_VER_CURRENT="$("$OPATCH" version 2>/dev/null | grep 'OPatch Version' | awk '{print $NF}')"
    printList "New OPatch version" 28 "${OPATCH_VER_CURRENT:-unknown}"

    if _version_lt "$OPATCH_VER_CURRENT" "$OPATCH_VER_MIN"; then
        fail "OPatch version after upgrade ($OPATCH_VER_CURRENT) still below minimum ($OPATCH_VER_MIN)"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi
    ok "OPatch upgraded successfully to $OPATCH_VER_CURRENT"

elif $OPATCH_NEEDS_UPGRADE && $CHECK_ONLY; then
    warn "OPatch upgrade required ($OPATCH_VER_CURRENT < $OPATCH_VER_MIN) – use --apply to upgrade"
fi

# =============================================================================
# WLS Stack Patch Bundle (SPB) – opatch napply, applied BEFORE the simple
# per-patch INSTALL_PATCHES loop below. Reuses the directory staged earlier
# (see "WLS Stack Patch Bundle ... – Staging" above) – no second unzip of the
# (multi-GB) archive.
# =============================================================================

if [ -n "${WLS_SPB_PATCH_NR:-}" ]; then

    section "WLS Stack Patch Bundle ($WLS_SPB_PATCH_NR) – Apply"

    if $SPB_ALREADY_APPLIED; then
        ok "SPB $WLS_SPB_PATCH_NR already applied (marker patch $SPB_MARKER present) – skip"
    elif [ -z "$SPB_DIR" ]; then
        fail "SPB was not staged earlier in this run – cannot apply"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    else
        # opatch napply README requires JAVA_HOME/ORACLE_HOME unset for this
        # call – scoped to a subshell only, no effect on the rest of this script.
        NAPPLY_MODE="-report"
        $APPLY && NAPPLY_MODE=""

        NAPPLY_OH="$ORACLE_HOME"   # capture before unsetting ORACLE_HOME below

        printf "\n" | tee -a "$LOG_FILE"
        info "Running: opatch napply ${NAPPLY_MODE:-(apply)} -oh $NAPPLY_OH -phBaseFile $SPB_PATCHLIST"
        (
            cd "$SPB_DIR/binary_patches" || exit 1
            unset JAVA_HOME
            unset ORACLE_HOME
            if [ -n "$NAPPLY_MODE" ]; then
                "$OPATCH" napply $NAPPLY_MODE -oh "$NAPPLY_OH" -phBaseFile "$SPB_PATCHLIST" "${INVPTR_ARGS[@]}"
            else
                "$OPATCH" napply -oh "$NAPPLY_OH" -phBaseFile "$SPB_PATCHLIST" "${INVPTR_ARGS[@]}"
            fi
        ) 2>&1 | tee -a "$LOG_FILE"
        NAPPLY_RC=${PIPESTATUS[0]}

        if [ "$NAPPLY_RC" -ne 0 ]; then
            fail "opatch napply failed for SPB $WLS_SPB_PATCH_NR (rc=$NAPPLY_RC)"
            fail "  Check: $ORACLE_HOME/cfgtoollogs/opatch/"
            rm -rf "$SPB_STAGE"
            EXIT_CODE=2; print_summary; exit $EXIT_CODE
        fi

        if $CHECK_ONLY; then
            ok "SPB napply report (--check-only) completed without errors"
        else
            if [ -n "$SPB_MARKER" ] && "$OPATCH" lspatches "${INVPTR_ARGS[@]}" 2>/dev/null | grep -q "^${SPB_MARKER};"; then
                ok "SPB $WLS_SPB_PATCH_NR applied – marker patch $SPB_MARKER confirmed"
            else
                fail "SPB napply reported success but marker patch $SPB_MARKER not found in lspatches"
                rm -rf "$SPB_STAGE"
                EXIT_CODE=2; print_summary; exit $EXIT_CODE
            fi
            info "Rollback (if ever needed): opatch nrollback -oh \$ORACLE_HOME -idFile $SPB_DIR/binary_patches/rollback_patchlist.txt"
            info "  Oracle advises against rolling back individual patches from the SPB"
        fi
    fi

    [ -n "$SPB_STAGE" ] && {
        rm -rf "$SPB_STAGE"
        info "SPB staging directory removed (ZIP kept in $PATCH_STORAGE/patches/$WLS_SPB_PATCH_NR/ for a future rollback)"
    }
else
    info "WLS_SPB_PATCH_NR not set in oracle_software_version.conf – skipping SPB apply"
fi

# =============================================================================
# Determine which patches still need to be applied
# =============================================================================

section "Installed Patch Inventory"

CURRENT_PATCHES="$("$OPATCH" lspatches "${INVPTR_ARGS[@]}" 2>/dev/null)"
printf "%s\n" "$CURRENT_PATCHES" | tee -a "$LOG_FILE"

PATCHES_TO_APPLY=""
for _p in $INSTALL_PATCHES; do
    if echo "$CURRENT_PATCHES" | grep -q "^${_p};"; then
        ok "$(printf "Patch %-12s already installed – skip" "$_p")"
    else
        PATCHES_TO_APPLY="$PATCHES_TO_APPLY $_p"
        info "$(printf "Patch %-12s not installed – will check/apply" "$_p")"
    fi
done
unset _p

PATCHES_TO_APPLY="${PATCHES_TO_APPLY# }"   # strip leading space

if [ -z "$PATCHES_TO_APPLY" ]; then
    ok "All patches from INSTALL_PATCHES already installed – nothing to do"
    print_summary
    exit $EXIT_CODE
fi

# =============================================================================
# Extract patches to staging and run conflict check
# =============================================================================

section "Conflict Check"

STAGING_BASE="$ORACLE_BASE/tmp/mw_patches_$$"
mkdir -p "$STAGING_BASE" || {
    fail "Cannot create patch staging directory: $STAGING_BASE"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
}

for _p in $PATCHES_TO_APPLY; do
    PATCH_ZIP="$(_select_patch_zip "$PATCH_STORAGE/patches/$_p" "$_p")"
    SELECT_RC=$?
    if [ "$SELECT_RC" -eq 1 ]; then
        fail "Patch ZIP not found for patch $_p in: $PATCH_STORAGE/patches/$_p/"
        fail "  Expected: p${_p}_*.zip"
        info "  Download first: 04-oracle_pre_download.sh --apply --mos"
        rm -rf "$STAGING_BASE"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    elif [ "$SELECT_RC" -eq 2 ]; then
        fail "Patch $_p has multiple product-version variants – cannot pick automatically:"
        for _f in "$PATCH_STORAGE/patches/$_p"/p${_p}_*.zip; do
            fail "  $(basename "$_f")"
        done
        unset _f
        fail "  None or more than one matches 14.1.2 – remove the unwanted variant(s) and re-run"
        rm -rf "$STAGING_BASE"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi
    ok "Patch $_p ZIP: $(basename "$PATCH_ZIP")"

    check_patch_zip "$PATCH_ZIP" "$_p" "$FMW_PRODUCT_RELEASE" || {
        fail "Patch $_p failed ZIP validation - aborting before extraction (see check_patch_zip message above)"
        rm -rf "$STAGING_BASE"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    }

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
    if [ ! -d "$PATCH_EXTRACT_DIR" ]; then
        warn "Patch directory not found after extract: $PATCH_EXTRACT_DIR – skipping conflict check"
        continue
    fi

    info "Conflict check: patch $_p"
    pushd "$PATCH_EXTRACT_DIR" > /dev/null
    "$OPATCH" prereq CheckConflictAgainstOHWithDetail \
        -ph . \
        "${INVPTR_ARGS[@]}" \
        2>&1 | tee -a "$LOG_FILE"
    PREREQ_RC=${PIPESTATUS[0]}
    popd > /dev/null

    if [ "$PREREQ_RC" -ne 0 ]; then
        fail "Conflict check failed for patch $_p (rc=$PREREQ_RC)"
        CONFLICT_FOUND=true
    else
        ok "No conflicts for patch $_p"
    fi
done
unset _p

if $CONFLICT_FOUND; then
    fail "Conflicts detected – aborting. Resolve conflicts before applying."
    rm -rf "$STAGING_BASE"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

# =============================================================================
# Check-only exit point
# =============================================================================

if $CHECK_ONLY; then
    ok "Check-only mode – conflict check passed for all patches, none applied"
    rm -rf "$STAGING_BASE"
    print_summary
    exit $EXIT_CODE
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

# --- Cleanup staging ----------------------------------------------------------
rm -rf "$STAGING_BASE"
info "Patch staging directory removed"

# =============================================================================
# Verification
# =============================================================================

section "Verification"

printf "\n" | tee -a "$LOG_FILE"
info "Running: opatch lspatches"
"$OPATCH" lspatches "${INVPTR_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"
VERIFY_RC=${PIPESTATUS[0]}

[ "$VERIFY_RC" -eq 0 ] \
    && ok "opatch lspatches successful" \
    || warn "opatch lspatches returned rc=$VERIFY_RC"

for _p in $PATCHES_APPLIED; do
    if "$OPATCH" lspatches "${INVPTR_ARGS[@]}" 2>/dev/null | grep -q "^${_p};"; then
        PATCH_DESC="$("$OPATCH" lspatches "${INVPTR_ARGS[@]}" 2>/dev/null | grep "^${_p};" | cut -d';' -f2)"
        ok "$(printf "Patch %-12s confirmed: %s" "$_p" "$PATCH_DESC")"
    else
        fail "$(printf "Patch %-12s NOT found in opatch lspatches after apply!" "$_p")"
    fi
done
unset _p

# =============================================================================
# Patch Report
# =============================================================================

section "Patch Report"

printf "\n  Patches from INSTALL_PATCHES:\n" | tee -a "$LOG_FILE"
FINAL_INVENTORY="$("$OPATCH" lspatches "${INVPTR_ARGS[@]}" 2>/dev/null)"

for _p in $INSTALL_PATCHES; do
    if echo "$FINAL_INVENTORY" | grep -q "^${_p};"; then
        PATCH_DESC="$(echo "$FINAL_INVENTORY" | grep "^${_p};" | cut -d';' -f2)"
        ok "$(printf "  %-12s INSTALLED  %s" "$_p" "$PATCH_DESC")"
    else
        fail "$(printf "  %-12s MISSING" "$_p")"
    fi
done
unset _p

printf "\n" | tee -a "$LOG_FILE"
info "OPatch version: $OPATCH_VER_CURRENT"
info "Next step: create domain or install Forms & Reports"

# =============================================================================
print_summary
exit $EXIT_CODE
