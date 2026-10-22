# Own Java Runtime for the Forms Client – jlink, Theory and Practice

How to build a small, self-contained Java runtime for the Oracle Forms
14.1.2 client (Forms Standalone Launcher, FSAL) with `jdeps` and `jlink`, why
this works, and what was tested on the test host.

Markers: **documented** (source in section 9), **confirmed (live)** (tested
on the test host, date given), **assumption** (not proven yet).

Related:
[forms_runtime_architecture.md](forms_runtime_architecture.md) (client ↔
`frmweb`, TLS, timeout chain),
[forms_jakob_webutil.md](forms_jakob_webutil.md) (WebUtil, JACOB, signing,
client distribution),
[09-Install/docs/40-forms_client_distribution.md](../09-Install/docs/40-forms_client_distribution.md)
(the concept that ships this runtime to the clients).

---

## 1. Why an own runtime

| Fact | Consequence |
|---|---|
| Since Java 11 Oracle ships **no separate JRE**, only the JDK (~300 MB on Windows) | a "JRE" for the clients has to be made |
| Java Web Start (`javaws`) was removed with Java 11 | Forms 14.1.2 clients run with **FSAL**: "FSAL requires Oracle Java version Java 17 or newer … only available in 64-bit Java Development Kit (JDK) distributions" (**documented**) |
| "Forms also supports using a custom JRE distribution that you create using Oracle Java version 17 or newer … jdeps … jlink … jpackage" (**documented**, FSAL "Custom JRE Support") | an own runtime is a supported Forms client configuration |
| JDK 21 updates exist only on MOS since the NFTC ended (September 2026), every update is a full distribution | the runtime is rebuilt from the MOS patch at every Java CPU / Security Alert |
| The client JRE is the TLS client of the Forms session (JSSE) – CVE-2026-91403 | the runtime must follow the Java patch cycle quickly ([forms_runtime_architecture.md §1.2](forms_runtime_architecture.md#12-threat-model-of-a-client-side-tls-jsse-flaw)) |

A runtime built for FSAL contains only the modules Forms needs: about
60–70 MB instead of ~300 MB, a smaller attack surface (no compiler, no
`jshell`, no debugging agents), and our own trust store inside.

---

## 2. Theory – modules, JMOD files, run-time images

### 2.1 The module system (Java 9+)

Java 9 split the JDK into **modules** (JEP 200/261, **documented**). A module
has a name (`java.base`, `java.desktop`, …), declares which modules it
`requires`, which packages it `exports`, and which **services** it `uses`
or `provides`. The JDK 21 used here consists of about 70 modules.

```
  java.base                  always: lang, util, io, net, security, TLS (JSSE)
     ^
     |  requires
  java.desktop  ──>  java.datatransfer, java.prefs, java.xml   (AWT/Swing – the Forms UI)
  java.net.http              HTTP client
  java.management            JMX
  jdk.jsobject               JavaScript integration (frmall.jar)
  …
  service providers (found only at run time through ServiceLoader):
  jdk.crypto.ec       elliptic-curve crypto (ECDHE cipher suites)
  jdk.crypto.mscapi   Windows key store (Windows-ROOT / Windows-MY)
  jdk.localedata      locale data beyond en (e.g. German formats)
  jdk.charsets        extended character sets
```

### 2.2 JMOD files and run-time images

- A JDK ships every module twice: compiled into the run-time image
  (`lib/modules`, one jimage file) and as a **JMOD file** in `jmods/` – the
  link-time format with classes, native libraries (`.dll` / `.so`),
  commands (`java.exe`, `keytool`) and configuration of that module
  (JEP 261 / 282, **documented**).
- A **run-time image** (JEP 220, **documented**) has a fixed layout:
  `bin/` (launchers), `conf/` (`security/java.security` …), `lib/`
  (`modules`, native libraries, `security/cacerts`), `legal/` and the
  `release` file (`JAVA_VERSION`, `MODULES`).

### 2.3 jlink – the linker

`jlink` (JEP 282, **documented**) resolves a set of root modules
(`--add-modules`) and everything they `require` from the module path and
writes a new run-time image (`--output`). Plugins reduce it further:
`--strip-debug`, `--no-header-files`, `--no-man-pages`, `--compress`.

```
  JMOD files of the TARGET platform              jlink of the BUILD host
  (jdk-21.0.13.0.2_windows-x64/jmods/*.jmod)     ($JDK_HOME/bin/jlink, Linux)
                 \                                  /
                  \--  --module-path      --add-modules java.base,java.desktop,…
                                  |
                                  v
                     run-time image for the TARGET platform
                     bin/java.exe, javaw.exe, keytool.exe
                     lib/modules (only the selected modules)
                     lib/security/cacerts   <- trust store, editable
                     release: JAVA_VERSION="21.0.13.0.2"
```

The native parts come from the JMOD files, not from the `jlink` that runs.
A Linux `jlink` can therefore build a Windows runtime from the Windows
JMOD files (**confirmed (live)**, see section 4). The version of
`jlink` and of the JMOD files may differ within the same feature release
here – 21.0.12.1 linked 21.0.13.0.2 (**confirmed (live)**). Whether this
always holds across feature releases is not documented in the sources
used (**assumption**: keep `jlink` and JMOD files in the same feature
release, e.g. 21).

### 2.4 jdeps and its blind spot: services

`jdeps --print-module-deps` analyses the class files of a jar and lists
the modules it references (**documented**, `jdeps` manual). It sees
**static** references only. Providers loaded through `ServiceLoader` at run
time – crypto, locale data, character sets – are invisible to it. Two ways
around:

- add the provider modules explicitly (chosen here – small, predictable), or
- `jlink --bind-services` ("Link service provider modules and their
  dependencies", **documented**) – pulls in every provider of every used
  service, and the image grows considerably.

Typical symptoms of a missing provider module (**assumption** from the
module contents, to be confirmed if it ever happens): TLS handshake fails
with modern ECDHE-only servers (`jdk.crypto.ec` missing), dates / numbers
formatted in English only (`jdk.localedata`), `Windows-ROOT` key store type
unknown (`jdk.crypto.mscapi`).

### 2.5 Outlook – JEP 493 (JDK 24)

JEP 493 lets `jlink` link from the run-time image itself, without JMOD
files, to make the JDK about 25 % smaller. It "must be enabled when the JDK
is built; it will not be enabled by default, and some JDK vendors may choose
not to enable it" (**documented**). Linking from the running image can only
produce images of **that** platform – cross-building for Windows on Linux
still needs the Windows JMOD files. JDK 21 (used here) ships `jmods/`
(**confirmed (live)**: 70 files in the Windows and 69 in the Linux JDK).
Whether later Oracle JDK releases still ship `jmods/`: check before moving
the clients to Java 25 (**assumption**).

---

## 3. The module list for Forms 14.1.2

`jdeps --ignore-missing-deps --print-module-deps --multi-release 21`
on the jars of `$ORACLE_HOME/forms/java/` (**confirmed (live)** 2026-10-22):

| Jar | Modules |
|---|---|
| `frmsal.jar` (FSAL) | `java.base, java.desktop, java.management, java.net.http` |
| `frmall.jar` (Forms client) | `java.base, java.desktop, java.net.http, jdk.jsobject` |
| `frmwebutil.jar` (WebUtil) | `java.base, java.desktop` |
| `jacob.jar` (JACOB) | `java.base` |

Added for run-time services and robustness:

| Module | Why |
|---|---|
| `jdk.crypto.ec` | ECDHE cipher suites (Nginx offers ECDHE first) |
| `jdk.crypto.mscapi` | Windows only – Windows certificate store (`Windows-ROOT`) |
| `jdk.charsets`, `jdk.localedata` | non-Latin-1 code pages, German date / number formats |
| `java.logging`, `java.naming`, `java.xml`, `java.prefs` | used by Swing / networking / configuration code paths |
| `jdk.unsupported` | `sun.misc.Unsafe` – used by some libraries |
| `jdk.zipfs` | zip file system provider |
| `jdk.accessibility` | Windows only – Java Access Bridge (screen readers) |

```
java.base,java.desktop,java.management,java.net.http,jdk.jsobject,
java.logging,java.naming,java.xml,java.prefs,jdk.crypto.ec,jdk.charsets,
jdk.localedata,jdk.unsupported,jdk.zipfs
  + Windows: jdk.crypto.mscapi,jdk.accessibility
```

Not included: compiler (`java.compiler`, `jdk.compiler`), `jdk.jshell`,
debugging / JFR / attach (`jdk.jdwp.agent`, `jdk.jfr`, `jdk.attach`),
`java.sql`. JavaFX is not part of the JDK; FSAL only needs it for
applications that use it ("Enabling JavaFX for Java 17+", FSAL
documentation).

---

## 4. Tests on the test host (2026-10-22)

### 4.1 Windows runtime, built on Linux – confirmed (live)

```bash
# source: MOS patch 35702194, platform 233P (04-oracle_pre_download.sh, client/jdk/)
unzip p35702194_2100_MSWIN-x86-64.zip jdk-21.0.13.0.2_windows-x64_bin.zip SHA256_VALUES
sha256sum jdk-21.0.13.0.2_windows-x64_bin.zip      # = value in SHA256_VALUES
unzip jdk-21.0.13.0.2_windows-x64_bin.zip -d win/

$JDK_HOME/bin/jlink \
    --module-path win/jdk-21.0.13.0.2/jmods \
    --add-modules <list of section 3, with the Windows modules> \
    --strip-debug --no-header-files --no-man-pages --compress=zip-6 \
    --output runtime-win
```

Result: 8 s, **61 MB**. `release`:

```
JAVA_VERSION="21.0.13.0.2"
MODULES="… 18 modules …"
```

`bin/` contains `java.exe`, `javaw.exe` (PE32+ x86-64, GUI subsystem) and
`keytool.exe`. Built with the Linux `jlink` 21.0.12.1. Whether it starts on
Windows is open: the Windows client test.

### 4.2 Linux runtime and a real Forms session – confirmed (live)

The same procedure with the Linux JMOD files of `$JDK_HOME`
(21.0.12.1, 14 root modules → 16 modules in the image): **69 MB**,
`java -version` works.

Root CA of the Nginx certificate into the runtime's trust store:

```bash
$JDK_HOME/bin/keytool -importcert -noprompt -alias ihw-root-ca \
    -file $ORACLE_BASE/admin/pki/ca/ca.crt \
    -keystore runtime/lib/security/cacerts -storepass changeit
```

Forms start with FSAL under Xvfb (no desktop on the server), through
Nginx / HTTPS:

```bash
xvfb-run -a runtime/bin/java -jar frmsal.jar \
    -url "https://<host>/forms/frmservlet?config=standaloneapp&form=test_form" \
    -t 30000 -cert_truststore java -showDetails 1
```

FSAL output (excerpt):

```
Using default TrustStore
Initiating secure connection to https://<host>/forms/frmservlet?config=standaloneapp&form=test_form
Detected Java version: 21.0.12.1
Downloading archive file https://<host>:443/forms/java/frmall.jar to cache subdirectory …
Forms Session ID is WLS_FORMS.formsapp.2
The connection mode is HTTPS.
Forms Applet version is 14.1.2.0
```

On the server a new `frmweb webfile=HTTP-0,standaloneapp` process started
for the session.

| Finding | Detail |
|---|---|
| TLS without any prompt | the CA in the runtime's `cacerts` + `-cert_truststore java` replaces FSAL's Certificate Importer and its user dialog |
| Module list sufficient | with `jdk.crypto.ec` the ECDHE handshake to Nginx works |
| FSAL cache in `java.io.tmpdir` | here `/tmp/frmsal/<host>/14.1.2.0/<hash>/frmall.jar` (2.4 MB) – not in `user.home`; on Windows `%TEMP%` (**assumption**) |
| Session lifetime after a hard client kill | `frmweb` keeps running until `FORMS_TIMEOUT` (default 15 min) expires – the documented timeout chain ([forms_runtime_architecture.md §4](forms_runtime_architecture.md#4-timeout-chain)) |

This is the first Forms session from a client on the test host – until
then only the server side (JNLP, `fsal.htm`, `frmsal.jar` reachable) was
verified.

---

## 5. Procedure (summary)

1. Download the JDK of the **target** platform from MOS (full
   distribution, no base + patch): Linux `226P`, Windows x64 `233P`
   (`04-oracle_pre_download.sh`, `client/jdk/<nr>/`).
2. Check the SHA-256 against `SHA256_VALUES`, extract the JDK ZIP
   (`jdk-<ver>_<platform>_bin.zip` / `.tar.gz`).
3. `jlink --module-path <target-jdk>/jmods --add-modules <list> … --output <dir>`
   with a `jlink` of the same feature release.
4. Import the CA of the Forms server certificate into
   `<dir>/lib/security/cacerts` (`keytool`, password `changeit`); for a
   public CA nothing to do.
5. Ship the image (ZIP) with `frmsal.jar` of **the same Forms server**
   ("version-specific", **documented**); start with
   `javaw -jar frmsal.jar -url "…config=standaloneapp" -cert_truststore java`.
6. Rebuild at every Java CPU / Security Alert and after the CA changes.

Automated as `09-Install/40-oracle_forms_client_bundle.sh` (planned, concept
[40-forms_client_distribution.md](../09-Install/docs/40-forms_client_distribution.md)).

---

## 6. Trust store inside the runtime

The usual advice "never import into a JRE's `cacerts`, the next Java update
loses it" is about a JRE installed and updated **independently** of the
certificates. Here the runtime is rebuilt for every update and the CA is
imported during the build – the trust is part of the artefact. Advantages:
no user prompt, no per-user `formstruststore`
(`C:\Users\<user>\Oracle\forms\formstruststore`, FSAL default, **documented**),
no `-autoImportCert` (which would silently trust whatever certificate a
manipulated connection presents).

---

## 7. Licence

The MOS JDK patches state that a Java SE subscription is required; Java
used only to run an Oracle product falls under MOS Doc ID 1557737.1. For a
Forms client runtime built from the JDK this is an **assumption** to be
confirmed with Oracle / the customer's licence management – the runtime is
meant for Forms only and served only to Forms users of the server.

---

## 8. Open points

- Windows client: start of the cross-built runtime, FSAL session, TLS via
  the bundled `cacerts`, JACOB / WebUtil (`frmwebutil.jar`, native DLLs)
  with the reduced module list.
- `Windows-ROOT` as trust store type (`jdk.crypto.mscapi`) as an
  alternative to the bundled `cacerts` – not tested.
- `fsalJavaVersion` in `formsweb.cfg` against the runtime version
  ([40-forms_client_distribution.md](../09-Install/docs/40-forms_client_distribution.md) §3.1).
- JMOD files in future Oracle JDK releases (JEP 493).

---

## 9. Sources

All checked 2026-10-22 (HTTP 200, title matches):

- JEP 220: Modular Run-Time Images – https://openjdk.org/jeps/220
- JEP 261: Module System – https://openjdk.org/jeps/261
- JEP 282: jlink: The Java Linker – https://openjdk.org/jeps/282
- JEP 493: Linking Run-Time Images without JMODs (JDK 24) – https://openjdk.org/jeps/493
- The jlink Command (JDK 21) – https://docs.oracle.com/en/java/javase/21/docs/specs/man/jlink.html
- The jdeps Command (JDK 21) – https://docs.oracle.com/en/java/javase/21/docs/specs/man/jdeps.html
- Oracle Forms 14.1.2 – Oracle Forms Standalone Launcher (requirements,
  Custom JRE Support, version-specific `frmsal.jar`, Certificate Importer,
  command-line arguments) –
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/working-forms/oracle-forms-standalone-launcher.html
- MOS CPU426 (Java SE Security Alert CVE-2026-91403, "each release is a
  full distribution") – see [00-patch-references.md](../09-Install/docs/00-patch-references.md)
