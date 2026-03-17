# Step 2b – 05-oracle_patch_weblogic.sh

**Script:** `09-Install/05-oracle_patch_weblogic.sh`
**Runs as:** `oracle`
**Phase:** 2 – WebLogic Installation

---

## How to Find the Correct Patch Numbers

Oracle puts considerable effort into making the patching of their products as
cumbersome as possible, and they usually succeed admirably.

### Step 1 – Find the current CPU

Search Google for:
```
January 2026 Critical Patch Update (CPU) Oracle Fusion Middleware Infrastructure 14.1.2.0.0
```

Navigate to **https://www.oracle.com/security-alerts/cpujan2026.html**, search the
page for **"Oracle WebLogic"**, and find the entry:

> Oracle HTTP Server, Oracle WebLogic Server Proxy Plug-in, versions 12.2.1.4.0,
> 14.1.1.0.0, 14.1.2.0.0

Click the entry — it leads to **https://www.oracle.com/security-alerts/cpujan2026.html#AppendixFMW**

> **Note:** The CPU URL changes every quarter. In April the path will be
> `cpuapr2026.html`, in July `cpujul2026.html`, etc. Oracle makes sure to keep
> this permanently interesting.

### Step 2 – Find the patch number in My Oracle Support

On the CPU page you will find, on the right-hand side, a link to a My Oracle
Support Doc ID — for January 2026 this is **KA1182**.

Go to **https://support.oracle.com/** and search for the Doc ID number **only**
(e.g. `KA1182`). Do not attempt to search by product name — the AI market leader
cannot recognise its own products in its own support interface and will return
only noise.

With some luck you will reach a page such as:
**https://support.oracle.com/support/?kmContentId=2806740&page=sptemplate&sptemplate=km-article**

Select the tab **"FMW Infrastructure"** → menu item **"FMW Infrastructure 14.1.2.0"**
— and there is your patch number.

For January 2026 CPU: **Patch 38566996**

### Step 3 – Navigate to the patch download page

Click the patch number. The page tends to perform so many redirects that cookie
problems arise. If you get an `HTTP 400 – Request Header Or Cookie Too Large`
error (which happens regularly), open a **different browser in private/incognito
mode**, log in to Oracle Support fresh, and repeat all steps above.

Alternatively, paste this URL directly into the private window:
```
https://support.oracle.com/support/?patchId=38566996&page=sptemplate&sptemplate=cp-patches-updates-view-more&cp-patches-updates-view-more=cp-patches-details
```

Try to use a browser in which you have not previously logged in to Oracle Support.
Log in again through the various screens — and you will arrive at the patch page.
Oracle will then promptly forget the link, so paste it into the same window again
once you have a working session. Select **Readme**.

Verify you have the correct patch:
> **Patch 38566996: UMS Bundle Patch 14.1.2.0.251022**

### Step 4 – Find the required OPatch version

In the Readme, click **Prerequisites**. This reveals the OPatch version required
to apply the patch:

> The ORACLE_HOME should be installed with OPatch version **13.9.4.2.17** or higher.

There is also a link to the OPatch patch itself. Click it to find the patch
number for the patch-installer patch:

> **Patch 28186730: OPATCH 13.9.4.2.22 FOR EM 13.5/24.1 AND FMW/WLS 12.2.1.4.0,
> 14.1.1.0.0, 14.1.2.0.0 AND IDM 14.1.2.1**

Open the OPatch Readme (it is a plain text file). It explains that you must first
check whether a previously installed OPatch version needs to be rolled back before
applying the new one. Download the OPatch patch, save/print the Readme, and follow
the instructions precisely.

Only after OPatch has been updated successfully can you return to the actual patch.

> **Important:** These links and Doc IDs are valid for January 2026 only. In April
> the CPU will reference different numbers and a different URL. Oracle always finds
> ways to add yet another layer of complexity — for reasons that remain unclear.

---

## Purpose

Update OPatch to the required version, then apply all WLS patches listed in
`INSTALL_PATCHES`. Patches must be applied immediately after the base install,
before any domain is created.

---

## Without the Script (manual)

### 1. Download OPatch upgrade patch (Patch 28186730)

> **Important:** Since OPatch >= 13.6, OPatch is no longer updated by a plain unzip.
> It must be installed via its own `opatch_generic.jar` installer (OUI tooling), so
> that the OUI metadata is updated correctly. A plain unzip will work but leaves the
> OUI inventory out of sync, which has caused upgrade issues.
>
> The correct download for FMW/WLS is **Patch 28186730** (not the generic 6880880).
> When unzipped, it contains a `6880880/` subdirectory with `opatch_generic.jar`.

Download via `04-oracle_pre_download.sh --apply --mos` (add `28186730` to
`INSTALL_PATCHES` in `oracle_software_version.conf` temporarily), or manually from
My Oracle Support: Patch 28186730.

```bash
# Staging directory after download:
ls $PATCH_STORAGE/patches/28186730/
# → p28186730_139422_Generic.zip  (or similar)

# Unzip to a staging area
mkdir -p /tmp/opatch_upgrade
unzip -q $PATCH_STORAGE/patches/28186730/p28186730_*.zip -d /tmp/opatch_upgrade
ls /tmp/opatch_upgrade/6880880/
# → opatch_generic.jar  (plus supporting files)
```

### 2. Check current OPatch version

```bash
$ORACLE_HOME/OPatch/opatch version
# Required for January 2026 CPU (Patch 38566996): ≥ 13.9.4.2.17
# Installed by this step: 13.9.4.2.22
```

### 3. Pre-requisite: check for patch 23335292

The OPatch README requires checking whether patch `23335292` is installed in
`ORACLE_HOME`. If present it must be rolled back **before** upgrading OPatch.
Do **not** roll it back after the upgrade.

```bash
# Check if patch 23335292 is installed
$ORACLE_HOME/OPatch/opatch lspatches | grep 23335292

# If found: rollback before proceeding
$ORACLE_HOME/OPatch/opatch rollback -id 23335292

# Wait 15–30 seconds after rollback before any further opatch operations
sleep 20
```

### 4. Backup before upgrading OPatch

> **There is no rollback mechanism for OPatch.** The only way to revert is to
> restore from backup. Always back up before proceeding.

```bash
# Backup OPatch directory
cp -a $ORACLE_HOME/OPatch $ORACLE_HOME/OPatch.bak_$(date +%Y%m%d)

# Backup Central Inventory
cp -a $ORACLE_BASE/oraInventory $ORACLE_BASE/oraInventory.bak_$(date +%Y%m%d)
```

### 5. Install new OPatch via opatch_generic.jar

```bash
# Standard installation
$JDK_HOME/bin/java -jar /tmp/opatch_upgrade/6880880/opatch_generic.jar \
    -silent \
    oracle_home=$ORACLE_HOME

# If using a custom oraInst.loc location:
$JDK_HOME/bin/java -jar /tmp/opatch_upgrade/6880880/opatch_generic.jar \
    -silent \
    oracle_home=$ORACLE_HOME \
    -invPtrLoc $ORACLE_BASE/oraInst.loc

# If /tmp is mounted noexec (common in hardened environments):
$JDK_HOME/bin/java \
    -Djava.io.tmpdir=$ORACLE_BASE/tmp \
    -jar /tmp/opatch_upgrade/6880880/opatch_generic.jar \
    -silent \
    oracle_home=$ORACLE_HOME
```

Log locations:
- Success: `$ORACLE_BASE/oraInventory/logs/`
- Failure: `/tmp/OraInstall<TIMESTAMP>/`  (or custom tmpdir)
- On any issue: see Doc ID 2759112.1

### 6. Verify new OPatch version

```bash
$ORACLE_HOME/OPatch/opatch version
# Expected: OPatch Version: 13.9.4.2.22

$ORACLE_HOME/OPatch/opatch lsinventory
```

### 7. Cleanup staging area

```bash
rm -rf /tmp/opatch_upgrade
```

> **Note on NGINST patches:** Patches 31101362, 29137924, and 29909359 are
> already included in OPatch 13.9.4.2.22. Do **not** attempt to apply them
> separately — they will cause an error. If they were applied previously, they
> will remain in the inventory harmlessly.

---

---

## Patch 38566996 – UMS Bundle Patch 14.1.2.0.251022

**Patch:** 38566996
**Platform:** Generic
**Product:** Service Delivery Platform (UMS)
**Released:** 24-Oct-2025
**Requires OPatch:** ≥ 13.9.4.2.17 (install 13.9.4.2.22 via Patch 28186730, see above)

### Zero Downtime Patching

This patch is eligible for **Zero Downtime Patching** of type `FMW_ROLLING_ORACLE_HOME`.
ZDT allows patching without service interruption in a running cluster.

> At this point in the installation sequence no domain exists yet, so the standard
> offline procedure (stop → patch → start) applies. ZDT becomes relevant for
> re-patching a live production system later.
>
> Doc ID 1942159.1 — Introduction to Zero Downtime Patching for Oracle Fusion Middleware

### 8. Prerequisites

```bash
# 1. Verify OPatch version (must be ≥ 13.9.4.2.17)
$ORACLE_HOME/OPatch/opatch version

# 2. Validate inventory
$ORACLE_HOME/OPatch/opatch lsinventory
$ORACLE_HOME/OPatch/opatch lspatches
```

Recommended backup before patching (no domain yet → ORACLE_HOME + inventory only):

```bash
cp -a $ORACLE_HOME           $ORACLE_HOME.bak_$(date +%Y%m%d)
cp -a $ORACLE_BASE/oraInventory  $ORACLE_BASE/oraInventory.bak_$(date +%Y%m%d)
```

Once a domain exists, also back up `$DOMAIN_HOME`.

### 9. Prepare patch staging area

```bash
MW_PATCHES=/tmp/mw_patches
mkdir -p $MW_PATCHES

# Unzip the patch (preserve permissions with -p on Linux)
unzip -d $MW_PATCHES $PATCH_STORAGE/patches/38566996/p38566996_141200_Generic.zip

ls $MW_PATCHES/38566996/
# → patch metadata + sub-patches

# Add OPatch to PATH
export PATH=$ORACLE_HOME/OPatch:$PATH
export ORACLE_HOME=$ORACLE_HOME   # must be set
```

### 10. Stop all processes

No domain exists at this stage — nothing to stop. For later re-patching:

```bash
# Stop Managed Servers, Admin Server, Node Manager
# (handled by 01-Run/ scripts once domain is running)
```

### 11. Apply the patch

```bash
cd $MW_PATCHES/38566996
opatch apply
```

OPatch will prompt for confirmation. In silent mode:

```bash
cd $MW_PATCHES/38566996
opatch apply -silent -jdk $JDK_HOME
```

Check OPatch output for `OPatch succeeded`. Any warnings or errors are logged to
`$ORACLE_HOME/cfgtoollogs/opatch/`.

### 12. Verify patch is installed

```bash
opatch lspatches | grep 38566996
# Expected: 38566996;Oracle UMS Bundle Patch 14.1.2.0.251022

opatch lsinventory | grep -E "Patch [0-9]+"
```

### 13. Cleanup staging area

```bash
rm -rf $MW_PATCHES
```

### 14. Start all processes

No domain exists at this stage — nothing to start yet.

---

### Deinstallation (rollback)

If the patch causes problems after a domain is running:

```bash
# 1. Stop all processes

# 2. Navigate to patch staging (re-unzip if cleaned up)
mkdir -p /tmp/mw_patches
unzip -d /tmp/mw_patches $PATCH_STORAGE/patches/38566996/p38566996_141200_Generic.zip

cd /tmp/mw_patches/38566996
opatch rollback -id 38566996

# 3. Verify removal
opatch lspatches | grep 38566996   # must return nothing

# 4. Reverse any post-installation changes (none for this patch)

# 5. Start all processes
```

> For a complete rollback, restore from backup: `$ORACLE_HOME` + Central Inventory
> (+ `$DOMAIN_HOME` if a domain was created after patching).

---

## What the Script Does

- Reads `ORACLE_HOME`, `JDK_HOME`, `PATCH_STORAGE`, `ORACLE_BASE` from `environment.conf`
- Reads `INSTALL_PATCHES`, `OPATCH_VERSION_MIN`, `OPATCH_UPGRADE_PATCH_NR` from `oracle_software_version.conf`
- **OPatch upgrade** (if current version < `OPATCH_VERSION_MIN`):
  - Checks for patch 23335292 in inventory; rolls it back if present (waits 20 s)
  - Backs up `$ORACLE_HOME/OPatch` and `$ORACLE_BASE/oraInventory`
  - Unzips Patch 28186730 to a temp directory
  - Runs `opatch_generic.jar -silent oracle_home=...` to install new OPatch via OUI tooling
  - Verifies the installed version matches `OPATCH_VERSION_MIN`
  - Cleans up temp directory
- **Conflict check** for all `INSTALL_PATCHES` before any apply
- Aborts if any conflict is found
- **Applies patches** in the order they appear in `INSTALL_PATCHES`
- Verifies each patch appears in `opatch lsinventory` after apply
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
- **OPatch upgrade uses `opatch_generic.jar`** — not a plain unzip. Since OPatch >= 13.6
  the OUI metadata must be updated; a plain unzip bypasses this and can cause upgrade issues
- **No rollback for OPatch** — there is no mechanism to revert to a previous OPatch version.
  The only recovery is restoring from backup. Always back up before upgrading
- **Patch 23335292 pre-check** is mandatory per the OPatch README: roll it back before
  upgrading, wait 15–30 seconds, do not roll it back after the upgrade
- **NGINST patches** 31101362, 29137924, 29909359: already included in OPatch 13.9.4.2.22,
  do not apply separately
- If an OPatch upgrade fails: see Doc ID 2759112.1 and check `/tmp/OraInstall<TIMESTAMP>/`
- If a patch apply fails: check `$ORACLE_HOME/cfgtoollogs/opatch/` for detailed logs
