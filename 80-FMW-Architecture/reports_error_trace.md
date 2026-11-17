---
title: "Oracle Reports 14c: Error Analysis and Trace Levels"
description: "Oracle Reports 14.1.2 error analysis: which log shows the cause, ODL trace levels per component, TRACE:32 step by step, what no longer works, live-tested."
---

# Oracle Reports 14c – error analysis and trace levels

A report fails, the user sees `REP-…` in the browser – where is the cause,
and when is a trace needed at all? This page puts the pieces together that
are spread over the library, and adds what was tested on the test host on
2026-11-17 (Reports 14.1.2, standalone Reports server `repserver01`,
secured, calls through rwservlet with a `cmdkey`).

Short version:

1. **Without any trace** the engine log `rwEng-N_diagnostic.log` already
   holds the real cause (`REP-501` + the `ORA-` behind it, `REP-56132` …).
   Look there first.
2. A trace is set with **ODL levels in `logging.xml`** – per component, for
   the whole server, never per job.
3. The old ways (`<trace>` in `rwserver.conf`, `traceopts=` in the URL,
   `trace` in `rwservlet.properties`) **no longer exist** in 14.1.2.
4. A trace of **one** report with `TRACEOPTS` only works with `rwrun`:
   [`01-Run/rwrun_trace.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/01-Run/rwrun_trace.sh).

**Related:** log files, rotation and level names:
[03-Logs/README.md](../03-Logs/README.md); the engine processes:
[reports_engine_architecture.md](reports_engine_architecture.md); job model
and queues: [reports_job_handling.md](reports_job_handling.md); status over
HTTP: [reports_monitoring_getserverinfo.md](reports_monitoring_getserverinfo.md).

---

## 1. Where an error shows up

```
browser / Forms RUN_REPORT_OBJECT / cmdkey call
   |  HTML page "REP-xxxx" (the user sees only the wrapper)
   v
WLS_REPORTS  rwservlet ........ servers/WLS_REPORTS/logs/reports/rwservlet_diagnostic.log
   |  (in-process server: also rwserver_diagnostic.log there)
   v
Reports server repserver01 .... servers/repserver01/logs/rwserver_diagnostic.log  (jobs, queue)
   |                            servers/repserver01/logs/repserver01.out          (stdout, libOVD)
   v
engines rwEng-0, rwEng-1 ...... servers/repserver01/logs/rwEng-N_diagnostic.log   <- the cause
   |
   v  hard crash of the native engine part
ADR incidents (rwrun: ~/oradiag_oracle/diag/clients/user_oracle/*/incident/)
```

| Log | Written by | Contains at the default level |
|---|---|---|
| `rwEng-N_diagnostic.log` | logger `oracle.reports.engine` of the Reports server | **the cause:** `ERROR … Job ID = <n> ERR REP-0501 …` with the `ORA-` text, `INCIDENT_ERROR [REP-69]` with the Java stack |
| `rwserver_diagnostic.log` | logger `oracle.reports.server` | server start, configuration warnings (e.g. `MailService` with `%MAILSERVER_NAME%`), security; **no line for a failed job** at `NOTIFICATION:1` (live) |
| `zrclient_diagnostic.log` | logger `oracle.reports.zrclient` | the client side of the server ↔ engine connection; empty on the test host |
| `repserver01.out` | stdout of the Reports server process | JVM messages, libOVD / LDAP lines (`VDELogger`) of the secured server |
| `rwservlet_diagnostic.log` | WLS_REPORTS, loggers `oracle.reports.servlet` / `.server` | servlet side: `REP-52262` (diagnostic output disabled), login, cgicmd |
| `runtime_diagnostic.log` | ReportsTools instance (`rwrun`, `rwconverter`) | batch runs outside the Reports server |

**`ecid`:** every ODL line carries an `[ecid: …]` – the same value in the
servlet, server and engine log belongs to the same request.

### 1.1 Live test at the default level (2026-11-17)

| Test | The user sees | `rwEng-0_diagnostic.log` |
|---|---|---|
| report file not there (`nix_da.rdf`) | `REP-69: An internal error occurred` / `REP-56132: Access is denied to the report definition file.` | `ERROR … ERR REP-0069 … REP-56132` + `INCIDENT_ERROR [REP-69]` with stack |
| wrong DB service in `userid` | `REP-501: The specified database cannot be connected.` | `ERROR … ERR REP-0501 … ORA-12162: TNS:net service name is incorrectly specified` |
| good report | PDF | nothing |

Two findings from it:

- **A missing file reports `REP-56132` (access denied), not "file not
  found":** the `<folderAccess>` check comes first. Before changing
  `folderAccess`, check whether the file exists at all and is spelt exactly
  (Linux is case-sensitive).
- **Every failed job shows up four times:** `<job … retry="3"/>` (template
  of [`13-oracle_setup_reports.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/13-oracle_setup_reports.sh)) runs a failed job
  three more times. Four identical error blocks with the same `Job ID` are
  one error, not four.

Quick search:

```bash
L=$DOMAIN_HOME/servers/repserver01/logs
grep -h 'ERR REP-' $L/rwEng-*_diagnostic.log | tail -20          # job id + REP code
grep -h -A2 'Job ID = 126 ' $L/rwEng-*_diagnostic.log | head -20  # one job with the ORA- line
./03-Logs/grep_logs.sh 'REP-[0-9]' --component reports --since-minutes 60
```

The server administrator also sees the error of each job in the past queue
with `showjobs` / `getserverinfo`
([reports_monitoring_getserverinfo.md](reports_monitoring_getserverinfo.md)).

---

## 2. Trace levels – what they mean for Reports

Since 11g Reports logs with Oracle Diagnostic Logging (ODL). The old 10g
trace options map to ODL levels (Oracle 12.2.1.3 *Publishing Reports*,
Table 24-3, shortened):

| ODL level | Content | Old option |
|---|---|---|
| `INCIDENT_ERROR:1` | unexpected internal errors | `TRACE_EXC` |
| `ERROR:1` | errors | `TRACE_ERR` |
| `WARNING:1` | warnings | `TRACE_WRN` |
| `NOTIFICATION:1` | **default** – important events of server / engine | `TRACE_LOG` |
| `NOTIFICATION:16` | server / engine state, configuration changes, **successful / failed jobs** | `TRACE_STA`, `TRACE_INFO` |
| `TRACE:1` | profiling | `TRACE_PRF` |
| `TRACE:8` | functional areas (distribution, fonts, printing) | `TRACE_DST` |
| `TRACE:16` | server: debug traces, engine: engine diagnostics | `TRACE_DBG` |
| `TRACE:32` | everything | `TRACE_ALL` (= `TRACE_APP`, `BRK`, `PLS`, `SQL`, `TMS` + all lower) |

Each level includes the ones above it. A sensible order: **`NOTIFICATION:16`**
first (job results, small – from Oracle's table, not tested here), then
`TRACE:16`, `TRACE:32` only for a short, targeted run.

---

## 3. Where the level is set

| Component | File / tool | Loggers | Becomes active |
|---|---|---|---|
| **standalone Reports server** + its engines | `$DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent/<name>/logging.xml` | `oracle.reports.server` → `rwserver_diagnostic.log`, `oracle.reports.engine` → `rwEng-N_diagnostic.log`, `oracle.reports.zrclient` → `zrclient_diagnostic.log` | restart of the Reports server |
| WLS_REPORTS (rwservlet, **in-process** server) | [`03-Logs/setLogLevel.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/03-Logs/setLogLevel.sh) (WLST `setLogLevel`), persistent in `config/fmwconfig/servers/WLS_REPORTS/logging.xml` | `oracle.reports.servlet`, `oracle.reports.server`, … ([03-Logs §5](../03-Logs/README.md)) | at once (runtime), `--persist` survives a restart |
| `rwrun` / ReportsTools | `logging.xml` of the ReportsTools instance, logger `oracle.reports.runtime` | → `runtime_diagnostic.log` | next run – [`rwrun_trace.sh --odl --apply`](https://github.com/gpipperr/IHateWeblogic/blob/main/01-Run/rwrun_trace.sh) sets and restores it |

WLST `setLogLevel` does **not** reach the standalone Reports server – Oracle:
"not supported for system components, such as Reports Server and Reports
Bridge". For it only `logging.xml` + restart works. Fusion Middleware Control
(Reports server → Logs → Log Configuration) writes the same file (not tested
here).

The shipped `logging.xml` of a Reports server (14.1.2):

```xml
<logger name='oracle.reports.server' level='NOTIFICATION:1' useParentHandlers='false'>
   <handler name='rwserver_trace_handler'/>
</logger>
<logger name='oracle.reports.engine' level='NOTIFICATION:1' useParentHandlers='false'>
   <handler name='rwengine_trace_handler'/>
</logger>
<logger name='oracle.reports.zrclient' level='NOTIFICATION:1' useParentHandlers='false'>
   <handler name='zrclient_trace_handler'/>
</logger>
```

Rotation per handler: `maxFileSize` 10 MB, `maxLogSize` 100 MB.

---

## 4. Step by step: engine and server to `TRACE:32` (standalone server)

Tested 2026-11-17 on the test host; the file was restored afterwards and
byte-compared.

```bash
R=$DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent/repserver01

# 1. backup
cp -p $R/logging.xml $R/logging.xml.bak_$(date +%Y%m%d_%H%M%S)

# 2. level up - only the loggers needed: engine for report errors,
#    server for queue / engine-manager problems
vi $R/logging.xml
#    oracle.reports.engine  NOTIFICATION:1 -> TRACE:32
#    oracle.reports.server  NOTIFICATION:1 -> TRACE:32

# 3. restart the Reports server (not WLS_REPORTS)
./01-Run/startStop.sh stop  repserver01 --apply
./01-Run/startStop.sh start repserver01 --apply

# 4. reproduce the error once, note the time
# 5. collect the lines since then
L=$DOMAIN_HOME/servers/repserver01/logs
awk '/^\[20/{p=(substr($0,2,16)>="2026-11-17T14:15")} p' $L/rwEng-0_diagnostic.log > /tmp/rwEng-0_trace.log

# 6. back: restore the backup, restart again
cp -p $R/logging.xml.bak_<ts> $R/logging.xml
./01-Run/startStop.sh stop  repserver01 --apply
./01-Run/startStop.sh start repserver01 --apply
```

### 4.1 What `TRACE:32` adds (live)

| Log | Additional lines | Examples |
|---|---|---|
| `rwEng-N_diagnostic.log` | `NOTIFICATION:16`, `TRACE`, `TRACE:16`, `TRACE:32` | `RWEngine:init args[n]=…` (engine start parameters), `EngineImpl:setCommandLine` (the job command line), `EngineImpl:checkReportDefinition Doing access checks`, `EngineImpl:run Running Jobid=…`, `CRunReport returns: 5` (return code of the C engine), `CEngine:FontRevamp: Font FullName : …` (every font found) |
| `rwserver_diagnostic.log` | mostly `TRACE:16` | `JobManager:firstToRun job 129 is first to run`, `Job 129 is a sync job`, `EngineManager:spawnEngine Started engine with Environment …`, `EngineInfo:setState Engine rwEng-0 state is: Running`, `JobObject:writeLongUTF` (the error text passed back) |

**Volume (test host):**
- Reports server start: `rwserver_diagnostic.log` +250 KB, each engine
  log +30 KB.
- One good job: engine log +32 KB.
- One failed job (with the three retries): engine log +26 KB, server log
  +52 KB.

At 10 MB per file and 100 MB per log, a busy server rotates the interesting
part away within minutes. Hence: reproduce once, collect, set it back.

### 4.2 Passwords and personal data in the trace

Checked on the test host against the real credentials of the test job:

- `userid` appears as `user@//host:port/service` – **without the
  password** (Reports drops it); the string `user/password@` was found in
  none of the logs.
- `authid` appears with the user name only; the repository password in the
  configuration dump appears as `value="csf:..."`.
- The **report parameters** of the command line are logged in full, as
  are the client address (`REMOTE_ADDR`) and the LDAP user searches in
  `repserver01.out`. Treat a trace like the data it contains: do not mail
  it around unchecked, delete it after the analysis.

---

## 5. What no longer works in 14.1.2

| Old way (10g / 11g sources) | 14.1.2 | Proof |
|---|---|---|
| `<trace traceFile=… traceOpts=… traceModule=…/>` in `rwserver.conf` | **commented out** in `$ORACLE_HOME/reports/dtd/rwserverconf.xsd` (like `jobRecovery`) | xsd of the test host |
| `traceopts=` / `tracefile=` / `tracemode=` in the rwservlet URL or a `cmdkey` | **`REP-50125: Incorrect value specified for traceopts parameter`** for every value (`TRACE_ALL`, `trace_all`, `TRACE_ERR`, `(TRACE_ERR,TRACE_SQL)`), returned in 6 ms – rwservlet rejects it before a job exists; `tracefile=` alone is accepted, but no file is written | live 2026-11-17 |
| `trace`, `traceopts` in `rwservlet.properties` | commented out in `rwservlet.xsd` | [reports_rwservlet_properties.md](reports_rwservlet_properties.md) |
| job-level trace of one report on the server | does not exist since 11g – Oracle: "In 11g, job level tracing for an individual report does not exist" | Oracle 12.2.1.3 §24.2.5 |

What remains for **one** report: run it with `rwrun` and `TRACEOPTS`
(`TRACE_ALL`, `TRACE_ERR`, `TRACE_SQL`, `TRACE_PLS`, `TRACE_PRF`, `TRACE_APP`
…), same `.rdf`, same DB user –
[`01-Run/rwrun_trace.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/01-Run/rwrun_trace.sh) does that, with the DB
password in a `cmdfile` instead of the command line, optionally with
`oracle.reports.runtime` on `TRACE:32` and the ADR incidents collected
([01-Run/README.md §5](../01-Run/README.md)). `LOGFILE=` is deprecated
(`REP-34551`).

---

## 6. Typical errors – which log, which level

| Message to the user | Look at | Usually enough |
|---|---|---|
| `REP-501` / `REP-0501` cannot connect | `rwEng-N`: the `ORA-` line below it (`ORA-12162`, `ORA-12514`, `ORA-01017`, `ORA-28000`) | default level |
| `REP-56132` access denied | does the file exist / spelling? then `<folderAccess>` ([reports_server_image_handling.md](reports_server_image_handling.md)) | default level |
| `REP-69` internal error | the lines **before** it in `rwEng-N`; `INCIDENT_ERROR` block with the Java stack | default, else engine `TRACE:16` |
| `REP-1924` / wrong fonts in the PDF | `CEngine:FontRevamp` lines in `rwEng-N` | engine `TRACE:32` ([04-ReportsFonts](../04-ReportsFonts/README.md)) |
| mail / distribution errors | `rwserver_diagnostic.log` (`MailService`, `javax.mail`) | server `TRACE:32` ([reports_mail_handling.md](reports_mail_handling.md)) |
| job hangs / waits in the queue | `rwserver_diagnostic.log` `JobManager` / `EngineManager` | server `TRACE:16` |
| report slow | `rwrun` with `TRACEOPTS=TRACE_PRF` (Reports time vs ORACLE time) | `rwrun_trace.sh` |
| engine crashes, no log line | ADR incidents, `repserver01.out` | – ([reports_engine_architecture.md](reports_engine_architecture.md)) |
| `REP-52262` diagnostic output disabled | intended – details in the logs above | – |
| `REP-50125` … traceopts | URL trace parameter – not supported, remove it | – |

---

## Sources

- Oracle Reports 12.2.1.3 *Publishing Reports to the Web* (the 14.1.2
  library has no own Reports books and links these):
  §24.2.1 Log Files, §24.2.3 Logging-Related WLST Commands, **§24.2.5
  Tracing Report Execution** with Table 24-3 –
  <https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_tune002.htm>
  (read 2026-11-17); Appendix D Troubleshooting –
  <https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_trouble.htm>
- 14.1.2 home of the test host: `$ORACLE_HOME/reports/dtd/rwserverconf.xsd`
  (`trace` commented out), `logging.xml` of `repserver01`.
- Live tests on the test host 2026-11-17 (sections 1.1, 4, 5); test host
  afterwards back in its starting state (`logging.xml` byte-identical,
  Reports server running).
- Library: [03-Logs/README.md](../03-Logs/README.md),
  [01-Run/README.md](../01-Run/README.md) (`rwrun_trace.sh`),
  [reports_rwservlet_properties.md](reports_rwservlet_properties.md).
