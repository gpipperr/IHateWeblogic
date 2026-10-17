#!/bin/bash
# =============================================================================
# show_all_logs.sh - alle aktuellen Logs der Domain live mitlesen (tail -F)
#
# Aufruf : ./show_all_logs.sh            Logs der letzten LOG_MINUTES Minuten
#          ./show_all_logs.sh -m 240     Logs der letzten 240 Minuten
#          ./show_all_logs.sh -n 50      je Datei die letzten 50 Zeilen zuerst
#          ./show_all_logs.sh -h         Hilfe
# Beenden: Strg+C
# Daten  : env.ini im selben Verzeichnis (oder ENV_INI=/pfad/env.ini)
# Hinweis: Logdateien, die erst NACH dem Aufruf neu entstehen, sind nicht
#          dabei (tail -F folgt nur Dateien, die beim Start da waren, auch
#          ueber eine Rotation hinweg) - dann einfach neu aufrufen.
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

MINUTES="${LOG_MINUTES:-60}"
LINES=20
while getopts "m:n:h" opt; do
    case "$opt" in
        m) MINUTES="$OPTARG" ;;
        n) LINES="$OPTARG" ;;
        h) sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) exit 2 ;;
    esac
done

# Alle Logs der Domain: Server (WebLogic, Reports), Node Manager, EM
FILES=()
while IFS= read -r -d '' f; do
    FILES+=("$f")
done < <(find "$DOMAIN_HOME/servers" "$DOMAIN_HOME/nodemanager" "$DOMAIN_HOME/sysman/log" \
             -type f \( -name "*.log" -o -name "*.out" -o -name "*.trc" \) \
             ! -name "access.log*" ! -name "*.lck" -mmin -"$MINUTES" -print0 2>/dev/null)

if [ ${#FILES[@]} -eq 0 ]; then
    printf "Keine Logdatei in den letzten %s Minuten geschrieben (%s).\n" "$MINUTES" "$DOMAIN_HOME"
    printf "Laengeren Zeitraum waehlen, z.B.: %s -m 1440\n" "$0"
    exit 1
fi

printf "%d Logdateien (geschrieben in den letzten %s Minuten):\n" "${#FILES[@]}" "$MINUTES"
printf "  %s\n" "${FILES[@]#$DOMAIN_HOME/}"
printf "\nLive-Ausgabe, je Datei zuerst die letzten %s Zeilen - beenden mit Strg+C\n\n" "$LINES"

exec tail -F -n "$LINES" "${FILES[@]}"
