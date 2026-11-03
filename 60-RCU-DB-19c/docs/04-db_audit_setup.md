# Step 4 – 04-db_audit_setup.sh

**Script:** `60-RCU-DB-19c/04-db_audit_setup.sh`
**Runs as:** `oracle`
**Phase:** Configure Unified Auditing in the running database – after `03-`
and the `uniaud_on` relink (`--relink`), before `05-` / `06-` / the RCU run
(`09-Install/07-`); the policies do not depend on the RCU schemas, a later
run works too

```bash
./60-RCU-DB-19c/04-db_audit_setup.sh                    # dry-run: checks + plan
./60-RCU-DB-19c/04-db_audit_setup.sh --relink --apply    # only when not linked: uniaud_on relink
./60-RCU-DB-19c/04-db_audit_setup.sh --apply            # policies, AUDITLOG, purge jobs
```

Checked against the script 2026-11-02. Background (author's wiki):
[pipperr.de – Unified Auditing migration 23ai](https://www.pipperr.de/dokuwiki/doku.php?id=dba:unified_auditing_oracle_migration_23ai);
which FMW schemas log in to this database:
[rcu_middleware_architecture.md §3](../../80-FMW-Architecture/rcu_middleware_architecture.md#3-who-logs-in-where).

---

## Purpose

Pure Unified Auditing for the RCU database:

1. Two **common** security policies, created and enabled in `CDB$ROOT`
   (`fmw_rcu_audit_policies.sql`, `CONTAINER = ALL`) – effective in all
   containers, including the PDB with the RCU schemas
2. Default policy `ORA_SECURECONFIG` off in the root and in the PDB (too
   verbose for a small metadata DB)
3. Dedicated `AUDITLOG` tablespace in the PDB; **all three** trails
   (standard, FGA, unified) moved there
4. Retention: daily archive-timestamp job + one purge job per trail
5. Check: both `FMW_RCU_*` policies enabled as seen from the PDB (FAIL
   otherwise)

> **Fixed 2026-11-02:** until then the policies were created **without**
> `CONTAINER = ALL` – root-local. The PDB step `AUDIT POLICY …` failed with
> `ORA-46357 … not found` and swallowed it (`— skipping`), so the RCU schemas
> in the PDB were **not** audited by them (test host: only `ORA_SECURECONFIG`
> + `ORA_LOGON_FAILURES` enabled in the PDB). Re-run `04- --apply` on such a
> database: Block 1 runs again (re-runnable) and creates the common policies.

---

## Prerequisites

- Database running, checked in two steps (FAIL stops the script, with the
  reason):
  1. **PMON** `ora_pmon_<DB_SID>` exists and its binary
     (`/proc/<pid>/exe`) lies in `DB_ORACLE_HOME` – otherwise the running
     instances / the real home are printed. Reason: the local SYSDBA login
     only reaches the instance with exactly the `ORACLE_HOME` / `ORACLE_SID`
     it was started with, else "Connected to an idle instance" although the
     DB runs (a trailing `/` in `DB_ORACLE_HOME` is stripped).
  2. **SYSDBA login** (`SELECT 'DB_UP'`) – on error the ORA message is shown
     (ORA-01031: `oracle` not in the OSDBA group, or
     `SQLNET.AUTHENTICATION_SERVICES = (NONE)` in the home's `sqlnet.ora`).
- PDB
  (`DB_PDB_NAME`) open READ WRITE – with `--apply` the script opens it
  (`ALTER PLUGGABLE DATABASE ALL OPEN`), the dry-run only reports it
- **Oracle binary linked with `uniaud_on`** – checked via
  `V$OPTION 'Unified Auditing' = TRUE`; FAIL stops the script.
  `03-db_create_database.sh` only reports the state (`kzaiang` in the binary).
  **`--relink --apply`** does the relink: FAIL when `weblogic.Server`
  processes run on the host (the domain loses its repository connections –
  stop it first; with `LOCAL_REP_DB=false` only a WARN for the remote
  domain), then `SHUTDOWN IMMEDIATE`, `lsnrctl stop`, `make … uniaud_on
  ioracle` (checked: `kzaiang` in `libknlopt.a`), `lsnrctl start`, `STARTUP`
  + `ALTER PLUGGABLE DATABASE ALL OPEN` (also after a failed relink – the old
  binary stays), `V$OPTION` again; then the normal checks continue (with
  `--apply` the setup runs in the same call). `--relink` without `--apply`
  only prints the plan. Same by hand:

  ```bash
  # as oracle, values from environment_db.conf
  export ORACLE_HOME=$DB_ORACLE_HOME ORACLE_SID=$DB_SID TNS_ADMIN=$DB_ORACLE_HOME/network/admin
  sqlplus / as sysdba <<< "shutdown immediate"
  $ORACLE_HOME/bin/lsnrctl stop        # with the systemd units: systemctl stop oracle-db oracle-listener (root)
  cd $ORACLE_HOME/rdbms/lib && make -f ins_rdbms.mk uniaud_on ioracle
  $ORACLE_HOME/bin/lsnrctl start       # or: systemctl start oracle-listener oracle-db (root)
  sqlplus / as sysdba <<< "startup"
  sqlplus -S / as sysdba <<< "select value from v\$option where parameter='Unified Auditing';"   # TRUE
  ```

  With the systemd units of `02-` / `08-` installed the script stops and
  starts outside systemd: the units (`RemainAfterExit=yes`) stay "active",
  which matches again once the DB runs; a unit in `failed` needs
  `systemctl reset-failed oracle-listener oracle-db` (root). By hand you can
  also stop / start through systemd.

  An out-of-place patch keeps it: `09-db_patch_rcu.sh` relinks the new home
  with `uniaud_on` when the old one has it.

Parameters (`environment_db.conf`):

| Variable | Default | Meaning |
|---|---|---|
| `DB_AUDIT_TS_SIZE_MB` | `100` | initial size of `AUDITLOG` |
| `DB_AUDIT_TS_MAX_MB` | `4000` | `MAXSIZE` (autoextend next 120 MB) |
| `DB_AUDIT_RETAIN_DAYS` | `180` | retention of all three trails |

Re-run: Block 1 (policies) always runs – it is re-runnable (`NOAUDIT`,
`DROP`, `CREATE`, `AUDIT`). Block 2 is skipped when all three trails already
point to `AUDITLOG` (`--apply` only); to recreate just the jobs run steps 4–5
of Block 2 by hand (both are drop + create) – do **not** drop `AUDITLOG`, it
holds the moved audit trails.

---

## Block 1 – CDB$ROOT: policies

First `NOAUDIT POLICY ORA_SECURECONFIG;` (19c: no `CONTAINER` clause for
`NOAUDIT` – it acts on the root only), then `@fmw_rcu_audit_policies.sql` as
SYS in `CDB$ROOT`: for each policy `NOAUDIT` + `DROP` (an enabled policy
cannot be dropped; errors ignored), `CREATE AUDIT POLICY … CONTAINER = ALL`,
`AUDIT POLICY …` – a common policy enabled in the root is effective in all
containers:

| Policy | Content |
|---|---|
| `FMW_RCU_DB_MIN_SEC_AUDIT` | privileges `CREATE EXTERNAL JOB`, `CREATE JOB`, `CREATE ANY JOB`; actions on users, roles, profiles, synonyms, DB links, procedures, triggers, table DDL, `RENAME`, `GRANT` / `REVOKE`, `ALTER SYSTEM`, `ALTER DATABASE`, tablespaces, directories, `DELETE` / `UPDATE ON AUDSYS.AUD$UNIFIED`, `LOGON` / `LOGOFF` |
| `FMW_RCU_SEC_AUDIT_TRUNC` | `TRUNCATE TABLE` on `AUDSYS.AUD$UNIFIED` (tamper protection) |

`generate_unified_audit_policy.sql` helps to derive an own policy from the
traditional audit settings of an existing database.

**State:** the common-policy version is not live-tested yet (2026-11-02) –
check with the verification queries below after the first run.

## Block 2 – PDB: AUDITLOG, trails, retention

In the PDB (`ALTER SESSION SET CONTAINER = <PDB>`), the data file directory
`<DB_DATA_DIR>/<CDB>/<PDB>` is created first (`mkdir -p`):

```sql
-- 0. ORA_SECURECONFIG off in the PDB too (DBCA enables it per container)
NOAUDIT POLICY ORA_SECURECONFIG;

-- 1. tablespace (only if missing)
CREATE SMALLFILE TABLESPACE "AUDITLOG" LOGGING
  DATAFILE '<DB_DATA_DIR>/<CDB>/<PDB>/auditlog01.dbf'
  SIZE 100M AUTOEXTEND ON NEXT 120M MAXSIZE 4000M
  EXTENT MANAGEMENT LOCAL UNIFORM SIZE 1M;

-- 2. all three trails into AUDITLOG
--    (each in its own block, an error is printed and skipped – e.g. already set)
BEGIN
  DBMS_AUDIT_MGMT.SET_AUDIT_TRAIL_LOCATION(DBMS_AUDIT_MGMT.AUDIT_TRAIL_DB_STD,  'AUDITLOG');
  DBMS_AUDIT_MGMT.SET_AUDIT_TRAIL_LOCATION(DBMS_AUDIT_MGMT.AUDIT_TRAIL_FGA_STD, 'AUDITLOG');
  DBMS_AUDIT_MGMT.SET_AUDIT_TRAIL_LOCATION(DBMS_AUDIT_MGMT.AUDIT_TRAIL_UNIFIED, 'AUDITLOG');
END;
/

-- 3. cleanup infrastructure (19c: AUDIT_TRAIL_ALL works here; ORA-46258 = already done)
BEGIN
  DBMS_AUDIT_MGMT.INIT_CLEANUP(DBMS_AUDIT_MGMT.AUDIT_TRAIL_ALL, 24);
END;
/

-- 4. archive timestamp job, daily 02:00 (job action: section "Retention" below)
BEGIN
  BEGIN DBMS_SCHEDULER.DROP_JOB('FMW_AUDIT_ARCHIVE_TS', TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'FMW_AUDIT_ARCHIVE_TS',
    job_type        => 'PLSQL_BLOCK',
    job_action      => q'[<job action below>]',
    repeat_interval => 'FREQ=DAILY;BYHOUR=2;BYMINUTE=0',
    enabled         => TRUE,
    comments        => 'Set archive timestamp for all audit trails (180 day retention)');
END;
/

-- 5. one purge job per trail (19c: CREATE_PURGE_JOB does NOT accept AUDIT_TRAIL_ALL)
BEGIN
  BEGIN DBMS_AUDIT_MGMT.DROP_PURGE_JOB('PURGE_STD_AUDIT'); EXCEPTION WHEN OTHERS THEN NULL; END;
  DBMS_AUDIT_MGMT.CREATE_PURGE_JOB(DBMS_AUDIT_MGMT.AUDIT_TRAIL_AUD_STD, 24, 'PURGE_STD_AUDIT', TRUE);
  BEGIN DBMS_AUDIT_MGMT.DROP_PURGE_JOB('PURGE_FGA_AUDIT'); EXCEPTION WHEN OTHERS THEN NULL; END;
  DBMS_AUDIT_MGMT.CREATE_PURGE_JOB(DBMS_AUDIT_MGMT.AUDIT_TRAIL_FGA_STD, 24, 'PURGE_FGA_AUDIT', TRUE);
  BEGIN DBMS_AUDIT_MGMT.DROP_PURGE_JOB('PURGE_UNIFIED_AUDIT'); EXCEPTION WHEN OTHERS THEN NULL; END;
  DBMS_AUDIT_MGMT.CREATE_PURGE_JOB(DBMS_AUDIT_MGMT.AUDIT_TRAIL_UNIFIED, 24, 'PURGE_UNIFIED_AUDIT', TRUE);
END;
/
-- (arguments: audit_trail_type, audit_trail_purge_interval, audit_trail_purge_name,
--  use_last_arch_timestamp)
```

`AUDIT_TRAIL_DB_STD` covers both `AUD$` and `FGA_LOG$` for the location;
the script sets FGA separately as well (an error is printed and skipped).

---

## Retention: archive-timestamp job + purge jobs

Unified Auditing never deletes on its own. The cleanup works in two steps
that only make sense together:

| Job | Owner / schedule | What it does |
|---|---|---|
| `FMW_AUDIT_ARCHIVE_TS` (scheduler job, own) | SYS in the PDB, daily 02:00 in the scheduler time zone (`DEFAULT_TIMEZONE`, test DB `PST8PDT` = 10:00 / 11:00 CET) | moves the **last archive timestamp** of each trail to `SYSTIMESTAMP - DB_AUDIT_RETAIN_DAYS`; then gathers statistics on `AUDSYS.AUD$UNIFIED` |
| `PURGE_STD_AUDIT`, `PURGE_FGA_AUDIT`, `PURGE_UNIFIED_AUDIT` (`DBMS_AUDIT_MGMT.CREATE_PURGE_JOB`) | every 24 h | delete the records **older than that timestamp** (`use_last_arch_timestamp => TRUE`) |

Without the timestamp job the purge jobs run but delete nothing – the
timestamp stays where it was (or is never set) and the trail grows until
`AUDITLOG` reaches `MAXSIZE`. The timestamp is the retention: 180 days
means "everything older than 180 days may go".

The job action (generated by the script, `<n>` = `DB_AUDIT_RETAIN_DAYS`):

```sql
BEGIN
  DBMS_AUDIT_MGMT.SET_LAST_ARCHIVE_TIMESTAMP(DBMS_AUDIT_MGMT.AUDIT_TRAIL_AUD_STD, SYSTIMESTAMP - <n>);
  DBMS_AUDIT_MGMT.SET_LAST_ARCHIVE_TIMESTAMP(DBMS_AUDIT_MGMT.AUDIT_TRAIL_FGA_STD, SYSTIMESTAMP - <n>);
  DBMS_AUDIT_MGMT.SET_LAST_ARCHIVE_TIMESTAMP(DBMS_AUDIT_MGMT.AUDIT_TRAIL_UNIFIED, SYSTIMESTAMP - <n>);
  -- statistics for the purge DELETE on the (large) audit table – own block:
  -- a stats error must not fail the job, the timestamp is what matters;
  -- 3 tries 2 min apart (sporadic ORA-20000 under load, see below)
  FOR i IN 1 .. 3 LOOP
    BEGIN
      DBMS_STATS.GATHER_TABLE_STATS(ownname => 'AUDSYS', tabname => 'AUD$UNIFIED');
      EXIT;
    EXCEPTION WHEN OTHERS THEN
      SYS.DBMS_SYSTEM.KSDWRT(2, 'FMW_AUDIT_ARCHIVE_TS: stats AUDSYS.AUD$UNIFIED try ' || i || ' failed: ' || SQLERRM);
      IF i < 3 THEN DBMS_SESSION.SLEEP(120); END IF;
    END;
  END LOOP;
END;
```

Why the statistics: the purge is a `DELETE … WHERE event_timestamp <
<archive timestamp>` on a table that only grows; with stale or missing
statistics the optimizer may pick a poor plan once the table is large.
Gathering statistics only **reads** – it takes no exclusive lock and is not
blocked by the audit writes or row locks. A failure is retried twice and
written to the alert log (`KSDWRT`, "FMW_AUDIT_ARCHIVE_TS: stats … try n
failed"); the job still ends with `SUCCEEDED`.

Check (in the PDB):

```sql
SELECT TO_CHAR(log_date,'YYYY-MM-DD HH24:MI') d, status, error#, additional_info
  FROM dba_scheduler_job_run_details
 WHERE job_name = 'FMW_AUDIT_ARCHIVE_TS' ORDER BY log_date DESC FETCH FIRST 5 ROWS ONLY;
SELECT audit_trail, last_archive_ts FROM dba_audit_mgmt_last_arch_ts;   -- ~ today - 180 days
SELECT last_analyzed FROM dba_tab_statistics
 WHERE owner = 'AUDSYS' AND table_name = 'AUD$UNIFIED' AND partition_name IS NULL;
```

### ORA-20000 "Unable to analyze TABLE AUDSYS.AUD$UNIFIED" (sporadic)

Seen 2026-10-21 in a production database (19.32, more load than the RCU
database) with a hand-made variant of this job
(`SYS.AUDIT_ARCHIVE_BEFORE_TIMESTAMP`, same `GATHER_TABLE_STATS` call) –
**only every few days**, the other runs succeed:

```
ORA-12012: error on auto execute of job "SYS"."AUDIT_ARCHIVE_BEFORE_TIMESTAMP"
ORA-20000: Unable to analyze TABLE "AUDSYS"."AUD$UNIFIED", insufficient privileges or does not exist
ORA-06512: at "SYS.DBMS_STATS", line 40799
```

What it is **not** (checked on the test DB 2026-11-02):

- **Not the name / a typo**: the name is resolved (`"AUDSYS"."AUD$UNIFIED"`
  in the message), and a wrong name fails every time with a different error
  – a `AUD\$UNIFIED` with backslash (shell escaping copied into SQL) gives
  `ORA-20001: AUD\$UNIFIED is an invalid identifier`.
- **Not the container**: `GATHER_TABLE_STATS` works in `CDB$ROOT` and in the
  PDB (both have their own `AUDSYS.AUD$UNIFIED`).
- **Not a row lock / the audit blocking itself**: statistics gathering only
  reads, it needs no exclusive lock; a lock would show up as a wait or
  `ORA-00054`, not as "does not exist". A `sleep` before the call or a
  "no row lock" check does not address it.

What fits a sporadic "does not exist" with the correct name: the **table
changes its partitions while DBMS_STATS works through them**.
`AUD$UNIFIED` is interval-partitioned (default `INTERVAL '1' MONTH`,
changeable with `DBMS_AUDIT_MGMT.ALTER_PARTITION_INTERVAL`); DBMS_STATS
gathers partition by partition from a list read at the start:

1. **The purge job runs at the same time** – `CLEAN_AUDIT_TRAIL` with the
   last archive timestamp drops partitions that lie completely before it
   and deletes in the rest. The purge jobs run every 24 h counted from
   their creation; under load the purge takes longer and sometimes overlaps
   the archive job.
2. **A new interval partition** is created by the first audit record of a
   new interval while the statistics run.
3. **A second statistics run on the same table** – the automatic optimizer
   statistics task in the maintenance window (22:00–02:00, weekend longer)
   gathers the dictionary schemas too.

To confirm in the affected database (times of the failures vs. the others):

```sql
-- failures of the archive job
SELECT TO_CHAR(log_date,'YYYY-MM-DD HH24:MI:SS') d, status, run_duration, additional_info
  FROM dba_scheduler_job_run_details
 WHERE job_name = '<archive job>' AND status <> 'SUCCEEDED' ORDER BY log_date;
-- purge runs around these times (start + duration)
SELECT job_name, TO_CHAR(actual_start_date,'YYYY-MM-DD HH24:MI:SS') s, run_duration, status
  FROM dba_scheduler_job_run_details
 WHERE job_name LIKE 'PURGE%AUDIT%' OR job_name LIKE '%AUDIT%CLEAN%' ORDER BY actual_start_date;
SELECT cleanup_time, audit_trail, number_of_records FROM dba_audit_mgmt_clean_events ORDER BY cleanup_time;
-- partitions created / interval
SELECT subobject_name, created FROM dba_objects
 WHERE owner = 'AUDSYS' AND object_name = 'AUD$UNIFIED' AND object_type = 'TABLE PARTITION' ORDER BY created;
-- other statistics runs on the table
SELECT operation, target, start_time, end_time, status FROM dba_optstat_operations
 WHERE target LIKE '%AUD$UNIFIED%' OR operation LIKE 'gather_database_stats%' ORDER BY start_time;
```

The full trace (`*_j000_*.trc`) shows the error stack below the ORA-06512
lines – the error DBMS_STATS wrapped into ORA-20000 (e.g. ORA-14xxx for a
partition, ORA-01403 / ORA-00942) names the cause.

Remedies (in this order):

1. Statistics in an **own block with retry** (as above, since 2026-11-02 in
   `04-db_audit_setup.sh`): the archive timestamp – the part the purge
   depends on – is set before, a statistics failure no longer marks the job
   `FAILED`, a second try 2 min later normally finds a stable partition list.
2. **Schedule apart**: the archive job well before the purge jobs (purge
   start = `NEXT_RUN_DATE` of `PURGE_*`, change with
   `DBMS_SCHEDULER.SET_ATTRIBUTE(…, 'start_date', …)`) and outside the
   maintenance window.
3. For an existing hand-made job: replace the action with
   `DBMS_SCHEDULER.SET_ATTRIBUTE('<owner>.<job>', 'job_action', q'[ … ]')`
   – `q'[…]'` avoids the doubled quotes.

The timestamps were set in the failing runs too (they come before the
statistics) – the purge kept working, the job only showed `FAILED`.

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

SELECT POLICY_NAME, ENABLED_OPTION FROM AUDIT_UNIFIED_ENABLED_POLICIES;  -- the two FMW_RCU_* policies (not ORA_SECURECONFIG)
SELECT DISTINCT POLICY_NAME, COMMON FROM AUDIT_UNIFIED_POLICIES
 WHERE POLICY_NAME LIKE 'FMW_RCU%';                                    -- COMMON = YES
```

---

## Notes

- `AUDITLOG` lives in the PDB; audit records of the root (e.g. `LOGON` of
  SYS) go to the root's `AUD$UNIFIED` in `SYSAUX` – add a matching tablespace
  in the root if that matters.
- 180 days fit easily into 4 GB for a metadata database with low activity.
- RCU schema users log on many times (data source pools) – `LOGON` /
  `LOGOFF` is the largest share of the records; the purge jobs keep it bounded.

## Next step

```bash
./60-RCU-DB-19c/05-db_fmw_tablespace.sh --apply   # optional
./60-RCU-DB-19c/06-db_rcu_profile.sh --apply
./60-RCU-DB-19c/08-db_auto_start.sh --apply
./09-Install/07-oracle_setup_repository.sh --apply
```
