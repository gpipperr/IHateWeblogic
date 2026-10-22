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

### 3.3 FMW Infrastructure 12.2.1.4 bundle patches

KA1182: "if only applying the WebLogic Server SPB or individual patches …
apply the additional patches" – **none of them is in the WLS SPB**. The
components come with every FMW infrastructure (also with Forms & Reports).

| Patch | Description | KA1182 release | Note |
|---|---|---|---|
| 40050071 | ADF Bundle Patch 12.2.1.4.260920 | Oct 2026 | together with 34809489 |
| 34809489 | Fix for CVE-2021-42575 | Jul 2023 | required with any ADF bundle patch, if not yet applied |
| 40022647 | WebCenter Core BP 12.2.1.4.260914 | Oct 2026 | installed even without WebCenter products |
| 40047683 | OWSM Bundle Patch 12.2.1.4.260918 | Oct 2026 | includes the fix of Security Alert CVE-2026-21992 (Mar 2026) |
| 39995014 | FMW Control BP 12.2.1.4.260908 | Oct 2026 | Enterprise Manager on the AdminServer |
| 40059055 | OAMCLIENT Bundle Patch 12.2.1.4.260922 | Oct 2026 | |
| 39979941 | OPSS Bundle Patch 12.2.1.4.260904 | Sep 2026 | |
| 39939504 | UMS Bundle Patch 12.2.1.3.260827 | Sep 2026 | UMS 12.2.1.3 is installed in a 12.2.1.4 home |
| 39726402 | LibOVD Bundle Patch 12.2.1.4 | Aug 2026 | replaces Patch 34065178 (needed after JDK 8u331); required on all installations except WLS standalone |

### 3.4 Forms & Reports 12.2.1.19

| Patch | Description | KA1182 release | Note |
|---|---|---|---|
| **39888613** | Oracle Forms QPR for 12.2.1.19 | Sep 2026 | further recommendations: KA204 |
| **39600813** | Oracle Reports Developer QPR for 12.2.1.19 | Aug 2026 | |
| 39425385 | DB Client Update 19.31 for FMW | Jul 2026 | FMW-specific DB client (based on 19.30), recommended for all security fixes, list: KB850150 |
| **39951739** | PERL Security Patch Update for FMW 12.2.1.4.0 | Oct 2026 | needs DB client for FMW **19.29 or later** – apply after 39425385 |
| KB243716 | SQL Developer installed with Forms & Reports 12.2.1.19: CVE-2021-4104 | Jan 2022 | upgrade to at least 21.4.2, not higher than 21.4.3 |

### 3.5 Oracle HTTP Server 12.2.1.4 colocated (only if OHS is in the home)

| Patch | Description | KA1182 release | Note |
|---|---|---|---|
| 40005842 | OHS DB19c Bundle Patch 12.2.1.4.260910 | Oct 2026 | apply together with the OSS BP and the DB client (collaborative fixes); post-install KB187736 |
| 39567777 | OSS 19c BP 12.2.1.4.260616 | Jul 2026 | same patch as in 3.2 |
| 39114058 | OAM WebGate DB19c BP 12.2.1.4.260323 | Apr 2026 | |
| 38098858 + 38832179 | LIBDMS2 SPU 12.2.1.4.260120 + LIBIAU SPU 12.2.1.4.260120 | Jan 2026 | Linux only |

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
| CVE-2026-4176 | Oracle Fusion Middleware / Thirdparty Jars (Perl) | HTTP | yes | **9.8** | PERL SPU 39951739 |
| CVE-2026-47065 | Middleware Common Libraries / Apache Mina | HTTP | yes | **9.8** | Third-Party BP 39988961 (in the SPB) |
| CVE-2026-41855 | Middleware Common Libraries / Spring Framework | HTTP | yes | 8.1 | Third-Party BP |
| CVE-2026-12817 / 2025-7962 / 2026-101515 | WebLogic Server / Thirdparty Jars (Bouncy Castle 8.6, Jakarta Mail 7.5, other 5.9) | HTTPS / SMTP / HTTP | yes | 5.9 – 8.6 | Third-Party BP |
| CVE-2026-49844 | Middleware Common Libraries / Log4j | HTTP | yes | 5.9 | Third-Party BP |
| CVE-2026-91617 / 91616 | Middleware Common Libraries / RDA | None / HTTP | no / yes | 5.5 / 3.7 | RDA 39646867 (in the SPB) |
| CVE-2026-56741 | Coherence / Thirdparty Jars (jline) | TCP | yes | 7.5 | Coherence CP33 39984205 (in the SPB) |
| CVE-2026-91467 | Fusion Middleware Control / Framework | None | no | 6.6 | FMW Control BP 39995014 |
| CVE-2026-91318 / 91319 / 91317 / 87334 / 91320 / 91322 | JDeveloper / ADF runtime components | HTTP / SOAP / None | partly | 3.3 – 6.5 | ADF BP 40050071 |
| CVE-2026-8763 / 101520 / 91776 / 59889 | NextGen OUI Framework (Bouncy Castle 9.1, jackson-databind …) | HTTP(S) | mostly | 6.5 – 9.1 | OPatch 13.9.4.2.25 (assumption) |
| CVE-2026-87347 / 91419 / 91473 / 87346 | Oracle HTTP Server (OSSL module 9.6 / 7.8, web listener 7.8, proxy plug-in for OHS 8.7) | HTTP / None | partly | 7.8 – 9.6 | OHS BP 40005842 – only if OHS is in the home |
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
5. Forms/Reports QPRs, DB client 19.31, PERL (3.4); SQL Developer if used.
6. OHS bundle set (3.5) if OHS is in the home; post-install KB187736.
7. Start, smoke test (Forms login, a report via rwservlet), `opatch lspatches` into the documentation.
8. Client JRE rollout (5) – test on a few PCs first.

---

## 7. Open points for the customer

| # | Question | Answer |
|---|---|---|
| 1 | Output of `viewInventory.sh` / `opatch lspatches` – which of the patches above are already installed? | |
| 2 | Is OHS (and WebGate) in the Forms & Reports home, or a separate OHS / Apache in front? | |
| 3 | Which JDK runs WebLogic (path, version, build)? | |
| 4 | Client Java: version/build, 32/64-bit, how is it distributed (software deployment, ZIP with `JAVA_HOME` in a start script)? | |
| 5 | How are the jar-signing certificates trusted on the clients (`cacerts`, deployment trust store, GPO)? | |
| 6 | Extended Support contract for 12.2.x after December 2026? | |
| 7 | Maintenance window and test environment for the patch run? | |
