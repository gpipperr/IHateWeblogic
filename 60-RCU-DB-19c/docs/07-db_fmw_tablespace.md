# Step 7 – 07-db_fmw_tablespace.sh

**Script:** `60-RCU-DB-19c/07-db_fmw_tablespace.sh`
**Runs as:** `oracle`
**Phase:** Optional — pre-create a shared FMW_DATA tablespace before RCU

---

## Purpose

Optionally create a dedicated tablespace in `FMWPDB` for DBA-managed
RCU schema storage.

- If `DB_FMW_TABLESPACE` is **not set** in `environment_db.conf`: script
  exits cleanly with an info message (no-op).
  RCU will create its own tablespaces automatically.
- If `DB_FMW_TABLESPACE` is **set**: create the tablespace, then update
  `RCU_TABLESPACE` in `environment.conf` to match.

---

## When to use

Use this step only when a DBA wants to control tablespace placement,
sizing, or encryption separately from the RCU defaults.

Skip it when running RCU on a dev/test environment — RCU auto-creates
its tablespaces in the `USERS` tablespace which is fine for metadata-only
workloads.

---

## Configuration

Set in `environment_db.conf`:

```
DB_FMW_TABLESPACE=FMW_DATA          # name; leave empty to skip
DB_FMW_TABLESPACE_SIZE_MB=500       # initial size, default 500 MB
```

Then also set in `environment.conf`:

```
RCU_TABLESPACE=FMW_DATA
```

The script sets `RCU_TABLESPACE` automatically if the line already exists
in `environment.conf`.  If not, run `00-Setup/init_env.sh --apply` first.

---

## Next step

```
09-Install/07-oracle_setup_repository.sh --apply
```
