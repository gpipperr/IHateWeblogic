# MOS Reference Documents – FMW 14.1.2 Patching

Central lookup of My Oracle Support (MOS) Doc IDs used across the patch
scripts (`05-oracle_patch_weblogic.sh`, `06-oracle_patch_forms_reports.sh`,
`04-oracle_pre_download.sh`) and their docs, plus the full patch list for
the currently configured cycle. Doc IDs and patch numbers change every
quarter — this file is a starting point for the next check, not a
substitute for re-verifying against MOS before each patch cycle.

| Doc ID | Title | Used for |
|---|---|---|
| **KA1182** | CPU/CSPU Patch Advisor for Oracle Fusion Middleware | Main entry point for current WLS 14.1.2 and Forms/Reports 14.1.2 patch numbers each quarter |
| **KA204** | Oracle Forms and Reports Quarterly Patch Release (QPR) Information | Current Forms/Reports QPR patch numbers |
| CPU211 | Patch Availability Document FMW, CPU July 2026 | Historical reference for the July 2026 cycle |
| CPU349 | CSPU September 2026 for Oracle Java SE | Current recommended JDK version/patch for the Sep 2026 cycle |
| KB168467 | Stack Patch Bundle (SPB) with SPBAT Utility | Background on the SPB/SPBAT mechanism reintroduced for 14.1.2 in CSPU Sep 2026 — see the corrected note in `docs/05-oracle_patch_weblogic.md` |
| KB175049 | Installing and maintaining Java SE for FMW 11g/12c/14c | JDK install/update procedure, referenced by `02b-root_os_java.sh` |
| KB159467 | Restricting Incoming Serialized Java Objects (JEP 290) | Why an up-to-date JDK is required for the WLS PSU deserialization fixes to take effect |
| KB694158 | Security Advice and Post-Install for WLS PSUs | Post-install steps after applying the WLS Stack Patch Bundle / SPU |
| KB559857 | Cumulative README Post-Install Steps for OHS 14.1.2.0 Bundle Patches | Only relevant if OHS is co-located in the same Oracle Home (conditional patch 39597026) |
| KB118538 | Native Network Encryption (NNE), DB compatibility (CVE-2021-2351) | Minimum requirement for the external repository database (RCU) |
| KB618392 | Zero Downtime Patching for FMW/WLS (legacy Doc ID 1942159.1) | Background on ZDT patching for a live production system (not used during initial install, no domain exists yet) |

## How to use this table

1. Before a new patch cycle, open KA1182 on MOS and compare the current
   patch numbers against `09-Install/oracle_software_version.conf`.
2. If a Doc ID listed here has been superseded or renumbered by Oracle,
   update this table — do not silently start referencing a new number
   from inline comments elsewhere, this table is the single place to look.
3. Patch numbers themselves live in `oracle_software_version.conf`, not
   here — the tables below are a point-in-time snapshot for reference,
   `oracle_software_version.conf` is the source of truth the scripts read.

---

## Patch List — CSPU September 2026 cycle

Target: Oracle Reports 14.1.2.0.0 (Reports only) on Linux x86-64 (Oracle
Linux 9), Nginx as frontend.

### Required for a Reports-only install

| # | Patch | Description | Release | File (getMOSPatch) |
|---|---|---|---|---|
| 1 | 35702194 | Java SE 21.0.12.1 or higher (JDK 17 alternative: Patch 33181589, 17.0.20.1+) | CSPU Sep 2026 | platform-dependent |
| 2 | 28186730 | OPatch for FMW/WLS 14.1.2.0.0 | CPU | standalone MOS download currently only offers **13.9.4.2.22** (`p28186730_1394222_Generic.zip`); **13.9.4.2.24** — the version this project's `OPATCH_VERSION_MIN` actually requires — is bundled inside the SPB (patch 39925660) at `tools/opatch/generic/p28186730_1394224_Generic.zip` instead; confirmed 2026-10-13, see the caveat in `docs/05-oracle_patch_weblogic.md` |
| 3 | **39925660** | WLS Stack Patch Bundle 14.1.2.0.260825 | CSPU Sep 2026 | `p39925660_141200_Generic.zip` |
| 4 | **39988381** | WLS 14.1.2 SPU for CVE-2026-70748 (in addition to the SPB) | CSPU Sep 2026 | ships 4 product-version variants under one patch number (12.2.1.4.0/14.1.1.0.0/14.1.2.0.0/15.1.1.x) — `05-/06-oracle_patch_*.sh` select the 14.1.2 one automatically via `_select_patch_zip()` in `IHateWeblogic_lib.sh` |
| 5 | 38590500 | FMW PERL Security Patch Update 14.1.2.0.260120 | CPU Jan 2026 | `p38590500_141200_Linux-x86-64.zip` |
| 6 | **39600348** | Oracle Reports Developer QPR 14.1.2.0 | Aug 2026 | `p39600348_141200_Linux-x86-64.zip` — supersedes 38827528 |

### Patch 39988381 — same patch number, two different releases

KA1182 lists Patch 39988381 for both WLS 14.1.2.0 and WLS 15.1.1.0 — same
patch number, different product release and prerequisite patch. Always
confirm the downloaded ZIP's release in `etc/config/inventory.xml` before
applying (see the pitfall note in `docs/05-oracle_patch_weblogic.md`);
`check_patch_zip()` does this automatically before every patch in
`INSTALL_PATCHES` is extracted.

| Release | Patches | Description |
|---|---|---|
| WLS 14.1.2.0 | SPB **39925660** + **39988381** | WLS Stack Patch Bundle 14.1.2.0.260825 + WLS 14.1.2 SPU for CVE-2026-70748 — this project |
| WLS 15.1.1.0 | PSU **39929333** + **39988381** | WLS Patch Set Update 15.1.1.0.260825 + WLS 15.1.1 SPU for CVE-2026-70748 — **not relevant** to this 14.1.2 project |

Source: KA1182, CSPU September 2026.

### Conditional (only if the component is installed in the Oracle Home)

| Patch | Description | Release | Condition |
|---|---|---|---|
| 39842516 | Oracle Forms QPR 14.1.2.0 | Sep 2026 | Only if Forms is in inventory (`opatch lsinventory -details`, component `oracle.forms*`) — supersedes 38874285 |
| 38936596 | One-off for Bug 38936596 (ewt3.jar, BiDi parentheses) | | Only if `REPORTS_BIDIPARENTHESIS=YES` (Hebrew). Per the QPR README the fix is only complete together with 39600348 |
| 39597026 | OHS Bundle Patch 14.1.2.0.260622 | Jul 2026 | Only if OHS is in the same Home (typically not installed with an Nginx frontend). Post-install per KB559857 |
| 39100536 | OAM WebGate Bundle Patch 14.1.2.0.260318 | Apr 2026 | Only if WebGate is installed |
| WLS Proxy Plug-In | see KA1182 | | Only for IIS/Apache as a proxy — not relevant with Nginx |

### Content of SPB 39925660 (applied in full via SPBAT or `opatch napply`)

| Patch | Content |
|---|---|
| 39925694 | SPB marker (interim 39925664), makes the SPB visible in `lsinventory` |
| 39798193 | RDA 26.3.2026915 for FMW 14.1.2.0.0 |
| 39919611 | WLS PSU 14.1.2.0.260823 |
| 38063775 | WebLogic Samples Patch 14.1.2.0.250715 |
| 39864483 | Coherence 14.1.2.0 Cumulative Patch 9 (14.1.2.0.9) |
| 39264447 | Database RU 23.26.2.0.0 for FMW DBCLIENT |
| 39487373 | JDBC 23.26.2 Bundle Patch 14.1.2.0.260603 |
| 28186730 | OPatch 13.9.4.2.24 (see the row above — this is the actual source of the .24 build) |
| 39916998 | FMW Thirdparty Bundle Patch 14.1.2.0.260821 |
| 38391376 | Fix: RCU prereq steps fail on DB connect validation |

### Superseded (kept for context, not read by any script)

| Old patch | Superseded by |
|---|---|
| 38566996 | UMS Bundle Patch 14.1.2.0.251022 (CPU Jan 2026) — kept in `INSTALL_PATCHES` pending confirmation of a CSPU Sep 2026 successor, see `oracle_software_version.conf` |
| 38827528 | → 39600348 (Reports QPR) |
| 38874285 | → 39842516 (Forms QPR) |
