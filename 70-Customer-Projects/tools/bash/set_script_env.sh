#!/bin/bash
# =============================================================================
# set_script_env.sh - alle Werte der Kundenumgebung aus patch_install.ini in
#                     die aktuelle Sitzung laden (fuer die Kochbuch-Befehle:
#                     Installation, Patch, Absicherung, Betrieb)
#
# Aufruf : . $ORACLE_BASE/tools/set_script_env.sh
#          (mit Punkt bzw. "source" - sonst gelten die Werte nur im Skript)
#          IHW_INI=/pfad/datei.ini . set_script_env.sh   andere ini-Datei
# Danach : echo $DOMAIN_HOME  ...  alle Werte stehen als Umgebungsvariablen
#          bereit; Kontrolle mit: set_script_env_show
# Ablage : neben patch_install.ini in $ORACLE_BASE/tools
#          (Fahrplan: 70-Customer-Projects/Start_beim_Kunden_kochbuch_de.txt)
# Die Shell-Umgebung (PATH, wlst, Home-Wechsel) setzt setdb
# (ihw_shell_env.sh) - dieses Skript laedt nur die Werte der ini.
#
# Author : Gunther Pipperr | https://pipperr.de
# License: Apache 2.0
# =============================================================================

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    printf "Bitte mit Punkt aufrufen:  . %s\n" "$0" >&2
    exit 1
fi

_tools_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_IHW_SCRIPT_INI="${IHW_INI:-$_tools_dir/patch_install.ini}"
unset _tools_dir
if [ ! -f "$_IHW_SCRIPT_INI" ]; then
    printf "FEHLER: %s nicht gefunden\n" "$_IHW_SCRIPT_INI" >&2
    return 1
fi

# mit setdb gewaehlte Domain merken: die ini ueberschreibt DOMAIN_HOME
_ihw_setdb_dh=""
case "${IHW_ENV_KEY:-}" in "FMW "*" -") ;; "FMW "*) _ihw_setdb_dh="${DOMAIN_HOME:-}" ;; esac

# set -a: jede gesetzte Variable wird automatisch exportiert
set -a
# shellcheck source=/dev/null
. "$_IHW_SCRIPT_INI"
set +a

if [ -n "$_ihw_setdb_dh" ] && [ "$(readlink -f "$_ihw_setdb_dh")" != "$(readlink -f "${DOMAIN_HOME:-/}")" ]; then
    printf "WARNUNG: setdb hatte Domain %s gewaehlt, %s setzt jetzt %s\n" "$_ihw_setdb_dh" "$_IHW_SCRIPT_INI" "$DOMAIN_HOME" >&2
fi
unset _ihw_setdb_dh

# Kontrolle: alle Werte aus der ini anzeigen
set_script_env_show() {
    local n
    for n in $(sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' "$_IHW_SCRIPT_INI"); do
        printf "  %-28s %s\n" "$n" "${!n}"
    done
}

printf "Umgebung geladen aus %s (Kontrolle: set_script_env_show)\n" "$_IHW_SCRIPT_INI"
