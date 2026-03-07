# Step 00 – 00-root_os_network.sh

**Script:** `09-Install/00-root_os_network.sh`
**Runs as:** root or oracle (read-only, no write access needed)
**Phase:** 0 – Pre-Installation Network Check

---

## Purpose

Validate that the network environment meets Oracle WebLogic / Forms / Reports
requirements **before** the installation starts.

At the time this script runs, hostname, IP address, and DNS are already configured
and cannot easily be changed afterward — WebLogic embeds the listen address in its
configuration, SSL certificates, and cluster definitions. A wrong network baseline
causes hard-to-diagnose failures later.

This script is **read-only**: it checks and reports, but makes no changes.

---

## Why Network Matters for WebLogic

| WebLogic Component | Network Dependency |
|---|---|
| Admin Server ListenAddress | Must forward-resolve to a routable IP |
| Node Manager | Binds to hostname; must not resolve to 127.0.0.1 |
| Cluster communication | Requires symmetric forward + reverse DNS |
| SSL certificates | FQDN in cert must match `hostname -f` |
| JDBC data sources | `localhost` must resolve to 127.0.0.1, not `::1` |
| In-process Reports Server | JVM uses OS DNS stack (NSS); same rules apply |

---

## Checks Performed

### Block 1 – Hostname Consistency

```bash
hostname          # short name  (e.g. wls01)
hostname -f       # FQDN        (e.g. wls01.company.local)
hostname -d       # domain part (e.g. company.local)
```

- Short hostname must not be empty or `localhost`
- FQDN must contain at least one dot (bare hostname is invalid for WLS)
- Domain part must not be empty

### Block 2 – Forward DNS Resolution

```bash
getent hosts "$(hostname -f)"      # NSS stack: same as JVM
dig +short "$(hostname -f)" A      # pure DNS (fallback)
```

- FQDN must resolve to an IP address
- The IP must **not** be `127.0.0.1` or `::1` (loopback)
  — WebLogic would bind to the loopback interface and be unreachable from the network
- `getent` uses the same NSS resolution order as the JVM (`/etc/nsswitch.conf`)

### Block 3 – Reverse DNS (PTR Record)

```bash
dig -x "$IP" +short        # PTR lookup
getent hosts "$IP"         # NSS reverse
```

- The IP must reverse-resolve back to the FQDN (or the short hostname at minimum)
- Forward ≠ Reverse causes SSL handshake failures and cluster issues
- Missing PTR record: WARN (not always FAIL; depends on DNS infrastructure)

### Block 4 – /etc/hosts Consistency

```bash
grep -E "$(hostname)" /etc/hosts
```

- An `/etc/hosts` entry for the host is recommended as DNS fallback
- The entry must not point to `127.0.0.1` or `::1`
- The IP in `/etc/hosts` must match the DNS resolution (no split-brain)

### Block 5 – DNS Resolver Configuration

```bash
cat /etc/resolv.conf
grep hosts /etc/nsswitch.conf
```

- `/etc/resolv.conf` must have at least one `nameserver` line
- `search` or `domain` directive must be present (required for short-name resolution)
- `/etc/nsswitch.conf`: `hosts:` line must include both `files` and `dns`

### Block 6 – IPv6 Status

```bash
sysctl -n net.ipv6.conf.all.disable_ipv6
ip -6 addr show scope global
```

- Reports whether IPv6 is enabled or disabled system-wide
- If **disabled** via sysctl: OK for WebLogic (matches `net.ipv6.conf.all.disable_ipv6=1`
  from `01-root_os_baseline.sh`)
- If **enabled**:
  - Check whether the host has a routable IPv6 address (global scope)
  - Check whether a AAAA record exists in DNS
  - If IPv6 is enabled but no AAAA record exists → WARN:
    add `-Djava.net.preferIPv4Stack=true` to `setUserOverrides.sh`
  - If IPv6 is enabled and AAAA record exists: verify AAAA matches interface address

### Block 7 – localhost → IPv4 Check

```bash
getent hosts localhost
grep "::1" /etc/hosts
```

**Background:** Standard Oracle Linux `/etc/hosts` contains:

```
::1   localhost localhost.localdomain localhost6 localhost6.localdomain6
```

On many OL installations the `::1` line assigns `localhost` (without the `6` suffix)
to the IPv6 loopback address. If `getent hosts localhost` returns `::1`:

- JDBC URL `jdbc:oracle:thin:@localhost:1521/...` connects via IPv6 — fails if the
  listener is IPv4-only
- Internal WebLogic RMI / JMX connections using `localhost` may fail or be slow
- `java.net.InetAddress.getByName("localhost")` returns `::1` instead of `127.0.0.1`

**Check result:**
- `getent hosts localhost` returns `127.0.0.1` → OK
- `getent hosts localhost` returns `::1` → FAIL with remediation hint

**Remediation (manual):** Edit `/etc/hosts` and ensure the `::1` line only contains
names with the `6` suffix:

```
# Before (problematic):
::1   localhost localhost.localdomain localhost6 localhost6.localdomain6

# After (correct):
::1   localhost6 localhost6.localdomain6
```

### Block 8 – Time Synchronization (chrony)

WebLogic requires both the Admin Server and Managed Servers to have identical system
clocks. A time difference of more than a few seconds causes:

- SSL handshake failures (certificate validity windows)
- Cluster heartbeat timeouts and split-brain
- Kerberos authentication failures (if used)
- Log correlation across servers becomes impossible

```bash
# Is chrony installed?
rpm -q chrony

# Is chronyd running and enabled?
systemctl status chronyd
systemctl is-enabled chronyd

# Is the clock synchronized?
timedatectl

# Tracking – reference server and current offset
chronyc -n tracking

# Sources – show all configured NTP sources and their status
chronyc -n sources -v
```

**Installation (falls chrony fehlt):**

```bash
# Verfügbarkeit prüfen
dnf list chrony

# Installieren
dnf install chrony -y

# Aktivieren und starten
systemctl enable chronyd
systemctl start chronyd

# Status prüfen
systemctl status chronyd
timedatectl
```

**Configuration – `/etc/chrony.conf`:**

At least one `pool` or `server` entry must be present. For German/European
infrastructure, the [NTP Pool Project](https://www.ntppool.org/en/zone/de)
provides geographically close servers:

```
# /etc/chrony.conf – add for Germany/DACH region
pool 0.de.pool.ntp.org iburst
pool 1.de.pool.ntp.org iburst
```

After changing `chrony.conf`:

```bash
systemctl restart chronyd
chronyc -n sources -v     # verify sources are reachable
chronyc -n tracking       # check offset and stratum
```

**Hardware clock:**

After the system clock is synchronized, write it to the hardware clock so the
BIOS/UEFI clock stays correct across reboots:

```bash
hwclock -w
```

**Acceptance criteria:**

| Item | Required |
|---|---|
| `rpm -q chrony` returns a version | YES |
| `systemctl is-active chronyd` = active | YES |
| `systemctl is-enabled chronyd` = enabled | YES |
| `timedatectl` shows `NTP service: active` and `synchronized: yes` | YES |
| `chronyc tracking` Stratum ≤ 10 | YES |
| `chronyc tracking` Leap status = Normal | YES |
| At least one `pool` or `server` in `/etc/chrony.conf` | YES |

---

## WebLogic Readiness Summary

At the end of the script, a consolidated verdict is printed:

| Check | Required for WLS | Result |
|---|---|---|
| FQDN has domain part | YES | OK / FAIL |
| FQDN resolves (forward) | YES | OK / FAIL |
| Resolved IP is not loopback | YES | OK / FAIL |
| Reverse DNS matches | RECOMMENDED | OK / WARN |
| localhost → 127.0.0.1 | YES | OK / FAIL |
| IPv6 status documented | INFO | OK / WARN |
| chrony installed and running | YES | OK / FAIL |
| System clock NTP-synchronized | YES | OK / WARN |
| NTP pool/server configured | YES | OK / FAIL |

---

## Verification (manual)

```bash
# Hostname checks
hostname
hostname -f
hostname -d

# Forward resolution (NSS – same as JVM)
getent hosts "$(hostname -f)"

# Forward resolution (pure DNS)
dig +short "$(hostname -f)" A

# Reverse DNS
dig -x "$(getent hosts "$(hostname -f)" | awk '{print $1}')" +short

# localhost resolution
getent hosts localhost
# Expected: 127.0.0.1   localhost

# IPv6 status
sysctl net.ipv6.conf.all.disable_ipv6
# Expected for WLS: net.ipv6.conf.all.disable_ipv6 = 1

# /etc/hosts
cat /etc/hosts
# ::1 line must NOT contain 'localhost' without '6' suffix
```

---

## References

| Topic | Reference |
|---|---|
| WebLogic listen address requirements | Oracle WebLogic 14.1.2 Installation Guide |
| Java InetAddress localhost resolution | JDK: `java.net.InetAddress.getLoopbackAddress()` |
| IPv6 and WebLogic JVM flag | `-Djava.net.preferIPv4Stack=true` in `setUserOverrides.sh` |
| NSS resolution order | `/etc/nsswitch.conf` – `hosts: files dns myhostname` |
