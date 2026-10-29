# Step 90 – 90-oracle_validate.sh

**Script:** `09-Install/90-oracle_validate.sh` *(planned)*
**Runs as:** `oracle`
**Phase:** 7 – Validation

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
./01-Run/startStop.sh start-all --apply
# wait for servers to start...
./01-Run/rwserver_status.sh

# 8. Engine configuration
./05-ReportsPerformance/engine_perf_settings.sh

# 9. Forms settings
./06-FormsDiag/forms_settings.sh

# 10. Config backup exists
ls -la ./07-Maintenance/ConfigBackup/

# 11. One TNS_ADMIN everywhere (files + running processes)
./02-Checks/tns_admin_check.sh

# 12. Loopback-only / clone-capable, no outbound calls
./02-Checks/clone_check.sh
./02-Checks/egress_check.sh

# 13. RCU repository: data sources log in, invalid objects, profile
./07-Maintenance/rcu_repository_check.sh

# 14. Smoke test: Forms XML -> FMX, report -> PDF via rwservlet, font test
./09-Install/15-deploy-test-report-forms_template.sh --apply

# 15. Certificate expiry check scheduled
./10-Monitoring/cert_expiry_check.sh --cron
```

Review output of each and resolve any FAIL items before going live.

---

## What the Script Does

Acceptance = the analyse scripts of 01–07 (folder roles, root README) – the
installation has no own check logic, so a check is fixed in one place and
works the same for a fresh install and an existing environment.

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
| 8 | Report engine parameters vs. Oracle rules / CPUs, engine heap vs. RAM, drift to `environment.conf` | `05-ReportsPerformance/engine_perf_settings.sh` |
| 9 | Forms files, binaries/libraries, FORMS_PATH, default.env vs. environment.conf, config sections | `06-FormsDiag/forms_settings.sh` (+ `forms_perf_settings.sh`: timeouts, limit, prestart) |
| 10 | Config backup present | direct check |
| 11 | `TNS_ADMIN` in every file and running process | `02-Checks/tns_admin_check.sh` |
| 12 | Loopback-only sockets, no outbound connections | `02-Checks/clone_check.sh`, `02-Checks/egress_check.sh` |
| 13 | RCU repository (data source logins, invalid objects, profile) | `07-Maintenance/rcu_repository_check.sh` |
| 14 | Smoke test Forms / Reports / fonts | `09-Install/15-deploy-test-report-forms_template.sh --apply` |
| 15 | Certificate expiry cron present | `10-Monitoring/cert_expiry_check.sh --cron` |

Background for every check – how the parts work together:
[80-FMW-Architecture/README.md](../../80-FMW-Architecture/README.md).

Final summary (via `print_summary`, same convention as every other script):
- Total OK / WARN / FAIL counts
- Exit code 0 if no issues, 1 if WARN only, 2 if any FAIL
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
2. Set up monitoring using `monUser` credentials
3. Test a sample report via `01-Run/rwserver_status.sh`
4. Run `04-ReportsFonts/pdf_font_verify.sh` to confirm fonts are embedded in PDF output
