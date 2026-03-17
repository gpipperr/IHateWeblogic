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

- Java 11 — use `$DB_ORACLE_HOME/jdk/bin/java` (bundled with 19c)
- MOS credentials in `mos_sec.conf.des3` (same file used by 09-Install scripts)
- Network access: `updates.oracle.com`, `login.oracle.com`,
  `login-ext.identity.oraclecloud.com`

### Download AutoUpgrade JAR

```bash
AUTOUPGRADE_HOME="$DB_BASE/autoupgrade"
mkdir -p "$AUTOUPGRADE_HOME/bin" "$AUTOUPGRADE_HOME/logs" \
         "$AUTOUPGRADE_HOME/config" "$AUTOUPGRADE_HOME/patchdir" \
         "$AUTOUPGRADE_HOME/keystore"

# Download latest autoupgrade.jar (MOS Doc ID 2485457.1)
# Or use getMOSPatch.jar with patch 30653378
```

### Set MOS Keystore

```bash
java -jar "$AUTOUPGRADE_HOME/bin/autoupgrade.jar" \
    -config "$AUTOUPGRADE_HOME/config/keystore.cfg" \
    -patch -mode setmospassword
```

`keystore.cfg`:
```
global.keystore=$DB_BASE/autoupgrade/keystore
```

---

## Patch Config

`$AUTOUPGRADE_HOME/config/db19patch.cfg`:

```
global.global_log_dir=$DB_BASE/autoupgrade/logs
global.keystore=$DB_BASE/autoupgrade/keystore

patch1.source_home=$DB_ORACLE_HOME_BASE      # unpatched 19.3 home
patch1.target_home=$DB_ORACLE_HOME           # new patched home (same or new path)
patch1.folder=$DB_BASE/autoupgrade/patchdir
patch1.patch=RU:19.CURRENT,OPATCH,OJVM:19.CURRENT,DPBP
patch1.target_version=19
patch1.download=YES
```

> `RU:19.CURRENT` → AutoUpgrade resolves the latest available 19c RU.
> Set a fixed RU (e.g. `RU:19.24`) for reproducible installs.

---

## Patch Execution

### 1. Download patches

```bash
java -Dhttps.protocols=TLSv1.3 \
    -jar "$AUTOUPGRADE_HOME/bin/autoupgrade.jar" \
    -config "$AUTOUPGRADE_HOME/config/db19patch.cfg" \
    -patch -mode download
```

Monitor: `lsj -a 10`

### 2. Create patched ORACLE_HOME

```bash
java -Dhttps.protocols=TLSv1.3 \
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
Transient DNS failures are known in some environments.  The script retries
with the same `MOS_RETRY_MAX` / `MOS_RETRY_WAIT` pattern used in
`04-oracle_pre_download.sh`.

Force TLSv1.3:
```bash
java -Dhttps.protocols=TLSv1.3 -jar autoupgrade.jar ...
```

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
DB_ORACLE_HOME          # patched target home
DB_ORACLE_HOME_BASE     # unpatched source home (19.3 base)
DB_BASE                 # $ORACLE_BASE — autoupgrade lives here
MOS_SEC_FILE            # path to mos_sec.conf.des3 (shared with 09-Install)
```
