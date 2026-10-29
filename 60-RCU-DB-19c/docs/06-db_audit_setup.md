# Step 6 – 06-db_audit_setup.sh

**Script:** `60-RCU-DB-19c/06-db_audit_setup.sh`
**Runs as:** `oracle`
**Phase:** Configure Unified Auditing in the running database (after `05-`,
best after the RCU run `09-Install/07-`)

```bash
./60-RCU-DB-19c/06-db_audit_setup.sh            # dry-run: checks + plan
./60-RCU-DB-19c/06-db_audit_setup.sh --apply    # policies, AUDITLOG, purge jobs
```

Checked against the script 2026-10-29. Background (author's wiki):
[pipperr.de – Unified Auditing migration 23ai](https://www.pipperr.de/dokuwiki/doku.php?id=dba:unified_auditing_oracle_migration_23ai);
which FMW schemas log in to this database:
[rcu_middleware_architecture.md §3](../../80-FMW-Architecture/rcu_middleware_architecture.md#3-who-logs-in-where).

---

## Purpose

Pure Unified Auditing for the RCU database:

1. Two security policies in `CDB$ROOT` (`fmw_rcu_audit_policies.sql`)
2. Default policy `ORA_SECURECONFIG` off (too verbose for a small metadata DB)
3. Dedicated `AUDITLOG` tablespace in the PDB; **all three** trails
   (standard, FGA, unified) moved there
4. Retention: daily archive-timestamp job + one purge job per trail

---

## Prerequisites

- Database running: CDB open, PDB (`DB_PDB_NAME`) open READ WRITE –
  checked by the script
- **Oracle binary linked with `uniaud_on`** – checked via
  `V$OPTION 'Unified Auditing' = TRUE`; FAIL stops the script.
  `05-db_create_database.sh` only reports the state (`kzaiang` in the binary)
  and prints the relink command; the relink is **manual**, with database and
  listener stopped:

  ```bash
  # as oracle, DB_ORACLE_HOME from environment_db.conf
  sqlplus / as sysdba <<< "shutdown immediate"
  lsnrctl stop
  cd $ORACLE_HOME/rdbms/lib && make -f ins_rdbms.mk uniaud_on ioracle
  lsnrctl start
  sqlplus / as sysdba <<< "startup"
  ```

  An out-of-place patch keeps it: `09-db_patch_rcu.sh` relinks the new home
  with `uniaud_on` when the old one has it.

Parameters (`environment_db.conf`):

| Variable | Default | Meaning |
|---|---|---|
| `DB_AUDIT_TS_SIZE_MB` | `100` | initial size of `AUDITLOG` |
| `DB_AUDIT_TS_MAX_MB` | `4000` | `MAXSIZE` (autoextend next 120 MB) |
| `DB_AUDIT_RETAIN_DAYS` | `180` | retention of all three trails |

Idempotent: when all three trails already point to `AUDITLOG` the script
stops with OK (re-run: drop `AUDITLOG` first).

---

## Block 1 – CDB$ROOT: policies

`@fmw_rcu_audit_policies.sql` as SYS in `CDB$ROOT` (drop + create, then
`AUDIT POLICY …` – active in the root):

| Policy | Content |
|---|---|
| `FMW_RCU_DB_MIN_SEC_AUDIT` | privileges `CREATE EXTERNAL JOB`, `CREATE JOB`, `CREATE ANY JOB`; actions on users, roles, profiles, synonyms, DB links, procedures, triggers, table DDL, `RENAME`, `GRANT` / `REVOKE`, `ALTER SYSTEM`, `ALTER DATABASE`, tablespaces, directories, `DELETE` / `UPDATE ON AUDSYS.AUD$UNIFIED`, `LOGON` / `LOGOFF` |
| `FMW_RCU_SEC_AUDIT_TRUNC` | `TRUNCATE TABLE` on `AUDSYS.AUD$UNIFIED` (tamper protection) |

Then `NOAUDIT POLICY ORA_SECURECONFIG;` (19c: no `CONTAINER` clause for `NOAUDIT`).
`generate_unified_audit_policy.sql` helps to derive an own policy from the
traditional audit settings of an existing database.

## Block 2 – PDB: AUDITLOG, trails, retention

In the PDB (`ALTER SESSION SET CONTAINER = <PDB>`):

```sql
-- 1. tablespace (only if missing)
CREATE SMALLFILE TABLESPACE "AUDITLOG" LOGGING
  DATAFILE '<DB_DATA_DIR>/<CDB>/<PDB>/auditlog01.dbf'
  SIZE 100M AUTOEXTEND ON NEXT 120M MAXSIZE 4000M
  EXTENT MANAGEMENT LOCAL UNIFORM SIZE 1M;

-- 2. all three trails into AUDITLOG
BEGIN
  DBMS_AUDIT_MGMT.SET_AUDIT_TRAIL_LOCATION(DBMS_AUDIT_MGMT.AUDIT_TRAIL_AUD_STD, 'AUDITLOG');
  DBMS_AUDIT_MGMT.SET_AUDIT_TRAIL_LOCATION(DBMS_AUDIT_MGMT.AUDIT_TRAIL_FGA_STD, 'AUDITLOG');
  DBMS_AUDIT_MGMT.SET_AUDIT_TRAIL_LOCATION(DBMS_AUDIT_MGMT.AUDIT_TRAIL_UNIFIED, 'AUDITLOG');
END;
/

-- 3. cleanup infrastructure (19c: AUDIT_TRAIL_ALL works here)
BEGIN
  DBMS_AUDIT_MGMT.INIT_CLEANUP(DBMS_AUDIT_MGMT.AUDIT_TRAIL_ALL, 24);
END;
/

-- 4. archive timestamp, daily 02:00, for all three trails
--    job FMW_AUDIT_ARCHIVE_TS: SET_LAST_ARCHIVE_TIMESTAMP(<trail>, SYSTIMESTAMP - 180)

-- 5. one purge job per trail (19c: CREATE_PURGE_JOB does NOT accept AUDIT_TRAIL_ALL)
--    PURGE_STD_AUDIT, PURGE_FGA_AUDIT, PURGE_UNIFIED_AUDIT
--    (audit_trail_purge_interval => 24, use_last_arch_timestamp => TRUE)

-- 6. activate the policies in the PDB
AUDIT POLICY FMW_RCU_DB_MIN_SEC_AUDIT;
AUDIT POLICY FMW_RCU_SEC_AUDIT_TRUNC;
```

---

## Verification

```sql
SELECT VALUE FROM V$OPTION WHERE PARAMETER = 'Unified Auditing';      -- TRUE

ALTER SESSION SET CONTAINER = <PDB>;
SELECT AUDIT_TRAIL, PARAMETER_VALUE FROM DBA_AUDIT_MGMT_CONFIG_PARAMS
 WHERE PARAMETER_NAME = 'DB AUDIT TABLESPACE';                        -- 3 rows AUDITLOG

SELECT JOB_NAME, JOB_STATUS FROM DBA_AUDIT_MGMT_CLEANUP_JOBS;          -- 3 purge jobs
SELECT JOB_NAME, ENABLED, STATE FROM DBA_SCHEDULER_JOBS
 WHERE JOB_NAME = 'FMW_AUDIT_ARCHIVE_TS';

SELECT POLICY_NAME, ENABLED_OPT FROM AUDIT_UNIFIED_ENABLED_POLICIES;  -- the two FMW_RCU_* policies
```

---

## Notes

- `AUDITLOG` lives in the PDB; audit records of the root (e.g. `LOGON` of
  SYS) go to the root's `AUD$UNIFIED` in `SYSAUX` – add a matching tablespace
  in the root if that matters.
- 180 days fit easily into 4 GB for a metadata database with low activity.
- RCU schema users log on many times (data source pools) – `LOGON` /
  `LOGOFF` is the largest share of the records; the purge jobs keep it bounded.
