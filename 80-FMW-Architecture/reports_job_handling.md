# Reports job handling – scheduled reports, job queues, cron

How a report is run automatically on a schedule on a standalone Oracle
Reports 14.1.2 server on Linux, how the job queues work, and how jobs are
watched and cancelled. Based on the Windows article "Report automatisch per
Zeitplan erstellen" (pipperr.de, see sources) and moved to Linux with the
security set-up of this library (`securityId`, `RepRunner` via `cmdkey`,
`monUser`).

Live-tested on the test host on 2026-11-03: Reports 14.1.2 + QPR 39600348,
secured server, `cgicmd.dat` key `default` with `RepRunner`.

Related:
- Security: [reports_user_local_ldap.md](reports_user_local_ldap.md) and
  [81-reports_rwservlet_security.md](../09-Install/docs/81-reports_rwservlet_security.md).
- Monitoring of the counters: [reports_monitoring_getserverinfo.md](reports_monitoring_getserverinfo.md).
- Engines: [report_engine_architecture.md](report_engine_architecture.md).
- Read / write directories: [report_server_image_handling.md](report_server_image_handling.md).

---

## 1. Sources

- **Oracle 14.1.2:** The library of Oracle Forms and Reports 14.1.2 has no
  Reports books of its own. Its section "Work with Oracle Reports" links to
  the 12.2.1.3 books (**documented**):
  - [Publish Reports to the Web with Oracle Reports Services](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/toc.htm)
  - [User's Guide to Building Reports](https://docs.oracle.com/middleware/12213/formsandreports/build-reports/toc.htm)
  
  The entry page is the
  [Oracle Forms and Reports 14.1.2.0.0 library](https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/).
  The 14.1.2 release notes mark Oracle Reports as deprecated: critical fixes
  only, no new functions.
- **Oracle chapters used here** (Publishing Reports 12.2.1.3):
  - [18.11 Scheduling Reports to Run Automatically](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_run011.htm)
  - [A.8.3 SCHEDULE, A.8.7 SHOWJOBID, A.8.8 SHOWJOBS, A.8.10 SHOWMYJOBS](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla008.htm)
  - [A.6.10 GETJOBID, A.6.14 JOBNAME, A.6.19 KILLJOBID, A.6.26/27 NOTIFYFAILURE/NOTIFYSUCCESS](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla006.htm)
  - [A.2.5 rwservlet](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla002.htm):
    end-user and administrator web commands
- **Windows original:**
  [pipperr.de – Oracle Reports 14c Windows, "Report automatisch per Zeitplan erstellen"](https://www.pipperr.de/dokuwiki/doku.php?id=forms:oracle_reports_14c_windows64).
  It uses `rwclient.bat` with `SCHEDULE=` and `DESTYPE=file`, and shows the
  jobs with `showjobs`.

## 2. The job model

```
  request (rwservlet POST / rwclient)
        |
        v
  +------------------- Reports server repserver01 -------------------+
  |                                                                  |
  |  future queue   scheduled "parent" job (id 85), schedule=...     |
  |        |  at each nextRun the server creates a NEW job           |
  |        v                                                         |
  |  current queue  job 86 -> engine rwEng-n -> desname / cache      |
  |        |                                                         |
  |        v                                                         |
  |  past queue     job 86 finished (code 4) / failed (code 5)       |
  |                 parent 85 moves here when it expires             |
  |                 or is killed                                     |
  |                                                                  |
  |  $DOMAIN_HOME/reports/server/repserver01.dat                     |
  |  = queues on disk (survives a restart)                           |
  +------------------------------------------------------------------+
```

Facts, **confirmed (live)** on 2026-11-03:

| Topic | Finding |
|---|---|
| **parent / child** | A scheduled request creates one job in `future` (id 85). Each run is a new job with its own id (86, 87) in `past`. After `expires after 2`, job 85 also moved to `past` and the future queue was empty. |
| **owner** | the `authid` user of the request. Via `cmdkey=default` that is `RepRunner` (from `cgicmd.dat`), not the caller. |
| **persistence** | A future job (`daily from 23:00 tomorrow`) was still in `future` after `startStop.sh stop/start repserver01`, with the same id and `nextRun`. The queues live in `$DOMAIN_HOME/reports/server/<server>.dat`. That file is binary; `strings` shows neither job names nor passwords, but it holds the whole request. |
| **output name** | `desname` is fixed per job: every run overwrites the same file (`sched_test.pdf`, mtime 15:32:15 → 15:33:15). |
| **write directory** | `destype=file` only writes into a directory listed in `<folderAccess><write>` of `rwserver.conf` – **not into its subdirectories** (`tmp/out` under the `<write>` dir `tmp`: rejected), same rule as `<read>`. Otherwise: `REP-56133: Access is denied to write to the specified location`. |
| **job status codes** | `1` waiting in the queue, `4` finished successfully, `5` terminated with error, `7` canceled upon user request |
| **past queue size** | `<queue maxQueueSize="4000"/>`: number of past jobs kept |

## 3. Three ways to run reports automatically

| | **A) `SCHEDULE=` in the Reports server** | **B) cron / systemd timer + run now** | C) Reports Queue Manager |
|---|---|---|---|
| how | one request with `schedule=...` (rwservlet POST or `rwclient`), the server keeps it in its future queue | the OS starts `rwclient.sh` (or `curl` POST) at the given time, without `schedule=` | `rwrqv.sh` (GUI, needs X11) |
| where is the plan | inside `repserver01.dat` – visible only with `showjobs queuetype=future` | `crontab -l` / `systemctl list-timers` – plain text, versioned, in the backup | in the server |
| output name per run | fixed (overwritten) | free, e.g. with the date (`report_$(date +%F).pdf`) | fixed |
| survives restart | yes (`.dat`) | yes (OS) | yes |
| survives domain restore / clone | the **old** `.dat` revives old schedules; a clone runs them **twice** (section 8) | follows the crontab of the host | as A |
| failure visible | `failedJobs`, `showjobs past` | exit code of `rwclient` (`1` on error, live) → mail / journal / monitoring | as A |
| change / delete | `killjobid<n>` (admin only) and new request | edit crontab | GUI |

**Recommendation for a Linux server operated by admins: B (cron or systemd
timer + `rwclient.sh cmdfile=`).** The plan is visible and in the backup,
every run gets its own file name, errors go to the OS, and there is no
hidden state in `.dat`.

**A** is right when the users schedule jobs themselves through the
rwservlet, as in the Windows original. It is also right when the schedule
needs Oracle's calendar logic, e.g. "last weekday before the 15th".

**C** (`rwrqv.sh`) needs an X display. Not used on headless servers.

## 4. `SCHEDULE=` – syntax

Verbatim from Oracle A.8.3 (**documented**):

> Use `SCHEDULE` to set the day, time, and frequency a report should be run.
> The default is to run the report once, now. Time values are expressed
> according to a 24-hour day (that is, one o'clock is expressed 13:00). To
> eliminate the need for quoting the scheduling command, use underscores (_)
> instead of spaces. You can also specify an expiration for a report job
> after a number of runs or on a particular date/time.

The keyword is used by `rwclient` and `rwservlet`. It is not used by
`rwrun`, `rwbuilder`, `rwconverter` or `rwserver`.

```
SCHEDULE=[FREQ from] TIME [retry {n} after LEN] expires {on|after} time|n

FREQ      hourly | daily | weekly | monthly | {every {LEN | DAYREPEAT}}
          | {last {WEEKDAYS | weekday | weekend} before {n}+}
LEN       {n}+ {minute[s] | hour[s] | day[s] | week[s] | month[s]}
DAYREPEAT {first | second | third | fourth | fifth} WEEKDAYS of month
WEEKDAYS  mon | tue | wed | thu | fri | sat | sun
TIME      now | CLOCK [DATE]
CLOCK     h:m | h:mm | hh:m | hh:mm
DATE      today | tomorrow | {MONTHS {d | dd} [,year]}
MONTHS    jan | feb | mar | apr | may | jun | jul | aug | sep | oct | nov | dec
EXPIRES   on {today | tomorrow | {MONTHS {d | dd} [,year]}} | after n
```

Examples:

| `schedule=` | Meaning | Backed by |
|---|---|---|
| `every 1 minute from now expires after 2` | two runs, one minute apart | **live** |
| `daily from 23:00 tomorrow expires after 1` | once, tomorrow at 23:00 | **live** (`nextRun` correct, killed before it ran) |
| `daily from 06:00 tomorrow` | every day at 06:00, no end | syntax (Oracle) |
| `every first fri of month from 15:53 Oct 23, 1999 retry 3 after 1 hour expires on 15:53 Oct 23, 2003` | first Friday of every month, 3 retries | Oracle example |
| `last weekday before 15 from 12:00 May 09, 2025 retry after 1 hour expires after 2` | last weekday before the 15th | pipperr.de / Oracle |

- **The time is the Reports server's time zone** (`date` on the host).
- **A bad value gives** "SCHEDULE argument is invalid" (12.2.1.3 and
  later).
- **As a POST the value can contain blanks:** `--data-urlencode
  "schedule=..."`. The underscores are only needed on a command line without
  quoting.

## 5. Set-up on Linux

Prerequisites, all already in place with the security cookbook
(Reports_Absicherung_kochbuch_de.txt):
- `cgicmd.dat` key `default` with `authid=RepRunner/...` (role
  `RW_EXECREPORTS`);
- the report file in a `<folderAccess><read>` directory.

The steps below are for a bash session as `oracle`.

### 5.1 Output directory

```bash
grep -n '<write>' $RWSERVER_CONF
# Expected: <write>/u01/app/oracle/reports/tmp</write>  (or your own directory)
```

- Write the output **into exactly that directory**. Subdirectories are
  rejected with `REP-56133` (live, 2026-11-03), the same rule as for
  `<read>`.
- If the output must go somewhere else, add that directory in the **one**
  `<write>` element, separated by `;`, like `<read>`
  ([report_server_image_handling.md](report_server_image_handling.md)).
  That the `;` rule also applies to `<write>` is an **assumption**, not
  tested.
- After a change, restart the Reports server.
- Without the right directory the job fails with `REP-56133`.

### 5.2 Variant B – cron with `rwclient.sh` (recommended)

`rwclient` takes its arguments from a file (`cmdfile=`). The DB and Reports
passwords stay out of `ps` and the crontab. Live: 1.3 s per run, exit code 0
on success and **1 on error** (`REP-56132`, unknown report).

1. A parameter file per report (mode 600), e.g.
   `$ORACLE_BASE/reports/jobs/daily_sales.cmd`:

   ```
   report=daily_sales.rdf
   destype=file
   desformat=pdf
   userid=<db_user>/<db_password>@//<db_host>:1521/<service>
   authid=RepRunner/<REPRUNNER_PASSWORD>
   ```

   `desname` stays out of the file so that every run gets its own name.
   On the command line it comes after `cmdfile=` and is used together with
   the file (live).

2. A small wrapper, `$ORACLE_BASE/reports/jobs/run_report.sh`:

   ```bash
   #!/bin/bash
   # run_report.sh <name> - run $JOBS/<name>.cmd on the Reports server, output with date
   JOBS=/u01/app/oracle/reports/jobs
   OUT=/u01/app/oracle/reports/tmp              # = a <folderAccess><write> directory, no subdirectory
   DOMAIN_HOME=/u01/app/oracle/domains/fr_domain
   NAME="$1"
   STAMP=$(date +%Y%m%d_%H%M)
   "$DOMAIN_HOME/reports/bin/rwclient.sh" server=repserver01 \
       cmdfile="$JOBS/$NAME.cmd" desname="$OUT/${NAME}_${STAMP}.pdf" \
       >> "$JOBS/$NAME.log" 2>&1
   RC=$?
   logger -t ihw-report "$NAME rc=$RC $OUT/${NAME}_${STAMP}.pdf"
   exit $RC
   ```

3. The crontab of `oracle` (`crontab -e`):

   ```
   # daily_sales every workday at 06:00
   0 6 * * 1-5  /u01/app/oracle/reports/jobs/run_report.sh daily_sales
   ```

   Live run of this wrapper (with a test `.cmd`): rc=0,
   `test_dual_20261103_1538.pdf` written, journal line
   `ihw-report: test_dual rc=0 /u01/app/oracle/reports/tmp/test_dual_20261103_1538.pdf`.
   With `OUT=.../tmp/out` it gave rc=1 with `REP-56133`.

4. The checks:

   ```bash
   journalctl -t ihw-report --since today      # rc=0 = OK, rc=1 = REP error in daily_sales.log
   ```

   On the Reports server side each run is a normal job in `showjobs
   queuetype=past`, with owner `RepRunner`.

Instead of `rwclient` a `curl` POST against rwservlet with `cmdkey=default`
works the same way (section 5.3, without `schedule=`). It then needs no
`authid` in the file, because the key brings `RepRunner`. Only the DB login
`userid=` is still needed.

### 5.3 Variant A – `SCHEDULE=` through rwservlet

One POST, everything in the body, no password in the URL
([reports_monitoring_getserverinfo.md §2.1](reports_monitoring_getserverinfo.md)).
The secrets are in a curl config file (mode 600):

```
# $ORACLE_BASE/reports/jobs/daily_sales.curl
url = "http://localhost:9002/reports/rwservlet"
data = "cmdkey=default&report=daily_sales.rdf&destype=file&desformat=pdf"
data = "desname=/u01/app/oracle/reports/tmp/daily_sales.pdf"
data = "jobname=daily_sales"
data-urlencode = "schedule=daily from 06:00 tomorrow"
data-urlencode = "userid=<db_user>/<db_password>@//<db_host>:1521/<service>"
```

```bash
curl -s -K $ORACLE_BASE/reports/jobs/daily_sales.curl | grep -o 'scheduled successfully\|REP-[0-9]*[^<]*'
# Expected: scheduled successfully
```

- Live: this file format (several `data =` lines, `schedule` and `userid`
  via `data-urlencode`) answered "scheduled successfully", and the job showed
  up in `future` with `jobname`.
- **`jobname=`** names the job in `showjobs` (live: `<name>ihw_daily_test</name>`).
  Without it the report name is shown.
- **`rwclient` also works,** with `schedule=` in the `cmdfile` (as in the
  Windows original).
- **Run the request ONCE.** Every repeated call creates a further schedule
  of its own.

## 6. Watching and cancelling jobs

All commands as POST, with the user named in the table. The `<identifier>`
admin is called `rep_admin` here.

| Command | Who | Live result |
|---|---|---|
| `showjobs` + `queuetype=future` | `<identifier>` admin | all scheduled jobs with `<schedule><lastRun>/<nextRun>/<description>` |
| `showjobs` + `queuetype=future` | `monUser` | **only its own jobs** (empty here – the jobs belong to `RepRunner`) |
| `showjobs` + `queuetype=past` (+ `count=`, `startrow=`) | admin | finished / failed / killed jobs, `<status code=...>` |
| `showjobs` + `queuetype=scheduled` | – | `REP-52274 Invalid values passed` – the value is `future` |
| `killjobid<n>` | admin | job → `past`, status code 7 |
| `killjobid<n>` | `monUser` | `REP-56071 ... Permission to run Web command killjobid is not granted` |
| `showjobid<n>`, `getjobid<n>` | the owner / admin | status of one job; output only for `destype=cache` jobs still in the cache (Oracle A.6.10) |

```bash
# admin credentials in a curl config file (mode 600): data-urlencode = "authid=rep_admin/<PASSWORD>"
curl -s -K ~/.config/rwadmin.curl -d server=repserver01 -d statusformat=XML -d queuetype=future \
     http://localhost:9002/reports/rwservlet/showjobs
```

Example answer (live, shortened):

```xml
<job id="85" queueType="future">
   <name>test_dual.rdf</name>
   <status code="1">The job is waiting in the queue.</status>
   <owner>RepRunner</owner>
   <destination><desType>file</desType><desName>/u01/app/oracle/reports/tmp/sched_test.pdf</desName><desFormat>pdf</desFormat></destination>
   <schedule>
      <lastRun>Nov 3, 2026, 3:32:15/PM</lastRun>
      <nextRun>Nov 3, 2026, 3:33:14/PM</nextRun>
      <interval intervalunit="1">1</interval>
      <description>every 1 minute from now expires after 2</description>
   </schedule>
</job>
```

```bash
# cancel job 88
curl -s -K ~/.config/rwadmin.curl -d server=repserver01 -d statusformat=XML \
     http://localhost:9002/reports/rwservlet/killjobid88 | grep -o '<status[^<]*'
# Expected: <status code="7">The job is canceled upon user request.
```

**For the monitoring system:** A scheduled job that fails raises
`failedJobs` in `getserverinfo`
([reports_monitoring_getserverinfo.md §5](reports_monitoring_getserverinfo.md)).
Which job it was, `showjobs queuetype=past` shows as admin (status code 5).
With variant B the exit code of the wrapper is enough.

## 7. Mail notification and `destype=mail`

The keywords:
- `notifysuccess=` / `notifyfailure=` (Oracle A.6.26/27) send a mail after
  the job;
- `destype=mail` + `desname=<address>` sends the report itself.

Both need:
- the `<notification id="mailNotify" class="oracle.reports.server.MailNotify">`
  element of `rwserver.conf` (present on the test host);
- a real mail server in `<pluginParam name="mailServer" value="..."/>`. On
  the test host this is still the template placeholder `%MAILSERVER_NAME%`,
  so mail is **not tested**.

For variant B the OS can send the mail itself (cron `MAILTO`, or a mail
from the wrapper on `rc≠0`). That needs no mail set-up in the Reports server.

## 8. Backup, restore, clone

- **`$DOMAIN_HOME/reports/server/<server>.dat` holds the scheduled jobs.** A
  restore of an old domain backup revives the schedules of that time.
- **A cloned domain (golden image) starts with the same `.dat`.** The clone
  then runs the same schedules and writes the same files, or sends the same
  mails. Before the first start of a clone:
  - stop the Reports server;
  - move the `.dat` aside, or delete the future jobs with `killjobid`.
  
  See [clone_golden_image.md](clone_golden_image.md).
- With variant B the plan is the crontab. It belongs to the host, not to
  the domain.

## 9. Pitfalls

| Symptom | Cause |
|---|---|
| `REP-56133 Access is denied to write to the specified location` | `desname` outside `<folderAccess><write>`, **or in a subdirectory of it** (live) |
| `REP-56132 Access is denied to the report definition file` | report not in a `<read>` directory, or the name is wrong (live, rc=1 of `rwclient`) |
| `REP-56071 unauthorized` when scheduling | user without `RW_EXECREPORTS`, or `monUser` used for a report |
| `showjobs queuetype=future` is empty although jobs exist | asked as `monUser` – shows only its own jobs; ask as admin |
| `REP-52274 Invalid values passed` | `queuetype=scheduled` – the value is `future` |
| same output file every time | `desname` is fixed per scheduled job – variant B for names with a date |
| two runs at the same time | the request was sent twice (two schedules) – `showjobs future`, `killjobid` the extra one |
| passwords in `WLS_REPORTS/logs/access.log` | request sent as GET with `userid=` / `authid=` in the URL – use POST / `cmdfile` |
| schedule ran on a test clone | `.dat` copied with the domain (section 8) |
