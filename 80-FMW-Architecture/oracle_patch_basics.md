---
title: "Oracle Patch Basics – Cycles, Numbers, ARU, OPatch"
description: "How Oracle patches are numbered for Fusion Middleware and Database on Linux and Windows: cycle, patch vehicles, release and platform codes, ARU, lsinventory."
---

# Oracle patch basics – cycle, numbers, ARU, OPatch

Every Oracle patch carries several numbers, and each of them answers a
different question: *which fix* (patch number), *for which release* (release
code), *for which operating system* (platform), *which build exactly* (ARU /
Unique Patch ID), *which level* (version string). Mixing them up is the
source of many "it is installed – no, it is not" discussions with Oracle
Support. This page explains the numbers for **Fusion Middleware** (WebLogic,
Forms, Reports 14.1.2) and the **Database** (the RCU repository, 19c), on
**Linux and Windows**, and how to read `opatch lsinventory`.

Oracle has no single document for this – the pieces are spread over the
OPatch guides of each product and many MOS notes (sources at the end).
Markers as in [README.md](README.md): **confirmed (live)** = test host
2026-11-16 (FMW 14.1.2 home with CPU October 2026, DB home 19.33),
**documented**, **assumption**.

The current patch numbers of this library – what to install this cycle – are
**not** repeated here: [09-Install/docs/00-patch-references.md](../09-Install/docs/00-patch-references.md).

---

## 1. The cycle

| Advisory | Cadence | Content |
|---|---|---|
| **CPU** – Critical Patch Update | quarterly, third Tuesday of Jan / Apr / Jul / Oct | cumulative security release for all products |
| **CSPU** – Critical Security Patch Update | since May 2026 the third Tuesday of the **other** months | smaller, targeted security fixes between the CPUs |
| **Security Alert** | any day | one severe vulnerability, own advisory and own patch document |

The public advisory (`oracle.com/security-alerts`) names products, versions
and CVEs – **never patch numbers**. The patch numbers are in the **Patch
Availability Documents** on MOS: for FMW **KA1182** (plus one note per
cycle), for Java one note per cycle / alert, for the Database the per-cycle
"Patch Availability Document" of the CPU. Details, history and how to read
KA1182: [00-patch-references.md – Terms](../09-Install/docs/00-patch-references.md#terms--cpu-cspu-security-alert-and-the-patch-vehicles).

## 2. Terms – what kind of patch is it?

### Fusion Middleware (WebLogic, Forms, Reports)

| Term | What it is |
|---|---|
| **SPB** – Stack Patch Bundle | one ZIP per CPU / CSPU with the WebLogic PSU, Coherence, JDBC, DB client, third-party libraries and OPatch – applied with `opatch napply` |
| **PSU** – Patch Set Update | the cumulative WebLogic patch (inside the SPB for 14.1.2) |
| **Bundle Patch (BP)** | cumulative patch of one FMW component: ADF BP, OPSS BP, OWSM BP, OHS BP, WebGate BP, Coherence cumulative patch … |
| **SPU** – Security Patch Update | single security fix on top of the PSU when it missed the bundle |
| **QPR** – Quarterly Patch Release | the Forms / Reports bundles – **not** part of the SPB |
| **one-off / interim patch** | a single bug fix (MOS: "One-off"); `opatch lsinventory` calls **every** FMW patch an "Interim patch" |
| **OPatch** | the patch tool itself, patched by its own patch (FMW 14.1.2: OPatch 13.9.4.2.x) |

**RCU** is not a patch: the Repository Creation Utility creates the FMW
schemas in the database once. Regular FMW patches (SPB, BP, QPR, one-off)
change **only the Oracle Home**, never the RCU schemas – those change only
with the Upgrade Assistant at a version upgrade
([rcu_middleware_architecture.md](rcu_middleware_architecture.md)).

### Database (19c – the RCU repository)

| Term | What it is |
|---|---|
| **RU** – Release Update | the quarterly cumulative DB patch (`Database Release Update : 19.33.0.0.261020`) – security + bug fixes, also **optimizer and feature fixes** |
| **OCW RU** | Oracle Clusterware part of the same release – also listed in a single-instance DB home (test host) |
| **OJVM RU** | the Java VM in the database – own patch, own number, same cycle |
| **JDK bundle patch** | the JDK inside the DB home (`$ORACLE_HOME/jdk`) – own patch per cycle in addition to the RU (test host: 39902051) |
| **Data Pump bundle patch** | Data Pump fixes on top of the RU |
| **Windows Bundle Patch** | on Windows the DB gets a *Windows Bundle Patch* with the same version string as the Linux RU but its **own** patch number |
| **MRP** – Monthly Recommended Patches | since October 2022: six MRPs per RU, each with all earlier MRPs of that RU plus the current recommended one-offs; "MRPs replace Release Update Revisions (RURs)", "MRPs are available only for the Linux operating system" (**documented**, source 9) – not used in this library |
| **one-off** on top of an RU | must be built for exactly that RU – with the next RU it is rebuilt (or is already contained) |

A DB patch has two parts: the **binaries** (OPatch, Oracle Home) and the
**SQL part** in the database (`datapatch` – registry `dba_registry_sqlpatch`).
An FMW patch has no SQL part.

Test host, DB home 19.33 (**confirmed (live)**, `opatch lspatches`):

```text
39902051;JDK BUNDLE PATCH 19.0.0.0.261020
40057600;DATAPUMP BUNDLE PATCH 19.33.0.0.0
39803650;OJVM RELEASE UPDATE: 19.33.0.0.261020 (39803650)
39922783;OCW RELEASE UPDATE 19.33.0.0.0 (39922783)
39915792;Database Release Update : 19.33.0.0.261020 (39915792)
```

## 3. Platforms – Linux and Windows

A patch exists once per platform (or once "generic" for pure Java / XML
content). The platform shows up in three places:

| Platform | MOS download code | File name | `etc/config/inventory.xml` of the patch | `opatch lsinventory` header |
|---|---|---|---|---|
| Linux x86-64 | **226P** | `p<patch>_<release>_Linux-x86-64.zip` | `<platform id="226" name="Linux x86-64"/>` | `ARU platform id: 226` / `ARU platform description:: Linux x86-64` |
| Microsoft Windows x64 | **233P** | `p<patch>_<release>_MSWIN-x86-64.zip` | id 233 (**assumption** – no Windows host here) | `ARU platform id: 233` |
| Generic (Java / XML only) | **2000P** | `p<patch>_<release>_Generic.zip` | `<platform id="0" name="Generic Platform 1"/>` | – (fits every platform) |

**confirmed (live)**: 226 in `lsinventory` of the FMW and the DB home and in
the OHS bundle 39987730; "Generic Platform 1" id 0 in the WLS SPB 39925660
and in 39988381; the codes 226P / 233P / 2000P in
[`09-Install/download/patches_fmw.csv`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/download/patches_fmw.csv) (column 2) work with the MOS
download. Windows id 233: MOS notes set `OPATCH_PLATFORM_ID=233` for
Windows x64 (source 7).

OPatch compares the platform of the patch with the one of the home
(prerequisite `CheckPatchApplicableOnCurrentPlatform`) – a Linux ZIP on a
Windows home, or a 32-bit build on a 64-bit home, stops there (source 6).

**Generic is not always generic – Data Pump bundle 19.33:** the Data Pump
Bundle Patch **40057600** ("DATAPUMP BUNDLE PATCH 19.33.0.0.0") is
delivered only as `p40057600_1933000DBRU_Generic.zip` – `inventory.xml`
says `<platform id="0" name="Generic Platform 1"/>`, UPI 29497019. On the
Linux test host it applied without a complaint (**confirmed (live)**,
2026-10-28, UPI 29497019 in `lsinventory` = UPI of the ZIP). On a
**Windows** DB home OPatch refused the same ZIP with a wrong-platform
message (customer observation 2026-11, no SR opened). Generic patch, but
not applicable on Windows – so the "generic" label of a DB patch is no
guarantee; check the README and the Windows patch list of the cycle, and
re-test with the Data Pump bundle of the next RU.
For FMW most patches are **generic** (WebLogic, ADF, OPSS – Java), only the
native parts are per platform (Forms / Reports QPR, OHS, WebGate, Perl, DB
client). For the Database almost everything is per platform.

## 4. The numbers – from the patch to the ARU

```text
 p39987730_141200_Linux-x86-64.zip
  │   │       │       └── platform           Linux x86-64 = ARU platform 226 (MOS 226P)
  │   │       └────────── release code       141200 = 14.1.2.0.0  (122140 = 12.2.1.4, 190000 = DB 19c)
  │   └────────────────── patch number       39987730 - what KA1182 / the patch document names
  └────────────────────── "p" = patch ZIP

 inside the ZIP: etc/config/inventory.xml
   <patch_id number="39987730"/>
   <unique_patch_id>29093973</unique_patch_id>   = ARU = this build
   <platform id="226" name="Linux x86-64"/>

 description:  OHS (NATIVE) BUNDLE PATCH 14.1.2.0.260907
                                 └── version string: release + date YYMMDD of the content
```

| Number | Answers | Example | Where you see it |
|---|---|---|---|
| **Patch number** | which fix / which bundle | 39987730 | KA1182, MOS search, file name, `opatch lspatches` |
| **Release code** | for which product release | 141200 | file name |
| **Platform** | for which OS | 226 / 233 / generic | file name, `inventory.xml`, `lsinventory` header |
| **ARU number = Unique Patch ID (UPI)** | **exactly which build** of this patch for this release and platform | 29093973 | `inventory.xml` of the ZIP, `opatch lsinventory`, MOS download link (`…aru=…`) |
| **Version string** | which level (content date) | FMW `14.1.2.0.260907`, DB `19.33.0.0.261020` | patch description |
| **Bug numbers** | which single defects are fixed | 37946091 … | `lsinventory` "Bugs fixed", README |

**ARU** is Oracle's patch build system ("Automated Release Updates"). Every
build of a patch – per release, platform and **re-delivery** – gets its own
ARU number. Oracle can re-release a patch **under the same patch number**
(a broken build, a missing file): the patch number stays, the **ARU / UPI
changes**. Test host, OHS bundle: UPI 29093973 in the downloaded ZIP = UPI
29093973 in `opatch lsinventory` (**confirmed (live)**) – the installed
build is the one offered.

### Where to find the ARU before the download

The MOS patch page shows patch number, release, platform, size and **"Last
Updated"** – but **no ARU**. Hardly anyone could have designed this less
practically ;-) The ARU appears only in the **download link** of each file:
open the download dialog, do not click the file, copy its link (right
click → copy link address) – or use **"WGET Options"** in the same dialog,
the generated script lists every file with its `aru=`. Example, JDK 8
"latest" patch 18143322, Linux x86-64, state 2026-11-16 (MOS page: "Last
Updated 2026-10-25 05:19:21"):

```text
https://updates.oracle.com/Orion/Services/download/p18143322_1800_Linux-x86-64.zip?aru=29534417&patch_file=p18143322_1800_Linux-x86-64.zip
                                                    │        │    │                   └── ARU = this build
                                                    │        │    └── platform
                                                    │        └── release code (1800 = JDK 8)
                                                    └── patch number
```

After the download the ARU of an OPatch patch is in
`etc/config/inventory.xml` (`<unique_patch_id>`) and, once applied, in
`opatch lsinventory`. A **Java** patch has neither (a JDK `tar.gz`, no
OPatch metadata) – the download link is the only place that shows its
ARU, otherwise only the build inside the JDK (`java -version`) tells the
builds apart. On the page itself, "Last Updated" is the only hint that a
patch was re-released.

### FMW and DB – the same numbers, different habits

| | Fusion Middleware 14.1.2 | Database 19c |
|---|---|---|
| main vehicle | SPB + component bundles + Forms / Reports QPR | RU (+ OCW, OJVM, JDK, Data Pump) |
| version string | `14.1.2.0.<YYMMDD>` – release stays, date counts | `19.<RU>.0.0.<YYMMDD>` – the RU number counts up (19.30 → 19.33) |
| platform | mostly generic, native parts per platform | almost all per platform; Windows: own Windows Bundle Patch number |
| SQL part | none (RCU schemas untouched) | `datapatch` after every RU |
| where the numbers come from | KA1182 + per-cycle note, KA204 (QPR) | the DB Patch Availability Document of the CPU |
| one-offs on top | must fit the bundle level (KA1182 lists merges) | must be built for exactly that RU (merge request) |
| how this library patches | in place with OPatch (`07-Maintenance/80-`…`82-`) | out-of-place: new patched home, move the database ([09-db_patch_rcu](../60-RCU-DB-19c/docs/09-db_patch_rcu.md)) |

## 5. Reading `opatch lsinventory`

```text
OPatch version    : 13.9.4.2.25                    <- the tool, must meet the patch README minimum
OUI version       : 13.9.4.0.0
Oracle Home       : /u01/app/oracle/fmw            <- which home is reported (one home per call!)
...
ARU platform id: 226                               <- platform of this home
ARU platform description:: Linux x86-64

Interim patches (21) :                             <- every installed patch (FMW: also bundles)

Patch  39987730     : applied on Sat Oct 24 17:46:07 CEST 2026
Unique Patch ID:  29093973                         <- the ARU = the exact build
Patch description:  "OHS (NATIVE) BUNDLE PATCH 14.1.2.0.260907"
   Created on ...                                  <- build date of the patch
   Bugs fixed:                                     <- proves a single bug fix
     37946091, 38141444, ...
   This patch overlays patches:                    <- DB: the RU it sits on
```

Rules:

- **`opatch lspatches` shows only number and description – no UPI.** It is
  enough for "is the patch there", not for "is it the current build". For
  that: `opatch lsinventory` and compare the UPI with the ZIP.
- **One home per call.** An FMW host often has several Oracle homes (FMW,
  DB, a separate OHS, an old FMW). `opatch lsinventory -oh <home>` per home;
  the central inventory (`oraInventory/ContentsXML/inventory.xml`) lists
  them all.
- **A bundle shows up as its parts.** The FMW SPB appears as its single
  patches (WLS PSU, Coherence, JDBC, DB client RU, third-party bundle) plus
  a marker patch – test host: "WLS STACK PATCH BUNDLE 14.1.2.0.261007
  (Patch 40125898)" as patch 40126042 (**confirmed (live)**).
- **"Is bug X fixed?"** – `opatch lsinventory -bugs_fixed | grep X`, not the
  patch number: a fix often travels in a later bundle under another number
  (example: one-off 37795631 is contained in the DB client RU 39264447 of
  the SPB – [00-patch-references.md](../09-Install/docs/00-patch-references.md), "Superseded").
- **`rc=0` is no proof.** OPatch reports "succeeded" also when a prerequisite
  failed or a patch was skipped – read the output (and the log under
  `cfgtoollogs/opatch/`).
- **DB:** after the binaries the SQL part – `datapatch -verbose`, check
  `dba_registry_sqlpatch` (status `SUCCESS` per PDB).

## 6. Superseding – what OPatch does with older patches

OPatch compares the **bug lists** of the new patch with the installed ones
(**documented**, sources 2, 3):

| Situation | OPatch behaviour |
|---|---|
| the new patch fixes **all** bugs of an installed one (superset) | **not an error:** the installed (subset) patch is rolled back automatically, the new one applied – a new WLS PSU replaces the previous PSU this way |
| the new patch fixes only part of the bugs of an installed one (subset) | skipped / refused ("Subset patch … can't overlay superset patch …") |
| same bugs, overlapping files, no superset | **conflict** – stop; solution: merge patch from Oracle or roll back first |
| options | `-skip_subset`, `-skip_duplicate` (`napply`), `-no_bug_superset` (fail instead of rolling back) |

Consequences:

- An old PSU or bundle **disappears** from `lsinventory` after the new one
  – that is the superset rule, not an error (MOS 2396417.1, source 4).
- The rolled-back files stay in `$ORACLE_HOME/.patch_storage` ("inactive
  patches") – they are needed for a rollback of the new patch; clean up
  only after a successful cycle with `opatch util deleteinactivepatches`.
- **Not everything is a superset in OPatch's eyes:** a new Forms / Reports
  QPR does not always roll back the old one – this library rolls back the
  superseded QPRs explicitly (`SUPERSEDES` map in
  [`06-oracle_patch_forms_reports.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/06-oracle_patch_forms_reports.sh)).
- **DB:** the next RU is a superset of the previous RU; one-offs on top of
  the old RU are either contained in the new RU or conflict and need a
  version for the new RU.

## 7. Example: one patch number, several builds – Java

Java shows the ARU logic best. The well-known JDK patches are **"latest"
patches**: the patch number never changes, Oracle repoints it to the newest
build at every update (**documented**, [00-patch-references.md – Special case Java](../09-Install/docs/00-patch-references.md#special-case-java--two-jdks-one-alert)):

| Patch | Meaning | October 2026 |
|---|---|---|
| **35702194** | "JDK 21 latest" – same patch number, same ZIP name `p35702194_2100_Linux-x86-64.zip` | first the CPU build **21.0.13** (2026-10-20), after the Security Alert the build **21.0.13.0.2** (available from 23 Oct) |
| **40186074** | release-specific patch of JDK 21.0.13.0.2 | stays this build |
| **18143322** | "JDK 8 latest" (also JRE 8) | 2026-10-20: JRE `1.8.0_511-b25` (CPU build, affected), later repointed – MOS "Last Updated 2026-10-25 05:19:21", Linux x86-64 file with **ARU 29534417** (download link, 2026-11-16) |
| **40186686** | release-specific JRE 8u511 of the alert | `1.8.0_511-b26` (fixed) |

So a download of 35702194 or 18143322 on 21 October and one on 24 October
give **different builds under the same patch number** – visible only in the
version / build inside the ZIP, in the "Last Updated" date of the patch on
MOS, and in the ARU of the download link. Rules of this library:

- after a Security Alert take the **release-specific** patch (40186074,
  40186686), not the "latest" one;
- [`patches_fmw.csv`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/download/patches_fmw.csv) keeps a **sha256 per file** – a re-delivered
  "latest" ZIP has a new checksum, the download tool reports it;
- a Java patch is no OPatch patch (a JDK `tar.gz` / directory), so there is
  no UPI in `lsinventory` – check the JDK itself (`java -version`,
  `$JDK_HOME/release` → `JAVA_RUNTIME_VERSION`).

## 8. Practical rules

1. Patch numbers come from the patch document of the cycle (KA1182 for FMW,
   the DB Patch Availability Document), never from the public advisory.
2. Download per platform: Linux 226P, Windows 233P, Generic 2000P – the
   generic ZIP is the same for both.
3. Before applying: OPatch version ≥ README minimum, `opatch prereq
   CheckConflictAgainstOHWithDetail -ph <dir>`.
4. After applying: `opatch lsinventory` – patch there, **UPI = UPI of the
   ZIP**, old subset patches gone; DB: `datapatch`.
5. A support case: give patch number **and** UPI (and the platform) – then
   Oracle knows the exact build.
6. Re-released patch (same number, new UPI): roll back the old build, apply
   the new one.

## 9. Sources

1. Oracle Fusion Middleware 12.2.1 – Patching with OPatch, "Using the OPatch
   lsinventory Command to Verify the Patches Applied to an Oracle Home"
   (output layout with Unique Patch ID, description, bugs fixed):
   <https://docs.oracle.com/middleware/1221/core/OPATC/GUID-7CCCA18F-FFAD-4A47-95C4-FB6994C137B0.htm>
2. OPatch User's Guide (10.2 / 11g era) – Patch conflicts: superset,
   subset, combination conflicts:
   <https://docs.oracle.com/cd/B16240_01/doc/em.102/e15294/patch_conflicts.htm>
3. MOS Doc ID 2357015.1 "WebLogic Server 12.1.3 PSU Jan 2018 … Conflicts
   with Previous PSU" (superset, OPatch rolls back the subset – title and
   summary only)
4. MOS Doc ID 2396417.1 "Old WLS PSU Patch Is Not Shown After Applying New
   WLS PSU Patch in opatch lsinventory" (title only)
5. OPatch syntax reference (`lsinventory -bugs_fixed`, `-inactive`,
   `-skip_subset`): <https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/13.4/optch/opatch-syntax-and-commands.html>
6. MOS Doc ID 2294122.1 "Patch Compatibility with Operating
   System/Platform and Prerequisite Check CheckPatchApplicableOnCurrentPlatform
   Fails" (title only)
7. MOS Doc ID 2338634.1 (Tuxedo on Windows x64, `OPATCH_PLATFORM_ID=233`)
   and MOSC thread "ARU platform id: 226" (title / snippet only)
8. Oracle Database 19c – About Oracle Database Release Numbers:
   <https://docs.oracle.com/en/database/oracle/oracle-database/19/upgrd/oracle-database-release-numbers.html>
9. Oracle AI Database 26 – About Oracle Database Release Numbers (RU and
   MRP since October 2022, MRP replaces RUR, Linux only, recommended
   one-offs in MOS Note 555.1):
   <https://docs.oracle.com/en/database/oracle/oracle-database/26/upgrd/oracle-database-release-numbers.html>
   – the former MOS Doc ID 2285040.1 "Release Update Introduction and FAQ"
   is no longer found in the support portal (checked 2026-11-16)
10. Test host 2026-11-16: `opatch lsinventory` / `lspatches` of the FMW home
    and the DB home 19.33, `etc/config/inventory.xml` of 39987730,
    39925660, 39988381 in the patch storage
11. This library: [00-patch-references.md](../09-Install/docs/00-patch-references.md)
    (cycle, KA1182, Java), [rcu_middleware_architecture.md](rcu_middleware_architecture.md)
