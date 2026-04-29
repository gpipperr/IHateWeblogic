# Step 13 – Reports Server Detail Configuration

**Scripts:** `09-Install/13-root_reports_fix.sh` · `09-Install/13-oracle_setup_reports.sh`
**Runs as:** `root` (fix step) then `oracle`
**Phase:** 7 – Reports Server Setup

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

Add to `environment.conf` (populated by `00-Setup/init_env.sh`):

```bash
# Reports system component instance names
REPORTS_TOOLS_INSTANCE="reptools_ent"       # Always exactly one per domain
REPORTS_SERVER_INSTANCES="repserver_ent"    # Space-separated; multiple allowed

# Reports runtime paths
REPORTS_PATH="/app/oracle/applications/source"   # Location of .rdf/.rep source files
REPORTS_TMP="/tmp/reports"                        # Temporary output directory

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
ln -s /lib64/libnsl.so.3.0.0 $ORACLE_HOME/lib/libnsl.so.2

# Verify
ls -la $ORACLE_HOME/lib/libnsl.so.2
```

> This symlink is only required on Oracle Linux 9 / RHEL 9.
> The target `libnsl.so.3.0.0` is present by default on OL9.

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

Locate the `<cluster>` element and change the `port` attribute:

```xml
<!-- Before -->
<cluster port="14021" .../>

<!-- After (14.1.2.0.0 production) -->
<cluster port="14027" .../>
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
    <envVariable name="REPORTS_PATH"        value="/app/oracle/applications/source"/>
    <envVariable name="REPORTS_TMP"         value="/tmp/reports"/>
    <envVariable name="NLS_LANG"            value="GERMAN_GERMANY.AL32UTF8"/>
    <envVariable name="TNS_ADMIN"           value="/app/oracle/19c/network/admin"/>
    <envVariable name="REPORTS_JVM_OPTIONS" value="-Djobid=random"/>
  </environment>

  <!-- Security: JAZN-based (WebLogic security realm) -->
  <security id="rwJaznSec" class="oracle.reports.server.RWJAZNSecurity"/>

  <!-- Destination plugins -->
  <destination destype="ftp"    class="oracle.reports.plugin.destination.ftp.DesFTP"/>
  <destination destype="WebDav" class="oracle.reports.plugin.destination.webdav.DesWebDAV"/>

  <!-- IMPORTANT: SecurityId attribute must NOT be present on the report job element -->
  <job jobType="report" engineId="rwEng" retry="3"/>
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
    <read>/app/oracle/applications/source</read>
    <write>/tmp/reports</write>
  </folderAccess>

  <!-- Internal Reports admin credentials (NOT the WebLogic admin user) -->
  <identifier encrypted="no">rep_admin/wls_team</identifier>

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
| `<job … SecurityId>` | **Remove** this attribute — causes startup errors with JAZN security |
| `<identifier>` | Internal Reports admin; keep separate from WebLogic admin |
| `<folderAccess><read>` | Reports Server will only read `.rdf` files from this path |
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
| `ReportsServer.Job → rwEngrwJaznSec` | Fix job | `Retry=3`, `SecurityId=(empty)` |
| `ReportsServer.Queue → Queue` | Set queue size | `MaxQueueSize=4000` |
| `ReportsServer.Connection → Connection` | Set connections | `maxConnect=300` |

After all MBean changes: **Lock & Edit → Save → Activate Changes → restart WLS_REPORTS**.

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
# ────────────────────────────────────────────────────────────────────────────
```

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
curl -s "http://localhost:7777/reports/rwservlet/showjobs?server=repserver_ent&authid=rep_admin/wls_team"

# Server info (no authentication required at webcommandaccess L1 for getserverinfo)
curl -s "http://localhost:7777/reports/rwservlet/getserverinfo?server=repserver_ent&statusformat=XML"
```

Expected: XML response with `<server>` element and engine status entries
(`status="1"` = IDLE, `status="2"` = BUSY, `status="0"` = DEAD).

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
| `libnsl.so.2: cannot open shared object file` | OL9, symlink missing | Step 1: `ln -s /lib64/libnsl.so.3.0.0 $ORACLE_HOME/lib/libnsl.so.2` |
| Reports Server not found by servlet | `rwservlet.properties <server>` wrong | Step 4: set `<server>repserver_ent</server>` |
| Reports run in-process despite standalone server | `<inprocess>no</inprocess>` missing | Step 4: set `inprocess=no` |
| Engine startup fails / loops | `SecurityId` attribute present in `<job>` | Step 5: remove `SecurityId` from `<job jobType="report">` |
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
