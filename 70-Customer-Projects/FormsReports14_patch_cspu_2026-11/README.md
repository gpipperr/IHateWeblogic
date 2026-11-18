---
nav_title: "F&R 14 – CSPU Nov 2026"
title: "Forms & Reports 14.1.2 – CSPU November 2026 Patch Analysis"
description: "CSPU November 2026 for Oracle Forms & Reports 14.1.2 on Oracle Linux 9: delta to CPU October 2026, README facts of every patch, order and manual guides."
permalink: /70-Customer-Projects/FormsReports14_patch_cspu_2026-11/
---

# Patch Analysis – Oracle Forms & Reports 14.1.2 – CSPU November 2026

Patch set **CSPU November 2026** (Critical Security Patch Update, released
2026-11-17) for the reference stack of this library: Oracle Forms & Reports
**14.1.2.0.0** on FMW / WebLogic 14.1.2, Oracle Linux 9, Nginx as frontend.

| | |
|---|---|
| What / why | [09-Install/docs/00-patch-references.md](../../09-Install/docs/00-patch-references.md) – patch list, KA1182 / CPU450 / CPU435 / CPU431, the CVE table of this cycle (not repeated here) |
| How – by hand, any older level | [install_14c_patch_set_november_2026_manual_full.md](install_14c_patch_set_november_2026_manual_full.md) – the whole cumulative set |
| How – by hand, from CPU October 2026 | [install_14c_patch_set_november_2026_manual_cumulativ_from_cpu102026.md](install_14c_patch_set_november_2026_manual_cumulativ_from_cpu102026.md) – only the six new patches (+ client runtime) |
| How – automated | [`09-Install/04-oracle_pre_download.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/04-oracle_pre_download.sh), [`05-`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/05-oracle_patch_weblogic.sh) / [`06-`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/06-oracle_patch_forms_reports.sh), [`07-Maintenance/80-`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/80-patch_java_os.sh)…`82-` with [`oracle_software_version.conf`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/oracle_software_version.conf) – **switched to this set 2026-11-18** with [docs/update_lib_to_act_cpu.md](../../docs/update_lib_to_act_cpu.md) + [update_plan.md](update_plan.md) (release `v1.0.202611`) |
| Previous cycle | [FormsReports14_patch_cpu_2026-10](../FormsReports14_patch_cpu_2026-10/README.md) (frozen) |
| Counterpart 12c | [FormsReports12_patch_cspu_2026-11](../FormsReports12_patch_cspu_2026-11/README.md) (customer, F&R 12.2.1.19) |
| State | **2026-11-18: applied on the test host** by hand with the [cumulative guide](install_14c_patch_set_november_2026_manual_cumulativ_from_cpu102026.md) – 0 errors in OPatch, start + smoke test 32 OK, `90-oracle_validate.sh` 0 FAIL, no invalid RCU objects (runtimes: section 8). Analysis: KA1182 (2026-11-17 19:11), CPU450, CPU435, CPU431, KB694158; every README read from the ZIP (section 3a). Forms session from a Windows PC OK; DB MRP + DB JDK, APEX 26.2.1, ORDS 26.3.1 applied 2026-11-18; **lib switched 2026-11-18** (release `v1.0.202611`). Open: client bundle `40-` (21.0.13.1) |

---

## 0. What is new against CPU October 2026

| Area | CPU Oct 2026 (test host today) | **CSPU Nov 2026** | Why (CPU450 / CPU435 / README) |
|---|---|---|---|
| JDK at `JDK_HOME` | 21.0.13.0.2 | **21.0.13.1** (35702194, ZIP checked) | Java matrix: 21.0.13.0.3 affected (11 CVEs, max 8.1) + closes the eMudhra alert CVE-2026-114820 |
| WLS SPB | 40125898 (.261007) | **40289362 (.261112)** | – |
| WLS PSU (in SPB) | 40058371 (.260922) | **40205408 (.261025)** | CVE-2026-91569 (10.0), 91570 / 91583 / 91585 / 91456 / 91470 (9.8), 91469 (9.4) + JAX-WS gate 40073770 (default **true**, KB694158) |
| Third-Party BP (in SPB) | 40035655 (.260916) | **40288205 (.261111)** | CVE-2026-91403 (Certifi, 7.4) |
| ADF BP | 40050062 (.260920) | **40155248 (.261013)** | CVE-2026-91618 (CPU450); 91544 already in the October BP |
| OPSS BP | 39979746 (.260904) | **40154045 (.261013)** | CVE-2026-114824 (10.0), 91548 (8.6), 91551 (7.5), 91560 (6.5) |
| UMS BP | 39940047 (.260827) | **40145610 (.261012)** | CVE-2026-114826 (9.8), 91556 (8.8), 91558 (8.3), 75596 (7.5), 91678 (3.3) |
| OHS BP (Linux) | 39987730 (.260907) | **40181911 (.261020)** | CVE-2026-9545 (curl, 7.5) |
| Forms client runtime | 21.0.13.0.2 (client bundle) / JRE 8u511 | **21.0.13.1** (Windows ZIP of 35702194) / **JRE 8u513** (40239650) | as the server JDK |
| Unchanged | | OPatch 13.9.4.2.25, Coherence CP10, RDA, DB client RU 23.26.2, JDBC, Samples, RCU fix, WebCenter Core, OWSM, FMW Control, OAMCLIENT, LibOVD, PERL, WebGate, Forms / Reports QPR | WebCenter Core 40035984 (October) already carries the five WebCenter Portal CVEs of November (CPU450) |
| Repository DB 19.33 / APEX / ORDS | RU 19.33 / APEX 26.2.0 / ORDS 26.3.0 | + DB MRP **40196156**, DB home JDK **40245331** / APEX **26.2.1** (40040466) / ORDS **26.3.1** | DB Oracle Text CVE-2026-114848 (9.9); APEX + ORDS CVE-2026-114849 (9.8) – own cycles, see 00-patch-references |

Oracle Forms and Oracle Reports themselves have **no** row in the CSPU
November 2026.

---

## 1. Check the installation first

Read-only, as the software owner – identical to the
[October analysis section 1](../FormsReports14_patch_cpu_2026-10/README.md#1-check-the-installation-first)
(collector `collect_fmw_env.sh --full` or the commands there). Distribution
"WebLogic Server for FMW 14.1.2.0.0" + "Oracle Forms Reports 14.1.2.0.0" →
the SPB goes in with `opatch napply`, SPBAT is not supported (SPB README
section 1, unchanged).

### 1a. Test host before the patch run (read 2026-11-18)

| Check | Result |
|---|---|
| OS | Oracle Linux 9.8, glibc **2.34** (KB873815 – only relevant when the QPRs are re-applied) |
| Oracle Home / domain | `/u01/app/oracle/fmw`, `/u01/app/oracle/domains/fr_domain` |
| OPatch | **13.9.4.2.25** – enough for every patch of this cycle |
| Patch level | **CPU October 2026** – 21 patches: SPB marker 40126042 (PSU 40058371, Third-Party BP 40035655, Coherence CP10 39984190, RDA 39646824, JDBC 39487373, DB client RU 39264447, RCU fix 38391376), ADF 40050062, WebCenter Core 40035984, OWSM 40024749, FMW Control 39995927, OAMCLIENT 40057999, UMS 39940047, OPSS 39979746, LibOVD 39726399, PERL 39951765, OHS 39987730, WebGate 39100536, Forms QPR 39842516, Reports QPR 39600348 |
| JDK_HOME | `jdk-21` → `jdk-21.0.13.0.2` (`21.0.13.0.2+1-LTS-2`) |
| Bundled JDK | `oracle_common/jdk` **17.0.12** (`17.0.12+8-LTS-286`) – still no patch (KA1182 November) |
| `opatch lspatches` | ~22 s on this home |

→ The test host is on the October state: **cumulative guide** applies.

---

## 2. Patch list (from `00-patch-references.md`, KA1182 Nov 2026)

| Area | Patches | Applied by |
|---|---|---|
| Java | JDK **21.0.13.1** – 35702194 (fixed 40239626); client JRE 8u513 40239650 / Forms client bundle with the Windows ZIP of 35702194 | `04-` download, `07-Maintenance/80-`, `40-` |
| OPatch | 28186730 = 13.9.4.2.25 (unchanged) | `05-` |
| WLS SPB | **40289362** (PSU 40205408, Third-Party BP 40288205, marker 40289390; Coherence CP10, RDA, DB client RU, JDBC, Samples, OPatch .25, RCU fix unchanged) | `05-` (`napply`) |
| Infrastructure | **ADF 40155248**, WebCenter Core 40035984, OWSM 40024749, FMW Control 39995927, OAMCLIENT 40057999, **UMS 40145610**, **OPSS 40154045**, LibOVD 39726399 | `05-` |
| Forms & Reports | PERL 39951765, Forms QPR 39842516, Reports QPR 39600348 (all unchanged) | `06-` |
| OHS / WebGate | **OHS BP 40181911**, WebGate BP 39100536 (unchanged) | `06-` |
| Optional | 38936596 (Reports BiDi, only with `REPORTS_BIDIPARENTHESIS=YES`) | `06-` |

Download of this analysis (2026-11-18): staging list
`10-Monitoring/Patch-Doku/2026-11_cspunov2026/download_cspunov2026.csv`
(local, not in Git) → `/srv/patch_storage/staging_cspunov2026/`, the live
patch storage stays on October until the switch.

| ZIP | Size | SHA-256 (first 16) | ARU (`unique_patch_id`) |
|---|---|---|---|
| `p40289362_141200_Generic.zip` | 2.8 GB | `2b5a0951c6c9afd7` | – (bundle; inner: marker 29577054, PSU 29534429, TPP 29576292) |
| `p40155248_141200_Generic.zip` | 22 MB | `a96c88248b8b28da` | 29510056 |
| `p40154045_141200_Generic.zip` | 1.6 MB | `2285427019491888` | 29506290 |
| `p40145610_141200_Generic.zip` | 4.6 MB | `3069d53f0edc5863` | 29500732 |
| `p40181911_141200_Linux-x86-64.zip` | 18 MB | `111a479d7567b1d8` | 29522371 |
| `p35702194_2100_Linux-x86-64.zip` | 539 MB | `89cbcb2c30c13635` | – (JDK 21.0.13.1) |
| `p35702194_2100_MSWIN-x86-64.zip` | 518 MB | `1bdefe790d9d1a39` | – (JDK 21.0.13.1 Windows) |
| `p40040466_262_Generic.zip` (APEX) | 1.1 MB | `620fa757d89d37af` | – |
| `p40196156_1933000DBRU_Linux-x86-64.zip` (DB MRP) | 82 MB | `3b2eb60cc8e7812a` | – (container; sub-patches own ARUs) |
| `p40245331_190000_Linux-x86-64.zip` (DB JDK) | 125 MB | `0b0a8ca39b1320f3` | 29556470 |

Full values: `patches_sha256.csv` of the staging run → `download/patches_fmw.csv`
/ `patches_db.csv` at the switch.

---

## 3a. Facts from the patch READMEs

All READMEs read **from the ZIP** on 2026-11-18 and compared with the
portal READMEs (notes of 2026-11-18): **no difference** in content, bug
lists or prerequisites. The portal "readme ARU" equals the
`unique_patch_id` of the ZIP for the bundles. Unchanged patches: see the
[October analysis 3a](../FormsReports14_patch_cpu_2026-10/README.md#3a-facts-from-the-patch-readmes).

| Patch | Method | Before | Post-install | Rollback | Notes / CVE confirmed |
|---|---|---|---|---|---|
| **35702194** "Oracle JDK 21" (latest) / 40239626 (fixed) | no real README – `readme.txt` in the ZIP = licence note + links; ZIP holds `jdk-21.0.13.1_linux-x64_bin.{tar.gz,rpm,deb}` + `SHA256_VALUES` / `MD5_VALUES` | **ZIP checked 2026-11-18: 21.0.13.1** (tar top dir `jdk-21.0.13.1/`); Windows ZIP `jdk-21.0.13.1_windows-x64_bin.{zip,msi,exe}` | `domain_jdk_path.sh`, client bundle `40-` | link back | CPU435: baseline 21.0.13.1+4; closes CVE-2026-114820 (roots removed). Kerberos transited check now on (only with Kerberos SSO) |
| **40289362** WLS SPB 14.1.2.0.261112 (README 11-Nov-26) | unpack **outside** the home (≥ 4 GB) with `unzip` → `WLS_SPB_14.1.2.0.261112/`; in `binary_patches/`: `opatch napply -report -oh … -phBaseFile linux64_patchlist.txt`, then without `-report` | as the owner, `unset JAVA_HOME ORACLE_HOME`; `oui/.globalEnv.properties` JAVA_HOME outside the home; OPatch 13.9.4.2.25 (in the SPB `tools/opatch/generic/`); JDK ≥ 17.0.12 / 21.0.4; all WLS processes stopped; backup | `opatch lspatches`; KB694158 (Nov 2026: JAX-WS gate); start | whole SPB only: `opatch nrollback -idFile rollback_patchlist.txt` (re-activates superseded patches) | SPBAT only for "WLS Generic" / "FMW Infrastructure" → our home `napply` (unchanged). **Content (10):** marker **40289390** (interim 40289366), RDA 39646824, PSU **40205408**, Samples 38063775, Coherence CP10 39984190, DB client RU 39264447, JDBC 39487373, OPatch 28186730 (.25), Third-Party BP **40288205**, RCU fix 38391376. `rollback_patchlist.txt` = the nine without OPatch. Platforms Linux x86-64 / ARM64 / Windows 64 |
| **40205408** WLS PSU 14.1.2.0.261025 (README 25-Oct-26, in the SPB) | via the SPB | OPatch ≥ **13.9.4.2.18**; newest Java CPU (JEP 290, KB159467) | **KB694158** (F41372-26, Nov 2026): new `FeatureCompatibilityMBean.JAXWSRejectUnknownSEIOperationsEnabled` – **default true**, dynamic | with the SPB | **confirmed:** 40073770 (JAX-WS gate) + the 7 WLS CVEs (91585, 91583, 91570, 91569, 91470, 91469, 91456). Cumulative: .260922 with **39924025** (CVE-2026-70748) → `WLS_SPB_CHECK_BUGS` stays; Remote Console 3.0.6 (since .260922) unchanged |
| **40288205** Third-Party BP 14.1.2.0.261111 (README 11-Nov-26, in the SPB) | via the SPB | OPatch ≥ 13.9.4.2.17 (Windows .22) | – (KB379953: jar names keep the old version, real version in `META-INF/MANIFEST.MF`) | with the SPB | **confirmed:** 40202517 = CVE-2026-91403 (Certifi), 40285175 unnamed; jackson-databind 2.21.5 (39863385) still in |
| **40155248** ADF BP 14.1.2.0.261013 (README 27-Oct-26, inventory 14-Oct-26) | `40155248/`: `opatch apply -silent` | OPatch "13.9.4.2.x" (inventory: ≥ 13.9.4.2.17); all processes stopped; **after the SPB** (PNEWS2138) | `opatch lspatches`; Doc ID 3093394.1 = PNEWS2138 (unchanged 2026-01-17): no command, same-cycle rule ADF + PSU + Third-Party BP | `opatch rollback -id 40155248` + rollback part of 3093394.1 | **confirmed:** new 39326348 = CVE-2026-91618 (matrix lists it for 12.2.1.4 only; CPU450 maps it to this BP); 91544 since .260721 (already installed). Cumulative back to .250530 |
| **40154045** OPSS BP 14.1.2.0.261013 (README 13-Oct-26) | `opatch apply -silent` | OPatch ≥ 13.9.4.2.17; all processes stopped | `opatch lspatches`, start – no policy-store step | `opatch rollback -id 40154045` | new: 40081462 (P2T plug-in), CVE-2026-83020 / -83011 / -82996 / -82995 / -82994 (Sep cycle, in .261013 again listed), **four unnamed "Fix for Bug" 39291300 / 39289143 / 39289108 / 39289054 = CVE-2026-114824 / 91548 / 91551 / 91560 per CPU450** (README names no CVE for them) |
| **40145610** UMS BP 14.1.2.0.261012 (README 12-Oct-26) | `opatch apply -silent` | OPatch ≥ 13.9.4.2.17; all processes stopped | `opatch lspatches`, start | `opatch rollback -id 40145610` | **confirmed:** CVE-2026-114826 (**9.8**), -75596, -91678, -91558, -91556; 37969584 clear-text password in `apns_cert_refresh_wlst.log` (APNS – not used here). Product "Service Delivery Platform" – the phase-1 filter missed it (skill rule) |
| **40181911** OHS (Native) BP 14.1.2.0.261020 (Linux README 20-Oct-26) | platform ZIP `p40181911_141200_Linux-x86-64.zip`; `opatch apply -silent` | OPatch ≥ 13.9.4.2.17; all processes stopped | **KB559857** (last updated 2026-10-20 – no November change): nothing to do without an OHS instance | `opatch rollback -id 40181911` | new: only "Fix for Bug 39932075" = CVE-2026-9545 (curl) per CPU450; cumulative incl. .260907 (hardening off by default, 39902419 / 39901695 / 39901639). Windows x64 ZIP exists (20.4 MB) – only for a Windows OHS / Builder home |

### 3b. Repository DB / APEX (own cycles – READMEs from the ZIP, 2026-11-18)

| Patch | Facts |
|---|---|
| **40196156** DATABASE MRP 19.33.0.0.261117 | cumulative MRP; five one-offs (40096495 Oracle Security Service, 40127726 / 40180925 RDBMS, 40130806 Oracle Text, 33566299) – inventories all on **19.33.0.0.0**; DB OPatch ≥ 12.2.0.1.52; `opatch prereq CheckConflictAgainstOHWithDetail`, `opatch napply` (offline; `-online` possible for the online-capable part), then **`datapatch`** (CDB: `alter pluggable database all open` first). **README inconsistency:** the text says "can only be installed to an Oracle home that has … 19.32.0.0.260721" – template error, the sub-patches name 19.33; the conflict check decides (live run) |
| **40245331** DB home JDK 8u513 | replaces 39902051 (8u511); DB OPatch ≥ 12.2.0.1.54; RAC-rolling; `jdk/release` in the ZIP = `1.8.0_513-b04` |
| **40040466** APEX 26.2 Patch Set Bundle (PATCH_VERSION 1, README 2026-10-26) | for 26.2.x → **26.2.1**; ORDS stopped; `catpatch.sql` (PDB) / `catpatch_con.sql` (CDB root) / `catpatch_appcon.sql`; copy `images/` over the APEX images; CDN `https://static.oracle.com/cdn/apex/26.2.1/` (an instance on the CDN is switched automatically); 18 bug fixes incl. 40055514 "CSP header missing from APEX AJAX responses" |

**DB window live 2026-11-18 (test host, in-place on the 19.33 home):**
conflict checks of MRP and DB JDK passed against 19.33 (the README's
"19.32.0.0.260721" is template text – confirmed); domain + ORDS stop,
`systemctl stop oracle-db oracle-listener`; `opatch napply ./40196156`
15:16:54–15:25:43 (~9 min, 5 sub-patches applied); `opatch apply` 40245331
15:25:50–15:28:43 (~3 min, `jdk/bin/java` = 1.8.0_513-b04; the old JDK
bundle 39902051 stays listed – JDK bundles stack in `lspatches`); DB +
listener start, PDBs open; **`datapatch -verbose`: nothing to apply** (all
five MRP sub-patches are binary-only, no SQL files – no new row in
`dba_registry_sqlpatch`), 0 invalid objects; domain start 2 min, smoke test
32 OK, `rcu_repository_check.sh` 37 OK / 0 invalid, ORDS 200. Downtime
15:15:47–15:32:51 (~17 min). Findings: `systemctl stop oracle-listener`
ends "failed" (the `oracle-db` stop had already stopped the listener) –
`systemctl reset-failed` before the start; always set `ORACLE_HOME` to the
DB home before `opatch` (with the FMW `ORACLE_HOME` in the environment
`opatch version` printed 13.9.4.2.25).

**APEX / ORDS window live 2026-11-18:** APEX patch set bundle 40040466
with `03-patch-apex.sh --apply` (24 s, ORDS stopped / started by the
script) → `dba_registry` APEX **26.2.1** VALID, APEXlang 26.2.0+3479, images
`APEX_26.2_p40040466`; then ORDS **26.3.1.303.1615** with
`06-patch-ords.sh --apply` (25 s) → `ORDS_METADATA` 26.3.1.r3031615, HTTP
OK. The ORDS ZIP had to be downloaded by hand (`04-` sees the old 26.3.0
ZIP as "present"). `/i/apex_version.txt` still shows "26.2".

---

## 6. Order of work

Cumulative from CPU October 2026 (the test host):

1. Inventory, backup, VM snapshot.
2. JDK 21.0.13.1 (link switch), `domain_jdk_path.sh`.
3. SPB 40289362 (`napply`, supersedes the October PSU / Third-Party BP / marker).
4. ADF 40155248, OPSS 40154045, UMS 40145610 (the other five bundles stay).
5. OHS 40181911.
6. Start, smoke test `15-`, KB694158 JAX-WS check, `90-oracle_validate.sh`, `cve_inventory.sh`.
7. Forms client bundle `40- --apply` (21.0.13.1), client JRE 8u513 for Web Start clients.
8. Own windows: repository DB (MRP 40196156 + DB JDK 40245331, `datapatch`), APEX 40040466 → ORDS 26.3.1 (one set).

Details: [cumulative guide](install_14c_patch_set_november_2026_manual_cumulativ_from_cpu102026.md),
for an older home the [full guide](install_14c_patch_set_november_2026_manual_full.md).

---

## 7. Open points

| # | Question | Answer |
|---|---|---|
| 1 | `napply -report` on the October home: PSU 40205408 superset of 40058371, Third-Party BP 40288205 superset of 40035655, marker 40289390 replaces 40126042 – and nothing else? | **confirmed live 2026-11-18:** exactly these three supersets; duplicates skipped 39264447 / 39984190 / 39646824 / 39487373 / 38391376; Samples 38063775 skipped (component not in the home); "All checks passed". After the `napply` the three October patches are "inactive" (sub-set) |
| 2 | JAX-WS gate `JAXWSRejectUnknownSEIOperationsEnabled` (default true): does anything in the F&R domain (EM, OWSM, Reports web service, own SOAP clients) send SOAP requests for unknown SEI operations? Check: EM login, Reports via rwservlet, Forms session, server logs for "Invalid operation" SOAP faults | **live 2026-11-18:** no "Invalid operation" in any server log, 0 `<Error>` / `<Critical>` after the start; EM / console / Forms servlet / ORDS HTTP 200, Reports via `rwservlet` PDF OK. Forms session from a Windows PC: open |
| 3 | UMS BP 40145610 with a 9.8 CVE (SOAP, remote w/o auth): is UMS deployed / running in our domain or only on disk? (`cve_inventory.sh` section 4, WLS deployments) – patch scope = on disk anyway | **checked 2026-11-18 (test host, read-only): only on disk / as client library – not reachable.** The domain was built with the template "Oracle User Messaging Service **Client** Extensions for JRF" (`init-info/domain-info.xml`): `config.xml` has only the shared libraries `oracle.sdp.client` / `oracle.sdp.messaging` (targets clusters + AdminServer) – **no** UMS server application (`usermessagingserver`, drivers), no UMS datasource; the EARs exist only on disk (`oracle_common/communications/applications/`). The SOAP / HTTP endpoints of the UMS server answer 404 on 7001 / 9001 / 9002 (`/ucs/messaging/webservice`, `/sdpmessaging/userprefs-ui`). CVE-2026-114826 needs the UMS server web service → not exploitable in a Forms & Reports domain of this layout; the patch keeps the libraries / a scanner quiet (still required by KA1182). A customer domain: same check (`grep -c usermessagingserver $DOMAIN_HOME/config/config.xml` → 0) |
| 4 | DB MRP 40196156: README names RU 19.32.0.0.260721 as base, sub-patches 19.33 – conflict check on the 19.33 home; MRP route in the lib (in-place `napply` + `datapatch` vs. the out-of-place route of `09-db_patch_rcu.sh`) | **live 2026-11-18:** conflict check passed on 19.33 (template error confirmed); applied in-place, `datapatch` had nothing to do (binary-only one-offs); route for the lib → `update_plan.md` (`09- --mrp`) |
| 5 | ORDS 26.3.1: APEXlang compiler version in `ords.war` ≥ APEX 26.2.1? (`04-` / `06-` check) | **live 2026-11-18:** compiler 26.2.0.239.1920 ≥ APEX 26.2 – `06-` check OK, ORDS 26.3.1 + APEX 26.2.1 run together |
| 6 | Bundled JDK 17.0.12 (`oracle_common/jdk`) – still no patch in KA1182 November; affected by all Java 17 CVEs since 2024 and trusts the eMudhra roots | **blocked** – SR draft `SR/sr_bundled_jdk17.txt` (local) |
| 7 | CVE-2026-91619 / 91670 (ADF Faces, 3.7): matrix lists 14.1.2.0.0, CPU450 maps them only to the 12.2.1.4 ADF patch | follow the PAD; newest 14c ADF BP is applied anyway – re-check in the next cycle |
| 8 | OpenSSL CVE-2026-72897 for 19c: matrix 19.32–19.33, CPU431 names the fix for 26ai only | **checked 2026-11-18:** the 19.33 DB does **not** use the OS OpenSSL – no `NEEDED` libssl / libcrypto in any ELF of the DB home (only Spatial `md/gdal/lib/libgdal.so` → `libcrypto.so.10`, absent on OL9), no `dlopen` string, `ora_pmon` maps no OS libssl; the RU 19.32 / 19.33 "OpenSSL 3 migration" (Bug 39009610 etc.) is inside Oracle's own crypto (`libnnz19`, `libzt*`). So **`dnf update openssl` does not fix this CVE** – it fixes the OS side (Nginx, curl, Python …): OS `openssl-3.5.8-2.0.1.el9_8` is current (no update available, its changelog already lists CVE-2026-84782, one of the OpenSSL CVEs behind CVE-2026-72897). The MRP one-offs name no CVE, CPU431 names no 19c fix → **open, next MRP / RU**. Exposure here: none reachable – the listener has only TCP (no TCPS), the CVE needs a TLS connection to the DB |

---

## 8. Runtimes on the test host (2026-11-18)

Applied by hand with the
[cumulative guide](install_14c_patch_set_november_2026_manual_cumulativ_from_cpu102026.md)
(the scripts `80-`…`82-` still read the October conf). Times from
`$STAGE/logs/runtimes.txt`. Test host: one VM, local disk, 19c repository DB
on the same host.

| Step | What | Start – end | Duration |
|---|---|---|---|
| 1 | October check (13 patches present), `lspatches`, `lsinventory -bugs_fixed`, RCU check (0 invalid objects) | 13:07:47 – 13:08:31 (+ RCU check) | < 1 min + ~1 min |
| 2 | unpack SPB + 4 bundles (6.2 GB) | 13:08:44 – 13:11:36 | ~3 min |
| 3 | `startStop.sh stop-all --apply` (NM, Admin, 2 managed, Reports, ORDS) | 13:11:43 – 13:12:29 | < 1 min |
| 4 | tar backup home (4.3 GB) / inventory / domain (0.8 GB) + `backup_config.sh` (70 OK) | 13:12:41 – 13:18:37 | ~6 min |
| 4 | VM snapshot (by Gunther) | 13:18 – 14:08 | (pause) |
| 5 | JDK 21.0.13.1 (unpack + link switch) | 14:08:40 – 14:08:45 | 5 s |
| 6 | SPB `napply -report` | 14:09:01 – 14:17:00 | **~8 min** |
| 6 | SPB `napply` (3 applied, 5 duplicates, Samples skipped) | 14:17:21 – 14:28:03 | **~11 min** |
| 7 | conflict check of the 3 bundles | 14:28:18 – 14:30:27 | ~2 min |
| 7 | ADF 40155248 / OPSS 40154045 / UMS 40145610 | 14:30:36 – 14:44:11 | 5 / 4 / 4 min (~14 min) |
| 8 | OHS 40181911 (prereq + apply) | 14:44:25 – 14:48:53 | ~4.5 min |
| 9 | `lspatches` + `lsinventory -bugs_fixed` | 14:48:53 – 14:49:50 | ~1 min |
| 9 | `startStop.sh start-all --apply` | 14:49:54 – 14:52:24 | 2.5 min |
| 9 | smoke test `15-` – first run 22 OK / 2 FAIL (REP-50001 "server is initializing", run right after the start), second run **32 OK** | 14:52:33 – 14:52:56 | 6 s |
| 9 | `90-oracle_validate.sh` – **1 FAIL: `securerandom.source=file:/dev/random`** in the new JDK (see below) | 14:53:04 – 14:53:30 | 26 s |
| 9 | fix `java.security` (backup), `stop-all` + `start-all`, smoke 32 OK, validate **0 FAIL** / 5 WARN (known) | 14:53:47 – 14:57:40 | ~4 min |

**Patch work** (JDK + SPB with report + 3 bundles + OHS) ~45 min;
**downtime** (stop 13:12 → start 14:52) 1 h 40 min, of that ~50 min VM
snapshot pause. Without the `-report` run and the snapshot pause ~45 min.

Findings of the live run:

- **SecureRandom fix missing after a manual JDK switch.** Every new Oracle
  JDK ships `securerandom.source=file:/dev/random`; `02b-root_os_java.sh` /
  `80-patch_java_os.sh` set `file:/dev/./urandom` – the manual unpack of
  step 5 did not. `90-oracle_validate.sh` reported it (FAIL), the WLS start
  itself was not slowed (2.5 min). Fixed with a backup of `java.security`
  and a restart → **added to step 5 of both guides**. The only other
  difference of the 21.0.13.1 `java.security`: new
  `sun.security.krb5.acceptor.checkTransitedPolicy = true` (CPU435).
- **Smoke test right after `start-all`:** the Reports server answers
  REP-50001 "server is initializing" for some seconds after `start-all`
  returns – wait until `rwserver_status.sh` is OK (added to step 9). Idea:
  `15-` could retry REP-50001.
- **`cve_inventory.sh` before the switch:** 5 FAIL "MISSING – configured for
  CPU Oct 2026" (40126042, 40050062, 39940047, 39979746, 39987730) – they
  are superseded by the newer patches; disappears with the conf switch.
  Idea: recognise "superseded by an installed newer patch".
- Ownership: `/u01/app/oracle/java/jdk-21.0.13.1` and the `jdk-21` link
  belong to `oracle` (manual unpack) – the older JDKs to `root` (`02b-`/`80-`).
  Harmless; the script path stays root.
- `/u01/backup` is not writable for `oracle` → backup under
  `/u01/app/oracle/backup/cspu_nov2026` (guides: `BACKUP` under `ORACLE_BASE`).
- Old finding, not caused by this run: `$ORACLE_HOME/bin/aqxmlctl` still
  names `jdk-21.0.12.1` (`domain_jdk_path.sh` WARN) – AQ XML tool, not used.
- `lspatches` diff exactly as expected (−7 October / +7 November); bug check
  39924025 / 40073770 → 40205408, 40202517 → 40288205, 39326348 → 40155248,
  39985496 → 40145610, 39932075 → 40181911.
