# Password handling in an FMW Forms / Reports domain

Where WebLogic, the Node Manager, OPSS, Reports and this library keep
credentials, how they are protected (mostly: **encrypted with a key that lies
next to them**), what that means for security – and the Node Manager's own
copy of `boot.properties`, which explains several "the start suddenly fails
after a password change" cases.

Markers as in the [README](README.md): **confirmed (live)** = seen on the test
host (FMW 14.1.2, `fr_domain`, 2026-10-29), **documented** = Oracle
documentation, **assumption** = plausible, not verified.

Steps to **recover / reset** a password (Node Manager, admin, stored WLST
credentials): [09-Install/docs/80-oracle_security.md §5](../09-Install/docs/80-oracle_security.md#5--password-recovery).
The same "key under the doormat" model for this library's `*.des3` files:
[SECURITY.md](../SECURITY.md#password-encryption-is-obfuscation-not-protection).

---

## 1. The domain key – `security/SerializedSystemIni.dat`

Every WebLogic domain has its own secret, created with the domain:
`$DOMAIN_HOME/security/SerializedSystemIni.dat` (80 bytes). Every value
WebLogic writes as `{AES256}…` (14.1.2; `{AES}…` in older releases) is
encrypted with it – `boot.properties`, `config.xml`, the JDBC modules, the
Node Manager cache. (**documented**, Securing WebLogic Server; **confirmed
(live)**: file present, values `{AES256}`.)

Consequences:

- **The key lies next to the encrypted values.** Anyone who can read
  `SerializedSystemIni.dat` **and** an `{AES256}` value can decrypt it with
  the WebLogic classes of the Oracle Home – no password needed. The
  encryption keeps passwords out of plain sight (screens, diffs, copies of a
  single file); it is **not** an access control on the host. Same principle
  as this library's `*.des3` files.
- An `{AES256}` value only works in its own domain – copying
  `boot.properties` into another domain does not work; a **clone** of the
  whole domain carries the same key and therefore the same readable secrets
  ([clone_golden_image.md](clone_golden_image.md)).
- Losing the file means losing every encrypted value of the domain – it is
  part of every domain backup, and every domain backup is therefore a
  secret.

Permissions on the test host (**confirmed (live)** 2026-10-29):

| File | Mode | Note |
|---|---|---|
| `security/SerializedSystemIni.dat` | `640 oracle:oinstall` | **group-readable** |
| `servers/<srv>/security/boot.properties` | `600` | written by `10-oracle_boot_properties.sh` |
| `servers/<ms>/data/nodemanager/boot.properties` | `640` | written by the Node Manager at every start (section 3) |
| `config/nodemanager/nm_password.properties` | `640` | hash only |
| `config/fmwconfig/bootstrap/cwallet.sso`, `config/fmwconfig/cwallet.sso`, `security/cwallet.sso` | `600` | OPSS wallets (section 4) |

`640` + group `oinstall` means: **every member of `oinstall` can decrypt the
boot identity.** Keep `oinstall` to the software owner (and DBA accounts that
need the inventory) – or treat its members as administrators of the domain.

## 2. `boot.properties` – the boot identity of a server

`$DOMAIN_HOME/servers/<server>/security/boot.properties`:

```
username=<admin user>
password=<password>
```

- Written in **clear text** (by hand or `09-Install/10-oracle_boot_properties.sh`),
  rewritten by the server at its **first successful start** as
  `username={AES256}…` / `password={AES256}…` (**confirmed (live)**). Until
  that first start the password lies in clear text on disk – start the server
  right after writing the file.
- Read by `startWebLogic.sh` / `startManagedWebLogic.sh` (no prompt) and by
  the stop scripts. Missing → the start script asks interactively; started
  in the background or by the Node Manager it dies at once (`BEA-090782`,
  [doc 10](../09-Install/docs/10-oracle_boot_properties.md)).
- The values are the **admin user of the security realm** – after a change
  of that password the file must be written again (clear text, re-encrypted at
  the next start), otherwise the next start fails with an authentication error.

## 3. The Node Manager's own copy – `data/nodemanager/boot.properties`

Next to the server's `security/boot.properties` there is a **second** one in
the Node Manager's cache of each managed server (**confirmed (live)**):

```
$DOMAIN_HOME/servers/WLS_FORMS/data/nodemanager/
    boot.properties      username / password {AES256}, TrustKeyStore=DemoTrust
    startup.properties   AdminURL, AutoRestart, RestartMax, SSLArguments, log rotation …
    WLS_FORMS.state / .pid / .lck / .url / .prg
```

On the test host both files carry the time stamp of the last domain start
(2026-10-28 17:01 – `start-all` after the RCU DB patch), `security/boot.properties`
the one of its first start (2026-10-15). The AdminServer's cache directory
holds only `.state` / `.pid` / `.lck` / `.url` – **no** `boot.properties`
there (it is started by `nmStart` and reads its `security/boot.properties`).

How the copy gets there (**documented**, Node Manager Administrator's Guide –
"boot identity" / `startup.properties`): when the **AdminServer** starts a
managed server through the Node Manager (Remote Console, EM, WLST `start()`),
it hands the Node Manager the boot identity and the server start properties;
the Node Manager stores them in `data/nodemanager/` and uses them for later
starts and automatic restarts (`AutoRestart=true`, `RestartMax=2` in
`startup.properties`) – also while the AdminServer is down.

Consequence – the cache **depends on how the server was started**:

| Start path | Uses / writes the cache |
|---|---|
| WLST `start('<ms>')` via the AdminServer (our `01-Run/startStop.sh`, `fmw_ctl.sh` / `wls_start.py` of the autostart) | AdminServer sends identity + start properties → NM **writes** `data/nodemanager/boot.properties` + `startup.properties` (**confirmed (live)**: time stamps = last `start-all`) |
| WLST `nmStart('<ms>')` without the AdminServer (fallback in `wls_start.py` when the AdminServer cannot be reached) | NM starts with what is **already in the cache**; with an empty cache it has no boot identity / no admin URL from the AdminServer (**assumption**: falls back to `security/boot.properties`, or the server starts without the AdminServer's start properties – to verify, see test plan) |
| `startManagedWebLogic.sh` / `startWebLogic.sh` by hand | **no** Node Manager in the chain – reads `security/boot.properties`, the NM cache is neither used nor updated; the NM sees the server as `SHUTDOWN` ([weblogic_middleware_architecture.md §4](weblogic_middleware_architecture.md#4-who-starts-whom--the-control-chain)) |

What this means in practice (from a support call 2026-10-29, partly
**assumption** until the test below has run):

- **After a password change of the admin user** the cache still holds the
  **old** identity. A restart by the Node Manager alone (crash restart,
  `nmStart`) uses it and fails with an authentication error, while a start
  via the AdminServer writes the new one. Rule: after a password change
  write `security/boot.properties` **and** delete the cached
  `data/nodemanager/boot.properties` (server stopped), then start the server
  once **through the AdminServer** (`startStop.sh start <ms> --apply`), so
  the Node Manager gets the new identity.
- **Deleting the cache** (`data/nodemanager/*` – sometimes recommended to
  "clean" a stuck state) removes the boot identity and the start
  properties: the next start **through the AdminServer** rebuilds both; a
  start **only with `nmStart`** does not have them – the server may come up
  with different arguments or not at all. Delete the cache only with the
  server stopped and start it afterwards via the AdminServer.
- The cache file has `TrustKeyStore=DemoTrust` and `startup.properties` the
  `SSLArguments` – the AdminServer passes its SSL view on; after a change of
  the trust configuration the cache must be refreshed the same way.

### Test plan (to turn the assumptions into facts)

On the test host, `WLS_FORMS`, one step at a time:

1. `startStop.sh stop WLS_FORMS --apply`; save `data/nodemanager/` aside.
2. Delete `data/nodemanager/boot.properties` + `startup.properties`.
3. Start with **`nmStart` only** (WLST `nmConnect` + `nmStart('WLS_FORMS')`,
   AdminServer running but not used) → does it start, which admin URL /
   arguments (`ps`), are the files recreated, what is in `WLS_FORMS.out`?
4. Stop, delete again, start via **`start('WLS_FORMS')`** through the
   AdminServer → files recreated, contents compared.
5. Change test: wrong password in the cached `boot.properties` (clear text,
   NM cache) → `nmStart` → error message; then start via the AdminServer →
   cache corrected?

## 4. Further credential stores of the domain

| Credential | Location | Protection | Note |
|---|---|---|---|
| WebLogic users (admin, `monUser`, `RepRunner`) | embedded LDAP `servers/AdminServer/data/ldap/` | hash | only the AdminServer reads it |
| Node Manager user / password | `config.xml` (`{AES256}`) **and** `config/nodemanager/nm_password.properties` (hash) | key / hash | two stores, independent of the admin password ([doc 80 §5.1](../09-Install/docs/80-oracle_security.md#51-where-the-credentials-live)) |
| Data source passwords (RCU schemas `_STB`, `_OPSS`, `_WLS` …) | `config/jdbc/*-jdbc.xml` `<password-encrypted>{AES256}…` | domain key | change after an RCU password change in the console / WLST, not in the file |
| OPSS bootstrap credential (login to the `_OPSS` schema) | `config/fmwconfig/bootstrap/cwallet.sso` | auto-login wallet (`600`) | readable by the OS owner without password – that is what "auto-login" means |
| OPSS credential store / keystore service | `_OPSS` schema in the RCU DB; `config/fmwconfig/cwallet.sso`, `security/cwallet.sso` | encrypted in the DB / auto-login wallet | [rcu_middleware_architecture.md](rcu_middleware_architecture.md) |
| RCU schema passwords | `_STB` service table (encrypted) | DB | [rcu_middleware_architecture.md §5 / §6](rcu_middleware_architecture.md#6-where-the-schema-passwords-are-stored) |
| Reports server `<identifier>` (admin of the web commands) | `rwserver.conf` `<identifier encrypted="yes">` | encrypted by the Reports server at its first start | written in clear text by `13-`, encrypted at the start (**confirmed (live)**) |
| Reports key map `cgicmd.dat` | `…/reports_14.1.2/configuration/cgicmd.dat` (mode `640`) | `userid=` **encrypted** by rwservlet (`{AES}…`), `authid=` **clear text** | section 4a |
| Forms `userid=` in `formsweb.cfg` (if used) | domain config | **clear text** | avoid – let the user log in, or use SSO / a proxy user |
| WLST stored credentials / autostart key files | `~/<user>-WebLogicConfig.properties` + `…Key.properties`, `$ORACLE_BASE/admin/<domain>/ctrl/keyfile/` (dir `700`) | encrypted + key file next to it | same model: key next to the value |
| ORDS (`ORDS_PUBLIC_USER`) | `ords_N/config/databases/default/wallet/cwallet.sso` | auto-login wallet | backed up by `backup_config.sh` category `ords` (set mode 600) |
| IHateWeblogic | `*.des3` in the repository | `openssl des3`, key from the machine | [SECURITY.md](../SECURITY.md#password-encryption-is-obfuscation-not-protection) |

### 4a. `cgicmd.dat` – `userid=` encrypted, `authid=` not

The Reports QPR **39600348** lists in its README the fixed bug
**37756029** "CGICMD.DAT FILE DOES NOT ACCEPT ENCRYPTION FOR VALUES LIKE
PASSWORD". What the code does (**confirmed (code)**, `reports/jlib/rwrun.jar`
`oracle.reports.rwclient.KeyMapParser`, `jlib/zrclient.jar`
`oracle.reports.utility.Utility` / `EncryptionUtil`, test host with the QPR,
2026-10-29):

- **Switch:** JVM property `-Dreports.userid.encryption.enabled=true`
  (`true` or `1`). Oracle's own `setDomainEnv.sh` of the 14.1.2 domain sets
  it for every WebLogic JVM (**confirmed (live)**: AdminServer, WLS_FORMS,
  WLS_REPORTS run with it) – the counterpart of
  `-Dforms.userid.encryption.enabled=true` for Forms.
- **When:** at its initialisation the rwservlet (`KeyMapParser.init()` →
  `writeEncryptionString`) reads `cgicmd.dat` line by line, skips comments
  (`#`, `;`), encrypts every **`userid=`** value and writes the file back
  (via `tmpoutput.txt` in the configuration directory, then rename). Reading
  a key decrypts it again (`returnDecryptedUserIdPassword`).
- **What:** only `userid=` – the **whole** value (`user/password@db`) becomes
  `userid={AES}<base64>`. **`authid=` is not touched**: the call passes the
  constant `userid=` only.
- **Key:** AES (128 / 256 bit, `-Dreports.userid.encryp.strength`), kept in
  the **OPSS keystore service** – stripe `reportsapp`, keystore `reportsks`,
  alias `reportskey` (created on first use, `EncryptionUtil.createKeyStore`),
  i.e. in the `_OPSS` schema of the RCU database, **not** next to the file.
  An encrypted `cgicmd.dat` therefore works only in its own domain / OPSS
  store; copied into another domain the `userid=` values cannot be decrypted.

**Live on the test host** (**confirmed (live)**): `cgicmd.dat` was rewritten
at the start of WLS_REPORTS (2026-10-28 17:02); Oracle's sample keys
(`breakbparam`, `express`) carry `userid={AES}…`, our key
`default: server=repserver01 %* authid=RepRunner/<password>` keeps the
password in **clear text**.

Consequences:

- `userid=` passwords in key-map entries are safe to write in clear text –
  they are encrypted at the next WLS_REPORTS start (same pattern as
  `boot.properties`: clear text until the next start).
- `authid=` (WebLogic user of a secured Reports server) stays readable for
  everybody who can read the file (`oracle`, group `oinstall` with 640) –
  use a user with `RW_EXECREPORTS` only, keep the file `640`/`600`; whether
  an `authid` can be replaced by an encrypted form is open (SR question).
- `14b-oracle_reports_fonts.sh` / `restore_config.sh` write the file in
  clear text again; the next WLS_REPORTS start encrypts the `userid=` values
  once more. A `cgicmd.dat` restored into **another** domain needs its
  `userid=` values in clear text.

## 5. What to observe for security

1. **The host is the boundary.** Every store above can be read by the OS
   owner `oracle` (wallets: auto-login; `{AES256}`: key next to it). Protect
   the account: SSH access, sudo policy, no shared `oracle` logins, minimal
   `oinstall` membership (section 1).
2. **Never on the command line.** Passwords on a command line are visible
   in `ps` / `/proc/<pid>/cmdline` and shell history. This library passes
   them via environment / stdin / temp files 600 (WLST helpers,
   `jarsigner -storepass:file`, `ihw_sql_sys`); avoid
   `startWebLogic.sh <user> <password>` and `connect('u','p',…)` in scripts
   that end up in a history.
3. **Clear text only briefly.** `boot.properties` until the first start,
   `rwserver.conf <identifier>` until the first Reports server start, the
   interview / `10-` write them right before the start.
4. **Backups and clones are secrets.** A domain backup or VM snapshot holds
   `SerializedSystemIni.dat` + every `{AES256}` value + the auto-login
   wallets = all passwords. `07-Maintenance/backup_config.sh` therefore
   does **not** copy `boot.properties`, `SerializedSystemIni.dat` or the
   keystores (only full domain / file-system backups do) –
   [07-Maintenance/README.md](../07-Maintenance/README.md).
5. **After a password change** (admin user): realm → `security/boot.properties`
   of every server → **Node Manager cache** (section 3) → stored WLST
   credentials and autostart key files (`30-configure_autostart.sh --apply`)
   → `weblogic_sec.conf.des3` (`00-Setup/weblogic_sec.sh --apply`).
   Steps: [doc 80 §5.3 / §5.4](../09-Install/docs/80-oracle_security.md#53-bootproperties-server-dies-at-start--stop-script-cannot-log-in).
6. **Clear-text exceptions** (`cgicmd.dat` `authid` – unlike `userid=`, see 4a; `formsweb.cfg` `userid`):
   least-privilege users, file mode 640 / 600, never in a repository.
7. **Demo trust in the cache** (`TrustKeyStore=DemoTrust`): harmless while
   every WebLogic port is on `127.0.0.1` and TLS ends at Nginx; with own
   SSL on WebLogic the identity / trust keystores must be configured and the
   cache refreshed ([certificates_trust_stores.md](certificates_trust_stores.md)).

## 6. Sources

- Oracle WebLogic Server 14.1.2 – *Administering Node Manager* (boot
  identity, `startup.properties`, starting servers via the AdminServer vs.
  `nmStart`) and *Administering Server Startup and Shutdown* (boot identity
  file) – docs.oracle.com, Fusion Middleware 14.1.2 library.
- Oracle WebLogic Server 14.1.2 – *Securing a Production Environment*
  (protecting `SerializedSystemIni.dat`, file permissions):
  https://docs.oracle.com/en/middleware/fusion-middleware/weblogic-server/14.1.2/lockd/index.html
- Test host inventory 2026-10-29 (`find $DOMAIN_HOME -name boot.properties …`,
  modes, time stamps; values never displayed).
