---
title: "Oracle Forms & Reports 14c – Configuration Backup and Restore"
description: "Configuration backup and restore of a running Oracle Forms & Reports 14.1.2 installation: backup_config.sh categories, restore_config.sh, bak_cleanup.sh, retention."
---

# Backup and restore of the configuration

← [07-Maintenance](../README.md) · topics: [backup / restore](01-backup_restore.md) · [patching](02-patching.md) · [security hardening](03-security_hardening.md)

## 1. Workflow

```
Before any config change (fonts, Reports/Forms server config, domain env):
  ./07-Maintenance/backup_config.sh --apply

If something breaks afterwards:
  ./07-Maintenance/restore_config.sh            # inspect available backups first
  ./07-Maintenance/restore_config.sh --apply     # select a set and restore it
```

Scripts that already call [`backup_config.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/backup_config.sh)-style backups internally before
writing (via `backup_file()` in [`00-Setup/IHateWeblogic_lib.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/00-Setup/IHateWeblogic_lib.sh)) still
benefit from a full `backup_config.sh --apply` run beforehand — it captures
a **complete, consistent snapshot** across all categories in one place,
rather than one file at a time.

## 2. Scripts

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

**Retention:** after a successful `--apply` the oldest
sets beyond N are removed – counted separately per kind:

| Kind | Name | Created by |
|---|---|---|
| config sets | `YYYYMMDD_HHMM` and `YYYYMMDD_HHMM_pre_restore` | [`backup_config.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/backup_config.sh), [`restore_config.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/restore_config.sh) |
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
| `fonts_custom` | `04-ReportsFonts/custom_fonts_dir/*.ttf/.ttc/.otf` | **Customer / licensed font originals** – source for [`deploy_fonts.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/04-ReportsFonts/deploy_fonts.sh); gitignored (licence), so this backup is their only copy besides the deployed one | customer |
| `reports_afm` | `ReportsToolsComponent/<inst>/guicommon/tk/admin/AFM/*` | AFM font metrics (files without extension) | [`paramform_afm_setup.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/04-ReportsFonts/paramform_afm_setup.sh) |
| `reports_comp` | `ReportsServerComponent/<instance>/` | `rwserver.conf`, `rwnetwork.conf` | `13-`, `05-` |
| `reports_tools` | `ReportsToolsComponent/<instance>/` | `rwnetwork.conf`, `rwbuilder.conf`, `PPD/screenprinter.ppd` | `13-`, [`paramform_afm_setup.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/04-ReportsFonts/paramform_afm_setup.sh) |
| `reports_wls` | `servers/$WLS_MANAGED_SERVER/applications/reports_*/configuration/` | `rwserver.conf` (in-process), `rwservlet.properties`, `cgicmd.dat` | `13-`, `14b-` |
| `fmw` | `$ORACLE_HOME/reports/conf/` | `cgicmd.dat` from the FMW install (separate category — same filename as the domain copy) | – |
| `forms_wls` | `servers/*/applications/formsapp_*/config/` | `formsweb.cfg`, `default.env`, `oracle/forms/registry/Registry.dat` | `14-`, `06-` |
| `forms_inst` | `components/FORMS/instances/<inst>/server/`, `components/FORMS/<inst>/server/` | `webutil.cfg` (stored as `webutil.cfg` / `webutil_alt.cfg`) | `14-` |
| `security` | `config/fmwconfig/` | `jps-config.xml`, `jps-config-jse.xml` (identity store of the Reports server) | `13-` |
| `logging` | `servers/*/logging.xml`, `components/Reports*Component/*/logging.xml` | ODL logging config (stored as `<server>_logging.xml`) | `03-Logs/setLogLevel.sh --persist` |
| `domain` | `$DOMAIN_HOME/bin/`, `config/`, `nodemanager/` | `setDomainEnv.sh`, `setUserOverrides.sh`, `config.xml`, `nodemanager.properties` | `08-`, `09-`, `11-`, [`domain_jdk_path.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/domain_jdk_path.sh) |
| `ihw` | project root | `environment.conf` | interview, [`detect_env_conf.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/00-Setup/detect_env_conf.sh) |
| `ords` | `$APEX_ORDS_BASE/ords_*/config/` (whole tree) | ORDS `pool.xml`, `global/settings.xml`, `logging.properties`, wallet `cwallet.sso` (credentials of `ORDS_PUBLIC_USER`) – stored as `<inst>__<path>` (e.g. `ords_1__databases__default__wallet__cwallet.sso`), mode 600 like the whole set; restore → restart `ords@ords_<n>`. Never copied **into** the config directory (ORDS reads every file there) | `12-APEX-Ords/04-`, `06-` |
| `wlsmon` | `$WLSMON_BASE/etc/` (default `$ORACLE_BASE/admin/wlsmon/etc`), only the files directly in it | `wlsmon.conf`, `wlsmon_rules.local.cfg` of the [runtime monitor](https://github.com/gpipperr/IHateWeblogic/blob/main/11-wlsmon/README.md). Not `etc/pending/` (clear-text secrets during the install), not `etc/creds/` (systemd credentials bound to this host – after a restore run `00-setup-interview.sh --apply` + `02-install-wlsmon_root.sh --apply`), not the `wlsmon.conf.bak_*` of `03-set-thresholds.sh`. Restore → no restart, the next round reads it | `11-wlsmon/00-`, `03-` |

**Not backed up on purpose:**

| What | Why / where instead |
|---|---|
| `*.des3` secret files | encrypted with a machine-bound key – useless on another host, re-created by [`01-setup-interview.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/01-setup-interview.sh) / the scripts that ask for them |
| own root CA `$ORACLE_BASE/admin/pki` | the CA key belongs in an **offline** backup with its passphrase ([08-SSL/README.md](../../08-SSL/README.md)), not next to the configuration |
| Nginx configuration | root-owned, written by `09-Install/04-`/`05-root_nginx*.sh` from templates |
| keystores, `boot.properties`, `security/SerializedSystemIni.dat` | domain secrets – part of a full domain / file-system backup, not of this config snapshot |
| `TNS_ADMIN` directory (`tnsnames.ora`, `sqlnet.ora`) | company files, maintained outside this library – include it in the file-system backup |

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
├── ords/             <inst>__<path> (pool.xml, settings.xml, wallet)
├── wlsmon/           wlsmon.conf, wlsmon_rules.local.cfg
└── manifest.txt      category, stored filename, original path — one line per file
```

Missing sources (component not installed, path not configured) are reported
as `WARN` and simply skipped — the backup still runs for everything that
**is** found. If nothing at all is found, the script aborts before creating
an (empty) backup directory.

`manifest.txt` is the single source of truth [`restore_config.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/restore_config.sh) uses to
find files again — do not rename or move files inside a backup directory.

**Permissions:** `umask 077` – backup directories 700, files 600 (the set
contains `rwserver.conf` with the encrypted `<identifier>`, `default.env`,
the OPSS configuration and `environment.conf`).

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
[`domain_jdk_path.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/domain_jdk_path.sh)) and are only named.

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
   Reports server / `WLS_REPORTS` / `WLS_FORMS` via [`01-Run/startStop.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/01-Run/startStop.sh),
   `start-all` after `domain`/`security`

If the destination directory for a file no longer exists (e.g. a Reports
instance was removed since the backup was taken), that file is skipped with
a `WARN` rather than failing the whole restore.

## 3. Notes

- `ConfigBackup/` is excluded from Git (`.gitignore`) — backups are server-local and may contain environment-specific paths and settings.
- Retention: `backup_config.sh --keep N` (`CONFIG_BACKUP_KEEP`, 10 sets) and `bak_cleanup.sh` (`BAK_FILES_KEEP`, 3 copies per file) – both delete only with `--apply`.

## 4. Troubleshooting

### backup_config.sh reports most categories as "not found"

```
Symptom: Nearly all BACKUP_ITEMS show "NOT FOUND" / "(not found – will be skipped)"
Cause:   DOMAIN_HOME or ORACLE_HOME in environment.conf is wrong, or the
         domain/instances haven't been created yet
Fix:     Re-run 00-Setup/detect_env_conf.sh to detect the current paths, or verify
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
