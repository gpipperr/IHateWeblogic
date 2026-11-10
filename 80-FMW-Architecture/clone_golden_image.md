# Clone-Capable Installation – Loopback Only, One Host Name at the Edge

> Certificates, keys and trust stores of the whole stack (terms, where what lives, who needs what, customer PKI / TLS interception): [certificates_trust_stores.md](certificates_trust_stores.md)

What a Forms / Reports 14.1.2 host binds to, which files hold its host
name, IP or machine identity, and what has to change after the machine is
cloned. Goal: everything internal runs over `127.0.0.1`, only Nginx (and the
certificate) carries the host name – then an installation can serve as a
**golden image** and is easy to move.

Markers: **confirmed (live)** (test host, date given), **documented**
(source in section 8), **assumption** (not proven yet).

Related:
[weblogic_middleware_architecture.md](weblogic_middleware_architecture.md)
(processes and who starts whom),
[forms_runtime_architecture.md](forms_runtime_architecture.md) (`frmweb`
sockets),
[report_engine_architecture.md](report_engine_architecture.md) (server /
engine CORBA),
[reports_server_discovery_multicast.md](reports_server_discovery_multicast.md)
(multicast discovery). Check script: `02-Checks/clone_check.sh` (customer
hosts: tools `clone_check_fmw.sh`).

Practice (anonymised, from a customer project 2026-11-09/10):
[../70-Customer-Projects/FormsReports14_linux_localhost/](../70-Customer-Projects/FormsReports14_linux_localhost/README.md)
(harden an existing domain to localhost – technical README + cookbook) and
[../70-Customer-Projects/FormsReports14_linux_clone/](../70-Customer-Projects/FormsReports14_linux_clone/README.md)
(clone with a new RCU prefix, way 3 – technical README + cookbook).

---

## 1. Target picture

```
  client (browser / FSAL)
        |  HTTPS, host name + certificate  <-- the ONLY host-specific edge
        v
  +---------------- Nginx (0.0.0.0:443) ------------------------------+
  |        proxy_pass http://127.0.0.1:<port>                         |
  +-------------------------------------------------------------------+
        |                     |                       |
        v                     v                       v
  AdminServer 127.0.0.1:7001  WLS_FORMS 127.0.0.1:9001  WLS_REPORTS 127.0.0.1:9002
  Node Manager 127.0.0.1:5556     |                       | rwservlet
                                  | TCP                   | CORBA (IOR host 127.0.0.1)
                                  v                       v
                          frmweb (0.0.0.0:<eph>)  rwserver 127.0.0.1:<eph>
                                                    engines 127.0.0.1:<eph>
        DB: same host -> localhost / alias, other host -> its name
```

---

## 2. Sockets and their bind address (test host, 2026-10-23)

| Process | Socket | Bind before | Bind after | How | Marker |
|---|---|---|---|---|---|
| AdminServer, WLS_FORMS, WLS_REPORTS | 7001 / 9001 / 9002 | `localhost` | – | `ListenAddress` in `09-Install/08-` | confirmed (live) |
| Node Manager | 5556 | `127.0.0.1` | – | `nodemanager.properties` (`08-`, `11-`) | confirmed (live) |
| Managed server → AdminServer on a **direct Node Manager start** (autostart, `nmStart` without AdminServer) | `servers/<ms>/data/nodemanager/startup.properties` `AdminURL` | address of the **last start via the AdminServer** (host name / IP before the hardening) | **`http\://localhost\:<port>`** | edit the file (or start the server once via EM / console – the AdminServer then hands over its own URL; assumption) and restart the managed server. The hardening (`ListenAddress localhost`) does **not** rewrite it: the server runs, but in *Managed Server independence mode*, the AdminServer logs only `BEA-149505 … JMX Service URL of <none>`, EM shows server, cluster and `reports` deployment **shut down** | confirmed (customer, 2026-11-10: `AdminURL=http\://<host IP>\:7001` on the source and the clone, `status.sh` all RUNNING, EM red) |
| WLS_FORMS / WLS_REPORTS SSL | 9501 / 9512, **demo certificate** | `localhost` | **off** | `/Servers/<ms>/SSL/<ms>` `Enabled=false` | confirmed (live) |
| Reports server `rwserver` | CORBA, ephemeral | `0.0.0.0` | **`127.0.0.1`** | `-Dcom.sun.corba.ee.ORBServerHost=127.0.0.1` in `REPORTS_JVM_OPTIONS` (`reports.sh`) | confirmed (live) |
| Reports engines (`rwEng-*`) | CORBA, ephemeral | `0.0.0.0` | **`127.0.0.1`** | the engines inherit `REPORTS_JVM_OPTIONS` of the server – no own setting needed **as long as `<engine>` has no `jvmOptions`** (next row) | confirmed (live) |
| Reports engines (`rwEng-*`) with **`jvmOptions`** on `<engine>` in `rwserver.conf` | CORBA, ephemeral | `0.0.0.0` | **`127.0.0.1`** | `jvmOptions` **replace** the inherited `REPORTS_JVM_OPTIONS` – add `-DORBWaitForResponseTimeout=999999999 -Dcom.sun.corba.ee.ORBServerHost=127.0.0.1` there (the timeout as in `reports.sh`; `13-` / `engine_perf_settings.sh` do it since 2026-11-10); `clone_check.sh` FIX | confirmed (customer, 2026-11-10: `jvmOptions="-Xms1024m -Xmx2048m"`, engines on `0.0.0.0` after a restart, server on loopback) |
| Reports discovery | UDP multicast `228.5.6.7:<REPORTS_BROADCAST_PORT>` | `0.0.0.0` | unchanged | multicast needs an interface; see section 4 | confirmed (live) |
| Coherence member traffic (cluster_forms / cluster_reports) | unicast | host IP | **`127.0.0.1`** | `/Servers/<ms>/CoherenceMemberConfig/<ms>` `UnicastListenAddress=127.0.0.1` | confirmed (live) |
| Coherence extra listeners | cluster port 7574 (tcp+udp) + one ephemeral tcp | host IP | **unchanged** | not removable with `UnicastListenAddress` nor `-Dcoherence.localhost=127.0.0.1` | confirmed (live) |
| `frmweb` (one per session / pooled) | ephemeral tcp, IPv4 + IPv6 | `0.0.0.0` / `[::]` | **unchanged** | no option found | documented (none) |

Notes:

- **ORB.** The Reports server and engines use the GlassFish ORB
  (`oracle_common/modules/glassfish-corba-orb-4.2.5.jar`, property names
  `com.sun.corba.ee.*`). `ORBServerHost` sets the host written into the IOR
  **and** the bind address: after the change `ss -ltnp` shows the server
  and both engines on `127.0.0.1`; `rwservlet` (WLS_REPORTS on the same
  host) still finds and calls the server, the smoke test produces the PDF
  (**confirmed (live)** 2026-10-23). A second Reports server or `rwclient`
  on **another** host could not call this server any more – intended here.
- **Coherence.** WebLogic generates a well-known-address list from the
  servers' listen addresses (`BEA-2194505` warns about `localhost`). With
  `UnicastListenAddress=127.0.0.1` Coherence logs `Local address
  "127.0.0.1" is a loopback address; this cluster node will not connect to
  nodes located on different machines` and the members talk over loopback
  (`ss -tanp`: ESTAB 127.0.0.1) – a clone in the same subnet cannot join.
  The cluster port 7574 and one more port still listen on the host IP as
  well (**confirmed (live)**); why (bind to the address of the host name?)
  is an **assumption**. The firewall closes them. Do not configure an own
  WKA list: "Use of the Well Known Addresses (WKA) feature requires a
  Coherence Enterprise License" (**documented**, Coherence 3.1 User Guide –
  an old release; check the current licensing before configuring WKA).
  Alternative not taken: detach Coherence from the two clusters.
- **frmweb.** Called only as `frmweb webfile=HTTP-0,<section>`; the binary
  has no `FORMS_*` variable for a host / bind address (strings of `frmweb`
  and its libraries: only `FORMS_AQ_PORT_RANGE`,
  `FORMS_JAVA_NET_PREFERIPV4STACK`, …); the 14.1.2 documentation of the
  environment variables and of "Forms Services in Action" names none
  (**documented**: not configurable). The socket holds no host name –
  **clone-neutral**, only a security point, closed by the firewall.
- **SSL off.** After `Enabled=false` and a restart Forms (frmservlet 200),
  EM (302 to login), rwservlet and the smoke test work unchanged; the demo
  certificate `DemoIdentity` is still loaded at start (`BEA-090171`) but no
  port uses it (**confirmed (live)** 2026-10-23).

### 2.1 Hardening checklist – an existing domain to localhost

Every point is needed; the last four were found only after a first
hardening at a customer (2026-11-10) – the domain ran, but EM showed the
Reports server red and the engines still listened on all interfaces.

| # | What | Where | Check |
|---|---|---|---|
| 1 | listen address `localhost` | `config.xml` AdminServer, WLS_FORMS, WLS_REPORTS; Node Manager `nodemanager.properties` | `ss -ltn` – 7001 / 9001 / 9002 / 5556 on 127.0.0.1 |
| 2 | SSL listen ports off, Coherence unicast 127.0.0.1 | `/Servers/<ms>/SSL`, `/Servers/<ms>/CoherenceMemberConfig` | `clone_check.sh` section 2 |
| 3 | Reports server ORB | `reports.sh` `REPORTS_JVM_OPTIONS` with `-DORBWaitForResponseTimeout=999999999 -Dcom.sun.corba.ee.ORBServerHost=127.0.0.1` (without the timeout: REP-50125) | section 3 |
| 4 | rwservlet ORB | `setUserOverrides.sh`, block for WLS_REPORTS | section 3 |
| 5 | engine ORB when `<engine>` has `jvmOptions` | `rwserver.conf` – the same two options in `jvmOptions` (they replace the inherited ones) | section 1: no `rwEng-*` on 0.0.0.0 |
| 6 | managed server → AdminServer on a Node Manager start | `servers/<ms>/data/nodemanager/startup.properties` `AdminURL=http\://localhost\:<port>` | AdminServer log `BEA-149506` for every managed server; EM green |
| 7 | domain scripts | `bin/*.sh` `ADMIN_URL=t3://localhost:<port>` | section 4 |
| 8 | EM | `emoms.properties` + `.jmxori` **and** the source copy `servers/AdminServer/tmp/_WL_user/em/*/META-INF/emoms.properties` | section 4; value survives an AdminServer restart |
| 9 | edge | Nginx `proxy_pass http://127.0.0.1:<port>`; nobody calls 7001 / 9002 directly (check the access logs first); firewall | `curl` via Nginx, smoke test |

Gate: `clone_check.sh` "Clone-capable: yes" (only STEP / INFO items left).
Details, symptoms and the manual cookbook:
[FormsReports14_linux_localhost](../70-Customer-Projects/FormsReports14_linux_localhost/README.md).
New installations: the domain is created with `localhost` (`09-Install/08-`,
`11-`), so points 1 and 6–8 hold from the start; points 3–5 come from `13-`
(engine `jvmOptions` since 2026-11-10). On an **existing** domain
`clone_check.sh --apply` sets point 2 (WLST online) and points 5–8 (files,
backup of each, since 2026-11-10).

---

## 3. Where the host name, IP and machine identity live

| Place | Content | After a clone | Marker |
|---|---|---|---|
| Nginx `server_name`, TLS certificate CN / SAN | host name | **new certificate**, `09-Install/04-root_nginx.sh` / `05-root_nginx_ssl.sh` | – |
| `environment.conf` `WLS_SERVER_FQDN`, `FORMS_CLIENT_BASE_URL` | host name / URL | set, then `09-Install/40- --apply` (client manifest) | – |
| `$DOMAIN_HOME/config/jdbc/*-jdbc.xml`, `fmwconfig/jps-config*.xml` | DB host **and prefix** of the RCU repository | DB on the same host: cloned along, only the host name (better `localhost` from the start); **external DB: own prefix per clone – section 5** | confirmed (live) |
| `tnsnames.ora` in `TNS_ADMIN` | DB host | same as above | – |
| **`$DOMAIN_HOME/bin/stopWebLogic.sh`** (and possibly `startManagedWebLogic.sh`) `ADMIN_URL="t3://<host>:7001"`; also an `ADMIN_URL` exported in the oracle profile | AdminServer address of the domain creation – the Configuration Wizard writes the listen address / host name of that time (test host: `localhost`) | **change to `t3://localhost:<port>` before the first start / stop on the clone.** Otherwise `stopWebLogic.sh` on the clone connects to the **source** AdminServer and, with `boot.properties` and an open network, **stops the source**. Until then: `ADMIN_URL=t3://localhost:7001 $DOMAIN_HOME/bin/stopWebLogic.sh` (the script takes a set `ADMIN_URL` and uses its own value only when it is empty). `02-Checks/clone_check.sh` reports own host names in `bin/*.sh` and a foreign `ADMIN_URL` (scripts and shell) as FIX | confirmed (customer, 2026-11-10: clone `stopWebLogic.sh` → `t3://<source>:7001`, only "No route to host" prevented the stop; script code read on the test host) |
| **`$DOMAIN_HOME/servers/<ms>/data/nodemanager/startup.properties`** `AdminURL=http\://<host>\:7001` | AdminServer address the Node Manager passes on a direct start | **`http\://localhost\:<port>`** before the first start on the clone – a host name / IP of the source makes the clone's managed server look for the **source** AdminServer (or, network closed, run in independence mode: EM red). Same on a hardened source (section 2). `clone_check.sh` reports it as FIX (2026-11-10.3) | confirmed (customer, 2026-11-10) |
| `*.des3` secret files | encrypted with the **disk UUID** (`_get_system_identifier`) | **unreadable** on the clone – re-enter (table "Password Security Concept" in the root README) | confirmed (code, lib) |
| Reports `rwnetwork.conf` multicast port + server name | `REPORTS_BROADCAST_PORT`, `repserver01` | clones in one subnet: **change the port** (14021–14030), `13- --apply` | documented (Doc ID 437228.1) |
| `init-info/tokenValue.properties` `@HOST_NAME` | host name of the domain creation | informational, not read at runtime | assumption |
| `uifont.ali` header comment | host name of the generation | comment only | confirmed (live) |
| `/etc/machine-id`, ssh host keys, `/etc/hosts` | machine identity | OS clone tooling (`virt-sysprep` / cloud-init) | – |
| `oraInventory`, Oracle Home | paths only | unchanged | – |
| `$DOMAIN_HOME/config/fmwconfig/servers/AdminServer/applications/em/META-INF/emoms.properties` (+ `.jmxori`) `ConsoleServerHost` / `ConsoleServerName` – **source: `servers/AdminServer/tmp/_WL_user/em/<id>/META-INF/emoms.properties`** | host name (or `localhost`) of the domain creation | EM **copies the `tmp/` file over both `config/` files at every AdminServer start** – editing only `config/` is undone (customer, 2026-11-10: both edited to `localhost`, after the restart both back to the FQDN, same size and timestamp as the start, `tmp/` copy dated at the creation; all three changed → `localhost` survives the restart, `clone_check` "Clone-capable: yes"). Change all three; check again after an EM patch / redeploy (re-extracts `tmp/`). EM works with the FQDN there (customer) – not a socket, but on a clone the source name. `clone_check.sh` reports the `tmp/` copy (2026-11-10.8). Test host: `localhost` everywhere (domain created with it) | confirmed (customer) |
| `rwserver.conf` `<notification>` `sender` | mail address with the host name (if set) | adjust per clone ([reports_job_handling.md](reports_job_handling.md) §7.2) | – |
| tools directory `patch_install.ini` (`70-Customer-Projects/tools`, customer hosts) | `WLS_SERVER_FQDN`, `SSL_CN`, `DB_HOST/PORT/SERVICE`, `DB_SCHEMA_PREFIX`, `REPORTS_BROADCAST_PORT` of the source | regenerate on the clone after the domain change: move the old file aside, `make_patch_install_ini.sh` (shows) / `--apply` (writes, never overwrites), carry over hand-made entries from a `diff`; `status.sh` warns when the ini names another domain | confirmed (code) |
| `crontab` of oracle / root, `/etc/cron.d` | cron jobs of the source (`rwclient` runs, exports, cleanup) | check and comment out on the clone – else they run twice or against the source | – |
| `$DOMAIN_HOME/reports/server/<server>.dat` | scheduled Reports jobs | move aside before the first start of a clone, else they run twice ([reports_job_handling.md](reports_job_handling.md) §8); never copy it back; check with `showjobs queuetype=future` (clone: 0, source: its jobs). Jobs for the clone: plan new (cron + `rwclient`, own targets for `desname` / FTP / mail) | confirmed (live, persistence) |

---

## 4. Reports discovery and clones

Multicast stays (Oracle default, works on one host). Two clones in the
same subnet with the same broadcast port and the same Reports server name
see each other: the second server stops with `REP-56040` / the servlet
picks the wrong one ([reports_server_discovery_multicast.md](reports_server_discovery_multicast.md)).
After cloning, change `REPORTS_BROADCAST_PORT` in `environment.conf` and
run `09-Install/13-oracle_setup_reports.sh --apply`; the firewall rule
(`<port>/udp`) moves along.

---

## 5. The RCU repository – where it lives decides

The domain is bound to **one repository prefix** (`<prefix>_OPSS`, `_STB`,
`_IAU*`, `_WLS*`, `_MDS` …,
[rcu_middleware_architecture.md](rcu_middleware_architecture.md) §2): the
JDBC data sources and the OPSS bootstrap in `jps-config*.xml` point to it,
OPSS keeps policies, credentials and keys **in the database**, the service
table `<prefix>_STB` names the schemas, `SYSTEM.SCHEMA_VERSION_REGISTRY$`
knows the prefix (§4, §5 there).

```
  RCU DB on the WLS host (this repository: 60-RCU-DB-19c)
  +----------------- machine -----------------+
  | domain  --JDBC-->  DB (prefix DEV)         |   clone = domain + DB together
  +--------------------------------------------+   -> nothing to do for RCU

  RCU DB external
  +---- machine A ----+          +------ DB host ------+
  | domain (DEV)  ----+--JDBC--> | prefix DEV          |
  +-------------------+     +--> |                     |   clone B on DEV = two domains
  +---- machine B ----+     |    |                     |   in ONE OPSS store - forbidden
  | domain (DEV)  ----+-----+    | prefix DEV2 (new)   |   -> B needs its own prefix
  +-------------------+          +---------------------+
```

| RCU database | After the clone |
|---|---|
| **on the WLS host** (cloned along) | nothing for RCU – the DB is part of the image. Only the DB host name in the JDBC URLs / `jps-config*.xml` / `tnsnames.ora` (section 3): use `localhost` or an alias from the start, then nothing changes either |
| **external** | the clone must **not start** against the repository of the source – two domains would write into the same OPSS store (policies, keystores, credentials), the same `_WLS` runtime / lease tables and the same service table (**assumption** from the design, not tested – do not try it on a production repository). Exception in way 3: only the AdminServer of the clone starts briefly against it to run `reassociateSecurityStore` (reads the source store) |

External RCU – three ways, the first one recommended:

1. **Image without domain (recommended).** The golden image holds the OS
   baseline, the Oracle Homes (patched), the JDK and this repository with a
   prepared `environment.conf` – but **no domain**. Per clone:
   `09-Install/07-oracle_setup_repository.sh` (RCU with a **new prefix**,
   `DB_SCHEMA_PREFIX`), `08-` (domain), then `09-` … `15-` as for a new
   installation. Every piece is a supported, tested script path; the domain
   is short to create compared to the installation of the homes.
2. **Clone the domain and re-bind it to a copied repository.** Data Pump
   export of the source prefix (`07-Maintenance/rcu_repository_check.sh
   --apply`), import under a new prefix (`REMAP_SCHEMA`), then on the clone:
   all JDBC data sources (user + URL), the OPSS bootstrap of
   `jps-config.xml` / `jps-config-jse.xml` and its credential, the service
   table `<newprefix>_STB` (it lists the old schema names) and the rows of
   the new prefix in `SCHEMA_VERSION_REGISTRY$` (missing rows = RCU cannot
   manage the prefix later, §4.1 there). Many places, not supported as a
   procedure by Oracle, **not tested** here – only if way 1 is impossible.
3. **Clone the domain, new RCU prefix, OPSS moved with
   `reassociateSecurityStore` (optional, tested 2026-11-10).** The
   domain is cloned with the machine; on the clone, before the managed
   servers start. Not described as a procedure by Oracle – the pieces
   (`reassociateSecurityStore`, `updateCred`, offline data source change) are
   documented single commands (section 8), the order and the leftovers are
   our tests.

   Flow of way 3 (as run on the test host and at a customer, 2026-11-10;
   `<SRC>` = prefix of the source, `<NEW>` = new prefix; the new prefix may
   be in the same or in another database):

   ```
     SOURCE host A                CLONE host B                            RCU database(s)
     -------------                ------------                            ---------------
     0 autostart off,
       stop the domain
     1 VM clone ----------------> copy of A: same domain, same config,
                                  still bound to <SRC>  (do NOT start!)
     2 autostart on, start
       (A unchanged)              3 Linux identity: host name, IP,
                                    machine-id, ssh keys
                                  4 BEFORE any start / stop of B:
                                    - ADMIN_URL -> t3://localhost (bin/*.sh,
                                      profile) - else stop hits A
                                    - AdminURL -> localhost (servers/*/data/
                                      nodemanager/startup.properties)
                                    - backup $DOMAIN_HOME/config
                                    - <server>.dat aside (scheduled jobs)
                                  5 RCU -createRepository -------------->  <NEW>_STB _OPSS _IAU*
                                    (same components as A)                 _WLS _WLS_RUNTIME
                                                                           (empty, no OPSS root)
                                  6 start the AdminServer ONLY  --read-->  <SRC>_OPSS (store of A)
                                  7 WLST online:
                                    - data source jdbc/OpssDataSource<NEW>
                                      (URL of the NEW DB, user <NEW>_OPSS)
                                    - reassociateSecurityStore --copy--->  <NEW>_OPSS: policies,
                                      rewrites jps-config.xml,             credentials, keys,
                                      jps-config-jse.xml (jdbc.url),       audit configuration
                                      bootstrap key, farm cn=<domain>
                                    - updateCred AuditDbPrincipalKey
                                      -> <NEW>_IAU_APPEND
                                  8 stop: ADMIN_URL=t3://localhost:7001 stopWebLogic.sh
                                  9 WLST offline (readDomain / updateDomain):
                                    6 data sources: user <NEW>_..., password
                                    (+ URL if another DB)
                                    file edit, jps-config-jse.xml:
                                    audit.loader.jdbc.string -> URL of the
                                    new DB (not rewritten by Oracle)
                                  10 host-specific: Reports multicast port,
                                     mail sender, Nginx + certificate, firewall,
                                     tools patch_install.ini, crontab
                                  11 start all, autostart on  ----------->  sessions only <NEW>_*
                                  12 checks:                                (OPSS, IAU_APPEND,
                                     - clone_check.sh                        IAU_VIEWER, STB)
                                     - v$session: B only on <NEW>,
                                       no session of B on <SRC>
                                     - showjobs queuetype=future = 0
     13 check A: showjobs future
        = its jobs, sessions <SRC>
        only from A
   ```

   The steps in detail:
   0. Before any start / stop on the clone: `ADMIN_URL` (`bin/*.sh`, profile)
      and `AdminURL` (`servers/*/data/nodemanager/startup.properties`) to
      `localhost`, backup of `config/`, `<server>.dat` aside (section 3).
   1. RCU creates a **new prefix** with the same components as the source
      (customer domain: `STB OPSS IAU IAU_APPEND IAU_VIEWER WLS` – WLS brings
      `WLS_RUNTIME`).
   2. Only the AdminServer starts (still on the OPSS of the source – reading;
      audit rows may land in the source `_IAU_APPEND`).
   3. Online WLST: a new data source on `<new>_OPSS` (JNDI e.g.
      `jdbc/OpssDataSource<new>`), then
      `reassociateSecurityStore(domain=..., servertype='DB_ORACLE',
      jpsroot='cn=opssRoot', datasourcename=<JNDI>, jdbcurl=..., jdbcdriver=...,
      dbUser='<new>_OPSS', dbPassword=...)`. Oracle: it "migrates the security
      store from a source to a target store and resets service configurations
      in the `jps-config.xml` and `jps-config-jse.xml` files" and the bootstrap
      credential (**documented**, OPSS 12.2.1.3 "reassociateSecurityStore",
      section 8). Oracle marks it "interactive mode only"; in a WLST script
      it worked (**confirmed (live)**, test host and customer).
   4. Online WLST: `updateCred(map='AuditDbPrincipalMap',
      key='AuditDbPrincipalKey', user='<new>_IAU_APPEND', password=...)` – the
      Java SE audit credential was copied with the old user (**documented**
      command, also "interactive mode only"; script result at the customer
      pending).
   5. Stop with `ADMIN_URL=t3://localhost:7001` (section 3); the remaining
      data sources (`LocalSvcTblDataSource` → `_STB`,
      `opss-audit-DBDS` → `_IAU_APPEND`, `opss-audit-viewDS` → `_IAU_VIEWER`,
      `WLSSchemaDataSource` → `_WLS`, `WLSRuntimeSchemaDataSource` →
      `_WLS_RUNTIME`, the old `opss-data-source`) to the new prefix – user +
      password, and the URL when the new prefix lives in another DB.
   6. `jps-config-jse.xml`: `audit.loader.jdbc.string` of the `audit.db`
      instance to the value of `jdbc.url` (another DB only – see below).
   7. Host-specific places (section 3), start all, checks: `v$session` on
      both DBs, `showjobs queuetype=future` on the clone (0) and on the source
      (its jobs, [reports_job_handling.md](reports_job_handling.md) §6).

   Why not offline – **confirmed (live)** on the test host 2026-11-10:
   - `migrateSecurityStore` (WLST offline, DB → DB, assembled config file
     with a source and a target context, target bootstrap credential added
     with `addBootStrapCredential`) stops with `JPS-01013: The credential
     store DN cn=CredentialStore,cn=opssSecurityStore,cn=JPSContext,cn=opssRoot
     is missing in the store; the target DN must be pre-configured.` – a
     schema freshly created by RCU has no OPSS root.
   - No `configureSecurityStore.py` in the 14.1.2 Oracle home (`find`, test
     host) – that it created the root in older releases is an
     **assumption**; the WLST command list of 14.1.2 (`Opss.py`,
     `jpsWlstCmd.py` in `oracle.fmwshare.pyjar.jar`) has no offline command
     for it, `tenantOnBoard` is for multi-tenant stores.
   - The DB → DB examples of `migrateSecurityStore` (config file with
     `jdbc.url`, `bootstrap.security.principal.key/map`, two contexts) are
     **documented** in OPSS 12.2.1.3 `addlsecfea.htm` (section 8); Oracle
     there does not say that the target must already hold a store.
   - The default context of the copied `jps-config.xml` must not be used
     offline (`idstore.ldap` needs the WebLogic configuration) – set
     `default=` to the source context.

   Test on the test host 2026-11-10 – **confirmed (live)**, domain
   `fr_domain` from `DEV` to the new prefix `CLN`:
   - `reassociateSecurityStore` in a WLST **script** (not only interactive)
     answered "Policy / Credential / Keystore / Audit store reassociation
     done"; `jps-config.xml` then has `datasource.jndi.name =
     jdbc/OpssDataSourceCLN`, a new bootstrap key, and the farm name changes
     from `cn=opssSecurityStore` to `cn=<domain>`.
   - The other data sources offline (`readDomain` → user + `PasswordEncrypted`
     per data source → `updateDomain`); `07-Maintenance/domain_jdk_path.sh`
     afterwards: no versioned JDK path.
   - Full start: `v$session` shows only `CLN_*` (OPSS 10, IAU_APPEND 3,
     IAU_VIEWER 3, STB 1), no `DEV_*`; no `<Error>` / `JPS-` in the server
     logs; `09-Install/15-` smoke test 32 OK (Forms, secured Reports server
     with `cmdkey`, PDF + fonts); `listAppStripes` shows `reports`.
   - Side effect: `updateDomain` drops elements with default values, e.g.
     `<enabled>false</enabled>` of the managed-server SSL (stays off, the
     default) – compare `config.xml` before / after.
   - Way back: restore `config/` from the backup, restart → only `DEV_*`
     sessions, smoke test OK. The source prefix is only read.
   - Not rewritten by `reassociateSecurityStore` – **confirmed (customer,
     2026-11-10, new prefix in ANOTHER database)**: in `jps-config-jse.xml`
     the `jdbc.url` of `props.db.1` moved to the new DB, but
     `audit.loader.jdbc.string` of the `audit.db` instance (Java SE audit
     loader – standalone Reports server, Java SE tools) still named the old
     DB. On the test host the same line exists; it went unnoticed because the
     DB stayed the same. Fix: copy the `jdbc.url` value into
     `audit.loader.jdbc.string` with the domain stopped. The audit credential
     `AuditDbPrincipalMap` / `AuditDbPrincipalKey` is copied with the old
     `_IAU_APPEND` user – the customer cookbook updates it with `updateCred`
     while the AdminServer runs (result at the customer pending).
   - Another RCU database: the new data source and `reassociateSecurityStore`
     get the URL of the **new** DB; the offline step sets `URL` in addition to
     user + password on every data source (`set('URL', …)` under
     `JDBCDriverParams/NO_NAME_0`, attribute checked read-only on the test
     host). The clone must reach both DBs during the reassociation.
   - Customer run 2026-11-10 (Reports only, AdminServer + `WLS_REPORTS`,
     standalone Reports server, other DB) – **confirmed (live)**: after the full
     start `v$session` on the new DB shows only the new prefix from the clone:
     `_OPSS` 6 (5 × program `SERVER` = data sources, 1 × `JDBC Thin Client`
     after the start of `WLS_REPORTS`, fits the standalone Reports server via
     `jdbc.url`), `_IAU_APPEND` 2, `_IAU_VIEWER` 2, `_STB` 1. `_WLS`,
     `_WLS_RUNTIME` and `_IAU` log in never – `WLSSchemaDataSource` /
     `WLSRuntimeSchemaDataSource` have no target in a Forms / Reports domain,
     `_IAU` is the owner schema.
   - The EM login was not tested by form (EM 302 OK).
   - Manual cookbook (anonymised from the customer run):
     [FormsReports14_linux_clone](../70-Customer-Projects/FormsReports14_linux_clone/README.md)
     (structure: autostart off on the source, clone, Linux identity, backup
     + `.dat` aside, RCU, AdminServer only + reassociate, data sources
     offline, multicast port / mail sender / Nginx, start, checks).

---

## 6. Recipe – golden image

Four phases; each ends with a gate. Do not start the next phase before the
gate is passed.

1. **Prepare the source.**
   - Harden to localhost – checklist section 2.1 (`02-Checks/clone_check.sh
     --apply` covers SSL / Coherence; the rest by `09-Install/08-`, `13-` or
     the localhost cookbook).
   - External RCU: decide the way first (section 5). Way 3: switch the
     autostart **off** before the VM is copied – the clone must not start
     against the source prefix on its first boot.
   - Stop the domain (`01-Run/startStop.sh stop-all --apply`).
   - **Gate:** `clone_check.sh` "Clone-capable: yes"; smoke test OK.
2. **Clone** with the OS / hypervisor tooling (new machine-id, ssh keys,
   host name, IP); start the source again and switch its autostart back on.
   - **Gate:** the source runs unchanged (status, smoke test).
3. **Re-personalise the clone** – in this order:
   - **first, before any start / stop:** `ADMIN_URL` in `$DOMAIN_HOME/bin/*.sh`
     and in the oracle profile to `t3://localhost:<port>`, `AdminURL` in
     `servers/*/data/nodemanager/startup.properties` to localhost (section
     3) – else the clone's scripts and managed servers address the source;
   - backup of `config/`, scheduled Reports jobs `<server>.dat` aside;
   - RCU external: new prefix – section 5, way 1 (image without domain) or
     way 3 (`reassociateSecurityStore`, data sources, audit URL);
   - secrets: `01-setup-interview.sh` or the single setters
     (`00-Setup/weblogic_sec.sh`, `mos_sec.sh`, …) – `*.des3` are bound to
     the disk;
   - `environment.conf`: `WLS_SERVER_FQDN`, `FORMS_CLIENT_BASE_URL`,
     `REPORTS_BROADCAST_PORT`, DB values if the DB changes; then
     `13- --apply`, `40- --apply`;
   - certificate + Nginx (`08-SSL`, `09-Install/05-root_nginx_ssl.sh`),
     firewall, Reports mail sender;
   - tools `patch_install.ini` regenerated, crontab checked (section 3).
4. **Check the clone and the source.**
   - `clone_check.sh` on the clone ("Clone-capable: yes", the remaining
     STEP items are the new host's own values), smoke test `09-Install/15-`;
   - external RCU: `v$session` – the clone only on its new prefix, no
     session of the clone on the source prefix
     ([rcu_middleware_architecture.md](rcu_middleware_architecture.md) §3.1);
   - `showjobs queuetype=future`: clone 0, source its jobs;
   - EM: all servers green (`BEA-149506` in the AdminServer log).

---

## 7. Open

- Why Coherence keeps listeners on the host IP; supported way to remove
  them (MOS 2420434.1 "How To Bring Up The Coherence Cluster With Loop
  Back Address, 127.0.0.1?" – not read).
- `frmweb` bind address: ask Oracle (SR) whether an option exists.
- Way 3 (`reassociateSecurityStore`) was tested live on the test host and
  run at a customer on 2026-11-10 (Reports-only domain, new prefix in
  another DB, followed by the localhost gaps of section 2.1). Not run yet:
  a clone of a domain **with Forms**, way 2 of section 5 (re-bind to a
  copied repository), the complete golden-image recipe of section 6 with
  `13-` / `40- --apply` on the clone.
- Way 3 leftovers: `updateCred` of `AuditDbPrincipalKey` (Java SE audit
  credential) to the new `_IAU_APPEND` user – result at the customer pending;
  whether the standalone Reports server writes audit rows at all with
  `audit.filterPreset=None`; EM login by form not tested after the move.
- The test prefix `CLN` in the test DB (drop with RCU when no longer needed).

---

## 8. Sources

All checked 2026-10-23 (HTTP 200, title matches):

- Oracle Forms 14.1.2 – Managing Environment Variables –
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/working-forms/managing-environment-variables.html
- Oracle Forms 14.1.2 – Oracle Forms Services in Action –
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/working-forms/oracle-forms-services-action.html
- WebLogic 14.1.2 Fusion Middleware Control help – Server: Administration:
  Coherence (`CoherenceMemberConfigMBean.UnicastListenAddress`) –
  https://docs.oracle.com/cd/G29095_01/fusion-middleware/weblogic-server/14.1.2/fmwch/pagehelp/Coherencewlsserverconfigtitle.html
- Coherence 3.1 User Guide : unicast-listener (WKA licence note, old release) –
  https://docs.oracle.com/cd/E14008_01/coh.310/coh31ug/unicast_listener.htm
- MOS Doc ID 437228.1 (Reports broadcast port per environment) – see
  [reports_server_discovery_multicast.md](reports_server_discovery_multicast.md)
- MOS Doc ID 2420434.1 "How To Bring Up The Coherence Cluster With Loop Back
  Address, 127.0.0.1?" – named in section 7, **not read**

Added 2026-11-10 for section 5, way 3 (HTTP 200 checked 2026-11-10; the
14.1.2 library links to the 12.2.1.x OPSS books):

- Oracle OPSS 12.2.1.3 – Managing Policies with WLST,
  `reassociateSecurityStore` (syntax, DB arguments, `join` / `migrate`) –
  https://docs.oracle.com/middleware/12213/opss/JISEC/managepols.htm
- Oracle OPSS 12.2.1.3 – Deploying Secure Applications, `migrateSecurityStore`
  DB → DB examples (policies, credentials, keys) –
  https://docs.oracle.com/middleware/12213/opss/JISEC/addlsecfea.htm
- Oracle OPSS 12.2.1.3 – Configuring the Security Store (DB store, resetting
  the OPSS schema password with `modifyBootStrapCredential`, offline use of
  `migrateSecurityStore`) –
  https://docs.oracle.com/middleware/12213/opss/JISEC/cfgauthr.htm
- Oracle WLST Command Reference for Infrastructure Security 12.2.1.4 – OPSS
  security store commands (`migrateSecurityStore` offline,
  `reassociateSecurityStore` online, `modifyBootStrapCredential`) –
  https://docs.oracle.com/en/middleware/fusion-middleware/platform-security/12.2.1.4/idmcr/security_wlst.html
- Code, test host 14.1.2: `oracle_common/modules/internal/clients/oracle.fmwshare.pyjar.jar`
  (`wlstScriptDir/Opss.py`, `jpsWlstCmd.py`) – list of the OPSS WLST commands

Added later on 2026-11-10 (HTTP 200 checked 2026-11-10):

- The same WLST Command Reference 12.2.1.4 (link above) – `updateCred(map,
  key, user, password, [desc])`, online, "interactive mode only"; `listCred`
  is not on that page.
- Oracle OPSS 12.2.1.3 – Managing Audit, "Configuring Standalone Audit
  Loader": "Java SE applications also use the standalone audit loader";
  names the system property `auditloader.jdbcString`. The
  `jps-config-jse.xml` property `audit.loader.jdbc.string` itself is not
  described there – what it holds and that `reassociateSecurityStore` keeps
  it is our finding (customer, section 5) –
  https://docs.oracle.com/middleware/12213/opss/JISEC/audpolicy.htm
- Code, test host 14.1.2: `$DOMAIN_HOME/bin/stopWebLogic.sh` (generated by
  the Configuration Wizard) – `ADMIN_URL` from the 3rd argument, else from the
  environment, else the value written at the domain creation (section 3).
- `servers/<ms>/data/nodemanager/startup.properties` `AdminURL`: customer
  source and clone 2026-11-10 (host IP, `WLS_REPORTS.log` "being started in
  Managed Server independence mode in the absence of the Administration
  Server" at every start, AdminServer `BEA-149505` only, no `BEA-149506`);
  test host has `localhost` there (domain created with `localhost`).
- Offline WLST attribute `URL` of `JDBCDriverParams/NO_NAME_0`: read on the
  test host (`readDomain`, no `updateDomain`).
- Scheduled jobs, `.dat`, `showjobs`: [reports_job_handling.md](reports_job_handling.md)
  §2, §6, §8 (with its own sources).
