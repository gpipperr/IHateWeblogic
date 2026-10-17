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

**`[█████████████████░░░]` ~85 % complete** – phases 1–7 are implemented and the
whole install chain is live-tested end-to-end incl. the smoke test, phase 8 is
nearly done, phase 9 is concept-only.

How the ~85 % is estimated (state 2026-10-17): phases 1–7 count as done
(7 × ~11 %, no stubs left: `rwrun_trace.sh` implemented, `display_check.sh`
dropped, `rwserver_status.sh` with `authid`), phase 8 about nine tenths
(backup/restore, WLS/Forms/Reports patching, RCU repository theory, profile
`RCU_USER`, pre-checks and `rcu_repository_check.sh` incl. Data Pump backup
done; JDK upgrade automation missing), phase 9 zero; minus the open security
items (EM user search, web-command tests, JACOB client test – the signing
itself is implemented since 2026-10-17).

| # | Phase | Status |
|---|---|---|
| 1 | Installation | ✅ Done |
| 2 | Configuration & First Start | ✅ Done – incl. secured Reports server (`REPORTS_SECURITY=ldap`), autostart, NM-aware `startStop.sh`, smoke test `15-` (Forms XML → FMX, report → PDF) |
| 3 | Check Logs | ✅ Done (incl. `rwrun_trace.sh`; `display_check.sh` dropped – tools need no X) |
| 4 | Set Up SSL | ✅ Done |
| 5 | Solve Font Problems | ✅ Done |
| 6 | Check Reports Performance | ✅ Done |
| 7 | Check Forms | ✅ Done |
| 8 | Maintenance & Patches | 🚧 Mostly done — backup/restore + WLS/Forms/Reports patching for an already-running environment (`07-Maintenance/80-82`) implemented; RCU repository: theory, profile `RCU_USER` (no password expiry), `db_securefile`/EBR pre-checks, `rcu_repository_check.sh` (check + Data Pump backup); still missing: automated JDK upgrade (`80-` is read-only for now) |
| 9 | Proactive Monitoring | 📝 Concept only – see [10-Monitoring/README.md](10-Monitoring/README.md) |

Details per phase: [Lifecycle Overview](#lifecycle-overview) below.

> **Work in Progress** – This library is under active development.
> Not all scripts are fully implemented yet.
> **Live-tested 2026-10-14/15:** a clean script-by-script rebuild on Oracle
> Linux 9 (FMW 14.1.2, CSPU Sep 2026 patch level, local 19c repository DB) ran
> the whole `09-Install/` chain end-to-end – Phase 0 through `14b-` plus the
> autostart `30-` (domain running under systemd + Node Manager, Reports engines
> idle, Forms servlet up). The bugs found on the way are fixed and committed;
> what is still open is listed under [Open Items / TODO](#open-items--todo).
> **2026-10-16:** secured standalone Reports server (WebLogic users/roles via
> the embedded LDAP, JVM fixes for the slow first request), all passwords
> from the interview in `*.des3` files, Forms/Reports directory layout under
> `$ORACLE_BASE`, `formsweb.cfg` keeps Oracle's 14.1.2 sections (Java Web
> Start / FSAL), smoke test `15-` verified end-to-end, `startStop.sh` starts
> through the Node Manager.
> **2026-10-17:** RCU repository analysed ([`rcu_middleware_architecture.md`](80-FMW-Architecture/rcu_middleware_architecture.md)):
> regular patches leave the schemas untouched; schema profile `RCU_USER`
> against the 180-day password expiry of `DEFAULT`; explicit RCU database type
> `RCU_DB_TYPE=EBR`; pre-check `db_securefile=FORCE` (ORA-43853 on the first
> RCU run); prefix overview of the schema version registry.
> The diagnostic folders `02-`…`06-` were not part of that run.
> Use with caution and verify output before applying any changes (`--apply`).
> Contributions and bug reports welcome.

> **Target Version:** This library targets **Oracle Fusion Middleware (FMW) 14.1.2 and later**
> (Oracle Forms 14c, Reports 12c codebase under 14c naming, WebLogic 14c). Earlier versions
> (12c domains, pre-14.1.2 WebLogic) are not supported.

> **Current patch numbers?** → [`09-Install/docs/00-patch-references.md`](09-Install/docs/00-patch-references.md)
> has the full, current patch list (CSPU September 2026 as of this writing) plus the MOS Doc-ID
> reference table — check this first before a new patch cycle or when `07-Maintenance/81-`/`82-`
> report missing patch ZIPs.

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
| Phase 8 (Patches) | JDK upgrade (`07-Maintenance/80-`) is read-only/checklist |
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
| `07-Maintenance/`     | Config backup/restore, patching an already-running environment |
| `08-SSL/`             | SSL certificate lifecycle: prepare, deploy, audit    |
| `09-Install/`         | Full installation flow: OS → WLS → Forms/Reports → Domain → runtime config |
| `10-Monitoring/`      | Concept only – AI-assisted proactive monitoring (Claude API) |
| `60-RCU-DB-19c/`     | Oracle 19c minimal RCU database: OS baseline → install → patch (AutoUpgrade) → create DB → Unified Audit |
| `70-Customer-Projects/` | Customer-specific manual walkthroughs (German Kochbuch `.txt` files), independent of the scripts above |
| `80-FMW-Architecture/` | Background: how Forms/Reports/WebLogic work internally – start with [`weblogic_middleware_architecture.md`](80-FMW-Architecture/weblogic_middleware_architecture.md) (homes, AdminServer / Node Manager / system components, consoles, log locations), RCU / OPSS: [`rcu_middleware_architecture.md`](80-FMW-Architecture/rcu_middleware_architecture.md) – findings, not procedures |

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
│   ├── reports_network_scan.sh      – Reports multicast discovery check + active scan for Reports
│   │                                   servers per port (DiagServerLocator), read-only
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
│   ├── README.md                    – Backup categories, manifest format, restore workflow,
│   │                                   patching an already-running environment (Phase 8)
│   ├── backup_config.sh             – Backup all config files before changes:
│   │                                   ConfigBackup/YYYYMMDD_HH24MI/<type>/ per config type
│   ├── restore_config.sh            – List available backups and restore a selected set (--apply)
│   ├── 80-patch_java_os.sh          – Java/OS layer: read-only check + manual upgrade checklist
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
│                                       30-autostart, 80-security, 90-validate, 99-deinstall)
│
├── 10-Monitoring/
│   └── README.md                    – Concept only: AI-assisted proactive monitoring (Claude API)
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
│   │                                      performance parameters, history, broadcast idea
│   ├── reports_server_discovery_multicast.md – Reports discovery via UDP multicast,
│   │                                      REP-50600 / REP-56040, prerequisites, diagnosis
│   ├── report_server_image_handling.md – images in reports, REPORTS_PATH, <folderAccess>
│   ├── reports_user_local_ldap.md   – secured standalone Reports server (embedded LDAP)
│   ├── em_principal_search_libovd.md – EM "Add Principal" empty, libOVD lock
│   └── forms_jakob_webutil.md       – WebUtil + JACOB (OLE / Office automation)
│
└── 70-Customer-Projects/            – Customer-specific manual walkthroughs, not generated from
    │                                   the scripts above; see README.md for an index + further
    │                                   German installation guides (one subfolder per customer/scenario)
    ├── README.md
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

## Troubleshooting

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
> This is separate from the `01-Run/rwserver_status.sh` gap in Open Items
> below – that script's own `getserverinfo` call is unauthenticated and
> needs `authid=` support added.

## Open Items / TODO

Status 2026-10-17 after the clean rebuild 2026-10-14/15 and the follow-up
work (details of every fix: `git log`).

### Not yet live-tested (built, waiting for a fresh install / full restart)

- [ ] `01-setup-interview.sh` interactively (new questions `REPORTS_SECURITY`,
  embedded LDAP password, Reports server admin, `FORMS_TMP`).
- [ ] `13-` path that sets the embedded LDAP `cn=Admin` password in a fresh
  domain (bind fails → `setCredential` → AdminServer restart → re-run).
- [ ] `startStop.sh start-all` / `stop-all` through `fmw_ctl.sh`, and the
  "Node Manager running without autostart" path.
- [ ] Start of the test form on a client with Java Web Start / FSAL (server
  side verified: JNLP, `fsal.htm`, `frmsal.jar` via NGINX).
- [ ] `09-Install/07-` on a fresh database: `-databaseType EBR` with
  `-createRepository`, profile assignment right after RCU, FAIL path of the
  `db_securefile=FORCE` pre-check (no registry yet). Tested so far: `--profile`,
  pre-flight with `-listSchemas -databaseType EBR`, `FORCE` + existing registry.

### Test host follow-ups

- [x] **Reboot test of the autostart** (`30-configure_autostart.sh`) – passed
  2026-10-15: after the reboot the listener and the repository DB came up first
  (08:43:12–08:43:25), then `fmw-<domain>.service`; `fmw_ctl.sh status` showed
  AdminServer, WLS_FORMS, WLS_REPORTS and the Reports server RUNNING.
- [x] **Smoke test `09-Install/15-deploy-test-report-forms_template.sh`**
  (2026-10-16): verified end-to-end on the rebuilt domain – Forms XML → FMB →
  FMX, Reports XML → RDF → `rwservlet` → PDF, no X display. Fixes: instance
  wrappers, `FORMS_API_TK_BYPASS=TRUE`, TNS alias (Forms tools split `userid`
  at `/`), schema-conform `test_form.xml`, DB credentials in
  `test_db_sec.conf.des3`. See `09-Install/docs/20-forms_reports_testmodules.md`.
- [ ] **Customer cookbook check**: does the graphical Configuration Wizard also
  create random Node Manager credentials (it does not show the Node Manager
  screen unless "Node Manager" is ticked under Advanced Configuration)? If yes,
  `Reports_kochbuch_de.txt` / `Autostart_linux_middleware.txt` need the same
  fix as `11-oracle_nodemanager.sh`.

### Reports servlet security – own topic (analyse in detail later)

- [x] **Secured standalone Reports server** (2026-10-16): `securityId` +
  JSE identity store (`jps-config-jse.xml`) = WebLogic embedded LDAP –
  `monUser`/`RW_MONITOR` and `RepRunner`/`RW_EXECREPORTS` work; JVM fixes
  (process reaper, ORB connect timeout) for the slow first request;
  `cgicmd.dat` key `%* authid=`. `13-` (`REPORTS_SECURITY=ldap`), `14b`,
  docs 13/14b/81, Reports cookbook 9.7b/9.9b, `Reports_security.txt` 7b.
  Background: [`80-FMW-Architecture/reports_user_local_ldap.md`](80-FMW-Architecture/reports_user_local_ldap.md).
- [ ] **EM "Add Principal" finds no users** – libOVD config overwritten by the
  Reports server; still empty with the LDAP identity store; SR draft local
  (`SR/`). Workaround: "Advanced Option" / WLST `grantAppRole`.
- [x] **`rwserver.conf` `<identifier>`** (2026-10-16) – user/password from
  `reports_admin_sec.conf.des3` (asked by `01-setup-interview.sh`, else
  generated randomly by `13- --apply`); no fixed password in the repo.

- [ ] **Web commands / `<identifier>` / `webcommandaccess`** – analysis and plan in
  [`09-Install/docs/81-reports_rwservlet_security.md`](09-Install/docs/81-reports_rwservlet_security.md):
  with `no`/`L0`/`L1` and a server without `securityId` on `<job>`, `getserverinfo`
  only accepts the server administrator from `<identifier>` (`monUser`, WebLogic
  admin → `REP-52262`); `L0` is not "open" as the cookbook claims; a customer who
  copied the cookbook from 9.7 on got an empty `<identifier>`. Open: behaviour
  without/with empty `<identifier>`, `L2`, secured server via `securityId`
  (tests A–D in the doc), then decide the target design (open first test →
  separate hardening step) and align `13-`, doc 13, both cookbooks and
  `rwserver_status.sh`. The two related items below are part of this topic.

### Script gaps found during the rebuild

- [x] **JDK path resolved in the domain** (2026-10-15): WLST
  `createDomain`/`updateDomain` write the resolved JDK directory
  (`jdk-21.0.12.1`) instead of the symlink (`jdk-21`) – not only into
  `setDomainEnv.sh`, `setNMJavaHome.sh`, `nodemanager.properties`, but also the
  Forms instance scripts and `init-info/*`; the installer into
  `$ORACLE_HOME/oui/`. New `07-Maintenance/domain_jdk_path.sh` (read-only /
  `--apply` with backup), called by `08-`; hint in `02b- --upgrade-jdk` and
  `80-`. Live: 22 files, after the restart all JVMs run from `jdk-21/bin/java`.
- [x] **`01-Run/startStop.sh` Reports system components** (2026-10-15): type
  `REPORTS` from config.xml (`ReportsServerComponent`), start/stop via WLST
  `nmConnect` + `nmStart`/`nmKill` (no password prompt), order
  … Managed → Reports → OHS / OHS → Reports → Managed …; status via
  `rwserver server=<name>`. Live: single stop/start, stop-all, start-all.
  Also fixed: the status after an action used the `ss` snapshot from the
  script start ("RUNNING port" for stopped servers).
- [x] **`startStop.sh` vs. systemd autostart** (2026-10-16): with the
  autostart configured, start/stop of AdminServer, managed servers, Reports
  servers and `start-all`/`stop-all` go through `fmw_ctl.sh` (Node Manager);
  NM running without autostart: `nmStart` / `start()` via the AdminServer.
  New status column `Ctrl` (`NM`/`script`) + warning for servers running
  past the NM; those are shut down via the AdminServer first. Live:
  WLS_FORMS `script` → stop → start → `NM`, repserver01 stop/start via
  `fmw_ctl.sh`. Not live-tested: the "NM without autostart" path.
- [x] **`rwserver.conf` server administrator** (2026-10-16): see
  `<identifier>` above – `reports_admin_sec.conf.des3`.
- [x] **Reports server security decision** (2026-10-16): `REPORTS_SECURITY`
  in `environment.conf`, asked by `01-setup-interview.sh` – `ldap` (default:
  `securityId` + LDAP identity store, `cn=Admin` password →
  `embedded_ldap_sec.conf.des3`, set in the domain by `13-`) or `identifier`
  (not secured, web commands only for the `<identifier>` admin).
- [x] **Reports-only installs in `08-oracle_setup_domain.sh`** (2026-10-15):
  templates and managed servers follow `INSTALL_COMPONENTS` (REPORTS_ONLY: no
  `forms_template.jar` / `WLS_FORMS` / `forms1`; FORMS_ONLY: no Reports
  templates / `WLS_REPORTS`); `14-` skips itself with REPORTS_ONLY. Verified
  with WLST offline (templates + server list, no `writeDomain`); a full
  Reports-only domain creation is still untested.
- [x] **Forms WebUtil (jacob) – download + install** (2026-10-15): switch
  `FORMS_WEBUTIL_JACOB=true|false` (default false); `04-` downloads JACOB 1.21
  from GitHub (SHA-256), `14-` installs jar + DLLs (size check). Also fixed:
  `webutil.cfg` is now Oracle's file + template overrides – the template had
  dropped all `install.syslib.*` entries. Background:
  `80-FMW-Architecture/forms_jakob_webutil.md`.
- [x] **Forms WebUtil (jacob) – signing** (2026-10-17): own root CA
  `08-SSL/ssl_local_ca.sh` (one root for the Nginx TLS certificate and the
  code-signing certificate, clients import only the root); `14-` signs
  `jacob.jar` with `FORMS_SIGN_KEYSTORE` (PKCS12 from the own CA, a company CA
  or a public CA; password `forms_sign_sec.conf.des3`, optional TSA), adds the
  manifest security attributes, verifies, activates. `ssl_prepare_cert.sh
  LOCALCA`; patch cycle in `07-Maintenance/README.md` re-runs `14-`.
  Live-tested on the test host incl. Nginx deployment.
- [ ] **Forms WebUtil (jacob) – Windows client test**: import the root
  (`ca.cer`), FSAL with unsigned vs. signed `jacob.jar`, Java Web Start with
  the signed jar (revocation check with a CA without CRL / OCSP?), real OLE
  call (Excel).

### Findings from the customer installation (2026-10-15)

- [x] **A1 – Firewall: UDP port for the Reports multicast discovery.** With
  firewalld active the Reports server receives no multicast packet and stops with
  `REP-50600 Broadcasting is disabled` (Node Manager restart loop).
  `01-root_os_baseline.sh` now checks/opens `REPORTS_BROADCAST_PORT`/udp
  (default 14027), `13-oracle_setup_reports.sh` checks it again; docs 00/13,
  OS + Reports cookbook (known problem REP-50600 incl. `tcpdump` diagnosis).
  Which of the changes fixed it at the customer is not confirmed yet.
- [x] **A2 – IPv6 per network interface.** `all`/`default` = 1 is not enough:
  an existing interface keeps its own value and NetworkManager re-enables IPv6
  (customer: `ens33=0` with `fe80::`, JVMs bound via `[::ffff:127.0.0.1]`).
  `00-root_os_network.sh` reports every interface + NM `ipv6.method`,
  `01-root_os_baseline.sh --apply` sets it at runtime and via
  `nmcli … ipv6.method disabled`; docs 00, OS cookbook.
- [x] **A3 – Multicast pre-check before the first Reports server start** –
  `13-oracle_setup_reports.sh`: route to `228.5.6.7` (not `lo`), `MULTICAST`
  flag, self-test (send + receive one datagram on the broadcast port, like the
  Reports server does → FAIL instead of a later REP-50600; skipped while a
  Reports server runs – it would log REP-50125), 10 s passive listen for foreign
  senders (hint only – Reports servers send only while starting, ~7 packets,
  confirmed 2026-10-15). Full uniqueness of the port in the subnet still cannot
  be proven.
- [x] **A4 – `13-root_reports_fix.sh`**: missing `libnsl.so.3` → hint that
  `libnsl2` is AppStream-only, whether AppStream is enabled, offline RPM variant.
- [x] **A5 – `11-oracle_nodemanager.sh`**: tests `nmConnect` with the admin
  credentials at the end (host/port/type from `nodemanager.properties`);
  after a credential change in the same run `--apply` offers a Node Manager
  restart and repeats the test (customer: `connect()` worked, `nmConnect()`
  did not). Tested on the test host: OK path and wrong-password path.
- [x] **A6 – way B in `docs/80-oracle_security.md` 5.2** (clear text in
  `nm_password.properties`) live-tested 2026-10-15: NM hashes it at the next
  start, `nmConnect` OK, running servers unaffected.
- [x] **C5 – `00-Setup/init_env.sh`**: DB detection from `jps-config.xml`
  returned empty `DB_HOST`/`DB_SERVICE` – it only parsed a lower-case TNS
  descriptor, but the domain stores EZConnect (`@//host:port/service`). Now
  both forms, case-insensitive (2026-10-15); doc 00-environment-setup.
- [x] **D2 – test host**: `~oracle/oracle-WebLogicConfig.properties` +
  `oracle-WebLogicKey.properties` (from a `storeUserConfig()` test) were WLST's
  default credentials and silently hid missing `boot.properties` / wrong NM
  passwords in tests – removed 2026-10-15 (nothing in the library depends on
  them; the autostart uses its own key files, `fmw_ctl.sh status` OK
  afterwards). Manual `startComponent.sh` on the test host now asks for the NM
  password again unless `storeUserConfig` is used.

### Older open items

- [x] **rwservlet authentication** (`01-Run/rwserver_status.sh`, 2026-10-17):
  `--auth auto|mon|admin|none` – `monUser` (`reports_users.conf.des3`) with
  `REPORTS_SECURITY=ldap`, else the `<identifier>` admin
  (`reports_admin_sec.conf.des3`); password via curl config on stdin. Also
  fixed: engine values were read from the URL engine, engine count looked
  for `rwengine` processes (14.1.2: Java children of `rwserver`), the
  standalone server's own `rwserver.conf` is used.

- [x] **`02-Checks/display_check.sh`** – dropped 2026-10-17: the Forms tools
  (`FORMS_API_TK_BYPASS=TRUE`) and the Reports tools (`REPORTS_DEFAULT_DISPLAY=YES`,
  instance wrappers) need no X display (smoke test 2026-10-16).

- [x] **`01-Run/rwrun_trace.sh`** (2026-10-17): one report with `rwrun.sh` of
  the ReportsTools instance + `TRACEOPTS`, optional ODL `TRACE:32` (logging.xml
  restored), `userid` via cmdfile; result directory with output, trace, ODL
  excerpt, new ADR incidents.

- [x] **Repository schema patching** (2026-10-17) – theory
  ([`80-FMW-Architecture/rcu_middleware_architecture.md`](80-FMW-Architecture/rcu_middleware_architecture.md)):
  regular patches (SPB/CSPU/one-offs, also September 2026) do **not** touch the
  RCU schemas; only a version upgrade uses the Upgrade Assistant.
  `07-Maintenance/rcu_repository_check.sh`: read-only check of registry,
  accounts (profile/expiry), data sources (login), service table; `--apply` =
  Data Pump export of the schemas + `SYSTEM.SCHEMA_VERSION_REGISTRY$`.
- [x] **Password expiry of the RCU schemas** (2026-10-17): profile `DEFAULT`
  (19c: 180 days) → own profile `RCU_USER` (no expiry, no lock):
  `60-RCU-DB-19c/07b-db_rcu_profile.sh`, `09-Install/07-` assigns it after RCU
  (`--profile` for existing repositories), Reports cookbook step 3. Applied on
  the test host.
- [x] **RCU database type explicit** (2026-10-17): silent RCU without
  `-databaseType` created EBR schemas, the GUI may preselect "Oracle Database"
  → `RCU_DB_TYPE` (default `EBR`) in `environment.conf`/interview, always passed
  by `09-Install/07-`; prefix overview shows EBR per prefix; `db_securefile=FORCE`
  pre-check (ORA-43853 on the first RCU run). See the RCU architecture doc §4.2/4.3.

- [ ] **Watch MOS KB873815 / Bug 38892485** (Forms relink fails after a Reports
  QPR on OL9, `libzrc.so` vs. glibc 2.34): no fix patch yet – the workaround in
  `06-oracle_patch_forms_reports.sh` stays until Oracle ships one.

- [ ] **`10-Monitoring/`** – concept only, not implemented yet.
  See [10-Monitoring/README.md](10-Monitoring/README.md) for the planned Claude-assisted
  proactive monitoring design.
