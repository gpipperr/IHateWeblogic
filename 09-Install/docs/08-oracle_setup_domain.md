# Step 4b – 08-oracle_setup_domain.sh

**Script:** `09-Install/08-oracle_setup_domain.sh`
**Runs as:** `oracle`
**Phase:** 4 – Repository & Domain

---

## Purpose

Create the WebLogic domain for Forms & Reports using WLST in silent mode.
Configures AdminServer, WLS_FORMS, and WLS_REPORTS managed servers.
All servers listen on `127.0.0.1` only — Nginx is the external entry point.

---

## Domain Templates Used

```
$ORACLE_HOME/wlserver/common/templates/wls/wls.jar
$ORACLE_HOME/oracle_common/common/templates/wls/oracle.jrf_template.jar
$ORACLE_HOME/forms/common/templates/wls/forms_template.jar
$ORACLE_HOME/reports/common/templates/wls/oracle.reports_app_template.jar
```

> **Note:** Template names verified via `ls $ORACLE_HOME/forms/common/templates/wls/`
> on FMW 14.1.2. The names differ from older 12.2.1.x installations.
> `forms_template.jar` creates the `WLS_FORMS` managed server automatically.
> `oracle.reports_app_template.jar` creates `WLS_REPORTS` automatically.

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

# Domain settings
cd('/')
set('Name', 'fr_domain')
setOption('ServerStartMode', 'prod')
setOption('OverwriteDomain', 'true')

# Admin Server listen address
cd('/Servers/AdminServer')
set('ListenAddress', '127.0.0.1')
set('ListenPort', 7001)

# JRF template (adds OPSS, MDS, JDBC data sources)
addTemplate('$ORACLE_HOME/oracle_common/common/templates/wls/oracle.jrf_template.jar')

# Forms template – creates WLS_FORMS managed server automatically
addTemplate('$ORACLE_HOME/forms/common/templates/wls/forms_template.jar')

# Reports template – creates WLS_REPORTS managed server automatically
addTemplate('$ORACLE_HOME/reports/common/templates/wls/oracle.reports_app_template.jar')

# Update managed server listen addresses (created by templates above)
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

### 4. Create additional WLS users

Start AdminServer, then via WLST:

```bash
$ORACLE_HOME/oracle_common/common/bin/wlst.sh << 'EOF'
connect('webadmin', 'WLS_PASSWORD', 't3://127.0.0.1:7001')
cd('/SecurityConfiguration/fr_domain/DefaultRealm/myrealm')

# MonUser – monitor role
cmo.createUser('MonUser', 'MonPassword123', 'Monitoring read-only user')
cd('RoleAssignments')
# Assign to Monitors role via WLST or console

# RepRunner – reports runner
cmo.createUser('RepRunner', 'RepPassword123', 'Reports job submission user')

disconnect()
EOF
```

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
- Configures `nodemanager.properties` (127.0.0.1 only, port from `WLS_NODEMANAGER_PORT`)
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
ls -la $DOMAIN_HOME/servers/WLS_FORMS/
ls -la $DOMAIN_HOME/servers/WLS_REPORTS/

# Start AdminServer and verify
$DOMAIN_HOME/bin/startWebLogic.sh &
# wait ~60s
curl -s http://127.0.0.1:7001/console/ | grep -i "weblogic"
```

---

## Notes

- Domain creation is not idempotent — if `DOMAIN_HOME` already exists, the script
  will abort unless `setOption('OverwriteDomain', 'true')` is set
- The WLST script file containing the password is created in a temp location and
  deleted immediately after WLST exits (trap EXIT)
- Node Manager must be started before managed servers can be started via WLST

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
