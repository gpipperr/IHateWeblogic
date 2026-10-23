# 80-FMW-Architecture – how Forms/Reports/WebLogic work internally

Background knowledge gained while installing, operating and debugging
FMW 14.1.2 environments. These documents are neither installation steps
(`09-Install/`) nor operating procedures (`01-Run/`, `07-Maintenance/`,
`70-Customer-Projects/`) – they explain **why** something behaves the way it
does, so that the scripts, docs and cookbooks can refer to one place.

Every statement is marked by how it is backed:

| Marker | Meaning |
|---|---|
| **confirmed (code)** | read from the bytecode of the shipped JARs (`javap -c`) |
| **confirmed (live)** | reproduced on the test host or seen at a customer, with date |
| **documented** | Oracle documentation / MOS note, not reproduced |
| **assumption** | plausible, not verified – to be checked |

## Documents

| Document | Topic |
|---|---|
| [weblogic_middleware_architecture.md](weblogic_middleware_architecture.md) | **Start here – base overview:** Oracle Home vs. Domain Home vs. Node Manager home, AdminServer / managed servers / clusters / Node Manager / system components (Forms, Reports) and how they are joined (t3, NM protocol, CORBA, OPSS DB, NGINX), who starts whom (systemd → `fmw_ctl.sh` → NM), who provides EM and the Remote Console, table of software / configuration / log locations per component, evolution 10g → 11g → 12c → 14c, Oracle sources incl. the older guides |
| [rcu_middleware_architecture.md](rcu_middleware_architecture.md) | RCU and the FMW repository: schemas and who uses them (ASCII), schema version registry `SYSTEM.SCHEMA_VERSION_REGISTRY$` (also: missing registry → RCU cannot drop), service table `_STB` with encrypted passwords, where the schema passwords live, password expiry of profile `DEFAULT` → own profile `RCU_USER`, patching vs. upgrade (OPatch vs. Upgrade Assistant, no PSA since 12c) – theory for phase 8 |
| [report_engine_architecture.md](report_engine_architecture.md) | Reports server and engines: in-process (Oracle default, inside WLS_REPORTS, WebLogic realm) vs. standalone server (own JVM, Node Manager, `jps-config-jse.xml`), the two `rwserver.conf` files, who starts the engines, why the WebLogic console shows only WLS_REPORTS, performance parameters with Oracle's sizing formulas, history 6i → 14c (CGI, VisiBroker/OPMN → JDK ORB/Node Manager), broadcast discovery – idea and why it disturbs on one host, clustering hint, Oracle sources |
| [reports_server_discovery_multicast.md](reports_server_discovery_multicast.md) | How Reports servers, the rwservlet and the Reports tools find each other (UDP multicast, `rwnetwork.conf`), why a server stops with `REP-50600`/`REP-56040`, active search of the network with `rwdiag`/`DiagServerLocator`, hardening ideas, prerequisites and diagnosis |
| [report_server_image_handling.md](report_server_image_handling.md) | Images in migrated reports: embedded vs. Link File vs. *Read from File*, `REPORTS_PATH` search, no fallback for Windows paths (`REP-108`), `<folderAccess>` – one `<read>`, `;`-separated, last element wins, no subdirectories (`REP-56132`, test series), migration with `rwconverter` |
| [reports_user_local_ldap.md](reports_user_local_ldap.md) | Who authenticates whom: standalone Reports server (Java SE, `jps-config-jse.xml`) vs. WebLogic realm; identity store switched to the embedded LDAP so `monUser`/`RW_MONITOR` and `RepRunner`/`RW_EXECREPORTS` work with `securityId`; slow first request explained (process reaper / ADR wait, stale CORBA IOR + 60 s ORB connect timeout) and fixed – test run with findings |
| [em_principal_search_libovd.md](em_principal_search_libovd.md) | EM "Add Principal" finds no users: the EM search goes through libOVD; the Reports server rewrites the shared libOVD config and leaves `ovd.lok`, an AdminServer started with it has no LDAP adapter – trace, test series, fix in the start scripts |
| [weblogic_outbound_connections.md](weblogic_outbound_connections.md) | What a Forms/Reports domain sends to other hosts (nothing to the internet – confirmed by capture), the **external-DTD trap** (JAXP downloads `java.sun.com` DTDs; refused = 55 ms, dropped = 130 s, silent firewall = hangs forever), mitigations (`accessExternalDTD`, `sun.net.client` timeouts, `/etc/hosts`), how to measure (tcpdump, ss, jstack, root-free reproducer) |
| [forms_runtime_architecture.md](forms_runtime_architecture.md) | How a Forms session runs: frmservlet / lservlet / one `frmweb` per session (child of WLS_FORMS, outside the heap), config sections and inheritance from `[default]`, **runtime pooling** (prestart in `[default]` = 50 idle processes, Oracle advice), timeout chain `heartBeat` < `FORMS_TIMEOUT` / `session-timeout`, shared FMX memory, `maxRuntimeProcesses`, logs / ODL levels / dumps |
| [apex_architecture.md](apex_architecture.md) | Oracle APEX + ORDS beside Forms: the parts of a request (Nginx, ORDS standalone, pool user, APEX engine, `ORDS_METADATA`), the ORDS configuration directory, the **proxy right** (`GRANT CONNECT THROUGH ORDS_PUBLIC_USER`) for APEX and REST schemas, APEX page flow, REST modules / privileges / OAuth2 client credentials, REST inside an APEX session (`apex_session.attach`), short history mod_plsql → HTML DB → APEX Listener → ORDS |
| [clone_golden_image.md](clone_golden_image.md) | Clone-capable installation / golden image: which socket binds where (WebLogic, Node Manager, SSL ports, Reports ORB via `ORBServerHost`, Coherence, `frmweb`, multicast), what holds the host name / IP / machine identity (JDBC, OPSS, `*.des3` = disk UUID, Nginx certificate), what changes after a clone, recipe; check `02-Checks/clone_check.sh` |
| [java_jlink_forms_env.md](java_jlink_forms_env.md) | Own Java runtime for the Forms client: module system, JMOD files, `jlink` / `jdeps` (and why `jdeps` misses service providers), module list for Forms 14.1.2, **cross-build of a Windows runtime on Linux** (61 MB), CA inside the runtime's `cacerts`, first real FSAL session against the test host with a Linux `jlink` runtime (2026-10-22), JEP 493 outlook |
| [forms_jakob_webutil.md](forms_jakob_webutil.md) | WebUtil and JACOB (Java–COM bridge for OLE/Office automation): architecture, download source and checksums of JACOB 1.21, files and locations, `webutil.cfg` syslib list, signing, state of the test host; **signing** (how Oracle intends it, `extensions.jnlp` = own signer, code-signing / TLS certificates, who checks: Java Web Start vs. FSAL), maintenance after patches, client distribution concept (login script, software distribution, GPO) |

## Where the scripts point here

The script READMEs describe **what** a script checks and link to these
documents for the **why**:

| Script(s) | Background |
|---|---|
| `02-Checks/java_check.sh`, `10-Monitoring/cve_inventory.sh` (two JDKs – WebLogic on `JDK_HOME`, Reports engines on `oracle_common/jdk`) | [weblogic_middleware_architecture.md](weblogic_middleware_architecture.md) §1, [report_engine_architecture.md](report_engine_architecture.md) §1, §4 |
| `02-Checks/port_check.sh`, `02-Checks/weblogic_performance.sh` | [weblogic_middleware_architecture.md](weblogic_middleware_architecture.md) §4, §6 |
| `02-Checks/db_connect_check.sh`, `07-Maintenance/rcu_repository_check.sh` | [rcu_middleware_architecture.md](rcu_middleware_architecture.md) §3, §6.1 |
| `02-Checks/ssl_check.sh`, `08-SSL/ssl_local_ca.sh` | [forms_jakob_webutil.md](forms_jakob_webutil.md) §9, §10 |
| `02-Checks/reports_network_scan.sh` | [reports_server_discovery_multicast.md](reports_server_discovery_multicast.md), [report_engine_architecture.md](report_engine_architecture.md) §8 |
| `01-Run/rwserver_status.sh`, `05-ReportsPerformance/engine_perf_settings.sh`, `05-ReportsPerformance/engine_perf_analyse.sh` (shared `01-Run/reports_server_lib.sh`) | [report_engine_architecture.md](report_engine_architecture.md) §5, §6 |
| `01-Run/rwrun_trace.sh` | [report_engine_architecture.md](report_engine_architecture.md) §5.1 |
| `02-Checks/egress_check.sh`, `09-Install/04-oracle_pre_checks.sh` (check 10) | [weblogic_outbound_connections.md](weblogic_outbound_connections.md) |
| `06-FormsDiag/forms_settings.sh`, `forms_perf_settings.sh`, `forms_perf_analyse.sh` (shared `06-FormsDiag/forms_lib.sh`), `09-Install/14-` prestart | [forms_runtime_architecture.md](forms_runtime_architecture.md) |

Overview of the checks: [02-Checks/README.md](../02-Checks/README.md).

## Candidates for further documents

Findings already collected elsewhere that belong here as a whole:

- Node Manager credentials – two stores (`config.xml` encrypted vs.
  `nm_password.properties` hash), random credentials of WLST-offline domains
  (today in `09-Install/docs/80-oracle_security.md` §5)
- rwservlet web commands – `webcommandaccess`, `<identifier>`,
  `checkDiagnostic` (today in `09-Install/docs/81-reports_rwservlet_security.md`)
- Which configuration file is effective (domain `config/fmwconfig/…` vs. the
  staged `servers/<ms>/tmp/_WL_user/…` copy vs. `$ORACLE_HOME/…/conf` templates)
- WLST credential resolution (`connect()` without arguments → default
  `~/<user>-WebLogicConfig.properties`, `boot.properties` of the target server)
