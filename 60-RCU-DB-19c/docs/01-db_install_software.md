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
3. Update OPatch in staging; identify RU dir (has `bundle.xml`) and OneOffs
4. `runInstaller -applyRU <RU_dir> [-applyOneOffs <OJVM_dir>] -silent`
   → installs directly to `DB_ORACLE_HOME`
5. `root.sh` prompt + `chopt disable olap rat`

`uniaud_on` relink is NOT done here — it runs in `05-db_create_database.sh`
before DBCA (requires the complete DB home).

---

## Prerequisites

- `00-root_db_os_baseline.sh --apply` completed
- Oracle 19c base ZIP placed at:
  `/srv/patch_storage/database/LINUX.X64_193000_db_home.zip`
  (manual download from eDelivery — see below)
- `environment_db.conf` configured
- At least 10 GB free under `ORACLE_BASE/product/`
- MOS credentials in `mos_sec.conf.des3` (for patch download)
  — skipped automatically if `patchdir/` already contains patch ZIPs

---

## Base ZIP Download (manual, one-time)

> **The Oracle 19c base ZIP cannot be downloaded automatically.**
> Oracle eDelivery requires a browser session and license agreement acceptance.

### Manual download steps

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
│   ├── p36912597_*.zip    ← RU (has bundle.xml after extraction)
│   └── p36912638_*.zip    ← OJVM (OneOff)
└── base_stage/            ← extracted 19.3.0 base (removed by --clean)
```

`DB_TARGET_RU` in `environment_db.conf` controls which RU to download:
- `RECOMMENDED` — latest RU + OJVM + OPatch + DPBP (default, always current)
- `19.30` — fixed version, reproducible install

---

## Installation: runInstaller -applyRU

The 19.3.0 staging directory (`base_stage`) provides the `runInstaller` binary.
The installer receives the extracted RU directory via `-applyRU` and optional
OneOffs via `-applyOneOffs`.  The result is installed **directly** to
`DB_ORACLE_HOME` (e.g. `$ORACLE_BASE/product/19.30.0/db_home1`).

```bash
CV_ASSUME_DISTID=OEL7.6 \
"$base_stage/runInstaller" \
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

### "No RU identified (no bundle.xml)"

The RU patch ZIP, when extracted, contains a single directory with `bundle.xml`.
If AutoUpgrade downloaded only individual patches (not a bundled RU), this
check fails.  Solution: set `DB_TARGET_RU=RECOMMENDED` or a specific version
like `19.30`, delete `patchdir/*.zip`, and re-run.

---

## Next Step

```
04-db_setup_listener.sh --apply
```
