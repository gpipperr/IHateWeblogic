# Step: 01-setup-interview.sh – Configuration Interview

**Script:** `09-Install/01-setup-interview.sh`
**Runs as:** `oracle`
**When:** Before all other installation steps

---

## Purpose

Collect all installation parameters interactively and write them to `environment.conf`.
Prompts only for parameters that are not yet set (idempotent — safe to re-run).
Passwords are encrypted immediately and never written in plaintext.

---

## Without the Script (manual)

1. Copy the `environment.conf` template and fill in all parameters manually:

```bash
cp environment.conf.template environment.conf
vi environment.conf
```

2. Encrypt WebLogic admin password:

```bash
# Store in weblogic_sec.conf, then encrypt:
./00-Setup/weblogic_sec.sh
```

3. Encrypt MOS password:

```bash
SYSTEMIDENTIFIER=$(ls -l /dev/disk/by-uuid/ | awk '{ print $9 }' | tail -1)
echo "MOS_PASSWORD=<your-mos-password>" > mos_sec.conf
openssl des3 -pbkdf2 -salt -in mos_sec.conf \
    -out mos_sec.conf.des3 -pass pass:"${SYSTEMIDENTIFIER}"
rm mos_sec.conf
```

4. Verify all required parameters are set before proceeding to the next step.

---

## What the Script Does

- Reads existing `environment.conf` (skip already-set parameters)
- Prompts interactively for each missing parameter with a sensible default
- Validates input immediately (directory exists, port is numeric, etc.)
- Encrypts all passwords via the same mechanism as `00-Setup/weblogic_sec.sh`
- Writes a reusable `setup.conf` template (passwords stripped) for subsequent installs
- Shows a summary of all values and asks for confirmation before writing

---

## Interview Blocks

### Block 1 – Directories & Homes

| Parameter | Default | Validation |
|---|---|---|
| `ORACLE_BASE` | `/u01/app/oracle` | directory writable |
| `ORACLE_HOME` | `$ORACLE_BASE/fmw` | will be created if absent |
| `JDK_HOME` | `$ORACLE_BASE/java/jdk-21` | `java -version` check |
| `DOMAIN_HOME` | `$ORACLE_BASE/domains/fr_domain` | – |
| `PATCH_STORAGE` | `/srv/patch_storage` | disk space ≥ 20 GB |

### Block 2 – Component Selection

```
What should be installed?
  [1] Forms and Reports (default)
  [2] Forms only
  [3] Reports only
```

Sets `INSTALL_COMPONENTS=FORMS_AND_REPORTS | FORMS_ONLY | REPORTS_ONLY`

### Block 3 – Domain Configuration

| Parameter | Default | Notes |
|---|---|---|
| `WLS_ADMIN_PORT` | `7001` | – |
| `WLS_ADMIN_USER` | `webadmin` | – |
| `WLS_ADMIN_PWD` | prompted, encrypted → `weblogic_sec.conf.des3` | – |
| `WLS_NODEMANAGER_PORT` | `5556` | – |
| `WLS_FORMS_PORT` | `9001` | – |
| `WLS_REPORTS_PORT` | `9002` | – |
| `WLS_LISTEN_ADDRESS` | `localhost` | see below |
| `REPORTS_SERVER_NAME` | `repserver01` | – |
| `FORMS_CUSTOMER_DIR` | `/app/forms/custom` | – |
| `REPORTS_CUSTOMER_DIR` | `/app/reports/custom` | – |

#### WLS_LISTEN_ADDRESS

Determines which network interface WebLogic (Admin Server and all Managed Servers) binds to.

```
[1] localhost  – NGINX reverse proxy handles all external access + SSL termination
                 WebLogic is not reachable from outside the host directly.
                 Requires: 09-Install/03-root_nginx_ssl.sh configured and running.
                 → recommended default for this architecture

[2] 0.0.0.0   – all interfaces, WebLogic exposed directly (no reverse proxy)
                 Use only when NGINX is not deployed.

[3] custom     – enter a specific hostname or IP address manually
```

> **Note:** With `localhost`, WebLogic never terminates SSL itself — all certificates
> are managed exclusively in NGINX. This eliminates the need for a WLS keystore and
> avoids the common failure mode of expired certificates inside the WebLogic config.
> See `09-Install/docs/03-root_nginx_ssl.md` for NGINX SSL setup.

### Block 4 – Database (RCU)

| Parameter | Default |
|---|---|
| `DB_HOST` | – |
| `DB_PORT` | `1521` |
| `DB_SERVICE` | – |
| `DB_SCHEMA_PREFIX` | `DEV` |
| DB SYS password | prompted, encrypted → used only for RCU, not persisted |

Immediate connection test via `02-Checks/db_connect_check.sh` after entry.

### Block 5 – My Oracle Support

| Parameter | Default |
|---|---|
| `MOS_USER` | – |
| `MOS_PWD` | prompted, encrypted → `mos_sec.conf.des3` |
| `INSTALL_PATCHES` | comma-separated patch numbers, apply order |

### Block 6 – Summary & Confirmation

Displays all values (passwords shown as `****`).
Asks for confirmation before writing `environment.conf`.

---

## Output Files

| File | Content |
|---|---|
| `environment.conf` | All installation parameters |
| `weblogic_sec.conf.des3` | Encrypted WebLogic admin password |
| `mos_sec.conf.des3` | Encrypted MOS password |
| `setup.conf` | Reusable template (no passwords) |

---

## Flags

| Flag | Description |
|---|---|
| `--apply` | Write files (default: show planned values only) |
| `--reset` | Clear all 09-Install parameters and re-run full interview |
| `--help` | Show usage |
