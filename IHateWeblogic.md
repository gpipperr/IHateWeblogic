# IHateWeblogic – Oracle Forms & Reports Diagnostic Script Library

Author: Gunther Pipperr | https://pipperr.de
License: Apache 2.0

## Meaning of the Projekt name:


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


Innovation Helps Admins To Enhance Weblogic-Based Lifecycle Operations, Governance, Integration & Control.



## Intention

Oracle Forms and Reports on WebLogic is powerful but notoriously difficult to diagnose.
This script library exists because the author has spent too many hours debugging obscure
configuration issues, font problems, segfaults, and SSL mismatches on Oracle Middleware
installations.

**This is not a monitoring or operations library.** DBA teams have their own tools for that.
This library focuses on:

- Post-installation diagnosis
- Configuration validation (against Oracle documentation)
- Bug hunting and root cause analysis
- Documentation generation for support cases

## Target Environment

- Oracle Forms 14c / Reports 12c (technically 14c naming but Reports is still 12c codebase)
- Oracle WebLogic 12c
- Oracle Linux 8 / 9

## Philosophy

- **Read-only by default.** Every script only reads and reports unless `--apply` is passed.
- **No surprises.** Every change is backed up before it is applied.
- **Source is king.** Where possible, behavior is validated against the official Oracle docs.
- **One library, many scripts.** All shared logic lives in `00-Setup/IHateWeblogic_lib.sh`.

## License

Copyright 2024 Gunther Pipperr – https://pipperr.de

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at:

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

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
