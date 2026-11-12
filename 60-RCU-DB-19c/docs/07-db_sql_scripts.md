# Step 7 – 07-db_sql_scripts.sh

**Script:** [`60-RCU-DB-19c/07-db_sql_scripts.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/07-db_sql_scripts.sh)
**Runs as:** `oracle`
**Phase:** after the database exists (03-) – DBA tooling for the local RCU DB

---

## Purpose

Provide the DBA SQL script collection
[OraDBASQLScripts](https://github.com/gpipperr/OraDBASQLScripts) in
`~oracle/sql` on a host with a **local** repository database:

- `login.sql`: sqlplus prompt with user / instance;
- around 290 analysis scripts (`@ash`, `@tablespace`, `@sessions` …), called
  by name without a path.

When you select a **DB entry**, the shell switcher `setdb`
([ihw_shell_env.sh](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/tools/bash/ihw_shell_env.sh),
installed by [`09-Install/03-root_user_oracle.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/03-root_user_oracle.sh)) exports `SQLPATH` and
`ORACLE_PATH` (SQLcl) to `~/sql`. sqlplus then finds the scripts and
`login.sql` from any directory.

> **Patching:** `login.sql` changes every sqlplus session (prompt, `termout`,
> formats) and disturbs `datapatch`, `catcon.pl` and `utlrp`. Before a manual
> DB patch run `setdb c` (removes `SQLPATH` / `ORACLE_PATH`), then set only
> `ORACLE_HOME` / `ORACLE_SID`. The IHateWeblogic scripts (`01-`, `03-`,
> [`09-db_patch_rcu.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/09-db_patch_rcu.sh)) unset both themselves: the library does it for every
> non-interactive run.

The scripts are kept as a **git clone**, so an update is one `git pull`.

| Situation of `~/sql` | Without `--apply` | With `--apply` |
|---|---|---|
| missing, or an empty directory | shows the clone command, checks that GitHub is reachable (`git ls-remote`) | `git clone <repo> ~/sql` |
| git clone of the repo (also behind a symlink) | shows the remote, the last commit and whether updates exist (`git fetch --dry-run`) | `git pull --ff-only` |
| git clone of a **different** remote | WARN, nothing is changed | WARN, nothing is changed |
| a normal directory with files (not git) | WARN, nothing is overwritten | WARN – move it aside or use `--archive` |
| `--archive <zip / tar.gz>` (offline) | shows what would be unpacked | unpacks into an empty / missing `~/sql` (GitHub ZIP: the top directory `OraDBASQLScripts-main/` is stripped) |

Without a local database (`LOCAL_REP_DB` not `true` in `environment.conf`)
the script prints INFO and changes nothing. The scripts belong to the DB
host; on a pure FMW host they are not needed.

---

## Prerequisites

- **`git` on the host.** [`09-Install/02-root_os_packages.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/02-root_os_packages.sh) installs
  `git-core` (root). It is also needed for the very first
  `git clone` of IHateWeblogic.
- **Egress to `github.com:443`** for the clone and every pull. Behind a
  customer firewall it must be on the allow-list, the same as for the
  IHateWeblogic clone ([`02-Checks/egress_check.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/02-Checks/egress_check.sh)). Without egress, use
  the offline route below.
- No credentials: the repository is public, HTTPS clone, no SSH key.

Settings (`environment_db.conf`, defaults in the script):

| Variable | Default | Meaning |
|---|---|---|
| `DB_SQL_SCRIPTS_REPO` | `https://github.com/gpipperr/OraDBASQLScripts.git` | clone URL (also a customer mirror) |
| `DB_SQL_SCRIPTS_DIR` | `$HOME/sql` | target; a symlink to an existing clone is fine |

---

## Without the Script (manual)

```bash
# as oracle, DB host with egress to github.com
git clone https://github.com/gpipperr/OraDBASQLScripts.git ~/sql

ls ~/sql/login.sql
# Expected: /home/oracle/sql/login.sql

# update later
git -C ~/sql pull --ff-only
```

**Offline** (no egress on the server). On a workstation:
- download `https://github.com/gpipperr/OraDBASQLScripts/archive/refs/heads/main.zip`;
- copy it with `scp` to `/tmp` on the server.

Then, on the server:

```bash
./60-RCU-DB-19c/07-db_sql_scripts.sh --archive /tmp/OraDBASQLScripts-main.zip --apply
# or by hand:
mkdir -p ~/sql
unzip -q /tmp/OraDBASQLScripts-main.zip -d /tmp/sqlrepo
cp -a /tmp/sqlrepo/OraDBASQLScripts-main/. ~/sql/
rm -rf /tmp/sqlrepo
```

An offline copy has no `.git`. A later update takes the same route again:
move the old directory aside, then unpack.

---

## Verification

```bash
# new shell (loads ~/.bashrc.d/ihw_env.sh)
setdb            # choose the DB entry (FMWCDB)

echo $SQLPATH
# Expected: /home/oracle/sql  (empty before setdb and after setdb c)

sqlplus / as sysdba
# Expected: prompt with user and instance from login.sql, e.g. SYS@FMWCDB>

SQL> @tablespace
```

---

## Relationship to Other Scripts

| Script | Relation |
|---|---|
| [`09-Install/02-root_os_packages.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/02-root_os_packages.sh) | installs `git-core` |
| [`09-Install/03-root_user_oracle.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/09-Install/03-root_user_oracle.sh) | creates `~oracle/sql`, installs the switcher that exports `SQLPATH` / `ORACLE_PATH` |
| [`03-db_create_database.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/03-db_create_database.sh) | the database the scripts are used against |
| [`08-db_auto_start.sh`](https://github.com/gpipperr/IHateWeblogic/blob/main/60-RCU-DB-19c/08-db_auto_start.sh) | next step |
