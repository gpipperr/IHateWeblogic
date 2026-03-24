# Step 4 – 04-db_setup_listener.sh

**Script:** `60-RCU-DB-19c/04-db_setup_listener.sh`
**Runs as:** `oracle` (systemd unit install requires root — script prompts)
**Phase:** Oracle Net configuration + TNS Listener start

---

## Purpose

Create the Oracle Net configuration and start the TNS Listener.
Must run **before** `05-db_create_database.sh` — DBCA requires the listener
to be running for dynamic service registration.

1. Write `listener.ora` (TCP, configured host, port 1521)
2. Write `sqlnet.ora` (basic name resolution, connect timeout)
3. Write `tnsnames.ora` (CDB + PDB aliases)
4. Start LISTENER (or reload if already running)
5. Install `oracle-listener.service` systemd unit for auto-start at boot

---

## Configuration

Set in `environment_db.conf`:

```
DB_LISTENER_HOST=hostname.domain   # defaults to hostname -f
DB_LISTENER_PORT=1521              # default
```

---

## Files written

| File | Location |
|---|---|
| `listener.ora` | `$DB_ORACLE_HOME/network/admin/` |
| `sqlnet.ora` | `$DB_ORACLE_HOME/network/admin/` |
| `tnsnames.ora` | `$DB_ORACLE_HOME/network/admin/` |
| `oracle-listener.service` | `/etc/systemd/system/` (root required) |

---

## Loopback Warning

If `DB_LISTENER_HOST` resolves to `127.x.x.x`, the script warns that
remote connections (FMW, RCU) will not work.
Set `DB_LISTENER_HOST` to the external hostname or IP in `environment_db.conf`.

---

## systemd Unit

The unit file is written to `/tmp/oracle-listener-XXXXXX.service` and must
be installed by root.  The script prints the three commands and prompts for
confirmation:

```bash
cp /tmp/oracle-listener-XXXXXX.service /etc/systemd/system/oracle-listener.service
systemctl daemon-reload
systemctl enable --now oracle-listener
```
