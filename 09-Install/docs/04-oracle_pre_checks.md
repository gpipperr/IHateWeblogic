# Step 1a – 04-oracle_pre_checks.sh

**Script:** `09-Install/04-oracle_pre_checks.sh`
**Runs as:** `oracle`
**Phase:** 1 – Pre-Install Checks

---

## Purpose

Verify that all prerequisites are met before downloading or installing Oracle FMW.
Fails fast with a clear error if anything is missing — avoiding a failed mid-install.

---

## Without the Script (manual)

### 1. OS version check

```bash
cat /etc/oracle-release   # or /etc/redhat-release
uname -r                  # kernel version
```

Minimum per FMW 14.1.2 Certification Matrix: Oracle Linux 7.9 / 8.x / 9.x

### 2. RAM check

```bash
free -g
# Minimum: 8 GB RAM
```

### 3. Disk space check

```bash
df -h $ORACLE_HOME    # minimum 10 GB free
df -h $ORACLE_BASE    # minimum 5 GB free
df -h $PATCH_STORAGE  # minimum 10 GB free
```

### 4. Java version check

```bash
$JDK_HOME/bin/java -version
# Must be JDK 21.x (not JRE, not system JDK)
# Certified: JDK 21.0.x per FMW 14.1.2 Cert Matrix
```

Or call:

```bash
./02-Checks/java_check.sh
```

### 5. Port availability

```bash
ss -tlnp | grep -E ':7001|:9001|:9002|:5556'
# All ports must be free (not in use by another process)
```

Or call:

```bash
./02-Checks/port_check.sh
```

### 6. Database connectivity (for RCU)

```bash
./02-Checks/db_connect_check.sh
```

### 7. oracle user limits

```bash
su - oracle -c "ulimit -a" | grep -E "open files|max user processes"
# open files: ≥ 65536
# max user processes: ≥ 16384
```

### 8. oraInst.loc

```bash
test -f $ORACLE_BASE/oraInst.loc && echo "OK" || echo "MISSING"
cat $ORACLE_BASE/oraInst.loc
```

### 9. Directory permissions

```bash
ls -ld $ORACLE_HOME $ORACLE_BASE $JDK_HOME
# oracle must be the owner
```

---

## What the Script Does

Runs the following checks in sequence and reports OK/WARN/FAIL for each:

| # | Check | Source |
|---|---|---|
| 1 | OS version, kernel, RAM, disk | → calls `02-Checks/os_check.sh` |
| 2 | JAVA_HOME, JDK version, not system JDK | → calls `02-Checks/java_check.sh` |
| 3 | Ports 7001, 9001, 9002, 5556 free | → calls `02-Checks/port_check.sh` |
| 4 | DB connectivity for RCU | → calls `02-Checks/db_connect_check.sh` |
| 5 | Disk space in ORACLE_HOME, DOMAIN_HOME, PATCH_STORAGE | direct check |
| 6 | oracle user limits (nofile, nproc) | direct check |
| 7 | oraInst.loc exists and is valid | direct check |
| 8 | Directory ownership (oracle owns ORACLE_BASE) | direct check |
| 9 | ORACLE_HOME is empty (not an existing install) | direct check |

Exits with code 2 if any FAIL. Continues past WARNs.

---

## Flags

| Flag | Description |
|---|---|
| (none) | Run all checks |
| `--skip-db` | Skip database connectivity check |
| `--help` | Show usage |

---

## Verification

The script is self-verifying. Review the summary at the end:
- All OK → safe to proceed to `04-oracle_pre_download.sh`
- Any FAIL → fix the reported issue, re-run
