# Step 14 – Oracle Forms Server Detail Configuration

**Scripts:** `09-Install/14-oracle_setup_forms.sh`
**Runs as:** `oracle`
**Phase:** 8 – Forms Server Setup

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
2. Check jacob.jar + WebUtil DLLs (check only – no auto-install)
3. Copy `webutil.cfg` to both required locations
4. Copy `default.env` to the Forms application config dir
5. Copy `formsweb.cfg` to the Forms application config dir
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
```

---

## Templates

All templates are in `09-Install/forms_templates/`.
See [forms_templates/README.md](../forms_templates/README.md) for a full list
of parameters to adapt.

**Minimum changes before running the script:**

| Template | Must adapt |
|---|---|
| `default.env.template` | `ORACLE_HOME`, `FORMS_INSTANCE`, `TNS_ADMIN`, `FORMS_PATH`, `NLS_LANG`, JDK path in `PATH`/`LD_LIBRARY_PATH`/`LD_PRELOAD` |
| `formsweb.cfg.template` | `form=` (start form), `pageTitle=` |
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

## Step 1 – jacob.jar and WebUtil DLLs

**Manual step – not automated.**

Oracle Forms WebUtil requires `jacob.jar` (Java-COM bridge) and platform DLLs
for Windows-client file operations.  The script checks for their presence and
prints the copy commands when they are missing.

**Target locations:**

```
$ORACLE_HOME/forms/java/jacob.jar
$ORACLE_HOME/forms/webutil/win32/jacob-<version>-x86.dll
$ORACLE_HOME/forms/webutil/win64/jacob-<version>-x64.dll
```

**Manual installation:**

```bash
# Download jacob from https://sourceforge.net/projects/jacob-project/
# or copy from patch storage

cp <PATCH_STORAGE>/jacob-1.18-M2/jacob.jar          $ORACLE_HOME/forms/java/
cp <PATCH_STORAGE>/jacob-1.18-M2/jacob-1.18-M2-x86.dll  $ORACLE_HOME/forms/webutil/win32/
cp <PATCH_STORAGE>/jacob-1.18-M2/jacob-1.18-M2-x64.dll  $ORACLE_HOME/forms/webutil/win64/
```

> **Note:** jacob is only required if your Forms applications use WebUtil for
> Windows client-side file operations (reading/writing local files, COM
> automation). Forms without WebUtil do not need jacob.

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

Key parameters in `webutil.cfg.template`:

| Parameter | Purpose |
|---|---|
| `transfer.database.enabled` | Enable DB-based file transfer (`TRUE`/`FALSE`) |
| `transfer.appsrv.enabled` | Enable server-side file transfer |
| `transfer.appsrv.workAreaRoot` | Temp dir for transfer operations (`/tmp`) |
| `transfer.appsrv.accessControl` | Restrict access to listed directories |
| `transfer.appsrv.read.N` | Directories the server may read from |
| `transfer.appsrv.write.N` | Directories the server may write to |

> Security note: set `accessControl=TRUE` and list only the directories
> actually needed.  Never set `transfer.appsrv.enabled=TRUE` without
> `accessControl=TRUE` in production.

---

## Step 3 – default.env

**Location:**
```
$DOMAIN_HOME/config/fmwconfig/servers/$WLS_FORMS_SERVER/applications/formsapp_<version>/config/default.env
```

Key parameters to adapt in `default.env.template`:

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

The `CLASSPATH` in `default.env` consists of FMW JARs under `$ORACLE_HOME`.
When changing `ORACLE_HOME`, update all CLASSPATH entries accordingly.
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
| `TMPDIR` | `/tmp` |
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

The `[default]` section contains global defaults.
Application-specific sections (e.g. `[myapp]`) **override** individual
parameters for a specific URL parameter `config=myapp`.

Key parameters:

| Parameter | Notes |
|---|---|
| `form=` | Default start form (`.fmx` filename, no path) |
| `envFile=` | Points to `default.env` (relative name, not full path) |
| `serverURL=` | `/forms/lservlet` (do not change) |
| `codebase=` | `/forms/java` (do not change) |
| `separate_jvm=true` | Recommended for WebUtil; each client gets its own JVM |
| `prestartInit` / `prestartMin` / `prestartIncrement` | Pre-started JVM tuning |
| `WebUtilArchive=` | `frmwebutil.jar` (add `jacob.jar` when WebUtil file transfer is used) |

> `formsweb.cfg` is **not** reloaded automatically after changes.
> Restart WLS_FORMS to pick up changes.

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
curl -s "http://localhost:${WLS_FORMS_PORT:-8001}/forms/frmservlet"
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
| `jacob.jar` not found warning | WebUtil DLL missing | Copy jacob files manually (Step 1) |

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
