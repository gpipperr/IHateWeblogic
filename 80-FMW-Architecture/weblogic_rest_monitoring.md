---
nav_title: "WebLogic REST monitoring"
title: "Monitoring WebLogic 14.1.2 with the REST Management API"
description: "Read server state, health, heap, stuck threads and JDBC pools of all WebLogic servers of a Forms & Reports 14.1.2 domain with one REST search call – verified field names, a read-only monitor user, no lockout, and why /management never goes through Nginx."
---

# Monitoring WebLogic with the REST Management API

This page shows how a monitor reads the runtime state of **all WebLogic
servers** of a Forms & Reports 14.1.2 domain:
- state and health;
- heap;
- stuck and hogging threads;
- JDBC connection pools.

It takes **one** HTTP request against the AdminServer, without WLST and
without a JVM start.

The counterpart for the standalone Reports server, which is not a WebLogic
server, is
[reports_monitoring_getserverinfo.md](reports_monitoring_getserverinfo.md).

Verified on the test host on 2026-11-20:
- FMW 14.1.2.0.0 with Stack Patch Bundle 14.1.2.0.261112 (CSPU Nov 2026);
- AdminServer, `WLS_FORMS`, `WLS_REPORTS`;
- WebLogic listens on `127.0.0.1` only, Nginx is in front.

Related:
- Our runtime monitor that uses this call:
  [11-wlsmon/docs/01-wlsmon_concept.md](../11-wlsmon/docs/01-wlsmon_concept.md)
  (§4.1);
- Web tier and bindings:
  [weblogic_middleware_architecture.md](weblogic_middleware_architecture.md);
- Security entry page: [security_overview.md](security_overview.md).

---

## 1. Which interface for what

| Question | Interface | Who answers |
|---|---|---|
| Server RUNNING? Health, heap, threads, JDBC pools of every WebLogic server | **REST Management API** `…/management/weblogic/latest/domainRuntime/search` (this page) | AdminServer (`:7001`) |
| Reports engines, queue, job counters | `getserverinfo` of the rwservlet ([reports_monitoring_getserverinfo.md](reports_monitoring_getserverinfo.md)) | `WLS_REPORTS` (`:9002`) |
| Forms sessions | `frmweb` processes and their connections (`06-FormsDiag/forms_perf_analyse.sh`) | the operating system |
| Is the server only up, without login? | `GET http://localhost:<port>/weblogic/ready` (200 = ready) | every server itself |

Why REST and not WLST:
- WLST starts a JVM every time. Called every 5 minutes, that costs seconds of
  CPU and several 100 MB of RAM.
- The REST call is a single HTTP request: about 0.2 s, and nothing extra on
  the host.

```
 monitor (on the WebLogic host)
     |  POST  http://localhost:7001/management/weblogic/latest/domainRuntime/search
     |        Basic Auth: monitor user (group Monitors), X-Requested-By header
     v
 AdminServer :7001  (REST Management Services, part of WebLogic)
     |  domainRuntime: collects the runtime MBeans of EVERY running server
     v
 AdminServer · WLS_FORMS · WLS_REPORTS   -> one JSON answer
```

The AdminServer collects the values of the managed servers. **If the
AdminServer is down, this call returns nothing**, even though the managed
servers keep running. In that case a monitor falls back to
`/weblogic/ready` and port checks per server (§6).

## 2. The request

### 2.1 One search POST for everything

```bash
curl -s --max-time 20 -K - \
     -H 'X-Requested-By: monitor' \
     -H 'Content-Type: application/json' \
     -H 'Accept: application/json' \
     -X POST --data @search.json \
     http://localhost:7001/management/weblogic/latest/domainRuntime/search \
     <<< 'user = "wlsmon_monitor:<PASSWORD>"'
```

`search.json` names the MBeans and the fields that should come back. Without
`fields`, WebLogic returns every attribute, which is several 100 KB.

```json
{"links": [], "fields": [],
 "children": {
  "serverRuntimes": {
   "links": [], "fields": ["name", "state", "healthState", "openSocketsCurrentCount"],
   "children": {
    "JVMRuntime": {"links": [], "fields": ["heapSizeCurrent", "heapFreeCurrent", "heapSizeMax", "heapFreePercent"]},
    "threadPoolRuntime": {"links": [], "fields": ["hoggingThreadCount", "stuckThreadCount",
                                                   "pendingUserRequestCount", "executeThreadTotalCount"]},
    "JDBCServiceRuntime": {"links": [], "fields": [], "children": {
      "JDBCDataSourceRuntimeMBeans": {"links": [], "fields": ["name", "state",
        "activeConnectionsCurrentCount", "waitingForConnectionCurrentCount"]}}}
   }}}}
```

Rules:
- **`X-Requested-By`** is required (CSRF protection of the REST services):
  for every POST, and on 14.1.2 also for the GET of the monitor's login test
  (`domainRuntime/serverRuntimes`) – live 2026-11-20. The value does not
  matter. Without it the answer is HTTP 400. Simplest rule: always send it.
- **`"links": []`** everywhere: without it, every object carries its
  hypermedia links, and the answer gets several times larger.
- **The password goes on stdin** (`-K -` reads a curl config from stdin).
  It is then not in the process list (`ps`), not in the shell history and
  not on disk. `-u user:pwd` on the command line is visible in `ps` to
  every local user.
- **`latest`** is the current REST version of the installed WebLogic. On
  14.1.2 it is identical to `14.1.2.0`.

### 2.2 The expected server list

`serverRuntimes` contains **only running servers**. A server that is down
is simply missing from the answer, so a monitor also needs the configured
list:

```bash
curl -s --max-time 20 -K - -H 'Accept: application/json' -H 'X-Requested-By: monitor' \
     'http://localhost:7001/management/weblogic/latest/domainConfig/servers?fields=name&links=none' \
     <<< 'user = "wlsmon_monitor:<PASSWORD>"'
```

```json
{"items": [{"name": "AdminServer"}, {"name": "WLS_FORMS"}, {"name": "WLS_REPORTS"}]}
```

Configured but not in `serverRuntimes` means **DOWN** (or not started).

### 2.3 Timing

| Call | Time on the test host |
|---|---|
| first search after a start of the AdminServer | **11.3 s** – WebLogic starts the REST application only at the first request |
| every further search | 0.17 – 0.22 s |
| minimal search (`name`, `state` only) | 0.12 s |
| `domainConfig/servers` | 0.21 s |

A timeout of 20 s covers the first call. A monitor that alarms after 5
seconds reports a false outage once after every restart.

## 3. The answer – real, on 14.1.2

One entry of `serverRuntimes.items`, from the test host (2026-11-20; server
and data source names are those of every F&R 14.1.2 domain):

```json
{
 "name": "WLS_FORMS",
 "state": "RUNNING",
 "openSocketsCurrentCount": 3,
 "healthState": {"state": "ok", "subsystemName": "ServerRuntime", "symptoms": []},
 "threadPoolRuntime": {
  "executeThreadTotalCount": 63, "pendingUserRequestCount": 0,
  "stuckThreadCount": 0, "hoggingThreadCount": 0
 },
 "JDBCServiceRuntime": {"JDBCDataSourceRuntimeMBeans": {"items": [
  {"name": "opss-audit-DBDS",   "state": "Running", "activeConnectionsCurrentCount": 0, "waitingForConnectionCurrentCount": 0},
  {"name": "opss-data-source",  "state": "Running", "activeConnectionsCurrentCount": 0, "waitingForConnectionCurrentCount": 0},
  {"name": "opss-audit-viewDS", "state": "Running", "activeConnectionsCurrentCount": 0, "waitingForConnectionCurrentCount": 0}
 ]}},
 "JVMRuntime": {
  "heapSizeCurrent": 2147483648, "heapFreeCurrent": 1361644624,
  "heapSizeMax": 2147483648, "heapFreePercent": 63
 }
}
```

The whole answer is the test fixture
[`11-wlsmon/tests/fixtures/wls/search_real_14.1.2.json`](https://github.com/gpipperr/IHateWeblogic/blob/main/11-wlsmon/tests/fixtures/wls/search_real_14.1.2.json).

## 4. Field reference (verified on 14.1.2)

| Field | Type | Meaning | Note |
|---|---|---|---|
| `name` | string | server name | |
| `state` | string | `RUNNING`, `ADMIN`, `STANDBY`, `SHUTTING_DOWN`, `FAILED`, … | only running servers appear at all (§2.2) |
| `healthState` | **object** | `state` (`ok`, `warning`, `critical`, `failed`, `overloaded`), `subsystemName`, `symptoms[]` | not a string – a monitor that compares `healthState == "ok"` never matches |
| `openSocketsCurrentCount` | number | open sockets | informative |
| `JVMRuntime.heapFreePercent` | number | free heap in % **of the maximum heap** | heap used = `100 - heapFreePercent` |
| `JVMRuntime.heapSizeCurrent` / `heapSizeMax` / `heapFreeCurrent` | bytes | current size / `-Xmx` / free in the current size | for an exact value: `(heapSizeCurrent - heapFreeCurrent) / heapSizeMax` |
| `threadPoolRuntime.stuckThreadCount` | number | threads busy longer than the stuck thread time (default 600 s) | > 0 = CRIT; also `BEA-000337` in the server log |
| `threadPoolRuntime.hoggingThreadCount` | number | threads that will be declared stuck soon | > 0 = WARN |
| `threadPoolRuntime.pendingUserRequestCount` | number | queued requests | a lasting value > 0 = the server cannot keep up |
| `JDBCDataSourceRuntimeMBeans.items[]` | list | one entry per data source **and server** | the same data source appears on every server it is targeted to |
| `….state` | string | `Running`, `Suspended`, `Overloaded`, `Shutdown`, … | mixed case – compare case-insensitively |
| `….activeConnectionsCurrentCount` / `waitingForConnectionCurrentCount` | number | connections in use / threads waiting for one | waiting > 0 = pool too small or the DB slow |

Collections always come as `{"items": [...]}`, also when there is only one
entry.

The data sources of a standard F&R 14.1.2 domain:
- `opss-data-source`, `opss-audit-DBDS`, `opss-audit-viewDS` (OPSS) on every
  server;
- `LocalSvcTblDataSource` (STB) only on the AdminServer.

The RCU schemas behind them are checked separately, because an expired
schema password shows only at the next restart (concept §4.1, RCU row).

## 5. The monitor user – read-only, no lockout

**A user of its own, only in the group `Monitors`:**
- `Monitors` may read every runtime MBean, but may not change, start or stop
  anything. The REST call above works with exactly this right.
- The admin user (`weblogic`, `webadmin`) has no place in a monitor: whoever
  reads the monitor configuration could otherwise stop the domain.
- The password follows the password rule of the realm
  (`07-Maintenance/wls_password_rule.sh`, 12 characters). It is random –
  nobody needs to know it.

**No self-made lockout:** the realm locks a user after failed logins
(`07-Maintenance/wls_lockout_config.sh`: 3 attempts / 30 min lockout /
15 min reset window).
- A monitor with a wrong or expired password that keeps polling every 5
  minutes keeps its own user locked.
- Worse: with the **admin** user it would lock out the administrator.
- So: after an HTTP 401, stop polling (wlsmon pauses for 30 minutes and
  reports "monitor login refused") instead of retrying.

| HTTP | Meaning |
|---|---|
| 200 | answer as in §3 |
| 400 | `X-Requested-By` missing (POST) or invalid JSON |
| 401 | wrong user / password, or the user is locked – **stop polling** |
| 403 | user known but without the right (not in `Monitors`/`Operators`/`Administrators`) |
| 404 | wrong path, or the REST services are disabled in the domain |
| connection refused / timeout | AdminServer down → fall back to §6 |

## 6. When the AdminServer is down

The managed servers run on without the AdminServer, but the REST call has
nobody to answer it. Per server, check instead:
- `GET http://localhost:<port>/weblogic/ready`: 200 = the server is up and
  ready. No login needed, it carries no data.
- A TCP check on the listen port and the Node Manager port (5556).

wlsmon then shows the AdminServer as DOWN and the managed servers as
"RUNNING (port only)", without heap and threads. Our own tools that use the
ready probe:
- `70-Customer-Projects/tools/bash/status.sh`;
- `01-Run/startStop.sh` (`_port_listening`).

## 7. Security: `/management` belongs to localhost only

The REST Management API is a full administration interface. With an admin
user it can do everything WLST can: deploy, change configuration, shut a
server down. So:

1. **Never route `/management` through Nginx.** The Nginx template of the
   library (`09-Install/nginx-wls.conf.template`) has no location for it,
   so a request ends at `return 404`. The monitor runs on the same host and
   calls `http://localhost:7001` directly.
2. **`/console` and `/em` are routed on purpose, but only for the admin
   network** (`allow ADMIN_IP_RANGE; deny all;`). A location without
   `deny all` would open the console to every client.
3. **WebLogic listens on `127.0.0.1` only**, Nginx is the only way in. If
   the AdminServer listened on a network address, `/console` and
   `/management` would be reachable from the network past every Nginx rule.

wlsmon checks all three every hour (`security.json`, tab "Security"):

| Check id | What | Level |
|---|---|---|
| `mgmt_rest_proxied` | a `location` for `/management` (or a catch-all `/` to the AdminServer port) in the Nginx configuration, plus an anonymous request to `/management/weblogic/latest` through the own Nginx with Host / SNI of the server block – anything other than 403 / 404 counts | CRIT |
| `admin_locations` | every location that proxies to the AdminServer port (resolved through the `upstream` blocks) has `deny all` and no `allow all` | WARN |
| `admin_listen` | the AdminServer port listens only on the loopback (`/proc/net/tcp`, `tcp6`) | WARN |

Test host 2026-11-20:
- `mgmt_rest_proxied` ok: no location, `/management` through Nginx → 404;
- `admin_locations` ok: `/console`, `/em` with `allow 10.0.0.0/8, deny all`;
- `admin_listen` ok: `127.0.0.1` only.

Why the check reads the configuration and does not only probe: a request
from the host itself comes from `127.0.0.1`, which is normally **not** in
`ADMIN_IP_RANGE`. `/console` therefore answers 403 locally, even though it
is open for the admin network. The probe alone cannot tell "restricted"
from "open". The configuration can.

## 8. Open points

Answered: the monitor user is created with REST – `createUser` +
`addMemberToGroup Monitors` of the `DefaultAuthenticator` (no WLST), live on
the test host and at a first customer 2026-11-20. On 14.1.2
`listMemberGroups` returns a cursor name (read it with `haveCurrent` /
`getCurrentName` / `advance`, then `close`), and every request needs
`X-Requested-By` – also a GET, otherwise HTTP 400 (§2.1).

Still open:

- Behaviour of the REST services with the **Remote Console** of 14.1.2
  (hosted `wls-remote-console.war`): it uses the same `/management` base
  path; to be checked whether a domain without the REST services still
  serves the Remote Console.
