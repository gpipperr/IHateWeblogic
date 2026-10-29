# Step 04 – 04-root_nginx.sh

> Certificates, keys and trust stores of the whole stack (terms, where what lives, who needs what, customer PKI / TLS interception): [certificates_trust_stores.md](../../80-FMW-Architecture/certificates_trust_stores.md)

**Script:** `09-Install/04-root_nginx.sh`
**Template:** `09-Install/nginx-wls.conf.template`
**Runs as:** `root` or `oracle` with sudo
**Phase:** 0 – OS Preparation

---

## Purpose

Install Nginx and generate a reverse proxy configuration that forwards external HTTPS requests
to WebLogic managed servers (Forms, Reports, AdminServer).

WebLogic listens **only on `127.0.0.1`** — Nginx is the sole external entry point.
SSL termination happens at Nginx; WebLogic sees plain HTTP internally.

This script **does not start Nginx** — SSL certificates must be in place first.
Start happens in `05-root_nginx_ssl.sh`.

Background: [how the parts are joined](../../80-FMW-Architecture/weblogic_middleware_architecture.md#6-how-the-parts-are-joined),
[consoles – who provides what](../../80-FMW-Architecture/weblogic_middleware_architecture.md#5-consoles--who-provides-what)
(`/console`, `/em` behind `ADMIN_IP_RANGE`), [loopback-only layout](../../80-FMW-Architecture/clone_golden_image.md),
Reports web commands – [doc 81](81-reports_rwservlet_security.md), ORDS / APEX
include directory `oracle-wls.d/` – [apex_architecture.md](../../80-FMW-Architecture/apex_architecture.md).

---

## Without the Script (manual)

### 1. Install Nginx

```bash
dnf install -y nginx
systemctl enable nginx
```

### 2. Create the proxy configuration

Create `/etc/nginx/conf.d/oracle-wls.conf`.
A complete reference configuration is shown in [nginx-wls.conf.template](../nginx-wls.conf.template).

Key design decisions to apply manually:

- `proxy_http_version 1.1` + `proxy_set_header Connection ""` → enable upstream keep-alive
- `proxy_set_header WL-Proxy-Client-IP $remote_addr` → WebLogic identifies the real client
- `proxy_set_header WL-Proxy-SSL true` → tells WLS the request came in via HTTPS
- `proxy_set_header X-Forwarded-Proto https` → used by WLS URL rewriting
- `proxy_set_header X-Forwarded-For $remote_addr` → overwrite, not append
  (`$proxy_add_x_forwarded_for` would keep a client-supplied chain)
- **Strip client-supplied WebLogic headers** (`proxy_set_header <name> "";`):
  `WL-Proxy-Client-Cert/-Keysize/-Secretkeysize/-Port`, `WL-PATH-TRIM/-PREPEND`,
  the known `X-WebLogic-*` control headers, `tyrus-connection-id` – the Nginx
  counterpart of the OHS / mod_wl hardening of CPU Oct 2026 (MOS KB559857);
  with `weblogic-plugin-enabled` WebLogic trusts these headers
- **No `proxy_set_header` inside a WebLogic `location`** – Nginx inherits the
  server-level headers only if the location sets none; one line drops all of
  them (the `/console` location had this bug until 2026-10-26: `Host` =
  upstream name, client-supplied `WL-Proxy-Client-IP` passed through)
- `/console` and `/em` locations: restrict to admin IP range (`allow 10.0.0.0/8; deny all;`)
- `/forms/` cookie path rewriting: `proxy_cookie_path /forms /forms;` (session tracking)
- `/reports/` extended timeouts: `proxy_read_timeout 300s;` (large job output)

### 3. Disable default.conf (if present)

OL9 nginx ships a `default.conf` that creates a conflicting server block on port 80:

```bash
mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled
```

### 4. Verify nginx.conf includes conf.d

The `/etc/nginx/nginx.conf` must contain (standard OL9 nginx package includes this):

```nginx
include /etc/nginx/conf.d/*.conf;
```

Note: conf.d files must **not** contain an `http {}` block — they are already inside
the `http {}` block of `nginx.conf`.

### 5. Validate config (after SSL certs are in place)

```bash
nginx -t
# Expected: syntax is ok / test is successful
```

---

## What the Script Does

1. Reads `environment.conf` for port and hostname values
2. Substitutes `##VARIABLE##` placeholders in `nginx-wls.conf.template` → temp config
3. Keeps the optional block `#@FORMS_CLIENT_BEGIN@` … `#@FORMS_CLIENT_END@`
   (Forms client bundle) only when `FORMS_CLIENT_DIST=true` and Forms is
   installed – otherwise the whole block is removed
4. Checks for any unresolved `##PARA##` placeholders (warns if found)
5. Shows a 30-line preview of the generated configuration
6. Installs Nginx via `dnf` if missing (asks for confirmation with `--apply`)
7. Enables Nginx for autostart (`systemctl enable nginx`) — does NOT start it
8. Creates `/etc/nginx/ssl/` directory (mode 700) for certificate storage
9. Backs up existing `oracle-wls.conf` before overwriting (as root – the
   directory is root-owned; no backup = nothing deployed)
10. Deploys generated config to `/etc/nginx/conf.d/oracle-wls.conf` and
    creates `/etc/nginx/oracle-wls.d/` – the template includes
    `/etc/nginx/oracle-wls.d/*.conf` **inside the 443 server block**: one file
    per further application (APEX / ORDS: `ords_N.conf`, written by
    `12-APEX-Ords/05-setup-nginx.sh`). Not below `conf.d/` – those files are
    loaded at `http{}` level, where `location` is not allowed
11. `nginx -t` if the SSL certs are in place (checked as root – `/etc/nginx/ssl`
    is mode 700), then **reloads a running Nginx**; a failed `nginx -t`
    restores the backup at once (Nginx keeps running unchanged). Without
    certs (first installation) validation and reload follow with
    `05-root_nginx_ssl.sh`. Fixed 2026-10-23: run as oracle with sudo, the
    cert check and the backup failed silently and the new configuration was
    written but never loaded
12. Detects and disables conflicting `/etc/nginx/conf.d/default.conf`

---

## Template Variables

| Placeholder | Source | Default |
|---|---|---|
| `##SERVER_NAME##` | `WLS_SERVER_FQDN` | `hostname -f` |
| `##WLS_FORMS_PORT##` | `WLS_FORMS_PORT` | `9001` |
| `##WLS_REPORTS_PORT##` | `WLS_REPORTS_PORT` | `9002` |
| `##WLS_ADMIN_PORT##` | `WLS_ADMIN_PORT` | `7001` |
| `##SSL_CERT##` | derived | `/etc/nginx/ssl/fullchain.pem` |
| `##SSL_KEY##` | derived | `/etc/nginx/ssl/privkey.pem` |
| `##ADMIN_IP_RANGE##` | `ADMIN_IP_RANGE` | `10.0.0.0/8` |
| `##FORMS_CLIENT_URL_PATH##` | `FORMS_CLIENT_URL_PATH` (only `FORMS_CLIENT_DIST=true`) | `/formsWeb` |
| `##FORMS_CLIENT_DIR##` | `FORMS_CLIENT_DIR` (only `FORMS_CLIENT_DIST=true`) | `/srv/formsWeb` |

### Reports admin web commands – not from outside

`/reports/` is proxied as a whole (report URLs of the users), but the admin
web commands of `rwservlet` are limited to localhost and `ADMIN_IP_RANGE`
(test series of [81-reports_rwservlet_security.md](81-reports_rwservlet_security.md):
with `webcommandaccess=L2` they answered **without login through Nginx**;
with `L1` they still show server, job and environment details to anyone
who knows a password):

```nginx
location ~* ^/reports/rwservlet/(getserverinfo|showjobs|showenv|showmap|showauth|delauth|killjobid|parsequery|stopserver) {
    allow 127.0.0.1;
    allow ##ADMIN_IP_RANGE##;
    deny  all;
    proxy_pass http://wls_reports;
}
```

- `getjobid`, `showjobid`, `showmyjobs` stay open – users fetch the output of
  their own jobs with them.
- Our status checks (`01-Run/rwserver_status.sh`, `05-ReportsPerformance/`,
  cookbooks) call `http://localhost:<WLS_REPORTS_PORT>` directly, not through
  Nginx – not affected.
- Existing installations: re-run `09-Install/04-root_nginx.sh --apply` (root);
  check from outside: `curl -k https://<host>/reports/rwservlet/getserverinfo`
  → HTTP 403.

### Forms client bundle location (`FORMS_CLIENT_DIST=true`)

Static, read-only delivery of the client bundle (concept
[40-forms_client_distribution.md](40-forms_client_distribution.md)) in the
same HTTPS server block as `/forms/`:

```nginx
location /formsWeb/ {                        # FORMS_CLIENT_URL_PATH
    alias /srv/formsWeb/;                    # FORMS_CLIENT_DIR (oracle:oinstall 755)
    autoindex off;                           # no directory listing
    types { application/json json; application/zip zip;
            application/java-archive jar; text/plain ps1; }
    default_type application/octet-stream;   # dll, cmd (the browser downloads
                                             # FormsWeb-Install.cmd instead of showing it)
}
location = /formsWeb/manifest.json {         # checked on every client start
    alias /srv/formsWeb/manifest.json;
    default_type application/json;
    add_header Cache-Control "no-cache" always;   # revalidate; ETag -> HTTP 304
}
location = /formsWeb { return 301 /formsWeb/; }
```

- `manifest.json` has its own exact-match location instead of a nested
  regex location – `alias` and nested regex locations do not combine
  reliably in Nginx.
- Nginx sends `ETag` / `Last-Modified` for static files by default, so an
  unchanged manifest is answered with HTTP 304.
- Nginx only reads; the bundle is written by `40-` as oracle. SELinux
  enforcing (customer hosts): `httpd_sys_content_t` on `FORMS_CLIENT_DIR`.

---

## Flags

| Flag | Description |
|---|---|
| (none) | Show substituted config preview, make no changes |
| `--apply` | Install Nginx, deploy config, enable service |
| `--help` | Show usage |

---

## Verification

```bash
# Config syntax (only after SSL certs are deployed by 05-root_nginx_ssl.sh)
nginx -t

# Verify ports and server_name match environment.conf
grep -E "server_name|upstream|proxy_pass|ssl_certificate" /etc/nginx/conf.d/oracle-wls.conf

# Service enabled for autostart
systemctl is-enabled nginx
# Expected: enabled

# No conflicting default config
ls /etc/nginx/conf.d/
# Should NOT contain default.conf (only oracle-wls.conf)
```

---

## Notes

- Nginx is **not started** by this script — SSL certificates must be deployed first
- Run `05-root_nginx_ssl.sh --apply` to deploy certificates, validate, and start Nginx
- WebLogic `WL-Proxy-*` headers are required for correct client IP tracking and
  SSL-aware URL generation inside WebLogic (forms redirect URLs, cookie domains)
- Live test 2026-10-26 (spoofed headers via `curl`, `tcpdump -i lo` on the
  upstream ports): before the change every client-supplied `WL-*` /
  `X-WebLogic-*` / `tyrus-connection-id` header reached WebLogic and
  `X-Forwarded-For` was `6.6.6.6, <client>`; after it only `Host`,
  `WL-Proxy-Client-IP`, `WL-Proxy-SSL`, `X-Forwarded-For`, `X-Real-IP` with the
  real client address arrive on `/forms`, `/reports`, `/console`, `/em`.
- AdminServer `weblogic-plugin-enabled` (set 2026-10-26, domain template +
  live): `/console` / `/em` now redirect to `https://<FQDN>/…` directly –
  before, the AdminServer ignored `WL-Proxy-SSL` and redirected to `http://`
  first ([docs/08](08-oracle_setup_domain.md#adminserver-weblogic-plugin-enabled-since-2026-10-26))
- `HSTS` header is commented out in the template — enable only after verifying SSL works
  to avoid locking out users if the cert is replaced incorrectly

---

## References

| Topic | URL |
|---|---|
| Oracle APEX + Nginx + Tomcat proxy config (Windows, template concept) | https://www.pipperr.de/dokuwiki/doku.php?id=prog:oracle_apex_nginx_tomcat_ords_install_windows_server |
| GitLab on Oracle Linux 9 – Nginx reverse proxy + SSL handling | https://www.pipperr.de/dokuwiki/doku.php?id=prog:gitlab_oracle_linux_9 |
| Easy-RSA CA on Oracle Linux 9 – SSL certificate creation with simple tools | https://www.pipperr.de/dokuwiki/doku.php?id=linux:ca_on_oracle_linux_9 |
