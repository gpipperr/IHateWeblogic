---
title: "Oracle Forms & Reports 14c Maintenance – Backup, Patching, Security Hardening"
description: "Maintenance of a running Oracle Forms & Reports 14.1.2 installation: configuration backup and restore, patching per CPU / CSPU cycle, security hardening of the WebLogic realm – overview of the scripts and topic documents."
permalink: /07-Maintenance/
---

# 07-Maintenance – Maintenance, Patches, Hardening (Phase 8)

**Role: analyse + fix an existing environment** (see the folder roles in the
[root README](../docs/forms_reports_installation_steps.md#folder-roles)):
backup / restore, patching and hardening of a running installation, no
matter who built it. The patch logic itself lives once in `09-Install/05-` /
`06-` – the `81-` / `82-` wrappers call it. All scripts source
`environment.conf`, are read-only by default and write only with `--apply`;
output to `$DIAG_LOG_DIR/`.

> 📋 **Current patch numbers?** →
> [`09-Install/docs/00-patch-references.md`](../09-Install/docs/00-patch-references.md).
> **Every security topic** (patch cycle, hardening by layer, checks) →
> [security_overview.md](../80-FMW-Architecture/security_overview.md).
> Certificates, keys and trust stores →
> [certificates_trust_stores.md](../80-FMW-Architecture/certificates_trust_stores.md).

## 1. Topics

| Topic | Document | Scripts | When |
|---|---|---|---|
| Backup / restore | [docs/01-backup_restore.md](docs/01-backup_restore.md) | `backup_config.sh`, `restore_config.sh`, `bak_cleanup.sh` | before every configuration change; after a failed change; housekeeping of `*.bak_<ts>` copies |
| Patching | [docs/02-patching.md](docs/02-patching.md) | `80-patch_java_os.sh`, `81-patch_weblogic.sh`, `82-patch_forms_reports.sh`, `domain_jdk_path.sh`, `patch_storage.sh`, `rcu_repository_check.sh` | every CPU / CSPU cycle (monthly), JDK update, small disk with a patch archive |
| Security hardening | [docs/03-security_hardening.md](docs/03-security_hardening.md) | `wls_audit_config.sh`, `wls_password_rule.sh`, `wls_lockout_config.sh` | once per domain (DISA STIG: audit, password rule, lockout); `--unlock USER` in operation |
| Customer import | [09-Install/docs/17-customer_conf_import.md](../09-Install/docs/17-customer_conf_import.md) | `apply_customer_conf.sh` | applying a customer's configuration to a library environment (14c move, way 2) |

## 2. Scripts

| Script | Purpose | Details |
|---|---|---|
| [`backup_config.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/backup_config.sh) | back up all relevant config + font files to `ConfigBackup/<timestamp>/` (categories, `--keep N`) | [backup](docs/01-backup_restore.md#backup_configsh) |
| [`restore_config.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/restore_config.sh) | list backups, restore a set or `--category` (pre-restore backup first) | [backup](docs/01-backup_restore.md#restore_configsh) |
| [`bak_cleanup.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/bak_cleanup.sh) | `*.bak_<ts>` copies next to the Oracle files: keep the newest `BAK_FILES_KEEP` (3) per file | [backup](docs/01-backup_restore.md#bak_cleanupsh) |
| [`80-patch_java_os.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/80-patch_java_os.sh) | Java / OS layer: JDK at `JDK_HOME` from the patch repository, domain stopped | [patching](docs/02-patching.md#80-patch_java_ossh) |
| [`81-patch_weblogic.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/81-patch_weblogic.sh) | WebLogic layer – wraps `09-Install/05-oracle_patch_weblogic.sh` + stop gate | [patching](docs/02-patching.md#81-patch_weblogicsh) |
| [`82-patch_forms_reports.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/82-patch_forms_reports.sh) | Forms + Reports layer – wraps `09-Install/06-oracle_patch_forms_reports.sh` + stop gate | [patching](docs/02-patching.md#82-patch_forms_reportssh) |
| [`domain_jdk_path.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/domain_jdk_path.sh) | domain + `oui/` + `bin/` pinned to `jdk-21.0.x` → `JDK_HOME` symlink | [patching](docs/02-patching.md#domain_jdk_pathsh) |
| [`patch_storage.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/patch_storage.sh) | local `PATCH_STORAGE` as working copy of a patch archive: `status`, `pull <step>`, `clean`, run history | [patching](docs/02-patching.md#patch_storagesh) |
| [`rcu_repository_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/rcu_repository_check.sh) | RCU repository health (registry, accounts, data sources, invalid objects); `--apply` = Data Pump backup | [patching](docs/02-patching.md#rcu_repository_checksh) |
| [`wls_audit_config.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/wls_audit_config.sh) | audit trail: configuration audit `logaudit`, `IHW_DefaultAuditor`, OPSS `filterPreset` | [hardening](docs/03-security_hardening.md#wls_audit_configsh) |
| [`wls_password_rule.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/wls_password_rule.sh) | password rule of the realm: 12 characters, upper + lower + digit + special, no user name | [hardening](docs/03-security_hardening.md#wls_password_rulesh) |
| [`wls_lockout_config.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/wls_lockout_config.sh) | account lockout 3 / 30 / 15, lockout runtime + events, `--unlock USER` | [hardening](docs/03-security_hardening.md#wls_lockout_configsh) |
| [`apply_customer_conf.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/apply_customer_conf.sh) | customer overlay on an existing library environment: `14b-` / `14-` / `13-` / `30-`, restart, `15-` / `90-` | [doc 17](../09-Install/docs/17-customer_conf_import.md) |

## 3. Quick start

```
Before any configuration change (fonts, Reports / Forms config, domain env):
  ./07-Maintenance/backup_config.sh --apply
  ... change ...      if it breaks: ./07-Maintenance/restore_config.sh --apply

Patch cycle (monthly): the 10 steps of docs/02-patching.md §1
  download (04- --mos) -> backup -> stop-all -> 80- / 81- / 82- --apply
  -> 14- (Forms) -> start-all -> smoke test 15- + checks

Hardening of a domain (once, test host first): docs/03-security_hardening.md
  wls_audit_config.sh --apply -> restart
  wls_password_rule.sh --apply
  wls_lockout_config.sh --apply -> restart
  check: ./02-Checks/domain_secret_check.sh
```

## 4. Related scripts

| Script | Purpose |
|---|---|
| `00-Setup/IHateWeblogic_lib.sh` | `backup_file()` — single-file backup used internally by most `--apply` scripts; `check_wls_stopped()`/`require_wls_stopped()` — used by `80-`/`81-`/`82-` |
| `04-ReportsFonts/uifont_ali_update.sh` | Backs up `uifont.ali` itself before rewriting; run `backup_config.sh` first for the full picture |
| `04-ReportsFonts/font_cache_reset.sh` | Run after restoring fonts, to rebuild the fontconfig cache |
| `01-Run/startStop.sh` | Stop/start the domain before and after maintenance patching (`stop-all --apply` / `start-all --apply`); also restart components after a restore |
| `00-Setup/detect_env_conf.sh` | Re-detect paths if `backup_config.sh` reports most sources as not found |
| `09-Install/04-oracle_pre_download.sh` | Download new patch ZIPs for a CPU/CSPU cycle before running `81-`/`82-` |
| `09-Install/05-oracle_patch_weblogic.sh` | Delegated to by `81-patch_weblogic.sh` |
| `09-Install/06-oracle_patch_forms_reports.sh` | Delegated to by `82-patch_forms_reports.sh` |
| `02-Checks/java_check.sh` | Delegated to by `80-patch_java_os.sh` |
| `09-Install/docs/00-patch-references.md` | Central MOS Doc-ID / patch-number reference for a new cycle |

## 5. Notes

- `ConfigBackup/` is excluded from Git (`.gitignore`) – backups are
  server-local and may contain environment-specific paths and settings.
- Open items of this folder: [docs/02-patching.md §5](docs/02-patching.md#5-open-items),
  security: [TODO.md](https://github.com/gpipperr/IHateWeblogic/blob/main/TODO.md) block "Security hardening".
