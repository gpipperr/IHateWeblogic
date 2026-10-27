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

| Cycle | Released | Type | Configured in this project | Status | Document | Manual guide (how, by hand) |
|---|---|---|---|---|---|---|
| Security Alert CVE-2026-114820 (Java, eMudhra CAs) + OS `ca-certificates` (ELSA-2026-88459 / CVE-2026-111943) | 2026-10-24 / 2026-10-22 | Alert | 2026-10-26 | **open (Java)** – OS fixed on the test host 2026-10-26; JDK 21.0.13.0.2 already blocks the compromised intermediates, next JDK build removes the roots; bundled JDK 17.0.12 still trusts them – see [Special case Java](#emudhra-ca-incident--cve-2026-114820-state-2026-10-26) | this file | – |
| CPU October 2026 + Security Alert CVE-2026-91403 | 2026-10-20 / 2026-10-21 | CPU + Alert | from 2026-10-22 | **current** – patch numbers from KA1182 (PDF of 2026-10-22) and CPU426; `oracle_software_version.conf` / `04-`/`05-`/`06-` switched and **applied on the test host 2026-10-24** (smoke test OK) | this file | [Forms14_reports14_patch_analyse_10_2026](../../70-Customer-Projects/Forms14_reports14_patch_analyse_10_2026/install_14c_patch_set_october_2026_manual.md) (verified on the test host 2026-10-24) |
| CSPU September 2026 | 2026-09-15 | CSPU | 2026-10-13 – 2026-10-22 | frozen; set live on the test host – **incomplete**: the FMW Infrastructure bundle patches (ADF, OWSM, OPSS, UMS, …) were missing, see "Patch List" below | [00-patch-references_september_2026.md](00-patch-references_september_2026.md) | – (applied by the scripts, steps in `docs/05` / `06` of that time, see git history) |

Rule for every new cycle:

0. Start with `10-Monitoring/patch_cycle_analysis.sh` (`prepare`, then
   `analyse --mode maintainer`) – Claude follows
   [patch_cycle_analysis_skill.md](../../10-Monitoring/patch_cycle_analysis_skill.md)
   and does steps 1–4 below, plus `update_plan.md` for the lib switch.
1. Copy this file to `00-patch-references_<month>_<year>.md` (cycle name,
   e.g. `_october_2026`), add the "Frozen snapshot … Do not edit" header,
   nothing else.
2. Add the row to the table above, link the snapshot.
3. Then rework **this** file for the new cycle. Every other file links
   only `00-patch-references.md` for the current state – a snapshot is
   linked only from this table or where a text describes that one cycle.
4. Manual guide: create the folder
   `70-Customer-Projects/Forms14_reports14_patch_analyse_<mm>_<yyyy>/`
   (analysis `README.md` with the facts of every patch README +
   `install_14c_patch_set_<month>_<year>_manual.md`), add the
   "Frozen – do not edit" header to the folder of the previous cycle, link
   the new one in the table above. The guide is the master for the scripts:
   `oracle_software_version.conf` is switched only after the guide was run
   on the test host.

Division of roles: **this file** = what / why (patch numbers, KA1182, CVEs);
the **manual guide** = how, by hand, per cycle; the **scripts** +
`oracle_software_version.conf` = automated, always the current cycle.

Rolling back by hand to a snapshot: set the patch numbers of the snapshot
in `09-Install/oracle_software_version.conf`, download with
`04-oracle_pre_download.sh --apply --fresh-patches --mos`, then roll back
the newer patches with OPatch (`opatch rollback -id …` / `opatch nrollback`)
and apply the old ones – there is no script for a rollback.

---

| Doc ID | Title | Used for |
|---|---|---|
| **KA1182** | CPU/CSPU Patch Advisor for Oracle Fusion Middleware | Main entry point for current WLS 14.1.2 and Forms/Reports 14.1.2 patch numbers – check **monthly** (CPU and CSPU, see "Terms" below). **Cumulative**: lists every patch still required for a home, with the CPU/CSPU release that brought it; patches are a "Minimum Requirement", bundle patches the "Latest Recommended". See "How to read KA1182" |
| KB160118 | KA1182 – archived revisions as PDF | The official KA1182 state of earlier cycles (Sep 2026 content added on 2026-10-20) – the counterpart of our snapshots |
| CPU289 / CPU290 | CPU October 2026 – Executive Summary / Documentation Map | Overview of all products of the CPU |
| **CPU360** | Patch Availability Document for Fusion Middleware, CPU October 2026 | Linked from the CPU Oct 2026 advisory for every FMW product (WLS, OHS, OUI, Common Libraries, FMW Control …) – patch numbers of this cycle |
| **CPU388** | Patch Availability Document for Java SE, CPU October 2026 | JDK 21.0.13 / 17.0.21 – **superseded for JSSE by CPU426** (21.0.13 is itself affected by CVE-2026-91403) |
| **CPU426** | Oracle Java SE Security Alert for CVE-2026-91403 (v1.0, read 2026-10-22) | Target JDK version of this cycle: **21.0.13.0.2** (Patch 40186074, or well-known 35702194), client JRE **8u511** (Patch 40186686) – see "Special case Java" |
| **KA204** | Oracle Forms and Reports Quarterly Patch Release (QPR) Information | Current Forms/Reports QPR patch numbers |
| CPU391 | Patch Availability Document, CPU October 2026, Enterprise Manager | Only if EM Cloud Control / FMW components of EM are used – not part of this stack |
| CPU349 | CSPU September 2026 for Oracle Java SE | History (cycle CSPU Sep 2026) |
| CPU211 | Patch Availability Document FMW, CPU July 2026 | History (cycle CPU Jul 2026) |
| KB379953 | Details for FMW Third-Party Component Updates | Third-Party BP (in the SPB); PNEWS2138 (= Doc ID 3093394.1, the "post-install" note of the ADF BP, read 2026-10-24): ADF BP, Third-Party BP and WLS PSU share the GraalVM libraries – apply all three from the same cycle; a runtime home needs at least ADF + WLS PSU (else EM does not deploy), the IDE also the Third-Party BP. No post-install command |
| KB417168 | Primary Note on Coherence Patch Releases | Coherence cumulative patch (in the SPB) |
| KB168467 | Stack Patch Bundle (SPB) with SPBAT Utility | Background on the SPB/SPBAT mechanism reintroduced for 14.1.2 in CSPU Sep 2026 — see the corrected note in `docs/05-oracle_patch_weblogic.md` |
| KB175049 | Installing and maintaining Java SE for FMW 11g/12c/14c | JDK install/update procedure, referenced by `02b-root_os_java.sh` |
| KB159467 | Restricting Incoming Serialized Java Objects (JEP 290) | Why an up-to-date JDK is required for the WLS PSU deserialization fixes to take effect |
| KB694158 | Security Advice and Post-Install for WLS PSUs | Post-install steps after applying the WLS Stack Patch Bundle / SPU |
| KB559857 | Cumulative README Post-Install Steps for OHS 14.1.2.0 Bundle Patches | OHS bundle patch post-install – the OHS binaries are in every Forms & Reports home, patched from this cycle on. Read 2026-10-24: no command; Oct 2026 hardening directives (header stripping, header validation, `SSLProxyCheckPeerName`, …) all off by default, July hardening reverted to off – only for an OHS instance / `mod_wl_24`, nothing to do with Nginx as frontend |
| [KB118538](https://support.oracle.com/support/?documentId=KB118538) | Changes in Native Network Encryption (NNE) with the July 2021 CPU (CVE-2021-2351) | DB check of every FMW CPU (step 1 in KA1182): repository database (RCU) on July 2021 or later; new parameters `SQLNET.ALLOW_WEAK_CRYPTO_CLIENTS` (DB) / `SQLNET.ALLOW_WEAK_CRYPTO` (client), JDBC thin `oracle.net.allow_weak_crypto` – see the customer analysis 12.2.1.19 §1 for the check |
| KB618392 | Zero Downtime Patching for FMW/WLS (legacy Doc ID 1942159.1) | Background on ZDT patching for a live production system (not used during initial install, no domain exists yet) |

CPU360 / CPU388 / CPU391 / CPU426 are the links in the "Patch Availability
Document" column of the public advisory / alert (read 2026-10-22); their
content needs a MOS login. CPU360 lists only the **new** patches of a cycle,
KA1182 the complete set – for a home always follow KA1182.

## How to read KA1182

KA1182 is one long web document with a tab per product suite (127 pages as
PDF, 2026-10-22). Save it as PDF into `90-Source-MetaData/` (gitignored –
the document is marked "Oracle Confidential", so only patch numbers, short
names and our own assessment go into the repo, no copied text) and extract
it with `pdftotext -layout`. Every tab starts with "This page provides …":

```bash
pdftotext -layout 90-Source-MetaData/KnowledgeArticle_KA1182.pdf /tmp/ka1182.txt
grep -n "This page provides" /tmp/ka1182.txt      # tab index with line numbers
```

Tabs for a Forms & Reports 14.1.2 home (KA1182 Step 1: the
"Distribution" in `$ORACLE_HOME/oui/bin/viewInventory.sh` names the tab):

| Tab | What it adds |
|---|---|
| Forms and Reports 14.1.2.0 | Forms QPR, Reports QPR, PERL SPU, OHS + WebGate colocated – and the pointer "click the sections above" to the next two tabs |
| FMW Infrastructure 14.1.2.0 | "If only applying the WebLogic Server SPB … apply the additional patches": ADF, WebCenter Core, OWSM, FMW Control, OAMCLIENT, UMS, OPSS, LibOVD bundle patches |
| WebLogic Server 14.1.2.0 | DB check (CVE-2021-2351 / KB118538), Java SE, WLS SPB (option 1) or the individual patches (option 2) |
| Oracle HTTP Server 14.1.2 | only if a separate OHS home proxies to Forms/Reports |

"Never patched?" → apply everything in the tabs; "patched before?" → apply
what is newer than the last applied cycle (column "CPU/CSPU Release").

Final CPU/CSPU per release (KA1182 introduction): **14.1.2.0 – December
2032**, 12.2.1.4 (incl. Forms/Reports 12.2.1.19) – December 2027 (Premier
Support for 12.2.x ends December 2026, afterwards patches only with an
Extended Support contract), 14.1.1.0 – December 2027.

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
- We prove a **patch level, not a fix**: "installed >= minimum of the patch
  document" (`JDK_VERSION_MIN`, patch numbers from KA1182) is what the
  scripts and `cve_inventory.sh` check. Oracle does not publish which patch
  fixes which CVE, and fixes are known to ship silently one release before
  they appear in an advisory – so the CVE → patch mapping stays marked as
  *assumption* / "expected vehicle", and towards the customer we state
  "current Oracle level per patch document X", not "CVE proven fixed".
  When in doubt: the newest available level.
- After a Security Alert take the **release-specific patch** (e.g. 40186074,
  40186686), not the well-known "latest" patch (35702194, 18143322): the
  latest patch is repointed later – recognisable by a "Last Updated" before
  the alert date (October 2026: 18143322 updated 2026-10-20 = CPU build,
  40186686 updated 2026-10-22 = alert build).
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
| 21 October 2026 | Security Alert CVE-2026-91403 | released (Rev 1) – Java SE JSSE, CVSS 9.1; affected **21.0.13**, 17.0.21, 8u511 … (= the versions of the CPU one day earlier); fixed releases 21.0.13.0.2 / 17.0.21.0.2 / 8u511 (new build) per CPU426, **patches available by 23 Oct 2026** |
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
BPM, ODI, WebCenter, OIM, MFT and Oracle Access Manager (OAM
server – **not** WebGate; no WebGate row in this CPU) – not installed by
this project (JDeveloper is listed because its ADF runtime is in the
home). Oracle Forms, Oracle Reports, OPSS and Coherence 14.1.2 have **no**
row in this CPU. APEX, ORDS, SQLcl and the Instant Client: own section
[at the end](#apex-ords-sqlcl-and-instant-client--security-status-and-patching).

| CVE | Product / component | Protocol | Remote w/o auth | CVSS 3.1 | Relevant here | Fix in patch |
|---|---|---|---|---|---|---|
| **CVE-2026-83399** | WebLogic Server / Core | T3, IIOP | yes | **9.8** | **yes** – every installation (T3 not exposed through Nginx, but local / internal network) | SPB 40125898 (WLS PSU 40058371) |
| **CVE-2026-91323** | WebLogic Server / Core | HTTP | yes | **9.8** | **yes** – reachable through Nginx (`/forms`, `/reports`) | SPB 40125898 (WLS PSU 40058371) |
| CVE-2026-87302 | WebLogic Server / Core | HTTP | yes | 9.1 | yes | SPB 40125898 (WLS PSU 40058371) |
| CVE-2026-91502 | WebLogic Server / Core | TLS | yes | 7.3 | low – WLS SSL listen ports (demo SSL 9501/9512) not used, loopback only; TLS terminates in Nginx | SPB 40125898 (WLS PSU 40058371) |
| CVE-2026-41855 | WebLogic Server / Core (Spring Framework); also Middleware Common Libraries and Tools / Thirdparty Patch | HTTP | yes | 8.1 | yes (library on disk) | SPB 40125898 (Third-Party BP 40035655) |
| CVE-2023-43622 | WebLogic Server / Core (Apache HTTP Server) | HTTP/2 | yes | 7.5 | yes (component in the home) | SPB 40125898 (WLS PSU 40058371) |
| CVE-2025-7962 | WebLogic Server / Centralized Thirdparty Jars (Jakarta Mail) | SMTP | yes | 7.5 | low – no mail sessions configured; library on disk | SPB 40125898 (Third-Party BP 40035655) |
| CVE-2026-101515 | WebLogic Server / Centralized Thirdparty Jars | HTTP | yes | 5.9 | yes | SPB 40125898 (Third-Party BP 40035655) |
| **CVE-2026-4176** | Oracle Fusion Middleware / Centralized Thirdparty Jars (Perl) | HTTP | yes | **9.8** | yes – `oracle.perlint` comes with the Forms & Reports installer | PERL SPU **39951765** (5.42.2, replaces 38590500) – **confirmed** (README, Bug 39400045) |
| **CVE-2026-47065** | Middleware Common Libraries and Tools / Third Party (Apache Mina) | HTTP | yes | **9.8** | yes (library on disk) | SPB 40125898 (Third-Party BP 40035655) |
| CVE-2026-54399 / 59649 / 49844 / 64607 | Middleware Common Libraries and Tools / Third Party (HttpComponents 7.5, Bouncy Castle 7.5, Log4j 5.9, HttpClient 5.3) | HTTP(S) | yes | 5.3 – 7.5 | yes (libraries on disk) | SPB 40125898 (Third-Party BP 40035655) |
| CVE-2026-91617 | Middleware Common Libraries and Tools / Remote Diagnostic Agent | None | no | 5.5 | yes – RDA is in the SPB (39798193 in Sep) | SPB 40125898 (RDA 39646824) |
| CVE-2026-54513 | Web Services Manager / Third Party (jackson-databind) | HTTP | yes | 8.1 | yes – OWSM is part of the FMW infrastructure home | Third-Party BP **40035655** (in the SPB, jackson-databind 2.21.5) – **confirmed 2026-10-26**: the advisory states that the patch for CVE-2026-54515 also addresses CVE-2026-54512 / -54513 / -54514; Bug 39863385 (CVE-2026-54515) is in `lsinventory -bugs_fixed`. KA1182 names the OWSM BP 40024749 (installed too). The DB-client copies 2.16.1 (`jlib/`, `sqlcl/lib/`) are not loaded at runtime (checked 2026-10-26) |
| CVE-2026-91318 / 91319 / 91317 / 87334 / 91320 / 91322 | JDeveloper / Security Framework, Java Business Objects, ADF Databinding, ADF Faces | HTTP / SOAP / None | partly | 3.3 – 6.5 | yes – the ADF runtime (`oracle.jrf.adfrt*`) is in every FMW infrastructure home | ADF BP **40050062** (not in the SPB) – **confirmed** (README: all six in BP 260721 / 260920) |
| CVE-2026-91467 | Fusion Middleware Control / Framework | None | no | 6.6 | yes – EM on the AdminServer | FMW Control BP **39995927** (not in the SPB) – **confirmed** (README, BP 260908) |
| CVE-2026-8763 / 101520 / 91776 / 59889 | Global Lifecycle Management NextGen OUI Framework / NextGen Installer (Bouncy Castle 9.1, 7.5, jackson-databind 7.5, 6.5) | HTTP(S) | mostly yes | 6.5 – 9.1 | yes – OUI/OPatch tooling in every home (exploitable only while the installer runs) | OPatch 13.9.4.2.25 – **confirmed for CVE-2026-91776** (OPatch README: Bug 40012934), the other three assumption (only Global Lifecycle Management patch in KA1182) |
| **CVE-2026-87347** | Oracle HTTP Server / OSSL Module | HTTP | no | **9.6** | yes – OHS binaries are in the home (no instance, Nginx frontend); patched from this cycle on | OHS BP **39987730** – **confirmed** (README) |
| CVE-2026-87346 | Oracle HTTP Server / WebLogic Proxy Plug-in for OHS | HTTP | yes | 8.7 | as above | OHS BP **39987730** – **confirmed** (README) |
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
the snapshot). Vehicle = the KA1182 patch whose component matches the
risk-matrix component; the WLS SPB contains PSU, Third-Party BP, RDA,
Coherence, DB client and JDBC – the infrastructure bundles (OWSM, FMW
Control, ADF, OPSS …) are **not** in it.

---

## Special case Java – two JDKs, one alert

The October cycle shows why Java gets its own section: the CPU of
20 October fixes Java with **21.0.13**, the Security Alert of 21 October
(CVE-2026-91403, JSSE, CVSS 9.1, AV:N/AC:L/PR:N/UI:N) lists exactly this
**21.0.13** as affected. Target is therefore the release of **CPU426**,
not the one of CPU388.

CPU426 (v1.0, read 2026-10-22 from MOS; "Patches will be available by
23 Oct 2026"):

| Release (fix for CVE-2026-91403) | Patch | Well-known patch ("latest") | Relevant here |
|---|---|---|---|
| JDK **21.0.13.0.2** | 40186074 | **35702194** (JDK 21 latest) | **yes** – `JDK_HOME` |
| JDK 17.0.21.0.2 | 40186076 | 33181589 (JDK 17 latest) | no – the bundled JDK 17 is an OPatch component, not patched with this ZIP (see below) |
| JDK 8 Update 511 / **JRE 8 Update 511** | 40186682 / **40186686** | 18143322 (JDK 8 latest) | **yes for clients** – Forms 12c-era clients typically run JRE 8 (Web Start) |
| JDK 11.0.33.0.2, 25.0.5.0.2, 27.0.1.0.2 | 40186080, 40186027, 40186001 | 27838191, 38306322, 39905790 | no |
| GraalVM (EE) | TBD | – | no |

Inconsistencies in CPU426 v1.0 (re-read the document when it is updated):

- The patch table names "JDK **21.0.15**.0.2: Patch 40186074", the
  release-notes list "21.0.**13**.0.2" – 21.0.15 does not exist yet, very
  probably a typo. Check the `jdk-21.0.x` inside the downloaded ZIP.
- JDK 8: the alert lists 8u511 as **affected**, CPU426 lists "8 Update 511"
  as the **fix** (no `.0.2` suffix as for 11+). The public 8u511 release
  notes (HTTP 200) are those of the CPU; distinguish by build number –
  only the build from Patch 40186682/40186686 (available from 23 Oct)
  counts as fixed.
- Release notes pages `21-0-13-0-2-relnotes.html` / `17-0-21-0-2-relnotes.html`
  return HTTP 404 on 2026-10-22 (not published yet).

Java 8 clients – how to tell the builds apart: CPU and alert release are
both called "8u511", only the build differs (`java -version` →
`build 1.8.0_511-bNN`, or the `release` file of the JRE / file version of
`bin\java.exe` for an inventory without starting Java). Compared on
2026-10-22 (Windows x64): JRE from 18143322 (state 2026-10-20) =
`1.8.0_511-b25` (CPU build, affected), JRE from 40186686 =
**`1.8.0_511-b26`** (alert build, fixed – observed, to be confirmed by the
README; re-check after 23 Oct whether 18143322 then also delivers b26). For
JDK 11+ the version itself differs (21.0.13 vs. **21.0.13.0.2**), check
`JAVA_RUNTIME_VERSION` in `$JDK_HOME/release`.

Client JRE download: take the **JRE** (40186686, ~180 MB) not the JDK,
platform **Microsoft Windows x64** (the JACOB DLL is x64), stay on Java 8
for Java Web Start (`javaws` no longer exists from Java 11 on; with 11+
only the FSAL standalone launcher works). Licence: the patch README demands
a Java SE subscription; for Java used **only** to run an Oracle product the
exception of Doc ID 1557737.1 applies (assumption for the Forms client JRE
– quote the exact sentence from 1557737.1 / the FMW licensing manual to the
customer; other Java programs on the same PCs are not covered).

The version compare of `02b-root_os_java.sh` (`sort -V`) orders
21.0.12.1 < 21.0.13 < 21.0.13.0.2 correctly – no script change needed.

| JDK | Where | Used by | Action this cycle | State 2026-10-22 |
|---|---|---|---|---|
| Oracle JDK 21 at `JDK_HOME` | outside the Oracle Home (`02b-root_os_java.sh`) | WebLogic servers, Node Manager, WLST | Patch **35702194** (always "current JDK 21", ZIP name does not change; release-specific alternative 40186074) – download from 23 Oct 2026 when the ZIP contains **21.0.13.0.2**: `04-oracle_pre_download.sh --apply --fresh-patches --mos`, check the `jdk-21.0.x` inside the ZIP, then `07-Maintenance/80-patch_java_os.sh --apply` (domain stopped) | target **21.0.13.0.2** (CPU426); set `JDK_VERSION_MIN="21.0.13.0.2"` in `oracle_software_version.conf` together with the download. Test host on 21.0.12.1 (affected by the CPU Oct Java matrix) |
| FMW-bundled JDK 17 `$ORACLE_HOME/oracle_common/jdk` | inside the Oracle Home, OPatch component `oracle.jdk` 17.0.12.8.0 | Reports server/engines, Forms/Reports tools (`rwrun`, `rwconverter`, `frmcmp`, …) | OPatch patch `FMW_JDK_PATCH_NR` | **blocked** – Oracle Support AI 2026-10-20: no published patch / Doc ID known, "Do not manually replace that JDK directory", check KA1182; the KA1182 of October 2026 lists no patch for it either. 17.0.12 is behind 17.0.20.1, 17.0.21 and the alert. 2026-10-24: the Reports QPR fix 37866660 ("alternative JAVA_HOME") is **no** way out – MOS AI: tools only, JDK 21 not certified for Reports 14.1.2, `rwengine.sh` hard-codes `oracle_common/jdk` → SR needed |
| Client JRE of the Forms users | user PCs (Java Web Start / FSAL standalone launcher) | Forms applet runtime, **TLS client** of the Forms session | **most important measure for CVE-2026-91403** – JSSE runs on the client; roll out the CPU426 JRE (JRE 8u511 Patch 40186686, or the JDK/JRE 11+/17/21 release the client uses) through the customer's software distribution; test that the trust of the code-signing certificate survives the JRE update (`cacerts` of the JRE is replaced, the user deployment trust store stays) | customer task – inform the customer, see the threat model |

Why the client is the critical side: in this architecture TLS terminates
in Nginx (OpenSSL), Nginx → WLS and WLS → `frmweb` are plain connections on
the server, so the server-side JSSE is hardly in the TLS path – but the
Forms client JRE is a JSSE TLS client, and a manipulated Forms/WebUtil
session can control the client with user rights. Details:
[forms_runtime_architecture.md §1.1 / §1.2](../../80-FMW-Architecture/forms_runtime_architecture.md#11-where-tls-is-spoken--and-who-uses-javas-jsse)
and [forms_jakob_webutil.md §10.1](../../80-FMW-Architecture/forms_jakob_webutil.md#101-what-the-session-can-do-on-the-client--threat-model).

### eMudhra CA incident – CVE-2026-114820 (state 2026-10-26)

**What happened:** the CA eMudhra generated the private keys of eight
intermediate CAs (EC-384) with 8-bit values (0–255) – anybody could
compute them and issue valid TLS certificates for any domain (reported
2026-10-17; heise, "Vorfall bei Zertifizierungsstelle eMudhra – Acht
CA-Zertifikate kompromittiert"). An attack additionally needs control over
DNS or routing (man in the middle). Some of the intermediates are also
cross-signed by Comodo/Sectigo **"AAA Certificate Services"**.

| Advisory | Scope | Fix |
|---|---|---|
| Oracle Security Alert **CVE-2026-114820** (2026-10-24, JSSE, CVSS 9.1, AV:N/PR:N) | Java SE 8u511-b32, 11.0.33.0.2, 17.0.21.0.2, **21.0.13.0.2**, 25.0.5.0.2, 27.0.1.0.2, GraalVM | Java update that removes the eMudhra roots, or the mitigations of `https://ops.java/emudhra` (page down on 2026-10-26) |
| OS trust store, CVE-2026-111943 (Go, Python certifi, NetBSD, Linux distributions) | `/etc/pki/ca-trust` | Oracle Linux 9: **ELSA-2026-88459** (Critical), `ca-certificates-2026.2.92_v9.0.319-90.3.el9_8` – removes emSign Root CA C1, ECC G3 (TLS) and AAA / emSign code-signing entries |

**Live test 2026-10-26** against `https://<chain>.we-have-a-problem.com`
(test sites with certificates of the compromised chains: `dv|ov|ev-g3b|g3c-emudhra`
and the `*-aaa-emudhra` variants over the AAA cross-signature) – OS with
`curl` (rejected = rc 60), Java with a small `HttpClient` probe
(`java TlsProbe.java <names>`; "CONNECTED" = trusted):

| Trust store | Result |
|---|---|
| OS `ca-certificates` 2025.2.80 (before) | 6 emSign roots, emSign Root CA G1 still in `tls-ca-bundle.pem` |
| OS `ca-certificates` **2026.2.92** (after `dnf update`) | all 12 test sites **rejected** ✓ |
| **JDK 21.0.13.0.2** (`JDK_HOME`, build 2026-10-21) | all **rejected** ✓ – "Untrusted certificate: CN=EM DV TLS CA - G3B": the build already blocks the intermediates in `lib/security/blocked.certs` (87 entries, +48 vs. 21.0.12.1); the 3 emSign roots (G1, G2, ECC G3) are still in `cacerts` → the alert lists the version, the next build removes them |
| JDK 21.0.12.1 (rollback copy next to `JDK_HOME`) | **trusted** ⚠ – not in use |
| **FMW-bundled JDK 17.0.12** (`oracle_common/jdk`, Reports server / engines, tools) | **trusted** ⚠ (`blocked.certs` from 2024, 39 entries) |
| bundled JDK 17.0.12 with a `cacerts` copy **without** the 3 emSign roots (`-Djavax.net.ssl.trustStore`) | direct chains rejected, the **`aaa` chains still trusted** – removing roots is no complete mitigation; removing `comodoaaaca` would also hit older Sectigo chains |

Assessment and actions:

- **`JDK_HOME`** – practically protected; take the next JDK 21 build of
  35702194 as soon as MOS has it (`04- --apply --fresh-patches --mos`,
  `07-Maintenance/80- --apply`, then `40- --apply` for the Forms client
  bundle, which carries the same 21.0.13.0.2 runtime).
- **OS** – `dnf update ca-certificates` (ELSA-2026-88459), no service
  restart needed; done on the test host 2026-10-26.
- **Bundled JDK 17.0.12** – exposed only if Reports itself opens outbound
  TLS (mail destination over SMTPS, WebDAV destination, images / XML data
  from `https://` URLs) **and** an attacker sits in the middle; this domain
  makes no outbound calls (egress check 2026-10-20) → low risk here, but
  one more reason for the SR on the bundled JDK (draft `SR/`). No supported
  mitigation inside the bundled JDK (`blocked.certs` is part of the JDK).
- **Rollback JDK 21.0.12.1** – remove once the new build runs (clean-up
  script idea, root README).
- **Customer homes with JDK 8** (server JDK, FMW-bundled JDK 8, client JREs):
  blocklists older than October 2026 – expect "trusted"; fix = 8u511-b32 or
  newer. Check with the same probe (compile it first, Java 8 cannot run a
  source file) and `dnf updateinfo list --available ca-certificates`.

---

## Patch List — CPU October 2026 cycle

Target: Oracle Forms & Reports 14.1.2.0.0 on Linux x86-64 (Oracle Linux 9),
Nginx as frontend. Source: KA1182 "LATEST for OCTOBER 2026" (PDF of
2026-10-22, tabs Forms and Reports / FMW Infrastructure / WebLogic Server
14.1.2.0) and CPU426 for Java. The column "Previous (CSPU Sep 2026)" is
what was installed before; `oracle_software_version.conf` and the scripts
`04-`/`05-`/`06-` are switched to this set and it is **applied on the test
host (2026-10-24)** – runtimes and the live findings in the 14c folder.

**Correction to the September set:** the Forms and Reports tab of KA1182
points to the FMW Infrastructure tab, which demands eight infrastructure
bundle patches whenever only the **WLS** SPB is applied. All eight
components are in our home (`$ORACLE_HOME/inventory/ContentsXML/comps.xml`,
test host 2026-10-22). Our CSPU Sep 2026 set had none of them – "UMS
removed" and "LibOVD not required" in the snapshot were wrong.

### Required

| # | Patch (CPU Oct 2026) | Previous (CSPU Sep 2026) | Description | KA1182 release | Applied by |
|---|---|---|---|---|---|
| 1 | 35702194 → **21.0.13.0.2** (release-specific 40186074) – MOS "Last Updated 2026-10-22 02:45", no README; the copy in our patch storage (2026-10-20) still holds 21.0.12.1 → `--fresh-patches`, check `jdk-21.0.x` inside the ZIP | 35702194 = 21.0.12.1 | Oracle JDK 21 at `JDK_HOME`. KA1182 demands "21.0.13 or later" (CPU388); the alert CVE-2026-91403 (CPU426) is stricter – see "Special case Java" | Oct 2026 | `04-` download, `02b- --upgrade-jdk` / `07-Maintenance/80- --apply` |
| 1b | *blocked* | *open* | FMW-bundled JDK `oracle_common/jdk` (`oracle.jdk` 17.0.12.8.0) – KA1182 lists no patch for it | – | – |
| 2 | 28186730 → **13.9.4.2.25** | 13.9.4.2.24 (inside SPB 39925660) | OPatch – "Upgrade OPatch before applying the below patches"; check whether the standalone download offers .25 or only the SPB carries it (see `docs/05-oracle_patch_weblogic.md`) | Oct 2026 | `05-` |
| 3 | **40125898** | 39925660 | WLS Stack Patch Bundle 14.1.2.0.261007 (content below) | Oct 2026 | `05-` |
| 4 | – (check) | 39988381 | WLS SPU for CVE-2026-70748 (CSPU Sep 2026) – the WLS 14.1.2 tab lists SPB 40125898 **alone** (PSU 14.1.2.0.260922 is newer than the SPU), but other tabs still pair it with their October SPB (WebCenter SPB 40141505 "+ 39988381"). Real README (inside the ZIP, read 2026-10-24 – the MOS portal README is an AutoPatch placeholder): **overlay on the Sep PSU 39919611**, base bug **39924025** (`com.oracle.weblogic.iiop.jar` NamingContextImpl) → it can not be re-applied on PSU 40058371. **Confirmed live 2026-10-24** (`napply -report`): "40058371 Bug Superset of 39988381 (39924025)" – rolled back by OPatch, fix in the new PSU | – | `05-` (`INSTALL_PATCHES`) |
| 5 | **39951765** | 38590500 | PERL 5.42.2 Security Update for FMW 14.1.2 (component `oracle.perlint`) – needs DBCLIENT for FMW 23.26.0.0.0 or later (comes with the SPB) | Oct 2026 | `06-` (`INSTALL_PATCHES_FR_COMMON`) |
| 6 | 39600348 (unchanged) | 39600348 | Oracle Reports Developer QPR 14.1.2.0 | Aug 2026 | `06-` |
| 7 | **39987730** | 39597026 (not applied) | OHS Bundle Patch 14.1.2.0.260907 – OHS binaries (`oracle.ohs2`, `oracle.ohs2.collocated`) are in the home although Nginx is the frontend. Post-install per KB559857 | Oct 2026 | `06-` |
| 8 | 39100536 (unchanged) | 39100536 (not applied) | OAM WebGate Bundle Patch 14.1.2.0.260318 (`oracle.oamclient.webgate.ohs`) – release notes read 2026-10-24: **CVE-2025-0725** (bundled libcurl) confirmed | Apr 2026 | `06-` |

### FMW Infrastructure bundle patches (new in our set)

Required by KA1182 tab "FMW Infrastructure 14.1.2.0" when only the WLS SPB
or individual WLS patches are applied. None of them is part of the WLS SPB.

| Patch | Description | KA1182 release | In our home (comps.xml) | Note |
|---|---|---|---|---|
| **40050062** | ADF Bundle Patch 14.1.2.0.260920 | Oct 2026 | `oracle.jrf.adfrt*`, `oracle.adfrt.view_11g` | requires the Third-Party BP (in the SPB), PNEWS2138 |
| **40035984** | WebCenter Core Bundle Patch 14.1.2.0.260916 | Oct 2026 | `oracle.webcenter.wccore`, `oracle.webcenter.framework.composer` | installed with every FMW infrastructure, even without WebCenter |
| **40024749** | OWSM Bundle Patch 14.1.2.0.260914 | Oct 2026 | `oracle.wsm.*` | CVE-2026-54513; includes the fix of Security Alert CVE-2026-21992 (Mar 2026) |
| **39995927** | FMW Control Bundle Patch 14.1.2.0.260908 | Oct 2026 | `oracle.sysman.fmw.*` (EM) | CVE-2026-91467 |
| **40057999** | OAMCLIENT Bundle Patch 14.1.2.0.260922 | Oct 2026 | `oracle.oamclient.core`, `.wls` | |
| **39940047** | UMS Bundle Patch 14.1.2.0.260827 | Sep 2026 | `oracle.sdp.messaging` | was missing in the Sep set (successor of 38566996) |
| **39979746** | OPSS Bundle Patch 14.1.2.0.260904 | Sep 2026 | `oracle.opss.*` | was missing in the Sep set – the Sep OPSS CVE-2026-83020 was assumed to be in the SPB; **confirmed 2026-10-24 by the OPSS BP README: CVE-2026-83020 is fixed in this bundle** (BP 260904), not in the SPB |
| **39726399** | LibOVD Bundle Patch 14.1.2.0 | Aug 2026 | `oracle_common/modules/oracle.ovd` | was "not required" in the snapshot – KA1182 lists it; README (read 2026-10-24): **no CVE**, bug fixes only (TLS 1.2 ciphers / TLS 1.3 to LDAP) |

### Conditional (only if the component is installed in the Oracle Home)

| Patch | Previous (CSPU Sep 2026) | Description | Condition |
|---|---|---|---|
| 39842516 (unchanged) | 39842516 | Oracle Forms QPR 14.1.2.0 (Sep 2026) | Only if Forms is in inventory (`opatch lsinventory -details`, component `oracle.forms*` / `oracle.developer.forms*`) |
| 38936596 | 38936596 | One-off for Bug 38936596 (ewt3.jar, BiDi parentheses), not in KA1182 | Only if `REPORTS_BIDIPARENTHESIS=YES` (Hebrew) |
| WLS Proxy Plug-In | – | CVE-2026-83379 / 87300 | Only for IIS/Apache as a proxy — not relevant with Nginx |

### DB client tools, APEX, ORDS (own release cycles, not in KA1182)

Security status (CVE check per CPU) and the patch procedure of each: section
[APEX, ORDS, SQLcl and Instant Client](#apex-ords-sqlcl-and-instant-client--security-status-and-patching) at the end.

| Component | Installed by | Release cycle | Update |
|---|---|---|---|
| Oracle Instant Client 23.26.x (`basic`, `sqlplus`, `tools`) | `00-Setup/install_db_client_tools.sh` | follows the quarterly DB RU (23.26.x) | `IC_VERSION` / `IC_URL_BASE` in `oracle_software_version.conf`, run the script again – link switch after smoke test, `--rollback` |
| SQLcl | `00-Setup/install_db_client_tools.sh` | quarterly OTN release (`sqlcl-latest.zip`) | run the script again |
| APEX 26.x | `09-Install/04-oracle_pre_download.sh`, `12-APEX-Ords/02-install-apex.sh` | OTN release + patch set bundles via MOS (`APEX_PATCH_NR`, platform 2000P) | release upgrade: `02-install-apex.sh`; patch set: `12-APEX-Ords/03-patch-apex.sh` |
| ORDS 26.x | `09-Install/04-oracle_pre_download.sh`, `12-APEX-Ords/04-install-ords.sh` | quarterly OTN release | `12-APEX-Ords/06-patch-ords.sh` (new release beside the old one, repository upgrade one-way). **ORDS ≥ APEX and the APEXlang compiler in `ords.war` ≥ APEX** – APEX 26.2 needs ORDS 26.3.0 + SQLcl 26.3.0: patch APEX, ORDS and SQLcl as one set |

### Content of SPB 40125898 (KA1182 option 2 = the individual patches)

| Patch | Content | KA1182 release |
|---|---|---|
| 28186730 | OPatch 13.9.4.2.25 | Oct 2026 |
| 40058371 | WLS PSU 14.1.2.0.260922 – post-install KB694158 | Oct 2026 |
| 40035655 | FMW Third-Party BP 14.1.2.0.260916 (KB379953) | Oct 2026 |
| 39984190 | Coherence 14.1.2.0 Cumulative Patch 10 (14.1.2.0.10) | Oct 2026 |
| 39646824 | RDA 26.4.20261020 for FMW/WLS 14.1.2 | Oct 2026 |
| 39264447 | Database Update 23.26.2 for FMW DBCLIENT | Jul 2026 |
| 39487373 | JDBC 23.26.2 Bundle Patch 14.1.2.0.260603 | Jul 2026 |
| 38063775 | WebLogic Samples Patch 14.1.2.0.250715 | Jul 2025 |
| **40126042** | SPB marker patch (`WLS_SPB_MARKER_PATCH`, Sep: 39925694; interim 40125902) – SPB README read 2026-10-24 | Oct 2026 |
| 38391376 | RCU fix "RCU prereq steps fail while validating the DB connection" – still part of the SPB | – |

### FMW DBCLIENT – known residual (state 2026-10-26)

The Oracle Home carries its own database client ("FMW DBCLIENT", 23.26.2 –
Patch 39264447, `binary_patches/dbclient/linux64/` of the SPB). The October
SPB still ships the same RU (OPatch skipped it as a duplicate) – Oracle
delivers **no newer FMW DBCLIENT** in this cycle, and KA1182 names no
separate one.

| Finding | Assessment |
|---|---|
| CVE-2026-101510 (Oracle Net Services, CVSS 4.4) and CVE-2026-54399 (SQLcl / Apache HttpComponents, 3.1) – both "applicable to client-only installations", affected 23.4.0–23.26.3 | the FMW DBCLIENT 23.26.2 (and `$ORACLE_HOME/sqlcl/`) is formally in the range. Net Services is really used: `frmweb`, `rwserver` and the Reports engines connect to the database through it |
| `jackson-databind` 2.16.1 in `$ORACLE_HOME/jlib/` and `$ORACLE_HOME/sqlcl/lib/` (Bug 37326206 of the DB client RU) | not loaded by any running process (checked 2026-10-26); the runtime uses `oracle_common/modules/thirdparty/jackson-databind-2.21.5.jar` (CVE-2026-54515 fix, also covers -54512 / -54513 / -54514) |

Why **no** regular Oracle Database 23ai client RU is applied to this home:

- the DB client inside the FMW home mixes DB 23 components (`oracle.client`,
  `oracle.network.client`, `oracle.rdbms.*`, `oracle.odbc` 23.0.0.0.0) with
  FMW components (`oracle.bali.*` 12.2.1) – it is an FMW variant, not a
  client installation;
- a DB RU normally needs the DB OPatch (6880880, 12.2.0.1.x), the FMW home
  runs the OUI-based FMW OPatch 13.9.4.2.x;
- only RUs titled "… for FMW DBCLIENT" are certified together with WLS,
  Forms and Reports; `frmweb`, `rwserver` and the engines are linked against
  the client libraries – a foreign RU can break the relink (compare the
  `libzrc` / glibc case, KB873815) and leaves SPB, DB client and JDBC bundle
  out of step for the next `napply`.

Rule: the FMW DBCLIENT is updated **only** through the WLS SPB or an RU
"for FMW DBCLIENT" that KA1182 lists. Every cycle: check whether the new SPB
carries a newer DBCLIENT RU (SPB content table above) and re-assess the
client rows of the DB risk matrix. Answer for an external scanner: "component
of the FMW database client, updated exclusively by Oracle's WLS SPB – current
level SPB CPU Oct 2026 (40125898); the Jackson copies are not loaded at
runtime."

### Superseded (kept for context, not read by any script)

| Old patch | Superseded by |
|---|---|
| 39925660 | → 40125898 (WLS SPB 14.1.2.0.261007, CPU Oct 2026) |
| 39988381 | WLS SPU (CSPU Sep 2026), overlay on PSU 39919611, base bug 39924025 → expected in SPB 40125898 (WLS tab lists the SPB alone) – to be verified after the apply via `-bugs_fixed`, see row 4 of the patch list |
| 38590500 | → 39951765 (PERL 5.42.2 Security Update) |
| 39597026 | → 39987730 (OHS BP 14.1.2.0.260907) – the older one was never applied |
| 38566996 | → 39940047 (UMS Bundle Patch 14.1.2.0.260827). Removing it in 2026-10 without a successor was a mistake – KA1182 lists UMS in the FMW Infrastructure tab |
| 38827528 | → 39600348 (Reports QPR) |
| 38874285 | → 39842516 (Forms QPR) |
| 37795631 | → 39264447 (DB RU 23.26.2 for FMW DBCLIENT, in the SPB). 37795631 = RSF fix for Bug 36749613 (Forms 14.1.2 crash FRM-93656/FRM-93652 on `EXIT_FORM`, 23.5 DB RSF), MOS KB177278. Verified 2026-10-14: `opatch lsinventory -bugs_fixed` lists 36749613 as fixed by 39264447 – do **not** apply 37795631 on top of the SPB |
| 36749613 / 37031357 | Older RSF one-offs for the same crash (KB177278) → 37795631 → 39264447 |

---

## APEX, ORDS, SQLcl and Instant Client – security status and patching

These four components are **not** in KA1182 – they have their own risk
matrices (APEX: "Oracle APEX"; ORDS: "Oracle REST Data Services";
SQLcl / Oracle Net client: inside "Oracle Database Server") and their own
download channels. Check them at every CPU (quarterly) together with the
FMW tables above. Installed by `00-Setup/install_db_client_tools.sh` and
`12-APEX-Ords/` – see the table "DB client tools, APEX, ORDS" in the patch
list.

**Coupling (APEXlang):** `ords.war` carries the APEXlang compiler of APEX
(26.3.0.272: `apexlang-compiler-26.2.0.239.jar`); APEX 26.2 requires
**ORDS 26.3.0+** and **SQLcl 26.3.0+** (APEX 26.2 installation guide).
APEX, ORDS and SQLcl are patched as **one set** in one window – details in
[ords_architecture.md §1a](../../80-FMW-Architecture/ords_architecture.md#1a-apexlang--apex-and-ords-are-coupled-since-26x).

### CVE check 2026-10-23 – CPU October 2026

Source: risk matrices of the CPU October 2026 advisory (`cpuoct2026.html`
and the text form `cpuoct2026verbose.html`, read 2026-10-23). Installed on
the test host (live, 2026-10-23): **APEX 26.2.0** (no patch set),
**ORDS 26.3.0.272.1811** (repository `26.3.0.r2721811`), **SQLcl
26.3.0.260.1620**, **Instant Client 23.26.4.0.0**; repository DB 19.30.

| CVE | Component | Remote w/o auth | CVSS 3.1 | Affected versions | Installed | Status here |
|---|---|---|---|---|---|---|
| **CVE-2026-101521** | Oracle APEX / General – "takeover of Oracle APEX" (AV:N/AC:L/PR:N/UI:N) | **yes** | **9.8** | 24.1.0–24.1.21, 24.2.0–24.2.20, 26.1.0–26.1.4 | APEX 26.2.0 | **not affected** – 26.2 is not in the list (see below) |
| CVE-2026-66010 | Oracle APEX / General (DOMPurify) | yes (user interaction) | 6.1 | 24.1.0–24.1.19, 24.2.0–24.2.18, 26.1.0–26.1.2 | APEX 26.2.0 | not affected |
| 28 CVEs (CVE-2026-101359 … -101386, -101493, max **6.9** CVE-2026-101362, unauth) | Oracle REST Data Services | partly | ≤ 6.9 | 24.2.0–26.1.0 | ORDS 26.3.0 | not affected |
| 5 CVEs (max **8.2** CVE-2026-33941, 8.1 CVE-2026-9753, CVE-2026-91609, -54515 …) | Oracle REST Data Services | no | ≤ 8.2 | 24.2.0–26.2.1 | ORDS 26.3.0 | not affected |
| CVE-2026-91610 (**8.8**), CVE-2026-101494 (7.7) | Oracle REST Data Services | no | ≤ 8.8 | 24.2.0–26.2.2 | ORDS 26.3.0 | not affected |
| CVE-2026-54399 | Oracle SQLcl (Apache HttpComponents) **component of Oracle Database Server** | yes | 3.1 | 19.3–19.32, 21.3–21.23, 23.4.0–23.26.3 | standalone SQLcl 26.3 | not affected – the row is about the SQLcl **inside a DB home** (19c / 23ai RU); our SQLcl is the standalone 26.3 |
| CVE-2026-101510 | Oracle Net Services (Database Server) | no | 4.4 | 19.3–19.32, 21.3–21.23, 23.4.0–23.26.3 | Instant Client 23.26.4 | not affected (23.26.4 > 23.26.3). The matrix says "2 of these patches are applicable to client-only installations" without naming them in the notes – presumably this row and the SQLcl row (**assumption**) |
| **CVE-2026-75803** | RDBMS (OpenSSL), TLS | **yes** | **9.8** | 19.3–19.32, 23.4.0–23.26.3 | repository DB **19.30** | **affected** – database server, not a client component: DB RU 19.33 (Oct 2026) for the repository / APEX database (`60-RCU-DB-19c/02-db_patch_db_software.sh`); further DB rows up to 8.8 (OLAP, VPD, Micronaut) same RU |

**Is APEX 26.2 really safe from CVE-2026-101521?** Yes, per the advisory:

- The risk matrix lists the **supported versions that are affected**. APEX
  26.2 (released 2026-10-06, two weeks before the CPU) is a supported
  release and is **not** in the list → not affected. The fix is already in
  26.2.0 – the usual pattern: a fix ships in the next release before the
  advisory names the CVE.
- For the other release lines the fix comes as a **patch set bundle**:
  26.1 → **26.1.5** (Patch 39179920, its README: "26.1.0 … 26.1.5" static
  files on the CDN), 24.2 → 24.2.21, 24.1 → 24.1.22 (each "last affected +
  1" – **assumption** for 24.x, check the bundle READMEs on the APEX
  download page).
- What we prove is the **level**: `dba_registry` APEX `26.2.0`, no
  `APEX_PATCHES` row needed for this CVE. As soon as a 26.2 patch set
  bundle appears, it is applied (`03-patch-apex.sh`) – later CVEs will name
  "26.2.0–26.2.x".
- The CVE ID given in a customer / news source as "CVE-2026-10152" does
  not exist in the CPU October 2026 for APEX – the APEX row is
  **CVE-2026-101521** (same versions, 9.8).

Check on any system (read-only, SYS in the PDB):

```sql
select version, status from dba_registry where comp_id = 'APEX';            -- 26.2.0 VALID
select patch_number, patch_version, images_version, apexlang_version
  from apex_260200.apex_patches order by installed_on;                      -- patch sets
select version from ords_metadata.ords_version;                              -- ORDS repository
```

```bash
readlink $APEX_ORDS_BASE/ords_1/ords                     # ORDS software (ords-<ver>)
grep RELEASE $SQLCL_HOME/bin/version.txt                 # SQLcl
LD_LIBRARY_PATH=$INSTANT_CLIENT_HOME $SQLPLUS_BIN -V     # Instant Client
```

### APEX – patching

| | |
|---|---|
| Vehicles | **Release** (26.1 → 26.2, `apexins.sql`, new schema `APEX_<ver>`) or **patch set bundle** (26.2.0 → 26.2.x, `catpatch.sql`, same schema) |
| Source | release: `apex-latest.zip` (OTN, no login, SHA-256 on the download page); patch set: MOS, platform Generic **2000P** (`APEX_PATCH_NR` in `oracle_software_version.conf`) – both via `09-Install/04-oracle_pre_download.sh --apply [--mos]` |
| Apply | release: `12-APEX-Ords/02-install-apex.sh --apply` (upgrade mode, ORDS stopped, DB backup); patch set: `12-APEX-Ords/03-patch-apex.sh --apply` (stops / starts ORDS, images `APEX_<ver>_p<nr>`) |
| Before | check that the ORDS of the instance carries an APEXlang compiler ≥ the new APEX (`04-` / `06-` check it) |
| Proof | `dba_registry` version + `APEX_PATCHES` (patch, images and **APEXlang** version) + `/i/apex_version.txt` through Nginx |
| Rollback | release / patch set are one-way in the DB (DB backup); images: link `apex_N` back |
| Status 2026-10-23 | APEX **26.2.0**, no patch set published yet – current, not affected by the CPU Oct 2026 APEX rows |

### ORDS – patching

| | |
|---|---|
| Vehicle | every ORDS release is a **complete new installation** (no patches); quarterly + occasional fix releases (`26.3.x`) |
| Source | `ords-latest.zip` (OTN, no login) via `04-oracle_pre_download.sh --apply` (`ORDS_ZIP_URL`, version from the jar names in the ZIP) |
| Apply | `12-APEX-Ords/06-patch-ords.sh --apply` – new `ords-<ver>` beside the old one, stop, link switch, `ords install --db-only` upgrades `ORDS_METADATA` (**one-way**), start, HTTP check |
| Before | export the REST definitions (`ORDS_EXPORT` / SQLcl `rest export`) and take a DB backup – `ORDS_METADATA` has 54 of 56 FKs `ON DELETE CASCADE` |
| Rollback | `06-patch-ords.sh --rollback` = link back – only while the repository was not upgraded; after the upgrade: DB restore |
| Status 2026-10-23 | ORDS **26.3.0.272.1811** – newer than every affected range of the CPU Oct 2026 (highest: 26.2.2) |

### SQLcl – patching

| | |
|---|---|
| Vehicle | standalone release (Java, quarterly, `sqlcl-latest.zip`); **not** the SQLcl inside a DB home – that one is patched by the DB RU and is the one named in the "Oracle Database Server" matrix |
| Source / apply | `00-Setup/install_db_client_tools.sh --apply` – downloads the newest ZIP to `$PATCH_STORAGE/sqlcl/<ver>/`, installs `$ORACLE_BASE/product/sqlcl_<ver>`, switches the link `sqlcl` only after the smoke test (`sql -V`) |
| Rule | SQLcl ≥ APEX (APEXlang compiler, `apex export`) – APEX 26.2 needs SQLcl 26.3.0+ |
| Rollback | `install_db_client_tools.sh --rollback` (link back), `--keep N` |
| Status 2026-10-23 | SQLcl **26.3.0.260.1620** – not in any affected range |

### Instant Client – patching

| | |
|---|---|
| Vehicle | Instant Client follows the **DB release updates** (23.26.x = 26ai); the client-relevant CVEs are in the "Oracle Database Server" matrix (Oracle Net Services, "applicable to client-only installations") |
| Source / apply | versioned URL in `oracle_software_version.conf` (`IC_VERSION`, `IC_URL_BASE` – the "latest" link lags behind, delivered 23.26.2 on 2026-10-23 while 23.26.4 was listed); `install_db_client_tools.sh --apply` installs `instantclient_<ver>`, link switch after `sqlplus -V` |
| Rule | Instant Client ≥ the first version **after** the highest affected client row (CPU Oct 2026: > 23.26.3) |
| Rollback | `install_db_client_tools.sh --rollback`, `--keep N` |
| Status 2026-10-23 | Instant Client **23.26.4.0.0** – above 23.26.3, not affected |

Not covered here: the **FMW DBCLIENT** inside the Oracle Home (23.26.2 via
the WLS SPB, Patch 39264447 – patched by `05-`; formally in the range of the
client rows above – see "FMW DBCLIENT – known residual") and the **database
server** itself (repository / APEX DB: DB RU, `60-RCU-DB-19c/`). The
repository DB 19.30 of the test host is affected by CVE-2026-75803
(OpenSSL, 9.8) → DB RU 19.33 is an open item.
