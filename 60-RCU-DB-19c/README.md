# 60-RCU-DB-19c – Minimal Oracle 19c Database for FMW RCU

Oracle 19c single-instance CDB/PDB database, sized for FMW 14.1.2 RCU metadata
schemas only.  Goal: smallest possible footprint on disk and in memory.

---

> **License Notice**
>
> The database hosting the FMW RCU schemas must be licensed according to
> Oracle database licensing guidelines:
> *"Follow the Oracle licensing guidelines for the Oracle database that hosts the repository."*
>
> RCU is **not** a license-free special case.
> The underlying database requires a full Oracle license — **Enterprise Edition (EE)**
> or **Standard Edition 2 (SE2)**.\
> Oracle Database XE or restricted runtime editions are **not permitted** —
> they are not certified for FMW RCU.
>
> → Oracle licensing reference: [MOS Doc ID 2605929.1](https://support.oracle.com/epmos/faces/DocumentDisplay?id=2605929.1) (FMW Interoperability Matrix)

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

**Default edition: Oracle Database 19c Enterprise Edition (EE).**
SE2 is technically sufficient for a pure RCU repository (supports CDB/PDB + Unified Auditing)
but EE is the default to avoid certification edge cases.
To switch: set `DB_EDITION=SE2` in `environment_db.conf`.
→ Details: [docs/00-concept.md – Edition](docs/00-concept.md)

---

## Script Sequence

All scripts follow the `--apply` / dry-run pattern of the 09-Install scripts.
Run in this order — each step must complete before the next:

| # | Script | Runs as | What |
|---|---|---|---|
| 0 | `00-root_db_os_baseline.sh` | root | DB kernel params, limits, preinstall RPM |
| 1 | `01-db_install_software.sh` | oracle | 19c software-only silent install |
| 2 | `02-db_patch_db_software.sh` | oracle | AutoUpgrade download + cp-a + opatchauto + chopt |
| 4 | `04-db_setup_listener.sh` | oracle | listener.ora + sqlnet.ora + systemd auto-start |
| 5 | `05-db_create_database.sh` | oracle | DBCA silent CDB+PDB + post-config |
| 6 | `06-db_audit_setup.sh` | oracle | AUDITLOG tablespace + purge jobs + policy |
| 7 | `07-db_fmw_tablespace.sh` | oracle | Optional: pre-create FMW_DATA tablespace |
| 8 | `08-db_auto_start.sh` | oracle | /etc/oratab + oracle-db.service systemd unit |

After step 8, continue with:

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
| [docs/00-db_os_baseline.md](docs/00-db_os_baseline.md) | OS parameters, packages, shmmax conflict |
| [docs/01-db_install_software.md](docs/01-db_install_software.md) | Silent software install |
| [docs/02-db_patch_autoupgrade.md](docs/02-db_patch_autoupgrade.md) | AutoUpgrade patch + chopt |
| [docs/04-db_setup_listener.md](docs/04-db_setup_listener.md) | listener.ora, sqlnet.ora, systemd unit |
| [docs/05-db_create_database.md](docs/05-db_create_database.md) | DBCA silent, sizing, CDB/PDB |
| [docs/06-db_audit_setup.md](docs/06-db_audit_setup.md) | Unified Auditing setup |
| [docs/07-db_fmw_tablespace.md](docs/07-db_fmw_tablespace.md) | Optional FMW_DATA tablespace |
| [docs/08-db_auto_start.md](docs/08-db_auto_start.md) | /etc/oratab + oracle-db.service auto-start |

---

## References

- [FMW 14.1.2 System Requirements](https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/sysrs/system-requirements-and-specifications.html#GUID-A5BAA99B-E383-4063-9EF7-BA963CF472A1)
- [FMW 14.1.2 RCU Guide](https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/rcuug/repository-creation-utility.html#GUID-2E73B30E-9E64-4986-82AD-CD54BB9641BD)
- FMW Interoperability Matrix: MOS Doc ID 2605929.1
