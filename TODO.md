# IHateWeblogic – Open Items / TODO

Only what is still open (state 2026-11-10). Everything finished is described
in the folder READMEs, in [CHANGELOG.md](CHANGELOG.md) and in `git log`; the
review of 2026-10-19/20 is summarised in each README ("Review 2026-10-19").
Overview and status: [docs/project_status.md](docs/project_status.md#project-status).

## Oracle ACE submission – publication readiness (assessment 2026-11-10)

Assessment: idea very good, implementation and quality good (three customer
environments live), visuals good since the SVG diagrams, completion good for a
1.0 – **publication hygiene not yet** (items 0, 2, 3, 7). Worked off step by
step beside the customer work (state 2026-11-10). Order:

- [x] **0. Demo-data naming convention** – done 2026-11-11: test host = demo
  data, no masking – server `orafusion01` (`pipperr.local`), IP `10.10.10.124`,
  RCU DB `fmwpdb`, Reports domain `reportGPI`, everything with `gpi`; section
  [Demo Data](README.md#demo-data) in the README (CONTRIBUTING reuses it, item 7);
  examples in docs / cookbooks switched to these names.
- [x] **1. Git history** – decided 2026-11-10: stays as it is. Historic
  customer traces (domain name) are accepted by the customer; the only other trace is a host
  name in 2 old commit messages, and that server no longer exists. No secrets
  were ever committed. New files keep the customer-data rule.
- [x] **2. Disclaimer & Acknowledgements** – done 2026-11-11, at the end of the root README: not
  affiliated with / endorsed by Oracle, trademarks, use at own risk, personal
  logo; thanks to **Jürgen Menge** and **Mark Eichhorst** (IT-Macher,
  https://www.der-it-macher.de/) – also kept in `09-Install/README.md`.
- [x] **3. Compact root README – move, do not shorten** – done 2026-11-11:
  "Start here" block (what, for whom, 3 entry paths, list of the moved
  files); nine sections moved 1:1 into six files in [`docs/`](https://github.com/gpipperr/IHateWeblogic/tree/main/docs) (migration,
  project status, security & patch status, sizing + new memory / process
  table, installation steps, general security), one summary + link each,
  headings kept as stubs; line check: 0 lines lost (35 link lines adjusted
  to `../`); incoming anchors repointed; `## Troubleshooting` dissolved into
  02-Checks / 04 §11 / 05 / 06. README 1018 → ~640 lines.
- [x] **4. Release `v1.0.0`** with the tools ZIPs as assets, notes from
  CHANGELOG – done 2026-11-11: tag `v1.0.0` on `d1a1251`, GitHub release
  "Latest" with the two ZIPs of that tag + `.sha256` (checked with `gh`).
- [x] **5. `shellcheck` + `bash -n`** as a GitHub Actions gate – done 2026-11-11:
  `tools/ci_lint.sh` (bash -n on all 132 `*.sh` / `*.sh.template` + shellcheck
  `-S error` as the gate, `-S warning` report only) run by
  `.github/workflows/lint.yml` on push / PR; badge in the README. Local run
  (ShellCheck 0.10.0 from `ol9_developer_EPEL`, ~8 s): 0 errors after the fixes,
  79 warnings left (43 × SC2034 unused variable – many are read by sourced
  scripts, check one by one). Open: confirm the first CI run (runner has 0.9.0).
- [ ] **6. Showcase** (`status.sh`, `clone_check`, analysis PDF page, smoke
  test) + blog article on pipperr.de linked both ways.
- [x] **7. `CONTRIBUTING.md`** (conventions, customer-data rule, how to report
  a finding); customer-data scan as a pre-commit hook – done 2026-11-11:
  `CONTRIBUTING.md` (issues welcome, PRs after agreement in an issue),
  issue template "Finding", `tools/hooks/pre-commit` + `install.sh`
  (customer names from the local `~/.config/ihw/customer_patterns`, forbidden
  files, secrets, private IPs, `bash -n`, stale customer ZIPs; 19 test cases).
- [ ] **8. Reviewer-visible test gaps:** fresh domain with the current `08-`
  template, `clone_check.sh --apply` file places on a real domain,
  `REPORTS_ONLY` domain creation.
- [x] 9. Optional: `render_ascii` checked in, `?v=` cache-busting for SVGs –
  done 2026-11-11: [`tools/render_ascii/`](https://github.com/gpipperr/IHateWeblogic/blob/main/tools/render_ascii/README.md) in git (README in English),
  all 32 image links carry `?v=<SVG hash>`, "Source:" / "ASCII version"; diagram texts
  checked – `builder-windows` translated to English, Target Picture ORDS 26.3.

## GitHub Pages – docs as a linked website (started 2026-11-12)

Spec: `90-Source-MetaData/prompt_ihw_pages_verlinkung.md` (local), plan steps 1–7;
tool: `tools/check_pages_links.py`. Done (`c95949c`): link checker, 2 broken
anchors, `TODO.md` / `tools/` / folder links + 84 raw-file links -> GitHub view,
render_ascii source links absolute, `code` links sample in `09-Install/README.md`
+ `00-Setup/README.md`, root README folder column. Rules: `.md` links relative,
code / raw files -> `github.com/…/blob/main/`, no Liquid in Markdown, no rewording.

- [x] **Step 4 – rest:** done 2026-11-12 – `--link-code --apply` folder by folder
  (07-Maintenance `9b716d7`, then 23 groups up to 09-Install `402f121`): 1,395 code
  mentions linked in 108 files, per folder: all targets exist, only link brackets
  added (text with the links removed is identical), checker 0, customer ZIPs
  rebuilt with `70-Customer-Projects/tools`; dry run afterwards: 0 links left.
- [x] **Step 5 – navigation** – done 2026-11-12 (`07b9aec`): own `_layouts/default.html`
  in the style of www.pipperr.de (header with logo + section, breadcrumb – folder
  link only with README –, menu column, "This page on GitHub", footer "Made by"),
  Cayman CSS kept for the content, `assets/css/ihw.css` on top. Found by the live
  check and fixed: ASCII `<details>` blocks swallowed the rest of 12 pages
  (kramdown: no fence after ```` ```ascii name= ````, `<placeholder>` as HTML) →
  `<details markdown="block">` + ```` ```ascii?name=<n> ````, render_ascii writes
  this form (`3485c0b`); 240 bare URLs in 40 files were plain text on Pages →
  `<https://…>` (`8900443`). Live check: 0 findings (2,344 links, 119 pages).
- [ ] **Step 6 – front matter:** proposal list `title` (≤ 70) / `description`
  (150–160) for the module READMEs `00`–`08`, `12`, `60`, `70` (+ `permalink:
  /<folder>/`) and all `09-Install/docs/*.md` – show first, enter after OK;
  `SKILL.md` untouched.
- [ ] **Step 7 – close:** checker locally 0, `ci_lint.sh` green; after Gunther's
  push: `gh run watch` (pages build), `check_pages_links.py --live`, folder
  addresses `/`, `/09-Install/`, `/80-FMW-Architecture/`, `/10-Monitoring/` +
  new permalinks -> HTTP 200, menu / breadcrumb spot check.

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

- [ ] **Brotli CVE-2026-111497** – OS fix and Reports server restart done
  on the test host (2026-11-10/11, no process maps the old lib after the
  reboot) and on the customer hosts. Left: the old Claude Code npm CLI 2.1.287
  on Node 20 (EOL, bundled Brotli 1.1.0) on the test host – as root
  `npm uninstall -g @anthropic-ai/claude-code`, then remove or upgrade the
  nodesource Node 20 (the VS Code session uses the native binary) –
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
- [ ] **Check `opatch util deleteinactivepatches`** for FMW 14.1.2 / OPatch
  13.9.4.2.25: removes the rollback copies of superseded patches in
  `$ORACLE_HOME/.patch_storage` (scanners report old jars there) – supported
  for FMW? Test on a home copy / with the domain stopped and a snapshot; then
  add it to `07-Maintenance/patch_storage.sh` / `check_disk_space.sh` beside
  `opatch util cleanup`.

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
  both are proposals today (½ RAM / 64 MB per session; 360 min safety net since
  2026-11-10 (before 30), measured
  longest job 1 s on the test host) – re-check with
  `06-FormsDiag/forms_perf_analyse.sh` and
  `05-ReportsPerformance/engine_perf_analyse.sh` at the first customer.

## APEX / ORDS beside Forms

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

## Watch / generic follow-ups

Customer-specific follow-ups (customer hosts, customer runs, customer
feedback) are kept locally in `70-Customer-Projects/customer-analyse/TODO.md`
(not in the repository, git-ignored).

- [ ] **Next customer installation:** run `09-Install/04-oracle_pre_checks.sh`
  (check 10: does a blocked request fail fast or hang?) and
  `02-Checks/egress_check.sh --capture 300` during the first start – which
  components fetch external DTDs there
  ([weblogic_outbound_connections.md](80-FMW-Architecture/weblogic_outbound_connections.md)).
- [ ] **Home vs. domain** ([§7a](80-FMW-Architecture/weblogic_middleware_architecture.md)):
  read KB694158 (WLS PSU post-install); run the checklist for swapping a patched
  home live; first real domain start after `clean_domain_tmp.sh --apply` (so far
  dry run on the test host and `--apply` on an isolated copy).
- [ ] **Reports mail** ([reports_mail_handling.md](80-FMW-Architecture/reports_mail_handling.md),
  own article since 2026-11-11): notifications **live-tested 2026-11-11** with a
  local SMTP sink (`notifyfailure` / `notifysuccess`, sender, own note files,
  `notifyfailure` in `cgicmd.dat` keys for a ticket system – key wins, `retry="3"`
  = 4 mails). Open with a real relay: `destype=mail` (report as attachment) and
  its success page, login / STARTTLS / SMTPS, does `TRACE:32` show the mail
  values, is `mailPassword` encrypted at the restart, umlauts in an own note
  file. (`retry` / `JOBRETRY` and `reloadkeymap` live-tested 2026-11-11 –
  [reports_rwservlet_properties.md](80-FMW-Architecture/reports_rwservlet_properties.md).)
- [ ] **`status.sh --store-nm-key`**: first real run with the Node Manager
  password (only the error paths are tested). Open question left over: where
  `startComponent.sh … storeUserConfig` writes its files, which
  `Autostart_linux_middleware.txt` step 1c, `WLS_Report_start_stop_kochbuch.txt`
  and `Reports_kochbuch_de.txt` 9.10 describe as `~/oracle-WebLogic*.properties` –
  check once live. Seen 2026-11-10 at the Reports-only customer: `status.sh`
  read the keys from `~/.wlst/nm-cfg-<domain>.props` – set there as
  `WLST_CONFIG_FILE` in `patch_install.ini`, so not yet proof of Oracle's
  default path.
- [ ] **Library template:** `09-Install/forms_templates/default.env.template`
  sets `FORMS_RESTRICT_ENTER_QUERY=FALSE` – Oracle's 14c template has TRUE
  (FALSE allows own SQL in Enter Query mode). Found by the analysis rule on the
  test host – decide and change.
- [ ] **Customer cookbook check**: does the graphical Configuration Wizard
  also create random Node Manager credentials? If yes,
  `Reports_kochbuch_de.txt` / `Autostart_linux_middleware.txt` need the same
  fix as `11-oracle_nodemanager.sh`.
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
  ([reports_engine_architecture.md §6](80-FMW-Architecture/reports_engine_architecture.md)).
