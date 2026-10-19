# Step 14 – Oracle Forms Server Detail Configuration

**Scripts:** `09-Install/14-oracle_setup_forms.sh`
**Runs as:** `oracle`
**Phase:** 6 – Forms Server Setup

**Source:** `90-Source-MetaData/oracle_forms_config_ch7_8.md` (Chapters 7–8)
→ Original: *Oracle_WebLogic_Server_14.1.2.0.0_forms_install.pdf*

---

## Overview

This step configures all Oracle Forms runtime files after the domain and
managed servers have been created (Step 8 `08-oracle_setup_domain.sh`).

The configuration uses a **template-copy** approach: customer-edited template
files in `09-Install/forms_templates/` are copied to the correct domain
locations.  No values are generated from `environment.conf` – the customer
controls every parameter directly in the templates.

Steps performed by `14-oracle_setup_forms.sh`:

1. Detect paths (`FR_INST`, `FR_INST_ALT`, Forms app dir)
2. JACOB (only `FORMS_WEBUTIL_JACOB=true`): install jar + DLLs from
   `$PATCH_STORAGE/jacob/`, sign it with `FORMS_SIGN_KEYSTORE` (if set),
   activate only a signed `jacob.jar`
3. Write `webutil.cfg` (Oracle's file + template overrides) to both locations
4. Copy `default.env` to the Forms application config dir
5. Write `formsweb.cfg` (Oracle's file + `[default]` overrides, runtime pooling only in
   `FORMS_PRESTART_SECTION`) to the Forms application config dir
6. Copy `Registry.dat` to the registry subdirectory
7. Copy `fmrweb_utf8.res` and `fmrwebd.res` to the resource directory

**Prerequisites:**

| Prerequisite | Check |
|---|---|
| Domain created | `08-oracle_setup_domain.sh` completed |
| `FORMS_INSTANCE_NAME` set in `environment.conf` | default: `forms1` |
| `WLS_FORMS_SERVER` set in `environment.conf` | default: `WLS_FORMS` |
| Templates in `09-Install/forms_templates/` edited | see [Templates](#templates) |

---

## Required Environment Variables

```bash
# Set by init_env.sh or manually in environment.conf
ORACLE_HOME=/u01/oracle/fmw
DOMAIN_HOME=/u01/user_projects/domains/fr_domain
FORMS_INSTANCE_NAME=forms1        # instance name under FORMS/instances/
WLS_FORMS_SERVER=WLS_FORMS        # managed server with Forms deployed
FORMS_CUSTOMER_DIR=/u01/app/oracle/forms/moduls   # .fmx/.fmb, first FORMS_PATH entry
FORMS_TMP=/u01/app/oracle/forms/tmp               # TMPDIR in default.env
```

Directory layout `$ORACLE_BASE/forms/{moduls,tmp}` (outside `ORACLE_HOME` and
`/tmp`, same idea as `$ORACLE_BASE/reports/{source,images,tmp}`). Step 2b
creates both directories (750) if missing.

---

## Templates

All templates are in `09-Install/forms_templates/`.
See [forms_templates/README.md](../forms_templates/README.md) for a full list
of parameters to adapt.

**Minimum changes before running the script:**

| Template | Must adapt |
|---|---|
| `default.env.template` | `ORACLE_HOME`, `FORMS_INSTANCE`, `TNS_ADMIN`, `FORMS_PATH`, `NLS_LANG`, JDK path in `PATH`/`LD_LIBRARY_PATH`/`LD_PRELOAD` |
| `formsweb.cfg.template` | overrides for `[default]` only (window size, WebUtil); optional `form=`, `pageTitle=` – runtime pooling is NOT set here (`FORMS_PRESTART_SECTION`) |
| `webutil.cfg.template` | `transfer.appsrv.read.N`, `transfer.appsrv.write.N` |
| `Registry.dat.template` | Rename `MyScheme` and set hex colours, or remove the colour scheme section |
| `fmrweb_utf8.res.template` | Only if function key assignment differs from the standard layout |
| `fmrwebd.res.template` | Only if `NLS_LANG` does not use UTF8 |

---

## File Locations (Two-Location Rule)

Some Forms configuration files must exist in **two directories** simultaneously.
The script writes to the primary location and copies to the secondary.

| File | Primary (`instances/`) | Secondary (without `instances/`) |
|---|---|---|
| `webutil.cfg` | `FORMS/instances/forms1/server/` | `FORMS/forms1/server/` |

All other templates are written to a single target location.

### Path Variables

```
FR_INST     = $DOMAIN_HOME/config/fmwconfig/components/FORMS/instances/$FORMS_INSTANCE_NAME
FR_INST_ALT = $DOMAIN_HOME/config/fmwconfig/components/FORMS/$FORMS_INSTANCE_NAME
FORMS_APP   = $DOMAIN_HOME/config/fmwconfig/servers/$WLS_FORMS_SERVER/applications/formsapp_*/config/
```

`FORMS_APP` is detected dynamically by globbing `formsapp_*` (handles version
string differences between 12.2.1.4 and 14.1.2.0.0).

---

## Step 1 – JACOB (WebUtil OLE / Office automation)

**Optional – switch `FORMS_WEBUTIL_JACOB=true|false` in `environment.conf`
(default `false`).** JACOB (Java–COM bridge) is only needed when the Forms
applications use WebUtil OLE (`CLIENT_OLE2`, Word/Excel automation). File
transfer, host commands etc. work without it. Oracle does not ship JACOB
(LGPL). Background: [80-FMW-Architecture/forms_jakob_webutil.md](../../80-FMW-Architecture/forms_jakob_webutil.md).

Version data in `oracle_software_version.conf`: `JACOB_VERSION=1.21` (Forms
14.1.2 is preconfigured for it), `JACOB_URL` (GitHub release
`Root_B-1_21`), `JACOB_SHA256`, `JACOB_DLL_X86_SIZE` / `JACOB_DLL_X64_SIZE`.

With `FORMS_WEBUTIL_JACOB=true`:

1. `04-oracle_pre_download.sh --apply` downloads `jacob-1.21.zip` to
   `$PATCH_STORAGE/jacob/` and verifies the SHA-256 (a mismatching file is
   moved aside as `*.bad_<ts>`).
2. `14-oracle_setup_forms.sh --apply` extracts it to a temp dir, checks the
   DLL sizes against `JACOB_DLL_*_SIZE` (WebUtil compares name **and** size
   from `webutil.cfg`), and installs with backup:

```
$ORACLE_HOME/forms/java/jacob.jar
$ORACLE_HOME/forms/webutil/win32/jacob-1.21-x86.dll
$ORACLE_HOME/forms/webutil/win64/jacob-1.21-x64.dll
```

3. **Signing** (only if `FORMS_SIGN_KEYSTORE` is set and `jacob.jar` is not
   yet signed). `jacob.jar` from the release is unsigned. The script signs it
   with the customer's code-signing certificate – Oracle signs only its own
   jars, own/third-party jars are signed by the customer
   (`forms_jakob_webutil.md` §8):

   | Variable (`environment.conf`) | Meaning | Default |
   |---|---|---|
   | `FORMS_SIGN_KEYSTORE` | PKCS12 keystore with key + code-signing certificate + chain | empty = do not sign (only check) |
   | `FORMS_SIGN_ALIAS` | alias of the key in the keystore | `forms_codesign` |
   | `FORMS_SIGN_TSA_URL` | timestamp authority for `jarsigner -tsa` | empty = no timestamp (WARN) |
   | password | `FORMS_SIGN_STOREPASS` in `forms_sign_sec.conf.des3` (repository root) | – |

   | `FORMS_SIGN_LOCALCA` | `true` = create a missing keystore with the own root CA before signing (set by the interview when the keystore did not exist) | `false` |

   With `FORMS_SIGN_LOCALCA=true` and no file at `FORMS_SIGN_KEYSTORE`,
   `--apply` first runs `08-SSL/ssl_local_ca.sh init --apply` (only if no
   root exists) and `codesign --apply` (subject values from
   `08-SSL/ssl.conf`, written by the interview), then signs. Otherwise a
   missing keystore is a FAIL – nothing is created over a company / public
   keystore that was just not copied yet.

   Where the keystore comes from does not matter: local CA
   (`08-SSL/ssl_local_ca.sh codesign --apply` creates keystore + des3 file
   with these defaults), company CA or public CA (import the PKCS12 file
   from the CA, write the password with the same des3 file).

   Steps:
   - `jacob.jar` → `jacob.jar.orig` (unsigned original, kept for the
     idempotency check below)
   - add the security attributes to the **main section** of the manifest
     (`jar ufm`): `Permissions: all-permissions`, `Codebase: *`,
     `Application-Name: Java-Windows Bridge`. The JACOB release has them
     only in the per-entry section `Name: com/jacob/`; Java reads the
     security attributes from the main section. Strictly required is
     `Permissions` only in the **main** jar of the application ("secondary
     JAR files and extensions are not required to have the Permissions
     attribute"), a missing `Codebase` gives a warning in the Java console
     (**documented**, [JAR File Manifest Attributes for Security](https://docs.oracle.com/javase/8/docs/technotes/guides/deploy/manifest.html)).
     We set them anyway – same as Oracle's `frmwebutil.jar` (main section:
     `Permissions`, `Codebase`, `Application-Name`, **confirmed (live)**) –
     so that the Java console stays clean and the security dialog shows a
     name
   - `jarsigner -keystore … -storetype PKCS12 -storepass:file <tmp> -digestalg SHA-256 [-tsa URL] jacob.jar ALIAS`
     (password only in a temp file, 600, removed by `trap`)
   - `jarsigner -verify` must report `jar verified` without unsigned
     entries; on failure the original jar is restored. **No `-strict`:**
     with an own or company CA the server JDK's `cacerts` does not know the
     root ("PKIX path building failed") – trust is decided on the client,
     where the root is imported. The warning "nonexistent signed entries:
     [com/jacob/]" comes from the per-entry manifest section of the JACOB
     release (a directory) and is harmless.

   **Timestamp:** with `-tsa` the signature stays valid after the
   certificate expires; without it Web Start rejects the jar from the expiry
   date on. Production: always set `FORMS_SIGN_TSA_URL` (public TSA, e.g.
   from the CA of the certificate – needs outbound HTTP from the server).

   **Idempotency:** a signed `jacob.jar` whose `jacob.jar.orig` equals the
   jar of the ZIP is "up to date" – a second run neither re-installs nor
   re-signs. A new JACOB version (other jar in the ZIP) is installed and
   signed again.

4. **Activation only for a signed jar.** Only if `jarsigner -verify`
   succeeds, the script sets `WebUtilArchive=frmwebutil.jar,jacob.jar` in
   `formsweb.cfg` and activates `<jar href="jacob.jar"/>` in
   `$ORACLE_HOME/forms/java/extensions.jnlp` (loaded by `webutil.jnlp` /
   `base.jnlp`; Oracle ships the entry commented out). Otherwise: WARN,
   nothing activated.

   **After every Forms patch:** run `14-oracle_setup_forms.sh --apply` again
   – a patch can reset `extensions.jnlp`; the script re-activates the entry
   (the signed `jacob.jar` itself is not an Oracle file and normally stays).

Manual equivalent:

```bash
mkdir -p $PATCH_STORAGE/jacob && cd $PATCH_STORAGE/jacob
curl -fLO https://github.com/freemansoft/jacob-project/releases/download/Root_B-1_21/jacob-1.21.zip
sha256sum jacob-1.21.zip   # 23a006e84f41443e735cfc3d47f053b995b1454f4ed54c405e7f1e104ef2e073
unzip -q jacob-1.21.zip
cp jacob-1.21/jacob.jar            $ORACLE_HOME/forms/java/
cp jacob-1.21/jacob-1.21-x86.dll   $ORACLE_HOME/forms/webutil/win32/
cp jacob-1.21/jacob-1.21-x64.dll   $ORACLE_HOME/forms/webutil/win64/
# sign (password typed interactively here):
cd $ORACLE_HOME/forms/java && cp -p jacob.jar jacob.jar.orig
printf 'Permissions: all-permissions\nCodebase: *\nApplication-Name: Java-Windows Bridge\n' > /tmp/jacob_mf.txt
$JDK_HOME/bin/jar ufm jacob.jar /tmp/jacob_mf.txt
$JDK_HOME/bin/jarsigner -keystore $FORMS_SIGN_KEYSTORE -storetype PKCS12 \
    -digestalg SHA-256 -tsa http://timestamp.digicert.com jacob.jar forms_codesign
$JDK_HOME/bin/jarsigner -verify -strict jacob.jar
# then WebUtilArchive + extensions.jnlp as in 4.
```

Check that the files are served (no restart needed):

```bash
curl -s -o /dev/null -w "%{http_code} %{size_download}\n" http://localhost:9001/forms/java/jacob.jar
curl -s -o /dev/null -w "%{http_code} %{size_download}\n" http://localhost:9001/forms/webutil/win64/jacob-1.21-x64.dll
```

Live-tested 2026-10-15: download + checksum, install, sizes, HTTP 200 with
the expected sizes; unsigned jar correctly not activated.

Live-tested 2026-10-17 (test host, keystore from `08-SSL/ssl_local_ca.sh
codesign`, TSA `http://timestamp.digicert.com`): `jacob.jar` signed with
timestamp (49846 → 61050 bytes, `jacob.jar.orig` kept), activated
(`WebUtilArchive=frmwebutil.jar,jacob.jar`, `extensions.jnlp` entry), served
via HTTP 200; second run "up to date (signed)", no re-signing; no password
in log files; 2026-10-18 also the `FORMS_SIGN_LOCALCA=true` path (keystore
missing → created by `ssl_local_ca.sh codesign` under the existing root,
then signed). First attempt with `-verify -strict` failed on the PKIX
check (see above) – changed to the integrity check. Client test (Windows,
JWS/FSAL, OLE) still open.

---

## Step 2 – webutil.cfg

**Two locations** – the script keeps them synchronised.

**Location 1 (primary):**
```
$FR_INST/server/webutil.cfg
```
**Location 2 (secondary, kept in sync):**
```
$FR_INST_ALT/server/webutil.cfg
```

**Base is Oracle's own file** `$ORACLE_HOME/forms/templates/config/webutil.cfg`;
`webutil.cfg.template` only overrides keys (since 2026-10-15):

- keys of the template replace the same keys of Oracle's file,
- numbered `transfer.appsrv.read.N` / `write.N` of Oracle's file that the
  template does not set are commented out (`# (IHW removed)`, Oracle's
  `c:\temp` examples),
- template keys that Oracle's file does not have are appended,
- with `FORMS_WEBUTIL_JACOB=true` the jacob `install.syslib` entries are set
  from `JACOB_VERSION` / `JACOB_DLL_*_SIZE`.

Before, the template **replaced** the whole file – all `install.syslib.*`
entries were lost, so WebUtil could not install any native library on the
client (`d2kwut60.dll`, `JNIsharedstubs.dll`, jacob DLLs). The verification
step warns if `install.syslib` entries are missing.

Key parameters in `webutil.cfg.template`:

| Parameter | Purpose |
|---|---|
| `transfer.database.enabled` | Enable DB-based file transfer (`TRUE`/`FALSE`) |
| `transfer.appsrv.enabled` | Enable server-side file transfer |
| `transfer.appsrv.workAreaRoot` | Temp dir for transfer operations (`/tmp`) |
| `transfer.appsrv.accessControl` | Restrict access to listed directories |
| `transfer.appsrv.read.N` | Directories the server may read from |
| `transfer.appsrv.write.N` | Directories the server may write to |

Kept from Oracle's file (do not put into the template unless needed):
`install.syslib.location*`, `install.syslib.<os>.<arch>.<package>.<n>`
(`name|size|version|showDownloadDialog`), `logging.*`.

> Security note: set `accessControl=TRUE` and list only the directories
> actually needed.  Never set `transfer.appsrv.enabled=TRUE` without
> `accessControl=TRUE` in production.

---

## Step 2b – Forms directories

`FORMS_CUSTOMER_DIR` (modules) and `FORMS_TMP` (runtime temp) are created with
mode 750 when missing (`--apply`); existing directories are only checked for
write access. Defaults: `$ORACLE_BASE/forms/moduls`, `$ORACLE_BASE/forms/tmp`.

## Step 3 – default.env

**Location:**
```
$DOMAIN_HOME/config/fmwconfig/servers/$WLS_FORMS_SERVER/applications/formsapp_<version>/config/default.env
```

All path values are `##...##` placeholders, filled by `14-oracle_setup_forms.sh`
from `environment.conf` when it copies the template (`##ORACLE_HOME##`,
`##DOMAIN_HOME##`, `##JDK_HOME##`, `##FORMS_INSTANCE_NAME##`,
`##REPORTS_TOOLS_INSTANCE##`, `##FORMS_CUSTOMER_DIR##`, `##FORMS_TMP##` (`TMPDIR`), `##TNS_ADMIN##` – default
`$DOMAIN_HOME/config/fmwconfig`). The script refuses to write a file with an
unresolved placeholder. Before 2026-10-15 the template contained hard-coded paths
of another host layout (`/u01/oracle/fmw`, `/u01/user_projects/...`, `reptools_ent`)
and a 12c CLASSPATH (`ldapjclnt11.jar`, `jpsmanifest.jar`,
`javax.management.j2ee.jar`, `frmopt.jar` – none of them exist in 14.1.2).
`CLASSPATH` and `LD_LIBRARY_PATH` are written on one line each, like Oracle's own
`default.env` (no documented line continuation).

Parameters in `default.env.template`:

| Parameter | Notes |
|---|---|
| `ORACLE_HOME` | FMW installation root |
| `FORMS_INSTANCE` | Full path to Forms instance dir (= `$FR_INST`) |
| `TNS_ADMIN` | Directory containing `tnsnames.ora` / `sqlnet.ora` |
| `FORMS_PATH` | Colon-separated list of `.fmb`/`.fmx` search dirs |
| `NLS_LANG` | Must match Oracle DB character set (e.g. `GERMAN_GERMANY.UTF8`) |
| `NLS_DATE_FORMAT` | Date display format (`DD.MM.YYYY` for German) |
| `COMPONENT_CONFIG_PATH` | Full path to `ReportsToolsComponent/<instance>` dir |
| `PATH` | Must include `$ORACLE_HOME/bin` and JDK `bin` |
| `LD_LIBRARY_PATH` | Must include `$ORACLE_HOME/lib` and JDK lib paths |
| `LD_PRELOAD` | `libjsig.so` path (JDK-version-specific) |

### CLASSPATH Assembly

The `CLASSPATH` in `default.env` consists of FMW JARs under `$ORACLE_HOME`
(`##ORACLE_HOME##` in the template). The list follows Oracle's 14.1.2
`default.env` – compare with the file the domain creates before changing it.
Key JARs:

| JAR | Purpose |
|---|---|
| `forms/j2ee/frmsrv.jar` | Forms server library |
| `forms/java/frmwebutil.jar` | WebUtil integration |
| `jlib/debugger.jar` | Forms Debugger support |
| `reports/jlib/rwrun.jar` | Forms → Reports integration |
| `oracle_common/modules/oracle.jps/jpsmanifest.jar` | Security / JAZN |

### Alternative: Configure via Enterprise Manager

```
Target Navigation → Forms → Forms1 → Environment Configuration
→ Lock and Edit → Add
```

Minimum parameters to add via EM:

| Parameter | Value |
|---|---|
| `COMPONENT_CONFIG_PATH` | path to ReportsToolsComponent instance |
| `TMPDIR` | `FORMS_TMP` (`$ORACLE_BASE/forms/tmp`) |
| `TNS_ADMIN` | path to tnsnames.ora |
| `NLS_LANG` | e.g. `GERMAN_GERMANY.UTF8` |
| `NLS_LENGTH_SEMANTICS` | `CHAR` |

After all entries: **Apply → Lock icon → Activate Changes**.

---

## Step 4 – formsweb.cfg

**Location:**
```
$DOMAIN_HOME/config/fmwconfig/servers/$WLS_FORMS_SERVER/applications/formsapp_<version>/config/formsweb.cfg
```

**Base = Oracle's file** `$ORACLE_HOME/forms/templates/config/formsweb.cfg`
(identical to the `formsweb.cfg.jmxori` of a new domain). The template only
overrides / adds keys in `[default]`; all Oracle sections stay:
`[sepwin]`, `[debug]`, `[webutil]`, `[jnlp]`, `[webutil_jnlp]`, **`[webstart]`**,
`[webutil_webstart]`, **`[standaloneapp]`**, `[webutil_standaloneapp]`, plus
`serverArgs`, `otherparams`, `java_version=1.8+`, `fsalcheck`.

> **Fixed 2026-10-16:** before, the template (12c content) replaced the whole
> file – no `[webstart]`/`[standaloneapp]`, no `serverArgs`, empty
> `otherparams`, `frmopt.jar` (does not exist in 14.1.2), `java_version=1.7+`.
> `config=webstart` then fell back to `[default]` and the browser showed
> "Oracle Java is required to run this application … Consider using Java Web
> Start or Standalone Launcher instead".

The `[default]` section contains global defaults.
Application-specific sections (e.g. `[myapp]`) **override** individual
parameters for a specific URL parameter `config=myapp` – add them in the
deployed file or via EM (the overlay only touches `[default]`).

How to start a form in 14.1.2 (browsers have no Java plugin any more):

| Client | URL / command | Section |
|---|---|---|
| Java Web Start | `https://<host>/forms/frmservlet?config=webstart&form=<module>` → `.jnlp` (`javaws` / OpenWebStart) | `[webstart]` |
| Standalone Launcher (FSAL) | `java -jar frmsal.jar -url "https://<host>/forms/frmservlet?config=standaloneapp&form=<module>" -t 30000` – `frmsal.jar` from `https://<host>/forms/html/fsal.htm` | `[standaloneapp]` |
| Browser + Java plugin (legacy) | `https://<host>/forms/frmservlet?form=<module>` | `[default]` |

With WebUtil: `config=webutil_webstart` / `config=webutil_standaloneapp`.

Key parameters:

| Parameter | Notes |
|---|---|
| `form=` | Default start form (`.fmx` filename, no path) |
| `envFile=` | Points to `default.env` (relative name, not full path) |
| `serverURL=` | `/forms/lservlet` (do not change) |
| `codebase=` | `/forms/java` (do not change) |
| `prestartRuntimes` / `prestartInit` / `prestartMin` / `prestartIncrement` | Runtime pooling = pre-started **Forms runtime (`frmweb`) processes** – only in the section `FORMS_PRESTART_SECTION`, never in `[default]` (see below) |
| `WebUtilArchive=` | `##WEBUTIL_ARCHIVE##` – set by the script: `frmwebutil.jar`, plus `jacob.jar` when `FORMS_WEBUTIL_JACOB=true` and the jar is signed (Step 1) |

> `formsweb.cfg` is **not** reloaded automatically after changes.
> Restart WLS_FORMS to pick up changes.

### Runtime pooling (prestart) – one section only

Oracle (*Working with Oracle Forms 14.1.2*, "Setting the prestartRuntimes
Parameter"): "It is recommended not setting the parameter in the [default]
section. Doing so will result in processes being started for all other
configurations unless overridden with a value of FALSE".

> **Fixed 2026-10-19:** the template set `prestartRuntimes=true` +
> `prestartInit=5` in `[default]` – every one of the 10 Oracle sections
> inherited it, the test host ran **50 `frmweb` processes without a user**
> (log: `FRM-93412 There are 5 prestarted runtime processes in the runtime
> process pool for configuration section [default]` – one line per section).

Now:

| Variable (`environment.conf`) | Default | Effect |
|---|---|---|
| `FORMS_PRESTART_SECTION` | empty | section that gets the prestart keys (the one users start, e.g. `webstart`, `standaloneapp` or an own `[myapp]`); empty = no runtime pooling (Oracle default) |
| `FORMS_PRESTART_INIT` | `5` | `prestartInit` – runtimes started at WLS_FORMS start |
| `FORMS_PRESTART_MIN` | `4` | `prestartMin` – kept in the pool (Oracle: must be <= Init) |
| `FORMS_PRESTART_INCREMENT` | `1` | `prestartIncrement` |

The script builds `formsweb.cfg` from Oracle's file (which has no prestart
keys), so a re-run removes old prestart lines from `[default]` automatically,
then sets the four keys in `FORMS_PRESTART_SECTION` (`frm_cfg_set` of
`06-FormsDiag/forms_lib.sh`). A section name that is not in the file → WARN,
nothing set. On an existing environment without re-installation:
`06-FormsDiag/forms_perf_settings.sh --apply --fix-prestart <section>`.
Background: [forms_runtime_architecture.md](../../80-FMW-Architecture/forms_runtime_architecture.md).

---

## Step 5 – Registry.dat

**Location:**
```
$DOMAIN_HOME/config/fmwconfig/servers/$WLS_FORMS_SERVER/applications/formsapp_<version>/config/oracle/forms/registry/Registry.dat
```

Key sections:

| Section | Purpose |
|---|---|
| `default.fontMap.*` | Maps Forms application font names to Java fonts |
| `app.ui.*` | UI features (LOV buttons, required field highlighting) |
| `colorScheme.<name>.*` | Custom colour scheme hex values |

The custom colour scheme name must match `customColorScheme=<name>` in
`formsweb.cfg [default]` (and any section that uses it).

> If no custom colour scheme is needed, remove the `colorScheme.MyScheme.*`
> entries from the template and leave `customColorScheme=` empty in
> `formsweb.cfg`.

---

## Step 6 – Keyboard Resources

**Location:**
```
$FR_INST/admin/resource/D/fmrweb_utf8.res   ← used when NLS_LANG ends in UTF8
$FR_INST/admin/resource/D/fmrwebd.res       ← used for non-UTF8 NLS
```

Both files use the format:
```
KeyCode : Modifier : "KeyLabel" : FunctionCode : "Description"
```

Modifiers: `0` = none, `1` = Shift, `2` = Ctrl, `3` = Shift+Ctrl.

The templates contain a standard German layout. Change key codes only if
your application uses different function key assignments.

> Always back up the originals before replacing:
> `cp fmrweb.res fmrweb.res.ori`
> `cp fmrweb_utf8.res fmrweb_utf8.res.ori`

---

## Verification

```bash
# Check Forms servlet is responding
curl -s "http://localhost:${WLS_FORMS_PORT:-9001}/forms/frmservlet"
# Expected: HTTP 200 or redirect to login

# Check WLS_FORMS managed server log
tail -100 $DOMAIN_HOME/servers/$WLS_FORMS_SERVER/logs/$WLS_FORMS_SERVER.log

# Verify default.env loaded by Forms
grep 'FORMS_PATH\|NLS_LANG' \
    $DOMAIN_HOME/servers/$WLS_FORMS_SERVER/logs/$WLS_FORMS_SERVER.log
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `NullPointerException` on form startup | `FORMS_PATH` incorrect or missing `.fmx` | Check `FORMS_PATH` in `default.env` |
| `ORA-12154: TNS:could not resolve service` | `TNS_ADMIN` pointing to wrong directory | Verify `tnsnames.ora` location |
| WebUtil file transfer fails | `webutil.cfg` read/write dirs missing | Add directories to `webutil.cfg` |
| Wrong date format displayed | `NLS_DATE_FORMAT` not set | Add `NLS_DATE_FORMAT=DD.MM.YYYY` to `default.env` |
| Custom colour scheme not applied | Name mismatch between `Registry.dat` and `formsweb.cfg` | Verify `customColorScheme=<name>` matches `colorScheme.<name>.*` |
| Forms loads but keyboard mapping wrong | Wrong `.res` file active | Check `NLS_LANG` → determines which `.res` file is used |
| `jacob.jar is not signed – NOT activated` | release jar is unsigned | sign `jacob.jar` (open TODO), re-run `--apply` (Step 1) |
| JACOB ZIP not found / SHA-256 mismatch | not downloaded / damaged | `04-oracle_pre_download.sh --apply` (Step 1) |
| WebUtil cannot install DLLs on the client | `webutil.cfg` without `install.syslib` entries (template before 2026-10-15) | re-run `14-oracle_setup_forms.sh --apply` (Step 2) |

---

## Related Scripts and Documents

| Item | Purpose |
|---|---|
| `09-Install/14-oracle_setup_forms.sh` | Copy templates to domain locations |
| `09-Install/forms_templates/` | Customer-edited configuration templates |
| `09-Install/forms_templates/README.md` | Template editing guide |
| `09-Install/11-oracle_nodemanager.sh` | NodeManager plain mode (prerequisite) |
| `09-Install/13-oracle_setup_reports.sh` | Reports Server setup (parallel step) |
| `04-ReportsFonts/uifont_ali_update.sh` | Font configuration for Reports (shares `REPORTS_FONT_DIR`) |
| `90-Source-MetaData/oracle_forms_config_ch7_8.md` | Source document (Chapters 7–8) |
