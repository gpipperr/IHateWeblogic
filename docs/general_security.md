---
title: "Password Security and Secure Report Invocation"
description: "How this library stores passwords (encrypted per machine, never in environment.conf) and how Oracle Reports are invoked securely with basic rwservlet hardening."
---

# General Security – Passwords and Report Invocation

← Back to the [root README](../README.md)

## Password Security Concept

Based on: <https://www.pipperr.de/dokuwiki/doku.php?id=dba:passwort_verschluesselt_hinterlegen>

The WebLogic admin password is encrypted with `openssl des3` using the machine's
disk UUID as key. The encrypted file `weblogic_sec.conf.des3` is machine-specific
and **must not be committed to git** (covered by `.gitignore`).

The same mechanism (`_write_secrets_file` / `load_secrets_file` in the lib)
holds all other secrets in the repository root – never in `environment.conf`:

| File | Content | Written by |
|---|---|---|
| `weblogic_sec.conf.des3` | WebLogic admin | [`01-setup-interview.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/01-setup-interview.sh), [`00-Setup/weblogic_sec.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/00-Setup/weblogic_sec.sh) |
| `db_sys_sec.conf.des3` | DB SYS + RCU schema password | interview |
| `mos_sec.conf.des3` | My Oracle Support | interview, [`00-Setup/mos_sec.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/00-Setup/mos_sec.sh) |
| `reports_users.conf.des3` | `monUser`, `RepRunner` | [`12-oracle_reports_users.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/12-oracle_reports_users.sh) |
| `embedded_ldap_sec.conf.des3` | embedded LDAP `cn=Admin` (`REPORTS_SECURITY=ldap`) | interview (13- sets it in the domain) |
| `reports_admin_sec.conf.des3` | Reports server admin `<identifier>` | interview, else random by `13- --apply` |
| `test_db_sec.conf.des3` | DB user of the smoke test | `15-` (asks once) |

## Report Security – Secure Invocation & Basic Hardening

By default the Reports Servlet (`rwservlet`/`getserverinfo`) is **unsecured** –
anyone who can reach the port can query server status or run reports. This is
important to fix before going live, not just a nice-to-have.

See [`09-Install/docs/12-weblogic-report-monitoring_user.md`](../09-Install/docs/12-weblogic-report-monitoring_user.md)
for the full role-based security model: a three-tier WebLogic/OPSS permission
chain (Application Policy → Application Role → user in the Security Realm)
separating **monitoring** (`monUser` / `RW_MONITOR` – status queries only, no
reports) from **report execution** (`RepRunner` / `RW_EXECREPORTS` – runs
reports via `authid=` in `cgicmd.dat`, password never appears in the report
URL) from full **admin access** (`weblogic` / `RW_ADMINISTRATOR`). Automated
by [`09-Install/12-oracle_reports_users.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/12-oracle_reports_users.sh); the same concept is also in the
German manual cookbook (Schritt 8) for customers installing by hand — see
[`70-Customer-Projects/`](../70-Customer-Projects/README.md).

> **Since 2026-10-16 the default is a secured Reports server**
> (`REPORTS_SECURITY=ldap`, `13-`): `securityId` on the report job + the
> standalone server's identity store pointed to the WebLogic embedded LDAP –
> then `monUser`/`RW_MONITOR` (`getserverinfo`) and `RepRunner`/`RW_EXECREPORTS`
> (report jobs, via the `cgicmd.dat` key `default: … %* authid=…`) work as
> designed; calls without login get HTTP 499. Background:
> [`80-FMW-Architecture/reports_user_local_ldap.md`](../80-FMW-Architecture/reports_user_local_ldap.md).
>
> **Live finding 2026-10-15** (still true for `REPORTS_SECURITY=identifier`):
> as long as the Reports server is **not**
> secured via `securityId` on the `<job>` element of `rwserver.conf`, the
> roles above do not apply to web commands. With `<webcommandaccess>`
> `no`/`L0`/`L1`, `getserverinfo`/`showjobs` then require the **server
> administrator** from `<identifier>` in `rwserver.conf` as `authid`
> (`repadmin/...`); `authid=monUser/...` or the WebLogic admin return
> `REP-52262 Diagnostic output is disabled` (confirmed in the
> `CommandManager.checkDiagnostic` bytecode). See
> [`09-Install/docs/13-reports-detail-settings.md`](../09-Install/docs/13-reports-detail-settings.md).
>
> [`01-Run/rwserver_status.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/01-Run/rwserver_status.sh) and [`05-ReportsPerformance/engine_perf_analyse.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/05-ReportsPerformance/engine_perf_analyse.sh)
> call `getserverinfo` with `authid` (`--auth`, shared
> [`01-Run/reports_server_lib.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/01-Run/reports_server_lib.sh), since 2026-10-17 / 2026-10-19).
>
> **Test series 2026-10-23** ([doc 81 §7](../09-Install/docs/81-reports_rwservlet_security.md)):
> an **empty** `<identifier>` stops the Reports server from starting
> (REP-50125, restart loop), a missing one locks every web command;
> `webcommandaccess=L0` is not open, **`L2` opens every web command without
> login – also through Nginx**. `rwserver_status.sh` checks all three; the
> Nginx template blocks the admin web commands from outside.
>
> **Live finding 2026-11-03:** WebLogic logs the whole `cs-uri` – a GET with
> `authid=user/password` (or `userid=` with the DB password) lands **in plain
> text** in `WLS_REPORTS/logs/access.log`. Send web commands and report
> requests as **POST** (all parameters in the body – a POST ignores the
> query string); `reports_server_lib.sh` does so since 2026-11-03, `15-` and
> the docs since 2026-11-06. Old log files keep the passwords. Monitoring
> of the server: [reports_monitoring_getserverinfo.md](../80-FMW-Architecture/reports_monitoring_getserverinfo.md);
> error XML codes have no `REP-` prefix (`code="56071"`).
