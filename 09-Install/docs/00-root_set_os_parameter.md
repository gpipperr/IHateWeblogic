# Step 01 – 01-root_os_baseline.sh

**Script:** `09-Install/01-root_os_baseline.sh`
**Runs as:** `root` or `oracle` with passwordless sudo (`NOPASSWD`)
**Phase:** 0 – OS Preparation

---

## Prerequisites – sudo Configuration

The script uses `sudo -n true` to detect sudo access (non-interactive, no password
prompt). This means the `oracle` user **must** have passwordless sudo configured
before running this script with `--apply`.

### How the script checks access

```bash
# From the script (_can_sudo helper):
sudo -n true 2>/dev/null   # returns 0 only if NOPASSWD sudo is available
```

If neither root nor NOPASSWD sudo is available the script prints:
```
FAIL  Root or sudo access required
INFO  Configure: /etc/sudoers.d/oracle-fmw
```

### Option A – via wheel group (current setup on this server)

Oracle Linux 9 grants full sudo to members of the `wheel` group.
If oracle is already in `wheel`, add NOPASSWD to the group rule:

```bash
# Check current group membership
id oracle
# groups=...,wheel,...  ← already in wheel?

# Check current wheel rule
grep wheel /etc/sudoers
# %wheel  ALL=(ALL)  ALL         ← requires password (not sufficient for -n)
# %wheel  ALL=(ALL)  NOPASSWD: ALL  ← this works with sudo -n
```

To change the wheel rule to passwordless:
```bash
# Edit safely with visudo
visudo
# Change: %wheel  ALL=(ALL)  ALL
# To:     %wheel  ALL=(ALL)  NOPASSWD: ALL
```

> **Security note:** NOPASSWD for the entire wheel group is convenient during
> installation but should be reverted to password-required after the install phase.

### Option B – targeted sudoers drop-in (recommended for production)

Create `/etc/sudoers.d/oracle-fmw` with only the commands needed by the scripts:

```bash
visudo -f /etc/sudoers.d/oracle-fmw
```

Minimum required for `01-root_os_baseline.sh --apply`:

```
# Oracle FMW installation – allow oracle to run baseline OS configuration
# Remove this file after installation is complete
oracle ALL=(ALL) NOPASSWD: /usr/sbin/sysctl, \
                            /usr/sbin/grubby, \
                            /usr/bin/tee, \
                            /usr/bin/sed, \
                            /usr/bin/dnf, \
                            /usr/bin/mount, \
                            /usr/bin/mkdir, \
                            /usr/bin/chmod, \
                            /usr/bin/firewall-cmd, \
                            /usr/bin/systemctl
```

### Verify sudo access before running

```bash
# As oracle – must return exit code 0 with no password prompt
sudo -n true && echo "sudo OK" || echo "sudo FAIL – configure NOPASSWD first"

# Test a specific command
sudo -n sysctl -n kernel.shmmax
```

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

## Konflikt: oracle-database-preinstall-* überschreibt WLS-Werte

Das RPM `oracle-database-preinstall-23ai` (und Vorgänger) schreibt DB-dimensionierte
`shmmax`/`shmall`-Werte in **zwei** Dateien:

```
/etc/sysctl.conf                                        ← höchste Priorität (wird zuletzt geladen)
/etc/sysctl.d/99-oracle-database-preinstall-23ai-sysctl.conf
```

Da `/etc/sysctl.conf` **nach** allen `sysctl.d/*.conf`-Dateien geladen wird,
überschreibt es `99-oracle-fmw.conf` — still und lautlos.

Das Skript erkennt diesen Konflikt automatisch und zeigt:

```
WARN  Conflicting sysctl in sysctl.conf: kernel.shmmax = 4398046511104 (overrides our: 4294967295)
FAIL  2 external sysctl file(s) override our WebLogic parameters
```

### Steuerung über `LOCAL_REP_DB` (environment.conf)

| Wert | Bedeutung | Verhalten im Skript |
|---|---|---|
| `false` *(Default)* | Kein Oracle DB auf diesem Host | **FAIL** — `--apply` bietet an, die kollidierenden Zeilen auszukommentieren (Backup wird erstellt) |
| `true` | Oracle DB läuft auf demselben Host | Nur **WARN** — keine Änderung, da die DB die größeren Shm-Werte benötigt |

```bash
# In environment.conf einstellen:
LOCAL_REP_DB="false"   # Standard: kein lokales Oracle DB
LOCAL_REP_DB="true"    # Oracle DB auf diesem Host (mixed setup)
```

### Manuelle Bereinigung (ohne --apply)

Kollidierenden Zeilen in `/etc/sysctl.conf` auskommentieren:

```bash
# Backup anlegen
cp /etc/sysctl.conf /etc/sysctl.conf.bak_$(date +%Y%m%d)

# Zeilen auskommentieren (Präfix [oracle-fmw] zur Nachvollziehbarkeit)
sed -i 's/^kernel\.shmmax[[:space:]]*=/# [oracle-fmw] kernel.shmmax =/' /etc/sysctl.conf
sed -i 's/^kernel\.shmall[[:space:]]*=/# [oracle-fmw] kernel.shmall =/' /etc/sysctl.conf
sed -i 's/^net\.ipv4\.ip_local_port_range[[:space:]]*=/# [oracle-fmw] net.ipv4.ip_local_port_range =/' /etc/sysctl.conf

# Gleiche Bereinigung für das preinstall-Drop-in:
sed -i '...' /etc/sysctl.d/99-oracle-database-preinstall-23ai-sysctl.conf

# Werte neu laden und prüfen
sysctl --system
sysctl kernel.shmmax   # Erwartet: 4294967295
```

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

## Swap Space

Oracle Universal Installer performs a hard prerequisite check:

```
Checking swap space: must be greater than 512 MB.   Actual 0 MB    Failed
```

**OUI refuses to continue if swap is below 512 MB.** On VMs and cloud instances swap
is frequently zero — not because anyone deleted it, but because it was never configured.

### Why swap matters here

`vm.swappiness=10` (set above) means the kernel almost never touches swap under normal
load. Swap is present purely as:

1. OUI prerequisite check (hard minimum 512 MB)
2. Emergency memory buffer if JVM heap temporarily exceeds available RAM

### Thresholds

| Swap total | Result |
|---|---|
| 0 MB | **FAIL** – OUI refuses to run |
| 1–511 MB | **FAIL** – below OUI minimum |
| 512 MB–2047 MB | **WARN** – OUI passes, but below recommended for WLS |
| ≥ 2 GB | **OK** |

### Check current swap

```bash
free -m          # Total/used/free – Swap line
swapon --show    # Active swap devices and files with size and type
```

### Create a swapfile (if no swap exists)

A swapfile under `$ORACLE_BASE` is the pragmatic solution on VMs:

```bash
# 1. Create the file (fallocate is instant on ext4/xfs)
fallocate -l 2G /u01/app/oracle/swapfile
# Fallback if fallocate fails (e.g. NFS):
# dd if=/dev/zero of=/u01/app/oracle/swapfile bs=1M count=2048

# 2. Set permissions (root-only read/write required by kernel)
chmod 600 /u01/app/oracle/swapfile

# 3. Format as swap
mkswap /u01/app/oracle/swapfile

# 4. Activate immediately
swapon /u01/app/oracle/swapfile

# 5. Verify
free -m
swapon --show
```

**Persist across reboots** – add to `/etc/fstab`:

```
/u01/app/oracle/swapfile   none   swap   sw   0   0
```

> **Location rationale:** Placing the swapfile under `$ORACLE_BASE` instead of `/`
> avoids filling up a potentially small root filesystem. The Oracle disk typically
> has the most free space.

### Extend existing swap (if below minimum)

If swap exists but is too small:

```bash
# Check what is active
swapon --show
NAME             TYPE   SIZE  USED PRIO
/dev/sda2        partition  1G    0B   -2

# Option A: Add a second swapfile (no need to touch the partition)
fallocate -l 2G /u01/app/oracle/swapfile2
chmod 600 /u01/app/oracle/swapfile2
mkswap /u01/app/oracle/swapfile2
swapon /u01/app/oracle/swapfile2
echo "/u01/app/oracle/swapfile2 none swap sw 0 0" >> /etc/fstab

# Option B: Resize a swapfile (must swapoff first)
swapoff /u01/app/oracle/swapfile
fallocate -l 4G /u01/app/oracle/swapfile
mkswap /u01/app/oracle/swapfile
swapon /u01/app/oracle/swapfile
```

### Remove swap after installation

Swap is only strictly needed during OUI execution. After the installation is complete
it can be reduced (but keep ≥ 512 MB in case of future patches or updates that invoke
OUI/OPatch):

```bash
# Check usage before removing
swapon --show
# If used=0:
swapoff /u01/app/oracle/swapfile
rm /u01/app/oracle/swapfile
# Remove the /etc/fstab line
```

---

## Additional baseline settings (also in 01-root_os_baseline.sh)

- **SELinux:** Set to `disabled` in `/etc/selinux/config` (requires reboot)
- **Transparent HugePages (THP):** Disabled via `grubby` (`transparent_hugepage=never`)
  — required to avoid JVM GC pause spikes caused by THP merging/splitting
- **Swap space:** ≥ 512 MB required by OUI prereq check; `--apply` creates a 2 GB
  swapfile under `$ORACLE_BASE/swapfile` if no swap is present (see section above)
- **Firewall:** Ports 80 and 443 opened; WLS ports (7001, 9001, 9002) and Node Manager
  port 5556 must remain closed externally (Nginx is the only external entry point)
- **Sysctl conflict detection:** The script scans all `/etc/sysctl.d/*.conf` and
  `/etc/sysctl.conf` for values that differ from the WLS target. Behaviour is
  controlled by `LOCAL_REP_DB` in `environment.conf` (see section above)

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

# Swap space (OUI minimum 512 MB)
free -m
# Expected Swap: total >= 512
swapon --show
# Expected: at least one entry (partition or swapfile)

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
