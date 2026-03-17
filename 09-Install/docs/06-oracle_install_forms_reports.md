# Step 3a – 06-oracle_install_forms_reports.sh

**Script:** `09-Install/06-oracle_install_forms_reports.sh`
**Runs as:** `oracle`
**Phase:** 3 – Forms & Reports Installation

---

## Purpose

Silent installation of Oracle Forms & Reports 14.1.2.0.0 into the same `ORACLE_HOME`
as FMW Infrastructure. Must run after `05-oracle_install_weblogic.sh`.

---

## Installation Options (INSTALL_COMPONENTS)

Three installation variants are supported. The choice is made once during the
setup interview (`01-setup-interview.sh`) and stored in `environment.conf`.

### How it is set

**During the interview** (`01-setup-interview.sh --apply`):
```
Block 3: What should be installed?
  1) FORMS_AND_REPORTS  – Forms and Reports (default)
  2) FORMS_ONLY         – Forms only
  3) REPORTS_ONLY       – Reports only
```

**Manually** in `environment.conf`:
```bash
INSTALL_COMPONENTS=FORMS_AND_REPORTS   # or FORMS_ONLY / REPORTS_ONLY
```

### Mapping to installer INSTALL_TYPE

> **14.1.2 vs. 12c:** The 12c values `Complete`, `Forms`, `Reports` are **not valid**
> in 14.1.2 and cause `INST-07546: Unable to find install type`.
> The correct values were discovered by running the graphical installer and saving
> the response file (source: `90-Source-MetaData/forms_reports_both_response_file.rsp`).

**The 14.1.2 installer always deploys both Forms and Reports binaries.**
The distinction between Forms-only and Reports-only deployments is made later
at **configuration time** (Configuration Wizard), not at install time.

| `INSTALL_TYPE` value | Use case | `INSTALL_COMPONENTS` that trigger it |
|---|---|---|
| `Forms and Reports Deployment` | Server installation (standard) | `FORMS_AND_REPORTS`, `FORMS_ONLY`, `REPORTS_ONLY` |
| `Standalone Forms Builder` | Developer workstation only | `STANDALONE_FORMS_BUILDER` |

> **In practice:** All server installations use `Forms and Reports Deployment`.
> `INSTALL_COMPONENTS` still controls which components are **configured** in the
> domain (Configuration Wizard step), but the installer always lays down all binaries.

### Key binaries per option

| Option | Binaries installed |
|---|---|
| Forms (Complete or FORMS_ONLY) | `$ORACLE_HOME/forms/bin/frmcmp_batch`, `frmweb`, `frmcmp` |
| Reports (Complete or REPORTS_ONLY) | `$ORACLE_HOME/reports/bin/rwrun`, `rwclient`, `rwservlet` |

> **Changing the option later** requires a full reinstall — the response file
> `INSTALL_TYPE` cannot be changed on an existing Oracle Home without deinstalling.
> Decide before running the installer.

---

## Without the Script (manual)

### 1. Create response file

Create `$PATCH_STORAGE/fr/fr_install.rsp`:

```
[ENGINE]

#DO NOT CHANGE THIS.
Response File Version=1.0.0.0.0

[GENERIC]

DECLINE_AUTO_UPDATES=true
MOS_USERNAME=
MOS_PASSWORD=
SOFTWARE_UPDATES_PROXY_SERVER=
SOFTWARE_UPDATES_PROXY_PORT=
SOFTWARE_UPDATES_PROXY_USER=
SOFTWARE_UPDATES_PROXY_PASSWORD=
ORACLE_HOME=/u01/app/oracle/fmw
FEDERATED_ORACLE_HOMES=
INSTALL_TYPE=Forms and Reports Deployment
JDK_HOME=/u01/app/oracle/java/jdk-21
```

> The response file format changed completely between 12c and 14.1.2.
> Keys like `DECLINE_SECURITY_UPDATES`, `PROXY_HOST`, `COLLECTOR_SUPPORTHUB_URL`
> no longer exist. `JDK_HOME` is now a required field.
> Source: `90-Source-MetaData/forms_reports_both_response_file.rsp`

### 2. Run the installer

```bash
$PATCH_STORAGE/fr/fmw_14.1.2.0.0_fr_linux64.bin \
    -silent \
    -responseFile $PATCH_STORAGE/fr/fr_install.rsp \
    -invPtrLoc /u01/app/oracle/oraInst.loc \
    -ignoreSysPrereqs \
    -jreLoc $JDK_HOME
```

> The `.bin` file is a native Linux executable — **not** a JAR file.
> Do **not** call it with `java -jar`. Run it directly (chmod +x required).

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
- The installer binary is a `.bin` file — native Linux executable, run **directly**
  (unlike the WLS `.jar` installer which requires `java -jar`)
- `INSTALL_COMPONENTS` is set once in the interview and controls `INSTALL_TYPE` in the
  response file — see "Installation Options" section above
- **Cannot change** `INSTALL_TYPE` on an existing Oracle Home without deinstalling first
- `-ignoreSysPrereqs` is required: the F&R installer performs stricter OS checks
  than the WLS installer; this flag tells it to trust the already-validated WLS install

---

## References

- [Oracle Docs – Installing Oracle Forms in Silent Mode (14.1.2)](https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/install-fnr/installing-oracle-forms-silent-mode.html)
