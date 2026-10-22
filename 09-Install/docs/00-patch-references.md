# MOS Reference Documents – FMW 14.1.2 Patching – CPU October 2026 (current)

Central lookup of My Oracle Support (MOS) Doc IDs used across the patch
scripts (`05-oracle_patch_weblogic.sh`, `06-oracle_patch_forms_reports.sh`,
`04-oracle_pre_download.sh`) and their docs, plus the full patch list for
the **current** cycle. Doc IDs and patch numbers change every month — this
file is a starting point for the next check, not a substitute for
re-verifying against MOS before each patch cycle.

Most important URLs:

- https://www.oracle.com/security-alerts/cpuoct2026.html
- https://www.oracle.com/security-alerts/alert-cve-2026-91403.html
- https://support.oracle.com/support/?documentId=KA1182

## Patch cycle history

The library itself is not versioned (always "latest"). This file is: at
every new cycle the previous state is frozen as a snapshot, so it stays
traceable what belonged to a cycle, and an environment can be brought
**by hand** to an earlier patch level (e.g. a bug in the current CPU).

| Cycle | Released | Type | Configured in this project | Status | Document |
|---|---|---|---|---|---|
| CPU October 2026 + Security Alert CVE-2026-91403 | 2026-10-20 / 2026-10-21 | CPU + Alert | from 2026-10-22 | **current** – patch numbers **pending** (KA1182/CPU360 not readable yet, MOS portal returned empty pages); `oracle_software_version.conf` still on CSPU Sep 2026 | this file |
| CSPU September 2026 | 2026-09-15 | CSPU | 2026-10-13 – 2026-10-22 | frozen; complete set live on the test host | [00-patch-references_september_2026.md](00-patch-references_september_2026.md) |

Rule for every new cycle:

1. Copy this file to `00-patch-references_<month>_<year>.md` (cycle name,
   e.g. `_october_2026`), add the "Frozen snapshot … Do not edit" header,
   nothing else.
2. Add the row to the table above, link the snapshot.
3. Then rework **this** file for the new cycle. Every other file links
   only `00-patch-references.md` for the current state – a snapshot is
   linked only from this table or where a text describes that one cycle.

Rolling back by hand to a snapshot: set the patch numbers of the snapshot
in `09-Install/oracle_software_version.conf`, download with
`04-oracle_pre_download.sh --apply --fresh-patches --mos`, then roll back
the newer patches with OPatch (`opatch rollback -id …` / `opatch nrollback`)
and apply the old ones – there is no script for a rollback.

---

| Doc ID | Title | Used for |
|---|---|---|
| **KA1182** | CPU/CSPU Patch Advisor for Oracle Fusion Middleware | Main entry point for current WLS 14.1.2 and Forms/Reports 14.1.2 patch numbers – check **monthly** (CPU and CSPU, see "Terms" below) |
| **CPU360** | Patch Availability Document for Fusion Middleware, CPU October 2026 | Linked from the CPU Oct 2026 advisory for every FMW product (WLS, OHS, OUI, Common Libraries, FMW Control …) – patch numbers of this cycle |
| **CPU388** | Patch Availability Document for Java SE, CPU October 2026 | JDK 21.0.13 / 17.0.21 – **superseded for JSSE by CPU426** (21.0.13 is itself affected by CVE-2026-91403) |
| **CPU426** | Patch Availability Document for Java SE, Security Alert CVE-2026-91403 | Target JDK version of this cycle – see "Special case Java" |
| **KA204** | Oracle Forms and Reports Quarterly Patch Release (QPR) Information | Current Forms/Reports QPR patch numbers |
| CPU391 | Patch Availability Document, CPU October 2026, Enterprise Manager | Only if EM Cloud Control / FMW components of EM are used – not part of this stack |
| CPU349 | CSPU September 2026 for Oracle Java SE | History (cycle CSPU Sep 2026) |
| CPU211 | Patch Availability Document FMW, CPU July 2026 | History (cycle CPU Jul 2026) |
| KB168467 | Stack Patch Bundle (SPB) with SPBAT Utility | Background on the SPB/SPBAT mechanism reintroduced for 14.1.2 in CSPU Sep 2026 — see the corrected note in `docs/05-oracle_patch_weblogic.md` |
| KB175049 | Installing and maintaining Java SE for FMW 11g/12c/14c | JDK install/update procedure, referenced by `02b-root_os_java.sh` |
| KB159467 | Restricting Incoming Serialized Java Objects (JEP 290) | Why an up-to-date JDK is required for the WLS PSU deserialization fixes to take effect |
| KB694158 | Security Advice and Post-Install for WLS PSUs | Post-install steps after applying the WLS Stack Patch Bundle / SPU |
| KB559857 | Cumulative README Post-Install Steps for OHS 14.1.2.0 Bundle Patches | OHS bundle patch post-install – the OHS binaries are in every Forms & Reports home, patched from this cycle on |
| KB118538 | Native Network Encryption (NNE), DB compatibility (CVE-2021-2351) | Minimum requirement for the external repository database (RCU) |
| KB618392 | Zero Downtime Patching for FMW/WLS (legacy Doc ID 1942159.1) | Background on ZDT patching for a live production system (not used during initial install, no domain exists yet) |

CPU360 / CPU388 / CPU391 / CPU426 are the links in the "Patch Availability
Document" column of the public advisory / alert (read 2026-10-22); their
content needs a MOS login.

## How to use this table

1. Every third Tuesday (CPU **or** CSPU) **and** whenever a Security Alert
   appears, read the public advisory (risk matrix: WLS, OPSS, Forms,
   "Oracle Fusion Middleware", Java SE), then open KA1182 on MOS and compare
   the current patch numbers against `09-Install/oracle_software_version.conf`.
2. New cycle → first freeze this file (see "Patch cycle history"), then
   rework it.
3. If a Doc ID listed here has been superseded or renumbered by Oracle,
   update this table — do not silently start referencing a new number
   from inline comments elsewhere, this table is the single place to look.
4. Set `PATCH_CYCLE`, `PATCH_CYCLE_DATE`, `PATCH_CYCLE_ADVISORY` in
   `oracle_software_version.conf` together with the patch numbers –
   `10-Monitoring/cve_inventory.sh` compares installed patches and newer
   advisories against them.
5. Patch numbers themselves live in `oracle_software_version.conf`, not
   here — the tables below are a point-in-time snapshot for reference,
   `oracle_software_version.conf` is the source of truth the scripts read.

---

## Terms – CPU, CSPU, Security Alert and the patch vehicles

Since May 2026 Oracle publishes security fixes **every month** – two kinds of
advisories alternate, and Security Alerts come in between:

| Term | What it is | Cadence | Source |
|---|---|---|---|
| **CPU** – Critical Patch Update | The classic **quarterly, cumulative** security release | Jan / Apr / Jul / Oct, third Tuesday | Oracle Security Alerts page |
| **CSPU** – Critical Security Patch Update | "targeted, high-priority security fixes in a smaller, more focused format … Critical Security Patch Updates **complement** Oracle's existing quarterly cumulative Critical Patch Updates (CPUs)" (advisory text, Sep 2026) | Third Tuesday of the **other** months; first one May 2026 ("except the initial May CSPU release") | CSPU advisories Jun/Aug/Sep 2026 |
| **Security Alert** | Out-of-cycle fix for a single severe vulnerability, own advisory `alert-cve-<id>.html` and own Patch Availability Document (e.g. CVE-2026-91403, JSSE, CVSS 9.1, one day after the CPU Oct 2026: CPU426) | any day, not bound to the third Tuesday | Oracle Security Alerts page, section "Security Alerts" |
| **Risk matrix** | Table per product in an advisory: CVE, component, protocol, "remote exploit without auth", CVSS, affected versions. Lists **only newly** fixed vulnerabilities – earlier ones are in the earlier CPU/CSPU advisories | per advisory | advisory |
| **Patch Availability Document** | MOS note mapping the advisory to concrete patch numbers – for FMW **KA1182** (current and previous CPU **and** CSPU patches) plus the per-cycle note (CPU Oct 2026: **CPU360**), Java SE per cycle (CPU388) / per alert (CPU426), Forms/Reports QPRs **KA204** | updated each release | MOS |
| **SPB** – Stack Patch Bundle | One ZIP with WLS PSU + Coherence + JDBC + DB client RU + third-party bundle + OPatch, applied with SPBAT / `opatch napply`. Reintroduced for 14.1.2 with CSPU Sep 2026 | per CPU/CSPU | KB168467 |
| **PSU** – Patch Set Update | Cumulative WLS patch (inside the SPB for 14.1.2, standalone for 15.1.1) | per CPU/CSPU | KA1182 |
| **SPU** – Security Patch Update | Single security fix on top of the SPB/PSU when it was not ready for the bundle (CSPU Sep 2026: 39988381 for CVE-2026-70748) | as needed | KA1182 |
| **QPR** – Quarterly Patch Release | Forms / Reports bundles (bug + security fixes) – **not** part of the WLS SPB, applied by `06-` | roughly quarterly, can be referenced by a CSPU | KA204 |

Consequences for this project:

- **Every month** (third Tuesday) check KA1182 – not only in CPU months. A
  CSPU can bring a CVSS 10.0 fix for WLS or Forms (September 2026: five
  CVSS 10.0 in Fusion Middleware, see the snapshot).
- **Additionally** watch the Security Alerts section of
  https://www.oracle.com/security-alerts/ – an alert does not wait for the
  next third Tuesday and can make the version of the CPU just applied
  obsolete (October 2026: JDK 21.0.13 from the CPU, affected by the alert
  one day later).
- A risk matrix lists only the new CVEs. When a cycle was skipped, read
  **every** advisory since the last applied one (the snapshots of this file
  list them per cycle).
- Patch numbers come from KA1182 / CPU360 / KA204 / CPU426, never from the
  public advisory – the advisory only names products, versions and CVEs.
- Oracle Reports has no own entry in the CSPU Sep 2026 / CPU Oct 2026
  product lists (only "Oracle Fusion Middleware" / WLS / OPSS, which are in
  every Reports home). Forms CVEs matter for a Reports-only home only if the
  Forms component is installed (`opatch lsinventory`, `oracle.forms*`).

### Release dates (from the advisories)

| Date | Type | State 2026-10-22 |
|---|---|---|
| 21 July 2026 | CPU | released |
| 18 August 2026 | CSPU | released |
| 15 September 2026 | CSPU | released – frozen in [00-patch-references_september_2026.md](00-patch-references_september_2026.md) |
| 20 October 2026 | CPU | released (Rev 1) – **current cycle**; Fusion Middleware 206 fixes, Java SE matrix (21.0.12.1 / 17.0.20.1 affected), Forms / Reports not in the product list |
| 21 October 2026 | Security Alert CVE-2026-91403 | released (Rev 1) – Java SE JSSE, CVSS 9.1; affected **21.0.13**, 17.0.21, 8u511 … (= the versions of the CPU one day earlier), patch document CPU426 |
| 17 November 2026 | CSPU | planned |
| 15 December 2026 | CSPU | planned |
| 19 January 2027 | CPU | planned |

### Public advisories (no MOS login needed)

All links checked 2026-10-22 (HTTP 200, title matches).

| Advisory | URL |
|---|---|
| Overview – CPUs, CSPUs, Security Alerts and Bulletins | https://www.oracle.com/security-alerts/ |
| Security Alert CVE-2026-91403 (Java SE JSSE) | https://www.oracle.com/security-alerts/alert-cve-2026-91403.html |
| CPU October 2026 | https://www.oracle.com/security-alerts/cpuoct2026.html |
| CSPU September 2026 | https://www.oracle.com/security-alerts/cspusep2026.html |
| CSPU August 2026 | https://www.oracle.com/security-alerts/cspuaug2026.html |
| CPU July 2026 | https://www.oracle.com/security-alerts/cpujul2026.html |
| CSPU June 2026 | https://www.oracle.com/security-alerts/cspujun2026.html |

Naming pattern: `cpu<mon><yyyy>.html` for CPUs, `cspu<mon><yyyy>.html` for
CSPUs, `alert-cve-<yyyy>-<nr>.html` for Security Alerts. `www.oracle.com`
refuses some non-browser clients (HTTP 403) – with `curl -A "Mozilla/5.0"`
it answers.

### CVE check 2026-10-22 – CPU October 2026

Filtered from the Fusion Middleware risk matrix of the CPU Oct 2026
advisory (Rev 1): all rows whose affected versions include **14.1.2.0.0**
and whose product is part of a Forms & Reports home. Not listed: SOA, OSB,
BPM, ODI, WebCenter, OIM, MFT, JDeveloper and Oracle Access Manager (OAM
server – **not** WebGate; no WebGate row in this CPU) – not installed by
this project. Oracle Forms, Oracle Reports, OPSS and Coherence 14.1.2 have
**no** row in this CPU.

| CVE | Product / component | Protocol | Remote w/o auth | CVSS 3.1 | Relevant here | Fix in patch |
|---|---|---|---|---|---|---|
| **CVE-2026-83399** | WebLogic Server / Core | T3, IIOP | yes | **9.8** | **yes** – every installation (T3 not exposed through Nginx, but local / internal network) | pending KA1182 (WLS SPB) |
| **CVE-2026-91323** | WebLogic Server / Core | HTTP | yes | **9.8** | **yes** – reachable through Nginx (`/forms`, `/reports`) | pending KA1182 (WLS SPB) |
| CVE-2026-87302 | WebLogic Server / Core | HTTP | yes | 9.1 | yes | pending KA1182 (WLS SPB) |
| CVE-2026-91502 | WebLogic Server / Core | TLS | yes | 7.3 | low – WLS SSL listen ports (demo SSL 9501/9512) not used, loopback only; TLS terminates in Nginx | pending KA1182 (WLS SPB) |
| CVE-2026-41855 | WebLogic Server / Core (Spring Framework); also Middleware Common Libraries and Tools / Thirdparty Patch | HTTP | yes | 8.1 | yes (library on disk) | pending KA1182 (SPB / thirdparty bundle) |
| CVE-2023-43622 | WebLogic Server / Core (Apache HTTP Server) | HTTP/2 | yes | 7.5 | yes (component in the home) | pending KA1182 |
| CVE-2025-7962 | WebLogic Server / Centralized Thirdparty Jars (Jakarta Mail) | SMTP | yes | 7.5 | low – no mail sessions configured; library on disk | pending KA1182 (thirdparty bundle) |
| CVE-2026-101515 | WebLogic Server / Centralized Thirdparty Jars | HTTP | yes | 5.9 | yes | pending KA1182 (thirdparty bundle) |
| **CVE-2026-4176** | Oracle Fusion Middleware / Centralized Thirdparty Jars (Perl) | HTTP | yes | **9.8** | yes – `oracle.perlint` comes with the Forms & Reports installer | pending KA1182 (successor of PERL SPU 38590500) |
| **CVE-2026-47065** | Middleware Common Libraries and Tools / Third Party (Apache Mina) | HTTP | yes | **9.8** | yes (library on disk) | pending KA1182 |
| CVE-2026-54399 / 59649 / 49844 / 64607 | Middleware Common Libraries and Tools / Third Party (HttpComponents 7.5, Bouncy Castle 7.5, Log4j 5.9, HttpClient 5.3) | HTTP(S) | yes | 5.3 – 7.5 | yes (libraries on disk) | pending KA1182 |
| CVE-2026-91617 | Middleware Common Libraries and Tools / Remote Diagnostic Agent | None | no | 5.5 | yes – RDA is in the SPB (39798193 in Sep) | pending KA1182 (SPB) |
| CVE-2026-54513 | Web Services Manager / Third Party (jackson-databind) | HTTP | yes | 8.1 | yes – OWSM is part of the FMW infrastructure home | pending KA1182 |
| CVE-2026-91467 | Fusion Middleware Control / Framework | None | no | 6.6 | yes – EM on the AdminServer | pending KA1182 |
| CVE-2026-8763 / 101520 / 91776 / 59889 | Global Lifecycle Management NextGen OUI Framework / NextGen Installer (Bouncy Castle 9.1, 7.5, jackson-databind 7.5, 6.5) | HTTP(S) | mostly yes | 6.5 – 9.1 | yes – OUI/OPatch tooling in every home (exploitable only while the installer runs) | pending KA1182 (OUI/NextGen patch) |
| **CVE-2026-87347** | Oracle HTTP Server / OSSL Module | HTTP | no | **9.6** | yes – OHS binaries are in the home (no instance, Nginx frontend); patched from this cycle on | pending KA1182 (OHS bundle) |
| CVE-2026-87346 | Oracle HTTP Server / WebLogic Proxy Plug-in for OHS | HTTP | yes | 8.7 | as above | pending KA1182 (OHS bundle) |
| CVE-2026-83379 / 87300 | WebLogic Server Proxy Plug-in for Third-Party Web Servers | HTTP | yes | 8.7 | **no** – only for IIS/Apache, Nginx uses `proxy_pass` | – |

Java SE matrix of the CPU Oct 2026 (55 rows): highest score for 17/21 is
7.0 (CVE-2026-91415, 2D); JSSE rows CVE-2026-91373 (5.3), -83376 / -91461
(3.7). Affected **21.0.12.1** and **17.0.20.1** → fixed in 21.0.13 /
17.0.21 (CPU388) – which the alert one day later declares affected again,
see the next section.

A CVE in a risk matrix means "addressed by the patches of this release"
– the advisory has no separate "fixed" flag. Which patch fixes which CVE
is **not** in the public advisory and the patch READMEs name no CVE
numbers – the column "Fix in patch" is the expected vehicle and must be
confirmed against KA1182 / CPU360 (same as in the September cycle, see
the snapshot).

---

## Special case Java – two JDKs, one alert

The October cycle shows why Java gets its own section: the CPU of
20 October fixes Java with **21.0.13**, the Security Alert of 21 October
(CVE-2026-91403, JSSE, CVSS 9.1, AV:N/AC:L/PR:N/UI:N) lists exactly this
**21.0.13** as affected. Target is therefore the release of **CPU426**,
not the one of CPU388.

| JDK | Where | Used by | Action this cycle | State 2026-10-22 |
|---|---|---|---|---|
| Oracle JDK 21 at `JDK_HOME` | outside the Oracle Home (`02b-root_os_java.sh`) | WebLogic servers, Node Manager, WLST | Patch **35702194** (always "current JDK 21", ZIP name does not change) – only download after CPU426 is out and the ZIP contains the fixed release: `04-oracle_pre_download.sh --apply --fresh-patches --mos`, check the `jdk-21.0.x` inside the ZIP, then `07-Maintenance/80-patch_java_os.sh --apply` (domain stopped) | **pending CPU426** – fixed version number not known yet; raise `JDK_VERSION_MIN` in `oracle_software_version.conf` together with the download. Test host on 21.0.12.1 (affected by the CPU Oct Java matrix) |
| FMW-bundled JDK 17 `$ORACLE_HOME/oracle_common/jdk` | inside the Oracle Home, OPatch component `oracle.jdk` 17.0.12.8.0 | Reports server/engines, Forms/Reports tools (`rwrun`, `rwconverter`, `frmcmp`, …) | OPatch patch `FMW_JDK_PATCH_NR` | **blocked** – Oracle Support AI 2026-10-20: no published patch / Doc ID known, "Do not manually replace that JDK directory", check KA1182; MOS portal returned only empty pages. 17.0.12 is behind 17.0.20.1, 17.0.21 and the alert |
| Client JRE of the Forms users | user PCs (Java Web Start / FSAL standalone launcher) | Forms applet runtime, **TLS client** of the Forms session | **most important measure for CVE-2026-91403** – JSSE runs on the client; roll out the CPU426 JRE through the customer's software distribution | customer task – inform the customer, see the threat model |

Why the client is the critical side: in this architecture TLS terminates
in Nginx (OpenSSL), Nginx → WLS and WLS → `frmweb` are plain connections on
the server, so the server-side JSSE is hardly in the TLS path – but the
Forms client JRE is a JSSE TLS client, and a manipulated Forms/WebUtil
session can control the client with user rights. Details:
[forms_runtime_architecture.md §1.1 / §1.2](../../80-FMW-Architecture/forms_runtime_architecture.md#11-where-tls-is-spoken--and-who-uses-javas-jsse)
and [forms_jakob_webutil.md §10.1](../../80-FMW-Architecture/forms_jakob_webutil.md#101-what-the-session-can-do-on-the-client--threat-model).

---

## Patch List — CPU October 2026 cycle

Target: Oracle Forms & Reports 14.1.2.0.0 on Linux x86-64 (Oracle Linux 9),
Nginx as frontend.

**All new numbers pending** – KA1182 / CPU360 / KA204 / CPU426 were not
readable on 2026-10-22 (MOS portal empty). The column "Previous (CSPU Sep
2026)" is what is installed now and what the new patch replaces;
`oracle_software_version.conf` keeps the previous numbers until the whole
set is known (no half cycle for the scripts).

### Required

| # | Patch (CPU Oct 2026) | Previous (CSPU Sep 2026) | Description | Applied by |
|---|---|---|---|---|
| 1 | 35702194 (same number) – release **pending CPU426** | 35702194 = 21.0.12.1 | Oracle JDK 21 at `JDK_HOME`, see "Special case Java" | `04-` download, `02b- --upgrade-jdk` / `07-Maintenance/80- --apply` |
| 1b | *blocked* | *open* | FMW-bundled JDK `oracle_common/jdk` (`oracle.jdk` 17.0.12.8.0) | `06-` / `82-` once known |
| 2 | 28186730 – version pending | 13.9.4.2.24 (inside SPB 39925660) | OPatch for FMW/WLS 14.1.2.0.0 – check whether the new SPB again carries a newer build than the standalone download (see `docs/05-oracle_patch_weblogic.md`) | `05-` |
| 3 | **pending KA1182** | 39925660 | WLS Stack Patch Bundle 14.1.2.0.2610xx – expected to carry the WLS Core CVEs, thirdparty bundle, RDA, Coherence, JDBC, DB client | `05-` |
| 4 | **pending KA1182** (or none) | 39988381 | WLS 14.1.2 SPU – only if KA1182 lists an SPU on top of the new SPB; otherwise 39988381 is expected to be included in the SPB | `05-` |
| 5 | **pending KA1182** | 38590500 | FMW PERL Security Patch Update (CVE-2026-4176, 9.8) – component `oracle.perlint` | `06-` (`INSTALL_PATCHES_FR_COMMON`) |
| 6 | **pending KA204** | 39600348 | Oracle Reports Developer QPR 14.1.2.0 – no Reports CVE in this CPU, take a new QPR only if KA204 lists one | `06-` |
| 7 | **pending KA1182** | 39597026 (not applied) | OHS Bundle Patch 14.1.2.0.2610xx (CVE-2026-87347 9.6, -87346 8.7) – **mandatory from this cycle on**: the OHS binaries (`oracle.ohs2`) are in every Forms & Reports home (agreed 2026-10-19: patch everything on disk). Post-install per KB559857 | `06-` |
| 8 | **pending KA1182** | 39100536 (not applied) | OAM WebGate Bundle Patch 14.1.2.0 – **mandatory from this cycle on** (`oracle.oamclient.webgate.ohs` is in the home); no WebGate CVE in this CPU, take the latest bundle listed in KA1182 | `06-` |
| 9 | **pending KA1182** | – | OUI / NextGen Installer patch for CVE-2026-8763 (9.1) and friends – only if KA1182 lists a separate patch for 14.1.2 | `05-` |
| 10 | **pending KA1182** | – | OWSM / FMW Control / Common Libraries one-offs (CVE-2026-54513, -91467, -47065 …) – only if not contained in the SPB | `05-` |

### Conditional (only if the component is installed in the Oracle Home)

| Patch | Previous (CSPU Sep 2026) | Description | Condition |
|---|---|---|---|
| **pending KA204** | 39842516 | Oracle Forms QPR 14.1.2.0 – no Forms CVE in this CPU, take a new QPR only if KA204 lists one | Only if Forms is in inventory (`opatch lsinventory -details`, component `oracle.forms*`) |
| 38936596 | 38936596 | One-off for Bug 38936596 (ewt3.jar, BiDi parentheses) | Only if `REPORTS_BIDIPARENTHESIS=YES` (Hebrew); check whether the new Reports QPR includes it |
| 39726399 | not applied | LIBOVD merge patch 14.1.2.0.0 (OAM/OID TLS bugs, no CVE) | Not required – re-check only if KA1182 lists it or on Oracle Support's advice (details in the snapshot) |
| WLS Proxy Plug-In | – | CVE-2026-83379 / 87300 | Only for IIS/Apache as a proxy — not relevant with Nginx |

### Content of the new SPB

**Pending** – fill in from the SPB README once the number is known. The
September content (SPB 39925660: marker, RDA, WLS PSU 260823, samples,
Coherence CP9, DB client RU 23.26.2, JDBC, OPatch .24, thirdparty bundle,
RCU fix) is in the
[snapshot](00-patch-references_september_2026.md#content-of-spb-39925660-applied-in-full-via-spbat-or-opatch-napply).

### Superseded (kept for context, not read by any script)

| Old patch | Superseded by |
|---|---|
| 38566996 | UMS Bundle Patch 14.1.2.0.251022 (CPU Jan 2026) — removed from `INSTALL_PATCHES` (2026-10-14): not on the CSPU Sep 2026 required list above. UMS is not part of the SPB; check KA1182 for a UMS/Infrastructure patch in later cycles |
| 38827528 | → 39600348 (Reports QPR) |
| 38874285 | → 39842516 (Forms QPR) |
| 37795631 | → 39264447 (DB RU 23.26.2 for FMW DBCLIENT, in the SPB). 37795631 = RSF fix for Bug 36749613 (Forms 14.1.2 crash FRM-93656/FRM-93652 on `EXIT_FORM`, 23.5 DB RSF), MOS KB177278. Verified 2026-10-14: `opatch lsinventory -bugs_fixed` lists 36749613 as fixed by 39264447 – do **not** apply 37795631 on top of the SPB |
| 36749613 / 37031357 | Older RSF one-offs for the same crash (KB177278) → 37795631 → 39264447 |
