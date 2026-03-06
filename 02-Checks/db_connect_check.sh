#!/bin/bash
# =============================================================================
# Script   : db_connect_check.sh
# Purpose  : Parse jps-config.xml for DB_ORACLE connections and verify
#            DNS reachability and TCP port connectivity
# Call     : ./db_connect_check.sh
# Requires : getent, nc (netcat)
# Note     : No SQL login – bootstrap credentials are encrypted.
#            Use this script to verify network path to the DB listener.
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"

# Load central library
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m Cannot find IHateWeblogic_lib.sh: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=00-Setup/IHateWeblogic_lib.sh
source "$LIB"

# Validate environment.conf
check_env_conf "$ENV_CONF" || exit 2
source "$ENV_CONF"

# Initialize log file
init_log

# =============================================================================
# Helpers: jps-config.xml parsing
# =============================================================================

# _prop_val  block  propname
# Extract the value="..." of a <property name="propname" value="..."/> element.
_prop_val() {
    printf "%s" "$1" \
        | sed -n "s/.*name=\"${2}\"[[:space:]]*value=\"\([^\"]*\)\".*/\1/p" \
        | head -1
}

# _jdbc_component  jdbc_url  component
# Extract host/port/service_name/server from a jdbc:oracle:thin:@ TNS descriptor.
_jdbc_host()    { printf "%s" "$1" | sed -n 's/.*host=\([^)]*\).*/\1/p'         | head -1; }
_jdbc_port()    { printf "%s" "$1" | sed -n 's/.*port=\([^)]*\).*/\1/p'         | head -1; }
_jdbc_service() { printf "%s" "$1" | sed -n 's/.*service_name=\([^)]*\).*/\1/p' | head -1; }
_jdbc_server()  { printf "%s" "$1" | sed -n 's/.*server=\([^)]*\).*/\1/p'       | head -1; }

# _check_db_block  block
# Validate one DB_ORACLE propertySet block (DNS + TCP + JDBC JAR).
_check_db_block() {
    local block="$1"

    # Extract metadata
    local ps_name jndi_name jdbc_url jdbc_driver
    ps_name="$(    printf "%s" "$block" | sed -n 's/.*<propertySet[[:space:]]*name="\([^"]*\)".*/\1/p' | head -1)"
    jndi_name="$(  _prop_val "$block" "datasource\.jndi\.name")"
    jdbc_url="$(   _prop_val "$block" "jdbc\.url")"
    jdbc_driver="$(_prop_val "$block" "jdbc\.driver")"

    # Parse TNS descriptor components
    local db_host db_port db_service db_srv_type
    db_host="$(    _jdbc_host    "$jdbc_url")"
    db_port="$(    _jdbc_port    "$jdbc_url")"
    db_service="$( _jdbc_service "$jdbc_url")"
    db_srv_type="$(_jdbc_server  "$jdbc_url")"

    printf "\n"
    printf "  \033[1m── %s ──\033[0m\n" "${ps_name:-Unbekannt}"
    printList "  JNDI-Name"    24 "${jndi_name:-–}"
    printList "  Host"         24 "${db_host:-–}"
    printList "  Port"         24 "${db_port:-–}"
    printList "  Service"      24 "${db_service:-–}"
    printList "  Server-Typ"   24 "${db_srv_type:-–}"
    printList "  JDBC-Driver"  24 "${jdbc_driver:-–}"

    printf "\n"

    # Check 1: DNS resolution
    if [ -z "$db_host" ]; then
        warn "$(printf "  %-22s  Host nicht aus JDBC-URL parsbar" "DNS-Auflösung:")"
    else
        local dns_ip
        dns_ip="$(getent hosts "$db_host" 2>/dev/null | awk '{print $1}' | head -1)"
        if [ -n "$dns_ip" ]; then
            ok "$(printf "  %-22s  %s → %s" "DNS-Auflösung:" "$db_host" "$dns_ip")"
        else
            fail "$(printf "  %-22s  %s – kein A-Record" "DNS-Auflösung:" "$db_host")"
        fi
    fi

    # Check 2: TCP port (Oracle listener)
    if [ -z "$db_host" ] || [ -z "$db_port" ]; then
        warn "$(printf "  %-22s  Host oder Port nicht ermittelbar" "TCP Port:")"
    elif command -v nc >/dev/null 2>&1; then
        if nc -z -w 3 "$db_host" "$db_port" 2>/dev/null; then
            ok "$(printf "  %-22s  %s:%s erreichbar" "TCP Port:" "$db_host" "$db_port")"
        else
            fail "$(printf "  %-22s  %s:%s – Timeout/Refused (3s)" "TCP Port:" "$db_host" "$db_port")"
        fi
    else
        warn "$(printf "  %-22s  nc nicht verfügbar – übersprungen" "TCP Port:")"
        info "  Alternativ: telnet $db_host $db_port"
    fi

    # Check 3: JDBC JAR (shared result from outer scope)
    if [ -n "${JDBC_JAR:-}" ]; then
        ok "$(printf "  %-22s  %s" "JDBC-JAR:" "$JDBC_JAR")"
    else
        warn "$(printf "  %-22s  kein ojdbc*.jar unter FMW_HOME gefunden" "JDBC-JAR:")"
        info "  Erwartet: $FMW_HOME/oracle_common/modules/oracle.jdbc/"
    fi
}

# =============================================================================
# Banner
# =============================================================================
printLine
printf "\n\033[1mIHateWeblogic – Oracle DB Connection Check\033[0m\n"
printf "Host    : %s\n" "$(_get_hostname)"
printf "Date    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "Log     : %s\n\n" "$LOG_FILE"

# =============================================================================
# Section 1: Locate jps-config.xml
# =============================================================================
section "jps-config.xml – Lokalisierung"

JPS_CONFIG="${DOMAIN_HOME}/config/fmwconfig/jps-config.xml"

if [ ! -f "$JPS_CONFIG" ]; then
    info "Standard-Pfad nicht gefunden – suche unter DOMAIN_HOME ..."
    JPS_CONFIG="$(find "$DOMAIN_HOME" -name "jps-config.xml" 2>/dev/null | head -1)"
fi

if [ -z "$JPS_CONFIG" ] || [ ! -f "$JPS_CONFIG" ]; then
    fail "jps-config.xml nicht gefunden unter $DOMAIN_HOME"
    info "  Prüfen Sie DOMAIN_HOME in environment.conf"
    print_summary
    exit "$EXIT_CODE"
fi

ok "jps-config.xml gefunden"
printList "Pfad"    26 "$JPS_CONFIG"
printList "Größe"   26 "$(wc -c < "$JPS_CONFIG") Bytes"

# =============================================================================
# Section 2: DB_ORACLE propertySet-Einträge zählen
# =============================================================================
section "DB_ORACLE Verbindungen"

NUM_CONNS="$(grep -c 'value="DB_ORACLE"' "$JPS_CONFIG" 2>/dev/null || true)"
printList "DB_ORACLE-Einträge" 26 "$NUM_CONNS"

if [ "${NUM_CONNS:-0}" -eq 0 ]; then
    warn "Keine DB_ORACLE propertySet-Einträge in jps-config.xml gefunden"
    print_summary
    exit "$EXIT_CODE"
fi

# =============================================================================
# Section 3: JDBC JAR (once, shared for all connections)
# =============================================================================
section "JDBC-Treiber"

JDBC_JAR=""
JDBC_JAR="$(find "$FMW_HOME" -name "ojdbc*.jar" 2>/dev/null | sort | head -1)"

if [ -n "$JDBC_JAR" ]; then
    ok "ojdbc JAR gefunden: $JDBC_JAR"
    # Also show if multiple versions exist
    JDBC_COUNT="$(find "$FMW_HOME" -name "ojdbc*.jar" 2>/dev/null | wc -l)"
    [ "$JDBC_COUNT" -gt 1 ] && \
        info "  Hinweis: $JDBC_COUNT ojdbc*.jar gefunden – Verwendung gemäß Classpath"
else
    warn "Kein ojdbc*.jar unter FMW_HOME ($FMW_HOME)"
    info "  Oracle JDBC wird von FMW normalerweise mitgeliefert"
fi

# =============================================================================
# Section 4: Pro Verbindung prüfen
# =============================================================================
section "DB-Verbindungsprüfung"

# Walk jps-config.xml line by line; collect <propertySet> blocks, process those
# containing server.type DB_ORACLE.
in_block=0
current_block=""
blocks_checked=0

while IFS= read -r line; do
    if [[ "$line" == *"<propertySet "* ]]; then
        in_block=1
        current_block="${line}"$'\n'
    elif [ "$in_block" -eq 1 ]; then
        current_block+="${line}"$'\n'
        if [[ "$line" == *"</propertySet>"* ]]; then
            if printf "%s" "$current_block" | grep -q 'value="DB_ORACLE"'; then
                _check_db_block "$current_block"
                blocks_checked=$(( blocks_checked + 1 ))
            fi
            in_block=0
            current_block=""
        fi
    fi
done < "$JPS_CONFIG"

printf "\n"
printList "Geprüfte DB_ORACLE-Verbindungen" 34 "$blocks_checked"

# =============================================================================
# Summary
# =============================================================================
print_summary
exit $EXIT_CODE
