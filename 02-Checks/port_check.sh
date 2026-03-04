#!/bin/bash
# =============================================================================
# Script   : port_check.sh
# Purpose  : Show which IP addresses and TCP ports each WebLogic/Reports/Forms
#            component is configured to listen on, cross-check with the actual
#            listening sockets reported by ss(8), and verify TCP connectivity.
# Call     : ./port_check.sh
#            ./port_check.sh --http
# Options  : --http         Also run HTTP GET health check on AdminServer console URL
#            --timeout N    TCP connect timeout in seconds (default: 3)
# Requires : ss (or netstat), ip (or ifconfig), awk, bash
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
source "$ENV_CONF"
init_log

# =============================================================================
# Arguments
# =============================================================================

HTTP_CHECK=false
TCP_TIMEOUT=3

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-22s %s\n" "--http"       "Also run HTTP GET health check on AdminServer console"
    printf "  %-22s %s\n" "--timeout N"  "TCP connect timeout in seconds (default: 3)"
    printf "\nExamples:\n"
    printf "  %s\n"        "$(basename "$0")"
    printf "  %s --http\n" "$(basename "$0")"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --http)      HTTP_CHECK=true; shift ;;
        --timeout)   TCP_TIMEOUT="$2"; shift 2 ;;
        --help|-h)   _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
    esac
done

# =============================================================================
# Helpers
# =============================================================================

# TCP connect check via bash /dev/tcp (no nc required)
_tcp_check() {
    local host="$1" port="$2"
    [ "$host" = "*" ] && host="localhost"   # all-interfaces → probe via localhost
    timeout "$TCP_TIMEOUT" bash -c ">/dev/tcp/${host}/${port}" 2>/dev/null
}

# Extract host / port from URL like t3://host:port  or  http://host:port
_url_host() { printf "%s" "$1" | sed 's|.*://||; s|:.*||'; }
_url_port() { printf "%s" "$1" | sed 's|.*:||';             }

# =============================================================================
# Collect ss snapshot once (reused in display and cross-check)
# =============================================================================

SS_CACHE=""
SS_TOOL=""
if command -v ss > /dev/null 2>&1; then
    SS_CACHE="$(ss -tlnp 2>/dev/null)"
    SS_TOOL="ss"
elif command -v netstat > /dev/null 2>&1; then
    SS_CACHE="$(netstat -tlnp 2>/dev/null)"
    SS_TOOL="netstat"
fi

# Returns "LISTEN" if port appears in the ss snapshot, "DOWN" otherwise
_ss_state() {
    local port="$1"
    echo "$SS_CACHE" | awk '{print $4}' | grep -qE ":${port}$" && printf "LISTEN" || printf "DOWN"
}

# =============================================================================
# Probe registry  (parallel arrays filled while scanning config)
# =============================================================================

declare -a PROBE_COMP=()
declare -a PROBE_ADDR=()
declare -a PROBE_PORT=()
declare -a PROBE_PROTO=()

_register() {
    [ -z "$3" ] && return   # skip empty port
    PROBE_COMP+=("$1")
    PROBE_ADDR+=("$2")
    PROBE_PORT+=("$3")
    PROBE_PROTO+=("$4")
}

# =============================================================================
# Banner
# =============================================================================

printLine
section "Port Check – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-22s %s\n" "Host:"        "$(hostname -f 2>/dev/null || hostname)"  | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-22s %s\n" "DOMAIN_HOME:" "${DOMAIN_HOME}"                           | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-22s %s\n" "Socket tool:" "${SS_TOOL:-(not found)}"                  | tee -a "${LOG_FILE:-/dev/null}"
printLine

# =============================================================================
# 1. Network Interfaces
# =============================================================================

section "Network Interfaces (IPv4)"

if command -v ip > /dev/null 2>&1; then
    ip -4 addr show 2>/dev/null \
    | awk '
        /^[0-9]+:/ { iface=$2; sub(/:$/,"",iface) }
        /inet /    {
            split($2,a,"/")
            printf "  %-18s %s/%s\n", iface, a[1], a[2]
        }
    ' | tee -a "${LOG_FILE:-/dev/null}"
elif command -v ifconfig > /dev/null 2>&1; then
    ifconfig 2>/dev/null | awk '
        /^[a-zA-Z]/ { iface=$1 }
        /inet /     {
            for(i=1;i<=NF;i++) if($i=="inet") printf "  %-18s %s\n", iface, $(i+1)
        }
    ' | tee -a "${LOG_FILE:-/dev/null}"
else
    warn "ip and ifconfig not found – cannot show network interfaces"
    info "Install: sudo dnf install iproute"
fi

# =============================================================================
# 2. Configured Ports – DOMAIN_HOME/config/config.xml
# =============================================================================

printLine
section "Configured Ports – config/config.xml"

CONFIG_XML="${DOMAIN_HOME}/config/config.xml"

if [ ! -f "$CONFIG_XML" ]; then
    warn "config.xml not found: $CONFIG_XML"
    info "Domain may not yet be created, or DOMAIN_HOME is wrong."
    _fb_host="$(_url_host "${WL_ADMIN_URL:-t3://localhost:7001}")"
    _fb_port="$(_url_port "${WL_ADMIN_URL:-t3://localhost:7001}")"
    info "Falling back to WL_ADMIN_URL from environment.conf: port ${_fb_port} on ${_fb_host}"
    _register "AdminServer" "$_fb_host" "$_fb_port" "T3/HTTP"
else
    printf "  \033[1m%-24s  %-22s  %-8s  %-10s  %s\033[0m\n" \
        "Server" "Listen Address" "Port" "SSL Port" "Source" \
        | tee -a "${LOG_FILE:-/dev/null}"
    printLine

    # Parse server blocks from config.xml
    # Output fields: name|listen_addr|listen_port|ssl_port
    while IFS='|' read -r srv_name listen_addr listen_port ssl_port; do
        [ -z "$srv_name" ] && continue
        local_addr="${listen_addr:-*}"
        probe_host="${listen_addr:-localhost}"

        printf "  %-24s  %-22s  %-8s  %-10s  config.xml\n" \
            "$srv_name" "$local_addr" "${listen_port:--}" "${ssl_port:--}" \
            | tee -a "${LOG_FILE:-/dev/null}"

        _register "$srv_name"          "$probe_host" "$listen_port" "T3/HTTP"
        [ -n "$ssl_port" ] && \
            _register "${srv_name}(SSL)" "$probe_host" "$ssl_port"    "T3/HTTPS"

    done < <(awk '
        BEGIN { in_srv=0; in_ssl=0 }
        /<server>$/   { in_srv=1; name=""; addr=""; port=""; ssl="" }
        /<\/server>$/ {
            if (in_srv && name != "" && name != "TEMPLATE" && name != "template") {
                print name "|" addr "|" port "|" ssl
            }
            in_srv=0; in_ssl=0
        }
        in_srv && /<ssl>$/    { in_ssl=1 }
        in_srv && /<\/ssl>$/  { in_ssl=0 }
        in_srv && !in_ssl {
            if (match($0, /<name>([^<]+)<\/name>/, m))
                name = m[1]
            if (match($0, /<listen-port>([^<]+)<\/listen-port>/, m))
                port = m[1]
            if (match($0, /<listen-address>([^<]+)<\/listen-address>/, m))
                addr = m[1]
        }
        in_srv && in_ssl {
            if (match($0, /<listen-port>([^<]+)<\/listen-port>/, m))
                ssl = m[1]
        }
    ' "$CONFIG_XML")

    # Ensure AdminServer from WL_ADMIN_URL is probed even if not explicit in config.xml
    _env_admin_host="$(_url_host "${WL_ADMIN_URL:-t3://localhost:7001}")"
    _env_admin_port="$(_url_port "${WL_ADMIN_URL:-t3://localhost:7001}")"
    _already=false
    for p in "${PROBE_PORT[@]}"; do
        [ "$p" = "$_env_admin_port" ] && _already=true && break
    done
    if ! $_already; then
        printf "  %-24s  %-22s  %-8s  %-10s  WL_ADMIN_URL\n" \
            "AdminServer" "$_env_admin_host" "$_env_admin_port" "-" \
            | tee -a "${LOG_FILE:-/dev/null}"
        _register "AdminServer" "$_env_admin_host" "$_env_admin_port" "T3/HTTP"
    fi
fi

# =============================================================================
# 3. Node Manager
# =============================================================================

printLine
section "Node Manager"

NM_PROPS="${DOMAIN_HOME}/nodemanager/nodemanager.properties"
NM_PORT_CFG=5556
NM_ADDR_CFG="localhost"

if [ -f "$NM_PROPS" ]; then
    _nm_port="$(grep -i '^ListenPort'    "$NM_PROPS" 2>/dev/null | cut -d= -f2 | tr -d ' \r')"
    _nm_addr="$(grep -i '^ListenAddress' "$NM_PROPS" 2>/dev/null | cut -d= -f2 | tr -d ' \r')"
    _nm_ssl="$( grep -i '^SecureListener\|^SSLEnabled' "$NM_PROPS" 2>/dev/null | head -1)"
    NM_PORT_CFG="${_nm_port:-5556}"
    NM_ADDR_CFG="${_nm_addr:-localhost}"

    ok "nodemanager.properties found"
    printf "  %-24s %s\n" "Properties:"   "$NM_PROPS"    | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-24s %s\n" "ListenAddress:" "$NM_ADDR_CFG" | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-24s %s\n" "ListenPort:"    "$NM_PORT_CFG" | tee -a "${LOG_FILE:-/dev/null}"
    [ -n "$_nm_ssl" ] && \
        printf "  %-24s %s\n" "SSL setting:" "$_nm_ssl"   | tee -a "${LOG_FILE:-/dev/null}"
else
    warn "nodemanager.properties not found: $NM_PROPS"
    printf "  Using defaults: %s:%s\n" "$NM_ADDR_CFG" "$NM_PORT_CFG" | tee -a "${LOG_FILE:-/dev/null}"
fi

_register "NodeManager" "$NM_ADDR_CFG" "$NM_PORT_CFG" "NM/SSL"

# =============================================================================
# 4. All Listening TCP Sockets
# =============================================================================

printLine
section "All Listening TCP Sockets  (${SS_TOOL:-unavailable})"

if [ -z "$SS_TOOL" ]; then
    warn "Neither ss nor netstat found – cannot show socket table"
    info "Install: sudo dnf install iproute"
elif [ -z "$SS_CACHE" ]; then
    warn "No output from ${SS_TOOL}"
else
    printf "  \033[1m%-10s  %-30s  %s\033[0m\n" \
        "State" "Local Address:Port" "Process" | tee -a "${LOG_FILE:-/dev/null}"
    printLine

    # ss -tlnp columns (OL8): State Recv-Q Send-Q Local Peer [Process]
    echo "$SS_CACHE" | tail -n +2 | while IFS= read -r line; do
        state="$(echo "$line"    | awk '{print $1}')"
        local_ap="$(echo "$line" | awk '{print $4}')"
        process="$(echo "$line"  | awk '{for(i=6;i<=NF;i++) printf "%s ",$i}')"
        [ -z "$process" ] && process="$(echo "$line" | awk '{print $5}')"

        if echo "$line" | grep -qiE 'java|weblogic|nodemanager|ohs|httpd'; then
            printf "  \033[32m%-10s  %-30s  %s\033[0m\n" \
                "$state" "$local_ap" "$process" | tee -a "${LOG_FILE:-/dev/null}"
        else
            printf "  \033[2m%-10s  %-30s  %s\033[0m\n" \
                "$state" "$local_ap" "$process" | tee -a "${LOG_FILE:-/dev/null}"
        fi
    done

    printf "\n" | tee -a "${LOG_FILE:-/dev/null}"
    info "Green rows = java/weblogic/nodemanager process.  Dim rows = other system sockets."
    if [ "$(id -u)" -ne 0 ]; then
        info "Run as root to see process names for sockets not owned by the current user."
    fi
fi

# =============================================================================
# 5. Port Connectivity Cross-Check
# =============================================================================

printLine
section "Port Connectivity Cross-Check  (TCP timeout: ${TCP_TIMEOUT}s)"
printf "  \033[1m%-24s  %-20s  %-8s  %-10s  %-8s  %s\033[0m\n" \
    "Component" "Host" "Port" "Protocol" "ss" "TCP Connect" \
    | tee -a "${LOG_FILE:-/dev/null}"
printLine

for (( i=0; i < ${#PROBE_COMP[@]}; i++ )); do
    comp="${PROBE_COMP[$i]}"
    host="${PROBE_ADDR[$i]}"
    port="${PROBE_PORT[$i]}"
    proto="${PROBE_PROTO[$i]}"
    probe_host="${host}"; [ "$probe_host" = "*" ] && probe_host="localhost"

    ss_state="$(_ss_state "$port")"
    if _tcp_check "$probe_host" "$port"; then
        tcp_col="\033[32mOPEN\033[0m"
    else
        tcp_col="\033[31mCLOSED\033[0m"
        fail "Port $port ($comp) not reachable on ${probe_host}"
    fi

    if [ "$ss_state" = "LISTEN" ]; then
        ss_col="\033[32m${ss_state}\033[0m"
    else
        ss_col="\033[31m${ss_state}\033[0m"
    fi

    printf "  %-24s  %-20s  %-8s  %-10s  " \
        "$comp" "$host" "$port" "$proto" | tee -a "${LOG_FILE:-/dev/null}"
    printf "${ss_col}    ${tcp_col}\n"     | tee -a "${LOG_FILE:-/dev/null}"
done

# =============================================================================
# 6. HTTP Health Check (optional --http)
# =============================================================================

if $HTTP_CHECK; then
    printLine
    section "HTTP Health Check"

    if ! command -v curl > /dev/null 2>&1; then
        warn "curl not found – skipping HTTP check"
        info "Install: sudo dnf install curl"
    else
        _admin_host="$(_url_host "${WL_ADMIN_URL:-t3://localhost:7001}")"
        _admin_port="$(_url_port "${WL_ADMIN_URL:-t3://localhost:7001}")"

        _http_check_url() {
            local label="$1" url="$2"
            printf "  %-34s %s\n" "${label}:" "$url" | tee -a "${LOG_FILE:-/dev/null}"
            local code
            code="$(curl -s -o /dev/null -w "%{http_code}" \
                --connect-timeout "$TCP_TIMEOUT" \
                --max-time $(( TCP_TIMEOUT * 2 )) \
                "$url" 2>/dev/null)"
            case "$code" in
                200|301|302)     ok   "  HTTP ${code} – reachable" ;;
                401|403)         ok   "  HTTP ${code} – reachable (auth required – expected)" ;;
                000)             fail "  No response – AdminServer not running?" ;;
                *)               warn "  HTTP ${code} – unexpected response" ;;
            esac
        }

        _http_check_url "AdminServer console" \
            "http://${_admin_host}:${_admin_port}/console"
        _http_check_url "AdminServer version JSP" \
            "http://${_admin_host}:${_admin_port}/bea_wls_internal/versionInfo.jsp"
    fi
fi

# =============================================================================
# Summary
# =============================================================================

print_summary
exit $EXIT_CODE
