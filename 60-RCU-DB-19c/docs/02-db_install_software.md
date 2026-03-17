# Step 1 – 01-db_install_software.sh

**Script:** `60-RCU-DB-19c/01-db_install_software.sh`
**Runs as:** `oracle`
**Phase:** Install Oracle 19c Database software (no DB created yet)

---

## Purpose

Install the Oracle 19c Database software into a new ORACLE_HOME.
No database is created in this step — software only.

---

## Prerequisites

- `00-root_db_os_baseline.sh --apply` completed
- Oracle 19c installation ZIP downloaded to `DB_INSTALL_ARCHIVE`
  (e.g. `LINUX.X64_193000_db_home.zip`)
- `environment_db.conf` configured
- oracle user, oinstall/dba groups present (set by preinstall RPM)
- At least 8 GB free in `DB_ORACLE_HOME` parent directory

---

## Download

Oracle 19c software is available on eDelivery / MOS.
Patch number for base release: **19.3** → `V982063-01.zip`

The same `getMOSPatch.jar` used in `09-Install/04-oracle_pre_download.sh`
can download 19c software. Alternatively, download manually via
`edelivery.oracle.com`.

---

## Installation

### 1. Create ORACLE_HOME directory

The 19c base install goes under `ORACLE_BASE/product/19.3.0/db_home1`:

```bash
# DB_ORACLE_HOME_BASE="${ORACLE_BASE}/product/19.3.0/db_home1"
mkdir -p "$DB_ORACLE_HOME_BASE"
chmod 775 "$DB_ORACLE_HOME_BASE"
```

After AutoUpgrade patching (step 2), the active ORACLE_HOME becomes
`$ORACLE_BASE/product/19.XX.0/db_home1` (`DB_ORACLE_HOME`).

### 2. Unzip into ORACLE_HOME

```bash
unzip -q "$DB_INSTALL_ARCHIVE" -d "$DB_ORACLE_HOME_BASE"
```

The 19c ZIP extracts directly into the target directory (unlike the old
runInstaller-with-stage approach).

### 3. Run installer (software-only)

> **ORACLE_HOME must be set explicitly here** — the oracle user's `.bash_profile`
> points to `FMW_HOME`, not to the DB home.  All scripts use `DB_ORACLE_HOME_BASE`
> to avoid any ambiguity.

```bash
"$DB_ORACLE_HOME_BASE/runInstaller" \
    -silent \
    -ignorePrereqFailure \
    -waitforcompletion \
    oracle.install.option=INSTALL_DB_SWONLY \
    ORACLE_BASE="$ORACLE_BASE" \
    ORACLE_HOME="$DB_ORACLE_HOME_BASE" \
    ORACLE_HOME_NAME="OraDB19Home1" \
    oracle.install.db.InstallEdition=EE \
    oracle.install.db.OSDBA_GROUP=dba \
    oracle.install.db.OSOPER_GROUP=oper \
    oracle.install.db.OSBACKUPDBA_GROUP=dba \
    oracle.install.db.OSDGDBA_GROUP=dba \
    oracle.install.db.OSKMDBA_GROUP=dba \
    oracle.install.db.OSKMDBA_GROUP=dba \
    SECURITY_UPDATES_VIA_MYORACLESUPPORT=false \
    DECLINE_SECURITY_UPDATES=true \
    2>&1 | tee -a "$LOG_FILE"
```

> SE2 alternative: change `InstallEdition=EE` to `InstallEdition=SE2`
> (sufficient for a single-PDB RCU-only database; see `docs/00-concept.md`).

### 4. Run root scripts (as root)

```bash
"$DB_ORACLE_HOME_BASE/root.sh"
```

The script prompts for this and pauses until confirmed.

---

## Verify Installation

```bash
$DB_ORACLE_HOME/OPatch/opatch lspatches
# Should show: 29517242 (19.3.0.0 base patch)

$DB_ORACLE_HOME/bin/sqlplus -V
# Should show: SQL*Plus: Release 19.0.0.0.0
```

---

## environment_db.conf Variables Used

```bash
ORACLE_BASE          # /u01/app/oracle — shared with FMW (from environment.conf)
DB_ORACLE_HOME_BASE  # ${ORACLE_BASE}/product/19.3.0/db_home1  — base install target
DB_INSTALL_ARCHIVE   # path to LINUX.X64_193000_db_home.zip
```

---

## Notes

- Install Edition `EE` (Enterprise Edition) is required for:
  - Unified Auditing (mixed mode disabled)
  - PDB (Pluggable Databases)
  - Partitioning (used internally by some FMW schemas)
- `SECURITY_UPDATES_VIA_MYORACLESUPPORT=false` + `DECLINE_SECURITY_UPDATES=true`:
  suppresses the email notification prompt in silent mode
- The installer log is at: `$DB_BASE/oraInventory/logs/`
- After software install + root.sh, do NOT create a database yet — patch first
  (Step 2: `02-db_patch_autoupgrade.sh`)
