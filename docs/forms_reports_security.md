---
title: "Oracle Forms & Reports 14c Security and Patch Status"
description: "Security and patch status of Oracle Forms & Reports 14.1.2: the current Oracle patch cycle, where the patch list lives, CVE check and the hardening documents."
---

# Forms & Reports – Security & Patch Status

← Back to the [root README](../README.md)

## Security & Patch Status

> **Oracle now ships security fixes every month** (quarterly CPU, CSPU in
> the other months, Security Alerts in between). Check the current cycle
> **before every installation and every patch run**.

**Current cycle: CPU October 2026 (2026-10-20) + Security Alert
CVE-2026-91403 (Java SE JSSE, CVSS 9.1, 2026-10-21)** – state 2026-10-26.

| | |
|---|---|
| Current patch list (14.1.2) | [`09-Install/docs/00-patch-references.md`](../09-Install/docs/00-patch-references.md) – patch numbers from MOS KA1182 + CPU426, CVE check, "How to read KA1182", MOS Doc-ID table |
| Earlier cycles | frozen snapshots, one per cycle, for rolling back by hand – table "Patch cycle history" in the same file (first: [CSPU September 2026](../09-Install/docs/00-patch-references_september_2026.md)) |
| Scripts / [`oracle_software_version.conf`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/oracle_software_version.conf) | **CPU October 2026** – switched and applied on the test host 2026-10-24 (smoke test OK, runtimes in the 14c folder) |
| DB client tools, APEX, ORDS | own release cycles beside the FMW patches: Instant Client 23.26.x (DB RU), SQLcl / ORDS / APEX (OTN releases, APEX patch set bundles via MOS) – update = run [`00-Setup/install_db_client_tools.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/00-Setup/install_db_client_tools.sh) / `04-` again, see "DB client tools, APEX, ORDS" in the patch list |
| Forms & Reports 14.1.2 – manual guide per cycle | [`70-Customer-Projects/FormsReports14_patch_cpu_2026-10/`](../70-Customer-Projects/FormsReports14_patch_cpu_2026-10/README.md) – analysis (facts of all 17 patch READMEs) + step-by-step guide of the CPU Oct 2026 set – the master for the scripts |
| Forms & Reports 12.2.1.19 (customer homes) | manual analysis: [`70-Customer-Projects/FormsReports12_patch_cpu_2026-10/`](../70-Customer-Projects/FormsReports12_patch_cpu_2026-10/README.md) |

What matters in this cycle:

- **WebLogic Core** CVE-2026-83399 (T3/IIOP) and CVE-2026-91323 (HTTP), Perl,
  Apache Mina – all CVSS 9.8 → WLS SPB **40125898**, PERL **39951765**.
- **Correction:** every FMW 14.1.2 home also needs the **eight FMW
  Infrastructure bundle patches** (ADF, WebCenter Core, OWSM, FMW Control,
  OAMCLIENT, UMS, OPSS, LibOVD) – they are not in the WLS SPB and were
  missing in our September set.
- **Java – target is the alert release, not the CPU release:** JDK 21
  **21.0.13.0.2** (21.0.13 of the CPU is itself affected); Forms clients
  JRE 8 **1.8.0_511-b26** (Patch 40186686; b25 = CPU build, affected). The
  Forms client is a JSSE TLS client – the client JREs are the most
  important measure:
  [threat model](../80-FMW-Architecture/forms_runtime_architecture.md#12-threat-model-of-a-client-side-tls-jsse-flaw).
- **FMW-bundled JDK** `oracle_common/jdk` 17.0.12: no patch in KA1182 –
  open; the "alternative JAVA_HOME" fix of the Reports QPR (Bug 37866660) is
  no way out (tools only, not certified for the engines) → SR.
- **FMW DBCLIENT** 23.26.2 inside the Oracle Home (only updated through the
  WLS SPB) is formally in the range of CVE-2026-101510 / -54399 (CVSS ≤ 4.4);
  `jackson-databind` 2.16.1 in `jlib/` / `sqlcl/lib/` is not loaded – assessment
  and scanner answer in [`00-patch-references.md`](../09-Install/docs/00-patch-references.md) ("FMW DBCLIENT – known
  residual"), question added to the SR draft.
- **Security Alert CVE-2026-114820** (2026-10-24, Java, eMudhra CA incident:
  intermediate CAs with 8-bit keys) + OS `ca-certificates` (ELSA-2026-88459):
  OS updated on the test host; JDK 21.0.13.0.2 already blocks the compromised
  intermediates (next build removes the roots); the **bundled JDK 17.0.12
  trusts them** (live-tested) – no mitigation inside it, argument for the SR.
  Details: [00-patch-references.md – eMudhra](../09-Install/docs/00-patch-references.md#emudhra-ca-incident--cve-2026-114820-state-2026-10-26).
- Oracle publishes no CVE → patch mapping: we prove the **patch level**
  ("installed ≥ patch document"), not the fix of a single CVE.
