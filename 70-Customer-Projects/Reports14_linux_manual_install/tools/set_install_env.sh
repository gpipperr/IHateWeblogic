#!/bin/bash
# =============================================================================
# set_install_env.sh - alle Installations-Parameter aus install.ini in die
#                      aktuelle Sitzung laden (fuer die Kochbuch-Befehle)
#
# Aufruf : . /u01/oracle/tools/set_install_env.sh
#          (mit Punkt bzw. "source" - sonst gelten die Werte nur im Skript)
# Danach : echo $DOMAIN_HOME  ...  alle Werte stehen als Umgebungsvariablen
#          bereit; Kontrolle mit: set_install_env_show
# Beschreibung: Tools_status_logs_kochbuch.txt
# =============================================================================

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    printf "Bitte mit Punkt aufrufen:  . %s\n" "$0" >&2
    exit 1
fi

_tools_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$_tools_dir/install.ini" ]; then
    printf "FEHLER: %s/install.ini nicht gefunden\n" "$_tools_dir" >&2
    unset _tools_dir
    return 1
fi

# set -a: jede gesetzte Variable wird automatisch exportiert
set -a
# shellcheck source=/dev/null
. "$_tools_dir/install.ini"
set +a

# Kontrolle: alle Werte aus install.ini anzeigen
set_install_env_show() {
    local n
    for n in $(sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' "$_IHW_INSTALL_INI"); do
        printf "  %-28s %s\n" "$n" "${!n}"
    done
}
_IHW_INSTALL_INI="$_tools_dir/install.ini"

printf "Installations-Umgebung geladen aus %s/install.ini (Kontrolle: set_install_env_show)\n" "$_tools_dir"
unset _tools_dir
