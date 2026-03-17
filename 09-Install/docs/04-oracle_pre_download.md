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
| `OPATCH_VERSION_INSTALL` | `13.9.4.2.22` | OPatch version installed by Patch 28186730 |
| `OPATCH_VERSION_MIN` | `13.9.4.2.17` | Minimum version required by current CPU |

> **Why Patch 28186730, not 6880880?** Since OPatch >= 13.6, OPatch must be installed
> via its own `opatch_generic.jar` (OUI tooling) to keep the OUI metadata in sync.
> A plain unzip of the raw OPatch files (Patch 6880880) still works mechanically but
> leaves the inventory inconsistent. Patch 28186730 is the FMW/WLS-specific upgrade
> package; when unzipped it contains a `6880880/` subdirectory with `opatch_generic.jar`.
> See [05-oracle_patch_weblogic.md](05-oracle_patch_weblogic.md) for the full procedure.

### Post-Install Patches (getMOSPatch, in apply order)

Patch numbers are determined by the Oracle CPU release cycle.
The procedure for finding the correct current patch numbers is documented in:

→ **[05-oracle_patch_weblogic.md](05-oracle_patch_weblogic.md)** – WLS/FMW Infrastructure patches
→ **[06-oracle_patch_forms_reports.md](06-oracle_patch_forms_reports.md)** – Forms & Reports patches

Current configuration in `oracle_software_version.conf`:

| Variable | Value | Description |
|---|---|---|
| `INSTALL_PATCHES` | `38566996` | CPU Jan 2026 – UMS Bundle Patch 14.1.2.0.251022 |

`INSTALL_PATCHES="38566996"` — apply in this order after OPatch upgrade.
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

### 4. Download CPU patches

Determine current patch numbers first — see
[05-oracle_patch_weblogic.md](05-oracle_patch_weblogic.md) (Section "How to Find the Correct Patch Numbers").

```bash
# Current CPU Jan 2026:
mkdir -p $PATCH_STORAGE/patches/38566996
cd $PATCH_STORAGE/patches/38566996
java -jar $PATCH_STORAGE/bin/getMOSPatch.jar \
    MOSUser="..." MOSPass="..." \
    patch=38566996 download=all
```

### 5. Apply OPatch and patches (after FMW installation)

OPatch upgrade and patch apply are handled by `05-oracle_patch_weblogic.sh`.
See [05-oracle_patch_weblogic.md](05-oracle_patch_weblogic.md) for the full manual procedure.

```bash
# Automated (recommended):
./09-Install/05-oracle_patch_weblogic.sh --apply

# Manual procedure: see docs/05-oracle_patch_weblogic.md
```

---

## What the Script Does

- Reads `MOS_USER`, `PATCH_STORAGE`, `INSTALL_COMPONENTS` from `environment.conf`
- Reads versions, filenames, patch numbers from `oracle_software_version.conf`
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
  - Downloads each patch from `INSTALL_PATCHES` to `$PATCH_STORAGE/patches/<nr>/`
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
    │   └── p28186730_139422_Generic.zip     ← contains 6880880/opatch_generic.jar
    └── 38566996/                 ← CPU Jan 2026: UMS Bundle Patch (getMOSPatch, INSTALL_PATCHES)
        └── p38566996_141200_Generic.zip
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
```

---

## Notes

- `getMOSPatch.jar` is downloaded automatically from GitHub on first use (`wget` or `curl` required)
- MOS account requires an active Oracle support contract
- eDelivery account may require a separate registration at edelivery.oracle.com
- Always update OPatch (Patch 28186730) **before** applying any CPU patches
- OPatch upgrade uses `opatch_generic.jar` (OUI tooling) — not a plain unzip of Patch 6880880
- Patch numbers for WLS/FMW patches: → [05-oracle_patch_weblogic.md](05-oracle_patch_weblogic.md)
- Patch numbers for Forms & Reports patches: → [06-oracle_patch_forms_reports.md](06-oracle_patch_forms_reports.md)
- Current OPatch minimum for CPU Jan 2026: ≥ 13.9.4.2.17 (installed: 13.9.4.2.22 via Patch 28186730)
