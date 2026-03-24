#!/bin/bash
# =============================================================================
# Script   : 06-db_audit_setup.sh
# Purpose  : Configure Unified Auditing in the running FMWPDB:
#              1. Create AUDITLOG tablespace
#              2. Move unified audit trail to AUDITLOG
#              3. Create automated purge job (180 day retention)
#              4. Define and activate minimal security audit policy
# Call     : ./60-RCU-DB-19c/06-db_audit_setup.sh
#            ./60-RCU-DB-19c/06-db_audit_setup.sh --apply
#            ./60-RCU-DB-19c/06-db_audit_setup.sh --help
# Runs as  : oracle
# Requires : environment.conf, environment_db.conf, database running
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 60-RCU-DB-19c/docs/06-db_audit_setup.md
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
export ORACLE_SID="${DB_SID}"
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
    fail "  Run 02-db_patch_db_software.sh --apply to relink with uniaud_on"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi
unset _ua_val

# --- Check PDB is open --------------------------------------------------------
# tr -d ' \r' strips the space → V$PDBS returns "READ WRITE" → becomes "READWRITE"
_pdb_mode=$("$SQLPLUS" -S /nolog <<< "CONNECT / AS SYSDBA
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT OPEN_MODE FROM V\$PDBS WHERE NAME=UPPER('${DB_PDB_NAME}');
EXIT;" 2>/dev/null | tr -d ' \r')

if [ "$_pdb_mode" = "READWRITE" ]; then
    ok "PDB $DB_PDB_NAME is open (READ WRITE)"
else
    warn "PDB $DB_PDB_NAME OPEN_MODE: ${_pdb_mode:-not found} — attempting to open ..."
    "$SQLPLUS" -S /nolog << 'PDBOPEN' 2>&1 | tee -a "$LOG_FILE"
CONNECT / AS SYSDBA
BEGIN
    EXECUTE IMMEDIATE 'ALTER PLUGGABLE DATABASE ALL OPEN';
EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = -65019 THEN
        DBMS_OUTPUT.PUT_LINE('PDB already open — skipping.');
    ELSE
        RAISE;
    END IF;
END;
/
EXIT;
PDBOPEN
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

# --- Idempotenz-Check: AUDITLOG Tablespace + Trail Location schon gesetzt? ----
# Abfrage in der PDB: Anzahl der Trails die bereits auf AUDITLOG zeigen.
# Wenn alle 3 (AUD_STD, FGA_STD, UNIFIED) schon dort liegen → bereits fertig.
_already_configured=$("$SQLPLUS" -S /nolog <<< "CONNECT / AS SYSDBA
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
ALTER SESSION SET CONTAINER = ${DB_PDB_NAME};
SELECT COUNT(*) FROM DBA_AUDIT_MGMT_CONFIG_PARAMS
 WHERE PARAMETER_NAME = 'DB AUDIT TABLESPACE'
   AND PARAMETER_VALUE = 'AUDITLOG';
EXIT;" 2>/dev/null | tr -d ' \r\n')

if [ "${_already_configured:-0}" -ge 3 ] 2>/dev/null; then
    ok "Audit already configured: AUDITLOG tablespace + all 3 trails already set"
    info "  Skipping Block 1 + Block 2 — nothing to do."
    info "  To re-run anyway: drop AUDITLOG tablespace first or comment out this check."
    unset _already_configured _ts_size _ts_max _retain _data_dir
    print_summary; exit $EXIT_CODE
fi
unset _already_configured

mkdir -p "$_data_dir"

_policy_sql="$SCRIPT_DIR/fmw_rcu_audit_policies.sql"
[ -f "$_policy_sql" ] \
    && ok "Policy file: $_policy_sql" \
    || { fail "Policy file not found: $_policy_sql"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# =============================================================================
# Block 1 – CDB\$ROOT: Audit Policies (CONTAINER=ALL)
# =============================================================================
# Policies must be created and activated in CDB\$ROOT to apply to all PDBs.
# fmw_rcu_audit_policies.sql handles DROP/CREATE/AUDIT POLICY CONTAINER=ALL.

section "CDB Audit Policies (CONTAINER=ALL)"

printf "\n  SQL Block 1 started: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"

"$SQLPLUS" -S /nolog << SQLEOF 2>&1 | tee -a "$LOG_FILE"
CONNECT / AS SYSDBA
SET SERVEROUTPUT ON SIZE UNLIMITED

-- Deactivate Oracle default policy (too noisy for FMW environments)
-- Note: NOAUDIT POLICY does not support a CONTAINER clause in Oracle 19c.
NOAUDIT POLICY ORA_SECURECONFIG;
PROMPT ORA_SECURECONFIG deactivated (CDB$ROOT).

-- Deploy FMW RCU audit policies from external file
@${_policy_sql}

EXIT;
SQLEOF

_sql1_rc=${PIPESTATUS[0]}
printf "\n  SQL Block 1 finished: %s  (rc=%s)\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$_sql1_rc" | tee -a "$LOG_FILE"
[ "$_sql1_rc" -eq 0 ] \
    && ok "Audit policies deployed" \
    || { warn "Block 1 SQL rc=$_sql1_rc – review log"; EXIT_CODE=1; }

# =============================================================================
# Block 2 – PDB: Tablespace, Trail Location, Cleanup, Purge Jobs
# =============================================================================
# All purge infrastructure is PDB-local.
# 19c: INIT_CLEANUP accepts AUDIT_TRAIL_ALL.
# 19c: CREATE_PURGE_JOB must be called SEPARATELY for AUD_STD, FGA_STD, UNIFIED
#      (AUDIT_TRAIL_ALL not supported for CREATE_PURGE_JOB in 19c).

section "PDB Audit Infrastructure (${DB_PDB_NAME})"

printf "\n  SQL Block 2 started: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"

"$SQLPLUS" -S /nolog << SQLEOF 2>&1 | tee -a "$LOG_FILE"
CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = ${DB_PDB_NAME};
SET SERVEROUTPUT ON SIZE UNLIMITED

-- ===========================================================================
-- Step 0: Activate common audit policies in PDB
-- Common policies (created in CDB$ROOT) must be explicitly enabled per container.
-- AUDIT POLICY without CONTAINER clause = enables in the current container.
-- ===========================================================================
PROMPT === Step 0: Enable Common Audit Policies in PDB ===

BEGIN
    EXECUTE IMMEDIATE 'AUDIT POLICY FMW_RCU_DB_MIN_SEC_AUDIT';
    DBMS_OUTPUT.PUT_LINE('FMW_RCU_DB_MIN_SEC_AUDIT enabled in ${DB_PDB_NAME}.');
EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('FMW_RCU_DB_MIN_SEC_AUDIT: ' || SQLERRM || ' — skipping.');
END;
/

BEGIN
    EXECUTE IMMEDIATE 'AUDIT POLICY FMW_RCU_SEC_AUDIT_TRUNC';
    DBMS_OUTPUT.PUT_LINE('FMW_RCU_SEC_AUDIT_TRUNC enabled in ${DB_PDB_NAME}.');
EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('FMW_RCU_SEC_AUDIT_TRUNC: ' || SQLERRM || ' — skipping.');
END;
/

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
-- Step 2: Move all audit trails to AUDITLOG (AUD_STD + FGA_STD + UNIFIED)
-- Already-configured trails are skipped gracefully.
-- ===========================================================================
PROMPT === Step 2: Move Audit Trails to AUDITLOG ===

BEGIN
    DBMS_AUDIT_MGMT.SET_AUDIT_TRAIL_LOCATION(
        audit_trail_type           => DBMS_AUDIT_MGMT.AUDIT_TRAIL_DB_STD,
        audit_trail_location_value => 'AUDITLOG');
    DBMS_OUTPUT.PUT_LINE('AUD_STD moved to AUDITLOG.');
EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('AUD_STD: ' || SQLERRM || ' — skipping.');
END;
/

BEGIN
    DBMS_AUDIT_MGMT.SET_AUDIT_TRAIL_LOCATION(
        audit_trail_type           => DBMS_AUDIT_MGMT.AUDIT_TRAIL_FGA_STD,
        audit_trail_location_value => 'AUDITLOG');
    DBMS_OUTPUT.PUT_LINE('FGA_STD moved to AUDITLOG.');
EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('FGA_STD: ' || SQLERRM || ' — skipping.');
END;
/

BEGIN
    DBMS_AUDIT_MGMT.SET_AUDIT_TRAIL_LOCATION(
        audit_trail_type           => DBMS_AUDIT_MGMT.AUDIT_TRAIL_UNIFIED,
        audit_trail_location_value => 'AUDITLOG');
    DBMS_OUTPUT.PUT_LINE('UNIFIED moved to AUDITLOG.');
EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('UNIFIED: ' || SQLERRM || ' — skipping.');
END;
/

-- ===========================================================================
-- Step 3: Initialize cleanup (19c: AUDIT_TRAIL_ALL works for INIT_CLEANUP)
-- ===========================================================================
PROMPT === Step 3: Initialize Cleanup ===

BEGIN
    DBMS_AUDIT_MGMT.INIT_CLEANUP(
        audit_trail_type         => DBMS_AUDIT_MGMT.AUDIT_TRAIL_ALL,
        default_cleanup_interval => 24);
    DBMS_OUTPUT.PUT_LINE('Audit cleanup initialized (AUDIT_TRAIL_ALL, interval: 24h).');
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
-- Step 4: Archive Timestamp Job (all three trails, retain ${_retain} days)
-- ===========================================================================
PROMPT === Step 4: Archive Timestamp Scheduler Job ===

BEGIN
    BEGIN
        DBMS_SCHEDULER.DROP_JOB('FMW_AUDIT_ARCHIVE_TS', TRUE);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'FMW_AUDIT_ARCHIVE_TS',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN
            DBMS_AUDIT_MGMT.SET_LAST_ARCHIVE_TIMESTAMP(
                audit_trail_type  => DBMS_AUDIT_MGMT.AUDIT_TRAIL_AUD_STD,
                last_archive_time => SYSTIMESTAMP - ${_retain});
            DBMS_AUDIT_MGMT.SET_LAST_ARCHIVE_TIMESTAMP(
                audit_trail_type  => DBMS_AUDIT_MGMT.AUDIT_TRAIL_FGA_STD,
                last_archive_time => SYSTIMESTAMP - ${_retain});
            DBMS_AUDIT_MGMT.SET_LAST_ARCHIVE_TIMESTAMP(
                audit_trail_type  => DBMS_AUDIT_MGMT.AUDIT_TRAIL_UNIFIED,
                last_archive_time => SYSTIMESTAMP - ${_retain});
            DBMS_STATS.GATHER_TABLE_STATS(''AUDSYS'', ''AUD\$UNIFIED'');
        END;',
        repeat_interval => 'FREQ=DAILY;BYHOUR=2;BYMINUTE=0',
        enabled         => TRUE,
        comments        => 'Set archive timestamp for all audit trails (${_retain} day retention)');
    DBMS_OUTPUT.PUT_LINE('Scheduler job FMW_AUDIT_ARCHIVE_TS created.');
END;
/

-- ===========================================================================
-- Step 5: Purge Jobs (19c: GETRENNT für AUD_STD, FGA_STD, UNIFIED!)
-- ===========================================================================
PROMPT === Step 5: Purge Jobs (3x – 19c requirement) ===

BEGIN
    BEGIN DBMS_AUDIT_MGMT.DROP_PURGE_JOB('PURGE_STD_AUDIT');  EXCEPTION WHEN OTHERS THEN NULL; END;
    DBMS_AUDIT_MGMT.CREATE_PURGE_JOB(
        audit_trail_type           => DBMS_AUDIT_MGMT.AUDIT_TRAIL_AUD_STD,
        audit_trail_purge_interval => 24,
        audit_trail_purge_name     => 'PURGE_STD_AUDIT',
        use_last_arch_timestamp    => TRUE);
    DBMS_OUTPUT.PUT_LINE('Purge job PURGE_STD_AUDIT created.');
END;
/

BEGIN
    BEGIN DBMS_AUDIT_MGMT.DROP_PURGE_JOB('PURGE_FGA_AUDIT');  EXCEPTION WHEN OTHERS THEN NULL; END;
    DBMS_AUDIT_MGMT.CREATE_PURGE_JOB(
        audit_trail_type           => DBMS_AUDIT_MGMT.AUDIT_TRAIL_FGA_STD,
        audit_trail_purge_interval => 24,
        audit_trail_purge_name     => 'PURGE_FGA_AUDIT',
        use_last_arch_timestamp    => TRUE);
    DBMS_OUTPUT.PUT_LINE('Purge job PURGE_FGA_AUDIT created.');
END;
/

BEGIN
    BEGIN DBMS_AUDIT_MGMT.DROP_PURGE_JOB('PURGE_UNIFIED_AUDIT'); EXCEPTION WHEN OTHERS THEN NULL; END;
    DBMS_AUDIT_MGMT.CREATE_PURGE_JOB(
        audit_trail_type           => DBMS_AUDIT_MGMT.AUDIT_TRAIL_UNIFIED,
        audit_trail_purge_interval => 24,
        audit_trail_purge_name     => 'PURGE_UNIFIED_AUDIT',
        use_last_arch_timestamp    => TRUE);
    DBMS_OUTPUT.PUT_LINE('Purge job PURGE_UNIFIED_AUDIT created.');
END;
/

-- ===========================================================================
-- Verification
-- ===========================================================================
PROMPT === Verification ===

SELECT PARAMETER, VALUE FROM V\$OPTION WHERE PARAMETER = 'Unified Auditing';

COL AUDIT_TRAIL     FORMAT A20
COL PARAMETER_NAME  FORMAT A35
COL PARAMETER_VALUE FORMAT A20
SELECT AUDIT_TRAIL, PARAMETER_NAME, PARAMETER_VALUE
  FROM DBA_AUDIT_MGMT_CONFIG_PARAMS
 WHERE PARAMETER_NAME = 'DB AUDIT TABLESPACE';

COL JOB_NAME    FORMAT A30
COL JOB_STATUS  FORMAT A12
COL AUDIT_TRAIL FORMAT A20
SELECT JOB_NAME, JOB_STATUS, AUDIT_TRAIL
  FROM DBA_AUDIT_MGMT_CLEANUP_JOBS
 ORDER BY JOB_NAME;

COL JOB_NAME FORMAT A30
SELECT JOB_NAME, ENABLED, STATE
  FROM DBA_SCHEDULER_JOBS
 WHERE JOB_NAME = 'FMW_AUDIT_ARCHIVE_TS';

EXIT;
SQLEOF

_sql2_rc=${PIPESTATUS[0]}
printf "\n  SQL Block 2 finished: %s  (rc=%s)\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$_sql2_rc" | tee -a "$LOG_FILE"
[ "$_sql2_rc" -eq 0 ] \
    && ok "PDB audit infrastructure configured" \
    || { warn "Block 2 SQL rc=$_sql2_rc – review log"; EXIT_CODE=1; }

# Combined result
[ "$EXIT_CODE" -eq 0 ] && ok "Audit setup completed" || warn "Audit setup completed with warnings"

printf "\n" | tee -a "$LOG_FILE"
info "Policies active (CDB\$ROOT CONTAINER=ALL):"
info "  FMW_RCU_DB_MIN_SEC_AUDIT"
info "  FMW_RCU_SEC_AUDIT_TRUNC"
info ""
info "Next step: optional FMW_DATA tablespace"
info "  05-db_fmw_tablespace.sh --apply"
info "  (or skip and use RCU with auto-created tablespaces)"
info ""
info "Then: 09-Install/07-oracle_setup_repository.sh --apply"

unset _ts_size _ts_max _retain _data_dir _policy_sql

# =============================================================================
print_summary
exit $EXIT_CODE
