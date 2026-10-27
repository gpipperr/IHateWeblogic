# RCU and the FMW repository – what it is, who uses it, how it is patched

Theory collection for phase 8 ("repository-schema patching"): what the
Repository Creation Utility (RCU) creates in the database, which processes
log in to which schema, where the schema passwords are stored, what the
schema version registry is – and whether a patch such as the September 2026
CSPU ever touches the schemas.

Short answer: **regular patches (SPB, CSPU, Forms/Reports one-offs) change
only the Oracle Home – the RCU schemas stay as they are.** Schemas are only
changed by the **Upgrade Assistant** (`ua`) during a version upgrade (e.g.
12.2.1.4 → 14.1.2). There are no patch sets and no Patch Set Assistant any
more since 12c.

Markers as in [README.md](README.md): **confirmed (live)** = test domain
2026-10-17 (prefix `DEV`, Oracle 19c PDB), **documented** = Oracle
documentation ([Sources](#10-sources)), **assumption** = not verified.
Overview of the domain itself: [weblogic_middleware_architecture.md](weblogic_middleware_architecture.md).

---

## 1. Terms

| Term | What it is |
|---|---|
| **RCU** (tool) | `$ORACLE_HOME/oracle_common/bin/rcu` – Java tool that **creates and drops** schemas (`-createRepository`, `-dropRepository`). Part of the Oracle Home, so it is patched like any other binary (the WLS SPB 14.1.2.0.260825 contains RCU fix 38391376 "RCU prereq steps fails while trying to validate the DB connection" – **confirmed (live)**, `opatch lspatches`, SPB README) |
| **Repository** | the set of schemas of one **prefix** (`DEV_STB`, `DEV_OPSS` …) in one database |
| **Prefix** | groups the schemas of one domain; one database can hold several prefixes (several domains) |
| **Schema version registry** | `SYSTEM.SCHEMA_VERSION_REGISTRY$` – one row per FMW schema of every prefix in this database (section 4) |
| **Service table** (`<prefix>_STB`) | "phone book" of the prefix: which component lives in which schema, incl. encrypted passwords (section 5) |
| **Upgrade Assistant** (UA) | `$ORACLE_HOME/oracle_common/upgrade/bin/ua` – upgrades schemas and domain component configuration in place on a **version upgrade** (section 7) |
| **Patch Set Assistant** (PSA) | 11g only – updated schemas after an 11g patch set (11.1.1.x → 11.1.1.y). Not shipped any more (**confirmed (live)**: no `psa` in the 14.1.2 Oracle Home) |
| **OPSS** | Oracle Platform Security Services – the security layer of all FMW Java components (section 1.1); its data lives in the RCU schema `<prefix>_OPSS` |
| **JPS** | Java Platform Security – the internal name of OPSS (packages `oracle.security.jps.*`, files `jps-config*.xml`); successor of the 10g "JAZN" (Java AuthoriZatioN) – hence `system-jazn-data.xml`, subscriber `jazn.com` |

### 1.1 OPSS / JPS – `jps-config.xml`, `jps-config-jse.xml` and the LDAP question

OPSS bundles several **services**; a JPS configuration file says which
implementation ("service instance") each service uses. Every JVM of the
domain reads one of two files in `$DOMAIN_HOME/config/fmwconfig/`
(**confirmed (live)**, default context of both files):

| Service | What it holds | `jps-config.xml` (WebLogic JVMs: AdminServer, WLS_FORMS, WLS_REPORTS) | `jps-config-jse.xml` (Java SE JVMs: standalone Reports server `rwserver`, WLST offline, tools) |
|---|---|---|---|
| policy store | application roles (`RW_MONITOR`, `RW_EXECREPORTS`, `RW_ADMINISTRATOR` …) and grants (`ReportsPermission`, `WebCommandPermission`) | `policystore.db` → schema `DEV_OPSS` | `policystore.db` → `DEV_OPSS` (same data) |
| credential store | credential maps/keys, e.g. `reports.idstore`/`embeddedldap` (`createCred`) | `credstore.db` → `DEV_OPSS` | `credstore.db` → `DEV_OPSS` |
| keystore service | KSS keystores (`keystores.xml`) | `keystore.db` → `DEV_OPSS` | `keystore.db` → `DEV_OPSS` |
| audit | audit framework | `audit.db` → `DEV_IAU*` | `audit.db` |
| **identity store** | **users and groups** – who is `monUser`, which groups he has | `idstore.ldap` with `WlsLdapIdStoreConfigProvider` = **the authenticators of the WebLogic realm `myrealm`** (DefaultAuthenticator = embedded LDAP of the AdminServer) | Oracle default: `idstore.xml` = file `system-jazn-data.xml` (subscriber `jazn.com`, knows **no** WebLogic user). Here since 2026-10-16: `idstore.ldap.embedded` (`OPEN_LDAP`, `ldap://localhost:7001`, `ou=myrealm,dc=fr_domain`) |
| bootstrap | how to reach the OPSS DB itself (JDBC URL + credential) | `datasource.jndi.name=jdbc/OpssDataSource` + bootstrap wallet | `jdbc.url` + bootstrap wallet `bootstrap/cwallet.sso` (no data source in Java SE) |

```
              policy + credential + key store: ONE copy, in the database
                         +------------------------------+
                         |  DEV_OPSS  (RCU schema)      |
                         +---------------^--------------+
                                         | JDBC (bootstrap wallet cwallet.sso)
              +--------------------------+---------------------------+
              |                                                      |
   jps-config.xml (WebLogic JVM)                      jps-config-jse.xml (Java SE JVM)
   AdminServer / WLS_FORMS / WLS_REPORTS              rwserver repserver01, WLST offline
              |                                                      |
   identity store: idstore.ldap                        identity store (Oracle default):
   -> WebLogic realm "myrealm"                         idstore.xml = system-jazn-data.xml
      DefaultAuthenticator                               -> knows NO WebLogic users
      = embedded LDAP in the AdminServer               identity store (here, since 2026-10-16):
        (ldap://localhost:7001,                        idstore.ldap.embedded
         ou=people,ou=myrealm,dc=<domain>)  <---------  -> the SAME embedded LDAP via
                                                          ldap://localhost:7001, bind as
                                                          cn=Admin (credential reports.idstore)
```

Why this matters here:

- **Roles and grants are shared, users are not (by default).** A role
  assignment made in EM is stored once in `DEV_OPSS` and seen by every JVM;
  but whether a user *exists* is answered by the identity store of the JVM
  that asks. The standalone Reports server with the default `idstore.xml`
  therefore does not know `monUser` → with `securityId` REP-50171 "user does
  not exist". Pointing its identity store to the embedded LDAP fixes it –
  [reports_user_local_ldap.md](reports_user_local_ldap.md),
  `09-Install/13-oracle_setup_reports.sh` (`REPORTS_SECURITY=ldap`).
- The **embedded LDAP** is a small LDAP server inside the AdminServer
  (port = admin port 7001, base `dc=<domain>`); WebLogic users/groups of
  `myrealm` live there, administrator `cn=Admin`. It is **not** an RCU
  schema – it is stored in `servers/AdminServer/data/ldap/ldapfiles/`, the
  managed servers keep a replica in `servers/<ms>/data/ldap/`
  (**confirmed (live)**). AdminServer down = the standalone Reports server
  cannot authenticate anybody (it binds to the AdminServer's LDAP port).
- **libOVD** (Oracle Virtual Directory library) is the layer OPSS/EM use to
  search the identity store as one virtual LDAP (`config/fmwconfig/ovd/`);
  the EM "Add Principal" search goes through it –
  [em_principal_search_libovd.md](em_principal_search_libovd.md).
- **RCU relation:** only the policy/credential/key/audit data are in RCU
  schemas (`DEV_OPSS`, `DEV_IAU*`); the identity data (users, passwords,
  groups) are **not** – they are in the embedded LDAP (or an external LDAP/AD
  configured as authenticator). A repository move therefore moves roles and
  credentials, not users.

---

## 2. The schemas of a Forms/Reports domain

Created by `09-Install/07-oracle_setup_repository.sh`
(`RCU_COMPONENTS=(STB MDS OPSS IAU IAU_APPEND IAU_VIEWER UCSUMS WLS)`).
**confirmed (live)**, `SCHEMA_VERSION_REGISTRY` and `config/jdbc/*.xml`:

| COMP_ID | Schema | Purpose | Used at runtime by (data source) |
|---|---|---|---|
| `STB` | `DEV_STB` | Service table (section 5) | `LocalSvcTblDataSource` |
| `OPSS` | `DEV_OPSS` | OPSS policy, credential and key store (application roles `RW_*`, `createCred` entries, keystores) | `opss-data-source` (`jdbc/OpssDataSource`); standalone Reports server directly via `jps-config-jse.xml` |
| `IAU` | `DEV_IAU` | audit data (owner) | – (owner schema) |
| `IAU_APPEND` | `DEV_IAU_APPEND` | writes audit records | `opss-audit-DBDS` |
| `IAU_VIEWER` | `DEV_IAU_VIEWER` | reads audit records (reports) | `opss-audit-viewDS` |
| `WLS` | `DEV_WLS` | WebLogic persistence (JDBC/JMS stores, leasing, …) | `WLSSchemaDataSource` |
| `WLS_RUNTIME` | `DEV_WLS_RUNTIME` | WebLogic runtime data | `WLSRuntimeSchemaDataSource` |
| `MDS` | `DEV_MDS` | Metadata Services repository | **no data source** in this domain |
| `UCSUMS` | `DEV_UMS` | User Messaging Service | **no data source** in this domain |

All schemas: version `14.1.2.0.0`, status `VALID`, `UPGRADED=N`, default
tablespace `FMW_DATA` (`60-RCU-DB-19c/07-db_fmw_tablespace.sh`).

### 2.1 The schemas and their users at a glance

```
                       Repository of prefix DEV  (one PDB, tablespace FMW_DATA)
 +------------------------------------------------------------------------------------+
 |                                                                                    |
 |  DEV_STB  "phone book"                SYSTEM.SCHEMA_VERSION_REGISTRY$  "registry" |
 |   COMPONENT_SCHEMA_INFO               one row per schema: COMP_ID, OWNER,         |
 |   (schema, host, service,             VERSION, STATUS - read by RCU (drop),       |
 |    encrypted password)                UA (upgrade), every schema user (SELECT)    |
 |      ^          ^                                    ^            ^               |
 |      |          |                                    |            |               |
 |  DEV_OPSS     DEV_IAU (owner)   DEV_WLS      DEV_MDS     DEV_UMS                  |
 |  security     |- DEV_IAU_APPEND  DEV_WLS_     metadata   messaging                 |
 |  store        |   (write)        RUNTIME      (unused)   (unused)                  |
 |               +- DEV_IAU_VIEWER  persistence                                       |
 |                   (read)                                                           |
 +-----^-------------^--------------^--------------------------------------------------+
       |             |              |
       |             |              +-- AdminServer, WLS_FORMS, WLS_REPORTS:
       |             |                  WLSSchemaDataSource / WLSRuntimeSchemaDataSource
       |             |                  (JDBC/JMS stores, leasing, runtime data)
       |             |
       |             +-- all WebLogic servers: audit framework writes via
       |                 opss-audit-DBDS (IAU_APPEND), audit reports read via
       |                 opss-audit-viewDS (IAU_VIEWER)
       |
       +-- AdminServer, WLS_FORMS, WLS_REPORTS: opss-data-source
       |     application roles RW_MONITOR / RW_EXECREPORTS, credential maps
       |     (reports.idstore), keystores, EM "Application Roles"
       +-- rwserver repserver01 (Java SE): jps-config-jse.xml JDBC + bootstrap wallet
       +-- WLST grantAppRole / createCred, EM security pages

 DEV_STB: read by the Configuration Wizard / WLST createDomain (once, to build the
          data sources) and by LocalSvcTblDataSource in the running domain.
 DEV_MDS / DEV_UMS: created by RCU for the Infrastructure template, no data source
          in a pure Forms/Reports domain (confirmed live) - empty but must stay
          consistent with the registry.
```

| Schema | Created by | Written by | Read by | If unavailable |
|---|---|---|---|---|
| `DEV_STB` | RCU | RCU | Config Wizard / WLST at domain creation, `LocalSvcTblDataSource` | new domain / domain extension cannot read the RCU configuration |
| `DEV_OPSS` | RCU | EM, WLST (`grantAppRole`, `createCred`), OPSS | every server + standalone Reports server | servers do not start (OPSS bootstrap), no roles/credentials |
| `DEV_IAU_APPEND` / `_VIEWER` | RCU | audit framework | audit reports | audit records lost / errors in the server log (**assumption**) |
| `DEV_WLS` / `_WLS_RUNTIME` | RCU | WebLogic | WebLogic | persistent stores / leasing fail (**assumption** for the exact effect) |
| `DEV_MDS`, `DEV_UMS` | RCU | – | – (here) | no effect at runtime here (**confirmed (live)**: no data source) |

---

## 3. Who logs in where

```
  Oracle Home (software)                         Domain Home (configuration)
  +----------------------------+                 +----------------------------------------+
  | oracle_common/bin/rcu      |  create / drop  | config/jdbc/*-jdbc.xml                 |
  |  (SYSDBA, one-time)        |---------+       |   user + {AES256} password per DS      |
  | oracle_common/upgrade/bin/ |         |       | config/fmwconfig/jps-config.xml        |
  |  ua  (version upgrade)     |----+    |       | config/fmwconfig/jps-config-jse.xml    |
  +----------------------------+    |    |       | config/fmwconfig/bootstrap/cwallet.sso |
                                    |    |       +-------------------+--------------------+
                                    |    |                           | read at start
                                    v    v                           v
 +-----------------------------------------------------------------------------------------+
 | AdminServer / WLS_FORMS / WLS_REPORTS (JDBC data sources, connection pools)              |
 |   opss-data-source ---------------------------------------------------> DEV_OPSS         |
 |   opss-audit-DBDS / opss-audit-viewDS -----------------> DEV_IAU_APPEND / DEV_IAU_VIEWER |
 |   WLSSchemaDataSource / WLSRuntimeSchemaDataSource ------> DEV_WLS / DEV_WLS_RUNTIME     |
 |   LocalSvcTblDataSource ----------------------------------------------> DEV_STB          |
 |                                                                                          |
 | rwserver repserver01 (Java SE, no data source):                                         |
 |   jps-config-jse.xml jdbc.url + bootstrap credential (cwallet.sso) -----> DEV_OPSS       |
 |                                                                                          |
 | Configuration Wizard / WLST createDomain (one-time):                                     |
 |   reads DEV_STB.COMPONENT_SCHEMA_INFO -> fills all data sources                          |
 +-----------------------------------------------------------------------------------------+
                                    |
                                    v
 +-----------------------------------------------------------------------------------------+
 | Database (PDB)                                                                           |
 |   DEV_STB  DEV_OPSS  DEV_IAU*  DEV_WLS*  DEV_MDS  DEV_UMS        (profile DEFAULT)       |
 |   SYSTEM.SCHEMA_VERSION_REGISTRY$  (+ view, public synonym, role REGISTRYACCESS)         |
 |   application schemas of Forms/Reports - NOT RCU, own credentials                        |
 +-----------------------------------------------------------------------------------------+
```

- The application data of Forms and Reports (`userid=` of a form/report) is
  **not** part of the repository – it is ordinary DB users.
- The standalone Reports server reads OPSS directly over JDBC (URL in
  `jps-config-jse.xml`, user/password from the bootstrap wallet) – that is
  why it sees the same application roles and credentials as the WebLogic
  servers ([reports_user_local_ldap.md](reports_user_local_ldap.md)).

---

## 4. The schema version registry – `SYSTEM.SCHEMA_VERSION_REGISTRY$`

**confirmed (live)**:

| Object | Owner | Type |
|---|---|---|
| `SCHEMA_VERSION_REGISTRY$` | `SYSTEM` | table (the data) |
| `SCHEMA_VERSION_REGISTRY` | `SYSTEM` | view on the table, `ORDER BY comp_id` |
| `SCHEMA_VERSION_REGISTRY` | `PUBLIC` | synonym |
| `REGISTRYACCESS` | – | role with SELECT/INSERT/UPDATE/DELETE on table and view |

Columns: `COMP_ID`, `COMP_NAME`, `MRC_NAME` (prefix), `MR_NAME`, `MR_TYPE`,
`OWNER`, `VERSION`, `STATUS`, `CUSTOM1/2`, `EDITION`, `UPGRADED`,
`START_TIME`, `MODIFIED`, `BACKUP` (CLOB). Every schema user of the prefix
has SELECT on the view.

- RCU creates the table "if it is not already present" in the **system load**
  phase and adds one row per component (status `LOADED`, later `VALID`).
  The mapping prefix → schemas is kept here. (**documented**, RCU guide
  "System Load and Product Load", "About Custom Prefixes")
- The table is created **once per database** and outlives the schemas: on
  the test host it dates from 2026-03-24, the current schemas from
  2026-10-15 (drop + recreate during the rebuild). (**confirmed (live)**)
- RCU writes and deletes the rows through the Java class
  `oracle.ias.version.SchemaVersionUtil` (`utilCreateRegistryEntry`,
  `utilDropRegistryEntry`); for a drop it first reads "existing components
  for prefix" from the registry, then runs `DROP USER …`, then deletes the
  rows. (**confirmed (live)**, `/tmp/RCU<timestamp>/logs/rcu.log`)
- Oracle requires a backup of **`SYSTEM.SCHEMA_VERSION_REGISTRY$`** before
  every Upgrade Assistant run – a failed UA run must be rolled back with it.
  (**documented**, Upgrading to the FMW Infrastructure 14c, "Backing Up the
  Schema Version Registry Table")

### 4.1 Damaged or missing registry (case of a colleague)

Reported: RCU showed no prefix, threw confusing Java exceptions and the old
repository could not be dropped – a problem for every move/rebuild. No logs
available. Remembered later (2026-10-17): the **view
`SYSTEM.SCHEMA_VERSION_REGISTRY` and its grants were gone**, the table was
still there. The colleague creates his repositories as database type
"Oracle Database" (non-EBR), the author always as "Oracle Database enabled
for edition-based redefinition" (EBR) – suspicion: EBR/non-EBR mixing
breaks the view (see 4.3).

What follows from the facts above:

- RCU builds its list of droppable prefixes/components **only** from the
  registry (live log). Without the table or without the rows of a prefix,
  `-dropRepository` cannot select the schemas → consistent with the report.
  (**assumption** for the exact error; the mechanism is **confirmed (live)**)
- Upgrade Assistant and the readiness check read the same registry – a
  version upgrade would fail as well. (**documented** – UA verifies against
  `schema_version_registry`)
- Typical ways to lose it (**assumption**): a DB export/import of only the
  `<prefix>_*` users onto a new database (the table belongs to `SYSTEM`),
  cleanup scripts that drop "unknown" `SYSTEM` objects, a PDB clone/refresh
  from a database without FMW.
- Prevention: back up the table together with the schemas, e.g.
  `expdp … TABLES=SYSTEM.SCHEMA_VERSION_REGISTRY$` (plus the `<prefix>_*`
  schemas) – especially before a move.
- With the view/grants missing but the table present (the colleague's
  case): RCU creates the registry only "if it is not already present"
  (**documented**) – if that check looks at the table only, a missing view
  is never re-created and every schema user loses its `SELECT` on
  `SCHEMA_VERSION_REGISTRY`. (**assumption**, not testable without breaking
  the registry – only on a disposable database)
- Without registry the schemas can still be removed manually (as SYSDBA:
  `DROP USER <prefix>_… CASCADE` per schema, then the RCU tablespaces) –
  RCU is not needed for that. Re-inserting registry rows by hand is not
  documented by Oracle – check MOS before doing it. (**assumption**, to be
  tested on the test host if needed)

### 4.2 `db_securefile=FORCE` – the first RCU run fails

Reported by a colleague: with the database parameter `db_securefile` set to
"always SecureFile" RCU does not work, because the registry must not be
created that way in the `SYSTEM` tablespace.

Facts (**confirmed (live)** 2026-10-17, test PDB):

- The registry table lives in tablespace **`SYSTEM`**, which uses **manual
  segment space management** (`SEGMENT_SPACE_MANAGEMENT = MANUAL`, no ASSM);
  its column `BACKUP` is a CLOB stored as **BasicFile** (`SECUREFILE = NO`).
  All 297 LOBs of the `DEV_*` schemas (tablespace `FMW_DATA`, ASSM) are
  SecureFiles.
- SecureFile LOBs require an ASSM tablespace. Test with a scratch table
  `(id NUMBER, backup CLOB) TABLESPACE SYSTEM` (dropped afterwards):

| `db_securefile` (session) | Result |
|---|---|
| `PREFERRED` (default since 12c, test DB) | created, LOB = BasicFile |
| `ALWAYS` | created, LOB = **BasicFile** – Oracle falls back silently in a non-ASSM tablespace |
| `FORCE` | **ORA-43853: SECUREFILE lobs cannot be used in non-ASSM tablespace "SYSTEM"** |
| `ALWAYS` + explicit `LOB (…) STORE AS SECUREFILE` | **ORA-43853** |

Consequences:

- The setting that breaks RCU is **`FORCE`** (hardening guides often call it
  "always SecureFile"); `ALWAYS` itself is harmless here.
- It hits the **first** RCU run in a database (the registry is only created
  "if not already present"); a database that already has a registry is not
  affected for the registry itself. (**assumption**: the RCU schemas in an
  ASSM tablespace like `FMW_DATA` are fine with `FORCE`; a prefix whose
  default tablespace is not ASSM would fail as well)
- A first RCU run that broke off while creating the registry is one way to
  end up with the "missing registry" of section 4.1. (**assumption**)
- Fix (DBA): `ALTER SYSTEM SET db_securefile=PREFERRED;` at least for the
  first RCU run (can be set back to `FORCE` afterwards – the existing
  BasicFile registry keeps working, see the test above).
- Pre-checks in this repository: `09-Install/07-oracle_setup_repository.sh`
  (FAIL with `FORCE` and no registry yet, WARN with `FORCE` and an existing
  registry), `60-RCU-DB-19c/07b-db_rcu_profile.sh` and
  `rcu_registry_overview.sql` (line `IHW:SECUREFILE|…`). Our own DB creation
  (`60-RCU-DB-19c/05-db_create_database.sh`) does not set the parameter
  (default `PREFERRED`).

Check (as DBA):

```sql
SELECT value FROM v$parameter WHERE name = 'db_securefile';
SELECT segment_space_management FROM dba_tablespaces WHERE tablespace_name = 'SYSTEM';
```

### 4.3 Database type EBR vs. ORACLE – and what "default" means

RCU knows two Oracle database types: `ORACLE` ("Oracle Database") and `EBR`
("Oracle Database enabled for edition-based redefinition"). The type decides
which SQL scripts run (`common/sql/<comp>/sql/` vs. `…/oracle_ebr/`) and
whether the schema users are editions-enabled.

**confirmed (live)** 2026-10-17 – same database, same Oracle Home:

| RCU call | SQL used | `EDITIONS_ENABLED` | Registry `EDITION` |
|---|---|---|---|
| our `07-oracle_setup_repository.sh` (**no** `-databaseType`), prefix `DEV` | `…/oracle_ebr/` (`ALTER USER … ENABLE EDITIONS`), log: "Default edition ORA$BASE in the database will be used" | `Y` | `ORA$BASE` |
| scratch test `-databaseType ORACLE`, prefix `ZZT` (STB + WLS, dropped afterwards) | `…/sql/` | `N` | empty |

- **Silent RCU without `-databaseType` produced an EBR repository** on this
  19c database. The GUI default of the "Database Type" list was not checked
  (no display) – "keep the default" therefore means different things in
  silent and GUI mode. (**assumption** for the GUI)
- Both types in one database are **supported**: the registry, its view and
  the grants are shared (`ZZT` and `DEV` coexisted, view unchanged).
  (**confirmed (live)**)
- Oracle itself prescribes both types in one database for Oracle Access
  Manager (OAM) and Oracle Internet Directory (OID). (**documented**)
  - Source: *Creating Schemas with the Repository Creation Utility* 14c
    (14.1.2), chapter "Obtaining and Running Repository Creation Utility",
    section **"Creating Schemas for Oracle Access Manager and Oracle
    Internet Directory"**:
    https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/rcuug/obtaining-and-running-repository-creation-utility.html#GUID-7C47260C-8755-4E50-A03D-9D11C8438F5A
    (checked 2026-10-17, HTTP 200, anchor present)
  - Quote: *"IDM schemas do not support EBR, so you must invoke RCU twice
    when creating schemas. When you invoke RCU the first time, select the
    Database type as Oracle Database enabled for edition-based redefinition
    and load the EBR-dependent components. When you invoke RCU the second
    time, select Database type as Oracle Database and load IDM schemas."*
  - For a pure Forms/Reports domain this does not apply (no IDM schemas) –
    it is the proof that EBR and non-EBR prefixes are meant to coexist in
    one database.
- The view `SYSTEM.SCHEMA_VERSION_REGISTRY` is a normal, **non-editionable**
  view (`EDITIONING_VIEW = N`, `EDITIONABLE = N`) – `SYSTEM` is not
  editions-enabled (Oracle-maintained user). It cannot become an editioning
  view, so "the view was created as editioning view and cannot be replaced"
  is unlikely for the registry view itself; how the colleague's view got
  lost remains open (4.1). (**confirmed (live)** for the view properties)
- Upgrade Assistant: "Verify that the EDITION NAME column appears as
  ORA$BASE" after a schema upgrade (**documented**, Upgrading to the FMW
  Infrastructure 14c) – i.e. EBR is the state Oracle expects for upgraded
  schemas.
- The type of an existing prefix cannot be switched – only drop + recreate.

Rule for this repository (decision 2026-10-17): **one type per
installation, chosen explicitly – default `EBR`** – not "whatever the tool
picks":

- `RCU_DB_TYPE` in `environment.conf` (`EBR` | `ORACLE`, default `EBR`,
  asked by `01-setup-interview.sh`, added by `init_env.sh`);
  `09-Install/07-oracle_setup_repository.sh` passes it as `-databaseType` to
  every RCU call (`-listSchemas`, `-createRepository`, `-dropRepository`).
- Why `EBR`: what all installations of this repository got so far (silent
  default), the author's practice, and the state the Upgrade Assistant
  verifies (`EDITION = ORA$BASE`).
- Reports cookbook step 3: `-databaseType EBR` in the silent command; in the
  GUI select "Oracle Database enabled for edition-based redefinition"
  explicitly instead of taking the preselection.
- The prefix overview (`rcu_registry_overview.sql`, `07b-`,
  `07 --profile`) shows the column `EBR` per prefix and warns about mixed
  schemas within a prefix.

Check of the registry rows (as any `<prefix>_*` user or DBA):

```sql
SELECT mrc_name, comp_id, owner, version, status, upgraded, edition
  FROM schema_version_registry
 WHERE owner LIKE 'DEV\_%' ESCAPE '\'
 ORDER BY owner;
```

---

## 5. The service table – `<prefix>_STB`

- Tables `COMPONENT_SCHEMA_INFO` and `SERVICETABLE_` (**confirmed (live)**).
- `COMPONENT_SCHEMA_INFO`: one row per schema of the prefix with
  `SCHEMA_USER`, `COMP_ID`, `PREFIX_NAME`, DB host/port/service, `STATUS`,
  `URL` and **`SCHEMA_PASSWORD` (encrypted BLOB)** (**confirmed (live)**,
  9 rows, status `INITIALIZED`).
- Purpose: the Configuration Wizard / WLST `createDomain` read the
  connection data and passwords from here ("Get RCU Configuration") and
  write the data sources of the domain; "service tables are used to wire
  Oracle Fusion Middleware components together". (**documented**, RCU guide
  "About the Service Table Schema")
- Consequence (**assumption**): a later password change of a schema does not
  update the STB row – it only matters when the domain is extended or a new
  domain reads the RCU configuration again.

---

## 6. Where the schema passwords are stored

| Place | Content | Changes when |
|---|---|---|
| `$DOMAIN_HOME/config/jdbc/<ds>-jdbc.xml` | user + `password-encrypted` (`{AES256}`, key `security/SerializedSystemIni.dat`) – one file per data source (**confirmed (live)**: 6 data sources) | WLST / Remote Console / EM edit of the data source |
| `$DOMAIN_HOME/config/fmwconfig/bootstrap/cwallet.sso` | OPSS bootstrap credential (map `BOOTSTRAP_JPS`, key in `jps-config.xml` / `jps-config-jse.xml`) for the `DEV_OPSS` connection – used by the standalone Reports server and at WebLogic boot (**confirmed (live)**: file + references) | WLST `modifyBootStrapCredential` (**documented** OPSS command, not tested here) |
| `<prefix>_STB.COMPONENT_SCHEMA_INFO` | encrypted copy of all schema passwords | RCU only |
| repository root `db_sys_sec.conf.des3` | `DB_SYS_PWD`, `DB_SCHEMA_PWD` for our scripts (07, 08, 15, checks) | `01-setup-interview.sh` |

Changing a schema password therefore means (**assumption**, not tested):
`ALTER USER` in the DB → every data source of that schema →
`modifyBootStrapCredential` if it is `DEV_OPSS` → `db_sys_sec.conf.des3` →
restart AdminServer, managed servers and Reports server.

### 6.1 Password expiry – a real risk

**confirmed (live)**: all `DEV_*` users have profile `DEFAULT` with
`PASSWORD_LIFE_TIME 180`, `PASSWORD_GRACE_TIME 7`,
`FAILED_LOGIN_ATTEMPTS 10` – **expiry date 2027-04-13**.

- After expiry the data sources and the OPSS bootstrap cannot log in → the
  servers do not start / OPSS fails (ORA-28001/28002 in the server logs).
- A data source with a wrong password (e.g. after a half-done password
  change) can **lock** the schema after 10 attempts (ORA-28000).
- **Decision 2026-10-17: own profile `RCU_USER`** (`PASSWORD_LIFE_TIME
  UNLIMITED`, `FAILED_LOGIN_ATTEMPTS UNLIMITED`, other limits from
  `DEFAULT`). RCU has no profile option, so it is assigned after RCU:
  - `60-RCU-DB-19c/rcu_user_profile.sql` – idempotent: create/align the
    profile, assign it to every schema of the selected prefix(es) taken from
    `SYSTEM.SCHEMA_VERSION_REGISTRY$` (exact `MRC_NAME` match). Default is
    the own `DB_SCHEMA_PREFIX`; further prefixes only explicitly
    (`--prefix`), no "all" switch – other repositories in the same DB may
    belong to other teams/policies. `rcu_registry_overview.sql` shows all
    prefixes (schemas, orphaned registry rows, profile, status, expiry)
  - `60-RCU-DB-19c/07b-db_rcu_profile.sh` – DB preparation on the DB host
    before RCU (`--assign` for an existing repository)
  - `09-Install/07-oracle_setup_repository.sh` – assigns it after
    `-createRepository`; `--profile` for an existing repository
  - Reports cookbook step 3 – the same SQL for manual installations
- **confirmed (live)** 2026-10-17: after `ALTER USER … PROFILE RCU_USER` all
  nine `DEV_*` schemas show `EXPIRY_DATE` empty, status `OPEN`; the running
  domain was not affected; second run idempotent.
- Trade-off: `FAILED_LOGIN_ATTEMPTS UNLIMITED` removes the lock as brute-force
  protection for these accounts – acceptable because the schemas are only
  used by the domain (data sources) and the passwords are long/random; the
  DB listener should only be reachable from the FMW hosts.

---

## 7. Patching and the schemas – how Oracle intends it

```
                          what changes?
                               |
       +-----------------------+-------------------------+
       |                                                 |
  patch inside the release                     version upgrade
  (SPB, CSPU, bundle, one-off;                 (12.2.1.4 -> 14.1.2,
   e.g. September 2026)                         14.1.1 -> 14.1.2)
       |                                                 |
  OPatch / SPBAT on the Oracle Home            new Oracle Home (OUI)
  servers stopped, then started                Upgrade Assistant: readiness check,
       |                                         schemas IN PLACE, domain config
  schemas: unchanged                           Reconfiguration Wizard (domain)
  RCU:     not used                            RCU: only for NEW schemas (or UA
  registry: unchanged                                creates them with defaults)
                                               registry: VERSION / UPGRADED updated
```

| Situation | Tool | Schemas | Source |
|---|---|---|---|
| September 2026 CSPU: WLS SPB 14.1.2.0.260825, Forms 39842516, Reports 39600348, `39988381`, Perl 38590500 | OPatch (`napply`) / SPBAT | **unchanged** – all five READMEs: post-install = "`opatch lspatches`, start all processes"; no SQL, no UA step (**confirmed (live)**, READMEs in `$PATCH_STORAGE`); registry still `14.1.2.0.0` | patch READMEs |
| any patch of 12c/14c | OPatch | "There are no patch set installers in 12c" – patches only via OPatch | **documented**, Planning an Upgrade 14c |
| exception | as stated in the README | a single patch *may* require SQL or a UA step – only if its README says so → always read the README (also SPBAT prechecks) | **documented** (README driven) |
| 12.2.1.4 → 14.1.2 | Upgrade Assistant (`ua`, readiness mode first) | upgraded in place; `VERSION` → `14.1.2.0.0`, `UPGRADED=Y`; backup incl. registry required | **documented**, Upgrading to the FMW Infrastructure 14c |
| 11g patch set (history) | Patch Set Assistant (`psa`) | updated per patch set | **documented**, 11g Patching Guide |

The OPatch guide 14.1.2 ("Patching Your Environment Using OPatch") does not
mention database schemas at all – OPatch only works on the Oracle Home and
its inventory. (**confirmed** by full-text search of the chapter)

Our scripts already follow this: `07-Maintenance/81-patch_weblogic.sh` /
`82-patch_forms_reports.sh` patch the Oracle Home; no schema step needed for
the September patch.

---

## 8. Consequences for phase 8 of this repository

The open item "repository-schema patching" is **not** a recurring patch
step. What makes sense instead:

1. **Check script** (read-only) – **done 2026-10-17**: `07-Maintenance/rcu_repository_check.sh`:
   registry rows of the prefix (`VERSION`, `STATUS = VALID`, `UPGRADED`),
   registry table present, every data source of `config/jdbc` reaches its
   schema, account status, profile (`RCU_USER`?) + `EXPIRY_DATE` of the
   `<prefix>_*` users (warn before expiry), STB rows. Useful after every patch, before a move, and
   regularly from monitoring.
2. **Backup option** of the same script (`--apply`, done 2026-10-17): Data Pump export of
   `SYSTEM.SCHEMA_VERSION_REGISTRY$` + the `<prefix>_*` schemas before an
   upgrade or a move.
3. **Password profile** – done 2026-10-17 (section 6.1).
4. **Upgrade Assistant** only when a version upgrade comes (14.1.2 → next
   release): own procedure then (readiness check, backup, UA, Reconfiguration
   Wizard) – not part of the regular patch cycle.
5. Move/rebuild: drop with RCU **before** the old database is gone, or
   document the manual cleanup (section 4.1).

---

## 9. Database requirements for the repository (19c / 26ai)

What the database behind the RCU schemas must look like for FMW 14.1.2 –
checked 2026-10-27 against the Oracle documentation ([sources](#10-sources),
"Database requirements") and against the test DB (19.30 EE, CDB `FMWCDB`,
read live as SYSDBA).

### 9.1 Version, character set, components

| Requirement | Oracle (FMW 14.1.2) | Test DB 2026-10-27 | Marker |
|---|---|---|---|
| Version 19c | ≥ **19.14.0.0** | 19.30.0.0 | **documented** / **confirmed (live)** |
| Version 23ai / **26ai** | ≥ **23.4.0.24.0** for 23ai; 26ai (= 23.26.x) certified for WebLogic 14.1.1 / 14.1.2 / 15.1.1 – RCU needs **patch 38391376** | – (38391376 is part of the WLS SPB since CSPU Sep 2026, confirmed (live) with `opatch lspatches`, section 1) | **documented** (Oracle WebLogic blog); certification matrix row not yet read |
| Character set | **AL32UTF8** – listed as requirement; RCU only **warns** otherwise ("Oracle strongly recommends using the AL32UTF8 character set … User can proceed with this warning") | `AL32UTF8`, national `AL16UTF16` | **documented** / **confirmed (live)** |
| Oracle JVM | "Database is installed with Oracle JVM enabled" | `JAVAVM` + `CATJAVA` `VALID` | **documented** / **confirmed (live)** |
| MDS privileges | RCU user needs `EXECUTE … WITH GRANT OPTION` on `DBMS_OUTPUT`, `DBMS_STATS`, `DBMS_LOB` (or run RCU as SYSDBA – our 07- does) | SYSDBA | **documented** |
| `db_securefile` | not `FORCE` for the first RCU run | `PREFERRED` | section 4.2 |
| Certification | always the certification matrix of 14.1.2 (Supported System Configurations) – RCU may warn about a newer, already certified DB version, which can then be ignored | – | **documented** |

Rule for this repository: **AL32UTF8 is mandatory** (Forms/Reports Unicode,
APEX in the same DB) – the RCU warning is not taken as "allowed".

### 9.2 Initialisation parameters

| Parameter | Oracle minimum (RCU, 14.1.2) | `60-RCU-DB-19c` today (`environment_db.conf` / docs) | Test DB 2026-10-27 | Status |
|---|---|---|---|---|
| `processes` | **1000** | `DB_PROCESSES=500` | 500 | **below** minimum |
| `open_cursors` | **1600** | `DB_OPEN_CURSORS=1000` | 1000 | **below** minimum |
| `session_cached_cursors` | **100** | not set (default) | 50 | **below** minimum |
| `db_files` | **600** | 100 (05 doc) | 200 | **below** minimum |
| `shared_pool_size` | 147,456 KB (144 MB) | ASMM (0) | 0, `sga_target` 2 GB | ok – ASMM sizes the pool |
| `sga_max_size` | 147,456 KB | 2 GB | 2 GB | ok |
| `db_block_size` | 8 KB | 8 KB | 8192 | ok |

The domain runs on the test DB with the lower values (metadata only, one
domain) – they are nevertheless below Oracle's RCU minimum. **Done
2026-10-27:** `60-RCU-DB-19c` sets the minimums for new databases
(`DB_PROCESSES` 1000, `DB_OPEN_CURSORS` 1600, `DB_SESSION_CACHED_CURSORS` 100,
`DB_FILES` 600); the table in `09-Install/README.md` (before: 1200 / 2250 /
200, `SGA_MAX_SIZE` 6112M – not from the Oracle documentation) is aligned.
The existing test DB keeps its values until it is changed by hand
(`processes`, `session_cached_cursors`, `db_files` are static – restart).

### 9.3 Edition – EE, SE2 only with workaround patches

- The FMW 14.1.2 system requirements name **no edition**.
- In practice RCU 14.1.2 hits Enterprise-Edition-only features on **SE2**:
  - **ORA-00439 "feature not enabled: Fine-grained access control"** when
    RCU sets up VPD policies – workaround patch **37506854** (MOS Doc ID
    3083393.1) on the Oracle Home, then re-run RCU (dbi-services, see
    sources; **documented** by a third party, not tested here).
  - **ORA-00439 Partitioning** with EBR / UMS on SE2 – bugs 37603856 /
    37555123, fixed in the UMS bundle patch (README of 39940047, see the
    October 2026 analysis).
- Test DB: **Enterprise Edition**, options `Fine-grained access control` and
  `Partitioning` = `TRUE` (**confirmed (live)**).
- Consequence: `60-RCU-DB-19c` keeps **EE as default**; the statement "SE2 is
  technically sufficient" in `60-RCU-DB-19c/docs/00-concept.md` is corrected
  (2026-10-27) – SE2 only with the patches above and a test RCU run.

### 9.4 Licence – separately licensed database (decision 2026-10-27)

Question: is the Enterprise Edition of the repository database covered by
the WebLogic / Forms & Reports licence? **Answer used by this repository:
no** – the RCU metadata schemas need a **separately licensed Oracle
Database** (EE, or SE2 with the restrictions of 9.3).

Wording for compliance / system documentation (audit note):

> **Licence evidence / audit note:** According to the *Oracle Fusion
> Middleware Licensing Information User Manual* (section Oracle Forms and
> Reports / restricted-use licenses), the licence for Oracle Fusion
> Middleware / Forms & Reports and the use of the Repository Creation
> Utility (RCU) do **not** entitle to a free use of the Oracle Database
> (Enterprise or Standard Edition). Operating the RCU metadata schemas
> requires a separately licensed Oracle Database on the host.
> Reference: Oracle Fusion Middleware Licensing Information User Manual
> (document ID E56762-96).

German version (customer documents):

> **Lizenznachweis / Audit-Hinweis:** Gemaess dem Oracle Fusion Middleware
> Licensing Information User Manual (Abschnitt Oracle Forms and Reports /
> Restricted-Use Licenses) berechtigt die Lizenz fuer Oracle Fusion
> Middleware / Forms & Reports sowie der Einsatz des Repository Creation
> Utility (RCU) nicht zur kostenfreien Nutzung der Oracle Database
> (Enterprise oder Standard Edition). Der Betrieb der RCU-Metadaten-Schemata
> setzt eine separat lizenzierte Oracle Datenbank auf dem Host voraus.
> Referenz: Oracle Fusion Middleware Licensing Information User Manual
> (Dokumenten-ID: E56762-96).

- Source of the wording: compliance statement provided by the author
  2026-10-27 – the conservative ("safe side") reading. The manual text
  itself was not opened from this repository; the exact section / revision
  should be quoted from the current manual in an audit.
- Consistent with the licence notice in `60-RCU-DB-19c/README.md` (no
  licence-free special case for RCU). Oracle Database XE is not an option
  (not certified for RCU).
- This is no legal advice – the customer's contract and Oracle licence
  management decide.

### 9.5 Checks (implemented 2026-10-27)

`60-RCU-DB-19c/rcu_db_requirements.sql` reads the values (one `IHW:REQ|…`
line each), `rcu_db_req_eval` in `00-Setup/IHateWeblogic_lib.sh` evaluates
them: version / AL32UTF8 / JVM / `db_block_size` → FAIL, edition not EE,
option missing, parameter below minimum → WARN. Used by:

| Script | When |
|---|---|
| `09-Install/07-oracle_setup_repository.sh --check` | read-only, any (customer) DB before RCU |
| `09-Install/07-oracle_setup_repository.sh --apply` | automatically before `-createRepository` – a FAIL stops RCU |
| `60-RCU-DB-19c/05-db_create_database.sh` | after DBCA, in the PDB |
| `07-Maintenance/rcu_repository_check.sh` | section 1, regularly |

Live 2026-10-27 (test DB): version, EE, AL32UTF8, JVM, block size OK; the
four parameters of 9.2 WARN.

Check (as DBA, in the PDB):

```sql
SELECT version_full FROM v$instance;
SELECT banner_full  FROM v$version;                       -- Enterprise / Standard Edition 2
SELECT parameter, value FROM nls_database_parameters
 WHERE parameter IN ('NLS_CHARACTERSET','NLS_NCHAR_CHARACTERSET');
SELECT comp_id, status FROM dba_registry WHERE comp_id IN ('JAVAVM','CATJAVA');
SELECT name, value FROM v$parameter
 WHERE name IN ('processes','open_cursors','session_cached_cursors','db_files',
                'db_block_size','shared_pool_size','sga_max_size','sga_target','db_securefile');
SELECT parameter, value FROM v$option
 WHERE parameter IN ('Fine-grained access control','Partitioning');
```

---

## 10. Sources

All links checked 2026-10-17 (HTTP 200, title matches); section 9 sources
2026-10-27.

**Database requirements (section 9, 2026-10-27)**

- *System Requirements and Specifications* 14c (14.1.2), "RCU Requirements
  for Oracle Databases" (versions 19.14 / 23.4.0.24, AL32UTF8 + warning text,
  Oracle JVM, parameter minimums, MDS privileges):
  https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/sysrs/system-requirements-and-specifications.html
- *Creating Schemas with the Repository Creation Utility* 14c, "Finding a
  Certified Database", "Database Requirements for RCU":
  https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/rcuug/repository-creation-utility.html
- Oracle Fusion Middleware Supported System Configurations (certification
  matrix 14.1.2 – the authoritative list of databases):
  https://www.oracle.com/middleware/technologies/fusion-certification.html
- Oracle WebLogic Server blog, "Announcing WebLogic Server certification with
  Oracle AI Database 26ai" (WLS 14.1.1 / 14.1.2 / 15.1.1, RCU patch
  38391376):
  https://blogs.oracle.com/weblogicserver/announcing-weblogic-server-certification-with-oracle-ai-database-26ai
- dbi-services, "Oracle FMW 14 installation: ORA-00439 feature not enabled:
  Fine-grained access control" (SE2, patch 37506854, MOS Doc ID 3083393.1):
  https://www.dbi-services.com/blog/oracle-fmw-14-installation-ora-00439-feature-not-enabled-fine-grained-access-control/
- Licence: *Oracle Fusion Middleware Licensing Information User Manual*
  (E56762-96), section Oracle Forms and Reports / restricted-use licenses –
  referenced by the audit wording of 9.4 (manual text not opened here)

**Current (14.1.2)**

- *Creating Schemas with the Repository Creation Utility* 14c – system load /
  product load, custom prefixes, service table, verifying schema version
  numbers, dropping schemas, log files (`/tmp/RCU<timestamp>/logs`):
  https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/rcuug/index.html
- *Upgrading to the Oracle Fusion Middleware Infrastructure* 14c – pre-upgrade
  checklist, "Backing Up the Schema Version Registry Table", Upgrade
  Assistant, readiness check, "Verifying the Schema Upgrade":
  https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/infup/index.html
- *Planning an Upgrade of Oracle Fusion Middleware* 14c – tools (OPatch,
  UA, Reconfiguration Wizard), "no patch set installers in 12c", in-place
  upgrade: https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/asmas/index.html
- *Patching with OPatch* 14c:
  https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/opatc/index.html
- *Administering Oracle Fusion Middleware* 14c (backup, wiring components):
  https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/asadm/index.html

- RCU guide 14c, "Creating Schemas for Oracle Access Manager and Oracle
  Internet Directory" (EBR + non-EBR in one DB):
  https://docs.oracle.com/en/middleware/fusion-middleware/14.1.2/rcuug/obtaining-and-running-repository-creation-utility.html#GUID-7C47260C-8755-4E50-A03D-9D11C8438F5A

**Older editions**

- 12.2.1.4 – RCU guide: https://docs.oracle.com/en/middleware/fusion-middleware/12.2.1.4/rcuug/index.html
- 12.2.1.4 – Upgrading to the FMW Infrastructure:
  https://docs.oracle.com/en/middleware/fusion-middleware/12.2.1.4/infup/index.html
- 11g (11.1.1.x) – *Patching Guide*, "Updating Your Schemas with Patch Set
  Assistant" (the PSA concept that no longer exists):
  https://docs.oracle.com/cd/E29542_01/doc.1111/e16793/patch_set_assistant.htm
  (contents: https://docs.oracle.com/cd/E29542_01/doc.1111/e16793/toc.htm)

**Live sources on the test host**

- `SYSTEM.SCHEMA_VERSION_REGISTRY$`, `DBA_USERS`, `DBA_PROFILES`,
  `DEV_STB.COMPONENT_SCHEMA_INFO` (queried 2026-10-17)
- `$DOMAIN_HOME/config/jdbc/*.xml`, `config/fmwconfig/jps-config*.xml`,
  `config/fmwconfig/bootstrap/cwallet.sso`
- RCU logs `/tmp/RCU2026-10-1*/logs/rcu.log` (create/drop of the rebuild)
- EBR test 2026-10-17: scratch prefix `ZZT` (`-databaseType ORACLE`, STB + WLS)
  created and dropped with RCU; `DBA_USERS.EDITIONS_ENABLED`, registry `EDITION`,
  `DBA_VIEWS.EDITIONING_VIEW`, RCU logs (`sql/` vs. `oracle_ebr/`)
- `db_securefile` test 2026-10-17: scratch table `SYSTEM.IHW_SF_TEST` with a
  CLOB in tablespace `SYSTEM` under `PREFERRED` / `ALWAYS` / `FORCE`
  (session level), dropped afterwards; `DBA_LOBS`, `DBA_TABLESPACES`
- Profile change 2026-10-17: `60-RCU-DB-19c/07b-db_rcu_profile.sh --apply --assign`,
  `09-Install/07-oracle_setup_repository.sh --profile` (idempotent re-run)
- READMEs of the September 2026 patches in `$PATCH_STORAGE/patches/`

**Related**

- `09-Install/docs/07-oracle_setup_repository.md` – how this repository runs RCU
- [weblogic_middleware_architecture.md](weblogic_middleware_architecture.md) – domain overview
- [reports_user_local_ldap.md](reports_user_local_ldap.md) – OPSS / `jps-config-jse.xml` of the Reports server
