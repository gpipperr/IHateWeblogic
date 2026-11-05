# IHateWeblogic – Changelog

What was finished when, newest first. Moved out of the README on 2026-11-04;
details of every fix: `git log`. Open items: [TODO.md](TODO.md).

## 2026-11-05

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
  [Start_beim_Kunden_kochbuch_de.txt](70-Customer-Projects/Start_beim_Kunden_kochbuch_de.txt)
  (tools → setdb → ini → analysis or installation).
- **Uniform customer folder names** (`Reports14_linux_manual_install`,
  `Reports14_builder_windows`, `FormsReports12/14_patch_cpu_2026-10`) and
  speaking patch list names (`patches_cpu_forms_reports_12c_oct2026.csv`,
  `patches_cpu_reports_14c_oct2026.csv`).
- README split into README (overview), [TODO.md](TODO.md) and this file.
- `;` in `<folderAccess><write>` confirmed at the customer (nightly report
  job into a second output directory).
- 12c patch cookbook CPU Oct 2026 final version for the customer.

## 2026-11-03 (afternoon, customer on site + test host)

- **Shell environment switcher** `setdb` / `setfmw` / `setfw`
  ([ihw_shell_env.sh](70-Customer-Projects/tools/bash/ihw_shell_env.sh), installed by `03-` as
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

