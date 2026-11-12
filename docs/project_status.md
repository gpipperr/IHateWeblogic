# Project Status

← Back to the [root README](../README.md)

## Project Status

**`[███████████████████░]` ~96 % complete** (state 2026-11-06) – phases 1–7
are implemented and the whole install chain is live-tested end-to-end incl.
the smoke test; all analyse + fix folders `01-`…`07-` and `08-SSL` were
reviewed against the Oracle 14.1.2 documentation and re-tested live
(2026-10-19/20); phase 8 is nearly done, phase 9 has its first script
([`cve_inventory.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/10-Monitoring/cve_inventory.sh), since 2026-10-30 [`cve_watch.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/10-Monitoring/cve_watch.sh)); host hardening
(firewall, sshd) is live on the test host. The 14c move of a customer
(export → analysis → import, [process](../09-Install/docs/00-transfer_customer_settings.md))
ran live at a customer on 2026-11-05/06: Way 2 and Way 1, including step 3,
the re-analysis of the new 14c host. On 2026-11-09/10 a customer domain was
hardened to localhost and cloned with its VM onto a new RCU prefix in another
database (`reassociateSecurityStore`) – the findings are in
[`clone_golden_image.md`](../80-FMW-Architecture/clone_golden_image.md) and, anonymised
with cookbooks, in
[`FormsReports14_linux_localhost`](../70-Customer-Projects/FormsReports14_linux_localhost/README.md) /
[`FormsReports14_linux_clone`](../70-Customer-Projects/FormsReports14_linux_clone/README.md).
What was done when: [CHANGELOG.md](../CHANGELOG.md) (newest first). What is
still open: [TODO.md](https://github.com/gpipperr/IHateWeblogic/blob/main/TODO.md).

How the ~96 % is estimated: phases 1–7 count as done (7 × ~11 %), phase 8
about nine tenths (CPU Oct 2026 applied on the test host 2026-10-24; bundled-JDK patch open), phase 9 about half
(CVE watch steps 1 + 2 (`cve_inventory.sh`, `cve_watch.sh` early warning),
the certificate expiry check and the Claude patch-cycle analysis done;
notification, log analysis, config security scanner are concept); minus the
[open items](https://github.com/gpipperr/IHateWeblogic/blob/main/TODO.md) – mainly the questions to Oracle (bundled
JDK 17 + FMW DBCLIENT SR, `frmweb` bind address), the
remaining client tests (update / offline / JACOB on Windows) and tests on a
fresh installation.

| # | Phase | Status |
|---|---|---|
| 1 | Installation | ✅ Done |
| 2 | Configuration & First Start | ✅ Done – incl. secured Reports server (`REPORTS_SECURITY=ldap`, web-command design tested 2026-10-23 – [doc 81](../09-Install/docs/81-reports_rwservlet_security.md)), autostart, NM-aware [`startStop.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/01-Run/startStop.sh), smoke test `15-` (Forms XML → FMX, report → PDF, font test report with `pdffonts` / [`pdf_font_verify.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/04-ReportsFonts/pdf_font_verify.sh)); **one `TNS_ADMIN`** in `default.env`, `rwserver.conf`, `reports.sh`, `setUserOverrides.sh`, `.bash_profile`, checked with [`02-Checks/tns_admin_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/tns_admin_check.sh) incl. the running processes (2026-10-23); **Forms client distribution** `40-` + client templates – first Windows FSAL session 2026-10-23 ([concept 40](../09-Install/docs/40-forms_client_distribution.md)) |
| 3 | Check Logs | ✅ Done (incl. [`rwrun_trace.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/01-Run/rwrun_trace.sh); `display_check.sh` dropped – tools need no X); reviewed 2026-10-19: one log discovery [`03-Logs/log_locations.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/03-Logs/log_locations.sh), `setLogLevel` persist fix – [03-Logs/README.md](../03-Logs/README.md) |
| 4 | Set Up SSL | ✅ Done; reviewed 2026-10-20: local root CA for TLS + code signing, `jacob.jar` signed with DigiCert timestamp, redirects behind Nginx via `WL-Proxy-SSL` – [08-SSL/README.md](../08-SSL/README.md) |
| 5 | Solve Font Problems | ✅ Done; reviewed 2026-10-19: two font paths (PDF: TTF, HTML: screen-printer AFM/PPD), substitute fonts need AFM/PPD in PDF too – [04-ReportsFonts/README.md](../04-ReportsFonts/README.md) |
| 6 | Check Reports Performance | ✅ Done; rebuilt 2026-10-19 on [`01-Run/reports_server_lib.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/01-Run/reports_server_lib.sh) (right `rwserver.conf`, report engine, `authid`, server logs); since 2026-10-23 every engine value (`engLife`, `maxIdle`, `jvmOptions`, `engineResponseTimeOut` – proposal from the measured `showjobs` run times) comes from `environment.conf` and `--apply` writes it back – [05-ReportsPerformance/README.md](../05-ReportsPerformance/README.md), background [reports_engine_architecture.md](../80-FMW-Architecture/reports_engine_architecture.md) |
| 7 | Check Forms | ✅ Done; rebuilt 2026-10-19 on [`06-FormsDiag/forms_lib.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/06-FormsDiag/forms_lib.sh) against Oracle's 14.1.2 parameters, prestart fix in `14-` (50 → 5 idle `frmweb`); 2026-10-23: `maxRuntimeProcesses` from RAM (interview / `14-`), `time-taken` in the access log (frmservlet + lservlet response times) – [06-FormsDiag/README.md](../06-FormsDiag/README.md), background [forms_runtime_architecture.md](../80-FMW-Architecture/forms_runtime_architecture.md) |
| 8 | Maintenance & Patches | 🚧 Mostly done — reviewed 2026-10-19 ([07-Maintenance/README.md](../07-Maintenance/README.md) §8: backup covers every file our scripts change incl. AFM metrics and customer font originals, restore per `--category` with path check, patch gate sees `rwserver`/engines/`frmweb`; retention 2026-10-23: `backup_config.sh --keep N`, [`bak_cleanup.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/bak_cleanup.sh) for the `*.bak_<ts>` copies); backup/restore + WLS/Forms/Reports patching for an already-running environment (`07-Maintenance/80-82`) implemented; RCU repository: theory, profile `RCU_USER` (no password expiry), `db_securefile`/EBR pre-checks, [`rcu_repository_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/rcu_repository_check.sh) (check + Data Pump backup); JDK upgrade: `80-patch_java_os.sh --apply` installs the JDK 21 of MOS Patch 35702194 from the patch repository (downloaded only by `04-`; since the NFTC ended in Sep 2026 there are no public JDK 21 updates), live-tested 2026-10-20; patch set CPU Oct 2026 in conf + `04-`/`05-`/`06-` and applied on the test host 2026-10-24 (manual guide per cycle in `70-Customer-Projects/`, VM-snapshot pause in `80-`–`82-`), `rcu_repository_check.sh` check 6 invalid objects (2026-10-26); since 2026-10-30 patch numbers in [`09-Install/download/patches_fmw.csv`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/download/patches_fmw.csv) (one list per cycle, also for the standalone download tool) and [`patch_storage.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/patch_storage.sh) for a small local disk (`PATCH_ARCHIVE` on NFS/ZFS = master, local = cache per step, run history `log/run_history.csv`); open: OPatch patch for the FMW-bundled JDK `oracle_common/jdk` (SR) |
| 9 | Proactive Monitoring | 🚧 Started – [`cve_inventory.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/10-Monitoring/cve_inventory.sh) (CVE watch step 1: components, patch cycle, both JDKs, active use / exposure, OS errata, `--online` advisories, third-party jars), [`cve_watch.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/10-Monitoring/cve_watch.sh) (step 2, daily early warning: Oracle alerts page, NVD Oracle CNA records, OSV, KEV, EPSS, heise – alerts only new findings, journal `ihw-cve`), [`cert_expiry_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/10-Monitoring/cert_expiry_check.sh) (daily cron, journal tag `ihw-cert`), [`patch_cycle_analysis.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/10-Monitoring/patch_cycle_analysis.sh) (Claude patch-cycle analysis, skill doc + `update_plan.md`), [`claude_setup_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/10-Monitoring/claude_setup_check.sh) (Claude sandbox / managed settings / guard hook, [setup_claude.md](../10-Monitoring/setup_claude.md)); rest concept incl. config security scanner – see [10-Monitoring/README.md](../10-Monitoring/README.md) |

Details per phase: [Lifecycle Overview](forms_reports_installation_steps.md#lifecycle-overview) below.
