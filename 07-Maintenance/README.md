# 07-Maintenance – Maintenance & Patches (Phase 8)

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
| `80-patch_java_os.sh` | ✅ implemented | Java/OS layer — read-only check + manual upgrade checklist |
| `rcu_repository_check.sh` | ✅ implemented | RCU repository: registry, schema accounts (profile/expiry), data sources (login test), service table; `--apply` = Data Pump export of the prefix schemas + `SYSTEM.SCHEMA_VERSION_REGISTRY$` |
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
5. ./07-Maintenance/80-patch_java_os.sh           # Java/OS layer (read-only)
6. ./07-Maintenance/81-patch_weblogic.sh --apply  # WLS FMW Basis layer
7. ./07-Maintenance/82-patch_forms_reports.sh --apply   # Forms + Reports layer
8. Forms only: ./09-Install/14-oracle_setup_forms.sh --apply
   (a Forms patch can reset extensions.jnlp / formsweb.cfg – re-activates the
   signed jacob.jar, re-signs a jacob.jar replaced by a new JACOB version)
9. ./01-Run/startStop.sh start-all --apply
10. ./02-Checks/java_check.sh / ./01-Run/rwserver_status.sh   # verify
    ./08-SSL/ssl_local_ca.sh status   # own root CA: certificate expiry
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

**Java/OS layer (step 5) is intentionally read-only in this version** —
`80-patch_java_os.sh` runs `02-Checks/java_check.sh` and prints a manual
JDK-upgrade checklist, but does not call `09-Install/02b-root_os_java.sh`
automatically yet. That script's behavior when installing a newer JDK
*alongside* an already-provisioned host (rather than a fresh one) is not
yet verified — see the script's own header comment for the three open
questions that need confirming on a disposable host first.

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
```

Options:

| Option | Description |
|---|---|
| `--apply` | Create `ConfigBackup/<timestamp>/` and copy all discovered files (default: dry-run) |
| `--help` | Show usage |

**What it discovers and backs up** — all paths are located dynamically via
`find` (they contain version numbers and instance names that vary per
install), not hardcoded:

| Category | Source | Content |
|---|---|---|
| `fonts` | `$UIFONT_ALI` | Oracle Reports font alias file (`uifont.ali`) |
| `fonts_ttf` | `$REPORTS_FONT_DIR/*.ttf/.TTF/.otf` | Deployed TrueType/OpenType font files |
| `reports_comp` | `ReportsServerComponent/<instance>/` | `rwserver.conf`, `rwnetwork.conf` |
| `reports_tools` | `ReportsToolsComponent/<instance>/` | `rwnetwork.conf` |
| `reports_wls` | `servers/$WLS_MANAGED_SERVER/applications/reports_*/configuration/` | `rwserver.conf` (in-process), `rwservlet.properties`, `cgicmd.dat` |
| `fmw` | `$ORACLE_HOME/reports/conf/` | `cgicmd.dat` from the FMW install (separate category — same filename as the domain copy) |
| `forms_wls` | `servers/*/applications/forms_*/config/` | `formsweb.cfg`, `default.env` |
| `domain` | `$DOMAIN_HOME/bin/` | `setDomainEnv.sh`, `setUserOverrides.sh` |
| `ihw` | project root | `environment.conf` |

**Output structure:**

```
07-Maintenance/ConfigBackup/YYYYMMDD_HHMM/
├── fonts/            uifont.ali
├── fonts_ttf/        *.ttf / *.TTF / *.otf
├── reports_comp/     rwserver.conf, rwnetwork.conf
├── reports_tools/    rwnetwork.conf
├── reports_wls/      rwserver.conf, rwservlet.properties, cgicmd.dat
├── fmw/              cgicmd.dat (FMW install copy)
├── forms_wls/        formsweb.cfg, default.env
├── domain/           setDomainEnv.sh, setUserOverrides.sh
├── ihw/              environment.conf
└── manifest.txt      category, filename, original path — one line per file
```

Missing sources (component not installed, path not configured) are reported
as `WARN` and simply skipped — the backup still runs for everything that
**is** found. If nothing at all is found, the script aborts before creating
an (empty) backup directory.

`manifest.txt` is the single source of truth `restore_config.sh` uses to
find files again — do not rename or move files inside a backup directory.

---

### restore_config.sh

```bash
./07-Maintenance/restore_config.sh             # list backups + show all manifests (read-only)
./07-Maintenance/restore_config.sh --apply     # interactively select and restore one
```

Options:

| Option | Description |
|---|---|
| `--apply` | Interactively select a backup set and restore it (default: list only) |
| `--help` | Show usage |

**Without `--apply`:** lists every backup directory under `ConfigBackup/`
with its file count, then prints the full `manifest.txt` contents of each —
read-only, nothing is touched.

**With `--apply`:**

1. Shows a numbered selection menu (skipped automatically if only one backup exists)
2. Prints the manifest of the selected backup for a final visual check
3. **Creates a pre-restore backup of the current state first** — every file
   that is about to be overwritten is saved to a new
   `ConfigBackup/<timestamp>_pre_restore/` set (with its own manifest), so a
   bad restore can itself be undone
4. Prompts for confirmation (`askYesNo`, default **no**) before overwriting anything
5. Copies each file from the backup back to its original path
6. Prints next steps: rebuild the font cache, restart the Reports Server

If the destination directory for a file no longer exists (e.g. a Reports
instance was removed since the backup was taken), that file is skipped with
a `WARN` rather than failing the whole restore.

---

### 80-patch_java_os.sh

```bash
./07-Maintenance/80-patch_java_os.sh    # read-only: java_check.sh + upgrade checklist
```

Options:

| Option | Description |
|---|---|
| `--help` | Show usage |

No `--apply` flag in this version — it is read-only by design (runs
`02-Checks/java_check.sh` unchanged, then prints a manual JDK-upgrade
checklist). Delegates to: `02-Checks/java_check.sh`. New code: the
soft `check_wls_stopped()` pre-check only.

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
| 6 | `--apply`: `expdp` (Oracle Home, network) of all prefix schemas + `SYSTEM.SCHEMA_VERSION_REGISTRY$` into `DATA_PUMP_DIR` on the DB server | export fails |

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
Fix:     $DOMAIN_HOME/bin/stopComponent.sh  <server_name>
         $DOMAIN_HOME/bin/startComponent.sh <server_name>
         For fonts, also run: ./04-ReportsFonts/font_cache_reset.sh --apply
```

### Backup directory grows large over time

```
Symptom: 07-Maintenance/ConfigBackup/ contains many timestamped directories
Cause:   No automatic retention/cleanup exists for this category (unlike
         03-Logs/archive_logs.sh and cleanLogFiles.sh for logs)
Fix:     Manually remove old backup sets you no longer need:
           rm -rf 07-Maintenance/ConfigBackup/20260101_0900
         Keep at least the most recent known-good set before deleting others.
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

- Both scripts are read-only by default; `--apply` is required for any write operation, consistent with the rest of the project.
- `ConfigBackup/` is excluded from Git (`.gitignore`) — backups are server-local and may contain environment-specific paths and settings.
- There is currently no automatic retention policy for `ConfigBackup/` — old backup sets accumulate until manually removed.
