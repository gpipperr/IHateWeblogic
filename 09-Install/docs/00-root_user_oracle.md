# Step 0a – 00-root_user_oracle.sh

**Script:** `09-Install/00-root_user_oracle.sh`
**Runs as:** `root` or `oracle` with sudo
**Phase:** 0 – OS Preparation

---

## Purpose

Create and configure the `oracle` OS user that will own all FMW files and run all
installation scripts. Set up required OS groups, shell resource limits, sudo rights,
and environment variables.

---

## Without the Script (manual)

### 1. Create OS groups

```bash
groupadd oinstall
groupadd dba
groupadd oper
```

### 2. Create oracle user

```bash
useradd -m -g oinstall -G dba,oper -s /bin/bash -d /home/oracle oracle
passwd oracle   # set initial password or use ssh key
```

### 3. Set shell resource limits

Add to `/etc/security/limits.conf`:

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

### 4. Configure sudo rights

Create `/etc/sudoers.d/oracle-fmw`:

```
oracle ALL=(root) NOPASSWD: /usr/bin/dnf install *
oracle ALL=(root) NOPASSWD: /usr/sbin/sysctl -p
oracle ALL=(root) NOPASSWD: /usr/bin/systemctl start nginx
oracle ALL=(root) NOPASSWD: /usr/bin/systemctl stop nginx
oracle ALL=(root) NOPASSWD: /usr/bin/systemctl reload nginx
oracle ALL=(root) NOPASSWD: /usr/bin/systemctl enable nginx
oracle ALL=(root) NOPASSWD: /bin/cp /etc/sysctl.d/*.conf /etc/sysctl.d/
oracle ALL=(root) NOPASSWD: /bin/cp /etc/security/limits.conf /etc/security/limits.conf
```

```bash
chmod 440 /etc/sudoers.d/oracle-fmw
visudo -c   # verify syntax
```

### 5. Set up oracle bash profile

Add to `/home/oracle/.bash_profile`:

```bash
# Oracle FMW environment
export ORACLE_BASE=/u01/app/oracle
export ORACLE_HOME=$ORACLE_BASE/fmw
export JAVA_HOME=$ORACLE_BASE/java/jdk-21.0.6
export PATH=$JAVA_HOME/bin:$ORACLE_HOME/OPatch:$PATH
export NLS_LANG=AMERICAN_AMERICA.AL32UTF8
export TMP=/tmp
export TMPDIR=/tmp
```

### 6. Create base directories

```bash
mkdir -p /u01/app/oracle/{fmw,java,oraInventory}
mkdir -p /u01/user_projects/domains
chown -R oracle:oinstall /u01
chmod -R 755 /u01/app/oracle
```

### 7. Create Oracle inventory pointer

```bash
cat > /u01/app/oracle/oraInst.loc << 'EOF'
inventory_loc=/u01/app/oracle/oraInventory
inst_group=oinstall
EOF
chown oracle:oinstall /u01/app/oracle/oraInst.loc
```

---

## What the Script Does

- Checks whether `oracle` user and groups already exist (idempotent)
- Creates missing groups and user with correct settings
- Writes `/etc/security/limits.conf` entries (appends, does not overwrite)
- Creates `/etc/sudoers.d/oracle-fmw` and validates with `visudo -c`
- Writes `~oracle/.bash_profile` entries (skips if already present)
- Creates directory structure with correct ownership and permissions
- Creates `oraInst.loc` inventory pointer
- Verifies each step and reports OK/WARN/FAIL

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
# Verify groups
id oracle
# Expected: uid=... gid=...oinstall... groups=...,dba,oper

# Verify limits (as oracle user)
su - oracle -c "ulimit -n"   # should be 65536

# Verify sudo
su - oracle -c "sudo -n sysctl -p 2>&1"   # should not ask for password

# Verify environment
su - oracle -c "echo $JAVA_HOME"
su - oracle -c "java -version"
```
