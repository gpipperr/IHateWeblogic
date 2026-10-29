#!/bin/bash
# =============================================================================
# Script   : ssl_customer_certs.sh
# Purpose  : Check and import the certificates of a customer PKI from the
#            inbox 08-SSL/user_certs/ (gitignored) – instead of the own root CA
#            of ssl_local_ca.sh. Fixed role names (README in the inbox):
#              server.crt + server.key | server.p12   TLS certificate for Nginx
#              chain.crt                              intermediate CA(s)
#              root.crt                               company root CA
#              codesign.p12                           code signing (jacob.jar)
#              interception.crt                       CA of a TLS-interception proxy
#            Formats PEM, DER, PKCS#7 (.p7b) and PKCS#12 are detected and
#            converted to PEM. Checks: key <-> certificate, SAN contains the
#            server name, EKU, validity, signature (no SHA-1 / MD5), key size,
#            chain up to the root, CA flags.
# Call     : ./08-SSL/ssl_customer_certs.sh                  # check only
#            ./08-SSL/ssl_customer_certs.sh --apply          # check + import
#            ./08-SSL/ssl_customer_certs.sh --only server,root [--apply]
#            -i DIR   other inbox (default 08-SSL/user_certs)
# Import   : server       -> SSL_CERT_FILE / SSL_KEY_FILE / SSL_CHAIN_FILE
#                            (08-SSL/certs/, then 09-Install/05-root_nginx_ssl.sh)
#            root         -> $SSL_CA_DIR/customer/root.crt, FORMS_CLIENT_TRUST_CA,
#                            OS trust anchors (root / sudo)
#            codesign     -> $SSL_CA_DIR/customer/codesign.p12, FORMS_SIGN_*,
#                            password -> forms_sign_sec.conf.des3
#            interception -> $SSL_CA_DIR/customer/interception.crt, OS trust
#                            anchors + JDK_HOME cacerts (root / sudo)
#            ssl.conf: SSL_CERT_SOURCE=customer, SSL_LAST_MODE=CUSTOMER.
#            Replaced files are kept as *.bak_<ts>. PFX / key passwords are
#            asked (hidden), never on a command line.
# Doc      : 08-SSL/README.md ("Customer certificates"), 08-SSL/user_certs/README.md
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_SH="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB_SH" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB_SH" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB_SH"
check_env_conf "$ROOT_DIR/environment.conf" || exit 2
ENV_CONF="$ROOT_DIR/environment.conf"
# shellcheck source=../environment.conf
source "$ENV_CONF"

SSL_CERT_FILE="$SCRIPT_DIR/certs/server.crt"
SSL_KEY_FILE="$SCRIPT_DIR/certs/server.key"
SSL_CHAIN_FILE="$SCRIPT_DIR/certs/chain.crt"
SSL_CN="${WLS_SERVER_FQDN:-$(hostname -f 2>/dev/null)}"
SSL_CONF="$SCRIPT_DIR/ssl.conf"
# shellcheck source=ssl.conf
[ -f "$SSL_CONF" ] && source "$SSL_CONF"
for _v in SSL_CERT_FILE SSL_KEY_FILE SSL_CHAIN_FILE; do
    [ -n "${!_v:-}" ] && [[ "${!_v}" != /* ]] && printf -v "$_v" '%s' "$ROOT_DIR/${!_v}"
done
SSL_CA_DIR="${SSL_CA_DIR:-${ORACLE_BASE:-/u01/app/oracle}/admin/pki}"
CUST_DIR="$SSL_CA_DIR/customer"
SIGN_SEC_FILE="$ROOT_DIR/forms_sign_sec.conf.des3"
KT="${JDK_HOME:-}/bin/keytool"; [ -x "$KT" ] || KT="$(command -v keytool 2>/dev/null)"

INBOX="$SCRIPT_DIR/user_certs"
APPLY=false
ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=true ;;
        --only)  ONLY=",${2:-},"; shift ;;
        -i)      INBOX="${2:-}"; shift ;;
        -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
        *) printf "Unknown option: %s\n" "$1" >&2; exit 2 ;;
    esac
    shift
done
_want() { [ -z "$ONLY" ] || [[ "$ONLY" == *",$1,"* ]]; }

init_log
WORK_DIR="$(mktemp -d)"; chmod 700 "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT
TS="$(date +%Y%m%d_%H%M%S)"
NEXT=()                       # next steps printed at the end

# =============================================================================
# Helpers
# =============================================================================
# _ask_pw prompt var – hidden input into variable var
_ask_pw() {
    local -n _pw="$2"
    printf "  %s: " "$1" >&2; read -rs _pw; printf "\n" >&2
}
# _pwfile var – value of variable var into a 600 temp file, prints its path
_pwfile() {
    local -n _pv="$1"; local f="$WORK_DIR/pw.$RANDOM"
    ( umask 077; printf '%s\n' "$_pv" > "$f" ); printf '%s' "$f"
}
# _to_pem in out – certificate(s) in any of PEM / DER / PKCS#7 -> PEM bundle
_to_pem() {
    local in="$1" out="$2"
    if grep -q -- '-----BEGIN CERTIFICATE-----' "$in" 2>/dev/null; then
        sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$in" > "$out"
    elif grep -q -- '-----BEGIN PKCS7-----' "$in" 2>/dev/null; then
        openssl pkcs7 -in "$in" -print_certs 2>/dev/null | sed -n '/BEGIN CERT/,/END CERT/p' > "$out"
    elif openssl x509 -inform DER -in "$in" -out "$out" 2>/dev/null; then :
    elif openssl pkcs7 -inform DER -in "$in" -print_certs 2>/dev/null | sed -n '/BEGIN CERT/,/END CERT/p' > "$out" && [ -s "$out" ]; then :
    else return 1; fi
    [ -s "$out" ]
}
# _split bundle prefix – one file per certificate: prefix.1 prefix.2 …
_split() {
    awk -v p="$2" '/-----BEGIN CERTIFICATE-----/{n++; f=p"."n} n{print > f}' "$1"
    ls "$2".* 2>/dev/null
}
_subj()  { openssl x509 -noout -subject -nameopt RFC2253 -in "$1" 2>/dev/null | sed 's/^subject=//'; }
_iss()   { openssl x509 -noout -issuer  -nameopt RFC2253 -in "$1" 2>/dev/null | sed 's/^issuer=//'; }
_ext()   { openssl x509 -noout -ext "$2" -in "$1" 2>/dev/null | sed 1d | tr -d ' ' | paste -sd','; }
_is_ca() { _ext "$1" basicConstraints | grep -q 'CA:TRUE'; }
_fp()    { openssl x509 -noout -fingerprint -sha256 -in "$1" 2>/dev/null | cut -d= -f2; }
_days()  {
    local end; end="$(openssl x509 -noout -enddate -in "$1" 2>/dev/null | cut -d= -f2)"
    [ -z "$end" ] && { printf '?'; return; }
    printf '%s' $(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
}
# _quality label crt – validity, signature algorithm, key size; 0 = no FAIL
_quality() {
    local l="$1" c="$2" rc=0 d sig bits
    d="$(_days "$c")"
    sig="$(openssl x509 -noout -text -in "$c" 2>/dev/null | sed -n 's/^ *Signature Algorithm: *//p' | head -1)"
    bits="$(openssl x509 -noout -text -in "$c" 2>/dev/null | sed -n 's/.*Public-Key: *(\([0-9]*\) bit).*/\1/p' | head -1)"
    if [ "$d" = "?" ]; then fail "  $l: unreadable"; return 1
    elif [ "$d" -lt 0 ]; then fail "  $l: EXPIRED ($d days)"; rc=1
    elif [ "$d" -lt 30 ]; then warn "  $l: valid only $d more days"
    else ok "$(printf "  %-12s valid %s days" "$l:" "$d")"; fi
    case "${sig,,}" in
        *sha1*|*md5*|*md2*) [ "$(_subj "$c")" = "$(_iss "$c")" ] && _is_ca "$c" \
            && warn "  $l: self-signed root with $sig (signature of a root is not checked – OK, but replace when possible)" \
            || { fail "  $l: signature $sig – rejected by current JDKs / browsers"; rc=1; } ;;
        *) ok "$(printf "  %-12s signature %s" "$l:" "$sig")" ;;
    esac
    if openssl x509 -noout -text -in "$c" 2>/dev/null | grep -q 'rsaEncryption'; then
        if [ "${bits:-0}" -lt 2048 ]; then fail "  $l: RSA $bits bit < 2048"; rc=1
        else ok "$(printf "  %-12s RSA %s bit" "$l:" "$bits")"; fi
    else
        ok "$(printf "  %-12s EC %s bit" "$l:" "${bits:-?}")"
    fi
    return $rc
}
# _order leaf chainfile out – intermediates sorted leaf -> root (by issuer)
_order() {
    local cur="$1" pool=("${@:3}") out="$2" c found
    : > "$out"
    for _ in 1 2 3 4 5 6; do
        found=""
        for c in "${pool[@]}"; do
            [ "$(_subj "$c")" = "$(_iss "$cur")" ] && [ "$c" != "$cur" ] && { found="$c"; break; }
        done
        [ -z "$found" ] && break
        [ "$(_subj "$found")" = "$(_iss "$found")" ] && break    # root is not part of the chain
        cat "$found" >> "$out"; cur="$found"
    done
}
# _put src dst mode – copy with *.bak_<ts> of an existing different target
_put() {
    local s="$1" d="$2" m="$3"
    mkdir -p "$(dirname "$d")"
    if [ -f "$d" ] && cmp -s "$s" "$d"; then ok "  unchanged  $d"; return 0; fi
    [ -f "$d" ] && cp -p "$d" "${d}.bak_${TS}" && info "  backup     ${d}.bak_${TS}"
    install -m "$m" "$s" "$d" && ok "  written    $d"
}
# _set_conf file key value – replace KEY= or append (follows the symlink)
_set_conf() {
    local f="$1" k="$2" v="$3"
    [ -f "$f" ] || : > "$f"
    if grep -q "^${k}=" "$f"; then
        sed -i --follow-symlinks "s|^${k}=.*|${k}=\"${v}\"|" "$f"
    else
        printf '%s="%s"\n' "$k" "$v" >> "$(readlink -f "$f")"
    fi
    ok "  $(basename "$f"): ${k}=${v}"
}
# _anchor crt name – OS trust anchor (root / sudo, else the command is printed)
_anchor() {
    local a="/etc/pki/ca-trust/source/anchors/$2"
    if [ -f "$a" ] && cmp -s "$1" "$a"; then ok "  OS trust anchor present: $a"; return 0; fi
    if $APPLY; then
        ihw_run_root cp "$1" "$a" && ihw_run_root update-ca-trust extract \
            && ok "  OS trust anchor: $a (update-ca-trust)"
    else
        info "  would add OS trust anchor: $a + update-ca-trust (root)"
    fi
}

_find() {   # _find role-base – first existing file of base.{crt,cer,pem,der,p7b}
    local b="$1" e
    for e in crt cer pem der p7b; do [ -f "$INBOX/$b.$e" ] && { printf '%s' "$INBOX/$b.$e"; return 0; }; done
    return 1
}

printLine
section "Customer certificates – $(date '+%Y-%m-%d %H:%M:%S')"
printList "Inbox"       20 "$INBOX"
printList "Server name" 20 "${WLS_SERVER_FQDN:-?}  (SSL_CN ${SSL_CN:-?})"
printList "Target"      20 "$CUST_DIR (root, codesign, interception), $(dirname "$SSL_CERT_FILE") (server)"
printList "Mode"        20 "$($APPLY && printf 'APPLY – import' || printf 'check only (--apply imports)')"
if [ ! -d "$INBOX" ]; then fail "Inbox not found: $INBOX"; print_summary; exit "$EXIT_CODE"; fi
_files="$(find "$INBOX" -maxdepth 1 -type f ! -name 'README*' -printf '%f ' 2>/dev/null)"
printList "Files"       20 "${_files:-(none)}"
[ -z "$_files" ] && { warn "Inbox is empty – see $INBOX/README.md"; print_summary; exit "$EXIT_CODE"; }
command -v openssl > /dev/null || { fail "openssl not found"; print_summary; exit "$EXIT_CODE"; }

# =============================================================================
# root.crt (first – the other roles verify against it)
# =============================================================================
ROOT_PEM=""
if _want root && _f="$(_find root)"; then
    section "Company root CA ($(basename "$_f"))"
    if _to_pem "$_f" "$WORK_DIR/root.pem"; then
        _r="$(_split "$WORK_DIR/root.pem" "$WORK_DIR/root" | head -1)"
        info "  subject     $(_subj "$_r")"
        info "  SHA-256     $(_fp "$_r")   (compare with the customer)"
        _rok=0
        _is_ca "$_r" && ok "  CA:TRUE" || { fail "  no CA certificate (basicConstraints CA:TRUE missing)"; _rok=1; }
        [ "$(_subj "$_r")" = "$(_iss "$_r")" ] && ok "  self-signed (root)" \
            || warn "  not self-signed – an intermediate? issuer: $(_iss "$_r")"
        _quality "root" "$_r" || _rok=1
        ROOT_PEM="$_r"
        if [ "$_rok" -eq 0 ] && $APPLY; then
            _put "$_r" "$CUST_DIR/root.crt" 644
            _set_conf "$ENV_CONF" FORMS_CLIENT_TRUST_CA "$CUST_DIR/root.crt"
            _anchor "$_r" ihw-customer-root.crt
            NEXT+=("Client bundle with the customer root: ./09-Install/40-oracle_forms_client_bundle.sh --apply (if FORMS_CLIENT_DIST=true)")
        elif [ "$_rok" -eq 0 ]; then
            info "  would import to $CUST_DIR/root.crt, FORMS_CLIENT_TRUST_CA, OS trust anchor"
            _anchor "$_r" ihw-customer-root.crt
        fi
    else
        fail "  not a certificate (PEM / DER / PKCS#7): $_f"
    fi
fi
_verify() {   # _verify leaf chainfile – against root.crt, else the OS store
    [ -s "${2:-/x}" ] || set -- "$1" ""
    if [ -n "$ROOT_PEM" ]; then
        openssl verify -CAfile "$ROOT_PEM" ${2:+-untrusted "$2"} "$1" > "$WORK_DIR/verify.out" 2>&1
    else
        openssl verify ${2:+-untrusted "$2"} "$1" > "$WORK_DIR/verify.out" 2>&1
    fi
}

# =============================================================================
# server certificate
# =============================================================================
if _want server && { [ -f "$INBOX/server.p12" ] || [ -f "$INBOX/server.pfx" ] || _find server > /dev/null; }; then
    section "Server certificate (Nginx)"
    _sok=0; _leaf=""; _key="$WORK_DIR/server.key"; _pool=()
    _p12="$INBOX/server.p12"; [ -f "$_p12" ] || _p12="$INBOX/server.pfx"
    if [ -f "$_p12" ]; then
        _ask_pw "Password of $(basename "$_p12")" _SP; _spf="$(_pwfile _SP)"; unset _SP
        if openssl pkcs12 -in "$_p12" -passin "file:$_spf" -nokeys -out "$WORK_DIR/srv_all.pem" 2>/dev/null \
           || openssl pkcs12 -legacy -in "$_p12" -passin "file:$_spf" -nokeys -out "$WORK_DIR/srv_all.pem" 2>/dev/null; then
            openssl pkcs12 -in "$_p12" -passin "file:$_spf" -nocerts -nodes -out "$_key" 2>/dev/null \
              || openssl pkcs12 -legacy -in "$_p12" -passin "file:$_spf" -nocerts -nodes -out "$_key" 2>/dev/null
            ok "  $(basename "$_p12") opens"
        else
            fail "  $(basename "$_p12") does not open with this password"; _sok=1
        fi
    else
        _to_pem "$(_find server)" "$WORK_DIR/srv_all.pem" || { fail "  server certificate unreadable"; _sok=1; }
        _kf="$INBOX/server.key"
        if [ ! -f "$_kf" ]; then
            fail "  server.key missing"; _sok=1
        elif grep -q 'ENCRYPTED' "$_kf"; then
            _ask_pw "Passphrase of server.key" _KP; _kpf="$(_pwfile _KP)"; unset _KP
            openssl pkey -in "$_kf" -passin "file:$_kpf" -out "$_key" 2>/dev/null \
                && ok "  server.key decrypted (Nginx needs it unencrypted, file mode 600)" \
                || { fail "  server.key: wrong passphrase"; _sok=1; }
        else
            openssl pkey -in "$_kf" -out "$_key" 2>/dev/null || { fail "  server.key unreadable"; _sok=1; }
        fi
    fi
    if [ -s "$WORK_DIR/srv_all.pem" ]; then
        for _c in $(_split "$WORK_DIR/srv_all.pem" "$WORK_DIR/srv"); do
            if _is_ca "$_c"; then _pool+=("$_c"); elif [ -z "$_leaf" ]; then _leaf="$_c"; fi
        done
        if _cf="$(_find chain)"; then
            _to_pem "$_cf" "$WORK_DIR/chain_in.pem" && for _c in $(_split "$WORK_DIR/chain_in.pem" "$WORK_DIR/chn"); do _pool+=("$_c"); done
        fi
        [ -n "$ROOT_PEM" ] && _pool+=("$ROOT_PEM")
    fi
    if [ -n "$_leaf" ]; then
        info "  subject     $(_subj "$_leaf")"
        info "  issuer      $(_iss "$_leaf")"
        if [ -s "$_key" ]; then
            if [ "$(openssl x509 -noout -pubkey -in "$_leaf" 2>/dev/null)" = "$(openssl pkey -pubout -in "$_key" 2>/dev/null)" ]; then
                ok "  key matches the certificate"
            else
                fail "  key does NOT match the certificate"; _sok=1
            fi
        fi
        _san="$(_ext "$_leaf" subjectAltName)"
        for _n in $(printf '%s\n' ${WLS_SERVER_FQDN:-} ${SSL_CN:-} | sort -u); do
            [[ ",$_san," == *",DNS:${_n},"* ]] && ok "  SAN contains $_n" \
                || { fail "  SAN does not contain $_n (SAN: ${_san:-none}) – browsers reject it"; _sok=1; }
        done
        _eku="$(_ext "$_leaf" extendedKeyUsage)"
        if [ -z "$_eku" ]; then warn "  no extendedKeyUsage – usually accepted, serverAuth recommended"
        elif [[ "$_eku" == *"TLSWebServerAuthentication"* ]]; then ok "  EKU serverAuth"
        else fail "  EKU without serverAuth: $_eku"; _sok=1; fi
        _quality "server" "$_leaf" || _sok=1
        _order "$_leaf" "$WORK_DIR/chain.pem" "${_pool[@]}"
        if _verify "$_leaf" "$WORK_DIR/chain.pem"; then
            ok "  chain verifies $([ -n "$ROOT_PEM" ] && printf 'up to root.crt' || printf 'against the OS trust store')"
        else
            if [ -n "$ROOT_PEM" ]; then fail "  chain does not verify: $(grep -m1 -oE "error [0-9]+ at [0-9]+ depth lookup: .*" "$WORK_DIR/verify.out" || tail -1 "$WORK_DIR/verify.out")"; _sok=1
            else warn "  chain does not verify against the OS store (no root.crt in the inbox): $(grep -m1 -oE "error [0-9]+ at [0-9]+ depth lookup: .*" "$WORK_DIR/verify.out" || tail -1 "$WORK_DIR/verify.out")"; fi
        fi
        [ -s "$WORK_DIR/chain.pem" ] && info "  intermediates: $(grep -c 'BEGIN CERT' "$WORK_DIR/chain.pem")" \
            || info "  intermediates: none (certificate issued directly by the root)"
    else
        fail "  no server (end-entity) certificate found"; _sok=1
    fi
    if [ "$_sok" -eq 0 ] && $APPLY; then
        _put "$_leaf" "$SSL_CERT_FILE" 644
        _put "$_key"  "$SSL_KEY_FILE"  600
        [ -s "$WORK_DIR/chain.pem" ] && _put "$WORK_DIR/chain.pem" "$SSL_CHAIN_FILE" 644
        _set_conf "$SSL_CONF" SSL_LAST_MODE CUSTOMER
        NEXT+=("Deploy to Nginx (root): ./09-Install/05-root_nginx_ssl.sh --apply")
    elif [ "$_sok" -eq 0 ]; then
        info "  would write $SSL_CERT_FILE, $SSL_KEY_FILE (600)$([ -s "$WORK_DIR/chain.pem" ] && printf ', %s' "$SSL_CHAIN_FILE")"
    fi
fi

# =============================================================================
# code signing (PKCS#12)
# =============================================================================
_cs="$INBOX/codesign.p12"; [ -f "$_cs" ] || _cs="$INBOX/codesign.pfx"
if _want codesign && [ -f "$_cs" ]; then
    section "Code signing ($(basename "$_cs"))"
    _cok=0
    _ask_pw "Password of $(basename "$_cs")" _CSP; _cpf="$(_pwfile _CSP)"
    _leg=""
    openssl pkcs12 -in "$_cs" -passin "file:$_cpf" -nokeys -out "$WORK_DIR/cs_all.pem" 2>/dev/null \
      || { _leg="-legacy"; openssl pkcs12 -legacy -in "$_cs" -passin "file:$_cpf" -nokeys -out "$WORK_DIR/cs_all.pem" 2>/dev/null; } \
      || { fail "  does not open with this password"; _cok=1; }
    if [ "$_cok" -eq 0 ]; then
        ok "  opens$([ -n "$_leg" ] && printf ' (legacy RC2/3DES encryption – old PFX format, works)')"
        _alias=""
        [ -x "${KT:-/x}" ] && _alias="$("$KT" -list -keystore "$_cs" -storetype PKCS12 -storepass:file "$_cpf" 2>/dev/null \
            | sed -n 's/^\([^,]*\), .*PrivateKeyEntry.*/\1/p' | head -1)"
        [ -n "$_alias" ] && ok "  alias: $_alias" || { warn "  alias not readable with keytool – FORMS_SIGN_ALIAS stays ${FORMS_SIGN_ALIAS:-forms_codesign}"; _alias="${FORMS_SIGN_ALIAS:-forms_codesign}"; }
        _csleaf=""; _cspool=()
        for _c in $(_split "$WORK_DIR/cs_all.pem" "$WORK_DIR/cs"); do
            if _is_ca "$_c"; then _cspool+=("$_c"); elif [ -z "$_csleaf" ]; then _csleaf="$_c"; fi
        done
        [ -n "$ROOT_PEM" ] && _cspool+=("$ROOT_PEM")
        if [ -n "$_csleaf" ]; then
            info "  subject     $(_subj "$_csleaf")"
            _eku="$(_ext "$_csleaf" extendedKeyUsage)"
            [[ "$_eku" == *"CodeSigning"* ]] && ok "  EKU codeSigning" || { fail "  EKU without codeSigning: ${_eku:-none}"; _cok=1; }
            _quality "codesign" "$_csleaf" || _cok=1
            _order "$_csleaf" "$WORK_DIR/cs_chain.pem" "${_cspool[@]}"
            _verify "$_csleaf" "$WORK_DIR/cs_chain.pem" && ok "  chain verifies" \
                || warn "  chain does not verify ($(grep -m1 -oE "error [0-9]+ at [0-9]+ depth lookup: .*" "$WORK_DIR/verify.out" || tail -1 "$WORK_DIR/verify.out")) – clients must trust the issuing root"
        else
            fail "  no certificate in the PFX"; _cok=1
        fi
    fi
    if [ "$_cok" -eq 0 ] && $APPLY; then
        _put "$_cs" "$CUST_DIR/codesign.p12" 600
        [ -f "$SIGN_SEC_FILE" ] && backup_file "$SIGN_SEC_FILE" > /dev/null
        _write_secrets_file "$SIGN_SEC_FILE" "FORMS_SIGN_STOREPASS=$_CSP" && ok "  password -> $(basename "$SIGN_SEC_FILE")"
        _set_conf "$ENV_CONF" FORMS_SIGN_KEYSTORE "$CUST_DIR/codesign.p12"
        _set_conf "$ENV_CONF" FORMS_SIGN_ALIAS "$_alias"
        _set_conf "$ENV_CONF" FORMS_SIGN_LOCALCA false
        _jar="${ORACLE_HOME:-/x}/forms/java/jacob.jar"
        if [ -f "$_jar" ] && [ -f "${_jar}.orig" ]; then
            NEXT+=("Re-sign jacob.jar with the customer certificate (14- signs only an unsigned jar):"
                   "  cp -p $_jar ${_jar}.bak_${TS} && cp -p ${_jar}.orig $_jar && ./09-Install/14-oracle_setup_forms.sh --apply")
        else
            NEXT+=("Sign jacob.jar: ./09-Install/14-oracle_setup_forms.sh --apply (FORMS_WEBUTIL_JACOB=true)")
        fi
    elif [ "$_cok" -eq 0 ]; then
        info "  would import to $CUST_DIR/codesign.p12, FORMS_SIGN_KEYSTORE / _ALIAS, password -> $(basename "$SIGN_SEC_FILE")"
    fi
    unset _CSP
fi

# =============================================================================
# interception CA
# =============================================================================
if _want interception && _f="$(_find interception)"; then
    section "TLS-interception CA ($(basename "$_f"))"
    if _to_pem "$_f" "$WORK_DIR/icpt.pem"; then
        _i="$(_split "$WORK_DIR/icpt.pem" "$WORK_DIR/icpt" | head -1)"
        info "  subject     $(_subj "$_i")"
        info "  SHA-256     $(_fp "$_i")"
        _iok=0
        _is_ca "$_i" && ok "  CA:TRUE" || { fail "  no CA certificate"; _iok=1; }
        _quality "intercept" "$_i" || _iok=1
        _cacerts="${JDK_HOME:-/x}/lib/security/cacerts"
        if [ -x "${KT:-/x}" ] && [ -f "$_cacerts" ] && "$KT" -list -cacerts -storepass changeit 2>/dev/null | grep -qiF "$(_fp "$_i")"; then
            ok "  already in JDK_HOME cacerts"
        fi
        if [ "$_iok" -eq 0 ]; then
            if $APPLY; then _put "$_i" "$CUST_DIR/interception.crt" 644; fi
            _anchor "$_i" ihw-interception.crt
            NEXT+=("Java trust for the interception CA (root, JDK_HOME is owned by root; repeat after every JDK update):"
                   "  sudo $KT -importcert -noprompt -cacerts -storepass changeit -alias ihw-interception -file $CUST_DIR/interception.crt"
                   "  background: 80-FMW-Architecture/certificates_trust_stores.md §6–§8")
        fi
    else
        fail "  not a certificate: $_f"
    fi
fi

# =============================================================================
# Result
# =============================================================================
section "Result"
if $APPLY && [ "${CNT_FAIL:-0}" -eq 0 ]; then
    _set_conf "$SSL_CONF" SSL_CERT_SOURCE customer
    chmod 600 "$SSL_CONF" 2>/dev/null
fi
if [ "${#NEXT[@]}" -gt 0 ]; then
    info "Next steps:"
    for _l in "${NEXT[@]}"; do info "  $_l"; done
fi
$APPLY || info "Check only – import with: ./08-SSL/ssl_customer_certs.sh --apply"
info "After the import: delete the files in $INBOX (keys / PFX must not stay there)"
printLine
print_summary
exit "$EXIT_CODE"
