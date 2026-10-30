# Step: 01-setup-interview.sh – Configuration Interview

> Certificates, keys and trust stores of the whole stack (terms, where what lives, who needs what, customer PKI / TLS interception): [certificates_trust_stores.md](../../80-FMW-Architecture/certificates_trust_stores.md)

**Script:** `09-Install/01-setup-interview.sh`
**Runs as:** `oracle`
**When:** Before all other installation steps

---

## Purpose

Collect all installation parameters interactively and write them to `environment.conf`.
Prompts only for parameters that are not yet set (idempotent — safe to re-run).
Passwords are encrypted immediately and never written in plaintext.

---

## Without the Script (manual)

1. Copy the `environment.conf` template and fill in all parameters manually:

```bash
cp environment.conf.template environment.conf
vi environment.conf
```

2. Encrypt WebLogic admin password:

```bash
# Store in weblogic_sec.conf, then encrypt:
./00-Setup/weblogic_sec.sh
```

3. Encrypt MOS password:

```bash
SYSTEMIDENTIFIER=$(ls -l /dev/disk/by-uuid/ | awk '{ print $9 }' | tail -1)
echo "MOS_PASSWORD=<your-mos-password>" > mos_sec.conf
openssl des3 -pbkdf2 -salt -in mos_sec.conf \
    -out mos_sec.conf.des3 -pass pass:"${SYSTEMIDENTIFIER}"
rm mos_sec.conf
```

4. Verify all required parameters are set before proceeding to the next step.

---

## What the Script Does

- Reads existing `environment.conf` (skip already-set parameters)
- Prompts interactively for each missing parameter with a sensible default
- Validates input immediately (directory exists, port is numeric, etc.)
- Encrypts all passwords via the same mechanism as `00-Setup/weblogic_sec.sh`
- Writes a reusable `setup.conf` template (passwords stripped) for subsequent installs
- Shows a summary of all values and asks for confirmation before writing
- Writes the values to `00-Setup/environments/<basename DOMAIN_HOME>.conf` and
  points the `environment.conf` symlink at it – the same layout `00-Setup/init_env.sh`
  uses later. If `environment.conf` is already a symlink, its target is updated;
  a legacy plain `environment.conf` is moved there first. (A plain file would
  otherwise be replaced by `init_env.sh`'s symlink and all interview values lost.)
- Replaces an existing `# === 09-INSTALL` block on every `--apply` instead of
  appending a second one; values outside the block (e.g. the `init_env.sh`
  runtime section) are preserved
- Block 4 asks for `LOCAL_REP_DB` (Oracle DB on this host?) with a detected
  default: `true` if an `ora_pmon_*` process runs or `DB_HOST` is a local
  address. Must be `true` on a shared FMW+DB host – with `false`,
  `01-root_os_baseline.sh` comments out the DB's shm/sysctl values

---

## Interview Blocks

### Block 1 – Directories & Homes

| Parameter | Default | Validation |
|---|---|---|
| `ORACLE_BASE` | `/u01/app/oracle` | directory writable |
| `ORACLE_HOME` | `$ORACLE_BASE/fmw` | will be created if absent |
| `JDK_HOME` | `$ORACLE_BASE/java/jdk-21` | `java -version` check |
| `DOMAIN_HOME` | `$ORACLE_BASE/domains/fr_domain` | – |
| `PATCH_STORAGE` | `/srv/patch_storage` | disk space ≥ 20 GB |
| `PATCH_ARCHIVE` | *(empty = none)* | optional NFS/ZFS master copy of installers + patches (same layout); readable directory, not `PATCH_STORAGE` – `07-Maintenance/patch_storage.sh pull/clean` |
| `ORACLE_INVENTORY` | one level above `ORACLE_BASE` (`/opt/oraInventory` when `ORACLE_BASE` has depth 1) | WARN if inside `ORACLE_BASE`; on a host with an existing inventory (local RCU DB, reinstall) enter that one – `03-` writes `/etc/oraInst.loc` |
| `IHW_ENV_TYPE` | `prod` | `test` or `prod` – `prod` = Claude Code is never used on this host; `test` = allowed with sandbox + guard hook ([10-Monitoring/setup_claude.md](../../10-Monitoring/setup_claude.md)) |
| `TNS_ADMIN` | `$ORACLE_BASE/admin/tns_names` | **one** Oracle Net directory (`tnsnames.ora`, `sqlnet.ora`) for Forms, Reports, WebLogic and the oracle shell – written into `default.env` (14-), `rwserver.conf` + `reports.sh` (13-), `setUserOverrides.sh` + checked by [tns_admin_check.sh](../../02-Checks/README.md#tns_admin_checksh), `.bash_profile` (03-) |

### Block 2 – Component Selection

```
What should be installed?
  [1] Forms and Reports (default)
  [2] Forms only
  [3] Reports only
```

Sets `INSTALL_COMPONENTS=FORMS_AND_REPORTS | FORMS_ONLY | REPORTS_ONLY`

### Block 3 – Domain Configuration

| Parameter | Default | Notes |
|---|---|---|
| `WLS_SERVER_FQDN` | `hostname -f` | **Public** server name (URL of the users, certificate SAN) – Nginx `server_name`, 08-SSL, default of `FORMS_CLIENT_BASE_URL` / `ORDS_PUBLIC_URL`. Cloud host / DNS alias: enter the alias (`forms.company.com`), not the `…oraclevcn.com` host name. Asked first in Block 3 (before 2026-10-29 never asked – phase-0 scripts fell back to `hostname -f`) |
| `WLS_ADMIN_PORT` | `7001` | – |
| `WLS_ADMIN_USER` | `webadmin` | – |
| `WLS_ADMIN_PWD` | prompted, encrypted → `weblogic_sec.conf.des3` | – |
| `WLS_NODEMANAGER_PORT` | `5556` | – |
| `WLS_FORMS_PORT` | `9001` | – |
| `WLS_REPORTS_PORT` | `9002` | – |
| `WLS_LISTEN_ADDRESS` | `localhost` | see below |
| `REPORTS_SERVER_NAME` | `repserver01` | – |
| `FORMS_CUSTOMER_DIR` | `${ORACLE_BASE}/forms/moduls` | Forms modules (`.fmx`/`.fmb`), first entry of `FORMS_PATH` (14- creates it) |
| `FORMS_TMP` | `${ORACLE_BASE}/forms/tmp` | `TMPDIR` of the Forms runtime in `default.env` (14- creates it) |
| `REPORTS_CUSTOMER_DIR` | `${ORACLE_BASE}/reports/source` | – |
| `REPORTS_IMAGE_DIR` | `${ORACLE_BASE}/reports/images` | images of the reports (Link File / Read from File) |
| `REPORTS_SECURITY` | `ldap` (Reports installs; else `identifier`) | menu: `ldap` = secured Reports server via WebLogic embedded LDAP, `identifier` = not secured (13- Step 5a) |
| `REPORTS_ADMIN_USER` | `rep_admin` (Reports installs) | Reports server admin = `rwserver.conf` `<identifier>` (not a WebLogic user) |
| `REPORTS_ADMIN_PWD` | prompted, encrypted → `reports_admin_sec.conf.des3` | letters/digits only; 13- writes it into `<identifier>` |
| `EMBEDDED_LDAP_PWD` | only with `ldap`: prompted, encrypted → `embedded_ldap_sec.conf.des3` | password of the embedded LDAP admin `cn=Admin` (letters/digits); 13- sets it in the domain |
| `EXPECTED_SESSIONS` | `lt100` | see below – sizes `ULIMIT_NOFILE`/`ULIMIT_NPROC` |

#### Forms WebUtil OLE (JACOB), client distribution and code signing – Forms installs only

Asked only for `FORMS_AND_REPORTS` / `FORMS_ONLY` – a Reports-only
installation gets none of these questions. Background:
`docs/14-forms-detail-settings.md` Step 1, `08-SSL/README.md` section
"ssl_local_ca.sh", client distribution: `docs/40-forms_client_distribution.md`.

```
FORMS_WEBUTIL_JACOB  [1] No (default)  [2] Yes
FORMS_CLIENT_DIST    [1] No (default)  [2] Yes   (Forms client via URL, concept 40)
        │ Yes → FORMS_CLIENT_DIR, _URL_PATH, _BASE_URL, _CONFIG, _FORM,
        │       _APP_NAME, _RUNTIME, _TRUST_CA   (table below)
        │
        │ JACOB = Yes  or  CLIENT_DIST = Yes   (keystore signs jacob.jar
        ▼                                        and the client setup script)
FORMS_SIGN_KEYSTORE  (default $SSL_CA_DIR/codesign/codesign.p12)
FORMS_SIGN_ALIAS     (default forms_codesign)
        │
        ├── file exists  (company CA / public CA / earlier local CA)
        │     password → forms_sign_sec.conf.des3
        │     check now: keystore opens + alias present
        │     (typed password: 3 attempts, a wrong one is not saved)
        │     FORMS_SIGN_LOCALCA=false
        │
        └── file missing → created later by 14- with the own root CA
              SSL_ORG, SSL_COUNTRY, SSL_CA_CN (only if no root yet),
              SSL_CODESIGN_CN, SSL_CODESIGN_DAYS  → 08-SSL/ssl.conf
              password generated by ssl_local_ca.sh (des3)
              FORMS_SIGN_LOCALCA=true
        ▼
FORMS_SIGN_TSA_URL   (default http://timestamp.digicert.com, Enter on an
                      empty value = no timestamp – not for production)
```

| Parameter | Default | Notes |
|---|---|---|
| `FORMS_MAX_RUNTIME_PROCESSES` | proposal: ½ RAM / 64 MB, tens, ≥ 20 | `formsweb.cfg` `[default]` `maxRuntimeProcesses` – session limit (Oracle: 0 = no limit = DoS risk); 14- writes it |
| `FORMS_WEBUTIL_JACOB` | `false` | menu; `true` = 04- downloads, 14- installs + signs JACOB |
| `SSL_CERT_SOURCE` (→ `08-SSL/ssl.conf`, asked always) | `localca` | `localca` = own root CA of this library; `customer` = customer PKI – files in `08-SSL/user_certs/`, imported by `08-SSL/ssl_customer_certs.sh --apply`; changes the keystore / client-CA defaults below to `$SSL_CA_DIR/customer/` and never creates a local CA |
| `FORMS_SIGN_KEYSTORE` | `${SSL_CA_DIR:-$ORACLE_BASE/admin/pki}/codesign/codesign.p12` (customer: `…/customer/codesign.p12`) | PKCS12 with key + code-signing certificate + chain |
| `FORMS_SIGN_ALIAS` | `forms_codesign` | alias (friendly name) of the key in the keystore |
| `FORMS_SIGN_STOREPASS` | only if the keystore exists: prompted, encrypted → `forms_sign_sec.conf.des3` | checked against the keystore with `openssl pkcs12` |
| `FORMS_SIGN_LOCALCA` | set by the interview | `true` = keystore did not exist; `14- --apply` runs `08-SSL/ssl_local_ca.sh init` (only without root) + `codesign` |
| `SSL_ORG`, `SSL_COUNTRY`, `SSL_CA_CN`, `SSL_CODESIGN_CN`, `SSL_CODESIGN_DAYS` | `Company GmbH`, `DE`, `<org> Root CA`, `<org> Forms Code Signing`, `1095` | only if the keystore is missing; written into `08-SSL/ssl.conf` (key replaced or appended, backup first) – the SSL module's own config, also used later by `ssl_prepare_cert.sh` |
| `FORMS_SIGN_TSA_URL` | `http://timestamp.digicert.com` | `jarsigner -tsa`; needs outbound HTTP from the server |

Client distribution (`docs/40-forms_client_distribution.md` §3.0, bundle
built by `40-oracle_forms_client_bundle.sh`):

| Parameter | Default | Notes |
|---|---|---|
| `FORMS_CLIENT_DIST` | `false` | menu; `true` = the following values are asked, `03-` creates `FORMS_CLIENT_DIR` |
| `FORMS_CLIENT_DIR` | `/srv/formsWeb` | bundle directory served by Nginx (owner oracle, created by root in `03-`) |
| `FORMS_CLIENT_URL_PATH` | `/formsWeb` | Nginx location; must start with `/`, no trailing `/`, not `/forms` |
| `FORMS_CLIENT_BASE_URL` | `https://$WLS_SERVER_FQDN` | URL the clients use (DNS alias possible, must match the TLS certificate) |
| `FORMS_CLIENT_CONFIG` | `standaloneapp` | `formsweb.cfg` section for FSAL |
| `FORMS_CLIENT_FORM` | empty | optional start form |
| `FORMS_CLIENT_APP_NAME` | `Oracle Forms` | shortcut name |
| `FORMS_CLIENT_ICON` | `$PATCH_STORAGE/icon/IHateWeblogic.ico` (project logo, copied there by `04-` from `forms_templates/`) | shortcut icon: `.ico`, or `.png` up to 256 × 256 (wrapped into an ICO by `40-`); a local path or an `http(s)` URL – a URL is downloaded by `04-` into `$PATCH_STORAGE/icon/`; empty = Windows default icon |
| `FORMS_CLIENT_RUNTIME` | `jlink` | menu: `jlink` (slim runtime) / `jdk` (full JDK) |
| `FORMS_CLIENT_TRUST_CA` | `$SSL_CA_DIR/ca/ca.crt` if present, else empty | CA for the bundled runtime's truststore; empty = public CA |

The client JDK patch / platform are software versions →
`download/patches_fmw.csv` (role `client_jdk` = `CLIENT_JDK_PATCH_NR`, `CLIENT_JDK_PLATFORM`).

A root CA created by 14- must be distributed to the clients (`ca.cer`) –
and should be the same root that signs the Nginx TLS certificate
(`08-SSL/ssl_prepare_cert.sh LOCALCA`), so that the clients need one root
only.

#### EXPECTED_SESSIONS

Sizes the `nofile`/`nproc` OS limits for the `oracle` user
(`09-Install/03-root_user_oracle.sh`) to the expected number of concurrent
Forms/Reports sessions.

```
[1] < 100 sessions        – nofile/nproc 65536/16384 (current project minimum)
[2] 100-500 sessions      – nofile/nproc 81920/81920
                             confirmed real production value (reference host "gpiwls01")
[3] 500-1000 sessions     – nofile/nproc ~131072/~131072
                             linear estimate — NOT independently confirmed
[4] > 1000 sessions       – nofile/nproc ~262144/~262144
                             LOWEST confidence: a cautious doubling of the
                             500-1000 estimate, not a measurement or even a
                             careful linear estimate — verify via your own
                             capacity planning / load testing
```

> Only the 100-500 tier is backed by a real production system. The other
> tiers are plausible estimates, not validated numbers — see
> `09-Install/docs/00-root_set_os_parameter.md` for the full rationale and
> the related sysctl kernel parameters sized from the same reference host.
> Each `frmweb` process (one per active Forms session) also needs roughly
> 30-80 MB RAM — factor `expected sessions × ~50 MB` into host sizing on
> top of the WebLogic JVM heaps, see `09-Install/README.md` §9.1.

#### WLS_LISTEN_ADDRESS

Determines which network interface WebLogic (Admin Server and all Managed Servers) binds to.

```
[1] localhost  – NGINX reverse proxy handles all external access + SSL termination
                 WebLogic is not reachable from outside the host directly.
                 Requires: 09-Install/05-root_nginx_ssl.sh configured and running.
                 → recommended default for this architecture

[2] 0.0.0.0   – all interfaces, WebLogic exposed directly (no reverse proxy)
                 Use only when NGINX is not deployed.

[3] custom     – enter a specific hostname or IP address manually
```

> **Note:** With `localhost`, WebLogic never terminates SSL itself — all certificates
> are managed exclusively in NGINX. This eliminates the need for a WLS keystore and
> avoids the common failure mode of expired certificates inside the WebLogic config.
> See `09-Install/docs/05-root_nginx_ssl.md` for NGINX SSL setup.

### Block 3b – Reports Server Details

The interview itself asks only `REPORTS_SERVER_NAMES` (list, default
`repserver01`; the first one is `REPORTS_SERVER_NAME`), the customer
directories (`FORMS_CUSTOMER_DIR`, `FORMS_TMP`, `REPORTS_CUSTOMER_DIR`,
`REPORTS_IMAGE_DIR`) and `REPORTS_SECURITY`. The values of the table below are
written by **`00-Setup/init_env.sh --apply` after the installation** (Phase 6,
before `13-`) – detected from the domain, otherwise the defaults shown.
Background: [report_engine_architecture.md](../../80-FMW-Architecture/report_engine_architecture.md),
[discovery](../../80-FMW-Architecture/reports_server_discovery_multicast.md).

| Parameter | Default | Notes |
|---|---|---|
| `REPORTS_TOOLS_INSTANCE` | detected (`reptools1` from `08-`), fallback `reptools_ent` | Name of the ReportsTools component instance (exactly one per domain) |
| `REPORTS_SERVER_INSTANCES` | `REPORTS_SERVER_NAMES` of the interview, fallback `repserver_ent` | Space-separated list of ReportsServer instance names (multiple allowed) |
| `REPORTS_PATH` | `<REPORTS_CUSTOMER_DIR>:<REPORTS_IMAGE_DIR>` | report sources + images, `:`-separated (13- writes `<folderAccess><read>` with `;`) |
| `REPORTS_TMP` | `${ORACLE_BASE}/reports/tmp` | writable output directory (accessible by Reports engines; not `/tmp`, cleaned at reboot) – 13- creates all three directories |
| `REPORTS_BROADCAST_PORT` | `14027` | UDP broadcast port – must be **unique per environment in the subnet** (range 14021–14030, Doc ID 437228.1) |
| `REPORTS_ENGINE_INIT` | `2` | `rwserver.conf`: initial number of engine processes at startup |
| `REPORTS_ENGINE_MAX` | `5` | `rwserver.conf`: maximum concurrent engine processes |
| `REPORTS_ENGINE_MIN` | `2` | `rwserver.conf`: minimum engine processes kept alive |
| `REPORTS_ENGINE_LIFE` | `50` | `rwserver.conf`: `engLife` – jobs per engine before it is replaced |
| `REPORTS_ENGINE_MAX_IDLE` | *(empty)* | `rwserver.conf`: `maxIdle` (minutes) – empty = not written, Oracle default 30 |
| `REPORTS_ENGINE_JVM_OPTIONS` | *(empty)* | `rwserver.conf`: engine `jvmOptions` (e.g. `-Xmx1g`) – empty = not written, engines run with `-Xmx256M`; no `" & < >` |
| `REPORTS_ENGINE_RESPONSE_TIMEOUT` | `30` | `rwserver.conf`: `engineResponseTimeOut` (minutes) – hanging engine is killed; set to the longest report run time (measured by `05-ReportsPerformance/engine_perf_analyse.sh`) |
| `REPORTS_MAX_CONNECT` | `300` | `rwserver.conf`: max simultaneous client connections |
| `REPORTS_MAX_QUEUE` | `4000` | `rwserver.conf`: max requests queued |
| `REPORTS_COOKIE_KEY` | *(generated)* | `rwservlet.properties` cookie encryption key – generated once, keep stable |

#### Broadcasting Port Assignment

The broadcast port is subnet-wide: **all Reports Servers in the same subnet that share a port will see each other.**
Each `environment.conf` file represents one environment, so the port is automatically isolated when using separate conf files.

Recommended allocation (align with Doc ID 437228.1):

| Port | Environment |
|---|---|
| `14027` | FMW 14.1.2.0.0 Production |
| `14028` | FMW 14.1.2.0.0 Standby / DR |
| `14025` | Test / QA |
| `14021` | Development |

#### Multiple Reports Server Instances

`REPORTS_SERVER_INSTANCES` is a space-separated string — each name becomes a separate
`ReportsServerComponent/<name>/` directory in the domain:

```bash
REPORTS_SERVER_INSTANCES="repserver_ent repserver_batch"
```

Scripts iterate with:
```bash
for inst in $REPORTS_SERVER_INSTANCES; do
    # configure $DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent/$inst/
done
```

---

### Block 4 – Database (RCU)

| Parameter | Default |
|---|---|
| `DB_HOST` | – |
| `DB_PORT` | `1521` |
| `DB_SERVICE` | – |
| `DB_SCHEMA_PREFIX` | `DEV` |
| DB SYS password | prompted, encrypted → `db_sys_sec.conf.des3` (with the schema password), used by RCU (`07-`) |
| `LOCAL_REP_DB` | detected (`ora_pmon_*` running or `DB_HOST` local) |
| `RCU_TABLESPACE` | empty – RCU creates its own tablespaces |
| `RCU_TEMP_TABLESPACE` | `TEMP` |
| `RCU_DB_TYPE` | `EBR` (editions enabled, default) or `ORACLE` |

Background – which schemas RCU creates, who logs in, password expiry:
[rcu_middleware_architecture.md](../../80-FMW-Architecture/rcu_middleware_architecture.md).

Immediate connection test via `02-Checks/db_connect_check.sh` after entry.

### Block 4b – APEX / ORDS (optional)

Oracle APEX + ORDS standalone beside Forms
([`12-APEX-Ords/README.md`](../../12-APEX-Ords/README.md)). The menu comes
first; everything else is asked only with `INSTALL_APEX=true`. Values for
the **first** ORDS instance (`ords_1`); a second one (`ords_2`, other DB) is
added by hand as `ORDS_2_*` in `environment.conf`. Software versions and
download URLs are in `oracle_software_version.conf` (`APEX_*`, `ORDS_*`).

| Parameter | Default | Notes |
|---|---|---|
| `INSTALL_APEX` | `false` | menu; `true` = `04-` downloads APEX / ORDS / the APEX patch, the questions below |
| `APEX_ORDS_BASE` | `$ORACLE_BASE/product/ords` | ORDS software per version (`ords-<ver>`) + homes `ords_1/`, `ords_2/` |
| `APEX_SW_BASE` | `$ORACLE_BASE/product/apex` | unpacked APEX zips `APEX_<ver>` (installer, SQL – private) |
| `APEX_WEB_DIR` | `/srv/apex` | copy of the APEX images per version, read by Nginx (`/srv/apex/apex_1` → `APEX_<ver>`); outside `$ORACLE_BASE` on purpose |
| `ORDS_1_DB_ALIAS` | the alias of `$TNS_ADMIN/tnsnames.ora` with `DB_SERVICE`, else `DB_SERVICE` | TNS alias of the database of `ords_1` (one ORDS per DB) |
| `ORDS_1_PORT` | `8081` | Jetty listener on `127.0.0.1` |
| `ORDS_1_CONTEXT` | `/ords` | URL context = Nginx location |
| `ORDS_1_IMAGE_PREFIX` | `/i/` | APEX `IMAGE_PREFIX` of this DB = Nginx alias to `/srv/apex/apex_1` |
| `ORDS_JAVA_HEAP` | `2G` | `-Xms` = `-Xmx` of every ORDS (dev 1–2 G, prod ≥ 4 G) |
| `APEX_TABLESPACE` | `APEX_DATA` | `apexins.sql` tablespace (created if missing) |
| `APEX_TEMP_TABLESPACE` | *(empty)* | temp tablespace for `apexins.sql`; empty = `DEFAULT_TEMP_TABLESPACE` of the DB (`12-APEX-Ords/01-prepare-database.sh` detects it and writes it back) |
| `APEX_LANGUAGES` | `de` | language packs to load (`builder/<lang>/load_<lang>.sql`), space-separated, empty = English only |
| `APEX_DB_PROFILE` | `APEX_USER` | DB profile without password expiry / lock-out for `ORDS_PUBLIC_USER`, `APEX_PUBLIC_USER`, `APEX_REST_PUBLIC_USER`, `APEX_PUBLIC_ROUTER` – created by `12-APEX-Ords/01-prepare-database.sh` (`apex_user_profile.sql`), assigned by 01 / 02 / 04 |
| `ORDS_PUBLIC_URL` | `https://<WLS_SERVER_FQDN>` | public URL of APEX – ORDS `security.externalSessionTrustedOrigins` (`04-install-ords.sh`) |
| `APEX_ADMIN_EMAIL` | *(empty = `ADMIN`)* | e-mail of the instance administrator `ADMIN` |
| *(not asked)* `ORDS_LOG_BASE` | `/var/log` | ORDS logs in `/var/log/ords_N` |
| *(not asked)* `ORDS_FEATURE_SDW`, `ORDS_FEATURE_REST_SQL`, `ORDS_FEATURE_DB_API`, `ORDS_FEATURE_GRAPHQL` | `false` (GraphQL `disable_all`) | ORDS features Database Actions, REST-enabled SQL, Database API; `ORDS_FEATURE_GRAPHQL` = `disable_all` (ORDS default `enabled`!) – off = smallest attack surface ([ords_architecture.md](../../80-FMW-Architecture/ords_architecture.md)); set to `true` by hand only when needed |
| `APEX_ADMIN_PWD` | prompted, encrypted → `apex_sec.conf.des3` | password of the APEX instance administrator `ADMIN` (`apxchpwd.sql`) – APEX rules: upper/lower case, digit, punctuation |

### Block 5 – My Oracle Support

| Parameter | Default |
|---|---|
| `MOS_USER` | – |
| `MOS_PWD` | prompted, encrypted → `mos_sec.conf.des3` |
| `INSTALL_PATCHES` | comma-separated patch numbers, apply order |

### Block 6 – Summary & Confirmation

Displays all values (passwords shown as `****`).
Asks for confirmation before writing `environment.conf`.

---

## Output Files

| File | Content |
|---|---|
| `environment.conf` | All installation parameters |
| `weblogic_sec.conf.des3` | Encrypted WebLogic admin password |
| `mos_sec.conf.des3` | Encrypted MOS password |
| `reports_admin_sec.conf.des3` | Encrypted Reports server admin (`<identifier>`) user + password |
| `embedded_ldap_sec.conf.des3` | Encrypted embedded LDAP `cn=Admin` password (`REPORTS_SECURITY=ldap`) |
| `forms_sign_sec.conf.des3` | Encrypted code-signing keystore password (existing keystore; otherwise written by `ssl_local_ca.sh`) |
| `08-SSL/ssl.conf` | Local CA subject values (only when the code-signing keystore does not exist yet) |
| `apex_sec.conf.des3` | Encrypted APEX / ORDS passwords (`INSTALL_APEX=true`): `APEX_ADMIN_USER` / `APEX_ADMIN_PWD` (interview), `APEX_REST_PUBLIC_PWD` (`02-install-apex.sh`), `ORDS_1_PUBLIC_PWD` (`04-install-ords.sh`, also in the ORDS wallet) – every writer merges, no key is lost |
| `setup.conf` | Reusable template (no passwords) |

---

## Flags

| Flag | Description |
|---|---|
| `--apply` | Write files (default: show planned values only) |
| `--reset` | Clear all 09-Install parameters and re-run full interview |
| `--help` | Show usage |
