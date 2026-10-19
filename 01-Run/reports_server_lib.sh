#!/bin/bash
# =============================================================================
# Script   : reports_server_lib.sh  (sourced, not executed)
# Purpose  : One place that knows how to find and query the Oracle Reports
#            server of an FMW 14.1.2 domain – used by 01-Run/rwserver_status.sh
#            and the 05-ReportsPerformance scripts (before, each script had its
#            own copy of these helpers and the copies drifted apart).
#
# Verified live 2026-10-19 (test host):
#   - standalone Reports server = system component, its rwserver.conf is
#     config/fmwconfig/components/ReportsServerComponent/<name>/rwserver.conf;
#     RWSERVER_CONF in environment.conf may point to the in-process server of
#     WLS_REPORTS (servers/WLS_REPORTS/applications/reports_*/configuration)
#   - rwserver.conf has TWO engines (rwEng + rwURLEng) – attributes must be
#     read from the report engine (<job jobType="report" engineId=...>)
#   - process "rwserver server=<name>", the engines are its Java child
#     processes (oracle.reports.engine.RWEngine) – no "rwengine" process
#   - getserverinfo needs an authid on a secured server (HTTP 499 without)
#
# Usage    : source "$ROOT_DIR/01-Run/reports_server_lib.sh"
#            rws_detect_wls_server            -> WLS managed server name
#            rws_find_conf [name]             -> sets RWS_COMP_NAME, RWSERVER_CONF
#            rws_engine_attr FILE ATTR        -> attribute of the report engine
#            rws_elem_attr FILE ELEMENT ATTR  -> attribute of the first <ELEMENT>
#            rws_cache_prop FILE NAME         -> <cache><property name=NAME value=…>
#            rws_set_engine_attr FILE ATTR VALUE  -> change/add attribute (report engine only)
#            rws_server_pid NAME              -> PID of "rwserver server=NAME"
#            rws_engine_pids SERVER_PID       -> engine PIDs (comma separated)
#            rws_wls_port SERVER              -> listen port from config.xml (default 9002)
#            rws_fetch_serverinfo URL MODE    -> sets RWS_HTTP_CODE, RWS_HTTP_XML,
#                                                RWS_REP_ERR, RWS_AUTH_USER, RWS_AUTH_SRC
#            rws_xval / rws_xline_attr / rws_xprop  -> XML string helpers
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

# Detect the Reports WLS managed server name.
# Priority:
#   1. Running process with "report" in -Dweblogic.Name=...
#   2. config.xml server name containing "report"
#   3. WLS_MANAGED_SERVER from environment.conf (if it differs from domain name)
#   4. Fallback: WLS_REPORTS
rws_detect_wls_server() {
    local config_xml="$DOMAIN_HOME/config/config.xml"
    local domain_name found

    domain_name="$(basename "${DOMAIN_HOME:-/}")"

    # Strategy 1: extract server name first, then filter by name (not full cmdline).
    # Full cmdline often contains "report" via domain path (e.g. fr_domain),
    # which would wrongly match AdminServer.
    found="$(pgrep -a -f 'weblogic.Name=' 2>/dev/null \
        | sed -n 's/.*-Dweblogic\.Name=\([^ ]*\).*/\1/p' \
        | grep -i 'report' \
        | head -1)"
    [ -n "$found" ] && { printf "%s" "$found"; return 0; }

    # Strategy 2: config.xml server names
    if [ -f "$config_xml" ]; then
        found="$(awk '
            /<server>$/   { in_srv=1; name="" }
            /<\/server>$/ { in_srv=0 }
            in_srv && /<name>/ {
                n=$0
                gsub(/.*<name>/, "", n); gsub(/<\/name>.*/, "", n)
                if (tolower(n) ~ /report/) { print n; exit }
            }
        ' "$config_xml" 2>/dev/null)"
        [ -n "$found" ] && { printf "%s" "$found"; return 0; }
    fi

    # Strategy 3: WLS_MANAGED_SERVER from environment.conf (if != domain name)
    if [ -n "${WLS_MANAGED_SERVER:-}" ] && [ "${WLS_MANAGED_SERVER}" != "$domain_name" ]; then
        printf "%s" "${WLS_MANAGED_SERVER}"
        return 0
    fi

    printf "WLS_REPORTS"
}

# rws_find_conf [name] – rwserver.conf of the standalone Reports server.
# Name: argument > REPORTS_SERVER_NAME > first ReportsServerComponent in
# config.xml. Falls back to RWSERVER_CONF (environment.conf), then to the
# first rwserver.conf below $DOMAIN_HOME/config.
# Sets RWS_COMP_NAME and RWSERVER_CONF (empty if nothing found).
rws_find_conf() {
    local comp
    RWS_COMP_NAME="${1:-${REPORTS_SERVER_NAME:-}}"
    if [ -z "$RWS_COMP_NAME" ] && [ -f "$DOMAIN_HOME/config/config.xml" ]; then
        RWS_COMP_NAME="$(awk '
            /<system-component>/ { n=""; t="" }
            /<name>/ && n=="" { n=$0; gsub(/.*<name>|<\/name>.*/, "", n) }
            /<component-type>ReportsServerComponent</ { t="R" }
            /<\/system-component>/ { if (t=="R") { print n; exit } }
        ' "$DOMAIN_HOME/config/config.xml")"
    fi
    comp="$DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent/${RWS_COMP_NAME}/rwserver.conf"
    if [ -n "$RWS_COMP_NAME" ] && [ -f "$comp" ]; then
        RWSERVER_CONF="$comp"
    else
        RWSERVER_CONF="${RWSERVER_CONF:-}"
    fi
    if [ -z "$RWSERVER_CONF" ] || [ ! -f "$RWSERVER_CONF" ]; then
        RWSERVER_CONF="$(find "${DOMAIN_HOME}/config" -name "rwserver.conf" 2>/dev/null | head -1)"
    fi
    [ -n "$RWSERVER_CONF" ] && [ -f "$RWSERVER_CONF" ]
}

# Flatten a config file: one XML tag per line (handles multi-line elements).
_rws_flat() { tr -d '\n' < "$1" | sed 's/</\n</g'; }

# Line of the report engine: the one of <job jobType="report" engineId=...>,
# else the first engine that is not the URL engine.
_rws_engine_line() {
    local flat eid line=""
    flat="$(_rws_flat "$1")"
    eid="$(printf '%s\n' "$flat" | grep '^<job ' | grep 'jobType="report"' \
           | sed -n 's/.*engineId="\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$eid" ] && line="$(printf '%s\n' "$flat" | grep "^<engine " | grep "id=\"${eid}\"" | head -1)"
    [ -z "$line" ] && line="$(printf '%s\n' "$flat" | grep '^<engine ' | grep -v 'URLEngineImpl' | head -1)"
    printf '%s' "$line"
}

# rws_engine_attr FILE ATTR – singular and plural (maxEngine / maxEngines)
# both occur in the wild.
rws_engine_attr() {
    local line val
    line="$(_rws_engine_line "$1")"
    val="$(printf '%s' "$line" | sed -n "s/.*[[:space:]]${2}=\"\([^\"]*\)\".*/\1/p")"
    [ -z "$val" ] && val="$(printf '%s' "$line" | sed -n "s/.*[[:space:]]${2}s=\"\([^\"]*\)\".*/\1/p")"
    printf "%s" "$val"
}

# rws_engine_id FILE – id of the report engine (rwEng)
rws_engine_id() { _rws_engine_line "$1" | sed -n 's/.*[[:space:]]id="\([^"]*\)".*/\1/p'; }

# rws_has_url_engine FILE – 0 if an active (not commented) URL engine exists
rws_has_url_engine() {
    tr -d '\n' < "$1" | sed 's/<!--[^>]*-->//g' | grep -q 'URLEngineImpl'
}

# rws_elem_attr FILE ELEMENT ATTR – attribute of the first <ELEMENT ...>
rws_elem_attr() {
    _rws_flat "$1" | grep "^<${2}[[:space:]>/]" | head -1 \
        | sed -n "s/.*[[:space:]]${3}=\"\([^\"]*\)\".*/\1/p"
}

# rws_cache_prop FILE NAME – <cache><property name="NAME" value="…"/>
rws_cache_prop() {
    _rws_flat "$1" | sed -n '/^<cache[[:space:]>]/,/^<\/cache>/p' \
        | grep "^<property[^>]*name=\"${2}\"" | head -1 \
        | sed -n 's/.*value="\([^"]*\)".*/\1/p'
}

# rws_set_engine_attr FILE ATTR VALUE – change (or add) one attribute of the
# report engine element only; the URL engine stays untouched. No backup here –
# the caller runs backup_file first.
rws_set_engine_attr() {
    local eid
    eid="$(rws_engine_id "$1")"
    [ -z "$eid" ] && return 1
    python3 -I - "$1" "$eid" "$2" "$3" << 'RWS_PY'
import re, sys
path, eid, attr, val = sys.argv[1:5]
s = open(path, encoding='iso-8859-1').read()
m = re.search(r'<engine\b[^>]*\bid="%s"[^>]*?(/?)>' % re.escape(eid), s)
if not m:
    sys.exit(1)
tag = m.group(0)
pat = re.compile(r'(\s%ss?)="[^"]*"' % re.escape(attr))
if pat.search(tag):
    new = pat.sub(lambda x: ' %s="%s"' % (attr, val), tag, count=1)
else:
    end = '/>' if tag.endswith('/>') else '>'
    new = tag[:-len(end)].rstrip() + ' %s="%s"%s' % (attr, val, end)
open(path, 'w', encoding='iso-8859-1').write(s[:m.start()] + new + s[m.end():])
RWS_PY
}

# rws_server_pid NAME – process "rwserver server=NAME"
rws_server_pid() {
    [ -n "$1" ] || return 1
    pgrep -f "rwserver server=${1}( |\$)" 2>/dev/null | head -1
}

# rws_engine_pids SERVER_PID – engine child processes (comma separated).
# Without a server PID (in-process server / older releases): native rwengine.
rws_engine_pids() {
    if [ -n "$1" ]; then
        pgrep -d ',' -P "$1" 2>/dev/null
    else
        pgrep -d ',' -x "rwengine" 2>/dev/null
    fi
}

# rws_wls_port SERVER – listen-port of the WLS managed server from config.xml
rws_wls_port() {
    local port="" cfg="$DOMAIN_HOME/config/config.xml"
    if [ -f "$cfg" ]; then
        # plain awk (no 3-arg match) – gsub strips tags in-place
        port="$(awk -v srv="$1" '
            /<server>$/   { in_srv=1; in_ssl=0; name=""; port="" }
            /<\/server>$/ {
                if (in_srv && name == srv && port != "") { print port; exit }
                in_srv=0; in_ssl=0
            }
            in_srv && /<ssl>$/   { in_ssl=1 }
            in_srv && /<\/ssl>$/ { in_ssl=0 }
            in_srv && !in_ssl {
                if ($0 ~ /<name>/) {
                    n=$0; gsub(/.*<name>/, "", n); gsub(/<\/name>.*/, "", n)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", n)
                    if (n != "") name=n
                }
                if ($0 ~ /<listen-port>/) {
                    p=$0; gsub(/.*<listen-port>/, "", p); gsub(/<\/listen-port>.*/, "", p)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", p)
                    if (p != "") port=p
                }
            }
        ' "$cfg" 2>/dev/null)"
    fi
    printf "%s" "${port:-9002}"
}

# rws_fetch_serverinfo URL MODE – one getserverinfo request.
# MODE (authid): auto | mon | admin | none. auto = REPORTS_SECURITY=ldap ->
# monUser (RW_MONITOR) from reports_users.conf.des3, otherwise the Reports
# server administrator (<identifier>) from reports_admin_sec.conf.des3; falls
# back to the other one. The password goes to curl via a config on stdin –
# not in the process list, not printed.
rws_fetch_serverinfo() {
    local url="$1" mode="${2:-auto}" pwd="" tmp
    RWS_HTTP_CODE="" RWS_HTTP_XML="" RWS_REP_ERR="" RWS_AUTH_USER="" RWS_AUTH_SRC=""

    _rws_load_mon() {
        local f="$ROOT_DIR/reports_users.conf.des3"
        [ -f "$f" ] && load_secrets_file "$f" > /dev/null 2>&1 \
            && [ -n "${REPORTS_MON_USER:-}" ] && [ -n "${REPORTS_MON_PWD:-}" ] || return 1
        RWS_AUTH_USER="$REPORTS_MON_USER"; pwd="$REPORTS_MON_PWD"
        RWS_AUTH_SRC="monitoring user (reports_users.conf.des3)"
    }
    _rws_load_admin() {
        local f="$ROOT_DIR/reports_admin_sec.conf.des3"
        [ -f "$f" ] && load_secrets_file "$f" > /dev/null 2>&1 \
            && [ -n "${REPORTS_ADMIN_USER:-}" ] && [ -n "${REPORTS_ADMIN_PWD:-}" ] || return 1
        RWS_AUTH_USER="$REPORTS_ADMIN_USER"; pwd="$REPORTS_ADMIN_PWD"
        RWS_AUTH_SRC="Reports server admin <identifier> (reports_admin_sec.conf.des3)"
    }
    case "$mode" in
        mon)   _rws_load_mon   || warn "Monitoring user not found in reports_users.conf.des3 (12-oracle_reports_users.sh)" ;;
        admin) _rws_load_admin || warn "Reports server admin not found in reports_admin_sec.conf.des3 (13-oracle_setup_reports.sh)" ;;
        auto)
            if [ "${REPORTS_SECURITY:-ldap}" = "ldap" ]; then
                _rws_load_mon || _rws_load_admin
            else
                _rws_load_admin || _rws_load_mon
            fi ;;
    esac
    unset REPORTS_MON_PWD REPORTS_EXEC_PWD REPORTS_ADMIN_PWD

    tmp="$(mktemp)"
    RWS_HTTP_CODE="$( {
        printf 'url = "%s"\n' "$url"
        if [ -n "$RWS_AUTH_USER" ]; then
            printf 'get\n'
            printf 'data-urlencode = "authid=%s/%s"\n' "$RWS_AUTH_USER" "$pwd"
        fi
    } | curl -s --connect-timeout 5 --max-time 30 -K - -o "$tmp" -w "%{http_code}" 2>/dev/null )"
    pwd=""
    RWS_HTTP_XML="$(cat "$tmp" 2>/dev/null)"
    rm -f "$tmp"
    RWS_REP_ERR="$(printf '%s' "$RWS_HTTP_XML" | sed -n 's/.*<error code="\([0-9]*\)"[^>]*message="\([^"]*\)".*/REP-\1 \2/p' | head -1)"
    [ -z "$RWS_REP_ERR" ] && RWS_REP_ERR="$(printf '%s' "$RWS_HTTP_XML" | grep -o 'REP-[0-9]*[^<]\{0,80\}' | head -1)"
    return 0
}

# rws_http_verdict – ok/warn/fail for RWS_HTTP_CODE / RWS_REP_ERR.
# Returns 0 only when RWS_HTTP_XML holds usable server info.
rws_http_verdict() {
    case "$RWS_HTTP_CODE" in
        200)
            if [ -n "$RWS_REP_ERR" ]; then
                fail "rwservlet answered with an error: $RWS_REP_ERR"
                case "$RWS_REP_ERR" in
                    REP-52262*) info "  Diagnostic output disabled for this user – unsecured server: use --auth admin (<identifier>); secured: monUser needs RW_MONITOR" ;;
                    REP-50171*) info "  Authentication failed – wrong password in the .des3 file, or (securityId without LDAP identity store) see doc 13 Step 5a" ;;
                    REP-56071*) info "  User not authorized for web commands – role RW_MONITOR / WebCommandPermission missing (12-oracle_reports_users.sh)" ;;
                esac
                return 1
            fi
            ok "rwservlet reachable (HTTP 200)"
            return 0
            ;;
        499)
            fail "HTTP 499 – login required (secured Reports server) and no valid authid"
            info "  Store the monitoring user: 09-Install/12-oracle_reports_users.sh"
            ;;
        000)
            warn "No response from rwservlet – WLS_REPORTS not running or port wrong?"
            ;;
        401|403)
            warn "HTTP ${RWS_HTTP_CODE} – Authentication required on rwservlet"
            info "  Try --auth mon / --auth admin (credentials from the *.des3 files)"
            ;;
        404)
            warn "HTTP 404 – rwservlet not found"
            info "Reports may not be deployed or the context path differs"
            ;;
        *)
            warn "HTTP ${RWS_HTTP_CODE} – unexpected response from rwservlet"
            ;;
    esac
    return 1
}

# Extract element value <tag>value</tag> from an XML string (not a file).
rws_xval() { printf "%s" "$1" | sed -n "s|.*<${2}>\([^<]*\)</${2}>.*|\1|p" | head -1; }

# Extract a named attribute from a single XML tag line.
rws_xline_attr() { printf "%s" "$1" | sed -n "s/.*[[:space:]]${2}=\"\([^\"]*\)\".*/\1/p"; }

# Extract the value of <property name="N" value="V"/> from an XML string.
rws_xprop() { printf "%s" "$1" | grep "name=\"${2}\"" | sed -n 's/.*value="\([^"]*\)".*/\1/p' | head -1; }
