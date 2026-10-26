# Patch Analysis – Oracle Forms & Reports 14.1.2 – CPU October 2026

Patch set **CPU October 2026** plus the **Security Alert CVE-2026-91403**
(Java SE JSSE) for the reference stack of this library: Oracle Forms &
Reports **14.1.2.0.0** on FMW / WebLogic 14.1.2, Oracle Linux 9, Nginx as
frontend.

| | |
|---|---|
| What / why | [09-Install/docs/00-patch-references.md](../../09-Install/docs/00-patch-references.md) – patch list, KA1182 / CPU360 / CPU426, the CVE table of this cycle (not repeated here) |
| How – by hand | [install_14c_patch_set_october_2026_manual.md](install_14c_patch_set_october_2026_manual.md) – step by step, versioned for this cycle |
| How – automated | `09-Install/04-oracle_pre_download.sh`, `05-oracle_patch_weblogic.sh`, `06-oracle_patch_forms_reports.sh`, `07-Maintenance/80-patch_java_os.sh` with `09-Install/oracle_software_version.conf` – **switched to this set and applied on the test host 2026-10-24** (smoke test OK) |
| Counterpart 12c | [Forms12_reports12_patch_analyse_10_2026](../Forms12_reports12_patch_analyse_10_2026/README.md) (customer, F&R 12.2.1.19) |
| State | **2026-10-24: applied on the test host** with `07-Maintenance/80-`/`81-`/`82-` – 0 FAIL, start + smoke test `15-` OK, Forms session from a Windows PC OK (runtimes: section 8). All 17 patch READMEs read (section 3a); open: points 5, 9, 10, 11 (section 7) |

**Why one folder per cycle:** the library always follows the current CPU.
These folders keep the **manual** procedure of every cycle – who has to stay
on, or go back to, an older patch set finds the exact steps and README facts
of that cycle here. When the next cycle starts, this folder is frozen and a
new one (`Forms14_reports14_patch_analyse_<mm>_<yyyy>`) is created.

---

## 1. Check the installation first

Read-only, as the software owner. Everything in one run: the shared collector
[../tools/collect_fmw_env.sh](../tools/collect_fmw_env.sh) (12c and 14c),
`--full` for `opatch lsinventory -bugs_fixed`.

```bash
$ORACLE_HOME/oui/bin/viewInventory.sh | grep -i distribution
$ORACLE_HOME/OPatch/opatch version
$ORACLE_HOME/OPatch/opatch lspatches
ls $ORACLE_HOME/inventory/Components | grep -iE 'forms|reports|ohs|webgate|perl'
ldd --version | head -1                                  # glibc – KB873815
readlink -f $JDK_HOME; $JDK_HOME/bin/java -version
$ORACLE_HOME/oracle_common/jdk/bin/java -version         # bundled JDK 17
```

Distribution **"WebLogic Server for FMW 14.1.2.0.0" + "Oracle Forms Reports
14.1.2.0.0"** = one-step Forms & Reports installer → the WLS SPB goes in with
`opatch napply`; SPBAT is not supported for this distribution (SPB README,
see the 12c analysis 3.2a – same rule for 14.1.2).

### 1a. Test host before the patch run (collector 2026-10-24, version 2026-10-24.1)

| Check | Result |
|---|---|
| OS | Oracle Linux 9.8, glibc **2.34** → KB873815 applies (Forms QPR before Reports QPR + `libzrc` check) |
| Oracle Home / domain | `/u01/app/oracle/fmw`, `/u01/app/oracle/domains/fr_domain` (AdminServer, WLS_FORMS, WLS_REPORTS, loopback only) |
| Distributions | OPatch 13.9.4.2.24; Oracle Forms Reports 14.1.2.0.0; WebLogic Server for FMW 14.1.2.0.0 |
| OPatch | **13.9.4.2.24** (from the Sep SPB) → .25 needed |
| Patch level | **CSPU September 2026** – 12 patches: SPB marker 39925694 (SPB 39925660, WLS PSU 39919611, Third-Party BP 39916998, Coherence CP9 39864483, RDA 39798193, JDBC 39487373, DB client RU 39264447), WLS SPU 39988381, RCU fix 38391376, PERL 38590500, Reports QPR 39600348, Forms QPR 39842516 |
| Not installed (KA1182 requires them) | the eight FMW infrastructure bundles (ADF, WebCenter Core, OWSM, FMW Control, OAMCLIENT, UMS, OPSS, LibOVD), OHS BP, WebGate BP |
| Components | Forms, Reports, OHS (`oracle.ohs2`, `.collocated`) and WebGate binaries – **no OHS instance** (Nginx is the frontend) |
| JDK_HOME | `jdk-21` → `jdk-21.0.12.1` (link) – target 21.0.13.0.2 |
| Bundled JDK | `oracle_common/jdk` **17.0.12** – used by the Reports engines and tools; no patch in KA1182 (blocked, see `00-patch-references.md` "Special case Java") |

---

## 2. Patch list (from `00-patch-references.md`, KA1182 Oct 2026)

| Area | Patches | Applied by |
|---|---|---|
| Java | JDK 21.0.13.0.2 – 40186074 (release-specific) / 35702194 (latest); client JRE 8u511 40186686 | `04-` download, `07-Maintenance/80-patch_java_os.sh` |
| OPatch | 28186730 → 13.9.4.2.25 | `05-` |
| WLS SPB | **40125898** (WLS PSU 40058371, Third-Party BP 40035655, Coherence CP10 39984190, RDA 39646824, DB client RU 39264447, JDBC 39487373, Samples 38063775, OPatch .25) | `05-` (`napply`) |
| WLS SPU | 39988381 – still needed on top? (open point 1) | `05-` |
| Infrastructure | ADF 40050062, WebCenter Core 40035984, OWSM 40024749, FMW Control 39995927, OAMCLIENT 40057999, UMS 39940047, OPSS 39979746, LibOVD 39726399 | `05-` / `06-` (to be added to the scripts) |
| Forms & Reports | PERL **39951765**, Forms QPR 39842516 (unchanged), Reports QPR 39600348 (unchanged) | `06-` |
| OHS / WebGate | OHS BP **39987730**, WebGate BP 39100536 | `06-` (to be added) |
| Optional | 38936596 (Reports BiDi, only with `REPORTS_BIDIPARENTHESIS=YES`) | `06-` |

---

## 3a. Facts from the patch READMEs

Filled in as the READMEs are read (source: MOS, read date per row). Columns
as in the 12c analysis. **README pending** = not read yet.

| Patch | Method | Before | Post-install | Rollback | Notes / CVE confirmed |
|---|---|---|---|---|---|
| **35702194** "Oracle JDK 21" (latest) / 40186074 (release-specific) | **no README** – only the licence note of the support portal (commercial Java SE licence; exception for Oracle products: Doc ID 1557737.1). ZIP `p35702194_2100_Linux-x86-64.zip` with `jdk-21.0.x_linux-x64_bin.{tar.gz,rpm,deb}` | MOS 2026-10-24: Last Updated **2026-10-22 02:45**, 538.9 MB → probably repointed to the alert release. Our copy in the patch storage (downloaded 2026-10-20 09:34, 538.3 MiB) still contains **`jdk-21.0.12.1`** – outdated: download again (`04-oracle_pre_download.sh --apply --fresh-patches --mos`) | – | link back to the old JDK | the file name never changes – the version is only visible **inside**: `unzip -l p35702194_*.zip \| grep jdk-21` must show `jdk-21.0.13.0.2`; after unpacking `JAVA_RUNTIME_VERSION` in `release`. If the latest patch still has 21.0.13 (CPU) → take 40186074 |
| 28186730 OPatch 13.9.4.2.25 (README read again 2026-10-24 – identical for 12c / 14c) | `java -jar 6880880/opatch_generic.jar -silent oracle_home=… [-invPtrLoc …]` with a JDK in `PATH`; `/tmp` noexec → `-Djava.io.tmpdir=…` | roll back 23335292 first (if present), wait 15–30 s; all processes stopped; backup – no OPatch rollback | `opatch version`, `opatch lsinventory`; logs in `<inventory>/logs` (failure: `/tmp/OraInstall<ts>`, KB310962) | restore only | **14.1.2-specific:** Bug 40105335 "WLS 14.1.2 OPatch apply fails during GDR library regeneration when Jakarta EL jar is missing" fixed in .25 → upgrade OPatch **before** the SPB. Same README as for 12c (12c analysis 3.2b): fixes CVE-2026-91776 (Bug 40012934); NGINST patches 31101362 / 29137924 / 29909359 not to be applied afterwards; new prompt for disabled security fixes → `-silent` |
| **40125898** WLS SPB 14.1.2.0.261007 (06-Oct-26, read 2026-10-24) | ZIP `p40125898_141200_Generic.zip`, unpack **outside** the Oracle Home (≥ 4 GB) with `unzip`, do not change `WLS_SPB_14.1.2.0.261007/`; in `binary_patches/`: `opatch napply -report -oh $ORACLE_HOME -phBaseFile linux64_patchlist.txt`, then without `-report` | as the installation owner, `unset JAVA_HOME ORACLE_HOME`; `JAVA_HOME` in `oui/.globalEnv.properties` outside the home (test host: `jdk-21` ✓); **OPatch 13.9.4.2.25 first** (in the SPB, `tools/opatch/generic/`; the SPBAT precheck already needs .25); JDK ≥ 17.0.12 / 21.0.4 (JEP 290, KB159467); all WLS processes stopped; backup `DOMAIN_HOME`, `ORACLE_HOME`, inventory. **No** patch to roll back first (unlike 12c: no 32720458 / 23335292 step for 14c) | `opatch lspatches` against the list (missing components are skipped); KB694158; start | whole SPB only: `opatch nrollback -oh $ORACLE_HOME -idFile rollback_patchlist.txt` (re-activates the superseded PSU; overlay patches must be re-applied); OPatch upgrade only by restore | SPBAT supported only for the distributions "FMW Infrastructure" / "WLS Generic" → our "WebLogic Server for FMW" home: `napply`. **Content (10):** marker **40126042** (interim 40125902), RDA 39646824, WLS PSU **40058371** (14.1.2.0.260922), Samples 38063775, Coherence CP10 39984190, DB client RU 39264447 (23.26.2), JDBC 39487373, OPatch 28186730 (.25), Third-Party BP 40035655, **RCU fix 38391376**. Not in the list: 39988381 (open point 1). Platforms: Linux x86-64, Linux ARM64, Windows 64 |
| **39988381** WLS SPU (CSPU Sep, ZIP 10-Sep-26, read 2026-10-24) | The MOS portal README is an E-Business-Suite AutoPatch placeholder (`patch_39988381.xml`) – the real README is `39988381/README.txt` **inside** `p39988381_14120260823_Generic.zip`: `opatch apply` | **overlay on the Sep PSU 39919611 (mandatory)**, OPatch ≥ 13.9.4.2.17 (`inventory.xml`) | – | `opatch rollback -id 39988381` | base bug **39924025** ("tracking bug for overlay patch"); the ZIP replaces one class, `com.oracle.weblogic.iiop.jar` → `weblogic/corba/cos/naming/NamingContextImpl.class` (IIOP / CORBA naming = CVE-2026-70748). Applied on the test host since 2026-10-14. Because it is bound to PSU 39919611, it **cannot** stay on top of the new PSU 40058371 – see open point 1 |
| **40050062** ADF BP 14.1.2.0.260920 (20-Sep-26, read 2026-10-24) | ZIP `p40050062_141200_Generic.zip`; `40050062/`: `opatch apply -silent` | all processes stopped; OPatch 13.9.4.2.x; KA1182: needs the Third-Party BP (in the SPB, PNEWS2138) → after step 7 | `opatch lspatches`; **MOS Doc ID 3093394.1 = KB PNEWS2138** (read 2026-10-24): no command – coordination rule ADF BP + Third-Party BP + WLS PSU of the same cycle (shared GraalVM libraries); runtime home: ADF only together with the WLS PSU → apply after the SPB; mismatch = EM does not deploy (`BEA-149205` nativebridge / unresolved `graal-bundle` library); `jdev -clean` only for a JDeveloper home | `opatch rollback -id 40050062`, then the rollback steps of **3093394.1** | **confirmed:** CVE-2026-91317 / -91318 / -91322 / -87334 (BP 260721), -91319 / -91320 (BP 260920) – all six ADF rows of the Oct matrix; also -91321 / -91357 (260622). Related to the post-install note: 37376076 "Update GraalVM to 24.1.1 manually in 14.1.2.0.0", 37879667 "update the versioned library references to the GraalVM-all bundle in template and WebLogic config files" (the assumption "post-install adjusts domain library references" was wrong – open point 8 answered). Cumulative back to 250530 |
| **40035984** WebCenter Core BP 14.1.2.0.260916 (16-Sep-26, read 2026-10-24) | ZIP `p40035984_141200_Generic.zip`; `40035984/`: `opatch apply -silent` | **OPatch ≥ 13.9.4.2.17**; all processes stopped | `opatch lspatches`, start – **no** pre- / post-install notes (unlike the 12c README with the WebCenter Portal notes 2662881.1 / 2658914.1) | `opatch rollback -id 40035984` | cumulative back to 260513; WebCenter CVEs (2026-83039 … -83043, -73948 … -73963, -60728 … -60733, -46765 / -46767) – not in the Oct matrix rows of this stack; required by KA1182 because `oracle.webcenter.wccore` is in every FMW infrastructure home |
| **40024749** OWSM BP 14.1.2.0.260914 (18-Sep-26, read 2026-10-24) | ZIP `p40024749_141200_Generic.zip`; `40024749/`: `opatch apply -silent` | **OPatch ≥ 13.9.4.2.17**; all processes stopped (no IDM additional patches named, unlike 12c) | `opatch lspatches`, start – no repository / MDS step | `opatch rollback -id 40024749` | **confirmed:** CVE-2026-21992 (Security Alert Mar 2026) in BP 260304; also -83334 / -83265 (260818), -71093 / -70924 / -61001 / -60737 (260707). **Not named: CVE-2026-54513** (Oct matrix, OWSM / jackson-databind, 8.1) – the newest level has only the unnamed "Fix for Bug 39927140"; the OPatch README lists CVE-2026-54513 under Bug 39621052 already in OPatch .24 (OPatch's own jackson). Vehicle stays an assumption – open point 9. Cumulative back to 250325 |
| **39995927** FMW Control BP 14.1.2.0.260908 (08-Sep-26, read 2026-10-24) | ZIP `p39995927_141200_Generic.zip`; `39995927/`: `opatch apply -silent` | OPatch ≥ 13.9.4.2.13; all processes stopped | `opatch lspatches`, start – no further step | `opatch rollback -id 39995927` | **confirmed:** CVE-2026-91467 (BP 260908); also -83346 / -83069 (260723). Cumulative back to 260120, incl. 38403670 (FMWC login NPE), 39239722 / 38944315 (Application Roles / Policies pages not rendering in the 14c EM console), 29557422 (XXE avoidance) |
| **40057999** OAMCLIENT BP 14.1.2.0.260922 (22-Sep-26, read 2026-10-24) | ZIP `p40057999_141200_Generic.zip`; `40057999/`: `opatch apply -silent` | **OPatch ≥ 13.9.4.2.17**; all processes stopped | `opatch lspatches`, start – no further step | `opatch rollback -id 40057999` | product "Oracle Access Manager" = the OAM **client** libraries of the infrastructure (`oracle.oamclient.core`, `.wls`), not the OAM server. Fixes CVE-2026-83409 / -83407 + unnamed 39992405 / 39992521 (260922), -73958 / -73947 (260817) – OAM rows of earlier advisories, not in the Oct matrix of this stack |
| **39940047** UMS BP 14.1.2.0.260827 (27-Aug-26, read 2026-10-24) | ZIP `p39940047_141200_Generic.zip`; `39940047/`: `opatch apply -silent` | **OPatch ≥ 13.9.4.2.17**; all processes stopped | `opatch lspatches`, start – no further step | `opatch rollback -id 39940047` | product "Service Delivery Platform" (`oracle.sdp.messaging`). Cumulative back to 250225 – successor of the January bundle 38566996 that was dropped by mistake. CVEs -83151 / -83000 … -82997 (260827), -60860 … -60866 (260723), -60374 … -60501 (260629), CVE-2025-55163 (251022). **Relevant for our EBR repository:** 38005346 "MESSAGE, STATUS views are missing in EBR schema", 37603856 / 37555123 ORA-00439 partitioning with EBR / RCU on SE2 – whether the view fix also reaches the **existing** UMS schema (no post-install step in the README) is open point 10 |
| **39979746** OPSS BP 14.1.2.0.260904 (04-Sep-26, read 2026-10-24) | ZIP `p39979746_141200_Generic.zip`; `39979746/`: `opatch apply -silent` | **OPatch ≥ 13.9.4.2.17**; all processes stopped | `opatch lspatches`, start – no policy-store / OPSS-schema step | `opatch rollback -id 39979746` | **confirmed:** CVE-2026-83020 (the OPSS CVE of the CSPU Sep 2026 – in the OPSS BP, **not** in the SPB as assumed in September) plus -83011 / -82996 / -82995 / -82994 (260904), -60366 … -60455 / -61246 (260629). For our IAU (audit) schema: 39367940 `auditDeleteData.sql` did not delete from `IAU_CUSTOM` / `IAU_COMMON`, 38884678 / 38884460 ORA-942 / ORA-904 in `auditReclaimSpace.sql`. Also 39969736 (credential store HTTP 500) |
| **39726399** LibOVD BP 14.1.2.0 (14-Aug-26, read 2026-10-24) | ZIP `p39726399_141200_Generic.zip`; `39726399/`: `opatch apply -silent` | **OPatch ≥ 13.9.4.2.13**; all processes stopped | `opatch lspatches`, start – nothing else | `opatch rollback -id 39726399` | **no CVE** in the README – pure bug-fix bundle (why KA1182 lists it: platform consistency). Relevant for us: 37567156 (libOVD did not set the ciphers for TLS 1.2 to OID by default) and 37331005 (TLS 1.3 LDAP) – both matter for the LDAP identity store of the standalone Reports server. **Not** fixed: our EM "Add Principal" / `ovd.lok` problem (SR open) |
| **39951765** PERL SPU for FMW 14.1.2 (03-Sep-26, read 2026-10-24) | platform ZIP `p39951765_141200_Linux-x86-64.zip`; `39951765/`: `opatch apply -silent` | **OPatch ≥ 13.9.4.2.17**; all processes stopped. Not in the README, only in KA1182: DBCLIENT for FMW ≥ 23.26.0 – fulfilled by the SPB (DB client RU 39264447 = 23.26.2) → apply **after** step 7. The predecessor **38590500** (5.40.2) is not mentioned – OPatch should supersede it on the same component `oracle.perlint` (**assumption**, conflict check shows it) | `opatch lspatches`, start | `opatch rollback -id 39951765` | **confirmed:** single fix CVE-2026-4176 (Perl, 9.8, Bug 39400045) – identical to the 12c PERL SPU 39951739 |
| **39842516** Forms QPR 14.1.2 (Linux README 16-Aug-26, read 2026-10-24) | **installed (Sep) – unchanged in October**; for a new home: platform ZIP `p39842516_141200_Linux-x86-64.zip`, `opatch apply` – **before** the Reports QPR (KB873815, glibc 2.34: rebuild `libzrc` against the stubs first, `docs/06`) | all processes stopped; `make`, `ld`, `ar`, `nm` in `PATH` (relink of `frmweb`, `dejvm`) | `opatch lspatches`, start – no own step; check the OPatch log for `make` errors | `opatch rollback -id 39842516` | relevant fixes: **38351061 / 39566455** Forms compiler seg fault with the common parser after the DB client 23.8 / 23.26.1 upgrade (our SPB brings DB client RU 23.26.2 – keep the QPR on the home), 38068260 pending changes in the AdminServer edit session after a `default.env` MBean update, 37641150 input / output values removed from Forms trace files, 38477700 cancel query → ORA-03123, 37464441 / 37623466 / 37459811 FSAL (proxy, `restrictedURLparams=ALL`, certificate host name), 35933061 / 38098803 OLE2 crashes; 16 unnamed "Fix for Bug 39375269 … 39375294" (same IDs as the 12c Forms QPR – probably security fixes) |
| **39600348** Reports Developer QPR 14.1.2 (Linux README 30-Jun-26, read 2026-10-24) | **installed (Sep) – unchanged in October**; for a new home: platform ZIP `p39600348_141200_Linux-x86-64.zip`, `opatch apply` – **after** the Forms QPR (KB873815, glibc 2.34) | all processes stopped; `make`, `ld`, `ar`, `nm` in `PATH` | `opatch lspatches`, start; "completed with warnings" known (`docs/06`) | `opatch rollback -id 39600348` | 12 bugs, e.g. **37866660 "Reports tools does not support alternative JAVA_HOME location"** (lead for the bundled JDK 17, open point 7), 38872838 (`RUN_REPORT_OBJECT` fails after 30 min), 37756029 (encrypted values in `cgicmd.dat`), 36434214 (umlauts in `DESNAME`), 35363833 (Office365 SMTP STARTTLS). 38936596 (BiDi): the full fix needs the one-off **38936596** (`ewt3.jar`) in addition – our optional `INSTALL_PATCHES_FR_OPTIONAL`. Unlike the 12c QPR no unnamed "Fix for Bug 3937xxxx" entries |
| **39987730** OHS (Native) BP 14.1.2.0.260907 (07-Sep-26, read 2026-10-24) | platform ZIP `p39987730_141200_Linux-x86-64.zip`; `39987730/`: `opatch apply -silent` | **OPatch ≥ 13.9.4.2.17**; all processes stopped | **KB559857** (OHS 14.1.2 cumulative post-install, read 2026-10-24): no command – apply the other KA1182 patches, review the OHS security guide, and the **October 2026 hardening directives** (all off / legacy by default, July hardening also reverted to off) – configuration of an OHS instance only, **nothing to do without one**; start | `opatch rollback -id 39987730`, reverse post-install changes | **confirmed:** CVE-2026-87347 / -87346 (BP 260907). As for 12c: the July / August 2026 CSPU hardening is **off by default** (Bugs 39902419 / 39901639 / 39901695, header stripping via a separate flag) – only relevant once an OHS instance exists. Cumulative back to 250320 – first OHS BP in our home, so all fixes since March 2025 at once; incl. 38130595 (WLS plug-in 14.1.2 for Apache on port 80 as non-root) |
| **39100536** WebGate BP 14.1.2.0.260318 (release notes G14589-06, Apr 2026, read 2026-10-24) | ZIP `p39100536_141200_Linux-x86-64.zip`; `39100536/`: `opatch apply -silent` (cumulative, no need to remove an older BP; a subset patch is rolled back automatically) | latest OPatch; **stop Node Manager and the OHS component** (we have no OHS instance – nothing to stop); OS minimum OL 8 | restart the web server – nothing else | `opatch rollback -id 39100536` | **confirmed:** CVE-2025-0725 (Bug 38764395 – bundled libcurl, gzip decompression). Same patch since the Apr 2026 set, never applied on our host. Other fixes only matter with OAM in use (JWT, `JWTNBCModeOnly`, 401 on XMLHttpRequest) |

---

## 6. Order of work

1. Inventory (section 1), backup.
2. JDK 21.0.13.0.2 (link switch), `domain_jdk_path.sh`.
3. OPatch .25 → SPB 40125898 (`napply`) → (39988381 if still needed).
4. Infrastructure bundles (eight).
5. PERL 39951765 (Forms / Reports QPRs are already at the October level).
6. OHS 39987730 + WebGate 39100536 (binaries).
7. Start, smoke test `15-`, `cve_inventory.sh` (`90-oracle_validate.sh` is still planned).

Details: [install_14c_patch_set_october_2026_manual.md](install_14c_patch_set_october_2026_manual.md).

---

## 7. Open points

| # | Question | Answer |
|---|---|---|
| 1 | WLS SPU 39988381 (CSPU Sep) – contained in SPB 40125898 (PSU 14.1.2.0.260922)? `opatch lsinventory -bugs_fixed` after the SPB / SPB README | SPB README (2026-10-24): **not** in the SPB list. SPU README (in the ZIP, 2026-10-24): overlay on PSU 39919611, base bug **39924025**. So it can **not** be re-applied on PSU 40058371 – expected: the `napply` removes it together with the old PSU (assumption, check the `-report` output). After the apply: `opatch lsinventory -bugs_fixed \| **answered 2026-10-24 (live, `napply -report` on the test host):** "Patch 40058371 – Bug Superset of 39988381, super set bugs: 39924025" – the new PSU contains the fix, OPatch rolls the SPU back automatically within the `napply`. No overlay / SR needed; `05-` checks 39924025 after the apply (`WLS_SPB_CHECK_BUGS`) |
| 2 | OPatch 13.9.4.2.25: does the standalone 28186730 deliver .25, or only the SPB (in Sep only the SPB carried .24)? | the SPB carries .25 in `tools/opatch/generic/` (SPB README) – use that copy; the standalone download is not needed |
| 3 | RCU fix 38391376 came with the Sep SPB – still in 40125898, or does `napply` leave it as it is? | yes – entry 10 of the SPB list (SPB README) |
| 4 | SPB marker patch number of 40125898 (`WLS_SPB_MARKER_PATCH`) – from the SPB README | **40126042** (interim patch 40125902) |
| 5 | Bundled JDK 17.0.12 (`oracle_common/jdk`) – still no patch (KA1182 Oct) | **blocked** – the alternative-JAVA_HOME route (point 7) is closed too (MOS AI 2026-10-24: not certified for Reports, tools only). Only an SR remains (draft `SR/sr_bundled_jdk17.txt`, local, not in Git): "patch for `oracle.jdk` 17.0.12.8.0 in F&R 14.1.2, or certification of an external JDK for Reports" |
| 6 | KB559857 (OHS 14.1.2 post-install) – which items apply without an OHS instance | **answered 2026-10-24:** none – the KB only lists hardening directives for an OHS instance (`mod_wl_ohs`, `mod_proxy`, `mod_ossl`, `mod_context`, `mod_certheaders`, core) and the Apache plug-in `mod_wl_24`, all default off. Same directive set and our recommendation as in the 12c analysis (section 3.5b there). New in Oct: `WLStripWLProxyHeaders` now covers only `WL-Proxy-Client-Cert/-Keysize/-Secretkeysize/-Port`; `X-WebLogic-*`, `WL-PATH-*`, `X-Forwarded-For` and `tyrus-connection-id` have their own `WLStrip*` directives. The same attack class applies to **our Nginx** → open point 11 |
| 11 | Nginx counterpart of the KB559857 header stripping: `nginx-wls.conf.template` overwrites `WL-Proxy-Client-IP` and `WL-Proxy-SSL`, but forwards client-supplied `WL-Proxy-Client-Cert/-Keysize/-Secretkeysize/-Port`, `WL-PATH-TRIM/-PREPEND`, `X-WebLogic-*` and `tyrus-connection-id` unchanged; `X-Forwarded-For` is appended, not overwritten (root README TODO). With `weblogic-plugin-enabled=true` WebLogic trusts the `WL-Proxy-*` headers | open – clear them with `proxy_set_header <name> "";` (`X-WebLogic-*` has no wildcard in Nginx – list the known names), then live test Forms (WebSocket?) / Reports / EM |
| 7 | Reports QPR 39600348 fixes Bug 37866660 "Reports tools does not support alternative JAVA_HOME location" – can the Reports tools / engines be pointed to `JDK_HOME` (21.0.13.0.2) instead of the bundled `oracle_common/jdk` 17.0.12 (open point 5, blocked)? How is it configured (MOS note of the bug), does it cover the engines of the Reports server (`rwengine`) or only the tools (`rwrun`, `rwconverter`)? Test on the test host | **answered 2026-10-24 – no.** MOS AI (3 prompts): no bug note / KB documents how the fix is configured; scope per README wording = Reports **tools** only, not `rwengine` / Reports server. Engines are started by `$DOMAIN_HOME/reports/bin/rwengine.sh` (`exec $ORACLE_HOME/oracle_common/jdk/bin/java …`, hard-coded, also `reports.sh` PATH / LD_LIBRARY_PATH) – `rwserver.conf` does not select the JVM. WebLogic certification of JDK 21.0.13 does **not** certify it for Reports 14.1.2; do not replace / repoint `oracle_common/jdk` – stay on the bundled JDK until Oracle states a Reports certification. Own check of the QPR ZIP: no start script shipped; the template `startscript.xml` changes only add `-Dreports.userid.encryption.enabled=true …` to `setDomainEnv` (already in ours); the tools JVM start is native (`librw.a` `zruji.o`, no `JAVA_HOME` string). Side hit: **KB924687** "After July QPR 39600348 Unable to start Standalone Report Server – REP-50125" = **Bug 39868225** (defect of the QPR, fix "in a later QPR"); workaround `-DORBWaitForResponseTimeout` in `REPORTS_JVM_OPTIONS` – found and fixed by us on 2026-10-15 (`13-`, `docs/13` troubleshooting), therefore not hit. → no way around point 5 |
| 8 | ADF BP 40050062: what does MOS **Doc ID 3093394.1** require after the apply (domain library references for GraalVM-all, `setDomainEnv`, redeploy?) – needed for step 8 of the guide; also its rollback part | **answered 2026-10-24:** = KB PNEWS2138, no post-install command, only the rule "ADF BP + WLS PSU (+ Third-Party BP) from the same cycle" – met by SPB first, then ADF; log check in guide step 11. Rollback: roll back ADF together with the SPB, never leave a newer ADF on an older PSU |
| 9 | CVE-2026-54513 (OWSM / jackson-databind, 8.1): the OWSM BP README does not name it (only unnamed 39927140), the OPatch README names it for OPatch .24 (Bug 39621052). After the apply: compare the jackson-databind version under `$ORACLE_HOME/oracle_common/modules` before / after (`find … -name 'jackson-databind*.jar'`) | **answered 2026-10-26:** the CPU Oct advisory says "the patch for CVE-2026-54515 also addresses CVE-2026-54512, CVE-2026-54513, and CVE-2026-54514" – vehicle = Third-Party BP 40035655 (in the SPB, Bug 39863385, jackson-databind **2.21.5**), installed → **-54513 confirmed**. The 2.16.1 copies `$ORACLE_HOME/jlib/jackson-databind.jar` and `sqlcl/lib/jackson-databind.jar` (DB client RU 39264447) are **not loaded** by any running process (`/proc/<pid>/maps` + open fds 2026-10-26: NM, Admin, WLS_FORMS, WLS_REPORTS, rwserver, rwEng-*, frmweb, ORDS – all use `thirdparty/jackson-databind-2.21.5.jar`, the servers also `oui/modules/private/jackson-databind-2.22.3.jar`). A file-based scanner still reports them – answer: not loaded, DB client component, updated by a later FMW DB client RU; do not delete (part of the inventory) |
| 10 | UMS BP 39940047 fixes 38005346 "MESSAGE, STATUS views are missing in EBR schema" – our RCU schemas are EBR. After the apply: are the views in the existing `<prefix>_UMS` schema (`select view_name from dba_views where owner = '<PREFIX>_UMS' and view_name in ('MESSAGE','STATUS')`)? If not – MOS note of the bug / Support | **answered 2026-10-26 (SQL as SYSDBA, read-only):** `DEV_UMS.MESSAGE` / `STATUS` exist as editioning views on `E$MESSAGE` / `E$STATUS`, VALID, since the RCU run of 2026-10-15 – our schema was not affected by 38005346. Side finding: 69 invalid objects since the RCU run (15.10. 00:05, not caused by the patch run): 62 IAU synonyms (`DEV_IAU_APPEND` / `_VIEWER`, targets exist), `DEV_OPSS` package bodies `OPSS_SYNCHRONIZATION` (ORA-00942 – a table is missing) / `OPSS_BC_INSERTVALPACK` + 4 `NEQUEUE_*` triggers, `DEV_UMS.DRIVERPROPERTIES` (editioning view, no error). Reported since 2026-10-26 by `07-Maintenance/rcu_repository_check.sh` check 6 |

## 8. Runtimes on the test host (2026-10-24)

Measured with the scripts (`07-Maintenance/80-` … `82-`), times from the
logs. Test host: one VM, 4 vCPU class, local disk, 19c repository DB on the
same host – a customer system with slower storage or a remote inventory
takes longer. **Plan the downtime from step 3 (stop) to step 11 (start).**

| Step | What | Start – end | Duration |
|---|---|---|---|
| 2 | `04- --apply --mos`: SPB 40125898 (2.8 GB) + 11 patches | 15:56 – 15:59 | ~3 min (download rate dependent) |
| 3 | `startStop.sh stop-all --apply` | 16:00 | < 1 min |
| 4 | `backup_config.sh --apply` (configuration only) | 15:59 | < 1 min |
| 5 | JDK 21.0.13.0.2 (`80-`, unpack + link switch) | 16:07:16 – 16:07:29 | **13 s** |
| 6 | OPatch 13.9.4.2.25 from the SPB (`81- --apply --opatch-only`) | 16:09:48 – 16:10:37 | ~1 min |
| 7 | `81- --check-only`: unpack SPB + `napply -report` + 8 conflict checks | 16:11:47 – 16:16:31 | ~5 min |
| 7 | `81- --apply`: unpack SPB | 16:17:44 – 16:18:43 | ~1 min |
| 7 | `opatch napply` SPB (5 patches applied, 3 duplicates skipped) | 16:18:43 – 16:23:49 | **~5 min** |
| 7 | bug check 39924025 + unpack / conflict-check the 8 bundles | 16:23:49 – 16:25:55 | ~2 min |
| 8 | 8 infrastructure bundles, `opatch apply` each | 16:25:55 – 16:56:36 | **~31 min** (ADF 2 min, the others ~4 min each) |
| 8 | verification (`lspatches` per patch – fixed afterwards, now one call) | 16:56:36 – 17:03:29 | ~7 min → now < 1 min |
| 9/10 | `82- --check-only`: unpack + 3 conflict checks | 17:26:44 – 17:29:08 | ~2.5 min |
| 9/10 | `82- --apply`: snapshot pause, rollback PERL 38590500 + unpack / conflict check | 17:33:43 – 17:38:01 | ~4 min (incl. the pause) |
| 9 | PERL 39951765 | 17:38:01 – 17:42:37 | ~4.5 min |
| 10 | OHS 39987730 | 17:42:37 – 17:46:10 | ~3.5 min |
| 10 | WebGate 39100536 | 17:46:10 – 17:49:45 | ~3.5 min |
| 9/10 | verification (one `lspatches`) | 17:49:45 – 17:50:29 | < 1 min |
| 11 | `startStop.sh start-all --apply` (NM, Admin, 2 managed, Reports, ORDS) | 18:28:54 – 18:31:17 | ~2.5 min |
| 11 | smoke test `15- --apply` (Forms compile against the DB, 2 reports → PDF, font check) | 18:43:33 – 18:43:39 | 6 s |
| 11 | Forms session from the Windows PC (FSAL, client Java 21.0.13.0.2 – in the bundle since 2026-10-22, the Windows ZIP of 35702194 was updated before the Linux one) | ~18:50 | OK |
| – | `40-oracle_forms_client_bundle.sh --apply`: change check | 20:39:49 – 20:39:50 | 1 s, "up to date" (Java + `frmsal.jar` unchanged) |

**Total downtime** (stop 16:00 → start done 18:31) was ~2.5 h incl. the
check-only runs and pauses; the pure patch work (JDK + OPatch + SPB + 8
bundles + PERL / OHS / WebGate, without `--check-only`) was ~70 min.

Observations:
- The SPB itself is fast; the time goes into the **single `opatch apply`
  per infrastructure bundle** (~4 min each – OPatch inventory load + backup
  per call, even for a 0.5 MB patch like LibOVD). Eight bundles ≈ half an
  hour. `opatch napply` of several one-offs in one call could shorten this
  (not tested – the bundles' READMEs name `opatch apply`).
- Every `opatch lspatches` takes ~25 s on this home – scripts must call it
  once and reuse the output (fixed in `05-` 2026-10-24).
- The snapshot pause of `80-`/`81-`/`82-` (since 2026-10-24) adds the time
  of the VM snapshot itself.

