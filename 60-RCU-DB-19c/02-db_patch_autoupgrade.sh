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

_usage() {
    printf "Usage: %s [--apply] [--help]\n\n" "$(basename "$0")"
    printf "  %-12s %s\n" "(none)"  "Dry-run: show config, no patching"
    printf "  %-12s %s\n" "--apply" "Download patches + create_home + chopt + relink"
    printf "  %-12s %s\n" "--help"  "Show this help"
    printf "\nRuns as: oracle\n"
    exit 0
}

for _arg in "$@"; do
    case "$_arg" in
        --apply)   APPLY=true ;;
        --help|-h) _usage ;;
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

# --- Java (bundled 19c JDK) --------------------------------------------------
JAVA_BIN="$DB_ORACLE_HOME_BASE/jdk/bin/java"
[ -x "$JAVA_BIN" ] \
    && ok "Java found: $JAVA_BIN ($("$JAVA_BIN" -version 2>&1 | head -1))" \
    || { fail "Java not found at $JAVA_BIN"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

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

AU_DOWNLOAD_URL="https://download.oracle.com/otn-pub/otn_software/autoupgrade/autoupgrade.jar"

if [ -f "$AU_JAR" ]; then
    ok "autoupgrade.jar already present: $AU_JAR"
    info "  Delete and re-run to force update to latest version"
else
    info "Downloading autoupgrade.jar from oracle.com (no auth required) ..."
    info "  Source: $AU_DOWNLOAD_URL"
    if curl -fsSL \
        -Dhttps.protocols=TLSv1.3 \
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

# Write keystore config
cat > "$AU_KEYSTORE_CFG" << KEOF
global.keystore=${DB_AUTOUPGRADE_HOME}/keystore
KEOF

info "Setting MOS password in AutoUpgrade keystore ..."
printf '%s\n%s\n' "$MOS_USER" "$MOS_PWD" \
    | "$JAVA_BIN" -Dhttps.protocols=TLSv1.3 \
        -jar "$AU_JAR" \
        -config "$AU_KEYSTORE_CFG" \
        -patch -mode setmospassword \
        2>&1 | tee -a "$LOG_FILE"

# Clear MOS credentials from memory
MOS_PWD="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
unset MOS_USER MOS_PWD

ok "MOS keystore configured"

# =============================================================================
# 4. Write patch config
# =============================================================================

section "Patch Config"

_target_ru="${DB_TARGET_RU:-19.CURRENT}"

cat > "$AU_CONFIG" << CFGEOF
# AutoUpgrade patch config – generated by 02-db_patch_autoupgrade.sh
# $(date '+%Y-%m-%d %H:%M:%S')

global.global_log_dir=${DB_AUTOUPGRADE_HOME}/logs
global.keystore=${DB_AUTOUPGRADE_HOME}/keystore

patch1.source_home=${DB_ORACLE_HOME_BASE}
patch1.target_home=${DB_ORACLE_HOME}
patch1.folder=${DB_AUTOUPGRADE_HOME}/patchdir
patch1.patch=RU:${_target_ru},OPATCH,OJVM:${_target_ru},DPBP
patch1.target_version=19
patch1.download=YES
CFGEOF

ok "Patch config written: $AU_CONFIG"
unset _target_ru

# =============================================================================
# 5. Download patches
# =============================================================================

section "AutoUpgrade – Download Patches"

printf "\n  Download started: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"

"$JAVA_BIN" -Dhttps.protocols=TLSv1.3 \
    -jar "$AU_JAR" \
    -config "$AU_CONFIG" \
    -patch -mode download \
    2>&1 | tee -a "$LOG_FILE"

_dl_rc=${PIPESTATUS[0]}
printf "\n  Download finished: %s  (rc=%s)\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$_dl_rc" | tee -a "$LOG_FILE"

[ "$_dl_rc" -eq 0 ] \
    && ok "Patch download completed" \
    || { fail "Patch download failed (rc=$_dl_rc)"
         info "  Check log: $DB_AUTOUPGRADE_HOME/logs/"
         info "  DNS issues? Try again – transient failures are known"
         EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# =============================================================================
# 6. Create patched ORACLE_HOME
# =============================================================================

section "AutoUpgrade – create_home"

info "Creating patched home: $DB_ORACLE_HOME"
printf "\n  create_home started: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"

"$JAVA_BIN" -Dhttps.protocols=TLSv1.3 \
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
