# IHateWeblogic – Changelog

What was finished when, newest first. Moved out of the README on 2026-11-04;
details of every fix: `git log`. Open items: [TODO.md](TODO.md).

## 2026-11-10

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

