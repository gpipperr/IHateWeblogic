# Oracle REST Data Services (ORDS) – How It Works

ORDS is the Java web server between Nginx and the database for APEX and for
REST services. This page explains:
- what is inside the ORDS software (Jetty, JDBC, APEXlang compiler, features);
- how a request runs through ORDS into the database;
- the two configuration levels (files and `ORDS_METADATA`);
- the **proxy right** that lets one pool user act as many schemas;
- REST services and their security (roles, privileges, OAuth2, APEX session);
- which features carry which risk, and how this library switches them off.

The APEX side (engine, SYS objects, page flow) is in
[apex_architecture.md](apex_architecture.md). The scripts are in
[12-APEX-Ords/](../12-APEX-Ords/README.md).

Markers: **documented** (source in section 12), **confirmed (live)** (test
host, ORDS 26.3.0.272.1811 + APEX 26.2 on DB 19.30, 2026-10-23),
**assumption** (not proven yet).

---

## 1. What is inside the ORDS software

The download is a ZIP. Its centre is one file, `ords.war` – an **executable
WAR**: `ords serve` starts it with an **embedded Jetty**, no separate
application server needed ("standalone" mode).

Content of `ords.war` 26.3.0.272.1811 – 221 jars (**confirmed (live)**,
`unzip -l ords.war`):

| Part | Jars (examples) | Meaning |
|---|---|---|
| Web server | `jetty-server-12.0.37`, `jetty-ee8-*`, `jetty-http2-*`, `jetty-websocket-*` | Jetty 12 with the Servlet API of Jakarta EE 8 (javax), HTTP/2, WebSocket |
| Database access | `ojdbc11-23.26.2.0.0`, `ucp11-23.26.2.0.0` | thin JDBC driver + Universal Connection Pool (UCP) – **no** Oracle client needed, the pool connects via the TNS alias of `TNS_ADMIN` |
| APEX support | `ords-apex-support`, `dbtools-apex` | PL/SQL gateway for APEX, static-file handling |
| **APEXlang** | `apexlang-compiler-26.2.0.239.0036`, `ords-apexlang-server` | the **APEXlang compiler of APEX 26.2 lives inside ORDS** (section 1a) |
| REST / security | `ords-oauth`, `ords-soda`, `orarestsoda`, `orajsoda` | OAuth2, SODA for REST (JSON collections) |
| Further features | `ords-graphql`, `ords-mcp`, `dbtools-mcp`, `oraml-jetty` | GraphQL, MCP server (AI agents), Oracle Machine Learning REST |

Besides the WAR, the ZIP contains `bin/ords` (the command line), `scripts/`
(installer SQL), `examples/` and `linux-support/`. That folder holds Oracle's
own `ords.service`, which serves **one** instance from `/etc/ords/ords.conf`.
This library uses its own template unit `ords@.service` instead: one unit
file for `ords_1`, `ords_2`, … (section 9).

### 1a. APEXlang – APEX and ORDS are coupled since 26.x

**APEXlang** is APEX's new declarative, human-readable application format
(text instead of the classic export SQL – meant for version control and for
AI agents). It is **not** processed in the database:
- the **APEXlang compiler is part of ORDS** (`apexlang-compiler-<APEX version>.jar` in `ords.war`, **confirmed (live)**) and of SQLcl (`apex validate`, `apex generate` – Oracle APEX blog, **documented**);
- APEX does not import APEXlang directly; the compiler turns it into the classic install SQL (Oracle APEX blog "Let's Talk APEXLang", **documented**);
- `APEX_PATCHES` in 26.2 has a column **`APEXLANG_VERSION`** next to `PATCH_VERSION` / `IMAGES_VERSION` – an APEX patch can move the APEXlang level (**confirmed (live)**, view description).

Consequences for this library:
- **ORDS ≥ APEX is a hard rule.** The APEX 26.2 installation guide: "Oracle APEX requires Oracle REST Data Services (ORDS) 26.3.0 or later" and "SQLcl 26.3.0 or later" (**documented**).
- An APEX upgrade can force an ORDS upgrade (and an SQLcl update) – patch them as **one pair**, in one window.
- `04-install-ords.sh` / `06-patch-ords.sh` check both the ORDS version and the version of the APEXlang compiler inside the new `ords.war` against the APEX version of the database – FAIL, not WARN.
- Oracle now recommends: "in new installations, ORDS should be installed before APEX" (APEX 26.2 installation guide, **documented**). This library installs APEX first (`02-`) and ORDS second (`04-`) – it works (live), because `ords install` finds the existing `APEX_PUBLIC_USER` and grants the proxy right.

### 1b. Java base

| Topic | Rule |
|---|---|
| JDK | ORDS 26 supports Java 17, 21 and 25; here `JDK_HOME` = Oracle JDK 21 (the same as for WebLogic) |
| Heap | `-Xms` = `-Xmx` = `ORDS_JAVA_HEAP` via `_JAVA_OPTIONS` in the unit (dev 1–2 G, test 2–4 G, production ≥ 4 G) |
| GC | G1 (`-XX:+UseG1GC`) |
| Logging | `java.util.logging`; this library sets `-Djava.util.logging.config.file=…/config/global/logging.properties` (rotating `FileHandler`, 5 × 10 MB) |
| Access log | `standalone.access.log` – ORDS writes `ords_<date>.log` per day and keeps 90 days (`standalone.access.log.retainDays`) |
| Other deployments | ORDS can also run as a WAR in Tomcat or WebLogic; the APEX 26.2 guide calls it "certified with Oracle WebLogic Server and Apache Tomcat". This library uses standalone only (own process, own restart, no influence on the Forms domain). ORDS 26.4 drops Tomcat 9 (release notes, **documented**) |

---

## 2. A request through ORDS

```
 Nginx  /ords/...  (X-Forwarded-For = $remote_addr)
   |
   v
 Jetty (127.0.0.1:8081, standalone.binds) -> ORDS dispatcher
   |   1. pool routing: /ords/<pool>/... or "default"
   |   2. what is it?
   |        /ords/r/<ws>/<app>/<page>  APEX friendly URL ------+
   |        /ords/f?p=...              PL/SQL gateway (APEX) --+--> PL/SQL gateway
   |        /ords/<schema alias>/...   REST module -------------> REST dispatcher
   v                                                               |
 UCP pool (logged in as ORDS_PUBLIC_USER)                          |
   |   3. take a connection, open a PROXY SESSION                  |
   |        gateway: ORDS_PUBLIC_USER[APEX_PUBLIC_USER]            |
   |        REST:    ORDS_PUBLIC_USER[<schema>]  <-----------------+
   |   4. gateway: owa.init_cgi_env(...) – CGI variables incl. REMOTE_ADDR
   |      requestValidationFunction (allow list) -> call the procedure
   |      REST: definitions from ORDS_METADATA (cached), run the handler
   |   5. read the result (htp buffer / result set / JSON), stream it back
   v
 database (PDB)
```

**Confirmed (live)** on the test host after one call of the APEX sign-in page
(`v$session`, `v$sql`):
- 10 sessions of `ORDS_PUBLIC_USER` (= `jdbc.InitialLimit`), plus one session of `APEX_PUBLIC_USER` – the proxy session of the request;
- the SQL parsed as `APEX_PUBLIC_USER` is the gateway protocol of ORDS: `owa.init_cgi_env(...)` + `htp.init`, `wwv_flow.resolve_friendly_url(p_path => :1)` for the friendly URL, the read-out of the `htp.htbuf_arr` buffer, and `begin :app_id := wwv_flow.g_flow_id; …` – the engine itself runs as `APEX_260200` (definer rights);
- a request with a forged `X-Forwarded-For: 1.2.3.4` is logged in the APEX activity log with the real address – Nginx overwrites the header.

---

## 3. Two levels of configuration – files and database

ORDS keeps its configuration in **two places**. Both must fit together:

```
 level 1: ON THE ORDS HOST (files)            level 2: IN THE TARGET DATABASE (repository)
 ords_1/config/                               schema ORDS_METADATA (+ ORDS_PUBLIC_USER)
   how to REACH the database                    WHAT to serve and WHO may call it
   - pool.xml: TNS alias, pool user,            - REST-enabled schemas + URL aliases
     wallet with its password                   - modules / templates / handlers (SQL, PL/SQL)
   - settings.xml: port, binds, context path,   - roles, privileges (URL patterns)
     caches, security switches                  - OAuth clients, secrets, tokens
   - logging                                    - ORDS version of the repository
   one per ORDS instance                        one per database (shared by every ORDS
   changed with: ords config set                that serves this database)
                                                changed with: ords install / ORDS PL/SQL API
```

| | Level 1 – configuration files | Level 2 – ORDS repository in the database |
|---|---|---|
| Where | `$APEX_ORDS_BASE/ords_N/config/` on the ORDS host | schema `ORDS_METADATA` in the target PDB – here in the APEX tablespace (`APEX_DATA`, ~2 MB after the installation, **confirmed (live)**) |
| Content | connection to the DB (pool), web server, caches, logging | REST services, their security, OAuth clients |
| Created by | `ords install` (pool), `ords config set` | `ords install` (creates / **upgrades** the schema to the ORDS version) |
| Changed by | the administrator on the host | developers: `ORDS.*` / `ORDS_SECURITY.*` PL/SQL, REST workshop in SQL Developer Web / APEX |
| Backup | file backup of the config dir (holds the wallet) | database backup / Data Pump of the PDB |
| On an ORDS upgrade | new software link, config stays | `ords install` upgrades `ORDS_METADATA` – one-way, DB backup first |
| On a clone / move | host-specific (`externalSessionTrustedOrigins`, TNS alias) | moves with the database |

**What the repository does:** for every REST request ORDS reads (and caches,
`cache.metadata.*`) the definitions in `ORDS_METADATA`:
- which schema the URL alias belongs to;
- which module / template / handler matches the path;
- which privilege protects it;
- whether the caller's token or role is allowed.

Only then does ORDS open the proxy session to the schema and run the
handler. The repository holds **no business data** – only the description
of the services and their security. Its version must match the ORDS
software (`ords_metadata.ords_version`: `26.3.0.r2721811` for the software
26.3.0.272.1811). Several ORDS instances may serve one database; they then
share one repository – in this library it is one ORDS per database.

> **Warning – never change `ORDS_METADATA` by hand (author's experience):**
>
> - **Never delete rows in `ORDS_METADATA` with SQL.** The tables are
>   linked with **`ON DELETE CASCADE`** foreign keys – **54 of the 56**
>   foreign keys of the schema (**confirmed (live)**, `dba_constraints`
>   `delete_rule = 'CASCADE'`). One `DELETE` on a module, schema or
>   privilege row silently takes every dependent template, handler,
>   privilege mapping and OAuth assignment with it – whole REST interfaces
>   are gone at once, without an error.
> - Change REST definitions only through the API (`ORDS.*`,
>   `ORDS_SECURITY.*`) or the REST workshop. **Before every change to an
>   existing REST interface, export it first** – especially before an ORDS
>   upgrade. ORDS has many bugs in this area: a "redefine" of a module, an
>   upgrade or a workshop action can drop or rewrite definitions you did
>   not touch.
> - Ways to save the definitions, from the smallest to the largest:
>   - the export of the REST workshop (SQL Developer Web / APEX: export module);
>   - the PL/SQL export API – packages `ORDS_EXPORT` / `ORDS_EXPORT_ADMIN` exist in 26.3 (**confirmed (live)**); the exact procedure names: ORDS 26.3 Developer's Guide;
>   - SQLcl `rest export` into a script under version control (SQLcl 26.3 is installed by `00-Setup/install_db_client_tools.sh`);
>   - Data Pump of the REST-enabled schema **plus** a backup of the whole PDB – a Data Pump of `ORDS_METADATA` alone is no restore path.
> - Keep the exported scripts in the repository of the application – then
>   a lost interface is re-created with one script instead of rebuilt by
>   hand.

---

## 4. Level 1 in detail – the configuration directory

One directory per ORDS instance, given with `--config`. Created by
`04-install-ords.sh` (**confirmed (live)**):

```
ords_1/config/                     mode 700 (owner oracle) – holds the wallet
  databases/
    default/                       one directory per pool (= per database)
      pool.xml                     TNS alias + TNS dir, user ORDS_PUBLIC_USER,
                                   jdbc.* limits, plsql.gateway.mode, feature.* flags
      wallet/cwallet.sso           password of ORDS_PUBLIC_USER (auto-login wallet)
  global/
    settings.xml                   standalone.* (binds, port, context, access log),
                                   cache.*, security.*
    logging.properties             java.util.logging (our template)
```

- **ORDS reads every file below `config/`, whatever its name** – a
  `pool.xml.bak` is read as configuration (customer finding). Backups go
  elsewhere; `04-` warns about `*.bak` / `*.old` / `*~` files there.
- **Change settings only with `ords --config <dir> config set`** – and
  check the key first:

> **Pitfall (confirmed live 2026-10-23):** `ords config set` accepts
> **unknown keys without an error**. Our first script set
> `standalone.http.host 127.0.0.1` (a key from old guides) – ORDS stored it,
> Jetty still listened on **0.0.0.0:8081**. The right key in ORDS 26 is
> **`standalone.binds`** (default `0.0.0.0`). `ords config info <key>`
> reports "not a recognized configuration setting" – `04-install-ords.sh`
> checks every key this way before it sets it, and checks the listener with
> `ss` afterwards.

- `ords config list --include-defaults` shows every effective value with
  its source (`Global`, `Pool`, `Default`).
- **Pool routing:** `/ords/...` without a pool name uses `default`;
  `/ords/<pool>/...` uses the pool of that name. One ORDS can serve several
  databases this way – **this library uses one ORDS per database** instead
  (own version, own restart, own image prefix).
- `ords install` of 26.3 rejects `--db-pool default` ("The default name is
  not allowed for --db-pool option") – leave the option out for the default
  pool (**confirmed (live)**).

---

## 5. The proxy right – how one pool serves many schemas

ORDS keeps **one** connection pool, logged in as `ORDS_PUBLIC_USER`. For each
request it does not log in again but opens a **proxy session** on a pooled
connection – it acts as another database user without knowing that user's
password. The database allows this only with the proxy right:

```sql
alter user APEX_PUBLIC_USER grant connect through ORDS_PUBLIC_USER;   -- APEX pages
alter user <SCHEMA>         grant connect through ORDS_PUBLIC_USER;   -- REST of <SCHEMA>
```

- **Set by the tools:**
  - `ords install --gateway-mode proxied --gateway-user APEX_PUBLIC_USER` grants it for the PL/SQL gateway user;
  - `ords.enable_schema` grants it for a REST-enabled schema;
  - **documented:** "proxied – The PL/SQL gateway call is performed by proxying from the run-time user (`db.username` in `pool.xml`) to the relevant schema configured by `ords_admin.config_plsql_gateway`" (ORDS 26.3 installation guide).
- **Confirmed (live)** after `04-install-ords.sh` (`proxy_users`):
  - `ORDS_PUBLIC_USER` → `APEX_PUBLIC_USER`
  - `ORDS_PUBLIC_USER` → `APEX_REST_PUBLIC_USER`
  - `APEX_REST_PUBLIC_USER` → `APEX_PUBLIC_USER` (created by `apex_rest_config.sql`)
  - **not** `APEX_PUBLIC_ROUTER` – the friendly-URL account of APEX 26 is no proxy client of the pool user.
- **Without the proxy right:** ORDS runs APEX / PL/SQL-gateway requests **directly as the runtime user** and logs a warning per request; with pooled proxy rights missing users see HTTP 503 ("not authorized to proxy", MOS 2770463.1 title).
- **Consequence for security:** the pool user can become every listed
  client. Its password lives only in the wallet (and `apex_sec.conf.des3`
  for a re-installation), it never gets more grants, and only schemas that
  need it are REST-enabled.

---

## 6. Features – and their risk

`ords config list --include-defaults` after `04-install-ords.sh`
(**confirmed (live)**):

| Feature | Setting | ORDS default | This library | Risk if on |
|---|---|---|---|---|
| PL/SQL gateway (APEX) | `plsql.gateway.mode` | `disabled` | `proxied` | every procedure `APEX_PUBLIC_USER` may execute is callable by URL – hence the allow list below |
| Gateway allow list | `security.requestValidationFunction` | none | `ords_util.authorize_plsql_gateway` (APEX 26.2 guide) | without it, any granted procedure answers on `/ords/<proc>` |
| REST services of enabled schemas | `ords.enable_schema` per schema | – | on, per schema | without a privilege a module is **public** |
| **Database Actions** (SQL Developer Web) | `feature.sdw` | – | `false` (`ORDS_FEATURE_SDW`) | SQL worksheet, data load, user admin in the browser – full SQL over HTTP for every REST-enabled user |
| **REST-enabled SQL** | `restEnabledSql.active` | – | `false` (`ORDS_FEATURE_REST_SQL`) | `POST /ords/<schema>/_/sql` runs any SQL script |
| **Database API** | `database.api.enabled` | `false` | `false` (`ORDS_FEATURE_DB_API`) | PDB lifecycle, data dictionary, Data Pump via REST |
| **GraphQL** | `feature.graphql` | **`enabled`** | `disable_all` (`ORDS_FEATURE_GRAPHQL`) | query language over the REST-enabled tables / views, GraphiQL UI |
| MCP server | `feature.mcp` | `false` | default | AI agents call database tools (ORDS 26.x) |
| MongoDB API | `mongo.enabled` | `false` (`mongo.host 0.0.0.0` when on!) | default | own listener port 27017 on all interfaces |
| Static files | `standalone.static.*` | context `/i` | not used – Nginx serves `/srv/apex` | an ORDS image path in addition to Nginx |
| HTTPS behind a proxy | `security.httpsHeaderCheck` | none | `X-Forwarded-Proto: https` | without it ORDS builds **`http://`** links (REST catalog, OpenAPI, redirects) although the client used HTTPS – seen live before the fix |

### 6.1 APEX workspaces REST-enable their schema – with an open catalog

Creating a workspace in APEX (live: workspace `GPI`, new schema `GPIDEV`,
2026-10-23) does more on the ORDS side than one would expect
(**confirmed (live)**):

- APEX calls `ords.enable_schema(p_enabled => true, p_schema => …,
  p_url_mapping_pattern => <workspace alias>, …)` – parsed as `GPIDEV`
  (`v$sql`). The schema is **REST-enabled** with the alias `gpi`, and
  `ords.enable_schema` grants the **proxy right** `ORDS_PUBLIC_USER` →
  `GPIDEV` (`proxy_users`).
- `auto_rest_auth = DISABLED`: the **metadata catalog and the OpenAPI
  catalog of the schema answer without authentication** –
  `/ords/gpi/metadata-catalog/` and `/ords/gpi/open-api-catalog/` → HTTP 200
  for anybody who reaches Nginx. Empty today (no modules, no AutoREST
  objects); as soon as REST modules exist, their structure is listed there.
- The new schema gets an **own tablespace** `APEX_<number>` with **10 MB,
  autoextend, maxsize 100 MB** (`dba_data_files`) – too small for a real
  application; and the profile `DEFAULT` (password expiry 180 days).

Rules for this library – these belong to the **installation of the
application** (not to the ORDS / APEX instance scripts); the planned
`12-APEX-Ords/07-check-ords-apex-security.sh` checks them
([12-APEX-Ords README §9](../12-APEX-Ords/README.md#9-open-items)):
- Workspace schemas for production: create the schema and its tablespace
  beforehand (own name, sensible maxsize) and assign them to the workspace,
  instead of letting APEX create `APEX_<number>`.
- Protect the catalog: `ords.enable_schema(p_enabled => true, p_schema =>
  '<SCHEMA>', p_url_mapping_type => 'BASE_PATH', p_url_mapping_pattern =>
  '<alias>', p_auto_rest_auth => true)` – or not REST-enable a schema that
  needs no REST at all (`ords.enable_schema(p_enabled => false, …)`).
- Password expiry of the parsing schema: APEX parses with
  `DBMS_SYS_SQL.parse_as_user` (no login), ORDS uses the proxy right (no
  password) – whether an **expired** client password breaks the proxy
  session is an **assumption** to test; a profile like `APEX_USER` for the
  parsing schemas avoids the question.

Rule of this library: everything that offers **SQL or administration over
HTTP** is off unless a project needs it – then it is switched on by hand in
`environment.conf` (`ORDS_FEATURE_*`) and the `04-` run is repeated.

---

## 7. REST services and their security

Structure in `ORDS_METADATA` (**documented**):

```
schema (REST-enabled, alias in the URL)
  └── module   base path  /orders/
        └── template      :id
              └── handler GET / POST / PUT / DELETE  ->  SQL query or PL/SQL block
URL: https://<host>/ords/<schema alias>/orders/42
```

- `ords.enable_schema` (alias, auth), `ords.define_module` / `define_template`
  / `define_handler`, or the REST workshop.
- **Protection:** a **role** (`ords.create_role`) and a **privilege**
  (`ords.define_privilege`, `p_patterns => '/import/*'`) map URL patterns to
  the role – **without a privilege a module is public**.

### 7.1 Machine callers – OAuth2 client credentials

From the author's wiki (APEX 26 / ORDS 26, cron job on an external server
loading Data Pump and PDF files):

1. `ORDS.CREATE_ROLE` + `ORDS.DEFINE_PRIVILEGE` (role ↔ `/import/*`);
2. `ORDS_SECURITY.REGISTER_CLIENT` (`p_grant_type => 'client_credentials'`);
3. `ORDS_SECURITY.GRANT_CLIENT_ROLE`;
4. `ORDS_SECURITY.ROTATE_CLIENT_SECRET` – returns the secret **once** in clear text; store it at once (encrypted, like the `*.des3` files here);
5. token: `POST /ords/<schema>/oauth/token`, Basic auth `client_id:secret`, `grant_type=client_credentials` → `access_token`, `expires_in` ≈ 3600 s; call with `Authorization: Bearer <token>`; cache the token and renew it a few minutes before expiry;
6. clean-up: `ORDS_SECURITY.DELETE_CLIENT`, `ORDS.DELETE_PRIVILEGE`, `ORDS.DELETE_ROLE`.

- The old packages **`OAUTH` / `OAUTH_ADMIN`**: deprecated in ORDS 24.3 ("consolidated … into two new packages: ORDS_SECURITY and ORDS_SECURITY_ADMIN"), **desupported from ORDS 25.3** (ORDS 25.2 package reference, **documented**). In 26.3 they still **exist and are VALID** in `ORDS_METADATA` (**confirmed (live)**) – old scripts still run, but are not supported any more. Use `ORDS_SECURITY` only.
- The wiki's helper used `curl -k` – never in production; the CA of the server must be trusted.
- After a move from Autonomous DB to on-premise, Basic auth against an APEX workspace user returned 401 under standalone ORDS 26 – the trigger for the OAuth2 design (wiki).

### 7.2 REST call inside an APEX session

A document download from a logged-in APEX page is a browser navigation
(new tab, PDF viewer) – it cannot send an `Authorization` header, and
OAuth2 would identify the client, not the user. The wiki's pattern:

- the URL carries the APEX session: `?_apex_session=<app_id>,<session_id>` (or a header);
- the handler checks **before** attaching:
  - the client IP of the request matches an entry of this session in the APEX activity log (`apex_workspace_activity_log`) – the IP comes from `X-Forwarded-For`, so **this check is only as good as the Nginx rule** that overwrites the header (section 2, confirmed live);
  - there is no logout entry for the session (a session stays attachable after logout until it is purged);
- `apex_session.attach(p_app_id, p_page_id => 0, p_session_id)` → `APP_USER` and the session state are available;
- on failure: HTTP 403 (`owa_util.status_line(403, …)`);
- **always** `apex_session.detach` – also in the error path: the pooled connection is reused for the next request;
- residual risks: the session id in the URL lands in logs and in `Referer` → `Referrer-Policy: no-referrer`, HTTPS only, short APEX idle timeout.

---

## 8. Operations and risks

| Topic | Rule |
|---|---|
| Expiring / locked runtime users | `ORDS_PUBLIC_USER`, `APEX_PUBLIC_USER`, `APEX_REST_PUBLIC_USER`, `APEX_PUBLIC_ROUTER` get the profile **`APEX_USER`** (`PASSWORD_LIFE_TIME` / `FAILED_LOGIN_ATTEMPTS UNLIMITED`, `12-APEX-Ords/apex_user_profile.sql`) – before, `APEX_REST_PUBLIC_USER` would have expired on 2027-04-21 (**confirmed (live)**). No lock-out means: long random passwords and a DB listener reachable from the application hosts only |
| Pool vs. `processes` | Σ `jdbc.MaxLimit` (50 per ORDS) + FMW / RCU pools + 50 ≤ `processes` (`01-prepare-database.sh` checks) |
| Listener | `standalone.binds 127.0.0.1` – Nginx is the one door (`04-` checks with `ss`) |
| Wallet | `config/` mode 700; belongs into the configuration backup (open item: `backup_config.sh`) |
| Logs | systemd stdout / stderr (almost empty), access log per day (90 days), `ords_sys_N.log` (5 × 10 MB) in `/var/log/ords_N` |
| Upgrade | new `ords-<ver>` beside the old one, link switch, `ords install` upgrades `ORDS_METADATA` – **one-way**; rollback by link only while the repository is unchanged (`06-patch-ords.sh`) |
| ORDS + APEX + SQLcl | one patch window (section 1a) |

---

## 9. In this library

| Script | What |
|---|---|
| `00-Setup/install_db_client_tools.sh` | SQLcl (APEXlang, `apex export`, `rest export`) + Instant Client |
| `12-APEX-Ords/01-prepare-database.sh` | tablespace for APEX **and** `ORDS_METADATA`, profile `APEX_USER` |
| `12-APEX-Ords/04-install-ords.sh` | software `ords-<ver>`, home `ords_N` (config 700, link), `ords install` (non-interactive, passwords via stdin), `config set` with key check, profile, systemd `ords@.service`, loopback check |
| `12-APEX-Ords/05-setup-nginx.sh` | `/etc/nginx/oracle-wls.d/ords_N.conf` – `/ords/` proxy (X-Forwarded-For overwritten) + `/i/` images |
| `12-APEX-Ords/06-patch-ords.sh` | new ORDS release, repository upgrade, rollback, clean-up |

Variables: `ORDS_N_DB_ALIAS / _PORT / _CONTEXT / _IMAGE_PREFIX`,
`ORDS_JAVA_HEAP`, `ORDS_PUBLIC_URL`, `ORDS_LOG_BASE`, `ORDS_FEATURE_*`,
`APEX_DB_PROFILE` ([interview block 4b](../09-Install/docs/01-setup-interview.md)).

---

## 10. History (short)

| Year | Step |
|---|---|
| 2010 | **APEX Listener** – a Java alternative to mod_plsql (WebLogic / GlassFish / standalone) |
| ~2014 | renamed **Oracle REST Data Services**: RESTful services, repository `ORDS_METADATA`; mod_plsql deprecated in OHS 12c |
| 2018 | year-based versions (ORDS 18.x) |
| 2022 | ORDS 22: new `ords` command line, one configuration directory (`databases/`, `global/`), Jetty standalone as the normal mode |
| 2024 | ORDS 24.3: `OAUTH` / `OAUTH_ADMIN` deprecated → `ORDS_SECURITY` / `ORDS_SECURITY_ADMIN` |
| 2025 | ORDS 25.3: `OAUTH` / `OAUTH_ADMIN` desupported |
| 2026 | ORDS 26.1.1: APEXlang support; ORDS 26.x MCP server; ORDS 26.3 required by APEX 26.2; ORDS 26.4 drops Tomcat 9 |

Dates before 2018 are background from the author's experience
(**assumption** to the year).

---

## 11. Open

- `07-check-ords-apex-security.sh` (planned, [12-APEX-Ords README §9](../12-APEX-Ords/README.md#9-open-items)):
  check workspace schemas for `auto_rest_auth`, profile, tablespace maxsize,
  public REST modules, feature drift; test whether an expired parsing-schema
  password breaks the ORDS proxy session.
- `06-patch-ords.sh` upgrade path: first real run with the next ORDS
  release (`ords install --db-only` for the repository upgrade is taken from
  `ords install --help`, not yet run).
- `backup_config.sh` / `clone_check.sh` for the ORDS config directory
  (wallet!), `cve_inventory.sh` for ORDS / APEX / SQLcl / Instant Client.

---

## 12. Sources

All checked 2026-10-23:

- ORDS 26.3 – Installation and Configuration Guide (`--password-stdin` order, gateway modes, APEX configuration) –
  <https://docs.oracle.com/en/database/oracle/oracle-rest-data-services/26.3/ordig/installing-and-configuring-oracle-rest-data-services.html>
- ORDS 26.3 Developer's Guide (REST modules, privileges, OAuth, export) –
  <https://docs.oracle.com/en/database/oracle/oracle-rest-data-services/26.3/orddg/>
- ORDS 25.2 – OAUTH_ADMIN PL/SQL Package Reference (desupport from 25.3) –
  <https://docs.oracle.com/en/database/oracle/oracle-rest-data-services/25.2/orddg/oauth_admin-pl-sql-package-reference.html>
- ORDS 24.3 release notes (`ORDS_SECURITY` / `ORDS_SECURITY_ADMIN`, `OAUTH` deprecated) –
  <https://www.oracle.com/tools/ords/ords-relnotes-24.3.html>
- ORDS 26.1.1 release notes (APEXlang support) –
  <https://www.oracle.com/tools/ords/ords-relnotes-26.1.1.html>
- Oracle APEX 26.2 Installation Requirements (ORDS 26.3.0, SQLcl 26.3.0, ORDS before APEX) –
  <https://docs.oracle.com/en/database/oracle/apex/26.2/htmig/apex-installation-requirements.html>
- Oracle APEX blog – "Let's Talk APEXLang" (compiler in SQLcl, APEXLang → SQL) –
  <https://blogs.oracle.com/apex/wp-content/uploads/sites/15/2026/04/Lets-Talk-APEXLang.pdf>
- `ords install --help`, `ords config info <key>`, `ords config list --include-defaults` of ORDS 26.3.0.272.1811 (test host)
- Gunther Pipperr – APEX 26 / ORDS 26: OAuth2 client credentials and the APEX session in REST calls –
  <https://pipperr.de/dokuwiki/doku.php?id=prog:oracle_apex_26_ords_26_oauth_apex_session>
- Gunther Pipperr – APEX 26.1 with ORDS 26.1 standalone and Nginx on OL9 –
  <https://pipperr.de/dokuwiki/doku.php?id=prog:oracle_apex_26_1_ords_standalone_nginx_ol9>
- MOS Doc ID 2770463.1 (ORDS 503, pool user not authorized to proxy) – title only.
