# Step 11 – NodeManager Configuration

**Script:** `09-Install/11-oracle_nodemanager.sh`
**Runs as:** `oracle`
**Phase:** 6 – Post-Domain Configuration

---

## Purpose

Configure the WebLogic NodeManager for **plain (non-SSL) communication** with
the AdminServer.

By default WebLogic installs NodeManager with `SecureListener=true`.  For
internal environments — where no internal PKI is in place — this causes the
following error when attempting to start managed servers (WLS_FORMS,
WLS_REPORTS):

```
<Error> <NodeManager> <BEA-300048>
<Unable to start the server WLS_FORMS :
 javax.net.ssl.SSLException: Unrecognized SSL message, plaintext connection?>
```

The root cause is a **protocol mismatch**: one side speaks SSL, the other
expects plain TCP.  Both sides must be aligned to the same mode.

---

## Background

NodeManager manages the lifecycle of managed servers (start / stop / restart)
independently of the AdminServer.  It communicates over a dedicated TCP port
(default: 5556).

### Two communication modes

| Mode | Property | Domain config |
|---|---|---|
| **SSL** (default) | `SecureListener=true` | NodeManager Type = `SSL` |
| **Plain** (this script) | `SecureListener=false` | NodeManager Type = `Plain` |

Both sides must match.  This script sets **both** to `Plain`.

### Relevant files

| File | Purpose |
|---|---|
| `$DOMAIN_HOME/nodemanager/nodemanager.properties` | NodeManager daemon settings |
| Domain `config.xml` (via WLST) | Stores NodeManager type for the domain |

---

## Without the Script (manual)

### Step 1 – nodemanager.properties

```bash
vi $DOMAIN_HOME/nodemanager/nodemanager.properties
```

Set:
```properties
SecureListener=false
StartScriptEnabled=true
```

### Step 2 – Domain configuration via Enterprise Manager

1. Log in to EM: `https://<host>:7002/em`
2. Navigate to `fr_domain` → **WebLogic Domain** → **Security** → **General**
3. Click **Lock & Edit**
4. Change **NodeManager Type** from `SSL` to `Plain`
5. Click **Save** → **Activate Changes**

### Step 3 – Restart NodeManager

```bash
# Stop any running NodeManager
pkill -f NodeManager

# Start NodeManager
nohup $DOMAIN_HOME/bin/startNodeManager.sh \
    > $DOMAIN_HOME/nodemanager/nm.out 2>&1 &
```

---

## With the Script

```bash
# Dry-run – show current settings, no changes
./09-Install/11-oracle_nodemanager.sh

# Apply all changes (requires AdminServer running for WLST step)
./09-Install/11-oracle_nodemanager.sh --apply

# Apply only nodemanager.properties (AdminServer not yet started)
./09-Install/11-oracle_nodemanager.sh --apply --skip-wlst
```

### Typical workflow on a fresh installation

```bash
# 1. Fix nodemanager.properties before first start
./09-Install/11-oracle_nodemanager.sh --apply --skip-wlst

# 2. Start AdminServer
$DOMAIN_HOME/bin/startWebLogic.sh &

# 3. Set domain NodeManager type via WLST (AdminServer now running)
./09-Install/11-oracle_nodemanager.sh --apply

# 4. Start NodeManager
nohup $DOMAIN_HOME/bin/startNodeManager.sh \
    > $DOMAIN_HOME/nodemanager/nm.out 2>&1 &
```

---

## What the Script Does

| Step | Action |
|---|---|
| 1 | Verify `DOMAIN_HOME` and `ORACLE_HOME` from `environment.conf` |
| 2 | Show current `SecureListener` / `ListenAddress` / `StartScriptEnabled` values |
| 3 | Backup `nodemanager.properties` with timestamp |
| 4 | Set `SecureListener=false` and `StartScriptEnabled=true` |
| 5 | Connect to AdminServer via WLST (if reachable) and set `NodeManagerType=Plain` |
| 6 | Verify written values |
| 7 | Print next-step hints |

---

## Key Properties Explained

| Property | Value | Reason |
|---|---|---|
| `SecureListener` | `false` | Disable SSL on NodeManager listener |
| `StartScriptEnabled` | `true` | Allow NM to start servers via `startManagedWebLogic.sh` |
| `ListenAddress` | `localhost` | Bind to loopback only (Admin and NM on same host) |
| `ListenPort` | `5556` | Default NM port (verify firewall if AdminServer is remote) |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `SSLException: Unrecognized SSL message` | `SecureListener=true` vs Plain domain config | Run this script `--apply` |
| `Connection refused` on port 5556 | NodeManager not started | `startNodeManager.sh &` |
| `WLST error: Cannot connect` | AdminServer not running | Use `--skip-wlst`, set NodeManager Type in EM later |
| Managed server stays `SHUTDOWN` after NM start | `StartScriptEnabled=false` | Script sets this to `true` |
| Changes lost after domain restart | Activation not completed in WLST | Re-run `--apply` or activate in EM |

---

## Related Scripts

| Script | Purpose |
|---|---|
| `09-Install/08-oracle_setup_domain.sh` | Creates the domain (prerequisite) |
| `09-Install/10-oracle_boot_properties.sh` | Write boot.properties (run before first start) |
| `09-Install/12-oracle_reports_users.sh` | Create Reports monitor/exec users (run after NM is up) |
| `01-Run/startStop.sh` | Day-to-day server start/stop via NodeManager |

---

## Oracle Documentation

- **NodeManager Overview** – WebLogic Server 14.1.2 Administration Guide,
  *Administering Node Manager*
  → Oracle Doc: *Configuring and Managing WebLogic Server Node Manager*
- **BEA-300048** – NodeManager SSL configuration mismatch error
