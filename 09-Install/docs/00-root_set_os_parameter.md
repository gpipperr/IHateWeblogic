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

## Conflict: oracle-database-preinstall-* overrides the WLS values

The RPM `oracle-database-preinstall-23ai` (and its predecessors) writes
DB-sized `shmmax` / `shmall` values into **two** files:

```
/etc/sysctl.conf                                        <- highest priority (loaded last)
/etc/sysctl.d/99-oracle-database-preinstall-23ai-sysctl.conf
```

Because `/etc/sysctl.conf` is loaded **after** all `sysctl.d/*.conf` files,
it silently overrides `99-oracle-fmw.conf`.

The script detects the conflict and shows:

```
WARN  Conflicting sysctl in sysctl.conf: kernel.shmmax = 4398046511104 (overrides our: 4294967295)
FAIL  2 external sysctl file(s) override our WebLogic parameters
```

### Controlled by `LOCAL_REP_DB` (environment.conf)

| Value | Meaning | Script behaviour |
|---|---|---|
| `false` *(default)* | no Oracle DB on this host | **FAIL** – `--apply` offers to comment out the conflicting lines (backup first) |
| `true` | Oracle DB runs on the same host | **WARN** only – no change, the DB needs the larger shm values |

```bash
# in environment.conf:
LOCAL_REP_DB="false"   # default: no local Oracle DB
LOCAL_REP_DB="true"    # Oracle DB on this host (mixed setup, 60-RCU-DB-19c/)
```

`01-setup-interview.sh` asks for `LOCAL_REP_DB` and proposes the detected
value (`true` when an `ora_pmon_*` process runs or `DB_HOST` is a local
address).

**Minimums instead of exact values:** for `kernel.shmmni`, `fs.file-max`,
`fs.aio-max-nr` and `net.core.rmem_*` / `wmem_*` a **larger** value is always
fine – no warning, no conflict. `kernel.shmmax` and `kernel.shmall` count as
minimums only with `LOCAL_REP_DB=true`; on a pure WLS host they stay exact,
because exactly the DB-sized values are to be cleaned up there.
`net.ipv4.ip_local_port_range` is always exact.

**Firewall with a local DB:** with `LOCAL_REP_DB=true` the script also checks
whether the listener port (`DB_PORT`, default 1521) is open – as a hint only,
it is never opened automatically.

**Swap:** a 2 GiB swap file shows up in `free -m` as 2047 MB; the check
tolerates 32 MB.

### Manual clean-up (without --apply)

Comment out the conflicting lines in `/etc/sysctl.conf`:

```bash
# backup
cp /etc/sysctl.conf /etc/sysctl.conf.bak_$(date +%Y%m%d)

# comment out (prefix [oracle-fmw] for traceability)
sed -i 's/^kernel\.shmmax[[:space:]]*=/# [oracle-fmw] kernel.shmmax =/' /etc/sysctl.conf
sed -i 's/^kernel\.shmall[[:space:]]*=/# [oracle-fmw] kernel.shmall =/' /etc/sysctl.conf
sed -i 's/^net\.ipv4\.ip_local_port_range[[:space:]]*=/# [oracle-fmw] net.ipv4.ip_local_port_range =/' /etc/sysctl.conf

# same clean-up for the preinstall drop-in:
sed -i '...' /etc/sysctl.d/99-oracle-database-preinstall-23ai-sysctl.conf

# reload and check
sysctl --system
sysctl kernel.shmmax   # expected: 4294967295
```

---

## Kernel parameters: WebLogic / Forms / Reports (no database)

Create `/etc/sysctl.d/99-oracle-fmw.conf`:

```
# Oracle FMW 14.1.2 – kernel parameters for WebLogic / Forms / Reports
# References:
#   Oracle WLS 14.1.1 SYSRS (kernel.shmmax explicitly required)
#   https://dbainsight.com/2026/02/oracle-weblogic-14c-installation-on-linux
#   Confirmed against a real 100-500-concurrent-session production host
#   (internal reference: gpiwls01) for shmmax/shmall/sem/shmmni/file-max/
#   aio-max-nr/rmem/wmem — see rationale table below.

# Shared memory – required by Oracle Universal Installer (WLS SYSRS)
kernel.shmmax         = 8318808064
kernel.shmall         = 2030959
kernel.sem            = 250 32000 100 128
kernel.shmmni         = 4096

# File handles and async I/O
fs.file-max           = 6815744
fs.aio-max-nr         = 1048576

# Network buffers (WLS / Forms / Reports with many concurrent sessions)
net.core.rmem_default = 262144
net.core.rmem_max     = 4194304
net.core.wmem_default = 262144
net.core.wmem_max     = 4194304

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

**IPv6 per interface:** `net.ipv6.conf.default` only applies to interfaces
created *after* it was set – an interface that already exists keeps its own
value, and NetworkManager re-enables IPv6 on its connections (`ipv6.method`).
Seen at a customer (2026-10-15): `all=1`, `default=1`, but `ens33=0` with an
`fe80::` address – the JVMs listened via the IPv6 stack (`[::ffff:127.0.0.1]:5556`).
`01-root_os_baseline.sh` therefore also checks every interface and with
`--apply` sets it at runtime and makes it persistent via NetworkManager:

```bash
sysctl -a 2>/dev/null | grep -E "net.ipv6.conf.*.disable_ipv6"   # every interface must be 1
ip -6 addr show                                                  # no output = IPv6 really off
sysctl -w net.ipv6.conf.<if>.disable_ipv6=1                      # runtime
nmcli -g GENERAL.CONNECTION device show <if>                     # connection name
nmcli connection modify "<connection>" ipv6.method disabled      # persistent (next activation/boot)
```

Restart the WLS/Reports JVMs afterwards – they bind their network stack at start.


### Parameter rationale

> **Provenance note:** `shmmax`, `shmall`, `sem`, `shmmni`, `file-max`,
> `aio-max-nr`, and `rmem`/`wmem` below are taken directly from a real
> production Forms/Reports host handling 100-500 concurrent sessions
> (internal reference: `gpiwls01`), not from generic Oracle documentation
> defaults. Earlier versions of this doc incorrectly labelled `kernel.sem`,
> `kernel.shmmni`, `fs.aio-max-nr`, and `net.core.rmem/wmem` as
> "Database only, not needed for WLS" — the real reference host (pure
> WLS/Forms/Reports, no local database) has all of them explicitly tuned,
> so that was wrong. See `docs/03-root_user_oracle.md` for the matching
> ulimit values from the same host, and `docs/01-setup-interview.md` for
> the `EXPECTED_SESSIONS`-driven nofile/nproc tiering (only nofile/nproc
> scale with session count — the sysctl values here are a single fixed
> target, not session-tiered).

| Parameter | Value | Source | Rationale |
|---|---|---|---|
| `kernel.shmmax` | `8318808064` | real production host (gpiwls01) | Max shared memory segment size; required by OUI |
| `kernel.shmall` | `2030959` | real production host | Total shared memory pages |
| `kernel.sem` | `250 32000 100 128` | real production host | SysV semaphores — WLS/Forms/Reports native processes use these too, not DB-only |
| `kernel.shmmni` | `4096` | real production host | Shared memory segment count |
| `fs.file-max` | `6815744` | real production host | System-wide open file handle ceiling; `os_check.sh` already read/displayed this without anything setting it until now |
| `fs.aio-max-nr` | `1048576` | real production host | Async I/O request limit |
| `net.core.rmem_default` / `rmem_max` | `262144` / `4194304` | real production host | Socket receive buffer sizing for many concurrent connections |
| `net.core.wmem_default` / `wmem_max` | `262144` / `4194304` | real production host + symmetric adjustment | Socket send buffer sizing; `wmem_max` raised to match `rmem_max` symmetrically (gpiwls01 itself has an asymmetric `1048576`, but a ~1000-session community sizing reference recommends matching `rmem_max` — adopted here as the more conservative choice) |
| `net.ipv4.ip_local_port_range` | `9000 65500` | Best practice | WLS / HTTP connections need many ephemeral ports |
| `vm.swappiness` | `10` | JVM best practice | Prefer RAM over swap for JVM heap |
| `fs.suid_dumpable` | `1` | Core dump requirement | Required so oracle user (non-root) produces core files |
| `kernel.core_uses_pid` | `1` | Core dump | Append PID to core filename (avoid overwrites) |
| `kernel.core_pattern` | `/var/tmp/core/...` | Core dump | Central directory; Forms/JVM dumps stay visible |
| `kernel.panic_on_oops` | `1` | Server stability | Force clean restart on kernel oops |
| `vm.min_free_kbytes` | — | **not set** | Heavy DB tuning – not needed for WLS |

> **Not configured on purpose:** `kernel.pid_max` (process ID ceiling) and
> `net.core.somaxconn` (listen backlog), both sometimes recommended for
> high-session-count Forms deployments, and the `as` (virtual address
> space) ulimit are **already at a sufficient value by default on Oracle
> Linux 9** (`kernel.pid_max` defaults to `4194304`, `net.core.somaxconn`
> to `4096`, and no distro caps `ulimit -v`) — verified directly on a live
> OL9.7 host. Explicitly setting them here would be a no-op; if you're on
> an older OS or a hardened image that lowers these, check them manually
> rather than assuming this project's scripts cover them.

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
- **DNF repositories:** checks that the Oracle Linux base / AppStream repos and
  Oracle EPEL (`ol9_developer_EPEL`, for `nmon`) are enabled. EPEL with
  `--apply` (question): a configured but disabled EPEL repo (cloud images) is
  enabled with `dnf config-manager --set-enabled`, a missing one is added with
  `oracle-epel-release-el<N>`. `02-root_os_packages.sh` offers the same if this
  step was skipped, and no longer aborts when `nmon` is unavailable.
- **Kernel parameters file:** `--apply` writes exactly the block above (same
  values as the script's check). Until 2026-10-29 the script wrote an older
  block (`shmmax=4294967295`, without `sem`/`shmmni`/`file-max`/`aio-max-nr`/
  `rmem`/`wmem`) – hosts installed before: re-run `--apply --only kernel`.
- **OS update:** `dnf check-update`; with `--apply` it asks for
  `dnf upgrade --refresh` (reboot after a kernel update). `--skip-update` skips
  the section – use it on a running system (e.g. `--only firewall,ssh`)
- **/dev/shm (tmpfs):** minimum size checked; `--apply` offers to write
  `tmpfs /dev/shm tmpfs rw,nosuid,nodev,exec,size=<n>M 0 0` into `/etc/fstab` and remounts.
  **`noexec`** (CIS hardening of cloud images) = FAIL – the JVM needs exec there.
  `--apply` (or `--apply --only shm`) replaces `noexec` by `exec` on the
  `/dev/shm` fstab line (`nosuid`, `nodev` stay; backup `/etc/fstab.bak_<ts>`)
  and runs `mount -o remount,exec /dev/shm` – no reboot. By hand:
  ```bash
  sed -i -E '/^[^#]*[[:space:]]\/dev\/shm[[:space:]]/ s/(^|[[:space:],])noexec([,[:space:]]|$)/\1exec\2/' /etc/fstab
  systemctl daemon-reload && mount -o remount,exec /dev/shm && findmnt /dev/shm
  ```
  `/tmp` with `noexec` (same CIS item) is only reported (WARN): OUI / OPatch run
  extracted helpers from the temp dir → use `TMPDIR=$ORACLE_BASE/tmp` and
  `-Djava.io.tmpdir=$ORACLE_BASE/tmp` (as `05-oracle_patch_weblogic.sh` does).
- **Transparent HugePages (THP):** Disabled via `grubby` (`transparent_hugepage=never`)
  — required to avoid JVM GC pause spikes caused by THP merging/splitting
- **Swap space:** ≥ 512 MB required by OUI prereq check; `--apply` creates a 2 GB
  swapfile under `$ORACLE_BASE/swapfile` if no swap is present (see section above)
- **Firewall:** (details and the safe activation: section "Firewall and SSH hardening" below) Ports 80 and 443 opened; WLS ports (7001, 9001, 9002) and Node Manager
  port 5556 must remain closed externally (Nginx is the only external entry point).
  For Reports (`INSTALL_COMPONENTS` with REPORTS): **UDP `REPORTS_BROADCAST_PORT`**
  (default 14027) is opened – the Reports server sends a multicast discovery packet
  (`228.5.6.7`) at start and must *receive* packets, otherwise it stops with
  `REP-50600 Broadcasting is disabled` and the Node Manager restarts it in a loop
  (customer 2026-10-15). The port must match the one `13-oracle_setup_reports.sh`
  writes into the three `rwnetwork.conf` files and be unique per environment in
  the subnet (14021–14030, Doc ID 437228.1). `13-` checks it again.
- **Sysctl conflict detection:** The script scans all `/etc/sysctl.d/*.conf` and
  `/etc/sysctl.conf` for values that differ from the WLS target. Behaviour is
  controlled by `LOCAL_REP_DB` in `environment.conf` (see section above)

---

## Firewall and SSH hardening (01-root_os_baseline.sh, sections 8 + 9)

Background – why only Nginx is reachable from outside and every internal
socket is on 127.0.0.1: [clone_golden_image.md](../../80-FMW-Architecture/clone_golden_image.md),
[how the parts are joined](../../80-FMW-Architecture/weblogic_middleware_architecture.md#6-how-the-parts-are-joined);
the Reports UDP port: [discovery – prerequisites on the host](../../80-FMW-Architecture/reports_server_discovery_multicast.md#5-prerequisites-on-the-host);
`frmweb` has no bind option: [forms_runtime_architecture.md §1](../../80-FMW-Architecture/forms_runtime_architecture.md#1-the-parts).

Why (found 2026-10-19 by `10-Monitoring/cve_inventory.sh` on the test host):
firewalld was installed but disabled. ~50 prestarted `frmweb`, `rwserver`,
the Reports engines and WLS Coherence listen on all interfaces – without a
host firewall they are reachable past Nginx. Patching closes known holes;
the firewall closes everything that does not need to be reachable.

### Target state

```
                 network
                    │
        ┌───────────┴─────────────────────────────────────────────┐
        │ firewalld, zone public (ens…), default: drop the rest     │
        │   ssh      22/tcp     admin + oracle only (sshd, see 9)   │
        │   http     80/tcp  ─┐                                     │
        │   https   443/tcp  ─┴─► Nginx ─► WLS 127.0.0.1:7001/9001/ │
        │                                      9002                 │
        │   14027/udp  Reports multicast discovery (REP-50600)      │
        │   1521/tcp   only if the repository DB must be reachable  │
        │              from other hosts (LOCAL_REP_DB=true – report │
        │              only, never opened automatically)            │
        │   NOT open: frmweb / rwserver / engine / Coherence ports, │
        │             7001/9001/9002/5556, cockpit 9090             │
        └───────────────────────────────────────────────────────────┘
   outgoing: not filtered by firewalld (MOS downloads, CVE watch, NTP …)
   lo:       always allowed – WLS → DB on the own host address uses lo

Background: why 14027/udp – [reports_server_discovery_multicast.md §5](../../80-FMW-Architecture/reports_server_discovery_multicast.md#5-prerequisites-on-the-host);
why the `frmweb` ports must stay closed – every Forms runtime listens on an
ephemeral port on all interfaces ([forms_runtime_architecture.md §1](../../80-FMW-Architecture/forms_runtime_architecture.md#1-the-parts)).
```

Apply only these two sections on a running system (all others stay
check-only – no kernel / SELinux / swap questions):

```bash
./09-Install/01-root_os_baseline.sh --apply --skip-update --only firewall,ssh
```

Section keys for `--only`: `selinux,repos,update,kernel,thp,shm,swap,core,firewall,ssh`.

### 8. Firewall

Check (always): firewalld running/enabled, default zone, `ssh` / 80 / 443 /
`REPORTS_BROADCAST_PORT`/udp in the zone, WLS + Node Manager ports closed,
services that are not needed (`cockpit`).

`--apply` with firewalld **not running** (question, default **no** – it is
the step that can cut connections):

1. Pre-check: `ssh` must be in the permanent default zone (it is in the OL9
   default `public` zone) – otherwise abort.
2. **Safety net:** `systemd-run --on-active=${FIREWALL_ROLLBACK_MIN:-10}min
   --unit=ihw-fw-rollback systemctl stop firewalld` – if the session is
   lost, the firewall stops by itself after 10 minutes.
3. `systemctl start firewalld`; add `http`, `https`,
   `REPORTS_BROADCAST_PORT/udp` **permanent and runtime**.
4. Question "new ssh login in a second window works?" – yes: `systemctl
   enable firewalld`, rollback timer removed. No / no answer: the timer stops
   the firewall.

`--apply` with firewalld running: as before, open missing 80/443/udp
(question each), plus: remove `cockpit` from the zone (question, default
no) – `FIREWALL_REMOVE_SERVICES` in `environment.conf` (default `cockpit`).

### 9. SSH hardening (sshd)

Only if `SSH_ALLOW_USERS` is set in `environment.conf` – otherwise check
only. At customers admins often log in via AD / LDAP groups: there use your
own users or switch to `AllowGroups` by hand, never activate blindly.

| Variable | Meaning | Test host |
|---|---|---|
| `SSH_ALLOW_USERS` | users allowed to log in via ssh (`AllowUsers`) | `admin oracle` |
| `SSH_PASSWORD_USERS` | users that keep password login (emergency access without key) – all others key only | `admin oracle` |

Files (OL9 / OpenSSH 9: the **first** value of a keyword wins, the main
`sshd_config` includes `sshd_config.d/*.conf` at the top):

```
/etc/ssh/sshd_config.d/10-ihw-hardening.conf   – before Red Hat's 50-redhat.conf
    PermitRootLogin no
    MaxAuthTries 3
    X11Forwarding no            # no GUI over ssh on a server – everything by script
    AllowUsers admin oracle
    PasswordAuthentication no
/etc/ssh/sshd_config.d/99-ihw-match.conf       – Match must come last
    Match User admin,oracle
        PasswordAuthentication yes
```

Not changed on purpose: `AllowTcpForwarding yes` (VS Code Remote-SSH
tunnels through it), `LoginGraceTime 0` in the OL9 `sshd_config` (Oracle's
mitigation for CVE-2024-6387 "regreSSHion"), sftp subsystem.

A `Match` block in an included file ends with that file (**confirmed
(live)** with OpenSSH 9.9, `sshd -T -C user=…`): admin gets password, oracle
and root do not, `Subsystem sftp` from the main file stays valid.

`--apply`:
1. Pre-check: every user in `SSH_ALLOW_USERS` exists; every user **not**
   in `SSH_PASSWORD_USERS` has `~/.ssh/authorized_keys` – otherwise abort
   (it would lock that user out).
2. Backup of the existing drop-ins, write both files, `sshd -t` – on error
   the files are removed again.
3. Safety net `systemd-run --on-active=10min --unit=ihw-ssh-rollback`
   (removes the two files, reloads sshd), then `systemctl reload sshd` –
   **existing sessions stay**.
4. `sshd -T -C user=<each>` shows the effective values; question "new login
   as every allowed user in a second window works?" – yes: timer removed.

Always keep a console session (VMware / vSphere / iLO) open while testing.

### Live test on the test host (2026-10-19, **confirmed (live)**)

`01-root_os_baseline.sh --apply --skip-update --only firewall,ssh`, VS Code
session and a VM console session open:

- firewalld was installed but disabled; started with the 15-min rollback
  timer; zone `public` got http, https, 14027/udp (ssh was already there).
  From the Windows client: `Test-NetConnection … -Port 443` → True,
  `-Port 9001` → False; Forms URL in the browser and a new ssh login
  (MobaXterm) worked; outgoing HTTPS (Claude, MOS) unaffected; WLS
  `/weblogic/ready` 200 on 7001/9001/9002, Reports engines IDLE, no
  REP-50600, DB on the own host address still reachable (via `lo`).
  Confirmed → `systemctl enable firewalld`, timer removed.
- sshd: first run `SSH_PASSWORD_USERS=admin`, then changed to
  `admin oracle` (oracle keeps password login too) – re-run rewrote
  `99-ihw-match.conf` and set a new rollback timer; new logins as admin and
  oracle worked, root refused. `sshd -T -C user=…`: admin/oracle password yes,
  root no, X11 no for all.
- `cockpit` removed from the zone afterwards (not needed on an FMW server; service was inactive anyway).
- Found on the way: `02-Checks/os_check.sh` reported a running firewalld as
  "not running" (`firewall-cmd --state` needs root) and rated "no firewall"
  as OK – fixed (systemctl, WARN without firewall). Same fix in
  `10-Monitoring/cve_inventory.sh`.

### Manual (without the script)

```bash
# firewall – with safety net
systemd-run --on-active=10min --unit=ihw-fw-rollback systemctl stop firewalld
systemctl start firewalld
firewall-cmd --permanent --add-service=http --add-service=https --add-port=14027/udp
firewall-cmd --reload
#   ... new ssh login in a second window ...
systemctl enable firewalld && systemctl stop ihw-fw-rollback.timer

# sshd
sshd -t && systemctl reload sshd
sshd -T -C user=oracle,host=x,addr=10.0.0.1 | grep -E 'passwordauth|x11|permitroot|allowusers'
```

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

# Firewall – Nginx ports open, WLS ports closed, Reports discovery UDP open
firewall-cmd --list-ports
# Expected: 80/tcp 443/tcp 14027/udp  (and NOT 7001 9001 9002 5556)

# IPv6 off on every interface
sysctl -a 2>/dev/null | grep -E "net.ipv6.conf.*.disable_ipv6"
# Expected: all lines "= 1" (lo may stay as is)
```

---

## References

| Topic | URL |
|---|---|
| Oracle WebLogic 14c Installation on Linux – practical guide with sysctl values | https://dbainsight.com/2026/02/oracle-weblogic-14c-installation-on-linux |
| Oracle WebLogic Server 14.1.1 System Requirements and Specifications (kernel.shmmax) | https://docs.oracle.com/en/middleware/standalone/weblogic-server/14.1.1.0/sysrs/system-requirements-and-specifications.html#GUID-D72CDA83-940D-497C-96EF-0BEB97D3A991 |
