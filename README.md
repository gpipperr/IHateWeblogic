---
title: "Oracle Forms & Reports 14c on WebLogic 14.1.2 – Install, Patch & Harden Scripts"
description: "Open-source bash scripts to install, patch, diagnose and harden Oracle Forms & Reports 14c on WebLogic 14.1.2 and Oracle Linux 9 – with APEX/ORDS side by side."
---

# IHateWeblogic – Oracle Forms & Reports Diagnostic Scripts

[![lint](https://github.com/gpipperr/IHateWeblogic/actions/workflows/lint.yml/badge.svg)](https://github.com/gpipperr/IHateWeblogic/actions/workflows/lint.yml)

> [!IMPORTANT]
> **For Oracle Fusion Middleware 14.1.2 and later only** – Oracle Forms 14c,
> Oracle Reports 14c (12c code base under the 14c name), WebLogic 14c.
> 12c domains and WebLogic before 14.1.2 are **not supported**.
> Moving from 12c: [docs/migration_forms_reports_to_14c.md](docs/migration_forms_reports_to_14c.md).

<p align="center">Made by <a href="https://www.pipperr.info/" target="_blank" rel="noopener"><img src="assets/IHateWeblogic_logo.png" alt="IHateWeblogic logo" width="160"></a> Gunther & Claude </p>

Author: Gunther Pipperr | https://pipperr.de | License: Apache 2.0

Independent community project – not affiliated with Oracle. See
[Disclaimer & Acknowledgements](#disclaimer--acknowledgements).

<pre>
<b>I</b> – <b>I</b>nnovation
<b>H</b> – <b>H</b>elps
<b>A</b> – <b>A</b>dmins
<b>T</b> – <b>T</b>o
<b>E</b> – <b>E</b>nhance
<b>W</b> – <b>W</b>eblogic
<b>B</b> – <b>B</b>ased
<b>L</b> – <b>L</b>ifecycle
<b>O</b> – <b>O</b>perations
<b>G</b> – <b>G</b>overnance
<b>I</b> – <b>I</b>ntegration
<b>C</b> – <b>C</b>ontrol
</pre>
**I**nnovation **H**elps **A**dmins **T**o **E**nhance **W**eblogic-**B**ased **L**ifecycle **O**perations, **G**overnance, **I**ntegration & **C**ontrol => [IHateWeblogic.md](IHateWeblogic.md)

## Project Status

> **Work in Progress** – This library is under active development.

**`[███████████████████░]` ~96 % complete** (state 2026-11-06) – phases 1–7
are implemented and the whole install chain is live-tested end-to-end incl.
the smoke test; phase table, how the ~96 % is estimated and what ran live at
customers: [docs/project_status.md](docs/project_status.md).

## Target Picture – Forms and APEX side by side – the main idea behind this installation

A modern Oracle Forms environment is not "Forms or APEX" but **Forms and
APEX on the same database**, each where it is strongest:

![target-picture](diagrams/target-picture.svg?v=d9b389b6)
<sub>Source: [diagrams/target-picture.prompt](diagrams/target-picture.prompt) · [D2](diagrams/target-picture.d2)</sub>

<details><summary>ASCII version</summary>

```ascii name=target-picture
                 users (browser / FSAL)
                          |  HTTPS
              +---------- Nginx (TLS, one host name) ----------+
              |                       |                         |
        /forms (WLS_FORMS)     /reports (WLS_REPORTS)     /ords (ORDS 26.3)
         Oracle Forms 14c       Oracle Reports              Oracle APEX 26.2
              |                       |                         |
              +-------------- Oracle Database --------------------+
                     one schema, one PL/SQL business logic
```

</details>

| Use | Tool | Users |
|---|---|---|
| **Case processing** – the existing, proven business logic, heavy data entry, power users | **Oracle Forms 14.1.2** (FSAL / Java Web Start) | the departments that work in it all day |
| **Data capture** – simple forms, self-service, mobile, occasional users | **Oracle APEX 26.2** (via **ORDS 26.3**) | everyone in the company, in the browser |
| **Reporting** – dashboards, interactive reports, exports | **Oracle APEX** (and Oracle Reports for the classic print output) | everyone |

This is the intention of a good, future-proof Oracle strategy for a Forms
customer: keep the investment in Forms and its PL/SQL logic, open the data
to everyone with APEX, and keep everything on the Oracle database – instead
of replacing it piece by piece with other platforms (background and appeal:
[IHateWeblogic.md](IHateWeblogic.md#why-forms--reports-still-matter--an-appeal)).
Status in this library: manual installation in
[`12-APEX-Ords/README.md`](12-APEX-Ords/README.md) (ORDS standalone homes
`ords_1` / `ords_2`, images copied to `/srv/apex`, Nginx `/ords` + `/i/`);
the automation is an [open item](TODO.md).

## Start here

**What:** a Bash library for the whole lifecycle of **Oracle Forms &
Reports 14.1.2** on Oracle Linux – analyse and fix an existing environment,
install a new one from an empty host, patch, harden, monitor. Every script
is read-only by default and writes only with `--apply`.
**For whom:** administrators and DBAs who run Forms & Reports.

Three ways in:

| I want to … | Start with |
|---|---|
| analyse an existing environment (also a customer's) | the tools ZIP – [70-Customer-Projects/tools](70-Customer-Projects/tools/README.md); on the host itself: [first run, required order](docs/forms_reports_installation_steps.md#first-run-on-an-existing-environment--required-order) |
| install Forms & Reports 14c from an empty host | [09-Install/README.md](09-Install/README.md) – the install chain; overview: [lifecycle](docs/forms_reports_installation_steps.md#lifecycle-overview) |
| understand why it behaves that way | [80-FMW-Architecture/](80-FMW-Architecture/README.md) – background articles with diagrams |
| fix a known problem | DB login `ORA-12154` / `ORA-12162`: [tns_admin_check.sh](02-Checks/README.md#tns_admin_checksh) · fonts in PDF / HTML parameter form: [04-ReportsFonts §11](04-ReportsFonts/README.md#11-troubleshooting) · Reports slow, jobs waiting: [05-ReportsPerformance](05-ReportsPerformance/README.md) · Forms sessions dropped, timeouts: [06-FormsDiag](06-FormsDiag/README.md) |

## Moving from 12c to Forms & Reports 14c – the process in three steps

Three steps: extract and analyse the old environment with the tools ZIP,
build 14c with the customer's master data, analyse again and harden
security – process, order on the new host and links:
[docs/migration_forms_reports_to_14c.md](docs/migration_forms_reports_to_14c.md).

## Setup

The first three steps (detect the environment, store the WebLogic password,
run the checks):
[docs/forms_reports_installation_steps.md](docs/forms_reports_installation_steps.md#setup).

### Lifecycle Overview

The numbered folders follow the lifecycle of an installation from an empty
machine to monitoring (phases 1–9), with the folder roles (analyse + fix /
build / monitor) and the known gaps:
[docs/forms_reports_installation_steps.md](docs/forms_reports_installation_steps.md#lifecycle-overview).

Documentation:

| File | Content |
|---|---|
| [docs/migration_forms_reports_to_14c.md](docs/migration_forms_reports_to_14c.md) | 12c → 14c in three steps |
| [docs/project_status.md](docs/project_status.md) | status per phase, live tests |
| [docs/forms_reports_security.md](docs/forms_reports_security.md) | security & patch status, current cycle |
| [docs/forms_reports_sizing.md](docs/forms_reports_sizing.md) | disk sizing, memory and processes |
| [docs/forms_reports_installation_steps.md](docs/forms_reports_installation_steps.md) | lifecycle, folder roles, known gaps, first run, setup |
| [docs/general_security.md](docs/general_security.md) | password concept, secure report invocation |

## Security & Patch Status

Oracle ships security fixes every month – check the current cycle before
every installation and every patch run. Current cycle (CPU October 2026 +
Security Alerts, state 2026-10-26), patch lists and what matters in it:
[docs/forms_reports_security.md](docs/forms_reports_security.md).

> **Live-tested** on Oracle Linux 9 / FMW 14.1.2 (CPU Oct 2026, local 19c
> repository DB): clean script-by-script rebuild of the whole `09-Install/`
> chain incl. autostart and smoke test (2026-10-14/16), secured standalone
> Reports server (2026-10-16), RCU repository analysis (2026-10-17), review of
> all analyse + fix folders and `08-SSL` against the Oracle docs (2026-10-19/20),
> Forms client distribution via URL + first Windows FSAL session, one
> `TNS_ADMIN` for all processes and the loopback-only / clone-capable domain
> (2026-10-22/23), at a customer the localhost hardening of an existing domain
> and a VM clone with a new RCU prefix (2026-11-09/10) – [Folder Roles](docs/forms_reports_installation_steps.md#folder-roles), background in
> [`80-FMW-Architecture/`](80-FMW-Architecture/README.md). Details of every
> fix: `git log`; what is still open: [TODO.md](TODO.md).
> Use with caution and verify output before applying any changes (`--apply`).
> Contributions and bug reports welcome.

### Report Security – Secure Invocation & Basic Hardening

The Reports servlet is unsecured by default – secure invocation and basic
hardening before going live:
[docs/general_security.md](docs/general_security.md#report-security--secure-invocation--basic-hardening).

### Password Security Concept

Every password is stored encrypted and machine-bound (`openssl`, key from
the disk UUID), one `.des3` file per secret:
[docs/general_security.md](docs/general_security.md#password-security-concept).

## Sizing Guide

Disk space, memory and process settings:
[docs/forms_reports_sizing.md](docs/forms_reports_sizing.md).

## First Run on an Existing Environment – Required Order

New installation: [`09-Install/README.md`](09-Install/README.md). Existing
environment (analyse + fix): the order of the first scripts –
[docs/forms_reports_installation_steps.md](docs/forms_reports_installation_steps.md#first-run-on-an-existing-environment--required-order).

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
| `12-APEX-Ords/`       | Oracle APEX 26.2 + ORDS 26.3 standalone beside Forms – scripts `01-` … `06-` (prepare DB, install / patch APEX, install / patch ORDS, Nginx), live-tested 2026-10-23 |
| `10-Monitoring/`      | CVE inventory + early warning (`cve_inventory.sh`, `cve_watch.sh`), certificate expiry, patch-cycle analysis with Claude (`patch_cycle_analysis.sh`); concept: notification, AI-assisted log analysis |
| `60-RCU-DB-19c/`     | Oracle 19c minimal RCU database: config interview → OS baseline → CVU pre-check → install already patched (gold image, or 19.3 image + opatch RU) → listener → create DB (RCU requirements checked) → Unified Audit → RCU profile → autostart; out-of-place RU patch |
| `70-Customer-Projects/` | Customer-specific manual walkthroughs (German Kochbuch `.txt` files, anonymised English knowledge base: localhost hardening, domain clone), patch analyses (12.2.1.19 customer; 14.1.2 manual guide per patch cycle) and standalone tools (`tools/bash/`: collector, MOS download, clone check, cookbook variables, disk space; `tools/powershell/`: collector, cookbook variables, MOS download for Windows hosts), independent of the scripts above |
| `80-FMW-Architecture/` | Background: how Forms/Reports/WebLogic work internally – start with [`weblogic_middleware_architecture.md`](80-FMW-Architecture/weblogic_middleware_architecture.md) (homes, AdminServer / Node Manager / system components, consoles, log locations), RCU / OPSS: [`rcu_middleware_architecture.md`](80-FMW-Architecture/rcu_middleware_architecture.md), Reports: [`reports_engine_architecture.md`](80-FMW-Architecture/reports_engine_architecture.md), certificates / trust stores: [`certificates_trust_stores.md`](80-FMW-Architecture/certificates_trust_stores.md), Forms: [`forms_runtime_architecture.md`](80-FMW-Architecture/forms_runtime_architecture.md) – findings, not procedures; index [`80-FMW-Architecture/README.md`](80-FMW-Architecture/README.md) |

## Common Flags

- `--apply` : Execute write/change operations (default: read-only/dry-run)
- `--help`  : Show usage information

## Repository Structure

```
IHateWeblogic/
│
├── README.md                        – Start here, target picture, script directories, repository structure
├── TODO.md                          – Open items (everything not yet done or tested)
├── CHANGELOG.md                     – What was finished when, newest first
├── CONTRIBUTING.md                  – How to report a finding, conventions, customer-data rule + pre-commit hook
├── IHateWeblogic.md                 – Background and intention of the IHateWeblogic script lib
├── docs/                            – sections moved out of this README (2026-11-11): migration to 14c,
│                                    project status, security & patch status, sizing (disk, memory,
│                                    processes), installation steps (lifecycle, first run, setup),
│                                    general security (passwords, report invocation)
├── tools/ci_lint.sh                 – lint gate: `bash -n` + `shellcheck` (errors) over all scripts, also run by GitHub Actions
├── tools/hooks/                     – pre-commit hook (customer data, secrets, bash -n, stale ZIPs) + install.sh
├── tools/render_ascii/              – ASCII diagrams in Markdown → SVG (LLM → D2), `?v=` cache-busting
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
│   ├── detect_env_conf.sh           – Detect FMW/Domain paths and running processes,
│   │                                   generate environments/<name>.conf + update symlink;
│   │                                   --list / --select switch between several confs
│   │                                   (shell: setdb from 70-Customer-Projects/tools/bash)
│   ├── weblogic_sec.sh              – Prompt for WebLogic password → encrypt to
│   │                                   weblogic_sec.conf.des3 (openssl des3, machine-local key)
│   ├── database_rcu_sec.sh          – Same encryption concept for the RCU/repository DB password
│   ├── mos_sec.sh                   – Same encryption concept for My Oracle Support credentials
│   ├── install_db_client_tools.sh   – Instant Client 23.26 (sqlplus/tools) + SQLcl into
│   │                                   $ORACLE_BASE/product/<tool>_<ver>, link switch after smoke test
│   ├── customer_conf_import.sh      – Customer export → environments/<env>.customer/ overlay +
│   │                                   IMPORT_DECISIONS.md + conf block (14c move, step 2)
│   ├── set_environment.md           – Concept doc: environment.conf symlink + environments/ folder
│   └── environments/                – Per-environment conf files
│       ├── README.md                – committed
│       ├── *.conf.template          – committed (fmw_prod, db_prod, …)
│       └── *.conf                   – gitignored (server-specific, generated by detect_env_conf.sh)
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
│   ├── clone_check.sh               – Clone-capable / golden image: sockets by bind address, SSL ports,
│   │                                   Coherence, Reports ORB, host refs, RCU location, secrets; --apply:
│   │                                   SSL/Coherence (WLST) + AdminURL, ADMIN_URL, emoms, engine jvmOptions
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
│   │                                   ConfigBackup/YYYYMMDD_HHMI/<category>/, mode 700/600, --keep N)
│   ├── restore_config.sh            – List backups, restore a set or --category (--apply), path check
│   ├── bak_cleanup.sh               – *.bak_<ts> copies next to the Oracle files: keep newest N per file
│   ├── patch_storage.sh             – patch archive (PATCH_ARCHIVE, NFS/ZFS) as master, local PATCH_STORAGE
│   │                                   as cache: status / pull <step> / clean (run history) / history
│   ├── 80-patch_java_os.sh          – JDK at JDK_HOME from the patch repository (--apply, domain stopped)
│   ├── domain_jdk_path.sh           – Domain + oui/ pinned to jdk-21.0.x → JDK_HOME symlink (--apply)
│   ├── rcu_repository_check.sh      – RCU repository check (registry, accounts, data sources);
│   │                                   --apply = Data Pump backup of schemas + registry
│   ├── 81-patch_weblogic.sh         – WLS FMW Basis layer: wraps 09-Install/05-oracle_patch_weblogic.sh,
│   │                                   hard-fails if WebLogic is still running
│   ├── 82-patch_forms_reports.sh    – Forms + Reports layer: wraps 09-Install/06-oracle_patch_forms_reports.sh,
│   │                                   same stop-check as 81-
│   ├── apply_customer_conf.sh       – Customer overlay on an existing library environment (Way 2):
│   │                                   14b- / 14- / 13- / 30-, restart, wait, 15- / 90- – one log
│   └── ConfigBackup/                – Backup storage: one subfolder per date/time and config type (gitignored,
│                                       retention CONFIG_BACKUP_KEEP)
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
│   ├── 00-install-status.sh         – Installation progress from log/run_history.csv + probes, next step
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
│   ├── 13-root_reports_fix.sh       – Phase 6: libnsl.so.2 symlink for Oracle Linux 9 (root, or
│   │                                   oracle when $ORACLE_HOME/lib is writable)
│   ├── 13-oracle_setup_reports.sh   – Phase 6: Reports Server config (rwnetwork/rwservlet/rwserver)
│   ├── 14-oracle_setup_forms.sh     – Phase 6: Forms config (template-copy approach)
│   ├── 14b-oracle_reports_fonts.sh  – Phase 6: Reports fonts, uifont.ali, cgicmd.dat (after first start)
│   ├── 30-configure_autostart.sh    – Autostart at boot: systemd unit + Node Manager controlled
│   │                                   start/stop scripts (templates in autostart_templates/)
│   ├── 40-oracle_forms_client_bundle.sh – Forms client bundle for Nginx /formsWeb: jlink Windows
│   │                                   runtime + CA, frmsal.jar, JACOB DLL, icon, manifest.json,
│   │                                   index.html landing page; checks start section + start form
│   ├── client_templates/            – FormsWeb-Install.cmd (bootstrap) + FormsWeb-Setup.ps1
│   │                                   (PS 5.1 installer/starter in %LOCALAPPDATA%, self-update)
│   │                                   + index.html.template (landing page of /formsWeb/)
│   ├── 99-oracle_deinstall_fmw.sh   – Teardown: remove FMW completely for a clean reinstall,
│   │                                   keeps a database on the same host (irreversible)
│   ├── oracle_software_version.conf – Pinned FMW/JDK/patch version numbers
│   ├── nginx-wls.conf.template      – Nginx reverse-proxy config template
│   ├── nginx-index.html.template    – start page https://<host>/ with the link to /formsWeb/
│   ├── forms_templates/             – 6 editable Forms config templates + README
│   │                                   (default.env, formsweb.cfg, webutil.cfg, Registry.dat, res files)
│   ├── response_files/              – Silent-install response file templates
│   │                                   (domain_config.py, fr_install.rsp, cgicmd.dat)
│   ├── 15-deploy-test-report-forms_template.sh – Smoke test: minimal Forms module + Reports demo
│   │                                   + font test report (reports_templates/test_fonts.xml)
│   ├── 90-oracle_validate.sh        – Phase 7: acceptance – runs the analyse scripts read-only +
│   │                                   direct checks, one summary (--smoke for 15-)
│   └── docs/                        – Step-by-step detail documentation (00–14b, 17-customer
│                                       import, 20-testmodules, 30-autostart, 40-client distribution,
│                                       80-security, 90-validate, 99-deinstall); process of the
│                                       14c move: 00-transfer_customer_settings.md
│
├── 10-Monitoring/
│   ├── README.md                    – Concept: AI-assisted proactive monitoring + monthly CVE watch
│   ├── cve_inventory.sh             – CVE watch step 1: components, patch cycle, JDKs, OS errata, advisories, jars
│   ├── cve_watch.sh                 – CVE watch step 2: daily early warning (Oracle alerts, NVD CNA, OSV, KEV,
│   │                                   EPSS, heise), only new findings alert, --state-dir per inventory, --cron
│   ├── patch_cycle_analysis.sh      – Claude patch-cycle analysis: prepare (README list) / analyse (docs, update_plan)
│   ├── patch_cycle_analysis_skill.md – the procedure Claude follows + registry "where the cycle lives"
│   ├── setup_claude.md              – Claude Code on an FMW host: placement (never prod), sandbox, guard, data protection
│   ├── claude_setup_check.sh        – checks that setup, --apply renders the managed settings + root commands
│   ├── claude/                      – managed-settings.json.template, ihw_guard.sh (PreToolUse hook),
│   │                                   skills/ template of the Claude Code skill (copied to the untracked .claude/)
│   └── cert_expiry_check.sh         – Certificate expiry (Nginx served cert, local CA, codesign), cron --apply
│
├── 12-APEX-Ords/
│   ├── README.md                    – APEX 26.2 + ORDS standalone (Jetty) beside Forms: homes ords_1/ords_2,
│   │                                   one ORDS per DB, images copy /srv/apex, Nginx, systemd ords@.service
│   ├── 01-prepare-database.sh       – PDB check: APEX present?, tablespace (APEX + ORDS), profile APEX_USER
│   ├── 02-install-apex.sh           – unpack, apexins as SYS in the PDB, ADMIN/REST user, languages, images
│   ├── 03-patch-apex.sh             – patch set bundle: catpatch, images APEX_<ver>_p<nr> + link switch
│   ├── 04-install-ords.sh           – ORDS home, ords install (non-interactive), config set, systemd unit
│   ├── 05-setup-nginx.sh            – /etc/nginx/oracle-wls.d/ords_N.conf (/ords/ + /i/), HTTPS check
│   ├── 06-patch-ords.sh             – new ORDS release beside the old one, repository upgrade, rollback
│   ├── apex_ords_lib.sh             – shared functions (SQL as SYS, ORDS command line, versions, templates)
│   ├── apex_user_profile.sql        – DB profile APEX_USER (no expiry / lock-out) for the runtime accounts
│   └── templates/                   – ords@.service, logging.properties, nginx-ords.conf
│
├── 60-RCU-DB-19c/
│   ├── README.md                    – DB setup roadmap (Phase DB, between Phase 3 and 4)
│   ├── 00a-db_env_interview.sh      – environment_db.conf from the template (interview, --check)
│   ├── 00-root_db_os_baseline.sh    – DB-specific OS settings, preinstall RPM (auto-sudo)
│   ├── 00b-db_cvu_check.sh          – host pre-check with the standalone CVU (patch 30839369, cluvfy -r 19)
│   ├── 01-db_install_software.sh    – 19c software-only install, patched in one run (gold image or
│   │                                   base + opatch RU); --target-home = new home for 09-
│   ├── 02-db_setup_listener.sh      – listener.ora / sqlnet.ora / tnsnames.ora, listener, oracle-listener.service
│   ├── 03-db_create_database.sh     – DBCA: CDB FMWCDB + PDB FMWPDB (AL32UTF8, RCU parameter minimums,
│   │                                   local_listener without alias, requirement check)
│   ├── 04-db_audit_setup.sh         – common audit policies, AUDITLOG tablespace, archive + purge jobs
│   │                                   (uniaud_on relink before it: --relink --apply)
│   ├── 05-db_fmw_tablespace.sh      – FMW_DATA tablespace for all RCU schemas
│   ├── 06-db_rcu_profile.sh        – DB profile RCU_USER for the RCU schemas (no expiry/lock)
│   ├── rcu_user_profile.sql         – idempotent SQL for it (also used by 09-Install/07)
│   ├── rcu_registry_overview.sql    – all RCU prefixes of the DB: schemas, orphans, profile, expiry
│   ├── rcu_db_requirements.sql      – FMW 14.1.2 DB requirements (version, edition, AL32UTF8, JVM, parameters)
│   ├── 08-db_auto_start.sh          – Configure DB/listener autostart (oratab, systemd)
│   ├── 09-db_patch_rcu.sh           – patch the running DB out-of-place (new home via 01- --target-home, move, datapatch, rollback)
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
│   ├── reports_engine_architecture.md – Reports in-process vs. standalone server, engines,
│   │                                      rwrun call flow (§5.1), performance parameters, history
│   ├── certificates_trust_stores.md – certificates / keys / trust stores: terms, CA quality, inventory,
│   │                                      who needs what, customer PKI + interception, central trust concept
│   ├── reports_rwbuilder.md          – Reports Builder minimal setup on Windows (RDP): builder-only
│   │                                      domain, no running server stack, local-admin finding
│   ├── weblogic_outbound_connections.md – what the domain sends outside, external-DTD trap
│   ├── forms_runtime_architecture.md – Forms servlet / listener / frmweb per session, runtime
│   │                                      pooling, timeout chain, memory, logs, protocol history
│   ├── reports_server_discovery_multicast.md – Reports discovery via UDP multicast,
│   │                                      REP-50600 / REP-56040, prerequisites, diagnosis
│   ├── reports_server_image_handling.md – images in reports, REPORTS_PATH, <folderAccess>
│   ├── reports_fonts_architecture.md – Reports fonts: original vs. substitute, licences (Windows fonts
│   │                                      not to another server), OFL replacements, migration
│   ├── reports_user_local_ldap.md   – secured standalone Reports server (embedded LDAP)
│   ├── em_principal_search_libovd.md – EM "Add Principal" empty, libOVD lock
│   ├── apex_architecture.md         – APEX: request path, 26.2 accounts, f?p= -> SYS wrapper, removal, export
│   ├── ords_architecture.md         – ORDS: Jetty, APEXlang compiler, config levels, proxy right, features + risks
│   │                                      (CONNECT THROUGH), REST / OAuth2, APEX session in REST, history
│   ├── clone_golden_image.md        – loopback-only installation, hardening checklist, what holds the
│   │                                      host name, RCU local vs. external (way 3 reassociate),
│   │                                      golden-image recipe in four phases
│   ├── java_jlink_forms_env.md      – own Java runtime for the Forms client (jlink, jmods,
│   │                                      cross-build Windows on Linux, module list)
│   └── forms_jakob_webutil.md       – WebUtil + JACOB (OLE / Office automation)
│
└── 70-Customer-Projects/            – Customer-specific manual walkthroughs, not generated from
    │                                   the scripts above; see README.md for an index + further
    │                                   German installation guides (one subfolder per customer/scenario)
    ├── README.md
    ├── cookbook-Skill.md             – how a customer cookbook is written (style rules)
    ├── Start_beim_Kunden_kochbuch_de.txt – first steps at a customer (tools ZIP, setdb, ini)
    ├── FormsReports14_linux_localhost/ – knowledge base (English, anonymised): harden an existing
    │   │                                 domain to localhost
    │   ├── README.md                     – every place touched, symptom -> cause table
    │   └── Localhost_cookbook_en.txt     – manual cookbook, ends with "Clone-capable: yes"
    ├── FormsReports14_linux_clone/   – knowledge base (English, anonymised): VM clone, new RCU prefix
    │   ├── README.md                     – reassociateSecurityStore, what changes and what not
    │   └── Clone_cookbook_en.txt         – manual cookbook (source part A, clone part B)
    ├── FormsReports12_patch_cpu_2026-10/
    │   ├── README.md                     – Patch analysis Forms & Reports 12.2.1.19, CPU Oct 2026 +
    │   │                                     Java alert (server JDK 8, client JRE), manual
    │   └── Patch_Kochbuch_CPU_Okt2026_de.txt – German patch cookbook for the customer (12 steps)
    ├── FormsReports14_patch_cpu_2026-10/   – one folder per patch cycle (history of the
    │   │                                     manual procedure; the scripts follow the current cycle)
    │   ├── README.md                     – 14.1.2 patch set CPU Oct 2026: test-host inventory,
    │   │                                     facts of every patch README
    │   └── install_14c_patch_set_october_2026_manual.md – manual step-by-step guide (master for 04-/05-/06-/80-)
    ├── customer-analyse/             – not in this repository: analysis scripts / templates (private
    │                                     repository) + local customer data (never committed)
    ├── tools/
    │   ├── README.md
    │   ├── make_customer_zip.sh          – builds ihw_customer_tools_linux.zip / _windows.zip (one link
    │   │                                     for the customer; run --apply before every tools commit)
    │   ├── bash/                         – Linux hosts
    │   │   ├── collect_fmw_env.sh            – shared read-only collector (12c + 14c), secrets masked
    │   │   ├── mos_patch_download.sh         – MOS download of a patch CSV with getMOSPatch (share host)
    │   │   ├── clone_check_fmw.sh            – read-only golden-image / clone check (12c + 14c)
    │   │   ├── fmw_patch_env.sh              – variables of the manual patch cookbooks
    │   │   ├── check_disk_space.sh           – where is the local disk space (NFS never scanned), clean commands
    │   │   ├── ihw_shell_env.sh              – setdb / setfmw: switch the current shell (FMW home, domains, DB homes) – ~/.bashrc.d
    │   │   ├── export_forms_reports_conf.sh  – export of the customer Forms/Reports configuration (12c/14c)
    │   │   │                                     for the 14c rebuild – encrypted archive, never into git
    │   │   ├── make_patch_install_ini.sh     – patch_install.ini from the existing domain (for the cookbooks)
    │   │   ├── set_script_env.sh             – loads patch_install.ini into the shell (sourced)
    │   │   ├── status.sh, show_log.sh,       – operation: status in three stages, logs, error lines
    │   │   │   show_errors.sh, show_all_logs.sh
    │   │   ├── clean_domain_tmp.sh           – delete servers/*/tmp + cache of the stopped domain (rebuilt at the next start)
    │   │   └── ihw_tools_lib.sh              – shared functions of the tools (parsers, unpack, lights)
    │   └── powershell/                   – MS Windows Server hosts (PowerShell 5.1 / 7), same output as bash
    │       ├── README.md
    │       ├── collect_fmw_env.ps1           – read-only collector (services, registry, CIM), secrets masked
    │       ├── fmw_patch_env.ps1             – cookbook variables (dot-source), running services
    │       ├── mos_patch_download.ps1        – MOS download of a patch CSV (Windows platform 233P)
    │       └── GetMOSPatchRunner.java        – MOS password via stdin (never on a command line) + ZIP CRC check
    ├── Reports14_builder_windows/
    │   ├── README.md                     – Reports Builder on Windows Server (builder-only domain)
    │   ├── Git_checkin.md                – Git check-in idea: pull.ps1 / checkin.ps1, rdf -> xml (step 1 tested)
    │   ├── scripts/                      – pull.ps1, checkin.ps1 (German messages), template.gitattributes / .gitignore
    │   ├── ReportBuilder_Windows_Kochbuch_de.txt
    │   └── ReportBuilder_Windows_Kochbuch_en.txt – English version (2026-11-11)
    └── Reports14_linux_manual_install/
        ├── README.md                     – Reading order + one-sentence purpose per Kochbuch
        ├── OS_Kochbuch_de.txt             – OS prep for OL9 (packages, Java, oracle user, network)
        ├── FMW_Kochbuch_de.txt            – WebLogic/FMW install, patch, SSL rollout to Nginx
        ├── SSL_Kochbuch_de.txt            – Certificate creation/audit only
        ├── Reports_kochbuch_de.txt        – Reports install, RCU, domain, Reports Server config
        ├── Font_kochbuch_de.txt           – TrueType fonts + HTML parameter-form font path
        ├── WLS_Report_start_stop_kochbuch.txt – Simplest start/stop for day-to-day operation,
        │                                          no dependency on the IHateWeblogic lib
        ├── Tools_status_logs_kochbuch.txt – status.sh / show_all_logs.sh / show_errors.sh for
        │                                    /u01/oracle/tools (no lib, data in patch_install.ini)
        ├── patch_install.ini              – ALL values of this environment (cookbooks + tools),
        │                                    loaded with tools/bash/set_script_env.sh
        ├── Autostart_linux_middleware.txt – Start/stop at boot/shutdown via a systemd unit
        ├── Reports_security.txt           – Hardening of the finished environment (new install)
        ├── Patch_Kochbuch_CPU_Okt2026_de.txt – CPU Oct 2026 for an EXISTING home with unknown
        │                                    patch level (+ patches_cpu_reports_14c_oct2026.csv, 18 patches)
        └── Reports_Absicherung_kochbuch_de.txt – check + complete the Reports security of an
                                             existing domain (monUser/RepRunner, LDAP, libOVD)
```

## Demo Data

Examples in docs, cookbooks and script comments use the names of our test host.
They are **demo data** – no customer data, no masking needed – and can be copied
as they are on a host built with this library:

| Item | Demo value |
|---|---|
| host / FQDN | `orafusion01` / `orafusion01.pipperr.local` |
| IP / network | `10.10.10.124` / `10.10.10.0/24` (admin PCs `10.10.10.50`, `10.10.10.51`) |
| RCU database | CDB `FMWCDB`, PDB service `fmwpdb` on `10.10.10.124:1521`, schema prefix `DEV` |
| Forms & Reports domain | `fr_domain` – `/u01/app/oracle/domains/fr_domain` |
| FMW / JDK home | `/u01/app/oracle/fmw` / `/u01/app/oracle/java/jdk-21` |
| Reports server | `repserver01` |
| Reports-only demo domain (manual cookbooks in `70-Customer-Projects/Reports14_linux_manual_install`) | `reportGPI` (systemd unit `reportgpi`) |
| further names in examples | `forms.pipperr.local` (public alias), `mail.pipperr.local`, `proxy.pipperr.local` |

Rule of thumb: everything with `orafusion`, `pipperr.local`, `10.10.10.` or `gpi`
is demo. Placeholders such as `<host>` or `<repserver>` stay where the reader
**must** put in an own value; default values inside the scripts are not demo
data and stay as they are.

## Disclaimer & Acknowledgements

### Disclaimer

- IHateWeblogic is an independent community project. It is **not affiliated
  with, endorsed or supported by Oracle Corporation**.
- Oracle, Java, WebLogic, Oracle Forms, Oracle Reports, Oracle Linux and APEX
  are trademarks or registered trademarks of Oracle and/or its affiliates.
  Other names may be trademarks of their respective owners.
- **Use at your own risk.** With `--apply` the scripts change OS, WebLogic and
  database settings – test in a non-production environment first and keep
  backups. The project is provided "as is", without warranty of any kind – see
  [LICENSE](LICENSE) (Apache 2.0). For Oracle products follow Oracle's
  documentation and My Oracle Support; licensing of Oracle software is your
  responsibility.
- The bird logo (`assets/IHateWeblogic_logo.png`) is the **personal logo of
  Gunther Pipperr**, used across his projects – it is neither a project logo
  nor an Oracle logo. Please do not reuse it for other projects without asking.
- Written by Gunther Pipperr together with Claude (Anthropic) as AI co-author.
  Every finding is checked on a real system before it is marked
  "confirmed live".
- Findings and contributions: [CONTRIBUTING.md](CONTRIBUTING.md); security
  problems privately: [SECURITY.md](SECURITY.md).

### Acknowledgements

Special thanks to two colleagues of [die IT-Macher](https://www.der-it-macher.de/)
without whom this documentation would not exist in this form:

**Jürgen Menge** – for his invaluable support on countless WebLogic questions,
for sharing his deep expertise, and for his ideas and information that have
substantially shaped the concepts and structure of this installation guide.

**Mark Eichhorst** – for his support and patience with Oracle Forms and Reports
questions, and for the inspiration that came from the challenges and tasks he brought
to the table.

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
  [`80-FMW-Architecture/reports_engine_architecture.md`](80-FMW-Architecture/reports_engine_architecture.md)
