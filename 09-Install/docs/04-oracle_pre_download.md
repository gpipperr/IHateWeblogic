# Step 1b – 04-oracle_pre_download.sh

**Script:** `09-Install/04-oracle_pre_download.sh`
**Runs as:** `oracle`
**Phase:** 1 – Pre-Install

---

## Download Sources

FMW 14.1.2 software comes from **two different sources** — the script handles both:

| Source | What | How |
|---|---|---|
| **eDelivery** (Oracle Software Delivery Cloud) | Base installers (V\*.zip) | Manual download, then unzip |
| **MOS** (My Oracle Support) | OPatch + individual patches | `getMOSPatch.jar` (automated) |

Credentials for MOS come from `environment.conf` (`MOS_USER`) and
`mos_sec.conf.des3` (encrypted password).

---

## Configuration File: oracle_software_version.conf

All versions, filenames, and patch numbers are defined in
`09-Install/oracle_software_version.conf`. This file is committed to git —
it contains no credentials.

### Base Installers (eDelivery)

| Variable | Value | Description |
|---|---|---|
| `FMW_INFRA_EDEL_SEARCH` | `Oracle Fusion Middleware Infrastructure 14.1.2.0.0 for Linux x86-64` | eDelivery search term |
| `FMW_INFRA_ZIP` | `V1045135-01.zip` | FMW Infrastructure ZIP (2.1 GB) |
| `FMW_INFRA_FILENAME` | `fmw_14.1.2.0.0_infrastructure.jar` | Extracted installer name |
| `FMW_INFRA_SHA256` | `1AAE35167B…D84E68BD` | SHA-256 checksum |
| `FMW_FR_EDEL_SEARCH` | `Oracle Forms and Reports 14.1.2.0.0` | eDelivery search term |
| `FMW_FR_ZIP` | `V1045121-01.zip` | Forms & Reports ZIP (1.3 GB) |
| `FMW_FR_FILENAME` | `fmw_14.1.2.0.0_fr_linux64.bin` | Extracted installer name |
| `FMW_FR_SHA256` | `01D7A1042F…373175B` | SHA-256 checksum |

> **Note:** `V1045121-01.zip` is listed on eDelivery under both *Oracle Forms 14.1.2.0.0* and
> *Oracle Reports 14.1.2.0.0* — it is the same file (1.3 GB). Download it once.
> Total cart size: **2 distinct files, 3.4 GB** (V1045135-01.zip + V1045121-01.zip).

![Oracle eDelivery – cart showing V1045121-01.zip listed twice under Forms and Reports](assets/edelivery_download_forms_reports_weblogic.jpg)

### OPatch Upgrade (getMOSPatch)

| Variable | Value | Description |
|---|---|---|
| `OPATCH_UPGRADE_PATCH_NR` | `28186730` | FMW/WLS OPatch upgrade package (contains `opatch_generic.jar`) |
| `OPATCH_VERSION_INSTALL` | `13.9.4.2.24` | OPatch version installed by Patch 28186730 |
| `OPATCH_VERSION_MIN` | `13.9.4.2.24` | Minimum version required by the current WLS Stack Patch Bundle |

> **Why Patch 28186730, not 6880880?** Since OPatch >= 13.6, OPatch must be installed
> via its own `opatch_generic.jar` (OUI tooling) to keep the OUI metadata in sync.
> A plain unzip of the raw OPatch files (Patch 6880880) still works mechanically but
> leaves the inventory inconsistent. Patch 28186730 is the FMW/WLS-specific upgrade
> package; when unzipped it contains a `6880880/` subdirectory with `opatch_generic.jar`.
> See [05-oracle_patch_weblogic.md](05-oracle_patch_weblogic.md) for the full procedure.

### WLS Stack Patch Bundle (getMOSPatch)

| Variable | Value | Description |
|---|---|---|
| `WLS_SPB_PATCH_NR` | `39925660` | WLS Stack Patch Bundle 14.1.2.0.260825 (CSPU Sep 2026) |

Large ZIP (several hundred MB) applied via `opatch napply`, not `opatch apply`
— see [05-oracle_patch_weblogic.md](05-oracle_patch_weblogic.md), section
"SPB (CSPU September 2026)", for why this mechanism was reintroduced and
what the apply script does with it.

### Post-Install Patches (getMOSPatch, in apply order)

Patch numbers are determined by the Oracle CPU release cycle.
The procedure for finding the correct current patch numbers is documented in:

→ **[05-oracle_patch_weblogic.md](05-oracle_patch_weblogic.md)** – WLS/FMW Infrastructure patches
→ **[06-oracle_patch_forms_reports.md](06-oracle_patch_forms_reports.md)** – Forms & Reports patches
→ **[00-patch-references.md](00-patch-references.md)** – central list of MOS Doc IDs used to find them

Current configuration in `oracle_software_version.conf`:

| Variable | Value | Description |
|---|---|---|
| `INSTALL_PATCHES` | `39988381 38590500 38566996` | CSPU Sep 2026 WLS SPU + PERL Security Patch, applied via plain `opatch apply` after the SPB above |
| `INSTALL_PATCHES_REPORTS` | `39600348` | Reports 14.1.2 QPR (Aug 2026, Linux-x86-64), supersedes `38827528` |
| `INSTALL_PATCHES_FORMS` | `39842516` | Forms 14.1.2 QPR (Sep 2026, Linux-x86-64), supersedes `38874285` — only downloaded/applied if Forms is part of this install |

All three variables are **space-separated** patch number lists.
`INSTALL_PATCHES` and `WLS_SPB_PATCH_NR` are applied by
`05-oracle_patch_weblogic.sh`; `INSTALL_PATCHES_REPORTS`/
`INSTALL_PATCHES_FORMS` are applied by `06-oracle_patch_forms_reports.sh`,
which also auto-detects whether Forms/Reports is actually installed.
Always update OPatch **before** applying patches.

---

## Purpose

Download FMW 14.1.2 installers and patches into the patch storage directory.
Handles both eDelivery (verification/unzip) and MOS (getMOSPatch.jar) workflows.

---

## Without the Script (manual)

### 1. Download base installers from eDelivery

```
https://edelivery.oracle.com  →  Sign in  →  Software Delivery Cloud
Search: Oracle Fusion Middleware Infrastructure 14.1.2.0.0 for Linux x86-64
  → V1045135-01.zip   Oracle Fusion Middleware 14c Infrastructure for Linux x86-64, 2.1 GB
    SHA-1   F2FD0F9CBDEFEAB5857736609FCF65C32F0E4604
    SHA-256 1AAE35167BDED101E7194AA3D75C26B292010035A36C289A3F90B663D84E68BD

Search: Oracle Forms and Reports 14.1.2.0.0
  → V1045121-01.zip   Oracle Fusion Middleware 14c Forms and Reports for Linux x86-64, 1.3 GB
    SHA-1   FE811A063A3A51DB71CB5B1812580940147119BC
    SHA-256 01D7A1042F0896FA5BDDD1EA268C1B60452476032819AAA307A789B15373175B
    (same file listed under "Oracle Forms" and "Oracle Reports" – download once)
```

Place the ZIPs in the correct PATCH_STORAGE subdirectories:

```bash
mkdir -p $PATCH_STORAGE/wls $PATCH_STORAGE/fr

cp V1045135-01.zip $PATCH_STORAGE/wls/
cp V1045121-01.zip $PATCH_STORAGE/fr/

# Verify checksums
sha256sum $PATCH_STORAGE/wls/V1045135-01.zip
# expected: 1AAE35167BDED101E7194AA3D75C26B292010035A36C289A3F90B663D84E68BD

sha256sum $PATCH_STORAGE/fr/V1045121-01.zip
# expected: 01D7A1042F0896FA5BDDD1EA268C1B60452476032819AAA307A789B15373175B
```

Then use `04-oracle_pre_download.sh --apply` to verify, or unzip manually:

```bash
unzip $PATCH_STORAGE/wls/V1045135-01.zip -d $PATCH_STORAGE/wls/
unzip $PATCH_STORAGE/fr/V1045121-01.zip  -d $PATCH_STORAGE/fr/
```

### 2. getMOSPatch.jar (automatic)

The script downloads `getMOSPatch.jar` automatically from GitHub if it is not yet present:

```
https://raw.githubusercontent.com/MarisElsins/getMOSPatch/master/getMOSPatch.jar
→ $PATCH_STORAGE/bin/getMOSPatch.jar
```

Either `wget` or `curl` must be installed. The `.getMOSPatch.cfg` is also created automatically.

**Manual fallback** (if GitHub is unreachable):

```bash
mkdir -p $PATCH_STORAGE/bin
# download getMOSPatch.jar from https://github.com/MarisElsins/getMOSPatch
cp getMOSPatch.jar $PATCH_STORAGE/bin/
```

Platform codes in `.getMOSPatch.cfg`: `226P` = Linux x86-64 · `233P` = Linux ARM 64 · `46P` = Windows x86-64

### 3. Download OPatch upgrade patch (Patch 28186730)

```bash
mkdir -p $PATCH_STORAGE/patches/28186730
cd $PATCH_STORAGE/patches/28186730
java -jar $PATCH_STORAGE/bin/getMOSPatch.jar \
    MOSUser="your.email@company.com" \
    MOSPass="your-mos-password" \
    patch=28186730 download=all
# → downloads p28186730_139422_Generic.zip (or similar)
```

### 4. Download the WLS Stack Patch Bundle (WLS_SPB_PATCH_NR)

```bash
# CSPU Sep 2026 – WLS Stack Patch Bundle (large, several hundred MB):
mkdir -p $PATCH_STORAGE/patches/39925660
cd $PATCH_STORAGE/patches/39925660
java -jar $PATCH_STORAGE/bin/getMOSPatch.jar \
    MOSUser="..." MOSPass="..." \
    patch=39925660 download=all
```

### 5. Download CPU patches (INSTALL_PATCHES)

Determine current patch numbers first — see
[05-oracle_patch_weblogic.md](05-oracle_patch_weblogic.md) (Section "How to Find the Correct Patch Numbers").

```bash
# Current CSPU Sep 2026, applied after the SPB above:
for _p in 39988381 38590500 38566996; do
    mkdir -p $PATCH_STORAGE/patches/$_p
    cd $PATCH_STORAGE/patches/$_p
    java -jar $PATCH_STORAGE/bin/getMOSPatch.jar \
        MOSUser="..." MOSPass="..." \
        patch=$_p download=all
done
```

### 6. Download Forms & Reports QPR patches (INSTALL_PATCHES_REPORTS / INSTALL_PATCHES_FORMS)

Determine current QPR patch numbers from MOS KA204 — see
[06-oracle_patch_forms_reports.md](06-oracle_patch_forms_reports.md) (Section "How to Find the Current F&R QPR Patch Number").

```bash
# Current QPR Aug 2026 – Reports 14.1.2 (supersedes 38827528):
mkdir -p $PATCH_STORAGE/patches/39600348
cd $PATCH_STORAGE/patches/39600348
java -jar $PATCH_STORAGE/bin/getMOSPatch.jar \
    MOSUser="..." MOSPass="..." \
    patch=39600348 download=all
# → p39600348_141200_Linux-x86-64.zip

# Current QPR Sep 2026 – Forms 14.1.2 (supersedes 38874285), only needed
# if Forms is part of this install:
mkdir -p $PATCH_STORAGE/patches/39842516
cd $PATCH_STORAGE/patches/39842516
java -jar $PATCH_STORAGE/bin/getMOSPatch.jar \
    MOSUser="..." MOSPass="..." \
    patch=39842516 download=all
# → p39842516_141200_Linux-x86-64.zip
```

### 7. Apply OPatch and patches (after FMW installation)

OPatch upgrade, WLS Stack Patch Bundle, and WLS patch apply are handled by
`05-oracle_patch_weblogic.sh`; F&R QPR patches by
`06-oracle_patch_forms_reports.sh`.

```bash
# Automated (recommended):
./09-Install/05-oracle_patch_weblogic.sh --apply       # OPatch upgrade + SPB + INSTALL_PATCHES
./09-Install/06-oracle_patch_forms_reports.sh --apply  # INSTALL_PATCHES_REPORTS / INSTALL_PATCHES_FORMS

# Manual procedure: see docs/05-oracle_patch_weblogic.md
#                   see docs/06-oracle_patch_forms_reports.md
```

---

## What the Script Does

- Reads `MOS_USER`, `PATCH_STORAGE`, `INSTALL_COMPONENTS` from `environment.conf`
- Reads versions, filenames, patch numbers from `oracle_software_version.conf`
- **`--fresh-patches`** (with `--apply`): archives `$PATCH_STORAGE/patches/` to
  `patches_<timestamp>/` before anything else, then creates a clean, empty
  `patches/` directory — `wls/`/`fr/` (the large eDelivery base installers)
  are untouched, since their checksum check already guarantees freshness
- **eDelivery ZIPs** (always with `--apply`):
  - Creates `$PATCH_STORAGE/wls/` and `$PATCH_STORAGE/fr/` directories
  - Manual mode: prompts user to place ZIPs, then verifies ZIP magic bytes + SHA-256
  - Wget mode (`--wget`): prompts for Bearer Token, then prompts per-file for download URL
  - Skips files that are already present with a valid checksum
- **getMOSPatch** (with `--mos` or `--all`):
  - Decrypts MOS password from `mos_sec.conf.des3` (written by `01-setup-interview.sh`)
  - Creates/verifies `$PATCH_STORAGE/bin/.getMOSPatch.cfg` (platform + language)
  - Downloads OPatch upgrade **Patch `OPATCH_UPGRADE_PATCH_NR`** (`28186730`) to `$PATCH_STORAGE/patches/28186730/`
    (contains `opatch_generic.jar` — used by `05-oracle_patch_weblogic.sh`)
  - Downloads the **WLS Stack Patch Bundle `WLS_SPB_PATCH_NR`** (`39925660`) to
    `$PATCH_STORAGE/patches/39925660/`, if set (skips if empty)
  - Downloads each patch from `INSTALL_PATCHES` to `$PATCH_STORAGE/patches/<nr>/`
  - Downloads each patch from `INSTALL_PATCHES_REPORTS` and
    `INSTALL_PATCHES_FORMS` (plus `INSTALL_PATCHES_FR_OPTIONAL` if
    `REPORTS_BIDIPARENTHESIS=YES`) to `$PATCH_STORAGE/patches/<nr>/`
    (skips entirely if all three are empty)
  - Skips patches already present in their target directory
  - Clears MOS password from memory after use
- Reports download summary: OK/WARN/FAIL counts

---

## Patch Storage Layout

```
$PATCH_STORAGE/
├── bin/
│   ├── getMOSPatch.jar           ← auto-downloaded from GitHub on first --mos run
│   └── .getMOSPatch.cfg          ← platform (226P) + language (4L)
├── wls/
│   ├── V1045135-01.zip           ← eDelivery: FMW Infrastructure 14.1.2 (manual/wget)
│   └── fmw_14.1.2.0.0_infrastructure.jar   ← extracted
├── fr/
│   ├── V1045121-01.zip           ← eDelivery: Forms & Reports 14.1.2 (manual/wget)
│   └── fmw_14.1.2.0.0_fr_linux64.bin       ← extracted
└── patches/
    ├── 28186730/                 ← OPatch upgrade package (getMOSPatch, OPATCH_UPGRADE_PATCH_NR)
    │   └── p28186730_1394222_Generic.zip    ← contains 6880880/opatch_generic.jar
    │       (confirmed on MOS: 13.9.4.2.22, NOT .24 – see caveat below)
    ├── 39925660/                 ← CSPU Sep 2026: WLS Stack Patch Bundle (getMOSPatch, WLS_SPB_PATCH_NR)
    │   └── p39925660_141200_Generic.zip     ← applied via opatch napply, not apply
    ├── 39988381/                 ← CSPU Sep 2026: WLS SPU CVE-2026-70748 (getMOSPatch, INSTALL_PATCHES)
    ├── 38590500/                 ← FMW PERL Security Patch (getMOSPatch, INSTALL_PATCHES)
    ├── 38566996/                 ← CPU Jan 2026: UMS Bundle Patch (getMOSPatch, INSTALL_PATCHES)
    │   └── p38566996_141200_Generic.zip
    ├── 39600348/                 ← QPR Aug 2026: Reports 14.1.2 QPR (getMOSPatch, INSTALL_PATCHES_REPORTS)
    │   └── p39600348_141200_Linux-x86-64.zip
    └── 39842516/                 ← QPR Sep 2026: Forms 14.1.2 QPR (getMOSPatch, INSTALL_PATCHES_FORMS)
        └── p39842516_141200_Linux-x86-64.zip
```

> **Note:** The `opatch/` directory from older versions of this guide no longer exists.
> Patch 28186730 (in `patches/28186730/`) replaces the direct download of Patch 6880880.
> The `05-oracle_patch_weblogic.sh` script unzips Patch 28186730 and uses the
> `6880880/opatch_generic.jar` inside it for the OPatch upgrade.
>
> Patch numbers for future CPU releases change quarterly — see
> [05-oracle_patch_weblogic.md](05-oracle_patch_weblogic.md) for the discovery workflow.

---

## Flags

| Flag | Description |
|---|---|
| (none) | Dry-run: show expected paths and checksums |
| `--apply` | eDelivery: create dirs, prompt manual file placement, verify |
| `--apply --wget` | eDelivery via Bearer Token wget instead of manual copy |
| `--apply --mos` | eDelivery + getMOSPatch: OPatch + post-install patches |
| `--apply --all` | Alias for `--apply --mos` |
| `--apply --wget --mos` | Bearer Token wget + getMOSPatch (fully automated) |
| `--fresh-patches` | Archive `patches/` to `patches_<timestamp>/` first, then download into a clean directory |
| `--help` | Show usage |

### Typical workflow

```bash
# First run: dry-run to review what will be done
./09-Install/04-oracle_pre_download.sh

# eDelivery only – place ZIPs manually, then verify
./09-Install/04-oracle_pre_download.sh --apply

# eDelivery via wget + MOS patches in one go
./09-Install/04-oracle_pre_download.sh --apply --wget --mos

# MOS patches only (eDelivery ZIPs already in place)
./09-Install/04-oracle_pre_download.sh --apply --mos

# Start of a new patch cycle (CPU/CSPU/QPR) – avoid mixing with leftover
# builds from the previous cycle: archive patches/ first, then download fresh
./09-Install/04-oracle_pre_download.sh --apply --fresh-patches --mos
```

> **Why this matters:** the per-patch skip-if-present check only looks for
> *any* ZIP already in a patch's destination directory, not whether it is
> the build actually needed this cycle. A patch number can also ship several
> product-version variants under the same number (e.g. one ZIP per
> `12.2.1.4.0`/`14.1.1.0.0`/`14.1.2.0.0`/...) – leftover files from an older
> run, or picking the wrong variant, are both avoided by starting from a
> clean `patches/` directory at the start of each new patch cycle.

---

## Notes

- `getMOSPatch.jar` is downloaded automatically from GitHub on first use (`wget` or `curl` required)
- MOS account requires an active Oracle support contract
- eDelivery account may require a separate registration at edelivery.oracle.com
- Always update OPatch (Patch 28186730) **before** applying any CPU patches
- OPatch upgrade uses `opatch_generic.jar` (OUI tooling) — not a plain unzip of Patch 6880880
- Patch numbers for WLS/FMW patches: → [05-oracle_patch_weblogic.md](05-oracle_patch_weblogic.md)
- Patch numbers for Forms & Reports patches: → [06-oracle_patch_forms_reports.md](06-oracle_patch_forms_reports.md)
- Central list of MOS Doc IDs: → [00-patch-references.md](00-patch-references.md)
- Current OPatch minimum for the CSPU Sep 2026 WLS Stack Patch Bundle: ≥ 13.9.4.2.24 (installed via Patch 28186730)
