# Step 13 – Reports Server Detail Configuration

**Scripts:** `09-Install/13-root_reports_fix.sh` · `09-Install/13-oracle_setup_reports.sh`
**Runs as:** `root` (fix step) then `oracle`
**Phase:** 6 – Reports Server Setup

**Source:** `90-Source-MetaData/oracle_reports_config_ch6.md` (Kapitel 6, Seiten 83–98)
→ Original: *Oracle_WebLogic_Server_14.1.2.0.0_setup_reports.pdf*

---

## Overview

This step creates and configures the Oracle Reports Server system components
within the WebLogic domain.  It covers:

1. OS-level fix for Oracle Linux 9 (`libnsl.so.2`)
2. Creating the ReportsTools and ReportsServer instances via WLST
3. Configuring the UDP broadcasting port (`rwnetwork.conf`)
4. Configuring `rwservlet.properties` (servlet → server mapping)
5. Configuring `rwserver.conf` (engine, environment, queue, folder access)
6. Configuring `reports.sh` (font and locale environment variables)
7. Starting and stopping system components
8. Font and Unicode configuration (`uifont.ali`)

**Prerequisites:**

| Prerequisite | Check |
|---|---|
| AdminServer running | `ss -tlnp \| grep 7001` |
| NodeManager running (plain mode) | `11-oracle_nodemanager.sh` completed |
| `boot.properties` written | `10-oracle_boot_properties.sh --apply` done |
| `environment.conf` has Reports variables | see [Required Variables](#required-environment-variables) |

---

## Required Environment Variables

Add to `environment.conf` (populated by `00-Setup/init_env.sh --apply` – run it once
after `08-`; on a fresh domain it takes the Reports server name from the setup
interview `REPORTS_SERVER_NAMES` and `REPORTS_PATH` from `REPORTS_CUSTOMER_DIR`):

```bash
# Reports system component instance names
REPORTS_TOOLS_INSTANCE="reptools_ent"       # Always exactly one per domain
REPORTS_SERVER_INSTANCES="repserver_ent"    # Space-separated; multiple allowed

# Reports runtime paths
REPORTS_PATH="/u01/app/oracle/reports/source:/u01/app/oracle/reports/images"   # report sources + images (':')
REPORTS_TMP="/u01/app/oracle/reports/tmp"                               # output directory (not /tmp - cleaned at reboot)
# 13- creates these directories (750) - default layout $ORACLE_BASE/reports/{source,images,tmp}

# Broadcasting port – unique per environment within the subnet (range: 14021–14030)
# See: Oracle Support Note Doc ID 437228.1
# 14027 = FMW 14.1.2.0.0 production, 14028 = standby
REPORTS_BROADCAST_PORT="14027"

# rwservlet.properties
REPORTS_SERVER_NAME="repserver_ent"         # <server> element (must match instance name)
REPORTS_COOKIE_KEY=""                       # Encryption key for session cookie (random string)

# rwserver.conf engine tuning
REPORTS_ENGINE_INIT="2"                     # initEngine: pre-started engine processes
REPORTS_ENGINE_MAX="5"                      # maxEngine: maximum concurrent engines
REPORTS_ENGINE_MIN="2"                      # minEngine: minimum idle engines
REPORTS_MAX_CONNECT="300"                   # connection maxConnect
REPORTS_MAX_QUEUE="4000"                    # queue maxQueueSize

# TNS / database
TNS_ADMIN="/app/oracle/19c/network/admin"   # Oracle Net configuration directory
```

---

## Step 1 – OS Fix: `libnsl.so.2` Symlink (root, Oracle Linux 9 only)

**Issue:** Oracle Reports 14c on OL9 fails to start the standalone Reports Server
with the error:

```
error while loading shared libraries: libnsl.so.2: cannot open shared object file:
No such file or directory
```

**Root cause:** OL9 ships `libnsl.so.3.0.0` but Oracle Reports was compiled against
`libnsl.so.2`.

**Oracle Support Note:** *Doc ID 3069675.1* –
"Oracle Reports 14c on Linux 9.X for Standalone Report Server Startup Shows Error
'libnsl.so.2: cannot open shared object file'"

**Fix (as root):**

```bash
ln -s /lib64/libnsl.so.3 $ORACLE_HOME/lib/libnsl.so.2

# Verify
ls -la $ORACLE_HOME/lib/libnsl.so.2
```

> This symlink is only required on Oracle Linux 9 / RHEL 9.
> Link to the stable SONAME link `/lib64/libnsl.so.3` (package `libnsl2`, itself
> a link to `libnsl.so.3.0.0`) – **not** to the versioned file: its name depends
> on the package version and can change with an OS update.
> Verify with `readlink -f $ORACLE_HOME/lib/libnsl.so.2` (must resolve to an
> existing file) and `ldd $ORACLE_HOME/bin/rwserver | grep libnsl`.

---

## Step 2 – Create System Component Instances (WLST)

**Prerequisites:** AdminServer and NodeManager must be running.

### 2.1 ReportsTools Instance

The ReportsTools component is required when Oracle Reports are called from
Oracle Forms and the Forms and Reports managed servers run on **different machines**.
There is always exactly **one** ReportsTools instance per domain.

```bash
$ORACLE_HOME/oracle_common/common/bin/wlst.sh
```

```python
# In WLST shell:
connect('weblogic', '<password>', 't3://localhost:7001')
createReportsToolsInstance(instanceName='reptools_ent', machine='AdminServerMachine')
exit()
```

**Expected output:**
```
Reports Tools instance "reptools_ent" was successfully created.
```

**Created directory:**
```
$DOMAIN_HOME/system_components/ReportsToolsComponent/reptools_ent/data/nodemanager/
```

### 2.2 ReportsServer Instance(s)

Multiple ReportsServer instances are possible (e.g., one for interactive reports,
one for batch jobs).  Create one instance per entry in `REPORTS_SERVER_INSTANCES`.

> **The domain needs the template "Oracle Reports Server".**
> `createReportsServerInstance` needs the MBean `ReportsServerComponentManager`,
> which the AdminServer registers from
> `config/fmwconfig/components/ReportsServerComponent/mbeans/mbeans.xml`. Only the
> domain template `ReportsServerComponent/common/templates/wls/oracle.reports_server_template.jar`
> ("Oracle Reports Server") brings it – `oracle.reports_app_template.jar` only pulls
> in "Oracle Reports Tools". Without it:
> `Attribute oracle.reports:Type=ReportsServerComponent,Name=ReportsServerComponentManager not found`
> (confirmed 2026-10-15; a running WLS_REPORTS does not change that).
> `08-oracle_setup_domain.sh` adds the template since 2026-10-15. An existing
> domain is extended offline (stop all servers first):
>
> ```python
> # wlst.sh (offline)
> readDomain('/u01/app/oracle/domains/fr_domain')
> addTemplate('/u01/app/oracle/fmw/ReportsServerComponent/common/templates/wls/oracle.reports_server_template.jar')
> updateDomain()
> closeDomain()
> ```
>
> Then start AdminServer (+ WLS_REPORTS) and re-run `13-`. The first start of
> WLS_REPORTS also creates the application directory with
> `rwservlet.properties`, `rwnetwork.conf` and `cgicmd.dat`.

```python
connect('weblogic', '<password>', 't3://localhost:7001')
createReportsServerInstance(instanceName='repserver_ent', machine='AdminServerMachine')
exit()
```

**Expected output:**
```
Reports Server instance "repserver_ent" was successfully created.
```

**Created directory:**
```
$DOMAIN_HOME/system_components/ReportsServerComponent/repserver_ent/data/nodemanager/
```

---

## Step 3 – Broadcasting Port (`rwnetwork.conf`)

### Background

The JDK UDP broadcasting mechanism makes all Reports Servers visible within the
same subnet. Two Reports Server instances with the **same name** in the same subnet
conflict with each other.  The solution is to assign a **unique broadcasting port
per environment**.

**Oracle Support Note:** *Doc ID 437228.1* –
"How to Create Two Reports Servers With the Same Name in the Same Subnet"

**Important:** The port must be changed in `rwnetwork.conf` for **all** Reports
components on the machine — including unused instances and the InProcess server.

### Port Assignment Table (range: 14021–14030)

| Environment | Port |
|---|---|
| Legacy environment | 14021 |
| Legacy standby | 14022 |
| New environment | 14023 |
| New standby | 14024 |
| FMW 12.2.1.4 production | 14025 |
| FMW 12.2.1.4 standby | 14026 |
| **FMW 14.1.2.0.0 production** | **14027** |
| **FMW 14.1.2.0.0 standby** | **14028** |

### Files to Modify (3 locations)

```
$DOMAIN_HOME/config/fmwconfigcomponents/ReportsToolsComponent/<REPORTS_TOOLS_INSTANCE>/rwnetwork.conf
$DOMAIN_HOME/config/fmwconfigcomponents/ReportsServerComponent/<REPORTS_SERVER_INSTANCE>/rwnetwork.conf
$DOMAIN_HOME/config/fmwconfig/servers/WLS_REPORTS/applications/reports_14.1.2/configuration/rwnetwork.conf
```

### Change in each `rwnetwork.conf`

Locate the `<multicast>` element (14.1.2; `<cluster>` in older releases) and change the `port` attribute:

```xml
<!-- Before -->
<multicast channel="228.5.6.7" port="14021" timeout="1000"/>

<!-- After (14.1.2.0.0 production) -->
<multicast channel="228.5.6.7" port="14027" timeout="1000"/>
```

---

## Step 4 – Configure `rwservlet.properties`

**Location** (one file per WLS_REPORTS managed server):
```
$DOMAIN_HOME/config/fmwconfig/servers/WLS_REPORTS/applications/reports_14.1.2/configuration/rwservlet.properties
```

> **Before editing:** Stop WLS_REPORTS and AdminServer.
> After changes, start in order: AdminServer → WLS_REPORTS → Reports Server component.

**Target content:**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rwservlet xmlns="http://xmlns.oracle.com/reports/rwservlet"
           xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <server>repserver_ent</server>
  <singlesignon>yes</singlesignon>
  <inprocess>no</inprocess>
  <webcommandaccess>L1</webcommandaccess>
  <cookie cookieexpire="30" encryptionkey="<REPORTS_COOKIE_KEY>"/>
</rwservlet>
```

**Key attributes:**

| Element | Value | Meaning |
|---|---|---|
| `<server>` | `repserver_ent` | Name of the standalone Reports Server instance |
| `<singlesignon>` | `yes` | Use WebLogic SSO |
| `<inprocess>` | `no` | Use standalone server, not in-process servlet |
| `<webcommandaccess>` | `L1` | Restrict web commands to authenticated users |
| `encryptionkey` | random string | Session cookie encryption; generate once and keep stable |

### Alternative: Configure via Enterprise Manager MBean Browser

```
EM → WebLogic Domain → System-MBean Browser
  → Anwendungsdefinierte MBeans → oracle.reportsApp.config
    → Server.WLS_REPORTS → Application.reports → ReportsApp → rwservlet
```

Lock & Edit, then set:

| Attribute | Old | New |
|---|---|---|
| Server | (hostname-based default) | `repserver_ent` |
| Inprocess | `yes` | `no` |
| WebcommandAccess | (empty) | `L1` |

---

## Step 5 – Configure `rwserver.conf`

**Location** (one file per ReportsServer instance):
```
$DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent/<instance>/rwserver.conf
```

> Back up the original file before editing.
> Check `rwserver_diagnostic.log` for XML parsing errors after changes.

**Target content:**

```xml
<?xml version="1.0" encoding="ISO-8859-1"?>
<server xmlns="http://xmlns.oracle.com/reports/server"
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">

  <cache class="oracle.reports.cache.RWCache">
    <property name="cacheSize" value="50"/>
  </cache>

  <!-- Engine configuration -->
  <!-- initEngine/maxEngine/minEngine: tune to available CPUs and load -->
  <engine id="rwEng" class="oracle.reports.engine.EngineImpl"
          initEngine="2" maxEngine="5" minEngine="2"
          engLife="50" defaultEnvId="QS"/>
  <engine id="rwURLEng" class="oracle.reports.urlengine.URLEngineImpl"
          maxEngine="1" minEngine="0" engLife="50"/>

  <!-- Environment QS: variables passed to each report engine process -->
  <environment id="QS">
    <envVariable name="REPORTS_PATH"        value="/u01/app/oracle/reports/source:/u01/app/oracle/reports/images"/>
    <envVariable name="REPORTS_TMP"         value="/u01/app/oracle/reports/tmp"/>
    <envVariable name="NLS_LANG"            value="GERMAN_GERMANY.AL32UTF8"/>
    <envVariable name="TNS_ADMIN"           value="/app/oracle/19c/network/admin"/>
    <envVariable name="REPORTS_JVM_OPTIONS" value="-Djobid=random -DORBWaitForResponseTimeout=999999999"/>
  </environment>

  <!-- Security: JAZN-based (WebLogic security realm) -->
  <security id="rwJaznSec" class="oracle.reports.server.RWJAZNSecurity"/>

  <!-- Destination plugins -->
  <destination destype="ftp"    class="oracle.reports.plugin.destination.ftp.DesFTP"/>
  <destination destype="WebDav" class="oracle.reports.plugin.destination.webdav.DesWebDAV"/>

  <!-- REPORTS_SECURITY=ldap (default): securityId - users/roles checked against
       the JSE identity store (jps-config-jse.xml -> WebLogic embedded LDAP, Step 5a) -->
  <job jobType="report" engineId="rwEng" securityId="rwJaznSec" retry="3"/>
  <job jobType="rwurl"  engineId="rwURLEng"/>

  <notification id="mailNotify" class="oracle.reports.server.MailNotify">
    <property name="succnotefile" value="succnote.txt"/>
    <property name="failnotefile" value="failnote.txt"/>
  </notification>

  <!-- jobStatusRepository: keep commented out unless DB repository is required -->
  <!--
  <jobStatusRepository class="oracle.reports.server.JobRepositoryDB">
    <property name="dbuser"     value="..."/>
    <property name="dbpassword" value="csf:..."/>
    <property name="dbconn"     value="..."/>
  </jobStatusRepository>
  -->

  <connection maxConnect="300" idleTimeOut="15"/>
  <queue maxQueueSize="4000"/>

  <!-- folderAccess: read = report source directory, write = temp output directory -->
  <folderAccess>
    <read>/u01/app/oracle/reports/source;/u01/app/oracle/reports/images</read>
    <write>/u01/app/oracle/reports/tmp</write>
  </folderAccess>

  <!-- Reports server administrator (not a WebLogic user), from reports_admin_sec.conf.des3 -->
  <identifier encrypted="no">rep_admin/<password from reports_admin_sec.conf.des3></identifier>

  <proxyInfo>
    <proxyServers>
      <proxyServer name="$$Self.proxyHost$$" port="$$Self.proxyPort$$" protocol="all"/>
    </proxyServers>
    <bypassProxy>
      <domain>$$Self.proxyByPass$$</domain>
    </bypassProxy>
  </proxyInfo>

  <pluginParam name="mailServer" value="%MAILSERVER_NAME%"/>
</server>
```

**Key configuration points:**

| Element | Notes |
|---|---|
| `<engine initEngine>` | Pre-started processes; set = `minEngine` |
| `<environment id="QS">` | `QS` is the default env ID referenced by `defaultEnvId` |
| `<envVariable NLS_LANG>` | Must match Oracle DB character set |
| `<envVariable TNS_ADMIN>` | Must point to `tnsnames.ora` for DB connections |
| `<job … securityId>` | `rwJaznSec` with `REPORTS_SECURITY=ldap` (Step 5a). Without the LDAP identity store every WebLogic user fails with `REP-50171` – then (`REPORTS_SECURITY=identifier`) leave it out. The old statement "causes startup errors" is wrong: the server starts fine (tested 2026-10-16) |
| `<identifier>` | Reports server admin (not a WebLogic user): `REPORTS_ADMIN_USER` (default `rep_admin`) + password from `reports_admin_sec.conf.des3` (asked by `01-setup-interview.sh`; missing → `--apply` generates a random one and stores it). Letters/digits only – `/ & < > " '` and blanks are rejected. `rwserver.conf` gets mode 640 |
| `<folderAccess><read>` | Reports Server will only read `.rdf` files from these directories. **Exactly one** `<read>`; several directories separated by **`;`** – also on Linux (`13-` converts the `:` of `REPORTS_PATH`). `:` / `,` are taken as one directory name, two `<read>` elements → only the last counts, subdirectories are not included; outside → `REP-56132 Access is denied to the report definition file` (test series 2026-10-16, [report_server_image_handling.md](../../80-FMW-Architecture/report_server_image_handling.md)) |
| `<folderAccess><write>` | Output files written here; must be writable by oracle user |

### Alternative: Configure via Enterprise Manager MBean Browser

```
EM → WebLogic Domain → System-MBean Browser → Konfigurations-MBeans
  → oracle.reports.serverconfig → ReportsServer → rwserver-repserver_ent
```

| MBean path | Operation | Values |
|---|---|---|
| `Vorgänge → addEnvironment` | Create env | `QS` |
| `ReportsServerEnvironment → QS → addEnvVariable` | Add variables | see table above |
| `ReportsServer.Engine → rwEng` | Set engine params | `DefaultEnvId=QS`, `initEngine=2`, `MaxEngine=5`, `minEngine=2` |
| `ReportsServer.Job → rwEngrwJaznSec` | Fix job | `Retry=3`, `SecurityId=rwJaznSec` (only with the LDAP identity store, Step 5a) |
| `ReportsServer.Queue → Queue` | Set queue size | `MaxQueueSize=4000` |
| `ReportsServer.Connection → Connection` | Set connections | `maxConnect=300` |

After all MBean changes: **Lock & Edit → Save → Activate Changes → restart WLS_REPORTS**.

---

## Step 5a – Secured Reports server: JSE identity store = WebLogic embedded LDAP

`REPORTS_SECURITY` in `environment.conf`: `ldap` (default) or `identifier`.
Background, diagrams and test run:
[80-FMW-Architecture/reports_user_local_ldap.md](../../80-FMW-Architecture/reports_user_local_ldap.md).

The standalone Reports server (`rwserver`, Java SE) reads OPSS from
`$DOMAIN_HOME/config/fmwconfig/jps-config-jse.xml`: policy and credential
store are the shared DB stores, but the **identity store is XML**
(`system-jazn-data.xml`). WebLogic users are unknown to it. With `ldap` the
script points this identity store to the embedded LDAP of the AdminServer and
sets `securityId="rwJaznSec"` – then `monUser`/`RW_MONITOR`
(`getserverinfo`) and `RepRunner`/`RW_EXECREPORTS` (report jobs) work as with
an in-process Reports server.

| `REPORTS_SECURITY` | web commands (`getserverinfo`) | report jobs |
|---|---|---|
| `ldap` | users with `WebCommandPermission` (`RW_MONITOR`), plus `<identifier>` | users with `ReportsPermission` (`RW_EXECREPORTS`); without login HTTP 499 |
| `identifier` | only the `<identifier>` admin (others `REP-52262`) | **no user check** – DB `userid` + `<folderAccess>` only |

Steps of the script (with `--apply`, AdminServer running):

1. Prerequisite: password of the embedded LDAP administrator `cn=Admin` in
   `embedded_ldap_sec.conf.des3` – asked by `01-setup-interview.sh`
   (`REPORTS_SECURITY=ldap`); if the file is missing the script prints how
   to create it by hand (architecture doc §5.1).
2. LDAP bind check as `cn=Admin` against `ldap://localhost:<admin port>`.
   If the bind fails (the domain still has the random password of the domain
   creation), the script sets the stored password via WLST
   (`/EmbeddedLDAP/<domain>` → `setCredential`, activate) and stops this
   section with a WARN: **restart the AdminServer, then re-run 13** – the
   embedded LDAP reads the credential only at start.
3. `createCred(map='reports.idstore', key='embeddedldap', user='cn=Admin', …)`
   (`updateCred` if it exists).
4. `jps-config-jse.xml` (backup): new `serviceInstance idstore.ldap.embedded`
   (`idstore.type=OPEN_LDAP`, search bases `ou=people|groups,ou=myrealm,dc=<domain>`
   as `extendedProperty`, bind via `security.principal.alias/key`), default
   context `idstore.xml` → `idstore.ldap.embedded`.
5. `rwserver.conf` (Step 5) with `securityId="rwJaznSec"`.

Result on the test host (2026-10-16):

| Test | Result |
|---|---|
| `getserverinfo` as `monUser` | `serverInfo` |
| as `RepRunner` / wrong password / no `authid` | `REP-56071` / `REP-50171` / HTTP 499 |
| report via `cmdkey=default` (`authid=RepRunner` in the key) | PDF |
| report without key and login | HTTP 499 |

Dependency: the embedded LDAP runs inside the AdminServer – while it is
down, the Reports server cannot authenticate anybody.

---

## Step 6 – Configure `reports.sh`

**Location:** `$DOMAIN_HOME/reports/bin/reports.sh`

This script sets environment variables used by the Reports Builder and Reports
Converter tools.  The font variables here apply to **command-line** tools;
for the Reports Server engines the same variables must be set in `rwserver.conf`
(see Step 5).

Add at the end of the file:

```bash
# ── IHateWeblogic Settings ──────────────────────────────────────────────────
export NLS_LANG=GERMAN_GERMANY.AL32UTF8

# Font configuration (must match rwserver.conf envVariable entries)
REPORTS_FONT_DIRECTORY=${DOMAIN_HOME}/reports/fonts; export REPORTS_FONT_DIRECTORY
REPORTS_ENHANCED_FONTHANDLING=YES; export REPORTS_ENHANCED_FONTHANDLING
REPORTS_JVM_OPTIONS="-Xmx256M -Djdk.lang.processReaperUseDefaultStackSize=true -DORBWaitForResponseTimeout=999999999 -Dcom.sun.corba.ee.transport.ORBTCPConnectTimeouts=250:5000:100:1000"; export REPORTS_JVM_OPTIONS
REPORTS_PATH=${REPORTS_PATH}:<REPORTS_PATH of environment.conf>; export REPORTS_PATH
# ────────────────────────────────────────────────────────────────────────────
```

`REPORTS_JVM_OPTIONS` here is the JVM of the **rwserver process itself**
(`librw.so` reads it; default `-Xmx256M`) – the `REPORTS_JVM_OPTIONS` in
`rwserver.conf` `<environment>` are for the engines. Tested 2026-10-16:

| Option | Why |
|---|---|
| `-Djdk.lang.processReaperUseDefaultStackSize=true` | the JDK "process reaper" thread died with `StackOverflowError` at every start; the first authentication then waited ~4 min in the Oracle diagnostics framework (`ADRHelper.getProcessExitValue`) |
| `-Dcom.sun.corba.ee.transport.ORBTCPConnectTimeouts=250:5000:100:1000` | after an engine crash the rwserver retried the dead engine 60 s (ORB default `250:60000:100:5000`) – now ~6 s |
| `-DORBWaitForResponseTimeout=999999999` | required as soon as `REPORTS_JVM_OPTIONS` is set (see troubleshooting REP-50125) |
| `-Xmx256M` | previous default |

Check: `jcmd <rwserver pid> VM.command_line`.

### Step 6b – `setUserOverrides.sh`: ORB connect timeout of WLS_REPORTS

The rwservlet keeps the CORBA reference of the Reports server; after a
restart of the Reports server (new random port) the ORB retried the dead
port 60 s. The script adds to the `WLS_REPORTS` block of
`$DOMAIN_HOME/bin/setUserOverrides.sh`:

```bash
export EXTRA_JAVA_PROPERTIES="${EXTRA_JAVA_PROPERTIES} -Dcom.sun.corba.ee.transport.ORBTCPConnectTimeouts=250:5000:100:1000"
```

First job after a full restart 1.8 s (before 242–305 s), after a restart of
the Reports server only 8 s (before 64 s), after an engine crash 7 s (before
63 s). Regular engine recycling (`engLife`) was never affected.

> `REPORTS_ENHANCED_FONTHANDLING=YES` is the default since Reports 12c; explicit
> setting is recommended for clarity.

---

## Step 7 – Font and Unicode Configuration

> **See also:** `04-ReportsFonts/uifont_ali_update.sh` and `04-ReportsFonts/font_cache_reset.sh`

**Relevant Oracle Support Notes:**
- *Doc ID 852698.1* – Using TTF Fonts for Font Metrics on Unix with Reports 11g/12c
- *Doc ID 2988373.1* – Troubleshoot Symbol/Greek Font in Reports 12c PDF Output
- *Doc ID 350971.1* – Font Aliasing / Subsetting / Embedding Issues Guide

**Symptom of font misconfiguration:** Greek or symbol characters appear in PDF
output instead of the expected text.

### 7.1 Install MS Core Fonts on Oracle Linux 9

```bash
# Install dependencies
dnf install -y curl fontconfig cabextract mkfontscale mkfontdir

# Install MS Core Fonts (Internet access required)
rpm -i https://downloads.sourceforge.net/project/mscorefonts2/rpms/msttcorefonts-installer-2.6-1.noarch.rpm --nodeps

# Rebuild font cache
fc-cache -v -r

# Verify
fc-list | grep -i arial
```

### 7.2 Copy Fonts to Domain Font Directory

```bash
# Stop all servers before copying
$DOMAIN_HOME/bin/stopComponent.sh repserver_ent
$DOMAIN_HOME/bin/stopComponent.sh reptools_ent
$DOMAIN_HOME/bin/stopManagedWebLogic.sh WLS_REPORTS
$DOMAIN_HOME/bin/stopWebLogic.sh

# Copy fonts
mkdir -p $DOMAIN_HOME/reports/fonts
cp /usr/share/fonts/msttcore/* $DOMAIN_HOME/reports/fonts/
```

### 7.3 Configure `uifont.ali`

**Location** (under the ReportsTools instance, **not** under `$ORACLE_HOME`):
```
$DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/<REPORTS_TOOLS_INSTANCE>/guicommon/tk/admin/uifont.ali
```

> Always create a backup before editing this file.

**Section `[ Global ]` – comment out Windows font mappings that have TTF equivalents:**

```
[ Global ]
# "Arial"      = helvetica    ← comment out; TTF mapping in [PDF:Subset] takes precedence
# "Courier New" = courier     ← comment out
"Times New Roman" = times
Modern           = helvetica
"MS Sans Serif"  = helvetica
"MS Serif"       = times
"Small Fonts"    = helvetica
"Lucida Console" = helvetica
```

**Section `[ PDF:Subset ]` – map fonts to TTF files (most specific style first):**

```
[ PDF:Subset ]
Arial..Italic.Bold.. = "arialbi.ttf"
Arial...Bold..       = "arialbd.ttf"
Arial..Italic...     = "ariali.ttf"
Arial.....           = "arial.ttf"
```

> **Style qualifier order:** `Italic.Bold` before `Bold` before `Italic` before plain.
> Right-hand side: always in double quotes, always with `.ttf` extension.
> See `04-ReportsFonts/uifont_ali_update.sh` for automated maintenance.

### 7.4 Verify `uifont.ali` Syntax

```bash
export LD_LIBRARY_PATH=$ORACLE_HOME/lib

mfontchk $DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/\
${REPORTS_TOOLS_INSTANCE}/guicommon/tk/admin

# Expected: "Schriftartaliasdatei erfolgreich geparst"
# ^ = file not found; ^ on left = syntax error
```

---

## Step 8 – Start and Stop System Components

### Start sequence (after all configuration is complete)

```bash
# 1. Start AdminServer (if not already running)
$DOMAIN_HOME/bin/startWebLogic.sh &

# 2. Start WLS_REPORTS managed server
$DOMAIN_HOME/bin/startManagedWebLogic.sh WLS_REPORTS t3://localhost:7001 &

# 3. Start ReportsTools component
$DOMAIN_HOME/bin/startComponent.sh reptools_ent

# 4. Start ReportsServer component
$DOMAIN_HOME/bin/startComponent.sh repserver_ent
```

### Stop sequence

```bash
$DOMAIN_HOME/bin/stopComponent.sh repserver_ent
$DOMAIN_HOME/bin/stopComponent.sh reptools_ent
$DOMAIN_HOME/bin/stopManagedWebLogic.sh WLS_REPORTS
$DOMAIN_HOME/bin/stopWebLogic.sh
```

---

## Known Harmless Errors

These errors appear in the log files and **cannot be avoided**.  They do not
indicate a functional problem.

| Error / Warning | Location | Cause | Reference |
|---|---|---|---|
| `Plugin not found for system component type 'ReportsToolsComponent', plugin type 'METRICS'` | startup log | Reports 14c is not integrated with OEM anymore | MOS Doc ID 2125317.1 |
| `SEVERE: JRF is unable to determine the current application server platform` | `repserver_ent.out` | Domain info cannot be passed to standalone system component | No workaround |
| `Unable to determine WLS domain name or temp location` | `repserver_ent.out` | Consequence of the JRF error above | Ignorable |

---

## Verification

### Check Reports Server is responding

```bash
# Queue status (replace host/port/authid as needed)
curl -s "http://localhost:7777/reports/rwservlet/showjobs?server=repserver_ent&authid=rep_admin/<identifier password>"

# Server info (no authentication required at webcommandaccess L1 for getserverinfo)
curl -s "http://localhost:7777/reports/rwservlet/getserverinfo?server=repserver_ent&statusformat=XML"
```

Expected: XML response with `<server>` element and engine status entries
(`status="1"` = IDLE, `status="2"` = BUSY, `status="0"` = DEAD).

### Engine crashes with REP-50125 NullPointerException (confirmed 2026-10-15)

`rwEng-0_diagnostic.log` shows every ~60 s:

```
REP-50125 : java.lang.NullPointerException
  at java.util.Properties.put(...)
  at oracle.reports.utility.Utility.getOrbProperties(Utility.java:2561)
  at oracle.reports.engine.RWEngine.init(RWEngine.java:253)
```

and `getserverinfo` answers `REP-50001 The server is initializing` forever.
`Utility.getOrbProperties` (Reports QPR 39600348) takes
`ORBWaitForResponseTimeout` from the environment variable
`REPORTS_JVM_OPTIONS` (`-DORBWaitForResponseTimeout=<ms>`). If the variable is
set **without** this option, the value is `null` and `Properties.put` throws.
If the variable is not set at all, the default `999999999` is used.
Fix: always add `-DORBWaitForResponseTimeout=999999999` to `REPORTS_JVM_OPTIONS`
in `rwserver.conf` (the script does this since 2026-10-15), then restart the
component (`stopComponent.sh` / `startComponent.sh <repserver>`).

### getserverinfo returns REP-52262 "Diagnostic output is disabled" (confirmed 2026-10-15)

Not a hidden error: `CommandManager.checkDiagnostic` blocks the web command.
With `<webcommandaccess>` `no`/`L0`/`L1` and a Reports server that is **not**
secured (no `securityId` on the `<job>` element), web commands such as
`getserverinfo`/`showjobs` require the **server administrator** from
`<identifier>` in `rwserver.conf` – not a WebLogic user and not `monUser`:

```bash
curl -s "http://localhost:9002/reports/rwservlet/getserverinfo?server=repserver01&statusformat=XML&authid=rep_admin/<identifier password>"
```

`authid=monUser/...` or `authid=webadmin/...` still return REP-52262.
The server encrypts `<identifier>` on its first start (`encrypted="yes"`).

### Reports server restarts in a loop: REP-50600 "Broadcasting is disabled" (customer 2026-10-15)

> Background (discovery modes, what the server does at start, observed
> traffic): [`80-FMW-Architecture/reports_server_discovery_multicast.md`](../../80-FMW-Architecture/reports_server_discovery_multicast.md)

`nodemanager.log` shows `The server 'repserver01' ... is no longer alive` /
`Server failed so attempting to restart` every few seconds,
`rwserver_diagnostic.log` shows `REP-50600 : Broadcasting is disabled. Please
enable cosnaming for Reports discovery`. In multicast mode
`RWServer.startServer` sends a discovery packet to `228.5.6.7:<port>` and then
requires that **any** multicast packet was received
(`ServerPacketHandler.packetsReceived()`, at least its own) – nothing received →
REP-50600. Not caused by other Reports servers on the same port (those would send
packets; a server with the **same name** on the same channel/port gives
`REP-56040` instead). Causes, in order:

1. firewalld blocks UDP `<REPORTS_BROADCAST_PORT>` →
   `firewall-cmd --permanent --add-port=<port>/udp && firewall-cmd --reload`
   (`01-root_os_baseline.sh --apply` does this; `13-` checks it)
2. IPv6 still active on the interface (JVMs bind via IPv6) → see
   `docs/00-root_set_os_parameter.md`, "IPv6 per interface"
3. no multicast route → `ip route get 228.5.6.7` must name the LAN interface

`13-oracle_setup_reports.sh` runs a **multicast pre-check** before it writes the
broadcast port (since 2026-10-15, via `02-Checks/reports_network_scan.sh
--no-scan --port <port>`; the same script without `--no-scan` also scans the
network for other Reports servers per port): route to `228.5.6.7` (not via `lo`),
`MULTICAST` flag on that interface, and a **self-test** that sends one UDP
datagram to `228.5.6.7:<port>` and must receive it again on this host (the
same thing the Reports server checks – FAIL = REP-50600 expected). The
self-test is skipped while a Reports server is already running on the host
(that server would receive the datagram and log a harmless
`REP-50125 StreamCorruptedException`; a running server proves reception
anyway). During a 10 s passive listen it reports foreign senders on the port –
only a hint: Reports servers send only while starting, so silence does not
prove the port is unused in the subnet.

`13-root_reports_fix.sh` checks for `/lib64/libnsl.so.3`; if it is missing it
points out that `libnsl2` is AppStream-only and whether AppStream is enabled.

Check with `tcpdump -ni <if> udp port <port>` while stopping/starting the component
(`stopComponent.sh` + `startComponent.sh` – `restartComponent.sh` is refused by
the Node Manager for Reports servers: "softRestart command is not supported on
ReportsServerComponent", confirmed 2026-10-15; a Reports server sends its
~7 discovery packets only at start, nothing while idle):
packets from foreign IPs = other environments use the same port (choose another
one, same value in all three `rwnetwork.conf`); own packets only = dropped
locally (firewall); none = route/interface.

### Check diagnostic log for startup errors

```bash
tail -100 $DOMAIN_HOME/servers/${REPORTS_SERVER_INSTANCES}/logs/${REPORTS_SERVER_INSTANCES}.out
grep -i "SEVERE\|error\|exception" \
  $DOMAIN_HOME/servers/${REPORTS_SERVER_INSTANCES}/logs/rwserver_diagnostic.log
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `libnsl.so.2: cannot open shared object file` | OL9, symlink missing | Step 1: `ln -s /lib64/libnsl.so.3 $ORACLE_HOME/lib/libnsl.so.2` |
| Reports Server not found by servlet | `rwservlet.properties <server>` wrong | Step 4: set `<server>repserver_ent</server>` |
| Reports run in-process despite standalone server | `<inprocess>no</inprocess>` missing | Step 4: set `inprocess=no` |
| `REP-50171 Authentication failed`, log `LoginException: A user with the specified name does not exist` | `securityId` set, but the JSE identity store is still XML | Step 5a (`REPORTS_SECURITY=ldap`) – or remove `securityId` |
| first request after a start takes minutes, `StackOverflowError … "process reaper"` in `repserver.out` | process reaper dies, diagnostics framework waits | Step 6: `REPORTS_JVM_OPTIONS` with `processReaperUseDefaultStackSize` |
| first request after a Reports server restart takes ~60 s | stale CORBA reference in the rwservlet, ORB connect timeout 60 s | Step 6b |
| Greek characters in PDF output | Font mapping incomplete | Step 7: configure `uifont.ali` `[PDF:Subset]` section |
| Broadcasting conflict with same-name server | Wrong port in `rwnetwork.conf` | Step 3: set unique port per environment |
| `rwserver.conf` XML parse error | Manual edit error | Check `rwserver_diagnostic.log`; restore backup |
| `startComponent.sh` hangs at NodeManager | NodeManager not running or SSL mismatch | Run `11-oracle_nodemanager.sh --apply` first |

---

## Related Scripts and Documents

| Item | Purpose |
|---|---|
| `09-Install/13-root_reports_fix.sh` | Root: `libnsl.so.2` symlink (OL9) |
| `09-Install/13-oracle_setup_reports.sh` | Create instances, configure all files |
| `09-Install/11-oracle_nodemanager.sh` | NodeManager plain mode (prerequisite) |
| `09-Install/12-oracle_reports_users.sh` | Create monitor/exec users in security realm |
| `04-ReportsFonts/uifont_ali_update.sh` | Automated `uifont.ali` maintenance |
| `01-Run/rwserver_status.sh` | Runtime status monitoring |
| `90-Source-MetaData/oracle_reports_config_ch6.md` | Source document (Chapter 6) |

**Oracle Support Notes referenced:**

| Doc ID | Title |
|---|---|
| 437228.1 | How to Create Two Reports Servers With the Same Name in the Same Subnet |
| 3069675.1 | Reports 14c on Linux 9.X: libnsl.so.2 not found |
| 2125317.1 | ReportsToolsComponent METRICS plugin warning |
| 852698.1 | Using TTF Fonts for Font Metrics on Unix with Reports 11g/12c |
| 2988373.1 | Troubleshoot Symbol/Greek Font in Reports 12c PDF Output |
| 350971.1 | Font Aliasing / Subsetting / Embedding Issues Guide |
| 2400542.1 | Standalone Report Server Restarted Continuously by Node Manager (JDK 8 only) |
