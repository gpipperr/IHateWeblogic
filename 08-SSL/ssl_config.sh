#!/bin/bash
# =============================================================================
# Script   : ssl_config.sh
# Purpose  : Audit the current SSL configuration:
#            – Certificate file validity (exists, not expired, key matches)
#            – SAN presence
#            – Nginx SSL configuration (cert deployed, protocols, ciphers)
#            – Live TLS handshake test (if port 443 is listening)
#            – TLS protocol compliance (TLS 1.0/1.1 must be rejected)
#            – WebLogic Frontend Host setting (config.xml)
#
# Call     : ./08-SSL/ssl_config.sh
#            ./08-SSL/ssl_config.sh --expiry
#
#            (no flag)  : Full audit – all checks
#            --expiry   : Expiry check only (for cron / monitoring)
#                         Exit 0 = OK (> 30 days), 1 = < 30 days, 2 = expired
#
# Requires : openssl, ss (or netstat), awk
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_SH="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"

# --- Source library -----------------------------------------------------------
if [ ! -f "$LIB_SH" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB_SH" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB_SH"

# --- Source environment.conf --------------------------------------------------
check_env_conf "$ROOT_DIR/environment.conf" || exit 2
# shellcheck source=../environment.conf
source "$ROOT_DIR/environment.conf"

# =============================================================================
# Load ssl.conf
# =============================================================================
SSL_CONF="$SCRIPT_DIR/ssl.conf"
SSL_CONF_TEMPLATE="$SCRIPT_DIR/ssl.conf.template"

SSL_CN="${WLS_SERVER_FQDN:-}"
SSL_CERT_FILE="/etc/nginx/ssl/server.crt"
SSL_KEY_FILE="/etc/nginx/ssl/server.key"
SSL_CHAIN_FILE=""

if [ -f "$SSL_CONF" ]; then
    # shellcheck source=ssl.conf
    source "$SSL_CONF"
elif [ -f "$SSL_CONF_TEMPLATE" ]; then
    source "$SSL_CONF_TEMPLATE"
    SSL_CN="${WLS_SERVER_FQDN:-$SSL_CN}"
fi

# Nginx deployed cert location (always checked regardless of staging path)
NGINX_CERT="/etc/nginx/ssl/server.crt"
NGINX_KEY="/etc/nginx/ssl/server.key"
NGINX_CONF="/etc/nginx/conf.d/oracle-fmw.conf"
EXPIRY_WARN_DAYS=30

# =============================================================================
# Arguments
# =============================================================================
EXPIRY_ONLY=false

for _arg in "$@"; do
    case "$_arg" in
        --expiry)  EXPIRY_ONLY=true ;;
        --help|-h)
            printf "Usage: %s [--expiry]\n\n" "$(basename "$0")"
            printf "  (none)    Full SSL audit\n"
            printf "  --expiry  Certificate expiry check only (for cron/monitoring)\n"
            printf "            Exit: 0=OK, 1=expires<30d, 2=expired\n"
            exit 0 ;;
        *) warn "Unknown argument: $_arg" ;;
    esac
done
unset _arg

# --- Log setup ----------------------------------------------------------------
LOG_FILE="$ROOT_DIR/log/$(date +%Y%m%d)/ssl_config_$(date +%H%M%S).log"
mkdir -p "$(dirname "$LOG_FILE")"
{
    printf "# ssl_config.sh log\n"
    printf "# Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# Host    : %s\n" "$(_get_hostname)"
    printf "# Mode    : %s\n" "$( $EXPIRY_ONLY && printf 'expiry-only' || printf 'full-audit' )"
} > "$LOG_FILE"

# =============================================================================
# Header
# =============================================================================
printLine
printf "\n\033[1m  IHateWeblogic – SSL Configuration Audit\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host      : %s\n" "$(_get_hostname)"   | tee -a "$LOG_FILE"
printf "  Cert file : %s\n" "$NGINX_CERT"        | tee -a "$LOG_FILE"
printf "  Log       : %s\n" "$LOG_FILE"          | tee -a "$LOG_FILE"
printLine

# =============================================================================
# Helper: days until certificate expires
# Returns number of days (negative = already expired)
# =============================================================================
_cert_days_remaining() {
    local cert_file="$1"
    local end_date
    end_date="$(openssl x509 -noout -enddate -in "$cert_file" 2>/dev/null \
                | cut -d= -f2)"
    if [ -z "$end_date" ]; then printf -- "-9999"; return; fi

    local end_epoch now_epoch
    end_epoch="$(date -d "$end_date" +%s 2>/dev/null)"
    now_epoch="$(date +%s)"
    printf "%d" "$(( (end_epoch - now_epoch) / 86400 ))"
}

# =============================================================================
# Check: Certificate expiry
# =============================================================================
_check_expiry() {
    local cert_file="$1"

    if [ ! -f "$cert_file" ]; then
        fail "Certificate file not found: $cert_file"
        return 2
    fi

    local days
    days="$(_cert_days_remaining "$cert_file")"
    local end_date
    end_date="$(openssl x509 -noout -enddate -in "$cert_file" 2>/dev/null | cut -d= -f2)"

    if [ "$days" -lt 0 ]; then
        fail "$(printf "Certificate EXPIRED %d days ago (%s)" "$(( -days ))" "$end_date")"
        return 2
    elif [ "$days" -lt "$EXPIRY_WARN_DAYS" ]; then
        warn "$(printf "Certificate expires in %d days (%s)" "$days" "$end_date")"
        return 1
    else
        ok "$(printf "Certificate valid for %d more days (%s)" "$days" "$end_date")"
        return 0
    fi
}

# =============================================================================
# Expiry-only mode (for cron / monitoring)
# =============================================================================
if $EXPIRY_ONLY; then
    section "Certificate Expiry Check"
    _check_expiry "$NGINX_CERT"
    _expiry_rc=$?
    print_summary
    exit "$_expiry_rc"
fi

# =============================================================================
# Full audit
# =============================================================================

# --- 1. Certificate file checks -----------------------------------------------
section "Certificate Files"

if [ ! -f "$NGINX_CERT" ]; then
    fail "Nginx cert not found: $NGINX_CERT"
    info "  Run: ./09-Install/03-root_nginx_ssl.sh --apply"
else
    ok "Nginx cert found: $NGINX_CERT"
fi

if [ ! -f "$NGINX_KEY" ]; then
    fail "Nginx key not found: $NGINX_KEY"
else
    ok "Nginx key found: $NGINX_KEY"
    _key_perms="$(stat -c '%a' "$NGINX_KEY" 2>/dev/null)"
    if [ "$_key_perms" = "600" ]; then
        ok "Key permissions: 600 (correct)"
    else
        warn "Key permissions: $_key_perms (expected 600)"
    fi
fi

# --- 2. Certificate expiry ----------------------------------------------------
section "Certificate Expiry"

if [ -f "$NGINX_CERT" ]; then
    _check_expiry "$NGINX_CERT"
fi

# --- 3. Certificate details ---------------------------------------------------
section "Certificate Details"

if [ -f "$NGINX_CERT" ]; then
    info "Subject:"
    openssl x509 -noout -subject -in "$NGINX_CERT" 2>/dev/null \
        | sed 's/^/  /' | tee -a "$LOG_FILE"
    info "Issuer:"
    openssl x509 -noout -issuer -in "$NGINX_CERT" 2>/dev/null \
        | sed 's/^/  /' | tee -a "$LOG_FILE"
    info "Subject Alternative Names:"
    openssl x509 -noout -text -in "$NGINX_CERT" 2>/dev/null \
        | grep -A2 "Subject Alternative" | sed 's/^/  /' | tee -a "$LOG_FILE"

    # SAN present?
    if openssl x509 -noout -text -in "$NGINX_CERT" 2>/dev/null \
            | grep -q "Subject Alternative Name"; then
        ok "SAN extension present"
    else
        warn "No SAN extension found – modern browsers require SAN"
        info "  Re-generate certificate with ssl_prepare_cert.sh"
    fi

    # CN in SAN?
    if [ -n "$SSL_CN" ] && openssl x509 -noout -text -in "$NGINX_CERT" 2>/dev/null \
            | grep -q "DNS:$SSL_CN"; then
        ok "CN ($SSL_CN) present in SAN"
    elif [ -n "$SSL_CN" ]; then
        warn "CN ($SSL_CN) NOT found in SAN"
    fi
fi

# --- 4. Key matches certificate -----------------------------------------------
section "Key / Certificate Match"

if [ -f "$NGINX_CERT" ] && [ -f "$NGINX_KEY" ]; then
    _cert_pub="$(openssl x509 -noout -pubkey -in "$NGINX_CERT" 2>/dev/null | md5sum)"
    _key_pub="$(openssl pkey -pubout -in "$NGINX_KEY" 2>/dev/null | md5sum)"
    if [ "$_cert_pub" = "$_key_pub" ] && [ -n "$_cert_pub" ]; then
        ok "Private key matches certificate (public key identical)"
    else
        fail "Key does NOT match certificate – mismatch or corrupted file"
        info "  Re-generate with ssl_prepare_cert.sh and redeploy"
    fi
fi

# --- 5. Staging cert in sync with Nginx cert ----------------------------------
section "Staging vs Nginx Certificate"

if [ -n "$SSL_CERT_FILE" ] && [ -f "$SSL_CERT_FILE" ] && [ -f "$NGINX_CERT" ]; then
    _staging_fp="$(openssl x509 -noout -fingerprint -sha256 -in "$SSL_CERT_FILE" 2>/dev/null)"
    _nginx_fp="$(openssl x509 -noout -fingerprint -sha256 -in "$NGINX_CERT" 2>/dev/null)"
    if [ "$_staging_fp" = "$_nginx_fp" ]; then
        ok "Nginx cert matches staging source (in sync)"
    else
        warn "Nginx cert differs from staging source: $SSL_CERT_FILE"
        info "  Re-deploy: ./09-Install/03-root_nginx_ssl.sh --apply"
    fi
elif [ -n "$SSL_CERT_FILE" ] && [ ! -f "$SSL_CERT_FILE" ]; then
    info "Staging cert not found ($SSL_CERT_FILE) – skipping sync check"
fi

# --- 6. Nginx configuration ---------------------------------------------------
section "Nginx SSL Configuration"

if [ ! -f "$NGINX_CONF" ]; then
    warn "Nginx config not found: $NGINX_CONF"
    info "  Run: ./09-Install/02-root_nginx.sh --apply"
else
    ok "Nginx config found: $NGINX_CONF"

    # Protocols
    if grep -q "ssl_protocols" "$NGINX_CONF"; then
        _proto="$(grep "ssl_protocols" "$NGINX_CONF" | head -1 | sed 's/.*ssl_protocols/ssl_protocols/' | tr -d ';')"
        info "  $_proto"
        if printf '%s' "$_proto" | grep -qiE 'SSLv3|TLSv1[^.2]|TLSv1\.0|TLSv1\.1'; then
            fail "Insecure protocol in ssl_protocols (SSLv3/TLS 1.0/1.1 must be removed)"
        else
            ok "Protocols: TLS 1.2 / 1.3 only"
        fi
    else
        warn "ssl_protocols not found in Nginx config"
    fi

    # ssl_certificate directive points to expected location
    if grep -q "ssl_certificate " "$NGINX_CONF"; then
        _cert_directive="$(grep "ssl_certificate " "$NGINX_CONF" | grep -v key | head -1 | awk '{print $2}' | tr -d ';')"
        [ "$_cert_directive" = "$NGINX_CERT" ] && \
            ok "ssl_certificate directive: $NGINX_CERT" || \
            warn "ssl_certificate points to: $_cert_directive (expected: $NGINX_CERT)"
    else
        warn "ssl_certificate directive not found in Nginx config"
    fi
fi

# --- 7. Live TLS handshake test -----------------------------------------------
section "Live TLS Test"

_ssl_port=443
if ss -tlnp 2>/dev/null | awk '{print $4}' | grep -q ":${_ssl_port}$"; then
    ok "Port $NGINX_CONF port 443 is listening"

    info "TLS handshake test (openssl s_client) ..."
    _hs_out="$(echo | openssl s_client -connect "localhost:${_ssl_port}" \
        -brief 2>&1)"
    if printf '%s' "$_hs_out" | grep -q "Verify return code: 0"; then
        ok "TLS handshake successful – certificate verified"
    elif printf '%s' "$_hs_out" | grep -q "Verify return code:"; then
        _verify="$(printf '%s' "$_hs_out" | grep "Verify return code:" | head -1)"
        warn "TLS handshake: $_verify"
        info "  Self-signed or untrusted CA: expected for SELF mode"
    else
        fail "TLS handshake failed"
        printf '%s' "$_hs_out" | head -5 | sed 's/^/  /' | tee -a "$LOG_FILE"
    fi

    # Protocol compliance: TLS 1.0 must be rejected
    info "Protocol compliance check ..."
    if echo | openssl s_client -connect "localhost:${_ssl_port}" \
            -tls1 2>&1 | grep -q "no protocols available\|alert\|ssl handshake failure\|handshake failure"; then
        ok "TLS 1.0 rejected (correct)"
    else
        warn "TLS 1.0 may be accepted – check ssl_protocols in Nginx config"
    fi

    # TLS 1.2 must be accepted
    if echo | openssl s_client -connect "localhost:${_ssl_port}" \
            -tls1_2 2>&1 | grep -q "Cipher\|CONNECTED"; then
        ok "TLS 1.2 accepted"
    else
        warn "TLS 1.2 not available – check ssl_protocols"
    fi
else
    info "Port 443 not listening – skipping live TLS tests"
    info "  Start Nginx: systemctl start nginx"
fi

# --- 8. WebLogic Frontend Host ------------------------------------------------
section "WebLogic Frontend Host"

_config_xml="${DOMAIN_HOME:-}/config/config.xml"
if [ -z "${DOMAIN_HOME:-}" ]; then
    info "DOMAIN_HOME not set – skipping Frontend Host check"
elif [ ! -f "$_config_xml" ]; then
    warn "config.xml not found: $_config_xml"
    info "  Domain not yet created or DOMAIN_HOME incorrect"
else
    _frontend_hosts="$(grep -oP '(?<=<frontend-host>)[^<]+' "$_config_xml" 2>/dev/null)"
    if [ -z "$_frontend_hosts" ]; then
        warn "Frontend Host not configured in config.xml"
        info "  WebLogic will generate redirects using localhost – broken through Nginx"
        info "  Fix: set FrontendHost for each server to: ${SSL_CN:-<FQDN>}"
        info "  See: 09-Install/docs/03-root_nginx_ssl.md – WebLogic Frontend Host"
    else
        while IFS= read -r _fh; do
            if [ -n "$SSL_CN" ] && [ "$_fh" = "$SSL_CN" ]; then
                ok "Frontend Host: $_fh"
            elif [ -z "$SSL_CN" ]; then
                ok "Frontend Host: $_fh"
            else
                warn "Frontend Host: $_fh (expected: $SSL_CN)"
            fi
        done <<< "$_frontend_hosts"
    fi
fi

# =============================================================================
print_summary
exit "$EXIT_CODE"
