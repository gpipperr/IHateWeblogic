#!/bin/bash
# =============================================================================
# Script   : create_server_cert_from_pfx.sh
# Purpose  : Split a PFX / PKCS#12 container (e.g. a wildcard certificate from
#            the customer's PKI) into the PEM files a web server needs:
#              server.key      private key, unencrypted (Nginx / Apache read it
#                              at start as root and cannot ask for a passphrase)
#              server.cert     the server certificate (leaf)
#              ca_chain.cert   intermediate CA(s), leaf issuer first (+ root if
#                              it is in the container)
#            Without --apply: only LIST the container - does the password fit,
#            format / encryption, every certificate with subject, issuer, SAN
#            (wildcard names), validity, CA yes/no, fingerprint; key type;
#            key <-> certificate check; chain order. Nothing is written.
#            Works with OpenSSL 1.1.1 (OL 8: -nodes, reads old RC2 PFX) and
#            OpenSSL 3.x (OL 9: -noenc, -legacy for old RC2 PFX - detected).
#            Background: 08-SSL/README.md "Manual: split a PFX / PKCS#12".
# Call     : ./create_server_cert_from_pfx.sh --in FILE.pfx [--pwd PWFILE]
#                 [-o OUTDIR] [--apply]
#            --in    the PFX / P12 container
#            --pwd   file that holds the container password in its first line
#                    (e.g. pw.text from the mail) - without it the password is
#                    asked hidden. The password is NEVER given on the command
#                    line (shell history, process list).
#            -o      output directory for --apply (default: the directory of
#                    the PFX); existing files are kept as <file>.bak_<ts>
#            --apply write server.key (600), server.cert, ca_chain.cert (644)
# Runs as  : any user that can read the PFX (writes only into -o)
# Exit     : 0 ok, 1 checks with findings (expired, key does not match ...),
#            2 error (wrong password, not readable, usage)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

set -u
umask 077
VERSION="2026-11-16.1"   # bump on every change

IN=""; PWF=""; OUT=""; APPLY=false
while [ $# -gt 0 ]; do
    case "$1" in
        --in)    IN="${2:-}"; shift ;;
        --pwd)   PWF="${2:-}"; shift ;;
        -o)      OUT="${2:-}"; shift ;;
        --apply) APPLY=true ;;
        -h|--help) sed -n '2,37p' "$0"; printf 'Version: %s\n' "$VERSION"; exit 0 ;;
        -V|--version) printf '%s\n' "$VERSION"; exit 0 ;;
        *) printf 'Unknown option: %s (--help)\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  OK    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; FIND=$((FIND + 1)); }
fail() { printf '  FAIL  %s\n' "$*"; FIND=$((FIND + 1)); }
FIND=0

[ -n "$IN" ] || { printf 'usage: %s --in FILE.pfx [--pwd PWFILE] [-o OUTDIR] [--apply]\n' "$0" >&2; exit 2; }
[ -r "$IN" ] || { printf 'not readable: %s\n' "$IN" >&2; exit 2; }
command -v openssl >/dev/null 2>&1 || { printf 'openssl not found\n' >&2; exit 2; }
[ -z "$PWF" ] || [ -r "$PWF" ] || { printf 'password file not readable: %s\n' "$PWF" >&2; exit 2; }

TMP="$(mktemp -d)" || exit 2
trap 'rm -rf "${TMP:?}"' EXIT
trap 'exit 130' INT TERM HUP

# --- password: file (first line) or hidden prompt - into a 600 file for -passin
if [ -n "$PWF" ]; then
    head -1 "$PWF" | tr -d '\r' > "$TMP/pw"
else
    read -r -s -p "  Password of $(basename "$IN"): " _pw; printf '\n'
    printf '%s' "$_pw" > "$TMP/pw"; unset _pw
fi

# --- OpenSSL version: 1.1.1 -> -nodes, no -legacy; 3.x -> -noenc, -legacy if needed
OSSL="$(openssl version 2>/dev/null)"
case "$OSSL" in
    "OpenSSL 1."*) NOENC="-nodes" ;;
    *)             NOENC="-noenc" ;;
esac
LEGACY=""
say "create_server_cert_from_pfx.sh $VERSION"
say "openssl     $OSSL"
say "container   $IN ($(stat -c %s "$IN") bytes)"
printf '\n'

# _p12 ARGS... - openssl pkcs12 on the container with the password file
_p12() { openssl pkcs12 -in "$IN" -passin "file:$TMP/pw" $LEGACY "$@"; }

# --- 1. does the password fit, which format ------------------------------------
if ! _p12 -info -nokeys -noout > "$TMP/info" 2>&1; then
    if grep -q 'unsupported' "$TMP/info" && openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
        LEGACY="-legacy"
        _p12 -info -nokeys -noout > "$TMP/info" 2>&1 || { fail "container does not open (with -legacy): $(grep -m1 -i 'error\|invalid' "$TMP/info")"; exit 2; }
        say "old container encryption (RC2 / 3DES) - read with -legacy (OpenSSL 3)"
    elif grep -qi 'mac verify\|invalid password' "$TMP/info"; then
        fail "WRONG PASSWORD (mac verify failure)"; exit 2
    else
        fail "container does not open: $(grep -m1 -iv '^\s*$' "$TMP/info")"; exit 2
    fi
fi
ok "password fits"
say "format      $(grep -m1 '^MAC' "$TMP/info" | sed 's/:  */: /')"
grep -E '^(PKCS7|Shrouded Keybag|PKCS8)' "$TMP/info" | sort -u | while IFS= read -r l; do say "            $l"; done

# --- 2. certificates and key ------------------------------------------------------
_p12 -nokeys -out "$TMP/all.pem" 2>/dev/null || { fail "certificates not readable"; exit 2; }
_p12 -nocerts $NOENC -out "$TMP/key.pem" 2>/dev/null
if ! openssl pkey -in "$TMP/key.pem" -out "$TMP/key.clean" 2>/dev/null; then
    fail "no private key in the container (certificates only?)"; : > "$TMP/key.clean"
fi
# split into one file per certificate
awk -v d="$TMP" '/-----BEGIN CERTIFICATE-----/{n++; f=sprintf("%s/c%02d.pem", d, n); on=1} on{print > f} /-----END CERTIFICATE-----/{on=0; close(f)}' "$TMP/all.pem"
mapfile -t CERTS < <(ls "$TMP"/c*.pem 2>/dev/null)
[ ${#CERTS[@]} -gt 0 ] || { fail "no certificate in the container"; exit 2; }

KEYPUB=""
[ -s "$TMP/key.clean" ] && KEYPUB="$(openssl pkey -in "$TMP/key.clean" -pubout 2>/dev/null | sha256sum | cut -d' ' -f1)"
NOW="$(date +%s)"; LEAF=""
say "content     ${#CERTS[@]} certificate(s), $( [ -s "$TMP/key.clean" ] && printf '1 private key' || printf 'no private key')"
for c in "${CERTS[@]}"; do
    openssl x509 -in "$c" -noout -text > "$c.txt" 2>/dev/null
    subj="$(openssl x509 -in "$c" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=//')"
    iss="$(openssl x509 -in "$c" -noout -issuer -nameopt RFC2253 2>/dev/null | sed 's/^issuer=//')"
    end="$(openssl x509 -in "$c" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
    beg="$(openssl x509 -in "$c" -noout -startdate 2>/dev/null | sed 's/^notBefore=//')"
    san="$(grep -A1 'Subject Alternative Name' "$c.txt" | tail -1 | sed 's/^ *//')"
    grep -q 'CA:TRUE' "$c.txt" && ca=yes || ca=no
    pub="$(openssl x509 -in "$c" -noout -pubkey 2>/dev/null | sha256sum | cut -d' ' -f1)"
    fp="$(openssl x509 -in "$c" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')"
    alg="$(sed -n 's/^ *Signature Algorithm: //p' "$c.txt" | head -1)"
    bits="$(sed -n 's/^ *Public-Key: (\([0-9]*\) bit)/\1/p' "$c.txt" | head -1)"
    role="CA"; [ "$ca" = no ] && role="server"
    if [ -n "$KEYPUB" ] && [ "$pub" = "$KEYPUB" ]; then role="server (matches the key)"; LEAF="$c"; fi
    if [ -z "$LEAF" ] && [ "$ca" = no ] && [ -z "$KEYPUB" ]; then LEAF="$c"; fi
    printf '\n'
    say "--- certificate $(basename "$c" .pem): $role"
    say "  subject   $subj"
    say "  issuer    $iss"
    [ -n "$san" ] && say "  names     $san"
    say "  valid     $beg  ->  $end"
    say "  CA        $ca, key ${bits:-?} bit, signature ${alg:-?}"
    say "  sha256    $fp"
    e="$(date -d "$end" +%s 2>/dev/null)"
    if [ -n "$e" ] && [ "$e" -lt "$NOW" ]; then fail "  EXPIRED ($end)"
    elif [ -n "$e" ] && [ "$e" -lt $((NOW + 30 * 86400)) ]; then warn "  expires within 30 days ($end)"; fi
    case "$alg" in *sha1*|*md5*) [ "$subj" != "$iss" ] && warn "  weak signature $alg" ;; esac
done
printf '\n'

# --- 3. key <-> certificate, chain order -------------------------------------------
if [ -z "$LEAF" ]; then
    fail "no server certificate matches the private key"
else
    ok "private key matches the server certificate (public key sha256 ${KEYPUB:0:16}...)"
fi
# chain: walk from the leaf issuer through the CA certificates of the container
: > "$TMP/chain.pem"
if [ -n "$LEAF" ]; then
    cur="$LEAF"; used=" $LEAF "
    for _i in 1 2 3 4 5 6 7 8; do
        ci="$(openssl x509 -in "$cur" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//')"
        cs="$(openssl x509 -in "$cur" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
        [ "$ci" = "$cs" ] && break                       # self-signed root reached
        nxt=""
        for c in "${CERTS[@]}"; do
            case "$used" in *" $c "*) continue ;; esac
            [ "$(openssl x509 -in "$c" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')" = "$ci" ] && { nxt="$c"; break; }
        done
        [ -n "$nxt" ] || break
        openssl x509 -in "$nxt" >> "$TMP/chain.pem"; used="$used$nxt "; cur="$nxt"
    done
    nch="$(grep -c 'BEGIN CERTIFICATE' "$TMP/chain.pem")"
    if [ "$nch" -eq 0 ]; then
        warn "no intermediate CA in the container - ask for it (Java clients: PKIX path building failed)"
    else
        ok "chain: $nch CA certificate(s) in order leaf issuer -> root"
        last_s="$(awk '/BEGIN/{b=""} {b=b $0 "\n"} END{printf "%s", b}' "$TMP/chain.pem" | openssl x509 -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
        last_i="$(awk '/BEGIN/{b=""} {b=b $0 "\n"} END{printf "%s", b}' "$TMP/chain.pem" | openssl x509 -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//')"
        if [ "$last_s" = "$last_i" ]; then say "  the root CA is part of the chain (not needed by the web server, harmless)"
        else say "  chain ends below the root ($last_i) - the root comes from the clients' trust store"; fi
        if openssl verify -partial_chain -CAfile "$TMP/chain.pem" "$LEAF" > "$TMP/verify" 2>&1; then
            ok "openssl verify: server certificate -> chain OK"
        else
            fail "openssl verify: $(grep -m1 -i 'error' "$TMP/verify")"
        fi
    fi
fi

if ! $APPLY; then
    printf '\n'
    say "LIST only - nothing written. Write the files with --apply (-o OUTDIR)."
    exit $(( FIND > 0 ? 1 : 0 ))
fi

# --- 4. --apply: write the three files ---------------------------------------------
[ -n "$LEAF" ] && [ -s "$TMP/key.clean" ] || { fail "nothing written - no matching key / server certificate"; exit 2; }
OUT="${OUT:-$(dirname "$IN")}"
mkdir -p "$OUT" || exit 2
TS="$(date +%Y%m%d_%H%M%S)"
printf '\n'
for f in server.key server.cert ca_chain.cert; do
    [ -e "$OUT/$f" ] && { cp -p "$OUT/$f" "$OUT/$f.bak_$TS"; say "backup      $OUT/$f.bak_$TS"; }
done
cp "$TMP/key.clean" "$OUT/server.key";  chmod 600 "$OUT/server.key"
openssl x509 -in "$LEAF" -out "$OUT/server.cert"; chmod 644 "$OUT/server.cert"
cp "$TMP/chain.pem" "$OUT/ca_chain.cert"; chmod 644 "$OUT/ca_chain.cert"
# check what was written: key and certificate belong together
k="$(openssl pkey -in "$OUT/server.key" -pubout | sha256sum | cut -d' ' -f1)"
c="$(openssl x509 -in "$OUT/server.cert" -noout -pubkey | sha256sum | cut -d' ' -f1)"
[ "$k" = "$c" ] && ok "written files: key and certificate match ($k)" || fail "written files do not match"
ls -l "$OUT/server.key" "$OUT/server.cert" "$OUT/ca_chain.cert" | sed 's/^/  /'
printf '\n'
say "Apache:  SSLCertificateFile server.cert, SSLCertificateKeyFile server.key, SSLCertificateChainFile ca_chain.cert"
say "Nginx:   cat server.cert ca_chain.cert > fullchain.pem  (ssl_certificate), server.key (ssl_certificate_key)"
say "Copy to the web server as root (key 600 root:root), then apachectl -t / nginx -t and reload."
say "server.key is UNENCRYPTED - delete the PFX / password file copies when done."
exit $(( FIND > 0 ? 1 : 0 ))
