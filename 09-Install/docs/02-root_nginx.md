# Step 0c – 02-root_nginx.sh

**Script:** `09-Install/02-root_nginx.sh`
**Runs as:** `root` or `oracle` with sudo
**Phase:** 0 – OS Preparation

---

## Purpose

Install Nginx and generate a reverse proxy configuration that forwards external requests
to WebLogic managed servers. WebLogic listens only on `127.0.0.1`; Nginx is the sole
external entry point.

---

## Without the Script (manual)

### 1. Install Nginx

```bash
dnf install -y nginx
systemctl enable nginx
```

### 2. Create proxy configuration

Create `/etc/nginx/conf.d/oracle-fmw.conf`:

```nginx
# Upstream targets (WebLogic listens on 127.0.0.1 only)
upstream wls_forms {
    server 127.0.0.1:9001;
    keepalive 32;
}
upstream wls_reports {
    server 127.0.0.1:9002;
    keepalive 32;
}
upstream wls_admin {
    server 127.0.0.1:7001;
    keepalive 16;
}

# HTTP → HTTPS redirect
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    return 301 https://$host$request_uri;
}

# HTTPS proxy (SSL directives added by 03-root_nginx_ssl.sh)
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name _;

    # Proxy settings
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_connect_timeout 300s;
    proxy_read_timeout    300s;
    proxy_send_timeout    300s;

    # Forms
    location /forms/ {
        proxy_pass http://wls_forms;
    }

    # Reports
    location /reports/ {
        proxy_pass http://wls_reports;
    }

    # WebLogic Admin Console (restrict to admin IPs)
    location /console {
        # allow 10.0.0.0/8;   # adjust to your admin network
        # deny all;
        proxy_pass http://wls_admin;
    }

    # OHS compatibility path
    location /weblogic/ {
        proxy_pass http://wls_admin;
    }
}
```

### 3. Validate and start

```bash
nginx -t
systemctl start nginx
systemctl status nginx
```

### 4. Open firewall port

```bash
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --reload
```

---

## What the Script Does

- Checks if Nginx is installed; installs via `sudo dnf install nginx` if missing
- Reads ports (`WLS_FORMS_PORT`, `WLS_REPORTS_PORT`, `WLS_ADMIN_PORT`) from `environment.conf`
- Generates `/etc/nginx/conf.d/oracle-fmw.conf` from the template above, substituting ports
- Backs up existing config if present
- Runs `nginx -t` to validate before activating
- Does NOT start Nginx yet (start happens in `03-root_nginx_ssl.sh` after SSL is configured)
- Optionally opens firewall ports if `firewall-cmd` is available

---

## Flags

| Flag | Description |
|---|---|
| (none) | Show generated config, make no changes |
| `--apply` | Write config file, enable Nginx |
| `--help` | Show usage |

---

## Verification

```bash
nginx -t
# Expected: syntax is ok / test is successful

cat /etc/nginx/conf.d/oracle-fmw.conf
# Verify ports match environment.conf values

systemctl is-enabled nginx
# Expected: enabled
```

---

## Notes

- SSL directives (`ssl_certificate`, `ssl_certificate_key`, `ssl_protocols`, `ssl_ciphers`)
  are added by `03-root_nginx_ssl.sh` — do not add them here
- The `location /console` block should restrict access to admin IPs in production;
  the script emits a WARN if no IP restriction is configured
