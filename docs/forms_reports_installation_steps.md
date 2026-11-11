# Forms & Reports – Lifecycle, First Run, Setup

← Back to the [root README](../README.md)

## Lifecycle Overview

The numbered folders in this repository follow the lifecycle of a real
Oracle Forms & Reports installation, from an empty machine to steady-state
operation with proactive, AI-assisted error analysis.

```
┌────────────────────────────────────────────────────────────────────┐
│  PHASE 1 – EMPTY SYSTEM → INSTALLATION                              │
│  (root + oracle, one-time)                                          │
│                                                                     │
│  00-Setup/            Shared library, environment concept,         │
│                       credential handling                          │
│  00-Setup/customer_conf_import.sh  customer master data (14c move, │
│                       before the interview)                        │
│  09-Install/00–03     OS baseline, packages, Java, "oracle" user    │
│  09-Install/04–05     Nginx (optional), WebLogic installation       │
│  09-Install/06        Forms & Reports installation                 │
│  60-RCU-DB-19c/       Repository DB: OS baseline, CVU pre-check,   │
│                       DB software, listener, database, audit,      │
│                       FMW tablespace, RCU profile, autostart        │
│  09-Install/07        RCU – create repository schemas in the DB    │
│  09-Install/08        Create the domain (WLST)                     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────┐
│  PHASE 2 – CONFIGURATION & FIRST START                              │
│  (oracle)                                                            │
│                                                                     │
│  09-Install/09        boot.properties, JVM, font packages, backup   │
│  00-Setup/detect_env_conf.sh Add runtime parameters to environment.conf    │
│  09-Install/10–11     boot.properties, NodeManager (+ NM creds)    │
│  09-Install/12        Reports users (monUser, RepRunner)            │
│  09-Install/13        Configure Reports Server                     │
│  09-Install/14        Configure Forms (template copy approach)     │
│  09-Install/14b       Reports fonts, uifont.ali, cgicmd.dat         │
│  09-Install/30        Autostart: systemd unit + Node Manager        │
│  09-Install/15        Smoke test: Forms XML -> FMX, report -> PDF   │
│  09-Install/40        Forms client bundle via URL (jlink, FSAL)     │
│  01-Run/startStop.sh  Start/stop through the Node Manager           │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────┐
│  PHASE 3 – CHECK LOGS                                               │
│  (oracle)                                                            │
│                                                                     │
│  03-Logs/tail_logs.sh       Follow live logs during first start    │
│  03-Logs/grep_logs.sh       Error patterns (ORA-, REP-, FRM-)      │
│  03-Logs/get_all_logs.sh    Collect a full log bundle               │
│  02-Checks/os_check.sh      Re-verify OS/RAM/disk/ulimits           │
│  02-Checks/java_check.sh    JAVA_HOME, version, Log4j CVE scan      │
│  02-Checks/port_check.sh    Port reachability                      │
│  02-Checks/tns_admin_check.sh  One TNS_ADMIN, files + processes    │
│  02-Checks/clone_check.sh   Loopback only, clone / golden image    │
│  01-Run/rwserver_status.sh  Reports Server health                  │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────┐
│  PHASE 4 – SET UP SSL                                               │
│  (root + oracle)                                                    │
│                                                                     │
│  08-SSL/ssl_prepare_cert.sh          Create / request a certificate│
│  08-SSL/ssl_local_ca.sh              Own root CA: TLS + codesigning│
│  09-Install/05-root_nginx_ssl.sh     Deploy to Nginx                │
│  08-SSL/ssl_config.sh                Audit + verification          │
│  02-Checks/ssl_check.sh              Ongoing certificate checks    │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────┐
│  PHASE 5 – SOLVE FONT PROBLEMS                                      │
│  (oracle)                                                            │
│                                                                     │
│  04-ReportsFonts/uifont_ali_update.sh   uifont.ali font mapping     │
│  04-ReportsFonts/fontpath_config.sh     Font paths + JAVA_OPTIONS   │
│  04-ReportsFonts/font_cache_reset.sh    Reset the font cache        │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────┐
│  PHASE 6 – CHECK REPORTS PERFORMANCE  (also alone, existing env.)   │
│  (oracle)                                                            │
│                                                                     │
│  05-ReportsPerformance/engine_perf_settings.sh   rules, CPU, RAM    │
│  05-ReportsPerformance/engine_perf_analyse.sh    failures, queue,   │
│                                                   pool, server logs │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────┐
│  PHASE 7 – CHECK FORMS                                              │
│  (oracle)                                                            │
│                                                                     │
│  06-FormsDiag/forms_settings.sh         configuration consistent?   │
│  06-FormsDiag/forms_perf_settings.sh    timeouts, limit, prestart   │
│  06-FormsDiag/forms_perf_analyse.sh     frmweb per section, logs    │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────┐
│  PHASE 8 – MAINTENANCE & PATCHES                                    │
│  (oracle + root, recurring)                                         │
│                                                                     │
│  → 09-Install/docs/00-patch-references.md     Current patch numbers │
│  07-Maintenance/backup_config.sh              Backup before every  │
│                                                patch                 │
│  01-Run/startStop.sh stop-all --apply          Stop before patching │
│  07-Maintenance/80-patch_java_os.sh            Java/OS (read-only)  │
│  07-Maintenance/81-patch_weblogic.sh           WebLogic patches     │
│  07-Maintenance/82-patch_forms_reports.sh      Forms/Reports patches│
│  60-RCU-DB-19c/01- --target-home + 09-         Database RU (o-o-p)  │
│  01-Run/startStop.sh start-all --apply         Start after patching │
│  07-Maintenance/restore_config.sh              Rollback on issues   │
│  07-Maintenance/bak_cleanup.sh --apply         Old *.bak_<ts> copies│
│  07-Maintenance/patch_storage.sh clean --apply Free patch ZIPs      │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────┐
│  PHASE 9 – PROACTIVE MONITORING (new)                               │
│  (oracle, cron / systemd timer, ongoing)                             │
│                                                                     │
│  10-Monitoring/cve_inventory.sh    Installed components, patch      │
│                                     cycle, JDKs, exposure, advisory │
│  10-Monitoring/cve_watch.sh        New CVEs / alerts, daily (cron)  │
│  10-Monitoring/cert_expiry_check.sh Certificates, daily (cron)      │
│  10-Monitoring/claude_monitor.sh   Collects diagnostic data from    │
│                                     phases 3–7 (logs, SSL, fonts,   │
│                                     Reports/Forms performance)      │
│  10-Monitoring/claude_analyze.sh   Claude API analysis →            │
│                                     SEVERITY / ROOT_CAUSE /          │
│                                     RECOMMENDED_ACTION                │
└────────────────────────────────────────────────────────────────────┘
```

### Folder Roles

The library grew in this order: first the scripts to analyse an **existing**
environment (01–07, customer engagements), then the installation (09), last
the monitoring (10). The folder numbers stay; each folder has one role:

| Role | Folders | Rule |
|---|---|---|
| **Analyse + fix** a running environment (no matter who built it) | `01-Run/`, `02-Checks/`, `03-Logs/`, `04-ReportsFonts/`, `05-ReportsPerformance/`, `06-FormsDiag/`, `07-Maintenance/` | read-only by default, `--apply` repairs with backup, may be interactive |
| **Build** (once, fixed order) | `09-Install/`, `08-SSL/`, `60-RCU-DB-19c/` | sets the values from `environment.conf`; acceptance by calling the analyse scripts (`09-Install/docs/90-oracle_validate.md`), no own check logic |
| **Monitor** (regularly, unattended) | `10-Monitoring/` | calls the analyse scripts read-only (exit code, log), never `--apply`; own logic only for what exists nowhere else (CVE comparison, trends, AI assessment) |
| Background / customer | `80-FMW-Architecture/`, `70-Customer-Projects/` | why it behaves that way / manual cookbooks |

Rules across the folders:

1. **Logic exists once.** Shared functions live in a sourced library of the
   folder that owns the topic (`01-Run/reports_server_lib.sh`,
   `03-Logs/log_locations.sh`, `06-FormsDiag/forms_lib.sh`). Build and monitor call the scripts, they do
   not copy them. (The 05 review of 2026-10-19 found stale copies that
   evaluated the wrong file – the reason for this rule.)
2. **One value, one source.** Target and tuning values live in
   `environment.conf`. The installation writes them to the Oracle files;
   an `--apply` in 01–07 writes changed values back to `environment.conf`, so a
   later installation run does not reset them.
3. **Monitoring needs machine-readable output.** Exit code 0/1/2 and
   `print_summary` exist in every script; a uniform report/JSON format is an
   open item in [10-Monitoring/README.md](../10-Monitoring/README.md).

### Known Gaps

| Phase | Gap |
|---|---|
| Phase 8 (Patches) | FMW-bundled JDK `oracle_common/jdk` (17.0.12, OPatch component `oracle.jdk`) – no patch in KA1182 (`FMW_JDK_PATCH_NR`); FMW DBCLIENT 23.26.2 only via the SPB – SR draft ready |
| Phase 9 (Monitoring) | `cve_inventory.sh`, `cve_watch.sh`, `cert_expiry_check.sh`, `patch_cycle_analysis.sh`, `claude_setup_check.sh` implemented (Claude sandbox rollout on the test host open), rest concept — see `10-Monitoring/README.md` |
| Security | `frmweb` / Coherence remainder on all interfaces / host IP (firewall); `ADMIN_IP_RANGE` optional (asked by `04-root_nginx.sh`, `any` where there is no admin network) |

## First Run on an Existing Environment – Required Order

A **new installation** runs through the install chain instead – order,
phases and gates in [`09-Install/README.md`](../09-Install/README.md) (customer
14c move: [Step 2 in order](migration_forms_reports_to_14c.md#moving-from-12c-to-forms--reports-14c--the-process-in-three-steps)).

On an **existing** environment (built by somebody else, analyse + fix), run
these scripts in sequence:

```
1.  00-Setup/detect_env_conf.sh                  # Detect paths, generate environment.conf
2.  00-Setup/weblogic_sec.sh              # Store WebLogic password (encrypted, machine-local)
3.  02-Checks/weblogic_performance.sh     # Check/apply SecureRandom fix + JVM heap settings
4.  02-Checks/os_check.sh                 # Validate OS, kernel, ulimits
5.  02-Checks/java_check.sh               # Verify correct JDK is used
6.  02-Checks/port_check.sh               # Verify WebLogic/OHS ports
7.  02-Checks/db_connect_check.sh         # Verify TNS/DB connectivity
8.  02-Checks/ssl_check.sh                # Check SSL/TLS configuration and cert expiry
9.  04-ReportsFonts/font_inventory.sh     # Inventory PS and TTF fonts
10. 04-ReportsFonts/get_font_names.sh     # Generate uifont.ali entries
11. 04-ReportsFonts/uifont_ali_update.sh  # Update uifont.ali (--apply to write)
```

## Setup

```bash
# Step 1: Detect environment
./00-Setup/detect_env_conf.sh

# Step 2: Store WebLogic password (encrypted with machine UUID)
./00-Setup/weblogic_sec.sh

# Step 3: Run checks
./02-Checks/java_check.sh
./02-Checks/port_check.sh
```
