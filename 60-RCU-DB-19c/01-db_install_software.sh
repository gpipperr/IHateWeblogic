#!/bin/bash
# =============================================================================
# Script   : 01-db_install_software.sh
# Purpose  : Install Oracle 19c Database software (software-only, no DB created).
#            Unzips LINUX.X64_193000_db_home.zip and runs runInstaller -silent.
#            After completion: prompts to run root.sh as root.
# Call     : ./60-RCU-DB-19c/01-db_install_software.sh
#            ./60-RCU-DB-19c/01-db_install_software.sh --apply
#            ./60-RCU-DB-19c/01-db_install_software.sh --help
# Runs as  : oracle
# Requires : environment.conf, environment_db.conf, DB_INSTALL_ARCHIVE
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 60-RCU-DB-19c/docs/02-db_install_software.md
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
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"

# --- Source environment.conf --------------------------------------------------
if [ ! -f "$ENV_CONF" ]; then
    printf "\033[31mFATAL\033[0m: environment.conf not found: %s\n" "$ENV_CONF" >&2; exit 2
fi
source "$ENV_CONF"

# --- Source environment_db.conf -----------------------------------------------
if [ ! -f "$ENV_DB_CONF" ]; then
    _example="$SCRIPT_DIR/environment_db.conf.example"
    printf "\n  \033[33mWARN\033[0m  environment_db.conf not found: %s\n" "$ENV_DB_CONF" >&2
    printf "  This file configures the Oracle 19c DB installation (ORACLE_HOME, SID, …).\n" >&2
    if [ ! -f "$_example" ]; then
        printf "\033[31mFATAL\033[0m: Template also missing: %s\n" "$_example" >&2; exit 2
    fi
    printf "\n  Template found: %s\n" "$_example" >&2
    if [ -n "${ORACLE_BASE:-}" ] && [ "$ORACLE_BASE" != "/u01/app/oracle" ]; then
        printf "  ORACLE_BASE from environment.conf: %s\n" "$ORACLE_BASE" >&2
        printf "  → will replace placeholder /u01/app/oracle in the copy\n" >&2
    fi
    printf "\n  Create environment_db.conf from template now? [y/N] " >&2
    read -r _yn
    case "${_yn}" in
        [yY]|[yY][eE][sS])
            cp "$_example" "$ENV_DB_CONF"
            chmod 600 "$ENV_DB_CONF"
            if [ -n "${ORACLE_BASE:-}" ] && [ "$ORACLE_BASE" != "/u01/app/oracle" ]; then
                sed -i "s|ORACLE_BASE=\"/u01/app/oracle\"|ORACLE_BASE=\"${ORACLE_BASE}\"|g" \
                    "$ENV_DB_CONF"
            fi
            printf "\n  \033[32mOK\033[0m   Created: %s\n" "$ENV_DB_CONF" >&2
            printf "  \033[33mWARN\033[0m Review remaining settings before proceeding:\n" >&2
            printf "       vi %s\n\n" "$ENV_DB_CONF" >&2
            ;;
        *)
            printf "\n  Aborted. Copy and edit manually:\n" >&2
            printf "    cp %s/environment_db.conf.example \\\n" "$SCRIPT_DIR" >&2
            printf "       %s/environment_db.conf\n\n" "$SCRIPT_DIR" >&2
            exit 2
            ;;
    esac
fi
source "$ENV_DB_CONF"

DIAG_LOG_DIR="${DIAG_LOG_DIR:-$ROOT_DIR/log/$(date +%Y%m%d)}"
init_log "$DIAG_LOG_DIR"

# =============================================================================
# Arguments
# =============================================================================

APPLY=false

_usage() {
    printf "Usage: %s [--apply] [--help]\n\n" "$(basename "$0")"
    printf "  %-12s %s\n" "(none)"  "Dry-run: show configuration, no install"
    printf "  %-12s %s\n" "--apply" "Unzip + runInstaller software-only"
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
printf "\n\033[1m  IHateWeblogic – DB Software Install (19c)\033[0m\n"   | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"                          | tee -a "$LOG_FILE"
printf "  Date        : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"             | tee -a "$LOG_FILE"
printf "  Mode        : %s\n" "$( $APPLY && printf 'APPLY' || printf 'DRY-RUN')" | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"                                 | tee -a "$LOG_FILE"
printLine

# =============================================================================
# Pre-checks
# =============================================================================

section "Pre-checks"

[ -n "${ORACLE_BASE:-}" ] \
    && ok "ORACLE_BASE = $ORACLE_BASE" \
    || { fail "ORACLE_BASE not set"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -n "${DB_ORACLE_HOME_BASE:-}" ] \
    && ok "DB_ORACLE_HOME_BASE = $DB_ORACLE_HOME_BASE" \
    || { fail "DB_ORACLE_HOME_BASE not set in environment_db.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -n "${DB_INSTALL_ARCHIVE:-}" ] \
    && ok "DB_INSTALL_ARCHIVE = $DB_INSTALL_ARCHIVE" \
    || { fail "DB_INSTALL_ARCHIVE not set in environment_db.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -f "$DB_INSTALL_ARCHIVE" ] \
    && ok "Install archive found: $DB_INSTALL_ARCHIVE ($(du -sh "$DB_INSTALL_ARCHIVE" 2>/dev/null | cut -f1))" \
    || { fail "Install archive not found: $DB_INSTALL_ARCHIVE"
         info "  Download manually from eDelivery (V982063-01)"
         info "  Place at: \${PATCH_STORAGE}/database/LINUX.X64_193000_db_home.zip"
         EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# --- Check if already installed -----------------------------------------------
if [ -x "$DB_ORACLE_HOME_BASE/bin/sqlplus" ]; then
    warn "DB software already installed: $DB_ORACLE_HOME_BASE"
    warn "  Remove the directory and re-run if a fresh install is needed."
    info "  Skipping install – continuing with verification only."
    section "Verification"
    ORACLE_HOME="$DB_ORACLE_HOME_BASE" "$DB_ORACLE_HOME_BASE/OPatch/opatch" lspatches 2>/dev/null \
        | head -5 | while IFS= read -r _line; do info "  $_line"; done
    print_summary; exit $EXIT_CODE
fi

# --- Disk space check ---------------------------------------------------------
_avail_kb=$(df -k "$(dirname "$DB_ORACLE_HOME_BASE")" 2>/dev/null | awk 'NR==2 { print $4 }')
_required_kb=$(( 8 * 1024 * 1024 ))   # 8 GB
if [ -n "$_avail_kb" ] && [ "$_avail_kb" -lt "$_required_kb" ]; then
    warn "$(printf "Available disk: %d MB — minimum 8 GB recommended" "$(( _avail_kb / 1024 ))")"
else
    ok "$(printf "Disk space available: %d MB in %s" "$(( _avail_kb / 1024 ))" "$(dirname "$DB_ORACLE_HOME_BASE")")"
fi
unset _avail_kb _required_kb

# --- Inventory check ----------------------------------------------------------
ORABASE_INVENTORY="$ORACLE_BASE/../oraInventory"
ORABASE_INVENTORY="$(cd "$ORACLE_BASE/.." && pwd)/oraInventory"
if [ -d "$ORABASE_INVENTORY" ]; then
    ok "Oracle Inventory found: $ORABASE_INVENTORY (shared with FMW)"
else
    info "No inventory yet at $ORABASE_INVENTORY – will be created by installer"
fi

# =============================================================================
# Summary
# =============================================================================

section "Install Configuration"

printList "ORACLE_BASE"          28 "$ORACLE_BASE"
printList "DB_ORACLE_HOME_BASE"  28 "$DB_ORACLE_HOME_BASE"
printList "Install archive"      28 "$DB_INSTALL_ARCHIVE"
printList "Edition"              28 "${DB_EDITION:-EE}  (EE=Enterprise / SE2=Standard)"

printf "\n" | tee -a "$LOG_FILE"
info "After runInstaller completes, you will be prompted to run root.sh as root."

if ! $APPLY; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "Dry-run – use --apply to install."
    print_summary; exit $EXIT_CODE
fi

# =============================================================================
# 1. Create ORACLE_HOME directory
# =============================================================================

section "Create ORACLE_HOME"

mkdir -p "$DB_ORACLE_HOME_BASE"
chmod 775 "$DB_ORACLE_HOME_BASE"
ok "Directory created: $DB_ORACLE_HOME_BASE"

# =============================================================================
# 2. Unzip install archive
# =============================================================================

section "Unzip Install Archive"

printf "  Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
unzip -q "$DB_INSTALL_ARCHIVE" -d "$DB_ORACLE_HOME_BASE" 2>&1 | tee -a "$LOG_FILE"
_rc=$?
printf "  Finished: %s  (rc=%s)\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$_rc" | tee -a "$LOG_FILE"

[ "$_rc" -eq 0 ] \
    && ok "Archive extracted to: $DB_ORACLE_HOME_BASE" \
    || { fail "Unzip failed (rc=$_rc)"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# =============================================================================
# 3. Run runInstaller (software-only, silent)
# =============================================================================

section "runInstaller – software-only"

_edition="${DB_EDITION:-EE}"
_inv_location="$(dirname "$ORACLE_BASE")/oraInventory"

printf "\n  Install started: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"

"$DB_ORACLE_HOME_BASE/runInstaller" \
    -silent \
    -ignorePrereqFailure \
    -waitforcompletion \
    "oracle.install.option=INSTALL_DB_SWONLY" \
    "ORACLE_BASE=$ORACLE_BASE" \
    "ORACLE_HOME=$DB_ORACLE_HOME_BASE" \
    "ORACLE_HOME_NAME=OraDB19Home1" \
    "oracle.install.db.InstallEdition=$_edition" \
    "oracle.install.db.OSDBA_GROUP=dba" \
    "oracle.install.db.OSOPER_GROUP=oper" \
    "oracle.install.db.OSBACKUPDBA_GROUP=dba" \
    "oracle.install.db.OSDGDBA_GROUP=dba" \
    "oracle.install.db.OSKMDBA_GROUP=dba" \
    "oracle.install.db.OSRACDBA_GROUP=dba" \
    "SECURITY_UPDATES_VIA_MYORACLESUPPORT=false" \
    "DECLINE_SECURITY_UPDATES=true" \
    2>&1 | tee -a "$LOG_FILE"

_install_rc=${PIPESTATUS[0]}
printf "\n  Install finished: %s  (rc=%s)\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$_install_rc" | tee -a "$LOG_FILE"
unset _edition _inv_location

if [ "$_install_rc" -ne 0 ]; then
    fail "runInstaller exited with rc=$_install_rc"
    info "  Check installer logs: $ORACLE_BASE/oraInventory/logs/"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

ok "runInstaller completed (rc=0)"

# =============================================================================
# 4. Prompt for root.sh
# =============================================================================

section "root.sh (requires root)"

printf "\n" | tee -a "$LOG_FILE"
printf "  \033[33m┌─────────────────────────────────────────────────────────┐\033[0m\n"
printf "  \033[33m│  Run as root NOW (open a second terminal):              │\033[0m\n"
printf "  \033[33m│                                                         │\033[0m\n"
printf "  \033[33m│  %s/root.sh  │\033[0m\n" "$DB_ORACLE_HOME_BASE"
printf "  \033[33m└─────────────────────────────────────────────────────────┘\033[0m\n"
printf "\n"

if askYesNo "Press Enter / type 'yes' after root.sh has completed" "y"; then
    ok "root.sh confirmed completed"
else
    warn "root.sh not confirmed – continue manually after running root.sh"
fi

# =============================================================================
# 5. Verify installation
# =============================================================================

section "Verification"

[ -x "$DB_ORACLE_HOME_BASE/bin/sqlplus" ] \
    && ok "sqlplus found: $DB_ORACLE_HOME_BASE/bin/sqlplus" \
    || { fail "sqlplus not found – installation may have failed"; EXIT_CODE=1; }

if [ -x "$DB_ORACLE_HOME_BASE/OPatch/opatch" ]; then
    ok "OPatch found"
    ORACLE_HOME="$DB_ORACLE_HOME_BASE" \
        "$DB_ORACLE_HOME_BASE/OPatch/opatch" lspatches 2>/dev/null \
        | head -5 | while IFS= read -r _line; do info "  $_line"; done
fi

printf "\n" | tee -a "$LOG_FILE"
info "Next step: patch to current RU"
info "  02-db_patch_autoupgrade.sh --apply"

# =============================================================================
print_summary
exit $EXIT_CODE
