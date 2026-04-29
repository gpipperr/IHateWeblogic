#!/bin/bash
# =============================================================================
# Script   : 05-root_nginx_ssl.sh
# Purpose  : Phase 0 – Deploy SSL certificate to Nginx and start the proxy.
#            Validates cert/key pair, copies to /etc/nginx/ssl/ with correct
#            permissions, runs nginx -t, and starts/reloads Nginx.
# Call     : ./09-Install/05-root_nginx_ssl.sh
#            ./09-Install/05-root_nginx_ssl.sh --apply
# Options  : --apply   Deploy certificate and start Nginx
#            --help    Show usage
# Requires : nginx, openssl
# Runs as  : root or oracle with sudo
# Ref      : 09-Install/docs/03-root_nginx_ssl.md
#            https://www.pipperr.de/dokuwiki/doku.php?id=prog:gitlab_oracle_linux_9
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"

LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m IHateWeblogic_lib.sh not found: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"

check_env_conf "$ENV_CONF" || exit 2
source "$ENV_CONF"
init_log

# =============================================================================
# Arguments
# =============================================================================

APPLY_MODE=0

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-16s %s\n" "--apply" "Deploy SSL certificate and start Nginx"
    printf "  %-16s %s\n" "--help"  "Show this help"
    printf "\nRequired environment.conf parameters:\n"
    printf "  SSL_CERT_FILE   path to certificate PEM (fullchain preferred)\n"
    printf "  SSL_KEY_FILE    path to private key PEM\n"
    printf "  SSL_CHAIN_FILE  path to CA chain PEM (optional, if not in fullchain)\n"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)   APPLY_MODE=1; shift ;;
        --help|-h) _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
    esac
done

# =============================================================================
# Root / sudo helpers
# =============================================================================

_can_sudo() { sudo -n true 2>/dev/null; }

_run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif _can_sudo; then
        sudo "$@"
    else
        warn "No root/sudo for: $*"
        info "  Run manually: sudo $*"
        return 1
    fi
}

_check_root_access() {
    if [ "$(id -u)" -eq 0 ]; then
        ok "Running as root"
    elif _can_sudo; then
        ok "Running as $(id -un) with sudo"
    else
        fail "Root or sudo access required"
        print_summary; exit 2
    fi
}

# =============================================================================
# Configuration
# =============================================================================

NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_CERT="$NGINX_SSL_DIR/fullchain.pem"
NGINX_KEY="$NGINX_SSL_DIR/privkey.pem"
NGINX_CONF="/etc/nginx/conf.d/oracle-wls.conf"

# Source certificate paths from environment.conf
SSL_CERT_FILE="${SSL_CERT_FILE:-}"
SSL_KEY_FILE="${SSL_KEY_FILE:-}"
SSL_CHAIN_FILE="${SSL_CHAIN_FILE:-}"

# Load 08-SSL/ssl.conf as fallback for SSL paths (set by ssl_prepare_cert.sh)
_SSL_CONF="$ROOT_DIR/08-SSL/ssl.conf"
if [ -f "$_SSL_CONF" ]; then
    # shellcheck source=../08-SSL/ssl.conf
    source "$_SSL_CONF"
    info "SSL paths loaded from: $_SSL_CONF"
fi
unset _SSL_CONF

# =============================================================================
# Banner
# =============================================================================

printLine
section "Nginx SSL Certificate Deployment – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-26s %s\n" "Nginx config:"    "$NGINX_CONF"                 | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "SSL directory:"   "$NGINX_SSL_DIR"              | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "SSL_CERT_FILE:"   "${SSL_CERT_FILE:-(not set)}" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "SSL_KEY_FILE:"    "${SSL_KEY_FILE:-(not set)}"  | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "SSL_CHAIN_FILE:"  "${SSL_CHAIN_FILE:-(not set)}"| tee -a "${LOG_FILE:-/dev/null}"
[ "$APPLY_MODE" -eq 1 ] && \
    printf "  %-26s %s\n" "Mode:" "APPLY (will deploy certificate and start Nginx)" \
        | tee -a "${LOG_FILE:-/dev/null}"
printLine

_check_root_access

# =============================================================================
# 1. Prerequisites
# =============================================================================

section "Prerequisites"

# Nginx installed?
if command -v nginx > /dev/null 2>&1; then
    ok "Nginx installed: $(nginx -v 2>&1 | head -1)"
else
    fail "Nginx not installed – run 04-root_nginx.sh --apply first"
    print_summary; exit 2
fi

# Config from 04-root_nginx.sh exists?
if [ -f "$NGINX_CONF" ]; then
    ok "Nginx WLS config exists: $NGINX_CONF"
else
    fail "Nginx WLS config not found: $NGINX_CONF"
    info "  Run 04-root_nginx.sh --apply first"
    print_summary; exit 2
fi

# openssl available?
if command -v openssl > /dev/null 2>&1; then
    ok "openssl available"
else
    fail "openssl not found – required for certificate validation"
    print_summary; exit 2
fi

# =============================================================================
# 2. Locate certificate files
# =============================================================================

section "Certificate Source Files"

# Interactive prompt – show current value as default, allow override
_prompt_ssl_path() {
    local label="$1"
    local -n _ref="$2"
    local _cur="${_ref:-}"
    local _input
    printf "  %-26s [\033[36m%s\033[0m]: " "$label" "$_cur" >&2
    read -r _input
    _ref="${_input:-$_cur}"
}

printf "  Review certificate paths (Enter = accept):\n\n"
_prompt_ssl_path "Certificate file (PEM)" SSL_CERT_FILE
_prompt_ssl_path "Private key file (PEM)" SSL_KEY_FILE
_prompt_ssl_path "CA chain file (optional)" SSL_CHAIN_FILE
printf "\n"

# Validate cert file exists and is readable
if [ -z "$SSL_CERT_FILE" ]; then
    fail "SSL_CERT_FILE not set in environment.conf"
    info "  Set SSL_CERT_FILE=/path/to/fullchain.pem"
    print_summary; exit 2
elif [ ! -f "$SSL_CERT_FILE" ]; then
    fail "Certificate file not found: $SSL_CERT_FILE"
    print_summary; exit 2
else
    ok "Certificate file found: $SSL_CERT_FILE"
fi

if [ -z "$SSL_KEY_FILE" ]; then
    fail "SSL_KEY_FILE not set in environment.conf"
    info "  Set SSL_KEY_FILE=/path/to/privkey.pem"
    print_summary; exit 2
elif [ ! -f "$SSL_KEY_FILE" ]; then
    fail "Key file not found: $SSL_KEY_FILE"
    print_summary; exit 2
else
    ok "Key file found: $SSL_KEY_FILE"
fi

# =============================================================================
# 3. Certificate validation
# =============================================================================

section "Certificate Validation"

# Expiry check
CERT_ENDDATE="$(openssl x509 -noout -enddate -in "$SSL_CERT_FILE" 2>/dev/null \
    | cut -d= -f2)"
CERT_SUBJECT="$(openssl x509 -noout -subject  -in "$SSL_CERT_FILE" 2>/dev/null \
    | sed 's/subject=//')"
CERT_ISSUER="$(openssl x509  -noout -issuer   -in "$SSL_CERT_FILE" 2>/dev/null \
    | sed 's/issuer=//')"

printf "  %-26s %s\n" "Subject:"  "$CERT_SUBJECT"  | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "Issuer:"   "$CERT_ISSUER"   | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "Expires:"  "$CERT_ENDDATE"  | tee -a "${LOG_FILE:-/dev/null}"

# Check expiry
DAYS_LEFT="$(openssl x509 -noout -checkend 0 -in "$SSL_CERT_FILE" 2>/dev/null \
    && echo "valid" || echo "expired")"
if [ "$DAYS_LEFT" = "expired" ]; then
    fail "Certificate has EXPIRED: $CERT_ENDDATE"
    print_summary; exit 2
fi

# Warn if expiring within 30 days
if ! openssl x509 -noout -checkend 2592000 -in "$SSL_CERT_FILE" > /dev/null 2>&1; then
    warn "Certificate expires within 30 days: $CERT_ENDDATE"
else
    ok "Certificate is valid and not expiring within 30 days"
fi

# Key matches certificate (modulus comparison)
CERT_MODULUS="$(openssl x509 -noout -modulus -in "$SSL_CERT_FILE" 2>/dev/null | md5sum)"
KEY_MODULUS="$(openssl rsa   -noout -modulus -in "$SSL_KEY_FILE"  2>/dev/null | md5sum)"

if [ "$CERT_MODULUS" = "$KEY_MODULUS" ]; then
    ok "Certificate and key match (modulus check)"
else
    fail "Certificate and private key do NOT match"
    info "  Certificate modulus: $(printf "%s" "$CERT_MODULUS" | cut -c1-16)..."
    info "  Key modulus:         $(printf "%s" "$KEY_MODULUS"  | cut -c1-16)..."
    print_summary; exit 2
fi

# Chain file (optional)
if [ -n "$SSL_CHAIN_FILE" ]; then
    if [ -f "$SSL_CHAIN_FILE" ]; then
        ok "Chain file found: $SSL_CHAIN_FILE"
    else
        warn "SSL_CHAIN_FILE set but not found: $SSL_CHAIN_FILE"
    fi
fi

# Self-signed warning
if [ "$CERT_SUBJECT" = "$CERT_ISSUER" ]; then
    warn "Certificate appears to be self-signed (Subject = Issuer)"
    info "  Self-signed certs will show browser warnings in production"
    info "  Acceptable for testing; use a CA-signed cert for production"
fi

# =============================================================================
# 4. Deploy certificate
# =============================================================================

section "Deploy Certificate to Nginx"

# Check current state
if [ -f "$NGINX_CERT" ]; then
    CURRENT_FINGERPRINT="$(openssl x509 -noout -fingerprint -in "$NGINX_CERT" 2>/dev/null)"
    SOURCE_FINGERPRINT="$(openssl x509 -noout -fingerprint -in "$SSL_CERT_FILE" 2>/dev/null)"
    if [ "$CURRENT_FINGERPRINT" = "$SOURCE_FINGERPRINT" ]; then
        ok "Certificate already deployed and up to date: $NGINX_CERT"
        CERT_DEPLOYED=1
    else
        warn "Different certificate already in $NGINX_CERT"
        info "  Will replace with: $SSL_CERT_FILE"
        CERT_DEPLOYED=0
    fi
else
    info "No certificate yet in: $NGINX_CERT"
    CERT_DEPLOYED=0
fi

if [ "$APPLY_MODE" -eq 1 ] && [ "${CERT_DEPLOYED:-0}" -eq 0 ]; then
    if askYesNo "Deploy certificate to $NGINX_SSL_DIR?" "y"; then
        # Ensure SSL dir exists
        _run_root mkdir -p "$NGINX_SSL_DIR"
        _run_root chmod 700 "$NGINX_SSL_DIR"

        # Build fullchain (cert + chain if separate) → fullchain.pem
        if [ -n "$SSL_CHAIN_FILE" ] && [ -f "$SSL_CHAIN_FILE" ]; then
            # Concatenate cert + chain into fullchain
            { cat "$SSL_CERT_FILE"; cat "$SSL_CHAIN_FILE"; } \
                | _run_root tee "$NGINX_CERT" > /dev/null
            ok "Fullchain written (cert + chain): $NGINX_CERT"
        else
            _run_root cp "$SSL_CERT_FILE" "$NGINX_CERT"
            ok "Certificate copied: $NGINX_CERT"
        fi

        # Copy key
        _run_root cp "$SSL_KEY_FILE" "$NGINX_KEY"

        # Set permissions (GitLab reference: 644 cert, 600 key)
        _run_root chmod 644 "$NGINX_CERT"
        _run_root chmod 600 "$NGINX_KEY"
        _run_root chown root:root "$NGINX_CERT" "$NGINX_KEY"
        ok "Permissions set: cert=644 key=600 (owner: root:root)"

        CERT_DEPLOYED=1
    fi
fi

# =============================================================================
# 5. Nginx validation and start
# =============================================================================

section "Nginx Configuration Validation"

if [ -f "$NGINX_CERT" ] && [ -f "$NGINX_KEY" ]; then
    # Full nginx -t validation
    if _run_root nginx -t 2>/tmp/nginx_test_output; then
        ok "Nginx config valid (nginx -t)"
    else
        fail "Nginx config syntax error:"
        cat /tmp/nginx_test_output | while IFS= read -r line; do
            fail "  $line"
        done
        rm -f /tmp/nginx_test_output
        info "  Check: sudo nginx -t"
        print_summary; exit 2
    fi
    rm -f /tmp/nginx_test_output
else
    warn "SSL files not yet in place – skipping nginx -t"
fi

section "Nginx Service"

NGINX_ACTIVE="$(systemctl is-active nginx 2>/dev/null)"
if [ "$NGINX_ACTIVE" = "active" ]; then
    ok "Nginx is running"
    if [ "$APPLY_MODE" -eq 1 ] && [ "${CERT_DEPLOYED:-0}" -eq 1 ]; then
        if askYesNo "Reload Nginx to apply new SSL certificate?" "y"; then
            _run_root systemctl reload nginx && ok "Nginx reloaded" || \
                fail "Nginx reload failed – run: sudo systemctl reload nginx"
        fi
    fi
else
    warn "Nginx is not running (state: $NGINX_ACTIVE)"
    if [ "$APPLY_MODE" -eq 1 ] && [ -f "$NGINX_CERT" ] && [ -f "$NGINX_KEY" ]; then
        if askYesNo "Start Nginx now?" "y"; then
            _run_root systemctl start nginx
            sleep 2
            if systemctl is-active nginx > /dev/null 2>&1; then
                ok "Nginx started successfully"
            else
                fail "Nginx failed to start"
                info "  Check: sudo journalctl -u nginx -n 50"
                print_summary; exit 2
            fi
        fi
    elif [ -z "$NGINX_CERT" ] || [ ! -f "$NGINX_CERT" ]; then
        info "Nginx will start after SSL certificate is deployed (--apply)"
    fi
fi

# =============================================================================
# 6. SSL Live Test
# =============================================================================

section "SSL Live Test"

SERVER_NAME="${WLS_SERVER_FQDN:-$(hostname -f 2>/dev/null)}"

if systemctl is-active nginx > /dev/null 2>&1; then
    # Quick TLS handshake test
    SSL_TEST="$(echo | timeout 5 openssl s_client \
        -connect "127.0.0.1:443" \
        -servername "$SERVER_NAME" \
        -brief 2>/dev/null | head -5)"

    if [ -n "$SSL_TEST" ]; then
        ok "TLS handshake successful"
        echo "$SSL_TEST" | while IFS= read -r line; do
            info "  $line"
        done
    else
        warn "TLS handshake test returned no output – verify manually:"
        info "  openssl s_client -connect localhost:443 -servername $SERVER_NAME"
    fi

    # HTTP→HTTPS redirect test
    HTTP_STATUS="$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 "http://127.0.0.1/" 2>/dev/null || echo "000")"
    if [ "$HTTP_STATUS" = "301" ]; then
        ok "HTTP → HTTPS redirect: 301 (correct)"
    elif [ "$HTTP_STATUS" = "000" ]; then
        warn "HTTP test: no response (port 80 not reachable?)"
    else
        warn "HTTP redirect returned $HTTP_STATUS (expected 301)"
    fi

    # Check /forms endpoint
    FORMS_STATUS="$(curl -sk -o /dev/null -w "%{http_code}" \
        --max-time 5 "https://127.0.0.1/forms/" 2>/dev/null || echo "000")"
    printf "  %-26s %s\n" "HTTPS /forms/ status:" "$FORMS_STATUS" \
        | tee -a "${LOG_FILE:-/dev/null}"
    # 200 or 302 = WLS responded; 502/503 = WLS not started yet (expected at this stage)
    case "$FORMS_STATUS" in
        200|302|301) ok "Forms endpoint reachable (WLS running)" ;;
        502|503|504) info "Forms endpoint: WLS not started yet (502/503/504 expected at install stage)" ;;
        000)         warn "Forms endpoint: no response from Nginx" ;;
        *)           info "Forms endpoint: HTTP $FORMS_STATUS" ;;
    esac
else
    info "Nginx not running – skipping live SSL test"
    info "  Start Nginx first: sudo systemctl start nginx"
fi

# =============================================================================
# Summary
# =============================================================================

printLine
if [ "$CNT_FAIL" -eq 0 ]; then
    info "Nginx SSL configuration complete."
    info "Phase 0 (root) is now finished."
    info "Switch to oracle user and continue:"
    info "  su - oracle"
    info "  cd ${ROOT_DIR}"
    info "  ./09-Install/04-oracle_pre_checks.sh"
fi

print_summary
exit "$EXIT_CODE"
