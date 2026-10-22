# Oracle Forms 14 – WebUtil and JACOB Architecture

Background for the WebUtil/JACOB step of `09-Install/14-oracle_setup_forms.sh`
(`docs/14-forms-detail-settings.md`, step 1).

---

## 1. What is JACOB?

JACOB (Java COM Bridge) is a Java-to-COM/ActiveX bridge for Microsoft Windows.
Oracle Forms uses JACOB for the OLE functions of WebUtil (`CLIENT_OLE2`), so a
Forms application can drive Microsoft Excel or Microsoft Word via COM
automation.

Oracle Forms 14.1.2 is preconfigured for **JACOB 1.21** (**documented**,
release notes; `webutil.cfg` names `jacob-1.21-*.dll` – **confirmed (live)**).
Oracle does not ship JACOB (LGPL license) – it has to be downloaded
separately.

## 2. Where to download JACOB

Oracle reference (Forms 14.1.2 release notes, lifecycle management):
<https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/releasenotes-fnr/lifecycle-management-information.html>

Download sources:

| Source | URL |
|---|---|
| GitHub releases (recommended) | <https://github.com/freemansoft/jacob-project/releases> |
| GitHub project page | <https://github.com/freemansoft/jacob-project> |
| Former SourceForge page | <https://sourceforge.net/projects/jacob-project/> |

Release `Root_B-1_21` (2024-04-01), asset `jacob-1.21.zip` (**confirmed
(live)** 2026-10-15 via the GitHub releases API and a download):

```
https://github.com/freemansoft/jacob-project/releases/download/Root_B-1_21/jacob-1.21.zip
SHA-256 23a006e84f41443e735cfc3d47f053b995b1454f4ed54c405e7f1e104ef2e073

jacob-1.21/jacob.jar            49846 bytes
jacob-1.21/jacob-1.21-x86.dll  195072 bytes
jacob-1.21/jacob-1.21-x64.dll  247296 bytes
jacob-1.21/LICENSE.TXT
```

The project publishes no checksum file – the SHA-256 above was computed
after the download. The DLL sizes match the `install.syslib` entries of
Oracle's `webutil.cfg` exactly (see §6).

## 3. What is WebUtil?

WebUtil is an Oracle extension for Forms that provides client-side functions,
although the application itself runs centrally on the Forms server.

Typical functions:

- access to local files on the client
- file upload / download (client ↔ application server / database)
- running local operating system commands
- access to environment variables
- reading client information
- OLE/COM automation (Word, Excel, …) – only this needs JACOB

WebUtil is part of Oracle Forms since 11g (before that a separate download).

## 4. Architecture

```
+---------------------------+
| Oracle Forms runtime      |
| (server, frmweb)          |
| webutil.pll               |
+-------------+-------------+
              |
              | HTTP(S) / Forms protocol
              v
+---------------------------+
| Forms Java client         |
| (Java Web Start / FSAL)   |
| frmwebutil.jar            |
+-------------+-------------+
              |
              | Java call
              v
+---------------------------+
| jacob.jar                 |
| JACOB bridge (Java part)  |
+-------------+-------------+
              |
              | JNI
              v
+---------------------------+
| jacob-1.21-x64.dll        |
| native part, Windows COM  |
+-------------+-------------+
              |
              | COM automation
              v
+---------------------------+
| Microsoft Word / Excel    |
| other COM objects         |
+---------------------------+
```

Forms 14.1.2 has no browser applet any more – the client runs with Java Web
Start or the Forms Standalone Launcher (FSAL). Everything below the server box
runs on the **Windows client**.

## 5. Technical flow

1. The Forms module calls a WebUtil function (e.g. `CLIENT_OLE2.create_obj`).
2. The PL/SQL library `webutil.pll` delegates the call to the Java bean on the
   client.
3. `frmwebutil.jar` runs in the Forms Java client.
4. For OLE calls WebUtil uses `jacob.jar`.
5. JACOB uses JNI (Java Native Interface) to call its native DLL.
6. The DLL talks to the Windows COM interface.
7. Word, Excel or other COM components are driven.

At the first WebUtil start the client downloads the native libraries listed in
`webutil.cfg` (`install.syslib.*`, see §6) from the server
(`/forms/webutil/win32|win64`) into
`<user home>\webutil\syslib\<server host>\win32|win64`.

## 6. Files

| File | Location on the server | Purpose |
|---|---|---|
| `webutil.pll` / `webutil.olb` | `$ORACLE_HOME/forms/` | PL/SQL library / object library (compile/attach in the Forms modules) |
| `frmwebutil.jar` | `$ORACLE_HOME/forms/java/` | Java client code (signed by Oracle) |
| `jacob.jar` | `$ORACLE_HOME/forms/java/` | Java part of the COM bridge – **not shipped** |
| `jacob-1.21-x86.dll` / `-x64.dll` | `$ORACLE_HOME/forms/webutil/win32/` / `win64/` | native part – **not shipped** |
| `d2kwut60.dll`, `JNIsharedstubs.dll` | `$ORACLE_HOME/forms/webutil/win32/` / `win64/` | WebUtil native helpers (shipped) |
| `webutil.cfg` | `$DOMAIN_HOME/config/fmwconfig/components/FORMS/instances/<forms instance>/server/` | WebUtil configuration (syslib list, transfer areas) |
| `formsweb.cfg` | `$DOMAIN_HOME/config/fmwconfig/servers/WLS_FORMS/applications/formsapp_14.1.2/config/` | `WebUtilArchive=` – the jars the client loads |
| `extensions.jnlp` | `$ORACLE_HOME/forms/java/` | additional jars for Java Web Start (`jacob.jar` entry shipped commented out) |

Oracle's default `webutil.cfg` (`$ORACLE_HOME/forms/templates/config/webutil.cfg`):

```
install.syslib.location=/webutil
install.syslib.location.0.0=/webutil/win32
install.syslib.location.0.1=/webutil/win64
install.syslib.location.client.0.0=webutil\syslib\$(SERVERHOST)\win32
install.syslib.location.client.0.1=webutil\syslib\$(SERVERHOST)\win64
# name|size|version|showDownloadDialog
install.syslib.0.0.7.1=jacob-1.21-x86.dll|195072|1.21|true
install.syslib.0.1.7.1=jacob-1.21-x64.dll|247296|1.21|true
install.syslib.0.0.9.1=JNIsharedstubs.dll|45056|1.0|true
install.syslib.0.1.9.1=JNIsharedstubs.dll|58368|1.0|true
install.syslib.0.0.9.2=d2kwut60.dll|81920|1.0|true
install.syslib.0.1.9.2=d2kwut60.dll|102400|1.0|true
```

Oracle's default `formsweb.cfg` section `[webutil]`:
`WebUtilArchive=frmwebutil.jar,jacob.jar`.

## 7. Oracle Forms 14 specifics

- According to the Oracle release notes Forms 14.1.2 is preconfigured for
  JACOB 1.21 (file names and sizes in `webutil.cfg`) – **documented** +
  **confirmed (live)**. With another version
  the `install.syslib.*` entries (name, size, version) must be adapted.
- `jacob.jar` from the release ZIP is **not signed** (no `META-INF/*.SF` /
  `*.RSA`, **confirmed (live)**); its manifest already carries `Permissions: all-permissions`,
  `Codebase: *`, `Trusted-Library: true`. Java Web Start runs only signed jars
  with all permissions – `jacob.jar` has to be signed with a code-signing
  certificate the clients trust (`jarsigner` from the JDK; Forms 14.1.2 ships
  no own signing script). Signing, certificates, verification, maintenance
  and distribution: sections 8–12.
- The size of the DLL is checked by WebUtil at download time – a DLL of a
  different build fails even with the same name (**documented** in the
  `webutil.cfg` comments: "Change size and version if necessary").

## 8. Signing – how Oracle intends it

```
   Oracle (vendor)                         Customer (you)
  +------------------------------+        +----------------------------------+
  | frmall.jar, frmwebutil.jar,  |        | jacob.jar, own jars (icons ...)  |
  | frmsal.jar ...               |        | - unsigned when downloaded       |
  | signed by "Oracle America"   |        | - sign with YOUR code-signing    |
  | (DigiCert code-signing CA,   |        |   certificate (jarsigner + TSA)  |
  |  timestamped)                |        |                                  |
  +--------------+---------------+        +----------------+-----------------+
                 |                                          |
       base.jnlp / webutil.jnlp                     extensions.jnlp
       (one signer per JNLP file)                   (component extension,
                 |                                   own signer allowed)
                 +--------------------+--------------------+
                                      v
                     Java client on the Windows PC
                     - Java Web Start: checks every signature against
                       the trusted signer / CA stores  -> run or block
                     - FSAL: no trust check by default (see 10)
```

- Oracle signs all **its** client jars and says so explicitly:
  "All Java JAR files provided by Oracle Forms that run on the user's machine
  are signed … It is further required that custom JAR files (those not
  provided by Oracle) also be properly signed with a trusted certificate.
  **Signing JARs not provided by Oracle is the customer's responsibility.**"
  (**documented**, Working with Oracle Forms 14.1.2, FSAL "Signed Code")
- "Using self-generated certificates is not recommended and should be
  avoided. Although using self-generated certificates may seem to function,
  support for this functionality may be removed from Java in the future."
  (**documented**, same section)
- Why a separate `extensions.jnlp`: "The JNLP 1.0 specification requires all
  JAR files used in a JNLP file to be signed by the same certificate …
  However, Java Web Start can use multiple JAR files signed by different
  certificates, by using the component extension mechanism and multiple JNLP
  files" (**documented**, Java Web Start FAQ). Oracle's jars (signer Oracle)
  stay in `base.jnlp` / `webutil.jnlp`; customer jars like `jacob.jar` go
  into `extensions.jnlp` (`<component-desc/>`, `<all-permissions/>`) –
  Oracle's note: "if the application uses custom jar files, for example
  jacob.jar … add these to the extensions.jnlp file" (**documented**, Forms
  14.1.2 "Java Web Start"; file content **confirmed (live)**).
- Oracle's own signature on the test host (**confirmed (live)**,
  `jarsigner -verify -verbose -certs`): signer `CN="Oracle America, Inc."`,
  chain `DigiCert Trusted G4 Code Signing RSA4096 SHA384 2021 CA1` →
  `DigiCert Trusted Root G4`; signer certificate valid until **2028-01-12**,
  **timestamped** by DigiCert (TSA certificate valid until 2031-11-10) – the
  signature stays valid after the signer certificate expires.
- Forms 14.1.2 ships **no** signing script (the old `sign_webutil.sh` of
  11g/12c is gone – **confirmed (live)**); signing = `jarsigner` of the JDK.

Signing in principle (`jarsigner`, **documented**, JDK 21 man page):

```bash
# keystore with the code-signing key + certificate chain (PKCS12)
jarsigner -keystore codesign.p12 -storetype PKCS12 \
          -tsa http://timestamp.<ca>.com \
          -digestalg SHA-256 \
          jacob.jar <alias>
jarsigner -verify -verbose -certs jacob.jar     # "jar verified." + chain + timestamp
```

- **Always with `-tsa`** (timestamp): without it the signature becomes
  invalid when the code-signing certificate expires → every client blocks
  the jar on that day.
- The jar's manifest has `Permissions: all-permissions`, `Codebase: *`,
  `Trusted-Library: true` – but only in the **per-entry section**
  `Name: com/jacob/`, not in the main section (**confirmed (live)**
  2026-10-17; the first version of this section overlooked that). Java reads
  these security attributes from the main section; `Permissions` is
  required only in the main jar of the application, "secondary JAR files
  and extensions are not required to have the Permissions attribute",
  without `Codebase` the Java console shows a warning (**documented**, JAR
  File Manifest Attributes for Security). `14-oracle_setup_forms.sh` adds
  them to the main section before signing, like Oracle's `frmwebutil.jar`.

## 9. Which certificates are needed

| Purpose | Certificate | Checked by | Notes |
|---|---|---|---|
| **Code signing** of `jacob.jar` (and other own jars) | code-signing certificate (Extended Key Usage *Code Signing*) | Java Web Start on the client | from a public CA or an internal company CA, see below |
| **TLS** of the Forms URL (NGINX) | server certificate (`08-SSL/`, `09-Install/05-root_nginx_ssl.sh`) | Java client (JWS **and** FSAL) when connecting via `https` | FSAL: "requires that the SSL / TLS certificate public key be included in the user's Java TrustStore" (**documented**, FSAL "Secure Socket Layer") |
| **Deployment Rule Set** (optional, JWS) | code-signing certificate for `DeploymentRuleSet.jar` | Java Web Start | "must be signed with a valid certificate from a trusted certificate authority" (**documented**, Java Deployment Rule Set) |

Options for the code-signing certificate:

| Option | Trust on the clients | Effort / risk |
|---|---|---|
| **A – public CA** (DigiCert, Sectigo, …) | already trusted: the CA root is in the Java `cacerts` and the Windows store → **nothing to distribute** | costs per year; since 2023 the private key must live on a hardware token / HSM or a cloud signing service (**assumption** – CA/Browser Forum code-signing requirements, check with the CA) → the signing step is a manual or CA-tool step, not a plain script |
| **B – internal company CA** (Windows AD CS …) | the **root of the company CA** must be trusted by the Java client: Windows store via GPO (JWS uses it by default, see 10) and/or the Java trust stores | company PKI needed; CRL/OCSP of the CA must be reachable from the clients (revocation check, see 10); renewals under the same root need **no** redistribution |
| **B' – own root CA** (`08-SSL/ssl_local_ca.sh`, implemented) | like B, but the root is self-made: one root signs the code-signing **and** the TLS certificate of Nginx → the clients import one root once (GPO / Java trust store) | same mechanics as B without a company PKI; the root key is the crown jewel (offline backup); no CRL / OCSP published – how Java Web Start's revocation check reacts is open (**assumption**, client test); Oracle's "self-generated certificates … should be avoided" applies – lab / internal use |
| **C – single self-signed certificate** | every client imports that one certificate | Oracle: avoid; each new certificate = redistribute to every client – test only |

## 10. Who checks the signature – and against what

| Client | Check | Trust anchors | Result if not trusted |
|---|---|---|---|
| **Java Web Start** (`config=webstart`; Oracle Java 8 `javaws`, or OpenWebStart) | every jar of every JNLP is verified; signer chain must end in a trusted CA; revocation check, default `ALL_CERTIFICATES` (OCSP/CRL); `all-permissions` only for signed jars | Java "Signer CA" stores: JRE `cacerts`, user / system `trusted.certs` (`deployment.system.security.trusted.certs`), and the **browser / Windows keystore** (`deployment.security.browser.keystore.use`, default `true`) – **documented**, Java deployment properties | jar blocked or security dialog; unsigned → blocked ("Unsigned applications are not permitted and are blocked", **documented** Forms FSAL page) |
| **FSAL** (`java -jar frmsal.jar`, Java 17+) | **no** signer trust check by default – "FSAL does not rely on Java Deployment technologies"; "limited levels of signed code verification can be enabled" via `keytool` import + `java.policy` `grant signedBy` – **deprecated** after Java 11, desupported from Oracle Java 24 (**documented**) | for TLS only: the Java truststore of the FSAL JVM (`cacerts`) | unsigned `jacob.jar` would load (**assumption**, to be tested); Oracle still recommends signing for all deployments |

Consequence: the signing/trust problem is mainly a **Java Web Start**
problem. With FSAL the remaining client-side trust item is the **TLS
certificate chain** of the Forms URL. Java Web Start itself is no longer in
current Java releases (removed with Java 11 – Oracle Java Client Roadmap
Update 2018; PDF reachable, wording not machine-checked here) – it needs
Oracle Java 8 or OpenWebStart, which
is one more reason Oracle positions FSAL ("this client configuration is
quickly becoming the preferred approach", **documented**).

### 10.1 What the session can do on the client – threat model

The signature protects **code**: the client's Java verifies the signed jars
(`frmwebutil.jar`, `jacob.jar`) independently of TLS. It does **not**
protect what the server tells the client to do during the session. With
WebUtil the Forms session is effectively a remote control of the client PC
**with the rights of the logged-in user** (not administrator / root):

| Server-side call | Effect on the client PC |
|---|---|
| `CLIENT_HOST` / `WEBUTIL_HOST` | runs operating-system commands |
| `WEBUTIL_FILE_TRANSFER`, `CLIENT_TEXT_IO` | reads / writes files the user can access |
| `CLIENT_OLE2` (JACOB) | drives Word / Excel and other COM objects |
| `install.syslib.*` in `webutil.cfg` | **pushes native DLLs** (`jacob-1.21-x64.dll`, `JNIsharedstubs.dll`) to `webutil\syslib\<serverhost>\` on the client and loads them into the client JVM |

The `install.syslib` entries carry only
`name|size|version|showDownloadDialog` (e.g.
`jacob-1.21-x64.dll|247296|1.21|true`, **confirmed (live)** in the
test host's `webutil.cfg`) – **no hash, no signature**. The integrity of
the DLL download from `/webutil/win64/` rests on TLS alone (plus the size).

`webutil.cfg` restricts only the **server side** of file transfers
(`transfer.appsrv.read.<n>` / `write.<n>`, `accessControl`, workAreaRoot);
there is no switch that disables `CLIENT_HOST` or client file access – that
is decided by the Forms code that attaches and calls WebUtil (**assumption**
from the keys present in Oracle's `webutil.cfg` 14.1.2).

Consequence: the two pillars of a WebUtil deployment are

1. the **code signature** (protect the code-signing key – everything signed
   with it runs with full user rights at the customer), and
2. the **integrity of the session's TLS** – whoever can manipulate it can
   act as the Forms server: trigger `CLIENT_HOST`, exchange files, swap a
   pushed DLL of the same size.

A TLS flaw in the client's Java (JSSE, e.g. CVE-2026-91403) hits pillar 2.
Scenarios and measures:
[forms_runtime_architecture.md §1.2](forms_runtime_architecture.md#12-threat-model-of-a-client-side-tls-jsse-flaw).
For WebUtil installations in particular: patch the client JREs first,
keep the Forms URL inside trusted networks, use WebUtil only in the forms
that need it, keep the `transfer.appsrv` directories minimal, and check
whether `CLIENT_HOST` is needed at all.

## 11. Maintenance – patching, renewal, re-signing

| Event | What happens | Action |
|---|---|---|
| **Forms patch / bundle** (`07-Maintenance/82-patch_forms_reports.sh`) | Oracle replaces its own signed jars (`frmall.jar`, `frmwebutil.jar`, `frmsal.jar`) – signed by Oracle, nothing to do; `jacob.jar` and the JACOB DLLs are not Oracle files and normally stay; **Oracle files we changed can be reset**: `extensions.jnlp` (jacob entry), `webutil.cfg` template | after every Forms patch: re-run `14-oracle_setup_forms.sh --apply` (checks `jacob.jar` present + `jarsigner -verify`, re-activates the `extensions.jnlp` entry and `WebUtilArchive`) |
| **New JACOB version required** (release notes of a Forms patch) | new `jacob.jar` (unsigned again) and new DLLs (other sizes) | download (`04-`), sign again, adapt `install.syslib.*` size/version in `webutil.cfg` (`14-` does it), clients download the new DLL automatically |
| **Own code-signing certificate expires** | signatures **with timestamp** stay valid; without timestamp the jar is blocked from that day | sign only with `-tsa`; renew the certificate before expiry; re-signing is needed only for new / changed jars |
| **Own root CA (B') – leaf renewal** | new code-signing / TLS certificate under the **same root** | `ssl_local_ca.sh codesign --apply --renew` / `ssl_prepare_cert.sh LOCALCA --apply --renew`; nothing to change on the clients; already signed + timestamped jars stay valid |
| **Certificate revoked / key compromised** | revocation check blocks every jar signed with it – also timestamped ones (**assumption** for the timestamp interplay) | new certificate, re-sign, serve |
| **Algorithm deprecated** (e.g. SHA-1 disabled in Java updates) | old signatures rejected by new Java versions | re-sign with SHA-256 (`-digestalg SHA-256`, current `jarsigner` default) |
| **Java update on the clients** | a JRE update replaces `lib/security/cacerts` – certificates imported **into that file** are lost (**assumption** – standard JRE update behaviour, verify per Java distribution) | never import into the JRE's `cacerts`; use the Windows store (GPO) or the system-level deployment stores outside the JRE |
| **Oracle's signer certificate expires** (2028-01-12 here) | Oracle signatures are timestamped (until 2031-11-10) – stay valid; newer patches bring re-signed jars | keep patching (CSPU) |

The jar itself is never distributed to the clients – Java Web Start / FSAL
download it from the server. What has to be on the clients is the **trust**
(CA certificates), the **Java runtime** and, for FSAL, `frmsal.jar`.

## 12. Distribution concept for the clients

What a Windows client needs:

| # | Item | JWS | FSAL | Changes how often |
|---|---|---|---|---|
| 1 | Java runtime | Oracle Java 8 (`javaws`) or OpenWebStart | Java 17+ (64 bit) | every Java CPU (quarterly) |
| 2 | Launcher | `.jnlp` link / `jnlp://` URL | `frmsal.jar` (+ shortcut with the URL); self-update via `fsalcheck` | seldom |
| 3 | Trust: CA of the **code-signing** certificate | yes (options B/C) | no (default) | B: once (root); C: at every new certificate |
| 4 | Trust: CA of the **TLS** certificate | yes | yes (FSAL JVM truststore) | with the TLS CA |
| 5 | Optional: system `deployment.config` / `deployment.properties`, `DeploymentRuleSet.jar` | yes | – | seldom |
| 6 | WebUtil native DLLs (`jacob`, `d2kwut60`, `JNIsharedstubs`) | downloaded by WebUtil into `%USERPROFILE%\webutil\syslib\<server>\…` at first use | same | with JACOB / Forms changes |

How customers distribute (observed practice):

| Method | How | Works for | Problems in larger environments |
|---|---|---|---|
| **Login script** | copies `frmsal.jar` / shortcuts, runs `keytool -importcert` into the user's `.keystore` or `trusted.certs` | small sites, few users | runs per user and logon; depends on the Java path (changes with every Java update); `keytool` must exist; errors invisible; user-level stores differ per profile / roaming profile; no reporting |
| **Software distribution** (SCCM / Intune / baramundi …) | package: Java runtime + launcher + trust configuration, version-controlled | medium / large sites | every Java update needs a new package; a package that imports into the JRE's `cacerts` breaks with the next Java update (11); packages per Java vendor/version; long change cycles when a certificate changes (option C) |
| **Group Policy – Windows certificate store** | company root CA (option B) and the TLS CA pushed into *Trusted Root Certification Authorities* | any size | JWS uses it by default (`deployment.security.browser.keystore.use=true`); FSAL/plain Java does not read the Windows store by default – there the truststore of the FSAL JVM is needed (**assumption**: e.g. `-Djavax.net.ssl.trustStoreType=Windows-ROOT` as FSAL Java option – to be tested) |
| **System-wide Java deployment config** | `C:\Windows\Sun\Java\Deployment\deployment.config` → central `deployment.properties` (e.g. `deployment.system.security.trusted.certs`, security level, lock-down), optional `DeploymentRuleSet.jar` | JWS in managed environments | applies to Java Web Start only; DRS jar itself must be signed by a trusted CA |

Recommendation (design, to be decided with the customer):

1. **Prefer FSAL** (Java 17/21) – no signer trust check by default, no Java
   8 / Web Start dependency; sign `jacob.jar` anyway (Oracle recommendation,
   cheap once the key exists).
2. **Code signing with a company CA (option B) or a public CA (option A)** –
   never self-signed in production. With B the root goes once via GPO;
   renewals under the same root need no client change.
3. **Trust via the Windows store / central deployment config**, never by
   importing into the JRE's `cacerts` (lost at the next Java update).
4. Distribute **Java + launcher** with the software distribution as one
   package; certificates via GPO – independent of the Java version.
5. Keep the WebUtil DLL download automatic (needs write access to
   `%USERPROFILE%\webutil`); only in locked-down clients (AppLocker etc.)
   pre-deploy and allow the path.

## 13. Implementation in this repository (2026-10-17)

```
  08-SSL/ssl_local_ca.sh  (creates)                09-Install/14-oracle_setup_forms.sh  (uses)
  +------------------------------+                 +------------------------------------------+
  | init     root CA             |                 | FORMS_SIGN_KEYSTORE set and jacob.jar    |
  | server   TLS cert -> Nginx   |                 | unsigned:                                |
  | codesign PKCS12 keystore ----+--- keystore --->|  jacob.jar -> jacob.jar.orig              |
  |          + des3 password     |   + des3 pw     |  main manifest += Permissions/Codebase/  |
  +------------------------------+                 |                   Application-Name       |
     or: company CA / public CA ----- PKCS12 ----->|  jarsigner -digestalg SHA-256 [-tsa]     |
                                                   |  jarsigner -verify -> activate           |
                                                   |  (WebUtilArchive, extensions.jnlp)       |
                                                   +------------------------------------------+
```

- **Creating** (08-SSL) and **using** (14-) are separate: 14- signs with any
  PKCS12 keystore – from the own root CA, a company CA or a public CA.
  Variables `FORMS_SIGN_KEYSTORE`, `FORMS_SIGN_ALIAS`, `FORMS_SIGN_TSA_URL`
  (`environment.conf`), password `FORMS_SIGN_STOREPASS` in
  `forms_sign_sec.conf.des3`. Details: `09-Install/docs/14-forms-detail-settings.md`
  Step 1, `08-SSL/README.md` section "ssl_local_ca.sh".
- Verification after signing **without `-strict`**: the server JDK does not
  trust an own / company root ("PKIX path building failed") – trust is a
  client matter (**confirmed (live)**).
- Still open:
  - Windows client: FSAL with unsigned and signed `jacob.jar`, JWS with the
    own-root-signed jar (root imported), revocation behaviour of JWS with a
    CA without CRL / OCSP, real OLE call (Excel).
  - After every Forms patch: `14- --apply` (re-activation) – entry in the
    `07-Maintenance` patch documentation done.

## 14. State on the test host (confirmed (live))

**2026-10-17 – signed and active:** own root CA `$ORACLE_BASE/admin/pki`
(`ssl_local_ca.sh init`), Nginx TLS certificate from that root (deployed by
`05-root_nginx_ssl.sh`, `openssl s_client -CAfile ca.crt` → `Verify return
code: 0`), code-signing keystore (`codesign`); `14- --apply` signed
`jacob.jar` with DigiCert timestamp (signer certificate until 2029-10-16,
timestamp until 2031-11-10), `WebUtilArchive=frmwebutil.jar,jacob.jar`,
`extensions.jnlp` entry active, jar served (HTTP 200, 61050 bytes); second
run idempotent.

History 2026-10-15:

Before the fix (first table) – after `FORMS_WEBUTIL_JACOB=true`, `04-` and
`14- --apply` the same day: JACOB 1.21 downloaded (SHA-256 OK), jar + DLLs
installed and served (HTTP 200, expected sizes), `webutil.cfg` is Oracle's
file + our `transfer.*` keys (all `install.syslib` entries kept), `jacob.jar`
**not activated** because unsigned (signing step open).

| Item | State |
|---|---|
| `jacob.jar`, `jacob-1.21-*.dll` | missing (14 only warns) |
| `d2kwut60.dll`, `JNIsharedstubs.dll` | present (shipped) |
| `webutil.cfg` of the instance | written by `14-` from `forms_templates/webutil.cfg.template` – contains only the `transfer.*` lines, **all `install.syslib.*` entries are missing** → WebUtil cannot install any native library on the client (also not `d2kwut60.dll`) |
| `formsweb.cfg` | `WebUtilArchive=frmwebutil.jar` (without `jacob.jar`) |
| `extensions.jnlp` | `jacob.jar` entry commented out (Oracle default) |
| hints in `14-` / doc 14 | still refer to `jacob-1.18-M2` and SourceForge (fixed the same day) |

## Summary

WebUtil solves the basic problem that Oracle Forms runs on the server but
needs resources of the Windows client. For normal file operations WebUtil uses
Java functions. For Microsoft Office automation it additionally uses JACOB,
the bridge between Java and the Windows COM world – a jar that must be signed
and a native DLL per architecture, both downloaded separately from GitHub.

## Sources

All links checked 2026-10-17 (HTTP 200, title matches).

Oracle Forms 14.1.2 – *Working with Oracle Forms*:
- Oracle Forms Standalone Launcher (requirements Java 17+, "Signed Code",
  "FSAL and Signed JARs", TLS truststore):
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/working-forms/oracle-forms-standalone-launcher.html
- Java Web Start (`basejnlp=webutil.jnlp`, `webstart=enabled`, custom jars
  such as `jacob.jar` into `extensions.jnlp`):
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/working-forms/java-web-start.html
- Release notes, lifecycle management (JACOB 1.21):
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/releasenotes-fnr/lifecycle-management-information.html

Java:
- JAR File Manifest Attributes for Security (`Permissions` required in the
  main jar only, `Codebase`): https://docs.oracle.com/javase/8/docs/technotes/guides/deploy/manifest.html
- `jarsigner` (JDK 21): https://docs.oracle.com/en/java/javase/21/docs/specs/man/jarsigner.html
- Signing JAR Files (Java Tutorials): https://docs.oracle.com/javase/tutorial/deployment/jar/signing.html
- Java Web Start FAQ ("all JAR files used in a JNLP file … signed by the same
  certificate", component extensions):
  https://docs.oracle.com/javase/8/docs/technotes/guides/javaws/developersguide/faq.html
- Java Web Start – Application Development Considerations (`all-permissions`
  only for signed jars):
  https://docs.oracle.com/javase/8/docs/technotes/guides/javaws/developersguide/development.html
- Deployment Configuration File and Properties (trusted.certs user/system,
  `deployment.security.browser.keystore.use`, `revocation.check`,
  `deployment.config` system-wide):
  https://docs.oracle.com/javase/8/docs/technotes/guides/deploy/properties.html
- Working with Signed RIAs (certificate chain, root CA):
  https://docs.oracle.com/javase/8/docs/technotes/guides/deploy/certificates.html
- Deployment Rule Set (`DeploymentRuleSet.jar`, signed by a trusted CA,
  `<Windows>\Sun\Java\Deployment`):
  https://docs.oracle.com/javase/8/docs/technotes/guides/deploy/deployment_rules.html
- Oracle Java Client Roadmap Update (2018, end of Java Web Start with Java 11;
  PDF reachable 2026-10-17, text not machine-checked):
  https://www.oracle.com/technetwork/java/javase/javaclientroadmapupdate2018mar-4414431.pdf

