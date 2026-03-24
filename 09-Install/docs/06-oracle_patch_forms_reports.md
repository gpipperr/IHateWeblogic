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

Defined in `09-Install/oracle_software_version.conf` (space-separated):

```bash
# QPR Jan 2026:
INSTALL_PATCHES_FR="38827528"
```

Current patches (Jan 2026):

| Patch | Product | Version | Platform | Date | Size | Bugs |
|---|---|---|---|---|---|---|
| `38874285` | Oracle Forms | 14.1.2.0.0 | Linux x86-64 | 22-Jan-2026 | 7.0 MB | 43 |
| `38827528` | Oracle Reports Developer | 14.1.2.0.0 | Linux x86-64 | 22-Jan-2026 | 266.9 KB | 5 |

**Forms `38874285` key fixes:**
OLE2 crash (FRM-93652), dark color scheme text visibility, Hebrew/English display,
REST Package Designer (RPD) multiple FRM-15758 fixes, FADS deploy failures,
Forms compiler seg fault after DB Client 23.8 upgrade (`38351061`),
ORA-03113 on cancel query (`38477700`), authentication failure in Forms/JBean (`38743543`).

**Reports `38827528` key fixes:**
rwconverter ORA-00933 (`35740116`), Hebrew text with parenthesis (`36475147`),
ADB 23ai SRW package registration PLS-01918 (`37548468`),
REP-52275 in job status view (`37595589`),
cgicmd.dat encryption for password values (`37756029`).

> **Note on KA204 platform confusion:** The KA204 article lists the Forms QPR entry
> under a "12.2.1.19" label without an OS filter. The correct Linux-x86-64/14.1.2.0.0
> patch is `38874285` — verify on the MOS patch detail page before downloading.

To add a future FR-specific patch:
1. Download the patch ZIP via `04-oracle_pre_download.sh --apply --mos`
   (reads `INSTALL_PATCHES_FR` automatically)
2. Add the patch number to `INSTALL_PATCHES_FR` in `oracle_software_version.conf`
3. Run `06-oracle_patch_forms_reports.sh --check-only` first
4. Run `06-oracle_patch_forms_reports.sh --apply`

---

## Without the Script (manual)

### 1. Conflict check

```bash
cd $PATCH_STORAGE/patches/<PATCH_NR>/
$ORACLE_HOME/OPatch/opatch prereq CheckConflictAgainstOHWithDetail \
    -ph .
```

> `/etc/oraInst.loc` is found automatically — no `-invPtrLoc` needed.
> Created by `03-root_user_oracle.sh` or `60-RCU-DB-19c/00-root_db_os_baseline.sh`.

### 2. Apply patch

```bash
cd $PATCH_STORAGE/patches/<PATCH_NR>/
$ORACLE_HOME/OPatch/opatch apply \
    -silent \
    -jdk $JDK_HOME
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

---

## How to Find the Current F&R QPR Patch Number

Since January 2022 Oracle delivers Forms fixes as **Quarterly Patch Releases (QPRs)**
on the same schedule as the CPU (January / April / July / October).
Oracle Reports was added to this programme in **May 2025**.

**Authoritative source — MOS Knowledge Article KA204:**

> *Oracle Forms and Reports Quarterly Patch Information*
> MOS → Search → Knowledge → **KA204**
> Applies to: Oracle Forms / Reports all versions

The article lists QPR patches per product and version.

**Steps to check for new QPR patches each CPU cycle:**
1. Open MOS → Knowledge → search `KA204`
2. Note the patch numbers listed for **Forms** and **Reports**
3. Click on the patch number → MOS shows a **list of platform-specific patches**
   for that QPR release (Linux, Windows, Solaris, AIX, HP-UX …)
4. Select **Linux x86-64** → verify on the patch detail page:
   - Platform = `Linux x86-64`
   - Product Version = `14.1.2.0.0`
5. Note the patch number for this platform variant
6. Update `INSTALL_PATCHES_FR` in `oracle_software_version.conf`
7. Run `04-oracle_pre_download.sh --apply --mos` to download
8. Run `06-oracle_patch_forms_reports.sh --check-only` then `--apply`

> **KA204 platform selection — important:**
> After clicking a patch link in KA204 you land on a list of platform variants.
> Oracle does **not** sort this list consistently — Linux x86-64 can appear anywhere,
> not necessarily at the top. Scan the full list and select `Linux x86-64` explicitly.
> Do not assume the first entry or the largest file is the correct one.
>
> Additionally, KA204 itself has no OS filter and may mix version labels in the same
> table (e.g. "12.2.1.19" and "14.1.2" entries side by side). Always confirm
> platform **and** product version on the patch detail page before updating the config.

**QPR release schedule:** January / April / July / October (same as CPU).
Oracle Reports joined the QPR programme in **May 2025**.
