# Step 1 – 01-db_install_software.sh

**Script:** `60-RCU-DB-19c/01-db_install_software.sh`
**Runs as:** `oracle`
**Phase:** Install Oracle 19c Database software + patches in one step

---

## Purpose

Install Oracle 19c directly to the **patched** `DB_ORACLE_HOME` (e.g. 19.30.0)
using `runInstaller -applyRU`.  No separate patching step, no `cp -a`.

Flow:
1. Extract the 19.3.0 base ZIP to a staging directory (`base_stage`)
2. Download RU + OJVM + OPatch ZIPs from MOS via AutoUpgrade
   (download is skipped if `patchdir/` already contains ZIPs)
3. Update OPatch in staging; identify the RU dir (`bundle.xml` of a system patch, or `etc/config/inventory.xml` "Database Release Update" of the single DB RU) and OneOffs
4. `runInstaller -applyRU <RU_dir> [-applyOneOffs <OJVM_dir>] -silent`
   → installs directly to `DB_ORACLE_HOME`
5. `root.sh` prompt + `chopt disable olap rat`

`uniaud_on` relink is NOT done here — it runs in `05-db_create_database.sh`
before DBCA (requires the complete DB home).

---

## Prerequisites

- `00-root_db_os_baseline.sh --apply` completed
  — creates `/etc/oraInst.loc` pointing to `ORACLE_INVENTORY`
- Recommended: `00b-db_cvu_check.sh --apply` (standalone CVU, `cluvfy comp sys -r 19`)
  without unexpected FAILED items — [00b-db_cvu_check.md](00b-db_cvu_check.md)
- Oracle 19c base ZIP placed at:
  `/srv/patch_storage/database/LINUX.X64_193000_db_home.zip`
  (manual download from eDelivery — see below)
- `environment_db.conf` configured (including `ORACLE_INVENTORY`)
- At least 10 GB free under `ORACLE_BASE/product/`
- MOS credentials in `mos_sec.conf.des3` (for patch download)
  — skipped automatically if `patchdir/` already contains patch ZIPs

---

## Base ZIP Download (manual, one-time)

> **The Oracle 19c base ZIP cannot be downloaded automatically.**
> Oracle eDelivery requires a browser session and license agreement acceptance.

### Manual download steps

Simplest: **https://www.oracle.com/database/technologies/oracle19c-linux-downloads.html**
(Oracle account login) → *Oracle Database 19c (19.3) for Linux x86-64*, ZIP –
the file is already called `LINUX.X64_193000_db_home.zip`, same SHA-256 as
below. Alternative eDelivery:

1. Log in at **https://edelivery.oracle.com** with your Oracle account
2. Search for: `Oracle Database 19c Enterprise Edition 19.3.0.0.0`
   (or SE2 — the ZIP file is identical)
3. Select Platform: **Linux x86-64** and add to cart
4. Accept the license agreement and download

### File details

| Field | Value |
|---|---|
| Part number | `V982063-01` |
| Filename | `V982063-01.zip` → place as `LINUX.X64_193000_db_home.zip` |
| Size | 2.8 GB |
| SHA-256 | `BA8329C757133DA313ED3B6D7F86C5AC42CD9970A28BF2E6233F3235233AA8D8` |

```bash
sha256sum V982063-01.zip
scp V982063-01.zip oracle@dbserver:/srv/patch_storage/database/LINUX.X64_193000_db_home.zip
```

> EE and SE2 deliver **the same ZIP file** — edition is determined by the license.

---

## Patch Download (AutoUpgrade)

`autoupgrade.jar` is downloaded automatically from oracle.com (no auth required).

MOS credentials (`mos_sec.conf.des3`) are used to download the RU, OJVM, OPatch,
and DPBP ZIPs from My Oracle Support.

The downloaded ZIPs are stored in `$DB_AUTOUPGRADE_HOME/patchdir/` and **reused
on subsequent runs** — delete them only to force a re-download.

```bash
DB_AUTOUPGRADE_HOME/
├── bin/autoupgrade.jar
├── config/db19patch.cfg
├── keystore/
├── patchdir/              ← downloaded ZIPs (kept across runs)
│   ├── p6880880_*.zip     ← OPatch
│   ├── p39915792_*.zip    ← DB RU 19.33 (inventory.xml: "Database Release Update")
│   └── p36912638_*.zip    ← OJVM (OneOff)
└── base_stage/            ← extracted 19.3.0 base (removed by --clean)
```

`DB_TARGET_RU` in `environment_db.conf` controls which RU to download:
- `RECOMMENDED` — latest RU + OJVM + OPatch + DPBP (default, always current)
- `19.30` — fixed version, reproducible install

---

## DB home JDK patch and AutoUpgrade version

The DB RU also replaces `$ORACLE_HOME/jdk` – but with the JDK of the
**previous** quarter (confirmed (live) 2026-10-28: RU 19.30 of January 2026
→ `1.8.0_471-b09`; the RU's `actions.xml` contains ~2,000 actions under
`jdk/`). The current JDK comes with the separate **JDK bundle patch**, which
AutoUpgrade downloads with the keyword **`jdk`** – it is **not** part of
`recommended` (our March 2026 download with AutoUpgrade 26.2: RU, OJVM, DPBP,
OPatch only). `01-` therefore uses `recommended,jdk` (or
`ru:<v>,ojvm:<v>,opatch,dpbp,jdk`); the JDK patch lands in `patchdir/` and is
applied as a OneOff of `runInstaller -applyOneOffs`.

| Item | Value (CPU Oct 2026, checked 2026-10-28) |
|---|---|
| AutoUpgrade | **26.6.260925** – `01-` downloads the newest `autoupgrade.jar` before every patch download and keeps the previous one as `autoupgrade.jar.<version>` (keywords change between releases) |
| `jdk` → | patch **39902051** "JDK BUNDLE PATCH 19.0.0.0.261020" (`p39902051_190000_Linux-x86-64.zip`, SHA-256 `8F9D82C0…53ED51`) – tested: AutoUpgrade 26.6 with `patch=jdk` / `opatch,jdk` |
| Content | JDK `1.8.0_511-b09` (own build line of Oracle homes – not comparable with the b-numbers of the public JRE); files 2026-09-22 → CPU level; **not** the level of the Java alerts of 21 / 24 Oct 2026 (`cacerts` still with the emSign roots, `blacklisted.certs` = list of 2024) |
| OPatch | `opatch` → 12.2.0.1.55 (Oct 2026); the JDK patch needs ≥ 12.2.0.1.52 |
| Existing home | `cd <dir>/<nr>; $ORACLE_HOME/OPatch/opatch prereq CheckConflictAgainstOHWithDetail -ph ./; opatch apply` – **no** database shutdown needed (README); rollback `opatch rollback -id <nr>`; with Examples installed first `chmod -R 755 $ORACLE_HOME/jdk` |
| Each cycle | AutoUpgrade takes the newest revision automatically; check its content (emSign roots gone from `cacerts` = alert level) |

## Additional home for patching (`--target-home`)

For the next RU of a **running** database `01-` builds a second home next to
the running one; `09-db_patch_rcu.sh` then moves the instance
([09-db_patch_rcu.md](09-db_patch_rcu.md)):

```bash
./60-RCU-DB-19c/01-db_install_software.sh --target-home $ORACLE_BASE/product/19.33.0/db_home1 --fresh-patches --apply
```

**Gold image (AutoUpgrade 26.6, 19.33, live 2026-10-28) – preferred:** when
both a `db_goldimage_*.zip` and an RU ZIP lie in `patchdir`, `01-` takes the
gold image (the RU is extracted but not used). Offline: copy the gold image
of another host (e.g. `autoupgrade/patchdir/db_goldimage_19_33_*.zip`, 4.6 GB)
into `patchdir`. `recommended` now
delivers `db_goldimage_19_<ru>_*.zip` – a complete home with RU and OCW RU –
instead of an RU ZIP. `01-` then unpacks it as the new home (newest OPatch
into it), runs its `runInstaller` without patches (rc 6 = success with
warnings) and applies the OneOffs (OJVM, Data Pump bundle, JDK bundle) with
`opatch apply` – `-applyOneOffs` rejected the OJVM RU as "not applicable" on
the gold image. The 19.3 base stage is not needed in this case. Unpacked
19.33 home + OneOffs: 11 GB.

`--target-home` keeps `DB_ORACLE_HOME` / `environment_db.conf` unchanged and
names the home `OraDB19Home_<version dir>`; `--fresh-patches` moves the old
patch ZIPs to `patchdir_<timestamp>/`. The **disk space check runs first**
(also in the dry-run): home + staging on one file system min 14 /
recommended 24 GB (home min 12 / rec 15 GB since the gold image).

## Installation: runInstaller -applyRU

> **State 2026-11-02: this route is NOT working on an FMW host with a shared
> central inventory.** `runInstaller -applyRU` attaches the unpacked home
> temporarily ("tempGIName"), runs `opatchauto apply <RU> -binary` and
> detaches it again – opatchauto then stops with `Invalid Home :
> <DB_ORACLE_HOME>` / "… is not applicable to the oracle home" (prereqs
> `checkPatchApplicable`, `checkConflictAgainstOHWithDetail` … "NOT
> ATTEMPTED"). Seen on the test host in all five runs of March 2026 (RU
> 19.30 = 38632161; the attach logged `OUI-10053 Unable to generate
> temporary script …/orainstRoot.sh`) and at the customer 2026-11-02 (RU
> 19.33 = 39915792, OPatch 12.2.0.1.55). Cause not confirmed yet – to be
> researched on a test host (AttachHome log, inventory permissions).
> **Working routes:** the gold image (below – `01-` prefers it when a
> `db_goldimage_*.zip` lies in `patchdir` next to an RU ZIP; it can be copied
> from a host where AutoUpgrade built it, it is not host-specific), or base
> install + `opatch napply` (how the 19.30 home of March was made).


19c is an **image-based** install: `runInstaller` must run from the home it
installs. `01-` unpacks the 19.3 base ZIP (`DB_INSTALL_ARCHIVE`) into
`DB_ORACLE_HOME`, puts the newest OPatch (p6880880) into it and runs **that**
`runInstaller` with the extracted RU via `-applyRU` and the OneOffs via
`-applyOneOffs` (`base_stage` only provides the Java for AutoUpgrade and the
OPatch for the patch check). Until 2026-11-02 the script ran
`base_stage/runInstaller` with `ORACLE_HOME=<new home>` – the installer stops
with rc=1: "The installer has detected that the Oracle home location provided
in the command line is not correct. The Oracle home is the location from where
setup script is executed." (customer, first run of the RU route; the gold-image
route always unpacked into the home).

```bash
unzip -q LINUX.X64_193000_db_home.zip -d "$DB_ORACLE_HOME"
unzip -q -o p6880880_190000_Linux-x86-64.zip -d "$DB_ORACLE_HOME"   # OPatch 12.2.0.1.55
cd "$DB_ORACLE_HOME"
CV_ASSUME_DISTID=OEL7.6 \
./runInstaller \
    -silent -ignorePrereqFailure -waitforcompletion \
    -applyRU   /path/to/RU_patch_dir \
    -applyOneOffs /path/to/OJVM_dir \
    oracle.install.option=INSTALL_DB_SWONLY \
    ORACLE_BASE="$ORACLE_BASE" \
    ORACLE_HOME="$DB_ORACLE_HOME" \
    ...
```

`CV_ASSUME_DISTID=OEL7.6` suppresses the `supportedOSCheck` NPE (MOS Doc ID 2584365.1).
The `-applyRU` approach resolves the `rc=252` ASM build failure on OL9 because
the RU contains updated makefiles.

---

## After Installation

```bash
# root.sh (sets SUID bit on oracle binary):
$DB_ORACLE_HOME/root.sh

# Verify:
$DB_ORACLE_HOME/OPatch/opatch lspatches
$DB_ORACLE_HOME/bin/sqlplus -V
```

---

## Re-running / --clean

```bash
# Fresh install (removes DB_ORACLE_HOME + base_stage; keeps patchdir ZIPs):
./01-db_install_software.sh --clean --apply
```

---

## environment_db.conf Variables Used

```bash
ORACLE_BASE            # shared with FMW (from environment.conf)
DB_ORACLE_HOME         # target patched home, e.g. product/19.30.0/db_home1
DB_EDITION             # EE | SE2
DB_INSTALL_ARCHIVE     # path to LINUX.X64_193000_db_home.zip
DB_AUTOUPGRADE_HOME    # AutoUpgrade work dir (patchdir, base_stage, …)
DB_TARGET_RU           # RECOMMENDED  or  19.30
MOS_SEC_FILE           # path to mos_sec.conf.des3 (MOS credentials)
```

---

## Troubleshooting

### [INS-08101] supportedOSCheck NullPointerException

The 19.3.0 installer predates OL8/OL9.  Fixed by:
- `CV_ASSUME_DISTID=OEL7.6` (set by the script from `DB_CV_ASSUME_DISTID`)
- `-ignorePrereqFailure` flag

### rc=252 on OL9

With the old (cp-a + opatchauto) approach, the 19.3.0 base installer returned
rc=252 on OL9 due to an ASM client library build failure.  The `-applyRU`
approach resolves this: the RU contains OL9-compatible makefiles, so the build
succeeds and rc=0 is expected.

### "No RU identified"

`01-` takes as RU the extracted directory with a `bundle.xml` (system patch,
GI-style bundle) **or** whose `etc/config/inventory.xml` has the patch
description "Database Release Update" – the single DB RU from MOS (19.33 =
patch **39915792**, 2.2 GB, 5.1 GB unpacked) has **no** `bundle.xml`
(customer 2026-11-02; until then only `bundle.xml` was accepted). The FAIL
lists every extracted directory with size and patch description. Causes:

- **Disk full while unzipping** (customer 2026-10-30: 10 GB free on the staging
  file system) – the RU directory exists but is incomplete. Since 2026-10-30
  `01-` checks the unpacked size of all ZIPs (`zipinfo -t`) plus the new home
  (same file system) **before** extracting, and stops on an `unzip` error
  (the old pipe `unzip | tee` hid it). The FAIL lists every extracted
  directory with size and README title.
- AutoUpgrade downloaded only individual patches (not a bundled RU): set
  `DB_TARGET_RU=RECOMMENDED` or a specific version like `19.30`, delete
  `patchdir/*.zip`, and re-run.
- Offline route: the RU row is in `09-Install/download/patches_db.csv`;
  the ZIPs are **linked** from `$PATCH_STORAGE/database/patches/` into
  `patchdir` (no second copy).

### "Cannot create /etc/oraInst.loc" / INS-32031

`/etc/oraInst.loc` must exist before `runInstaller` runs — the 19c installer
reads only `/etc/oraInst.loc` (not `$ORACLE_BASE/oraInst.loc`).

```bash
# Created by 00-root_db_os_baseline.sh --apply (runs as root)
cat /etc/oraInst.loc
# Expected:
#   inventory_loc=/u01/app/oraInventory   ← ORACLE_INVENTORY
#   inst_group=oinstall
```

If missing: re-run `00-root_db_os_baseline.sh --apply`.
`ORACLE_INVENTORY` must be set in `environment_db.conf` (or derived from
`$(dirname "$ORACLE_BASE")/oraInventory` — the standard Oracle layout).

---

## Next Step

```
04-db_setup_listener.sh --apply
```
