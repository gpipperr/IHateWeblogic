# Step 3a – 06-oracle_install_forms_reports.sh

**Script:** `09-Install/06-oracle_install_forms_reports.sh`
**Runs as:** `oracle`
**Phase:** 3 – Forms & Reports Installation

---

## Purpose

Silent installation of Oracle Forms & Reports 14.1.2.0.0 into the same `ORACLE_HOME`
as FMW Infrastructure. Must run after `05-oracle_install_weblogic.sh`.

---

## Without the Script (manual)

### 1. Create response file

Create `$PATCH_STORAGE/fr/fr_install.rsp`:

```
[ENGINE]
Response File Version=1.0.0.0.0

[GENERIC]
ORACLE_HOME=/u01/app/oracle/fmw
INSTALL_TYPE=Complete
DECLINE_SECURITY_UPDATES=true
SECURITY_UPDATES_VIA_MYORACLESUPPORT=false
PROXY_HOST=
PROXY_PORT=
PROXY_USER=
PROXY_PWD=
COLLECTOR_SUPPORTHUB_URL=
```

`INSTALL_TYPE` options:
- `Complete` – installs both Forms and Reports
- `Forms` – Forms only
- `Reports` – Reports only

### 2. Run the installer

```bash
$JDK_HOME/bin/java -jar $PATCH_STORAGE/fr/fmw_14.1.2.0.0_fr_linux64.bin \
    -silent \
    -responseFile $PATCH_STORAGE/fr/fr_install.rsp \
    -invPtrLoc /u01/app/oracle/oraInst.loc \
    -ignoreSysPrereqs \
    -jreLoc $JDK_HOME
```

Installation log: `$ORACLE_BASE/oraInventory/logs/`

### 3. Verify installation

```bash
$ORACLE_HOME/OPatch/opatch lsinventory | grep -iE "forms|reports"

ls -la $ORACLE_HOME/forms/
ls -la $ORACLE_HOME/reports/
ls -la $ORACLE_HOME/forms/bin/frmcmp_batch
```

Check Forms version:

```bash
$ORACLE_HOME/forms/bin/frmcmp_batch 2>&1 | head -3
# Should show: "Oracle Forms 14.1.2.0.0 ..."
```

---

## What the Script Does

- Reads `ORACLE_HOME`, `JDK_HOME`, `PATCH_STORAGE`, `INSTALL_COMPONENTS` from `environment.conf`
- Maps `INSTALL_COMPONENTS` (FORMS_AND_REPORTS | FORMS_ONLY | REPORTS_ONLY)
  to `INSTALL_TYPE` (Complete | Forms | Reports)
- Generates the response file
- Verifies FMW Infrastructure is already installed in `ORACLE_HOME`
  (checks for `$ORACLE_HOME/wlserver/` — aborts if missing)
- Runs the silent installer
- Tails install log to stdout
- Verifies `forms/` and `reports/` directories exist after install

---

## Response File Template

Located at: `09-Install/response_files/fr_install.rsp.template`

---

## Flags

| Flag | Description |
|---|---|
| (none) | Show planned install type and paths |
| `--apply` | Run the silent installer |
| `--help` | Show usage |

---

## Verification

```bash
# Inventory
$ORACLE_HOME/OPatch/opatch lsinventory | grep -i "forms"

# Binaries exist
ls $ORACLE_HOME/forms/bin/frmcmp_batch
ls $ORACLE_HOME/reports/bin/rwrun

# Version
$ORACLE_HOME/forms/bin/frmcmp_batch 2>&1 | head -2
```

---

## Notes

- Must install into the **same** `ORACLE_HOME` as FMW Infrastructure
- Install time: approximately 10–20 minutes
- The installer binary is a `.bin` file (not `.jar`); it is self-extracting
- If only Reports is needed: set `INSTALL_COMPONENTS=REPORTS_ONLY` in `environment.conf`
