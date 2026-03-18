#!/bin/bash
# =============================================================================
# Script   : 03-db_create_database.sh
# Purpose  : Create Oracle 19c CDB + PDB (FMWCDB / FMWPDB) via dbca -silent.
#            Includes:
#              - Listener creation (listener.ora)
#              - DBCA silent with minimal FMW-RCU sizing
#              - Post-creation parameter tuning (open_cursors, processes, …)
#              - ALTER PLUGGABLE DATABASE ALL SAVE STATE (PDB auto-open)
# Call     : ./60-RCU-DB-19c/03-db_create_database.sh
#            ./60-RCU-DB-19c/03-db_create_database.sh --apply
#            ./60-RCU-DB-19c/03-db_create_database.sh --help
# Runs as  : oracle
# Requires : environment.conf, environment_db.conf, db_sys_sec.conf.des3
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 60-RCU-DB-19c/docs/04-db_create_database.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"
ENV_DB_CONF="$SCRIPT_DIR/environment_db.conf"
DB_SEC_FILE="$ROOT_DIR/db_sys_sec.conf.des3"

# --- Source library -----------------------------------------------------------
if [ ! -f "$LIB" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB" >&2; exit 2
fi
source "$LIB"

for _f in "$ENV_CONF" "$ENV_DB_CONF"; do
    [ ! -f "$_f" ] && { printf "\033[31mFATAL\033[0m: Config not found: %s\n" "$_f" >&2; exit 2; }
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
    printf "  %-12s %s\n" "(none)"  "Dry-run: show configuration, no DB created"
    printf "  %-12s %s\n" "--apply" "Create listener + CDB + PDB + post-config"
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

# Set ORACLE_HOME to DB home for this script (does NOT affect .bash_profile)
export ORACLE_HOME="$DB_ORACLE_HOME"

# =============================================================================
# Banner
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – DB Create Database (19c CDB+PDB)\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"                               | tee -a "$LOG_FILE"
printf "  Date        : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"                  | tee -a "$LOG_FILE"
printf "  Mode        : %s\n" "$( $APPLY && printf 'APPLY' || printf 'DRY-RUN')" | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"                                      | tee -a "$LOG_FILE"
printLine

# =============================================================================
# Pre-checks
# =============================================================================

section "Pre-checks"

[ -n "${DB_ORACLE_HOME:-}" ] \
    && ok "DB_ORACLE_HOME = $DB_ORACLE_HOME" \
    || { fail "DB_ORACLE_HOME not set"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -x "$DB_ORACLE_HOME/bin/dbca" ] \
    && ok "dbca found: $DB_ORACLE_HOME/bin/dbca" \
    || { fail "dbca not found – run 02-db_patch_autoupgrade.sh --apply first"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -x "$DB_ORACLE_HOME/bin/lsnrctl" ] \
    && ok "lsnrctl found" \
    || { fail "lsnrctl not found in $DB_ORACLE_HOME/bin/"; EXIT_CODE=2; }

# --- Unified Auditing relink verification ------------------------------------
_kzaiang_count=$(strings "$DB_ORACLE_HOME/bin/oracle" 2>/dev/null | grep -c "kzaiang" || printf "0")
if [ "$_kzaiang_count" -gt 0 ]; then
    ok "Unified Auditing relink verified (kzaiang: $_kzaiang_count)"
else
    fail "Unified Auditing relink NOT verified (run 02-db_patch_autoupgrade.sh --apply)"
    EXIT_CODE=2
fi
unset _kzaiang_count

[ -n "${DB_SID:-}" ]      && ok "DB_SID      = $DB_SID"      || { fail "DB_SID not set";      EXIT_CODE=2; }
[ -n "${DB_CDB_NAME:-}" ] && ok "DB_CDB_NAME = $DB_CDB_NAME" || { fail "DB_CDB_NAME not set"; EXIT_CODE=2; }
[ -n "${DB_PDB_NAME:-}" ] && ok "DB_PDB_NAME = $DB_PDB_NAME" || { fail "DB_PDB_NAME not set"; EXIT_CODE=2; }
[ -n "${DB_DATA_DIR:-}" ] && ok "DB_DATA_DIR = $DB_DATA_DIR" || { fail "DB_DATA_DIR not set"; EXIT_CODE=2; }
if [ -n "${DB_FAST_RECOVERY_AREA:-}" ]; then
    ok "$(printf "%-28s %s  (%s MB)" "DB_FAST_RECOVERY_AREA" "$DB_FAST_RECOVERY_AREA" "${DB_RECOVERY_SIZE_MB:-4096}")"
else
    info "DB_FAST_RECOVERY_AREA not set – FRA disabled"
fi

[ "$EXIT_CODE" -ne 0 ] && { print_summary; exit $EXIT_CODE; }

# --- DB already exists? -------------------------------------------------------
if [ -d "${DB_DATA_DIR}/${DB_CDB_NAME}" ]; then
    warn "Datafile directory already exists: ${DB_DATA_DIR}/${DB_CDB_NAME}"
    warn "  Remove it and re-run if a fresh DB is needed."
    EXIT_CODE=1
fi

# --- Credentials --------------------------------------------------------------
[ -f "$DB_SEC_FILE" ] \
    && ok "DB credentials file: $DB_SEC_FILE" \
    || { fail "DB credentials not found: $DB_SEC_FILE"
         info "  Run first: 00-Setup/database_rcu_sec.sh --apply"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# =============================================================================
# Configuration Summary
# =============================================================================

section "Database Configuration"

_memory_mb="${DB_SGA_MB:-1536}"
_pga_mb="${DB_PGA_MB:-512}"
_total_mb=$(( _memory_mb + _pga_mb ))
_listener_port="${DB_LISTENER_PORT:-1521}"
_listener_host="${DB_LISTENER_HOST:-$(_get_hostname)}"

printList "CDB name"          28 "$DB_CDB_NAME"
printList "PDB name"          28 "$DB_PDB_NAME"
printList "SID"               28 "$DB_SID"
printList "SGA_TARGET"        28 "${_memory_mb} MB"
printList "PGA_TARGET"        28 "${_pga_mb} MB"
printList "Total memory"      28 "${_total_mb} MB"
printList "Character set"     28 "${DB_CHAR_SET:-AL32UTF8}"
printList "Data dir"          28 "$DB_DATA_DIR"
printList "Recovery Area"     28 "${DB_FAST_RECOVERY_AREA:-(disabled)}"
printList "Admin dir"         28 "${DB_ADMIN_DIR:-$ORACLE_BASE/admin}"
printList "Archivelog"        28 "${DB_ARCHIVELOG:-false}"
printList "Listener host"     28 "$_listener_host"
printList "Listener port"     28 "$_listener_port"
printList "PROCESSES"         28 "${DB_PROCESSES:-500}"
printList "OPEN_CURSORS"      28 "${DB_OPEN_CURSORS:-1000}"

if ! $APPLY; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "Dry-run – use --apply to create the database."
    print_summary; exit $EXIT_CODE
fi

# =============================================================================
# Load DB credentials
# =============================================================================

section "DB Credentials"

unset DB_SYS_PWD DB_SCHEMA_PWD
if ! load_secrets_file "$DB_SEC_FILE"; then
    info "  Run first: 00-Setup/database_rcu_sec.sh --apply"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

[ -n "${DB_SYS_PWD:-}" ] \
    && ok "DB_SYS_PWD decrypted (${#DB_SYS_PWD} chars)" \
    || { fail "DB_SYS_PWD not found in $DB_SEC_FILE"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# Use DB_SYS_PWD for SYSTEM and PDB_ADMIN on a minimal dev DB.
# Override by setting DB_SYSTEM_PWD / DB_PDB_ADMIN_PWD in environment_db.conf.
DB_SYSTEM_PWD="${DB_SYSTEM_PWD:-$DB_SYS_PWD}"
DB_PDB_ADMIN_PWD="${DB_PDB_ADMIN_PWD:-$DB_SYS_PWD}"
info "SYSTEM + PDB_ADMIN passwords: using DB_SYS_PWD (set DB_SYSTEM_PWD/DB_PDB_ADMIN_PWD in environment_db.conf to override)"

# Cleanup trap
_cleanup_db_passwords() {
    DB_SYS_PWD="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    DB_SYSTEM_PWD="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    DB_PDB_ADMIN_PWD="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    unset DB_SYS_PWD DB_SYSTEM_PWD DB_PDB_ADMIN_PWD
}
trap '_cleanup_db_passwords' EXIT

# =============================================================================
# 1. Create directory structure
# =============================================================================

section "Directory Structure"

_adump_dir="${DB_ADMIN_DIR:-$ORACLE_BASE/admin}/${DB_CDB_NAME}/adump"
mkdir -p "${DB_DATA_DIR}" "$_adump_dir"
ok "Data dir : $DB_DATA_DIR"
ok "Audit dir: $_adump_dir"
if [ -n "${DB_FAST_RECOVERY_AREA:-}" ]; then
    mkdir -p "${DB_FAST_RECOVERY_AREA}"
    ok "FRA dir  : $DB_FAST_RECOVERY_AREA"
fi
unset _adump_dir

# =============================================================================
# 2. Create listener
# =============================================================================

section "Listener"

_net_admin="$DB_ORACLE_HOME/network/admin"
mkdir -p "$_net_admin"

_listener_ora="$_net_admin/listener.ora"
if [ -f "$_listener_ora" ]; then
    backup_file "$_listener_ora" "$_net_admin"
fi

cat > "$_listener_ora" << LSNEOF
# listener.ora – generated by 03-db_create_database.sh
# $(date '+%Y-%m-%d %H:%M:%S')
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = ${_listener_host})(PORT = ${_listener_port}))
      (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC1521))
    )
  )

# Automatic registration — no static SID_LIST needed for 19c
LSNEOF

ok "listener.ora written: $_listener_ora"

info "Starting LISTENER ..."
"$DB_ORACLE_HOME/bin/lsnrctl" start LISTENER 2>&1 | tee -a "$LOG_FILE"
_lsnr_rc=${PIPESTATUS[0]}
[ "$_lsnr_rc" -eq 0 ] && ok "Listener started" || warn "lsnrctl start rc=$_lsnr_rc (may already be running)"
unset _net_admin _listener_ora _lsnr_rc

# =============================================================================
# 3. DBCA silent – create CDB + PDB
# =============================================================================

section "DBCA – Create CDB + PDB"

# Fast Recovery Area flags (conditional — like RCU_TS_FLAGS pattern)
_fra_flags=( -recoveryAreaDestination "" )
if [ -n "${DB_FAST_RECOVERY_AREA:-}" ]; then
    _fra_flags=(
        -recoveryAreaDestination "${DB_FAST_RECOVERY_AREA}"
        -recoveryAreaSize        "${DB_RECOVERY_SIZE_MB:-4096}"
    )
    ok "$(printf "%-28s %s" "Recovery Area:" "$DB_FAST_RECOVERY_AREA  (${DB_RECOVERY_SIZE_MB:-4096} MB)")"
else
    info "Recovery Area disabled (DB_FAST_RECOVERY_AREA not set)"
fi

printf "\n  DBCA started: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"

"$DB_ORACLE_HOME/bin/dbca" -silent \
    -createDatabase \
    -templateName          General_Purpose.dbc \
    -gdbName               "${DB_CDB_NAME}" \
    -sid                   "${DB_SID}" \
    -createAsContainerDatabase true \
    -numberOfPDBs          1 \
    -pdbName               "${DB_PDB_NAME}" \
    -pdbAdminPassword      "${DB_PDB_ADMIN_PWD}" \
    -databaseType          MULTIPURPOSE \
    -memoryMgmtType        CUSTOM_SGA \
    -sga                   "${DB_SGA_MB:-1536}" \
    -pga                   "${DB_PGA_MB:-512}" \
    -storageType           FS \
    -datafileDestination   "${DB_DATA_DIR}" \
    -redoLogFileSize        50 \
    -emConfiguration       NONE \
    -dbOptions             "JSERVER:false,ORACLE_TEXT:false,IMEDIA:false,CWMLITE:false,SPATIAL:false,OMS:false,APEX:false,DV:false" \
    -characterSet          "${DB_CHAR_SET:-AL32UTF8}" \
    -nationalCharacterSet  "${DB_NCHAR_SET:-AL16UTF16}" \
    -sysPassword           "${DB_SYS_PWD}" \
    -systemPassword        "${DB_SYSTEM_PWD}" \
    -enableArchive         "${DB_ARCHIVELOG:-false}" \
    "${_fra_flags[@]}" \
    -useLocalUndoForPDBs   true \
    2>&1 | tee -a "$LOG_FILE"

_dbca_rc=${PIPESTATUS[0]}
printf "\n  DBCA finished: %s  (rc=%s)\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$_dbca_rc" | tee -a "$LOG_FILE"

if [ "$_dbca_rc" -ne 0 ]; then
    fail "DBCA exited with rc=$_dbca_rc"
    info "  Check logs: $ORACLE_BASE/cfgtoollogs/dbca/${DB_CDB_NAME}/"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

ok "DBCA completed – CDB $DB_CDB_NAME / PDB $DB_PDB_NAME created"

# =============================================================================
# 4. Post-creation parameter tuning
# =============================================================================

section "Post-Creation Parameter Tuning"

info "Applying RCU-required parameters and PDB SAVE STATE ..."

"$DB_ORACLE_HOME/bin/sqlplus" -S /nolog 2>&1 | tee -a "$LOG_FILE" << SQLEOF
CONNECT / AS SYSDBA

-- RCU pre-check RCU-6107 and parallel session requirements
ALTER SYSTEM SET open_cursors    = ${DB_OPEN_CURSORS:-1000} SCOPE=BOTH;
ALTER SYSTEM SET processes       = ${DB_PROCESSES:-500}     SCOPE=SPFILE;

-- Extended string support for FMW VARCHAR columns (static)
ALTER SYSTEM SET max_string_size = EXTENDED SCOPE=SPFILE;

-- Compatibility level
ALTER SYSTEM SET compatible      = '19.0.0' SCOPE=SPFILE;

-- PDB auto-open after CDB restart (CRITICAL)
ALTER PLUGGABLE DATABASE ALL OPEN;
ALTER PLUGGABLE DATABASE ALL SAVE STATE;

EXIT;
SQLEOF
_sql_rc=${PIPESTATUS[0]}

info "Restarting database to apply static parameters ..."

"$DB_ORACLE_HOME/bin/sqlplus" -S /nolog 2>&1 | tee -a "$LOG_FILE" << SQLEOF2
CONNECT / AS SYSDBA
SHUTDOWN IMMEDIATE;
STARTUP;
ALTER PLUGGABLE DATABASE ALL OPEN;
SELECT NAME, OPEN_MODE FROM V\$PDBS;
SHOW PARAMETER open_cursors;
SHOW PARAMETER processes;
SHOW PARAMETER max_string_size;
SHOW PARAMETER compatible;
EXIT;
SQLEOF2
_restart_rc=${PIPESTATUS[0]}

[ "$_restart_rc" -eq 0 ] && ok "Database restarted and PDB opened" \
    || warn "DB restart returned rc=$_restart_rc – check log manually"

# =============================================================================
# 5. Update /etc/oratab
# =============================================================================

section "oratab"

if [ -f /etc/oratab ]; then
    if grep -q "^${DB_SID}:" /etc/oratab; then
        ok "/etc/oratab entry already exists for $DB_SID"
    else
        printf "%s:%s:Y\n" "$DB_SID" "$DB_ORACLE_HOME" >> /etc/oratab
        ok "Added to /etc/oratab: ${DB_SID}:${DB_ORACLE_HOME}:Y"
    fi
else
    warn "/etc/oratab not found – skipping"
fi

# =============================================================================
# 6. Final verification
# =============================================================================

section "Verification"

"$DB_ORACLE_HOME/bin/sqlplus" -S /nolog << VERIFYEOF 2>&1 | tee -a "$LOG_FILE"
CONNECT / AS SYSDBA
SELECT 'CDB: ' || NAME || '  DB_UNIQUE_NAME: ' || DB_UNIQUE_NAME FROM V\$DATABASE;
SELECT NAME, OPEN_MODE, RESTRICTED FROM V\$PDBS;
SELECT VALUE FROM NLS_DATABASE_PARAMETERS WHERE PARAMETER = 'NLS_CHARACTERSET';
SELECT VALUE FROM V\$OPTION WHERE PARAMETER = 'Unified Auditing';
EXIT;
VERIFYEOF

printf "\n" | tee -a "$LOG_FILE"
info "Update environment.conf with DB connection:"
info "  DB_HOST=${_listener_host}"
info "  DB_PORT=${_listener_port}"
info "  DB_SERVICE=${DB_PDB_NAME}"
printf "\n" | tee -a "$LOG_FILE"
info "Next step: configure Unified Auditing"
info "  04-db_audit_setup.sh --apply"

# =============================================================================
print_summary
exit $EXIT_CODE
