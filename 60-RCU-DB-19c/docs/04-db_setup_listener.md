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

The instance registers with this listener through `local_listener`, which
`05-db_create_database.sh` sets to the explicit address (not the DBCA alias
`LISTENER_<SID>`) – see
[05-db_create_database.md](05-db_create_database.md#step-4-post-creation-parameter-tuning).

---

## Two Oracle Net directories on a shared host

| Directory | Read by | Content |
|---|---|---|
| `$DB_ORACLE_HOME/network/admin` | listener, the DB instance, `sqlplus` with the DB home environment | `listener.ora`, `sqlnet.ora`, `tnsnames.ora` of this script |
| `TNS_ADMIN` of `environment.conf` (`$ORACLE_BASE/admin/tns_names`) | Forms, Reports, WebLogic, the oracle shell | the aliases the FMW side uses – the PDB alias must be there too |

Lesson of 2026-10-27/28: an instance started with the **shared** `TNS_ADMIN`
did not find the `LISTENER_<SID>` alias of `local_listener` and never
registered its services – hence the explicit address in `local_listener`
(`05-`), and `09-db_patch_rcu.sh` starts the instance with the home's own
`network/admin` and copies these three files into a new home. Background:
[report_engine_architecture.md §5.2](../../80-FMW-Architecture/report_engine_architecture.md#52-oracle-net--three-places-for-one-tns_admin),
[02-Checks/tns_admin_check.sh](../../02-Checks/README.md#tns_admin_checksh).

## systemd Unit

The unit file is written to `/tmp/oracle-listener-XXXXXX.service` and must
be installed by root.  The script prints the three commands and prompts for
confirmation:

```bash
cp /tmp/oracle-listener-XXXXXX.service /etc/systemd/system/oracle-listener.service
systemctl daemon-reload
systemctl enable --now oracle-listener
```

The unit contains the home path – after an out-of-place patch see
[08-db_auto_start.md](08-db_auto_start.md) / [09-db_patch_rcu.md](09-db_patch_rcu.md).

