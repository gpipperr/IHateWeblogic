# 08-SSL – SSL Certificate Management

**Module:** `08-SSL/`
**Runs as:** `root` (cert deployment) / `oracle` (audit + CSR)
**Phase:** Operational – before initial start and on every certificate renewal

---

## Purpose

This module manages the **SSL certificate lifecycle** for the Oracle Forms &
Reports installation – the TLS certificate of the Nginx frontend and the
code-signing certificate for `jacob.jar` (Forms/WebUtil). Role in the
library: certificates are **built** here (see the folder roles in the
[root README](../README.md#folder-roles)); the host-wide TLS audit incl.
WebLogic's own SSL ports is `02-Checks/ssl_check.sh`.

Background (`80-FMW-Architecture/`):
- where TLS ends and how Nginx, WebLogic and the Forms/Reports processes are
  joined: [weblogic_middleware_architecture.md §6](../80-FMW-Architecture/weblogic_middleware_architecture.md#6-how-the-parts-are-joined)
- which client (Java Web Start / FSAL) talks to which server process:
  [forms_runtime_architecture.md §1](../80-FMW-Architecture/forms_runtime_architecture.md#1-the-parts)
- code signing: [how Oracle intends it](../80-FMW-Architecture/forms_jakob_webutil.md#8-signing--how-oracle-intends-it),
  [which certificates](../80-FMW-Architecture/forms_jakob_webutil.md#9-which-certificates-are-needed),
  [who checks the signature](../80-FMW-Architecture/forms_jakob_webutil.md#10-who-checks-the-signature--and-against-what),
  [renewal / re-signing](../80-FMW-Architecture/forms_jakob_webutil.md#11-maintenance--patching-renewal-re-signing),
  [client distribution](../80-FMW-Architecture/forms_jakob_webutil.md#12-distribution-concept-for-the-clients)

It covers these recurring tasks:

| Task | Script | When |
|---|---|---|
| Prepare / create a certificate | `ssl_prepare_cert.sh` | Before first Nginx start and at renewal |
| Own root CA + server + code-signing certificates | `ssl_local_ca.sh` | Once (CA), then at renewal; code signing for Forms/WebUtil (`jacob.jar`) |
| Deploy certificate to Nginx | `09-Install/05-root_nginx_ssl.sh` | Install-time (once) and at renewal |
| Audit current SSL configuration | `ssl_config.sh` | Anytime – monitoring, compliance checks |

The module does **not** manage SSL inside WebLogic directly.
WebLogic listens on `127.0.0.1` only; SSL for clients is terminated at Nginx.
Note: the domain templates also enable WebLogic SSL listen ports with the
**demo certificate** (`WLS_FORMS` 9501, `WLS_REPORTS` 9512 – on the test host
bound to `127.0.0.1`, confirmed 2026-10-20); they are not used and shall be
disabled in `09-Install/08-` (root README open item, found by
`02-Checks/ssl_check.sh`).

---

## Architecture: SSL in This Installation

```
Internet / Browser
        │  HTTPS :443
        ▼
┌────────────────────────────────────────────────────────┐
│  Nginx  (SSL termination)                              │
│  /etc/nginx/ssl/fullchain.pem ← deployed by            │
│  /etc/nginx/ssl/privkey.pem     05-root_nginx_ssl.sh   │
│                                                        │
│  Protocols: TLSv1.2 + TLSv1.3 only                     │
│  Ciphers:   ECDHE / AES-GCM only                       │
└────────────────────────────────────────────────────────┘
        │  HTTP plain — loopback only (127.0.0.1)
        ▼
WebLogic (no client TLS)
  AdminServer   127.0.0.1:7001
  WLS_FORMS     127.0.0.1:9001   (+ demo SSL 127.0.0.1:9501 – unused)
  WLS_REPORTS   127.0.0.1:9002   (+ demo SSL 127.0.0.1:9512 – unused)
```

**Consequences:**
- Only one certificate location for clients: `/etc/nginx/ssl/` (`fullchain.pem`
  = server certificate + chain, `privkey.pem`)
- No Java KeyStore management inside WebLogic (the demo keystores of the
  unused SSL ports aside)
- Redirects with the correct `https://<FQDN>` URL: Nginx sends `Host` and
  `WL-Proxy-SSL: true`, the domain templates set `weblogic-plugin-enabled` on
  `WLS_FORMS` / `WLS_REPORTS` – no Frontend Host needed (confirmed live
  2026-10-20; alternative and WLST commands:
  [09-Install/docs/05-root_nginx_ssl.md](../09-Install/docs/05-root_nginx_ssl.md#weblogic-frontend-host-configuration))

---

## Certificate Lifecycle

```
┌──────────────────────────────────────────────────────────────────┐
│  1. PREPARE  (ssl_prepare_cert.sh)                               │
│     Choose one option:                                           │
│       A. Self-signed      → quick test, browser warning          │
│       L. Local CA (openssl, ssl_local_ca.sh) → one root for TLS  │
│          and code signing, trusted after root import (lab/int.)  │
│       B. Easy-RSA (internal CA) → alternative to L, needs EPEL   │
│       C. Customer / Public CA   → receive signed cert from CA    │
│                                                                  │
│     Result: cert + key in staging path (SSL_CERT_FILE / _KEY)    │
│             stored in environment.conf                           │
└──────────────────┬───────────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────────────┐
│  2. DEPLOY  (09-Install/05-root_nginx_ssl.sh --apply)            │
│     - Validates cert: exists, not expired, key matches           │
│     - Copies to /etc/nginx/ssl/ (chmod 600 key, 644 cert)        │
│     - Injects SSL directives into Nginx config                   │
│     - nginx -t → systemctl reload nginx                          │
└──────────────────┬───────────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────────────┐
│  3. VERIFY  (ssl_config.sh)                                      │
│     - TLS handshake test (openssl s_client)                      │
│     - Protocol check (no TLS 1.0/1.1)                           │
│     - Certificate expiry / subject / SAN                         │
│     - WebLogic redirects (plugin-enabled / Frontend Host)        │
│     - Nginx cipher / protocol config                             │
└──────────────────────────────────────────────────────────────────┘

Renewal: repeat steps 1 → 2 → 3 with the new certificate.
```

---

## Scripts

### ssl_prepare_cert.sh

**Purpose:** Generate or stage a certificate for Nginx deployment.

```bash
./08-SSL/ssl_prepare_cert.sh SELF      # self-signed (testing only)
./08-SSL/ssl_prepare_cert.sh LOCALCA   # server cert from the local CA (ssl_local_ca.sh)
./08-SSL/ssl_prepare_cert.sh EASYRSA   # Easy-RSA internal CA workflow
./08-SSL/ssl_prepare_cert.sh REQUEST   # generate CSR for customer/public CA
```

**Mode: SELF** (`--apply`)
- `openssl req -x509` → self-signed cert + key
- Output: `SSL_CERT_FILE`, `SSL_KEY_FILE` (paths from `environment.conf`)
- Use case: smoke test before customer cert arrives

**Mode: LOCALCA** (`--apply [--renew]`) – recommended for internal / lab
- Same prompts as SELF, then calls `ssl_local_ca.sh init --apply` (only if
  no CA exists yet) and `ssl_local_ca.sh server --apply [--renew]`
- Output: `SSL_CERT_FILE`, `SSL_KEY_FILE`, `SSL_CHAIN_FILE` (= root CA)
- Use case: lab / internal installations without a company PKI; the same
  root also signs the code-signing certificate for `jacob.jar`
- Details: section "ssl_local_ca.sh" below

**Mode: EASYRSA** (`--apply`) – alternative to LOCALCA (needs the EPEL package)
- Checks for existing Easy-RSA PKI at `EASYRSA_PKI_DIR` (env.conf)
- If PKI not initialized: `easyrsa init-pki` + `easyrsa build-ca`
- Issues server cert: `easyrsa build-server-full <fqdn> nopass`
- Copies cert + key to `SSL_CERT_FILE` / `SSL_KEY_FILE`
- Use case: internal/lab environments with own CA

**Mode: REQUEST**
- Generates private key + CSR: `openssl req -new`
- CSR written to `SSL_CSR_FILE` (env.conf)
- Prints instructions for submitting to CA
- Use case: production environments with a company or public CA

**Does NOT deploy** → run `05-root_nginx_ssl.sh --apply` afterwards.

---

### ssl_local_ca.sh

**Purpose:** a small own certificate authority built with plain `openssl`
(no Easy-RSA, no EPEL): **one root CA**, two kinds of leaf certificates.

```
                 ┌───────────────────────────────────────┐
                 │  Root CA   ca/ca.crt  (10 years)      │
                 │  CA:TRUE pathlen:0, keyCertSign/cRLSign│
                 │  ca/ca.key  AES-256, passphrase in    │
                 │             ssl_ca_sec.conf.des3      │
                 └──────────────┬────────────────┬───────┘
                       signs    │                │   signs
                                ▼                ▼
   ┌────────────────────────────────┐  ┌────────────────────────────────┐
   │ server/<cn>.crt   (825 days)   │  │ codesign/codesign.crt (3 years)│
   │ EKU serverAuth, SAN            │  │ EKU codeSigning                │
   │ key unencrypted (Nginx)        │  │ key only in codesign.p12       │
   │ → SSL_CERT_FILE/_KEY/_CHAIN    │  │   (password forms_sign_sec.    │
   │ → 05-root_nginx_ssl.sh --apply │  │    conf.des3)                  │
   │ TLS of the Forms/Reports URL   │  │ → 14-oracle_setup_forms.sh     │
   │                                │  │   signs jacob.jar (jarsigner)  │
   └────────────────────────────────┘  └────────────────────────────────┘

   Client: imports ONLY ca.crt / ca.cer once → trusts the TLS certificate
   (browser, FSAL, Java Web Start) AND the jacob.jar signature (Web Start).
```

**Why one root for both:** the clients need exactly one trust anchor.
Renewing the server or the code-signing certificate under the same root
needs **no** change on the clients – with single self-signed certificates
(mode SELF) every renewal has to be distributed again. Background on who
checks which certificate: [forms_jakob_webutil.md §9–12](../80-FMW-Architecture/forms_jakob_webutil.md#9-which-certificates-are-needed).

```bash
./08-SSL/ssl_local_ca.sh status                     # read-only: CA, server, code signing, expiry, chain
./08-SSL/ssl_local_ca.sh init     [--apply]         # create the root CA (once)
./08-SSL/ssl_local_ca.sh server   [--apply] [--renew]   # TLS certificate for SSL_CN / SSL_SAN
./08-SSL/ssl_local_ca.sh codesign [--apply] [--renew]   # code-signing keystore (PKCS12) for jarsigner
```

| Sub-command | Does | Idempotent |
|---|---|---|
| `status` | subject / issuer / expiry / days left of root, server and code-signing certificate; `openssl verify` against the root; PKCS12 opens with the des3 password; `SSL_CERT_FILE` = issued server certificate; distribution hint. Exit 0 ok / 1 warning (missing, < 30 days, root < 365 days) / 2 error (expired, broken chain) – usable in cron | read-only |
| `init` | root key (RSA `SSL_CA_KEY_SIZE`, AES-256 encrypted) + self-signed root certificate (`SSL_CA_CN`, `SSL_CA_DAYS`); `ca.cer` (DER, for Windows / GPO); random passphrase → `ssl_ca_sec.conf.des3` | existing root is never overwritten (a new root = redistribute to every client – do it by hand: move `SSL_CA_DIR` away) |
| `server` | key (`SSL_KEY_ALGO` / size / curve) + CSR + certificate signed by the root (EKU `serverAuth`, SAN from `SSL_SAN`, `SSL_DAYS`); copies to `SSL_CERT_FILE`, `SSL_KEY_FILE`, `SSL_CHAIN_FILE` (= `ca.crt`) | existing valid certificate for the same CN is kept; `--renew` issues a new one (old files → `*.bak_<ts>`) |
| `codesign` | key + certificate (EKU `codeSigning`, `SSL_CODESIGN_CN`, `SSL_CODESIGN_DAYS`) → PKCS12 `FORMS_SIGN_KEYSTORE` with alias `FORMS_SIGN_ALIAS` and the root in the chain; random keystore password → `forms_sign_sec.conf.des3`; the plain key is deleted | as `server` |

All writes only with `--apply`. Values come from `ssl.conf` (no prompts –
the interactive way for the server certificate is
`ssl_prepare_cert.sh LOCALCA`) and from `environment.conf`
(`FORMS_SIGN_KEYSTORE`, `FORMS_SIGN_ALIAS`).

**CA directory** `SSL_CA_DIR` (default `$ORACLE_BASE/admin/pki`, owner
oracle, `chmod 700`, never in the repository, never below a web root):

```
$SSL_CA_DIR/
├── ca/ca.key            root key, AES-256 encrypted, 600
├── ca/ca.crt            root certificate (PEM)  → Linux / Java truststore / Nginx chain
├── ca/ca.cer            root certificate (DER)  → Windows certificate store / GPO
├── ca/ca.srl            serial number file
├── server/<cn>.key|.csr|.crt
└── codesign/codesign.crt, codesign.p12 (600)
```

**Timestamp (TSA):** `FORMS_SIGN_TSA_URL` (environment.conf) adds a trusted
timestamp to the `jacob.jar` signature – it stays valid after the
code-signing certificate expires. Test host (confirmed 2026-10-20,
`jarsigner -verify -verbose -certs`): signed by the local "Forms Code
Signing" certificate (expires 2029-10-17), timestamped by DigiCert
(timestamp valid until 2031-11-10). Without a TSA the jar becomes invalid
for Java Web Start on the day the certificate expires.

**Passwords:** never on the command line. The scripts decrypt the des3 file
(`load_secrets_file`), write the value to a temporary file (600, removed by
`trap`) and pass it as `-passin file:` / `-passout file:` (openssl) and
`-storepass:file` (jarsigner).

| des3 file (repository root, gitignored) | Variable | Used by |
|---|---|---|
| `ssl_ca_sec.conf.des3` | `SSL_CA_PASS` | `ssl_local_ca.sh` (signing with the root key) |
| `forms_sign_sec.conf.des3` | `FORMS_SIGN_STOREPASS` | `ssl_local_ca.sh codesign`, `09-Install/14-oracle_setup_forms.sh` |

The des3 files are bound to this machine (key = system identifier). Back up
`SSL_CA_DIR` **together with the plain passphrase** offline (password safe):
without the root key no further certificate can be issued under the same
root.

**Lifecycle:**

| Event | Action | Client impact |
|---|---|---|
| Server certificate expires (825 days) | `ssl_prepare_cert.sh LOCALCA --apply --renew` → `05-root_nginx_ssl.sh --apply` | none |
| Code-signing certificate expires (3 years) | `ssl_local_ca.sh codesign --apply --renew` → `14-oracle_setup_forms.sh --apply` (signs again only unsigned jars; timestamped signatures stay valid) | none |
| A Forms patch / new JACOB version replaces `jacob.jar` | `14-oracle_setup_forms.sh --apply` signs the new (unsigned) jar with the current certificate (`07-Maintenance/README.md` patch step 8) | none |
| Root expires (10 years) / root key lost | new root (`init` after moving `SSL_CA_DIR`), re-issue both leaves | **redistribute `ca.cer` to every client** |

**Distribution to the clients:** `ca.cer` into *Trusted Root Certification
Authorities* (GPO) – used by browsers and Java Web Start; for FSAL the
truststore of the FSAL JVM is needed (never the JRE `cacerts`, see
[forms_jakob_webutil.md §12](../80-FMW-Architecture/forms_jakob_webutil.md#12-distribution-concept-for-the-clients)). Linux test client:
`cp ca.crt /etc/pki/ca-trust/source/anchors/ && update-ca-trust`.

---

### ssl_config.sh

**Purpose:** Audit and report the current SSL configuration.

```bash
./08-SSL/ssl_config.sh           # full audit report
./08-SSL/ssl_config.sh --expiry  # certificate expiry check only
```

**Checks performed:**

| Check | Tool | Expected |
|---|---|---|
| Certificate file exists + readable | shell | OK |
| Certificate not expired | `openssl x509 -enddate` | Valid for > 30 days |
| Key matches certificate (public key) | `openssl x509 -pubkey` / `openssl pkey -pubout` | md5 match |
| SAN present | `openssl x509 -text` | `DNS:` entry found |
| TLS handshake succeeds | `openssl s_client` | `Verify return code: 0` |
| Protocol: no TLS 1.0 / 1.1 | `openssl s_client -tls1` | Connection refused |
| Protocol: TLS 1.2 + 1.3 available | `openssl s_client -tls1_2/3` | Handshake OK |
| Nginx cipher config | `grep ssl_protocols nginx.conf` | No SSLv3/TLS1.0 |
| WebLogic redirects behind Nginx | `config.xml`: `weblogic-plugin-enabled` / `frontend-host` | plugin enabled (OK) or Frontend Host = `SSL_CN`; WARN only if neither |
| Certificate expiry warning | `openssl x509 -enddate` | Warn at < 30 days |

**Output:** ok / warn / fail per check + summary.
Exit code 1 if expiry < 30 days, exit code 2 if expired or handshake fails.

---

## Configuration: ssl.conf

SSL certificate parameters are stored in a dedicated `08-SSL/ssl.conf` file –
separate from `environment.conf` because they belong to the SSL module, not to
the WebLogic environment.

| File | Git | Purpose |
|---|---|---|
| `ssl.conf.template` | committed | Reference with documented defaults |
| `ssl.conf` | **gitignored** | Server-specific values (CN, paths, key size …) |

### Interactive prompt with saved defaults

When `ssl_prepare_cert.sh` is called, it reads `ssl.conf` and shows each
current value as the prompt default:

```
  Common Name      [wls01.company.local]: _
  SAN              [DNS:wls01.company.local DNS:wls01]: _
  Organization     [Company GmbH]: _
  Country          [DE]: _
  Key algorithm    [RSA]: _
  Key size         [4096]: _
  Validity (days)  [825]: _
  Mode             [SELF]: _
```

The user can confirm each value (Enter) or type a new one.
After execution, `ssl.conf` is written back with the confirmed values so
the next run shows them as defaults again.

### ssl.conf Parameters

| Parameter | Description |
|---|---|
| `SSL_CN` | Common Name = external FQDN |
| `SSL_SAN` | Subject Alternative Names (space-separated: `DNS:host IP:1.2.3.4`) |
| `SSL_COUNTRY` | 2-letter ISO country code |
| `SSL_STATE` | State / Province |
| `SSL_CITY` | City |
| `SSL_ORG` | Organization |
| `SSL_ORG_UNIT` | Organizational Unit |
| `SSL_KEY_ALGO` | `RSA` or `EC` |
| `SSL_KEY_SIZE` | RSA key size: `2048` or `4096` |
| `SSL_EC_CURVE` | EC curve: `prime256v1` or `secp384r1` |
| `SSL_DAYS` | Certificate validity in days |
| `SSL_CERT_FILE` | Output path for certificate (staging area) |
| `SSL_KEY_FILE` | Output path for private key |
| `SSL_CHAIN_FILE` | Output path for CA chain / root cert |
| `SSL_CSR_FILE` | Output path for CSR (REQUEST mode) |
| `EASYRSA_PKI_DIR` | Easy-RSA PKI root directory (EASYRSA mode) |
| `EASYRSA_CA_DAYS` | CA certificate validity (new CA only) |
| `SSL_CA_DIR` | Local CA directory (`ssl_local_ca.sh`), default `$ORACLE_BASE/admin/pki` |
| `SSL_CA_CN` | Common Name of the local root CA, default `<SSL_ORG> Root CA` |
| `SSL_CA_DAYS` | Root CA validity in days, default `3650` |
| `SSL_CA_KEY_SIZE` | Root CA RSA key size, default `4096` |
| `SSL_CODESIGN_CN` | Common Name of the code-signing certificate, default `<SSL_ORG> Forms Code Signing` |
| `SSL_CODESIGN_DAYS` | Code-signing certificate validity in days, default `1095` |
| `SSL_LAST_MODE` | Last used mode – shown as default on next run |

`WLS_SERVER_FQDN` (from `environment.conf`) is used as the initial default
for `SSL_CN` when `ssl.conf` does not yet exist.

### First run (no ssl.conf yet)

```bash
# ssl.conf does not exist → ssl_prepare_cert.sh copies from ssl.conf.template,
# substitutes WLS_SERVER_FQDN as initial SSL_CN default, then prompts.
cp 08-SSL/ssl.conf.template 08-SSL/ssl.conf
# edit ssl.conf – or just run ssl_prepare_cert.sh and answer the prompts
./08-SSL/ssl_prepare_cert.sh SELF --apply
```

---

## Workflows

### Initial Installation

```
1. set up environment.conf  (WLS_SERVER_FQDN, SSL_* paths)
2. Choose certificate option:
   a. SELF:     ./08-SSL/ssl_prepare_cert.sh SELF --apply
   l. LOCALCA:  ./08-SSL/ssl_prepare_cert.sh LOCALCA --apply
                (+ Forms/WebUtil: ./08-SSL/ssl_local_ca.sh codesign --apply)
   b. EASYRSA:  ./08-SSL/ssl_prepare_cert.sh EASYRSA --apply
   c. REQUEST:  ./08-SSL/ssl_prepare_cert.sh REQUEST --apply
                → send CSR to CA → receive signed cert → set SSL_CERT_FILE
3. Deploy:      ./09-Install/05-root_nginx_ssl.sh --apply
4. Verify:      ./08-SSL/ssl_config.sh
```

### Certificate Renewal

```
1. Obtain new cert (EASYRSA re-issue or new CA-signed cert)
   l. Local CA: ./08-SSL/ssl_prepare_cert.sh LOCALCA --apply --renew
   a. Easy-RSA: ./08-SSL/ssl_prepare_cert.sh EASYRSA --apply  (re-issues)
   b. CA cert:  copy new cert to SSL_CERT_FILE / SSL_KEY_FILE manually
2. Deploy:      ./09-Install/05-root_nginx_ssl.sh --apply
3. Verify:      ./08-SSL/ssl_config.sh
```

### Regular Monitoring

```bash
# Check expiry (use in cron or monitoring)
./08-SSL/ssl_config.sh --expiry
# Exit 0 = OK, Exit 1 = expires in < 30 days, Exit 2 = expired
```

---

## Relationship to Other Scripts

| Script | Role |
|---|---|
| `09-Install/04-root_nginx.sh` | Install Nginx + generate base proxy config (upstream + location blocks) |
| `09-Install/05-root_nginx_ssl.sh` | Deploy cert to Nginx + inject SSL directives + start/reload Nginx |
| `08-SSL/ssl_prepare_cert.sh` | Create / prepare the certificate (all cert options) |
| `08-SSL/ssl_local_ca.sh` | Local root CA; server + code-signing certificates |
| `09-Install/14-oracle_setup_forms.sh` | Signs `jacob.jar` with `FORMS_SIGN_KEYSTORE` (code-signing certificate) |
| `08-SSL/ssl_config.sh` | Audit SSL config + expiry monitoring |
| `00-Setup/init_env.sh` | Sets `WLS_SERVER_FQDN`, `SSL_*` paths in `environment.conf` |
| `02-Checks/ssl_check.sh` | Host-wide TLS audit: who terminates TLS (Nginx / WLS / OHS), live TLS, WebLogic demo certificates / keystores |
| `07-Maintenance/backup_config.sh` | Does **not** back up `SSL_CA_DIR` on purpose – the CA key belongs in an offline backup (see above) |
| `10-Monitoring/` | candidate for the scheduled `ssl_local_ca.sh status` / `ssl_config.sh --expiry` run |

---

## Certificate Options Summary

| Option | Command | Trust | Use Case |
|---|---|---|---|
| Self-signed | `ssl_prepare_cert.sh SELF` | None (browser warning) | Smoke test only |
| Local CA (openssl) | `ssl_prepare_cert.sh LOCALCA` / `ssl_local_ca.sh` | Internal, after root import (one root also for code signing) | Lab / internal, **recommended** without company PKI |
| Easy-RSA internal CA | `ssl_prepare_cert.sh EASYRSA` | Internal, after CA root import | Alternative to LOCALCA (EPEL package) |
| Customer / public CA | `ssl_prepare_cert.sh REQUEST` → CA signs | Full (public) | Production |

> For Easy-RSA setup details see: `09-Install/docs/05-root_nginx_ssl.md`
> – section "Option B – Local CA with openssl", "Option C – Internal CA with Easy-RSA"

---

## Open Items (TODO)

- **Local CA – client side not yet tested:** Java Web Start checks
  revocation (`deployment.security.revocation.check`, default
  `ALL_CERTIFICATES`); the local CA publishes no CRL / OCSP. Whether Web
  Start accepts such a chain or needs a revocation setting / a CRL served by
  Nginx is open (Windows client test).

All three scripts are implemented (all four `ssl_prepare_cert.sh` modes,
`ssl_local_ca.sh`, all `ssl_config.sh` audit sections). What's still missing:

- **No automated cron job for expiry monitoring** — `ssl_config.sh --expiry`
  and `ssl_local_ca.sh status` already return cron-friendly exit codes
  (0/1/2), but nothing installs them as a scheduled job yet – candidate for
  `10-Monitoring/` (systemd timer like `cve_inventory.sh`).
- Consider `ssl_renew_easyrsa.sh` as a dedicated renewal script for Easy-RSA
  environments (currently: re-run `ssl_prepare_cert.sh EASYRSA --apply`,
  which re-issues but does not automate CA rotation).
- **Live-tested 2026-10-17:** `ssl_local_ca.sh` (init / server / codesign /
  status, idempotent second runs), `ssl_prepare_cert.sh LOCALCA --apply`,
  deploy with `05-root_nginx_ssl.sh --apply`, TLS handshake against the
  local root (`Verify return code: 0`), `ssl_config.sh` as oracle and root.
  Fixed on the way in `ssl_config.sh`: the handshake check used
  `s_client -brief` (prints no "Verify return code" → always FAIL), and
  an unreadable `/etc/nginx/ssl` (700 root) was reported as "not found".
- **Still limited real-world testing:** besides `SELF`, `LOCALCA` and the
  `ssl_config.sh` checks, nothing has been exercised end-to-end. The
  `EASYRSA` mode (against a real Easy-RSA install) and the `REQUEST` mode
  (CSR → external CA → cert install round-trip) still need verification on
  a real server.
- **Review 2026-10-20:** `ssl_local_ca.sh status` 11 OK (root until 2036,
  server 822 days, code signing until 2029, chains verified), `ssl_config.sh`
  (as oracle: Nginx config, TLS 1.0 rejected, 1.2 OK, handshake verified);
  the former "Frontend Host not configured" WARN was a false finding –
  redirects work through `WL-Proxy-SSL` + `weblogic-plugin-enabled`, the
  check now evaluates that. README: Nginx file names (`fullchain.pem` /
  `privkey.pem`, deployed by `05-`, not `03-`), WebLogic demo SSL ports,
  links to the architecture docs.
