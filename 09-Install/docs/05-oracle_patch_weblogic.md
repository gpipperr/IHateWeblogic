# Step 2b – 05-oracle_patch_weblogic.sh

**Script:** `09-Install/05-oracle_patch_weblogic.sh`
**Runs as:** `oracle`
**Phase:** 2 – WebLogic Installation

---

## Purpose

Update OPatch to the required version, then apply all WLS patches listed in
`INSTALL_PATCHES`. Patches must be applied immediately after the base install,
before any domain is created.

---

## Without the Script (manual)

### 1. Check current OPatch version

```bash
$ORACLE_HOME/OPatch/opatch version
# Required: ≥ 13.9.4.0.0 for FMW 14.1.2
```

### 2. Update OPatch

```bash
# Backup existing OPatch
mv $ORACLE_HOME/OPatch $ORACLE_HOME/OPatch.bak

# Extract new OPatch (from PATCH_STORAGE/opatch/)
unzip $PATCH_STORAGE/opatch/p6880880_*.zip -d $ORACLE_HOME

# Verify new version
$ORACLE_HOME/OPatch/opatch version
```

### 3. Run conflict check before patching

```bash
for PATCH_NR in 33735326 34374498; do
    echo "=== Conflict check: $PATCH_NR ==="
    $ORACLE_HOME/OPatch/opatch prereq CheckConflictAgainstOHWithDetail \
        -phBaseDir $PATCH_STORAGE/patches/$PATCH_NR \
        -jdk $JDK_HOME
done
```

All patches must show `OPatch succeeded` before proceeding.

### 4. Apply patches in order

```bash
# Patches must be applied in the order listed in Oracle's readme
for PATCH_NR in 33735326 34374498; do
    echo "=== Applying patch: $PATCH_NR ==="
    unzip -q $PATCH_STORAGE/patches/$PATCH_NR/p${PATCH_NR}_*.zip \
        -d /tmp/patch_apply
    $ORACLE_HOME/OPatch/opatch apply \
        /tmp/patch_apply/$PATCH_NR \
        -silent \
        -jdk $JDK_HOME
    rm -rf /tmp/patch_apply
done
```

### 5. Verify patches

```bash
$ORACLE_HOME/OPatch/opatch lsinventory | grep -E "Patch [0-9]+"
```

---

## What the Script Does

- Reads `ORACLE_HOME`, `JDK_HOME`, `PATCH_STORAGE`, `INSTALL_PATCHES` from `environment.conf`
- Checks current OPatch version; updates if older than what's in `PATCH_STORAGE/opatch/`
- Locates patch zips in `PATCH_STORAGE/patches/<PATCH_NR>/`
- Runs `opatch prereq CheckConflictAgainstOHWithDetail` for all patches first
- Aborts if any conflict is found
- Applies patches in the order they appear in `INSTALL_PATCHES`
- Verifies each patch in `opatch lsinventory` after apply
- Generates a patch report: which patches were applied, which were already present

---

## Flags

| Flag | Description |
|---|---|
| (none) | Show OPatch version, list patches to apply |
| `--apply` | Update OPatch and apply patches |
| `--check-only` | Run conflict check only, do not apply |
| `--help` | Show usage |

---

## Verification

```bash
$ORACLE_HOME/OPatch/opatch lsinventory
# Lists all applied patches with patch number and description

$ORACLE_HOME/OPatch/opatch lsinventory | grep "33735326"
# Each patch number must appear
```

---

## Notes

- All WebLogic servers must be **stopped** before applying patches (OPatch verifies this)
- At this stage no domain exists yet, so there are no servers to stop
- Always run the conflict check (`prereq`) before `apply` — never skip it
- Patch apply order matters: apply in the sequence specified in Oracle's Bundle Patch readme
- If a patch fails: check `$ORACLE_HOME/cfgtoollogs/opatch/` for detailed logs
