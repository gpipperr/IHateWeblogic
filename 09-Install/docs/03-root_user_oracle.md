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

The script writes a drop-in file `/etc/security/limits.d/oracle-fmw.conf`
(preferred over editing `limits.conf` directly).

```
# Oracle FMW 14.1.2 – oracle user resource limits
oracle   soft   nofile     65536
oracle   hard   nofile     65536
oracle   soft   nproc      16384
oracle   hard   nproc      16384
oracle   soft   stack      10240
oracle   hard   stack      32768
oracle   soft   core       unlimited
oracle   hard   core       unlimited
oracle   soft   memlock    unlimited
oracle   hard   memlock    unlimited
```

**Oracle WLS SYSRS minimum values vs. our values:**

| Limit | Oracle minimum (soft) | Oracle minimum (hard) | Our value (soft=hard) |
|---|---|---|---|
| `nofile` | 4096 | 65536 | **65536** |
| `nproc` | 2047 | 16384 | **16384** |
| `stack` | 10240 | — | 10240 / 32768 |
| `memlock` | — | — | unlimited |
| `core` | — | — | unlimited (for JVM crash dumps) |

> We set `soft = hard` for `nofile` and `nproc`. This is production practice:
> the JVM and WLS processes start at the maximum limit without needing to
> explicitly raise the soft limit themselves. This meets and exceeds the
> Oracle minimum requirements.

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
export ORACLE_HOME=$ORACLE_BASE/fmw
export JAVA_HOME=/u01/app/oracle/java/jdk-21
export PATH=$JAVA_HOME/bin:$ORACLE_HOME/OPatch:$PATH
# Unicode locale – required for Oracle Forms/Reports Unicode support
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
# Oracle NLS – must match database character set
export NLS_LANG=AMERICAN_AMERICA.AL32UTF8
export TMP=/tmp
export TMPDIR=/tmp
umask 0022
```

> **Note:** The script uses `ORACLE_HOME` (= `$ORACLE_BASE/fmw`) as the FMW home
> variable. This is the standard Oracle convention. Do not confuse with a Database
> `ORACLE_HOME` — on this host, `ORACLE_HOME` points exclusively to the FMW install.

### 6. System locale (Unicode support)

Oracle Forms and Reports require a UTF-8 locale for correct Unicode handling.
Check and set the system-wide locale:

```bash
# Check current locale
echo $LANG
echo $LC_ALL
localectl status

# Set system locale (OL9)
localectl set-locale LANG=en_US.UTF-8
```

> **Why both LANG and LC_ALL?**
> - `LANG` is the base locale setting for all categories.
> - `LC_ALL` overrides all individual `LC_*` variables — it guarantees a consistent
>   UTF-8 environment even if individual variables are set elsewhere.
> - `NLS_LANG` is Oracle-specific and controls how the Oracle client/forms engine
>   encodes characters. It is independent of the POSIX locale.

Verify after re-login:

```bash
su - oracle
locale
# Expected: all entries show en_US.UTF-8 (or LANG/LC_ALL at minimum)
```

### 7. Create directory structure

```bash
mkdir -p /u01/app/oracle/fmw
mkdir -p /u01/app/oracle/java
mkdir -p /u01/app/oracle/oraInventory
mkdir -p /u01/user_projects/domains
chown -R oracle:oinstall /u01
chmod -R 755 /u01/app/oracle
chmod 750 /u01/app/oracle/oraInventory
```

### 8. Create Oracle Inventory pointer

The script creates `$ORACLE_BASE/oraInst.loc` (= `/u01/app/oracle/oraInst.loc`):

```bash
cat > /u01/app/oracle/oraInst.loc << 'EOF'
inventory_loc=/u01/app/oracle/oraInventory
inst_group=oinstall
EOF
```

> **Two possible locations — the script uses the user-space path:**
> - `/etc/oraInst.loc` — system-wide default; Oracle installers check this first
>   (requires root write; created manually if needed for enterprise environments)
> - `/u01/app/oracle/oraInst.loc` — user-space fallback under `ORACLE_BASE`;
>   created by this script; sufficient for standalone FMW installations

### 9. Bootstrap handover (final root step)

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
- Creates `$ORACLE_BASE/oraInst.loc` inventory pointer (user-space path)
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

# Environment and locale
su - oracle -c "echo \$ORACLE_HOME"   # → /u01/app/oracle/fmw
su - oracle -c "echo \$JAVA_HOME"
su - oracle -c "locale"
# Expected: LANG=en_US.UTF-8, LC_ALL=en_US.UTF-8

# Sudo (should NOT prompt for password)
su - oracle -c "sudo -n systemctl status nginx 2>&1 | head -1"

# Inventory pointer
cat /u01/app/oracle/oraInst.loc

# Directory ownership
ls -la /u01/app/oracle/
# Expected: oracle:oinstall on all entries
```
