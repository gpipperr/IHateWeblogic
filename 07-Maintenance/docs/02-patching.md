---
title: "Oracle Forms & Reports 14c – Patching a Running Installation"
description: "Patching a running Oracle Forms & Reports 14.1.2 installation per CPU / CSPU cycle: workflow, JDK update order, domain_jdk_path.sh, 80- / 81- / 82- wrappers, patch_storage.sh, RCU repository check."
---

# Patching an already-running environment (CPU / CSPU cycle)

← [07-Maintenance](../README.md) · topics: [backup / restore](01-backup_restore.md) · [patching](02-patching.md) · [security hardening](03-security_hardening.md)

## 1. Workflow per patch cycle

> 📋 **Current patch numbers?** →
> [`09-Install/docs/00-patch-references.md`](../../09-Install/docs/00-patch-references.md)

> **RCU schemas and patching:** regular patches (SPB / CSPU / Forms and
> Reports one-offs) never change the RCU schemas – only a version upgrade
> does (Upgrade Assistant). Run [`rcu_repository_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/rcu_repository_check.sh) before and after a
> patch cycle as a health check; before an upgrade or a move with `--apply`
> (backup). Background:
> [`80-FMW-Architecture/rcu_middleware_architecture.md`](../../80-FMW-Architecture/rcu_middleware_architecture.md).

`80-`/`81-`/`82-patch_*.sh` are **thin wrappers**: they add one thing that
was previously missing — a hard check that WebLogic is actually stopped —
then delegate 100% of the real patch logic to the unchanged, already
idempotent `09-Install/05-` and `06-oracle_patch_*.sh` scripts (safe to
re-run; they skip whatever is already applied). No patch logic is
duplicated here.

```
1. Update 09-Install/oracle_software_version.conf with the new cycle's
   patch numbers — see 09-Install/docs/00-patch-references.md
   (customer host: git pull of the current release, e.g. v1.0.202611 –
   the maintainer switched conf + patch lists already)
2. 09-Install/04-oracle_pre_download.sh --apply --mos
   (add --fresh-patches first to archive the previous cycle's ZIPs)
   no MOS access on the host: 04- --offline-list -> CSV for
   mos_patch_download.ps1 on a PC with internet, scp the tree back
   (09-Install/docs/04-oracle_pre_download.md "No MOS access on the host")
   ./07-Maintenance/domain_jdk_path.sh            # read-only: pinned jdk-21.0.x paths?
3. ./07-Maintenance/backup_config.sh --apply
4. ./01-Run/startStop.sh stop-all --apply        # REQUIRED before step 5-7
   (81-/82- refuse --apply while NM, a WLS server or ANY process from
    $ORACLE_HOME runs – rwserver, Reports engines, frmweb, rwrun …;
    80- also while a JVM runs from JDK_HOME – ORDS, stopped by stop-all)
   Then each of 80-/81-/82- --apply pauses: "VM snapshot now?" – type ok to
   continue, anything else aborts (no terminal or IHW_NO_SNAPSHOT_PROMPT=true:
   no pause). Everything is stopped at that point, so the snapshot is
   consistent.
5. ./07-Maintenance/domain_jdk_path.sh --apply    # only if step 2 listed files (backup first)
   ./07-Maintenance/80-patch_java_os.sh --apply   # JDK_HOME from patches/<JDK_PATCH_NR>/ (WARN if missing)
6. ./07-Maintenance/81-patch_weblogic.sh --apply  # WLS FMW Basis layer
7. ./07-Maintenance/82-patch_forms_reports.sh --apply   # Forms + Reports layer
8. Forms only: ./09-Install/14-oracle_setup_forms.sh --apply
   (a Forms patch can reset extensions.jnlp / formsweb.cfg – re-activates the
   signed jacob.jar, re-signs a jacob.jar replaced by a new JACOB version)
   Forms client distribution (FORMS_CLIENT_DIST=true): ./09-Install/40-oracle_forms_client_bundle.sh --apply
   (new client Java from step 2 / new frmsal.jar from step 7 -> new bundle,
   clients update themselves at their next start; domain may run)
9. ./01-Run/startStop.sh start-all --apply
10. verify:
    ./09-Install/15-deploy-test-report-forms_template.sh --apply   # smoke test Forms + Reports
    ./01-Run/rwserver_status.sh ; ./06-FormsDiag/forms_settings.sh
    ./02-Checks/java_check.sh
    ./10-Monitoring/cve_inventory.sh   # installed patches = PATCH_CYCLE
    ./08-SSL/ssl_local_ca.sh status    # own root CA: certificate expiry
11. If something breaks: ./07-Maintenance/restore_config.sh --apply
```

**Why only 3 scripts for "4 layers"?** [`06-oracle_patch_forms_reports.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/06-oracle_patch_forms_reports.sh)
already auto-detects whether `$ORACLE_HOME/forms` and `$ORACLE_HOME/reports`
exist and only patches what's actually installed — there is exactly one
underlying call for both, so [`82-patch_forms_reports.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/82-patch_forms_reports.sh) covers the Forms
and the Reports conceptual layer together. A separate Forms-only/
Reports-only script would need a new `--only forms|reports` scope flag on
the delegated script first — not implemented (bundled on purpose, see
[`09-Install/docs/06-oracle_patch_forms_reports.md`](../../09-Install/docs/06-oracle_patch_forms_reports.md)).

**Why [`04-oracle_pre_download.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/04-oracle_pre_download.sh) isn't called automatically by the
wrappers:** updating [`oracle_software_version.conf`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/oracle_software_version.conf) with the new cycle's
patch numbers (step 1) is an inherent human-judgment step (reading the new
CPU/CSPU advisory) — it has to happen before any download anyway, and
`05-`/`06-oracle_patch_*.sh` already print the exact download command
whenever a required patch ZIP is missing.

**Java/OS layer (step 5):** since October 2026 JDK 21 updates exist only
on MOS (Patch 35702194 – the NFTC for JDK 21 ended in September 2026). The
patch is downloaded **once**, with all other patches, by
`04-oracle_pre_download.sh --apply --mos`; `80-patch_java_os.sh --apply` only
looks into `$PATCH_STORAGE/patches/<JDK_PATCH_NR>/` – missing or not newer →
WARN / OK, no download. Details: [01-root_setup_java.md](../../09-Install/docs/01-root_setup_java.md#patch-cycle-minimum-and-upgrade---upgrade-jdk).
The FMW-bundled JDK (`oracle_common/jdk`, OPatch component `oracle.jdk`)
is patched with OPatch (`FMW_JDK_PATCH_NR`, still to be determined).

#### JDK update on an existing customer home – order

`80-` only repoints the symlink `JDK_HOME` (`jdk-21 → jdk-21.0.x`). A file
that still names the **versioned** directory (`setDomainEnv.sh`,
`nodemanager.properties`, `oui/.globalEnv.properties`, a text script in
`$ORACLE_HOME/bin` like `aqxmlctl` …) keeps the domain on the **old** JDK
after the switch – `80-` reports it afterwards only read-only ("Pinned JDK
paths found"). So clean them up **before** the switch, in the same window:

| # | When | Command | Note |
|---|---|---|---|
| 1 | before, system runs | `git pull` (release of the cycle), `09-Install/04-oracle_pre_download.sh --apply --mos` | JDK patch (35702194) into the patch storage – check the version inside the ZIP |
| 2 | before, system runs | `07-Maintenance/domain_jdk_path.sh` | read-only – lists pinned paths; `WARN JDK_HOME is no symlink` → first convert `JDK_HOME` to a link by hand (variant b of [Java_wechsel_Kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/FormsReports_change_java/Java_wechsel_Kochbuch_de.txt)), only then go on |
| 3 | window | `01-Run/startStop.sh stop-all --apply` | also ORDS; any other JVM on `JDK_HOME` is named by `80-`, which refuses otherwise |
| 4 | window | `07-Maintenance/domain_jdk_path.sh --apply` | only if step 2 found files; backup `ConfigBackup/jdk_path_<ts>/`; harmless before the switch (the old JDK directory stays) |
| 5 | window | `07-Maintenance/80-patch_java_os.sh --apply` | VM-snapshot pause, `02b-` installs the new JDK beside the old one (SHA-256, **SecureRandom fix** `file:/dev/./urandom` – a manual unpack misses it, live 2026-11-18), link switch, `domain_jdk_path.sh` read-only as counter-check |
| 6 | window | `01-Run/startStop.sh start-all --apply`, `09-Install/15-deploy-test-report-forms_template.sh --apply`, `09-Install/90-oracle_validate.sh` | wait for the Reports server before the smoke test (REP-50001 right after the start) |
| 7 | after | `09-Install/40-oracle_forms_client_bundle.sh --apply` | only with the Forms client distribution – new client runtime |

Rollback: `sudo ln -sfn <old jdk dir> $JDK_HOME` (printed by `80-`), the
files of step 4 from `ConfigBackup/jdk_path_<ts>/`. The bundled
`oracle_common/jdk` is not touched by any of these steps.

## 2. Scripts

### domain_jdk_path.sh

```bash
./07-Maintenance/domain_jdk_path.sh            # read-only: files with jdk-21.0.x
./07-Maintenance/domain_jdk_path.sh --apply    # replace with JDK_HOME, then restart
```

Manual way without the library (German cookbook, every file with vi): [70-Customer-Projects/FormsReports_change_java](../../70-Customer-Projects/FormsReports_change_java/README.md).

WLST `createDomain` / `updateDomain` (and the Config Wizard) resolve the
`JDK_HOME` symlink and write the versioned JDK directory into
`setDomainEnv.sh`, `setNMJavaHome.sh`, `nodemanager.properties`, the Forms
instance scripts and `init-info/*`; the installer into
`$ORACLE_HOME/oui/.globalEnv.properties`, `oui/bin/*.sh` and text scripts directly in
`$ORACLE_HOME/bin` (e.g. `aqxmlctl`, found 2026-11-17). A JDK upgrade
that only repoints the symlink would not reach WebLogic. Matches `JDK_HOME`
followed by a version suffix and the current symlink target; skips logs,
`servers/` and backups. Backup: `ConfigBackup/jdk_path_<ts>/` with the original
paths below it. Called by [`09-Install/08-oracle_setup_domain.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/08-oracle_setup_domain.sh); run it
after every JDK upgrade and every `updateDomain`.

### 80-patch_java_os.sh

```bash
./07-Maintenance/80-patch_java_os.sh            # read-only: java_check.sh + JDK in the patch repository?
./07-Maintenance/80-patch_java_os.sh --apply    # upgrade JDK_HOME from the patch repository
```

| Option | Description |
|---|---|
| `--apply` | domain must be stopped (`require_wls_stopped`); calls `09-Install/02b-root_os_java.sh --apply --upgrade-jdk` (sudo inside), then [`domain_jdk_path.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/domain_jdk_path.sh) (read-only check) and [`java_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/java_check.sh) |
| `--help` | Show usage |

Without `--apply`: [`java_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/java_check.sh) plus `02b- --upgrade-jdk` as dry-run –
which JDK is in the repository, would it be installed. Rollback:
`ln -sfn <old jdk dir> $JDK_HOME` (old directory is kept).

### 81-patch_weblogic.sh

```bash
./07-Maintenance/81-patch_weblogic.sh                # dry-run
./07-Maintenance/81-patch_weblogic.sh --check-only    # conflict check only
./07-Maintenance/81-patch_weblogic.sh --apply         # patch (requires WLS stopped)
```

Options: same as [`09-Install/05-oracle_patch_weblogic.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/05-oracle_patch_weblogic.sh) (`--apply`,
`--check-only`, `--help`) — forwarded verbatim, no translation.

Delegates to: `09-Install/05-oracle_patch_weblogic.sh` (OPatch upgrade, WLS
Stack Patch Bundle, `INSTALL_PATCHES` loop). Own code: the
`require_wls_stopped()` hard gate before `--apply` (OPatch itself does not
enforce a stopped domain).

### 82-patch_forms_reports.sh

```bash
./07-Maintenance/82-patch_forms_reports.sh                # dry-run
./07-Maintenance/82-patch_forms_reports.sh --check-only    # conflict check only
./07-Maintenance/82-patch_forms_reports.sh --apply          # patch (requires WLS stopped)
```

Options: same as [`09-Install/06-oracle_patch_forms_reports.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/06-oracle_patch_forms_reports.sh) — forwarded
verbatim.

Delegates to: `09-Install/06-oracle_patch_forms_reports.sh` (auto-detects
Forms/Reports, superseded-QPR rollback, `check_patch_zip()` validation). Own
code: same `require_wls_stopped()` hard gate as `81-`.

### patch_storage.sh

Small local disk, big but slow archive (customer 2026-10-30: installing from
the ZFS share is far too slow, the local disk cannot hold every installer and
patch at once). `PATCH_ARCHIVE` (interview, optional) is the **master copy**
with the layout of `PATCH_STORAGE` – the share host with MOS access downloads
straight into it (`mos_patch_download.sh -c patches_fmw.csv -d <archive> --all
--apply`, eDelivery ZIPs by browser into `wls/`, `fr/`). The local
`PATCH_STORAGE` only holds what the next step needs.

```bash
./07-Maintenance/patch_storage.sh                                         # status
./07-Maintenance/patch_storage.sh pull 05-oracle_patch_weblogic.sh         # show what would be copied + space check
./07-Maintenance/patch_storage.sh pull 05-oracle_patch_weblogic.sh --apply # copy archive -> local
./07-Maintenance/patch_storage.sh pull spb --apply                         # or by CSV role
./07-Maintenance/patch_storage.sh clean                                    # what could be freed
./07-Maintenance/patch_storage.sh clean --apply                            # ask per file
./07-Maintenance/patch_storage.sh clean --apply --yes                      # take every proposal
./07-Maintenance/patch_storage.sh history                                  # last run per script
```

**Items** – no own list: every row of [`09-Install/download/patches_fmw.csv`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/download/patches_fmw.csv)
(+ [`patches_db.csv`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/download/patches_db.csv) with `LOCAL_REP_DB=true`) the installation needs (same role
rules as `04-`), the eDelivery ZIPs + their extracted installers of
[`oracle_software_version.conf`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/oracle_software_version.conf), the 19c base (`DB_INSTALL_ARCHIVE`, when below
`PATCH_STORAGE`), APEX/ORDS version directories.

**Which run frees what** (last `--apply` run with rc 0 or 1 in the run history):

| Files | Freed by a successful |
|---|---|
| `wls/` ZIP + `fmw_*_infrastructure.jar` | [`09-Install/05-oracle_install_weblogic.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/05-oracle_install_weblogic.sh) |
| `fr/` ZIP + `fmw_*_fr_linux64.bin` | [`09-Install/06-oracle_install_forms_reports.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/06-oracle_install_forms_reports.sh) |
| roles `opatch`, `spb`, `wls` | [`09-Install/05-oracle_patch_weblogic.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/05-oracle_patch_weblogic.sh) or [`81-patch_weblogic.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/81-patch_weblogic.sh) (not `--opatch-only`) |
| roles `fr_common`, `reports`, `forms`, `fr_optional` | [`09-Install/06-oracle_patch_forms_reports.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/06-oracle_patch_forms_reports.sh) or [`82-patch_forms_reports.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/82-patch_forms_reports.sh) |
| role `jdk` | `09-Install/02b-root_os_java.sh --upgrade-jdk` or [`80-patch_java_os.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/80-patch_java_os.sh) |
| role `client_jdk` | [`09-Install/40-oracle_forms_client_bundle.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/40-oracle_forms_client_bundle.sh) |
| role `cvu` / 19c base + [`patches_db.csv`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/download/patches_db.csv) | `60-RCU-DB-19c/00b-` / [`01-db_install_software.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/01-db_install_software.sh) |
| role `apex`, APEX / ORDS directories | `12-APEX-Ords/03-` / `02-` / `04-` |

**Proposals** (`status`, `clean`): `pull` = only in the archive, step not done
yet; `keep` = step not done; `free` = step done and the archive holds the same
size (or an extracted installer – re-created from the ZIP); `archive` = step
done, file only local → copy into the archive, verify SHA-256, then delete
locally; without an archive only *delete* or *keep* (proposal *keep* – deleted
means downloading again). Also offered by `clean`: `patches_<ts>/` +
`client/jdk_<ts>/` of `--fresh-patches`, staging directories of finished runs
in `$ORACLE_BASE/tmp` (`mw_patches_<pid>`, `fr_patches_<pid>`, `wls_spb_<pid>`,
`opatch_*_<pid>` – only when that PID no longer runs). Info only:
`$ORACLE_HOME/.patch_storage` (OPatch rollback data, `opatch util cleanup`).

`pull` checks the free space first (size + 10 %), copies with `rsync -a
--partial` (resumable; without `rsync` `cp` via a `.part` name), compares the
size and the SHA-256 of the CSV (soft check, WARN). [`04-oracle_pre_download.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/04-oracle_pre_download.sh)
shows files that are only in the archive as *in archive* (not MISSING); the
"ZIP not found" messages of `05-`, `06-`, `02b-`, `40-` name the `pull`
command when `PATCH_ARCHIVE` is set.

**Run history** – [`00-Setup/IHateWeblogic_lib.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/00-Setup/IHateWeblogic_lib.sh) (`print_summary` →
`run_history_record`) appends one row per run of every script in `09-Install`,
`07-Maintenance`, `08-SSL`, `12-APEX-Ords`, `60-RCU-DB-19c` to
`log/run_history.csv` (`IHW_RUN_HISTORY` overrides the path):
`timestamp;host;user;script;args;apply;rc;ok;warn;fail;log`. `rc` = the
OK/WARN/FAIL result of `print_summary` (a wrapper that raises its exit code
afterwards, e.g. `81-` after `05-`, is recorded with its own summary; the
delegated `05-` has its own row). Root scripts of phase 0 hand a new file to
the repository owner. The installation progress built from it:
[`09-Install/00-install-status.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/00-install-status.sh) (every step, its state, the next step).

### rcu_repository_check.sh

```bash
./07-Maintenance/rcu_repository_check.sh            # read-only checks
./07-Maintenance/rcu_repository_check.sh --apply    # + Data Pump backup
```

Connects as SYSDBA over the network (`sqlplus` of the Oracle Home, password
from `db_sys_sec.conf.des3` via stdin):

| # | Check | FAIL / WARN when |
|---|---|---|
| 1 | `db_securefile`, registry table, **all** prefixes of the DB (own one marked `*`) | `FORCE` (WARN, ORA-43853 risk), registry missing (FAIL), orphaned registry rows (WARN) |
| 2 | registry rows of `DB_SCHEMA_PREFIX`: version, status, upgraded, edition | status ≠ `VALID`; no edition with `RCU_DB_TYPE=EBR` |
| 3 | schema accounts: status, profile, expiry, editions | not `OPEN`, expiry < `RCU_EXPIRY_WARN_DAYS` (30) → FAIL; profile ≠ `RCU_DB_PROFILE` → WARN |
| 4 | data sources `config/jdbc/*-jdbc.xml`: user is a registry schema, URL = `DB_HOST/PORT/SERVICE`, login with `DB_SCHEMA_PWD` | login fails (FAIL), foreign user / URL (WARN) |
| 5 | `<prefix>_STB.COMPONENT_SCHEMA_INFO` rows = registry rows | differ (WARN) |
| 6 | invalid objects in the `<prefix>_*` schemas, grouped per owner / type, first line of `DBA_ERRORS` (since 2026-10-26) | invalid since the RCU run (last DDL ≤ user creation + 1 h) → WARN, invalidated later (patch / upgrade) → FAIL; no automatic recompile |
| 7 | `--apply`: `expdp` (Oracle Home, network) of all prefix schemas + `SYSTEM.SCHEMA_VERSION_REGISTRY$` into `DATA_PUMP_DIR` on the DB server | export fails |

The Data Pump `userid` is written to a parameter file (mode 600, removed
afterwards) – not in the process list. Exported as SYSDBA; on a production
DB a DBA may prefer an own export user. Live 2026-10-17 on the test host:
27 checks OK; export schemas 22 MB / 56 s, registry 9 rows / 16 s.

## 3. Notes

- `rcu_repository_check.sh` check 6 (invalid objects): objects invalid since
  the RCU run (IAU synonyms, `DEV_OPSS` packages) are fixed by `utlrp.sql` in
  the PDB (`catcon.pl`, see `60-RCU-DB-19c/docs/03-db_create_database.md`) –
  no MOS note needed.
- `rcu_repository_check.sh --apply`: the Data Pump parameter file with the SYS password is mode 600 and removed by a trap also on Ctrl-C / error.

## 4. Troubleshooting

### 81-/82- wrapper: FAIL "WebLogic components are still RUNNING"

```
Symptom: Script exits immediately (EXIT_CODE=2) before the delegated
         05-/06-oracle_patch_*.sh banner ever prints
Cause:   Domain not stopped (NM, a WLS server or any process from
         $ORACLE_HOME) – intentional hard gate of the wrappers.
Fix:     ./01-Run/startStop.sh stop-all --apply
         Verify: ./01-Run/startStop.sh list
         Then re-run the wrapper with --apply.
```

## 5. Open items

All scripts of this folder are live-tested on the test host (review
2026-10-19; `80-`/`81-`/`82-` `--apply` in the CPU Oct 2026 run 2026-10-24).

- Reports engines on the FMW-bundled JDK 17.0.12 (`oracle_common/jdk`,
  `80-` shows them): no Oracle patch number yet (`FMW_JDK_PATCH_NR`), SR
  prepared – root README open item.
