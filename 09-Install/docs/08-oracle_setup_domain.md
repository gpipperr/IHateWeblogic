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
$ORACLE_HOME/forms/common/templates/wls/oracle.forms.templates.jar
$ORACLE_HOME/reports/common/templates/wls/oracle.reports.templates.jar
```

---

## Without the Script (manual)

### 1. Create WLST domain config script

Create `$PATCH_STORAGE/domain_config.py` from template
(see `response_files/domain_config.py.template`):

```python
# Read base domain template
readTemplate('$ORACLE_HOME/wlserver/common/templates/wls/wls.jar')

# Domain name
set('Name', 'fr_domain')

# Admin server credentials
cd('/Security/fr_domain/User/weblogic')
cmo.setPassword('WLS_ADMIN_PASSWORD')

# Production mode
setOption('ServerStartMode', 'prod')
setOption('OverwriteDomain', 'true')

# Apply JRF template
addTemplate('$ORACLE_HOME/oracle_common/common/templates/wls/oracle.jrf_template.jar')

# Apply Forms template (if INSTALL_COMPONENTS includes Forms)
addTemplate('$ORACLE_HOME/forms/common/templates/wls/oracle.forms.templates.jar')

# Apply Reports template (if INSTALL_COMPONENTS includes Reports)
addTemplate('$ORACLE_HOME/reports/common/templates/wls/oracle.reports.templates.jar')

# Configure Admin Server (listen on localhost only)
cd('/Servers/AdminServer')
set('ListenAddress', '127.0.0.1')
set('ListenPort', 7001)

# Configure WLS_FORMS managed server
create('WLS_FORMS', 'Server')
cd('/Servers/WLS_FORMS')
set('ListenAddress', '127.0.0.1')
set('ListenPort', 9001)

# Configure WLS_REPORTS managed server
create('WLS_REPORTS', 'Server')
cd('/Servers/WLS_REPORTS')
set('ListenAddress', '127.0.0.1')
set('ListenPort', 9002)

# Database (JDBC data source for FMW schemas)
cd('/JDBCSystemResources/LocalSvcTblDataSource/JdbcResource/LocalSvcTblDataSource')
cd('JDBCDriverParams/NO_NAME_0')
set('URL', 'jdbc:oracle:thin:@DB_HOST:DB_PORT/DB_SERVICE')
set('PasswordEncrypted', 'DB_SCHEMA_PASSWORD')
cd('Properties/NO_NAME_0/Property/user')
set('Value', 'DB_SCHEMA_PREFIX_STB')

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
- Generates `domain_config.py` from `response_files/domain_config.py.template`
- Decrypts WLS admin password and injects into the WLST script (never writes to disk)
- Runs `wlst.sh domain_config.py` to create the domain
- Configures `nodemanager.properties` (localhost only, port 5556)
- Starts AdminServer briefly to create `MonUser` and `RepRunner` via WLST
- Verifies domain directory exists with expected structure after creation

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
  deleted immediately after WLST exits
- Node Manager must be started before managed servers can be started via WLST
