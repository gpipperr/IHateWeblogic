#!/bin/bash
# =============================================================================
# set_env.sh - Betriebs-Umgebung aus env.ini in die aktuelle Sitzung laden:
#              Variablen (DOMAIN_HOME, ORACLE_HOME ...), PATH mit den Tools,
#              Kurzbefehle "wlst" und "domain"
#
# Aufruf : . /u01/oracle/tools/set_env.sh
#          (mit Punkt bzw. "source" - sonst gelten die Werte nur im Skript)
# Dauerhaft fuer den oracle-Benutzer - einmalig in ~/.bash_profile:
#          [ -f /u01/oracle/tools/set_env.sh ] && . /u01/oracle/tools/set_env.sh
# Beschreibung: Tools_status_logs_kochbuch.txt
# =============================================================================

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    printf "Bitte mit Punkt aufrufen:  . %s\n" "$0" >&2
    exit 1
fi

_tools_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$_tools_dir/env.ini" ]; then
    printf "FEHLER: %s/env.ini nicht gefunden\n" "$_tools_dir" >&2
    unset _tools_dir
    return 1
fi

# set -a: jede gesetzte Variable wird automatisch exportiert
set -a
# shellcheck source=/dev/null
. "$_tools_dir/env.ini"
set +a
unset _tools_dir

# Nur in interaktiven Sitzungen eine kurze Zeile ausgeben (nicht bei scp/sftp)
case "$-" in
    *i*) printf "Umgebung %s geladen - Befehle: status.sh, show_log.sh, show_errors.sh, show_all_logs.sh, wlst, domain\n" \
             "${DOMAIN_NAME:-?}" ;;
esac
