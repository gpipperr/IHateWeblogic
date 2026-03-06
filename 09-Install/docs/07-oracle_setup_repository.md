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

## What the Script Does

- Reads `DB_HOST`, `DB_PORT`, `DB_SERVICE`, `DB_SCHEMA_PREFIX`, `ORACLE_HOME`
  from `environment.conf`
- Decrypts the DB SYS password from its encrypted store
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
- The SYS password is never written to disk in plaintext; the password file is
  created in `/tmp` with restricted permissions and deleted after the RCU call
- RCU logs: `$ORACLE_HOME/oracle_common/rcu/log/`
- If RCU fails: check `$ORACLE_HOME/oracle_common/rcu/log/` for the error
- Re-running RCU with `-createRepository` fails if schemas already exist
  → use `--drop` first (CAUTION: destroys all FMW configuration data)
