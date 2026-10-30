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

Background per step – **why** the domain looks like this (`80-FMW-Architecture/`):

| Step | Background |
|---|---|
| `05-`/`06-` homes, two JDKs | [the four homes](../80-FMW-Architecture/weblogic_middleware_architecture.md#1-terms--the-four-homes) |
| `07-` repository | [rcu_middleware_architecture.md](../80-FMW-Architecture/rcu_middleware_architecture.md) |
| `08-` domain, servers, clusters | [building blocks](../80-FMW-Architecture/weblogic_middleware_architecture.md#3-the-building-blocks) |
| `10-`/`11-`/`30-` boot, Node Manager, autostart | [Node Manager](../80-FMW-Architecture/weblogic_middleware_architecture.md#34-node-manager), [who starts whom](../80-FMW-Architecture/weblogic_middleware_architecture.md#4-who-starts-whom--the-control-chain) |
| `12-`/`13-` Reports server, security | [report_engine_architecture.md](../80-FMW-Architecture/report_engine_architecture.md), [reports_user_local_ldap.md](../80-FMW-Architecture/reports_user_local_ldap.md), [multicast discovery](../80-FMW-Architecture/reports_server_discovery_multicast.md), [image handling](../80-FMW-Architecture/report_server_image_handling.md) |
| `14-` Forms | [forms_runtime_architecture.md](../80-FMW-Architecture/forms_runtime_architecture.md) (runtime pooling / `FORMS_PRESTART_SECTION`), [forms_jakob_webutil.md](../80-FMW-Architecture/forms_jakob_webutil.md) |
| `14b-` fonts | [`rwrun` vs. engines, same font files](../80-FMW-Architecture/report_engine_architecture.md#51-rwrun--a-report-without-rwservlet-and-without-reports-server), [../04-ReportsFonts/README.md](../04-ReportsFonts/README.md) |

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
| `monUser` | Monitor | Read-only for monitoring/alerting (`RW_MONITOR` role) |
| `RepRunner` | Reports Runner | Submits Reports jobs via rwservlet (`RW_EXECREPORTS` role) |

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
           → WLS_SERVER_FQDN = PUBLIC name (URL of the users, certificate SAN) – in the
             cloud / with a DNS alias NOT the host name (host.subnet.vcn.oraclevcn.com)
           → see docs/00-environment-setup.md for all parameters
           → see docs/01-setup-interview.md for interview details

Phase 0 – OS Preparation (as root; hand over repo to oracle at end of phase)
  [root] ./09-Install/00-root_os_network.sh            # hostname, DNS/hosts, IPv6, chrony (read-only check)
  [root] ./09-Install/01-root_os_baseline.sh --apply   # SELinux, kernel, THP, firewall, sshd → REBOOT
         (later, on a running system: --apply --skip-update --only firewall,ssh)
  [root] ./09-Install/02-root_os_packages.sh --apply   # OS packages (motif, gcc, numactl …)
  [root] ./09-Install/02b-root_os_java.sh --apply      # Oracle JDK 21 + SecureRandom fix
         (no JDK found: bootstrap 21.0.12.1 from the CDN archive – curl hangs behind a
          firewall → download in a browser + scp to /tmp, docs/01-root_setup_java.md)
  [root] ./09-Install/03-root_user_oracle.sh --apply   # oracle user + chown repo → oracle
  [root] ./09-Install/04-root_nginx.sh --apply         # Nginx install + proxy config
         (asks ADMIN_IP_RANGE once: host network / own list / any = no admin network,
          or --admin-range <list>|any – docs/04-root_nginx.md#admin-network-admin_ip_range--optional)

  Server certificate (as oracle – SSL_CERT_SOURCE from the interview), BEFORE 05-:
    customer PKI (SSL_CERT_SOURCE=customer):
      customer files → 08-SSL/user_certs/   server.crt|.cert + server.key (or server.p12),
                                            chain.crt, root.crt, codesign.p12 (role names:
                                            08-SSL/user_certs/README.md – gitignored)
      [oracle] ./08-SSL/ssl_customer_certs.sh           # check only: key ↔ cert, SAN, chain, expiry
      [oracle] ./08-SSL/ssl_customer_certs.sh --apply   # import → 08-SSL/certs/ + ssl.conf
                                                        # (encrypted key / PFX: password asked)
      then delete the files in 08-SSL/user_certs/
    own root CA (SSL_CERT_SOURCE=localca, default):
      [oracle] ./08-SSL/ssl_prepare_cert.sh LOCALCA --apply   # root CA (once) + server cert
    → docs/05-root_nginx_ssl.md "Certificate Options"

  [root] ./09-Install/05-root_nginx_ssl.sh --apply     # deploy 08-SSL/certs/ → /etc/nginx/ssl,
                                                       # nginx -t, start Nginx, TLS test
         (prompts show the IMPORTED files in 08-SSL/certs/; warns if user_certs/
          holds a server certificate that is not imported yet)

Phase 1 – Pre-Install Checks (as oracle)
  [oracle] ./09-Install/04-oracle_pre_checks.sh        # verify all prerequisites before download
             --skip-db        remote RCU DB not reachable yet (local DB with LOCAL_REP_DB=true
                              that is not built yet is skipped automatically)
  [oracle] ./09-Install/04-oracle_pre_download.sh      # eDelivery ZIPs + MOS patches (OPatch + post-install)
             --apply          manual eDelivery placement + SHA-256 verify
             --apply --wget   eDelivery via Bearer Token wget
             --apply --mos    + MOS patches of download/patches_fmw.csv
                              (+ JDK 21 patch, CVU for a local RCU DB)
         (no MOS access from this host: download on another host with
          70-Customer-Projects/tools/mos_patch_download.sh -c patches_fmw.csv,
          rsync PATCH_STORAGE – see 09-Install/download/README.md)
  [root]   ./09-Install/02b-root_os_java.sh --apply --upgrade-jdk
                                                       # JDK 21 of the current patch cycle (JDK_PATCH_NR
                                                       # from the patch repository) – BEFORE 05-: phase 0
                                                       # only installs the bootstrap JDK (NFTC 21.0.12.1);
                                                       # the FMW installer and createDomain write its path

Phase 2 – WebLogic Installation (as oracle)
  [oracle] ./09-Install/05-oracle_install_weblogic.sh --apply   # FMW Infrastructure 14.1.2 silent install
  [oracle] ./09-Install/05-oracle_patch_weblogic.sh --apply     # update OPatch + apply WLS patches

Phase 3 – Forms & Reports Installation (as oracle)
  [oracle] ./09-Install/06-oracle_install_forms_reports.sh --apply  # Forms/Reports 14.1.2 silent install
  [oracle] ./09-Install/06-oracle_patch_forms_reports.sh --apply    # apply Forms/Reports patches

  ▶ ALL FMW software + patches must be complete before continuing.
    Phases 0–3 install and patch everything into ORACLE_HOME.
    The Oracle Home is not touched again after this point.

  Small local disk + patch archive (PATCH_ARCHIVE, NFS/ZFS master copy):
    before each step  [oracle] ./07-Maintenance/patch_storage.sh pull <step script> --apply
                      e.g. pull 05-oracle_install_weblogic.sh / 05-oracle_patch_weblogic.sh /
                           06-oracle_install_forms_reports.sh / 06-oracle_patch_forms_reports.sh
    after the step    [oracle] ./07-Maintenance/patch_storage.sh clean --apply
                      frees the files of steps whose last --apply run succeeded
                      (run history log/run_history.csv) – they stay in the archive
    overview          [oracle] ./07-Maintenance/patch_storage.sh   (status: what is where)

Phase DB – Oracle 19c RCU Database (separate DB host, or the same host with
           LOCAL_REP_DB=true; parallel to or after Phase 3)
  → Full procedure: 60-RCU-DB-19c/README.md
  [oracle/sudo] ./60-RCU-DB-19c/00-root_db_os_baseline.sh --apply
                  DB-specific OS settings (shmmax, sem, aio, preinstall RPM)
                  auto-elevates via sudo when run as oracle
  [oracle]      ./60-RCU-DB-19c/00b-db_cvu_check.sh
                  host pre-check with the standalone CVU (downloaded by 04- --mos)
  [oracle]      ./60-RCU-DB-19c/01-db_install_software.sh --apply
                  19c software-only install, patched in one go: AutoUpgrade
                  downloads RU + OJVM + Data Pump + JDK (gold image possible),
                  runInstaller -applyRU (02-db_patch_db_software.sh is DEPRECATED)
  [oracle]      ./60-RCU-DB-19c/04-db_setup_listener.sh --apply
                  configure the TNS listener
  [oracle]      ./60-RCU-DB-19c/05-db_create_database.sh --apply
                  DBCA silent: CDB FMWCDB + PDB FMWPDB (AL32UTF8, no archivelog,
                  MAX_STRING_SIZE=EXTENDED in every container incl. PDB$SEED)
  [oracle]      ./60-RCU-DB-19c/06-db_audit_setup.sh --apply
                  Pure Unified Auditing (uniaud_on relink + purge job)
  [oracle]      ./60-RCU-DB-19c/07-db_fmw_tablespace.sh --apply
                  optional: create FMW_DATA tablespace (skip = RCU creates its own)
  [oracle]      ./60-RCU-DB-19c/07b-db_rcu_profile.sh --apply
                  DB profile RCU_USER (no password expiry / lock for the schemas)
  [oracle]      ./60-RCU-DB-19c/08-db_auto_start.sh --apply
                  configure DB/listener autostart (oratab, systemd)
  later:        ./60-RCU-DB-19c/09-db_patch_rcu.sh – next DB RU out-of-place

  ▶ Database must be up and reachable from the FMW host before Phase 4.
  [oracle] ./00-Setup/database_rcu_sec.sh --apply      # store the DB credentials (encrypted)

Phase 4 – Repository & Domain (as oracle)
  [oracle] ./09-Install/07-oracle_setup_repository.sh --check
                                                       # RCU DB requirements (parameters, JVM, charset,
                                                       # edition, db_securefile) – nothing is created
  [oracle] ./09-Install/07-oracle_setup_repository.sh --apply
                                                       # RCU: create the FMW metadata schemas
                                                       # (DB_SYS_PWD + DB_SCHEMA_PWD from db_sys_sec.conf.des3)
  [oracle] ./09-Install/08-oracle_setup_domain.sh --apply
                                                       # create the WebLogic domain (WLST silent; needs
                                                       # the RCU schemas; loopback only: SSL demo ports
                                                       # off, Coherence on the listen address; resets
                                                       # the resolved JDK path to the jdk-21 link)

Phase 5 – Configuration (as oracle)
  [oracle] ./09-Install/09-oracle_configure.sh --apply # pre-start configuration (boot.properties, JVM,
                                                       # font OS packages, validation, backup)
                                                       # – fonts/cgicmd.dat: 14b-

Phase 6 – Runtime Configuration (as oracle / root)
  [oracle] ./00-Setup/init_env.sh --apply                          # add runtime parameters to environment.conf
                                                                   # (WLS_MANAGED_SERVER, REPORTS_* – needed by 13-)
  [oracle] ./09-Install/10-oracle_boot_properties.sh --apply       # boot.properties for AdminServer + Managed Server
  [oracle] ./09-Install/11-oracle_nodemanager.sh --apply --skip-wlst  # NodeManager config before first start
  → Start AdminServer + NodeManager manually
  [oracle] ./09-Install/11-oracle_nodemanager.sh --apply           # WLST: set Machine NMType=Plain
  [oracle] ./09-Install/12-oracle_reports_users.sh --apply         # create WLS users monUser + RepRunner
  [root]   ./09-Install/13-root_reports_fix.sh --apply             # libnsl.so.2 symlink (OL9 only)
  [edit]   09-Install/forms_templates/*.template                   # adapt templates before the Forms setup
  [oracle] ./01-Run/startStop.sh start WLS_REPORTS --apply         # first start creates the app dir (rwservlet.properties)
  [oracle] ./09-Install/13-oracle_setup_reports.sh --apply         # rwnetwork.conf, rwservlet, rwserver.conf
  [oracle] ./09-Install/14-oracle_setup_forms.sh --apply           # copy Forms config templates into the domain
  [oracle] ./01-Run/startStop.sh stop-all --apply                  # restart: 13-/14- changes become active
  [oracle] ./01-Run/startStop.sh start-all --apply
  [oracle] ./09-Install/14b-oracle_reports_fonts.sh --apply        # fonts, uifont.ali, cgicmd.dat, backup
                                                                   # (needs the WLS_REPORTS app dir of the first start)

Phase 7 – Validation (as oracle) [planned]
  [oracle] ./09-Install/90-oracle_validate.sh          # full validation report → docs/90-oracle_validate.md

Phase 7b – Smoke Test Modules (as oracle) [verified 2026-10-16]
  [oracle] ./09-Install/15-deploy-test-report-forms_template.sh --apply
                                                       # compile a minimal Forms module + convert a minimal
                                                       # Reports demo, to prove Forms/Reports reach the DB;
                                                       # runs the report via rwservlet (PDF)
                                                       # → docs/20-forms_reports_testmodules.md

Phase 7c – Autostart at boot (as oracle; systemd part via sudo)
  [oracle] ./09-Install/30-configure_autostart.sh --apply
                                                       # render autostart_templates/ into
                                                       # $ORACLE_BASE/admin/<domain>/ctrl, WLST key files,
                                                       # systemd unit fmw-<domain>.service (Node Manager
                                                       # controlled) → docs/30-configure_autostart.md

Phase 7d – Forms client distribution (as oracle; only FORMS_CLIENT_DIST=true)
  [oracle] ./09-Install/40-oracle_forms_client_bundle.sh --apply
                                                       # Windows Java runtime (jlink) + FSAL + JACOB for
                                                       # Nginx /formsWeb/, PowerShell installer from
                                                       # client_templates/ → docs/40-forms_client_distribution.md

Final checks (as oracle, read-only)
  [oracle] ./02-Checks/tns_admin_check.sh              # one TNS_ADMIN for every process (incl. running ones)
  [oracle] ./02-Checks/clone_check.sh                  # loopback-only / clone-capable installation
  [oracle] ./10-Monitoring/cert_expiry_check.sh --cron --apply   # daily certificate expiry check (cron)

Teardown – Remove FMW, keep the database (as oracle) [IRREVERSIBLE]
  [oracle] ./09-Install/99-oracle_deinstall_fmw.sh --apply
                                                       # stop FMW, OUI deinstall, remove ORACLE_HOME/
                                                       # DOMAIN_HOME/FMW client ADR; keeps DB, inventory,
                                                       # JDK, patch storage, RCU schemas, *.des3
                                                       # → docs/99-oracle_deinstall_fmw.md
```

---

## 3. Script Reference

| Phase | Script | Description | Detail |
|---|---|---|---|
| 0 | `00-root_os_network.sh` | Hostname, DNS/hosts, resolver, IPv6, chrony (read-only check) | [→ docs](docs/00-root_os_network.md) |
| 0 | `01-root_os_baseline.sh` | SELinux, kernel params, THP, core dump dir, firewall (safe activation with rollback timer), sshd hardening (`SSH_ALLOW_USERS`); `--only <sections>` → **REBOOT** | [→ docs](docs/00-root_set_os_parameter.md) |
| 0 | `02-root_os_packages.sh` | dnf packages (motif, gcc, numactl …) | [→ docs](docs/01-root_install_packages.md) |
| 0 / 1 | `02b-root_os_java.sh` | Oracle JDK 21 install, alternatives, jps, SecureRandom fix; after `04-` `--upgrade-jdk` = JDK of the current patch cycle | [→ docs](docs/01-root_setup_java.md) |
| 0 | `03-root_user_oracle.sh` | oracle user, limits, locale, sudo, dirs, repo handover | [→ docs](docs/03-root_user_oracle.md) |
| 0 | `04-root_nginx.sh` | Nginx install + proxy config from template; optional admin network `ADMIN_IP_RANGE` (asked once, `--admin-range`) | [→ docs](docs/04-root_nginx.md) |
| 0 | `05-root_nginx_ssl.sh` | SSL certificate deploy (from `08-SSL/certs/` – customer files imported first with `08-SSL/ssl_customer_certs.sh`), start Nginx | [→ docs](docs/05-root_nginx_ssl.md) |
| 1 | `04-oracle_pre_checks.sh` | Pre-install prerequisite validation | [→ docs](docs/04-oracle_pre_checks.md) |
| 1 | `04-oracle_pre_download.sh` | eDelivery ZIPs (manual/wget) + getMOSPatch: OPatch + patches | [→ docs](docs/04-oracle_pre_download.md) |
| 2 | `05-oracle_install_weblogic.sh` | FMW Infrastructure silent install | [→ docs](docs/05-oracle_install_weblogic.md) |
| 2 | `05-oracle_patch_weblogic.sh` | OPatch update + WLS patches | [→ docs](docs/05-oracle_patch_weblogic.md) |
| 3 | `06-oracle_install_forms_reports.sh` | Forms/Reports 14.1.2 silent install (Forms and Reports Deployment / Standalone Forms Builder) | [→ docs](docs/06-oracle_install_forms_reports.md) |
| 3 | `06-oracle_patch_forms_reports.sh` | Forms/Reports patches | [→ docs](docs/06-oracle_patch_forms_reports.md) |
| 4 | `07-oracle_setup_repository.sh` | RCU: create FMW metadata schemas; `--check` = DB requirements only | [→ docs](docs/07-oracle_setup_repository.md) |
| 4 | `08-oracle_setup_domain.sh` | Domain creation (WLST silent) | [→ docs](docs/08-oracle_setup_domain.md) |
| 5 | `09-oracle_configure.sh` | Pre-start configuration using 00-07 scripts | [→ docs](docs/09-oracle_configure.md) |
| 6 | `10-oracle_boot_properties.sh` | boot.properties for AdminServer + Managed Server | [→ docs](docs/10-oracle_boot_properties.md) |
| 6 | `11-oracle_nodemanager.sh` | Configure NodeManager (plain mode, WLST) | [→ docs](docs/11-oracle_nodemanager.md) |
| 6 | `12-oracle_reports_users.sh` | Create WLS users monUser + RepRunner | [→ docs](docs/12-weblogic-report-monitoring_user.md) |
| 6 | `13-root_reports_fix.sh` | libnsl.so.2 symlink for OL9 (root) | [→ docs](docs/13-reports-detail-settings.md) |
| 6 | `13-oracle_setup_reports.sh` | Configure Reports Server (rwnetwork, rwservlet, rwserver) | [→ docs](docs/13-reports-detail-settings.md) |
| 6 | `14-oracle_setup_forms.sh` | Copy Forms config templates into the domain | [→ docs](docs/14-forms-detail-settings.md) |
| 6 | `14b-oracle_reports_fonts.sh` | Reports fonts, uifont.ali, cgicmd.dat (after first start) | [→ docs](docs/14b-oracle_reports_fonts.md) |
| 7 | `90-oracle_validate.sh` | Full validation report [planned] | [→ docs](docs/90-oracle_validate.md) |
| 7b | `15-deploy-test-report-forms_template.sh` | Smoke test: minimal Forms module + Reports demo, DB reachability only. verified 2026-10-16 (XML→FMX, XML→RDF→PDF); DB user/password in `test_db_sec.conf.des3` | [→ docs](docs/20-forms_reports_testmodules.md) |
| pre | `01-setup-interview.sh` | Configuration interview → environment.conf | [→ docs](docs/01-setup-interview.md) |
| 7c | `30-configure_autostart.sh` | Autostart at boot: control scripts from `autostart_templates/` (Node Manager controlled, orderly shutdown), WLST key files, systemd unit | [→ docs](docs/30-configure_autostart.md) |
| 7d | `40-oracle_forms_client_bundle.sh` | Forms client bundle for Nginx `/formsWeb/`: Windows Java runtime built with jlink from the MOS client JDK (CA inside `cacerts`), `frmsal.jar`, JACOB DLL, `manifest.json` (atomic switch, `--rollback`); only `FORMS_CLIENT_DIST=true`. PowerShell installer `client_templates/FormsWeb-Setup.ps1` (first Windows FSAL session 2026-10-23) | [→ docs](docs/40-forms_client_distribution.md) |
| teardown | `99-oracle_deinstall_fmw.sh` | Remove the whole FMW installation for a clean reinstall; database on the same host is kept. **Irreversible**, typed confirmation | [→ docs](docs/99-oracle_deinstall_fmw.md) |

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
FORMS_CUSTOMER_DIR=/u01/app/oracle/forms/moduls
FORMS_TMP=/u01/app/oracle/forms/tmp
REPORTS_CUSTOMER_DIR=/u01/app/oracle/reports/source

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
| `02-Checks/ssl_check.sh` | `90-oracle_validate.sh` [planned] |
| `02-Checks/weblogic_performance.sh` | `09-oracle_configure.sh` |
| `04-ReportsFonts/get_root_install_libs.sh` | `09-oracle_configure.sh` |
| `04-ReportsFonts/deploy_fonts.sh` | `14b-oracle_reports_fonts.sh` |
| `04-ReportsFonts/font_cache_reset.sh` | `14b-oracle_reports_fonts.sh` |
| `04-ReportsFonts/uifont_ali_update.sh` | `14b-oracle_reports_fonts.sh` |
| `04-ReportsFonts/fontpath_config.sh` | `14b-oracle_reports_fonts.sh` |
| `07-Maintenance/backup_config.sh` | `09-oracle_configure.sh`, `14b-oracle_reports_fonts.sh` |
| `09-Install/10-oracle_boot_properties.sh` | `09-oracle_configure.sh` (Step 0) |
| `01-Run/rwserver_status.sh` | `90-oracle_validate.sh` [planned] |

Shared install functions (silent response file generation, OPatch version check,
password-file handling for RCU) are planned to live in `install_lib.sh` — not yet
created; each script currently defines its own helpers (`_run_root`, `_can_sudo`, …).

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
├── jdk/                          ← JDK 21 tarballs extracted by 02b- --upgrade-jdk
├── database/cvu/                 ← standalone CVU (only LOCAL_REP_DB=true)
└── patches/<patch nr>/p<nr>_*.zip  ← getMOSPatch, one directory per patch, e.g. (CPU Oct 2026):
    ├── 28186730/                 ← OPatch 13.9.4.2.25 (OPATCH_UPGRADE_PATCH_NR; also inside the SPB)
    ├── 40125898/                 ← WLS Stack Patch Bundle 14.1.2.0.261007 (WLS_SPB_PATCH_NR) – opatch napply
    ├── 35702194/                 ← Oracle JDK 21 (JDK_PATCH_NR)
    ├── 40050062/ …               ← FMW Infrastructure bundles (INSTALL_PATCHES)
    ├── 39951765/ …               ← Forms & Reports common (INSTALL_PATCHES_FR_COMMON)
    ├── 39842516/                 ← Forms 14.1.2 QPR (INSTALL_PATCHES_FORMS)
    └── 39600348/                 ← Reports 14.1.2 QPR (INSTALL_PATCHES_REPORTS)
```

> Patch numbers change every month (CPU quarterly, CSPU in between). Current values are in `oracle_software_version.conf`,
> central Doc-ID list in `docs/00-patch-references.md`.
> See [docs/05-oracle_patch_weblogic.md](docs/05-oracle_patch_weblogic.md) for the discovery workflow.
> New cycle: `04-oracle_pre_download.sh --apply --fresh-patches --mos` (old ZIPs moved to `patches_<ts>/`).

All versions, filenames, SHA-256 checksums and patch numbers are defined in
`oracle_software_version.conf` (committed to git — no credentials).

Platform codes: `226P` = Linux x86-64 · `541P` = Linux ARM 64-bit · `233P` = Microsoft Windows x64 (`46P` = Linux x86 32-bit – checked with getMOSPatch 2026-10-22)

→ [Detail: docs/04-oracle_pre_download.md](docs/04-oracle_pre_download.md)

---

## 8. sudo Concept for oracle User

Root operations run via selective sudo — no full root shell required:

```
/etc/sudoers.d/oracle-fmw   (written by 03-root_user_oracle.sh, checked with visudo -c):
oracle ALL=(root) NOPASSWD: /usr/bin/dnf install *, /usr/bin/dnf update *
oracle ALL=(root) NOPASSWD: /usr/sbin/sysctl -p *, /usr/sbin/sysctl --system
oracle ALL=(root) NOPASSWD: /usr/bin/systemctl start|stop|reload|enable|status nginx   (one line each)
oracle ALL=(root) NOPASSWD: /bin/cp /etc/sysctl.d/*.conf /etc/sysctl.d/
oracle ALL=(root) NOPASSWD: /bin/cp /etc/security/limits.conf /etc/security/limits.conf
oracle ALL=(root) NOPASSWD: /usr/bin/firewall-cmd *
oracle ALL=(root) NOPASSWD: /usr/bin/fc-cache -f -v
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
| ulimit `nofile`/`nproc` (oracle user) | 65536 / 16384 | 65536 / 16384 | **81920/81920** (100-500) · ~131072/131072 (500-1000, est.) · ~262144/262144 (>1000, lowest confidence) |

> ulimit values are set by `03-root_user_oracle.sh`, sized via the
> `EXPECTED_SESSIONS` question in `01-setup-interview.sh` (< 100 / 100-500 /
> 500-1000 / > 1000 concurrent Forms/Reports sessions). Only the 100-500
> tier (81920/81920) is a confirmed real production value; the `500-1000`
> and especially the `>1000` tier are estimates of decreasing confidence,
> not measurements — see
> [docs/00-root_set_os_parameter.md](docs/00-root_set_os_parameter.md) for
> the full rationale and the matching sysctl kernel parameters.

**Production memory sizing example (WLS only):**
```
  8 GB  OS and other software
  3 GB  Admin Server
+ 6 GB  Two Managed Servers (WLS_FORMS + WLS_REPORTS)
------
 17 GB  minimum for WLS alone → plan 64 GB for production
```

**Forms session RAM budget (additional, on top of the above):** Oracle
Forms starts one dedicated `frmweb` process per active session, each using
roughly 30-80 MB RAM. Rule of thumb: `expected sessions × ~50 MB`, e.g.
~25 GB for 500 sessions, ~50 GB for 1000 sessions — on top of the WLS JVM
heaps above. External sizing estimate, not independently verified against
a specific measured host; validate with real load testing before sizing
production hardware.

> If the database runs on the same host (`LOCAL_REP_DB=true`), add DB RAM/CPU
> requirements on top – disk: [Disk Sizing Guide](../README.md#disk-sizing-guide).

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
Recommended on a **separate server**; on the same host with
`LOCAL_REP_DB=true` (built with `60-RCU-DB-19c/`). The RCU database needs its
own DB licence – details [rcu_middleware_architecture.md §9.4](../80-FMW-Architecture/rcu_middleware_architecture.md).

**Certified database versions:**
- Oracle DB 23ai ≥ 23.4.0.24
- Oracle DB 19c ≥ 19.14.0.0

**Database prerequisites:**

| Requirement | Value |
|---|---|
| Oracle JVM | must be installed in the DB (`@?/javavm/install/initjvm.sql`) |
| Version | 19c ≥ 19.14.0.0, 23ai / 26ai ≥ 23.4.0.24 (26ai: RCU patch 38391376 – in the WLS SPB) |
| Edition | Enterprise Edition (SE2: RCU hits ORA-00439 – fine-grained access control / partitioning) |
| Character set | `AL32UTF8` (RCU only warns; mandatory here for Forms/Reports Unicode) |
| Password expiry | `ALTER PROFILE DEFAULT LIMIT PASSWORD_LIFE_TIME UNLIMITED;` |

**Required DB parameters** (minimums of the FMW 14.1.2 System Requirements,
"RCU Requirements for Oracle Databases" – check: `07-oracle_setup_repository.sh --check`,
details: [rcu_middleware_architecture.md §9](../80-FMW-Architecture/rcu_middleware_architecture.md#9-database-requirements-for-the-repository-19c--26ai)):

| Parameter | Minimum |
|---|---|
| `SHARED_POOL_SIZE` | 147,456 KB (ASMM / `0` is fine) |
| `SGA_MAX_SIZE` | 147,456 KB |
| `DB_BLOCK_SIZE` | 8 KB |
| `session_cached_cursors` | 100 |
| `processes` | 1000 |
| `open_cursors` | 1600 |
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
└── app/
    ├── oracle/                   ← ORACLE_BASE
    │   ├── fmw/                  ← ORACLE_HOME (FMW Infrastructure + Forms/Reports)
    │   ├── java/jdk-21           ← JDK_HOME symlink (→ jdk-21.0.x, NOT under fmw/)
    │   ├── domains/fr_domain/    ← DOMAIN_HOME (interview default ${ORACLE_BASE}/domains/fr_domain)
    │   ├── forms/{moduls,tmp}    ← FORMS_CUSTOMER_DIR / FORMS_TMP
    │   └── reports/source        ← REPORTS_CUSTOMER_DIR
    └── oraInventory/             ← ORACLE_INVENTORY (interview default: one level above ORACLE_BASE)
/srv/patch_storage/               ← PATCH_STORAGE (own file system recommended)
```

Disk space per area (FMW only ~75 GB, with a local RCU DB ≥ 140 GB): root
README [Disk Sizing Guide](../README.md#disk-sizing-guide).

---

## 10. File Structure

```
09-Install/
├── README.md                          ← this roadmap
├── install_lib.sh                     ← [TODO] shared functions
├── 01-setup-interview.sh              ← configuration interview
├── 00-root_os_network.sh              ← Phase 0: hostname, DNS/hosts, IPv6, chrony (check only)
├── 01-root_os_baseline.sh             ← Phase 0: SELinux, kernel, THP, firewall, sshd → REBOOT
├── 02-root_os_packages.sh             ← Phase 0: OS packages (motif, gcc, numactl …)
├── 02b-root_os_java.sh                ← Phase 0: Oracle JDK 21 + SecureRandom fix
├── 03-root_user_oracle.sh             ← Phase 0: oracle user, limits, dirs, repo handover
├── 04-root_nginx.sh                   ← Phase 0: Nginx install + proxy config
├── 05-root_nginx_ssl.sh               ← Phase 0: SSL cert, TLS config, start Nginx
├── nginx-wls.conf.template            ← Nginx proxy config template (##VARIABLE## substitution)
├── oracle_software_version.conf       ← SW versions, SHA-256, cycle values; loads download/patches_fmw.csv
├── download/                          ← per-cycle patch lists (CSV) – library + mos_patch_download.sh
│   ├── patches_fmw.csv / patches_db.csv
│   └── README.md
├── 04-oracle_pre_checks.sh            ← Phase 1: pre-install prerequisite validation
├── 04-oracle_pre_download.sh          ← eDelivery + getMOSPatch download
├── 05-oracle_install_weblogic.sh      ← FMW Infrastructure 14.1.2 silent install
├── 05-oracle_patch_weblogic.sh        ← OPatch upgrade + WLS CPU patch apply
├── 06-oracle_install_forms_reports.sh ← Phase 3: Forms/Reports silent install
├── 06-oracle_patch_forms_reports.sh   ← Phase 3: Forms/Reports patches
├── 07-oracle_setup_repository.sh      ← Phase 4: RCU metadata schemas
├── 08-oracle_setup_domain.sh          ← Phase 4: domain creation (WLST silent)
├── 09-oracle_configure.sh             ← Phase 5: orchestrator – calls scripts 00-07
├── 10-oracle_boot_properties.sh       ← Phase 6: boot.properties for AdminServer + Managed Server
├── 11-oracle_nodemanager.sh           ← Phase 6: configure NodeManager (plain mode, WLST)
├── 12-oracle_reports_users.sh         ← Phase 6: create WLS users monUser + RepRunner
├── 13-root_reports_fix.sh             ← Phase 6: libnsl.so.2 symlink (root, OL9 only)
├── 13-oracle_setup_reports.sh         ← Phase 6: configure Reports Server
├── 14-oracle_setup_forms.sh           ← Phase 6: copy Forms config templates into the domain
├── 14b-oracle_reports_fonts.sh        ← Phase 6: Reports fonts, uifont.ali, cgicmd.dat
├── 15-deploy-test-report-forms_template.sh  ← Phase 7b: smoke test (Forms+Reports), verified 2026-10-16
├── 30-configure_autostart.sh          ← Phase 7c: autostart at boot (systemd, Node Manager controlled)
├── 40-oracle_forms_client_bundle.sh   ← Phase 7d: Forms client bundle for Nginx /formsWeb/
├── 99-oracle_deinstall_fmw.sh         ← Teardown: remove FMW completely, keep the database (irreversible)
├── autostart_templates/               ← Templates rendered by 30-configure_autostart.sh
│   ├── fmw_env.sh.template / fmw_ctl.sh.template          (env + control wrapper)
│   ├── wls_start.py / wls_stop.py / wls_status.py .template (WLST via Node Manager)
│   └── fmw.service.template                                 (systemd unit)
├── client_templates/                  ← Windows client installer (FormsWeb-Setup.ps1, FormsWeb-Install.cmd)
├── forms_templates/                   ← Forms config templates (edited by the customer)
│   ├── README.md
│   ├── default.env.template
│   ├── formsweb.cfg.template
│   ├── webutil.cfg.template
│   ├── Registry.dat.template
│   ├── fmrweb_utf8.res.template
│   ├── fmrwebd.res.template
│   └── test_form.xml                  ← Phase 7b smoke-test Forms module (verified 2026-10-16)
├── reports_templates/                 ← Phase 7b smoke-test Reports demo reports
│   ├── test_dual.xml                  ← no parameters, SYSDATE only (verified 2026-10-16)
│   ├── test_user_objects.xml          ← one parameter + parameter form, USER_OBJECTS
│   └── REPORTS_XML_SYNTAX_REFERENCE.md ← Reports XML syntax reference (DTD-confirmed), reusable for debugging any Reports XML
├── response_files/                    ← response file templates
│   ├── cgicmd.dat.template
│   ├── fr_install.rsp.template
│   └── domain_config.py.template
└── docs/                              ← step-by-step detail documentation
    ├── 00-environment-setup.md        ← all environment.conf parameters + init concept
    ├── 00-patch-references.md         ← current patch cycle: Doc IDs, patch numbers, CVE assessment
    ├── 00-patch-references_september_2026.md ← frozen snapshot of the previous cycle
    ├── 01-setup-interview.md
    ├── 00-root_set_os_parameter.md    ← 01-root_os_baseline.sh
    ├── 00-root_os_network.md          ← 00-root_os_network.sh
    ├── 01-root_install_packages.md    ← 02-root_os_packages.sh
    ├── 01-root_setup_java.md          ← 02b-root_os_java.sh
    ├── 03-root_user_oracle.md         ← 03-root_user_oracle.sh
    ├── 04-root_nginx.md               ← 04-root_nginx.sh
    ├── 05-root_nginx_ssl.md            ← 05-root_nginx_ssl.sh
    ├── 04-oracle_pre_checks.md
    ├── 04-oracle_pre_download.md
    ├── 05-oracle_install_weblogic.md
    ├── 05-oracle_patch_weblogic.md
    ├── 06-oracle_install_forms_reports.md
    ├── 06-oracle_patch_forms_reports.md
    ├── 07-oracle_setup_repository.md
    ├── 08-oracle_setup_domain.md
    ├── 09-oracle_configure.md
    ├── 10-oracle_boot_properties.md   ← 10-oracle_boot_properties.sh
    ├── 11-oracle_nodemanager.md       ← 11-oracle_nodemanager.sh
    ├── 12-weblogic-report-monitoring_user.md  ← 12-oracle_reports_users.sh
    ├── 13-reports-detail-settings.md ← 13-root_reports_fix.sh + 13-oracle_setup_reports.sh
    ├── 14-forms-detail-settings.md   ← 14-oracle_setup_forms.sh
    ├── 14b-oracle_reports_fonts.md   ← 14b-oracle_reports_fonts.sh
    ├── 80-oracle_security.md         ← post-install hardening checklist + password recovery
    ├── 81-reports_rwservlet_security.md ← Reports web commands / <identifier> / webcommandaccess (tests A–D done 2026-10-23)
    ├── 90-oracle_validate.md         ← 90-oracle_validate.sh [planned]
    ├── 20-forms_reports_testmodules.md ← 15-deploy-test-report-forms_template.sh (verified 2026-10-16)
    ├── 30-configure_autostart.md     ← 30-configure_autostart.sh
    ├── 40-forms_client_distribution.md ← 40-oracle_forms_client_bundle.sh + Windows installer
    └── 99-oracle_deinstall_fmw.md    ← 99-oracle_deinstall_fmw.sh
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

---

## 12. References

- **Oracle FMW 14.1.2 – System Requirements and Specifications (PDF):**
  https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/sysrs/system-requirements-and-specifications.pdf
  *(Authoritative source for hardware, OS, DB, and JDK requirements — to be analysed in detail during final validation.)*

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
