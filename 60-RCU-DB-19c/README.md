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
> Audit note: the FMW / Forms & Reports licence and RCU do **not** include a
> free use of the Oracle Database (EE or SE2) – the RCU metadata schemas need a
> separately licensed database (Oracle Fusion Middleware Licensing Information
> User Manual, E56762-96). Wording for compliance documents (EN / DE):
> [rcu_middleware_architecture.md §9.4](../80-FMW-Architecture/rcu_middleware_architecture.md#94-licence--separately-licensed-database-decision-2026-10-27)
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
 └─ PDB: FMWPDB   ← all 9 FMW RCU schemas (PREFIX_STB/MDS/OPSS/IAU/…/WLS/WLS_RUNTIME)

Listener: port 1521
DB_SERVICE (in environment.conf) → FMWPDB  (PDB service = DB_PDB_NAME, not CDB)
```

Pluggable database from day 1 — required for Oracle 21c+ and simplifies
future migration to a DBA-managed infrastructure database.

---

## Minimum Resource Requirements

| Resource | Minimum | Recommended |
|---|---|---|
| RAM | 2 GB | 4 GB |
| Disk – DB software | 12 GB (one patched home) | **24 GB** (2 homes during an out-of-place patch) |
| Disk – DB files | 8 GB | 15 GB |
| Disk – AutoUpgrade staging | 2 GB (patch set local / gold image) | 14 GB (AutoUpgrade download: + base stage 6.6 GB) |
| Disk – total | **30 GB** | **60 GB** (+ OS) |
| CPU | 1 core | 2 cores |

> Measured 2026-10-28 (19.33 home = 11–12 GB); details and the whole-host
> view: root README, [Disk Sizing Guide](../README.md#disk-sizing-guide).
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
| 0a | `00a-db_env_interview.sh` | oracle | Create / maintain `environment_db.conf` from the template, consistency check (`--check`) |
| 0 | `00-root_db_os_baseline.sh` | root | DB kernel params, limits, preinstall RPM |
| 0b | `00b-db_cvu_check.sh` | oracle | Validate the host with the standalone CVU (patch 30839369, `cluvfy comp sys -r 19`) |
| 1 | `01-db_install_software.sh` | oracle | Extract base + download patches + install (gold image, or base + opatch RU) |
| 2 | `02-db_setup_listener.sh` | oracle | listener.ora + sqlnet.ora + systemd auto-start |
| 3 | `03-db_create_database.sh` | oracle | DBCA silent CDB+PDB + post-config (`--clean` = drop and re-create) |
| 4 | `04-db_audit_setup.sh --relink --apply` | oracle | `uniaud_on` relink (stops + starts DB and listener; by hand: [docs/04-db_audit_setup.md](docs/04-db_audit_setup.md#prerequisites)) |
| 4 | `04-db_audit_setup.sh --apply` | oracle | common audit policies (all containers) + AUDITLOG tablespace + purge jobs |
| 5 | `05-db_fmw_tablespace.sh` | oracle | FMW_DATA tablespace for all RCU schemas (= `RCU_TABLESPACE`) |
| 6 | `06-db_rcu_profile.sh` | oracle | DB profile `RCU_USER` for the RCU schemas (no password expiry, no lock); `--assign` for existing schemas |
| 8 | `08-db_auto_start.sh` | oracle | /etc/oratab + oracle-db.service systemd unit |
| 9 | `09-db_patch_rcu.sh` | oracle | **Patch a running DB out-of-place:** new home with `01- --target-home <dir> --fresh-patches`, then move the instance (spfile, orapw, network, oratab, env), datapatch, utlrp, domain stop / start; `--rollback` |

After step 8, continue with:

```
09-Install/07-oracle_setup_repository.sh --apply
09-Install/08-oracle_setup_domain.sh --apply
```

---

## Configuration

Create it with the interview (from the template, after
`09-Install/01-setup-interview.sh`) before running any other script:

```bash
./60-RCU-DB-19c/00a-db_env_interview.sh            # dry-run: questions + diff
./60-RCU-DB-19c/00a-db_env_interview.sh --apply    # write (backup, mode 600)
./60-RCU-DB-19c/00a-db_env_interview.sh --check    # consistency check only
```

It asks only what differs per installation (DB home named after the RU of
`09-Install/download/patches_db.csv`, edition, SID / CDB, PDB = `DB_SERVICE`,
listener port = `DB_PORT`, SGA / PGA from RAM, data / FRA, archivelog, audit
retention, FMW tablespace = `RCU_TABLESPACE`), adds template keys an older
file misses, and replaces fixed `ORACLE_BASE` / `ORACLE_INVENTORY` values by
the inherited form – details: [docs/00a-db_env_interview.md](docs/00a-db_env_interview.md).
`cp environment_db.conf.example environment_db.conf` + `vi` still works
(then `--check`).

`environment_db.conf` is **separate from** `environment.conf` (FMW/WLS).
It is read **after** `environment.conf`: `ORACLE_BASE` and `ORACLE_INVENTORY`
default to the values of `environment.conf` – a fixed value in
`environment_db.conf` overrides them for all 60- scripts (an old copy of the
template had `/u01/...` fixed: check these two lines when `ORACLE_BASE` is
not `/u01/app/oracle`).
The 09-Install scripts read `environment.conf`; these scripts read
`environment_db.conf`.  The two files share `ROOT_DIR` and
`00-Setup/IHateWeblogic_lib.sh`, but no variables overlap.

The only bridge: after the DB is running, set in `environment.conf`:
```
DB_HOST=localhost    # or the DB server hostname
DB_PORT=1521
DB_SERVICE=FMWPDB   # PDB service name
```

### Host without MOS access (offline patches)

`01-db_install_software.sh` lets AutoUpgrade download the patch set from MOS.
Without MOS access (OCI private subnet, egress allow-list) download the list
[09-Install/download/patches_db.csv](../09-Install/download/patches_db.csv)
on a host that may, with the standalone
[mos_patch_download.sh](../70-Customer-Projects/tools/README.md#mos_patch_downloadsh),
and copy it:

```bash
./mos_patch_download.sh -c patches_db.csv -d <share>/patch_storage --apply
rsync -a <share>/patch_storage/database/ oracle@<target>:$PATCH_STORAGE/database/
```

`01-` links `$PATCH_STORAGE/database/patches/*/p*.zip` into an **empty**
AutoUpgrade `patchdir` (symlinks, no second copy on the staging file system)
and skips the download. The list holds the DB RU too (19.33 = **39915792**,
2.2 GB) – online AutoUpgrade `RECOMMENDED` delivers a gold image instead. The
19.3 base ZIP comes from eDelivery as before.

---

## Same Host vs. Separate DB Server

**Same host (FMW + DB on one machine):**
- Run `09-Install` phase 0–3 (FMW software install) first, then this section
- `00-root_db_os_baseline.sh` writes its own `/etc/sysctl.d/60-oracle-db.conf`;
  the 99- files of the FMW baseline / preinstall RPM are loaded later and win
  for the same keys – check the effective values
  ([docs/00-db_os_baseline.md](docs/00-db_os_baseline.md#effective-values-the-last-file-wins))

**Separate DB server:**
- Run only `00-root_db_os_baseline.sh` through `08-db_auto_start.sh` here
- No FMW scripts needed on the DB host

---

## Docs

| Doc | Content |
|---|---|
| [docs/00-concept.md](docs/00-concept.md) | Architecture decisions, FMW/DB separation |
| [docs/00-db_os_baseline.md](docs/00-db_os_baseline.md) | OS parameters, packages, shmmax conflict |
| [docs/00b-db_cvu_check.md](docs/00b-db_cvu_check.md) | Standalone CVU: download (04- `--mos`), checks, fixups, expected findings |
| [docs/01-db_install_software.md](docs/01-db_install_software.md) | Install + patch (gold image, base + opatch RU; -applyRU research only) |
| [docs/02-db_setup_listener.md](docs/02-db_setup_listener.md) | listener.ora, sqlnet.ora, systemd unit |
| [docs/03-db_create_database.md](docs/03-db_create_database.md) | DBCA silent, sizing, CDB/PDB |
| [docs/04-db_audit_setup.md](docs/04-db_audit_setup.md) | Unified Auditing setup (`uniaud_on` relink `--relink`, common policies, retention jobs) |
| [docs/05-db_fmw_tablespace.md](docs/05-db_fmw_tablespace.md) | FMW_DATA tablespace (one for all RCU schemas) |
| [docs/06-db_rcu_profile.md](docs/06-db_rcu_profile.md) | DB profile for the RCU schemas (password expiry / lock) |
| [docs/08-db_auto_start.md](docs/08-db_auto_start.md) | /etc/oratab + oracle-db.service auto-start |
| [docs/09-db_patch_rcu.md](docs/09-db_patch_rcu.md) | Out-of-place patching of the running RCU DB (new home + move + datapatch, rollback) |

---

## References

- [FMW 14.1.2 System Requirements](https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/sysrs/system-requirements-and-specifications.html#GUID-A5BAA99B-E383-4063-9EF7-BA963CF472A1)
- [FMW 14.1.2 RCU Guide](https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/rcuug/repository-creation-utility.html#GUID-2E73B30E-9E64-4986-82AD-CD54BB9641BD)
- FMW Interoperability Matrix: MOS Doc ID 2605929.1
- [Cluster Verification Utility downloads](https://www.oracle.com/database/technologies/cvu-downloads.html) – standalone CVU = MOS patch 30839369 (step 0b)
