# 03-Logs – Log Management for Forms / Reports / WebLogic

Author: Gunther Pipperr | https://pipperr.de | License: Apache 2.0

Where an FMW 14.1.2 Forms & Reports domain writes its logs, what to look
for, and the `03-Logs/` scripts for inventory, search, live view, cleanup,
archiving and log levels.

**Why** the logs are spread like this – which process writes what – is
explained in [`80-FMW-Architecture/`](../80-FMW-Architecture/README.md):
[who starts whom](../80-FMW-Architecture/weblogic_middleware_architecture.md#4-who-starts-whom--the-control-chain),
[where is what – homes, configuration, logs](../80-FMW-Architecture/weblogic_middleware_architecture.md#7-where-is-what--homes-configuration-logs),
[Reports server and engines](../80-FMW-Architecture/report_engine_architecture.md#1-the-parts),
[Forms logs and ODL levels](../80-FMW-Architecture/forms_runtime_architecture.md#6-logs-traces-monitoring).

---

## Table of Contents

1. [Log Landscape](#1-log-landscape)
2. [Log Formats and Rotation](#2-log-formats-and-rotation)
3. [Key Log Files – What to Look For](#3-key-log-files--what-to-look-for)
4. [Error Codes](#4-error-codes)
5. [Log Levels](#5-log-levels)
6. [Scripts Reference](#6-scripts-reference)
7. [Step-by-Step: Fresh Diagnostic Baseline](#7-step-by-step-fresh-diagnostic-baseline)
8. [Troubleshooting](#8-troubleshooting)
9. [References](#9-references)

---

## 1. Log Landscape

Confirmed on the test host (2026-10-19, **confirmed (live)**). Every
process writes below `$DOMAIN_HOME/servers/<name>/logs/` – WebLogic
servers **and** the system components (standalone Reports server,
Reports tools):

```
$DOMAIN_HOME
├── servers/
│   ├── AdminServer/logs/
│   │   ├── AdminServer.log            WebLogic server log (BEA-*)
│   │   ├── AdminServer-diagnostic.log ODL log (Java components, EM, OPSS)
│   │   ├── AdminServer.out            stdout/stderr (rotated at every start: .out00001 …)
│   │   ├── fr_domain.log              domain log (messages of all servers)
│   │   └── access.log                 HTTP access log
│   ├── WLS_FORMS/logs/
│   │   ├── WLS_FORMS.log / -diagnostic.log / .out
│   │   └── formsapp-diagnostic.log    Forms servlet (FRM-93xxx: frmweb start, sessions)
│   ├── WLS_REPORTS/logs/
│   │   ├── WLS_REPORTS.log / -diagnostic.log / .out
│   │   └── reports/rwservlet_diagnostic.log   rwservlet (in-process server: also rwserver_diagnostic.log)
│   ├── repserver01/logs/              standalone Reports server = system component
│   │   ├── rwserver_diagnostic.log    Reports server (jobs, REP-5xxxx)
│   │   ├── rwEng-0_diagnostic.log     one log per engine – the root cause of REP errors
│   │   ├── rwEng-1_diagnostic.log
│   │   └── repserver01.out            stdout of the rwserver process (Node Manager)
│   └── reptools1/logs/
│       └── runtime_diagnostic.log     rwrun / rwconverter / Reports Builder runtime
├── nodemanager/
│   └── nodemanager.log                server / component start, stop, crash, restart
└── servers/AdminServer/sysman/log/emoms.log   Enterprise Manager (Fusion Middleware Control)
```

Not log locations (although older guides / earlier versions of these
scripts said so): `$DOMAIN_HOME/diagnostics/logs/` does **not exist** in
14.1.2 – the ODL logs are `servers/<srv>/logs/<srv>-diagnostic.log`;
`config/fmwconfig/components/ReportsToolsComponent/reptools1/` holds the
**configuration** (`rwbuilder.conf`, `logging.xml` …), not the logs.

Not counted as logs, but the real disk consumers below `servers/` on the
test host: `servers/<srv>/tmp/` (WebLogic cache, 400–800 MB each) and
`servers/<srv>/adr/` (ADR incidents) – `get_all_logs.sh` lists them
separately.

> **Key point for Reports:** `WLS_REPORTS.log` and
> `rwservlet_diagnostic.log` usually show only the wrapper error the user
> got. The cause (font, file, SQL, engine crash) is in
> `servers/<repserver>/logs/rwEng-N_diagnostic.log` and
> `rwserver_diagnostic.log`. Batch runs via `rwrun` log to
> `servers/reptools1/logs/runtime_diagnostic.log`
> (deeper: `01-Run/rwrun_trace.sh`).

All `03-Logs` scripts find these directories themselves
([`log_locations.sh`](log_locations.sh)): every `servers/*/logs` with its
role (Admin server, Managed server, Reports server, Reports tools), plus
Node Manager and EM. No server name is hard-coded.

---

## 2. Log Formats and Rotation

### WebLogic server log (`<srv>.log`, `fr_domain.log`)

```
####<Oct 19, 2026, 2:13:41,123 PM CEST> <Error> <HTTP> <host> <WLS_REPORTS> \
<[ACTIVE] ExecuteThread: '1' …> <<WLS Kernel>> <> <…> <1760876021123> \
<[severity-value: 8] …> <BEA-101020> <[ServletContext@…] Servlet failed …>
```

Fields in angle brackets: time, severity (`<Error>`, `<Warning>`,
`<Notice>`, `<Info>`), subsystem, host, server, thread, user, transaction,
diagnostic context, epoch, message id (`BEA-…`), message.

### ODL logs (`*-diagnostic.log`, `rwEng-N_diagnostic.log`, …)

```
[2026-10-17T10:54:12.345+02:00] [WLS_REPORTS] [ERROR] [REP-52262] \
[oracle.reports.servlet] [tid: …] [userId: …] [ecid: …] Diagnostic output is disabled …
```

`[time] [component] [level] [message id] [logger] [thread] [user] [ecid] message`.
Levels: `INCIDENT_ERROR`, `ERROR`, `WARNING`, `NOTIFICATION`, `TRACE`.
The `ecid` links the entries of one request across servlet, server and
engine logs.

### Rotation (as configured on the test host)

| Log | Rotation | Source |
|---|---|---|
| `<srv>.log` | WebLogic defaults – no `<log>` element in `config.xml` | Remote Console → server → Logging |
| `<srv>.out` | by the Node Manager at **every start** → `<srv>.out00001` … (13 on the AdminServer after a week of tests) | **confirmed (live)** |
| ODL `*-diagnostic.log` | `maxFileSize` 10 MB per file, `maxLogSize` 100 MB per log → `*-diagnostic-1.log` … | `config/fmwconfig/servers/<srv>/logging.xml`, Reports: `components/ReportsServerComponent/<name>/logging.xml` (**confirmed (live)**) |
| `nodemanager.log` | `LogLimit=0` (unlimited), `LogCount=1` | `nodemanager.properties` |

The scripts treat as **rotated**: `*.log00001`, `*.out00001`,
`*-diagnostic-1.log`, `*.log.1`; as **compressed**: `*.gz`, `*.bz2`.

---

## 3. Key Log Files – What to Look For

| Problem | Look first in |
|---|---|
| Report fails, user sees REP error | `servers/<repserver>/logs/rwEng-N_diagnostic.log` (cause), `rwserver_diagnostic.log` (job), then `WLS_REPORTS/logs/reports/rwservlet_diagnostic.log` |
| Report via `rwrun` / batch | `servers/reptools1/logs/runtime_diagnostic.log`, `01-Run/rwrun_trace.sh` |
| Reports server does not start / restarts | `nodemanager/nodemanager.log`, `servers/<repserver>/logs/<repserver>.out` (REP-50600 multicast, REP-56040 name in use) |
| Forms session does not start | `WLS_FORMS/logs/formsapp-diagnostic.log` (FRM-93xxx: frmweb start, environment), `WLS_FORMS.out` |
| Server does not start / crashes | `nodemanager/nodemanager.log`, `<srv>.out` (JVM errors, OutOfMemoryError), `<srv>.log` |
| Deployment, data source, OPSS, SSL | `AdminServer.log`, `AdminServer-diagnostic.log` |
| EM (Fusion Middleware Control) | `servers/AdminServer/sysman/log/emoms.log`, `AdminServer-diagnostic.log` |
| Login / security of the Reports server | `rwserver_diagnostic.log` (identity store, `securityId`), `AdminServer-diagnostic.log` |

---

## 4. Error Codes

Codes found in the test-host logs (2026-10-19) and from the work on this
project:

| Code | Where | Meaning / cause |
|---|---|---|
| `REP-50600` | `<repserver>.out` | broadcasting disabled – multicast port blocked (firewall `14027/udp`), Reports server stops – [discovery](../80-FMW-Architecture/reports_server_discovery_multicast.md) |
| `REP-56040` | rwserver log | a Reports server with that name already runs in the network |
| `REP-56132` | engine log | file access outside `<folderAccess>` – [image handling](../80-FMW-Architecture/report_server_image_handling.md) |
| `REP-108` | engine log | file (image) not found – Windows path in the report |
| `REP-50125` | rwserver log | `StreamCorruptedException` – foreign packet on the discovery port |
| `REP-52262` | rwservlet log | diagnostic output disabled – the user sees no details (by design) |
| `REP-0069` | engine log | internal error – look at the lines before it |
| `REP-501` / `REP-0501` | engine log | unable to connect to the database (data source of the report) |
| `REP-1924` | engine log | font file not found – see `04-ReportsFonts/` |
| `FRM-93xxx` | `formsapp-diagnostic.log` | Forms servlet / `frmweb` process start, environment (`default.env`) |
| `BEA-000362` | `<srv>.log` | server failed to start (e.g. port in use) |
| `ORA-12541` / `ORA-01017` / `ORA-28001` | data source / engine logs | no listener / wrong password / password expired – `02-Checks/db_connect_check.sh` |

Quick scan:

```bash
./03-Logs/grep_logs.sh 'REP-[0-9]' --component reports --since-minutes 60
./03-Logs/grep_logs.sh 'FRM-[0-9]' --component forms
./03-Logs/grep_logs.sh 'BEA-[0-9]\|ORA-[0-9]' --level ERROR      # basic regex: \| = or
```

---

## 5. Log Levels

Java / ODL levels (highest to lowest):

```
SEVERE  = ERROR         errors
WARNING = WARNING
INFO    = NOTIFICATION  default in production
CONFIG  = NOTIFICATION:16
FINE    = TRACE:1       debug (large volume)
FINER   = TRACE:16
FINEST  = TRACE:32      maximum detail – short, targeted sessions only
```

Loggers on `WLS_REPORTS` (`setLogLevel.sh --query`, **confirmed (live)**):
`oracle.reports`, `oracle.reports.admin`, `oracle.reports.configMbeans`,
`oracle.reports.rwclient.RWClient`, `oracle.reports.server`,
`oracle.reports.servlet`. There is **no** `oracle.reports.engine` /
`oracle.reports.fonts` logger in WebLogic – the engines run in the
standalone Reports server process; their level is set in
`config/fmwconfig/components/ReportsServerComponent/<name>/logging.xml`
(restart of the Reports server), for `rwrun` via
`01-Run/rwrun_trace.sh --odl`.

`setLogLevel.sh` changes the level **at runtime only** by default
(`persist=0`); `--persist` writes it into
`config/fmwconfig/servers/<srv>/logging.xml` so that it survives a restart.

---

## 6. Scripts Reference

All scripts read `environment.conf`; the log directories come from
[`log_locations.sh`](log_locations.sh). `--component` accepts:
`all` (default), `reports` (WLS_REPORTS + Reports servers + Reports tools),
`forms`, `wls` (all WebLogic servers), `nm`, `em`, or a server name
(`AdminServer`, `WLS_REPORTS`, `repserver01`, …).

| Script | Purpose | Mode |
|---|---|---|
| `get_all_logs.sh` | inventory: every log with size, date, active / rotated / compressed, totals | read-only |
| `grep_logs.sh` | search a pattern in all logs incl. rotated and `.gz` | read-only |
| `tail_logs.sh` | live view of the main logs (tmux split panes or plain `tail -F`) | read-only |
| `cleanLogFiles.sh` | truncate active logs, delete old rotated / compressed ones | `--apply` |
| `archive_logs.sh` | gzip rotated logs | `--apply` |
| `setLogLevel.sh` | query / set WebLogic logger levels via WLST | `--apply` |
| `log_locations.sh` | shared helper (sourced): log groups, file kind, file search | – |

### get_all_logs.sh

```bash
./03-Logs/get_all_logs.sh
./03-Logs/get_all_logs.sh --component reports
```

One section per log group (role – name, directory), every file with
size, modification time and status (`active`, `rotated`, `compressed`);
files in subdirectories shown relative (`reports/rwservlet_diagnostic.log`).
WARN for active logs larger than `LOG_MAX_SIZE_MB` (default 500) or not
written for `LOG_RETAIN_DAYS` (default 30) days. Summary: total size of
the log files, plus `servers/*/tmp` and `servers/*/adr` (not logs, often the
real disk consumers).

### grep_logs.sh

```bash
./03-Logs/grep_logs.sh 'REP-3000'
./03-Logs/grep_logs.sh 'REP-' --component reports --since 2026-10-17
./03-Logs/grep_logs.sh 'Exception' --context 5 --level ERROR
./03-Logs/grep_logs.sh 'Exception' --since-minutes 30
```

| Option | Description |
|---|---|
| `<pattern>` | search pattern (basic regex, case-insensitive; `\|` for alternatives) |
| `--component NAME` | see above (default `all`) |
| `--since YYYY-MM-DD` | only files modified on / after this date |
| `--since-minutes N` | only files modified within the last N minutes |
| `--context N` | lines of context per match (default 3) |
| `--level ERROR\|WARNING\|INFO` | only files that also contain this keyword |

Active, rotated and compressed files (`zgrep`); file name and line number
per match; REP- / FRM- / BEA- / ORA- codes highlighted. `--since` and
`--since-minutes` are mutually exclusive.

### tail_logs.sh

```bash
./03-Logs/tail_logs.sh                       # main logs of all groups
./03-Logs/tail_logs.sh --component reports   # WLS_REPORTS + Reports server + engines + rwrun
./03-Logs/tail_logs.sh --component forms --lines 50
./03-Logs/tail_logs.sh --all-files --component WLS_FORMS
./03-Logs/tail_logs.sh --no-tmux
```

| Option | Description |
|---|---|
| `--component NAME` | see above (default `all`; EM only with `em`) |
| `--lines N` | initial lines per file (default 20) |
| `--all-files` | every active log of the selected groups, not only the main ones |
| `--no-tmux` | plain `tail -F` even when tmux is available |

Main logs per group: `<srv>.log`, `<srv>.out`, `<srv>-diagnostic.log`,
`rwservlet_diagnostic.log` (only if written); Reports server:
`rwserver_diagnostic.log`, `rwEng-*_diagnostic.log`, `<name>.out`; Reports
tools: `runtime_diagnostic.log`; `nodemanager.log` (16 files for `all` on
the test host). `tail -F` follows by name – it keeps following when
WebLogic rotates a log.

tmux: one pane per file (tiled, file name in the pane border); inside tmux
a new window, outside a new session. `Ctrl-b d` detach, `Ctrl-b &` close.
More than 12 files → hint to narrow with `--component`. Without tmux:
`tail -F` with coloured output (`<Error>` / `[ERROR]` / SEVERE red,
warnings yellow, info green).

### cleanLogFiles.sh

```bash
./03-Logs/cleanLogFiles.sh                          # dry-run: plan
./03-Logs/cleanLogFiles.sh --apply
./03-Logs/cleanLogFiles.sh --retain-days 3 --apply
./03-Logs/cleanLogFiles.sh --include-out --apply
./03-Logs/cleanLogFiles.sh --component reports --apply
```

| Option | Description |
|---|---|
| `--apply` | execute (default: dry-run plan) |
| `--retain-days N` | keep rotated / compressed logs N days (default `LOG_RETAIN_DAYS`, 7) |
| `--include-out` | also truncate `*.out` (skipped by default – may hold JVM crash output) |
| `--component NAME` | see above |

Rules: active `*.log` / `*.trc` → `truncate -s 0` (the server keeps
writing into the same file); `*.out` → only with `--include-out`;
rotated and compressed files older than `--retain-days` → delete.
`nodemanager/` and the EM logs are **never** touched. The plan shows
TRUNCATE / DELETE / SKIP per file and the space freed.

> Truncating is irreversible – run `grep_logs.sh` first.

### archive_logs.sh

```bash
./03-Logs/archive_logs.sh                        # dry-run
./03-Logs/archive_logs.sh --apply
./03-Logs/archive_logs.sh --min-age 7 --apply
./03-Logs/archive_logs.sh --level 6 --apply
```

| Option | Description |
|---|---|
| `--apply` | compress (default: dry-run) |
| `--min-age N` | only files older than N days (default `LOG_ARCHIVE_MIN_AGE_DAYS`, 1) |
| `--level N` | gzip level 1–9 (default 9) |
| `--component NAME` | see above |

Compresses **rotated** logs (`*.log00001`, `*.out00001`,
`*-diagnostic-1.log`, …) with gzip; active and already compressed files
are never touched. Afterwards still searchable with `grep_logs.sh` /
`zgrep`.

### setLogLevel.sh

```bash
./03-Logs/setLogLevel.sh --query --target WLS_REPORTS --logger oracle.reports
./03-Logs/setLogLevel.sh --level FINE --logger oracle.reports.server --target WLS_REPORTS --apply
./03-Logs/setLogLevel.sh --level INFO --logger oracle.reports.server --target WLS_REPORTS --apply
./03-Logs/setLogLevel.sh --level WARNING --target all --apply --persist
```

| Option | Description |
|---|---|
| `--query` | current levels (no `--apply` needed) |
| `--level LEVEL` | `SEVERE\|WARNING\|INFO\|CONFIG\|FINE\|FINER\|FINEST` |
| `--logger NAME` | logger and its children (default: `oracle.reports oracle.forms oracle.adf weblogic.xml.stax`) |
| `--target SERVER` | `AdminServer\|WLS_FORMS\|WLS_REPORTS\|all` (default `$WLS_MANAGED_SERVER`) |
| `--apply` | required to change a level (otherwise dry-run) |
| `--persist` | also save to `logging.xml` (survives a restart) |

Needs the running AdminServer and the stored credentials
(`00-Setup/weblogic_sec.sh`). WebLogic servers only – see section 5 for
the Reports server / engines.

Fixed 2026-10-19 (**confirmed (live)**): `--query` found no loggers
(`listLoggers` takes a regex – `oracle.reports*` only matched
`oracle.report(s)`); every `--apply` was **persistent** although documented
as runtime-only (WLST default `persist=1`; on top, a Python variable named
`persist` is replaced by the Java package `weblogic.persist` after
`connect()`).

---

## 7. Step-by-Step: Fresh Diagnostic Baseline

```
Step 1 – Inventory
  ./03-Logs/get_all_logs.sh

Step 2 – Save existing errors before wiping anything
  ./03-Logs/grep_logs.sh 'REP-\|FRM-\|BEA-\|ORA-' --context 5

Step 3 – Compress rotated logs
  ./03-Logs/archive_logs.sh            # plan
  ./03-Logs/archive_logs.sh --apply

Step 4 – Clean active logs for a fresh baseline
  ./03-Logs/cleanLogFiles.sh           # plan
  ./03-Logs/cleanLogFiles.sh --apply

Step 5 – (optional) more detail for one WebLogic logger, runtime only
  ./03-Logs/setLogLevel.sh --level FINE --logger oracle.reports.server --target WLS_REPORTS --apply

Step 6 – Watch live while reproducing the problem
  ./03-Logs/tail_logs.sh --component reports

Step 7 – Search the result
  ./03-Logs/grep_logs.sh 'REP-' --since-minutes 30 --context 10

Step 8 – Reset the level
  ./03-Logs/setLogLevel.sh --level INFO --logger oracle.reports.server --target WLS_REPORTS --apply
```

---

## 8. Troubleshooting

### REP error for the user – cause not visible in WLS_REPORTS.log

```
Symptom: WLS_REPORTS.log / rwservlet_diagnostic.log show only the error the
         user got (REP-52262 diagnostic output disabled, REP-50125 …)
Cause:   the report runs in an engine of the standalone Reports server – a
         different process with its own logs
Fix:     ./03-Logs/grep_logs.sh 'REP-' --component repserver01 --since-minutes 30
         → servers/<repserver>/logs/rwEng-N_diagnostic.log, rwserver_diagnostic.log
```

### Log file missing or empty after start

```
Symptom: <srv>.log missing or 0 bytes after a start
Cause A: the server failed before logging was initialised
         → nodemanager/nodemanager.log, servers/<srv>/logs/<srv>.out
Cause B: cleanLogFiles.sh truncated the file, nothing logged since → normal
```

### Disk full

```
Symptom: no space left on device
Check:   ./03-Logs/get_all_logs.sh – log totals and servers/*/tmp, servers/*/adr
         (on the test host tmp/ was 400–800 MB per server, the logs 40 MB in all)
Fix:     ./03-Logs/archive_logs.sh --apply
         ./03-Logs/cleanLogFiles.sh --apply     (after grep_logs.sh)
         servers/<srv>/tmp: only with the server stopped
```

### grep_logs.sh finds nothing in compressed logs

```
Cause:   zgrep missing
Fix:     sudo dnf install gzip      (zgrep is part of gzip)
```

### setLogLevel.sh cannot connect

```
Cause A: AdminServer not running        → ./01-Run/startStop.sh start AdminServer --apply
Cause B: stored password wrong          → ./00-Setup/weblogic_sec.sh --apply
Cause C: WL_ADMIN_URL wrong             → environment.conf (t3://localhost:7001)
```

### setLogLevel.sh – level back after a restart / still set after a restart

```
Default is runtime only (lost at restart). With --persist the level is in
config/fmwconfig/servers/<srv>/logging.xml – reset with
--level INFO … --apply --persist. Before 2026-10-19 every change was
persisted: check logging.xml for level='TRACE…' entries left from old runs.
```

---

## 9. References

All links checked 2026-10-19 (HTTP 200, title matches) – see below.

- Configuring Log Files and Filtering Log Messages for Oracle WebLogic Server 14.1.2:
  https://docs.oracle.com/en/middleware/fusion-middleware/weblogic-server/14.1.2/wllog/index.html
- Troubleshooting Oracle Reports Services (12.2.1.3 guide, still valid for the architecture):
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_trouble.htm
- Pipperr.de – Oracle Reports 14c install guide:
  https://www.pipperr.de/dokuwiki/doku.php?id=forms:oracle_reports_14c_windows64
