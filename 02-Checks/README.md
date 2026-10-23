# 02-Checks – System & Environment Diagnostics

Diagnostic scripts that inspect the host, the Java runtime, the WebLogic
domain, the database connection, TLS and the Reports network discovery.
All scripts are **read-only** – only `weblogic_performance.sh --apply` and
`tns_admin_check.sh --apply` change a file (`setUserOverrides.sh`, with backup).

This README describes **what** each script checks and how to read the
result. **Why** a check exists – how the components work together – is
explained in the background documents of
[`80-FMW-Architecture/`](../80-FMW-Architecture/README.md), linked per script
("Why").

---

## 1. Overview

| Script | Purpose | Why – background |
|---|---|---|
| [`os_check.sh`](#os_checksh) | OS release, RAM/CPU/disk, ulimits, kernel parameters, SELinux + firewall, packages, hostname | [OS parameters](../09-Install/docs/00-root_set_os_parameter.md), [firewall + sshd](../09-Install/docs/00-root_set_os_parameter.md#firewall-and-ssh-hardening-01-root_os_baselinesh-sections-8--9) |
| [`java_check.sh`](#java_checksh) | `JAVA_HOME`, JDK version/vendor, JDK of every running WLS JVM **and of the Reports engines**, heap, Log4j scan | [the homes incl. both JDKs](../80-FMW-Architecture/weblogic_middleware_architecture.md#1-terms--the-four-homes), [Reports engines](../80-FMW-Architecture/report_engine_architecture.md#1-the-parts) |
| [`port_check.sh`](#port_checksh) | listen addresses/ports from `config.xml` + Node Manager, live sockets, TCP and HTTP checks | [how the parts are joined](../80-FMW-Architecture/weblogic_middleware_architecture.md#6-how-the-parts-are-joined), [who starts whom](../80-FMW-Architecture/weblogic_middleware_architecture.md#4-who-starts-whom--the-control-chain); `frmweb` listen ports – [forms_runtime_architecture.md §1](../80-FMW-Architecture/forms_runtime_architecture.md#1-the-parts) |
| [`db_connect_check.sh`](#db_connect_checksh) | 6-step DB diagnosis: DNS / ping / TCP / TNS / service / login | [who logs in where](../80-FMW-Architecture/rcu_middleware_architecture.md#3-who-logs-in-where), [password expiry](../80-FMW-Architecture/rcu_middleware_architecture.md#61-password-expiry--a-real-risk) |
| [`ssl_check.sh`](#ssl_checksh) | who terminates TLS (Nginx / WLS / OHS), live TLS analysis, certificates incl. WebLogic demo certificates, keystores | [08-SSL](../08-SSL/README.md), [which certificates are needed](../80-FMW-Architecture/forms_jakob_webutil.md#9-which-certificates-are-needed) |
| [`weblogic_performance.sh`](#weblogic_performancesh) | SecureRandom source in `java.security`, heap per server in `setUserOverrides.sh` (`--apply`) | [who starts whom](../80-FMW-Architecture/weblogic_middleware_architecture.md#4-who-starts-whom--the-control-chain) (`setDomainEnv.sh` → `setUserOverrides.sh`); WLS_FORMS heap ≠ Forms sessions – [forms_runtime_architecture.md §1](../80-FMW-Architecture/forms_runtime_architecture.md#1-the-parts) |
| [`egress_check.sh`](#egress_checksh) | what the domain sends to other hosts: external DTD/XSD URLs in the configuration, `/etc/hosts` entries for them, XML/network JVM options, live non-local connections per process, `--capture` (tcpdump: DNS + outgoing SYN/UDP, with DNS names and process) | [outbound connections, external-DTD trap](../80-FMW-Architecture/weblogic_outbound_connections.md) |
| [`tns_admin_check.sh`](#tns_admin_checksh) | one Oracle Net directory (`TNS_ADMIN` of `environment.conf`) in every place a Forms / Reports / WebLogic process or the oracle shell reads it; `--apply` writes the `setUserOverrides.sh` block | [Forms: `frmweb` reads `default.env`](../80-FMW-Architecture/forms_runtime_architecture.md#21-oracle-net--where-frmweb-finds-the-database-alias), [Reports: three places, Oracle's defaults](../80-FMW-Architecture/report_engine_architecture.md#52-oracle-net--three-places-for-one-tns_admin) |
| [`clone_check.sh`](#clone_checksh) | clone-capable / golden image: listening sockets by bind address, WebLogic listen + SSL ports + Coherence, Reports ORB, host name / IP in the domain configuration, `*.des3` secrets (disk UUID), host-specific places; `--apply` = SSL off + Coherence 127.0.0.1 (WLST online) | [clone_golden_image.md](../80-FMW-Architecture/clone_golden_image.md) |
| [`reports_network_scan.sh`](#reports_network_scansh) | Reports multicast discovery: `rwnetwork.conf`, route/firewall, send+receive self-test, active scan per port | [Reports server discovery](../80-FMW-Architecture/reports_server_discovery_multicast.md), [broadcast – why it disturbs](../80-FMW-Architecture/report_engine_architecture.md#8-server-discovery-broadcast--the-idea-and-why-it-rather-disturbs) |

All scripts source `environment.conf` and write their output to stdout and
`$DIAG_LOG_DIR/` (or `log/<date>/`). Run `00-Setup/init_env.sh` first if
`environment.conf` does not exist yet.

Related, outside this folder: `10-Monitoring/cve_inventory.sh` (installed
components, patch cycle, both JDKs, exposure, Oracle advisories) and
`08-SSL/ssl_config.sh` (Nginx TLS audit).

---

## 2. Recommended Execution Order

Run in this sequence when setting up a new server or diagnosing a problem:

```
Step 1 – OS baseline
  ./02-Checks/os_check.sh

Step 2 – Java runtime
  ./02-Checks/java_check.sh

Step 3 – Ports and network
  ./02-Checks/port_check.sh
  ./02-Checks/port_check.sh --http   # also HTTP checks against the AdminServer

Step 4 – Database connectivity
  ./02-Checks/tns_admin_check.sh            # one TNS_ADMIN everywhere (files + processes)
  ./02-Checks/db_connect_check.sh --new     # first time: configure + save credentials
  ./02-Checks/db_connect_check.sh           # check existing config (DNS/TCP/TNS/Service)
  ./02-Checks/db_connect_check.sh --login   # full check including login test

Step 5 – SSL / TLS
  ./02-Checks/ssl_check.sh
  ./02-Checks/ssl_check.sh --warn-days 60   # warn earlier on cert expiry

Step 6 – WebLogic performance settings
  ./02-Checks/weblogic_performance.sh          # check current state
  ./02-Checks/weblogic_performance.sh --apply  # set heap per server (in place)

Step 7 – Reports server discovery (Reports installations)
  ./02-Checks/reports_network_scan.sh
```

---

## 3. Script Reference

### os_check.sh

```bash
./02-Checks/os_check.sh
```

Read-only – no options. **Why:** the OS settings FMW needs and why –
[`09-Install/docs/00-root_set_os_parameter.md`](../09-Install/docs/00-root_set_os_parameter.md);
sizing of ulimits / sysctl by expected sessions:
`09-Install/01-setup-interview.sh` (`EXPECTED_SESSIONS`).

| Section | What is checked |
|---|---|
| 1 – OS Version & Kernel | Oracle Linux / RHEL release, kernel, architecture (x86_64), `CV_ASSUME_DISTID` (required on OL9 for OUI), `LANG`/`LC_ALL` (`en_US.UTF-8`), `umask` 022 (Oracle software owner default; 027 = INFO) |
| 2 – System Resources | RAM total/available (FMW minimums: OS 8 GB / DEV-QS 16 GB / PRD 64 GB), swap (>= 2 GB recommended), CPU cores + model, free space on `$ORACLE_HOME`, `$DOMAIN_HOME`, `/tmp`, `/var/log` |
| 3 – ulimits | `nofile`, `nproc`, `stack`, `core` (session) + configured limits in `/etc/security/limits.conf` / `limits.d/` for the oracle user |
| 4 – Kernel Parameters | `fs.file-max`, `fs.aio-max-nr`, `kernel.sem`, `kernel.shmmni`, `kernel.shmall`, `kernel.shmmax`, `net.core.rmem_*`, `net.core.wmem_*`, `net.ipv4.ip_local_port_range` |
| 5 – SELinux & Firewall | SELinux runtime + persistent mode; `firewalld` state via `systemctl` (works as oracle – `firewall-cmd --state` needs root and used to report a running firewall as "not running", fixed 2026-10-19). Firewall active = OK, not active = **WARN** (all `frmweb` / `rwserver` / engine sockets reachable past Nginx); safe activation: `09-Install/01-root_os_baseline.sh --apply --skip-update --only firewall` |
| 6 – Required OS Packages | via `rpm -q`: **critical** (`glibc`, `libXext`, `libXrender`, `motif`, `gcc`, …), **compatibility** libs, **Reports printing** (`cups`, `cups-libs`), **diagnostic tools** (`strace`, `lsof`, `sysstat`, `xorg-x11-server-Xvfb`, `fonttools`) |
| 7 – Hostname & Network | FQDN resolvable and different from the short name, hostname not on loopback, `/etc/hosts` entries |

Exit code 0 = all OK, 1 = warnings, 2 = at least one FAIL.

> **umask (decided 2026-10-19):** 022 – the Oracle default for the software
> owner, as written by `09-Install/03-root_user_oracle.sh`. The check used to
> demand 027 without an Oracle source. Files with passwords are protected
> explicitly (600 / 640), not via the umask.

---

### java_check.sh

```bash
./02-Checks/java_check.sh
```

Read-only – no options. **Why:** an FMW host has **two JDKs** – the
standalone Oracle JDK (`JDK_HOME`) for WebLogic and the Node Manager, and
the FMW-bundled `$ORACLE_HOME/oracle_common/jdk`, which the Reports engines
use – see
[the homes](../80-FMW-Architecture/weblogic_middleware_architecture.md#1-terms--the-four-homes)
and [Reports engines](../80-FMW-Architecture/report_engine_architecture.md#1-the-parts).

| Section | What is checked |
|---|---|
| `JAVA_HOME` | set, standalone Oracle JDK (expected for 14.1.2) or FMW-bundled; `java` in `PATH` = `JAVA_HOME` |
| Java version & vendor | major release rating (21 = certified for 14.1.2), Oracle JDK vs. OpenJDK (Oracle Support asks for the vendor) |
| Running WLS JVMs | per server (`-Dweblogic.Name`): java binary = `JAVA_HOME`?, runtime `-Xms` / `-Xmx` / GC |
| Reports engines | every running engine (`rwrun.jar`): java binary + version – **WARN** if it is not the `JAVA_HOME` JDK (`reports.sh` puts `oracle_common/jdk` first in `PATH`; `JDK_HOME` updates do not reach the engines) |
| Heap | rates the **runtime** `-Xmx` of each running server; without running servers the values in `setUserOverrides.sh`. Oracle's defaults in `setDomainEnv.sh` (`-Xmx512m`) are not rated – they are overridden |
| Log4j scan | all `log4j*.jar` under `$ORACLE_HOME` / `$DOMAIN_HOME`; version from `MANIFEST.MF` / `pom.properties`, file name only as fallback |

Log4j classification:

| Version | Result |
|---|---|
| ≥ 2.17.1 | OK – patched |
| 2.x < 2.17.1 | FAIL – CVE-2021-44228 / -45046 / -45105 / -44832 |
| 1.x | FAIL – EOL, CVE-2019-17571, no fix |

- `log4j-1.2-api-2.x.jar` is the **Log4j 2 bridge** for the 1.2 API (version
  2.x), not log4j 1.x – rated by its real version (until 2026-10-19 the file
  name made it a false FAIL).
- FMW "features" jars (`oracle_common/modules/thirdparty/features/log4j-*.jar`)
  contain no classes, only a `Class-Path` to the real jar – listed as INFO,
  the real jar is rated.

---

### port_check.sh

```bash
./02-Checks/port_check.sh
./02-Checks/port_check.sh --http
./02-Checks/port_check.sh --timeout 5
```

| Option | Description |
|---|---|
| `--http` | also HTTP checks against the AdminServer (`/console`, `/weblogic/ready`) |
| `--timeout N` | TCP connect timeout in seconds (default 3) |

**Why:** which component listens where and who talks to whom –
[how the parts are joined](../80-FMW-Architecture/weblogic_middleware_architecture.md#6-how-the-parts-are-joined).

Sections:

1. **Network interfaces** – IPv4 addresses (`ip addr`).
2. **Configured ports** – `<server>` blocks of `$DOMAIN_HOME/config/config.xml`
   with `<listen-address>`, `<listen-port>` and SSL port; fallback
   `WL_ADMIN_URL`.
3. **Node Manager** – `ListenPort` / `ListenAddress` from
   `nodemanager.properties` (default 5556 / localhost).
4. **Listening TCP sockets** – `ss -tlnp`; Java / WebLogic / Node Manager
   rows highlighted. Process names only for own processes (run as root to
   see all).
5. **Cross-check** – per configured port: `ss` state (LISTEN / DOWN) and a
   TCP connect (`bash /dev/tcp`, no `nc` / `nmap` needed).
6. **HTTP** (`--http`) – `/console` (14.1.2: redirect to the console welcome
   page, HTTP 302 = OK) and `/weblogic/ready` (200 = server RUNNING). The
   old `/bea_wls_internal/versionInfo.jsp` no longer exists in 14.1.2
   (replaced 2026-10-19).

Ports of the domain in this project (`environment.conf`):

| Component | Port | Bound to | Note |
|---|---|---|---|
| AdminServer | 7001 | 127.0.0.1 | via Nginx `/em`, `/console` |
| WLS_FORMS | 9001 | 127.0.0.1 | via Nginx `/forms` |
| WLS_REPORTS | 9002 | 127.0.0.1 | via Nginx `/reports` |
| WLS_FORMS / WLS_REPORTS SSL | 9501 / 9512 | 127.0.0.1 | enabled by the domain templates with the **WebLogic demo certificate** – not needed (TLS ends at Nginx), see `ssl_check.sh` |
| Node Manager | 5556 | 127.0.0.1 | plain |
| Nginx | 80 / 443 | all interfaces | the only entry from outside (firewall) |
| Reports discovery | 14027/udp | multicast | `REPORTS_BROADCAST_PORT` |

---

### db_connect_check.sh

```bash
./02-Checks/db_connect_check.sh               # check existing config
./02-Checks/db_connect_check.sh --new         # configure a connection (interactive)
./02-Checks/db_connect_check.sh --login       # include the login test
./02-Checks/db_connect_check.sh --login --sqlplus=/path/to/sqlplus
```

**Why:** which schema logs in from where (data sources, OPSS bootstrap,
Reports / Forms application users) –
[who logs in where](../80-FMW-Architecture/rcu_middleware_architecture.md#3-who-logs-in-where);
locked / expired accounts after 180 days –
[password expiry](../80-FMW-Architecture/rcu_middleware_architecture.md#61-password-expiry--a-real-risk).

Connection parameters from `environment.conf` (`DB_HOST`, `DB_PORT`,
`DB_SERVICE`), fallback `jps-config.xml`. `--new` asks for host, port,
service, user and password, writes the parameters to `environment.conf`
and the credentials encrypted to `db_connect.conf.des3` (same openssl des3
concept as `weblogic_sec.conf.des3`).

Steps (sequential – stops at the first FAIL):

| Step | What | Tool | On failure |
|---|---|---|---|
| 1 | DNS resolution | `getent hosts` | FAIL – host name wrong or DNS unreachable |
| 2 | ICMP ping | `ping -c3 -W2` | WARN only – ICMP is often blocked |
| 3 | TCP port open | `bash /dev/tcp` / `nc` | FAIL – firewall or listener down |
| 4 | Oracle TNS listener? | `tnsping` or a Python3 TNS packet | WARN – port open but not Oracle |
| 5 | Service / SID exists? | Python3 TNS `CONNECT_DATA` | ORA code → targeted hint |
| 6 | Login (`--login`) | `sqlplus` / `sql` Easy Connect | ORA code → cause |

Step 5 works without an Oracle client: a minimal TNS CONNECT packet is sent
via Python3 sockets, the listener answers with a REFUSE packet containing
the ORA error as text.

| ORA in REFUSE | Meaning |
|---|---|
| no error / REDIRECT | service registered with the listener |
| `ORA-12514` | listener running – service not registered |
| `ORA-12505` | listener running – SID not found |
| `ORA-12519` | service found – all handlers busy |

Step 6 needs `SQLPLUS_BIN` in `environment.conf` or `--sqlplus=` (Instant
Client `sqlplus` or SQLcl `sql`); Easy Connect `//host:port/service`.

| ORA after login | Meaning |
|---|---|
| none | login successful |
| `ORA-01017` | wrong user name or password |
| `ORA-28000` | account locked |
| `ORA-28001` | password expired → [profile `RCU_USER`](../60-RCU-DB-19c/docs/07b-db_rcu_profile.md) |

---

### ssl_check.sh

```bash
./02-Checks/ssl_check.sh                    # auto-detect architecture
./02-Checks/ssl_check.sh --warn-days 60     # warn earlier on cert expiry
./02-Checks/ssl_check.sh --host 10.0.1.5    # external host for the TLS checks
./02-Checks/ssl_check.sh --no-curl          # skip the HTTP endpoint checks
```

**Why:** in this setup TLS ends at Nginx, WebLogic listens on localhost
only ([08-SSL](../08-SSL/README.md)); which certificates a Forms/Reports
installation needs and who checks them –
[certificates](../80-FMW-Architecture/forms_jakob_webutil.md#9-which-certificates-are-needed).

Detects the TLS architecture first:

| Port 443 owner | Mode | Certificate |
|---|---|---|
| `nginx` | Nginx TLS proxy | `ssl_certificate` file of the Nginx config |
| `java` (WLS) | WLS direct SSL | WLS keystore (JKS / PKCS12) |
| `httpd` | OHS proxy | OHS `ssl.conf` |
| nothing | no HTTPS on 443 | WLS SSL ports checked directly |

| Section | What |
|---|---|
| 1 – Voraussetzungen | `openssl` / `curl` / `keytool` available |
| 2 – Architektur | who owns port 443 |
| 3 – WLS `config.xml` | SSL enabled per server, listen ports, keystore type – demo keystore → FAIL |
| 4 – Nginx config | `ssl_certificate` (read via `sudo -n` when `/etc/nginx/ssl` is 700 root, otherwise INFO and checked via live TLS), `ssl_protocols`, `ssl_ciphers`, `proxy_pass` targets incl. **upstream names** resolved to their port |
| 5 – Live TLS | protocol, cipher, forward secrecy (TLS 1.3 always (EC)DHE), TLS 1.0 / 1.1 still accepted?, certificate of Nginx and of every WLS SSL port |
| 6 – HTTP endpoints | `curl` on `/em`, `/console` (HTTP and HTTPS) |
| 7 – Keystore files | `keytool -list` on `.jks` / `.p12` under `$DOMAIN_HOME` |

Ratings: TLS 1.3 / 1.2 OK, TLS 1.1 WARN (RFC 8996), TLS 1.0 / SSLv3 FAIL.
Certificates: subject / issuer / SAN, expiry (FAIL expired, WARN within
`--warn-days`, default 30), self-signed WARN, **WebLogic demo certificate**
(`CertGenCA`, `DemoCertFor_<domain>`, "FOR TESTING ONLY") **FAIL** – the
private key of that CA ships with every WebLogic installation.

> Found 2026-10-19 on the test host: the SSL listen ports 9501 (WLS_FORMS)
> and 9512 (WLS_REPORTS) are enabled with the demo certificate (bound to
> 127.0.0.1, behind the firewall). Not needed – TLS ends at Nginx. Open:
> disable them in the domain setup (`09-Install/08-`) or use an own
> certificate; candidate for the config security scanner
> (`10-Monitoring/README.md`).

Fixed 2026-10-19 (were false findings): certificate file in the 700 root
directory reported as "not found", `proxy_pass http://<upstream>` reported
as "not listening", TLS 1.3 reported without forward secrecy, live
certificates with 4096-bit keys "not readable" (PEM cut after 30 lines).

---

### weblogic_performance.sh

```bash
./02-Checks/weblogic_performance.sh            # check
./02-Checks/weblogic_performance.sh --apply    # set heap per server (backup first)
```

**Why:** `setDomainEnv.sh` (rewritten by Oracle on updateDomain / patches)
sources `setUserOverrides.sh` – the place for own JVM settings per server –
[who starts whom](../80-FMW-Architecture/weblogic_middleware_architecture.md#4-who-starts-whom--the-control-chain).

#### Section 1 – `java.security`: SecureRandom source

`java.security` of `JAVA_HOME` (`jre/lib/security` on JDK 8,
`conf/security` on JDK 11+), setting `securerandom.source`:

| Value | Rating |
|---|---|
| `file:/dev/random` | **FAIL** – blocking entropy source, slows the WLS start |
| `file:/dev/./urandom` | OK – non-blocking (recommended) |
| `file:/dev/./random` | OK – non-blocking via the `./` trick |
| `file:/dev/urandom` | OK on JDK 17+ / newer JDK 8 builds |
| (not set) | WARN – compile-time default applies |

The JVM treats the literal `file:/dev/random` as a blocking source; on a
freshly booted VM this can stall the WebLogic start for 30 s to minutes.
`file:/dev/./urandom` points to the same device but does not match that
string. `--apply`: `backup_file()` + `sed`; effective at the next JVM start.
The JDK of the Reports engines (`oracle_common/jdk`) is a separate
`java.security` – see `java_check.sh`.

#### Section 2 – `setUserOverrides.sh`: heap per server

Reads `USER_MEM_ARGS` per `if [ "${SERVER_NAME}" = "<name>" ]` block:

| Check | Rating |
|---|---|
| file exists | WARN if missing |
| block for `AdminServer` / `WLS_FORMS` / `WLS_REPORTS` | WARN if absent |
| `LOG4J_FORMAT_MSG_NO_LOOKUPS=true` | WARN if absent (CVE-2021-44228) |
| `-Dforms.userid.encryption.enabled=true` | INFO if absent |

Typical values:

| Server | `-Xms` | `-Xmx` | Additional |
|---|---|---|---|
| AdminServer | 1024m | 1536m | `-XX:MaxMetaspaceSize=2G` |
| WLS_FORMS | 2g | 2g | `-XX:NewSize=1g` |
| WLS_REPORTS | 2g | 2g | `-XX:NewSize=1g` |

`--apply` asks for the three values and **updates the file in place**: the
`USER_MEM_ARGS` line inside an existing server block is replaced, a missing
block is appended, the Log4j guard is added only if missing. Everything
else stays – the file also holds the Reports font settings
(`14b-oracle_reports_fonts.sh`) and the rwservlet ORB timeout
(`13-oracle_setup_reports.sh`). Until 2026-10-19 `--apply` rewrote the
whole file and dropped them; the server-name parser also read every block
as "not set". Restart the servers afterwards.

---

### reports_network_scan.sh

```bash
./02-Checks/reports_network_scan.sh                         # full check + scan 14021-14030
./02-Checks/reports_network_scan.sh --ports 14021-14040 --timeout 5
./02-Checks/reports_network_scan.sh --listen 20             # longer passive listen (default 10 s)
./02-Checks/reports_network_scan.sh --port 14027 --no-scan  # used by 13-oracle_setup_reports.sh
```

**Why:** the standalone Reports server must find itself (and is found) via
multicast, otherwise it stops with `REP-50600` –
[Reports server discovery](../80-FMW-Architecture/reports_server_discovery_multicast.md),
[prerequisites on the host](../80-FMW-Architecture/reports_server_discovery_multicast.md#5-prerequisites-on-the-host).

| Step | What |
|---|---|
| 1 | channel / port of all `rwnetwork.conf` (ReportsTools instance, every Reports server, `WLS_REPORTS` application) – must be equal |
| 2 | route to the multicast group (not `lo`), `MULTICAST` flag, IPv6 on that interface, firewall `<port>/udp` (via `sudo -n` when firewalld is active) |
| 3 | self-test: one UDP datagram to `channel:port`, must be received again on this host – what the Reports server needs at start (else `REP-50600`). Skipped while a Reports server runs (it would log `REP-50125 StreamCorruptedException`). Passive listen for foreign senders (`--listen`) |
| 4 | active scan: Oracle's `DiagServerLocator -findAll` (behind `rwdiag.sh`) per port of the range, with a temporary `COMPONENT_CONFIG_PATH` – nothing is written to the domain. WARN if a foreign host uses the own port, FAIL if an own server name runs on another host (`REP-56040`) |

- Runs in a subshell that sources `$DOMAIN_HOME/reports/bin/reports.sh`
  (`DiagServerLocator` needs that environment).
- About 4 s per port; only **running** servers answer.

### egress_check.sh

```bash
./02-Checks/egress_check.sh                    # static + live, read-only
./02-Checks/egress_check.sh --capture 300      # + capture; restart a server meanwhile
./02-Checks/egress_check.sh --capture 120 --if ens160
```

**Why:** the domain needs no internet at run time – but an XML parser that
downloads a DTD from `http://java.sun.com/dtd/…` blocks a server start
forever behind a firewall that accepts the connection and never answers
([outbound connections, external-DTD trap](../80-FMW-Architecture/weblogic_outbound_connections.md)).

| Section | What |
|---|---|
| 1 | `DOCTYPE` with an http(s) DTD in `$DOMAIN_HOME/config` per URL and file; `properties.dtd` = OK (JDK built-in via `Properties.loadFromXML`), others WARN; count of http(s) XSDs in `schemaLocation` (INFO) |
| 2 | `/etc/hosts` entry for each DTD host (fast failure) or resolved via DNS |
| 3 | `-Djavax.xml.accessExternal*`, `-Djdk.xml.*`, `sun.net.client` timeouts, proxy options of every WLS / Reports engine JVM |
| 4 | established connections to non-local hosts: domain processes (WLS, Reports, `frmweb`) WARN, other processes INFO |
| 5 | `--capture N`: `sudo tcpdump` on the default-route interface – DNS lookups, outgoing SYN/UDP to non-local networks (destination filter only), names from the DNS answers, process from an `ss` poll; pcap in `log/<date>/egress_<time>.pcap` (600) |

Live 2026-10-20: full domain restart – nothing left the host; a test
parser fetching `java.sun.com` was shown with name and destination.
Short connections are often not seen by the `ss` poll – then the DNS name
and the time stamp point to the process; OS timers (`dnf-makecache`) show up
too (`journalctl`).

### tns_admin_check.sh

```bash
./02-Checks/tns_admin_check.sh            # read-only: every place + running processes
./02-Checks/tns_admin_check.sh --apply    # write the setUserOverrides.sh block (backup)
```

`TNS_ADMIN` is set **once** in `environment.conf` (interview block 1,
default `$ORACLE_BASE/admin/tns_names`) – `tnsnames.ora` and `sqlnet.ora`
of the company go there. Without it every component used Oracle's default
(`$DOMAIN_HOME/config/fmwconfig`, only a sample `tnsnames.ora`): a Forms
login with an alias failed with `ORA-12162` / `ORA-12154` (test host
2026-10-23). Where the value has to arrive – and who writes it:

| Process / reader | File | Written by | Note |
|---|---|---|---|
| Forms runtime (`frmweb`, one per session) | `default.env` (`TNS_ADMIN=`) | `09-Install/14-oracle_setup_forms.sh` (`##TNS_ADMIN##`) | read at every new session – no restart |
| Reports engines | `rwserver.conf` `<environment id="QS">` `<envVariable name="TNS_ADMIN">` | `09-Install/13-oracle_setup_reports.sh` | Reports server restart |
| Reports server process, `rwrun`, `rwconverter` | `$DOMAIN_HOME/reports/bin/reports.sh` | `13-` (IHW block, after Oracle's "set if empty" default) | Reports server restart |
| WebLogic JVMs (`WLS_FORMS`, `WLS_REPORTS`, AdminServer: JDBC alias resolution) | `setUserOverrides.sh` – `export TNS_ADMIN` + `-Doracle.net.tns_admin` | this script `--apply` (also called by `09-oracle_configure.sh`) | sourced **after** Oracle's `setStartupEnv.sh`, which sets `$DOMAIN_HOME/config/fmwconfig` for the Reports group; server restart |
| oracle shell (`sqlplus`, tools by hand) | `~oracle/.bash_profile` | `09-Install/03-root_user_oracle.sh` (root) | new login |
| Smoke test / `rwrun_trace.sh` | copy the aliases of `$TNS_ADMIN/tnsnames.ora` into a temporary directory | `15-`, `01-Run/rwrun_trace.sh` | – |

Live 2026-10-23 (**confirmed**): after setting the files the check showed
the old value for every running process (8 OK / 4 WARN); after
`startStop.sh stop-all` / `start-all` all 12 checks OK – files **and**
`frmweb`, `rwserver`, `WLS_FORMS`, `WLS_REPORTS`.

Checks: the directory (aliases in `tnsnames.ora`, `NAMES.DIRECTORY_PATH`
of `sqlnet.ora`), every file of the table, and – the real proof – the
environment of the running processes (`/proc/<pid>/environ` of `frmweb`,
`rwserver`, `WLS_FORMS`, `WLS_REPORTS`). A WARN names the script that owns
the file. Diagnosis scripts that compare one place on their own:
`06-FormsDiag/forms_settings.sh` (default.env),
`05-ReportsPerformance/engine_perf_settings.sh` (rwserver.conf).

---

### clone_check.sh

```bash
./02-Checks/clone_check.sh            # read-only
./02-Checks/clone_check.sh --apply    # SSL listen ports off + Coherence 127.0.0.1 (WLST online)
```

Can this installation be cloned (golden image) or moved? Target: everything
internal on `127.0.0.1`, only Nginx and the certificate carry the host name
([clone_golden_image.md](../80-FMW-Architecture/clone_golden_image.md)).

| Section | WARN (fix before the image) | INFO (by design / after the clone) |
|---|---|---|
| listening sockets (`ss`) of WebLogic, NM, `rwserver`, engines, `frmweb` | java socket on all interfaces / host IP | `frmweb` (not configurable), Coherence remainder on the host IP, multicast discovery |
| WebLogic `config.xml`, `nodemanager.properties` | listen address not loopback, SSL listen port on, Coherence unicast not 127.0.0.1 | – |
| Reports | `reports.sh` / `setUserOverrides.sh` without `ORBServerHost=127.0.0.1` → `13- --apply` | broadcast port to change after a clone |
| host name / IP in `$DOMAIN_HOME/config` | unknown file | JDBC / OPSS (DB host), `tokenValue.properties`, `uifont.ali` comment |
| RCU repository | – | on this host = cloned along (OK); **external** = own prefix per clone ([§5](../80-FMW-Architecture/clone_golden_image.md#5-the-rcu-repository--where-it-lives-decides)) |
| machine identity | – | `*.des3` secrets (disk UUID) to re-enter |
| host-specific places | – | `WLS_SERVER_FQDN`, `FORMS_CLIENT_BASE_URL`, Nginx certificate, `tnsnames.ora` |

Result line "Clone-capable: yes / not yet" with the number of items. `--apply`
loads the WebLogic password (`load_weblogic_password`, passed to WLST via the
environment), backs up `config.xml` and changes WLS_FORMS / WLS_REPORTS
online; then stop both servers and start them again. Live 2026-10-23: from 4
items (SSL ×2, Coherence ×2) plus ORB on all interfaces to "yes" with 14
post-clone steps.

---

## 4. Troubleshooting

### os_check.sh – ulimit warnings

```
Symptom: WARN nofile=1024 – recommended >= 65536
Cause:   OS default limits too low for WebLogic / Forms sessions
Fix:     09-Install/01-root_os_baseline.sh / 03-root_user_oracle.sh --apply
         (values sized by EXPECTED_SESSIONS), or /etc/security/limits.d/:
           oracle  soft  nofile  65536
           oracle  hard  nofile  65536
           oracle  soft  nproc   16384
           oracle  hard  nproc   16384
         Then log in again and re-run os_check.sh.
```

### java_check.sh – wrong JDK detected

```
Symptom: WARN PATH java differs from JAVA_HOME java
Cause:   /etc/profile.d/ or .bashrc puts another java first in PATH
Fix:     JAVA_HOME / JDK_HOME in environment.conf point to the symlink
           JDK_HOME=/u01/app/oracle/java/jdk-21
         (repointed at every JDK update, see 09-Install/docs/01-root_setup_java.md)
```

### java_check.sh – Reports engines on another JDK

```
Symptom: WARN PID <n> .../oracle_common/jdk/bin/java (17.0.12 ...) – NOT the JAVA_HOME JDK
Cause:   $DOMAIN_HOME/reports/bin/reports.sh puts oracle_common/jdk first in PATH
Fix:     open – supported way to update the bundled JDK / point the engines
         to JDK_HOME is being clarified (README "Open Items")
```

### java_check.sh – Log4j FAIL

```
Symptom: FAIL log4j-core-2.14.1.jar – VULNERABLE (Log4Shell family)
Cause:   old log4j bundled with WLS or an application
Fix:     apply the current Oracle patches (09-Install/docs/00-patch-references.md);
         Log4j: https://logging.apache.org/log4j/2.x/security.html,
         MOS Note 2827793.1; minimum safe version log4j-core 2.17.1
```

### port_check.sh – all ports show CLOSED

```
Symptom: all WLS ports CLOSED in the cross-check
Cause A: domain not started
         → ./01-Run/startStop.sh start-all --apply
Cause B: WL_ADMIN_URL in environment.conf has the wrong host/port
         → re-run 00-Setup/init_env.sh
Cause C: the check runs from another host – WLS listens on 127.0.0.1 only
         and the firewall lets only ssh / 80 / 443 through (by design);
         check on the server itself, from outside only via Nginx
         (never open 7001/9001/9002/5556 in the firewall)
```

### port_check.sh – process names missing in ss output

```
Symptom: ss -tlnp shows no process name
Cause:   ss shows process info only for own processes
Fix:     run as the oracle user that started WebLogic, or as root:
           sudo ./02-Checks/port_check.sh
```

---

## 5. Related Scripts

| Script | Purpose |
|---|---|
| `00-Setup/init_env.sh` | detect FMW / domain paths, generate `environment.conf` |
| `00-Setup/weblogic_sec.sh` | store the WebLogic admin credentials (des3) |
| `01-Run/rwrun_trace.sh` | diagnose `rwrun` crashes |
| `03-Logs/grep_logs.sh` | search the logs after a failed check |
| `08-SSL/` | certificates: local CA, deployment to Nginx, `ssl_config.sh` audit |
| `09-Install/01-root_os_baseline.sh` | fix what `os_check.sh` reports (sysctl, THP, firewall, sshd) |
| `10-Monitoring/cve_inventory.sh` | installed components vs. patch cycle and Oracle advisories, both JDKs, exposure |

---

## 6. References

All links checked 2026-10-19 (HTTP 200, title matches).

- Oracle FMW 14.1.2 System Requirements and Specifications:
  https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/sysrs/system-requirements-and-specifications.html
- Securing a Production Environment for Oracle WebLogic Server 14.1.2:
  https://docs.oracle.com/en/middleware/fusion-middleware/weblogic-server/14.1.2/lockd/index.html
- Oracle Database Installation Guide 21c for Linux (ulimits / kernel
  parameters of Oracle products):
  https://docs.oracle.com/en/database/oracle/oracle-database/21/ladbi/
- Troubleshooting Oracle Reports Services (12.2.1.3 guide, still valid for
  the architecture):
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_trouble.htm
- Log4j security (CVE-2021-44228):
  https://logging.apache.org/log4j/2.x/security.html
- My Oracle Support Note 2827793.1 (Log4j and FMW):
  https://support.oracle.com/epmos/faces/DocumentDisplay?id=2827793.1
