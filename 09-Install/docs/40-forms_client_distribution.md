# 40 – Forms Client Distribution via URL (Concept)

> Certificates, keys and trust stores of the whole stack (terms, where what lives, who needs what, customer PKI / TLS interception): [certificates_trust_stores.md](../../80-FMW-Architecture/certificates_trust_stores.md)

**Status 2026-10-23: server side live on the test host** (download `04-`,
Nginx `/formsWeb/`, bundle `40-oracle_forms_client_bundle.sh`, client templates
`09-Install/client_templates/`) **and first Windows client run OK** –
installation from the URL and the FSAL start of the test form work
(`FormsWeb-Setup.ps1` 1.0.2, Windows client JDK platform `233P` = Windows x64).
Open (§8 / §12): update and self-update round, offline start, `-Rollback`,
JACOB / Excel, `AllSigned` + Authenticode signature of the setup script. This
document is the master for the scripts (doc-as-master: doc first, then
script).

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
 | $PATCH_STORAGE/client/jdk/<nr>/             |          | Desktop / start menu shortcut             |
 |   Windows x64 JDK ZIP (MOS, platform 233P)  |          |   powershell -ExecutionPolicy Bypass      |
 | $ORACLE_HOME/forms/java/frmsal.jar          |          |     -File FormsWeb-Setup.ps1 -Start       |
 | $PATCH_STORAGE/jacob/jacob-1.21.zip         |          |                 |                         |
 | 08-SSL CA (TLS chain of Nginx)              |          |   1. GET manifest.json (10 s timeout)     |
 |          |                                  |          |   2. self-update of the script            |
 |          v  40-oracle_forms_client_bundle.sh|          |   3. load changed components, SHA-256     |
 | $FORMS_CLIENT_DIR  (default /srv/formsWeb)  |  HTTPS   |   4. start script / shortcut refresh      |
 |                                             | <------- |   5. start FSAL                           |
 |   manifest.json                             |  Nginx   |                 |                         |
 |   FormsWeb-Setup.ps1                        | /forms   |  %LOCALAPPDATA%\FormsWeb\                 |
 |   FormsWeb-Install.cmd (bootstrap)          |  Web/    |    java\<version>-<sha8>\ (jlink runtime)  |
 |   jre-<version>-win-x64.zip                 |          |    fsal\frmsal-<version>.jar              |
 |   frmsal-<version>.jar                      |          |    jacob\jacob-1.21-x64.dll               |
 |   jacob-1.21-x64.dll                        |          |    state.json, logs\                      |
 +---------------------------------------------+          +-------------------|-----------------------+
                                                                              | javaw -jar frmsal.jar
                                                                              v  -url ...config=standaloneapp
                                                           https://<host>/forms/frmservlet  (Forms session)
```

---

## 3. Server Side – the Bundle

Built by `40-oracle_forms_client_bundle.sh` (read-only by
default, `--apply` builds, §10) **only from sources the library already
manages** – logic once, no own download:

| Component | Source | Notes |
|---|---|---|
| **Java runtime** | Oracle JDK 21 for **Windows x64** – MOS Patch 35702194 ("JDK 21 latest") or the release-specific patch (CPU426: 40186074 = 21.0.13.0.2), platform **233P** | see 3.1 |
| **`frmsal.jar`** | `$ORACLE_HOME/forms/java/frmsal.jar` of this server | Oracle-signed; "version-specific – you cannot use frmsal.jar from one installation against another" (**documented**) → always the server's own file; replaced by Forms patches → rebuild the bundle after every Forms patch |
| **JACOB DLL** | `$PATCH_STORAGE/jacob/$JACOB_ZIP` (same ZIP as `14-oracle_setup_forms.sh`, SHA-256 in `oracle_software_version.conf`) | x64 DLL – bitness of the client Java (FSAL is 64-bit only); see 5.6 |
| **Trust** | CA chain of the Nginx TLS certificate (`08-SSL/ssl_local_ca.sh` root, company CA, or nothing for a public CA) | imported with the server `keytool` into the `cacerts` of the **bundled** runtime; see 5.5 |
| **`manifest.json`** | generated | see 3.2 |
| **`FormsWeb-Setup.ps1`**, **`FormsWeb-Install.cmd`** | `09-Install/client_templates/` (§11) | unsigned today; Authenticode signature with the `FORMS_SIGN_*` keystore is open (§5.1, §12) |

Location: `FORMS_CLIENT_DIR` (default `/srv/formsWeb`, next to
`PATCH_STORAGE=/srv/patch_storage`), created by root in
`03-root_user_oracle.sh` (owner `oracle:oinstall`, mode 755 – Nginx only
reads). `01-root_os_baseline.sh` disables SELinux; on a customer host with
SELinux enforcing the directory needs the context `httpd_sys_content_t`
(`semanage fcontext -a -t httpd_sys_content_t '/srv/formsWeb(/.*)?'` +
`restorecon -R /srv/formsWeb`). No sibling directory for a rollback
(`/srv` belongs to root): all files carry their version in the name, old
and new set live side by side, `manifest.json` is replaced last and
atomically (`mv`), the previous one stays as `manifest.prev.json` (see §10).

### 3.0 Parameters (`environment.conf`, asked by `01-setup-interview.sh`)

Only for `INSTALL_COMPONENTS=FORMS_AND_REPORTS` / `FORMS_ONLY` – a
Reports-only installation has no Forms client and asks none of them.

| Variable | Default | Purpose |
|---|---|---|
| `FORMS_CLIENT_DIST` | `false` | switch – all other values only with `true` |
| `FORMS_CLIENT_DIR` | `/srv/formsWeb` | bundle directory, Nginx `alias` source |
| `FORMS_CLIENT_URL_PATH` | `/formsWeb` | Nginx `location` (starts with `/`, no trailing `/`, not `/forms`) |
| `FORMS_CLIENT_BASE_URL` | `https://${WLS_SERVER_FQDN}` | server URL the clients use – may be a DNS alias, must match the TLS certificate |
| `FORMS_CLIENT_CONFIG` | `standaloneapp` | `formsweb.cfg` section → `…/frmservlet?config=<section>` |
| `FORMS_CLIENT_FORM` | empty | optional start form → `&form=<name>`; empty = `form=` of the section |
| `FORMS_CLIENT_APP_NAME` | `Oracle Forms` | name of the desktop / start menu shortcut |
| `FORMS_CLIENT_ICON` | `${PATCH_STORAGE}/icon/IHateWeblogic.ico` | shortcut icon – the default is the project logo `09-Install/forms_templates/IHateWeblogic.ico` (16/32/48/256 px), copied there by `04- --apply` if missing; own icon: local path or `http(s)` URL (`04-` downloads a URL into `$PATCH_STORAGE/icon/<basename>`, shared helper `forms_client_icon_path` in the lib): `.ico`, or `.png` up to 256 × 256 – `40-` wraps a PNG into an ICO container (PNG-compressed entry, Windows Vista and later), served as `icon-<sha8>.ico`, `start.icon` in the manifest; empty = Windows default. The Oracle Home has no Forms `.ico` – for production use the customer's application / company icon |
| `FORMS_CLIENT_RUNTIME` | `jlink` | `jlink` = slim runtime, `jdk` = full JDK ZIP |
| `FORMS_CLIENT_TRUST_CA` | `${SSL_CA_DIR}/ca/ca.crt` if it exists, else empty | CA for the truststore of the bundled runtime; empty = public CA |

Code signing of the setup script uses the existing `FORMS_SIGN_*`
keystore (also asked when `FORMS_CLIENT_DIST=true`, not only for JACOB).
Not in the interview (software versions, one source):
`CLIENT_JDK_PATCH_NR` and `CLIENT_JDK_PLATFORM` in
`oracle_software_version.conf`.

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
  run. Second pass for the client platform (**implemented 2026-10-22**,
  `04- --apply --mos` with `FORMS_CLIENT_DIST=true`): variables
  `CLIENT_JDK_PATCH_NR` (empty = `JDK_PATCH_NR`) and
  `CLIENT_JDK_PLATFORM="233P"` (Microsoft Windows x64) in
  `oracle_software_version.conf`, target `$PATCH_STORAGE/client/jdk/<nr>/`
  – an own directory, because the skip check of `04-` treats any ZIP in
  `patches/<nr>/` as present ([04-oracle_pre_download.md](04-oracle_pre_download.md)).
  First download **confirmed (live) 2026-10-22**: `p35702194_2100_MSWIN-x86-64.zip`
  (518 MB) holds `jdk-21.0.13.0.2_windows-x64_bin.zip` (the source for
  `jlink`), `.exe`, `.msi`, `SHA256_VALUES` – already the alert release.
  Same version target as the server (`JDK_VERSION_MIN`, CPU October 2026 +
  alert: 21.0.13.0.2).
- **Slim runtime with `jlink` (default):** "Forms also supports using a
  custom JRE distribution that you create using Oracle Java version 17 or
  newer … jdeps … jlink … jpackage" (**documented**, Forms 14.1.2 FSAL,
  "Custom JRE Support"). The bundle script runs `jlink` from the server
  JDK 21 with the `jmods` of the **Windows** JDK and a fixed module list
  (`FORMS_CLIENT_JLINK_MODULES`, default from the `jdeps` analysis below) →
  a runtime of about 60 MB instead of ~300 MB (ZIP 44 MB). Fallback: the
  full JDK (`FORMS_CLIENT_RUNTIME=jdk`). Re-run `jdeps` when a Forms patch
  brings new client jars.

  Theory, module list and tests in detail:
  [java_jlink_forms_env.md](../../80-FMW-Architecture/java_jlink_forms_env.md).
  Test on the server, **confirmed (live) 2026-10-22**:
  - Linux `jlink` 21.0.12.1 (`JDK_HOME`) with the 70 `jmods` of
    `jdk-21.0.13.0.2_windows-x64_bin.zip` (SHA-256 checked against
    `SHA256_VALUES`) built a Windows runtime in 8 s:
    - 61 MB, `release` `JAVA_VERSION="21.0.13.0.2"`;
    - `java.exe` / `javaw.exe` (PE32+ x86-64) and `keytool.exe`;
    - `lib/security/cacerts` is PKCS12; the own root CA was imported with
      the server `keytool` (`-storepass changeit`).
  - Whether it starts on Windows: client test.

  Modules:
  - `jdeps --print-module-deps`: `frmsal.jar` → `java.base,java.desktop,
    java.management,java.net.http`; `frmall.jar` adds `jdk.jsobject`;
    `frmwebutil.jar`, `jacob.jar` → `java.base,java.desktop`.
  - Added because they are loaded via services / at run time and
    invisible to `jdeps` (**assumption** to be confirmed on the client):
    - TLS / crypto: `jdk.crypto.ec`, `jdk.crypto.mscapi` (Windows key
      store);
    - text: `jdk.charsets`, `jdk.localedata` (German date / number
      formats);
    - general: `java.logging`, `java.naming`, `java.xml`, `java.prefs`,
      `jdk.unsupported`, `jdk.zipfs`, `jdk.accessibility`.
  - `jlink` options: `--strip-debug --no-header-files --no-man-pages
    --compress=zip-6`.
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

One file of about 1.5 KB; no second "version" file is needed. As written
by `40-` (**confirmed (live)** 2026-10-22, hashes shortened):

```json
{
  "schemaVersion": 1,
  "generated": "2026-10-22T21:20:00+02:00",
  "server": "https://<host>",
  "baseUrl": "https://<host>/formsWeb/",
  "components": {
    "java":  { "version": "21.0.13.0.2", "file": "jre-21.0.13.0.2-win-x64.zip",
               "size": 45609003, "sha256": "1bf2…", "source": "<fingerprint of the sources>" },
    "fsal":  { "version": "14.1.2.0.0-bdd10648", "file": "frmsal-14.1.2.0.0-bdd10648.jar",
               "size": 388317, "sha256": "bdd1…", "source": "bdd1…" },
    "jacob": { "version": "1.21", "file": "jacob-1.21-x64.dll",
               "size": 247296, "sha256": "6b44…", "source": "<sha256 of jacob-1.21.zip>" }
  },
  "start": {
    "url": "https://<host>/forms/frmservlet?config=standaloneapp",
    "fsalArgs": ["-t", "30000", "-cert_truststore", "java"],
    "shortcutName": "Oracle Forms"
  },
  "setup": { "version": "1.0.1", "file": "FormsWeb-Setup.ps1", "sha256": "…",
             "bootstrap": "FormsWeb-Install.cmd" }
}
```

`source` is the change-check fingerprint of `40-` (no server paths – the
manifest is public). Nginx serves it with `Cache-Control: no-cache` and an
ETag (HTTP 304 **confirmed (live)**); the PowerShell script itself fetches
the full file each time (§11). Versioned file names
(`jre-<version>…`, `frmsal-<version>.jar`) let browsers / proxies cache the
large files safely.

---

## 4. Nginx

Optional block in `09-Install/nginx-wls.conf.template`, kept by
`04-root_nginx.sh` only with `FORMS_CLIENT_DIST=true` – the exact
configuration is in [04-root_nginx.md](04-root_nginx.md) ("Forms client
bundle location"): `location /formsWeb/` with `alias /srv/formsWeb/`,
`autoindex off`, `.ps1` as `text/plain`, `.cmd` / `.dll` / everything else
as `application/octet-stream` (the browser downloads the bootstrap), an
exact-match location for `manifest.json` with `Cache-Control: no-cache`.
Deployed on the test host 2026-10-22 (**confirmed (live)**: 200, 301 for
`/formsWeb`, 403 for the directory, 304 with ETag, MIME types).

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
   `irm https://<host>/formsWeb/FormsWeb-Setup.ps1 | iex` is documented
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
  state.json                             installed versions + hashes (UTF-8, no paths)
  icons\icon-<sha8>.ico                  own shortcut icon (FORMS_CLIENT_ICON)
  java\21.0.13.0.2-<sha8>\               runtime (versioned; previous version kept)
  fsal\frmsal-14.1.2.0.0-<sha8>.jar
  jacob\jacob-1.21-x64.dll               verified copy (see 5.6)
  logs\FormsWeb-<date>.log
```

No administrator, no `HKLM`, no system `PATH`, no change to any machine-wide
Java. `%LOCALAPPDATA%` instead of `%APPDATA%`: a Roaming profile would copy
the runtime at every logon / logoff.

**Profile paths with non-ASCII characters** (**confirmed (live)** 2026-10-23:
a Windows user name taken over from a Microsoft account, `C:\Users\Pipp<è>rr`).
Version 1.0.1 failed at the second start with *"Unable to access jarfile
C:\Users\Pipp?rr\…"* – two causes, both fixed in 1.0.2:

- `state.json` was written with `-Encoding ASCII` → `è` became `?`. Now
  UTF-8, and **no absolute paths are stored at all** – every path is derived
  from `%LOCALAPPDATA%` + version + hash at run time (an old, broken state
  file heals itself).
- The Java launcher converts its command line to the ANSI code page; a
  character outside it would still arrive as `?`. FSAL is therefore started
  with the **jar name only** and the `fsal\` folder as working directory –
  Java gets ASCII arguments only. The path of `javaw.exe` itself goes
  through `CreateProcessW` (Unicode).

Still a limit (**assumption**): a profile path with characters outside the
ANSI code page may break `java.home` detection of the launcher – then a
short ASCII install root would be needed (not implemented).

### 5.3 Order on every start

```
 -Start
   |
   1. GET manifest.json  (timeout 10 s)
   |     unreachable -> log, use the cached manifest, continue with step 5 (offline)
   |
   2. setup.version differs from own version ?  (differs, not "newer":
   |     a server-side rollback must reach the clients too)
   |     yes -> download script to %TEMP%, SHA-256 check, replace itself,
   |            restart with the same arguments (at most once: loop guard)
   |
   3. for java / fsal / jacob: version or sha256 differs from state.json ?
   |     yes -> download to %TEMP% -> SHA-256 check -> extract into a new
   |            versioned directory -> switch state.json only after success
   |            -> keep the previous version, delete older ones
   |
   4. place the JACOB DLL (5.6)
   |
   5. start FSAL (javaw, no console window) with start.url / start.fsalArgs
      of the manifest
```

`-Install` = steps 1–4 + shortcuts (desktop, start menu via
`WScript.Shell`) + step 5; `-Start` (also the default without a switch) =
steps 1–5; `-Uninstall` = remove the folder and the shortcuts; `-Rollback`
= switch `state.json` to the previous version (both are kept on disk).
A changed `shortcutName` takes effect with the next `-Install`.

### 5.4 Starting FSAL

```
"%LOCALAPPDATA%\FormsWeb\java\<version>-<sha8>\bin\javaw.exe"
    -jar frmsal-<version>.jar                 (working directory: …\FormsWeb\fsal)
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

### 5.8 Own root CA on a test client – manual import (no administrator)

Needed only with the own root CA of `08-SSL/ssl_local_ca.sh` (or a company
CA the client does not know yet) and only for the **Windows** side:
PowerShell, the browser and the bootstrap download use the Windows
certificate store. FSAL itself does not need it – the bundled runtime brings
the CA in its `cacerts` (§5.5). In production the CA comes by GPO (customer
IT); this is the way for a test client.

1. **Get the certificate** – on the server `$SSL_CA_DIR/ca/ca.cer` (DER, for
   Windows) or `ca.crt` (PEM); copy it to the client (share, mail, USB).
   Only the public certificate – never `ca.key`.
2. **Note the fingerprints on the server** – Windows shows the SHA-1
   thumbprint in its confirmation dialog:
   ```bash
   openssl x509 -in $SSL_CA_DIR/ca/ca.crt -noout -subject -fingerprint -sha1
   openssl x509 -in $SSL_CA_DIR/ca/ca.crt -noout -fingerprint -sha256
   ```
3. **Import into the user store** – one of:
   - Explorer: double-click `ca.cer` → *Install Certificate* → *Current
     User* → *Place all certificates in the following store* → *Trusted
     Root Certification Authorities* → *Finish*.
   - PowerShell (no administrator):
     ```powershell
     Import-Certificate -FilePath .\ca.cer -CertStoreLocation Cert:\CurrentUser\Root
     ```
   - Command prompt: `certutil -user -addstore Root ca.cer`

   Windows then shows a **security warning** with the thumbprint – compare
   it with step 2 and confirm with *Yes*. This dialog is the reason no
   script can do the import silently for a user root (the chicken-and-egg
   of §5.1: the trust has to exist before the first HTTPS download).
4. **Check:**
   ```powershell
   Get-ChildItem Cert:\CurrentUser\Root | Where-Object Subject -like '*Root CA*' |
       Format-List Subject, Thumbprint, NotAfter
   Invoke-WebRequest -UseBasicParsing https://<host>/formsWeb/manifest.json | Select-Object StatusCode
   ```
   `StatusCode 200` without a certificate error → the bootstrap can run.
5. **Remove again** (test end): `certmgr.msc` → *Trusted Root Certification
   Authorities* → *Certificates* → delete, or
   `Remove-Item Cert:\CurrentUser\Root\<thumbprint>`.

Notes:

- Edge and Chrome use the Windows store; **Firefox** keeps its own store
  (import there, or enable `security.enterprise_roots.enabled`).
- A root in the *user* store is trusted only for this Windows user;
  `Cert:\LocalMachine\Root` (all users) needs an administrator.
- For the Authenticode-signed `FormsWeb-Setup.ps1` (`AllSigned`, §5.1) the
  signing certificate additionally goes into
  `Cert:\CurrentUser\TrustedPublisher` – same procedure with the
  code-signing certificate (`$SSL_CA_DIR/codesign/`).

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
| Problem with a new version | server: `40-oracle_forms_client_bundle.sh --apply --rollback` (makes `manifest.prev.json` current again); client: `FormsWeb-Setup.ps1 -Rollback` |
| Relation to the customer's software deployment | alternative to it – or the SCCM / Intune package carries only `FormsWeb-Install.cmd` |

---

## 8. Test Plan (Windows client)

| # | Test | Expected |
|---|---|---|
| 1 | Bootstrap on a clean user profile (default policy, no admin) | runtime, jars, shortcut in place; form starts |
| 2 | Second start without server change | one manifest request (~1.5 KB), no other download |
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

## 9. Implementation Pieces

| Piece | Change |
|---|---|
| `09-Install/40-oracle_forms_client_bundle.sh` | read-only check / `--apply` builds `FORMS_CLIENT_DIR` (jlink, CA import, manifest, setup scripts) – **done 2026-10-22**, see §10 |
| `09-Install/client_templates/` | `FormsWeb-Setup.ps1`, `FormsWeb-Install.cmd` – **written 2026-10-22**, served on the test host, see §11; Windows client test open |
| Authenticode signature of `FormsWeb-Setup.ps1` | **open** (§12) |
| `09-Install/04-oracle_pre_download.sh` + doc 04 | second getMOSPatch pass for `CLIENT_JDK_PLATFORM` into `client/jdk/<nr>/` – **done 2026-10-22** |
| `09-Install/oracle_software_version.conf` | `CLIENT_JDK_PATCH_NR`, `CLIENT_JDK_PLATFORM` – **done 2026-10-22** |
| `09-Install/nginx-wls.conf.template` + `04-root_nginx.sh` + doc 04 | `location <FORMS_CLIENT_URL_PATH>/` (default `/formsWeb/`) – **done 2026-10-22**, deployed on the test host (200 / 304 / MIME checked) |
| `environment.conf` / `01-setup-interview.sh` | `FORMS_CLIENT_*` (§3.0) – **done 2026-10-22** |
| `09-Install/03-root_user_oracle.sh` | creates `FORMS_CLIENT_DIR` (only Forms + `FORMS_CLIENT_DIST=true`) – **done 2026-10-22** |
| `14-oracle_setup_forms.sh` | optional `fsalJavaVersion` in `[standaloneapp]` – **open** (§12) |
| `07-Maintenance/README.md` | "after every Java / Forms patch: `40- --apply`" – **done 2026-10-22** |

---

## 10. Script `40-oracle_forms_client_bundle.sh`

```
./09-Install/40-oracle_forms_client_bundle.sh                    # read-only: sources, current bundle, what --apply would do
./09-Install/40-oracle_forms_client_bundle.sh --apply            # build if a source changed
./09-Install/40-oracle_forms_client_bundle.sh --apply --force    # rebuild everything
./09-Install/40-oracle_forms_client_bundle.sh --apply --rollback # previous manifest becomes current
```

Runs as oracle. Only for Forms installations with `FORMS_CLIENT_DIST=true`
(otherwise exit 0 with a note).

| Step | What happens |
|---|---|
| 1. Sources | client JDK ZIP from `$PATCH_STORAGE/client/jdk/<CLIENT_JDK_PATCH_NR or JDK_PATCH_NR>/` (no Linux ZIP), the inner `jdk-<ver>_windows-x64_bin.zip` checked against `SHA256_VALUES`; `$ORACLE_HOME/forms/java/frmsal.jar`; JACOB x64 DLL from `$PATCH_STORAGE/jacob/$JACOB_ZIP` (only `FORMS_WEBUTIL_JACOB=true`, size checked against `JACOB_DLL_X64_SIZE`); CA `FORMS_CLIENT_TRUST_CA` (optional) |
| 2. Change check | a fingerprint per component (SHA-256 of the source, module list, runtime mode, CA), the start parameters (URL with `config=` / `form=`, shortcut name) and the icon are compared with the current `manifest.json` – nothing changed → "up to date", nothing written (unless `--force`) |
| 3. Runtime | work directory `mktemp -d`; `jlink` mode: only `jmods/` of the Windows JDK extracted, `$JDK_HOME/bin/jlink` with `FORMS_CLIENT_JLINK_MODULES` (default list of [java_jlink_forms_env.md §3](../../80-FMW-Architecture/java_jlink_forms_env.md#3-the-module-list-for-forms-1412), Windows modules included); `jdk` mode: the whole JDK; then the CA into `lib/security/cacerts` (`keytool`, alias `ihw-forms-ca`); ZIP with the runtime files at the top level → `jre-<JAVA_VERSION>-win-x64.zip` |
| 4. Other files | `frmsal-<forms version>-<sha8>.jar`, `jacob-1.21-x64.dll`; `FormsWeb-Setup.ps1` / `FormsWeb-Install.cmd` from `09-Install/client_templates/` once they exist |
| 5. Manifest | `manifest.json` (schema §3.2) written to a temp file in `FORMS_CLIENT_DIR`, the old one renamed to `manifest.prev.json`, the new one moved into place – the atomic switch for the clients |
| 6. Clean-up | files referenced by neither `manifest.json` nor `manifest.prev.json` are deleted (only our own patterns `jre-*`, `frmsal-*`, `jacob-*`); files 644, owner oracle |

Run it again after every Java CPU / Security Alert (`04-` downloaded a new
client JDK), every Forms patch (new `frmsal.jar`) and every CA change.

---

## 11. Client templates (`09-Install/client_templates/`)

| File | Content |
|---|---|
| `FormsWeb-Install.cmd` | bootstrap; `40-` replaces `@@BASE_URL@@` with `FORMS_CLIENT_BASE_URL` + `FORMS_CLIENT_URL_PATH` when copying it into the bundle; downloads `manifest.json` and `FormsWeb-Setup.ps1`, checks the SHA-256, runs `-Install -BaseUrl …`; CRLF line endings |
| `FormsWeb-Setup.ps1` | the installer / starter of §5; first line of interest `$FormsWebSetupVersion = 'x.y.z'` – `40-` reads it into `setup.version` of the manifest; **raise it with every change**, otherwise clients do not self-update |

Written for **Windows PowerShell 5.1** (default on Windows 10 / 11):

- pure ASCII – 5.1 reads UTF-8 files without BOM as ANSI;
- TLS 1.2 (+ 1.3 if available) forced via `ServicePointManager`;
- `-UseBasicParsing`, `$ProgressPreference = 'SilentlyContinue'` (the
  progress bar slows downloads in 5.1 by orders of magnitude);
- system proxy with the user's credentials;
- `[IO.Compression.ZipFile]::ExtractToDirectory` instead of `Expand-Archive`.

Behaviour (§5.3), as implemented:

- the manifest is fetched on every start with a 10 s timeout (about
  1.5 KB; no ETag handling in the script – `Invoke-WebRequest` in 5.1
  throws on HTTP 304); the large files with 600 s;
- offline → cached `manifest.json` and the installed version;
- self-update with SHA-256 check and one restart (`-Restarted 1`
  = loop guard);
- components compared by SHA-256, the runtime extracted into
  `java\<version>-<sha8>\`, `state.json` keeps `current` + `previous`,
  everything else is removed;
- the JACOB DLL is copied into `%USERPROFILE%\webutil\syslib\<server host>\`
  (assumption 5.6);
- FSAL is started with `javaw.exe -jar frmsal-….jar -url "<start.url>"
  <start.fsalArgs>`;
- errors are shown in a message box (the shortcut runs hidden) and logged
  in `logs\FormsWeb-<date>.log`;
- shortcuts are rewritten on `-Install` and on every online start when the
  shortcut name or the icon (`start.icon`, SHA-256 checked, stored in
  `icons\`) changed on the server; a renamed shortcut replaces the old one;
- 1.0.2 (2026-10-23): non-ASCII profile paths (see §5.2), own icon.

Nginx serves `.ps1` as `text/plain` and `.cmd` as `application/octet-stream`
(the browser saves the bootstrap instead of showing it).

Not yet included: see §12.

---

## 12. Open points (state 2026-10-29)

| # | Point | Next step |
|---|---|---|
| 1 | **Windows client test** – install + FSAL start **done 2026-10-23**; open: update / self-update round (next cycle or `40- --force`), offline start, `-Rollback` | rest of test plan §8 |
| 2 | Cross-built runtime on Windows | **done 2026-10-23** (`javaw.exe` start, TLS with the bundled `cacerts`) |
| 3 | Module list sufficient for WebUtil / JACOB / German locale | test 9 + a form with dates / numbers |
| 4 | Authenticode signature of `FormsWeb-Setup.ps1` | `osslsigncode` with the `FORMS_SIGN_*` keystore in `40-` (only needed under `AllSigned`) |
| 5 | `fsalJavaVersion` in `[standaloneapp]` | `14-oracle_setup_forms.sh` option, value from the bundled runtime |
| 6 | Licence of the jlink runtime (1557737.1) | confirm with Oracle / the customer |
| 7 | CPU October 2026 switch | after the new client JDK download: `40- --apply` (the Windows client JDK is already 21.0.13.0.2) |

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
