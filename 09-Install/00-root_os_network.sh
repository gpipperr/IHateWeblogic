#!/bin/bash
# =============================================================================
# Script   : 00-root_os_network.sh
# Purpose  : Phase 0 – Network environment check for Oracle FMW 14.1.2 on OL 9
#            Validates hostname resolution, DNS (forward + reverse), /etc/hosts
#            consistency, IPv6 status, and localhost IPv4 binding.
#            Read-only – no changes are made.
# Call     : ./09-Install/00-root_os_network.sh
#            ./09-Install/00-root_os_network.sh --help
# Options  : --help   Show usage
# Requires : hostname, getent, sysctl, ip; dig or nslookup (optional, for PTR)
# Runs as  : root or oracle (no write access needed)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/docs/00-root_os_network.md
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

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-20s %s\n" "--help"  "Show this help"
    printf "\nThis script is read-only – it checks and reports but makes no changes.\n"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h) _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
    esac
done

# =============================================================================
# Helpers
# =============================================================================

# Reverse DNS lookup: try dig, then nslookup, then getent
_ptr_lookup() {
    local ip="$1"
    local result=""
    if command -v dig > /dev/null 2>&1; then
        result="$(dig -x "$ip" +short 2>/dev/null | sed 's/\.$//' | head -1)"
    fi
    if [ -z "$result" ] && command -v nslookup > /dev/null 2>&1; then
        result="$(nslookup "$ip" 2>/dev/null \
            | awk '/name =/ {gsub(/\.$/, "", $NF); print $NF}' | head -1)"
    fi
    if [ -z "$result" ]; then
        result="$(getent hosts "$ip" 2>/dev/null | awk '{print $2}' | head -1)"
    fi
    printf "%s" "$result"
}

# Check if an IP string is a loopback address
_is_loopback() {
    case "$1" in
        127.*|::1) return 0 ;;
        *)         return 1 ;;
    esac
}

# =============================================================================
# Banner
# =============================================================================

printLine
section "Network Check – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-26s %s\n" "Host:" \
    "$(hostname -f 2>/dev/null || hostname)" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "OS:" \
    "$(cat /etc/oracle-release 2>/dev/null \
    || cat /etc/redhat-release 2>/dev/null || printf 'unknown')" \
    | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "Mode:" "CHECK ONLY (read-only)" | tee -a "${LOG_FILE:-/dev/null}"
printLine

# =============================================================================
# 1. Hostname Consistency
# =============================================================================

section "Hostname Consistency"

SHORT_HOST="$(hostname 2>/dev/null)"
FQDN="$(hostname -f 2>/dev/null)"
DOMAIN="$(hostname -d 2>/dev/null)"
# First label only (e.g. "orafusion01" from "orafusion01.pipperr.local")
SHORT_LABEL="${SHORT_HOST%%.*}"
# Static hostname from hostnamectl (what is persistently configured)
STATIC_HOSTNAME="$(hostnamectl status 2>/dev/null \
    | awk '/Static hostname:/ {print $3}')"
# hostname -a: aliases from /etc/hosts – populated when short name is first in /etc/hosts
# and FQDN appears as alias. If hostname -f returns the FQDN correctly, -a returns the short name.
HOSTNAME_ALIASES="$(hostname -a 2>/dev/null)"

printf "  %-26s %s\n" "hostname:"           "${SHORT_HOST:-(empty)}"       | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "hostname -f (FQDN):" "${FQDN:-(empty)}"             | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "hostname -a (alias):" "${HOSTNAME_ALIASES:-(empty)}" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "hostname -d (domain):" "${DOMAIN:-(empty)}"          | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "hostnamectl static:"  "${STATIC_HOSTNAME:-(empty)}"  | tee -a "${LOG_FILE:-/dev/null}"

# Short hostname must not be empty or a generic placeholder
if [ -z "$SHORT_HOST" ]; then
    fail "hostname is empty – set via hostnamectl set-hostname"
elif [ "$SHORT_HOST" = "localhost" ] || [ "$SHORT_HOST" = "localhost.localdomain" ]; then
    fail "hostname is '$SHORT_HOST' – generic placeholder, WebLogic needs a real hostname"
else
    ok "$(printf "%-26s %s" "Short hostname:" "$SHORT_HOST")"
fi

# FQDN must contain at least one dot
if [ -z "$FQDN" ]; then
    fail "hostname -f returned empty – /etc/hosts or DNS missing for this host"
elif ! printf "%s" "$FQDN" | grep -q '\.'; then
    # Check if FQDN is reachable via hostname -a (alias in /etc/hosts)
    # This happens when /etc/hosts has the short name as first entry:
    #   Wrong:   <ip>  orafusion01  orafusion01.pipperr.local
    #   Correct: <ip>  orafusion01.pipperr.local  orafusion01
    FQDN_FROM_ALIAS="$(printf "%s" "${HOSTNAME_ALIASES:-}" | tr ' ' '\n' | grep '\.' | head -1)"
    if [ -n "$FQDN_FROM_ALIAS" ]; then
        fail "$(printf "hostname -f returns '%s' (no domain) but FQDN '%s' found via hostname -a" \
            "$FQDN" "$FQDN_FROM_ALIAS")"
        info "  Cause: /etc/hosts has short name as first entry – FQDN must come first:"
        info "    Wrong:   <ip>  $SHORT_LABEL  $FQDN_FROM_ALIAS"
        info "    Correct: <ip>  $FQDN_FROM_ALIAS  $SHORT_LABEL"
        info "  Fix: edit /etc/hosts and reorder the entry, then verify:"
        info "    hostname -f  →  $FQDN_FROM_ALIAS"
        info "    hostname -a  →  $SHORT_LABEL"
    else
        fail "$(printf "%-26s %s  (no domain part – bare hostname invalid for WebLogic)" \
            "FQDN:" "$FQDN")"
        info "  Fix: hostnamectl set-hostname ${SHORT_LABEL}.your.domain.local"
        info "  Add to /etc/hosts: <server-ip>  ${SHORT_LABEL}.your.domain.local  $SHORT_LABEL"
        info "  Verify: hostname -f  →  ${SHORT_LABEL}.your.domain.local"
        info "          hostname -a  →  $SHORT_LABEL"
    fi
else
    ok "$(printf "%-26s %s" "FQDN:" "$FQDN")"
fi

# Domain part must not be empty
# NOTE: hostname -d returns the DNS domain derived from name resolution (not the static config).
# hostnamectl static hostname may already be a FQDN – but if /etc/hosts or DNS does not
# resolve it back to an FQDN, hostname -d will still be empty.
if [ -z "$DOMAIN" ]; then
    warn "hostname -d returned empty – domain part required for WebLogic cluster config"
    info "  Note: 'hostname -d' derives the domain from DNS/hosts resolution, NOT from"
    info "  the static hostname set via hostnamectl. Both must be consistent:"
    info "    hostnamectl static : ${STATIC_HOSTNAME:-(not set)}"
    info "    hostname -f (DNS)  : ${FQDN:-(empty)}  ← must contain a dot"
    info "    hostname -d (DNS)  : (empty)            ← derived from hostname -f"
    info "  Fix step 1: hostnamectl set-hostname ${SHORT_LABEL}.your.domain.local"
    info "  Fix step 2: /etc/hosts – FQDN must be first: <ip>  ${SHORT_LABEL}.your.domain.local  $SHORT_LABEL"
    info "  Fix step 3: verify:"
    info "    hostname -f  →  ${SHORT_LABEL}.your.domain.local  (FQDN)"
    info "    hostname -a  →  $SHORT_LABEL                      (alias)"
    info "    hostname -d  →  your.domain.local                 (domain part)"
else
    ok "$(printf "%-26s %s" "Domain:" "$DOMAIN")"
fi

# =============================================================================
# 2. Forward DNS Resolution
# =============================================================================

section "Forward DNS Resolution"

RESOLVED_IP=""
if [ -n "$FQDN" ]; then
    # getent uses the same NSS stack as the JVM (files → dns → myhostname)
    RESOLVED_IP="$(getent hosts "$FQDN" 2>/dev/null | awk '{print $1}' | head -1)"

    printf "  %-26s %s\n" "getent hosts $FQDN:" \
        "${RESOLVED_IP:-(no result)}" | tee -a "${LOG_FILE:-/dev/null}"

    if [ -z "$RESOLVED_IP" ]; then
        fail "FQDN does not resolve – add $FQDN to DNS or /etc/hosts"
    elif _is_loopback "$RESOLVED_IP"; then
        fail "$(printf "FQDN resolves to loopback %s – WebLogic/NodeManager will bind to loopback and be unreachable" \
            "$RESOLVED_IP")"
    else
        ok "$(printf "%-26s %s → %s" "Forward DNS:" "$FQDN" "$RESOLVED_IP")"
    fi

    # Cross-check with pure DNS (if dig available) – catches /etc/hosts overrides
    if command -v dig > /dev/null 2>&1; then
        DNS_IP="$(dig +short "$FQDN" A 2>/dev/null | head -1)"
        if [ -n "$DNS_IP" ] && [ "$DNS_IP" != "$RESOLVED_IP" ]; then
            warn "$(printf "DNS returns %s but getent returns %s – /etc/hosts overrides DNS" \
                "$DNS_IP" "$RESOLVED_IP")"
            info "  Verify /etc/hosts entry for $FQDN is intentional"
        elif [ -z "$DNS_IP" ] && [ -n "$RESOLVED_IP" ]; then
            info "  FQDN resolves via /etc/hosts only (no DNS A record found)"
        fi
    fi
else
    warn "Skipping forward DNS check – FQDN not available"
fi

# =============================================================================
# 3. Reverse DNS (PTR Record)
# =============================================================================

section "Reverse DNS (PTR)"

if [ -n "$RESOLVED_IP" ]; then
    PTR="$(_ptr_lookup "$RESOLVED_IP")"
    printf "  %-26s %s\n" "PTR for $RESOLVED_IP:" \
        "${PTR:-(no PTR record)}" | tee -a "${LOG_FILE:-/dev/null}"

    if [ -z "$PTR" ]; then
        warn "No PTR record for $RESOLVED_IP – SSL and cluster communication may fail"
        info "  Request PTR record from your DNS administrator: $RESOLVED_IP → $FQDN"
    else
        PTR_CLEAN="${PTR%.}"   # strip trailing dot (dig output)
        if [ "$PTR_CLEAN" = "$FQDN" ] || [ "$PTR_CLEAN" = "$SHORT_HOST" ]; then
            ok "$(printf "%-26s %s → %s → %s" \
                "Reverse DNS:" "$FQDN" "$RESOLVED_IP" "$PTR_CLEAN")"
        else
            warn "$(printf "PTR mismatch: forward=%s reverse=%s – SSL/cluster issues possible" \
                "$FQDN" "$PTR_CLEAN")"
            info "  Correct the PTR record in DNS to point to: $FQDN"
        fi
    fi
else
    warn "Skipping PTR check – no resolved IP available"
fi

# =============================================================================
# 4. /etc/hosts Consistency
# =============================================================================

section "/etc/hosts Consistency"

HOSTS_FILE="/etc/hosts"
HOSTS_LINE=""

# Look for FQDN or short hostname in /etc/hosts
if [ -n "$FQDN" ]; then
    HOSTS_LINE="$(grep -E "[[:space:]]${FQDN}([[:space:]]|$)" "$HOSTS_FILE" 2>/dev/null \
        | grep -v '^[[:space:]]*#' | head -1)"
fi
if [ -z "$HOSTS_LINE" ] && [ -n "$SHORT_HOST" ]; then
    HOSTS_LINE="$(grep -E "[[:space:]]${SHORT_HOST}([[:space:]]|$)" "$HOSTS_FILE" 2>/dev/null \
        | grep -v '^[[:space:]]*#' | head -1)"
fi

if [ -z "$HOSTS_LINE" ]; then
    warn "/etc/hosts has no entry for $FQDN – DNS-only setup (no fallback if DNS fails)"
    info "  Recommended: add '$RESOLVED_IP  $FQDN  $SHORT_HOST' to /etc/hosts"
else
    HOSTS_IP="$(printf "%s" "$HOSTS_LINE" | awk '{print $1}')"
    printf "  %-26s %s\n" "/etc/hosts entry:" "$HOSTS_LINE" | tee -a "${LOG_FILE:-/dev/null}"

    if _is_loopback "$HOSTS_IP"; then
        fail "$FQDN maps to loopback $HOSTS_IP in /etc/hosts – WebLogic will bind to loopback"
        info "  Fix: replace loopback with the real server IP in /etc/hosts"
    elif [ -n "$RESOLVED_IP" ] && [ "$HOSTS_IP" != "$RESOLVED_IP" ]; then
        warn "$(printf "/etc/hosts IP %s differs from DNS %s – split-brain risk" \
            "$HOSTS_IP" "$RESOLVED_IP")"
    else
        ok "$(printf "%-26s %s → %s" "/etc/hosts:" "$FQDN" "$HOSTS_IP")"
    fi
fi

# =============================================================================
# 5. DNS Resolver Configuration
# =============================================================================

section "DNS Resolver Configuration"

RESOLV_CONF="/etc/resolv.conf"
if [ ! -f "$RESOLV_CONF" ]; then
    fail "$RESOLV_CONF not found – DNS resolution will not work"
else
    NS_COUNT="$(grep -c '^nameserver' "$RESOLV_CONF" 2>/dev/null || printf "0")"
    SEARCH_LINE="$(grep -E '^(search|domain)' "$RESOLV_CONF" 2>/dev/null | head -1)"

    printf "  %-26s %s\n" "nameserver entries:" "$NS_COUNT" \
        | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-26s %s\n" "search/domain:" \
        "${SEARCH_LINE:-(not set)}" | tee -a "${LOG_FILE:-/dev/null}"

    if [ "$NS_COUNT" -eq 0 ]; then
        fail "No nameserver in $RESOLV_CONF – DNS resolution impossible"
    elif [ "$NS_COUNT" -eq 1 ]; then
        warn "Only one nameserver configured – no DNS redundancy"
    else
        ok "$(printf "%-26s %s nameserver(s)" "nameserver:" "$NS_COUNT")"
    fi

    if [ -z "$SEARCH_LINE" ]; then
        warn "No 'search' or 'domain' in $RESOLV_CONF – short hostname resolution may fail"
        [ -n "$DOMAIN" ] && info "  Add: search $DOMAIN"
    else
        ok "$(printf "%-26s %s" "Resolver search:" "$SEARCH_LINE")"
    fi
fi

# nsswitch.conf – verify hosts: includes files and dns
NSSWITCH="/etc/nsswitch.conf"
if [ -f "$NSSWITCH" ]; then
    HOSTS_NSS="$(grep '^hosts:' "$NSSWITCH" 2>/dev/null | head -1)"
    printf "  %-26s %s\n" "nsswitch hosts:" \
        "${HOSTS_NSS:-(not found)}" | tee -a "${LOG_FILE:-/dev/null}"

    if printf "%s" "$HOSTS_NSS" | grep -q 'files' \
    && printf "%s" "$HOSTS_NSS" | grep -q 'dns'; then
        ok "nsswitch: hosts resolution includes 'files' and 'dns'"
    elif printf "%s" "$HOSTS_NSS" | grep -q 'files'; then
        warn "nsswitch hosts: 'dns' missing – only /etc/hosts used for name resolution"
    else
        warn "nsswitch hosts: unexpected configuration – $HOSTS_NSS"
    fi
fi

# =============================================================================
# 6. IPv6 Status
# =============================================================================

section "IPv6 Status"

IPV6_ALL_DISABLED="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)"
IPV6_DEF_DISABLED="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)"

printf "  %-40s %s\n" "net.ipv6.conf.all.disable_ipv6:" \
    "${IPV6_ALL_DISABLED:-(unset)}" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-40s %s\n" "net.ipv6.conf.default.disable_ipv6:" \
    "${IPV6_DEF_DISABLED:-(unset)}" | tee -a "${LOG_FILE:-/dev/null}"

if [ "${IPV6_ALL_DISABLED:-0}" = "1" ] && [ "${IPV6_DEF_DISABLED:-0}" = "1" ]; then
    ok "IPv6 disabled system-wide via sysctl (recommended for WebLogic)"
    info "  NodeManager listen address is stable (127.0.0.1, not ::1)"
else
    info "IPv6 is active – performing additional checks"

    # Global-scope IPv6 addresses on any interface
    IPV6_GLOBAL="$(ip -6 addr show scope global 2>/dev/null \
        | awk '/inet6/ {print $2}' | head -3)"
    if [ -n "$IPV6_GLOBAL" ]; then
        printf "  %-40s %s\n" "Global IPv6 address(es):" \
            "$(printf "%s" "$IPV6_GLOBAL" | tr '\n' ' ')" | tee -a "${LOG_FILE:-/dev/null}"
        ok "IPv6 active with global-scope address"
    else
        warn "IPv6 active but no global-scope address – routing may be incomplete"
    fi

    # AAAA record in DNS
    AAAA_RECORD=""
    if [ -n "$FQDN" ] && command -v dig > /dev/null 2>&1; then
        AAAA_RECORD="$(dig +short "$FQDN" AAAA 2>/dev/null | head -1)"
    fi
    printf "  %-40s %s\n" "AAAA record for $FQDN:" \
        "${AAAA_RECORD:-(none)}" | tee -a "${LOG_FILE:-/dev/null}"

    if [ -z "$AAAA_RECORD" ]; then
        warn "IPv6 active but no AAAA DNS record – JVM may attempt IPv6 connections and fail"
        info "  Add to setUserOverrides.sh:"
        info "    JAVA_OPTIONS=\"\${JAVA_OPTIONS} -Djava.net.preferIPv4Stack=true\""
    else
        ok "$(printf "%-40s %s" "AAAA record:" "$AAAA_RECORD")"

        # Verify AAAA matches an interface address
        AAAA_CLEAN="${AAAA_RECORD%%/*}"
        if printf "%s" "$IPV6_GLOBAL" | grep -qF "$AAAA_CLEAN"; then
            ok "AAAA record matches interface address"
        else
            warn "AAAA record $AAAA_RECORD does not match any interface address"
        fi
    fi
fi

# =============================================================================
# 7. localhost → IPv4 Check
# =============================================================================

section "localhost → IPv4 Check"

# Use 'getent -s files' to query /etc/hosts only – bypasses the systemd
# 'myhostname' NSS module which always maps localhost → ::1 when IPv6 is active,
# even if /etc/hosts is correct. This avoids a false positive.
LOCALHOST_RESOLVED="$(getent -s files hosts localhost 2>/dev/null \
    | awk '{print $1}' | head -1)"

# Fallback: parse /etc/hosts directly if getent -s files is not supported
if [ -z "$LOCALHOST_RESOLVED" ]; then
    LOCALHOST_RESOLVED="$(grep -E '^[0-9a-f:]+[[:space:]]' /etc/hosts 2>/dev/null \
        | grep -v '^[[:space:]]*#' \
        | awk '$0 ~ /[[:space:]]localhost([[:space:]]|$)/ {print $1; exit}')"
fi

printf "  %-40s %s\n" "localhost (/etc/hosts):" \
    "${LOCALHOST_RESOLVED:-(no result)}" | tee -a "${LOG_FILE:-/dev/null}"

if [ -z "$LOCALHOST_RESOLVED" ]; then
    fail "localhost has no entry in /etc/hosts"
elif [ "$LOCALHOST_RESOLVED" = "127.0.0.1" ]; then
    ok "localhost → 127.0.0.1 (IPv4) in /etc/hosts – correct for WebLogic/JDBC"
elif [ "$LOCALHOST_RESOLVED" = "::1" ]; then
    fail "localhost → ::1 (IPv6 loopback) in /etc/hosts – JDBC and WLS internal connections may fail"
    info "  Fix: edit /etc/hosts, change the ::1 line to:"
    info "    ::1   localhost6 localhost6.localdomain6"
    info "  Ensure this line exists: 127.0.0.1   localhost localhost.localdomain"
else
    warn "$(printf "localhost maps to unexpected address in /etc/hosts: %s" "$LOCALHOST_RESOLVED")"
fi

# Show the loopback lines from /etc/hosts for context
printf "\n  Loopback lines in /etc/hosts:\n" | tee -a "${LOG_FILE:-/dev/null}"
grep -E '^(127\.|::1)' /etc/hosts 2>/dev/null \
    | grep -v '^[[:space:]]*#' \
    | while IFS= read -r line; do
        printf "    %s\n" "$line" | tee -a "${LOG_FILE:-/dev/null}"
      done

# Specific check: does ::1 line incorrectly claim 'localhost' without '6' suffix?
IPV6_LOCALHOST_WRONG="$(grep '^::1' /etc/hosts 2>/dev/null \
    | grep -v '^[[:space:]]*#' \
    | grep -E '[[:space:]]localhost([[:space:]]|$)' \
    | grep -v 'localhost6' \
    | head -1)"
if [ -n "$IPV6_LOCALHOST_WRONG" ] && [ "$LOCALHOST_RESOLVED" != "::1" ]; then
    # getent returned IPv4 (127.0.0.1 line first), but ::1 also claims localhost – risky
    warn "::1 line in /etc/hosts contains 'localhost' without '6' suffix"
    info "  On some JVM versions this causes IPv6 resolution – safer to remove it"
    info "  Fix: ::1   localhost6 localhost6.localdomain6"
fi

# =============================================================================
# 8. Time Synchronization (chrony)
# =============================================================================

section "Time Synchronization (chrony)"

# Is chrony installed?
if ! rpm -q chrony > /dev/null 2>&1; then
    fail "chrony is not installed"
    info "  Installation: see 09-Install/docs/00-root_os_network.md – Block 8"
    info "    dnf list chrony"
    info "    dnf install chrony -y"
    info "    systemctl enable chronyd"
    info "    systemctl start chronyd"
else
    ok "chrony package is installed ($(rpm -q --qf '%{VERSION}' chrony 2>/dev/null))"

    # Service enabled?
    CHRONY_ENABLED="$(systemctl is-enabled chronyd 2>/dev/null)"
    if [ "$CHRONY_ENABLED" = "enabled" ]; then
        ok "chronyd is enabled (starts on boot)"
    else
        fail "chronyd is not enabled – run: systemctl enable chronyd"
    fi

    # Service active?
    CHRONY_ACTIVE="$(systemctl is-active chronyd 2>/dev/null)"
    if [ "$CHRONY_ACTIVE" = "active" ]; then
        ok "chronyd is running"
    else
        fail "chronyd is not running – run: systemctl start chronyd"
        info "  Time drift causes SSL certificate errors and WLS cluster split-brain"
    fi

    # NTP synchronized (timedatectl)?
    NTP_SYNC="$(timedatectl show --property=NTPSynchronized --value 2>/dev/null)"
    NTP_ACTIVE="$(timedatectl show --property=NTP --value 2>/dev/null)"
    printf "  %-34s %s\n" "NTP active (timedatectl):"   "${NTP_ACTIVE:-(unknown)}" \
        | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-34s %s\n" "NTP synchronized (timedatectl):" "${NTP_SYNC:-(unknown)}" \
        | tee -a "${LOG_FILE:-/dev/null}"

    if [ "$NTP_SYNC" = "yes" ]; then
        ok "System clock is NTP-synchronized"
    else
        warn "System clock not yet NTP-synchronized – wait for chronyd to sync or run: chronyc makestep"
    fi

    # chronyc tracking – reference and offset
    if [ "$CHRONY_ACTIVE" = "active" ] && command -v chronyc > /dev/null 2>&1; then
        TRACKING="$(chronyc -n tracking 2>/dev/null)"
        if [ -n "$TRACKING" ]; then
            REF_ID="$(printf "%s" "$TRACKING"   | awk '/^Reference ID/   {print $4, $5}')"
            STRATUM="$(printf "%s" "$TRACKING"  | awk '/^Stratum/        {print $3}')"
            SYS_OFFSET="$(printf "%s" "$TRACKING" | awk '/^System time/  {print $4, $5}')"
            LEAP_STATUS="$(printf "%s" "$TRACKING" | awk '/^Leap status/  {print $4}')"

            printf "  %-34s %s\n" "Reference ID:"  "${REF_ID:-(unknown)}"   | tee -a "${LOG_FILE:-/dev/null}"
            printf "  %-34s %s\n" "Stratum:"       "${STRATUM:-(unknown)}"  | tee -a "${LOG_FILE:-/dev/null}"
            printf "  %-34s %s\n" "System offset:" "${SYS_OFFSET:-(unknown)}" | tee -a "${LOG_FILE:-/dev/null}"
            printf "  %-34s %s\n" "Leap status:"   "${LEAP_STATUS:-(unknown)}" | tee -a "${LOG_FILE:-/dev/null}"

            # Stratum check: 0 = unsynchronised reference clock, >10 = too far from source
            if [ -n "$STRATUM" ] && [ "$STRATUM" -le 10 ] 2>/dev/null; then
                ok "$(printf "%-34s stratum %s" "chrony tracking:" "$STRATUM")"
            elif [ -n "$STRATUM" ]; then
                warn "Stratum $STRATUM is high – NTP source may be unreliable"
            fi

            # Leap status must not be 'Not synchronised'
            if printf "%s" "$LEAP_STATUS" | grep -qi "not synchronised\|unsynchronised"; then
                warn "chrony reports: Not synchronised – time may drift"
                info "  Check sources: chronyc -n sources -v"
            fi
        else
            warn "chronyc tracking returned no output"
        fi
    fi

    # /etc/chrony.conf – at least one pool or server entry present?
    CHRONY_CONF="/etc/chrony.conf"
    if [ -f "$CHRONY_CONF" ]; then
        POOL_COUNT="$(grep -cE '^(pool|server)[[:space:]]' "$CHRONY_CONF" 2>/dev/null || printf "0")"
        printf "  %-34s %s\n" "NTP pool/server entries:" "$POOL_COUNT" \
            | tee -a "${LOG_FILE:-/dev/null}"

        if [ "$POOL_COUNT" -eq 0 ]; then
            fail "No pool or server configured in $CHRONY_CONF"
            info "  Add a pool entry, e.g. for Germany:"
            info "    pool 0.de.pool.ntp.org iburst"
            info "  See: https://www.ntppool.org/en/zone/de"
        else
            # Show configured sources
            grep -E '^(pool|server)[[:space:]]' "$CHRONY_CONF" 2>/dev/null \
                | while IFS= read -r line; do
                    printf "    %s\n" "$line" | tee -a "${LOG_FILE:-/dev/null}"
                  done
            ok "NTP sources configured in $CHRONY_CONF ($POOL_COUNT entries)"
        fi
    else
        warn "$CHRONY_CONF not found"
    fi

    # Hardware clock hint
    info "  After initial sync, write system time to hardware clock: hwclock -w"
fi

# =============================================================================
# Summary
# =============================================================================

printLine
section "WebLogic Network Readiness Summary"

printf "\n" | tee -a "${LOG_FILE:-/dev/null}"
if [ "$CNT_FAIL" -gt 0 ]; then
    info "Fix all FAIL items before proceeding with WebLogic installation."
    info "Network issues discovered after installation are very hard to correct."
elif [ "$CNT_WARN" -gt 0 ]; then
    info "Review WARN items – some may be acceptable depending on your infrastructure."
    info "Continue with: ./09-Install/01-root_os_baseline.sh"
else
    info "Network baseline is WebLogic-ready."
    info "Continue with: ./09-Install/01-root_os_baseline.sh"
fi

print_summary
exit "$EXIT_CODE"
