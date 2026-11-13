---
title: "Monitoring Oracle Reports 14c with getserverinfo"
description: "Watch a standalone Oracle Reports 14.1.2 server from Nagios, Checkmk or Zabbix: getserverinfo XML of rwservlet, engine states, job counters, a monitor user."
---

# Monitoring the Reports server with `getserverinfo`

How to watch a standalone Oracle Reports 14.1.2 server from a monitoring
system (Nagios / Icinga / Checkmk, Zabbix, PRTG …). The source is the web
command `getserverinfo` of the rwservlet, which returns the state of the
server, its engines and its job counters as XML.

Measured on the test host on 2026-11-03: Reports 14.1.2 + QPR 39600348,
secured server (`securityId`), `monUser` with role `RW_MONITOR`.

Related:
- Security of the web commands: [reports_user_local_ldap.md](reports_user_local_ldap.md)
  and [81-reports_rwservlet_security.md](../09-Install/docs/81-reports_rwservlet_security.md).
- Engines and sizing: [reports_engine_architecture.md](reports_engine_architecture.md).
- Our own tools: [01-Run/rwserver_status.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/01-Run/rwserver_status.sh)
  (display) and
  [05-ReportsPerformance/engine_perf_analyse.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/05-ReportsPerformance/engine_perf_analyse.sh)
  (evaluation).

---

## 1. What `getserverinfo` can tell – and what not

The **standalone Reports server is not a WebLogic server.** The WebLogic
console and JMX know only `WLS_REPORTS`, and EM shows the server only as a
system component. Engine state, queue and job counters therefore come only
from the Reports server itself, and `getserverinfo` is the interface for
that ([reports_engine_architecture.md §5](reports_engine_architecture.md)).

```
 monitoring agent (on the Reports host)
        |  HTTP POST  server=..  statusformat=XML  authid=monUser/..
        v
 WLS_REPORTS :9002  /reports/rwservlet/getserverinfo     (rwservlet)
        |  CORBA (JDK ORB)
        v
 rwserver server=repserver01  (standalone Reports server, own JVM)
        |-- rwEng-0, rwEng-1 ...   report engines (Java child processes)
        `-- rwURLEng               URL engine
        |
        `-- secured server: checks monUser against the embedded LDAP of the
            AdminServer (jps-config-jse.xml -> idstore.ldap.embedded)
```

A successful answer proves the whole chain at once:
- `WLS_REPORTS` and the rwservlet are up;
- the servlet reaches the Reports server over CORBA;
- on a secured server, the AdminServer's LDAP answers the login.

**Not covered by `getserverinfo`** – check these separately (section 6):
- the content of the logs (`REP-`, `ORA-`, `OutOfMemoryError`);
- disk space of the cache and temp directories;
- whether a report renders correctly (fonts, images);
- the database that the reports query.

## 2. The request

### 2.1 Send everything as POST – never as URL parameters

**confirmed (live), 2026-11-03:** WebLogic writes the full `cs-uri` with the
query string into `$DOMAIN_HOME/servers/WLS_REPORTS/logs/access.log`
(`elf-fields ... cs-uri ...`). Every `getserverinfo?...&authid=monUser/<password>`
leaves the password in plain text in that log: 124 such lines were found on
the test host.

rwservlet accepts the same parameters as a form POST. Two results:

| Request | Result |
|---|---|
| all parameters in the POST body | `<serverInfo ...>` (works) |
| `server` / `statusformat` in the URL, only `authid` in the body | HTTP 200 but no XML – a POST ignores the query string |

So: **all parameters in the body, plain URL.**

```bash
curl -s --max-time 60 -K ~/.config/rwmon.curl \
     --data-urlencode "server=repserver01" \
     --data-urlencode "statusformat=XML" \
     http://localhost:9002/reports/rwservlet/getserverinfo
```

`~/.config/rwmon.curl` (mode `600`, owner = the monitoring agent user) holds
the one secret line:

```
data-urlencode = "authid=monUser/<MONUSER_PASSWORD>"
```

With `-K` the password appears neither in the process list (`ps`) nor in the
shell history nor in the access log.

> Our own [rwserver_status.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/01-Run/rwserver_status.sh) and
> [`engine_perf_analyse.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/05-ReportsPerformance/engine_perf_analyse.sh) (`rws_fetch_serverinfo` in [`reports_server_lib.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/01-Run/reports_server_lib.sh))
> use POST since 2026-11-03: the query string of the URL goes into the body
> as it is, `authid` via `data-urlencode`, all of it as a curl config on
> stdin. Live-tested with `--auth auto|mon|admin|none` and `showjobs`. Before
> that, `authid` was a GET parameter, out of `ps` but not out of
> `access.log`.

Report requests work the same way: `cmdkey=default&report=...&desformat=pdf`
plus `userid=` as POST returned a PDF (live, 2026-11-03). Otherwise the DB
password of `userid=` lands in the access log too.

### 2.2 Who asks, from where

| Question | Recommendation |
|---|---|
| user | `monUser` with role `RW_MONITOR` (only `getserverinfo`, `showjobs` …). Not `weblogic`, not the `<identifier>` admin – exception: a server without `securityId`, where only the `<identifier>` admin gets an answer (`REP-52262` otherwise, doc 81 §7) |
| from where | **locally on the Reports host** (NRPE, Checkmk agent, Zabbix agent, PRTG SSH script sensor) against `http://localhost:9002`. Nginx blocks the web commands from outside (Reports_security.txt 2.3), and that should stay so |
| how often | every 1–5 minutes. Each request is light (one CORBA call) |
| timeout | 60 s. The first request after a start of the Reports server can take long: before the ORB fix it took 242 s ([reports_user_local_ldap.md §7](reports_user_local_ldap.md)), after the fix seconds |

### 2.3 Answers that are not XML

| Answer | Meaning |
|---|---|
| HTTP 200 + `<serverInfo ...>` | OK |
| HTTP 200 + `<error code="50171" .../>` (note: the code has **no** `REP-` prefix – grep for `code="…"`, not `REP-…`) | wrong password, **or the AdminServer (LDAP) is down**, or `jps-config-jse.xml` wrong |
| HTTP 200 + `<error code="56071" .../>` | user known, but without `RW_MONITOR` |
| HTTP 200 + `<error code="52262" .../>` | server not secured and caller is not the `<identifier>` admin |
| HTTP 499 + HTML (title "Oracle SSO") | no `authid` sent – a login page |
| connection refused / timeout | `WLS_REPORTS` down or hanging |

**Trap:** most errors come with **HTTP 200**. A monitor that checks only the
HTTP status reports "green" while no user can log in. Always evaluate the
content (`<error>` or `<serverInfo>`).

## 3. The XML – a real answer

Test host, 2026-11-03, about 5 hours after the start of the Reports server
(demo host name, see [Demo Data](../README.md#demo-data)).

```xml
<?xml version = '1.0' encoding = 'UTF-8' standalone = 'yes'?>
<serverInfo name="repserver01" version="14.1.2.0.0">
   <host>orafusion01.pipperr.local</host>
   <processId>217406</processId>
   <startTime>1793697621935</startTime>
   <queue maxQueueSize="4000"/>
   <engine id="rwEng" activeEngine="2" runningEngine="0" totalBusyEngines="0" totalIdleEngines="2">
      <engineInstance name="rwEng-0" processId="217799" status="1" runJobId="-1" curJobExecTime="-1" idleTime="17673" numJobsRun="4" lifeLeft="46" nls="AMERICAN_AMERICA.AL32UTF8" totalRunTime="0" totalIdleTime="295"/>
      <engineInstance name="rwEng-1" processId="217862" status="1" runJobId="-1" curJobExecTime="-1" idleTime="17700" numJobsRun="0" lifeLeft="50" nls="AMERICAN_AMERICA.AL32UTF8" totalRunTime="0" totalIdleTime="295"/>
   </engine>
   <engine id="rwURLEng" activeEngine="0" runningEngine="0" totalBusyEngines="0" totalIdleEngines="2"/>
   <performance>
      <property name="successfulJobs" value="59"/>
      <property name="currentJobs" value="0"/>
      <property name="futureJobs" value="0"/>
      <property name="transferredJobs" value="0"/>
      <property name="failedJobs" value="24"/>
      <property name="longRunningJobs" value="0"/>
      <property name="potentialRunawayJobs" value="0"/>
      <property name="averageResponseTime" value="1343.58"/>
      <property name="averageElapsedTime" value="0.0"/>
      <property name="avgQueuingTime" value="1098.45"/>
   </performance>
   <connection connectionsUsed="1" connectionsAvailable="299"/>
   <isSecure>1</isSecure>
   <engineInfo maxEnginesUsed="2" avgEnginesUsed="1.5"/>
   <avgAuthTime>287.0</avgAuthTime>
</serverInfo>
```

Matching `rwserver.conf`: `<engine id="rwEng" ... initEngine="2" maxEngine="5"
minEngine="2" engLife="50" maxIdle="30" engineResponseTimeOut="30"/>`.

## 4. Field reference

The **Unit / meaning** column is backed as follows:
- **live**: derived from this answer, e.g. `idleTime` 17673 against an
  uptime of 17714 s;
- **code**: as our parsers use it since 2026-10-17.

### 4.1 Server

| Element / attribute | Unit / meaning | Use |
|---|---|---|
| `serverInfo/@name`, `@version` | server name, release | inventory, detect a wrong server answering |
| `host` | FQDN of the host | – (do not put it into tickets sent outside) |
| `processId` | PID of `rwserver` | **restart detection** together with `startTime` |
| `startTime` | epoch **milliseconds** (live) | uptime / restart detection – the job counters (4.3) do **not** start again |
| `queue/@maxQueueSize` | `<queue maxQueueSize>` of `rwserver.conf` | config drift |
| `isSecure` | `1` = `securityId` active | **CRITICAL if 0** on a server that should be secured |
| `avgAuthTime` | ms per login (live: 287) | a rising value points at a slow LDAP / AdminServer |
| `connection/@connectionsUsed`, `@connectionsAvailable` | client connections against `maxConnect` | `connectionsAvailable=0` = new requests are refused |
| `engineInfo/@maxEnginesUsed`, `@avgEnginesUsed` | peak / average of engines in use (since the start or from the job queue – not verified) | **sizing**: `maxEnginesUsed = maxEngine` = jobs had to wait |

### 4.2 Engines (`engine id="rwEng"` = report engine, `rwURLEng` = URL engine)

| Attribute | Meaning | Use |
|---|---|---|
| `activeEngine` | engine processes running now | `0` on `rwEng` = **CRITICAL** (no report can run) |
| `totalBusyEngines` / `totalIdleEngines` | busy / waiting engines | busy = `maxEngine` over several checks = pool too small |
| `runningEngine` | engines being started | short spikes are normal |
| `engineInstance/@status` | `1` IDLE, `2` BUSY, `0` **DEAD** (code) | any `0` = **CRITICAL** |
| `@processId` | PID of the engine JVM | memory per engine (`ps -o rss`) |
| `@runJobId`, `@curJobExecTime` | job running now and its runtime in ms; `-1` = none | `curJobExecTime` near `engineResponseTimeOut` = the job is about to be killed |
| `@idleTime` | seconds idle (live) | together with `maxIdle` (minutes): above `minEngine` an idle engine is stopped |
| `@numJobsRun`, `@lifeLeft` | jobs done, jobs left until the engine is recycled (`engLife` 50 − 4 = 46, live) | normal recycling, no alarm |
| `@totalRunTime`, `@totalIdleTime` | minutes (live: 17700 s = 295 min) | load per engine |
| `@nls` | NLS of the engine | config drift (wrong character set = broken umlauts) |

`rwURLEng` has no `engineInstance` while no URL job runs (`minEngine="0"`).
That is normal.

### 4.3 Job counters (`performance/property`)

**The job counters are computed from the past job queue – not since the
start of the Reports server.** confirmed (live), 2026-11-11: after a reboot
(Reports server started 08:11, both engines `numJobsRun="0"`) `getserverinfo`
still showed `successfulJobs` 71 and `failedJobs` 30, and `showjobs
queuetype=past` listed exactly 101 jobs from 2026-10-24 to 2026-11-10:

| `<status code>` in `showjobs` | Jobs | Counted as |
|---|---|---|
| `4` finished successfully | 70 | `successfulJobs` |
| `15` scheduled job has expired | 1 | `successfulJobs` |
| `5` terminated with error | 28 | `failedJobs` |
| `7` canceled upon user request | 2 | `failedJobs` |

The past queue is kept in `$DOMAIN_HOME/reports/server/<repserver>.dat` and
survives every restart. `averageResponseTime` / `avgQueuingTime` also kept
values without a single new job, so they come from the same queue.

Consequences:
- **No command resets the counters.** `killjobid` acts on current and
  future jobs only. The only way to 0: stop the Reports server, move the
  `.dat` away, start – that deletes the whole job history **and every
  scheduled job** (`schedule=`). Not as a daily routine.
- **Alarm on the difference** between two checks, never on the absolute
  value. A restart does not change the counters.
- **Assumption:** the past queue is limited by `maxQueueSize` (4000); once it
  is full the oldest jobs drop out and `failedJobs` can even **fall**. Count
  only positive differences.
- **Failures per day:** read `showjobs queuetype=past` once a day and count
  the jobs with code `5` / `7` that finished today (below). The 24 / 30
  `failedJobs` above are test reports from a font and image test series.

```bash
curl -s --max-time 60 -K ~/.config/rwadmin.curl \
     --data-urlencode "server=repserver01" --data-urlencode "statusformat=XML" \
     --data-urlencode "queuetype=past" \
     http://localhost:9002/reports/rwservlet/showjobs > /tmp/sj.xml
```

```bash
D="$(LC_ALL=C date '+%b %-d, %Y,')"
xmllint --xpath "count(/serverQueues/job[status/@code='5' or status/@code='7'][starts-with(timingInfo/finished,'$D')])" /tmp/sj.xml; echo
```

`showjobs` lists all jobs only for the server administrator from
`<identifier>` (`rwadmin.curl`, doc 13) – `monUser` sees its own jobs only.
`<finished>` has the format `Nov 3, 2026, 3:38:16/PM` (no leading zero, hence
`%-d`). Live 2026-11-11 against the test host's queue: 2026-11-03 = 6 failed
of 17 jobs. Delete `/tmp/sj.xml` afterwards.

| Property | Meaning | Use |
|---|---|---|
| `successfulJobs` | jobs finished OK | throughput (delta per minute) |
| `failedJobs` | jobs with an error (`REP-`/`ORA-`) | **delta > 0 = WARNING**. A failure rate ≥ 5 % of the jobs = a functional problem, not tuning ([`engine_perf_analyse.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/05-ReportsPerformance/engine_perf_analyse.sh)) |
| `currentJobs` | jobs running now | load |
| `futureJobs` | scheduled jobs (`schedule=`) | only if used |
| `transferredJobs` | jobs taken over from another server (cluster) | normally 0 |
| `longRunningJobs` | jobs longer than Oracle's "long running" limit | WARNING – slow SQL or a huge report |
| `potentialRunawayJobs` | jobs that probably never end | **CRITICAL** – look at once (`showjobs`, `killjobid`) |
| `averageResponseTime` | ms from request to result (end to end) | trend |
| `avgQueuingTime` | ms spent waiting for a free engine | **queuing share** = `avgQueuingTime / averageResponseTime`; ≥ 50 % = jobs wait for engines ([`engine_perf_analyse.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/05-ReportsPerformance/engine_perf_analyse.sh)) |
| `averageElapsedTime` | should be the engine time – **always `0.0` in 14.1.2** (live, 2026-10-19) | do not use |

## 5. What to alarm on

| Level | Condition | Why |
|---|---|---|
| CRITICAL | no answer / timeout | `WLS_REPORTS` or rwservlet down |
| CRITICAL | `<error>` in the answer (`REP-50171`, `REP-56071`, …) | nobody can log in – often the AdminServer is down (secured server) |
| CRITICAL | `activeEngine` of `rwEng` = 0, or any engine `status="0"` | no report runs |
| CRITICAL | `potentialRunawayJobs` > 0 | a hanging engine blocks the pool |
| CRITICAL | `connectionsAvailable` = 0 | new requests are refused |
| CRITICAL | `isSecure` = 0 on a secured installation | security switched off (config change, restore) |
| WARNING | `failedJobs` rose since the last check | failing reports |
| WARNING | `longRunningJobs` > 0 | slow reports |
| WARNING | `totalBusyEngines` = `maxEngine` in 3 checks in a row | pool too small, jobs wait |
| WARNING | queuing share ≥ 50 % | same, measured over the whole uptime |
| INFO | `startTime` / `processId` changed | restart of the Reports server – the job counters keep their values (4.3) |

**Performance data worth a graph:**
- `totalBusyEngines`, `currentJobs`;
- deltas of `successfulJobs` / `failedJobs`;
- `averageResponseTime`, `avgQueuingTime`, `avgAuthTime`.

## 6. Checks around `getserverinfo`

| Check | Command / source | Why |
|---|---|---|
| process `rwserver` | `pgrep -f "rwserver server=repserver01"` | distinguishes "Reports server down" from "WLS_REPORTS down" |
| AdminServer | port 7001 / `startStop.sh status` | the secured Reports server authenticates against the AdminServer's LDAP – AdminServer down = `REP-50171` for everyone |
| logs | `$DOMAIN_HOME/servers/<repserver>/logs/*.log`, engine logs: `REP-`, `ORA-`, `OutOfMemoryError` | the reason behind `failedJobs` |
| disk | cache directory of the Reports server, `/tmp`, `$DOMAIN_HOME` | a full cache = every job fails |
| end-to-end | once per hour a small test report via `cmdkey=` → `%PDF` | proves DB login, fonts and the PDF output (15- test report) |
| certificates | [`10-Monitoring/cert_expiry_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/10-Monitoring/cert_expiry_check.sh) | HTTPS in front of rwservlet |

## 7. Implementations

### 7.1 Generic check (Nagios / Icinga / Checkmk / NRPE)

A complete, live-tested (2026-11-03) plugin. Needs `curl` and `xmllint`
(package `libxml2`, on OL9 by default). Exit codes: 0 OK, 1 WARNING,
2 CRITICAL, 3 UNKNOWN. Output with performance data after the `|`.

```bash
#!/bin/bash
# check_reports_server.sh - check of an Oracle Reports server via getserverinfo.
# Exit 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN.
# Credentials: curl config file (chmod 600) with one line
#   data-urlencode = "authid=monUser/<password>"
# All parameters go in the POST body - nothing in the URL, in access.log or in ps.
URL="${RW_URL:-http://localhost:9002/reports/rwservlet/getserverinfo}"
SERVER="${1:-repserver01}"
MAX_ENGINE="${2:-5}"                       # maxEngine of rwEng in rwserver.conf
CRED="${RW_CRED:-$HOME/.config/rwmon.curl}"
STATE="${RW_STATE:-$HOME/.cache/rwmon_${SERVER}.state}"

XML="$(curl -s --connect-timeout 5 --max-time 60 -K "$CRED" \
        --data-urlencode "server=$SERVER" --data-urlencode "statusformat=XML" "$URL")"
[ $? -ne 0 ] && { echo "CRITICAL - rwservlet not reachable ($URL)"; exit 2; }

x() { printf '%s' "$XML" | xmllint --xpath "$1" - 2>/dev/null; }

ERR="$(x 'string(//error/@code)')"
[ -n "$ERR" ] && { echo "CRITICAL - REP-$ERR $(x 'string(//error/@message)')"; exit 2; }
[ "$(x 'count(/serverInfo)')" = "1" ] || { echo "UNKNOWN - no serverInfo (HTTP 499 = login page?)"; exit 3; }

P() { x "string(//performance/property[@name='$1']/@value)"; }
ACTIVE="$(x 'string(//engine[@id="rwEng"]/@activeEngine)')"
BUSY="$(x 'string(//engine[@id="rwEng"]/@totalBusyEngines)')"
DEAD="$(x 'count(//engine[@id="rwEng"]/engineInstance[@status="0"])')"
FAILED="$(P failedJobs)"; RUNAWAY="$(P potentialRunawayJobs)"; LONG="$(P longRunningJobs)"
CURRENT="$(P currentJobs)"; RESP="$(P averageResponseTime)"; QUEUE="$(P avgQueuingTime)"
CONN_FREE="$(x 'string(/serverInfo/connection/@connectionsAvailable)')"

# failedJobs comes from the persisted past queue (survives restarts, can fall
# when the queue is full) - alarm only on a positive difference
LAST_FAILED=""
[ -r "$STATE" ] && read -r LAST_FAILED < "$STATE"
mkdir -p "$(dirname "$STATE")"; echo "$FAILED" > "$STATE"
NEW_FAILED=0
[ -n "$LAST_FAILED" ] && [ "$FAILED" -gt "$LAST_FAILED" ] && NEW_FAILED=$(( FAILED - LAST_FAILED ))

RC=0; MSG=""
add() { MSG="$MSG $2;"; [ "$1" -gt "$RC" ] && RC=$1; }
[ "$DEAD" -gt 0 ]                  && add 2 "$DEAD engine(s) DEAD"
[ "${RUNAWAY:-0}" -gt 0 ]          && add 2 "$RUNAWAY runaway job(s)"
[ "${ACTIVE:-0}" -eq 0 ]           && add 2 "no active report engine"
[ "${CONN_FREE:-1}" -eq 0 ]        && add 2 "no free connections (maxConnect)"
[ "$NEW_FAILED" -gt 0 ]            && add 1 "$NEW_FAILED new failed job(s)"
[ "${LONG:-0}" -gt 0 ]             && add 1 "$LONG long-running job(s)"
[ "${BUSY:-0}" -ge "$MAX_ENGINE" ] && add 1 "all $MAX_ENGINE engines busy"

TEXT="engines active=$ACTIVE busy=$BUSY dead=$DEAD, jobs current=$CURRENT failed=$FAILED"
PERF="active=$ACTIVE busy=$BUSY;$MAX_ENGINE dead=$DEAD;;1 current=$CURRENT failed=${FAILED}c resp=${RESP}ms queue=${QUEUE}ms"
case $RC in 0) S=OK ;; 1) S=WARNING ;; *) S=CRITICAL ;; esac
echo "$S -${MSG:- all fine;} $TEXT | $PERF"
exit $RC
```

Live results on the test host:

| Case | Output | Exit |
|---|---|---|
| normal | `OK - all fine; engines active=2 busy=0 dead=0, jobs current=0 failed=24 \| active=2 busy=0;5 dead=0;;1 current=0 failed=24c resp=1343.58ms queue=1098.45ms` | 0 |
| wrong password | `CRITICAL - REP-50171 Authentication failed.` | 2 |
| no credentials | `UNKNOWN - no serverInfo (HTTP 499 = login page?)` | 3 |
| servlet not reachable | `CRITICAL - rwservlet not reachable (http://localhost:9999/x)` | 2 |

The `failedJobs` difference (since 2026-11-11 without the `startTime`
comparison, 4.3) was tested with saved answers via `RW_URL=file://…`:
24 → OK, 27 → `WARNING - 3 new failed job(s)`, 27 → OK, 20 (fallen) → OK.

The `isSecure` check is left out on purpose: only the operator knows whether
the server should be secured. Add `[ "$(x 'string(/serverInfo/isSecure)')" = "1" ] || add 2 "server not secured"`
when it should be.

### 7.2 Zabbix

Use one **HTTP agent** item as the master item:
- URL `http://localhost:9002/reports/rwservlet/getserverinfo`;
- request method POST, body type "Raw data";
- body `server=repserver01&statusformat=XML&authid=monUser/{$RW_MON_PWD}`,
  with the password in a **secret macro**;
- run it from the Zabbix agent on the host or from a proxy that may reach
  `localhost`.

Dependent items read values from it with the preprocessing step "XML
XPath":
- `string(//engine[@id="rwEng"]/@activeEngine)`
- `count(//engine[@id="rwEng"]/engineInstance[@status="0"])`
- `string(//performance/property[@name="failedJobs"]/@value)`, with an extra
  step "Simple change" for the delta (trigger on `> 0` – the value can fall
  when the job queue is full, 4.3)
- `string(//error/@code)` → trigger "not empty"

Map the thresholds from section 5 to triggers. The Zabbix server stores the
body in its configuration, so make the macro secret.

### 7.3 PRTG

Every PRTG HTTP sensor runs **on the probe**, not on the Reports host. Nginx
blocks the web commands from outside (Reports_security.txt 2.3), and on a
loopback-hardened domain `WLS_REPORTS` listens on `127.0.0.1:9002` only. So
the request has to start on the Reports host. Two ways:

- **A – REST Custom v2 sensor** on a probe that runs on the Reports host
  (multi-platform probe on Linux). Reads up to 10 values straight from the
  XML, no script on the host (7.3.1).
- **B – SSH Script Advanced** sensor that runs the script from 7.1 on the
  host. Turn its output into PRTG's XML format, or use the plain exit code
  with "SSH Script". Works with any probe that may SSH to the host.

#### 7.3.1 REST Custom v2 sensor (XPath, 10 channels)

Source: [PRTG manual – REST Custom v2](https://www.paessler.com/manuals/prtg/rest_custom_v2_sensor)
(read 2026-11-11). **Not tested live** – no PRTG on the test host; the XPath
expressions are checked against the real answer from section 3 with `xmllint`.

What the sensor offers (from the manual):
- content type XML, **XPath 1.0** (functions such as `count()` allowed);
- request method POST with a **POST body**, custom headers;
- placeholders `%restusername` / `%restpassword` from the device setting
  "credentials for REST API";
- **at most 10 channels**; channel #1 is required, #2–#10 can only be
  enabled at creation;
- value types Absolute (integer / float), Delta (counter), Status (string)
  with "Strings mapped to the 'Up' status" (unknown strings → Down by
  default), Lookup. **Value type and lookup cannot be changed after creation.**

Sensor settings:

| Setting | Value |
|---|---|
| Request URL | `http://localhost:9002/reports/rwservlet/getserverinfo` |
| Request Method | POST |
| POST Body | `server=repserver01&statusformat=XML&authid=%restusername/%restpassword` |
| Custom Headers | `Content-Type: application/x-www-form-urlencoded` |
| Content Type | XML |
| Timeout (Sec.) | 60 (first request after a Reports server start can be slow, 2.2) |
| Credentials (device) | "credentials for REST API": user `monUser`, its password |
| Custom Sensor Message | `concat(/serverInfo/@name, ' ', /serverInfo/@version, //error/@message)` – server and release, or the error text |

All parameters stay in the POST body – nothing lands in `access.log` (2.1).
**Assumption:** the manual does not say whether the placeholders are
URL-encoded; a password with `&`, `+`, `%` or `=` may then break the body.
Use a `monUser` password without these characters, or test it once.

The 10 channels (thresholds from section 5):

| # | Channel | XPath | Value type / unit | Alarm (limit / mapping) |
|---|---|---|---|---|
| 1 | Server answers | `count(/serverInfo)` | Status (string), Up = `1` | anything else → Down: `<error>` answer (wrong password, AdminServer / LDAP down, missing role) or login page |
| 2 | Active engines | `/serverInfo/engine[@id="rwEng"]/@activeEngine` | Absolute (integer), # | lower error limit 1 – no report can run |
| 3 | Busy engines | `/serverInfo/engine[@id="rwEng"]/@totalBusyEngines` | Absolute (integer), # | upper warning = `maxEngine` − 1 (pool full) |
| 4 | Dead engines | `count(/serverInfo/engine[@id="rwEng"]/engineInstance[@status="0"])` | Absolute (integer), # | upper error limit 0 |
| 5 | Failed jobs | `/serverInfo/performance/property[@name="failedJobs"]/@value` | Absolute (integer), # | notification trigger "on change"; from the persisted job queue (4.3) |
| 6 | Runaway jobs | `/serverInfo/performance/property[@name="potentialRunawayJobs"]/@value` | Absolute (integer), # | upper error limit 0 |
| 7 | Long-running jobs | `/serverInfo/performance/property[@name="longRunningJobs"]/@value` | Absolute (integer), # | upper warning limit 0 |
| 8 | Free connections | `/serverInfo/connection/@connectionsAvailable` | Absolute (integer), # | lower error limit 1 – new requests are refused |
| 9 | Secured | `/serverInfo/isSecure` | Status (string), Up = `1` | `0` → Down; leave the channel out on a server without `securityId` |
| 10 | Auth time | `/serverInfo/avgAuthTime` | Absolute (float), Time ms | upper warning by baseline (test host 287 ms, slow LDAP / AdminServer) |

Notes:
- **Channel #1 as Status (string)** turns every error answer into Down without
  a limit: `<error code="50171">` has no `serverInfo`, `count()` returns `0`.
  The other channels then find no value – also a sensor error.
- **`failedJobs` not as Delta (counter):** the manual allows Delta only for
  values that never fall. The counter survives restarts, but it falls when
  the past queue is full (oldest jobs drop out) or the `.dat` is removed
  (4.3). Absolute + "on change" trigger is the safer choice.
- **Limits** (2–8, 10) are set afterwards in the channel settings (PRTG
  channel limits). The manual for this sensor does not describe limits
  itself – check on the first sensor.

Further XPath values to swap in (still 10 channels at most):

| Value | XPath | Value type / unit |
|---|---|---|
| Current jobs | `/serverInfo/performance/property[@name="currentJobs"]/@value` | Absolute (integer) |
| Successful jobs | `/serverInfo/performance/property[@name="successfulJobs"]/@value` | Absolute (integer) |
| Average response time | `/serverInfo/performance/property[@name="averageResponseTime"]/@value` | Absolute (float), Time ms |
| Average queuing time | `/serverInfo/performance/property[@name="avgQueuingTime"]/@value` | Absolute (float), Time ms |
| Queuing share | `/serverInfo/performance/property[@name="avgQueuingTime"]/@value div /serverInfo/performance/property[@name="averageResponseTime"]/@value * 100` | Absolute (float), Percent – warning ≥ 50; **no jobs yet = 0 div 0 = NaN** |
| Peak engines used | `/serverInfo/engineInfo/@maxEnginesUsed` | Absolute (integer) – `= maxEngine` means jobs had to wait |
| Idle engines | `/serverInfo/engine[@id="rwEng"]/@totalIdleEngines` | Absolute (integer) |
| Process ID | `/serverInfo/processId` | Absolute (integer) – changes on a restart |
| URL engines active | `/serverInfo/engine[@id="rwURLEng"]/@activeEngine` | Absolute (integer) – `0` is normal (4.2) |

Test the expressions on the host before you build the sensor:

```bash
curl -s --max-time 60 -K ~/.config/rwmon.curl \
     --data-urlencode "server=repserver01" --data-urlencode "statusformat=XML" \
     http://localhost:9002/reports/rwservlet/getserverinfo > /tmp/si.xml
```

```bash
xmllint --xpath 'count(/serverInfo/engine[@id="rwEng"]/engineInstance[@status="0"])' /tmp/si.xml; echo
```

```bash
xmllint --xpath 'string(/serverInfo/performance/property[@name="failedJobs"]/@value)' /tmp/si.xml; echo
```

`xmllint` needs `string()` around attribute paths to print the bare value;
in PRTG the plain path is enough. Delete `/tmp/si.xml` afterwards (it holds
the host name).

### 7.4 Our tools for manual checks

| Tool | Use |
|---|---|
| `01-Run/rwserver_status.sh --auth auto` | readable dump of the whole answer (server, engines, counters) |
| [`05-ReportsPerformance/engine_perf_analyse.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/05-ReportsPerformance/engine_perf_analyse.sh) | evaluation: failure rate, queuing share, pool at `maxEngine`, logs |
| customer tool `/u01/oracle/tools/status.sh` | ports, processes and Node Manager state of the whole domain (Tools_status_logs_kochbuch.txt) |

## 8. Open points

- Still GET with a password in the URL: the test report run of
  [`09-Install/15-deploy-test-report-forms_template.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/15-deploy-test-report-forms_template.sh) (`userid=` with the
  DB password), and examples in older docs / cookbooks (doc 12, doc 13,
  WLS_Report_start_stop_kochbuch.txt, Patch_Kochbuch 13.6). On customer
  hosts: check old access logs for `authid=` / `userid=` and clean them.
- Does the access log really contain no body after the switch? Not yet seen
  live: the test host's `access.log` had not been written since 2026-10-27
  (buffer / rotation, to be checked). By definition, `cs-uri` holds only the
  URL.
- The exact Oracle limits behind `longRunningJobs` and `potentialRunawayJobs`
  are not documented here yet (**assumption**: related to
  `engineResponseTimeOut`).
- `showjobs` (job list with `REP-` per job) as a second source for the "why"
  behind `failedJobs`.
- Behaviour of the job counters when the past queue reaches `maxQueueSize`
  (assumption: oldest jobs drop out, `failedJobs` falls) and whether
  `engineInfo` also comes from the queue – not seen live yet.
- PRTG REST Custom v2 sensor (7.3.1) not tested live: URL-encoding of
  `%restpassword` in the POST body, sensor state when an XPath finds no value,
  Status (string) mapping of the `count()` result.
