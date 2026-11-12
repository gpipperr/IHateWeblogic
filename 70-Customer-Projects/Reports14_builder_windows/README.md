# Reports Builder Environment on MS Windows – Oracle Reports Builder 14.1.2

Minimal development environment for the **Oracle Reports Builder 14.1.2** on
a central **Windows Server**, where the developers work via **RDP**. Same
customer as the Linux Reports installation in
[`../Reports14_linux_manual_install/`](../Reports14_linux_manual_install/README.md):
the reports are designed on Windows and run and tested on the Linux Reports
server.

→ Step-by-step guide:
[ReportBuilder_Windows_Kochbuch_en.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/ReportBuilder_Windows_Kochbuch_en.txt) (English) ·
[ReportBuilder_Windows_Kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/ReportBuilder_Windows_Kochbuch_de.txt) (German, the version run at the customer)

→ Architecture and idea:
[80-FMW-Architecture/reports_rwbuilder.md](../../80-FMW-Architecture/reports_rwbuilder.md)

## The question: does the Reports Builder work without the full FMW stack?

For Forms there is the installation type **"Standalone Forms Builder"** – an
Oracle home without a WebLogic domain. For Reports there is **no** such
thing. Result of the research in the Oracle documentation (state
2026-10-26):

| Finding | Source |
|---|---|
| Reports 14.1.2 is unchanged against 12.2.1.3 and deprecated – installation per the **12.2.1.3 installation guide**, only with the 14.1.2 software | [Install Forms 14.1.2, chapter 5 "About Oracle Reports"](https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/install-fnr/oracle-reports.html) |
| Installation types of the Forms & Reports installer: **"Forms and Reports Deployment"** or **"Standalone Forms Builder"** – no Reports counterpart | [Install 12.2.1.3 §2.4.4](https://docs.oracle.com/middleware/12213/formsandreports/install-fnr/installing-and-configuring-oracle-forms-and-reports1.htm) |
| "**One ReportsTools component is compulsory**" – the Builder needs a Reports Tools instance, created with WLST `createReportsToolsInstance()` against a **running AdminServer** | ibid. §2.4.7, §2.4.7.1, §2.4.7.3 |
| The domain template "Oracle Reports Tools" pulls in **Oracle JRF** (full) and **Oracle Enterprise Manager** → **RCU schemas are mandatory**. "Oracle Forms Development", in contrast, runs on Restricted JRF without a database – Reports has no such counterpart | `template-info.xml` of the templates; WLST offline `selectTemplate('Oracle Reports Tools')` → JRF, EM, Coherence extension (checked 2026-10-26 on the 14.1.2 test system) |
| The WLS Stack Patch Bundle contains its own `windows64_patchlist.txt` and the DB client for Windows → patching as on Linux with `opatch napply` | SPB 40125898 (CPU October 2026) |

**So a domain with RCU cannot be avoided.** What can be avoided is the
**running server stack** – and that is exactly what makes the effort on
Windows (Windows services, autostart, SSL, memory leaks in long-term
operation, see
[pipperr.de – Reports 14c on Windows](https://pipperr.de/dokuwiki/doku.php?id=forms:oracle_reports_14c_windows64)).

## Decision: builder domain without a Reports server

| Part | Full Reports installation (server) | **Builder environment (here)** |
|---|---|---|
| Software | FMW Infrastructure + Forms & Reports | the same – one Oracle home |
| RCU | own prefix | own prefix in the **existing** database of the customer |
| Domain templates | JRF, EM, Reports Tools, Reports Server, Reports Application, Reports Bridge, OHS | **only JRF + EM + Reports Tools** |
| Managed servers | WLS_REPORTS (+ cluster, machine, Node Manager) | **none** – only the AdminServer |
| Domain mode | Production (secure mode, `t3s`) | **Development** (no secure mode, `t3`) |
| AdminServer | runs permanently (Windows service) | runs **only once** for `createReportsToolsInstance`, then stopped |
| Windows services / autostart / SSL | needed | **not needed** |
| Running reports | locally via `rwservlet` | on the **Linux Reports server** (`rwservlet`) |

Day to day the developer only starts `rwbuilder.bat` from
`DOMAIN_HOME\reports\bin` – no WebLogic is running. This removes the
laborious and error-prone parts of a Windows server installation.

![builder-windows](diagrams/builder-windows.svg?v=65a44a9e)
<sub>Source: [diagrams/builder-windows.prompt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/diagrams/builder-windows.prompt) · [D2](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/diagrams/builder-windows.d2)</sub>

<details><summary>ASCII version</summary>

```ascii name=builder-windows
 Developer (RDP) ──► Windows Server ──── Reports Builder (rwbuilder.bat)
                         │  Oracle Home + builder domain (AdminServer stopped)
                         ├──────────► existing DB: RCU prefix + application data
                         └─ .rdf / .rep  ──► Linux Reports server (rwservlet) for testing
```

</details>

## Multi-user operation (RDP)

- **One** installation, one Oracle home, one builder domain; installed with
  a local admin account (e.g. `ORASYSTEM`), developers start the Builder via
  a shortcut for all users.
- **Developers need local administrator rights** (live 2026-10-27): with a
  normal user account the Builder does not start. The Oracle installer
  breaks the inheritance of permissions below `E:\oracle` – a group with
  rights on `E:\oracle` does not arrive in the subfolders, the rights would
  have to be set folder by folder by hand (a lot of work, again after
  patches). Therefore: one personal account per developer in the local
  group "Administrators", the server only for Builder development.
  2 simultaneous admin RDP sessions work without RDS licences – fits 2
  developers.
- Report sources in a shared directory (or version control), in the
  `REPORTS_PATH` of the Builder; keep fonts and `uifont.ali` **identical** to
  the Linux server, otherwise the preview looks different from the server
  output (see
  [Font_kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/Font_kochbuch_de.txt)).
- Database connections via a shared `tnsnames.ora`
  (`%DOMAIN_HOME%\config\fmwconfig`, `TNS_ADMIN` from `reports.bat`).
- Java: Oracle JDK only for Oracle products → licence-free per MOS Doc ID
  1557737.1.

## Next: Git check-in

Idea 2026-11-11: one Git clone per developer (`E:\git\<user>\oracle-report`), `pull.ps1`
at the start of the work, `checkin.ps1` converts every changed `.rdf` to XML
and commits / pushes – for developers without Git experience. Step 1 (rdf →
xml from the command line) is tested on the Linux test host; Windows test
procedure for the customer and the script design:
[Git_checkin.md](Git_checkin.md). The two scripts (German messages, a
skeleton for own adaptation) and `.gitattributes` / `.gitignore` templates:
[scripts/](https://github.com/gpipperr/IHateWeblogic/tree/main/70-Customer-Projects/Reports14_builder_windows/scripts).

Deployment (2026-11-12): only the branch `main`, one report per check-in;
push → the changed reports to the Linux DEV server; a `prod-*` tag
(`release_tag.ps1`) → exactly that check-in to production. GitLab CI
template, SSH forced-command queue `rwdeploy.sh`: [Git_deploy.md](Git_deploy.md);
set-up step by step (German): [git_pipeline_kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/git_pipeline_kochbuch_de.txt).

## Patch level

CPU October 2026 – the same patches as the Linux server
([FMW_Kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/FMW_Kochbuch_de.txt)
step 3, [Reports_kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/Reports_kochbuch_de.txt)
step 2), each in the Windows variant (MOS platform "Microsoft Windows x64
(64-bit)", getMOSPatch `233P`). JDK 21.0.13.0.2 from MOS patch 35702194
(Windows). Builder and server should have **the same patch level** – a
report saved with a newer Builder must run on the server.

## Facts from the Windows patch READMEs

Generic patches (OPatch 28186730, SPB 40125898, the eight infrastructure
bundles) have the same README as on Linux – facts in the
[14c README, section 3a](../FormsReports14_patch_cpu_2026-10/README.md).
Platform-specific (Windows x64):

| Patch | Read | Installation | Prerequisite / Windows notes | Bugs / remarks |
|---|---|---|---|---|
| **39600348** Reports QPR (README 10-Aug-26, `MSWIN-x86-64`) | 2026-10-26 | unpack, `opatch apply` in the directory `39600348`; rollback `opatch rollback -id 39600348` | all processes of the home stopped, same user as for the installation; OPatch minimum version only given as a placeholder "13.9.4.2.XXXX" (we have .25); patch directory in the root directory (`C:\MW_PATCHES`, 256-character limit), on "path too long" unpack with `%JDK_HOME%\bin\jar -xvf`; pause anti-virus; no relink (`make`/`ld` Unix only) | 31 bugs, identical to Linux: among others 37866660 (alternative JAVA_HOME for the tools), 38617264 (ENHANCEDSPREADSHEET REP-56048), 38872838 (`RUN_REPORT_OBJECT` after 30 min), 37756029 (`cgicmd.dat` encrypted), 36434214 (umlauts in `DESNAME`), 35740116 (`rwconverter` ORA-00933), 35363833 (Office365 STARTTLS), 37548468 (SRW package in ADB 23ai) + 20× "Fix for Bug 39375xxx" |
| **39951765** PERL SPU (README 03-Sep-26, Windows x64) | 2026-10-26 | unpack, `opatch apply` in the directory `39951765`; rollback `opatch rollback -id 39951765` | **OPatch ≥ 13.9.4.2.17**; all processes stopped, same user; the same Windows notes as above (`C:\MW_PATCHES`, `jar -xvf`, anti-virus). The README does not mention the DB client; on Linux KA1182 requires DBCLIENT ≥ 23.26 – it comes with the SPB (`dbclient/windows64`), so apply it **after** the SPB. The predecessor 38590500 does not exist on a new installation | the only fix **CVE-2026-4176** (Bug 39400045) – identical to the Linux variant |
| **39987730** OHS (Native) BP 14.1.2.0.260907 (README 08-Sep-26, Windows x64) | 2026-10-26 | unpack, `opatch apply` in the directory `39987730`; rollback `opatch rollback -id 39987730` | **OPatch ≥ 13.9.4.2.17**; all processes stopped, same user; Windows notes as above. Post-install: MOS **KB559857** – without an OHS instance (the builder domain has no OHS) **nothing to do** | cumulative since 250320, the same bug list as Linux: **CVE-2026-87347 / -87346** (260907), July / August hardening off by default (39902419 / 39901639 / 39901695) and more – binaries only, patched so that scanners do not report them |
| **39100536** WebGate BP 14.1.2.0.260318 (release notes G14589-06, Apr 2026, all platforms) | 2026-10-26 | unpack, `opatch apply` in the directory `39100536`; cumulative, an older BP does not have to be removed; rollback `opatch rollback -id 39100536` | latest OPatch; stop the Node Manager and the OHS component first (builder domain: neither runs); **minimum OS Windows 2022** – Windows Server 2022/2025 fits | **CVE-2025-0725** (libcurl), plus Windows fixes 38141444 (IIS module) and 38381381 (`webgate.log` on Windows) – binaries only, no OAM in use |

## Open points for the customer

| # | Question |
|---|---|
| 1 | ~~Windows version?~~ **Clarified 2026-10-26: Windows Server 2025.** By the last check FMW / Reports 14.1.2 are certified for 2022 only (check the [Certification Matrix](https://www.oracle.com/middleware/technologies/fusion-certification.html) again before the installation); 2025 is tested successfully on pipperr.de (installation, Builder starts). Consequences: the installer prerequisite check may object to 2025 (then "Skip" or `-ignoreSysPrereqs`), and Oracle Support may point to a certified platform in an SR. WebGate BP: minimum OS 2022 – fits. Open: English OS? |
| 2 | Database for the RCU prefix (host/service, DBA for RCU) – the same as for the Linux server? Prefix name? |
| 3 | ~~How many developers?~~ **Clarified 2026-10-26: 2 developers** (simultaneously via RDP). RAM: 8 GB base + roughly 0.5–1 GB per Builder session → **12 GB** are enough with a reserve (assumption, measure in operation); Windows Server 2025 allows 2 simultaneous admin RDP sessions without RDS licences – **clarified 2026-10-27:** the developers work with local admin accounts (normal accounts fail on the rights below `E:\oracle`, see "Multi-user operation"), so the 2 admin sessions are enough; RDS only from the third simultaneous user on. |
| 4 | Storage of the report sources (network drive, Git?) and the way to the Linux server (share, sftp, deployment script) |
| 5 | Anti-virus: exclusions for the Oracle home during installation and patching |
| 6 | ~~Windows variants of the platform-specific patches on MOS?~~ **Clarified 2026-10-26: all available** (platform "Microsoft Windows x64 (64-bit)"): Reports 39600348 (3.5 MB, 2026-08-17), PERL 39951765 (38.4 MB, 2026-10-19), OHS 39987730 (20.3 MB, 2026-10-19), WebGate 39100536 (11.1 MB, 2026-04-21). The MOS title of the Reports QPR ("MERGE REQUEST … FOR BUGS 38991174 37866660 39375353") names only the bugs of the merge request – the **Windows README lists 31 bugs**, identical to the inventory of the Linux test host (`lsinventory -bugs_fixed`, compared 2026-10-26). Builder and server therefore have the same Reports level. |
| 7 | **Done 2026-10-28:** downloading the MOS patches one by one by hand took too long at the appointment (about 15 files, ~7 GB, platform chosen per patch). For that there is now [tools/bash/mos_patch_download.sh](../tools/README.md#mos_patch_downloadsh) (Windows variant since 2026-11-03: [tools/powershell/mos_patch_download.ps1](../tools/powershell/README.md#mos_patch_downloadps1), plus `collect_fmw_env.ps1` / `fmw_patch_env.ps1`; Windows platform `233P`): one CSV list (patch number, platform `233P` / generic `2000P`, file regexp, mandatory/optional) loaded in one run with getMOSPatch, `unzip -t` + SHA-256 – in advance on a machine with MOS access, then the files as a package to the customer. The CSV for this download checklist will be created from the cookbook at the next appointment (template: `FormsReports12_patch_cpu_2026-10/patches_cpu_reports_14c_oct2026.csv`). |
| 8 | **RCU DB day to day:** the Reports tools do not use the RCU schemas at runtime (measured 2026-10-27 with `strace` on `rwconverter` on the Linux test system: no OPSS / wallet file, no AdminServer, only the login of the report) – the own RCU DB on the builder server is only needed for domain changes and a version upgrade, service set to "Manual". **Open:** start the Builder once with the DB service stopped and create a preview (Builder GUI not measured yet). Details: cookbook step 10, [reports_rwbuilder.md §3.2/3.3](../../80-FMW-Architecture/reports_rwbuilder.md#32-what-the-builder-still-needs-at-runtime). |

Status: **confirmed live 2026-10-27** at the customer (Windows Server 2025,
CPU October 2026) – the cookbook was run step by step and worked exactly
like this; the only addition: developer accounts with local admin rights
(see "Multi-user operation"). English cookbook: translated 2026-11-11 from
the German version (same commands, checked line by line).
