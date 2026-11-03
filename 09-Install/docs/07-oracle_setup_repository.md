# Step 4a – 07-oracle_setup_repository.sh

**Script:** `09-Install/07-oracle_setup_repository.sh`
**Runs as:** `oracle`
**Phase:** 4 – Repository & Domain

```bash
./09-Install/07-oracle_setup_repository.sh --check    # DB requirements only (read-only)
./09-Install/07-oracle_setup_repository.sh            # dry-run: connection, schema names
./09-Install/07-oracle_setup_repository.sh --apply    # RCU -createRepository + DB profile
```

Checked against the script 2026-11-03. Before it (local DB, `60-RCU-DB-19c`):
`04-db_audit_setup.sh`, `05-db_fmw_tablespace.sh` (when `RCU_TABLESPACE` is
set), `06-db_rcu_profile.sh`; the DB credentials with
`00-Setup/database_rcu_sec.sh --apply`.

---

## Purpose

Run the Repository Creation Utility (RCU) to create the required FMW metadata schemas
in the Oracle database. These schemas are required before the WebLogic domain can be created.

---

## Required Schemas

| Schema suffix | Component | Description |
|---|---|---|
| `_STB` | Service Table | Central FMW metadata repository |
| `_MDS` | Metadata Service | ADF metadata storage |
| `_OPSS` | Oracle Platform Security | Security policies and credentials |
| `_IAU` | Audit | Full audit trail |
| `_IAU_APPEND` | Audit Append | Audit data insert |
| `_IAU_VIEWER` | Audit Viewer | Audit read access |
| `_UMS` | User Messaging Service (component ID `UCSUMS`) | UMS configuration |
| `_WLS` | WebLogic Services | WLS internal metadata |
| `_WLS_RUNTIME` | WebLogic Services (sub) | WLS runtime metadata (sub-schema of WLS) |

Schema names are prefixed with `DB_SCHEMA_PREFIX` (e.g. `DEV_STB`, `DEV_MDS`, ...).

> **Note:** The component list was verified via `rcu -silent -listComponents` on FMW 14.1.2.
> WLS (WebLogic Services) is a required component in 14.1.2 — it was not part of earlier
> 12.2.1.x installations. WLS also has a sub-schema `WLS_RUNTIME` which requires an
> additional password line in the RCU password file (see password file format below).
>
> Component ID ≠ schema name: component `UCSUMS` creates `<prefix>_UMS` (confirmed via
> `rcu -listSchemas`, 2026-10-14).
>
> **`--drop`:** `-dropRepository` only takes `-component` – `-tablespace` /
> `-tempTablespace` are rejected with `RCU-6197 Invalid arguments` (confirmed
> 2026-10-14). The script passes the tablespace flags for `--apply` only and
> verifies with `rcu -listSchemas` afterwards that no `<prefix>_*` schema is left.
>
> **`--drop` also drops the tablespace – including a DBA-pre-created one.** The RCU
> log shows `drop tablespace FMW_DATA including contents and datafiles` (confirmed
> 2026-10-14). With `RCU_TABLESPACE` set, re-create it before the next `--apply`:
> `60-RCU-DB-19c/05-db_fmw_tablespace.sh --apply`. On a customer DB managed by a
> DB team: agree on this before any drop – their tablespace and datafiles are gone.

---

## Without the Script (manual)

Same order as the script. Values from `environment.conf`; connect string
always `host:port/service` (slash = PDB service, not `:SID`).

### 0. Check the database (read-only)

```bash
sqlplus -S -L /nolog <<EOF
CONNECT sys/"<sys password>"@//${DB_HOST}:${DB_PORT}/${DB_SERVICE} AS SYSDBA
@60-RCU-DB-19c/rcu_db_requirements.sql
SHOW PARAMETER db_securefile
SELECT tablespace_name, status FROM dba_tablespaces WHERE tablespace_name = UPPER('${RCU_TABLESPACE:-FMW_DATA}');
EOF
```

`IHW:REQ|…` lines: version 19c ≥ 19.14, Enterprise Edition, AL32UTF8, JVM
`VALID`, `processes` ≥ 1000, `open_cursors` ≥ 1600, `session_cached_cursors`
≥ 100, `db_files` ≥ 600 (the script evaluates them, `--check`).
`db_securefile` must not be `FORCE` before the first RCU run (ORA-43853, see
below); with `RCU_TABLESPACE` set the tablespace must exist.

### 1. Write RCU password file

RCU silent mode (`-f`) reads passwords from stdin/file in this order:
- Line 1: SYS/SYSDBA password (for the DB connection)
- Lines 2–8: schema password, one line per component (same password repeated)

```bash
cat > /tmp/rcu_passwords.txt << 'EOF'
MySysDBAPassword
MySchemaPassword
MySchemaPassword
MySchemaPassword
MySchemaPassword
MySchemaPassword
MySchemaPassword
MySchemaPassword
MySchemaPassword
MySchemaPassword
EOF
chmod 600 /tmp/rcu_passwords.txt
```

> 10 lines total: 1 SYS + 8 schema components (STB MDS OPSS IAU IAU_APPEND IAU_VIEWER UCSUMS WLS)
> + 1 extra for WLS_RUNTIME (sub-schema of WLS, requires its own password line).
> The script builds this file automatically from `DB_SYS_PWD` and `DB_SCHEMA_PWD`.

### 2. Run RCU

```bash
# test the connection first (lists existing schemas – the prefix must not exist yet)
$ORACLE_HOME/oracle_common/bin/rcu -silent -listSchemas -databaseType EBR \
    -connectString "${DB_HOST}:${DB_PORT}/${DB_SERVICE}" -dbUser sys -dbRole sysdba \
    -f < /tmp/rcu_passwords.txt

$ORACLE_HOME/oracle_common/bin/rcu \
    -silent \
    -createRepository \
    -databaseType EBR \
    -connectString "${DB_HOST}:${DB_PORT}/${DB_SERVICE}" \
    -dbUser sys \
    -dbRole sysdba \
    -schemaPrefix "${DB_SCHEMA_PREFIX}" \
    -component STB \
    -component MDS \
    -component OPSS \
    -component IAU \
    -component IAU_APPEND \
    -component IAU_VIEWER \
    -component UCSUMS \
    -component WLS \
    -f < /tmp/rcu_passwords.txt
```

`-databaseType` = `RCU_DB_TYPE` (`EBR` default, or `ORACLE`). With
`RCU_TABLESPACE` set add `-tablespace FMW_DATA -tempTablespace TEMP` directly
after **each** `-component <ID>`.

> **Connect string format:** Use `/service_name` (slash) for PDB service names — not `:SID`
> (colon). Colon format addresses the CDB SID; slash format targets the PDB service.
> Example: `192.168.1.20:1521/fmwpdb`

### 3. Clean up password file

```bash
rm -f /tmp/rcu_passwords.txt
```

### 4. Verify schemas were created

```bash
sqlplus -S -L /nolog <<EOF
CONNECT sys/"<sys password>"@//${DB_HOST}:${DB_PORT}/${DB_SERVICE} AS SYSDBA
SELECT username, profile, account_status FROM dba_users
 WHERE username LIKE '${DB_SCHEMA_PREFIX^^}\_%' ESCAPE '\' ORDER BY username;
EOF
```

Expected: 9 schemas listed (8 components + the WLS_RUNTIME sub-schema).

### 5. DB profile for the schemas

RCU creates them with profile `DEFAULT` (password expires after 180 days):

```sql
-- as SYSDBA in the PDB, from the repository root
@60-RCU-DB-19c/rcu_user_profile.sql RCU_USER DEV      -- profile + assign (prefixes comma-separated)
```

---

## Tablespace Configuration

### Our standard: one tablespace for all schemas (`RCU_TABLESPACE`)

All 9 FMW schemas go into **one** tablespace, passed as `RCU_TABLESPACE`
(e.g. `FMW_DATA`) – one place for size, monitoring and backup, nothing
scattered over per-component tablespaces.

```bash
# environment.conf (01-setup-interview.sh, block 4 – Database)
RCU_TABLESPACE=FMW_DATA        # must exist before RCU
RCU_TEMP_TABLESPACE=TEMP       # default: TEMP
```

Create it before `07- --apply`:

- local RCU DB: `60-RCU-DB-19c/05-db_fmw_tablespace.sh --apply`
  (`DB_FMW_TABLESPACE` = `RCU_TABLESPACE`, also writes `RCU_TABLESPACE` into
  `environment.conf`)
- DBA-managed DB, the DBA creates it:

  ```sql
  CREATE TABLESPACE FMW_DATA
    DATAFILE '/u01/oradata/mydb/fmw_data01.dbf'
    SIZE 500M AUTOEXTEND ON NEXT 100M MAXSIZE UNLIMITED;
  ```

The script then passes it after **every** component (RCU requirement):

```bash
rcu ... -component STB -tablespace FMW_DATA -tempTablespace TEMP \
        -component MDS -tablespace FMW_DATA -tempTablespace TEMP ...
```

`--drop` removes this tablespace **including its data files**, also a
DBA-created one – re-create it before the next `--apply` (see *Required
Schemas*).

### Fallback: `RCU_TABLESPACE` empty – RCU creates its own

Only when `RCU_TABLESPACE` is empty (interview default `FMW_DATA`) RCU creates one
tablespace per component (names from
`$ORACLE_HOME/oracle_common/common/sql/*/*_Storage.xml`, FMW 14.1.2, checked
2026-11-03):

| Component | Tablespace created by RCU |
|---|---|
| STB | `<PREFIX>_STB` |
| MDS | `<PREFIX>_MDS` |
| OPSS | `<PREFIX>_IAS_OPSS` |
| IAU, IAU_APPEND, IAU_VIEWER | `<PREFIX>_IAU` |
| UCSUMS | `<PREFIX>_IAS_UMS` |
| WLS (+ WLS_RUNTIME) | `<PREFIX>_WLS` |

plus a temporary tablespace (`fmw/fmw_Storage.xml`). Not our way – six
tablespaces to size and watch.

---

## What the Script Does

- Reads `DB_HOST`, `DB_PORT`, `DB_SERVICE`, `DB_SCHEMA_PREFIX`, `ORACLE_HOME`
  from `environment.conf`
- Reads `RCU_TABLESPACE` / `RCU_TEMP_TABLESPACE` from `environment.conf`
  (passes `-tablespace` / `-tempTablespace` after every component; empty =
  WARN, RCU creates one tablespace per component – not the standard)
- Decrypts `DB_SYS_PWD` + `DB_SCHEMA_PWD` from `db_sys_sec.conf.des3`
  (written by `00-Setup/database_rcu_sec.sh` or `09-Install/01-setup-interview.sh`)
- Creates `/tmp/rcu_pw_<PID>.tmp` with correct permissions (600)
- **DB Pre-Flight Check** (before touching the database):
  1. TCP port reachability (`bash /dev/tcp`) — fails fast if listener is down
  2. `rcu -listSchemas` — tests SYSDBA auth and lists existing schemas;
     aborts if connection fails or if prefix already exists (use `--drop` first)
  3. Registry overview (`rcu_registry_overview.sql`, all prefixes – before
     the first RCU run `IHW:NOREG`, no error) and the database requirements
     (`rcu_db_requirements.sql`, same as `--check`) – a FAIL item stops `--apply`
  4. `db_securefile` (create only, via sqlplus as SYSDBA): with `FORCE` the
     first RCU run in a database fails – the registry
     `SYSTEM.SCHEMA_VERSION_REGISTRY$` (CLOB) is created in the non-ASSM
     tablespace `SYSTEM` → ORA-43853. FAIL if `FORCE` and no registry yet
     (fix: `ALTER SYSTEM SET db_securefile=PREFERRED`), WARN if `FORCE` and a
     registry already exists. `PREFERRED`/`ALWAYS` are fine (BasicFile in
     `SYSTEM`). Live test: architecture doc §4.2
  5. Tablespaces `RCU_TABLESPACE` + `RCU_TEMP_TABLESPACE` in `dba_tablespaces`
     of the PDB (same sqlplus call, also in `--check`): `ONLINE` → OK,
     missing / not online → FAIL, stops `--apply` (since 2026-11-03 – before,
     only a "pre-created?" prompt). Only without `sqlplus` in `ORACLE_HOME`
     the script still asks the operator to confirm it
- Runs `rcu -silent -createRepository` with all 8 components (9 schemas total,
  including the WLS_RUNTIME sub-schema)
- **Database type** `RCU_DB_TYPE` (`EBR` | `ORACLE`, default `EBR`, asked by
  the interview) is always passed as `-databaseType` (also to
  `-listSchemas` / `-dropRepository`). Tested 2026-10-17: silent RCU
  **without** `-databaseType` created EBR schemas (editions enabled, edition
  `ORA$BASE`), `-databaseType ORACLE` creates schemas without editions; the
  GUI may preselect "Oracle Database". One explicit type per installation;
  the type of an existing prefix cannot be changed (drop + recreate).
  Background: `80-FMW-Architecture/rcu_middleware_architecture.md` §4.3
- Deletes the password file immediately via `trap cleanup EXIT`
  (cleanup runs even if RCU fails or script is interrupted)
- Verifies the RCU Completion Summary in the log (`Success` ≥ 8 components,
  any `Failure` = FAIL)
- **DB profile** (since 2026-10-17): RCU creates its schemas with profile
  `DEFAULT` – in 19c `PASSWORD_LIFE_TIME 180` / `FAILED_LOGIN_ATTEMPTS 10`:
  after 180 days the data sources and the OPSS bootstrap can no longer log in
  and the domain does not start; a wrong password in a data source locks the
  schema. RCU has no option for a profile, so after `-createRepository` the
  script runs `60-RCU-DB-19c/rcu_user_profile.sql` as SYSDBA (network
  connection, SYS password via stdin): creates/aligns `RCU_DB_PROFILE`
  (default `RCU_USER`: `PASSWORD_LIFE_TIME UNLIMITED`,
  `FAILED_LOGIN_ATTEMPTS UNLIMITED`) and assigns it to every schema of the
  prefix listed in `SYSTEM.SCHEMA_VERSION_REGISTRY$`. For an existing
  repository: `--profile`. DB preparation before RCU (on the DB host):
  `60-RCU-DB-19c/06-db_rcu_profile.sh`. Background:
  [`80-FMW-Architecture/rcu_middleware_architecture.md`](../../80-FMW-Architecture/rcu_middleware_architecture.md) §6.1.

---

## Flags

| Flag | Description |
|---|---|
| (none) | Show what would be created (connection info, schema names); no DB connection |
| `--apply` | Run RCU and create schemas |
| `--drop` | Drop existing schemas (CAUTION: destroys data) |
| `--check` | Read-only: FMW 14.1.2 database requirements in the target PDB + the tablespaces `RCU_TABLESPACE` / `RCU_TEMP_TABLESPACE` – version (19c ≥ 19.14 / 23ai–26ai ≥ 23.4.0.24), edition (EE; SE2 → ORA-00439), AL32UTF8, Oracle JVM, `db_block_size`, RCU parameter minimums (`processes` 1000, `open_cursors` 1600, `session_cached_cursors` 100, `db_files` 600). The same check runs automatically before `--apply` (FAIL items stop RCU). Requirements: [rcu_middleware_architecture.md §9](../../80-FMW-Architecture/rcu_middleware_architecture.md#9-database-requirements-for-the-repository-19c--26ai) |
| `--profile` | Only create/align `RCU_DB_PROFILE` and assign it to the existing schemas of the prefix (no RCU run); shows all prefixes of the registry first |
| `--prefix <P>` | With `--profile`: prefix(es) to assign (repeatable), default `DB_SCHEMA_PREFIX`; exact match, no "all" option – see `60-RCU-DB-19c/docs/06-db_rcu_profile.md` |
| `--help` | Show usage |

---

## Verification

```bash
# List schemas in the DB (tests SYSDBA connection + shows existing schemas)
# Password file: 1 line (SYS password only)
echo "MySysDBAPassword" > /tmp/rcu_pw_verify.txt
chmod 600 /tmp/rcu_pw_verify.txt

$ORACLE_HOME/oracle_common/bin/rcu \
    -silent \
    -listSchemas \
    -databaseType EBR \
    -connectString "${DB_HOST}:${DB_PORT}/${DB_SERVICE}" \
    -dbUser sys -dbRole sysdba \
    -f < /tmp/rcu_pw_verify.txt

rm -f /tmp/rcu_pw_verify.txt
```

Note: `-listSchemas` and `-createRepository` are the valid silent-mode commands in
FMW 14.1.2. There is no `-checkRequirements` or `-checkPrereqs` in this version.

---

## Notes

- RCU requires a SYSDBA connection to create schemas — this is a one-time operation
- Passwords (`DB_SYS_PWD`, `DB_SCHEMA_PWD`) are never written to disk in plaintext;
  the password file is created in `/tmp` with mode 600 and deleted via `trap EXIT`
  — cleanup runs even if RCU fails or the script is interrupted with Ctrl+C
- `DB_SYS_PWD` + `DB_SCHEMA_PWD` are stored together in `db_sys_sec.conf.des3`
  → manage with `00-Setup/database_rcu_sec.sh --apply`
- RCU logs: `/tmp/RCU<date_time_random>/logs/rcu.log` (one directory per
  RCU run, also for `-listSchemas`; documented in the RCU guide "RCU Log
  Files", confirmed 2026-10-17 – `$ORACLE_HOME/oracle_common/rcu/log/` does
  not exist in 14.1.2)
- If RCU fails: check the newest `/tmp/RCU*/logs/rcu.log` for the error
- Check the profile / password expiry of the schemas:
  `SELECT username, profile, account_status, expiry_date FROM dba_users WHERE username LIKE 'DEV\_%' ESCAPE '\';`
- Re-running RCU with `-createRepository` fails if schemas already exist
  → use `--drop` first (CAUTION: destroys all FMW configuration data)
- `RCU_TABLESPACE` / `RCU_TEMP_TABLESPACE`: set in `environment.conf` via
  `01-setup-interview.sh` (Block 4); standard = one tablespace for all
  schemas (*Tablespace Configuration*), empty only as fallback

---

## References

- Oracle FMW 14.1.2 – Repository Creation Utility Guide (Running RCU in Silent Mode):
  https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/rcuug/repository-creation-utility.html#GUID-22C3AC9D-2F27-49ED-B983-8F4FC94C5501
- Oracle FMW 14.1.2 – RCU Guide (Overview):
  https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/rcuug/repository-creation-utility.html#GUID-2E73B30E-9E64-4986-82AD-CD54BB9641BD
