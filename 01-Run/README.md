# 01-Run – Start/Stop, WLST, Reports Server

Scripts for operating a running Oracle Forms/Reports domain: component
management, interactive WLST access, Reports Server status.

---

## 1. Overview

| Script | Status | Purpose |
|---|---|---|
| `startStop.sh` | ✅ implemented | Component status table; start/stop NM, WLS, OHS |
| `wlst_connect.sh` | ✅ implemented | Interactive WLST shell with auto-login |
| `rwserver_status.sh` | 🔧 planned | Query Reports Server status (no restart) |

All scripts source `environment.conf`. Run `00-Setup/env_check.sh` first
if `environment.conf` does not exist yet.

---

## 2. startStop.sh

### Usage

```bash
# Show component status (read-only, no credentials needed)
./01-Run/startStop.sh
./01-Run/startStop.sh list

# Start / stop a single component (dry-run without --apply)
./01-Run/startStop.sh start AdminServer  --apply
./01-Run/startStop.sh stop  WLS_REPORTS  --apply
./01-Run/startStop.sh start NodeManager  --apply

# Start / stop all components in the correct sequence
./01-Run/startStop.sh start-all  --apply
./01-Run/startStop.sh stop-all   --apply
```

### Component types

| Type | Components | Start mechanism | Stop mechanism |
|---|---|---|---|
| `NM` | NodeManager | `bin/startNodeManager.sh` (nohup) | `kill <PID>` |
| `ADMIN` | AdminServer | `bin/startWebLogic.sh` (nohup) | WLST `shutdown()` |
| `MANAGED` | WLS_REPORTS, WLS_FORMS | `bin/startManagedWebLogic.sh` (nohup) | WLST `shutdown()` |
| `OHS` | ohs1, … | `bin/startComponent.sh` | `bin/stopComponent.sh` |

Components are discovered automatically from:

- `$DOMAIN_HOME/config/config.xml` → WLS server list
- `$DOMAIN_HOME/nodemanager/nodemanager.properties` → NodeManager port
- `$DOMAIN_HOME/system_components/OHS/` → OHS instances (if present)

### Start sequence

```
1. NodeManager    (NM)       – wait ~15 s
2. AdminServer    (ADMIN)    – wait ~60 s
3. Managed servers (MANAGED) – WLS_REPORTS, WLS_FORMS, …
4. OHS            (OHS)      – independent of WLS
```

`start-all` skips components already `RUNNING`.

### Stop sequence

```
1. OHS            (OHS)      – independent of WLS
2. Managed servers (MANAGED) – shutdown via WLST (requires AdminServer up)
3. AdminServer    (ADMIN)    – shutdown via WLST
4. NodeManager    (NM)       – kill
```

`stop-all` skips components already `STOPPED`.

### Dry-run

Without `--apply` all write operations (start/stop) are shown as a
preview only. No process is started or stopped.

```bash
# Preview what start-all would do:
./01-Run/startStop.sh start-all
```

### Status detection

The status column shows:

| Status | Meaning |
|---|---|
| `RUNNING` (green) | Process found via `pgrep` **or** port is listening |
| `STOPPED` (red) | No process, port not listening |
| `UNKNOWN` (yellow) | Only shown briefly before first refresh |

Run as root or as the Oracle user to see all process names (`pgrep` may
miss processes owned by other users).

---

## 3. wlst_connect.sh

### Usage

```bash
./01-Run/wlst_connect.sh
./01-Run/wlst_connect.sh --url t3://adminhost:7001
./01-Run/wlst_connect.sh --user wlsadmin
```

### Options

| Option | Description |
|---|---|
| `--url T3_URL` | Override AdminServer URL (default: from `weblogic_sec.conf.des3`) |
| `--user NAME` | Override WebLogic admin username |

### Prerequisites

```bash
# Store credentials once (machine-local encryption):
./00-Setup/weblogic_sec.sh --apply
```

### How it works

1. Loads credentials from `weblogic_sec.conf.des3` via
   `load_weblogic_password()` (openssl des3 + machine UUID key).
2. Optionally sources `$DOMAIN_HOME/bin/setDomainEnv.sh`.
3. Writes a temp Python bootstrap (`/tmp/wlst_connect_XXXXX.py`) with
   only the `connect()` call – the password is passed via env vars,
   never stored in the file.
4. Pipes bootstrap to WLST stdin, then forwards terminal input.
   WLST stays interactive after the auto-connect.
5. On exit: temp file and password env vars are removed by the EXIT trap.

### Note on readline

Because stdin is a pipe (bootstrap + forwarded terminal), readline
history and tab completion may be limited. All WLST commands work
normally.

### Typical WLST commands after connect

```python
# Domain overview
ls()
domainRuntime()
ls()

# Reports engine status
cd('/AppRuntimeStateRuntime/AppRuntimeStateRuntime')
ls()

# Thread dump
threadDump()

# Exit
exit()
```

---

## 4. Planned scripts

### rwserver_status.sh

Query the Oracle Reports Server status for all configured instances
without requiring a full start/stop cycle.

```bash
./01-Run/rwserver_status.sh
```

Planned checks:
- Running `rwserver` processes and their PIDs
- Reports engine count vs. configured min/max
- Job queue depth (pending/running/completed)

---

## 5. Troubleshooting

### startStop.sh – managed server won't stop (AdminServer down)

```
Symptom: WLST shutdown fails for WLS_REPORTS / WLS_FORMS
Cause:   AdminServer must be running to shut down managed servers via WLST
Fix:     Stop the managed server by PID, then restart AdminServer
         pgrep -a -f "Dweblogic.Name=WLS_REPORTS"
         kill <PID>
```

### startStop.sh – start-all stalls at NodeManager

```
Symptom: start-all hangs after "NodeManager start initiated"
Cause:   startNodeManager.sh blocked (e.g. port 5556 already in use)
Fix:     Check port 5556:   ss -tlnp | grep 5556
         Check NM log:      tail $DIAG_LOG_DIR/start_NodeManager_*.log
```

### startStop.sh – STOPPED for all components though domain is running

```
Symptom: All components show STOPPED even though WebLogic is up
Cause A: Running as a different user – pgrep misses processes of other users
         Fix: Run as the oracle user: su - oracle -c "..."
Cause B: DOMAIN_HOME wrong in environment.conf
         Fix: Re-run 00-Setup/env_check.sh to regenerate environment.conf
```

### wlst_connect.sh – "User failed to be authenticated"

```
Symptom: WLST connects but login fails
Cause:   Stored password outdated or wrong username
Fix:     Re-run 00-Setup/weblogic_sec.sh --apply to update credentials
```

### wlst_connect.sh – wlst.sh not found

```
Symptom: FAIL wlst.sh not found: /u01/oracle/fmw/oracle_common/common/bin/wlst.sh
Cause:   FMW_HOME is wrong or FMW is not installed at that path
Fix:     Correct FMW_HOME in environment.conf, then re-run env_check.sh
```

---

## 6. Related Scripts

| Script | Purpose |
|---|---|
| `00-Setup/env_check.sh` | Generate / validate `environment.conf` |
| `00-Setup/weblogic_sec.sh` | Store WebLogic credentials (used by wlst_connect and startStop) |
| `02-Checks/port_check.sh` | Verify ports before start; complements status table |
| `03-Logs/tail_logs.sh` | Live-tail server logs during start/stop |
| `05-ReportsPerformance/engine_check.sh` | Engine count after Reports Server start |

---

## 7. References

- Oracle WebLogic WLST Command Reference (14.1.2):
  https://docs.oracle.com/en/middleware/developer-tools/weblogic-server/14.1.2/wlstg/
- Oracle Reports Administration (rwserver, rwclient):
  https://docs.oracle.com/middleware/12213/formsandreports/admin-reports/
- Oracle Forms/Reports 14c Start/Stop:
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/admin-fnr/
