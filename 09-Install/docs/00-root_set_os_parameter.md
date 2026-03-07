# Step 01 – 01-root_os_baseline.sh

**Script:** `09-Install/01-root_os_baseline.sh`
**Runs as:** `root`
**Phase:** 0 – OS Preparation

---

## Purpose

Set kernel parameters, disable Transparent HugePages, configure core dumps,
and open firewall ports. Requires a reboot after applying SELinux changes.

---

## OL9: Use sysctl.d — not sysctl.conf

> **Common mistake on Oracle Linux 9:** Administrators often edit `/etc/sysctl.conf`
> directly (as was standard on OL6/7). On OL9 this still works but is the wrong approach.

On OL9 (systemd-based), `sysctl --system` processes configuration in this order
(last writer wins):

```
/usr/lib/sysctl.d/*.conf      ← OS / package defaults  (lowest priority)
/run/sysctl.d/*.conf          ← runtime overrides
/etc/sysctl.d/*.conf          ← admin customisation     (recommended place)
/etc/sysctl.conf              ← legacy file             (highest priority, but avoid)
```

**Correct approach:** Place settings in `/etc/sysctl.d/99-oracle-fmw.conf`.
The `99-` prefix ensures the file is processed last within `sysctl.d/` and
overrides any lower-numbered package files (e.g. `10-default-yama-scope.conf`).

Apply after writing:

```bash
sysctl --system
# Apply only the oracle file (for testing):
sysctl -p /etc/sysctl.d/99-oracle-fmw.conf
```

Check current value before applying:

```bash
sysctl -a | grep shmmax
# kernel.shmmax = 4398046511104   ← this DB-sized value indicates a mixed config
```

---

## SHMMAX and SHMALL explained

**`kernel.shmmax`** – maximum size of a single shared memory segment in bytes.

Oracle Universal Installer checks this value and refuses to proceed if it is too low.

| Platform | Oracle DB recommendation | WebLogic (WLS SYSRS) |
|---|---|---|
| 32-bit Linux | min(4 GB − 1, RAM/2) | — |
| 64-bit Linux | RAM / 2 | **4294967295 (4 GB − 1, fixed)** |

For a **database host**, SHMMAX scales with RAM because the Oracle SGA (System Global
Area) is allocated as a single shared memory segment. A 64 GB DB server would set
`kernel.shmmax = 34359738368` (32 GB).

For a **WebLogic / Forms / Reports host** (no database), Oracle explicitly documents
`4294967295` in the WLS System Requirements and Specifications. The JVM heap is
managed by the JVM — it does not use SysV shared memory segments the way an Oracle DB
does. The fixed value of 4 GB − 1 is sufficient.

**`kernel.shmall`** – total amount of shared memory available system-wide, in **pages**.

Rule: `shmall ≥ CEIL(shmmax / PAGE_SIZE)`

```bash
# Page size (x86_64 is always 4096 bytes)
getconf PAGE_SIZE
# → 4096

# Minimum shmall for our shmmax:
# CEIL(4294967295 / 4096) = 1048576 pages
```

Our value `9272480` pages (≈ 37 GB) exceeds the minimum — it matches the practical
WLS recommendation from dbainsight and leaves headroom for JVM off-heap / NIO buffers.

---

## Kernel parameters: WebLogic / Forms / Reports (no database)

Create `/etc/sysctl.d/99-oracle-fmw.conf`:

```
# Oracle FMW 14.1.2 – kernel parameters for WebLogic / Forms / Reports
# References:
#   Oracle WLS 14.1.1 SYSRS (kernel.shmmax explicitly required)
#   https://dbainsight.com/2026/02/oracle-weblogic-14c-installation-on-linux

# Shared memory – required by Oracle Universal Installer (WLS SYSRS)
# Note: NOT Oracle Database values (shmmax=4TB, shmall=1073741824, sem, shmmni)
kernel.shmmax         = 4294967295
kernel.shmall         = 9272480

# Ephemeral port range (WLS / Forms / Reports use many concurrent connections)
net.ipv4.ip_local_port_range = 9000 65500

# JVM GC stability – reduce swap pressure on JVM heap
vm.swappiness         = 10

# Server stability – panic on kernel oops to force clean restart
kernel.panic_on_oops  = 1

# Core dumps – centralise to /var/tmp/core (Oracle Forms dumps frequently)
# fs.suid_dumpable=1 required so oracle user (non-root) produces core files
fs.suid_dumpable      = 1
kernel.core_uses_pid  = 1
kernel.core_pattern   = /var/tmp/core/coredump_%h_.%s.%u.%g_%t_%E_%e

# IPv6 disable (WLS Node Manager listen address stability: 127.0.0.1 vs ::1)
net.ipv6.conf.all.disable_ipv6     = 1
net.ipv6.conf.default.disable_ipv6 = 1
```

Apply immediately:

```bash
sysctl --system
```

### Parameter rationale

| Parameter | Value | Source | Rationale |
|---|---|---|---|
| `kernel.shmmax` | `4294967295` | Oracle WLS SYSRS (explicit) | Max shared memory segment size; 4 GB−1; required by OUI |
| `kernel.shmall` | `9272480` | dbainsight / WLS practice | Total shared memory pages (~37 GB), sufficient for JVM |
| `kernel.sem` | — | **not set** | SysV semaphores – Oracle Database only |
| `kernel.shmmni` | — | **not set** | Shared memory segment count – Oracle Database only |
| `fs.aio-max-nr` | — | **not set** | Async I/O – Oracle Database only |
| `net.ipv4.ip_local_port_range` | `9000 65500` | Best practice | WLS / HTTP connections need many ephemeral ports |
| `vm.swappiness` | `10` | JVM best practice | Prefer RAM over swap for JVM heap |
| `fs.suid_dumpable` | `1` | Core dump requirement | Required so oracle user (non-root) produces core files |
| `kernel.core_uses_pid` | `1` | Core dump | Append PID to core filename (avoid overwrites) |
| `kernel.core_pattern` | `/var/tmp/core/...` | Core dump | Central directory; Forms/JVM dumps stay visible |
| `kernel.panic_on_oops` | `1` | Server stability | Force clean restart on kernel oops |
| `vm.min_free_kbytes` | — | **not set** | Heavy DB tuning – not needed for WLS |
| `net.core.rmem/wmem` | — | **not set** | DB/RAC network tuning – not needed for single-server WLS |

---

## Core Dump Setup

Oracle Forms in particular can produce core dumps. Without a central directory they
land in the FMW process working directory (e.g. `/u01/oracle/fmw/.../bin/`) and
**silently fill up the disk** — very hard to debug.

`fs.suid_dumpable = 1` is required so the `oracle` user (non-root) actually produces
core files at all. Without it, setuid processes silently suppress the dump.

**Setup (manual or via script with `--apply`):**

```bash
mkdir /var/tmp/core
chmod 777 /var/tmp/core
```

The `kernel.core_pattern` parameter (set in the sysctl file above) controls the filename.
Pattern fields used:

| Field | Meaning |
|---|---|
| `%h` | Hostname |
| `%s` | Signal number that caused the dump |
| `%u` | UID of the dumping process |
| `%g` | GID of the dumping process |
| `%t` | Time of dump (UNIX epoch) |
| `%E` | Full pathname of executable (slashes replaced by `!`) |
| `%e` | Executable filename (short) |

**Test – verify core dumps work for the oracle user:**

```bash
su - oracle

# Core file size must be unlimited (0 = no core file produced at all)
ulimit -c unlimited

# Trigger a SIGSEGV on the current shell
kill -s SIGSEGV $$
# Expected output: Segmentation fault (core dumped)

# Check the dump file
ls /var/tmp/core/
# Example: coredump_wls01.company.local_.11.1100.1000_1711234567_!bin!bash_bash

# Decode the timestamp from the filename
date -d @1711234567

# Analyse with gdb
gdb /bin/bash /var/tmp/core/coredump_...
# or
readelf -Wa /var/tmp/core/coredump_...
```

**Disk space warning:** A JVM core dump is roughly the size of the Java heap
(typically 2–8 GB). Monitor `/var/tmp/core/` and add a cron cleanup if needed:

```bash
# Remove core dumps older than 14 days
find /var/tmp/core/ -name "coredump_*" -mtime +14 -delete
```

---

## Additional baseline settings (also in 01-root_os_baseline.sh)

- **SELinux:** Set to `disabled` in `/etc/selinux/config` (requires reboot)
- **Transparent HugePages (THP):** Disabled via `grubby` (`transparent_hugepage=never`)
  — required to avoid JVM GC pause spikes caused by THP merging/splitting
- **Firewall:** Ports 80 and 443 opened; WLS ports (7001, 9001, 9002) and Node Manager
  port 5556 must remain closed externally (Nginx is the only external entry point)

---

## Verification

```bash
# Kernel parameters (after applying)
sysctl kernel.shmmax kernel.shmall net.ipv4.ip_local_port_range vm.swappiness \
       kernel.panic_on_oops fs.suid_dumpable kernel.core_uses_pid
# Expected:
#   kernel.shmmax = 4294967295
#   kernel.shmall = 9272480
#   net.ipv4.ip_local_port_range = 9000    65500
#   vm.swappiness = 10
#   kernel.panic_on_oops = 1
#   fs.suid_dumpable = 1
#   kernel.core_uses_pid = 1

sysctl kernel.core_pattern
# Expected: /var/tmp/core/coredump_%h_.%s.%u.%g_%t_%E_%e

# THP status
cat /sys/kernel/mm/transparent_hugepage/enabled
# Expected: always madvise [never]

# SELinux (requires reboot after change)
getenforce
# Expected: Disabled

# Core dump directory
ls -la /var/tmp/core/
# Expected: drwxrwxrwx

# Firewall – Nginx ports open, WLS ports closed
firewall-cmd --list-ports
# Expected: 80/tcp 443/tcp  (and NOT 7001 9001 9002 5556)
```

---

## References

| Topic | URL |
|---|---|
| Oracle WebLogic 14c Installation on Linux – practical guide with sysctl values | https://dbainsight.com/2026/02/oracle-weblogic-14c-installation-on-linux |
| Oracle WebLogic Server 14.1.1 System Requirements and Specifications (kernel.shmmax) | https://docs.oracle.com/en/middleware/standalone/weblogic-server/14.1.1.0/sysrs/system-requirements-and-specifications.html#GUID-D72CDA83-940D-497C-96EF-0BEB97D3A991 |
