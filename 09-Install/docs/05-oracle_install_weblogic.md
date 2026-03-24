# Step 2a – 05-oracle_install_weblogic.sh

**Script:** `09-Install/05-oracle_install_weblogic.sh`
**Runs as:** `oracle`
**Phase:** 2 – WebLogic Installation

---

## Purpose

Silent installation of Oracle FMW Infrastructure 14.1.2.0.0 (includes WebLogic Server).
This is the base layer required before Forms & Reports can be installed.

---

## Without the Script (manual)

### 1. Create response file

Create `$PATCH_STORAGE/wls/wls_install.rsp`:

```
[ENGINE]
Response File Version=1.0.0.0.0

[GENERIC]
ORACLE_HOME=/u01/app/oracle/fmw
INSTALL_TYPE=Fusion Middleware Infrastructure
MYORACLESUPPORT_USERNAME=
MYORACLESUPPORT_PASSWORD=
DECLINE_SECURITY_UPDATES=true
SECURITY_UPDATES_VIA_MYORACLESUPPORT=false
PROXY_HOST=
PROXY_PORT=
PROXY_USER=
PROXY_PWD=
COLLECTOR_SUPPORTHUB_URL=
```

### 2. Verify oraInst.loc

`/etc/oraInst.loc` must already exist — created by `03-root_user_oracle.sh --apply` (root step).
This script (running as oracle) only reads it.

```bash
# Verify before running the installer:
cat /etc/oraInst.loc
# Expected:
#   inventory_loc=/u01/app/oraInventory
#   inst_group=oinstall
```

> `/etc/oraInst.loc` points to `ORACLE_INVENTORY` (one level above `ORACLE_BASE`).
> The installer finds it automatically — no `-invPtrLoc` argument needed.
> If `/etc/oraInst.loc` is missing, re-run `03-root_user_oracle.sh --apply`.

### 3. Set CV override and run the installer

The CV (Configuration Validation) checker in the installer does not natively
recognise Oracle Linux 9. Setting `CV_ASSUME_DISTID=OEL8` fixes the OS detection
without skipping all prerequisite checks. Unset immediately after the installer exits.

```bash
export CV_ASSUME_DISTID=OEL8

$JDK_HOME/bin/java -jar $PATCH_STORAGE/wls/fmw_14.1.2.0.0_infrastructure.jar \
    -silent \
    -responseFile $PATCH_STORAGE/wls/wls_install.rsp \
    -jreLoc $JDK_HOME

unset CV_ASSUME_DISTID
```

> `-invPtrLoc` is not needed: the installer finds `/etc/oraInst.loc` automatically.

Installation log: `$ORACLE_INVENTORY/logs/`  (= `/u01/app/oraInventory/logs/`)

### 4. Verify installation

```bash
$ORACLE_HOME/OPatch/opatch lsinventory
# Expected: Oracle WebLogic Server 14.1.2.0.0

ls -la $ORACLE_HOME/wlserver/
ls -la $ORACLE_HOME/oracle_common/
```

---

## What the Script Does

- Reads `ORACLE_HOME`, `ORACLE_BASE`, `JDK_HOME`, `PATCH_STORAGE` from `environment.conf`
- Reads `CV_ASSUME_DISTID`, `FMW_INFRA_FILENAME`, `FMW_INFRA_ZIP` from `oracle_software_version.conf`
- Locates the FMW Infrastructure JAR in `$PATCH_STORAGE/wls/`; unzips from `FMW_INFRA_ZIP` if JAR not yet extracted
- Generates the response file inline (substituting `ORACLE_HOME`, `ORACLE_BASE`)
- Verifies `/etc/oraInst.loc` exists (created by `03-root_user_oracle.sh`); aborts if missing
- Checks that `ORACLE_HOME` does not yet exist (prevents overwriting an existing install)
- Exports `CV_ASSUME_DISTID` for the duration of the installer run only; unsets afterwards
- Runs the silent installer with `$JDK_HOME/bin/java`
- After install: runs `opatch lsinventory` to verify
- Cleans up the response file (contains no secrets, but good practice)

---

## Response File

Generated at runtime from a heredoc inside the script.
Written to `$PATCH_STORAGE/wls/wls_install.rsp` and deleted after the installer exits.
`ORACLE_HOME` and `ORACLE_BASE` are substituted from `environment.conf`.

---

## Flags

| Flag | Description |
|---|---|
| (none) | Show what would be installed (paths, installer version) |
| `--apply` | Run the silent installer |
| `--help` | Show usage |

---

## Verification

```bash
# Inventory check
$ORACLE_HOME/OPatch/opatch lsinventory | grep -i "weblogic"

# Key directories
ls $ORACLE_HOME/wlserver/common/templates/wls/wls.jar
ls $ORACLE_HOME/oracle_common/common/templates/wls/oracle.jrf_template.jar

# Version file
cat $ORACLE_HOME/inventory/registry.xml | grep "WLS"
```

---

## Notes

- `CV_ASSUME_DISTID=OEL8` is set only for the installer run and unset immediately
  after — it is **not** written to `.bash_profile`. The value is read from
  `oracle_software_version.conf` so it can be adjusted if Oracle certifies OL9
  natively in a future release.
- The `-ignoreSysPrereqs` flag is intentionally **not** used — `CV_ASSUME_DISTID`
  is the targeted fix for the OS detection only; all other CV checks run normally.
  Full prerequisite validation happens in `04-oracle_pre_checks.sh` beforehand.
- Install time: approximately 10–15 minutes depending on disk speed
- Do not run as root — installer must run as `oracle` user
- If installation fails: check log in `$ORACLE_INVENTORY/logs/`  (= `/u01/app/oraInventory/logs/`)
