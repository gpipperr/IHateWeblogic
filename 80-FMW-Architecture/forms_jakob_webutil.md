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
  no own signing script). Whether FSAL needs the signature as well is
  still to be verified (**assumption**).
- The size of the DLL is checked by WebUtil at download time – a DLL of a
  different build fails even with the same name (**documented** in the
  `webutil.cfg` comments: "Change size and version if necessary").

## 8. State on the test host (2026-10-15, confirmed (live))

| Item | State |
|---|---|
| `jacob.jar`, `jacob-1.21-*.dll` | missing (14 only warns) |
| `d2kwut60.dll`, `JNIsharedstubs.dll` | present (shipped) |
| `webutil.cfg` of the instance | written by `14-` from `forms_templates/webutil.cfg.template` – contains only the `transfer.*` lines, **all `install.syslib.*` entries are missing** → WebUtil cannot install any native library on the client (also not `d2kwut60.dll`) |
| `formsweb.cfg` | `WebUtilArchive=frmwebutil.jar` (without `jacob.jar`) |
| `extensions.jnlp` | `jacob.jar` entry commented out (Oracle default) |
| hints in `14-` / doc 14 | still refer to `jacob-1.18-M2` and SourceForge |

## Summary

WebUtil solves the basic problem that Oracle Forms runs on the server but
needs resources of the Windows client. For normal file operations WebUtil uses
Java functions. For Microsoft Office automation it additionally uses JACOB,
the bridge between Java and the Windows COM world – a jar that must be signed
and a native DLL per architecture, both downloaded separately from GitHub.
