# Forms performance – analysis and tuning

"Forms is slow" – where to look, in which order, and which setting belongs
to which finding. This page is the **method**; how the parts work is in
[forms_runtime_architecture.md](forms_runtime_architecture.md) (pooling §3,
timeout chain §4, memory §5, logs §6), what the scripts check in
[06-FormsDiag/README.md](../06-FormsDiag/README.md).

Markers as in the rest of this folder: **documented** (Oracle documentation),
**confirmed (live)** (seen on the test host), **assumption**, **open**.

---

## 1. The chain of one user action

![formsperf-path](diagrams/formsperf-path.svg?v=4e954697)
<sub>Source: [diagrams/formsperf-path.prompt](https://github.com/gpipperr/IHateWeblogic/blob/main/80-FMW-Architecture/diagrams/formsperf-path.prompt) · [D2](https://github.com/gpipperr/IHateWeblogic/blob/main/80-FMW-Architecture/diagrams/formsperf-path.d2)</sub>

<details><summary>ASCII version</summary>

```ascii name=formsperf-path
 Forms client (Java, FSAL / Web Start)
   │  HTTPS                                   ← network, TLS
   ▼
 Nginx :443                                   ← access.log: rt / urt / uct
   │  HTTP 127.0.0.1, keepalive
   ▼
 WLS_FORMS  /forms/lservlet                   ← access.log: time-taken
   │  local socket
   ▼
 frmweb  (one process per session)            ← CPU, RSS (forms_perf_analyse.sh)
   │  Oracle Net (TNS_ADMIN)
   ▼
 Database                                     ← SQL / PL/SQL of the form (open, §5)
```

</details>

Every user action of a running session (key, button, navigation, commit) is
**one `lservlet` round trip**: the client sends the event, the listener
servlet hands it to `frmweb`, waits for the answer and returns it
(**documented** in principle – Forms listener servlet architecture; the
waiting is the reason why `time-taken` of `lservlet` contains the `frmweb`
and DB time, [§6.1](forms_runtime_architecture.md#61-accesslog-and-time-taken)).
A session start is different: `frmservlet?config=…` delivers the start page /
JNLP, the client loads the jars, then the first `lservlet` request takes a
`frmweb` from the pool or starts one.

---

## 2. Measuring per layer

| Layer | Where | What it shows | Tool |
|---|---|---|---|
| Client → Nginx → client | Nginx `access.log`, field `rt=` | whole request as Nginx sees it, incl. sending the answer to the client (s) | `09-Install/nginx-wls.conf.template` (format `ihw_timing`, since 2026-11-03) |
| Nginx → WebLogic | Nginx `access.log`, `urt=` / `uct=` | WebLogic answer incl. transfer to Nginx / TCP connect (`0.000` with keepalive) | same |
| WebLogic | `servers/WLS_FORMS/logs/access.log`, `time-taken` | time WebLogic needed to complete the request (s) | `06-FormsDiag/forms_perf_analyse.sh` (avg / max, `lservlet` ≥ 2 s) |
| `frmweb` | processes | count per config section, pool vs. session, RSS, CPU, DB connection | `forms_perf_analyse.sh` |
| WLS_FORMS JVM | heap, GC | servlet / listener only – **not** the sessions | `02-Checks/weblogic_performance.sh` |
| Database | `v$session`, ASH / AWR | SQL and waits of the `frmweb` sessions | manual – see §5 (open) |

Nginx line (test with a private Nginx in front of WLS_FORMS, **confirmed
(live)** 2026-11-03):

```
127.0.0.1 - - [03/Nov/2026:04:25:53 +0100] "GET /forms/frmservlet HTTP/1.1" 200 4037 "-" "curl/7.76.1" "-" rt=0.232 urt=0.232 uct=0.000
127.0.0.1 - - [03/Nov/2026:04:25:53 +0100] "GET /r HTTP/1.1" 301 169 "-" "curl/7.76.1" "-" rt=0.000 urt=- uct=-
```

`urt=-` = not proxied (redirect, static file such as the client bundle
under `/formsWeb/`). The first `frmservlet` call took 0.232 s, the second
0.003 s – the first call after a pause is not representative.

Reading the three numbers together:

| Finding | Meaning |
|---|---|
| `rt` ≈ `urt` ≈ `time-taken`, all high | the time is spent behind WebLogic: `frmweb` / database |
| `rt` ≫ `urt` | Nginx waited for the client: slow network, slow upload of the request body or download of the answer (large jar, report) |
| `urt` ≫ `time-taken` | between Nginx and WebLogic (connect, queueing in WebLogic before the request is counted) – rare on loopback (**assumption**) |
| all small, user still sees a delay | client side: JVM start, jar download (once), rendering, a Forms trigger that does client-side work (WebUtil, JACOB) |

The user's perception has no log line – ask *what* is slow: the start,
every action, one particular form / button, or a certain time of day.

---

## 3. From finding to cause

| Symptom | First check | Likely cause | Setting / fix |
|---|---|---|---|
| Start of a session slow, actions fine | `frmservlet` `time-taken`, Nginx `rt` of the jars, pool size per section | no pooled `frmweb` for this section, jar download, client JVM start | prestart in the **used** section (FSAL of the client distribution: `standaloneapp`), not `[default]` (§3 of the architecture doc); `gzipCompressApplet`; client bundle / jar cache (`40-`) |
| Every action slow for everybody | `lservlet` avg in `forms_perf_analyse.sh`, `rt` vs. `urt` | DB or host overloaded, `frmweb` CPU-bound | §5 DB; host load (CPU, swap); number of sessions vs. RAM |
| One form / one button slow | `lservlet` max, ≥ 2 s list (time of day) | SQL / PL/SQL of that action | DB (§5) – not a Forms server setting |
| Slow, but `time-taken` small | `rt` − `urt` | network / client | network path, proxy, client PC; not the server |
| Sessions end, "no response" | timeout chain | `FORMS_TIMEOUT` ≤ `heartBeat`, proxy / load-balancer idle timeout < `heartBeat` | `forms_perf_settings.sh` Timeout Chain (§4 of the architecture doc) |
| New sessions rejected / host swaps | memory section of `forms_perf_analyse.sh` | too many `frmweb`, no limit | `maxRuntimeProcesses` (§5 of the architecture doc), RAM |
| Many `frmweb` without users | pool per section | prestart in `[default]` (pool × number of sections) | `forms_perf_settings.sh --apply --fix-prestart <section>` |
| HTTP 5xx | `forms_perf_analyse.sh` HTTP status, `WLS_FORMS-diagnostic.log` | servlet errors, `frmweb` crash | Forms logs / crash dumps (§6 of the architecture doc) |

---

## 4. Settings and what they do (and do not) influence

| Setting | Where | Influences | Restart | Checked by |
|---|---|---|---|---|
| `prestartRuntimes`, `prestartInit`, `prestartMin`, `prestartIncrement`, `prestartTimeout` | formsweb.cfg, per section | start of a session (pool), memory of idle processes | WLS_FORMS (read at servlet start, **documented**) | `forms_perf_settings.sh` Runtime Pooling |
| `maxRuntimeProcesses` | formsweb.cfg `[default]` | upper limit of `frmweb` = protection of RAM | WLS_FORMS | `forms_perf_settings.sh` Global Parameters, `forms_perf_analyse.sh` |
| `heartBeat`, `FORMS_TIMEOUT`, session-timeout | formsweb.cfg / default.env / formsapp.ear | when idle sessions end, network traffic of idle clients | WLS_FORMS | `forms_perf_settings.sh` Timeout Chain |
| `networkRetries` | formsweb.cfg | retries of the client on a network error (default 0) | – | `forms_perf_settings.sh` Startup / Network |
| `gzipCompressApplet` | formsweb.cfg | size of the jar download at the start | – | same (INFO) |
| WLS_FORMS heap (`-Xmx`) | setUserOverrides.sh | servlet / listener JVM | WLS_FORMS | `02-Checks/weblogic_performance.sh` |

What does **not** help:

- **More heap for WLS_FORMS against slow forms.** `frmweb` runs outside the
  JVM; the heap serves the servlet / listener only
  ([06-FormsDiag/README.md §7](../06-FormsDiag/README.md#7-review-2026-10-19--what-was-wrong-before)).
- **A bigger prestart pool against slow actions.** The pool only shortens
  the start of a session; a running session has its own `frmweb`.
- **A lower `heartBeat` against "hanging" sessions.** It only shortens the
  keep-alive interval and adds network traffic; the cause of a hang is the
  action itself (DB) or a timeout below the `heartBeat`.

Not covered here (would need Oracle documentation or a live test first):
client-side Java settings, array fetch / record group sizes in the forms,
Forms trace (`ftrace.cfg`) for a single session.

---

## 5. Database side – open

The DB part of an `lservlet` round trip is usually the largest, but on the
test host it cannot be examined: only the prestart pool runs (6 `frmweb`
on 2026-11-03), and **a pooled `frmweb` has no DB session** – `v$session`
shows nothing for `frmweb` until a user connects (**confirmed (live)**, read-only
check 2026-11-03).

**Open** – check at a site with real users:

1. What a `frmweb` session sets in `v$session`: `program`, `module`
   (form name?), `action`, `client_info`, `client_identifier`. Only if the
   form name is visible can ASH / AWR be split per form.
2. Whether the ECID of the WebLogic request (`ctx-ecid` in `access.log`)
   reaches the database (`v$session.ecid`) – that would connect one slow
   `lservlet` line with its SQL.

```sql
-- as DBA in the PDB of the application, while users work (read-only)
SELECT program, module, action, client_info, client_identifier, ecid, username, count(*)
  FROM v$session
 WHERE type = 'USER' AND program LIKE 'frmweb%'
 GROUP BY program, module, action, client_info, client_identifier, ecid, username;

-- top SQL of the Forms sessions in the last 30 minutes (ASH needs the
-- Diagnostics Pack licence on EE)
SELECT sql_id, module, action, count(*) samples
  FROM v$active_session_history
 WHERE program LIKE 'frmweb%' AND sample_time > SYSDATE - 30/1440
 GROUP BY sql_id, module, action ORDER BY samples DESC FETCH FIRST 10 ROWS ONLY;
```

Licence note: ASH / AWR (`v$active_session_history`, `DBA_HIST_*`) are part
of the Diagnostics Pack; without it use Statspack or `v$sql` / `v$session`.

---

## 6. Order of work

```
1. ask: what exactly is slow (start / every action / one form), since when, for whom
2. 06-FormsDiag/forms_perf_settings.sh     settings coherent? (pool, timeouts, limit)
3. 06-FormsDiag/forms_perf_analyse.sh      load, memory, lservlet times, logs
4. Nginx access.log: rt vs. urt            server side or network / client?
5. server side → database (§5), host load
6. change ONE thing, restart if needed, compare the same numbers again
```

Fields missing? `time-taken`: `06-FormsDiag/forms_perf_settings.sh --apply
--fix-accesslog` (running domain) – new domains get it from `09-Install/08-`.
Nginx `rt=` / `urt=`: re-render the Nginx config with
`09-Install/04-root_nginx.sh --apply` (template since 2026-11-03).

---

## 7. Sources

- Oracle Forms 14.1.2 – Deploying Forms Applications: Built-in Optimization
  Features, Minimizing Forms Services Resource Requirements, formsweb.cfg
  parameters (via [forms_runtime_architecture.md §10](forms_runtime_architecture.md#10-sources))
- Nginx `ngx_http_log_module` / `ngx_http_upstream_module` – variables
  `$request_time`, `$upstream_response_time`, `$upstream_connect_time`
- WebLogic Server – Extended Log Format, field `time-taken`
