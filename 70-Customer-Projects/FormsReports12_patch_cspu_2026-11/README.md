---
nav_title: "F&R 12 – CSPU Nov 2026"
title: "Oracle Forms & Reports 12.2.1.19 – CSPU November 2026 Patch Analysis"
description: "CSPU November 2026 for an Oracle Forms & Reports 12.2.1.19 home: delta to CPU October 2026, cumulative patch list, order and a German cookbook to apply by hand."
permalink: /70-Customer-Projects/FormsReports12_patch_cspu_2026-11/
---

# Patch Analysis – Oracle Forms & Reports 12.2.1.19 – CSPU November 2026

Patch analysis for an existing customer installation of **Oracle Forms &
Reports 12.2.1.19** (FMW Infrastructure / WebLogic Server 12.2.1.4) for the
cycle **CSPU November 2026** (Critical Security Patch Update, released
2026-11-17). A reference for applying the patches **by hand** – nothing
here depends on the IHateWeblogic scripts. Same structure as the previous
cycle [FormsReports12_patch_cpu_2026-10](../FormsReports12_patch_cpu_2026-10/README.md)
(frozen); the customer inventory of section 1a lives there.

| | |
|---|---|
| Sources | MOS KA1182 "CPU Patch Advisor for Oracle Fusion Middleware – LATEST for NOVEMBER 2026" (tabs Forms and Reports 12.2.1.19, FMW Infrastructure 12.2.1.4, WebLogic Server 12.2.1.4, Oracle HTTP Server 12.2.1.4), MOS CPU450 (FMW CSPU Nov 2026 Patch Availability Document – patch → CVE), MOS CPU435 (Java SE CSPU Nov 2026), KB694158 (PDF F41372-26, Nov 2026), KB187736, public advisory [CSPU Nov 2026](https://www.oracle.com/security-alerts/cspunov2026.html) |
| State | KA1182 updated 2026-11-17; READMEs of the new patches read 2026-11-18 |
| Previous cycle | [FormsReports12_patch_cpu_2026-10](../FormsReports12_patch_cpu_2026-10/README.md) – CPU October 2026, customer inventory (1a), open points |
| Counterpart for 14.1.2 | [09-Install/docs/00-patch-references.md](../../09-Install/docs/00-patch-references.md) (our own 14.1.2 stack) |

**Cookbooks for the patch run (German, plain text)** – two documents:

| Cookbook | For | Steps |
|---|---|---|
| [Patch_Kochbuch_CSPU_Nov2026_full_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/FormsReports12_patch_cspu_2026-11/Patch_Kochbuch_CSPU_Nov2026_full_de.txt) | **way A – full run**: home not on the CPU October 2026 state (up to a never patched home) | 0–12, all patches of section 3 |
| [Patch_Kochbuch_CSPU_Nov2026_kumulativ_auf_cpu102026_de.txt](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/FormsReports12_patch_cspu_2026-11/Patch_Kochbuch_CSPU_Nov2026_kumulativ_auf_cpu102026_de.txt) | **way B – on top of CPU October 2026**: October cookbook applied (customer 2026-10-29) | 0–11, only the six new patches + client JRE; step 0.2 checks the October state first |

Both use the same full download list (section 3) – on a home patched in
October the ZIPs of the unchanged patches are already there.

Patch numbers change every month – before applying, compare against the
current KA1182 ("patched before?" → apply what is newer than the last
applied CPU/CSPU release).

---

## 0. What is new against CPU October 2026

| Area | CPU Oct 2026 | **CSPU Nov 2026** | Why (CPU450 / READMEs) |
|---|---|---|---|
| Java SE 8 server | 8u511 alert build 40186682 (≥ b26) | **8u513** – KA1182: 18143322 "JDK 8 latest"; fixed patch 40239638 (CPU435) | Java CSPU Nov (8u511-b33 affected) + closes the eMudhra alert CVE-2026-114820 (8u511-b32 affected) |
| WLS SPB | 40129641 (.261007) | **40213323 (.261027)** – only the PSU and the marker changed | – |
| WLS PSU (in SPB) | 40069416 (.260924) | **40205342 (.261025)** | CVE-2026-91569 (10.0), 91570 / 91583 / 91456 / 91470 / 91585 (9.8), 91469 (9.4), 91416 (5.9) + JAX-WS gate (3.2c) |
| ADF BP | 40050071 (.260920) | **40081766 (.260927)** (+ 34809489 unchanged) | CVE-2026-91618 (9.1); 91544 / 91619 / 91670 of CPU450 already in the October BP |
| OPSS BP | 39979941 (.260904) | **40154178 (.261013)** | CVE-2026-114824 (10.0), 91548 (8.6), 91551 (7.5), 91560 (6.5) |
| UMS BP (12.2.1.3) | 39939504 (.260827) | **40132160 (12.2.1.3.261008)** | CVE-2026-91558 (8.3), 91556 |
| OHS DB19c BP | 40005842 (.260910) | **40176880 (.261019)** | CVE-2026-9545 (curl, 7.5) |
| Client JRE 8 | 40186686 (8u511 alert build) | **40239650 (JRE 8u513)** | as the server JDK |
| Everything else | | unchanged | OPatch .25, Coherence CP33, Third-Party BP 39988961 (no Nov TPP for 12c), RDA, OSS, JDBC, Samples, Cloning, ADR, FMW Platform, WebCenter Core, OWSM, FMW Control, OAMCLIENT, LibOVD, DB client 19.31, PERL, Forms / Reports QPR, WebGate, LIBDMS2 / LIBIAU |

A home on the **October state** needs exactly the six new patches plus the
client JRE (cookbook way B). A home that was **not** patched in October gets
the full cumulative list of section 3 (way A) – the October cookbook is not
needed any more.

Oracle Forms and Oracle Reports themselves have **no** row in the CSPU
November 2026.

---

## 1. Check the installation first

Run as the software owner, `ORACLE_HOME` = the Forms & Reports home.

```bash
# Distribution(s) installed in the home – names the KA1182 tab to follow
$ORACLE_HOME/oui/bin/viewInventory.sh | grep -i distribution

# Installed patches (compare with the tables below)
$ORACLE_HOME/OPatch/opatch version
$ORACLE_HOME/OPatch/opatch lspatches

# Components: is OHS / WebGate / Forms / Reports really in the home?
$ORACLE_HOME/OPatch/opatch lsinventory -details | grep -iE 'ohs|webgate|forms|reports|sqldeveloper'

# Java used by WebLogic (server side)
$JAVA_HOME/bin/java -version
```

Also check:

- **Repository database:** FMW CPUs contain the fix for CVE-2021-2351
  (Native Network Encryption). The database of the RCU schemas (and every
  application database the Forms/Reports sessions connect to) must be on
  July 2021 or later – [KB118538](https://support.oracle.com/support/?documentId=KB118538):
  - Since July 2021 the DB `sqlnet.ora` knows `SQLNET.ALLOW_WEAK_CRYPTO_CLIENTS`,
    the client `sqlnet.ora` `SQLNET.ALLOW_WEAK_CRYPTO` (both default `TRUE`).
    `FALSE` removes DES, 3DES, RC4 and MD5 and **blocks unpatched clients**
    (`ORA-12269`). The FMW homes are patched clients: OCI via the FMW DB
    client (3.4), JDBC thin via the JDBC bundle patch (3.2).
  - JDBC thin ignores `sqlnet.ora`; its switch is the connection property
    `oracle.net.allow_weak_crypto` (default `true`). `ORA-12268` after the
    patch means the **database server** is not patched.
  - Only relevant if NNE is used (`SQLNET.ENCRYPTION_SERVER=REQUESTED|REQUIRED`).
    Which ciphers the sessions really use – before switching to `FALSE`:

    ```sql
    SELECT s.username, s.program, ci.network_service_banner
      FROM v$session_connect_info ci JOIN v$session s ON s.sid = ci.sid
     WHERE ci.network_service_banner LIKE '%Encryption%'
        OR ci.network_service_banner LIKE '%Crypto-checksumming%';
    ```

    No DES/3DES/RC4 and no MD5 in the result → the DB can be set to
    `SQLNET.ALLOW_WEAK_CRYPTO_CLIENTS=FALSE` (Oracle's recommendation).
- **Client PCs:** `java -version` on a few Forms clients (Java Web Start /
  FSAL), see section 5.

Result of the check → fill in section 7 (open points).

All of this in one run: [../tools/bash/collect_fmw_env.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/tools/bash/collect_fmw_env.sh) –
standalone, read-only, secrets masked, result `/tmp/fmw_collect_<host>_<ts>.tar.gz`
(shared collector for 12c and 14c, see [../tools/README.md](../tools/README.md)).

For the later **migration to 14c** the customer configuration (formsweb.cfg
sections, env files, cgicmd.dat keys, Reports servers, uifont.ali, custom
fonts, customer jars, source paths + dependencies – no module files) is
exported with
[../tools/bash/export_forms_reports_conf.sh](../tools/README.md#export_forms_reports_confsh)
– encrypted archive, never into git.

### 1a. Inventory of the customer home

Unchanged since the collector run of **2026-10-23** – see
[section 1a of the October analysis](../FormsReports12_patch_cpu_2026-10/README.md#1a-inventory-of-the-customer-home-received-2026-10-23)
(test machine, home `/oracle/product/mw`, OPatch 13.9.4.2.11, practically
unpatched, OHS `ohs1` configured but not running, Reports running, glibc
2.28, server JDK 8u411 as a real directory, bundled `oracle_common/jdk`
8u341). Whether the October cookbook was applied in the meantime decides
cookbook way A or B – compare `opatch lspatches` with section 0.


---

## 2. Support status 12.2.1.x

| Fact (KA1182 introduction) | Consequence |
|---|---|
| Forms & Reports 12.2.1.4 has received no patches since July 2024 – only **12.2.1.19** is patched | the customer is on 12.2.1.19 – OK |
| Premier Support for 12.2.x ends **December 2026** | after that, patches can only be downloaded with an **Extended Support** contract – check the contract |
| Final CPU/CSPU for 12.2.1.4 (incl. 12.2.1.19): **December 2027** | plan the upgrade to 14.1.2 (final CPU December 2032) in 2027 – target architecture: [09-Install](../../09-Install/README.md) |

---

## 3. Patch list – Forms & Reports 12.2.1.19 home (KA1182, November 2026)

Apply in this order, with **all** Forms/Reports/WebLogic processes stopped
(Node Manager, AdminServer, managed servers, OHS if colocated). Back up the
Oracle Home and the inventory before (`tar` of `ORACLE_HOME` and
`oraInventory`) – rollback per patch with `opatch rollback -id <nr>`.

"KA1182 release" = the CPU/CSPU in which Oracle listed the patch; a patch
of an older release is still required if it is not installed yet.

**Download in one run:** all ZIPs of 3.1–3.5 (incl. the OHS set) are listed
in [patches_cspu_forms_reports_12c_nov2026.csv](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/FormsReports12_patch_cspu_2026-11/patches_cspu_forms_reports_12c_nov2026.csv) (rows new since October marked `[delta]`) (patch, MOS platform,
file, required, cookbook step) –
[tools/bash/mos_patch_download.sh](../tools/README.md#mos_patch_downloadsh) loads
them with getMOSPatch, checks every ZIP and writes the SHA-256 list
(standalone, no IHateWeblogic library on the customer host).

### 3.1 Java SE on the server (JDK 8)

| Patch | Description | KA1182 release | Note |
|---|---|---|---|
| 18143322 | Java SE 8 Update 513 or later ("JDK 8 latest") | Nov 2026 | what KA1182 demands; the ZIP name never changes – check the version inside |
| **40239638** | JDK 8 Update 513 (CPU435, Java CSPU Nov 2026) | Nov 2026 | fixed to 8u513 – take it if 18143322 still shows 8u511 |

8u513 (security baseline `1.8.0_513-b04`) is cumulative: Java CSPU November
(Java 8 affected up to 8u511-b33), the October alert CVE-2026-91403 and the
**eMudhra alert CVE-2026-114820** (affected 8u511-b32 – the October target
build) – Oracle removed the eMudhra roots from `cacerts`. Proof:
`<jdk>/bin/java -version` → `1.8.0_513`, or `grep JAVA_RUNTIME_VERSION
<jdk>/release`. Install procedure unchanged (KB175049, link switch of
`/oracle/java/jdk`, cookbook step 4); licence exception MOS Doc ID 1557737.1.
The bundled `oracle_common/jdk` (8u341, Reports engines) still has no FMW
patch in KA1182 (open point 14).

**Java4Shell** (CVE-2026-114938, Base64 intrinsic on AVX-512 VBMI CPUs, in
the news 2026-11-17/18) concerns Java 17 / 21 / 25 / 27 and for Java 8
**only the `8u511b33-perf` build** – the server JDK, the bundled 8u341 and
the client JRE 8 of a 12.2.1.19 home are **not** affected by it (the other
Java 8 CVEs of November are the reason for 8u513). Details:
[00-patch-references.md – Java4Shell](../../09-Install/docs/00-patch-references.md#java4shell--cve-2026-114938-state-2026-11-18).

Java 8 security files are in `jre/lib/security/`; the block list is called
**`blacklisted.certs`** there (the name `blocked.certs` belongs to newer
JDKs) – corrected in step 4.8 of both November cookbooks on 2026-11-18
(checked against JDK 8u513: 0 emSign entries in `cacerts`, 87 entries in
`blacklisted.certs`). The frozen October cookbook still says `blocked.certs`
in its eMudhra check – use `blacklisted.certs`.

### 3.2 OPatch and WebLogic Server 12.2.1.4

| Patch | Description | KA1182 release | Note |
|---|---|---|---|
| 28186730 | OPatch **13.9.4.2.25** | Oct 2026 | upgrade OPatch first |
| **40213323** | WLS Stack Patch Bundle 12.2.1.4.261027 | Nov 2026 | **option 1** – contains all patches of the next table |

Option 2 instead of the SPB – the individual patches:

| Patch | Description | KA1182 release |
|---|---|---|
| **40205342** | WLS PSU 12.2.1.4.261025 – post-install steps KB694158 (JAX-WS gate, 3.2c) | Nov 2026 |
| 39984205 | Coherence 12.2.1.4 Cumulative Patch 33 | Oct 2026 |
| 39646867 | RDA 26.4.20261020 for FMW 12.2.1.4 | Oct 2026 |
| 39988961 | FMW Third-Party BP 12.2.1.4.260907 (KB379953) | Oct 2026 |
| 39567777 | OSS 19c BP 12.2.1.4.260616 | Jul 2026 |
| 39487427 | JDBC 19.31 Bundle Patch 12.2.1.4.260603 – first JDBC BP in this home? Roll back older JDBC patches first (KB153375) | Jul 2026 |
| 36426672 | WebLogic Samples SPU 12.2.1.4.240416 (only if samples are installed – OPatch checks) | Apr 2025 |
| 37056593 | Cloning SPU for WLS/FMW 12.2.1.4.0 | Oct 2024 |
| 35965629 | ADR SPU for WebLogic Server 12.2.1.4.0 (size optimized, KB496228 / KB537876) | Oct 2023 |
| 36789759 (or minimum 33093748) | FMW Platform BP 12.2.1.4.240812 (latest recommended) / FMW Platform SPU (minimum) | Apr 2021 |

#### 3.2a From the SPB README (40213323, dated 27-Oct-26, read 2026-11-18)

| Topic | README says | For the patch run |
|---|---|---|
| Content | 12 entries: marker **40213450** / interim 40213328 (SPB in `lsinventory`; Oct: 40129643), ADR 35965629, **WLS PSU 40205342**, Samples SPU 36426672, Coherence CP33 39984205 (`lspatches` shows **1221426**), FMW Platform BP 36789759, Third-Party BP 39988961, OPatch 28186730 (13.9.4.2.25), JDBC 19.31 BP 39487427, RDA 39646867, OSS 19c BP 39567777, Cloning SPU 37056593 | against October **only the PSU and the marker changed** – the Third-Party BP stays 39988961 (CPU450 has no 12.2.1.4 TPP for November) |
| SPBAT or `napply` | unchanged: SPBAT only for homes from the FMW Infrastructure or standalone WLS distribution | customer home = Forms & Reports installer → **`opatch napply`** |
| Staging | ZIP `p40213323_122140_Generic.zip` (1.0 GB), unpack outside the Oracle Home with `unzip`, ≥ 4 GB free; result `WLS_SPB_12.2.1.4.261027/` | |
| Java | minimum JDK 1.8.0_211 (JEP 290, KB159467) | we install 8u513 before (3.1) |
| OPatch | PSU needs ≥ 13.9.4.2.13; roll back 23335292 **before** the OPatch upgrade (unchanged) | way B: OPatch is already .25 |
| `napply` | roll back 32720458 if present; in `binary_patches/`: `opatch napply -report … -phBaseFile linux64_patchlist.txt`, then without `-report` | way B: the report shows 40205342 as superset of 40069416 – OPatch rolls the October PSU back itself |
| Post-install | `opatch lspatches`; KB694158 (PDF Nov 2026); start the servers | |
| Rollback | `opatch nrollback -oh $ORACLE_HOME -idFile rollback_patchlist.txt` (unchanged) | |

#### 3.2b From the OPatch README (28186730, OPatch 13.9.4.2.25, read 2026-10-23 – unchanged)

| Topic | README says | For the patch run |
|---|---|---|
| Rollback | "no mechanism to revert OPatch to an older version" – only restore of `ORACLE_HOME` + central inventory | backup **before** the OPatch upgrade |
| Before | all processes using files of the Oracle Home stopped; Patch **23335292** rolled back first (`opatch rollback -id 23335292`), then wait 15–30 s; never roll it back after the upgrade | |
| Install | unzip into a staging directory (→ `6880880/`), run with a **JDK** in `PATH`: `java -jar <stage>/6880880/opatch_generic.jar -silent oracle_home=$ORACLE_HOME` | custom inventory: `-invPtrLoc <path>/oraInst.loc`; `/tmp` with `noexec`: `java -Djava.io.tmpdir=<dir> -jar …` |
| Logs | success: `<central inventory>/logs`; failure: `/tmp/OraInstall<timestamp>`; problems: KB310962 | |
| Check | `$ORACLE_HOME/OPatch/opatch version` → 13.9.4.2.25, `opatch lsinventory` | |
| NGINST patches | 31101362, 29137924, 29909359 are contained – do **not** apply them after the upgrade (error); if already in the inventory: harmless, cannot be rolled back | |
| New in .25 | Bug 39905069 "prompt user when patch contains security fixes not enabled by default", Bug 39932917 new `opatch util` option to query such fixes | `napply` with `-silent` in the cookbook; after the run query disabled security fixes (`opatch util -help`) |
| CVEs fixed | Bug 40012934: **CVE-2026-91776** (NextGen OUI, jackson-databind – CPU Oct 2026 row), plus CVE-2026-19032, -59650, -54428 | confirms the OPatch vehicle for CVE-2026-91776 (CPU Oct 2026, section 4 of the October analysis); the other OUI rows (CVE-2026-8763, -101520, -59889) are not named – still assumption |

#### 3.2c PSU 40205342 and the new JAX-WS gate (KB694158, Nov 2026)

| Topic | Source | For the patch run |
|---|---|---|
| CVEs | PSU README (25-Oct-26) = CPU450: CVE-2026-91585, -91583, -91570, -91569 (TopLink), -91470 (T3/IIOP), -91469 (HTTP), -91456 (SOAP), **-91416** (HTTP, 12.2.1.4 only) – **confirmed** | |
| New gate | Bug 40073770 → `FeatureCompatibilityMBean.JAXWSRejectUnknownSEIOperationsEnabled`: JAX-WS endpoints with a Service Endpoint Interface answer SOAP requests for unknown operations with a SOAP fault before WorkContext processing | **default `true`** – unlike all gates of July to September (default `false`); dynamic, no restart |
| Impact | Forms / Reports do not call unknown SOAP operations; EM / OWSM internals unknown | smoke test incl. EM login, check the server logs (cookbook 10.8); set `false` only if a legitimate SOAP client fails |
| Older gates | Jul / Aug / Sep 2026 (`WorkContextClassValidationEnabled`, JNDI allow lists, `T3RouteOnlyToTrustedServersEnabled`, ojdl / DMS properties) – all default `false` | candidates for a later hardening pass, not part of this run |

### 3.3 FMW Infrastructure 12.2.1.4 bundle patches

KA1182: "if only applying the WebLogic Server SPB or individual patches …
apply the additional patches" – **none of them is in the WLS SPB**. The
components come with every FMW infrastructure (also with Forms & Reports).

| Patch | Description | KA1182 release | Note |
|---|---|---|---|
| **40081766** | ADF Bundle Patch 12.2.1.4.260927 | Nov 2026 | together with 34809489 |
| 34809489 | Fix for CVE-2021-42575 | Jul 2023 | required with any ADF bundle patch, if not yet applied |
| 40022647 | WebCenter Core BP 12.2.1.4.260914 | Oct 2026 | installed even without WebCenter products; CPU450 maps 5 November CVEs (WebCenter Portal Composer 91525 / 91529 / 91567 / 91586 / 91587) to this patch – covered by the October patch |
| 40047683 | OWSM Bundle Patch 12.2.1.4.260918 | Oct 2026 | includes the fix of Security Alert CVE-2026-21992 (Mar 2026) – confirmed by the README (BP 260304) |
| 39995014 | FMW Control BP 12.2.1.4.260908 | Oct 2026 | Enterprise Manager on the AdminServer |
| 40059055 | OAMCLIENT Bundle Patch 12.2.1.4.260922 | Oct 2026 | |
| **40154178** | OPSS Bundle Patch 12.2.1.4.261013 | Nov 2026 | |
| **40132160** | UMS Bundle Patch 12.2.1.3.261008 | Nov 2026 | UMS 12.2.1.3 is installed in a 12.2.1.4 home |
| 39726402 | LibOVD Bundle Patch 12.2.1.4 | Aug 2026 | replaces Patch 34065178 (needed after JDK 8u331); required on all installations except WLS standalone |

#### 3.3a From the bundle READMEs (new ones read 2026-11-18, the others 2026-10-23)

| Patch | Method | Before | Post-install | Rollback | Notes |
|---|---|---|---|---|---|
| **40081766** ADF BP 12.2.1.4.260927 (29-Oct-26) | in the unpacked `40081766/`: `opatch apply` (single patch, **not** `napply`) | all processes of the Oracle Home stopped, the installation owner, `ORACLE_HOME` + `PATH=$ORACLE_HOME/OPatch:$PATH`; backup `DOMAIN_HOME` / `ORACLE_HOME` / inventory; OPatch 13.9.4.2.x | `opatch lspatches` (`jdev -clean` only for a JDeveloper home – not here) | `opatch rollback -id 40081766`, then **empty the server `tmp` directories** of the domain (`$DOMAIN_HOME/servers/*/tmp/*`) | Generic, 72.7 MB. New in .260927: **CVE-2026-91618** (Security Framework, 9.1, Bug 39326348) and 38307118 (af:tree indentation after 38015786). CPU450 maps 91544 / 91618 / 91619 / 91670 to this patch – 91619 / 91670 are already in BP .260920 (the October 40050071), 91544 in .260721. Cumulative back to 200129; the October CVEs (91317 … 91322, 87334) stay covered. Supersedes 40050071 (way B: subset in the prereq). The README does not mention 34809489 – KA1182 still requires it with any ADF BP |
| **34809489** interim patch (17-Nov-2022) | `34809489/`: `opatch apply` | as above; check conflicts first: `opatch prereq CheckConflictAgainstOHWithDetail -ph ./` – if OPatch asks "patch(es) … will be rolled back … proceed? [y\|n]" answer **`n`** and request a merge patch from Oracle Support | none | `opatch rollback -id 34809489`, then empty the server `tmp` directories | bug title "PATCH CONFLICT OBSERVED BETWEEN 34647149 AND 34604561" – KA1182 lists it as "Fix for CVE-2021-42575" with any ADF BP (assumption: the conflict resolver of the ADF chain); apply it **after** 40050071. The README's `opatch lsinventory -jre $ORACLE_HOME/oracle_common/jdk/jre` is generic text – OPatch uses the JDK of `.globalEnv.properties` |
| **40022647** WebCenter Core BP 12.2.1.4.260914 (14-Sep-26) | `40022647/`: `opatch apply` | **OPatch ≥ 13.9.4.2.17**; all processes stopped; pre-install steps: MOS 2662881.1 "Pre-Installation Instructions for WebCenter Portal 12.2.1.4 Bundle Patches" | `opatch lspatches`; post-install: MOS 2658914.1 (WebCenter **Portal**) | `opatch rollback -id 40022647`, reverse the post-install changes | the two notes are for a WebCenter **Portal** domain – a Forms & Reports home only carries the `wccore` libraries of the infrastructure, so they most likely do not apply (**assumption** – read both notes once before the window). Cumulative back to 200302; fixes WebCenter CVEs (2026-83039/-83040/-83041/-83043, -73948 … -73963, -60728 … -60733) that were not in the October matrix; CPU450 maps the 5 November WebCenter Portal Composer CVEs (section 4) to this same BP; required by KA1182 because the component is in every FMW infrastructure home |
| **40047683** OWSM BP 12.2.1.4.260918 (19-Sep-26) | `40047683/`: `opatch apply` | **OPatch ≥ 13.9.4.2.17**; all processes stopped. The additional patches of the README (38009014 OINAV, 39099526 OIM BP) are for **IDM** products only – not needed here | `opatch lspatches`, start – **no repository / MDS step** | `opatch rollback -id 40047683` | cumulative back to 210520. **Confirmed:** CVE-2026-21992 (Security Alert March 2026) in BP 260304; further CVE-2026-83334 / -83265 (260818), -71093 / -70924 / -61001 / -60737 (260707); the newest level 260918 has only bug fixes |
| **39995014** FMW Control BP 12.2.1.4.260908 (08-Sep-26) | `39995014/`: `opatch apply` | OPatch ≥ 13.9.4.2.13; all processes stopped | `opatch lspatches`, start – no further step | `opatch rollback -id 39995014` | cumulative back to 240814. **Confirmed:** CVE-2026-91467 (CPU Oct 2026) in BP 260908; also CVE-2026-83346 / -83069 (260803) |
| **40059055** OAMCLIENT BP 12.2.1.4.260922 (22-Sep-26) | `40059055/`: `opatch apply` | **OPatch ≥ 13.9.4.2.17**; all processes stopped | `opatch lspatches`, start – no further step | `opatch rollback -id 40059055` | product "Oracle Access Manager" = the OAM **client** libraries of the infrastructure (not the OAM server); fixes CVE-2026-83409 / -83407 (260922), -73958 / -73947 (260819) – OAM rows of earlier advisories; the November OAM rows concern the OAM server, not this client BP |
| **40154178** OPSS BP 12.2.1.4.261013 (13-Oct-26) | `40154178/`: `opatch apply` | **OPatch ≥ 13.9.4.2.17**; on a conflict prompt answer `n` and ask Support for a merge patch (as 34809489) | **none** – no policy-store / OPSS-schema step | `opatch rollback -id 40154178`, then restart AdminServer + all managed servers | Generic, 2.1 MB. New in .261013: 40081462 and four "Fix for Bug" entries (39291300, 39289143, 39289108, 39289054) = CPU450: **CVE-2026-114824 (10.0), -91548 (8.6), -91551 (7.5), -91560 (6.5)** (component "Centralized Thirdparty Jars", HTTP, unauthenticated). Cumulative – contains the September / October content of 39979941 (CVE-2026-83020 …, Bug 39969736) |
| **40132160** UMS (On Prem) BP 12.2.1.3.261008 (08-Oct-26) | `40132160/`: `opatch apply` (ZIP `p40132160_122130_Generic.zip` – release **12.2.1.3**, correct for the UMS 12.2.1.3 component of a 12.2.1.4 home) | **OPatch ≥ 13.9.4.2.17**; all processes stopped | `opatch lspatches`, start – no further step | `opatch rollback -id 40132160` | Generic, 2.4 MB, product "Service Delivery Platform" (`oracle.sdp.messaging`). New in .261008: **CVE-2026-91558** (Messaging Enabler, HTTPS, 8.3) and **-91556** (matrix lists 91556 for 14.1.2.0.0 only, CPU450 and the README map it to this 12.2.1.3 BP). The 9.8 UMS CVE 114826 of the same cycle is 14.1.2 only. Cumulative – contains 39939504 |
| **39726402** LibOVD BP 12.2.1.4 (14-Aug-26) | `39726402/`: `opatch apply` | OPatch ≥ 13.9.4.2.13; all processes stopped. The README does **not** mention the predecessor **34065178** – the BP contains its fix (Bug 33903365 "FMW consoles fail after applying JDK 1.8.0_331 or later"), so OPatch should treat 34065178 as a subset and roll it back itself (**assumption** – `opatch prereq CheckConflictAgainstOHWithDetail` first, stop on a real conflict) | `opatch lspatches`, start – no further step | `opatch rollback -id 39726402` (then 34065178 would be missing again – with JDK ≥ 8u331 the consoles fail: re-apply it or restore) | must be in the home **before the first start with a JDK ≥ 8u331** (8u513 here) – the JDK 8u331+ fix of the FMW consoles. Bug list: 20812896, 32305678, 33368783, 33545965, 33762450, 33903365, 34113169, 39272755 |

### 3.4 Forms & Reports 12.2.1.19 (unchanged since October)

| Patch | Description | KA1182 release | Note |
|---|---|---|---|
| **39888613** | Oracle Forms QPR for 12.2.1.19 | Sep 2026 | further recommendations: KA204 |
| **39600813** | Oracle Reports Developer QPR for 12.2.1.19 | Aug 2026 | |
| 39425385 | DB Client Update 19.31 for FMW | Jul 2026 | FMW-specific DB client (based on 19.30), recommended for all security fixes, list: KB850150 |
| **39951739** | PERL Security Patch Update for FMW 12.2.1.4.0 | Oct 2026 | needs DB client for FMW **19.29 or later** – apply after 39425385 |
| KB243716 | SQL Developer installed with Forms & Reports 12.2.1.19: CVE-2021-4104 | Jan 2022 | upgrade to at least 21.4.2, not higher than 21.4.3 |

#### 3.4a From the READMEs (read 2026-10-23 – patches unchanged)

| Patch | Method | Before | Post-install | Rollback | Notes |
|---|---|---|---|---|---|
| **39888613** Forms QPR 12.2.1.19 (29-Aug-26) | ZIP `p39888613_1221190_Linux-x86-64.zip` (platform patch, not Generic); `39888613/`: `opatch apply` | all processes stopped; OPatch 13.9.4.2.x; `make`, `ld`, `ar`, `nm` in `PATH` (OPatch relinks `frmweb` / `dejvm` itself) | `opatch lspatches`, start – no own step; **check the OPatch log for `make` errors** ("OPatch succeeded" alone proves nothing) | `opatch rollback -id 39888613` | **Order: Forms QPR before Reports QPR.** On glibc ≥ 2.34 (OL9) the Reports QPR rebuilds `lib/libzrc.so.0` against glibc 2.34; a later Forms relink against the glibc 2.28 stubs fails with rc=73 and OPatch's own restore can fail too – MOS **KB873815** (Bug 38892485, no fix yet), seen live on 14.1.2 / OL9 (2026-10-14); for 12.2.1.19 **assumption** (same `genshlib` mechanism) – check `ldd --version` on the customer host. Notable fixes: 37641150 (input / output values removed from Forms trace files), 36442524 (linefeed in the Forms URL breaks SSO), 37464441 / 37623466 (FSAL through a proxy / with `restrictedURLparams=ALL`), 35687821 (PL/SQL error 422 after the upgrade to 12.2.1.19), 36945810 / 38098803 (FRM-93652) |
| **39600813** Reports Developer QPR 12.2.1.19 (Linux README 08-Jul-26, Solaris README 27-Aug-26) | **platform ZIP – take `p39600813_1221190_Linux-x86-64.zip`**: the same patch number exists per platform – easy to pick the wrong variant on MOS. **The two READMEs differ:** both list the same 14 named bugs, but the Solaris-64 README (27-Aug) has 20 "Fix for Bug 39375295 … 39375343" entries, the Linux-x86-64 README (08-Jul) only **39375343** – unnamed entries of this kind are usually security fixes. Either a README difference or the Linux build predates them: after the apply check `opatch lsinventory -bugs_fixed \| grep 393753`; if they are missing, ask Oracle (open point 9). `39600813/`: `opatch apply` | as the Forms QPR; **after** the Forms QPR (KB873815) | `opatch lspatches`, start; check the OPatch log for `make` errors – OPatch relinks the Reports binaries and rebuilds `libzrc.so` (`zrcsharedlib`) itself, no own step in the README | `opatch rollback -id 39600813` | notable fixes: 37756029 (encrypted values such as passwords in `cgicmd.dat`), 36434214 (umlauts in `DESNAME` → REP-56093 with UTF8), 35363833 (e-mail distribution via Office365 SMTP with STARTTLS), 33008149 (Reports Server slow to finish jobs), 37595589 (REP-52275 in `showjobs`), 35444503 (job status repository on ADB) |
| **39425385** DB Client 19.31 Update for FMW (21-Jul-26) | platform ZIP `p39425385_122140_Linux-x86-64.zip`; `39425385/`: `opatch apply` | the home must already have the **19c** client ("Database Client 19c 19.14 and higher" – true for 12.2.1.19, named in the README); OPatch ≥ 13.9.4.2.13; `opatch` + `unzip` in `PATH`; all processes stopped; **roll back first if present: one-offs 35037811, 34976606, 35522383** (`opatch rollback -id …`) | start – the OID relink (`ins_ldap.mk`) and the AIX one-off 34976606 do not apply here | `opatch rollback -id 39425385`, restart all servers | fixes CVE-2026-24400 (19.31); full list KB850150. Apply it **before** PERL (needs DB client ≥ 19.29) and before the QPRs, so their relinks of `frmweb` / the Reports binaries use the 19.31 client libraries (order proven live on 14.1.2: DB RU in the SPB → PERL → QPRs – **assumption** for 12.2.1.19) |
| **39951739** PERL SPU for FMW 12.2.1.4.0 (03-Sep-26) | platform ZIP `p39951739_122140_Linux-x86-64.zip`; `39951739/`: `opatch apply` | **OPatch ≥ 13.9.4.2.17**; all processes stopped. The README does **not** name the DB client ≥ 19.29 prerequisite – only KA1182 does; fulfilled by applying 39425385 first | `opatch lspatches`, start – no further step | `opatch rollback -id 39951739` | **confirmed:** single fix CVE-2026-4176 (Perl, 9.8, Bug 39400045) |

### 3.5 Oracle HTTP Server 12.2.1.4 colocated (only if OHS is in the home)

| Patch | Description | KA1182 release | Note |
|---|---|---|---|
| **40176880** | OHS DB19c Bundle Patch 12.2.1.4.261019 | Nov 2026 | apply together with the OSS BP and the DB client (collaborative fixes); post-install KB187736 (KA1182 links the 14.1.2 note KB559857 in this row – copy error) |
| 39567777 | OSS 19c BP 12.2.1.4.260616 | Jul 2026 | same patch as in 3.2 |
| 39114058 | OAM WebGate DB19c BP 12.2.1.4.260323 | Apr 2026 | |
| 38098858 + 38832179 | LIBDMS2 SPU 12.2.1.4.260120 + LIBIAU SPU 12.2.1.4.260120 | Jan 2026 | Linux only |

#### 3.5a From the OHS READMEs (40176880 read 2026-11-18, the others 2026-10-23)

| Patch | Method | Before | Post-install | Rollback | Notes |
|---|---|---|---|---|---|
| **40176880** OHS (Native) DB19c BP 12.2.1.4.261019 (19-Oct-26) | ZIP `p40176880_122140_Linux-x86-64.zip` (21.5 MB; also Windows x64, Solaris, AIX variants – take Linux); `40176880/`: `opatch apply` | only for a home whose DB client was upgraded to **19c** (KB585169 – true for 12.2.1.19); OPatch ≥ 13.9.4.2.13; collaborative patches per KB187736: OSS 19c BP 39567777 (in the SPB) and the DB client → apply **after** step 8; stop everything **including the OHS instance** (`ohs1`) | **MOS KB187736** (last updated 2026-10-20 – no November section) ; start WLS + OHS | `opatch rollback -id 40176880`, reverse the post-install steps | New in .261019: 39932075 ("Fix for Bug") = CPU450 **CVE-2026-9545** (curl in the WebLogic proxy plug-in for OHS, 7.5). Cumulative – contains the October 40005842: CVE-2026-87347 / -87346 / -91419 / -91473, the July / August hardening **switched OFF by default** via flags (39902419 / 39901639 / 39901695), 34646873 (deprecated ciphers removed from the default configuration). Supersedes 40005842 (way B: subset in the prereq) |
| **39114058** OAM WebGate DB19c BP 12.2.1.4.260323 | Linux x86-64, 106.7 MB, classification Security; **no README** | component `oracle.oamclient.webgate.ohs` is in the home → KA1182 applies it; whether `ohs1` actually uses WebGate (OAM SSO) is open | unknown – check the README inside the ZIP after download | `opatch rollback -id 39114058` | point 15 |
| **38098858** LIBDMS2 SPU 12.2.1.4.260120 (bundle, 03-Jul-25) | ZIP `p38098858_122140_Linux-x86-64.zip`; `opatch apply` | OPatch 13.9.4.x; conflict prompt → `n`, merge patch | none | `opatch rollback -id 38098858`, then restart AdminServer + all managed servers | tracking bug 37564963 |
| **38832179** LIBIAU SPU 12.2.1.4.260120 (09-Jan-26) | ZIP `p38832179_122140_Linux-x86-64.zip`; `opatch apply` | all processes stopped | `opatch lspatches` | `opatch rollback -id 38832179` | product "Oracle Platform Security for Java", bug 37616934 |

#### 3.5b KB187736 – post-install steps of the OHS bundle patches (read 2026-10-23)

MOS **KB187736** (updated 2026-10-20, **unchanged for November** – checked
2026-11-18) is the cumulative extension of the OHS README. It is cumulative: an OHS that is patched **for the first time** (the
customer's `ohs1`) has to review **every** item, not only the October one.
Summary in our own words (no MOS text in the repository):

| Item (cycle) | What | For `ohs1` |
|---|---|---|
| Collaborative patches | OHS BP together with OSS BP, DB client, WLS PSU (Node Manager), JDK | covered by steps 6 / 8 / 9 of the cookbook |
| **Oct 2026 – hardening directives** | new directives; the July 2026 hardening is now **off by default** (legacy behaviour) – Oracle recommends enabling after a test | see the table below |
| Jan 2025 / Apr 2024 – default `index.html` | the version disclosure fix reaches only new instances; existing ones keep the old file (KB373037) | check whether `ohs1` still serves the default `index.html` |
| Apr 2024 – DB client 19c | required | fulfilled (12.2.1.19) |
| **Jan 2023 – cipher suites** | remove weak ciphers from `ssl.conf`, `admin.conf` (and other `.conf`), recommended ECDHE-GCM suites matching the certificate type (KB652513) | check `SSLCipherSuite` of `ohs1` (collector) |
| Apr 2022 – `MergeSlashes` | consecutive slashes merged by default | information only |
| Apr 2021 – Java SSL clients | SSLv2 Client Hello fails | irrelevant with current JREs |
| Further KBs | KB496091 (SSL), KB371238 (slow HTTP DoS), KB617786 (host header), KB381807 (X-Frame-Options), KB526727 (cookie flags), KB220767 (XSS) | hardening checklist for a later step |

Our assessment of the October 2026 directives for Forms & Reports behind
`ohs1` (all default off / legacy; enable on the test system first):

| Directive (module) | Recommendation | Why |
|---|---|---|
| `WLStripWLProxyHeaders`, `WLStripWebLogicControlHeaders`, `WLStripPathRewriteHeaders` (mod_wl_ohs), `OHSProxyStripWLHeaders` (mod_proxy) | **On** | clients must not inject `WL-Proxy-*`, `WL-PATH-*`, `X-WebLogic-*` headers – Forms / Reports do not need them from the client |
| `WLHeaderValidationPolicy` (mod_wl_ohs), `OHSContextSecurityPolicy` (mod_context) | **strict** | drop headers / ECID values with control characters |
| `OraAuditSanitizationPolicy` (mod_ora_audit, global only) | **strict** | |
| `RejectUnsafeEncodedPatterns` (core), `SSLAuthConfigHardening` (mod_ossl) | **On** | encoded traversal patterns → 400; stricter client-certificate handling |
| `WLStripForwardedForHeader` | **On if `ohs1` faces the clients directly**; with a load balancer in front check the chain first | the client IP must be overwritten, not appended – same rule as our Nginx `X-Forwarded-For $remote_addr` |
| `WLValidateWebSocketUpgradeResponse` | **On** | validates the back-end 101 response |
| `WLAllowWebSocketUpgrade` | keep **On** (default) for `/forms` | Forms 12.2.1.19 can use WebSocket (`frmwebsocketjsi.jar` in the home) |
| `EnforceTrustedCertHeaderProxy` + `TrustedCertHeaderProxy` | only if `AddCertHeader` is used | |
| `WLRejectMaliciousPathParameters` | not for OHS (Apache / IIS plug-ins only) | |

Where: in the domain configuration of the instance
(`$DOMAIN_HOME/config/fmwconfig/components/OHS/ohs1/` – `httpd.conf`,
`mod_wl_ohs.conf`, `ssl.conf`), not in the runtime copy under `instances/`;
the Node Manager / AdminServer synchronise it.

If a separate OHS home proxies to Forms/Reports, follow the OHS 12.2.1.4 tab
of KA1182 for that home. The WebLogic Proxy Plug-In tab is only for
Apache/IIS as a proxy.

---

## 4. Why: CVEs of the CSPU November 2026 for a 12.2.1.4 home

From the Fusion Middleware risk matrix of the final advisory (rows with
12.2.1.4.0 / 12.2.1.3.0 in "Supported Versions Affected", products of a
Forms & Reports home). The matrix lists only CVEs **new** in this cycle;
earlier ones are covered by the cumulative patches above. Unlike October,
the vehicle is no longer an assumption: MOS **CPU450** (Patch Availability
Document) maps every CVE to its patch.

| CVE | Product / component | Protocol | Remote w/o auth | CVSS 3.1 | Patch (CPU450) |
|---|---|---|---|---|---|
| CVE-2026-91569 | WebLogic Server / TopLink Integration | HTTP | yes | **10.0** | WLS PSU 40205342 (SPB 40213323) – **confirmed** (README) |
| CVE-2026-91570 / 91583 | WebLogic Server / TopLink Integration | HTTP | yes | **9.8** | WLS PSU 40205342 |
| CVE-2026-91585 | WebLogic Server / TopLink Integration | TCP | yes | **9.8** | WLS PSU 40205342 |
| CVE-2026-91456 | WebLogic Server / Core | SOAP | yes | **9.8** | WLS PSU 40205342 |
| CVE-2026-91470 | WebLogic Server / Core | T3, IIOP | yes | **9.8** | WLS PSU 40205342 |
| CVE-2026-91469 | WebLogic Server / Core | HTTP | yes | 9.4 | WLS PSU 40205342 |
| CVE-2026-91416 | WebLogic Server / Core (12.2.1.4 only) | HTTP | no | 5.9 | WLS PSU 40205342 |
| CVE-2026-114824 | Platform Security for Java / Centralized Thirdparty Jars | HTTP | yes | **10.0** | OPSS BP 40154178 |
| CVE-2026-91548 / 91551 / 91560 | Platform Security for Java / Centralized Thirdparty Jars | HTTP | yes | 8.6 / 7.5 / 6.5 | OPSS BP 40154178 |
| CVE-2026-91618 | ADF / Security Framework (12.2.1.4 only) | HTTP | yes | **9.1** | ADF BP 40081766 – **confirmed** (README) |
| CVE-2026-91619 / 91670 | ADF / ADF Faces | HTTP | yes | 3.7 | ADF BP – already in the October BP 40050071 (.260920) |
| CVE-2026-91558 | Service Delivery Platform (UMS) / Messaging Enabler | HTTPS | yes (adjacent) | 8.3 | UMS BP 40132160 – **confirmed** (README) |
| CVE-2026-91556 | Service Delivery Platform (UMS) / Messaging Enabler | HTTP | no | 8.8 | UMS BP 40132160 (matrix: 14.1.2.0.0 only; CPU450 + README: also this 12.2.1.3 BP) |
| CVE-2026-9545 (+ 6276, 6429, 7168, 8924) | Oracle HTTP Server / WLS proxy plug-in for OHS (curl) | HTTPS | yes | 7.5 | OHS BP 40176880 – only if OHS is in the home (customer: `ohs1`) |
| CVE-2026-91587 / 91586 / 91525 / 91529 / 91567 | WebCenter Portal / Composer | HTTP | partly | 6.5 – 8.6 | WebCenter Core BP 40022647 – the **October** patch (CPU450), nothing new to apply |

Not relevant for a Forms & Reports home: Oracle Access Manager server
(authentication engine, admin console – 10.0 rows; the home only has the
OAM **client** libraries), SOA / BPM, OSB, MFT, WebCenter Content / Sites,
Identity Manager connectors, BI. The WebLogic Proxy Plug-In for Apache /
IIS has no new row in November.

Java SE (CSPU Nov 2026 risk matrix, 11 CVEs, max 8.1): Java 8 up to
**8u511b33** affected → fix 8u513 (section 3.1 / 5). The eMudhra alert
CVE-2026-114820 (October) is closed by the same build.

---

## 5. Client side: the JRE of the Forms users

The Forms client (Java Web Start or the standalone launcher FSAL) is a
**TLS client** that uses Java's JSSE – the Java alerts of October
(CVE-2026-91403, eMudhra CVE-2026-114820) and the Java CVEs of November
concern exactly this side. With WebUtil (CLIENT_HOST, file transfer,
JACOB/OLE) a manipulated session can act on the PC with the user's rights.
Background:
[forms_runtime_architecture.md §1.1/§1.2](../../80-FMW-Architecture/forms_runtime_architecture.md#11-where-tls-is-spoken--and-who-uses-javas-jsse),
[forms_jakob_webutil.md §10.1](../../80-FMW-Architecture/forms_jakob_webutil.md#101-what-the-session-can-do-on-the-client--threat-model).

| Item | Recommendation |
|---|---|
| Patch | **40239650** – JRE 8 Update 513 (CPU435) – replaces the October target 40186686 (8u511 alert build, still affected by the eMudhra alert). Platform = the **bitness the clients use today** – the WebUtil DLLs (JACOB etc., `install.syslib` in `webutil.cfg`) must match the JRE bitness |
| Current state (2026-10-22, unchanged) | Software deployment rolls out a private JRE `1.8.0_241-b07` (January 2020), **32-bit** ("Client VM", under `Program Files (x86)`) – six years of Java security fixes behind, not only the alert. Either the 32-bit (Windows x86) build of 40239650 (JRE 8u513), or a planned switch to 64-bit **together** with x64 WebUtil/JACOB DLLs |
| Gap 8u241 → 8u513 | Oracle tightened the defaults in between: TLS 1.0/1.1 disabled (TLS 1.2+ needed at the web server in front of Forms), SHA-1-signed JARs and weak keys rejected. Test the own signed jars (WebUtil, JACOB, customer jars: signature algorithm, key length, timestamp, certificate expiry) and the TLS setup of the web server with the new JRE before the rollout |
| Not | 18143322 ("JDK 8 latest") – a JDK where a JRE is enough |
| Java version | stay on Java 8 for Java Web Start – `javaws` does not exist from Java 11 on (with 11+ only FSAL works) |
| Verification | `java -version` → `1.8.0_513` (b04 or newer); without starting Java: the `release` file of the JRE or the file version of `bin\java.exe` (useful for an inventory via the software deployment) |
| Certificates | test whether the trust of the Forms jar signature survives the update: a certificate in the JRE's `cacerts` is lost when the JRE is replaced, the user's deployment trust store usually stays |
| Distribution | Private JRE as a folder (ZIP / file copy by the software deployment) vs. the `.exe` installer: the installer also registers in the registry (Java Control Panel, system-wide deployment config, `.jnlp` association for Web Start). A copied folder has none of that – the start script / launcher must call its `bin\javaw`/`javaws` explicitly, and certificates belong in that JRE's `lib\security\cacerts` (replaced with every update → re-import in the package) or in a deployment trust store referenced by `deployment.properties`. Keep the existing method and only swap the folder, then test |
| Licence | the patch README demands a Java SE subscription; Java used **only** to run an Oracle product is covered by the exception of MOS Doc ID 1557737.1 – confirm the exact wording for the Forms client JRE; other Java programs on the same PCs are not covered |

---

## 6. Order of work (summary)

**Way A – full run** (`…_full_de.txt`, home not on the October state):

1. Section 1: inventory, versions, DB check; back up the home + inventory.
2. Stop everything; JDK 8u513 (3.1).
3. OPatch 13.9.4.2.25, then WLS SPB 40213323 (3.2) and post-install KB694158 (3.2c JAX-WS gate).
4. FMW Infrastructure bundles (3.3) – with ADF 40081766, OPSS 40154178, UMS 40132160.
5. DB client 19.31 (roll back the one-offs 35037811 / 34976606 / 35522383 first) → PERL → Forms QPR → Reports QPR (3.4a: Forms before Reports, KB873815); SQL Developer if used.
6. OHS bundle set (3.5 / 3.5a: 40176880, 39114058, 38098858, 38832179) – after step 5; post-install KB187736, decide on the hardening flags.
7. Start, smoke test (Forms login, a report via rwservlet, EM login, logs for JAX-WS faults), `opatch lspatches` into the documentation.
8. Client JRE 8u513 rollout (5) – test on a few PCs first.

**Way B – on top of CPU October 2026** (`…_kumulativ_auf_cpu102026_de.txt`, October cookbook applied): back up → JDK 8u513 → SPB
40213323 (`napply`, supersedes the October PSU) → ADF 40081766, OPSS
40154178, UMS 40132160 → OHS 40176880 → start and test → client JRE
8u513. OPatch, DB client, PERL and the QPRs stay as they are.

---

## 7. Open points for the customer

Carried over from the
[October analysis, section 7](../FormsReports12_patch_cpu_2026-10/README.md#7-open-points-for-the-customer)
(answers given there stay valid: 1, 2, 8, 10 partly, 11, 12). Still open
from October: 3–7, 9, 10 (one-off 34290481), 13–20. Changed or new for
November:

| # | Question | Answer |
|---|---|---|
| 14 | Bundled JDK `oracle_common/jdk` (8u341, Reports engines): KA1182 November still names **no** FMW patch for it – unchanged open | |
| 18 | eMudhra: closed for the server JDK and the client JRE by **8u513** (Oracle removed the roots); still open for the bundled `oracle_common/jdk` (point 14) and the OS trust store (`ca-certificates`) | |
| 21 | Was the October cookbook applied (test / production)? `opatch lspatches` of both machines → decides cookbook way A or B | manual run at the customer **2026-10-29** (index of 70-Customer-Projects; FSAL follow-up 2026-11-02) → **way B** for that machine; the second machine still to confirm |
| 22 | JAX-WS gate of the November PSU (default `true`, 3.2c): are there own SOAP / JAX-WS services or external SOAP clients on this domain (other than Forms / Reports / EM)? | |
| 23 | Premier Support for 12.2.x ends **December 2026** (section 2) – the December 2026 CSPU is the last one without Extended Support: contract status? | |
