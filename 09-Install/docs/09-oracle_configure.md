# Step 5a – 09-oracle_configure.sh

**Script:** `09-Install/09-oracle_configure.sh`
**Runs as:** `oracle`
**Phase:** 5 – Configuration & Validation

---

## Purpose

Apply the standard configuration to a freshly created domain **before its first
start**: boot.properties, JVM settings (SecureRandom, heap per server), font OS
packages, a validation of the domain artifacts and an initial backup.

This script does **not implement new functionality** — it orchestrates existing
scripts from modules 00–07.

> **Split 2026-10-15:** the font configuration (`deploy_fonts`, font cache,
> `uifont.ali`, font path) and the `cgicmd.dat` default key moved to
> [`14b-oracle_reports_fonts.sh`](14b-oracle_reports_fonts.md). They need the
> ReportsTools component (created by `13-oracle_setup_reports.sh`) and the
> WLS_REPORTS application directory (exists only after the first start of
> WLS_REPORTS). Right after `08-` none of that exists — `uifont_ali_update.sh`
> failed with "Target directory does not exist" (confirmed 2026-10-15).

---

## Without the Script (manual)

Run the following in order after the domain is created:

### 1. Validate environment.conf

```bash
./00-Setup/init_env.sh
```

### 2. Apply JVM performance settings

```bash
./02-Checks/weblogic_performance.sh --apply
# Sets securerandom.source=file:/dev/./urandom in java.security
# Creates/updates setUserOverrides.sh with:
#   - JVM heap per server (AdminServer, WLS_FORMS, WLS_REPORTS)
#   - Log4j CVE guard (LOG4J_FORMAT_MSG_NO_LOOKUPS=true)
```

### 3. Install font OS packages

```bash
# Install OS font packages (requires root):
./04-ReportsFonts/get_root_install_libs.sh --apply
```

> Font deployment, font cache, `uifont.ali`, font path and `cgicmd.dat` follow
> later in [`14b-oracle_reports_fonts.sh`](14b-oracle_reports_fonts.md).

### 4. Take initial config backup

```bash
./07-Maintenance/backup_config.sh
```

### 5. Verify

```bash
./02-Checks/weblogic_performance.sh   # verify JVM settings
```

---

## What the Script Does

Orchestrates the configuration sequence:

| Order | Action | Script called | Doc |
|---|---|---|---|
| 0 | boot.properties | `09-Install/10-oracle_boot_properties.sh --apply` | [10-oracle_boot_properties.md](10-oracle_boot_properties.md) |
| 1 | JVM settings | `02-Checks/weblogic_performance.sh --apply` | |
| 2 | Font OS packages | `04-ReportsFonts/get_root_install_libs.sh --apply` (root/sudo) | |
| 3 | Domain validation | verify domain artifacts + `nodemanager.properties` | |
| 4 | Config backup | `07-Maintenance/backup_config.sh --apply` | |
| – | Fonts, uifont.ali, cgicmd.dat | **later:** `14b-oracle_reports_fonts.sh` | [14b-oracle_reports_fonts.md](14b-oracle_reports_fonts.md) |

> Step 2 is skipped with `--skip-fonts`.
>
> Expected on a fresh domain (not errors): `10-oracle_boot_properties.sh` warns
> that `servers/WLS_REPORTS` does not exist yet (created on first start – `10-`
> runs again in Phase 6), `weblogic_performance.sh` creates `setUserOverrides.sh`.

Each called script reports its own OK/WARN/FAIL. The orchestrator collects exit codes
and reports an overall summary.

---

## Flags

| Flag | Description |
|---|---|
| (none) | Show what would be configured |
| `--apply` | Execute all configuration steps |
| `--skip-fonts` | Skip the font OS package step |
| `--help` | Show usage |

---

## Notes

- This script is safe to re-run — all called scripts are idempotent (read-only without `--apply`)
- Font configuration (`get_root_install_libs.sh --apply`) requires sudo; the script
  checks availability and shows manual commands if sudo is not available
- The domain does not need to be running for this step — configuration files are
  written directly
