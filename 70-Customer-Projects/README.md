# 70-Customer-Projects

Practical, real-world installation examples collected from actual customer
projects and installations — independent of the IHateWeblogic scripts in the
numbered folders above. One subfolder per customer/scenario, each a
self-contained, copy-paste-able walkthrough rather than generated script
output.

## Available Walkthroughs

### Oracle Reports 14.1.2 – Manual Install (German)

→ [Reports14_Only_manuall_install/README.md](Reports14_Only_manuall_install/README.md)

A manual, step-by-step installation guide (in German) for a Reports-only
FMW 14.1.2 environment (WebLogic 14.1.2, Oracle Linux 9) — six self-contained
"Kochbuch" text files a customer can follow without using any of the
IHateWeblogic scripts.

### Oracle Reports Builder 14.1.2 on Windows – Development Environment (German)

→ [Reports14_ReportBuilder_MS_Windows/README.md](Reports14_ReportBuilder_MS_Windows/README.md)

Same customer as the Reports-only Linux install: a minimal **Reports Builder**
environment on a central Windows Server (developers via RDP). Analysis of the
Oracle docs (no "Standalone Reports Builder" like for Forms – the Reports Tools
template needs JRF + EM + RCU) and a cookbook for a builder-only domain without
Reports server, Windows services or SSL; reports are tested on the Linux server.
**Live-confirmed 2026-10-27** at the customer (Windows Server 2025, CPU
October 2026) – developers need local admin accounts (the installer breaks the
ACL inheritance under the Oracle base).

### Oracle Forms & Reports 12.2.1.19 – Patch Analysis CPU October 2026 (English)

→ [Forms12_reports12_patch_analyse_10_2026/README.md](Forms12_reports12_patch_analyse_10_2026/README.md)

Patch list for an existing Forms & Reports 12.2.1.19 home (FMW
Infrastructure / WebLogic 12.2.1.4) from KA1182 of October 2026 plus the
Java Security Alert CVE-2026-91403 (server JDK 8 and client JRE), with the
CVE background and the questions to clarify with the customer – applied by
hand, no scripts.

### Oracle Forms & Reports 14.1.2 – Patch Set CPU October 2026 (English)

→ [Forms14_reports14_patch_analyse_10_2026/README.md](Forms14_reports14_patch_analyse_10_2026/README.md)

The reference stack of this library (Forms & Reports 14.1.2, OL9, Nginx):
analysis of the CPU October 2026 patch set with the facts of every patch
README, and a manual step-by-step guide
([install_14c_patch_set_october_2026_manual.md](Forms14_reports14_patch_analyse_10_2026/install_14c_patch_set_october_2026_manual.md)).
**One folder per patch cycle** – the versioned history of the manual
procedure, while the scripts always follow the current cycle; older folders
are frozen. Cycle table: [09-Install/docs/00-patch-references.md](../09-Install/docs/00-patch-references.md).

### tools – shared collector (12c and 14c)

→ [tools/README.md](tools/README.md)

`collect_fmw_env.sh`: standalone, read-only collection of OS, Java, Oracle
Home / patches, domain, Forms / Reports / OHS / web server configuration into
one archive for the analysis; secrets masked. Works for 12.2.1.x and 14.1.2.

## Further Installation Guides (German)

Additional practical installation walkthroughs for other WebLogic-related
topics from real projects, published on the author's blog
([pipperr.de](https://pipperr.de)) — also in German, not part of this
repository.

**Oracle Reports – Windows**
- 14c: https://pipperr.de/dokuwiki/doku.php?id=forms:oracle_reports_14c_windows64
- 12c R2: https://pipperr.de/dokuwiki/doku.php?id=forms:oracle_reports_12c_r2_windows64
- 11g R2: https://pipperr.de/dokuwiki/doku.php?id=forms:oracle_reports_11g_r2_windows64

**Oracle WebLogic Based Products**

*Oracle WebLogic – Linux*
- WebLogic 10.3.5 Install: https://pipperr.de/dokuwiki/doku.php?id=prod:weblogic_10_3_5_install_linux

*Oracle BI Publisher – Linux*
- BI Publisher 11g Install: https://pipperr.de/dokuwiki/doku.php?id=prod:bipublisher_11g_install

**Enterprise Manager / Cloud Control**
- Cloud Control 12c Install: https://pipperr.de/dokuwiki/doku.php?id=dba:cloudcontrol_12c_oracle_install

**Primavera**
- Primavera P6 8 Web Install: https://pipperr.de/dokuwiki/doku.php?id=prod:primavera_p6_p_8_web_install
- Primavera P6 15.1 Web Install: https://pipperr.de/dokuwiki/doku.php?id=prod:primavera_p6_p_15_1_web_install
