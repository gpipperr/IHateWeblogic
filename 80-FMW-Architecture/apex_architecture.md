# Oracle APEX and ORDS – How a Request Reaches the Database

How Oracle APEX and Oracle REST Data Services (ORDS) work together beside a
Forms / Reports domain:
- which parts take part in a request;
- what lives in the ORDS configuration directory and in the database;
- how the pool user reaches the APEX and REST schemas through the **proxy
  right** (`CONNECT THROUGH`);
- how REST services and OAuth2 work through ORDS.

The installation is in [12-APEX-Ords/README.md](../12-APEX-Ords/README.md).

Markers: **documented** (source in section 9), **confirmed (live)** (test
host, date given), **assumption** (not proven yet). APEX 26.2 is installed on
the test host since 2026-10-23 (`12-APEX-Ords/02-install-apex.sh`, PDB on DB
19.30) – sections 5a / 5b are checked there; ORDS is not installed yet, so
the request path (sections 4–6) is still **documented** only.

---

## 1. The parts

```
 browser                                        script / other system
   |  HTTPS  /ords/r/<app>/...                    |  HTTPS  /ords/<schema>/<module>/...
   v                                              v
 +------------------------- Nginx (TLS, one host name) -------------------------+
 |  /i/  -> alias /srv/apex/apex_1/  (static images, no ORDS)                         |
 |  /ords/ -> 127.0.0.1:8081     X-Forwarded-For = $remote_addr (overwritten)     |
 +-------------------------------------|-----------------------------------------+
                                       v
 +---------------- ORDS 26.x standalone (Jetty 12, java at JDK_HOME) ----------------+
 |  config dir  ords_1/config/   databases/<pool>/pool.xml + wallet,                 |
 |                               global/settings.xml, credentials, logging           |
 |  JDBC pool (UCP) - connects as ORDS_PUBLIC_USER (runtime user)                    |
 +-----------|------------------------------------------------|----------------------+
             | proxy: ORDS_PUBLIC_USER[APEX_PUBLIC_USER]       | proxy: ORDS_PUBLIC_USER[<SCHEMA>]
             v                                                v
 +--------------------------------- database (PDB) ----------------------------------+
 |  APEX_PUBLIC_USER -> APEX engine (schema APEX_260200, FLOWS_FILES):                |
 |                     wwv_flow.show/accept, the app's PL/SQL, session state          |
 |  <SCHEMA> (REST-enabled) -> handler PL/SQL / SQL of the REST module                |
 |  ORDS_METADATA  - REST modules/templates/handlers, privileges, roles, OAuth        |
 |                   clients, schema aliases (the "ORDS repository")                  |
 +------------------------------------------------------------------------------------+
```

| Part | Role |
|---|---|
| Nginx | TLS, one host name, serves the APEX images directly (`/i/` → `/srv/apex/apex_1`), proxies `/ords/` |
| ORDS (standalone) | Java web server (embedded Jetty); maps the URL to a pool and to an APEX page or a REST handler, runs the database call, streams the answer |
| `ORDS_PUBLIC_USER` | **runtime / pool user** – the only user ORDS logs in with; owns nothing |
| `APEX_PUBLIC_USER` | **PL/SQL gateway user** of APEX – ORDS switches to it for APEX pages (proxy). 26.2 creates it **without authentication** – reached only through the proxy right, no password needed (section 2a) |
| `APEX_PUBLIC_ROUTER` | **new in 26.x** – minimally privileged account an ORDS REST module uses to resolve APEX **friendly URLs** (`/ords/r/<workspace>/<app>/<page>`) |
| `APEX_260200` | APEX engine and metadata of release 26.2 (one schema per release – an upgrade creates a new one, the old one is dropped later) |
| `FLOWS_FILES` | uploaded files of APEX |
| `APEX_REST_PUBLIC_USER` | created by `apex_rest_config.sql` – serves the **static files** of workspaces / applications / plug-ins / themes through an APEX RESTful module; still required after a new 26.2 installation (`APEX_LISTENER` no longer exists, section 2a) |
| `ORDS_METADATA` | the ORDS repository: REST definitions, security, OAuth clients (created / upgraded by `ords install`) |
| REST-enabled schema | the owner of the data a REST module works on (`ords.enable_schema`) |

---

## 2. Two levels of ORDS configuration – files and database

ORDS keeps its configuration in **two places**. Both must fit together:

```
 level 1: ON THE ORDS HOST (files)            level 2: IN THE TARGET DATABASE (repository)
 ords_1/config/                               schema ORDS_METADATA (+ ORDS_PUBLIC_USER)
   how to REACH the database                    WHAT to serve and WHO may call it
   - pool.xml: TNS alias, pool user,            - REST-enabled schemas + URL aliases
     wallet with its password                   - modules / templates / handlers (SQL, PL/SQL)
   - settings.xml: port, host, context path,    - roles, privileges (URL patterns)
     caches, security switches                  - OAuth clients, secrets, tokens
   - logging                                    - ORDS version of the repository
   one per ORDS instance                        one per database (shared by every ORDS
   changed with: ords config set                that serves this database)
                                                changed with: ords install / ORDS PL/SQL API
```

| | Level 1 – configuration files | Level 2 – ORDS repository in the database |
|---|---|---|
| Where | `$APEX_ORDS_BASE/ords_N/config/` on the ORDS host | schema `ORDS_METADATA` in the target PDB |
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
software: a newer ORDS upgrades the repository with `ords install` (customer
upgrade 23.3 → 26.3: 30 s, **documented** in the anonymised upgrade notes).
Several ORDS instances may serve one database; they then share one
repository – in this library it is one ORDS per database, so each
repository has exactly one ORDS.

> **Warning – never change `ORDS_METADATA` by hand (author's experience):**
>
> - **Never delete rows in `ORDS_METADATA` with SQL.** The tables are
>   linked with **`ON DELETE CASCADE`** foreign keys – one `DELETE` on a
>   module, schema or privilege row silently takes every dependent
>   template, handler, privilege mapping and OAuth assignment with it, and
>   whole REST interfaces are gone at once, without an error.
> - Change REST definitions only through the API (`ORDS.*`,
>   `ORDS_SECURITY.*`) or the REST workshop. **Before every change to an
>   existing REST interface, export it first** – especially before an ORDS
>   upgrade. ORDS has many bugs in this area: a "redefine" of a module, an
>   upgrade or a workshop action can drop or rewrite definitions you did
>   not touch.
> - Ways to save the definitions, from the smallest to the largest:
>   - the export of the REST workshop (SQL Developer Web / APEX: export module);
>   - an ORDS PL/SQL export of the schema;
>   - SQLcl `rest export` into a script under version control;
>   - Data Pump of the REST-enabled schema **plus** a backup of the whole PDB – a Data Pump of `ORDS_METADATA` alone is no restore path.
>   - The exact names of the export API differ between ORDS releases – check them in the ORDS 26.3 Developer's Guide (section 9) before relying on them; **assumption**, not tested here yet.
> - Keep the exported scripts in the repository of the application – then
>   a lost interface is re-created with one script instead of rebuilt by
>   hand.

APEX keeps its own metadata (applications, workspaces, session state) in
`APEX_260200`, not in `ORDS_METADATA`. Only the REST services of APEX
workspaces are stored in `ORDS_METADATA`.

---

## 2a. APEX database accounts in 26.2 – what changed

Checked 2026-10-23 against the APEX 26.2 installation guide ("About APEX
Database Accounts", "Configuring the APEX_PUBLIC_USER Account",
"Configuring Oracle REST Data Services") and the scripts in `apex_26.2.zip`
(**documented**):

| Account | Older releases / old guides | APEX 26.2 |
|---|---|---|
| `APEX_PUBLIC_USER` | password set and account unlocked after the installation; ORDS connected **as** this user | "created with **no authentication** in a new installation"; a password is needed only if ORDS is configured to connect as `APEX_PUBLIC_USER` instead of `ORDS_PUBLIC_USER` |
| `APEX_LISTENER` | created by `apex_rest_config.sql` (password prompt) | **gone** – not in the 26.2 account list; `apex_rest_config_core.sql` takes only a prefix and **one** password |
| `APEX_REST_PUBLIC_USER` | created by `apex_rest_config.sql` | still created by `apex_rest_config.sql` – **required after a new installation**: static files of workspaces, applications, plug-ins and themes are served by a RESTful module of APEX |
| `APEX_PUBLIC_ROUTER` | – | **new**: resolves friendly URLs for an ORDS REST module; "on highly active systems may reach the maximum number of sessions allowed" (sessions per user / profile) |
| `APEX_260200`, `FLOWS_FILES` | release schema, files | unchanged (one schema per release; `FLOWS_FILES` always locked) |

Consequences for this library (`12-APEX-Ords/02-install-apex.sh`):
- **No password and no unlock for `APEX_PUBLIC_USER`.** Our ORDS uses `ORDS_PUBLIC_USER` + proxy right (section 4) – a passwordless gateway account cannot be used for a direct login. That is a smaller attack surface than the old "unlock with password".
- One password less: only `APEX_REST_PUBLIC_USER` (random, `apex_sec.conf.des3`).
- `APEX_PUBLIC_ROUTER` belongs into the profile / sessions check, like the other runtime accounts. Whether it is a further proxy client of `ORDS_PUBLIC_USER` is to be verified after the installation (`proxy_users`) – **assumption** until then.
- Old guides and scripts that unlock `APEX_PUBLIC_USER` or expect `APEX_LISTENER` are outdated for 26.2.
- **ORDS setting recommended by the 26.2 guide:** `security.requestValidationFunction = ords_util.authorize_plsql_gateway` – only procedures allowed for the PL/SQL gateway can be called through `/ords/` (`12-APEX-Ords/README.md` §5.5).

---

## 3. Level 1 in detail – the ORDS configuration directory

One directory per ORDS instance (`$APEX_ORDS_BASE/ords_1/config/`), given with
`--config` – since ORDS 22 one tree for all settings (**documented**):

```
ords_1/config/
  databases/
    default/                 one directory per pool (= per database / mapping)
      pool.xml               connection (TNS alias + TNS_ADMIN, user ORDS_PUBLIC_USER),
                             jdbc.* pool limits, plsql.gateway.mode, feature flags
      wallet/cwallet.sso     password of ORDS_PUBLIC_USER (auto-login wallet)
    <alias> -> default       optional second name for the same pool (/ords/<alias>/...)
  global/
    settings.xml             standalone.* (host 127.0.0.1, port, context path, access log),
                             cache.*, security.*, feature switches
    credentials              Basic-auth users of ORDS itself (if used)
    logging.properties       java.util.logging (our addition, see 12-APEX-Ords)
```

- **ORDS reads every file below `config/`, whatever its name** – a
  `pool.xml.bak` is read as configuration (customer finding). Backups go
  elsewhere.
- **Pool routing:**
  - `/ords/...` without a pool name uses `default`;
  - `/ords/<pool>/...` uses the pool of that name;
  - one ORDS can serve several databases this way. **This library uses one ORDS
    per database instead** (own version, own restart, own image prefix).
- Change settings with `ords --config <dir> config set <key> <value>`, check
  with `config list [--include-defaults]` – not by editing the XML.
- The wallet makes the directory secret: owner `oracle`, mode 700 – and it
  belongs into the backup of the configuration.

---

## 4. The proxy right – how one pool serves many schemas

ORDS keeps **one** connection pool, logged in as `ORDS_PUBLIC_USER`. For each
request it does not log in again but opens a **proxy session** on a pooled
connection – it acts as another database user without knowing that user's
password. The database allows this only with the proxy right:

```sql
alter user APEX_PUBLIC_USER grant connect through ORDS_PUBLIC_USER;   -- APEX pages
alter user <SCHEMA>         grant connect through ORDS_PUBLIC_USER;   -- REST of <SCHEMA>
```

- **Set by the tools:**
  - `ords install` grants it for the PL/SQL gateway user (`APEX_PUBLIC_USER`);
  - `ords.enable_schema` grants it for a REST-enabled schema.
  - **documented:** the ORDS guide for a customer-managed runtime user shows `ALTER USER <gateway user> GRANT CONNECT THROUGH <runtime user>`; `ORDS_ADMIN.PROVISION_RUNTIME_ROLE` with `p_proxy_enabled_schemas` "adds proxy grants for REST enabled schemas".
- **Without the proxy right:** the guide says ORDS runs APEX / OWA / PL/SQL-gateway requests **directly as the runtime user** and logs a warning for each request. With pooled proxy rights missing, users see HTTP 503 ("not authorized to proxy", MOS 2770463.1 title).
- **Check (test host, after the installation):**

  ```sql
  select proxy, client from proxy_users where proxy = 'ORDS_PUBLIC_USER';
  ```
- **Consequence for security:** the pool user can become every listed
  client. Lock its password into the wallet only, never grant it more, and
  do not REST-enable schemas that do not need it.

```
 request /ords/r/sales/...       pool connection (ORDS_PUBLIC_USER)
        |                                |
        +--> ORDS: APEX request ---------+--> proxy session APEX_PUBLIC_USER
                                         |      -> wwv_flow.show (APEX engine)
 request /ords/sales/orders/ ------------+--> proxy session SALES
                                                -> REST handler of module "orders"
```

---

## 5. An APEX page request

1. Browser → Nginx `/ords/r/<app>/<page>` → ORDS `127.0.0.1:8081`.
2. ORDS picks the pool (`default`), takes a connection, opens the proxy
   session `APEX_PUBLIC_USER`.
3. The APEX engine (`APEX_260200`) checks the APEX session (cookie +
   `session` in the URL), runs the page process / render PL/SQL of the
   application's parsing schema, writes the HTML via the PL/SQL web toolkit
   (`htp`) – ORDS streams it back.
4. CSS / JavaScript come from `/i/` – Nginx serves them from `/srv/apex/apex_1`
   without touching ORDS or the DB. The APEX instance parameter
   `IMAGE_PREFIX` (`/i/`) must match the Nginx location.
5. The client IP the application sees (`owa_util.get_cgi_env('REMOTE_ADDR')`,
   APEX activity log) comes from `X-Forwarded-For` – Nginx must **overwrite**
   it with `$remote_addr`, or the address is wrong and forgeable (customer
   finding, see 12-APEX-Ords §5.7).

---

## 5a. From `f?p=` to SQL in the application schema

The classic URL `https://<host>/ords/f?p=<app>:<page>:<session>` calls a
**procedure named `F`** through the PL/SQL gateway – `p` is its first
parameter. How the SQL of the application then runs in the application's
**parsing schema**, not in the APEX schema, can be read from the clear-text
package specifications, `dba_dependencies`, `accessible by` clauses and
grants – no unwrapping needed (**confirmed (live)** 2026-10-23, APEX 26.2):

```
/ords/f?p=100:1:<session>
  -> PUBLIC synonym F -> APEX_260200.F          procedure (body wrapped), EXECUTE to PUBLIC
       parameters P (= "app:page:session:request:debug:..."), P_SEP, C, CS, S,
       TZ, P_LANG, X01 ...; depends on WWV_FLOW, WWV_FLOW_SECURITY, DBMS_SQL
  -> APEX_260200.WWV_FLOW.show / accept         engine entry (spec clear, body wrapped)
  -> APEX_260200.WWV_FLOW_DYNAMIC_EXEC          dynamic SQL / PL/SQL of the application
  -> SYS.WWV_DBMS_SQL_APEX_260200               authid current_user,
       parse_as_user(p_cursor, p_query, p_username, p_use_roles)
       accessible by ONLY: WWV_FLOW_DYNAMIC_EXEC, WWV_FLOW_SESSION_RAS,
                           WWV_FLOW_CODE_EXEC_MLE, WWV_FLOW_DEEPSEC
  -> SYS.DBMS_SYS_SQL.parse_as_user             undocumented, no grant to anybody
  -> statement parsed as the parsing schema     name resolution + privileges of that
                                                schema (workspace <-> schema mapping:
                                                APEX_260200.WWV_FLOW_COMPANY_SCHEMAS)
```

- **Why APEX needs an object in SYS:** `DBMS_SYS_SQL` ("parse as another
  user") has **no grant at all** on the test host – only SYS can call it.
  So `apexins` creates a SYS-owned wrapper and locks it down with
  `accessible by` to four APEX packages. That wrapper is the one place
  where APEX "switches" into the application schema.
- **One wrapper per release:** the package carries the APEX schema name
  (`WWV_DBMS_SQL_APEX_260200`), so an old and a new release can live side by
  side during an upgrade – each engine calls its own wrapper.
- The same wrapper also holds `kill_session`, `fetch_credential_info` (web
  credentials) and, on DB 21+, `create_mle_context_as_user` (JavaScript /
  MLE in the parsing schema).
- The bodies of `F`, `WWV_FLOW` and the SYS wrappers are **wrapped** – the
  order of calls *inside* them is an **assumption** taken from the
  dependencies. Live proof once ORDS runs: after a page call
  `v$sql.parsing_schema_name` shows the application schema for the page SQL
  (or `dbms_hprof` on one request).
- **Wrapped code:** the 10g+ wrap format is only encoded and compressed,
  tools exist to decode it – but the Oracle license forbids reverse
  engineering, and decoded Oracle code never belongs into this repository.
  Everything on this page comes from clear specs, the dictionary and the
  install scripts of the zip.

---

## 5b. APEX objects outside the APEX schema – removal and export / import

`apexins` creates objects **outside** `APEX_260200` (**confirmed (live)**
2026-10-23, `dba_objects` / `dba_synonyms` / `dba_users`):

| Object | Owner | Per release? | Purpose |
|---|---|---|---|
| `WWV_DBMS_SQL_APEX_260200` | SYS | **yes** | parse as the application schema (section 5a), kill session, credentials |
| `WWV_UTIL_APEX_260200` | SYS | **yes** | utility functions of the engine |
| `WWV_FLOW_KEY`, `WWV_FLOW_VAL` + library `WWV_FLOW_VAL_LIB`, procedure `VALIDATE_APEX` | SYS | no – **shared** | key handling / validation, registry validation |
| context `APEX$SESSION` | SYS | no – shared | session context of the engine |
| public synonyms `F`, `WWV_FLOW`, `APEX_UTIL`, … | PUBLIC | point to the current release | URL entry and API names |
| users `FLOWS_FILES`, `APEX_PUBLIC_USER`, `APEX_REST_PUBLIC_USER`, `APEX_PUBLIC_ROUTER`, roles `APEX_ADMINISTRATOR_ROLE` … | – | no – shared | files, gateway / REST / router accounts |
| proxy right `APEX_REST_PUBLIC_USER` → `APEX_PUBLIC_USER` | – | – | created by `apex_rest_config.sql` (seen in `proxy_users` before ORDS was installed) |

All APEX users and the SYS objects are **`oracle_maintained = Y`** – they
are created under `_ORACLE_SCRIPT=true`, like Oracle's own schemas.

### Remove a release only with the remove script of the same release

What `apxremov.sql` of the 26.2 zip does (read 2026-10-23, **documented** by
the script itself):

1. `core/scripts/set_appun.sql` contains a **hard-coded** `define APPUN =
   'APEX_260200'` – the remove script of a zip knows only **its own** release
   schema and its own SYS wrappers (`drop package WWV_DBMS_SQL_^APPUN`,
   `WWV_UTIL_^APPUN`). The 26.2 script cannot remove an APEX 24.2 schema –
   it would aim at `APEX_260200`.
2. It switches on `_ORACLE_SCRIPT=true` – needed because the objects are
   Oracle-maintained; a plain `DROP USER` by the DBA is not the intended way.
3. Besides `drop user APEX_260200 cascade` it cleans what a `DROP USER`
   leaves behind: the public synonyms of the release
   (`wwv_flow_upgrade.drop_public_synonyms`), the release's objects in
   `FLOWS_FILES`, the REST definitions of `APEX_PUBLIC_ROUTER` in
   `ORDS_METADATA` (`ords_admin.drop_rest_for_schema`), the two SYS wrappers
   and the entry in `SYS.KU_NOEXP_TAB`.
4. **Shared objects only when it is the last release:**
   `set_ufrom_and_upgrade.sql` looks for an **older** APEX schema
   (`APEX_xxxxxx < APPUN` that owns `WWV_FLOWS`). Found → `UPGRADE = 2` →
   the shared users, roles, context and `WWV_FLOW_KEY` / `WWV_FLOW_VAL` stay
   (the older release still needs them). Not found → `UPGRADE = 1` → they
   are dropped too, **including `FLOWS_FILES` with all uploaded files**.

Consequences:
- **Roll back a failed upgrade:** run `apxremov.sql` of the **new** release –
  it removes only the new schema and its wrappers and keeps the shared
  objects for the old release (then point the image link back).
- **Drop the old schema after a successful upgrade** (`APEX_240200` next to
  `APEX_260200`): its own `apxremov` would find no older schema → `UPGRADE =
  1` → would drop the shared objects that the **new** release uses.
  Instead: the documented "remove prior installation" steps – `drop user
  APEX_240200 cascade` plus the two SYS packages of **that** release
  (`WWV_DBMS_SQL_APEX_240200`, `WWV_UTIL_APEX_240200`). **Assumption** from
  the 26.2 scripts – check the remove section of the 26.2 installation guide
  and the old zip before the first real clean-up.
- **Remove APEX completely:** `apxremov.sql` of the installed release, with
  `FLOWS_FILES` / application exports saved first.

### Why APEX does not move with a Data Pump schema export

- `SYS.KU_NOEXP_TAB` – Data Pump's list of schemas **never exported** –
  contains `APEX_260200`, `FLOWS_FILES`, `APEX_PUBLIC_USER`,
  `APEX_REST_PUBLIC_USER`, `APEX_PUBLIC_ROUTER` and every older APEX / FLOWS
  schema name (**confirmed (live)** 2026-10-23). A schema or full export
  silently skips the APEX engine and its metadata.
- Even a forced copy would be incomplete: the SYS wrappers, the shared SYS
  packages, the context and the public synonyms live outside the schema.
- **What works:**
  - the whole PDB (unplug / plug, clone, RMAN) – the APEX instance moves
    with everything;
  - a new APEX installation in the target (same release) plus the
    applications / workspaces exported with SQLcl `apex export` and imported
    again – the application schemas themselves move with Data Pump as usual.
- For [clone_golden_image.md](clone_golden_image.md): APEX belongs to the
  database side – it moves with the PDB, never with a schema export.

---

## 6. REST services through ORDS

Structure in `ORDS_METADATA` (**documented**):

```
schema (REST-enabled, alias in the URL)
  └── module   base path  /orders/
        └── template      :id
              └── handler GET / POST / PUT / DELETE  ->  SQL query or PL/SQL block
URL: https://<host>/ords/<schema alias>/orders/42
```

- `ords.enable_schema` (alias, auth), `ords.define_module` / `define_template`
  / `define_handler`, or the REST workshop in SQL Developer Web / APEX.
- **Protection:**
  - a **role** (`ords.create_role`) and a **privilege** (`ords.define_privilege`) map URL patterns (`/import/*`) to the role – without a privilege a module is public.
  - **OAuth2 client credentials** for machine callers (author's wiki, ORDS 26):
    1. `ORDS_SECURITY.REGISTER_CLIENT` (grant type `client_credentials`);
    2. `ORDS_SECURITY.GRANT_CLIENT_ROLE`;
    3. `ORDS_SECURITY.ROTATE_CLIENT_SECRET` – shows the secret **once**;
    4. token: `POST /ords/<schema>/oauth/token` with Basic auth `client_id:secret`, then `Authorization: Bearer <token>` (default lifetime 1 h).
  - The older `OAUTH` / `OAUTH_ADMIN` packages are deprecated (since 24.3) – the wiki is contradictory about their state in 26.x, so check against the 26.3 guide before using them.
- **REST call inside an APEX session** (document download from a logged-in
  APEX page, no `Authorization` header possible):
  - the URL carries the APEX session (`?_apex_session=<app>,<session>`);
  - the handler checks it and runs `apex_session.attach(app, 0, session)`, so that `APP_USER` and the session state are available;
  - it returns the document;
  - it **always** runs `apex_session.detach` – also in the error path, because the pooled connection is reused for the next request;
  - limits: the session id in the URL shows up in logs / `Referer` (use `Referrer-Policy: no-referrer`, short idle timeout, check the client IP).
  - Source: the author's wiki, section 9.

---

## 7. Fit with the rest of this library

| Topic | Rule |
|---|---|
| Ports / clone | ORDS on `127.0.0.1` only, Nginx is the one door ([clone_golden_image.md](clone_golden_image.md)) |
| Oracle Net | pool via TNS alias from `TNS_ADMIN` – the same directory as Forms / Reports |
| Java | `JDK_HOME` (Oracle JDK 21; ORDS 26.3 supports 17, 21, 25) |
| Versions | ORDS ≥ APEX; one APEX schema per release (`APEX_260200`); images per version in `/srv/apex/APEX_<ver>` |
| Downloads | `09-Install/04-oracle_pre_download.sh` (OTN "latest" ZIPs, APEX patch via getMOSPatch platform `2000P` Generic – confirmed live 2026-10-23) |
| Database users | `ORDS_PUBLIC_USER`, `APEX_REST_PUBLIC_USER` (and `APEX_PUBLIC_ROUTER`) must stay open – an expiring password stops APEX (profile like `RCU_USER`, [rcu_middleware_architecture.md](rcu_middleware_architecture.md) §6.1) |

---

## 8. History (short)

| Year | Step |
|---|---|
| 1990s | Oracle Web Server / Web Application Server with the PL/SQL cartridge, then **mod_plsql** in Oracle HTTP Server – the PL/SQL web toolkit (`htp`, `owa_util`) that APEX still uses |
| 2004 | **HTML DB** 1.5 (internal project "Flows" / "Marvel") – the origin of `FLOWS_FILES` and `wwv_flow` |
| 2006 | renamed **Oracle Application Express** (APEX 2.1); access through mod_plsql or the Embedded PL/SQL Gateway (EPG, 11g) |
| 2010 | **APEX Listener** – a Java alternative to mod_plsql (WebLogic / GlassFish / standalone) |
| ~2014 | APEX Listener becomes **Oracle REST Data Services**: RESTful services, repository `ORDS_METADATA`; mod_plsql is deprecated in OHS 12c |
| 2018 | year-based versions (APEX 18.1, ORDS 18.x) |
| 2022 | ORDS 22: new `ords` command line, one configuration directory (`databases/`, `global/`), Jetty standalone as the normal mode |
| 2026 | APEX 26.x (APEXlang, needs a matching ORDS), ORDS 26.x with MCP support; ORDS 26.4 drops Tomcat 9 (standalone unaffected) |

The history rows are background from the author's experience and Oracle's
release notes (**documented** only where a source of section 9 says so –
the dates before 2018 are **assumption** to the year).

---

## 9. Sources

All checked 2026-10-23 (HTTP 200, title matches):

- Oracle APEX Release 26.2 – documentation library –
  <https://docs.oracle.com/en/database/oracle/apex/26.2/>
- Oracle APEX 26.2 Installation Guide –
  <https://docs.oracle.com/en/database/oracle/apex/26.2/htmig/>
- APEX 26.2 Installation Guide – About APEX Database Accounts –
  <https://docs.oracle.com/en/database/oracle/apex/26.2/htmig/about-apex-database-accounts.html>
- APEX 26.2 Installation Guide – Downloading and Installing APEX
  (APEX_PUBLIC_USER without authentication, APEX_PUBLIC_ROUTER) –
  <https://docs.oracle.com/en/database/oracle/apex/26.2/htmig/downloading-installing-apex.html>
- APEX 26.2 Installation Guide – Configuring Oracle REST Data Services
  (`apex_rest_config.sql` for static files, `requestValidationFunction`) –
  <https://docs.oracle.com/en/database/oracle/apex/26.2/htmig/configuring-ords.html>
- Oracle APEX 26.2 Administration Guide –
  <https://docs.oracle.com/en/database/oracle/apex/26.2/aeadm/>
- Oracle REST Data Services 26.3 – Get Started –
  <https://docs.oracle.com/en/database/oracle/oracle-rest-data-services/26.3/>
- ORDS 26.3 Installation and Configuration Guide –
  <https://docs.oracle.com/en/database/oracle/oracle-rest-data-services/26.3/ordig/>
- ORDS 26.3 Developer's Guide (REST modules, privileges, OAuth) –
  <https://docs.oracle.com/en/database/oracle/oracle-rest-data-services/26.3/orddg/>
- ORDS 21.3 – Creating Customer Managed Oracle REST Data Services User (proxy
  grants, `GRANT CONNECT THROUGH`, warning without a gateway user) –
  <https://docs.oracle.com/en/database/oracle/oracle-rest-data-services/21.3/aelig/creating-customer-managed-ords-user-role-autonomous-database.html>
- Oracle APEX Downloads (26.2, patch set bundles) –
  <https://www.oracle.com/tools/downloads/apex-downloads.html>
- ORDS Download (26.3, supported Java) –
  <https://www.oracle.com/database/sqldeveloper/technologies/db-actions/download/>
- Gunther Pipperr – APEX 26 / ORDS 26: OAuth2 client credentials and the APEX
  session in REST calls –
  <https://pipperr.de/dokuwiki/doku.php?id=prog:oracle_apex_26_ords_26_oauth_apex_session>
- Gunther Pipperr – APEX 26.1 with ORDS 26.1 standalone and Nginx on OL9 –
  <https://pipperr.de/dokuwiki/doku.php?id=prog:oracle_apex_26_1_ords_standalone_nginx_ol9>
- MOS Doc ID 2770463.1 (ORDS 503, pool user not authorized to proxy) – title only.
