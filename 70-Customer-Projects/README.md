# 70-Customer-Projects

Practical, real-world installation examples collected from actual customer
projects and installations — independent of the IHateWeblogic scripts in the
numbered folders above. One subfolder per customer/scenario, each a
self-contained, copy-paste-able walkthrough rather than generated script
output.

## First steps at a customer – the road map

→ [Start_beim_Kunden_kochbuch_de.txt](Start_beim_Kunden_kochbuch_de.txt) (German, step by step)

Every customer engagement on Linux starts the same way, whatever the folder:

1. **Tools:** one link – `tools/ihw_customer_tools_linux.zip` (Windows:
   `…_windows.zip`), unpacked into `$ORACLE_BASE` = `$ORACLE_BASE/tools`; no
   git clone at the customer. Built with `tools/make_customer_zip.sh --apply`
   before every commit that touches the tools.
2. **setdb:** `tools/bash/ihw_shell_env.sh` → `~/.bashrc.d/ihw_env.sh`, new
   shell – one menu for the FMW home / domains and DB homes, PATH on the
   tools, `wlst`, `domain`.
3. **One ini:** the `patch_install.ini` of the customer folder (template:
   [Reports14_linux_manual_install/patch_install.ini](Reports14_linux_manual_install/patch_install.ini))
   to `$ORACLE_BASE/tools` (600), plus the `patches_cpu_*.csv` when patching.
4. **Existing environment?**
   - yes → analysis with `collect_fmw_env.sh`, fill / check the ini from its
     `00_summary.txt`;
   - no → fill the ini from the installation cookbooks.
5. **In both cases** `. $ORACLE_BASE/tools/set_script_env.sh` in every new
   session – then the cookbooks of the customer folder; `status.sh` /
   `show_log.sh` / `show_errors.sh` read the same ini.

So a customer folder holds only **one ini, one csv and the cookbooks**; all
scripts are shared in `tools/bash/`.

**Moving to 14c:** export the old environment at the first visit
(`export_forms_reports_conf.sh`, next to `collect_fmw_env.sh`). The whole
process – analysis, build with the customer's data, check again – is in
[09-Install/docs/00-transfer_customer_settings.md](../09-Install/docs/00-transfer_customer_settings.md).

## Writing a cookbook

→ [cookbook-Skill.md](cookbook-Skill.md) – style rules for every customer
cookbook (any language, bash / PowerShell / cmd): one command per line with
blank lines around it, no nesting (intermediate variables instead), derived
paths, "Expected" output under each command, rollback in every step.

## Available Walkthroughs

### Oracle Reports 14.1.2 – Manual Install (German)

→ [Reports14_linux_manual_install/README.md](Reports14_linux_manual_install/README.md)

A manual, step-by-step installation guide (in German) for a Reports-only
FMW 14.1.2 environment (WebLogic 14.1.2, Oracle Linux 9) — six self-contained
"Kochbuch" text files a customer can follow without using any of the
IHateWeblogic scripts, with all values in one
[patch_install.ini](Reports14_linux_manual_install/patch_install.ini).

### Oracle Reports Builder 14.1.2 on Windows – Development Environment (German)

→ [Reports14_builder_windows/README.md](Reports14_builder_windows/README.md)

Same customer as the Reports-only Linux install: a minimal **Reports Builder**
environment on a central Windows Server (developers via RDP). Analysis of the
Oracle docs (no "Standalone Reports Builder" like for Forms – the Reports Tools
template needs JRF + EM + RCU) and a cookbook for a builder-only domain without
Reports server, Windows services or SSL; reports are tested on the Linux server.
**Live-confirmed 2026-10-27** at the customer (Windows Server 2025, CPU
October 2026) – developers need local admin accounts (the installer breaks the
ACL inheritance under the Oracle base).

### Oracle Forms & Reports 12.2.1.19 – Patch Analysis CPU October 2026 (English)

→ [FormsReports12_patch_cpu_2026-10/README.md](FormsReports12_patch_cpu_2026-10/README.md)

Patch list for an existing Forms & Reports 12.2.1.19 home (FMW
Infrastructure / WebLogic 12.2.1.4) from KA1182 of October 2026 plus the
Java Security Alert CVE-2026-91403 (server JDK 8 and client JRE), with the
CVE background and the questions to clarify with the customer – applied by
hand with the German cookbook `Patch_Kochbuch_CPU_Okt2026_de.txt` (manual run
at the customer 2026-10-29). Download list
[patches_cpu_forms_reports_12c_oct2026.csv](FormsReports12_patch_cpu_2026-10/patches_cpu_forms_reports_12c_oct2026.csv)
for `tools/bash/mos_patch_download.sh`.

### Oracle Forms & Reports 14.1.2 – Patch Set CPU October 2026 (English)

→ [FormsReports14_patch_cpu_2026-10/README.md](FormsReports14_patch_cpu_2026-10/README.md)

The reference stack of this library (Forms & Reports 14.1.2, OL9, Nginx):
analysis of the CPU October 2026 patch set with the facts of every patch
README, and a manual step-by-step guide
([install_14c_patch_set_october_2026_manual.md](FormsReports14_patch_cpu_2026-10/install_14c_patch_set_october_2026_manual.md)).
**One folder per patch cycle** – the versioned history of the manual
procedure, while the scripts always follow the current cycle; older folders
are frozen. Cycle table: [09-Install/docs/00-patch-references.md](../09-Install/docs/00-patch-references.md).

### tools – standalone helpers for customer hosts (12c and 14c)

→ [tools/README.md](tools/README.md)

No IHateWeblogic library needed – copy the script to the host:

| Script | Purpose |
|---|---|
| `collect_fmw_env.sh` | read-only collection of OS, Java, Oracle Home / patches, domain, Forms / Reports / OHS / web server configuration into one archive for the analysis; secrets masked |
| `mos_patch_download.sh` | downloads a patch list (CSV per cycle) from MOS with getMOSPatch in one run, `unzip -t` + SHA-256 (used at the customer 2026-10-29) |
| `clone_check_fmw.sh` | read-only check whether the installation is clone-capable (golden image) – e.g. after the 12c patch run |
| `fmw_patch_env.sh` | detects and sets the variables of the manual patch cookbooks (`ORACLE_HOME`, `DOMAIN_HOME`, `INV_PTR`, `JDK_LINK`, `PATCH_DIR` …) – sourced |
| `ihw_shell_env.sh` | `setdb` / `setfmw`: one menu to switch the shell between FMW home / domains and DB homes / SIDs (`~/.bashrc.d/ihw_env.sh`) |
| `set_script_env.sh` | loads the customer's `patch_install.ini` into the session for the cookbook commands – sourced |
| `status.sh`, `show_log.sh`, `show_errors.sh`, `show_all_logs.sh` | operation: status in three stages (ports / processes / HTTP + Node Manager), logs and error lines – read `patch_install.ini` next to them |
| `check_disk_space.sh`, `export_forms_reports_conf.sh` | disk space before a patch run; read-only export of the Forms / Reports configuration (12c → 14c) |
| `analyse_forms_reports_export.sh` | (our host) export → analysis report for the customer with the 14c target mapping and security findings; output git-ignored in `tools/customer-analyse/` |
| `ihw_tools_lib.sh` | shared helpers of the tools (sourced, always copied with them) |

Linux: `tools/bash/`. Windows Server hosts: `tools/powershell/` –
`collect_fmw_env.ps1`, `fmw_patch_env.ps1`, `mos_patch_download.ps1`, same
output / CSV format → [tools/powershell/README.md](tools/powershell/README.md)

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
