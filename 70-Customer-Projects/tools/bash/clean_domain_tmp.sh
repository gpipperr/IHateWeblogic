#!/bin/bash
# =============================================================================
# clean_domain_tmp.sh - temporaere Dateien der Domain loeschen, WebLogic baut sie
#                       beim naechsten Start neu auf (z.B. nach einem Patch oder
#                       dem Tausch des FMW Homes)
#
# Aufruf : clean_domain_tmp.sh            zeigt, was geloescht wuerde (aendert nichts)
#          clean_domain_tmp.sh --apply    loescht - nur wenn nichts mehr laeuft
#          clean_domain_tmp.sh -h         Hilfe
# Domain : die mit setdb gewaehlte Domain, sonst patch_install.ini / Login-Umgebung
# Loescht: den Inhalt von servers/<server>/tmp und servers/<server>/cache
#          (die Verzeichnisse selbst bleiben)
# Bleibt : servers/<server>/data (Embedded LDAP, Stores), security, logs, adr,
#          stage (dort liegen ggf. Anwendungen), reports/cache (Job-Ergebnisse),
#          config/ - nicht neu aufbaubar oder Benutzerdaten
# Sperre : --apply bricht ab, solange ein Server, Node Manager, Forms- oder
#          Reports-Prozess dieser Domain oder dieses Homes auf diesem Host laeuft
# Danach : der erste Start dauert laenger, die Anwendungen werden neu ausgepackt
# Exit   : 0 = in Ordnung, 1 = Prozesse laufen, 2 = Fehler
# =============================================================================

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./ihw_tools_lib.sh
. "$TOOLS_DIR/ihw_tools_lib.sh" || { printf "FEHLER: ihw_tools_lib.sh fehlt neben %s\n" "$0" >&2; exit 2; }

APPLY=false
case "${1:-}" in
    --apply) APPLY=true ;;
    -h|--help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") ;;
    *) printf "Unbekannte Option: %s (Hilfe: -h)\n" "$1" >&2; exit 2 ;;
esac

ihwt_ops_env "$TOOLS_DIR" || exit 2
DOMAIN_HOME="${DOMAIN_HOME%/}"
ORACLE_HOME="${ORACLE_HOME%/}"

# Der Eigentuemer loescht: root wuerde keine Rechte-Fehler melden, ein anderer
# Benutzer sieht das Arbeitsverzeichnis fremder Prozesse nicht
_owner="$(stat -c %U "$DOMAIN_HOME/config/config.xml" 2>/dev/null)"
if [ "$(id -un)" != "$_owner" ]; then
    printf "FEHLER: bitte als Eigentuemer der Domain aufrufen (%s), nicht als %s\n" "$_owner" "$(id -un)" >&2
    exit 2
fi

# --- laufende Prozesse -----------------------------------------------------------
# Nur Programme von WebLogic, Forms und Reports zaehlen: eine Shell, die in der
# Domain steht, oder ein "tail -f" auf ein Log sperrt nicht. frmweb nennt die Domain
# nirgends (Arbeitsverzeichnis im Home), deshalb zaehlt auch ein Start aus dem Home.
_running() {
    local d p comm cmd cwd exe
    for d in /proc/[0-9]*; do
        p="${d#/proc/}"
        [ "$p" = "$$" ] && continue
        comm="$(cat "$d/comm" 2>/dev/null)" || continue
        case "$comm" in
            java|frmweb|frmcmp*|frmbld*|rwserver|rwrun*|rwbuilder*|rwclient*|rwconverter*|rwEng*) ;;
            *) continue ;;
        esac
        cmd="$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)"
        cwd="$(readlink "$d/cwd" 2>/dev/null)"
        exe="$(readlink "$d/exe" 2>/dev/null)"
        case " $cmd " in
            *"$DOMAIN_HOME/"*|*"=$DOMAIN_HOME "*|*" $DOMAIN_HOME "*) ;;
            *)  case "$cwd/" in
                    "$DOMAIN_HOME"/*) ;;
                    *)  [ -n "${ORACLE_HOME:-}" ] || continue
                        case "$exe $cmd" in
                            "$ORACLE_HOME"/*|*" $ORACLE_HOME/"*|*":$ORACLE_HOME/"*|*"=$ORACLE_HOME/"*) ;;
                            *) continue ;;
                        esac ;;
                esac ;;
        esac
        printf "  %8s  %-10s %s\n" "$p" "$comm" "$(printf '%s' "$cmd" | cut -c1-90)"
    done
}

# --- was wird geloescht ----------------------------------------------------------
TARGETS=()
TOTAL_KB=0
printf "\nDomain %s  (%s, Quelle: %s)\n\n" "${DOMAIN_NAME:-?}" "$DOMAIN_HOME" "${IHWT_OPS_SRC:-?}"
printf "  %-44s %10s\n" "Verzeichnis" "Groesse"
for _srv in "$DOMAIN_HOME"/servers/*/; do
    _srv="${_srv%/}"
    [ -L "$_srv" ] && continue
    for _sub in tmp cache; do
        _dir="$_srv/$_sub"
        if [ -L "$_dir" ]; then
            printf "  %-44s %10s\n" "servers/$(basename "$_srv")/$_sub" "Link - bleibt"
            continue
        fi
        [ -d "$_dir" ] || continue
        _kb="$(du -sk "$_dir" 2>/dev/null | awk '{print $1}')"
        TARGETS+=("$_dir")
        TOTAL_KB=$((TOTAL_KB + ${_kb:-0}))
        printf "  %-44s %7s MB\n" "servers/$(basename "$_srv")/$_sub" "$(( (${_kb:-0} + 512) / 1024 ))"
    done
done
if [ ${#TARGETS[@]} -eq 0 ]; then
    printf "\nKeine tmp- oder cache-Verzeichnisse gefunden - nichts zu tun.\n"
    exit 0
fi
printf "  %-44s %7s MB\n" "Summe" "$(( (TOTAL_KB + 512) / 1024 ))"
printf "\nBleibt erhalten: servers/*/data (LDAP, Stores), security, logs, adr, stage,\n"
printf "                 reports/cache (Job-Ergebnisse), config/\n"
_stage="$(ls -d "$DOMAIN_HOME"/servers/*/stage 2>/dev/null | wc -l)"
[ "$_stage" -gt 0 ] && printf "Hinweis: %s stage-Verzeichnis(se) vorhanden - Kopien von Deployments, nach einem Patch von Hand pruefen.\n" "$_stage"

RUN="$(_running)"
if [ -n "$RUN" ]; then
    printf "\nEs laufen noch Prozesse dieser Domain oder dieses Homes:\n%s\n" "$RUN"
    printf "Erst alles stoppen (Server, Node Manager, Reports-Komponenten), dann erneut aufrufen.\n"
    $APPLY && printf "Nichts geloescht.\n"
    exit 1
fi
printf "\nKeine Prozesse dieser Domain auf diesem Host (Server auf anderen Hosts sieht das Tool nicht).\n"

if ! $APPLY; then
    printf "Nichts geloescht. Loeschen mit: %s --apply\n" "$(basename "$0")"
    exit 0
fi

# --- loeschen: nur der Inhalt, rm folgt keinen Links -------------------------------
RC=0
for _dir in "${TARGETS[@]}"; do
    find "$_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null
    _left="$(find "$_dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
    if [ "$_left" -gt 0 ]; then
        printf "FEHLER: %s - %s Eintraege nicht geloescht\n" "$_dir" "$_left" >&2
        RC=2
    fi
done
if [ "$RC" -ne 0 ]; then
    printf "\nNicht alles geloescht (siehe oben) - Rechte pruefen, dann erneut aufrufen.\n" >&2
    exit "$RC"
fi
printf "\nOK: %s MB geloescht. Der erste Start dauert laenger, die Anwendungen werden neu ausgepackt.\n" "$(( (TOTAL_KB + 512) / 1024 ))"
exit 0
