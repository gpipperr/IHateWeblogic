---
title: "Oracle 19c OS Baseline for the RCU Database (OL9)"
description: "Step 0 of the RCU database on Oracle Linux 9 as root: preinstall RPM, kernel parameters, user limits, transparent huge pages and core dumps for Oracle 19c."
---

# Step 0 – 00-root_db_os_baseline.sh

**Script:** [`60-RCU-DB-19c/00-root_db_os_baseline.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/00-root_db_os_baseline.sh)
**Runs as:** `root` – started as `oracle` it re-runs itself via `sudo`
**Phase:** OS preparation — before [`01-db_install_software.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/01-db_install_software.sh); on a shared
FMW + DB host after the FMW software install (`09-Install/05-`/`06-`)
**Requires:** `environment.conf` (FATAL otherwise: "Run first:
09-Install/01-setup-interview.sh --apply") – this root script reads only
`environment.conf`, not `environment_db.conf`

Next step: [`00b-db_cvu_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/00b-db_cvu_check.sh) – host pre-check with the standalone CVU
([00b-db_cvu_check.md](00b-db_cvu_check.md)). Background – the RCU database and
what the FMW schemas need: [rcu_middleware_architecture.md §9](../../80-FMW-Architecture/rcu_middleware_architecture.md#9-database-requirements-for-the-repository-19c--26ai).

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

After the RPM runs, the script applies **additions** — groups, packages,
its own sysctl / limits files, core directory, the OL9 linker stub and the
inventory pointer. A failed RPM install stops the script.

---

## Kernel Parameters

Written to `/etc/sysctl.d/60-oracle-db.conf` (separate from the FMW file
`/etc/sysctl.d/99-oracle-fmw.conf` to make the two responsibilities visible),
rewritten on every `--apply` (backup first), then `sysctl --system`.

### Effective values: the last file wins

`sysctl --system` loads `/etc/sysctl.d/*.conf` in lexical order – a key set
in several files gets the value of the **last** one. `60-oracle-db.conf` sorts
**before** `99-oracle-fmw.conf` (FMW baseline) and
`99-oracle-database-preinstall-19c-sysctl.conf` (preinstall RPM), so their
values win for keys set there too (test host 2026-11-02: effective
`kernel.shmmax` 4398046511104 and `fs.aio-max-nr` 4194304 from the preinstall
RPM, `net.core.wmem_max` 1048576). Since 2026-10-29 the FMW baseline sets most
of these keys itself, with `LOCAL_REP_DB=true` its shm values only as
minimums. The values below are what this script writes; check what is
effective:

```bash
sysctl kernel.shmmax kernel.shmall fs.aio-max-nr net.core.wmem_max
grep -H -E 'shmmax|shmall|aio-max-nr|wmem_max' /etc/sysctl.d/*.conf
```

### Parameters written by this script (several also in the FMW baseline / preinstall RPM)

| Parameter | Value | Reason |
|---|---|---|
| `kernel.shmmni` | `4096` | Shared memory segments |
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

### shmmax / shmall

**On a shared host** this script runs AFTER the FMW software install
(`09-Install/05-` / `06-`).

| Parameter | FMW baseline (`99-oracle-fmw.conf`) | This script (`60-oracle-db.conf`) | Notes |
|---|---|---|---|
| `kernel.shmmax` | `8 318 808 064` (minimum when `LOCAL_REP_DB=true`) | `(RAM_bytes / 2)` | 60- is overridden by the 99- files (see above) |
| `kernel.shmall` | `2 030 959` | `shmmax / 4096` | pages (4 096 B) |

The script calculates shmmax/shmall from actual RAM:
```bash
RAM_BYTES=$(awk '/MemTotal/ { print $2 * 1024 }' /proc/meminfo)
SHMMAX=$(( RAM_BYTES / 2 ))      # half of total RAM
SHMALL=$(( SHMMAX / 4096 ))      # in 4 kB pages
```

Minimum enforced: `SHMMAX=2147483648` (2 GB), even if RAM is smaller.

### Parameters only in the FMW baseline (not set here)

The following are in `/etc/sysctl.d/99-oracle-fmw.conf` and are identical for
DB use — this script does **not** set them:

- `net.ipv4.ip_local_port_range = 9000 65500`
- `kernel.panic_on_oops = 1`
- `transparent_hugepage=never` (GRUB cmdline, set by FMW script)

---

## User Limits

Written to `/etc/security/limits.d/60-oracle-db.conf` (user =
`ORACLE_OS_USER`, default `oracle`; rewritten on every `--apply`):

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

> Note: the `memlock` limit must be ≥ the SGA when it is locked (HugePages).
> 50 000 000 kB (~47 GB) is far above the 2 GB SGA of this database —
> intentionally safe.

---

## Core Dump Directory

```bash
mkdir -p /var/tmp/core
chmod 1777 /var/tmp/core
```

---

## Transparent Huge Pages

Already disabled by [`09-Install/01-root_os_baseline.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/01-root_os_baseline.sh) via grubby.

If running on a dedicated DB server (no FMW baseline run before):
```bash
grubby --update-kernel=ALL --args="transparent_hugepage=never"
```

---

## HugePages (optional, for SGA > 4 GB)

For a minimal FMW RCU database (`sga_target` 2 GB, see
[03-db_create_database.md](03-db_create_database.md)), HugePages provide no
measurable benefit.  Enable only if the database is also used for other
workloads with SGA > 4 GB.

Formula (if needed):
```bash
# SGA in bytes divided by hugepage size (2 MB)
HUGEPAGES=$(( SGA_BYTES / (2 * 1024 * 1024) + 5 ))
# Add to /etc/sysctl.d/60-oracle-db.conf:
vm.nr_hugepages = $HUGEPAGES
```

AMM (`MEMORY_TARGET`) is not used by `03-` anyway (`SGA_TARGET` +
`PGA_AGGREGATE_TARGET`), so HugePages need no change of the memory model.

---

## What the Script Does

1. Pre-checks (root, `dnf`); calculate shmmax/shmall from the actual RAM.
   **Dry-run** ends here: it shows RAM / shmmax / shmall, the group
   membership and the files that would be written; RPM, packages, THP and
   `/etc/oraInst.loc` are handled only with `--apply`
2. Install `oracle-database-preinstall-19c` RPM (creates oracle user, groups,
   base limits, most sysctl params)
2b. Add the oracle user to the groups `dba` + `oper` (OSDBA / OSOPER of the
   `01-` response file; groups created if missing). The RPM adds the user to
   them only when it creates the user itself – on an FMW host
   [`03-root_user_oracle.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/03-root_user_oracle.sh) created oracle before with `oinstall` only
   (CVU PRVF-7566 "Group Membership: dba", OS authentication fails). The new
   membership is active only in a **new login** of oracle
3. Install `expect` – AutoUpgrade's MOS keystore setup (`01-` download) is
   scripted with it
4. Install `perl-File-Copy` – OL9 minimal: `opatch` / OJVM `javavm_refresh`
   fails without the Perl module `File::Copy`
5. Write `/etc/sysctl.d/60-oracle-db.conf` (DB-specific additions + overrides),
   `sysctl --system`
6. Write `/etc/security/limits.d/60-oracle-db.conf` (oracle user DB limits)
7. Create `/var/tmp/core` with correct permissions
8. OL9: create an empty stub `libpthread_nonshared.a` if missing – the 19c
   link steps (runInstaller / opatch in `01-`, the manual `uniaud_on` relink
   before `04-`, `09-` for a new home) link against it; glibc 2.34 merged
   libpthread into libc and dropped the archive
9. Check and report THP status
10. Central inventory: `/etc/oraInst.loc` with `inventory_loc=<ORACLE_INVENTORY>`
    (from `environment.conf`, else `$(dirname ORACLE_BASE)/oraInventory`).
    Missing (DB-only host): created, the inventory directory with owner
    `ORACLE_OS_USER:oinstall`, mode 770. On a shared host it must point to the **same** inventory
    as the FMW home – a different value is reported (WARN) and corrected
    with `--apply` **only** when the current inventory holds no homes yet;
    an inventory with registered homes (FMW) is never re-pointed (since
    2026-11-02) – then `ORACLE_INVENTORY` in the config is wrong

---

## Flags

| Flag | Description |
|---|---|
| (none) | Dry-run: show calculated values, no changes |
| `--apply` | Apply all OS settings |
| `--help` | Show usage |

---

## Manual installation (same order as the script, as root)

```bash
dnf install -y oracle-database-preinstall-19c
getent group dba  || groupadd dba
getent group oper || groupadd oper
usermod -aG dba,oper oracle                      # active in a NEW login of oracle
dnf install -y expect perl-File-Copy
vi /etc/sysctl.d/60-oracle-db.conf               # table above; shmmax = RAM/2 (min 2 GB), shmall = shmmax/4096
sysctl --system
vi /etc/security/limits.d/60-oracle-db.conf      # block above
mkdir -p /var/tmp/core && chmod 1777 /var/tmp/core
[ -f /usr/lib64/libpthread_nonshared.a ] || { ar cr /usr/lib64/libpthread_nonshared.a; chmod 644 /usr/lib64/libpthread_nonshared.a; }   # OL9
cat /sys/kernel/mm/transparent_hugepage/enabled  # [never]; else grubby (above)
# DB-only host without /etc/oraInst.loc:
mkdir -p /u01/app/oraInventory && chown oracle:oinstall /u01/app/oraInventory && chmod 770 /u01/app/oraInventory
printf 'inventory_loc=/u01/app/oraInventory\ninst_group=oinstall\n' > /etc/oraInst.loc; chmod 644 /etc/oraInst.loc
```

---

## Verification

```bash
sysctl kernel.shmmax kernel.shmall kernel.sem fs.aio-max-nr   # effective values
grep -H -E 'shmmax|shmall|aio-max-nr' /etc/sysctl.d/*.conf    # which file wins
cat /etc/security/limits.d/60-oracle-db.conf
id oracle                                         # dba + oper
cat /sys/kernel/mm/transparent_hugepage/enabled   # should show [never]
cat /etc/oraInst.loc
```
