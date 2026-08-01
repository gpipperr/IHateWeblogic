# IHateWeblogic – Oracle Forms & Reports Diagnostic Scripts

Author: Gunther Pipperr | https://pipperr.de | License: Apache 2.0
```
I – Innovation
H – Helps
A – Admins
T – To
E – Enhance
W – Weblogic
B – Based
L – Lifecycle
O – Operations
G – Governance
I – Integration
C – Control
```
Innovation Helps Admins To Enhance Weblogic-Based Lifecycle Operations, Governance, Integration & Control => [IHateWeblogic.md](IHateWeblogic.md)

## Project Status

**`[██████████████░░░░░░]` ~70 % complete** – phases 1–7 are implemented, phase 8 is partial, phase 9 is concept-only.

| # | Phase | Status |
|---|---|---|
| 1 | Installation | ✅ Done |
| 2 | Configuration & First Start | ✅ Done |
| 3 | Check Logs | ✅ Done (`display_check.sh`, `rwrun_trace.sh` still stubs) |
| 4 | Set Up SSL | ✅ Done |
| 5 | Solve Font Problems | ✅ Done |
| 6 | Check Reports Performance | ✅ Done |
| 7 | Check Forms | ✅ Done |
| 8 | Maintenance & Patches | 🚧 Partial (no dedicated repository-schema patch script) |
| 9 | Proactive Monitoring | 📝 Concept only – see [10-Monitoring/README.md](10-Monitoring/README.md) |

Details per phase: [Lifecycle Overview](#lifecycle-overview) below.

> **Work in Progress** – This library is under active development.
> Not all scripts are fully implemented yet and the collection has not been
> end-to-end tested on a live Oracle Forms/Reports installation.
> Use with caution and verify output before applying any changes (`--apply`).
> Contributions and bug reports welcome.

> **Target Version:** This library targets **Oracle Fusion Middleware (FMW) 14.1.2 and later**
> (Oracle Forms 14c, Reports 12c codebase under 14c naming, WebLogic 14c). Earlier versions
> (12c domains, pre-14.1.2 WebLogic) are not supported.

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
│  09-Install/00–03     OS baseline, packages, Java, "oracle" user    │
│  09-Install/04–05     Nginx (optional), WebLogic installation       │
│  09-Install/06        Forms & Reports installation                 │
│  60-RCU-DB-19c/       Repository DB: OS baseline, DB software,     │
│                       listener, database creation, audit,          │
│                       FMW tablespace, autostart                    │
│  09-Install/07        RCU – create repository schemas in the DB    │
│  09-Install/08        Create the domain (WLST)                     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────┐
│  PHASE 2 – CONFIGURATION & FIRST START                              │
│  (oracle)                                                            │
│                                                                     │
│  09-Install/09        JVM, cgicmd.dat, base configuration           │
│  09-Install/10–11     boot.properties, NodeManager                 │
│  09-Install/12        Reports users (MonUser, RepRunner)            │
│  09-Install/13        Configure Reports Server                     │
│  09-Install/14        Configure Forms (template copy approach)     │
│  01-Run/startStop.sh  Start AdminServer + Managed Servers           │
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
│  01-Run/rwserver_status.sh  Reports Server health                  │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────┐
│  PHASE 4 – SET UP SSL                                               │
│  (root + oracle)                                                    │
│                                                                     │
│  08-SSL/ssl_prepare_cert.sh          Create / request a certificate│
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
│  PHASE 6 – CHECK REPORTS PERFORMANCE                                │
│  (oracle)                                                            │
│                                                                     │
│  05-ReportsPerformance/engine_perf_settings.sh   Engine parameters  │
│  05-ReportsPerformance/engine_perf_analyse.sh    Live analysis,     │
│                                                   queue/response     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────┐
│  PHASE 7 – CHECK FORMS                                              │
│  (oracle)                                                            │
│                                                                     │
│  06-FormsDiag/forms_settings.sh        formsweb.cfg / default.env  │
│  06-FormsDiag/forms_perf_settings.sh    Forms runtime tuning        │
│  06-FormsDiag/forms_perf_analyse.sh     Live analysis of sessions   │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────┐
│  PHASE 8 – MAINTENANCE & PATCHES                                    │
│  (oracle + root, recurring)                                         │
│                                                                     │
│  07-Maintenance/backup_config.sh              Backup before every  │
│                                                patch                 │
│  09-Install/05-oracle_patch_weblogic.sh        WebLogic patches     │
│  09-Install/06-oracle_patch_forms_reports.sh   Forms/Reports patches│
│  60-RCU-DB-19c/02-db_patch_db_software.sh      Database patches     │
│  07-Maintenance/restore_config.sh              Rollback on issues   │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────┐
│  PHASE 9 – PROACTIVE MONITORING (new)                               │
│  (oracle, cron / systemd timer, ongoing)                             │
│                                                                     │
│  10-Monitoring/claude_monitor.sh   Collects diagnostic data from    │
│                                     phases 3–7 (logs, SSL, fonts,   │
│                                     Reports/Forms performance)      │
│  10-Monitoring/claude_analyze.sh   Claude API analysis →            │
│                                     SEVERITY / ROOT_CAUSE /          │
│                                     RECOMMENDED_ACTION                │
└────────────────────────────────────────────────────────────────────┘
```

### Two Kinds of Folders in This Structure

| Type | Folders | Character |
|---|---|---|
| **Phase folders** (run once) | `09-Install/`, `60-RCU-DB-19c/`, `08-SSL/` | Fixed order, rarely re-run after initial setup (except for renewal/patching) |
| **Cross-cutting folders** (used repeatedly) | `00-Setup/`, `01-Run/`, `02-Checks/`, `03-Logs/`, `04-ReportsFonts/`, `05-ReportsPerformance/`, `06-FormsDiag/`, `07-Maintenance/` | Called again and again from first start through steady-state operation |

`10-Monitoring/` is the only folder that is **not** a manual diagnostic step
anymore — it automates exactly these cross-cutting scripts in the
background and adds AI-assisted root-cause reasoning on top.

### Known Gaps

| Phase | Gap |
|---|---|
| Phase 3 (Logs) | `02-Checks/display_check.sh` (DISPLAY for rwclient) is still a stub |
| Phase 6 (Reports) | `01-Run/rwrun_trace.sh` is still a stub |
| Phase 8 (Patches) | No dedicated script for repository schema patches after an FMW upgrade (`60-RCU-DB-19c/02-db_patch_db_software.sh` only covers DB software patches) |
| Phase 9 (Monitoring) | Concept only so far — see `10-Monitoring/README.md` |

## First Run – Required Order

Run these scripts in sequence on a fresh installation:

```
1.  00-Setup/init_env.sh                  # Detect paths, generate environment.conf
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

## Script Directories

| Directory             | Purpose                                              |
|-----------------------|------------------------------------------------------|
| `00-Setup/`           | Environment setup, lib, password management          |
| `01-Run/`             | Start/stop, WLST, Reports Server status              |
| `02-Checks/`          | OS, Java, ports, DB connectivity, SSL checks         |
| `03-Logs/`            | Log discovery, grep, tail, archive, cleanup          |
| `04-ReportsFonts/`    | Font inventory, migration PS→TTF, uifont.ali, deploy |
| `05-ReportsPerformance/` | Engine/cache tuning and inspection               |
| `06-FormsDiag/`       | Oracle Forms specific diagnostics                    |
| `07-Maintenance/`     | Config backup/restore                                |
| `08-SSL/`             | SSL certificate lifecycle: prepare, deploy, audit    |
| `09-Install/`         | Full installation flow: OS → WLS → Forms/Reports → Domain → runtime config |
| `10-Monitoring/`      | Concept only – AI-assisted proactive monitoring (Claude API) |
| `60-RCU-DB-19c/`     | Oracle 19c minimal RCU database: OS baseline → install → patch (AutoUpgrade) → create DB → Unified Audit |

## Repository Structure

```
IHateWeblogic/
│
├── README.md                        – First-run order, purpose of each script, debug checklist
├── IHateWeblogic.md                 – Background and intention of the IHateWeblogic script lib
├── environment.conf                 ← symlink → 00-Setup/environments/<name>.conf  (do NOT commit)
├── weblogic_sec.conf.des3           ← generated by 00-Setup/weblogic_sec.sh (do NOT commit)
├── .gitignore                       – excludes environment.conf, *.des3, *.conf, ssl.conf, certs/, log/
│
├── 00-Setup/
│   ├── README.md                    – Full script reference + setup walkthrough (clone → params →
│   │                                   passwords → analyze → configure)
│   ├── IHateWeblogic_lib.sh         – Central library: output functions, password handling,
│   │                                   parameter parsing, environment helpers (source this first)
│   ├── init_env.sh                  – Detect FMW/Domain paths and running processes,
│   │                                   generate environments/<name>.conf + update symlink
│   ├── set_env.sh                   – Select active environment when multiple domains/DB homes exist
│   ├── weblogic_sec.sh              – Prompt for WebLogic password → encrypt to
│   │                                   weblogic_sec.conf.des3 (openssl des3, machine-local key)
│   ├── database_rcu_sec.sh          – Same encryption concept for the RCU/repository DB password
│   ├── mos_sec.sh                   – Same encryption concept for My Oracle Support credentials
│   ├── set_environment.md           – Concept doc: environment.conf symlink + environments/ folder
│   └── environments/                – Per-environment conf files
│       ├── README.md                – committed
│       ├── *.conf.template          – committed (fmw_prod, db_prod, …)
│       └── *.conf                   – gitignored (server-specific, generated by init_env.sh)
│
├── 01-Run/
│   ├── README.md
│   ├── startStop.sh                 – Manage components: list | start/stop <comp> | start-all | stop-all
│   ├── wlst_connect.sh              – Open interactive WLST shell with auto-login via weblogic_sec.sh
│   └── rwserver_status.sh           – Engine pool, job queue, rwservlet HTTP status
│
├── 02-Checks/
│   ├── README.md
│   ├── os_check.sh                  – OL version, kernel, ulimits, open files;
│   │                                   validated against Oracle certification matrix
│   ├── java_check.sh                – Verify JAVA_HOME uses FMW-bundled JDK (not system JDK)
│   ├── port_check.sh                – Listen addresses and ports per component, TCP check
│   ├── db_connect_check.sh          – TNS / JDBC connectivity test (uses weblogic_sec.sh)
│   ├── ssl_check.sh                 – Read SSL configuration, analyze certificates, show expiry dates
│   └── weblogic_performance.sh      – SecureRandom startup fix (java.security) + JVM heap per server
│
├── 03-Logs/
│   ├── README.md
│   ├── get_all_logs.sh              – List all relevant log files with size and modification date
│   ├── grep_logs.sh                 – Search a pattern across all log files  (param: search term)
│   ├── tail_logs.sh                 – Live-tail multiple log files simultaneously
│   ├── archive_logs.sh              – Compress old log files (--apply to execute)
│   ├── setLogLevel.sh               – Query running components and set log level via WLST
│   └── cleanLogFiles.sh             – Truncate active logs, remove old ones for a clean baseline
│
├── 04-ReportsFonts/
│   ├── README.md                    – incl. Section 11: font troubleshooting
│   ├── manual_setup_de.txt          – German DBA cookbook (manual font setup, 7 steps)
│   ├── get_root_install_libs.sh     – Check/install font, PDF (poppler-utils) and general
│   │                                   FMW OS prerequisite packages (gcc, motif, …) via dnf
│   ├── font_inventory.sh            – Inventory all PostScript Type1 and TTF fonts (FMW + system)
│   ├── get_font_names.sh            – Use fc-query to extract exact names → ready uifont.ali entries
│   ├── deploy_fonts.sh              – Deploy Liberation, DejaVu and custom fonts to REPORTS_FONT_DIR (--apply)
│   ├── uifont_ali_update.sh         – Rebuild uifont.ali from uifont_ali_template.ali (--apply)
│   ├── uifont_ali_template.ali      – Live template (committed): [Global]/[Printer]/[Display]/[PDF:Embed]
│   │                                   sections + ##PDF_SUBSET## marker; edit this, not the deployed file
│   ├── fontpath_config.sh           – Set REPORTS_FONT_DIRECTORY, TK_FONTALIAS, ORACLE_FONTALIAS (--apply)
│   ├── pdf_font_verify.sh           – Verify generated PDFs: embedded=yes, type=TrueType (pdffonts)
│   ├── font_cache_reset.sh          – Rebuild Linux fontconfig cache (fc-cache) after font deploy (--apply)
│   └── custom_fonts_dir/            – Drop corporate/customer font files here before deploying
│
├── 05-ReportsPerformance/
│   ├── README.md
│   ├── engine_perf_settings.sh      – Read/update engine+cache tuning params in rwserver.conf (--apply)
│   └── engine_perf_analyse.sh       – Live job stats via getserverinfo XML + WLS_REPORTS log scan
│
├── 06-FormsDiag/
│   ├── README.md
│   ├── forms_settings.sh            – Forms version, FORMS_PATH, config files, fonts, frmweb sessions
│   ├── forms_perf_settings.sh       – formsweb.cfg perf params, default.env timeouts, WLS_FORMS JVM heap
│   └── forms_perf_analyse.sh        – Session memory, HTTP response times, WLS_FORMS log scan
│
├── 07-Maintenance/
│   ├── README.md                    – Backup categories, manifest format, restore workflow
│   ├── backup_config.sh             – Backup all config files before changes:
│   │                                   ConfigBackup/YYYYMMDD_HH24MI/<type>/ per config type
│   ├── restore_config.sh            – List available backups and restore a selected set (--apply)
│   └── ConfigBackup/                – Backup storage: one subfolder per date/time and config type (gitignored)
│
├── 08-SSL/
│   ├── README.md                    – Certificate lifecycle: prepare → deploy → verify
│   ├── ssl_prepare_cert.sh          – Create/stage a cert: SELF (self-signed), EASYRSA (internal CA),
│   │                                   REQUEST (CSR for a public/company CA)
│   ├── ssl_config.sh                – Audit SSL config: expiry, protocols, ciphers, Frontend Host
│   ├── ssl.conf.template            – committed – documented defaults for ssl.conf
│   ├── ssl.conf                     – gitignored – server-specific cert parameters
│   └── certs/                       – gitignored – generated certs/keys (staging area)
│
├── 09-Install/
│   ├── README.md                    – Installation roadmap, full script reference (Phase 0–6)
│   ├── 01-setup-interview.sh        – Configuration interview → environment.conf
│   ├── 00-root_os_network.sh        – Phase 0: hostname, hosts, chrony, SSH
│   ├── 01-root_os_baseline.sh       – Phase 0: SELinux, kernel, THP → REBOOT
│   ├── 02-root_os_packages.sh       – Phase 0: OS packages
│   ├── 02b-root_os_java.sh          – Phase 0: Oracle JDK 21 + SecureRandom fix
│   ├── 03-root_user_oracle.sh       – Phase 0: oracle user, dirs, sudo, repo handover
│   ├── 04-root_nginx.sh             – Phase 0: Nginx install + proxy config
│   ├── 05-root_nginx_ssl.sh         – Phase 0: SSL cert deploy, TLS config
│   ├── 04-oracle_pre_checks.sh      – Phase 1: pre-flight checks before download/install
│   ├── 04-oracle_pre_download.sh    – Phase 1: eDelivery ZIPs + getMOSPatch
│   ├── 05-oracle_install_weblogic.sh – Phase 2: FMW Infrastructure silent install
│   ├── 05-oracle_patch_weblogic.sh  – Phase 2: OPatch upgrade + WLS patches
│   ├── 06-oracle_install_forms_reports.sh – Phase 3: Forms & Reports silent install
│   ├── 06-oracle_patch_forms_reports.sh   – Phase 3: Forms & Reports patches
│   ├── 07-oracle_setup_repository.sh – Phase 4: RCU metadata schemas
│   ├── 08-oracle_setup_domain.sh    – Phase 4: WebLogic domain creation (WLST silent)
│   ├── 09-oracle_configure.sh       – Phase 5: orchestrator – env → JVM → fonts → cgicmd → backup
│   ├── 10-oracle_boot_properties.sh – Phase 6: boot.properties (AdminServer + NodeManager)
│   ├── 11-oracle_nodemanager.sh     – Phase 6: NodeManager setup (plain SSL via WLST)
│   ├── 12-oracle_reports_users.sh   – Phase 6: MonitorUser + RepRunner WebLogic users
│   ├── 13-root_reports_fix.sh       – Phase 6 (root): libnsl.so.2 symlink for Oracle Linux 9
│   ├── 13-oracle_setup_reports.sh   – Phase 6: Reports Server config (rwnetwork/rwservlet/rwserver)
│   ├── 14-oracle_setup_forms.sh     – Phase 6: Forms config (template-copy approach)
│   ├── oracle_software_version.conf – Pinned FMW/JDK/patch version numbers
│   ├── nginx-wls.conf.template      – Nginx reverse-proxy config template
│   ├── forms_templates/             – 6 editable Forms config templates + README
│   │                                   (default.env, formsweb.cfg, webutil.cfg, Registry.dat, res files)
│   ├── response_files/              – Silent-install response file templates
│   │                                   (domain_config.py, fr_install.rsp, cgicmd.dat)
│   └── docs/                        – Step-by-step detail documentation (00–14, 80-security, 90-validate)
│
├── 10-Monitoring/
│   └── README.md                    – Concept only: AI-assisted proactive monitoring (Claude API)
│
└── 60-RCU-DB-19c/
    ├── README.md                    – DB setup roadmap (Phase DB, between Phase 3 and 4)
    ├── 00-root_db_os_baseline.sh    – DB-specific OS settings, preinstall RPM (auto-sudo)
    ├── 01-db_install_software.sh    – Oracle 19c software-only install (runInstaller -silent)
    ├── 02-db_patch_db_software.sh   – AutoUpgrade: download RU + create patched ORACLE_HOME
    ├── 04-db_setup_listener.sh      – Configure the TNS listener
    ├── 05-db_create_database.sh     – DBCA: CDB FMWCDB + PDB FMWPDB (AL32UTF8, AMM)
    ├── 06-db_audit_setup.sh         – Pure Unified Auditing relink + purge job
    ├── 07-db_fmw_tablespace.sh      – Optional: FMW_DATA tablespace pre-RCU
    ├── 08-db_auto_start.sh          – Configure DB/listener autostart (oratab, systemd)
    ├── *.sql                        – Unified Audit policy scripts (generate/disable)
    ├── environment_db.conf.example  – committed – DB-specific variables (DB_ORACLE_HOME, DB_SID, …)
    ├── environment_db.conf          – gitignored – server-specific values
    └── docs/                        – Step-by-step detail documentation
```

## Common Flags

- `--apply` : Execute write/change operations (default: read-only/dry-run)
- `--help`  : Show usage information

## Setup

```bash
# Step 1: Detect environment
./00-Setup/init_env.sh

# Step 2: Store WebLogic password (encrypted with machine UUID)
./00-Setup/weblogic_sec.sh

# Step 3: Run checks
./02-Checks/java_check.sh
./02-Checks/port_check.sh
```

## Oracle Documentation References

- Forms 14c Install Guide: https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/install-fnr/index.html
- Reports 12c Install Guide: https://docs.oracle.com/middleware/12213/formsandreports/install-fnr/
- Reports 14c Install Guide on Windows: https://www.pipperr.de/dokuwiki/doku.php?id=forms:oracle_reports_14c_windows64 
- Reports 12c Install Guide on Windows:https://www.pipperr.de/dokuwiki/doku.php?id=forms:oracle_reports_12c_r2_windows64
- SSL Weblogic : https://www.pipperr.de/dokuwiki/doku.php?id=forms:oracle_reports_12_ssl

- Font Usage Oracle Reports : https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_xplat001.htm

## Troubleshooting

### Font Problems

For detailed font troubleshooting see [04-ReportsFonts/README.md](04-ReportsFonts/README.md) – Section 11.

## Password Security Concept

Based on: https://www.pipperr.de/dokuwiki/doku.php?id=dba:passwort_verschluesselt_hinterlegen

The WebLogic admin password is encrypted with `openssl des3` using the machine's
disk UUID as key. The encrypted file `weblogic_sec.conf.des3` is machine-specific
and **must not be committed to git** (covered by `.gitignore`).

## Open Items / TODO

- [ ] **rwservlet authentication** (`01-Run/rwserver_status.sh`):
  `getserverinfo` is currently called without credentials (works on unsecured servlets).
  Secured rwservlet instances require `authid=user/password` in the URL or HTTP Basic Auth.
  Credentials must be stored encrypted using the same mechanism as the WebLogic password
  (`openssl des3` + system UUID key via `00-Setup/weblogic_sec.sh`).
  Until implemented: restrict `rwservlet` access via firewall or WLS security policy.

- [ ] **`02-Checks/display_check.sh`** – not yet created.
  Verify/set a usable `DISPLAY` for `rwclient`/report generation that needs an X server (Xvfb).

- [ ] **`01-Run/rwrun_trace.sh`** – not yet created.
  Run a single report with `rwrun` debug tracing enabled for root-cause analysis.

- [ ] **Repository schema patching** – no dedicated script yet.
  `60-RCU-DB-19c/02-db_patch_db_software.sh` only patches the database software (AutoUpgrade);
  RCU/repository schema patches after an FMW upgrade are still a manual step.

- [ ] **`10-Monitoring/`** – concept only, not implemented yet.
  See [10-Monitoring/README.md](10-Monitoring/README.md) for the planned Claude-assisted
  proactive monitoring design.
