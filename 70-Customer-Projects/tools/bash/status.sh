#!/bin/bash
# =============================================================================
# status.sh - Zustand der WebLogic/Reports-Umgebung in drei Stufen
#   Stufe 1: Ports      (ss)        - hoert der Dienst auf seinem Port?
#   Stufe 2: Prozesse   (ps)        - laeuft der Prozess, seit wann, wie gross,
#                                      wer hat ihn gestartet (Node Manager?)
#   Stufe 3: Status     (curl/WLST) - was sagen WebLogic und der Node Manager?
#
# Aufruf : ./status.sh          alle drei Stufen
#          ./status.sh -q       ohne WLST (schnell, Stufe 3 nur HTTP)
#          ./status.sh --store-nm-key  Node-Manager-Zugang einmalig speichern
#                               (~/oracle-WebLogic*.properties, Rechte 600)
#          ./status.sh -h       Hilfe
# Daten  : die mit setdb gewaehlte Domain, sonst patch_install.ini im selben
#          Verzeichnis (IHW_INI=/pfad/datei.ini hat Vorrang); was fehlt, kommt aus der Domain
# Exit   : 0 = alles in Ordnung, 1 = Warnung, 2 = Fehler
# Braucht ihw_tools_lib.sh daneben, sonst nur bash, ss, ps, curl, wlst.sh.
# Beschreibung: Tools_status_logs_kochbuch.txt
# =============================================================================

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./ihw_tools_lib.sh
. "$TOOLS_DIR/ihw_tools_lib.sh" || { printf "FEHLER: ihw_tools_lib.sh fehlt neben %s\n" "$0" >&2; exit 2; }
ihwt_ops_env "$TOOLS_DIR" || exit 2

QUICK=false
STORE_KEY=false
case "${1:-}" in
    -q|--quick) QUICK=true ;;
    --store-nm-key) STORE_KEY=true ;;
    -h|--help)
        sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    "") ;;
    *) printf "Unbekannte Option: %s (Hilfe: -h)\n" "$1" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------- NM keys ----
# _nm_key_candidates - "config<TAB>key" pairs in search order: ini, storeUserConfig
# default in the home directory, keys of the library autostart (30-configure_autostart.sh)
_nm_key_candidates() {
    local d b
    [ -n "${WLST_CONFIG_FILE:-}" ] && printf '%s\t%s\n' "$WLST_CONFIG_FILE" "${WLST_KEY_FILE:-}"
    printf '%s\t%s\n' "$HOME/oracle-WebLogicConfig.properties" "$HOME/oracle-WebLogicKey.properties"
    # (duplicates: an ini may name the same pair)
    # ORACLE_BASE is not set by setdb for FMW: also above the Oracle Home
    # (/u01/app/oracle/fmw -> /u01/app/oracle, /oracle/product/mw -> /oracle)
    for b in "${ORACLE_BASE:-}" "$(dirname "${ORACLE_HOME:-/}")" "$(dirname "$(dirname "$(dirname "${ORACLE_HOME:-/}")")")"; do
        [ -n "$b" ] && [ "$b" != "/" ] || continue
        d="$b/admin/$DOMAIN_NAME/ctrl/keyfile"
        printf '%s\t%s\n' "$d/nm_config" "$d/nm_key"
    done
}

_nm_keys_hint() {   # how to create them - also shown after a failed login
    printf "    -> einmalig anlegen (Node Manager muss laufen, fragt Benutzer + Passwort):\n"
    printf "         %s --store-nm-key\n" "$(basename "$0")"
    printf "    Benutzer/Passwort unbekannt (zufaellig bei der Domain-Anlage)?\n"
    printf "         Autostart_linux_middleware.txt Schritt 1b\n"
}

NM_KEY_CFG="" NM_KEY_KEY=""
while IFS=$'\t' read -r _c _k; do
    if [ -r "$_c" ] && [ -r "$_k" ]; then NM_KEY_CFG="$_c"; NM_KEY_KEY="$_k"; break; fi
done < <(_nm_key_candidates | awk '!seen[$0]++')

# --store-nm-key: one write action of this tool, only on explicit request.
# The password goes to WLST through the environment, never on a command line.
if $STORE_KEY; then
    _cfg="${WLST_CONFIG_FILE:-$HOME/oracle-WebLogicConfig.properties}"
    _key="${WLST_KEY_FILE:-$HOME/oracle-WebLogicKey.properties}"
    _wlst="$ORACLE_HOME/oracle_common/common/bin/wlst.sh"
    printf "Node-Manager-Zugang speichern: Domain %s, %s:%s (%s)\n" "$DOMAIN_NAME" "$NM_HOST" "$WLS_NODEMANAGER_PORT" "$NM_TYPE"
    printf "  Ziel: %s\n        %s\n" "$_cfg" "$_key"
    [ -x "$_wlst" ] || { printf "FEHLER: %s nicht gefunden (ORACLE_HOME? -> setdb)\n" "$_wlst" >&2; exit 2; }
    ss -ltnH 2>/dev/null | awk -v p=":$WLS_NODEMANAGER_PORT" '$4 ~ p"$" {f=1} END {exit !f}' || {
        printf "FEHLER: auf Port %s hoert kein Node Manager - erst starten, dann erneut aufrufen\n" "$WLS_NODEMANAGER_PORT" >&2
        exit 2
    }
    [ -t 0 ] || { printf "FEHLER: fragt Benutzer + Passwort - nur im Terminal\n" >&2; exit 2; }
    if [ -e "$_cfg" ] || [ -e "$_key" ]; then
        read -r -p "  Dateien existieren - ueberschreiben? (ja/NEIN) " _a
        [ "$_a" = "ja" ] || { printf "  nichts geaendert\n"; exit 0; }
    fi
    _u_def="$(sed -n 's|.*<node-manager-username>\([^<]*\)</node-manager-username>.*|\1|p' "$DOMAIN_HOME/config/config.xml" | head -1)"
    read -r -p "  Node-Manager-Benutzer [${_u_def}]: " _u
    _u="${_u:-$_u_def}"
    read -r -s -p "  Passwort: " _p; printf "\n"
    [ -n "$_u" ] && [ -n "$_p" ] || { printf "FEHLER: Benutzer und Passwort noetig\n" >&2; exit 2; }
    PY="$(mktemp /tmp/status_nmkey_XXXXXX.py)"
    chmod 600 "$PY"
    trap 'rm -f "$PY"' EXIT
    cat > "$PY" <<'WLST_EOF'
import os
e = os.environ
try:
    nmConnect(e['_IHW_NM_USER'], e['_IHW_NM_PWD'], e['_IHW_NM_HOST'], e['_IHW_NM_PORT'],
              e['_IHW_DOMAIN'], e['_IHW_DOMAIN_HOME'], e['_IHW_NM_TYPE'])
    storeUserConfig(e['_IHW_CFG'], e['_IHW_KEY'], 'true')
    nmDisconnect()
    print('IHW:OK')
except Exception, ex:
    print('IHW:FAIL:' + str(ex).split('\n')[0])
    exit(defaultAnswer='y', exitcode=1)
exit(defaultAnswer='y', exitcode=0)
WLST_EOF
    _out="$(_IHW_NM_USER="$_u" _IHW_NM_PWD="$_p" _IHW_NM_HOST="$NM_HOST" _IHW_NM_PORT="$WLS_NODEMANAGER_PORT" \
            _IHW_DOMAIN="$DOMAIN_NAME" _IHW_DOMAIN_HOME="$DOMAIN_HOME" _IHW_NM_TYPE="$NM_TYPE" \
            _IHW_CFG="$_cfg" _IHW_KEY="$_key" "$_wlst" "$PY" 2>&1)"
    unset _p
    if printf '%s\n' "$_out" | grep -q '^IHW:OK' && [ -s "$_cfg" ] && [ -s "$_key" ]; then
        chmod 600 "$_cfg" "$_key"
        printf "  OK: gespeichert (Rechte 600). Kontrolle: %s\n" "$(basename "$0")"
        exit 0
    fi
    printf "FEHLER: nicht gespeichert: %s\n" "$(printf '%s\n' "$_out" | sed -n 's/^IHW:FAIL://p' | head -1)" >&2
    printf "  Benutzer/Passwort unbekannt (zufaellig bei der Domain-Anlage)? Autostart_linux_middleware.txt Schritt 1b\n" >&2
    exit 2
fi

RC=0
_warn() { [ "$RC" -lt 1 ] && RC=1; }
_err()  { RC=2; }

# Ergebnisse je Komponente fuer die Zusammenfassung
declare -A R_PORT R_PROC R_HTTP R_NM
COMPS=()

# Server-Liste aufbauen: Name|Typ|Port
COMPS+=("NodeManager|NM|${WLS_NODEMANAGER_PORT}")
COMPS+=("${ADMIN_SERVER}|WLS|${WLS_ADMIN_PORT}")
for _m in $MANAGED_SERVERS; do
    COMPS+=("${_m%%:*}|WLS|${_m##*:}")
done
for _r in $REPORTS_SERVERS; do
    COMPS+=("${_r}|REPORTS|-")
done

printf "\n=== Status %s  (%s, %s) ===\n" "$DOMAIN_NAME" "$(hostname -s)" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "  DOMAIN_HOME %s  (Quelle: %s)\n" "$DOMAIN_HOME" "$IHWT_OPS_SRC"

# =============================================================================
# Stufe 1: Ports
# =============================================================================
printf "\n--- Stufe 1: Ports (ss) ---------------------------------------------------\n"
SS_OUT="$(ss -ltnH 2>/dev/null)"

_port_line() {
    printf '%s\n' "$SS_OUT" | awk -v p=":$1" '$4 ~ p"$" {print $4}' | head -1
}

for c in "${COMPS[@]}"; do
    IFS='|' read -r name typ port <<< "$c"
    [ "$port" = "-" ] && continue
    addr="$(_port_line "$port")"
    if [ -n "$addr" ]; then
        printf "  %-16s Port %-6s LISTEN   %s\n" "$name" "$port" "$addr"
        R_PORT[$name]="ok"
    else
        printf "  %-16s Port %-6s FEHLT\n" "$name" "$port"
        R_PORT[$name]="FEHLT"
    fi
done
for p in $EXTRA_PORTS; do
    addr="$(_port_line "$p")"
    printf "  %-16s Port %-6s %s\n" "(weitere)" "$p" "$( [ -n "$addr" ] && printf 'LISTEN   %s' "$addr" || printf 'FEHLT' )"
done

# =============================================================================
# Stufe 2: Prozesse
# =============================================================================
printf "\n--- Stufe 2: Prozesse (ps) ------------------------------------------------\n"
NM_PID="$(pgrep -f 'java .*weblogic\.NodeManager' | head -1)"

# _von_nm <pid> - steht der Node Manager in der Kette der Elternprozesse?
_von_nm() {
    local p="$1" i
    [ -z "$NM_PID" ] && return 1
    for i in 1 2 3 4; do
        p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
        [ -z "$p" ] || [ "$p" -le 1 ] && return 1
        [ "$p" = "$NM_PID" ] && return 0
    done
    return 1
}

printf "  %-16s %-8s %-12s %-8s %s\n" "Komponente" "PID" "Laufzeit" "RAM MB" "gestartet von"
for c in "${COMPS[@]}"; do
    IFS='|' read -r name typ port <<< "$c"
    case "$typ" in
        NM)      pid="$NM_PID" ;;
        WLS)     pid="$(pgrep -f "weblogic.Name=${name}( |\$)" | head -1)" ;;
        REPORTS) pid="$(pgrep -f "rwserver server=${name}( |\$)" | head -1)" ;;
    esac
    if [ -z "$pid" ]; then
        printf "  %-16s %-8s\n" "$name" "-  (kein Prozess)"
        R_PROC[$name]="FEHLT"
        continue
    fi
    etime="$(ps -o etime= -p "$pid" | tr -d ' ')"
    rss="$(ps -o rss= -p "$pid" | awk '{printf "%d", $1/1024}')"
    if [ "$typ" = "NM" ]; then
        von="-"
    elif _von_nm "$pid"; then
        von="Node Manager"
    else
        von="Skript (Node Manager kennt ihn nicht!)"
        _warn
    fi
    extra=""
    if [ "$typ" = "REPORTS" ]; then
        extra="  Engines: $(pgrep -P "$pid" | wc -l)"
    fi
    printf "  %-16s %-8s %-12s %-8s %s%s\n" "$name" "$pid" "$etime" "$rss" "$von" "$extra"
    R_PROC[$name]="ok"
done

# =============================================================================
# Stufe 3: Status ueber HTTP und Node Manager
# =============================================================================
printf "\n--- Stufe 3: Status (HTTP /weblogic/ready, Node Manager) -----------------\n"
for c in "${COMPS[@]}"; do
    IFS='|' read -r name typ port <<< "$c"
    [ "$typ" = "WLS" ] || continue
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://localhost:${port}/weblogic/ready")"
    case "$code" in
        200) txt="200 = RUNNING" ; R_HTTP[$name]="ok" ;;
        503) txt="503 = startet noch / nicht bereit" ; R_HTTP[$name]="503" ;;
        *)   txt="${code} = nicht erreichbar" ; R_HTTP[$name]="FEHLT" ;;
    esac
    printf "  HTTP %-16s %s\n" "$name" "$txt"
done

if $QUICK; then
    printf "  Node Manager: uebersprungen (-q)\n"
elif [ -z "$NM_KEY_CFG" ]; then
    printf "  Node Manager: keine gespeicherten Zugangsdaten - Abfrage uebersprungen\n"
    printf "    gesucht:\n"
    _nm_key_candidates | awk '!seen[$0]++' | while IFS=$'\t' read -r _c _k; do printf "      %s\n" "$_c"; done
    _nm_keys_hint
    _warn
elif [ -z "$NM_PID" ]; then
    printf "  Node Manager: laeuft nicht - Status nicht abfragbar\n"
    _err
else
    PY="$(mktemp /tmp/status_nm_XXXXXX.py)"
    chmod 600 "$PY"
    trap 'rm -f "$PY"' EXIT
    {
        printf 'import sys\n'
        printf 'try:\n'
        printf '    nmConnect(userConfigFile=sys.argv[1], userKeyFile=sys.argv[2], host=sys.argv[3], port=sys.argv[4], domainName=sys.argv[5], domainDir=sys.argv[6], nmType=sys.argv[7])\n'
        printf 'except Exception, e:\n'
        printf '    print("NMSTAT|CONNECT|" + str(e).split("\\n")[0])\n'
        printf '    exit(exitcode=1)\n'
        printf 'for a in sys.argv[8:]:\n'
        printf '    n, t = a.split(":")\n'
        printf '    try:\n'
        printf '        if t == "Server":\n'
        printf '            s = nmServerStatus(n)\n'
        printf '        else:\n'
        printf '            s = nmServerStatus(serverName=n, serverType=t)\n'
        printf '    except Exception, e:\n'
        printf '        s = "UNKNOWN"\n'
        printf '    print("NMSTAT|" + n + "|" + str(s))\n'
        printf 'nmDisconnect()\n'
    } > "$PY"
    args=()
    for c in "${COMPS[@]}"; do
        IFS='|' read -r name typ port <<< "$c"
        case "$typ" in
            WLS)     args+=("${name}:Server") ;;
            REPORTS) args+=("${name}:ReportsServerComponent") ;;
        esac
    done
    printf "  Node Manager: Zugangsdaten %s\n" "$NM_KEY_CFG"
    out="$("$ORACLE_HOME/oracle_common/common/bin/wlst.sh" "$PY" \
            "$NM_KEY_CFG" "$NM_KEY_KEY" "$NM_HOST" "$WLS_NODEMANAGER_PORT" \
            "$DOMAIN_NAME" "$DOMAIN_HOME" "$NM_TYPE" "${args[@]}" 2>&1)"
    if printf '%s\n' "$out" | grep -q '^NMSTAT|CONNECT|'; then
        printf "  Node Manager: Anmeldung fehlgeschlagen:\n    %s\n" \
            "$(printf '%s\n' "$out" | sed -n 's/^NMSTAT|CONNECT|//p')"
        _nm_keys_hint
        _err
    else
        while IFS='|' read -r tag name st; do
            [ "$tag" = "NMSTAT" ] || continue
            printf "  NM   %-16s %s\n" "$name" "$st"
            R_NM[$name]="$st"
        done <<< "$out"
    fi
fi

# =============================================================================
# Zusammenfassung
# =============================================================================
printf "\n--- Zusammenfassung --------------------------------------------------------\n"
printf "  %-16s %-8s %-8s %-8s %-10s %s\n" "Komponente" "Port" "Prozess" "HTTP" "NodeMgr" "Ergebnis"
for c in "${COMPS[@]}"; do
    IFS='|' read -r name typ port <<< "$c"
    p="${R_PORT[$name]:--}"; pr="${R_PROC[$name]:--}"; h="${R_HTTP[$name]:--}"; nm="${R_NM[$name]:--}"
    res="OK"
    if [ "$pr" = "FEHLT" ] || [ "$p" = "FEHLT" ] || [ "$h" = "FEHLT" ]; then
        res="FEHLER"; _err
    elif [ "$h" = "503" ] || { [ "$nm" != "-" ] && [ "$nm" != "RUNNING" ]; }; then
        res="WARNUNG"; _warn
    fi
    printf "  %-16s %-8s %-8s %-8s %-10s %s\n" "$name" "$p" "$pr" "$h" "$nm" "$res"
done

case "$RC" in
    0) printf "\nErgebnis: alles in Ordnung\n" ;;
    1) printf "\nErgebnis: WARNUNG - Details oben\n" ;;
    *) printf "\nErgebnis: FEHLER - Details oben (Logs: show_errors.sh -r)\n" ;;
esac
exit "$RC"
