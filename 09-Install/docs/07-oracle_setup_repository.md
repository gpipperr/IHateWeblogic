# Step 4a – 07-oracle_setup_repository.sh

**Script:** `09-Install/07-oracle_setup_repository.sh`
**Runs as:** `oracle`
**Phase:** 4 – Repository & Domain

---

## Purpose

Run the Repository Creation Utility (RCU) to create the required FMW metadata schemas
in the Oracle database. These schemas are required before the WebLogic domain can be created.

---

## Required Schemas

| Schema suffix | Component | Description |
|---|---|---|
| `_STB` | Service Table | Central FMW metadata repository |
| `_MDS` | Metadata Service | ADF metadata storage |
| `_OPSS` | Oracle Platform Security | Security policies and credentials |
| `_IAU` | Audit | Full audit trail |
| `_IAU_APPEND` | Audit Append | Audit data insert |
| `_IAU_VIEWER` | Audit Viewer | Audit read access |
| `_UCSUMS` | User Messaging Service | UMS configuration |

Schema names are prefixed with `DB_SCHEMA_PREFIX` (e.g. `DEV_STB`, `DEV_MDS`, ...).

---

## Without the Script (manual)

### 1. Write RCU password file

Create a temporary password file (one password per line):
- Line 1: common schema password (for all schemas)

```bash
cat > /tmp/rcu_passwords.txt << 'EOF'
MySecureSchemaPassword123
EOF
chmod 600 /tmp/rcu_passwords.txt
```

### 2. Run RCU

```bash
$ORACLE_HOME/oracle_common/bin/rcu \
    -silent \
    -createRepository \
    -connectString "${DB_HOST}:${DB_PORT}:${DB_SERVICE}" \
    -dbUser sys \
    -dbRole sysdba \
    -schemaPrefix "${DB_SCHEMA_PREFIX}" \
    -component STB \
    -component MDS \
    -component OPSS \
    -component IAU \
    -component IAU_APPEND \
    -component IAU_VIEWER \
    -component UCSUMS \
    -f < /tmp/rcu_passwords.txt
```

### 3. Clean up password file

```bash
rm -f /tmp/rcu_passwords.txt
```

### 4. Verify schemas were created

```bash
sqlplus sys/${DB_SYS_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_SERVICE} as sysdba << 'EOF'
SELECT username FROM dba_users
WHERE username LIKE UPPER('${DB_SCHEMA_PREFIX}')  || '_%'
ORDER BY username;
EXIT;
EOF
```

Expected: 7 schemas listed.

---

## Tablespace Configuration

### Default: RCU creates its own tablespaces

If `RCU_TABLESPACE` is **not** set in `environment.conf`, RCU automatically creates
tablespaces for each schema component using prefix-based names:

| Component | Default tablespace created by RCU |
|---|---|
| STB, MDS, UCSUMS | `<PREFIX>_STB` |
| OPSS | `<PREFIX>_IAS_OPSS` |
| IAU, IAU_APPEND, IAU_VIEWER | `<PREFIX>_IAS_AUDIT` |

No DBA action required. Suitable for dev, test and QA environments.

### Optional: single pre-created tablespace (enterprise / production)

The DBA pre-creates one tablespace; all FMW schemas share it.

Set in `environment.conf` (via `01-setup-interview.sh` or manually):

```bash
RCU_TABLESPACE=FMW_DATA        # DBA must create this before running RCU
RCU_TEMP_TABLESPACE=TEMP       # default: TEMP (system temp tablespace)
```

**DBA pre-creation SQL:**

```sql
CREATE TABLESPACE FMW_DATA
  DATAFILE '/u01/oradata/mydb/fmw_data01.dbf'
  SIZE 500M AUTOEXTEND ON NEXT 100M MAXSIZE UNLIMITED;
```

When `RCU_TABLESPACE` is set, the script adds:

```bash
rcu ... -tablespace FMW_DATA -tempTablespace TEMP ...
```

> **Note:** `RCU_TABLESPACE` and `RCU_TEMP_TABLESPACE` are set by
> `09-Install/01-setup-interview.sh` (Block 4 – Database) and are kept in
> `environment.conf`. Leave `RCU_TABLESPACE` empty to use RCU defaults.

---

## What the Script Does

- Reads `DB_HOST`, `DB_PORT`, `DB_SERVICE`, `DB_SCHEMA_PREFIX`, `ORACLE_HOME`
  from `environment.conf`
- Reads optional `RCU_TABLESPACE` / `RCU_TEMP_TABLESPACE` from `environment.conf`
  (if set, passes `-tablespace` / `-tempTablespace` to RCU; otherwise RCU creates
  its own tablespaces automatically)
- Decrypts `DB_SYS_PWD` + `DB_SCHEMA_PWD` from `db_sys_sec.conf.des3`
  (written by `00-Setup/database_rcu_sec.sh` or `09-Install/01-setup-interview.sh`)
- Creates `/tmp/rcu_passwords.tmp` with correct permissions (600)
- Runs `rcu -silent -createRepository` with all 7 components
- Deletes the password file immediately via `trap cleanup EXIT`
  (cleanup runs even if RCU fails or script is interrupted)
- Verifies schemas exist in the database after creation
- Checks tablespace usage after creation

---

## Flags

| Flag | Description |
|---|---|
| (none) | Show what would be created (connection info, schema names) |
| `--apply` | Run RCU and create schemas |
| `--drop` | Drop existing schemas (CAUTION: destroys data) |
| `--help` | Show usage |

---

## Verification

```bash
# Check schemas exist
$ORACLE_HOME/oracle_common/bin/rcu \
    -silent \
    -checkRequirements \
    -connectString "${DB_HOST}:${DB_PORT}:${DB_SERVICE}" \
    -dbUser sys -dbRole sysdba \
    -schemaPrefix ${DB_SCHEMA_PREFIX} \
    -component STB
```

---

## Notes

- RCU requires a SYSDBA connection to create schemas — this is a one-time operation
- Passwords (`DB_SYS_PWD`, `DB_SCHEMA_PWD`) are never written to disk in plaintext;
  the password file is created in `/tmp` with mode 600 and deleted via `trap EXIT`
  — cleanup runs even if RCU fails or the script is interrupted with Ctrl+C
- `DB_SYS_PWD` + `DB_SCHEMA_PWD` are stored together in `db_sys_sec.conf.des3`
  → manage with `00-Setup/database_rcu_sec.sh --apply`
- RCU logs: `$ORACLE_HOME/oracle_common/rcu/log/`
- If RCU fails: check `$ORACLE_HOME/oracle_common/rcu/log/` for the error
- Re-running RCU with `-createRepository` fails if schemas already exist
  → use `--drop` first (CAUTION: destroys all FMW configuration data)
- `RCU_TABLESPACE` / `RCU_TEMP_TABLESPACE`: set in `environment.conf` via
  `01-setup-interview.sh` (Block 4); leave empty to let RCU manage tablespaces
