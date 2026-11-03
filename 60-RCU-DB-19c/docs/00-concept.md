# Concept – Minimal Oracle 19c RCU Database

## Goal

Background – what FMW stores in this database and who logs in:
[rcu_middleware_architecture.md](../../80-FMW-Architecture/rcu_middleware_architecture.md).

The smallest possible Oracle 19c database that satisfies the FMW 14.1.2 RCU
requirements.  Nothing more.

FMW RCU (`09-Install/07-oracle_setup_repository.sh`) creates 8 components =
9 metadata schemas (STB, MDS, OPSS, IAU, IAU_APPEND, IAU_VIEWER, UMS
(component UCSUMS), WLS, WLS_RUNTIME).  These schemas store configuration and audit data —
not application data.  Transaction volumes are low, the schemas are small
(< 500 MB total in a fresh install), and there are no performance-critical
queries at database level.

---

## Design Decisions

### CDB + single PDB

A Container Database with one Pluggable Database is the modern Oracle standard.
Reasons for this setup even for a minimal DB:

- Oracle 21c+ requires CDB; starting with 19c avoids a future migration
- PDB service name (`FMWPDB`) is the connection point for FMW — clean separation
  from the CDB administration layer
- Future hand-off to a DBA-managed infrastructure: just unplug the PDB and
  plug it into the production CDB

```
CDB: FMWCDB          ← admin layer, SYS/SYSTEM live here
 └─ PDB: FMWPDB      ← application layer, all PREFIX_* schemas live here
```

The `DB_SERVICE` in `environment.conf` always names the PDB (`DB_PDB_NAME`,
default `FMWPDB`; `00a-db_env_interview.sh` keeps both equal), never the CDB.

### Archivelog: OFF for dev/test, ON for production

A metadata-only database used only during domain startup/shutdown does not
need point-in-time recovery.  Archivelog OFF keeps disk usage minimal.

Exception: if this database is used in a production environment, enable
archivelog mode after creation.

### Memory: SGA_TARGET + PGA_AGGREGATE_TARGET (no AMM)

`03-db_create_database.sh` creates the database with `-memoryMgmtType
CUSTOM_SGA`: `sga_target=DB_SGA_MB`, `pga_aggregate_target=DB_PGA_MB`
(`00a-` proposes 15 % of RAM, 1536–4096 MB, PGA a third of it), plus
`shared_pool_size` / `java_pool_size` floors (`DB_SHARED_POOL_MB` 2048 /
`DB_JAVA_POOL_MB` 512) for the Oracle JVM install. Afterwards it sets both
pools to 0 (auto) and `sga_target` / `pga_aggregate_target` to
`DB_SGA_POST_MB` (2048) / `DB_PGA_POST_MB` (512). `MEMORY_TARGET` (AMM) is
not used – it works with and without HugePages.

### Unified Auditing: on from day 1

The kernel relink (`make uniaud_on ioracle`) must happen either:
1. Before the first database is created — zero downtime, preferred
2. On a closed database — requires restart of all instances on the ORACLE_HOME

**State 2026-10-29 (checked against the scripts):** `03-db_create_database.sh`
only **reports** whether the binary is linked with `uniaud_on` (`kzaiang`) and
prints the relink command; the relink itself is a manual step with database
and listener stopped ([04-db_audit_setup.md](04-db_audit_setup.md#prerequisites)),
and `04-db_audit_setup.sh` stops with FAIL until it is done. An out-of-place
patch keeps it: `09-db_patch_rcu.sh` relinks the new home when the old one has
`uniaud_on`. (The original plan – relink in `03-` (then `05-`) before DBCA, repeated after
every RU in the former `02-db_patch_db_software.sh` – was not implemented;
`02-` was removed 2026-11-02.)

Classical (mixed-mode) auditing is not configured.  The `AUDITLOG` tablespace
holds all unified audit data.

### Edition: EE is the default

**Enterprise Edition (EE) is used by default** (`DB_EDITION=EE` in
`environment_db.conf`).  EE avoids any certification edge cases with FMW
components and is the safe choice for all production and development setups.

SE2 (Standard Edition 2) supports CDB/PDB (up to 3 PDBs since 19.7) and
Unified Auditing, but **RCU 14.1.2 uses Enterprise-Edition features**: on
SE2 it fails with ORA-00439 "feature not enabled: Fine-grained access
control" (VPD – workaround patch 37506854, MOS Doc ID 3083393.1) and
ORA-00439 Partitioning with EBR / UMS (bugs 37603856 / 37555123, UMS bundle
patch) – see
[rcu_middleware_architecture.md §9.3](../../80-FMW-Architecture/rcu_middleware_architecture.md#93-edition--ee-se2-only-with-workaround-patches).
Switch to SE2 only when:
- The license budget explicitly requires SE2, and
- the workaround patches are applied to the FMW home and a test RCU run
  succeeded, and
- The DB will never host application data beyond FMW schemas, and
- No RAC, Partitioning, or Advanced Compression is needed

Licence of the repository DB: **separately licensed** – the FMW / Forms &
Reports licence does not include the database (audit wording in §9.4 of the
same document).

To switch: set `DB_EDITION=SE2` in `environment_db.conf` before running
`01-db_install_software.sh`.

---

### No optional components

`01-db_install_software.sh` disables unused options as its last step (attack
surface, binary size); by hand with the DB home's `chopt`:

```bash
$DB_ORACLE_HOME/bin/chopt disable olap
$DB_ORACLE_HOME/bin/chopt disable rat
```

OLAP and Real Application Testing are never needed for FMW metadata storage.

---

## FMW / DB Configuration Separation

| File | Purpose | Sourced by |
|---|---|---|
| `environment.conf` | FMW/WLS settings + DB connection params | All 09-Install scripts |
| `environment_db.conf` | DB-internal settings (ORACLE_HOME, SID, sizing) | 60-RCU-DB-19c scripts only |

`environment_db.conf` is read **after** `environment.conf`. The two files share:
- `ORACLE_BASE`, `ORACLE_INVENTORY` – inherited from `environment.conf`
  (template form `ORACLE_BASE="${ORACLE_BASE:-/u01/app/oracle}"`; a fixed value
  overrides it for all 60- scripts – `00a-db_env_interview.sh` replaces it)
- `PATCH_STORAGE` (base ZIP, offline patches, CVU), `ROOT_DIR` (project root)
- `00-Setup/IHateWeblogic_lib.sh` (logging, ok/warn/fail)

`00-root_db_os_baseline.sh` (root) reads only `environment.conf`.

### ORACLE_HOME: the ambiguous variable

`ORACLE_HOME` is an Oracle convention that means different things in different
contexts.  On a host running both FMW and a DB, the oracle user has exactly
one `$ORACLE_HOME` in `.bash_profile` — which must be set to FMW_HOME for
the WLS scripts to work.

**Rule: never use bare `$ORACLE_HOME` in the DB scripts.**

The DB scripts use `DB_ORACLE_HOME` as an explicit variable (sourced from
`environment_db.conf`).  All oracle binary calls use the full path:

```bash
# Wrong — reads oracle user's .bash_profile ORACLE_HOME (= FMW!)
$ORACLE_HOME/bin/dbca ...

# Correct — always explicit
$DB_ORACLE_HOME/bin/dbca ...
$DB_ORACLE_HOME/bin/sqlplus ...
$DB_ORACLE_HOME/OPatch/opatch ...
```

The ORACLE_HOME environment variable is set **within script scope only**:

```bash
source "$ROOT_DIR/environment.conf"
source "$SCRIPT_DIR/environment_db.conf"   # 60-RCU-DB-19c/environment_db.conf
export ORACLE_HOME="$DB_ORACLE_HOME"   # local to this script process
# ... run DB commands ...
# ORACLE_HOME reverts when script exits
```

### Directory layout on a shared host

```
/u01/app/
├── oraInventory/                           ← ORACLE_INVENTORY (one level above ORACLE_BASE)
│   └── ContentsXML/inventory.xml           ← shared by FMW and DB
│
└── oracle/                                 ← ORACLE_BASE (shared — same in both conf files)
    ├── fmw/                                ← FMW_HOME  (09-Install)
    │   ├── wlserver/
    │   └── oracle_common/ forms/ reports/ ...
    ├── product/
    │   ├── 19.33.0/db_home1/              ← DB_ORACLE_HOME (one versioned home per RU,
    │   │                                     01- gold image or base + opatch RU)
    │   └── <previous RU>/db_home1/        ← DB_ORACLE_HOME_PREV after 09-db_patch_rcu.sh
    │                                         (rollback path, deinstall after some days)
    ├── oradata/
    │   └── FMWCDB/
    │       ├── system01.dbf  sysaux01.dbf ...  ← CDB datafiles
    │       └── FMWPDB/
    │           └── system01.dbf  ...           ← PDB datafiles
    ├── admin/
    │   └── FMWCDB/adump/                  ← audit dump (traditional)
    └── diag/                              ← Oracle ADR (automatic)
        └── rdbms/fmwcdb/FMWCDB/
            ├── alert/                     ← alert log
            └── trace/                     ← trace files
```

`ORACLE_INVENTORY` (`/u01/app/oraInventory/`) lives **one level above** `ORACLE_BASE` and is
shared between FMW and DB homes — Oracle handles multi-home registration automatically.
`/etc/oraInst.loc` (root-owned) points to it; created by:
- `09-Install/03-root_user_oracle.sh` on a shared host
- `60-RCU-DB-19c/00-root_db_os_baseline.sh` on a separate DB server

Bridge between the two: after the PDB is running, the DBA (or the install
engineer) sets in `environment.conf`:

```bash
DB_HOST=localhost       # or DB server hostname
DB_PORT=1521
DB_SERVICE=FMWPDB      # PDB service name — NOT the CDB SID
DB_SCHEMA_PREFIX=DEV   # e.g. DEV, TEST, PROD
```

---

## Same Host: kernel parameters from several files

FMW and DB both write kernel parameters to `/etc/sysctl.d/`:
`09-Install/01-root_os_baseline.sh` → `99-oracle-fmw.conf`, the preinstall
RPM → `99-oracle-database-preinstall-19c-sysctl.conf`,
`00-root_db_os_baseline.sh` → `60-oracle-db.conf`. `sysctl --system` loads
them in lexical order – **the last file wins**, so the 99- files override
`60-oracle-db.conf` (test host 2026-11-02: effective `kernel.shmmax`
4398046511104 from the preinstall RPM, not the RAM/2 value of `60-`). With
`LOCAL_REP_DB=true` the FMW baseline treats its shm values only as minimums
and keeps the larger DB values. Check what is effective:
`sysctl kernel.shmmax kernel.shmall fs.aio-max-nr` and
`grep -H -E 'shmmax|shmall|aio-max-nr' /etc/sysctl.d/*.conf`.

---

## Disk Layout (minimal)

Measured on the test host (2026-11-02, `General_Purpose.dbc`, after RCU and
some months of operation – sizes come from the DBCA template, the scripts set
only `-redoLogFileSize 50`):

```
$DB_DATA_DIR/                    (default $ORACLE_BASE/oradata)
└── FMWCDB/
    ├── system01.dbf        ~1.5 GB
    ├── sysaux01.dbf        ~1.2 GB
    ├── undotbs01.dbf       ~1.6 GB
    ├── temp01.dbf          ~0.3 GB
    ├── redo01..03.log      3 × 50 MB
    ├── control01.ctl         (control02.ctl in the FRA)
    ├── pdbseed/            ~1.8 GB  (system, sysaux, undo, temp)
    └── FMWPDB/
        ├── system01.dbf    ~1 GB
        ├── sysaux01.dbf    ~0.5 GB
        ├── undotbs01.dbf   ~0.3 GB
        ├── temp01.dbf      ~0.3 GB
        ├── auditlog01.dbf  100 MB  ← DB_AUDIT_TS_SIZE_MB; purge jobs keep it bounded
        └── fmw_data01.dbf  500 MB  ← all RCU schemas (05-), DB_FMW_TABLESPACE_SIZE_MB
```

**Total DB files: ~9 GB** (test host 9.8 GB incl. 0.5 GB APEX) – fresh
somewhat less; the README sizing (8 / 15 GB) covers it.

Homes and staging come on top: one patched 19c home ≈ 11–12 GB, two of them
during an out-of-place patch, plus the AutoUpgrade patch directory – host
totals in the root README [Disk Sizing Guide](../../README.md#disk-sizing-guide).

---

## References

| Document | URL |
|---|---|
| FMW 14.1.2 System Requirements and Specifications | https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/sysrs/system-requirements-and-specifications.html#GUID-A5BAA99B-E383-4063-9EF7-BA963CF472A1 |
| FMW 14.1.2 Repository Creation Utility Guide | https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/rcuug/repository-creation-utility.html#GUID-2E73B30E-9E64-4986-82AD-CD54BB9641BD |
| FMW Interoperability Matrix (MOS) | Doc ID 2605929.1 |
| Oracle AutoUpgrade / Patch Automation 19c | https://www.pipperr.de/dokuwiki/doku.php?id=dba:autouppgrade_patch_automation_19c |
| Oracle Unified Auditing Migration | https://www.pipperr.de/dokuwiki/doku.php?id=dba:unified_auditing_oracle_migration_23ai |
| Oracle Linux 8 OS Baseline for Oracle DB | https://www.pipperr.de/dokuwiki/doku.php?id=linux:linux_8_system_grundeinstellungen_oracle_datenbank_rac |

---

## Script Sequence Summary

```
oracle: 00a-db_env_interview.sh     environment_db.conf from the template (--check: consistency only)
root:   00-root_db_os_baseline.sh   preinstall RPM, oracle in dba/oper, expect, perl-File-Copy,
                                    sysctl, limits, libpthread stub, oraInst.loc (DB-only host)
oracle: 00b-db_cvu_check.sh         host pre-check with the standalone CVU
oracle: 01-db_install_software.sh   gold image (preferred), else 19.3 base into the home + attachHome
                                    + opatch RU/OneOffs + detachHome + runInstaller on the patched image;
                                    AutoUpgrade download (+ base_stage) only when no patches are local;
                                    root.sh, chopt disable olap/rat
oracle: 02-db_setup_listener.sh     listener.ora + sqlnet.ora + tnsnames.ora + oracle-listener.service
oracle: 03-db_create_database.sh    DBCA silent CDB+PDB, MAX_STRING_SIZE in every container,
                                    local_listener = explicit address (uniaud_on: reported only)
manual: uniaud_on relink            DB + listener down (04-db_audit_setup.md)
oracle: 04-db_audit_setup.sh        AUDITLOG-TS + audit policies (CDB+PDB) + purge jobs
oracle: 05-db_fmw_tablespace.sh     FMW_DATA tablespace for all RCU schemas
oracle: 06-db_rcu_profile.sh       profile RCU_USER (no password expiry / lock)
oracle: 08-db_auto_start.sh         /etc/oratab :Y + oracle-db.service systemd unit

→ then: 09-Install/07-oracle_setup_repository.sh --apply

Later, every DB RU: 01- --target-home <new> --fresh-patches, then
09-db_patch_rcu.sh --new-home <new> --apply (out-of-place, rollback path)
```
