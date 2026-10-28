# Reports Builder minimal setup – a builder-only Windows server

> Certificates, keys and trust stores of the whole stack (terms, where what lives, who needs what, customer PKI / TLS interception): [certificates_trust_stores.md](certificates_trust_stores.md)

How to give report developers the **Oracle Reports Builder 14.1.2** with as
little Fusion Middleware as possible: one central Windows Server, developers
work via RDP, the reports are designed there and executed on the existing
Linux Reports server. This document explains the architecture and why it
looks like this; the step-by-step installation is the German customer
cookbook
[ReportBuilder_Windows_Kochbuch_de.txt](../70-Customer-Projects/Reports14_ReportBuilder_MS_Windows/ReportBuilder_Windows_Kochbuch_de.txt)
(background and decisions in German:
[README.md](../70-Customer-Projects/Reports14_ReportBuilder_MS_Windows/README.md)).

Markers as in [README.md](README.md): **confirmed (live)** = customer
installation 2026-10-27 (Windows Server 2025, CPU October 2026 – the
cookbook was run step by step and worked as written), **documented** =
Oracle documentation ([Sources](#10-sources)), **assumption** = not verified.
Related: [report_engine_architecture.md](report_engine_architecture.md)
(Reports server, engines, ReportsTools instance),
[rcu_middleware_architecture.md](rcu_middleware_architecture.md) (RCU,
database requirements).

---

## 1. The idea

Developers only need the **Builder** – a desktop tool that opens `.rdf`
files, connects to the application database and shows a preview. They do
not need a Reports server, `rwservlet`, WebLogic managed servers, SSL or
Windows services. A complete Reports installation on Windows brings all of
that, and on Windows exactly those parts are the expensive ones: services
and autostart, SSL, memory growth of long-running JVMs
([pipperr.de – Reports 14c on Windows](https://pipperr.de/dokuwiki/doku.php?id=forms:oracle_reports_14c_windows64)).

So the goal was: **install the software, keep everything that runs
permanently away.** Reports are tested where they will run in production –
on the Linux Reports server.

## 2. What Oracle does not offer – and what is unavoidable

| Fact | Consequence | Marker |
|---|---|---|
| The Forms & Reports installer has two installation types: "Forms and Reports Deployment" and **"Standalone Forms Builder"** – the latter is an Oracle Home without a domain, but contains **no** Reports Builder | there is no "Standalone Reports Builder"; the full "Forms and Reports Deployment" is installed | **documented** (Install 12.2.1.3 §2.4.4; Reports 14.1.2 is installed by the 12.2.1.3 guide) |
| "**One ReportsTools component is compulsory**" – the Builder reads its configuration (`rwbuilder.conf`, `uifont.ali`, printer files, log directory) from a **ReportsTools instance** of a domain | a domain is needed | **documented** (§2.4.7) |
| The instance is created with WLST `createReportsToolsInstance()` against a **running AdminServer** | the AdminServer must run – but only once | **documented** (§2.4.7.1/3), **confirmed (live)** |
| The domain template "Oracle Reports Tools" pulls in **Oracle JRF** (full) and **Enterprise Manager** – unlike "Oracle Forms Development" (Restricted JRF, no database) | **RCU schemas are mandatory** – a database prefix is needed even for the Builder | **confirmed** (`template-info.xml`, WLST offline `selectTemplate`, 14.1.2 test host 2026-10-26) |

Result: a domain with RCU cannot be avoided – the **running server stack**
can.

## 3. Architecture

```
  Developer workstation                Windows Server (central, RDP)
  ---------------------                ---------------------------------------------
  RDP client  ----- RDP ----------->   rwbuilder.bat  (one process per developer)
                                         |  reports.bat: TNS_ADMIN, REPORTS_PATH, ...
                                         |
                                         +-- Oracle Home E:\oracle\fmw
                                         |     FMW Infrastructure + Forms & Reports,
                                         |     patched like the Linux server
                                         |
                                         +-- Builder domain (AdminServer STOPPED)
                                         |     templates: JRF + EM + Reports Tools only
                                         |     no managed server, no Node Manager running
                                         |     config/fmwconfig/components/
                                         |        ReportsToolsComponent/reptools1
                                         |        (rwbuilder.conf, uifont.ali, ...)
                                         |
                                         +-- fonts (same TTFs as the Linux server)

                    SQL*Net                                  file copy / share / sftp
  existing customer database  <-----------+          +-------------------------------->
    - application schemas (reports data)  |          |
    - RCU prefix RWDEV_* (domain only)    |          v
                                          |   Linux Reports server (production stack)
                                          |     WLS_REPORTS / rwservlet / engines
                                          +---- runs the .rdf for the real test
```

What runs when:

| Phase | What runs | How often |
|---|---|---|
| Installation, patching | installers, OPatch (as the installation account) | per patch cycle |
| Create domain | Configuration Wizard (`config.cmd`), reads RCU prefix | once |
| Create ReportsTools instance | AdminServer in the foreground + WLST `createReportsToolsInstance(instanceName='reptools1', ...)`, then AdminServer stopped | once |
| **Daily work** | **only `rwbuilder.bat`** – no WebLogic, no Windows service | every session |
| Test the report | the Linux Reports server (`rwservlet`) | per report change |

**confirmed (live)** 2026-10-27: the AdminServer is not running during daily
work, the Builder starts from `DOMAIN_HOME\reports\bin\rwbuilder.bat`.

### 3.1 Builder domain vs. full Reports domain

| Part | Full Reports installation (server) | **Builder domain** |
|---|---|---|
| Software | FMW Infrastructure + Forms & Reports | same – one Oracle Home |
| RCU | own prefix | own prefix (`RWDEV`) in the **existing** database |
| Domain templates | JRF, EM, Reports Tools, Reports Server, Reports Application, Reports Bridge, OHS | **JRF + EM + Reports Tools only** |
| Managed servers | `WLS_REPORTS` (+ cluster, machine, Node Manager) | **none** – AdminServer only (one machine for the instance) |
| Domain mode | Production (secure mode, `t3s`) | **Development** (`t3`, AdminServer on `127.0.0.1` only) |
| AdminServer | permanent (Windows service) | **once**, for `createReportsToolsInstance` |
| Windows services / autostart / SSL | needed | **none** |
| Reports execution | local `rwservlet` | on the **Linux** Reports server |

### 3.2 What the Builder still needs at runtime

- **The ReportsTools instance** (`reptools1`) – configuration files only,
  no process (see [report_engine_architecture.md §1](report_engine_architecture.md#1-the-parts)).
- **`reports.bat`** of the domain – sets the environment for the tools:
  `TNS_ADMIN` (= `DOMAIN_HOME\config\fmwconfig`, one `tnsnames.ora` for all
  developers) and `REPORTS_PATH` (sources, libraries, images).
  **confirmed (live)**.
- **The application database** via SQL*Net (the developer's connect).
- **Not the RCU schemas.** The Reports tools do not touch the repository
  at runtime – **confirmed (live)** 2026-10-27 on the Linux test host with
  `strace` (`-e trace=openat,connect`) on `rwconverter` (`rdf → xml`), which
  uses the same tools runtime and the same `reptools1` instance as the
  Builder:

  | Run | Network connections | OPSS / wallet files |
  |---|---|---|
  | without `userid` (stops at the logon) | **none** – only local Unix sockets | no `jps-config*.xml`, no `cwallet.sso` / bootstrap wallet opened |
  | with `userid` (test user) | **exactly one** TCP connection to port 1521 = the report's own logon | none |

  Read from the domain: only files of the ReportsTools instance
  (`tools/admin/prefs.ora`, AFM / PPD of `guicommon`); no connection to the
  AdminServer (7001). The OPSS / JDBC JARs are on the class path, but
  nothing opens the OPSS store.
  The **Builder GUI** itself could not be traced on the test host (no
  display) – **assumption** with high confidence (same runtime); test at
  the customer: stop the RCU database service, start `rwbuilder.bat`,
  connect to the application DB, run a preview.

### 3.3 What the RCU database is still needed for

| Task | Needs the RCU DB (+ AdminServer) |
|---|---|
| daily Builder work (`rwbuilder`, `rwconverter`, `rwrun`) | **no** (3.2) |
| OPatch patches of the Oracle Home | **no** – they change only the Oracle Home ([rcu_middleware_architecture.md §7](rcu_middleware_architecture.md#7-patching-and-the-schemas--how-oracle-intends-it)) |
| change the domain, create another ReportsTools instance, start the AdminServer (OPSS lives in `<prefix>_OPSS`) | **yes** |
| version upgrade (14.1.2 → next release): Upgrade Assistant upgrades schemas **and** domain | **yes** – without the schemas an upgrade means a new installation |

Consequence for a builder server with its **own** RCU database: keep the
schemas and the database installation, but the database service does not
have to run during daily work – start type "manual", started only for
domain changes and upgrades; saves memory for the RDP sessions. Keep the
`RWDEV_*` accounts in the profile without password expiry (`RCU_USER`)
anyway – an expired account surfaces only when the AdminServer is needed
again, i.e. at the worst moment.

## 4. Windows specifics

| Topic | Fact | Marker |
|---|---|---|
| **Developer accounts** | A normal user cannot start the Builder: the Oracle installer **breaks the ACL inheritance** under the Oracle base (`E:\oracle`), a group granted on `E:\oracle` does not reach the subfolders; setting ACLs folder by folder is error-prone and has to be repeated after patches (**assumption** for patches). Decision: one personal account per developer in the local group "Administrators" | **confirmed (live)** 2026-10-27 |
| Own RCU database on the builder server | only needed for domain changes and upgrades (3.3) – service start type "manual" | **confirmed (live)** for the tools runtime (`strace`), Builder GUI test open |
| RDP sessions | Windows Server allows **2 concurrent administrative RDP sessions without RDS licences** – fits 2 developers with admin accounts; from the third concurrent user the customer needs Remote Desktop Services licensing | **documented** (Windows Server) |
| One installation account | install and patch always with the same local admin account (OPatch: "same user as the installation"), `cmd` "Run as administrator" | **documented** (patch READMEs) |
| Visual C++ runtime | x64 **and** x86 redistributable, otherwise "MSVCP100.dll not found" | **documented** (pipperr.de), part of the cookbook |
| Path / environment length | short paths without blanks – long environment variables break Reports on Windows; patch ZIPs with "path too long" are unpacked with the JDK's `jar` | **documented** (Install 12.2.1.3 App. B.3, patch READMEs) |
| Windows Server 2025 | FMW 14.1.2 certified for Windows Server 2022 at the time of writing; 2025 works (installer prerequisite check may complain → skip). Oracle Support may point to a certified platform | **confirmed (live)** for the installation; certification = check the matrix |
| Patching | the WLS Stack Patch Bundle ships `windows64_patchlist.txt` (`opatch napply`) and the Windows DB client; platform patches (Reports QPR, Perl, OHS, WebGate) exist as "Microsoft Windows x64" | **confirmed (live)** 2026-10-27 (CPU October 2026) |

## 5. Keeping Builder and server consistent

A report that looks right in the Builder must look the same on the server.
The minimal setup works only if these four things are kept identical:

| Item | Why | Where |
|---|---|---|
| **Patch level** | a report saved by a newer Builder must run on the server; same CPU cycle, Windows variants of the same patch numbers | cookbook step 4, Linux cookbooks |
| **Fonts + `uifont.ali`** | the preview uses the Windows fonts; the PDF on the server uses `uifont.ali` + TTF/AFM – different fonts = different layout | cookbook step 8.3, [Font cookbook](../70-Customer-Projects/Reports14_Only_manuall_install/Font_kochbuch_de.txt) |
| **Connect aliases** | same `tnsnames.ora` entries on both sides | `DOMAIN_HOME\config\fmwconfig` vs. server `TNS_ADMIN` |
| **Paths** | images / libraries via `REPORTS_PATH`; Windows paths in reports have no fallback on Linux (`REP-108`) – references carry the file name only (section 6) | [report_server_image_handling.md](report_server_image_handling.md) |

## 6. Development workflow – from the old report to the Linux DEV server

How a developer changes an existing report with this setup (customer
process, agreed 2026-10-27; the Git automation belongs to the customer –
**assumption** for its details):

```
  1 copy        2 edit in the Builder          3 git commit / push     4 automation        5 test
  old .rdf  --> Windows Server (RDP)       --> repository           --> Linux DEV        --> rwservlet
  (prod/old     - change layout / query        (one place for the       Reports server       on the DEV
   source)      - image references: path       sources, history,        source dir in        server, as in
                  removed, FILE NAME only       review)                  REPORTS_PATH         production
                  (found via REPORTS_PATH)
```

1. **Copy the "old" report** onto the Windows Server – into the developer's
   working copy of the repository (or the shared source directory,
   cookbook step 8.2).
2. **Edit it in the Builder.** Typical clean-up while doing so: image
   elements ("Read from File" / link file) that still carry a **full path**
   (often a Windows path from the old environment, `D:
eports\img\logo.gif`)
   get only the **file name** (`logo.gif`). The file is then found through
   **`REPORTS_PATH`** – on Windows through the `REPORTS_PATH` of
   `reports.bat`, on Linux through the `REPORTS_PATH` and `<folderAccess>`
   of the Reports server. A full Windows path has **no fallback** on the
   Linux server (`REP-108`) – details and a test series:
   [report_server_image_handling.md](report_server_image_handling.md)
   (sections 2 "How a file name is resolved", **2.1 "Who searches where –
   and with which separator"**, 3 `<folderAccess>`, 5 "Normalising the image
   references"). Same file names in lower case on both sides.
3. **Check the report in with Git** (commit / push from the working copy) –
   the repository is the only place the source lives; no copies on file
   shares.
4. **Git automation deploys it to DEV:** the customer's pipeline copies the
   `.rdf` (and images / libraries, if changed) into the source directory of
   the Linux **DEV** Reports server – a directory that is part of its
   `REPORTS_PATH` and of `<folderAccess><read>` (one element, directories
   separated by `;`).
5. **Run it on the Linux server:** the developer calls the report through
   the DEV `rwservlet`, e.g.
   `https://<dev-server>/reports/rwservlet?report=<name>.rdf&destype=cache&desformat=pdf&<cmdkey>`
   (connect from a `cgicmd.dat` key, no password in the URL –
   [Reports_security.txt](../70-Customer-Projects/Reports14_Only_manuall_install/Reports_security.txt)). This is the real test: server fonts / `uifont.ali`,
   Linux paths, the server's patch level.

Why this order: the Builder preview (Windows fonts, Windows paths) is only a
first check – what counts is the output of the server the report will run
on. Names instead of paths make the same `.rdf` work on Windows (Builder)
and Linux (server) unchanged.

Prerequisites on both sides:

| | Windows Server (Builder) | Linux DEV server |
|---|---|---|
| Image / library search | `REPORTS_PATH` in `DOMAIN_HOME\reports\bin\reports.bat` incl. the image directory of the working copy – separator **`;`** | `REPORTS_PATH` in `rwserver.conf` and `reports.sh` – separator **`:`**; `<folderAccess><read>` (one element) – separator **`;`**; both incl. the deploy directory, server restarted after a change |
| Fonts | same TTFs + `uifont.ali` as the server | reference |
| Connect aliases | `tnsnames.ora` in `DOMAIN_HOME\config\fmwconfig` | server `TNS_ADMIN` – same alias names |
| Git | working copy per developer (Git client on the Windows Server) | target of the automation (deploy directory) |

## 7. Alternatives that were not chosen

| Alternative | Why not |
|---|---|
| Full Reports server installation on Windows | services, autostart, SSL, long-running JVMs – the expensive part on Windows, and the reports run on Linux anyway |
| "Standalone Forms Builder" installation | contains no Reports Builder |
| Builder on every developer PC | every PC needs the same Oracle Home, domain and RCU prefix, patched per cycle – one central server is one installation to patch |
| Domain without RCU (Restricted JRF) | the Reports Tools template requires full JRF + EM → not possible |

## 8. Lifecycle

- **Patching:** every cycle the same patch numbers as the Linux server in the
  Windows variant; all Builder sessions closed, VM snapshot first.
- **JDK:** the domain uses a version-neutral junction (`E:\Java\jdk-21` →
  current JDK) – a JDK update is "new JDK beside it, move the junction".
- **AdminServer:** only needed again to create another ReportsTools instance
  or to change the domain.
- **Next time:** the MOS downloads (about 15 patches, ~7 GB) took too long
  one by one – a download script with a patch list is an open item (root
  README, "Scripts").

## 9. Status

Implemented and **confirmed (live)** at the customer on 2026-10-27 – the
cookbook ran as written; the only addition from the live run is the
local-admin requirement for the developer accounts (section 4).

## 10. Sources

- Oracle Forms 14.1.2 installation guide, chapter "About Oracle Reports"
  (Reports 14.1.2 unchanged since 12.2.1.3, deprecated, installed by the
  12.2.1.3 guide):
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/install-fnr/oracle-reports.html
- Installing and Configuring Oracle Forms and Reports 12.2.1.3 – installation
  types (§2.4.4), ReportsTools instance / `createReportsToolsInstance`
  (§2.4.7), Windows environment limits (App. B.3):
  https://docs.oracle.com/middleware/12213/formsandreports/install-fnr/installing-and-configuring-oracle-forms-and-reports1.htm
- Oracle Fusion Middleware Supported System Configurations (Windows Server
  versions): https://www.oracle.com/middleware/technologies/fusion-certification.html
- pipperr.de – Oracle Reports 14c on Windows (services, Visual C++ runtime,
  `TNS_ADMIN` in `reports.bat`):
  https://pipperr.de/dokuwiki/doku.php?id=forms:oracle_reports_14c_windows64
- Patch READMEs of the CPU October 2026 Windows patches (39600348, 39951765,
  39987730, 39100536) – facts in the
  [folder README](../70-Customer-Projects/Reports14_ReportBuilder_MS_Windows/README.md)
- Customer installation 2026-10-27 (Windows Server 2025) – cookbook
  [ReportBuilder_Windows_Kochbuch_de.txt](../70-Customer-Projects/Reports14_ReportBuilder_MS_Windows/ReportBuilder_Windows_Kochbuch_de.txt)
