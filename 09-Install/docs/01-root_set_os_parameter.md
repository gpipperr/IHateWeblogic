# Steps 01 / 02 – OS Baseline and Package Installation

This document covers two scripts that were split from the original OS preparation step:

| Script | Purpose |
|---|---|
| `09-Install/01-root_os_baseline.sh` | Kernel parameters, THP, firewall, SELinux |
| `09-Install/02-root_os_packages.sh` | Package installation, JDK 21 |

---

## 01-root_os_baseline.sh – Kernel Parameters

### OL9: Use sysctl.d — not sysctl.conf

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

### SHMMAX and SHMALL explained

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

### Kernel parameters: WebLogic / Forms / Reports (no database)

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

### Core Dump Setup

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

### Additional baseline settings (also in 01-root_os_baseline.sh)

- **SELinux:** Set to `disabled` in `/etc/selinux/config` (requires reboot)
- **Transparent HugePages (THP):** Disabled via `grubby` (`transparent_hugepage=never`)
  — required to avoid JVM GC pause spikes caused by THP merging/splitting
- **Firewall:** Ports 80 and 443 opened; WLS ports (9001, 9002, 7001) must remain
  closed externally (Nginx is the only external entry point)

---

## 02-root_os_packages.sh – Package Installation

### OL7 → OL9 package changes

The official Oracle WLS/Forms installation guide lists packages for OL6/OL7.
Several packages changed or disappeared for OL9 (RHEL9):

| OL7 package | OL9 status | Action |
|---|---|---|
| `compat-libcap1` | **removed from RHEL9** | omit |
| `compat-libstdc++-33` | **removed from RHEL9** | omit — replaced by current `libstdc++` |
| `openssl-1.0.x` | **replaced by OpenSSL 3** | use `compat-openssl11` for 1.1 compat |
| `redhat-lsb` / `redhat-lsb-core` | deprecated on OL9 | omit |
| `glibc.i686` / `libgcc.i686` / `libstdc++.i686` | 32-bit | **omit** — FMW 14.1.2 is 64-bit only |
| `motif` / `motif-devel` | ✓ available on OL9 | **required** — OUI exits with "Not found. Failed" |
| `numactl` | ✓ available on OL9 | add — JVM NUMA memory awareness |
| `gcc` / `gcc-c++` | ✓ available on OL9 | add — OUI checks for compiler toolchain |

> **motif is critical for Forms/Reports:** The Oracle Universal Installer explicitly
> checks for `motif-2.3.4-28.el9-x86_64` on OL9. Without it the installer exits:
> `Checking for motif-2.3.4-28.el9-x86_64; Not found. Failed`

### 1. FMW prerequisite libraries

```bash
dnf install -y \
  binutils compat-openssl11 cups-libs \
  gcc gcc-c++ \
  glibc glibc-devel ksh \
  libaio libaio-devel libX11 libXau libXi libXrender libXtst \
  libgcc libstdc++ libstdc++-devel libnsl \
  make motif motif-devel \
  net-tools nfs-utils numactl \
  unzip wget curl tar
```

### 2. Font stack (Reports PDF rendering)

```bash
dnf install -y \
  fontconfig freetype \
  dejavu-sans-fonts dejavu-serif-fonts dejavu-sans-mono-fonts \
  dejavu-lgc-sans-fonts dejavu-lgc-serif-fonts \
  liberation-sans-fonts liberation-serif-fonts liberation-mono-fonts \
  xorg-x11-utils xorg-x11-fonts-Type1
```

### 3. Admin and monitoring tools

```bash
dnf install -y \
  sysstat smartmontools nmon tmux \
  lsof strace psmisc xauth \
  bind-utils tcpdump nc
```

### 4. JDK 21

Download JDK 21 from Oracle (requires Oracle account):

```bash
# Extract to JDK_HOME (NOT into FMW_HOME – JDK stays independent)
tar xf jdk-21.0.x_linux-x64_bin.tar.gz -C /u01/app/oracle/java/

# Register with alternatives (do NOT change the system default /usr/bin/java)
alternatives --install /usr/bin/java java /u01/app/oracle/java/jdk-21/bin/java 1000
```

Verify:

```bash
/u01/app/oracle/java/jdk-21/bin/java -version
# Expected: java version "21.x.x"
```

> The script looks for a `.tar.gz` or `.rpm` JDK 21 installer in `$PATCH_STORAGE`
> and offers to install it automatically.

---

## Verification

```bash
# Kernel parameters (after applying)
sysctl kernel.shmmax kernel.shmall net.ipv4.ip_local_port_range vm.swappiness
# Expected:
#   kernel.shmmax = 4294967295
#   kernel.shmall = 9272480
#   net.ipv4.ip_local_port_range = 9000    65500
#   vm.swappiness = 10

# THP status
cat /sys/kernel/mm/transparent_hugepage/enabled
# Expected: always madvise [never]

# Key packages
rpm -q glibc libaio libstdc++ fontconfig

# JDK
$JDK_HOME/bin/java -version
# Expected: java version "21.x.x"
```

---

## References

| Topic | URL |
|---|---|
| Oracle WebLogic 14c Installation on Linux – practical guide with sysctl values | https://dbainsight.com/2026/02/oracle-weblogic-14c-installation-on-linux |
| Oracle WebLogic Server 14.1.1 System Requirements and Specifications (kernel.shmmax) | https://docs.oracle.com/en/middleware/standalone/weblogic-server/14.1.1.0/sysrs/system-requirements-and-specifications.html#GUID-D72CDA83-940D-497C-96EF-0BEB97D3A991 |
| Oracle Forms & Reports 14.1.2 Installation Prerequisites | https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/install-fnr/preparing-install.html#GUID-F657DBB3-8C18-49E0-87FF-9D32DB46B9DD |
