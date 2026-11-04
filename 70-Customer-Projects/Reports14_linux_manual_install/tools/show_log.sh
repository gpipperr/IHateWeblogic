#!/bin/bash
# =============================================================================
# show_log.sh - das aktuelle Log EINER Komponente oeffnen
#
# Aufruf : show_log.sh                     Auswahl-Menue (Komponente, dann Log)
#          show_log.sh nodemanager         Node-Manager-Log
#          show_log.sh adminserver         Auswahl der Logs des AdminServers
#          show_log.sh AdminServer out     direkt das .out des AdminServers
#          show_log.sh reports             Reports-Server (der erste aus env.ini)
#          show_log.sh -l ...              in "less" oeffnen statt live (tail -F)
#          show_log.sh -n 200 ...          mit den letzten 200 Zeilen beginnen
# Log    : log | out | diag | rwservlet | engine  (nur was es gibt)
# Beenden: Strg+C   (in less: Strg+C, dann q)
# Daten  : env.ini im selben Verzeichnis (oder ENV_INI=/pfad/env.ini)
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

USE_LESS=false
LINES=50
while getopts "ln:h" opt; do
    case "$opt" in
        l) USE_LESS=true ;;
        n) LINES="$OPTARG" ;;
        h) sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))
WANT_COMP="${1:-}"
WANT_LOG="${2:-}"

# --- Komponenten aus env.ini: Anzeigename|Typ -----------------------------------
COMPS=("NodeManager|NM" "${ADMIN_SERVER}|WLS")
for _m in $MANAGED_SERVERS; do COMPS+=("${_m%%:*}|WLS"); done
for _r in $REPORTS_SERVERS; do COMPS+=("${_r}|REPORTS"); done

# _logs <name> <typ> - vorhandene Logs der Komponente als "kurz|Beschreibung|Datei"
_logs() {
    local n="$1" t="$2" d f
    case "$t" in
        NM)
            f="$DOMAIN_HOME/nodemanager/nodemanager.log"
            [ -f "$f" ] && printf '%s|%s|%s\n' log "Node-Manager-Log" "$f" ;;
        WLS)
            d="$DOMAIN_HOME/servers/$n/logs"
            [ -f "$d/$n.log" ]            && printf '%s|%s|%s\n' log  "Server-Log (WebLogic-Meldungen)" "$d/$n.log"
            [ -f "$d/$n.out" ]            && printf '%s|%s|%s\n' out  "Konsolen-Ausgabe (Start, stdout/stderr)" "$d/$n.out"
            [ -f "$d/$n-diagnostic.log" ] && printf '%s|%s|%s\n' diag "Diagnose-Log (FMW: Sicherheit, Reports, JRF)" "$d/$n-diagnostic.log"
            [ -f "$d/reports/rwservlet_diagnostic.log" ] && \
                printf '%s|%s|%s\n' rwservlet "rwservlet-Log (Reports-Aufrufe)" "$d/reports/rwservlet_diagnostic.log" ;;
        REPORTS)
            d="$DOMAIN_HOME/servers/$n/logs"
            [ -f "$d/rwserver_diagnostic.log" ] && printf '%s|%s|%s\n' log "Reports-Server-Log" "$d/rwserver_diagnostic.log"
            [ -f "$d/$n.out" ] && printf '%s|%s|%s\n' out "Konsolen-Ausgabe (Start, stdout/stderr)" "$d/$n.out"
            f="$(ls -t "$d"/rwEng-*_diagnostic.log 2>/dev/null | head -1)"
            [ -n "$f" ] && printf '%s|%s|%s\n' engine "Engine-Log (zuletzt geschrieben: $(basename "$f"))" "$f" ;;
    esac
}

# --- Komponente bestimmen -----------------------------------------------------------
SEL_NAME="" SEL_TYPE=""
if [ -n "$WANT_COMP" ]; then
    w="${WANT_COMP,,}"
    for c in "${COMPS[@]}"; do
        IFS='|' read -r n t <<< "$c"
        if [ "${n,,}" = "$w" ] || { [ "$w" = "reports" ] && [ "$t" = "REPORTS" ]; } \
           || { [ "$w" = "nm" ] && [ "$t" = "NM" ]; }; then
            SEL_NAME="$n"; SEL_TYPE="$t"; break
        fi
    done
    if [ -z "$SEL_NAME" ]; then
        printf "Unbekannte Komponente: %s\nVorhanden:" "$WANT_COMP" >&2
        for c in "${COMPS[@]}"; do printf " %s" "${c%%|*}" >&2; done
        printf "\n" >&2
        exit 2
    fi
else
    printf "Welche Komponente?\n"
    PS3="Nummer: "
    names=(); for c in "${COMPS[@]}"; do names+=("${c%%|*}"); done
    select n in "${names[@]}"; do
        [ -n "$n" ] || { printf "Bitte eine Nummer aus der Liste.\n"; continue; }
        for c in "${COMPS[@]}"; do
            [ "${c%%|*}" = "$n" ] && { SEL_NAME="$n"; SEL_TYPE="${c##*|}"; }
        done
        break
    done
    [ -n "$SEL_NAME" ] || exit 1
fi

# --- Log bestimmen ------------------------------------------------------------------
mapfile -t LOGS < <(_logs "$SEL_NAME" "$SEL_TYPE")
if [ ${#LOGS[@]} -eq 0 ]; then
    printf "Fuer %s wurde keine Logdatei gefunden (DOMAIN_HOME=%s).\n" "$SEL_NAME" "$DOMAIN_HOME" >&2
    exit 1
fi

FILE=""
if [ -n "$WANT_LOG" ]; then
    for l in "${LOGS[@]}"; do
        [ "${l%%|*}" = "${WANT_LOG,,}" ] && FILE="${l##*|}"
    done
    if [ -z "$FILE" ]; then
        printf "Log '%s' gibt es fuer %s nicht. Vorhanden:" "$WANT_LOG" "$SEL_NAME" >&2
        for l in "${LOGS[@]}"; do printf " %s" "${l%%|*}" >&2; done
        printf "\n" >&2
        exit 2
    fi
elif [ ${#LOGS[@]} -eq 1 ]; then
    FILE="${LOGS[0]##*|}"
else
    printf "\nWelches Log von %s?\n" "$SEL_NAME"
    labels=()
    for l in "${LOGS[@]}"; do
        IFS='|' read -r k desc f <<< "$l"
        labels+=("$(printf '%-9s %s' "$k" "$desc")")
    done
    PS3="Nummer: "
    select x in "${labels[@]}"; do
        [ -n "$x" ] || { printf "Bitte eine Nummer aus der Liste.\n"; continue; }
        FILE="${LOGS[$((REPLY - 1))]##*|}"
        break
    done
    [ -n "$FILE" ] || exit 1
fi

printf "\n==> %s  (%s, geaendert %s)\n" "$FILE" "$(du -h "$FILE" | cut -f1)" \
    "$(date -r "$FILE" '+%Y-%m-%d %H:%M:%S')"
if $USE_LESS; then
    printf "    less: Ende = G, Suchen = /text, live mitlesen = F, beenden = q\n\n"
    exec less +G "$FILE"
fi
printf "    live, die letzten %s Zeilen zuerst - beenden mit Strg+C\n\n" "$LINES"
exec tail -F -n "$LINES" "$FILE"
