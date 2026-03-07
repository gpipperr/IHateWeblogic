# Step 04 – 04-root_nginx.sh

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
3. Checks for any unresolved `##PARA##` placeholders (warns if found)
4. Shows a 30-line preview of the generated configuration
5. Installs Nginx via `dnf` if missing (asks for confirmation with `--apply`)
6. Enables Nginx for autostart (`systemctl enable nginx`) — does NOT start it
7. Creates `/etc/nginx/ssl/` directory (mode 700) for certificate storage
8. Backs up existing `oracle-wls.conf` before overwriting
9. Deploys generated config to `/etc/nginx/conf.d/oracle-wls.conf`
10. Skips `nginx -t` validation if SSL certs are not yet in place
11. Detects and disables conflicting `/etc/nginx/conf.d/default.conf`

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
- `HSTS` header is commented out in the template — enable only after verifying SSL works
  to avoid locking out users if the cert is replaced incorrectly

---

## References

| Topic | URL |
|---|---|
| Oracle APEX + Nginx + Tomcat proxy config (Windows, template concept) | https://www.pipperr.de/dokuwiki/doku.php?id=prog:oracle_apex_nginx_tomcat_ords_install_windows_server |
| GitLab on Oracle Linux 9 – Nginx reverse proxy + SSL handling | https://www.pipperr.de/dokuwiki/doku.php?id=prog:gitlab_oracle_linux_9 |
| Easy-RSA CA on Oracle Linux 9 – SSL certificate creation with simple tools | https://www.pipperr.de/dokuwiki/doku.php?id=linux:ca_on_oracle_linux_9 |
