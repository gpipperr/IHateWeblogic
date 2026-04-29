# Step 5b – 10-oracle_validate.sh

**Script:** `09-Install/10-oracle_validate.sh`
**Runs as:** `oracle`
**Phase:** 5 – Configuration & Validation

---

## Purpose

Run a full validation of the completed installation by calling all existing check
scripts. Generates a single summary report that confirms the system is ready for
production use or lists any remaining issues.

This is the final step — if all checks pass, the installation is complete.

---

## Without the Script (manual)

Run each check script in sequence and review the output:

```bash
# 1. OS prerequisites
./02-Checks/os_check.sh

# 2. JDK version and JAVA_HOME
./02-Checks/java_check.sh

# 3. Port availability
./02-Checks/port_check.sh --http

# 4. JVM performance settings
./02-Checks/weblogic_performance.sh

# 5. Database connectivity
./02-Checks/db_connect_check.sh --login

# 6. SSL configuration
./02-Checks/ssl_check.sh

# 7. Start all servers, then check Reports Server
./01-Run/startStop.sh start ALL --apply
# wait for servers to start...
./01-Run/rwserver_status.sh

# 8. Engine configuration
./05-ReportsPerformance/engine_perf_settings.sh

# 9. Forms settings
./06-FormsDiag/forms_settings.sh

# 10. Config backup exists
ls -la ./07-Maintenance/ConfigBackup/
```

Review output of each and resolve any FAIL items before going live.

---

## What the Script Does

Calls all check scripts and aggregates results:

| # | Check | Script |
|---|---|---|
| 1 | OS version, RAM, disk, ulimits | `02-Checks/os_check.sh` |
| 2 | JAVA_HOME, JDK version | `02-Checks/java_check.sh` |
| 3 | Port status, HTTP response | `02-Checks/port_check.sh` |
| 4 | SecureRandom, JVM heap | `02-Checks/weblogic_performance.sh` |
| 5 | DB connectivity | `02-Checks/db_connect_check.sh` |
| 6 | SSL certificate, expiry, TLS versions | `02-Checks/ssl_check.sh` |
| 7 | Reports Server engine pool, job stats | `01-Run/rwserver_status.sh` |
| 8 | Engine pool config (min/max, heap) | `05-ReportsPerformance/engine_perf_settings.sh` |
| 9 | Forms config, FORMS_PATH | `06-FormsDiag/forms_settings.sh` |
| 10 | Config backup present | direct check |

Final summary:
- Total OK / WARN / FAIL counts
- Exit code 0 if no FAIL, exit code 1 if any FAIL
- Full log written to `$DIAG_LOG_DIR/install_validation_<YYYYMMDD>.log`

---

## Flags

| Flag | Description |
|---|---|
| (none) | Run all checks |
| `--skip-db` | Skip database connectivity check |
| `--skip-ssl` | Skip SSL check (if SSL not configured yet) |
| `--help` | Show usage |

---

## Interpretation

| Result | Meaning |
|---|---|
| All OK | System is ready for production |
| WARN only | Review warnings, may be acceptable for the environment |
| Any FAIL | Must be resolved before going live |

---

## Post-Validation

After successful validation:

1. Schedule regular runs of `07-Maintenance/backup_config.sh`
2. Set up monitoring using `MonUser` credentials
3. Test a sample report via `01-Run/rwserver_status.sh`
4. Run `04-ReportsFonts/pdf_font_verify.sh` to confirm fonts are embedded in PDF output
