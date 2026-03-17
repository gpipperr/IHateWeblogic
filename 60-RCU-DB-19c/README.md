# 60-RCU-DB-19c – Minimal Oracle 19c Database for FMW RCU

Oracle 19c single-instance CDB/PDB database, sized for FMW 14.1.2 RCU metadata
schemas only.  Goal: smallest possible footprint on disk and in memory.

---

## When to use this

Only needed when **no Oracle database is available** in the environment and the
FMW domain must be installed on the same server or a dedicated minimal DB host.

If a DBA-managed database already exists, skip this entire section and go
directly to:

```
09-Install/07-oracle_setup_repository.sh --apply
```

---

## Architecture

```
CDB: FMWCDB
 └─ PDB: FMWPDB   ← all 7 FMW RCU schemas (PREFIX_STB/MDS/OPSS/IAU/…)

Listener: port 1521
DB_SERVICE (in environment.conf) → FMWPDB  (PDB service, not CDB)
```

Pluggable database from day 1 — required for Oracle 21c+ and simplifies
future migration to a DBA-managed infrastructure database.

---

## Minimum Resource Requirements

| Resource | Minimum | Recommended |
|---|---|---|
| RAM | 2 GB | 4 GB |
| Disk – DB software | 8 GB | 8 GB |
| Disk – DB files | 4 GB | 8 GB |
| Disk – total | **12 GB** | **16 GB** |
| CPU | 1 core | 2 cores |

> These figures apply to a **metadata-only** database (FMW RCU schemas).
> Do not use this sizing for application data, archive logs, or production loads.

---

## Script Sequence

All scripts follow the `--apply` / dry-run pattern of the 09-Install scripts.
Run in this order — each step must complete before the next:

| # | Script | Runs as | What |
|---|---|---|---|
| 0 | `00-root_db_os_baseline.sh` | root | DB kernel params, limits, preinstall RPM |
| 1 | `01-db_install_software.sh` | oracle | 19c software-only silent install |
| 2 | `02-db_patch_autoupgrade.sh` | oracle | AutoUpgrade create_home + chopt disable |
| 3 | `03-db_create_database.sh` | oracle | Unified Audit relink → DBCA silent CDB+PDB |
| 4 | `04-db_audit_setup.sh` | oracle | AUDITLOG tablespace + purge jobs + policy |
| 5 | `05-db_fmw_tablespace.sh` | oracle | Optional: pre-create FMW_DATA tablespace |

After step 5, continue with:

```
09-Install/07-oracle_setup_repository.sh --apply
09-Install/08-oracle_setup_domain.sh --apply
```

---

## Configuration

Copy the template and edit before running any script:

```bash
cp environment_db.conf.example environment_db.conf
chmod 600 environment_db.conf
vi environment_db.conf
```

`environment_db.conf` is **separate from** `environment.conf` (FMW/WLS).
The 09-Install scripts read `environment.conf`; these scripts read
`environment_db.conf`.  The two files share `ROOT_DIR` and
`00-Setup/IHateWeblogic_lib.sh`, but no variables overlap.

The only bridge: after the DB is running, set in `environment.conf`:
```
DB_HOST=localhost    # or the DB server hostname
DB_PORT=1521
DB_SERVICE=FMWPDB   # PDB service name
```

---

## Same Host vs. Separate DB Server

**Same host (FMW + DB on one machine):**
- Run `09-Install` phase 0–3 (FMW software install) first, then this section
- `00-root_db_os_baseline.sh` will upgrade shmmax/shmall to DB-sized values —
  this is safe at runtime; only WLS OUI needs the smaller values during install

**Separate DB server:**
- Run only `00-root_db_os_baseline.sh` through `04-db_audit_setup.sh` here
- No FMW scripts needed on the DB host

---

## Docs

| Doc | Content |
|---|---|
| [docs/00-concept.md](docs/00-concept.md) | Architecture decisions, FMW/DB separation |
| [docs/01-db_os_baseline.md](docs/01-db_os_baseline.md) | OS parameters, packages, shmmax conflict |
| [docs/02-db_install_software.md](docs/02-db_install_software.md) | Silent software install |
| [docs/03-db_patch_autoupgrade.md](docs/03-db_patch_autoupgrade.md) | AutoUpgrade patch + chopt |
| [docs/04-db_create_database.md](docs/04-db_create_database.md) | DBCA silent, sizing, CDB/PDB |
| [docs/05-db_audit_setup.md](docs/05-db_audit_setup.md) | Unified Auditing setup |

---

## References

- [FMW 14.1.2 System Requirements](https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/sysrs/system-requirements-and-specifications.html#GUID-A5BAA99B-E383-4063-9EF7-BA963CF472A1)
- [FMW 14.1.2 RCU Guide](https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/rcuug/repository-creation-utility.html#GUID-2E73B30E-9E64-4986-82AD-CD54BB9641BD)
- FMW Interoperability Matrix: MOS Doc ID 2605929.1
