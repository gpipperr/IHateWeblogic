---
title: "Oracle Forms & Reports 14c Sizing – Disk, Memory"
description: "Disk, memory and process sizing for Oracle Forms & Reports 14.1.2, measured on a test host: Oracle Home, domain, JDK, RCU database homes, patch storage."
---

# Forms & Reports – Sizing (disk, memory, processes)

← Back to the [root README](../README.md)

## Disk Sizing Guide

Measured on the test host on 2026-10-28. That host runs everything on one server and one 99 GB file system: Forms + Reports domain, local RCU database 19c, APEX + ORDS, patch storage. It is **92 GB full** right after the out-of-place DB patch, with the old and the new DB home side by side. Plan for the **peak during patching**, not for the steady state.

| Area | Path (default) | Measured | Plan for | Why |
|---|---|---|---|---|
| **FMW Oracle Home** (WLS + Forms & Reports, patched) | `$ORACLE_HOME` (`$ORACLE_BASE/fmw`) | 6.8 GB | **12 GB** | OPatch keeps roll-back copies in `.patch_storage` – grows with every cycle (SPB, bundles, QPRs) |
| FMW patching workspace | SPB unpacked outside the home | – | **+5 GB** temporary | WLS Stack Patch Bundle README: ≥ 4 GB outside the Oracle Home |
| **Domain** | `$DOMAIN_HOME` | 2.0 GB | **5 GB** | server logs, Reports cache / output, Forms temp; rotation in `07-Maintenance` |
| JDK | `$ORACLE_BASE/java` | 1.0 GB | **2 GB** | old + new JDK side by side during an update (junction / symlink switch) |
| **RCU DB home** | `$ORACLE_BASE/product/<ru>/db_home1` | 12 GB per home | **2 × 12 = 24 GB** | out-of-place patch: new home (19.33 gold image + OJVM / Data Pump / JDK = 11 GB) next to the running one until the old one is removed ([09-db_patch_rcu.md](../60-RCU-DB-19c/docs/09-db_patch_rcu.md)) |
| DB data files | `DB_DATA_DIR` (`$ORACLE_BASE/oradata`) | 9.3 GB | **15 GB** | CDB + PDB + RCU schemas (67 MB) + APEX; datapatch / `utlrp` grow SYSTEM / SYSAUX |
| DB admin / diag / FRA | `admin`, `diag`, `flash_recovery_area` | 0.6 GB | **3 GB** | Data Pump dumps before a patch, audit, alert / trace; FRA only with ARCHIVELOG (then much more) |
| **AutoUpgrade staging** | `DB_AUTOUPGRADE_HOME` | 7.9 GB | **8 GB**, AutoUpgrade download **+10 GB** | gold image 4.9 GB + OneOffs + OPatch; only an AutoUpgrade download also unpacks the 19.3 base ZIP (3 GB ZIP + 6.6 GB `base_stage`) – with the patch set local (offline route / gold image) no `base_stage` |
| APEX / ORDS / Instant Client | `product/apex`, `ords_*`, `instantclient*` | 1.6 GB | **3 GB** | two ORDS homes for an ORDS switch |
| **Patch storage** | `PATCH_STORAGE` (`/srv/patch_storage`) | 20 GB | **30 GB** | base installers (WLS 4.2, F&R 2.7 GB), current patch set 3.8 GB **+ archived previous set** (6.5 GB, `04- --fresh-patches`), client Java 1.1 GB, APEX / ORDS / SQLcl |
| OS / swap / tmp | `/`, `swapfile`, `/tmp` | ~15 GB | **20 GB** | swap file 2 GB, `/tmp` for installers and OPatch |
| `/boot` | own partition | 624 MB of 960 MB (6 kernels) | **3 GB** | the installer default 1 GiB holds only about three kernels – see [OS disk layout](#os-disk-layout--boot-3-gb-not-the-installer-default) |

**Totals:**

| Setup | Plan for |
|---|---|
| FMW only (RCU DB on another server) | **~75 GB**: FMW 12 + 5 workspace + domain 5 + JDK 2 + patch storage 30 + OS 20 – the patch storage can be shared or on a separate disk |
| RCU DB server only | **~80 GB**: 2 homes 24 + data 15 + admin 3 + AutoUpgrade 18 + OS 20 |
| **Everything on one host** (like the test host) | **≥ 140 GB** (sum of the plan column: 137 GB). Better split: `/u01` ≥ 90 GB, `/srv/patch_storage` 30–40 GB, OS 20 GB. 100 GB is already too tight while a DB patch runs. |

### OS disk layout – `/boot` 3 GB, not the installer default

The Oracle Linux installer creates a **1 GiB `/boot`** (XFS shows about
**960 MB** usable). That holds only about three kernels – too little for a
host that gets `dnf update` every month. At a customer `dnf update` stopped on
2026-11-17 because `/boot` was full.

Measured on the test host (Oracle Linux 9.8, 2026-11-17): **624 MB of 960 MB
used**.

| In `/boot` | Size each | On the test host |
|---|---|---|
| UEK kernel: `vmlinuz` + `initramfs` + `initramfs…kdump` (+ `config`, `System.map`) | ≈ **100 MB** (14 + 38 + 43 MB + small files) | 3 × (`kernel-uek` 5.15.0-317 / -318 / -325) |
| Red Hat compatible kernel (RHCK): `vmlinuz` + `initramfs` | ≈ **60 MB** (15 + 39 MB + small files), more with its own kdump image | 3 × (`kernel` 5.14.0-611.36 / -611.38 / -687) |
| rescue image `initramfs-0-rescue-*` | 77 MB | 1 |

Why it fills up:
- `installonly_limit=3` in `/etc/dnf/dnf.conf` counts **per package name**:
  three `kernel-uek` **and** three `kernel` (RHCK) – both are installed by
  default.
- During `dnf update` the **new** kernel is installed before the oldest one
  is removed: for a moment four of each, plus the space `dracut` needs to
  build the new initramfs.
- Every UEK generation brings bigger images (UEK 8 / kernel 6.12 more than
  UEK 7).

Recommended layout for a new Forms & Reports host (Oracle Linux 8 / 9):

| Mount | Size | Note |
|---|---|---|
| `/boot` | **3 GB** (XFS, normal partition) | room for UEK + RHCK with kdump and the update peak |
| `/boot/efi` | 600 MB | only with UEFI (installer default) |
| `/` | 20 GB (LVM) | OS, `/tmp` for installers and OPatch; or `/var` / `/tmp` as own LVs |
| swap | 2–4 GB (LV or swap file) | |
| `/u01` (`ORACLE_BASE`) | ≥ 25 GB FMW only, ≥ 90 GB with a local RCU DB | see the table above |
| `/srv/patch_storage` | 30–40 GB | can be shared / NFS |

Keep free extents in the volume group: an LV grows online, `/boot` (a plain
partition in front of the LVM) does not – enlarging it later means moving
partitions, in practice a new disk layout. So set it at the installation.

**An existing host with the 960 MB `/boot`** – make room instead of resizing:

```bash
df -h /boot

uname -r
# the running kernel - never remove it

rpm -q kernel-uek kernel-core

dnf remove --oldinstallonly --setopt installonly_limit=2 kernel-uek
# keeps the two newest UEK kernels (the running one included)
```

- Only UEK in use (the default boot entry)? The RHCK kernels can go too
  (`dnf remove --oldinstallonly --setopt installonly_limit=1 kernel-core`) –
  keep at least one as a fallback if the operations team wants it.
- `installonly_limit=2` in `/etc/dnf/dnf.conf` keeps it that way for the next
  updates.
- Check `df -h /boot` before every `dnf update`: at least 300 MB free.

**Cloned VMs: the rescue image of the source.** A VM clone carries the
rescue image of the template (`initramfs-0-rescue-<machine-id>.img` +
`vmlinuz-0-rescue-…`, about 90 MB – 77 + 13 MB on the test host). Once the
clone has its own machine-id, the next kernel update builds a **second**
rescue image for the new ID; the old one stays. That alone can fill a 960 MB
`/boot`. So:
- in the template: delete the rescue image, or switch it off with
  `dracut_rescue_image="no"` in `/etc/dracut.conf.d/02-rescue.conf`;
- in the clone workflow: after the new machine-id remove
  `/boot/*0-rescue-<old-id>*` and `/boot/loader/entries/<old-id>-0-rescue.conf`
  ([clone cookbook step 4.5](../70-Customer-Projects/FormsReports14_linux_clone/README.md)).

Rules:

- Check free space **before** every patch run. [`01-db_install_software.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/01-db_install_software.sh) and [`09-db_patch_rcu.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/09-db_patch_rcu.sh) check it first and stop on FAIL; the FMW patch scripts `81-` / `82-` need the SPB workspace.
- Each cycle: remove the old DB home after a few days of stable operation (`deinstall`, about 12 GB). Archived patch sets in `PATCH_STORAGE` older than one cycle can go too. Clean up `.patch_storage` of the FMW home only with `opatch util cleanup` (never by hand).
- Small local disk: keep the patches in an NFS/ZFS archive (`PATCH_ARCHIVE`) and pull only the next step's files – `07-Maintenance/patch_storage.sh pull <step> --apply` / `clean --apply`; find the space eaters with [`70-Customer-Projects/tools/bash/check_disk_space.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/tools/bash/check_disk_space.sh).
- Logs and backups grow without limit unless rotated: `07-Maintenance` (`backup_config.sh --keep`, [`bak_cleanup.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/bak_cleanup.sh)), the domain log rotation and the Data Pump dumps of `rcu_repository_check.sh --apply`.

## Memory and process settings

Added 2026-11-11: the memory and process rules of the library in one place.
Each row names its source; the values themselves are set and checked by the
scripts there – nothing new is defined here.

| Area | Rule (library) | Status | Source / script |
|---|---|---|---|
| **Forms sessions** `maxRuntimeProcesses` | half of `MemTotal` for Forms (the other half: OS, WebLogic heaps, Reports engines, a local DB), divided by **64 MB per session under load**, rounded down to tens, at least 20 – test host (18 GB): 140. Oracle's default 0 = no limit "is not recommended" (DoS) | 64 MB is an **assumption**: idle pooled `frmweb` 16 MB RSS, a small test form 39 MB RSS (7 MB private) – measure real sessions | [doc 14 – session limit](../09-Install/docs/14-forms-detail-settings.md#session-limit-maxruntimeprocesses-global-default), [06-FormsDiag](../06-FormsDiag/README.md) ([`forms_perf_analyse.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/06-FormsDiag/forms_perf_analyse.sh), [`forms_perf_settings.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/06-FormsDiag/forms_perf_settings.sh)) |
| **Forms processes** | one `frmweb` OS process per session (not a thread) – drives `nproc` / `nofile` | confirmed | [forms_runtime_architecture.md](../80-FMW-Architecture/forms_runtime_architecture.md), [forms_performance_analyse_tuning.md](../80-FMW-Architecture/forms_performance_analyse_tuning.md) |
| **Reports engines** | heap check: `maxEngine × -Xmx` against MemAvailable + RSS of the running engines (WARN > 80 %); without engine `jvmOptions` the engines run with `-Xmx256M`; `maxEngine` proposal: 5, or peak used + 1, at most 4 × CPUs | confirmed (live 2026-10-19 / 2026-11-11) | [05-ReportsPerformance/README.md](../05-ReportsPerformance/README.md), [reports_engine_architecture.md](../80-FMW-Architecture/reports_engine_architecture.md) |
| **Reports hanging engine** `engineResponseTimeOut` | library default **360 min** (safety net), measured proposal 2 × longest job, at least 5 min | default since 2026-11-11 | [reports_engine_architecture.md §6](../80-FMW-Architecture/reports_engine_architecture.md), [`engine_perf_settings.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/05-ReportsPerformance/engine_perf_settings.sh) |
| **WebLogic heaps** (AdminServer, WLS_FORMS, WLS_REPORTS) | heap per server in `setUserOverrides.sh` (Oracle's `-Xmx512m` in `setDomainEnv.sh` is overridden); the runtime `-Xmx` of every running server is rated | set by `09-`, checked by [`weblogic_performance.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/weblogic_performance.sh) | [02-Checks/README.md](../02-Checks/README.md) (`weblogic_performance.sh`, [`java_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/java_check.sh)), [09-oracle_configure.md](../09-Install/docs/09-oracle_configure.md) |
| **ORDS** (if APEX runs beside Forms) | `ORDS_JAVA_HEAP` (default `2G`, `-Xms` = `-Xmx`) | interview value | [12-APEX-Ords/README.md](../12-APEX-Ords/README.md) |
| **ulimit** `nofile` / `nproc` | sized by `EXPECTED_SESSIONS`: 65536–131072 (soft = hard); the `100-500` tier (81920) is confirmed on a production host, the other tiers are estimates; `memlock` 3145728, `core` 2097152 blocks | partly confirmed | [03-root_user_oracle.md](../09-Install/docs/03-root_user_oracle.md), [00-root_set_os_parameter.md](../09-Install/docs/00-root_set_os_parameter.md) |
| **sysctl** (shm, sem, network buffers) | one fixed target from a production host with 100–500 sessions – not session-tiered | confirmed reference values | [00-root_set_os_parameter.md](../09-Install/docs/00-root_set_os_parameter.md) |

RAM in one sentence: Forms gets about half of the RAM (sessions × 64 MB),
the rest carries the OS, the three WebLogic heaps, the Reports engines
(`maxEngine × -Xmx`) and – on a single host – the RCU database and ORDS.
Measure under real load before raising `maxRuntimeProcesses` or `maxEngine`
([`06-FormsDiag/forms_perf_analyse.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/06-FormsDiag/forms_perf_analyse.sh), [`05-ReportsPerformance/engine_perf_analyse.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/05-ReportsPerformance/engine_perf_analyse.sh)).
