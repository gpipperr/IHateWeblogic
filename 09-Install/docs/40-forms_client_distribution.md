# 40 – Forms Client Distribution via URL (Concept)

**Status: concept (2026-10-22) – not implemented yet.** This document is the
master for the later script `09-Install/40-oracle_forms_client_bundle.sh`
and the PowerShell template `09-Install/client_templates/FormsWeb-Setup.ps1`
(doc-as-master: doc first, then script).

Markers as in `80-FMW-Architecture/`: **documented** (Oracle source),
**confirmed (live)**, **assumption** (to be tested).

---

## 1. Goal and Scope

The Forms client – Java runtime, launcher, trust, WebUtil native libraries –
is today the customer's job, and it shows: a customer site rolls out a
32-bit JRE 8u241 from January 2020 through its software deployment; Java Web
Start (`javaws`) exists only in Java 8; and the Security Alert
CVE-2026-91403 (Java SE JSSE) showed that the **client JRE is the most
important lever** of the Forms TLS chain
([forms_runtime_architecture.md §1.2](../../80-FMW-Architecture/forms_runtime_architecture.md#12-threat-model-of-a-client-side-tls-jsse-flaw)) –
and that there is no fast way to update it.

Idea: the **application server serves the client itself**. Nginx publishes
a small bundle (Java runtime, `frmsal.jar`, JACOB DLL, trust store, start
parameters); a PowerShell mini installer on the Windows client installs it
**in the user's profile**, checks on every start whether the server has
something newer, updates itself and the components, and starts the form
with the Forms Standalone Launcher (FSAL).

| In scope | Out of scope |
|---|---|
| Windows clients (64-bit), Forms 14.1.2, **FSAL** | Java Web Start (needs Java 8 `javaws`) |
| user scope, no administrator, at most a "power user" | machine-wide installation, MSI, registry outside HKCU |
| bundle built from the patch repository + Oracle Home of the server | own Java builds, third-party JREs |
| test host and customer sites | Forms 12.2.1.19 (FSAL there also runs with Java 8 – own variant if needed) |

Benefit beyond security: one defined client state per server – the same
Java, the same `frmsal.jar`, the same trust – which makes client tests
reproducible (open items "Tests that need a client" in the root README).

---

## 2. Architecture

```
  Application server (Linux)                                Windows client (user scope)
 +---------------------------------------------+          +-------------------------------------------+
 | $PATCH_STORAGE/patches/<CLIENT_JDK_PATCH>/  |          | Desktop / start menu shortcut             |
 |   Windows x64 JDK ZIP (MOS, platform 46P)   |          |   powershell -ExecutionPolicy Bypass      |
 | $ORACLE_HOME/forms/java/frmsal.jar          |          |     -File FormsWeb-Setup.ps1 -Start       |
 | $PATCH_STORAGE/jacob/jacob-1.21.zip         |          |                 |                         |
 | 08-SSL CA (TLS chain of Nginx)              |          |   1. GET manifest.json (ETag, 304)        |
 |          |                                  |          |   2. self-update of the script            |
 |          v  40-oracle_forms_client_bundle.sh|          |   3. load changed components, SHA-256     |
 | $FORMS_CLIENT_DIR  ($ORACLE_BASE/forms/     |  HTTPS   |   4. start script / shortcut refresh      |
 |                     client/)                | <------- |   5. start FSAL                           |
 |   manifest.json                             |  Nginx   |                 |                         |
 |   FormsWeb-Setup.ps1 (+ Authenticode sig.)  | /forms   |  %LOCALAPPDATA%\FormsWeb\                 |
 |   FormsWeb-Install.cmd (bootstrap)          |  client/ |    java\<version>\  (jlink runtime / JDK)  |
 |   jre-<version>-win-x64.zip                 |          |    fsal\frmsal.jar                        |
 |   frmsal-<version>.jar                      |          |    jacob\jacob-1.21-x64.dll               |
 |   jacob-1.21-x64.dll                        |          |    state.json, logs\                      |
 +---------------------------------------------+          +-------------------|-----------------------+
                                                                              | javaw -jar frmsal.jar
                                                                              v  -url ...config=standaloneapp
                                                           https://<host>/forms/frmservlet  (Forms session)
```

---

## 3. Server Side – the Bundle

Built by the later `40-oracle_forms_client_bundle.sh` (read-only by
default, `--apply` builds) **only from sources the library already
manages** – logic once, no own download:

| Component | Source | Notes |
|---|---|---|
| **Java runtime** | Oracle JDK 21 for **Windows x64** – MOS Patch 35702194 ("JDK 21 latest") or the release-specific patch (CPU426: 40186074 = 21.0.13.0.2), platform **46P** | see 3.1 |
| **`frmsal.jar`** | `$ORACLE_HOME/forms/java/frmsal.jar` of this server | Oracle-signed; "version-specific – you cannot use frmsal.jar from one installation against another" (**documented**) → always the server's own file; replaced by Forms patches → rebuild the bundle after every Forms patch |
| **JACOB DLL** | `$PATCH_STORAGE/jacob/$JACOB_ZIP` (same ZIP as `14-oracle_setup_forms.sh`, SHA-256 in `oracle_software_version.conf`) | x64 DLL – bitness of the client Java (FSAL is 64-bit only); see 5.6 |
| **Trust** | CA chain of the Nginx TLS certificate (`08-SSL/ssl_local_ca.sh` root, company CA, or nothing for a public CA) | imported with the server `keytool` into the `cacerts` of the **bundled** runtime; see 5.5 |
| **`manifest.json`** | generated | see 3.2 |
| **`FormsWeb-Setup.ps1`**, **`FormsWeb-Install.cmd`** | `09-Install/client_templates/` | Authenticode-signed if a code-signing keystore exists (`FORMS_SIGN_*`, `08-SSL`), see 5.1 |

Location: `$ORACLE_BASE/forms/client/` (new variable `FORMS_CLIENT_DIR` in
`environment.conf`), owner `oracle`, readable for Nginx (SELinux context
`httpd_sys_content_t` – same check as `05-root_nginx_ssl.sh`). The previous
bundle stays as `client.prev/` for a server-side rollback.

### 3.1 Java runtime – no "base JRE + patch"

- **There is no separate JRE since Java 11**; Oracle ships only the JDK.
  The public archive page
  (https://www.oracle.com/java/technologies/javase/jdk21-archive-downloads.html,
  checked 2026-10-22) lists only JDK ZIP / exe / msi and ends at
  **21.0.12.1** under the No-Fee Terms – affected by the CPU October 2026
  and the alert, and no further public updates since the NFTC for JDK 21
  ended (September 2026). Not used.
- **Java updates are not deltas.** Every Java update from MOS is a complete
  distribution: "each release is a full distribution and supersedes prior
  releases" (CPU426, **documented**). So the bundle needs no base version –
  only the current MOS patch for the Windows platform.
- **Download:** `04-oracle_pre_download.sh` loads Patch 35702194 today only
  for `MOS_PLATFORM=226P` (Linux x86-64); getMOSPatch takes one platform per
  run. New: a second pass for the client platform – variables
  `CLIENT_JDK_PATCH_NR` and `CLIENT_JDK_PLATFORM="46P"` (Windows x86-64) in
  `oracle_software_version.conf`, target `$PATCH_STORAGE/patches/<nr>/46P/`.
  Same version target as the server (`JDK_VERSION_MIN`, CPU October 2026 +
  alert: 21.0.13.0.2).
- **Slim runtime with `jlink` (default):** "Forms also supports using a
  custom JRE distribution that you create using Oracle Java version 17 or
  newer … jdeps … jlink … jpackage" (**documented**, Forms 14.1.2 FSAL,
  "Custom JRE Support"). The bundle script runs `jdeps` on `frmsal.jar` /
  the Forms client jars and `jlink` from the server JDK 21 with the
  `jmods` of the **Windows** JDK (cross-platform linking with the same
  version – **assumption**, test) → a runtime of a few dozen MB instead of
  ~300 MB. Fallback: the full JDK ZIP.
- **Licence:** the patch README demands a Java SE subscription; Java used
  only to run an Oracle product falls under MOS Doc ID 1557737.1 – for the
  Forms client runtime an **assumption** to be confirmed for the customer;
  the bundle serves Java only to Forms users of this server.
- **Server-side enforcement:** `fsalJavaVersion` in the `[standaloneapp]`
  section of `formsweb.cfg` – "17.0.5* : Runs only the specified version or
  later in the Java 17 family" (**documented**, Web Configuration
  Parameters). Setting e.g. `21.0.13*` rejects clients with an older Java
  (whether the four-part `21.0.13.0.2*` is accepted: **assumption**).

### 3.2 `manifest.json` – the one small file checked on every start

One file of about 1–2 KB; no second "version" file is needed:

```json
{
  "schemaVersion": 1,
  "server": "https://<host>",
  "setup":  { "version": "1.0.3", "file": "FormsWeb-Setup.ps1", "sha256": "…" },
  "components": {
    "java":  { "version": "21.0.13.0.2", "file": "jre-21.0.13.0.2-win-x64.zip", "size": 0, "sha256": "…" },
    "fsal":  { "version": "14.1.2.0.0-<qpr>", "file": "frmsal-14.1.2.0.0-<qpr>.jar", "size": 0, "sha256": "…" },
    "jacob": { "version": "1.21", "file": "jacob-1.21-x64.dll", "size": 247296, "sha256": "…" }
  },
  "start": {
    "url": "https://<host>/forms/frmservlet?config=standaloneapp",
    "fsalArgs": ["-t", "30000", "-cert_truststore", "java"],
    "shortcutName": "Forms <application>",
    "icon": null
  }
}
```

Nginx serves it with `Cache-Control: no-cache` and an ETag: an unchanged
manifest costs one request with an HTTP 304 answer. Versioned file names
(`jre-<version>…`, `frmsal-<version>.jar`) let browsers / proxies cache the
large files safely.

---

## 4. Nginx

New location in `09-Install/nginx-wls.conf.template` (deployed by
`04-root_nginx.sh`; change `docs/04-root_nginx.md` first):

```nginx
location /formsclient/ {
    alias  <FORMS_CLIENT_DIR>/;
    autoindex off;
    types { application/json json; application/zip zip; application/java-archive jar;
            text/plain ps1 cmd; application/octet-stream dll; }
    location = /formsclient/manifest.json { add_header Cache-Control "no-cache"; }
}
```

Only HTTPS (same server block as `/forms/`), no directory listing, no
access from outside the networks that may use Forms (same rules as
`/forms/`).

---

## 5. Client Side – `FormsWeb-Setup.ps1`

### 5.1 Getting the script to run – ExecutionPolicy and signing (chicken-and-egg)

The ExecutionPolicy applies to `.ps1` files only; how the script arrives
and how it is called decides whether it runs:

| Windows fact | Consequence |
|---|---|
| Default policy: Windows client `Restricted`, Windows Server `RemoteSigned`; companies usually set it by GPO | a double-clicked `.ps1` does not run on a default client |
| `RemoteSigned` demands a signature only for files with *Mark of the Web* (`Zone.Identifier` stream, set by browsers / mail clients) | a file written by PowerShell itself (`Invoke-WebRequest -OutFile`) carries no MOTW (**assumption**, test) |
| `powershell -ExecutionPolicy Bypass -File …` applies to that process only, needs no administrator | works – **unless** a GPO sets the policy (MachinePolicy / UserPolicy scope wins over the command line) |
| `.cmd` files are not subject to the ExecutionPolicy | a small `.cmd` is the bootstrap; from a browser it may show one SmartScreen warning |
| AppLocker / WDAC put PowerShell into *Constrained Language Mode* | only signed **and** allowed scripts work – then signing is mandatory |

Design:

1. **Bootstrap `FormsWeb-Install.cmd`** – from a link on the Forms start
   page, by mail from IT, or as the only content of an SCCM / Intune
   package. It runs
   `powershell -NoProfile -ExecutionPolicy Bypass -Command …`, downloads
   `manifest.json` and `FormsWeb-Setup.ps1` into
   `%LOCALAPPDATA%\FormsWeb\`, checks the SHA-256 of the script against the
   manifest and starts it with `-Install`. The one-liner
   `irm https://<host>/formsclient/FormsWeb-Setup.ps1 | iex` is documented
   as an alternative only (no hash check before execution).
2. **The shortcut calls the script, not Java:**
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%LOCALAPPDATA%\FormsWeb\FormsWeb-Setup.ps1" -Start`
   – every start goes through the update check, and the self-updated script
   needs no signature as long as no GPO policy applies.
3. **Always sign anyway** – Authenticode with timestamp, with the
   code-signing certificate of `08-SSL/ssl_local_ca.sh codesign` or the
   company / public CA (the same keystore as `jacob.jar`, `FORMS_SIGN_*`).
   Then the script also runs under `AllSigned` / Constrained Language Mode.
   The **egg** – trust in the signer – cannot come from the script itself:
   - company CA / public CA: root via GPO into *Trusted Root Certification
     Authorities*, the signing certificate into *Trusted Publishers* (IT);
   - own root CA (`08-SSL`): the user imports root and publisher once into
     `Cert:\CurrentUser\Root` and `Cert:\CurrentUser\TrustedPublisher`
     (no administrator, Windows shows a confirmation dialog).
   Signing on the Linux server: `osslsigncode` (`.ps1` support in newer
   versions – **assumption**, test); `Set-AuthenticodeSignature` exists on
   Windows only.
4. **Own integrity check independent of the policy:** every file – the
   script's own update included – is compared with the SHA-256 of the
   manifest before use.
5. Customer check before the rollout: `Get-ExecutionPolicy -List`,
   `$ExecutionContext.SessionState.LanguageMode`, AppLocker rules.

### 5.2 Install layout

```
%LOCALAPPDATA%\FormsWeb\                 (local profile, not Roaming: runtime ~50–300 MB)
  FormsWeb-Setup.ps1                     current script
  manifest.json                          last manifest (offline start)
  state.json                             installed versions + hashes
  java\21.0.13.0.2\                      runtime (versioned; previous version kept)
  fsal\frmsal-<version>.jar
  jacob\jacob-1.21-x64.dll               verified copy (see 5.6)
  logs\FormsWeb-<date>.log
```

No administrator, no `HKLM`, no system `PATH`, no change to any machine-wide
Java. `%LOCALAPPDATA%` instead of `%APPDATA%`: a Roaming profile would copy
the runtime at every logon / logoff.

### 5.3 Order on every start

```
 -Start
   |
   1. GET manifest.json  (If-None-Match, timeout ~3 s)
   |     unreachable -> log, use the cached manifest, continue with step 5 (offline)
   |
   2. setup.version > own version ?
   |     yes -> download script to %TEMP%, SHA-256 check, replace itself,
   |            restart with the same arguments (at most once: loop guard)
   |
   3. for java / fsal / jacob: version or sha256 differs from state.json ?
   |     yes -> download to %TEMP% -> SHA-256 check -> extract into a new
   |            versioned directory -> switch state.json only after success
   |            -> keep the previous version, delete older ones
   |
   4. start parameters / shortcut name changed in the manifest ?
   |     yes -> rewrite the shortcuts
   |
   5. start FSAL (javaw, no console window)
```

`-Install` = steps 1–4 + shortcuts (desktop, start menu via
`WScript.Shell`), `-Start` = steps 1–5, `-Uninstall` = remove the folder and
the shortcuts, `-Rollback` = switch `state.json` to the previous version.

### 5.4 Starting FSAL

```
"%LOCALAPPDATA%\FormsWeb\java\<version>\bin\javaw.exe"
    -jar "%LOCALAPPDATA%\FormsWeb\fsal\frmsal-<version>.jar"
    -url "https://<host>/forms/frmservlet?config=standaloneapp"
    -t 30000 -cert_truststore java
```

FSAL command-line arguments (**documented**, FSAL Reference): `-url` (in
quotes, with the `config=` section), `-t` (ms to wait for the first server
response, default 60000), `-showDetails 1|2|99` (diagnosis), `-clearcache`,
`-cert_truststore forms|java`, `-autoImportCert`. No `userid=` in the URL –
the Forms logon dialog asks.

FSAL updates `frmsal.jar` itself when it does not match the server
("`fsalEnableAutoUpdate` … Auto update is only supported for patch updates",
default `TRUE`, **documented**) – our own update of `frmsal.jar` from the
bundle keeps the file under our control; both lead to the server's version.

### 5.5 TLS trust

FSAL needs the CA of the server certificate in "the Java TrustStore that is
being used by FSAL" (**documented**). By default FSAL keeps its own store
`C:\Users\<user>\Oracle\forms\formstruststore` and asks the user to import
an unknown certificate (Certificate Importer); `-autoImportCert` imports
without asking.

Design: the bundle script imports the CA chain into the `cacerts` of the
**bundled runtime** on the server, and the client starts FSAL with
`-cert_truststore java`. The usual objection "never import into a JRE's
`cacerts`, the next Java update loses it" does not apply here – every
runtime comes from the bundle with the CA already inside. **Never**
`-autoImportCert` (a manipulated connection would be trusted silently) and
no user prompt that teaches users to click "OK" on unknown certificates.

The script itself (PowerShell, `Invoke-WebRequest`) uses the **Windows**
certificate store: for an own root CA / company CA the root must be there
before the first download (GPO, or one user import – see 5.1).

### 5.6 JACOB DLL

WebUtil pushes `jacob-1.21-x64.dll` into
`%USERPROFILE%\webutil\syslib\<server>\` on first use, checked only by size
(`install.syslib.*` in `webutil.cfg`, no hash –
[forms_jakob_webutil.md §10.1](../../80-FMW-Architecture/forms_jakob_webutil.md#101-what-the-session-can-do-on-the-client--threat-model)).
The setup script places the SHA-256-verified DLL there in advance; whether
WebUtil then skips its own download (same name and size) is an
**assumption** to be tested. `jacob.jar` itself is loaded by FSAL from the
server like every Forms jar.

Bitness: FSAL needs a 64-bit Java ("These versions are only available in
64-bit Java Development Kit (JDK) distributions", **documented**) → always
the x64 DLL; a 32-bit JRE 8 of an older Web Start setup needs the x86 DLL.

### 5.7 Rights and environment

| Topic | Requirement |
|---|---|
| User rights | normal user; "power user" at most – nothing needs administrator |
| AppLocker / SRP | default rules block executables in the user profile → customer IT needs a **publisher rule** for Oracle's signed `java.exe` / `javaw.exe` (survives updates) or a path rule for `%LOCALAPPDATA%\FormsWeb\java\*` |
| ExecutionPolicy / Constrained Language | see 5.1 |
| Proxy | `Invoke-WebRequest -UseDefaultCredentials`, system proxy; FSAL behind a proxy: "Running An Application Through a Proxy Server" (FSAL documentation) |
| Profiles | folder redirection of `%LOCALAPPDATA%` is rare; check on terminal servers (one runtime per user – consider a shared read-only path there) |
| Disk | runtime + jars ≈ 60 MB (jlink) / 320 MB (full JDK) per user and version, previous version kept |

---

## 6. Security Assessment

- Integrity of every file = **TLS + SHA-256 from the manifest**; the
  manifest itself is only as trustworthy as the TLS connection and the
  server. Optional next step: a signed manifest (detached signature with the
  code-signing key, checked by the signed script).
- The chain gives the server **the right to install and run code on the
  client with the user's rights** – the same trust level WebUtil already
  has ([forms_jakob_webutil.md §10.1](../../80-FMW-Architecture/forms_jakob_webutil.md#101-what-the-session-can-do-on-the-client--threat-model)):
  protect the server, the bundle directory (owner `oracle`, not writable
  for Nginx) and the code-signing key.
- No passwords anywhere: not in the manifest, the URL, the shortcut or the
  logs.
- Gain compared with today: the client Java follows the server's patch
  cycle within one start, instead of a software-deployment package per
  Java update.

---

## 7. Operations

| Event | Action |
|---|---|
| Java CPU / Security Alert | `04-` downloads the Windows patch → `40- --apply` rebuilds the bundle → every client updates at its next start |
| Forms patch (QPR) | new `frmsal.jar` / Forms jars on the server → `40- --apply` (same rule as `14- --apply` after every Forms patch, `07-Maintenance/README.md`) |
| New JACOB version | `04-` + `14-` as today, then `40- --apply` |
| TLS CA change | `40- --apply` (CA into the bundled runtime); the Windows store via GPO / user import |
| Problem with a new version | server: restore `client.prev/`; client: `FormsWeb-Setup.ps1 -Rollback` |
| Relation to the customer's software deployment | alternative to it – or the SCCM / Intune package carries only `FormsWeb-Install.cmd` |

---

## 8. Test Plan (Windows client)

| # | Test | Expected |
|---|---|---|
| 1 | Bootstrap on a clean user profile (default policy, no admin) | runtime, jars, shortcut in place; form starts |
| 2 | Second start without server change | one manifest request (304), no download |
| 3 | New bundle on the server (Java + `frmsal.jar`) | client updates at the next start, previous version kept |
| 4 | Self-update of the script | new version runs after one restart, no loop |
| 5 | Server unreachable | start with the installed version, log entry |
| 6 | `-Rollback`, `-Uninstall` | previous version / clean removal |
| 7 | GPO `AllSigned`; AppLocker default rules | signed script runs; Java blocked until the publisher rule exists |
| 8 | Downloaded `.ps1` (MOTW) vs. PowerShell-loaded file under `RemoteSigned` | confirms 5.1 |
| 9 | JACOB: pre-seeded DLL, WebUtil OLE call (Excel) with unsigned / signed `jacob.jar` | WebUtil skips its download (assumption 5.6), OLE works |
| 10 | TLS with own root CA, `-cert_truststore java` | no Certificate Importer prompt |
| 11 | `fsalJavaVersion` with an older runtime | start refused with Oracle's message |

---

## 9. Implementation Pieces (after approval)

| Piece | Change |
|---|---|
| `09-Install/40-oracle_forms_client_bundle.sh` | new – read-only check / `--apply` builds `FORMS_CLIENT_DIR` (jlink, CA import, manifest, signing) |
| `09-Install/client_templates/` | new – `FormsWeb-Setup.ps1`, `FormsWeb-Install.cmd` |
| `09-Install/04-oracle_pre_download.sh` + doc 04 | second getMOSPatch pass for `CLIENT_JDK_PLATFORM` |
| `09-Install/oracle_software_version.conf` | `CLIENT_JDK_PATCH_NR`, `CLIENT_JDK_PLATFORM` |
| `09-Install/nginx-wls.conf.template` + `04-root_nginx.sh` + doc 04 | `location /formsclient/` |
| `environment.conf` / `01-setup-interview.sh` | `FORMS_CLIENT_DIR`, application name for the shortcut, `config=` section |
| `14-oracle_setup_forms.sh` | optional `fsalJavaVersion` in `[standaloneapp]` |
| `07-Maintenance/README.md` | "after every Java / Forms patch: `40- --apply`" |

---

## Sources

- Oracle Forms 14.1.2, Working with Oracle Forms – Oracle Forms Standalone
  Launcher (requirements Java 17+ / 64-bit, Custom JRE Support, version
  specific `frmsal.jar`, Certificate Importer / `formstruststore`, FSAL
  Reference: `fsalEnableAutoUpdate`, command-line arguments), checked
  2026-10-22 (HTTP 200, title "Oracle Forms Standalone Launcher"):
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/working-forms/oracle-forms-standalone-launcher.html
- Same book – Web Configuration Parameters (`fsalJavaVersion`), checked
  2026-10-22 (HTTP 200, title "Web Configuration Parameters"):
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/working-forms/web-configuration-parameters.html
- Java SE 21 archive downloads (JDK only, last 21.0.12.1, NFTC), checked
  2026-10-22: https://www.oracle.com/java/technologies/javase/jdk21-archive-downloads.html
- MOS CPU426 – Oracle Java SE Security Alert for CVE-2026-91403 ("each
  release is a full distribution"), read 2026-10-22; see
  [00-patch-references.md](00-patch-references.md).
- Background: [forms_jakob_webutil.md](../../80-FMW-Architecture/forms_jakob_webutil.md)
  §10–12 (trust, distribution methods), [forms_runtime_architecture.md](../../80-FMW-Architecture/forms_runtime_architecture.md)
  §1.1/§1.2 (who speaks TLS, threat model).
