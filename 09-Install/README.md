# 09-Install – Oracle Forms & Reports 14.1.2 Installation

Complete installation roadmap for Oracle Forms & Reports 14.1.2 (FMW 14.1.2.0.0)
on Oracle Linux 9 – from OS configuration to a validated production environment.

---

## Acknowledgements

Special thanks to two colleagues without whom this documentation would not exist in this form:

**Jürgen Menge** – for his invaluable support on countless WebLogic questions,
for sharing his deep expertise, and for his ideas and information that have
substantially shaped the concepts and structure of this installation guide.

**Mark Eichhorst** – for his support and patience with Oracle Forms and Reports
questions, and for the inspiration that came from the challenges and tasks he brought
to the table.

---

>
> **Concept:** Each installation step has a detail document in `docs/` describing what
> would need to be done manually and what the script automates. Scripts are generated
> from these detail documents.

---

## 1. Architecture & Security Concept

### SSL Proxy Architecture

```
Internet / Intranet
        │
        │ HTTPS (443)
        ▼
   ┌─────────────┐
   │    Nginx    │  ← SSL termination, no Oracle HTTP Server (OHS)
   │ (Port 443)  │
   └──────┬──────┘
          │ HTTP (localhost / 127.0.0.1 only)
          ├──► AdminServer    :7001
          ├──► WLS_FORMS      :9001
          └──► WLS_REPORTS    :9002

WebLogic listens exclusively on 127.0.0.1 – no direct external access.
SSL terminates entirely at Nginx; no SSL required inside WLS.
```

### WebLogic Users

| User | Role | Description |
|---|---|---|
| `webadmin` | WLS Administrator | Full access to WLS Console and WLST |
| `nodemanager` | Node Manager Auth | Node Manager authentication |
| `MonUser` | Monitor | Read-only for monitoring/alerting |
| `RepRunner` | Reports Runner | Submits Reports jobs via rwservlet |

All passwords stored encrypted (`openssl des3 -pbkdf2` + disk UUID as key —
same mechanism as `00-Setup/weblogic_sec.sh`).

### OS User

The entire library runs as OS user `oracle`.
For root operations (OS parameters, packages, Nginx) `oracle` receives selective `sudo` rights.
Scripts in the `root_*` group check sudo availability and display commands for manual
execution if sudo is not available.

---

## 2. Installation Flow

```
Phase 0 – OS Preparation (as root; git clone first, then hand over to oracle)
  [root] git clone <repo> && cd IHateWeblogic
  [root] cp environment.conf.template environment.conf  # fill in parameters
  [root] ./09-Install/00-root_os_network.sh --apply    # hostname, hosts, chrony, SSH
  [root] ./09-Install/01-root_os_baseline.sh --apply   # SELinux, kernel, THP → REBOOT
  [root] ./09-Install/02-root_os_packages.sh --apply   # packages, JDK
  [root] ./09-Install/03-root_user_oracle.sh --apply   # oracle user + chown repo → oracle
  [root] ./09-Install/04-root_nginx.sh --apply         # Nginx install + proxy config
  [root] ./09-Install/05-root_nginx_ssl.sh --apply     # SSL cert, TLS config

Phase 1 – Pre-Install Checks (as oracle)
  04-oracle_pre_checks.sh       Verify all prerequisites before download
  04-oracle_pre_download.sh     Download software and patches from MOS (getMOSPatch.jar)

Phase 2 – WebLogic Installation (as oracle)
  05-oracle_install_weblogic.sh FMW Infrastructure 14.1.2 silent install
  05-oracle_patch_weblogic.sh   Update OPatch + apply WLS patches

Phase 3 – Forms & Reports Installation (as oracle)
  06-oracle_install_forms_reports.sh  Forms/Reports 14.1.2 silent install
  06-oracle_patch_forms_reports.sh    Apply Forms/Reports patches

Phase 4 – Repository & Domain (as oracle)
  07-oracle_setup_repository.sh  RCU: create FMW metadata schemas
  08-oracle_setup_domain.sh      Create WebLogic domain (WLST silent mode)

Phase 5 – Configuration & Validation (as oracle)
  09-oracle_configure.sh         Final configuration using existing 00-07 scripts
  10-oracle_validate.sh          Full validation report
```

---

## 3. Script Reference

| Phase | Script | Description | Detail |
|---|---|---|---|
| 0 | `00-root_os_network.sh` | Hostname, /etc/hosts, IPv6, chrony, SSH | [→ docs](docs/concept-os-preparation.md) |
| 0 | `01-root_os_baseline.sh` | SELinux, kernel params, THP, core dump dir, firewall → **REBOOT** | [→ docs](docs/00-root_set_os_parameter.md) |
| 0 | `02-root_os_packages.sh` | dnf packages (motif, gcc, numactl …) | [→ docs](docs/01-root_install_packages.md) |
| 0 | _(Java setup)_ | OpenJDK vs Oracle JDK, alternatives, jps, SecureRandom | [→ docs](docs/01-root_setup_java.md) |
| 0 | `03-root_user_oracle.sh` | oracle user, limits, locale, sudo, dirs, repo handover | [→ docs](docs/03-root_user_oracle.md) |
| 0 | `04-root_nginx.sh` | Nginx install + proxy config from template | [→ docs](docs/02-root_nginx.md) |
| 0 | `05-root_nginx_ssl.sh` | SSL certificate deploy, TLS config, start Nginx | [→ docs](docs/03-root_nginx_ssl.md) |
| 1 | `04-oracle_pre_checks.sh` | Pre-install prerequisite validation | [→ docs](docs/04-oracle_pre_checks.md) |
| 1 | `04-oracle_pre_download.sh` | MOS download via getMOSPatch.jar | [→ docs](docs/04-oracle_pre_download.md) |
| 2 | `05-oracle_install_weblogic.sh` | FMW Infrastructure silent install | [→ docs](docs/05-oracle_install_weblogic.md) |
| 2 | `05-oracle_patch_weblogic.sh` | OPatch update + WLS patches | [→ docs](docs/05-oracle_patch_weblogic.md) |
| 3 | `06-oracle_install_forms_reports.sh` | Forms/Reports silent install | [→ docs](docs/06-oracle_install_forms_reports.md) |
| 3 | `06-oracle_patch_forms_reports.sh` | Forms/Reports patches | [→ docs](docs/06-oracle_patch_forms_reports.md) |
| 4 | `07-oracle_setup_repository.sh` | RCU: create FMW metadata schemas | [→ docs](docs/07-oracle_setup_repository.md) |
| 4 | `08-oracle_setup_domain.sh` | Domain creation (WLST silent) | [→ docs](docs/08-oracle_setup_domain.md) |
| 5 | `09-oracle_configure.sh` | Final configuration using 00-07 scripts | [→ docs](docs/09-oracle_configure.md) |
| 5 | `10-oracle_validate.sh` | Full post-install validation report | [→ docs](docs/10-oracle_validate.md) |
| pre | `01-setup-interview.sh` | Configuration interview → environment.conf | [→ docs](docs/01-setup-interview.md) |

---

## 4. Configuration Interview: `01-setup-interview.sh`

Runs before all other installation steps. Reads existing `environment.conf`, prompts
only for missing parameters, encrypts passwords immediately, writes a reusable
`setup.conf` template. → [Detail: docs/01-setup-interview.md](docs/01-setup-interview.md)

---

## 5. environment.conf – Installation Parameters

New parameters added by the 09-Install module (appended to existing `environment.conf`):

```bash
# === 09-INSTALL: ORACLE INSTALLATION ===
ORACLE_BASE=/u01/app/oracle
ORACLE_HOME=/u01/app/oracle/fmw
JDK_HOME=/u01/app/oracle/java/jdk-21.0.6
PATCH_STORAGE=/srv/patch_storage

# === DOMAIN ===
WLS_ADMIN_PORT=7001
WLS_ADMIN_USER=webadmin
WLS_NODEMANAGER_PORT=5556
WLS_FORMS_PORT=9001
WLS_REPORTS_PORT=9002
DB_SCHEMA_PREFIX=DEV

# === COMPONENTS ===
INSTALL_COMPONENTS=FORMS_AND_REPORTS    # FORMS_ONLY | REPORTS_ONLY | FORMS_AND_REPORTS
FORMS_CUSTOMER_DIR=/app/forms/custom
REPORTS_CUSTOMER_DIR=/app/reports/custom

# === MOS DOWNLOADS ===
MOS_USER=firstname.lastname@company.com
# MOS_PWD → encrypted: mos_sec.conf.des3 (same mechanism as weblogic_sec.conf.des3)
INSTALL_PATCHES=33735326,34374498       # comma-separated, apply order matters
```

Existing parameters (`FMW_HOME`, `DOMAIN_HOME`, `REPORTS_SERVER_NAME` etc.) remain
unchanged — all modules 00–07 continue to work without modification.

---

## 6. Reuse of Existing Scripts

The installation module calls existing scripts directly — no code duplication:

| Existing script | Called from |
|---|---|
| `02-Checks/os_check.sh` | `04-oracle_pre_checks.sh` |
| `02-Checks/java_check.sh` | `04-oracle_pre_checks.sh` |
| `02-Checks/port_check.sh` | `04-oracle_pre_checks.sh` |
| `02-Checks/db_connect_check.sh` | `01-setup-interview.sh`, `04-oracle_pre_checks.sh` |
| `02-Checks/ssl_check.sh` | `10-oracle_validate.sh` |
| `02-Checks/weblogic_performance.sh` | `09-oracle_configure.sh` |
| `04-ReportsFonts/uifont_ali_update.sh` | `09-oracle_configure.sh` |
| `07-Maintenance/backup_config.sh` | `09-oracle_configure.sh` |
| `01-Run/rwserver_status.sh` | `10-oracle_validate.sh` |

Shared install functions (silent response file generation, OPatch version check,
password-file handling for RCU) live in `install_lib.sh`.

---

## 7. MOS Downloads (getMOSPatch.jar)

```
/srv/patch_storage/
├── bin/
│   ├── getMOSPatch.jar           ← from GitHub: MarisElsins/getMOSPatch
│   └── .getMOSPatch.cfg          ← platform + language (generated from environment.conf)
├── wls/                          ← FMW Infrastructure installer
├── fr/                           ← Forms & Reports installer
├── opatch/                       ← OPatch (p6880880)
└── patches/                      ← individual patches by number
```

Platform codes: `226P` = Linux x86-64 · `233P` = Linux ARM 64 · `46P` = Windows x86-64

→ [Detail: docs/04-oracle_pre_download.md](docs/04-oracle_pre_download.md)

---

## 8. sudo Concept for oracle User

Root operations run via selective sudo — no full root shell required:

```
/etc/sudoers.d/oracle-fmw:
oracle ALL=(root) NOPASSWD: /usr/bin/dnf install *
oracle ALL=(root) NOPASSWD: /usr/sbin/sysctl -p
oracle ALL=(root) NOPASSWD: /usr/bin/systemctl start|stop|reload|enable nginx
oracle ALL=(root) NOPASSWD: /bin/cp /etc/sysctl.d/*.conf /etc/sysctl.d/
oracle ALL=(root) NOPASSWD: /bin/cp /etc/security/limits.conf /etc/security/limits.conf
```

Scripts check `sudo -n <cmd> 2>/dev/null` — if oracle has sudo, execute directly;
otherwise display the command for manual execution.

---

## 9. System Requirements (FMW 14.1.2 on OL 8 / OL 9)

> IHateWeblogic targets **Oracle Linux 8 and Oracle Linux 9**.
> OL7 is end-of-life and not covered by these scripts.

### 9.1 Hardware – WebLogic / Forms / Reports server (no database on this host)

| Resource | Minimum | Dev / QS / MTN | Production |
|---|---|---|---|
| RAM | 8 GB | 16 GB | 64 GB |
| CPU cores | 1 core / 1 GHz | 2 cores | 4 cores |
| Disk `ORACLE_HOME` | 10 GB | 15 GB | 15 GB |
| Disk `DOMAIN_HOME` | 5 GB | 10 GB | 20 GB |
| Disk patch storage | 10 GB | 20 GB | 20 GB |
| Swap | 512 MB (OUI min) | = RAM | 1.5× RAM |
| `/tmp` | 300 MB (OUI min) | 2 GB | 2 GB |

**Production memory sizing example (WLS only):**
```
  8 GB  OS and other software
  3 GB  Admin Server
+ 6 GB  Two Managed Servers (WLS_FORMS + WLS_REPORTS)
------
 17 GB  minimum for WLS alone → plan 64 GB for production
```

> If the database runs on the same host, add DB RAM/CPU requirements on top.
> For IHateWeblogic the database is on a **separate server** (see section 9.3).

### 9.2 Oracle Universal Installer (OUI) minimum requirements

| Resource | OUI minimum |
|---|---|
| CPU speed | 300 MHz |
| Monitor | 256 colors (required for graphical installer mode) |
| Swap | 512 MB |
| Temp (`/tmp`) | 300 MB |

The OUI can also run in silent mode (no monitor required) — all installation scripts
use silent mode with response files.

### 9.3 Repository Database requirements

FMW 14.1.2 requires an Oracle Database for the FMW metadata schemas (RCU).
The database runs on a **separate server** from WebLogic.

**Certified database versions:**
- Oracle DB 23ai ≥ 23.4.0.24
- Oracle DB 19c ≥ 19.14.0.0

**Database prerequisites:**

| Requirement | Value |
|---|---|
| Oracle JVM | must be installed in the DB (`@?/javavm/install/initjvm.sql`) |
| Character set | `AL32UTF8` (mandatory for Forms/Reports Unicode) |
| Password expiry | `ALTER PROFILE DEFAULT LIMIT PASSWORD_LIFE_TIME UNLIMITED;` |

**Required DB parameters (RCU prereq check):**

| Parameter | Required value |
|---|---|
| `SHARED_POOL_SIZE` | 0 |
| `SGA_MAX_SIZE` | 6112M |
| `DB_BLOCK_SIZE` | 8 KB |
| `session_cached_cursors` | 200 |
| `processes` | 1200 |
| `open_cursors` | 2250 |
| `db_files` | 600 |

**Verify required DB package:**
```sql
-- Run as SYSDBA – must return DBMS_SHARED_POOL / SYS
SELECT object_name, owner
FROM   sys.all_objects
WHERE  object_name = 'DBMS_SHARED_POOL';
```

**Set password expiry (run in CDB and PDB):**
```sql
ALTER PROFILE DEFAULT LIMIT PASSWORD_LIFE_TIME UNLIMITED;
```

→ Full RCU procedure: [docs/07-oracle_setup_repository.md](docs/07-oracle_setup_repository.md)

### Directory Layout

```
/u01/
├── app/oracle/
│   ├── fmw/                      ← ORACLE_HOME (FMW Infrastructure + Forms/Reports)
│   ├── java/jdk-21.0.6/          ← JDK_HOME (standalone, NOT under fmw/)
│   └── oraInventory/             ← OUI inventory
└── user_projects/
    └── domains/
        └── fr_domain/            ← DOMAIN_HOME
```

---

## 10. File Structure

```
09-Install/
├── README.md                          ← this roadmap
├── install_lib.sh                     ← [TODO] shared functions
├── 01-setup-interview.sh              ← [TODO] configuration interview
├── 00-root_os_network.sh              ← Phase 0: hostname, hosts, IPv6, chrony, SSH
├── 01-root_os_baseline.sh             ← Phase 0: SELinux, kernel, THP, firewall → REBOOT
├── 02-root_os_packages.sh             ← Phase 0: packages, JDK
├── 03-root_user_oracle.sh             ← Phase 0: oracle user, limits, dirs, repo handover
├── 04-root_nginx.sh                   ← Phase 0: Nginx install + proxy config
├── 05-root_nginx_ssl.sh               ← Phase 0: SSL cert, TLS config, start Nginx
├── nginx-wls.conf.template            ← Nginx proxy config template (##VARIABLE## substitution)
├── 04-oracle_pre_checks.sh            ← [TODO]
├── 04-oracle_pre_download.sh          ← [TODO]
├── 05-oracle_install_weblogic.sh      ← [TODO]
├── 05-oracle_patch_weblogic.sh        ← [TODO]
├── 06-oracle_install_forms_reports.sh ← [TODO]
├── 06-oracle_patch_forms_reports.sh   ← [TODO]
├── 07-oracle_setup_repository.sh      ← [TODO]
├── 08-oracle_setup_domain.sh          ← [TODO]
├── 09-oracle_configure.sh             ← [TODO]
├── 10-oracle_validate.sh              ← [TODO]
├── response_files/                    ← response file templates
│   ├── wls_install.rsp.template
│   ├── fr_install.rsp.template
│   └── domain_config.py.template
└── docs/                              ← step-by-step detail documentation
    ├── 01-setup-interview.md
    ├── 00-root_user_oracle.md
    ├── 01-root_set_os_parameter.md
    ├── 02-root_nginx.md
    ├── 03-root_nginx_ssl.md
    ├── 04-oracle_pre_checks.md
    ├── 04-oracle_pre_download.md
    ├── 05-oracle_install_weblogic.md
    ├── 05-oracle_patch_weblogic.md
    ├── 06-oracle_install_forms_reports.md
    ├── 06-oracle_patch_forms_reports.md
    ├── 07-oracle_setup_repository.md
    ├── 08-oracle_setup_domain.md
    ├── 09-oracle_configure.md
    └── 10-oracle_validate.md
```

---

## 11. Local Reference Documents (90-Source-MetaData)

The `90-Source-MetaData/` directory holds local copies of Oracle documents used as
reference during script development. This directory is **not committed to git**
(binary files / Oracle license terms — see `.gitignore`).

Place the following files there manually before working on related scripts:

| File | Relevant for |
|---|---|
| `Oracle_WebLogic_Server_14.1.2.0.0_install.docx` | `05-oracle_install_weblogic.sh`, response files, OPatch |
| `fmw-141200-certmatrix.xlsx` | `04-oracle_pre_checks.sh`, `02-Checks/os_check.sh` |
| `Knowledge_Article_Log4J_Security_Alert_*/` | `05-oracle_patch_weblogic.sh`, Log4j guard |

---

## 12. References

- Oracle Forms & Reports 14.1.2 – Installation Guide:
  https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/install-fnr/index.html
- Oracle WebLogic Server 14.1.1 – Installation Guide:
  https://docs.oracle.com/en/middleware/standalone/weblogic-server/14.1.1.0/wlsig/planning-oracle-weblogic-server-installation.html#GUID-458885D0-B7E0-437F-866F-7EA6BA1B7BCC
- Oracle WebLogic Server 14.1.1 – Documentation Home:
  https://docs.oracle.com/en/middleware/standalone/weblogic-server/14.1.1.0/index.html
- Oracle Forms 14.1.2 – Practical installation guide:
  https://www.pipperr.de/dokuwiki/doku.php?id=forms:oracle_reports_14c_windows64
- Nginx proxy concept reference:
  https://www.pipperr.de/dokuwiki/doku.php?id=prog:oracle_apex_nginx_tomcat_ords_install_windows_server
- getMOSPatch.jar (MOS download tool):
  https://github.com/MarisElsins/getMOSPatch
