#!/bin/bash
# =============================================================================
# Script   : 05-db_create_database.sh
# Purpose  : Create Oracle 19c CDB + PDB (FMWCDB / FMWPDB) via dbca -silent.
#            Includes:
#              - DBCA silent with minimal FMW-RCU sizing
#              - Post-creation parameter tuning (open_cursors, processes, …)
#              - ALTER PLUGGABLE DATABASE ALL SAVE STATE (PDB auto-open)
#            Requires listener running — run 04-db_setup_listener.sh first.
# Call     : ./60-RCU-DB-19c/05-db_create_database.sh
#            ./60-RCU-DB-19c/05-db_create_database.sh --apply
#            ./60-RCU-DB-19c/05-db_create_database.sh --help
# Runs as  : oracle
# Requires : environment.conf, environment_db.conf, db_sys_sec.conf.des3
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 60-RCU-DB-19c/docs/05-db_create_database.md
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
CLEAN=false

_usage() {
    printf "Usage: %s [--apply] [--clean [--apply]] [--help]\n\n" "$(basename "$0")"
    printf "  %-22s %s\n" "(none)"          "Dry-run: show configuration, no DB created"
    printf "  %-22s %s\n" "--apply"         "Create CDB + PDB + post-config"
    printf "  %-22s %s\n" "--clean"         "Dry-run: show what --clean --apply would remove"
    printf "  %-22s %s\n" "--clean --apply" "Delete existing DB + datafiles, then re-create"
    printf "  %-22s %s\n" "--help"          "Show this help"
    printf "\nRuns as: oracle\n"
    exit 0
}

for _arg in "$@"; do
    case "$_arg" in
        --apply)   APPLY=true ;;
        --clean)   CLEAN=true ;;
        --help|-h) _usage ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$_arg" >&2; exit 1 ;;
    esac
done
unset _arg

# Set ORACLE_HOME + ORACLE_SID for sqlplus OS authentication (/ AS SYSDBA)
export ORACLE_HOME="$DB_ORACLE_HOME"
export ORACLE_SID="${DB_SID}"

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
    || { fail "dbca not found – run 02-db_patch_db_software.sh --apply first"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -x "$DB_ORACLE_HOME/bin/lsnrctl" ] \
    && ok "lsnrctl found: $DB_ORACLE_HOME/bin/lsnrctl" \
    || { fail "lsnrctl not found — run 02-db_patch_db_software.sh --apply first"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

"$DB_ORACLE_HOME/bin/lsnrctl" status LISTENER >/dev/null 2>&1 \
    && ok "Listener is running" \
    || { fail "Listener is NOT running — run 03a-db_setup_listener.sh --apply first"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# --- Unified Auditing relink verification ------------------------------------
# INFO only — DB creation works with standard auditing (uniaud_off).
# Unified Auditing is enabled in a separate step (04-db_audit_setup.sh).
_kzaiang_count=$(strings "$DB_ORACLE_HOME/bin/oracle" 2>/dev/null | grep -c "kzaiang" || printf "0")
if [ "$_kzaiang_count" -gt 0 ]; then
    ok "Unified Auditing: enabled in oracle binary (kzaiang: $_kzaiang_count)"
else
    info "Unified Auditing: not yet enabled (standard auditing active — OK for DB creation)"
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

_memory_mb="${DB_SGA_MB:-4096}"
_shared_pool_mb="${DB_SHARED_POOL_MB:-2048}"
_java_pool_mb="${DB_JAVA_POOL_MB:-512}"
_pga_mb="${DB_PGA_MB:-1024}"
_total_mb=$(( _memory_mb + _pga_mb ))
_listener_port="${DB_LISTENER_PORT:-1521}"
_listener_host="${DB_LISTENER_HOST:-$(_get_hostname)}"

printList "CDB name"          28 "$DB_CDB_NAME"
printList "PDB name"          28 "$DB_PDB_NAME"
printList "SID"               28 "$DB_SID"
printList "SGA_TARGET"        28 "${_memory_mb} MB  → post-install: ${DB_SGA_POST_MB:-2048} MB"
printList "SHARED_POOL_SIZE"  28 "${_shared_pool_mb} MB  (floor for JSERVER) → 0 (auto) after install"
printList "JAVA_POOL_SIZE"    28 "${_java_pool_mb} MB  (floor for JSERVER) → 0 (auto) after install"
printList "PGA_TARGET"        28 "${_pga_mb} MB  → post-install: ${DB_PGA_POST_MB:-512} MB"
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
# Clean – Delete existing database + datafiles
# =============================================================================
# Use when DBCA failed partway and a fresh start is needed.
# Steps:
#   1. dbca -deleteDatabase   (deregisters from inventory/oratab, stops instance)
#   2. rm -rf datafiles, admin, FRA subdirectory
#
# dbca -deleteDatabase may fail if the DB was never fully registered (partial
# create).  Errors are ignored — directory cleanup follows regardless.

if $CLEAN; then
    section "Clean – Delete DB and datafiles"

    _clean_data="${DB_DATA_DIR}/${DB_CDB_NAME}"
    _clean_admin="${DB_ADMIN_DIR:-$ORACLE_BASE/admin}/${DB_CDB_NAME}"
    _clean_fra="${DB_FAST_RECOVERY_AREA:-}/${DB_CDB_NAME}"

    info "Would remove:"
    info "  DB instance  : $DB_SID"
    info "  Datafiles    : $_clean_data"
    info "  Admin dir    : $_clean_admin"
    [ -n "${DB_FAST_RECOVERY_AREA:-}" ] && info "  FRA subdir   : $_clean_fra"

    if ! $APPLY; then
        warn "Dry-run – use --clean --apply to actually delete."
        print_summary; exit $EXIT_CODE
    fi

    info "Step 1: dbca -deleteDatabase (errors ignored if not registered) ..."
    ORACLE_BASE="$ORACLE_BASE" ORACLE_HOME="$DB_ORACLE_HOME" \
        "$DB_ORACLE_HOME/bin/dbca" -silent \
        -deleteDatabase \
        -sourceDB "$DB_SID" \
        -sysPassword "$DB_SYS_PWD" \
        2>&1 | tee -a "$LOG_FILE" || true
    ok "dbca deleteDatabase done (or skipped)"

    info "Step 2: removing datafile directories ..."
    for _d in "$_clean_data" "$_clean_admin"; do
        if [ -d "$_d" ]; then
            rm -rf "$_d" && ok "Removed: $_d" || warn "Could not remove: $_d"
        else
            ok "Already absent: $_d"
        fi
    done
    if [ -n "${DB_FAST_RECOVERY_AREA:-}" ] && [ -d "$_clean_fra" ]; then
        rm -rf "$_clean_fra" && ok "Removed: $_clean_fra" || warn "Could not remove: $_clean_fra"
    fi
    unset _clean_data _clean_admin _clean_fra _d

    ok "Clean completed — continuing with --apply"
    printf "\n" | tee -a "$LOG_FILE"
fi

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
# 2. DBCA silent – create CDB + PDB
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
    -initParams            "sga_target=${DB_SGA_MB:-4096}m,shared_pool_size=${DB_SHARED_POOL_MB:-2048}m,java_pool_size=${DB_JAVA_POOL_MB:-512}m,pga_aggregate_target=${DB_PGA_MB:-1024}m" \
    -storageType           FS \
    -datafileDestination   "${DB_DATA_DIR}" \
    -redoLogFileSize        50 \
    -emConfiguration       NONE \
    -dbOptions             "JSERVER:true,ORACLE_TEXT:false,IMEDIA:false,CWMLITE:false,SPATIAL:false,OMS:false,APEX:false,DV:false" \
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

"$DB_ORACLE_HOME/bin/sqlplus" -S /nolog << SQLEOF 2>&1 | tee -a "$LOG_FILE"
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

# MAX_STRING_SIZE=EXTENDED requires UPGRADE mode migration (utl32k.sql).
# Procedure:
#   1. STARTUP UPGRADE
#   2. @utl32k.sql in CDB$ROOT
#   3. Open all PDBs in UPGRADE mode + run utl32k.sql
#   4. Normal restart
#   5. Recompile invalid objects (utlrp.sql)

info "Restarting in UPGRADE mode for MAX_STRING_SIZE=EXTENDED migration ..."

"$DB_ORACLE_HOME/bin/sqlplus" -S /nolog << SQLEOF2 2>&1 | tee -a "$LOG_FILE"
CONNECT / AS SYSDBA
SHUTDOWN IMMEDIATE;
STARTUP UPGRADE;
@?/rdbms/admin/utl32k.sql
ALTER PLUGGABLE DATABASE ALL OPEN UPGRADE;
ALTER SESSION SET CONTAINER = ${DB_PDB_NAME};
@?/rdbms/admin/utl32k.sql
ALTER SESSION SET CONTAINER = CDB\$ROOT;
SHUTDOWN IMMEDIATE;
STARTUP;
ALTER PLUGGABLE DATABASE ALL OPEN;
@?/rdbms/admin/utlrp.sql
ALTER SESSION SET CONTAINER = ${DB_PDB_NAME};
@?/rdbms/admin/utlrp.sql
ALTER SESSION SET CONTAINER = CDB\$ROOT;
SELECT NAME, OPEN_MODE FROM V\$PDBS;
SHOW PARAMETER max_string_size;
SHOW PARAMETER processes;
SHOW PARAMETER compatible;
EXIT;
SQLEOF2
_restart_rc=${PIPESTATUS[0]}

[ "$_restart_rc" -eq 0 ] && ok "Database restarted, MAX_STRING_SIZE=EXTENDED migrated, PDB opened" \
    || warn "DB restart/migration rc=$_restart_rc – check log manually"

# =============================================================================
# 5. Post-install memory resize
# =============================================================================
# Installation used large SGA + explicit shared/java pool floors for JSERVER
# class loading.  After a successful restart we shrink to production sizing:
#   - shared_pool_size=0  → Oracle auto-tunes within sga_target
#   - java_pool_size=0    → Oracle auto-tunes within sga_target
#   - sga_target          → DB_SGA_POST_MB  (default 2048 MB)
#   - pga_aggregate_target → DB_PGA_POST_MB (default 512 MB)
# All SCOPE=BOTH — no further restart required.

section "Post-Install Memory Resize"

_sga_post="${DB_SGA_POST_MB:-2048}"
_pga_post="${DB_PGA_POST_MB:-512}"
printList "SGA_TARGET (post)"  28 "${_sga_post} MB"
printList "PGA_TARGET (post)"  28 "${_pga_post} MB"
printList "SHARED_POOL_SIZE"   28 "0  (auto-tune within SGA)"
printList "JAVA_POOL_SIZE"     28 "0  (auto-tune within SGA)"

"$DB_ORACLE_HOME/bin/sqlplus" -S /nolog << MEMEOF 2>&1 | tee -a "$LOG_FILE"
CONNECT / AS SYSDBA
-- CDB$ROOT: instance-level parameters (SGA is shared across all PDBs)
-- Remove explicit floors first — otherwise sga_target reduction may fail
ALTER SYSTEM SET shared_pool_size     = 0 SCOPE=BOTH;
ALTER SYSTEM SET java_pool_size       = 0 SCOPE=BOTH;
-- Reduce to production values (dynamic — no restart needed)
ALTER SYSTEM SET sga_target           = ${_sga_post}m SCOPE=BOTH;
ALTER SYSTEM SET pga_aggregate_target = ${_pga_post}m SCOPE=BOTH;
SHOW PARAMETER sga_target;
SHOW PARAMETER pga_aggregate_target;

-- PDB: open_cursors is PDB-modifiable — set in PDB context as well
ALTER SESSION SET CONTAINER = ${DB_PDB_NAME};
ALTER SYSTEM SET open_cursors = ${DB_OPEN_CURSORS:-1000} SCOPE=BOTH;
SHOW PARAMETER open_cursors;
EXIT;
MEMEOF
_mem_rc=${PIPESTATUS[0]}
[ "$_mem_rc" -eq 0 ] && ok "Memory resized to production values" \
    || warn "Memory resize rc=$_mem_rc – check log"
unset _sga_post _pga_post _mem_rc

# =============================================================================
# 7. Update /etc/oratab
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
info "Next step: RCU schema creation"
info "  09-Install/07-oracle_setup_repository.sh --apply"
info ""
info "Optional (after RCU): enable Unified Auditing + custom audit tablespace"
info "  relink uniaud_on: cd \$ORACLE_HOME/rdbms/lib; make -f ins_rdbms.mk uniaud_on ioracle"
info "  04-db_audit_setup.sh --apply"

# =============================================================================
print_summary
exit $EXIT_CODE
