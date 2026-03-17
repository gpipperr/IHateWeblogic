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

**Before starting the installation, two documents are essential:**

| Document | Purpose |
|---|---|
| [docs/00-environment-setup.md](docs/00-environment-setup.md) | All `environment.conf` parameters explained — what they mean, who sets them, when they are available. Reference for the entire installation. |
| [docs/01-setup-interview.md](docs/01-setup-interview.md) | How `01-setup-interview.sh` collects parameters interactively and writes `environment.conf` before Phase 0 begins. |

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
Setup – Environment Configuration (as oracle; before Phase 0)
  [oracle] git clone <repo> && cd IHateWeblogic
  [oracle] ./09-Install/01-setup-interview.sh --apply  # interview → writes environment.conf
           → see docs/00-environment-setup.md for all parameters
           → see docs/01-setup-interview.md for interview details

Phase 0 – OS Preparation (as root; hand over repo to oracle at end of phase)
  [root] ./09-Install/00-root_os_network.sh --apply    # hostname, hosts, chrony, SSH
  [root] ./09-Install/01-root_os_baseline.sh --apply   # SELinux, kernel, THP → REBOOT
  [root] ./09-Install/02-root_os_packages.sh --apply   # OS packages (motif, gcc, numactl …)
  [root] ./09-Install/02b-root_os_java.sh --apply      # Oracle JDK 21 + SecureRandom fix
  [root] ./09-Install/03-root_user_oracle.sh --apply   # oracle user + chown repo → oracle
  [root] ./09-Install/04-root_nginx.sh --apply         # Nginx install + proxy config
  [root] ./09-Install/05-root_nginx_ssl.sh --apply     # SSL cert, TLS config

Phase 1 – Pre-Install Checks (as oracle)
  04-oracle_pre_checks.sh       Verify all prerequisites before download
  04-oracle_pre_download.sh     Download eDelivery ZIPs + MOS patches (OPatch + post-install)
                                  --apply        manual eDelivery placement + SHA-256 verify
                                  --apply --wget eDelivery via Bearer Token wget
                                  --apply --mos  + getMOSPatch: OPatch + INSTALL_PATCHES

Phase 2 – WebLogic Installation (as oracle)
  05-oracle_install_weblogic.sh FMW Infrastructure 14.1.2 silent install
  05-oracle_patch_weblogic.sh   Update OPatch + apply WLS patches

Phase 3 – Forms & Reports Installation (as oracle)
  06-oracle_install_forms_reports.sh  Forms/Reports 14.1.2 silent install
  06-oracle_patch_forms_reports.sh    Apply Forms/Reports patches

  ▶ ALL FMW software + patches must be complete before continuing.
    Phases 0–3 install and patch everything into ORACLE_HOME.
    The Oracle Home is not touched again after this point.

Phase DB – Oracle 19c RCU Database (on DB host; parallel to or after Phase 3)
  → Full procedure: 60-RCU-DB-19c/README.md
  [oracle/sudo] 60-RCU-DB-19c/00-root_db_os_baseline.sh --apply
                  DB-specific OS settings (shmmax, sem, aio, preinstall RPM)
                  auto-elevates via sudo when run as oracle
  [oracle]       60-RCU-DB-19c/01-db_install_software.sh --apply
                  Oracle 19c software-only install (unzip + runInstaller -silent)
  [oracle]       60-RCU-DB-19c/02-db_patch_autoupgrade.sh --apply
                  AutoUpgrade: download current RU, create patched ORACLE_HOME
  [oracle]       60-RCU-DB-19c/03-db_create_database.sh --apply
                  DBCA silent: CDB FMWCDB + PDB FMWPDB (AL32UTF8, AMM, no archivelog)
  [oracle]       60-RCU-DB-19c/04-db_audit_setup.sh --apply
                  Pure Unified Auditing (uniaud_on relink + purge job)
  [oracle]       60-RCU-DB-19c/05-db_fmw_tablespace.sh --apply
                  Optional: create FMW_DATA tablespace (skip = RCU creates its own)

  ▶ Database must be up and reachable from the FMW host before Phase 4.
    Run 00-Setup/database_rcu_sec.sh --apply to store DB credentials.

Phase 4 – Repository & Domain (as oracle)
  07-oracle_setup_repository.sh  RCU: create FMW metadata schemas in Oracle DB
                                   (reads DB_SYS_PWD + DB_SCHEMA_PWD from db_sys_sec.conf.des3)
  08-oracle_setup_domain.sh      Create WebLogic domain (WLST silent mode)
                                   (requires completed RCU schemas)

Phase 5 – Configuration & Validation (as oracle)
  09-oracle_configure.sh         Final configuration using existing 00-07 scripts
  10-oracle_validate.sh          Full validation report
```

---

## 3. Script Reference

| Phase | Script | Description | Detail |
|---|---|---|---|
| 0 | `00-root_os_network.sh` | Hostname, /etc/hosts, IPv6, chrony, SSH | [→ docs](docs/00-root_os_network.md) |
| 0 | `01-root_os_baseline.sh` | SELinux, kernel params, THP, core dump dir, firewall → **REBOOT** | [→ docs](docs/00-root_set_os_parameter.md) |
| 0 | `02-root_os_packages.sh` | dnf packages (motif, gcc, numactl …) | [→ docs](docs/01-root_install_packages.md) |
| 0 | `02b-root_os_java.sh` | Oracle JDK 21 install, alternatives, jps, SecureRandom fix | [→ docs](docs/01-root_setup_java.md) |
| 0 | `03-root_user_oracle.sh` | oracle user, limits, locale, sudo, dirs, repo handover | [→ docs](docs/03-root_user_oracle.md) |
| 0 | `04-root_nginx.sh` | Nginx install + proxy config from template | [→ docs](docs/02-root_nginx.md) |
| 0 | `05-root_nginx_ssl.sh` | SSL certificate deploy, TLS config, start Nginx | [→ docs](docs/03-root_nginx_ssl.md) |
| 1 | `04-oracle_pre_checks.sh` | Pre-install prerequisite validation | [→ docs](docs/04-oracle_pre_checks.md) |
| 1 | `04-oracle_pre_download.sh` | eDelivery ZIPs (manual/wget) + getMOSPatch: OPatch + patches | [→ docs](docs/04-oracle_pre_download.md) |
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

Runs **before all other installation steps**. Reads existing `environment.conf`, prompts
only for missing parameters (idempotent), encrypts passwords immediately, writes a
reusable `setup.conf` template.

- Interview blocks and all flags: → [docs/01-setup-interview.md](docs/01-setup-interview.md)
- Full parameter reference with defaults and validation: → [docs/00-environment-setup.md](docs/00-environment-setup.md)

---

## 5. environment.conf – Installation Parameters

→ **Full parameter reference:** [docs/00-environment-setup.md](docs/00-environment-setup.md)

Key parameters added by the 09-Install module (appended to existing `environment.conf`):

```bash
# === 09-INSTALL: ORACLE INSTALLATION ===
ORACLE_BASE=/u01/app/oracle
ORACLE_HOME=/u01/app/oracle/fmw
JDK_HOME=/u01/app/oracle/java/jdk-21
PATCH_STORAGE=/srv/patch_storage

# === DOMAIN ===
WLS_ADMIN_PORT=7001
WLS_ADMIN_USER=webadmin
WLS_NODEMANAGER_PORT=5556
WLS_FORMS_PORT=9001
WLS_REPORTS_PORT=9002
WLS_LISTEN_ADDRESS=localhost   # localhost = NGINX proxy (default); 0.0.0.0 = direct access
DB_SCHEMA_PREFIX=DEV

# === COMPONENTS ===
INSTALL_COMPONENTS=FORMS_AND_REPORTS    # FORMS_ONLY | REPORTS_ONLY | FORMS_AND_REPORTS
FORMS_CUSTOMER_DIR=/app/forms/custom
REPORTS_CUSTOMER_DIR=/app/reports/custom

# === MOS DOWNLOADS ===
MOS_USER=firstname.lastname@company.com
# MOS_PWD → encrypted: mos_sec.conf.des3 (same mechanism as weblogic_sec.conf.des3)
```

Software versions, patch numbers, SHA-256 checksums and OPatch regexp are defined
in `09-Install/oracle_software_version.conf` (committed to git, no credentials).

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

## 7. Software Download (04-oracle_pre_download.sh)

```
/srv/patch_storage/
├── bin/
│   ├── getMOSPatch.jar           ← auto-downloaded from GitHub on first --mos run
│   └── .getMOSPatch.cfg          ← platform + language (from oracle_software_version.conf)
├── wls/
│   ├── V1045135-01.zip           ← eDelivery: FMW Infrastructure 14.1.2 (manual/wget)
│   └── fmw_14.1.2.0.0_infrastructure.jar
├── fr/
│   ├── V1045121-01.zip           ← eDelivery: Forms & Reports 14.1.2 (manual/wget)
│   └── fmw_14.1.2.0.0_fr_linux64.bin
└── patches/
    ├── 28186730/                 ← OPatch upgrade package (getMOSPatch, OPATCH_UPGRADE_PATCH_NR)
    │   └── p28186730_139422_Generic.zip   ← contains 6880880/opatch_generic.jar
    └── 38566996/                 ← CPU Jan 2026: UMS Bundle Patch (getMOSPatch, INSTALL_PATCHES)
        └── p38566996_141200_Generic.zip
```

> Patch numbers change quarterly. Current values are in `oracle_software_version.conf`.
> See [docs/05-oracle_patch_weblogic.md](docs/05-oracle_patch_weblogic.md) for the discovery workflow.

All versions, filenames, SHA-256 checksums and patch numbers are defined in
`oracle_software_version.conf` (committed to git — no credentials).

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
→ DB setup scripts (if DB on same or separate host): [../60-RCU-DB-19c/README.md](../60-RCU-DB-19c/README.md)

### Directory Layout

```
/u01/
├── app/oracle/
│   ├── fmw/                      ← ORACLE_HOME (FMW Infrastructure + Forms/Reports)
│   ├── java/jdk-21/              ← JDK_HOME symlink (→ jdk-21.0.x, NOT under fmw/)
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
├── 01-setup-interview.sh              ← configuration interview
├── 00-root_os_network.sh              ← Phase 0: hostname, hosts, IPv6, chrony, SSH
├── 01-root_os_baseline.sh             ← Phase 0: SELinux, kernel, THP, firewall → REBOOT
├── 02-root_os_packages.sh             ← Phase 0: OS packages (motif, gcc, numactl …)
├── 02b-root_os_java.sh                ← Phase 0: Oracle JDK 21 + SecureRandom fix
├── 03-root_user_oracle.sh             ← Phase 0: oracle user, limits, dirs, repo handover
├── 04-root_nginx.sh                   ← Phase 0: Nginx install + proxy config
├── 05-root_nginx_ssl.sh               ← Phase 0: SSL cert, TLS config, start Nginx
├── nginx-wls.conf.template            ← Nginx proxy config template (##VARIABLE## substitution)
├── oracle_software_version.conf       ← SW versions, SHA-256, patch numbers, OPatch regexp
├── 04-oracle_pre_checks.sh            ← [TODO]
├── 04-oracle_pre_download.sh          ← eDelivery + getMOSPatch download
├── 05-oracle_install_weblogic.sh      ← FMW Infrastructure 14.1.2 silent install
├── 05-oracle_patch_weblogic.sh        ← OPatch upgrade + WLS CPU patch apply
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
    ├── 00-environment-setup.md        ← all environment.conf parameters + init concept
    ├── 01-setup-interview.md
    ├── 00-root_set_os_parameter.md    ← 01-root_os_baseline.sh
    ├── 00-root_os_network.md          ← 00-root_os_network.sh
    ├── 01-root_install_packages.md    ← 02-root_os_packages.sh
    ├── 01-root_setup_java.md          ← 02b-root_os_java.sh
    ├── 03-root_user_oracle.md         ← 03-root_user_oracle.sh
    ├── 20-oracle_security.md          ← post-install hardening checklist
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
