---
title: "Oracle Reports 14c Job Queue in the Database"
description: "Oracle Reports 14.1.2 job status repository: the Reports Server job queue as table RW_SERVER_JOB_QUEUE - setup, rights, csf key, queries, pitfalls, tested."
---

# Reports Server job queue monitoring – `jobStatusRepository`

The Reports Server keeps its job queues in a binary file (`<server>.dat`).
With the `jobStatusRepository` element it **also** writes every job into a
database table, `RW_SERVER_JOB_QUEUE`. Monitoring, own queue reports and
"how many jobs failed today?" then become plain SQL.

This page explains how it works, how it is set up on Oracle Reports 14.1.2
(tested on the test host on 2026-11-17), what changed against the old
descriptions and what to watch out for.

> Thanks to Jürgen for his setup notes from a customer project, which this
> page started from.

**Related:** job model, scheduled jobs and `.dat` persistence:
[reports_job_handling.md](reports_job_handling.md); queue counters over
HTTP: [reports_monitoring_getserverinfo.md](reports_monitoring_getserverinfo.md).

---

## 1. Three ways to keep job information – which one is this?

| Element in `rwserver.conf` | Where | Purpose | Leading? |
|---|---|---|---|
| `persistFile` (default `<server>.dat`) | file in `$DOMAIN_HOME/reports/server/` | the server restores its queues (scheduled, current, past) after a restart | **yes** – always there |
| **`jobStatusRepository`** | DB table `RW_SERVER_JOB_QUEUE` | a **copy** of the job status for applications and monitoring | no – read-only copy |
| `jobRepository` | DB table `RW_JOBS` (BLOB) | all job data in the DB instead of the `.dat`, needed for high availability (several Reports servers share the jobs) | replaces the `.dat` |

Oracle: the `persistFile` "is a binary file and, therefore, cannot be used to
publish job status information within your application. The
`jobStatusRepository` element provides a means of including status
information in your application"
([Reports 12.2.1.3, 7.2.1.11 jobStatusRepository](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_conf002.htm)).

The script header of `rw_server.sql` says the same in other words: "This is a
read-only copy of the Report Server job queue (i.e. manually inserting a row
in the table will not submit a job)." Submitting jobs from the database is a
different feature (Event-Based Publishing API).

This page is about the `jobStatusRepository` only.

## 2. How it works

```
 rwservlet / rwclient / scheduled run
              |
              v
   Reports Server (repserver01)
     |                     |
     | queues              | JDBC as dbuser, password from the
     v                     | credential store (csf:reports:<key>)
   <server>.dat            v
   (leading)       package RW_SERVER.insert_job / remove_job
                           |
                           v
                   table RW_SERVER_JOB_QUEUE   <- monitoring, own reports
```

- **Who writes:** the Reports Server process itself, through the package
  `RW_SERVER` in the repository schema. WebLogic (`WLS_REPORTS`) is not
  involved, so no data source is needed.
- **When (live 2026-11-17):**
  - one row per job when it ends (`Past`);
  - one row per scheduled parent job (`Scheduled`, with `NEXT_RUN`); every
    scheduled run is its own `Past` row with a new job id; when the schedule
    expires the parent row becomes `Past` with status 15 (EXPIRED).
- **The table mirrors the past queue:** a job that leaves the in-memory past
  queue (`<queue maxQueueSize>`, default 1000, library 4000) is deleted from
  the table too (`RW_SERVER.remove_job`). With `maxQueueSize="100"` and 112
  new jobs exactly the newest 100 rows stayed. The table is therefore **no
  long-term history** – see 5.3.
- **Not back-filled:** jobs that were already in the `.dat` before the element
  was activated do not appear in the table.
- **Which `rwserver.conf`:**
  - standalone Reports server:
    `$DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent/<server>/rwserver.conf`;
  - in-process server:
    `$DOMAIN_HOME/config/fmwconfig/servers/WLS_REPORTS/applications/reports_<version>/configuration/rwserver.conf`
    ([Reports 12.2.1.2, 24.3.6.1](https://docs.oracle.com/middleware/12212/formsandreports/use-reports/pbr_tune003.htm)).

## 3. Setup on Oracle Reports 14.1.2 (tested)

There are no separate Reports books for 14.1.2; the 14.1.2 library links the
12.2.1.3 Reports books. They describe the element exactly as 11g did. The
script is in the 14c home:
`$ORACLE_HOME/reports/admin/sql/rw_server.sql` (last fix 2020, bug 22846976)
plus `rw_job_repos.sql`, which it calls.

How stable the whole thing is shows the header of the script that still
ships with 14.1.2:

```
REM Version
REM -------
REM 9.0.4.0.0
...
REM  26-Mar-99 P Narth   Created
...
REM  Note: This script is only certified to work against Oracle RDBMS 8.1.7 or
REM  later
```

Created in March 1999, "certified" for Oracle 8i – and it ran unchanged
against a 19c PDB on the test host. "8.1.7 or later" has simply become a very
long "later".

### 3.1 Database user with minimal rights

```sql
CREATE USER RW_JOBQ IDENTIFIED BY "<PASSWORD>"
  DEFAULT TABLESPACE USERS TEMPORARY TABLESPACE TEMP;

GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE PROCEDURE,
      CREATE SEQUENCE, CREATE TRIGGER TO RW_JOBQ;

ALTER USER RW_JOBQ QUOTA 1G ON USERS;
```

| Right | Needed for |
|---|---|
| `CREATE SESSION` | the Reports Server logs in |
| `CREATE TABLE` | `RW_SERVER_JOB_QUEUE`, `RW_JOBS` |
| `CREATE VIEW` | `RW_SERVER_QUEUE` (Reports 6i compatibility view) |
| `CREATE PROCEDURE` | package `RW_SERVER` |
| `CREATE SEQUENCE` | `REPORTS_JOBS` (from `rw_job_repos.sql`) |
| `CREATE TRIGGER` | `RW_ID` on `RW_JOBS` (from `rw_job_repos.sql`) |
| quota | the table grows with every job (CLOB columns) |

Not needed: `CREATE ANY TRIGGER` (a system-wide right – triggers in every
schema) and the old `RESOURCE` role of the snapdba article. Missing
`CREATE SEQUENCE` / `CREATE TRIGGER` lets `rw_job_repos.sql` fail; the job
status table itself would still work.

Live 2026-11-17: exactly these six rights, the script created 16 objects, all
`VALID` – table `RW_SERVER_JOB_QUEUE`, view `RW_SERVER_QUEUE`, package
`RW_SERVER`, sequence `REPORTS_JOBS`, table `RW_JOBS`, trigger `RW_ID`, plus
LOB segments and indexes.

### 3.2 Run `rw_server.sql` as that user

```bash
cd $ORACLE_HOME/reports/admin/sql

sqlplus RW_JOBQ@//<db-host>:1521/<service>
SQL> @rw_server.sql
```

- **On a first run** two errors are expected and harmless: `ORA-00942: table or
  view does not exist` and `ORA-02289: sequence does not exist` – the
  `DROP` statements of `rw_job_repos.sql` before the `CREATE`.
- **The script starts by dropping** `RW_SERVER_QUEUE`, `RW_SERVER_JOB_QUEUE`
  (and `RW_JOBS`, `REPORTS_JOBS`). Running it again in production **deletes
  the whole job history.** Run it once; after a Reports patch compare the
  script with the installed objects instead of running it again.

### 3.3 Password into the credential store (csf)

The password never goes into `rwserver.conf`; the element references a key of
the credential store map `reports`.

WLST (password read from the environment, not typed into the script):

```python
import os
e = os.environ
connect(e['_IHW_WL_USER'], e['_IHW_WL_PASS'], 't3://localhost:7001')
createCred(map='reports', key='jobq_repository', user='RW_JOBQ',
           password=e['_IHW_DB_PWD'], desc='Reports job status repository')
```

The three values are set as environment variables of the `wlst.sh` call
(read hidden with `read -s` before), so they appear neither in the script nor
in the process list.

Fusion Middleware Control instead: *WebLogic Domain → Security →
Credentials*:
1. *Create Map* `reports` (only if it is not there yet);
2. select the map → *Create Key*: key name (e.g. `reports_repository`), type
   *Password*, user name and password of the **DB user**, a description.

Either way the reference is `csf:reports:<key>`. Done this way at a customer
on 14.1.2 (2026-11-17): after the restart the Reports server ran and the
table filled.

**Watch the browser:** in the *Create Key* dialog the browser offered the
saved login of Fusion Middleware Control and filled in `weblogic` and its
password – the key must hold the DB user. Check the user name before *OK*,
or switch off password autofill for the console.

### 3.4 `rwserver.conf`

```xml
   <jobStatusRepository class="oracle.reports.server.JobRepositoryDB">
      <property name="dbuser" value="RW_JOBQ"/>
      <property name="dbpassword" value="csf:reports:jobq_repository"/>
      <property name="dbconn" value="<db-host>:1521/<service>"/>
   </jobStatusRepository>
```

- **Position:** `rwserverconf.xsd` of the 14c home
  (`$ORACLE_HOME/reports/dtd/`) fixes the order inside `<server>`: … `job`,
  `notification`, `log`, **`jobStatusRepository`**, `jobRepository`,
  `connection`, `ORBPorts`, `queue`, `folderAccess`, `persistFile`,
  `identifier`. Put it after the last `notification` / `log` and before
  `connection`. The library's template (`13-oracle_setup_reports.sh`) already
  has a commented block in exactly that place.
  - **Not enforced at the start (live 2026-11-17):** with the element as the
    last child of `<server>` (after `pluginParam`, as written by hand at a
    customer) the Reports server started and wrote its rows; a `connection`
    element moved behind `pluginParam` was accepted as well. Oracle still
    says the order of `rwserverconf.xsd` "must" be followed – keep it, so
    that a validating tool, Fusion Middleware Control or a later patch does
    not stumble over the file.
- **`dbconn`:** live 2026-11-17 `host:port/service` worked against a PDB
  service. The old form `host:port:SID` only fits a database reachable by
  SID (no PDB).
- **Property names:** `dbuser`, `dbpassword`, `dbconn`. Older pages and one
  sentence of the 12.2.1.3 book still mention `repositoryconn`; the
  12.2.1.3 example and the note "Oracle Reports uses the `dbconn` property"
  use `dbconn` – that is what works.
- **Copying Oracle's example fails:** `value=csf:reports:"<dbkey>"` in the
  book is not well-formed XML. Quote the whole value as above.

Restart the Reports server (a standalone server: `stopComponent.sh` /
`startComponent.sh <server>`, or Fusion Middleware Control). The setting is
read at the start.

### 3.5 Check

```sql
SELECT job_queue, job_id, job_name, status_code, owner, server,
       queued, finished, run_elapse
  FROM rw_server_job_queue
 ORDER BY job_id;
```

Live 2026-11-17 after two good reports, a failing one and a scheduled one:

```
JOB_QUEUE  JOB_ID JOB_NAME     STATUS_CODE OWNER      SERVER       RUN_ELAPSE
Past          124 ihw_ok_1               4 RepRunner  repserver01         276
Past          125 ihw_ok_2               4 RepRunner  repserver01          48
Past          126 ihw_fail_1             5 RepRunner  repserver01           9
Scheduled     128 ihw_sched_1            1 ...        repserver01
Past          129 ihw_sched_1            4 ...        repserver01
```

Two minutes later, after the second scheduled run and the expiry
(`schedule=every_2_minutes_from_now_expires_after_2`): parent 128 is `Past`
with status 15, runs 129 and 130 are `Past` with status 4.

- `OWNER` is the authenticated Reports user (on a secured server the user of
  `authid`, here `RepRunner` from the `cmdkey`), not the DB user of the
  report.
- `RW_JOBS` stays empty – it belongs to the `jobRepository`, which is not
  configured.

## 4. The table and the status codes

Columns and codes as documented in
[Reports 12.2.1.2, 24.3.6 RW_SERVER_JOB_QUEUE Table](https://docs.oracle.com/middleware/12212/formsandreports/use-reports/pbr_tune003.htm)
(shortened):

| Column | Content |
|---|---|
| `JOB_QUEUE` | `Current`, `Past` or `Scheduled` |
| `JOB_ID` | job id of the Reports server |
| `JOB_TYPE` | `report`, `rwurl` … (job types of `rwserver.conf`) |
| `JOB_NAME` | `jobname=` of the request, else the file name |
| `STATUS_CODE` / `STATUS_MESSAGE` | status, full message incl. the REP error |
| `COMMAND_LINE` | the complete request (CLOB) |
| `OWNER` | user who submitted the job |
| `DESTYPE` / `DESNAME` | destination |
| `SERVER` | Reports server name |
| `QUEUED` / `STARTED` / `FINISHED` | times |
| `RUN_ELAPSE` / `TOTAL_ELAPSE` | run time / time since queued, in ms |
| `LAST_RUN` / `NEXT_RUN` / `REPEAT_INTERVAL` / `REPEAT_PATTERN` | scheduled jobs |
| `CACHE_KEY` / `CACHE_HIT` | result cache |

| Code | Meaning |
|---|---|
| 1 | ENQUEUED – waiting |
| 2 | OPENING (named in Oracle's query, not in the table) |
| 3 | RUNNING |
| 4 | FINISHED – successful |
| 5 | TERMINATED_W_ERR – error |
| 7 | CANCELED |
| 8 | SERVER_SHUTDOWN – cancelled by a shutdown |
| 12 | VOID_FINISHED – output void, cache full |
| 13 | ERROR_FINISHED – output made, delivery failed |
| 15 | EXPIRED – scheduled job expired |

Oracle's note: "If a report ends due to an unexpected error, such as invalid
input, then the `FINISHED` column remains `NULL`" – evaluate `STATUS_CODE`,
not "`FINISHED` is empty".

### 4.1 Useful queries

```sql
-- waiting and running now (Oracle's example)
SELECT COUNT(*) FROM rw_server_job_queue
 WHERE status_code IN (1, 2, 3) AND job_type != 'Scheduled';

-- errors of the last hour
SELECT job_id, job_name, owner, queued, SUBSTR(status_message, 1, 200)
  FROM rw_server_job_queue
 WHERE status_code IN (5, 13) AND queued > SYSDATE - 1/24;

-- run time per report, last 7 days
SELECT job_name, COUNT(*), ROUND(AVG(run_elapse)/1000, 1) avg_s,
       ROUND(MAX(run_elapse)/1000, 1) max_s
  FROM rw_server_job_queue
 WHERE job_queue = 'Past' AND queued > SYSDATE - 7
 GROUP BY job_name ORDER BY max_s DESC;

-- jobs that hang (waiting / running for more than 30 minutes)
SELECT job_id, job_name, status_code, queued
  FROM rw_server_job_queue
 WHERE status_code IN (1, 2, 3) AND job_queue = 'Current'
   AND queued < SYSDATE - 30/1440;
```

## 5. What to watch out for

### 5.1 The repository database is a dependency of the Reports server

Tested 2026-11-17 on a standalone Reports server under the Node Manager:

| Situation | Effect (live) |
|---|---|
| repository session killed and the DB user locked while the server runs | the next job write fails (`REP-3113: ORA-03113`, `REP-17008: Closed connection` in `rwserver_diagnostic.log`) – the **Reports server process dies** |
| server start while the DB user is still locked (`ORA-28000`) | the server dies again right after the start |
| Node Manager | restarted the server twice ("Server failed so attempting to restart"); jobs sent in that moment got `REP-50001: The server is initializing` and were **lost** |
| DB user unlocked again | the server started normally, rows were written again |

So with a `jobStatusRepository` the Reports server is only as available as
the repository database:
- put the schema into a database with the same availability as the
  application database (often the same database);
- a database maintenance window is a Reports maintenance window, or remove
  the element before it;
- the Node Manager restarts a server only a limited number of times
  (`RestartMax`, default 2 within `RestartInterval`) – after a longer outage
  start the Reports server by hand;
- password expiry of the repository user stops Reports as well: a profile
  without password expiry for this technical user, or rotate the password
  together with the csf key (`updateCred`).

### 5.2 Errors of the package are silent

Every function of `RW_SERVER` ends with
`EXCEPTION WHEN OTHERS THEN RETURN (SQLCODE)`. A full tablespace, a missing
quota or a value too long for a column (`OWNER VARCHAR2(30)`,
`SERVER VARCHAR2(80)`) is not reported to the Reports server as an error –
the row is simply missing, the report runs anyway. Check now and then that
the number of rows of the day matches `successfulJobs` + `failedJobs` of
`getserverinfo` ([reports_monitoring_getserverinfo.md](reports_monitoring_getserverinfo.md)).

### 5.3 No long-term history, orphan rows

- The table holds at most the past queue (`maxQueueSize`) per Reports server
  (section 2). For statistics over months copy the rows into an own
  archive table – a scheduler job (`INSERT ... SELECT` of new `Past` rows) or a
  trigger on insert. The snapdba article calls the table "self-housekeeping";
  that is right, and it is exactly why the history disappears.
- **Orphans:** when the server drops past jobs at a start (e.g. after
  `maxQueueSize` was lowered) their rows stay in the table (live: 6 rows
  remained after the restart with `maxQueueSize="100"`). Harmless, but they
  disturb counts – delete rows older than the oldest job of the past queue
  now and then.
- `RW_SERVER.clean_up_queue` is a `TRUNCATE TABLE` of the whole table. It was
  not called at a restart in the test; never run it on a table that is used
  for monitoring.

### 5.4 Re-running `rw_server.sql` deletes everything

The script drops the table, the view, `RW_JOBS` and the sequence before
creating them. Run it once per schema; never "just to be sure" after a
patch.

### 5.5 Rights and security

- Minimal rights as in 3.1; no `CREATE ANY TRIGGER`, no `RESOURCE`.
- The repository user is a technical user: own profile, no interactive use.
- `COMMAND_LINE` contains the complete request – depending on the
  application including `userid=user/password@db` of the report. Whoever
  may read the table may read those passwords:
  - grant `SELECT` only to a monitoring role, or better on a view without
    `COMMAND_LINE`;
  - prefer `cmdkey` / `authid` in `cgicmd.dat` over passwords in the
    request ([81-reports_rwservlet_security.md](../09-Install/docs/81-reports_rwservlet_security.md)).
- The DB password lives only in the credential store (`csf:reports:<key>`),
  never in `rwserver.conf`, never in a notes file.

### 5.6 One schema per Reports server and environment

The `SERVER` column separates several Reports servers in one table, but
`remove_job` deletes by `job_id` and `server` – two environments with the
same Reports server name in one schema (e.g. a clone, or test and
production both called `repserver01`) delete each other's rows. Use one
schema per environment, and after a clone point the clone's `dbconn` /
csf key to its own schema
([FormsReports14_linux_clone](../70-Customer-Projects/FormsReports14_linux_clone/README.md) §4.7).

### 5.7 Licence

The schema needs a licensed Oracle Database – it is not part of the RCU
schemas and not covered by the Forms & Reports licence
([fmw_forms_reports_licence.md](fmw_forms_reports_licence.md#5-rcu-database-and-the-same-machine) section 5).
Usually it goes into the database of the application.

### 5.8 Smaller points

- `maxQueueSize` above 3000 and the Reports Queue Manager (`rwrqm`): Oracle
  warns the Queue Manager may fail; the table and `rwservlet` are not
  affected (7.2.1.20).
- `jobRecovery` (auxiliary `.dat` files) is documented in 12.2.1.3 but
  commented out in the `rwserverconf.xsd` of the 14c home – not tested here,
  do not rely on it.
- `jobRepository` (HA) is a different element with its own table `RW_JOBS`;
  `rw_server.sql` creates it as well, but it stays empty without that
  element.
- After changing the element restart the Reports server; a changed csf key
  needs a restart too.

## 6. The old descriptions, assessed

| Source | Still right | To correct for 14.1.2 |
|---|---|---|
| [snapdba, 2016](https://www.snapdba.com/2016/10/configuring-oracle-reports-server-job-queue-monitoring/) (11gR2) | idea, `rw_server.sql`, csf key in the map `reports`, Enterprise Manager setting "Enable Job Status Repository DB", status queries | `GRANT RESOURCE` too wide (3.1); `dbconn` as `host:port:SID` – for a PDB `host:port/service`; "restart WLS_REPORTS" – the standalone Reports server must be restarted; "self-housekeeping" = history limited to `maxQueueSize` (5.3); `.dat` path now `$DOMAIN_HOME/reports/server/` |
| [Oracle 11.1.1, 8.2.1.12](https://docs.oracle.com/cd/E21764_01/bi.1111/b32121/pbr_conf002.htm#i1006647) and [12.2.1.3, 7.2.1.11](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_conf002.htm) | element, default class, properties as name/value pairs, `dbconn` note | example `value=csf:reports:"<dbkey>"` is not well-formed XML; the text still names `repositoryconn` |
| [Oracle 12.2.1.2, 24.3.6](https://docs.oracle.com/middleware/12212/formsandreports/use-reports/pbr_tune003.htm) | table, status codes, count query, `rwserver.conf` paths standalone / in-process | "certified to work against Oracle 10g database" – works against 19c (test host); setup step names `repositoryconn` |
| setup notes from a customer project (Jürgen) | order of the steps: schema, `rw_server.sql`, csf key, element, restart | `CREATE ANY TRIGGER` → `CREATE TRIGGER`; add `CREATE SEQUENCE`; keep passwords out of notes files |

## 7. Sources

Oracle (Reports 14.1.2 has no own Reports books – the 14.1.2 library links the
12.2.1.3 books):
- Oracle Reports 12.2.1.3, *Publishing Reports to the Web*, 7.2 Reports
  Server Configuration File (7.2.1.10 jobRecovery, 7.2.1.11
  jobStatusRepository, 7.2.1.13 jobRepository, 7.2.1.17 persistFile,
  7.2.1.20 queue, 7.2.1.33 server):
  <https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_conf002.htm>
- Oracle Reports 12.2.1.2, 24.3.6 RW_SERVER_JOB_QUEUE Table and 24.3.6.1
  Updating the Database with Queue Activity:
  <https://docs.oracle.com/middleware/12212/formsandreports/use-reports/pbr_tune003.htm>
- Oracle Reports 11.1.1, 8.2.1.12 jobStatusRepository:
  <https://docs.oracle.com/cd/E21764_01/bi.1111/b32121/pbr_conf002.htm#i1006647>
- Files of the 14.1.2 home: `$ORACLE_HOME/reports/admin/sql/rw_server.sql`,
  `rw_job_repos.sql`, `$ORACLE_HOME/reports/dtd/rwserverconf.xsd`.

Secondary:
- snapdba, "Configuring Oracle Reports Server Job Queue Monitoring"
  (October 2016):
  <https://www.snapdba.com/2016/10/configuring-oracle-reports-server-job-queue-monitoring/>
  – names MOS notes 72531.1 and 858200.1 (not checked here).
- Setup notes from a customer project, kindly provided by Jürgen.

Test: Oracle Reports 14.1.2 standalone server `repserver01`, Oracle Database
19c PDB, 2026-11-17 – schema with the six rights of 3.1, csf key via WLST,
element as in 3.4, reports good / failing / scheduled, `maxQueueSize="100"`
with 112 jobs, repository session killed and user locked; afterwards
everything removed again.
