#!/bin/bash
# =============================================================================
# show_errors.sh - nur Fehlerzeilen aus allen aktuellen Logs der Domain
#
# Aufruf : ./show_errors.sh            ab jetzt neue Fehler live anzeigen
#          ./show_errors.sh -r         erst die letzten Fehler der letzten
#                                      LOG_MINUTES Minuten, dann live weiter
#          ./show_errors.sh -r -m 240  ... der letzten 240 Minuten
#          ./show_errors.sh -h         Hilfe
# Beenden: Strg+C
# Daten  : env.ini im selben Verzeichnis (oder ENV_INI=/pfad/env.ini)
# Muster : PATTERN unten - bei Bedarf anpassen. "==>" sind die Dateinamen-
#          Zeilen von tail, damit man sieht, aus welchem Log ein Fehler kommt.
# Beschreibung: Tools_status_logs_kochbuch.txt
# =============================================================================

PATTERN='<Error>|<Critical>|ERROR|SEVERE|Exception|REP-[0-9]+|JPS-[0-9]+|BEA-[0-9]+'

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_INI="${ENV_INI:-$TOOLS_DIR/env.ini}"
if [ ! -f "$ENV_INI" ]; then
    printf "FEHLER: %s nicht gefunden\n" "$ENV_INI" >&2
    exit 2
fi
# shellcheck source=/dev/null
. "$ENV_INI"

MINUTES="${LOG_MINUTES:-60}"
REVIEW=false
while getopts "rm:h" opt; do
    case "$opt" in
        r) REVIEW=true ;;
        m) MINUTES="$OPTARG" ;;
        h) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) exit 2 ;;
    esac
done

FILES=()
while IFS= read -r -d '' f; do
    FILES+=("$f")
done < <(find "$DOMAIN_HOME/servers" "$DOMAIN_HOME/nodemanager" "$DOMAIN_HOME/sysman/log" \
             -type f \( -name "*.log" -o -name "*.out" -o -name "*.trc" \) \
             ! -name "access.log*" ! -name "*.lck" -mmin -"$MINUTES" -print0 2>/dev/null)

if [ ${#FILES[@]} -eq 0 ]; then
    printf "Keine Logdatei in den letzten %s Minuten geschrieben (%s).\n" "$MINUTES" "$DOMAIN_HOME"
    printf "Laengeren Zeitraum waehlen, z.B.: %s -r -m 1440\n" "$0"
    exit 1
fi

printf "%d Logdateien werden ueberwacht (geschrieben in den letzten %s Minuten).\n" "${#FILES[@]}" "$MINUTES"

if $REVIEW; then
    printf "\n=== Letzte Fehler (max. 50) ===\n"
    grep -H -E "$PATTERN" "${FILES[@]}" 2>/dev/null \
        | sed "s#^$DOMAIN_HOME/##" | tail -50
    printf "\n=== Ab jetzt live (Strg+C beendet) ===\n"
else
    printf "Neue Fehler werden live angezeigt (Strg+C beendet) - alte Fehler: %s -r\n\n" "$0"
fi

# tail schreibt vor neuen Zeilen "==> datei <==" - die Kopfzeile nur zeigen,
# wenn darunter wirklich ein Fehler kommt. Bei Strg+C / Abbruch die
# Kindprozesse (tail, awk) mit beenden.
trap 'pkill -P $$ 2>/dev/null; exit 0' INT TERM
tail -F -n 0 "${FILES[@]}" 2>/dev/null \
    | awk -v pat="$PATTERN" '
        /^==> .* <==$/ { head = $0; next }
        $0 ~ pat       { if (head != "") { print ""; print head; head = "" }
                         print; fflush() }' &
wait
