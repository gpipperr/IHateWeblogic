# Step 3b – 06-oracle_patch_forms_reports.sh

**Script:** `09-Install/06-oracle_patch_forms_reports.sh`
**Runs as:** `oracle`
**Phase:** 3 – Forms & Reports Installation

---

## Purpose

Apply Forms & Reports specific patches after the base F&R install.
Patches are listed in `INSTALL_PATCHES_FR` in `oracle_software_version.conf`.

**If `INSTALL_PATCHES_FR` is empty, the script exits OK — nothing to do.**

F&R and WLS share the same `ORACLE_HOME`. The WLS patches from `INSTALL_PATCHES`
(applied by `05-oracle_patch_weblogic.sh`) already cover the shared home.
`INSTALL_PATCHES_FR` is only needed for patches that are F&R-specific and not
included in the WLS CPU bundle.

> **Current state (14.1.2, CPU Jan 2026):** `INSTALL_PATCHES_FR=""` — no
> FR-specific patches needed beyond the WLS bundle patch already applied.

---

## INSTALL_PATCHES_FR

Defined in `09-Install/oracle_software_version.conf`:

```bash
# Leave empty if no FR-specific patches are needed beyond INSTALL_PATCHES.
INSTALL_PATCHES_FR=""

# Example when FR patches are needed:
# INSTALL_PATCHES_FR="12345678 87654321"
```

To add an FR-specific patch:
1. Download the patch ZIP to `$PATCH_STORAGE/patches/<NR>/`
2. Add the patch number to `INSTALL_PATCHES_FR`
3. Run `06-oracle_patch_forms_reports.sh --check-only` first
4. Run `06-oracle_patch_forms_reports.sh --apply`

---

## Without the Script (manual)

### 1. Conflict check

```bash
cd $PATCH_STORAGE/patches/<PATCH_NR>/
$ORACLE_HOME/OPatch/opatch prereq CheckConflictAgainstOHWithDetail \
    -ph . \
    -invPtrLoc $ORACLE_BASE/oraInst.loc
```

### 2. Apply patch

```bash
cd $PATCH_STORAGE/patches/<PATCH_NR>/
$ORACLE_HOME/OPatch/opatch apply \
    -silent \
    -jdk $JDK_HOME \
    -invPtrLoc $ORACLE_BASE/oraInst.loc
```

### 3. Verify

```bash
$ORACLE_HOME/OPatch/opatch lspatches | grep <PATCH_NR>
```

---

## What the Script Does

- Sources `INSTALL_PATCHES_FR` from `oracle_software_version.conf`
- If empty → exits OK with info message
- Reads current patch inventory via `opatch lspatches`
- Skips patches already installed (idempotent)
- For remaining patches: extract ZIP to staging, conflict check, apply
- Cleans up staging directory after apply
- Verifies each applied patch appears in `opatch lspatches`
- **Does NOT upgrade OPatch** — already done in `05-oracle_patch_weblogic.sh`

---

## Flags

| Flag | Description |
|---|---|
| (none) | Show pending patches from `INSTALL_PATCHES_FR` |
| `--apply` | Apply pending patches, skip already-installed |
| `--check-only` | Conflict check only, do not apply |
| `--help` | Show usage |

---

## Notes

- `INSTALL_PATCHES_FR` is in `oracle_software_version.conf` (not `environment.conf`)
- F&R and WLS share one `ORACLE_HOME` — OPatch operates on the whole home
- FMW Bundle Patches often cover both WLS and F&R components; check the CPU
  advisory whether a separate F&R patch is listed
- OPatch upgrade is not repeated here (done in `05-oracle_patch_weblogic.sh`)
