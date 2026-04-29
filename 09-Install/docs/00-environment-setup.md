# Environment Setup – Concept and Parameters

**Goal:** Create `environment.conf` before or after Oracle FMW is installed.

---

## Overview: When is `environment.conf` created?

| Situation | Tool | Method |
|---|---|---|
| **New installation** (no FMW present) | `09-Install/01-setup-interview.sh` | Interactive interview, sensible defaults suggested |
| **Existing system, no conf** | `00-Setup/init_env.sh --interview --apply` | Auto-detect + user confirms or overrides each value |
| **Existing system, conf present** | `00-Setup/init_env.sh --apply` | Auto-detect, append only missing values |
| **Multi-domain environment** | `00-Setup/set_env.sh` | Switch symlink to the active conf |

---

## Core Principles

**Idempotent:** Every `--apply` run writes only values that are not yet set.
Existing values in `environment.conf` are never overwritten — unless the user
explicitly provides a different value during `--interview`.

**Two parameter classes:**

```
[Install parameters]    → set by the interview before installation begins
[Runtime parameters]    → auto-detected by init_env.sh after installation
```

**Passwords never in plaintext:** All passwords are encrypted immediately
(via `00-Setup/weblogic_sec.sh`) and stored only as `*.des3` files.

---

## New Installation Flow

```
1. 09-Install/01-setup-interview.sh --apply
   → Collects all install parameters interactively
   → Writes environment.conf (install parameters block only)
   → Encrypts WLS Admin password  → weblogic_sec.conf.des3
   → Encrypts MOS password        → mos_sec.conf.des3
   → Encrypts DB SYS password     → db_sys_sec.conf.des3

2. [Phase 0–1 installation runs through]

3. 00-Setup/init_env.sh --apply
   → Detects runtime parameters (FMW paths, instances, config files)
   → Extends environment.conf with runtime section
   → Existing install parameters are not overwritten
```

## Existing System (no conf)

```
1. 00-Setup/init_env.sh --interview --apply
   → Scans running WLS processes, FMW paths, jps-config.xml
   → Shows each detected value, user confirms or overrides
   → Writes complete environment.conf
```

---

## All Parameters

### Block 1 – Installation Paths
*Install parameters – set by `01-setup-interview.sh`*

| Variable | Default | Description | Validation |
|---|---|---|---|
| `ORACLE_BASE` | `/u01/app/oracle` | Base directory for all Oracle installations | Directory writable or creatable |
| `ORACLE_HOME` | `$ORACLE_BASE/fmw` | FMW installation target (= `FMW_HOME` after install) | Must be empty before installation |
| `JDK_HOME` | `$ORACLE_BASE/java/jdk-21` | Oracle JDK 21 symlink (created by `02b-root_os_java.sh`) | `$JDK_HOME/bin/java -version` must return JDK 21 |
| `PATCH_STORAGE` | `/srv/patch_storage` | Storage for installer ZIPs and patches | ≥ 20 GB free |

### Block 2 – FMW Runtime Paths
*Runtime parameters – auto-detected by `init_env.sh` after installation*

| Variable | Value | Description |
|---|---|---|
| `FMW_HOME` | `$ORACLE_HOME` | FMW installation directory (after install = `ORACLE_HOME`) |
| `WL_HOME` | `$FMW_HOME/wlserver` | WebLogic Server home (derived) |
| `JAVA_HOME` | `$FMW_HOME/oracle_common/jdk` | FMW-bundled JDK (≠ `JDK_HOME`!) |
| `WLST` | `$FMW_HOME/oracle_common/common/bin/wlst.sh` | WLST script (derived) |
| `RWRUN` | `$FMW_HOME/bin/rwrun` | Reports rwrun binary (derived) |
| `RWCLIENT` | `$FMW_HOME/bin/rwclient` | Reports rwclient binary (derived) |

> **Important:** `JAVA_HOME` in `environment.conf` points to the **FMW-bundled JDK**
> (`oracle_common/jdk`), not to `JDK_HOME`. Oracle Support always asks for the JDK
> vendor when troubleshooting — therefore `oracle`'s `.bash_profile` must explicitly
> set `JDK_HOME`, independent of `alternatives`.

### Block 3 – WebLogic Domain
*Mix: base values from interview, managed server name auto-detected by init_env.sh*

| Variable | Default | Description |
|---|---|---|
| `DOMAIN_HOME` | `$ORACLE_BASE/domains/fr_domain` | Domain home directory |
| `DOMAIN_NAME` | `fr_domain` | Domain name (= `basename $DOMAIN_HOME`) |
| `WL_ADMIN_URL` | `t3://localhost:7001` | T3 URL of the AdminServer |
| `WLS_ADMIN_PORT` | `7001` | AdminServer HTTP port |
| `WLS_FORMS_PORT` | `9001` | WLS_FORMS managed server port |
| `WLS_REPORTS_PORT` | `9002` | WLS_REPORTS managed server port |
| `WLS_NODEMANAGER_PORT` | `5556` | NodeManager port |
| `WLS_LISTEN_ADDRESS` | `localhost` | Network interface WebLogic binds to. `localhost` = NGINX proxy (recommended); `0.0.0.0` = all interfaces (no proxy); custom FQDN/IP |
| `WLS_MANAGED_SERVER` | `WLS_REPORTS` | Reports managed server name (auto-detected) |
| `SETDOMAINENV` | `$DOMAIN_HOME/bin/setDomainEnv.sh` | Domain environment script (derived) |

### Block 4 – Reports Components
*Runtime parameters – auto-detected by init_env.sh after installation*

| Variable | Description |
|---|---|
| `REPORTS_COMPONENT_HOME` | Primary ReportsTools instance (`reptools1`) |
| `REPORTS_ADMIN` | `$REPORTS_COMPONENT_HOME/guicommon/tk/admin` |
| `UIFONT_ALI` | Path to `uifont.ali` (= `TK_FONTALIAS` = `ORACLE_FONTALIAS`) |
| `TK_FONTALIAS` | Overrides Oracle default uifont.ali search path (= `UIFONT_ALI`) |
| `ORACLE_FONTALIAS` | Same as `TK_FONTALIAS` (= `UIFONT_ALI`) |
| `REPORTS_FONT_DIR` | `$DOMAIN_HOME/reports/fonts` – TTF font storage |
| `REPORTS_INSTANCES` | Bash array of all `reptools*` instances |
| `REPORTS_SERVER_NAME` | `repserver01` – Reports Server name |

### Block 5 – Configuration Files
*Runtime parameters – auto-detected by init_env.sh*

| Variable | Description |
|---|---|
| `RWSERVER_CONF` | Path to `rwserver.conf` (under `servers/WLS_REPORTS/applications/`) |
| `CGICMD_DAT` | Path to `cgicmd.dat` (same directory as `rwserver.conf`) |

### Block 6 – Database (RCU)
*Install parameters – set by the interview; also auto-detected from `jps-config.xml`*

| Variable | Default | Description |
|---|---|---|
| `DB_HOST` | – | Database server hostname |
| `DB_PORT` | `1521` | Oracle listener port |
| `DB_SERVICE` | – | Service name (not SID) |
| `DB_SERVER` | `dedicated` | Connection mode: `dedicated` or `shared` |
| `DB_SCHEMA_PREFIX` | `DEV` | Prefix for RCU schemas (e.g. `DEV_MDS`, `DEV_STB`) |
| `SQLPLUS_BIN` | empty | Optional: path to sqlplus for login test |
| `SEC_CONF_DB` | `db_connect.conf.des3` | Encrypted DB credentials |
| `LOCAL_REP_DB` | `false` | `true` if an Oracle DB runs on the same host as WebLogic |

> **`LOCAL_REP_DB`:** Controls the behaviour of `01-root_os_baseline.sh` when
> `oracle-database-preinstall-*` sysctl files conflict with WebLogic OUI requirements.
> `false` → conflicting files are flagged as FAIL and their keys commented out.
> `true`  → WARN only, no modification (the local DB needs the large shm values).

### Block 7 – My Oracle Support
*Install parameters – interview only; MOS_PWD is never written to environment.conf*

| Variable | Description |
|---|---|
| `MOS_USER` | MOS e-mail address |
| `MOS_PWD` | Encrypted → `mos_sec.conf.des3` (never in env.conf) |
| `INSTALL_PATCHES` | Comma-separated patch numbers in apply order |
| `INSTALL_COMPONENTS` | `FORMS_AND_REPORTS` / `FORMS_ONLY` / `REPORTS_ONLY` |

### Block 8 – Security and Operations
*Mix: some from interview, some defaults*

| Variable | Default | Description |
|---|---|---|
| `ORACLE_OS_USER` | `oracle` | OS user that runs WebLogic |
| `SEC_CONF` | `weblogic_sec.conf.des3` | Encrypted WLS Admin credentials |
| `WLS_LOG_DIR` | `$DOMAIN_HOME/servers/$WLS_MANAGED_SERVER/logs` | WLS log directory |
| `DIAG_LOG_DIR` | `$ROOT_DIR/log/$(date +%Y%m%d)` | IHateWeblogic script logs |
| `DISPLAY_VAR` | `:99` | X11 display for rwrun and Oracle Installer |

---

## JDK_HOME vs. JAVA_HOME

```
JDK_HOME  = /u01/app/oracle/java/jdk-21        (symlink → jdk-21.0.x)
            Set by:  02b-root_os_java.sh
            Used by: 04-oracle_pre_checks.sh, oracle .bash_profile
            Oracle Support expects the Oracle JDK vendor here

JAVA_HOME = /u01/oracle/fmw/oracle_common/jdk   (FMW-bundled JDK)
            Set by:  init_env.sh (auto-detected after FMW installation)
            Used by: all diagnostic scripts that invoke java
            Only available after FMW installation
```

**Phase 0/1 (before FMW):** Only `JDK_HOME` is known → `04-oracle_pre_checks.sh` uses `JDK_HOME`
**Phase 2+ (after FMW):** `JAVA_HOME` points to FMW JDK → all other scripts use `JAVA_HOME`

---

## Detection Chain in `init_env.sh`

```
FMW_HOME:
  1. Standard paths: /u01/oracle/fmw, /u01/app/oracle/fmw, ...
     (proof: wlserver/server/lib/weblogic.jar present)
  2. Running process: ps -eo args | -Dwls.home=<path>/wlserver
  3. Environment variables: MW_HOME, ORACLE_HOME
  → Fallback: /u01/oracle/fmw (for new installs)

DOMAIN_HOME:
  1. Running AdminServer: -Dweblogic.RootDirectory=<path>
  2. Standard base directories → first subdirectory with config/config.xml
  → Fallback: /u01/user_projects/domains/fr_domain

JAVA_HOME:
  1. FMW-bundled JDK: $FMW_HOME/oracle_common/jdk
  2. Running WLS process: -Djava.home=<path>
  3. System JAVA_HOME
  → Fallback: $FMW_HOME/oracle_common/jdk

DB connection:
  1. jps-config.xml: first DB_ORACLE propertySet → parse JDBC URL
  → Fallback: empty (manual entry required)
```

---

## File Overview

| File | Content | In Git? |
|---|---|---|
| `environment.conf` | All runtime and install parameters | **No** (`.gitignore`) |
| `weblogic_sec.conf.des3` | Encrypted WLS Admin password | **No** |
| `mos_sec.conf.des3` | Encrypted MOS password | **No** |
| `db_sys_sec.conf.des3` | Encrypted DB SYS password (RCU only) | **No** |
| `db_connect.conf.des3` | Encrypted DB runtime credentials | **No** |
| `setup.conf` | Password-free reusable template | **No** |
| `environment.conf.bak.*` | Backups before any overwrite | **No** |

---

## Related Scripts

| Script | Purpose |
|---|---|
| `09-Install/01-setup-interview.sh` | New install: interview → environment.conf + encrypted passwords |
| `00-Setup/init_env.sh` | Existing system: auto-detect → extend environment.conf |
| `00-Setup/weblogic_sec.sh` | Password concept: encrypt/decrypt via machine UUID |
| `00-Setup/set_env.sh` | Multi-domain: switch symlink to active conf |
| `09-Install/04-oracle_pre_checks.sh` | Phase 1: reads install parameters from environment.conf |
