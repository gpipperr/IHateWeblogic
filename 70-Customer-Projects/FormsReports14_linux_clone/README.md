# Forms & Reports 14.1.2 – clone a domain with its VM, own RCU prefix ("way 3")

Anonymised knowledge base from a customer run on 2026-11-10: a Reports-only
14.1.2 domain (AdminServer + `WLS_REPORTS` + standalone Reports server
`repserver01`) is cloned together with its VM. The clone gets a **new RCU
prefix in another database**, and OPSS is moved there with the WLST command
`reassociateSecurityStore`. The cookbook is plain text with commands to type
along with; this README explains what each step changes and why.

| File | Content |
|---|---|
| [Clone_cookbook_en.txt](Clone_cookbook_en.txt) | Step-by-step cookbook (English, bash, ASCII). Part A on the source, Part B on the clone, ROLLBACK, KNOWN PROBLEMS |
| README.md | This file – background, what changes where, open points |

Theory (not repeated here):
[clone_golden_image.md](../../80-FMW-Architecture/clone_golden_image.md)
§3 (host-name places), §5 (RCU, the three ways, ASCII flow of way 3, test
results), §6 (recipe), §8 (sources);
[rcu_middleware_architecture.md](../../80-FMW-Architecture/rcu_middleware_architecture.md)
§3 / §3.1 (who logs in where, sessions table);
[reports_job_handling.md](../../80-FMW-Architecture/reports_job_handling.md)
§6 / §8 (scheduled jobs, `.dat`, `showjobs`).

Tested: customer run 2026-11-10 (Reports only, new prefix in **another** RCU
database) and a test-host run of way 3 in the **same** database (prefix
`DEV` → `CLN`, start, smoke test, way back). Both are documented in
clone_golden_image.md §5.

---

## 1. When to use way 3 – and when way 1

With an **external** RCU database the domain is bound to one prefix: the
data sources and the OPSS bootstrap point to it, and OPSS holds policies,
credentials and keys in the database. A clone must **never** run against the
prefix of the source. Two domains in one OPSS store are not allowed
(clone_golden_image.md §5).

| Way | Idea | Use when |
|---|---|---|
| 1 – image without domain (recommended) | golden image holds OS, homes, JDK; per clone: RCU new prefix + new domain | you build images in advance; every piece is a supported script path |
| 2 – copy the repository (Data Pump) | re-bind the clone to an imported copy | untested, many places – avoid |
| **3 – clone the domain, new prefix, `reassociateSecurityStore`** | domain is cloned with the VM; the clone moves its OPSS into a new prefix before the managed servers start | an existing, configured domain shall be duplicated (dev → test, new production) and rebuilding it is more work than the move |

Way 3 is not described as a procedure by Oracle. The single commands
(`reassociateSecurityStore`, `updateCred`, offline data source changes) are
documented; the order and the leftovers come from our two test runs.

## 2. Prerequisites

- **Source hardened to localhost:** AdminServer, managed servers, Node
  Manager, Reports server and engines on `127.0.0.1`. See the sibling folder
  [../FormsReports14_linux_localhost/README.md](../FormsReports14_linux_localhost/README.md).
  The hardening is what makes the clone's host name matter in only a few
  places (Nginx, certificate, mail sender, multicast port, tools ini).
- **Autostart off on the source before the VM clone** (cookbook step 1).
  Otherwise the clone boots and starts against the source prefix.
- **Both databases reachable from the clone during the reassociation**
  (steps 7/8): the old one (read the source OPSS store) and the new one
  (write). From step 9 on, only the new one is needed.
- DBA with SYS for the new database (RCU, 19c+, AL32UTF8).
- `clone_check_fmw.sh` **2026-11-10.8** or newer in the tools directory.

## 3. Flow

The ASCII flow (source host A, clone host B, RCU databases) is in
[clone_golden_image.md §5, way 3](../../80-FMW-Architecture/clone_golden_image.md#5-the-rcu-repository--where-it-lives-decides).
Cookbook steps in short:

| Step | Where | What |
|---|---|---|
| 1–3 | source | autostart off, clone check, stop, VM clone, autostart on, start |
| 4 | clone, root | host name, IP, `/etc/hosts`, machine-id, ssh host keys |
| 5 | clone | backup `config/`, `<server>.dat` aside, **5.1** `ADMIN_URL`, **5.2** `AdminURL`, **5.3** loopback leftovers (check) |
| 6 | clone + DBA | RCU `-createRepository` with the new prefix (same components) |
| 7 | clone | start the AdminServer **only** (still on the source OPSS, read) |
| 8 | clone, WLST online | new OPSS data source, `reassociateSecurityStore`, `updateCred` |
| 9 | clone, WLST offline | stop with `ADMIN_URL=t3://localhost:7001`, other data sources (user, password, URL), `audit.loader.jdbc.string` |
| 10 | clone | multicast port, mail sender, Nginx + certificate, firewall, tools `patch_install.ini`, crontab |
| 11–12 | clone (+ source) | start all, autostart on, checks: logs, EM, `clone_check_fmw.sh`, `v$session` on both DBs, `showjobs` |

## 4. What changes where

### 4.1 `reassociateSecurityStore` (step 8)

Run online against the AdminServer of the clone, after a new data source
`opss-data-source-<newprefix>` (JNDI `jdbc/OpssDataSource<NEWPREFIX>`, user
`<NEWPREFIX>_OPSS`, URL of the **new** DB, targets AdminServer +
`cluster_reports`) was created in the same WLST script.

It **does**:

- copy policies, credentials, keys and the audit configuration from the
  source store into `<NEWPREFIX>_OPSS` ("Policy / Credential / Keystore /
  Audit store reassociation done");
- rewrite `jps-config.xml` (`datasource.jndi.name` → the new JNDI) and the
  `jdbc.url` of `props.db.1` in `jps-config-jse.xml` (used by the
  standalone Reports server, which reads OPSS directly over JDBC);
- write a new bootstrap key (bootstrap wallet);
- change the farm name from `cn=opssSecurityStore` to `cn=<domain>`.

It does **not**:

- rewrite `audit.loader.jdbc.string` of the `audit.db` instance in
  `jps-config-jse.xml` (Java SE audit loader of the standalone Reports
  server). After a move to **another** DB it still names the old DB
  (customer, confirmed). Cookbook step 9.5 copies the `jdbc.url` value into
  it with the domain stopped. On the test host (same DB) the line was the
  same but went unnoticed.
- change the credential `AuditDbPrincipalMap` / `AuditDbPrincipalKey`. It is
  copied with the **old** `<OLDPREFIX>_IAU_APPEND` user. Step 8.4 sets it to
  `<NEWPREFIX>_IAU_APPEND` with `updateCred` while the AdminServer runs.
  **The result of `updateCred` at the customer is still pending.**

The offline alternative `migrateSecurityStore` fails with `JPS-01013 … the
target DN must be pre-configured`: a fresh RCU schema has no OPSS root, and
14.1.2 has no offline tool to create one (clone_golden_image.md §5).

### 4.2 Offline data sources (step 9)

WLST offline (`readDomain` → `updateDomain`). For each data source, under
`/JDBCSystemResource/<ds>/JdbcResource/<ds>/JDBCDriverParams/NO_NAME_0`:

- `URL` – only needed when the new prefix lives in another DB (the cookbook
  always sets it);
- `PasswordEncrypted` – the password of the new schemas;
- `Properties/NO_NAME_0/Property/user` `Value` → `<NEWPREFIX>_<suffix>`.

Side effect (known, harmless): `updateDomain` drops elements with default
values from `config.xml`, e.g. `<enabled>false</enabled>` of the managed
server SSL. SSL stays off, because that is the default.

### 4.3 Data sources and their targets (Reports-only domain)

| Data source | Schema | Target | Sessions |
|---|---|---|---|
| `opss-data-source` (old, re-pointed) and `opss-data-source-<newprefix>` (new) | `_OPSS` | AdminServer, `cluster_reports` | yes |
| `opss-audit-DBDS` | `_IAU_APPEND` | AdminServer, cluster | yes |
| `opss-audit-viewDS` | `_IAU_VIEWER` | AdminServer, cluster | yes |
| `LocalSvcTblDataSource` | `_STB` | **AdminServer only** | 0–1 (pool starts with 0) |
| `WLSSchemaDataSource` | `_WLS` | **none** | never |
| `WLSRuntimeSchemaDataSource` | `_WLS_RUNTIME` | **none** | never |
| (standalone Reports server, Java SE) | `_OPSS` via `jdbc.url`, `_IAU_APPEND` via `audit.loader.jdbc.string` | – | `JDBC Thin Client` |

After step 9 all seven `config/jdbc/*.xml` files must carry the new prefix
and the URL of the new DB (check in cookbook step 9.4).

### 4.4 `stopWebLogic.sh` and `ADMIN_URL` – the dangerous one (step 5.1)

The Configuration Wizard writes `ADMIN_URL="t3://<host>:7001"` into
`$DOMAIN_HOME/bin/stopWebLogic.sh` (and possibly `startManagedWebLogic.sh`).
On the clone this is the **source**. With `boot.properties` and an open
network, `stopWebLogic.sh` on the clone **stops the source AdminServer**. At
the customer only "No route to host" prevented it.

- Change it to `t3://localhost:7001` **before any start / stop on the
  clone** (step 5.1). Also check an `ADMIN_URL` exported in the oracle
  profile.
- Until then, and as a habit during the move:
  `ADMIN_URL=t3://localhost:7001 $DOMAIN_HOME/bin/stopWebLogic.sh`. The
  script only uses its own value when `ADMIN_URL` is empty.

### 4.5 `startup.properties` `AdminURL` (step 5.2)

`$DOMAIN_HOME/servers/<ms>/data/nodemanager/startup.properties` holds the
AdminServer address of the **last start through the AdminServer**. The Node
Manager passes it when it starts the managed server directly (autostart).
On the clone it names the source IP. The managed server then looks for the
source, or runs in *Managed Server independence mode*: EM shows the server,
`cluster_reports` and the `reports` deployment red, the AdminServer logs only
`BEA-149505`, while `status.sh` shows everything RUNNING. The customer had
this on the source too, because the loopback hardening does not rewrite the
file. Fix: `AdminURL=http\://localhost\:7001`, before the first start.

### 4.6 Loopback leftovers that come along (step 5.3)

If the source was hardened with
`../FormsReports14_linux_localhost/Localhost_cookbook_en.txt`, these are
already correct and step 5.3 only checks them:

- **Engine `jvmOptions`** in `rwserver.conf` (`<engine id="rwEng" …
  jvmOptions="…">`) **replace** the `REPORTS_JVM_OPTIONS` inherited from
  `reports.sh`. The engines then bind to `0.0.0.0`. Add
  `-DORBWaitForResponseTimeout=999999999
  -Dcom.sun.corba.ee.ORBServerHost=127.0.0.1`.
- **EM `emoms.properties`**: EM copies
  `servers/AdminServer/tmp/_WL_user/em/<id>/META-INF/emoms.properties` over
  `config/fmwconfig/servers/AdminServer/applications/em/META-INF/emoms.properties`
  and `.jmxori` at every AdminServer start. Change all three
  (`ConsoleServerHost` / `ConsoleServerName` → `localhost`), and check again
  after an EM patch or redeploy.

### 4.7 Scheduled jobs (`.dat`, step 5 and 12.2)

Jobs submitted with `SCHEDULE=` live in
`$DOMAIN_HOME/reports/server/<server>.dat` (without a
`<jobStatusRepository>`). The clone would run them a second time (same
files, FTP targets, mails). So the `.dat` is moved aside before the first
start and never copied back. Check after the start with `showjobs
queuetype=future`: 0 on the clone, the unchanged job list on the source.
Jobs for the clone are scheduled new, preferably with cron + `rwclient` and
their own targets.

### 4.8 Tools `patch_install.ini` and crontab (step 10.5 / 10.6)

- `$TOOLS/patch_install.ini` comes along with the source values
  (`WLS_SERVER_FQDN`, `SSL_CN`, `DB_HOST/PORT/SERVICE`, `DB_SCHEMA_PREFIX`,
  `REPORTS_BROADCAST_PORT`). Move it aside, run `make_patch_install_ini.sh`
  (shows) and then `--apply` (writes, never overwrites), and carry over
  hand-made entries from a `diff`.
- The crontabs of oracle and root and `/etc/cron.d` come along. Comment out
  what must not run on the clone.

## 5. Expected RCU sessions after the full start

`v$session` on the **new** DB, grouped by user and machine (cookbook step
12.1). Example Reports-only domain (customer run 2026-11-10, AdminServer +
`WLS_REPORTS` + standalone Reports server), `machine` = the clone:

| User | Sessions | From |
|---|---|---|
| `<NEWPREFIX>_OPSS` | 6 | 5 × program `SERVER` (data sources) + 1 × `JDBC Thin Client` (standalone Reports server via `jdbc.url`, inferred from the timing) |
| `<NEWPREFIX>_IAU_APPEND` | 2 | `opss-audit-DBDS`, one per server |
| `<NEWPREFIX>_IAU_VIEWER` | 2 | `opss-audit-viewDS`, one per server |
| `<NEWPREFIX>_STB` | 1 | `LocalSvcTblDataSource`, AdminServer |
| `_WLS`, `_WLS_RUNTIME`, `_IAU` | none | no target / owner schema |

The numbers depend on the pools (the test host with Forms has 3 servers:
OPSS 10, IAU_APPEND 3, IAU_VIEWER 3, STB 1). What matters is which schemas
appear. On the **old** DB there must be **no** session from the clone's
machine.

## 6. Rollback

- **Source:** only the autostart was switched off and on. The source prefix
  is only read, so there is nothing to undo.
- **Clone, error in step 8 or 9:** stop the AdminServer (with
  `ADMIN_URL=t3://localhost:7001`), move `config/` aside, restore
  `config_<time>.tgz` from step 5. The clone then points to the **source**
  prefix again and must **not** be started. Start again from step 7, or
  discard the clone. The test host did this successfully (only `DEV_*`
  sessions afterwards, smoke test OK).
- **New prefix:** `rcu -dropRepository` by the DBA, only when the clone is
  discarded.

## 7. Still open

- Result of `updateCred` (`AuditDbPrincipalKey` → new `_IAU_APPEND`) at the
  customer.
- Whether the standalone Reports server writes audit rows at all with
  `audit.filterPreset=None`. This decides how much the audit loader URL and
  credential matter in practice.
- EM login by form after the move (only EM HTTP 302 checked).
- `reassociateSecurityStore` and `updateCred` are marked "interactive mode
  only" by Oracle. They ran from a WLST script on the test host and at the
  customer, but that is not a supported guarantee.

## 8. Check scripts

- Repository: [`02-Checks/clone_check.sh`](../../02-Checks/clone_check.sh).
- Customer hosts (standalone, read-only):
  [`tools/bash/clone_check_fmw.sh`](../tools/bash/clone_check_fmw.sh),
  version **2026-11-10.8**: `ADMIN_URL` in `bin/*.sh` (2026-11-10.2),
  `startup.properties` `AdminURL` (.3), engine `jvmOptions` without
  `ORBServerHost` and the EM `tmp/` copy of `emoms.properties` (.8). Use
  `--config` to see the file and the lines under each finding. Description:
  [tools/README.md](../tools/README.md#clone_check_fmwsh).
