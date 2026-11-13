---
title: "Oracle Reports 14c Mail – SMTP, Notifications, Tickets"
description: "How a standalone Oracle Reports 14.1.2 server sends mail: destype=mail, notifysuccess / notifyfailure, mail server and sender, failure mail to a ticket system."
---

# Reports mail handling – mail server, sender, notifications, failure mail to a ticket system

How a standalone Oracle Reports 14.1.2 server sends mail: the report itself
(`destype=mail`) or a short notification after a job (`notifysuccess` /
`notifyfailure`). Where the mail server and the note texts are configured,
who is the sender, demo calls, and how a failing report can open a ticket in
the customer's ticket system by mail.

Moved out of [reports_job_handling.md](reports_job_handling.md) (section 7)
on 2026-11-11. Live-tested on the test host on 2026-11-11 with a local SMTP
sink (section 7.1): Reports 14.1.2 + QPR 39600348, secured server
(`securityId`), `cgicmd.dat` key `default` with `RepRunner`.

Related:
- Jobs, queues, cron: [reports_job_handling.md](reports_job_handling.md).
- Security of rwservlet and `cgicmd.dat`: [81-reports_rwservlet_security.md](../09-Install/docs/81-reports_rwservlet_security.md).
- Monitoring (`failedJobs`): [reports_monitoring_getserverinfo.md](reports_monitoring_getserverinfo.md).
- Trust store for TLS to the relay: [certificates_trust_stores.md](certificates_trust_stores.md).

---

## 1. Overview

Two different functions use the same mail server:

| | `destype=mail` | `notifysuccess=` / `notifyfailure=` |
|---|---|---|
| what is sent | the **report itself** (e.g. PDF attachment) | a short **notification** after the job (text from `succnote.txt` / `failnote.txt`) |
| recipient | `desname=` (+ `cc=`, `bcc=`) | the value of the keyword |
| sender | `from=` per request | `<property name="sender">` of the `<notification>` element |
| needs | `<pluginParam name="mailServer">` | `mailServer` **and** `<notification id="mailNotify" ...>` |

```
 request (rwservlet POST / rwclient / schedule=)      rwrun (local, no server)
        |                                                   |
        v                                                   v
 Reports server repserver01 (rwserver.conf)          rwbuilder.conf of reptools1
   job -> engine -> result                             (own mailServer entry)
        |
        |-- destype=mail          -> report as attachment to desname= / cc= / bcc=
        |-- notifysuccess=<addr>  -> note text succnotefile   (after success)
        `-- notifyfailure=<addr>  -> note text failnotefile   (after an error,
        |                             once per try: retry="3" = 4 mails)
        v
 MailService (JavaMail) --SMTP 25 / 465 / 587--> mail relay --> mailbox / ticket system
```

Status (2026-11-11):
- **Notifications confirmed (live)** with a local SMTP sink: `notifyfailure`,
  `notifysuccess`, sender property, own note files with all placeholders,
  `notifyfailure` in a `cgicmd.dat` key (section 6).
- **Not tested yet:** `destype=mail` (report as attachment), a real relay
  with login / STARTTLS / SMTPS, encryption of `mailPassword` at the restart.
  The `rwserver.conf` part and the code facts below are read on the test host
  (Reports 14.1.2, `rwrun.jar`, `javap`, 2026-11-10).

## 2. Configuration – the mail server

The mail server goes into the `rwserver.conf` of the Reports server that runs
the jobs (which file that is: 3.1). **It is read when the Reports server
starts** – confirmed (live) 2026-11-11: after `startStop.sh stop/start
repserver01` the start log showed the new `hostName`.

### 2.1 Oracle's template and what the code makes of it

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

### 2.2 Examples, TLS and firewall

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

## 3. File locations

| What | File |
|---|---|
| mail server, notification class, sender (standalone server) | `$DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent/<server>/rwserver.conf` |
| the same for the in-process server | `$DOMAIN_HOME/config/fmwconfig/servers/WLS_REPORTS/applications/reports_14.1.2/configuration/rwserver.conf` |
| fixed request parts incl. `notifyfailure=` per key | `$DOMAIN_HOME/config/fmwconfig/servers/WLS_REPORTS/applications/reports_14.1.2/configuration/cgicmd.dat` – read by WLS_REPORTS, **a change needs a restart of WLS_REPORTS** (live, 2026-11-11) |
| note texts (Oracle) | `$ORACLE_HOME/reports/templates/succnote.txt` / `failnote.txt` |
| note texts (own) | absolute path in `succnotefile` / `failnotefile`, e.g. next to `rwserver.conf` (3.2) |
| mail server for `rwrun` | `$DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/reptools1/rwbuilder.conf` (section 5) |
| mail errors | `rwserver_diagnostic.log` of the server in use (3.1 table) |

### 3.1 Which `rwserver.conf`

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
  `hostName = %MAILSERVER_NAME%` (section 7, step 1).
- 12c had the in-process path under `reports_12.2.1` instead of
  `reports_14.1.2`.
- The examples below and in section 7 use the standalone server `repserver01`; for
  in-process take the WLS_REPORTS paths of the table.

### 3.2 Note files (`succnotefile` / `failnotefile`)

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

Confirmed (live) 2026-11-11 with an own note file (absolute path):
- all four placeholders are replaced (`&jobName`, `&serverName`,
  `&timeFinished`, `&errorString`, written in this mixed case in the file);
- **the `/` header lines land in the mail body** – leave them out of own
  files;
- `&timeFinished` looks like `11/11/26, 1:16:16 PM`;
- `&errorString` is the full job status text over several lines:
  `The report terminated with error:` + the REP lines + a line with `.`;
- the subject is fixed (6.2); the mail is `text/plain; charset=us-ascii` –
  umlauts in an own note file are not tested.

## 4. Sender (`from=`) and notification sender

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

Confirmed (live) 2026-11-11: with `<property name="sender"
value="reports-noreply@pipperr.local"/>` the notification mails had this
address as envelope sender (`MAIL FROM`) and in `From:`. The `Message-ID`
carries the FQDN of the Reports host.

## 5. Demo calls – `destype=mail` and notifications

The keywords (Oracle A.5 / A.6 / A.7 / A.8):

| Keyword | Value |
|---|---|
| `destype=mail` | send by mail |
| `desname=` | main recipient(s), several separated by `,` (Oracle: without blanks) |
| `desformat=` | `pdf` (attachment); `html` / `htmlcss` are sent as HTML |
| `from=` | sender (section 4) |
| `replyto=` | answer address |
| `cc=` / `bcc=` | copies – one address `"a@x"` or a list `("a@x","b@x")` |
| `subject=` | subject line |

Oracle's example (A.5, `rwrun`), here with the path of the domain wrapper
and the DB login in a parameter file (mode 600, not on the command line,
as in [job handling 5.2](reports_job_handling.md#52-variant-b--cron-with-rwclientsh-recommended)):

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

**b) Scheduled or by cron.** The same keywords go into the curl file of [job handling 5.3](reports_job_handling.md#53-variant-a--schedule-through-rwservlet)
(`data = "destype=mail&desformat=pdf"`, `data-urlencode = "desname=..."`,
`data-urlencode = "from=..."`, `data-urlencode = "subject=..."`) or into the
`cmdfile` of job handling 5.2. With variant B the wrapper must not set `desname` to a
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

## 6. Failure mail to the ticket system

**Question:** can `cgicmd.dat` set a generic "send a mail on failure" for
every report call, so that a failing report opens a ticket in the customer's
ticket system by mail?

**Answer: yes – per key, confirmed (live) 2026-11-11.** `notifyfailure=` is a
normal keyword and can be part of every key, including the generic `default`
key. There is no single setting for *all* requests: Oracle's `cgicmd.dat`
knows only `%0`–`%9`, `%*`, `%D`, `%P`, and `rwserver.conf` has no default
recipient. Requests without `cmdkey` only get a mail when they bring
`notifyfailure=` themselves.

### 6.1 Live results

SMTP sink on `127.0.0.1:2525` (7.1), `mailServer value="127.0.0.1:2525"`,
own note files, POST requests against rwservlet. A failing report means an
unknown report name (`REP-56132`) unless noted.

| Case | Result |
|---|---|
| `notifyfailure=` only in the request (`cmdkey=default`, passed on by `%*`) | failure mail to that address |
| `notifysuccess=` in the request, report OK | one success mail |
| key `default: server=repserver01 %* authid=... notifyfailure=tickets@...` | failure mail to the key address |
| the same key, request also sends `notifyfailure=url-fail@...` | mail only to the **key** address |
| key with `notifyfailure=` **before** `%*`, request sends another address | mail only to the **key** address – the key wins in both orders, a caller cannot redirect it |
| key `default` with `notifyfailure`, report OK | no mail |
| `destype=cache` (synchronous call from the browser), failing | failure mail as well |
| runtime errors: `REP-56133` (write directory), `REP-501` (DB login) | failure mail with the REP text in `&errorString` |
| request rejected before a job exists: wrong `authid` → `REP-50171` | **no mail** |
| `jobname=SALES_DAILY` in the request | subject `Job SALES_DAILY notification from Reports Server`, `&jobName` = `SALES_DAILY` |
| every failing request | **4 mails**, about one second apart – the `<job ... retry="3"/>` of `rwserver.conf` (1 try + 3 retries); `failedJobs` rose by **1** per request |
| change in `cgicmd.dat` | effective only after a **restart of WLS_REPORTS** (a restart of `repserver01` was not enough) – or at once with `<reloadkeymap>yes</reloadkeymap>` in `rwservlet.properties` (live, [reports_rwservlet_properties.md §3](reports_rwservlet_properties.md#3-reloadkeymap--cgicmddat-changes-without-a-restart)) |

The failure mail as it arrived (test host, own note file without header):

```
From: reports-noreply@pipperr.local
To: tickets@pipperr.local
Subject: Job nosuch.rdf notification from Reports Server
Content-Type: text/plain; charset=us-ascii

TICKET Reports job failed
job=nosuch.rdf
server=repserver01
finished=11/11/26, 1:16:16 PM
error=The report terminated with error:
REP-69: An internal error occurred
REP-56132: Access is denied to the report definition file.
.
```

### 6.2 Set-up for a ticket system

1. **Mailbox of the ticket system** as recipient, e.g.
   `reports-tickets@<customer domain>`. The subject is fixed (`Job <jobname>
   notification from Reports Server`, Oracle message catalogue, the same text
   for success and failure) – route in the ticket system by **recipient** and
   **sender**, not by subject.
2. **Sender** in `rwserver.conf` (section 4), an address the relay and the
   ticket system accept, and the own fail note (3.2):

   ```xml
   <notification id="mailNotify" class="oracle.reports.server.MailNotify">
      <property name="succnotefile" value="succnote.txt"/>
      <property name="failnotefile" value="/u01/app/oracle/domains/fr_domain/config/fmwconfig/components/ReportsServerComponent/repserver01/failnote_ticket.txt"/>
      <property name="sender" value="reports-noreply@pipperr.local"/>
   </notification>
   ```

3. **Own fail note** with fields the ticket system can parse – no `/` header
   lines (they would land in the mail):

   ```
   Oracle Reports job failed
   job=&jobName
   server=&serverName
   finished=&timeFinished
   error=&errorString
   ```

4. **`notifyfailure=` in every key of `cgicmd.dat`**, including the generic
   `default` key (one key per line, keys separated by an empty line):

   ```
   default: server=repserver01 %* authid=RepRunner/<REPRUNNER_PASSWORD> notifyfailure=reports-tickets@pipperr.local

   monthly_sales: report=monthly_sales.rdf destype=cache desformat=pdf server=repserver01 %* authid=RepRunner/<REPRUNNER_PASSWORD> notifyfailure=reports-tickets@pipperr.local jobretry=0
   ```

   `jobretry=0` gives one ticket per failed request instead of 1 + `retry`
   (6.3).

   The key value wins over a value from the request (6.1), so a caller can
   neither switch the ticket off nor redirect it.
5. **Job name for the ticket:** without `jobname=` the subject and
   `&jobName` show the report file name. Callers that send `jobname=` get a
   readable ticket title.
6. **Restart:** `rwserver.conf` → Reports server; `cgicmd.dat` → WLS_REPORTS.
7. **Test** with a report name that does not exist (`report=nosuch.rdf`) –
   harmless, gives `REP-56132` and the failure mail.

### 6.3 Limits – what does NOT open a ticket

- **One failure = several mails** while `retry` is set: with `retry="3"` the
  ticket system gets 4 mails for one failed request. **Best fix: `jobretry=0`
  in the key that sends `notifyfailure`** – one mail per failed request, the
  other jobs keep `retry="3"`. Live 2026-11-11: `jobretry=0` in the key = 1
  mail (also when the request sends `jobretry=2`); `retry="0"` in
  `rwserver.conf` = 1 mail, but only after a restart of the Reports server.
  Details and the "retry does not take" checklist:
  [reports_rwservlet_properties.md §5](reports_rwservlet_properties.md#5-job-retry--job-retry-in-rwserverconf-and-jobretry).
- **No job, no mail:** a rejected request (`REP-50171` wrong login,
  `REP-56071` missing role), a Reports server or WLS_REPORTS that is down,
  a full queue. These cases need the monitoring of
  [getserverinfo](reports_monitoring_getserverinfo.md) (CRITICAL on no
  answer / `<error>`).
- **Requests without `cmdkey`** get no ticket unless they send
  `notifyfailure=` themselves.
- **`rwrun`** runs without the Reports server and reads `rwbuilder.conf`
  (section 5) – the keys of `cgicmd.dat` do not apply.
- **Cron variant B** ([job handling 5.2](reports_job_handling.md#52-variant-b--cron-with-rwclientsh-recommended)):
  the wrapper sees the exit code of `rwclient` – it can send the ticket mail
  itself on `rc≠0`, independent of the Reports mail set-up.
- Engine crash during a job, mail relay down: not tested.

## 7. Debugging

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

   `verify error` = the relay certificate is not trusted (2.2, TLS trust).

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
   dual`) with the key from section 5. Then:
   - the job status as admin with `showjobs queuetype=past` ([job handling section 6](reports_job_handling.md#6-watching-and-cancelling-jobs)) –
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
   `rwserver.conf` – the server passes only the properties of 2.1.

Typical errors (from the JavaMail / SMTP answers – to be confirmed in the
live test):

| Message | Cause |
|---|---|
| `hostName = %MAILSERVER_NAME%` at the start | template value never set, or set in the `rwserver.conf` of the server not in use (3.1 table: `inprocess` no / yes) |
| `Connection refused` / timeout | firewall to the relay, wrong port, relay only on 587 / 465 |
| `530 Must issue a STARTTLS command first` | relay wants STARTTLS – 2.2 b) (with login) |
| `535 Authentication failed` | `mailUserName` / `mailPassword` wrong, or the relay wants the full address as user |
| `550` / `553 sender rejected`, `relay access denied` | `from=` missing (default `oracle@<host>`) or not allowed; Reports host not allowed on the relay |
| `PKIX path building failed` | relay certificate (internal CA) not in the JDK trust store |

### 7.1 Test without a mail relay – local SMTP sink

The live tests of 2026-11-11 used a tiny SMTP receiver on the Reports host:
it accepts every mail on `127.0.0.1:2525` and writes it into a file – nothing
leaves the host. Only for tests, on a test system.

```python
#!/usr/bin/env python3
# smtp_sink.py <dir> - SMTP sink on 127.0.0.1:2525, every mail -> <dir>/<ms>.eml
import socketserver, sys, os, time
OUT = sys.argv[1]
class H(socketserver.StreamRequestHandler):
    def w(self, s): self.wfile.write((s + "\r\n").encode())
    def handle(self):
        self.w("220 sink ESMTP"); env = []; data = None
        while True:
            line = self.rfile.readline()
            if not line: return
            l = line.decode("utf-8", "replace").rstrip("\r\n"); u = l.upper()
            if data is not None:
                if l == ".":
                    fn = os.path.join(OUT, "%d.eml" % int(time.time() * 1000))
                    open(fn, "w").write("X-Envelope: %s\n" % " | ".join(env) + "\n".join(data) + "\n")
                    data = None; env = []; self.w("250 OK queued")
                else:
                    data.append(l[1:] if l.startswith("..") else l)
                continue
            if u.startswith("EHLO"): self.w("250-sink"); self.w("250 8BITMIME")
            elif u.startswith("HELO"): self.w("250 sink")
            elif u.startswith(("MAIL FROM", "RCPT TO")): env.append(l); self.w("250 OK")
            elif u == "DATA": data = []; self.w("354 end with .")
            elif u == "QUIT": self.w("221 bye"); return
            else: self.w("250 OK")
class T(socketserver.ThreadingTCPServer): allow_reuse_address = True
T(("127.0.0.1", 2525), H).serve_forever()
```

Procedure:
1. Back up `rwserver.conf` (and `cgicmd.dat`), start the sink
   (`python3 -I smtp_sink.py /tmp/mails`), check it with
   `curl --url smtp://127.0.0.1:2525 --mail-from a@pipperr.local --mail-rcpt b@pipperr.local -T file`.
2. Set `<pluginParam name="mailServer" value="127.0.0.1:2525"/>`, restart the
   Reports server, check `hostName = 127.0.0.1:2525` in
   `rwserver_diagnostic.log`.
3. Run a failing request with `notifyfailure=` (`report=nosuch.rdf`), read
   the `.eml` files.
4. Restore the files from the backup (`cmp` against the backup), restart the
   Reports server (and WLS_REPORTS after a `cgicmd.dat` change), stop the
   sink, delete the mail files.

## 8. Sources

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
