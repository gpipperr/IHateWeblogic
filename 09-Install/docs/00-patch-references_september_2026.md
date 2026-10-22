# MOS Reference Documents – FMW 14.1.2 Patching – CSPU September 2026 (frozen)

> **Frozen snapshot** of the patch cycle **CSPU September 2026** (released
> 2026-09-15, configured in this project 2026-10-13 – 2026-10-22). **Do not
> edit.** Superseded by [00-patch-references.md](00-patch-references.md)
> (current cycle, history table at the top).
> Use: rebuild or roll back an environment **by hand** to this patch level –
> e.g. when a later cycle brings a bug. The patch numbers are in the tables
> below; set them in `09-Install/oracle_software_version.conf` (and
> download them with `04-oracle_pre_download.sh --apply --fresh-patches --mos`)
> to reproduce this state. Statements like "next step" or "state of the test
> host" describe the situation of 2026-10-22.


Central lookup of My Oracle Support (MOS) Doc IDs used across the patch
scripts (`05-oracle_patch_weblogic.sh`, `06-oracle_patch_forms_reports.sh`,
`04-oracle_pre_download.sh`) and their docs, plus the full patch list for
the currently configured cycle. Doc IDs and patch numbers change every
quarter — this file is a starting point for the next check, not a
substitute for re-verifying against MOS before each patch cycle.

Most importend URLs'

- https://www.oracle.com/security-alerts/cspusep2026.html
- https://support.oracle.com/support/?documentId=KA1182


| Doc ID | Title | Used for |
|---|---|---|
| **KA1182** | CPU/CSPU Patch Advisor for Oracle Fusion Middleware | Main entry point for current WLS 14.1.2 and Forms/Reports 14.1.2 patch numbers – check **monthly** (CPU and CSPU, see "Terms" below) |
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

1. Every third Tuesday (CPU **or** CSPU), read the public advisory (risk
   matrix: WLS, OPSS, Forms, "Oracle Fusion Middleware"), then open KA1182
   on MOS and compare the current patch numbers against
   `09-Install/oracle_software_version.conf`.
2. If a Doc ID listed here has been superseded or renumbered by Oracle,
   update this table — do not silently start referencing a new number
   from inline comments elsewhere, this table is the single place to look.
3. Set `PATCH_CYCLE`, `PATCH_CYCLE_DATE`, `PATCH_CYCLE_ADVISORY` in
   `oracle_software_version.conf` together with the patch numbers –
   `10-Monitoring/cve_inventory.sh` compares installed patches and newer
   advisories against them.
4. Patch numbers themselves live in `oracle_software_version.conf`, not
   here — the tables below are a point-in-time snapshot for reference,
   `oracle_software_version.conf` is the source of truth the scripts read.

---

## Terms – CPU, CSPU and the patch vehicles

Since May 2026 Oracle publishes security fixes **every month** – two kinds of
advisories alternate:

| Term | What it is | Cadence | Source |
|---|---|---|---|
| **CPU** – Critical Patch Update | The classic **quarterly, cumulative** security release | Jan / Apr / Jul / Oct, third Tuesday | Oracle Security Alerts page |
| **CSPU** – Critical Security Patch Update | "targeted, high-priority security fixes in a smaller, more focused format … Critical Security Patch Updates **complement** Oracle's existing quarterly cumulative Critical Patch Updates (CPUs)" (advisory text, Sep 2026) | Third Tuesday of the **other** months; first one May 2026 ("except the initial May CSPU release") | CSPU advisories Jun/Aug/Sep 2026 |
| **Risk matrix** | Table per product in an advisory: CVE, component, protocol, "remote exploit without auth", CVSS, affected versions. Lists **only newly** fixed vulnerabilities – earlier ones are in the earlier CPU/CSPU advisories | per advisory | advisory |
| **Patch Availability Document** | MOS note mapping the advisory to concrete patch numbers – for FMW **KA1182** (current and previous CPU **and** CSPU patches), Forms/Reports QPRs **KA204** | updated each release | MOS |
| **SPB** – Stack Patch Bundle | One ZIP with WLS PSU + Coherence + JDBC + DB client RU + third-party bundle + OPatch, applied with SPBAT / `opatch napply`. Reintroduced for 14.1.2 with CSPU Sep 2026 | per CPU/CSPU | KB168467 |
| **PSU** – Patch Set Update | Cumulative WLS patch (inside the SPB for 14.1.2, standalone for 15.1.1) | per CPU/CSPU | KA1182 |
| **SPU** – Security Patch Update | Single security fix on top of the SPB/PSU when it was not ready for the bundle (e.g. 39988381 for CVE-2026-70748) | as needed | KA1182 |
| **QPR** – Quarterly Patch Release | Forms / Reports bundles (bug + security fixes) – **not** part of the WLS SPB, applied by `06-` | roughly quarterly, can be referenced by a CSPU | KA204 |

Consequences for this project:

- **Every month** (third Tuesday) check KA1182 – not only in CPU months. A
  CSPU can bring a CVSS 10.0 fix for WLS or Forms (September 2026: five
  CVSS 10.0 in Fusion Middleware, see below).
- A risk matrix lists only the new CVEs. When a cycle was skipped, read
  **every** advisory since the last applied one.
- Patch numbers come from KA1182 / KA204, never from the public advisory –
  the advisory only names products, versions and CVEs.
- Oracle Reports has no own entry in the CSPU Sep 2026 / CPU Oct 2026
  product lists (only "Oracle Fusion Middleware" / WLS / OPSS, which are in
  every Reports home). Forms CVEs matter for a Reports-only home only if the
  Forms component is installed (`opatch lsinventory`, `oracle.forms*`).

### Release dates (from the advisories)

| Date | Type | State 2026-10-18 |
|---|---|---|
| 21 July 2026 | CPU | released |
| 18 August 2026 | CSPU | released |
| 15 September 2026 | CSPU | released – **cycle configured in this project** |
| 20 October 2026 | CPU | pre-release announcement only (1283 patches; FMW 196, WLS 14.1.2.0.0 and "Oracle Fusion Middleware 14.1.2.0.0" affected; Java SE 21.0.12.1 affected → new JDK; Forms / Reports not in the product list) |
| 17 November 2026 | CSPU | planned |
| 15 December 2026 | CSPU | planned |
| 19 January 2027 | CPU | planned |

### Public advisories (no MOS login needed)

All links checked 2026-10-18 (HTTP 200, title matches).

| Advisory | URL |
|---|---|
| Overview – CPUs, CSPUs, Security Alerts and Bulletins | https://www.oracle.com/security-alerts/ |
| CSPU September 2026 | https://www.oracle.com/security-alerts/cspusep2026.html |
| CSPU August 2026 | https://www.oracle.com/security-alerts/cspuaug2026.html |
| CPU July 2026 | https://www.oracle.com/security-alerts/cpujul2026.html |
| CSPU June 2026 | https://www.oracle.com/security-alerts/cspujun2026.html |
| CPU October 2026 (pre-release until 20 Oct) | https://www.oracle.com/security-alerts/cpuoct2026.html |

Naming pattern: `cpu<mon><yyyy>.html` for CPUs, `cspu<mon><yyyy>.html` for
CSPUs. `www.oracle.com` refuses some non-browser clients (HTTP 403) – with
`curl -A "Mozilla/5.0"` it answers.

### CVE check 2026-10-18 – CSPU September 2026

From the Fusion Middleware risk matrix of the CSPU Sep 2026 advisory:

| CVE | Product / component | Protocol | Remote w/o auth | CVSS 3.1 | Affected (our release) | Relevant here |
|---|---|---|---|---|---|---|
| **CVE-2026-83021** | Oracle WebLogic Server / Web Container | HTTP | yes | **10.0** (scope changed) | 12.2.1.4.0, 14.1.1.0.0, **14.1.2.0.0** | **yes** – every installation (WLS_REPORTS, WLS_FORMS, AdminServer) |
| **CVE-2026-83099** | Oracle Forms / Forms Services, C/S, Charmode | HTTP | yes | **10.0** (scope changed) | 12.2.1.19.0, **14.1.2.0.0** | **yes for Forms installs**; Reports-only only if the Forms component is in the home |
| CVE-2026-83020 | Oracle Platform Security for Java (OPSS) / Centralized Thirdparty Jars | HTTP | yes | 10.0 | 12.2.1.4.0, 14.1.2.0.0 | yes – OPSS is in every FMW infrastructure home |
| CVE-2026-83094/95/98/100/108 | Oracle Forms / Forms Services | HTTP | yes | 9.8 | 14.1.2.0.0 | Forms installs |
| CVE-2026-70748/56/57 | Oracle WebLogic Server / Core | T3, IIOP | yes | 9.8 | 14.1.2.0.0 | yes (T3 not exposed through Nginx, but local / internal network) |

A CVE in a risk matrix means "addressed by the patches of this release"
– the advisory has no separate "fixed" flag (the 2026-10-19 copy of the
September advisory is unchanged, still "Rev 1. Initial Release").

Which patch fixes which CVE is **not** in the public advisory and the patch
READMEs name no CVE numbers (checked: SPB 39925660, SPU 39988381, QPR
39842516, QPR 39600348). State of the configured cycle:

| CVE | Expected fix in our patch set | Evidence | Status |
|---|---|---|---|
| CVE-2026-83021 (WLS Web Container) | SPB **39925660** (WLS PSU 14.1.2.0.260823) and/or SPU **39988381** | set taken from KA1182 "CSPU Sep 2026" on 2026-10-13; SPU README dated 2026-09-10, SPB 14.1.2.0.260825 – both before the 15 Sep release | **assumption** – confirm in KA1182 that the CVE row for WLS 14.1.2 points to 39925660 / 39988381 |
| CVE-2026-83099 (Forms Services) | Forms QPR **39842516** (README dated 2026-08-16) | listed as "Sep 2026" in KA204 | **assumption** – confirm in KA1182 / KA204 that the Forms 14.1.2 row of the CSPU Sep 2026 names 39842516 (and no additional one-off) |
| CVE-2026-83020 (OPSS) | SPB 39925660 (FMW Thirdparty Bundle 39916998 "Centralized Thirdparty Jars") | component name matches the third-party bundle in the SPB | **assumption** – confirm in KA1182 |

Test host (2026-10-18, **confirmed (live)**, `opatch lspatches`): 39925694 (SPB
marker 14.1.2.0.260825), 39919611 (WLS PSU 260823), 39916998 (Thirdparty
260821), 39988381, 39842516 (Forms QPR), 39600348 (Reports QPR), 38590500,
39864483, 39798193, 39487373, 39264447, 38391376 – i.e. the complete
CSPU Sep 2026 set of this file.

Next step: on 20 October 2026 the CPU October 2026 replaces this set – new
KA1182 check, new JDK (Java SE 21.0.12.1 is listed as affected), update
`oracle_software_version.conf` and the patch list below.

---

## Patch List — CSPU September 2026 cycle

Target: Oracle Reports 14.1.2.0.0 (Reports only) on Linux x86-64 (Oracle
Linux 9), Nginx as frontend.

### Required for a Reports-only install

| # | Patch | Description | Release | File (getMOSPatch) |
|---|---|---|---|---|
| 1 | 35702194 | Java SE 21.0.12.1 or higher (JDK 17 alternative: Patch 33181589, 17.0.20.1+) – since NFTC ended (Sep 2026) the only source of JDK 21 updates; downloaded by `04-`, installed by `02b- --upgrade-jdk` / `07-Maintenance/80- --apply` | CSPU Sep 2026 | `p35702194_2100_Linux-x86-64.zip` (tar.gz/rpm/deb + SHA256_VALUES, ~565 MB) |
| 1b | *open* | FMW-bundled JDK `oracle_common/jdk` (OPatch component `oracle.jdk` 17.0.12.8.0) – used by Reports server/engines and Forms/Reports tools; patch number to be determined (`FMW_JDK_PATCH_NR`). Oracle Support AI 2026-10-20: no published patch / Doc ID known, "Do not manually replace that JDK directory", check KA1182 – portal returned only empty pages, to be checked later | – | – |
| 2 | 28186730 | OPatch for FMW/WLS 14.1.2.0.0 | CPU | standalone MOS download currently only offers **13.9.4.2.22** (`p28186730_1394222_Generic.zip`); **13.9.4.2.24** — the version this project's `OPATCH_VERSION_MIN` actually requires — is bundled inside the SPB (patch 39925660) at `tools/opatch/generic/p28186730_1394224_Generic.zip` instead; confirmed 2026-10-13, see the caveat in `docs/05-oracle_patch_weblogic.md` |
| 3 | **39925660** | WLS Stack Patch Bundle 14.1.2.0.260825 | CSPU Sep 2026 | `p39925660_141200_Generic.zip` |
| 4 | **39988381** | WLS 14.1.2 SPU for CVE-2026-70748 (in addition to the SPB) | CSPU Sep 2026 | ships 4 product-version variants under one patch number (12.2.1.4.0/14.1.1.0.0/14.1.2.0.0/15.1.1.x) — `05-/06-oracle_patch_*.sh` select the 14.1.2 one automatically via `_select_patch_zip()` in `IHateWeblogic_lib.sh` |
| 5 | 38590500 | FMW PERL Security Patch Update 14.1.2.0.260120 – component `oracle.perlint`, comes with the Forms & Reports installer: applied by `06-` (`INSTALL_PATCHES_FR_COMMON`), not in the infrastructure-only home | CPU Jan 2026 | `p38590500_141200_Linux-x86-64.zip` |
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
| 39597026 | OHS Bundle Patch 14.1.2.0.260622 | Jul 2026 | Only if OHS is in the same Home. **Correction 2026-10-19:** the Forms & Reports installer puts the OHS binaries (`oracle.ohs2`, `$ORACLE_HOME/ohs`) into the home even with an Nginx frontend – no OHS instance, but the files are there (`10-Monitoring/cve_inventory.sh`). Agreed 2026-10-19: patch everything on disk (not running ≠ not exploitable) – add the OHS bundle patch to the patch set from the CPU Oct 2026 cycle on. Post-install per KB559857 |
| 39100536 | OAM WebGate Bundle Patch 14.1.2.0.260318 | Apr 2026 | Only if WebGate is installed – **it is** (`oracle.oamclient.webgate.ohs`, `$ORACLE_HOME/webgate`, comes with the Forms & Reports installer, 2026-10-19); patch it like OHS from the CPU Oct 2026 cycle on |
| 39726399 | LIBOVD merge patch 14.1.2.0.0 ("MERGE REQUEST ON TOP OF 14.1.2.0.0 FOR BUGS 39458344 39301239", README dated 2026-08-14, `opatch apply`, ZDT-eligible) | one-off, not in a CPU/CSPU list | **Not applied, not required** (checked 2026-10-19): fixes OAM/OID TLS bugs (37331005 TLSv1.3 LDAP, 37567156 TLSv1.2 ciphers to OID, 37359866 OAM audit, 39272755); no CVE, not on the CSPU Sep 2026 list we took from KA1182. Only relevant with an external LDAP / OID identity store over TLS. libOVD itself is in every home (`oracle_common/modules/oracle.ovd`, test host: `ovd.jar` unchanged since 2024 – the SPB does not touch it). Re-check if KA1182 ever lists it, or for the EM principal search problem (libOVD) only on Oracle Support's advice |
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
| 38566996 | UMS Bundle Patch 14.1.2.0.251022 (CPU Jan 2026) — removed from `INSTALL_PATCHES` (2026-10-14): not on the CSPU Sep 2026 required list above. UMS is not part of the SPB; check KA1182 for a UMS/Infrastructure patch in later cycles |
| 38827528 | → 39600348 (Reports QPR) |
| 38874285 | → 39842516 (Forms QPR) |
| 37795631 | → 39264447 (DB RU 23.26.2 for FMW DBCLIENT, in the SPB). 37795631 = RSF fix for Bug 36749613 (Forms 14.1.2 crash FRM-93656/FRM-93652 on `EXIT_FORM`, 23.5 DB RSF), MOS KB177278. Verified 2026-10-14: `opatch lsinventory -bugs_fixed` lists 36749613 as fixed by 39264447 – do **not** apply 37795631 on top of the SPB |
| 36749613 / 37031357 | Older RSF one-offs for the same crash (KB177278) → 37795631 → 39264447 |
