# 02-Checks – System & Environment Diagnostics

Diagnostic scripts that inspect the host, the Java runtime, the WebLogic
domain, and the network configuration. All scripts are **read-only** unless
marked otherwise – run them without `--apply` to get a safe status overview.

---

## 1. Overview

| Script | Status | Purpose |
|---|---|---|
| `os_check.sh` | ✅ implemented | OS, RAM, CPU, disk, ulimits, kernel params, packages |
| `java_check.sh` | ✅ implemented | JAVA_HOME, JDK version, WLS JVM settings, Log4j CVE scan |
| `port_check.sh` | ✅ implemented | Listen addresses and ports per WLS component, TCP check |
| `db_connect_check.sh` | ✅ implemented | 6-step DB diagnostics: DNS/Ping/TCP/TNS/Service/Login |
| `ssl_check.sh` | ✅ implemented | SSL architecture detection (Nginx/WLS), TLS analysis, cert expiry |
| `weblogic_performance.sh` | ✅ implemented | SecureRandom startup fix + JVM heap per server check/apply |

All implemented scripts source `environment.conf` and write output to both
stdout and `$DIAG_LOG_DIR/`. Run `00-Setup/init_env.sh` first if
`environment.conf` does not exist yet.

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
  ./02-Checks/port_check.sh --http   # also check AdminServer console via HTTP

Step 4 – Database connectivity
  ./02-Checks/db_connect_check.sh --new     # first time: configure + save credentials
  ./02-Checks/db_connect_check.sh           # check existing config (DNS/TCP/TNS/Service)
  ./02-Checks/db_connect_check.sh --login   # full check including login test

Step 5 – SSL certificates
  ./02-Checks/ssl_check.sh
  ./02-Checks/ssl_check.sh --warn-days 60   # warn earlier on cert expiry

Step 6 – WebLogic performance settings
  ./02-Checks/weblogic_performance.sh          # check current state
  ./02-Checks/weblogic_performance.sh --apply  # apply recommended settings
```

---

## 3. Script Reference

### os_check.sh

```bash
./02-Checks/os_check.sh
```

Read-only – no options needed.

Checks performed:

| Category | What is checked |
|---|---|
| OS version | Oracle Linux / RHEL release, kernel version |
| RAM | Total / available – warns if below FMW minimum |
| CPU | Core count, model name |
| Disk | Free space on `/`, `/tmp`, `$DOMAIN_HOME` filesystem |
| Ulimits | `nofile` (open files), `nproc`, `stack` per FMW recommendations |
| Kernel params | `vm.swappiness`, `net.core.somaxconn` etc. via `sysctl` |
| SELinux | Reports enforcing / permissive / disabled |
| Required packages | `glibc`, `libXext`, `libXrender`, `motif`, etc. via `rpm -q` |
| `LANG` / locale | Must be `en_US.UTF-8` for Oracle Forms/Reports |
| `umask` | Recommended `0027` during FMW operations |

Exit code 0 = all OK; non-zero = at least one FAIL detected.

---

### java_check.sh

```bash
./02-Checks/java_check.sh
```

Read-only – no options needed.

Checks performed:

| Category | What is checked |
|---|---|
| JAVA_HOME | Correct FMW JDK path (not the system JDK) |
| JDK version | Must be JDK 21.0.x for FMW 14.1.2, JDK 8 for FMW 12.2.1 |
| `java` on PATH | Whether `$JAVA_HOME/bin/java` matches `$(which java)` |
| Running WLS JVMs | Finds `java` processes with `-Dweblogic`, shows PID, heap settings |
| Heap settings | Extracts `-Xms` / `-Xmx` from running WLS JVM arguments |
| Log4j CVE scan | Scans `$FMW_HOME` for `log4j*.jar`; reports CVE-2021-44228 exposure |

Log4j classification:

| Version | Result |
|---|---|
| ≥ 2.17.1 | OK – patched |
| 2.x < 2.17.1 | FAIL – CVE-2021-44228 / CVE-2021-45046 vulnerable |
| 1.x | WARN – EOL, CVE-2019-17571 |

---

### port_check.sh

```bash
./02-Checks/port_check.sh
./02-Checks/port_check.sh --http
./02-Checks/port_check.sh --timeout 5
```

Options:

| Option | Description |
|---|---|
| `--http` | Also run HTTP GET health check on AdminServer console and version JSP |
| `--timeout N` | TCP connect timeout in seconds (default: 3) |

Read-only – no `--apply` needed.

Sections in the output:

**1. Network Interfaces** – all IPv4 addresses and subnet masks on the host
(`ip addr` or `ifconfig` fallback).

**2. Configured Ports** – reads `$DOMAIN_HOME/config/config.xml` and extracts
`<server>` blocks with their `<listen-address>` and `<listen-port>` / SSL port.
Falls back to `WL_ADMIN_URL` from `environment.conf` when `config.xml` is not
found.

**3. Node Manager** – reads `$DOMAIN_HOME/nodemanager/nodemanager.properties`
for `ListenPort` and `ListenAddress`. Default 5556 / localhost if file not found.

**4. All Listening TCP Sockets** – output of `ss -tlnp` (or `netstat -tlnp`).
Rows with `java` / `weblogic` / `nodemanager` processes are highlighted in
green; other system sockets are shown dimmed.

> Run as root to see process names for sockets not owned by the current user.

**5. Port Connectivity Cross-Check** – for every port found in config.xml and
nodemanager.properties: shows `ss` state (LISTEN / DOWN) and a TCP connect
result (OPEN / CLOSED). Uses `bash /dev/tcp` – no `nc` or `nmap` required.

**6. HTTP Health Check** (`--http` only) – `curl` GET requests to:
- `http://<admin>:<port>/console` – AdminServer console (HTTP 401 = expected)
- `http://<admin>:<port>/bea_wls_internal/versionInfo.jsp` – version endpoint

Typical ports for a Forms/Reports 14c domain:

| Component | Default Port | Protocol |
|---|---|---|
| AdminServer | 7001 | T3 / HTTP |
| AdminServer SSL | 7002 | T3S / HTTPS |
| WLS_REPORTS | 9001 | T3 / HTTP |
| WLS_FORMS | 9002 | T3 / HTTP |
| Node Manager | 5556 | NM / SSL |
| OHS (if installed) | 8890 / 4443 | HTTP / HTTPS |

---

### db_connect_check.sh

```bash
./02-Checks/db_connect_check.sh               # check existing config
./02-Checks/db_connect_check.sh --new          # configure new connection (interactive)
./02-Checks/db_connect_check.sh --login        # include login test
./02-Checks/db_connect_check.sh --login --sqlplus=/path/to/sqlplus
```

DB connection parameters are read from `environment.conf` (`DB_HOST`, `DB_PORT`,
`DB_SERVICE`, `DB_SERVER`).  If not present, `jps-config.xml` is parsed as fallback.
Use `--new` to configure and save parameters permanently.

**First-time setup:**

```bash
./02-Checks/db_connect_check.sh --new
```

Starts an interactive dialog (host, port, service, username, password).
Writes `DB_HOST / DB_PORT / DB_SERVICE / DB_SERVER` to `environment.conf`
and saves encrypted credentials to `db_connect.conf.des3`
(same openssl des3 + machine-UUID mechanism as `weblogic_sec.sh`).

**Diagnostic steps (sequential – stops at first FAIL):**

| Step | What | Tool | Exit on FAIL |
|---|---|---|---|
| 1 | DNS resolution | `getent hosts` | yes – hostname wrong or DNS unreachable |
| 2 | ICMP Ping | `ping -c3 -W2` | no – ICMP often blocked (WARN only) |
| 3 | TCP port open | `bash /dev/tcp` / `nc` | yes – firewall or listener not started |
| 4 | Oracle TNS Listener? | `tnsping` or Python3 TNS packet | WARN – port open but not Oracle |
| 5 | Service/SID exists? | Python3 TNS CONNECT_DATA | ORA code → targeted hint |
| 6 | Login test (`--login`) | `sqlplus`/`sql` Easy Connect | ORA code → precise error cause |

**Service check without Oracle Client (Step 5):**

A minimal TNS CONNECT packet is sent via Python3 sockets.  The Oracle Listener
responds with a TNS REFUSE packet containing the ORA error as readable ASCII text
(e.g. `ERR=12514`).  No tnsnames.ora, no Oracle client required.

| ORA in REFUSE | Meaning |
|---|---|
| no error / REDIRECT | Service found and registered with listener |
| `ORA-12514` | Listener running – service name not registered |
| `ORA-12505` | Listener running – SID not found |
| `ORA-12519` | Service found – but all handlers busy |

**Login test (Step 6, optional):**

Requires `SQLPLUS_BIN` in `environment.conf` or `--sqlplus=` flag.
Uses Easy Connect (`//host:port/service`) – no tnsnames.ora needed.

| ORA after login | Meaning |
|---|---|
| no ORA | Login successful |
| `ORA-01017` | Wrong username or password |
| `ORA-28000` | Account locked |
| `ORA-28001` | Password expired |

`SQLPLUS_BIN` options:
- Oracle Instant Client `sqlplus` binary
- SQLcl (`sql`) – Java-based, uses existing `$JAVA_HOME`

---

### ssl_check.sh

```bash
./02-Checks/ssl_check.sh                    # auto-detect architecture
./02-Checks/ssl_check.sh --warn-days 60     # warn earlier on cert expiry
./02-Checks/ssl_check.sh --host 10.0.1.5    # external host for TLS checks
./02-Checks/ssl_check.sh --no-curl          # skip HTTP endpoint checks
```

Detects the SSL architecture first, then analyses accordingly.

**Supported architectures:**

| Port 443 owner | Mode | Where is the certificate? |
|---|---|---|
| `nginx` | Nginx SSL proxy | `ssl_certificate` file in nginx config |
| `java` (WLS) | WLS direct SSL | WLS Keystore (JKS/PKCS12) |
| `httpd` | OHS proxy | OHS `ssl.conf` |
| nothing | No HTTPS on 443 | WLS SSL ports (7002, 9002) checked directly |

**Sections:**

| Section | What |
|---|---|
| 1 – Voraussetzungen | openssl / curl / keytool availability |
| 2 – Architektur | Who owns port 443? nginx/WLS/OHS/other |
| 3 – WLS config.xml | SSL enabled/disabled per server, listen ports, keystore type |
| 4 – Nginx config | ssl_certificate path + cert, ssl_protocols, ssl_ciphers, proxy_pass targets |
| 5 – Live TLS analyse | Protocol (TLS 1.0–1.3), cipher strength, forward secrecy, weak protocol test |
| 6 – HTTP endpoints | curl check on /em, /console (HTTP and HTTPS) |
| 7 – Keystore files | keytool -list on .jks/.p12 files under DOMAIN_HOME |

**TLS protocol ratings:**

| Protocol | Result |
|---|---|
| TLS 1.3 | OK |
| TLS 1.2 | OK |
| TLS 1.1 | WARN – deprecated RFC 8996 |
| TLS 1.0 | FAIL – POODLE/BEAST |
| SSLv3 | FAIL – critical |

Also explicitly tests whether old protocols (TLS 1.0/1.1) are still _accepted_
even when the server negotiated TLS 1.2+.

**Certificate checks:**
- Subject / Issuer / SANs
- Self-signed detection (Subject == Issuer)
- Expiry: FAIL if expired, WARN if within `--warn-days` (default: 30)
- Demo certificate detection (WLS `DEMO_CERTS` keystore → FAIL)

**Nginx specifics:**
- Reads config via `nginx -T` (full merged config), falls back to direct file read
- Checks `ssl_certificate` file existence and reads cert without TLS handshake
- Validates `ssl_protocols` and `ssl_ciphers` directives
- Cross-checks `proxy_pass` targets against live listening ports

---

## 4. Troubleshooting

### os_check.sh – ulimit warnings

```
Symptom: WARN nofile=1024 – recommended >= 65536
Cause:   Default OS limits are too low for WebLogic
Fix:     Add to /etc/security/limits.conf:
           oracle  soft  nofile  65536
           oracle  hard  nofile  65536
           oracle  soft  nproc   16384
           oracle  hard  nproc   16384
         Then re-login and re-run os_check.sh.
```

### java_check.sh – wrong JDK detected

```
Symptom: FAIL JAVA_HOME points to system JDK, not FMW JDK
Cause:   /etc/profile.d/ or .bashrc overrides JAVA_HOME after setDomainEnv.sh
Fix:     Set JAVA_HOME explicitly in environment.conf:
           JAVA_HOME=/app/oracle/java/jdk-21.0.6
         Or prepend $FMW_HOME bin to PATH before system Java.
```

### java_check.sh – Log4j FAIL

```
Symptom: FAIL log4j-core-2.14.1.jar – CVE-2021-44228 vulnerable
Cause:   Old log4j version bundled with WLS or application
Fix:     See https://logging.apache.org/log4j/2.x/security.html
         Apply Oracle patch: My Oracle Support Note 2827793.1
         Minimum safe version: log4j-core 2.17.1
```

### port_check.sh – all ports show CLOSED

```
Symptom: All WLS ports show CLOSED in connectivity check
Cause A: WebLogic domain not started
         → Run: $DOMAIN_HOME/bin/startWebLogic.sh  (or via Node Manager)
Cause B: WL_ADMIN_URL in environment.conf has wrong host/port
         → Re-run: 00-Setup/init_env.sh to regenerate environment.conf
Cause C: Firewall blocking the port on this host
         → Check: sudo firewall-cmd --list-ports
         → Open:  sudo firewall-cmd --add-port=7001/tcp --permanent
```

### port_check.sh – process names missing in ss output

```
Symptom: ss -tlnp shows no process name in the Process column
Cause:   Running as a non-root user; ss only shows process info for own processes
Fix:     Run as root or as the oracle user that started WebLogic:
           sudo ./02-Checks/port_check.sh
           su - oracle -c "cd /development/IHateWeblogic && ./02-Checks/port_check.sh"
```

### weblogic_performance.sh

```bash
./02-Checks/weblogic_performance.sh
./02-Checks/weblogic_performance.sh --apply
```

Options:

| Option | Description |
|---|---|
| `--apply` | Interactive update of both settings (backup before every write) |

---

#### Section 1 – java.security: SecureRandom Source

Locates and reads `java.security` for the configured `JAVA_HOME`:

| JDK version | Path |
|---|---|
| JDK 8 | `$JAVA_HOME/jre/lib/security/java.security` |
| JDK 11 / 17 / 21 | `$JAVA_HOME/conf/security/java.security` |

Checks the `securerandom.source` setting:

| Value | Evaluation |
|---|---|
| `file:/dev/random` | **FAIL** – blocking entropy source; slows WLS startup |
| `file:/dev/./urandom` | OK – non-blocking (recommended) |
| `file:/dev/./random` | OK – non-blocking via `./` trick |
| `file:/dev/urandom` | OK on JDK 17+ / newer JDK 8 builds |
| _(not set)_ | WARN – JVM compile-time default applies (likely `/dev/random`) |

**Background – Why `/dev/./urandom`?**

The Oracle JVM contains a special code path: when `securerandom.source` is set to
the literal string `file:/dev/random`, the JVM opens it as a *blocking* source and
waits until the OS entropy pool has enough data. On a freshly booted server or inside
a VM this can stall WebLogic startup for **30 seconds to several minutes**.

The fix is the `./` path trick: `file:/dev/./urandom` resolves to the same device node
on Linux (`/dev/urandom`) but does **not** match the JVM's hardcoded `"/dev/random"`
string comparison, so the JVM falls through to the regular non-blocking path.

```
# Before (in java.security):
securerandom.source=file:/dev/random

# After:
securerandom.source=file:/dev/./urandom
```

`--apply` performs: `backup_file()` → `sed` replace in-place.
No server restart required – takes effect on next JVM startup.

---

#### Section 2 – setUserOverrides.sh: JVM Heap per Server

Reads `$DOMAIN_HOME/bin/setUserOverrides.sh` and extracts `USER_MEM_ARGS` per
managed server block.

`setDomainEnv.sh` sources `setUserOverrides.sh` during startup – this is the
**recommended** way to configure per-server JVM settings without modifying the
Oracle-managed `setDomainEnv.sh` directly.

Checks performed:

| Check | Evaluation |
|---|---|
| File exists | WARN if missing |
| `USER_MEM_ARGS` block for `AdminServer` | WARN if absent |
| `USER_MEM_ARGS` block for `WLS_FORMS` | WARN if absent |
| `USER_MEM_ARGS` block for `WLS_REPORTS` | WARN if absent |
| `LOG4J_FORMAT_MSG_NO_LOOKUPS=true` | WARN if absent (CVE-2021-44228) |
| `forms.userid.encryption.enabled=true` | INFO if absent (optional) |

Typical recommended values:

| Server | `-Xms` | `-Xmx` | Additional |
|---|---|---|---|
| AdminServer | 1024m | 1536m | `-XX:MaxMetaspaceSize=2G` |
| WLS_FORMS | 2g | 2g | `-XX:NewSize=1g` |
| WLS_REPORTS | 2g | 2g | `-XX:NewSize=1g` |

`--apply` writes a complete `setUserOverrides.sh` with all server blocks, the
Log4j CVE guard, and `forms.userid.encryption.enabled`.
All managed servers must be **restarted** for heap changes to take effect.

---

## 5. Related Scripts

| Script | Purpose |
|---|---|
| `00-Setup/init_env.sh` | Detect FMW/Domain paths, generate `environment.conf` |
| `00-Setup/weblogic_sec.sh` | Store WebLogic admin credentials (used by db_connect_check) |
| `01-Run/rwrun_trace.sh` | Diagnose `rwrun` segfaults |
| `03-Logs/grep_logs.sh` | Search logs for errors after a failed check |
| `08-SSL/` | SSL certificate management (complements ssl_check.sh) |

---

## 6. References

- Oracle FMW 14.1.2 System Requirements:
  https://docs.oracle.com/en/middleware/fusion-middleware/fmw-infrastructure/14.1.2/infst/
- Oracle Linux 8 Ulimits for Oracle Products:
  https://docs.oracle.com/en/database/oracle/oracle-database/21/ladbi/
- Oracle Reports Troubleshooting (rwrun segfault / DISPLAY):
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_troubl.htm
- Log4j Security (CVE-2021-44228):
  https://logging.apache.org/log4j/2.x/security.html
- My Oracle Support Note 2827793.1 (Log4j patch for FMW):
  https://support.oracle.com/epmos/faces/DocumentDisplay?id=2827793.1
