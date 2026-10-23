# Reports server and engines – in-process vs. standalone, and why it is so complicated

Oracle Reports can run its server in two places and starts the engines
that actually produce the output as separate processes. Both facts cause
most of the confusion around Reports in a WebLogic domain: which
`rwserver.conf` applies, why the WebLogic console shows `WLS_REPORTS` but
no engines, why users of the WebLogic realm are unknown to one mode and not
to the other, and why a network broadcast is involved at all.

Markers as in [README.md](README.md): **confirmed (live)** = test domain
2026-10-14…17, **documented** = Oracle documentation ([Sources](#10-sources)),
**assumption** = not verified.
Domain overview: [weblogic_middleware_architecture.md](weblogic_middleware_architecture.md).

---

## 1. The parts

| Part | What it does | Process |
|---|---|---|
| **rwservlet** | HTTP entry point (`/reports/rwservlet`): takes the request, checks `cgicmd.dat` keys / SSO, hands the job to a Reports **server**, returns the output | part of the `reports` application in the managed server **WLS_REPORTS** |
| **Reports server** | job queue, scheduling, cache of finished output, security checks (`securityId`), starts and stops the engines | **in-process**: inside the WLS_REPORTS JVM – or **standalone**: own process `rwserver server=<name>` |
| **Engines** (`rwEng`, `rwURLEng`) | run the report: fetch data, format, write the output to the cache, report back | separate processes, started by the server; `rwEng` = reports, `rwURLEng` = URL engine (fetches a URL into the output) |
| **ReportsTools instance** (`reptools1`) | configuration of the command-line tools `rwrun`, `rwconverter`, `rwbuilder`: `rwbuilder.conf`, `uifont.ali`, screen-printer PPD/AFM, log directory `servers/reptools1/logs/` – the component itself has no permanently running process | each **tool call** is its own process – `rwrun` even runs a complete Reports runtime incl. engine inside it (section 5.1) |

"The Reports Engine … fetches requested data from the data source, formats
the report, sends the output to cache, and notifies the Reports Server that
the job is complete." (**documented**, Publishing Reports 12.2.1.3, 2.2)

---

## 2. Two modes

```
 MODE A: IN-PROCESS (Oracle default)              MODE B: STANDALONE (this repository)

  Browser / cgicmd key                             Browser / cgicmd key
        |                                                |
  +-----v--------------------------------+         +-----v--------------------------------+
  | WLS_REPORTS (WebLogic JVM)           |         | WLS_REPORTS (WebLogic JVM)           |
  |  rwservlet                           |         |  rwservlet                           |
  |    | in the same JVM                 |         |    | CORBA/IIOP to a server found    |
  |  Reports server (in-process)         |         |    | by name (broadcast / naming)    |
  |    config: servers/WLS_REPORTS/      |         +----|---------------------------------+
  |    applications/reports_14.1.2/      |              |
  |    configuration/rwserver.conf       |         +----v---------------------------------+
  |    security: jps-config.xml          |         | rwserver repserver01 (own JVM)       |
  |      = WebLogic realm (myrealm)      |         |  started by the NODE MANAGER         |
  +----|---------------------------------+         |  config: components/                  |
       | starts                                    |   ReportsServerComponent/repserver01/ |
  +----v------------------+                        |   rwserver.conf                       |
  | engines rwEng-0 ...   |                        |  security: jps-config-jse.xml         |
  | (separate processes)  |                        |   (default identity store: XML file)  |
  +-----------------------+                        +----|---------------------------------+
                                                        | starts
                                                   +----v------------------+
                                                   | engines rwEng-0 ...   |
                                                   | Java child processes  |
                                                   | of rwserver           |
                                                   +-----------------------+
```

Which mode is used is decided in `rwservlet.properties` of the reports
application (**confirmed (live)**):

```xml
<server>repserver01</server>   <!-- name of the Reports server to use     -->
<inprocess>no</inprocess>       <!-- no = standalone server, yes = in-process -->
```

- The domain contains **both** `rwserver.conf` files: the one of the
  in-process server under
  `servers/WLS_REPORTS/applications/reports_14.1.2/configuration/` (template
  values, e.g. `maxEngine=1`) and the one of the standalone server under
  `config/fmwconfig/components/ReportsServerComponent/<name>/`. Only the one
  of the mode in use is effective – a classic trap when tuning
  (**confirmed (live)**; `01-Run/rwserver_status.sh` therefore reads the
  component's file since 2026-10-17).
- In-process is Oracle's default: "If you are using Reports Server as an
  in-process Reports Server (the default configuration), sending a run
  report request starts the in-process Reports Server." (**documented**,
  5.5)

---

## 3. In-process – advantages and the LDAP question

**Advantages** (**documented**, 2.2 and – identical wording – already in the
10g guide): "the in-process Reports Server is available for faster response
and easier administration. The in-process Reports Server cuts down on the
communication expense between processes and consequently shortens response
times."

- no CORBA hop between rwservlet and server, no server discovery
- nothing to start separately – the server comes up with the first request
  (first request therefore slower)
- **security runs in the WebLogic JVM**: OPSS uses `jps-config.xml`, the
  identity store is the WebLogic realm `myrealm` (embedded LDAP or an
  external LDAP/AD authenticator). WebLogic users and the application roles
  `RW_*` work without any extra configuration.

Oracle documents the two user stores explicitly (**documented**, 15.8):
"15.8.1 Adding Users to WebLogic Embedded ID Store for **In-Process**
Servers" – via the WebLogic console, realm `myrealm` – versus "15.8.4 Adding
Users to `system-jazn-data.xml` for **Standalone** Servers".

That is exactly the standalone problem we hit: with `securityId` on the
report job every WebLogic user failed with `REP-50171 … user does not
exist`, because the standalone server looked in the XML file. Fixed by
pointing the identity store of `jps-config-jse.xml` to the embedded LDAP –
[reports_user_local_ldap.md](reports_user_local_ldap.md) (**confirmed (live)**,
2026-10-16).

**Disadvantages of in-process** (**assumption** – general consequences of
sharing one JVM, not quoted from Oracle):

- a hanging or crashing Reports server affects the WLS_REPORTS JVM, and a
  restart of the Reports server means a restart of WLS_REPORTS
- heap and JVM options are shared with the servlet container
- tuning in the in-process `rwserver.conf` lives in the application
  directory, which is easy to overlook

---

## 4. Standalone server with own engines – advantages

| Advantage | Why |
|---|---|
| process isolation | an engine or server crash does not touch WLS_REPORTS; Reports can be restarted alone (`startStop.sh stop/start repserver01`) |
| own JVM settings | `REPORTS_JVM_OPTIONS` in `$DOMAIN_HOME/reports/bin/reports.sh` (heap, process-reaper fix, ORB timeouts – [reports_user_local_ldap.md](reports_user_local_ldap.md) §7; ORB of server + engines on `127.0.0.1` via `ORBServerHost` – [clone_golden_image.md](clone_golden_image.md)) independent of WLS_REPORTS. Also an **own JDK**: `reports.sh` puts `$ORACLE_HOME/oracle_common/jdk/bin` first in `PATH`, the engines run on the FMW-bundled JDK, not on `JDK_HOME` (**confirmed (live)** 2026-10-19 – 17.0.12 on the test host; open: supported way to update it) |
| Node Manager control | start/stop/monitoring like the WebLogic servers (`nmStart … ReportsServerComponent`, autostart via `fmw_ctl.sh`) |
| several servers | several standalone servers (different names / queues / settings) can serve one rwservlet farm |

Price: CORBA between rwservlet and server (stale IOR after a restart caused
the 60 s delay we fixed with `ORBTCPConnectTimeouts`), server discovery
(section 8), and a second OPSS configuration (`jps-config-jse.xml`).

---

## 5. Who starts what – and what the consoles show

```
 systemd -> fmw_ctl.sh -> Node Manager
                            |-- AdminServer
                            |-- WLS_REPORTS  (rwservlet; in-process server would live here)
                            +-- repserver01  (system component "ReportsServerComponent")
                                   |-- rwEng-0   started by repserver01
                                   |-- rwEng-1   (initEngine at start, up to maxEngine on load,
                                   +-- ...        recycled after engLife jobs, stopped after maxIdle)
```

- **Starting WLS_REPORTS does not start the standalone Reports server.** It
  is a separate system component and must be started on its own – by the
  Node Manager (`startComponent.sh`, WLST `nmStart`, our autostart). Oracle:
  "The best way to run Reports Server is through the Oracle WebLogic
  Scripting Tool (WLST). Node Manager provides a centralized mechanism for
  initializing, maintaining, and shutting down … OracleAS Reports
  Services." (**documented**, 5.1)
- **The engines are never started by hand** – the Reports server starts
  `initEngine` engines at startup, more up to `maxEngine` when jobs queue
  up, and replaces them after `engLife` jobs (**documented**, 7.2.1.8).
  Live: engines are Java child processes of `rwserver`
  (`pgrep -P <rwserver pid>`), no `rwengine` process name in 14.1.2
  (**confirmed (live)**).
- **WebLogic console (Remote Console)** knows only WebLogic servers –
  AdminServer, WLS_FORMS, **WLS_REPORTS**. The Reports server and its engines
  are not WebLogic servers, so they do not appear there. An in-process server
  is invisible anyway (it is part of WLS_REPORTS).
- **Fusion Middleware Control (EM)** lists the standalone Reports server as a
  system component (Reports pages, start/stop through the Node Manager)
  (**documented**, chapter 6 "Administering … Using Oracle Enterprise
  Manager"); engines are not separate targets – their state is part of the
  server's status.
- Engine status therefore comes from the server itself: `getserverinfo`
  (`01-Run/rwserver_status.sh --auth …`, customer `status.sh`), or EM.

### 5.1 `rwrun` – a report without rwservlet and without Reports server

`rwrun` does not talk to `repserver01` at all. Oracle: "rwrun (Reports
Runtime) runs a report by starting its own in-process server (not to be
confused with the default in-process Reports Server), which runs in the same
JVM as the rwrun process. The configuration file for this in-process server
is rwbuilder.conf … It is recommended that you use rwrun for testing
purposes only. Use rwservlet and rwclient in your production environment"
(**documented**, Publishing Reports 12.2.1.3, A.2.2).

```
 PRODUCTION PATH                                   rwrun (batch / test)
 browser, cgicmd key, Forms RUN_REPORT_OBJECT      shell, cron, rwrun_trace.sh
        |                                                 |
  WLS_REPORTS: rwservlet                           $DOMAIN_HOME/reports/bin/rwrun.sh
        | CORBA, server found by name (multicast)         |  . reports.sh            (env: PATH, NLS_LANG,
        v                                                 |                           REPORTS_FONT_DIRECTORY …)
  rwserver repserver01   <- Node Manager                  |  COMPONENT_NAME=reptools1
   rwserver.conf (component)                              |  COMPONENT_CONFIG_PATH=…/ReportsToolsComponent/reptools1
   queue, cache, securityId, engine pool                  |  exec $ORACLE_HOME/bin/rwrun "$@"
        | starts                                          v
        v                                          ONE native process "rwrun"
  rwEng-0 … rwEng-N  (own Java processes,           |  librw.so + embedded JVM
   oracle.reports.engine.RWEngine)                  |   (oracle_common/jdk/lib/server/libjvm.so)
                                                    |  own runtime "server" from rwbuilder.conf,
                                                    |  engine rwEng-0 inside the same process
                                                    v
                                                   output file (DESTYPE=file) – no queue, no cache, no server
```

Live on the test host (2026-10-19, **confirmed (live)**: `/proc/<pid>/exe`,
`/proc/<pid>/maps`, `pgrep -P`, strace):

| | `rwrun` | Reports server path |
|---|---|---|
| processes | one native process `rwrun` (~25 threads), **no child process**; JVM loaded in-process | `rwserver` + Java engine processes |
| JDK | `$ORACLE_HOME/oracle_common/jdk` (via `reports.sh` – the FMW-bundled JDK, see section 4) | same |
| configuration | `ReportsToolsComponent/reptools1/rwbuilder.conf` (`maxEngine=1`) – log line `ServerConfig:logConf Reading server config file …/rwbuilder.conf` | `ReportsServerComponent/repserver01/rwserver.conf` |
| fonts | `reptools1/…/tk/admin/uifont.ali` + PPD/AFM (`TK_FONTALIAS` is ignored) | the same reptools1 files (no `uifont.ali` in the server component) |
| environment | `reports.sh` → `NLS_LANG`, `REPORTS_FONT_DIRECTORY`, `REPORTS_ENHANCED_FONTHANDLING`, `REPORTS_PATH`, `TNS_ADMIN` | `reports.sh` + `<envVariable>` of `rwserver.conf` (section 5.2) |
| network | none to the Reports server (only the DB connection) – no multicast, no `cgicmd.dat`, no `server=` | rwservlet → CORBA → server |
| log | `servers/reptools1/logs/runtime_diagnostic.log` (engine `rwEng-0` of the tool runtime) | `servers/repserver01/logs/rwserver_diagnostic.log`, `rwEng-N_diagnostic.log` |
| result | same PDF as the server path in all font tests of 2026-10-19 | – |

Example (password via `cmdfile`, so it is not visible in `ps`; DB given as
a TNS alias):

```bash
printf 'userid=%s/%s@MYDB\n' "$DB_USER" "$DB_PWD" > /tmp/rw.cmd && chmod 600 /tmp/rw.cmd
$DOMAIN_HOME/reports/bin/rwrun.sh cmdfile=/tmp/rw.cmd \
    report=/u01/app/oracle/reports/source/test_dual.rdf \
    destype=file desformat=pdf desname=/tmp/test_dual.pdf batch=yes
rm -f /tmp/rw.cmd
```

Always via the domain wrapper `$DOMAIN_HOME/reports/bin/rwrun.sh`: called
directly, `$ORACLE_HOME/bin/rwrun` lacks the component environment and
crashes or asks for a logon dialog (`01-Run/rwrun_trace.sh` documents the
chain).

When to use which:

| Need | Use |
|---|---|
| report for users / applications (web, Forms) | rwservlet → Reports server |
| batch job without the web path, but with queue, cache, security | `rwclient` – "parses and transfers a command line to the specified Reports Server" (**documented**, A.2.1) |
| quick test of a report or of the Reports installation, crash analysis | `rwrun` (`01-Run/rwrun_trace.sh`; the `15-` smoke test uses `rwconverter` + rwservlet instead) |

Consequence: a report that works with `rwrun` can still fail on the server
(different `rwserver.conf`, `securityId`, server environment, engine JVM
options) and vice versa – test on the path that production uses. The font
tests of 2026-10-19 gave the same result on both because both read the
same reptools1 font files and the same `reports.sh`
([04-ReportsFonts/README.md](../04-ReportsFonts/README.md)).

### 5.2 Oracle Net – three places for one `TNS_ADMIN`

A report connects with `userid=user/password@ALIAS` (URL, `cgicmd.dat` key,
Forms `RUN_REPORT_OBJECT`). The alias is resolved in the process that runs
the report – and the Reports processes get their environment from three
different places (**confirmed (live)** on the test host 2026-10-23,
`/proc/<pid>/environ`):

| Process | Environment from | Oracle's default for `TNS_ADMIN` |
|---|---|---|
| engines `rwEng-N` (the DB connection of a report) | `<environment id="QS">` `<envVariable name="TNS_ADMIN">` of `rwserver.conf` | none in `rwserver.conf` – without the entry the engines inherit the value of the `rwserver` process (**assumption**; with both set, engines and `rwserver` showed the same directory, **confirmed (live)**) |
| `rwserver` (Node Manager start), `rwrun`, `rwconverter` | `$DOMAIN_HOME/reports/bin/reports.sh` | set **only when empty**: `/etc` if `/etc/tnsnames.ora` exists, else `$DOMAIN_HOME/config/fmwconfig` |
| WLS_REPORTS (rwservlet; an in-process server would run the engines here) | `setDomainEnv.sh` → `setStartupEnv.sh` (startup group `REPORTS-APP-SERVERS`), then `setUserOverrides.sh` | `$DOMAIN_HOME/config/fmwconfig` – fixed in the generated `setStartupEnv.sh` |

`$DOMAIN_HOME/config/fmwconfig` holds only Oracle's sample `tnsnames.ora`
after the domain creation – an alias works there only if somebody edits a
file inside the domain, which a domain re-creation or `updateDomain` can
overwrite. This repository therefore sets **one** directory
(`TNS_ADMIN` in `environment.conf`, default `$ORACLE_BASE/admin/tns_names`)
in all three: `13-` writes the `rwserver.conf` entry and a line in the IHW
block of `reports.sh` (after Oracle's "if empty" block, so it wins);
`02-Checks/tns_admin_check.sh --apply` writes `export TNS_ADMIN` +
`-Doracle.net.tns_admin` into `setUserOverrides.sh`, which `setDomainEnv.sh`
sources **after** `setStartupEnv.sh`. Who writes what in detail, and the
check of the running processes:
[02-Checks/README.md – tns_admin_check.sh](../02-Checks/README.md#tns_admin_checksh).

---

## 6. Performance parameters (`rwserver.conf`)

Oracle's tuning chapter (**documented**, 24.3 "Tuning Reports Server
Configuration") and the `engine` element (7.2.1.8):

| Parameter | Element | Default | Meaning / rule |
|---|---|---|---|
| `initEngine` | `engine` | 1 | engines started at server start. Oracle: average run time × *minimum* request rate (10 s × 6/min → 1) |
| `maxEngine` | `engine` | 1 | upper limit. Average run time × *maximum* request rate; "maximum throughput … 2-4 engines multiplied by the number of CPUs" (dual CPU → 8, quad → 16). Too high: "could cause the operating system to crash" |
| `minEngine` | `engine` | 0 | engines always kept; "anything between 0 to initEngine" |
| `engLife` | `engine` | 50 | jobs per engine before it is replaced – "to thwart memory leaks" |
| `maxIdle` | `engine` | 30 (min) | idle engines above `minEngine` are stopped after this time |
| `callbackTimeOut` | `engine` | 90000 ms | wait for a new engine to call the server back |
| `engineResponseTimeOut` | `engine` | none | minutes without a status update of a running job (hanging engine); Oracle: "set to the maximum time a report takes", batch reports better on an own server. Here: `REPORTS_ENGINE_RESPONSE_TIMEOUT=30`, `engine_perf_analyse.sh` measures the run times (`showjobs` `timingInfo`) and proposes 2 × longest job, ≥ 5 – test host 2026-10-23: 68 jobs, longest 1 s → 5 |
| `jvmOptions` | `engine` | – | heap etc. of the **engine** JVMs |
| `maxQueueSize` | `queue` | – | jobs kept; rate × `EXPIRATION` (10/min × 480 min → 4800) |
| `cacheSize` | `cache` | – | `maxQueueSize` × average output size (4800 × 100 KB → 480 MB) |
| `maxConnect` | `connection` | – | parallel client connections |

Oracle also advises: "If you are not using the URL engine, comment the
engine element with ID="rwURLEng"".

This repository (`09-Install/13-oracle_setup_reports.sh`): `initEngine=2`,
`maxEngine=5`, `minEngine=2`, `engLife=50`, `maxConnect=300`,
`maxQueueSize=4000` (environment.conf `REPORTS_ENGINE_*`; `maxIdle` and
engine `jvmOptions` only when `REPORTS_ENGINE_MAX_IDLE` /
`REPORTS_ENGINE_JVM_OPTIONS` are set); JVM of the
**server** via `REPORTS_JVM_OPTIONS` in `reports.sh` (not `jvmOptions`,
which is for the engines). Live test 2026-10-16: regular `engLife`
recycling costs 85–661 ms per job, a crashed engine (kill -9) is replaced
within seconds after the ORB fix ([reports_user_local_ldap.md](reports_user_local_ldap.md) §7).

On a host: `05-ReportsPerformance/engine_perf_settings.sh` checks the
parameters of this table against these rules (report engine only, CPUs, RAM,
drift to `environment.conf`) and changes them with `--apply`;
`05-ReportsPerformance/engine_perf_analyse.sh` evaluates the load
(failure rate, queuing share, `maxEnginesUsed` vs. `maxEngine`, engine logs).
Live 2026-10-19: without `jvmOptions` the engines run with `-Xmx256M`
(**confirmed (live)**, engine command line), and 14.1.2 reports
`averageElapsedTime=0.0` in `getserverinfo` (**confirmed (live)**).

---

## 7. Why so complicated – the history

| Release | Reports server | How the web reached it | Process control |
|---|---|---|---|
| 6i | native C server (`rwmts60`) | CGI (`rwcgi60`) | OS / Windows service |
| 9i / 10g AS (9.0.x, 10.1.2) | server rewritten in Java, CORBA (VisiBroker ORB, `osfind`) | **rwservlet** in OC4J; CGI "maintained for backward compatibility"; **in-process server** introduced for the servlet path | **OPMN** |
| 11g | unchanged concept, WebLogic instead of OC4J; standalone server in an Oracle Instance | rwservlet in WLS_REPORTS | OPMN |
| 12c / 14c | JDK ORB instead of VisiBroker (`rwdiag` replaces `osfind`); standalone server = system component in the domain | rwservlet in WLS_REPORTS | **Node Manager** |

- The Reports server had to be reachable from many clients long before
  servlets existed (CGI, `rwclient`, Forms `RUN_REPORT_OBJECT`, other
  hosts) – hence a standalone server with its own network protocol (CORBA)
  and discovery by **name** instead of host/port.
- When the servlet came, the in-process server was added as the faster
  shortcut for the web path – but the standalone server stayed for all
  other clients and for isolation. Both modes have been carried forward
  ever since, each with its own configuration file and – since OPSS – its
  own security configuration.
- The VisiBroker → JDK ORB switch is documented ("Using rwdiag, you can
  replace the functionality of osfind available in the prior VisiBroker
  implementation" – **documented**, 2.2.4); the 6i/9i rows are general
  product history (**assumption** for the details, not quoted from the
  12c/14c books).

---

## 8. Server discovery: broadcast – the idea, and why it rather disturbs

The rwservlet, `rwclient` and Forms address a Reports server **by name**
(`server=repserver01`), not by host and port. To find it, Reports uses
(**documented**, 2.2.4 / 7.5):

| Method | How | Configured in `rwnetwork.conf` |
|---|---|---|
| **Broadcast** (default) | UDP multicast: servers announce themselves, clients ask on the multicast channel; works "within a subnet or across subnets" | `<multicast channel="228.5.6.7" port="14027" timeout="1000"/>` (**confirmed (live)**, port per environment 14021–14030) |
| **COS Naming Service** | a central naming service (`namingservice.sh`) – servers register, clients look up | `<namingService name="Cos" host=… port=…/>` |

The idea: zero configuration in a farm – start a Reports server anywhere in
the subnet and every servlet/client finds it by name; several servers can
share the load, a server can move to another host.

Why it disturbs more than it helps in a typical single-host Forms/Reports
installation (**confirmed (live)** / customer 2026-10-15, see
[reports_server_discovery_multicast.md](reports_server_discovery_multicast.md)):

- the rwservlet and the server sit on the **same host** – nothing to
  discover, but discovery still has to work
- firewalld drops the multicast packets → the server stops with
  `REP-50600 Broadcasting is disabled` (Node Manager restart loop)
- the multicast port must be **unique per environment in the subnet** – a
  test and a production domain with the same port and server name see each
  other (`REP-56040 server already exists`)
- IPv6 / interface settings, VPNs and cloud networks without multicast
  break it; Oracle itself lists a host "not in a network" and VPN
  scenarios, and recommends the naming service "if … you want to avoid
  broadcast traffic on your network" (**documented**, 10g guide 1.x)
- diagnosis needs extra tools (`rwdiag`, `tcpdump`,
  `02-Checks/reports_network_scan.sh`)

The alternative COS naming service avoids broadcast but adds another
process to run and monitor – for one host the multicast with a unique port
and an open local firewall rule is still the lighter choice.

---

## 9. Clustering – only a hint

- **In-process servers** can be grouped: `rwservlet.properties`
  `<cluster clustername="ha_cluster" clusternodes="ha_server2"/>` on every
  node, "cluster name should be same in all rwservlet.properties files.
  Cluster nodes should include in-process server names which are part of the
  cluster except the current one" (**documented**, 2.4.2).
- WLS_REPORTS is already targeted to a WebLogic cluster (`cluster_reports`,
  **confirmed (live)**) – scaling out means more managed servers on more
  hosts (each with its own in-process or standalone Reports server).
- Several standalone servers behind one rwservlet farm rely on server
  discovery (section 8) – one more reason the broadcast exists.
- Details: Publishing Reports 2.4 / 6.10 and the FMW High Availability
  Guide. Not used in this repository (single host).

---

## 10. Sources

All links checked 2026-10-17, A.2 on 2026-10-19 (HTTP 200, title matches). The Forms & Reports
14.1.2 book list links the **12.2.1.3** Reports books.

*Publishing Reports to the Web with Oracle Reports Services* 12.2.1.3:
- 2.2 Oracle Reports Services (components, in-process server, communication,
  broadcast vs. COS naming, `rwdiag`):
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_arch002.htm
- 2.4 Setting Up a High Availability Environment (`<cluster>` in
  `rwservlet.properties`):
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_arch004.htm
- 5.1 Starting and Stopping Reports Server (Node Manager, in-process start):
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_strt001.htm
- 5.5 Starting and Stopping the In-process Reports Server ("the default
  configuration"):
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_strt005.htm
- 7.2 Reports Server Configuration File (`engine`: initEngine, maxEngine,
  minEngine, engLife, maxIdle, callbackTimeOut, jvmOptions …):
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_conf002.htm
- 7.5 Network Configuration File (`rwnetwork.conf`, multicast, naming service):
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_conf005.htm
- A.2 Overview of Oracle Reports Components (`rwclient` A.2.1, `rwrun` A.2.2:
  own in-process server in the rwrun JVM, `rwbuilder.conf`, "for testing
  purposes only"):
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla002.htm
- 15.8 Managing Users and Security Policies (embedded ID store for
  in-process vs. `system-jazn-data.xml` for standalone):
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_sec_arch008.htm
- 24.3 Tuning Reports Server Configuration (engine sizing formulas, cache,
  queue):
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_tune003.htm

Older editions (history, same concepts):
- 11g – Understanding the Oracle Reports Services Architecture:
  https://docs.oracle.com/cd/E28280_01/bi.1111/b32121/pbr_arch.htm
- 10g (10.1.2) – Understanding the OracleAS Reports Services Architecture
  (in-process server, CGI "maintained for backward compatibility", COS
  naming "to avoid broadcast traffic", OPMN):
  https://docs.oracle.com/cd/B14099_19/bi.1012/b14048/pbr_arch.htm

Related documents in this repository:
- [reports_server_discovery_multicast.md](reports_server_discovery_multicast.md) – discovery in depth, REP-50600 / REP-56040
- [reports_user_local_ldap.md](reports_user_local_ldap.md) – standalone server + WebLogic users, JVM/ORB fixes
- [weblogic_middleware_architecture.md](weblogic_middleware_architecture.md) – domain, Node Manager, consoles
- `09-Install/docs/13-reports-detail-settings.md` – how `13-` configures the standalone server
- `01-Run/rwserver_status.sh` – status of the Reports server and its engines; `01-Run/rwrun_trace.sh` – traced `rwrun` runs (section 5.1)
- `05-ReportsPerformance/engine_perf_settings.sh` / `engine_perf_analyse.sh` – parameter review against section 6 and load analysis
- `02-Checks/tns_admin_check.sh` – `TNS_ADMIN` in `rwserver.conf`, `reports.sh`, `setUserOverrides.sh` and of the running processes (section 5.2)
