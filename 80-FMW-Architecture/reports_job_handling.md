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
  That the `;` rule also applies to `<write>` is **confirmed (customer,
  2026-11-04)**: a second output directory for the nightly job was appended
  to the existing `<write>` element with `;`
  (`<write>/u01/.../tmp;/u01/.../out</write>`), the Reports server was
  restarted, and the nightly job then wrote into the new directory.
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
admin is called `repadmin` here.

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
# admin credentials in a curl config file (mode 600): data-urlencode = "authid=repadmin/<PASSWORD>"
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

Two different functions use the same mail server:

| | `destype=mail` | `notifysuccess=` / `notifyfailure=` |
|---|---|---|
| what is sent | the **report itself** (e.g. PDF attachment) | a short **notification** after the job (text from `succnote.txt` / `failnote.txt`) |
| recipient | `desname=` (+ `cc=`, `bcc=`) | the value of the keyword |
| sender | `from=` per request | `<property name="sender">` of the `<notification>` element |
| needs | `<pluginParam name="mailServer">` | `mailServer` **and** `<notification id="mailNotify" ...>` |

Status: the `rwserver.conf` part and the code facts below are read on the
test host (Reports 14.1.2, `rwrun.jar`), **mail was not sent yet** – the test
host has no mail server. Live test open (TODO).

### 7.1 Mail server in `rwserver.conf`

The mail server goes into the `rwserver.conf` of the Reports server that
**runs the jobs**. Which one that is, `rwservlet.properties` says:

```bash
grep -n 'inprocess\|<server>' $DOMAIN_HOME/config/fmwconfig/servers/WLS_REPORTS/applications/reports_14.1.2/configuration/rwservlet.properties
# Expected (this library): <server>repserver01</server> and <inprocess>no</inprocess>
```

| `<inprocess>` | Reports server | `rwserver.conf` with the mail server | restart after a change | log of the mail errors |
|---|---|---|---|---|
| **`no`** – standalone (this library, test host) | own process `rwserver` (`<server>` name, e.g. `repserver01`) | `$DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent/<server>/rwserver.conf` | the Reports server (`startStop.sh stop/start <server>`) | `$DOMAIN_HOME/servers/<server>/logs/rwserver_diagnostic.log` |
| **`yes`** – in-process (inside WLS_REPORTS) | runs in the WLS_REPORTS JVM | `$DOMAIN_HOME/config/fmwconfig/servers/WLS_REPORTS/applications/reports_14.1.2/configuration/rwserver.conf` | WLS_REPORTS | `$DOMAIN_HOME/servers/WLS_REPORTS/logs/reports/rwserver_diagnostic.log` (`03-Logs/README.md`) |

- **Only the file of the server in use counts.** The other file has the
  same `pluginParam` element, but an entry there has no effect. A frequent
  mistake: the mail server set in the WLS_REPORTS file while the jobs run on
  the standalone server – the start log then still shows
  `hostName = %MAILSERVER_NAME%` (7.4 step 1).
- 12c had the in-process path under `reports_12.2.1` instead of
  `reports_14.1.2`.
- The examples below and in 7.4 use the standalone server `repserver01`; for
  in-process take the WLS_REPORTS paths of the table.

Oracle's template (14.1.2, `rwserver.conf` of WLS_REPORTS; the standalone
file of the test host has only the one-line form) – the placeholder stays if
nobody sets it:

```xml
<pluginParam name="mailServer" value="%MAILSERVER_NAME%">
   <!--property name="enableSSL" value="yes"/-->
   <!--UserName and Password that can be used to connect to the mail server-->
   <!--property name="mailUserName" value="%MAIL_USERID%" /-->
   <!--property name="mailPassword" value="%MAIL_PASSWORD%"/-->
</pluginParam>
```

What the Reports server makes of it – **confirmed (code)**,
`oracle.reports.server.MailService` in `$ORACLE_HOME/reports/jlib/rwrun.jar`
(14.1.2, read with `javap`), JavaMail underneath:

| Setting | Effect |
|---|---|
| `value="host"` | `mail.smtp.host`; port = JavaMail default **25** |
| `value="host:port"` | split at the `:` into `mail.smtp.host` + `mail.smtp.port` – **the port goes into `value`**, there is no port property |
| `enableSSL=yes` | `mail.smtp.socketFactory.class=javax.net.ssl.SSLSocketFactory` = TLS from the first byte (SMTPS, normally port **465**). Not STARTTLS. Default `no`. |
| `mailUserName` + `mailPassword` | SMTP login. **Only when both are set**, the server also reads these properties of the element (name = the JavaMail key, value `yes` / text): `mail.smtp.auth`, `mail.smtp.starttls.enable`, `mail.smtp.starttls.required`, `mail.smtp.ssl.trust`, `mail.smtp.ssl.protocols`, `mail.smtp.auth.login.disable`, `mail.transport.protocol` |
| `mail.smtp.auth=no` | allowed, but the trace writes "would usually fail" |

Consequences:
- **STARTTLS (port 587) is only possible with a login.** Without
  `mailUserName` / `mailPassword` the STARTTLS properties are not read. A
  relay without login therefore means plain port 25, or `enableSSL=yes`
  on 465.
- **The mail session is built when the server starts.** At start the server
  writes the values into `rwserver_diagnostic.log` (live, test host):

  ```
  [WARNING] [] [oracle.reports.server] ... MailService:MailService [[
   hostName = %MAILSERVER_NAME%
   enableSSL = null
  ]]
  ```

  After every change: restart the Reports server and check this entry.
- **`mailPassword` is clear text in the file** – whether the server encrypts
  it at the restart like the `<identifier>` is **not tested**. Until then:
  a mail user only for this server, only allowed to send, `rwserver.conf`
  readable for `oracle` only.

Examples (`<mail.pipperr.local>` = the SMTP relay of the customer):

```xml
<!-- a) internal relay, no login, port 25 (most common in a company network) -->
<pluginParam name="mailServer" value="mail.pipperr.local"/>

<!-- b) relay with login and STARTTLS on 587 -->
<pluginParam name="mailServer" value="mail.pipperr.local:587">
   <property name="mailUserName" value="reports-sender@pipperr.local"/>
   <property name="mailPassword" value="<MAIL_PASSWORD>"/>
   <property name="mail.smtp.starttls.enable" value="yes"/>
   <property name="mail.smtp.starttls.required" value="yes"/>
</pluginParam>

<!-- c) SMTPS (TLS from the start) on 465 with login -->
<pluginParam name="mailServer" value="mail.pipperr.local:465">
   <property name="enableSSL" value="yes"/>
   <property name="mailUserName" value="reports-sender@pipperr.local"/>
   <property name="mailPassword" value="<MAIL_PASSWORD>"/>
</pluginParam>
```

- **TLS trust:** the relay certificate is checked against the trust store of
  the Reports server JVM (the JDK `cacerts`). An internal CA must be in it,
  otherwise the TLS handshake fails (see the certificates article).
  `mail.smtp.ssl.trust=<host>` switches the check off for this host – only
  as a test.
- **Firewall:** the Reports host needs an outgoing rule to the relay on 25 /
  465 / 587. No direct mail to the internet (rule "no outbound calls" of this
  library).

### 7.2 Sender (`from=`) and notification sender

- **`from=` sets the sender of a `destype=mail` request.** One address, no
  list. **Default `loginid@machine_name`** (Oracle A.6.9), that is
  `oracle@<host>` of the Reports server. Most relays reject this address,
  because the domain of the host does not receive mail. So **always set
  `from=`**, with an address of a domain the relay accepts.
- **`replyto=`** sets where answers go (e.g. the department instead of the
  technical sender).
- **The notification mails** (`notifysuccess` / `notifyfailure`) take their
  sender from the `<notification>` element (Oracle 7.2.1: "some mail servers
  may validate the sender's domain"):

  ```xml
  <notification id="mailNotify" class="oracle.reports.server.MailNotify">
     <property name="succnotefile" value="succnote.txt"/>
     <property name="failnotefile" value="failnote.txt"/>
     <property name="sender" value="reports-noreply@pipperr.local"/>
  </notification>
  ```

  The code reads the property `sender` (string in `MailNotify.class`,
  confirmed).

**Where the note files are – confirmed (code)**, `MailNotify` +
`Utility.fullFileName` / `getTemplatesDir` (14.1.2, `javap`):

| Value of `succnotefile` / `failnotefile` | File read |
|---|---|
| file name only (`succnote.txt`, Oracle's default) | `$ORACLE_HOME/reports/templates/succnote.txt` – the templates directory of the **Oracle home** (Oracle's docs write `template`; on the test host it is `templates`) |
| absolute path | exactly this file |

Oracle's files on the test host (one line of text under a `/` comment header):

```
The Job &jobname on Report Server &servername has successfully finished at &timefinished.
The Job &jobname on Report Server &servername has terminated at &timefinished.
```

- **Placeholders** the code replaces: `&jobName`, `&serverName`,
  `&timeFinished`, `&errorString` (Oracle's files write them in lower case;
  the replace call is passed `true`, most likely "ignore case" – not tested).
  `&errorString` = the status text of the job, the REP error – Oracle's
  `failnote.txt` does not use it, an own fail note should.
- **Own texts: absolute path outside the Oracle home**, e.g. next to the
  `rwserver.conf` of the server:

  ```xml
  <property name="succnotefile" value="/u01/app/oracle/domains/fr_domain/config/fmwconfig/components/ReportsServerComponent/repserver01/succnote_de.txt"/>
  <property name="failnotefile" value="/u01/app/oracle/domains/fr_domain/config/fmwconfig/components/ReportsServerComponent/repserver01/failnote_de.txt"/>
  ```

  A change in `$ORACLE_HOME/reports/templates` is not part of the domain
  backup, is lost on a new Oracle home (out-of-place patch, clone of the
  binaries) and applies to every domain of that home.
- **Open (live test):** whether the `/` header lines of the file land in the
  mail body, and the subject line – the code takes it from Oracle's message
  catalogue (message 56086), not from a property.

### 7.3 Calling a report with `destype=mail`

The keywords (Oracle A.5 / A.6 / A.7 / A.8):

| Keyword | Value |
|---|---|
| `destype=mail` | send by mail |
| `desname=` | main recipient(s), several separated by `,` (Oracle: without blanks) |
| `desformat=` | `pdf` (attachment); `html` / `htmlcss` are sent as HTML |
| `from=` | sender (7.2) |
| `replyto=` | answer address |
| `cc=` / `bcc=` | copies – one address `"a@x"` or a list `("a@x","b@x")` |
| `subject=` | subject line |

Oracle's example (A.5, `rwrun`), here with the path of the domain wrapper
and the DB login in a parameter file (mode 600, not on the command line,
as in 5.2):

```bash
# $ORACLE_BASE/reports/jobs/test_mail.cmd:  userid=<db_user>/<db_password>@//<db_host>:1521/<service>
$DOMAIN_HOME/reports/bin/rwrun.sh report=/u01/app/oracle/reports/source/test.rdf \
    cmdfile=$ORACLE_BASE/reports/jobs/test_mail.cmd desformat=pdf destype=mail \
    desname="emp1@pipperr.local,emp2@pipperr.local" cc="emp3@pipperr.local" bcc="mgr@pipperr.local" \
    replyto="me@pipperr.local" from="me@pipperr.local" subject="Test report"
```

- **Call `$DOMAIN_HOME/reports/bin/rwrun.sh`, not `$ORACLE_HOME/bin/rwrun`.**
  The wrapper sources `reports.sh` (`REPORTS_PATH`, `TNS_ADMIN`, libraries)
  and sets the tools component `reptools1`, then runs
  `$ORACLE_HOME/bin/rwrun` (test host).
- **`rwrun` runs the report locally, without the Reports server.** It does
  not read `rwserver.conf` – its mail server is the `pluginParam
  name="mailServer"` in the tools configuration
  `$DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/reptools1/rwbuilder.conf`
  (on the test host also still `%MAILSERVER_NAME%`, with its own
  `<notification id="mailNotify">`). Set it there too when `rwrun` should
  send mail.
- `report=` with the full path, or the file in a `REPORTS_PATH` directory of
  `reports.sh`.

**a) Via rwservlet with a key in `cgicmd.dat` (recommended).** The fixed part
– report, mail target, sender, subject – stays in the key. The URL only
carries `cmdkey=`; the user cannot change the recipient or the sender. The
DB login is in the key as before (secured server: `%D` / `RepRunner`, see
[81-reports_rwservlet_security.md](../09-Install/docs/81-reports_rwservlet_security.md)):

```
monthly_sales_mail: report=monthly_sales.rdf destype=mail desformat=pdf
    desname=controlling@pipperr.local from=reports-noreply@pipperr.local
    replyto=controlling@pipperr.local subject="Monthly sales" %*
```

- One key per line in the real file (the line is wrapped here); `%*` lets
  further parameters from the URL through (e.g. report parameters) – the
  same rules as for every other key.
- **Values with blanks in quotes** (`subject="..."`).
- Call as POST (no login in the access log):

  ```bash
  curl -s -d cmdkey=monthly_sales_mail -d p_month=2026-10 \
       http://localhost:9002/reports/rwservlet | grep -o 'REP-[0-9]*[^<]*'
  # Expected: no REP line (the exact success page for destype=mail is not tested yet)
  ```

- **Must it be in `cgicmd.dat`?** No – every keyword can also be a
  parameter of the request (`-d destype=mail -d desname=...`). But: then
  every caller can choose recipient and sender, and the rwservlet becomes a
  mail sender for anyone who can reach it. With `cmdkey` the target is fixed
  on the server. For a secured server: put the mail keywords into the key.

**b) Scheduled or by cron.** The same keywords go into the curl file of 5.3
(`data = "destype=mail&desformat=pdf"`, `data-urlencode = "desname=..."`,
`data-urlencode = "from=..."`, `data-urlencode = "subject=..."`) or into the
`cmdfile` of 5.2. With variant B the wrapper must not set `desname` to a
file then.

**c) Notification only** (the report goes to a file, a mail says "done" /
"failed"):

```
... destype=file desname=/u01/app/oracle/reports/tmp/daily.pdf
    notifysuccess=controlling@pipperr.local notifyfailure=it-ops@pipperr.local
```

For variant B the OS can send the notification itself (cron `MAILTO`, or a
mail from the wrapper on `rc≠0`). That needs no mail set-up in the Reports
server.

### 7.4 Debugging

Step by step from the network to the Reports server, as `oracle` on the
Reports host:

1. **Configuration loaded?** After the restart:

   ```bash
   grep -A3 'MailService:MailService' $DOMAIN_HOME/servers/repserver01/logs/rwserver_diagnostic.log | tail -4
   # Expected: hostName = mail.pipperr.local:587 (not %MAILSERVER_NAME%), enableSSL = yes/no/null
   ```

2. **Relay reachable?**

   ```bash
   timeout 5 bash -c '</dev/tcp/mail.pipperr.local/25' && echo open        # 465 / 587 in the same way
   openssl s_client -connect mail.pipperr.local:587 -starttls smtp -brief </dev/null   # STARTTLS + certificate
   openssl s_client -connect mail.pipperr.local:465 -brief </dev/null                  # SMTPS
   ```

   `verify error` = the relay certificate is not trusted (7.1, TLS trust).

3. **Relay accepts sender and recipient – without Reports.** `curl` speaks
   SMTP and shows the dialogue (`-v`):

   ```bash
   printf 'Subject: Reports mail test\n\nTest from the Reports host.\n' > /tmp/mailtest.txt
   curl -v --url smtp://mail.pipperr.local:25 --mail-from reports-noreply@pipperr.local \
        --mail-rcpt controlling@pipperr.local -T /tmp/mailtest.txt
   ```

   For 587 add `--ssl-reqd` (STARTTLS) and `--user reports-sender@pipperr.local`
   (curl asks for the password). An answer like `550 sender rejected` /
   `relay access denied` is a matter for the mail team: allow the Reports host
   IP or the sender address on the relay. This test already shows whether
   `from=` is accepted.

4. **Report with `destype=mail`:** a small report (e.g. `select sysdate from
   dual`) with the key from 7.3. Then:
   - the job status as admin with `showjobs queuetype=past` (section 6) –
     status code 5 + the REP text;
   - the error in the log:

     ```bash
     grep -hE 'REP-[0-9]+|MailService|javax.mail' $DOMAIN_HOME/servers/repserver01/logs/rwserver_diagnostic.log | tail -20
     ```

     The `javax.mail...Exception` behind the REP number names the cause
     (connection refused, `530 Must issue a STARTTLS command first`,
     `535 authentication failed`, certificate).

5. **More detail (trace):** raise the logger `oracle.reports.server` in
   `$DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent/repserver01/logging.xml`
   from `NOTIFICATION:1` to `TRACE:32`, restart, run the test, set it back.
   The code writes its mail values under a trace flag (`MailService:MailService`,
   `MailService:send`); whether `TRACE:32` switches this flag on is **not
   tested**. JavaMail's own SMTP dialogue (`mail.debug`) cannot be set through
   `rwserver.conf` – the server passes only the properties of 7.1.

Typical errors (from the JavaMail / SMTP answers – to be confirmed in the
live test):

| Message | Cause |
|---|---|
| `hostName = %MAILSERVER_NAME%` at the start | template value never set, or set in the `rwserver.conf` of the server not in use (7.1 table: `inprocess` no / yes) |
| `Connection refused` / timeout | firewall to the relay, wrong port, relay only on 587 / 465 |
| `530 Must issue a STARTTLS command first` | relay wants STARTTLS – 7.1 b) (with login) |
| `535 Authentication failed` | `mailUserName` / `mailPassword` wrong, or the relay wants the full address as user |
| `550` / `553 sender rejected`, `relay access denied` | `from=` missing (default `oracle@<host>`) or not allowed; Reports host not allowed on the relay |
| `PKIX path building failed` | relay certificate (internal CA) not in the JDK trust store |

### 7.5 Sources

- Oracle, Publishing Reports 12.2.1.3 (linked from the 14.1.2 library):
  - [7.2.1 Reports server configuration file – `pluginParam` / `mailServer`, `enableSSL`, `notification` with `sender`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_conf002.htm)
  - [A.5 command line keywords – `BCC`, `CC`, `DESFORMAT`, `DESNAME` (mail example), `DESTYPE=MAIL`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla005.htm)
  - [A.6 – `FROM` (default `loginid@machine_name`), `NOTIFYFAILURE`, `NOTIFYSUCCESS`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla006.htm)
  - [A.7 – `REPLYTO`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla007.htm),
    [A.8 – `SUBJECT`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla008.htm)
  - 12.2.1 (same text): [7.2 Reports Server Configuration File](https://docs.oracle.com/middleware/1221/formsandreports/use-reports/pbr_conf002.htm)
- Code: `oracle.reports.server.MailService`, `MailNotify`, `DesMail` in
  `$ORACLE_HOME/reports/jlib/rwrun.jar`, Reports 14.1.2 test host, read with
  `javap -c` on 2026-11-10 (host:port, `enableSSL`, STARTTLS properties only
  with login, `sender`).
- Oracle community: [REP-50152 "Must issue a STARTTLS command first"](https://community.oracle.com/mosc/discussion/4173446)
  (Gmail SMTP; internal relay worked).
- pipperr.de (older blog entry): mail server in `rwserver.conf` of Reports
  12.2.1 on Windows, the same `pluginParam` block.

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
| `REP-56133 Access is denied to write to the specified location` | `desname` outside `<folderAccess><write>`, **or in a subdirectory of it** (live) – append the directory to the one `<write>` element with `;` and restart (customer, 2026-11-04) |
| `REP-56132 Access is denied to the report definition file` | report not in a `<read>` directory, or the name is wrong (live, rc=1 of `rwclient`) |
| `REP-56071 unauthorized` when scheduling | user without `RW_EXECREPORTS`, or `monUser` used for a report |
| `showjobs queuetype=future` is empty although jobs exist | asked as `monUser` – shows only its own jobs; ask as admin |
| `REP-52274 Invalid values passed` | `queuetype=scheduled` – the value is `future` |
| same output file every time | `desname` is fixed per scheduled job – variant B for names with a date |
| two runs at the same time | the request was sent twice (two schedules) – `showjobs future`, `killjobid` the extra one |
| passwords in `WLS_REPORTS/logs/access.log` | request sent as GET with `userid=` / `authid=` in the URL – use POST / `cmdfile` |
| schedule ran on a test clone | `.dat` copied with the domain (section 8) |
