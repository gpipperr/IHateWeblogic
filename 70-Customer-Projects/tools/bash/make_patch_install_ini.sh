#!/bin/bash
# =============================================================================
# make_patch_install_ini.sh - patch_install.ini aus der vorhandenen Domain
#                             erzeugen (fuer die Kochbuecher)
#
# Aufruf : make_patch_install_ini.sh            zeigt die Werte mit Quelle (schreibt nichts)
#          make_patch_install_ini.sh --apply    schreibt patch_install.ini (Rechte 600)
#          make_patch_install_ini.sh -h         Hilfe
# Domain : die mit setdb gewaehlte Domain, sonst DOMAIN_HOME der Login-Umgebung
# Ziel   : patch_install.ini neben diesem Skript (oder IHW_INI=/pfad/datei.ini);
#          eine vorhandene Datei wird NIE ueberschrieben
# Inhalt : nur abgeleitete Werte, keine Kennwoerter und keine Beispielwerte. Was
#          sich nicht sicher ableiten laesst, bleibt auskommentiert ("ANPASSEN").
#          MANAGED_SERVERS / REPORTS_SERVERS bleiben Kommentar: status.sh und
#          show_log.sh lesen sie live aus der Domain (bleibt nach dem Entfernen
#          eines Servers richtig).
# Die Betriebs-Tools brauchen die ini nicht - nur die Kochbuecher.
# Exit   : 0 = in Ordnung, 2 = Fehler
# =============================================================================

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./ihw_tools_lib.sh
. "$TOOLS_DIR/ihw_tools_lib.sh" || { printf "FEHLER: ihw_tools_lib.sh fehlt neben %s\n" "$0" >&2; exit 2; }

APPLY=false
case "${1:-}" in
    --apply) APPLY=true ;;
    -h|--help) sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") ;;
    *) printf "Unbekannte Option: %s (Hilfe: -h)\n" "$1" >&2; exit 2 ;;
esac

TARGET="${IHW_INI:-$TOOLS_DIR/patch_install.ini}"

# --- Domain: setdb oder Login, nie eine alte ini -------------------------------
case "${IHW_ENV_KEY:-}" in
    "FMW "*" -"|"DB "*)
        printf "FEHLER: setdb steht auf \"home only\" / DB - bitte einen Domain-Eintrag waehlen\n" >&2
        exit 2 ;;
esac
if [ -z "${DOMAIN_HOME:-}" ] || [ ! -f "$DOMAIN_HOME/config/config.xml" ]; then
    printf "FEHLER: keine Domain bekannt (DOMAIN_HOME=%s) - setdb, Domain-Eintrag waehlen\n" "${DOMAIN_HOME:-}" >&2
    exit 2
fi
unset DOMAIN_NAME ADMIN_SERVER MANAGED_SERVERS REPORTS_SERVERS WLS_ADMIN_PORT \
      WLS_NODEMANAGER_PORT NM_HOST NM_TYPE
ihwt_ops_from_domain
if [ -z "${ORACLE_HOME:-}" ] || [ ! -d "$ORACLE_HOME" ]; then
    printf "FEHLER: ORACLE_HOME unbekannt - setdb, Domain-Eintrag waehlen\n" >&2
    exit 2
fi
CFG="$DOMAIN_HOME/config/fmwconfig"

# --- Ableitungen ----------------------------------------------------------------
# ORACLE_BASE: Umgebung; sonst ueber dem Tools-Verzeichnis, wenn der Home darunter
# liegt; sonst .../product/<ver>/<home> -> ...; sonst das Verzeichnis ueber dem Home
BASE_SRC="pruefen"
if [ -n "${ORACLE_BASE:-}" ]; then
    BASE="$ORACLE_BASE"; BASE_SRC="Umgebung"
else
    _tp="$(dirname "$TOOLS_DIR")"
    case "$ORACLE_HOME/" in
        "$_tp"/*) BASE="$_tp" ;;
        */product/*/*) BASE="${ORACLE_HOME%%/product/*}" ;;
        *) BASE="$(dirname "$ORACLE_HOME")" ;;
    esac
fi

JDK="${JDK_HOME:-}"
[ -n "$JDK" ] || JDK="$(sed -n 's/^JAVA_HOME=//p' "$ORACLE_HOME/oui/.globalEnv.properties" 2>/dev/null | head -1)"
[ -n "$JDK" ] || JDK="$ORACLE_HOME/oracle_common/jdk"

# Reports-Managed-Server: Name mit "report", sonst leer (Forms-only)
MS_REP=""; MS_PORT=""
for _m in $MANAGED_SERVERS; do
    case "${_m,,}" in *report*) MS_REP="${_m%%:*}"; MS_PORT="${_m##*:}"; break ;; esac
done
APP_CONF="$(ls -d "$CFG/servers/${MS_REP:-none}"/applications/reports_*/configuration 2>/dev/null | tail -1)"

# Standard-Reports-Server: Server aus rwservlet.properties, sonst der erste
RS=""
[ -n "$APP_CONF" ] && RS="$(sed -n 's|.*<server>\([^<]*\)</server>.*|\1|p' "$APP_CONF/rwservlet.properties" 2>/dev/null | head -1)"
case " $REPORTS_SERVERS " in *" $RS "*) [ -n "$RS" ] || RS="${REPORTS_SERVERS%% *}" ;; *) RS="${REPORTS_SERVERS%% *}" ;; esac
# Instanz = Verzeichnis mit rwnetwork.conf / rwbuilder.conf (daneben liegt z.B. mbeans/)
TOOLS_INST=""
for _d in "$CFG"/components/ReportsToolsComponent/*/; do
    if [ -f "$_d/rwnetwork.conf" ] || [ -f "$_d/rwbuilder.conf" ]; then TOOLS_INST="$(basename "$_d")"; break; fi
done
RS_CONF=""; [ -n "$RS" ] && RS_CONF="$CFG/components/ReportsServerComponent/$RS/rwserver.conf"
_envvar() { sed -n "s|.*<envVariable name=\"$1\" value=\"\([^\"]*\)\".*|\1|p" "$RS_CONF" 2>/dev/null | head -1; }
BCAST=""; [ -n "$RS" ] && BCAST="$(sed -nE 's/.*<(multicast|cluster)[^>]*port="([0-9]*)".*/\2/p' "$CFG/components/ReportsServerComponent/$RS/rwnetwork.conf" 2>/dev/null | head -1)"
_read="$(sed -n 's|.*<read>\([^<]*\)</read>.*|\1|p' "$RS_CONF" 2>/dev/null | head -1)"
REP_PATH="$(printf '%s\n' "${_read//;/$'\n'}" | grep -vi image | head -1)"
REP_IMG="$(printf '%s\n' "${_read//;/$'\n'}" | grep -i image | head -1)"

# TNS_ADMIN: Umgebung (setdb aendert ihn nie), sonst die feste Zeile in reports.sh
TNS="${TNS_ADMIN:-}"
[ -n "$TNS" ] || TNS="$(sed -n 's|^TNS_ADMIN=\(/[^;[:space:]]*\).*|\1|p' "$DOMAIN_HOME/reports/bin/reports.sh" 2>/dev/null | tail -1)"

# RCU-Datenbank (wie export_forms_reports_conf.sh): //host:port/service oder DESCRIPTION
_jd="$DOMAIN_HOME/config/jdbc/opss-datasource-jdbc.xml"
_url="$(sed -n 's|.*<url>\([^<]*\)</url>.*|\1|p' "$_jd" 2>/dev/null | head -1)"
_hp="$(printf '%s' "$_url" | sed -n 's#.*@//\([^/]*\)/\(.*\)#\1;\2#p')"
[ -n "$_hp" ] || _hp="$(printf '%s' "$_url" | sed -n 's#.*HOST=\([^)]*\).*PORT=\([0-9]*\).*SERVICE_NAME=\([^)]*\).*#\1:\2;\3#p')"
DB_H=""; DB_P=""; DB_S=""
if [ -n "$_hp" ]; then
    DB_H="${_hp%%:*}"; DB_P="$(printf '%s' "${_hp%%;*}" | sed -n 's/.*:\([0-9]*\)$/\1/p')"; DB_S="${_hp#*;}"
fi
DB_PFX="$(sed -n 's|.*<value>\([A-Za-z0-9#$]*\)_OPSS</value>.*|\1|p' "$_jd" 2>/dev/null | head -1)"

# oeffentlicher Name: erster server_name der Nginx-Konfiguration (ohne "_"), sonst Host
FQDN_SRC="pruefen"
FQDN="$(sed -n 's/^[[:space:]]*server_name[[:space:]]\+\([^ ;]*\).*/\1/p' /etc/nginx/conf.d/oracle-wls.conf 2>/dev/null | grep -v '^_$' | head -1)"
if [ -n "$FQDN" ]; then FQDN_SRC="Nginx - pruefen"; else FQDN="$(hostname -f 2>/dev/null)"; fi

# --- Ausgabe: Zeilen "NAME|Wert|Quelle"; leerer Wert = auskommentiert -------------
LINES_OUT=()
_b() { LINES_OUT+=("#|$1|"); }                      # Block-Ueberschrift
_v() { LINES_OUT+=("$1|$2|$3"); }                   # NAME Wert Quelle
_c() { LINES_OUT+=("!$1|$2|$3"); }                  # bewusst Kommentar: NAME Wert Grund

_b "Grundverzeichnisse"
_v ORACLE_BASE "$BASE" "$BASE_SRC"
_v ORACLE_HOME "$ORACLE_HOME" "setdb"
_v JDK_HOME "$JDK" "setdb / oui"
_v JAVA_HOME "$JDK" "= JDK_HOME"
if [ -d "$BASE/patch_storage" ]; then _v PATCH_STORAGE "$BASE/patch_storage" "Verzeichnis vorhanden"; else _c PATCH_STORAGE "" "ANPASSEN: Verzeichnis der Patch-ZIPs"; fi
if [ -d "$BASE/install/media" ]; then _v MEDIA "$BASE/install/media" "Verzeichnis vorhanden"; else _c MEDIA "" "ANPASSEN: Upload-Verzeichnis der Installations-ZIPs"; fi
_c CV_ASSUME_DISTID "OEL8" "nur fuer den Installer auf Oracle Linux 9"
_v WLST "$ORACLE_HOME/oracle_common/common/bin/wlst.sh" "Oracle Home"

_b "Domain und Server"
_v DOMAIN_NAME "$DOMAIN_NAME" "config.xml"
_v DOMAIN_HOME "$DOMAIN_HOME" "setdb"
_v WLS_ADMIN_PORT "$WLS_ADMIN_PORT" "config.xml"
_v WLS_ADMIN_URL "t3://localhost:$WLS_ADMIN_PORT" "config.xml"
_v WLS_MANAGED_SERVER "$MS_REP" "config.xml"
_v WLS_REPORTS_PORT "$MS_PORT" "config.xml"
_v WLS_NODEMANAGER_PORT "$WLS_NODEMANAGER_PORT" "nodemanager.properties"
_v WLS_SERVER_FQDN "$FQDN" "$FQDN_SRC"
_v ADMIN_SERVER "$ADMIN_SERVER" "config.xml"
_c MANAGED_SERVERS "$MANAGED_SERVERS" "status.sh / show_log.sh lesen live aus der Domain"

_b "Reports-Komponenten"
_v REPORTS_TOOLS_INSTANCE "$TOOLS_INST" "Domain"
_v REPORTS_SERVER_NAME "$RS" "rwservlet.properties"
_c REPORTS_SERVERS "$REPORTS_SERVERS" "status.sh / show_log.sh lesen live aus der Domain"
_v REPORTS_BROADCAST_PORT "$BCAST" "rwnetwork.conf"
_rch=""; [ -n "$TOOLS_INST" ] && _rch="$CFG/components/ReportsToolsComponent/$TOOLS_INST"
_v REPORTS_COMPONENT_HOME "$_rch" "Domain"
_v REPORTS_ADMIN "${_rch:+$_rch/guicommon/tk/admin}" "Domain"
_v RWSERVER_CONF "$RS_CONF" "Domain"
_v REPORTS_APP_CONF "$APP_CONF" "Domain"
_v CGICMD_DAT "${APP_CONF:+$APP_CONF/cgicmd.dat}" "Domain"

_b "Report-Verzeichnisse"
_v REPORTS_PATH "$REP_PATH" "rwserver.conf"
_v REPORTS_IMAGE_DIR "$REP_IMG" "rwserver.conf"
_v REPORTS_TMP "$(_envvar REPORTS_TMP)" "rwserver.conf"
_v REPORTS_NLS_LANG "$(_envvar NLS_LANG)" "rwserver.conf von $RS"
_v TNS_ADMIN "$TNS" "Umgebung / reports.sh"

_b "Fonts"
_v REPORTS_FONT_DIR "$DOMAIN_HOME/reports/fonts" "Domain"
_v REPORTS_FONT_DIRECTORY "$DOMAIN_HOME/reports/fonts" "Domain"
_ali="${_rch:+$_rch/guicommon/tk/admin/uifont.ali}"
_v UIFONT_ALI "$_ali" "Domain"
_v TK_ADMIN "${_rch:+$_rch/guicommon/tk/admin}" "Domain"
_v TK_FONTALIAS "$_ali" "Domain"
_v ORACLE_FONTALIAS "$_ali" "Domain"
_v REPORTS_ENHANCED_FONTHANDLING "yes" "Vorgabe"

_b "RCU-Datenbank"
_v DB_HOST "$DB_H" "opss-datasource-jdbc.xml"
_v DB_PORT "$DB_P" "opss-datasource-jdbc.xml"
_v DB_SERVICE "$DB_S" "opss-datasource-jdbc.xml"
_v DB_SCHEMA_PREFIX "$DB_PFX" "opss-datasource-jdbc.xml"
_c RCU_DB_TYPE "" "ANPASSEN: nur fuer einen neuen RCU-Lauf"

_b "SSL (nur SSL_Kochbuch_de.txt)"
_v SSL_CN "$FQDN" "$FQDN_SRC"
for _k in SSL_CERT_FILE SSL_KEY_FILE SSL_CHAIN_FILE SSL_CSR_FILE SSL_KEY_SIZE SSL_DAYS SSL_COUNTRY SSL_STATE SSL_CITY SSL_ORG SSL_ORG_UNIT SSL_CA_DIR SSL_CA_CN; do
    _c "$_k" "" "ANPASSEN"
done

_b "Betrieb"
_v LOG_DIR "$DOMAIN_HOME/logs" "Domain"
_v TOOLS_HOME "$TOOLS_DIR" "dieses Skript"
_v NM_HOST "$NM_HOST" "nodemanager.properties"
_v NM_TYPE "$NM_TYPE" "nodemanager.properties"
_c WLST_CONFIG_FILE "" "nur wenn abweichend - status.sh sucht selbst"
_c WLST_KEY_FILE "" "nur wenn abweichend - status.sh sucht selbst"
if [ -f /etc/nginx/conf.d/oracle-wls.conf ]; then _v EXTRA_PORTS "80 443" "Nginx vorhanden"; else _c EXTRA_PORTS "" "weitere Ports fuer status.sh"; fi
_v LOG_MINUTES "60" "Vorgabe"

# --- anzeigen -------------------------------------------------------------------
TODO=()
printf "\npatch_install.ini aus Domain %s  -> %s\n" "$DOMAIN_NAME" "$TARGET"
for l in "${LINES_OUT[@]}"; do
    IFS='|' read -r n v q <<< "$l"
    case "$n" in
        "#") printf "\n  --- %s ---\n" "$v" ;;
        !*)  printf "  # %-26s %-34s %s\n" "${n#!}" "$v" "($q)"
             case "$q" in ANPASSEN*) TODO+=("${n#!}") ;; esac ;;
        *)   if [ -z "$v" ]; then
                 printf "  # %-26s %-34s %s\n" "$n" "" "(nicht ermittelt - ANPASSEN)"; TODO+=("$n")
             else
                 printf "    %-26s %s  (%s)\n" "$n" "$v" "$q"
                 case "$q" in *pruefen*) TODO+=("$n pruefen") ;; esac
             fi ;;
    esac
done

if ! $APPLY; then
    printf "\nNichts geschrieben. Schreiben mit: %s --apply\n" "$(basename "$0")"
    [ -e "$TARGET" ] && printf "Achtung: %s existiert - --apply ueberschreibt sie nicht.\n" "$TARGET"
    exit 0
fi

# --- schreiben ------------------------------------------------------------------
if [ -e "$TARGET" ]; then
    printf "\nFEHLER: %s existiert - wird nicht ueberschrieben (umbenennen, dann erneut)\n" "$TARGET" >&2
    exit 2
fi
ihwt_git_guard "$(dirname "$TARGET")" "$(basename "$TARGET")" || exit 2
( umask 077
  {
    printf '# =============================================================================\n'
    printf '# patch_install.ini - erzeugt am %s von make_patch_install_ini.sh\n' "$(date '+%F %T')"
    printf '# aus Domain %s auf %s. KEINE Kennwoerter in diese Datei schreiben.\n' "$DOMAIN_NAME" "$(hostname -s)"
    printf '# Auskommentierte Werte: ANPASSEN oder bewusst nicht gesetzt (Grund dahinter).\n'
    printf '# Einlesen: . %s/set_script_env.sh   Kontrolle: set_script_env_show\n' "$TOOLS_DIR"
    printf '# =============================================================================\n'
    for l in "${LINES_OUT[@]}"; do
        IFS='|' read -r n v q <<< "$l"
        case "$n" in
            "#") printf '\n# --- %s ---\n' "$v" ;;
            !*)  printf '# %s="%s"   # %s\n' "${n#!}" "$v" "$q" ;;
            *)   if [ -z "$v" ]; then printf '# %s=""   # nicht ermittelt - ANPASSEN\n' "$n"
                 else printf '%s="%s"\n' "$n" "$v"; fi ;;
        esac
    done
  } > "$TARGET"
) || { printf "FEHLER: %s nicht schreibbar\n" "$TARGET" >&2; exit 2; }
chmod 600 "$TARGET"
printf "\nOK: %s geschrieben (Rechte 600).\n" "$TARGET"
[ ${#TODO[@]} -gt 0 ] && printf "Noch pruefen / ergaenzen: %s\n" "${TODO[*]}"
printf "Einlesen fuer die Kochbuecher: . %s/set_script_env.sh\n" "$TOOLS_DIR"
exit 0
