# 07-Maintenance – Configuration Backup & Restore

Backup and restore Oracle Reports/Forms configuration files before and after
changes. All scripts source `environment.conf` and write output to
`$DIAG_LOG_DIR/`.

---

## 1. Overview

| Script | Status | Purpose |
|---|---|---|
| `backup_config.sh` | ✅ implemented | Back up all relevant config + font files to `ConfigBackup/<timestamp>/` |
| `restore_config.sh` | ✅ implemented | List backups, restore a selected set back to its original locations |

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

## 3. Script Reference

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

## 4. Troubleshooting

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

---

## 5. Related Scripts

| Script | Purpose |
|---|---|
| `00-Setup/IHateWeblogic_lib.sh` | `backup_file()` — single-file backup used internally by most `--apply` scripts |
| `04-ReportsFonts/uifont_ali_update.sh` | Backs up `uifont.ali` itself before rewriting; run `backup_config.sh` first for the full picture |
| `04-ReportsFonts/font_cache_reset.sh` | Run after restoring fonts, to rebuild the fontconfig cache |
| `01-Run/startStop.sh` | Restart components after a restore (or use `stopComponent.sh`/`startComponent.sh` directly) |
| `00-Setup/init_env.sh` | Re-detect paths if `backup_config.sh` reports most sources as not found |

---

## 6. Notes

- Both scripts are read-only by default; `--apply` is required for any write operation, consistent with the rest of the project.
- `ConfigBackup/` is excluded from Git (`.gitignore`) — backups are server-local and may contain environment-specific paths and settings.
- There is currently no automatic retention policy for `ConfigBackup/` — old backup sets accumulate until manually removed.
