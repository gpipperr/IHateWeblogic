# Step 2b – 05-oracle_patch_weblogic.sh

**Script:** `09-Install/05-oracle_patch_weblogic.sh`
**Runs as:** `oracle`
**Phase:** 2 – WebLogic Installation

> **Scope: FMW 14.1.2.0.0 only.**
> This document describes the patching procedure for Oracle Fusion Middleware
> **14.1.2** exclusively. Instructions found elsewhere that reference SPBAT,
> Stack Patch Bundles (SPBs), or the `napply` / `opatch_auto` tools typically
> originate from FMW 12.2.1.x guides and **do not apply here** — see the
> [SPBAT note](#note-on-spbat-and-stack-patch-bundles) below.

---

## How to Find the Correct Patch Numbers

Oracle puts considerable effort into making the patching of their products as
cumbersome as possible, and they usually succeed admirably.

> The walkthrough below uses the January 2026 CPU (Patch 38566996) as a
> worked example of the discovery process itself — it is still the correct
> *procedure*, but the *numbers* are already out of date. For the current
> patch set (including the CSPU September 2026 WLS Stack Patch Bundle), see
> [`docs/00-patch-references.md`](00-patch-references.md) and
> `oracle_software_version.conf` directly.

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

The manual procedure is versioned **per patch cycle** – one folder per cycle
with the analysis (patch list, facts of every patch README) and a
step-by-step guide:

- **current:** [70-Customer-Projects/Forms14_reports14_patch_analyse_10_2026/install_14c_patch_set_october_2026_manual.md](../../70-Customer-Projects/Forms14_reports14_patch_analyse_10_2026/install_14c_patch_set_october_2026_manual.md)
  (CPU October 2026)
- older cycles: the folders `70-Customer-Projects/Forms14_reports14_patch_analyse_<mm>_<yyyy>/`
  and the frozen `00-patch-references_<month>_<year>.md` snapshots – see the
  cycle table in [00-patch-references.md](00-patch-references.md)

This section used to carry manual steps with fixed patch numbers (OPatch,
UMS bundle of January 2026); they aged with every cycle and were removed on
2026-10-24.

---

## What the Script Does

- Reads `ORACLE_HOME`, `JDK_HOME`, `PATCH_STORAGE`, `ORACLE_BASE` from `environment.conf`
- Reads `INSTALL_PATCHES`, `OPATCH_VERSION_MIN`, `OPATCH_UPGRADE_PATCH_NR`,
  `WLS_SPB_PATCH_NR`/`WLS_SPB_MARKER_PATCH`/`WLS_SPB_PATCHLIST_FILE`,
  `FMW_PRODUCT_RELEASE` from `oracle_software_version.conf`
- **OPatch upgrade first** (if current version < `OPATCH_VERSION_MIN`), same
  order as the manual cookbook:
  - Checks for patch 23335292 in inventory; rolls it back if present (waits 20 s)
  - Backs up `$ORACLE_HOME/OPatch` and `$ORACLE_INVENTORY`
  - Extracts **only** the bundled OPatch ZIP (`tools/opatch/generic/p28186730_*.zip`,
    ~60 MB) from the SPB archive, else falls back to the standalone Patch
    28186730 download — see the resolved caveat above
  - Runs `opatch_generic.jar -silent oracle_home=...` to install new OPatch via OUI tooling
  - Verifies the installed version matches `OPATCH_VERSION_MIN`, cleans up its temp dirs
- **WLS Stack Patch Bundle staging + apply** (if `WLS_SPB_PATCH_NR` is set and
  not already applied) — only after the OPatch upgrade: unzips the multi-GB
  SPB under `$ORACLE_BASE/tmp/` and runs `opatch napply` — see "SPB (CSPU
  September 2026)" above; runs before the patches below
- **`--check-only` with an outdated OPatch stops early** with a hint: a
  `napply -report` / conflict check from the old OPatch is not meaningful for
  patches that require the newer one (and would stage the SPB for nothing).
  Live-tested 2026-10-14: the old-OPatch report also failed OPatch's
  `CheckSystemSpace` prerequisite (needs ~5.6 GB free in the `ORACLE_HOME`
  filesystem, on top of the ~4 GB SPB staging when both share one disk)
- **Patch ZIP validation** (`check_patch_zip()`) for every `INSTALL_PATCHES`
  entry, run right after the ZIP is selected and before it is extracted —
  rejects EBS AutoPatch artifacts and release mismatches against
  `FMW_PRODUCT_RELEASE`; aborts the whole run on failure — see "Patch
  39988381" below
- **Conflict check** for all `INSTALL_PATCHES` before any apply. The OPatch
  **output** is evaluated, not only the return code: OPatch reports
  `OPatch succeeded` (rc=0) even when `checkConflictAgainstOHWithDetail` failed.
  A missing prerequisite that is part of the SPB (e.g. 39988381 needs the WLS
  PSU 39919611 from SPB 39925660) is only a WARN in `--check-only` – the SPB is
  merely simulated there; `--apply` installs it first. Everything else is a FAIL.
- Aborts if any conflict is found
- All OPatch calls that would ask "Do you want to proceed? [y|n]" (`napply`,
  `rollback`, `apply`) run with `-silent` – otherwise they fail with rc=73 when
  no terminal is attached (confirmed 2026-10-14)
- **Applies patches** in the order they appear in `INSTALL_PATCHES`
- Verifies each patch appears in `opatch lsinventory` after apply
- Generates a patch report: which patches were applied, which were already present

---

## Flags

| Flag | Description |
|---|---|
| (none) | Show OPatch version, list patches to apply |
| `--apply` | Update OPatch, apply SPB and patches |
| `--check-only` | Run conflict check only, do not apply – needs the new OPatch, stops early otherwise |
| `--apply --opatch-only` | Only upgrade OPatch (small, separate step), then stop |
| `--help` | Show usage |

Recommended order on a fresh install:

```bash
./09-Install/05-oracle_patch_weblogic.sh --apply --opatch-only   # OPatch 13.9.4.2.17 → .24
./09-Install/05-oracle_patch_weblogic.sh --check-only            # SPB napply -report + conflicts
./09-Install/05-oracle_patch_weblogic.sh --apply                 # SPB + INSTALL_PATCHES
```

Disk space: OPatch requires ~5.6 GB free in the `ORACLE_HOME` filesystem for
the SPB, plus ~4 GB for the SPB staging under `$ORACLE_BASE/tmp/`.

---

## Verification

```bash
$ORACLE_HOME/OPatch/opatch lsinventory
# Lists all applied patches with patch number and description

$ORACLE_HOME/OPatch/opatch lspatches
# Compare with the expected list of the current cycle – manual guide
# (70-Customer-Projects/Forms14_reports14_patch_analyse_<mm>_<yyyy>/) step "Start and verify"
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

---

## Note on SPBAT and Stack Patch Bundles

> **Correction (2026-10-13):** This section previously stated that SPBAT/SPBs
> do not apply to FMW 14.1.2. That was accurate for the January 2026 CPU cycle,
> but **Oracle changed the patch delivery model again for the CSPU September
> 2026 cycle** — a WLS Stack Patch Bundle is back, and `05-oracle_patch_
> weblogic.sh` now applies it via `opatch napply`. See
> [`docs/00-patch-references.md`](00-patch-references.md) for the source
> (KA1182, KB168467) and the "SPB (CSPU September 2026)" section below for
> what the script actually does. Do not assume this is stable going
> forward — check KA1182 again before every future patch cycle.

### Background

In the 12.2.1.3/12.2.1.4 timeframe, Oracle FMW installations often combined many
components (WLS, Coherence, ADF, JRF, SOA, MDS, …) in a single ORACLE_HOME, each
with their own patch dependencies. Oracle introduced SPBs to consolidate dozens of
patches into one bundle, and SPBAT to automate the complex sequencing and conflict
resolution across all components. Doc ID 2657920.1 / KB168467 describes SPBAT.

For the January 2026 CPU cycle, FMW 14.1.2 patches were delivered as plain
**CPU Bundle Patches** per component (e.g. `38566996` for UMS/FMW
Infrastructure), applied via plain `opatch apply` — no SPB involved. That is
still true for the small, individual patches this project applies via
`INSTALL_PATCHES` (see `oracle_software_version.conf`).

**For the CSPU September 2026 cycle, Oracle additionally reintroduced a WLS
Stack Patch Bundle** (Patch `39925660`, version `14.1.2.0.260825`) that
consolidates several component patches (RDA, WLS PSU, Coherence, DB client,
JDBC, FMW Thirdparty, OPatch itself, and a few one-offs — see the full
content table in
`90-Source-MetaData/claude-memory/FMW14_Reports_Patch_CSPU_2026-09.md`).
This SPB must be applied via `opatch napply` with the patch list it ships,
**before** the simple per-patch `INSTALL_PATCHES` loop.

### What to do when you find old instructions referencing SPBAT/napply

Not every old reference is automatically wrong anymore — verify against the
current cycle instead of dismissing it outright:

| What you see | What to check |
|---|---|
| References to SPBAT or an SPB with a 14.1.2 version string (e.g. `14.1.2.0.260825`) | Current — this is exactly the CSPU Sep 2026 mechanism, follow it |
| `opatch napply` with a `*_patchlist.txt` file shipped inside a `WLS_SPB_*` directory | Current — same mechanism this script now implements |
| `opatch_auto` / `bsu.sh` | WLS 10.x / 12.1.x era — ignore entirely, not applicable to any 14.1.2 cycle |
| Patch numbers in the 2xxxxxx-3xxxxxx range with no SPB context at all | Likely a pre-Sep-2026 plain CPU bundle (still valid procedure, just via `opatch apply`, not `napply`) |

For FMW 14.1.2: follow the CPU page → MOS Doc ID (KA1182) → check whether an
SPB is listed for the current cycle. If yes, use the "SPB (CSPU September
2026)" procedure below (or whatever Patch ID KA1182 lists for the then-current
quarter); if no SPB is listed, plain `opatch apply` per patch is correct (see the
manual guide of the current cycle, linked under "Without the Script").

### SPB (CSPU September 2026) — what the script does

`05-oracle_patch_weblogic.sh` runs this automatically when `WLS_SPB_PATCH_NR`
is set in `oracle_software_version.conf` (currently `39925660`), inserted
between the OPatch-upgrade step and the `INSTALL_PATCHES` loop (the OPatch
upgrade extracts only its own ZIP from the SPB archive, the full SPB is
staged here, after the upgrade):

1. Skip if the SPB's marker patch (`WLS_SPB_MARKER_PATCH`, currently
   `39925694`) is already in `opatch lspatches` (idempotent)
2. Unzip the downloaded SPB ZIP (`$PATCH_STORAGE/patches/39925660/`) to a
   staging directory under `$ORACLE_BASE/tmp/`
3. Locate the `WLS_SPB_*` directory inside it (the name changes with the SPB
   version, so the script discovers it rather than hardcoding it)
4. Run `opatch napply [-report] -oh $ORACLE_HOME -phBaseFile
   <dir>/binary_patches/linux64_patchlist.txt` — `-report` (dry-run) for
   `--check-only`, the real apply for `--apply`. `JAVA_HOME`/`ORACLE_HOME`
   are unset for the duration of this call only (per the SPB's own README),
   scoped to a subshell with no effect on the rest of the script
5. Verify the marker patch now appears in `opatch lspatches`
6. Remove the staging directory — the ZIP itself stays in `$PATCH_STORAGE/
   patches/39925660/` in case a later `opatch nrollback` is needed

Manual equivalent (for reference, mirrors section 4.3 Variante B of the
source patch plan):

```bash
cd $PATCH_STAGE
unzip -q p39925660_141200_Generic.zip

cd WLS_SPB_14.1.2.0.260825/binary_patches
unset JAVA_HOME
unset ORACLE_HOME
$ORACLE_HOME_SAVED/OPatch/opatch napply -report -oh $ORACLE_HOME_SAVED -phBaseFile linux64_patchlist.txt   # dry-run
$ORACLE_HOME_SAVED/OPatch/opatch napply        -oh $ORACLE_HOME_SAVED -phBaseFile linux64_patchlist.txt   # real apply
```

Disk space: the SPB needs roughly 4 GB free outside `$ORACLE_HOME` to unzip.

Rollback (manual only, not automated by the script): Oracle advises against
rolling back individual patches out of an SPB.

> **Resolved — OPatch 13.9.4.2.24 source (confirmed 2026-10-13):** the
> standalone MOS download of Patch `28186730` (`OPATCH_UPGRADE_PATCH_NR`)
> currently only offers builds up to **13.9.4.2.22**
> (`p28186730_1394221_Generic.zip` / `p28186730_1394222_Generic.zip`) —
> confirmed by actually downloading it, not assumed. The build this
> project's `OPATCH_VERSION_MIN=13.9.4.2.24` requires was found **bundled
> inside the SPB zip itself**, at `WLS_SPB_14.1.2.0.260825/tools/opatch/
> generic/p28186730_1394224_Generic.zip`.
>
> `05-oracle_patch_weblogic.sh` now stages the SPB **before** the OPatch
> upgrade step (new "WLS Stack Patch Bundle ... – Staging" section) and the
> OPatch upgrade prefers the jar bundled inside that staged SPB directory
> (`$SPB_DIR/tools/opatch/generic/p28186730_*.zip`), falling back to the
> standalone download only if the SPB isn't configured or doesn't contain
> one — logged either way as `OPatch upgrade ZIP found (<source>): ...`.
> The SPB archive is unzipped only once and the same staging directory is
> reused by the later `opatch napply` step, instead of unzipping the
> multi-GB archive twice.

```bash
cd WLS_SPB_14.1.2.0.260825/binary_patches
opatch nrollback -oh $ORACLE_HOME -idFile rollback_patchlist.txt
```

> If MOS explicitly references a different mechanism for a specific 14.1.2
> patch cycle, follow that guidance — but verify the Doc ID and version
> string are current for the cycle you are actually installing, not a
> copy-paste from an older cycle (this document itself was wrong about this
> once already, see the correction note above).

---

## Patch 39988381 — Portal README Pitfall and Multi-Release Patch Numbers

> **Resolved — Portal README vs. ZIP README (confirmed 2026-10-14):** the MOS
> portal page for Patch 39988381 displays a README text referencing
> AutoPatch and `patch_39988381.xml` ("ST Checkin description ... This patch
> contains the following unified driver file to be applied with AutoPatch").
> AutoPatch (`adpatch`/`adop`) is an **E-Business Suite** tool and does not
> exist in a WebLogic/FMW Home — this portal text is a wrong template
> placeholder. The ZIP's own `README.txt` is normal, well-formed Oracle WLS
> patch documentation (ZDT eligibility, Prerequisites, Installation
> Instructions) and is trustworthy; confirmed by inspecting the real
> downloaded ZIP contents directly (`unzip -l` / `unzip -p`, read-only, all
> 4 product-version variants). A genuine OPatch package contains
> `etc/config/inventory.xml` + `etc/config/actions.xml`; a wrongly-attached
> package would instead contain `patch_<nr>.xml` or `u<nr>.drv` at the root —
> if you ever see that pattern, do not apply, open an SR.
>
> Separately, 39988381 is reused across two different WLS releases: for
> 14.1.2.0 it pairs with SPB 39925660 (this project); for 15.1.1.0 it pairs
> with PSU 39929333 (not relevant here) — see the table in the cycle
> snapshot `docs/00-patch-references_september_2026.md`. Always verify the downloaded ZIP's actual
> release in `etc/config/inventory.xml`, not just the filename.
>
> `check_patch_zip()` (`00-Setup/IHateWeblogic_lib.sh`) now automates both
> checks for every patch in `INSTALL_PATCHES`, before extraction: rejects
> EBS-pattern artifacts, and compares the majority `version=` value across
> `inventory.xml`'s `<required_components>` entries against
> `FMW_PRODUCT_RELEASE` (`oracle_software_version.conf`) — a majority vote,
> not one hardcoded component name, since the naming convention differs per
> product (`oracle.wls.*` for WLS, `oracle.reports.*` for Reports QPRs,
> `oracle.developer.forms.*` for Forms QPRs, confirmed against real ZIPs of
> each). A patch with only one component (e.g. Patch 38590500's PERL fix,
> whose sole `oracle.perlint` component is versioned by the bundled Perl
> interpreter itself, not the FMW release) is not hard-failed on a mismatch,
> only logged as a warning — the release check genuinely does not apply to
> that patch. It only fits a standard OPatch one-off
> patch — it does **not** apply to the WLS Stack Patch Bundle ZIP (39925660,
> a bundle of many patches with its own `binary_patches/` layout) or the
> OPatch upgrade ZIP (28186730, an OUI installer package with
> `6880880/opatch_generic.jar`, no `inventory.xml`) — those are staged and
> applied through their own, already-existing mechanisms described above.
>
> Next quarterly CPU lands 2026-10-20 — re-check KA1182 after that date for
> renumbered patches.

### New post-install hardening options (Sep/Aug/Jul 2026 editions, F41372-23)

Per Oracle's "Post-Install Actions and Considerations for Oracle WebLogic
Server Patch Set Updates" (F41372-23), the document behind KB694158 — all of
the following are backward-compatible, default-disabled, opt-in settings.
None require any action for this project's current 14.1.2 install; listed
here so they are not missed if a future hardening pass is done:

- **Sep 2026 edition:** new `FeatureCompatibilityMBean.
  WorkContextClassValidationEnabled` attribute, default `false` — when
  enabled, tightens validation of WorkContext class names/resolved classes
  on inbound T3/JMS/IIOP paths, limiting untrusted input to WebLogic
  built-in and product WorkContext implementations.
- **Aug 2026 edition:** additional default-`false` `FeatureCompatibilityMBean`
  attributes (`JNDIAdditionalFactoriesAllowListsEnabled`,
  `JNDIBindingAuthorizationPolicyEnabled`,
  `JNDIOutboundConnectionsAllowListEnabled`, `T3RouteOnlyToTrustedServersEnabled`)
  plus matching `SecurityConfigurationMBean` allowlist attributes
  (`JndiAdditionalInitialContextFactoriesAllowed`,
  `JndiAdditionalReferenceFactoriesAllowed`, `JndiOutboundConnectionsAllowed`,
  each defaulting to an empty string) — enforce JNDI factory/outbound-connection
  allowlists when enabled.
- **Jul 2026 edition:** 3 default-`false` non-WLS system properties:
  `oracle.core.ojdl.loader.LogServerConnectionHardeningEnabled` (binds
  LogServer to loopback only unless `-host` is given explicitly, filters
  incoming socket log messages), `oracle.as.management.logging.LogQuery.
  registeredLogPathValidationEnabled` (restricts log queries to registered
  paths), `oracle.dms.collector.J2EETableGroupProvider.
  deserializationFilterEnabled` (stricter DMS TableGroup/QueryOptions
  deserialization).
