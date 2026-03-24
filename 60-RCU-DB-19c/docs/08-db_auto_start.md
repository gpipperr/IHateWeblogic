# Step 8 – 08-db_auto_start.sh

**Script:** `60-RCU-DB-19c/08-db_auto_start.sh`
**Runs as:** `oracle` (systemd unit install requires root — script prompts)
**Phase:** Register DB for auto-start at boot

---

## Purpose

Ensure the Oracle CDB starts automatically after a system reboot:

1. Verify or add the `/etc/oratab` entry for the CDB (required by `dbstart`/`dbshut`)
2. Write `oracle-db.service` systemd unit to `/tmp/`, print root install commands
3. Confirm the unit is enabled

PDB auto-open is **not** handled here — it relies on
`ALTER PLUGGABLE DATABASE ALL SAVE STATE` which was set in `05-db_create_database.sh`.

---

## /etc/oratab

`dbstart` and `dbshut` read `/etc/oratab` to decide which instances to start/stop.
The entry format is:

```
$SID:$ORACLE_HOME:Y
```

The `:Y` flag tells `dbstart` to start this instance.  `:N` means skip.

DBCA normally creates this entry automatically during DB creation.
This script verifies the entry exists with `:Y` and adds it if missing.

**Permissions:** `/etc/oratab` is typically owned by `root:oinstall` with mode `664`,
so the `oracle` user (member of `oinstall`) can append to it directly.
If it is `644` or owned differently, the script will print the manual root command.

---

## systemd Unit: oracle-db.service

```ini
[Unit]
Description=Oracle Database CDB (FMWCDB)
After=network-online.target oracle-listener.service
Wants=network-online.target
Requires=oracle-listener.service

[Service]
Type=forking
User=oracle
Group=oinstall
Environment=ORACLE_HOME=...
Environment=ORACLE_BASE=...
Environment=ORACLE_SID=...
ExecStart=$ORACLE_HOME/bin/dbstart  $ORACLE_HOME
ExecStop=$ORACLE_HOME/bin/dbshut   $ORACLE_HOME
RemainAfterExit=yes
TimeoutStartSec=180
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
```

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
| `04-db_setup_listener.sh` | TNS Listener | `oracle-listener.service` |
| `08-db_auto_start.sh` | Oracle CDB (+ PDB via SAVE STATE) | `oracle-db.service` |

Boot order: `oracle-listener.service` → `oracle-db.service`

---

## Next step

After DB auto-start is configured, continue with the FMW installation:

```
09-Install/07-oracle_setup_repository.sh --apply
```
