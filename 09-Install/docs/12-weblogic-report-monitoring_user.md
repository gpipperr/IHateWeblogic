# Step 12 – Reports Server User & Security Setup

**Script:** `09-Install/12-oracle_reports_users.sh` *(planned)*
**Runs as:** `oracle` (WLST) / Browser (Enterprise Manager)
**Phase:** 5 – Configuration & Validation

**Source:** [pipperr.de – Oracle Reports 14c: Reports Servlet Admin / Monitoring and Report User Setup](https://www.pipperr.de/dokuwiki/doku.php?id=forms:oracle_reports_14c_windows64&s[]=boot&s[]=properties#reports_servlet_admin_oberflaeche_erlauben_-_monitoring_und_report_user_anlegen)

---

## Purpose

Secure the Reports Server against unauthorized access while enabling automated
monitoring and scripted report execution.

Three WebLogic users are created with distinct permission levels:

| User | Role | Purpose |
|---|---|---|
| `weblogic` *(existing)* | `RW_ADMINISTRATOR` | Admin UI in EM, full Reports management |
| `monPrtgUser` | `RW_MONITOR` | Monitoring tools (PRTG, Nagios …) – status query only |
| `EXECREPORTS` | `RW_EXECREPORTS` | Run reports – no admin access |

---

## Background – Permission Chain

WebLogic Reports uses a three-tier security architecture:

```
Application Policies
    └── linked to Application Role  (e.g. RW_MONITOR)
            └── linked to User      (Security Realm / myrealm)
```

> Reference: Oracle Doc ID 2072876.1 – *REP-56071 When Attempt to Access
> In-Process Reports Server in Reports 12c*

**Enterprise Manager (EM):** `http://<host>:9002/em`

---

## 1 – weblogic → RW_ADMINISTRATOR

Grant the existing `weblogic` admin user access to the Reports Servlet UI so
Report jobs can be managed via EM.

### Manual Steps (EM Browser)

1. Open EM: `http://<host>:9002/em`
2. Menu: **WebLogic Domain → Security → Application Roles**
3. *Application Stripe* = **reports** → search (`>`)
4. Select role **RW_ADMINISTRATOR** → **Edit**
5. Section *Members* → **+ Add**
   - *Type*: `User`
   - Search (`>`) → select user `weblogic` → **OK**
6. Confirm with **OK**

### Verification

```
https://<host>/reports/rwservlet/showenv
# Must display the Reports environment variables after login as weblogic
```

---

## 2 – Monitoring User (monPrtgUser) → RW_MONITOR

This user may **only** call `getserverinfo` – no reports, no admin.

Monitoring URL (e.g. PRTG):

```
http://<host>:9002/reports/rwservlet/getserverinfo?authid=monPrtgUser/<PWD>&statusformat=XML
```

### 2a – Create User (Security Realm)

1. EM → **WebLogic Domain → Security → Security Realms**
2. Select **myrealm**
3. Tab **Users and Groups**
4. **Create** → Name: `monPrtgUser`, description, set password → **OK**

### 2b – Check / Create Application Role RW_MONITOR

1. EM → **WebLogic Domain → Security → Application Roles**
2. *Application Stripe* = **reports** → search (`>`)
3. **RW_MONITOR** exists? → **Edit** → assign user `monPrtgUser` via **+ Add**
4. If not present: **Create** → Name `RW_MONITOR` → assign user

### 2c – Configure Application Policy for RW_MONITOR

1. EM → **WebLogic Domain → Security → Application Policies**
2. *Application Stripe* = **reports** → search (`>`)
3. Select principal **RW_MONITOR** → **Edit**
4. Verify that role `RW_MONITOR` is already assigned as principal; if not: assign it
5. Section *Permissions* → **+ Add**
   - *Permission Class*: `oracle.reports.server.WebCommandPermission`
   - Search (`>`)
   - Select resource:
     ```
     webcommands=showmyjobs,getjobid,showjobid,getserverinfo,showjobs server=*
     ```
   - *Permission Actions*: **ALL**
   - **OK** → **OK**

---

## 3 – Report Execution User (EXECREPORTS) → RW_EXECREPORTS

This user is stored in `cgicmd.dat` as the `authid=` parameter so that reports
can be executed automatically without exposing a password in the URL.

### 3a – Create User (Security Realm)

1. EM → **WebLogic Domain → Security → Security Realms**
2. **myrealm** → Tab **Users and Groups**
3. **Create** → Name: `EXECREPORTS`, description, set a strong password → **OK**

### 3b – Create Application Role RW_EXECREPORTS

1. EM → **WebLogic Domain → Security → Application Roles**
2. *Application Stripe* = **reports** → search (`>`)
3. **Create** → Name: `RW_EXECREPORTS`
4. Assign user `EXECREPORTS` via **+ Add** → **OK**

### 3c – Create Application Policy for RW_EXECREPORTS

1. EM → **WebLogic Domain → Security → Application Policies**
2. *Application Stripe* = **reports** → search (`>`)
3. **Create** → new principal: `RW_EXECREPORTS`
4. Assign role `RW_EXECREPORTS` as principal
5. Section *Permissions* → **+ Add**
   - *Permission Class*: `oracle.reports.server.ReportsPermission`
   - Search (`>`)
   - Select resource:
     ```
     report=* server=* destype=* desformat=* allowcustomargs=true
     ```
   - *Permission Actions*: **ALL**
   - **OK** → **OK**

---

## 4 – cgicmd.dat: Adding the authid Parameter

To prevent the `EXECREPORTS` password from appearing in the report call URL,
store it centrally in `cgicmd.dat`.

### File Path

```
$DOMAIN_HOME/config/fmwconfig/servers/WLS_REPORTS/applications/reports_14.1.2/configuration/cgicmd.dat
```

### Format

The `authid=` parameter is appended **after** `%2` to the existing key:

```
# Before (no authentication):
default: server=repserver01 statusformat=xml %2

# After (with authid – placed AFTER %2):
default: server=repserver01 statusformat=xml %2 authid=EXECREPORTS/<PWD>

# Example with DB connection:
SalesDEPRep: %1 userid=salesRep/<PWD>@<DBSERVICE> destype=cache desformat=pdf %2 authid=EXECREPORTS/<PWD>
```

> **Security note:** `cgicmd.dat` stores the password in plaintext.
> The file must have permissions `640` (oracle:oracle) and must not be
> accessible via the web server.

### Backup Before Editing

```bash
cp "$DOMAIN_HOME/config/fmwconfig/servers/WLS_REPORTS/applications/reports_14.1.2/configuration/cgicmd.dat" \
   "$DOMAIN_HOME/config/fmwconfig/servers/WLS_REPORTS/applications/reports_14.1.2/configuration/cgicmd.dat.bak_$(date +%Y%m%d)"
```

---

## 5 – Verification

### Monitoring User

```bash
# Status query without browser (curl)
curl -s "http://localhost:9002/reports/rwservlet/getserverinfo?authid=monPrtgUser/<PWD>&statusformat=XML" \
  | grep -E '<server|engineState|status='
```

Expected output contains `<server name="repserver01"` and engine entries with
`status="1"` (IDLE) or `status="2"` (BUSY).

### Execution User

```bash
# Call a simple report via cgicmd.dat key
curl -I "http://localhost:9002/reports/rwservlet?cmdkey=default&report=<testreport.rdf>&destype=cache&desformat=pdf"
# Expect HTTP 200 or 302 – NOT 401/403
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `401 Unauthorized` on getserverinfo | Servlet secured, no authid passed | Append `authid=user/pwd` to URL |
| `403 Forbidden` despite authid | User not assigned to role | Check Application Role (step 2b / 3b) |
| `403 Forbidden` on report call | Policy permission missing | Check Application Policy (step 3c) |
| getserverinfo returns empty response | Reports Server not running | Check WLS_REPORTS in Admin Console |
| Password visible in URL | authid not in cgicmd.dat | Add authid to cgicmd.dat key (section 4) |
| Changes have no effect | Security cache not refreshed | Restart WLS_REPORTS managed server |

---

## Oracle Documentation References

### WLST OPSS Custom Commands

The script uses OPSS (Oracle Platform Security Services) WLST commands to manage
Application Roles and Application Policies programmatically.

| Command | Purpose | Oracle Doc |
|---|---|---|
| `createAppRole` | Create a new Application Role in a stripe | *WLST Command Reference for Infrastructure Components* – Chapter: OPSS Custom WLST Commands |
| `grantAppRole` | Assign a user or group to an Application Role | same |
| `grantPermission` | Create an Application Policy entry with a Permission | same |

**Parameters used in `grantPermission`:**

| Parameter | Description |
|---|---|
| `appStripe` | Application stripe name – `reports` for Oracle Reports |
| `principalClass` | `oracle.security.jps.service.policystore.ApplicationRole` for role-based policies |
| `permClass` | Java permission class (see below) |
| `permTarget` | Resource string passed to the permission constructor |
| `permActions` | `ALL` grants all defined actions |

Oracle doc entry point for OPSS WLST commands:
**Securing Applications with Oracle Platform Security Services**
→ Appendix: OPSS WLST Custom Commands
→ Search for: `grantPermission`, `createAppRole`, `grantAppRole`

Direct URL (WebLogic / FMW 14.1.2):
`https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/`
→ Security → *Securing Applications with Oracle Platform Security Services*

---

### Reports Permission Classes

These Java permission classes control what a principal may do in the Reports Servlet:

| Class | Controls |
|---|---|
| `oracle.reports.server.WebCommandPermission` | Which servlet commands a principal may call (e.g. `getserverinfo`, `showjobs`) |
| `oracle.reports.server.ReportsPermission` | Which reports a principal may run (report, server, destype, desformat) |

**Reference:** Oracle Support Doc ID **2072876.1** –
*REP-56071 When Attempt to Access In-Process Reports Server in Reports 12c*

Also documented in:
**Oracle Reports Developer's Guide** – Chapter: Security in Oracle Reports
→ Section: Configuring Oracle Reports Security
→ Search for: `WebCommandPermission`, `ReportsPermission`

---

### WebLogic Security Realm MBean (`createUser`)

The script creates Security Realm users by navigating to the
`DefaultAuthenticator` configuration MBean and calling `createUser()`.

MBean path used:
```
/SecurityConfiguration/<domain>/Realms/myrealm/AuthenticationProviders/DefaultAuthenticator
```

Reference:
**Oracle WebLogic Server MBean Reference**
→ `DefaultAuthenticatorMBean`
→ Method: `createUser(name, password, description)`

URL:
`https://docs.oracle.com/en/middleware/fusion-middleware/weblogic-server/14.1.2/wlmbr/mbeans/DefaultAuthenticatorMBean.html`

---

### WLST General Reference

**WebLogic Scripting Tool Command and Variable Reference**
`https://docs.oracle.com/en/middleware/fusion-middleware/weblogic-server/14.1.2/wlstc/`

---

## Related Files

| File | Purpose |
|---|---|
| `$DOMAIN_HOME/.../cgicmd.dat` | authid parameter for report execution |
| `09-Install/12-oracle_reports_users.sh` | Automation script for this setup |
| `09-Install/09-oracle_configure.sh` | Base configuration (includes cgicmd.dat setup) |
| `09-Install/docs/09-oracle_configure.md` | Configuration steps overview |
| `01-Run/rwserver_status.sh` | Automated status monitoring (uses getserverinfo) |
| `00-Setup/weblogic_sec.sh` | WebLogic password concept (encrypted storage) |





