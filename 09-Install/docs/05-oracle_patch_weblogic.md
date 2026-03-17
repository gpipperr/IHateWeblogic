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

- Reads `ORACLE_HOME`, `JDK_HOME`, `PATCH_STORAGE` from `environment.conf`
- Reads `INSTALL_PATCHES`, `OPATCH_VERSION_MIN`, `OPATCH_REGEXP` from `oracle_software_version.conf`
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
