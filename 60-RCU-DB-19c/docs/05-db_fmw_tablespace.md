# Step 5 – 05-db_fmw_tablespace.sh

**Script:** [`60-RCU-DB-19c/05-db_fmw_tablespace.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/05-db_fmw_tablespace.sh)
**Runs as:** `oracle`
**Phase:** Before RCU — pre-create the FMW_DATA tablespace for all RCU schemas

---

## Purpose

Create the **one** tablespace in `FMWPDB` that holds all RCU schemas – our
standard ([07-oracle_setup_repository.md – Tablespace Configuration](../../09-Install/docs/07-oracle_setup_repository.md#tablespace-configuration));
`07-` checks before RCU that it exists (`dba_tablespaces`).

- If `DB_FMW_TABLESPACE` is **not set** in `environment_db.conf`: WARN,
  nothing created – fallback, RCU then creates one tablespace per component.
- If `DB_FMW_TABLESPACE` is **set**: create the tablespace, then update
  `RCU_TABLESPACE` in `environment.conf` to match.

```bash
./60-RCU-DB-19c/05-db_fmw_tablespace.sh            # dry-run (needs the running DB)
./60-RCU-DB-19c/05-db_fmw_tablespace.sh --apply
```

Flow: database reachable as SYSDBA (exit 2 otherwise, also in the dry-run) →
dry-run ends → `mkdir -p` of the data file directory → `CREATE TABLESPACE`
in the PDB (an existing tablespace is skipped; an SQL error is a FAIL –
`WHENEVER SQLERROR`, since 2026-11-02) → `RCU_TABLESPACE` in
`environment.conf` set (backup first, symlink followed).

---

## When to use

Use this step only when a DBA wants to control tablespace placement,
sizing, or encryption separately from the RCU defaults.

Skip it otherwise – RCU creates its own tablespaces per component
(`<PREFIX>_STB`, `<PREFIX>_IAS_OPSS`, `<PREFIX>_IAS_AUDIT` …, see
[07-oracle_setup_repository.md](../../09-Install/docs/07-oracle_setup_repository.md#fallback-rcu_tablespace-empty--rcu-creates-its-own)),
which is fine for the metadata workload. Which schemas live there and who uses
them: [rcu_middleware_architecture.md](../../80-FMW-Architecture/rcu_middleware_architecture.md).

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
in `environment.conf` – [`09-Install/01-setup-interview.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/01-setup-interview.sh) writes it (block 4,
empty by default). If the line is missing, the script only WARNs – add it
with `00-Setup/detect_env_conf.sh --apply` (or the interview) and run `05-` again.
`DB_SERVICE` in `environment.conf` must be the PDB service (`DB_PDB_NAME`).

---

## Manual equivalent

```sql
sqlplus / as sysdba
ALTER SESSION SET CONTAINER = FMWPDB;
CREATE TABLESPACE "FMW_DATA"
  DATAFILE '<DB_DATA_DIR>/<CDB>/<PDB>/fmw_data01.dbf' SIZE 500M
  AUTOEXTEND ON NEXT 100M MAXSIZE UNLIMITED
  EXTENT MANAGEMENT LOCAL AUTOALLOCATE SEGMENT SPACE MANAGEMENT AUTO;
```

Data file: `${DB_DATA_DIR}/${DB_CDB_NAME}/${DB_PDB_NAME}/<lower-case name>01.dbf`
(directory created with `mkdir -p` first). Then in `environment.conf`:
`RCU_TABLESPACE="FMW_DATA"`.

---

## Next step

```
60-RCU-DB-19c/06-db_rcu_profile.sh --apply      # profile RCU_USER (no password expiry)
60-RCU-DB-19c/08-db_auto_start.sh --apply        # autostart
09-Install/07-oracle_setup_repository.sh --apply  # RCU
```
