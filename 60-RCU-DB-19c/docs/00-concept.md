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

This setup relinks in `03-db_create_database.sh` **before** calling DBCA.
The relink must be repeated after every Oracle RU patch (integrated into
`02-db_patch_autoupgrade.sh`).

Classical (mixed-mode) auditing is not configured.  The `AUDITLOG` tablespace
holds all unified audit data.

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
- `ROOT_DIR` (project root)
- `00-Setup/IHateWeblogic_lib.sh` (logging, ok/warn/fail)

They do **not** share ORACLE_HOME.  The oracle user's `.bash_profile` continues
to point to `FMW_HOME` as `ORACLE_HOME`.  The DB scripts source
`environment_db.conf` and set `ORACLE_HOME` locally within the script scope.

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

## Script Sequence Summary

```
root:   00-root_db_os_baseline.sh    OS params, preinstall RPM, limits
oracle: 01-db_install_software.sh   runInstaller -silent software-only
oracle: 02-db_patch_autoupgrade.sh  AutoUpgrade create_home + chopt disable
oracle: 03-db_create_database.sh    uniaud_on relink → DBCA silent CDB+PDB
oracle: 04-db_audit_setup.sh        AUDITLOG-TS + audit policies + purge job
oracle: 05-db_fmw_tablespace.sh     (optional) FMW_DATA tablespace for RCU

→ then: 09-Install/07-oracle_setup_repository.sh --apply
```
