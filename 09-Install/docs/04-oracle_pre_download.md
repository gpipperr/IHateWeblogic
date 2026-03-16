# Step 1b – 04-oracle_pre_download.sh

**Script:** `09-Install/04-oracle_pre_download.sh`
**Runs as:** `oracle`
**Phase:** 1 – Pre-Install Checks

---

## Configuration File: oracle_software_version.conf

Software versions, patch numbers, and download targets are defined in
`09-Install/oracle_software_version.conf`. This file is committed to git
and contains no credentials.

| Variable | Description |
|---|---|
| `MOS_PLATFORM` | getMOSPatch platform code (`226P` = Linux x86-64) |
| `MOS_LANGUAGE` | Language code (`4L` = German, `1` = English) |
| `FMW_INFRA_PATCH_NR` | MOS patch number for `fmw_14.1.2.0.0_infrastructure.jar` |
| `FMW_INFRA_FILENAME` | Expected installer filename |
| `FMW_INFRA_SHA256` | SHA256 checksum from MOS README |
| `FMW_FR_PATCH_NR` | MOS patch number for `fmw_14.1.2.0.0_fr_linux64.bin` |
| `FMW_FR_FILENAME` | Expected installer filename |
| `FMW_FR_SHA256` | SHA256 checksum from MOS README |
| `OPATCH_PATCH_NR` | Always `6880880` |
| `OPATCH_VERSION_MIN` | Minimum OPatch version (`13.9.4.0.0` for FMW 14.1.2) |
| `INSTALL_PATCHES` | Comma-separated post-install patch numbers, in apply order |

**Credentials** (MOS username and password) come from `environment.conf`
(`MOS_USER`) and `mos_sec.conf.des3` (encrypted password).

---

## Purpose

Download FMW 14.1.2 installers and patches from My Oracle Support (MOS) into the
patch storage directory. Uses `getMOSPatch.jar` for automated downloads.

---

## Without the Script (manual)

### 1. Set up getMOSPatch.jar

Download from GitHub: https://github.com/MarisElsins/getMOSPatch

```bash
mkdir -p $PATCH_STORAGE/bin
cp getMOSPatch.jar $PATCH_STORAGE/bin/
```

Create `$PATCH_STORAGE/bin/.getMOSPatch.cfg`:

```
226P;Linux x86-64
4L;German (D)
```

Platform codes: `226P` = Linux x86-64 · `233P` = Linux ARM 64 · `46P` = Windows x86-64

### 2. Download FMW Infrastructure installer (WebLogic)

```bash
cd $PATCH_STORAGE/wls
java -jar $PATCH_STORAGE/bin/getMOSPatch.jar \
    MOSUser="your.email@company.com" \
    MOSPass="your-mos-password" \
    patch=<FMW_INFRA_PATCH_NR> \
    download=all
```

Verify:

```bash
sha256sum fmw_14.1.2.0.0_infrastructure.jar
# Compare to checksum in MOS readme
```

### 3. Download Forms & Reports installer

```bash
cd $PATCH_STORAGE/fr
java -jar $PATCH_STORAGE/bin/getMOSPatch.jar \
    MOSUser="..." MOSPass="..." \
    patch=<FR_PATCH_NR> download=all
```

### 4. Download OPatch

```bash
cd $PATCH_STORAGE/opatch
java -jar $PATCH_STORAGE/bin/getMOSPatch.jar \
    MOSUser="..." MOSPass="..." \
    patch=6880880 download=all
```

### 5. Download individual patches

```bash
for PATCH_NR in 33735326 34374498; do
    mkdir -p $PATCH_STORAGE/patches/$PATCH_NR
    cd $PATCH_STORAGE/patches/$PATCH_NR
    java -jar $PATCH_STORAGE/bin/getMOSPatch.jar \
        MOSUser="..." MOSPass="..." \
        patch=$PATCH_NR download=all
done
```

### 6. Verify SHA256 checksums

Each download from MOS includes a README with the expected SHA256 checksum:

```bash
sha256sum $PATCH_STORAGE/wls/fmw_14.1.2.0.0_infrastructure.jar
sha256sum $PATCH_STORAGE/fr/fmw_14.1.2.0.0_fr_linux64.bin
```

---

## What the Script Does

- Reads `MOS_USER`, `PATCH_STORAGE` from `environment.conf`
- Reads software versions and patch numbers from `09-Install/oracle_software_version.conf`
- Decrypts MOS password from `mos_sec.conf.des3`
- Checks if each installer already exists in `PATCH_STORAGE` (skip if present and checksum OK)
- Downloads missing installers and patches via `getMOSPatch.jar`
- Verifies SHA256 checksum for each downloaded file
- Reports download summary: total size, files downloaded, files skipped

---

## Patch Storage Layout

```
$PATCH_STORAGE/
├── bin/
│   ├── getMOSPatch.jar
│   └── .getMOSPatch.cfg
├── wls/
│   └── fmw_14.1.2.0.0_infrastructure.jar
├── fr/
│   └── fmw_14.1.2.0.0_fr_linux64.bin
├── opatch/
│   └── p6880880_<version>_Generic.zip
└── patches/
    ├── 33735326/
    │   └── p33735326_*.zip
    └── 34374498/
        └── p34374498_*.zip
```

---

## Flags

| Flag | Description |
|---|---|
| (none) | Show what would be downloaded (sizes, checksums) |
| `--apply` | Execute downloads |
| `--force` | Re-download even if files already exist |
| `--help` | Show usage |

---

## Notes

- `getMOSPatch.jar` must be downloaded separately (open source, not bundled)
- MOS account requires an active Oracle support contract
- Some patches require a specific base patch to be applied first — check the README
  in each patch zip for prerequisites
- OPatch version must be ≥ 13.9.4.0.0 for FMW 14.1.2
