# Reports users – who authenticates whom: standalone Reports server, OPSS JSE, WebLogic embedded LDAP

**Scope:** FMW 14.1.2.0.0 (CSPU Sep 2026, Reports QPR 39600348), Forms/Reports
domain with JRF, rwservlet on `WLS_REPORTS`, **standalone** Reports server
(`ReportsServerComponent`, process `rwserver`, started by the Node Manager).
Goal: Reports users and roles (`monUser` → `RW_MONITOR`, `RepRunner` →
`RW_EXECREPORTS`) from the WebLogic security realm also for the standalone
Reports server – as with an in-process Reports server.

Markers as in [README.md](README.md): **confirmed (code)**, **confirmed
(live)**, **documented**, **assumption**. Findings of the test run are in §7.

Related: [em_principal_search_libovd.md](em_principal_search_libovd.md)
(same split JSE ↔ WebLogic, libOVD), `09-Install/docs/81-reports_rwservlet_security.md`
(web commands, `<identifier>`, `webcommandaccess`).

---

## 1. The parts

| Part | Process | Security configuration |
|---|---|---|
| AdminServer | WebLogic JVM | realm `myrealm`, `DefaultAuthenticator` → **embedded LDAP** (inside the AdminServer, port 7001); OPSS `config/fmwconfig/jps-config.xml` |
| WLS_REPORTS + rwservlet | WebLogic JVM | `jps-config.xml` (WebLogic platform), `rwservlet.properties` (`singlesignon`, `webcommandaccess`, `inprocess`) |
| in-process Reports server (alternative) | inside WLS_REPORTS | `…/WLS_REPORTS/applications/reports_14.1.2/configuration/rwserver.conf` – Oracle default has `securityId="rwJaznSec"` on the report job |
| **standalone Reports server** `repserver01` | own process `rwserver` (Java SE, started by the NM) | **`config/fmwconfig/jps-config-jse.xml`** + `components/ReportsServerComponent/<name>/rwserver.conf` |
| OPSS schema `<prefix>_OPSS` (DB) | – | policy store (application roles, policies of stripe `reports`), credential store, keystore, audit – **shared** by both `jps-config*.xml` |

`jps-config-jse.xml`, default context on the test host (**confirmed (live)**):

```
credstore.db  keystore.db  policystore.db  audit.db  trust  pdp.service  attribute
idstore.xml   idstore.loginmodule
```

All stores except the **identity store** are the shared DB stores. The
identity store is the file `system-jazn-data.xml` (JAZN XML).

## 2. Who talks to whom – today (identity store XML)

```
 Browser / Monitoring / Application
        |  HTTPS  /reports/rwservlet/getserverinfo?authid=monUser/...
        v
 +------------------+
 | nginx (TLS)      |
 +--------+---------+
          | HTTP 127.0.0.1:9002
          v
 +-------------------------------+        +------------------------------+
 | WLS_REPORTS  (WebLogic JVM)   |        | AdminServer (WebLogic JVM)   |
 |  rwservlet                    |        |  realm myrealm               |
 |  rwservlet.properties         |        |   DefaultAuthenticator       |
 |   singlesignon / webcmdaccess |        |    -> embedded LDAP :7001    |
 +---------------+---------------+        |       ou=people,ou=myrealm,  |
                 | request + authid       |       dc=<domain>            |
                 | (multicast discovery,  |  EM (Add Principal, roles)   |
                 |  ORB/IIOP)             +--------------+---------------+
                 v                                       |
 +-------------------------------+                       | OPSS jps-config.xml
 | repserver01  rwserver (Java SE)|                      | idstore.ldap -> realm
 |  rwserver.conf                 |                      | policystore.db
 |   <security rwJaznSec>         |                      v
 |   <job ... securityId=?>       |        +------------------------------+
 |   <identifier> (server admin)  |        | DB schema <prefix>_OPSS      |
 |  OPSS jps-config-jse.xml       |------->|  policy store (RW_* roles,   |
 |   policystore.db  credstore.db |  JDBC  |  ReportsPermission,          |
 |   idstore.xml ----+            |        |  WebCommandPermission)       |
 +-------------------|------------+        |  credential store            |
                     v                     +------------------------------+
        system-jazn-data.xml  (file, users unknown to WebLogic)
```

Decision points in the Reports server (**confirmed (code)**,
`oracle.reports.rwclient.CommandManager.checkDiagnostic`, doc 81):

| Situation | web commands (`getserverinfo`, `showjobs`) | report jobs |
|---|---|---|
| no `securityId` on `<job>` ("server not secure") | only the server administrator `<identifier>`; everybody else `REP-52262` | **no** user check – only DB `userid` and `<folderAccess>` (confirmed (live): call without any login reaches the server) |
| `securityId="rwJaznSec"` on `<job>` | user authenticated against the **JSE identity store** + authorised via policy store | user authenticated against the **JSE identity store** + `ReportsPermission` |

With `securityId` and the XML identity store, every WebLogic user fails
(**confirmed (live)** 2026-10-16): `REP-50171 Authentication failed`, log
`REP-50125 … LoginException: A user with the specified name does not exist`.

## 3. Target – identity store of the JSE context = WebLogic embedded LDAP

```
 repserver01 rwserver (Java SE)
   rwserver.conf  <job jobType="report" ... securityId="rwJaznSec"/>
   OPSS jps-config-jse.xml
     policystore.db / credstore.db  ------------------------> DB <prefix>_OPSS
     idstore.<new> (idstore.ldap.provider)
        ldap.url = ldap://localhost:7001
        bind     = cn=Admin  (password from credential store:
                               security.principal.alias / .key)
        users    = ou=people,ou=myrealm,dc=<domain>
        groups   = ou=groups,ou=myrealm,dc=<domain>
          |
          | LDAP (plain, localhost only)
          v
 AdminServer  embedded LDAP  (same data as realm myrealm / DefaultAuthenticator)
```

Then the same users and roles work for the standalone server as for an
in-process server: `monUser` (`RW_MONITOR`, `WebCommandPermission`) for
`getserverinfo`, `RepRunner` (`RW_EXECREPORTS`, `ReportsPermission`) via
`cgicmd.dat … %* authid=RepRunner/…`.

Consequences to keep in mind:

- The embedded LDAP lives in the **AdminServer** – while it is down the
  Reports server cannot authenticate anybody.
- The embedded LDAP is plain LDAP on the admin port; it must only be reached
  via localhost (listen address `localhost`, firewall closed).
- **Assumption:** the Reports server then pushes an LDAP identity store into
  libOVD instead of the XML one – this may also cure the empty EM user search
  ([em_principal_search_libovd.md](em_principal_search_libovd.md)). To verify.

## 4. Configuration elements

| Element | Where | Value / note |
|---|---|---|
| password of `cn=Admin` (embedded LDAP) | domain `EmbeddedLDAP` MBean, attribute `Credential` | random at domain creation – set a known one (WLST, AdminServer restart) |
| credential for the bind | OPSS credential store (`credstore.db`, shared) | WLST `createCred(map=…, key=…, user='cn=Admin', password=…)` – the command is `createCred` (`opss-wlst-commands.jar`), not `createCredential` |
| identity store instance | `jps-config-jse.xml` `<serviceInstances>` | provider `idstore.ldap.provider` (already defined in the file); properties `idstore.type`, `ldap.url`, `security.principal.alias`, `security.principal.key`, `username.attr`, `groupname.attr`, `extendedProperty user.search.bases / group.search.bases` |
| `idstore.type` | same | valid values (**confirmed (code)**, `IdentityStoreType`): `XML OID ACTIVE_DIRECTORY IPLANET EDIRECTORY OPEN_LDAP COREID OVD OUD WLS_OVD CUSTOM LIBOVD SCIM` – there is **no** `WLS` |
| default context | `jps-config-jse.xml` `<jpsContext name="default">` | **replace** `idstore.xml` by the new instance (one identity store per context) |
| `securityId` | `rwserver.conf` of the standalone server, `<job jobType="report">` | `rwJaznSec` |
| start / stop | Node Manager | `startComponent.sh` / `nmStart(serverType='ReportsServerComponent')` – no `start(type='ReportsServer')` |

Property names checked in the OPSS jars (**confirmed (code)**):
`security.principal.alias`, `security.principal.key`,
`cleartext.ldap.credentials`, `user.search.bases`, `subscriber.name` exist;
`bootstrap.principal.key` does **not**.

## 5. Test plan (test host)

### 5.1 Set the password of the embedded LDAP administrator (manual, WLST)

> Automated since 2026-10-16: `01-setup-interview.sh` asks the password
> (`REPORTS_SECURITY=ldap`) and writes `embedded_ldap_sec.conf.des3`;
> `13-oracle_setup_reports.sh --apply` sets it in the domain when the
> `cn=Admin` bind fails (then restart the AdminServer, re-run 13). The manual
> steps below remain the reference / fallback.

The embedded LDAP administrator is `cn=Admin`; its password (`EmbeddedLDAP`
MBean, attribute `Credential`) is generated randomly when the domain is created
and is not known. Set it by hand (done on the test host 2026-10-16, as oracle):

1. Choose the password (letters and digits only – no `"` `$` `` ` `` `\` `#`
   `&`) and store it encrypted like the other credentials of the repository
   (`*.des3`, not in Git):

   ```bash
   cd /development/IHateWeblogic
   read -s -p "Embedded-LDAP password: " P; echo
   bash -c 'source 00-Setup/IHateWeblogic_lib.sh; _write_secrets_file /development/IHateWeblogic/embedded_ldap_sec.conf.des3 "EMBEDDED_LDAP_USER=cn=Admin" "EMBEDDED_LDAP_PWD=$1"' _ "$P"
   unset P
   ```

2. Set it in the domain (WLST interactive):

   ```
   $ORACLE_HOME/oracle_common/common/bin/wlst.sh
   connect(url='t3://localhost:7001')
   dn = cmo.getName()
   edit()
   startEdit()
   cd('/EmbeddedLDAP/' + dn)
   cmo.setCredential('<PASSWORD>')
   save()
   activate()
   exit()
   ```

   `connect()` without user/password uses the WLST key files in the home
   directory if they exist (autostart), otherwise it prompts. The password is
   visible in the WLST session but not in the bash history.

3. Restart the AdminServer (the embedded LDAP reads the credential at start;
   managed servers and the Reports server keep running):

   ```bash
   $ORACLE_BASE/admin/<domain>/ctrl/fmw_ctl.sh stop  AdminServer
   $ORACLE_BASE/admin/<domain>/ctrl/fmw_ctl.sh start AdminServer
   ```

   In `config.xml` the value is stored as
   `<embedded-ldap><credential-encrypted>{AES256}…`.

### 5.2 Steps

1. Backups: `config.xml`, `jps-config-jse.xml`, `rwserver.conf` (standalone).
2. Set the embedded LDAP credential, restart the AdminServer; read the DNs of
   `monUser` and the groups via LDAP.
3. `createCred` for `cn=Admin`.
4. New identity store instance in `jps-config-jse.xml`, default context
   switched; first `idstore.type=OPEN_LDAP`.
5. `securityId="rwJaznSec"` on the report job, restart repserver01.
6. Checks: `getserverinfo` as `monUser` → XML; without login / wrong user →
   refused; report call via `cgicmd.dat` key with `%* authid=RepRunner`;
   EM user search after a full restart.
7. Roll back on failure.

## 6. Alternatives

| | standalone + JSE LDAP identity store (this document) | in-process Reports server |
|---|---|---|
| OPSS / identity store | JSE context, must be pointed to LDAP | WebLogic context, realm used as is |
| Oracle default `securityId` | removed in our template – to be set | set (`rwJaznSec`) |
| own process / restart independently | yes | no (part of WLS_REPORTS) |
| libOVD overwrite by `rwserver` | yes (today) | no JSE process – **assumption** |
| tested on 14.1.2 here | yes – roles work, first request slow (§7) | no |

## 7. Findings (test host, 2026-10-16)

### 7.1 Configuration as tested

- Backups: `07-Maintenance/ConfigBackup/ldap_idstore_<ts>/` (`config.xml`,
  `jps-config-jse.xml`, `rwserver.conf`).
- `cn=Admin` password set manually (§5.1), stored in
  `embedded_ldap_sec.conf.des3`.
- LDAP bind as `cn=Admin` to `ldap://localhost:7001` works (JNDI from WLST,
  no `ldapsearch` installed). DNs (**confirmed (live)**):

  ```
  uid=monUser,ou=people,ou=myrealm,dc=fr_domain      inetOrgPerson, wlsUser
  uid=RepRunner,ou=people,ou=myrealm,dc=fr_domain    inetOrgPerson, wlsUser
  cn=Administrators,ou=groups,ou=myrealm,dc=fr_domain groupOfUniqueNames
  ```

- `createCred(map='reports.idstore', key='embeddedldap', user='cn=Admin', password=…)`.
- `jps-config-jse.xml` (default context: `idstore.xml` commented out):

  ```xml
  <serviceInstance name="idstore.ldap.embedded" provider="idstore.ldap.provider">
      <property name="idstore.type" value="OPEN_LDAP"/>
      <property name="ldap.url" value="ldap://localhost:7001"/>
      <property name="security.principal.alias" value="reports.idstore"/>
      <property name="security.principal.key" value="embeddedldap"/>
      <property name="subscriber.name" value="ou=myrealm,dc=fr_domain"/>
      <property name="username.attr" value="uid"/>
      <property name="groupname.attr" value="cn"/>
      <extendedProperty><name>user.search.bases</name>
          <values><value>ou=people,ou=myrealm,dc=fr_domain</value></values></extendedProperty>
      <extendedProperty><name>group.search.bases</name>
          <values><value>ou=groups,ou=myrealm,dc=fr_domain</value></values></extendedProperty>
  </serviceInstance>
  ...
  <!--serviceInstanceRef ref="idstore.xml"/-->
  <serviceInstanceRef ref="idstore.ldap.embedded"/>
  ```

- `rwserver.conf`: `<job jobType="report" engineId="rwEng" securityId="rwJaznSec" retry="3"/>`;
  `<identifier>` kept.
- `rwservlet.properties` unchanged (`singlesignon=yes`, `webcommandaccess=L1`).

### 7.2 Authentication and authorisation – works (confirmed (live))

| Test | Result |
|---|---|
| `getserverinfo` as `monUser` (`RW_MONITOR`) | `serverInfo` XML |
| `getserverinfo` as `RepRunner` (no `RW_MONITOR`) | `REP-56071 The requested operation is unauthorized` |
| `monUser` with wrong password | `REP-50171 Authentication failed` (log: `LoginException: Incorrect password`) |
| no `authid` | HTTP 499 (login required) |
| `<identifier>` admin | `serverInfo` (still works) |
| report job as `RepRunner` (`RW_EXECREPORTS`) | passes authorisation, stops at `<folderAccess>` (`REP-56132`, test report does not exist) |
| report job as `monUser` (no `RW_EXECREPORTS`) | `REP-56071 unauthorized` |
| report job without `authid` | HTTP 499 |

Passwords do not appear in any log (checked); the log shows `authid=monUser`
only. idstore type `OPEN_LDAP` works with the embedded LDAP.

So the standalone Reports server uses the same users and roles as the
in-process server – the role model of the Windows setup works once the JSE
identity store points to the realm's LDAP and `securityId` is set.

### 7.3 First request after a Reports server start takes 4–5 minutes

Measured with a clean sequence (full `systemctl restart`, 3 min idle, one
request): first `getserverinfo` 242 s, the following ones 0 s. Second run
(restart of repserver01 only, 2 min idle): 305 s. No log entry in that window.
Thread dumps during the first request (**confirmed (live)**) show two phases:

1. **CORBA connect rwservlet → rwserver (~60 s).** WLS_REPORTS thread in
   `RWClient.doGet → ServletCmdMgr.handleWebCommand →
   CommandManager.getServerSecuritySetting → ServerManager.isSecure →
   getServer → _ServerClassStub.getState → ContactInfoListIteratorImpl.next →
   TcpTimeoutsImpl.sleepTime` – the ORB retries the TCP connection with
   back-off. 19:28:45 request → 19:29:48 the Reports server starts working on it.
2. **libOVD start inside the Reports server (~4 min).** At the first
   authentication the Reports server initialises libOVD lazily:
   `OvdIdsStackProvider.initializeVirtualizationService →
   VirtualizationService.<init> → LibOVDDump.register → DiagnosticsFramework →
   ADRHelper.<init> → ADRHelper.getProcessExitValue` – the Oracle diagnostics
   framework starts an external (ADR) process and **waits for its exit**.
   Every start of the Reports server logs
   `java.lang.StackOverflowError thrown from the UncaughtExceptionHandler in thread "process reaper"`
   – the JDK thread that reports the exit of child processes. **Assumption:**
   the reaper dies, the exit is never reported and `getProcessExitValue` waits
   until its timeout. 19:29:48 → 19:33:50 response.

The rwserver runs with the FMW-bundled JDK 17.0.12 and only
`-DORACLE_HOME=… -Xmx256M -Xrs`. It reads its JVM options from the
environment variable `REPORTS_JVM_OPTIONS` (`librw.so`, default `-Xmx256M`) –
its environment comes from `$DOMAIN_HOME/reports/bin/reports.sh`; the
`REPORTS_JVM_OPTIONS` in `rwserver.conf` `<environment>` are for the engines.
**Fix for phase 2 (confirmed (live), 19:38–19:42):** in
`$DOMAIN_HOME/reports/bin/reports.sh` (IHateWeblogic block):

```bash
REPORTS_JVM_OPTIONS="-Xmx256M -Djdk.lang.processReaperUseDefaultStackSize=true -DORBWaitForResponseTimeout=999999999"; export REPORTS_JVM_OPTIONS
```

- `-Djdk.lang.processReaperUseDefaultStackSize=true` (standard JDK property:
  the reaper thread gets the default stack size instead of the small one),
  `-Xmx256M` = the previous default, `-DORBWaitForResponseTimeout` because
  Reports reads the ORB timeout only from this variable once it is set.
- `jcmd <rwserver> VM.command_line` shows the options after a restart of
  repserver01.
- Result: `StackOverflowError … "process reaper"` **0** (before: at every
  start), libOVD start in the Reports server 1 s instead of ~4 min,
  **first request 65 s** instead of 242 / 305 s, following requests 0 s.

**Phase 1 explained (confirmed (live) + code), 19:47–19:50:** the rwservlet
in WLS_REPORTS keeps the CORBA object reference (IOR) of the Reports server
process it talked to last. The rwserver listens on a new random port after
every start:

```
19:47:24 old rwserver pid 232946 listens 0.0.0.0:23323, WLS_REPORTS connected to :23323
19:48:11 new rwserver pid 234564 listens 0.0.0.0:32853
19:49:11 first request
19:50:15 WLS_REPORTS connects to :32853, response (64 s)
```

In between the ORB retries the dead old port (connection refused – not
visible in `ss` samples) with back-off until its connect timeout is used up,
then the servlet looks the server up again. Default of
`com.sun.corba.ee.transport.ORBTCPConnectTimeouts`
(`glassfish-corba-orb-4.2.5.jar`, `ParserTable`): `250:60000:…:5000` –
first retry after 250 ms, at most 5 s per wait, **60 000 ms in total**.

Consistent with the measurements: full domain restart (WLS_REPORTS new, no
old reference) 242 s, restart of only the Reports server 305 s – the
difference is these ~63 s. So phase 1 only appears when the Reports server is
restarted while WLS_REPORTS keeps running.

**Engines (confirmed (live), 20:14–20:17, report `test_dual.xml` as
`RepRunner`, PDF):**

| Situation | job duration |
|---|---|
| warm-up after restart of repserver01 | 64 s (phase 1 above) |
| regular engine recycling, `engLife="2"`, 8 jobs, engine PIDs changing | 85–661 ms – **no** delay |
| engine killed (`kill -9`, crash simulation), next job | **63 s** – same ORB connect timeout, this time **inside the rwserver** (it retries the dead engine) |
| following jobs | 76 ms – 1.4 s |

So regular `engLife` recycling is fine (the rwserver gets the new engine's
reference when it registers), but the 60 s ORB connect timeout hits twice:
WLS_REPORTS → rwserver after a Reports server restart, and rwserver → engine
after an engine crash.

**Fix for phase 1 (confirmed (live), 20:19–20:22):**
`-Dcom.sun.corba.ee.transport.ORBTCPConnectTimeouts=250:5000:100:1000` in
both JVMs:

```bash
# $DOMAIN_HOME/bin/setUserOverrides.sh, inside the WLS_REPORTS block
export EXTRA_JAVA_PROPERTIES="${EXTRA_JAVA_PROPERTIES} -Dcom.sun.corba.ee.transport.ORBTCPConnectTimeouts=250:5000:100:1000"

# $DOMAIN_HOME/reports/bin/reports.sh (rwserver)
REPORTS_JVM_OPTIONS="-Xmx256M -Djdk.lang.processReaperUseDefaultStackSize=true -DORBWaitForResponseTimeout=999999999 -Dcom.sun.corba.ee.transport.ORBTCPConnectTimeouts=250:5000:100:1000"; export REPORTS_JVM_OPTIONS
```

Check: `jcmd <pid> VM.system_properties | grep ORBTCPConnectTimeouts`
(the colons are shown escaped). Restart WLS_REPORTS and the Reports server.

| Situation | before | with both fixes |
|---|---|---|
| first job after restart of WLS_REPORTS + Reports server | 242–305 s | **1.8 s** |
| restart of the Reports server only | 64 s | **8.3 s** |
| engine crash (`kill -9`) | 63 s | **6.6 s** |
| following jobs | ~0.1 s | ~0.1 s |

Earlier considered alternatives (no longer needed):

- accept it – once per Reports-server-only restart / engine crash, ~60 s;
- shorter ORB connect timeout, e.g.
  `-Dcom.sun.corba.ee.transport.ORBTCPConnectTimeouts=250:5000:100:1000`, in
  **both** JVMs: WLS_REPORTS (`setUserOverrides.sh`, only for `WLS_REPORTS`)
  and the rwserver (`REPORTS_JVM_OPTIONS` in `reports.sh`) – affects all
  CORBA connects of these JVMs;
- restart WLS_REPORTS together with the Reports server.

### 7.4 libOVD

- With the LDAP identity store the Reports server no longer touches libOVD at
  its start (the XML store pushed at start).
- At the **first authentication** it pushes `idstore.ldap.embedded` into the
  shared `config/fmwconfig/ovd/default/adapters.os_xml` (afterwards only
  `<ldap id="idstore.ldap.embedded">`, 7332 bytes) and creates `ovd.lok` –
  the overwrite still happens, now with an LDAP adapter to the same LDAP.
  Effect on the EM "Add Principal" search: to be tested.
- `DO_NOT_PUSH_DATA_LIBOVD=true` would skip the push and with it probably the
  slow libOVD/diagnostics start – but then authentication may not work
  (libOVD is the identity layer). To be tested.

### 7.5 Open

- Reaper fix + ORB connect timeout: done (§7.3) – first job 1.8 s after a
  full restart, 8 s after a Reports server restart, 7 s after an engine crash.
- Transferred 2026-10-16: `13-oracle_setup_reports.sh` (`REPORTS_SECURITY=ldap`,
  steps 4c / 6 / 6b, tested `--apply` on the test host: 42 OK), `14b` /
  `cgicmd.dat.template` (`default: server=… %* authid=RepRunner/…` – PDF via
  `cmdkey=default`, URL `authid` does not override the key, no key → 499),
  docs 13 / 14b / 81, Reports cookbook 9.7 / 9.7b / 9.8 / 9.9 / 9.9b / 9.11,
  Reports_security.txt step 7b.
- EM "Add Principal" still finds no users with the new adapter (2026-10-16)
  – to analyse (SR draft).
- EM "Add Principal" search with the new adapter.
- Reaper fix also applies to the XML identity store setup (the reaper died
  there as well) – i.e. for every standalone Reports server.
- Customer: with `securityId` set but the XML identity store the customer
  got `REP-50171` and slowness – the slowness is the same libOVD/ADR start
  (§7.3), the `REP-50171` the XML store (§2).
