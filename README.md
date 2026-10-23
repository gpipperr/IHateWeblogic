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

**`[██████████████████░░]` ~92 % complete** (state 2026-10-23) – phases 1–7
are implemented and the whole install chain is live-tested end-to-end incl.
the smoke test; all analyse + fix folders `01-`…`07-` and `08-SSL` were
reviewed against the Oracle 14.1.2 documentation and re-tested live
(2026-10-19/20); phase 8 is nearly done, phase 9 has its first script
(`cve_inventory.sh`); host hardening (firewall, sshd) is live on the test host.
New 2026-10-22/23: the **Forms client distribution via URL** (jlink Java
runtime + FSAL + JACOB from Nginx, PowerShell installer in the user profile)
and **one `TNS_ADMIN`** for every process – together the first complete
Forms session from a Windows client (alias login, test form).

How the ~92 % is estimated: phases 1–7 count as done (7 × ~11 %), phase 8
about nine tenths (JDK upgrade from the patch repository done 2026-10-20; bundled-JDK patch open), phase 9 about a quarter
(CVE watch step 1 done; `cve_watch.sh`, notification, config security
scanner are concept); minus the [open items](#open-items--todo) – mainly
the remaining client tests (update / offline / JACOB on Windows), switching the scripts to the CPU Oct 2026 patch set (see
[Security & Patch Status](#security--patch-status)) and a few security
hardening steps.

| # | Phase | Status |
|---|---|---|
| 1 | Installation | ✅ Done |
| 2 | Configuration & First Start | ✅ Done – incl. secured Reports server (`REPORTS_SECURITY=ldap`), autostart, NM-aware `startStop.sh`, smoke test `15-` (Forms XML → FMX, report → PDF); **one `TNS_ADMIN`** in `default.env`, `rwserver.conf`, `reports.sh`, `setUserOverrides.sh`, `.bash_profile`, checked with `02-Checks/tns_admin_check.sh` incl. the running processes (2026-10-23); **Forms client distribution** `40-` + client templates – first Windows FSAL session 2026-10-23 ([concept 40](09-Install/docs/40-forms_client_distribution.md)) |
| 3 | Check Logs | ✅ Done (incl. `rwrun_trace.sh`; `display_check.sh` dropped – tools need no X); reviewed 2026-10-19: one log discovery `03-Logs/log_locations.sh`, `setLogLevel` persist fix – [03-Logs/README.md](03-Logs/README.md) |
| 4 | Set Up SSL | ✅ Done; reviewed 2026-10-20: local root CA for TLS + code signing, `jacob.jar` signed with DigiCert timestamp, redirects behind Nginx via `WL-Proxy-SSL` – [08-SSL/README.md](08-SSL/README.md) |
| 5 | Solve Font Problems | ✅ Done; reviewed 2026-10-19: two font paths (PDF: TTF, HTML: screen-printer AFM/PPD), substitute fonts need AFM/PPD in PDF too – [04-ReportsFonts/README.md](04-ReportsFonts/README.md) |
| 6 | Check Reports Performance | ✅ Done; rebuilt 2026-10-19 on `01-Run/reports_server_lib.sh` (right `rwserver.conf`, report engine, `authid`, server logs) – [05-ReportsPerformance/README.md](05-ReportsPerformance/README.md), background [report_engine_architecture.md](80-FMW-Architecture/report_engine_architecture.md) |
| 7 | Check Forms | ✅ Done; rebuilt 2026-10-19 on `06-FormsDiag/forms_lib.sh` against Oracle's 14.1.2 parameters, prestart fix in `14-` (50 → 5 idle `frmweb`) – [06-FormsDiag/README.md](06-FormsDiag/README.md), background [forms_runtime_architecture.md](80-FMW-Architecture/forms_runtime_architecture.md) |
| 8 | Maintenance & Patches | 🚧 Mostly done — reviewed 2026-10-19 ([07-Maintenance/README.md](07-Maintenance/README.md) §8: backup covers every file our scripts change incl. AFM metrics and customer font originals, restore per `--category` with path check, patch gate sees `rwserver`/engines/`frmweb`); backup/restore + WLS/Forms/Reports patching for an already-running environment (`07-Maintenance/80-82`) implemented; RCU repository: theory, profile `RCU_USER` (no password expiry), `db_securefile`/EBR pre-checks, `rcu_repository_check.sh` (check + Data Pump backup); JDK upgrade: `80-patch_java_os.sh --apply` installs the JDK 21 of MOS Patch 35702194 from the patch repository (downloaded only by `04-`; since the NFTC ended in Sep 2026 there are no public JDK 21 updates), live-tested 2026-10-20; open: OPatch patch for the FMW-bundled JDK `oracle_common/jdk` |
| 9 | Proactive Monitoring | 🚧 Started – `cve_inventory.sh` (CVE watch step 1: components, patch cycle, both JDKs, active use / exposure, OS errata, `--online` advisories); rest concept incl. config security scanner – see [10-Monitoring/README.md](10-Monitoring/README.md) |

Details per phase: [Lifecycle Overview](#lifecycle-overview) below.



## Security & Patch Status

> **Oracle now ships security fixes every month** (quarterly CPU, CSPU in
> the other months, Security Alerts in between). Check the current cycle
> **before every installation and every patch run**.

**Current cycle: CPU October 2026 (2026-10-20) + Security Alert
CVE-2026-91403 (Java SE JSSE, CVSS 9.1, 2026-10-21)** – state 2026-10-22.

| | |
|---|---|
| Current patch list (14.1.2) | [`09-Install/docs/00-patch-references.md`](09-Install/docs/00-patch-references.md) – patch numbers from MOS KA1182 + CPU426, CVE check, "How to read KA1182", MOS Doc-ID table |
| Earlier cycles | frozen snapshots, one per cycle, for rolling back by hand – table "Patch cycle history" in the same file (first: [CSPU September 2026](09-Install/docs/00-patch-references_september_2026.md)) |
| Scripts / `oracle_software_version.conf` | **still on CSPU September 2026** (= test host) – switching to October is the first [open item](#next-patch-cycle-cpu-october-2026-released-2026-10-20--security-alert-cve-2026-91403) |
| Forms & Reports 12.2.1.19 (customer homes) | manual analysis: [`70-Customer-Projects/Forms12_reports12_patch_analyse_10_2026/`](70-Customer-Projects/Forms12_reports12_patch_analyse_10_2026/README.md) |

What matters in this cycle:

- **WebLogic Core** CVE-2026-83399 (T3/IIOP) and CVE-2026-91323 (HTTP), Perl,
  Apache Mina – all CVSS 9.8 → WLS SPB **40125898**, PERL **39951765**.
- **Correction:** every FMW 14.1.2 home also needs the **eight FMW
  Infrastructure bundle patches** (ADF, WebCenter Core, OWSM, FMW Control,
  OAMCLIENT, UMS, OPSS, LibOVD) – they are not in the WLS SPB and were
  missing in our September set.
- **Java – target is the alert release, not the CPU release:** JDK 21
  **21.0.13.0.2** (21.0.13 of the CPU is itself affected); Forms clients
  JRE 8 **1.8.0_511-b26** (Patch 40186686; b25 = CPU build, affected). The
  Forms client is a JSSE TLS client – the client JREs are the most
  important measure:
  [threat model](80-FMW-Architecture/forms_runtime_architecture.md#12-threat-model-of-a-client-side-tls-jsse-flaw).
- **FMW-bundled JDK** `oracle_common/jdk` 17.0.12: no patch in KA1182 –
  open.
- Oracle publishes no CVE → patch mapping: we prove the **patch level**
  ("installed ≥ patch document"), not the fix of a single CVE.


> **Work in Progress** – This library is under active development.

> **Live-tested** on Oracle Linux 9 / FMW 14.1.2 (CSPU Sep 2026, local 19c
> repository DB): clean script-by-script rebuild of the whole `09-Install/`
> chain incl. autostart and smoke test (2026-10-14/16), secured standalone
> Reports server (2026-10-16), RCU repository analysis (2026-10-17), review of
> all analyse + fix folders and `08-SSL` against the Oracle docs (2026-10-19/20,
> Forms client distribution via URL + first Windows FSAL session and one
> `TNS_ADMIN` for all processes (2026-10-22/23,
> [Folder Roles](#folder-roles), background in
> [`80-FMW-Architecture/`](80-FMW-Architecture/README.md)). Details of every
> fix: `git log`; what is still open: [Open Items / TODO](#open-items--todo).
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
│  00-Setup/init_env.sh Add runtime parameters to environment.conf    │
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
│  60-RCU-DB-19c/02-db_patch_db_software.sh      Database patches     │
│  01-Run/startStop.sh start-all --apply         Start after patching │
│  07-Maintenance/restore_config.sh              Rollback on issues   │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────┐
│  PHASE 9 – PROACTIVE MONITORING (new)                               │
│  (oracle, cron / systemd timer, ongoing)                             │
│                                                                     │
│  10-Monitoring/cve_inventory.sh    Installed components, patch      │
│                                     cycle, JDKs, exposure, advisory │
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
   open item in [10-Monitoring/README.md](10-Monitoring/README.md).

### Known Gaps

| Phase | Gap |
|---|---|
| Phase 8 (Patches) | Scripts still on the CSPU Sep 2026 set (October set incl. FMW Infrastructure bundles documented, not yet in `05-`/`06-`); FMW-bundled JDK `oracle_common/jdk` (17.0.12, OPatch component `oracle.jdk`) – no patch in KA1182 (`FMW_JDK_PATCH_NR`) |
| Phase 9 (Monitoring) | `cve_inventory.sh` implemented, rest concept — see `10-Monitoring/README.md` |
| Security | WLS demo SSL ports, `frmweb`/`rwserver` loopback binding, Forms `maxRuntimeProcesses` – see [Open Items](#open-items--todo) |

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
| `05-ReportsPerformance/` | Reports server: analyse + fix an existing environment (parameters, load, logs) |
| `06-FormsDiag/`       | Forms: analyse + fix an existing environment (configuration, sessions, performance) |
| `07-Maintenance/`     | Config backup/restore, patching an already-running environment |
| `08-SSL/`             | SSL certificate lifecycle: prepare, deploy, audit    |
| `09-Install/`         | Full installation flow: OS → WLS → Forms/Reports → Domain → runtime config |
| `10-Monitoring/`      | CVE inventory (`cve_inventory.sh`); concept: AI-assisted monitoring + CVE watch |
| `60-RCU-DB-19c/`     | Oracle 19c minimal RCU database: OS baseline → install → patch (AutoUpgrade) → create DB → Unified Audit |
| `70-Customer-Projects/` | Customer-specific manual walkthroughs (German Kochbuch `.txt` files) and patch analyses (Forms & Reports 12.2.1.19), independent of the scripts above |
| `80-FMW-Architecture/` | Background: how Forms/Reports/WebLogic work internally – start with [`weblogic_middleware_architecture.md`](80-FMW-Architecture/weblogic_middleware_architecture.md) (homes, AdminServer / Node Manager / system components, consoles, log locations), RCU / OPSS: [`rcu_middleware_architecture.md`](80-FMW-Architecture/rcu_middleware_architecture.md), Reports: [`report_engine_architecture.md`](80-FMW-Architecture/report_engine_architecture.md), Forms: [`forms_runtime_architecture.md`](80-FMW-Architecture/forms_runtime_architecture.md) – findings, not procedures; index [`80-FMW-Architecture/README.md`](80-FMW-Architecture/README.md) |

## Repository Structure

```
IHateWeblogic/
│
├── README.md                        – First-run order, purpose of each script, debug checklist
├── IHateWeblogic.md                 – Background and intention of the IHateWeblogic script lib
├── environment.conf                 ← symlink → 00-Setup/environments/<name>.conf  (do NOT commit)
├── weblogic_sec.conf.des3           ← generated by 00-Setup/weblogic_sec.sh (do NOT commit)
├── *_sec.conf.des3, *.conf.des3     ← further encrypted secrets (interview / 13- / 15-), see
│                                       "Password Security Concept" (do NOT commit)
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
│   ├── rwserver_status.sh           – Engine pool, job queue, rwservlet HTTP status (--auth)
│   ├── reports_server_lib.sh        – Shared Reports helpers (sourced by rwserver_status + 05-)
│   └── rwrun_trace.sh               – One report with rwrun + trace / ODL TRACE:32, results in log/
│
├── 02-Checks/
│   ├── README.md
│   ├── os_check.sh                  – OL version, kernel, ulimits, open files;
│   │                                   validated against Oracle certification matrix
│   ├── java_check.sh                – Verify JAVA_HOME uses FMW-bundled JDK (not system JDK)
│   ├── port_check.sh                – Listen addresses and ports per component, TCP check
│   ├── db_connect_check.sh          – TNS / JDBC connectivity test (uses weblogic_sec.sh)
│   ├── ssl_check.sh                 – Read SSL configuration, analyze certificates, show expiry dates
│   ├── egress_check.sh              – Outbound connections of the domain, external DTD URLs, JVM XML options,
│   │                                   --capture (tcpdump DNS + SYN with process) – external-DTD hang risk
│   ├── tns_admin_check.sh           – One TNS_ADMIN everywhere: default.env, rwserver.conf, reports.sh,
│   │                                   setUserOverrides.sh (--apply), .bash_profile, running processes
│   ├── reports_network_scan.sh      – Reports multicast discovery check + active scan for Reports
│   │                                   servers per port (DiagServerLocator), read-only
│   └── weblogic_performance.sh      – SecureRandom startup fix (java.security) + JVM heap per server
│
├── 03-Logs/
│   ├── README.md
│   ├── get_all_logs.sh              – List all relevant log files with size and modification date
│   ├── log_locations.sh             – Sourced: discovers all log dirs of the domain (servers, Reports
│   │                                   server + engines, Reports tools, NM, EM) for all 03- scripts
│   ├── grep_logs.sh                 – Search a pattern across all log files  (param: search term)
│   ├── tail_logs.sh                 – Live-tail multiple log files simultaneously
│   ├── archive_logs.sh              – Compress old log files (--apply to execute)
│   ├── setLogLevel.sh               – Query running components and set log level via WLST
│   └── cleanLogFiles.sh             – Truncate active logs, remove old ones for a clean baseline
│
├── 04-ReportsFonts/
│   ├── README.md                    – incl. Section 11: font troubleshooting
│   ├── manual_setup_de.txt          – pointer only → 70-Customer-Projects/…/Font_kochbuch_de.txt
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
│   ├── paramform_afm_setup.sh       – Screen-printer PPD + AFM for the HTML parameter form (and
│   │                                   substitute fonts in PDF), uses ttf2reports_afm.py (--apply)
│   ├── ttf2reports_afm.py           – Generate Reports-compatible AFM files from TTF fonts
│   ├── HTML_ParameterForm_Fonts.md  – Why the HTML parameter form shows Symbol glyphs, the two font paths
│   ├── font_cache_reset.sh          – Rebuild Linux fontconfig cache (fc-cache) after font deploy (--apply)
│   └── custom_fonts_dir/            – Drop corporate/customer font files here before deploying
│
├── 05-ReportsPerformance/
│   ├── README.md
│   ├── engine_perf_settings.sh      – Engine/queue/cache params vs. Oracle rules, CPUs, RAM (--apply: report engine)
│   └── engine_perf_analyse.sh       – Load: failure rate, queuing share, pool usage, Reports server logs
│
├── 06-FormsDiag/
│   ├── README.md
│   ├── forms_lib.sh                 – Shared Forms helpers (sourced by 06- and 14-): sections with inheritance, frmweb per section
│   ├── forms_settings.sh            – Files, binaries/ldd, FORMS_PATH, default.env vs environment.conf, config sections
│   ├── forms_perf_settings.sh       – Timeout chain, maxRuntimeProcesses, prestart (--apply, --fix-prestart)
│   └── forms_perf_analyse.sh        – frmweb per section (pool vs session), memory, access.log, Forms logs, dumps
│
├── 07-Maintenance/
│   ├── README.md                    – Backup categories, manifest format, restore workflow,
│   │                                   patching an already-running environment (Phase 8)
│   ├── backup_config.sh             – Backup all config files our scripts change (13 categories,
│   │                                   ConfigBackup/YYYYMMDD_HHMI/<category>/, mode 700/600)
│   ├── restore_config.sh            – List backups, restore a set or --category (--apply), path check
│   ├── 80-patch_java_os.sh          – JDK at JDK_HOME from the patch repository (--apply, domain stopped)
│   ├── domain_jdk_path.sh           – Domain + oui/ pinned to jdk-21.0.x → JDK_HOME symlink (--apply)
│   ├── rcu_repository_check.sh      – RCU repository check (registry, accounts, data sources);
│   │                                   --apply = Data Pump backup of schemas + registry
│   ├── 81-patch_weblogic.sh         – WLS FMW Basis layer: wraps 09-Install/05-oracle_patch_weblogic.sh,
│   │                                   hard-fails if WebLogic is still running
│   ├── 82-patch_forms_reports.sh    – Forms + Reports layer: wraps 09-Install/06-oracle_patch_forms_reports.sh,
│   │                                   same stop-check as 81-
│   └── ConfigBackup/                – Backup storage: one subfolder per date/time and config type (gitignored)
│
├── 08-SSL/
│   ├── README.md                    – Certificate lifecycle: prepare → deploy → verify
│   ├── ssl_prepare_cert.sh          – Create/stage a cert: SELF (self-signed), LOCALCA (own root CA),
│   │                                   EASYRSA (internal CA), REQUEST (CSR for a public/company CA)
│   ├── ssl_local_ca.sh              – Own root CA (openssl): init / server (TLS for Nginx) /
│   │                                   codesign (PKCS12 for jacob.jar) / status
│   ├── ssl_config.sh                – Audit SSL config: expiry, protocols, ciphers, Frontend Host
│   ├── ssl.conf.template            – committed – documented defaults for ssl.conf
│   ├── ssl.conf                     – gitignored – server-specific cert parameters
│   └── certs/                       – gitignored – generated certs/keys (staging area)
│
├── 09-Install/
│   ├── README.md                    – Installation roadmap, full script reference (Phase 0–6)
│   ├── 01-setup-interview.sh        – Configuration interview → environment.conf
│   ├── 00-root_os_network.sh        – Phase 0: hostname, DNS/hosts, IPv6, chrony (check only)
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
│   ├── 09-oracle_configure.sh       – Phase 5: pre-start config – boot.properties → JVM → font OS
│   │                                   packages → validation → backup (fonts/cgicmd.dat: 14b-)
│   ├── 10-oracle_boot_properties.sh – Phase 6: boot.properties (AdminServer + NodeManager)
│   ├── 11-oracle_nodemanager.sh     – Phase 6: NodeManager setup (plain SSL via WLST)
│   ├── 12-oracle_reports_users.sh   – Phase 6: monUser + RepRunner WebLogic users
│   ├── 13-root_reports_fix.sh       – Phase 6 (root): libnsl.so.2 symlink for Oracle Linux 9
│   ├── 13-oracle_setup_reports.sh   – Phase 6: Reports Server config (rwnetwork/rwservlet/rwserver)
│   ├── 14-oracle_setup_forms.sh     – Phase 6: Forms config (template-copy approach)
│   ├── 14b-oracle_reports_fonts.sh  – Phase 6: Reports fonts, uifont.ali, cgicmd.dat (after first start)
│   ├── 30-configure_autostart.sh    – Autostart at boot: systemd unit + Node Manager controlled
│   │                                   start/stop scripts (templates in autostart_templates/)
│   ├── 40-oracle_forms_client_bundle.sh – Forms client bundle for Nginx /formsWeb: jlink Windows
│   │                                   runtime + CA, frmsal.jar, JACOB DLL, icon, manifest.json
│   ├── client_templates/            – FormsWeb-Install.cmd (bootstrap) + FormsWeb-Setup.ps1
│   │                                   (PS 5.1 installer/starter in %LOCALAPPDATA%, self-update)
│   ├── 99-oracle_deinstall_fmw.sh   – Teardown: remove FMW completely for a clean reinstall,
│   │                                   keeps a database on the same host (irreversible)
│   ├── oracle_software_version.conf – Pinned FMW/JDK/patch version numbers
│   ├── nginx-wls.conf.template      – Nginx reverse-proxy config template
│   ├── forms_templates/             – 6 editable Forms config templates + README
│   │                                   (default.env, formsweb.cfg, webutil.cfg, Registry.dat, res files)
│   ├── response_files/              – Silent-install response file templates
│   │                                   (domain_config.py, fr_install.rsp, cgicmd.dat)
│   ├── 15-deploy-test-report-forms_template.sh – Smoke test: minimal Forms module + Reports demo
│   │                                   (verified 2026-10-16)
│   └── docs/                        – Step-by-step detail documentation (00–14b, 20-testmodules,
│                                       30-autostart, 40-client distribution, 80-security,
│                                       90-validate, 99-deinstall)
│
├── 10-Monitoring/
│   ├── README.md                    – Concept: AI-assisted proactive monitoring + monthly CVE watch
│   └── cve_inventory.sh             – CVE watch step 1: components, patch cycle, JDKs, OS errata, advisories
│
├── 60-RCU-DB-19c/
│   ├── README.md                    – DB setup roadmap (Phase DB, between Phase 3 and 4)
│   ├── 00-root_db_os_baseline.sh    – DB-specific OS settings, preinstall RPM (auto-sudo)
│   ├── 01-db_install_software.sh    – Oracle 19c software-only install (runInstaller -silent)
│   ├── 02-db_patch_db_software.sh   – AutoUpgrade: download RU + create patched ORACLE_HOME
│   ├── 04-db_setup_listener.sh      – Configure the TNS listener
│   ├── 05-db_create_database.sh     – DBCA: CDB FMWCDB + PDB FMWPDB (AL32UTF8, AMM)
│   ├── 06-db_audit_setup.sh         – Pure Unified Auditing relink + purge job
│   ├── 07-db_fmw_tablespace.sh      – Optional: FMW_DATA tablespace pre-RCU
│   ├── 07b-db_rcu_profile.sh        – DB profile RCU_USER for the RCU schemas (no expiry/lock)
│   ├── rcu_user_profile.sql         – idempotent SQL for it (also used by 09-Install/07)
│   ├── rcu_registry_overview.sql    – all RCU prefixes of the DB: schemas, orphans, profile, expiry
│   ├── 08-db_auto_start.sh          – Configure DB/listener autostart (oratab, systemd)
│   ├── *.sql                        – Unified Audit policy scripts (generate/disable)
│   ├── environment_db.conf.example  – committed – DB-specific variables (DB_ORACLE_HOME, DB_SID, …)
│   ├── environment_db.conf          – gitignored – server-specific values
│   └── docs/                        – Step-by-step detail documentation
│
├── 80-FMW-Architecture/             – Background knowledge: how FMW works internally (findings
│   ├── README.md                       marked confirmed/assumption)
│   ├── weblogic_middleware_architecture.md – START HERE: homes, AdminServer, Node Manager,
│   │                                      system components, EM / Remote Console, logs, sources
│   ├── rcu_middleware_architecture.md – RCU schemas, OPSS/JPS + LDAP, registry, passwords,
│   │                                      profile RCU_USER, SecureFile/EBR, patching vs. upgrade
│   ├── report_engine_architecture.md – Reports in-process vs. standalone server, engines,
│   │                                      rwrun call flow (§5.1), performance parameters, history
│   ├── weblogic_outbound_connections.md – what the domain sends outside, external-DTD trap
│   ├── forms_runtime_architecture.md – Forms servlet / listener / frmweb per session, runtime
│   │                                      pooling, timeout chain, memory, logs, protocol history
│   ├── reports_server_discovery_multicast.md – Reports discovery via UDP multicast,
│   │                                      REP-50600 / REP-56040, prerequisites, diagnosis
│   ├── report_server_image_handling.md – images in reports, REPORTS_PATH, <folderAccess>
│   ├── reports_user_local_ldap.md   – secured standalone Reports server (embedded LDAP)
│   ├── em_principal_search_libovd.md – EM "Add Principal" empty, libOVD lock
│   ├── java_jlink_forms_env.md      – own Java runtime for the Forms client (jlink, jmods,
│   │                                      cross-build Windows on Linux, module list)
│   └── forms_jakob_webutil.md       – WebUtil + JACOB (OLE / Office automation)
│
└── 70-Customer-Projects/            – Customer-specific manual walkthroughs, not generated from
    │                                   the scripts above; see README.md for an index + further
    │                                   German installation guides (one subfolder per customer/scenario)
    ├── README.md
    ├── Forms12_reports12_patch_analyse_10_2026/
    │   └── README.md                     – Patch analysis Forms & Reports 12.2.1.19, CPU Oct 2026 +
    │                                         Java alert (server JDK 8, client JRE), manual
    └── Reports14_Only_manuall_install/
        ├── README.md                     – Reading order + one-sentence purpose per Kochbuch
        ├── OS_Kochbuch_de.txt             – OS prep for OL9 (packages, Java, oracle user, network)
        ├── FMW_Kochbuch_de.txt            – WebLogic/FMW install, patch, SSL rollout to Nginx
        ├── SSL_Kochbuch_de.txt            – Certificate creation/audit only
        ├── Reports_kochbuch_de.txt        – Reports install, RCU, domain, Reports Server config
        ├── Font_kochbuch_de.txt           – TrueType fonts + HTML parameter-form font path
        ├── WLS_Report_start_stop_kochbuch.txt – Simplest start/stop for day-to-day operation,
        │                                          no dependency on the IHateWeblogic lib
        ├── Tools_status_logs_kochbuch.txt – status.sh / show_all_logs.sh / show_errors.sh for
        │                                    /u01/oracle/tools (no lib, data in env.ini)
        ├── tools/                         – the scripts + env.ini (copied 1:1 to the server)
        └── Autostart_linux_middleware.txt – Start/stop at boot/shutdown via a systemd unit
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
- Architecture overview with verified Oracle sources (10.3 / 11g / 12c / 14c):
  [`80-FMW-Architecture/weblogic_middleware_architecture.md`](80-FMW-Architecture/weblogic_middleware_architecture.md)
- RCU / repository / OPSS with verified Oracle sources (RCU guide, Upgrade
  Assistant, OPatch, 11g Patch Set Assistant):
  [`80-FMW-Architecture/rcu_middleware_architecture.md`](80-FMW-Architecture/rcu_middleware_architecture.md)
- Working with Oracle Forms 14.1.2 (Web Configuration Parameters, Environment Variables, runtime pooling):
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/working-forms/index.html –
  digested with quotes in [`80-FMW-Architecture/forms_runtime_architecture.md`](80-FMW-Architecture/forms_runtime_architecture.md)
- Reports server / engines / `rwrun` with Oracle sources:
  [`80-FMW-Architecture/report_engine_architecture.md`](80-FMW-Architecture/report_engine_architecture.md)

## Troubleshooting

### Database login: ORA-12154 / ORA-12162

An alias login (`user/pwd@ALIAS`) in Forms or a report fails although the
alias is in "the" `tnsnames.ora`: the process reads another directory.
`./02-Checks/tns_admin_check.sh` compares `TNS_ADMIN` of `environment.conf`
with `default.env`, `rwserver.conf`, `reports.sh`, `setUserOverrides.sh`,
`.bash_profile` **and** the running processes, and names the script that
fixes each place ([02-Checks/README.md](02-Checks/README.md#tns_admin_checksh)).

### Reports / Forms performance and sessions

- Reports server slow, jobs waiting, failures: `05-ReportsPerformance/engine_perf_analyse.sh`
  ([05-ReportsPerformance/README.md](05-ReportsPerformance/README.md)).
- Forms sessions dropped, too many `frmweb`, timeouts: `06-FormsDiag/forms_perf_settings.sh`
  ([06-FormsDiag/README.md](06-FormsDiag/README.md), background
  [forms_runtime_architecture.md](80-FMW-Architecture/forms_runtime_architecture.md)).

### Font Problems

For detailed font troubleshooting in PDF generation see [04-ReportsFonts/README.md](04-ReportsFonts/README.md) – Section 11.

For font problems in the **HTML parameter form** (e.g. text rendered in the
Symbol font / Greek glyphs instead of the expected Latin text) see
[04-ReportsFonts/HTML_ParameterForm_Fonts.md](04-ReportsFonts/HTML_ParameterForm_Fonts.md)
– a separate font code path from PDF generation, with its own root cause and fix.

## Password Security Concept

Based on: https://www.pipperr.de/dokuwiki/doku.php?id=dba:passwort_verschluesselt_hinterlegen

The WebLogic admin password is encrypted with `openssl des3` using the machine's
disk UUID as key. The encrypted file `weblogic_sec.conf.des3` is machine-specific
and **must not be committed to git** (covered by `.gitignore`).

The same mechanism (`_write_secrets_file` / `load_secrets_file` in the lib)
holds all other secrets in the repository root – never in `environment.conf`:

| File | Content | Written by |
|---|---|---|
| `weblogic_sec.conf.des3` | WebLogic admin | `01-setup-interview.sh`, `00-Setup/weblogic_sec.sh` |
| `db_sys_sec.conf.des3` | DB SYS + RCU schema password | interview |
| `mos_sec.conf.des3` | My Oracle Support | interview, `00-Setup/mos_sec.sh` |
| `reports_users.conf.des3` | `monUser`, `RepRunner` | `12-oracle_reports_users.sh` |
| `embedded_ldap_sec.conf.des3` | embedded LDAP `cn=Admin` (`REPORTS_SECURITY=ldap`) | interview (13- sets it in the domain) |
| `reports_admin_sec.conf.des3` | Reports server admin `<identifier>` | interview, else random by `13- --apply` |
| `test_db_sec.conf.des3` | DB user of the smoke test | `15-` (asks once) |

## Report Security – Secure Invocation & Basic Hardening

By default the Reports Servlet (`rwservlet`/`getserverinfo`) is **unsecured** –
anyone who can reach the port can query server status or run reports. This is
important to fix before going live, not just a nice-to-have.

See [`09-Install/docs/12-weblogic-report-monitoring_user.md`](09-Install/docs/12-weblogic-report-monitoring_user.md)
for the full role-based security model: a three-tier WebLogic/OPSS permission
chain (Application Policy → Application Role → user in the Security Realm)
separating **monitoring** (`monUser` / `RW_MONITOR` – status queries only, no
reports) from **report execution** (`RepRunner` / `RW_EXECREPORTS` – runs
reports via `authid=` in `cgicmd.dat`, password never appears in the report
URL) from full **admin access** (`weblogic` / `RW_ADMINISTRATOR`). Automated
by `09-Install/12-oracle_reports_users.sh`; the same concept is also in the
German manual cookbook (Schritt 8) for customers installing by hand — see
[`70-Customer-Projects/`](70-Customer-Projects/README.md).

> **Since 2026-10-16 the default is a secured Reports server**
> (`REPORTS_SECURITY=ldap`, `13-`): `securityId` on the report job + the
> standalone server's identity store pointed to the WebLogic embedded LDAP –
> then `monUser`/`RW_MONITOR` (`getserverinfo`) and `RepRunner`/`RW_EXECREPORTS`
> (report jobs, via the `cgicmd.dat` key `default: … %* authid=…`) work as
> designed; calls without login get HTTP 499. Background:
> [`80-FMW-Architecture/reports_user_local_ldap.md`](80-FMW-Architecture/reports_user_local_ldap.md).
>
> **Live finding 2026-10-15** (still true for `REPORTS_SECURITY=identifier`):
> as long as the Reports server is **not**
> secured via `securityId` on the `<job>` element of `rwserver.conf`, the
> roles above do not apply to web commands. With `<webcommandaccess>`
> `no`/`L0`/`L1`, `getserverinfo`/`showjobs` then require the **server
> administrator** from `<identifier>` in `rwserver.conf` as `authid`
> (`rep_admin/...`); `authid=monUser/...` or the WebLogic admin return
> `REP-52262 Diagnostic output is disabled` (confirmed in the
> `CommandManager.checkDiagnostic` bytecode). See
> `09-Install/docs/13-reports-detail-settings.md`.
>
> `01-Run/rwserver_status.sh` and `05-ReportsPerformance/engine_perf_analyse.sh`
> call `getserverinfo` with `authid` (`--auth`, shared
> `01-Run/reports_server_lib.sh`, since 2026-10-17 / 2026-10-19).

## Open Items / TODO

Only what is still open (state 2026-10-23). Everything finished is described
in the folder READMEs and in `git log`; the review of 2026-10-19/20 is
summarised in each README ("Review 2026-10-19").

### Next: patch cycle CPU October 2026 (released 2026-10-20) + Security Alert CVE-2026-91403

[`00-patch-references.md`](09-Install/docs/00-patch-references.md) is
reworked for CPU Oct 2026 (CVE check, special case Java, patch list); the
CSPU Sep 2026 state is frozen in
[`00-patch-references_september_2026.md`](09-Install/docs/00-patch-references_september_2026.md)
(one snapshot per cycle, see "Patch cycle history" there).

- [ ] **Switch conf + scripts to October** – patch numbers are known (KA1182
  PDF + CPU426, 2026-10-22): SPB 40125898, OPatch 13.9.4.2.25, PERL 39951765,
  OHS 39987730, `JDK_VERSION_MIN=21.0.13.0.2`, and the **eight FMW
  Infrastructure bundle patches** (ADF, WebCenter Core, OWSM, FMW Control,
  OAMCLIENT, UMS, OPSS, LibOVD) that were missing in the September set –
  needs a new patch list for `05-`/`06-` (doc first). Then download,
  `07-Maintenance/81-`/`82-`, smoke test `15-`. Check whether SPU 39988381
  is contained in SPB 40125898.
- [ ] Part of that switch: the **OHS / WebGate** bundle patches (39987730 /
  39100536) – the binaries are in the Oracle Home although Nginx is the
  frontend (agreed: everything on disk gets patched; OHS CVE-2026-87347 9.6).
- [ ] JDK at `JDK_HOME`: target **21.0.13.0.2** (CPU426, Patch 40186074 /
  well-known 35702194, available by 23 Oct 2026), not 21.0.13 (affected by
  CVE-2026-91403). Set `JDK_VERSION_MIN="21.0.13.0.2"`,
  `04-oracle_pre_download.sh --apply --fresh-patches --mos` (check that the
  ZIP holds `jdk-21.0.13.0.2`), then `07-Maintenance/80-patch_java_os.sh
  --apply`. The bundled JDK of the Reports engines: see "FMW-bundled JDK"
  under Scripts.
- [ ] **Client JREs** (Java Web Start / FSAL) of the Forms users: CPU426 JRE
  (JRE 8u511 Patch 40186686 = `1.8.0_511-b26`, observed 2026-10-22; re-check
  after 23 Oct whether 18143322 then also delivers b26) via the customer's
  software distribution, same bitness as the WebUtil DLLs, test the
  code-signing trust after the update – JSSE runs on the client, see
  [forms_runtime_architecture.md §1.2](80-FMW-Architecture/forms_runtime_architecture.md#12-threat-model-of-a-client-side-tls-jsse-flaw).
- [ ] Confirm the CVE coverage of the patches in MOS KA1182 / CPU360
  (CPU Oct 2026: CVE-2026-83399 / 91323 / 4176 / 47065, all 9.8; the
  September CVEs 83021 / 83099 / 83020 are still unconfirmed too).
- [ ] `10-Monitoring/cve_inventory.sh --online` against the new advisory.

### Tests that need a client or a fresh install

- [ ] **Forms client distribution via URL** – rest of the Windows test plan
  ([concept 40 §8 / §12](09-Install/docs/40-forms_client_distribution.md)).
  **Done 2026-10-23 on a Windows client:** CA import into the user store,
  bootstrap `.cmd`, install into `%LOCALAPPDATA%`, shortcut with own icon,
  FSAL start of `test_form` with alias login; fixed on the way: non-ASCII
  profile path (`state.json` / Java arguments, setup 1.0.2).
  Open: update and self-update round, offline start, `-Rollback`, JACOB /
  Excel, `AllSigned` + Authenticode signature of the script.
- [ ] **Windows client**: Java Web Start start of the test form (FSAL done
  2026-10-23), signed vs. unsigned `jacob.jar`, revocation check
  of Java Web Start with a CA without CRL/OCSP, real OLE call (Excel);
  Forms **pool vs. session** criterion and RSS of a real session
  (`06-FormsDiag/forms_perf_analyse.sh`).
- [ ] `01-setup-interview.sh` interactively (questions `REPORTS_SECURITY`,
  embedded LDAP password, Reports server admin, `FORMS_TMP`).
- [ ] `13-` path that sets the embedded LDAP `cn=Admin` password in a fresh
  domain (bind fails → `setCredential` → AdminServer restart → re-run).
- [ ] `startStop.sh start-all` / `stop-all` through `fmw_ctl.sh`, and the
  "Node Manager running without autostart" path.
- [ ] `09-Install/07-` on a fresh database: `-databaseType EBR` with
  `-createRepository`, profile assignment right after RCU, FAIL path of the
  `db_securefile=FORCE` pre-check.
- [ ] Full Reports-only domain creation (`INSTALL_COMPONENTS=REPORTS_ONLY`,
  so far verified with WLST offline only).
- [ ] `08-SSL` modes `EASYRSA` and `REQUEST` end-to-end.
- [ ] HTML parameter form with `AL32UTF8` umlauts
  ([test plan §9](04-ReportsFonts/HTML_ParameterForm_Fonts.md)).

### Security hardening

- [ ] **WLS SSL listen ports with the demo certificate** (`WLS_FORMS` 9501,
  `WLS_REPORTS` 9512, bound to 127.0.0.1) – disable in `09-Install/08-`
  (plan in `09-Install/docs/08-oracle_setup_domain.md`).
- [ ] **Loopback binding** of the `frmweb` / `rwserver` sockets – every
  `frmweb` listens on an ephemeral port on all interfaces
  ([forms_runtime_architecture.md §1](80-FMW-Architecture/forms_runtime_architecture.md#1-the-parts));
  the firewall keeps them closed today.
- [ ] **Forms `maxRuntimeProcesses`** unset (Oracle: DoS risk) – 14- /
  interview should propose a value from RAM.
- [ ] **Reports web commands / `<identifier>` / `webcommandaccess`** – tests
  A–D and target design in
  [`09-Install/docs/81-reports_rwservlet_security.md`](09-Install/docs/81-reports_rwservlet_security.md),
  then align `13-`, doc 13, both cookbooks, `rwserver_status.sh`.
- [ ] **EM "Add Principal" finds no users** – libOVD config overwritten by the
  Reports server; SR draft local (`SR/`). Workaround: "Advanced Option" /
  WLST `grantAppRole`
  ([em_principal_search_libovd.md](80-FMW-Architecture/em_principal_search_libovd.md)).
- [ ] **Idea: configuration security scanner** for WebLogic / Forms / Reports
  (T3/IIOP, debug configs, web commands, demo certificates …) –
  [10-Monitoring/README.md](10-Monitoring/README.md).

### Scripts

- [ ] **FMW-bundled JDK** (`oracle_common/jdk` 17.0.12, OPatch component
  `oracle.jdk`, used by the Reports server/engines and the Forms/Reports
  tools): find the MOS patch number (`FMW_JDK_PATCH_NR` in
  `oracle_software_version.conf`), then download in `04-` and apply in
  `06-`/`82-`. The JDK at `JDK_HOME` is done (`80-patch_java_os.sh --apply`).
  State 2026-10-20: the Oracle Support AI knows no published patch and no
  Doc ID; it says "Do not manually replace that JDK directory" – only a MOS
  patch for component `oracle.jdk` / FMW 14.1.2 is supported, and points to
  the KA1182 / CPU October 2026 patch-availability rows. **State
  2026-10-22:** the KA1182 of October 2026 (PDF) has no patch for the
  bundled JDK (only Java SE for `JDK_HOME`) → open an SR with the question.
- [ ] **13- `rwserver.conf`: `engLife` / `maxIdle` / engine `jvmOptions`**
  not taken from `environment.conf` – values tuned with
  `05-ReportsPerformance/engine_perf_settings.sh --apply` are lost on the next
  `13- --apply` (proposal `REPORTS_ENGINE_LIFE`, `REPORTS_ENGINE_JVM_OPTIONS`;
  evaluate a default `engineResponseTimeOut`).
- [ ] **Font check in the smoke test `15-`**: a font test report (Arial,
  Helvetica, Times New Roman, Courier New, Tahoma, Liberation, DejaVu)
  checked with `04-ReportsFonts/pdf_font_verify.sh`.
- [ ] `07-Maintenance/ConfigBackup/` retention (`--keep N`); collect the
  `*.bak_<ts>` copies our scripts leave next to Oracle files.
- [ ] `time-taken` in the WLS_FORMS access log (response times for
  `06-FormsDiag/forms_perf_analyse.sh`).

### Monitoring (phase 9)

- [ ] `10-Monitoring/cve_watch.sh` (risk matrix parser, fixture test),
  notification, Claude analysis, uniform machine-readable output of the
  01–07 scripts – [10-Monitoring/README.md](10-Monitoring/README.md).
- [ ] Scheduled certificate expiry check (`08-SSL/ssl_local_ca.sh status`,
  `ssl_config.sh --expiry` – exit codes are cron-ready).

### Customer feedback / watch

- [ ] **Next customer installation:** run `09-Install/04-oracle_pre_checks.sh`
  (check 10: does a blocked request fail fast or hang?) and
  `02-Checks/egress_check.sh --capture 300` during the first start – which
  components fetch external DTDs there
  ([weblogic_outbound_connections.md](80-FMW-Architecture/weblogic_outbound_connections.md)).
- [ ] **OAM external DTD (SR):** colleagues fill in OAM version / component /
  XML file + customer thread dump in the local SR draft
  (`SR/oam_external_dtd/`, reproducer without root included).

- [ ] **Customer cookbook check**: does the graphical Configuration Wizard
  also create random Node Manager credentials? If yes,
  `Reports_kochbuch_de.txt` / `Autostart_linux_middleware.txt` need the same
  fix as `11-oracle_nodemanager.sh`.
- [ ] Customer installation 2026-10-15: which of the changes (firewall
  `14027/udp`, IPv6 per interface, multicast pre-check) fixed `REP-50600`
  there is not confirmed yet.
- [ ] **Watch MOS KB873815 / Bug 38892485** (Forms relink fails after a
  Reports QPR on OL9, `libzrc.so` vs. glibc 2.34): workaround in
  `06-oracle_patch_forms_reports.sh` stays until Oracle ships a fix.
