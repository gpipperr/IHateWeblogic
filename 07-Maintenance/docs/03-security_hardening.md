---
title: "Oracle Forms & Reports 14c – Security Hardening of the WebLogic Realm"
description: "Security hardening of a running Oracle Forms & Reports 14.1.2 domain (DISA STIG): audit trail, password rule and account lockout of the WebLogic realm with wls_audit_config.sh, wls_password_rule.sh, wls_lockout_config.sh."
---

# Security hardening of the WebLogic realm

← [07-Maintenance](../README.md) · topics: [backup / restore](01-backup_restore.md) · [patching](02-patching.md) · [security hardening](03-security_hardening.md)

The three DISA STIG changes of
[stig_weblogic_forms_reports.md §5](../../80-FMW-Architecture/stig_weblogic_forms_reports.md#5-order-of-the-open-changes),
one script each – read-only by default, `--apply` with a backup of
`config.xml`, `--undo` as the way back. Run them in this order, test host
first. Check afterwards:
[`02-Checks/domain_secret_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/domain_secret_check.sh)
(sections 5 + 7). Entry page of every security topic:
[security_overview.md](../../80-FMW-Architecture/security_overview.md).

| # | Script | Change | Restart |
|---|---|---|---|
| 1 | [`wls_audit_config.sh`](#wls_audit_configsh) | configuration audit, DefaultAuditor, OPSS audit | yes |
| 2 | [`wls_password_rule.sh`](#wls_password_rulesh) | password rule 12 characters | no |
| 3 | [`wls_lockout_config.sh`](#wls_lockout_configsh) | lockout 3 / 30 / 15, `--unlock USER` | yes |

### wls_audit_config.sh

```bash
./07-Maintenance/wls_audit_config.sh                      # current state (WLST online) + plan
./07-Maintenance/wls_audit_config.sh --apply              # + --preset Medium for OPSS
./07-Maintenance/wls_audit_config.sh --undo --apply       # the way back
```

**Why:** without an audit trail an admin login and a deployment leave no
trace in the domain – the end point of both attack paths in
[fmw_pwd_handling.md §1a](../../80-FMW-Architecture/fmw_pwd_handling.md#1a-what-an-attacker-does-with-it--two-real-paths)
(DISA STIG V-235931/33/34, [stig_weblogic_forms_reports.md](../../80-FMW-Architecture/stig_weblogic_forms_reports.md)).

| Change | Where it lands | Active |
|---|---|---|
| configuration audit `logaudit` (Change Log and Audit) | every configuration change / activation with user in `<server>.log` + the auditing provider | after the restart (non-dynamic) |
| auditing provider `IHW_DefaultAuditor` (DefaultAuditor, severity `ERROR` = ERROR + SUCCESS + FAILURE) – only if the realm has none | `servers/<server>/logs/DefaultAuditRecorder.log`: successful and failed logins, configuration events, role / policy deployment; rotated daily, 50 files kept (provider defaults) | after the restart |
| OPSS audit `filterPreset` Low (`setAuditPolicy`) | OPSS management events only (credentials, keystores, policies, roles, audit configuration – `audit-store.xml`, no logins / authorisation checks): `servers/<server>/logs/auditlogs/JPS/audit_*.log` | at once |

`--apply` backs up `config.xml` first and prints the restart (`stop-all` /
`start-all`). `--undo` sets the configuration audit to `none`, removes only
`IHW_DefaultAuditor` and sets `filterPreset` to `None`.

**Live on the test host 2026-11-18:** `--apply` with Low, `stop-all` /
`start-all`: every component up; `DefaultAuditRecorder.log` in all three
servers (AdminServer ~300 records / 100 KB right after the start – mostly
role / policy deployment; a smoke test run added ~4 KB on WLS_REPORTS); a
login with a wrong user produced a `FAILURE` record with the user name, the
WLST login of the script a `SUCCESS` record; the OPSS policy change itself
is in `auditlogs/JPS/`. `domain_secret_check.sh` section 7: both audit WARN
gone; smoke test 32 OK. **Open:** the OPSS audit loader did not write that
event into `DEV_IAU` (0 rows in every `E$` table) – the file under
`auditlogs/` is the record for now; `--undo` not run live yet.

### wls_password_rule.sh

```bash
./07-Maintenance/wls_password_rule.sh                     # rule, realm users, stored passwords vs. the new rule
./07-Maintenance/wls_password_rule.sh --apply             # --min-length N (default 12, STIG 15)
./07-Maintenance/wls_password_rule.sh --undo --apply      # back to the template: 8 characters, 1 digit or special
```

**Why:** the domain template only demands 8 characters and one digit or
special character – the cracked admin password of the Medium case met
exactly that ([fmw_pwd_handling.md §1a](../../80-FMW-Architecture/fmw_pwd_handling.md#1a-what-an-attacker-does-with-it--two-real-paths),
DISA STIG V-235966–70).

| Section | Content |
|---|---|
| 1 current rule | `SystemPasswordValidator` values of `config.xml` |
| 2 realm users | WLST online, read-only (`listUsers` of every authentication provider) |
| 3 stored passwords | `weblogic_sec.conf.des3` (admin), `reports_users.conf.des3` (`monUser`, `RepRunner`) checked **locally** against the target rule (lib `wls_pwd_rule_fail`) – only the failed criteria are printed; a failing password cannot be set again after the change |
| 4 plan / 5 apply | backup of `config.xml`, WLST: `MinPasswordLength`, `MinUppercaseCharacters`, `MinLowercaseCharacters`, `MinNumericCharacters`, `MinNonAlphanumericCharacters` (1 each), `MinNumericOrSpecialCharacters` 1, `RejectEqualOrContainUsername` true |

The rule is checked whenever a password is **set** (create user, change,
reset) – existing passwords keep working. Not affected: Node Manager
password, embedded LDAP `cn=Admin`, Reports `<identifier>`, DB / RCU
passwords (no realm users). The prompts of the library check the active rule
before WLST would fail: `01-setup-interview.sh` (WLS admin),
`00-Setup/weblogic_sec.sh`, `12-oracle_reports_users.sh` – a failing password
only after a confirmation (it may be the existing password of the realm).

**Live on the test host 2026-11-18** (`--min-length 12`): active at once,
no restart (dynamic attributes); a temporary test user with a weak password
was rejected (`Security:099069` length, `099078` upper case, `099079`
special character), a strong one accepted, the user removed again – the
three steps are in `DefaultAuditRecorder.log` (audit trail of step 1).
Stored passwords: `monUser` / `RepRunner` meet the rule, the **admin
password does not** (length, upper case, special character) – it keeps
working; the next change must meet the rule. Smoke test 32 OK.

### wls_lockout_config.sh

```bash
./07-Maintenance/wls_lockout_config.sh                     # settings, runtime, lockout events (30 days)
./07-Maintenance/wls_lockout_config.sh --apply             # 3 / 30 / 15 (--threshold / --duration / --reset)
./07-Maintenance/wls_lockout_config.sh --undo --apply      # WebLogic defaults 5 / 30 / 5
./07-Maintenance/wls_lockout_config.sh --unlock RepRunner  # operational: clear a lockout on every running server
```

**Why:** DISA STIG V-235936–38 (3 failed logins); the default 5 / 30 / 5
lets a guesser try 5 passwords every 5 minutes.

| Value | STIG | Library | Note |
|---|---|---|---|
| threshold | 3 | **3** | |
| duration (min) | 15 | **30** | WebLogic warns below 30 min in production mode (`BEA-090978`, message catalog) – 30 is the stricter value |
| reset duration (min) | 15 | **15** | failures are counted over 15 minutes |

The values are **non-dynamic** – restart the domain after `--apply`. The
runtime view (section 2) lists per server the users locked now, invalid
logins and lockouts since the start; section 3 the `BEA-090078` messages
(user + client address) of the last `LOCKOUT_LOG_DAYS` (30) days – WebLogic
logs one at the lockout and one for each attempt on the locked account.

**Live on the test host 2026-11-18:** `--apply`, restart (no
`BEA-090978`), every component up; a temporary test user was locked after 3
wrong logins (the right password then answered 401 instead of 403),
`--unlock` released it (403 again), user removed. 4 wrong
`authid=RepRunner` through `rwservlet` gave `REP-50171` but **no lockout** –
the standalone Reports server checks `authid` with an LDAP bind against the
embedded LDAP, past the realm lockout
([reports_user_local_ldap.md §8](../../80-FMW-Architecture/reports_user_local_ldap.md#8-account-lockout-does-not-cover-authid-test-host-2026-11-18)).
Smoke test 32 OK.
