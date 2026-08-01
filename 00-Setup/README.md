# 00-Setup – Library, Environment Detection & Credentials

**Module:** `00-Setup/`
**Runs as:** `oracle` (all scripts here run unprivileged)
**Phase:** Foundation – sourced/used by every other module in this repository

---

## Purpose

This is the foundation layer every other script in the repository depends on:

- **`IHateWeblogic_lib.sh`** – the shared library (output helpers, password
  encryption, environment helpers) that every script sources first.
- **`environment.conf`** – the single source of truth for all paths, ports and
  instance names, generated and maintained by the scripts in this folder.
- **Credential storage** – WebLogic, RCU/database and My Oracle Support
  passwords, all encrypted with the same machine-local `openssl des3` concept.

Nothing in this folder installs software. It only detects, records and
secures the configuration that the rest of the library (`09-Install/`,
`02-Checks/`, `05-ReportsPerformance/`, …) reads from `environment.conf`.

---

## Contents at a Glance

| File | Type | Purpose |
|---|---|---|
| `IHateWeblogic_lib.sh` | library (source only) | Output functions, password encryption, environment helpers |
| `init_env.sh` | script | Detect FMW/DB paths → generate/extend `environments/<name>.conf` |
| `set_env.sh` | script (must be **sourced**) | Switch the active environment via a numbered menu |
| `weblogic_sec.sh` | script | Store/verify the WebLogic admin password (encrypted) |
| `database_rcu_sec.sh` | script | Store/verify the RCU `SYS` + FMW schema password (encrypted) |
| `mos_sec.sh` | script | Store/verify My Oracle Support credentials (encrypted) |
| `getPWDs.sh` | script, **gitignored** | Debug helper – decrypts and prints all `*.des3` files in plaintext |
| `report_env.sh` | stub, not implemented | Planned: collect diagnostics into one standalone HTML report |
| `set_environment.md` | doc | Deep-dive on the `environment.conf` symlink + `environments/` concept |
| `environments/` | directory | One conf file per environment (FMW domain or DB home) + templates |

---

## Script Reference

### IHateWeblogic_lib.sh

Central library. **Must be sourced, never executed** (it refuses to run
directly and prints a warning if you try).

```bash
source 00-Setup/IHateWeblogic_lib.sh
```

What it provides:

| Category | Functions |
|---|---|
| Output (tee to `$LOG_FILE`) | `ok()`, `warn()`, `fail()`, `info()`, `section()`, `printError()`, `printLine()`, `printList()` |
| Raw color (no log, inline) | `_color_green()`, `_color_yellow()`, `_color_red()`, `_color_bold()`, `_color_cyan()` |
| Interactive prompts | `askYesNo "prompt" [y|n]`, `readSelection "prompt" default opt1 opt2 …` |
| Utility | `init_log [dir]`, `backup_file file [dir]`, `check_env_conf [path]`, `print_summary` |
| Password / secrets (pipperr.de concept) | `_get_system_identifier`, `_write_secrets_file`, `load_secrets_file`, `save_weblogic_password`, `load_weblogic_password` |

Every script in the repository follows the same pattern at the top:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/IHateWeblogic_lib.sh"   # or ../00-Setup/... depending on depth
check_env_conf "$ROOT_DIR/environment.conf" || exit 2
source "$ROOT_DIR/environment.conf"
init_log
```

`print_summary` at the end sets `$EXIT_CODE` (0=OK, 1=WARN, 2=FAIL) — every
script exits with it.

---

### init_env.sh

Detects paths and running processes, then writes or extends a named conf
file under `environments/` and updates the `environment.conf` symlink.
**Use once per environment** (at install time, or when a new domain/instance
appears). For daily switching between already-configured environments, use
`set_env.sh` instead.

```bash
./00-Setup/init_env.sh                    # FMW mode, dry-run (default)
./00-Setup/init_env.sh --apply            # FMW mode, write conf
./00-Setup/init_env.sh --apply --interview  # confirm/override every detected value
./00-Setup/init_env.sh --db --apply       # DB mode: detect Oracle DB home
```

| Option | Effect |
|---|---|
| `--apply` | Write `environments/<name>.conf` and update the `environment.conf` symlink (FMW mode only; DB mode never touches the symlink) |
| `--interview` | Show each detected value and let you confirm (Enter) or override it |
| `--db` | Switch to DB mode: detect `ORACLE_HOME`/`ORACLE_SID` of an Oracle Database instead of FMW |
| `--help` | Usage |

**Two very different behaviors depending on state:**

1. **No `environment.conf` symlink exists yet** (very first run on a fresh
   machine): the script cannot detect a running domain, so it collects the
   handful of **install parameters** needed by `09-Install/` (`ORACLE_BASE`,
   `ORACLE_HOME`, `JDK_HOME`, `DOMAIN_HOME`, `PATCH_STORAGE`,
   `INSTALL_COMPONENTS`) and writes a minimal conf. This is the read-only
   *analysis* equivalent of `09-Install/01-setup-interview.sh` for people who
   skip the full guided interview.

2. **`environment.conf` already exists** (post-installation, or re-run after
   a config change): the script actively scans the running system —
   `ps` for WebLogic/NodeManager/Reports processes, standard FMW paths,
   `config.xml`, `jps-config.xml`, the `ReportsToolsComponent` /
   `ReportsServerComponent` / `FORMS` directories — and either:
   - **extends** the existing conf with any keys that are still missing
     (existing values are never overwritten), or
   - on a brand-new domain, writes the full **runtime** section (Reports
     instances, Forms instance, WLS managed server, `rwserver.conf` path,
     Java, DB connection from `jps-config.xml`, DISPLAY check, …).

Detection covers (non-exhaustive): `ORACLE_HOME`, `DOMAIN_HOME`,
`REPORTS_COMPONENT_HOME` + all Reports Tools/Server instances,
`FORMS_INSTANCE_NAME` + `WLS_FORMS_SERVER`, `WLS_MANAGED_SERVER`,
`RWSERVER_CONF`, `CGICMD_DAT`, `JDK_HOME`, the OS user running WebLogic, and
the DB connection parameters used by JRF (`DB_HOST`/`DB_PORT`/`DB_SERVICE`).

Without `--apply` every mode is a pure dry-run/preview — nothing is written.
This makes `./00-Setup/init_env.sh` (no flags) the standard way to **analyze
an existing environment** without changing anything.

---

### set_env.sh

Switches between multiple environments already registered in
`environments/` — an FMW/WebLogic domain or an Oracle Database home — via a
numbered menu. **Must be sourced**, otherwise the detected variables never
reach your shell.

```bash
. ./00-Setup/set_env.sh          # interactive menu, sets shell env
. ./00-Setup/set_env.sh 1        # direct select #1, no menu
./00-Setup/set_env.sh --list     # list only, no environment change
```

| Option | Effect |
|---|---|
| *(none, sourced)* | Show numbered menu of all `environments/*.conf`, select, export variables |
| `N` (sourced) | Select entry `N` directly, no menu |
| `--list` | Print the menu and exit — does not touch the symlink or shell |
| `--help` | Usage |

Exported variables depend on the conf's `# ENV_TYPE=` (explicit comment, or
auto-detected: `DOMAIN_HOME` present → FMW, `ORACLE_SID` present → DB):

| ENV_TYPE | Exports | PATH addition |
|---|---|---|
| `FMW` | `ORACLE_HOME`, `DOMAIN_HOME`, `JDK_HOME` | `$ORACLE_HOME/bin`, `$ORACLE_HOME/oracle_common/common/bin`, `$JDK_HOME/bin` |
| `DB` | `ORACLE_HOME`, `ORACLE_SID`, `ORACLE_BASE`, `NLS_LANG` | `$ORACLE_HOME/bin` |

Full concept, `.bash_profile` integration and troubleshooting:
see [set_environment.md](set_environment.md).

---

### Credential Scripts (weblogic_sec.sh / database_rcu_sec.sh / mos_sec.sh)

> **⚠️ Security warning — read before relying on this concept**
>
> The goal of encrypting these files is **only** to keep passwords out of Git —
> so a plaintext password can never end up in a commit, a diff, a pull
> request, or a backup of the repository. It is **not** a defense against
> anyone who already has access to this machine.
>
> Anyone who can read files as the `oracle` OS user (or root) can run the
> exact same script (`./weblogic_sec.sh`, no `--apply`) and decrypt the
> credentials themselves — the decryption key is derived from the machine
> itself (`/dev/disk/by-uuid` / `/etc/machine-id`), which is public
> information to anyone logged into that host. This is **security through
> obscurity** (Security by Verschleierung), not real access control.
>
> **Encryption-at-rest is better than a plaintext file — it stops the file
> from being useful if leaked, copied, or accidentally committed — but it
> provides no protection against a compromised or shared machine.** Treat
> file-system access to this server (OS user separation, `chmod 600`,
> `sudo` policy, who has SSH access) as the actual security boundary, not
> the `.des3` encryption.

All three follow the identical pipperr.de encryption concept and the
identical command pattern — only the stored fields differ:

| Script | Encrypted file | Stored fields |
|---|---|---|
| `weblogic_sec.sh` | `weblogic_sec.conf.des3` | `WL_USER`, `WL_PASSWORD`, `WL_ADMIN_URL` |
| `database_rcu_sec.sh` | `db_sys_sec.conf.des3` | `DB_SYS_PWD` (SYSDBA, RCU only), `DB_SCHEMA_PWD` (all FMW schemas) |
| `mos_sec.sh` | `mos_sec.conf.des3` | `MOS_USER`, `MOS_PWD` |

```bash
./00-Setup/weblogic_sec.sh          # read-only: test decryption on this machine
./00-Setup/weblogic_sec.sh --apply  # prompt for credentials, encrypt, verify round-trip
```

Behavior (identical for all three):

1. **Without `--apply`**: reads the existing `*.des3` file (if present) and
   attempts to decrypt it on this machine — proves the credentials are still
   usable without ever printing them. Nothing is written.
2. **With `--apply`**: prompts for the credentials (password entered twice,
   masked input), shows a confirmation summary, then on confirmation:
   - backs up any existing `*.des3` file (timestamped)
   - encrypts via `openssl des3 -pbkdf2` using a key derived from this
     machine's disk UUID (`/dev/disk/by-uuid`, falling back to
     `/etc/machine-id`)
   - immediately deletes the plaintext intermediate file
   - performs a **round-trip decryption test** and reports success/failure

Because the encryption key is derived from the machine itself, an encrypted
file **cannot be decrypted on a different host** — copying `*.des3` files
between servers (e.g. via `git clone` or backup restore) is safe by design;
they simply won't decrypt anywhere else, so they must be recreated with
`--apply` on the new machine.

`weblogic_sec.sh` additionally enforces the WebLogic password policy while
prompting (min. 8 characters, at least one digit or special character —
avoids the well-known WLST error 60455 during later domain operations).

`database_rcu_sec.sh` stores **two** passwords in one file because RCU needs
both: the `SYS` password (used once, only during `07-oracle_setup_repository.sh`)
and the schema password assigned to every `<PREFIX>_STB`, `<PREFIX>_MDS`, …
schema created by RCU.

---

### getPWDs.sh

**Debug helper only — gitignored, never commit its output.** Decrypts and
prints every `*.des3` file it finds under the repository root in plaintext
to the console.

```bash
./00-Setup/getPWDs.sh
```

Use this when you need to verify what is actually stored (e.g. after a
migration) or hand credentials to a colleague verbally. There is no
`--apply` flag — it never writes anything, only reads and displays.

---

### report_env.sh

**Not implemented yet** (stub — `TODO: Implement`, exits `0` immediately).
Planned purpose: collect all diagnostic log files from a run into one
standalone HTML report for handover / support cases.

---

### environments/

One `*.conf` file per environment on this server — an FMW/WebLogic domain
or an Oracle Database home. See [set_environment.md](set_environment.md)
for the full concept. Quick reference:

```
00-Setup/environments/
├── README.md                    – committed, quick reference
├── fmw_prod.conf.template       – committed, copy+adapt for a new FMW domain
├── db_prod.conf.template        – committed, copy+adapt for a new DB home
├── fmw_prod.conf                – gitignored, server-specific (generated)
└── db_ORCL.conf                 – gitignored, server-specific (generated)
```

`environment.conf` in the project root is always a **symlink** into this
directory, pointing at whichever conf is currently active.

---

## Full Setup Walkthrough

This is the complete path from an empty machine to a fully configured,
credential-secured environment. It corresponds to Phase 1 of the
[project Lifecycle Overview](../README.md#lifecycle-overview).

### 1. Create the base directory and clone the repository

```bash
# As the user that will run the scripts (root initially, oracle later —
# see 09-Install/03-root_user_oracle.sh, which chowns the repo to oracle):
mkdir -p /home/oracle
cd /home/oracle
git clone git@github.com:gpipperr/IHateWeblogic.git
cd IHateWeblogic
find . -name "*.sh" -exec chmod u+x {} \;
```

No fixed path is required by any script — everything is derived from
`SCRIPT_DIR`/`ROOT_DIR` at runtime — but `/home/oracle/IHateWeblogic` matches
the `oracle` OS user's home directory created by
`09-Install/03-root_user_oracle.sh` and is the path used throughout the
`09-Install/docs/`.

### 2. Fill in all parameters

Two different starting points, same result — a complete `environment.conf`:

**New installation (nothing exists on the machine yet):**

```bash
./09-Install/01-setup-interview.sh --apply
```

Full guided interview: install parameters (`ORACLE_BASE`, `ORACLE_HOME`,
`JDK_HOME`, `DOMAIN_HOME`, …), MOS credentials, DB connection, RCU passwords —
all in one pass, idempotent (safe to re-run, only prompts for what's still
missing). See `09-Install/docs/01-setup-interview.md`.

**Existing system, no `environment.conf` yet** (e.g. taking over an
already-installed environment):

```bash
./00-Setup/init_env.sh --interview --apply
```

Scans the running system and shows every detected value for confirmation.

**After installation, or after any config change** (extend with runtime
values, e.g. after `09-Install/13-oracle_setup_reports.sh` or
`14-oracle_setup_forms.sh` created new instances):

```bash
./00-Setup/init_env.sh --apply
```

Only appends keys that are still missing — existing values are never
overwritten.

### 3. Store the passwords

Each credential type is stored in its own encrypted file, all following the
same pipperr.de concept (`openssl des3` + machine UUID key):

```bash
./00-Setup/weblogic_sec.sh --apply        # WebLogic admin password
./00-Setup/database_rcu_sec.sh --apply    # RCU: SYS + FMW schema password
./00-Setup/mos_sec.sh --apply             # My Oracle Support credentials
```

(`09-Install/01-setup-interview.sh --apply` already calls the first two of
these as part of the guided interview — run them individually only when you
need to rotate a single credential later.)

Verify at any time, without changing anything:

```bash
./00-Setup/weblogic_sec.sh          # read-only decryption test
./00-Setup/database_rcu_sec.sh
./00-Setup/mos_sec.sh
```

### 4. Analyze an existing environment (read-only)

Before changing anything on a system you didn't build yourself, run the
detection scripts **without** `--apply` — every one of them is read-only by
default:

```bash
./00-Setup/init_env.sh                 # what would be written/updated?
./00-Setup/set_env.sh --list           # which environments are registered?
./00-Setup/weblogic_sec.sh             # can existing credentials be decrypted here?
```

This gives a full picture — detected `ORACLE_HOME`/`DOMAIN_HOME`, Reports
and Forms instances, running processes, DB connection, missing pieces (e.g.
`DISPLAY` not set) — before you commit to any change.

### 5. Configure a new environment

Once analysis confirms the detected values are correct (or after adjusting
them via `--interview`), make it official:

```bash
./00-Setup/init_env.sh --apply                 # write/extend environment.conf
./00-Setup/init_env.sh --db --apply            # additionally register a DB home
. ./00-Setup/set_env.sh                        # activate it in the current shell
```

If this server hosts more than one domain or DB home, `environments/` will
contain multiple conf files — `set_env.sh` (sourced) is then the daily
driver for switching between them; see
[set_environment.md](set_environment.md#bash_profile-integration) for
automatic activation on login.

---

## Files NOT in Git

| Pattern | Reason |
|---|---|
| `environment.conf` | Symlink — points to a server-specific file |
| `environments/*.conf` | Server-specific paths (templates and `README.md` ARE committed) |
| `*.des3`, `*.des3.bak*` | Encrypted credentials — machine-specific key, no reason to share |
| `weblogic_sec.conf` | Plaintext intermediate — exists only briefly at runtime, always deleted |
| `00-Setup/getPWDs.sh` | Prints plaintext passwords — debug tool only |

---

## Relationship to Other Modules

| Module | Role |
|---|---|
| `09-Install/01-setup-interview.sh` | Alternative front-end to the same `environment.conf` — full guided interview for a brand-new install |
| `02-Checks/*` | Read `environment.conf` for all detected paths |
| `01-Run/wlst_connect.sh` | Uses `load_weblogic_password` from the library to auto-login |
| `07-Maintenance/backup_config.sh` | Backs up `environment.conf` under the `ihw` category |
| `08-SSL/*` | Uses the same credential-encryption pattern for `ssl.conf` |
