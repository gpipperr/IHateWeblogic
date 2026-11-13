---
title: "Oracle Forms, Reports & WebLogic 14c Architecture – How It Works Internally"
description: "How Oracle Forms, Reports and WebLogic 14.1.2 work internally: Oracle/Domain Home, Node Manager, RCU schemas, Reports engines, fonts, certificates – verified."
permalink: /80-FMW-Architecture/
---

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
| [weblogic_middleware_architecture.md](weblogic_middleware_architecture.md) | **Start here – base overview:** Oracle Home vs. Domain Home vs. Node Manager home, what a patch changes and what it does not reach, swapping a patched home (§7a), AdminServer / managed servers / clusters / Node Manager / system components (Forms, Reports) and how they are joined (t3, NM protocol, CORBA, OPSS DB, NGINX), who starts whom (systemd → `fmw_ctl.sh` → NM), who provides EM and the Remote Console, table of software / configuration / log locations per component, evolution 10g → 11g → 12c → 14c, Oracle sources incl. the older guides |
| [rcu_middleware_architecture.md](rcu_middleware_architecture.md) | RCU and the FMW repository: schemas and who uses them (ASCII), schema version registry `SYSTEM.SCHEMA_VERSION_REGISTRY$` (also: missing registry → RCU cannot drop), **§4.4 clean-up of old prefixes** (find, prove unused, shared objects that stay, backup, drop with RCU GUI / silent / SQL, verify – queries live-tested), service table `_STB` with encrypted passwords, where the schema passwords live, password expiry of profile `DEFAULT` → own profile `RCU_USER`, patching vs. upgrade (OPatch vs. Upgrade Assistant, no PSA since 12c) – theory for phase 8; §9 database requirements 19c / 26ai (version, AL32UTF8, JVM, parameter minimums vs. our DB, edition EE / SE2 ORA-00439, licence: separately licensed DB + audit wording EN/DE) |
| [reports_engine_architecture.md](reports_engine_architecture.md) | Reports server and engines: in-process (Oracle default, inside WLS_REPORTS, WebLogic realm) vs. standalone server (own JVM, Node Manager, `jps-config-jse.xml`), the two `rwserver.conf` files, who starts the engines, why the WebLogic console shows only WLS_REPORTS, performance parameters with Oracle's sizing formulas, history 6i → 14c (CGI, VisiBroker/OPMN → JDK ORB/Node Manager), broadcast discovery – idea and why it disturbs on one host, clustering hint, Oracle sources |
| [reports_server_discovery_multicast.md](reports_server_discovery_multicast.md) | How Reports servers, the rwservlet and the Reports tools find each other (UDP multicast, `rwnetwork.conf`), why a server stops with `REP-50600`/`REP-56040`, active search of the network with `rwdiag`/`DiagServerLocator`, hardening ideas, prerequisites and diagnosis |
| [reports_fonts_architecture.md](reports_fonts_architecture.md) | **Reports fonts:** how a font name becomes a file (`uifont.ali`, screen printer, `[PDF:Subset]`, `REPORTS_FONT_DIRECTORY`), original vs. substitute, **licences** (Windows fonts may not be copied to another server – Microsoft FAQ; Office fonts; free OFL replacements Liberation / Carlito / Caladea / DejaVu; customer fonts), metric compatibility "identical" vs. "similar", Builder vs. server vs. browser, migration path with the font classes of the export tool, open points (Carlito / Caladea not set up) |
| [reports_server_image_handling.md](reports_server_image_handling.md) | Images in migrated reports: embedded vs. Link File vs. *Read from File*, `REPORTS_PATH` search, no fallback for Windows paths (`REP-108`), `<folderAccess>` – one `<read>`, `;`-separated, last element wins, no subdirectories (`REP-56132`, test series), migration with `rwconverter` |
| [reports_user_local_ldap.md](reports_user_local_ldap.md) | Who authenticates whom: standalone Reports server (Java SE, `jps-config-jse.xml`) vs. WebLogic realm; identity store switched to the embedded LDAP so `monUser`/`RW_MONITOR` and `RepRunner`/`RW_EXECREPORTS` work with `securityId`; slow first request explained (process reaper / ADR wait, stale CORBA IOR + 60 s ORB connect timeout) and fixed – test run with findings |
| [reports_job_handling.md](reports_job_handling.md) | **Scheduled reports and job queues:** sources (14.1.2 library → 12.2.1.3 Reports books), job model future/current/past with parent/child jobs and `repserver01.dat` persistence (survives restart, revived by restore/clone), `SCHEDULE=` syntax, cron + `rwclient.sh cmdfile=` (recommended, rc=1 on error) vs. `SCHEDULE=` via rwservlet POST, `showjobs`/`killjobid` rights, `<write>` without subdirectories (`REP-56133`) – all live-tested |
| [reports_mail_handling.md](reports_mail_handling.md) | **Reports mail:** mail server in `rwserver.conf` (`host:port`, `enableSSL`, STARTTLS only with login), which `rwserver.conf` / note files / `rwbuilder.conf`, sender (`from=`, notification `sender`), demo calls (`destype=mail`, `notifysuccess` / `notifyfailure`), **failure mail to a ticket system** via `notifyfailure` in `cgicmd.dat` keys (live 2026-11-11: key wins over the request, `retry="3"` = 4 mails, rejected requests send none), debugging with a local SMTP sink |
| [reports_rwservlet_properties.md](reports_rwservlet_properties.md) | **`rwservlet.properties` in 14.1.2:** location, read at WLS_REPORTS start, all 19 elements of `rwservlet.xsd` with default / meaning / DEV-PROD recommendation / library value (`trace` commented out), what `13-` writes (whole file – hand-set elements get lost on a re-run), **`reloadkeymap`** (live: `cgicmd.dat` changes without restart), `cgicmd.dat` short, **job retry** (`<job retry>` in `rwserver.conf` + `JOBRETRY`, live: key wins, Reports server restart needed, normal REP errors retried too) with a "retry does not take" checklist |
| [reports_monitoring_getserverinfo.md](reports_monitoring_getserverinfo.md) | **Monitoring the Reports server:** `getserverinfo` as the only source of engine / queue / job state, request as POST (a GET `authid` lands in plain text in `WLS_REPORTS/logs/access.log` – live finding), real XML with field reference and units, cumulative counters → deltas, alarm table, checks around it (AdminServer LDAP, logs, end-to-end report), live-tested Nagios/Icinga/Checkmk plugin, Zabbix XPath items, PRTG |
| [em_principal_search_libovd.md](em_principal_search_libovd.md) | EM "Add Principal" finds no users: the EM search goes through libOVD; the Reports server rewrites the shared libOVD config and leaves `ovd.lok`, an AdminServer started with it has no LDAP adapter – trace, test series, fix in the start scripts |
| [weblogic_outbound_connections.md](weblogic_outbound_connections.md) | What a Forms/Reports domain sends to other hosts (nothing to the internet – confirmed by capture), the **external-DTD trap** (JAXP downloads `java.sun.com` DTDs; refused = 55 ms, dropped = 130 s, silent firewall = hangs forever), mitigations (`accessExternalDTD`, `sun.net.client` timeouts, `/etc/hosts`), how to measure (tcpdump, ss, jstack, root-free reproducer) |
| [certificates_trust_stores.md](certificates_trust_stores.md) | **Certificates, keys and trust stores – central description:** terms (TLS/SSL, chain, PEM / DER / PKCS#7 / #8 / #12, JKS, Oracle wallet, KSS, Windows store), quality of a CA certificate (SHA-1/MD5 signatures rejected, key size, container encryption, checklist), three directions of trust, inventory of every store of the stack with owner / permissions / writer / reader (live), Oracle JDK vs. OS root lists differ, who needs what, customer PKI + TLS interception, options to centralise the Java trust stores (symlink to the OS store recommended), concept for a trust-anchor directory + check/sync script, link list of every script / doc that touches a store |
| [reports_rwbuilder.md](reports_rwbuilder.md) | **Reports Builder minimal setup** on a central Windows Server (RDP): why there is no "standalone Reports Builder", why a domain + RCU are unavoidable but the running server stack is not (templates JRF + EM + Reports Tools only, AdminServer once for `createReportsToolsInstance`, daily only `rwbuilder.bat`), Windows specifics (installer breaks ACL inheritance → developers need local admin, 2 RDP admin sessions), keeping Builder and Linux server consistent, alternatives – links the German customer cookbook; confirmed live 2026-10-27 |
| [fmw_pwd_handling.md](fmw_pwd_handling.md) | **Password handling in the domain:** the domain key `SerializedSystemIni.dat` next to every `{AES256}` value (= obfuscation, the host is the boundary), `boot.properties` and the **Node Manager's own copy** in `data/nodemanager/` (written when the AdminServer starts a server, stale after a password change, rebuilt differently by `start()` vs. `nmStart`), all other stores (JDBC, OPSS wallets, Reports `<identifier>`, clear-text `cgicmd.dat` `authid`), permissions found live, security rules, test plan |
| [forms_performance_analyse_tuning.md](forms_performance_analyse_tuning.md) | "Forms is slow" – method: the chain client → Nginx → `lservlet` → `frmweb` → DB, what to measure per layer (Nginx `rt` / `urt`, WebLogic `time-taken`, `frmweb`), symptom → cause → setting, what does not help, DB side as open point |
| [forms_runtime_architecture.md](forms_runtime_architecture.md) | How a Forms session runs: frmservlet / lservlet / one `frmweb` per session (child of WLS_FORMS, outside the heap), config sections and inheritance from `[default]`, **runtime pooling** (prestart in `[default]` = 50 idle processes, Oracle advice), timeout chain `heartBeat` < `FORMS_TIMEOUT` / `session-timeout`, shared FMX memory, `maxRuntimeProcesses`, logs / ODL levels / dumps |
| [apex_architecture.md](apex_architecture.md) | Oracle APEX beside Forms: the parts of a request, APEX 26.2 database accounts (`APEX_LISTENER` gone, `APEX_PUBLIC_USER` without authentication, `APEX_PUBLIC_ROUTER`), **from `f?p=` to SQL** (`SYS.WWV_DBMS_SQL_<schema>` → `DBMS_SYS_SQL.parse_as_user`), APEX objects in SYS, removal only with the script of the same release, why APEX does not move with a Data Pump schema export (`KU_NOEXP_TAB`) |
| [ords_architecture.md](ords_architecture.md) | ORDS in depth: `ords.war` = executable WAR with Jetty 12, ojdbc / UCP and the **APEXlang compiler** (ORDS ≥ APEX), request pipeline (live `v$sql`), two configuration levels (files vs. `ORDS_METADATA`, 54 of 56 FKs `ON DELETE CASCADE`), `config set` accepts unknown keys (`standalone.binds`!), proxy right, features with risk (SDW, REST-enabled SQL, DB API, GraphQL on by default), REST / OAuth2 with `ORDS_SECURITY`, REST inside an APEX session |
| [clone_golden_image.md](clone_golden_image.md) | Clone-capable installation / golden image: which socket binds where (WebLogic, Node Manager, SSL ports, Reports ORB via `ORBServerHost`, Coherence, `frmweb`, multicast), what holds the host name / IP / machine identity (JDBC, OPSS, `*.des3` = disk UUID, Nginx certificate), what changes after a clone, recipe; check [`02-Checks/clone_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/clone_check.sh) |
| [java_jlink_forms_env.md](java_jlink_forms_env.md) | Own Java runtime for the Forms client: module system, JMOD files, `jlink` / `jdeps` (and why `jdeps` misses service providers), module list for Forms 14.1.2, **cross-build of a Windows runtime on Linux** (61 MB), CA inside the runtime's `cacerts`, first real FSAL session against the test host with a Linux `jlink` runtime (2026-10-22), JEP 493 outlook |
| [forms_jakob_webutil.md](forms_jakob_webutil.md) | WebUtil and JACOB (Java–COM bridge for OLE/Office automation): architecture, download source and checksums of JACOB 1.21, files and locations, `webutil.cfg` syslib list, signing, state of the test host; **signing** (how Oracle intends it, `extensions.jnlp` = own signer, code-signing / TLS certificates, who checks: Java Web Start vs. FSAL), maintenance after patches, client distribution concept (login script, software distribution, GPO) |

## Where the scripts point here

The script READMEs describe **what** a script checks and link to these
documents for the **why**:

| Script(s) | Background |
|---|---|
| [`02-Checks/java_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/java_check.sh), [`10-Monitoring/cve_inventory.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/10-Monitoring/cve_inventory.sh) (two JDKs – WebLogic on `JDK_HOME`, Reports engines on `oracle_common/jdk`) | [weblogic_middleware_architecture.md](weblogic_middleware_architecture.md) §1, [reports_engine_architecture.md](reports_engine_architecture.md) §1, §4 |
| [`02-Checks/port_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/port_check.sh), [`02-Checks/weblogic_performance.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/weblogic_performance.sh) | [weblogic_middleware_architecture.md](weblogic_middleware_architecture.md) §4, §6 |
| [`02-Checks/db_connect_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/db_connect_check.sh), [`07-Maintenance/rcu_repository_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/rcu_repository_check.sh) | [rcu_middleware_architecture.md](rcu_middleware_architecture.md) §3, §6.1 |
| [`02-Checks/ssl_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/ssl_check.sh), [`08-SSL/ssl_local_ca.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/08-SSL/ssl_local_ca.sh) | [forms_jakob_webutil.md](forms_jakob_webutil.md) §9, §10 |
| [`02-Checks/reports_network_scan.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/reports_network_scan.sh) | [reports_server_discovery_multicast.md](reports_server_discovery_multicast.md), [reports_engine_architecture.md](reports_engine_architecture.md) §8 |
| [`01-Run/rwserver_status.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/01-Run/rwserver_status.sh), [`05-ReportsPerformance/engine_perf_settings.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/05-ReportsPerformance/engine_perf_settings.sh), [`05-ReportsPerformance/engine_perf_analyse.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/05-ReportsPerformance/engine_perf_analyse.sh) (shared [`01-Run/reports_server_lib.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/01-Run/reports_server_lib.sh)) | [reports_engine_architecture.md](reports_engine_architecture.md) §5, §6 |
| [`01-Run/rwrun_trace.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/01-Run/rwrun_trace.sh) | [reports_engine_architecture.md](reports_engine_architecture.md) §5.1 |
| [`02-Checks/egress_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/egress_check.sh), [`09-Install/04-oracle_pre_checks.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/04-oracle_pre_checks.sh) (check 10) | [weblogic_outbound_connections.md](weblogic_outbound_connections.md) |
| [`06-FormsDiag/forms_settings.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/06-FormsDiag/forms_settings.sh), [`forms_perf_settings.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/06-FormsDiag/forms_perf_settings.sh), [`forms_perf_analyse.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/06-FormsDiag/forms_perf_analyse.sh) (shared [`06-FormsDiag/forms_lib.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/06-FormsDiag/forms_lib.sh)), `09-Install/14-` prestart | [forms_runtime_architecture.md](forms_runtime_architecture.md) |
| [`02-Checks/tns_admin_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/tns_admin_check.sh) (one `TNS_ADMIN`) | [forms_runtime_architecture.md](forms_runtime_architecture.md) §2.1, [reports_engine_architecture.md](reports_engine_architecture.md) §5.2 |
| [`02-Checks/clone_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/clone_check.sh), `09-Install/08-` loopback block, `13-` `ORBServerHost` | [clone_golden_image.md](clone_golden_image.md) |
| [`02-Checks/ssl_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/ssl_check.sh), `08-SSL/`, [`10-Monitoring/cert_expiry_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/10-Monitoring/cert_expiry_check.sh), `40-` client `cacerts` | [certificates_trust_stores.md](certificates_trust_stores.md) |
| [`01-Run/startStop.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/01-Run/startStop.sh) / `fmw_ctl.sh` (`ovd.lok` removal), `09-Install/12-` | [em_principal_search_libovd.md](em_principal_search_libovd.md), [reports_user_local_ldap.md](reports_user_local_ldap.md) |
| `09-Install/13-` `REPORTS_SECURITY`, `<folderAccess>` / `REPORTS_PATH` | [reports_user_local_ldap.md](reports_user_local_ldap.md), [reports_server_image_handling.md](reports_server_image_handling.md) |
| [`09-Install/40-oracle_forms_client_bundle.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/40-oracle_forms_client_bundle.sh), `client_templates/` | [java_jlink_forms_env.md](java_jlink_forms_env.md), [forms_jakob_webutil.md](forms_jakob_webutil.md) |
| `09-Install/14-` JACOB / signing, `08-SSL/ssl_local_ca.sh codesign` | [forms_jakob_webutil.md](forms_jakob_webutil.md) |
| `12-APEX-Ords/01-` … `06-`, `03-Logs` group `ords` | [apex_architecture.md](apex_architecture.md), [ords_architecture.md](ords_architecture.md) |
| `09-Install/07-oracle_setup_repository.sh --check`, `60-RCU-DB-19c/` | [rcu_middleware_architecture.md](rcu_middleware_architecture.md) §9 |
| `14-ReportsBuilder/` | [reports_rwbuilder.md](reports_rwbuilder.md) |

The installation steps link here per step: [09-Install/README.md §1](../09-Install/README.md#1-architecture--security-concept)
and every `09-Install/docs/*.md` (reviewed 2026-10-29).

Overview of the checks: [02-Checks/README.md](../02-Checks/README.md).

## Candidates for further documents

Findings already collected elsewhere that belong here as a whole:

- Node Manager credentials – two stores (`config.xml` encrypted vs.
  `nm_password.properties` hash), random credentials of WLST-offline domains
  (today in [`09-Install/docs/80-oracle_security.md`](../09-Install/docs/80-oracle_security.md) §5)
- rwservlet web commands – `webcommandaccess`, `<identifier>`,
  `checkDiagnostic` (today in [`09-Install/docs/81-reports_rwservlet_security.md`](../09-Install/docs/81-reports_rwservlet_security.md),
  design and tests done 2026-10-23)
- Which configuration file is effective (domain `config/fmwconfig/…` vs. the
  staged `servers/<ms>/tmp/_WL_user/…` copy vs. `$ORACLE_HOME/…/conf` templates)
- WLST credential resolution (`connect()` without arguments → default
  `~/<user>-WebLogicConfig.properties`, `boot.properties` of the target server)
