#!/bin/bash
# =============================================================================
# Script   : 02-db_patch_autoupgrade.sh
# Purpose  : Patch Oracle 19c ORACLE_HOME to current RU using AutoUpgrade
#            -mode create_home (offline, new patched home, no DB needed).
#            After patching: disable unused options (chopt) and relink for
#            Unified Auditing (uniaud_on).
# Call     : ./60-RCU-DB-19c/02-db_patch_autoupgrade.sh
#            ./60-RCU-DB-19c/02-db_patch_autoupgrade.sh --apply
#            ./60-RCU-DB-19c/02-db_patch_autoupgrade.sh --help
# Runs as  : oracle
# Requires : environment.conf, environment_db.conf, mos_sec.conf.des3
#            Java 11 (bundled: DB_ORACLE_HOME_BASE/jdk/bin/java)
# Ref      : 60-RCU-DB-19c/docs/03-db_patch_autoupgrade.md
#            https://mikedietrichde.com/2024/11/21/download-autoupgrade-directly-from-oracle-com/
#            https://mikedietrichde.com/2024/10/28/autoupgrades-patching-the-feature-you-waited-for/
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"
ENV_DB_CONF="$SCRIPT_DIR/environment_db.conf"

# --- Source library -----------------------------------------------------------
if [ ! -f "$LIB" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB" >&2; exit 2
fi
source "$LIB"

# --- Source configs -----------------------------------------------------------
for _f in "$ENV_CONF" "$ENV_DB_CONF"; do
    if [ ! -f "$_f" ]; then
        printf "\033[31mFATAL\033[0m: Config not found: %s\n" "$_f" >&2; exit 2
    fi
    source "$_f"
done
unset _f

DIAG_LOG_DIR="${DIAG_LOG_DIR:-$ROOT_DIR/log/$(date +%Y%m%d)}"
init_log "$DIAG_LOG_DIR"

# =============================================================================
# Arguments
# =============================================================================

APPLY=false
RESET_RECOVERY=false
CLEAN=false

_usage() {
    printf "Usage: %s [--apply] [--clean [--apply]] [--reset-recovery] [--help]\n\n" "$(basename "$0")"
    printf "  %-20s %s\n" "(none)"           "Dry-run: show config, no patching"
    printf "  %-20s %s\n" "--apply"          "Download patches + create_home + chopt + relink"
    printf "  %-20s %s\n" "--clean"          "Dry-run: show what --clean --apply would remove"
    printf "  %-20s %s\n" "--clean --apply"  "Remove broken home + clear AutoUpgrade state, then apply"
    printf "  %-20s %s\n" "--reset-recovery" "Clear AutoUpgrade recovery data only, then run apply"
    printf "  %-20s %s\n" "--help"           "Show this help"
    printf "\nRuns as: oracle\n"
    exit 0
}

for _arg in "$@"; do
    case "$_arg" in
        --apply)          APPLY=true ;;
        --clean)          CLEAN=true ;;
        --reset-recovery) APPLY=true; RESET_RECOVERY=true ;;
        --help|-h)        _usage ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$_arg" >&2; exit 1 ;;
    esac
done
unset _arg

# =============================================================================
# Banner
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – DB Patch AutoUpgrade (19c)\033[0m\n"  | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"                          | tee -a "$LOG_FILE"
printf "  Date        : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"             | tee -a "$LOG_FILE"
printf "  Mode        : %s\n" "$( $APPLY && printf 'APPLY' || printf 'DRY-RUN')" | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"                                 | tee -a "$LOG_FILE"
printLine

# =============================================================================
# Pre-checks
# =============================================================================

section "Pre-checks"

[ -n "${ORACLE_BASE:-}" ]           && ok "ORACLE_BASE           = $ORACLE_BASE"           || { fail "ORACLE_BASE not set";           EXIT_CODE=2; }
[ -n "${DB_ORACLE_HOME_BASE:-}" ]   && ok "DB_ORACLE_HOME_BASE   = $DB_ORACLE_HOME_BASE"   || { fail "DB_ORACLE_HOME_BASE not set";   EXIT_CODE=2; }
[ -n "${DB_ORACLE_HOME:-}" ]        && ok "DB_ORACLE_HOME        = $DB_ORACLE_HOME"        || { fail "DB_ORACLE_HOME not set";        EXIT_CODE=2; }
[ -n "${DB_AUTOUPGRADE_HOME:-}" ]   && ok "DB_AUTOUPGRADE_HOME   = $DB_AUTOUPGRADE_HOME"   || { fail "DB_AUTOUPGRADE_HOME not set";   EXIT_CODE=2; }
[ "$EXIT_CODE" -ne 0 ] && { print_summary; exit $EXIT_CODE; }

[ -d "$DB_ORACLE_HOME_BASE" ] \
    && ok "Source home exists: $DB_ORACLE_HOME_BASE" \
    || { fail "Source home not found – run 01-db_install_software.sh --apply first"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# --- Java for AutoUpgrade -----------------------------------------------------
# AutoUpgrade 26.x requires Java 11 (rejects Java 21: "must run with Java version 11").
# Try Oracle 19.3.0 bundled JDK first — if AutoUpgrade rejects it, fall back to
# system Java 11 (java-11-openjdk, installed by 00-root_db_os_baseline.sh).
JAVA_BIN=""
for _jbin in \
    "$DB_ORACLE_HOME_BASE/jdk/bin/java" \
    $(ls /usr/lib/jvm/java-11-openjdk*/bin/java 2>/dev/null | head -1) \
    "/usr/bin/java"; do
    [ -n "$_jbin" ] && [ -x "$_jbin" ] && { JAVA_BIN="$_jbin"; break; }
done
unset _jbin
if [ -n "$JAVA_BIN" ]; then
    ok "Java found: $JAVA_BIN ($("$JAVA_BIN" -version 2>&1 | head -1))"
else
    fail "No Java found — install java-11-openjdk (run 00-root_db_os_baseline.sh --apply)"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

# TLS protocol: Java 8 (1.8.0_xxx) does not support TLSv1.3 as a JVM property —
# forcing it throws IllegalArgumentException.  Use TLSv1.2 for Java 8, TLSv1.3 for 11+.
if "$JAVA_BIN" -version 2>&1 | grep -q '"1\.8\.'; then
    AU_TLS="-Dhttps.protocols=TLSv1.2"
    ok "TLS mode: TLSv1.2  (Java 8 — TLSv1.3 not supported as JVM property)"
else
    AU_TLS="-Dhttps.protocols=TLSv1.3"
    ok "TLS mode: TLSv1.3"
fi

# --- MOS credentials ---------------------------------------------------------
MOS_SEC_FILE="${MOS_SEC_FILE:-$ROOT_DIR/mos_sec.conf.des3}"
[ -f "$MOS_SEC_FILE" ] \
    && ok "MOS credentials file: $MOS_SEC_FILE" \
    || { fail "MOS credentials not found: $MOS_SEC_FILE"
         info "  Run first: 00-Setup/mos_sec.sh --apply"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# --- Target home must not already be the same as source ---------------------
if [ "$DB_ORACLE_HOME" = "$DB_ORACLE_HOME_BASE" ]; then
    fail "DB_ORACLE_HOME and DB_ORACLE_HOME_BASE must be different directories"
    info "  DB_ORACLE_HOME_BASE = unpatched 19.3 base"
    info "  DB_ORACLE_HOME      = patched target (e.g. product/19.24.0/db_home1)"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

# =============================================================================
# AutoUpgrade setup
# =============================================================================

section "AutoUpgrade Setup"

AU_JAR="$DB_AUTOUPGRADE_HOME/bin/autoupgrade.jar"
AU_CONFIG="$DB_AUTOUPGRADE_HOME/config/db19patch.cfg"
AU_KEYSTORE_CFG="$DB_AUTOUPGRADE_HOME/config/keystore.cfg"

printList "AutoUpgrade home"   30 "$DB_AUTOUPGRADE_HOME"
printList "autoupgrade.jar"    30 "$AU_JAR"
printList "Patch config"       30 "$AU_CONFIG"
printList "Target RU"          30 "${DB_TARGET_RU:-19.CURRENT}"
printList "Source home"        30 "$DB_ORACLE_HOME_BASE"
printList "Target home"        30 "$DB_ORACLE_HOME"

# =============================================================================
# Clean – Reset broken AutoUpgrade state
# =============================================================================
# Use after a failed create_home run where the target home is corrupt/missing
# but AutoUpgrade still holds PATCH109 recovery state and the Oracle Inventory
# may still have a stale entry for the broken home.
#
# Steps:
#   1. detachHome  – removes stale Oracle Inventory entry (safe if not registered)
#   2. rm -rf      – removes the broken target home directory
#   3. -clear_recovery_data – resets AutoUpgrade PATCH109 job state
#
# Preserved (not touched):
#   autoupgrade.jar, patchdir/ (downloaded patches + Gold Image), keystore/
# =============================================================================

if $CLEAN; then
    section "Clean – Reset AutoUpgrade State"

    if ! $APPLY; then
        info "Dry-run: the following would be cleaned (use --clean --apply to execute):"
        printf "\n" | tee -a "$LOG_FILE"
        info "  1. detachHome from Oracle Inventory:"
        info "       $DB_ORACLE_HOME/oui/bin/runInstaller -silent -detachHome"
        info "       ORACLE_HOME=$DB_ORACLE_HOME"
        [ -d "$DB_ORACLE_HOME" ] \
            && warn "     (target home EXISTS on disk)" \
            || info "     (target home already absent — detach still attempted)"
        printf "\n" | tee -a "$LOG_FILE"
        info "  2. Remove target home directory:"
        info "       rm -rf $DB_ORACLE_HOME"
        printf "\n" | tee -a "$LOG_FILE"
        info "  3. Clear AutoUpgrade recovery data:"
        info "       java -jar autoupgrade.jar -patch -clear_recovery_data -jobs 1"
        printf "\n" | tee -a "$LOG_FILE"
        info "  Preserved (not touched):"
        info "    $AU_JAR"
        info "    $DB_AUTOUPGRADE_HOME/patchdir/"
        info "    $DB_AUTOUPGRADE_HOME/keystore/"
        printf "\n" | tee -a "$LOG_FILE"
        warn "Run --clean --apply to execute"
        print_summary; exit $EXIT_CODE
    fi

    # --- Execute clean ---

    # 1. Detach target home from Oracle Inventory (safe even if never registered)
    info "Step 1: detachHome from Oracle Inventory ..."
    if [ -x "$DB_ORACLE_HOME/oui/bin/runInstaller" ]; then
        "$DB_ORACLE_HOME/oui/bin/runInstaller" \
            -silent -detachHome \
            "ORACLE_HOME=$DB_ORACLE_HOME" \
            2>&1 | tee -a "$LOG_FILE" || true
        ok "detachHome completed"
    else
        info "  runInstaller not found in target home — skipping detachHome"
        info "  ($DB_ORACLE_HOME/oui/bin/runInstaller)"
    fi

    # 2. Remove broken target home directory
    info "Step 2: removing target home directory ..."
    if [ -d "$DB_ORACLE_HOME" ]; then
        rm -rf "$DB_ORACLE_HOME"
        ok "Removed: $DB_ORACLE_HOME"
    else
        ok "Target home already absent: $DB_ORACLE_HOME"
    fi

    # 3. Clear AutoUpgrade recovery data (removes PATCH109 job state)
    info "Step 3: clearing AutoUpgrade recovery data ..."
    if [ -f "$AU_JAR" ] && [ -f "$AU_CONFIG" ]; then
        "$JAVA_BIN" $AU_TLS \
            -jar "$AU_JAR" \
            -config "$AU_CONFIG" \
            -patch -clear_recovery_data -jobs 1 \
            2>&1 | tee -a "$LOG_FILE" || true
        ok "AutoUpgrade recovery data cleared"
    else
        [ -f "$AU_JAR" ]    || warn "  autoupgrade.jar not found — recovery data NOT cleared"
        [ -f "$AU_CONFIG" ] || warn "  patch config not found  — recovery data NOT cleared"
    fi

    ok "Clean completed — continuing with --apply"
    printf "\n" | tee -a "$LOG_FILE"
fi

if ! $APPLY; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "Dry-run – use --apply to patch."
    print_summary; exit $EXIT_CODE
fi

# =============================================================================
# 1. Create AutoUpgrade directory structure
# =============================================================================

section "AutoUpgrade Directories"

for _dir in \
    "$DB_AUTOUPGRADE_HOME/bin" \
    "$DB_AUTOUPGRADE_HOME/logs" \
    "$DB_AUTOUPGRADE_HOME/config" \
    "$DB_AUTOUPGRADE_HOME/patchdir" \
    "$DB_AUTOUPGRADE_HOME/keystore"; do
    mkdir -p "$_dir"
    ok "$(printf "  %-50s" "$_dir")"
done
unset _dir

# =============================================================================
# 2. Download autoupgrade.jar (direct from oracle.com — no MOS auth required)
# =============================================================================

section "Download autoupgrade.jar"

AU_DOWNLOAD_URL="https://download.oracle.com/otn-pub/otn_software/autoupgrade.jar"

if [ -f "$AU_JAR" ]; then
    ok "autoupgrade.jar already present: $AU_JAR"
    info "  Delete and re-run to force update to latest version"
else
    info "Downloading autoupgrade.jar from oracle.com (no auth required) ..."
    info "  Source: $AU_DOWNLOAD_URL"
    if curl -fsSL \
        -o "$AU_JAR" \
        "$AU_DOWNLOAD_URL" 2>&1 | tee -a "$LOG_FILE"; then
        ok "autoupgrade.jar downloaded: $AU_JAR"
    else
        fail "Download failed – download manually:"
        info "  curl -fsSL $AU_DOWNLOAD_URL -o $AU_JAR"
        info "  Reference: https://mikedietrichde.com/2024/11/21/download-autoupgrade-directly-from-oracle-com/"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi
fi

# --- Verify jar ---------------------------------------------------------------
"$JAVA_BIN" -jar "$AU_JAR" -version 2>&1 | head -2 | while IFS= read -r _line; do
    ok "  $_line"
done

# =============================================================================
# 3. MOS Keystore (for patch download from MOS)
# =============================================================================

section "MOS Keystore"

info "Loading MOS credentials from: $MOS_SEC_FILE"
unset MOS_USER MOS_PWD
if ! load_secrets_file "$MOS_SEC_FILE"; then
    fail "Could not decrypt MOS credentials"
    info "  Run: 00-Setup/mos_sec.sh --apply"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

ok "MOS_USER decrypted: ${MOS_USER}"
ok "MOS_PWD  decrypted (${#MOS_PWD} chars)"

# Write keystore config (global.global_log_dir required to avoid /tmp fallback)
cat > "$AU_KEYSTORE_CFG" << KEOF
global.global_log_dir=${DB_AUTOUPGRADE_HOME}/logs
global.keystore=${DB_AUTOUPGRADE_HOME}/keystore
KEOF

# -load_password (AutoUpgrade 26.x) is an interactive console.
# For a NEW keystore: prompts for keystore encryption password (x2), then MOS credentials.
# Keystore encryption password: deterministic per-host (not sensitive).
# expect handles each prompt reliably regardless of timing; stdin pipe is fallback.
_ks_dir="${DB_AUTOUPGRADE_HOME}/keystore"
_ks_done_flag="${_ks_dir}/.mos_configured"

if [ -f "$_ks_done_flag" ]; then
    ok "MOS keystore already configured — skipping (delete $_ks_done_flag to re-run)"
    MOS_PWD="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    unset MOS_USER MOS_PWD
else
    _ks_pass="IHateWeblogic-$(hostname -s 2>/dev/null || printf 'oracle')"
    info "Setting MOS credentials in AutoUpgrade keystore (-load_password) ..."

    if command -v expect >/dev/null 2>&1; then
        # Pass all values via environment — no credentials written to disk
        export _AU_KS_BIN="$JAVA_BIN" _AU_KS_JAR="$AU_JAR" _AU_KS_CFG="$AU_KEYSTORE_CFG"
        export _AU_KS_PASS="$_ks_pass" _AU_MOS_USER="$MOS_USER" _AU_MOS_PWD="$MOS_PWD"
        export _AU_KS_TLS="$AU_TLS"
        _ks_out=$(expect << 'EXPEOF' 2>&1
set timeout 60
spawn $env(_AU_KS_BIN) $env(_AU_KS_TLS) \
      -jar $env(_AU_KS_JAR) -patch -config $env(_AU_KS_CFG) -load_password

# New keystore: "Enter password:" (x2). Existing keystore: single unlock prompt.
expect {
    "Enter password again:" { send "$env(_AU_KS_PASS)\r"; exp_continue }
    "Enter password:"       { send "$env(_AU_KS_PASS)\r"; exp_continue }
    "MOS>"  { }
    timeout { puts "TIMEOUT waiting for MOS> prompt"; exit 1 }
    eof     { puts "EOF before MOS> prompt"; exit 1 }
}

# No "group mos" needed — add-user works directly at the MOS> prompt
send "add -user $env(_AU_MOS_USER)\r"
expect "Enter your secret/Password:"
send "$env(_AU_MOS_PWD)\r"
expect "Re-enter your secret/Password:"
send "$env(_AU_MOS_PWD)\r"
expect "MOS>"
send "exit\r"

# Two YES/NO prompts after exit:
# 1. "Save the AutoUpgrade Patching keystore before exiting [YES|NO] ?"
# 2. "Convert the AutoUpgrade Patching keystore to auto-login [YES|NO] ?"
expect -re {YES|NO}
send "YES\r"
expect -re {YES|NO}
send "YES\r"

expect eof
EXPEOF
)
        unset _AU_KS_BIN _AU_KS_JAR _AU_KS_CFG _AU_KS_PASS _AU_MOS_USER _AU_MOS_PWD _AU_KS_TLS
    else
        warn "expect not found — using stdin pipe (install expect for reliability)"
        _ks_out=$(printf '%s\n%s\nadd -user %s\n%s\n%s\nexit\nYES\nYES\n' \
            "$_ks_pass" "$_ks_pass" "$MOS_USER" "$MOS_PWD" "$MOS_PWD" \
            | "$JAVA_BIN" $AU_TLS \
                -jar "$AU_JAR" -config "$AU_KEYSTORE_CFG" -patch -load_password 2>&1)
    fi

    MOS_PWD="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    unset MOS_USER MOS_PWD _ks_pass
    printf '%s\n' "$_ks_out" | tee -a "$LOG_FILE"

    if printf '%s\n' "$_ks_out" | grep -qi "Connection Successful"; then
        touch "$_ks_done_flag"
        ok "MOS keystore configured (Connection Successful)"
    elif printf '%s\n' "$_ks_out" | grep -qi "successfully created\|successfully saved"; then
        touch "$_ks_done_flag"
        warn "MOS keystore saved — connection not yet verified (MOS reachable?)"
    else
        warn "MOS keystore setup may have failed — 'Connection Successful' not found"
        warn "  Retry: rm -rf '${_ks_dir}'/* && ./02-db_patch_autoupgrade.sh --apply"
    fi
    unset _ks_out
fi
unset _ks_dir _ks_done_flag

# =============================================================================
# 4. Write patch config
# =============================================================================

section "Patch Config"

_target_ru="${DB_TARGET_RU:-RECOMMENDED}"

# Build patch1.patch value:
#   RECOMMENDED          → "recommended" (latest RU+OJVM+OPATCH+DPBP+AU — one keyword)
#   numeric e.g. 19.30   → "ru:19.30,ojvm:19.30,opatch,dpbp" (reproducible fixed version)
#   anything else        → passed through as-is (user-defined)
case "${_target_ru^^}" in
    RECOMMENDED)
        _patch_spec="recommended"
        ;;
    19.*CURRENT*|19.*LATEST*)
        # Legacy value from older environment_db.conf — not valid in AutoUpgrade 26.x.
        # Map to RECOMMENDED (latest RU+OJVM+OPatch+DPBP).
        warn "DB_TARGET_RU='$_target_ru' is not valid in AutoUpgrade 26.x → using 'recommended'"
        warn "  Update environment_db.conf:  DB_TARGET_RU=\"RECOMMENDED\"  (or e.g. 19.30)"
        _patch_spec="recommended"
        ;;
    19.*)
        _patch_spec="ru:${_target_ru},ojvm:${_target_ru},opatch,dpbp"
        ;;
    *)
        _patch_spec="${_target_ru}"
        ;;
esac

cat > "$AU_CONFIG" << CFGEOF
# AutoUpgrade patch config – generated by 02-db_patch_autoupgrade.sh
# $(date '+%Y-%m-%d %H:%M:%S')

global.global_log_dir=${DB_AUTOUPGRADE_HOME}/logs
global.keystore=${DB_AUTOUPGRADE_HOME}/keystore

patch1.source_home=${DB_ORACLE_HOME_BASE}
patch1.target_home=${DB_ORACLE_HOME}
patch1.folder=${DB_AUTOUPGRADE_HOME}/patchdir
patch1.patch=${_patch_spec}
patch1.target_version=19
patch1.download=YES
CFGEOF

ok "Patch config written: $AU_CONFIG"
ok "$(printf "  patch spec: %s  (DB_TARGET_RU=%s)" "$_patch_spec" "$_target_ru")"
unset _target_ru _patch_spec

# =============================================================================
# 5. Download patches  (skip if AutoUpgrade recovery state exists)
# =============================================================================

section "AutoUpgrade – Download Patches"

# Clear recovery data first if --reset-recovery was given.
# This discards any incomplete create_home job so the next run starts fresh.
if $RESET_RECOVERY; then
    warn "--reset-recovery: clearing AutoUpgrade recovery data ..."
    "$JAVA_BIN" $AU_TLS \
        -jar "$AU_JAR" \
        -config "$AU_CONFIG" \
        -patch -clear_recovery_data -jobs 1 \
        2>&1 | tee -a "$LOG_FILE" || true
    ok "Recovery data cleared"
fi

printf "\n  Download started: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"

_dl_out=$("$JAVA_BIN" $AU_TLS \
    -jar "$AU_JAR" \
    -config "$AU_CONFIG" \
    -patch -mode download \
    2>&1)
_dl_rc=$?
printf '%s\n' "$_dl_out" | tee -a "$LOG_FILE"
printf "\n  Download finished: %s  (rc=%s)\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$_dl_rc" | tee -a "$LOG_FILE"

# AutoUpgrade rc=1 when a previous create_home run left recovery state.
# It refuses download mode and asks to resume via create_home — detect and skip.
_SKIP_DOWNLOAD=false
if [ "$_dl_rc" -ne 0 ]; then
    if printf '%s\n' "$_dl_out" | grep -qi "unfinished execution\|create_home mode to resume"; then
        warn "AutoUpgrade recovery state detected — previous create_home run incomplete"
        warn "  Skipping download, proceeding directly to create_home (resume)"
        info "  To start completely fresh: ./$(basename "$0") --reset-recovery"
        _SKIP_DOWNLOAD=true
    else
        fail "Patch download failed (rc=$_dl_rc)"
        info "  Check log: $DB_AUTOUPGRADE_HOME/logs/"
        info "  DNS issues? Try: ./$(basename "$0") --apply"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi
else
    ok "Patch download completed"
fi
unset _dl_out _dl_rc

# =============================================================================
# 5b. Ensure Gold Image (LINUX.X64_193000_db_home.zip) is in patchdir
# =============================================================================
#
# create_home extracts the base 19.3.0 Gold Image from patchdir to build the
# new target_home.  Without it AutoUpgrade fails at EXTRACT stage:
#   "Could not find a Gold Image or usable base image"
#
# DB_INSTALL_ARCHIVE from environment_db.conf points to the patch storage copy.
# We place a symlink rather than a copy to avoid doubling the 3 GB.

section "Gold Image in patchdir"

_gold_zip="$DB_AUTOUPGRADE_HOME/patchdir/LINUX.X64_193000_db_home.zip"
_src_zip="${DB_INSTALL_ARCHIVE:-}"

if [ -f "$_gold_zip" ] || [ -L "$_gold_zip" ]; then
    ok "Gold Image present: $_gold_zip"
elif [ -f "$_src_zip" ]; then
    info "Symlinking Gold Image from patch storage into patchdir ..."
    ln -sf "$_src_zip" "$_gold_zip"
    ok "Gold Image symlinked: $_gold_zip → $_src_zip"
else
    fail "Gold Image not found in patchdir and DB_INSTALL_ARCHIVE not available"
    info "  Expected: $_gold_zip"
    info "  Or set DB_INSTALL_ARCHIVE in environment_db.conf to the ZIP path"
    info "  Manual fix: cp LINUX.X64_193000_db_home.zip $DB_AUTOUPGRADE_HOME/patchdir/"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi
unset _gold_zip _src_zip

# =============================================================================
# 6. Create patched ORACLE_HOME
# =============================================================================

section "AutoUpgrade – create_home"

$_SKIP_DOWNLOAD && info "Resuming previous create_home run (recovery state)" \
                || info "Creating patched home: $DB_ORACLE_HOME"
unset _SKIP_DOWNLOAD

# --- Pre-flight: fix oraInst.loc if EXTRACT already ran but INSTALL failed -------
# AutoUpgrade EXTRACT unpacks the gold image but does NOT create oraInst.loc.
# OPatch needs oraInst.loc to locate the central inventory; without it all
# inventory-dependent prereqs fail with "Invalid Home" (OPatch error 106).
# Fix: copy from /etc/oraInst.loc, then register the home via attachHome.
if [ -d "$DB_ORACLE_HOME" ] && [ ! -f "$DB_ORACLE_HOME/oraInst.loc" ]; then
    if [ -f "/etc/oraInst.loc" ]; then
        warn "oraInst.loc missing in target home — auto-fixing (OPatch error 106 prevention)"
        cp /etc/oraInst.loc "$DB_ORACLE_HOME/oraInst.loc"
        ok "oraInst.loc copied: $DB_ORACLE_HOME/oraInst.loc"
    else
        fail "oraInst.loc missing in target home AND in /etc — cannot auto-fix"
        info "  Manual fix: create $DB_ORACLE_HOME/oraInst.loc with:"
        info "    inventory_loc=<central_inventory_path>"
        info "    inst_group=oinstall"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi
    info "Registering target home in Oracle Inventory (attachHome) ..."
    "$DB_ORACLE_HOME/oui/bin/runInstaller" \
        -silent -attachHome \
        "ORACLE_HOME=$DB_ORACLE_HOME" \
        "ORACLE_HOME_NAME=OraDB19Home1Patched" \
        2>&1 | tee -a "$LOG_FILE" || true
    ok "attachHome completed — OPatch should now recognise the target home"
fi

printf "\n  create_home started: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"

"$JAVA_BIN" $AU_TLS \
    -jar "$AU_JAR" \
    -config "$AU_CONFIG" \
    -patch -mode create_home \
    2>&1 | tee -a "$LOG_FILE"

_patch_rc=${PIPESTATUS[0]}
printf "\n  create_home finished: %s  (rc=%s)\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$_patch_rc" | tee -a "$LOG_FILE"

[ "$_patch_rc" -eq 0 ] \
    && ok "Patched home created: $DB_ORACLE_HOME" \
    || { fail "create_home failed (rc=$_patch_rc)"
         info "  Check log: $DB_AUTOUPGRADE_HOME/logs/"
         info "  PATCH109/Invalid Home? Check:"
         info "    $DB_ORACLE_HOME/cfgtoollogs/opatchauto/core/opatch/opatch*.log"
         EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# =============================================================================
# 7. Prompt for root.sh on patched home
# =============================================================================

section "root.sh on patched home (requires root)"

printf "\n"
printf "  \033[33m┌──────────────────────────────────────────────────────────┐\033[0m\n"
printf "  \033[33m│  Run as root NOW (open a second terminal):               │\033[0m\n"
printf "  \033[33m│                                                          │\033[0m\n"
printf "  \033[33m│  %s/root.sh  │\033[0m\n" "$DB_ORACLE_HOME"
printf "  \033[33m└──────────────────────────────────────────────────────────┘\033[0m\n"
printf "\n"

if askYesNo "Press Enter / type 'yes' after root.sh has completed" "y"; then
    ok "root.sh confirmed completed"
else
    warn "root.sh not confirmed – run it before continuing"
fi

# =============================================================================
# 8. Disable unused options (chopt)
# =============================================================================

section "Disable Unused Options (chopt)"

JAVA_BIN_NEW="$DB_ORACLE_HOME/jdk/bin/java"
[ -x "$JAVA_BIN_NEW" ] || JAVA_BIN_NEW="$JAVA_BIN"

for _opt in olap rat; do
    info "Disabling option: $_opt ..."
    "$DB_ORACLE_HOME/bin/chopt" disable "$_opt" 2>&1 | tee -a "$LOG_FILE"
    _chopt_rc=${PIPESTATUS[0]}
    [ "$_chopt_rc" -eq 0 ] \
        && ok "$(printf "chopt disable %-8s  OK" "$_opt")" \
        || warn "$(printf "chopt disable %-8s  rc=%s (may already be disabled)" "$_opt" "$_chopt_rc")"
done
unset _opt _chopt_rc JAVA_BIN_NEW

# =============================================================================
# 9. Unified Auditing relink (uniaud_on)
# =============================================================================

section "Unified Auditing Relink (uniaud_on)"

info "Relinking Oracle binary with Unified Auditing support ..."
info "  ORACLE_HOME: $DB_ORACLE_HOME"

cd "$DB_ORACLE_HOME/rdbms/lib" || { fail "Cannot cd to $DB_ORACLE_HOME/rdbms/lib"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

ORACLE_HOME="$DB_ORACLE_HOME" \
    make -f ins_rdbms.mk uniaud_on ioracle 2>&1 | tee -a "$LOG_FILE"

_relink_rc=${PIPESTATUS[0]}

if [ "$_relink_rc" -ne 0 ]; then
    fail "uniaud_on relink failed (rc=$_relink_rc)"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

# Verify
_kzaiang_count=$(strings "$DB_ORACLE_HOME/bin/oracle" 2>/dev/null | grep -c "kzaiang" || printf "0")
if [ "$_kzaiang_count" -gt 0 ]; then
    ok "Unified Auditing relink verified (kzaiang found: $_kzaiang_count)"
else
    warn "kzaiang not found in oracle binary – relink may not have taken effect"
fi
unset _relink_rc _kzaiang_count

# =============================================================================
# 10. Verify patched home
# =============================================================================

section "Verification"

info "Installed patches:"
ORACLE_HOME="$DB_ORACLE_HOME" \
    "$DB_ORACLE_HOME/OPatch/opatch" lspatches 2>/dev/null \
    | head -10 | while IFS= read -r _line; do info "  $_line"; done

info "OPatch version:"
ORACLE_HOME="$DB_ORACLE_HOME" \
    "$DB_ORACLE_HOME/OPatch/opatch" version 2>/dev/null \
    | head -2 | while IFS= read -r _line; do info "  $_line"; done

printf "\n" | tee -a "$LOG_FILE"
info "Next step: create the database"
info "  03-db_create_database.sh --apply"

# =============================================================================
print_summary
exit $EXIT_CODE
