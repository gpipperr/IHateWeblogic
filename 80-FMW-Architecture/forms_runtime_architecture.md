# Oracle Forms 14.1.2 – runtime architecture

How a Forms session runs on the server: servlet, listener, `frmweb`
processes, runtime pooling, timeouts, memory, configuration inheritance,
logs, where TLS is spoken and who uses Java's JSSE (section 1.1), the threat
model of a client-side TLS flaw (1.2) – and
where it comes from (section 8: protocol history 1979–2024). Background for `06-FormsDiag/` and `09-Install/14-oracle_setup_forms.sh`.

Markers: **confirmed (live)** = seen on the test host (FMW 14.1.2, OL 9),
**documented** = Oracle documentation (sources in sections 8.2 and 10),
**assumption** = plausible, not yet verified.

---

## 1. The parts

```
 client (Java Web Start / Standalone Launcher FSAL – no browser applet any more)
    |  HTTPS
    v
 Nginx / OHS  -->  WLS_FORMS (Java EE, application formsapp)
                     |
                     |  /forms/frmservlet   Forms servlet: reads formsweb.cfg,
                     |                      builds the JNLP / HTML start page
                     |  /forms/lservlet     Forms Listener servlet: broker between
                     |                      client and runtime, all session traffic
                     v
                   frmweb  (native C process, $ORACLE_HOME/bin/frmweb)
                     one per client session, child of the WLS_FORMS JVM
                     environment from the envFile (default.env)
                     |
                     v
                   database (SQL*Net, TNS_ADMIN / NLS_LANG from default.env)
```

- "The Forms Listener servlet manages the creation of a Forms Runtime
  process for each client and manages the network communications between the
  client and its associated Forms Runtime process" (**documented**,
  Oracle Forms Services Architecture).
- Process: `/u01/app/oracle/fmw/bin/frmweb webfile=HTTP-0,<config section>`,
  parent PID = WLS_FORMS JVM, working directory `$ORACLE_HOME/forms`
  (**confirmed (live)**). The section name in the command line is the
  `config=` parameter of the start URL.
- Each `frmweb` opens its **own TCP listen socket** on an ephemeral port on
  all interfaces (`0.0.0.0:34925` and `[::]:34925` for a pooled runtime,
  `ss -tanp`), the Listener servlet connects to it (**confirmed (live)**
  2026-10-19) – the socket principle of Forms 6i (section 8), only with the
  servlet in front. Reachable from the network unless the firewall blocks
  the port range (01-root_os_baseline section 8 keeps only ssh/http/https open).
  The bind address is **not configurable**: no `FORMS_*` variable for it in
  `frmweb` and its libraries, none in the 14.1.2 documentation (**documented**:
  none, 2026-10-23) – the socket holds no host name, so it is clone-neutral
  ([clone_golden_image.md](clone_golden_image.md)).
- The instance `forms1` (`config/fmwconfig/components/FORMS/instances/forms1/`)
  is configuration only (`webutil.cfg`, `ftrace.cfg`, `forms.conf`, tool
  scripts) – no own process ([weblogic_middleware_architecture.md](weblogic_middleware_architecture.md) §3.5).
- The **WLS_FORMS heap** holds the servlets and the session bookkeeping; the
  application runs in `frmweb` **outside** the JVM. Sizing sessions by
  `-Xmx` is therefore wrong – the limit is the RAM of the host and
  `maxRuntimeProcesses` (section 5).

### 1.1 Where TLS is spoken – and who uses Java's JSSE

JSSE (Java Secure Socket Extension) is the TLS implementation of every Java
runtime: "a framework and an implementation for a Java version of the TLS and
DTLS protocols" (**documented**, JSSE Reference Guide JDK 21). A Java
process that opens or accepts an HTTPS / TLS connection uses it – a native
process (Nginx, `frmweb`) does not. That decides which Java security fixes
matter for which part of a Forms installation (example: Security Alert
CVE-2026-91403, JSSE, CVSS 9.1, all Java lines – 8u511, 17.0.21, 21.0.13 and
older; Oracle's note names Java Web Start explicitly).

```
 client PC                              server
 +--------------------------+   HTTPS   +-------------------+  HTTP (loopback)  +------------------+  TCP (own port)  +--------+  SQL*Net
 | JWS / FSAL client JVM    |---------->| Nginx             |------------------>| WLS_FORMS JVM    |----------------->| frmweb |---------> DB
 | JSSE = TLS client        |  TLS 1.2+ | OpenSSL 3.5.8     |  127.0.0.1:9001   | no TLS on this   |  plain           | native |
 | (JNLP, jars, all session |           | (no Java)         |                   | hop              |                  | C      |
 |  traffic, WebUtil)       |           |                   |                   |                  |                  |        |
 +--------------------------+           +-------------------+                   +------------------+                  +--------+
```

| Hop | TLS by | Java JSSE involved? |
|---|---|---|
| client → Nginx (start page, JNLP, `frmall.jar` / `jacob.jar` download, every Listener-servlet request of the session, WebUtil file transfer) | client: **Java of the client PC** (JWS / FSAL), server: Nginx with OpenSSL (**confirmed (live)**: `nginx -V` "running with OpenSSL 3.5.8") | **yes – on the client**: the JRE / JDK that runs Java Web Start or the Standalone Launcher (**assumption** from the mechanism: Java's HTTPS client is JSSE) |
| Nginx → WLS_FORMS | none – plain HTTP to `127.0.0.1:9001`, Nginx sends `WL-Proxy-SSL: true` (**confirmed (live)**, [08-SSL](../08-SSL/README.md)) | no |
| WLS_FORMS → `frmweb` | none – TCP to the listen port of the runtime (section 1) | no – `frmweb` is native |
| `frmweb` → database | SQL*Net (native Oracle client; TCPS only if configured in `tnsnames.ora`) | no |
| WebLogic SSL listen ports `9501` / `9512` (demo certificate, enabled by the domain templates) | WebLogic | **off** since 2026-10-23 (`08-` template, `02-Checks/clone_check.sh --apply`) |
| WebLogic → LDAP / OID / AD over LDAPS, outbound HTTPS from applications | WebLogic | **yes** – only if configured (not on the test host, `egress_check.sh`) |

Consequence for a Java security fix:

1. **Client PCs first** – every JRE / JDK that starts Forms via Java Web
   Start or FSAL speaks TLS with JSSE to the server, for every request of
   the session. The server cannot enforce the client's Java version; the
   client rollout (GPO / software distribution, see
   [forms_jakob_webutil.md §12](forms_jakob_webutil.md#12-distribution-concept-for-the-clients))
   has to.
2. **Server JDKs** – `JDK_HOME` (WebLogic) and the bundled
   `oracle_common/jdk` (Reports engines, Forms/Reports tools) still get the
   fix (everything on disk gets patched), but with TLS ending at Nginx their
   JSSE is exposed only through the unused demo SSL ports and configured
   outbound TLS connections.
3. Nginx / OpenSSL fixes are OS errata (`dnf`), independent of Java.

### 1.2 Threat model of a client-side TLS (JSSE) flaw

A JSSE flaw on the client is not triggered by a correct server. Someone has
to **be the TLS peer of the client's Java, or sit in between**:

| Scenario | Realistic? | What the attacker gets |
|---|---|---|
| our own server sends malicious data | only if the server is already compromised | nothing extra – a compromised Forms server owns the session anyway |
| **man in the middle** between client and Nginx (internal LAN, Wi-Fi, home office / VPN, TLS-intercepting proxy, DNS redirect) | **yes – the main case** | read and **modify** the Forms session although the client shows HTTPS |
| **social engineering**: the user starts a foreign JNLP / FSAL URL from a mail or web page that points to the attacker's server | yes | the client's Java talks TLS to the attacker; Oracle's note for CVE-2026-91403 names Java Web Start |
| foreign code in the Java Web Start sandbox | hardly relevant here | a Forms application with WebUtil runs with `all-permissions` – it does not rely on the sandbox |

Reading of the CVSS vector of CVE-2026-91403 (network, no privileges, no
user interaction, confidentiality and integrity **high**, availability
**none**): it fits "TLS can be read or manipulated" rather than code
execution inside the client JVM – **assumption**, Oracle does not publish
details.

Why WebUtil raises the stakes: the server can trigger actions on the client
PC with the user's rights (`CLIENT_HOST`, file transfer, OLE via JACOB) and
even pushes native DLLs to it. An attacker who can manipulate the TLS of the
session can act as the server – see
[forms_jakob_webutil.md §10.1](forms_jakob_webutil.md#101-what-the-session-can-do-on-the-client--threat-model).

Measures, in order: patch the **client JREs** (the server cannot enforce
them – an own `jlink` runtime rebuilt at every Java CPU makes this a server
task: [java_jlink_forms_env.md](java_jlink_forms_env.md)); offer Forms only from trusted networks (internal / VPN); keep WebUtil
narrow; protect the code-signing key; let users start Forms only through the
distributed shortcut / FSAL call, never from mail links.

## 2. Configuration files and inheritance

Deployed application: `config/fmwconfig/servers/WLS_FORMS/applications/formsapp_14.1.2/config/`
(**confirmed (live)**):

| File | Content |
|---|---|
| `formsweb.cfg` | `[default]` + named sections (`config=<name>`). Oracle ships 10: `default`, `sepwin`, `debug`, `webutil`, `jnlp`, `webutil_jnlp`, `webstart`, `webutil_webstart`, `standaloneapp`, `webutil_standaloneapp` |
| `default.env` (= `envFile` of `[default]`) | environment of every `frmweb`: `ORACLE_HOME`, `FORMS_PATH`, `TNS_ADMIN`, `NLS_LANG`, `TMPDIR`, `PATH`, `LD_LIBRARY_PATH`, `FORMS_TIMEOUT` … |

Inheritance: "you need only specify the parameters you want to change. The
default values (defined above) will be used for all other parameters"
(comment in Oracle's `formsweb.cfg`, **documented**). A key set in
`[default]` is therefore active in **every** section that does not
override it – the reason for section 3. Some parameters are *global system
parameters* and are only read from `[default]` (e.g. `maxRuntimeProcesses`,
`allowNewConnections`, **documented**, Web Configuration Parameters).

### 2.1 Oracle Net – where `frmweb` finds the database alias

`frmweb` is a native Oracle client: a login `user/password@ALIAS` is
resolved with `tnsnames.ora` / `sqlnet.ora` in **`TNS_ADMIN` of
`default.env`** – not with the environment of WLS_FORMS. Without our value
the template default was `$DOMAIN_HOME/config/fmwconfig`, where the domain
creation leaves only Oracle's sample `tnsnames.ora` (no alias): every alias
login failed with `ORA-12162` (**confirmed (live)** 2026-10-23, FSAL client
on Windows). With `TNS_ADMIN` of `environment.conf`
(`$ORACLE_BASE/admin/tns_names`, written by `14-` into `default.env`) the
same login `DEV_STB@RCU` opened the test form (**confirmed (live)**,
2026-10-23). `default.env` is read for every new `frmweb` – a new session
uses a changed value at once, only the **prestart pool** keeps the
environment of its start until WLS_FORMS restarts (`/proc/<pid>/environ`,
**confirmed (live)**).

EZConnect (`host:port/service`) works without any `tnsnames.ora` as long as
`sqlnet.ora` does not exclude it (`NAMES.DIRECTORY_PATH`). The same
directory is used by Reports, WebLogic and the oracle shell – the full list
of places and who writes them:
[02-Checks/README.md – tns_admin_check.sh](../02-Checks/README.md#tns_admin_checksh).

`09-Install/14-` builds `formsweb.cfg` from Oracle's
`$ORACLE_HOME/forms/templates/config/formsweb.cfg` plus key overrides for
`[default]` – it never replaces the file
([09-Install/docs/14-forms-detail-settings.md](../09-Install/docs/14-forms-detail-settings.md) Step 4).

## 3. Runtime pooling (prestart)

"Forms Runtime Pooling (or Forms Runtime prestart) enables the startup of a
configurable number of application runtime engines prior to their usage"
(**documented**, Built-in Optimization Features). Parameters per section:
`prestartRuntimes` (default false), `prestartInit` (1), `prestartMin` (0,
must be <= Init), `prestartIncrement` (0), `prestartTimeout` (0 = never
stop); read only at frmservlet initialization – restart WLS_FORMS after a
change. Values are per WLS_FORMS JVM.

```
 formsweb.cfg                              frmweb processes after WLS_FORMS start
 [default]  prestartRuntimes=true   ==>    5 x webfile=HTTP-0,default
            prestartInit=5                 5 x webfile=HTTP-0,sepwin
 [sepwin]   (inherits)                     5 x webfile=HTTP-0,debug
 [debug]    (inherits)                     ... 10 sections x 5 = 50 processes
 ...
 ----------------------------------------------------------------------------
 [default]  (no prestart)          ==>    5 x webfile=HTTP-0,webstart
 [webstart] prestartRuntimes=true
            prestartInit=5
```

- Oracle: "It is recommended not setting the parameter in the [default]
  section. Doing so will result in processes being started for all other
  configurations" (**documented**).
- Before 2026-10-19 our template did exactly that: **50 `frmweb`** on the
  test host, 14 h old, no user, ~16 MB RSS each; the log confirms one pool
  per section – `FRM-93412 There are 5 prestarted runtime processes in the
  runtime process pool for configuration section [default]`, `FRM-93424
  removing the prestarted runtime processes …` at shutdown (both
  `[NOTIFICATION]`, **confirmed (live)**). With `FORMS_PRESTART_SECTION=webstart`:
  5 processes (**confirmed (live)**).
- A pooled runtime "is removed from the prestart pool once client
  connection is made" (**documented**). A pooled process has no DB
  connection and no CPU time yet – `06-FormsDiag/forms_perf_analyse.sh`
  uses that to separate pool from sessions (**assumption**, not yet tested
  with a real client session).

## 4. Timeout chain

| Parameter | Where | Unit / default | Meaning |
|---|---|---|---|
| `heartBeat` | formsweb.cfg (section) | minutes, 2 | client sends "still running" (fractions allowed, 0.5 = 30 s) |
| `FORMS_TIMEOUT` | envFile (default.env) | minutes, 15 (3–1440) | `frmweb` terminated after this time without client contact |
| `session-timeout` | `formsapp.ear` `WEB-INF/weblogic.xml` `timeout-secs` | 7200 s = 120 min (**confirmed (live)**) | WLS HTTP session of the servlet |
| `idleTimeout` | formsweb.cfg | seconds, empty | only fires `SYSTEM_CLIENT_IDLE` in the application, ends nothing |

Rules (**documented**): `FORMS_TIMEOUT` must be greater than `heartBeat`,
otherwise the runtime is terminated and "the user session becoming
unresponsive"; if `heartBeat` is higher than `session-timeout`, the
`session-timeout` wins. Too low a `heartBeat` "will cause a significant
increase in network traffic". A load balancer / proxy idle timeout must be
longer than `heartBeat` – the heartbeat is the only traffic of an idle user
(**assumption** from the mechanism).

There is no `heartbeatInterval` and no `maxEventBunchSize` in the 14.1.2
parameter list – older notes (including our first 06 scripts) used these
names.

## 5. Memory and limits

- "Oracle Forms Services maps the shared components into physical memory,
  and then shares them between all processes accessing the same FMX file"
  – only the data part grows per session (**documented**, Minimizing Forms
  Services Resource Requirements). RSS per process therefore overstates the
  real cost; measure with real users.
- `maxRuntimeProcesses` (global, `[default]`): "A value of 0 (the default)
  indicates that there is no explicit limit. This default is not
  recommended, because it leaves the system vulnerable to Denial of Service
  attacks" (**documented**). Size: (RAM available for Forms) / (RSS of a real
  session under load).
- `allowNewConnections=FALSE` blocks new sessions (maintenance), read on
  every request (**documented**).

## 6. Logs, traces, monitoring

| What | Where |
|---|---|
| Servlet / listener / pool messages (ODL) | `servers/WLS_FORMS/logs/WLS_FORMS-diagnostic.log`, `formsapp-diagnostic.log` – judge by level: `FRM-934xx` are `[NOTIFICATION]` (pool), `FRM-93654 Runtime process … is terminating due to external action` is `[ERROR]` (process killed, e.g. by a stop) (**confirmed (live)**) |
| HTTP | `servers/WLS_FORMS/logs/access.log`, fields `date time cs-method ctx-ecid ctx-rid cs-uri sc-status bytes` – **no time-taken**, response times need the extended log format (**confirmed (live)**) |
| frmweb crash dumps, `record=forms` traces | `FORMS_TRACE_DIR`, Oracle default `$DOMAIN_HOME/system_component/FORMS/<instance>/trace` (**documented**; not present on the test host = no crash yet) |
| Forms Trace (events of a session) | `ftrace.cfg` of the instance, Tracing and Diagnostics chapter |
| Sessions, metrics, kill a session | Fusion Middleware Control → Forms → User Sessions; Forms Diagnostics Agent `formsagentapp.war` (`$ORACLE_HOME/forms/j2ee/`, not deployed by us) |

Collected by `03-Logs/log_locations.sh` (group `forms`).

## 7. Where the scripts check this

| Script | Section |
|---|---|
| `06-FormsDiag/forms_settings.sh` | 1, 2 (files, binaries, FORMS_PATH, default.env, sections) |
| `06-FormsDiag/forms_perf_settings.sh` | 3, 4, 5 (prestart incl. inheritance, timeout chain, limits; `--apply --fix-prestart`) |
| `06-FormsDiag/forms_perf_analyse.sh` | 3, 5, 6 (processes per section, pool vs. session, memory, access.log, logs, dumps) |
| `09-Install/14-oracle_setup_forms.sh` | 2, 3 (`FORMS_PRESTART_SECTION`) |
| `02-Checks/weblogic_performance.sh` | WLS_FORMS heap (servlet side only) |
| `02-Checks/tns_admin_check.sh` | 2.1 (`TNS_ADMIN` in `default.env` and of every running `frmweb`) |

## 8. History – how client and runtime talk, 1979 to 2024

**The protocol in two sentences:** Since Forms 6i, a thin Java client that
only draws and contains no application logic keeps one persistent session
with one native runtime process per user, which runs the compiled form
(FMX, PL/SQL, triggers) against the database. Both exchange only compact
structured messages – the runtime sends name-value pairs telling the client
what to display (only the differences to the previous state), and the client
sends back the user's events, bundled per navigation; since 6i Patch 4
these messages travel over HTTP(S) through the Listener servlet instead of
a direct socket.

On the wire today: the Java client wraps these messages in HTTPS requests to
the Listener servlet – the TLS part is done by the client's Java (JSSE), the
server side of TLS by Nginx (OpenSSL); behind Nginx the messages travel
without TLS (section 1.1).

A common belief: "there is CORBA in the Forms backend". There is not –
CORBA is the **Reports** server ↔ engine protocol
([report_engine_architecture.md](report_engine_architecture.md)). Forms
has always had its own protocol: the runtime sends **structured messages**
("what the client needs to display"), the client sends back what the user
did. Oracle 2001: "The Forms Server Runtime process uses a persistent
connection to the client to send information in the form of structured
messages about the running application" (**documented**, 6i Patch 5 white
paper); Oracle 2024: "Oracle Forms Services communicates with the Java
client using metadata messages … a collection of name-value pairs"
(**documented**, 14.1.2). Same idea, 25 years apart.

```
 ~1999  Forms 6i "Forms Server" (three-tier, LAN)
   browser + Java applet  --- socket / http / https (connectMode) --->  Forms Listener (f60srvm,
   (thin client, renders                                               own port, e.g. 9001)
    only, no logic)                                                       | hands the connection over
                          <=========== persistent connection ==========> f60webm (runtime, per user)
                                                                          executes the FMX, PL/SQL
                                                                          -> SQL*Net -> database

 2001   Forms 6i Patch 4/5: Forms Listener Servlet (Java, in the web server)
   applet --- HTTP(S) request/response ---> web server + servlet ---> f60webm
                                           (only port 80/443 at the firewall)

 2026   Forms 14.1.2
   JWS / FSAL client --- HTTPS ---> Nginx/OHS ---> WLS_FORMS lservlet ---> frmweb (per session)
                                                    (Java EE)          TCP to the frmweb's own
                                                                       listen port (section 1)
```

What changed, what did not:

| Layer | 1999 | 2026 |
|---|---|---|
| Client | Java applet in the browser (JInitiator / plugin) | Java Web Start or Standalone Launcher; applet desupported (`separateFrame` kept "for backward compatibility only", **documented**) |
| Transport | direct socket, later HTTP/HTTPS tunnelled by the listener; message encryption RC4 40-bit for socket/HTTP modes (**documented**, 6i guide) | HTTPS only, through the Listener servlet; TLS = Java JSSE on the client, OpenSSL in Nginx (section 1.1) |
| Broker | Forms Listener process (`f60srvm`) | Listener servlet in WebLogic |
| Runtime | `f60webm` / `ifweb60`, one per user, environment from the servlet engine, later an env file | `frmweb`, one per session, environment from `envFile` (`default.env`) – the env file came with 6i Patch 5 (**documented**) |
| Application | FMX/PLX interpreted by the runtime, PL/SQL, triggers | the same – the IDE "has changed very little since" Forms 4.5 (Wikipedia) |

So the impression "Forms 6 in the backend with wrappers around it" is
fair for the **model**: one native runtime process per user that interprets
the compiled form and talks a message protocol to a thin renderer. That the
14.1.2 `frmweb` shares code with `f60webm` is an **assumption** (same role,
same name pattern, same file formats) – Oracle does not publish it.

### 8.1 Timeline

| Year | Release | What happened | Source |
|---|---|---|---|
| 1979 | IAF (Oracle V2) | character-mode forms tool – the root of Forms | Wikipedia, Kumaran |
| – | SQL*Forms 2 / 2.3 (Oracle 5), 3 (Oracle 6) | character mode; PL/SQL in triggers from version 3 | Wikipedia (no years) |
| early 1990s | Forms 4.0, 4.5 (~1994) | first GUI (Windows, X); 4.5 = IDE with object navigator and property sheets, still the same today | Wikipedia; year 1994 from a secondary source |
| late 1990s | Forms 6 (Oracle 8.0), 6i (Oracle 8i) | **Forms Server**: Java applet + Forms Listener + runtime per user, connect modes socket/http/https | Wikipedia; Forms Server 6i guide |
| before April 2001 | 6i Patch 4 / 5 | **Forms Listener Servlet**, only port 80/443 at the firewall, env file for the runtime | 6i Patch 5 white paper (April 2001) |
| 2002 | Forms 9i (9.0.2) | web deployment only – client/server and character mode removed; version number aligned with the database | Upgrade Reference (December 2002), Wikipedia |
| – | Forms 10g (9.0.4), 10gR2 (10.1.2) | rebadged 9i / Java plugin applet | Wikipedia, MOS 166640.1 |
| 2011 | Forms 11g (11.1.1 / 11.1.2) | on WebLogic, external events, JavaScript integration | Kumaran (year), Wikipedia |
| October 2015 | Forms 12c (12.2.1) | Java Web Start, later the Standalone Launcher – no browser plugin needed | Kumaran, Wikipedia |
| 2023 | 12.2.1.19 | last 12c release line | Kumaran |
| 20 December 2024 | Forms 14.1.2 | no 13; REST data sources, modernised widgets; Premier Support until December 2029, Extended until December 2032 | Wikipedia (citing the Oracle Forms announcement) |

How long the core has been in production: the GUI runtime model (compiled
FMX interpreted by a runtime per user) since the early 1990s – **over 30
years**; the web split (thin client + message protocol + one runtime per
session) since Forms 6i (~1999) – **over 25 years**, with the same structured
message idea in the 2001 and the 2024 documentation. Year values marked
"secondary" are not from Oracle documents.

### 8.2 Links to the past

Oracle (still online, checked 2026-10-19, HTTP 200):

- Forms 6i documentation overview:
  https://www.oracle.com/application-development/technologies/forms/6i-forms.html
- Oracle Forms Server Release 6i: Deploying Forms Applications to the Web with iAS – contents:
  https://docs.oracle.com/cd/A97335_02/apps.102/a86202/toc.htm
- … chapter "Configuring the Forms Server" (listener `f60ctl`/`ifsrv60`, `mode=socket|http|https`, `connectMode`, RC4 message encryption):
  https://docs.oracle.com/cd/A97335_02/apps.102/a86202/chap05.htm
- Forms6i Patch 5: Forms Listener Servlet for Deployment of Forms on the Internet (white paper, April 2001 – pre-Patch-4 architecture, `f60webm`, why HTTP through firewalls):
  https://download.oracle.com/otn_hosted_doc/forms/forms/p5_listenerservlet.pdf
- Forms 6i to Oracle9i Forms Upgrade Reference (December 2002 – what was removed: character mode, client/server):
  https://www.oracle.com/technetwork/developer-tools/forms/forms-upgrade-reference-128184.pdf
- My Oracle Support Doc ID 166640.1 "The History and Methods of Running Oracle Forms Over The Web" (login required):
  https://support.oracle.com/knowledge/Middleware/166640_1.html

Secondary:

- Wikipedia "Oracle Forms" (version table, 14.1.2 release date, support dates):
  https://en.wikipedia.org/wiki/Oracle_Forms
- Kumaran Systems, "Oracle Forms Version History" (2023, vendor blog – years for 11g / 12c):
  https://kumaran.com/blogs/oracle-forms-version-history-a-timeline-and-comprehensive-guide-of-how-the-software-has-progressed/

## 9. Open points

- First real client session: **confirmed (live) 2026-10-22** with FSAL and
  an own `jlink` runtime on Linux (Xvfb) through Nginx / HTTPS – new
  `frmweb …,standaloneapp`, "Forms Session ID is WLS_FORMS.formsapp.2";
  the `frmweb` of a killed client lives until `FORMS_TIMEOUT`
  ([java_jlink_forms_env.md §4.2](java_jlink_forms_env.md#42-linux-runtime-and-a-real-forms-session--confirmed-live)).
- First session from a **Windows** client: **confirmed (live) 2026-10-23** –
  FSAL with the jlink runtime of the client distribution
  ([09-Install/docs/40-forms_client_distribution.md](../09-Install/docs/40-forms_client_distribution.md)),
  login with a TNS alias after `TNS_ADMIN` was fixed (section 2.1).
- Pool vs. session with a real client session (JWS / FSAL from Windows):
  DB connection and CPU time as criterion, EM "User Sessions" comparison
  (Oracle: "A user session starts when the frmweb process starts" – does EM
  list pooled processes as sessions? **assumption**: yes).
- RSS of a real session for the `maxRuntimeProcesses` sizing.
- `time-taken` in the WLS_FORMS access log (extended format) – then
  `forms_perf_analyse.sh` reports response times.
- `frmweb` listens on `0.0.0.0` (section 1): can it be bound to loopback?
  (root README open item "frmweb/rwserver loopback binding").

## 10. Sources

*Working with Oracle Forms 14.1.2* (all checked 2026-10-19, HTTP 200, title matches):

- Oracle Forms Services Architecture:
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/working-forms/oracle-forms-services-architecture.html
- Built-in Optimization Features of Forms Services (runtime pooling, prestart parameters, "not … in the [default] section", shared FMX memory):
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/working-forms/built-optimization-features-forms-services.html
- Web Configuration Parameters (`heartBeat`, `maxRuntimeProcesses`, `allowNewConnections`, `networkRetries`, `gzipCompressApplet`, `prestartRuntimes`):
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/working-forms/web-configuration-parameters.html
- Environment Variables (`FORMS_TIMEOUT`, `FORMS_PATH`, `FORMS_TRACE_DIR`):
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/working-forms/environment-variables.html
- Configuration Files:
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/working-forms/configuration-files.html
- Managing User Sessions:
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/working-forms/managing-user-sessions.html
- Tracing and Diagnostics:
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/working-forms/tracing-and-diagnostics.html
- Forms Diagnostics Agent:
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/working-forms/forms-diagnostics-agent.html

Java (checked 2026-10-22, HTTP 200, title matches):

- Java Secure Socket Extension (JSSE) Reference Guide (JDK 21):
  https://docs.oracle.com/en/java/javase/21/security/java-secure-socket-extension-jsse-reference-guide.html
- Oracle Security Alert Advisory – CVE-2026-91403 (JSSE, CVSS 9.1, 2026-10-21; patch document MOS CPU426):
  https://www.oracle.com/security-alerts/alert-cve-2026-91403.html
