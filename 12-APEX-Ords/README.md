# 12-APEX-Ords – Oracle APEX and ORDS beside Oracle Forms

Installation of **Oracle APEX 26.2** with **ORDS 26.x in standalone (Jetty)
mode** behind the Nginx of this library – scripts `01-` … `06-` (section 5),
the manual procedure stays as the reference (section 5a).

**Status:** live on the test host since 2026-10-23 (APEX 26.2 + ORDS 26.3,
workspace + application tested through Nginx). Sources: the author's wiki
guide (APEX / ORDS 26.1 standalone + Nginx on OL9) and a real customer
upgrade (ORDS 23 → 26.3, APEX 23 → 26.2, Tomcat removed, October 2026 –
anonymised).

---

## 1. Why APEX beside Forms

A modern Forms environment is Forms **and** APEX on the same database
([root README, Target Picture](../README.md#target-picture--forms-and-apex-side-by-side)):

| Use | Tool |
|---|---|
| case processing, the proven PL/SQL logic, power users | Oracle Forms 14.1.2 |
| data capture, self-service, occasional users, mobile | Oracle APEX 26.2 |
| reporting for everyone (dashboards, interactive reports) | Oracle APEX (+ Oracle Reports for print) |

```
   browser / FSAL
        |  HTTPS – one host name, one certificate
   +--- Nginx -------------------------------------------------------------------+
   |  /forms /reports        /ords  /i/                /ords_2  /i_2/               |
   +----|--------------------|------|--------------------|-------|------------------+
        v                    v      v                    v       v
   WLS_FORMS / WLS_REPORTS   ords_1 /srv/apex/apex_1     ords_2  /srv/apex/apex_2
   127.0.0.1:9001/9002       127.0.0.1:8081              127.0.0.1:8082
        |                    |                           |
        +---- DB A (Forms schema + APEX) ----+           DB B (other APEX)
```

---

## 2. Rules of this layout

1. **ORDS in standalone mode** (embedded Jetty) – no Tomcat, no WebLogic
   deployment. Started by systemd, listens on `127.0.0.1` only, Nginx is the
   only door (same rule as the rest of the domain,
   [clone_golden_image.md](../80-FMW-Architecture/clone_golden_image.md)).
2. **One ORDS per database.** A second database gets its own ORDS home
   (`ords_2`), its own URL (`/ords_2`) and may run another ORDS / APEX
   version.
3. **Software versioned, homes linked:** the ORDS zip is unpacked per version
   (`ords-26.3.0`), each home links to the version it runs (`ords_1/ords`).
   Upgrade = new directory + new link, rollback = old link.
4. **The ORDS config directory holds nothing but the config.** ORDS reads
   every file under it, whatever the extension – no backups, no notes, no
   `*.bak` there (customer finding). Backups go to `07-Maintenance/ConfigBackup/`.
5. **APEX images are a copy under `/srv`** (security): the APEX zip with its
   SQL stays private under `$ORACLE_BASE`; Nginx only reads
   `/srv/apex/APEX_<version>` through the link `/srv/apex/apex_N` of its ORDS. Nginx
   never needs access to `$ORACLE_BASE`.
6. **Every APEX installation has its own image prefix** (`/i/` for DB A,
   `/i_2/` for DB B) – two APEX versions live side by side.
7. **Java = `JDK_HOME`** (Oracle JDK 21 of this library, patched by
   `07-Maintenance/80-patch_java_os.sh`; free when used with Oracle
   products, Doc ID 1557737.1).
8. **Oracle Net = `TNS_ADMIN`** of `environment.conf` – ORDS connects with a
   TNS alias from the one Oracle Net directory.

---

## 3. Directory layout and instances

```
$ORACLE_BASE/product/ords/
  ords-26.3.0/                 unpacked ORDS zip, one directory per version
  ords_1/
    ords -> ../ords-26.3.0     software link of this ORDS
    config/                    ORDS config of ords_1 (databases/, global/) - nothing else
  ords_2/
    ords -> ../ords-<ver>
    config/
$ORACLE_BASE/product/apex/
  APEX_26.2/apex/...           unpacked apex_26.2.zip (installer, SQL) - private
/srv/apex/                     web root for Nginx only (oracle:oinstall, 755 / 644)
  APEX_26.2/                   copy of APEX_26.2/apex/images
  apex_1 -> APEX_26.2          images of ords_1 (link inside /srv/apex, no root)
  apex_2 -> APEX_<ver>         images of ords_2
/var/log/ords_1/, /var/log/ords_2/     ORDS access + server log, systemd stdout/stderr
```

| Instance | URL context | Listener | Images | APEX `IMAGE_PREFIX` | Database |
|---|---|---|---|---|---|
| `ords_1` | `/ords` | `127.0.0.1:8081` | `/i/` → `/srv/apex/apex_1/` | `/i/` | DB A (TNS alias, e.g. the Forms PDB) |
| `ords_2` | `/ords_2` | `127.0.0.1:8082` | `/i_2/` → `/srv/apex/apex_2/` | `/i_2/` | DB B |

Ports 8081 / 8082 are free next to WebLogic (7001, 9001, 9002) and the Node
Manager (5556). In the steps below `N` = 1 or 2, shown for `ords_1`.

---

## 4. Prerequisites

| Item | Value |
|---|---|
| APEX | 26.2 (released 2026-10-06), `apex_26.2.zip` + language packs inside |
| ORDS | 26.x – **ORDS version ≥ APEX version** (documented for APEX 26.1: older ORDS releases do not work with it) |
| Java | Java 21 at `JDK_HOME` |
| Database | 19c or 26ai, PDB; APEX 26.2 is supported on both |
| DB sizing | `processes` ≥ Σ `jdbc.MaxLimit` of all ORDS on this DB + 50–100, `sessions` ≈ processes × 1.1 (else `ORA-00020`) |
| Nginx | from `09-Install/04-root_nginx.sh` (TLS, one host name) |
| Accounts | SYS of the PDB (once, for the installers) |

**Downloads – `09-Install/04-oracle_pre_download.sh --apply`** (with
`INSTALL_APEX=true`): the OTN "latest" ZIPs, version read from the ZIP,
stored per version; with `--mos` also the APEX patch set bundle
(`APEX_PATCH_NR`, platform Generic `2000P`) – see
[docs/04](../09-Install/docs/04-oracle_pre_download.md):

```
$PATCH_STORAGE/apex/26.2/apex_26.2.zip                       (SHA-256 = download page, checked 2026-10-23)
$PATCH_STORAGE/apex/26.2/patch/<APEX_PATCH_NR>/p<nr>_262_Generic.zip
$PATCH_STORAGE/ords/26.3.0.272.1811/ords-26.3.0.272.1811.zip
```

**Values – `environment.conf`** (interview block 4b,
[docs/01](../09-Install/docs/01-setup-interview.md)):

| Variable | Used here as |
|---|---|
| `INSTALL_APEX` | `true` = this page applies |
| `APEX_ORDS_BASE` | `$ORACLE_BASE/product/ords` (section 3) |
| `APEX_SW_BASE` | `$ORACLE_BASE/product/apex` |
| `APEX_WEB_DIR` | `/srv/apex` |
| `ORDS_1_DB_ALIAS` / `_PORT` / `_CONTEXT` / `_IMAGE_PREFIX` | `<PDB_ALIAS_1>`, `8081`, `/ords`, `/i/` (ords_2: `ORDS_2_*` by hand) |
| `ORDS_JAVA_HEAP` | `-Xms` = `-Xmx` in the systemd unit |
| `APEX_TABLESPACE`, `APEX_LANGUAGES` | `apexins.sql`, `load_<lang>.sql` |
| `apex_sec.conf.des3` | `APEX_ADMIN_USER`, `APEX_ADMIN_PWD`, `APEX_REST_PUBLIC_PWD` – generated by `02-install-apex.sh` if missing |

Background: [apex_architecture.md](../80-FMW-Architecture/apex_architecture.md)
(request path, ORDS config directory, proxy right, REST / OAuth2).

---

## 5. Installation

**Scripts** (all live-tested on the test host 2026-10-23 except the real
patch runs of `03-` / `06-`, which need the next APEX patch / ORDS release;
the manual steps in §5a stay as the reference). Every script is read-only
without `--apply`; `--instance N` selects `ords_N`. Shared functions:
`apex_ords_lib.sh`, templates in `templates/`, the DB profile in
`apex_user_profile.sql`.

| Step | Script | What |
|---|---|---|
| 0 | `00-Setup/install_db_client_tools.sh --apply` | Instant Client 23.26 (`sqlplus`, tools) + SQLcl – SQL\*Plus for the APEX installer, SQLcl for `apex export` / `rest export` |
| 0 | `09-Install/04-oracle_pre_download.sh --apply [--mos]` | APEX / ORDS ZIPs, APEX patch |
| 0 | `09-Install/03-root_user_oracle.sh --apply` (root) | creates `APEX_WEB_DIR` (`/srv/apex`, owner oracle) |
| 1 | `12-APEX-Ords/01-prepare-database.sh [--apply]` | PDB check, APEX already installed (version, tablespace), tablespace for APEX **and** `ORDS_METADATA`, temp tablespace, DB profile `APEX_USER` (no expiry / lock-out) for the runtime accounts |
| 2 | `12-APEX-Ords/02-install-apex.sh [--apply]` | new installation **or release upgrade**: unpack, `apexins.sql`, ADMIN, `apex_rest_config.sql`, profile, language packs, images to `/srv/apex/APEX_<ver>` + link `apex_1` |
| 3 | `12-APEX-Ords/03-patch-apex.sh [--apply]` | APEX patch set bundle (`APEX_PATCH_NR`): ORDS stop, `catpatch.sql`, ORDS start, images to `/srv/apex/APEX_<ver>_p<nr>` + link switch (rollback = link back) |
| 4 | `12-APEX-Ords/04-install-ords.sh [--apply]` | ORDS software `ords-<ver>` + home `ords_1` (config 700), `ords install` non-interactive (repository in the APEX tablespace, risky features off), `config set` with key check, systemd `ords@.service`, loopback check |
| 5 | `12-APEX-Ords/05-setup-nginx.sh [--apply]` | `/etc/nginx/oracle-wls.d/ords_1.conf` (`/ords/` + `/i/`), image / `IMAGE_PREFIX` / SELinux checks, `nginx -t` + reload + rollback, HTTPS check |
| 6 | `12-APEX-Ords/06-patch-ords.sh [--apply] [--rollback] [--keep N]` | new ORDS release beside the old one, link switch, repository upgrade (one-way), rollback by link while the repository is unchanged |

## 5a. Installation by hand (reference)

### 5.1 Directories (root)

```bash
mkdir -p $ORACLE_BASE/product/ords $ORACLE_BASE/product/apex
mkdir -p /srv/apex /var/log/ords_1
chown -R oracle:oinstall $ORACLE_BASE/product/ords $ORACLE_BASE/product/apex /srv/apex /var/log/ords_1
chmod 755 /srv/apex
```

### 5.2 Software (oracle)

```bash
# ZIPs from 04-oracle_pre_download.sh (checksum checked there)
OZ=$PATCH_STORAGE/ords/26.3.0.272.1811/ords-26.3.0.272.1811.zip
AZ=$PATCH_STORAGE/apex/26.2/apex_26.2.zip

mkdir $ORACLE_BASE/product/ords/ords-26.3.0
unzip -q $OZ -d $ORACLE_BASE/product/ords/ords-26.3.0
mkdir -p $ORACLE_BASE/product/ords/ords_1/config
ln -sfn ../ords-26.3.0 $ORACLE_BASE/product/ords/ords_1/ords
$ORACLE_BASE/product/ords/ords_1/ords/bin/ords --config $ORACLE_BASE/product/ords/ords_1/config --version

mkdir $ORACLE_BASE/product/apex/APEX_26.2
unzip -q $AZ -d $ORACLE_BASE/product/apex/APEX_26.2

# images: copy for Nginx, link for the ORDS instance
mkdir /srv/apex/APEX_26.2
cp -r $ORACLE_BASE/product/apex/APEX_26.2/apex/images/. /srv/apex/APEX_26.2/
ln -sfn APEX_26.2 /srv/apex/apex_1                  # link inside /srv/apex - no root needed
```

### 5.3 APEX into the database (oracle, SYSDBA in the PDB)

```bash
cd $ORACLE_BASE/product/apex/APEX_26.2/apex
export NLS_LANG=American_America.AL32UTF8
sqlplus sys@<PDB_ALIAS_1> as sysdba
```

Check first (new installation: no row in `dba_registry`; upgrade: the values
of the existing installation are the `apexins.sql` parameters):

```sql
select comp_id, version, status, schema from dba_registry where comp_id = 'APEX';
select property_value from database_properties where property_name = 'DEFAULT_TEMP_TABLESPACE';
select apex_instance_admin.get_parameter('IMAGE_PREFIX') from dual;   -- only if APEX exists
```

Install (own tablespace recommended for production):

```sql
create tablespace apex_data datafile size 500m autoextend on next 100m maxsize 4g;
spool /tmp/install_apex.log
@apexins.sql APEX_DATA APEX_DATA TEMP /i/          -- ords_2 / DB B: /i_2/
@apxchpwd.sql                                       -- INTERNAL admin password
@apex_rest_config.sql                               -- APEX_REST_PUBLIC_USER (static files)
select status from dba_registry where comp_id = 'APEX';   -- VALID
```

**APEX 26.2 accounts** ([apex_architecture.md §2a](../80-FMW-Architecture/apex_architecture.md)):
- `APEX_PUBLIC_USER` stays **without password and locked**. 26.2 creates it without authentication; ORDS reaches it through the proxy right of `ORDS_PUBLIC_USER`. Older guides unlocked it with a password – not needed any more.
- `apex_rest_config.sql` asks for **one** password (`APEX_REST_PUBLIC_USER`, static files of workspaces / apps) – `APEX_LISTENER` no longer exists.
- New: `APEX_PUBLIC_ROUTER` (friendly URLs) – check profile / sessions.

German language pack (optional): `cd builder/de` and `@load_de.sql de`, then
Manage Instance → Instance Settings → Language.

### 5.4 ORDS install (oracle)

```bash
export ORDS_CONFIG=$ORACLE_BASE/product/ords/ords_1/config
cd $ORACLE_BASE/product/ords/ords_1/ords/bin
./ords --config $ORDS_CONFIG install
```

Non-interactive (what `04-install-ords.sh` runs – passwords via stdin in
the order of the user options: SYS, then `ORDS_PUBLIC_USER`; **no**
`--db-pool default`, ORDS 26.3 rejects it):

```bash
./ords --config $ORDS_CONFIG install --admin-user "SYS AS SYSDBA" --proxy-user \
  --db-tns-dir $TNS_ADMIN --db-tns-alias <PDB_ALIAS_1> \
  --schema-tablespace APEX_DATA --schema-temp-tablespace TEMP \
  --proxy-user-tablespace APEX_DATA --proxy-user-temp-tablespace TEMP \
  --gateway-mode proxied --gateway-user APEX_PUBLIC_USER \
  --feature-sdw false --feature-rest-enabled-sql false --feature-db-api false \
  --log-folder /tmp/ords_install --password-stdin <<'PWD'
<SYS password>
<ORDS_PUBLIC_USER password>
PWD
```

Answers: connection type **TNS** – TNS directory `$TNS_ADMIN`, alias
`<PDB_ALIAS_1>`; administrator `SYS`; features as needed (APEX, REST
services; Database Actions only if wanted); **do not start** (systemd does
that). The installer creates `ORDS_METADATA` / `ORDS_PUBLIC_USER` and
writes `config/databases/default/pool.xml`. Its log lands in the current
directory (`./logs`) – keep it outside `config/`.

### 5.5 ORDS settings (oracle)

```bash
O="./ords --config $ORDS_CONFIG config set"
$O standalone.binds 127.0.0.1                    # NOT standalone.http.host – unknown key, accepted silently!
$O standalone.http.port 8081                     # ords_2: 8082
$O standalone.context.path /ords                 # ords_2: /ords_2
$O standalone.access.log /var/log/ords_1
$O cache.metadata.enabled true
$O cache.metadata.timeout 900
$O jdbc.InitialLimit 10
$O jdbc.MinLimit 10
$O jdbc.MaxLimit 50
$O security.externalSessionTrustedOrigins "https://<FQDN>"
$O security.requestValidationFunction ords_util.authorize_plsql_gateway   # APEX 26.2 guide
$O feature.graphql disable_all                   # ORDS default: enabled
./ords --config $ORDS_CONFIG config list         # check
```

No `standalone.static.*` – Nginx serves the images (rule 5).

`$ORDS_CONFIG/global/logging.properties`:

```ini
handlers=java.util.logging.FileHandler
.level=WARNING
java.util.logging.FileHandler.pattern=/var/log/ords_1/ords_sys.log
java.util.logging.FileHandler.formatter=java.util.logging.SimpleFormatter
java.util.logging.SimpleFormatter.format=%1$tY-%1$tm-%1$td %1$tH:%1$tM:%1$tS %4$-6s %2$s %5$s%6$s%n
oracle.dbtools.level=WARNING
```

### 5.6 systemd – one template unit for all instances (root)

`/etc/systemd/system/ords@.service` (`%i` = `ords_1`, `ords_2`; replace
`<ORACLE_BASE>` / `<JDK_HOME>` by the values of `environment.conf`):

```ini
[Unit]
Description=Oracle REST Data Services %i (standalone)
After=network-online.target

[Service]
Type=simple
User=oracle
Group=oinstall
Restart=on-failure
RestartSec=10
StandardOutput=append:/var/log/%i/ords_stdout.log
StandardError=append:/var/log/%i/ords_stderr.log
SyslogIdentifier=%i
Environment=JAVA_HOME=<JDK_HOME>
Environment="_JAVA_OPTIONS=-Xms2G -Xmx2G -XX:+UseG1GC -Djava.util.logging.config.file=<ORACLE_BASE>/product/ords/%i/config/global/logging.properties"
ExecStart=<ORACLE_BASE>/product/ords/%i/ords/bin/ords --config <ORACLE_BASE>/product/ords/%i/config serve
ExecStop=/bin/kill -TERM $MAINPID

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now ords@ords_1
systemctl status ords@ords_1
```

Heap: dev 1–2 GB, test 2–4 GB, production ≥ 4 GB, `-Xms` = `-Xmx`.

### 5.7 Nginx (root)

Own file per instance, `/etc/nginx/oracle-wls.d/ords_1.conf` – included
**inside the 443 server block** of `/etc/nginx/conf.d/oracle-wls.conf`
(`include /etc/nginx/oracle-wls.d/*.conf;`, `09-Install/nginx-wls.conf.template`
since 2026-10-23). `05-setup-nginx.sh` renders it from
`templates/nginx-ords.conf.template`:

```nginx
location /ords/ {
    proxy_pass         http://127.0.0.1:8081/ords/;
    proxy_set_header   Host              $host;
    # client IP for APEX / owa_util: OVERWRITE, never append (see below)
    proxy_set_header   X-Forwarded-For   $remote_addr;
    proxy_set_header   X-Real-IP         $remote_addr;
    proxy_set_header   X-Forwarded-Proto https;
    proxy_set_header   X-Forwarded-Port  443;
    proxy_set_header   X-Forwarded-Host  $host;
    proxy_connect_timeout 60s;
    proxy_read_timeout    300s;
    proxy_send_timeout    300s;
    proxy_buffer_size       128k;
    proxy_buffers           4 256k;
    proxy_busy_buffers_size 256k;
}
location /i/ {
    alias   /srv/apex/apex_1/;
    expires 7d;
    access_log off;
}
# second instance: /ords_2/ -> 127.0.0.1:8082/ords_2/, /i_2/ -> /srv/apex/apex_2/
```

**Client IP to PL/SQL (customer finding, October 2026):** with Apache the
fix was `ProxyAddHeaders Off` plus `RequestHeader set X-Forwarded-For
"expr=%{REMOTE_ADDR}"`. The header must be **overwritten** with the real
client address. If it is appended, APEX / `owa_util.get_cgi_env('REMOTE_ADDR')`
get the wrong value, and a client can forge its address by sending its own
`X-Forwarded-For`. In Nginx that means `$remote_addr`, **not**
`$proxy_add_x_forwarded_for`, which appends to the value the client sent.
(Our common WebLogic headers in the template still use
`$proxy_add_x_forwarded_for` – open item, section 9.)

```bash
nginx -t && systemctl reload nginx
```

SELinux enforcing (customer hosts; not on the test host):
`semanage fcontext -a -t httpd_sys_content_t "/srv/apex(/.*)?"; restorecon -Rv /srv/apex`
and `setsebool -P httpd_can_network_connect 1`.

### 5.8 Verification

```bash
ss -ltnp | grep 808                                         # 127.0.0.1:8081 only
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/ords/_/landing
curl -sk https://<FQDN>/i/apex_version.txt                  # 26.2
curl -sk -o /dev/null -w '%{http_code}\n' https://<FQDN>/ords/apex
```

- Browser: `https://<FQDN>/ords/apex` – workspace `INTERNAL`, user `ADMIN`.
- Client IP: in an APEX page or with `owa_util.get_cgi_env('REMOTE_ADDR')`
  the real client address. A request with a forged
  `-H 'X-Forwarded-For: 1.2.3.4'` must **not** show 1.2.3.4.
- Reboot test: `systemctl is-enabled ords@ords_1 nginx` → `enabled`, after the
  reboot APEX answers again.

---

## 6. Upgrade (ORDS and APEX) – and the second version

From the customer upgrade, generic:

1. **ORDS:**
   - unpack the new zip into `ords-<new>`;
   - `systemctl stop ords@ords_1`;
   - `ln -sfn ../ords-<new> ords_1/ords`;
   - `ords --config … install`, select the existing pool – this **upgrades** the ORDS repository (customer: 23.3 → 26.3 in 30 s);
   - `config list`, start.
2. **APEX:**
   - unpack into `APEX_<new>`;
   - stop ORDS (downtime);
   - `@apexins.sql` with the parameters of the check query (tablespaces, temp, image prefix);
   - language packs again;
   - copy the images to `/srv/apex/APEX_<new>`, `ln -sfn` `/srv/apex/apex_1`;
   - start, check `/i/apex_version.txt`.
3. **Clean-up only after acceptance:**
   - drop the old `APEX_2x0x00` schema (check `dba_registry` first);
   - remove the old ORDS / APEX directories;
   - check for invalid objects.
4. **Rollback before the clean-up:** switch the links back – but only as long as the database part was not upgraded (`apexins.sql` / ORDS repository are one-way – a database backup is needed before).

---

## 7. Operations and pitfalls

| Topic | Note |
|---|---|
| Log rotation | ORDS rotates its own logs (access log, `logging.properties` handler). Only the systemd stdout / stderr files need a small logrotate rule (`copytruncate`, weekly) – they normally stay almost empty and only grow on errors |
| HTTP 502 | ORDS not running or not on `127.0.0.1:8081` – `journalctl -u ords@ords_1` |
| ORDS does not start | wrong `JAVA_HOME`, DB listener not reachable, wrong `--config` path, foreign files in `config/` |
| `OutOfMemoryError` | raise `-Xmx` in the unit |
| Locked / expired users | `ORDS_PUBLIC_USER`, `APEX_REST_PUBLIC_USER`, `APEX_PUBLIC_ROUTER`, `APEX_PUBLIC_USER` – profile `APEX_USER` (no expiry / lock-out) by `01-` / `02-` / `04-`; check: `01-prepare-database.sh` (without the profile `APEX_REST_PUBLIC_USER` expired after 180 days) |
| `ORA-00020` / `ORA-00018` | `processes` / `sessions` too small for the pools |
| REST definitions lost | never `DELETE` in `ORDS_METADATA` by hand (`ON DELETE CASCADE` – whole interfaces vanish at once); export existing REST interfaces before every change and before every ORDS upgrade – [apex_architecture.md §2](../80-FMW-Architecture/apex_architecture.md) |
| APEX jobs | `dba_scheduler_jobs` of the APEX schema (mail queue) running? |
| Scripted `apxchpwd.sql` / `apex_rest_config.sql` | their `ACCEPT … HIDE` reads **nothing** from stdin without a TTY: the password arrives empty (`ORA-20001: Invalid password`), the input line then runs as a command and is **echoed in `SP2-0734`** / `Enter value for 2:` – password in the spool. `02-install-apex.sh` therefore calls `create_or_update_admin_user` directly (bind variable, as `apxchpwd` does), sets the REST password again with `ALTER USER` and never spools these steps (live 2026-10-23). Empty stdin lines for "take the default" are skipped as well |
| Broken images | `/srv/apex/apex_1` link and `IMAGE_PREFIX` match? Nginx can read `/srv/apex`? |

---

## 8. Fit with this library

| Area | What applies |
|---|---|
| Loopback / clone | ORDS on `127.0.0.1`; host-specific: `security.externalSessionTrustedOrigins`, Nginx `server_name` – to add to `02-Checks/clone_check.sh` |
| Backup | `ords_N/config` (holds `cwallet.sso` – owner only) into `07-Maintenance/backup_config.sh` – to add |
| Patching | APEX + ORDS + SQLcl as **one set** (APEXlang compiler in ORDS): `03-patch-apex.sh`, `06-patch-ords.sh`, `00-Setup/install_db_client_tools.sh`; cycle in `09-Install/docs/00-patch-references.md` |
| Certificates | Nginx certificate already covered by `10-Monitoring/cert_expiry_check.sh` |
| Java | `JDK_HOME` – the JDK upgrade of `80-` needs an ORDS restart too (`systemctl restart ords@ords_1`) |
| DB accounts | profile `APEX_USER` (`apex_user_profile.sql`) – like `RCU_USER` for the FMW schemas |
| Background | [ords_architecture.md](../80-FMW-Architecture/ords_architecture.md) (Jetty, APEXlang, features + risks, REST / OAuth2) |

---

## 9. Open items

- **Done 2026-10-23:** interview block 4b, `environment.conf`, download in
  `04-`, scripts `01-` … `06-`, `03-` creates `APEX_WEB_DIR`, Nginx include
  directory, live installation APEX 26.2 + ORDS 26.3 on the test host.
- First real run of `03-patch-apex.sh` (next APEX 26.2 patch set bundle) and
  of the upgrade path of `06-patch-ords.sh` (next ORDS release).
- ~~Nginx template: `X-Forwarded-For $remote_addr` also for `/forms` /
  `/reports`~~ – done 2026-10-26 in `09-Install/nginx-wls.conf.template`
  together with stripping the client-supplied WebLogic headers (live-tested).
- `clone_check.sh` / `backup_config.sh` / `cve_inventory.sh` know ORDS and APEX
  (config dir with wallet, versions of APEX / ORDS / SQLcl / Instant Client).
- `01-Run/startStop.sh` / `fmw_ctl.sh` status: show `ords@ords_N` next to the
  FMW components.
- [ ] **`07-check-ords-apex-security.sh`** (read-only check, later
  `--apply` for the safe fixes) – security of what the **applications**
  bring into the APEX / ORDS instance, run after every app installation and
  regularly. Found live 2026-10-23 with workspace `GPI` / schema `GPIDEV`
  ([ords_architecture.md §6.1](../80-FMW-Architecture/ords_architecture.md#61-apex-workspaces-rest-enable-their-schema--with-an-open-catalog)):
  - REST-enabled schemas with **`auto_rest_auth` off** – metadata / OpenAPI
    catalog open without login (`/ords/<alias>/metadata-catalog/`, HTTP
    200); fix: `ords.enable_schema(p_enabled => true, p_schema => '<SCHEMA>',
    p_url_mapping_type => 'BASE_PATH', p_url_mapping_pattern => '<alias>',
    p_auto_rest_auth => true)`;
  - workspace / parsing schemas with profile `DEFAULT` (password expiry) –
    fix: profile `APEX_USER` (`apex_user_profile.sql`);
  - workspace tablespaces `APEX_<number>` created by APEX with maxsize
    100 MB – fill level / maxsize;
  - REST modules without a privilege (public), AutoREST-enabled objects,
    proxy rights of `ORDS_PUBLIC_USER` to schemas without REST modules;
  - instance settings: risky ORDS features on (SDW, REST-enabled SQL, DB
    API, GraphQL), `requestValidationFunction`, `standalone.binds`,
    `httpsHeaderCheck` – the values `04-install-ords.sh` sets, drift check;
  - APEX instance: e.g. `ADMIN` account, workspace provisioning, HTTPS-only
    / session settings (`apex_instance_admin` parameters) – to collect.

---

## 10. Sources

All checked 2026-10-23 (HTTP 200, title matches):

- Gunther Pipperr – Oracle APEX 26.1 with ORDS 26.1 Standalone and NGINX on
  Oracle Linux 9 –
  <https://pipperr.de/dokuwiki/doku.php?id=prog:oracle_apex_26_1_ords_standalone_nginx_ol9>
- Oracle APEX – Downloads (APEX 26.2, release date, supported databases) –
  <https://www.oracle.com/tools/downloads/apex-downloads.html>
- Oracle REST Data Services Download –
  <https://www.oracle.com/database/sqldeveloper/technologies/db-actions/download/>
- ORDS Changelog – <https://www.oracle.com/tools/ords/ords-changelog.html>
- Oracle REST Data Services documentation (releases) –
  <https://docs.oracle.com/en/database/oracle/oracle-rest-data-services/>
- Customer upgrade ORDS 23 → 26.3 / APEX 23 → 26.2, October 2026
  (anonymised; not in the repository).
