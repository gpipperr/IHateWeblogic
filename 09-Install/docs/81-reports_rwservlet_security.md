# Reports Servlet Security – web commands, `<identifier>`, `webcommandaccess`

**Status:** analysis 2026-10-15; **test D done 2026-10-16** – the secured
server works once the JSE identity store points to the WebLogic LDAP, see
[80-FMW-Architecture/reports_user_local_ldap.md](../../80-FMW-Architecture/reports_user_local_ldap.md)
and `13-` Step 5a (`REPORTS_SECURITY=ldap`). Tests A–C still open.
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

### 2.2 Live results (orafusion01, 2026-10-15)

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

## 3. Current state per artifact (to be corrected)

| Artifact | Current content | Problem |
|---|---|---|
| `09-Install/13-oracle_setup_reports.sh` | writes `<identifier>` from `reports_admin_sec.conf.des3` (fixed 2026-10-16, before: fixed demo password `rep_admin/wls_team`), `rwservlet.properties` with `singlesignon=yes`, `webcommandaccess=L1` | hardened from the start, no "open" first test |
| Reports cookbook 9.2 / 9.7 | `REPORTS_IDENTIFIER` set in 9.2, used in 9.7 | copying only from 9.7 → empty `<identifier>`; no quotes around the value (special characters) |
| Reports cookbook 9.6 | `webcommandaccess=L0`, `singlesignon=no`, comment "open" | L0 is not open (2.1) |
| Reports cookbook 9.11, start/stop cookbook 0.2 | `getserverinfo … authid=<identifier>` | correct for the current design, but depends on the open decision |
| Reports cookbook Schritt 8 (monUser verification) | `authid=monUser/…` | only works with a secure server |
| `01-Run/rwserver_status.sh` | `getserverinfo` without `authid` | gets `REP-52262` |

---

## 4. Open questions

1. What happens when `<identifier>` is **missing** from `rwserver.conf`?
   (No admin check? Server generates one? `REP-52262`?)
2. What happens with an **empty** `<identifier encrypted="no"></identifier>`
   (customer case)?
3. Does `webcommandaccess=L2` really open all web commands without
   authentication on 14.1.2 (bytecode says yes – verify live), and which
   commands does that expose (`showenv`, `showmap`, `killjobid`, …)?
4. What exactly makes the server "secure" (`m_serverSecure`) – `securityId` on
   `<job>`? Does `monUser`/`RW_MONITOR` (`WebCommandPermission`) then work for
   `getserverinfo`? Why does the cookbook warn against `securityId` on `<job>`
   (source of that statement to be checked)?
5. Interaction with `singlesignon=yes/no` and `cgicmd.dat` `authid` for report
   execution (`RepRunner`/`RW_EXECREPORTS`).

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

## 6. Target design (draft, to be decided)

1. **First function test open:** cookbook/script start without server-admin
   check (variant from test A or C) so a misconfigured role cannot hide whether
   the server itself works.
2. **Separate hardening step afterwards:**
   - Option 1 – server administrator: `<identifier>` with a chosen password
     (quoted, stored in the password safe / encrypted `*.des3` like the other
     credentials), `webcommandaccess=L1`, status checks with that `authid`.
   - Option 2 – secured server: `securityId` on `<job>`, roles/policies from
     step 12 (`monUser`/`RW_MONITOR` for status, `RepRunner` for reports),
     status checks with `authid=monUser/…`.
3. **Guard for partial copying:** 9.7 aborts if `REPORTS_IDENTIFIER` is empty
   (only if Option 1 is chosen).
4. Then align `13-oracle_setup_reports.sh`, doc 13, both cookbooks and
   `01-Run/rwserver_status.sh` (`authid` from an encrypted file).
