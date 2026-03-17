#!/bin/bash
# =============================================================================
# Script   : 04-db_audit_setup.sh
# Purpose  : Configure Unified Auditing in the running FMWPDB:
#              1. Create AUDITLOG tablespace
#              2. Move unified audit trail to AUDITLOG
#              3. Create automated purge job (180 day retention)
#              4. Define and activate minimal security audit policy
# Call     : ./60-RCU-DB-19c/04-db_audit_setup.sh
#            ./60-RCU-DB-19c/04-db_audit_setup.sh --apply
#            ./60-RCU-DB-19c/04-db_audit_setup.sh --help
# Runs as  : oracle
# Requires : environment.conf, environment_db.conf, database running
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 60-RCU-DB-19c/docs/05-db_audit_setup.md
#            https://www.pipperr.de/dokuwiki/doku.php?id=dba:unified_auditing_oracle_migration_23ai
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"
ENV_DB_CONF="$SCRIPT_DIR/environment_db.conf"

source "$LIB" 2>/dev/null || { printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB" >&2; exit 2; }
for _f in "$ENV_CONF" "$ENV_DB_CONF"; do
    [ ! -f "$_f" ] && { printf "\033[31mFATAL\033[0m: Config not found: %s\n" "$_f" >&2; exit 2; }
    source "$_f"
done
unset _f

DIAG_LOG_DIR="${DIAG_LOG_DIR:-$ROOT_DIR/log/$(date +%Y%m%d)}"
init_log "$DIAG_LOG_DIR"

export ORACLE_HOME="$DB_ORACLE_HOME"
SQLPLUS="$DB_ORACLE_HOME/bin/sqlplus"

# =============================================================================
# Arguments
# =============================================================================

APPLY=false

_usage() {
    printf "Usage: %s [--apply] [--help]\n\n" "$(basename "$0")"
    printf "  %-12s %s\n" "(none)"  "Dry-run: show configuration, no changes"
    printf "  %-12s %s\n" "--apply" "Create AUDITLOG tablespace + purge job + policy"
    printf "  %-12s %s\n" "--help"  "Show this help"
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
printf "\n\033[1m  IHateWeblogic – DB Audit Setup\033[0m\n"               | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"                          | tee -a "$LOG_FILE"
printf "  Date        : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"             | tee -a "$LOG_FILE"
printf "  Mode        : %s\n" "$( $APPLY && printf 'APPLY' || printf 'DRY-RUN')" | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"                                 | tee -a "$LOG_FILE"
printLine

# =============================================================================
# Pre-checks
# =============================================================================

section "Pre-checks"

[ -x "$SQLPLUS" ] \
    && ok "sqlplus found: $SQLPLUS" \
    || { fail "sqlplus not found: $SQLPLUS"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# --- Check DB is running ------------------------------------------------------
_ping=$("$DB_ORACLE_HOME/bin/sqlplus" -S /nolog <<< "CONNECT / AS SYSDBA
SELECT 'DB_UP' FROM DUAL;
EXIT;" 2>/dev/null)

if printf "%s" "$_ping" | grep -q "DB_UP"; then
    ok "Database is running"
else
    fail "Database is not running or OS authentication failed"
    info "  Start DB: ORACLE_HOME=$DB_ORACLE_HOME $DB_ORACLE_HOME/bin/sqlplus /nolog"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi
unset _ping

# --- Check Unified Auditing is active -----------------------------------------
_ua_val=$("$SQLPLUS" -S /nolog <<< "CONNECT / AS SYSDBA
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT VALUE FROM V\$OPTION WHERE PARAMETER='Unified Auditing';
EXIT;" 2>/dev/null | tr -d ' \r')

if [ "$_ua_val" = "TRUE" ]; then
    ok "Unified Auditing is active (V\$OPTION: TRUE)"
else
    fail "Unified Auditing is NOT active (V\$OPTION: ${_ua_val:-empty})"
    fail "  Run 02-db_patch_autoupgrade.sh --apply to relink with uniaud_on"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi
unset _ua_val

# --- Check PDB is open --------------------------------------------------------
_pdb_mode=$("$SQLPLUS" -S /nolog <<< "CONNECT / AS SYSDBA
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT OPEN_MODE FROM V\$PDBS WHERE NAME=UPPER('${DB_PDB_NAME}');
EXIT;" 2>/dev/null | tr -d ' \r')

if [ "$_pdb_mode" = "READ WRITE" ]; then
    ok "PDB $DB_PDB_NAME is open (READ WRITE)"
else
    warn "PDB $DB_PDB_NAME OPEN_MODE: ${_pdb_mode:-not found}"
    "$SQLPLUS" -S /nolog <<< "CONNECT / AS SYSDBA
ALTER PLUGGABLE DATABASE ${DB_PDB_NAME} OPEN;
EXIT;" 2>&1 | tee -a "$LOG_FILE"
fi
unset _pdb_mode

# =============================================================================
# Summary
# =============================================================================

section "Audit Configuration"

_ts_size="${DB_AUDIT_TS_SIZE_MB:-100}"
_ts_max="${DB_AUDIT_TS_MAX_MB:-4000}"
_retain="${DB_AUDIT_RETAIN_DAYS:-180}"
_data_dir="${DB_DATA_DIR}/${DB_CDB_NAME}/${DB_PDB_NAME}"

printList "PDB"               28 "$DB_PDB_NAME"
printList "AUDITLOG size"     28 "${_ts_size} MB initial / ${_ts_max} MB max"
printList "Retention"         28 "${_retain} days"
printList "Datafile path"     28 "${_data_dir}/auditlog01.dbf"

if ! $APPLY; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "Dry-run – use --apply to configure auditing."
    print_summary; exit $EXIT_CODE
fi

mkdir -p "$_data_dir"

# =============================================================================
# Apply Audit Setup (single SQL block for atomicity)
# =============================================================================

section "Applying Audit Configuration"

printf "\n  SQL started: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"

"$SQLPLUS" -S /nolog 2>&1 | tee -a "$LOG_FILE" << SQLEOF
CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = ${DB_PDB_NAME};

-- ===========================================================================
-- Step 1: AUDITLOG Tablespace
-- ===========================================================================
PROMPT === Step 1: AUDITLOG Tablespace ===

DECLARE
    v_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM DBA_TABLESPACES WHERE TABLESPACE_NAME = 'AUDITLOG';
    IF v_count = 0 THEN
        EXECUTE IMMEDIATE
            'CREATE SMALLFILE TABLESPACE "AUDITLOG" LOGGING ' ||
            'DATAFILE ''${_data_dir}/auditlog01.dbf'' ' ||
            'SIZE ${_ts_size}M AUTOEXTEND ON NEXT 120M MAXSIZE ${_ts_max}M ' ||
            'EXTENT MANAGEMENT LOCAL UNIFORM SIZE 1M';
        DBMS_OUTPUT.PUT_LINE('AUDITLOG tablespace created.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('AUDITLOG tablespace already exists - skipping.');
    END IF;
END;
/

-- ===========================================================================
-- Step 2: Move unified audit trail to AUDITLOG
-- ===========================================================================
PROMPT === Step 2: Move Unified Audit Trail ===

BEGIN
    DBMS_AUDIT_MGMT.SET_AUDIT_TRAIL_LOCATION(
        audit_trail_type         => DBMS_AUDIT_MGMT.AUDIT_TRAIL_UNIFIED,
        audit_trail_location_value => 'AUDITLOG');
    DBMS_OUTPUT.PUT_LINE('Unified audit trail moved to AUDITLOG.');
END;
/

-- ===========================================================================
-- Step 3: Initialize cleanup
-- ===========================================================================
PROMPT === Step 3: Initialize Cleanup ===

BEGIN
    DBMS_AUDIT_MGMT.INIT_CLEANUP(
        audit_trail_type         => DBMS_AUDIT_MGMT.AUDIT_TRAIL_UNIFIED,
        default_cleanup_interval => 24);
    DBMS_OUTPUT.PUT_LINE('Audit cleanup initialized (interval: 24h).');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -46258 THEN
            DBMS_OUTPUT.PUT_LINE('Audit cleanup already initialized - skipping.');
        ELSE
            RAISE;
        END IF;
END;
/

-- ===========================================================================
-- Step 4: Purge job – archive timestamp (update daily, retain ${_retain} days)
-- ===========================================================================
PROMPT === Step 4: Archive Timestamp Scheduler Job ===

BEGIN
    BEGIN
        DBMS_SCHEDULER.DROP_JOB('AUDIT_ARCHIVE_TIMESTAMP', TRUE);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'AUDIT_ARCHIVE_TIMESTAMP',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN
            DBMS_AUDIT_MGMT.SET_LAST_ARCHIVE_TIMESTAMP(
                audit_trail_type  => DBMS_AUDIT_MGMT.AUDIT_TRAIL_UNIFIED,
                last_archive_time => SYSTIMESTAMP - ${_retain});
            DBMS_STATS.GATHER_TABLE_STATS(''AUDSYS'', ''AUD\$UNIFIED'');
        END;',
        repeat_interval => 'FREQ=DAILY;BYHOUR=2;BYMINUTE=0',
        enabled         => TRUE,
        comments        => 'Update unified audit archive timestamp (${_retain} day retention)');
    DBMS_OUTPUT.PUT_LINE('Scheduler job AUDIT_ARCHIVE_TIMESTAMP created.');
END;
/

-- ===========================================================================
-- Step 5: Purge job
-- ===========================================================================
PROMPT === Step 5: Purge Job ===

BEGIN
    BEGIN
        DBMS_AUDIT_MGMT.DROP_PURGE_JOB('PURGE_UNIFIED_AUDIT');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    DBMS_AUDIT_MGMT.CREATE_PURGE_JOB(
        audit_trail_type          => DBMS_AUDIT_MGMT.AUDIT_TRAIL_UNIFIED,
        audit_trail_purge_interval => 24,
        audit_trail_purge_name    => 'PURGE_UNIFIED_AUDIT',
        use_last_arch_timestamp   => TRUE);
    DBMS_OUTPUT.PUT_LINE('Purge job PURGE_UNIFIED_AUDIT created.');
END;
/

-- ===========================================================================
-- Step 6: Minimal security audit policy
-- ===========================================================================
PROMPT === Step 6: Audit Policy ===

NOAUDIT POLICY ORA_SECURECONFIG;

BEGIN
    EXECUTE IMMEDIATE 'DROP AUDIT POLICY FMW_DB_MIN_SEC_AUDIT';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

CREATE AUDIT POLICY FMW_DB_MIN_SEC_AUDIT
  PRIVILEGES
    CREATE EXTERNAL JOB,
    CREATE ANY JOB,
    CREATE JOB
  ACTIONS
    CREATE USER,  ALTER USER,  DROP USER,
    CREATE ROLE,  ALTER ROLE,  DROP ROLE,
    CREATE PROCEDURE, ALTER PROCEDURE, DROP PROCEDURE,
    GRANT, REVOKE,
    ALTER SYSTEM,
    DELETE ON AUDSYS.AUD\$UNIFIED,
    UPDATE ON AUDSYS.AUD\$UNIFIED,
    LOGON, LOGOFF;

AUDIT POLICY FMW_DB_MIN_SEC_AUDIT CONTAINER=ALL;
PROMPT Policy FMW_DB_MIN_SEC_AUDIT activated.

-- ===========================================================================
-- Verification
-- ===========================================================================
PROMPT === Verification ===

SELECT PARAMETER, VALUE FROM V\$OPTION WHERE PARAMETER = 'Unified Auditing';

SELECT AUDIT_TRAIL, TABLESPACE_NAME
FROM   DBA_AUDIT_MGMT_CONFIG_PARAMS
WHERE  AUDIT_TRAIL = 'UNIFIED AUDIT TRAIL';

SELECT JOB_NAME, JOB_STATUS
FROM   DBA_AUDIT_MGMT_CLEANUP_JOBS;

SELECT JOB_NAME, ENABLED, STATE
FROM   DBA_SCHEDULER_JOBS
WHERE  JOB_NAME IN ('AUDIT_ARCHIVE_TIMESTAMP', 'PURGE_UNIFIED_AUDIT');

SELECT POLICY_NAME, ENABLED_OPT
FROM   AUDIT_UNIFIED_ENABLED_POLICIES
WHERE  POLICY_NAME = 'FMW_DB_MIN_SEC_AUDIT';

EXIT;
SQLEOF

_sql_rc=${PIPESTATUS[0]}
printf "\n  SQL finished: %s  (rc=%s)\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$_sql_rc" | tee -a "$LOG_FILE"

[ "$_sql_rc" -eq 0 ] && ok "Audit setup completed" \
    || { warn "SQL exited with rc=$_sql_rc – review log for details"; EXIT_CODE=1; }

printf "\n" | tee -a "$LOG_FILE"
info "Next step: optional FMW_DATA tablespace"
info "  05-db_fmw_tablespace.sh --apply"
info "  (or skip and use RCU with auto-created tablespaces)"
info ""
info "Then: 09-Install/07-oracle_setup_repository.sh --apply"

unset _ts_size _ts_max _retain _data_dir

# =============================================================================
print_summary
exit $EXIT_CODE
