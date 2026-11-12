# Step 90 – 90-oracle_validate.sh

**Script:** [`09-Install/90-oracle_validate.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/90-oracle_validate.sh)
**Runs as:** `oracle` – domain started (`01-Run/startStop.sh start-all`)
**Phase:** 7 – Validation (after Phase 6, before / after 7c autostart)

```bash
./09-Install/90-oracle_validate.sh                   # all read-only checks
./09-Install/90-oracle_validate.sh --smoke           # + smoke test 15- (deploys test modules)
./09-Install/90-oracle_validate.sh --skip-db --skip-ssl
```

---

## Purpose

Acceptance of a finished installation: one run, one summary table, one exit
code – usable as the acceptance record for the customer.

Acceptance = the analyse scripts of 01–08/10 (folder roles, root README) –
the installation has no own check logic, so a check is fixed in one place
and works the same for a fresh install and an existing environment. `90-`
only calls them (all **without `--apply`**), adds a few direct checks for
what the installation steps set up and aggregates. Nothing is changed –
except with `--smoke`.

Created 2026-11-03; first run on the test host: 28 checks, 24 OK, 3 WARN
(expected: Reports engines on the bundled JDK 17, `/etc/nginx/ssl` not
readable as oracle, old failed report jobs), 0 FAIL, ~25 s.

---

## What the Script Does

### 0. Installation progress (information only)

The progress line and the next step of [`00-install-status.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/00-install-status.sh) – not counted.

### 1. Analyse scripts (read-only)

| # | Check | Script (arguments) |
|---|---|---|
| 1 | OS version, RAM, disk, ulimits | [`02-Checks/os_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/os_check.sh) |
| 2 | `JDK_HOME`, bundled JDK, JVMs of running processes | [`02-Checks/java_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/java_check.sh) |
| 3 | Ports of the domain (SSL ports only when enabled in `config.xml`) | [`02-Checks/port_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/port_check.sh) |
| 4 | SecureRandom, JVM heap | [`02-Checks/weblogic_performance.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/weblogic_performance.sh) |
| 5 | DB listener + service (no `--login`: that needs credentials saved by `db_connect_check.sh --new`, the installation never writes them – the logins are row 14) | [`02-Checks/db_connect_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/db_connect_check.sh) |
| 6 | Nginx certificate, SAN, chain, TLS versions, expiry | [`08-SSL/ssl_config.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/08-SSL/ssl_config.sh) |
| 7 | WebLogic keystores / SSL ports (demo ports off) | [`02-Checks/ssl_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/ssl_check.sh) |
| 8 | Reports server: `getserverinfo` (authid from `reports_users.conf.des3`), engines, jobs – not for `FORMS_ONLY` | [`01-Run/rwserver_status.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/01-Run/rwserver_status.sh) |
| 9 | Report engine parameters vs. Oracle rules / CPUs / RAM | [`05-ReportsPerformance/engine_perf_settings.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/05-ReportsPerformance/engine_perf_settings.sh) |
| 10 | Forms files, binaries, `FORMS_PATH`, default.env, sections – not for `REPORTS_ONLY` | [`06-FormsDiag/forms_settings.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/06-FormsDiag/forms_settings.sh) |
| 11 | Forms timeout chain, `maxRuntimeProcesses`, runtime pooling | [`06-FormsDiag/forms_perf_settings.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/06-FormsDiag/forms_perf_settings.sh) |
| 12 | `TNS_ADMIN` in every file and running process | [`02-Checks/tns_admin_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/tns_admin_check.sh) |
| 13 | Loopback-only sockets, clone-capable | [`02-Checks/clone_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/clone_check.sh) |
| 13b | Outbound connections, external DTDs | [`02-Checks/egress_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/egress_check.sh) |
| 14 | RCU repository: data source logins, invalid objects, profile | [`07-Maintenance/rcu_repository_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/07-Maintenance/rcu_repository_check.sh) |
| 15 | Certificate expiry incl. code signing, cron present | [`10-Monitoring/cert_expiry_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/10-Monitoring/cert_expiry_check.sh) |

Each step runs with a timeout (`--timeout`, default 600 s); its full output
goes to `log/<date>/validate_<time>/NN_<script>.log`, the console shows the
result and the step's own WARN / FAIL lines. Result = exit code of the
script (0 OK, 1 WARN, else / timeout FAIL).

### 2. Direct checks – what the installation steps set up

| Check | Expected | Set by |
|---|---|---|
| Node Manager type | `<nm-type>Plain` in `config.xml` | `11-` |
| Node Manager user | `<node-manager-username>` = `WLS_ADMIN_USER` | `08-` / `11-` |
| Reports security (`REPORTS_SECURITY=ldap`) | `jps-config-jse.xml` uses `idstore.ldap.embedded` | `13-` |
| Forms access log | `time-taken` in `config.xml` | `08-` / `forms_perf_settings.sh --fix-accesslog` |
| `jacob.jar` signature (`FORMS_WEBUTIL_JACOB=true`) | signed; timestamped, or without timestamp: WARN below 90 days to the signer certificate's expiry | `14-` |
| `jacob.jar` active | `WebUtilArchive` of the deployed `formsweb.cfg` contains `jacob.jar` | `14-` |
| Nginx timing log | `ihw_timing` in `/etc/nginx/conf.d/oracle-wls.conf` | [`04-root_nginx.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/04-root_nginx.sh) |
| Forms servlet | `http://localhost:9001/forms/frmservlet` → 200 | domain |
| Forms through Nginx | `https://localhost/forms/frmservlet` → 200 | Nginx |
| Config backup | at least one set in `07-Maintenance/ConfigBackup/` | `09-`, `14b-` |
| Autostart | `fmw-<domain>.service` enabled (WARN before Phase 7c) | `30-` |

### 3. Smoke test (`--smoke` only)

`09-Install/15-deploy-test-report-forms_template.sh --apply` – compiles a
Forms test module, converts and runs a test report via rwservlet (PDF) –
the only step that writes (test modules in `FORMS_CUSTOMER_DIR` /
`REPORTS_CUSTOMER_DIR`). [doc 20](20-forms_reports_testmodules.md).

### Summary

A table of every check (state, label, step log), counts, and the overall
verdict; exit code = worst state (0 OK, 1 WARN, 2 FAIL), `print_summary`
and run history as every script.

---

## Without the Script (manual)

Same order; every script without `--apply`:

```bash
./09-Install/00-install-status.sh
./02-Checks/os_check.sh
./02-Checks/java_check.sh
./02-Checks/port_check.sh
./02-Checks/weblogic_performance.sh
./02-Checks/db_connect_check.sh
./08-SSL/ssl_config.sh
./02-Checks/ssl_check.sh
./01-Run/rwserver_status.sh
./05-ReportsPerformance/engine_perf_settings.sh
./06-FormsDiag/forms_settings.sh
./06-FormsDiag/forms_perf_settings.sh
./02-Checks/tns_admin_check.sh
./02-Checks/clone_check.sh
./02-Checks/egress_check.sh
./07-Maintenance/rcu_repository_check.sh
./10-Monitoring/cert_expiry_check.sh

# direct checks
. ./environment.conf
grep -E '<nm-type>|<node-manager-username>|time-taken' $DOMAIN_HOME/config/config.xml
grep -c 'idstore.ldap.embedded' $DOMAIN_HOME/config/fmwconfig/jps-config-jse.xml
$JDK_HOME/bin/jarsigner -verify -verbose -certs $ORACLE_HOME/forms/java/jacob.jar | grep -E 'Timestamped|expire|jar verified'
grep WebUtilArchive $DOMAIN_HOME/config/fmwconfig/servers/WLS_FORMS/applications/formsapp_*/config/formsweb.cfg
grep -c ihw_timing /etc/nginx/conf.d/oracle-wls.conf
curl -s  -o /dev/null -w '%{http_code}\n' http://localhost:9001/forms/frmservlet
curl -sk -o /dev/null -w '%{http_code}\n' https://localhost/forms/frmservlet
systemctl is-enabled fmw-$(basename $DOMAIN_HOME).service

# smoke test (writes test modules)
./09-Install/15-deploy-test-report-forms_template.sh --apply
```

---

## Flags

| Flag | Description |
|---|---|
| (none) | all read-only checks |
| `--smoke` | also the smoke test `15- --apply` (deploys test modules) |
| `--skip-db` | skip DB listener and RCU repository check |
| `--skip-ssl` | skip both TLS checks and the request through Nginx |
| `--timeout N` | timeout per step in seconds (default 600) |
| `--help` | Show usage |

Unknown options: exit 1.

---

## Interpretation

| Result | Meaning |
|---|---|
| All OK | ready for production |
| WARN only | review – often acceptable (examples above) |
| Any FAIL | resolve before going live; the step log names the cause |

---

## Post-Validation

1. Phase 7b smoke test if not run with `--smoke`; Phase 7c autostart
   ([`30-configure_autostart.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/30-configure_autostart.sh)), Phase 7d client distribution.
2. Monitoring with `monUser` (`01-Run/rwserver_status.sh --auth mon`),
   certificate expiry cron (`cert_expiry_check.sh --cron --apply`).
3. Keep the summary (`log/<date>/90-oracle_validate_*.log` + step logs) as
   the acceptance record.
