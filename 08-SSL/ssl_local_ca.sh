#!/bin/bash
# =============================================================================
# Script   : ssl_local_ca.sh
# Purpose  : Small own certificate authority with plain openssl:
#              one root CA, signing
#              - the server (TLS) certificate for Nginx and
#              - the code-signing certificate for Forms/WebUtil (jacob.jar).
#            Clients import only the root once (ca.cer) and then trust both.
#
# Call     : ./08-SSL/ssl_local_ca.sh status
#            ./08-SSL/ssl_local_ca.sh init     [--apply]
#            ./08-SSL/ssl_local_ca.sh server   [--apply] [--renew]
#            ./08-SSL/ssl_local_ca.sh codesign [--apply] [--renew]
#
#            Without --apply : show what would be done, no files written
#            --renew         : issue a new leaf certificate although a valid
#                              one exists (old files -> *.bak_<ts>)
#
# Config   : 08-SSL/ssl.conf (SSL_CA_*, SSL_CN/SAN/..., SSL_CODESIGN_*),
#            environment.conf (FORMS_SIGN_KEYSTORE, FORMS_SIGN_ALIAS)
# Secrets  : ssl_ca_sec.conf.des3     SSL_CA_PASS           (root key passphrase)
#            forms_sign_sec.conf.des3 FORMS_SIGN_STOREPASS  (PKCS12 password)
#            created with a random value if missing; never on the command line
# Exit     : status: 0 ok, 1 expires < 30 days / missing, 2 expired / broken
# Doc      : 08-SSL/README.md, section "ssl_local_ca.sh"
# Requires : openssl
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
# Defaults (overridden by ssl.conf / ssl.conf.template)
# =============================================================================
SSL_CN="${WLS_SERVER_FQDN:-$(hostname -f 2>/dev/null || hostname)}"
SSL_SAN="DNS:${SSL_CN}"
SSL_COUNTRY="DE"
SSL_STATE=""
SSL_CITY=""
SSL_ORG="Company"
SSL_ORG_UNIT=""
SSL_KEY_ALGO="RSA"
SSL_KEY_SIZE="4096"
SSL_EC_CURVE="secp384r1"
SSL_DAYS="825"
SSL_CERT_FILE="$SCRIPT_DIR/certs/server.crt"
SSL_KEY_FILE="$SCRIPT_DIR/certs/server.key"
SSL_CHAIN_FILE="$SCRIPT_DIR/certs/chain.crt"

SSL_CONF="$SCRIPT_DIR/ssl.conf"
if [ -f "$SSL_CONF" ]; then
    # shellcheck source=ssl.conf
    source "$SSL_CONF"
elif [ -f "$SCRIPT_DIR/ssl.conf.template" ]; then
    source "$SCRIPT_DIR/ssl.conf.template"
    SSL_CN="${WLS_SERVER_FQDN:-$SSL_CN}"
    SSL_SAN="DNS:${SSL_CN}"
fi

SSL_CA_DIR="${SSL_CA_DIR:-${ORACLE_BASE:-/u01/app/oracle}/admin/pki}"
SSL_CA_CN="${SSL_CA_CN:-${SSL_ORG} Root CA}"
SSL_CA_DAYS="${SSL_CA_DAYS:-3650}"
SSL_CA_KEY_SIZE="${SSL_CA_KEY_SIZE:-4096}"
SSL_CODESIGN_CN="${SSL_CODESIGN_CN:-${SSL_ORG} Forms Code Signing}"
SSL_CODESIGN_DAYS="${SSL_CODESIGN_DAYS:-1095}"
FORMS_SIGN_KEYSTORE="${FORMS_SIGN_KEYSTORE:-$SSL_CA_DIR/codesign/codesign.p12}"
FORMS_SIGN_ALIAS="${FORMS_SIGN_ALIAS:-forms_codesign}"

# Relative paths in ssl.conf.template are project-root relative
for _v in SSL_CERT_FILE SSL_KEY_FILE SSL_CHAIN_FILE; do
    [ -n "${!_v:-}" ] && [[ "${!_v}" != /* ]] && printf -v "$_v" '%s' "$ROOT_DIR/${!_v}"
done
unset _v

CA_KEY="$SSL_CA_DIR/ca/ca.key"
CA_CRT="$SSL_CA_DIR/ca/ca.crt"
CA_CER="$SSL_CA_DIR/ca/ca.cer"
CA_SRL="$SSL_CA_DIR/ca/ca.srl"
SRV_DIR="$SSL_CA_DIR/server"
CS_DIR="$SSL_CA_DIR/codesign"
CS_CRT="$CS_DIR/codesign.crt"

CA_SEC_FILE="$ROOT_DIR/ssl_ca_sec.conf.des3"
SIGN_SEC_FILE="$ROOT_DIR/forms_sign_sec.conf.des3"

# =============================================================================
# Arguments
# =============================================================================
CMD=""
APPLY=false
RENEW=false

_usage() {
    printf "Usage: %s status|init|server|codesign [--apply] [--renew]\n\n" "$(basename "$0")"
    printf "  %-10s %s\n" "status"   "Show root / server / code-signing certificates (read-only)"
    printf "  %-10s %s\n" "init"     "Create the root CA (once)"
    printf "  %-10s %s\n" "server"   "Issue the TLS certificate for SSL_CN / SSL_SAN"
    printf "  %-10s %s\n" "codesign" "Issue the code-signing certificate -> PKCS12 keystore"
    printf "\n  %-10s %s\n" "--apply" "Write files (default: dry-run)"
    printf "  %-10s %s\n"   "--renew" "Re-issue a leaf certificate although a valid one exists"
    printf "\nParameters: 08-SSL/ssl.conf, environment.conf (FORMS_SIGN_*)\n"
    printf "Doc       : 08-SSL/README.md, section \"ssl_local_ca.sh\"\n"
    exit 0
}

for _arg in "$@"; do
    case "${_arg,,}" in
        status|init|server|codesign) CMD="${_arg,,}" ;;
        --apply)  APPLY=true ;;
        --renew)  RENEW=true ;;
        --help|-h) _usage ;;
        *) printf "\033[31mERROR\033[0m: Unknown argument: %s\n" "$_arg" >&2; exit 2 ;;
    esac
done
unset _arg
[ -z "$CMD" ] && _usage

# --- Log setup ----------------------------------------------------------------
LOG_FILE="$ROOT_DIR/log/$(date +%Y%m%d)/ssl_local_ca_${CMD}_$(date +%H%M%S).log"
mkdir -p "$(dirname "$LOG_FILE")"
{
    printf "# ssl_local_ca.sh log\n"
    printf "# Command : %s\n" "$CMD"
    printf "# Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# Apply   : %s  Renew: %s\n" "$APPLY" "$RENEW"
} > "$LOG_FILE"

printLine
printf "\n\033[1m  IHateWeblogic – Local CA (%s)\033[0m\n" "$CMD" | tee -a "$LOG_FILE"
printf "  Host   : %s\n" "$(_get_hostname)" | tee -a "$LOG_FILE"
printf "  CA dir : %s\n" "$SSL_CA_DIR"      | tee -a "$LOG_FILE"
printf "  Apply  : %s\n" "$APPLY"           | tee -a "$LOG_FILE"
printf "  Log    : %s\n" "$LOG_FILE"        | tee -a "$LOG_FILE"
printLine

# Private temp dir for password files / openssl configs (removed on exit)
WORK_DIR="$(mktemp -d)"
chmod 700 "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

# =============================================================================
# Helpers
# =============================================================================

# _days_left crt – days until notAfter (negative = expired)
_days_left() {
    local end
    end="$(openssl x509 -noout -enddate -in "$1" 2>/dev/null | cut -d= -f2)"
    [ -z "$end" ] && { printf "?"; return; }
    printf "%s" $(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
}

# _cert_info label crt [warn_days] – one line per certificate, sets ok/warn/fail
_cert_info() {
    local label="$1" crt="$2" warn_days="${3:-30}" days subj end
    if [ ! -f "$crt" ]; then
        warn "$(printf "  %-10s missing  %s" "$label" "$crt")"
        return 1
    fi
    subj="$(openssl x509 -noout -subject -nameopt oneline -in "$crt" 2>/dev/null | sed 's/^subject= *//')"
    end="$(openssl x509 -noout -enddate -in "$crt" 2>/dev/null | cut -d= -f2)"
    days="$(_days_left "$crt")"
    local line
    line="$(printf "  %-10s %-6s days  %-26s %s" "$label" "$days" "$end" "$subj")"
    if [ "$days" = "?" ]; then
        fail "$line (unreadable)"
    elif [ "$days" -lt 0 ]; then
        fail "$line EXPIRED"
    elif [ "$days" -lt "$warn_days" ]; then
        warn "$line"
    else
        ok "$line"
    fi
}

# _new_secret – random password (letters/digits only, no quoting issues)
_new_secret() {
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-32
}

# _pass_file var file – write the value of variable var into file (600)
_pass_file() {
    local -n _pv="$1"
    : > "$2"; chmod 600 "$2"
    printf '%s\n' "$_pv" > "$2"
}

# _load_ca_pass – SSL_CA_PASS from des3 -> $WORK_DIR/ca.pw
_load_ca_pass() {
    load_secrets_file "$CA_SEC_FILE" || return 1
    if [ -z "${SSL_CA_PASS:-}" ]; then
        fail "SSL_CA_PASS not found in $CA_SEC_FILE"
        return 1
    fi
    _pass_file SSL_CA_PASS "$WORK_DIR/ca.pw"
    unset SSL_CA_PASS
}

# _subject_cnf file cn [ext_section_content] – openssl req config with DN
_subject_cnf() {
    local f="$1" cn="$2"
    {
        printf "[req]\ndistinguished_name = dn\nprompt = no\n\n[dn]\n"
        printf "C = %s\n" "$SSL_COUNTRY"
        [ -n "$SSL_STATE" ]    && printf "ST = %s\n" "$SSL_STATE"
        [ -n "$SSL_CITY" ]     && printf "L = %s\n"  "$SSL_CITY"
        printf "O = %s\n" "$SSL_ORG"
        [ -n "$SSL_ORG_UNIT" ] && printf "OU = %s\n" "$SSL_ORG_UNIT"
        printf "CN = %s\n" "$cn"
    } > "$f"
}

# _sign_csr csr crt days extfile – sign a CSR with the root
_sign_csr() {
    openssl x509 -req -in "$1" -out "$2" -days "$3" -sha256 \
        -CA "$CA_CRT" -CAkey "$CA_KEY" -passin "file:$WORK_DIR/ca.pw" \
        -CAserial "$CA_SRL" -CAcreateserial \
        -extfile "$4" -extensions ext 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
}

# _backup files... – move existing files to *.bak_<ts>
_backup() {
    local ts f
    ts="$(date +%Y%m%d_%H%M%S)"
    for f in "$@"; do
        [ -f "$f" ] && mv "$f" "${f}.bak_${ts}" && info "  backup: ${f}.bak_${ts}"
    done
    return 0
}

# _need_ca – the root must exist for server / codesign
_need_ca() {
    if [ ! -f "$CA_CRT" ] || [ ! -f "$CA_KEY" ]; then
        fail "Root CA not found: $CA_CRT"
        info "  Create it first: ./08-SSL/ssl_local_ca.sh init --apply"
        return 1
    fi
    if [ ! -f "$CA_SEC_FILE" ]; then
        fail "CA passphrase file missing: $CA_SEC_FILE"
        return 1
    fi
}

# =============================================================================
# status
# =============================================================================
_cmd_status() {
    section "Root CA"
    _cert_info "root" "$CA_CRT" 365
    if [ -f "$CA_CRT" ]; then
        [ -f "$CA_KEY" ]      && ok "  root key   : $CA_KEY" || fail "  root key missing: $CA_KEY"
        [ -f "$CA_SEC_FILE" ] && ok "  passphrase : $CA_SEC_FILE" || warn "  passphrase file missing: $CA_SEC_FILE"
        [ -f "$CA_CER" ]      && ok "  for clients: $CA_CER (DER, Windows/GPO) / $CA_CRT (PEM)"
        local _perm
        _perm="$(stat -c %a "$SSL_CA_DIR" 2>/dev/null)"
        [ "$_perm" = "700" ] && ok "  $SSL_CA_DIR mode 700" \
                             || warn "  $SSL_CA_DIR mode $_perm (expected 700)"
    else
        info "  Create: ./08-SSL/ssl_local_ca.sh init --apply"
    fi

    section "Server certificate (TLS)"
    local _srv="$SRV_DIR/${SSL_CN}.crt"
    if _cert_info "server" "$_srv"; then
        if [ -f "$CA_CRT" ]; then
            openssl verify -CAfile "$CA_CRT" "$_srv" >/dev/null 2>&1 \
                && ok "  chain      : verified against the root" \
                || fail "  chain      : NOT signed by this root"
        fi
        openssl x509 -noout -ext subjectAltName -in "$_srv" 2>/dev/null \
            | sed -n '2p' | sed 's/^ */  SAN        : /' | tee -a "$LOG_FILE"
        if [ -f "$SSL_CERT_FILE" ] && cmp -s "$_srv" "$SSL_CERT_FILE"; then
            ok "  SSL_CERT_FILE = issued certificate ($SSL_CERT_FILE)"
        else
            warn "  SSL_CERT_FILE differs from the issued certificate: $SSL_CERT_FILE"
            info "  Copy: ./08-SSL/ssl_prepare_cert.sh LOCALCA --apply"
        fi
    else
        info "  Create: ./08-SSL/ssl_prepare_cert.sh LOCALCA --apply"
    fi

    section "Code-signing certificate (Forms/WebUtil)"
    if _cert_info "codesign" "$CS_CRT"; then
        if [ -f "$CA_CRT" ]; then
            openssl verify -CAfile "$CA_CRT" -purpose any "$CS_CRT" >/dev/null 2>&1 \
                && ok "  chain      : verified against the root" \
                || fail "  chain      : NOT signed by this root"
        fi
        if [ ! -f "$FORMS_SIGN_KEYSTORE" ]; then
            fail "  keystore missing: $FORMS_SIGN_KEYSTORE"
        elif [ ! -f "$SIGN_SEC_FILE" ]; then
            warn "  keystore password file missing: $SIGN_SEC_FILE"
        elif load_secrets_file "$SIGN_SEC_FILE" && [ -n "${FORMS_SIGN_STOREPASS:-}" ]; then
            _pass_file FORMS_SIGN_STOREPASS "$WORK_DIR/ks.pw"
            unset FORMS_SIGN_STOREPASS
            if openssl pkcs12 -in "$FORMS_SIGN_KEYSTORE" -noout -passin "file:$WORK_DIR/ks.pw" 2>/dev/null; then
                ok "  keystore   : $FORMS_SIGN_KEYSTORE (opens with the des3 password)"
            else
                fail "  keystore   : $FORMS_SIGN_KEYSTORE does not open with the des3 password"
            fi
        fi
    else
        info "  Create (only Forms with FORMS_WEBUTIL_JACOB=true): ./08-SSL/ssl_local_ca.sh codesign --apply"
    fi
}

# =============================================================================
# init – root CA
# =============================================================================
_cmd_init() {
    section "Root CA"
    printList "CN"       22 "$SSL_CA_CN"
    printList "Validity" 22 "${SSL_CA_DAYS} days"
    printList "Key"      22 "RSA ${SSL_CA_KEY_SIZE}, AES-256 encrypted"
    printList "Files"    22 "$CA_KEY, $CA_CRT, $CA_CER"

    if [ -f "$CA_CRT" ]; then
        ok "Root CA exists – not overwritten: $CA_CRT"
        _cert_info "root" "$CA_CRT" 365
        info "  A new root must be distributed to every client again."
        info "  Only if really wanted: move $SSL_CA_DIR away and run init again."
        return 0
    fi
    if ! $APPLY; then
        info "Dry-run – root CA would be created. Use --apply."
        return 0
    fi

    mkdir -p "$SSL_CA_DIR/ca" "$SRV_DIR" "$CS_DIR" || { fail "Cannot create $SSL_CA_DIR"; return 1; }
    chmod 700 "$SSL_CA_DIR" "$SSL_CA_DIR/ca" "$SRV_DIR" "$CS_DIR"

    # Passphrase: existing des3 file (e.g. restored) or a new random one
    if [ -f "$CA_SEC_FILE" ]; then
        info "Using existing passphrase file: $CA_SEC_FILE"
    else
        _write_secrets_file "$CA_SEC_FILE" "SSL_CA_PASS=$(_new_secret)" || return 1
    fi
    _load_ca_pass || return 1

    local _cnf="$WORK_DIR/ca.cnf"
    _subject_cnf "$_cnf" "$SSL_CA_CN"
    {
        printf "\n[v3_ca]\n"
        printf "basicConstraints = critical, CA:TRUE, pathlen:0\n"
        printf "keyUsage = critical, keyCertSign, cRLSign\n"
        printf "subjectKeyIdentifier = hash\n"
        printf "authorityKeyIdentifier = keyid:always\n"
    } >> "$_cnf"

    info "Generating root key (RSA ${SSL_CA_KEY_SIZE}) ..."
    openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:${SSL_CA_KEY_SIZE}" \
        -aes-256-cbc -pass "file:$WORK_DIR/ca.pw" -out "$CA_KEY" >> "$LOG_FILE" 2>&1 \
        || { fail "Root key generation failed (see $LOG_FILE)"; return 1; }
    chmod 600 "$CA_KEY"

    info "Self-signing the root certificate ..."
    openssl req -x509 -new -key "$CA_KEY" -passin "file:$WORK_DIR/ca.pw" \
        -sha256 -days "$SSL_CA_DAYS" -config "$_cnf" -extensions v3_ca \
        -out "$CA_CRT" 2>&1 | tee -a "$LOG_FILE"
    [ "${PIPESTATUS[0]}" -eq 0 ] || { fail "Root certificate failed"; return 1; }
    openssl x509 -in "$CA_CRT" -outform DER -out "$CA_CER"
    chmod 644 "$CA_CRT" "$CA_CER"

    ok "Root CA created: $CA_CRT"
    _cert_info "root" "$CA_CRT" 365
    info "  Distribute to the clients: $CA_CER (Windows/GPO) or $CA_CRT (PEM)"
    info "  Back up $SSL_CA_DIR + the passphrase offline (password safe)"
}

# =============================================================================
# server – TLS certificate
# =============================================================================
_cmd_server() {
    local _key="$SRV_DIR/${SSL_CN}.key" _csr="$SRV_DIR/${SSL_CN}.csr" _crt="$SRV_DIR/${SSL_CN}.crt"

    # CN always first SAN entry
    printf '%s' "$SSL_SAN" | grep -qw "DNS:$SSL_CN" || SSL_SAN="DNS:${SSL_CN}${SSL_SAN:+ $SSL_SAN}"

    section "Server certificate (TLS)"
    printList "CN"        22 "$SSL_CN"
    printList "SAN"       22 "$SSL_SAN"
    printList "Key"       22 "${SSL_KEY_ALGO} / ${SSL_KEY_SIZE:-$SSL_EC_CURVE}"
    printList "Validity"  22 "${SSL_DAYS} days"
    printList "Issued"    22 "$_crt"
    printList "Copy to"   22 "$SSL_CERT_FILE, $SSL_KEY_FILE, $SSL_CHAIN_FILE"

    _need_ca || return 1

    local _issue=true
    if [ -f "$_crt" ] && ! $RENEW; then
        local _d; _d="$(_days_left "$_crt")"
        if [ "$_d" != "?" ] && [ "$_d" -ge 30 ]; then
            ok "Valid certificate for $SSL_CN exists ($_d days) – not re-issued (--renew to force)"
            _issue=false
        else
            warn "Certificate for $SSL_CN expires in $_d days – re-issuing"
        fi
    fi

    if ! $APPLY; then
        $_issue && info "Dry-run – certificate would be issued. Use --apply."
        $_issue || info "Dry-run – files would be copied to the SSL_* paths. Use --apply."
        return 0
    fi

    if $_issue; then
        _load_ca_pass || return 1
        _backup "$_key" "$_csr" "$_crt"

        local _cnf="$WORK_DIR/server.cnf" _ext="$WORK_DIR/server_ext.cnf"
        _subject_cnf "$_cnf" "$SSL_CN"
        {
            printf "[ext]\n"
            printf "basicConstraints = critical, CA:FALSE\n"
            printf "keyUsage = critical, digitalSignature, keyEncipherment\n"
            printf "extendedKeyUsage = serverAuth\n"
            printf "subjectAltName = %s\n" "${SSL_SAN// /,}"
            printf "subjectKeyIdentifier = hash\n"
            printf "authorityKeyIdentifier = keyid,issuer\n"
        } > "$_ext"

        info "Generating key + CSR ..."
        if [ "${SSL_KEY_ALGO^^}" = "EC" ]; then
            openssl genpkey -algorithm EC -pkeyopt "ec_paramgen_curve:${SSL_EC_CURVE}" \
                -out "$_key" >> "$LOG_FILE" 2>&1
        else
            openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:${SSL_KEY_SIZE}" \
                -out "$_key" >> "$LOG_FILE" 2>&1
        fi
        [ $? -eq 0 ] || { fail "Key generation failed (see $LOG_FILE)"; return 1; }
        chmod 600 "$_key"
        openssl req -new -key "$_key" -config "$_cnf" -out "$_csr" 2>&1 | tee -a "$LOG_FILE"
        [ "${PIPESTATUS[0]}" -eq 0 ] || { fail "CSR failed"; return 1; }

        info "Signing with the root CA ..."
        _sign_csr "$_csr" "$_crt" "$SSL_DAYS" "$_ext" || { fail "Signing failed"; return 1; }
        chmod 644 "$_crt"
        ok "Certificate issued: $_crt"
    fi

    # Copy to the staging paths used by 09-Install/05-root_nginx_ssl.sh
    mkdir -p "$(dirname "$SSL_CERT_FILE")" "$(dirname "$SSL_KEY_FILE")" "$(dirname "$SSL_CHAIN_FILE")"
    if [ -f "$SSL_CERT_FILE" ] && ! cmp -s "$_crt" "$SSL_CERT_FILE"; then
        _backup "$SSL_CERT_FILE" "$SSL_KEY_FILE" "$SSL_CHAIN_FILE"
    fi
    cp "$_crt"   "$SSL_CERT_FILE"  && chmod 644 "$SSL_CERT_FILE"
    cp "$_key"   "$SSL_KEY_FILE"   && chmod 600 "$SSL_KEY_FILE"
    cp "$CA_CRT" "$SSL_CHAIN_FILE" && chmod 644 "$SSL_CHAIN_FILE"
    ok "Certificate : $SSL_CERT_FILE"
    ok "Private key : $SSL_KEY_FILE  (mode 600)"
    ok "CA chain    : $SSL_CHAIN_FILE  (root)"

    _cert_info "server" "$_crt"
    openssl verify -CAfile "$CA_CRT" "$_crt" 2>&1 | sed 's/^/  /' | tee -a "$LOG_FILE"
    info "  Next step (root): ./09-Install/05-root_nginx_ssl.sh --apply"
}

# =============================================================================
# codesign – code-signing certificate -> PKCS12
# =============================================================================
_cmd_codesign() {
    section "Code-signing certificate (Forms/WebUtil)"
    printList "CN"        22 "$SSL_CODESIGN_CN"
    printList "Validity"  22 "${SSL_CODESIGN_DAYS} days"
    printList "Keystore"  22 "$FORMS_SIGN_KEYSTORE (PKCS12)"
    printList "Alias"     22 "$FORMS_SIGN_ALIAS"
    printList "Password"  22 "$SIGN_SEC_FILE"

    _need_ca || return 1

    if [ -f "$CS_CRT" ] && [ -f "$FORMS_SIGN_KEYSTORE" ] && ! $RENEW; then
        local _d; _d="$(_days_left "$CS_CRT")"
        if [ "$_d" != "?" ] && [ "$_d" -ge 30 ]; then
            ok "Valid code-signing certificate exists ($_d days) – not re-issued (--renew to force)"
            return 0
        fi
        warn "Code-signing certificate expires in $_d days – re-issuing"
    fi

    if ! $APPLY; then
        info "Dry-run – code-signing certificate + keystore would be created. Use --apply."
        return 0
    fi

    _load_ca_pass || return 1
    mkdir -p "$CS_DIR" "$(dirname "$FORMS_SIGN_KEYSTORE")"
    chmod 700 "$CS_DIR"
    _backup "$CS_CRT" "$FORMS_SIGN_KEYSTORE"

    # Keystore password: keep an existing one (14- reads the same file)
    if [ -f "$SIGN_SEC_FILE" ]; then
        info "Using existing keystore password file: $SIGN_SEC_FILE"
    else
        _write_secrets_file "$SIGN_SEC_FILE" "FORMS_SIGN_STOREPASS=$(_new_secret)" || return 1
    fi
    load_secrets_file "$SIGN_SEC_FILE" || return 1
    [ -n "${FORMS_SIGN_STOREPASS:-}" ] || { fail "FORMS_SIGN_STOREPASS not in $SIGN_SEC_FILE"; return 1; }
    _pass_file FORMS_SIGN_STOREPASS "$WORK_DIR/ks.pw"
    unset FORMS_SIGN_STOREPASS

    local _key="$WORK_DIR/codesign.key" _csr="$WORK_DIR/codesign.csr"
    local _cnf="$WORK_DIR/codesign.cnf" _ext="$WORK_DIR/codesign_ext.cnf"
    _subject_cnf "$_cnf" "$SSL_CODESIGN_CN"
    {
        printf "[ext]\n"
        printf "basicConstraints = critical, CA:FALSE\n"
        printf "keyUsage = critical, digitalSignature\n"
        printf "extendedKeyUsage = critical, codeSigning\n"
        printf "subjectKeyIdentifier = hash\n"
        printf "authorityKeyIdentifier = keyid,issuer\n"
    } > "$_ext"

    info "Generating key (RSA 3072) + CSR ..."
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$_key" >> "$LOG_FILE" 2>&1 \
        || { fail "Key generation failed (see $LOG_FILE)"; return 1; }
    openssl req -new -key "$_key" -config "$_cnf" -out "$_csr" 2>&1 | tee -a "$LOG_FILE"
    [ "${PIPESTATUS[0]}" -eq 0 ] || { fail "CSR failed"; return 1; }

    info "Signing with the root CA ..."
    _sign_csr "$_csr" "$CS_CRT" "$SSL_CODESIGN_DAYS" "$_ext" || { fail "Signing failed"; return 1; }
    chmod 644 "$CS_CRT"

    # PKCS12: key + certificate + root; the alias is the friendly name.
    # The plain key exists only in WORK_DIR (removed by trap).
    info "Writing PKCS12 keystore ..."
    openssl pkcs12 -export -inkey "$_key" -in "$CS_CRT" -certfile "$CA_CRT" \
        -name "$FORMS_SIGN_ALIAS" -passout "file:$WORK_DIR/ks.pw" \
        -out "$FORMS_SIGN_KEYSTORE" 2>&1 | tee -a "$LOG_FILE"
    [ "${PIPESTATUS[0]}" -eq 0 ] || { fail "PKCS12 export failed"; return 1; }
    chmod 600 "$FORMS_SIGN_KEYSTORE"
    rm -f "$_key"

    ok "Code-signing certificate: $CS_CRT"
    ok "Keystore               : $FORMS_SIGN_KEYSTORE (alias $FORMS_SIGN_ALIAS, mode 600)"
    _cert_info "codesign" "$CS_CRT"

    # Hint for environment.conf (14- signs only when FORMS_SIGN_KEYSTORE is set there)
    local _env_ks
    _env_ks="$(grep -E '^FORMS_SIGN_KEYSTORE=' "$ROOT_DIR/environment.conf" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"')"
    if [ "$_env_ks" != "$FORMS_SIGN_KEYSTORE" ]; then
        warn "environment.conf: FORMS_SIGN_KEYSTORE is '${_env_ks}' – set it to use this keystore:"
        info "  FORMS_SIGN_KEYSTORE=\"$FORMS_SIGN_KEYSTORE\""
        info "  FORMS_SIGN_ALIAS=\"$FORMS_SIGN_ALIAS\""
    fi
    info "  Next step: ./09-Install/14-oracle_setup_forms.sh --apply (signs jacob.jar)"
}

# =============================================================================
case "$CMD" in
    status)   _cmd_status ;;
    init)     _cmd_init ;;
    server)   _cmd_server ;;
    codesign) _cmd_codesign ;;
esac

print_summary
exit "$EXIT_CODE"
