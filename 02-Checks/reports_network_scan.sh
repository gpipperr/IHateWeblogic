#!/bin/bash
# =============================================================================
# Script   : reports_network_scan.sh
# Purpose  : Check the Oracle Reports server discovery (UDP multicast) on this
#            host and find the Reports servers in the network:
#              1. own channel/port from rwnetwork.conf, all three files equal?
#              2. multicast prerequisites: route, MULTICAST flag, firewall
#              3. self-test: send one datagram to channel:port and receive it
#                 again on this host (what the Reports server needs at start –
#                 without it: REP-50600); skipped while a Reports server runs
#              4. active scan over a port range with Oracle's DiagServerLocator
#                 (rwdiag -findAll): which servers answer on which port, on
#                 which host; foreign hosts on the own port, same server name
#                 on another host (REP-56040), free ports
#              5. discovery errors in the Reports server logs of the last days
#                 (REP-56040 name already in the network, REP-50600, REP-50125
#                 invalid stream header)
#              6. --set-port N: own port per environment - shows the change of
#                 every rwnetwork.conf; with --apply backup + change
#            Read-only unless --set-port N --apply.
#            Background: 80-FMW-Architecture/reports_server_discovery_multicast.md
# Call     : ./reports_network_scan.sh
#            ./reports_network_scan.sh --ports 14021-14030 --timeout 3
#            ./reports_network_scan.sh --port 14027 --no-scan
#            ./reports_network_scan.sh --set-port 14028 [--apply]
# Options  : --ports A-B     port range for the active scan (default 14021-14030)
#            --port N        check/self-test this port instead of the configured one
#            --timeout N     DiagServerLocator answer timeout per port (default 3)
#            --listen N      passive listen in the self-test (default 10 s)
#            --no-scan       only steps 1-3 (used by 13-oracle_setup_reports.sh)
#            --log-days N    days of the Reports server logs in step 5 (default 7)
#            --set-port N    own multicast port for this environment: show the change
#            --apply         with --set-port: back up and change every rwnetwork.conf
#            --force         with --set-port: change even if another host answers on N
#            --help          Show usage
# Requires : ip, python3 (self-test), Oracle Reports in the domain
#            ($DOMAIN_HOME/reports/bin/reports.sh, DiagServerLocator)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 02-Checks/README.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"

LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m IHateWeblogic_lib.sh not found: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"

check_env_conf "$ENV_CONF" || exit 2
# shellcheck source=../environment.conf
source "$ENV_CONF"

DIAG_LOG_DIR="${DIAG_LOG_DIR:-$ROOT_DIR/log/$(date +%Y%m%d)}"
init_log "$DIAG_LOG_DIR"

# =============================================================================
# Arguments
# =============================================================================

PORT_RANGE="14021-14030"
CHECK_PORT=""
SCAN_TIMEOUT=3
LISTEN_SECS=10
DO_SCAN=true
LOG_DAYS=7
SET_PORT=""
SCAN_DONE=false
SCAN_FOREIGN=""
APPLY=false
FORCE=false

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-16s %s\n" "--ports A-B"  "port range for the active scan (default 14021-14030)"
    printf "  %-16s %s\n" "--port N"     "check/self-test this port instead of the configured one"
    printf "  %-16s %s\n" "--timeout N"  "DiagServerLocator answer timeout per port (default 3)"
    printf "  %-16s %s\n" "--listen N"   "passive listen during the self-test (default 10 s)"
    printf "  %-16s %s\n" "--no-scan"    "only configuration, prerequisites and self-test"
    printf "  %-16s %s\n" "--log-days N" "days of the Reports server logs to check (default 7)"
    printf "  %-16s %s\n" "--set-port N" "own multicast port for this environment (shows the change)"
    printf "  %-16s %s\n" "--apply"      "with --set-port: back up and change every rwnetwork.conf"
    printf "  %-16s %s\n" "--force"      "with --set-port: change even if another host answers on N"
    printf "  %-16s %s\n" "--help"       "show this help"
    printf "\nRead-only unless --set-port N --apply. Background: 80-FMW-Architecture/reports_server_discovery_multicast.md\n"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ports)    PORT_RANGE="$2"; shift 2 ;;
        --port)     CHECK_PORT="$2"; shift 2 ;;
        --timeout)  SCAN_TIMEOUT="$2"; shift 2 ;;
        --listen)   LISTEN_SECS="$2"; shift 2 ;;
        --no-scan)  DO_SCAN=false; shift ;;
        --log-days) LOG_DAYS="$2"; shift 2 ;;
        --set-port) SET_PORT="$2"; shift 2 ;;
        --apply)    APPLY=true; shift ;;
        --force)    FORCE=true; shift ;;
        --help|-h)  _usage ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 2 ;;
    esac
done
[[ "$LOG_DAYS" =~ ^[0-9]+$ ]] || { printf "\033[31mERROR\033[0m --log-days N\n" >&2; exit 2; }
if [ -n "$SET_PORT" ] && { ! [[ "$SET_PORT" =~ ^[0-9]+$ ]] || [ "$SET_PORT" -lt 1024 ] || [ "$SET_PORT" -gt 65535 ]; }; then
    printf "\033[31mERROR\033[0m --set-port: a port 1024-65535 (Oracle range for Reports: 14021-14030)\n" >&2; exit 2
fi
$APPLY && [ -z "$SET_PORT" ] && { printf "\033[31mERROR\033[0m --apply only with --set-port N\n" >&2; exit 2; }

printLine
printf "\n\033[1m  IHateWeblogic – Reports Network Scan (multicast discovery)\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"             | tee -a "$LOG_FILE"
printf "  DOMAIN_HOME : %s\n" "${DOMAIN_HOME:-?}"             | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"                     | tee -a "$LOG_FILE"
printLine

# =============================================================================
# 1. Own discovery configuration (three rwnetwork.conf files)
# =============================================================================

section "Discovery Configuration (rwnetwork.conf)"

_COMP="$DOMAIN_HOME/config/fmwconfig/components"
_mc_attr() { sed -nE "s/.*<multicast[^>]*${2}=\"([^\"]*)\".*/\1/p" "$1" 2>/dev/null | head -1; }

# every rwnetwork.conf of the domain (tools instance, every Reports server
# instance, the in-process / servlet configuration of every managed server -
# 12c reports_12.2.1 and 14c reports_14.1.2); template dirs (mbeans) skipped.
# 2026-11-27: before, the list came from environment.conf + a fixed 14c path
# and missed further server instances.
declare -a NET_FILES=()
mapfile -t NET_FILES < <(find "$DOMAIN_HOME/config/fmwconfig" -name rwnetwork.conf -type f 2>/dev/null \
    | grep -v -e '/mbeans/' -e '/templates\{0,1\}/' | LC_ALL=C sort)
# own Reports server names (standalone instances + <server> of rwservlet.properties)
SERVER_INSTS="$( { for _d in "$_COMP"/ReportsServerComponent/*/rwserver.conf; do
        [ -f "$_d" ] && basename "$(dirname "$_d")"; done
    sed -n 's:.*<server>\([^<]*\)</server>.*:\1:p' "$DOMAIN_HOME"/config/fmwconfig/servers/*/applications/reports_*/configuration/rwservlet.properties 2>/dev/null
  } | sort -u | xargs)"
[ ${#NET_FILES[@]} -eq 0 ] && warn "No rwnetwork.conf below $DOMAIN_HOME/config/fmwconfig – Reports not configured in this domain?"

OWN_CHANNEL="" OWN_PORT="" _diff=false
for _f in "${NET_FILES[@]}"; do
    _rel="${_f#"$DOMAIN_HOME"/config/fmwconfig/}"
    if [ ! -f "$_f" ]; then
        info "$(printf "%-70s %s" "$_rel" "(not present yet)")"
        continue
    fi
    _ch="$(_mc_attr "$_f" channel)"; _po="$(_mc_attr "$_f" port)"
    if [ -z "$_po" ]; then
        warn "$(printf "%-70s %s" "$_rel" "no <multicast port=...> – discovery disabled/naming service?")"
        continue
    fi
    printf "  %-70s %s:%s\n" "$_rel" "${_ch:-?}" "$_po" | tee -a "$LOG_FILE"
    if [ -z "$OWN_PORT" ]; then
        OWN_CHANNEL="$_ch"; OWN_PORT="$_po"
    elif [ "$_ch" != "$OWN_CHANNEL" ] || [ "$_po" != "$OWN_PORT" ]; then
        _diff=true
    fi
done
if $_diff; then
    fail "The rwnetwork.conf files use different channels/ports – all participants must use the same"
    info "  Fix: 09-Install/13-oracle_setup_reports.sh --apply (sets REPORTS_BROADCAST_PORT everywhere)"
elif [ -n "$OWN_PORT" ]; then
    ok "All rwnetwork.conf use ${OWN_CHANNEL}:${OWN_PORT}"
fi
OWN_CHANNEL="${OWN_CHANNEL:-228.5.6.7}"
OWN_PORT="${CHECK_PORT:-${OWN_PORT:-${REPORTS_BROADCAST_PORT:-14021}}}"
[ -n "$CHECK_PORT" ] && info "Port for the checks: ${OWN_PORT} (--port)"
[ -n "$SERVER_INSTS" ] && info "Own Reports server(s): $SERVER_INSTS"

# =============================================================================
# 2. Multicast prerequisites
# =============================================================================

section "Multicast Prerequisites"

_mc_dev="$(ip -o route get "$OWN_CHANNEL" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
if [ -z "$_mc_dev" ]; then
    fail "No route to multicast group $OWN_CHANNEL – Reports discovery will fail (REP-50600)"
    info "  As root: ip route add 224.0.0.0/4 dev <LAN interface>  (persistent: nmcli +ipv4.routes)"
elif [ "$_mc_dev" = "lo" ]; then
    warn "Multicast group $OWN_CHANNEL is routed via 'lo' – check the default route / LAN interface"
else
    ok "Multicast route: $OWN_CHANNEL via $_mc_dev"
    if ip -br link show dev "$_mc_dev" 2>/dev/null | grep -q 'MULTICAST'; then
        ok "Interface $_mc_dev has the MULTICAST flag"
    else
        fail "Interface $_mc_dev has no MULTICAST flag – Reports discovery will fail (REP-50600)"
        info "  As root: ip link set dev $_mc_dev multicast on"
    fi
    _v6="$(cat "/proc/sys/net/ipv6/conf/$_mc_dev/disable_ipv6" 2>/dev/null)"
    if [ -n "$_v6" ] && [ "$_v6" != "1" ]; then
        warn "IPv6 still active on $_mc_dev (disable_ipv6=$_v6) – JVMs may bind via IPv6"
        info "  Fix: 09-Install/01-root_os_baseline.sh --apply (per-interface IPv6 + nmcli)"
    fi
fi

# Firewall: the Reports server must RECEIVE the multicast packets on the port
if systemctl is-active --quiet firewalld 2>/dev/null; then
    if sudo -n true 2>/dev/null; then
        if sudo -n firewall-cmd --query-port="${OWN_PORT}/udp" > /dev/null 2>&1; then
            ok "Firewall: ${OWN_PORT}/udp open"
        else
            fail "Firewall: ${OWN_PORT}/udp NOT open – Reports server will stop with REP-50600"
            info "  As root: firewall-cmd --permanent --add-port=${OWN_PORT}/udp && firewall-cmd --reload"
        fi
    else
        warn "firewalld is active – check as root: firewall-cmd --query-port=${OWN_PORT}/udp"
    fi
else
    ok "firewalld not active – no UDP rule needed"
fi

# =============================================================================
# 3. Self-test: send + receive on channel:port (+ passive listen)
# =============================================================================

section "Multicast Self-Test (${OWN_CHANNEL}:${OWN_PORT})"

_PY="$(command -v python3 || command -v /usr/libexec/platform-python)"
if pgrep -f "rwserver server=" > /dev/null 2>&1; then
    # A running Reports server would read the test datagram and log
    # "REP-50125 StreamCorruptedException: invalid stream header" – and a
    # running server already proves the reception.
    ok "Reports server process running on this host – reception works, self-test skipped"
elif [ -z "$_PY" ]; then
    warn "python3 not found – self-test skipped"
else
    _mc_py="$(mktemp --suffix=.py)"
    cat > "$_mc_py" << 'MC_EOF'
import socket, struct, sys, time
grp, port, listen = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
r = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
r.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    r.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
except (AttributeError, OSError):
    pass
r.bind(('', port))
r.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
             struct.pack('4sl', socket.inet_aton(grp), socket.INADDR_ANY))
r.settimeout(0.5)
w = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
w.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
w.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)
token = ('IHW-MC-SELFTEST-%d' % time.time()).encode()
w.sendto(token, (grp, port))
own, senders, end = False, {}, time.time() + max(listen, 3)
while time.time() < end:
    try:
        data, addr = r.recvfrom(65535)
    except socket.timeout:
        continue
    if data == token:
        own = True
    else:
        senders[addr[0]] = senders.get(addr[0], 0) + 1
print('SELF %s' % ('ok' if own else 'missing'))
for ip, n in sorted(senders.items()):
    print('SENDER %s %d' % (ip, n))
MC_EOF
    _mc_out="$("$_PY" -I "$_mc_py" "$OWN_CHANNEL" "$OWN_PORT" "$LISTEN_SECS" 2>&1)"
    rm -f "$_mc_py"
    if printf '%s\n' "$_mc_out" | grep -q '^SELF ok'; then
        ok "Packet to ${OWN_CHANNEL}:${OWN_PORT} sent and received on this host"
    elif printf '%s\n' "$_mc_out" | grep -q '^SELF missing'; then
        fail "Own packet to ${OWN_CHANNEL}:${OWN_PORT} NOT received – Reports server will stop with REP-50600"
        info "  Check: firewall (${OWN_PORT}/udp), IPv6 on the interface, multicast route"
    else
        warn "Self-test could not run: $(printf '%s' "$_mc_out" | tail -1)"
    fi
    _own_ips=" $(hostname -I 2>/dev/null) "
    while read -r _tag _ip _n; do
        [ "$_tag" = "SENDER" ] || continue
        case "$_own_ips" in
            *" $_ip "*) info "  Packets from this host ($_ip) – own Reports server starting/searching" ;;
            *) warn "Foreign sender $_ip on ${OWN_CHANNEL}:${OWN_PORT} ($_n packets) – another environment on this port?" ;;
        esac
    done <<< "$_mc_out"
    info "  Passive listen ${LISTEN_SECS} s – Reports servers send only while starting; use the active scan below"
fi

# =============================================================================
# 4. Active scan with DiagServerLocator (rwdiag -findAll) over a port range
# =============================================================================

if $DO_SCAN; then
    section "Active Scan – Reports servers per port (DiagServerLocator)"

    _rsh="$DOMAIN_HOME/reports/bin/reports.sh"
    _java="$ORACLE_HOME/oracle_common/jdk/bin/java"
    _tpl="${NET_FILES[0]}"
    if [ ! -f "$_rsh" ] || [ ! -x "$_java" ] || [ ! -f "$_tpl" ]; then
        warn "Scan not possible – need $_rsh, $_java and a rwnetwork.conf template"
    else
        # DiagServerLocator needs the complete reports.sh environment
        # (REPORTS_CLASSPATH, LD_LIBRARY_PATH, ...) - with the class path alone
        # it fails with InvocationTargetException (2026-10-15). Run it in a
        # subshell that sources reports.sh, like rwdiag.sh does.
        _p_from="${PORT_RANGE%-*}"; _p_to="${PORT_RANGE#*-}"
        info "Ports ${_p_from}-${_p_to}, channel ${OWN_CHANNEL}, timeout ${SCAN_TIMEOUT} s per port (a few seconds each)"
        _own_names=" $(_get_hostname) $(hostname -s 2>/dev/null) $(hostname -f 2>/dev/null) $(hostname -I 2>/dev/null) "
        _free="" _found_any=false _scan_fail=false; SCAN_DONE=true
        printf "\n  %-7s %-24s %-8s %s\n" "Port" "Name" "Type" "Host" | tee -a "$LOG_FILE"
        printf "  %-7s %-24s %-8s %s\n" "-------" "------------------------" "--------" "----------------------------" | tee -a "$LOG_FILE"
        for (( _p=_p_from; _p<=_p_to; _p++ )); do
            _tmp="$(mktemp -d)"
            sed -E "s/(<multicast[^>]*port=\")[0-9]*/\1${_p}/; s/(<multicast[^>]*channel=\")[^\"]*/\1${OWN_CHANNEL}/" \
                "$_tpl" > "$_tmp/rwnetwork.conf"
            _out="$( ( export DOMAIN_HOME; . "$_rsh" > /dev/null 2>&1
                       COMPONENT_CONFIG_PATH="$_tmp" timeout $(( SCAN_TIMEOUT + 30 )) "$_java" \
                           -DORACLE_HOME="$ORACLE_HOME" -classpath "$REPORTS_CLASSPATH" \
                           oracle.reports.utility.DiagServerLocator -findAll -timeout "$SCAN_TIMEOUT" ) < /dev/null 2>&1 )"
            rm -rf "$_tmp"
            _lines="$(printf '%s\n' "$_out" | grep -E '^\([0-9]+\) Name = ')"
            if [ -z "$_lines" ]; then
                if printf '%s' "$_out" | grep -q 'REP-50503'; then
                    printf "  %-7s %s\n" "$_p" "-" | tee -a "$LOG_FILE"
                    _free="$_free $_p"
                else
                    printf "  %-7s %s\n" "$_p" "? $(printf '%s' "$_out" | grep -E 'REP-|Exception' | head -1)" | tee -a "$LOG_FILE"
                    _scan_fail=true
                fi
                continue
            fi
            _found_any=true
            while IFS= read -r _l; do
                _nm="$(printf '%s' "$_l" | sed -n 's/.*Name = \([^ ]*\).*/\1/p')"
                _ty="$(printf '%s' "$_l" | sed -n 's/.*Type = \([^ ]*\).*/\1/p')"
                _ho="$(printf '%s' "$_l" | sed -n 's/.*Host = \([^ ]*\).*/\1/p')"
                _mine=false
                case "$_own_names" in *" $_ho "*|*" ${_ho%%.*} "*) _mine=true ;; esac
                printf "  %-7s %-24s %-8s %s%s\n" "$_p" "$_nm" "$_ty" "$_ho" "$($_mine && printf '  (this host)')" | tee -a "$LOG_FILE"
                $_mine || SCAN_FOREIGN="$SCAN_FOREIGN $_p:$_nm@$_ho"
                if [ "$_p" = "$OWN_PORT" ] && ! $_mine; then
                    warn "  Port $_p (own broadcast port) is used by $_nm on $_ho – environments see each other"
                fi
                for _s in $SERVER_INSTS; do
                    if [ "$_nm" = "$_s" ] && ! $_mine; then
                        fail "  Server name '$_nm' also exists on $_ho (port $_p) – same name on the same port gives REP-56040"
                    fi
                done
            done <<< "$_lines"
        done
        printf "\n" | tee -a "$LOG_FILE"
        $_found_any || info "No Reports server answered in the range"
        $_scan_fail && warn "Some ports could not be scanned – see the '?' lines"
        if [ -n "$_free" ]; then
            info "Ports without any answer:$_free"
            info "  (only servers RUNNING now answer – a port can still belong to a stopped environment)"
        fi
        unset _p _p_from _p_to _tmp _out _lines _l _nm _ty _ho _mine _s _free _found_any _scan_fail _own_names
    fi
fi

# =============================================================================
# 5. Discovery errors in the Reports server logs (last LOG_DAYS days)
# =============================================================================

section "Discovery Errors in the Reports Server Logs (last ${LOG_DAYS} days)"

_lim="$(date -d "-${LOG_DAYS} days" +%Y-%m-%d)"
mapfile -t _rlogs < <(find "$DOMAIN_HOME/servers" "$DOMAIN_HOME/system_components" -name 'rwserver_diagnostic*.log' -type f 2>/dev/null | LC_ALL=C sort)
if [ ${#_rlogs[@]} -eq 0 ]; then
    info "No rwserver_diagnostic*.log below $DOMAIN_HOME/servers"
else
    _n56040=0
    for _f in "${_rlogs[@]}"; do
        # REP-56040 = server name already in the network, REP-50600 = discovery
        # (multicast) not possible, REP-50125 only with the stream header of a
        # foreign datagram on the port
        _hits="$(grep -E 'REP-56040|REP-50600|REP-50125.*(StreamCorrupted|invalid stream header)' "$_f" 2>/dev/null \
                 | awk -v lim="$_lim" 'match($0, /^\[[0-9]{4}-[0-9]{2}-[0-9]{2}/) { d = substr($0, 2, 10); if (d >= lim) print }')"
        [ -n "$_hits" ] || continue
        _rel="${_f#"$DOMAIN_HOME"/}"
        while IFS=';' read -r _d _code _cnt; do
            printf "  %-60s %s %-9s %s\n" "$_rel" "$_d" "$_code" "${_cnt}x" | tee -a "$LOG_FILE"
            [ "$_code" = "REP-56040" ] && _n56040=$((_n56040 + _cnt))
        done < <(printf '%s\n' "$_hits" | awk '{ d = substr($0, 2, 10); c = ($0 ~ /REP-56040/) ? "REP-56040" : ($0 ~ /REP-50600/) ? "REP-50600" : "REP-50125"; n[d ";" c]++ }
                                            END { for (k in n) print k ";" n[k] }' | sort)
        info "  last: $(printf '%s\n' "$_hits" | tail -1 | cut -c1-220)"
    done
    if [ "$_n56040" -gt 0 ]; then
        fail "REP-56040 ${_n56040}x: a Reports server with the same name answers on the same multicast port (other environment, e.g. QS on ${OWN_PORT})"
        info "  Fix: own port per environment – see the scan above, then --set-port N --apply (+ the other environment)"
    else
        ok "No REP-56040 / REP-50600 / stream header errors in ${#_rlogs[@]} Reports server log(s)"
    fi
fi
unset _lim _rlogs _f _hits _rel _d _code _cnt _n56040

# =============================================================================
# 6. --set-port N: own multicast port for this environment
# =============================================================================

if [ -n "$SET_PORT" ]; then
    section "Change the Multicast Port ${OWN_PORT} -> ${SET_PORT}$($APPLY || printf ' (dry run)')"
    _block=false
    if [ "$SET_PORT" = "$OWN_PORT" ] && ! $_diff; then
        ok "All rwnetwork.conf already use port ${SET_PORT} – nothing to do"
        _block=true
    fi
    if ! $_block && $SCAN_DONE; then
        _busy="$(printf '%s\n' $SCAN_FOREIGN | awk -F: -v p="$SET_PORT" '$1 == p {print $2}' | paste -sd' ' -)"
        if [ -n "$_busy" ] && ! $FORCE; then
            fail "Port ${SET_PORT} is used by another host: ${_busy} – choose a free port (see the scan) or --force"
            _block=true
        elif [ -n "$_busy" ]; then
            warn "Port ${SET_PORT} is used by ${_busy} – changed anyway (--force)"
        fi
    elif ! $_block; then
        warn "No scan in this run (--no-scan) – the new port ${SET_PORT} was not checked for other environments"
    fi
    if ! $_block; then
        for _f in "${NET_FILES[@]}"; do
            _rel="${_f#"$DOMAIN_HOME"/config/fmwconfig/}"
            _po="$(_mc_attr "$_f" port)"
            if [ -z "$_po" ]; then
                warn "$(printf "%-70s %s" "$_rel" "no <multicast port=...> – left as it is")"
                continue
            fi
            if [ "$_po" = "$SET_PORT" ]; then
                ok "$(printf "%-70s %s" "$_rel" "already ${SET_PORT}")"
                continue
            fi
            if ! $APPLY; then
                info "$(printf "%-70s %s -> %s" "$_rel" "$_po" "$SET_PORT")"
                continue
            fi
            backup_file "$_f" || continue
            sed -i -E "s/(<multicast[^>]*port=\")[0-9]*/\1${SET_PORT}/" "$_f"
            if [ "$(_mc_attr "$_f" port)" = "$SET_PORT" ]; then
                ok "$(printf "%-70s %s -> %s" "$_rel" "$_po" "$SET_PORT")"
            else
                fail "$(printf "%-70s %s" "$_rel" "not changed – restore: cp -p $LAST_BACKUP $_f")"
            fi
        done
        if $APPLY; then
            info "Takes effect at the next start: restart the Reports server(s) ${SERVER_INSTS:-} and WLS_REPORTS"
            info "  (01-Run/startStop.sh stop/start, or the cookbook of this host)"
            info "Every OTHER environment on ${OWN_PORT} needs its own port too – same procedure there"
            pgrep -f "rwserver server=" > /dev/null 2>&1 && warn "A Reports server runs now – it keeps the old port ${OWN_PORT} until its restart"
        else
            info "Dry run – add --apply to back up and change the files"
        fi
    fi
    unset _block _busy _f _rel _po
fi

printLine
print_summary
exit "$EXIT_CODE"
