---
title: "FMW 14.1.2 Patching – MOS Doc IDs, CSPU November 2026"
description: "My Oracle Support Doc IDs for patching Oracle Forms & Reports 14.1.2 and WebLogic: CSPU November 2026 patch numbers, OPatch, JDK, known issues and CVE notes."
---

# MOS Reference Documents – FMW 14.1.2 Patching – CSPU November 2026 (current)

> Certificates, keys and trust stores of the whole stack (terms, where what lives, who needs what, customer PKI / TLS interception): [certificates_trust_stores.md](../../80-FMW-Architecture/certificates_trust_stores.md)

Central lookup of My Oracle Support (MOS) Doc IDs used across the patch
scripts ([`05-oracle_patch_weblogic.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/05-oracle_patch_weblogic.sh), [`06-oracle_patch_forms_reports.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/06-oracle_patch_forms_reports.sh),
[`04-oracle_pre_download.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/04-oracle_pre_download.sh)) and their docs, plus the full patch list for
the **current** cycle. Doc IDs and patch numbers change every month — this
file is a starting point for the next check, not a substitute for
re-verifying against MOS before each patch cycle.

Most important URLs:

- <https://www.oracle.com/security-alerts/cspunov2026.html>
- <https://support.oracle.com/support/?documentId=KA1182>
- previous cycle: <https://www.oracle.com/security-alerts/cpuoct2026.html>
  (frozen: [00-patch-references_october_2026.md](00-patch-references_october_2026.md))

**State 2026-11-18:** CSPU November 2026 analysed (all patch READMEs read
from the ZIPs, ARU of every ZIP recorded), applied on the test host (FMW
home, repository DB MRP + DB home JDK, APEX 26.2.1, ORDS 26.3.1) and the
**library switched** (`oracle_software_version.conf`, `download/patches_*.csv`,
docs, cookbooks – release `v1.0.202611`, procedure
[docs/update_lib_to_act_cpu.md](../../docs/update_lib_to_act_cpu.md), facts
[`update_plan.md`](../../70-Customer-Projects/FormsReports14_patch_cspu_2026-11/update_plan.md)).

**Next cycle – CSPU December 2026, released Tuesday 2026-12-15:**
<https://www.oracle.com/security-alerts/cspudec2026.html> – then run
`10-Monitoring/patch_cycle_analysis.sh prepare`.

## Patch cycle history

The library itself is not versioned (always "latest"). This file is: at
every new cycle the previous state is frozen as a snapshot, so it stays
traceable what belonged to a cycle, and an environment can be brought
**by hand** to an earlier patch level (e.g. a bug in the current CPU).

| Cycle | Released | Type | Configured in this project | Status | Document | Manual guide (how, by hand) |
|---|---|---|---|---|---|---|
| CSPU November 2026 | 2026-11-17 | CSPU | from 2026-11-18 | **current – applied on the test host 2026-11-18** (by hand, cumulative guide; smoke test OK, validate 0 FAIL; DB MRP, APEX 26.2.1, ORDS 26.3.1) – **lib switched 2026-11-18** (release `v1.0.202611`) – patch numbers from KA1182 (2026-11-17 19:11), CPU450 (FMW), CPU435 (Java), CPU431 (DB / APEX / ORDS); all READMEs read from the ZIPs 2026-11-18 | this file | [FormsReports14_patch_cspu_2026-11](../../70-Customer-Projects/FormsReports14_patch_cspu_2026-11/README.md) – full + cumulative from CPU Oct 2026 |
| Security Alert CVE-2026-114820 (Java, eMudhra CAs) + OS `ca-certificates` (ELSA-2026-88459 / CVE-2026-111943) | 2026-10-24 / 2026-10-22 | Alert | 2026-10-26 | **closed by JDK 21.0.13.1** of the CSPU Nov 2026 (CPU435: cumulative, removes the roots) once applied; OS fixed on the test host 2026-10-26; bundled JDK 17.0.12 still trusts them – see [eMudhra](#emudhra-ca-incident--cve-2026-114820-state-2026-10-26) | this file | – |
| OS / third-party: Google Brotli decoder **CVE-2026-111497** ("HTTP2Shell", CISA KEV 2026-10-27) | 2026-10-22 | OS errata | 2026-10-28 | **open (OS update)** – not reachable through Forms / Reports / WebLogic / Nginx; OS fix **ELSA-2026-500513** to install, Reports processes restart – see [Brotli](#brotli-decoder--cve-2026-111497-state-2026-10-28) | this file | – |
| CPU October 2026 + Security Alert CVE-2026-91403 | 2026-10-20 / 2026-10-21 | CPU + Alert | 2026-10-22 – 2026-11-18 | frozen; **applied on the test host 2026-10-24** (smoke test OK) | [00-patch-references_october_2026.md](00-patch-references_october_2026.md) | [FormsReports14_patch_cpu_2026-10](../../70-Customer-Projects/FormsReports14_patch_cpu_2026-10/install_14c_patch_set_october_2026_manual.md) (verified on the test host 2026-10-24) |
| CSPU September 2026 | 2026-09-15 | CSPU | 2026-10-13 – 2026-10-22 | frozen; set live on the test host – **incomplete**: the FMW Infrastructure bundle patches (ADF, OWSM, OPSS, UMS, …) were missing | [00-patch-references_september_2026.md](00-patch-references_september_2026.md) | – (applied by the scripts, steps in `docs/05` / `06` of that time, see git history) |

Rule for every new cycle:

0. Start with [`10-Monitoring/patch_cycle_analysis.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/10-Monitoring/patch_cycle_analysis.sh) (`prepare`, then
   `analyse --mode maintainer`) – Claude follows
   [patch_cycle_analysis_skill.md](../../10-Monitoring/patch_cycle_analysis_skill.md)
   and does steps 1–4 below, plus `update_plan.md` for the lib switch.
1. Copy this file to `00-patch-references_<month>_<year>.md` – the month of
   the cycle it **describes** (e.g. `_october_2026`) – add the "Frozen
   snapshot … Do not edit" header, nothing else.
2. Add the row to the table above, link the snapshot.
3. Then rework **this** file for the new cycle. Every other file links
   only `00-patch-references.md` for the current state – a snapshot is
   linked only from this table or where a text describes that one cycle.
4. Manual guides: create the folder
   `70-Customer-Projects/FormsReports14_patch_<cpu|cspu>_<yyyy>-<mm>/` with
   the analysis `README.md` (facts of every patch README) and **two**
   guides – `install_14c_patch_set_<month>_<year>_manual_full.md` (whole
   cumulative set, any older level) and
   `install_14c_patch_set_<month>_<year>_manual_cumulativ_from_<cpu|cspu><mm><yyyy>.md`
   (only the patches newer than the **directly previous** cycle). The
   folder of the previous cycle stays as it is, only the "Frozen – do not
   edit" header is added; link the new one in the table above. The guides
   are the master for the scripts:
   [`oracle_software_version.conf`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/oracle_software_version.conf) is switched only after a guide was run
   on the test host.
5. Switch the library with [docs/update_lib_to_act_cpu.md](../../docs/update_lib_to_act_cpu.md)
   + `update_plan.md` – one commit, release tag `v1.0.<yyyymm>`.

Division of roles: **this file** = what / why (patch numbers, KA1182, CVEs);
the **manual guides** = how, by hand, per cycle; the **scripts** +
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
| **CPU450** | Patch Availability Document for Fusion Middleware, CSPU November 2026 (updated 2026-11-17 18:36) | **patch ↔ CVE mapping** of the new patches of the cycle (WLS PSU 40205408, Third-Party BP 40288205, OPSS 40154045, ADF 40155248, UMS 40145610, OHS 40181911, WebCenter Core 40035984) – since November the CVE vehicle is documented, no longer an assumption |
| **CPU435** | Oracle CSPU November 2026 for Oracle Java SE (updated 2026-11-17) | Target JDK of this cycle: **21.0.13.1** (fixed patch 40239626, well-known **35702194**), JDK 17.0.21.1 (40239631 / 33181589), JDK / JRE 8u513-b04 (40239638 / **40239650**) – see "Special case Java" |
| **CPU431** | CPU/CSPU November 2026 for Oracle Database Products (PAD, updated 2026-11-18) | Repository DB 19.33: **DB MRP 40196156** (19.33.0.0.261117, Linux x86-64), DB home JDK 8u513 **40245331**; APEX → 26.2.1 (patch set bundle 40040466); ORDS → **26.3.1** |
| CPU454 | CSPU November 2026 Patch Availability Document for Oracle Products (Enterprise Manager) | Only if EM Cloud Control is used – not part of this stack |
| **KA204** | Oracle Forms and Reports Quarterly Patch Release (QPR) Information | Current Forms/Reports QPR patch numbers |
| CPU360 / CPU388 / CPU426 | FMW PAD CPU Oct 2026 / Java SE CPU Oct 2026 / Java Security Alert CVE-2026-91403 | History (cycle CPU Oct 2026, [snapshot](00-patch-references_october_2026.md)) |
| CPU349 | CSPU September 2026 for Oracle Java SE | History (cycle CSPU Sep 2026) |
| CPU211 | Patch Availability Document FMW, CPU July 2026 | History (cycle CPU Jul 2026) |
| KB379953 | Details for FMW Third-Party Component Updates | Third-Party BP (in the SPB); PNEWS2138 (= Doc ID 3093394.1, the "post-install" note of the ADF BP, read 2026-10-24): ADF BP, Third-Party BP and WLS PSU share the GraalVM libraries – apply all three from the same cycle; a runtime home needs at least ADF + WLS PSU (else EM does not deploy), the IDE also the Third-Party BP. No post-install command |
| KB417168 | Primary Note on Coherence Patch Releases | Coherence cumulative patch (in the SPB) |
| KB168467 | Stack Patch Bundle (SPB) with SPBAT Utility | Background on the SPB/SPBAT mechanism reintroduced for 14.1.2 in CSPU Sep 2026 — see the corrected note in `docs/05-oracle_patch_weblogic.md` |
| KB175049 | Installing and maintaining Java SE for FMW 11g/12c/14c | JDK install/update procedure, referenced by [`02b-root_os_java.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/02b-root_os_java.sh) |
| KB159467 | Restricting Incoming Serialized Java Objects (JEP 290) | Why an up-to-date JDK is required for the WLS PSU deserialization fixes to take effect |
| KB694158 | Security Advice and Post-Install for WLS PSUs (PDF F41372-26, "Updated for November 2026", read 2026-11-18) | Post-install steps after the WLS SPB / PSU. **November 2026:** new FeatureCompatibilityMBean attribute `JAXWSRejectUnknownSEIOperationsEnabled` (PSU bug 40073770) – JAX-WS endpoints with a Service Endpoint Interface answer SOAP requests for unknown operations with a SOAP fault; **default true** (unlike the Jul / Aug / Sep 2026 gates, all default false), dynamic, `false` = old behaviour |
| KB559857 | Cumulative README Post-Install Steps for OHS 14.1.2.0 Bundle Patches | OHS bundle patch post-install – the OHS binaries are in every Forms & Reports home, patched from this cycle on. Read 2026-10-24: no command; Oct 2026 hardening directives (header stripping, header validation, `SSLProxyCheckPeerName`, …) all off by default, July hardening reverted to off – only for an OHS instance / `mod_wl_24`, nothing to do with Nginx as frontend |
| [KB118538](https://support.oracle.com/support/?documentId=KB118538) | Changes in Native Network Encryption (NNE) with the July 2021 CPU (CVE-2021-2351) | DB check of every FMW CPU (step 1 in KA1182): repository database (RCU) on July 2021 or later; new parameters `SQLNET.ALLOW_WEAK_CRYPTO_CLIENTS` (DB) / `SQLNET.ALLOW_WEAK_CRYPTO` (client), JDBC thin `oracle.net.allow_weak_crypto` – see the customer analysis 12.2.1.19 §1 for the check |
| KB618392 | Zero Downtime Patching for FMW/WLS (legacy Doc ID 1942159.1) | Background on ZDT patching for a live production system (not used during initial install, no domain exists yet) |

CPU450 / CPU435 / CPU431 are the links in the "Patch Availability Document"
column of the public advisory (read 2026-11-18); their content needs a MOS
login. CPU450 lists only the **new** patches of a cycle (and their CVEs),
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
   the current patch numbers against [`09-Install/download/patches_fmw.csv`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/download/patches_fmw.csv).
2. New cycle → first freeze this file (see "Patch cycle history"), then
   rework it.
3. If a Doc ID listed here has been superseded or renumbered by Oracle,
   update this table — do not silently start referencing a new number
   from inline comments elsewhere, this table is the single place to look.
4. Set `PATCH_CYCLE`, `PATCH_CYCLE_DATE`, `PATCH_CYCLE_ADVISORY` in
   [`oracle_software_version.conf`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/oracle_software_version.conf) together with the patch numbers in
   `download/patches_fmw.csv` (DB repository: `download/patches_db.csv`) –
   [`10-Monitoring/cve_inventory.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/10-Monitoring/cve_inventory.sh) compares installed patches and newer
   advisories against them; [`10-Monitoring/cve_watch.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/10-Monitoring/cve_watch.sh) uses
   `PATCH_CYCLE_DATE` as "covered by the applied cycle" for the daily
   early warning (NVD, OSV, KEV).
5. Patch numbers themselves live in `download/patches_fmw.csv`, not
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
  <https://www.oracle.com/security-alerts/> – an alert does not wait for the
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
  scripts and [`cve_inventory.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/10-Monitoring/cve_inventory.sh) check. Oracle does not publish which patch
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

### What a home needs – CPU vs. CSPU (one list, two starting points)

A CSPU **complements** the quarterly CPU – but for the FMW home that does
**not** mean "CPU run + CSPU run". KA1182 is **cumulative**: the November
2026 version still lists every patch a home needs, including the ones
released with the October CPU (column "CPU/CSPU Release" = "Oct 2026":
OPatch .25, Coherence CP10, WebCenter Core, OWSM, PERL, the QPRs …). So the
**current KA1182 list = the complete set**, whatever kind the current cycle
is.

| Component | Home never patched / older than the previous cycle | Home on the previous cycle (here CPU Oct 2026) | How the library covers it |
|---|---|---|---|
| FMW home (SPB, infrastructure bundles, PERL, OHS, WebGate, QPRs) | **all** rows of the current KA1182 – one run (full guide) | only the rows newer than the previous cycle (cumulative guide) | **one** `download/patches_fmw.csv` = the full KA1182 set (unchanged rows stay, new numbers replace old ones); `05-` / `06-` skip what is installed (SPB marker, "already installed"), OPatch deactivates older bundles itself (sub-set, live 2026-11-18) |
| Java (`JDK_HOME`, client) | newest build only (35702194 "latest") | same | `JDK_VERSION_MIN` – no stacking |
| Repository DB 19c | **RU of the last CPU** (19.33 = Oct 2026) **+ MRP / CSPU patch of the month** (Nov: MRP 40196156) + DB home JDK – two layers | only the MRP + DB home JDK | `patches_db.csv`: RU, OJVM, DPBP, DB JDK + role **`db_mrp`** (`database/mrp/<nr>/`, not linked into the AutoUpgrade patchdir); in-place apply documented ([09-db_patch_rcu.md – Monthly MRP](../../60-RCU-DB-19c/docs/09-db_patch_rcu.md#monthly-mrp-in-place-cspu-months), live 2026-11-18), script mode `09- --mrp` open (TODO) |
| APEX | base release (26.2) + patch set bundle (26.2.1) | patch set bundle only | `02-install-apex.sh` + `03-patch-apex.sh` (`APEX_PATCH_NR`) |
| ORDS | newest release (complete install) | same | `06-patch-ords.sh` |

Special case **overlay**: when a CSPU brings no new SPB but a single patch
on top of the CPU's PSU (CSPU Sep 2026: WLS SPU 39988381 on PSU 39919611),
the full set is the CPU's SPB **plus** the overlay – two rows in the CSV
(`spb` + `wls`), both applied by `05-`. At the next CPU the new PSU
contains the fix and OPatch rolls the overlay back (superset, confirmed
2026-10-24) – the overlay row moves to "Superseded".

The two manual guides of a cycle folder follow exactly this split: `_full`
(complete set) and `_cumulativ_from_<previous cycle>` (only the newer
rows) – see [docs/update_lib_to_act_cpu.md](../../docs/update_lib_to_act_cpu.md) §2.

### Release dates (from the advisories)

| Date | Type | State 2026-11-18 |
|---|---|---|
| 21 July 2026 | CPU | released |
| 18 August 2026 | CSPU | released |
| 15 September 2026 | CSPU | released – frozen in [00-patch-references_september_2026.md](00-patch-references_september_2026.md) |
| 20 October 2026 | CPU | released – frozen in [00-patch-references_october_2026.md](00-patch-references_october_2026.md) |
| 21 October 2026 | Security Alert CVE-2026-91403 | released – Java SE JSSE, fixed in 21.0.13.0.2 (CPU426) – part of the October snapshot |
| 24 October 2026 | Security Alert CVE-2026-114820 | released (Rev 2 2026-10-30) – Java SE, eMudhra CAs; closed by the November Java builds |
| 6 November 2026 | Security Alert CVE-2026-109618 / -109619 ("PHP2Shell", Rev 3) | Oracle Communications, Secure Backup, Solaris – **not** in this stack |
| 17 November 2026 | CSPU | released – **current cycle**; pre-release announcement until the evening, final advisory 2026-11-18 morning (CET); Fusion Middleware 71 fixes (53 remote w/o auth, max 10.0), Java SE 11 (max 8.1), DB 7, APEX 2, ORDS 8 |
| 15 December 2026 | CSPU | planned |
| 19 January 2027 | CPU | planned (also the next Java CPU) |

The final November advisory differed from the pre-release in one point that
matters here: **ORDS 26.3.0 moved into the affected range** (pre-release:
"up to 26.2.3", final: 24.2.0–26.3.0). Always re-read the final page.

### Public advisories (no MOS login needed)

All links checked 2026-11-18 (HTTP 200, title matches).

| Advisory | URL |
|---|---|
| Overview – CPUs, CSPUs, Security Alerts and Bulletins | <https://www.oracle.com/security-alerts/> |
| CSPU November 2026 (+ text risk matrix `cspunov2026verbose.html`) | <https://www.oracle.com/security-alerts/cspunov2026.html> |
| Security Alert CVE-2026-114820 (Java SE, eMudhra) | <https://www.oracle.com/security-alerts/alert-cve-2026-114820.html> |
| Security Alert CVE-2026-91403 (Java SE JSSE) | <https://www.oracle.com/security-alerts/alert-cve-2026-91403.html> |
| CPU October 2026 | <https://www.oracle.com/security-alerts/cpuoct2026.html> |
| CSPU September 2026 | <https://www.oracle.com/security-alerts/cspusep2026.html> |
| CSPU August 2026 | <https://www.oracle.com/security-alerts/cspuaug2026.html> |
| CPU July 2026 | <https://www.oracle.com/security-alerts/cpujul2026.html> |

Naming pattern: `cpu<mon><yyyy>.html` for CPUs, `cspu<mon><yyyy>.html` for
CSPUs, `alert-cve-<yyyy>-<nr>.html` for Security Alerts. `www.oracle.com`
refuses some non-browser clients (HTTP 403) – with `curl -A "Mozilla/5.0"`
it answers.

### CVE check 2026-11-18 – CSPU November 2026

Filtered from the Fusion Middleware risk matrix of the final CSPU Nov 2026
advisory: all rows whose affected versions include **14.1.2.0.0** and whose
product is part of a Forms & Reports home. Not listed: Oracle Access Manager
server (10.0 rows, 14.1.2.1.0 – the home only has the OAM **client**
libraries), SOA / BPM, OSB, MFT, WebCenter Content / Portal / Sites,
Identity Manager connectors. Oracle Forms, Oracle Reports, Coherence, OWSM,
FMW Control, LibOVD and WebGate have **no** row. Unlike earlier cycles the
vehicle is documented: column "Fix in patch" = **CPU450**, confirmed in the
patch README from the ZIP (2026-11-18).

| CVE | Product / component | Protocol | Remote w/o auth | CVSS 3.1 | Relevant here | Fix in patch (CPU450 + README) |
|---|---|---|---|---|---|---|
| **CVE-2026-91569** | WebLogic Server / TopLink Integration | HTTP | yes | **10.0** | **yes** – reachable through Nginx | SPB 40289362 (WLS PSU **40205408**) – confirmed |
| **CVE-2026-91570 / 91583** | WebLogic Server / TopLink Integration | HTTP | yes | **9.8** | yes | WLS PSU 40205408 – confirmed |
| **CVE-2026-91585** | WebLogic Server / TopLink Integration | TCP | yes | **9.8** | yes (local / internal network) | WLS PSU 40205408 – confirmed |
| **CVE-2026-91456** | WebLogic Server / Core | SOAP | yes | **9.8** | yes | WLS PSU 40205408 – confirmed |
| **CVE-2026-91470** | WebLogic Server / Core | T3, IIOP | yes | **9.8** | yes – every installation (T3 not exposed through Nginx, but local / internal network) | WLS PSU 40205408 – confirmed |
| CVE-2026-91469 | WebLogic Server / Core | HTTP | yes | 9.4 | yes | WLS PSU 40205408 – confirmed |
| **CVE-2026-114824** | Platform Security for Java / Centralized Thirdparty Jars | HTTP | yes | **10.0** | yes – OPSS in every infrastructure home | OPSS BP **40154045** (README: unnamed "Fix for Bug 39289054 / 39289108 / 39289143 / 39291300") – CPU450 |
| CVE-2026-91548 / 91551 / 91560 | Platform Security for Java / Centralized Thirdparty Jars | HTTP | yes | 8.6 / 7.5 / 6.5 | yes | OPSS BP 40154045 – CPU450 |
| **CVE-2026-114826** | Service Delivery Platform (= **UMS**) / Messaging Enabler | SOAP | yes | **9.8** | component in the home (`oracle.sdp.messaging`), but **not reachable** in our domain: only the UMS client libraries are deployed, no UMS server application (checked 2026-11-18, endpoints 404 – [installed / deployed / reachable](../../80-FMW-Architecture/weblogic_middleware_architecture.md#37-infrastructure-components-in-every-home--installed-deployed-reachable)) – patched anyway | UMS BP **40145610** – confirmed |
| CVE-2026-91556 / 91558 / 75596 / 91678 | Service Delivery Platform / Messaging Enabler, Netty, Installer | HTTP / HTTPS / TLS / local | partly | 8.8 / 8.3 / 7.5 / 3.3 | yes | UMS BP 40145610 – confirmed |
| CVE-2026-9545 (+ 6276, 6429, 7168, 8924) | Oracle HTTP Server / WLS Proxy Plug-in for OHS (curl) | HTTPS | yes | 7.5 | yes – OHS binaries in the home (no instance) | OHS BP **40181911** (README: "Fix for Bug 39932075") – CPU450 |
| CVE-2026-91403 | Middleware Common Libraries and Tools / Thirdparty Patch (Certifi) | Multiple | yes | 7.4 | yes (library on disk) | SPB 40289362 (Third-Party BP **40288205**, Bug 40202517) – confirmed |
| CVE-2026-91544 | ADF / ADF Faces | HTTP | yes (user interaction) | 6.1 | yes – ADF runtime in every infrastructure home | **already in our ADF BP 40050062** (since .260721); new ADF BP **40155248** adds CVE-2026-91618 (matrix: 12.2.1.4 only) – CPU450 |
| CVE-2026-91619 / 91670 | ADF / ADF Faces | HTTP | yes | 3.7 | low | matrix lists 14.1.2.0.0, **CPU450 maps them only to the 12.2.1.4 ADF patch** – follow the PAD, newest ADF BP applied anyway |
| CVE-2026-91525 / 91529 / 91567 / 91586 / 91587 | WebCenter Portal / Composer | HTTP | partly | 6.5 – 8.6 | yes – `oracle.webcenter.*` in every infrastructure home | WebCenter Core BP **40035984** – the **October** patch, already applied (CPU450) |

Java SE matrix of the CSPU Nov 2026 (11 rows, max 8.1 CVE-2026-114938,
Compiler): affected **21.0.13.0.3**, **17.0.21.0.3**, **8u511b33** → our
`JDK_HOME` 21.0.13.0.2 and the client JRE 8u511 (b26 / b32) are affected;
fix 21.0.13.1 / 8u513 (CPU435) – see "Special case Java".

---

## Special case Java – two JDKs, one alert

Background – why an FMW host has two JDKs and who runs on which:
[weblogic_middleware_architecture.md §1](../../80-FMW-Architecture/weblogic_middleware_architecture.md#1-terms--the-four-homes),
[reports_engine_architecture.md §1](../../80-FMW-Architecture/reports_engine_architecture.md#1-the-parts).

Java gets its own section since the October cycle: the CPU of 20 October
fixed Java with 21.0.13, the alert of 21 October (CVE-2026-91403) declared
exactly that build affected (→ 21.0.13.0.2), the eMudhra alert of
24 October (CVE-2026-114820) declared 21.0.13.0.2 affected again. History
of those two alerts: [October snapshot](00-patch-references_october_2026.md#special-case-java--two-jdks-one-alert).

**CSPU November 2026 – CPU435** (updated 2026-11-17, read 2026-11-18):

| Release (Java CSPU Nov 2026) | Fixed-version patch | Well-known patch ("latest") | Relevant here |
|---|---|---|---|
| JDK **21.0.13.1+4** | 40239626 | **35702194** (JDK 21 latest) – **ZIP checked 2026-11-18: `jdk-21.0.13.1_linux-x64_bin.tar.gz`** (Windows ZIP: `jdk-21.0.13.1_windows-x64_bin.zip`) | **yes** – `JDK_HOME` and the Forms client bundle |
| JDK 17.0.21.1+4 | 40239631 | 33181589 (JDK 17 latest) | no – the bundled JDK 17 is an OPatch component, not patched with this ZIP |
| JDK / **JRE 8u513-b04** | 40239638 / **40239650** (ServerJRE 40239653) | 18143322 (JDK 8 latest) | **yes for clients** – Forms clients on Java 8 (Web Start) |
| JDK 8 perf / JavaFX 21 | 40239685 / 40245620 | 34689523 / – | no |

- KA1182 (WLS tab) demands "21.0.13.1 or later" (35702194) / "17.0.21.1 or
  later" (33181589) – no stricter alert build this time.
- 21.0.13.1 is **cumulative**: it also closes the eMudhra alert
  CVE-2026-114820 (affected 21.0.13.0.2 / 8u511-b32) – the roots are
  removed, not only the intermediates blocked.
- Security baselines (release notes 21.0.13.1): 21.0.13.1+4, 17.0.21.1+4,
  1.8.0_513-b04. Next Java CPU: 2027-01-19.
- Behaviour change 21.0.13.1: Kerberos cross-realm "transited" check
  enabled (`sun.security.krb5.acceptor.checkTransitedPolicy`) – only with
  Kerberos SSO in WebLogic.
- Licence: JDK 21 updates since 21.0.13 are under the OTN licence for Java
  SE (no longer NFTC) – already the case for 21.0.13.0.2; use with FMW is
  covered by the FMW licence (restricted use, Doc ID 1557737.1).

The version compare of [`02b-root_os_java.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/02b-root_os_java.sh) (`sort -V`) orders
21.0.13.0.2 < 21.0.13.1 correctly – no script change needed.

| JDK | Where | Used by | Action this cycle | State 2026-11-18 |
|---|---|---|---|---|
| Oracle JDK 21 at `JDK_HOME` | outside the Oracle Home ([`02b-root_os_java.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/02b-root_os_java.sh)) | WebLogic servers, Node Manager, WLST | Patch **35702194** (ZIP name never changes – the version is only visible inside) → `JDK_VERSION_MIN="21.0.13.1"`; `04-oracle_pre_download.sh --apply --fresh-patches --mos`, then `07-Maintenance/80-patch_java_os.sh --apply` (domain stopped), `domain_jdk_path.sh`, `40- --apply` for the Forms client bundle | test host on **21.0.13.0.2** (affected by the Nov Java matrix and the eMudhra alert); 21.0.13.1 downloaded to the staging area 2026-11-18 |
| FMW-bundled JDK 17 `$ORACLE_HOME/oracle_common/jdk` | inside the Oracle Home, OPatch component `oracle.jdk` 17.0.12.8.0 | Reports server/engines, Forms/Reports tools (`rwrun`, `rwconverter`, `frmcmp`, …) | OPatch patch `FMW_JDK_PATCH_NR` | **blocked** – KA1182 November still names no patch for it; 17.0.12 is affected by every Java 17 CVE since 2024 and still trusts the eMudhra roots. The Reports QPR fix 37866660 ("alternative JAVA_HOME") is **no** way out (tools only, `rwengine.sh` hard-codes `oracle_common/jdk`) → SR needed (draft `SR/`) |
| Client JRE of the Forms users | user PCs (Java Web Start / FSAL standalone launcher) | Forms applet runtime, **TLS client** of the Forms session | roll out **JRE 8u513** (40239650, platform = bitness of the clients / WebUtil DLLs) or the 21.0.13.1 runtime of the Forms client bundle (FSAL) through the customer's software distribution; test that the trust of the code-signing certificate survives the JRE update | customer task |

Why the client is the critical side: in this architecture TLS terminates
in Nginx (OpenSSL), Nginx → WLS and WLS → `frmweb` are plain connections on
the server, so the server-side JSSE is hardly in the TLS path – but the
Forms client JRE is a JSSE TLS client, and a manipulated Forms/WebUtil
session can control the client with user rights. Details:
[forms_runtime_architecture.md §1.1 / §1.2](../../80-FMW-Architecture/forms_runtime_architecture.md#11-where-tls-is-spoken--and-who-uses-javas-jsse)
and [forms_jakob_webutil.md §10.1](../../80-FMW-Architecture/forms_jakob_webutil.md#101-what-the-session-can-do-on-the-client--threat-model).

### Java4Shell – CVE-2026-114938 (state 2026-11-18)

**What it is:** memory corruption in the **x86-64 Base64 intrinsic** of
HotSpot (AVX-512 VBMI code path of `java.util.Base64` decoding, OpenJDK
component `hotspot/compiler`). The padding `=` is mishandled, the stub
computes a negative output length and writes decoded bytes to the wrong
place – trigger: 64 × `A` + `=` (OpenJDK 17: 128 × `A` + `=`). Named
"Java4Shell" by the finder Calif (CVSS 4.0 9.2); Oracle / OpenJDK rate it
**CVSS 3.1 8.1** (AV:N/AC:H/PR:N/UI:N). Calif shows unauthenticated RCE in
Keycloak, Jira, Confluence, Artifactory, Jenkins – an application-specific
exploit is needed, sending the string to any Base64 input is not enough.
No attacks in the wild known (2026-11-18), no public PoC for the products.
Part of the **Java CSPU November 2026** (11 Java CVEs, max 8.1) – fixed by
the same builds as the rest of the cycle.

| | |
|---|---|
| Affected (Oracle Java SE matrix / OpenJDK advisory 2026-11-17) | **17.0.21.0.3, 21.0.13.0.3**, 25.0.5.0.3, 27.0.1.0.3 and earlier – per Calif from **17.0.6** on; Java 8 only the **`8u511b33-perf`** build (regular 8u builds and 11 not listed for this CVE); GraalVM for JDK 17 / 21 |
| Fixed | **21.0.13.1**, 17.0.21.1, 25.0.5.1 … (CPU435) |
| Precondition | x86-64 CPU with **AVX-512 F / BW / VBMI** (+ BMI2): Intel Xeon Ice Lake, Sapphire / Emerald / Granite Rapids; AMD **Zen 4** and newer (EPYC Genoa, Ryzen 7000) – typical cloud shapes (e.g. OCI E5 / X9 class) **are** affected; ARM64 is not |
| Check a host | `grep -m1 '^flags' /proc/cpuinfo \| tr ' ' '\n' \| grep -E '^(avx512f\|avx512bw\|avx512vbmi\|bmi2)$'` – all four = vulnerable code path possible; `java -XX:+UnlockDiagnosticVMOptions -XX:+PrintFlagsFinal -version \| grep UseBASE64Intrinsics` |
| Mitigation without update | JVM option **`-XX:-UseBASE64Intrinsics`** (pure-Java Base64) or `-XX:UseAVX=2` (no AVX-512; x86-64 only – an ARM JVM does not start with it) |
| Sources | heise 2026-11-17/18 ("Java4Shell: Gefährlicher Bug in Java", "Java-RCE mit AAAA…="), <https://calif.io/java4shell/>, <https://openjdk.org/groups/vulnerability/advisories/2026-11-17>, CSPU Nov 2026 Java SE matrix |

**Our stack – checked 2026-11-18 on the test host** (CPU Intel Core
i9-13980HX, Raptor Lake: **avx2 only, no AVX-512** → the vulnerable stub
cannot run here at all):

| JVM | Version | Java4Shell | Action |
|---|---|---|---|
| `JDK_HOME` (WebLogic, Node Manager, WLST, **ORDS**, SQLcl) | **21.0.13.1** since 2026-11-18 | **fixed** (was 21.0.13.0.2 = affected); `UseBASE64Intrinsics=true` on this CPU (AVX2 variant – not the AVX-512 path) | done – customer hosts: switch with the CSPU Nov 2026 |
| FMW-bundled `oracle_common/jdk` (**Reports server / engines**, Forms / Reports tools) | **17.0.12** | **in the affected range** (17.0.6+), **no FMW patch** (KA1182 Nov names none); on the test host `UseBASE64Intrinsics=false` (no AVX-512) → not reachable | on an **AVX-512 VBMI host** (cloud, newer Xeon / EPYC): add `-XX:-UseBASE64Intrinsics` to the JVM options of the Reports server / engines (`REPORTS_JVM_OPTIONS` / engine `jvmOptions` in `rwserver.conf`) – mitigation until Oracle ships a bundled-JDK patch (SR draft "bundled JDK 17"). Whether Reports decodes attacker-controlled Base64 at all is **not known** (assumption: low) |
| Forms client runtime (FSAL bundle, `40-`) | 21.0.13.0.2 | affected – and **client PCs** often have Zen 4 / Ryzen 7000 or Ice Lake+ | `40-oracle_forms_client_bundle.sh --apply` with 21.0.13.1 right after the lib switch; until then `-XX:-UseBASE64Intrinsics` would need a client-side JVM option |
| Client JRE 8 (Web Start) | 8u511 b26 / b32 | **not** listed for CVE-2026-114938 (only `-perf`); but other Nov CVEs (JSSE 114940, JGSS 114939 …) → 8u513 | 8u513 (40239650) through the customer's software distribution |
| DB home JDK (repository DB) | **8u513-b04** since 2026-11-18 | not affected (Java 8) | done |
| Customer F&R 12.2.1.19 homes | JDK 8 (8u411 / bundled 8u341) | not affected by Java4Shell (Java 8), affected by the other Java 8 CVEs | 8u513 – [12c CSPU folder](../../70-Customer-Projects/FormsReports12_patch_cspu_2026-11/README.md) |

Rule for customer hosts: run the CPU-flag check first. Without AVX-512
VBMI Java4Shell is not exploitable, but the update stays mandatory because
of the other ten Java CVEs (JSSE / TLS clients).

### eMudhra CA incident – CVE-2026-114820 (state 2026-10-26)

> **Update 2026-11-18:** the November Java builds (21.0.13.1, 17.0.21.1,
> 8u513 – CPU435) are cumulative and remove the eMudhra roots; with the
> switch to the CSPU November 2026 `JDK_HOME` and the client runtimes are
> closed. Still open: the bundled JDK 17.0.12 (no patch) and customer JDK 8
> homes below 8u511-b32 / 8u513.

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

### Brotli decoder – CVE-2026-111497 (state 2026-10-28)

**What it is:** out-of-bounds write in the **C decoder of Google Brotli**
(`c/dec/decode.c`), versions 1.0.3 – 1.2.0, fixed in 1.0.10 / 1.1.1 /
1.2.1 (CVE record 2026-10-22; CVSS 4.0 9.2, Red Hat CVSS 3.1 8.1 Important;
CISA KEV since 2026-10-27). Reachable wherever attacker-controlled
Brotli data is decoded – e.g. HTTP bodies with `Content-Encoding: br`
(request side: Envoy, Express 5; response side: clients that send
`Accept-Encoding: br`). Not an HTTP/2 protocol flaw despite the nickname.
Products with an own copy (Node.js, Bun, Envoy, …) need their own fix.

**Forms & Reports 14.1.2 stack – checked on the test host 2026-10-28
(confirmed (live)):**

| Component | Finding | Assessment |
|---|---|---|
| **Nginx** (`nginx-core-1.20.1` OL9) | not linked against libbrotli, no `ngx_brotli` module, no `load_module` | **not affected** – passes `br` bodies through without decoding |
| **WebLogic / JDKs / ORDS** | no native libbrotli in the Oracle Home, `JDK_HOME`, bundled JDK, ORDS homes; `httpclient5-5.6.4.jar` (and `oamcfgtool.jar`) only contain Brotli wrapper classes – the Java decoder `org.brotli.dec` is **not** on any class path | **not affected** |
| **Reports** (`rwserver`, engine JVMs) | map `/usr/lib64/libbrotlidec.so.1.0.9` – loaded through **`libfreetype`** (font rendering; FreeType decodes Brotli only for WOFF2 web fonts) | vulnerable library **loaded but not reachable remotely** (Reports reads local TTF fonts); fixed with the OS update + restart |
| **OS packages** | `brotli`, `libbrotli`, `python3-brotli`, `brotli-devel` `1.0.9-10.el9_8`; `libcurl` links libbrotli (`curl --compressed`) | **affected** – OS fix below |
| **Node.js of Claude Code** (`10-Monitoring/`, nodesource `nodejs-20.20.2`) | bundled its own **Brotli 1.1.0** | **fixed 2026-11-13 on the test host:** npm CLI 2.1.287 and Node.js 20 (end of life) removed, native Claude Code build 2.1.325 without Node.js installed – see [setup_claude.md](../../10-Monitoring/setup_claude.md) §2 |

**OS fix:** Oracle Linux 9 **ELSA-2026-500513** (Important, 2026-10-26):
`brotli-1.0.9-10.0.1.el9_8` – Oracle backported the fix into 1.0.9 (the
`.0.1` release counts, not the upstream version number);
`dnf updateinfo list --cve CVE-2026-111497` lists it.

```bash
# as root (or with the regular OS update)
dnf update brotli libbrotli python3-brotli brotli-devel
# processes that still map the old library -> restart (Reports server + engines)
grep -l 'libbrotli.*(deleted)' /proc/[0-9]*/maps 2>/dev/null
dnf needs-restarting
01-Run/startStop.sh stop-all --apply && 01-Run/startStop.sh start-all --apply   # as oracle
```

Not part of the Oracle CPU / CSPU – OS errata only; check again with the
next [`10-Monitoring/cve_inventory.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/10-Monitoring/cve_inventory.sh) run (OS errata section).

Sources: CVE record <https://www.cve.org/CVERecord?id=CVE-2026-111497> ·
<https://brandefense.io/blog/http2shell-brotli-cve-2026-111497/> ·
<https://linux.oracle.com/errata/ELSA-2026-500513.html> ·
<https://nodejs.org/en/blog/vulnerability/october-2026-security-releases>

## Patch List — CSPU November 2026 cycle

Target: Oracle Forms & Reports 14.1.2.0.0 on Linux x86-64 (Oracle Linux 9),
Nginx as frontend. Source: KA1182 "LATEST for NOVEMBER 2026" (last updated
2026-11-17 19:11, tabs Forms and Reports / FMW Infrastructure / WebLogic
Server / Oracle HTTP Server 14.1.2.0), CPU450, CPU435 for Java. The column
"Previous (CPU Oct 2026)" is what is installed on the test host today
(`opatch lspatches` 2026-11-18: 21 patches, OPatch 13.9.4.2.25).
[`oracle_software_version.conf`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/oracle_software_version.conf) and `download/patches_fmw.csv`
are switched to this set (2026-11-18, release `v1.0.202611`).

All ZIPs downloaded 2026-11-18 (`mos_patch_download.sh`, staging area,
`unzip -t` OK, SHA-256 + ARU recorded); every README below was read **from
the ZIP** and matched the portal README.

A home on the **October state** needs exactly: JDK 21.0.13.1, SPB 40289362,
ADF 40155248, OPSS 40154045, UMS 40145610, OHS 40181911 (plus the client
JRE / client bundle) – OPatch, the other five infrastructure bundles, PERL,
WebGate and the QPRs stay.

### Required

| # | Patch (CSPU Nov 2026) | Previous (CPU Oct 2026) | Description | KA1182 release | ARU (ZIP) | Applied by |
|---|---|---|---|---|---|---|
| 1 | 35702194 → **21.0.13.1** (fixed 40239626) | 35702194 = 21.0.13.0.2 | Oracle JDK 21 at `JDK_HOME` – ZIP checked: `jdk-21.0.13.1_linux-x64_bin.*` | Nov 2026 | – (no inventory) | `04-` download, `07-Maintenance/80- --apply` |
| 1b | *blocked* | *blocked* | FMW-bundled JDK `oracle_common/jdk` (`oracle.jdk` 17.0.12.8.0) – KA1182 lists no patch | – | – | – |
| 2 | 28186730 → 13.9.4.2.25 (unchanged) | 13.9.4.2.25 | OPatch – also in the SPB (`tools/opatch/generic/`); the bundles need ≥ 13.9.4.2.17, the PSU ≥ 13.9.4.2.18 | Oct 2026 | – | `05-` |
| 3 | **40289362** | 40125898 | WLS Stack Patch Bundle **14.1.2.0.261112** (README 11-Nov-26, content below) | Nov 2026 | – (bundle; marker 40289390 = 29577054) | `05-` (`napply`) |
| 4 | 39951765 (unchanged) | 39951765 | PERL 5.42.2 Security Update for FMW 14.1.2 – needs DBCLIENT 23.26.0+ (SPB) | Oct 2026 | | `06-` |
| 5 | 39600348 (unchanged) | 39600348 | Oracle Reports Developer QPR 14.1.2.0 | Aug 2026 | | `06-` |
| 6 | **40181911** | 39987730 | OHS (Native) Bundle Patch **14.1.2.0.261020** (Linux x86-64, README 20-Oct-26) – new: 39932075 = CVE-2026-9545 (curl, CPU450). Post-install KB559857 (unchanged since 2026-10-20 – nothing to do without an OHS instance) | Nov 2026 | **29522371** | `06-` |
| 7 | 39100536 (unchanged) | 39100536 | OAM WebGate Bundle Patch 14.1.2.0.260318 | Apr 2026 | | `06-` |

### FMW Infrastructure bundle patches

Required by KA1182 tab "FMW Infrastructure 14.1.2.0" when only the WLS SPB
is applied. None of them is part of the SPB. All: `opatch apply`, OPatch ≥
13.9.4.2.17, ZDT-eligible (FMW_ROLLING_ORACLE_HOME, not used here),
`opatch rollback -id <nr>`.

| Patch | Previous | Description | KA1182 release | ARU (ZIP) | Note (README from the ZIP, 2026-11-18) |
|---|---|---|---|---|---|
| **40155248** | 40050062 | ADF Bundle Patch **14.1.2.0.261013** (README 27-Oct-26) | Nov 2026 | **29510056** | new: 39326348 = CVE-2026-91618; post-install Doc ID 3093394.1 (= PNEWS2138, unchanged since 2026-01-17): ADF BP + Third-Party BP + WLS PSU from the same cycle – SPB first, then ADF |
| 40035984 (unchanged) | 40035984 | WebCenter Core Bundle Patch 14.1.2.0.260916 | Oct 2026 | | carries 5 WebCenter Portal CVEs of November (CPU450) – already applied |
| 40024749 (unchanged) | 40024749 | OWSM Bundle Patch 14.1.2.0.260914 | Oct 2026 | | |
| 39995927 (unchanged) | 39995927 | FMW Control Bundle Patch 14.1.2.0.260908 | Oct 2026 | | |
| 40057999 (unchanged) | 40057999 | OAMCLIENT Bundle Patch 14.1.2.0.260922 | Oct 2026 | | |
| **40145610** | 39940047 | UMS Bundle Patch **14.1.2.0.261012** (README 12-Oct-26) | Nov 2026 | **29500732** | new: CVE-2026-114826 (**9.8**), -75596, -91678, -91558, -91556; 37969584 clear-text password in `apns_cert_refresh_wlst.log`. Matrix product name "Service Delivery Platform" |
| **40154045** | 39979746 | OPSS Bundle Patch **14.1.2.0.261013** (README 13-Oct-26) | Nov 2026 | **29506290** | new: four unnamed "Fix for Bug" (39289054 / 39289108 / 39289143 / 39291300) = the four OPSS CVEs of November per CPU450 (114824 10.0, 91548, 91551, 91560), 40081462 (P2T plug-in) |
| 39726399 (unchanged) | 39726399 | LibOVD Bundle Patch 14.1.2.0 | Aug 2026 | | |

### Conditional (only if the component is installed in the Oracle Home)

| Patch | Previous | Description | Condition |
|---|---|---|---|
| 39842516 (unchanged) | 39842516 | Oracle Forms QPR 14.1.2.0 (Sep 2026) | Only if Forms is in inventory (`oracle.forms*` / `oracle.developer.forms*`) |
| 38936596 | 38936596 | One-off for Bug 38936596 (ewt3.jar, BiDi parentheses), not in KA1182 | Only if `REPORTS_BIDIPARENTHESIS=YES` (Hebrew) |
| WLS Proxy Plug-In | – | Apache plug-ins 40008996 (OpenSSL 3) / 40014119 (OpenSSL 1), Oct 2026, no new row in November | Only for IIS/Apache as a proxy — not relevant with Nginx |

### DB client tools, APEX, ORDS (own release cycles, not in KA1182)

Security status (CVE check per cycle) and the patch procedure of each: section
[APEX, ORDS, SQLcl and Instant Client](#apex-ords-sqlcl-and-instant-client--security-status-and-patching) at the end.

| Component | Installed by | Release cycle | Update |
|---|---|---|---|
| Oracle Instant Client 23.26.x (`basic`, `sqlplus`, `tools`) | [`00-Setup/install_db_client_tools.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/00-Setup/install_db_client_tools.sh) | follows the quarterly DB RU (23.26.x) | `IC_VERSION` / `IC_URL_BASE` in [`oracle_software_version.conf`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/oracle_software_version.conf), run the script again – link switch after smoke test, `--rollback` |
| SQLcl | [`00-Setup/install_db_client_tools.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/00-Setup/install_db_client_tools.sh) | quarterly OTN release (`sqlcl-latest.zip`) | run the script again |
| APEX 26.x | [`09-Install/04-oracle_pre_download.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/04-oracle_pre_download.sh), [`12-APEX-Ords/02-install-apex.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/12-APEX-Ords/02-install-apex.sh) | OTN release + patch set bundles via MOS (`APEX_PATCH_NR`, platform 2000P) | release upgrade: `02-install-apex.sh`; patch set: [`12-APEX-Ords/03-patch-apex.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/12-APEX-Ords/03-patch-apex.sh) – **November: first 26.2 patch set bundle 40040466 → 26.2.1** |
| ORDS 26.x | [`09-Install/04-oracle_pre_download.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/04-oracle_pre_download.sh), [`12-APEX-Ords/04-install-ords.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/12-APEX-Ords/04-install-ords.sh) | quarterly OTN release + fix releases | [`12-APEX-Ords/06-patch-ords.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/12-APEX-Ords/06-patch-ords.sh) (new release beside the old one, repository upgrade one-way). **ORDS ≥ APEX and the APEXlang compiler in `ords.war` ≥ APEX** – patch APEX, ORDS and SQLcl as one set. **November: ORDS 26.3.0 → 26.3.1** |

### Content of SPB 40289362 (KA1182 option 2 = the individual patches)

From the SPB README inside the ZIP (`WLS_SPB_14.1.2.0.261112/README.html`,
dated 11-Nov-26, read 2026-11-18). Platforms: Linux x86-64, Linux ARM64,
Windows 64 (`linux64_patchlist.txt`, `windows64_patchlist.txt`,
`arm64_patchlist.txt`, `generic_patchlist.txt`, `rollback_patchlist.txt` =
the nine patch numbers below without OPatch). SPBAT only for the
distributions "WLS Generic" / "FMW Infrastructure" – our Forms & Reports
home: `opatch napply` (unchanged). Java minimum 17.0.12+ / 21.0.4+
(unchanged), OPatch 13.9.4.2.25 (unchanged).

| Patch | Content | KA1182 release | Change vs. SPB 40125898 | ARU (ZIP) |
|---|---|---|---|---|
| **40289390** | SPB marker patch (`WLS_SPB_MARKER_PATCH`, Oct: 40126042; interim 40289366) | Nov 2026 | new | 29577054 |
| **40205408** | WLS PSU **14.1.2.0.261025** (README 25-Oct-26, OPatch ≥ 13.9.4.2.18) – new: the 7 WLS CVEs + **40073770** JAX-WS feature gate (KB694158, default true); cumulative incl. .260922 (= Oct PSU 40058371) with **39924025** (CVE-2026-70748 → `WLS_SPB_CHECK_BUGS` stays) | Nov 2026 | new (Oct: 40058371) | 29534429 |
| **40288205** | FMW Third-Party BP **14.1.2.0.261111** (README 11-Nov-26, KB379953) – new: 40202517 = CVE-2026-91403 (Certifi), 40285175 (unnamed); jackson-databind 2.21.5 since .260821 | Nov 2026 | new (Oct: 40035655) | 29576292 |
| 39984190 | Coherence 14.1.2.0 Cumulative Patch 10 | Oct 2026 | – | |
| 39646824 | RDA 26.4.20261020 | Oct 2026 | – | |
| 39264447 | Database Update 23.26.2 for FMW DBCLIENT | Jul 2026 | – (no newer FMW DBCLIENT) | |
| 39487373 | JDBC 23.26.2 Bundle Patch 14.1.2.0.260603 | Jul 2026 | – | |
| 38063775 | WebLogic Samples Patch 14.1.2.0.250715 | Jul 2025 | – | |
| 28186730 | OPatch 13.9.4.2.25 | Oct 2026 | – | |
| 38391376 | RCU fix "RCU prereq steps fail while validating the DB connection" | – | – | |

Expected `napply -report` on a home with the October SPB (to be confirmed
in the live run): PSU 40205408 superset of 40058371, Third-Party BP
40288205 superset of 40035655, marker 40289390 replaces 40126042, the other
six skipped as duplicates.

### FMW DBCLIENT – known residual (state 2026-10-26)

The Oracle Home carries its own database client ("FMW DBCLIENT", 23.26.2 –
Patch 39264447, `binary_patches/dbclient/linux64/` of the SPB). The October
and the November SPB still ship the same RU (OPatch skipped it as a
duplicate) – Oracle delivers **no newer FMW DBCLIENT** in these cycles,
and KA1182 names no separate one. The DB matrix of November has no
client-only row.

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
level SPB CSPU Nov 2026 (40289362); the Jackson copies are not loaded at
runtime."

### Superseded (kept for context, not read by any script)

| Old patch | Superseded by |
|---|---|
| 40125898 | → 40289362 (WLS SPB 14.1.2.0.261112, CSPU Nov 2026); marker 40126042 → 40289390, PSU 40058371 → 40205408, Third-Party BP 40035655 → 40288205 |
| 40050062 | → 40155248 (ADF BP 14.1.2.0.261013) |
| 39979746 | → 40154045 (OPSS BP 14.1.2.0.261013) |
| 39940047 | → 40145610 (UMS BP 14.1.2.0.261012) |
| 39987730 | → 40181911 (OHS BP 14.1.2.0.261020) |
| 35702194 = 21.0.13.0.2 (fixed 40186074) | → 35702194 = 21.0.13.1 (fixed 40239626) |
| 40186686 (JRE 8u511 alert build) | → 40239650 (JRE 8u513-b04) |
| 39925660 | → 40125898 (CPU Oct 2026) → 40289362 |
| 39988381 | WLS SPU (CSPU Sep 2026), overlay on PSU 39919611, base bug 39924025 → contained in PSU 40058371 (confirmed live 2026-10-24) and in 40205408 |
| 38590500 | → 39951765 (PERL 5.42.2 Security Update) |
| 39597026 | → 39987730 → 40181911 (OHS BP) – the oldest one was never applied |
| 38566996 | → 39940047 → 40145610 (UMS Bundle Patch) |
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
FMW tables above. Installed by [`00-Setup/install_db_client_tools.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/00-Setup/install_db_client_tools.sh) and
`12-APEX-Ords/` – see the table "DB client tools, APEX, ORDS" in the patch
list.

**Coupling (APEXlang):** `ords.war` carries the APEXlang compiler of APEX
(26.3.0.272: `apexlang-compiler-26.2.0.239.jar`); APEX 26.2 requires
**ORDS 26.3.0+** and **SQLcl 26.3.0+** (APEX 26.2 installation guide).
APEX, ORDS and SQLcl are patched as **one set** in one window – details in
[ords_architecture.md §1a](../../80-FMW-Architecture/ords_architecture.md#1a-apexlang--apex-and-ords-are-coupled-since-26x).

### CVE check 2026-11-18 – CSPU November 2026 (APEX, ORDS, clients)

Source: risk matrices of the final CSPU November 2026 advisory
(`cspunov2026.html` / `cspunov2026verbose.html`) and CPU431 (DB PAD, fixed
versions). Installed on the test host (unchanged since 2026-10-23): **APEX
26.2.0** (no patch set), **ORDS 26.3.0.272.1811**, **SQLcl 26.3.0.260.1620**,
**Instant Client 23.26.4.0.0**; repository DB **19.33** (since 2026-10-28).

| CVE | Component | Remote w/o auth | CVSS 3.1 | Affected versions | Installed | Status here |
|---|---|---|---|---|---|---|
| **CVE-2026-114849 / -114850** | Oracle APEX / General | **yes** | **9.8** | 24.1.22, 24.2.21, 26.1.5, **26.2.0** | APEX 26.2.0 | **affected** – fix APEX **26.2.1** = patch set bundle **40040466** (README from the ZIP: PATCH_VERSION 1, dated 2026-10-26, `catpatch.sql` / `catpatch_con.sql` + images, CDN `https://static.oracle.com/cdn/apex/26.2.1/`) |
| **CVE-2026-114849, -114856, -114857, -114852, -114853, -114855, -114851, -114854** (+ **-127419** per CPU431) | Oracle REST Data Services / Core, General, PL/SQL Gateway | partly | **9.8** | 24.2.0–**26.3.0** | ORDS 26.3.0 | **affected** – fix **ORDS 26.3.1** (CPU431; `ords-latest.zip` of 2026-11-04 = 26.3.1). The pre-release still said "up to 26.2.3" |
| Oracle Database Server rows | RDBMS / Oracle Text / OpenSSL / … | – | – | – | SQLcl 26.3, Instant Client 23.26.4, FMW DBCLIENT 23.26.2 | **not affected** – "None of these patches are applicable to client-only installations" (DB matrix November) |

CVE-2026-114849 appears in both the APEX and the ORDS matrix – patch both
in one window (APEX patch set, then ORDS 26.3.1; the APEXlang compiler in
ORDS 26.3.1 stays ≥ APEX 26.2.1 – check with `04-` / `06-`).

Check on any system (read-only, SYS in the PDB):

```sql
select version, status from dba_registry where comp_id = 'APEX';            -- 26.2.0 → 26.2.1
select patch_number, patch_version, images_version, apexlang_version
  from apex_260200.apex_patches order by installed_on;                      -- patch sets
select version from ords_metadata.ords_version;                              -- ORDS repository
```

```bash
readlink $APEX_ORDS_BASE/ords_1/ords                     # ORDS software (ords-<ver>)
grep RELEASE $SQLCL_HOME/bin/version.txt                 # SQLcl
LD_LIBRARY_PATH=$INSTANT_CLIENT_HOME $SQLPLUS_BIN -V     # Instant Client
```

The CPU October 2026 check (APEX 26.2.0 not affected by CVE-2026-101521,
why a risk matrix lists only *supported affected* versions) is in the
[October snapshot](00-patch-references_october_2026.md#cve-check-2026-10-23--cpu-october-2026).

### APEX – patching

| | |
|---|---|
| Vehicles | **Release** (26.1 → 26.2, `apexins.sql`, new schema `APEX_<ver>`) or **patch set bundle** (26.2.0 → 26.2.x, `catpatch.sql`, same schema) |
| Source | release: `apex_26.2.zip` (OTN, no login, pinned in `APEX_ZIP_URL` with the SHA-256 of the download page since 2026-10-30; `apex-latest.zip` = newest); patch set: MOS, platform Generic **2000P** (`APEX_PATCH_NR` = role `apex` in `download/patches_fmw.csv`) – both via `09-Install/04-oracle_pre_download.sh --apply [--mos]` |
| Apply | release: `12-APEX-Ords/02-install-apex.sh --apply` (upgrade mode, ORDS stopped, DB backup); patch set: `12-APEX-Ords/03-patch-apex.sh --apply` (stops / starts ORDS, images `APEX_<ver>_p<nr>`) |
| Before | check that the ORDS of the instance carries an APEXlang compiler ≥ the new APEX (`04-` / `06-` check it) |
| Proof | `dba_registry` version + `APEX_PATCHES` (patch, images and **APEXlang** version) + `/i/apex_version.txt` through Nginx |
| Rollback | release / patch set are one-way in the DB (DB backup); images: link `apex_N` back |
| Status 2026-11-18 | **APEX 26.2.1** on the test host – patch set bundle **40040466** applied with `03-patch-apex.sh --apply` 15:42:22–15:42:46 (24 s incl. ORDS stop / start): `dba_registry` 26.2.1 VALID, APEXlang 26.2.0+3479, no invalid objects, images link `apex_1 → APEX_26.2_p40040466`. Fixes CVE-2026-114849 / -114850 (9.8). Note: `/i/apex_version.txt` still says "26.2" (the patch does not rewrite it) – prove the level with `dba_registry` / `APEX_PATCHES` |

### ORDS – patching

| | |
|---|---|
| Vehicle | every ORDS release is a **complete new installation** (no patches); quarterly + occasional fix releases (`26.3.x`) |
| Source | `ords-latest.zip` (OTN, no login) via `04-oracle_pre_download.sh --apply` (`ORDS_ZIP_URL`, version from the jar names in the ZIP) |
| Apply | `12-APEX-Ords/06-patch-ords.sh --apply` – new `ords-<ver>` beside the old one, stop, link switch, `ords install --db-only` upgrades `ORDS_METADATA` (**one-way**), start, HTTP check |
| Before | export the REST definitions (`ORDS_EXPORT` / SQLcl `rest export`) and take a DB backup – `ORDS_METADATA` has 54 of 56 FKs `ON DELETE CASCADE` |
| Rollback | `06-patch-ords.sh --rollback` = link back – only while the repository was not upgraded; after the upgrade: DB restore |
| Status 2026-11-18 | **ORDS 26.3.1.303.1615** on the test host – `06-patch-ords.sh --apply` 15:43:03–15:43:28 (25 s): `ORDS_METADATA` 26.3.0.r2721811 → 26.3.1.r3031615, HTTP 302 → landing 200, APEXlang compiler 26.2.0.239.1920. Fixes the 9 ORDS CVEs of the CSPU Nov 2026. Findings: `04-oracle_pre_download.sh` does not fetch a newer `ords-latest.zip` while an older ORDS ZIP is in the storage ("present") – downloaded by hand to `ords/26.3.1.303.1615/` (SHA-256 `9f39890c…5f4d`); `06-` asks interactively for the DB-backup confirmation (feed `y` in a non-interactive run) |

### SQLcl – patching

| | |
|---|---|
| Vehicle | standalone release (Java, quarterly, `sqlcl-latest.zip`); **not** the SQLcl inside a DB home – that one is patched by the DB RU and is the one named in the "Oracle Database Server" matrix |
| Source / apply | `00-Setup/install_db_client_tools.sh --apply` – downloads the newest ZIP to `$PATCH_STORAGE/sqlcl/<ver>/`, installs `$ORACLE_BASE/product/sqlcl_<ver>`, switches the link `sqlcl` only after the smoke test (`sql -V`) |
| Rule | SQLcl ≥ APEX (APEXlang compiler, `apex export`) – APEX 26.2 needs SQLcl 26.3.0+ |
| Rollback | `install_db_client_tools.sh --rollback` (link back), `--keep N` |
| Status 2026-11-18 | SQLcl **26.3.0.260.1620** – not in any affected range (no client-only DB row in November) |

### Instant Client – patching

| | |
|---|---|
| Vehicle | Instant Client follows the **DB release updates** (23.26.x = 26ai); the client-relevant CVEs are in the "Oracle Database Server" matrix (Oracle Net Services, "applicable to client-only installations") |
| Source / apply | versioned URL in [`oracle_software_version.conf`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/oracle_software_version.conf) (`IC_VERSION`, `IC_URL_BASE` – the "latest" link lags behind, delivered 23.26.2 on 2026-10-23 while 23.26.4 was listed); `install_db_client_tools.sh --apply` installs `instantclient_<ver>`, link switch after `sqlplus -V` |
| Rule | Instant Client ≥ the first version **after** the highest affected client row (CPU Oct 2026: > 23.26.3) |
| Rollback | `install_db_client_tools.sh --rollback`, `--keep N` |
| Status 2026-11-18 | Instant Client **23.26.4.0.0** – not affected (no client-only DB row in November) |

Not covered here: the **FMW DBCLIENT** inside the Oracle Home (23.26.2 via
the WLS SPB, Patch 39264447 – patched by `05-`; formally in the range of the
client rows above – see "FMW DBCLIENT – known residual") and the **database
server** itself (repository / APEX DB: DB RU, `60-RCU-DB-19c/`) – next
section.

## Repository database (local RCU DB, `60-RCU-DB-19c/`) – CSPU November 2026

Only when the RCU / APEX database runs on a host of this library
(`LOCAL_REP_DB=true`); a customer DB is patched by its DBA. Source: CPU431
(DB PAD, released 2026-11-17, updated 2026-11-18); READMEs read from the ZIPs
2026-11-18.

| Item | Patch / version | How it is obtained / applied |
|---|---|---|
| Base (unchanged) | DB RU 19.33 **39915792**, OJVM **39803650**, Data Pump BP **40057600** (no new 19c OJVM / DPBP in CPU431) | installed 2026-10-28 |
| **DB MRP 19.33.0.0.261117** (fixes CVE-2026-114848 Oracle Text 9.9, -64607, -77185, -77420/-421/-422, -75140, -89425, -89407, -111879) | **40196156** (Linux x86-64, `p40196156_1933000DBRU_Linux-x86-64.zip`) | decision 2026-11-18: **MRP** (Oracle's route on Linux x86-64; the "DATABASE CSPU 19.33" 40245657 has ETA 2026-11-20). README: cumulative, five one-offs (40096495, 40127726, 40130806, 40180925, 33566299 – all built on 19.33.0.0.0); `opatch napply` (offline, or `-online` for the online-capable part), then `datapatch`; DB OPatch ≥ 12.2.0.1.52. **README error:** "can only be installed to an Oracle home that has … 19.32.0.0.260721" – the inventories of all five sub-patches name 19.33.0.0.0 (template text; conflict check `opatch prereq CheckConflictAgainstOHWithDetail` decides) |
| DB home JDK → **8u513** | **40245331** (replaces 39902051 / 8u511; DB OPatch ≥ 12.2.0.1.54) | ZIP checked: `jdk/release` = 1.8.0_513-b04, ARU 29556470 |
| DB OPatch | 6880880 = 12.2.0.1.55 (unchanged) | CPU431 demands ≥ 12.2.0.1.55 for CVE-2026-89425 – fulfilled |
| CVE-2026-114819 (Oracle Text, 9.9) | – | listed for 19.32 / 19.28 only – **19.33 not affected** |
| OpenSSL CVE-2026-72897 | – | 19c: matrix 19.32–19.33, CPU431 lists the fix for 26ai only. **Checked 2026-11-18:** the DB home does not load the OS OpenSSL (no libssl / libcrypto `NEEDED`, no `dlopen`; Oracle's own crypto in `libnnz19` / `libzt*`) – `dnf update openssl` keeps the **OS** current (Nginx, curl; test host: openssl 3.5.8-2.0.1, no update pending) but does not fix the DB. No 19c vehicle named yet → open (next MRP / RU); not reachable without a TCPS listener (test host: TCP only) |
| datapatch / move of the instance | – | in-place `opatch napply` of the MRP on the 19.33 home (it is an overlay, not a new RU) – the out-of-place route of `09-db_patch_rcu.sh` is for RU changes; how the lib applies an MRP is part of the switch (`update_plan.md`) |
| Standalone CVU (host pre-check) | **30839369** (`DB_CVU_PATCH_NR`, 26ai kit) | `04-oracle_pre_download.sh --mos`, [`60-RCU-DB-19c/00b-db_cvu_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/00b-db_cvu_check.sh) |
| AHF / TFA | AHF 26.11 (16 CVEs, CPU431) | only if AHF is installed on the DB host – the library does not install it |

Status: test host on **19.33 + MRP 19.33.0.0.261117 + DB home JDK 8u513**
– applied in-place 2026-11-18 (MRP ~9 min, JDK ~3 min, `datapatch` without
work – the MRP one-offs are binary-only; downtime ~17 min incl. domain
stop / start; details: README of the cycle folder, section 3b). Background (who uses which schema, why the
DB version matters):
[rcu_middleware_architecture.md](../../80-FMW-Architecture/rcu_middleware_architecture.md);
the RU change of October: [09-db_patch_rcu.md](../../60-RCU-DB-19c/docs/09-db_patch_rcu.md).
