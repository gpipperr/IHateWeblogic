# Step 0b – 00b-db_cvu_check.sh (standalone CVU)

**Script:** `60-RCU-DB-19c/00b-db_cvu_check.sh`
**Runs as:** `oracle`
**Phase:** after `00-root_db_os_baseline.sh`, before `01-db_install_software.sh`

---

## Purpose

Background – what the RCU database must offer (version, edition,
parameters) beyond the OS check: [rcu_middleware_architecture.md §9](../../80-FMW-Architecture/rcu_middleware_architecture.md#9-database-requirements-for-the-repository-19c--26ai).

Validate the host with Oracle's own checker before `runInstaller` runs,
instead of finding missing packages, kernel parameters or limits only during
the installation. The **Cluster Verification Utility (CVU)** is built for
Clusterware / RAC, but its component checks also work for a single instance
without Clusterware – here: system requirements of a 19c database home.

| | |
|---|---|
| MOS patch | **30839369** "Standalone CVU Platform-specific package supports 21c and 19c" |
| Release | Linux: **26ai (23.26)** (`p30839369_2326000_Linux-x86-64.zip`, build 2026-07, Java 11.0.32, `CV_ASSUME_CL_VERSION=23`); the Windows README of the same patch describes 21cR21 (January 2026) |
| Platform | Linux x86-64 – the MOS patch holds several kits, see below |
| Download page | https://www.oracle.com/database/technologies/cvu-downloads.html |
| FAQ | https://www.oracle.com/database/technologies/cvu-faq.html |

## Download

Automatically with the other MOS patches when the RCU database runs on this
host (`LOCAL_REP_DB=true`, set by `09-Install/01-setup-interview.sh`):

```bash
./09-Install/04-oracle_pre_download.sh --apply --mos
#   -> $PATCH_STORAGE/database/cvu/p30839369_<ver>_Linux-x86-64.zip
```

Separate DB server (`LOCAL_REP_DB=false` on the FMW host): 04- skips the CVU –
download it by hand on the DB host, or temporarily with
`LOCAL_REP_DB=true`, and copy the ZIP into `DB_CVU_DIR` there.

Patch number: `DB_CVU_PATCH_NR` = role `cvu` in `09-Install/download/patches_fmw.csv`.

**The Linux patch holds five ZIPs** (confirmed live 2026-10-27 – 810 MB when
getMOSPatch takes all of them):

| File | Size | Content | Used |
|---|---|---|---|
| `p30839369_2326000_Linux-x86-64.zip` | 133 MB | standalone CVU 26ai (23.26), Java 11.0.32, build 2026-07 | **yes** |
| `p30839369_2326000OCWRU_Linux-x86-64.zip` | 68 MB | 26ai (23.26) variant for OCW RU (Grid) homes | no |
| `cvupack_linux_ol7_x86_64.zip` | 241 MB | 21c kit (build 2024-11) | fallback only |
| `cvupack_host.zip` | 143 MB | 21c host kit (2024-11) | no |
| `cvupack_linux_ol6_x86_64.zip` | 263 MB | 18c kit (2021-08) | no |

`DB_CVU_REGEXP` (`p30839369_[0-9]+_Linux-x86-64\.zip`) restricts getMOSPatch to
the 26ai kit; the script picks the same file (newest version) and falls back
to `cvupack_linux_ol7*.zip` only when it is missing. getMOSPatch compares the
regexp with the file name **without** `.zip` – `04-` strips the trailing
`\.zip` before the call (fixed 2026-10-28; before, the filter never matched and
the download relied on the directory being filled otherwise).
By hand: MOS → patch 30839369 → platform Linux x86-64 → into
`DB_CVU_DIR` (`environment_db.conf`, default `$PATCH_STORAGE/database/cvu`).

## What the script does

| Mode | Action |
|---|---|
| (none) | dry-run: archive found?, free space, the cluvfy command |
| `--apply` | unpack the ZIP into `DB_CVU_HOME` once (default `$ORACLE_BASE/cvu`, ≥ 500 MB free – the 26ai kit needs 280 MB), set `CV_ORACLE_RELEASE=19` in `cv/admin/cvu_config`, disk check (DB home 8 GB, data files 4 GB – README sizing), run `cluvfy comp sys -n <host> -p database -r 19 -fixup -verbose` |

Every `Verifying <item> ...PASSED / WARNING / FAILED` line becomes OK / WARN /
FAIL (with the `PRVF-…` / `PRVG-…` code); the full output is in
`log/<date>/cvu_pre_<time>.txt` / `cvu_post_<time>.txt`.

`-r 19`: the CVU checks against its own release (26ai / 21c) by default; the
script sets both the option and `CV_ORACLE_RELEASE=19`, so a manual `cluvfy`
call in the CV home also checks for 19c.

## Fixups

With `-fixup` CVU writes a root script (`runfixup.sh`) for the items it can
correct. The script only prints its path – **review it, then run it as root
yourself**. The preferred place for OS settings stays
`00-root_db_os_baseline.sh --apply`; a fixup that is needed repeatedly
belongs there.

## Reading the result – expected findings

First live run 2026-10-27 on the test host (Oracle Linux 9, UEK 5.15, CVU
Standalone 23.26.3.0.0, `-r 19`): **45 items, 43 PASSED, 2 FAILED** – both
expected, the script reports them as WARN with the reason:

| Item | CVU message | Why it is expected | Action |
|---|---|---|---|
| (header) | "Reference data is not available for release 19 on … Linux OL9. Using … Linux OL7 reference data." | CVU has no 19c reference data for OL9 yet and checks against OL7 | none – the OL7 package names below follow from it |
| `Package: compat-libcap1-1.10` | PRVF-7532 missing | the package does not exist on OL9; `oracle-database-preinstall-19c` for OL9 does not require it | none |
| `Swap Size` | PRVF-7573 required 16 GB, found 2 GB | CVU rule for RAM > 16 GB (test host 18.6 GB); sized for a full database, the RCU repository runs with SGA 1.5 GB | test host: accept; production: add swap (or size by the DB's real memory) |

PASSED on OL9: memory, `/tmp` space, oracle user / groups `oinstall` + `dba`,
run level, architecture, kernel version, **all kernel parameters**
(sem*, shm*, file-max, ip_local_port_range, rmem / wmem, aio-max-nr – set by
`00-root_db_os_baseline.sh`) and all other packages (binutils, glibc(-devel),
libaio(-devel), libstdc++(-devel), ksh, make, sysstat, smartmontools,
net-tools, kmod). No fixup script was generated ("No fixable verification
failures to fix").

Real errors are everything else: missing kernel parameters / limits (→
`00-root_db_os_baseline.sh --apply`), groups, disk space.

## No post-install check

`cluvfy comp software -d <DB home>` (attributes of the files of an installed
home) was tried after step 1 and does **not** work here (live 2026-10-27):
it has no `-r` option ("Unexpected symbol -r") and without it stops with
**PRVG-11902 "Oracle Clusterware is not configured"** – a cluster-only
check. The installed home is verified by `01-` itself (`opatch lspatches`,
`sqlplus -V`).

## environment_db.conf variables

| Variable | Default | Meaning |
|---|---|---|
| `DB_CVU_DIR` | `${PATCH_STORAGE}/database/cvu` | where 04- stores the CVU ZIP |
| `DB_CVU_HOME` | `${ORACLE_BASE}/cvu` | CV home (unpacked CVU, ≥ 500 MB) |

## Next step

```bash
./60-RCU-DB-19c/01-db_install_software.sh --apply
```
