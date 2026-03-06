#!/bin/bash
# =============================================================================
# Script   : ssl_check.sh
# Purpose  : SSL/TLS inventory for Oracle Forms/Reports 14c environments.
#            Detects SSL architecture (Nginx proxy vs. WLS direct), analyses
#            TLS protocol + cipher strength, and checks certificate expiry.
# Call     : ./ssl_check.sh
#            ./ssl_check.sh --warn-days 60
#            ./ssl_check.sh --host 10.0.1.5
#            ./ssl_check.sh --no-curl
# Requires : openssl, ss (or netstat), optionally curl, keytool
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"

LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m Cannot find IHateWeblogic_lib.sh: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=00-Setup/IHateWeblogic_lib.sh
source "$LIB"

check_env_conf "$ENV_CONF" || exit 2
source "$ENV_CONF"
init_log

# =============================================================================
# Arguments
# =============================================================================
WARN_DAYS=30
CHECK_HOST=""        # override host for TLS checks (default: localhost)
NO_CURL=false

while [ $# -gt 0 ]; do
    case "$1" in
        --warn-days)  WARN_DAYS="$2"; shift 2 ;;
        --warn-days=*)WARN_DAYS="${1#--warn-days=}"; shift ;;
        --host)       CHECK_HOST="$2"; shift 2 ;;
        --host=*)     CHECK_HOST="${1#--host=}"; shift ;;
        --no-curl)    NO_CURL=true; shift ;;
        --help|-h)
            printf "Usage: %s [--warn-days N] [--host HOST] [--no-curl]\n" "$(basename "$0")"
            exit 0
            ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
done

# Resolve check host: CLI > WL_ADMIN_URL host > localhost
if [ -z "$CHECK_HOST" ]; then
    CHECK_HOST="$(printf "%s" "${WL_ADMIN_URL:-t3://localhost:7001}" \
        | sed 's|.*://||; s|:.*||')"
    [ -z "$CHECK_HOST" ] && CHECK_HOST="localhost"
fi

# =============================================================================
# Helpers: openssl wrappers
# =============================================================================

# _tls_connect  host  port  [extra_flags]
# Run openssl s_client, return full output. Timeout 5s.
_tls_connect() {
    local host="$1" port="$2"
    shift 2
    timeout 5 openssl s_client \
        -connect "${host}:${port}" \
        -servername "$host" \
        "$@" \
        </dev/null 2>&1
}

# _cert_enddate_epoch  pem_text_or_file
# Returns epoch seconds of certificate Not After date.
# Pass "-" as second arg to read from file path given in first arg.
_cert_enddate_epoch() {
    local input="$1" mode="${2:-text}"
    local enddate_str
    if [ "$mode" = "file" ]; then
        enddate_str="$(openssl x509 -noout -enddate -in "$input" 2>/dev/null \
            | cut -d= -f2)"
    else
        enddate_str="$(printf "%s" "$input" \
            | openssl x509 -noout -enddate 2>/dev/null \
            | cut -d= -f2)"
    fi
    [ -z "$enddate_str" ] && { printf "0"; return; }
    date -d "$enddate_str" +%s 2>/dev/null || printf "0"
}

# _cert_subject  pem_text
_cert_subject() {
    printf "%s" "$1" | openssl x509 -noout -subject 2>/dev/null \
        | sed 's/subject=//' | sed 's/^[[:space:]]*//'
}

# _cert_issuer  pem_text
_cert_issuer() {
    printf "%s" "$1" | openssl x509 -noout -issuer 2>/dev/null \
        | sed 's/issuer=//' | sed 's/^[[:space:]]*//'
}

# _cert_sans  pem_text
_cert_sans() {
    printf "%s" "$1" | openssl x509 -noout -ext subjectAltName 2>/dev/null \
        | grep -v "^X509" | tr ',' '\n' | sed 's/[[:space:]]*DNS://g; s/[[:space:]]//g' \
        | grep -v '^$' | head -8
}

# _is_self_signed  pem_text
# Returns 0 if self-signed (subject == issuer)
_is_self_signed() {
    local subj iss
    subj="$(printf "%s" "$1" | openssl x509 -noout -subject 2>/dev/null)"
    iss="$( printf "%s" "$1" | openssl x509 -noout -issuer  2>/dev/null)"
    [ "$subj" = "$iss" ]
}

# _check_cert  pem_text  source_label
# Evaluate certificate and emit ok/warn/fail lines.
_check_cert() {
    local pem="$1" label="$2"
    local now epoch_end days_left subj iss

    now="$(date +%s)"
    epoch_end="$(_cert_enddate_epoch "$pem")"

    if [ "$epoch_end" -eq 0 ]; then
        warn "$(printf "  %-26s  Zertifikat nicht lesbar" "$label")"
        return
    fi

    days_left=$(( (epoch_end - now) / 86400 ))
    enddate_human="$(date -d "@${epoch_end}" '+%Y-%m-%d' 2>/dev/null)"
    subj="$(_cert_subject "$pem")"
    iss="$( _cert_issuer  "$pem")"

    printList "  Subject"    28 "$subj"
    printList "  Issuer"     28 "$iss"
    printList "  Gültig bis" 28 "${enddate_human} (${days_left} Tage)"

    # SAN entries
    local sans
    sans="$(_cert_sans "$pem")"
    if [ -n "$sans" ]; then
        local first=true
        while IFS= read -r san; do
            [ -z "$san" ] && continue
            if $first; then
                printList "  SANs" 28 "$san"
                first=false
            else
                printList "  " 28 "$san"
            fi
        done <<< "$sans"
    fi

    # Self-signed check
    if _is_self_signed "$pem"; then
        warn "$(printf "  %-26s  Subject == Issuer → selbst-signiert" "Signatur:")"
    else
        ok "$(printf "  %-26s  CA-signiert" "Signatur:")"
    fi

    # Expiry check
    if [ "$days_left" -lt 0 ]; then
        fail "$(printf "  %-26s  ABGELAUFEN seit %d Tagen!" "Ablauf:" "$(( -days_left ))")"
    elif [ "$days_left" -lt "$WARN_DAYS" ]; then
        warn "$(printf "  %-26s  läuft in %d Tagen ab (Schwelle: %d)" "Ablauf:" "$days_left" "$WARN_DAYS")"
    else
        ok "$(printf "  %-26s  gültig noch %d Tage (bis %s)" "Ablauf:" "$days_left" "$enddate_human")"
    fi
}

# _check_tls_on_port  host  port  label
# Full TLS analysis: protocol, cipher, FS, weak-protocol test, cert.
_check_tls_on_port() {
    local host="$1" port="$2" label="$3"

    printf "\n"
    printf "  \033[1m── %s  (%s:%s) ──\033[0m\n" "$label" "$host" "$port"

    # Main connect
    local tls_out
    tls_out="$(_tls_connect "$host" "$port")"
    if printf "%s" "$tls_out" | grep -q "Connection refused\|connect:errno\|getaddrinfo\|TNS_ERROR"; then
        warn "$(printf "  %-26s  Verbindung fehlgeschlagen (%s:%s)" "TLS-Connect:" "$host" "$port")"
        return
    fi
    if ! printf "%s" "$tls_out" | grep -q "BEGIN CERTIFICATE\|Protocol\|Cipher"; then
        warn "$(printf "  %-26s  Keine TLS-Antwort von %s:%s" "TLS-Connect:" "$host" "$port")"
        return
    fi

    # Protocol
    local proto
    proto="$(printf "%s" "$tls_out" | grep -E '^\s*Protocol\s*:' | awk '{print $NF}' | head -1)"
    [ -z "$proto" ] && proto="$(printf "%s" "$tls_out" \
        | grep -oE 'TLSv[0-9.]+|SSLv[0-9.]+' | tail -1)"

    case "$proto" in
        TLSv1.3) ok   "$(printf "  %-26s  %s" "Protokoll:" "$proto")" ;;
        TLSv1.2) ok   "$(printf "  %-26s  %s" "Protokoll:" "$proto")" ;;
        TLSv1.1) warn "$(printf "  %-26s  %s – veraltet (RFC 8996)" "Protokoll:" "$proto")" ;;
        TLSv1.0) fail "$(printf "  %-26s  %s – unsicher (POODLE/BEAST)" "Protokoll:" "$proto")" ;;
        SSLv*)   fail "$(printf "  %-26s  %s – kritisch unsicher" "Protokoll:" "$proto")" ;;
        *)       info "$(printf "  %-26s  %s (unbekannt)" "Protokoll:" "${proto:-(nicht erkannt)}")" ;;
    esac

    # Cipher
    local cipher
    cipher="$(printf "%s" "$tls_out" | grep -E '^\s*Cipher\s*:' | awk '{print $NF}' | head -1)"
    if [ -n "$cipher" ]; then
        local cipher_ok=true
        case "$cipher" in
            *RC4*|*DES*|*NULL*|*EXPORT*|*anon*|*ADH*|*AECDH*)
                fail "$(printf "  %-26s  %s – unsicherer Cipher" "Cipher:" "$cipher")"
                cipher_ok=false ;;
            *MD5*)
                warn "$(printf "  %-26s  %s – MD5 veraltet" "Cipher:" "$cipher")" ;;
            *)
                ok "$(printf "  %-26s  %s" "Cipher:" "$cipher")" ;;
        esac

        # Forward Secrecy
        if printf "%s" "$cipher" | grep -qE 'DHE|ECDHE'; then
            ok "$(printf "  %-26s  ja (DHE/ECDHE erkannt)" "Forward Secrecy:")"
        else
            warn "$(printf "  %-26s  nein – kein DHE/ECDHE im Cipher" "Forward Secrecy:")"
        fi
    fi

    # Weak protocol explicit test (TLS 1.0 / 1.1 still accepted?)
    if [[ "$proto" == TLSv1.2 || "$proto" == TLSv1.3 ]]; then
        local weak_out
        weak_out="$(timeout 4 openssl s_client -tls1 \
            -connect "${host}:${port}" -servername "$host" </dev/null 2>&1)"
        if printf "%s" "$weak_out" | grep -q "BEGIN CERTIFICATE"; then
            warn "$(printf "  %-26s  TLS 1.0 wird noch akzeptiert!" "Schwache Protokolle:")"
        else
            weak_out="$(timeout 4 openssl s_client -tls1_1 \
                -connect "${host}:${port}" -servername "$host" </dev/null 2>&1)"
            if printf "%s" "$weak_out" | grep -q "BEGIN CERTIFICATE"; then
                warn "$(printf "  %-26s  TLS 1.1 wird noch akzeptiert" "Schwache Protokolle:")"
            else
                ok "$(printf "  %-26s  TLS 1.0/1.1 abgelehnt" "Schwache Protokolle:")"
            fi
        fi
    fi

    # Certificate
    local cert_pem
    cert_pem="$(printf "%s" "$tls_out" \
        | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
        | head -30)"    # first cert in chain only
    if [ -n "$cert_pem" ]; then
        printf "\n"
        info "  Zertifikat:"
        _check_cert "$cert_pem" "Live-Zertifikat"
    fi
}

# _owner_of_port  port
# Returns process name owning the port from ss output.
_owner_of_port() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnp 2>/dev/null | awk -v p=":${port}" '$0 ~ p {print $NF}' \
            | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 \
            | xargs -I{} cat /proc/{}/comm 2>/dev/null \
            | head -1
    fi
}

_port_listener() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnp 2>/dev/null | awk -v p=":${port} " '$0 ~ p || $0 ~ ":"p{print $0}' \
            | head -1
    fi
}

# =============================================================================
# Banner
# =============================================================================
printLine
printf "\n\033[1mIHateWeblogic – SSL/TLS Check\033[0m\n"
printf "Host    : %s\n" "$(_get_hostname)"
printf "Date    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "Log     : %s\n"  "$LOG_FILE"
printf "Ablauf-Warnung: %d Tage\n\n" "$WARN_DAYS"

# =============================================================================
# Section 1: Tool-Verfügbarkeit
# =============================================================================
section "Voraussetzungen"

HAS_OPENSSL=false
HAS_CURL=false
HAS_KEYTOOL=false

if command -v openssl >/dev/null 2>&1; then
    _ossl_ver="$(openssl version 2>/dev/null)"
    ok "openssl verfügbar: $_ossl_ver"
    HAS_OPENSSL=true
else
    fail "openssl nicht gefunden – TLS-Analyse nicht möglich"
fi

if command -v curl >/dev/null 2>&1; then
    ok "curl verfügbar: $(curl --version 2>/dev/null | head -1)"
    HAS_CURL=true
else
    info "curl nicht gefunden – HTTP-Endpoint-Checks werden übersprungen"
fi

if command -v keytool >/dev/null 2>&1; then
    ok "keytool verfügbar (JKS-Keystore-Inspektion möglich)"
    HAS_KEYTOOL=true
else
    info "keytool nicht im PATH (JAVA_HOME/bin/keytool wird versucht)"
    if [ -x "${JAVA_HOME:-}/bin/keytool" ]; then
        HAS_KEYTOOL=true
        ok "keytool über JAVA_HOME verfügbar: $JAVA_HOME/bin/keytool"
    fi
fi
KEYTOOL="${JAVA_HOME:-}/bin/keytool"
command -v keytool >/dev/null 2>&1 && KEYTOOL="keytool"

# =============================================================================
# Section 2: Architektur-Erkennung – wer hört auf welchem Port?
# =============================================================================
section "SSL-Architektur – Port-Belegung"

# Collect all listening ports from ss once
SS_OUT=""
if command -v ss >/dev/null 2>&1; then
    SS_OUT="$(ss -tlnp 2>/dev/null)"
elif command -v netstat >/dev/null 2>&1; then
    SS_OUT="$(netstat -tlnp 2>/dev/null)"
fi

# Determine owner of port 443
PORT_443_LINE="$(printf "%s" "$SS_OUT" | awk '$0 ~ /:443[ \t]/ || $0 ~ /:443$/'| head -1)"
PORT_443_PROC=""
if [ -n "$PORT_443_LINE" ]; then
    _pid="$(printf "%s" "$PORT_443_LINE" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | head -1)"
    [ -n "$_pid" ] && PORT_443_PROC="$(cat /proc/$_pid/comm 2>/dev/null)"
fi

# Detect nginx
NGINX_RUNNING=false
NGINX_CONF_DIRS=("/etc/nginx" "/usr/local/nginx/conf" "/opt/nginx/conf")
NGINX_MAIN_CONF=""
if pgrep -x nginx >/dev/null 2>&1 || pgrep -f "nginx: master" >/dev/null 2>&1; then
    NGINX_RUNNING=true
fi
for _d in "${NGINX_CONF_DIRS[@]}"; do
    [ -f "$_d/nginx.conf" ] && { NGINX_MAIN_CONF="$_d/nginx.conf"; break; }
done

# Architecture determination
ARCH_MODE="unknown"
if [ -n "$PORT_443_PROC" ]; then
    case "$PORT_443_PROC" in
        nginx)  ARCH_MODE="nginx" ;;
        java)   ARCH_MODE="wls_direct" ;;
        httpd)  ARCH_MODE="ohs" ;;
        *)      ARCH_MODE="other:$PORT_443_PROC" ;;
    esac
elif $NGINX_RUNNING; then
    ARCH_MODE="nginx"
fi

# Display architecture
printf "\n"
case "$ARCH_MODE" in
    nginx)
        ok "  SSL-Architektur: Nginx SSL-Proxy erkannt"
        info "  Muster: Internet → nginx:443 (TLS) → WLS intern (HTTP)"
        info "  TLS-Zertifikat liegt bei nginx, nicht im WLS-Keystore"
        ;;
    wls_direct)
        ok "  SSL-Architektur: WLS direkt (Java auf Port 443)"
        info "  TLS-Zertifikat im WLS-Keystore konfiguriert"
        ;;
    ohs)
        ok "  SSL-Architektur: Oracle HTTP Server (OHS) Proxy erkannt"
        info "  Muster: Internet → OHS:443 (TLS) → WLS intern (HTTP)"
        ;;
    other:*)
        warn "$(printf "  SSL-Architektur: Unbekannter Prozess auf Port 443: %s" "${ARCH_MODE#other:}")"
        ;;
    *)
        if [ -n "$PORT_443_LINE" ]; then
            info "  Port 443 belegt, Prozess-Name nicht ermittelbar (ggf. sudo nötig)"
        else
            info "  Kein Prozess auf Port 443 gefunden"
            info "  WLS SSL-Ports werden direkt geprüft"
        fi
        ;;
esac

# Show all listening ports with SSL-Port-Candidates
printf "\n"
info "  Lauschende TCP-Ports (alle):"
if [ -n "$SS_OUT" ]; then
    printf "%s" "$SS_OUT" | grep LISTEN | while IFS= read -r _line; do
        _addr="$(printf "%s" "$_line" | awk '{print $4}')"
        _proc="$(printf "%s" "$_line" | grep -oE '"[^"]*"' | head -1)"
        printf "    %-28s %s\n" "$_addr" "${_proc:-}" | tee -a "${LOG_FILE:-/dev/null}"
    done
fi

# =============================================================================
# Section 3: WLS config.xml – SSL-Konfiguration
# =============================================================================
section "WebLogic SSL-Konfiguration (config.xml)"

CONFIG_XML="${DOMAIN_HOME}/config/config.xml"
SSL_PORTS=()    # collect for later TLS analysis

if [ ! -f "$CONFIG_XML" ]; then
    warn "config.xml nicht gefunden: $CONFIG_XML"
    info "  Prüfen Sie DOMAIN_HOME in environment.conf"
else
    ok "config.xml gefunden: $CONFIG_XML"
    printf "\n"

    # Parse <server> blocks
    in_block=0
    current_block=""

    while IFS= read -r line; do
        if [[ "$line" == *"<server>"* ]] || [[ "$line" == *"<server "* ]]; then
            in_block=1
            current_block="${line}"$'\n'
        elif [ "$in_block" -eq 1 ]; then
            current_block+="${line}"$'\n'
            if [[ "$line" == *"</server>"* ]]; then
                # Extract fields from block
                _srv_name="$(printf "%s" "$current_block" \
                    | grep -oP '(?<=<name>)[^<]+' | head -1)"
                _listen_port="$(printf "%s" "$current_block" \
                    | grep -oP '(?<=<listen-port>)[^<]+' | head -1)"
                _ssl_port="$(printf "%s" "$current_block" \
                    | grep -oP '(?<=<ssl-listen-port>)[^<]+' \
                    | head -1)"
                # ssl block
                _ssl_block="$(printf "%s" "$current_block" \
                    | sed -n '/<ssl>/,/<\/ssl>/p')"
                _ssl_enabled="$(printf "%s" "$_ssl_block" \
                    | grep -oP '(?<=<enabled>)[^<]+' | head -1)"
                [ -z "$_ssl_port" ] && _ssl_port="$(printf "%s" "$_ssl_block" \
                    | grep -oP '(?<=<listen-port>)[^<]+' | head -1)"

                # Keystore info
                _keystores="$(printf "%s" "$current_block" \
                    | grep -oP '(?<=<key-stores>)[^<]+' | head -1)"
                _server_cert="$(printf "%s" "$current_block" \
                    | grep -oP '(?<=<certificate-file>)[^<]+' | head -1)"

                # Defaults
                [ -z "$_listen_port" ] && _listen_port="7001"
                [ -z "$_ssl_enabled" ] && _ssl_enabled="false"

                # Live port status
                _nossl_live="$(printf "%s" "$SS_OUT" \
                    | grep -cE ":${_listen_port}[ \t]|:${_listen_port}$" 2>/dev/null)"
                _ssl_live=""
                [ -n "$_ssl_port" ] && _ssl_live="$(printf "%s" "$SS_OUT" \
                    | grep -cE ":${_ssl_port}[ \t]|:${_ssl_port}$" 2>/dev/null)"

                printf "  \033[1m── %s ──\033[0m\n" "${_srv_name:-Unbekannt}"

                # NoSSL port
                _nossl_status="LISTEN"
                [ "${_nossl_live:-0}" -eq 0 ] && _nossl_status="DOWN"
                if [ "$_nossl_status" = "LISTEN" ]; then
                    info "$(printf "  %-24s  :%s  %s" "NoSSL (HTTP):" "$_listen_port" "$_nossl_status")"
                else
                    warn "$(printf "  %-24s  :%s  %s (Server nicht gestartet?)" "NoSSL (HTTP):" "$_listen_port" "$_nossl_status")"
                fi

                # SSL port
                if [ "$_ssl_enabled" = "true" ]; then
                    _ssl_status="LISTEN"
                    [ "${_ssl_live:-0}" -eq 0 ] && _ssl_status="DOWN"
                    if [ "$_ssl_status" = "LISTEN" ]; then
                        ok "$(printf "  %-24s  :%s  %s  SSL aktiv" "SSL (HTTPS):" "${_ssl_port:-7002}" "$_ssl_status")"
                        SSL_PORTS+=("${_ssl_port:-7002}:WLS-${_srv_name}")
                    else
                        warn "$(printf "  %-24s  :%s  %s  (SSL konfiguriert, aber Port nicht aktiv)" "SSL (HTTPS):" "${_ssl_port:-7002}" "$_ssl_status")"
                    fi
                else
                    _arch_note=""
                    [ "$ARCH_MODE" = "nginx" ] && _arch_note=" – OK (Nginx macht SSL)"
                    [ "$ARCH_MODE" = "ohs" ]   && _arch_note=" – OK (OHS macht SSL)"
                    info "$(printf "  %-24s  SSL deaktiviert%s" "SSL:" "$_arch_note")"
                fi

                # Keystore
                if [ -n "$_keystores" ]; then
                    case "$_keystores" in
                        *DEMO*)
                            fail "$(printf "  %-24s  %s – Demo-Zertifikat! Nicht für Produktion!" "Keystore:" "$_keystores")"
                            ;;
                        *CUSTOM*)
                            ok "$(printf "  %-24s  %s" "Keystore:" "$_keystores")"
                            ;;
                        *)
                            info "$(printf "  %-24s  %s" "Keystore:" "$_keystores")"
                            ;;
                    esac
                fi
                [ -n "$_server_cert" ] && printList "  Zertifikat-Datei" 24 "$_server_cert"

                printf "\n"
                in_block=0
                current_block=""
            fi
        fi
    done < "$CONFIG_XML"
fi

# =============================================================================
# Section 4: Nginx SSL-Konfiguration
# =============================================================================
if [ "$ARCH_MODE" = "nginx" ]; then
    section "Nginx SSL-Konfiguration"

    if [ -n "$NGINX_MAIN_CONF" ]; then
        ok "Nginx-Konfiguration: $NGINX_MAIN_CONF"
    else
        info "Nginx-Konfigurationsdatei nicht gefunden – Standardpfade geprüft"
    fi

    # Try nginx -T for full merged config (may need sudo)
    NGINX_FULL_CONF=""
    if nginx -T 2>/dev/null | grep -q "ssl_certificate"; then
        NGINX_FULL_CONF="$(nginx -T 2>/dev/null)"
        info "Nginx-Konfiguration via 'nginx -T' gelesen (vollständig)"
    else
        # Fallback: search conf files directly
        NGINX_CONF_SEARCH_DIRS=("/etc/nginx" "/usr/local/nginx/conf")
        for _dir in "${NGINX_CONF_SEARCH_DIRS[@]}"; do
            [ -d "$_dir" ] || continue
            NGINX_FULL_CONF+="$(find "$_dir" \
                \( -name "*.conf" -o -name "nginx.conf" \) \
                -readable 2>/dev/null \
                -exec cat {} \; 2>/dev/null)"
        done
        [ -n "$NGINX_FULL_CONF" ] && \
            info "Nginx-Konfigurationsdateien direkt gelesen (nginx -T nicht verfügbar)"
    fi

    if [ -z "$NGINX_FULL_CONF" ]; then
        warn "Nginx-Konfiguration nicht lesbar – ggf. mit sudo ausführen"
    else
        printf "\n"
        # ssl_certificate paths
        NGINX_CERT_FILES=()
        while IFS= read -r _cert_path; do
            [ -z "$_cert_path" ] && continue
            NGINX_CERT_FILES+=("$_cert_path")
        done < <(printf "%s" "$NGINX_FULL_CONF" \
            | grep -E '^\s*ssl_certificate\s' \
            | grep -v 'ssl_certificate_key' \
            | awk '{print $2}' | tr -d ';' | sort -u)

        for _cert_file in "${NGINX_CERT_FILES[@]}"; do
            printf "  \033[1m── Zertifikat-Datei: %s ──\033[0m\n" "$_cert_file"
            if [ -f "$_cert_file" ]; then
                ok "$(printf "  %-26s  vorhanden" "ssl_certificate:")"
                _cert_pem="$(openssl x509 -in "$_cert_file" 2>/dev/null)"
                if [ -n "$_cert_pem" ]; then
                    _check_cert "$_cert_pem" "nginx-Zertifikat"
                fi
            else
                fail "$(printf "  %-26s  Datei nicht gefunden: %s" "ssl_certificate:" "$_cert_file")"
            fi
            printf "\n"
        done

        # ssl_protocols
        _nginx_protocols="$(printf "%s" "$NGINX_FULL_CONF" \
            | grep -E '^\s*ssl_protocols' | head -1 | sed 's/ssl_protocols//; s/;//'  | xargs)"
        if [ -n "$_nginx_protocols" ]; then
            printList "  ssl_protocols" 26 "$_nginx_protocols"
            if printf "%s" "$_nginx_protocols" | grep -qE 'TLSv1\.0|TLSv1\.1|SSLv'; then
                warn "$(printf "  %-26s  Unsichere Protokolle in ssl_protocols aktiviert!" "Protokoll-Bewertung:")"
            else
                ok "$(printf "  %-26s  Nur sichere Protokolle konfiguriert" "Protokoll-Bewertung:")"
            fi
        else
            info "  ssl_protocols nicht explizit gesetzt (Nginx-Default)"
        fi

        # ssl_ciphers
        _nginx_ciphers="$(printf "%s" "$NGINX_FULL_CONF" \
            | grep -E '^\s*ssl_ciphers' | head -1 | sed 's/ssl_ciphers//; s/;//' | tr -d "'" | xargs)"
        if [ -n "$_nginx_ciphers" ]; then
            printList "  ssl_ciphers" 26 "$_nginx_ciphers"
            if printf "%s" "$_nginx_ciphers" | grep -qiE 'RC4|DES|NULL|EXPORT|aNULL|!aNULL'; then
                if printf "%s" "$_nginx_ciphers" | grep -q '!aNULL'; then
                    ok "$(printf "  %-26s  anonyme Ciphers explizit ausgeschlossen" "Cipher-Bewertung:")"
                else
                    warn "$(printf "  %-26s  Schwache Cipher-Patterns erkannt" "Cipher-Bewertung:")"
                fi
            else
                info "$(printf "  %-26s  Cipher-String sieht plausibel aus" "Cipher-Bewertung:")"
            fi
        else
            info "  ssl_ciphers nicht explizit gesetzt (Nginx-Default)"
        fi

        # proxy_pass targets
        printf "\n"
        info "  Nginx proxy_pass Ziele (WLS intern):"
        while IFS= read -r _proxy; do
            [ -z "$_proxy" ] && continue
            _proxy_port="$(printf "%s" "$_proxy" | grep -oE ':[0-9]+' | head -1 | tr -d ':')"
            _proxy_live=0
            [ -n "$_proxy_port" ] && _proxy_live="$(printf "%s" "$SS_OUT" \
                | grep -cE ":${_proxy_port}[ \t]|:${_proxy_port}$" 2>/dev/null)"
            if [ "${_proxy_live:-0}" -gt 0 ]; then
                ok "$(printf "  %-26s  %s  (LISTEN)" "proxy_pass:" "$_proxy")"
            else
                warn "$(printf "  %-26s  %s  (NICHT lauschend!)" "proxy_pass:" "$_proxy")"
            fi
        done < <(printf "%s" "$NGINX_FULL_CONF" \
            | grep -E '^\s*proxy_pass' \
            | awk '{print $2}' | tr -d ';' | sort -u)
    fi

    # Port 443 always to analyse
    SSL_PORTS=("443:Nginx-HTTPS" "${SSL_PORTS[@]}")
fi

# =============================================================================
# Section 5: Live TLS-Analyse (alle SSL-Ports)
# =============================================================================
if ! $HAS_OPENSSL; then
    section "TLS-Analyse – übersprungen (openssl fehlt)"
else
    section "Live TLS-Analyse"

    # If no SSL ports from config, try well-known defaults
    if [ "${#SSL_PORTS[@]}" -eq 0 ]; then
        for _p in 443 7002 9002 9012 4443; do
            _live="$(printf "%s" "$SS_OUT" \
                | grep -cE ":${_p}[ \t]|:${_p}$" 2>/dev/null)"
            [ "${_live:-0}" -gt 0 ] && SSL_PORTS+=("${_p}:Port-${_p}")
        done
    fi

    if [ "${#SSL_PORTS[@]}" -eq 0 ]; then
        info "  Keine SSL-Ports gefunden/aktiv – TLS-Analyse übersprungen"
    else
        for _entry in "${SSL_PORTS[@]}"; do
            _port="${_entry%%:*}"
            _lbl="${_entry#*:}"
            _check_tls_on_port "$CHECK_HOST" "$_port" "$_lbl"
        done
    fi
fi

# =============================================================================
# Section 6: HTTP/HTTPS Endpoint-Check
# =============================================================================
if $NO_CURL || ! $HAS_CURL; then
    $NO_CURL  && section "HTTP/HTTPS Endpoint-Check – übersprungen (--no-curl)"
    ! $HAS_CURL && ! $NO_CURL && \
        section "HTTP/HTTPS Endpoint-Check – übersprungen (curl fehlt)"
else
    section "HTTP/HTTPS Endpoint-Check"

    # Build endpoint list based on architecture
    declare -a ENDPOINTS
    ENDPOINTS=()

    # Derive AdminServer address from WL_ADMIN_URL
    _adm_host="$(printf "%s" "${WL_ADMIN_URL:-t3://localhost:7001}" \
        | sed 's|.*://||; s|:.*||')"
    _adm_port="$(printf "%s" "${WL_ADMIN_URL:-t3://localhost:7001}" \
        | sed 's|.*:||')"

    if [ "$ARCH_MODE" = "nginx" ]; then
        ENDPOINTS+=(
            "https://${CHECK_HOST}/em|200,302,401,403|HTTPS über Nginx"
            "https://${CHECK_HOST}/console|200,302,401,403|WLS Console über Nginx"
            "http://${_adm_host}:${_adm_port}/console|200,302,401|WLS Console intern (HTTP)"
        )
    else
        ENDPOINTS+=(
            "https://${CHECK_HOST}:${_adm_port}/console|200,302,401|WLS Console HTTPS"
            "https://${CHECK_HOST}:${_adm_port}/em|200,302,401,403|Enterprise Manager HTTPS"
            "http://${_adm_host}:${_adm_port}/console|200,302,401|WLS Console HTTP"
        )
    fi

    for _ep_entry in "${ENDPOINTS[@]}"; do
        _url="${_ep_entry%%|*}"
        _rest="${_ep_entry#*|}"
        _ok_codes="${_rest%%|*}"
        _lbl="${_rest#*|}"

        _http_code="$(curl -sk -o /dev/null -w "%{http_code}" \
            --max-time 5 "$_url" 2>/dev/null)"
        _curl_rc=$?

        if [ "$_curl_rc" -ne 0 ]; then
            warn "$(printf "  %-36s  Verbindungsfehler (curl RC=%s)" "$_lbl:" "$_curl_rc")"
        elif printf "%s" "$_ok_codes" | grep -q "$_http_code"; then
            # HTTP 401 on internal HTTP = WARN (no SSL on public-facing endpoint)
            if [[ "$_url" == http://* ]] && printf "%s" "$_url" | grep -qvE 'localhost|127\.0\.0\.1'; then
                warn "$(printf "  %-36s  HTTP %s – unverschlüsselt erreichbar!" "$_lbl:" "$_http_code")"
            else
                ok "$(printf "  %-36s  HTTP %s" "$_lbl:" "$_http_code")"
            fi
        else
            warn "$(printf "  %-36s  HTTP %s (erwartet: %s)" "$_lbl:" "$_http_code" "$_ok_codes")"
        fi
        info "    URL: $_url"
    done
fi

# =============================================================================
# Section 7: WLS Keystore-Dateien (keytool)
# =============================================================================
if $HAS_KEYTOOL; then
    section "WLS Keystore-Dateien (keytool)"

    KEYSTORE_FILES=()
    while IFS= read -r _ks; do
        KEYSTORE_FILES+=("$_ks")
    done < <(find "$DOMAIN_HOME" \
        \( -name "*.jks" -o -name "*.p12" -o -name "*.pfx" -o -name "*.keystore" \) \
        -not -path "*/ConfigBackup/*" \
        2>/dev/null | sort)

    if [ "${#KEYSTORE_FILES[@]}" -eq 0 ]; then
        info "  Keine .jks/.p12/.pfx Keystore-Dateien unter DOMAIN_HOME gefunden"
        info "  (Bei Nginx-Proxy sind Zertifikate in nginx-Verzeichnissen, nicht im Domain)"
    else
        for _ks in "${KEYSTORE_FILES[@]}"; do
            printf "\n"
            printf "  \033[1m── %s ──\033[0m\n" "$(basename "$_ks")"
            printList "  Pfad" 22 "$_ks"
            printList "  Größe" 22 "$(wc -c < "$_ks" 2>/dev/null) Bytes"

            # List aliases (no password = only public view)
            _ks_list="$(timeout 5 "$KEYTOOL" -list -keystore "$_ks" \
                -storepass changeit 2>/dev/null \
                || timeout 5 "$KEYTOOL" -list -keystore "$_ks" \
                   -storepass '' 2>/dev/null)"

            if [ -n "$_ks_list" ]; then
                _alias_count="$(printf "%s" "$_ks_list" \
                    | grep -cE 'PrivateKeyEntry|trustedCertEntry' 2>/dev/null)"
                printList "  Einträge" 22 "$_alias_count"
                if printf "%s" "$_ks_list" | grep -qi "DemoIdentity\|DemoCert\|democert"; then
                    fail "  Demo-Keystore erkannt (DemoIdentity/DemoCert)! Nicht für Produktion!"
                fi
                printf "%s" "$_ks_list" | grep -E 'PrivateKeyEntry|trustedCertEntry' \
                    | while IFS= read -r _alias_line; do
                    info "    $_alias_line"
                done
            else
                info "  Keystore-Passwort nicht bekannt (keytool -list schlägt fehl)"
                info "  Manuell: keytool -list -keystore $_ks"
            fi
        done
    fi
fi

# =============================================================================
# Summary
# =============================================================================
print_summary
exit $EXIT_CODE
