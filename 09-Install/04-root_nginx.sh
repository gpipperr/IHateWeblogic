#!/bin/bash
# =============================================================================
# Script   : 04-root_nginx.sh
# Purpose  : Phase 0 – Install Nginx and deploy WLS proxy configuration.
#            Uses nginx-wls.conf.template with ##VARIABLE## substitution
#            from environment.conf. Does NOT start Nginx yet – SSL certs
#            must be in place first (05-root_nginx_ssl.sh).
# Call     : ./09-Install/04-root_nginx.sh
#            ./09-Install/04-root_nginx.sh --apply
# Options  : --apply   Install Nginx and write configuration
#            --help    Show usage
# Requires : dnf, nginx
# Runs as  : root or oracle with sudo
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/docs/04-root_nginx.md
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
    printf "  %-16s %s\n" "--apply" "Install Nginx and deploy proxy configuration"
    printf "  %-16s %s\n" "--help"  "Show this help"
    printf "\nNote: Nginx is NOT started after this script.\n"
    printf "      Run 05-root_nginx_ssl.sh to install SSL certs and start Nginx.\n"
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
# Configuration (with defaults)
# =============================================================================

TEMPLATE="$SCRIPT_DIR/nginx-wls.conf.template"
NGINX_CONF_DIR="/etc/nginx/conf.d"
NGINX_CONF="$NGINX_CONF_DIR/oracle-wls.conf"
NGINX_SSL_DIR="/etc/nginx/ssl"

SERVER_NAME="${WLS_SERVER_FQDN:-$(hostname -f 2>/dev/null)}"
WLS_FORMS_PORT="${WLS_FORMS_PORT:-9001}"
WLS_REPORTS_PORT="${WLS_REPORTS_PORT:-9002}"
WLS_ADMIN_PORT="${WLS_ADMIN_PORT:-7001}"
ADMIN_IP_RANGE="${ADMIN_IP_RANGE:-10.0.0.0/8}"

# SSL cert paths (will be created by 05-root_nginx_ssl.sh)
SSL_CERT="${NGINX_SSL_DIR}/fullchain.pem"
SSL_KEY="${NGINX_SSL_DIR}/privkey.pem"

# =============================================================================
# Banner
# =============================================================================

printLine
section "Nginx Installation & Configuration – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-26s %s\n" "Host:"             "$SERVER_NAME"      | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "WLS_FORMS_PORT:"   "$WLS_FORMS_PORT"   | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "WLS_REPORTS_PORT:" "$WLS_REPORTS_PORT" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "WLS_ADMIN_PORT:"   "$WLS_ADMIN_PORT"   | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "ADMIN_IP_RANGE:"   "$ADMIN_IP_RANGE"   | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "Target config:"    "$NGINX_CONF"       | tee -a "${LOG_FILE:-/dev/null}"
[ "$APPLY_MODE" -eq 1 ] && \
    printf "  %-26s %s\n" "Mode:" "APPLY (will install and configure)" \
        | tee -a "${LOG_FILE:-/dev/null}"
printLine

_check_root_access

# =============================================================================
# 1. Template
# =============================================================================

section "Configuration Template"

if [ ! -f "$TEMPLATE" ]; then
    fail "Template not found: $TEMPLATE"
    info "  Expected: $SCRIPT_DIR/nginx-wls.conf.template"
    print_summary; exit 2
fi
ok "Template found: $TEMPLATE"

# Show which variables will be substituted
printf "\n  Substitutions:\n" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-28s → %s\n" "##SERVER_NAME##"        "$SERVER_NAME"      | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-28s → %s\n" "##WLS_FORMS_PORT##"     "$WLS_FORMS_PORT"   | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-28s → %s\n" "##WLS_REPORTS_PORT##"   "$WLS_REPORTS_PORT" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-28s → %s\n" "##WLS_ADMIN_PORT##"     "$WLS_ADMIN_PORT"   | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-28s → %s\n" "##SSL_CERT##"           "$SSL_CERT"         | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-28s → %s\n" "##SSL_KEY##"            "$SSL_KEY"          | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-28s → %s\n" "##ADMIN_IP_RANGE##"     "$ADMIN_IP_RANGE"   | tee -a "${LOG_FILE:-/dev/null}"

# Check for unset ##PARA## (SERVER_NAME must be a valid FQDN)
if ! printf "%s" "$SERVER_NAME" | grep -qE '\.' ; then
    warn "SERVER_NAME '$SERVER_NAME' is not an FQDN (no dot) – Nginx config may not match requests"
    info "  Set WLS_SERVER_FQDN=hostname.domain.local in environment.conf"
fi

# =============================================================================
# 2. Nginx Installation
# =============================================================================

section "Nginx Installation"

if command -v nginx > /dev/null 2>&1; then
    NGINX_VERSION="$(nginx -v 2>&1 | head -1)"
    ok "Nginx installed: $NGINX_VERSION"
else
    fail "Nginx not installed"
    if [ "$APPLY_MODE" -eq 1 ]; then
        if askYesNo "Install nginx via dnf?" "y"; then
            _run_root dnf install -y nginx
            if command -v nginx > /dev/null 2>&1; then
                ok "Nginx installed: $(nginx -v 2>&1 | head -1)"
            else
                fail "Nginx installation failed"
                print_summary; exit 2
            fi
        else
            fail "Nginx is required – aborting"
            print_summary; exit 2
        fi
    else
        info "Install: dnf install -y nginx"
    fi
fi

# Enable nginx service (autostart), but do NOT start yet (SSL certs not in place)
if systemctl is-enabled nginx > /dev/null 2>&1; then
    ok "Nginx service enabled (autostart)"
else
    warn "Nginx service not enabled for autostart"
    if [ "$APPLY_MODE" -eq 1 ]; then
        _run_root systemctl enable nginx && ok "Nginx service enabled"
    else
        info "Enable: systemctl enable nginx"
    fi
fi

# =============================================================================
# 3. SSL directory
# =============================================================================

section "SSL Directory"

if [ -d "$NGINX_SSL_DIR" ]; then
    ok "SSL directory exists: $NGINX_SSL_DIR"
else
    warn "SSL directory missing: $NGINX_SSL_DIR"
    if [ "$APPLY_MODE" -eq 1 ]; then
        _run_root mkdir -p "$NGINX_SSL_DIR"
        _run_root chmod 700 "$NGINX_SSL_DIR"
        ok "SSL directory created: $NGINX_SSL_DIR"
    else
        info "Will be created: $NGINX_SSL_DIR"
    fi
fi

# Warn if cert files don't exist yet (expected – 05-root_nginx_ssl.sh places them).
# /etc/nginx/ssl is root-only (700) - test as root, else "as oracle with sudo"
# always reported "not in place" and skipped nginx -t (2026-10-23)
_certs_ok() { _run_root test -f "$SSL_CERT" 2>/dev/null && _run_root test -f "$SSL_KEY" 2>/dev/null; }
if _certs_ok; then
    ok "SSL certificate found: $SSL_CERT"
    ok "SSL key found: $SSL_KEY"
else
    info "SSL certificate not yet in place (will be deployed by 05-root_nginx_ssl.sh)"
    info "  Expected cert: $SSL_CERT"
    info "  Expected key:  $SSL_KEY"
fi

# =============================================================================
# 4. Generate and deploy configuration
# =============================================================================

section "Nginx Configuration"

# Check if conf already exists and matches
if [ -f "$NGINX_CONF" ]; then
    ok "Existing config found: $NGINX_CONF"
    # Show key settings from current config
    grep -E "server_name|upstream|proxy_pass|ssl_certificate" "$NGINX_CONF" 2>/dev/null \
        | head -10 | while IFS= read -r line; do info "  $line"; done
fi

# Generate the config from template (to a temp file for review)
NGINX_CONF_TMP="$(mktemp /tmp/nginx-wls-XXXXXX.conf)"

sed \
    -e "s|##SERVER_NAME##|${SERVER_NAME}|g" \
    -e "s|##WLS_FORMS_PORT##|${WLS_FORMS_PORT}|g" \
    -e "s|##WLS_REPORTS_PORT##|${WLS_REPORTS_PORT}|g" \
    -e "s|##WLS_ADMIN_PORT##|${WLS_ADMIN_PORT}|g" \
    -e "s|##SSL_CERT##|${SSL_CERT}|g" \
    -e "s|##SSL_KEY##|${SSL_KEY}|g" \
    -e "s|##ADMIN_IP_RANGE##|${ADMIN_IP_RANGE}|g" \
    "$TEMPLATE" > "$NGINX_CONF_TMP"

# Optional Forms client bundle location (docs/40-forms_client_distribution.md):
# keep the marked block only for Forms installs with FORMS_CLIENT_DIST=true
_fc_dist=false
if [ "${FORMS_CLIENT_DIST:-false}" = "true" ] && [ "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" != "REPORTS_ONLY" ]; then
    _fc_dist=true
fi
if $_fc_dist; then
    _fc_path="${FORMS_CLIENT_URL_PATH:-/formsWeb}"; _fc_path="${_fc_path%/}"
    _fc_dir="${FORMS_CLIENT_DIR:-/srv/formsWeb}";   _fc_dir="${_fc_dir%/}"
    sed -i -e '/#@FORMS_CLIENT_\(BEGIN\|END\)@/d' \
           -e "s|##FORMS_CLIENT_URL_PATH##|${_fc_path}|g" \
           -e "s|##FORMS_CLIENT_DIR##|${_fc_dir}|g" "$NGINX_CONF_TMP"
    ok "Forms client bundle: location ${_fc_path}/ -> ${_fc_dir}/"
    [ -d "$_fc_dir" ] || warn "FORMS_CLIENT_DIR $_fc_dir does not exist yet (03-root_user_oracle.sh --apply)"
    unset _fc_path _fc_dir
else
    sed -i '/#@FORMS_CLIENT_BEGIN@/,/#@FORMS_CLIENT_END@/d' "$NGINX_CONF_TMP"
    info "Forms client bundle location not configured (FORMS_CLIENT_DIST != true)"
fi
unset _fc_dist

# Check no ##PARA## placeholders remain
# (comment lines are ignored – the template header documents the ##PARA## syntax)
REMAINING="$(grep -v '^[[:space:]]*#' "$NGINX_CONF_TMP" 2>/dev/null | grep -c '##[A-Z_]*##')"
if [ "$REMAINING" -gt 0 ]; then
    warn "Unreplaced placeholders in generated config:"
    grep -v '^[[:space:]]*#' "$NGINX_CONF_TMP" | grep -o '##[A-Z_]*##' | sort -u | while IFS= read -r p; do
        warn "  $p"
    done
else
    ok "All ##PARA## placeholders substituted"
fi

printf "\n  Generated config preview (first 30 lines):\n" | tee -a "${LOG_FILE:-/dev/null}"
head -30 "$NGINX_CONF_TMP" | while IFS= read -r line; do
    printf "  %s\n" "$line" | tee -a "${LOG_FILE:-/dev/null}"
done

if [ "$APPLY_MODE" -eq 1 ]; then
    if askYesNo "Deploy generated config to $NGINX_CONF?" "y"; then
        # Backup existing config (root-owned directory -> as root)
        _bak=""
        if [ -f "$NGINX_CONF" ]; then
            _bak="${NGINX_CONF}.bak_$(date +%Y%m%d_%H%M%S)"
            _run_root cp -p "$NGINX_CONF" "$_bak" && ok "Backup created: $_bak" \
                || { fail "Backup of $NGINX_CONF failed – nothing deployed"; _bak="FAILED"; }
        fi

        if [ "$_bak" != "FAILED" ]; then
        # include directory of further applications (12-APEX-Ords/05-setup-nginx.sh)
        _run_root mkdir -p /etc/nginx/oracle-wls.d && _run_root chmod 755 /etc/nginx/oracle-wls.d
        _run_root cp "$NGINX_CONF_TMP" "$NGINX_CONF"
        _run_root chmod 644 "$NGINX_CONF"
        ok "Configuration deployed: $NGINX_CONF"

        # Validate syntax (nginx -t fails if the SSL certs don't exist yet),
        # reload a running Nginx; a broken config is rolled back at once
        if _certs_ok; then
            if _run_root nginx -t 2>/dev/null; then
                ok "Nginx config syntax valid (nginx -t)"
                if _run_root systemctl is-active --quiet nginx; then
                    _run_root systemctl reload nginx && ok "Nginx reloaded – new configuration active" \
                        || fail "systemctl reload nginx failed"
                else
                    info "Nginx not running – start it: sudo systemctl start nginx"
                fi
            else
                fail "Nginx config syntax error – run: sudo nginx -t"
                if [ -n "$_bak" ]; then
                    _run_root cp -p "$_bak" "$NGINX_CONF" && warn "Previous configuration restored from $_bak (Nginx unchanged)"
                fi
            fi
        else
            info "Skipping nginx -t (SSL certs not yet in place)"
            info "  Full validation after 05-root_nginx_ssl.sh deploys the certificates"
        fi
        fi
        unset _bak
    fi
else
    info "Run with --apply to deploy this configuration"
    info "  Config will be written to: $NGINX_CONF"
fi

rm -f "$NGINX_CONF_TMP"

# =============================================================================
# 5. Default nginx.conf check
# =============================================================================

section "Default Nginx Config"

NGINX_DEFAULT="/etc/nginx/nginx.conf"
if [ -f "$NGINX_DEFAULT" ]; then
    # Check it includes conf.d (standard OL9 nginx package does this)
    if grep -q "conf\.d" "$NGINX_DEFAULT" 2>/dev/null; then
        ok "nginx.conf includes conf.d/ directory"
    else
        warn "nginx.conf does not include conf.d/ – oracle-wls.conf will not be loaded"
        info "  Add to nginx.conf http{} block:"
        info '  include /etc/nginx/conf.d/*.conf;'
    fi

    # Check for conflicting default server block (OL9 nginx ships a default server)
    if [ -f "/etc/nginx/conf.d/default.conf" ]; then
        warn "Default server config exists: /etc/nginx/conf.d/default.conf"
        info "  This may conflict with oracle-wls.conf on port 80"
        if [ "$APPLY_MODE" -eq 1 ]; then
            if askYesNo "Rename default.conf to default.conf.disabled?" "y"; then
                _run_root mv /etc/nginx/conf.d/default.conf \
                             /etc/nginx/conf.d/default.conf.disabled
                ok "default.conf disabled"
            fi
        fi
    else
        ok "No conflicting default.conf found"
    fi
fi

# =============================================================================
# Summary
# =============================================================================

printLine
if [ "$CNT_FAIL" -eq 0 ]; then
    info "Nginx configuration ready."
    info "Next step: ./09-Install/05-root_nginx_ssl.sh --apply"
    info "  → copies SSL certificate, validates config, starts Nginx"
else
    info "Fix reported issues and re-run with --apply"
fi

print_summary
exit "$EXIT_CODE"
