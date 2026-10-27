# 07-Maintenance – Maintenance & Patches (Phase 8)

**Role: analyse + fix an existing environment** (see the folder roles in the
[root README](../README.md#folder-roles)): backup/restore and patching of a
running installation, no matter who built it. The patch logic itself lives
once in `09-Install/05-`/`06-` – the `81-`/`82-` wrappers call it.
Background: what OPatch changes (the Oracle Home, both JDKs) –
[weblogic_middleware_architecture.md §1](../80-FMW-Architecture/weblogic_middleware_architecture.md#1-terms--the-four-homes); what must be stopped –
[§4](../80-FMW-Architecture/weblogic_middleware_architecture.md#4-who-starts-whom--the-control-chain); RCU schemas and
patching – [rcu_middleware_architecture.md](../80-FMW-Architecture/rcu_middleware_architecture.md).

Configuration backup/restore, **and** patching an already-running,
already-installed environment (e.g. a future CPU/CSPU cycle) — as opposed
to `09-Install/`, which covers only the one-time initial install and
explicitly says "The Oracle Home is not touched again after this point."
All scripts source `environment.conf` and write output to `$DIAG_LOG_DIR/`.

> 📋 **Looking for current patch numbers?** →
> [`09-Install/docs/00-patch-references.md`](../09-Install/docs/00-patch-references.md)
> — the central MOS Doc-ID / patch-number reference, used for both initial
> install and the maintenance workflow below. This is usually the first
> thing you need once the environment is up and running.

---

## 1. Overview

| Script | Status | Purpose |
|---|---|---|
| `backup_config.sh` | ✅ implemented | Back up all relevant config + font files to `ConfigBackup/<timestamp>/` |
| `restore_config.sh` | ✅ implemented | List backups, restore a selected set back to its original locations |
| `bak_cleanup.sh` | ✅ implemented | `*.bak_<ts>` copies our scripts leave next to the Oracle files: list per file, `--apply` deletes all but the newest `BAK_FILES_KEEP` (3) |
| `80-patch_java_os.sh` | ✅ implemented | Java/OS layer — `java_check.sh`; `--apply`: JDK at `JDK_HOME` from the patch repository (`JDK_PATCH_NR`, downloaded by `04-`), domain stopped, then `domain_jdk_path.sh` check |
| `rcu_repository_check.sh` | ✅ implemented | RCU repository: registry, DB requirements of FMW 14.1.2 (version, edition, AL32UTF8, JVM, parameter minimums), schema accounts (profile/expiry), data sources (login test), service table, invalid objects; `--apply` = Data Pump export of the prefix schemas + `SYSTEM.SCHEMA_VERSION_REGISTRY$` |
| `domain_jdk_path.sh` | ✅ implemented | Domain + `oui/` pinned to `jdk-21.0.x` instead of the `JDK_HOME` symlink: list, `--apply` replaces (backup `ConfigBackup/jdk_path_<ts>/`) |
| `81-patch_weblogic.sh` | ✅ implemented | WLS FMW Basis layer — wraps `09-Install/05-oracle_patch_weblogic.sh` |
| `82-patch_forms_reports.sh` | ✅ implemented | Forms + Reports layer (combined) — wraps `09-Install/06-oracle_patch_forms_reports.sh` |

`82-patch_forms_reports.sh` covers both the Forms and the Reports
conceptual layer in a single call — see §3 below for why there is no
separate Forms-only/Reports-only script.

---

## 2. Recommended Workflow

```
Before any config change (fonts, Reports/Forms server config, domain env):
  ./07-Maintenance/backup_config.sh --apply

If something breaks afterwards:
  ./07-Maintenance/restore_config.sh            # inspect available backups first
  ./07-Maintenance/restore_config.sh --apply     # select a set and restore it
```

Scripts that already call `backup_config.sh`-style backups internally before
writing (via `backup_file()` in `00-Setup/IHateWeblogic_lib.sh`) still
benefit from a full `backup_config.sh --apply` run beforehand — it captures
a **complete, consistent snapshot** across all categories in one place,
rather than one file at a time.

---

## 3. Patching an Already-Running Environment (CPU/CSPU cycle)

> 📋 **Current patch numbers?** →
> [`09-Install/docs/00-patch-references.md`](../09-Install/docs/00-patch-references.md)

> **RCU schemas and patching:** regular patches (SPB / CSPU / Forms and
> Reports one-offs) never change the RCU schemas – only a version upgrade
> does (Upgrade Assistant). Run `rcu_repository_check.sh` before and after a
> patch cycle as a health check; before an upgrade or a move with `--apply`
> (backup). Background:
> [`80-FMW-Architecture/rcu_middleware_architecture.md`](../80-FMW-Architecture/rcu_middleware_architecture.md).

`80-`/`81-`/`82-patch_*.sh` are **thin wrappers**: they add one thing that
was previously missing — a hard check that WebLogic is actually stopped —
then delegate 100% of the real patch logic to the unchanged, already
idempotent `09-Install/05-` and `06-oracle_patch_*.sh` scripts (safe to
re-run; they skip whatever is already applied). No patch logic is
duplicated here.

```
1. Update 09-Install/oracle_software_version.conf with the new cycle's
   patch numbers — see 09-Install/docs/00-patch-references.md
2. 09-Install/04-oracle_pre_download.sh --apply --mos
   (add --fresh-patches first to archive the previous cycle's ZIPs)
3. ./07-Maintenance/backup_config.sh --apply
4. ./01-Run/startStop.sh stop-all --apply        # REQUIRED before step 5-7
   (81-/82- refuse --apply while NM, a WLS server or ANY process from
    $ORACLE_HOME runs – rwserver, Reports engines, frmweb, rwrun …;
    80- also while a JVM runs from JDK_HOME – ORDS, stopped by stop-all
    since 2026-10-24)
   Then each of 80-/81-/82- --apply pauses: "VM snapshot now?" – type ok to
   continue, anything else aborts (no terminal or IHW_NO_SNAPSHOT_PROMPT=true:
   no pause). Everything is stopped at that point, so the snapshot is
   consistent.
5. ./07-Maintenance/80-patch_java_os.sh --apply   # JDK_HOME from patches/<JDK_PATCH_NR>/ (WARN if missing)
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

**Why only 3 scripts for "4 layers"?** `06-oracle_patch_forms_reports.sh`
already auto-detects whether `$ORACLE_HOME/forms` and `$ORACLE_HOME/reports`
exist and only patches what's actually installed — there is exactly one
underlying call for both, so `82-patch_forms_reports.sh` covers the Forms
and the Reports conceptual layer together. A separate Forms-only/
Reports-only script would need a new `--only forms|reports` scope flag on
the delegated script first — not implemented (bundled on purpose, see
`09-Install/docs/06-oracle_patch_forms_reports.md`).

**Why `04-oracle_pre_download.sh` isn't called automatically by the
wrappers:** updating `oracle_software_version.conf` with the new cycle's
patch numbers (step 1) is an inherent human-judgment step (reading the new
CPU/CSPU advisory) — it has to happen before any download anyway, and
`05-`/`06-oracle_patch_*.sh` already print the exact download command
whenever a required patch ZIP is missing.

**Java/OS layer (step 5):** since October 2026 JDK 21 updates exist only
on MOS (Patch 35702194 – the NFTC for JDK 21 ended in September 2026). The
patch is downloaded **once**, with all other patches, by
`04-oracle_pre_download.sh --apply --mos`; `80-patch_java_os.sh --apply` only
looks into `$PATCH_STORAGE/patches/<JDK_PATCH_NR>/` – missing or not newer →
WARN / OK, no download. Details: [01-root_setup_java.md](../09-Install/docs/01-root_setup_java.md#patch-cycle-minimum-and-upgrade---upgrade-jdk).
The FMW-bundled JDK (`oracle_common/jdk`, OPatch component `oracle.jdk`)
is patched with OPatch (`FMW_JDK_PATCH_NR`, still to be determined).

### domain_jdk_path.sh

```bash
./07-Maintenance/domain_jdk_path.sh            # read-only: files with jdk-21.0.x
./07-Maintenance/domain_jdk_path.sh --apply    # replace with JDK_HOME, then restart
```

WLST `createDomain` / `updateDomain` (and the Config Wizard) resolve the
`JDK_HOME` symlink and write the versioned JDK directory into
`setDomainEnv.sh`, `setNMJavaHome.sh`, `nodemanager.properties`, the Forms
instance scripts and `init-info/*`; the installer into
`$ORACLE_HOME/oui/.globalEnv.properties` and `oui/bin/*.sh`. A JDK upgrade
that only repoints the symlink would not reach WebLogic. Matches `JDK_HOME`
followed by a version suffix and the current symlink target; skips logs,
`servers/` and backups. Backup: `ConfigBackup/jdk_path_<ts>/` with the original
paths below it. Called by `09-Install/08-oracle_setup_domain.sh`; run it
after every JDK upgrade and every `updateDomain`.

---

## 4. Script Reference

### backup_config.sh

```bash
./07-Maintenance/backup_config.sh              # dry-run: show what would be backed up
./07-Maintenance/backup_config.sh --apply      # create the backup
./07-Maintenance/backup_config.sh --apply --keep 5   # create, then keep only the 5 newest sets
```

Options:

| Option | Description |
|---|---|
| `--apply` | Create `ConfigBackup/<timestamp>/` and copy all discovered files (default: dry-run) |
| `--keep N` | Retention: keep the N newest sets, default `CONFIG_BACKUP_KEEP` from `environment.conf` (10) |
| `--help` | Show usage |

**Retention** (since 2026-10-23): after a successful `--apply` the oldest
sets beyond N are removed – counted separately per kind:

| Kind | Name | Created by |
|---|---|---|
| config sets | `YYYYMMDD_HHMM` and `YYYYMMDD_HHMM_pre_restore` | `backup_config.sh`, `restore_config.sh` |
| JDK path sets | `jdk_path_YYYYMMDD_HHMMSS` | `domain_jdk_path.sh --apply` |

The dry-run lists the sets that the next `--apply` would remove (the new set
counts). Only directories directly under `ConfigBackup/` that match one of
the names are removed; the newest set of each kind is never removed
(`N >= 1`); other directories are left alone.

**What it discovers and backs up** — all paths are located dynamically via
`find` (they contain version numbers and instance names that vary per
install), not hardcoded:

| Category | Source | Content | Written by |
|---|---|---|---|
| `fonts` | `$UIFONT_ALI` | Oracle Reports font alias file (`uifont.ali`) | `04-`, `14b-` |
| `fonts_ttf` | `$REPORTS_FONT_DIR/*.ttf/.ttc/.otf` (any case) | Deployed TrueType/OpenType font files (system + customer fonts as deployed) | `04-`, `14b-` |
| `fonts_custom` | `04-ReportsFonts/custom_fonts_dir/*.ttf/.ttc/.otf` | **Customer / licensed font originals** – source for `deploy_fonts.sh`; gitignored (licence), so this backup is their only copy besides the deployed one | customer |
| `reports_afm` | `ReportsToolsComponent/<inst>/guicommon/tk/admin/AFM/*` | AFM font metrics (files without extension) | `paramform_afm_setup.sh` |
| `reports_comp` | `ReportsServerComponent/<instance>/` | `rwserver.conf`, `rwnetwork.conf` | `13-`, `05-` |
| `reports_tools` | `ReportsToolsComponent/<instance>/` | `rwnetwork.conf`, `rwbuilder.conf`, `PPD/screenprinter.ppd` | `13-`, `paramform_afm_setup.sh` |
| `reports_wls` | `servers/$WLS_MANAGED_SERVER/applications/reports_*/configuration/` | `rwserver.conf` (in-process), `rwservlet.properties`, `cgicmd.dat` | `13-`, `14b-` |
| `fmw` | `$ORACLE_HOME/reports/conf/` | `cgicmd.dat` from the FMW install (separate category — same filename as the domain copy) | – |
| `forms_wls` | `servers/*/applications/formsapp_*/config/` | `formsweb.cfg`, `default.env`, `oracle/forms/registry/Registry.dat` | `14-`, `06-` |
| `forms_inst` | `components/FORMS/instances/<inst>/server/`, `components/FORMS/<inst>/server/` | `webutil.cfg` (stored as `webutil.cfg` / `webutil_alt.cfg`) | `14-` |
| `security` | `config/fmwconfig/` | `jps-config.xml`, `jps-config-jse.xml` (identity store of the Reports server) | `13-` |
| `logging` | `servers/*/logging.xml`, `components/Reports*Component/*/logging.xml` | ODL logging config (stored as `<server>_logging.xml`) | `03-Logs/setLogLevel.sh --persist` |
| `domain` | `$DOMAIN_HOME/bin/`, `config/`, `nodemanager/` | `setDomainEnv.sh`, `setUserOverrides.sh`, `config.xml`, `nodemanager.properties` | `08-`, `09-`, `11-`, `domain_jdk_path.sh` |
| `ihw` | project root | `environment.conf` | interview, `init_env.sh` |

Extended 2026-10-19: before, customer font originals, `.ttc` files, `webutil.cfg`, `Registry.dat`, the OPSS files,
`config.xml`, `nodemanager.properties`, `logging.xml`, `rwbuilder.conf` and
the screen-printer PPD/AFM were not backed up although our own scripts
change them.

**Not backed up on purpose:**

| What | Why / where instead |
|---|---|
| `*.des3` secret files | encrypted with a machine-bound key – useless on another host, re-created by `01-setup-interview.sh` / the scripts that ask for them |
| own root CA `$ORACLE_BASE/admin/pki` | the CA key belongs in an **offline** backup with its passphrase ([08-SSL/README.md](../08-SSL/README.md)), not next to the configuration |
| Nginx configuration | root-owned, written by `09-Install/04-`/`05-root_nginx*.sh` from templates |
| keystores, `boot.properties`, `security/SerializedSystemIni.dat` | domain secrets – part of a full domain / file-system backup, not of this config snapshot |

**Output structure:**

```
07-Maintenance/ConfigBackup/YYYYMMDD_HHMM/
├── fonts/            uifont.ali
├── fonts_ttf/        *.ttf / *.ttc / *.otf (deployed)
├── fonts_custom/     customer font originals (custom_fonts_dir)
├── reports_afm/      AFM metric files
├── reports_comp/     rwserver.conf, rwnetwork.conf
├── reports_tools/    rwnetwork.conf, rwbuilder.conf, screenprinter.ppd
├── reports_wls/      rwserver.conf, rwservlet.properties, cgicmd.dat
├── fmw/              cgicmd.dat (FMW install copy)
├── forms_wls/        formsweb.cfg, default.env, Registry.dat
├── forms_inst/       webutil.cfg, webutil_alt.cfg
├── security/         jps-config.xml, jps-config-jse.xml
├── logging/          <server>_logging.xml
├── domain/           setDomainEnv.sh, setUserOverrides.sh, config.xml, nodemanager.properties
├── ihw/              environment.conf
└── manifest.txt      category, stored filename, original path — one line per file
```

Missing sources (component not installed, path not configured) are reported
as `WARN` and simply skipped — the backup still runs for everything that
**is** found. If nothing at all is found, the script aborts before creating
an (empty) backup directory.

`manifest.txt` is the single source of truth `restore_config.sh` uses to
find files again — do not rename or move files inside a backup directory.

**Permissions:** `umask 077` – backup directories 700, files 600 (the set
contains `rwserver.conf` with the encrypted `<identifier>`, `default.env`,
the OPSS configuration and `environment.conf`). Sets created before
2026-10-19 are 755/644 – tighten them once:
`chmod -R go-rwx 07-Maintenance/ConfigBackup`.

---

### bak_cleanup.sh

```bash
./07-Maintenance/bak_cleanup.sh                  # list the copies per file (read-only)
./07-Maintenance/bak_cleanup.sh --apply          # delete all but the newest 3 per file
./07-Maintenance/bak_cleanup.sh --apply --keep 1
```

Our `--apply` scripts back up a file before they change it as
`<file>.bak_<YYYYMMDD_HHMM[SS]>` in the same directory (`backup_file` in the
lib, `13-`, `14-` …). After some runs there are many of them next to the
Oracle files (live 2026-10-23: about 100, ten copies each of `default.env`,
`Registry.dat`, `fmrweb_utf8.res`), and some hold secrets (`rwserver.conf`
right after `13-` has the Reports admin `<identifier>` in clear text until the
server encrypts it at its next start).

| Option | Description |
|---|---|
| `--apply` | delete the copies beyond `--keep` (default: list only) |
| `--keep N` | copies kept per original file, newest first; default `BAK_FILES_KEEP` from `environment.conf` (3), `N >= 1` |

**Searched:** `$DOMAIN_HOME`, `$ORACLE_HOME/forms/java` and
`$ORACLE_HOME/reports/conf` (not the whole Oracle Home), `$ORACLE_BASE/admin`,
`$ORACLE_BASE/reports` and `$ORACLE_BASE/forms` (report / form modules deployed by `15-`),
the project root and `00-Setup/environments/` (backups of `environment.conf`),
the oracle home directory (top level) – files only, one file system (`-xdev`).

**Never deleted, only reported:**

| What | Why |
|---|---|
| directories (`OPatch.bak_*`, inventory copies) | rollback of `09-Install/05-` – remove by hand after a successful patch |
| `*.des3.bak_*` | copies of secret files – check by hand which key/password they hold |
| files of another owner | root copies (`/etc/*.bak_*` of `01-` / `02b-`, Nginx) are not searched at all |

The copies are grouped per original file and sorted by the timestamp in the
name; the table shows copies / kept / removed and the size per file.
`ConfigBackup/` is not touched (see `backup_config.sh --keep`).

---

### restore_config.sh

```bash
./07-Maintenance/restore_config.sh             # list backups + show all manifests (read-only)
./07-Maintenance/restore_config.sh --apply     # interactively select and restore one
./07-Maintenance/restore_config.sh --apply --category forms_wls,forms_inst   # only these
```

Options:

| Option | Description |
|---|---|
| `--apply` | Interactively select a backup set and restore it (default: list only) |
| `--category LIST` | Only these categories (comma separated) – recommended; a full restore also brings back an older `environment.conf` and `config.xml` |
| `--help` | Show usage |

**Without `--apply`:** lists every backup set under `ConfigBackup/` that has
a `manifest.txt` (newest first) with its file count, then prints the full
`manifest.txt` of each — read-only, nothing is touched. Directories without
a manifest come from single scripts (e.g. `jdk_path_<ts>/` of
`domain_jdk_path.sh`) and are only named.

**With `--apply`:**

1. Shows a numbered selection menu, newest first (skipped automatically if only one backup exists)
2. Prints the manifest of the selected backup for a final visual check
   - only destinations below `DOMAIN_HOME`, `ORACLE_HOME`, the repository or
     `REPORTS_FONT_DIR` are accepted – the manifest is a text file, other
     paths (or `..`) are skipped with a WARN
   - categories `domain` / `security` are refused while WebLogic or any
     process from `$ORACLE_HOME` runs (`check_wls_stopped`); `ihw` warns that
     newer `environment.conf` variables are lost
3. **Creates a pre-restore backup of the current state first** — every file
   that is about to be overwritten is saved to a new
   `ConfigBackup/<timestamp>_pre_restore/` set (with its own manifest), so a
   bad restore can itself be undone
4. Prompts for confirmation (`askYesNo`, default **no**) before overwriting anything
5. Copies each file from the backup back to its original path
6. Prints next steps per restored category: font cache, restart of the
   Reports server / `WLS_REPORTS` / `WLS_FORMS` via `01-Run/startStop.sh`,
   `start-all` after `domain`/`security`

If the destination directory for a file no longer exists (e.g. a Reports
instance was removed since the backup was taken), that file is skipped with
a `WARN` rather than failing the whole restore.

---

### 80-patch_java_os.sh

```bash
./07-Maintenance/80-patch_java_os.sh            # read-only: java_check.sh + JDK in the patch repository?
./07-Maintenance/80-patch_java_os.sh --apply    # upgrade JDK_HOME from the patch repository
```

| Option | Description |
|---|---|
| `--apply` | domain must be stopped (`require_wls_stopped`); calls `09-Install/02b-root_os_java.sh --apply --upgrade-jdk` (sudo inside), then `domain_jdk_path.sh` (read-only check) and `java_check.sh` |
| `--help` | Show usage |

Without `--apply`: `java_check.sh` plus `02b- --upgrade-jdk` as dry-run –
which JDK is in the repository, would it be installed. Rollback:
`ln -sfn <old jdk dir> $JDK_HOME` (old directory is kept).

### 81-patch_weblogic.sh

```bash
./07-Maintenance/81-patch_weblogic.sh                # dry-run
./07-Maintenance/81-patch_weblogic.sh --check-only    # conflict check only
./07-Maintenance/81-patch_weblogic.sh --apply         # patch (requires WLS stopped)
```

Options: same as `09-Install/05-oracle_patch_weblogic.sh` (`--apply`,
`--check-only`, `--help`) — forwarded verbatim, no translation.

Delegates to: `09-Install/05-oracle_patch_weblogic.sh` (unchanged — OPatch
upgrade, WLS Stack Patch Bundle, `INSTALL_PATCHES` loop). New code: the
`require_wls_stopped()` hard gate before `--apply` runs (not implemented
anywhere before this wrapper — neither the delegated script nor OPatch
itself actually enforces this).

### 82-patch_forms_reports.sh

```bash
./07-Maintenance/82-patch_forms_reports.sh                # dry-run
./07-Maintenance/82-patch_forms_reports.sh --check-only    # conflict check only
./07-Maintenance/82-patch_forms_reports.sh --apply          # patch (requires WLS stopped)
```

Options: same as `09-Install/06-oracle_patch_forms_reports.sh` — forwarded
verbatim.

Delegates to: `09-Install/06-oracle_patch_forms_reports.sh` (unchanged —
auto-detects Forms/Reports, superseded-QPR rollback, `check_patch_zip()`
validation). New code: same `require_wls_stopped()` hard gate as `81-`.

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

---

## 5. Troubleshooting

### backup_config.sh reports most categories as "not found"

```
Symptom: Nearly all BACKUP_ITEMS show "NOT FOUND" / "(not found – will be skipped)"
Cause:   DOMAIN_HOME or ORACLE_HOME in environment.conf is wrong, or the
         domain/instances haven't been created yet
Fix:     Re-run 00-Setup/init_env.sh to detect the current paths, or verify
         DOMAIN_HOME manually: ls $DOMAIN_HOME/config/fmwconfig/components/
```

### restore_config.sh: "manifest.txt not found"

```
Symptom: FAIL manifest.txt not found in <backup dir>
Cause:   The backup directory is incomplete (interrupted backup_config.sh run,
         or manifest.txt was manually deleted/moved)
Fix:     Choose a different, complete backup set. Do not restore from a
         backup directory with a missing or edited manifest.txt.
```

### restore_config.sh: file restored but Reports Server still shows old behavior

```
Symptom: uifont.ali / rwserver.conf restored, but server behaves unchanged
Cause:   Reports Server / WLS_FORMS JVM caches config at startup; a restored
         file only takes effect after a restart
Fix:     ./01-Run/startStop.sh stop  repserver01 --apply   (Reports server component)
         ./01-Run/startStop.sh start repserver01 --apply
         WLS_FORMS / WLS_REPORTS the same way; restore_config.sh prints the
         commands for the restored categories.
         For fonts, also run: ./04-ReportsFonts/font_cache_reset.sh --apply
```

### Backup directory grows large over time

```
Symptom: 07-Maintenance/ConfigBackup/ contains many timestamped directories,
         or many *.bak_<ts> files next to the Oracle configuration files
Cause:   every --apply run creates a new set / copy
Fix:     ./07-Maintenance/backup_config.sh --apply --keep 10   (sets)
         ./07-Maintenance/bak_cleanup.sh --apply               (*.bak_<ts> copies)
         Defaults: CONFIG_BACKUP_KEEP / BAK_FILES_KEEP in environment.conf.
```

### 81-/82- wrapper: FAIL "WebLogic components are still RUNNING"

```
Symptom: Script exits immediately (EXIT_CODE=2) before the delegated
         05-/06-oracle_patch_*.sh banner ever prints
Cause:   Domain not stopped — new, intentional hard gate. Previously
         neither 05- nor 06-oracle_patch_*.sh checked this at all.
Fix:     ./01-Run/startStop.sh stop-all --apply
         Verify: ./01-Run/startStop.sh list
         Then re-run the wrapper with --apply.
```

---

## 6. Related Scripts

| Script | Purpose |
|---|---|
| `00-Setup/IHateWeblogic_lib.sh` | `backup_file()` — single-file backup used internally by most `--apply` scripts; `check_wls_stopped()`/`require_wls_stopped()` — used by `80-`/`81-`/`82-` |
| `04-ReportsFonts/uifont_ali_update.sh` | Backs up `uifont.ali` itself before rewriting; run `backup_config.sh` first for the full picture |
| `04-ReportsFonts/font_cache_reset.sh` | Run after restoring fonts, to rebuild the fontconfig cache |
| `01-Run/startStop.sh` | Stop/start the domain before and after maintenance patching (`stop-all --apply` / `start-all --apply`); also restart components after a restore |
| `00-Setup/init_env.sh` | Re-detect paths if `backup_config.sh` reports most sources as not found |
| `09-Install/04-oracle_pre_download.sh` | Download new patch ZIPs for a CPU/CSPU cycle before running `81-`/`82-` |
| `09-Install/05-oracle_patch_weblogic.sh` | Delegated to by `81-patch_weblogic.sh` |
| `09-Install/06-oracle_patch_forms_reports.sh` | Delegated to by `82-patch_forms_reports.sh` |
| `02-Checks/java_check.sh` | Delegated to by `80-patch_java_os.sh` |
| `09-Install/docs/00-patch-references.md` | Central MOS Doc-ID / patch-number reference for a new cycle |

---

## 7. Notes

- All scripts are read-only by default; `--apply` is required for any write operation, consistent with the rest of the project.
- `ConfigBackup/` is excluded from Git (`.gitignore`) — backups are server-local and may contain environment-specific paths and settings.
- Retention: `backup_config.sh --keep N` (`CONFIG_BACKUP_KEEP`, 10 sets) and `bak_cleanup.sh` (`BAK_FILES_KEEP`, 3 copies per file) – both delete only with `--apply`.
- `rcu_repository_check.sh`: new check 6 "invalid objects" (2026-10-26) – the
  test host shows 69 objects invalid since the RCU 14.1.2 EBR run (62 IAU
  synonyms, `DEV_OPSS` packages / triggers – `OPSS_SYNCHRONIZATION` ORA-00942,
  `DEV_UMS.DRIVERPROPERTIES`); not caused by the CPU Oct 2026 patch run.
- `rcu_repository_check.sh --apply`: the Data Pump parameter file with the SYS password is mode 600 and removed by a trap also on Ctrl-C / error (2026-10-19).

## 8. Review 2026-10-19

Live on the test host: `backup_config.sh` (dry-run + `--apply`: 27 files,
55 TTF, 77 AFM), `restore_config.sh` (`--category logging` restored
unchanged files, `--category domain` refused while the domain runs, a
manifest pointing to `/tmp` or `…/../` skipped), `domain_jdk_path.sh`,
`80-` (dry), `81-`/`82-` (dry-run, `require_wls_stopped` now lists
`rwserver`, Reports engines and `frmweb`), `rcu_repository_check.sh`
(27 checks OK).

Open:
- ~~retention for `ConfigBackup/`~~ and ~~`*.bak_<ts>` copies~~ – done
  2026-10-23 (`backup_config.sh --keep`, `bak_cleanup.sh`)
- JDK upgrade automation (`80-` read-only, see above)
- Reports engines on the FMW-bundled JDK 17.0.12 (`80-` shows them – root README open item)
