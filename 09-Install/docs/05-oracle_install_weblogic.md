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
INSTALL_TYPE=WebLogic Server
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

### 2. Create oraInst.loc

```bash
cat > /u01/app/oracle/oraInst.loc << 'EOF'
inventory_loc=/u01/app/oracle/oraInventory
inst_group=oinstall
EOF
```

### 3. Run the installer

```bash
$JDK_HOME/bin/java -jar $PATCH_STORAGE/wls/fmw_14.1.2.0.0_infrastructure.jar \
    -silent \
    -responseFile $PATCH_STORAGE/wls/wls_install.rsp \
    -invPtrLoc /u01/app/oracle/oraInst.loc \
    -ignoreSysPrereqs \
    -jreLoc $JDK_HOME
```

Installation log: `$ORACLE_BASE/oraInventory/logs/`

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
- Locates the FMW Infrastructure installer jar in `PATCH_STORAGE/wls/`
- Generates the response file from a template (substituting `ORACLE_HOME`)
- Checks that `ORACLE_HOME` is empty (prevents overwriting an existing install)
- Runs the silent installer with `$JDK_HOME/bin/java`
- Tails the installer log to stdout so progress is visible
- After install: runs `opatch lsinventory` to verify
- Cleans up the response file (contains no secrets, but good practice)

---

## Response File Template

Located at: `09-Install/response_files/wls_install.rsp.template`

The script fills `ORACLE_HOME` from `environment.conf` at runtime.

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

- The `-ignoreSysPrereqs` flag is used because prerequisites are validated by
  `04-oracle_pre_checks.sh` before this step — we do not need the installer's
  own check to run again
- Install time: approximately 10–15 minutes depending on disk speed
- Do not run as root — installer must run as `oracle` user
- If installation fails: check log in `$ORACLE_BASE/oraInventory/logs/`
