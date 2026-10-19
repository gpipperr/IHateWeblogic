# 01-Run – Start/Stop, WLST, Reports Server

Scripts for operating a running Oracle Forms/Reports domain: component
management, interactive WLST access, Reports Server status, single report
runs with trace.

**Role: analyse + fix an existing environment** (see the folder roles in the
[root README](../README.md#folder-roles)). Background – which process is
started by whom (AdminServer, Node Manager, system components):
[weblogic_middleware_architecture.md](../80-FMW-Architecture/weblogic_middleware_architecture.md);
Reports server, engines and `rwrun`:
[report_engine_architecture.md](../80-FMW-Architecture/report_engine_architecture.md).

---

## 1. Overview

| Script | Status | Purpose |
|---|---|---|
| `startStop.sh` | ✅ implemented | Component status table; start/stop NM, WLS, Reports servers, OHS |
| `wlst_connect.sh` | ✅ implemented | Interactive WLST shell with auto-login |
| `rwserver_status.sh` | ✅ implemented | Engine pool, job queue, rwservlet HTTP status (`--auth` for secured servers) |
| `reports_server_lib.sh` | sourced | Shared Reports helpers (`rws_*`): component `rwserver.conf`, report engine attributes, server/engine PIDs, `getserverinfo` with `authid` – also used by `05-ReportsPerformance/` |
| `rwrun_trace.sh` | ✅ implemented | Run one report with `rwrun` + trace (TRACEOPTS, optional ODL `TRACE:32`), collect output/trace/log excerpt/ADR incidents |

All scripts source `environment.conf`. Run `00-Setup/init_env.sh` first
if `environment.conf` does not exist yet.

Review 2026-10-19: status table, `rwserver_status.sh` (`--auth auto/none`),
`rwrun_trace.sh` and the dry-runs re-tested live; `rwserver_status.sh` now
uses `reports_server_lib.sh` (output unchanged); AdminServer port 7001 shown;
README sections / WLST examples / references corrected.

---

## 2. startStop.sh

### Usage

```bash
# Show component status (read-only, no credentials needed)
./01-Run/startStop.sh
./01-Run/startStop.sh list

# Start / stop a single component (dry-run without --apply)
./01-Run/startStop.sh start AdminServer  --apply
./01-Run/startStop.sh stop  WLS_REPORTS  --apply
./01-Run/startStop.sh start NodeManager  --apply
./01-Run/startStop.sh stop  repserver01  --apply   # Reports server component

# Start / stop all components in the correct sequence
./01-Run/startStop.sh start-all  --apply
./01-Run/startStop.sh stop-all   --apply
```

### Component types

Servers are started the way the Node Manager knows about them (since
2026-10-16) – the mechanism depends on what is set up:

| Situation | ADMIN / MANAGED / REPORTS start | stop | `start-all` / `stop-all` |
|---|---|---|---|
| **Autostart configured** (`$ORACLE_BASE/admin/<domain>/ctrl/fmw_ctl.sh` from `30-configure_autostart.sh`) | `fmw_ctl.sh start <name>` | `fmw_ctl.sh stop <name>` | `fmw_ctl.sh start\|stop all` (+ note on the systemd unit state) |
| NM running, no autostart | AdminServer: `nmStart`; managed: WLST `start()` via the AdminServer (NM-controlled) | WLST `shutdown()` | per component, as below |
| NM not running | start scripts (table below) | WLST `shutdown()` | per component |

`fmw_ctl.sh` uses the encrypted WLST keyfiles of the autostart – no password
needed. Table of the plain mechanisms (NM not running / no autostart):

| Type | Components | Start mechanism | Stop mechanism |
|---|---|---|---|
| `NM` | NodeManager | `bin/startNodeManager.sh` (nohup) | `kill <PID>` |
| `ADMIN` | AdminServer | `bin/startWebLogic.sh` (nohup) | WLST `shutdown()` |
| `MANAGED` | WLS_REPORTS, WLS_FORMS | `bin/startManagedWebLogic.sh` (nohup) | WLST `shutdown()` |
| `REPORTS` | repserver01, … | WLST `nmConnect` + `nmStart(serverType='ReportsServerComponent')` | WLST `nmKill` (fallback: `kill <PID>` if the NM does not know the process) |
| `OHS` | ohs1, … | `bin/startComponent.sh` | `bin/stopComponent.sh` |

`REPORTS` (since 2026-10-15): the Reports server runs as a Node Manager
system component – the NM must be running. `startComponent.sh` /
`stopComponent.sh` do the same, but prompt for the NM password unless a WLST
user config was stored; the script connects with the admin credentials from
`weblogic_sec.conf.des3` (`11-oracle_nodemanager.sh` sets the NM credentials
to the same). `restartComponent.sh` is not supported for Reports servers –
use stop + start. Status: process `rwserver server=<name>`.
`ReportsToolsComponent` and `FORMS` system components are configuration only
(no own process) and are not listed.

Components are discovered automatically from:

- `$DOMAIN_HOME/config/config.xml` → WLS server list, Reports server
  system components (`<component-type>ReportsServerComponent</component-type>`)
- `$DOMAIN_HOME/nodemanager/nodemanager.properties` → NodeManager port
- `$DOMAIN_HOME/system_components/OHS/` → OHS instances (if present)

### Start sequence

```
1. NodeManager    (NM)       – wait ~15 s
2. AdminServer    (ADMIN)    – wait ~60 s
3. Managed servers (MANAGED) – WLS_REPORTS, WLS_FORMS, …
4. Reports servers (REPORTS) – via Node Manager
5. OHS            (OHS)      – independent of WLS
```

`start-all` skips components already `RUNNING`.

### Stop sequence

```
1. OHS            (OHS)      – independent of WLS
2. Reports servers (REPORTS) – nmKill via Node Manager
3. Managed servers (MANAGED) – shutdown via WLST (requires AdminServer up)
4. AdminServer    (ADMIN)    – shutdown via WLST
5. NodeManager    (NM)       – kill
```

`stop-all` skips components already `STOPPED`.

`start AdminServer` / `start-all` rename a leftover
`$DOMAIN_HOME/config/fmwconfig/ovd/default/ovd.lok` (libOVD lock left by the
Reports server) before the AdminServer starts – otherwise the EM user search in
"Add Principal" stays empty
([em_principal_search_libovd.md](../80-FMW-Architecture/em_principal_search_libovd.md)).

### Column `Ctrl` – started by the Node Manager?

For running servers and Reports components the status table shows who
started them: `NM` (the Node Manager JVM is an ancestor of the process) or
`script` (started with `startWebLogic.sh` / `startManagedWebLogic.sh` past a
running NM). For `script` the script warns:

```
WARN  Running OUTSIDE the Node Manager: WLS_FORMS
```

Such a server is `SHUTDOWN` for the NM: `fmw_ctl.sh` / `systemctl` skip it
and the next `nmStart` fails on the occupied port (seen 2026-10-15 with the
old `startStop.sh`). Fix: `stop <name> --apply` (shut down through the
AdminServer – `fmw_ctl.sh` would skip it; `stop-all` does this first), then
`start <name> --apply` (now through the NM). Tested 2026-10-16 with
WLS_FORMS: `script` → stop → start via `fmw_ctl.sh` → `NM`.

After a manual `stop-all` the systemd unit `fmw-<domain>.service` still shows
`active (exited)` – `systemctl start` then does nothing, use
`systemctl restart`.

### Dry-run

Without `--apply` all write operations (start/stop) are shown as a
preview only. No process is started or stopped.

```bash
# Preview what start-all would do:
./01-Run/startStop.sh start-all
```

### Status detection

The status column shows:

| Status | Meaning |
|---|---|
| `RUNNING` (green) | Process found via `pgrep` **or** port is listening |
| `STOPPED` (red) | No process, port not listening |
| `UNKNOWN` (yellow) | Only shown briefly before first refresh |

Run as root or as the Oracle user to see all process names (`pgrep` may
miss processes owned by other users).

Port column: `<listen-port>` from `config.xml`; a server without it uses the
WebLogic default **7001** (the AdminServer of our domains – shown as `-`
before 2026-10-19). Start output of servers started by script goes to
`log/<date>/start_<name>_<time>.log` (`$DIAG_LOG_DIR`).

---

## 3. wlst_connect.sh

### Usage

```bash
./01-Run/wlst_connect.sh
./01-Run/wlst_connect.sh --url t3://adminhost:7001
./01-Run/wlst_connect.sh --user wlsadmin
```

### Options

| Option | Description |
|---|---|
| `--url T3_URL` | Override AdminServer URL (default: from `weblogic_sec.conf.des3`) |
| `--user NAME` | Override WebLogic admin username |

### Prerequisites

```bash
# Store credentials once (machine-local encryption):
./00-Setup/weblogic_sec.sh --apply
```

### How it works

1. Loads credentials from `weblogic_sec.conf.des3` via
   `load_weblogic_password()` (openssl des3 + machine UUID key).
2. Optionally sources `$DOMAIN_HOME/bin/setDomainEnv.sh`.
3. Writes a temp Python bootstrap (`/tmp/wlst_connect_XXXXX.py`, mode 600)
   with only the `connect()` call – the password is passed via env vars,
   never stored in the file and never on the command line.
   (`/proc/<pid>/environ` of the WLST JVM is readable only by the same user
   and root; `startStop.sh` uses the same pattern for its WLST calls.)
4. Pipes bootstrap to WLST stdin, then forwards terminal input.
   WLST stays interactive after the auto-connect.
5. On exit: temp file and password env vars are removed by the EXIT trap.

### Note on readline

Because stdin is a pipe (bootstrap + forwarded terminal), readline
history and tab completion may be limited. All WLST commands work
normally.

### Typical WLST commands after connect

Reports engines are not WLS MBeans – their state comes from
`rwserver_status.sh` (`getserverinfo`), not from WLST.

```python
# Domain overview
ls()
domainRuntime()
ls()

# State of a server (also managed servers, via the AdminServer)
state('WLS_REPORTS')
state('WLS_FORMS')

# Lifecycle of all servers
domainRuntime()
cd('ServerLifeCycleRuntimes')
ls()

# Thread dump of a server (e.g. hanging WLS_FORMS)
threadDump(serverName='WLS_FORMS')

# Exit
exit()
```

---

## 4. rwserver_status.sh

### Usage

```bash
./01-Run/rwserver_status.sh
./01-Run/rwserver_status.sh --port 9002
./01-Run/rwserver_status.sh --server repserver01
./01-Run/rwserver_status.sh --auth admin
```

### Options

| Option | Description |
|---|---|
| `--port N` | WLS_REPORTS listen port (default: auto-detect from config.xml) |
| `--server NAME` | Reports Server name (default: `REPORTS_SERVER_NAME`, else the `ReportsServerComponent` in config.xml) |
| `--auth MODE` | `authid` for `getserverinfo`: `auto` (default), `mon`, `admin`, `none` |

### Authentication (`--auth`, since 2026-10-17)

`getserverinfo` needs an `authid` on a secured/hardened Reports server –
without it the servlet answers HTTP 499 (login) or `REP-52262`.

| Mode | User | Source |
|---|---|---|
| `auto` with `REPORTS_SECURITY=ldap` | `monUser` (role `RW_MONITOR`), fallback admin | `reports_users.conf.des3` (`12-`) |
| `auto` with `REPORTS_SECURITY=identifier` | Reports server admin (`<identifier>`), fallback `monUser` | `reports_admin_sec.conf.des3` (`13-`/interview) |
| `mon` / `admin` | only that user | as above |
| `none` | no `authid` (shows what an anonymous caller gets) | – |

The password is passed to `curl` as a config on stdin (`-K -`,
`data-urlencode`) – it never appears in the process list, the output or the
log (output shows `user/****`). REP errors in the answer are reported with
a hint (`REP-52262`, `REP-50171`, `REP-56071`). Live 2026-10-17: `auto`
(monUser) and `admin` → full server info, `none` → HTTP 499.

### What it shows

| Section | Source | Content |
|---|---|---|
| Engine Configuration | `rwserver.conf` of the Reports server component (`components/ReportsServerComponent/<name>/`) | minEngine, maxEngine, maxIdle of the **report** engine (not the URL engine `rwURLEng`) |
| Process Status | `pgrep` | WLS managed server PID, `rwserver server=<name>` PID, engine count = Java child processes of `rwserver` (14.1.2 has no `rwengine` process name) |
| HTTP Engine Status | rwservlet | URL, `authid` used (`user/****`), HTTP code / REP error with hint |
| Server Info | `getserverinfo` | name, version, PID, running since / uptime, secured, average auth time, max queue size |
| Engine Pool | `getserverinfo` | per engine id (`rwEng`, `rwURLEng`): active / running / busy / idle; per instance: PID, status (IDLE/BUSY/DEAD), job id, idle time, jobs run, life left (`engLife`), NLS |
| Performance | `getserverinfo` | successful / current / future / transferred / failed / long running / runaway jobs, average response / elapsed / queuing time |
| Connections | `getserverinfo` | connections used / available, max / avg engines used |

Evaluation of these numbers (failure rate, queuing share, pool at
`maxEngine`, server logs): `05-ReportsPerformance/engine_perf_analyse.sh`.
All `getserverinfo` / `rwserver.conf` helpers are in `reports_server_lib.sh`
(shared with 05, see section 1).

### Two-layer design

`startStop.sh` answers: **Is WLS_REPORTS up?** (JVM process / port)

`rwserver_status.sh` answers: **Is the Reports engine working?**

- A running `WLS_REPORTS` JVM does not guarantee a functional engine pool.
- Failed engine spawns, misconfigured fonts, or a full job queue will
  not appear in `startStop.sh` but are visible here.

### Relation to startStop.sh

| Check | startStop.sh | rwserver_status.sh |
|---|---|---|
| WLS_REPORTS JVM running | yes | yes (pgrep) |
| Reports server `rwserver` running | yes (type `REPORTS`) | yes |
| engine process count | no | yes |
| Engine idle/busy state | no | yes (HTTP) |
| Job queue pending/failed | no | yes (HTTP) |
| Configured min/max engines | no | yes (rwserver.conf) |

### HTTP endpoint

The script queries:
```
http://<host>:<port>/reports/rwservlet/getserverinfo?server=<name>&statusformat=XML
```
(`getserverinfo` is part of the **path**, not a query flag.)

This requires `WLS_REPORTS` to be running and `curl` to be installed.
If the endpoint is not reachable, the process section still shows
`pgrep`-based engine counts.

---

## 5. rwrun_trace.sh

Runs **one** report in-process with `rwrun` (no Reports server, no
rwservlet) – to find out whether a problem is in the report itself (SQL,
PL/SQL, fonts, parameters) or in the server/servlet path. How `rwrun`
differs from the server path (own in-process server from `rwbuilder.conf`,
embedded JVM, reptools1 fonts and log, Oracle: "for testing purposes
only"): [report_engine_architecture.md §5.1](../80-FMW-Architecture/report_engine_architecture.md#51-rwrun--a-report-without-rwservlet-and-without-reports-server).

```bash
./01-Run/rwrun_trace.sh --report test_dual.rdf
./01-Run/rwrun_trace.sh --report /path/my.rdf --params "P_DEPT=10 P_YEAR=2026" --format pdf
./01-Run/rwrun_trace.sh --report my.rdf --traceopts TRACE_SQL
./01-Run/rwrun_trace.sh --report my.rdf --odl --apply     # + ODL TRACE:32
```

| Option | Meaning |
|---|---|
| `--report FILE` | `.rdf` / `.rep` / `.xml`, absolute or searched in `REPORTS_CUSTOMER_DIR` / `REPORTS_PATH` |
| `--format FMT` | `desformat` (default `pdf`) |
| `--params "..."` | report parameters `NAME=VALUE`, blank-separated |
| `--traceopts OPT` | `TRACE_ALL` (default), `TRACE_ERR`, `TRACE_SQL`, `TRACE_PLS`, `TRACE_PRF`, `TRACE_APP`, … |
| `--db-sec FILE` | DB credentials, default `test_db_sec.conf.des3` (`TEST_DB_USER`/`TEST_DB_PWD`) |
| `--odl` + `--apply` | logger `oracle.reports.runtime` of the ReportsTools instance → `TRACE:32` for this run; `logging.xml` is restored afterwards (also on Ctrl+C) |

How it works (findings 2026-10-14 / 16 / 17):

- Uses `$DOMAIN_HOME/reports/bin/rwrun.sh` (wrapper of the ReportsTools
  instance – sets `REPORTS_CLASSPATH`, `libjvm` path,
  `REPORTS_DEFAULT_DISPLAY=YES`; no X display). `$ORACLE_HOME/bin/rwrun`
  alone crashes (SIGSEGV/SIGABRT, missing environment).
- `userid` is passed in a `cmdfile=` (mode 600, removed after the run, also
  on Ctrl+C; result directory mode 700) –
  the password never appears on the command line / in `ps`; DB via a
  temporary TNS alias (`TNS_ADMIN` in the work directory).
- `LOGFILE` is deprecated in 14.1.2 (`REP-34551`) – not used; the console
  output is kept instead.

Result directory `log/<date>/rwrun_trace_<timestamp>/`:

| File | Content |
|---|---|
| `output.<fmt>` | the report output |
| `rwrun.trc` | rwrun trace (`TRACEOPTS`) |
| `console.txt` | stdout/stderr of rwrun |
| `runtime_diagnostic_excerpt.log` | new lines of `servers/<reptools>/logs/runtime_diagnostic.log` (ODL; with `--odl` full `TRACE:32` detail, stack traces, REP codes) |
| `adr_incidents.txt` | new ADR incidents (`~/oradiag_<user>/…/incident/`) = native crash |

The summary lists the `REP-`/`ORA-` messages found. Live 2026-10-17:
`test_dual.rdf` → PDF in 3 s; with `--odl` 482 log lines (339 TRACE);
broken SQL → `ORA-00942` / `REP-0583`, FAIL; interrupt during `--odl` →
`logging.xml` byte-identical afterwards. Re-tested 2026-10-19: PDF 9307
bytes, no `.cmdfile` left in the result directory.

## 6. Troubleshooting

### startStop.sh – managed server won't stop (AdminServer down)

```
Symptom: WLST shutdown fails for WLS_REPORTS / WLS_FORMS
Cause:   AdminServer must be running to shut down managed servers via WLST
Fix:     Stop the managed server by PID, then restart AdminServer
         pgrep -a -f "Dweblogic.Name=WLS_REPORTS"
         kill <PID>
```

### startStop.sh – start-all stalls at NodeManager

```
Symptom: start-all hangs after "NodeManager start initiated"
Cause:   startNodeManager.sh blocked (e.g. port 5556 already in use)
Fix:     Check port 5556:   ss -tlnp | grep 5556
         Check the start output: tail log/<date>/start_NodeManager_*.log
         NM log:            $DOMAIN_HOME/nodemanager/nodemanager.log
```

### startStop.sh – STOPPED for all components though domain is running

```
Symptom: All components show STOPPED even though WebLogic is up
Cause A: Running as a different user – pgrep misses processes of other users
         Fix: Run as the oracle user: su - oracle -c "..."
Cause B: DOMAIN_HOME wrong in environment.conf
         Fix: Re-run 00-Setup/init_env.sh to regenerate environment.conf
```

### wlst_connect.sh – "User failed to be authenticated"

```
Symptom: WLST connects but login fails
Cause:   Stored password outdated or wrong username
Fix:     Re-run 00-Setup/weblogic_sec.sh --apply to update credentials
```

### wlst_connect.sh – wlst.sh not found

```
Symptom: FAIL wlst.sh not found: /u01/oracle/fmw/oracle_common/common/bin/wlst.sh
Cause:   FMW_HOME is wrong or FMW is not installed at that path
Fix:     Correct ORACLE_HOME in environment.conf, then re-run init_env.sh
```

---

## 7. Related Scripts

| Script | Purpose |
|---|---|
| `00-Setup/init_env.sh` | Detect FMW/Domain paths, generate `environment.conf` |
| `00-Setup/weblogic_sec.sh` | Store WebLogic credentials (used by wlst_connect and startStop) |
| `02-Checks/port_check.sh` | Verify ports before start; complements status table |
| `03-Logs/tail_logs.sh` | Live-tail server logs during start/stop |
| `05-ReportsPerformance/engine_perf_settings.sh` | Engine parameters vs. Oracle's tuning rules, CPUs, RAM (`--apply`) |
| `05-ReportsPerformance/engine_perf_analyse.sh` | Load analysis: failure rate, queuing share, pool usage, Reports server logs |
| `06-FormsDiag/forms_perf_analyse.sh` | Forms: `frmweb` per config section, memory, Forms logs |
| `07-Maintenance/81-`/`82-patch_*.sh` | Patching: `stop-all --apply` first – the patch gate refuses while any process from `$ORACLE_HOME` runs |
| `09-Install/30-configure_autostart.sh` | systemd unit + `fmw_ctl.sh` that `startStop.sh` delegates to |

---

## 8. References

All checked 2026-10-19 (HTTP 200, title matches) – the three links listed
here before were 404.

- WLST Command Reference for Oracle WebLogic Server 14c (14.1.2.0.0):
  https://docs.oracle.com/en/middleware/fusion-middleware/weblogic-server/14.1.2/wlstc/
- Administering Node Manager for Oracle WebLogic Server 14c (14.1.2.0.0):
  https://docs.oracle.com/en/middleware/fusion-middleware/weblogic-server/14.1.2/nodem/index.html
- Administering Oracle Fusion Middleware 14c (14.1.2.0.0) (starting / stopping, system components):
  https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/asadm/index.html
- Publishing Reports 12.2.1.3 – Starting and Stopping Reports Server:
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_strt001.htm
- Publishing Reports 12.2.1.3 – Overview of Oracle Reports Components (`rwrun`, `rwclient`):
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla002.htm
