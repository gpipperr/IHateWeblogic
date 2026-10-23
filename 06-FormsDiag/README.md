# 06-FormsDiag – Oracle Forms Diagnostics

**Role: analyse + fix an existing environment** (see the folder roles in the
[root README](../README.md)). On a new installation `09-Install/14-oracle_setup_forms.sh`
sets the values and `09-Install/docs/90-oracle_validate.md` calls these scripts
read-only as acceptance; `10-Monitoring/` uses them as a data source.

How Forms works on the server (servlet, listener, `frmweb` per session,
runtime pooling, timeout chain, memory, logs):
[forms_runtime_architecture.md](../80-FMW-Architecture/forms_runtime_architecture.md).

---

## 1. Overview – and what is NOT here

| Script | Question it answers |
|---|---|
| `forms_settings.sh` | Is the Forms configuration complete and consistent? Files actually used, binaries + libraries, `FORMS_PATH`, `default.env` vs. `environment.conf`, config sections and what they inherit |
| `forms_perf_settings.sh` | Do the session / runtime parameters fit together and follow Oracle's rules? Timeout chain, `maxRuntimeProcesses`, runtime pooling incl. inheritance from `[default]`, startup parameters. `--apply` changes single keys in one section, `--fix-prestart` moves pooling out of `[default]` |
| `forms_perf_analyse.sh` | How does the server carry its load? `frmweb` per config section (pool vs. session), memory vs. RAM and limit, access log per section / status, Forms logs by ODL level, crash dumps |

Not duplicated here:

| Need | Script |
|---|---|
| WLS_FORMS JVM heap (servlet / listener – not the sessions) | `02-Checks/weblogic_performance.sh` |
| Search all logs, tail | `03-Logs/grep_logs.sh 'FRM-'`, `03-Logs/tail_logs.sh` |
| `uifont.ali` / fonts | `04-ReportsFonts/` |
| DB connectivity (ORA-) | `02-Checks/db_connect_check.sh` |
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
| Runtime Pooling | table of the sections with pooling (own / from default, Init, Min, Increment, Timeout), expected number of pooled `frmweb`; `prestartRuntimes` in `[default]` → WARN with Oracle's quote; `prestartMin > prestartInit` → WARN |
| Startup / Network | `networkRetries` (default 0), `gzipCompressApplet` (INFO: TRUE shortens start-up), `idleTimeout` |

`--apply` (backup with `backup_file`, python edit of one section only –
other sections, comments and Oracle entries stay):

| Option | Effect |
|---|---|
| `--section NAME --set KEY=VALUE` | change or add the key in that section (repeatable) |
| `--section NAME --unset KEY` | remove the key from that section – it inherits from `[default]` again |
| `--fix-prestart NAME` | copy the effective `prestart*` values into `[NAME]`, remove them from `[default]`; hint to set `FORMS_PRESTART_SECTION=NAME` in environment.conf so a re-installation (14-) keeps it |

Pooling changes need a WLS_FORMS restart (read only at servlet start).

## 5. forms_perf_analyse.sh

```bash
./06-FormsDiag/forms_perf_analyse.sh
./06-FormsDiag/forms_perf_analyse.sh --lines 10000
./06-FormsDiag/forms_perf_analyse.sh --no-log
```

| Section | Content |
|---|---|
| frmweb per Config Section | count, RSS sum / max, processes with an established TCP connection (DB) and with CPU time > 0, prestart Init of the section; pool = no DB connection and no CPU (**assumption**, see section 7); > 20 processes without a session → WARN |
| Memory and Session Limit | RAM, WLS_FORMS RSS, frmweb RSS, average RSS of real sessions and how many fit; `maxRuntimeProcesses` unset → WARN, >= 90 % used → WARN; < 10 % RAM available → WARN |
| HTTP Requests | `access.log` columns from its `#Fields` header: frmservlet requests per `config=`, lservlet requests, HTTP status, 5xx → WARN; response time only with a `time-taken` field (not in the default format) |
| Forms Logs | `WLS_FORMS-diagnostic.log`, `formsapp-diagnostic.log`, `WLS_FORMS.out`: ERROR/WARNING lines by message id (top 5), FRM `[NOTIFICATION]`s separately (runtime pool, servlet start), ORA-, OutOfMemoryError |
| Crash Dumps | files changed in `FORMS_TRACE_DIR` (default `$DOMAIN_HOME/system_component/FORMS/<instance>/trace`) in the last 7 days |
| Recommendations | prestart fix, session limit, memory, heap (02-Checks), FRM/ORA, 5xx, dumps |

---

## 6. Review 2026-10-19 – what was wrong before

| Before | Effect | Now |
|---|---|---|
| `heartbeatInterval` in seconds, default 120 | parameter does not exist – real one is `heartBeat`, minutes, default 2 | Oracle name/unit, timeout chain with `FORMS_TIMEOUT` and `session-timeout` |
| `maxEventBunchSize`, `networkRetries` default 3, `lookAndFeel`/`separateFrame` as tuning | not in the 14.1.2 parameter list / default 0 / applet desupported | removed; `networkRetries`, `gzipCompressApplet` with Oracle defaults |
| `maxRuntimeProcesses` not checked | no session limit (Oracle: DoS risk) | WARN + `--set` |
| prestart not checked | our own installation started 50 idle `frmweb` | WARN + `--fix-prestart`; 14- fixed (`FORMS_PRESTART_SECTION`) |
| `pgrep frmweb` = "active sessions" | counted the pool | per section, DB connection / CPU |
| "max sessions = WLS_FORMS -Xmx / 80 MB" | `frmweb` runs outside the JVM heap | RAM / RSS of real sessions, heap → 02-Checks |
| `frmcmp`/`frmweb` in `$ORACLE_HOME/forms/bin` | not found → version and `ldd` silently skipped | `$ORACLE_HOME/bin`, `ldd` with default.env library path |
| `[PDF:Subset]` check | Reports topic | removed (04-ReportsFonts) |
| access.log "last numeric field = ms" | that field is `bytes` | columns from `#Fields`, time only with `time-taken` |
| `WLS_FORMS.log`, "timeout" pattern, every FRM- = error | wrong file, noise, pool notifications counted as errors | diagnostic logs, ODL level |
| copies of the file-finding helpers in each script | drifted apart | `forms_lib.sh` |

Live after the fix on the test host: 50 → 5 `frmweb` (only `[webstart]`),
smoke test 15- green.

---

## 7. Open items

- Pool vs. session with a real client session (JWS / FSAL from Windows) –
  verify the DB-connection / CPU criterion, RSS of a real session for the
  `maxRuntimeProcesses` sizing.
- `time-taken` in the WLS_FORMS access log (extended format) – then response
  times; candidate for a WLST `--apply`.

---

## 8. References

- Background + Oracle sources: [forms_runtime_architecture.md](../80-FMW-Architecture/forms_runtime_architecture.md)
- Installation side: [09-Install/docs/14-forms-detail-settings.md](../09-Install/docs/14-forms-detail-settings.md)
- WebUtil / JACOB: [forms_jakob_webutil.md](../80-FMW-Architecture/forms_jakob_webutil.md)
