# Concept – Minimal Oracle 19c RCU Database

## Goal

The smallest possible Oracle 19c database that satisfies the FMW 14.1.2 RCU
requirements.  Nothing more.

FMW RCU creates 7 metadata schemas (STB, MDS, OPSS, IAU, IAU_APPEND,
IAU_VIEWER, UCSUMS).  These schemas store configuration and audit data —
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

The `DB_SERVICE` in `environment.conf` always points to `FMWPDB`, never to
the CDB.

### Archivelog: OFF for dev/test, ON for production

A metadata-only database used only during domain startup/shutdown does not
need point-in-time recovery.  Archivelog OFF keeps disk usage minimal.

Exception: if this database is used in a production environment, enable
archivelog mode after creation.

### Automatic Memory Management (AMM)

`MEMORY_TARGET` controls total memory (SGA + PGA combined).  Oracle manages
the split internally.  Simpler than separate SGA_TARGET + PGA_AGGREGATE_TARGET
for a small, non-tuned installation.

Minimum: `MEMORY_TARGET=1536M`  (1.5 GB)
Recommended: `MEMORY_TARGET=2048M`  (2 GB, leaves headroom for FMW startup)

> On systems with HugePages, AMM (MEMORY_TARGET) cannot be used — switch to
> `SGA_TARGET` + `PGA_AGGREGATE_TARGET` and configure HugePages accordingly.

### Unified Auditing: on from day 1

The kernel relink (`make uniaud_on ioracle`) must happen either:
1. Before the first database is created — zero downtime, preferred
2. On a closed database — requires restart of all instances on the ORACLE_HOME

This setup relinks in `05-db_create_database.sh` **before** calling DBCA.
The relink must be repeated after every Oracle RU patch (integrated into
`02-db_patch_db_software.sh`).

Classical (mixed-mode) auditing is not configured.  The `AUDITLOG` tablespace
holds all unified audit data.

### Edition: EE is the default

**Enterprise Edition (EE) is used by default** (`DB_EDITION=EE` in
`environment_db.conf`).  EE avoids any certification edge cases with FMW
components and is the safe choice for all production and development setups.

SE2 (Standard Edition 2) is technically sufficient for a pure RCU metadata
database: it supports CDB/PDB (up to 3 PDBs since 19.7) and Unified
Auditing.  Switch to SE2 only when:
- The license budget explicitly requires SE2, and
- The DB will never host application data beyond FMW schemas, and
- No RAC, Partitioning, or Advanced Compression is needed

To switch: set `DB_EDITION=SE2` in `environment_db.conf` before running
`01-db_install_software.sh`.

---

### No optional components

After patching, disable unused options to reduce attack surface and binary size:

```bash
$ORACLE_HOME/bin/chopt disable olap
$ORACLE_HOME/bin/chopt disable rat
```

OLAP and Real Application Testing are never needed for FMW metadata storage.

---

## FMW / DB Configuration Separation

| File | Purpose | Sourced by |
|---|---|---|
| `environment.conf` | FMW/WLS settings + DB connection params | All 09-Install scripts |
| `environment_db.conf` | DB-internal settings (ORACLE_HOME, SID, sizing) | 60-RCU-DB-19c scripts only |

The two files share:
- `ORACLE_BASE` (must match — both use `/u01/app/oracle`)
- `ROOT_DIR` (project root)
- `00-Setup/IHateWeblogic_lib.sh` (logging, ok/warn/fail)

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
source "$SCRIPT_DIR/../environment_db.conf"
export ORACLE_HOME="$DB_ORACLE_HOME"   # local to this script process
# ... run DB commands ...
# ORACLE_HOME reverts when script exits
```

### Directory layout on a shared host

```
ORACLE_BASE=/u01/app/oracle                 (shared — same in both conf files)
├── fmw/                                    ← FMW_HOME  (09-Install)
│   ├── wlserver/
│   └── oracle_common/ forms/ reports/ ...
├── product/
│   └── 19.30.0/db_home1/                  ← DB_ORACLE_HOME (installed via runInstaller -applyRU)
├── oradata/
│   └── FMWCDB/
│       ├── system01.dbf  sysaux01.dbf ...  ← CDB datafiles
│       └── FMWPDB/
│           └── system01.dbf  ...           ← PDB datafiles
├── admin/
│   └── FMWCDB/adump/                      ← audit dump (traditional)
└── diag/                                  ← Oracle ADR (automatic)
    └── rdbms/fmwcdb/FMWCDB/
        ├── alert/                          ← alert log
        └── trace/                          ← trace files
```

`/u01/app/oraInventory/` is shared between FMW and DB — Oracle handles this
automatically, no conflict.

Bridge between the two: after the PDB is running, the DBA (or the install
engineer) sets in `environment.conf`:

```bash
DB_HOST=localhost       # or DB server hostname
DB_PORT=1521
DB_SERVICE=FMWPDB      # PDB service name — NOT the CDB SID
DB_SCHEMA_PREFIX=DEV   # e.g. DEV, TEST, PROD
```

---

## Same Host: shmmax/shmall Conflict

`09-Install/01-root_os_baseline.sh` sets `kernel.shmmax` to the WLS OUI
installation value intentionally (comment in that script).  The Oracle DB
preinstall RPM would set it much higher — which breaks the WLS OUI installer.

Resolution (same host, both FMW and DB):

1. Run `09-Install` phase 0–1 (root scripts + FMW software install) with the
   WLS-sized shmmax/shmall in place
2. Run `60-RCU-DB-19c/00-root_db_os_baseline.sh` — upgrades shmmax/shmall to
   DB-sized values
3. WLS runtime does not require the smaller values — only WLS OUI during install

---

## Disk Layout (minimal)

```
$DB_BASE/
└── oradata/
    └── FMWCDB/
        ├── system01.dbf        200 MB
        ├── sysaux01.dbf        500 MB
        ├── undotbs01.dbf       200 MB
        ├── temp01.dbf          100 MB
        └── FMWPDB/
            ├── system01.dbf    200 MB
            ├── sysaux01.dbf    300 MB
            ├── undotbs01.dbf   200 MB
            ├── temp01.dbf      100 MB
            ├── auditlog01.dbf  100 MB  ← grows slowly; purge job keeps it bounded
            └── fmw_data01.dbf  500 MB  ← optional, for DBA-managed RCU tablespace
```

Redo logs (CDB-level): 2 groups × 50 MB = 100 MB
Control files: 2 × 20 MB = 40 MB

**Total DB files: ~2.5 GB fresh, ~4 GB with growth margin**

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
root:   00-root_db_os_baseline.sh    OS params, preinstall RPM, limits
oracle: 01-db_install_software.sh   extract base + AU download + runInstaller -applyRU + chopt disable
oracle: 04-db_setup_listener.sh     listener.ora + sqlnet.ora + tnsnames.ora + oracle-listener.service
oracle: 05-db_create_database.sh    uniaud_on relink → DBCA silent CDB+PDB
oracle: 06-db_audit_setup.sh        AUDITLOG-TS + audit policies (CDB+PDB) + purge job
oracle: 07-db_fmw_tablespace.sh     (optional) FMW_DATA tablespace for RCU
oracle: 08-db_auto_start.sh         /etc/oratab :Y + oracle-db.service systemd unit

→ then: 09-Install/07-oracle_setup_repository.sh --apply
```
