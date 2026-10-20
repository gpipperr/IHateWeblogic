#!/bin/bash
# =============================================================================
# Script   : egress_check.sh
# Purpose  : What does the FMW domain send to other hosts – and is it exposed
#            to the external-DTD trap (an XML parser downloads a DTD at start
#            and blocks forever behind a silent firewall)?
#              1. external DTD / schema URLs in the domain configuration
#              2. /etc/hosts entries for those hosts
#              3. XML / network options of the running server JVMs
#              4. live: established connections that leave the local networks,
#                 per process
#              5. --capture N: tcpdump (sudo) of DNS + outgoing TCP SYN / UDP to
#                 non-local networks for N seconds (restart a server meanwhile),
#                 with a process mapping from an ss poll
#            Read-only – changes nothing (the pcap goes to the log directory).
#            Background: 80-FMW-Architecture/weblogic_outbound_connections.md
# Call     : ./egress_check.sh
#            ./egress_check.sh --capture 300            # start/restart a server now
#            ./egress_check.sh --capture 120 --if ens160
# Options  : --capture N   capture N seconds (needs sudo for tcpdump)
#            --if IF       interface for the capture (default: route of the default gateway)
#            --help        Show usage
# Requires : ss, ip, awk; tcpdump + sudo for --capture
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

# DTDs that are resolved without network by the JDK when read through the API
# that owns them – documented in the JDK Javadoc
KNOWN_LOCAL_DTD="http://java.sun.com/dtd/properties.dtd"   # java.util.Properties.loadFromXML

# =============================================================================
# Arguments
# =============================================================================

CAPTURE_SECS=0
CAP_IF=""

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-14s %s\n" "--capture N" "capture DNS + outgoing connections for N seconds (sudo tcpdump)"
    printf "  %-14s %s\n" "--if IF"     "capture interface (default: interface of the default route)"
    printf "  %-14s %s\n" "--help"      "show this help"
    printf "\nRead-only. Background: 80-FMW-Architecture/weblogic_outbound_connections.md\n"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --capture) CAPTURE_SECS="$2"; shift 2 ;;
        --if)      CAP_IF="$2"; shift 2 ;;
        --help|-h) _usage ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; _usage ;;
    esac
done
[[ "$CAPTURE_SECS" =~ ^[0-9]+$ ]] || { printf "\033[31mERROR\033[0m --capture needs seconds\n" >&2; exit 2; }

_show() { printf "  %-28s %s\n" "$1" "$2" | tee -a "${LOG_FILE:-/dev/null}"; }

# local networks = directly connected IPv4 routes + loopback
LOCAL_NETS="$(ip -4 -o route show scope link 2>/dev/null | awk '{print $1}' | paste -sd' ')"
# _is_local IP – 0 for loopback, link-local, multicast and connected IPv4 networks
_is_local() {
    local ip="$1" n
    case "$ip" in
        127.*|::1|fe80:*|ff*:*|22[4-9].*|23[0-9].*|::ffff:127.*) return 0 ;;
    esac
    ip="${ip#::ffff:}"
    [[ "$ip" =~ ^[0-9.]+$ ]] || return 1
    for n in $LOCAL_NETS; do
        python3 -I -c "import ipaddress,sys; sys.exit(0 if ipaddress.ip_address('$ip') in ipaddress.ip_network('$n', strict=False) else 1)" 2>/dev/null && return 0
    done
    return 1
}

# _proc_label PID – "java WLS_FORMS", "frmweb", "rwserver repserver01" …
_proc_label() {
    local p="$1" comm args
    comm="$(cat "/proc/$p/comm" 2>/dev/null)"
    args="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
    case "$args" in
        *-Dweblogic.Name=*) printf '%s %s' "$comm" "$(printf '%s' "$args" | sed -n 's/.*-Dweblogic\.Name=\([^ ]*\).*/\1/p')" ;;
        *oracle.reports.engine.RWEngine*) printf 'java Reports-engine' ;;
        *rwserver\ server=*) printf 'rwserver %s' "$(printf '%s' "$args" | sed -n 's/.*server=\([^ ]*\).*/\1/p')" ;;
        *) printf '%s' "${comm:-?}" ;;
    esac
}

printLine
section "Outbound Connections / External DTDs – $(date '+%Y-%m-%d %H:%M:%S')"
_show "Host:"          "$(hostname -f 2>/dev/null || hostname)"
_show "DOMAIN_HOME:"   "${DOMAIN_HOME}"
_show "Local networks:" "${LOCAL_NETS:-?} + loopback / link-local / multicast"
printLine

# =============================================================================
# 1. External DTD / schema URLs in the configuration
# =============================================================================

section "1. External DTD / Schema URLs in \$DOMAIN_HOME/config"

DTD_HOSTS=()
_dtd_list="$(grep -rIoE '<!DOCTYPE[^>]*"https?://[^"]+"' "$DOMAIN_HOME/config" --include='*.xml*' 2>/dev/null \
    | sed -E 's|^([^:]+):.*"(https?://[^"]+)".*|\2\t\1|')"
if [ -z "$_dtd_list" ]; then
    ok "No DOCTYPE with an http(s) DTD in the configuration"
else
    while IFS=$'\t' read -r _url _cnt; do
        _files="$(printf '%s\n' "$_dtd_list" | awk -F'\t' -v u="$_url" '$1==u {print $2}' \
            | sed "s|^$DOMAIN_HOME/||" | sort -u | head -3 | paste -sd',' | sed 's/,/, /g')"
        if [ "$_url" = "$KNOWN_LOCAL_DTD" ]; then
            ok "$(printf "%3s x %s  – JDK built-in when read by Properties.loadFromXML (no network)" "$_cnt" "$_url")"
        else
            warn "$(printf "%3s x %s  – fetched over the network by a plain JAXP parser" "$_cnt" "$_url")"
        fi
        info "      $_files"
        DTD_HOSTS+=("$(printf '%s' "$_url" | sed -E 's|https?://([^/:]+).*|\1|')")
    done < <(printf '%s\n' "$_dtd_list" | cut -f1 | sort | uniq -c | awk '{print $2"\t"$1}')
fi
_xsd="$(grep -rIhoE '(schemaLocation|noNamespaceSchemaLocation)="[^"]*https?://[^"]*"' "$DOMAIN_HOME/config" --include='*.xml' 2>/dev/null \
    | grep -oE 'https?://[^" ]+\.xsd' | sort -u | wc -l)"
info "$(printf "%s distinct http(s) XSD in schemaLocation attributes – loaded only by validating parsers without a local catalog" "$_xsd")"

# =============================================================================
# 2. /etc/hosts entries for the DTD hosts
# =============================================================================

section "2. Name Resolution of the DTD Hosts"

if [ "${#DTD_HOSTS[@]}" -eq 0 ]; then
    info "No DTD hosts found"
else
    for _h in $(printf '%s\n' "${DTD_HOSTS[@]}" | sort -u); do
        _he="$(awk -v h="$_h" '!/^[[:space:]]*#/ { for (i=2;i<=NF;i++) if ($i==h) print $1 }' /etc/hosts | head -1)"
        if [ -n "$_he" ]; then
            ok "$(printf "%-20s /etc/hosts -> %s (fast failure if nothing listens there)" "$_h" "$_he")"
        else
            info "$(printf "%-20s resolved via DNS (%s) – a silent firewall on the path blocks a parser forever" \
                "$_h" "$(getent ahostsv4 "$_h" 2>/dev/null | awk 'NR==1{print $1}')")"
        fi
    done
fi

# =============================================================================
# 3. XML / network options of the running JVMs
# =============================================================================

section "3. XML / Network Options of the Running Server JVMs"

_any=0
for _p in $(pgrep -f -- '-Dweblogic.Name=|oracle.reports.engine.RWEngine' 2>/dev/null); do
    _args="$(tr '\0' '\n' < "/proc/$_p/cmdline" 2>/dev/null)"
    [ -z "$_args" ] && continue
    _any=1
    _opts="$(printf '%s\n' "$_args" | grep -E '^-D(javax\.xml\.accessExternal|jdk\.xml\.|sun\.net\.client\.default|https?\.proxy|https?\.nonProxyHosts)' | paste -sd' ')"
    _show "$(_proc_label "$_p") ($_p):" "${_opts:-(none – external DTDs allowed, no URLConnection timeout)}"
done
[ "$_any" -eq 0 ] && info "No server JVM running"
info "  Options and their effect: 80-FMW-Architecture/weblogic_outbound_connections.md section 3"

# =============================================================================
# 4. Live: established connections leaving the local networks
# =============================================================================

section "4. Established Connections to Non-local Hosts (now)"

_out=0
while read -r _peer _pids; do
    _ip="${_peer%:*}"; _ip="${_ip#[}"; _ip="${_ip%]}"
    _is_local "$_ip" && continue
    for _p in $(printf '%s' "$_pids" | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do
        _lbl="$(_proc_label "$_p")"
        case "$_lbl" in
            java\ *|frmweb*|rwserver*|rwrun*) warn "$(printf "%-28s %s  – domain process talks to a non-local host" "$_lbl ($_p):" "$_peer")"
                                              _out=$(( _out + 1 )) ;;
            *) info "$(printf "%-28s %s  (not part of the domain)" "$_lbl ($_p):" "$_peer")" ;;
        esac
    done
done < <(ss -tnpH state established 2>/dev/null | awk '{print $4, $5}')
[ "$_out" -eq 0 ] && ok "No domain process (WebLogic, Reports, frmweb) connected to a non-local host"
info "  ss shows only processes of the current user (run as root for all)"

# =============================================================================
# 5. Capture
# =============================================================================

if [ "$CAPTURE_SECS" -gt 0 ]; then
    section "5. Capture ${CAPTURE_SECS} s – restart / use the servers now"
    [ -z "$CAP_IF" ] && CAP_IF="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
    if ! command -v tcpdump > /dev/null 2>&1; then
        fail "tcpdump not installed (dnf install tcpdump)"
    elif ! sudo -n true 2>/dev/null; then
        fail "sudo without password needed for tcpdump"
    else
        PCAP="$DIAG_LOG_DIR/egress_$(date +%H%M%S).pcap"
        POLL="$(mktemp)"
        # destination filter only – the host itself is part of the local network
        _flt="(udp port 53) or (ip and not dst net 127.0.0.0/8 and not dst net 224.0.0.0/4"
        for _n in $LOCAL_NETS; do _flt="$_flt and not dst net $_n"; done
        _flt="$_flt and ((tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack == 0) or udp))"
        _show "Interface:" "$CAP_IF"
        _show "pcap:" "$PCAP"
        sudo -n timeout "$CAPTURE_SECS" tcpdump -ni "$CAP_IF" -s 0 -U -w "$PCAP" "$_flt" > /dev/null 2>&1 &
        _tp=$!
        _end=$(( SECONDS + CAPTURE_SECS ))
        while [ $SECONDS -lt $_end ]; do
            ss -tnpH 2>/dev/null | awk '{print $5, $6}' >> "$POLL"; sleep 0.5
        done
        wait "$_tp" 2>/dev/null
        sudo -n chown "$(id -u):$(id -g)" "$PCAP" 2>/dev/null; chmod 600 "$PCAP" 2>/dev/null

        _dns="$(tcpdump -nr "$PCAP" 'udp port 53' 2>/dev/null | grep -oE '(A|AAAA)\? [^ ]+' | awk '{print $2}' | sort | uniq -c | sort -rn)"
        printf "\n  DNS lookups:\n" | tee -a "${LOG_FILE:-/dev/null}"
        if [ -n "$_dns" ]; then
            printf '%s\n' "$_dns" | sed 's/^/    /' | tee -a "${LOG_FILE:-/dev/null}"
        else
            printf "    (none)\n" | tee -a "${LOG_FILE:-/dev/null}"
        fi
        # IP -> name from the DNS answers of the capture (query id -> name, answer A records)
        _ipname="$(tcpdump -nr "$PCAP" 'udp port 53' 2>/dev/null | awk '
            / [AAA]*\? / { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\+?$/ && $(i+1) ~ /\?$/) { id=$i; sub(/\+/,"",id); q[id]=$(i+2) } }
            / A [0-9.]+/ { id=""; for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/ && $(i+1) ~ /^[0-9]+\/[0-9]+\/[0-9]+$/) id=$i
                           for (i=1;i<NF;i++) if ($i=="A") { ip=$(i+1); sub(/[,]$/,"",ip); if (id in q) print ip, q[id] } }')"
        printf "\n  Outgoing connections (destination, packets, DNS name, process from the ss poll):\n" | tee -a "${LOG_FILE:-/dev/null}"
        _n=0
        while read -r _c _dst; do
            _proc="$(grep -F " $_dst " <(sed 's/$/ /' "$POLL") 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)"
            _lbl="$( [ -n "$_proc" ] && _proc_label "$_proc" || printf '(process not seen by ss – short-lived)')"
            _nm="$(printf '%s\n' "$_ipname" | awk -v ip="${_dst%:*}" '$1==ip {print $2; exit}')"
            printf "    %5s  %-24s %-22s %s\n" "$_c" "$_dst" "${_nm:--}" "$_lbl" | tee -a "${LOG_FILE:-/dev/null}"
            _n=$(( _n + 1 ))
        done < <(tcpdump -nr "$PCAP" 'not udp port 53' 2>/dev/null \
                 | awk '{d=$5; sub(/:$/,"",d); n=split(d,a,"."); port=a[n]; ip=a[1]; for(i=2;i<n;i++) ip=ip"."a[i]; print ip":"port}' \
                 | sort | uniq -c | sort -rn)
        rm -f "$POLL"
        if [ "$_n" -eq 0 ] && [ -z "$_dns" ]; then
            ok "Nothing left the local networks during the capture"
        else
            warn "$(printf "%s outgoing destination(s) – check which process (OS timers such as dnf-makecache also show up: journalctl)" "$_n")"
        fi
    fi
fi

print_summary
exit "$EXIT_CODE"
