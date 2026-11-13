---
title: "Create the Oracle 19c CDB and PDB for the FMW RCU"
description: "Step 3: create the Oracle 19c CDB and PDB for the FMW 14.1.2 repository with DBCA – RCU requirements checked, post-configuration, clean and re-create."
---

# Step 3 – 03-db_create_database.sh

**Script:** [`60-RCU-DB-19c/03-db_create_database.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/03-db_create_database.sh)
**Runs as:** `oracle`
**Phase:** Create the CDB + PDB
**Requires:** listener running ([`02-db_setup_listener.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/02-db_setup_listener.sh)),
`environment_db.conf`, `db_sys_sec.conf.des3` (`00-Setup/database_rcu_sec.sh
--apply`), the DB home from `01-` (root.sh done)

```bash
./60-RCU-DB-19c/03-db_create_database.sh                  # dry-run: checks + configuration
./60-RCU-DB-19c/03-db_create_database.sh --apply          # create CDB + PDB + post-config
./60-RCU-DB-19c/03-db_create_database.sh --clean          # dry-run: what --clean --apply removes
./60-RCU-DB-19c/03-db_create_database.sh --clean --apply  # delete the DB + files, then create again
```

---

## Flow (as in the script)

1. **Pre-checks** – `DB_ORACLE_HOME`; `ORACLE_BASE` (environment.conf →
   environment_db.conf) must equal the base recorded for the home in
   `$DB_ORACLE_HOME/install/orabasetab` – dbca uses that one for cfgtoollogs
   / admin / diag (mismatch = FAIL with the hints `00a-db_env_interview.sh
   --check` / `01-db_install_software.sh --clean --apply`; customer
   2026-11-02); `dbca` and `lsnrctl` present; listener running (FAIL);
   `uniaud_on` state of the binary (INFO only, see
   [Unified Audit relink](#unified-audit-relink-manual-checked-only));
   `DB_SID`, `DB_CDB_NAME`, `DB_PDB_NAME`, `DB_DATA_DIR` set; credentials file
2. **Existing database** – `DB_DATA_DIR/<CDB>` exists: dry-run WARN;
   `--apply` without `--clean` stops with FAIL (DBCA is not started)
3. Configuration summary – **dry-run ends here**
4. Credentials: `DB_SYS_PWD` from `db_sys_sec.conf.des3`; `DB_SYSTEM_PWD` /
   `DB_PDB_ADMIN_PWD` default to it (override in `environment_db.conf`)
5. `--clean`: `dbca -silent -deleteDatabase -sourceDB <SID>` (errors
   ignored), `rm -rf` of `DB_DATA_DIR/<CDB>`, `DB_ADMIN_DIR/<CDB>`,
   `DB_FAST_RECOVERY_AREA/<CDB>`
6. Directories: `mkdir -p $DB_DATA_DIR $DB_ADMIN_DIR/<CDB>/adump [$DB_FAST_RECOVERY_AREA]`
7. DBCA (below)
8. Post-creation parameters, `local_listener`, `max_string_size`, PDB save state
9. `MAX_STRING_SIZE=EXTENDED` migration in every container (`utl32k` via
   catcon), `utlrp` via catcon
10. Memory resize to the operating values
11. `/etc/oratab` (DBCA normally writes `<SID>:<home>:N` itself – the script
    then reports "already exists"; [`08-db_auto_start.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/08-db_auto_start.sh) sets `Y`)
12. Verification + RCU requirements check in the PDB, next-step hints

---

## Unified Audit relink (manual, checked only)

`03-` only **checks** the binary (`kzaiang`, INFO) and prints the relink
command; the relink is a manual step with database and listener stopped –
right after DBCA, before [`04-db_audit_setup.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/04-db_audit_setup.sh) (which stops with FAIL until
it is done). Commands: [04-db_audit_setup.md](04-db_audit_setup.md#prerequisites).

```bash
strings $DB_ORACLE_HOME/bin/oracle | grep -c kzaiang    # > 0 = linked
```

> A new home needs it again: [`09-db_patch_rcu.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/09-db_patch_rcu.sh) relinks the new home with
> `uniaud_on` when the old one has it (out-of-place RU patch).

---

## Listener

Prerequisite, not part of this script: [`02-db_setup_listener.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/02-db_setup_listener.sh) writes
`listener.ora` / `sqlnet.ora` / `tnsnames.ora` in
`$DB_ORACLE_HOME/network/admin` and starts `LISTENER`. `03-` stops with FAIL
if `lsnrctl status LISTENER` fails. No netca.

---

## DBCA Silent — Minimal CDB + PDB

| Parameter | Value | Reason |
|---|---|---|
| `sga_target` | `DB_SGA_MB` during DBCA (template 1536, script default 4096) + `shared_pool_size` `DB_SHARED_POOL_MB` (2048) and `java_pool_size` `DB_JAVA_POOL_MB` (512) as floors for the JVM install; afterwards `DB_SGA_POST_MB` (2048), both pools 0 (auto) | the floors are larger than 1536 – Oracle raises the SGA (test host 2026-03: `sga_target=1536m` + `shared_pool_size=2048m` + `java_pool_size=512m` → DBCA 100 %; today `sga_target` / `sga_max_size` 2 GB) |
| `pga_aggregate_target` | `DB_PGA_MB` (template 512, script default 1024) during DBCA, afterwards `DB_PGA_POST_MB` (512) | parallel RCU sessions |
| `DB_BLOCK_SIZE` | `8192` (template) | FMW default; checked (FAIL otherwise) |
| Character set | `DB_CHAR_SET` = `AL32UTF8` | **Mandatory here** — RCU itself only warns ("strongly recommends"), Forms/Reports Unicode and APEX need it |
| National char set | `DB_NCHAR_SET` = `AL16UTF16` | Oracle default |
| `PROCESSES` | `DB_PROCESSES` 1000 | RCU minimum of FMW 14.1.2 (static) |
| `OPEN_CURSORS` | `DB_OPEN_CURSORS` 1600 | RCU minimum of FMW 14.1.2 (CDB and PDB) |
| `SESSION_CACHED_CURSORS` | `DB_SESSION_CACHED_CURSORS` 100 | RCU minimum of FMW 14.1.2 (static) |
| `DB_FILES` | `DB_FILES` 600 | RCU minimum of FMW 14.1.2 (static) |
| `compatible` | `19.0.0` | Required for 19c feature set |
| `max_string_size` | `EXTENDED` | FMW extended VARCHAR support; static — needs restart and the `utl32k.sql` migration in **every** container incl. `PDB$SEED` (see below) |
| Archivelog | `DB_ARCHIVELOG` (false = test) | Saves disk; not needed for metadata-only DB |
| Fast Recovery Area | `DB_FAST_RECOVERY_AREA` + `DB_RECOVERY_SIZE_MB` (script default 4096); empty = no FRA | |
| Redo logs | template: 3 groups × `-redoLogFileSize 50` MB | low-write workload |

Source of the minimums and the full requirement list (version, edition,
JVM): [rcu_middleware_architecture.md §9](../../80-FMW-Architecture/rcu_middleware_architecture.md#9-database-requirements-for-the-repository-19c--26ai).

Data file sizes come from the DBCA template `General_Purpose.dbc` – the
script sets none of them (measured: [00-concept.md](00-concept.md#disk-layout-minimal)).
AUDITLOG tablespace: created by [`04-db_audit_setup.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/04-db_audit_setup.sh) (separate script).
FMW_DATA tablespace (all RCU schemas): created by [`05-db_fmw_tablespace.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/05-db_fmw_tablespace.sh).

### DBCA silent command

```bash
$DB_ORACLE_HOME/bin/dbca -silent \
    -createDatabase \
    -templateName   General_Purpose.dbc \
    -gdbName        "${DB_CDB_NAME}" \
    -sid            "${DB_SID}" \
    -createAsContainerDatabase true \
    -numberOfPDBs   1 \
    -pdbName        "${DB_PDB_NAME}" \
    -pdbAdminPassword "${DB_PDB_ADMIN_PWD}" \
    -databaseType   MULTIPURPOSE \
    -memoryMgmtType CUSTOM_SGA \
    -initParams     "sga_target=${DB_SGA_MB}m,shared_pool_size=${DB_SHARED_POOL_MB:-2048}m,java_pool_size=${DB_JAVA_POOL_MB:-512}m,pga_aggregate_target=${DB_PGA_MB}m" \
    -storageType    FS \
    -datafileDestination "${DB_DATA_DIR}" \
    -redoLogFileSize 50 \
    -emConfiguration NONE \
    -dbOptions      "JSERVER:true,ORACLE_TEXT:false,IMEDIA:false,CWMLITE:false,SPATIAL:false,OMS:false,APEX:false,DV:false" \
    -characterSet   "${DB_CHAR_SET}" \
    -nationalCharacterSet "${DB_NCHAR_SET}" \
    -sysPassword    "${DB_SYS_PWD}" \
    -systemPassword "${DB_SYSTEM_PWD}" \
    -enableArchive  "${DB_ARCHIVELOG}" \
    -recoveryAreaDestination "${DB_FAST_RECOVERY_AREA}" -recoveryAreaSize "${DB_RECOVERY_SIZE_MB}" \
    -useLocalUndoForPDBs true
# without FRA: -recoveryAreaDestination ""   (no -recoveryAreaSize)
# rc <> 0 = FAIL, logs: $ORACLE_BASE/cfgtoollogs/dbca/<DB_CDB_NAME>/
```

> `useLocalUndoForPDBs=true`: each PDB manages its own undo — required for
> PDB-level flashback and simplifies future PDB migration.

### DB options (via -dbOptions)

| Option | State |
|---|---|
| JSERVER | **enabled** – Oracle JVM is an RCU 14.1.2 requirement (checked: `JAVAVM` must be VALID) |
| ORACLE_TEXT | Full-text search — not used by FMW |
| IMEDIA | Oracle Multimedia — not needed |
| CWMLITE | OLAP Catalog — not needed |
| SPATIAL | Oracle Spatial — not needed |
| APEX | Application Express — not needed |
| OMS | not needed |
| DV | Database Vault — not needed for RCU DB |

---

## Post-Creation Parameter Tuning

Connect to the CDB as SYSDBA and apply parameters that DBCA does not set:

```sql
sqlplus / as sysdba

-- RCU minimums of FMW 14.1.2 (rcu_middleware_architecture.md 9.2)
ALTER SYSTEM SET open_cursors           = 1600 SCOPE=BOTH;
ALTER SYSTEM SET processes              = 1000 SCOPE=SPFILE;
ALTER SYSTEM SET session_cached_cursors = 100  SCOPE=SPFILE;
ALTER SYSTEM SET db_files               = 600  SCOPE=SPFILE;

-- Listener registration with the explicit address instead of the DBCA alias
-- host: DB_LISTENER_HOST, empty = hostname -f; port: DB_LISTENER_PORT
ALTER SYSTEM SET local_listener = '(ADDRESS=(PROTOCOL=TCP)(HOST=<host>)(PORT=<port>))' SCOPE=BOTH;
ALTER SYSTEM REGISTER;

-- Extended string support for FMW VARCHAR columns (static — needs restart)
ALTER SYSTEM SET max_string_size = EXTENDED SCOPE=SPFILE;

-- Compatibility level
ALTER SYSTEM SET compatible      = '19.0.0' SCOPE=SPFILE;

-- PDB auto-open after CDB restart (CRITICAL — without this the PDB stays MOUNTED)
ALTER PLUGGABLE DATABASE ALL OPEN;
ALTER PLUGGABLE DATABASE ALL SAVE STATE;
```

The static changes take effect with the restarts of the `MAX_STRING_SIZE`
migration below – a plain `STARTUP` after `max_string_size=EXTENDED` without
`utl32k` fails (ORA-14694).

> `ALTER PLUGGABLE DATABASE ALL SAVE STATE` persists the PDB open mode in the
> CDB data dictionary.  Without it, the PDB must be opened manually after every
> CDB restart.

> **`local_listener` – no alias.** DBCA sets `local_listener=LISTENER_<SID>`,
> an alias that exists only in `$DB_ORACLE_HOME/network/admin/tnsnames.ora`.
> An instance started from a shell whose `TNS_ADMIN` points to the shared
> directory (`$ORACLE_BASE/admin/tns_names`, one `TNS_ADMIN` for Forms /
> Reports / WebLogic) cannot resolve it and does **not register** with the
> listener: `lsnrctl status` shows "The listener supports no services",
> clients get ORA-12514, the AdminServer hangs in OPSS `JpsStartup` retries
> (live 2026-10-27, test host). The script therefore sets the explicit
> address. Existing database:
> `ALTER SYSTEM SET local_listener='(ADDRESS=(PROTOCOL=TCP)(HOST=<host>)(PORT=1521))' SCOPE=BOTH; ALTER SYSTEM REGISTER;`

---

### MAX_STRING_SIZE=EXTENDED – migrate every container (incl. PDB$SEED)

As the script does it (`catcon.pl` needs `sqlplus` in `PATH`; `PDB$SEED` is
in MIGRATE mode after `STARTUP UPGRADE` and `catcon` includes it):

```sql
SHUTDOWN IMMEDIATE
STARTUP UPGRADE
ALTER PLUGGABLE DATABASE ALL OPEN UPGRADE;
```
```bash
cd $DB_ORACLE_HOME/rdbms/admin
PATH=$DB_ORACLE_HOME/bin:$DB_ORACLE_HOME/perl/bin:$PATH \
  perl catcon.pl -n 1 -d $DB_ORACLE_HOME/rdbms/admin -l <logdir> -b utl32k utl32k.sql
```
```sql
SHUTDOWN IMMEDIATE
STARTUP
ALTER PLUGGABLE DATABASE ALL OPEN;
```
```bash
PATH=$DB_ORACLE_HOME/bin:$DB_ORACLE_HOME/perl/bin:$PATH \
  perl catcon.pl -n 1 -d $DB_ORACLE_HOME/rdbms/admin -l <logdir> -b utlrp utlrp.sql
```

The script only filters the catcon output (`completed successfully`,
`ORA-`) into the log – after a run with errors check `SHOW PDBS`
(`PDB$SEED` READ ONLY) and `SHOW PARAMETER max_string_size` (EXTENDED).

**Bug until 2026-10-28:** the script ran `utl32k.sql` only in `CDB$ROOT` and
the application PDB (`ALL OPEN UPGRADE` does not include the seed). Result,
**confirmed (live)**: `PDB$SEED` stays MOUNTED and cannot be opened –
`ORA-14696: MAX_STRING_SIZE migration is incomplete for pluggable database
PDB$SEED` (no new PDB from the seed, datapatch at risk). Repair of an
existing database (domain stopped, ~10 min):

```sql
SHUTDOWN IMMEDIATE
STARTUP UPGRADE                         -- PDB$SEED -> MIGRATE
```
```bash
cd $ORACLE_HOME/rdbms/admin
PATH=$ORACLE_HOME/bin:$ORACLE_HOME/perl/bin:$PATH \
  perl catcon.pl -n 1 -c 'PDB$SEED' -d $ORACLE_HOME/rdbms/admin -l /tmp -b utl32k_seed utl32k.sql
```
```sql
SHUTDOWN IMMEDIATE
STARTUP                                 -- PDB$SEED READ ONLY again
```
```bash
PATH=$ORACLE_HOME/bin:$ORACLE_HOME/perl/bin:$PATH \
  perl catcon.pl -n 1 -d $ORACLE_HOME/rdbms/admin -l /tmp -b utlrp utlrp.sql
```

Done on the test host 2026-10-28: `PDB$SEED` READ ONLY; the `utlrp` over all
containers also recompiled the 69 objects of the RCU schemas that had been
invalid since the RCU run ([`rcu_repository_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/rcu_repository_check.sh): 0 invalid).

## Memory resize (operating values)

```sql
-- CDB$ROOT, all SCOPE=BOTH - no restart
ALTER SYSTEM SET shared_pool_size     = 0 SCOPE=BOTH;     -- floors off first
ALTER SYSTEM SET java_pool_size       = 0 SCOPE=BOTH;
ALTER SYSTEM SET sga_target           = 2048m SCOPE=BOTH; -- DB_SGA_POST_MB
ALTER SYSTEM SET pga_aggregate_target = 512m  SCOPE=BOTH; -- DB_PGA_POST_MB
ALTER SESSION SET CONTAINER = <PDB>;
ALTER SYSTEM SET open_cursors = 1600 SCOPE=BOTH;          -- PDB-modifiable
```

## oratab

```bash
grep "^<SID>:" /etc/oratab || echo "<SID>:<DB_ORACLE_HOME>:Y" >> /etc/oratab
```

DBCA normally writes the entry with flag `N`; [`08-db_auto_start.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/08-db_auto_start.sh) sets `Y`.

## Post-Creation Checks

```sql
sqlplus / as sysdba

-- Verify PDB is open
SHOW PDBS;
-- Expected: FMWPDB OPEN READ WRITE

-- Verify character set (must be AL32UTF8)
SELECT VALUE FROM NLS_DATABASE_PARAMETERS WHERE PARAMETER = 'NLS_CHARACTERSET';

-- Verify RCU-critical parameters
SHOW PARAMETER open_cursors;     -- expected: 1600
SHOW PARAMETER processes;        -- expected: 1000
SHOW PARAMETER session_cached_cursors;  -- expected: 100
SHOW PARAMETER db_files;         -- expected: 600
SHOW PARAMETER max_string_size;  -- expected: EXTENDED
SHOW PARAMETER compatible;       -- expected: 19.0.0
SHOW PARAMETER sga_target;
SHOW PARAMETER pga_aggregate_target;
SELECT VALUE FROM V$OPTION WHERE PARAMETER = 'Unified Auditing';
```

The script then runs [`rcu_db_requirements.sql`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/rcu_db_requirements.sql) in the PDB and grades it
(`rcu_db_req_eval`, [`00-Setup/IHateWeblogic_lib.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/00-Setup/IHateWeblogic_lib.sh)):

| Result | Check |
|---|---|
| FAIL | version 19c < 19.14 (23ai < 23.4.0.24); character set not `AL32UTF8`; `JAVAVM` not VALID; `db_block_size` ≠ 8192 |
| WARN | `processes` < 1000, `open_cursors` < 1600, `session_cached_cursors` < 100, `db_files` < 600; edition not EE; options "Fine-grained access control" / "Partitioning" not TRUE |
| INFO | `shared_pool_size`, `sga_max_size`, `sga_target`, national character set |

---

## environment_db.conf Variables Used

```bash
ORACLE_BASE         # shared with FMW (environment.conf); must match install/orabasetab
DB_ORACLE_HOME      # ${ORACLE_BASE}/product/19.33.0/db_home1 — patched home
DB_ADMIN_DIR        # ${ORACLE_BASE}/admin  — audit dump dir
DB_DATA_DIR         # e.g. /u01/app/oracle/oradata
DB_FAST_RECOVERY_AREA / DB_RECOVERY_SIZE_MB   # empty = no FRA
DB_SID / DB_CDB_NAME / DB_PDB_NAME             # e.g. FMWCDB / FMWCDB / FMWPDB (= DB_SERVICE)
DB_LISTENER_HOST / DB_LISTENER_PORT            # local_listener (empty host = hostname -f)
DB_SGA_MB / DB_PGA_MB                          # during DBCA
DB_SHARED_POOL_MB / DB_JAVA_POOL_MB            # floors during DBCA (default 2048 / 512)
DB_SGA_POST_MB / DB_PGA_POST_MB                # operating values (default 2048 / 512)
DB_PROCESSES / DB_OPEN_CURSORS / DB_SESSION_CACHED_CURSORS / DB_FILES
DB_CHAR_SET / DB_NCHAR_SET / DB_ARCHIVELOG
DB_SYS_PWD          # from db_sys_sec.conf.des3
DB_SYSTEM_PWD       # optional, default DB_SYS_PWD
DB_PDB_ADMIN_PWD    # optional, default DB_SYS_PWD
```

---

## Notes

- `dbca -silent` exit code: 0 = success, non-zero = error; check
  `$ORACLE_BASE/cfgtoollogs/dbca/<DB_CDB_NAME>/` for detailed logs
- Auto-start on boot: [`08-db_auto_start.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/08-db_auto_start.sh) (oratab flag `Y` + `oracle-db.service`)
- After creation, update `environment.conf` with `DB_SERVICE=FMWPDB` before
  running the RCU script
- `db_securefile` is not set → default `PREFERRED`. Do **not** set `FORCE`
  (hardening guides: "always SecureFile") before the first RCU run: RCU
  creates `SYSTEM.SCHEMA_VERSION_REGISTRY$` with a CLOB in the non-ASSM
  tablespace `SYSTEM` → ORA-43853. `ALWAYS` is harmless (BasicFile fallback).
  See [`80-FMW-Architecture/rcu_middleware_architecture.md`](../../80-FMW-Architecture/rcu_middleware_architecture.md) §4.2
- Profile for the RCU schemas (no password expiry): [`06-db_rcu_profile.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/06-db_rcu_profile.sh)

## Next steps

1. Manual `uniaud_on` relink (DB + listener down) – [04-db_audit_setup.md](04-db_audit_setup.md#prerequisites)
2. `04-db_audit_setup.sh --apply`
3. `05-db_fmw_tablespace.sh --apply` (FMW_DATA for all RCU schemas)
4. `06-db_rcu_profile.sh --apply`, `08-db_auto_start.sh --apply`
5. `09-Install/07-oracle_setup_repository.sh --apply`
