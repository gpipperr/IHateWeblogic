# Clone-Capable Installation – Loopback Only, One Host Name at the Edge

What a Forms / Reports 14.1.2 host binds to, which files hold its host
name, IP or machine identity, and what has to change after the machine is
cloned. Goal: everything internal runs over `127.0.0.1`, only Nginx (and the
certificate) carries the host name – then an installation can serve as a
**golden image** and is easy to move.

Markers: **confirmed (live)** (test host, date given), **documented**
(source in section 7), **assumption** (not proven yet).

Related:
[weblogic_middleware_architecture.md](weblogic_middleware_architecture.md)
(processes and who starts whom),
[forms_runtime_architecture.md](forms_runtime_architecture.md) (`frmweb`
sockets),
[report_engine_architecture.md](report_engine_architecture.md) (server /
engine CORBA),
[reports_server_discovery_multicast.md](reports_server_discovery_multicast.md)
(multicast discovery). Check script: `02-Checks/clone_check.sh`.

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
| WLS_FORMS / WLS_REPORTS SSL | 9501 / 9512, **demo certificate** | `localhost` | **off** | `/Servers/<ms>/SSL/<ms>` `Enabled=false` | confirmed (live) |
| Reports server `rwserver` | CORBA, ephemeral | `0.0.0.0` | **`127.0.0.1`** | `-Dcom.sun.corba.ee.ORBServerHost=127.0.0.1` in `REPORTS_JVM_OPTIONS` (`reports.sh`) | confirmed (live) |
| Reports engines (`rwEng-*`) | CORBA, ephemeral | `0.0.0.0` | **`127.0.0.1`** | the engines inherit `REPORTS_JVM_OPTIONS` of the server – no own setting needed | confirmed (live) |
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

---

## 3. Where the host name, IP and machine identity live

| Place | Content | After a clone | Marker |
|---|---|---|---|
| Nginx `server_name`, TLS certificate CN / SAN | host name | **new certificate**, `09-Install/04-root_nginx.sh` / `05-root_nginx_ssl.sh` | – |
| `environment.conf` `WLS_SERVER_FQDN`, `FORMS_CLIENT_BASE_URL` | host name / URL | set, then `09-Install/40- --apply` (client manifest) | – |
| `$DOMAIN_HOME/config/jdbc/*-jdbc.xml`, `fmwconfig/jps-config*.xml` | DB host **and prefix** of the RCU repository | DB on the same host: cloned along, only the host name (better `localhost` from the start); **external DB: own prefix per clone – section 5** | confirmed (live) |
| `tnsnames.ora` in `TNS_ADMIN` | DB host | same as above | – |
| `*.des3` secret files | encrypted with the **disk UUID** (`_get_system_identifier`) | **unreadable** on the clone – re-enter (table "Password Security Concept" in the root README) | confirmed (code, lib) |
| Reports `rwnetwork.conf` multicast port + server name | `REPORTS_BROADCAST_PORT`, `repserver01` | clones in one subnet: **change the port** (14021–14030), `13- --apply` | documented (Doc ID 437228.1) |
| `init-info/tokenValue.properties` `@HOST_NAME` | host name of the domain creation | informational, not read at runtime | assumption |
| `uifont.ali` header comment | host name of the generation | comment only | confirmed (live) |
| `/etc/machine-id`, ssh host keys, `/etc/hosts` | machine identity | OS clone tooling (`virt-sysprep` / cloud-init) | – |
| `oraInventory`, Oracle Home | paths only | unchanged | – |

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
| **external** | the clone must **not start** against the repository of the source – two domains would write into the same OPSS store (policies, keystores, credentials), the same `_WLS` runtime / lease tables and the same service table (**assumption** from the design, not tested – do not try it on a production repository) |

External RCU – two ways, the first one recommended:

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

---

## 6. Recipe – golden image

1. **Prepare** (source host; external RCU: see section 5 first): `02-Checks/clone_check.sh` until only the
   INFO items of section 3 remain (`--apply` switches off SSL, sets the
   Coherence and ORB addresses). Stop the domain (`01-Run/startStop.sh
   stop-all --apply`).
2. **Clone** with the OS / hypervisor tooling (new machine-id, ssh keys,
   host name, IP).
3. **Re-personalise** (clone):
   - secrets: `01-setup-interview.sh` or the single setters
     (`00-Setup/weblogic_sec.sh`, `mos_sec.sh`, …);
   - `environment.conf`: `WLS_SERVER_FQDN`, `FORMS_CLIENT_BASE_URL`,
     `REPORTS_BROADCAST_PORT`, DB values if the DB changes;
   - certificate + Nginx (`08-SSL`, `09-Install/05-root_nginx_ssl.sh`);
   - RCU external: new prefix per clone (section 5, way 1 – the image then
     holds no domain);
   - `13- --apply`, `40- --apply`, start, `02-Checks/clone_check.sh` and
     the smoke test `09-Install/15-`.

---

## 7. Open

- Why Coherence keeps listeners on the host IP; supported way to remove
  them (MOS 2420434.1 "How To Bring Up The Coherence Cluster With Loop
  Back Address, 127.0.0.1?" – not read).
- `frmweb` bind address: ask Oracle (SR) whether an option exists.
- A full clone with the recipe of section 6 has not been run yet; way 2 of
  section 5 (re-bind to a copied repository) is untested.

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
