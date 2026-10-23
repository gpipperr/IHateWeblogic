#!/bin/bash
# =============================================================================
# Script   : clone_check.sh
# Purpose  : Is this installation clone-capable (golden image, easy to move)?
#            Target: everything internal on 127.0.0.1, only Nginx / the
#            certificate carry the host name.
#              1. listening sockets of WebLogic, Node Manager, Forms, Reports
#                 by bind address (loopback / all interfaces / host IP)
#              2. WebLogic: listen addresses, SSL listen ports (demo
#                 certificate), Coherence unicast address, Node Manager
#              3. Reports ORB on 127.0.0.1 (reports.sh), discovery port
#              4. host name / IP in the domain configuration (JDBC, OPSS …)
#              5. machine identity: *.des3 secrets (disk UUID)
#              6. the intended host-specific places (to change after a clone)
#            --apply (domain running, WLST online, backup of config.xml):
#            SSL listen port off + Coherence UnicastListenAddress 127.0.0.1
#            for WLS_FORMS / WLS_REPORTS – restart of both servers needed.
# Call     : ./02-Checks/clone_check.sh
#            ./02-Checks/clone_check.sh --apply
# Options  : --apply   switch off SSL + Coherence on 127.0.0.1 (WLST online)
#            --help    Show usage
# Runs as  : oracle
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 80-FMW-Architecture/clone_golden_image.md, 02-Checks/README.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"

LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m Cannot find IHateWeblogic_lib.sh: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"
check_env_conf "$ENV_CONF" || exit 2
# shellcheck source=../environment.conf
source "$ENV_CONF"

init_log

APPLY=false
for _arg in "$@"; do
    case "$_arg" in
        --apply) APPLY=true ;;
        --help|-h)
            printf "Usage: %s [--apply]\n" "$(basename "$0")"
            printf "  (none)   check sockets, WebLogic, Reports, host references, secrets\n"
            printf "  --apply  SSL listen port off + Coherence on 127.0.0.1 (WLST online)\n"
            exit 0 ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$_arg" >&2; exit 2 ;;
    esac
done
unset _arg

CONFIG_XML="$DOMAIN_HOME/config/config.xml"
H_FQDN="$(hostname -f 2>/dev/null)"
H_SHORT="$(hostname -s 2>/dev/null)"
H_IPS="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -vE '^(127\.|::1|$)')"
COH_PORT="$(sed -n 's:.*<cluster-listen-port>\([0-9]*\)<.*:\1:p' "$DOMAIN_HOME"/config/coherence/*/*.xml 2>/dev/null | head -1)"
COH_PORT="${COH_PORT:-7574}"
STEPS=0          # things to do after a clone (INFO with a step)
FIXES=0          # things to fix before an image is taken (WARN)

_step() { STEPS=$(( STEPS + 1 )); info "$*"; }
_fix()  { FIXES=$(( FIXES + 1 )); warn "$*"; }

# server|listen-address|ssl-enabled|coherence-unicast|cluster from config.xml
SRV_INFO="$( [ -f "$CONFIG_XML" ] && python3 - "$CONFIG_XML" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
ns = {'d': 'http://xmlns.oracle.com/weblogic/domain'}
root = ET.parse(sys.argv[1]).getroot()
for s in root.findall('d:server', ns):
    name = s.findtext('d:name', '', ns)
    la = s.findtext('d:listen-address', '', ns)
    ssl = s.find('d:ssl', ns)
    en = 'false'
    if ssl is not None:
        en = (ssl.findtext('d:enabled', 'false', ns) or 'false').lower()
    cm = s.find('d:coherence-member-config', ns)
    ua = cm.findtext('d:unicast-listen-address', '', ns) if cm is not None else ''
    cl = s.findtext('d:cluster', '', ns)
    print('%s|%s|%s|%s|%s' % (name, la, en, ua, cl))
PYEOF
)"

printLine
section "Clone readiness ($(date '+%Y-%m-%d %H:%M:%S'))"
printList "Host name"  20 "${H_FQDN:-?} (${H_SHORT:-?})"
printList "Host IPs"   20 "$(printf '%s ' $H_IPS)"

# =============================================================================
# 1. Listening sockets by bind address
# =============================================================================
section "Listening sockets"
_frmweb_any=0
while read -r _proto _local _proc; do
    _addr="${_local%:*}"; _port="${_local##*:}"
    case "$_addr" in
        127.*|\[::1\]|\[::ffff:127.*) continue ;;
    esac
    _name="$(printf '%s' "$_proc" | sed -n 's/.*(("\([^"]*\)",pid=\([0-9]*\).*/\1 \2/p')"
    _cmd=""; _pid="${_name#* }"
    [ -r "/proc/$_pid/cmdline" ] && _cmd="$(tr '\0' ' ' < "/proc/$_pid/cmdline")"
    _who="$(printf '%s' "$_cmd" | grep -oE 'weblogic.Name=[A-Za-z_]+|oracle.reports.component=[A-Za-z0-9_-]+|NodeManager' | head -1)"
    _who="${_who#*=}"; _who="${_who:-${_name%% *}}"
    case "${_name%% *}/$_port" in
        frmweb/*)
            _frmweb_any=$(( _frmweb_any + 1 )); continue ;;
        */"${REPORTS_BROADCAST_PORT:-14027}")
            info "$(printf "  %-5s %-22s %-14s multicast discovery (stays, section 3)" "$_proto" "$_local" "$_who")"; continue ;;
    esac
    # Coherence of a server already on 127.0.0.1 keeps the cluster port + one
    # port on the host IP (confirmed 2026-10-23, not removable) - firewall
    if [ "${_name%% *}" = "java" ] && printf '%s\n' "$SRV_INFO" | grep -qE "^${_who}\|[^|]*\|[^|]*\|(127\.0\.0\.1|localhost)\|" \
       && { [ "$_port" = "$COH_PORT" ] || printf '%s\n' $H_IPS | grep -qxF "${_addr//[\[\]]/}"; }; then
        info "$(printf "  %-5s %-22s %-14s Coherence (stays on the host IP, member traffic on loopback) – firewall" "$_proto" "$_local" "$_who")"
        continue
    fi
    if printf '%s\n' $H_IPS | grep -qxF "${_addr//[\[\]]/}"; then
        _fix "$(printf "  %-5s %-22s %-14s bound to the host IP" "$_proto" "$_local" "$_who")"
    else
        _fix "$(printf "  %-5s %-22s %-14s all interfaces" "$_proto" "$_local" "$_who")"
    fi
done < <(ss -Hltnpu 2>/dev/null | awk '/java|frmweb|rwserver/ { print $1, $5, $7 }')
[ "$_frmweb_any" -gt 0 ] && info "$(printf "  frmweb: %s socket(s) on all interfaces – not configurable (no Oracle option), no host name inside; firewall" "$_frmweb_any")"

# =============================================================================
# 2. WebLogic configuration
# =============================================================================
section "WebLogic (config.xml, Node Manager)"
NEED_WLST=false
if [ ! -f "$CONFIG_XML" ]; then
    fail "config.xml not found: $CONFIG_XML"
else
    while IFS='|' read -r _s _la _ssl _ua _cl; do
        [ -z "$_s" ] && continue
        case "$_la" in
            localhost|127.0.0.1) ok "$(printf "  %-12s listen %s" "$_s" "$_la")" ;;
            "")                  _fix "$(printf "  %-12s listen address empty = all interfaces" "$_s")" ;;
            *)                   _fix "$(printf "  %-12s listen %s (not loopback)" "$_s" "$_la")" ;;
        esac
        if [ "$_ssl" = "true" ]; then
            _fix "$(printf "  %-12s SSL listen port enabled (demo certificate unless replaced) – --apply" "$_s")"
            [ "$_s" != "AdminServer" ] && NEED_WLST=true
        else
            ok "$(printf "  %-12s SSL listen port off" "$_s")"
        fi
        if [ -n "$_cl" ]; then
            case "$_ua" in
                127.0.0.1|localhost) ok "$(printf "  %-12s Coherence unicast %s" "$_s" "$_ua")" ;;
                *) _fix "$(printf "  %-12s Coherence unicast %s – member traffic on the host IP, clones can join – --apply" "$_s" "${_ua:-(auto = host IP)}")"
                   NEED_WLST=true ;;
            esac
        fi
    done <<< "$SRV_INFO"
fi
_nm="$DOMAIN_HOME/nodemanager/nodemanager.properties"
if [ -f "$_nm" ]; then
    _nla="$(sed -n 's/^ListenAddress=//p' "$_nm" | tail -1)"
    case "$_nla" in
        localhost|127.0.0.1) ok "$(printf "  %-12s listen %s" "NodeManager" "$_nla")" ;;
        *) _fix "$(printf "  %-12s listen %s – 09-Install/11-oracle_nodemanager.sh" "NodeManager" "${_nla:-(all)}")" ;;
    esac
fi

# =============================================================================
# 3. Reports: ORB bind address, discovery
# =============================================================================
if [ "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" != "FORMS_ONLY" ]; then
    section "Reports (ORB, discovery)"
    _rsh="$DOMAIN_HOME/reports/bin/reports.sh"
    if grep -q '^REPORTS_JVM_OPTIONS=.*ORBServerHost=127.0.0.1' "$_rsh" 2>/dev/null; then
        ok "  reports.sh: ORB of server + engines on 127.0.0.1 (ORBServerHost)"
    else
        _fix "  reports.sh: no ORBServerHost=127.0.0.1 – server/engines on all interfaces – 09-Install/13-oracle_setup_reports.sh --apply + restart"
    fi
    if grep -q 'ORBServerHost=127.0.0.1' "$DOMAIN_HOME/bin/setUserOverrides.sh" 2>/dev/null; then
        ok "  setUserOverrides.sh: rwservlet ORB (WLS_REPORTS) on 127.0.0.1"
    else
        _fix "  setUserOverrides.sh: rwservlet ORB (WLS_REPORTS) on all interfaces – 09-Install/13-oracle_setup_reports.sh --apply + restart"
    fi
    _step "$(printf "  discovery: multicast port %s, server %s – after a clone in the same subnet change REPORTS_BROADCAST_PORT (14021-14030) + 13- --apply" \
        "${REPORTS_BROADCAST_PORT:-14027}" "${REPORTS_SERVER_INSTANCES:-?}")"
fi

# =============================================================================
# 4. Host name / IP in the domain configuration
# =============================================================================
section "Host name / IP in \$DOMAIN_HOME/config"
_pat="$(printf '%s\n' "$H_FQDN" "$H_SHORT" $H_IPS | grep -v '^$' | sed 's/\./\\./g' | paste -sd'|')"
if [ -n "$_pat" ]; then
    _hits="$(grep -rlIE "(^|[^A-Za-z0-9.-])(${_pat})([^A-Za-z0-9-]|$)" "$DOMAIN_HOME/config" "$DOMAIN_HOME/init-info" 2>/dev/null \
        | grep -vE '\.bak_[0-9]|/logs?/|\.log' | sort)"
    if [ -z "$_hits" ]; then
        ok "  no own host name / IP"
    else
        while read -r _f; do
            _rel="${_f#"$DOMAIN_HOME"/}"
            case "$_rel" in
                config/jdbc/*|config/fmwconfig/jps-config*.xml)
                    _step "$(printf "  %-48s DB host = this host – keep it only if the DB moves along, else localhost/alias" "$_rel")" ;;
                init-info/*|*uifont.ali)
                    info "$(printf "  %-48s informational (not read at runtime / comment)" "$_rel")" ;;
                *)
                    _fix "$(printf "  %-48s host name / IP – check" "$_rel")" ;;
            esac
        done <<< "$_hits"
    fi
fi

# RCU repository: on this host (cloned along) or external (own prefix per clone)
_ds="$DOMAIN_HOME/config/jdbc/WLSSchemaDataSource-jdbc.xml"
if [ -f "$_ds" ]; then
    _dburl="$(sed -n 's:.*<url>\([^<]*\)</url>.*:\1:p' "$_ds" | head -1)"
    _dbh="$(printf '%s' "$_dburl" | sed -n 's|.*@/*\([^:/]*\).*|\1|p')"
    _pfx="$(grep -A1 '<name>user</name>' "$_ds" | sed -n 's:.*<value>\([^<]*\)_WLS</value>.*:\1:p' | head -1)"
    if [ "$_dbh" = "localhost" ] || [ "${_dbh%%.*}" = "$H_SHORT" ] || printf '%s\n' $H_IPS 127.0.0.1 | grep -qxF "$_dbh"; then
        ok "$(printf "  RCU repository on this host (prefix %s) – cloned along with the DB" "${_pfx:-?}")"
    else
        _step "$(printf "  RCU repository EXTERNAL (%s, prefix %s) – a clone needs its own prefix, never start it on the source repository (clone_golden_image.md §5)" "$_dbh" "${_pfx:-?}")"
    fi
fi

# =============================================================================
# 5. Machine identity
# =============================================================================
section "Machine identity"
_des3="$(find "$ROOT_DIR" -maxdepth 1 -name '*.des3' -printf '%f ' 2>/dev/null)"
if [ -n "$_des3" ]; then
    _step "  secrets bound to the disk UUID (unreadable on a clone, re-enter): $_des3"
    info  "    01-setup-interview.sh / 00-Setup/weblogic_sec.sh, mos_sec.sh, database_rcu_sec.sh (README: Password Security Concept)"
fi
info "  /etc/machine-id, ssh host keys, /etc/hosts: OS clone tooling (virt-sysprep / cloud-init)"

# =============================================================================
# 6. Intended host-specific places
# =============================================================================
section "Host-specific by design (change after a clone)"
_step "$(printf "  %-26s %s" "WLS_SERVER_FQDN:" "${WLS_SERVER_FQDN:-(not set)}")"
[ "${FORMS_CLIENT_DIST:-false}" = "true" ] && \
    _step "$(printf "  %-26s %s  -> 09-Install/40- --apply" "FORMS_CLIENT_BASE_URL:" "${FORMS_CLIENT_BASE_URL:-}")"
_step "  Nginx server_name + TLS certificate (CN/SAN) -> 08-SSL, 09-Install/05-root_nginx_ssl.sh (root)"
if [ -f "${TNS_ADMIN:-}/tnsnames.ora" ]; then
    _th="$(grep -oiE 'HOST *= *[^)]+' "$TNS_ADMIN/tnsnames.ora" | sed 's/.*= *//' | sort -u | paste -sd' ')"
    _step "$(printf "  %-26s HOST %s" "tnsnames.ora:" "${_th:-?}")"
fi

# =============================================================================
# 7. --apply: SSL off + Coherence 127.0.0.1 (WLST online)
# =============================================================================
if $APPLY && $NEED_WLST; then
    section "Apply (WLST online)"
    if ! load_weblogic_password > /dev/null; then
        fail "WebLogic password not loaded – nothing changed"
    else
        backup_file "$CONFIG_XML" > /dev/null
        _py="$(mktemp /tmp/clone_check_XXXXXX.py)"; chmod 600 "$_py"
        cat > "$_py" <<'WLST_EOF'
import os
connect(os.environ['_IHW_WL_USER'], os.environ['_IHW_WL_PWD'], os.environ['_IHW_WL_URL'])
edit()
startEdit()
for _ihw_ms in ['WLS_FORMS', 'WLS_REPORTS']:
    try:
        cd('/Servers/' + _ihw_ms + '/SSL/' + _ihw_ms)
    except:
        print('IHW:SKIP:' + _ihw_ms)
        continue
    set('Enabled', 'false')
    cd('/Servers/' + _ihw_ms + '/CoherenceMemberConfig/' + _ihw_ms)
    set('UnicastListenAddress', '127.0.0.1')
    print('IHW:SET:' + _ihw_ms)
save()
activate(block='true')
print('IHW:DONE')
disconnect()
WLST_EOF
        _out="$(_IHW_WL_USER="$WL_USER" _IHW_WL_PWD="$INTERNAL_WL_PWD" \
                _IHW_WL_URL="${WL_ADMIN_URL:-t3://${WLS_LISTEN_ADDRESS:-localhost}:${WLS_ADMIN_PORT:-7001}}" \
                "$ORACLE_HOME/oracle_common/common/bin/wlst.sh" "$_py" 2>&1)"
        rm -f "$_py"; INTERNAL_WL_PWD=""
        printf '%s\n' "$_out" >> "${LOG_FILE:-/dev/null}"
        if printf '%s' "$_out" | grep -q 'IHW:DONE'; then
            for _m in $(printf '%s' "$_out" | sed -n 's/^IHW:SET://p'); do
                ok "  $_m: SSL listen port off, Coherence unicast 127.0.0.1"
            done
            APPLIED=true
            info "  Restart both managed servers (stop both first, then start):"
            info "    ./01-Run/startStop.sh stop WLS_REPORTS --apply; ./01-Run/startStop.sh stop WLS_FORMS --apply"
            info "    ./01-Run/startStop.sh start WLS_FORMS --apply; ./01-Run/startStop.sh start WLS_REPORTS --apply"
        else
            fail "WLST failed – see $LOG_FILE (AdminServer running?)"
        fi
    fi
elif $APPLY; then
    ok "Nothing to apply (SSL off, Coherence on 127.0.0.1)"
fi

# =============================================================================
# Result
# =============================================================================
printLine
${APPLIED:-false} && info "Changed by --apply – re-run this check after the restart"
if [ "$FIXES" -eq 0 ]; then
    ok "$(printf "Clone-capable: yes – %s step(s) after cloning (INFO above)" "$STEPS")"
else
    warn "$(printf "Clone-capable: not yet – %s item(s) to fix first, then %s step(s) after cloning" "$FIXES" "$STEPS")"
fi
info "Recipe: 80-FMW-Architecture/clone_golden_image.md §6"
print_summary
exit "$EXIT_CODE"
