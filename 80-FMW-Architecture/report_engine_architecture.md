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
| **ReportsTools instance** | configuration for `rwrun`, `rwconverter`, `rwbuilder` (no own process) | – |

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
| own JVM settings | `REPORTS_JVM_OPTIONS` in `$DOMAIN_HOME/reports/bin/reports.sh` (heap, process-reaper fix, ORB timeouts – [reports_user_local_ldap.md](reports_user_local_ldap.md) §7) independent of WLS_REPORTS. Also an **own JDK**: `reports.sh` puts `$ORACLE_HOME/oracle_common/jdk/bin` first in `PATH`, the engines run on the FMW-bundled JDK, not on `JDK_HOME` (**confirmed (live)** 2026-10-19 – 17.0.12 on the test host; open: supported way to update it) |
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
| `engineResponseTimeOut` | `engine` | none | maximum time without a status update of a running job (hanging engine) |
| `jvmOptions` | `engine` | – | heap etc. of the **engine** JVMs |
| `maxQueueSize` | `queue` | – | jobs kept; rate × `EXPIRATION` (10/min × 480 min → 4800) |
| `cacheSize` | `cache` | – | `maxQueueSize` × average output size (4800 × 100 KB → 480 MB) |
| `maxConnect` | `connection` | – | parallel client connections |

Oracle also advises: "If you are not using the URL engine, comment the
engine element with ID="rwURLEng"".

This repository (`09-Install/13-oracle_setup_reports.sh`): `initEngine=2`,
`maxEngine=5`, `minEngine=2`, `engLife=50`, `maxConnect=300`,
`maxQueueSize=4000` (environment.conf `REPORTS_ENGINE_*`); JVM of the
**server** via `REPORTS_JVM_OPTIONS` in `reports.sh` (not `jvmOptions`,
which is for the engines). Live test 2026-10-16: regular `engLife`
recycling costs 85–661 ms per job, a crashed engine (kill -9) is replaced
within seconds after the ORB fix ([reports_user_local_ldap.md](reports_user_local_ldap.md) §7).

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

All links checked 2026-10-17 (HTTP 200, title matches). The Forms & Reports
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
- `01-Run/rwserver_status.sh`, `01-Run/rwrun_trace.sh` – status and in-process test runs
