# IHateWeblogic – Open Items / TODO

Only what is still open (state 2026-11-10). Everything finished is described
in the folder READMEs, in [CHANGELOG.md](CHANGELOG.md) and in `git log`; the
review of 2026-10-19/20 is summarised in each README ("Review 2026-10-19").
Overview and status: [README.md](README.md#project-status).

## Cookbooks – still to check on a fresh run / at the customer

The findings of the cookbook style rewrite (2026-11-04) are fixed (`git log`).
Still open:

- [ ] `cmdkey` / `userid=` report runs as POST (Reports cookbook 9.8 / 9.11,
  Font step 7 test PDF via `destype=cache`) on a customer host.
- [ ] Windows Builder: German `mklink` / `setx` messages, `rwconverter
  cmdfile=`, PowerShell 5.1 POST against the internal CA.
- [ ] Autostart / start-stop: generated `report_env.sh` (values from step 0)
  and `start_wls_all.sh` reading `patch_install.ini` – first real run.

## Patch cycle CPU October 2026 – remaining

Applied on the test host 2026-10-24 (details, runtimes, answered open points:
[`70-Customer-Projects/FormsReports14_patch_cpu_2026-10/`](70-Customer-Projects/FormsReports14_patch_cpu_2026-10/README.md)).
Next cycle: CSPU November 2026 – new 14c folder, freeze the October one.

- [ ] **Brotli CVE-2026-111497** (CISA KEV, 2026-10-28): not reachable
  through Forms / Reports / WebLogic / Nginx. Test host: OS fix
  ELSA-2026-500513 (`brotli-1.0.9-10.0.1.el9_8`) installed 2026-11-10; open:
  restart of the Reports server (`rwserver` + engines still map the old
  `libbrotlidec` via `libfreetype` – check `grep -l 'libbrotli.*(deleted)'
  /proc/[0-9]*/maps`), the same on customer hosts. Claude Code: the VS Code
  session runs the native binary (no Node); the old npm CLI 2.1.287 on Node 20
  (EOL, bundled Brotli 1.1.0) → native CLI, `npm uninstall -g
  @anthropic-ai/claude-code`, remove or upgrade the nodesource Node 20 –
  [00-patch-references.md, Brotli](09-Install/docs/00-patch-references.md#brotli-decoder--cve-2026-111497-state-2026-10-28).

- [ ] **Client JREs** (Java Web Start / FSAL) of the Forms users: CPU426 JRE
  (JRE 8u511 Patch 40186686 = `1.8.0_511-b26`, observed 2026-10-22; re-check
  after 23 Oct whether 18143322 then also delivers b26) via the customer's
  software distribution, same bitness as the WebUtil DLLs, test the
  code-signing trust after the update – JSSE runs on the client, see
  [forms_runtime_architecture.md §1.2](80-FMW-Architecture/forms_runtime_architecture.md#12-threat-model-of-a-client-side-tls-jsse-flaw).
- [ ] Confirm the remaining CVE coverage (CPU Oct 2026: CVE-2026-83399 /
  91323 / 47065, 9.8; September 83021 / 83099). Confirmed from the READMEs:
  4176 (PERL), OHS 87347 / 87346, ADF, FMW Control 91467, OPSS 83020, Jackson
  54512–54515 (Third-Party BP), WebGate CVE-2025-0725.

## Tests that need a client or a fresh install

- [ ] **Forms client distribution via URL** – rest of the Windows test plan
  ([concept 40 §8 / §12](09-Install/docs/40-forms_client_distribution.md))
  – install + FSAL start work since 2026-10-23. Open: update and self-update
  round (next cycle or `40- --force`), offline start, `-Rollback`, JACOB /
  Excel, `AllSigned` + Authenticode signature of the script.
- [ ] **Windows client**: Java Web Start start of the test form (FSAL done
  2026-10-23), signed vs. unsigned `jacob.jar`, revocation check
  of Java Web Start with a CA without CRL/OCSP, real OLE call (Excel);
  Forms **pool vs. session** criterion and RSS of a real session
  (`06-FormsDiag/forms_perf_analyse.sh`).
- [ ] `01-setup-interview.sh` interactively (questions `REPORTS_SECURITY`,
  embedded LDAP password, Reports server admin, `FORMS_TMP`).
- [ ] **Fresh domain with the new `08-` template** (2026-11-03): Node Manager
  credentials and embedded-LDAP `cn=Admin` password set at `writeDomain` –
  then the first `11-` start and `13-` must run without "Access denied" /
  `error 49` and without the `13-` restart path (bind fails →
  `setCredential` → restart, still in place for older domains).
- [ ] `startStop.sh`: the "Node Manager running without autostart" path
  (`start-all` / `stop-all` through `fmw_ctl.sh` incl. ORDS ran live
  2026-10-24/26).
- [ ] `09-Install/07-` on a fresh database: `-databaseType EBR` with
  `-createRepository`, profile assignment right after RCU, FAIL path of the
  `db_securefile=FORCE` pre-check.
- [ ] Full Reports-only domain creation (`INSTALL_COMPONENTS=REPORTS_ONLY`,
  so far verified with WLST offline only).
- [ ] `08-SSL` modes `EASYRSA` and `REQUEST` end-to-end.
- [ ] `08-` loopback block (SSL off, Coherence unicast) in a **new** domain –
  tested offline on a domain copy and online on the existing domain only.
- [ ] **Clone test – rest**: way 3 (VM clone, new RCU prefix,
  `reassociateSecurityStore`) ran on the test host (same DB, prefix `CLN`) and
  at a customer (Reports only, other DB) on 2026-11-10. Still open: the full
  golden-image recipe of
  [clone_golden_image.md §6](80-FMW-Architecture/clone_golden_image.md) with
  `13-` / `40- --apply` on the clone, a clone of a domain **with Forms**, way 2
  (re-bind to a copied repository).
- [ ] **`02-Checks/clone_check.sh --apply` file places** (2026-11-10:
  `startup.properties` `AdminURL`, `bin/*.sh` `ADMIN_URL`, emoms 3 files,
  engine `jvmOptions`): tested only in an isolated copy – first run on a real
  domain with these findings, then restart and re-check.
- [ ] **Public knowledge-base cookbooks** (2026-11-10,
  [localhost](70-Customer-Projects/FormsReports14_linux_localhost/README.md),
  [clone](70-Customer-Projects/FormsReports14_linux_clone/README.md)): the
  write steps come from the customer runs; untested as written: the WLS_FORMS
  WLST steps (listen / SSL / Coherence) of the localhost cookbook, `curl -K -`
  for `showjobs` in the clone cookbook (stdin form checked, not against
  `showjobs`), the manual stop/start path without autostart.
- [ ] HTML parameter form with `AL32UTF8` umlauts
  ([test plan §9](04-ReportsFonts/HTML_ParameterForm_Fonts.md)).
- [ ] **RCU DB (`60-RCU-DB-19c`) after the review of 2026-11-02**: audit trail
  growth in the PDB checked 2026-11-10: `AUDITLOG` 85 of 100 MB (autoextend
  4 GB), 4–32 rows per normal day, peaks only on admin days (patch 6390, RCU
  work 262), archive timestamp job + 3 purge jobs working (180 days) – OK; `06-` / `09-Install/07-` on a
  PDB **before** RCU (registry missing – checked read-only in `CDB$ROOT`
  only); first customer run of the new `01-` "patch first, then install"
  route (live on the test host with `--target-home`); research why
  `runInstaller -applyRU` fails with "Invalid Home" on FMW hosts
  (AttachHome log, inventory permissions).

## Security hardening

- [ ] **Remaining non-loopback sockets** (2026-10-23 everything else is on
  `127.0.0.1`, SSL ports with the demo certificate are off – `08-`,
  `13-`, `02-Checks/clone_check.sh`): `frmweb` (no bind option – SR
  question to Oracle) and the Coherence cluster port + one port on the host
  IP (MOS 2420434.1 not read yet); the firewall closes them
  ([clone_golden_image.md](80-FMW-Architecture/clone_golden_image.md)).
- [ ] **EM "Add Principal" finds no users** – libOVD config overwritten by the
  Reports server; SR draft local (`SR/`) – the LibOVD BP 39726399 of CPU Oct
  2026 does not fix it (README read 2026-10-24). Workaround: "Advanced Option" /
  WLST `grantAppRole`
  ([em_principal_search_libovd.md](80-FMW-Architecture/em_principal_search_libovd.md)).
- [ ] **Idea: configuration security scanner** for WebLogic / Forms / Reports
  (T3/IIOP, debug configs, web commands, demo certificates …) –
  [10-Monitoring/README.md](10-Monitoring/README.md).
- [ ] **Clean-up of old patch artefacts** – partly done 2026-10-30:
  `07-Maintenance/patch_storage.sh clean` frees the ZIPs of finished steps,
  `patches_<timestamp>/` of `--fresh-patches` and staging leftovers;
  `check_disk_space.sh` lists `.patch_storage`, unlinked JDKs and old homes
  with the clean command. Open: the rollback copies themselves – external security scanners
  report vulnerable jars / libraries that only lie in rollback copies:
  `$ORACLE_HOME/.patch_storage/<patch>_<date>/` of superseded patches (e.g.
  the Sep PSU 39919611 / SPU 39988381 after CPU Oct 2026), `OPatch.bak_*`,
  `oraInventory.bak_*`, the previous JDK next to `JDK_HOME`
  (`jdk-21.0.12.1`), `patches_<timestamp>/` of `04- --fresh-patches`.
  Check first what Oracle supports for `.patch_storage` (`opatch util
  cleanup` / `opatch util deleteinactivepatches` – to verify for FMW 14.1.2
  and OPatch 13.9.4.2.25) instead of deleting by hand; keep the rollback
  copy of the **current** set until the next cycle is applied and tested;
  run only with the domain stopped and after a backup / VM snapshot.

## Scripts

- [ ] **FMW-bundled JDK** (`oracle_common/jdk` 17.0.12, OPatch component
  `oracle.jdk`, used by the Reports server/engines and the Forms/Reports
  tools): find the MOS patch number (`FMW_JDK_PATCH_NR` in
  `oracle_software_version.conf`), then download in `04-` and apply in
  `06-`/`82-`. The JDK at `JDK_HOME` is done (`80-patch_java_os.sh --apply`).
  State 2026-10-20: the Oracle Support AI knows no published patch and no
  Doc ID; it says "Do not manually replace that JDK directory" – only a MOS
  patch for component `oracle.jdk` / FMW 14.1.2 is supported, and points to
  the KA1182 / CPU October 2026 patch-availability rows. **State
  2026-10-22:** the KA1182 of October 2026 (PDF) has no patch for the
  bundled JDK (only Java SE for `JDK_HOME`). **State 2026-10-24:** Reports
  QPR Bug 37866660 ("alternative JAVA_HOME") is no way out (tools only, JDK 21
  not certified for Reports 14.1.2, `rwengine.sh` hard-codes
  `oracle_common/jdk`). **SR draft ready** (local `SR/sr_bundled_jdk17.txt`,
  incl. the FMW DBCLIENT question since 2026-10-26) – submit.
- [ ] **Trust-store check / sync script** (`08-SSL/`): central trust-anchor
  directory (customer root + intermediates, interception CA, local CA) →
  OS `anchors/` + `update-ca-trust`, server JDK `cacerts` as symlink to the
  OS-generated store (re-link after JDK updates) or `keytool` import,
  `NODE_EXTRA_CA_CERTS`; read-only check of presence, links, expiry, quality
  (SHA-1 / MD5) and interception – concept in
  [certificates_trust_stores.md §7 / §8](80-FMW-Architecture/certificates_trust_stores.md#7-centralising-the-java-trust-stores--options).
- [ ] **`maxRuntimeProcesses` / `engineResponseTimeOut` with real load**:
  both are proposals today (½ RAM / 64 MB per session; 30 min, measured
  longest job 1 s on the test host) – re-check with
  `06-FormsDiag/forms_perf_analyse.sh` and
  `05-ReportsPerformance/engine_perf_analyse.sh` at the first customer.

## APEX / ORDS beside Forms

- [ ] Remove the 32 KB stub `/u01/app/oracle/product/19.3.0` (left by
  `detachHome` of the already missing 19.3 home on 2026-11-10).
- [ ] APEX / ORDS follow-ups: `12-APEX-Ords/07-check-ords-apex-security.sh`
  (what applications bring in: open REST catalogs `auto_rest_auth`, workspace
  schema profile / tablespace, public REST modules, feature drift – see the
  12-APEX-Ords README §9); first real run of `03-patch-apex.sh` /
  `06-patch-ords.sh` upgrade; `clone_check` / `backup_config` (ORDS config +
  wallet) / `cve_inventory` for IC / SQLcl / ORDS / APEX; move `rcu_repository_check` etc. to `ihw_sqlplus`;
  the 8 `_run_root` copies in `09-Install` to the lib `ihw_run_root`.

## Monitoring (phase 9)

- [ ] **CSPU November 2026** (release 2026-11-17) = first real run of
  `10-Monitoring/patch_cycle_analysis.sh` (prepare → analyse --mode
  maintainer → live run → `update_plan.md` → `git tag`); check the
  registry of the skill doc against what really changed.
- [ ] **Claude sandbox rollout on the test host:** `IHW_ENV_TYPE=test`,
  `claude_setup_check.sh --profile maintainer --apply` → root: bubblewrap +
  socat, `/etc/claude-code/`; verify `/status`, guard ask/deny, `.des3`
  denied, curl `www.oracle.com` in the sandbox, `localhost` entries
  ([setup_claude.md](10-Monitoring/setup_claude.md)).
- [ ] **Proactive log analysis** on that sandbox (headless `claude -p`,
  read-only inputs, only the unusual entries – normal checks stay with
  Nagios / Prometheus); open: read-only mount of the production log dirs on
  the analysis host – to decide.
- [ ] **`cve_watch.sh` in daily operation:** `--cron --apply` on the test
  host; assess the open library findings of the baseline (jackson-databind /
  -core 2.16.1 in `jlib/` + `sqlcl/lib/`, jackson-core 2.21.5 in
  `oracle_common` – current Oracle copy –, httpcore5, OpenJPA 1.1.1, jline
  telnet in SQLcl) → `cve_accepted.txt` or SR / next CPU; at the customer:
  inventory on the server, watch on the share host (`--inventory`,
  `--state-dir`).
- [ ] CVE watch steps 3–4: notification, Claude assessment, uniform
  machine-readable output of the 01–07 scripts –
  [10-Monitoring/README.md](10-Monitoring/README.md).
- [ ] Notification for the cron checks (`cert_expiry_check.sh` writes to
  the journal `ihw-cert` today; mail / monitoring hook with the monitoring
  concept).

## Customer feedback / watch

- [ ] **Customer installation 2026-10-29/30 (OCI, no `*.oracle.com`, NFS/ZFS
  store):** first live runs of `07-Maintenance/patch_storage.sh` with a real
  `PATCH_ARCHIVE` on NFS, `check_disk_space.sh` with an NFS mount (must be
  listed as "not scanned"), `60-RCU-DB-19c/00-root_db_os_baseline.sh --apply`
  adding oracle to `dba` / `oper` (then re-login, `00b-`). Confirmed there:
  the run history file created by a root script belongs to the repository
  owner.
- [ ] **Next customer installation:** run `09-Install/04-oracle_pre_checks.sh`
  (check 10: does a blocked request fail fast or hang?) and
  `02-Checks/egress_check.sh --capture 300` during the first start – which
  components fetch external DTDs there
  ([weblogic_outbound_connections.md](80-FMW-Architecture/weblogic_outbound_connections.md)).
- [ ] **OAM external DTD (SR):** colleagues fill in OAM version / component /
  XML file + customer thread dump in the local SR draft
  (`SR/oam_external_dtd/`, reproducer without root included).

- [ ] **Linux Reports-only customer (cookbooks of 2026-11-03, not run yet):**
  CPU October 2026 run with `Patch_Kochbuch_CPU_Okt2026_de.txt` (starting
  level unknown; Forms QPR before Reports QPR with the `libzrc` check – decide
  on site), then `Reports_Absicherung_kochbuch_de.txt` (two full domain
  restarts) – feed findings back into the cookbooks.
- [ ] **Passwords in old `access.log` files** (library and docs on POST since
  2026-11-06): check customer hosts for `authid=` / `userid=` in
  `WLS_REPORTS/logs/access.log*` (and the Nginx access logs, root) and change
  the affected passwords. Test host done 2026-11-10: 56 lines (15.10.–03.11.,
  `DEV_STB`, `rep_admin`, `monUser`) removed with
  `03-Logs/cleanLogFiles.sh --retain-days 0 --include-out --apply` – passwords
  not changed (test host without customer data); Nginx logs not checked yet. First
  full `15- --apply` with the POST call (the function ran alone against the
  Reports server).
- [ ] **Node Manager warnings** "Uncaught exception in server handler"
  (`Connection reset` / `Broken pipe`) in `nodemanager.log` of a customer host,
  nearly all at second `:45`: the client is the AdminServer, the cause is open. The
  test host shows none of them. Compare the connection with `tcpdump`, read Doc ID
  1498013.1 (related, only seen as a search summary).
- [ ] **Home vs. domain** ([§7a](80-FMW-Architecture/weblogic_middleware_architecture.md)):
  read KB694158 (WLS PSU post-install); run the checklist for swapping a patched
  home live; first real domain start after `clean_domain_tmp.sh --apply` (so far
  dry run on the test host and `--apply` on an isolated copy).
- [ ] **Shell switcher at the customer**: copy the current
  `ihw_shell_env.sh` to `~/.bashrc.d/ihw_env.sh` (only ONE copy there) and run
  `ihwenv_configure -f`, so the home names, `(no SID)` lines and `t` appear;
  `07-db_sql_scripts.sh` there needs `github.com` on the egress allow-list
  (else `--archive`).
- [ ] **Scheduled reports**: mail notification (`destype=mail`,
  `notifysuccess`) untested – the mail server is still the template
  placeholder (`;` in `<write>` confirmed at the customer 2026-11-04).
  Doc section 7 of `80-FMW-Architecture/reports_job_handling.md` written
  2026-11-10 from Oracle docs + `rwrun.jar` code (host:port, `enableSSL`,
  STARTTLS only with login, `from=` / `sender`, `cgicmd.dat` key, debugging).
  Open live test with a relay: send, the success page, does `TRACE:32` show
  the mail values, is `mailPassword` encrypted at the restart.
- [ ] **14c move of a customer – export → analysis → import**
  ([process](09-Install/docs/00-transfer_customer_settings.md)). Way 2 ran live
  on 2026-11-05, Way 1 and the start page of `04-` as root by 2026-11-06. The
  systemd units wait for `/oracle` (reboot test with `critical-chain` OK). The
  closing report exists (2026-11-06): patch level green, security red only because
  `/console` and `/em` have no IP restriction. The customer stays on
  `ADMIN_IP_RANGE=any` by decision, its network has no clean separation; the red
  point is accepted for now. Open:
  - a fully green `apply_customer_conf.sh --apply` run (`15-` with PDF after
    the wait for the Reports servers);
  - slow Reports logins at the customer (1.6–2.6 s, test host 60 ms) –
    measure again after IPv6 off (`rwserver_status.sh`, "Avg auth time");
  - 12c report already sent: one false WARN ("same broadcast port", not
    security) – regenerate with analysis 2026-11-05.7 if it is sent again;
  - feedback of the customer on the reports and the decisions in
    `IMPORT_DECISIONS.md` (`SECTION_UNUSED`, `ENV_UNUSED`, `PATH_KEPT` –
    second module directory `bin_eg`), the customer start section / form for
    the FSAL shortcut (today `test_form`);
  - on the customer host: Carlito fonts, `FORMS_SIGN_TSA_URL`, recompile of
    the invalid RCU objects (since the RCU run of 2026-11-03), `server_tokens
    off`.
- [ ] **`status.sh --store-nm-key`**: first real run with the Node Manager
  password (only the error paths are tested). Open question left over: where
  `startComponent.sh … storeUserConfig` writes its files, which
  `Autostart_linux_middleware.txt` step 1c, `WLS_Report_start_stop_kochbuch.txt`
  and `Reports_kochbuch_de.txt` 9.10 describe as `~/oracle-WebLogic*.properties` –
  check once live. Seen 2026-11-10 at the Reports-only customer: `status.sh`
  read the keys from `~/.wlst/nm-cfg-<domain>.props` – set there as
  `WLST_CONFIG_FILE` in `patch_install.ini`, so not yet proof of Oracle's
  default path.
- [ ] **Customer clone (Reports only, 2026-11-10/11)** – source hardened and
  "Clone-capable: yes" since 2026-11-10 (`startup.properties` `AdminURL`,
  engine `jvmOptions`, emoms 3 files, `bin/*.sh`). Open on the clone (future
  production): the private `fix_localhost_kochbuch.txt` (same four places,
  EM green afterwards), then from the clone cookbook: result of `updateCred`
  `AuditDbPrincipalKey` (8.4), EM login by form, `showjobs queuetype=future`
  on clone (0) and source, host name of the clone vs. the intended name.
  Feed results into
  [FormsReports14_linux_clone](70-Customer-Projects/FormsReports14_linux_clone/README.md)
  and `clone_golden_image.md` §5 / §7.
- [ ] **Library template:** `09-Install/forms_templates/default.env.template`
  sets `FORMS_RESTRICT_ENTER_QUERY=FALSE` – Oracle's 14c template has TRUE
  (FALSE allows own SQL in Enter Query mode). Found by the analysis rule on the
  test host – decide and change.
- [ ] **Customer cookbook check**: does the graphical Configuration Wizard
  also create random Node Manager credentials? If yes,
  `Reports_kochbuch_de.txt` / `Autostart_linux_middleware.txt` need the same
  fix as `11-oracle_nodemanager.sh`.
- [ ] **Reports Builder Windows (customer, 2026-10-27):** start the Builder
  once with the own RCU database service stopped and run a preview – the
  tools runtime was measured without RCU use (`strace`), the Builder GUI not
  yet ([report_rwbuilder.md §3.2](80-FMW-Architecture/report_rwbuilder.md#32-what-the-builder-still-needs-at-runtime)).
- [ ] Customer installation 2026-10-15: which of the changes (firewall
  `14027/udp`, IPv6 per interface, multicast pre-check) fixed `REP-50600`
  there is not confirmed yet.
- [ ] **Watch MOS KB873815 / Bug 38892485** (Forms relink fails after a
  Reports QPR on OL9, `libzrc.so` vs. glibc 2.34): workaround in
  `06-oracle_patch_forms_reports.sh` stays until Oracle ships a fix.
- [ ] **Watch Bug 39868225 / MOS KB924687** (REP-50125 NullPointerException
  in `Utility.getOrbProperties` after Reports QPR 39600348): our
  `-DORBWaitForResponseTimeout` in `REPORTS_JVM_OPTIONS` (`13-`, since
  2026-10-15) is the documented workaround – keep it until a Reports QPR
  README lists 39868225 ([doc 13](09-Install/docs/13-reports-detail-settings.md)).
  KB text read 2026-11-10: it advises removing the option from `jvmOptions`
  "to avoid conflicts" – we keep it there with the same value (engine
  `jvmOptions` since 2026-11-10, running at the customer); drop it from
  `jvmOptions` if a later QPR shows a conflict
  ([report_engine_architecture.md §6](80-FMW-Architecture/report_engine_architecture.md)).
