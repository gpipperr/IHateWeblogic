# 05-ReportsPerformance – Oracle Reports Engine Performance

**Role: analyse + fix an existing environment** (see the folder roles in the
[root README](../README.md)). On a new installation
`09-Install/13-oracle_setup_reports.sh` sets the values and
`09-Install/docs/90-oracle_validate.md` calls these scripts read-only as
acceptance; `10-Monitoring/` uses them as a data source.

Configuration review and load analysis of the **standalone Reports server**
(system component, e.g. `repserver01`) and its engines.
All scripts source `environment.conf`, log to `log/<date>/` and are
read-only by default (`--apply` only in `engine_perf_settings.sh`).

Background (why the server/engine split, which process uses which JDK,
Oracle's tuning rules): [report_engine_architecture.md](../80-FMW-Architecture/report_engine_architecture.md).

---

## 1. Overview – and what is NOT here

| Script | Question it answers |
|---|---|
| `engine_perf_settings.sh` | Are the engine/queue/cache parameters sensible for this host (CPUs, RAM) and in line with `environment.conf`? `--apply` changes the report engine |
| `engine_perf_analyse.sh` | How does the server cope with its load: failure rate, queuing share, pool usage vs. `maxEngine`, engine memory, REP-/ORA- errors in the Reports server logs? |

Not duplicated here – use the existing scripts:

| Need | Script |
|---|---|
| Is the Reports server running, which engines, raw `getserverinfo` | `01-Run/rwserver_status.sh` |
| Search all logs for an error | `03-Logs/grep_logs.sh 'REP-'` |
| Run one report outside the server (crash / trace) | `01-Run/rwrun_trace.sh` |
| WebLogic JVM heap / GC of `WLS_REPORTS` (the servlet, not the engines) | `02-Checks/weblogic_performance.sh` |
| `ORA-12154` / `ORA-12162` in reports – which `tnsnames.ora` do the engines use? | `02-Checks/tns_admin_check.sh` |

All three Reports scripts share `01-Run/reports_server_lib.sh` (find the
component's `rwserver.conf`, read the **report** engine, server/engine PIDs,
`getserverinfo` with `authid`). Before 2026-10-19 the 05 scripts had their
own older copies of these helpers and evaluated the wrong file and engine
(see section 5).

---

## 2. Recommended order

```
1. Is it running at all?        ./01-Run/rwserver_status.sh
2. Configuration review         ./05-ReportsPerformance/engine_perf_settings.sh
3. Load analysis                ./05-ReportsPerformance/engine_perf_analyse.sh
                                (best after a period of real load – the
                                 averages cover everything since server start)
4. Change engine parameters     ./05-ReportsPerformance/engine_perf_settings.sh --apply
   + restart                    ./01-Run/startStop.sh stop  repserver01 --apply
                                ./01-Run/startStop.sh start repserver01 --apply
5. Analyse again under load
```

---

## 3. engine_perf_settings.sh

```bash
./05-ReportsPerformance/engine_perf_settings.sh
./05-ReportsPerformance/engine_perf_settings.sh --apply
./05-ReportsPerformance/engine_perf_settings.sh --server repserver01
./05-ReportsPerformance/engine_perf_settings.sh --conf /path/to/rwserver.conf
```

| Option | Description |
|---|---|
| `--apply` | Interactive dialog, backup, write the report engine element |
| `--server NAME` | Reports server component (default `REPORTS_SERVER_NAME`, else the `ReportsServerComponent` in `config.xml`) |
| `--conf PATH` | Evaluate/modify another file (e.g. a copy for a test) |

File: `config/fmwconfig/components/ReportsServerComponent/<name>/rwserver.conf`.
`RWSERVER_CONF` in `environment.conf` points to the in-process server of
`WLS_REPORTS` – shown as INFO, not used.

| Section | Content / evaluation |
|---|---|
| Report Engine | `initEngine`, `minEngine`, `maxEngine`, `engLife`, `maxIdle`, `callbackTimeOut`, `engineResponseTimeOut`, `jvmOptions` of the engine used by `<job jobType="report">` (`rwEng`) – **not** the URL engine `rwURLEng`. WARN: `minEngine=0` (cold start), `minEngine > initEngine`, `maxEngine <= 1`, `maxEngine > 4 × CPUs`, `engLife > 1000`; FAIL: `maxEngine < minEngine/initEngine`. INFO: no `engineResponseTimeOut`, URL engine active |
| Engine JVM Heap | `-Xmx` from `jvmOptions`, else from the running engines (`/proc/<pid>/cmdline`), RSS per engine; `maxEngine × -Xmx` against MemAvailable + RSS of the running engines (WARN > 80 %) |
| Queue, Connections, Cache | `maxQueueSize`, `maxConnect`, `idleTimeOut`, `cacheSize`, cache directory (size, files) |
| rwserver.conf vs. environment.conf | `REPORTS_ENGINE_INIT/MIN/MAX/LIFE/MAX_IDLE/JVM_OPTIONS/RESPONSE_TIMEOUT`, `REPORTS_MAX_CONNECT`, `REPORTS_MAX_QUEUE`, `TNS_ADMIN` (`<envVariable>` of the engines) – WARN on drift. All places of `TNS_ADMIN` incl. `reports.sh` and the running processes: `02-Checks/tns_admin_check.sh` ([why three places](../80-FMW-Architecture/report_engine_architecture.md#52-oracle-net--three-places-for-one-tns_admin)) |
| Live Engine Processes | `rwserver server=<name>` PID, engines = its child processes, count vs. min/max |

The rules and Oracle's numbers behind the checks:
[report_engine_architecture.md §6](../80-FMW-Architecture/report_engine_architecture.md#6-performance-parameters-rwserverconf).
Live 2026-10-19: without `jvmOptions` the engines run with `-Xmx256M`
(**confirmed (live)**, engine command line).

**`--apply`** asks for `initEngine`, `minEngine`, `maxEngine`, `engLife`,
`maxIdle`, `engineResponseTimeOut` (minutes) and the engine `-Xmx`, validates them (numbers, `max >= min/init`),
shows the change list, asks for confirmation, then:

1. `backup_file` of `rwserver.conf`
2. changes **only the report engine element** (`rws_set_engine_attr`, python3;
   missing attributes are added, `rwURLEng` stays untouched)
3. writes every changed value also to `environment.conf` (with backup):
   `REPORTS_ENGINE_INIT/MIN/MAX`, `REPORTS_ENGINE_LIFE`,
   `REPORTS_ENGINE_MAX_IDLE`, `REPORTS_ENGINE_JVM_OPTIONS`,
   `REPORTS_ENGINE_RESPONSE_TIMEOUT` (appended if
   missing) – `09-Install/13-oracle_setup_reports.sh --apply` regenerates
   `rwserver.conf` from these values, the tuning survives
4. prints the restart command – the change takes effect after a restart of
   the Reports server component

---

## 4. engine_perf_analyse.sh

```bash
./05-ReportsPerformance/engine_perf_analyse.sh
./05-ReportsPerformance/engine_perf_analyse.sh --lines 5000
./05-ReportsPerformance/engine_perf_analyse.sh --auth admin
./05-ReportsPerformance/engine_perf_analyse.sh --no-http
```

| Option | Description |
|---|---|
| `--server NAME` | Reports server component |
| `--port N` | `WLS_REPORTS` listen port (default from `config.xml`) |
| `--auth MODE` | `authid` for `getserverinfo`: `auto` (default), `mon`, `admin`, `none` – same as `rwserver_status.sh` ([01-Run/README.md §4](../01-Run/README.md)) |
| `--lines N` | Last N lines per log file (default 1000) |
| `--no-http` | Only processes and logs |

| Section | Evaluation |
|---|---|
| Jobs | successful/failed/current/long running/runaway; failure rate ≥ 5 % → FAIL ("failing reports, not a tuning question"), runaway > 0 → FAIL |
| Response Times | `averageResponseTime`, `averageElapsedTime`, `avgQueuingTime`; **queuing share** = queuing / response ≥ 50 % → WARN. 14.1.2 reports `averageElapsedTime=0.0` (**confirmed (live)** 2026-10-19), so the old rule "queuing > elapsed" cannot be used |
| Job Run Times | `showjobs` (always with the Reports server admin `<identifier>` – the monitoring user sees only its own jobs): number of past jobs, longest and 95th percentile run time from `timingInfo`, vs. `engineResponseTimeOut` – unset → WARN, longest job ≥ timeout → WARN (the server would kill it); proposal 2 × longest job, ≥ 5 min (`rws_ert_proposal`). Test host 2026-10-23: 68 jobs, longest 1 s → 5 |
| Engine Pool Usage | `maxEnginesUsed` / `avgEnginesUsed` vs. `maxEngine` (pool reached → WARN), connections, per instance status/jobs/life left/current job time, DEAD → FAIL |
| Engine Processes | RSS, `-Xmx`, uptime per engine process |
| Reports Server Logs | `servers/<repserver>/logs/rwserver_diagnostic.log` + `rwEng-N_diagnostic.log` (found via `03-Logs/log_locations.sh`): lines with ORA-/REP-/OutOfMemoryError, the five most frequent REP codes with an example |
| Recommendations | pool full → raise `maxEngine` (heap must fit); high queuing **without** full pool → cause is not `maxEngine` (engine start, failed jobs, retries); OOM → engine `-Xmx`; REP/failed jobs → fix the cause first; ORA → `db_connect_check.sh` |

Note: the job counters of `getserverinfo` include jobs from before the last
restart of the Reports server (live 2026-10-19: server up 20 min, engines had
run 1 job, counters showed 60) – **assumption**: the persisted job
repository is counted. Judge trends, not absolute numbers.

Where the logs are and why there are separate engine logs:
[03-Logs/README.md](../03-Logs/README.md),
[report_engine_architecture.md §5](../80-FMW-Architecture/report_engine_architecture.md#5-who-starts-what--and-what-the-consoles-show).
Typical REP codes from images/`folderAccess` (REP-56132, REP-108):
[report_server_image_handling.md](../80-FMW-Architecture/report_server_image_handling.md).
Slow first request / engine replacement after a crash:
[reports_user_local_ldap.md §7](../80-FMW-Architecture/reports_user_local_ldap.md).

---

## 5. Review 2026-10-19 – what was wrong before

| Problem (old 05 scripts) | Effect | Now |
|---|---|---|
| Used `RWSERVER_CONF` / first `rwserver.conf` found | evaluated the in-process server of `WLS_REPORTS`, not `repserver01` | component file via `reports_server_lib.sh` |
| Greedy attribute match over the whole file | showed `minEngine=0 maxEngine=1` of the URL engine | report engine only |
| `--apply` with `sed …/g` | would have changed **both** engines | python, report engine element only |
| `pgrep -f rwengine` | 14.1.2 has no `rwengine` process → "0 engines" | child processes of `rwserver` |
| `getserverinfo` without `authid` | HTTP 499 on the secured server, all HTTP sections empty | same `--auth` logic as `rwserver_status.sh` |
| Log scan of `WLS_REPORTS.log` | the Reports errors are in `servers/repserver01/logs/` | Reports server + engine logs |
| Integer comparison of `2134.06` / `grep -c … \|\| printf 0` | silent wrong results, "0\n0" and a bash error | awk compare, plain `grep -c` |
| `initTime`, `purgeTime`, `maxJobSize` | not attributes of the 14.1.2 `engine`/`cache` element | Oracle's attribute list (§6 of the architecture doc) |
| Cache dir `servers/WLS_REPORTS/tmp/cache` | does not exist | `cacheDir` property, else `$DOMAIN_HOME/reports/cache` (**confirmed (live)**: job outputs) |
| Restart hint `WLS_REPORTS` | the standalone server is a component | `startStop.sh stop/start <component>` |

---

## 6. Open items

- 10-Monitoring: `engine_perf_analyse.sh` as data source for the queue/pool
  KPIs ([10-Monitoring/README.md](../10-Monitoring/README.md)).

---

## 7. References

- Oracle Reports 12.2.1.3 "Publishing Reports", 24.3 Tuning Reports Server
  Configuration and 7.2.1.8 `engine` element – quoted and linked in
  [report_engine_architecture.md §6 / §10](../80-FMW-Architecture/report_engine_architecture.md)
- Related scripts: `01-Run/rwserver_status.sh`, `01-Run/reports_server_lib.sh`,
  `03-Logs/grep_logs.sh`, `02-Checks/db_connect_check.sh`,
  `07-Maintenance/backup_config.sh` (category `reports_comp`)
