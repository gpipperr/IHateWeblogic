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

### DB_TARGET_RU=19.CURRENT — patch parameter not supported

**Symptom:**
```
The patch parameter for prefix patch1 includes a value that is not supported or is not in the required format
```

**Cause:** `RU:19.CURRENT` is not a valid value in AutoUpgrade 26.x.

**Fix:** Set `DB_TARGET_RU="RECOMMENDED"` (or a numeric version like `19.30`) in `environment_db.conf`.

---

## References

| Document | URL |
|---|---|
| AutoUpgrade direct download from oracle.com | https://mikedietrichde.com/2024/11/21/download-autoupgrade-directly-from-oracle-com/ |
| AutoUpgrade patching feature (create_home) | https://mikedietrichde.com/2024/10/28/autoupgrades-patching-the-feature-you-waited-for/ |
| AutoUpgrade / Patch Automation 19c (pipperr.de) | https://www.pipperr.de/dokuwiki/doku.php?id=dba:autouppgrade_patch_automation_19c |
