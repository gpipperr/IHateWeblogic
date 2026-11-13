---
title: "Apache Derby in WebLogic 14.1.2 – History and Disabling"
description: "Why every WebLogic 14.1.2 domain starts an Apache Derby database on port 1527: from BEA PointBase to Derby, what it was good for, and how to switch it off."
---

# Apache Derby in WebLogic – where it comes from, what it was for, how to switch it off

A Forms & Reports 14.1.2 domain runs a database nobody installed: the Apache
Derby **Network Server** on `127.0.0.1:1527`. It is a leftover of the
"zero-install" idea of BEA WebLogic – a small all-Java database that makes
samples, the Configuration Wizard and developer installations work without
an Oracle database. This page explains where it comes from (BEA PointBase →
Apache Derby), what it was and still is used for, why a Forms & Reports
domain does not need it, and how to switch it off.

Markers as in [README.md](README.md): **confirmed (live)** = test host
2026-11-13 (FMW 14.1.2, `fr_domain`, CPU Oct 2026), **documented** = Oracle /
Apache documentation (sources in section 7), **assumption** = plausible, not
verified.

---

## 1. What runs on the test host

**confirmed (live)**, 2026-11-13:

| What | Value |
|---|---|
| process | `java … org.apache.derby.drda.NetworkServerControl start` (JDK 21 of `JDK_HOME`, about 80 MB RSS), parent PID 1 – detached from the server that started it |
| listen | `127.0.0.1:1527` only |
| software | `$WL_HOME/common/derby/lib/derby*.jar` – **Apache Derby 10.16.1.1, Oracle build `1905560-wls`** (manifest `Bundle-Version: 10.16.1000001.1905560-wls`) |
| system home | `-Dderby.system.home=$DOMAIN_HOME/common/db` – contains only `readme.txt` and `derby.log`, **no database** |
| started by | `$DOMAIN_HOME/bin/startWebLogic.sh` of `WLS_REPORTS`, called by the Node Manager (`nodemanager.log` 2026-11-11 15:02:55 "Starting WebLogic server with command line: …/startWebLogic.sh", `derby.log` one second later "Apache Derby Network Server - 10.16.1.1 … started … on port 1527") |
| used by | **nothing** – no JDBC data source in `config/jdbc/` or `config.xml` points to Derby; the domain runs in production mode and still starts it |

How it is switched on – the generated domain scripts, **confirmed (live)**:

```text
setDomainEnv.sh, line ~155
  if DERBY_FLAG is empty and $WL_HOME/common/derby/lib/derby.jar exists
      -> DERBY_FLAG="true"
  argument "noderby" -> DERBY_FLAG="false"
  line ~332: . $DOMAIN_HOME/bin/setUserOverrides.sh   (after the default!)

startWebLogic.sh
  . setDomainEnv.sh
  if DERBY_FLAG = true -> $WL_HOME/common/derby/bin/startNetworkServer.sh &
  trap on stop         -> stopNetworkServer.sh   ("only if we started it")
```

So **every** server started through `startWebLogic.sh` – AdminServer,
`WLS_FORMS`, `WLS_REPORTS`, by hand or by the Node Manager – tries to start
Derby. The first one gets port 1527, the others fail silently (the port is
taken). Stopping a server through its start script runs the trap and stops
the shared Derby (seen in `WLS_REPORTS.out`: "Stopping Derby server… Derby
server stopped."), the next start brings it back. A server killed instead
of stopped leaves Derby running without a parent – as on the test host.

Oracle knows this behaviour – and still documents it with 11g material:
- The **WebLogic 14.1.1 release notes** list the known issue *"Issue
  Starting Multiple Development Servers On Same Host – Two development
  servers cannot be started on the same host if they are sharing a single
  Derby instance"*; the workaround links to *"Running Each Domain with a
  Unique Derby Instance"* in the **Oracle Service Bus 11g** Developer's
  Guide (source 15, **documented**).
- That 11g chapter (source 14) describes the same mechanics as above:
  every normal server start also starts Derby; `DERBY_FLAG=false` in
  `setDomainEnv` "prevents a server shutdown from stopping the running
  Derby instance"; `startWebLogic noderby` suppresses the start; a second
  domain gets its own Derby with `-p <port>` on the `startNetworkServer`
  line of `startWebLogic`.
- The **14.1.2** release notes no longer list the Derby issue (checked
  2026-11-13); they only say that Java DB is not supported for server
  migration (no leasing script in `WL_HOME/server/db`).

So the mechanism of an OSB 11g developer domain from around 2010 is
unchanged in every 14.1.2 domain – Derby is retired at Apache, but alive in
the WebLogic start scripts.

## 2. History – from BEA PointBase to Apache Derby

```text
 1996  Cloudscape Inc. (Oakland) – Java database, 1997 first release "JBMS"
 1999  Informix buys Cloudscape
 2001  IBM buys the Informix database business -> "IBM Cloudscape"
 2004  IBM donates the code to the Apache Software Foundation -> "Derby"
 2005  Derby leaves the Apache incubator
 2006  Sun ships it as "Java DB" with JDK 6 (until JDK 8)
 2015  Oracle: no Java DB in JDK 9 and later

 BEA WebLogic 8.1 / 9 / 10.0 (and Oracle WebLogic 10.3 until 10.3.2)
       evaluation database = PointBase (all-Java DBMS, licence from DataMirror)
 2010  WebLogic 10.3.3: evaluation database PointBase -> Apache Derby
       10.3.6: MedRec samples on Derby
 2015  WebLogic 12.2.1: Derby backs the Java EE 7 default data source
 2023  Derby 10.17.1.0 – last release of the project
 2025  2025-10-10: the Derby developers vote to retire the project (read-only)
 2026  WebLogic 14.1.2 still ships Derby 10.16 (own build "-wls")
```

**documented** (sources 1–5, 9): Cloudscape → Informix → IBM → Apache Derby;
Java DB in the JDK and its end with JDK 9; BEA's PointBase as "the default
database that BEA provides", used for the sample domains and for every
domain created with the Configuration Wizard, supported "only for the
design, development, and verification of applications", evaluation licence
limited to 30 MB, other use needed a licence from DataMirror; the switch to
Derby in WebLogic 10.3.3 with the same "development only" statement.

**documented** (source 12, the project page): "On 2025-10-10, the Derby
developers voted to retire the project into a read-only state." – no
releases, no bug or security fixes any more; the last release is 10.17.1.0
(14 November 2023). WebLogic 14.1.2 ships the older 10.16 line in an Oracle
build – whatever is fixed there comes from Oracle, not from Apache.

## 3. What it was good for – and the link to RCU

The idea behind both PointBase and Derby: **a WebLogic installation that
works without installing a database.**

| Use | Era | Status |
|---|---|---|
| sample domains (`examples`, MedRec) | BEA → 12c | samples are not installed with Forms & Reports |
| Configuration Wizard default: every new domain got an evaluation database (PointBase, ports 9092 / 9093) | BEA 8.1 / 9 / 10 | gone |
| repository of BEA products for evaluation – **WebLogic Portal / Integration** created their schemas in PointBase, a production install moved them to Oracle / DB2 / SQL Server with database scripts | BEA 8.1 – 10.3 | replaced by RCU |
| Java EE 7 **default data source** `java:comp/DefaultDataSource` (`org.apache.derby.jdbc.ClientDataSource`, `localhost:1527`, database `DefaultDataSource`, no user / password) | WebLogic 12.2.1 → 14.1.2 | still there – unavailable with `DERBY_FLAG=false` |
| developer installations: **SOA / BPM Quick Start** and the integrated WebLogic of JDeveloper use Java DB **instead of RCU schemas**; components that do not run on Java DB need a compact domain with RCU | FMW 12.1.3 → 14.1.2 | still there (not in a Forms & Reports install) |
| Oracle Service Bus reporting (`wlsbjmsrpDataSource`) in a development domain – "the only Oracle Service Bus module that persists data in a database", Derby under `WL_HOME/common/derby/demo/databases/` (source 14) | 11g / 12c | OSB only |
| **trial editions of FMW products** – e.g. the Oracle BI Publisher 11.1.1.7 Trial Edition on WebLogic 10.3.6 ships "Java DB 10.6.1.0 – für das Repository": one download, no database, no RCU (source 13) | 11g | gone |

**Derby and RCU – two answers to the same question.** A Fusion Middleware
product needs tables for its metadata (security store, MDS, audit, job
state). The BEA answer was a bundled evaluation database plus database
scripts for production; Oracle Fusion Middleware 11g (2009) introduced the
**Repository Creation Utility** as the one way to create these schemas in a
real database ([rcu_middleware_architecture.md](rcu_middleware_architecture.md)).
The bundled Java database lived on for the cases where a real database is
too much: samples, trial editions (BI Publisher 11g kept its repository in
Java DB), the Java EE default data source, and the developer Quick Starts –
there Java DB still **is** the replacement for the RCU schemas. In other words: PointBase / Derby is not the technical predecessor
of RCU, but the "no database needed" alternative that RCU made obsolete for
everything except development. (*Interpretation of sources 2, 5, 7, 8 – no
Oracle document says it in these words.*)

## 4. Why a Forms & Reports domain does not need it

- **No component uses it.** Forms and Reports keep nothing in Derby; the
  FMW schemas (OPSS, MDS, STB, IAU, WLS) are in the RCU database, the
  Reports job store in files ([reports_job_handling.md](reports_job_handling.md)).
  On the test host no data source points to Derby (section 1).
- **`java:comp/DefaultDataSource`** is a Java EE convenience for
  applications that do not name a data source. Forms (`formsapp`), Reports
  (`reports`), EM and the WebLogic applications do not rely on it
  (**assumption** for applications deployed later by the customer – check
  before switching off, section 5).
- **Production use is not supported:** Oracle supports the bundled Derby
  only for design, development and verification (source 5).
- **Cost:** one more JVM (about 80 MB), one more listening port, a database
  engine whose upstream project has stopped releasing, and confusing
  start / stop behaviour across servers (section 1).

**Security view.** The network server listens only on `127.0.0.1`, and
Derby has **no authentication** by default – every local user and every
local process can connect and create databases under
`$DOMAIN_HOME/common/db`. On a single-purpose FMW host that is a small
risk, but it is a risk without any benefit. CVE-2022-46337 (Derby LDAP
authentication bypass, fixed in 10.16.1.2 upstream) does not apply as long
as Derby LDAP authentication is not configured – which it is not.
[`10-Monitoring/cve_inventory.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/10-Monitoring/cve_inventory.sh) shows the process as "Derby (WLS sample DB)".

## 5. Switching Derby off

The Oracle-supported switch is the variable `DERBY_FLAG` (sources 6, 7, 10).
Put it into **`setUserOverrides.sh`** – it is sourced by `setDomainEnv.sh`
**after** the default (line ~332 vs. ~155, **confirmed (live)**), it
survives domain updates and patches, and it covers all servers and all
start ways (Node Manager, `startWebLogic.sh`, `startManagedWebLogic.sh`).
Editing `setDomainEnv.sh` itself works too, but a domain reconfiguration
rewrites that file.

As `oracle` (backup first):

```bash
cd $DOMAIN_HOME/bin

cp -p setUserOverrides.sh setUserOverrides.sh.bak_$(date +%Y%m%d_%H%M%S)

cat >> setUserOverrides.sh <<'EOF'

# Apache Derby (WLS evaluation database) - not used by Forms & Reports
DERBY_FLAG="false"
export DERBY_FLAG
EOF

grep -n DERBY_FLAG setUserOverrides.sh
# Expected: DERBY_FLAG="false" and export DERBY_FLAG
```

Then stop the running instance once (the next server starts no new one):

```bash
$WL_HOME/common/derby/bin/stopNetworkServer.sh

ss -ltnp | grep 1527
# Expected: no output
```

Check after the next restart of all servers: no `NetworkServerControl`
process (`pgrep -af derby`), nothing on 1527, Forms test form and a report
via `rwservlet` work, `$DOMAIN_HOME/derby.log` is not rewritten.

Other ways, not used here:
- argument `noderby` – `startWebLogic.sh noderby`; the Node Manager does not
  pass it, so it only helps for servers started by hand;
- removing `$WL_HOME/common/derby/` – changes the Oracle Home, comes back
  with the next WebLogic patch, and is not supported.

**Going back:** remove the three lines from `setUserOverrides.sh` (or
restore the backup) and restart a server.

## 6. Open points

- **Library step:** set `DERBY_FLAG=false` in `setUserOverrides.sh` during
  the domain configuration (`09-Install/09-oracle_configure.sh`, next to
  `TNS_ADMIN`) and check it in the security hardening
  ([80-oracle_security.md](../09-Install/docs/80-oracle_security.md)) and
  in [`02-Checks/port_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/port_check.sh) (port 1527 = finding) – not done yet.
- 14.1.2 lists the Node Manager properties `startscriptenabled` /
  `startscriptname` as removed (source 11), yet the test host's Node
  Manager starts the servers through `startWebLogic.sh` – and with it
  Derby. Why exactly (default behaviour vs. the old properties in
  `nodemanager.properties`) is not clear yet; the `setUserOverrides.sh`
  switch works for both cases.
- Confirm whether Oracle's build `10.16.1.1 … -wls` contains the fix of
  CVE-2022-46337 (upstream fixed in 10.16.1.2); relevant only with Derby
  LDAP authentication.

## 7. Sources

1. Apache Derby – history (Cloudscape, Informix, IBM, Apache, Java DB):
   <https://en.wikipedia.org/wiki/Apache_Derby>
2. BEA WebLogic Platform 8.1 – supported databases (PointBase):
   <https://docs.oracle.com/cd/E13196_01/platform/suppconfigs/configs81/81_over/supported_db.html>
3. BEA WebLogic Portal 8.1 – PointBase (default database, sample domains,
   Configuration Wizard, DataMirror licence):
   <https://docs.oracle.com/cd/E13218_01/wlp/docs81/db/pointbase.html>
4. WebLogic Portal 10.3.2 – PointBase (30 MB evaluation limit, ports):
   <https://docs.oracle.com/cd/E15919_01/wlp.1032/e14233/pointbase.htm>
5. WebLogic Server 10.3.3 – compatibility with previous releases
   (evaluation database PointBase → Apache Derby, development only):
   <https://docs.oracle.com/cd/E14571_01/web.1111/e13754/compat.htm>
6. WebLogic Portal 10.3.5 – Derby:
   <https://docs.oracle.com/cd/E35968_01/wlp.1035/e14233/derby.htm>
7. WebLogic Server 12.2.1.3 – Using the Default Data Source (Derby,
   `DERBY_FLAG`, `java:comp/DefaultDataSource`):
   <https://docs.oracle.com/middleware/12213/wls/JDBCA/default_datasource.htm>
8. SOA Suite 14.1.2 Quick Start – compact domain (Java DB vs. RCU):
   <https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/soaqs/SOA-COMPACT.html>
9. WebLogic Server 10.3.6 – compatibility (MedRec on Derby):
   <https://docs.oracle.com/middleware/11119/wls/WLUPG/compat.htm>
10. MOS Doc ID 2205413.1 "Disabling Derby Server From Starting Up at Startup
    of Oracle WebLogic Server" and Doc ID 2355058.1 "Why is the included
    Derby server configured by default to start up when the WebLogic Server
    is started?" (titles only – not read)
11. WebLogic Server 14.1.2 – deprecated and removed functionality:
    <https://docs.oracle.com/en/middleware/fusion-middleware/weblogic-server/14.1.2/notes/deprecated-removed-functionality.html>
12. Apache Derby project page (retirement vote 2025-10-10, last release
    10.17.1.0): <https://db.apache.org/derby/>
13. pipperr.de – Oracle BI Publisher 11g Trial Edition (11.1.1.7, WebLogic
    10.3.6, Java DB 10.6.1.0 as repository on `localhost:1527`; 2014 the
    network server stopped with `AccessControlException … "localhost:1527"
    "listen,resolve"` until `permission java.net.SocketPermission
    "localhost:1527", "listen";` was added to `$JAVA_HOME/jre/lib/security/java.policy`):
    <https://www.pipperr.de/dokuwiki/doku.php?id=prod:bipublisher_11g_trial_edition>
14. Oracle Service Bus 11g Developer's Guide, chapter "Development
    Environment Setup" (Derby only for development, reporting provider,
    `DERBY_FLAG`, `noderby`, own Derby port per domain):
    <https://docs.oracle.com/cd/E29542_01/dev.1111/e15866/dev_env.htm>
15. WebLogic Server 14.1.1 release notes – known issues ("Issue Starting
    Multiple Development Servers On Same Host", link to the OSB 11g guide):
    <https://docs.oracle.com/en/middleware/standalone/weblogic-server/14.1.1.0/wlsrn/issues.html>
16. WebLogic Server 14.1.2 release notes – known issues (no Derby issue;
    "No Java DB Leasing Script or Support"):
    <https://docs.oracle.com/en/middleware/fusion-middleware/weblogic-server/14.1.2/wlsrn/issues.html>
