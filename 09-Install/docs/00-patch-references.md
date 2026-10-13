# MOS Reference Documents – FMW 14.1.2 Patching

Central lookup of My Oracle Support (MOS) Doc IDs used across the patch
scripts (`05-oracle_patch_weblogic.sh`, `06-oracle_patch_forms_reports.sh`,
`04-oracle_pre_download.sh`) and their docs. Doc IDs and patch numbers
change every quarter — this table is a starting point for the next check,
not a substitute for re-verifying against MOS before each patch cycle.

Last verified: 2026-10-13, against CSPU September 2026
(`90-Source-MetaData/claude-memory/FMW14_Reports_Patch_CSPU_2026-09.md`).
Next CPU: 2026-10-20 — re-check KA1182 after that date.

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
   here — this table only tracks the *reference documents* used to find
   them.
