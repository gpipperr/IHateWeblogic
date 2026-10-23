# Reports Servlet Security – web commands, `<identifier>`, `webcommandaccess`

**Status:** analysis 2026-10-15; test D 2026-10-16 (secured server works
once the JSE identity store points to the WebLogic LDAP, see
[80-FMW-Architecture/reports_user_local_ldap.md](../../80-FMW-Architecture/reports_user_local_ldap.md),
`13-` Step 5a); **tests A–C and the full matrix done 2026-10-23 (section 7),
design decided (section 6), artifacts aligned (section 3).**
The findings below come from the live rebuild on Oracle Linux 9 / FMW 14.1.2
(CSPU Sep 2026, Reports QPR 39600348) and from the bytecode of
`oracle.reports.rwclient.CommandManager` (`reports/jlib/rwrun.jar`). The test
plan and the target design still have to be worked through in detail.

Related: [12-weblogic-report-monitoring_user.md](12-weblogic-report-monitoring_user.md)
(users/roles), [13-reports-detail-settings.md](13-reports-detail-settings.md)
(Reports server setup, REP-52262 section), root `README.md` → Open Items.

---

## 1. Why this needs its own topic

`getserverinfo` / `showjobs` (web commands of `rwservlet`) are used for every
status check – by operators (start/stop cookbook, step 0.2), by
`01-Run/rwserver_status.sh` and by monitoring. During the rebuild they answered
`REP-52262 Diagnostic output is disabled` for every user we tried, and the
current scripts/cookbooks contain statements that turned out to be wrong.
A customer who copied the Reports cookbook only from step 9.7 on ended up with
an empty `<identifier>` (variable `REPORTS_IDENTIFIER` not set).

---

## 2. Findings (confirmed)

### 2.1 `CommandManager.checkDiagnostic` (bytecode, 14.1.2 + QPR 39600348)

The setting compared is `<webcommandaccess>` from `rwservlet.properties`
(`RWClient.s_diagnostic`, default `"no"`).

| Condition | Result |
|---|---|
| `webcommandaccess=L1` and command is `showjobid`, `killjobid`, `showauth` or `getjobid` | allowed directly |
| Reports server is **secure** (`m_serverSecure`) | allowed directly (authorization then via the server's security, i.e. roles/policies) |
| `webcommandaccess` is `no`, `L0` or `L1` (any other command, server not secure) | `ServerManager.authenticateSysUser(server, sysUser, sysPassword)` – only if the caller is the **server administrator** (`ReportRunner.isAdmin()`) it is allowed, otherwise `REP-52262` |
| any **other** `webcommandaccess` value (e.g. `L2`) | allowed directly, **no authentication** |
| command `stopserver` | always requires the server administrator |

Consequences:

- `L0` is **not** "open". The cookbook (9.6) says "L0 = open, function test works
  without authid" – that is wrong according to the code.
- With `no`/`L0`/`L1` and a non-secure server, web commands need the server
  administrator = `<identifier>` in `rwserver.conf`.

### 2.2 Live results (test host, 2026-10-15)

| Test | Result |
|---|---|
| `getserverinfo` without `authid`, `webcommandaccess=L1`, `singlesignon=yes` | `REP-52262` |
| `authid=webadmin/…` (WebLogic admin, role `RW_ADMINISTRATOR`) | `REP-52262` |
| `authid=monUser/…` (role `RW_MONITOR` + `WebCommandPermission`) | `REP-52262` |
| `authid=RepRunner/…` (role `RW_EXECREPORTS`) | `REP-52262` |
| `authid=rep_admin/<identifier password>` (= `<identifier>` written by `13-`, at the time of the test the fixed demo password) | **works** – full `serverInfo` XML |

- The Reports server encrypts `<identifier>` on its first start
  (`encrypted="yes"`) – the password cannot be read back from the file afterwards.
- `rwserver.conf` from `13-` has `<security id="rwJaznSec" …/>` but **no**
  `securityId` on the `<job>` elements (cookbook comment: "SecurityId darf NICHT
  auf dem job-Element stehen") → server is treated as **not secure** → the
  `monUser`/`RW_MONITOR` model from step 12 does not apply to web commands.

---

## 3. State per artifact (aligned 2026-10-23)

| Artifact | State |
|---|---|
| `09-Install/13-oracle_setup_reports.sh` | `REPORTS_SECURITY=ldap` (default): `securityId` on the report job; `<identifier>` always from `reports_admin_sec.conf.des3` (random if missing) – FAIL if no password, never an empty element; `rwservlet.properties` `singlesignon=yes`, `webcommandaccess=L1`; info "never L2" in identifier mode |
| `01-Run/rwserver_status.sh` | `--auth auto` (monUser for ldap, else the `<identifier>` admin) since 2026-10-17; new section **Web Command Security**: `securityId`, `<identifier>` missing (WARN, test A) / empty (FAIL, test B) / encrypted, `webcommandaccess` not `no`/`L0`/`L1` (FAIL, test C); hint for `REP-51002` |
| `01-Run/reports_server_lib.sh` | REP errors only from `<error code=…>` – the `REP-` of old failed jobs in `showjobs` no longer counts as a command error |
| `09-Install/nginx-wls.conf.template`, doc 04 | admin web commands (`getserverinfo`, `showjobs`, `showenv`, `showmap`, `showauth`, `delauth`, `killjobid`, `parsequery`, `stopserver`) only from `127.0.0.1` + `ADMIN_IP_RANGE`; `getjobid` / `showjobid` / `showmyjobs` stay open (Forms `RUN_REPORT_OBJECT` + `WEB.SHOW_DOCUMENT`) – tested with an own Nginx instance (403 / pass) |
| Reports cookbook 9.2 / 9.6 / 9.7 / 9.11 / Bekannte Probleme | 9.2: value quoted, "never empty"; 9.6 writes `singlesignon=yes` + `L1` directly ("L0 is not open, never L2"); 9.7 aborts on an empty `REPORTS_IDENTIFIER` (`${VAR:?}`); 9.11 Nginx check expects 499 / 403; new problem entry "empty `<identifier>`" |
| `Reports_security.txt` (cookbook) | step 7: tested behaviour of a missing / empty `<identifier>`; step 8: L0 = L1, L2 open, monUser vs. admin; 2.3: keep `getjobid` open for Forms; open point removed |
| start/stop cookbook 0.2 | `getserverinfo … authid=<identifier>` – correct (admin works in both modes) |

---

## 4. Questions – answered 2026-10-23 (section 7)

1. `<identifier>` **missing**: the server starts and runs reports, but no one –
   not even with the former admin password – gets `getserverinfo`,
   `showjobs`, `showenv`, `showmap` on an unsecured server (`REP-52262`); the
   server does not create one (**confirmed (live)**).
2. **Empty** `<identifier encrypted="no"></identifier>` (customer case): the
   Reports server **does not start** – `REP-50125` `NullPointerException:
   Cannot invoke "org.w3c.dom.Node.getNodeValue()" because the return value
   of "org.w3c.dom.Element.getFirstChild()" is null` in
   `ServerConfig.open`, the Node Manager restarts it in a loop, every
   request gets `REP-51002 Bind to Reports Server failed`
   (**confirmed (live)**).
3. `webcommandaccess=L2` on an unsecured server: **every** web command
   without login – `getserverinfo`, `showjobs`, `showenv` (environment of the
   servlet), `showmap` (cgicmd.dat keys; Oracle masks the `authid` password as
   `<PASSWORD>`) – also **through Nginx from outside** (**confirmed (live)**).
   `L0` behaves like `L1` (not open).
4. `securityId` on the report job makes the server secure (test D):
   `monUser`/`RW_MONITOR` gets `getserverinfo` + `showjobs`, **not**
   `showenv` / `showmap` (`REP-56071`); the `<identifier>` admin gets
   everything; without login HTTP 499 – with `L1` and with `L2` alike. The old
   cookbook warning against `securityId` on `<job>` came from the missing
   LDAP identity store (`REP-50171`), not from `securityId` itself.
5. `singlesignon=yes` + `cgicmd.dat` key `default: … %* authid=RepRunner/…`:
   report runs work (smoke test `15-`, every run 2026-10-16…23).

---

## 5. Test plan (on the test host, reversible, with backups)

Restart via `fmw_ctl.sh restart repserver01` / `restart WLS_REPORTS`;
restore the current state afterwards.

| Test | Change | Check |
|---|---|---|
| A | remove `<identifier>` from `rwserver.conf`, restart `repserver01` | `getserverinfo` without `authid` at `L1`; also at `L0` |
| B | empty `<identifier encrypted="no"></identifier>` | same as A (customer case) |
| C | `webcommandaccess=L2` in `rwservlet.properties`, restart WLS_REPORTS | `getserverinfo`, `showjobs`, `showenv` without `authid` |
| D | `securityId="rwJaznSec"` on `<job jobType="report">`, back to `L1` | `getserverinfo` with `monUser`, `RepRunner`, `webadmin`; a report run via `cgicmd.dat` key |

---

## 6. Target design (decided 2026-10-23)

1. **No "open" first test.** It is not possible without `L2`, and `L2` opens
   everything to everyone (test C). The function test runs with `monUser`
   (secured) or the `<identifier>` admin – both deterministic.
2. **Default = secured server** (`REPORTS_SECURITY=ldap`): `securityId` on the
   report job, JSE identity store = WebLogic LDAP, `singlesignon=yes`,
   `webcommandaccess=L1`; status with `monUser`, reports via `cgicmd.dat`
   key with `RepRunner`.
3. **`<identifier>` always set, never empty** – emergency admin and
   `stopserver` in both modes; password random or from the interview, in
   `reports_admin_sec.conf.des3` (scripts) / the password safe (cookbook).
4. **Never `webcommandaccess=L2`**; `L0` is not "open" either.
5. **Nginx blocks the admin web commands** from outside (localhost + admin
   network), user commands for own jobs stay open.
6. `REPORTS_SECURITY=identifier` stays possible (unsecured server, web
   commands only for the admin) – for environments without the LDAP step.

---

## 7. Test results 2026-10-23 (test host, reversible, restored afterwards)

`getserverinfo`, `showjobs`, `showenv`, `showmap` via
`http://localhost:9002/reports/rwservlet/…`, each without `authid`, with
`monUser` (`RW_MONITOR`) and with the `<identifier>` admin; restart of
`repserver01` after each `rwserver.conf` change, of `WLS_REPORTS` after each
`rwservlet.properties` change. `singlesignon=yes` throughout.

| Case | `securityId` | `<identifier>` | `webcommandaccess` | without login | monUser | admin |
|---|---|---|---|---|---|---|
| D (default) | yes | set | L1 | HTTP 499 | info + jobs; env/map REP-56071 | all |
| D + L2 | yes | set | L2 | HTTP 499 | info + jobs; env/map REP-56071 | all |
| I | no | set | L1 | REP-52262 | REP-52262 | all |
| I + L0 | no | set | L0 | REP-52262 | REP-52262 | all |
| **A** | no | **missing** | L1 | REP-52262 | REP-52262 | **REP-52262** |
| **B** | no | **empty** | L1 | REP-51002 | REP-51002 | REP-51002 – server does not start (REP-50125 NPE) |
| **C** | no | set | **L2** | **all** | all | all – also via Nginx from outside |

Pitfalls of the test itself: a `REP-52262` answer is wrapped in
`<serverQueues>`, and `showjobs` lists the `REP-` codes of old failed jobs
in `<status>` – only `<error code=…>` is a command error (fixed in
`reports_server_lib.sh`). `showenv` / `showmap` answer HTML, not XML.
