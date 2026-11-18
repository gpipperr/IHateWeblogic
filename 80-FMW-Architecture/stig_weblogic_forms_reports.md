---
title: "DISA STIG for WebLogic – What It Means for Forms / Reports 14c"
description: "The DISA Oracle WebLogic Server 12c STIG (V2R2, 73 rules) read against a Forms / Reports 14.1.2 domain behind Nginx: transferable findings, what this library already does, deliberate deviations, and what does not apply."
---

# DISA STIG for WebLogic – what it means for Forms / Reports

The US Defense Information Systems Agency publishes a Security Technical
Implementation Guide for WebLogic: **Oracle WebLogic Server 12c STIG,
Version 2 Release 2, 30 January 2025** (developed by Oracle and DISA, 73
rules, XCCDF + overview). There is no STIG for 14.1.2 or for Forms /
Reports. The rules are written as click paths in the classic
Administration Console of 12c (removed in 14.1.2), but most of the
settings behind them still exist. This page reads every rule against our
architecture (TLS at Nginx, every WebLogic socket on `127.0.0.1`, Forms /
Reports on managed servers, RCU repository on the host).

Markers as in the [README](README.md): **confirmed (live)** = seen on the
test host (FMW 14.1.2, `fr_domain`, 2026-11-18), **documented** = STIG /
Oracle documentation. The STIG is DoD guidance – for other organisations it
is a well-structured checklist, not a rule. The rule texts are summarised
here in our own words; the source files are not part of the repository.

Check:
[`02-Checks/domain_secret_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/domain_secret_check.sh)
section 7 (read-only). Related: [fmw_pwd_handling.md](fmw_pwd_handling.md)
(domain key, attack paths, blast radius).

---

## 1. Transferable findings – open on the test host

| STIG | Requirement (short) | Test host 2026-11-18 | Forms / Reports aspect | Change |
|---|---|---|---|---|
| V-235933, V-235934 | auditing provider in the realm + configuration audit "Change Log and Audit" (account creation / modification, every configuration change) | was: no auditor, no `configuration-audit-type` – **since 2026-11-18 `logaudit` + `IHW_DefaultAuditor`** ([`wls_audit_config.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/wls_audit_config.sh), **confirmed (live)**: failed login recorded with the user name) | an admin login (the end point of both cases in [fmw_pwd_handling.md §1a](fmw_pwd_handling.md#1a-what-an-attacker-does-with-it--two-real-paths)) and a deployment leave no trail in the domain without it | **done** (step 1) |
| V-235931, V-235935, V-235939 | OPSS audit policy with every event, privileged users always audited | was `audit.filterPreset=None` – **since 2026-11-18 `Low`** (instance `audit.db` of the default context) | `Low` = OPSS management events only (credentials, keystores, policies, roles – `audit-store.xml`), no logins (those are in the DefaultAuditor log). The IAU schemas and `opss-audit-DBDS` exist from RCU; the events land in `servers/<srv>/logs/auditlogs/JPS/` – **open:** the loader wrote nothing into `DEV_IAU` yet ([rcu_middleware_architecture.md](rcu_middleware_architecture.md)) | **done** (step 1), DB load open |
| V-235966 – V-235970 | password rule of the domain: 15 characters, ≥1 upper, lower, digit, special | was `SystemPasswordValidator` 8 / 1 digit-or-special – **since 2026-11-18: 12 characters, upper + lower case, digit, special character, not containing the user name** ([`wls_password_rule.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/wls_password_rule.sh); **confirmed (live)**: a test user with `weak1234` rejected with Security:099069/078/079, a strong password accepted, active without restart) | the rule of the **realm** – it applies to the admin, `RepRunner`, `monUser` and the Reports users whenever a password is **set**; existing passwords keep working. The prompts of the library (interview, `weblogic_sec.sh`, `12-`) check it (lib `wls_pwd_rule_fail`). 12 instead of the STIG's 15 – decision 2026-11-18 | **done** (step 2, length 12) |
| V-235936 – V-235938 | lockout 3 failed logins, 15 min lock, 15 min reset | WebLogic default 5 / 30 / 5 | **service users share the realm:** `RepRunner` (`authid` in `cgicmd.dat`) and `monUser` can be locked by anybody who guesses against them – Reports jobs then fail. A stricter lockout raises that risk; long passwords for service users and an alert on lockout messages belong to it | open – only together with service-user protection |
| V-235947, V-235949 | audit records with the source (client) and the user | `access.log` of WLS_FORMS / WLS_REPORTS without `c-ip` / `cs-username` (elf fields of `08-`) | behind Nginx the client of WebLogic is `127.0.0.1` anyway – the **Nginx access log** is the record with the client IP; correlate via ECID (`ctx-ecid`). Rule: keep the Nginx access log (rotation / retention) as the audit source | documentation |
| V-270883 (CAT I) | the WebLogic version must be supported – "12c is no longer supported" | 14.1.2 | the customers on F&R **12.2.1.19** (WebLogic 12.2.1.4): an auditor working with this STIG reports a **CAT I** finding – one more argument for 14c. The actual support date is in Oracle's Lifetime Support Policy (not checked here) | – |
| Overview 2.1.2 | `umask 027` for the installation user | `.bash_profile` of `oracle` (written by `03-root_user_oracle.sh`) has `umask 0022`; the WebLogic start scripts set 027 themselves (domain files 640) | files created by our scripts (logs, report directories, exports) are world-readable. A global 027 would break files Nginx must read as user `nginx` (Forms client bundle `/formsWeb`) – change selectively | open – evaluate |

## 2. Already met by this library

| STIG | Requirement | How |
|---|---|---|
| V-235963, V-235986, V-235988 | production mode | `08-oracle_setup_domain.sh` (`production-mode-enabled=true`, **confirmed (live)**) |
| V-235961 | JSP page check `-1` (no reload) | default of production mode for Oracle's applications |
| V-235983 | no applications on the AdminServer | only EM, OPSS REST, DMS and resource adapters on the AdminServer; `formsapp` / `reports` on `cluster_forms` / `cluster_reports` (**confirmed (live)**, check section 7) |
| V-235932, V-235962 | only approved ports / protocols | every WebLogic, Node Manager, Reports ORB and Coherence socket on `127.0.0.1`, SSL demo ports off ([clone_golden_image.md](clone_golden_image.md)); `clone_check.sh`, `domain_secret_check.sh` §4 |
| V-235936 (basic) | lockout active | WebLogic default on; `domain_secret_check.sh` §5 FAILs on `lockout-enabled=false` |
| V-235954 | audit time stamps in UTC | `audit.timezone=utc` in `jps-config.xml` (**confirmed (live)**) |
| V-235994 | no sensitive data in errors / logs | passwords never on command lines, `ihwt_mask` in every collection; Reports web commands restricted ([doc 81](../09-Install/docs/81-reports_rwservlet_security.md)) |
| V-235999 | multi-factor via an access manager | OAM WebGate in front of Forms where the customer runs OAM SSO (collector `43_ohs.txt`) – not part of the base install |

## 3. Deliberate deviation – TLS on every WebLogic listen port

About a third of the rules (V-235928/29, V-235971–73, V-235977/78,
V-235980, V-235984, V-235987, V-235991/92) check the same thing: plain
listen port **off**, SSL listen port **on**, own identity / trust keystores,
for every server. This library does the opposite on purpose:

```
 client --TLS--> Nginx :443 --HTTP--> 127.0.0.1:9001 / 9002 / 7001 (WebLogic)
                                      127.0.0.1:5556 (Node Manager), Reports ORB, Coherence
```

- TLS ends at Nginx (one certificate, one place for protocols / ciphers –
  `08-SSL/ssl_config.sh`); the WebLogic SSL ports stay off (the demo
  certificate would be the alternative).
- Plain traffic only on loopback: reading it needs root on the host, and
  root reads the domain key anyway ([fmw_pwd_handling.md §1](fmw_pwd_handling.md#1-the-domain-key--securityserializedsysteminidat)).
- Compensating controls: loopback binding (checked), Nginx admin locations
  only from `ADMIN_IP_RANGE`, host firewall, no remote T3 / IIOP.

An auditor using the STIG will still list these rules – document the
deviation with this rationale. Where WebLogic must be reached by other
hosts (cluster over several machines, remote Node Manager), the STIG rule
applies in full: SSL listen ports with own keystores
([certificates_trust_stores.md](certificates_trust_stores.md)).

## 4. Not applicable or covered elsewhere

| STIG | Why |
|---|---|
| V-235975, V-235976, V-235981 (FIPS 140-2, NSA crypto) | DoD requirement (RSA Crypto-J FIPS jars); not a general hardening item |
| V-235951 – V-235953, V-235996, V-235997 (WLDF watch + e-mail on health / audit failure) | covered by `10-Monitoring` (outside WebLogic) |
| V-235979, V-235985 (session timeout 900 s) | Forms has its own timeout chain (`heartBeat`, `FORMS_TIMEOUT` 15 min, `formsapp` `timeout-secs` 7200 s – [forms_runtime_architecture.md §4](forms_runtime_architecture.md#4-timeout-chain)); an idle logout of the user is a matter of the application. Documented, not changed |
| V-235982 (clustering), V-235989 (max in-memory sessions), V-235990 (work managers) | sizing / availability topics |
| V-235998 (central enterprise tool) | organisational |
| V-235956 – V-235960, V-235995 (who is Admin / Deployer / Monitor / Operator) | relevant, but not readable offline: `RepRunner`, `monUser` and the Reports users must not be in `Administrators` or `Deployers` (a deployer can deploy code = admin). Check with WLST (read-only) – open |

## 5. Order of the open changes

Each one separately, on the test host first, with `--apply` and a backup:

1. **Configuration audit + OPSS audit** (`logaudit`, auditing provider,
   `filterPreset` Low / Medium) – small effort, closes the "no trail" gap.
   **Done 2026-11-18** on the test host:
   [`07-Maintenance/wls_audit_config.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/wls_audit_config.sh)
   ([07-Maintenance README](../07-Maintenance/README.md#wls_audit_configsh)).
2. **Password rule of the domain** (12–15 characters) – agree first; it
   applies to every realm user at the next password change. **Done
   2026-11-18** with 12 characters:
   [`07-Maintenance/wls_password_rule.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/wls_password_rule.sh)
   ([07-Maintenance README](../07-Maintenance/README.md#wls_password_rulesh)).
3. **Lockout 3 / 15 / 15** – only together with long service-user passwords
   and an alert on lockouts (`RepRunner`, `monUser`).

## 6. Sources

- DISA, *Oracle WebLogic Server 12c Security Technical Implementation Guide*,
  V2R2, 30 January 2025 (XCCDF manual STIG + overview), DoD Cyber Exchange:
  <https://public.cyber.mil/stigs/downloads/>.
- Test host inventory 2026-11-18: `config.xml` (password validator, lockout,
  audit, deployments, `web-server-log`), `jps-config.xml` (`audit.*`),
  `.bash_profile` of `oracle`; check output of `domain_secret_check.sh`.
