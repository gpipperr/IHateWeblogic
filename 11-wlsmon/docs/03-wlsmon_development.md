---
nav_title: "wlsmon development plan"
title: "wlsmon – Development Plan: Implementation Steps P1 to P3"
description: "Development plan of the wlsmon runtime monitor for Oracle Forms & Reports 14.1.2: ordered implementation steps from the JSON contract and the GUI of the prototype over the python3 collector to the installation scripts – each step with files, reuse from the repository and a done criterion."
---

# wlsmon – development plan

← [11-wlsmon](../README.md) · [concept](01-wlsmon_concept.md) ·
[interface design](02-wlsmon_interface_design.md)

**State 2026-11-19 evening: steps 0–8 implemented** (code in the repository,
46 unit tests green, nothing installed on the test host). Open in them: the
browser checks of steps 2–4 and the REST verification of 6b – both need
Gunther (section 9). This document is the master for the **build order**. Two other documents are the master for the
**content**:
- the concept (what is built);
- the interface design (how it looks).

If a step finds that the concept is wrong (for example a REST field name),
the concept is corrected first, then the code.

## 1. Ground rules of the development

**Order: contract and GUI first, then the collector, installation last.**
- The prototype already shows every page with sample data.
- The collector is written against the same JSON contract. It is done when
  the GUI shows its output without any change to the GUI.
- The installation scripts come last, when program and GUI are stable.

**Every step:**
- ends testable, with its done criterion from the tables below;
- leaves the test host unchanged until step 10. Steps 0–9 work in the
  repository, in a scratch directory and with read-only calls;
- runs `--apply` tests first in an isolated copy (absolute paths, `cd`
  check, fake `sudo`); a live `--apply` on the test host only with Gunther's
  approval;
- checks `free -h` before native Oracle processes are started (the sandbox
  saw a real OOM kill of `WLS_REPORTS`).

**Code rules:**
- **Python:**
  - `wlsmon.py` uses the standard library only and is 3.6-compatible (OL8):
    no dataclasses, no `:=`, no `match`, no `X | Y` type hints, no
    f-string `=`;
  - the lint gate checks this with
    `ast.parse(source, feature_version=(3, 6))` (step 0).
- **Bash:** the three install scripts follow the library standards of
  `CLAUDE.md`:
  - `--apply`;
  - backup before every change;
  - `ok` / `warn` / `fail`;
  - `print_summary`;
  - `bash -n` and shellcheck through `tools/ci_lint.sh`.
- **JavaScript:** the security rules of the prototype stay:
  - no `innerHTML`, no `eval`, no inline code;
  - values only through `textContent`;
  - levels only from a whitelist.
- **Test data:**
  - only demo names (`orafusion01.pipperr.local`, `fr_domain`,
    `repserver01`);
  - no customer data, not even as a fixture.

**GUI technology – decision 2026-11-19:**
- **Oracle JET only for the charts:** `ojchart` + `ojarraydataprovider` +
  the theme `oj-redwood-notag-min.css` from `/i/`.
- **Everything else stays the prototype's own HTML / CSS:**
  - layout, tiles, topology;
  - tabs (WAI-ARIA);
  - tables, filters and badges.
- **Not used:** `oj-tab-bar`, `oj-table`, `oj-select-single` and the other
  JET Cookbook components.
- **Reasons:**
  - the full Redwood theme would cover our own look (interface design);
  - without a build chain JET means MVVM with Knockout, and the VDOM
    variant needs node / npm – both against concept §2.1;
  - every further component is one more thing an APEX update can break
    (20.1.4 already has no `oj-spark-chart` any more);
  - the prototype code stays usable.
- **Fallback:** if JET does not load, the prototype's own SVG draws the
  charts.

## 2. Source material: the prototype v3

The prototype is `90-Source-MetaData/wlsmon/wlsmon-claude-code_3.zip`. It is
local and not in git. Contents:
- `www/`:
  - `index.html` + `js/overview.js`: the overview, grouped by product, with
    an environment filter and a search;
  - `host.html` + `js/wlsmon.js`: the host view with refresh countdown,
    traffic light, the tabs Overview / Patch level / Security / Log viewer,
    the components as a topology and the key figures per component block;
  - `css/wlsmon.css`, `img/ihw_logo.png`;
- `tools/gen_sample_data.py` with the scenarios normal / warn / crit /
  nginxdown / stale / rcu;
- its `PLAN.md` and screenshots.

What moves into the repository:

| From the prototype | Into the repository | Adaptation |
|---|---|---|
| `www/index.html`, `www/host.html`, `js/overview.js`, `js/wlsmon.js`, `css/wlsmon.css` | `11-wlsmon/www/` | icons → font-apex (inline SVG stays as fallback); charts through `js/wlsmon_charts.js` (step 4); footer texts updated |
| `img/ihw_logo.png` | `11-wlsmon/www/img/` | unchanged (project logo) |
| `tools/gen_sample_data.py` | `11-wlsmon/tools/` | writes only into a given directory (`--out`), never into `www/` of the repository |
| demo mode (`#demo-<scenario>`, `demo_reference`) | stays in the GUI | the Nginx whitelist answers `api/demo/` with 404; the collector never writes `demo_reference` |
| `PLAN.md`, screenshots | stay local | history only – concept §3.5 has taken over all fields |

## 3. Phase P1 – one host (GUI and data role)

Overview of the steps; the details follow the table.

| # | Step | Result |
|---|---|---|
| 0 | Skeleton and lint gate | folder tree, Python check in the gate – **done** |
| 1 | Freeze the contract | sample data + `check_contract.py` – **done** |
| 2 | Import the GUI | `www/` runs on sample data – **done**, live in the browser 2026-11-20 |
| 3 | JET spike | proof: `oj-chart` under the strict CSP – **passed** 2026-11-20 (incl. tooltips) |
| 4 | Chart layer | `wlsmon_charts.js` (JET + SVG fallback) – **done** |
| 5 | `wlsmon.py` frame | subcommands, config, credentials, atomic writes – **done** |
| 6a–6j | Collector parts | one source per part, each with fixtures – **done** (6h code done, off) |
| 7 | Build | levels, topology, rollups, the 7 files – **done** |
| 8 | Templates | `wlsmon.conf`, systemd, Nginx – **done** |
| 9 | `00-setup-interview.sh` | `wlsmon.conf` + secrets to `etc/pending/` – **done 2026-11-20** |
| 10 | `01-install-wlsmon_fmw.sh` | program, GUI, `ui.json`, monitor user – **live 2026-11-20** |
| 11 | `02-install-wlsmon_root.sh` | group, systemd, Nginx, credentials, timers – **live 2026-11-20** |
| 12 | Test on the test host | security, CSP, 24-h run, resources – **running** (24-h evaluation 2026-11-21) |
| 13 | Integration | backup category, docs, `--remove` – open (docs: operations page 04 done 2026-11-20) |

### Step 0 – skeleton and lint gate

- Create the folder tree of concept §9.2: `www/`, `rules/`, `templates/`,
  `tools/`, `tests/` (with `tests/fixtures/`).
- `tools/ci_lint.sh` gets a Python part for `11-wlsmon/**/*.py`:
  1. `python3 -m py_compile`;
  2. the 3.6 check with `ast.parse(..., feature_version=(3, 6))`;
  3. `python3 -I -m unittest discover 11-wlsmon/tests`.
- **Done when:** the gate is green on the empty skeleton, locally and in
  GitHub Actions.

### Step 1 – freeze the contract

- **Sample data:** take over `tools/gen_sample_data.py`; all scenarios plus
  `--all-scenarios` (demo `hosts.json`).
- **New: `tools/check_contract.py`** (stdlib) checks a directory with the
  7 files, plus `hosts.json` if it is there:
  - required keys of concept §3.1 / §3.5, `schema == 1`;
  - `level` only `ok | warn | crit`;
  - every series has as many values as `ts`;
  - `requires` and `parent` point to existing component ids;
  - `layout.stages` names every component except the host;
  - every metric `group` is listed in `layout.metric_groups`;
  - `logs.json` has no field that could carry a raw log line (only the
    short `text` per code);
  - `value` is a number, never a formatted string.
- **Done when:**
  - every prototype scenario passes;
  - a test with a broken sample (wrong level, a series too short) fails;
  - from step 7 on, the same checker validates the real output.

### Step 2 – import the GUI

- Copy `www/` of the prototype into `11-wlsmon/www/`.
- **Icons:** font-apex classes (`fa-check-circle`,
  `fa-exclamation-triangle`, `fa-times-circle`, `fa-clock-o`). The path comes
  from `ui.json`; if the font does not load, the inline SVG stays.
- **`ui.json` (repository default):** `locale` only. `01-install-wlsmon_fmw.sh`
  adds the library paths (step 10).
- Check footer and help texts: refresh 5 min, the 7 files.
- **Done when:**
  - `gen_sample_data.py --all-scenarios --out <scratch>/api` and
    `python3 -m http.server` show every scenario and the overview as in the
    screenshots, in light and dark mode;
  - the browser console shows no CSP or JavaScript error (local test with
    the CSP header of concept §6 through a small test server in `tools/`).

### Step 3 – JET spike (CSP proof)

This step decides steps 4 and 12. It is a local test page and is not
shipped.
- **Test page `tools/jet_probe.html`**, served by the test server under the
  same origin as `/i/`.
- **Loading:**
  - RequireJS from `/i/libraries/oraclejet/<ver>/js/libs/require/require.js`;
  - the modules `ojs/ojchart` and `ojs/ojarraydataprovider` from
    `js/libs/oj/<ver>/min/`.
- **No Knockout, no binding expressions:** the properties are set from
  JavaScript (`chart.data = new ArrayDataProvider(...)`, `chart.series`,
  `chart.referenceObjects`).
- **Theme:** `css/libs/oj/<ver>/redwood/oj-redwood-notag-min.css`. Its
  rules carry no tag selectors, so it does not restyle our page.
- **Charts to build:**
  - a line chart day / week / year with two series;
  - threshold lines as `referenceObjects`;
  - a sparkline. 20.1.4 has no `oj-spark-chart`, so the sparkline is an
    `oj-chart` line without axes, legend and grid.
- **Colours:** series and thresholds come from the CSS tokens
  (`getComputedStyle`, interface design §4). A theme switch repaints.
- **Under the strict CSP of concept §6:**
  - the console shows no violation;
  - `style-src 'unsafe-inline'` only if `oj-chart` needs it – measured,
    with the reason documented;
  - `script-src` never gets `unsafe-eval`.
- **Measure:** bytes loaded and time to the first chart (cold cache).
- **Result:**
  - go → step 4;
  - no-go → back to Gunther with the measured reason. The SVG renderer of
    the prototype is there either way.

Found on the test host (2026-11-19):
- APEX 26.2 patch set, `/i/` → `/srv/apex/apex_1`;
- JET `20.1.4` with `ojchart`, `ojarraydataprovider`,
  `ojcspexpressionevaluator` and `oj-redwood-notag`;
- font-apex up to `2.5.1` plus `latest`.

### Step 4 – chart layer

- **New: `www/js/wlsmon_charts.js`**, one interface for both renderers:
  - `line(el, spec)` – series, thresholds, time axis;
  - `spark(el, spec)`;
  - `spec` holds the values, series ids, colour token names and
    thresholds.
- **Renderers:**
  - JET (from the spike) is the default;
  - the SVG code of the prototype moves here as the fallback;
  - the choice is made once at page load: `ui.json` has a JET path and
    RequireJS loads.
- `wlsmon.js` calls only this layer – no chart code left in the page logic.
- **Done when:**
  - all scenarios show JET charts;
  - with the JET path renamed (test server), the SVG fallback shows the
    same data;
  - the theme switch repaints;
  - tooltips show values in the locale of `ui.json`.

### Step 5 – frame of `wlsmon.py`

- **Subcommands:**
  - `collect` – one round;
  - `collect --check` – a dry run with every source, prints instead of
    writing;
  - `pull` – P2, until then only parsed;
  - `rules --test <logfile>` – hits per rule id for one log;
  - `version`.
- **Config:** `$WLSMON_BASE/etc/wlsmon.conf` (KEY=value, comments with
  `#`). Defaults live in the program; unknown keys are reported in
  `collector.errors`.
- **Secrets:**
  - read from `$CREDENTIALS_DIRECTORY/<name>`;
  - OL8 fallback: a file with mode 400 below `etc/creds/`;
  - never from argv or the environment;
  - never in logs.
- **Writing:** `tempfile` in the target directory, then `os.replace` (atomic).
  `state/` holds offsets, counters, pause stamps and schedule stamps.
- **Testability:** `WLSMON_TEST_ROOT` puts a prefix before `/proc`, `/sys`
  and the log paths, so every source part runs on fixtures.
- **Done when:** unit tests for config parsing, the credentials lookup and
  the atomic write pass; the 3.6 check is green.

### Step 6 – collector parts

One part per source. Each part:
- returns components, metrics, series values and errors;
- never raises out of the round – an error becomes a `collector.errors`
  entry and the part's components become `stale` / `n/a`;
- has fixture tests in `tests/fixtures/<part>/`.

| # | Part | Source (concept §4.1) | Reuses | Done when |
|---|---|---|---|---|
| 6a | Host | `btime` from `/proc/stat` (uptime), `/proc/loadavg`, `os.cpu_count()`, CPU % from the `/proc/stat` delta between two runs (iowait, steal; counters in `state/`), `/proc/meminfo`, `shutil.disk_usage` of the configured list incl. the core directory | – | fixtures incl. the first run without counters (CPU `n/a`) |
| 6b | WebLogic REST | first a **read-only verification** of the field names on 14.1.2 with curl (search POST of concept §4), saved as a fixture; then one search POST + the expected server list from `domainConfig/servers`; heap, stuck / hogging threads, JDBC data sources; HTTP 401 → pause in `state/` (lockout 3/30/15); AdminServer down → `/weblogic/ready` per server + port check | `70-Customer-Projects/tools/bash/status.sh` (ready probe), `01-Run/startStop.sh` (`_port_listening`) | fixtures for 200, 401 and AdminServer down |
| 6c | Reports | getserverinfo POST (all parameters in the body) per server of `WLSMON_REPORTS_SERVERS` with `monUser`; engines busy / idle, queue, failed jobs; status codes `0` dead / `1` idle / `2` busy | `01-Run/reports_server_lib.sh` (`rws_fetch_serverinfo`, `rws_http_verdict`), XML fields of `01-Run/rwserver_status.sh` | XML fixtures incl. HTTP error and an empty engine list |
| 6d | Forms | `frmweb` processes from `/proc/<pid>/cmdline` + `ss` (a runtime with a client connection = session), prestart pool | rule of `06-FormsDiag/forms_perf_analyse.sh` | fixtures |
| 6e | nginx | running (pid file / `/proc`), requests per minute with 5xx / 4xx from the access log since the last offset, `error.log` entries | offset logic of 6f | fixtures incl. rotation |
| 6f | Logs and rules | offsets per inode in `state/` (rotation = start again); entry parser for `####<`; rules file of concept §4.3 – `ignore` first, an ignore rule without a reason is not loaded, a broken regex → `collector.errors`; counts per component; 24-h window of events per code in `state/` → `logs.json`; first content of `rules/wlsmon_rules.cfg` | patterns of `70-Customer-Projects/tools/bash/show_errors.sh` | `wlsmon.py rules --test` on copies of the test-host logs gives the ignore list proposal for Gunther |
| 6g | Core dumps | `kernel.core_pattern`; a pattern starting with `\|` → `coredumpctl list --since`; else new files in the directory; `hs_err_pid*.log` in the domain | values of `09-Install/01-root_os_baseline.sh` | fixtures for both pattern kinds |
| 6h | Database / RCU | JDBC state from 6b; hourly: account status and expiry of the RCU schemas from `DBA_USERS` through `sqlplus` of the F&R home, connect data from the STB data source (`jdbc/*.xml`); behind `WLSMON_RCU_CHECK=false` until the DB monitor user is agreed | domain `jdbc/*.xml` | fixtures; live only after agreement with the DBA |
| 6i | Daily facts, patch level | `patch.json` from the inventory files (no OPatch JVM), baseline from `WLSMON_PATCH_BASELINE`; days until the next certificate expiry (`openssl x509 -enddate`); Derby running; GUI library paths of `ui.json` still there | `10-Monitoring/cve_inventory.sh`, `10-Monitoring/cert_expiry_check.sh`, facts of `70-Customer-Projects/tools/bash/collect_fmw_env.sh` | fixtures; compared once by hand with `opatch lspatches` |
| 6j | Security checks (hourly) | `security.json` with the checks of concept §3.5 | `80-FMW-Architecture/security_overview.md`, `02-Checks/domain_secret_check.sh` | fixtures; every check has a hint text |

### Step 7 – build

- **Levels:** thresholds of concept §4.2 as `WLSMON_*` keys with defaults;
  each metric gets its level, and each block gets the worst level of its
  metrics.
- **Topology (concept §3.5):**
  - only DOWN propagates;
  - components behind a DOWN one (`requires`, `parent`) become *blocked*
    (crit, "blocked by …");
  - only the root cause becomes a reason ("nginx: not running · blocks …");
  - AdminServer and Node Manager block nothing by default.
- **`now.json`:** overall level and reasons (worst first, at most a few),
  `collector`, `layout`, `daily`.
- **Series and rollups (concept §8):**
  - `day.json`: ring of 288 points;
  - `week.json`: maximum per hour, sum for errors / dumps / jobs, minimum
    for free memory;
  - `history.json`: per 12 h the same rules plus the worst level;
  - hourly and daily parts (6h, 6i, 6j) run inside the 5-minute round when
    their stamp in `state/` is due – one timer only.
- **Writing:** the 7 files atomically, `api/` last; the round's duration
  goes to `collector.duration_ms`.
- **Done when:**
  - synthetic time series (2 days of rounds in the test) give the expected
    rollups;
  - the topology tests cover the scenarios nginxdown and WLS_REPORTS failed;
  - `check_contract.py` is green on real `collect --check` output from the
    test host.

### Step 8 – templates

- `templates/wlsmon.conf.template`: all keys with comments and defaults.
- systemd templates with the limits and sandboxing of concept §5:
  - `wlsmon-collect.service` + `.timer`;
  - `wlsmon-pull.service` + `.timer` (P2, already in the template).
- `templates/wlsmon-nginx.conf.template`:
  - blocks `#@WLSMON_GUI_BEGIN@` / `#@WLSMON_DATA_BEGIN@`;
  - the headers include in every location;
  - a whitelist regex for the 7 files and `hosts.json`;
  - `api/demo/` → 404;
  - `limit_except GET`;
  - `/i/` reused from the APEX include when it is there.
- `templates/wlsmon_zone.conf` (`limit_req_zone`, http context).
- Rendering with **one** renderer, `tools/render_template.py` (used by the
  three install scripts and the tests): `##VARIABLE##`, marker blocks, and a
  list variable like `ADMIN_IP_RANGE` (one `allow` line per network, `any`
  removes the line and its `deny all;`) – the rules of
  `09-Install/04-root_nginx.sh`; SELinux / include pattern of
  `12-APEX-Ords/05-setup-nginx.sh`.
- **Done when:**
  - the render test in a scratch directory produces both roles;
  - `nginx -t` passes against a copy of the configuration;
  - `systemd-analyze verify` passes on the rendered units.

### Step 9 – `00-setup-interview.sh`

- Content as concept §9.2: defaults from an existing `wlsmon.conf`, then
  `environment.conf` (via `detect_env_conf` when the library is there), then
  the built-in defaults.
- Secrets:
  - monitor password generated at random (password rule, 12 characters);
  - `monUser` asked hidden and twice;
  - pull password generated, its hash shown;
  - written to `etc/pending/` (700 / 600);
  - `--secret <name>` changes only that secret.
- **Done when:**
  - without `--apply` it shows the `wlsmon.conf` diff;
  - `--apply` in an isolated copy writes only below `etc/`;
  - a second run offers the last answers.

### Step 10 – `01-install-wlsmon_fmw.sh`

- Copies `bin/wlsmon.py`, `share/wlsmon_rules.cfg`, `www/`; creates the
  `etc/wlsmon_rules.local.cfg` skeleton (never overwritten).
- `ui.json`:
  - `WLSMON_LOCALE`;
  - the newest JET and font-apex version directories below the active
    `APEX_WEB_DIR/apex_N`, as `/i/` paths;
  - without APEX: the `images/` folder of the APEX ZIP to
    `$WLSMON_BASE/www/i/` (concept §7).
- **WebLogic monitor user** (group Monitors only):
  - a one-time REST call with the admin password (asked, memory only; or
    from the library);
  - the REST `createUser` path is verified here first, read-only, before
    any write.
- Checks the Reports `monUser`; ends with `wlsmon.py collect --check`.
- **Done when:**
  - the isolated test is green;
  - the live run on the test host (with approval) creates the user, and
    `collect --check` shows every part.

### Step 11 – `02-install-wlsmon_root.sh`

- Content as concept §9.2:
  - group `wlsmon`;
  - setgid on `www/`, `api/`, `hosts/`;
  - traverse ACLs on the parent directories if they are 750;
  - SELinux context;
  - units, timers and the Nginx include from the templates of step 8;
  - `htpasswd` files with `openssl passwd -6`;
  - `etc/pending/` → `etc/creds/*.cred` (`systemd-creds encrypt`), then the
    clear text is deleted;
  - `nginx -t` + reload;
  - the timers enabled;
  - a first run with `systemctl start` and its result.
- Pattern for root parts and units: `09-Install/30-configure_autostart.sh`,
  `09-Install/04-root_nginx.sh`.
- **Done when:**
  - the isolated test (fake `sudo`, rendered files only) is green;
  - the live run (with approval) ends with a green first round.

### Step 12 – test on the test host

- **Access** (concept §6):
  - `curl` without login → 401;
  - with login → 200;
  - `POST` → 403;
  - `api/.tmp_x.json` and `api/demo/…` → 404;
  - `/management` and `/console` are not routed.
- **Browser:** both pages without CSP violations, JET charts visible, the
  SVG fallback checked once.
- **Load:**
  - 24 h of rounds;
  - `collector.duration_ms` over the day;
  - CPU and memory of the unit (`systemd-cgtop`, `MemoryMax`);
  - no effect on the WebLogic heap or threads.
- **Failure cases:** with fixtures. Stopping a real component only with
  Gunther's approval.
- **Thresholds:** compare the proposals of concept §4.2 with the 24-h real
  values and adjust the defaults.
- **Done when:** the results are written into this section (date, values).

### Step 13 – integration

- `07-Maintenance/backup_config.sh`: new category `wlsmon`
  (`$WLSMON_BASE/etc` without `pending/` and `creds/`).
- `--remove` of both install scripts tested in reverse order (isolated, then
  live with approval).
- Update `README.md` of the folder (state), `CHANGELOG.md`, `TODO.md`.
- **Done when:** `python3 tools/check_pages_links.py` reports 0 findings,
  and the customer-name scan is clean.

## 4. Phase P2 – one GUI host, many data hosts

| # | Step | Content | Done when |
|---|---|---|---|
| P2.1 | `wlsmon.py pull` | per data host a fetch of the 7 files with its own timeout; TLS verified against `WLSMON_PULL_CAFILE` (never without verification); pull user from the credential; keeps the last copy on error; writes `hosts.json` (concept §3.2) | unit tests with a local HTTPS test server and a test CA |
| P2.2 | GUI role | overview page on live `hosts.json`; STALE computed in the browser from each host's `generated_at` | a host whose pull fails turns grey while `hosts.json` is fresh |
| P2.3 | Data role | template block DATA: `allow <IP of A>`, shared pull hash from the interview, no GUI | access test: A gets 200, any other IP 403 |
| P2.4 | Test | first a second data host simulated on the test host (data role under a second server name over loopback, HTTPS against the internal CA); later a real second host | two tiles, drill-down to both hosts |

## 5. Phase P3 – optional

- The three install scripts and the runtime go into the customer tools ZIP
  (`70-Customer-Projects/tools/make_customer_zip.sh`). The runtime needs no
  library anyway.
- Notes for PRTG / Nagios: how to read `now.json` (overall level, age).

## 6. Dependencies

```
1 → 2 → 3 → 4                     (contract, GUI, charts)
1 → 5 → 6a … 6j → 7               (program, may run in parallel to 2–4)
4 + 7 → 8 → 9 → 10 → 11 → 12 → 13 (installation and test)
13 → P2.1 → P2.2 / P2.3 → P2.4
```

## 7. Open points and the step that answers them

| Open point (concept §11) | Answered in |
|---|---|
| REST field names on 14.1.2 | 6b – **verified 2026-11-20**, [weblogic_rest_monitoring.md](../../80-FMW-Architecture/weblogic_rest_monitoring.md) |
| REST `createUser` for the monitor user | 10 |
| JET without Knockout under the strict CSP | 3 |
| `sqlplus` in every F&R home, DB monitor user for the RCU check | 6h (agreement with the DBA per customer) |
| Thresholds for Forms sessions / Reports queue | 7 (defaults), 12 (real values) |
| Allowed networks | 9 (interview question) |
| Monitor user on customer domains | per customer, before 10 |

## 8. Test strategy

- **Unit tests** (`tests/`, stdlib `unittest`): every collector part runs on
  fixtures through `WLSMON_TEST_ROOT`, without WebLogic, Reports or Nginx.
- **Contract test:** `tools/check_contract.py` checks:
  - the sample data (step 1);
  - the real output of `collect --check` (step 7);
  - the pulled data on A (P2).
- **GUI test:** sample scenarios through the local test server with the CSP
  header of the production Nginx.
- **Install tests:** first isolated (fake `sudo`, scratch target), live only
  with approval.
- **Fixtures:**
  - only sanitised demo data;
  - real test-host output only after replacing host, domain and user names
    with the demo set.

## 9. Progress log

### 2026-11-19 – steps 0 to 8

| Step | State | Result / finding |
|---|---|---|
| 0 | done | `tools/ci_lint.sh` step P (py_compile, Python 3.6 syntax via `tools/py36_check.py`, unittest) and step J (ES5 syntax of `www/js` via Nashorn, `11-wlsmon/tools/js_syntax_check.sh` – skipped without a `jjs`). Python 3.9's parser does not enforce `feature_version` for everything, so `py36_check.py` walks the AST itself (walrus, positional-only, `X \| Y`, `capture_output=`, `fromisoformat` …) |
| 1 | done | `tools/gen_sample_data.py` (from the prototype, `--out` mandatory), `tools/check_contract.py` – all 6 scenarios + demo `hosts.json` pass, 10 negative tests fail as they should |
| 2 | done, **live in the browser 2026-11-20** (overview + host view on the test host) | `www/` from the prototype v3; icons through `js/wlsmon_libs.js` (font-apex from `ui.json`, inline SVG fallback); `tests/test_gui_rules.py` enforces the CSP rules (no inline code / style, no `innerHTML`, no `eval`, no external URL, plain ES5). Test server `tools/devserver.py` with the production CSP; it prints CSP violations and browser JS errors in its terminal |
| 3 | **passed** (2026-11-19 17:45: charts render under the strict CSP without violations, ~450 ms, ~2.7 MB incl. theme; 2026-11-20: data-cursor tooltips on charts and sparklines confirmed, `hoverBehavior` must stay `'none'`, `style-src 'self'` is enough) – findings: `data-oj-binding-provider="none"` (otherwise JET waits for Knockout), `knockout` path for the DVT template engine (`ui.json` `libs.knockout`, loaded, never bound), `groupId` is an array, reference lines `location: front`, the theme `oj-redwood-notag` is required (without it only the unstyled "loading" text) | `oj-chart` needs `jquery` and `jqueryui-amd/*`, which JET 20.1.4 does not ship – APEX defines them as AMD shims over its global jQuery / jQuery UI (`libraries/apex/requirejs.jetConfig.js`); `wlsmon_charts.js` does the same (no inline script). The 44 modules of `ojchart` + `ojarraydataprovider` contain no `eval` / `new Function`; whether `oj-chart` writes style attributes (CSP `style-src`) shows only in the browser. Size: about 1.1 MB JET modules + 250 KB jQuery / jQuery UI, theme CSS (0.9 MB) optional (`ui.json` `jet_theme`). Probe page `tools/jet_probe/` |
| 4 | done, JET path live 2026-11-20 | `www/js/wlsmon_charts.js`: `init(ui)`, `line()`, `spark()`; JET renderer, the prototype SVG as fallback per chart; colours from the CSS tokens, redraw on theme switch |
| 5 | done | `wlsmon.py` (one file, stdlib, 3.6): `collect [--check] [--out] [--state]`, `rules --test`, `version`; `pull` is a stub (P2); config with defaults, credentials (`$CREDENTIALS_DIRECTORY`, OL8 fallback only with mode 400), atomic writes, own lock file (`state/run.lock` – the unit's `flock` holds `collect.lock`) |
| 6a–6g | done | real `collect --check` on the test host in 0.9 s, read-only, without credentials: host, nginx, ports / ready probes, Forms sessions from `/proc` (5 frmweb, all prestart pool), logs, core dumps |
| 6b | **done, verified 2026-11-20** | one read-only search POST on the test host (admin user through the library loader, password only on curl's stdin): the field names of the prototype plan are right on 14.1.2 (`healthState` object, collections as `items`); the real answer is the fixture `tests/fixtures/wls/search_real_14.1.2.json`. The first search after an AdminServer start took 11.3 s (REST initialised lazily), then 0.17 – 0.22 s |
| 6c | done | `parse_serverinfo` on the real XML of `80-FMW-Architecture/reports_monitoring_getserverinfo.md`; `failedJobs` / `successfulJobs` are counters since the start → the monitor shows the delta per round |
| 6f | done | rules against the real logs of the test host: `BEA-000365` (Notice, state change) and `REP-50001/50002` (start / stop, logged as `INCIDENT_ERROR`) would have been red all the time – the first one fixed in the rule, the second an `ignore` rule with reason; `BEA-001156` (stack trace of `BEA-001129`) ignored. Left unclassified in two real logs: 8 entries without a code |
| 6h | code done, off | `WLSMON_RCU_CHECK=false` until the DB monitor user is agreed |
| 6i | done | patch level from `inventory/patches/*.xml` + `registry.xml` (test host: Stack Patch Bundle `261112` = CSPU Nov 2026, 36 patches); JDK of the **running** domain from the AdminServer process (`jdk-21` 21.0.13.1, not the bundled 17.0.12); the nginx certificate from the TLS handshake (`/etc/nginx/ssl` is root-only; test host: 792 days); Derby running = a real finding on the test host |
| 6j | done | 9 checks; `/console` + `/management` probed anonymously through the own nginx |
| 7 | done | levels, topology (only DOWN propagates, one root-cause reason, the key figures of a DOWN component give no second reason), day ring, week / history buckets; `check_contract.py --real` green on the real output; 12 collect tests on fixtures (401 pause, AdminServer down, nginx down, Reports delta, log counts, core dump, patch baseline) |
| 8 | done | templates (`wlsmon.conf`, nginx include + headers + zone, collect / pull service + timer); `nginx -t` for both roles; a **throwaway nginx on the loopback** (`tests/test_templates.py`): 401 / 200 / 405 / 404 – it found that a nested `location ^~ /wlsmon/api/` hides the whitelist regexes (all JSON 404), fixed; `systemd-analyze verify` without findings |

Found for later steps:
- **nginx logs:** `/var/log/nginx` is not readable for the FMW owner →
  `02-install-wlsmon_root.sh` grants read access (ACL on the directory and
  the log files, plus a logrotate `postrotate` / `create` mode that keeps it).
- **POST** to a JSON file gets 405 (static handler), not 403 – both refuse.
- **Listening ports:** the test host listens on many non-loopback ports
  (Coherence, DB, NFS …) – `WLSMON_EXPECTED_PORTS` needs the interview,
  otherwise the check stays WARN.

### 2026-11-20 – `03-set-thresholds.sh`, swap limit, first customer

- First customer install (one host, both roles): `01-` stopped with
  "REST: user does not exist" – the state text of `monitor-user check` was in
  `error`; now `reason`, `error` only for a failed REST call (also unblocks the
  401 / reset branch).
- New operation script `03-set-thresholds.sh` (FMW owner): thresholds next to
  the value now and the 24-h maximum / average, `--set` / `--reset` /
  `--interactive`, values checked before writing, backup, `collect --check`.
  Logic in `wlsmon.py thresholds [--check KEY=VALUE]`.
- `WLSMON_SWAP_MB=512,2048` replaces "any swap in use = WARN" (the customer
  host showed WARN with 83 % memory used, 1.8 GB swap); series `swap_mb`.
- An unreadable threshold (e.g. `85;95`) is reported in `collector.errors`
  instead of silently using the default.
- Tests: 69 (swap levels, unreadable threshold, value checks, overview,
  `03-` dry run / refuse / write + backup + append / reset in an isolated copy).

### 2026-11-20 – JET tooltips on sparklines and charts

- Sparklines: tooltip (time · value) through the data cursor (`dataCursor: on`,
  `snap`, item `shortDesc`), `wlsmon.js` passes the time axis.
- Large charts: no tooltip with `hoverBehavior: 'dim'`; bisected on the test
  host (type `line` + `none` → tooltip; `lineWithArea` + `none` → tooltip and
  area) – `dim` is the cause, the charts keep `none` from `jetChart()`.
- `wlsmon.css`: the SVG fallback rules are scoped to `.chart-box > svg`; the
  plain `.chart-box svg` also hit the SVG inside `oj-chart`.
- First test run looked broken only because nginx answered 403 on the new JS
  (setgid entry below), the browser kept the old file.

### 2026-11-20 – re-run of step 10 removed the setgid bit (403)

- Symptom: after `01-install-wlsmon_fmw.sh --apply` (new `www/` for the
  sparkline tooltip) nginx answered 403 for the changed JS files and for every
  JSON file; the overview showed the host as STALE.
- Cause: Linux clears the setgid bit on every `chmod` by an owner who is not
  a member of the file's group. The oracle login was older than the
  `usermod -aG wlsmon` of step 11, so the unconditional `chmod 750` of 01 turned
  the 2750 of 02 into 750; new files (install, collector `os.replace`) then got
  group `oinstall`, which nginx cannot read.
- Fix in 01: `_dirmode` changes the mode only when the permission bits differ
  (setgid ignored); `install -D` runs under `umask 027`, so new subdirectories
  need no chmod; a WARN names the first file of `www/` / `api/` / `hosts/` that
  is not group `wlsmon` and points to 02.
- Live repair: group `wlsmon`, dirs 2750, files 640 again (the 02 commands).

### 2026-11-20 – collector live on the test host (Gunther: "Collector vorziehen")

- `wlsmon.py collect --secrets-stdin`: secrets as `name=value` lines on stdin,
  in memory only – for runs by hand before the installation (under systemd:
  `$CREDENTIALS_DIRECTORY`).
- First live round with credentials (admin user as a stand-in until the
  monitor user exists, `monUser` for Reports): all parts green –
  REST (3 servers RUNNING, heap 35 / 38 / 41 %, 4 / 4 data sources),
  Reports `repserver01` (0 / 4 engines busy), Forms (5 frmweb = prestart pool),
  patch level, certificate, logs, core dumps; under 1 s;
  `check_contract.py --real` 0 findings. Real WARN: memory of the test host
  (19 % free, swap in use).
- Since 08:53 a round every 5 minutes into the scratch directory (not
  installed, no systemd), so the GUI can be checked with real day series:
  `devserver.py --data <scratch>/wlsbase/live/api --apex /srv/apex/apex_1`.
- Security checks of the WebLogic administration rebuilt (hourly,
  `security.json`): `mgmt_rest_proxied` (Nginx configuration – `location` for
  `/management` or a catch-all to the AdminServer port – plus an anonymous
  probe with Host / SNI of the server block), `admin_locations` (`/console`,
  `/em` only with `deny all`), `admin_listen` (AdminServer port on the
  loopback). The old probe-only check could not tell "restricted" from
  "open": from 127.0.0.1 `/console` answers 403 even when it is open for the
  admin network. Test host: all three ok. Documentation:
  [weblogic_rest_monitoring.md §7](../../80-FMW-Architecture/weblogic_rest_monitoring.md#7-security-management-belongs-to-localhost-only).

### 2026-11-20 – step 11 live on the test host

- Gunther ran `02-install-wlsmon_root.sh --apply` as root (11:48): 35 OK,
  1 WARN (`WLSMON_ADMIN_IP_RANGE=any`), 0 FAIL. Group, setgid, nginx log ACL,
  3 credentials encrypted (`pending/` empty), htpasswd, nginx `-t` + reload,
  timer active, first run 5 s (collector 3.6 s), `collector.errors` empty;
  local test: `/wlsmon/` 401 without login, POST 401.
- `systemd-creds` notes "credential.secret is not located on encrypted
  media, using anyway" – expected without TPM2 / encrypted disk; the `.cred`
  files stay bound to this host.
- Browser check: `/wlsmon/hosts.json` 404 – not a permission problem; only
  `wlsmon.py pull` (P2) writes it, so a single GUI host had no overview.
  Fix: `collect` in role `gui` / `both` without `WLSMON_PULL_HOSTS` writes
  `hosts/hosts.json` with its own tile (`host_tile()`, reused by pull later)
  and the symlink `hosts/<id>` → `../api` – the host view link
  `host.html?host=<id>` reads the same path as for a pulled host.
- 12:02 overview and host view live in the browser (Gunther): `orafusion01`
  as tile, host view with real values; the `CORE_DIR` bind removed the false
  "Disk max" WARN. Remaining WARN "nginx log errors 1": our own hourly
  security probe (`GET /management/weblogic/latest` from 127.0.0.1) lands
  in `error.log` as 404 – now not counted (would be a WARN every hour).
- Found in the first service round: "Disk max" WARN because the core
  directory `/var/tmp/core` was "not found" – `PrivateTmp=yes` gives the unit
  its own `/var/tmp`. Fix: `BindReadOnlyPaths=-<core dir>` (block `CORE_DIR`,
  the directory from `kernel.core_pattern` or `WLSMON_CORE_DIR`); needs one
  more `02 --apply`.

### 2026-11-20 – step 11 written, isolated test + dry-run

- `02-install-wlsmon_root.sh` (root, or the FMW owner with `sudo -n`), in
  this order:
  1. group `wlsmon` (nginx + FMW owner), `WLSMON_BASE` owner:wlsmon 750,
     `www/ api/ hosts/` setgid 2750 / files 640, the rest 700;
  2. ACLs: traverse `u:nginx:x` only on parents nginx cannot pass; FMW owner
     reads the nginx logs (`u:oracle:rx` + default `u:oracle:r` on the
     directory – files logrotate creates inherit it); the ACLs set are listed
     in `/etc/nginx/wlsmon/root_acl.list` for `--remove`; SELinux context only
     when SELinux is on;
  3. secrets: `etc/pending/<name>` → `systemd-creds encrypt` →
     `etc/creds/<name>.cred` (root 400), clear text deleted; OL8 without
     credentials: file 400 of the FMW owner (warned as the weaker variant);
     `gui_htpasswd` / `pull_hash` → `/etc/nginx/wlsmon/htpasswd` /
     `pull_htpasswd` (root:nginx 640);
  4. nginx: headers, zone, include from the templates, diff + backup,
     `nginx -t` with rollback, reload; `/i/` from our include only when no
     other include routes it (test host: the ORDS include does);
  5. systemd: units of the role, `daemon-reload`, timers enabled; first run
     `systemctl start wlsmon-collect.service` + `now.json` summary;
  6. local access test (curl `--resolve` on the loopback: 401 / 403, POST
     refused).
- Template change: one `#@CRED_<name>_` block per credential (`CRED_WLS`,
  `CRED_REP`, `CRED_DB`, `CRED_PULL`) – a `LoadCredentialEncrypted` line for
  a missing file makes the unit fail to start, so only existing ones go in.
- Test: `--test-root DIR` puts `/etc` and `/var/log` below DIR; the test
  puts fake `sudo`, `systemctl`, `systemd-creds` (copies), `groupadd`,
  `setfacl` … first in `PATH` – apply, re-run (nothing changes), remove.
  59 tests. Dry-run on the test host: 9 OK, 1 WARN (`WLSMON_ADMIN_IP_RANGE=any`).

### 2026-11-20 – steps 9 and 10 live on the test host

- Gunther ran the interview interactively and `01-install-wlsmon_fmw.sh
  --apply` live: `wlsmon_monitor` created (only in `Monitors`, login works),
  `collect --check` with WebLogic REST complete (3 servers RUNNING, heap,
  JDBC 4 / 4, Reports, Forms) – summary 19 OK / 0 FAIL.
- The first live run created the user but reported `FAIL createUser:` with an
  empty text. Three bugs in the final check, not in the password (20
  characters, the realm rule len 12 / upper / lower / digit / special holds):
  - `listMemberGroups` returns a **cursor name** (`Cursor_95`), not a list –
    read with `haveCurrent` / `getCurrentName` / `advance`, then `close`;
  - every REST call needs `X-Requested-By`, **also a GET** – without it
    HTTP 400 (the login test sent only `Accept`);
  - a failed final check had no `error` text – now always a reason.
  The test fake answers like 14.1.2 (cursor, 400 without the header).
- Also: the host tile was WARN without a detail (memory free 18 %) – the
  build writes the names of the non-OK host metrics as detail now; the
  check of 01 passes `db_monitor` too (the RCU check reported "credential
  missing" although the interview had stored it).

### 2026-11-20 – step 9 done, step 10 prepared

**Step 9 – `00-setup-interview.sh` (done, tested in isolation):**
- Defaults: built-in (`wlsmon.py defaults`) < `environment.conf` < the host
  (`wlsmon.py detect`: patch cycle of the inventory, fixed ports, `/i/`
  libraries) < an existing `wlsmon.conf`. Test host: every value right
  (patch baseline 2026-11, expected ports `22 80 111 443 1521 7574`).
- `wlsmon.conf` also holds the installation keys (`WLSMON_BASE`,
  `WLSMON_ADMIN_IP_RANGE`, `WLSMON_GUI_USERS`, `WLSMON_GUI_IP`,
  `WLSMON_STYLE_SRC`, `WLSMON_PULL_USER`) – known to `wlsmon.py`, so no
  "unknown key" error. Fixed on the way: the config reader removed single
  quotes too (`'self'` → `self`, a broken CSP) – now only double quotes.
- Secrets to `etc/pending/` (700 / 600): `wls_monitor` generated (20
  characters, checked with the realm rule of the library), `reports_mon` from
  `reports_users.conf.des3` or asked, `pull_user` / `pull_hash` /
  `gui_htpasswd` / `db_monitor` by role. An existing secret is kept (a second
  run must not change the password of the WebLogic user), `--secret NAME`
  changes exactly one. Dry-run writes nothing.
- Interactive questions (`read -e -i` with the default) are not tested yet –
  Gunther runs the interview on the test host.

**Step 10 – `01-install-wlsmon_fmw.sh` (prepared, dry-run and `--no-user`
tested in isolation, NOT run live):**
- Read-only verification on the test host: realm `myrealm`,
  `DefaultAuthenticator` offers `userExists`, `groupExists`, `isMember`,
  `listMemberGroups`, `createUser`, `addMemberToGroup`, `resetUserPassword`,
  `removeUser` under `serverConfig` – no edit session. `wlsmon_monitor` does
  not exist yet, the group `Monitors` does.
- `wlsmon.py monitor-user check|create|reset --secrets-stdin`: the REST user
  calls in Python, passwords on stdin (they are in the JSON body); after an
  admin 401 it stops at once (one call, no lockout); `create` is idempotent;
  the check verifies "only in Monitors" and a login with the monitor password.
- The script installs `bin/`, `share/`, `www/` + `ui.json` (from
  `wlsmon.py detect`, incl. `libs.knockout`), the local rules skeleton, the
  data directories; creates / checks the monitor user; ends with
  `collect --check` – with the monitor password only for a verified user
  (found: the first draft logged in with a user that did not exist yet).
  `--remove` keeps `etc/` and only lists the WebLogic user.
- `collect --check` removes its temporary directory now (5 left in `/tmp`
  from earlier runs, removed).

**Port check rebuilt (found while detecting the defaults):** the Forms
prestart runtimes (`frmweb`) listen on **all interfaces** on random ports,
like Coherence and the DB dispatcher. A fixed list would warn after every
restart. Now only fixed ports below the ephemeral range
(`ip_local_port_range`, test host from 9000) are compared with
`WLSMON_EXPECTED_PORTS`; random listeners are counted per process, and a
separate check `forms_listeners` reminds that the host firewall must block
the ephemeral range from outside.

Next with Gunther: interview interactively, then `01 --apply` live (creates
`wlsmon_monitor`), then step 11.

