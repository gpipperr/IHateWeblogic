---
title: "DB Profile for the RCU Schemas – No Password Expiry"
description: "Step 6: a database profile for the FMW RCU schemas, so passwords do not expire after 180 days and a wrong password locks no schema (ORA-28001, ORA-28000)."
---

# Step 6 – DB profile for the RCU schemas (`06-db_rcu_profile.sh`)

## Purpose

RCU creates the FMW repository schemas (`<PREFIX>_STB`, `_OPSS`, `_IAU*`,
`_WLS*`, `_MDS`, `_UMS`) with the database profile **`DEFAULT`**. In Oracle
19c that means:

| Limit (DEFAULT) | Value | Consequence for the domain |
|---|---|---|
| `PASSWORD_LIFE_TIME` | 180 days (+7 grace) | data sources and the OPSS bootstrap can no longer log in → servers do not start (ORA-28001 / ORA-28002) |
| `FAILED_LOGIN_ATTEMPTS` | 10 | a data source with a wrong password (e.g. half-done password change) locks the schema (ORA-28000) |

Seen on the test host 2026-10-17: all nine `DEV_*` schemas would have
expired on 2027-04-13.

This script creates the profile **`RCU_DB_PROFILE`** (default `RCU_USER`)
with `PASSWORD_LIFE_TIME UNLIMITED` and `FAILED_LOGIN_ATTEMPTS UNLIMITED`
(all other limits are inherited from `DEFAULT`) – as DB preparation before
RCU, on the DB host.

RCU has **no option** to set a profile – the new schemas still get
`DEFAULT`. The profile is assigned afterwards:

- automatically by `09-Install/07-oracle_setup_repository.sh --apply` (after
  `-createRepository`), or `07-oracle_setup_repository.sh --profile`
  (existing repository, network connection, SYS password from
  `db_sys_sec.conf.des3`)
- or with this script: `--apply --assign` (on the DB host, `/ AS SYSDBA`)

Both use the same idempotent SQL: [`60-RCU-DB-19c/rcu_user_profile.sql`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/rcu_user_profile.sql).

## Call

```bash
./60-RCU-DB-19c/06-db_rcu_profile.sh                    # dry-run: profile + schema state
./60-RCU-DB-19c/06-db_rcu_profile.sh --apply            # create / align the profile
./60-RCU-DB-19c/06-db_rcu_profile.sh --apply --assign   # + assign to existing <PREFIX>_* schemas
./60-RCU-DB-19c/06-db_rcu_profile.sh --apply --assign --prefix DEV --prefix TEST   # several prefixes
```

### Which schemas are changed – prefix selection

The schemas are taken from `SYSTEM.SCHEMA_VERSION_REGISTRY$`, not from
`DBA_USERS LIKE 'DEV%'` – so exactly the RCU schemas are changed, and the
prefix match is exact (`MRC_NAME = 'DEV'`; `DEV2`, `DE` or a foreign user
`DEV_SOMETHING` are not hit).

- Default: `DB_SCHEMA_PREFIX` from `environment.conf` (our own domain).
- `--prefix <P>` (repeatable): select prefixes explicitly, e.g. when several
  domains of the same customer move together. Without `--assign` it only
  marks the prefixes in the overview.
- There is deliberately **no "all prefixes"** switch: one database often
  holds further repositories (TEST/PROD, a second domain, SOA/OBIEE of
  another team) whose accounts may follow another password policy.
- Every run first shows **all prefixes of the registry**
  ([`rcu_registry_overview.sql`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/rcu_registry_overview.sql)): number of schemas, registry rows without
  database user ("missing" = orphaned entries), profile(s), status, earliest
  expiry date. Selected prefixes are marked `*`; a foreign prefix with
  another profile is reported ("left unchanged"), a selected prefix that is
  not in the registry is warned about.

```
=== RCU registry – all prefixes in this database ===
  OK  db_securefile=PREFERRED (RCU registry in tablespace SYSTEM possible)
      Prefix     Schemas Missing Profile(s)             Status             Earliest expiry  EBR
   *  DEV        9       0       RCU_USER               OPEN               -                Y
```

`EBR` = `EDITIONS_ENABLED` of the schemas (Y = RCU database type EBR, N =
ORACLE); mixed values within a prefix are warned about. The dry-run then
lists the schemas of the selected prefixes (ok = target profile, warn =
other profile).

**Before RCU** the registry does not exist yet: the overview reports
`IHW:NOREG` and the script only creates the profile (registry access is
dynamic SQL since 2026-11-02 – before, the static reference failed to
compile and the dry-run stopped with "Cannot query the PDB"; checked
read-only in `CDB$ROOT`, which has no registry). `--assign` without a
registry is a FAIL (`IHW:FAIL`, no RCU repository).

The overview also reports `db_securefile`: with `FORCE` and no registry
yet the first RCU run fails (ORA-43853, registry CLOB in the non-ASSM
tablespace `SYSTEM`) → FAIL; with an existing registry → WARN. Background:
architecture doc §4.2.

| Variable | Source | Default |
|---|---|---|
| `RCU_DB_PROFILE` | `environment.conf` (optional – not written by [`detect_env_conf.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/00-Setup/detect_env_conf.sh) / the interview; set it by hand only for another name) | `RCU_USER` |
| `DB_SCHEMA_PREFIX` | `environment.conf` | – (needed for `--assign`) |
| `DB_ORACLE_HOME`, `DB_SID`, `DB_PDB_NAME` | `environment_db.conf` | – |

## What the SQL does (`rcu_user_profile.sql <profile> <prefixes|->`)

1. `CREATE PROFILE <profile> LIMIT PASSWORD_LIFE_TIME UNLIMITED FAILED_LOGIN_ATTEMPTS UNLIMITED`
   – or `ALTER PROFILE` with the same limits if it exists.
2. With prefixes (comma-separated, e.g. `DEV,TEST`): for every `OWNER` of
   these prefixes (exact `MRC_NAME` match) in
   `SYSTEM.SCHEMA_VERSION_REGISTRY$`: `ALTER USER … PROFILE <profile>`
   (only if different).
3. Shows the two limits and `username / profile / account_status / expiry_date`.

Output lines `IHW:OK:` / `IHW:WARN:` / `IHW:FAIL:` are mapped to
`ok` / `warn` / `fail` by the calling scripts.

## Verification

```sql
ALTER SESSION SET CONTAINER = FMWPDB;
SELECT u.username, u.profile, u.account_status, u.expiry_date
  FROM dba_users u
 WHERE u.username IN (SELECT owner FROM system.schema_version_registry$ WHERE mrc_name = 'DEV')
 ORDER BY u.username;
-- expected: profile RCU_USER, OPEN, expiry_date empty
```

## Manual call

```sql
cd 60-RCU-DB-19c; sqlplus / as sysdba
ALTER SESSION SET CONTAINER = FMWPDB;
@rcu_registry_overview.sql
@rcu_user_profile.sql RCU_USER -          -- before RCU: profile only
@rcu_user_profile.sql RCU_USER DEV        -- after RCU: + assign (prefixes comma-separated)
```

Live 2026-10-17 (test host): `DEFAULT` → `RCU_USER` for all nine schemas,
`EXPIRY_DATE` empty afterwards, running domain not affected; second run
(`09-Install/07-oracle_setup_repository.sh --profile`) idempotent;
`--prefix DE` does not touch `DEV` (warning "not in the registry"),
`--prefix DEV --prefix XYZ` works, an invalid prefix (`DEV;drop`) is
rejected. Not tested: a second real prefix with another profile (the test
DB has only `DEV`).

## Notes

- An account that is already `EXPIRED` keeps that status after the profile
  change – it needs `ALTER USER … IDENTIFIED BY …` with the **same**
  password that the data sources use (otherwise update the data sources and
  the OPSS bootstrap credential too – see the architecture doc §6).
- `FAILED_LOGIN_ATTEMPTS UNLIMITED` removes the lock as brute-force
  protection for these accounts – accepted because only the domain uses
  them; restrict the listener to the FMW hosts.
- `rcu -dropRepository` drops the users – the profile stays in the PDB and
  is reused by the next RCU run.

## Next step

```bash
./60-RCU-DB-19c/08-db_auto_start.sh --apply
./09-Install/07-oracle_setup_repository.sh --apply   # assigns the profile after RCU
```

## References

- Background: [`80-FMW-Architecture/rcu_middleware_architecture.md`](../../80-FMW-Architecture/rcu_middleware_architecture.md) §6.1
- `09-Install/docs/07-oracle_setup_repository.md` – RCU run + profile step
- Reports cookbook (manual install), step 3: same SQL for the DB team
