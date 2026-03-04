# Oracle FMW – Log Management Guide

Author: Gunther Pipperr | https://pipperr.de | License: Apache 2.0

> This guide describes the Oracle Forms & Reports / WebLogic logging landscape
> and explains how to use the `03-Logs/` scripts for log discovery, search,
> live monitoring, cleanup, and archiving.

---

## Table of Contents

1. [Log Landscape – Overview](#1-log-landscape--overview)
2. [Log Types and Formats](#2-log-types-and-formats)
3. [Log File Locations](#3-log-file-locations)
4. [Key Log Files – What to Look For](#4-key-log-files--what-to-look-for)
5. [Common Error Code Patterns](#5-common-error-code-patterns)
6. [Log Level Configuration](#6-log-level-configuration)
7. [Scripts Reference](#7-scripts-reference)
8. [Step-by-Step: Fresh Diagnostic Baseline](#8-step-by-step-fresh-diagnostic-baseline)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Log Landscape – Overview

An Oracle Forms & Reports 14c installation produces logs from several independent
subsystems. Errors may be split across multiple files and you need to know where
to look for each component:

```
WebLogic Domain ($DOMAIN_HOME)
│
├── servers/
│   ├── AdminServer/logs/         ← Domain admin server (startup, deploy, WLST)
│   ├── WLS_REPORTS/logs/         ← Reports managed server (REP-* errors here)
│   └── WLS_FORMS/logs/           ← Forms managed server (FRM-* errors here)
│
├── diagnostics/logs/             ← ODL-format component diagnostic logs
│   ├── AdminServer/
│   ├── WLS_REPORTS/
│   └── WLS_FORMS/
│
├── config/fmwconfig/components/
│   └── ReportsToolsComponent/
│       └── reptools1/            ← Reports Engine process logs (rwEng*.log)
│
└── nodemanager/                  ← Node Manager log (server start/stop)
```

> **Key insight:** The WLS managed server log (`WLS_REPORTS.log`) only shows the
> wrapper exception (`REP-1800`). The underlying Reports Engine error (`REP-3000`,
> `REP-0069`, `REP-1924`, etc.) is in the Reports Engine diagnostic log under
> `config/fmwconfig/components/ReportsToolsComponent/reptools1/`.

---

## 2. Log Types and Formats

### 2.1 WebLogic Server Logs (plain text)

File pattern: `<ServerName>.log`, `<ServerName>.log00001`, `<ServerName>.out`

```
####<Mar 4, 2026 3:00:00,000 PM CET> <Error> <oracle.reports.servlet> \
<WLS_REPORTS> <ExecuteThread: '1'> <<WLS Kernel>> <> <> \
<1709557200000> <BEA-000000> <REP-1800: Error running report.>
```

Fields (angle-bracket separated): timestamp, severity, subsystem, server, thread,
user, transaction, diagnostic context, timestamp (epoch), message-id, message.

### 2.2 ODL Diagnostic Logs

Located in `$DOMAIN_HOME/diagnostics/logs/`. Component diagnostic logs written
by Oracle Diagnostic Logging (ODL). More detailed than the WLS log.

```
[2026-03-04T15:00:00.000+01:00] [WLS_REPORTS] [ERROR] [REP-3000] \
[oracle.reports.engine] [tid: ExecuteThread: '1'] [userId: <anonymous>] \
[ecid: ...] ... Unable to open the file ...
```

### 2.3 Reports Engine Log

File pattern: `rwEng-<PID>.log` or `repserver.log` under the
`ReportsToolsComponent/reptools1/` path. Plain text, contains the raw Reports
Server and Engine messages — **this is the primary log for all REP-* errors**.

### 2.4 Node Manager Log

`$DOMAIN_HOME/nodemanager/nodemanager.log` — plain text, records server lifecycle
events (start, stop, crash, restart). Check here if managed servers fail to start.

---

## 3. Log File Locations

### Quick reference

| Component | Active Log | Rotated Logs |
|---|---|---|
| AdminServer | `servers/AdminServer/logs/AdminServer.log` | `AdminServer.log00001` ... |
| AdminServer stdout | `servers/AdminServer/logs/AdminServer.out` | — |
| WLS_REPORTS | `servers/WLS_REPORTS/logs/WLS_REPORTS.log` | `WLS_REPORTS.log00001` ... |
| WLS_REPORTS stdout | `servers/WLS_REPORTS/logs/WLS_REPORTS.out` | — |
| WLS_FORMS | `servers/WLS_FORMS/logs/WLS_FORMS.log` | `WLS_FORMS.log00001` ... |
| ODL / Reports | `diagnostics/logs/WLS_REPORTS/*.log` | — |
| Reports Engine | `config/fmwconfig/components/ReportsToolsComponent/reptools1/*.log` | — |
| Node Manager | `nodemanager/nodemanager.log` | — |

### Retrieve all log paths dynamically

```bash
# All active WLS logs in the domain:
find $DOMAIN_HOME/servers -name "*.log" -not -name "*.[0-9]*" | sort

# Reports Engine logs only:
find $DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent \
     -name "*.log" | sort

# Largest logs first:
find $DOMAIN_HOME -name "*.log" -o -name "*.out" 2>/dev/null \
  | xargs du -sh 2>/dev/null | sort -rh | head -20
```

---

## 4. Key Log Files – What to Look For

### AdminServer.log – domain-level events

- Deployment errors for Forms/Reports applications
- DataSource connection pool issues (DB connect failures)
- WLST connection and script errors
- Certificate and SSL handshake errors

### WLS_REPORTS.log – Reports servlet + server

- `REP-1800` — generic formatter error (wrapper; look deeper for root cause)
- `REP-0050` — error connecting to Reports Server
- `REP-0262` — cannot connect to job repository
- Java stack traces from `oracle.reports.servlet`
- `BEA-*` WebLogic infrastructure errors

### Reports Engine log (`rwEng-*.log`, `repserver.log`)

- `REP-3000` — internal rendering error (font missing, file missing)
- `REP-0069` — engine communication error
- `REP-1924` — font file cannot be found (TTF not in REPORTS_FONT_DIRECTORY)
- `REP-1800` — formatter chain failure (source here, not in WLS_REPORTS.log)
- `REP-0110` — datamodel execution error (SQL issue)
- Segfault / core dump references (rwrun crashed)

### WLS_FORMS.log – Forms servlet + server

- `FRM-40735` — trigger failure
- `FRM-41214` — memory error
- Forms session startup and security errors

### nodemanager.log – server lifecycle

- `FAILED_NOT_RESTARTABLE` — server crashed and Node Manager gave up restarting
- Process exit codes on crash
- Startup command lines (useful for verifying JAVA_OPTIONS)

---

## 5. Common Error Code Patterns

| Code | Component | Typical Cause |
|---|---|---|
| `REP-1800` | Reports | Generic formatter error – check Engine log for root cause |
| `REP-3000` | Reports | Internal engine error – font/file/DB access failure |
| `REP-1924` | Reports | Font file not found – TTF missing from REPORTS_FONT_DIRECTORY |
| `REP-0069` | Reports | Engine unreachable – server not started or crashed |
| `REP-0050` | Reports | Cannot connect to Reports Server – check nodemanager, ports |
| `REP-0262` | Reports | Job repository unavailable – DB connection issue |
| `FRM-40735` | Forms | PL/SQL trigger failure |
| `BEA-000337` | WebLogic | Failed to deploy application |
| `BEA-000362` | WebLogic | Server failed to bind port (port conflict) |
| `ORA-12541` | Oracle DB | TNS: no listener – DB not running or wrong hostname |
| `ORA-01017` | Oracle DB | Invalid username/password |

### Grep patterns for quick scan

```bash
# All REP errors (excluding the wrapper REP-1800 when looking for root cause):
grep -h "REP-[0-9]\{4\}" $DOMAIN_HOME/servers/WLS_REPORTS/logs/WLS_REPORTS.log

# Java exceptions with 5 lines of context:
grep -A5 "Exception\|Error\|SEVERE" \
     $DOMAIN_HOME/servers/WLS_REPORTS/logs/WLS_REPORTS.log | head -100

# Reports Engine – all errors today:
find $DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent \
     -name "*.log" -newer /tmp -exec grep "REP-" {} \;

# Node Manager – server restart events:
grep "FAILED\|STARTED\|restart" $DOMAIN_HOME/nodemanager/nodemanager.log
```

---

## 6. Log Level Configuration

WebLogic and Oracle Reports use **Java Util Logging (JUL)** / **Oracle Diagnostic
Logging (ODL)** with the following severity levels (highest to lowest):

```
SEVERE  →  ERROR   – production errors visible in WLS log
WARNING →  WARNING – non-fatal issues, also visible in WLS log
INFO    →  INFO    – informational (default minimum in production)
CONFIG  →  CONFIG  – configuration settings at startup
FINE    →  TRACE   – low-level tracing (verbose!)
FINER   →  TRACE16 – component internals
FINEST  →  TRACE32 – maximum detail (use only for targeted debugging)
```

### Important loggers for Oracle Reports

| Logger | Purpose | Recommended level |
|---|---|---|
| `oracle.reports` | All Reports components | `INFO` (production) / `FINE` (debug) |
| `oracle.reports.engine` | Reports Engine renderer | `INFO` / `FINE` |
| `oracle.reports.servlet` | Reports Servlet | `INFO` |
| `oracle.reports.fonts` | Font subsystem (uifont.ali) | `FINE` (font issues) |
| `weblogic.xml.stax` | XML parsing | `WARNING` |

> **Warning:** Setting `oracle.reports` to `FINE` or `FINEST` generates several
> hundred MB of log output per hour on an active server. Only enable for short,
> targeted diagnostic sessions and reset immediately afterwards.

### Changing log level at runtime

Use `setLogLevel.sh` (requires AdminServer running + WebLogic credentials):

```bash
./03-Logs/setLogLevel.sh --query                              # Show current levels
./03-Logs/setLogLevel.sh --level FINE --logger oracle.reports # Enable debug
./03-Logs/setLogLevel.sh --level INFO --logger oracle.reports # Reset to normal
```

For font-related issues specifically, set the log level before generating a test
report, then check the Reports Engine log for font resolution details.

### WebLogic log rotation settings

WebLogic rotates logs based on:
- **Size** (default: 5000 KB per file, up to 7 files)
- **Time** (e.g. daily at midnight)

Configure in: Admin Console → Environment → Servers → WLS_REPORTS →
Logging → Rotation.

The active log is always the file without a number suffix (`WLS_REPORTS.log`).
Rotated files are `WLS_REPORTS.log00001`, `WLS_REPORTS.log00002`, etc.

---

## 7. Scripts Reference

All scripts read `environment.conf` for path configuration. Scripts that modify
files require `--apply`; without it they run in **dry-run** (preview) mode.

| Script | Purpose | Mode |
|---|---|---|
| `get_all_logs.sh` | Inventory all log files with size, age, component | read-only |
| `grep_logs.sh` | Search pattern across all relevant logs (incl. rotated + gz) | read-only |
| `tail_logs.sh` | Live-follow multiple logs simultaneously (tmux or plain tail) | read-only |
| `cleanLogFiles.sh` | Truncate active logs, delete old rotated logs | `--apply` required |
| `archive_logs.sh` | Compress rotated logs with gzip to save disk space | `--apply` required |
| `setLogLevel.sh` | Query / set Java logger levels via WLST (server must run) | `--apply` required |

### get_all_logs.sh

```bash
./03-Logs/get_all_logs.sh
```

Lists all logs grouped by component (AdminServer, WLS_REPORTS, WLS_FORMS,
ReportsEngine, NodeManager, ODL). Shows size and last modified date per file.
Warns if a log exceeds `LOG_MAX_SIZE_MB` (default 500 MB) or has not been
written to for more than `LOG_RETAIN_DAYS` days (stale rotation check).
Prints disk-usage totals per group at the end.

### grep_logs.sh

```bash
./03-Logs/grep_logs.sh "REP-3000"
./03-Logs/grep_logs.sh "REP-" --component WLS_REPORTS --since 2026-03-04
./03-Logs/grep_logs.sh "Exception" --context 5 --level ERROR
```

Options:

| Option | Description |
|---|---|
| `<pattern>` | Search pattern (required, supports regex) |
| `--component AdminServer\|WLS_REPORTS\|WLS_FORMS\|all` | Limit search scope (default: all) |
| `--since YYYY-MM-DD` | Only search files modified on or after this date |
| `--context N` | Show N lines of context around each match (default: 3) |
| `--level ERROR\|WARNING\|INFO` | Pre-filter by severity keyword |

Searches active logs **and** all rotated files (`*.log00001`…) and gzip-compressed
files (`*.gz` via `zgrep`). Output includes filename and line number for every match.
REP-/FRM-/BEA- error codes are colour-highlighted.

### tail_logs.sh

```bash
./03-Logs/tail_logs.sh                              # All relevant logs
./03-Logs/tail_logs.sh --component WLS_REPORTS      # Reports Server only
./03-Logs/tail_logs.sh --component WLS_FORMS        # Forms Server only
./03-Logs/tail_logs.sh --component all --lines 50   # All logs, 50 initial lines
./03-Logs/tail_logs.sh --no-tmux                    # Force plain tail (no tmux)
```

Options:

| Option | Description |
|---|---|
| `--component all\|AdminServer\|WLS_REPORTS\|WLS_FORMS` | Component filter (default: all) |
| `--lines N` | Initial lines shown per file at start (default: 20) |
| `--no-tmux` | Force plain `tail -f` mode even when tmux is available |

If `tmux` is available, opens a new split-pane session (or window when already
inside tmux) with one pane per log file and file names shown in pane borders
(`tiled` layout). Press `Ctrl-b d` to detach, `Ctrl-b &` to close the window.

Fallback (no tmux / `--no-tmux`): `tail -f` on all files simultaneously with
colour-filtered output: `ERROR`/`SEVERE` → red, `WARNING` → yellow, `INFO` → green,
`REP-*`/`FRM-*` error codes → red.

### cleanLogFiles.sh

```bash
./03-Logs/cleanLogFiles.sh                          # Dry-run: show what would be done
./03-Logs/cleanLogFiles.sh --apply                  # Execute cleanup
./03-Logs/cleanLogFiles.sh --retain-days 3 --apply  # Keep only last 3 days of rotated logs
./03-Logs/cleanLogFiles.sh --include-out --apply    # Also truncate *.out (stdout) files
```

Options:

| Option | Description |
|---|---|
| `--apply` | Execute the plan (default: dry-run preview) |
| `--retain-days N` | Keep rotated logs for N days (default: `LOG_RETAIN_DAYS=7`) |
| `--include-out` | Also truncate `*.out` stdout files (skipped by default) |

Rules applied:
- **Active `*.log` files** (`WLS_REPORTS.log`, `AdminServer.log`, etc.) — truncated
  to zero bytes (`truncate -s 0`). The file descriptor stays open; the running
  server continues writing to the same (now empty) file. Never deleted.
- **`*.out` files** (managed server stdout) — skipped by default; truncated only
  with `--include-out`. These files may contain JVM crash info.
- **Rotated logs** (`*.log00001`, `*.log00002`, etc.) older than `--retain-days` — deleted.
- **Reports Engine logs** under `ReportsToolsComponent/` older than `--retain-days` — deleted
  (engine creates a new log file per run; all are candidates for cleanup).
- `diagnostics/` and `nodemanager/` are **never touched**.

Dry-run shows a coloured action plan (TRUNCATE / DELETE / SKIP) with sizes and
total disk space that would be freed. Always run dry-run before `--apply`.

> **Note:** Truncating an active log is irreversible.
> Run `grep_logs.sh` first to confirm there is nothing relevant to preserve.

### archive_logs.sh

```bash
./03-Logs/archive_logs.sh                        # Dry-run: show candidates + estimated savings
./03-Logs/archive_logs.sh --apply                # Compress
./03-Logs/archive_logs.sh --min-age 7 --apply   # Only compress files older than 7 days
./03-Logs/archive_logs.sh --level 6 --apply     # Use gzip level 6 (faster, slightly larger)
```

Options:

| Option | Description |
|---|---|
| `--apply` | Execute compression (default: dry-run preview) |
| `--min-age N` | Only compress files older than N days (default: `LOG_ARCHIVE_MIN_AGE_DAYS=1`) |
| `--level N` | gzip compression level 1–9 (default: 9 = `--best`) |

Compresses rotated logs (`*.log[0-9]*`) and Reports Engine logs older than
`--min-age` using `gzip`. Active logs (`*.log` without suffix, `*.out`) and
already-compressed files (`*.gz`, `*.bz2`) are always skipped.

Dry-run shows candidates with sizes and an estimated saving (~85% typical for
WLS text logs). After `--apply`, prints actual before/after sizes and compression
percentage per file plus totals. Compressed files remain searchable via `zgrep`
and `grep_logs.sh`.

### setLogLevel.sh

```bash
./03-Logs/setLogLevel.sh --query                                      # Show current levels
./03-Logs/setLogLevel.sh --level WARNING --apply                      # Set all managed loggers
./03-Logs/setLogLevel.sh --level FINE   --logger oracle.reports --apply
./03-Logs/setLogLevel.sh --level INFO   --logger oracle.reports --apply
./03-Logs/setLogLevel.sh --query --target WLS_FORMS                   # Query specific server
./03-Logs/setLogLevel.sh --level FINE --target all --apply            # All servers
```

Options:

| Option | Description |
|---|---|
| `--query` | Show current logger levels – no `--apply` needed |
| `--level LEVEL` | `SEVERE\|WARNING\|INFO\|CONFIG\|FINE\|FINER\|FINEST` |
| `--logger NAME` | Logger name/prefix (default: all managed loggers) |
| `--target SERVER` | `WLS_REPORTS\|WLS_FORMS\|AdminServer\|all` (default: `$WLS_MANAGED_SERVER`) |
| `--apply` | **Required** to actually change levels; without it shows a dry-run preview |

Default managed loggers (when no `--logger` specified):
`oracle.reports`, `oracle.forms`, `oracle.adf`, `weblogic.xml.stax`

Requires AdminServer to be running. Uses `load_weblogic_password()` from
`00-Setup/IHateWeblogic_lib.sh` — run `00-Setup/weblogic_sec.sh` first if
the password has not been stored yet.

Level changes are **runtime-only** (lost on server restart). Always reset
with `--level INFO` after a debug session.

---

## 8. Step-by-Step: Fresh Diagnostic Baseline

Before starting a diagnostic session it is helpful to have a clean, known-good
log state. This avoids confusion between old and new errors.

```
Step 1 – Inventory current log situation
─────────────────────────────────────────
./03-Logs/get_all_logs.sh

Review sizes. If any log is > 500 MB, schedule archiving or cleanup.


Step 2 – Search for existing errors (before wiping anything)
──────────────────────────────────────────────────────────────
./03-Logs/grep_logs.sh "REP-\|FRM-\|BEA-\|ORA-" --context 5

Save or review the output. This gives you the pre-baseline error state.


Step 3 – Archive rotated logs to free disk space
──────────────────────────────────────────────────
./03-Logs/archive_logs.sh           # preview
./03-Logs/archive_logs.sh --apply   # compress


Step 4 – Clean active logs to establish a fresh baseline
──────────────────────────────────────────────────────────
./03-Logs/cleanLogFiles.sh          # preview what will be truncated/deleted
./03-Logs/cleanLogFiles.sh --apply  # truncate active logs, delete old rotated logs


Step 5 – (Optional) Enable debug logging for a targeted component
───────────────────────────────────────────────────────────────────
./03-Logs/setLogLevel.sh --level FINE --logger oracle.reports.fonts --apply


Step 6 – Monitor live while reproducing the issue
───────────────────────────────────────────────────
./03-Logs/tail_logs.sh --component WLS_REPORTS
# (In another terminal: trigger the failing report)


Step 7 – Search the results
──────────────────────────────
./03-Logs/grep_logs.sh "REP-" --since $(date +%Y-%m-%d) --context 10


Step 8 – Reset log level
──────────────────────────
./03-Logs/setLogLevel.sh --level INFO --logger oracle.reports.fonts --apply
```

---

## 9. Troubleshooting

### REP-1800 in WLS_REPORTS.log – root cause not visible

```
Symptom: WLS_REPORTS.log shows only "REP-1800: Error running report."
         with a java.rmi.RemoteException stack trace
Cause:   REP-1800 is a servlet-level wrapper. The underlying error
         is in the Reports Engine process, which logs to a different file.
Fix:     Search the Reports Engine log:
           find $DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent \
                -name "*.log" -newer /tmp | xargs grep "REP-" 2>/dev/null
         Common underlying errors: REP-1924 (font), REP-3000 (engine),
         REP-0069 (communication), REP-0110 (SQL)
```

### Log file missing or empty at startup

```
Symptom: WLS_REPORTS.log does not exist or is 0 bytes after server start
Cause A: Server failed to start before any logging was initialised
         → check nodemanager/nodemanager.log for the exit reason
Cause B: cleanLogFiles.sh truncated the file; server restarted and wrote nothing
         → this is normal; generate a test report to produce log output
Fix:     Check Node Manager and AdminServer logs for startup errors:
           tail -100 $DOMAIN_HOME/nodemanager/nodemanager.log
           tail -100 $DOMAIN_HOME/servers/AdminServer/logs/AdminServer.log
```

### Log file grows without bound (no rotation happening)

```
Symptom: WLS_REPORTS.log is several GB in size, no rotated files exist
Cause:   Log rotation is disabled or the rotation size threshold is not reached
         because log entries arrive faster than the check interval
Fix:     Admin Console → Environment → Servers → WLS_REPORTS → Logging:
           Enable: Rotate log file on startup: Yes
           Log file rotation type: By Size
           Maximum log file size: 50000 KB
           Number of files: 10
         Or use cleanLogFiles.sh --apply for immediate relief.
```

### grep_logs.sh finds nothing in rotated logs

```
Symptom: grep_logs.sh returns no results from *.log00001 files
Cause A: Rotated files have already been archived (*.gz)
Fix A:   grep_logs.sh automatically searches *.gz files via zgrep when zgrep
         is installed. If zgrep is missing, install it:
           sudo dnf install gzip        # zgrep is included in the gzip package
         Then re-run grep_logs.sh – it will pick up the .gz files.
         To search manually:
           zgrep "REP-3000" $DOMAIN_HOME/servers/WLS_REPORTS/logs/*.gz

Cause B: zgrep is not installed on the system
Fix B:   sudo dnf install gzip
```

### setLogLevel.sh fails with connection error

```
Symptom: WLST cannot connect to AdminServer
Cause A: AdminServer is not running
         → Start: $DOMAIN_HOME/bin/startWebLogic.sh (or via Node Manager)
Cause B: Stored WebLogic password is wrong or expired
         → Re-run: ./00-Setup/weblogic_sec.sh --apply
Cause C: Admin port is not the default (7001) or SSL is required
         → Check: grep ListenPort $DOMAIN_HOME/config/config.xml
```

### Reports Engine log is empty despite REP-1800

```
Symptom: No useful content in rwEng*.log or repserver.log
Cause A: Reports Server is configured for a different diagnostic log path
Fix A:   Find all .log files under ReportsToolsComponent:
           find $DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent \
                -name "*.log" 2>/dev/null
Cause B: Reports Server crashed at startup before it could log anything
Fix B:   Check $DOMAIN_HOME/servers/WLS_REPORTS/logs/WLS_REPORTS.out for
         raw stderr output (JVM crash dumps, OutOfMemoryError, etc.)
```

### Disk full because of logs

```
Symptom: Oracle Linux reports no space left on device
Cause:   Unrotated or uncompressed WLS logs consuming all available space
Quick fix (immediate relief):
  1. Identify largest logs:
       du -sh $DOMAIN_HOME/servers/*/logs/* | sort -rh | head -20
  2. Archive rotated logs immediately:
       ./03-Logs/archive_logs.sh --apply
  3. Truncate active logs if server is running and logs are confirmed reviewed:
       ./03-Logs/cleanLogFiles.sh --apply
  4. After gaining space: configure WebLogic log rotation properly (see above)
```

---

## References

- Oracle WebLogic 14c – Logging and Diagnostic Services:
  https://docs.oracle.com/en/middleware/fusion-middleware/weblogic-server/12.2.1.4/wllog/index.html
- Oracle Reports 12c – Troubleshooting Guide:
  https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_troubl.htm
- Oracle Diagnostic Logging (ODL) Format:
  https://docs.oracle.com/middleware/12213/core/ASADM/diagnosing.htm
- Oracle WLST Reference – Logger configuration:
  https://docs.oracle.com/en/middleware/fusion-middleware/weblogic-server/12.2.1.4/wlstg/index.html
- Pipperr.de – Oracle Reports 14c Install Guide:
  https://www.pipperr.de/dokuwiki/doku.php?id=forms:oracle_reports_14c_windows64
