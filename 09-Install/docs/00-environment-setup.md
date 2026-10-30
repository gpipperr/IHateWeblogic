# Environment Setup – Concept and Parameters

**Goal:** Create `environment.conf` before or after Oracle FMW is installed.

Background – which home, configuration and process a parameter belongs to:
[weblogic_middleware_architecture.md §1 / §7](../../80-FMW-Architecture/weblogic_middleware_architecture.md#7-where-is-what--homes-configuration-logs);
`environment.conf` as the one source of every value: [00-Setup/README.md](../../00-Setup/README.md).

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
(same `openssl des3` concept as `00-Setup/weblogic_sec.sh`) and stored only as
`*.des3` files – list of all files: [00-Setup/README.md](../../00-Setup/README.md#credential-scripts-weblogic_secsh--database_rcu_secsh--mos_secsh).

---

## New Installation Flow

```
1. 09-Install/01-setup-interview.sh --apply
   → Collects all install parameters interactively
   → Writes environment.conf (install parameters block only)
   → Encrypts WLS Admin password  → weblogic_sec.conf.des3
   → Encrypts MOS password        → mos_sec.conf.des3
   → Encrypts DB SYS password     → db_sys_sec.conf.des3
   → Encrypts embedded LDAP / Reports admin / Forms signing / APEX passwords
     (only when the matching option is chosen)

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
| `PATCH_STORAGE` | `/srv/patch_storage` | Storage for installer ZIPs and patches | ≥ 20 GB free (less with `PATCH_ARCHIVE`: only the current step) |
| `PATCH_ARCHIVE` | *(empty)* | Optional NFS/ZFS archive = master copy, same layout; `07-Maintenance/patch_storage.sh` pulls a step's files to `PATCH_STORAGE` and frees them after the step | readable (writable for `clean` archiving) |
| `ORACLE_INVENTORY` | one level above `ORACLE_BASE` (`/opt/oraInventory` if that is not possible) | Central inventory, written to `/etc/oraInst.loc` by `03-root_user_oracle.sh`. On a host with an existing inventory (local RCU DB, reinstall) enter **that** one | directory |
| `TNS_ADMIN` | `$ORACLE_BASE/admin/tns_names` | The one Oracle Net directory for every process – [02-Checks/tns_admin_check.sh](../../02-Checks/README.md#tns_admin_checksh) | directory |
| `INSTALL_COMPONENTS` | `FORMS_AND_REPORTS` | `FORMS_AND_REPORTS` / `FORMS_ONLY` / `REPORTS_ONLY` | menu |

### Block 2 – FMW Runtime Paths
*Runtime parameters – auto-detected by `init_env.sh` after installation*

| Variable | Value | Description |
|---|---|---|
| `WL_HOME` | `${ORACLE_HOME}/wlserver` | WebLogic Server home (derived) |
| `WLST` | `${ORACLE_HOME}/oracle_common/common/bin/wlst.sh` | WLST script (derived) |
| `RWRUN` | `${ORACLE_HOME}/bin/rwrun` | Reports rwrun binary (derived) |
| `RWCLIENT` | `${ORACLE_HOME}/bin/rwclient` | Reports rwclient binary (derived) |

> **No `FMW_HOME` / `JAVA_HOME` in `environment.conf`** (checked 2026-10-29):
> the scripts use `ORACLE_HOME` and `JDK_HOME`; `JAVA_HOME` comes from the
> process environment (`.bash_profile` sets it to `JDK_HOME`). The second JDK,
> `$ORACLE_HOME/oracle_common/jdk`, is not a parameter – it belongs to the home
> (Reports engines, OPatch fallback), see [JDK_HOME vs. the bundled JDK](#jdk_home-vs-the-bundled-jdk).

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
| `WLS_ADMIN_USER` | `webadmin` | WebLogic admin user (password → `weblogic_sec.conf.des3`) |
| `WLS_SERVER_FQDN` | interview (default `hostname -f`) | **Public** server name – the name the users type and the certificate (SAN) carries: Nginx `server_name`, 08-SSL, default of `FORMS_CLIENT_BASE_URL` / `ORDS_PUBLIC_URL`. May differ from the host name: cloud host `host.subnet.vcn.oraclevcn.com`, users via `forms.company.com` → `WLS_SERVER_FQDN=forms.company.com` (Nginx answers to both names). Not used inside WebLogic (`WLS_LISTEN_ADDRESS`) |
| `WLS_MANAGED_SERVER` | `WLS_REPORTS` | Reports managed server name (auto-detected) |
| `WLS_FORMS_SERVER` | `WLS_FORMS` | Forms managed server name (auto-detected) |
| `SETDOMAINENV` | `$DOMAIN_HOME/bin/setDomainEnv.sh` | Domain environment script (derived) |
| `EXPECTED_SESSIONS` | `lt100` | Expected concurrent Forms/Reports sessions tier — sizes the two variables below. See `docs/01-setup-interview.md` |
| `ULIMIT_NOFILE` | `65536` | oracle OS user `nofile` ulimit, used by `03-root_user_oracle.sh`. `81920` confirmed for 100-500 sessions (real production reference); `131072`/`262144` for the higher tiers are estimates of decreasing confidence — `262144` (`>1000`) is the least confident, a cautious doubling with no reference data behind it |
| `ULIMIT_NPROC` | `16384` | oracle OS user `nproc` ulimit — same tiering/provenance as `ULIMIT_NOFILE` |
| `ULIMIT_MEMLOCK` | `3145728` | oracle OS user `memlock` ulimit (KB) — fixed, not session-tiered; not asked by the interview, override manually if needed |
| `ULIMIT_CORE` | `2097152` | oracle OS user `core` ulimit (blocks) — fixed, not session-tiered; not asked by the interview, override manually if needed |

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
| `REPORTS_SERVER_NAME` | `repserver01` – Reports Server name (first of `REPORTS_SERVER_NAMES`, interview list) |
| `REPORTS_SERVER_INSTANCES` | standalone Reports servers created by `13-` (from `REPORTS_SERVER_NAMES`) |
| `REPORTS_TOOLS_INSTANCE` | `reptools1` – ReportsTools instance (`rwrun`, `rwconverter`, Builder) |
| `REPORTS_BROADCAST_PORT` | multicast discovery port (`rwnetwork.conf`, `14027` on the test host) – [discovery](../../80-FMW-Architecture/reports_server_discovery_multicast.md) |
| `REPORTS_PATH` / `REPORTS_TMP` | `REPORTS_PATH` and temp directory of the engines (default from `REPORTS_CUSTOMER_DIR`) |
| `REPORTS_CUSTOMER_DIR` | `$ORACLE_BASE/reports/source` – `.rdf` / `.rep` sources (interview) |
| `REPORTS_IMAGE_DIR` | `$ORACLE_BASE/reports/images` – images, `<folderAccess>` – [image handling](../../80-FMW-Architecture/report_server_image_handling.md) |
| `REPORTS_SECURITY` | `ldap` (secured server, WebLogic embedded LDAP) or `identifier` – [reports_user_local_ldap.md](../../80-FMW-Architecture/reports_user_local_ldap.md); passwords → `embedded_ldap_sec` / `reports_admin_sec.conf.des3` |
| `REPORTS_ADMIN_USER` | `rep_admin` – Reports server admin (`<identifier>`) |
| `REPORTS_COOKIE_KEY` | generated once by `13-` (persisted) |
| `REPORTS_ENGINE_MIN` / `_INIT` / `_MAX` | `2` / `2` / `5` – engines per server |
| `REPORTS_ENGINE_LIFE` / `_MAX_IDLE` | `50` jobs / empty (Oracle default) – engine recycling |
| `REPORTS_ENGINE_RESPONSE_TIMEOUT` | `30` minutes – proposal from the measured run times (`05-ReportsPerformance`) |
| `REPORTS_ENGINE_JVM_OPTIONS` | extra engine JVM options (empty) |
| `REPORTS_MAX_CONNECT` / `REPORTS_MAX_QUEUE` | `300` / `4000` |

All engine values are written by `13-` / `05-ReportsPerformance --apply` into
`rwserver.conf` – background: [report_engine_architecture.md](../../80-FMW-Architecture/report_engine_architecture.md).

### Block 5 – Configuration Files
*Runtime parameters – auto-detected by init_env.sh*

| Variable | Description |
|---|---|
| `RWSERVER_CONF` | Path to `rwserver.conf` (under `servers/WLS_REPORTS/applications/`) |
| `CGICMD_DAT` | Path to `cgicmd.dat` (same directory as `rwserver.conf`) |

### Block 4b – Forms
*Interview + defaults; written into the domain by `14-oracle_setup_forms.sh` –
background: [forms_runtime_architecture.md](../../80-FMW-Architecture/forms_runtime_architecture.md)*

| Variable | Default | Description |
|---|---|---|
| `FORMS_INSTANCE_NAME` | detected | Forms instance (`forms1`) |
| `FORMS_CUSTOMER_DIR` | `$ORACLE_BASE/forms/moduls` | `.fmx` / `.fmb` directory (`FORMS_PATH`) |
| `FORMS_TMP` | `$ORACLE_BASE/forms/tmp` | `TMPDIR` in `default.env`, WebUtil work area |
| `FORMS_MAX_RUNTIME_PROCESSES` | proposal from RAM (`frm_mrp_proposal`) | `maxRuntimeProcesses` – upper limit of `frmweb` sessions |
| `FORMS_PRESTART_SECTION` / `_INIT` / `_MIN` / `_INCREMENT` | empty / `5` / `4` / `1` | runtime pooling (prestart) – empty section = off |
| `FORMS_WEBUTIL_JACOB` | `false` | WebUtil OLE / Office automation – [forms_jakob_webutil.md](../../80-FMW-Architecture/forms_jakob_webutil.md) |
| `FORMS_SIGN_KEYSTORE` / `FORMS_SIGN_ALIAS` | `<CA dir>/codesign/codesign.p12` / `forms_codesign` | code signing of `jacob.jar` (password → `forms_sign_sec.conf.des3`) |
| `FORMS_SIGN_TSA_URL` | `http://timestamp.digicert.com` | timestamp server for `jarsigner` |
| `FORMS_SIGN_LOCALCA` | `false` | `true` = certificate from the local CA (`08-SSL/ssl_local_ca.sh`) |

### Block 4c – Forms client distribution (`40-`)
*Only with `FORMS_CLIENT_DIST=true` – [docs/40](40-forms_client_distribution.md),
[java_jlink_forms_env.md](../../80-FMW-Architecture/java_jlink_forms_env.md)*

| Variable | Default | Description |
|---|---|---|
| `FORMS_CLIENT_DIST` | `false` | Forms client (Java + FSAL) via URL |
| `FORMS_CLIENT_RUNTIME` | `jlink` | `jlink` (own runtime) or `jdk` |
| `FORMS_CLIENT_DIR` / `FORMS_CLIENT_URL_PATH` | `/srv/formsWeb` / `/formsWeb` | bundle directory for Nginx / URL |
| `FORMS_CLIENT_BASE_URL` | `https://<WLS_SERVER_FQDN>` | server URL used by the clients |
| `FORMS_CLIENT_CONFIG` / `FORMS_CLIENT_FORM` | `standaloneapp` / empty | `formsweb.cfg` section / start form |
| `FORMS_CLIENT_APP_NAME` / `FORMS_CLIENT_ICON` | `Oracle Forms` / – | desktop shortcut |
| `FORMS_CLIENT_TRUST_CA` | local CA if present | CA certificate put into the client `cacerts` |

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
| `RCU_DB_TYPE` | `EBR` | `EBR` (editions enabled, Oracle's default for 14.1.2) or `ORACLE` – [rcu_middleware_architecture.md](../../80-FMW-Architecture/rcu_middleware_architecture.md) |
| `RCU_TABLESPACE` / `RCU_TEMP_TABLESPACE` | empty (RCU creates its own) / `TEMP` | tablespaces for the RCU schemas |
| `LOCAL_REP_DB` | detected | `true` if an Oracle DB runs on the same host as WebLogic. Asked in `01-setup-interview.sh` Block 4; the detected value (`ora_pmon_*` running, or `DB_HOST` is a local address) is offered as default |

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

Patch numbers (`INSTALL_PATCHES`, `WLS_SPB_PATCH_NR`, `JDK_PATCH_NR` …) are
**not** in `environment.conf` – they live in `09-Install/oracle_software_version.conf`
(committed, one set per patch cycle).

### Block 7b – APEX / ORDS
*Only with `INSTALL_APEX=true` – [12-APEX-Ords/README.md](../../12-APEX-Ords/README.md),
[apex_architecture.md](../../80-FMW-Architecture/apex_architecture.md), [ords_architecture.md](../../80-FMW-Architecture/ords_architecture.md)*

| Variable | Default | Description |
|---|---|---|
| `INSTALL_APEX` | `false` | APEX + ORDS beside Forms |
| `APEX_ORDS_BASE` / `APEX_SW_BASE` | `$ORACLE_BASE/product/ords` / `$ORACLE_BASE/product/apex` | software + homes |
| `APEX_WEB_DIR` | `/srv/apex` | APEX images for Nginx |
| `ORDS_1_DB_ALIAS` / `_PORT` / `_CONTEXT` / `_IMAGE_PREFIX` | TNS alias / `8081` / `/ords` / `/i/` | first ORDS instance |
| `ORDS_JAVA_HEAP` | `2G` | `-Xms` = `-Xmx` of the systemd unit |

### Block 8 – Security and Operations
*Mix: some from interview, some defaults*

| Variable | Default | Description |
|---|---|---|
| `ORACLE_OS_USER` | `oracle` | OS user that runs WebLogic |
| `SEC_CONF` | `weblogic_sec.conf.des3` | Encrypted WLS Admin credentials |
| `WLS_LOG_DIR` | `$DOMAIN_HOME/servers/$WLS_MANAGED_SERVER/logs` | WLS log directory |
| `DIAG_LOG_DIR` | `$ROOT_DIR/log/$(date +%Y%m%d)` | IHateWeblogic script logs |
| `DISPLAY_VAR` | `:99` | X11 display for rwrun and Oracle Installer |
| `SSH_ALLOW_USERS` / `SSH_PASSWORD_USERS` | empty | sshd hardening of `01-root_os_baseline.sh` (`AllowUsers`, password login only for these) |
| `CONFIG_BACKUP_KEEP` / `BAK_FILES_KEEP` | `10` / `3` | retention of `backup_config.sh` runs / `*.bak_<ts>` copies (`bak_cleanup.sh`) |
| `IHW_ENV_TYPE` | interview: `prod`; `init_env.sh`: none (asked) | `test` \| `prod` – on `prod` the Claude tooling refuses to run and the guard hook denies changing commands ([setup_claude.md](../../10-Monitoring/setup_claude.md)) |

### Block 9 – Test Modules (Smoke Test)
*Manual parameter — not set by the interview; add by hand if used*

| Variable | Default | Description |
|---|---|---|
| `TEST_DB_HOST` / `TEST_DB_PORT` / `TEST_DB_SERVICE` | `DB_HOST` / `DB_PORT` / `DB_SERVICE` | Optional: database for the Forms/Reports smoke test (`15-deploy-test-report-forms_template.sh`) if it differs from the repository DB. User/password are **not** stored here but encrypted in `test_db_sec.conf.des3` (asked by `15-` on first `--apply`). See `docs/20-forms_reports_testmodules.md`. |

---

## JDK_HOME vs. the bundled JDK

```
JDK_HOME  = /u01/app/oracle/java/jdk-21        (symlink → jdk-21.0.x)
            Set by:  02b-root_os_java.sh (root), updated by --upgrade-jdk /
                     07-Maintenance/80-patch_java_os.sh
            Used by: WebLogic, Node Manager, OPatch (.globalEnv.properties),
                     ORDS, all scripts; oracle .bash_profile: JAVA_HOME=$JDK_HOME
            Oracle Support expects the Oracle JDK vendor here

$ORACLE_HOME/oracle_common/jdk                  (FMW-bundled JDK, part of the home)
            Not a parameter – used by the Reports engines (reports.sh puts it
            first in PATH) and the Forms / Reports tools
            Updated only by an Oracle patch (component oracle.jdk) – open item
```

Background: [the four homes, two JDKs](../../80-FMW-Architecture/weblogic_middleware_architecture.md#1-terms--the-four-homes).

> **`init_env.sh` without an existing conf** (taking over a system) proposes
> `JDK_HOME` in this order (since 2026-10-29; before, the bundled JDK came
> first and became `JDK_HOME`): `JAVA_HOME` of
> `$ORACLE_HOME/oui/.globalEnv.properties` → java of a running WebLogic server /
> Node Manager → standard paths / `alternatives` → `$JAVA_HOME` of the shell –
> each only outside `ORACLE_HOME`, a version-neutral symlink (`jdk-21`) is
> preferred. Only if none exists the bundled JDK is proposed, with a WARN.
> With an existing conf the value is never overwritten.

---

## Detection Chain in `init_env.sh`

```
FMW_HOME:
  1. Standard paths: /u01/oracle/fmw, /u01/app/oracle/fmw, ...
     (proof: wlserver/server/lib/weblogic.jar present)
  2. Running process: ps -eo args | -Dwls.home=<path>/wlserver
  3. Environment variables: MW_HOME, ORACLE_HOME
  → Fallback: /u01/oracle/fmw (for new installs)
  (standard paths: /u01/oracle/fmw, /u01/app/oracle/fmw, /opt/oracle/fmw,
   /oracle/fmw, /home/oracle/fmw)

DOMAIN_HOME:
  1. Running AdminServer: -Dweblogic.RootDirectory=<path>
  2. Standard base directories (/u01/user_projects/domains,
     /u01/app/oracle/user_projects/domains, /home/oracle/…, /opt/oracle/…)
     → first subdirectory with config/config.xml
  → Fallback: /u01/user_projects/domains/fr_domain
  (the interview default for a new installation is $ORACLE_BASE/domains/fr_domain)

JDK_HOME (proposal, see the note above; each candidate outside ORACLE_HOME,
          version-neutral symlink preferred):
  1. JAVA_HOME= of $ORACLE_HOME/oui/.globalEnv.properties
  2. java binary of a running weblogic.Server / NodeManager (/proc/<pid>/exe)
  3. Standard paths (/u01/app/oracle/java/jdk-21 …) / alternatives
  4. JAVA_HOME of the shell
  → Fallback: $ORACLE_HOME/oracle_common/jdk + WARN

DB connection:
  1. jps-config.xml: first DB_ORACLE propertySet → parse JDBC URL
     - EZConnect  jdbc:oracle:thin:@//host:port/service[:server]  (as written
       by 08-oracle_setup_domain.sh / the Configuration Wizard)
     - TNS form   jdbc:oracle:thin:@(DESCRIPTION=…(HOST=…)(PORT=…)…(SERVICE_NAME=…))
       (case-insensitive)
     (before 2026-10-15 only a lower-case TNS form was parsed – EZConnect
      gave an empty DB_HOST/DB_SERVICE)
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
| further `*.des3` | LDAP, Reports admin / users, Forms signing, CA, APEX, test DB – [00-Setup/README.md](../../00-Setup/README.md) | **No** |
| `09-Install/oracle_software_version.conf` | Software versions, SHA-256, cycle values | **Yes** |
| `09-Install/download/patches_fmw.csv` / `patches_db.csv` | Patch numbers per cycle (library + `mos_patch_download.sh`) | **Yes** |
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
