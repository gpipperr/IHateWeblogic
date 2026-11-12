# Step 0a – 00a-db_env_interview.sh

**Script:** [`60-RCU-DB-19c/00a-db_env_interview.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/00a-db_env_interview.sh)
**Runs as:** `oracle`
**Phase:** Phase DB, first step – after [`09-Install/01-setup-interview.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/01-setup-interview.sh)
(`environment.conf` with `LOCAL_REP_DB=true`), before `00-` / `00b-` / `01-`

```bash
./60-RCU-DB-19c/00a-db_env_interview.sh            # dry-run: questions + diff, nothing written
./60-RCU-DB-19c/00a-db_env_interview.sh --apply    # write environment_db.conf (backup, mode 600)
./60-RCU-DB-19c/00a-db_env_interview.sh --reset --apply   # ask every value again (current = default)
./60-RCU-DB-19c/00a-db_env_interview.sh --check    # read-only consistency check
```

`--check` evaluates the existing file as it is (no template merge, no
`ORACLE_BASE` replacement, no questions); without a file it is a FAIL (exit 2).

---

## Purpose

`environment_db.conf` (gitignored) holds the values of the local RCU database.
Created by hand (`cp environment_db.conf.example` + `vi`) it caused three
problems at the first customer installation (2026-10-30 … 11-02): file
missing (`00b-` FATAL), fixed `/u01/...` values of an old template copy
overriding `ORACLE_BASE` / `ORACLE_INVENTORY` of `environment.conf` (the file
is read **after** it), `DB_ORACLE_HOME` named `19.30.0` while 19.33 was
installed – and values that must match `environment.conf` were typed twice
(`DB_PDB_NAME` vs. `DB_SERVICE`: `FMWPDB` vs. `rcu`).

The script works on a **working copy**; the dry-run shows the questions and
the diff, `--apply` writes it (backup `environment_db.conf.bak_<ts>`,
`chmod 600`). A second run without changes writes nothing.

## What it does

1. **Template keys** – no file: copy of [`environment_db.conf.example`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/environment_db.conf.example) (with
   its comments). Existing file: keys of the template the file misses are
   appended under a marker comment (new template keys arrive with
   `git pull`); existing values and extra keys (`DB_ORACLE_HOME_PREV` of
   [`09-db_patch_rcu.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/09-db_patch_rcu.sh)) stay.
2. **Inherited, never asked** – `ORACLE_BASE` and `ORACLE_INVENTORY` come
   from `environment.conf`; a fixed value is replaced by the template's
   default form (`ORACLE_BASE="${ORACLE_BASE:-/u01/app/oracle}"`) with a WARN.
3. **Interview** – asked on a new file or with `--reset`; in an existing file
   kept, except when the value contradicts `environment.conf` (then asked
   again with the matching default):

| Key | Default | Re-asked when |
|---|---|---|
| `DB_ORACLE_HOME` | `${ORACLE_BASE}/product/<RU>/db_home1`, RU from the `db_ru` row of [`09-Install/download/patches_db.csv`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/download/patches_db.csv) (19.33 → `19.33.0`; no row: `19.33.0`) | the directory does not name that RU and the home is not installed yet |
| `DB_EDITION` | menu EE / SE2 (licence); default = current value | – |
| `DB_SID`, `DB_CDB_NAME` | template (`FMWCDB`) | – (not asked when the DB exists in `/etc/oratab`) |
| `DB_PDB_NAME` | `DB_SERVICE` of `environment.conf`, upper case | it differs from `DB_SERVICE` (case-insensitive) and the DB does not exist yet |
| `DB_LISTENER_PORT` | `DB_PORT` | it differs from `DB_PORT` |
| `DB_SGA_MB` / `DB_PGA_MB` | new file: 15 % of RAM (1536 … 4096 MB, 256 MB steps) / a third of it (≥ 512, 128 MB steps) – the DB shares the host with WebLogic, Forms, Reports; `03-` creates the DB with them and lowers them afterwards to `DB_SGA_POST_MB` / `DB_PGA_POST_MB` | – |
| `DB_DATA_DIR`, `DB_FAST_RECOVERY_AREA`, `DB_RECOVERY_SIZE_MB` | template (under `ORACLE_BASE`); free space shown | – |
| `DB_ARCHIVELOG` | menu false (test) / true (production); default = current value | – |
| `DB_AUDIT_RETAIN_DAYS` | 180 | – |
| `DB_FMW_TABLESPACE` | `RCU_TABLESPACE` of `environment.conf` | it differs from `RCU_TABLESPACE` |

Not asked (template defaults, rarely changed): processes / cursors / files
(RCU minimums), character sets (`AL32UTF8` required), AutoUpgrade home,
`DB_TARGET_RU`, install archive / CVU paths below `PATCH_STORAGE`, free-space
thresholds – edit the file for those.

4. **Consistency check** (every run, `--check` alone): `ORACLE_BASE` /
   `ORACLE_INVENTORY` = `environment.conf`; `/etc/oraInst.loc` =
   `ORACLE_INVENTORY` (the installer uses oraInst.loc – fix the config, never
   re-point it); `DB_PDB_NAME` = `DB_SERVICE`; `DB_LISTENER_PORT` = `DB_PORT`;
   `DB_HOST` is this host; DB home installed, or named after the RU and ~20 GB
   free; SGA + PGA ≤ half of the RAM; `AL32UTF8`; `DB_FMW_TABLESPACE` =
   `RCU_TABLESPACE`; 19.3 base ZIP present (INFO; `01-` checks it on every
   route, also with a gold image; skipped when the home is installed). An
   existing database (oratab) is reported – changing SID / PDB / data dir in
   the file would not move it.

## By hand

```bash
cp 60-RCU-DB-19c/environment_db.conf.example 60-RCU-DB-19c/environment_db.conf
chmod 600 60-RCU-DB-19c/environment_db.conf
vi 60-RCU-DB-19c/environment_db.conf
#   DB_ORACLE_HOME directory = RU of patches_db.csv (db_ru row), e.g. product/19.33.0/db_home1
#   DB_PDB_NAME = DB_SERVICE (upper case), DB_LISTENER_PORT = DB_PORT,
#   DB_FMW_TABLESPACE = RCU_TABLESPACE (all from environment.conf)
#   leave ORACLE_BASE / ORACLE_INVENTORY in the template form ${ORACLE_BASE:-…}
./60-RCU-DB-19c/00a-db_env_interview.sh --check
```

## Related

- [`09-Install/01-setup-interview.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/01-setup-interview.sh) prints the call at the end when
  `LOCAL_REP_DB=true`; the 60- scripts and [`04-oracle_pre_checks.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/04-oracle_pre_checks.sh) point to
  it when the file is missing; [`09-Install/00-install-status.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/00-install-status.sh) lists it as
  the first step of phase DB.
- Template: [`60-RCU-DB-19c/environment_db.conf.example`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/environment_db.conf.example).
