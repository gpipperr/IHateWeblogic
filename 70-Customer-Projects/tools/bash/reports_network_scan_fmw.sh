#!/bin/bash
# =============================================================================
# Script   : reports_network_scan_fmw.sh
# Purpose  : Oracle Reports server discovery (UDP multicast) of this domain and
#            the Reports servers in the network - standalone version of
#            02-Checks/reports_network_scan.sh for customer hosts (12.2.1.x and
#            14.1.2), no IHateWeblogic library, no environment.conf:
#              1. every rwnetwork.conf of the domain: channel / port, all equal?
#              2. multicast prerequisites: route, MULTICAST flag, firewalld
#              3. self-test: send one datagram to channel:port and receive it
#                 on this host (what the Reports server needs at start -
#                 without it REP-50600); skipped while a Reports server runs
#              4. active scan over a port range with Oracle's DiagServerLocator
#                 (rwdiag -findAll): which servers answer on which port, on
#                 which host; foreign hosts on the own port, the same server
#                 name on another host (REP-56040), free ports
#              5. discovery errors in the Reports server logs (REP-56040,
#                 REP-50600, REP-50125 invalid stream header)
#              6. --set-port N: own port per environment - shows the change of
#                 every rwnetwork.conf; --apply backs up (.bak_<ts>) and changes
#            Typical case: production and test / QS use the same default port
#            and the same server names - the Reports server starts and stops
#            again with REP-56040 ("already exists in the network").
#            READ-ONLY unless --set-port N --apply.
# Call     : ./reports_network_scan_fmw.sh [-o ORACLE_HOME] [-d DOMAIN_HOME] [-t OUTDIR]
#                [--ports A-B] [--port N] [--timeout N] [--listen N] [--no-scan]
#                [--log-days N] [--set-port N [--apply] [--force]]
#              -o / -d      default: environment, running WebLogic,
#                           domain-registry.xml, /app/oracle/mw, /u01/app/oracle/fmw ...
#              -t           directory of the log file (default /tmp)
#              --ports A-B  port range of the scan (default 14021-14030, Oracle's range)
#              --port N     self-test this port instead of the configured one
#              --timeout N  DiagServerLocator answer timeout per port (default 3)
#              --listen N   passive listen in the self-test (default 10 s)
#              --no-scan    steps 1-3 + 5 only
#              --log-days N days of Reports server logs (default 7)
#              --set-port N own multicast port: show the change of every rwnetwork.conf
#              --apply      with --set-port: back up + change (restart Reports after it)
#              --force      with --set-port: change even if another host answers on N
# Runs as  : the software owner (oracle), no root needed (firewall check as root)
# Output   : stdout + <OUTDIR>/reports_network_scan_<host>_<yyyymmdd_hhmmss>.log
# Exit     : 0 = ok, 1 = warnings, 2 = failures
# Doc      : 70-Customer-Projects/tools/README.md,
#            80-FMW-Architecture/reports_server_discovery_multicast.md
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================
set -u
VERSION="2026-11-27.1"   # bump on every change

_IHWT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ihw_tools_lib.sh
. "$_IHWT_DIR/ihw_tools_lib.sh" || { printf 'ihw_tools_lib.sh missing next to %s\n' "$0" >&2; exit 2; }

OH="${ORACLE_HOME:-}"; DH="${DOMAIN_HOME:-}"; OUTBASE="/tmp"
PORT_RANGE="14021-14030"; CHECK_PORT=""; SCAN_TIMEOUT=3; LISTEN_SECS=10; DO_SCAN=true
LOG_DAYS=7; SET_PORT=""; APPLY=false; FORCE=false
while [ $# -gt 0 ]; do
    case "$1" in
        -o) OH="${2:-}"; shift ;;
        -d) DH="${2:-}"; shift ;;
        -t) OUTBASE="${2:-/tmp}"; shift ;;
        --ports) PORT_RANGE="${2:-}"; shift ;;
        --port) CHECK_PORT="${2:-}"; shift ;;
        --timeout) SCAN_TIMEOUT="${2:-3}"; shift ;;
        --listen) LISTEN_SECS="${2:-10}"; shift ;;
        --no-scan) DO_SCAN=false ;;
        --log-days) LOG_DAYS="${2:-7}"; shift ;;
        --set-port) SET_PORT="${2:-}"; shift ;;
        --apply) APPLY=true ;;
        --force) FORCE=true ;;
        -h|--help) sed -n '2,47p' "$0"; printf 'Version: %s\n' "$VERSION"; exit 0 ;;
        -V|--version) printf '%s\n' "$VERSION"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
[[ "$LOG_DAYS" =~ ^[0-9]+$ ]] || { printf -- '--log-days N\n' >&2; exit 2; }
[[ "$PORT_RANGE" =~ ^[0-9]+-[0-9]+$ ]] || { printf -- '--ports A-B\n' >&2; exit 2; }
if [ -n "$SET_PORT" ] && { ! [[ "$SET_PORT" =~ ^[0-9]+$ ]] || [ "$SET_PORT" -lt 1024 ] || [ "$SET_PORT" -gt 65535 ]; }; then
    printf -- '--set-port: a port 1024-65535 (Oracle range for Reports: 14021-14030)\n' >&2; exit 2
fi
$APPLY && [ -z "$SET_PORT" ] && { printf -- '--apply only with --set-port N\n' >&2; exit 2; }

LOG="$OUTBASE/reports_network_scan_$(hostname -s 2>/dev/null || hostname)_$(date +%Y%m%d_%H%M%S).log"
: > "$LOG" 2>/dev/null || LOG=/dev/null
N_WARN=0; N_FAIL=0
_p()   { printf '%s\n' "$*" | tee -a "$LOG"; }
ok()   { printf '\033[32m  OK  \033[0m %s\n' "$*"; printf '  OK   %s\n' "$*" >> "$LOG"; }
warn() { N_WARN=$((N_WARN + 1)); printf '\033[33m WARN \033[0m %s\n' "$*"; printf ' WARN  %s\n' "$*" >> "$LOG"; }
fail() { N_FAIL=$((N_FAIL + 1)); printf '\033[31m FAIL \033[0m %s\n' "$*"; printf ' FAIL  %s\n' "$*" >> "$LOG"; }
info() { printf '       %s\n' "$*" | tee -a "$LOG"; }
section() { _p ""; _p "=== $* ==="; }

# --- locate ORACLE_HOME / DOMAIN_HOME (as java_check_fmw.sh) --------------------
if [ -z "$OH" ] || [ ! -d "$OH/OPatch" ]; then
    OH="$(ps -eo args= 2>/dev/null | sed -n 's/.*-Dweblogic\.home=\([^ ]*\)\/wlserver\/server.*/\1/p' | head -1)"
    if [ ! -d "${OH:-/x}/OPatch" ]; then
        OH=""
        for c in /app/oracle/mw /oracle/product/mw /u01/app/oracle/fmw /u01/oracle/fmw \
                 /u01/app/oracle/middleware /u01/oracle/middleware; do
            [ -d "$c/OPatch" ] && { OH="$c"; break; }
        done
    fi
fi
while [ "${OH%/}" != "$OH" ] && [ "$OH" != / ]; do OH="${OH%/}"; done
if [ -z "$DH" ] && [ -r "${OH:-/x}/domain-registry.xml" ]; then
    DH="$(sed -n 's/.*location="\([^"]*\)".*/\1/p' "$OH/domain-registry.xml" | head -1)"
fi
[ -z "$DH" ] && DH="$(ps -eo args= 2>/dev/null | sed -n 's/.*-Dweblogic\.RootDirectory=\([^ ]*\).*/\1/p' | head -1)"
while [ "${DH%/}" != "$DH" ] && [ "$DH" != / ]; do DH="${DH%/}"; done
[ -d "${DH:-/x}/config" ] || { printf 'DOMAIN_HOME not found - use -d\n' >&2; exit 2; }

_p "reports_network_scan_fmw.sh $VERSION - $(date '+%Y-%m-%d %H:%M:%S')"
_p "Host        : $(hostname -f 2>/dev/null || hostname)"
_p "ORACLE_HOME : ${OH:-<not found>}"
_p "DOMAIN_HOME : $DH"
_p "Log         : $LOG"

# =============================================================================
# 1. Discovery configuration - every rwnetwork.conf of the domain
# =============================================================================
section "1. Discovery configuration (rwnetwork.conf)"
_mc_attr() { sed -nE "s/.*<multicast[^>]*${2}=\"([^\"]*)\".*/\1/p" "$1" 2>/dev/null | head -1; }
mapfile -t NET_FILES < <(find "$DH/config/fmwconfig" -name rwnetwork.conf -type f 2>/dev/null \
    | grep -v -e '/mbeans/' -e '/templates\{0,1\}/' | LC_ALL=C sort)
# own Reports server names: standalone instances + <server> of the servlet (ihwt_rs_list)
SERVER_INSTS="$(ihwt_rs_list "$DH" | awk -F';' '$1 != "-" && $1 != "in-process" {print $1}' | sort -u | xargs)"
OWN_CHANNEL=""; OWN_PORT=""; _diff=false
[ ${#NET_FILES[@]} -eq 0 ] && fail "no rwnetwork.conf below $DH/config/fmwconfig - Reports not configured in this domain?"
for _f in "${NET_FILES[@]}"; do
    _rel="${_f#"$DH"/config/fmwconfig/}"
    _ch="$(_mc_attr "$_f" channel)"; _po="$(_mc_attr "$_f" port)"
    if [ -z "$_po" ]; then warn "$(printf '%-70s %s' "$_rel" "no <multicast port=...> - discovery off / naming service?")"; continue; fi
    _p "$(printf '  %-70s %s:%s' "$_rel" "${_ch:-?}" "$_po")"
    if [ -z "$OWN_PORT" ]; then OWN_CHANNEL="$_ch"; OWN_PORT="$_po"
    elif [ "$_ch" != "$OWN_CHANNEL" ] || [ "$_po" != "$OWN_PORT" ]; then _diff=true; fi
done
if $_diff; then
    fail "the rwnetwork.conf files use different channels / ports - every participant needs the same (fix: --set-port N --apply)"
elif [ -n "$OWN_PORT" ]; then
    ok "all ${#NET_FILES[@]} rwnetwork.conf use ${OWN_CHANNEL}:${OWN_PORT}"
    [ "$OWN_PORT" = 14021 ] && info "14021 = Oracle's default port - every untouched environment in the network uses it too"
fi
OWN_CHANNEL="${OWN_CHANNEL:-228.5.6.7}"
OWN_PORT="${CHECK_PORT:-${OWN_PORT:-14021}}"
[ -n "$CHECK_PORT" ] && info "port for the checks: $OWN_PORT (--port)"
info "own Reports server(s): ${SERVER_INSTS:-none}"

# =============================================================================
# 2. Multicast prerequisites
# =============================================================================
section "2. Multicast prerequisites"
_mc_dev="$(ip -o route get "$OWN_CHANNEL" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
if [ -z "$_mc_dev" ]; then
    fail "no route to the multicast group $OWN_CHANNEL - Reports discovery fails (REP-50600)"
    info "  as root: ip route add 224.0.0.0/4 dev <LAN interface> (persistent: nmcli +ipv4.routes)"
elif [ "$_mc_dev" = lo ]; then
    warn "multicast group $OWN_CHANNEL is routed via 'lo' - check the default route / LAN interface"
else
    ok "multicast route: $OWN_CHANNEL via $_mc_dev"
    if ip -br link show dev "$_mc_dev" 2>/dev/null | grep -q MULTICAST; then ok "interface $_mc_dev has the MULTICAST flag"
    else fail "interface $_mc_dev has no MULTICAST flag (as root: ip link set dev $_mc_dev multicast on)"; fi
fi
if systemctl is-active --quiet firewalld 2>/dev/null; then
    _q="$(firewall-cmd --query-port="${OWN_PORT}/udp" 2>&1)"
    case "$_q" in
        yes) ok "firewalld: ${OWN_PORT}/udp open" ;;
        no)  fail "firewalld: ${OWN_PORT}/udp NOT open - the Reports server stops with REP-50600"
             info "  as root: firewall-cmd --permanent --add-port=${OWN_PORT}/udp && firewall-cmd --reload" ;;
        *)   warn "firewalld active - not readable without root; as root: firewall-cmd --query-port=${OWN_PORT}/udp" ;;
    esac
else
    ok "firewalld not active - no UDP rule needed"
fi

# =============================================================================
# 3. Self-test: send + receive on channel:port (+ passive listen)
# =============================================================================
section "3. Multicast self-test (${OWN_CHANNEL}:${OWN_PORT})"
_PY="$(command -v python3 || command -v /usr/libexec/platform-python)"
if pgrep -f "rwserver.* server=" > /dev/null 2>&1; then
    # a running Reports server would read the test datagram (REP-50125 invalid
    # stream header) - and a running server proves the reception anyway
    ok "a Reports server runs on this host - reception works, self-test skipped"
elif [ -z "$_PY" ]; then
    warn "python3 not found - self-test skipped"
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
r.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, struct.pack('4sl', socket.inet_aton(grp), socket.INADDR_ANY))
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
    if printf '%s\n' "$_mc_out" | grep -q '^SELF ok'; then ok "packet to ${OWN_CHANNEL}:${OWN_PORT} sent and received on this host"
    elif printf '%s\n' "$_mc_out" | grep -q '^SELF missing'; then
        fail "own packet to ${OWN_CHANNEL}:${OWN_PORT} NOT received - the Reports server stops with REP-50600 (firewall, IPv6, route)"
    else warn "self-test could not run: $(printf '%s' "$_mc_out" | tail -1)"; fi
    _own_ips=" $(hostname -I 2>/dev/null) "
    while read -r _tag _ip _n; do
        [ "$_tag" = SENDER ] || continue
        case "$_own_ips" in
            *" $_ip "*) info "  packets from this host ($_ip) - own Reports server starting / searching" ;;
            *) warn "foreign sender $_ip on ${OWN_CHANNEL}:${OWN_PORT} ($_n packets) - another environment on this port?" ;;
        esac
    done <<< "$_mc_out"
    info "  passive listen ${LISTEN_SECS} s - Reports servers send only while starting; the active scan below asks them"
fi

# =============================================================================
# 4. Active scan with DiagServerLocator over a port range
# =============================================================================
SCAN_DONE=false; SCAN_FOREIGN=""
if $DO_SCAN; then
    section "4. Active scan - Reports servers per port (DiagServerLocator)"
    _rsh="$DH/reports/bin/reports.sh"; _java="$OH/oracle_common/jdk/bin/java"; _tpl="${NET_FILES[0]:-}"
    if [ ! -f "$_rsh" ] || [ ! -x "$_java" ] || [ ! -f "$_tpl" ]; then
        warn "scan not possible - need $_rsh, $_java and one rwnetwork.conf"
    else
        # DiagServerLocator needs the whole reports.sh environment (class path,
        # LD_LIBRARY_PATH); rwdiag.sh always reads the tools instance - so a
        # copy of rwnetwork.conf with the scanned port in a temp dir becomes
        # COMPONENT_CONFIG_PATH of one subshell per port
        _p_from="${PORT_RANGE%-*}"; _p_to="${PORT_RANGE#*-}"; SCAN_DONE=true
        info "ports ${_p_from}-${_p_to}, channel ${OWN_CHANNEL}, timeout ${SCAN_TIMEOUT} s per port"
        _own_names=" $(hostname 2>/dev/null) $(hostname -s 2>/dev/null) $(hostname -f 2>/dev/null) $(hostname -I 2>/dev/null) "
        _free=""; _found_any=false; _scan_fail=false
        _p ""; _p "$(printf '  %-7s %-24s %-8s %s' Port Name Type Host)"
        _p "$(printf '  %-7s %-24s %-8s %s' ------- ------------------------ -------- ----------------------------)"
        for (( _po=_p_from; _po<=_p_to; _po++ )); do
            _tmp="$(mktemp -d)"
            sed -E "s/(<multicast[^>]*port=\")[0-9]*/\1${_po}/; s/(<multicast[^>]*channel=\")[^\"]*/\1${OWN_CHANNEL}/" "$_tpl" > "$_tmp/rwnetwork.conf"
            # set +u: reports.sh reads unset variables - under set -u the subshell ends silently
            # shellcheck disable=SC1090
            _out="$( ( set +u; export DOMAIN_HOME="$DH" ORACLE_HOME="$OH"; . "$_rsh" > /dev/null 2>&1
                       COMPONENT_CONFIG_PATH="$_tmp" timeout $(( SCAN_TIMEOUT + 30 )) "$_java" -DORACLE_HOME="$OH" \
                           -classpath "${REPORTS_CLASSPATH:-}" oracle.reports.utility.DiagServerLocator -findAll -timeout "$SCAN_TIMEOUT" ) < /dev/null 2>&1 )"
            rm -rf "${_tmp:?}"
            _lines="$(printf '%s\n' "$_out" | grep -E '^\([0-9]+\) Name = ')"
            if [ -z "$_lines" ]; then
                if printf '%s' "$_out" | grep -q 'REP-50503'; then _p "$(printf '  %-7s %s' "$_po" -)"; _free="$_free $_po"
                else _p "$(printf '  %-7s %s' "$_po" "? $(printf '%s' "$_out" | grep -E 'REP-|Exception' | head -1)")"; _scan_fail=true; fi
                continue
            fi
            _found_any=true
            while IFS= read -r _l; do
                _nm="$(printf '%s' "$_l" | sed -n 's/.*Name = \([^ ]*\).*/\1/p')"
                _ty="$(printf '%s' "$_l" | sed -n 's/.*Type = \([^ ]*\).*/\1/p')"
                _ho="$(printf '%s' "$_l" | sed -n 's/.*Host = \([^ ]*\).*/\1/p')"
                _mine=false
                case "$_own_names" in *" $_ho "*|*" ${_ho%%.*} "*) _mine=true ;; esac
                _p "$(printf '  %-7s %-24s %-8s %s%s' "$_po" "$_nm" "$_ty" "$_ho" "$($_mine && printf '  (this host)')")"
                $_mine || SCAN_FOREIGN="$SCAN_FOREIGN $_po:$_nm@$_ho"
                [ "$_po" = "$OWN_PORT" ] && ! $_mine && warn "  port $_po (own port) is used by $_nm on $_ho - the environments see each other"
                for _s in $SERVER_INSTS; do
                    [ "$_nm" = "$_s" ] && ! $_mine && fail "  server name '$_nm' also on $_ho (port $_po) - same name on the same port = REP-56040"
                done
            done <<< "$_lines"
        done
        _p ""
        $_found_any || info "no Reports server answered in the range"
        $_scan_fail && warn "some ports could not be scanned - see the '?' lines"
        [ -n "$_free" ] && info "ports without an answer:$_free (only RUNNING servers answer - a port may still belong to a stopped environment)"
    fi
fi

# =============================================================================
# 5. Discovery errors in the Reports server logs
# =============================================================================
section "5. Discovery errors in the Reports server logs (last ${LOG_DAYS} days)"
_lim="$(date -d "-${LOG_DAYS} days" +%Y-%m-%d)"
mapfile -t _rlogs < <(find "$DH/servers" "$DH/system_components" -name 'rwserver_diagnostic*.log' -type f 2>/dev/null | LC_ALL=C sort)
_n56040=0
if [ ${#_rlogs[@]} -eq 0 ]; then
    info "no rwserver_diagnostic*.log below $DH/servers"
else
    for _f in "${_rlogs[@]}"; do
        _hits="$(grep -E 'REP-56040|REP-50600|REP-50125.*(StreamCorrupted|invalid stream header)' "$_f" 2>/dev/null \
                 | awk -v lim="$_lim" 'match($0, /^\[[0-9]{4}-[0-9]{2}-[0-9]{2}/) { if (substr($0, 2, 10) >= lim) print }')"
        [ -n "$_hits" ] || continue
        while IFS=';' read -r _d _code _cnt; do
            _p "$(printf '  %-60s %s %-9s %s' "${_f#"$DH"/}" "$_d" "$_code" "${_cnt}x")"
            [ "$_code" = REP-56040 ] && _n56040=$((_n56040 + _cnt))
        done < <(printf '%s\n' "$_hits" | awk '{ d = substr($0, 2, 10); c = ($0 ~ /REP-56040/) ? "REP-56040" : ($0 ~ /REP-50600/) ? "REP-50600" : "REP-50125"; n[d ";" c]++ }
                                              END { for (k in n) print k ";" n[k] }' | sort)
        info "  last: $(printf '%s\n' "$_hits" | tail -1 | cut -c1-220)"
    done
    if [ "$_n56040" -gt 0 ]; then
        fail "REP-56040 ${_n56040}x: a Reports server with the same name answers on the same multicast port (other environment on ${OWN_PORT}?)"
        info "  fix: own port per environment - free port from the scan, then --set-port N --apply here and in the other environment"
    else
        ok "no REP-56040 / REP-50600 / stream header error in ${#_rlogs[@]} Reports server log(s)"
    fi
fi

# =============================================================================
# 6. --set-port N: own multicast port for this environment
# =============================================================================
if [ -n "$SET_PORT" ]; then
    section "6. Change the multicast port ${OWN_PORT} -> ${SET_PORT}$($APPLY || printf ' (dry run)')"
    _block=false
    if [ "$SET_PORT" = "$OWN_PORT" ] && ! $_diff; then ok "every rwnetwork.conf already uses ${SET_PORT} - nothing to do"; _block=true; fi
    if ! $_block && $SCAN_DONE; then
        _busy="$(printf '%s\n' $SCAN_FOREIGN | awk -F: -v p="$SET_PORT" '$1 == p {print $2}' | paste -sd' ' -)"
        if [ -n "$_busy" ] && ! $FORCE; then fail "port ${SET_PORT} is used by another host: ${_busy} - choose a free port (scan) or --force"; _block=true
        elif [ -n "$_busy" ]; then warn "port ${SET_PORT} is used by ${_busy} - changed anyway (--force)"; fi
    elif ! $_block; then
        warn "no scan in this run - the new port ${SET_PORT} was not checked against other environments"
    fi
    if ! $_block; then
        _ts="$(date +%Y%m%d_%H%M%S)"
        for _f in "${NET_FILES[@]}"; do
            _rel="${_f#"$DH"/config/fmwconfig/}"; _po="$(_mc_attr "$_f" port)"
            if [ -z "$_po" ]; then warn "$(printf '%-70s %s' "$_rel" "no <multicast port=...> - left as it is")"; continue; fi
            if [ "$_po" = "$SET_PORT" ]; then ok "$(printf '%-70s %s' "$_rel" "already ${SET_PORT}")"; continue; fi
            if ! $APPLY; then info "$(printf '%-70s %s -> %s' "$_rel" "$_po" "$SET_PORT")"; continue; fi
            if ! cp -p "$_f" "$_f.bak_$_ts"; then fail "$_rel: backup failed - not changed"; continue; fi
            sed -i -E "s/(<multicast[^>]*port=\")[0-9]*/\1${SET_PORT}/" "$_f"
            if [ "$(_mc_attr "$_f" port)" = "$SET_PORT" ]; then ok "$(printf '%-70s %s -> %s  (backup .bak_%s)' "$_rel" "$_po" "$SET_PORT" "$_ts")"
            else fail "$(printf '%-70s %s' "$_rel" "not changed - restore: cp -p $_f.bak_$_ts $_f")"; fi
        done
        if $APPLY; then
            info "takes effect at the next start: restart the Reports server(s) ${SERVER_INSTS:-} and the managed server WLS_REPORTS"
            info "every OTHER environment on ${OWN_PORT} needs its own port too - run this tool there with another port"
            info "way back: cp -p <file>.bak_$_ts <file> for each file above, then restart"
            pgrep -f "rwserver.* server=" > /dev/null 2>&1 && warn "a Reports server runs now - it keeps port ${OWN_PORT} until its restart"
        else
            info "dry run - add --apply to back up and change the files"
        fi
    fi
fi

section "Result"
_p "Result: $N_FAIL FAIL, $N_WARN WARN - log: $LOG"
[ "$N_FAIL" -gt 0 ] && exit 2
[ "$N_WARN" -gt 0 ] && exit 1
exit 0
