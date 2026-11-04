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
#          ./status.sh -h       Hilfe
# Daten  : env.ini im selben Verzeichnis (oder ENV_INI=/pfad/env.ini)
# Exit   : 0 = alles in Ordnung, 1 = Warnung, 2 = Fehler
# Ohne Abhaengigkeit zu weiteren Skripten - nur bash, ss, ps, curl, wlst.sh.
# Beschreibung: Tools_status_logs_kochbuch.txt
# =============================================================================

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_INI="${ENV_INI:-$TOOLS_DIR/env.ini}"
if [ ! -f "$ENV_INI" ]; then
    printf "FEHLER: %s nicht gefunden\n" "$ENV_INI" >&2
    exit 2
fi
# shellcheck source=/dev/null
. "$ENV_INI"

QUICK=false
case "${1:-}" in
    -q|--quick) QUICK=true ;;
    -h|--help)
        sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    "") ;;
    *) printf "Unbekannte Option: %s (Hilfe: -h)\n" "$1" >&2; exit 2 ;;
esac

RC=0
_warn() { [ "$RC" -lt 1 ] && RC=1; }
_err()  { RC=2; }

# Ergebnisse je Komponente fuer die Zusammenfassung
declare -A R_PORT R_PROC R_HTTP R_NM
COMPS=()

# Server-Liste aufbauen: Name|Typ|Port
COMPS+=("NodeManager|NM|${NM_PORT}")
COMPS+=("${ADMIN_SERVER}|WLS|${ADMIN_PORT}")
for _m in $MANAGED_SERVERS; do
    COMPS+=("${_m%%:*}|WLS|${_m##*:}")
done
for _r in $REPORTS_SERVERS; do
    COMPS+=("${_r}|REPORTS|-")
done

printf "\n=== Status %s  (%s, %s) ===\n" "$DOMAIN_NAME" "$(hostname -s)" "$(date '+%Y-%m-%d %H:%M:%S')"

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
elif [ ! -r "$WLST_CONFIG_FILE" ] || [ ! -r "$WLST_KEY_FILE" ]; then
    printf "  Node Manager: keine gespeicherten Zugangsdaten gefunden\n"
    printf "    %s\n    %s\n" "$WLST_CONFIG_FILE" "$WLST_KEY_FILE"
    printf "    -> einmalig anlegen: \$DOMAIN_HOME/bin/startComponent.sh <ReportsServer> storeUserConfig\n"
    printf "       (Autostart_linux_middleware.txt Schritt 1c)\n"
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
    out="$("$ORACLE_HOME/oracle_common/common/bin/wlst.sh" "$PY" \
            "$WLST_CONFIG_FILE" "$WLST_KEY_FILE" "$NM_HOST" "$NM_PORT" \
            "$DOMAIN_NAME" "$DOMAIN_HOME" "$NM_TYPE" "${args[@]}" 2>&1)"
    if printf '%s\n' "$out" | grep -q '^NMSTAT|CONNECT|'; then
        printf "  Node Manager: Anmeldung fehlgeschlagen:\n    %s\n" \
            "$(printf '%s\n' "$out" | sed -n 's/^NMSTAT|CONNECT|//p')"
        printf "    -> Zugangsdaten neu speichern (Autostart_linux_middleware.txt Schritt 1b/1c)\n"
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
