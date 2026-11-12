# IHateWeblogic – Changelog

What was finished when, newest first. Moved out of the README on 2026-11-04;
details of every fix: `git log`. Open items: [TODO.md](https://github.com/gpipperr/IHateWeblogic/blob/main/TODO.md).

## 2026-11-12

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
- New `70-Customer-Projects/Reports14_builder_windows/Git_checkin.md`: Git check-in idea for
  Reports developers on the Windows Builder server (clone per user `E:\git\<user>`,
  `pull.ps1` / `checkin.ps1`, no stash / ff-only, Git Credential Manager). Step 1 rdf -> xml
  tested live on the Linux test host: needs a DB login (`cmdfile=`; without: REP-3022 /
  REP-1430, also with Xvfb), 0.4-0.7 s per report, byte-identical XML on re-conversion, `name=`
  from the destination file name, exit code 1 on missing / broken file and wrong login;
  Windows test procedure for the customer included. Scripts: flow sketch only.
- `70-Customer-Projects/Reports14_builder_windows`: README in English; new
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

