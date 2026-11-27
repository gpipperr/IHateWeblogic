---
title: "IHateWeblogic Changelog – What Was Finished When"
description: "Changelog of the IHateWeblogic library for Oracle Forms & Reports 14c on WebLogic 14.1.2: what was finished when, newest first, with links to the documents."
---

# IHateWeblogic – Changelog

What was finished when, newest first. Moved out of the README on 2026-11-04;
details of every fix: `git log`. Open items: [TODO.md](https://github.com/gpipperr/IHateWeblogic/blob/main/TODO.md).

## 2026-11-27

- **Windows part of the customer tools reviewed and completed**
  ([tools/powershell/README.md](70-Customer-Projects/tools/powershell/README.md#tested--and-what-is-not)):
  - new `collect_ords_apex.ps1`, the Windows twin of the third collector: NSSM / WinSW /
    Procrun services, quoted Windows command lines, Windows Firewall rules; same files and
    lines as bash, so the ORDS analysis reads it unchanged;
  - `collect_fmw_env.ps1` shows the `ORDS / APEX` fact;
  - all eight scripts run with pwsh 7.7 on the test host against the bash results, plus a
    static PS 5.1 check with the PowerShell parser;
  - fixed: the home search without `ORACLE_HOME` (`Join-Path ""` threw), slow key derivation
    on .NET before 4.7.2 (now C# through `Add-Type`), `@REM` lines and junction targets in
    `java_check_fmw.ps1`, version of `fmw_patch_env.ps1` in the ZIP;
  - bash `collect_ords_apex.sh` 2026-11-27.1: only the JVM counts as an ORDS process, secret
    keys masked in `cfg;` lines, commented-out AJP connectors ignored and `secret=` masked;
  - German cookbook for the first Windows customer:
    [Start_beim_Kunden_Windows_Kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Start_beim_Kunden_Windows_Kochbuch_de.txt)
    (also in the Windows ZIP).

## 2026-11-26

- **ORDS / APEX cookbook CSPU Nov 2026**
  ([70-Customer-Projects/OrdsApex_Patch_cspu_202611/](70-Customer-Projects/OrdsApex_Patch_cspu_202611/README.md)):
  German, simple manual way for an existing standalone ORDS 26.x → 26.3.1
  plus the APEX 26.2 Patch Set Bundle 40040466 (→ 26.2.1), from the
  application server.
  - ORDS home, config, Java and unit are read from the running process.
  - The path is switched in the unit or in `/etc/ords.conf`.
  - `ords install --db-only` upgrades the schema with the existing pool.
  - For APEX: the images go over `/i/`, then `catpatch.sql` as SYS in the
    PDB.

- **Customer tools `java_check_fmw.sh` and `check_fix_libzrc_glibc.sh`:** which
  Java WebLogic / Reports / frmweb really use, a bent `oracle_common/jdk` and
  every missing or versioned JDK path after a JDK switch; check and repair of
  `libzrc.so.0` / the `libzrc.so` link (Forms relink after a Reports QPR on
  OL9, KB873815)
  ([tools/README.md](70-Customer-Projects/tools/README.md#java_check_fmwsh)).
  Windows version `java_check_fmw.ps1` (same sections, Node Manager service
  from the registry, junctions); the manual JDK switch cookbook runs the
  check before / after and names "Reports does not start after the switch".
- **ORDS / APEX: third collector + third analysis:** `collect_ords_apex.sh`
  (read-only) finds every ORDS installation (standalone / Tomcat / WebLogic,
  systemd, stopped copies, configuration before ORDS 22), reads version,
  Java, pools and features (`ords config list`, installer choice 1–5), the
  APEX version of the images directory (`/i/`), the web routes and the
  security points (listen address, SQL over HTTP, fixed Authorization
  headers, AJP, file-based users) and aggregates the logs of the last days;
  `collect_fmw_env.sh` points to it. New reference keys `APEX_VERSION_MIN`,
  `ORDS_JAVA_MIN`
  ([tools/README.md](70-Customer-Projects/tools/README.md#collect_ords_apexsh)).
- **Configuration export finds every client jar:** `export_forms_reports_conf`
  2026-11-26.1 (bash + PowerShell) reads all jar lists of `formsweb.cfg`
  (`cache_archive_ex`, own `*Archive` keys, `fsal_archive` resources, the
  `codebase` of the section), resolves URL paths like `/frmopt/x.jar` through
  the document roots / aliases of OHS, Apache and Nginx on the host, exports
  renamed `jacob_*.jar` and keeps equal names from two places; the Windows
  export no longer stops on a host without Reports server
  ([tools/README.md](70-Customer-Projects/tools/README.md#export_forms_reports_confsh)).

## 2026-11-24

- **Forms runtime crashes in the collector and the analysis:** `collect_fmw_env.sh`
  2026-11-24.1 writes `72_forms_crashes.txt` – library paths of the Forms env
  files (a `LD_PRELOAD` to the `libjsig.so` of a removed JDK breaks the
  signal chaining of the JVM in `frmweb`), crashes / preload errors per day and
  a summary of every `frmweb_dump_<pid>` (text stack trace, no gdb needed),
  newest 10 dumps in `dumps/`; `06-FormsDiag/forms_settings.sh` checks
  `LD_PRELOAD` / `LD_LIBRARY_PATH` and recent dumps
  ([06-FormsDiag/README.md](06-FormsDiag/README.md)); the Windows collector
  `collect_fmw_env.ps1` 2026-11-24.1 writes the same file (env `PATH` with
  the JDK for `jvm.dll` instead of `LD_PRELOAD`).
- **Applications directory outside the Oracle Home for new installs:** new key
  `APPLICATIONS_HOME` (default `$ORACLE_BASE/applications/<domain>`) in the
  interview, `setOption('AppDir')` in `08-oracle_setup_domain.sh` / domain
  template, directory in `03-`, removed by `99-`
  ([08-oracle_setup_domain.md](09-Install/docs/08-oracle_setup_domain.md)).
- **Architecture "the five homes":** Oracle Home, Domain Home and Applications
  Home with a drawing and a table of what a patch does in which home
  ([weblogic_middleware_architecture.md §1a](80-FMW-Architecture/weblogic_middleware_architecture.md#1a-oracle-home-domain-home-applications-home--who-holds-what)).
- **Smaller Forms client runtime:** `40-oracle_forms_client_bundle.sh` links
  only the `de,en` locales (`FORMS_CLIENT_JLINK_LOCALES`), keeps the modules
  uncompressed for the outer `zip -9` and drops `lib/*.lib` – download 28 MB
  instead of 45.6 MB; the ZIP is now named `formsWeb-jre-<ver>-win-x64.zip`
  ([java_jlink_forms_env.md §3.1](80-FMW-Architecture/java_jlink_forms_env.md#31-size-of-the-download--what-still-helps)).
- **Own client jars in the jlink runtime:** `40-` checks every `archive=` /
  `WebUtilArchive` jar of `formsweb.cfg` with `jdeps`, adds the modules they
  need and warns on JDK APIs removed since Java 9 (`sun.misc.BASE64*`);
  `java.sql` is now part of the default module list
  ([java_jlink_forms_env.md §3.2](80-FMW-Architecture/java_jlink_forms_env.md#32-own-jars-of-the-application-javabeans-pjcs)).
- **Finding: the domain's `em.ear` is never patched** – the `/em` cookie fix of
  the FMW Control BP of the CPU Oct 2026 is not active on the test host;
  check and refresh procedure open (TODO).

## 2026-11-23

- **Patch concept "patch once, transfer the FMW home":** patch master =
  application test, tar of the patched home to QA / PROD, clone family, the
  two inventories (central one not overwritten, only checked), Java through
  the link, short downtime with `mv` and way back
  ([forms_reports_patch_transfer_fmw_home.md](docs/forms_reports_patch_transfer_fmw_home.md)).
- **`backup_config.sh` category `wlsmon`:** `wlsmon.conf` and the local log
  rules of the runtime monitor (only the files directly in `etc/` – no
  secrets, no host-bound credentials)
  ([01-backup_restore.md](07-Maintenance/docs/01-backup_restore.md)).
- **11-wlsmon `--remove` and reinstall tested live:** `02 --remove` also
  deletes the `.bak_*` of its own units / nginx files; a new `wls_monitor`
  credential ends the 401 pause at once; operations page: order after a
  remove (00 → `01 --reset-monitor-password` → 02), backup and restore.
- **11-wlsmon nginx log errors:** the own anonymous probes from the loopback
  on `/console` / `/em` (access test of `02-`) are no longer counted.

## 2026-11-20

- **11-wlsmon tiles say what they measure:** the memory tile names the
  cause of WARN / CRIT (used % or swap); "Heap used" names the max heap and
  the JVM (without frmweb / engines); the JDBC tile counts RCU vs. own data
  sources. `03-set-thresholds.sh` shows the memory limit as free %, and
  `10,5` is refused with the hint `90,95`. Ops page: table "What the tiles
  refer to" ([04-wlsmon_operations.md](11-wlsmon/docs/04-wlsmon_operations.md)).
- **11-wlsmon nginx log errors:** a missing static file (`open() … No such
  file or directory`, e.g. the browser's `/favicon.ico`) is a 404, counted as
  4xx – no longer a log error that turns the host WARN.
- **11-wlsmon GUI libraries "moved: knockout":** false alarm (module path
  without `.js`) fixed; the daily facts now also refresh at the next run
  after a new `bin/wlsmon.py`, not after 24 h.
- **11-wlsmon at the first customer, `03-set-thresholds.sh`:** fix for a
  missing monitor user (01- now creates it); new operation script to show
  and change the WARN / CRIT limits next to the measured values of the last
  24 h (checked, backup, no restart); swap limit `WLSMON_SWAP_MB` instead of
  "any swap = WARN"; unreadable thresholds are reported; operations page
  §0 users, §1a update, §3a thresholds; favicon.
- **11-wlsmon docs completed:** new
  [operations page](11-wlsmon/docs/04-wlsmon_operations.md) (install / update /
  remove, status and logs, known faults: 403 after lost setgid, stale, false
  disk warning, tooltips, debugging without login); concept with the state
  of P1, all script options and `wlsmon.py` commands, a configuration
  reference of every `WLSMON_*` key, systemd credential blocks and core
  directory binding, Nginx log ACL, setgid trap; interface design with the
  tooltip behaviour; README with quick start; step states in the plan.
- **New concept [80-FMW-Architecture/fmw_load_test.md](80-FMW-Architecture/fmw_load_test.md):**
  load tests for Reports (paths, profiles, stop criteria, proposed curl-based
  generator, result → `maxEngine` / engine heap / sizing) and the options and
  limits for Forms. Nothing implemented yet.
- **11-wlsmon steps 9 + 10 live, step 11 written:** the interview and
  `01-install-wlsmon_fmw.sh --apply` ran on the test host (monitor user
  `wlsmon_monitor` created through REST, only in `Monitors`).
  `02-install-wlsmon_root.sh` (root): group `wlsmon` + setgid on the
  directories nginx reads, traverse ACLs only when needed, read ACL on the
  nginx logs (default ACL, survives logrotate), SELinux context when on,
  `etc/pending` → systemd credentials (clear text deleted), htpasswd in
  `/etc/nginx/wlsmon/`, nginx include with `nginx -t` + rollback, units +
  timers, first run, local access test; `--remove`. One credential block per
  secret in the unit (a missing `.cred` would stop the start).
- **11-wlsmon step 9 `00-setup-interview.sh`** (defaults from environment.conf
  and the host, secrets to `etc/pending/`, kept on re-runs) and **step 10
  prepared `01-install-wlsmon_fmw.sh`** (runtime below `WLSMON_BASE`,
  `ui.json`, monitor user through REST `createUser` – verified read-only,
  not run live yet). New `wlsmon.py defaults | detect | monitor-user`.
  Port check: fixed ports only, random listeners (Forms prestart `frmweb` on
  all interfaces) counted. 57 tests.
- **New page [80-FMW-Architecture/weblogic_rest_monitoring.md](80-FMW-Architecture/weblogic_rest_monitoring.md):**
  monitoring WebLogic 14.1.2 with the REST Management API – one search POST,
  field names verified on the test host (real answer as fixture), timing
  (first call 11 s, then 0.2 s), read-only monitor user, no lockout, fallback,
  `/management` only on localhost.
- **11-wlsmon collector live on the test host** (not installed): REST
  verified, `collect --secrets-stdin`, a round every 5 minutes into scratch.
  Security checks for the WebLogic administration rebuilt: `mgmt_rest_proxied`
  (Nginx configuration + probe with Host / SNI), `admin_locations` (`/console`,
  `/em` only with `deny all`), `admin_listen` (AdminServer on the loopback).

## 2026-11-19

- **11-wlsmon steps 0–8 implemented** (not installed yet) – progress log in
  the internal development plan (local, not in git since 2026-11-20).
  - `wlsmon.py` (python3 stdlib, 3.6): collector parts host, WebLogic REST
    (field names still to verify), Reports `getserverinfo`, Forms sessions,
    nginx, logs with `rules/wlsmon_rules.cfg`, core dumps, RCU (off), daily
    patch level from the inventory files, hourly security checks; levels,
    topology, rollups – the 7 JSON files of the contract.
  - GUI of the prototype v3 in `www/`, font-apex icons and Oracle JET charts
    from `/i/` with SVG fallback; test server `tools/devserver.py` with the
    production CSP.
  - Templates (wlsmon.conf, nginx include, systemd) with one renderer; tested
    with a throwaway nginx on the loopback.
  - `tools/ci_lint.sh`: Python 3.6 syntax + unittest (46 tests), ES5 syntax
    of the GUI via Nashorn.

- **11-wlsmon development plan** (internal, local only since 2026-11-20):
  - Ordered steps P1 0–13 and P2.1–P2.4, each with files, reuse from the repo
    and a done criterion.
  - Order: contract and GUI of the prototype v3 first, then the collector
    against the same contract (`check_contract.py`), installation last.
  - Decision: Oracle JET only for the charts (`oj-chart` from `/i/`,
    notag theme, no Knockout); everything else stays own HTML / CSS. A JET
    spike under the strict CSP is the gate.

- **New folder `11-wlsmon/` – concept of a lightweight runtime monitor:**
  [docs/01-wlsmon_concept.md](11-wlsmon/docs/01-wlsmon_concept.md) (master spec).
  - Static JSON per host (contract of the first plan / prototype).
  - Collector with one read-only WebLogic REST call per 5 min, no WLST, systemd
    limits; one python3 program (standard library only, 3.6-compatible); only
    `dnf` packages, no pip / PyPI / Galaxy.
  - Rules file `wlsmon_rules.cfg` (+ local file per host): `match` / `ignore`
    per log entry, counted per rule, so the WebLogic noise is filtered visibly.
  - Self-contained runtime below `$ORACLE_BASE/admin/wlsmon` (program, rules,
    `wlsmon.conf`, credentials – no library needed); Nginx reads only `www` /
    `api` / `hosts` via group `wlsmon`.
  - Secrets as encrypted systemd credentials; hand-over from the FMW owner to
    root like `boot.properties` (`etc/pending/` → `etc/creds/`).
  - Installation planned as `00-setup-interview.sh` (questions, defaults from
    `environment.conf`) → `01-install-wlsmon_fmw.sh` → `02-install-wlsmon_root.sh`
    (systemd, Nginx include from a template, timers).
- **11-wlsmon interface design:** [docs/02-wlsmon_interface_design.md](11-wlsmon/docs/02-wlsmon_interface_design.md) –
  colour concept from the colours of the project site: frame and data colours
  kept apart, reserved status colours (OK blue-green, WARN orange, CRIT red,
  STALE outline – always with icon + word), chart series, light / dark mode,
  CSS tokens; values checked for contrast and red-green colour blindness;
  colour swatches as small SVGs. From APEX `/i/` only font-apex and Oracle JET,
  no Universal Theme CSS – own look.
- **TODO:** library `.des3` secrets weaker than needed (key readable, process
  list, clear-text file, disk UUID order).
  - GUI as plain HTML5 with the APEX libraries from `/i/`.
  - Data and GUI separated: one GUI host pulls many data hosts – overview +
    drill-down.
  - One login for people, one shared pull user restricted to the GUI host's IP.
  - Concept only, no script yet; nav, README, TODO.

- **`ihw_tools_lib` 2026-11-19.2:** `ihwt_security` writes `config_audit;none` instead of an empty value and no
  longer prints an error when `jps-config.xml` is missing (found with the first real customer collection).

- **`update_tools_from_git.ps1`** (Windows twin of `update_tools_from_git.sh`, PowerShell 5.1 / 7): Windows tools ZIP
  with the certificate check off, `-Zip` offline, `-Proxy`, installed → repository per file, `-Apply` with backup,
  no downgrade, self-update; no `setdb` part. `make_customer_zip.sh` now also reads `$SCRIPT_VERSION = "…"`, so the
  Windows `VERSIONS.txt` carries the `.ps1` versions. Tested with pwsh on Linux.
  [powershell README](70-Customer-Projects/tools/powershell/README.md#update_tools_from_gitps1)

- **`update_tools_from_git.sh`** (new, customer tools `$ORACLE_BASE/tools`): downloads the Linux tools ZIP from the
  repository (wget `--no-check-certificate` because of TLS interception at customers, curl `-k` fallback, `--zip`
  offline), checks SHA-256 / `unzip -t`, shows per file installed → repository version; `--apply` replaces / unpacks
  with backup (`tools/backup/tools_<ts>`, newest 3), never downgrades a locally newer file, installs `setdb` as
  `~/.bashrc.d/ihw_env.sh` and removes the template `ihw_shell_env.sh` from the tools directory ("bitte neu
  anmelden"). Start road map step 2 uses it, new step 7 "Tools aktualisieren"; `ihw_shell_env.sh` 2026-11-19.1
  (help line). [tools README](70-Customer-Projects/tools/README.md#update_tools_from_gitsh)

- **Collector security facts (`46_security.txt`):** `collect_fmw_env.sh` / `.ps1` 2026-11-19.1, `ihw_tools_lib`
  2026-11-19.1 (`ihwt_security` / `ihwt-security`, identical lines bash / pwsh on the test host) – the checks of
  `02-Checks/domain_secret_check.sh` as facts: mode / owner / further group members of the domain key,
  `config.xml`, JDBC files and every `boot.properties`, clear-text `boot.properties`, lockout and password rule of
  the realm, configuration audit + auditor, OPSS `filterPreset`, applications on the AdminServer, groups of the
  domain owner, further copies of a domain key, `umask`, ORDS version of every `ords.war`; Windows: ACL readers
  (`acl` / `acl-world`). No values stored, no `sudo` call. New `ORDS_VERSION_MIN="26.3.1"` in
  `09-Install/oracle_software_version.conf` (set per cycle, [update_lib_to_act_cpu.md](docs/update_lib_to_act_cpu.md)
  area B). The customer analyses (private repo) rate the facts (status report section 11.1, patch analysis ORDS row).

- **CSPU November 2026 folder closed:** README state line (client bundle `40-` built 2026-11-18, rest → TODO),
  open point 2 (Forms session from a Windows PC OK), `update_plan.md` checklist ticked – only the AutoUpgrade
  question / first `09-db_patch_rcu.sh --mrp --apply` stays open.

## 2026-11-18 (after the release)

- **README final pass of the day:** "Ways in" with patching (`07-Maintenance/docs/02-patching.md`) and security
  (`security_overview.md`); APEX / ORDS status with the first real patch run 2026-11-18 (APEX 26.2.1, ORDS 26.3.1 –
  also in the directory table and TODO); 60-RCU row with the MRP in-place mode.

- **07-Maintenance split into topic documents:** the 740-line README is now an overview (topics, scripts, quick
  start); the content moved unchanged into [`07-Maintenance/docs/`](07-Maintenance/README.md#1-topics) –
  `01-backup_restore.md`, `02-patching.md` (incl. `rcu_repository_check.sh`), `03-security_hardening.md` (the three
  STIG scripts); right column in the Pages navigation; anchors and script header references repointed. Root
  `README.md` brought up to date (tree: `domain_secret_check.sh`, `wls_*` scripts, `07-Maintenance/docs/`, seven
  80-FMW pages; Script Directories; live-tested box with the November items; `docs/` line without the removed
  security pages).

- **Security entry page:** new [80-FMW-Architecture/security_overview.md](80-FMW-Architecture/security_overview.md)
  (`nav_title` "Security", also a key page in the Pages navigation): security model at a glance, current patch cycle
  (moved from `docs/forms_reports_security.md` unchanged), hardening by layer with fix + check scripts, passwords of the
  library (from `docs/general_security.md`), Reports invocation essentials (rules instead of dated findings), deliberate
  deviations / residual risks, checks to run. `docs/general_security.md` and `docs/forms_reports_security.md` removed
  (`redirect_from` on the new page), every link repointed (README, CONTRIBUTING, cycle procedure, patch-cycle skill,
  update plan, migration page). TODO: today's open security items in one block.

- **STIG change 3 – account lockout:** new [`07-Maintenance/wls_lockout_config.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/wls_lockout_config.sh)
  (settings, lockout runtime + locked users per server, `BEA-090078` events; `--apply` 3 / 30 / 15 – 30 instead of the
  STIG's 15 because WebLogic warns below 30 in production mode, `BEA-090978`; `--undo`; `--unlock USER`). Live: restart
  (non-dynamic), test user locked after 3 failures and released by `--unlock`; wrong `authid=RepRunner` via `rwservlet`
  gives `REP-50171` but **no lockout** (LDAP bind of the standalone Reports server,
  [reports_user_local_ldap.md §8](80-FMW-Architecture/reports_user_local_ldap.md#8-account-lockout-does-not-cover-authid-test-host-2026-11-18)).
  `domain_secret_check.sh` reads the realm elements with the `sec:` prefix (the lockout values were never found
  before) and rates 3 / 30 / 15 as OK. Smoke test 32 OK.

- **STIG change 2 – password rule of the realm:** new [`07-Maintenance/wls_password_rule.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/wls_password_rule.sh)
  (read-only: rule, realm users, stored passwords checked locally; `--apply` 12 characters / upper / lower / digit /
  special / no user name, `--undo`). New lib functions `wls_pwd_rule_spec`, `wls_pwd_rule_text`, `wls_pwd_rule_fail`,
  `wls_pwd_rule_prompt_ok`; the prompts of `01-setup-interview.sh`, `00-Setup/weblogic_sec.sh` (replaces the fixed 8/1
  check) and `12-oracle_reports_users.sh` check the active rule (failing password only after confirmation). Live: no
  restart, weak test password rejected (Security:099069/078/079), strong accepted, test user removed, smoke test 32 OK;
  the stored admin password does not meet the rule (keeps working).

- **STIG change 1 – audit trail:** new [`07-Maintenance/wls_audit_config.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/wls_audit_config.sh)
  (read-only by default, `--apply`, `--undo`): configuration audit `logaudit`, auditing provider `IHW_DefaultAuditor`
  (severity ERROR = ERROR + SUCCESS + FAILURE), OPSS `filterPreset` Low. Live on the test host: restart, every component
  up, failed login recorded with the user name in `DefaultAuditRecorder.log`, smoke test 32 OK; OPSS Low = management
  events only, loader into `DEV_IAU` open. `domain_secret_check.sh` §7 reads the OPSS value of the default
  `jpsContext` (`audit.db`).

- **DISA STIG for WebLogic read against Forms / Reports:**
  new [stig_weblogic_forms_reports.md](80-FMW-Architecture/stig_weblogic_forms_reports.md) (WebLogic 12c STIG V2R2,
  73 rules): transferable findings open on the test host (no configuration / OPSS audit, password rule 8/1, lockout
  values vs. service users, Nginx log as audit source, 12c = CAT I "unsupported", umask 0022), what the library meets
  (production mode, nothing on the AdminServer, loopback, UTC audit), the deliberate deviation "TLS at Nginx, WebLogic on
  loopback", what does not apply (FIPS, WLDF mail, sizing). `domain_secret_check.sh` section 7 checks the items
  read-only (test host: 3 WARN). Changes open, one by one (TODO).

- **Domain key / admin password – attack paths and check:**
  [fmw_pwd_handling.md](80-FMW-Architecture/fmw_pwd_handling.md) new §1a (two public cases: vulhub file read →
  key + `{AES}` → offline decryption → console → WAR; Medium case study WebLogic 12.2.1.4, reachable port 7001,
  CVE-2020-14882 → shell as `oracle` → several domains + backup copies → decrypted `boot.properties`; admin login =
  code execution; file-read paths of Forms / Reports; 14.1.2 without the classic console) and §1b (blast radius of the
  owner: other domains, `dba` with a local DB, sudo, password reuse, domain copies), §5 strong unique password / own
  admin name / lockout. New [`02-Checks/domain_secret_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/domain_secret_check.sh) (read-only;
  `--apply` = modes 600 for key + `boot.properties`, old modes saved). Test host: 3 WARN (lab account `oracle` in
  `wheel` with password-less sudo and in `dba`); negative and `--apply` tests in an isolated fake domain; live
  `--apply` (key + 2 NM-cache `boot.properties` → 600), `stop-all` / `start-all`: every component up, the NM keeps 600,
  smoke test 32 OK.

- **Windows collector Java4Shell facts** (`collect_fmw_env.ps1` / `ihw_tools_lib.ps1` 2026-11-18.1): `ihwt-java4shell`
  writes the same `java4shell;…` lines and summary fact as bash. CPU features from the bundled JVM (`-Xlog:os+cpu`,
  Java 11+), else .NET 8 intrinsics, else `IsProcessorFeaturePresent` (AVX-512 F only → `vulnerable=unknown`), column
  `source=`; `reports.bat` / machine variable `REPORTS_JVM_OPTIONS`; native `rwserver.exe` → `flag=unknown`. Tested
  with pwsh 7.7 on the test host (identical lines to bash, the private patch analysis reads them); first Windows run
  open. ([powershell/README.md](70-Customer-Projects/tools/powershell/README.md#collect_fmw_envps1))

- **Collector Java4Shell facts** (`collect_fmw_env.sh` / `ihw_tools_lib.sh` 2026-11-18.1): new `ihwt_java4shell` writes
  `java4shell;…` lines into `20_java.txt` – CPU AVX-512 VBMI flags, bundled JDK range, `-XX:-UseBASE64Intrinsics` in
  `reports.sh`, engine `jvmOptions` and every running process on the bundled JDK – plus the fact `Java4Shell
  CVE-2026-114938` in `00_summary.txt`. Tested on the test host (CPU no, 17.0.12 affected, flag 3/3); the private patch
  analysis rates a missing flag (WARN on AVX-512 VBMI CPUs, otherwise HINT). Windows collector open (TODO).
  ([tools README](70-Customer-Projects/tools/README.md#collect_fmw_envsh))

- **Java4Shell mitigation for the FMW-bundled JDK 17.0.12** (Reports server + engines, no FMW patch yet):
  `-XX:-UseBASE64Intrinsics` added by `09-Install/13-oracle_setup_reports.sh --apply` to `REPORTS_JVM_OPTIONS` in
  `reports.sh` (appended to the existing line) and to engine `jvmOptions`; `05-ReportsPerformance/engine_perf_settings.sh`
  keeps it (no drift). Set on every host whose bundled JDK is Java 11+ – **no CPU check** (no-op without AVX-512, a VM
  can move); never with Java 8 (`Unrecognized VM option` – checked with 8u513). New lib helpers `java_version`,
  `java_major`, `cpu_avx512_vbmi`, `java4shell_affected`, `reports_b64_opt`. `02-Checks/java_check.sh` section
  "Java4Shell": CPU flags, bundled JDK range, `reports.sh`, engine `jvmOptions`, every running process on the bundled JDK
  (WARN on AVX-512 VBMI CPUs, otherwise INFO). Live on the test host (no AVX-512): `13- --apply` → flag appended,
  repserver01 restarted, `java_check.sh` shows it active in rwserver + rwEng-0/1 (`jcmd VM.flags`), smoke test `15-
  --apply` 32 OK. Side effects documented
  ([13-reports-detail-settings.md](09-Install/docs/13-reports-detail-settings.md),
  [00-patch-references.md – Java4Shell](09-Install/docs/00-patch-references.md#java4shell--cve-2026-114938-state-2026-11-18)).

- **`60-RCU-DB-19c/09-db_patch_rcu.sh --mrp [--apply]`** – the monthly MRP + DB home JDK in-place into
  `DB_ORACLE_HOME`, as done by hand in the CSPU window
  ([09-db_patch_rcu.md](60-RCU-DB-19c/docs/09-db_patch_rcu.md#monthly-mrp-in-place-cspu-months----mrp), doc = spec):
  patches from `patches_db.csv` (roles `db_mrp` / `db_jdk` / `db_opatch`), sub-patches from the ZIP, "already
  applied" from `lspatches` (nothing to do, rc 0); base RU (`prereq_oneoffs`) and minimum OPatch read from the patch
  inventories (OPatch replaced from the `db_opatch` ZIP when too old); conflict check also in the dry-run (stage
  removed again); with `--apply` backup, stop, no process left in the home, snapshot pause, `napply` / `apply` with
  output evaluation, start + all PDBs open, `datapatch` (utlrp only when it applied SQL), invalid-object compare,
  domain start, `rcu_repository_check.sh`. Tested: live dry-run on the test host → "already applied" (rc 0);
  isolated copy with two sub-patches simulated missing → partial-state WARN, RU / OPatch / disk / seed checks,
  conflict check passed, plan. First `--apply` with the December MRP.

- **Script package from the CSPU live run:**
  - `10-Monitoring/cve_inventory.sh`: a configured patch that a newer installed one superseded (`opatch lsinventory
    -inactive`, read only when a patch is not in `lspatches`) is INFO "superseded" instead of FAIL "MISSING", plus
    the hint "home newer than the configured cycle – update the library". Tested with the October conf in an
    isolated copy: 5 FAIL → 5 INFO; a really missing patch stays FAIL (rc 2).
  - `09-Install/04-oracle_pre_download.sh`: the dry-run checks a stored ORDS ZIP (APEX only with a "latest" URL)
    against the remote `…-latest.zip` (HEAD, size) – WARN "NEWER release on OTN", note in `--offline-list`. Tested:
    26.3.1 stored → "= current OTN release"; only 26.3.0 stored → newer release detected.
  - `09-Install/15-deploy-test-report-forms_template.sh`: `REP-50001` (Reports server initializing) → retry every
    10 s, up to `REPORTS_INIT_RETRIES` (6). Live: `repserver01` restarted, smoke test right away → one retry, 32 OK.
  - TODO: the three items and the done client-bundle entry removed.

- **Architecture base map §3.7 "Infrastructure components in every home – installed, deployed, reachable?"**
  ([weblogic_middleware_architecture.md](80-FMW-Architecture/weblogic_middleware_architecture.md#37-infrastructure-components-in-every-home--installed-deployed-reachable)):
  OPSS, ADF, EM, OWSM, UMS ("Service Delivery Platform"), WebCenter Core, OAMCLIENT, LibOVD, Coherence, OHS /
  WebGate / Perl / DBCLIENT with what they are, their state in the test domain (checked live: UMS / OWSM /
  WebCenter only libraries, endpoints 404) and the KA1182 bundle; rule "patch scope = installed, risk = reachable",
  check commands for a customer domain. UMS check recorded in the CSPU Nov 2026 folder (open point 3) and the CVE
  table. 12c October cookbook: eMudhra check `blocked.certs` → `blacklisted.certs` (Java 8), noted in the frozen
  header.

- **`mos_patch_download.ps1` 2026-11-18.1 – Java < 11 fixed:** without the password runner getMOSPatch was
  started with `| Out-Host`; the pipe left `System.console()` `null` → `NullPointerException` in
  `getMOSPatch.setAuthentication`, no user / password prompt (first customer run of the offline list with Java
  8). Now `Start-Process -NoNewWindow -Wait` – getMOSPatch inherits the console and asks itself; proven with a
  pseudo terminal and Java 8 (old: console `null`, new: present). Recommended remains `-Java <JDK 11+>`
  (password once, through the runner). The bash tool was not affected (pseudo terminal via Python).

- **Offline patch download for a host without MOS access** – `09-Install/04-oracle_pre_download.sh
  --offline-list[=FILE]` / `--offline-list-all` (read-only): writes the MOS rows this host needs and misses
  (roles of `environment.conf`; `patches_db.csv` with `LOCAL_REP_DB=true`, a row in the AutoUpgrade patchdir
  counts as present) as a normal patch list with a command header; the standalone
  `mos_patch_download.ps1` on a Windows PC downloads it into the `PATCH_STORAGE` layout, the tree goes back by
  `scp`; non-MOS items (APEX / ORDS, JACOB, icon URL) as URL + target comments. No change to the
  downloaders. Tested in an isolated copy (4 rows + ORDS note, plan runs of `.sh` and `.ps1`, round trip →
  all present). Docs: [04-oracle_pre_download.md](09-Install/docs/04-oracle_pre_download.md#no-mos-access-on-the-host--offline-list--windows-download),
  download README, tools README, 07-Maintenance README.

- **Pre-commit hook 2026-11-18.1 – customer ZIPs:** the stale-ZIP check now triggers on every file
  `make_customer_zip.sh` packs (new option `--sources`: scripts, `tools/README.md`, start cookbook,
  `patch_install.ini` template), not only on `tools/bash|powershell` – the switch commit of `v1.0.202611`
  had left the Linux ZIP stale after a `tools/README.md` change (fixed by 7ca50c2 before the tag). Tested in a
  scratch clone: README / start cookbook changed without ZIP → blocked, with rebuilt ZIP → passes, unrelated
  file → passes.

## v1.0.202611 – CSPU November 2026 (2026-11-18)

First release after `v1.0.0`: the library is switched to the **CSPU November 2026** in one commit
(release tag scheme `v1.0.<yyyymm>`). Procedure: new fixed step list
[docs/update_lib_to_act_cpu.md](docs/update_lib_to_act_cpu.md); facts of this cycle:
[update_plan.md](70-Customer-Projects/FormsReports14_patch_cspu_2026-11/update_plan.md).

- **Analysis** (`patch_cycle_analysis.sh prepare` / `analyse --mode maintainer`, first real run): final advisory
  (differs from the pre-release: ORDS 26.3.0 affected), KA1182 of 2026-11-17, CPU450 / CPU435 / CPU431, every
  README read from the ZIP (download to a staging area, ARU of every ZIP). New cycle folder
  [FormsReports14_patch_cspu_2026-11](70-Customer-Projects/FormsReports14_patch_cspu_2026-11/README.md) with
  **two** guides (full / cumulative from CPU Oct 2026); October folder frozen;
  `00-patch-references.md` archived as `_october_2026.md` and rewritten (new sections "What a home needs – CPU
  vs. CSPU", "Java4Shell" CVE-2026-114938, MRP / OpenSSL assessment of the repository DB).
- **Live run on the test host 2026-11-18** (by hand, cumulative guide): JDK 21.0.13.1, SPB 40289362 (PSU
  40205408, TPP 40288205, marker 40289390), ADF 40155248, OPSS 40154045, UMS 40145610, OHS 40181911 – OPatch sets
  the October bundles "inactive" itself; validate 0 FAIL after the SecureRandom fix (missing after a manual JDK
  unpack – added to both guides); smoke test, Forms session OK. DB window: MRP 40196156 in-place + DB home JDK
  40245331 (`datapatch` without work – binary-only one-offs). APEX 26.2.1 (patch set bundle 40040466) and
  ORDS 26.3.1.
- **A patch lists:** `patches_fmw.csv` (complete November set, release month per row, `apex` row 40040466),
  `patches_db.csv` (new role `db_mrp`, MRP in `database/mrp/<nr>/`, DB JDK 40245331); customer list
  `patches_cspu_reports_14c_nov2026.csv` + `Patch_Kochbuch_CSPU_Nov2026_de.txt` (Reports14).
- **B conf:** `PATCH_CYCLE` CSPU Nov 2026, `WLS_SPB_VERSION` / `_MARKER_PATCH`, `WLS_SPB_CHECK_BUGS="39924025
  40073770"` (JAX-WS gate of the Nov PSU), `JDK_VERSION_MIN=21.0.13.1`, superseded list.
- **C scripts:** lib `otn_newest_zip` ignores non-version directories (`apex/patch/<nr>/` hid `apex/26.2` – found
  by the switch check); comments only otherwise (no `SUPERSEDES` change needed).
- **D install docs:** 04 / 05 (new section "November 2026 PSU: JAX-WS gate ON by default") / 06 / 40, download
  README, 60-RCU docs 01 / 09 ("Monthly MRP in-place"), 12-APEX-Ords README.
- **F customer cookbooks:** Reports14 FMW / Reports / OS / security cookbooks and README, Java change cookbook,
  14-ReportsBuilder (de / en / install page – Windows ZIP of OHS 40181911).
- **G / H / J:** ORDS and certificate pages (current state), security & patch status page, root README, project
  status, 70-Customer-Projects index, 10-Monitoring README, TODO, skill doc (rules learned: KA1182 cumulative,
  "Service Delivery Platform" = UMS, pre-release vs. final, PAD vs. matrix, README template errors, manual JDK
  switch + SecureRandom, news CVEs).
- **K storage (test host, not in Git):** October ZIPs archived, November ZIPs in place; `04-` reports every row
  present, `81-` / `82-` `--check-only` "already installed", `cve_inventory.sh` 0 FAIL.

## 2026-11-17

- **Open points of the doc pages reviewed:** stale entries cleaned (getserverinfo §8 GET examples + `maxQueueSize`,
  ords_architecture §11 backup, java_jlink §8 Windows client, 10-Monitoring `cve_watch.sh` / CSPU state,
  09-Install file tree `install_lib.sh`, doc 40 §12 client JDK); TODO.md: full HTML parameter form test plan,
  Reports font open points, PRTG sensor live test.
- **Patch lists with the Unique Patch ID (ARU)** – new column `aru` in `09-Install/download/patches_fmw.csv` /
  `patches_db.csv` (CPU October 2026 values from the `inventory.xml` of the ZIPs, all identical with
  `opatch lsinventory` on the test host). `mos_patch_download.sh` / `.ps1` 2026-11-17.1 read the ARU of every
  ZIP, show it, write it to `patches_sha256.csv` and WARN on a new build; lib `patch_zip_sha_check` (05- / 06- /
  40-) checks it before the apply. Empty for SPB, OPatch, JDK, CVU (no OPatch inventory). Old 6- / 8-column
  lists keep working ([download/README.md](09-Install/download/README.md#aru-unique-patch-id--soft-check)).
- **TODO.md:** open script side of the Reports job queue page (13- template, collector / analysis detection)
  and the ORDS follow-ups (Nginx rate limit, `ords pool --pid … list`, pool destroy test).
  12-APEX-Ords README §4: ORDS requirement corrected to 26.3+ for APEX 26.2 (was "documented for APEX 26.1").
- **ORDS architecture page compared with Oracle Skills `db/ords`** ([ords_architecture.md](80-FMW-Architecture/ords_architecture.md)):
  new §3.1 export API `ORDS_EXPORT` / `ORDS_EXPORT_ADMIN` (signatures from `dba_arguments`, typo
  `p_include_privleges`, `select … FALSE from dual` → `ORA-00904` on 19c, PL/SQL block instead); §4 config keys
  of general guides unknown to ORDS 26.3 (`feature.db-api`, `log.folder`, `java.opts`, …), `ords validate`
  gone, `jdbc.statementTimeout` is no query timeout; §6 CORS meaning of `externalSessionTrustedOrigins`;
  §8 `ords pool --pid … list`, health check `/ords/` = 302, Nginx rate limit (not in the template yet).
  All checked live on the test host.
- **Reports14_linux_manual_install README in English** ([README](70-Customer-Projects/Reports14_linux_manual_install/README.md)), the cookbooks stay German; known problem `<server>.lok` added to item 6, patch-references path as link.
- **New architecture page: Reports error analysis and trace levels** ([reports_error_trace.md](80-FMW-Architecture/reports_error_trace.md)):
  which log holds the cause, ODL levels vs the old `TRACE_*` options (Oracle Table 24-3), where the level is
  set per component, `TRACE:32` step by step with measured volume. Live 2026-11-17: `<trace>` in
  `rwserver.conf` commented out in the 14.1.2 xsd, `traceopts=` in the rwservlet URL → `REP-50125` for every
  value, a missing report file reports `REP-56132`, `retry="3"` = four error blocks per job, `userid` in the
  trace without password. Linked from the 80- README, 03-Logs §5, 01-Run §5.
- **FormsReports_change_java README in English** ([README](70-Customer-Projects/FormsReports_change_java/README.md)), the cookbook stays German; linked from 07-Maintenance/README.md, 01-root_setup_java.md, 08-oracle_setup_domain.md §3b, weblogic_middleware_architecture.md and as arrow link below weblogic_middleware_architecture in the right column of 80-FMW-Architecture.
- **Server lock `servers/<name>/tmp/<name>.lok` before every start** ([01-Run/README.md](01-Run/README.md),
  [30-configure_autostart.md](09-Install/docs/30-configure_autostart.md)): a running server holds its `.lok`
  open (`fuser` shows the JVM). `startStop.sh` aborts the start with the PID when an old JVM still holds it
  (new start would wait, `BEA-141281`) and moves a lock no process holds to `.lok.stale`; `fmw_ctl.sh` does
  the same and only logs a WARNING. Never delete a held `.lok`. Troubleshooting row in
  [12-weblogic-report-monitoring_user.md](09-Install/docs/12-weblogic-report-monitoring_user.md), known
  problem in `WLS_Report_start_stop_kochbuch.txt`, monitoring checks for `ovd.lok` (older than the
  AdminServer start) and held server locks in
  [reports_monitoring_getserverinfo.md §6](80-FMW-Architecture/reports_monitoring_getserverinfo.md).
- **Clones: rescue image of the old machine-id out of `/boot`** ([FormsReports14_linux_clone](70-Customer-Projects/FormsReports14_linux_clone/README.md),
  [forms_reports_sizing.md](docs/forms_reports_sizing.md#os-disk-layout--boot-3-gb-not-the-installer-default)): a VM clone carries the
  template's rescue image (~90 MB); after the new machine-id the next kernel update builds a second one and
  the old one stays – clone cookbook step 4.5 remembers the old id and removes it, or `dracut_rescue_image="no"`
  in the template.
- **Disk sizing: OS layout with `/boot` 3 GB** ([forms_reports_sizing.md](docs/forms_reports_sizing.md#os-disk-layout--boot-3-gb-not-the-installer-default)):
  the installer default 1 GiB (960 MB usable) holds about three kernels; measured per kernel (UEK ≈ 100 MB
  with kdump, RHCK ≈ 60 MB), `installonly_limit` counts UEK and RHCK separately, update peak; recommended
  layout, and how to make room on an existing host (`dnf remove --oldinstallonly`). A customer `dnf update`
  stopped on a full `/boot`. `02-Checks/os_check.sh` now checks `/boot`: free space against the next kernel
  update, installed UEK / RHCK kernels, `installonly_limit`, hint when `/boot` is the installer default.
- **Reports job queue in the database** ([reports_job_queue_monitoring.md](80-FMW-Architecture/reports_job_queue_monitoring.md)):
  `jobStatusRepository` / `RW_SERVER_JOB_QUEUE` on 14.1.2 – setup with minimal rights, csf key, xsd order,
  `dbconn` for a PDB, status codes and queries; live test: the table mirrors the past queue, orphan rows after
  restarts, a repository outage kills the Reports server (Node Manager restart loop, jobs lost), silent
  package errors, `COMMAND_LINE` may contain passwords; old sources (snapdba 2016, Oracle 11g / 12.2.1.x)
  assessed. Thanks to Jürgen for the setup notes.
- **New JDK by hand** ([70-Customer-Projects/FormsReports_change_java/](70-Customer-Projects/FormsReports_change_java/README.md)):
  German cookbook – unpack the new Oracle JDK, carry over SecureRandom and own CAs, create / switch the
  version-neutral link, switch domain and Oracle home (23 files on the test host) with vi, check, way back;
  tested in an isolated copy with the files of the 2026-10-15 switch.
- **domain_jdk_path.sh** also scans the text scripts directly in `$ORACLE_HOME/bin`: the installer pins
  `JAVA_HOME` to the versioned JDK there too (`aqxmlctl`, found on the test host – no Forms / Reports start
  path, the domain and `oui/` were already on the link).

## 2026-11-16

- **Architecture data in the collector** (`collect_fmw_env.sh` 2026-11-16.7, `.ps1` 2026-11-16.8, `ihw_tools_lib`
  2026-11-16.7, export 2026-11-16.2): normalised listening ports (loopback / one address / all interfaces),
  `Domain summary (top level)` with the WebLogic plug-in flag, certificate columns SAN / key / signature /
  chain, `WLProxySSL` in the rated directives; **fix**: Apache / OHS global `<Location>` routes are inherited
  by every VirtualHost without own routes – a TLS VirtualHost no longer looks as if `/forms` ran over plain
  HTTP only. bash and PowerShell give the same lines.
- **Collector: other WebLogic domains and WebGate** (`collect_fmw_env.sh` 2026-11-16.6, `.ps1` 2026-11-16.7,
  `ihw_tools_lib` 2026-11-16.6 / `.ps1` 2026-11-16.6): `41_other_domains.txt` with the top level of every
  other domain of the host (BI Publisher, OAM … next to the Forms domain: version, home, servers, deployments,
  products) and whether WebGate (OAM agent) is configured in an OHS instance (`43_ohs.txt`: security mode,
  OAM server, agent certificate expiry) – so the WebGate bundle patch of the single sign-on client side is
  recommended as "active"; bash and PowerShell give the same lines
  ([tools/README.md](70-Customer-Projects/tools/README.md#collect_fmw_envsh)).
- **Licence in the public cloud** ([fmw_forms_reports_licence.md](80-FMW-Architecture/fmw_forms_reports_licence.md#4-metric-and-prices)):
  OCI counted per OCPU (Core Factor Table, x86 2 / Ampere 4 OCPUs per processor licence), AWS / Azure /
  Google Cloud per vCPU (cloud licensing policy, as of 2026-09-04), core factor not applicable; glossary
  OCI / OCPU / vCPU / BYOL. Collector (`collect_fmw_env.sh` 2026-11-16.5, `.ps1` 2026-11-16.6,
  `ihw_tools_lib` 2026-11-16.5 / `.ps1` 2026-11-16.5): `host;cloud` (DMI as cloud-init reads it) and
  `host;cpu_arch` in `45_licence.txt`, fact `Public cloud / CPU arch`.
- **sar memory history fixed** (`ihw_tools_lib.sh`): "memory used" now = 100 − available / total (like
  `free`); with sysstat < 12 (OL7 / OL8) `%memused` counted the page cache and showed 98 % on a host with
  two thirds of the memory available.
- **08-SSL terms** ([08-SSL/README.md](08-SSL/README.md#terms--what-is-meant)): short list of the standard terms
  (X.509 certificate, private key, chain, root, PEM, DER, PKCS#12 = `.pfx` / `.p12`, PKCS#7, CSR, JKS) with
  the usual extensions and how to recognise a file – the extension says little about the content.
- **create_server_cert_from_pfx.sh** (customer tools): PFX / PKCS#12 → `server.key` / `server.cert` /
  `ca_chain.cert`; without `--apply` it lists the container (password, format, names, validity, key ↔
  certificate, chain); OpenSSL 1.1.1 and 3 ([tools/README.md](70-Customer-Projects/tools/README.md#create_server_cert_from_pfxsh)).
- **Manual PFX split** ([08-SSL/README.md](08-SSL/README.md#manual-split-a-pfx--pkcs12-also-wildcard-certificates)):
  key / certificate / chain from a PFX with OpenSSL 1.1.1 (`-nodes`) and 3.x (`-noenc`, `-legacy` for old
  RC2 PFX), checks (SAN, key ↔ certificate, chain with / without the root in the OS trust store),
  wildcard notes – tested with a test PKI.
- **Forms & Reports licensing:** [fmw_forms_reports_licence.md](80-FMW-Architecture/fmw_forms_reports_licence.md) –
  technical classification with disclaimer (EN / DE), glossary of the abbreviations, what the licence
  covers, Builder not covered, NUP vs. processor with core factor and Oracle Store / price list
  prices, virtualization, RCU database, WebLogic Server Basic restrictions, MOS note 885587.1 assessed,
  Reports deprecated / Reports-only with the Lifetime Support dates, old contracts, checklist – every
  statement with its source; socket metric and chiplets (only "Standard Edition" products count dies as
  sockets – OFR per core, but SE2 for the RCU database / WebLogic SE) with a 2 × AMD EPYC 9654 example
  (96 processor licences vs. 960 NUP minimum, VMware vs. KVM hard partitioning). Collector licence indicators (`collect_fmw_env.sh` 2026-11-16.4,
  `.ps1` 2026-11-16.5, `45_licence.txt`, `ihwt_wls_basic` / `ihwt_licence_host`): the WebLogic Server
  Basic restrictions visible offline in the domain configuration, every application / library with
  "source in ORACLE_HOME", CPU / virtualization, database (edition chosen at installation from
  `oracle_install_db_InstallEdition`, instance → home without a login) and ORDS on the host – bash and
  PowerShell give the same lines; the analysis warns (HINT) for a Standard Edition database on a host
  with more than 2 sockets / a multi-die CPU.
- **Forms FADS:** [forms_fads_app_dep_service.md](80-FMW-Architecture/forms_fads_app_dep_service.md),
  collector facts "FADS in the domain" / "FADS software in home".
- **Patch basics:** [oracle_patch_basics.md](80-FMW-Architecture/oracle_patch_basics.md) – patch
  vehicles FMW / DB, platforms, patch number → ARU / UPI, lsinventory, superset, Windows lag.
- **Collector and export split (collector 2026-11-16.3, export 2026-11-16.1):** `collect_fmw_env.sh`
  = the state (installed, patch level, Java, OS security advisories from the dnf cache, Nginx patch
  facts in detail, memory, load profile, HTTPS certificates, Derby, FADS) without configuration files;
  `export_forms_reports_conf.sh` = the configuration for the rebuild (load profile and listener
  certificates moved to the collector). Shared blocks in `ihw_tools_lib.sh` (`ihwt_identity`,
  `ihwt_rs_list`, `ihwt_load_profile`, `ihwt_certificates`, `ihwt_os_advisories`, `ihwt_nginx_patch`).
  Every analysis needs both runs: patch analysis = collection, environment analysis = export +
  collection ([tools/README.md](70-Customer-Projects/tools/README.md)).
- **Windows collector (collect_fmw_env.ps1 2026-11-16.3 + new `ihw_tools_lib.ps1`):** the same split
  as bash - state only, encrypted `.zip.enc` (.NET AES compatible with the openssl command of the bash
  tools), UTF-8 without BOM / LF / `/` in the ZIP; web tier routing identical to bash; Nginx installed
  by hand found through process, NSSM / WinSW / srvany service, task or directory, with version,
  static OpenSSL, stable / mainline, build date, restart pending and write rights; pending Windows
  updates from the Windows Update cache; load profile; patch facts (products, components, other
  homes, OPatch prerequisites) so the patch analysis reads Windows collections
  ([powershell/README.md](70-Customer-Projects/tools/powershell/README.md)).
- **Windows export (export_forms_reports_conf.ps1 2026-11-16.1, ihw_tools_lib.ps1 2026-11-16.2):** the
  configuration of a Windows host with the same archive layout as bash (paths with `/` in the derived
  files, `raw/other/<drive>/`), plus `ihw_import/registry_env.txt` (Oracle `KEY_*` + machine
  environment) and `ihw_import/path_map.txt` (Windows path → Linux proposal); IIS + `iisproxy.ini`,
  `C:\Windows\Fonts` (customer fonts by owner, Microsoft fonts listed only), UNC sources with a
  timeout. On the test host equal to the bash export of the same domain. The environment analysis
  reads Windows exports (CRLF, drive paths, section 13.4, Windows findings: registry-only variables,
  UNC shares, blanks, upper / lower case). PowerShell masking now line by line like `sed`;
  `ihwt-find-homes` shared by collector (2026-11-16.4) and export.
- **Collector memory (2026-11-16.2):** `collect_fmw_env.sh` / `.ps1` write `51_forms_memory.txt`
  (every frmweb with RSS, private, PSS, session / pool; heap / GC arguments and RSS of every WLS
  server; prestart keys of formsweb.cfg) and the facts "Forms frmweb memory", "WLS heap (Xms/Xmx,
  RSS)", "Forms prestart sections" – for comparing the memory of Forms 12c and 14c hosts.

## 2026-11-13

- **SEO:** front matter `title` (≤ 60 characters) and `description` (140–160) for the 52 pages that
  still had the general site description (80-FMW-Architecture, 60-RCU-DB-19c/docs, docs/, root pages,
  set_environment, HTML_ParameterForm_Fonts, setup_claude, XML syntax reference, sub-folder READMEs
  with permalink) – also used as og:description when a page is shared. Layout: own `<title>`,
  " | IHateWeblogic" only when the whole title stays ≤ 60 characters (`{% seo title=false %}`).
- **New main folder `14-ReportsBuilder/`** (moved from `70-Customer-Projects/Reports14_builder_windows`,
  history kept with `git mv`): new overview `README.md` – the idea (builder-only Windows server) and
  the core question how to distribute and manage reports with GitLab, with the diagram
  `builder-gitlab-flow`; the former README is now `ReportsBuilder_install_windows.md`. English
  developer workflow `scripts/README.md` next to `README_DE.md`. All paths updated (docs, script
  header comments, cookbook `$QUELLE`); old Pages URLs redirect (`jekyll-redirect-from`). Pages: left
  menu entry 14-ReportsBuilder, right column (all pages of the folder, new mode `dir/**`), links
  from `80-FMW-Architecture/reports_rwbuilder.md` and `clone_golden_image.md` to the practice;
  key pages "The idea" / "Current patches" below Start; right column for 00, 04, 09, 10, 60, 70
  (tree with `nav_title`), 80.
- `Reports14_builder_windows`: **Reports deployment live at the customer** – own GitLab project
  runner, push -> DEV and `prod-*` tag -> PROD (files arrive correctly), mail after the PROD deploy,
  protected tags, variables per environment. New: `deploy/ci_deploy_debug.sh` (no-logic test of the
  pipeline mechanism, cookbook step 4b), `deploy/ci_notify_mail.sh` + stage `notify` (mail only for
  PROD, Postfix relay over TLS, cookbook step 9; demo relay `mxmail01.pipperr.local:587` in the
  README demo data); cookbook step 4 rewritten for the project runner (stale entries / `verify
  --delete`, no restart after `register`, runner too old -> upgrade + new registration with a new
  name); `checkin.ps1` puts the report name into every comment; `status_detail.ps1` explains `offen`,
  legend, `$ReleaseSkript`, umlauts via character codes; `Git_deploy.md` / `Git_checkin.md` link the
  original documentation (GitLab, OpenSSH, Git, Oracle Reports 12.2.1.3, PowerShell) and list where
  each value is set and used.

## 2026-11-12

- **GitHub Pages – docs as a linked website, finished** (steps 4–7 of
  `prompt_ihw_pages_verlinkung.md`): 1,395 code mentions in 108 files linked, one commit per
  folder (only link brackets added, all targets checked); own `_layouts/default.html` +
  `assets/css/ihw.css` in the style of www.pipperr.de (header with logo and section,
  breadcrumb, menu column, "This page on GitHub", footer "Made by"); kramdown fixes found by the
  live check: ASCII `<details>` blocks swallowed the rest of 12 pages -> `<details
  markdown="block">` + fence ```` ```ascii?name=<n> ```` (render_ascii writes this form), 240
  bare URLs in 40 files were plain text on Pages -> `<https://…>`; front matter (title /
  description, READMEs + permalink) for 12 module READMEs and 35 `09-Install/docs`. Live check
  0 findings (2,344 links, 119 pages), all folder addresses HTTP 200.
- `Reports14_builder_windows`: new cookbook `git_pipeline_kochbuch_de.txt` (German) - set-up of
  `deploy_dev` / `deploy_prod` step by step: `rwdeploy.sh` on DEV and PROD, deploy keys with
  `command=` / `restrict` / `from=`, host key for `DEPLOY_KNOWN_HOSTS`, runner tag, GitLab protected
  branch / tags, scoped variables, `.gitlab-ci.yml` as the last step, tests DEV + PROD, rollback,
  known problems. `rwdeploy.conf.template` targets `/u01/reports/source` / `images`; `rwdeploy.sh`
  `die` no longer prints the exit code in the message.
- `Reports14_builder_windows`: **repository layout of the customer adopted** – top folder
  `menu.cmd` / `menu.ps1` / `menu.ini`, folders `deploy/` (scripts), `source/`, `xml/`, `images/`
  (before: everything under `Reports/`). `checkin.ps1` / `convert_rdf.ps1` folders, `status_detail.ps1`
  Prod column (showed `-` everywhere at the customer), `ci_deploy.sh` file list, `rwdeploy.sh` allowed
  tar members (`source/<name>.rdf`, `images/<name>`), `.gitlab-ci.yml` (`bash deploy/ci_deploy.sh`),
  `menu.ini` `SkriptPfad = deploy`, all docs and usage lines (`.\deploy\...`). `rwdeploy.sh` must be
  installed again on DEV / PROD.
- `Reports14_builder_windows/scripts`: new start menu for a double click - `menu.cmd` (desktop icon,
  `-NoExit` keeps the window open with the result) starts `menu.ps1`, which lists the scripts from
  `menu.ini` (sorting, short + long text, parameters, admin flag) and runs the chosen one in the
  same window; `x` closes it. `SkriptPfad` in `menu.ini` (global or per entry, relative,
  absolute, `%VARIABLE%`) when the scripts are in another folder.
- `Reports14_builder_windows/scripts`: `status_detail.ps1` gets the column **Prod** (`PROD` / `offen` /
  `alt` / `-`, same production logic as `release_tag.ps1`), `NO_TAG` and the tag message in the row
  below the tag name (narrow table), plus a line with the open files of the list;
  `release_tag.ps1 -List` = only show, no question, no tag.
- `Reports14_builder_windows`: **deployment switched to the customer's tag concept** – only the
  branch `main`, one report per check-in (`checkin.ps1` / `checkin_only.ps1` commit every selected
  file on its own, a report with its `.xml`); push to `main` -> `deploy_dev` sends the files changed
  since the last DEV deploy; a `prod-*` tag (`release_tag.ps1`) -> `deploy_prod` sends exactly the
  files of the tagged commit. No `development` branch, no merge requests: `promote.ps1` removed.
  `release_tag.ps1`: open = no own tag and no newer tagged check-in of the same file, warning for an
  older version, releases list the files of their commit. `rwdeploy.sh` kinds `delta` / `tag`
  (`snapshot` still accepted). `Git_deploy.md` rewritten; README_DE, Git_checkin.md updated.
- `Reports14_builder_windows/scripts`: customer script for release tags rebuilt as `release_tag.ps1` in
  our style (repo-root logic, Exit-Script, commented git calls, ASCII): open check-ins on
  `origin/development` without a `prod-*` tag, the last 20 releases, set + push an annotated tag;
  new default filter `*.rdf` (`-Filter` overrides, `''` = all), `-File` = part of the file name.
- `Reports14_builder_windows/scripts`: new `status_detail.ps1` (read only) - the last 20 check-ins
  (parameter = other count) as a Markdown table `|Datum|Commit ID|Datei|Tag|`, one row per file.
- `Reports14_builder_windows`: **deployment** with a self-hosted GitLab (`Git_deploy.md`, folder
  `deploy/`). Push to `development` -> job `deploy_dev` sends all reports + images as a snapshot;
  new `scripts/promote.ps1 <report>` releases ONE report (.rdf + .xml, images on request) from
  `origin/development` into a `release/...` branch built in a temporary `git worktree` (working copy
  untouched) and opens the merge request to `main` with push options (no API token); after the
  merge `deploy_prod` (manual "Play") sends only the files changed since the last PROD deploy.
  Server side `rwdeploy.sh`: SSH forced command (`restrict`, `from=`), spool queue with `flock`,
  tar members checked before extracting, copy only changed files with backup, never delete,
  `status --wait` so the pipeline shows the deploy result; older pipelines are recognised with
  `merge-base --is-ancestor`. Builder Git scripts: same repo-root logic everywhere, return to the
  script folder at the end, German comments on every git parameter; `status.ps1` warns outside
  `development`. Tested in a sandbox (bare repos, simulated ssh, malicious tars, races).
- `Reports14_builder_windows/scripts`: `checkin.ps1` shows the changed files of `source` / `images`
  as a numbered list – number = only this file (+ its `.xml`), `a` = all, `n` = nothing new, only
  send unsent check-ins; only the selection is committed (`git commit -- <paths>`). Rejected push
  now `git pull --no-rebase --ff` instead of `--rebase` (a rebase refuses while other, not
  selected reports are changed – reproduced); conflict -> `merge --abort`. New `convert_rdf.ps1`
  (report name only, folders fixed, `-Check`; output captured with `Start-Process`, success = exit
  0 AND XML written) and `git_setup.ps1` (name, e-mail, `core.autocrlf` global). `rwconverter
  logfile=` tested live and rejected: deprecated (`REP-34551`), no `REP-` lines in the file, and
  with a wrong login it prompts "Enter Password:" despite `batch=yes`. Tested with PowerShell 7.4
  (bare repo, two clones, races) and the real `rwconverter.sh` 14.1.2; `Git_checkin.md` updated.
- **GitHub Pages links** (prompt `prompt_ihw_pages_verlinkung.md`, steps 1–4 started): new
  `tools/check_pages_links.py` (stdlib only) – local check of every relative link (missing,
  anchor against the headings, folder without README, excluded in `_config.yml`, raw file,
  README without permalink), `--live` (sitemap + every internal href / anchor over HTTP),
  `--fix` and `--link-code` (dry-run diff, `--apply` with backup). Fixed: 2 broken anchors (also
  on github.com), 7 `TODO.md` + 3 `tools/` links (excluded on Pages) and 5 folder links -> GitHub
  view, 84 raw-file links (`.sh`, `.txt`, `.csv` …) -> `github.com/…/blob/main/`; render_ascii
  writes the `.prompt` / `.d2` source links absolute (migrated its own 64 links, no re-render).
  Only link targets changed (checked line by line). `code` mentions linked in
  `09-Install/README.md` + `00-Setup/README.md` as a sample (first mention per section, every
  table row); root README "Script Directories": folder column linked.

## 2026-11-11

- **`CONTRIBUTING.md`** (ACE item 7): scope, how to report a finding (fields, anonymise, what never
  to attach), pull requests only after agreement in an issue, public copy of the coding
  conventions (so far only in the git-ignored `CLAUDE.md`), customer-data rule with the demo set.
  Issue template `.github/ISSUE_TEMPLATE/finding.md`. **Pre-commit hook** `tools/hooks/pre-commit`
  (+ `install.sh` -> `core.hooksPath`): checks only staged lines / names – customer names from the
  local list `~/.config/ihw/customer_patterns` (never in git; `cs:` / `allow:` entries), forbidden
  files also with `add -f`, private keys / GitHub tokens / `password=<value>`, private IPs except
  the demo net, `bash -n`, stale customer ZIPs. 19 cases tested in a scratch repository; the
  rules run over the whole repository gave no false positive in new-style content.
  `SECURITY.md`: releases exist since `v1.0.0`.
- **Lint gate** (ACE item 5): `tools/ci_lint.sh` – `bash -n` on all `*.sh` / `*.sh.template`
  plus ShellCheck (one parallel run, errors = gate, warnings = report; `CI_LINT_VERBOSE=1` lists
  them) – run by `.github/workflows/lint.yml` on push / PR, badge in the README. Fixed for the
  gate: 5 ShellCheck errors (`ssl_check.sh` double `2>`, single-item loops in
  `export_forms_reports_conf.sh` / `ihw_shell_env.sh`, `${a}` before `[[:space:]]`) and the
  warnings with real risk: `00a-db_env_interview.sh` did not recognise DB_HOST = own IP on a host
  with more than one IP (`a|b` from an expansion is no alternation in `case`; reproduced);
  `05-` / `06-` patch scripts stop when `pushd` into the patch directory fails (before: OPatch
  would have run in the wrong directory); `40-` `rm -rf "${WORK:?}/…"`; dead case patterns in
  `tail_logs.sh` / `ihw_tools_lib.sh`. Customer tools versions bumped, ZIPs rebuilt.
- Tag `v1.0.0` on `d1a1251` (ACE item 4, GitHub release page with the ZIPs of that tag).
- All 32 diagrams: image links with `?v=`, "Source:" / "ASCII version" (one commit per document,
  no content change, no LLM run); diagram texts checked: `builder-windows` translated to English
  (hand-edited `.d2`), `apex-parts` prompt + hash brought to the current style template while
  keeping the approved SVG byte-identical.
- `tools/render_ascii/` checked in (ACE item 9; only `render_ascii.conf` stays git-ignored), README
  in English. New: `?v=<8 hex of the SVG's SHA-256>` on every image link (cache-busting for
  browsers / GitHub's image proxy, updated on every run when the SVG changed); source line and
  summary in English ("Source:", "ASCII version") – older German wrappers are recognised and
  rewritten. Tested in an isolated copy (old wrapper converted, new diagram, re-render changes
  `?v=`, second run idempotent).
- **Root README compacted** (ACE item 3, move – not shorten): new "Start here" block; nine
  sections moved 1:1 into `docs/` – `migration_forms_reports_to_14c.md`, `project_status.md`
  (the ~96 % sentence stays in the README too), `forms_reports_security.md`,
  `forms_reports_sizing.md` (+ new "Memory and process settings" table with sources),
  `forms_reports_installation_steps.md` (lifecycle incl. folder roles / known gaps, first run,
  setup), `general_security.md` (password concept, report security). Headings stay as stubs
  with one summary + link; line check 0 lost; incoming anchors repointed (00-Setup, 01-Run, 07-,
  08-SSL, 09-Install, 60-RCU, TODO); broken `#monitoring-phase-9` link of 10-Monitoring fixed. `## Troubleshooting` dissolved:
  symptom entries added in 02-Checks (`tns_admin_check.sh`), 04-ReportsFonts §11 (HTML parameter
  form), 05 / 06 overviews; "Start here" got a row "fix a known problem".
- `Reports14_builder_windows/scripts/`: `pull.ps1` and `checkin.ps1` (simple skeleton, German
  messages, plain ASCII, PowerShell 5.1 syntax) + `template.gitattributes` / `.gitignore`. Only
  fast-forward, never stash: a pull with own changes is allowed (Git aborts by itself when the
  same report is affected) – the first sketch was a dead end; rejected push -> `pull --rebase` +
  push, conflict -> `rebase --abort`. Tested on Linux with PowerShell 7.4, a local bare repo and a
  fake converter (14 cases); Windows PowerShell 5.1 + real `rwconverter.bat` at the customer.
  `Git_checkin.md` §3.2 / §4 updated (English).
- New `80-FMW-Architecture/reports_rwservlet_properties.md`: all `rwservlet.properties` elements
  of 14.1.2 (`rwservlet.xsd`, Oracle 12.2.1.3 §7.3 – the book the 14.1.2 library links) with
  default / DEV-PROD recommendation / library value; `13-` rewrites the whole file (hand-set
  elements lost). Live-tested: `reloadkeymap=yes` makes a new `cgicmd.dat` key work without a
  WLS_REPORTS restart; job retry: `<job retry>` belongs to `rwserver.conf` (xsd default 0,
  library 3), needs a Reports server restart, `JOBRETRY` in request / key overrides it (key
  wins), normal REP errors are retried too; "retry does not take" checklist.
  `reports_mail_handling.md`: `jobretry=0` in the ticket key (one mail per failure).
- New `14-ReportsBuilder/Git_checkin.md`: Git check-in idea for
  Reports developers on the Windows Builder server (clone per user `E:\git\<user>`,
  `pull.ps1` / `checkin.ps1`, no stash / ff-only, Git Credential Manager). Step 1 rdf -> xml
  tested live on the Linux test host: needs a DB login (`cmdfile=`; without: REP-3022 /
  REP-1430, also with Xvfb), 0.4-0.7 s per report, byte-identical XML on re-conversion, `name=`
  from the destination file name, exit code 1 on missing / broken file and wrong login;
  Windows test procedure for the customer included. Scripts: flow sketch only.
- `14-ReportsBuilder`: README in English; new
  `ReportBuilder_Windows_Kochbuch_en.txt` (full translation of the German cookbook, same commands
  checked line by line, ASCII / 80 columns); German cookbook unchanged. Links added in
  `reports_rwbuilder.md`, the Linux manual-install README and the root repository tree.
- New article `80-FMW-Architecture/reports_mail_handling.md` – section 7 of
  `reports_job_handling.md` moved 1:1 (overview, configuration, file locations, sender, demo
  calls, debugging, sources; job handling keeps a short summary + link). New **section 6:
  failure mail to a ticket system**, live-tested on the test host with a local SMTP sink:
  `notifyfailure=` in a `cgicmd.dat` key (also the generic `default` key) sends a failure mail
  for every job; the key value wins over the request in both orders; `destype=cache` and runtime
  errors (`REP-56133`, `REP-501`) mail too, a rejected request (`REP-50171`) does not; one
  failed request = 4 mails with `retry="3"` (`failedJobs` +1); a `cgicmd.dat` change needs a
  WLS_REPORTS restart; subject fixed `Job <jobname> notification from Reports Server`; `/`
  header lines of the note file land in the body. Test host restored afterwards (`cmp`).
- `reports_monitoring_getserverinfo.md` §4.3 corrected – confirmed live: `successfulJobs` /
  `failedJobs` (and the average times) are computed from the **persisted past job queue**
  (`<repserver>.dat`), not since the server start; they survive restarts and no command resets
  them (only stop + move the `.dat`, which also drops scheduled jobs). `failedJobs` = status code
  5 + 7, expired (15) counts as successful. New: failures per day via `showjobs queuetype=past`
  + XPath on `<finished>`. Plugin 7.1: positive difference only (no `startTime` comparison);
  §4.1 / §5 / Zabbix / PRTG notes adjusted.
- `80-FMW-Architecture`: consistent `reports_*` names – `report_engine_architecture.md`,
  `report_rwbuilder.md`, `report_server_image_handling.md` renamed to `reports_*` (git mv); all
  references in 41 files repointed (also older entries here), relative-link check 0 broken.
- `reports_monitoring_getserverinfo.md` §7.3: PRTG **REST Custom v2** sensor as option A (probe on
  the Reports host, POST body with `%restusername` / `%restpassword`, 10 channels with XPath, value
  types and limits from §5, further XPath values to swap in); SSH Script Advanced stays as option B.
  XPath checked with `xmllint` against the real answer, sensor itself not tested live.
- **Disclaimer & Acknowledgements** (ACE item 2): new last section of the root README (not
  affiliated with Oracle, trademarks, use at own risk / Apache 2.0 "as is", personal bird logo,
  AI co-author) + thanks to Jürgen Menge and Mark Eichhorst of die IT-Macher; pointer line at
  the README top; `09-Install/README.md` links the company and the root section.
- **Demo-data naming convention** (ACE item 0): README section "Demo Data" (test host
  `orafusion01.pipperr.local` / `10.10.10.124` / `fmwpdb` / `fr_domain` / `repserver01`,
  Reports-only demo domain `reportGPI`). Examples switched from invented names
  (`wls01.company.local`, `dbserver01`, `fmwhost01.example.local`, `192.168.1.10`,
  `10.1.2.0/24`, `ORCLPDB1`, `mail.example.com`, …) to the demo set; typo `reportRpgpi` →
  `reportGPI` in the manual cookbooks; example paths in docs → `/u01/app/oracle/fmw` /
  `/u01/app/oracle/domains/fr_domain` (CLAUDE.md too). Script defaults, search lists and
  `<host>`-style placeholders unchanged; Oracle's own placeholder `dbhost.example.com` kept.
- `engineResponseTimeOut` default 30 → **360 minutes** (6 h safety net: ends only a really hanging
  engine, never a long batch report): `13-oracle_setup_reports.sh`, `detect_env_conf.sh`,
  `fmw_prod.conf.template`, docs 13 / 00-environment-setup / 01-setup-interview,
  `reports_engine_architecture.md`. `05-ReportsPerformance/README.md`: missing
  `engineResponseTimeOut` is a WARN (as the script does), new note on the difference to
  `-DORBWaitForResponseTimeout` (ORB wait time / REP-50125 workaround, limits nothing).

## 2026-11-10

- Test host RCU DB: old 19.30 home removed after 13 days on 19.33 – its deinstall tool was never
  instantiated (`%setInstallFlag%`, 19.3 image + opatch route), so `detachHome` + rm;
  stale inventory entry of the 19.3 home detached; Data Pump dumps of 2026-10-17 deleted; audit
  growth checked (OK). `09-db_patch_rcu.md` "After the patch": check the deinstall tool first,
  the manual way, listener name trap.
- REP-50125 / `REPORTS_JVM_OPTIONS`: MOS KB924687 read – `reports_engine_architecture.md` section 6
  explains the three places (`reports.sh`, `<envVariable>`, engine `jvmOptions`) and their effect;
  `13-reports-detail-settings.md` quotes the KB note on `jvmOptions` and why this repository keeps
  the timeout there with the same value (no conflict, running at the customer).
- `02-Checks/clone_check.sh --apply`: besides SSL off / Coherence (WLST online) it now changes the
  four file places of the localhost hardening – Node Manager `AdminURL` in `startup.properties`,
  `ADMIN_URL` in `bin/*.sh`, `emoms.properties` (config, `.jmxori`, `tmp/_WL_user/em` source copy),
  engine `jvmOptions` in `rwserver.conf` (ORB timeout + `ORBServerHost`); backup of each file,
  idempotent, names the servers to restart. Tested in an isolated copy. `02-Checks/README.md`,
  `clone_golden_image.md` §2.1.
- Knowledge base from the customer project (anonymised, English): new folders
  `70-Customer-Projects/FormsReports14_linux_localhost/` (README + `Localhost_cookbook_en.txt` –
  harden an existing domain to localhost, incl. the four places found after the first hardening) and
  `70-Customer-Projects/FormsReports14_linux_clone/` (README + `Clone_cookbook_en.txt` – VM clone
  with a new RCU prefix, `reassociateSecurityStore`). `clone_golden_image.md`: new section 2.1
  hardening checklist, section 6 recipe in four phases with gates, section 7 updated, links to the
  new folders; `70-Customer-Projects/README.md` index.
- `clone_check_fmw.sh` 2026-11-10.8 and `02-Checks/clone_check.sh`: host name in
  `servers/AdminServer/tmp/_WL_user/em/*/META-INF/emoms.properties` is a FIX – EM copies this file
  over `config/.../em/META-INF/emoms.properties` and `.jmxori` at every AdminServer start, so an
  edit of `config/` alone is undone (customer). `clone_golden_image.md` section 3 and 7.
- Reports engine ORB: `jvmOptions` on `<engine>` in `rwserver.conf` **replace** the
  `REPORTS_JVM_OPTIONS` the engines inherit from `reports.sh` – without `ORBServerHost` there the
  engines listen on `0.0.0.0` (customer, loopback-hardened domain). `13-oracle_setup_reports.sh` and
  `05-ReportsPerformance/engine_perf_settings.sh` now add `-DORBWaitForResponseTimeout=999999999
  -Dcom.sun.corba.ee.ORBServerHost=127.0.0.1` (as in `reports.sh`) whenever they write engine
  `jvmOptions` (the drift check ignores them); `clone_check.sh` / `clone_check_fmw.sh` 2026-11-10.7 report engine `jvmOptions` without it as FIX. Docs: 13- detail
  settings, setup interview, `reports_engine_architecture.md`, `clone_golden_image.md` section 2.
- `clone_check_fmw.sh` 2026-11-10.5 and `02-Checks/clone_check.sh`: `rwserver.conf` whose only host
  name is the mail sender (`<notification>` `sender` `reports@<host>`) is a STEP (adjust per clone),
  no longer a FIX; any other host-name line in it stays a FIX.
- `clone_check_fmw.sh` 2026-11-10.4 and `02-Checks/clone_check.sh`: section 4 shows the matching
  lines (line number + text, max 3) under each host-name / IP finding, so it is visible which line
  holds the host name (a customer read the findings as "localhost taken for the host name").
- `clone_check_fmw.sh` 2026-11-10.3 and `02-Checks/clone_check.sh`: section 4 checks `AdminURL` in
  `servers/*/data/nodemanager/startup.properties` – a host name / IP there while the AdminServer
  listens on 127.0.0.1 starts the managed server in *Managed Server independence mode* on every
  direct Node Manager start (EM: server, cluster and `reports` deployment shut down, AdminServer
  only `BEA-149505`); on a clone it addresses the source. Found live at a customer on the hardened
  source and the clone. `clone_golden_image.md` sections 2, 3, 5, 6, 8 and tools README updated.
- `rcu_middleware_architecture.md`: corrected – `WLSSchemaDataSource` / `WLSRuntimeSchemaDataSource`
  have no target in a Forms/Reports domain (no `_WLS*` sessions), `LocalSvcTblDataSource` only on the
  AdminServer; new: Java SE audit loader with its own URL `audit.loader.jdbc.string` and the
  credential `AuditDbPrincipalKey` (one more place holding a schema password), farm name after a
  reassociation, section 3.1 sessions of a running domain (test host and customer), section 8.6 new
  prefix for an existing domain (empty OPSS schema, JPS-01013 offline, `reassociateSecurityStore`).
- `clone_golden_image.md` section 5, way 3: ASCII flow of the whole move (source, clone, RCU
  databases – autostart, `ADMIN_URL`, RCU, AdminServer only, `reassociateSecurityStore`,
  `updateCred`, offline data sources incl. URL, `audit.loader.jdbc.string`, host-specific places,
  checks on both DBs and of the scheduled jobs); steps 0–7 in detail; section 3 with tools
  `patch_install.ini`, crontab and the `showjobs` check; sources for `updateCred`, the Java SE
  audit loader and the `stopWebLogic.sh` code.
- `clone_check_fmw.sh` 2026-11-10.2 and `02-Checks/clone_check.sh`: section 4 also searches
  `$DOMAIN_HOME/bin/*.sh` for the own host name and reports an `ADMIN_URL` (domain scripts and
  shell) that does not point to `localhost` as FIX. Found at a customer clone: the cloned
  `stopWebLogic.sh` connected to `t3://<source>:7001` – with an open network it would have
  stopped the source AdminServer. `clone_golden_image.md` section 3 and recipe updated.
- `export_forms_reports_conf.sh` 2026-11-10.1: the sar CPU average of a day is the mean over
  all samples. Before, a day with a reboot gave one average per sar section glued together
  (e.g. `013`, `3310`). Tested on reboot days of the test host.
- `cookbook-Skill.md` 2.7: small changes to a config file are made with vi (grep first,
  keystrokes as comments, text at column 0, check with `tail` / `bash -n`), no
  `cat >> ... << 'EOF'`.
- `clone_check_fmw.sh` 2026-11-10.1 and `02-Checks/clone_check.sh`: new FIX when
  `REPORTS_JVM_OPTIONS` in `reports.sh` is set without `-DORBWaitForResponseTimeout=` – the
  Reports server then stops at the start (REP-50125 NullPointerException in
  `Utility.getOrbProperties`, read in `zrclient.jar`). Found at a customer loopback change whose
  cookbook line lacked the timeout; the skill example is fixed too.
- `reports_job_handling.md` section 7 rewritten: mail server in `rwserver.conf` (`host:port`,
  `enableSSL` = SMTPS, STARTTLS properties only with login – read from `rwrun.jar`), sender
  (`from=`, `sender` of the notification), call with a `cgicmd.dat` key, debugging steps,
  sources. Mail itself not tested yet (no relay on the test host).

## 2026-11-09

- `clone_check_fmw.sh` 2026-11-09.1: new option `--config` – under each finding the
  configuration file (full path) and its lines with the own host name / IP or the setting to
  change (`{AES}` / passwords masked, at most 8 lines per file). Tested on the test host and
  on a test domain for the FIX cases (listen address, Coherence, Node Manager, masking).
  2026-11-09.2 after the first customer run: an empty listen address shows only the `<name>`
  line of the `<server>` block (not every `<name>` of SSL / log), missing settings are named
  (Coherence unicast, `REPORTS_JVM_OPTIONS`, `WLS_REPORTS` block), `tnsnames.ora` with all
  `HOST` lines; the RCU host of a lower-case descriptor (`(host=…)`) is read again (the
  whole descriptor was printed). 2026-11-09.3: the messages name the ORB property
  `-Dcom.sun.corba.ee.ORBServerHost` (GlassFish ORB, as tested), not `com.sun.CORBA`.
- `export_forms_reports_conf.sh` 2026-11-09.1: on a Reports-only domain (no `formsweb.cfg`)
  the export hung after "Sources inventory ..." – with no Forms env file the TNS alias step
  ran a bare `cat` that waited for keyboard input (`Ctrl+D` let it go on). Now `cat
  /dev/null …`; output with Forms unchanged (compared on the test host). Tools ZIP rebuilt.
- `export_forms_reports_conf.sh` 2026-11-09.2: `DB_HOST` / `DB_PORT` / `DB_SERVICE` of the
  proposal stayed empty when the JDBC descriptor is written in lower case, as RCU does
  (`(host=…)(port=…)(service_name=…)`); now read case-insensitive. Tools ZIP rebuilt.

## 2026-11-06

- Reports calls with a password are POST everywhere: `15-` test report run
  (`_rws_post_report`, all parameters in the body, `userid` via `data-urlencode`, `\` and
  `"` escaped), examples in docs 12, 13, 14b, 20, `reports_user_local_ldap.md`.
  `cmdkey=default` works with POST (PDF from the Reports server, 0.2 s).
- `60-RCU-DB-19c/04-db_audit_setup.sh --apply` live on the test DB, common policies now
  enabled in the PDB, DDL there audited (`CREATE ROLE` test). Two fixes from that run:
  `ORA_SECURECONFIG` off in the PDB now also on a re-run (it was inside the skipped
  Block 2), final check with `[:space:]` (a SQL*Plus tab gave a false FAIL "2 of 2").
- Closing analysis of the customer 14c host, from the export and collection of
  2026-11-06: patch level green (nothing of CPU Oct 2026 missing), security red in one
  point only, `/console` and `/em` without an IP restriction. Accepted for now, see
  above.
- `weblogic_middleware_architecture.md` new §7a: what a patch changes in the Oracle Home
  and the Domain Home (measured on the test host), what stays behind, what the domain
  leaves in the home (`em.ear`, `domain-registry.xml`, JACOB and signed jars), checklist
  for a swapped home, `clean_domain_tmp.sh`. KB694158 still to be read.
- New tool `clean_domain_tmp.sh`: deletes the contents of `servers/*/tmp` and `cache` of
  a stopped domain, WebLogic rebuilds them at the next start (after a patch or a swapped
  FMW home). Dry run by default, `--apply` refuses while a process of the domain or home
  runs; `data`, `security`, `logs`, `stage`, `reports/cache` and `config` stay. In the
  `setdb` help (`ihw_shell_env.sh` 2026-11-06.3). First real start after `--apply` open.
- Customer follow-up after the first 14c move, as reported from the customer
  host:
  - `04-root_nginx.sh --apply` deployed the start page `/` and the `/formsWeb/`
    landing page (first run of the start page as root). Corrected the same day: no
    admin network was set. The exported `oracle-wls.conf` has no restriction on
    `/console` and `/em`, the customer stays on `ADMIN_IP_RANGE=any` by decision
    because its network has no clean separation;
  - `40- --apply` with `FORMS_CLIENT_FORM=test_form`, `WLS_FORMS` restarted;
  - systemd units rendered again (`30-`, `60-RCU-DB-19c/02-` / `08-`), reboot
    test with `systemd-analyze critical-chain` OK;
  - Way 1 of the import run at a customer.

  Docs 00-transfer, 04, 17, 30, README status and TODO updated. No code change.
- IPv6 came back after every reboot on a host with a network boot (customer, OCI,
  `netroot=iscsi`): the initrd creates a new NetworkManager profile with
  `ipv6.method=auto` at each start, our `nmcli modify` only left a file in `/etc`. `01-`
  now installs the dispatcher script `90-ihw-disable-ipv6` (sets the sysctl at each
  `up`) on every host and leaves a profile of the initrd alone; otherwise it changes the
  active profile by UUID and reads the value back (FAIL if unchanged). `00-` knows the
  dispatcher. Docs 00-set_os, OS cookbook. Effect after a reboot still to be confirmed live.
- `setdb` and the operation tools work together (`ihw_tools_lib` 2026-11-06.1,
  `ihw_shell_env.sh` 2026-11-06.1):
  - `status.sh`, `show_log.sh`, `show_errors.sh`, `show_all_logs.sh` no longer need
    `patch_install.ini`. They use the domain selected with `setdb` and read
    servers and ports from `config.xml` / `nodemanager.properties`. Order:
    `IHW_INI` by hand, `setdb` domain, ini, login. An ini with another domain
    gives a note and is ignored. `set_script_env.sh` warns in that case.
  - `setdb`: `t` / `cdt` change to the tools, `2t` selects and changes, `h` lists
    the tools that exist. The tools directory is also found above a known
    home (`/oracle/tools`), or set with `IHW_TOOLS_DIR=` in `~/.ihw_env.conf`.
  - `status.sh`: Node Manager keys searched in the ini, the home directory and the
    library autostart; a clear message when missing; new `status.sh --store-nm-key`.
- The analysis scripts and their templates / rules left this repository: they run
  on our side only and make no sense on a customer host. Private repository,
  cloned to `70-Customer-Projects/customer-analyse/` (ignored here). The tools ZIPs
  never contained them. Helpers used only by the analysis moved along
  (`ihw_tools_lib` 2026-11-06.2). Reports identical before / after. The old versions
  stay in the history of this repository.
- New `make_patch_install_ini.sh`: `patch_install.ini` from the existing domain, for
  the cookbooks. Dry run shows every value with its source; `--apply` writes it
  (600), never over an existing file. What cannot be derived stays commented out.
  `setdb` offers it once per session at `t` when there is no ini and a domain is
  selected.

## 2026-11-05

- Start page of the server `https://<host>/`.
  - `04-root_nginx.sh` writes `/usr/share/nginx/ihw-html/index.html` from
    `09-Install/nginx-index.html.template`: the server name, a link to the
    Forms client `/formsWeb/` (only with `FORMS_CLIENT_DIST=true`), a Reports
    note, `/ords/` (only with an ORDS include). No admin links.
  - Served by a new exact `location = /`, in an own directory – the
    package's `/usr/share/nginx/html/index.html` is an RPM symlink to the
    test page.
  - Tested in a private Nginx. Doc 04.
- Step 3 of the 14c move, first run on the customer's new 14c host: export
  + collection analysed. Patch level green. Security red only for open
  `/console` / `/em` (`ADMIN_IP_RANGE=any`).
  - **`analyse_forms_reports_export.sh` 2026-11-05.7** – false positives on a
    14c target fixed:
    - several Reports servers of ONE domain on one broadcast port is right
      (INFO, was WARN);
    - no `<folderAccess>` in the in-process `rwserver.conf` with
      `inprocess=no` (INFO);
    - host name values of a 14.1.2 export are the new host (INFO with a
      clone hint);
    - TNS_ADMIN directories counted only with defined aliases (Oracle's
      sample files no longer count).
  - **`webutil.cfg.template`:** the example paths `/mnt/shared/import` /
    `/mnt/shared/export` were active as `read.1` / `read.2` / `write.1` –
    directories that do not exist on a host without that share. Default now
    `##FORMS_TMP##/webutil`; the examples are commented.
  - **`14-`:** creates `FORMS_TMP/webutil`, and every WebUtil transfer
    directory below `FORMS_TMP` of the deployed `webutil.cfg`. Other missing
    ones (shares) are a WARN.
- `export_forms_reports_conf.sh` 2026-11-05.4:
  - no shell error at the end of the load profile when `reports_jobs.csv`
    or `host_sar.csv` is missing. `wc -l < file 2>/dev/null` did not stop
    the redirect error; a secured Reports server without `--rw-auth`
    leaves no job list – first export of a library 14c host.
  - The block "ihw_import/ – what goes where" in `00_report.txt` names
    the importer and the overlay files. It said "no 14- mechanism yet".
- `40-`: check of the start form. The `.fmx` of `FORMS_CLIENT_FORM` (else
  `form=` of the section) must be in `FORMS_PATH` of the section's
  `envFile`. Otherwise WARN – the clients would start into FRM-40010. At
  the customer, the kept library value `main.fmb` did not exist; the test
  form of `15-` is `FORMS_CLIENT_FORM=test_form`.
- Forms client bundle landing page: `/formsWeb/` showed only a 403
  (`autoindex off`, no index file; customer).
  - `40-` now writes `index.html` from
    `client_templates/index.html.template`: shortcut name, a button for
    `FormsWeb-Install.cmd`, three steps, the SmartScreen note, the versions
    of the manifest. Written only when it changed, also when the bundle is
    up to date.
  - The Nginx template has `index index.html;`, `text/html` and
    `image/x-icon` in the `types` block and `charset utf-8`. Existing hosts:
    run `04-root_nginx.sh --apply` again.
  - Tested in a private Nginx. Doc 40 §4 / §11.
- `FORMS_CLIENT_TRUST_CA` pointed to `…/pki/customer/root.crt`, but the
  file did not exist (customer). The interview proposes this path for
  `SSL_CERT_SOURCE=customer`; only `ssl_customer_certs.sh` writes it, from a
  delivered `root.crt`, and none was delivered.
  - `40-` now shows which root the clients need: the top of the chain Nginx
    sends, whether it verifies against the OS store, and the two ways out
    (deliver the company root / set the value empty for a public CA).
  - `ssl_customer_certs.sh` warns when the conf points to the file, but no
    `root.crt` was delivered.
- `40-`: the check of `FORMS_CLIENT_TRUST_CA` names the cause instead of
  "no readable certificate" (customer). Possible causes:
  - the file is missing;
  - the file or a directory is not readable for oracle (`ls -ld` of both);
  - neither PEM nor DER, shown with `file`, the size and the PEM block
    types (PKCS#7, private key, empty).

  DER is accepted (`keytool` imports it), and the PEM / DER form is set
  explicitly – OpenSSL 3 guesses the format otherwise. New WARN when the
  certificate has no `CA:TRUE`.
- `40-oracle_forms_client_bundle.sh` reviewed:
  - client JDK and patch numbers come from `patches_fmw.csv` – up to date;
    the test host bundle is on 21.0.13.0.2 (CPU Oct 2026);
  - new: soft SHA-256 check of the client JDK ZIP against the patch list
    (`patch_zip_sha_check`, like `05-` / `06-`);
  - new: check of the start section `FORMS_CLIENT_CONFIG` in the deployed
    `formsweb.cfg`. FAIL when it does not exist. WARN when it switches
    WebUtil on without `baseSAAfile=webutilsaa.txt` – FSAL would load no
    WebUtil jars. The customer sections of the import are on FSAL +
    WebUtil.
  - Docs 40 and `00-transfer_customer_settings` (Way 2: set the customer
    section, then `40- --apply`).
- systemd units wait for the Oracle file systems: `RequiresMountsFor=` in
  `oracle-listener` (`60-/02-`), `oracle-db` (`60-/08-`, plus
  `DB_DATA_DIR`), `fmw-<domain>` (`30-`: Oracle Home, domain, JDK, ctrl dir,
  `TNS_ADMIN`) and `ords@` (`12-APEX-Ords/04-`). Also in the German autostart
  cookbook, with a `critical-chain` check after the reboot. At the customer,
  the listener started at 7 s and the `/oracle` block volume (`nofail` /
  `_netdev`, after `network-online.target`) was mounted only at 11 s. Docs
  30, 60-02, 60-08 and the 12-APEX-Ords README updated.
- Way 1 order clone → import → interview:
  - `customer_conf_import.sh` links `environment.conf` to the new conf when
    there is none yet. Before, the interview started fresh and wrote
    `environments/<basename DOMAIN_HOME>.conf`, so the import block was not
    seen.
  - `01-setup-interview.sh` takes `REPORTS_SERVER_INSTANCES` of the import
    as its Reports server list. Before, it asked again with the default
    `repserver01` – two different lists, the pitfall of the live run.
  - Process document section "When does the interview run?".
- Process document `09-Install/docs/00-transfer_customer_settings.md`:
  moving a customer environment to 14c in three steps (extract + analyse,
  build with the customer's master data – Way 1 preferred / Way 2, analyse
  again + harden). It includes the pitfalls of the first live run,
  verification and rollback. Linked from:
  - the new section at the start of the root README;
  - `09-Install/README.md`, doc 17 (status: Way 2 live-tested);
  - `70-Customer-Projects` README, tools README, the German first-visit
    cookbook;
  - `00-Setup` / `07-Maintenance` READMEs.
- `13- --remove-server` live at the customer: `repserver01` removed with
  WLST `deleteReportsServerInstance` (before / after lists, backup,
  `servers/<name>` moved into the backup). `30- --apply` then removed it
  from the autostart. Fix found on the way: `14b-` now updates the
  "Server" / "Date" header lines of its `cgicmd.dat` block too. Before, the
  old server name stayed in the comment and `--remove-server` listed it as
  a reference.
- Reports status, false OK fixed: `getserverinfo` answering HTTP 200
  without `<serverInfo>` was reported as "rwservlet reachable". The output
  was an empty "Server Info" section and 0 FAIL, while the smoke test got
  REP-51002. This is now a FAIL that shows the start of the answer (lib
  `rws_http_verdict`, used by `rwserver_status.sh`, `90-` and
  `engine_perf_analyse.sh`).
- `rwserver_status.sh --server NAME` no longer takes NAME as the WLS managed
  server too. The "Status URL" line is now written to the log.
- `apply_customer_conf.sh`: after `start-all` it waits until every Reports
  server answers `getserverinfo` (default up to 240 s,
  `IHW_REPORTS_READY_WAIT`) before the smoke test. It prints the details
  of a server that does not answer.
- Autostart drift: the autostart scripts of `30-` carry the Reports servers
  of `config.xml` as of configure time. Servers created later by `13-` were
  not started by `start-all` / systemd (customer: only the old
  `repserver01` came up, REP-51002 for the new ones). The new lib function
  `autostart_drift` drives three changes:
  - `startStop.sh` warns and starts / stops the missing components directly
    through the Node Manager;
  - `13-` warns after `--apply` / `--remove-server`;
  - `apply_customer_conf.sh --apply` re-renders with `30- --apply` before
    the restart.
- `13-`: the multicast check now runs AFTER the `rwnetwork.conf` port update.
  WLST creates a new Reports server with Oracle's default port 14021; the
  check ran before the update and stopped the first customer `--apply` with
  a false FAIL, although 13- had already set the port. The check output
  now includes the port-consistency line. In a dry run, a port difference
  that `--apply` fixes is reported as WARN. The empty "ReportsTools instance
  already exists:" line is gone.
- First customer dry run of `apply_customer_conf.sh`, fixes:
  - `14-`: the code-signing readiness check now covers the customer jars of
    the overlay, too. Before, it was skipped when `jacob.jar` was already
    signed, so a missing keystore showed up only as a FAIL during `--apply`.
  - `14-`: every env file is labelled with its own name (it was always
    `default.env`); the overlay path shows the overlay file instead of the
    temp copy.
  - `apply_customer_conf.sh`: new section "Reports server names". It warns
    when a server of the overlay (`reports/<name>.env`) is not in
    `REPORTS_SERVER_INSTANCES`, or when `REPORTS_SERVER_NAME` is not in it
    (14b- would write `cgicmd.dat` for the old server). It lists the servers
    of the domain that are no longer configured, with the
    `--remove-server` hint. It also shows both server lists and warns
    when the interview array `REPORTS_SERVER_NAMES` differs from
    `REPORTS_SERVER_INSTANCES` (13- uses the latter).
- `13-oracle_setup_reports.sh --remove-server <name> [--apply]`: remove a
  Reports server instance. It checks the gates (not in
  `REPORTS_SERVER_INSTANCES`, stopped, AdminServer up) and lists the
  references, makes a backup of `config.xml` and the component directories,
  then runs WLST `deleteReportsServerInstance`. Use case: the customer import
  replaces `repserver01` with the customer's server names.
- Logging for the customer test: `apply_customer_conf.sh` writes the full
  output of every step into one log. The importer log holds the whole
  decision table and the file list of the overlay.
- **Customer import built:**
  - `00-Setup/customer_conf_import.sh`: export → overlay
    `environments/<env>.customer/` + `IMPORT_DECISIONS.md` + conf block.
    It covers:
    - Forms: sections, env files per `envFile`, WebUtil, deduplicated jars;
    - Reports: per-server `<environment>`, `cgicmd.dat` without logins;
    - customer fonts.

    Safe corrections with `--keep-customer`; passwords never.
  - `07-Maintenance/apply_customer_conf.sh`: Way 2 sequence `14b-` / `14-` /
    `13-`, restart, `15-` / `90-`.
  - `14-` renders the overlay with `##PLACEHOLDER##` from `environment.conf`.

- **Traffic lights in the customer reports:**
  - **Patch analysis:** 🟢 requirements of the cycle met / 🟡 partly /
    🔴 nothing or no SPB, with the known product gaps below it.
  - **Configuration report:** renamed to the **Forms & Reports status**
    (`fmw_forms_reports_status_<customer>_<date>.md`, template
    `fmw_forms_reports_status_template.md`). It gets a security light per
    area:
    - weights in `customer-analyse/rules/security_weights.txt`
      (critical / high / low);
    - patch level taken from the patch analysis;
    - overall = the worst area.
  - Shared helpers in `ihw_tools_lib.sh` 2026-11-05.4: `ihwt_light_md`,
    `ihwt_weigh`, `ihwt_status_rows`.

- **Patch analysis for the customer:** new
  `70-Customer-Projects/tools/bash/analyse_patch_collect.sh` + template
  `customer-analyse/patch_analyse_template.md` turn a collection of
  `collect_fmw_env.sh` into the customer document (installed patches, the
  patch list of the cycle against the environment, Java, other homes, web
  tier, OPatch prerequisites, order of work, route cookbook / library,
  findings). Reference = our patch lists (`patches_fmw.csv` for 14.1.2, the
  12c customer list). Collector 2026-11-05.3 records whether the library
  is present (route B). `ihw_tools_lib.sh` 2026-11-05.3: `ihwt_unpack`,
  `ihwt_report_secret_check`, `ihwt_fact`, `ihwt_block` (shared by both
  analyses).

- **Web tier in the customer tools:** export `export_forms_reports_conf.sh`
  2026-11-05.3, collector `collect_fmw_env.sh` 2026-11-05.2 and analysis
  2026-11-05.3 find Nginx, Apache + WebLogic plug-in (`mod_wl`) and OHS
  (also standalone web tier domains), store every configuration file incl.
  includes, and write the routing (`ihw_import/web_tier.txt`); the analysis
  maps the routes to the 14c Nginx template (section 13.2) and rates admin
  paths, TLS protocols, plain HTTP, `TraceEnable`, `DebugConfigInfo`,
  version banners. Certificate subjects from every HTTPS listener (was: OHS
  only). Shared functions `ihwt_webtier_*` in `ihw_tools_lib.sh` 2026-11-05.2.
- `collect_fmw_env.sh` 2026-11-05.1: encrypted ZIP by default, patch scope
  (registry versions, bundled JDK, components, other homes, OPatch
  prerequisites, Forms client JRE).
- Load profile fixes from the first real customer export (12c job status 12,
  per-line date cutoff, raw showjobs times).

## 2026-11-04

- **Cleanup – one environment tool chain:** `00-Setup/init_env.sh` renamed
  to `00-Setup/detect_env_conf.sh` with `--list` / `--select [n] --apply` for
  the `environment.conf` symlink; `00-Setup/set_env.sh` removed (the shell is
  switched with `setdb`).
- **Customer tools in one place:** `status.sh`, `show_log.sh`,
  `show_errors.sh`, `show_all_logs.sh` and `set_script_env.sh` (was
  `set_install_env.sh`) moved to `70-Customer-Projects/tools/bash/`; the
  former `env.ini` + `install.ini` are **one `patch_install.ini`** per
  customer folder; `setdb` puts `$ORACLE_BASE/tools` into the PATH and has
  `domain`; road map
  [Start_beim_Kunden_kochbuch_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Start_beim_Kunden_kochbuch_de.txt)
  (tools → setdb → ini → analysis or installation).
- **Uniform customer folder names** (`Reports14_linux_manual_install`,
  `Reports14_builder_windows`, `FormsReports12/14_patch_cpu_2026-10`) and
  speaking patch list names (`patches_cpu_forms_reports_12c_oct2026.csv`,
  `patches_cpu_reports_14c_oct2026.csv`).
- README split into README (overview), [TODO.md](https://github.com/gpipperr/IHateWeblogic/blob/main/TODO.md) and this file.
- `;` in `<folderAccess><write>` confirmed at the customer (nightly report
  job into a second output directory).
- 12c patch cookbook CPU Oct 2026 final version for the customer.

## 2026-11-03 (afternoon, customer on site + test host)

- **Shell environment switcher** `setdb` / `setfmw` / `setfw`
  ([ihw_shell_env.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/tools/bash/ihw_shell_env.sh), installed by `03-` as
  `~oracle/.bashrc.d/ihw_env.sh`, after the model of OraBashShell): one menu – FMW home only + domains,
  DB homes under their home name with every SID and always a `(no SID)` line, `c` clear, `h` help, `q`
  quit. It sets `WLST`, `wlst`, `cdlog` and the Forms / Reports config paths, never touches
  `environment.conf`, and sets `SQLPATH` / `ORACLE_PATH` (`~/sql`) **only for a DB entry** – a
  `login.sql` disturbs datapatch / utlrp. The library unsets both in every script.
- **DBA SQL scripts** in `~/sql` (OraDBASQLScripts git clone,
  `60-RCU-DB-19c/07-db_sql_scripts.sh`, offline `--archive`); `git-core` is now in `02-`.
- **`detect_env_conf.sh --db` never worked** (the DB block ran before the `detect_*` helpers were defined →
  always `ORCL` / `19c/dbhome_1`). It now works, plus fixes: SID case (`comm`), pmon home via
  `/proc/<pid>/exe`, tnsnames parsing, domain via `domain-registry.xml` and `/u01/app/oracle/domains`,
  `orabasetab` field.
- **`rwservlet` with `authid=` in the URL writes the password into `WLS_REPORTS/logs/access.log`** –
  every web command and report call now goes as POST (`reports_server_lib.sh`, cookbooks);
  [reports_monitoring_getserverinfo.md](80-FMW-Architecture/reports_monitoring_getserverinfo.md)
  (XML field reference, alarm table, tested Nagios / Checkmk plugin).
- **Scheduled reports** ([reports_job_handling.md](80-FMW-Architecture/reports_job_handling.md) +
  `Reports_Zeitplan_kochbuch_de.txt`): cron + `rwclient.sh cmdfile=` recommended; `SCHEDULE=`
  jobs live in `$DOMAIN_HOME/reports/server/<server>.dat` (survive restarts, come back with a
  restore / clone); `<folderAccess><write>` has no subdirectories (`REP-56133`).
- **Cookbook style** rules in [cookbook-Skill.md](70-Customer-Projects/cookbook-Skill.md) (one command
  per line, blank lines, no nesting, "what ends up where" tree, sources); the security cookbook
  rewritten in that style.

## 2026-11-03 (review of `09-Install` 07–14 against the customer logs)

One RCU tablespace `RCU_TABLESPACE` checked in the DB; `08-` writes
`time-taken` into `config.xml` after `writeDomain` (JRF overwrote it) and
sets the Node Manager and embedded-LDAP credentials already in the domain
template (customer: AdminServer "Access denied", managed servers `error 49`
after `13-`); `11-` first start order; `13-` keeps `securityId`, an embedded
LDAP password change is a FAIL with "restart AdminServer"; `14-` writes
idempotently, needs the code-signing keystore (FAIL also in dry run),
`--resign` for signatures without timestamp (no TSA without egress);
the **Phase 7 acceptance** `09-Install/90-oracle_validate.sh` (16 analyse
scripts + direct checks, one summary – test host 24 OK / 3 WARN / 0 FAIL);
Nginx `ihw_timing` log format and
[forms_performance_analyse_tuning.md](80-FMW-Architecture/forms_performance_analyse_tuning.md);
the **configuration export** of an existing 12c/14c customer environment
(`70-Customer-Projects/tools/bash/export_forms_reports_conf.sh`, encrypted, never
into git – import step follows); for the Linux Reports-only customer a
complete **CPU October 2026 patch set** (CSV + cookbook for a home with
unknown starting level) and a cookbook to **check and complete the Reports
security** (monUser / RepRunner, embedded LDAP, `securityId`, libOVD).

## 2026-11-02 (customer DB install + review of every `60-RCU-DB-19c` doc against its script, one commit each)

`00a-db_env_interview.sh` writes
`environment_db.conf` from the template; `09-Install/00-install-status.sh`
shows the progress from the run history; the RCU DB home is built **patch
first, then install** (19.3 image + `opatch` RU / OneOffs, then
`runInstaller` – the 19.3 installer cannot link on OL9 and stopped before
instantiating its scripts; `-applyRU` fails on FMW hosts with "Invalid Home"),
the gold image stays preferred; steps renumbered (`02-` listener, `03-`
DBCA, `04-` audit, `05-` FMW tablespace, `06-` RCU profile; the old `02-`
stub removed); fixes found by the review: the audit policies were root-local
(not effective in the PDB with the RCU schemas) – now common; the registry
queries of `06-` / `09-Install/07-` failed before the first RCU run; `02-`
started the listener with the shared `TNS_ADMIN`; every DB doc now has the
manual way in the script's order.

## 2026-10-30 (same customer – `*.oracle.com` blocked, small local disk, ZFS store via NFS)

The **patch numbers per cycle in CSV lists**
(`09-Install/download/patches_fmw.csv` + `patches_db.csv`, SHA-256 as soft
check) downloaded by the standalone tool on a share host; a **patch archive**
(`PATCH_ARCHIVE`, NFS/ZFS master) with `07-Maintenance/patch_storage.sh`
(`pull` per step, `clean` after a successful step) driven by a **run
history** every install / maintenance script writes (`log/run_history.csv`);
root scripts log centrally from the first step on; `60-RCU-DB-19c` adds
oracle to `dba` / `oper` (CVU PRVF-7566 at the customer);
`70-Customer-Projects/tools/bash/check_disk_space.sh` (where is the space, NFS
never scanned); and the **CVE early warning** `10-Monitoring/cve_watch.sh`
(Oracle CNA records on release day instead of the late NVD CPE, OSV for the
third-party jars of the home, KEV, EPSS, heise).

## 2026-10-29

Review of every `09-Install/docs` file against its script
(one commit each, architecture links), `fmw_patch_env.sh` and
`clone_check_fmw.sh` as standalone customer tools, customer certificates via
an inbox (`08-SSL/ssl_customer_certs.sh`), `WLS_SERVER_FQDN` as the public
server name, optional `ADMIN_IP_RANGE` in Nginx, and the fixes from the
**first real customer installation** (OCI, CIS image): `/dev/shm` / `/tmp`
noexec, installer temp in `$ORACLE_BASE/tmp`, EPEL / missing packages no
longer abort, reachability test of the Oracle download hosts.

## 2026-10-28

The **RCU database patched out-of-place 19.30 → 19.33**
(`60-RCU-DB-19c/01- --target-home` from the AutoUpgrade gold image +
`09-db_patch_rcu.sh`, domain down ~22 min, datapatch in every container,
rollback path), the PDB$SEED MAX_STRING_SIZE fix in `03-` (then `05-`), a **disk sizing
guide**, the central article on **certificates and trust stores**, and a
standalone **MOS patch download tool** (`70-Customer-Projects/tools/bash/mos_patch_download.sh`,
CSV list per cycle – first for the customer's 12c CPU October 2026 run).

## 2026-10-27

The **patch-cycle analysis with Claude**
(`10-Monitoring/patch_cycle_analysis.sh` + skill, customer / maintainer mode,
`update_plan.md` as the prompt for switching the lib) on a **hardened Claude
Code setup** (`setup_claude.md`, `claude_setup_check.sh`, guard hook, new
parameter `IHW_ENV_TYPE` – never on production); the **RCU database
requirements** for 19c / 26ai documented and checked
(`07-oracle_setup_repository.sh --check`, Oracle parameter minimums in
`60-RCU-DB-19c` and on the test DB, licence: separately licensed DB),
`local_listener` without the DBCA alias, a host pre-check with the standalone
**CVU** (`60-RCU-DB-19c/00b-`); the **Reports Builder on Windows** cookbook
was run live at the customer and worked as written (developers need local
admin accounts), with an architecture article incl. the development workflow
and the image search paths per side; measured: the Reports tools do not use
the RCU schemas at runtime.

## 2026-10-26

Nginx strips client-supplied WebLogic headers and overwrites
`X-Forwarded-For` (live-tested, `/console` header bug fixed), the AdminServer
redirects to `https://` directly (`weblogic-plugin-enabled`),
`rcu_repository_check.sh` reports invalid objects, the Jackson / FMW DBCLIENT
scanner findings are assessed (`00-patch-references.md`).

## 2026-10-24

All 17 patch READMEs of the **CPU October 2026** set read
and documented in a versioned manual guide per cycle
([`70-Customer-Projects/FormsReports14_patch_cpu_2026-10/`](70-Customer-Projects/FormsReports14_patch_cpu_2026-10/README.md)),
`oracle_software_version.conf` + `04-`/`05-`/`06-` switched to that set
(incl. the eight FMW Infrastructure bundles), JDK 21.0.13.0.2 downloaded;
applied on the test host the same day with `07-Maintenance/80-`/`81-`/`82-` (0 FAIL, smoke test OK);
`startStop.sh` now also handles ORDS, and the patch scripts pause for a VM snapshot.

## 2026-10-22/23

The **Forms client distribution via URL** (jlink Java
runtime + FSAL + JACOB from Nginx, PowerShell installer in the user profile)
and **one `TNS_ADMIN`** for every process – together the first complete
Forms session from a Windows client (alias login, test form). Since
2026-10-23 also: all Reports engine tuning values from `environment.conf`
(an `--apply` in `05-` survives the next `13-`), backup retention
(`backup_config.sh --keep`, `bak_cleanup.sh`) and a **loopback-only,
clone-capable** installation (`02-Checks/clone_check.sh`, SSL demo ports off,
Reports ORB on 127.0.0.1); in the evening the last own security / tuning
items: Forms `maxRuntimeProcesses` from RAM, `engineResponseTimeOut` from
measured run times, the Reports web-command test series (doc 81, Nginx
block), `time-taken` in the Forms access log, a font test report in the
smoke test and a daily certificate expiry check (cron).

