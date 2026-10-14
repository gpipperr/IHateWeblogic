# 30 – Autostart: FMW domain under Node Manager control (systemd)

Script: `09-Install/30-configure_autostart.sh`
Templates: `09-Install/autostart_templates/`

Starts the complete Forms/Reports domain automatically at boot and stops it
cleanly at shutdown. All components are controlled through the **Node Manager**;
a small set of control scripts is rendered from templates into a central
directory per domain, and one systemd unit calls them.

Based on the procedure in *Oracle WebLogic Server 14.1.2.0.0 install*,
chapter 9.4 "Weblogic.service (automatisch stoppen und starten)", with these
deliberate changes:

| Original procedure | Here |
|---|---|
| Repository DB started by the same unit | DB has its own units (`60-RCU-DB-19c/08-db_auto_start.sh`); with `LOCAL_REP_DB=true` the FMW unit is only ordered **after** `oracle-db.service`/`oracle-listener.service` |
| Servers stopped with `nmKill` (hard kill) | Orderly WLST `shutdown()` via the AdminServer, `nmKill` only as fallback |
| `kill -9` loop for leftover processes | Not used |
| One script per component (`wls_start_forms.sh`, …) | One wrapper `fmw_ctl.sh <action> [component]` |
| Managed servers started with `nmStart` | Started with `start()` through the AdminServer (passes the admin URL / startup properties correctly); AdminServer and system components with `nmStart` |

> **Simple alternative for customers who set everything up by hand:**
> `70-Customer-Projects/Reports14_Only_manuall_install/Autostart_linux_middleware.txt`
> (plain start scripts, no Node Manager control).

---

## Layout

Control directory: **`$ORACLE_BASE/admin/<DOMAIN_NAME>/ctrl`** – follows the
Oracle `admin/<name>` convention, next to database directories such as
`admin/FMWCDB`.

```
$ORACLE_BASE/admin/<DOMAIN_NAME>/ctrl/
├── fmw_env.sh          paths, ports, component lists (rendered)
├── fmw_ctl.sh          fmw_ctl.sh {start|stop|restart|status} [all|<component>]
├── wls_start.py        WLST: nmStart AdminServer, start() managed servers, nmStart components
├── wls_stop.py         WLST: nmKill components, shutdown() managed + AdminServer, nmKill fallback
├── wls_status.py       WLST: nmServerStatus for every component
├── fmw-<domain>.service  rendered unit (copied to /etc/systemd/system/)
├── keyfile/            encrypted WLST credentials (mode 700, files 600)
│   ├── admin_config / admin_key    AdminServer login (connect)
│   └── nm_config    / nm_key       Node Manager login (nmConnect)
└── log/                fmw_ctl_<date>.log, nodemanager.out
```

## Components

Discovered from `$DOMAIN_HOME/config/config.xml` at configure time:

| Kind | Start | Stop |
|---|---|---|
| Node Manager | `startNodeManager.sh` (background), wait for its port | `stopNodeManager.sh` (last) |
| AdminServer | `nmStart` | `shutdown()` (after the managed servers), fallback `nmKill` |
| Managed servers (`WLS_FORMS`, `WLS_REPORTS`, …) | `start()` via AdminServer | `shutdown(…, ignoreSessions='true')`, fallback `nmKill` |
| System components of type `ReportsServerComponent` (and `OHS` if present) | `nmStart(serverName, serverType)` | `nmKill` (same as `stopComponent.sh`) |

Not started: `FORMS` and `ReportsToolsComponent` system components – they have
no long-running process of their own.

## Credentials

`30-configure_autostart.sh --apply` creates the key files **without any
prompt**: the WebLogic admin password comes from `weblogic_sec.conf.des3`
(`load_weblogic_password`), then WLST `connect()` + `storeUserConfig()` and
`nmConnect()` + `storeUserConfig(nm='true')`. `WLST_PROPERTIES=-Dweblogic.management.confirmKeyfileCreation=true`
suppresses WLST's interactive "create the key file?" question.

The Node Manager login must be the WebLogic admin user/password. A domain
created by WLST offline in production mode gets **random** Node Manager
credentials (user e.g. `o2HTp584LE`, password unknown – confirmed 2026-10-15);
`11-oracle_nodemanager.sh --apply` sets them to the admin credentials
(`SecurityConfiguration` `NodeManagerUsername` + `setNodeManagerPassword()`,
then restart the Node Manager). If `nmConnect` still fails, the script stops
with a FAIL.

`servers/AdminServer/security/boot.properties` must exist – the Node Manager
uses it for `nmStart('AdminServer')`.

## systemd unit

`fmw-<DOMAIN_NAME>.service`:

- `Type=oneshot` + `RemainAfterExit=yes` – the unit starts the domain and then
  shows `active (exited)`; the server JVMs keep running under the Node Manager.
- `User=oracle`, `ExecStart=… fmw_ctl.sh start all`, `ExecStop=… fmw_ctl.sh stop all`
- `LimitNOFILE` / `LimitNPROC` from `ULIMIT_NOFILE` / `ULIMIT_NPROC` in
  `environment.conf` – **systemd does not apply `/etc/security/limits.d`** to
  services, without these lines WebLogic would run with 1024 open files.
- `After=network-online.target`; with `LOCAL_REP_DB=true` also
  `After=`/`Wants=oracle-db.service oracle-listener.service`.
- `TimeoutStartSec=1800`, `TimeoutStopSec=900`.

The script copies the unit and runs `systemctl daemon-reload` + `enable` (as
root via sudo, otherwise it prints the commands). It does **not** start the
unit – the domain is already running at this point.

## Usage

```bash
# Configure (domain + Node Manager must be running)
./09-Install/30-configure_autostart.sh            # dry-run: components + target files
./09-Install/30-configure_autostart.sh --apply

# Day-to-day (as oracle)
CTRL=$ORACLE_BASE/admin/<DOMAIN_NAME>/ctrl
$CTRL/fmw_ctl.sh status
$CTRL/fmw_ctl.sh restart WLS_REPORTS        # single component
$CTRL/fmw_ctl.sh stop all

# As root
systemctl status fmw-<DOMAIN_NAME>
systemctl stop|start|restart fmw-<DOMAIN_NAME>
journalctl -u fmw-<DOMAIN_NAME> -b

# Remove (unit disabled + removed, ctrl/ deleted; running servers are NOT stopped)
./09-Install/30-configure_autostart.sh --remove --apply
```

**Interplay with `01-Run/startStop.sh`:** once the autostart is active, control
the servers through `fmw_ctl.sh` / `systemctl` (Node Manager). Servers started
outside the Node Manager show up as `UNKNOWN` in `fmw_ctl.sh status`.

## Manual procedure (without the script)

1. Create the directories, render the templates by hand (replace every
   `##VARIABLE##`), `chmod 750 *.sh`.
2. Create the key files once in WLST:
   ```
   connect('weblogic','<pw>','t3://localhost:7001')
   storeUserConfig('<ctrl>/keyfile/admin_config','<ctrl>/keyfile/admin_key')
   disconnect()
   nmConnect('weblogic','<pw>','localhost','5556','<domain>','<DOMAIN_HOME>','plain')
   storeUserConfig('<ctrl>/keyfile/nm_config','<ctrl>/keyfile/nm_key','true')
   nmDisconnect()
   ```
3. Copy the unit to `/etc/systemd/system/`, `systemctl daemon-reload`,
   `systemctl enable fmw-<domain>`.

## Deinstall

`99-oracle_deinstall_fmw.sh` disables and removes the unit and deletes
`$ORACLE_BASE/admin/<DOMAIN_NAME>`; other directories under `$ORACLE_BASE/admin`
(database) stay protected.

## Verification

- `fmw_ctl.sh status` → every component `RUNNING`
- `systemctl stop fmw-<domain>` → all JVMs and the Node Manager gone
- `systemctl start fmw-<domain>` → `status` all `RUNNING` again
- Reboot → with `LOCAL_REP_DB=true` the DB starts first, then the domain
