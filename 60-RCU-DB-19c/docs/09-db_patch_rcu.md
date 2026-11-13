---
title: "Patch the Oracle 19c RCU Database Out-of-Place"
description: "Step 9: patch the running Oracle 19c RCU database out-of-place each release update cycle – build the new home, move the database, datapatch, rollback path."
---

# Step 9 – 09-db_patch_rcu.sh (patch the RCU database out-of-place)

**Script:** [`60-RCU-DB-19c/09-db_patch_rcu.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/09-db_patch_rcu.sh)
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
   AutoUpgrade (newest jar): RU + OJVM + DPBP + OPatch + jdk  ->  gold image / base + opatch
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
options, `db_securefile=FORCE`). Our way reuses `01-` (download, gold image or
base install + `opatch`, one-offs) and keeps every step visible.

## Step 1 – build the new home

```bash
./60-RCU-DB-19c/01-db_install_software.sh --target-home $ORACLE_BASE/product/19.33.0/db_home1 --fresh-patches
./60-RCU-DB-19c/01-db_install_software.sh --target-home $ORACLE_BASE/product/19.33.0/db_home1 --fresh-patches --apply
# root.sh of the new home when asked
```

| Option | Effect |
|---|---|
| `--target-home <dir>` | installs into `<dir>`; `DB_ORACLE_HOME` (running home) and `environment_db.conf` stay unchanged; home name `OraDB19Home_<version dir>` (unique in the inventory, else `_<date>` appended) |
| `--fresh-patches` | moves the patch ZIPs (`p*.zip`), an old gold image (`db_goldimage_*.zip`) and `patches_info.json` of `patchdir/` to `patchdir_<timestamp>/` (the 19.3 base ZIP stays) → AutoUpgrade downloads the current set (with offline ZIPs in `$PATCH_STORAGE/database/patches/` they are linked again instead) |
| route | gold image (AutoUpgrade `recommended`), otherwise "patch first, then install" (19.3 base image + `opatch apply` RU / OneOffs, then `runInstaller`) – [01-db_install_software.md](01-db_install_software.md#installation-routes); `-applyRU` only with `--apply-ru-installer`, not on FMW hosts |
| disk space **first** | home min 12 / rec 15 GB, staging min 8 / rec 14 GB – on one file system 20 / 29 GB; staging −6 GB when `base_stage` exists, patch ZIPs / a gold image are already in `patchdir` (without `--fresh-patches`) or offline ZIPs exist → 14 / 23 GB. FAIL stops `--apply`; variables `DB_HOME_MIN_FREE_GB`, `DB_HOME_REC_FREE_GB`, `DB_STAGE_MIN_FREE_GB`, `DB_STAGE_REC_FREE_GB` |

## Step 2 – move the database

```bash
./60-RCU-DB-19c/09-db_patch_rcu.sh --new-home $ORACLE_BASE/product/19.33.0/db_home1           # checks + plan
./60-RCU-DB-19c/09-db_patch_rcu.sh --new-home $ORACLE_BASE/product/19.33.0/db_home1 --apply   # downtime of the domain
```

| # | Step | Details |
|---|---|---|
| 1a | disk space | Data Pump in `DATA_PUMP_DIR`: segment size of `owner LIKE '<prefix>\_%'` × 1.2 + 1 GB (rec. +1 GB more) – only `DB_SCHEMA_PREFIX` (default `DEV`), other prefixes in the same DB are not backed up; log dir min 1 GB; data files min 1 / rec 2 GB (datapatch grows SYSTEM / SYSAUX) – FAIL stops before anything is stopped |
| 1b | homes / DB | instance runs from `DB_ORACLE_HOME` (`/proc/<pmon>/exe`); target home ≠ running home; new home installed + in the inventory; `root.sh` of the new home has run (`install/root_*.log`); new RU > old RU (`opatch lspatches`); `PDB$SEED` READ ONLY (otherwise WARN); `db_securefile` not `FORCE` in CDB / PDB; `OPATCH_XML_INV` readable; FMW requirements (`rcu_db_requirements.sql`) |
| 2 | backup | `07-Maintenance/rcu_repository_check.sh --apply` (Data Pump of the prefix schemas + `SYSTEM.SCHEMA_VERSION_REGISTRY$`); copy of `dbs/`, `network/admin/`, `/etc/oratab`, `environment_db.conf` to `log/<date>/rcu_patch_<ts>/` |
| 3 | stop | `01-Run/startStop.sh stop-all` (with `LOCAL_REP_DB=true`, otherwise confirmation that the remote domain is down), `SHUTDOWN IMMEDIATE`, `lsnrctl stop`; VM snapshot pause (`confirm_snapshot`) |
| 4 | files | `spfile<SID>.ora`, `orapw<SID>`, `init.ora`, `network/admin/*.ora` → new home (existing files there saved as `.bak_<ts>`) |
| 5 | unified auditing | old home linked `uniaud_on` (`libknlopt.a` contains `kzaiang`) → `make -f ins_rdbms.mk uniaud_on ioracle` in the new home |
| 6 | switch | `/etc/oratab` `<SID>:<new>:<flag unchanged>`; `environment_db.conf`: `DB_ORACLE_HOME=<new>`, `DB_ORACLE_HOME_PREV=<old>` (backup first); systemd units `oracle-listener.service` / `oracle-db.service` – the root commands (`sed` + `daemon-reload` + `reset-failed`) are printed, and again under "Next steps" |
| 7 | start | listener + `STARTUP` from the new home (`TNS_ADMIN` = the home's `network/admin`), `ALTER SYSTEM REGISTER`, wait ≤ 120 s until the PDB service is registered |
| 8 | datapatch | `OPatch/datapatch -verbose` (CDB + PDBs), result per container from `cdb_registry_sqlpatch` (`SUCCESS`); datapatch error → stop, logs `cfgtoollogs/sqlpatch/`, domain stays down. `utlrp` in all containers via `catcon.pl` (needs `sqlplus` in `PATH`) – a problem there is only a WARN (`log/<date>/rcu_patch_<ts>/utlrp*.log`), the domain is still started |
| 9 | verify / start | `version_full`, PMON binary from the new home, FMW requirements, `startStop.sh start-all`, `rcu_repository_check.sh` (data sources log in); remote domain (`LOCAL_REP_DB=false`): only a hint – start it on the FMW host, then `rcu_repository_check.sh` |

## Rollback

```bash
./60-RCU-DB-19c/09-db_patch_rcu.sh --rollback --apply
```

Same steps in the other direction with `DB_ORACLE_HOME_PREV`: stop, files
back, oratab / environment / units back, start from the old home and
**datapatch from the old home** – it rolls the SQL part of the newer RU back.
Differences: no Data Pump in step 2 (only the config copy), no "newer RU"
check; afterwards `DB_ORACLE_HOME_PREV` = the new home, so another
`--rollback` goes forward again. Last resort: Data Pump dumps of step 2 + VM
snapshot.

`--rollback` needs the instance running from `DB_ORACLE_HOME` (check 1b). If
the start from the new home fails in step 7 (oratab / environment already
switched in step 6): `STARTUP` from the old home by hand
(`ORACLE_HOME=<old>`, `TNS_ADMIN=<old>/network/admin`, `lsnrctl start`), set
`DB_ORACLE_HOME` back, then fix the cause – or run `--rollback --apply` once
the instance runs from the home in `DB_ORACLE_HOME`.

## After the patch

- keep the old home some days, then
  `$OLD_HOME/deinstall/deinstall -checkonly` and `-silent`. **Check first**
  that the tool was instantiated: `grep '^INSTALLED_VERSION_FLAG=' $OLD_HOME/deinstall/deinstall`
  must show `true` – a home built with the 19.3 image + `opatch` RU (the
  `-applyRU` route never worked on FMW hosts) keeps the placeholder
  `%setInstallFlag%` and the tool stops with `deinstall/perl/bin/perl: No such
  file or directory` (test host 2026-11-10). Then: nothing of the old home may
  run (`/proc/*/exe`), `oratab` / systemd units / profiles must not name it,
  `$NEW_HOME/oui/bin/runInstaller -silent -detachHome ORACLE_HOME=$OLD_HOME
  ORACLE_HOME_NAME=<name from inventory.xml>`, then remove the directory and
  empty `DB_ORACLE_HOME_PREV` (the rollback path ends here). Careful with the
  deinstall tool: the old home's `listener.ora` names the same `LISTENER` as
  the running one – deselect it (`.`) if the tool asks to de-configure
  listeners. `detachHome` of a home whose directory is already gone leaves a
  small stub directory (`inventory/`, `cfgtoollogs/`) – remove it;
- delete the Data Pump dumps (`DATA_PUMP_DIR/rcu_<prefix>_*_<ts>.dmp`) when no
  longer needed;
- systemd units: run the printed root commands **before the next reboot**
  (steps 3 / 7 stop and start listener and database with `lsnrctl` / sqlplus
  outside systemd – `systemctl reset-failed oracle-listener oracle-db` after
  the `daemon-reload`; the units take over again at the next reboot or
  `systemctl restart` in a maintenance window);
- record the new RU in the patch documentation of the cycle.

## Pitfalls

| Pitfall | Handling |
|---|---|
| service not registered after the start (`local_listener` alias only in the old home's `tnsnames.ora`, or the shared `TNS_ADMIN`) | `local_listener` is the explicit address since 2026-10-28 (`03-`); `09-` starts with the home's own `TNS_ADMIN` and waits for the registration |
| `PDB$SEED` MOUNTED | `ALTER PLUGGABLE DATABASE PDB$SEED OPEN READ ONLY` – never READ WRITE. If that fails with **ORA-14696** the MAX_STRING_SIZE migration is missing in the seed (databases created by `03-` before 2026-10-28) – repair first ([03-db_create_database.md](03-db_create_database.md#max_string_sizeextended--migrate-every-container-incl-pdbseed)) |
| `db_securefile=FORCE` (hardening) → ORA-43853 in RU scripts | `PREFERRED` with `SCOPE=MEMORY` for the patch, back afterwards ([rcu_middleware_architecture.md §4.2](../../80-FMW-Architecture/rcu_middleware_architecture.md)) |
| `OPATCH_XML_INV` / QOpatch directory objects point to a wrong path (PATCH112) | check before; recreate the directory objects |
| not enough space | checked first in `01-` and `09-` |

## Manual equivalent (same order)

```bash
OLD=$DB_ORACLE_HOME NEW=$ORACLE_BASE/product/<next RU>/db_home1 SID=FMWCDB
# 1 checks
df -h $OLD $NEW; $NEW/OPatch/opatch lspatches -oh $NEW
#   sqlplus: SELECT open_mode FROM v$pdbs WHERE name='PDB$SEED';   -- READ ONLY
# 2 backup
07-Maintenance/rcu_repository_check.sh --apply
cp -p $OLD/dbs/*$SID* $OLD/network/admin/*.ora /etc/oratab 60-RCU-DB-19c/environment_db.conf <backup dir>/
# 3 stop
01-Run/startStop.sh stop-all --apply
ORACLE_HOME=$OLD ORACLE_SID=$SID $OLD/bin/sqlplus / as sysdba <<< "shutdown immediate"
ORACLE_HOME=$OLD $OLD/bin/lsnrctl stop LISTENER
# 4 files
cp -p $OLD/dbs/spfile$SID.ora $OLD/dbs/orapw$SID $OLD/dbs/init.ora $NEW/dbs/
cp -p $OLD/network/admin/*.ora $NEW/network/admin/
# 5 unified auditing
ar -t $OLD/rdbms/lib/libknlopt.a | grep -q kzaiang && (cd $NEW/rdbms/lib && ORACLE_HOME=$NEW make -f ins_rdbms.mk uniaud_on ioracle)
# 6 switch: /etc/oratab  $SID:$NEW:Y ; environment_db.conf DB_ORACLE_HOME=$NEW, DB_ORACLE_HOME_PREV=$OLD
#   root: sed -i "s#$OLD#$NEW#g" /etc/systemd/system/oracle-{listener,db}.service; systemctl daemon-reload
# 7 start from the new home
export ORACLE_HOME=$NEW ORACLE_SID=$SID TNS_ADMIN=$NEW/network/admin
$NEW/bin/lsnrctl start LISTENER
$NEW/bin/sqlplus / as sysdba <<< "startup
alter system register;"
# 8 datapatch + utlrp
cd $NEW/OPatch && ./datapatch -verbose
cd $NEW/rdbms/admin && PATH=$NEW/bin:$NEW/perl/bin:$PATH $NEW/perl/bin/perl catcon.pl -n 1 -d $PWD -l /tmp -b utlrp utlrp.sql
#   sqlplus: SELECT con_id, patch_id, action, status FROM cdb_registry_sqlpatch ORDER BY action_time;
# 9 verify + start
#   sqlplus: SELECT version_full FROM v$instance;
01-Run/startStop.sh start-all --apply; 07-Maintenance/rcu_repository_check.sh
```

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
| PDB$SEED could not be opened before (ORA-14696) | repaired the same day ([03-db_create_database.md](03-db_create_database.md)) |

## References

- pipperr.de – AutoUpgrade patch automation 26ai (download, keystore,
  create_home / deploy, pitfalls): <https://pipperr.de/dokuwiki/doku.php?id=dba:autouppgrade_patch_automation_26ai>
- [01-db_install_software.md](01-db_install_software.md) – AutoUpgrade download, install routes, `jdk`
- [07-Maintenance/rcu_repository_check.sh](../../07-Maintenance/README.md) – Data Pump backup
