# `rwservlet.properties` – what can be set in Reports 14.1.2, and the job `retry`

The configuration file of the Reports servlet (`rwservlet`, the web entry of
Oracle Reports in WLS_REPORTS): every element of the current version with
default, meaning and a recommendation for DEV and PROD. Plus the settings
that are often looked for here but live elsewhere – above all the **job
retry** (`rwserver.conf` / `JOBRETRY`) and the key map file `cgicmd.dat`.

Live-tested on the test host on 2026-11-11 (Reports 14.1.2 + QPR 39600348,
standalone Reports server `repserver01`, secured server): `reloadkeymap`,
`<job retry>`, `JOBRETRY` in the request and in a `cgicmd.dat` key. All
changes were reverted afterwards.

Related:
- Security of the web commands (`webcommandaccess`, `<identifier>`,
  `securityId`): [81-reports_rwservlet_security.md](../09-Install/docs/81-reports_rwservlet_security.md).
- How the library writes the file: [13-reports-detail-settings.md](../09-Install/docs/13-reports-detail-settings.md), step 4.
- Failure mails and `cgicmd.dat` keys: [reports_mail_handling.md](reports_mail_handling.md).
- Engines, `engineResponseTimeOut`: [reports_engine_architecture.md](reports_engine_architecture.md).

---

## 1. Where the file is and when it is read

```
$DOMAIN_HOME/config/fmwconfig/servers/WLS_REPORTS/applications/reports_14.1.2/configuration/
    rwservlet.properties     <- this article
    cgicmd.dat               <- key map file (section 4)
    rwserver.conf            <- in-process server only (inprocess=yes)
```

- **Read when WLS_REPORTS starts.** A change needs a restart of WLS_REPORTS
  (`startStop.sh stop/start WLS_REPORTS`), not of the Reports server.
- One file per WLS_REPORTS managed server (12c had `reports_12.2.1` in the
  path).
- Another file: `-DServletPropFile=<file>` in the server start arguments of
  WLS_REPORTS (Oracle 7.3) – not used by this library.
- **XML, case-sensitive.** The schema is
  `$ORACLE_HOME/reports/dtd/rwservlet.xsd` (14.1.2 test host): an
  `xs:sequence`, i.e. a fixed element order. **Observed:** the file written
  by this library has `webcommandaccess` before `cookie` (against the
  schema order) and works – the servlet does not validate the order. Keep the
  schema order anyway for new elements.

### 1.1 What the library writes

[`09-Install/13-oracle_setup_reports.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/13-oracle_setup_reports.sh) writes the **whole file**
(test host, 2026-11-11):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rwservlet xmlns="http://xmlns.oracle.com/reports/rwservlet"
           xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <server>repserver01</server>
  <singlesignon>yes</singlesignon>
  <inprocess>no</inprocess>
  <webcommandaccess>L1</webcommandaccess>
  <cookie cookieexpire="30" encryptionkey="<REPORTS_COOKIE_KEY>"/>
</rwservlet>
```

**Caution:** a new run of `13- --apply` rewrites the file and **drops
elements set by hand** (e.g. `reloadkeymap` on a DEV system). The script
keeps a `.bak_<date>`; set such elements again after the run.

## 2. All elements (14.1.2)

Element list and order from `rwservlet.xsd` of 14.1.2 (the same as in the
12.2.1.3 book that the 14.1.2 library links for Reports). Defaults and
meanings from Oracle 12.2.1.3 §7.3, quoted in short.

| # | Element | Values / default | Meaning | DEV | PROD | Library |
|---|---|---|---|---|---|---|
| 1 | `server` | name; default `rep_<hostname>` | the Reports server the servlet sends jobs to; with `inprocess=no` an external (standalone) server of that name | name of the DEV server | name of the server | first entry of `REPORTS_SERVER_INSTANCES` |
| 2 | `singlesignon` | `yes` / `no`; default `yes` | Single Sign-On for the servlet (WebLogic login instead of the Reports login form) | `yes` | `yes` | `yes` |
| 3 | `inprocess` | `yes` / `no`; default `yes` | run the Reports server inside WLS_REPORTS (`yes`) or use the standalone server (`no`) | `no` | `no` | `no` – own JVM, own restart ([reports_engine_architecture.md](reports_engine_architecture.md)) |
| 4 | `reports_servermap` | `cluster:server;...` | maps a cluster name to a server name | – | only with Reports clusters | – |
| 5 | `cookie` | `cookieexpire` minutes, default `30`; `encryptionkey` required | lifetime and key of the cookie that keeps the encrypted DB / system login on the client | `30` | `30` | `30`, key per installation (`REPORTS_COOKIE_KEY`) |
| 6 | `defaultcharset` | NLS or IANA name | character set to decode non-ASCII characters of the URL / parameter form | only if needed | only if needed | – |
| 7 | `webcommandaccess` | `L0`, `L1`, `L2`, `NO`, `YES` | which web commands are allowed: `L0` none, `L1` end-user commands, `L2` also admin commands | `L1` | `L1` | `L1` – **never `L2`**: opens every web command without login, also through Nginx (doc 81 §7) |
| 8 | `allowhtmltags` | `yes` / `no`; default `no` | allow HTML in URL parameters – Oracle: "might lead to a security compromise" | `no` | `no` | – (default) |
| 9 | `helpurl` | URL / file; default `$ORACLE_HOME/reports/templates/help.htm` | own help page for the `HELP` keyword | – | – | – |
| 10 | `imageurl` | URL | location of generated images for JSP reports not run through rwservlet | – | – | – |
| 11 | **`reloadkeymap`** | `yes` / `no`; default **`no`** | read `cgicmd.dat` again on **every** request – Oracle: `no` in production, `yes` in testing | **`yes`** | `no` | – (default `no`); live result: section 3 |
| 12 | `dbauth` | template; default `rwdbauth.htm` | HTML template of the DB login dialog | – | – | – |
| 13 | `sysauth` | template; default `rwsysauth.htm` | HTML template of the login dialog of a secured server | – | – | – |
| 14 | `errortemplate` | template; default `rwerror.htm` | own error page (character set `iso-8859-1`) | – | optional, e.g. without internal details | – |
| 15 | `diagtags` | `diagbodytags`, `diagheadtags` | extra HTML in diagnostic / debug output | – | – | – |
| 16 | `cluster` | `clustername`, `clusternodes` | high availability (Oracle 2.4) | – | – | – |
| 17 | `oidconnection` | `oidcon_*` attributes | connection to Oracle Internet Directory | – | – | – (no OID; LDAP: [reports_user_local_ldap.md](reports_user_local_ldap.md)) |
| 18 | `allowauthid` | `yes` / `no`; default `yes` | allow `authid=` in the request; `no` = only Single Sign-On | `yes` | `yes` – our monitoring and tools send `authid` (as POST) | – (default) |
| 19 | `enabledbproxy` | `yes` / `no`; default `yes` | DB proxy feature through rwservlet | – | – | – |
| – | `trace` | `traceopts`, `tracefile`, `tracemode` | **commented out** in the 14.1.2 `rwservlet.xsd` – not available | – | – | – |

Not in this file (often searched here): the job `retry` (section 5), the
mail server (`rwserver.conf`, [reports_mail_handling.md](reports_mail_handling.md)),
`folderAccess`, engines, `<identifier>` (all `rwserver.conf`), the key map
entries (`cgicmd.dat`, section 4).

## 3. `reloadkeymap` – `cgicmd.dat` changes without a restart

**Confirmed (live) 2026-11-11:**

| State | Result |
|---|---|
| default (`reloadkeymap` missing = `no`), new key added to `cgicmd.dat` | `REP-52005: The specified key rtest does not exist in the key map file` until WLS_REPORTS is restarted (also seen in the mail test the same day) |
| `<reloadkeymap>yes</reloadkeymap>` (WLS_REPORTS restarted once after setting it), new key added to `cgicmd.dat` | the very next request with `cmdkey=rtest` used the new key – **no restart** |

```xml
  <reloadkeymap>yes</reloadkeymap>
```

- Position in the schema: after `imageurl`, before `dbauth`. At the end of
  the file it worked as well (test).
- **DEV:** `yes` – developers and admins change keys often (test reports,
  failure-mail keys).
- **PROD:** `no` (Oracle's advice, and pipperr.de: the file is read on every
  request – a small cost per request). A key change in production is a
  planned change with a WLS_REPORTS restart anyway.
- A new run of `13- --apply` removes the element again (1.1).

## 4. `cgicmd.dat` – the key map file (short)

- Same directory as `rwservlet.properties` (section 1); read by WLS_REPORTS –
  at its start, or on every request with `reloadkeymap=yes`.
- One key per line, keys separated by an empty line, `%*` passes on the
  parameters of the request (without it: `REP-50004`).
- **A keyword in the key wins over the same keyword in the request** –
  confirmed (live) 2026-11-11 for `notifyfailure` and `jobretry`
  ([reports_mail_handling.md §6.1](reports_mail_handling.md#61-live-results)).
- Security rules (no password in the URL, `authid` / `%D`, POST):
  [81-reports_rwservlet_security.md](../09-Install/docs/81-reports_rwservlet_security.md).

## 5. Job retry – `<job retry>` in `rwserver.conf` and `JOBRETRY`

### 5.1 What Oracle documents

- **`retry`** is an attribute of `<job>` in the **`rwserver.conf` of the
  Reports server that runs the job** – not of `rwservlet.properties`
  (Oracle 12.2.1.3 §7.2.1.9, schema `rwserverconf.xsd` of 14.1.2:
  `default="0"`, minimum 0):
  > "specifies the number of times to retry a job after the initial run, if
  > the job fails due to an engine crash or unexpected error. The job is
  > resubmitted to another engine the number of times specified. This
  > attribute is ignored if the job is explicitly cancelled or when
  > `jobType="rwurl"` ... If JOBRETRY is specified on the command line, it
  > takes precedence, and the retry attribute is ignored."
- **`JOBRETRY=`** (Oracle A.6.15) – keyword of `rwservlet` and `rwclient`,
  default 0: "All jobs that fail with unexpected errors (either engine crash
  or normal errors) are retried." An invalid value gives `REP-50003`.
- **This library writes `retry="3"`** ([`13-oracle_setup_reports.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/13-oracle_setup_reports.sh), doc 13)
  – decided 2026-11-11 to keep it: a short DB or engine hiccup is retried
  automatically.

### 5.2 Live results (2026-11-11)

SMTP sink + `notifyfailure` in a test key, so every try of a failing job
(`report=nosuch.rdf`, `REP-56132`) shows up as one mail:

| `rwserver.conf` `retry` | `JOBRETRY` | Mails = tries |
|---|---|---|
| 3 | – | **4** (1 + 3) |
| 3 | `jobretry=0` in the request | **1** |
| 3 | `jobretry=1` in the request | **2** |
| 3 | `jobretry=0` in the `cgicmd.dat` key | **1** |
| 3 | `jobretry=0` in the key, `jobretry=2` in the request | **1** – the key wins |
| changed to 0, **Reports server not restarted** | – | **4** – the old value still applies |
| 0, Reports server restarted | – | **1** |
| 0 | `jobretry=2` in the request | **3** |
| 0 | – , runtime error `REP-56133` (write directory) | **1** |

Further observations:
- **"Normal" REP errors are retried too** (unknown report, `REP-56132`) –
  not only engine crashes, as the `JOBRETRY` text says. Each try is one more
  notification mail; `failedJobs` rises by 1 per request.
- Directly after the restart of the Reports server the first request got
  `REP-50001: The server is initializing` – no job, no mail. Wait until the
  server answers `getserverinfo`.
- Without `<property name="sender">` in `<notification>` the mails came from
  `oracle@<host FQDN>` (default sender).

### 5.3 "retry does not take" – checklist

1. **Reports server restarted?** `retry` is read at the start of the Reports
   server (`startStop.sh stop/start <server>`) – a WLS_REPORTS restart is not
   enough (5.2: changed without restart = still 4 tries).
2. **The right `rwserver.conf`?** With `inprocess=no` (this library) it is
   `$DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent/<server>/rwserver.conf`,
   **not** the file under `servers/WLS_REPORTS/...` (that one counts only
   for `inprocess=yes`) – the same trap as the mail server
   ([reports_mail_handling.md §3.1](reports_mail_handling.md#31-which-rwserverconf)).
3. **`JOBRETRY` somewhere?** A `jobretry=` in the `cgicmd.dat` key or in the
   request overrides `retry` (5.2). Check the key line and the caller.
4. **The right `<job>` element?** `retry` belongs on the `jobType="report"`
   element; it is ignored for `rwurl`.
5. **Expectation:** a failing job is retried at once (no delay, about one
   second apart in the test), on another engine – a report that fails
   because of its own error fails every time; retry only helps against
   short outages (engine crash, DB connection).

### 5.4 Recommendation

| Use | Setting |
|---|---|
| PROD, default | `retry="3"` (library) – short outages are bridged |
| failure mails to a ticket system | keep `retry="3"` for the batch jobs, but put `jobretry=0` into the keys that send `notifyfailure` – one ticket per failed request instead of 4 |
| DEV | `retry="0"` or `jobretry=0` in the DEV keys – an error is shown at once, without repeated runs |

## 6. Sources

- Oracle Forms & Reports 14.1.2 library – "Work with Oracle Reports" links to
  the 12.2.1.3 books:
  <https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/>
- Oracle Reports 12.2.1.3, Publishing Reports to the Web:
  - [7.3 Oracle Reports Servlet Configuration File (`rwservlet.properties`)](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_conf003.htm)
  - [7.2.1.9 `job` (attribute `retry`)](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_conf002.htm)
  - [A.6.15 `JOBRETRY`](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_cla006.htm)
- Oracle Application Server Reports Services 10.1.2 (B14048), configuration
  chapter – the older original of the same section:
  <https://docs.oracle.com/cd/B25527_01/doc/frs/reports/B14048_01/pbr_conf.htm>
- Schemas of the test host (14.1.2): `$ORACLE_HOME/reports/dtd/rwservlet.xsd`,
  `$ORACLE_HOME/reports/dtd/rwserverconf.xsd`.
- pipperr.de – Oracle Reports 12c R2 on Windows, "Test 3 – KeyMap Datei
  einrichten" / "Problem REP-52005" (`reloadkeymap` for development systems):
  <https://www.pipperr.de/dokuwiki/doku.php?id=forms:oracle_reports_12c_r2_windows64>
- Sources checked on 2026-11-11.
