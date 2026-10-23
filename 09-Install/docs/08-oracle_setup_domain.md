# Step 4b – 08-oracle_setup_domain.sh

**Script:** `09-Install/08-oracle_setup_domain.sh`
**Runs as:** `oracle`
**Phase:** 4 – Repository & Domain

---

## Purpose

Create the WebLogic domain for Forms & Reports using WLST in silent mode.
Configures AdminServer, WLS_FORMS, and WLS_REPORTS managed servers.

Background – domain, AdminServer, managed servers, clusters, system
components: [weblogic_middleware_architecture.md §3](../../80-FMW-Architecture/weblogic_middleware_architecture.md#3-the-building-blocks).
All servers listen on `127.0.0.1` only — Nginx is the external entry point.

### Components (`INSTALL_COMPONENTS`)

The domain gets only the managed servers of the installed products
(since 2026-10-15 – before, a Reports-only domain still got `WLS_FORMS` and
the `forms1` instance):

| `INSTALL_COMPONENTS` | Templates | Servers / system components |
|---|---|---|
| `FORMS_AND_REPORTS` (default) | wls, jrf, forms, reports_app, reports_server | AdminServer, WLS_FORMS, WLS_REPORTS, forms1 |
| `REPORTS_ONLY` | wls, jrf, reports_app, reports_server | AdminServer, WLS_REPORTS |
| `FORMS_ONLY` | wls, jrf, forms | AdminServer, WLS_FORMS, forms1 |

Template check and WLST script follow the same selection
(`##WITH_FORMS##` / `##WITH_REPORTS##` in the template). Verified offline with
WLST (templates added, server list read, no `writeDomain`). With
`REPORTS_ONLY`, `14-oracle_setup_forms.sh` skips itself.

---

## Domain Templates Used

```
$ORACLE_HOME/wlserver/common/templates/wls/wls.jar
$ORACLE_HOME/oracle_common/common/templates/wls/oracle.jrf_template.jar
$ORACLE_HOME/forms/common/templates/wls/forms_template.jar
$ORACLE_HOME/reports/common/templates/wls/oracle.reports_app_template.jar
$ORACLE_HOME/ReportsServerComponent/common/templates/wls/oracle.reports_server_template.jar
```

> **Note:** Template names verified via `ls $ORACLE_HOME/forms/common/templates/wls/`
> on FMW 14.1.2. The names differ from older 12.2.1.x installations.
> `forms_template.jar` creates the `WLS_FORMS` managed server automatically.
> `oracle.reports_app_template.jar` creates `WLS_REPORTS` automatically.
> It only pulls in "Oracle Reports Tools" as a dependency – **not** "Oracle
> Reports Server". `oracle.reports_server_template.jar` must be added explicitly,
> otherwise `createReportsServerInstance` in `13-` fails with
> `ReportsServerComponentManager not found` (confirmed 2026-10-15, added to `08-`
> the same day).

Reports-only (manual / Config Wizard): leave out `forms_template.jar`
("Oracle Forms") – then there is no `WLS_FORMS`. The Reports templates do not
depend on it.

---

## Without the Script (manual)

### 1. Create WLST domain config script

Create from template `09-Install/response_files/domain_config.py.template`
(the script substitutes all `##PLACEHOLDER##` values at runtime into a temp file):

```python
# Read base WebLogic template
readTemplate('$ORACLE_HOME/wlserver/common/templates/wls/wls.jar')

# Admin credentials – set BEFORE renaming domain (path uses 'base_domain')
cd('/Security/base_domain/User/weblogic')
cmo.setName('webadmin')           # rename from default 'weblogic'
cmo.setPassword('WLS_ADMIN_PASSWORD')

# Domain name
cd('/')
set('Name', 'fr_domain')

# Add templates BEFORE setOption() calls
# (ServerStartMode is not valid during addTemplate – causes WLSTException)
addTemplate('$ORACLE_HOME/oracle_common/common/templates/wls/oracle.jrf_template.jar')
addTemplate('$ORACLE_HOME/forms/common/templates/wls/forms_template.jar')        # not for Reports-only
addTemplate('$ORACLE_HOME/reports/common/templates/wls/oracle.reports_app_template.jar')            # not for Forms-only
addTemplate('$ORACLE_HOME/ReportsServerComponent/common/templates/wls/oracle.reports_server_template.jar')  # not for Forms-only

# Domain options – set AFTER all addTemplate calls
setOption('ServerStartMode', 'prod')
setOption('OverwriteDomain', 'true')

# Admin Server listen address
cd('/Servers/AdminServer')
set('ListenAddress', '127.0.0.1')
set('ListenPort', 7001)

# Update managed server listen addresses (created by templates above;
# only the servers of the added templates exist)
cd('/Servers/WLS_FORMS')
set('ListenAddress', '127.0.0.1')
set('ListenPort', 9001)

cd('/Servers/WLS_REPORTS')
set('ListenAddress', '127.0.0.1')
set('ListenPort', 9002)

# Configure LocalSvcTblDataSource (FMW Service Table = STB schema)
# JDBC thin URL: //host:port/service_name  (// + / = PDB service, not SID)
cd('/JDBCSystemResources/LocalSvcTblDataSource/JdbcResource/LocalSvcTblDataSource')
cd('JDBCDriverParams/NO_NAME_0')
set('URL', 'jdbc:oracle:thin:@//DB_HOST:DB_PORT/DB_SERVICE')
set('PasswordEncrypted', 'DB_SCHEMA_PASSWORD')
cd('Properties/NO_NAME_0/Property/user')
set('Value', 'DEV_STB')

# Write domain
writeDomain('DOMAIN_HOME')
closeTemplate()
```

### 2. Run WLST to create domain

```bash
$ORACLE_HOME/oracle_common/common/bin/wlst.sh $PATCH_STORAGE/domain_config.py
```

### 3. Configure Node Manager

```bash
$DOMAIN_HOME/bin/installNodeMgrSvc.sh   # create Node Manager as a service (optional)

# Or configure nodemanager.properties manually:
cat > $DOMAIN_HOME/nodemanager/nodemanager.properties << 'EOF'
ListenAddress=127.0.0.1
ListenPort=5556
SecureListener=false
LogLimit=0
PropertiesVersion=12.2.1
AuthenticationEnabled=true
NodeManagerHome=$DOMAIN_HOME/nodemanager
JavaHome=$JDK_HOME
LogFile=$DOMAIN_HOME/nodemanager/nodemanager.log
EOF
```

### 3b. JDK path: symlink instead of the versioned directory

`writeDomain` (and every later `updateDomain` / Config Wizard run) resolves
`JDK_HOME` (`/u01/app/oracle/java/jdk-21` → `jdk-21.0.12.1`) and writes the
**versioned** directory into `bin/setDomainEnv.sh`, `bin/setNMJavaHome.sh`,
`nodemanager/nodemanager.properties`, the Forms instance scripts
(`config/fmwconfig/components/FORMS/instances/*/bin/*.sh`) and `init-info/*`
(the templates `updateDomain` regenerates the scripts from). The FMW installer
does the same in `$ORACLE_HOME/oui/.globalEnv.properties` (JAVA_HOME of
`wlst.sh`, OPatch) and `oui/bin/*.sh`. A JDK upgrade that only switches the
symlink (`02b-root_os_java.sh --upgrade-jdk`) would then not reach the domain
(found 2026-10-15).

```bash
# show
grep -rlE "java/jdk-21\.[0-9]" $DOMAIN_HOME --exclude-dir=servers --exclude=*.log
# fix (backup first), then restart NM + servers
07-Maintenance/domain_jdk_path.sh            # read-only list
07-Maintenance/domain_jdk_path.sh --apply
```

Live-tested 2026-10-15: 22 files, after the restart NM, AdminServer,
WLS_FORMS and WLS_REPORTS run with `/u01/app/oracle/java/jdk-21/bin/java`.

### 4. Create additional WLS users

Start AdminServer, then create the Reports monitoring and execution users with
their Application Roles and Policies (`monUser` → `RW_MONITOR`,
`RepRunner` → `RW_EXECREPORTS`). This is a separate, dedicated step —
see [09-Install/12-oracle_reports_users.sh](../12-oracle_reports_users.sh) and
[docs/12-weblogic-report-monitoring_user.md](12-weblogic-report-monitoring_user.md)
for the full WLST/OPSS procedure (manual and scripted).

---

## What the Script Does

- Reads all domain parameters from `environment.conf`
- Decrypts WLS admin password from `weblogic_sec.conf.des3`
  (`load_weblogic_password` → `WL_USER`, `INTERNAL_WL_PWD`)
- Decrypts DB schema password from `db_sys_sec.conf.des3`
  (`load_secrets_file` → `DB_SCHEMA_PWD`)
- Substitutes `##PLACEHOLDER##` values in `response_files/domain_config.py.template`
  into a temp file (`/tmp/domain_cfg_PID.py`, mode 600); deleted via `trap EXIT`
- Runs `wlst.sh /tmp/domain_cfg_PID.py` to create the domain
- Selects the templates by `INSTALL_COMPONENTS` (see *Components*), checks that
  they exist, passes `##WITH_FORMS##` / `##WITH_REPORTS##` to the WLST script
- Configures `nodemanager.properties` (127.0.0.1 only, port from `WLS_NODEMANAGER_PORT`)
- Runs `07-Maintenance/domain_jdk_path.sh --apply`: versioned JDK directory →
  `JDK_HOME` symlink (step 3b)
- Writes `servers/AdminServer/security/boot.properties` so AdminServer can be
  started right away, without waiting for Phase 6 (`10-oracle_boot_properties.sh`
  re-writes the same file later with identical content — harmless double-write,
  not a bug)
- Verifies domain directory structure exists after creation

---

## Response File Template

Located at: `09-Install/response_files/domain_config.py.template`

---

## Flags

| Flag | Description |
|---|---|
| (none) | Show planned domain configuration |
| `--apply` | Create domain |
| `--help` | Show usage |

---

## Verification

```bash
# Domain directory exists
ls -la $DOMAIN_HOME/config/config.xml
ls -la $DOMAIN_HOME/servers/AdminServer/
ls -la $DOMAIN_HOME/servers/WLS_FORMS/      # not with REPORTS_ONLY
ls -la $DOMAIN_HOME/servers/WLS_REPORTS/    # not with FORMS_ONLY

# Domain uses the JDK_HOME symlink, not jdk-21.0.x
07-Maintenance/domain_jdk_path.sh

# All data sources point to the RCU database (none left at dbhost.example.com)
grep -h "<url>" $DOMAIN_HOME/config/jdbc/*.xml | sort | uniq -c
```

**Re-creating the domain needs fresh RCU schemas.** `writeDomain` binds the OPSS
security store in `<prefix>_OPSS` to the new domain. Deleting `DOMAIN_HOME` and
running `08` again fails with (confirmed 2026-10-15):

```
64254: Error occurred in "OPSS Processing" phase execution
LifecycleException: The schema DEV_OPSS is already in use for security store(s).
Please create a new schema..
```

Order: remove the (partial) `DOMAIN_HOME` → `07-oracle_setup_repository.sh --drop`
→ re-create the tablespace if `RCU_TABLESPACE` is set
(`60-RCU-DB-19c/07-db_fmw_tablespace.sh --apply`, the drop removes it) →
`07-oracle_setup_repository.sh --apply` → `08-oracle_setup_domain.sh --apply`.
The script prints this sequence when it detects the error.

The domain is not started here: next step is `09-oracle_configure.sh`
(WLS 14.1.2 has no Administration Console under `/console` any more).

> `WLSSchemaDataSource` / `WLSRuntimeSchemaDataSource` (`<prefix>_WLS`,
> `<prefix>_WLS_RUNTIME`) come from `wls_schema.jar` and are **untargeted by
> design** (`default-targeting="false"`). The WLST template still sets their URL
> and user – otherwise they keep the placeholder `dbhost.example.com:1521/orcl`.

---

## Notes

- Domain creation is not idempotent. The WLST template hardcodes
  `setOption('OverwriteDomain', 'true')` — WLST itself would silently overwrite an
  existing domain, no questions asked. The actual protection is the shell script's
  own pre-check (`08-oracle_setup_domain.sh`, before WLST is even invoked): it aborts
  if `$DOMAIN_HOME/config/config.xml` already exists. Running the "Without the
  Script" WLST steps below directly does **not** have this protection — check for
  an existing domain manually first.
- The WLST script file containing the password is created in a temp location and
  deleted immediately after WLST exits (trap EXIT)
- Node Manager must be started before managed servers can be started via WLST

### Loopback only: SSL listen ports off, Coherence on the listen address

Found 2026-10-19 (`02-Checks/ssl_check.sh`, test host): the Forms / Reports
domain templates leave an **SSL listen port enabled** on the managed
servers – `WLS_FORMS` 9501, `WLS_REPORTS` 9512 – with the **WebLogic demo
certificate** (`DemoIdentity.p12`, issuer `CertGenCA`, "FOR TESTING ONLY";
the private key of that CA ships with every WebLogic installation). TLS ends
at Nginx, the ports are not needed. And Coherence (`defaultCoherenceCluster`
of `cluster_forms` / `cluster_reports`) talked over the **routable host IP** –
a clone of the machine in the same subnet could join the cluster.

The WLST template therefore sets, per managed server and before
`writeDomain` (helper `_ihw_loopback` in `domain_config.py.template`):

```python
cd('/Servers/WLS_FORMS/SSL/WLS_FORMS')
set('Enabled', 'false')
cd('/Servers/WLS_FORMS/CoherenceMemberConfig/WLS_FORMS')   # created if missing
set('UnicastListenAddress', '<WLS_LISTEN_ADDRESS>')         # 127.0.0.1
```

`Enabled=false` is the default value – `config.xml` then has no
`<enabled>` element under `<ssl>` (tested offline on a domain copy
2026-10-23). The `cd()` errors in the WLST output come from the `try`
branch that creates a missing `CoherenceMemberConfig` – harmless.

Live 2026-10-23 (existing domain, WLST online + restart): 9501 / 9512 gone,
Forms, EM, rwservlet and the smoke test unchanged; Coherence members talk
over `127.0.0.1`, the cluster port 7574 and one more port still listen on the
host IP (not removable, firewall) – details and the whole clone picture:
[clone_golden_image.md](../../80-FMW-Architecture/clone_golden_image.md).
Not configured on purpose: an own Coherence WKA list (licence note there).

### Access log of WLS_FORMS with `time-taken`

The template also adds `time-taken` to the extended access log of
`WLS_FORMS` (helper `_ihw_accesslog`: `LogFileFormat=extended`, the existing
`ELFFields` + `time-taken`) – response times for
`06-FormsDiag/forms_perf_analyse.sh` (frmservlet and the `lservlet` round
trips of running sessions). Tested offline on a domain copy and online
2026-10-23; existing domains: `06-FormsDiag/forms_perf_settings.sh --apply
--fix-accesslog`.

**Existing domains (SSL / Coherence):** `02-Checks/clone_check.sh --apply` (WLST online,
backup of `config.xml`), then stop both managed servers and start them
again. `02-Checks/ssl_check.sh` shows "SSL deaktiviert".

### WebLogic Admin Password Requirements

WebLogic enforces a password policy during domain creation (error 60455):

- **Minimum 8 characters**
- **At least one number or special character**

Example valid passwords: `Welcome1`, `Admin#2024`, `Muster01!`

Set via `00-Setup/weblogic_sec.sh --apply` before running this script.

### Non-ASCII Characters in Passwords

WLST runs on Jython 2, which requires an explicit encoding declaration when the
Python script file contains non-ASCII bytes (e.g. passwords with Umlauts: ä ö ü ß).

The template already contains `# -*- coding: utf-8 -*-` as line 1.
If the password contains characters outside UTF-8 (rare), change the declaration
to `# -*- coding: latin-1 -*-` in `response_files/domain_config.py.template`.
