# 08-SSL – SSL Certificate Management

**Module:** `08-SSL/`
**Runs as:** `root` (cert deployment) / `oracle` (audit + CSR)
**Phase:** Operational – before initial start and on every certificate renewal

---

## Purpose

This module manages the **SSL certificate lifecycle** for the Oracle Forms &
Reports installation. It covers three recurring tasks:

| Task | Script | When |
|---|---|---|
| Prepare / create a certificate | `ssl_prepare_cert.sh` | Before first Nginx start and at renewal |
| Deploy certificate to Nginx | `09-Install/03-root_nginx_ssl.sh` | Install-time (once) and at renewal |
| Audit current SSL configuration | `ssl_config.sh` | Anytime – monitoring, compliance checks |

The module does **not** manage SSL inside WebLogic directly.
WebLogic listens on `127.0.0.1` only; SSL is terminated exclusively at Nginx.

---

## Architecture: SSL in This Installation

```
Internet / Browser
        │  HTTPS :443
        ▼
┌────────────────────────────────────────────────────────┐
│  Nginx  (SSL termination)                              │
│  /etc/nginx/ssl/server.crt  ← deployed by 03-root_    │
│  /etc/nginx/ssl/server.key    nginx_ssl.sh             │
│                                                        │
│  Protocols: TLSv1.2 + TLSv1.3 only                    │
│  Ciphers:   ECDHE / AES-GCM only                       │
└────────────────────────────────────────────────────────┘
        │  HTTP plain — loopback only (127.0.0.1)
        ▼
WebLogic (never handles TLS)
  AdminServer   127.0.0.1:7001
  WLS_FORMS     127.0.0.1:9001
  WLS_REPORTS   127.0.0.1:9002
```

**Consequences:**
- Only one certificate location: `/etc/nginx/ssl/`
- No Java KeyStore management inside WebLogic
- WebLogic must have **Frontend Host** set to the external FQDN so that
  server-generated redirects use the correct HTTPS URL
  (configured by `09-Install/08-oracle_setup_domain.sh` or manually via WLST)

---

## Certificate Lifecycle

```
┌──────────────────────────────────────────────────────────────────┐
│  1. PREPARE  (ssl_prepare_cert.sh)                               │
│     Choose one option:                                           │
│       A. Self-signed      → quick test, browser warning          │
│       B. Easy-RSA (internal CA) → trusted in internal network    │
│       C. Customer / Public CA   → receive signed cert from CA    │
│                                                                  │
│     Result: cert + key in staging path (SSL_CERT_FILE / _KEY)    │
│             stored in environment.conf                           │
└──────────────────┬───────────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────────────┐
│  2. DEPLOY  (09-Install/03-root_nginx_ssl.sh --apply)            │
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
│     - WebLogic Frontend Host setting check                       │
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
./08-SSL/ssl_prepare_cert.sh EASYRSA   # Easy-RSA internal CA workflow
./08-SSL/ssl_prepare_cert.sh REQUEST   # generate CSR for customer/public CA
```

**Mode: SELF** (`--apply`)
- `openssl req -x509` → self-signed cert + key
- Output: `SSL_CERT_FILE`, `SSL_KEY_FILE` (paths from `environment.conf`)
- Use case: smoke test before customer cert arrives

**Mode: EASYRSA** (`--apply`)
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

**Does NOT deploy** → run `03-root_nginx_ssl.sh --apply` afterwards.

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
| Key matches certificate (modulus) | `openssl x509 / rsa -modulus` | md5 match |
| SAN present | `openssl x509 -text` | `DNS:` entry found |
| TLS handshake succeeds | `openssl s_client` | `Verify return code: 0` |
| Protocol: no TLS 1.0 / 1.1 | `openssl s_client -tls1` | Connection refused |
| Protocol: TLS 1.2 + 1.3 available | `openssl s_client -tls1_2/3` | Handshake OK |
| Nginx cipher config | `grep ssl_protocols nginx.conf` | No SSLv3/TLS1.0 |
| WebLogic Frontend Host | WLST or REST API | Matches `WLS_SERVER_FQDN` |
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
   b. EASYRSA:  ./08-SSL/ssl_prepare_cert.sh EASYRSA --apply
   c. REQUEST:  ./08-SSL/ssl_prepare_cert.sh REQUEST --apply
                → send CSR to CA → receive signed cert → set SSL_CERT_FILE
3. Deploy:      ./09-Install/03-root_nginx_ssl.sh --apply
4. Verify:      ./08-SSL/ssl_config.sh
```

### Certificate Renewal

```
1. Obtain new cert (EASYRSA re-issue or new CA-signed cert)
   a. Easy-RSA: ./08-SSL/ssl_prepare_cert.sh EASYRSA --apply  (re-issues)
   b. CA cert:  copy new cert to SSL_CERT_FILE / SSL_KEY_FILE manually
2. Deploy:      ./09-Install/03-root_nginx_ssl.sh --apply
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
| `09-Install/02-root_nginx.sh` | Install Nginx + generate base proxy config (upstream + location blocks) |
| `09-Install/03-root_nginx_ssl.sh` | Deploy cert to Nginx + inject SSL directives + start/reload Nginx |
| `08-SSL/ssl_prepare_cert.sh` | Create / prepare the certificate (all three cert options) |
| `08-SSL/ssl_config.sh` | Audit SSL config + expiry monitoring |
| `00-Setup/init_env.sh` | Sets `WLS_SERVER_FQDN`, `SSL_*` paths in `environment.conf` |

---

## Certificate Options Summary

| Option | Command | Trust | Use Case |
|---|---|---|---|
| Self-signed | `ssl_prepare_cert.sh SELF` | None (browser warning) | Smoke test only |
| Easy-RSA internal CA | `ssl_prepare_cert.sh EASYRSA` | Internal, after CA root import | Internal / lab / dev |
| Customer / public CA | `ssl_prepare_cert.sh REQUEST` → CA signs | Full (public) | Production |

> For Easy-RSA setup details see: `09-Install/docs/03-root_nginx_ssl.md`
> – section "Option B – Internal CA with Easy-RSA"

---

## Open Items (TODO)

- `ssl_prepare_cert.sh` – implement all three modes
- `ssl_config.sh` – implement audit checks
- Cron / monitoring integration for expiry alerting
- Consider `ssl_renew_easyrsa.sh` as dedicated renewal script for Easy-RSA environments
