# Step 9 – 09-db_patch_rcu.sh (patch the RCU database out-of-place)

**Script:** `60-RCU-DB-19c/09-db_patch_rcu.sh`
**Runs as:** `oracle` on the DB host (systemd unit change: root, commands printed)
**When:** every DB release update cycle (CPU / RU, e.g. 19.30 → 19.33 for CPU
October 2026) on a running installation

---

## Idea

No patching inside the running home. A **new, fully patched home** is built
next to it with the proven first-install path, then the instance moves into
it and `datapatch` brings the dictionary to the new RU. The old home stays as
the way back.

```
 01-db_install_software.sh --target-home <new> --fresh-patches --apply
   AutoUpgrade (newest jar): RU + OJVM + DPBP + OPatch + jdk  ->  runInstaller -applyRU
                                   |
 09-db_patch_rcu.sh --new-home <new> --apply
   1 checks (disk FIRST)  2 backup (Data Pump + config)  3 stop domain / DB / listener
   4 spfile, orapw, network/admin -> new   5 uniaud_on relink   6 oratab, env, units
   7 start from new home   8 datapatch + utlrp   9 verify, start domain
                                   |
 old home kept  ->  09-db_patch_rcu.sh --rollback --apply   (if needed)
                ->  deinstall after some days of stable operation
```

Why not AutoUpgrade `create_home` + `deploy` (pipperr.de, 26ai): `deploy`
sets a guaranteed restore point and needs **ARCHIVELOG** – the RCU database
runs without (`DB_ARCHIVELOG=false`); listener, oratab and systemd stay
manual anyway; known traps (PATCH112 QOpatch directory, PATCH114 binary
options, `db_securefile=FORCE`). Our way reuses `01-` (download, `-applyRU`,
one-offs) and keeps every step visible.

## Step 1 – build the new home

```bash
./60-RCU-DB-19c/01-db_install_software.sh --target-home $ORACLE_BASE/product/19.33.0/db_home1 --fresh-patches
./60-RCU-DB-19c/01-db_install_software.sh --target-home $ORACLE_BASE/product/19.33.0/db_home1 --fresh-patches --apply
# root.sh of the new home when asked
```

| Option | Effect |
|---|---|
| `--target-home <dir>` | installs into `<dir>`; `DB_ORACLE_HOME` (running home) and `environment_db.conf` stay unchanged; home name `OraDB19Home_<version dir>` (unique in the inventory) |
| `--fresh-patches` | moves the patch ZIPs (`p*.zip`) of `patchdir/` to `patchdir_<timestamp>/` (the 19.3 base ZIP stays) → AutoUpgrade downloads the current set |
| disk space **first** | home + staging on the same file system: min 14 / recommended 24 GB (home 6 / 10, staging 8 / 14; staging −6 GB when `base_stage` is already unpacked) – FAIL stops `--apply`; variables `DB_HOME_MIN_FREE_GB`, `DB_HOME_REC_FREE_GB`, `DB_STAGE_MIN_FREE_GB`, `DB_STAGE_REC_FREE_GB` |

## Step 2 – move the database

```bash
./60-RCU-DB-19c/09-db_patch_rcu.sh --new-home $ORACLE_BASE/product/19.33.0/db_home1           # checks + plan
./60-RCU-DB-19c/09-db_patch_rcu.sh --new-home $ORACLE_BASE/product/19.33.0/db_home1 --apply   # downtime of the domain
```

| # | Step | Details |
|---|---|---|
| 1a | disk space | Data Pump size of the `<prefix>_*` schemas × 1.2 in `DATA_PUMP_DIR`, backup copy, data files (datapatch grows SYSTEM / SYSAUX) – FAIL stops before anything is stopped |
| 1b | homes / DB | instance runs from `DB_ORACLE_HOME` (`/proc/<pmon>/exe`); new home installed + in the inventory; new RU > old RU (`opatch lspatches`); `PDB$SEED` READ ONLY; `db_securefile` not `FORCE` in CDB / PDB; `OPATCH_XML_INV` readable; FMW requirements (`rcu_db_requirements.sql`) |
| 2 | backup | `07-Maintenance/rcu_repository_check.sh --apply` (Data Pump of the prefix schemas + `SYSTEM.SCHEMA_VERSION_REGISTRY$`); copy of `dbs/`, `network/admin/`, `/etc/oratab`, `environment_db.conf` to `log/<date>/rcu_patch_<ts>/` |
| 3 | stop | `01-Run/startStop.sh stop-all` (with `LOCAL_REP_DB=true`, otherwise confirmation that the remote domain is down), `SHUTDOWN IMMEDIATE`, `lsnrctl stop`; VM snapshot pause (`confirm_snapshot`) |
| 4 | files | `spfile<SID>.ora`, `orapw<SID>`, `init.ora`, `network/admin/*.ora` → new home (existing files there saved as `.bak_<ts>`) |
| 5 | unified auditing | old home linked `uniaud_on` (`libknlopt.a` contains `kzaiang`) → `make -f ins_rdbms.mk uniaud_on ioracle` in the new home |
| 6 | switch | `/etc/oratab` `<SID>:<new>:Y`; `environment_db.conf`: `DB_ORACLE_HOME=<new>`, `DB_ORACLE_HOME_PREV=<old>` (backup first); systemd units `oracle-listener.service` / `oracle-db.service` – the root commands (`sed` + `daemon-reload`) are printed |
| 7 | start | listener + `STARTUP` from the new home (`TNS_ADMIN` = the home's `network/admin`), `ALTER SYSTEM REGISTER`, wait ≤ 120 s until the PDB service is registered |
| 8 | datapatch | `OPatch/datapatch -verbose` (CDB + PDBs), result per container from `cdb_registry_sqlpatch` (`SUCCESS`); `utlrp` in all containers via `catcon.pl` (needs `sqlplus` in `PATH`); error → stop, logs `cfgtoollogs/sqlpatch/`, domain stays down |
| 9 | verify / start | `version_full`, PMON binary from the new home, FMW requirements, `startStop.sh start-all`, `rcu_repository_check.sh` (data sources log in) |

## Rollback

```bash
./60-RCU-DB-19c/09-db_patch_rcu.sh --rollback --apply
```

Same steps in the other direction with `DB_ORACLE_HOME_PREV`: stop, files
back, oratab / environment / units back, start from the old home and
**datapatch from the old home** – it rolls the SQL part of the newer RU back.
Last resort: Data Pump dumps of step 2 + VM snapshot.

## After the patch

- keep the old home some days, then
  `$OLD_HOME/deinstall/deinstall -checkonly` and `-silent`;
- delete the Data Pump dumps (`DATA_PUMP_DIR/rcu_<prefix>_*_<ts>.dmp`) when no
  longer needed;
- systemd units: run the printed root commands **before the next reboot**;
- record the new RU in the patch documentation of the cycle.

## Pitfalls

| Pitfall | Handling |
|---|---|
| service not registered after the start (`local_listener` alias only in the old home's `tnsnames.ora`, or the shared `TNS_ADMIN`) | `local_listener` is the explicit address since 2026-10-28 (`05-`); `09-` starts with the home's own `TNS_ADMIN` and waits for the registration |
| `PDB$SEED` MOUNTED | `ALTER PLUGGABLE DATABASE PDB$SEED OPEN READ ONLY` – never READ WRITE. If that fails with **ORA-14696** the MAX_STRING_SIZE migration is missing in the seed (old `05-`, test host until 2026-10-28) – repair first ([05-db_create_database.md](05-db_create_database.md#max_string_sizeextended--migrate-every-container-incl-pdbseed)) |
| `db_securefile=FORCE` (hardening) → ORA-43853 in RU scripts | `PREFERRED` with `SCOPE=MEMORY` for the patch, back afterwards ([rcu_middleware_architecture.md §4.2](../../80-FMW-Architecture/rcu_middleware_architecture.md)) |
| `OPATCH_XML_INV` / QOpatch directory objects point to a wrong path (PATCH112) | check before; recreate the directory objects |
| not enough space | checked first in `01-` and `09-` |

## Status – live run 19.30 → 19.33 (test host, 2026-10-28)

**Done, confirmed (live).** Result: `version_full` 19.33.0.0.0, PMON from the
new home, datapatch `SUCCESS` in CDB$ROOT, PDB$SEED and FMWPDB (APPLY RU
39915792, OJVM 39803650, Data Pump 40057600; ROLLBACK of the 19.30 OJVM / Data
Pump patches), `utlrp` OK, FMW requirements OK, domain up, all data sources
log in (`rcu_repository_check.sh` rc 0).

| Phase | Time | Duration |
|---|---|---|
| `01-` download (AutoUpgrade 26.6, gold image 4.9 GB at ~2 MB/s) | 15:22 – 16:03 | 41 min (domain running) |
| `01-` gold image unpack + runInstaller + 3 × `opatch apply` | 16:11 – 16:25 | ~14 min (domain running) |
| `root.sh` (root) | 16:37 | – |
| `09-` checks + Data Pump + config backup | 16:38 – 16:41 | 3 min |
| **domain down**: stop, move, uniaud relink, start, datapatch, utlrp, start-all | 16:41 – 17:02 | **~22 min** (datapatch + utlrp the largest part) |

Findings of the run (fixed in the scripts):

| Finding | Fix |
|---|---|
| AutoUpgrade 26.6 `recommended` delivers a **gold image** (`db_goldimage_19_33_*.zip`, complete home with RU + OCW RU) instead of an RU ZIP | `01-` installs from the gold image (unzip as the new home, its `runInstaller`) |
| `runInstaller -applyOneOffs` with the gold image rejected the OJVM RU ("not applicable", `checkComponents` not executed) and detached the home | OneOffs (OJVM, Data Pump, JDK) with `opatch apply` after the installation, "skipped" = failure |
| `runInstaller` rc 6 = "Successfully Setup Software with warning(s)" | rc 6 → WARN |
| disk: the unpacked 19.33 home has **11 GB** (estimate was 8) – `/` reached 98 % | thresholds raised (home min 12 / rec 15 GB); in the gold-image case the 19.3 base stage (6.6 GB) is not needed and skipped |
| `sed -i /etc/oratab` fails (temp file in `/etc` not writable for oracle although oratab is) | write back through a temp file in `/tmp` |
| systemd unit files readable by root only → "no reference" was reported | unreadable units are treated as "to change", root commands printed |
| PDB$SEED could not be opened before (ORA-14696) | repaired the same day ([05-db_create_database.md](05-db_create_database.md)) |

## References

- pipperr.de – AutoUpgrade patch automation 26ai (download, keystore,
  create_home / deploy, pitfalls): https://pipperr.de/dokuwiki/doku.php?id=dba:autouppgrade_patch_automation_26ai
- [01-db_install_software.md](01-db_install_software.md) – AutoUpgrade download, `-applyRU`, `jdk`
- [07-Maintenance/rcu_repository_check.sh](../../07-Maintenance/README.md) – Data Pump backup
