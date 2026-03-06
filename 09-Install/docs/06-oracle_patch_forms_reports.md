# Step 3b – 06-oracle_patch_forms_reports.sh

**Script:** `09-Install/06-oracle_patch_forms_reports.sh`
**Runs as:** `oracle`
**Phase:** 3 – Forms & Reports Installation

---

## Purpose

Apply Forms & Reports specific patches after the base Forms/Reports install.
Some patches may affect the WLS home and the FR home — the script handles both.

---

## Without the Script (manual)

The procedure is identical to `05-oracle_patch_weblogic.sh`.

### 1. Check which home a patch affects

```bash
# After unzipping the patch:
cat $PATCH_STORAGE/patches/<PATCH_NR>/README.txt | grep -i "oracle home"
# or:
$ORACLE_HOME/OPatch/opatch lsinventory -all_nodes
```

Some patches specify: "Apply to Oracle Home: FMW Infrastructure Home" — these
need to be applied to the same `ORACLE_HOME` as WLS.

### 2. Conflict check

```bash
$ORACLE_HOME/OPatch/opatch prereq CheckConflictAgainstOHWithDetail \
    -phBaseDir $PATCH_STORAGE/patches/<PATCH_NR> \
    -jdk $JDK_HOME
```

### 3. Apply patch

```bash
unzip -q $PATCH_STORAGE/patches/<PATCH_NR>/p<PATCH_NR>_*.zip \
    -d /tmp/patch_apply
$ORACLE_HOME/OPatch/opatch apply \
    /tmp/patch_apply/<PATCH_NR> \
    -silent \
    -jdk $JDK_HOME
rm -rf /tmp/patch_apply
```

### 4. Verify

```bash
$ORACLE_HOME/OPatch/opatch lsinventory | grep <PATCH_NR>
```

---

## What the Script Does

- Uses `INSTALL_PATCHES` from `environment.conf` (same list as WLS patches, but
  the script identifies which patches are FR-specific vs already applied to WLS)
- Skips patches already shown in `opatch lsinventory`
- Applies only patches not yet applied
- Otherwise identical logic to `05-oracle_patch_weblogic.sh`

---

## Flags

| Flag | Description |
|---|---|
| (none) | Show pending patches |
| `--apply` | Apply pending patches |
| `--check-only` | Conflict check only |
| `--help` | Show usage |

---

## Notes

- Separate `INSTALL_PATCHES_FR` can be defined in `environment.conf` for FR-specific patches
- If `INSTALL_PATCHES_FR` is empty, this script exits OK (no FR-specific patches to apply)
- FMW Bundle Patches often include both WLS and FR components — check the README carefully
