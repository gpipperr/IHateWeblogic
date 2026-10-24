# Patch Analysis – Oracle Forms & Reports 12.2.1.19 – CPU October 2026

Patch analysis for an existing customer installation of **Oracle Forms &
Reports 12.2.1.19** (FMW Infrastructure / WebLogic Server 12.2.1.4) for the
cycle **CPU October 2026** plus the **Security Alert CVE-2026-91403**
(Java SE JSSE). A reference for applying the patches **by hand** – nothing
here depends on the IHateWeblogic scripts.

| | |
|---|---|
| Sources | MOS KA1182 "CPU Patch Advisor for Oracle Fusion Middleware – LATEST for OCTOBER 2026" (tabs Forms and Reports 12.2.1.19, FMW Infrastructure 12.2.1.4, WebLogic Server 12.2.1.4), MOS CPU426 (Java SE alert), public advisories [CPU Oct 2026](https://www.oracle.com/security-alerts/cpuoct2026.html) and [alert CVE-2026-91403](https://www.oracle.com/security-alerts/alert-cve-2026-91403.html) |
| State | read 2026-10-22 |
| Counterpart for 14.1.2 | [09-Install/docs/00-patch-references.md](../../09-Install/docs/00-patch-references.md) (same cycle, our own 14.1.2 stack) |

**Cookbook for the patch run (German, plain text):**
[Patch_Kochbuch_CPU_Okt2026_de.txt](Patch_Kochbuch_CPU_Okt2026_de.txt) – built from
this analysis and the READMEs of all patches (sections 3.1–3.4a).

Patch numbers change every month – before applying, compare against the
current KA1182 ("patched before?" → apply what is newer than the last
applied CPU/CSPU release).

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

All of this in one run: [../tools/collect_fmw_env.sh](../tools/collect_fmw_env.sh) –
standalone, read-only, secrets masked, result `/tmp/fmw_collect_<host>_<ts>.tar.gz`
(shared collector for 12c and 14c, see [../tools/README.md](../tools/README.md)).

### 1a. Inventory of the customer home (received 2026-10-23)

> **Source:** the inventory and the collector run of this section come from
> the customer's **test machine** (confirmed 2026-10-23). The production
> machine has the same layout; its collector run needs a release by the
> customer first – until then the conclusions are valid for test and
> **assumed** for production (section 7, points 12 / 13).
>
> 2026-10-23: a **second machine** of the customer has the same layout
> (Oracle Home `/oracle/product/mw`, JDK via `/oracle/java/jdk`) – the
> cookbook applies to every node; run it machine by machine and compare
> `opatch lspatches` of both (section 7, point 13).

| Check | Result | Consequence |
|---|---|---|
| `viewInventory.sh` distributions | `WebLogic Server for FMW 12.2.1.4.0` + `Oracle Forms Reports 12.2.1.19.0` | the home comes from the standalone Forms & Reports installer – **not** the "Fusion Middleware Infrastructure" or a standalone WLS distribution → **SPBAT not supported**, the SPB goes in with `opatch napply` (3.2a) |
| `opatch version` | **13.9.4.2.11** | below 13.9.4.2.13 → no SPBAT precheck, most bundles need ≥ .13 / .17 → the OPatch upgrade to .25 is the first mandatory step; Patch 23335292 is **not** installed |
| `opatch lspatches` | 8 entries only: 35007159, 35007154, 35005177, 35005164 (DBCLIENT patches for **19.14**), 33903365, 30613424, 34290481, 36475988 | **the home has practically never been patched** since the installation: no WLS PSU, no SPB, no Forms/Reports QPR, no infrastructure bundle → KA1182 "never patched? → apply everything in the tabs"; our list is cumulative and covers it |
| DB client | 19.14 + the four 19.14 one-offs | 39425385 (19.31) supersedes them – OPatch should roll them back as subsets (watch the prereq); 35037811 / 34976606 / 35522383 of the README are not installed |
| 33903365 | LibOVD one-off "FMW consoles fail after JDK 1.8.0_331 or later" | contained in LibOVD BP 39726402 (bug list) → superseded; 34065178 (named in 3.3) is **not** installed |
| 30613424 | CVE-2021-2134 | contained in FMW Control BP 39995014 (bug list of BP 240814) → superseded |
| 34290481, 36475988 | one-offs without description | **open** – what are they? possible conflicts with the bundles (section 7, point 10) |
| 32720458 (old JDBC) | not installed | no rollback before `napply` needed |
| `/etc/oraInst.loc` | `inventory_loc=/home/oracle/oraInventory`, `inst_group=oinstall`; Oracle Home `/oracle/product/mw`, domain home `/oracle/user_projects/domains/fr_domain` | the central inventory lives in the **home directory of the oracle user**, outside `/oracle` – include it explicitly in the backup (a backup of `/oracle` alone misses it) |
| `$ORACLE_HOME/oui/.globalEnv.properties` | `JAVA_HOME=/oracle/java/jdk`, `JAVA_HOME_1_8=/oracle/java/jdk` | OPatch's JDK lies **outside** the Oracle Home (KB175049 fulfilled) and the path is version-neutral → the JDK update is a link switch `ln -sfn jdk1.8.0_511 /oracle/java/jdk` (if `jdk` is a real directory today: rename it to `jdk1.8.0_<old>` once and create the link) – no configuration file has to change; check for remaining `jdk1.8.0_` paths in `DOMAIN_HOME` (cookbook step 4). **Confirmed:** all running Java processes (`ps auxf`) start from `/oracle/java/jdk` – the servers already use the version-neutral path |
| **Collector run 2026-10-23** (`../tools/collect_fmw_env.sh --full --logs`, first machine) | see the rows below | archive kept outside the repository |
| OS / glibc | Oracle Linux **8.9**, glibc **2.28**, uptime 17 weeks, 30 GB RAM | KB873815 (Forms relink after Reports QPR, glibc ≥ 2.34) does **not** apply – the order Forms before Reports stays as a good habit |
| Role of the machine | host name ends with "t", no `frmweb` session at 20:00 | probably a **test** system – confirm (point 12) |
| **Reports** | components `oracle.reports.{bridge,builder,core,runtime,server,tools}` in the home; `ReportsServerComponent` / `ReportsToolsComponent` in `config.xml`; `rwserver` listening on port 13411, two engines running | Reports **runs on this machine** – the Reports QPR 39600813 is required (point 11 answered) |
| **OHS** | components `oracle.ohs2`, `oracle.ohs2.collocated`, `oracle.oamclient.webgate.ohs`; system component **`ohs1`** (type OHS) in the domain | the OHS set of 3.5 (40005842, 39114058, 38098858 + 38832179; 39567777 via the SPB) is required – READMEs still to read (point 2 answered) |
| **JDK inside the home** | `oracle_common/jdk` = **1.8.0_341-b10** (2022); the Reports engines (`rwrun.jar`) run with it | the link switch of `/oracle/java/jdk` (8u411 → 8u511) does **not** reach the Reports engines – they stay on 8u341, affected by every Java CPU since 2022 and the alert CVE-2026-91403. Same topic as the bundled JDK of 14.1.2 (no patch in KA1182). **Open:** does KA1182 / Oracle provide an update of `oracle_common/jdk` for 12.2.1.19, or may the Reports engine JVM be pointed to `/oracle/java/jdk` (point 14) |
| Java elsewhere | an OCI management agent with its own JDK 8u431 under `/oracle/agent` | not part of the FMW home – outside this patch run |
| One-off **36475988** | "One-off", unique ID 25629864, created 8 Apr 2024, applied 30 May 2024; bugs 31730486, 34001741, 34565300, 34992408, 35027900, 35324055, 35504582, 35515196, 35687821, 35783672, 36442524 | all 11 bugs are in Forms QPR 39888613 → a Forms bundle one-off of April 2024, superseded by the QPR |
| One-off **34290481** | created 17 Nov 2022, applied 29 May 2024, fixes only bug 34290481 | still unknown (point 10) – the conflict check shows whether a bundle contains it |
| Listening ports | `WLS_FORMS` 9001 and `WLS_REPORTS` 9002 on 127.0.0.1 only; Reports server 13411 and Coherence/NM ports on all interfaces; a local DB listener on 127.0.0.1:1521 | a database runs on the same machine – repository DB? (its patch level is a separate topic, DB RU) |
| **Collector run 20:53** (version 2026-10-23.3, incl. OHS configuration) | see the rows below | |
| OHS `ohs1` | configured (`httpd.conf`, `ssl.conf`, `admin.conf`, `mod_wl_ohs.conf` with `/console`, `/em`, `/forms`, `/reports` to localhost) but **not running** (no listener on 7777 / 4443 / 7779) | the OHS patches still go in (binaries in the home, KA1182); the KB187736 hardening (3.5b) only matters if `ohs1` is used again. Its configuration is already hardened (TLSv1.2, the recommended GCM ciphers, `ServerTokens None`, HSTS, security headers); the default `index.html` with the version text is still in `htdocs` (KB373037). Note: if it ran, `ohs1` would publish `/console` and `/em` |
| **Web tier in front** | OS Apache (`httpd.service`, enabled, running) **and** Nginx (`nginx.service`, enabled, running); ports 80 / 443 open (owner needs root to show) | which one serves Forms / Reports is open. If Apache uses the WebLogic plug-in (`mod_wl_24`), the KA1182 tab "WebLogic Proxy Plug-In for third-party web servers" applies (CVE-2026-83379 / -87300, 8.7) and the WL* directives of KB187736 2.2 apply to `mod_wl_24` too – the collector reads `/etc/httpd` and `/etc/nginx` from version 2026-10-23.4 on (point 16) |
| Java server JDK | `/oracle/java/jdk` resolves to itself – a **real directory**, not a link | cookbook step 4.4 variant b (rename once, create the link) |
| **Repository database** | local instance `REPOS`, Oracle Home `/oracle/product/19.32/db`, listener 127.0.0.1:1521 | DB **19.32** is affected by CVE-2026-75803 (RDBMS / OpenSSL, 9.8, unauthenticated; affected 19.3–19.32) → DB RU 19.33 – separate patch run, not part of this cookbook (point 17) |
| Other listeners | Reports server 13411 / 28461 and Coherence / NM ports on all interfaces; OCI management agent 3874; a Java process on 127.0.0.1:8080 | firewall review; outside the patch run |
| Products (`lsinventory -details` excerpt) | file list of the Forms components (`patches/25629864`, Forms only) | whether the **Reports** component is in the home is not visible – the customer runs Reports, but probably not on this server (section 7, point 11) |


---

## 2. Support status 12.2.1.x

| Fact (KA1182 introduction) | Consequence |
|---|---|
| Forms & Reports 12.2.1.4 has received no patches since July 2024 – only **12.2.1.19** is patched | the customer is on 12.2.1.19 – OK |
| Premier Support for 12.2.x ends **December 2026** | after that, patches can only be downloaded with an **Extended Support** contract – check the contract |
| Final CPU/CSPU for 12.2.1.4 (incl. 12.2.1.19): **December 2027** | plan the upgrade to 14.1.2 (final CPU December 2032) in 2027 – target architecture: [09-Install](../../09-Install/README.md) |

---

## 3. Patch list – Forms & Reports 12.2.1.19 home (KA1182, October 2026)

Apply in this order, with **all** Forms/Reports/WebLogic processes stopped
(Node Manager, AdminServer, managed servers, OHS if colocated). Back up the
Oracle Home and the inventory before (`tar` of `ORACLE_HOME` and
`oraInventory`) – rollback per patch with `opatch rollback -id <nr>`.

"KA1182 release" = the CPU/CSPU in which Oracle listed the patch; a patch
of an older release is still required if it is not installed yet.

### 3.1 Java SE on the server (JDK 8)

| Patch | Description | KA1182 release | Note |
|---|---|---|---|
| 18143322 | Java SE 8 Update 511 or later ("JDK 8 latest") | Oct 2026 | what KA1182 demands (CPU388) |
| **40186682** | JDK 8 Update 511 – **alert build** for CVE-2026-91403 (CPU426) | Alert 2026-10-21 | **take this one**: the 8u511 of the CPU (20 Oct) is listed as affected by the alert one day later; "patches available by 23 Oct 2026". 18143322 still pointed to the CPU build on 2026-10-22 (Last Updated 2026-10-20) |

JDK update procedure: KB175049. Both builds are called "1.8.0_511" – only
the build number (`java -version` → `1.8.0_511-bNN`) tells them apart:
**b25** = CPU build (affected), **b26** = alert build (fixed; observed on
2026-10-22 for the JRE, confirm with the README of 40186682).

Update 2026-10-23: 18143322 (Linux x86-64, 550.8 MB) now shows **Last
Updated 2026-10-22 03:10** (the day before: 2026-10-20) – Oracle has
probably repointed the "latest" patch to the alert build. The patch has
**no README**; proof only from the content: after unpacking,
`jdk1.8.0_511/bin/java -version` or `grep JAVA_RUNTIME_VERSION
jdk1.8.0_511/release` must show **b26**. If b26 → 18143322 and 40186682 are
equivalent; if b25 → take 40186682.

40186682 has **no README** either – only the licence text of the support
portal ("You must have a current commercial license or support contract
with Oracle that includes Oracle Java SE …", links to the OTN Java readme and
the release notes). For Java used **only** to run Oracle products the
exception of MOS Doc ID 1557737.1 applies (same as for the client JRE,
section 5). Install procedure: KB175049 (unpack beside the old JDK, switch
`JAVA_HOME` in the domain scripts / `.globalEnv.properties` / Node Manager);
proof of the alert build only from the content:
`<jdk>/bin/java -version` → `1.8.0_511-b26`, or
`grep JAVA_RUNTIME_VERSION <jdk>/release`.

### 3.2 OPatch and WebLogic Server 12.2.1.4

| Patch | Description | KA1182 release | Note |
|---|---|---|---|
| 28186730 | OPatch **13.9.4.2.25** | Oct 2026 | upgrade OPatch first |
| **40129641** | WLS Stack Patch Bundle 12.2.1.4.261007 | Oct 2026 | **option 1** – contains all patches of the next table |

Option 2 instead of the SPB – the individual patches:

| Patch | Description | KA1182 release |
|---|---|---|
| 40069416 | WLS PSU 12.2.1.4.260924 – post-install steps KB694158 | Oct 2026 |
| 39984205 | Coherence 12.2.1.4 Cumulative Patch 33 | Oct 2026 |
| 39646867 | RDA 26.4.20261020 for FMW 12.2.1.4 | Oct 2026 |
| 39988961 | FMW Third-Party BP 12.2.1.4.260907 (KB379953) | Oct 2026 |
| 39567777 | OSS 19c BP 12.2.1.4.260616 | Jul 2026 |
| 39487427 | JDBC 19.31 Bundle Patch 12.2.1.4.260603 – first JDBC BP in this home? Roll back older JDBC patches first (KB153375) | Jul 2026 |
| 36426672 | WebLogic Samples SPU 12.2.1.4.240416 (only if samples are installed – OPatch checks) | Apr 2025 |
| 37056593 | Cloning SPU for WLS/FMW 12.2.1.4.0 | Oct 2024 |
| 35965629 | ADR SPU for WebLogic Server 12.2.1.4.0 (size optimized, KB496228 / KB537876) | Oct 2023 |
| 36789759 (or minimum 33093748) | FMW Platform BP 12.2.1.4.240812 (latest recommended) / FMW Platform SPU (minimum) | Apr 2021 |

#### 3.2a From the SPB README (40129641, dated 07-Oct-26, read 2026-10-23)

| Topic | README says | For the patch run |
|---|---|---|
| Content | 12 entries: marker 40129643 / 40129696 (SPB in `lsinventory`), ADR 35965629, WLS PSU 40069416, Samples SPU 36426672, Coherence CP33 39984205 (`lspatches` shows **1221426**), FMW Platform BP 36789759, Third-Party BP 39988961, **OPatch 28186730 (13.9.4.2.25)**, JDBC 19.31 BP 39487427, RDA 39646867, OSS 19c BP 39567777, Cloning SPU 37056593 | = the table above ("option 2"); OPatch is part of the SPB ZIP (`tools/opatch/generic/`) |
| SPBAT or `napply` | SPB / SPBAT "supported only for products installed from the Oracle Fusion Middleware Infrastructure distribution or standalone WebLogic Server distributions … If any other Oracle product installs an FMW Infrastructure, then the SPBAT would not be supported" (example: EM 13c) | decide by the **Distribution** in `viewInventory.sh` (section 1). **Recommendation: `opatch napply`** – works in every case, gives control, the same method as for our 14.1.2 homes; the SPBAT `-phase precheck` can still be run beforehand (read-only) |
| Staging | ZIP `p40129641_122140_Generic.zip`, unpack **outside** the Oracle Home with `unzip` (keeps permissions), ≥ 4 GB free; result `WLS_SPB_12.2.1.4.261007/` – do not change it | |
| Java | minimum JDK 1.8.0_211 (JEP 290 for the deserialization fixes, KB159467) | we install 8u511 before (3.1) |
| `.globalEnv.properties` | `JAVA_HOME` in `$ORACLE_HOME/oui/.globalEnv.properties` must point to the JDK **outside** the Oracle Home (KB175049) – otherwise OPatch patches itself / corrupts the inventory | check and, after the JDK update, adjust to the new JDK path |
| Backup | `DOMAIN_HOME`, `ORACLE_HOME` and the **central inventory** – "in some cases restoring from backup is the only way to roll back" | also the domain, not only the home |
| OPatch | PSU needs ≥ 13.9.4.2.13; if Patch **23335292** is on OPatch 13.9.4.2.13, roll it back **before** the OPatch upgrade (not after); upgrade: `java -jar <dir>/6880880/opatch_generic.jar -silent oracle_home=$ORACLE_HOME` (README of 28186730) | wait 15–30 s after the rollback before the next `opatch` call |
| Processes | AdminServer, managed servers **and Node Manager** stopped, no Java process on the home | |
| `napply` | as the installation owner, `unset JAVA_HOME ORACLE_HOME`; roll back Patch **32720458** if present; in `binary_patches/`: `opatch napply -report -oh $ORACLE_HOME -phBaseFile linux64_patchlist.txt` (dry run), then the same without `-report` | the patch list files are in `binary_patches/`, no path needed |
| Post-install | `opatch lspatches` against the list (components not installed are skipped – normal); KB694158 (security advice / post-install for WLS PSUs); start the servers | |
| Rollback | `opatch nrollback -oh $ORACLE_HOME -idFile rollback_patchlist.txt` in `binary_patches/` (all patches of past and present SPBs, superseded PSU re-activated, overlay patches must be re-applied); OPatch upgrade only by restore; "do not roll back individual patches" | |

#### 3.2b From the OPatch README (28186730, OPatch 13.9.4.2.25, read 2026-10-23)

| Topic | README says | For the patch run |
|---|---|---|
| Rollback | "no mechanism to revert OPatch to an older version" – only restore of `ORACLE_HOME` + central inventory | backup **before** the OPatch upgrade |
| Before | all processes using files of the Oracle Home stopped; Patch **23335292** rolled back first (`opatch rollback -id 23335292`), then wait 15–30 s; never roll it back after the upgrade | |
| Install | unzip into a staging directory (→ `6880880/`), run with a **JDK** in `PATH`: `java -jar <stage>/6880880/opatch_generic.jar -silent oracle_home=$ORACLE_HOME` | custom inventory: `-invPtrLoc <path>/oraInst.loc`; `/tmp` with `noexec`: `java -Djava.io.tmpdir=<dir> -jar …` |
| Logs | success: `<central inventory>/logs`; failure: `/tmp/OraInstall<timestamp>`; problems: KB310962 | |
| Check | `$ORACLE_HOME/OPatch/opatch version` → 13.9.4.2.25, `opatch lsinventory` | |
| NGINST patches | 31101362, 29137924, 29909359 are contained – do **not** apply them after the upgrade (error); if already in the inventory: harmless, cannot be rolled back | |
| New in .25 | Bug 39905069 "prompt user when patch contains security fixes not enabled by default", Bug 39932917 new `opatch util` option to query such fixes | `napply` with `-silent` in the cookbook; after the run query disabled security fixes (`opatch util -help`) |
| CVEs fixed | Bug 40012934: **CVE-2026-91776** (NextGen OUI, jackson-databind – CPU Oct 2026 row), plus CVE-2026-19032, -59650, -54428 | confirms the OPatch vehicle for CVE-2026-91776 (section 4); the other OUI rows (CVE-2026-8763, -101520, -59889) are not named – still assumption |

### 3.3 FMW Infrastructure 12.2.1.4 bundle patches

KA1182: "if only applying the WebLogic Server SPB or individual patches …
apply the additional patches" – **none of them is in the WLS SPB**. The
components come with every FMW infrastructure (also with Forms & Reports).

| Patch | Description | KA1182 release | Note |
|---|---|---|---|
| 40050071 | ADF Bundle Patch 12.2.1.4.260920 | Oct 2026 | together with 34809489 |
| 34809489 | Fix for CVE-2021-42575 | Jul 2023 | required with any ADF bundle patch, if not yet applied |
| 40022647 | WebCenter Core BP 12.2.1.4.260914 | Oct 2026 | installed even without WebCenter products |
| 40047683 | OWSM Bundle Patch 12.2.1.4.260918 | Oct 2026 | includes the fix of Security Alert CVE-2026-21992 (Mar 2026) – confirmed by the README (BP 260304) |
| 39995014 | FMW Control BP 12.2.1.4.260908 | Oct 2026 | Enterprise Manager on the AdminServer |
| 40059055 | OAMCLIENT Bundle Patch 12.2.1.4.260922 | Oct 2026 | |
| 39979941 | OPSS Bundle Patch 12.2.1.4.260904 | Sep 2026 | |
| 39939504 | UMS Bundle Patch 12.2.1.3.260827 | Sep 2026 | UMS 12.2.1.3 is installed in a 12.2.1.4 home |
| 39726402 | LibOVD Bundle Patch 12.2.1.4 | Aug 2026 | replaces Patch 34065178 (needed after JDK 8u331); required on all installations except WLS standalone |

#### 3.3a From the bundle READMEs (read 2026-10-23)

| Patch | Method | Before | Post-install | Rollback | Notes |
|---|---|---|---|---|---|
| **40050071** ADF BP 12.2.1.4.260920 (20-Sep-26) | in the unpacked `40050071/`: `opatch apply` (single patch, **not** `napply`) | all processes of the Oracle Home stopped, the installation owner, `ORACLE_HOME` + `PATH=$ORACLE_HOME/OPatch:$PATH`; backup `DOMAIN_HOME` / `ORACLE_HOME` / inventory; OPatch 13.9.4.2.x | `opatch lspatches` (`jdev -clean` only for a JDeveloper home – not here) | `opatch rollback -id 40050071`, then **empty the server `tmp` directories** of the domain (`$DOMAIN_HOME/servers/*/tmp/*`) | ZDT-eligible (`FMW_ROLLING_ORACLE_HOME`) – not used here. Cumulative back to 200129. **CVE mapping confirmed**: CVE-2026-91317 / -91318 / -91322 / -87334 (BP 260721), CVE-2026-91319 / -91320 (BP 260920) – all six ADF rows of section 4; also CVE-2026-91321 / -91357. The README does not mention 34809489 – KA1182 still requires it with any ADF BP |
| **34809489** interim patch (17-Nov-2022) | `34809489/`: `opatch apply` | as above; check conflicts first: `opatch prereq CheckConflictAgainstOHWithDetail -ph ./` – if OPatch asks "patch(es) … will be rolled back … proceed? [y\|n]" answer **`n`** and request a merge patch from Oracle Support | none | `opatch rollback -id 34809489`, then empty the server `tmp` directories | bug title "PATCH CONFLICT OBSERVED BETWEEN 34647149 AND 34604561" – KA1182 lists it as "Fix for CVE-2021-42575" with any ADF BP (assumption: the conflict resolver of the ADF chain); apply it **after** 40050071. The README's `opatch lsinventory -jre $ORACLE_HOME/oracle_common/jdk/jre` is generic text – OPatch uses the JDK of `.globalEnv.properties` |
| **40022647** WebCenter Core BP 12.2.1.4.260914 (14-Sep-26) | `40022647/`: `opatch apply` | **OPatch ≥ 13.9.4.2.17**; all processes stopped; pre-install steps: MOS 2662881.1 "Pre-Installation Instructions for WebCenter Portal 12.2.1.4 Bundle Patches" | `opatch lspatches`; post-install: MOS 2658914.1 (WebCenter **Portal**) | `opatch rollback -id 40022647`, reverse the post-install changes | the two notes are for a WebCenter **Portal** domain – a Forms & Reports home only carries the `wccore` libraries of the infrastructure, so they most likely do not apply (**assumption** – read both notes once before the window). Cumulative back to 200302; fixes WebCenter CVEs (2026-83039/-83040/-83041/-83043, -73948 … -73963, -60728 … -60733) that are not listed in section 4 (WebCenter rows); required by KA1182 because the component is in every FMW infrastructure home |
| **40047683** OWSM BP 12.2.1.4.260918 (19-Sep-26) | `40047683/`: `opatch apply` | **OPatch ≥ 13.9.4.2.17**; all processes stopped. The additional patches of the README (38009014 OINAV, 39099526 OIM BP) are for **IDM** products only – not needed here | `opatch lspatches`, start – **no repository / MDS step** | `opatch rollback -id 40047683` | cumulative back to 210520. **Confirmed:** CVE-2026-21992 (Security Alert March 2026) in BP 260304; further CVE-2026-83334 / -83265 (260818), -71093 / -70924 / -61001 / -60737 (260707); the newest level 260918 has only bug fixes |
| **39995014** FMW Control BP 12.2.1.4.260908 (08-Sep-26) | `39995014/`: `opatch apply` | OPatch ≥ 13.9.4.2.13; all processes stopped | `opatch lspatches`, start – no further step | `opatch rollback -id 39995014` | cumulative back to 240814. **Confirmed:** CVE-2026-91467 (section 4) in BP 260908; also CVE-2026-83346 / -83069 (260803) |
| **40059055** OAMCLIENT BP 12.2.1.4.260922 (22-Sep-26) | `40059055/`: `opatch apply` | **OPatch ≥ 13.9.4.2.17**; all processes stopped | `opatch lspatches`, start – no further step | `opatch rollback -id 40059055` | product "Oracle Access Manager" = the OAM **client** libraries of the infrastructure (not the OAM server); fixes CVE-2026-83409 / -83407 (260922), -73958 / -73947 (260819) – none of them in section 4 (OAM rows of earlier advisories) |
| **39979941** OPSS BP 12.2.1.4.260904 (04-Sep-26) | `39979941/`: `opatch apply` | **OPatch ≥ 13.9.4.2.17**; on a conflict prompt answer `n` and ask Support for a merge patch (as 34809489) | **none** – no policy-store / OPSS-schema step | `opatch rollback -id 39979941`, then restart AdminServer + all managed servers | "ensure that you have the exact symptoms" is the generic text for interim patches – KA1182 makes the BP mandatory. Cumulative back to 200724. **Confirmed:** CVE-2026-83020 (OPSS CVE of the CSPU Sep 2026) plus -83011 / -82996 / -82995 / -82994 in BP 260904, -60366 … -60455 / -61246 in 260629. Also fixes Bug 39969736 (credential store HTTP 500 caused by the previous OPSS BP) |
| **39939504** UMS (On Prem) BP 12.2.1.3.260827 (27-Aug-26) | `39939504/`: `opatch apply` (ZIP `p39939504_122130_Generic.zip` – release **12.2.1.3**, correct for the UMS 12.2.1.3 component of a 12.2.1.4 home) | **OPatch ≥ 13.9.4.2.17**; all processes stopped | `opatch lspatches`, start – no further step | `opatch rollback -id 39939504` | product "Service Delivery Platform" (`oracle.sdp.messaging`). Fixes CVE-2026-83151 / -83000 … -82997 (260827), -60860 … -60865 (260722), -60374 … -60501 (260708) – UMS rows of earlier advisories, not in section 4. Also Bug 39856242 (NPE while applying the previous UMS patch 39703215) |
| **39726402** LibOVD BP 12.2.1.4 (14-Aug-26) | `39726402/`: `opatch apply` | OPatch ≥ 13.9.4.2.13; all processes stopped. The README does **not** mention the predecessor **34065178** – the BP contains its fix (Bug 33903365 "FMW consoles fail after applying JDK 1.8.0_331 or later"), so OPatch should treat 34065178 as a subset and roll it back itself (**assumption** – `opatch prereq CheckConflictAgainstOHWithDetail` first, stop on a real conflict) | `opatch lspatches`, start – no further step | `opatch rollback -id 39726402` (then 34065178 would be missing again – with JDK ≥ 8u331 the consoles fail: re-apply it or restore) | must be in the home **before the first start with JDK 8u511** – the JDK 8u331+ fix of the FMW consoles. Bug list: 20812896, 32305678, 33368783, 33545965, 33762450, 33903365, 34113169, 39272755 |

### 3.4 Forms & Reports 12.2.1.19

| Patch | Description | KA1182 release | Note |
|---|---|---|---|
| **39888613** | Oracle Forms QPR for 12.2.1.19 | Sep 2026 | further recommendations: KA204 |
| **39600813** | Oracle Reports Developer QPR for 12.2.1.19 | Aug 2026 | |
| 39425385 | DB Client Update 19.31 for FMW | Jul 2026 | FMW-specific DB client (based on 19.30), recommended for all security fixes, list: KB850150 |
| **39951739** | PERL Security Patch Update for FMW 12.2.1.4.0 | Oct 2026 | needs DB client for FMW **19.29 or later** – apply after 39425385 |
| KB243716 | SQL Developer installed with Forms & Reports 12.2.1.19: CVE-2021-4104 | Jan 2022 | upgrade to at least 21.4.2, not higher than 21.4.3 |

#### 3.4a From the READMEs (read 2026-10-23)

| Patch | Method | Before | Post-install | Rollback | Notes |
|---|---|---|---|---|---|
| **39888613** Forms QPR 12.2.1.19 (29-Aug-26) | ZIP `p39888613_1221190_Linux-x86-64.zip` (platform patch, not Generic); `39888613/`: `opatch apply` | all processes stopped; OPatch 13.9.4.2.x; `make`, `ld`, `ar`, `nm` in `PATH` (OPatch relinks `frmweb` / `dejvm` itself) | `opatch lspatches`, start – no own step; **check the OPatch log for `make` errors** ("OPatch succeeded" alone proves nothing) | `opatch rollback -id 39888613` | **Order: Forms QPR before Reports QPR.** On glibc ≥ 2.34 (OL9) the Reports QPR rebuilds `lib/libzrc.so.0` against glibc 2.34; a later Forms relink against the glibc 2.28 stubs fails with rc=73 and OPatch's own restore can fail too – MOS **KB873815** (Bug 38892485, no fix yet), seen live on 14.1.2 / OL9 (2026-10-14); for 12.2.1.19 **assumption** (same `genshlib` mechanism) – check `ldd --version` on the customer host. Notable fixes: 37641150 (input / output values removed from Forms trace files), 36442524 (linefeed in the Forms URL breaks SSO), 37464441 / 37623466 (FSAL through a proxy / with `restrictedURLparams=ALL`), 35687821 (PL/SQL error 422 after the upgrade to 12.2.1.19), 36945810 / 38098803 (FRM-93652) |
| **39600813** Reports Developer QPR 12.2.1.19 (Linux README 08-Jul-26, Solaris README 27-Aug-26) | **platform ZIP – take `p39600813_1221190_Linux-x86-64.zip`**: the same patch number exists per platform – easy to pick the wrong variant on MOS. **The two READMEs differ:** both list the same 14 named bugs, but the Solaris-64 README (27-Aug) has 20 "Fix for Bug 39375295 … 39375343" entries, the Linux-x86-64 README (08-Jul) only **39375343** – unnamed entries of this kind are usually security fixes. Either a README difference or the Linux build predates them: after the apply check `opatch lsinventory -bugs_fixed \| grep 393753`; if they are missing, ask Oracle (open point 9). `39600813/`: `opatch apply` | as the Forms QPR; **after** the Forms QPR (KB873815) | `opatch lspatches`, start; check the OPatch log for `make` errors – OPatch relinks the Reports binaries and rebuilds `libzrc.so` (`zrcsharedlib`) itself, no own step in the README | `opatch rollback -id 39600813` | notable fixes: 37756029 (encrypted values such as passwords in `cgicmd.dat`), 36434214 (umlauts in `DESNAME` → REP-56093 with UTF8), 35363833 (e-mail distribution via Office365 SMTP with STARTTLS), 33008149 (Reports Server slow to finish jobs), 37595589 (REP-52275 in `showjobs`), 35444503 (job status repository on ADB) |
| **39425385** DB Client 19.31 Update for FMW (21-Jul-26) | platform ZIP `p39425385_122140_Linux-x86-64.zip`; `39425385/`: `opatch apply` | the home must already have the **19c** client ("Database Client 19c 19.14 and higher" – true for 12.2.1.19, named in the README); OPatch ≥ 13.9.4.2.13; `opatch` + `unzip` in `PATH`; all processes stopped; **roll back first if present: one-offs 35037811, 34976606, 35522383** (`opatch rollback -id …`) | start – the OID relink (`ins_ldap.mk`) and the AIX one-off 34976606 do not apply here | `opatch rollback -id 39425385`, restart all servers | fixes CVE-2026-24400 (19.31); full list KB850150. Apply it **before** PERL (needs DB client ≥ 19.29) and before the QPRs, so their relinks of `frmweb` / the Reports binaries use the 19.31 client libraries (order proven live on 14.1.2: DB RU in the SPB → PERL → QPRs – **assumption** for 12.2.1.19) |
| **39951739** PERL SPU for FMW 12.2.1.4.0 (03-Sep-26) | platform ZIP `p39951739_122140_Linux-x86-64.zip`; `39951739/`: `opatch apply` | **OPatch ≥ 13.9.4.2.17**; all processes stopped. The README does **not** name the DB client ≥ 19.29 prerequisite – only KA1182 does; fulfilled by applying 39425385 first | `opatch lspatches`, start – no further step | `opatch rollback -id 39951739` | **confirmed:** single fix CVE-2026-4176 (Perl, 9.8, Bug 39400045) |

### 3.5 Oracle HTTP Server 12.2.1.4 colocated (only if OHS is in the home)

| Patch | Description | KA1182 release | Note |
|---|---|---|---|
| 40005842 | OHS DB19c Bundle Patch 12.2.1.4.260910 | Oct 2026 | apply together with the OSS BP and the DB client (collaborative fixes); post-install KB187736 |
| 39567777 | OSS 19c BP 12.2.1.4.260616 | Jul 2026 | same patch as in 3.2 |
| 39114058 | OAM WebGate DB19c BP 12.2.1.4.260323 | Apr 2026 | |
| 38098858 + 38832179 | LIBDMS2 SPU 12.2.1.4.260120 + LIBIAU SPU 12.2.1.4.260120 | Jan 2026 | Linux only |

#### 3.5a From the OHS READMEs (read 2026-10-23)

| Patch | Method | Before | Post-install | Rollback | Notes |
|---|---|---|---|---|---|
| **40005842** OHS (Native) DB19c BP 12.2.1.4.260910 (10-Sep-26) | ZIP `p40005842_122140_Linux-x86-64.zip`; `40005842/`: `opatch apply` | only for a home whose DB client was upgraded to **19c** (KB585169 – true for 12.2.1.19); OPatch ≥ 13.9.4.2.13; **collaborative patches** per KB187736: OSS 19c BP 39567777 (in the SPB) and the DB client (OHS uses the NZ libraries of the DB 19 client RU since Bug 37569298) → apply **after** step 8; stop everything **including the OHS instance** (`ohs1`) | **MOS KB187736** "Cumulative README Post-Install Steps for OHS 12.2.1.4 Bundle Patches" – may contain configuration steps: read before the window; start WLS + OHS | `opatch rollback -id 40005842`, reverse the post-install steps | **confirmed:** CVE-2026-87347 / -87346 / -91419 / -91473 (all four OHS rows of section 4). Bugs 39902419 / 39901639 / 39901695: the **security hardening of the July and August 2026 CSPU fixes is switched OFF by default** via flags (HTTP header stripping separately) – to get it, enable the flags explicitly (assumption: documented in KB187736). Cumulative back to 221127 → for the never patched `ohs1` four years of fixes at once, incl. 34646873 "remove deprecated ciphers from OHS default configuration" – test clients with old ciphers |
| **39114058** OAM WebGate DB19c BP 12.2.1.4.260323 | Linux x86-64, 106.7 MB, classification Security; **no README** | component `oracle.oamclient.webgate.ohs` is in the home → KA1182 applies it; whether `ohs1` actually uses WebGate (OAM SSO) is open | unknown – check the README inside the ZIP after download | `opatch rollback -id 39114058` | point 15 |
| **38098858** LIBDMS2 SPU 12.2.1.4.260120 (bundle, 03-Jul-25) | ZIP `p38098858_122140_Linux-x86-64.zip`; `opatch apply` | OPatch 13.9.4.x; conflict prompt → `n`, merge patch | none | `opatch rollback -id 38098858`, then restart AdminServer + all managed servers | tracking bug 37564963 |
| **38832179** LIBIAU SPU 12.2.1.4.260120 (09-Jan-26) | ZIP `p38832179_122140_Linux-x86-64.zip`; `opatch apply` | all processes stopped | `opatch lspatches` | `opatch rollback -id 38832179` | product "Oracle Platform Security for Java", bug 37616934 |

#### 3.5b KB187736 – post-install steps of the OHS bundle patches (read 2026-10-23)

MOS **KB187736** (updated 2026-10-20) is the cumulative extension of the OHS
README. It is cumulative: an OHS that is patched **for the first time** (the
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

## 4. Why: CVEs of the CPU October 2026 for a 12.2.1.4 home

From the Fusion Middleware risk matrix (rows with 12.2.1.4.0 in "Supported
Versions Affected", products of a Forms & Reports home). The matrix lists
only CVEs **new** in this cycle; earlier ones are covered by the cumulative
patches above. "Expected vehicle" = the KA1182 patch whose component
matches – Oracle does not publish the exact CVE → patch mapping.

| CVE | Product / component | Protocol | Remote w/o auth | CVSS 3.1 | Expected vehicle |
|---|---|---|---|---|---|
| CVE-2026-83399 | WebLogic Server / Core | T3, IIOP | yes | **9.8** | WLS SPB 40129641 (PSU 40069416) |
| CVE-2026-91323 | WebLogic Server / Core | HTTP | yes | **9.8** | WLS SPB / PSU |
| CVE-2026-87302 | WebLogic Server / Core | HTTP | yes | 9.1 | WLS SPB / PSU |
| CVE-2026-91502 | WebLogic Server / Core | TLS | yes | 7.3 | WLS SPB / PSU |
| CVE-2026-4176 | Oracle Fusion Middleware / Thirdparty Jars (Perl) | HTTP | yes | **9.8** | PERL SPU 39951739 – **confirmed** (README) |
| CVE-2026-47065 | Middleware Common Libraries / Apache Mina | HTTP | yes | **9.8** | Third-Party BP 39988961 (in the SPB) |
| CVE-2026-41855 | Middleware Common Libraries / Spring Framework | HTTP | yes | 8.1 | Third-Party BP |
| CVE-2026-12817 / 2025-7962 / 2026-101515 | WebLogic Server / Thirdparty Jars (Bouncy Castle 8.6, Jakarta Mail 7.5, other 5.9) | HTTPS / SMTP / HTTP | yes | 5.9 – 8.6 | Third-Party BP |
| CVE-2026-49844 | Middleware Common Libraries / Log4j | HTTP | yes | 5.9 | Third-Party BP |
| CVE-2026-91617 / 91616 | Middleware Common Libraries / RDA | None / HTTP | no / yes | 5.5 / 3.7 | RDA 39646867 (in the SPB) |
| CVE-2026-56741 | Coherence / Thirdparty Jars (jline) | TCP | yes | 7.5 | Coherence CP33 39984205 (in the SPB) |
| CVE-2026-91467 | Fusion Middleware Control / Framework | None | no | 6.6 | FMW Control BP 39995014 – **confirmed** (README) |
| CVE-2026-91318 / 91319 / 91317 / 87334 / 91320 / 91322 | JDeveloper / ADF runtime components | HTTP / SOAP / None | partly | 3.3 – 6.5 | ADF BP 40050071 – **confirmed** (bug list of the README) |
| CVE-2026-8763 / 101520 / 91776 / 59889 | NextGen OUI Framework (Bouncy Castle 9.1, jackson-databind …) | HTTP(S) | mostly | 6.5 – 9.1 | OPatch 13.9.4.2.25 – **confirmed for CVE-2026-91776** (OPatch README, Bug 40012934), the others assumption |
| CVE-2026-87347 / 91419 / 91473 / 87346 | Oracle HTTP Server (OSSL module 9.6 / 7.8, web listener 7.8, proxy plug-in for OHS 8.7) | HTTP / None | partly | 7.8 – 9.6 | OHS BP 40005842 – **confirmed** (README); only if OHS is in the home – the customer has `ohs1` |
| CVE-2026-83379 / 87300 | WebLogic Proxy Plug-In for third-party web servers | HTTP | yes | 8.7 | Proxy Plug-In tab – only for Apache/IIS as proxy |

Not relevant for a Forms & Reports home: Oracle Access Manager
(authentication engine = OAM server), SOA, OSB, WebCenter, ODI, OIM.
Oracle Forms and Oracle Reports themselves have **no** row in the CPU
October 2026.

Java SE (CPU Oct 2026 risk matrix): Java 8 up to **8u503** affected (fix:
8u511); Security Alert CVE-2026-91403 (JSSE, CVSS 9.1): 8u511 of the CPU
affected as well (fix: alert build, section 3.1 / 5).

---

## 5. Client side: the JRE of the Forms users (CVE-2026-91403)

The Forms client (Java Web Start or the standalone launcher FSAL) is a
**TLS client** that uses Java's JSSE – the alert concerns exactly this side.
With WebUtil (CLIENT_HOST, file transfer, JACOB/OLE) a manipulated session
can act on the PC with the user's rights. Background:
[forms_runtime_architecture.md §1.1/§1.2](../../80-FMW-Architecture/forms_runtime_architecture.md#11-where-tls-is-spoken--and-who-uses-javas-jsse),
[forms_jakob_webutil.md §10.1](../../80-FMW-Architecture/forms_jakob_webutil.md#101-what-the-session-can-do-on-the-client--threat-model).

| Item | Recommendation |
|---|---|
| Patch | **40186686** – JRE 8 Update 511, alert build (CPU426) = `1.8.0_511-b26`. Platform = the **bitness the clients use today** (see below) – the WebUtil DLLs (JACOB etc., `install.syslib` in `webutil.cfg`) must match the JRE bitness |
| Current state (2026-10-22) | Software deployment rolls out a private JRE `1.8.0_241-b07` (January 2020), **32-bit** ("Client VM", under `Program Files (x86)`) – six years of Java security fixes behind, not only the alert. Either the 32-bit (Windows x86) build of 40186686, or a planned switch to 64-bit **together** with x64 WebUtil/JACOB DLLs |
| Gap 8u241 → 8u511 | Oracle tightened the defaults in between: TLS 1.0/1.1 disabled (TLS 1.2+ needed at the web server in front of Forms), SHA-1-signed JARs and weak keys rejected. Test the own signed jars (WebUtil, JACOB, customer jars: signature algorithm, key length, timestamp, certificate expiry) and the TLS setup of the web server with the new JRE before the rollout |
| Not | 18143322 ("JDK 8 latest") – still the CPU build on 2026-10-22, and a JDK where a JRE is enough |
| Java version | stay on Java 8 for Java Web Start – `javaws` does not exist from Java 11 on (with 11+ only FSAL works) |
| Verification | `java -version` → `1.8.0_511-bNN`, compare the build with the README of 40186686; without starting Java: the `release` file of the JRE or the file version of `bin\java.exe` (useful for an inventory via the software deployment) |
| Certificates | test whether the trust of the Forms jar signature survives the update: a certificate in the JRE's `cacerts` is lost when the JRE is replaced, the user's deployment trust store usually stays |
| Distribution | Private JRE as a folder (ZIP / file copy by the software deployment) vs. the `.exe` installer: the installer also registers in the registry (Java Control Panel, system-wide deployment config, `.jnlp` association for Web Start). A copied folder has none of that – the start script / launcher must call its `bin\javaw`/`javaws` explicitly, and certificates belong in that JRE's `lib\security\cacerts` (replaced with every update → re-import in the package) or in a deployment trust store referenced by `deployment.properties`. Keep the existing method and only swap the folder, then test |
| Licence | the patch README demands a Java SE subscription; Java used **only** to run an Oracle product is covered by the exception of MOS Doc ID 1557737.1 – confirm the exact wording for the Forms client JRE; other Java programs on the same PCs are not covered |

---

## 6. Order of work (summary)

1. Section 1: inventory, versions, DB check; back up the home + inventory.
2. Stop everything; JDK 8 alert build (3.1).
3. OPatch 13.9.4.2.25, then WLS SPB 40129641 (3.2) and post-install KB694158.
4. FMW Infrastructure bundles (3.3).
5. DB client 19.31 (roll back the one-offs 35037811 / 34976606 / 35522383 first) → PERL → Forms QPR → Reports QPR (3.4a: Forms before Reports, KB873815); SQL Developer if used.
6. OHS bundle set (3.5 / 3.5a: 40005842, 39114058, 38098858, 38832179) – required at the customer (`ohs1`); after step 5 (collaborative with DB client + OSS BP); post-install KB187736, decide on the hardening flags.
7. Start, smoke test (Forms login, a report via rwservlet), `opatch lspatches` into the documentation.
8. Client JRE rollout (5) – test on a few PCs first.

---

## 7. Open points for the customer

| # | Question | Answer |
|---|---|---|
| 1 | Output of `viewInventory.sh` / `opatch lspatches` – which of the patches above are already installed? | received 2026-10-23 – none of the CPU patches; OPatch 13.9.4.2.11; see 1a |
| 2 | Is OHS (and WebGate) in the Forms & Reports home, or a separate OHS / Apache in front? | OHS in the home and configured (system component `ohs1`) – 3.5 applies (collector 2026-10-23, 1a) |
| 3 | Which JDK runs WebLogic (path, version, build)? | |
| 4 | Client Java: version/build, 32/64-bit, how is it distributed (software deployment, ZIP with `JAVA_HOME` in a start script)? | |
| 5 | How are the jar-signing certificates trusted on the clients (`cacerts`, deployment trust store, GPO)? | |
| 6 | Extended Support contract for 12.2.x after December 2026? | |
| 7 | Maintenance window and test environment for the patch run? | |
| 8 | OS release and glibc version (`cat /etc/os-release`, `ldd --version`) – glibc ≥ 2.34 means the Forms/Reports relink issue of KB873815 (3.4a) | Oracle Linux 8.9, glibc 2.28 – KB873815 does not apply (1a) |
| 9 | (for Oracle) Reports QPR 39600813: the Linux-x86-64 README (08-Jul-26) lists only 39375343 of the 20 "Fix for Bug 39375295 … 39375343" entries of the Solaris README (27-Aug-26) – are those fixes in the Linux build? Check after the apply (`opatch lsinventory -bugs_fixed`), else SR | |
| 10 | One-offs 34290481 and 36475988 in the home – purpose? (MOS lookup / customer); check them in the conflict check of each bundle, a conflict means a merge patch from Support | 36475988 = Forms bundle one-off of April 2024, superseded by QPR 39888613; 34290481 still open (1a) |
| 11 | Is the **Reports** component in this home although Reports does not run on this server? `opatch lsinventory -details \| grep -i reports` – if yes: apply the Reports QPR anyway (binaries on disk) and keep "Forms before Reports"; if no: OPatch skips 39600813 ("none of the components") | yes – Reports runs on this machine (`rwserver` + engines), QPR required (1a) |
| 12 | Do the inventory logs of 1a come from the **production** Forms server (not a temporary test machine)? Hostname, domain, uptime, running servers, age of the home | **test machine** (confirmed 2026-10-23); production collector run pending the customer release |
| 13 | Second machine with the same layout: role (production / test / second node)? Same patch level – `opatch version`, `opatch lspatches`, `viewInventory.sh` of both for comparison; which one is patched first (test first) | |
| 14 | Reports engines run with the JDK **inside** the home (`oracle_common/jdk` 1.8.0_341) – not reached by the `/oracle/java/jdk` update. Patch / supported procedure for 12.2.1.19 (KA1182, MOS search "oracle_common/jdk update Forms Reports 12.2.1.19") or a supported way to point the engine JVM to `/oracle/java/jdk`? | |
| 15 | OHS `ohs1`: is OAM WebGate (SSO) configured? Is there a load balancer in front (decides `WLStripForwardedForHeader`)? Does Forms use WebSocket? Current `SSLCipherSuite`, default `index.html` still served? (KB187736 read – 3.5b; the collector now also gathers the OHS configuration) | |
| 16 | Web tier: does OS Apache or Nginx serve Forms / Reports (ports 80 / 443)? Does Apache load the WebLogic plug-in `mod_wl_24` (then the Proxy Plug-In tab of KA1182 + KB187736 WL* directives)? Next collector run (≥ 2026-10-23.4) | |
| 17 | Repository DB `REPOS` (19.32, same host): DB RU 19.33 for CVE-2026-75803 (9.8) – who patches the database, when? | |
