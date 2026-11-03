# 06-FormsDiag – Oracle Forms Diagnostics

**Role: analyse + fix an existing environment** (see the folder roles in the
[root README](../README.md)). On a new installation `09-Install/14-oracle_setup_forms.sh`
sets the values and `09-Install/docs/90-oracle_validate.md` calls these scripts
read-only as acceptance; `10-Monitoring/` uses them as a data source.

How Forms works on the server (servlet, listener, `frmweb` per session,
runtime pooling, timeout chain, memory, logs):
[forms_runtime_architecture.md](../80-FMW-Architecture/forms_runtime_architecture.md).
"Forms is slow" – which layer, which number, which setting:
[forms_performance_analyse_tuning.md](../80-FMW-Architecture/forms_performance_analyse_tuning.md).

---

## 1. Overview – and what is NOT here

| Script | Question it answers |
|---|---|
| `forms_settings.sh` | Is the Forms configuration complete and consistent? Files actually used, binaries + libraries, `FORMS_PATH`, `default.env` vs. `environment.conf`, config sections and what they inherit, `jacob.jar` (signature, activation, DLL sizes) |
| `forms_perf_settings.sh` | Do the session / runtime parameters fit together and follow Oracle's rules? Timeout chain, `maxRuntimeProcesses`, runtime pooling incl. inheritance from `[default]`, startup parameters, `time-taken` in the access log; values vs. `environment.conf` (what a `14-` re-run would write, [section 6](#6-sync-with-the-installation-09-install14-)). `--apply` changes single keys in one section, `--fix-prestart` moves pooling out of `[default]`, `--fix-accesslog` adds `time-taken` to the WLS_FORMS access log |
| `forms_perf_analyse.sh` | How does the server carry its load? `frmweb` per config section (pool vs. session), memory vs. RAM and limit, access log per section / status, Forms logs by ODL level, crash dumps |

Not duplicated here:

| Need | Script |
|---|---|
| WLS_FORMS JVM heap (servlet / listener – not the sessions) | `02-Checks/weblogic_performance.sh` |
| Search all logs, tail | `03-Logs/grep_logs.sh 'FRM-'`, `03-Logs/tail_logs.sh` |
| `uifont.ali` / fonts | `04-ReportsFonts/` |
| DB connectivity (ORA-) | `02-Checks/db_connect_check.sh` |
| `TNS_ADMIN` of `default.env` and of every running `frmweb` | `02-Checks/tns_admin_check.sh` |
| Signing / re-signing `jacob.jar`, expiry monitoring of the code-signing certificate | `09-Install/14-oracle_setup_forms.sh --apply [--resign]`, `10-Monitoring/cert_expiry_check.sh` – [08-SSL Code Signing](../08-SSL/README.md#code-signing-jacobjar) |
| Response time seen by the client (Nginx `rt=` / `urt=`) | Nginx `access.log` – [forms_performance_analyse_tuning.md §2](../80-FMW-Architecture/forms_performance_analyse_tuning.md#2-measuring-per-layer) |
| Start / stop WLS_FORMS | `01-Run/startStop.sh` |

Shared helpers: [forms_lib.sh](forms_lib.sh) (sourced; `frm_*`: WLS_FORMS
server/PID, formsweb.cfg / default.env of the deployed application, value of
a key in a section **with inheritance** from `[default]`, set/unset a key in
one section, `frmweb` processes per section, session-timeout of the
servlet). Also used by `09-Install/14-oracle_setup_forms.sh`.

---

## 2. Recommended order

```
1. forms_settings.sh          configuration complete?
2. forms_perf_settings.sh     parameters coherent? (prestart, timeouts, limit)
3. forms_perf_analyse.sh      load – best during real use
   + Nginx access.log rt vs. urt: server side or network / client?
     (method: forms_performance_analyse_tuning.md §6)
4. fix, e.g.
   forms_perf_settings.sh --apply --fix-prestart webstart
   forms_perf_settings.sh --apply --section default --set maxRuntimeProcesses=200
   + ./01-Run/startStop.sh stop WLS_FORMS --apply && ./01-Run/startStop.sh start WLS_FORMS --apply
```

---

## 3. forms_settings.sh

```bash
./06-FormsDiag/forms_settings.sh
./06-FormsDiag/forms_settings.sh --cfg /path/to/formsweb.cfg
```

Read-only.

| Section | Checks |
|---|---|
| Configuration Files | `formsweb.cfg` of the deployed application (`servers/<WLS_FORMS>/applications/formsapp_*/config/`), its `envFile` (default.env), instance `forms1` with `webutil.cfg`, `ftrace.cfg`, `forms.conf` |
| Forms Binaries | version from `inventory/registry.xml`; `frmweb`, `frmcmp_batch`, `frmbld` in `$ORACLE_HOME/bin`; `ldd frmweb` with the `LD_LIBRARY_PATH` of default.env → FAIL on missing libraries |
| FORMS_PATH | each directory: exists, number of fmx / mmx / plx+pll; `FORMS_CUSTOMER_DIR` contained |
| default.env | `ORACLE_HOME` = environment.conf, `TNS_ADMIN` with `tnsnames.ora`, `TMPDIR` = `FORMS_TMP` and exists, `PATH` entries exist, `NLS_LANG` (INFO for `UTF8` = old CESU-8 vs. `AL32UTF8`), `FORMS_TRACE_DIR` |
| Config Sections | per section: `serverURL`, `form`, WebUtil, `prestartRuntimes` **own or inherited from [default]** |
| WebUtil / JACOB | only if `jacob.jar` is installed: sections that load it (`WebUtilArchive`, inherited), signature (signer, timestamp – without timestamp: expiry, WARN < 90 days, FAIL expired), signed but loaded by no section → WARN, unsigned but loaded → WARN (Java Web Start blocks it), `extensions.jnlp` entry active, JACOB DLLs below `$ORACLE_HOME/forms/webutil` = size in `webutil.cfg` `install.syslib` (else FAIL) |
| Runtime Overview | WLS_FORMS PID, number of `frmweb` |

## 4. forms_perf_settings.sh

```bash
./06-FormsDiag/forms_perf_settings.sh
./06-FormsDiag/forms_perf_settings.sh --apply --fix-prestart webstart
./06-FormsDiag/forms_perf_settings.sh --apply --section default --set maxRuntimeProcesses=200
./06-FormsDiag/forms_perf_settings.sh --apply --section sepwin --unset heartBeat
./06-FormsDiag/forms_perf_settings.sh --cfg /copy/formsweb.cfg --apply ...     # test on a copy
```

| Section | Rule (Oracle 14.1.2) |
|---|---|
| Timeout Chain | per section: `heartBeat` (minutes, default 2) < `FORMS_TIMEOUT` of its envFile (minutes, default 15, valid 3–1440) → else FAIL; `heartBeat` < WLS `session-timeout` (formsapp.ear, 120 min) → else WARN; `heartBeat` < 0.5 → WARN (network traffic) |
| Global Parameters | `maxRuntimeProcesses` 0/unset → WARN ("vulnerable to Denial of Service") with the RAM proposal (`frm_mrp_proposal`); `--set maxRuntimeProcesses=` also writes `FORMS_MAX_RUNTIME_PROCESSES` back to `environment.conf`; differs from it → WARN; `allowNewConnections=FALSE` → WARN; global keys set in a named section → WARN (only read from `[default]`) |
| Runtime Pooling | table of the sections with pooling (own / from default, Init, Min, Increment, Timeout), expected number of pooled `frmweb`; `prestartRuntimes` in `[default]` → WARN with Oracle's quote; `prestartMin > prestartInit` → WARN; sync with `FORMS_PRESTART_SECTION` / `FORMS_PRESTART_*` (WARN: other values, own pool in another section – lost at the next `14-`); WARN when the FSAL clients of the URL distribution (`FORMS_CLIENT_CONFIG`) start another section than the pooled one |
| Startup / Network | `networkRetries` (default 0), `gzipCompressApplet` (INFO: TRUE shortens start-up), `idleTimeout` |
| Access Log | `elf-fields` of WLS_FORMS in `config.xml`: `time-taken` present → OK, else WARN + `--fix-accesslog` |

`--apply` (backup with `backup_file`, python edit of one section only –
other sections, comments and Oracle entries stay):

| Option | Effect |
|---|---|
| `--section NAME --set KEY=VALUE` | change or add the key in that section (repeatable) |
| `--section NAME --unset KEY` | remove the key from that section – it inherits from `[default]` again |
| `--fix-prestart NAME` | copy the effective `prestart*` values into `[NAME]`, remove them from `[default]`; hint to set `FORMS_PRESTART_SECTION=NAME` in environment.conf so a re-installation (14-) keeps it |
| `--fix-accesslog` | WLST online: access log of WLS_FORMS in extended format with `time-taken` (keeps the other fields). Dynamic – WebLogic rotates `access.log` and writes a new `#Fields` header, no restart; entries appear after ~8 KB (buffer) (**confirmed (live)** 2026-10-23). New domains get it from `09-Install/08-` (in `config.xml` after `writeDomain`, since 2026-11-03). What `time-taken` measures: [forms_runtime_architecture.md §6.1](../80-FMW-Architecture/forms_runtime_architecture.md#61-accesslog-and-time-taken) |

Pooling changes need a WLS_FORMS restart (read only at servlet start).

## 5. forms_perf_analyse.sh

```bash
./06-FormsDiag/forms_perf_analyse.sh
./06-FormsDiag/forms_perf_analyse.sh --lines 10000
./06-FormsDiag/forms_perf_analyse.sh --no-log
```

| Section | Content |
|---|---|
| frmweb per Config Section | count, RSS sum / max, **client** = connection from the WLS_FORMS JVM (Listener servlet) = session, **logged on** = any other connection (Oracle Net), prestart Init of the section; pool = no client connection; > 20 processes without a session → WARN. Criterion **confirmed (live)** 2026-11-03, see below |
| Memory and Session Limit | RAM, WLS_FORMS RSS, frmweb RSS, average RSS of real sessions and how many fit; `maxRuntimeProcesses` unset → WARN, >= 90 % used → WARN; < 10 % RAM available → WARN |
| HTTP Requests | `access.log` columns from its `#Fields` header: frmservlet requests per `config=`, lservlet requests, HTTP status, 5xx → WARN; response time with a `time-taken` field (the **last** `#Fields` header counts): frmservlet avg/max, **lservlet** avg/max and requests ≥ 2 s (every round trip of a running session); field missing → hint `--fix-accesslog`. Check of the field itself: `forms_perf_settings.sh` section Access Log |
| Forms Logs | `WLS_FORMS-diagnostic.log`, `formsapp-diagnostic.log`, `WLS_FORMS.out`: ERROR/WARNING lines by message id (top 5), FRM `[NOTIFICATION]`s separately (runtime pool, servlet start), ORA-, OutOfMemoryError |
| Crash Dumps | files changed in `FORMS_TRACE_DIR` (default `$DOMAIN_HOME/system_component/FORMS/<instance>/trace`) in the last 7 days |
| Recommendations | prestart fix, session limit, memory, heap (02-Checks), FRM/ORA, 5xx, dumps |

---

## 6. Sync with the installation (`09-Install/14-`)

On a new installation `14-oracle_setup_forms.sh` writes the Forms
configuration from `environment.conf`; on an existing one these scripts
check it. A value changed only in the domain (EM, by hand, `--apply` here)
is **overwritten by the next `14- --apply`** – the scripts say where that
would happen, `--set maxRuntimeProcesses` and `--fix-prestart` write / name
the `environment.conf` variable.

| Setting | `14-` writes from (`environment.conf`) | Checked by |
|---|---|---|
| `maxRuntimeProcesses` (`[default]`) | `FORMS_MAX_RUNTIME_PROCESSES`, empty = RAM proposal `frm_mrp_proposal` (`forms_lib.sh`) | `forms_perf_settings.sh` Global Parameters (differs → WARN; `--set` writes it back) |
| runtime pooling | `FORMS_PRESTART_SECTION` + `FORMS_PRESTART_INIT` / `_MIN` / `_INCREMENT` (5 / 4 / 1), never in `[default]` | `forms_perf_settings.sh` Runtime Pooling (other values / other section → WARN; FSAL section ≠ pooled section → WARN) |
| `TNS_ADMIN` (`default.env`) | `TNS_ADMIN` | `forms_settings.sh` default.env, `02-Checks/tns_admin_check.sh` |
| `TMPDIR` (`default.env`) | `FORMS_TMP` (directory created by `14-`) | `forms_settings.sh` default.env |
| `FORMS_PATH` (`default.env`) | `FORMS_CUSTOMER_DIR` first | `forms_settings.sh` FORMS_PATH |
| `heartBeat`, `FORMS_TIMEOUT`, `networkRetries`, `gzipCompressApplet` | not set – Oracle defaults (2 / 15 min, 0, FALSE) | `forms_perf_settings.sh` Timeout Chain, Startup / Network |
| `WebUtilArchive`, `extensions.jnlp` (`jacob.jar`), JACOB DLLs in `webutil.cfg` | `FORMS_WEBUTIL_JACOB`, `FORMS_SIGN_*` – only when signed | `forms_settings.sh` WebUtil / JACOB |
| `time-taken` in the access log | `09-Install/08-` (domain creation, not `14-`) | `forms_perf_settings.sh` Access Log |

The acceptance of a new installation (`09-Install/90-oracle_validate.sh`)
runs `forms_settings.sh` and `forms_perf_settings.sh` read-only.

---

## 7. Review 2026-10-19 – what was wrong before

| Before | Effect | Now |
|---|---|---|
| `heartbeatInterval` in seconds, default 120 | parameter does not exist – real one is `heartBeat`, minutes, default 2 | Oracle name/unit, timeout chain with `FORMS_TIMEOUT` and `session-timeout` |
| `maxEventBunchSize`, `networkRetries` default 3, `lookAndFeel`/`separateFrame` as tuning | not in the 14.1.2 parameter list / default 0 / applet desupported | removed; `networkRetries`, `gzipCompressApplet` with Oracle defaults |
| `maxRuntimeProcesses` not checked | no session limit (Oracle: DoS risk) | WARN + `--set` |
| prestart not checked | our own installation started 50 idle `frmweb` | WARN + `--fix-prestart`; 14- fixed (`FORMS_PRESTART_SECTION`) |
| `pgrep frmweb` = "active sessions" | counted the pool | per section, client / DB connection (2026-11-03: CPU criterion dropped, "with DB" counted the listener connection) |
| "max sessions = WLS_FORMS -Xmx / 80 MB" | `frmweb` runs outside the JVM heap | RAM / RSS of real sessions, heap → 02-Checks |
| `frmcmp`/`frmweb` in `$ORACLE_HOME/forms/bin` | not found → version and `ldd` silently skipped | `$ORACLE_HOME/bin`, `ldd` with default.env library path |
| `[PDF:Subset]` check | Reports topic | removed (04-ReportsFonts) |
| access.log "last numeric field = ms" | that field is `bytes` | columns from `#Fields`, time only with `time-taken` |
| `WLS_FORMS.log`, "timeout" pattern, every FRM- = error | wrong file, noise, pool notifications counted as errors | diagnostic logs, ODL level |
| copies of the file-finding helpers in each script | drifted apart | `forms_lib.sh` |

Live after the fix on the test host: 50 → 5 `frmweb` (only `[webstart]`),
smoke test 15- green.

---

## 8. Pool vs. session – live test 2026-11-03

One FSAL session on the test host (`frmsal.jar` with `$JDK_HOME` under Xvfb,
through Nginx / HTTPS, `config=standaloneapp&form=test_form`, logon typed
into the Forms logon dialog – no password in the URL / access log):

| State | TCP connections of the `frmweb` | RSS | CPU (`ps`) |
|---|---|---|---|
| pooled (`[webstart]`, 12 h old) | only a LISTEN socket (ephemeral port, IPv4 + IPv6) | 4 MB | 0 s (34 ticks) |
| session, logon dialog | LISTEN socket closed; one connection from the WLS_FORMS JVM (Listener servlet) | 30 MB | 0 s (2 ticks) |
| session, logged on (test form open) | + one connection to the DB port (`:1521`) | 39 MB, private (`RssAnon`) 7 MB | 0 s |
| client killed hard (08:13) | both connections stay; the `frmweb` ended between 08:38 and 08:39 – **~25 min**, although `FORMS_TIMEOUT` is not set (Oracle default 15 min). Cause **open** (timer granularity / heartBeat interplay?); no FRM message in `WLS_FORMS-diagnostic.log` / `formsapp-diagnostic.log` for the end | – | – |

Consequences, built into `forms_perf_analyse.sh`:
- **client** (session) = a connection whose peer is a socket of the
  WLS_FORMS JVM; **logged on** = any other connection. The old "with DB" counted
  every connection, i.e. also a session still at the logon dialog.
- CPU time is no criterion: `ps` rounds to seconds, a long-running pooled
  process had more ticks than the new session – dropped.
- The session did not come from the pool: the pool is in `[webstart]`, FSAL
  started `standaloneapp` – a new `frmweb` was started
  (`forms_perf_settings.sh` now warns about that). Switched the same day:
  `FORMS_PRESTART_SECTION="standaloneapp"` + `14- --apply` + WLS_FORMS
  restart → 5 × `frmweb …,standaloneapp`, no WARN
  ([forms_runtime_architecture.md §3](../80-FMW-Architecture/forms_runtime_architecture.md#3-runtime-pooling-prestart)).
- RSS per session: 39 MB for the small test form, of it 7 MB private – the
  rest (libraries, FMX) is shared between sessions. The 64 MB of the
  `maxRuntimeProcesses` proposal stay a conservative value; a real
  application with large forms / record groups needs its own measurement
  under load (`forms_perf_analyse.sh` shows RSS and private MB per session).

---

## 9. References

- How it works + Oracle sources: [forms_runtime_architecture.md](../80-FMW-Architecture/forms_runtime_architecture.md)
  (§3 pooling, §4 timeout chain, §5 memory, §6 logs / `time-taken`, §7 which script checks what)
- Method "Forms is slow": [forms_performance_analyse_tuning.md](../80-FMW-Architecture/forms_performance_analyse_tuning.md)
- Installation side: [09-Install/docs/14-forms-detail-settings.md](../09-Install/docs/14-forms-detail-settings.md)
- WebUtil / JACOB: [forms_jakob_webutil.md](../80-FMW-Architecture/forms_jakob_webutil.md)
