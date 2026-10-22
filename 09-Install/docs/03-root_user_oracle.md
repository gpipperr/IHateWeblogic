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
(preferred over editing `limits.conf` directly). `nofile`/`nproc` are sized
by `ULIMIT_NOFILE`/`ULIMIT_NPROC` in `environment.conf` — set by the
`EXPECTED_SESSIONS` question in `01-setup-interview.sh` (see
`docs/01-setup-interview.md`). `memlock`/`core` are fixed values, not
session-tiered.

```
# Oracle FMW 14.1.2 – oracle user resource limits
oracle   soft   nofile     $ULIMIT_NOFILE    # e.g. 81920
oracle   hard   nofile     $ULIMIT_NOFILE
oracle   soft   nproc      $ULIMIT_NPROC     # e.g. 81920
oracle   hard   nproc      $ULIMIT_NPROC
oracle   soft   stack      10240
oracle   hard   stack      32768
oracle   soft   core       2097152
oracle   hard   core       2097152
oracle   soft   memlock    3145728
oracle   hard   memlock    3145728
```

**Oracle WLS SYSRS minimum values vs. our values:**

| Limit | Oracle minimum (soft) | Oracle minimum (hard) | Our value (soft=hard) | Provenance |
|---|---|---|---|---|
| `nofile` | 4096 | 65536 | **sized by `EXPECTED_SESSIONS`, 65536-131072** | `<100`/`>1000` tiers unconfirmed estimates; `100-500` (81920) confirmed |
| `nproc` | 2047 | 16384 | **sized by `EXPECTED_SESSIONS`, 16384-131072** | same as `nofile` |
| `stack` | 10240 | — | 10240 / 32768 | unchanged, not concurrency-driven |
| `memlock` | — | — | **3145728** (was `unlimited`) | real production reference (see below) |
| `core` | — | — | **2097152 blocks** (was `unlimited`) | real production reference (see below) |

> We set `soft = hard` for `nofile` and `nproc`. This is production practice:
> the JVM and WLS processes start at the maximum limit without needing to
> explicitly raise the soft limit themselves. This meets and exceeds the
> Oracle minimum requirements.

> **Why `nproc` must scale with session count:** Oracle Forms starts one
> dedicated `frmweb` OS process per active Forms session (not threads
> within a shared process). `nproc` accounts for both processes and
> threads under Linux, so WebLogic's own JVM thread pools (AdminServer +
> WLS_FORMS + WLS_REPORTS) sit on top of that per-session process count.
> This is also why `nofile` needs equivalent headroom: each `frmweb`
> process independently opens DB sockets, a WebLogic Forms Servlet socket,
> and `.fmx`/`.mmx`/`.plx`/shared-library handles.

> **Provenance of the non-`<100` values:** `nofile`/`nproc` = 81920 for the
> `100-500` session tier, and `memlock`/`core` as shown above, are taken
> directly from `ulimit -a` on a real production Forms/Reports host running
> 100-500 concurrent sessions (internal reference: `gpiwls01`) — not
> Oracle's published minimum, and not a guess. The `500-1000` tier
> (131072) is a linear estimate around this one confirmed data point; the
> `>1000` tier (262144) is lower confidence still — a cautious doubling of
> the `500-1000` estimate, not derived from any measurement. Neither is
> independently validated — see `docs/00-root_set_os_parameter.md` for the
> equivalent sysctl-side caveat.

> **systemd caveat (not applicable to this project's default setup):** if
> WebLogic/NodeManager were started via a systemd unit instead of the
> `startWebLogic.sh`/NodeManager scripts this project uses, systemd's own
> `LimitNOFILE`/`LimitNPROC` directives would take precedence over
> `/etc/security/limits.d/oracle-fmw.conf` for that service, silently
> capping it back down regardless of what's configured here. Verified this
> project does not do this (only the RCU database side has systemd units,
> `oracle-db.service`/`oracle-listener.service`) — but worth checking if
> you customize the startup method.

> **FMW/DB co-location risk:** if the RCU database also runs on this host,
> `60-RCU-DB-19c/00-root_db_os_baseline.sh` writes its own
> `/etc/security/limits.d/60-oracle-db.conf` for the same `oracle` OS user
> with different (typically higher, e.g. 131072/131072) nofile/nproc values.
> Because `oracle-fmw.conf` sorts after `60-oracle-db.conf` alphabetically,
> pam_limits applies this file's values last — silently overriding the DB
> tier. If co-located, set `ULIMIT_NOFILE`/`ULIMIT_NPROC` in
> `environment.conf` to at least the DB script's values before running
> `--apply`, rather than relying on both files to merge sensibly.

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

The Central Oracle Inventory (`ORACLE_INVENTORY`) sits **one level above** `ORACLE_BASE`,
so it is shared between FMW and DB homes and survives a recreation of `ORACLE_BASE`.

```
ORACLE_BASE  = /u01/app/oracle       ← FMW home, DB home
ORACLE_INVENTORY = /u01/app/oraInventory  ← one level up, shared by all Oracle products
```

Derivation rule: `$(dirname "$ORACLE_BASE")/oraInventory`
Exception: if `ORACLE_BASE` is at depth 1 (e.g. `/oracle`), set `ORACLE_INVENTORY`
explicitly in `environment.conf` — do not place the inventory at root level.

```bash
mkdir -p /u01/app/oracle/fmw
mkdir -p /u01/app/oracle/java
mkdir -p /u01/app/oraInventory      # ← one level above ORACLE_BASE
mkdir -p /u01/user_projects/domains
chown -R oracle:oinstall /u01
chmod -R 755 /u01/app/oracle
chmod 750 /u01/app/oraInventory
```

Also created (owner `oracle:oinstall`, mode 755):

- `PATCH_STORAGE` (default `/srv/patch_storage`) and `$PATCH_STORAGE/bin`
- `FORMS_CLIENT_DIR` (default `/srv/formsWeb`) – **only** for Forms
  installations with `FORMS_CLIENT_DIST=true` (never for `REPORTS_ONLY`):
  the client bundle Nginx serves, see
  [40-forms_client_distribution.md](40-forms_client_distribution.md).

### 8. Create Oracle Inventory pointer

The script creates `/etc/oraInst.loc` (system-wide, root-owned):

```bash
cat > /etc/oraInst.loc << 'EOF'
inventory_loc=/u01/app/oraInventory
inst_group=oinstall
EOF
```

`/etc/oraInst.loc` is the **system-wide** Oracle inventory pointer.
All Oracle installers (OUI, OPatch, `runInstaller`) check `/etc/oraInst.loc` first —
no `-invPtrLoc` argument needed in subsequent install scripts.

> **Why `/etc/oraInst.loc` and not `$ORACLE_BASE/oraInst.loc`?**
> - Only root can write to `/etc/` — this script runs as root, so this is the right time
> - `/etc/oraInst.loc` is Oracle's primary lookup path; it works for all Oracle products
> - Placing it inside `ORACLE_BASE` would lose the inventory pointer if `ORACLE_BASE` is recreated
> - `ORACLE_INVENTORY` outside `ORACLE_BASE` means FMW and DB share one inventory without conflict

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
- Creates full directory tree with correct ownership (`$ORACLE_BASE/*` and `$ORACLE_INVENTORY`)
- Creates `/etc/oraInst.loc` pointing to `$ORACLE_INVENTORY` (system-wide, root-owned)
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
su - oracle -c "ulimit -Hn"   # hard nofile → $ULIMIT_NOFILE (65536 for the <100 tier)
su - oracle -c "ulimit -Sn"   # soft nofile → $ULIMIT_NOFILE

# Environment and locale
su - oracle -c "echo \$ORACLE_HOME"   # → /u01/app/oracle/fmw
su - oracle -c "echo \$JAVA_HOME"
su - oracle -c "locale"
# Expected: LANG=en_US.UTF-8, LC_ALL=en_US.UTF-8

# Sudo (should NOT prompt for password)
su - oracle -c "sudo -n systemctl status nginx 2>&1 | head -1"

# Inventory pointer (system-wide)
cat /etc/oraInst.loc
# Expected:
#   inventory_loc=/u01/app/oraInventory
#   inst_group=oinstall

ls -la /u01/app/oraInventory/

# Directory ownership
ls -la /u01/app/oracle/
# Expected: oracle:oinstall on all entries
```
