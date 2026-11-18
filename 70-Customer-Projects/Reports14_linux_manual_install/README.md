---
nav_title: "Reports 14 – manual install"
title: "Oracle Reports 14.1.2 – Manual Install Without Forms"
description: "Oracle Reports 14.1.2 without Forms on Oracle Linux 9 by hand: German text cookbooks for OS, WebLogic, SSL, Reports, fonts, start/stop, security and patching."
permalink: /70-Customer-Projects/Reports14_linux_manual_install/
---

# Oracle Reports 14.1.2 – manual installation (without Forms)

Customer-specific guide for a Reports-only installation (FMW 14.1.2,
WebLogic 14.1.2, Oracle Linux 9) that the customer can follow step by step
without the IHateWeblogic scripts. Every file is a self-contained plain-text
cookbook with copy-paste commands and **German** comments.

## Order

1. [OS_Kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/OS_Kochbuch_de.txt) – prepare the operating system:
   packages, Java, oracle user, network basics on Oracle Linux 9;
   step 9: harden firewall and SSH (with a safety net).
2. [FMW_Kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/FMW_Kochbuch_de.txt) – install and patch the
   WebLogic / FMW Infrastructure (CSPU November 2026: OPatch 13.9.4.2.25, WLS
   Stack Patch Bundle 40289362, eight FMW Infrastructure bundles) and roll
   out the SSL certificate on Nginx.
3. [SSL_Kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/SSL_Kochbuch_de.txt) – create and check the SSL
   certificate (creation and checks only; the rollout is in the FMW
   cookbook).
4. [Reports_kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/Reports_kochbuch_de.txt) – install and patch
   Oracle Reports (Reports QPR, PERL, OHS / WebGate binaries), register the
   RCU schema, create the WebLogic domain and configure the Reports server
   (deliberately without Forms).
5. [Font_kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/Font_kochbuch_de.txt) – set up TrueType fonts and the
   font path of the HTML parameter form for Reports.
6. [WLS_Report_start_stop_kochbuch.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/WLS_Report_start_stop_kochbuch.txt) –
   start, stop and check the environment in daily operation, without any
   dependency on the IHateWeblogic scripts:
   - **Step 0 – by hand with the Oracle scripts:** overview of the
     start / stop scripts Oracle ships in `$DOMAIN_HOME/bin/`
     (`startWebLogic.sh`, `startNodeManager.sh`, `startManagedWebLogic.sh`,
     `startComponent.sh` and their `stop*` counterparts). They start
     AdminServer, Node Manager, managed server and Reports server one by one
     and stop them in reverse order – e.g. for troubleshooting or to restart
     a single component.
   - **Status of all four components:** AdminServer and managed server via
     `/weblogic/ready` (HTTP 200), Node Manager via port 5556 and process,
     Reports server via the `rwserver` process and `getserverinfo` (engine
     status `1` = ready). Important: `getserverinfo` needs the server
     administrator from `<identifier>` in `rwserver.conf` as `authid`, not a
     WebLogic user.
   - **Steps 1–4 – everything at once:** two own scripts
     `start_wls_all.sh` / `stop_wls_all.sh` (in `/u01/oracle/tools`, values
     from [`patch_install.ini`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/patch_install.ini)) that always start or stop the
     whole environment in the right order (the WebLogic password for the
     stop is asked for hidden and stored nowhere).
   - **Known problems:** among others the server dies right after the start
     (missing `boot.properties`, `BEA-090782`), `REP-52262` on the status
     query, a server lock `<server>.lok` still held by an old process.

   Once the autostart (item 7) is set up, the environment is operated only
   with `systemctl start/stop` – the commands of this cookbook are then for
   troubleshooting only.
7. [Autostart_linux_middleware.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/Autostart_linux_middleware.txt) –
   automatic start / stop at boot and shutdown with a systemd unit (waits
   for "RUNNING" instead of fixed pauses, stop without a password prompt via
   `boot.properties`).

8. [Reports_security.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/Reports_security.txt) – hardening of the finished
   Reports / WebLogic environment (after SSL): ports / firewall, Nginx
   (headers, `/em` for admins only, Reports administration commands such as
   `showenv` blocked from outside), password policy and account lockout,
   personal admin accounts, Reports users / roles / policies, Reports server
   administrator `<identifier>`, `rwservlet.properties`, file permissions,
   Node Manager, sudo, patch level, password changes. Users and roles each
   through the UI (Enterprise Manager) **and** as WLST commands to type in.

9. [Tools_status_logs_kochbuch.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/Tools_status_logs_kochbuch.txt) –
   small operations scripts from [`../tools/bash/`](https://github.com/gpipperr/IHateWeblogic/tree/main/70-Customer-Projects/tools/bash), placed in
   `/u01/oracle/tools` following
   [../Start_beim_Kunden_kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Start_beim_Kunden_kochbuch_de.txt)
   (without the IHateWeblogic lib; values in [`patch_install.ini`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/patch_install.ini);
   `setdb` sets the PATH to the tools, `wlst` and `domain`):
   - [`status.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/tools/bash/status.sh) – state in three levels: ports (`ss`), processes (`ps`,
     incl. "started by the Node Manager?" and number of Reports engines),
     status via `/weblogic/ready` and the Node Manager (WLST with the stored
     storeUserConfig credentials); return code 0/1/2.
   - [`show_all_logs.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/tools/bash/show_all_logs.sh) – all current logs of the domain live (`tail -F`).
   - [`show_errors.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/tools/bash/show_errors.sh) – error lines only (`<Error>`, `REP-`, `BEA-`,
     `JPS-`, exceptions …), with `-r` first the latest errors, then live.
   - [`show_log.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/tools/bash/show_log.sh) – the current log of one component (Node Manager,
     AdminServer, managed server, Reports server / engines) from a menu or
     directly (`show_log.sh reports engine`).
   - `patch_install.ini` + [`set_script_env.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/tools/bash/set_script_env.sh) – all values of this
     environment in one place (cookbooks and tools), loaded into the session
     with `. /u01/oracle/tools/set_script_env.sh`.

10. [Patch_Kochbuch_CSPU_Nov2026_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/Patch_Kochbuch_CSPU_Nov2026_de.txt) –
    bring an **existing** Reports environment to CSPU November 2026 – one
    run from any level (the list contains the October CPU patches, KA1182 is
    cumulative); on the October state only JDK, SPB, ADF / UMS / OPSS and
    OHS are new. When the starting level is unknown: complete patch
    set, a check with `opatch lspatches` before every patch, JDK change with
    carry-over of `java.security` / `cacerts`, OPatch, SPB via `napply`,
    eight infrastructure bundles, PERL, OHS / WebGate (binaries only – no
    OHS instance), Reports QPR (Forms QPR only optional for a scanner,
    appendix 12.F with the `libzrc` check), start and test, rollback.
    Download of all patches in one run:
    [patches_cspu_reports_14c_nov2026.csv](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/patches_cspu_reports_14c_nov2026.csv) with
    [tools/bash/mos_patch_download.sh](../tools/README.md#mos_patch_downloadsh)
    (`--all`). The October cookbook
    ([Patch_Kochbuch_CPU_Okt2026_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/Patch_Kochbuch_CPU_Okt2026_de.txt),
    [patches_cpu_reports_14c_oct2026.csv](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/patches_cpu_reports_14c_oct2026.csv))
    stays as the frozen record of that cycle.

11. [Reports_Absicherung_kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/Reports_Absicherung_kochbuch_de.txt) –
    after the patch: check an **existing**, only partly secured Reports
    environment and complete it – inventory with target values, password of
    `cn=Admin` of the WebLogic LDAP (then a full restart, otherwise error 49
    when the managed servers start), `monUser` / `RepRunner` with roles and
    permissions via WLST, credential store, `jps-config-jse.xml` to the
    LDAP, `<identifier>` and `securityId`, `cgicmd.dat`, JVM options, the OVD
    problem (EM finds no users) with workarounds, test matrix and password
    changes.
12. [Reports_Zeitplan_kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/Reports_Zeitplan_kochbuch_de.txt) –
    create reports automatically on a schedule as PDF: recommended cron +
    `rwclient.sh cmdfile=` (passwords in a file, PDF with date, exit code to
    the journal), as an appendix `SCHEDULE=` in the Reports server via POST
    with `showjobs` / `killjobid`. Important: PDF only into a `<write>`
    directory, no subdirectories (REP-56133). Background:
    [reports_job_handling.md](../../80-FMW-Architecture/reports_job_handling.md).

## Download checklist (preparation)

Download everything before the installation date and put it into the patch
directory (`/u01/oracle/patch_storage`, layout as in
[OS_Kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/OS_Kochbuch_de.txt) step 7: `wls/`, `fr/`,
`patches/<number>/`). State **CSPU November 2026** – check in MOS KA1182
before the download whether numbers have changed. Mind the platform of MOS
patches: **Generic** = one ZIP for all platforms, otherwise **Linux x86-64**
(getMOSPatch: platform `226P`). File names and sizes: download on the test
system on 2026-10-26 / 2026-11-18 (new November patches).

**a) Oracle Software Delivery Cloud** (edelivery.oracle.com)

- [ ] `V1045135-01.zip` – FMW Infrastructure 14.1.2.0.0 · 2.1 GB · to `wls/` · FMW step 1
- [ ] `V1045121-01.zip` – Forms and Reports 14.1.2.0.0 Linux x86-64 · 1.3 GB · to `fr/` · Reports step 1

Checksums (SHA-256, compare with `sha256sum` after the download):

```
V1045135-01.zip  1AAE35167BDED101E7194AA3D75C26B292010035A36C289A3F90B663D84E68BD
V1045121-01.zip  01D7A1042F0896FA5BDDD1EA268C1B60452476032819AAA307A789B15373175B
```

**b) My Oracle Support – Java**

- [ ] **35702194** `p35702194_2100_Linux-x86-64.zip` – Oracle JDK 21 · 539 MB · OS step 4
  (check in the ZIP: `jdk-21.0.13.1_linux-x64_bin.tar.gz` or newer)

**c) My Oracle Support – WebLogic / FMW Infrastructure** (all *Generic*)

- [ ] **40289362** `p40289362_141200_Generic.zip` – WLS Stack Patch Bundle 14.1.2.0.261112 · 2.8 GB · FMW step 3.2/3.3
  (contains OPatch 13.9.4.2.25 – no separate download of 28186730 needed)
- [ ] **40155248** `p40155248_141200_Generic.zip` – ADF bundle · 22 MB · FMW step 3.4
- [ ] **40035984** `p40035984_141200_Generic.zip` – WebCenter Core bundle · 80 MB · FMW step 3.4
- [ ] **40024749** `p40024749_141200_Generic.zip` – OWSM bundle · 5.4 MB · FMW step 3.4
- [ ] **39995927** `p39995927_141200_Generic.zip` – FMW Control (EM) bundle · 13 MB · FMW step 3.4
- [ ] **40057999** `p40057999_141200_Generic.zip` – OAMCLIENT bundle · 2.4 MB · FMW step 3.4
- [ ] **40145610** `p40145610_141200_Generic.zip` – UMS bundle · 4.5 MB · FMW step 3.4
- [ ] **40154045** `p40154045_141200_Generic.zip` – OPSS bundle · 1.5 MB · FMW step 3.4
- [ ] **39726399** `p39726399_141200_Generic.zip` – LibOVD bundle · 0.5 MB · FMW step 3.4

**d) My Oracle Support – Reports home** (platform *Linux x86-64*)

- [ ] **39600348** `p39600348_141200_Linux-x86-64.zip` – Reports QPR 14.1.2 · 0.5 MB · Reports step 2
- [ ] **39951765** `p39951765_141200_Linux-x86-64.zip` – PERL SPU (replaces 38590500) · 29 MB · Reports step 2
- [ ] **40181911** `p40181911_141200_Linux-x86-64.zip` – OHS bundle (binaries only) · 17 MB · Reports step 2
- [ ] **39100536** `p39100536_141200_Linux-x86-64.zip` – WebGate bundle (binaries only) · 21 MB · Reports step 2

Not needed: Forms QPR 39842516 (Reports-only installation, no Forms in use)
– in the patch cookbook (item 10) only as optional appendix 12.F, in case a
vulnerability scanner flags the Forms binaries in the home. Optional:
one-off 38936596 only for the Hebrew parenthesis display
(`REPORTS_BIDIPARENTHESIS=YES`).

**e) From the Oracle Linux repositories** (no download in advance, `dnf` on
the day): operating system packages, Nginx and `ca-certificates`
([OS_Kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/OS_Kochbuch_de.txt) steps 2–3 and 8).
Optional for the MOS download on the command line:
[getMOSPatch.jar](https://github.com/MarisElsins/getMOSPatch) (OS cookbook
step 7) – or all MOS patches in one run with
[tools/bash/mos_patch_download.sh](../tools/README.md#mos_patch_downloadsh) and
a CSV list (template:
[patches_cspu_reports_14c_nov2026.csv](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_linux_manual_install/patches_cspu_reports_14c_nov2026.csv) – complete set, with `--all`
also the optional rows: Forms QPR for appendix 12.F, JDK replacement 40239626).

**Total:** about 7 GB. If there are several variants for one patch number,
use only the one for 14.1.2 and Linux x86-64 or Generic. The same list for
the Windows Builder environment (other platform ZIPs):
[ReportBuilder_Windows_Kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/14-ReportsBuilder/ReportBuilder_Windows_Kochbuch_de.txt)
(English: [ReportBuilder_Windows_Kochbuch_en.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/14-ReportsBuilder/ReportBuilder_Windows_Kochbuch_en.txt)).

## Development environment (Reports Builder)

The Reports Builder for this server runs on its own Windows server
(developers via RDP) – analysis and cookbook:
[14-ReportsBuilder/](../../14-ReportsBuilder/README.md)
(a main folder of the library since 2026-11-13).

## Patch level

All cookbooks are at **CSPU November 2026** (JDK 21.0.13.1, SPB 40289362,
ADF / UMS / OPSS / OHS bundles of November), applied and tested on the test
system on 2026-11-18 (the October state on 2026-10-24); additions of
2026-10-26: Nginx removes WebLogic headers sent by the client,
`weblogic-plugin-enabled` also on the AdminServer, eMudhra incident
(`ca-certificates`, Java trust store). The current state and the history are
kept in
[09-Install/docs/00-patch-references.md](../../09-Install/docs/00-patch-references.md);
Oracle now ships monthly – check MOS KA1182 before every installation.

## Note

The external database is not created in any of these cookbooks – it does
not run on this machine and is operated by another team; only schemas are
registered in an existing database.
