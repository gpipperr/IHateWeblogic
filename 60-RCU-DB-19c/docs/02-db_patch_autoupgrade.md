# Step 2 – 02-db_patch_autoupgrade.sh

**Script:** `60-RCU-DB-19c/02-db_patch_autoupgrade.sh`
**Runs as:** `oracle`
**Phase:** Patch 19c software to current RU using AutoUpgrade; then disable
unused options

---

## Purpose

Patch the freshly installed 19c ORACLE_HOME to the current Release Update (RU)
without an existing database.  AutoUpgrade `-mode create_home` creates a new
patched ORACLE_HOME offline — no in-place OPatch, clean rollback possible.

After patching: disable OLAP and RAT options (`chopt`), then relink for
Unified Auditing (`uniaud_on`).

---

## AutoUpgrade Setup

### Prerequisites

**Java:**

AutoUpgrade 26.x requires Java 11 (explicitly rejects Java 21).
The script tries the Oracle 19.3.0 bundled JDK first.
If AutoUpgrade rejects it, install the system Java 11:

```bash
# as root — also handled by 00-root_db_os_baseline.sh --apply
dnf install java-11-openjdk
```

**expect:**

The MOS keystore setup (`-load_password`) is an interactive console.
`expect` is required to automate the credential prompts reliably:

```bash
# as root — also handled by 00-root_db_os_baseline.sh --apply
dnf install expect       # installs tcl as dependency (~5 MB)
```

Without `expect` the script falls back to stdin pipe (unreliable for interactive consoles).

**MOS credentials:** `mos_sec.conf.des3` (shared with 09-Install scripts)

**Network access:** `updates.oracle.com`, `login.oracle.com`,
`login-ext.identity.oraclecloud.com`

### Download AutoUpgrade JAR

```bash
AUTOUPGRADE_HOME="$DB_BASE/autoupgrade"
mkdir -p "$AUTOUPGRADE_HOME/bin" "$AUTOUPGRADE_HOME/logs" \
         "$AUTOUPGRADE_HOME/config" "$AUTOUPGRADE_HOME/patchdir" \
         "$AUTOUPGRADE_HOME/keystore"

# Download latest autoupgrade.jar directly from oracle.com (no login required)
curl -fsSL https://download.oracle.com/otn-pub/otn_software/autoupgrade.jar \
    -o "$AUTOUPGRADE_HOME/bin/autoupgrade.jar"
```

> **Note on URL stability:** Oracle periodically reorganises the download path.
> The current URL is `https://download.oracle.com/otn-pub/otn_software/autoupgrade.jar`
> (path changed from `.../otn_software/autoupgrade/autoupgrade.jar` in early 2026).
> The Oracle Upgrades page at `https://www.oracle.com/database/upgrades/` always
> contains the authoritative current link.

### Set MOS Keystore

MOS credentials are stored **once** in the keystore and reused on subsequent runs.
The script automates this with `expect` (installed by `00-root_db_os_baseline.sh`).

```bash
java -jar "$AUTOUPGRADE_HOME/bin/autoupgrade.jar" \
    -config "$AUTOUPGRADE_HOME/config/keystore.cfg" \
    -patch -load_password
```

Exact interactive prompt sequence (AutoUpgrade 26.x):
```
Creating new AutoUpgrade Patching keystore - Password required
Enter password:                                   ← keystore encryption password
Enter password again:                             ← keystore encryption password (confirm)
AutoUpgrade Patching keystore was successfully created

MOS> add -user your.email@example.com             ← no 'group mos' needed
Enter your secret/Password:                       ← MOS password
Re-enter your secret/Password:                    ← MOS password (confirm)
MOS> exit
Save the AutoUpgrade Patching keystore before exiting [YES|NO] ? YES
Convert the AutoUpgrade Patching keystore to auto-login [YES|NO] ?  YES
```

The script automates this sequence via `expect` using credentials from `mos_sec.conf.des3`.
The keystore encryption password is derived deterministically from the hostname.
If credentials change: `rm -rf $DB_AUTOUPGRADE_HOME/keystore/* && ./02-db_patch_autoupgrade.sh --apply`

`keystore.cfg`:
```
global.global_log_dir=$DB_BASE/autoupgrade/logs
global.keystore=$DB_BASE/autoupgrade/keystore
```

> **Changed in AutoUpgrade 26.x:** `-mode setmospassword` replaced by `-load_password`.
> `group mos` is no longer needed before `add -user`.
> Two YES/NO save prompts appear after `exit` (save + convert to auto-login).

---

## Patch Config

`$AUTOUPGRADE_HOME/config/db19patch.cfg`:

```
global.global_log_dir=$DB_BASE/autoupgrade/logs
global.keystore=$DB_BASE/autoupgrade/keystore

patch1.source_home=$DB_ORACLE_HOME_BASE      # unpatched 19.3 home
patch1.target_home=$DB_ORACLE_HOME           # new patched home (19.30.0/db_home1)
patch1.folder=$DB_BASE/autoupgrade/patchdir
patch1.patch=recommended
patch1.target_version=19
patch1.download=YES
```

> **`patch1.patch` values (AutoUpgrade 26.x):**
>
> | Value | Meaning |
> |---|---|
> | `recommended` | Latest RU + OJVM + OPatch + DPBP + AU (default for non-production) |
> | `ru:19.30,ojvm:19.30,opatch,dpbp` | Fixed RU 30 — reproducible, for production |
>
> The script derives the patch spec automatically from `DB_TARGET_RU` in `environment_db.conf`:
> - `RECOMMENDED` → `recommended`
> - `19.30` → `ru:19.30,ojvm:19.30,opatch,dpbp`
>
> **Note:** `RU:19.CURRENT` is **not** a valid value in AutoUpgrade 26.x.
> Use `RECOMMENDED` for "always latest".
>
> Update `DB_ORACLE_HOME` in `environment_db.conf` to match the RU version:
> `${ORACLE_BASE}/product/19.30.0/db_home1`

---

## Gold Image Prerequisite

`create_home` builds the new ORACLE_HOME by unpacking the base 19.3.0 installation ZIP
(Gold Image).  The file **must** be present in `patch1.folder` before `create_home` runs.

```bash
# Option A: symlink from patch storage (avoids 3 GB copy)
ln -sf "$DB_INSTALL_ARCHIVE" "$DB_AUTOUPGRADE_HOME/patchdir/LINUX.X64_193000_db_home.zip"

# Option B: copy
cp LINUX.X64_193000_db_home.zip "$DB_AUTOUPGRADE_HOME/patchdir/"
```

The script handles this automatically: it symlinks `DB_INSTALL_ARCHIVE` (from
`environment_db.conf`) into `patchdir` before calling `create_home`.

If the ZIP is missing, `create_home` fails at the EXTRACT stage:
```
EXTRACT stage failed: Could not find a Gold Image or usable base image
```

---

## Patch Execution

### 1. Download patches

```bash
# Java 8 (Oracle 19.3.0 JDK): use TLSv1.2 — Java 8 does not support TLSv1.3 as JVM property
java -Dhttps.protocols=TLSv1.2 \
    -jar "$AUTOUPGRADE_HOME/bin/autoupgrade.jar" \
    -config "$AUTOUPGRADE_HOME/config/db19patch.cfg" \
    -patch -mode download

# Java 11+: TLSv1.3 works
java -Dhttps.protocols=TLSv1.3 \
    -jar "$AUTOUPGRADE_HOME/bin/autoupgrade.jar" \
    -config "$AUTOUPGRADE_HOME/config/db19patch.cfg" \
    -patch -mode download
```

The script detects the Java version and sets `$AU_TLS` automatically.

Monitor: `lsj -a 10`

### 2. Create patched ORACLE_HOME

```bash
java -Dhttps.protocols=TLSv1.2 \   # or TLSv1.3 for Java 11+
    -jar "$AUTOUPGRADE_HOME/bin/autoupgrade.jar" \
    -config "$AUTOUPGRADE_HOME/config/db19patch.cfg" \
    -patch -mode create_home
```

The original `source_home` remains untouched.  The `target_home` gets the
patched binaries.

### 3. Run root.sh on new home

```bash
"$DB_ORACLE_HOME/root.sh"
```

Script pauses and prompts for root confirmation.

---

## Disable Unused Options (chopt)

After patching, on the new ORACLE_HOME:

```bash
$DB_ORACLE_HOME/bin/chopt disable olap
$DB_ORACLE_HOME/bin/chopt disable rat
```

`chopt` relinks the Oracle binary — takes ~2 minutes per option.

| Option | Why disabled |
|---|---|
| `olap` | Oracle OLAP — not used by FMW metadata schemas |
| `rat` | Real Application Testing — not needed in this environment |

---

## Unified Auditing Relink

After all `chopt` operations, relink for Unified Auditing:

```bash
cd "$DB_ORACLE_HOME/rdbms/lib"
make -f ins_rdbms.mk uniaud_on ioracle
```

Verify:
```bash
strings "$DB_ORACLE_HOME/bin/oracle" | grep -c kzaiang
# must return a positive number
```

> **This relink must be repeated after every future RU patch.**
> `02-db_patch_autoupgrade.sh --apply` performs all three steps:
> AutoUpgrade create_home → chopt disable → uniaud_on relink.

---

## SSL / DNS Issues

AutoUpgrade communicates with Oracle Identity Cloud (`login-ext.identity.oraclecloud.com`).
Transient DNS failures are known in some environments.

**TLS version by Java version:**

| Java | `-Dhttps.protocols` | Note |
|---|---|---|
| Java 8 (Oracle 19.3.0 JDK) | `TLSv1.2` | TLSv1.3 throws `IllegalArgumentException` on Java 8 |
| Java 11+ | `TLSv1.3` | Full TLS 1.3 support |

The script detects the Java version and sets the flag automatically.

---

## Verify Patched Home

```bash
$DB_ORACLE_HOME/OPatch/opatch lspatches
# Should show current RU + OJVM patch

$DB_ORACLE_HOME/OPatch/opatch version
# OPatch version should be current (bundled with the RU)
```

---

## environment_db.conf Variables Used

```bash
ORACLE_BASE             # /u01/app/oracle — shared with FMW
DB_ORACLE_HOME_BASE     # ${ORACLE_BASE}/product/19.3.0/db_home1  — source (unpatched)
DB_ORACLE_HOME          # ${ORACLE_BASE}/product/19.30.0/db_home1 — target (RU 30, patched)
DB_AUTOUPGRADE_HOME     # ${ORACLE_BASE}/autoupgrade
MOS_SEC_FILE            # path to mos_sec.conf.des3 (shared with 09-Install)
```

---

## Troubleshooting

### Unable to validate platform / OPatch error 73

**Symptom:**
```
Unable to validate platform
OPatch failed with error code 73
LsInventorySession failed: RawInventory gets null OracleHomeInfo
```

**Cause:**

`runInstaller` rc=252 (ASM make failure, see `docs/02-db_install_software.md`) stops
before Oracle Inventory registration completes.  The DB home is not listed in the
central inventory — OPatch cannot identify it as a known Oracle Home.

**Fix:**

Register the already-installed home using `attachHome`:

```bash
$ORACLE_BASE/product/19.3.0/db_home1/oui/bin/runInstaller \
    -silent -attachHome \
    ORACLE_HOME=$ORACLE_BASE/product/19.3.0/db_home1 \
    ORACLE_HOME_NAME=OraDB19Home1
```

Verify:
```bash
$ORACLE_BASE/product/19.3.0/db_home1/OPatch/opatch lsinventory \
    -oh $ORACLE_BASE/product/19.3.0/db_home1
# Must list OraDB19Home1 alongside OracleHome1 (FMW)
```

`01-db_install_software.sh` runs `attachHome` automatically after rc=252 as of
commit `ddf59d6`.  On existing installations that pre-date this fix, run the
`attachHome` command manually before calling `02-db_patch_autoupgrade.sh --apply`.

---

### AutoUpgrade Recovery State – download mode refused

**Symptom:**
```
Previous execution found loading latest data
Total jobs recovered: 1
There is an unfinished execution of a create_home mode. Run the AutoUpgrade Patching
in create_home mode to resume from failure point
        java -jar autoupgrade.jar -config .../db19patch.cfg -mode create_home
```
`download` mode exits with rc=1 — not a DNS or network error.

**Cause:**

A previous `create_home` run failed partway through (e.g. at INSTALL stage).
AutoUpgrade stores recovery data and refuses to run `download` again while a
`create_home` job is pending.

**Fix A — Resume (default behaviour of the script):**

The script detects "unfinished execution" in the output and automatically skips the
download step, proceeding directly to `create_home` (which will resume from the
failure point):

```bash
./02-db_patch_autoupgrade.sh --apply
```

**Fix B — Start completely from scratch:**

```bash
./02-db_patch_autoupgrade.sh --reset-recovery
```

This clears the AutoUpgrade recovery data (`-clear_recovery_data -jobs 1`), then
re-runs the full cycle: download → create_home.

**Manual equivalent:**
```bash
java -jar autoupgrade.jar -config .../db19patch.cfg -patch \
    -clear_recovery_data -jobs 1
java -jar autoupgrade.jar -config .../db19patch.cfg -patch -mode create_home
```

---

### DB_TARGET_RU=19.CURRENT — patch parameter not supported

**Symptom:**
```
The patch parameter for prefix patch1 includes a value that is not supported or is not in the required format
```

**Cause:** `RU:19.CURRENT` is not a valid value in AutoUpgrade 26.x.

**Fix:** Set `DB_TARGET_RU="RECOMMENDED"` (or a numeric version like `19.30`) in `environment_db.conf`.

---

### PATCH109 – patch not applicable / Invalid Home (INSTALL stage)

**Symptom:**
```
PATCH109: AutoUpgrade Patching failed to install the new ORACLE_HOME
          /u01/app/oracle/product/19.30.0/db_home1
Reason: Failed during Analysis: .../38632161 is not applicable to the oracle home ...
opatchauto FAILED on some patches.
```

OPatch sub-log (`cfgtoollogs/opatchauto/core/opatch/opatch*.log`):
```
[INFO]   Throwable occurred: Invalid Home : /u01/app/oracle/product/19.30.0/db_home1
[INFO]   IMPReadService:getPatchCheckResultsCUPs, failed to get ComponentInfo from
         inventory Invalid Home : /u01/app/oracle/product/19.30.0/db_home1
OPatch cannot locate your -invPtrLoc '.../19.30.0/db_home1/oraInst.loc'
OPatch failed with error code 106
```

**Cause:**

AutoUpgrade EXTRACT stage unpacks the Gold Image ZIP into `target_home`, but
`oraInst.loc` is **not included in the ZIP** — it is created by OUI during a normal
installation.  Without `oraInst.loc`, OPatch cannot locate the central Oracle Inventory
and all inventory-dependent prerequisite checks fail with "Invalid Home" (OPatch
error 106).

**Fix (manual / one-time):**

```bash
# 1. Copy oraInst.loc from system into the new home
cp /etc/oraInst.loc $DB_ORACLE_HOME/oraInst.loc

# 2. Register the new home in the central inventory
$DB_ORACLE_HOME/oui/bin/runInstaller \
    -silent -attachHome \
    ORACLE_HOME=$DB_ORACLE_HOME \
    ORACLE_HOME_NAME=OraDB19Home1Patched

# 3. Verify — must now show Oracle Database 19c without error
$DB_ORACLE_HOME/OPatch/opatch lsinventory -oh $DB_ORACLE_HOME 2>&1 | head -20

# 4. Resume (AutoUpgrade recovery state is still active)
./02-db_patch_autoupgrade.sh --apply
```

**Automated:** The script detects `$DB_ORACLE_HOME` exists without `oraInst.loc`
before every `create_home` call and applies the fix automatically (copy + attachHome).
Manual intervention is only needed on environments set up before this fix was added.

---

## References

| Document | URL |
|---|---|
| AutoUpgrade direct download from oracle.com | https://mikedietrichde.com/2024/11/21/download-autoupgrade-directly-from-oracle-com/ |
| AutoUpgrade patching feature (create_home) | https://mikedietrichde.com/2024/10/28/autoupgrades-patching-the-feature-you-waited-for/ |
| AutoUpgrade / Patch Automation 19c (pipperr.de) | https://www.pipperr.de/dokuwiki/doku.php?id=dba:autouppgrade_patch_automation_19c |
