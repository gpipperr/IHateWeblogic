# Step 0 – 00-root_db_os_baseline.sh

**Script:** `60-RCU-DB-19c/00-root_db_os_baseline.sh`
**Runs as:** `root`
**Phase:** OS preparation — run before any Oracle software installation

---

## Strategy: oracle-database-preinstall-19c

The Oracle preinstall RPM handles the bulk of OS configuration automatically:

```bash
dnf install -y oracle-database-preinstall-19c
```

This single package sets:
- Required sysctl kernel parameters
- /etc/security/limits.d/oracle-database-preinstall-19c.conf (user limits)
- Required OS packages (gcc, libaio, compat-libs, …)
- oracle user and oinstall/dba/oper groups (if not already present)
- /etc/pam.d/login: session pam_limits.so

After the RPM runs, the script applies **corrections and additions** —
specifically the parameters that differ from the WLS-baseline or that the
RPM does not set.

---

## Kernel Parameters

Written to `/etc/sysctl.d/60-oracle-db.conf` (separate from the FMW file
`/etc/sysctl.d/99-oracle-fmw.conf` to make the two responsibilities visible).

### DB-specific parameters (not set by FMW baseline)

| Parameter | Value | Reason |
|---|---|---|
| `fs.aio-max-nr` | `3145728` | Async I/O — Oracle DB direct I/O |
| `fs.file-max` | `6815744` | Max open file handles (DB needs far more than WLS) |
| `vm.min_free_kbytes` | `524288` | Prevent OOM during large SGA operations |
| `kernel.sem` | `250 32000 100 128` | Semaphores for Oracle background processes |
| `kernel.msgmax` | `65536` | IPC message size |
| `kernel.msgmnb` | `65536` | IPC message queue size |
| `net.core.rmem_default` | `262144` | Oracle Net receive buffer |
| `net.core.rmem_max` | `4194304` | Oracle Net receive buffer max |
| `net.core.wmem_default` | `262144` | Oracle Net send buffer |
| `net.core.wmem_max` | `1048576` | Oracle Net send buffer max |
| `fs.suid_dumpable` | `1` | Allow core dumps for setuid Oracle binaries |
| `kernel.core_uses_pid` | `1` | Include PID in core file name |
| `kernel.core_pattern` | `/var/tmp/core/coredump_%h_.%s.%u.%g_%t_%E_%e` | DB diagnostic core path |

### shmmax / shmall — the same-host conflict

`09-Install/01-root_os_baseline.sh` sets intentionally smaller values for
WLS OUI compatibility (see comment in that script).  The Oracle preinstall
RPM and this script set DB-sized values.

**On same host:** this script runs AFTER `09-Install/05-oracle_install_weblogic.sh`
has completed.  The FMW software is already installed; WLS runtime does not
require the smaller values.

| Parameter | FMW baseline | DB baseline | Notes |
|---|---|---|---|
| `kernel.shmmax` | `4 294 967 295` | `(RAM_bytes / 2)` | Dynamically calculated; typically 2–8 GB |
| `kernel.shmall` | `9 272 480` | `(RAM_pages / 2)` | Dynamically calculated in pages (4 096 B) |

The script calculates shmmax/shmall from actual RAM:
```bash
RAM_BYTES=$(awk '/MemTotal/ { print $2 * 1024 }' /proc/meminfo)
SHMMAX=$(( RAM_BYTES / 2 ))      # half of total RAM
SHMALL=$(( SHMMAX / 4096 ))      # in 4 kB pages
```

Minimum enforced: `SHMMAX=2147483648` (2 GB), even if RAM is smaller.

### Parameters already set by FMW baseline (not duplicated here)

The following are already in `/etc/sysctl.d/99-oracle-fmw.conf` and are
identical for DB use — this script does **not** set them again:

- `net.ipv4.ip_local_port_range = 9000 65500`
- `kernel.panic_on_oops = 1`
- `transparent_hugepage=never` (GRUB cmdline, set by FMW script)

---

## User Limits

Written to `/etc/security/limits.d/60-oracle-db.conf`:

```
oracle  soft  nofile    131072
oracle  hard  nofile    131072
oracle  soft  nproc     131072
oracle  hard  nproc     131072
oracle  soft  core      unlimited
oracle  hard  core      unlimited
oracle  soft  memlock   50000000
oracle  hard  memlock   50000000
oracle  soft  stack     10240
```

`memlock` is the key addition vs. the FMW limits — required for HugePages and
large SGA locking.

> Note: On systems using Automatic Memory Management (`MEMORY_TARGET`), the
> `memlock` limit must be ≥ SGA size.  For `MEMORY_TARGET=2G`, 50 000 000 kB
> (~47 GB) is far above the minimum — intentionally safe.

---

## Core Dump Directory

```bash
mkdir -p /var/tmp/core
chmod 1777 /var/tmp/core
```

---

## Transparent Huge Pages

Already disabled by `09-Install/01-root_os_baseline.sh` via grubby.

If running on a dedicated DB server (no FMW baseline run before):
```bash
grubby --update-kernel=ALL --args="transparent_hugepage=never"
```

---

## HugePages (optional, for SGA > 4 GB)

For a minimal FMW RCU database (`MEMORY_TARGET=2G`), HugePages provide no
measurable benefit.  Enable only if the database is also used for other
workloads with SGA > 4 GB.

Formula (if needed):
```bash
# SGA in bytes divided by hugepage size (2 MB)
HUGEPAGES=$(( SGA_BYTES / (2 * 1024 * 1024) + 5 ))
# Add to /etc/sysctl.d/60-oracle-db.conf:
vm.nr_hugepages = $HUGEPAGES
```

When HugePages are active, AMM (`MEMORY_TARGET`) cannot be used.
Switch to: `SGA_TARGET=1536M` + `PGA_AGGREGATE_TARGET=512M`.

---

## What the Script Does

1. Install `oracle-database-preinstall-19c` RPM (creates oracle user, groups,
   base limits, most sysctl params)
2. Calculate shmmax/shmall from actual RAM
3. Write `/etc/sysctl.d/60-oracle-db.conf` (DB-specific additions + overrides)
4. Apply: `sysctl --system`
5. Write `/etc/security/limits.d/60-oracle-db.conf` (oracle user DB limits)
6. Create `/var/tmp/core` with correct permissions
7. Check and report THP status

---

## Flags

| Flag | Description |
|---|---|
| (none) | Dry-run: show calculated values, no changes |
| `--apply` | Apply all OS settings |
| `--help` | Show usage |

---

## Verification

```bash
sysctl kernel.shmmax kernel.shmall kernel.sem fs.aio-max-nr
cat /etc/security/limits.d/60-oracle-db.conf
cat /sys/kernel/mm/transparent_hugepage/enabled   # should show [never]
```
