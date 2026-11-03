# Step 4b – 08-oracle_setup_domain.sh

**Script:** `09-Install/08-oracle_setup_domain.sh`
**Runs as:** `oracle`
**Phase:** 4 – Repository & Domain

```bash
./09-Install/08-oracle_setup_domain.sh            # dry-run: plan + repository check
./09-Install/08-oracle_setup_domain.sh --apply    # WLST createDomain
```

Checked against the script 2026-11-03. Before it: `07-oracle_setup_repository.sh
--apply` (RCU schemas + profile), `00-Setup/weblogic_sec.sh --apply` (admin
user / password).

---

## Purpose

Create the WebLogic domain for Forms & Reports using WLST in silent mode.
Configures AdminServer, WLS_FORMS, and WLS_REPORTS managed servers.

Background – domain, AdminServer, managed servers, clusters, system
components: [weblogic_middleware_architecture.md §3](../../80-FMW-Architecture/weblogic_middleware_architecture.md#3-the-building-blocks);
who starts whom (Node Manager, system components) – [§4](../../80-FMW-Architecture/weblogic_middleware_architecture.md#4-who-starts-whom--the-control-chain);
the data sources / OPSS store bound to the RCU schemas –
[rcu_middleware_architecture.md §3](../../80-FMW-Architecture/rcu_middleware_architecture.md#3-who-logs-in-where);
what runs in `WLS_FORMS` / `WLS_REPORTS` –
[forms_runtime_architecture.md](../../80-FMW-Architecture/forms_runtime_architecture.md),
[report_engine_architecture.md](../../80-FMW-Architecture/report_engine_architecture.md).
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

### 0. Check the repository

```bash
# DB reachable, RCU schemas present, schema password valid, account open
sqlplus -S -L /nolog <<EOF
CONNECT ${DB_SCHEMA_PREFIX}_OPSS/"<schema password>"@//${DB_HOST}:${DB_PORT}/${DB_SERVICE}
SELECT 'LOGIN_OK' FROM dual;
EOF
ls $DOMAIN_HOME/config/config.xml     # must NOT exist
```

ORA-01017 = schema missing (RCU not run for this prefix) or wrong password;
ORA-28000 / ORA-28001 = locked / expired (profile, `07- --profile`);
ORA-12514 = `DB_SERVICE` not registered at the listener.

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

# Data sources: URL, password and schema user for each one
# JDBC thin URL: //host:port/service_name  (// + / = PDB service, not SID)
def cfg_ds(ds, user):
    cd('/JDBCSystemResources/' + ds + '/JdbcResource/' + ds)
    cd('JDBCDriverParams/NO_NAME_0')
    set('URL', 'jdbc:oracle:thin:@//DB_HOST:DB_PORT/DB_SERVICE')
    set('PasswordEncrypted', 'DB_SCHEMA_PASSWORD')
    cd('Properties/NO_NAME_0/Property/user')
    set('Value', user)
    cd('/')

cfg_ds('LocalSvcTblDataSource',      'DEV_STB')
cfg_ds('opss-data-source',           'DEV_OPSS')
cfg_ds('opss-audit-DBDS',            'DEV_IAU_APPEND')
cfg_ds('opss-audit-viewDS',          'DEV_IAU_VIEWER')
cfg_ds('WLSSchemaDataSource',        'DEV_WLS')          # untargeted by design,
cfg_ds('WLSRuntimeSchemaDataSource', 'DEV_WLS_RUNTIME')  # URL still needed (see below)
# (no mds-owsm in Forms & Reports – no OWSM component)

# Write domain
writeDomain('DOMAIN_HOME')
closeTemplate()
```

The template additionally sets, before `writeDomain` (see *Notes*):
`WeblogicPluginEnabled` on the AdminServer, SSL listen port off + Coherence
on the listen address per managed server (`_ihw_loopback`), `time-taken` in
the access log of `WLS_FORMS` (`_ihw_accesslog`).

### 2. Run WLST to create domain

```bash
chmod 600 /tmp/domain_config.py      # contains the passwords
$ORACLE_HOME/oracle_common/common/bin/wlst.sh /tmp/domain_config.py
rm -f /tmp/domain_config.py
```

### 3. Configure Node Manager

```bash
cp -p $DOMAIN_HOME/nodemanager/nodemanager.properties{,.bak.$(date +%Y%m%d_%H%M%S)}
cat > $DOMAIN_HOME/nodemanager/nodemanager.properties <<EOF
ListenAddress=127.0.0.1
ListenPort=${WLS_NODEMANAGER_PORT:-5556}
SecureListener=false
LogLimit=0
PropertiesVersion=14.1.2
AuthenticationEnabled=true
NodeManagerHome=$DOMAIN_HOME/nodemanager
JavaHome=$JDK_HOME
LogFile=$DOMAIN_HOME/nodemanager/nodemanager.log
LogLevel=INFO
EOF
```

Only these keys – Node Manager adds the missing ones with their defaults at
the first start (`DomainsFile`, `StartScriptEnabled`, `CrashRecoveryEnabled`,
… – seen on the test host). Node Manager as a systemd service: phase 7c
(`30-configure_autostart.sh`); `installNodeMgrSvc` exists for Windows only.

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

- Reads all domain parameters from `environment.conf`; unknown options stop
  the script (exit 1)
- Decrypts WLS admin password from `weblogic_sec.conf.des3`
  (`load_weblogic_password` → `WL_USER`, `INTERNAL_WL_PWD`)
- Decrypts DB schema password from `db_sys_sec.conf.des3`
  (`load_secrets_file` → `DB_SCHEMA_PWD`)
- **Repository check** (dry-run too): DB port reachable, one login as
  `<prefix>_OPSS` with `DB_SCHEMA_PWD` (sqlplus of `ORACLE_HOME`) – FAIL with
  the ORA message and a hint (ORA-01017 / 28000 / 28001 / 12514). Without it
  WLST fails only after minutes in "OPSS Processing" and leaves a partial
  `DOMAIN_HOME`. An existing `config.xml`: WARN in the dry-run, FAIL with
  `--apply`; a non-empty `DOMAIN_HOME` without `config.xml` (partial domain):
  WARN, WLST overwrites it (`OverwriteDomain`)
- Substitutes `##PLACEHOLDER##` values in `response_files/domain_config.py.template`
  into a temp file (`/tmp/domain_cfg_PID.py`, mode 600); deleted via `trap EXIT`
- Runs `wlst.sh /tmp/domain_cfg_PID.py` to create the domain
- Selects the templates by `INSTALL_COMPONENTS` (see *Components*), checks that
  they exist, passes `##WITH_FORMS##` / `##WITH_REPORTS##` to the WLST script
- Configures `nodemanager.properties` (127.0.0.1 only, port from `WLS_NODEMANAGER_PORT`)
- **Embedded LDAP password** (`REPORTS_SECURITY=ldap`, since 2026-11-03):
  the template creates `/EmbeddedLDAP/base_domain` (not in the template
  tree – checked offline) and sets `CredentialEncrypted` from
  `embedded_ldap_sec.conf.des3` (interview). Without it the new domain gets a
  random one, `13-oracle_setup_reports.sh` has to set it online and every
  managed server started before the following AdminServer restart fails with
  `LDAPException: error result (49); Invalid credentials` (customer
  2026-11-03). Password file missing: WARN, the old way through `13-`
  applies. The verification checks `<embedded-ldap>` / `<credential-encrypted>`
  in `config.xml`. Not yet confirmed with a real `writeDomain` (the whole
  rendered template ran offline without `writeDomain`) – the next new domain
  shows it
- **Node Manager credentials = admin user** (since 2026-11-03): the template
  sets `NodeManagerUsername` / `NodeManagerPasswordEncrypted` under
  `/SecurityConfiguration/base_domain` before `writeDomain` (offline the node
  keeps the template name after `set('Name')`; checked offline). Without it a
  production domain gets random ones (default `????????`) and the first
  `nmConnect` with the admin user fails (`Access to domain 'fr_domain' for
  user 'webadmin' denied`, customer 2026-11-03) until `11-` sets them online.
  The verification compares `<node-manager-username>` in `config.xml` with the
  admin user (WARN with the first-start order otherwise). Not yet confirmed
  with a real `writeDomain` – the next new domain shows it
- Runs `07-Maintenance/domain_jdk_path.sh --apply`: versioned JDK directory →
  `JDK_HOME` symlink (step 3b)
- Writes `servers/AdminServer/security/boot.properties` so AdminServer can be
  started right away, without waiting for Phase 6 (`10-oracle_boot_properties.sh`
  re-writes the same file later with identical content — harmless double-write,
  not a bug)
- Verifies domain directory structure exists after creation, then what the
  template set (in the written domain): no data source left at
  `dbhost.example.com` (FAIL), Coherence unicast on loopback for every managed
  server, `time-taken` in the `WLS_FORMS` access log (WARN with the fix
  command)
- WLST output `Error: cd() failed` / `Error: runCmd() failed`: the template
  helpers try `cd()` first and create the MBean in the `except` branch – WLST
  still prints the error. Expected on a fresh domain: one pair per
  `CoherenceMemberConfig` (each managed server, FORMS_AND_REPORTS: 2; until
  2026-11-03 one more for the access-log helper); the script reports the
  count as INFO
- Appends `time-taken` to the `<elf-fields>` of the `WLS_FORMS` access log
  directly in `config.xml` (backup `config.xml.bak_*`, domain not started
  yet) – see *Access log of WLS_FORMS with `time-taken`*
- `07-Maintenance/domain_jdk_path.sh` result by its exit code (until
  2026-11-03 a `grep FAIL` also hit its summary line `FAIL: 0` and always
  printed "reported errors" – false alarm)

---

## Response File Template

Located at: `09-Install/response_files/domain_config.py.template`

---

## Flags

| Flag | Description |
|---|---|
| (none) | Show planned domain configuration + repository check (read-only login) |
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
(`60-RCU-DB-19c/05-db_fmw_tablespace.sh --apply`, the drop removes it) →
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
  own pre-check (`08-oracle_setup_domain.sh`, before WLST is even invoked): `--apply`
  aborts if `$DOMAIN_HOME/config/config.xml` already exists. Running the "Without the
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
branch that creates a missing `CoherenceMemberConfig` – harmless (count and
result are checked by the script, see *What the Script Does*).

Live 2026-10-23 (existing domain, WLST online + restart): 9501 / 9512 gone,
Forms, EM, rwservlet and the smoke test unchanged; Coherence members talk
over `127.0.0.1`, the cluster port 7574 and one more port still listen on the
host IP (not removable, firewall) – details and the whole clone picture:
[clone_golden_image.md](../../80-FMW-Architecture/clone_golden_image.md).
Not configured on purpose: an own Coherence WKA list (licence note there).

### AdminServer: `weblogic-plugin-enabled` (since 2026-10-26)

The Forms / Reports templates set `weblogic-plugin-enabled=true` only on
`WLS_FORMS` / `WLS_REPORTS`. The template now sets it on the AdminServer too:
behind Nginx WebLogic then builds redirects from `Host` + `WL-Proxy-SSL: true`
– `/console` and `/em` redirect to `https://<FQDN>/…` directly instead of
`http://` and the port-80 hop. Safe because Nginx strips every client-supplied
`WL-Proxy-*` header (`nginx-wls.conf.template`, 2026-10-26). Not dynamic –
existing domains (live 2026-10-26 on the test host):

```python
connect('<admin user>', '<password>', 't3://127.0.0.1:7001')
edit(); startEdit()
cd('/Servers/AdminServer')
set('WeblogicPluginEnabled', 'true')
save(); activate(block='true')     # isRestartRequired() = True
disconnect()
```
then restart the AdminServer only: `01-Run/startStop.sh stop AdminServer --apply`
and `start AdminServer --apply` (managed servers keep running).

### Access log of WLS_FORMS with `time-taken`

`time-taken` in the extended access log of `WLS_FORMS` gives the response
times for `06-FormsDiag/forms_perf_analyse.sh` (frmservlet and the
`lservlet` round trips of running sessions) – what the value measures and
what not: [forms_runtime_architecture.md §6.1](../../80-FMW-Architecture/forms_runtime_architecture.md#61-accesslog-and-time-taken).

It **cannot be set in the WLST template**: `writeDomain` (JRF processing)
rewrites the `web-server-log` of every server afterwards – all three get
`date time cs-method ctx-ecid ctx-rid cs-uri sc-status bytes`, a value set
before `writeDomain` is gone (first new domain with the template helper at a
customer, 2026-11-03; the helper worked before `writeDomain`, checked offline).
The helper `_ihw_accesslog` was removed from the template; `08-` now appends
` time-taken` to that list in `config.xml` after `writeDomain`, before the
first start (backup first, only the `WLS_FORMS` block, idempotent).

By hand on a fresh, not yet started domain:

```bash
cp -p $DOMAIN_HOME/config/config.xml{,.bak_$(date +%Y%m%d_%H%M%S)}
grep -n "<elf-fields>" $DOMAIN_HOME/config/config.xml     # line of the WLS_FORMS block
sed -i '<line>s#</elf-fields># time-taken</elf-fields>#' $DOMAIN_HOME/config/config.xml
```

Running domain: `06-FormsDiag/forms_perf_settings.sh --apply --fix-accesslog`
(WLST online, tested 2026-10-23).

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
