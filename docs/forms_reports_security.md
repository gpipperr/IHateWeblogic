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

**Current cycle: CSPU November 2026 (2026-11-17)** – state 2026-11-18,
applied on the test host (FMW home, repository DB MRP, APEX 26.2.1, ORDS
26.3.1).

| | |
|---|---|
| Current patch list (14.1.2) | [`09-Install/docs/00-patch-references.md`](../09-Install/docs/00-patch-references.md) – patch numbers from MOS KA1182 + CPU450 / CPU435 / CPU431, CVE check, "What a home needs – CPU vs. CSPU", "How to read KA1182", MOS Doc-ID table |
| Earlier cycles | frozen snapshots, one per cycle, for rolling back by hand – table "Patch cycle history" in the same file ([CPU October 2026](../09-Install/docs/00-patch-references_october_2026.md), [CSPU September 2026](../09-Install/docs/00-patch-references_september_2026.md)) |
| Scripts / [`oracle_software_version.conf`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/oracle_software_version.conf) | **CSPU November 2026** – switched 2026-11-18 (release `v1.0.202611`, procedure [update_lib_to_act_cpu.md](update_lib_to_act_cpu.md)) |
| DB client tools, APEX, ORDS | own release cycles beside the FMW patches: Instant Client 23.26.x (DB RU), SQLcl / ORDS / APEX (OTN releases, APEX patch set bundles via MOS) – update = run [`00-Setup/install_db_client_tools.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/00-Setup/install_db_client_tools.sh) / `04-` again, see "DB client tools, APEX, ORDS" in the patch list |
| Forms & Reports 14.1.2 – manual guides per cycle | [`70-Customer-Projects/FormsReports14_patch_cspu_2026-11/`](../70-Customer-Projects/FormsReports14_patch_cspu_2026-11/README.md) – analysis (README facts from the ZIPs, live run 2026-11-18) + guide **full** (any older level) and **cumulative from CPU Oct 2026** – the master for the scripts |
| Forms & Reports 12.2.1.19 (customer homes) | manual analysis: [`70-Customer-Projects/FormsReports12_patch_cspu_2026-11/`](../70-Customer-Projects/FormsReports12_patch_cspu_2026-11/README.md) |

What matters in this cycle:

- **One run, not "CPU + CSPU":** KA1182 is cumulative – the November list
  contains the October CPU patches; a never patched home needs one run.
  Two layers only for the repository DB (RU 19.33 of the CPU + MRP of the
  month) and APEX (release + patch set bundle).
- **WebLogic** – 7 CVEs up to **10.0** (TopLink, T3/IIOP, SOAP, HTTP) → SPB
  **40289362** (PSU 40205408). The PSU switches a new gate **on by default**:
  `JAXWSRejectUnknownSEIOperationsEnabled` (KB694158) – no impact on Forms /
  Reports / EM on the test host.
- **FMW infrastructure** – OPSS **10.0** (40154045), UMS **9.8** (40145610,
  matrix name "Service Delivery Platform"), ADF (40155248), OHS / proxy
  plug-in curl (40181911), Certifi (Third-Party BP in the SPB).
- **Java** – 11 CVEs incl. **Java4Shell** (CVE-2026-114938, Base64 intrinsic,
  only on AVX-512 VBMI CPUs) → JDK **21.0.13.1** (also closes the eMudhra
  alert CVE-2026-114820); Forms clients: client bundle 21.0.13.1 / JRE 8
  **8u513**. Details: [00-patch-references.md – Java4Shell](../09-Install/docs/00-patch-references.md#java4shell--cve-2026-114938-state-2026-11-18).
- **FMW-bundled JDK** `oracle_common/jdk` 17.0.12 (Reports engines): still
  no patch – in the Java4Shell range; on AVX-512 VBMI hosts mitigate with
  `-XX:-UseBASE64Intrinsics`; SR open.
- **Repository DB 19.33** – Oracle Text CVE-2026-114848 (9.9) → MRP
  **40196156** (in-place) + DB home JDK 8u513; OpenSSL CVE-2026-72897 has no
  19c fix yet and does **not** depend on the OS `openssl` package (not
  reachable without TCPS).
- **APEX 26.2.0 / ORDS 26.3.0** – CVE-2026-114849 (9.8) and more → APEX
  **26.2.1** (patch set bundle 40040466) + ORDS **26.3.1**, one window.
- **FMW DBCLIENT** 23.26.2 inside the Oracle Home: unchanged in the November
  SPB; no client-only DB row in November – see "FMW DBCLIENT – known
  residual" in [`00-patch-references.md`](../09-Install/docs/00-patch-references.md).
- Oracle publishes no CVE → patch mapping: we prove the **patch level**
  ("installed ≥ patch document"), not the fix of a single CVE.
