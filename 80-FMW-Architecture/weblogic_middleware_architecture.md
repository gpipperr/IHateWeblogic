# WebLogic / Fusion Middleware architecture – how the components work together

Base overview for a Forms & Reports 14.1.2 domain: which processes exist,
who starts whom, how they talk to each other, who provides which console,
and where each component has its home, its configuration and its logs.
The other documents in this folder go into single topics in depth; this one
is the map they refer to.

Statements are marked as described in [README.md](README.md)
(**confirmed (live)** = seen on the test domain 2026-10-16,
**documented** = Oracle documentation, see [Sources](#9-sources)).
Paths use the layout of this repository (`ORACLE_BASE=/u01/app/oracle`,
domain `fr_domain`) – replace them with your `environment.conf` values.

---

## 1. Terms – the four "homes"

| Term | Path (this layout) | What it is | Changes when |
|---|---|---|---|
| **Oracle Home** (`ORACLE_HOME`, older: Middleware Home) | `/u01/app/oracle/fmw` | the installed **software**: `wlserver/` (WebLogic), `oracle_common/` (JRF, OPSS, WLST, EM libraries), `forms/`, `reports/`, `bin/` (`frmweb`, `rwserver`, `frmcmp_batch` …), `OPatch/` | installation, patches – identical on every host of the same version |
| **WebLogic Home** (`WL_HOME`) | `$ORACLE_HOME/wlserver` | the WebLogic Server part of the Oracle Home | patches |
| **Domain Home** (`DOMAIN_HOME`) | `/u01/app/oracle/domains/fr_domain` | the **configuration and runtime state** of one domain: `config/config.xml`, `config/fmwconfig/` (OPSS, components), `servers/<name>/` (logs, state, cache), `nodemanager/`, `bin/` (start scripts) | configuration, every start (logs, tmp) |
| **Node Manager Home** | `$DOMAIN_HOME/nodemanager` | properties, log and process ids of the per-domain Node Manager | NM configuration |

Further homes of the platform:

| Term | Path | Note |
|---|---|---|
| JDK | `/u01/app/oracle/java/jdk-21` (`JDK_HOME`) | used by all JVMs of the domain (`setDomainEnv.sh`, `setNMJavaHome.sh`) |
| Inventory | `/u01/app/oracle/oraInventory` | OUI/OPatch registry of the Oracle Homes |
| Application directory | `$ORACLE_HOME/user_projects/applications/fr_domain` | `em.ear` lives here (**confirmed (live)**, `config.xml` source path) |
| Autostart control (this repo) | `$ORACLE_BASE/admin/fr_domain/ctrl` | `fmw_ctl.sh`, WLST keyfiles, logs – `09-Install/30-configure_autostart.sh` |

**Rule of thumb:** *Oracle Home = what Oracle delivered, Domain Home = what
you configured.* Never edit files under `$ORACLE_HOME/.../templates` to change
a domain – they are the source for new domains and are replaced by patches.
(**documented**, 11g Administrator's Guide "Understanding Oracle Fusion
Middleware Concepts", 14c Understanding Oracle Fusion Middleware)

---

## 2. Big picture

```
                         Browser / Java Web Start / FSAL / curl
                                         |
                                  https :443 / :80
                                         |
                         +---------------v----------------+
                         |  NGINX reverse proxy (OS)      |   /forms/* -> :9001
                         |  /etc/nginx/conf.d/*.conf      |   /reports/* -> :9002
                         +-------+----------------+-------+   /em, /console -> :7001
                                 |                |
 ================================|================|===== WebLogic domain fr_domain ====
                                 |                |
 +-------------------------------|----------------|-------------------------------+
 |  Machine "AdminServerMachine" (one host)       |                               |
 |                               |                |                               |
 |  +---------------------+      |                |                               |
 |  | Node Manager  :5556 |<--------------------------------------+               |
 |  | (Java, per domain)  |  starts / kills / monitors            |               |
 |  +--+-------+------+---+      |                |               |               |
 |     |       |      |          |                |               |               |
 |     v       v      v          |                |               |               |
 |  +-----------------------+    |                |       +-------+------------+  |
 |  | AdminServer   :7001   |<---+---- t3 / JMX / config ----| (asks NM to start |  |
 |  |  - domain config      |    |                |       |  managed servers)  |  |
 |  |  - EM  (/em)          |    |                |       +--------------------+  |
 |  |  - Remote Console     |    |                |                               |
 |  |    (/console)         |    |                |                               |
 |  |  - embedded LDAP      |    |                |                               |
 |  +-----------+-----------+    |                |                               |
 |              | config push / runtime MBeans   |                               |
 |      +-------+-------------------+            |                               |
 |      v                           v            |                               |
 |  +------------------------+  +------------------------+                       |
 |  | WLS_FORMS     :9001    |  | WLS_REPORTS    :9002   |                       |
 |  | cluster_forms          |  | cluster_reports        |                       |
 |  |  formsapp (frmservlet, |  |  reports.ear           |                       |
 |  |   Listener Servlet)    |  |   (rwservlet)          |                       |
 |  +-----------+------------+  +-----------+------------+                       |
 |              | spawns                    | CORBA/IIOP (+ UDP multicast         |
 |              v one per session           |   discovery :14027)                 |
 |  +------------------------+  +-----------v------------+                       |
 |  | frmweb  (C, "forms1")  |  | rwserver "repserver01" |<-- started by the NM  |
 |  | Forms runtime          |  | Java SE + engines      |   (system component)  |
 |  +-----------+------------+  |  rwEng-0 / rwEng-1 ... |                       |
 |              |               +-----------+------------+                       |
 +--------------|---------------------------|------------------------------------+
                | SQL*Net                   | SQL*Net (report data)
                v                           v
 +--------------------------------------------------------------------------------+
 |  Oracle Database                                                               |
 |   application schemas (forms/report data)                                      |
 |   RCU schemas of the domain: <PREFIX>_STB  service table (config of the        |
 |   other schemas), _OPSS policy/credential/key store, _IAU audit, _WLS /        |
 |   _WLS_RUNTIME (WebLogic persistence)                                          |
 +--------------------------------------------------------------------------------+
```

- **confirmed (live)**: listeners `127.0.0.1:5556/7001/9001/9002` (Java),
  `:80/:443` NGINX; deployments from `config.xml`: `em` and `opss-rest` →
  AdminServer, `formsapp#14.1.2` → `cluster_forms`, `reports#14.1.2` →
  `cluster_reports`; system components `forms1` (FORMS), `reptools1`
  (ReportsToolsComponent), `repserver01` (ReportsServerComponent), all on
  machine `AdminServerMachine` (NM type `Plain`); data sources for
  `DEV_STB`, `DEV_OPSS`, `DEV_IAU_APPEND`/`_VIEWER`, `DEV_WLS`,
  `DEV_WLS_RUNTIME`.
- WebLogic listens on `localhost` only (`WLS_LISTEN_ADDRESS=localhost`) –
  clients reach it only through NGINX (`09-Install/docs/00-root_os_network.md`).

---

## 3. The building blocks

### 3.1 Domain

A **domain** is the unit of administration: one `config.xml`, one security
realm, exactly **one Administration Server**, any number of managed servers,
clusters, machines and system components. (**documented**, Understanding
Domain Configuration – the 10.3 / 11g editions explain it best)

```
Domain fr_domain  ($DOMAIN_HOME/config/config.xml)
 |
 +-- Administration Server  AdminServer
 +-- Cluster cluster_forms    -- Managed Server WLS_FORMS
 +-- Cluster cluster_reports  -- Managed Server WLS_REPORTS
 +-- Machine AdminServerMachine
 |     +-- Node Manager  (localhost:5556, Plain)
 |     +-- servers + system components assigned to this machine
 +-- System components (Node Manager controlled, no WebLogic JVM)
 |     +-- forms1       FORMS                  (configuration of frmweb)
 |     +-- reptools1    ReportsToolsComponent  (configuration of rwrun/rwconverter...)
 |     +-- repserver01  ReportsServerComponent (process rwserver)
 +-- Security realm myrealm (DefaultAuthenticator = embedded LDAP in the AdminServer)
 +-- JDBC data sources (opss-data-source, WLSSchemaDataSource, LocalSvcTblDataSource ...)
 +-- Applications (em, formsapp, reports, opss-rest, dms ...)
```

### 3.2 Administration Server

- Holds the **master copy of the configuration**; all changes go through it
  (WLST `edit()/startEdit()/activate()`, EM, Remote Console) and it
  distributes them to the managed servers. (**documented**)
- Hosts the **embedded LDAP** (default authenticator: users, groups of
  `myrealm`) – managed servers keep a replica.
- Hosts the consoles: **Fusion Middleware Control (EM)** and the
  **WebLogic Remote Console** – see section 5.
- Managed servers run without it (Managed Server Independence, MSI – they
  use their local copy of the configuration), but no configuration change
  and no EM is possible while it is down. (**documented**, Managing Server
  Startup and Shutdown)

### 3.3 Managed servers and clusters

- Java EE containers that run the applications: `WLS_FORMS` (Forms servlet
  and Listener Servlet), `WLS_REPORTS` (rwservlet).
- At start a managed server contacts the AdminServer (admin URL) for its
  configuration; the NM-side file `servers/<ms>/data/nodemanager/startup.properties`
  carries the admin URL and JVM arguments. (**confirmed (live)**: file
  present for WLS_FORMS/WLS_REPORTS)
- Forms and Reports are each targeted to a **cluster** (`cluster_forms`,
  `cluster_reports`) even with one server – scaling out = adding servers.

### 3.4 Node Manager

- A separate Java process that starts, kills and monitors servers **and**
  system components of the domain on its machine; the AdminServer (and WLST
  `nmConnect`) talk to it. (**documented**, Node Manager Administrator's
  Guide)
- 12c/14c default: **per-domain Node Manager** in `$DOMAIN_HOME/nodemanager`
  (11g/10.3: one per host in `$WL_HOME/common/nodemanager`).
- Here: `ListenAddress=localhost`, `ListenPort=5556`,
  `SecureListener=false` (machine NM type `Plain`),
  `CrashRecoveryEnabled=false` (**confirmed (live)**,
  `nodemanager.properties`).
- Credentials: the NM user/password are stored twice – encrypted in
  `config.xml` (domain side) and hashed in
  `$DOMAIN_HOME/config/nodemanager/nm_password.properties` (NM side); see
  `09-Install/docs/80-oracle_security.md`.
- State per server: `servers/<name>/data/nodemanager/<name>.state`
  (`RUNNING`, `SHUTDOWN`, `FAILED_NOT_RESTARTABLE` …), `.pid`, `.lck`,
  `boot.properties`, `startup.properties`. A server started with
  `startManagedWebLogic.sh` has no such NM-written state → the NM sees
  `SHUTDOWN` (see section 4).

### 3.5 System components (Forms, Reports)

12c replaced **OPMN** and the **Oracle Instance** (`$ORACLE_INSTANCE`) of 11g
by system components that the Node Manager controls. (**documented**,
Understanding Oracle Fusion Middleware 12c/14c "system components")

| Component | Type in `config.xml` | Own process? | Started by | Configuration |
|---|---|---|---|---|
| `forms1` | `FORMS` | no – configuration only | – (the `frmweb` processes are spawned by WLS_FORMS) | `$DOMAIN_HOME/config/fmwconfig/components/FORMS/instances/forms1/` |
| `reptools1` | `ReportsToolsComponent` | no – configuration for `rwrun`, `rwconverter`, `rwbuilder` | – (tools via `$DOMAIN_HOME/reports/bin/*.sh`) | `$DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/reptools1/` |
| `repserver01` | `ReportsServerComponent` | **yes**, `rwserver` (Java SE) + engines | Node Manager (`nmStart … serverType='ReportsServerComponent'`) | `$DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent/repserver01/` |

**confirmed (live)**: `frmweb webfile=HTTP-0,default` processes are children
of the WLS_FORMS JVM; `rwserver` is a child of `rwserver.sh`, which the Node
Manager started.

### 3.6 Database (RCU schemas)

The domain is a JRF domain: it needs the RCU repository. `_STB` (service
table) tells the domain where the other schemas are; `_OPSS` holds the
policy, credential and key stores (shared by all JVMs of the domain incl.
the standalone Reports server); `_IAU*` audit; `_WLS`/`_WLS_RUNTIME`
WebLogic persistence (leasing, JMS/JDBC stores). (**documented**,
`09-Install/docs/07-oracle_setup_repository.md`)

---

## 4. Who starts whom – the control chain

```
 systemd  fmw-fr_domain.service   (09-Install/30-configure_autostart.sh)
   |   ExecStart = fmw_ctl.sh start all
   v
 fmw_ctl.sh  ($ORACLE_BASE/admin/fr_domain/ctrl)
   |-- 1. startNodeManager.sh ---------------> Node Manager :5556
   |-- 2. WLST nmConnect + nmStart(AdminServer) ----+
   |-- 3. WLST connect(AdminServer) + start(WLS_*)  |   AdminServer asks the NM
   |-- 4. WLST nmStart(repserver01, ReportsServerComponent)
   v                                                v
 Node Manager
   |-- startWebLogic.sh -> java AdminServer
   |-- startWebLogic.sh -> java WLS_FORMS ------> frmweb (one per Forms session)
   |-- startWebLogic.sh -> java WLS_REPORTS
   +-- rwserver.sh      -> rwserver repserver01 --> engines rwEng-0, rwEng-1 ...
```

- **confirmed (live)** process trees: AdminServer / WLS_REPORTS / WLS_FORMS:
  `java` ← `startWebLogic.sh` ← Node Manager JVM. A server started by hand
  instead: `java` ← `startWebLogic.sh` ← `startManagedWebLogic.sh` – no NM
  in the chain. The NM then reports `SHUTDOWN`, `fmw_ctl.sh`/systemd skip it
  and the next `nmStart` fails on the occupied port. `01-Run/startStop.sh`
  shows this in its column `Ctrl` (`NM`/`script`) and starts through
  `fmw_ctl.sh` / the NM since 2026-10-16.
- Order matters: NM → AdminServer → managed servers → Reports server; stop
  in reverse. The Reports server needs the AdminServer when it is secured
  (embedded LDAP, [reports_user_local_ldap.md](reports_user_local_ldap.md)).

---

## 5. Consoles – who provides what

```
   http(s)://<host>/em        http(s)://<host>/console       WLST / REST
            |                          |                           |
            v                          v                           v
 +----------------------+  +------------------------+  +-----------------------+
 | Fusion Middleware    |  | WebLogic Remote Console|  | wlst.sh  (t3:7001)    |
 | Control  "EM"        |  | hosted (14.1.2)        |  | /management/weblogic  |
 | em.ear               |  | wls-remote-console.war |  |  (REST, 401 w/o auth) |
 +----------+-----------+  +-----------+------------+  +-----------+-----------+
            |  all deployed on / served by the AdminServer         |
            +---------------------+--------------------------------+
                                  v
                    AdminServer: domain runtime MBean server
                      |              |                 |
             managed servers   Node Manager      OPSS (DB) / embedded LDAP
             (runtime MBeans)  (system components) (security, app roles)
```

| Console | URL | Provided by | Used for |
|---|---|---|---|
| **Fusion Middleware Control (EM)** | `/em` | application `em` (`em.ear`) deployed **only on the AdminServer** (**confirmed (live)**, `config.xml`) | FMW view: Forms/Reports components, start/stop of system components, logs (ODL), OPSS security (application roles – "Add Principal"), MBean browser, configuration of `rwserver.conf`/`formsweb.cfg` |
| **WebLogic Remote Console** (hosted) | `/console` | `wlserver/server/lib/wls-remote-console.war` (**confirmed (live)**: `/console` → `/console/welcome`; no classic console application found under `wlserver/`) – the hosted Remote Console replaces the classic WebLogic Administration Console in 14.1.2 | WebLogic view: servers, clusters, data sources, realm users/groups |
| WLST | `t3://localhost:7001`, NM `localhost:5556` | `$ORACLE_HOME/oracle_common/common/bin/wlst.sh` | scripting – everything in this repository |

Consequences:

- **AdminServer down = no EM, no console**; managed servers and the Reports
  server keep running (MSI), configuration changes wait.
- EM reads the state of system components through the NM and the
  AdminServer – a Reports server started past the NM is invisible to EM.
- EM's own logs: `$DOMAIN_HOME/sysman/log/emoms.log` (+ `emoms_startup.log`,
  `.trc`) (**confirmed (live)**).
- The EM user search "Add Principal" goes through libOVD of the AdminServer –
  see [em_principal_search_libovd.md](em_principal_search_libovd.md).

---

## 6. How the parts are joined

| From → To | Channel | Configured in |
|---|---|---|
| AdminServer ↔ managed servers | t3 (admin URL), configuration download at start, change distribution, runtime MBeans | `config.xml` (listen address/port), `startup.properties` |
| AdminServer / WLST → Node Manager | NM protocol, `plain` on `localhost:5556`, NM credentials | `config.xml` machine `<node-manager>`, `nodemanager.properties`, `nm_password.properties` |
| Node Manager → servers | starts `startWebLogic.sh` / `rwserver.sh`, watches the process | `servers/<name>/data/nodemanager/` |
| NGINX → WebLogic | HTTP proxy `localhost:7001/9001/9002`, forwards Host / X-Forwarded-* | `/etc/nginx/conf.d/oracle-wls.conf` |
| frmservlet → frmweb | WLS_FORMS spawns `frmweb` per session, Listener Servlet relays the client traffic | `formsweb.cfg`, `default.env` (`$DOMAIN_HOME/config/fmwconfig/servers/WLS_FORMS/applications/formsapp_14.1.2/config/`) |
| rwservlet → rwserver | CORBA/IIOP, server found by name via UDP multicast (`rwnetwork.conf`, port 14027 here) | [reports_server_discovery_multicast.md](reports_server_discovery_multicast.md) |
| all JVMs → OPSS | `jps-config.xml` (WebLogic) / `jps-config-jse.xml` (standalone Reports server) → `opss-data-source` | `$DOMAIN_HOME/config/fmwconfig/` |
| frmweb / Reports engines → application DB | SQL*Net (`TNS_ADMIN`) | `default.env`, report `userid=` |

---

## 7. Where is what – homes, configuration, logs

`D` = `$DOMAIN_HOME` (`/u01/app/oracle/domains/fr_domain`),
`O` = `$ORACLE_HOME` (`/u01/app/oracle/fmw`). All rows **confirmed (live)**.

| Component | Software | Configuration | Logs |
|---|---|---|---|
| Node Manager | `O/wlserver` | `D/nodemanager/nodemanager.properties`, `D/config/nodemanager/nm_password.properties` | `D/nodemanager/nodemanager.log` |
| AdminServer | `O/wlserver`, `O/oracle_common` | `D/config/config.xml` (domain), `D/servers/AdminServer/security/boot.properties` | `D/servers/AdminServer/logs/AdminServer.log` (server log), `AdminServer.out` (stdout when started by the NM), `AdminServer-diagnostic.log` (ODL, FMW components), `access.log`, **domain log** `fr_domain.log` |
| EM (FMW Control) | `O/user_projects/applications/fr_domain/em.ear`, `O/em` | `D/sysman/config/` | `D/sysman/log/emoms.log`, `emoms_startup.log` |
| WLS_FORMS | `O/forms/j2ee/formsapp.ear` | `D/config/fmwconfig/servers/WLS_FORMS/applications/formsapp_14.1.2/config/` (`formsweb.cfg`, `default.env`, `registry/`) | `D/servers/WLS_FORMS/logs/WLS_FORMS.log`, `.out`, `WLS_FORMS-diagnostic.log`, `formsapp-diagnostic.log`, `access.log` |
| Forms runtime `frmweb` | `O/bin/frmweb`, `O/forms` | `D/config/fmwconfig/components/FORMS/instances/forms1/` (`server/webutil.cfg`, `admin/resource`, `bin/*.sh` tool wrappers) | `D/system_components/FORMS/forms1/trace/` (Forms trace, crash dumps) |
| WLS_REPORTS / rwservlet | `O/reports/j2ee/reports.ear` | `D/config/fmwconfig/servers/WLS_REPORTS/applications/reports_14.1.2/configuration/` (`rwservlet.properties`, `cgicmd.dat`, `rwserver.conf` of the in-process server) | `D/servers/WLS_REPORTS/logs/WLS_REPORTS.log`, `WLS_REPORTS-diagnostic.log`, `reports/` |
| Reports server `repserver01` | `O/bin/rwserver`, `O/reports` | `D/config/fmwconfig/components/ReportsServerComponent/repserver01/` (`rwserver.conf`, `rwnetwork.conf`, `logging.xml`, `jdbcpds.conf`), JVM: `D/reports/bin/reports.sh` | `D/servers/repserver01/logs/` (`rwserver_diagnostic.log`, `rwEng-N_diagnostic.log`, `repserver01.out`, `zrclient_diagnostic.log`) |
| Reports tools `reptools1` | `O/bin/rwrun`, `rwconverter` … | `D/config/fmwconfig/components/ReportsToolsComponent/reptools1/` (`rwbuilder.conf`, `rwnetwork.conf`), wrappers `D/reports/bin/*.sh` | per call (`~/oradiag_<user>/` ADR for crashes) |
| OPSS | `O/oracle_common/modules/oracle.jps` | `D/config/fmwconfig/jps-config.xml`, `jps-config-jse.xml`, DB schema `_OPSS` | in the server logs (`*-diagnostic.log`) |
| Autostart (this repo) | – | `$ORACLE_BASE/admin/fr_domain/ctrl/` (`fmw_env.sh`, keyfiles) | `$ORACLE_BASE/admin/fr_domain/ctrl/log/` |

Log families:

- `<server>.log` – WebLogic server log (BEA-/WL- messages), rotated by
  WebLogic; `<domain>.log` on the AdminServer collects important messages
  of all servers. (**documented**, Configuring Log Files and Filtering Log
  Messages)
- `<server>.out` – stdout/stderr of a JVM started by the Node Manager.
- `*-diagnostic.log` – **ODL** (Oracle Diagnostic Logging) of the FMW
  components (JRF, OPSS, Forms, Reports), configured in `logging.xml`,
  readable in EM "Log Messages". (**documented**, Administrator's Guide 11g
  "Managing Log Files and Diagnostic Data")
- ADR (`D/diag/`, `~/oradiag_*`) – incidents of native code (`frmweb`,
  `rwserver` engines, tools).

---

## 8. How it evolved – why old documentation still helps

| Release | Middle tier | Control of non-Java processes | Console |
|---|---|---|---|
| 10g AS (10.1.2) | OC4J containers in an Oracle Application Server instance | **OPMN** (`opmnctl`) | Application Server Control |
| 11g (11.1.1 / 11.1.2) | **WebLogic domain** for Java EE + separate **Oracle Instance** (`$ORACLE_INSTANCE`) for system components | **OPMN** inside the instance; WebLogic servers via Node Manager | **Fusion Middleware Control** (EM, on the AdminServer) + WebLogic Administration Console |
| 12c (12.2.1.x) | WebLogic domain only – system components moved into the domain | **Node Manager** (OPMN removed), `startComponent.sh`/`stopComponent.sh` | EM + WebLogic Administration Console |
| 14c (14.1.2) | as 12c | Node Manager | EM + **WebLogic Remote Console** (hosted under `/console`; classic console not found on the test domain) |

The 10.3/11g guides explain domain, Node Manager and logging concepts in
more detail than the 12c/14c books, which mostly describe *what changed*.
The concepts (one AdminServer per domain, MSI, NM per machine, server log
vs. domain log, ODL) are unchanged – read the old chapter for the "why",
check the 14c book for current names and paths.

---

## 9. Sources

All links checked 2026-10-16 (HTTP 200, title matches).

**Concepts – older editions (best explanations of the basics)**

- WebLogic Server 10.3 – *Understanding WebLogic Server Domains* (domain,
  AdminServer, managed servers, clusters, machines):
  https://docs.oracle.com/cd/E13222_01/wls/docs103/domain_config/understand_domains.html
- WebLogic Server 10.3 – *Node Manager Overview*:
  https://docs.oracle.com/cd/E13222_01/wls/docs103/nodemgr/overview.html
- Fusion Middleware 11g – *Administrator's Guide*, chapter *Understanding
  Oracle Fusion Middleware Concepts* (Middleware Home, Oracle Home, WebLogic
  domain, **Oracle Instance**, OPMN, system components, Fusion Middleware
  Control): https://docs.oracle.com/cd/E23943_01/core.1111/e10105/concepts.htm
- Fusion Middleware 11g – *Concepts Guide* (overview of the components and of
  administration/operations):
  https://docs.oracle.com/cd/E21764_01/core.1111/e10103/toc.htm
- WebLogic Server 11g (10.3.6) – *Understanding Domain Configuration*:
  https://docs.oracle.com/cd/E23943_01/web.1111/e13716/understand_domains.htm
- WebLogic Server 11g – *Node Manager Administrator's Guide*:
  https://docs.oracle.com/cd/E23943_01/web.1111/e13740/overview.htm
- WebLogic Server 11g – *Managing Server Startup and Shutdown* (MSI, start
  order, boot identity): https://docs.oracle.com/cd/E23943_01/web.1111/e13708/toc.htm
- WebLogic Server 11g – *Configuring Log Files and Filtering Log Messages*
  (server log, domain log, stdout): https://docs.oracle.com/cd/E23943_01/web.1111/e13739/toc.htm
- Fusion Middleware 11g – *Administrator's Guide*, *Managing Log Files and
  Diagnostic Data* (ODL, EM log viewer):
  https://docs.oracle.com/cd/E23943_01/core.1111/e10105/logs.htm
- Forms 11g – *Forms Services Deployment Guide*, *Basics of Deploying Oracle
  Forms Applications* (Forms servlet, Listener Servlet, frmweb):
  https://docs.oracle.com/cd/E28280_01/web.1111/e10240/basics.htm
- Reports 11g – *Publishing Reports to the Web*, *Understanding the Oracle
  Reports Services Architecture*:
  https://docs.oracle.com/cd/E28280_01/bi.1111/b32121/pbr_arch.htm

**Current editions**

- *Understanding Oracle Fusion Middleware* 14.1.2:
  https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/ascon/index.html
  (12.2.1.4: https://docs.oracle.com/en/middleware/fusion-middleware/12.2.1.4/ascon/index.html)
- *Administering Oracle Fusion Middleware* 14.1.2 (EM, starting/stopping,
  logs): https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/asadm/index.html
  (12.2.1.4: https://docs.oracle.com/en/middleware/fusion-middleware/12.2.1.4/asadm/index.html)
- *Understanding Domain Configuration for Oracle WebLogic Server* 14.1.2:
  https://docs.oracle.com/en/middleware/fusion-middleware/weblogic-server/14.1.2/domcf/index.html
- *Administering Node Manager for Oracle WebLogic Server* 14.1.2:
  https://docs.oracle.com/en/middleware/fusion-middleware/weblogic-server/14.1.2/nodem/index.html
- *Working with Oracle Forms* 14.1.2:
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/working-forms/index.html
- Reports: the Forms & Reports 14.1.2 book list
  (https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/books.html)
  links the **12.2.1.3** Reports books – *Publishing Reports to the Web*,
  *Understanding the Oracle Reports Services Architecture*:
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_arch.htm

**Related documents in this repository**

- [reports_server_discovery_multicast.md](reports_server_discovery_multicast.md) – rwservlet ↔ rwserver discovery
- [reports_user_local_ldap.md](reports_user_local_ldap.md) – OPSS / identity store of the standalone Reports server
- [em_principal_search_libovd.md](em_principal_search_libovd.md) – EM user search, libOVD
- `01-Run/README.md` – `startStop.sh`, column `Ctrl`, Node Manager control
- `09-Install/docs/80-oracle_security.md` – Node Manager credentials, boot identity
