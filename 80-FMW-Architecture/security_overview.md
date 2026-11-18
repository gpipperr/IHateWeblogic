---
nav_title: "Security"
title: "Oracle Forms & Reports 14c Security – Overview, Patch Cycle, Hardening"
description: "Security entry page of IHateWeblogic for Oracle Forms & Reports 14.1.2: the security model, the current Oracle patch cycle, hardening by layer with fix and check scripts, passwords, Reports invocation, residual risks."
redirect_from:
  - /docs/general_security.html
  - /docs/forms_reports_security.html
---

# Forms & Reports 14c – security overview

One entry page for every security topic of this library: the model, the
current patch cycle, the hardening per layer with the script that does it
and the check that proves it, the passwords, the Reports invocation and the
residual risks. Details live on the linked pages; findings are marked there
(**confirmed (live)** / **documented**).

---

## 1. Security at a glance

```
 user / admin network                       host (Oracle Linux)
 ---------------------                      ------------------------------------------------
 browser, Forms client  --TLS 443-->  Nginx  --HTTP-->  127.0.0.1:9001 WLS_FORMS   (Forms)
                                      |                 127.0.0.1:9002 WLS_REPORTS (rwservlet)
 admin network only      /console /em |                 127.0.0.1:7001 AdminServer (EM, REST, WLST)
 (ADMIN_IP_RANGE)  -------------------'                 127.0.0.1:5556 Node Manager
                                                        127.0.0.1      Reports ORB, Coherence
                                                        local RCU DB, embedded LDAP
                         every process runs as the domain owner "oracle"
```

Three things decide the security of such an installation – the two public
cases in [fmw_pwd_handling.md §1a](fmw_pwd_handling.md#1a-what-an-attacker-does-with-it--two-real-paths)
show all three:

1. **Patch level** – Oracle ships fixes every month (section 2).
2. **Reachability** – only Nginx is reachable; every WebLogic socket listens
   on loopback, the admin interfaces only from the admin network.
3. **Blast radius** – code execution in any WebLogic JVM runs as `oracle`:
   what that account can read and do (domain key, other domains, `sudo`,
   `dba`) belongs to the attacker as well ([§1b](fmw_pwd_handling.md#1b-blast-radius-of-the-domain-owner-account)).

## 2. Current patch cycle

> **Oracle now ships security fixes every month** (quarterly CPU, CSPU in
> the other months, Security Alerts in between). Check the current cycle
> **before every installation and every patch run**.

**Current cycle: CSPU November 2026 (2026-11-17)** – state 2026-11-18,
applied on the test host (FMW home, repository DB MRP, APEX 26.2.1, ORDS
26.3.1).

| | |
|---|---|
| Current patch list (14.1.2) | [`09-Install/docs/00-patch-references.md`](../09-Install/docs/00-patch-references.md) – patch numbers from MOS KA1182 + CPU450 / CPU435 / CPU431, CVE check, "What a home needs – CPU vs. CSPU", "How to read KA1182", MOS Doc-ID table |
| Earlier cycles | frozen snapshots, one per cycle, for rolling back by hand – table "Patch cycle history" in the same file ([CPU October 2026](../09-Install/docs/00-patch-references_october_2026.md), [CSPU September 2026](../09-Install/docs/00-patch-references_september_2026.md)) |
| Scripts / [`oracle_software_version.conf`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/oracle_software_version.conf) | **CSPU November 2026** – switched 2026-11-18 (release `v1.0.202611`, procedure [update_lib_to_act_cpu.md](../docs/update_lib_to_act_cpu.md)) |
| DB client tools, APEX, ORDS | own release cycles beside the FMW patches: Instant Client 23.26.x (DB RU), SQLcl / ORDS / APEX (OTN releases, APEX patch set bundles via MOS) – update = run [`00-Setup/install_db_client_tools.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/00-Setup/install_db_client_tools.sh) / `04-` again, see "DB client tools, APEX, ORDS" in the patch list |
| Forms & Reports 14.1.2 – manual guides per cycle | [`70-Customer-Projects/FormsReports14_patch_cspu_2026-11/`](../70-Customer-Projects/FormsReports14_patch_cspu_2026-11/README.md) – analysis (README facts from the ZIPs, live run 2026-11-18) + guide **full** (any older level) and **cumulative from CPU Oct 2026** – the master for the scripts |
| Forms & Reports 12.2.1.19 (customer homes) | manual analysis: [`70-Customer-Projects/FormsReports12_patch_cspu_2026-11/`](../70-Customer-Projects/FormsReports12_patch_cspu_2026-11/README.md) |

What matters in this cycle:

- **One run, not "CPU + CSPU":** KA1182 is cumulative – the November list
  contains the October CPU patches; a never patched home needs one run.
  Two layers only for the repository DB (RU 19.33 of the CPU + MRP of the
  month) and APEX (release + patch set bundle).
- **WebLogic** – 7 CVEs up to **10.0** (TopLink, T3/IIOP, SOAP, HTTP) → SPB
  **40289362** (PSU 40205408). The PSU switches a new gate **on by default**:
  `JAXWSRejectUnknownSEIOperationsEnabled` (KB694158) – no impact on Forms /
  Reports / EM on the test host.
- **FMW infrastructure** – OPSS **10.0** (40154045), UMS **9.8** (40145610,
  matrix name "Service Delivery Platform"), ADF (40155248), OHS / proxy
  plug-in curl (40181911), Certifi (Third-Party BP in the SPB).
- **Java** – 11 CVEs incl. **Java4Shell** (CVE-2026-114938, Base64 intrinsic,
  only on AVX-512 VBMI CPUs) → JDK **21.0.13.1** (also closes the eMudhra
  alert CVE-2026-114820); Forms clients: client bundle 21.0.13.1 / JRE 8
  **8u513**. Details: [00-patch-references.md – Java4Shell](../09-Install/docs/00-patch-references.md#java4shell--cve-2026-114938-state-2026-11-18).
- **FMW-bundled JDK** `oracle_common/jdk` 17.0.12 (Reports engines): still
  no patch – in the Java4Shell range; mitigated with
  `-XX:-UseBASE64Intrinsics` (`13-oracle_setup_reports.sh --apply`, every
  host with a bundled JDK 11+, check `java_check.sh`); SR open.
- **Repository DB 19.33** – Oracle Text CVE-2026-114848 (9.9) → MRP
  **40196156** (in-place) + DB home JDK 8u513; OpenSSL CVE-2026-72897 has no
  19c fix yet and does **not** depend on the OS `openssl` package (not
  reachable without TCPS).
- **APEX 26.2.0 / ORDS 26.3.0** – CVE-2026-114849 (9.8) and more → APEX
  **26.2.1** (patch set bundle 40040466) + ORDS **26.3.1**, one window.
- **FMW DBCLIENT** 23.26.2 inside the Oracle Home: unchanged in the November
  SPB; no client-only DB row in November – see "FMW DBCLIENT – known
  residual" in [`00-patch-references.md`](../09-Install/docs/00-patch-references.md).
- Oracle publishes no CVE → patch mapping: we prove the **patch level**
  ("installed ≥ patch document"), not the fix of a single CVE.

## 3. Hardening by layer

| Layer | What | Fix (script) | Check | Background |
|---|---|---|---|---|
| Network / Nginx | only Nginx reachable, every internal socket on `127.0.0.1`, `/console` `/em` from `ADMIN_IP_RANGE`, client proxy headers stripped | `08-`, `13-`, [`04-root_nginx.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/04-root_nginx.sh) | [`clone_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/clone_check.sh), [`port_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/port_check.sh), [`domain_secret_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/domain_secret_check.sh) §4 | [clone_golden_image.md](clone_golden_image.md), [doc 05](../09-Install/docs/05-root_nginx_ssl.md) |
| WebLogic realm | audit trail (configuration audit + DefaultAuditor + OPSS), password rule 12 characters, lockout 3 / 30 / 15 | [`wls_audit_config.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/wls_audit_config.sh), [`wls_password_rule.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/wls_password_rule.sh), [`wls_lockout_config.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/wls_lockout_config.sh) (`--unlock`) | `domain_secret_check.sh` §5 + §7 | [stig_weblogic_forms_reports.md](stig_weblogic_forms_reports.md) |
| Domain secrets | `SerializedSystemIni.dat` + `boot.properties` mode 600, no clear text, no key copies | `domain_secret_check.sh --apply` | `domain_secret_check.sh` §1–§3, §6 | [fmw_pwd_handling.md](fmw_pwd_handling.md) |
| Reports | secured server (`REPORTS_SECURITY=ldap`), web commands restricted, POST only, `cgicmd.dat` key with `authid` | `12-`, `13-` | [`rwserver_status.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/01-Run/rwserver_status.sh), smoke test `15-` | section 5, [doc 81](../09-Install/docs/81-reports_rwservlet_security.md), [reports_user_local_ldap.md](reports_user_local_ldap.md) |
| Forms | WebUtil file transfer only to the configured directories (`accessControl`), FADS only when used | `14-` | `domain_secret_check.sh` §3 | [forms_fads_app_dep_service.md](forms_fads_app_dep_service.md) |
| Java | `JDK_HOME` on the current Oracle JDK + SecureRandom fix; bundled JDK 17: Java4Shell flag `-XX:-UseBASE64Intrinsics` | `80-patch_java_os.sh`, `13-` | [`java_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/java_check.sh) | [00-patch-references.md – Java4Shell](../09-Install/docs/00-patch-references.md#java4shell--cve-2026-114938-state-2026-11-18) |
| TLS / certificates | TLS at Nginx, WebLogic demo SSL ports off, own CA / certificates, expiry watch | [`08-SSL/`](../08-SSL/README.md), `08-` | [`ssl_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/ssl_check.sh), `10-Monitoring/cert_expiry_check.sh` | [certificates_trust_stores.md](certificates_trust_stores.md) |
| Outbound connections | no calls of the domain to other hosts (external DTD trap) | `04-oracle_pre_checks.sh` | [`egress_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/egress_check.sh) | [weblogic_outbound_connections.md](weblogic_outbound_connections.md) |
| Evaluation database | Apache Derby never started (`DERBY_FLAG=false`) | `09-` | `port_check.sh --apply` | [fmw_derby_history.md](fmw_derby_history.md) |
| OS / account | firewall + sshd hardening; small blast radius of `oracle` (no `sudo`, no `dba` in production) | [`01-root_os_baseline.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/01-root_os_baseline.sh) | [`os_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/os_check.sh), `domain_secret_check.sh` §6 | [doc 00](../09-Install/docs/00-root_set_os_parameter.md), [fmw_pwd_handling.md §1b](fmw_pwd_handling.md#1b-blast-radius-of-the-domain-owner-account) |
| RCU database | schema profile (no 180-day expiry), RU out-of-place / MRP in-place | `06-db_rcu_profile.sh`, [`09-db_patch_rcu.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/09-db_patch_rcu.sh) (`--mrp`) | [`rcu_repository_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/rcu_repository_check.sh) | [rcu_middleware_architecture.md](rcu_middleware_architecture.md) |
| Patch level | the current cycle (section 2), one run per home | `07-Maintenance/80-` / `81-` / `82-` | [`cve_inventory.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/10-Monitoring/cve_inventory.sh) | [00-patch-references.md](../09-Install/docs/00-patch-references.md) |

The full hardening table of the installation (what each install step sets):
[09-Install/docs/80-oracle_security.md §4](../09-Install/docs/80-oracle_security.md).

## 4. Passwords of this library

Based on: <https://www.pipperr.de/dokuwiki/doku.php?id=dba:passwort_verschluesselt_hinterlegen>

Every secret is stored encrypted and machine-bound – `openssl des3`, key from
the disk UUID – in its own `*.des3` file in the repository root, never in
`environment.conf`, never in git (`.gitignore`). Helpers: `_write_secrets_file`
/ `load_secrets_file` / `load_weblogic_password` in the lib.

| File | Content | Written by |
|---|---|---|
| `weblogic_sec.conf.des3` | WebLogic admin | [`01-setup-interview.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/01-setup-interview.sh), [`00-Setup/weblogic_sec.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/00-Setup/weblogic_sec.sh) |
| `db_sys_sec.conf.des3` | DB SYS + RCU schema password | interview |
| `mos_sec.conf.des3` | My Oracle Support | interview, [`00-Setup/mos_sec.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/00-Setup/mos_sec.sh) |
| `reports_users.conf.des3` | `monUser`, `RepRunner` | [`12-oracle_reports_users.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/12-oracle_reports_users.sh) |
| `embedded_ldap_sec.conf.des3` | embedded LDAP `cn=Admin` (`REPORTS_SECURITY=ldap`) | interview (13- sets it in the domain) |
| `reports_admin_sec.conf.des3` | Reports server admin `<identifier>` | interview, else random by `13- --apply` |
| `test_db_sec.conf.des3` | DB user of the smoke test | `15-` (asks once) |

This is **obfuscation, not protection**: the key lies on the same machine,
like the WebLogic domain key next to every `{AES256}` value
([SECURITY.md](../SECURITY.md#password-encryption-is-obfuscation-not-protection),
[fmw_pwd_handling.md §1](fmw_pwd_handling.md#1-the-domain-key--securityserializedsysteminidat)).
The prompts for WebLogic realm users (interview, `weblogic_sec.sh`, `12-`)
check the password rule of the realm before WLST would refuse it (lib
`wls_pwd_rule_spec` / `wls_pwd_rule_fail`). Recovering / resetting a password:
[80-oracle_security.md §5](../09-Install/docs/80-oracle_security.md#5--password-recovery).

## 5. Reports invocation essentials

The Reports servlet is **unsecured by default** – anyone who reaches it can
query the server or run reports. The rules this library applies:

| Rule | Why | Where |
|---|---|---|
| secured standalone Reports server (`REPORTS_SECURITY=ldap`, default since 2026-10-16): `securityId` on the job, identity store = WebLogic embedded LDAP | the roles below only apply on a secured server; without login HTTP 499 | `13-`, [reports_user_local_ldap.md](reports_user_local_ldap.md) |
| `monUser` / `RW_MONITOR` (status only), `RepRunner` / `RW_EXECREPORTS` (report jobs), admin / `RW_ADMINISTRATOR` | separation of monitoring, execution and administration | [`12-oracle_reports_users.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/12-oracle_reports_users.sh), [doc 12](../09-Install/docs/12-weblogic-report-monitoring_user.md) |
| report jobs through the `cgicmd.dat` key `default: … %* authid=RepRunner/…` | the password never appears in the report URL | `14b-`, [fmw_pwd_handling.md §4a](fmw_pwd_handling.md#4a-cgicmddat--userid-encrypted-authid-not) |
| every web command and report request as **POST** | a GET with `authid=` / `userid=` lands in clear text in `WLS_REPORTS/logs/access.log` | `reports_server_lib.sh`, `15-` |
| `<identifier>` set, never empty; `webcommandaccess` not `L2` | empty identifier = REP-50125 restart loop; `L2` opens every web command without login, also through Nginx | `13-`, `rwserver_status.sh`, [doc 81](../09-Install/docs/81-reports_rwservlet_security.md) |
| admin web commands (`showjobs`, `killjobid`, `stopserver` …) blocked from outside | Nginx template | `04-root_nginx.sh` |
| `authid` guessing is **not** slowed by the realm lockout | the standalone server checks `authid` with an LDAP bind against the embedded LDAP | [reports_user_local_ldap.md §8](reports_user_local_ldap.md#8-account-lockout-does-not-cover-authid-test-host-2026-11-18) |

Monitoring the Reports server: [reports_monitoring_getserverinfo.md](reports_monitoring_getserverinfo.md).

## 6. Deliberate deviations and known residual risks

| Item | State | Reference |
|---|---|---|
| TLS only at Nginx, WebLogic plain HTTP on loopback | deliberate – STIG rules for SSL-only listen ports are documented as deviation | [stig_weblogic_forms_reports.md §3](stig_weblogic_forms_reports.md#3-deliberate-deviation--tls-on-every-weblogic-listen-port) |
| Reports `authid` not covered by the account lockout | open – Nginx request limit + monitoring of `REP-50171` planned | [reports_user_local_ldap.md §8](reports_user_local_ldap.md#8-account-lockout-does-not-cover-authid-test-host-2026-11-18) |
| FMW-bundled JDK 17 (Reports engines) without an Oracle patch | mitigated (Java4Shell flag), SR open | section 2 |
| OpenSSL CVE in the repository DB 19c | no 19c fix yet, not reachable without TCPS | section 2 |
| Forms & Reports 12c at customers | a STIG auditor reports "unsupported version" as CAT I | [stig_weblogic_forms_reports.md §1](stig_weblogic_forms_reports.md#1-transferable-findings--open-on-the-test-host) |
| one OS user for FMW and the local DB on lab hosts | blast radius = SYSDBA; production: own DB owner | [fmw_pwd_handling.md §1b](fmw_pwd_handling.md#1b-blast-radius-of-the-domain-owner-account) |

## 7. Checks to run

All read-only by default:

| Check | Covers |
|---|---|
| [`02-Checks/domain_secret_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/domain_secret_check.sh) | domain key, file-read paths, admin interfaces, lockout, blast radius, STIG items |
| [`02-Checks/java_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/java_check.sh) | JDKs, Log4j, Java4Shell flag |
| [`02-Checks/ssl_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/ssl_check.sh) | who terminates TLS, certificates, demo certificates |
| [`02-Checks/clone_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/clone_check.sh) | sockets by bind address (loopback) |
| [`02-Checks/egress_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/egress_check.sh) | outbound connections |
| [`01-Run/rwserver_status.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/01-Run/rwserver_status.sh) | Reports server: identifier, web command access, engines |
| [`10-Monitoring/cve_inventory.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/10-Monitoring/cve_inventory.sh) | installed patches against the configured cycle |
| [`07-Maintenance/wls_lockout_config.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/wls_lockout_config.sh) | locked users, lockout events with client address |

Customer hosts without the library: the collector
([`collect_fmw_env.sh`](../70-Customer-Projects/tools/README.md#collect_fmw_envsh))
gathers ports, certificates, Java4Shell facts and the patch level.

## 8. Reporting a vulnerability

Security problems in the scripts: privately, as described in
[SECURITY.md](../SECURITY.md).
