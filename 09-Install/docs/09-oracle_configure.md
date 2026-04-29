# Step 5a – 09-oracle_configure.sh

**Script:** `09-Install/09-oracle_configure.sh`
**Runs as:** `oracle`
**Phase:** 5 – Configuration & Validation

---

## Purpose

Apply the standard configuration to a freshly created domain by calling existing
scripts from modules 00–07. This step bridges the installation and the operational
state: after this script completes, the domain is ready to start.

This script does **not implement new functionality** — it orchestrates the existing
configuration scripts in the correct sequence.

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

### 3. Install and configure fonts

```bash
# Install OS font packages (requires root):
./04-ReportsFonts/get_root_install_libs.sh --apply

# Rebuild font cache:
./04-ReportsFonts/font_cache_reset.sh --apply

# Update uifont.ali:
./04-ReportsFonts/uifont_ali_update.sh --apply

# Set REPORTS_FONT_DIRECTORY in setUserOverrides.sh:
./04-ReportsFonts/fontpath_config.sh --apply
```

### 4. Configure Reports Server

Set cgicmd.dat for default report parameters:

```bash
CGICMD_DAT="$ORACLE_HOME/reports/conf/cgicmd.dat"
# Add default key for batch reports:
# default: server=repserver01 statusformat=xml
```

### 5. Take initial config backup

```bash
./07-Maintenance/backup_config.sh
```

### 6. Verify final configuration

```bash
./02-Checks/weblogic_performance.sh   # verify JVM settings
./04-ReportsFonts/font_inventory.sh   # verify fonts are visible
```

---

## What the Script Does

Orchestrates the configuration sequence:

| Order | Action | Script called | Doc |
|---|---|---|---|
| 0 | boot.properties | `09-Install/10-oracle_boot_properties.sh --apply` | [10-oracle_boot_properties.md](10-oracle_boot_properties.md) |
| 1 | Validate env | `00-Setup/init_env.sh` | |
| 2 | JVM settings | `02-Checks/weblogic_performance.sh --apply` | |
| 3 | Font OS libs | `04-ReportsFonts/get_root_install_libs.sh --apply` | |
| 4 | Font cache | `04-ReportsFonts/font_cache_reset.sh --apply` | |
| 5 | uifont.ali | `04-ReportsFonts/uifont_ali_update.sh --apply` | |
| 6 | Font path | `04-ReportsFonts/fontpath_config.sh --apply` | |
| 7 | cgicmd.dat | direct edit from `environment.conf` | |
| 8 | Node Manager | validate `nodemanager.properties` | |
| 9 | Config backup | `07-Maintenance/backup_config.sh` | |

Each called script reports its own OK/WARN/FAIL. The orchestrator collects exit codes
and reports an overall summary.

---

## Flags

| Flag | Description |
|---|---|
| (none) | Show what would be configured |
| `--apply` | Execute all configuration steps |
| `--skip-fonts` | Skip font configuration (if handled separately) |
| `--help` | Show usage |

---

## Notes

- This script is safe to re-run — all called scripts are idempotent (read-only without `--apply`)
- Font configuration (`get_root_install_libs.sh --apply`) requires sudo; the script
  checks availability and shows manual commands if sudo is not available
- The domain does not need to be running for this step — configuration files are
  written directly
