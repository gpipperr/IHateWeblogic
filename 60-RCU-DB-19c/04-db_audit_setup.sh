#!/bin/bash
# =============================================================================
# Script   : 04-db_audit_setup.sh
# Purpose  : Configure Unified Auditing in the running CDB / PDB:
#              Pre-checks: PMON of DB_SID runs from DB_ORACLE_HOME, SYSDBA login,
#                       uniaud_on linked (--relink: stop DB + listener, relink,
#                       start again)
#              Block 1 (CDB$ROOT): common audit policies FMW_RCU_* (CONTAINER=ALL,
#                       enabled in the root = all containers), ORA_SECURECONFIG off
#              Block 2 (PDB): ORA_SECURECONFIG off, AUDITLOG tablespace, all three
#                       trails (AUD_STD / FGA_STD / UNIFIED) moved there, cleanup
#                       init, archive-timestamp job (DB_AUDIT_RETAIN_DAYS), three
#                       purge jobs; skipped when already configured
#              Check   : FMW_RCU_* policies enabled as seen from the PDB
# Call     : ./60-RCU-DB-19c/04-db_audit_setup.sh
#            ./60-RCU-DB-19c/04-db_audit_setup.sh --apply
#            ./60-RCU-DB-19c/04-db_audit_setup.sh --relink --apply
#            ./60-RCU-DB-19c/04-db_audit_setup.sh --help
# Runs as  : oracle
# Requires : environment.conf, environment_db.conf, database running
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 60-RCU-DB-19c/docs/04-db_audit_setup.md
#            https://www.pipperr.de/dokuwiki/doku.php?id=dba:unified_auditing_oracle_migration_23ai
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"
ENV_DB_CONF="$SCRIPT_DIR/environment_db.conf"

source "$LIB" 2>/dev/null || { printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB" >&2; exit 2; }
for _f in "$ENV_CONF" "$ENV_DB_CONF"; do
    [ ! -f "$_f" ] && { printf "\033[31mFATAL\033[0m: Config not found: %s\n" "$_f" >&2
        [ "$_f" = "$ENV_DB_CONF" ] && printf "  Create it (interview from the template): ./60-RCU-DB-19c/00a-db_env_interview.sh --apply\n" >&2
        exit 2; }
    source "$_f"
done
unset _f

DIAG_LOG_DIR="${DIAG_LOG_DIR:-$ROOT_DIR/log/$(date +%Y%m%d)}"
init_log "$DIAG_LOG_DIR"

DB_ORACLE_HOME="${DB_ORACLE_HOME%/}"   # a trailing / is another home for the SYSDBA login
export ORACLE_HOME="$DB_ORACLE_HOME"
export ORACLE_SID="${DB_SID}"
SQLPLUS="$DB_ORACLE_HOME/bin/sqlplus"

# _sql "statements" - local sqlplus / as sysdba; TNS_ADMIN = the home's
# network/admin, so an instance started here resolves its local_listener alias
_sql() {
    TNS_ADMIN="$DB_ORACLE_HOME/network/admin" "$SQLPLUS" -S -L / as sysdba <<SQLEOF 2>&1
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 300
$1
EXIT;
SQLEOF
}
_lsnr() { TNS_ADMIN="$DB_ORACLE_HOME/network/admin" "$DB_ORACLE_HOME/bin/lsnrctl" "$1" LISTENER 2>&1; }
_pmon_home() {   # home of the running PMON of DB_SID (empty = down)
    local pid; pid="$(pgrep -f "^ora_pmon_${DB_SID}$" | head -1)"
    [ -n "$pid" ] && readlink -f "/proc/$pid/exe" 2>/dev/null | sed 's#/bin/oracle$##'
}
_uniaud() { ar -t "$DB_ORACLE_HOME/rdbms/lib/libknlopt.a" 2>/dev/null | grep -q kzaiang && printf on || printf off; }

# =============================================================================
# Arguments
# =============================================================================

APPLY=false
RELINK=false

_usage() {
    printf "Usage: %s [--apply] [--help]\n\n" "$(basename "$0")"
    printf "  %-12s %s\n" "(none)"  "Dry-run: show configuration, no changes"
    printf "  %-12s %s\n" "--apply" "Create AUDITLOG tablespace + purge job + policy"
    printf "  %-12s %s\n" "--relink" "Unified Auditing not linked: stop DB + listener, relink"
    printf "  %-12s %s\n" ""         "uniaud_on, start again (with --apply; FMW domain must be down)"
    printf "  %-12s %s\n" "--help"  "Show this help"
    exit 0
}

for _arg in "$@"; do
    case "$_arg" in
        --apply)   APPLY=true ;;
        --relink)  RELINK=true ;;
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
printf "  Mode        : %s\n" "$( $APPLY && printf 'APPLY' || printf 'DRY-RUN')$($RELINK && printf ' + RELINK')" | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"                                 | tee -a "$LOG_FILE"
printLine

# =============================================================================
# Pre-checks
# =============================================================================

section "Pre-checks"

[ -x "$SQLPLUS" ] \
    && ok "sqlplus found: $SQLPLUS" \
    || { fail "sqlplus not found: $SQLPLUS"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# --- Check DB is running: PMON, then SYSDBA login -----------------------------
# The local SYSDBA login only finds the instance with exactly the ORACLE_HOME /
# ORACLE_SID it was started with - otherwise "idle instance" although it runs.
# PMON tells which home really runs (2026-11-03).
_run_home="$(_pmon_home)"
if [ -z "$_run_home" ]; then
    fail "Database $DB_SID is not running (no ora_pmon_${DB_SID} process)"
    _others="$(pgrep -fa '^ora_pmon_' | sed 's/.*ora_pmon_//' | tr '\n' ' ')"
    [ -n "$_others" ] && info "  Running instances: ${_others}– DB_SID in environment_db.conf?"
    info "  Start: ORACLE_HOME=$DB_ORACLE_HOME ORACLE_SID=$DB_SID $SQLPLUS / as sysdba <<< startup"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
elif [ "$_run_home" != "$(readlink -f "$DB_ORACLE_HOME")" ]; then
    fail "Database $DB_SID runs from $_run_home, DB_ORACLE_HOME = $DB_ORACLE_HOME"
    info "  Set DB_ORACLE_HOME in environment_db.conf (00a-db_env_interview.sh --reset --apply)"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi
ok "Database $DB_SID is running (PMON from $_run_home)"

_ping="$(_sql "SELECT 'DB_UP' FROM DUAL;")"
if printf "%s" "$_ping" | grep -q "DB_UP"; then
    ok "SYSDBA login (OS authentication)"
else
    fail "SYSDBA login failed: $(printf "%s" "$_ping" | grep -m1 -E '(ORA|SP2)-[0-9]+' | tr -d '\r')"
    info "  ORA-01031: oracle not in the OSDBA group of the home, or SQLNET.AUTHENTICATION_SERVICES"
    info "  = (NONE) in $DB_ORACLE_HOME/network/admin/sqlnet.ora"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi
unset _ping _run_home _others

# --- Check Unified Auditing is active -----------------------------------------
_ua_val="$(_sql "SELECT VALUE FROM V\$OPTION WHERE PARAMETER='Unified Auditing';" | tr -d ' \r\n')"

if [ "$_ua_val" = "TRUE" ]; then
    ok "Unified Auditing is active (V\$OPTION: TRUE)"
elif ! $RELINK; then
    fail "Unified Auditing is NOT active (V\$OPTION: ${_ua_val:-empty}, libknlopt.a: uniaud $(_uniaud))"
    info "  Relink (DB + listener are stopped and started again):"
    info "    ./60-RCU-DB-19c/04-db_audit_setup.sh --relink --apply"
    info "  or by hand: docs/04-db_audit_setup.md (Prerequisites)"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
else
    section "Relink uniaud_on"
    warn "Unified Auditing is NOT active (V\$OPTION: ${_ua_val:-empty}) – --relink"
    # the FMW domain loses its repository connections while the DB is down
    _wls="$(pgrep -f 'weblogic.Server' | wc -l)"
    if [ "$_wls" -gt 0 ]; then
        fail "$_wls WebLogic server process(es) running on this host – stop the domain first"
        info "  01-Run/startStop.sh stop-all --apply, then run again"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi
    [ "${LOCAL_REP_DB:-true}" = "false" ] && warn "LOCAL_REP_DB=false – a domain on another host must be down too"
    if ! $APPLY; then
        info "  --relink --apply would:"
        info "    1 SHUTDOWN IMMEDIATE ($DB_SID), lsnrctl stop LISTENER"
        info "    2 cd $DB_ORACLE_HOME/rdbms/lib; make -f ins_rdbms.mk uniaud_on ioracle"
        info "    3 lsnrctl start LISTENER, STARTUP, ALTER PLUGGABLE DATABASE ALL OPEN"
        info "    4 check V\$OPTION 'Unified Auditing' = TRUE"
        warn "Dry-run – use --relink --apply"
        print_summary; exit $EXIT_CODE
    fi
    # 1 stop
    _sql "SHUTDOWN IMMEDIATE" | tee -a "$LOG_FILE" | grep -E 'ORACLE instance shut down|ORA-' | head -3
    [ -z "$(_pmon_home)" ] && ok "Database $DB_SID stopped" \
        || { fail "Database still running – see $LOG_FILE"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
    _lsnr stop >> "$LOG_FILE" && ok "Listener stopped" || warn "Listener stop reported an error (not running?)"
    # 2 relink
    info "make -f ins_rdbms.mk uniaud_on ioracle ..."
    ( cd "$DB_ORACLE_HOME/rdbms/lib" && make -f ins_rdbms.mk uniaud_on ioracle ) >> "$LOG_FILE" 2>&1
    _make_rc=$?
    if [ "$_make_rc" -eq 0 ] && [ "$(_uniaud)" = "on" ]; then
        ok "uniaud_on linked"
    else
        fail "Relink failed (rc=$_make_rc, uniaud $(_uniaud)) – see $LOG_FILE; starting the DB again"
        EXIT_CODE=2
    fi
    # 3 start (also after a failed relink - the old binary stays in place)
    _lsnr start >> "$LOG_FILE" && ok "Listener started" || fail "Listener start failed – see $LOG_FILE"
    _sql "STARTUP
ALTER PLUGGABLE DATABASE ALL OPEN;" | tee -a "$LOG_FILE" | grep -E 'Database opened|ORA-' | head -3
    [ -n "$(_pmon_home)" ] && ok "Database $DB_SID started" \
        || { fail "Database did not start – see $LOG_FILE"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
    [ "$EXIT_CODE" -ge 2 ] && { print_summary; exit $EXIT_CODE; }
    # systemd units (RemainAfterExit=yes) stay "active" - that matches again now
    if systemctl is-enabled oracle-db oracle-listener >/dev/null 2>&1; then
        info "  systemd units: stopped/started outside systemd – state matches again;"
        info "  a unit in 'failed': systemctl reset-failed oracle-listener oracle-db (root)"
    fi
    # 4 check
    _ua_val="$(_sql "SELECT VALUE FROM V\$OPTION WHERE PARAMETER='Unified Auditing';" | tr -d ' \r\n')"
    [ "$_ua_val" = "TRUE" ] && ok "Unified Auditing is active (V\$OPTION: TRUE)" \
        || { fail "Unified Auditing still NOT active (V\$OPTION: ${_ua_val:-empty})"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
    unset _wls _make_rc
    section "Pre-checks (continued)"
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
elif ! $APPLY; then
    warn "PDB $DB_PDB_NAME OPEN_MODE: ${_pdb_mode:-not found} — --apply opens it (ALTER PLUGGABLE DATABASE ALL OPEN)"
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

# Block 1 (policies) always runs - it is re-runnable (NOAUDIT, DROP, CREATE)
# and brings older installations to the common policies (2026-11-02)
_block2=true
if [ "${_already_configured:-0}" -ge 3 ] 2>/dev/null; then
    ok "AUDITLOG tablespace + all 3 trails already set – Block 2 (tablespace, jobs) skipped"
    info "  Policies (Block 1) are deployed again. Jobs only: run steps 4-5 of Block 2 by hand"
    info "  (docs/04-db_audit_setup.md – both are drop + create)"
    _block2=false
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
# Common policies (CREATE ... CONTAINER = ALL) created and enabled in CDB\$ROOT
# apply to all containers. fmw_rcu_audit_policies.sql: NOAUDIT/DROP/CREATE/AUDIT.

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

if $_block2; then
section "PDB Audit Infrastructure (${DB_PDB_NAME})"

printf "\n  SQL Block 2 started: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"

"$SQLPLUS" -S /nolog << SQLEOF 2>&1 | tee -a "$LOG_FILE"
CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = ${DB_PDB_NAME};
SET SERVEROUTPUT ON SIZE UNLIMITED

-- ===========================================================================
-- Step 0: ORA_SECURECONFIG off in the PDB too (enabled per container by
-- DBCA; the FMW_RCU_* common policies come from CDB$ROOT, Block 1)
-- ===========================================================================
PROMPT === Step 0: ORA_SECURECONFIG off in the PDB ===

BEGIN
    EXECUTE IMMEDIATE 'NOAUDIT POLICY ORA_SECURECONFIG';
    DBMS_OUTPUT.PUT_LINE('ORA_SECURECONFIG deactivated in ${DB_PDB_NAME}.');
EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('ORA_SECURECONFIG: ' || SQLERRM || ' — skipping.');
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
            -- stats for the purge DELETE; own block: a stats error must not
            -- fail the job (the archive timestamp above is what matters).
            -- ORA-20000 seen sporadically under load (partition dropped /
            -- added by purge or audit writes while gathering) -> 3 tries
            FOR i IN 1 .. 3 LOOP
                BEGIN
                    DBMS_STATS.GATHER_TABLE_STATS(ownname => ''AUDSYS'', tabname => ''AUD\$UNIFIED'');
                    EXIT;
                EXCEPTION WHEN OTHERS THEN
                    SYS.DBMS_SYSTEM.KSDWRT(2, ''FMW_AUDIT_ARCHIVE_TS: stats AUDSYS.AUD\$UNIFIED try '' || i || '' failed: '' || SQLERRM);
                    IF i < 3 THEN DBMS_SESSION.SLEEP(120); END IF;
                END;
            END LOOP;
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
fi
unset _block2

# The policies must be effective where the RCU schemas live (until 2026-11-02
# they were root-local and the PDB step swallowed "ORA-46357 not found")
_pol_pdb=$("$SQLPLUS" -S /nolog <<< "CONNECT / AS SYSDBA
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
ALTER SESSION SET CONTAINER = ${DB_PDB_NAME};
SELECT COUNT(DISTINCT POLICY_NAME) FROM AUDIT_UNIFIED_ENABLED_POLICIES
 WHERE POLICY_NAME IN ('FMW_RCU_DB_MIN_SEC_AUDIT', 'FMW_RCU_SEC_AUDIT_TRUNC');
EXIT;" 2>/dev/null | tr -d ' \r\n')
if [ "${_pol_pdb:-0}" = "2" ]; then
    ok "FMW_RCU_DB_MIN_SEC_AUDIT + FMW_RCU_SEC_AUDIT_TRUNC enabled in ${DB_PDB_NAME}"
else
    fail "FMW_RCU_* policies not enabled in ${DB_PDB_NAME} (found ${_pol_pdb:-?} of 2) – see the log of Block 1"
    EXIT_CODE=2
fi
unset _pol_pdb

# Combined result
[ "$EXIT_CODE" -eq 0 ] && ok "Audit setup completed" || warn "Audit setup completed with warnings"

printf "\n" | tee -a "$LOG_FILE"
info "Policies active (common, enabled in CDB\$ROOT = all containers):"
info "  FMW_RCU_DB_MIN_SEC_AUDIT"
info "  FMW_RCU_SEC_AUDIT_TRUNC"
info ""
info "Next step: FMW_DATA tablespace for all RCU schemas"
info "  05-db_fmw_tablespace.sh --apply"
info ""
info "Then: 06-db_rcu_profile.sh --apply, 08-db_auto_start.sh --apply,"
info "      09-Install/07-oracle_setup_repository.sh --apply"

unset _ts_size _ts_max _retain _data_dir _policy_sql

# =============================================================================
print_summary
exit $EXIT_CODE
