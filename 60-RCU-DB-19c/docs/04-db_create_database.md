# Step 3 – 03-db_create_database.sh

**Script:** `60-RCU-DB-19c/03-db_create_database.sh`
**Runs as:** `oracle`
**Phase:** Create the CDB + PDB

---

## Purpose

1. Relink the Oracle binary for Unified Auditing (`uniaud_on`) — must happen
   before the first database is created on this ORACLE_HOME
2. Create the listener
3. Create the Container Database (FMWCDB) with one Pluggable Database (FMWPDB)
   via `dbca -silent`

---

## Step 1: Unified Audit Relink

Must happen on a closed Oracle binary before any instance exists:

```bash
cd $DB_ORACLE_HOME/rdbms/lib
make -f ins_rdbms.mk uniaud_on ioracle
```

Verify:
```bash
strings $DB_ORACLE_HOME/bin/oracle | grep -c kzaiang
# must return > 0
```

> This relink must be repeated after every Oracle RU patch.
> `02-db_patch_autoupgrade.sh` performs it automatically after create_home.

---

## Step 2: Listener (netca silent)

```bash
$DB_ORACLE_HOME/bin/netca -silent -responseFile \
    $DB_ORACLE_HOME/assistants/netca/netca.rsp
```

Or via dbca which creates the listener automatically if `createListener=true`.

Default: `LISTENER` on port `1521`.

---

## Step 3: DBCA Silent — Minimal CDB + PDB

### Design goals for minimal footprint

Source: Oracle FMW 14.1.2 System Requirements (Doc ID 2605929.1) and RCU Guide.

| Parameter | Value | Reason |
|---|---|---|
| `SGA_TARGET` | `1536M` | Minimum for stable PL/SQL compilation during RCU |
| `PGA_AGGREGATE_TARGET` | `512M` | Parallel RCU sessions; sort/hash operations |
| `DB_BLOCK_SIZE` | `8192` | FMW default; do not change |
| Character set | `AL32UTF8` | **Mandatory** — FMW RCU fails with any other charset |
| National char set | `AL16UTF16` | Oracle default |
| `PROCESSES` | `500` | RCU opens many parallel connections |
| `OPEN_CURSORS` | `1000` | **RCU pre-check RCU-6107 requires ≥ 400; set 1000 to be safe** |
| `compatible` | `19.0.0` | Required for 19c feature set |
| `max_string_size` | `EXTENDED` | FMW extended VARCHAR support; static — needs restart |
| Archivelog | `false` (dev) | Saves disk; not needed for metadata-only DB |
| Redo log groups | `2` | Minimum; one is always current |
| Redo log size | `50 MB` | Minimal for low-write workload |
| `DB_FILES` | `100` | More than enough for this DB |

> **AMM vs. SGA_TARGET:** `MEMORY_TARGET` (Automatic Memory Management) is simpler
> but cannot be used with HugePages.  For this minimal setup, `SGA_TARGET=1536M` +
> `PGA_AGGREGATE_TARGET=512M` is preferred — works with or without HugePages.
> Total memory: ~2 GB.

### Tablespace sizing (initial, AUTOEXTEND ON)

| Tablespace | File | Initial | NEXT | MAXSIZE | Where |
|---|---|---|---|---|---|
| SYSTEM | system01.dbf | 200 MB | 32 MB | 1 GB | CDB |
| SYSAUX | sysaux01.dbf | 500 MB | 32 MB | 2 GB | CDB |
| UNDOTBS1 | undotbs01.dbf | 200 MB | 32 MB | 2 GB | CDB |
| TEMP | temp01.tmp | 100 MB | 32 MB | 1 GB | CDB |
| SYSTEM (PDB) | system01.dbf | 200 MB | 32 MB | 1 GB | FMWPDB |
| SYSAUX (PDB) | sysaux01.dbf | 300 MB | 32 MB | 1 GB | FMWPDB |
| UNDOTBS1 (PDB) | undotbs01.dbf | 200 MB | 32 MB | 1 GB | FMWPDB |
| TEMP (PDB) | temp01.tmp | 100 MB | 32 MB | 1 GB | FMWPDB |

AUDITLOG tablespace: created by `04-db_audit_setup.sh` (separate script).
FMW_DATA tablespace: created by `05-db_fmw_tablespace.sh` (optional).

**Total fresh: ~1.8 GB, with 4× growth margin: ~7 GB**

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
    -sga            "${DB_SGA_MB:-1536}" \
    -pga            "${DB_PGA_MB:-512}" \
    -storageType    FS \
    -datafileDestination "${DB_DATA_DIR}" \
    -redoLogFileSize 50 \
    -emConfiguration NONE \
    -dbOptions      "JSERVER:false,ORACLE_TEXT:false,IMEDIA:false,CWMLITE:false,SPATIAL:false,OMS:false,APEX:false,DV:false" \
    -characterSet   AL32UTF8 \
    -nationalCharacterSet AL16UTF16 \
    -sysPassword    "${DB_SYS_PWD}" \
    -systemPassword "${DB_SYSTEM_PWD}" \
    -enableArchive  false \
    -recoveryAreaDestination "" \
    -useLocalUndoForPDBs true \
    2>&1 | tee -a "$LOG_FILE"
```

> `useLocalUndoForPDBs=true`: each PDB manages its own undo — required for
> PDB-level flashback and simplifies future PDB migration.

### Disabled DB options (via -dbOptions)

| Option | Disabled |
|---|---|
| JSERVER | Java in DB — not needed for FMW schemas |
| ORACLE_TEXT | Full-text search — not used by FMW |
| IMEDIA | Oracle Multimedia — not needed |
| CWMLITE | OLAP Catalog — not needed |
| SPATIAL | Oracle Spatial — not needed |
| APEX | Application Express — not needed |
| DV | Database Vault — not needed for RCU DB |

---

## Step 4: Post-Creation Parameter Tuning

Connect to the CDB as SYSDBA and apply parameters that DBCA does not set:

```sql
sqlplus / as sysdba

-- Cursor and process limits (RCU parallel sessions + pre-check RCU-6107)
ALTER SYSTEM SET open_cursors    = 1000 SCOPE=BOTH;
ALTER SYSTEM SET processes       = 500  SCOPE=SPFILE;

-- Extended string support for FMW VARCHAR columns (static — needs restart)
ALTER SYSTEM SET max_string_size = EXTENDED SCOPE=SPFILE;

-- Compatibility level
ALTER SYSTEM SET compatible      = '19.0.0' SCOPE=SPFILE;

-- PDB auto-open after CDB restart (CRITICAL — without this the PDB stays MOUNTED)
ALTER PLUGGABLE DATABASE ALL OPEN;
ALTER PLUGGABLE DATABASE ALL SAVE STATE;

-- Apply static changes
SHUTDOWN IMMEDIATE;
STARTUP;
ALTER PLUGGABLE DATABASE ALL OPEN;
```

> `ALTER PLUGGABLE DATABASE ALL SAVE STATE` persists the PDB open mode in the
> CDB data dictionary.  Without it, the PDB must be opened manually after every
> CDB restart.

---

## Step 5: Post-Creation Checks

```sql
sqlplus / as sysdba

-- Verify PDB is open
SHOW PDBS;
-- Expected: FMWPDB OPEN READ WRITE

-- Verify character set (must be AL32UTF8)
SELECT VALUE FROM NLS_DATABASE_PARAMETERS WHERE PARAMETER = 'NLS_CHARACTERSET';

-- Verify RCU-critical parameters
SHOW PARAMETER open_cursors;     -- expected: 1000
SHOW PARAMETER processes;        -- expected: 500
SHOW PARAMETER max_string_size;  -- expected: EXTENDED
SHOW PARAMETER compatible;       -- expected: 19.0.0
SHOW PARAMETER sga_target;
SHOW PARAMETER pga_aggregate_target;
```

---

## environment_db.conf Variables Used

```bash
ORACLE_BASE         # /u01/app/oracle — shared with FMW
DB_ORACLE_HOME      # ${ORACLE_BASE}/product/19.24.0/db_home1 — patched home
DB_ADMIN_DIR        # ${ORACLE_BASE}/admin  — audit dump dir
DB_DATA_DIR         # e.g. /u01/app/oracle/oradata
DB_SID              # e.g. FMWCDB
DB_CDB_NAME         # e.g. FMWCDB
DB_PDB_NAME         # e.g. FMWPDB
DB_MEMORY_MB        # e.g. 2048
DB_SYS_PWD          # from db_sys_sec.conf.des3
DB_SYSTEM_PWD       # from db_sys_sec.conf.des3
DB_PDB_ADMIN_PWD    # from db_sys_sec.conf.des3
```

---

## Notes

- `dbca -silent` exit code: 0 = success, non-zero = error; check
  `$DB_BASE/cfgtoollogs/dbca/` for detailed logs
- The database starts automatically via `/etc/oratab` + `dbstart`; configure
  systemd service separately if auto-start on boot is required
- After creation, update `environment.conf` with `DB_SERVICE=FMWPDB` before
  running the RCU script
