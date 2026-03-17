# Step 4 – 04-db_audit_setup.sh

**Script:** `60-RCU-DB-19c/04-db_audit_setup.sh`
**Runs as:** `oracle`
**Phase:** Configure Unified Auditing in the running database

---

## Purpose

Set up Unified Auditing in the freshly created PDB:
1. Create a dedicated `AUDITLOG` tablespace in `FMWPDB`
2. Move the unified audit trail to `AUDITLOG`
3. Create an automated purge job (keeps the tablespace bounded)
4. Define a minimal security audit policy

---

## Prerequisites

- Database running: `FMWCDB` open, `FMWPDB` open READ WRITE
- Unified Auditing relink completed (`uniaud_on` in step 3)
- Verify: `SELECT VALUE FROM V$OPTION WHERE PARAMETER='Unified Auditing';`
  → must return `TRUE`

---

## Step 1: AUDITLOG Tablespace

Connect to `FMWPDB`:

```sql
ALTER SESSION SET CONTAINER = FMWPDB;

CREATE SMALLFILE TABLESPACE "AUDITLOG"
  LOGGING
  DATAFILE '$DB_DATA_DIR/FMWCDB/FMWPDB/auditlog01.dbf'
  SIZE 100M
  AUTOEXTEND ON NEXT 120M
  MAXSIZE 4000M
  EXTENT MANAGEMENT LOCAL UNIFORM SIZE 1M;
```

Max size 4 GB: the purge job keeps actual usage well below this.
Raise if the DB is used for longer retention periods.

---

## Step 2: Move Unified Audit Trail to AUDITLOG

```sql
BEGIN
  DBMS_AUDIT_MGMT.SET_AUDIT_TRAIL_LOCATION(
    audit_trail_type         => DBMS_AUDIT_MGMT.AUDIT_TRAIL_UNIFIED,
    audit_trail_location_value => 'AUDITLOG');
END;
/
```

---

## Step 3: Initialize Cleanup

```sql
BEGIN
  DBMS_AUDIT_MGMT.INIT_CLEANUP(
    audit_trail_type       => DBMS_AUDIT_MGMT.AUDIT_TRAIL_UNIFIED,
    default_cleanup_interval => 24);
END;
/
```

---

## Step 4: Purge Job

Retain 180 days of audit data; purge daily.

```sql
-- Update archive timestamp daily (defines the retention window)
BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'AUDIT_ARCHIVE_TIMESTAMP',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN
      DBMS_AUDIT_MGMT.SET_LAST_ARCHIVE_TIMESTAMP(
        audit_trail_type => DBMS_AUDIT_MGMT.AUDIT_TRAIL_UNIFIED,
        last_archive_time => SYSTIMESTAMP - 180);
      DBMS_STATS.GATHER_TABLE_STATS(''AUDSYS'', ''AUD$UNIFIED'');
    END;',
    repeat_interval => 'FREQ=DAILY;BYHOUR=2;BYMINUTE=0',
    enabled         => TRUE,
    comments        => 'Update unified audit archive timestamp (180 day retention)');
END;
/

-- Purge records older than archive timestamp
BEGIN
  DBMS_AUDIT_MGMT.CREATE_PURGE_JOB(
    audit_trail_type          => DBMS_AUDIT_MGMT.AUDIT_TRAIL_UNIFIED,
    audit_trail_purge_interval => 24,
    audit_trail_purge_name    => 'PURGE_UNIFIED_AUDIT',
    use_last_arch_timestamp   => TRUE);
END;
/
```

For a minimal FMW RCU database with low activity, 180 days fits easily
within the 4 GB AUDITLOG tablespace.  Adjust `SYSTIMESTAMP - N` in the
scheduler job for shorter or longer retention.

---

## Step 5: Audit Policy

Disable the verbose default Oracle policy, define a focused minimal policy:

```sql
-- Disable default policy (too verbose for a small metadata DB)
NOAUDIT POLICY ORA_SECURECONFIG;

-- Drop if exists from previous run
BEGIN
  EXECUTE IMMEDIATE 'DROP AUDIT POLICY FMW_DB_MIN_SEC_AUDIT';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

-- Minimal security policy: user management, privilege changes, system changes
CREATE AUDIT POLICY FMW_DB_MIN_SEC_AUDIT
  PRIVILEGES
    CREATE EXTERNAL JOB,
    CREATE ANY JOB,
    CREATE JOB
  ACTIONS
    CREATE USER,   ALTER USER,   DROP USER,
    CREATE ROLE,   ALTER ROLE,   DROP ROLE,
    CREATE PROCEDURE, ALTER PROCEDURE, DROP PROCEDURE,
    GRANT,  REVOKE,
    ALTER SYSTEM,
    DELETE ON AUDSYS.AUD$UNIFIED,
    UPDATE ON AUDSYS.AUD$UNIFIED,
    LOGON, LOGOFF;

-- Activate for the entire CDB (applies in all PDBs)
AUDIT POLICY FMW_DB_MIN_SEC_AUDIT CONTAINER=ALL;
```

---

## Verification

```sql
-- Unified Auditing active
SELECT VALUE FROM V$OPTION WHERE PARAMETER='Unified Auditing';
-- Expected: TRUE

-- Audit trail location
SELECT AUDIT_TRAIL, TABLESPACE_NAME
FROM   DBA_AUDIT_MGMT_CONFIG_PARAMS
WHERE  AUDIT_TRAIL = 'UNIFIED AUDIT TRAIL';
-- Expected: AUDITLOG

-- Purge job status
SELECT JOB_NAME, JOB_STATUS
FROM   DBA_AUDIT_MGMT_CLEANUP_JOBS;

-- Scheduler jobs
SELECT JOB_NAME, ENABLED, STATE
FROM   DBA_SCHEDULER_JOBS
WHERE  JOB_NAME IN ('AUDIT_ARCHIVE_TIMESTAMP', 'PURGE_UNIFIED_AUDIT');

-- Active policies
SELECT POLICY_NAME, ENABLED_OPT
FROM   AUDIT_UNIFIED_ENABLED_POLICIES;
```

---

## Notes

- `CONTAINER=ALL` on the audit policy: applies from CDB to all PDBs — simpler
  than activating per PDB
- The AUDITLOG tablespace is in `FMWPDB`; CDB-level audit (`LOGON` in the
  policy) writes to the CDB AUDSYS.AUD$UNIFIED — if this matters, create a
  matching AUDITLOG tablespace in the CDB root as well
- The `FMW_DB_MIN_SEC_AUDIT` policy name matches the `GPI_DB_MIN_SEC_AUDIT`
  pattern from `pipperr.de/dba:unified_auditing_oracle_migration_23ai`
  (adapted prefix)
