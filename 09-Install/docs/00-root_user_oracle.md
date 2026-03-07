# Step 03 – 03-root_user_oracle.sh

**Script:** `09-Install/03-root_user_oracle.sh`
**Runs as:** `root`
**Phase:** 0 – OS Preparation

---

## Purpose

Create and configure the `oracle` OS user that owns all FMW files and runs all
installation scripts. Set up the required OS group, shell resource limits, sudo rights,
environment variables, and directory structure.

---

## Groups: FMW vs. Database

For a **WebLogic / Forms / Reports** installation (no Oracle Database on this host),
only **one** group is required:

| Group | GID | Purpose | Required for FMW? |
|---|---|---|---|
| `oinstall` | 1000 | Oracle Inventory group — required by every Oracle product installer | **Yes** |
| `dba` | — | Grants SYSDBA privilege on an Oracle DB | No — DB-only |
| `oper` | — | Grants SYSOPER privilege on an Oracle DB | No — DB-only |
| `backupdba` | — | RMAN backup privilege | No — DB-only |

> **Rule:** If there is no Oracle Database on this host, only `oinstall` is needed.
> Adding `dba`/`oper` is harmless but misleading — omit them for clarity.

---

## Without the Script (manual)

### 1. Create OS group

```bash
groupadd -g 1000 oinstall
```

### 2. Create oracle user

```bash
useradd -m -u 1100 -g oinstall -s /bin/bash -d /home/oracle oracle
passwd oracle   # set initial password, or configure SSH key
```

### 3. Set shell resource limits

Add to `/etc/security/limits.conf` (or create `/etc/security/limits.d/oracle-fmw.conf`):

```
oracle  soft  nofile   65536
oracle  hard  nofile   65536
oracle  soft  nproc    16384
oracle  hard  nproc    16384
oracle  soft  stack    10240
oracle  hard  stack    32768
oracle  soft  memlock  unlimited
oracle  hard  memlock  unlimited
```

Verify that PAM loads limits:

```bash
grep pam_limits /etc/pam.d/system-auth
# Must contain: session required pam_limits.so
```

### 4. Configure sudo rights

Create `/etc/sudoers.d/oracle-fmw`:

```
# Oracle FMW maintenance – allow oracle to manage Nginx and system tools
oracle ALL=(root) NOPASSWD: /usr/bin/systemctl start nginx
oracle ALL=(root) NOPASSWD: /usr/bin/systemctl stop nginx
oracle ALL=(root) NOPASSWD: /usr/bin/systemctl reload nginx
oracle ALL=(root) NOPASSWD: /usr/bin/systemctl restart nginx
oracle ALL=(root) NOPASSWD: /usr/bin/systemctl enable nginx
oracle ALL=(root) NOPASSWD: /usr/bin/nginx -t
```

```bash
chmod 440 /etc/sudoers.d/oracle-fmw
visudo -c   # verify syntax
```

### 5. Set up oracle bash profile

Add to `/home/oracle/.bash_profile`:

```bash
# --- Oracle FMW Environment -------------------------------------------
export ORACLE_BASE=/u01/app/oracle
export FMW_HOME=$ORACLE_BASE/fmw
export JAVA_HOME=/u01/app/oracle/java/jdk-21
export PATH=$JAVA_HOME/bin:$FMW_HOME/OPatch:$PATH
export NLS_LANG=AMERICAN_AMERICA.AL32UTF8
export TMP=/tmp
export TMPDIR=/tmp
umask 0022
```

### 6. Create directory structure

```bash
mkdir -p /u01/app/oracle/fmw
mkdir -p /u01/app/oracle/java
mkdir -p /u01/app/oracle/oraInventory
mkdir -p /u01/user_projects/domains
chown -R oracle:oinstall /u01
chmod -R 755 /u01/app/oracle
chmod 750 /u01/app/oracle/oraInventory
```

### 7. Create Oracle Inventory pointer

```bash
cat > /etc/oraInst.loc << 'EOF'
inventory_loc=/u01/app/oracle/oraInventory
inst_group=oinstall
EOF
chmod 644 /etc/oraInst.loc
```

> Note: `/etc/oraInst.loc` is the system-wide default location that Oracle installers
> check first. `/u01/app/oracle/oraInst.loc` is a user-space fallback used if root
> has not created the system file.

### 8. Bootstrap handover (final root step)

After this script completes, transfer ownership of the IHateWeblogic repository
to the oracle user so all further scripts run under `oracle`:

```bash
chown -R oracle:oinstall /path/to/IHateWeblogic
find /path/to/IHateWeblogic -name "*.sh" -exec chmod u+x {} \;
```

From here: `su - oracle`, then continue with `04-oracle_pre_checks.sh`.

---

## What the Script Does

- Checks for existing `oinstall` group; creates it with fixed GID 1000 if missing
- Checks for existing `oracle` user; creates with UID 1100, primary group `oinstall`
- Checks user's primary group and shell; warns on mismatch
- Writes limits to `/etc/security/limits.d/oracle-fmw.conf` (separate file, not limits.conf)
- Verifies PAM loads limits (`pam_limits.so` in system-auth)
- Creates `/etc/sudoers.d/oracle-fmw` and validates with `visudo -c`
- Writes `~oracle/.bash_profile` FMW block (checks for existing entries, no duplicates)
- Creates full directory tree with correct ownership
- Creates `/etc/oraInst.loc` inventory pointer
- Transfers repository ownership to `oracle:oinstall` (bootstrap handover)

---

## Flags

| Flag | Description |
|---|---|
| (none) | Show what would be done, make no changes |
| `--apply` | Execute all changes |
| `--help` | Show usage |

---

## Verification

```bash
# Group and user
id oracle
# Expected: uid=1100(oracle) gid=1000(oinstall) groups=1000(oinstall)

# Resource limits (as oracle user)
su - oracle -c "ulimit -Hn"   # hard nofile → 65536
su - oracle -c "ulimit -Sn"   # soft nofile → 65536

# Environment
su - oracle -c "echo \$FMW_HOME"
su - oracle -c "echo \$JAVA_HOME"

# Sudo (should NOT prompt for password)
su - oracle -c "sudo -n systemctl status nginx 2>&1 | head -1"

# Inventory pointer
cat /etc/oraInst.loc

# Directory ownership
ls -la /u01/app/oracle/
# Expected: oracle:oinstall on all entries
```
