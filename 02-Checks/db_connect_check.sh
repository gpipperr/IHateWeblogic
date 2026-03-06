#!/bin/bash
# =============================================================================
# Script   : db_connect_check.sh
# Purpose  : Structured Oracle DB connection diagnostics (6 steps):
#            1-DNS  2-Ping  3-TCP  4-TNS Listener  5-Service  6-Login (opt.)
#            DB parameters from environment.conf / jps-config.xml fallback.
# Call     : ./db_connect_check.sh              # check existing config
#            ./db_connect_check.sh --new         # interactive: configure + save
#            ./db_connect_check.sh --login       # also run login test
#            ./db_connect_check.sh --login --sqlplus=/path/to/sqlplus
# Requires : getent, ping, python3 (TNS checks), optionally sqlplus/sql
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

# Encrypted credentials file (same concept as weblogic_sec.conf.des3)
SEC_CONF_DB="${SEC_CONF_DB:-${ROOT_DIR}/db_connect.conf.des3}"

init_log

# =============================================================================
# Argument parsing
# =============================================================================
NEW_MODE=false
LOGIN_MODE=false
SQLPLUS_OVERRIDE=""

for _arg in "$@"; do
    case "$_arg" in
        --new)       NEW_MODE=true ;;
        --login)     LOGIN_MODE=true ;;
        --sqlplus=*) SQLPLUS_OVERRIDE="${_arg#--sqlplus=}" ;;
    esac
done

# =============================================================================
# Helpers: environment.conf key update
# =============================================================================

# _env_set  key  value  file
# Replaces existing key=... line or appends key="value".
_env_set() {
    local key="$1" val="$2" file="$3"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$file"
    else
        printf '%s="%s"\n' "$key" "$val" >> "$file"
    fi
}

# =============================================================================
# Helpers: DB credentials (openssl des3, same concept as weblogic_sec)
# =============================================================================

_save_db_credentials() {
    local user="$1" pass="$2" dest_des3="$3"
    local plaintext="${dest_des3%.des3}"
    local systemid
    systemid="$(_get_system_identifier)"

    {
        printf 'export DB_USER="%s"\n' "$user"
        printf 'export DB_PASS="%s"\n' "$pass"
    } > "$plaintext"
    chmod 600 "$plaintext"

    openssl des3 -pbkdf2 -salt \
        -in  "$plaintext" \
        -out "$dest_des3" \
        -pass pass:"${systemid}" >/dev/null 2>&1
    local rc=$?
    rm -f "$plaintext"

    if [ "$rc" -ne 0 ]; then
        fail "Verschlüsselung fehlgeschlagen (rc=$rc)"
        return 1
    fi
    chmod 600 "$dest_des3"
    ok "Zugangsdaten gespeichert (verschlüsselt): $dest_des3"
}

_load_db_credentials() {
    local src_des3="${1:-$SEC_CONF_DB}"
    [ -f "$src_des3" ] || { fail "Keine gespeicherten DB-Zugangsdaten: $src_des3"; return 1; }

    local plaintext="${src_des3%.des3}"
    local systemid
    systemid="$(_get_system_identifier)"

    openssl des3 -pbkdf2 -d -salt \
        -in  "$src_des3" \
        -out "$plaintext" \
        -pass pass:"${systemid}" >/dev/null 2>&1
    local rc=$?

    if [ "$rc" -ne 0 ]; then
        rm -f "$plaintext"
        fail "Entschlüsselung fehlgeschlagen (anderes System oder beschädigte Datei?)"
        return 1
    fi

    # shellcheck source=/dev/null
    source "$plaintext"
    rm -f "$plaintext"

    INTERNAL_DB_PASS="${DB_PASS}"
    export DB_PASS="REDACTED"
    ok "Zugangsdaten geladen – Benutzer: ${DB_USER:-unbekannt}"
}

# =============================================================================
# Helpers: TNS protocol via Python3
# =============================================================================

# _tns_query  host  port  connect_data  [timeout_s]
# Sends a minimal TNS CONNECT packet and returns the raw listener response.
# Exit: 0=response received, 1=no response/timeout, 2=connection error
_tns_query() {
    local host="$1" port="$2" connect_data="$3" timeout_s="${4:-4}"
    command -v python3 >/dev/null 2>&1 || return 2

    python3 - "$host" "$port" "$connect_data" "$timeout_s" 2>/dev/null <<'PYEOF'
import socket, struct, sys

host    = sys.argv[1]
port    = int(sys.argv[2])
cd      = sys.argv[3]
timeout = int(sys.argv[4])

cd_b    = cd.encode('ascii')
cd_len  = len(cd_b)
offset  = 58          # standard offset to CONNECT_DATA in TNS CONNECT packet
total   = offset + cd_len

# TNS CONNECT packet:
#   8-byte common header  (length, checksum, type=0x01, flags, hdr_checksum)
#  16-byte connect fields (version, compat, service_opts, SDU, TDU, NT_proto, LTO, byte_order)
#   4-byte CD info        (cd_len, offset)
#  30-byte padding
#   N-byte CONNECT_DATA string
hdr = struct.pack('>HH', total, 0) + bytes([0x01, 0x00]) + struct.pack('>H', 0)
cf  = struct.pack('>HHHHHHHH', 0x0136, 0x012c, 0, 0x0800, 0x7fff, 0x7f08, 0, 1)
cdi = struct.pack('>HH', cd_len, offset)
pkt = hdr + cf + cdi + bytes(30) + cd_b

try:
    s = socket.create_connection((host, port), timeout=timeout)
    s.sendall(pkt)
    s.settimeout(timeout)
    resp = b''
    try:
        while len(resp) < 65536:
            chunk = s.recv(4096)
            if not chunk:
                break
            resp += chunk
    except socket.timeout:
        pass
    s.close()
    if resp:
        sys.stdout.buffer.write(resp)
        sys.exit(0)
    sys.exit(1)
except OSError as e:
    print(f"TNS_ERROR: {e}", file=sys.stderr)
    sys.exit(2)
PYEOF
}

# _tns_ora_code  response_text
# Extract ORA error number from a TNS REFUSE response (ERR=NNNNN).
_tns_ora_code() {
    printf "%s" "$1" | grep -oE 'ERR=[0-9]+' | head -1 | cut -d= -f2
}

# _ora_explain  code_number
# Human-readable message for common ORA/listener error codes.
_ora_explain() {
    case "$1" in
        0)     printf "Listener antwortet – OK" ;;
        12514) printf "Listener läuft – Service-Name beim Listener nicht registriert" ;;
        12505) printf "Listener läuft – SID nicht bekannt (SERVICE_NAME statt SID nutzen?)" ;;
        12519) printf "Service vorhanden – alle Handler belegt (Verbindungslimit erreicht)" ;;
        12521) printf "Listener läuft – Host-String nicht korrekt" ;;
        12541) printf "Kein Listener auf diesem Port" ;;
        12545) printf "Ziel-Host nicht erreichbar" ;;
        1017)  printf "Login FAIL – falscher Benutzername oder Passwort" ;;
        28000) printf "Login FAIL – Account gesperrt (lockout)" ;;
        28001) printf "Login WARN – Passwort abgelaufen" ;;
        28002) printf "Login WARN – Passwort läuft in Kürze ab" ;;
        1005)  printf "Login FAIL – leeres Passwort nicht erlaubt" ;;
        *)     printf "Unbekannter ORA-Code $1" ;;
    esac
}

# =============================================================================
# Banner
# =============================================================================
printLine
printf "\n\033[1mIHateWeblogic – Oracle DB Connection Check\033[0m\n"
printf "Host    : %s\n" "$(_get_hostname)"
printf "Date    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "Log     : %s\n\n" "$LOG_FILE"

# =============================================================================
# --new Mode: interactive dialog
# =============================================================================
if $NEW_MODE; then
    section "Neue DB-Verbindung konfigurieren"

    # Defaults: environment.conf values, fallback to jps-config.xml
    _def_host="${DB_HOST:-}"
    _def_port="${DB_PORT:-1521}"
    _def_service="${DB_SERVICE:-}"
    _def_server="${DB_SERVER:-dedicated}"

    if [ -z "$_def_host" ]; then
        _jps="${DOMAIN_HOME}/config/fmwconfig/jps-config.xml"
        if [ -f "$_jps" ]; then
            _in_b=0; _blk=""; _jurl=""
            while IFS= read -r _l; do
                if [[ "$_l" == *"<propertySet "* ]]; then
                    _in_b=1; _blk="${_l}"$'\n'
                elif [ "$_in_b" -eq 1 ]; then
                    _blk+="${_l}"$'\n'
                    if [[ "$_l" == *"</propertySet>"* ]]; then
                        if printf "%s" "$_blk" | grep -q 'value="DB_ORACLE"'; then
                            _jurl="$(printf "%s" "$_blk" \
                                | sed -n 's/.*name="jdbc\.url"[[:space:]]*value="\([^"]*\)".*/\1/p' \
                                | head -1)"
                            [ -n "$_jurl" ] && break
                        fi
                        _in_b=0; _blk=""
                    fi
                fi
            done < "$_jps"
            if [ -n "$_jurl" ]; then
                _def_host="$(   printf "%s" "$_jurl" | sed -n 's/.*host=\([^)]*\).*/\1/p'         | head -1)"
                _def_port="$(   printf "%s" "$_jurl" | sed -n 's/.*port=\([^)]*\).*/\1/p'         | head -1)"
                _def_service="$(printf "%s" "$_jurl" | sed -n 's/.*service_name=\([^)]*\).*/\1/p' | head -1)"
                _def_server="$( printf "%s" "$_jurl" | sed -n 's/.*server=\([^)]*\).*/\1/p'       | head -1)"
                info "Standardwerte aus jps-config.xml gelesen"
            fi
        fi
    fi

    printf "  (Enter = Wert in Klammern übernehmen)\n\n"

    printf "  DB Host         [%s]: " "${_def_host}" >&2
    read -r _inp_host;    DB_HOST="${_inp_host:-$_def_host}"

    printf "  DB Port         [%s]: " "${_def_port}" >&2
    read -r _inp_port;    DB_PORT="${_inp_port:-$_def_port}"

    printf "  DB Service Name [%s]: " "${_def_service}" >&2
    read -r _inp_service; DB_SERVICE="${_inp_service:-$_def_service}"

    printf "  DB Server-Typ   [%s]: " "${_def_server}" >&2
    read -r _inp_server;  DB_SERVER="${_inp_server:-$_def_server}"

    printf "  DB Username:    " >&2
    read -r _inp_user

    printf "  DB Password:    " >&2
    read -rs _inp_pass
    printf "\n\n" >&2

    # Validate mandatory fields
    if [ -z "$DB_HOST" ] || [ -z "$DB_SERVICE" ] || \
       [ -z "$_inp_user" ] || [ -z "$_inp_pass" ]; then
        fail "Host, Service-Name, Benutzername und Passwort sind Pflichtfelder"
        print_summary; exit "$EXIT_CODE"
    fi

    # Backup + update environment.conf
    backup_file "$ENV_CONF" "$ROOT_DIR"
    if ! grep -q "^DB_HOST=" "$ENV_CONF"; then
        printf '\n# ── Oracle DB Connection ─────────────────────────────────────\n' >> "$ENV_CONF"
    fi
    _env_set DB_HOST    "$DB_HOST"    "$ENV_CONF"
    _env_set DB_PORT    "$DB_PORT"    "$ENV_CONF"
    _env_set DB_SERVICE "$DB_SERVICE" "$ENV_CONF"
    _env_set DB_SERVER  "$DB_SERVER"  "$ENV_CONF"
    ok "environment.conf aktualisiert (DB_HOST / DB_PORT / DB_SERVICE / DB_SERVER)"

    _save_db_credentials "$_inp_user" "$_inp_pass" "$SEC_CONF_DB" || {
        print_summary; exit "$EXIT_CODE"
    }

    printf "\n"
    info "Starte Verbindungstest mit neuen Parametern ..."
    printf "\n"
fi

# =============================================================================
# Section 1: Verbindungsparameter
# =============================================================================
section "Verbindungsparameter"

# Resolve sqlplus: CLI flag > environment.conf > auto-detect
SQLPLUS_BIN="${SQLPLUS_OVERRIDE:-${SQLPLUS_BIN:-}}"
[ -z "$SQLPLUS_BIN" ] && SQLPLUS_BIN="$(command -v sqlplus 2>/dev/null || true)"
[ -z "$SQLPLUS_BIN" ] && SQLPLUS_BIN="$(command -v sql     2>/dev/null || true)"   # SQLcl

# Fallback: detect DB params from jps-config.xml if not in environment.conf
if [ -z "${DB_HOST:-}" ]; then
    _jps="${DOMAIN_HOME}/config/fmwconfig/jps-config.xml"
    if [ -f "$_jps" ]; then
        info "DB_HOST nicht in environment.conf – lese aus jps-config.xml ..."
        _in_b=0; _blk=""; _jurl=""
        while IFS= read -r _l; do
            if [[ "$_l" == *"<propertySet "* ]]; then
                _in_b=1; _blk="${_l}"$'\n'
            elif [ "$_in_b" -eq 1 ]; then
                _blk+="${_l}"$'\n'
                if [[ "$_l" == *"</propertySet>"* ]]; then
                    if printf "%s" "$_blk" | grep -q 'value="DB_ORACLE"'; then
                        _jurl="$(printf "%s" "$_blk" \
                            | sed -n 's/.*name="jdbc\.url"[[:space:]]*value="\([^"]*\)".*/\1/p' \
                            | head -1)"
                        [ -n "$_jurl" ] && break
                    fi
                    _in_b=0; _blk=""
                fi
            fi
        done < "$_jps"
        if [ -n "$_jurl" ]; then
            DB_HOST="$(   printf "%s" "$_jurl" | sed -n 's/.*host=\([^)]*\).*/\1/p'         | head -1)"
            DB_PORT="$(   printf "%s" "$_jurl" | sed -n 's/.*port=\([^)]*\).*/\1/p'         | head -1)"
            DB_SERVICE="$(printf "%s" "$_jurl" | sed -n 's/.*service_name=\([^)]*\).*/\1/p' | head -1)"
            DB_SERVER="$( printf "%s" "$_jurl" | sed -n 's/.*server=\([^)]*\).*/\1/p'       | head -1)"
            info "Werte aus jps-config.xml – environment.conf mit --new aktualisieren"
        fi
    fi
fi

DB_PORT="${DB_PORT:-1521}"
DB_SERVER="${DB_SERVER:-dedicated}"

printList "DB Host"       24 "${DB_HOST:-(nicht konfiguriert)}"
printList "DB Port"       24 "${DB_PORT}"
printList "DB Service"    24 "${DB_SERVICE:-(nicht konfiguriert)}"
printList "DB Server-Typ" 24 "${DB_SERVER}"
printList "sqlplus"       24 "${SQLPLUS_BIN:-(nicht gefunden)}"
if [ -f "$SEC_CONF_DB" ]; then
    ok "$(printf "  %-22s  %s" "Zugangsdaten:" "vorhanden ($SEC_CONF_DB)")"
else
    info "$(printf "  %-22s  nicht gespeichert → --new" "Zugangsdaten:")"
fi

if [ -z "${DB_HOST:-}" ]; then
    fail "DB_HOST nicht konfiguriert – bitte: ./db_connect_check.sh --new"
    print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# Schritt 1: DNS-Auflösung
# =============================================================================
section "Schritt 1 – DNS-Auflösung"

DNS_IP=""
DNS_IP="$(getent hosts "$DB_HOST" 2>/dev/null | awk '{print $1}' | head -1)"

if [ -n "$DNS_IP" ]; then
    ok "$(printf "  %-24s  %s → %s" "getent hosts:" "$DB_HOST" "$DNS_IP")"
else
    fail "$(printf "  %-24s  %s – kein A-Record" "getent hosts:" "$DB_HOST")"
    info "  Mögliche Ursachen:"
    info "    - Hostname falsch (DB_HOST=$DB_HOST in environment.conf)"
    info "    - DNS-Server nicht erreichbar (/etc/resolv.conf prüfen)"
    info "    - Kein Eintrag in /etc/hosts"
    info "  Test: getent hosts $DB_HOST"
    print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# Schritt 2: Ping
# =============================================================================
section "Schritt 2 – ICMP Ping"

if command -v ping >/dev/null 2>&1; then
    if ping -c 3 -W 2 "$DB_HOST" >/dev/null 2>&1; then
        ok "$(printf "  %-24s  %s antwortet" "ping -c3 -W2:" "$DB_HOST")"
    else
        warn "$(printf "  %-24s  %s – kein Ping" "ping -c3 -W2:" "$DB_HOST")"
        info "  Hinweis: ICMP ist häufig durch Firewalls geblockt → nur WARN, kein FAIL"
        info "  TCP-Port-Test (Schritt 3) ist aussagekräftiger"
    fi
else
    info "  ping nicht verfügbar – Schritt übersprungen"
fi

# =============================================================================
# Schritt 3: TCP Port
# =============================================================================
section "Schritt 3 – TCP Port ${DB_PORT}"

TCP_OK=false

# Primary: bash /dev/tcp (no external tool needed)
if timeout 3 bash -c ">/dev/null </dev/tcp/${DB_HOST}/${DB_PORT}" 2>/dev/null; then
    TCP_OK=true
    ok "$(printf "  %-24s  %s:%s erreichbar" "bash /dev/tcp:" "$DB_HOST" "$DB_PORT")"
elif command -v nc >/dev/null 2>&1 && nc -z -w 3 "$DB_HOST" "$DB_PORT" 2>/dev/null; then
    TCP_OK=true
    ok "$(printf "  %-24s  %s:%s erreichbar" "nc -z -w3:" "$DB_HOST" "$DB_PORT")"
else
    fail "$(printf "  %-24s  %s:%s nicht erreichbar" "TCP Port $DB_PORT:" "$DB_HOST" "$DB_PORT")"
    info "  Mögliche Ursachen:"
    info "    - Oracle Listener nicht gestartet → am DB-Server: lsnrctl start"
    info "    - Firewall blockiert Port $DB_PORT → firewall-cmd --list-ports"
    info "    - Falscher Port in environment.conf (Standard Oracle: 1521)"
    print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# Schritt 4: Oracle TNS Listener?
# =============================================================================
section "Schritt 4 – Oracle TNS Listener auf Port ${DB_PORT}"

TNS_ALIVE=false

if command -v tnsping >/dev/null 2>&1; then
    # tnsping preferred – most reliable
    _tns_target="(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${DB_HOST})(PORT=${DB_PORT})))"
    _tnsping_out="$(timeout 6 tnsping "$_tns_target" 2>&1 | tail -4)"
    if printf "%s" "$_tnsping_out" | grep -qi "\bOK\b"; then
        TNS_ALIVE=true
        ok "  tnsping: Oracle Listener antwortet"
        info "  $(printf "%s" "$_tnsping_out" | grep -iE 'OK|ms' | head -1)"
    else
        warn "  tnsping: Port offen, aber keine Oracle TNS-Antwort"
        info "  Ausgabe: $(printf "%s" "$_tnsping_out" | head -2)"
    fi
elif command -v python3 >/dev/null 2>&1; then
    _ping_resp="$(_tns_query "$DB_HOST" "$DB_PORT" "(CONNECT_DATA=(COMMAND=ping))" 4)"
    _ping_rc=$?
    if [ "$_ping_rc" -eq 0 ] && printf "%s" "$_ping_resp" | grep -qE 'VSNNUM|ALIAS|ERR=0'; then
        TNS_ALIVE=true
        _alias="$(printf "%s" "$_ping_resp" | grep -oE 'ALIAS=[^)]+' | head -1)"
        ok "$(printf "  TNS ping: Oracle Listener antwortet (%s)" "${_alias:-TNS OK}")"
    elif [ "$_ping_rc" -eq 0 ] && [ -n "$_ping_resp" ]; then
        warn "  Port antwortet, aber keine erkennbare Oracle TNS-Antwort"
        info "  Erste Zeichen: $(printf "%s" "$_ping_resp" | tr -cd '[:print:]' | head -c 80)"
    else
        warn "  Keine TNS-Antwort auf COMMAND=ping"
        info "  Port ist offen (Schritt 3 OK) – möglicherweise anderer Dienst auf Port $DB_PORT"
    fi
else
    warn "  python3 und tnsping nicht verfügbar – TNS-Check übersprungen"
    info "  Port $DB_PORT ist offen (Schritt 3) – vermutlich Oracle Listener"
    TNS_ALIVE=true
fi

# =============================================================================
# Schritt 5: Service/SID-Check
# =============================================================================
section "Schritt 5 – Oracle Service '${DB_SERVICE:-?}'"

if [ -z "${DB_SERVICE:-}" ]; then
    warn "  DB_SERVICE nicht konfiguriert – Schritt übersprungen"
    info "  Konfigurieren mit: ./db_connect_check.sh --new"
elif ! command -v python3 >/dev/null 2>&1; then
    warn "  python3 nicht verfügbar – Service-Check übersprungen"
    info "  Manuell testen:"
    info "    tnsping '(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${DB_HOST})(PORT=${DB_PORT}))(CONNECT_DATA=(SERVICE_NAME=${DB_SERVICE})))'"
else
    _cd="(CONNECT_DATA=(SERVICE_NAME=${DB_SERVICE})(CID=(PROGRAM=IHateWeblogic)(HOST=$(_get_hostname))(USER=${USER:-oracle})))"
    _svc_resp="$(_tns_query "$DB_HOST" "$DB_PORT" "$_cd" 5)"
    _svc_rc=$?

    if [ "$_svc_rc" -eq 2 ]; then
        fail "  Verbindungsfehler beim Service-Check"
    elif [ "$_svc_rc" -eq 1 ] || [ -z "$_svc_resp" ]; then
        warn "  Keine Antwort – Service-Check uneindeutig"
        info "  Möglicherweise: Listener-Timeout oder Service akzeptiert keine anonymen Connects"
    else
        _ora="$(_tns_ora_code "$_svc_resp")"

        if [ -z "$_ora" ] || [ "$_ora" = "0" ]; then
            # REDIRECT or ACCEPT → service is registered with the listener
            if printf "%s" "$_svc_resp" | grep -q 'ADDRESS='; then
                ok "  Service gefunden – Listener sendet REDIRECT (Service registriert)"
            else
                ok "  Service '${DB_SERVICE}' bekannt beim Listener"
            fi
        else
            case "$_ora" in
                12514)
                    fail "  ORA-12514: $(_ora_explain 12514)"
                    info "  Konfigurierter Service-Name: '${DB_SERVICE}'"
                    info "  Verfügbare Services prüfen (am DB-Server als oracle):"
                    info "    lsnrctl status | grep -i service"
                    ;;
                12505)
                    warn "  ORA-12505: $(_ora_explain 12505)"
                    info "  DB_SERVICE evtl. ist ein SID – SERVICE_NAMES in init.ora prüfen"
                    ;;
                12519)
                    warn "  ORA-12519: $(_ora_explain 12519)"
                    info "  Service registriert – aber Verbindungslimit erreicht"
                    info "  In init.ora: PROCESSES / SESSIONS erhöhen"
                    ;;
                *)
                    warn "  ORA-${_ora}: $(_ora_explain "$_ora")"
                    info "  Listener-Antwort: $(printf "%s" "$_svc_resp" | tr -cd '[:print:]' | head -c 120)"
                    ;;
            esac
        fi
    fi
fi

# =============================================================================
# Schritt 6: Login-Test (nur mit --login)
# =============================================================================
if $LOGIN_MODE; then
    section "Schritt 6 – Login-Test (sqlplus Easy Connect)"

    if [ -z "${SQLPLUS_BIN:-}" ]; then
        warn "  Kein sqlplus/sql gefunden – Login-Test übersprungen"
        info "  Optionen:"
        info "    A) Oracle Instant Client installieren + SQLPLUS_BIN=/pfad/sqlplus in environment.conf"
        info "    B) SQLcl nutzen (basiert auf vorhandenem JDK):"
        info "       Download: https://www.oracle.com/tools/downloads/sqlcl-downloads.html"
        info "       Danach: SQLPLUS_BIN=/opt/sqlcl/bin/sql in environment.conf"
    elif [ ! -x "$SQLPLUS_BIN" ]; then
        warn "  SQLPLUS_BIN nicht ausführbar: $SQLPLUS_BIN"
    elif [ ! -f "$SEC_CONF_DB" ]; then
        warn "  Keine gespeicherten Zugangsdaten – bitte zuerst:"
        info "  ./db_connect_check.sh --new"
    else
        _load_db_credentials "$SEC_CONF_DB" || { print_summary; exit "$EXIT_CODE"; }

        EASY_CONNECT="//${DB_HOST}:${DB_PORT}/${DB_SERVICE}"
        printList "  Benutzer"    20 "${DB_USER:-unbekannt}"
        printList "  Connect"     20 "$EASY_CONNECT"
        printf "\n"

        # -L = no retry on wrong password  -S = silent (no banner)
        LOGIN_OUT="$(echo "exit" | timeout 15 "$SQLPLUS_BIN" -L -S \
            "${DB_USER}/${INTERNAL_DB_PASS}@${EASY_CONNECT}" 2>&1)"
        LOGIN_RC=$?

        ORA_LOGIN="$(printf "%s" "$LOGIN_OUT" | grep -oE 'ORA-[0-9]+' | head -1)"

        if [ -z "$ORA_LOGIN" ] && [ "$LOGIN_RC" -eq 0 ]; then
            ok "  Login erfolgreich – Verbindung OK"
        elif [ -z "$ORA_LOGIN" ] && printf "%s" "$LOGIN_OUT" | grep -qi "connected"; then
            ok "  Login erfolgreich (Connected)"
        elif [ -z "$ORA_LOGIN" ]; then
            warn "  sqlplus ohne ORA-Code beendet (RC=$LOGIN_RC)"
            info "  Ausgabe: $(printf "%s" "$LOGIN_OUT" | head -3)"
        else
            _ora_num="${ORA_LOGIN#ORA-}"
            case "$_ora_num" in
                1017|28000|1005)
                    fail "  ${ORA_LOGIN}: $(_ora_explain "$_ora_num")"
                    info "  Zugangsdaten neu eingeben: ./db_connect_check.sh --new"
                    ;;
                28001|28002)
                    warn "  ${ORA_LOGIN}: $(_ora_explain "$_ora_num")"
                    info "  Passwort ändern als DBA: ALTER USER ${DB_USER} IDENTIFIED BY <neues_passwort>;"
                    ;;
                *)
                    fail "  ${ORA_LOGIN}: $(_ora_explain "$_ora_num")"
                    info "  Ausgabe: $(printf "%s" "$LOGIN_OUT" | grep -E 'ORA-|ERROR' | head -3)"
                    ;;
            esac
        fi
    fi
else
    # Hint when credentials + sqlplus are ready
    if [ -f "$SEC_CONF_DB" ] && [ -n "${SQLPLUS_BIN:-}" ]; then
        printf "\n"
        info "  Tipp: Login-Test möglich mit: ./db_connect_check.sh --login"
    fi
fi

# =============================================================================
# Summary
# =============================================================================
print_summary
exit $EXIT_CODE
