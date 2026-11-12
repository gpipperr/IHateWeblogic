# Step 8 – 08-db_auto_start.sh

**Script:** [`60-RCU-DB-19c/08-db_auto_start.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/08-db_auto_start.sh)
**Runs as:** `oracle` (systemd unit install requires root — script prompts)
**Phase:** Register DB for auto-start at boot

---

## Purpose

Ensure the Oracle CDB starts automatically after a system reboot:

1. Verify or add the `/etc/oratab` entry for the CDB (required by `dbstart`/`dbshut`):
   entry with `DB_ORACLE_HOME` (a different home → WARN) and flag `Y`
   (flag `N` → the root `sed` command is printed; the confirmation prompt
   only with `--apply`). Dry-run ends after this check
2. Write `oracle-db.service` systemd unit to `/tmp/` – an installed unit with
   the same content that is enabled → OK, nothing to do; a different one
   (e.g. old home after `09-`) → WARN; otherwise print the root install commands
3. Confirm the unit is enabled; next-step hint (RCU)

PDB auto-open is **not** handled here — it relies on
`ALTER PLUGGABLE DATABASE ALL SAVE STATE` which was set in [`03-db_create_database.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/03-db_create_database.sh).

---

## /etc/oratab

`dbstart` and `dbshut` read `/etc/oratab` to decide which instances to start/stop.
The entry format is:

```
$SID:$ORACLE_HOME:Y
```

The `:Y` flag tells `dbstart` to start this instance.  `:N` means skip.

DBCA normally creates this entry automatically during DB creation (flag `N`).
This script verifies the entry exists with the current `DB_ORACLE_HOME` and
`:Y`, and adds it if missing. Flag `N` → as root:

```bash
sed -i 's|^FMWCDB:.*|FMWCDB:<DB_ORACLE_HOME>:Y|' /etc/oratab
```
(a missing entry: `echo 'FMWCDB:<DB_ORACLE_HOME>:Y' >> /etc/oratab`)

**Permissions:** `/etc/oratab` is typically owned by `root:oinstall` with mode `664`,
so the `oracle` user (member of `oinstall`) can append to it directly.
If it is `644` or owned differently, the script will print the manual root command.

---

## systemd Unit: oracle-db.service

As root `cat > /etc/systemd/system/oracle-db.service` (example values):

```ini
[Unit]
Description=Oracle Database CDB (FMWCDB)
After=network-online.target oracle-listener.service
Wants=network-online.target
Requires=oracle-listener.service
RequiresMountsFor=<home> <ORACLE_BASE> <DB_DATA_DIR>

[Service]
Type=forking
User=oracle
Group=oinstall
Environment=ORACLE_HOME=/u01/app/oracle/product/19.33.0/db_home1
Environment=ORACLE_BASE=/u01/app/oracle
Environment=ORACLE_SID=FMWCDB
# dbstart/dbshut read /etc/oratab — entry must exist with :Y flag
ExecStart=/u01/app/oracle/product/19.33.0/db_home1/bin/dbstart  /u01/app/oracle/product/19.33.0/db_home1
ExecStop=/u01/app/oracle/product/19.33.0/db_home1/bin/dbshut   /u01/app/oracle/product/19.33.0/db_home1
RemainAfterExit=yes
TimeoutStartSec=180
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
```

> **`RequiresMountsFor=`** (since 2026-11-05): the unit waits until the file
> systems of these paths are mounted. A block volume mounted with `nofail` /
> `_netdev` (OCI iSCSI, NFS) comes **after** `network-online.target`, so
> `After=network-online.target` alone is not enough. At a customer the
> listener started at 7 s, while `/oracle` was mounted only at 11 s. If
> everything is on `/`, the line changes nothing. Check:
> `systemctl show -p RequiresMountsFor,After <unit>`,
> `systemd-analyze critical-chain <unit>` – the `.mount` of the volume must
> appear in the chain.


`Requires=oracle-listener.service` needs the unit of `02-` – without it
`oracle-db` does not start. `dbstart` / `dbshut` with the home argument also
start / stop `LISTENER` of that home (`ORACLE_HOME_LISTNR`): harmless at the
start (already running), at the stop the listener goes down with the database.

**`Requires=oracle-listener.service`** — systemd starts the listener first,
then the database.  Without the listener, PMON cannot register the PDB service
and `dbstart` may time out waiting for dynamic registration.

**`TimeoutStartSec=180`** — DB start takes significantly longer than listener start
(SGA allocation, redo application, PDB open).  60 s is not enough.

---

## Root Install Commands

The script writes the unit to a temp file and prints:

```bash
cp /tmp/oracle-db-XXXXXX.service /etc/systemd/system/oracle-db.service
systemctl daemon-reload
systemctl enable --now oracle-db
```

The script then prompts for confirmation and verifies with `systemctl is-enabled`.

---

## Manual Verification

After the unit is enabled:

```bash
systemctl status oracle-db.service
systemctl status oracle-listener.service

# Test full cycle (as root):
systemctl stop  oracle-db.service
systemctl start oracle-db.service
systemctl status oracle-db.service

# Verify PDB is open after restart:
ORACLE_SID=FMWCDB sqlplus / as sysdba <<< "SELECT NAME, OPEN_MODE FROM V\$PDBS;"
```

---

## Relationship to Other Scripts

| Script | What it starts | systemd unit |
|---|---|---|
| [`02-db_setup_listener.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/02-db_setup_listener.sh) | TNS Listener | `oracle-listener.service` |
| [`08-db_auto_start.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/08-db_auto_start.sh) | Oracle CDB (+ PDB via SAVE STATE) | `oracle-db.service` |

Boot order: `oracle-listener.service` → `oracle-db.service`

**After an out-of-place patch** ([`09-db_patch_rcu.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/09-db_patch_rcu.sh), new `DB_ORACLE_HOME`):
both units contain the home path (`ExecStart`, `Environment=ORACLE_HOME`) and
`/etc/oratab` the `SID:home:Y` line. `09-` rewrites `/etc/oratab` and prints
the root commands for the units (`sed` + `systemctl daemon-reload`) – run them
before the next reboot, otherwise the old home starts
([09-db_patch_rcu.md](09-db_patch_rcu.md), step 6). The unit files are
readable by root only on some hosts; `09-` then treats them as "to change".

**FMW domain on the same host:** with `LOCAL_REP_DB=true`
[`09-Install/30-configure_autostart.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/30-configure_autostart.sh) orders `fmw-<domain>.service`
(`Wants=` / `After=`) after `oracle-listener.service` and `oracle-db.service`
– the data sources and the OPSS store need the RCU schemas at the first start ([rcu_middleware_architecture.md §3](../../80-FMW-Architecture/rcu_middleware_architecture.md#3-who-logs-in-where)).

---

## Next step

After DB auto-start is configured, continue with the FMW installation:

```
09-Install/07-oracle_setup_repository.sh --apply
```
