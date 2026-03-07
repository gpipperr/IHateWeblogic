#!/bin/bash
# =============================================================================
# Script   : 00-root_os_network.sh
# Purpose  : Phase 0 – Network configuration for Oracle FMW 14.1.2 on OL 9
#            Sets hostname (FQDN), /etc/hosts, NOZEROCONF, nsswitch.conf,
#            IPv6 disable, SSH settings, and chrony time sync.
# Call     : ./09-Install/00-root_os_network.sh
#            ./09-Install/00-root_os_network.sh --apply
# Options  : --apply   Write configuration changes (default: read-only)
#            --help    Show usage
# Requires : hostnamectl, sysctl, systemctl, chronyc
# Runs as  : root or oracle with sudo (configured via 03-root_user_oracle.sh)
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

APPLY_MODE=0

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-16s %s\n" "--apply" "Write configuration changes"
    printf "  %-16s %s\n" "--help"  "Show this help"
    printf "\nExamples:\n"
    printf "  %s\n"         "$(basename "$0")"
    printf "  %s --apply\n" "$(basename "$0")"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)   APPLY_MODE=1; shift ;;
        --help|-h) _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
    esac
done

# =============================================================================
# Root / sudo helper
# =============================================================================

_can_sudo() { sudo -n true 2>/dev/null; }

_run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif _can_sudo; then
        sudo "$@"
    else
        warn "No root/sudo for: $*"
        info "  Run manually: sudo $*"
        return 1
    fi
}

_check_root_access() {
    if [ "$(id -u)" -eq 0 ]; then
        ok "Running as root"
    elif _can_sudo; then
        ok "Running as $(id -un) with sudo"
    else
        fail "Root or sudo access required"
        info "  Configure: /etc/sudoers.d/oracle-fmw"
        info "  Or run as: sudo $(basename "$0")"
        print_summary; exit 2
    fi
}

# =============================================================================
# Banner
# =============================================================================

printLine
section "Network Configuration – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-26s %s\n" "Host (current):"  "$(hostname 2>/dev/null || echo 'unknown')" \
    | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "FQDN (current):"  "$(hostname -f 2>/dev/null || echo 'unknown')" \
    | tee -a "${LOG_FILE:-/dev/null}"
[ "$APPLY_MODE" -eq 1 ] && \
    printf "  %-26s %s\n" "Mode:" "APPLY (will write changes)" \
        | tee -a "${LOG_FILE:-/dev/null}"
printLine

_check_root_access

# =============================================================================
# 1. Hostname (FQDN)
# =============================================================================

section "Hostname (FQDN)"

CURRENT_FQDN="$(hostname -f 2>/dev/null)"
CURRENT_SHORT="$(hostname -s 2>/dev/null)"

# Target FQDN: from environment.conf WLS_SERVER_FQDN, else current
TARGET_FQDN="${WLS_SERVER_FQDN:-$CURRENT_FQDN}"

printf "  %-26s %s\n" "Current FQDN:"   "$CURRENT_FQDN" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "Target FQDN:"    "$TARGET_FQDN"  | tee -a "${LOG_FILE:-/dev/null}"

# Must contain at least one dot (be a true FQDN)
if printf "%s" "$TARGET_FQDN" | grep -qE '\.' ; then
    ok "FQDN contains domain: $TARGET_FQDN"
else
    fail "Hostname is not an FQDN (no domain part): $TARGET_FQDN"
    info "  Set WLS_SERVER_FQDN=hostname.domain.local in environment.conf"
fi

# Must not resolve to loopback
RESOLVED_IP="$(getent hosts "$TARGET_FQDN" 2>/dev/null | awk '{print $1}' | head -1)"
if [ -n "$RESOLVED_IP" ]; then
    case "$RESOLVED_IP" in
        127.*|::1)
            fail "FQDN resolves to loopback ($RESOLVED_IP) – WLS will bind incorrectly"
            info "  Fix: ensure $TARGET_FQDN points to the server's real interface IP in /etc/hosts or DNS"
            ;;
        *)
            ok "FQDN resolves to: $RESOLVED_IP"
            ;;
    esac
else
    warn "FQDN does not resolve: $TARGET_FQDN"
    info "  Add to /etc/hosts or DNS before starting WLS"
fi

# Apply: set hostname if different
if [ "$APPLY_MODE" -eq 1 ] && [ "$CURRENT_FQDN" != "$TARGET_FQDN" ]; then
    if askYesNo "Set hostname to $TARGET_FQDN?" "y"; then
        _run_root hostnamectl set-hostname "$TARGET_FQDN" && \
            ok "Hostname set: $TARGET_FQDN" || fail "hostnamectl failed"
    fi
fi

# =============================================================================
# 2. /etc/hosts
# =============================================================================

section "/etc/hosts"

SERVER_IP="${WLS_SERVER_IP:-$RESOLVED_IP}"
HOST_SHORT="$(printf "%s" "$TARGET_FQDN" | cut -d. -f1)"

printf "  %-26s %s\n" "Server IP:" "${SERVER_IP:-(unknown)}" \
    | tee -a "${LOG_FILE:-/dev/null}"

# Check for loopback-mapped hostname (common cloud/VM issue)
if grep -qE "^127\.0\.1\.1[[:space:]]" /etc/hosts 2>/dev/null; then
    MAPPED_HOST="$(grep -E '^127\.0\.1\.1' /etc/hosts | awk '{print $2}' | head -1)"
    if printf "%s" "$MAPPED_HOST" | grep -qi "$(hostname -s 2>/dev/null)"; then
        fail "Hostname mapped to 127.0.1.1 in /etc/hosts – WLS will bind incorrectly"
        info "  Remove or fix this line in /etc/hosts:"
        grep -E '^127\.0\.1\.1' /etc/hosts | info "    $(cat)"
    fi
fi

# Check if FQDN is in /etc/hosts with a real IP
if [ -n "$SERVER_IP" ] && grep -q "$TARGET_FQDN" /etc/hosts 2>/dev/null; then
    HOSTS_IP="$(grep "$TARGET_FQDN" /etc/hosts | awk '{print $1}' | head -1)"
    if [ "$HOSTS_IP" = "$SERVER_IP" ]; then
        ok "/etc/hosts: $SERVER_IP → $TARGET_FQDN"
    else
        warn "/etc/hosts: $TARGET_FQDN mapped to $HOSTS_IP (expected $SERVER_IP)"
    fi
elif [ -n "$SERVER_IP" ]; then
    warn "$TARGET_FQDN not found in /etc/hosts with IP $SERVER_IP"
    info "  Required entry: $SERVER_IP  $TARGET_FQDN  $HOST_SHORT"
    if [ "$APPLY_MODE" -eq 1 ]; then
        if askYesNo "Add '$SERVER_IP  $TARGET_FQDN  $HOST_SHORT' to /etc/hosts?" "y"; then
            backup_file /etc/hosts
            printf "%s  %s  %s\n" "$SERVER_IP" "$TARGET_FQDN" "$HOST_SHORT" \
                | _run_root tee -a /etc/hosts > /dev/null && \
                ok "/etc/hosts updated" || fail "/etc/hosts update failed"
        fi
    fi
else
    warn "Server IP unknown – cannot verify /etc/hosts entry"
    info "  Set WLS_SERVER_IP=<ip> in environment.conf"
fi

# =============================================================================
# 3. NOZEROCONF
# =============================================================================

section "NOZEROCONF"

NETWORK_FILE="/etc/sysconfig/network"

if [ -f "$NETWORK_FILE" ] && grep -q "NOZEROCONF=yes" "$NETWORK_FILE" 2>/dev/null; then
    ok "NOZEROCONF=yes in $NETWORK_FILE"
else
    warn "NOZEROCONF=yes not set – 169.254.x.x route may interfere with WLS binding"
    info "  Add NOZEROCONF=yes to $NETWORK_FILE"
    if [ "$APPLY_MODE" -eq 1 ]; then
        if askYesNo "Add NOZEROCONF=yes to $NETWORK_FILE?" "y"; then
            if [ -f "$NETWORK_FILE" ]; then
                backup_file "$NETWORK_FILE"
                if grep -q "^NOZEROCONF" "$NETWORK_FILE"; then
                    _run_root sed -i 's/^NOZEROCONF=.*/NOZEROCONF=yes/' "$NETWORK_FILE"
                else
                    printf "NOZEROCONF=yes\n" | _run_root tee -a "$NETWORK_FILE" > /dev/null
                fi
            else
                printf "NOZEROCONF=yes\n" | _run_root tee "$NETWORK_FILE" > /dev/null
            fi
            ok "NOZEROCONF=yes written"
        fi
    fi
fi

# =============================================================================
# 4. nsswitch.conf – files before dns
# =============================================================================

section "nsswitch.conf (files before dns)"

NSSWITCH="/etc/nsswitch.conf"
HOSTS_LINE="$(grep '^hosts:' "$NSSWITCH" 2>/dev/null)"

printf "  %-26s %s\n" "Current hosts line:" "${HOSTS_LINE:-(not found)}" \
    | tee -a "${LOG_FILE:-/dev/null}"

if printf "%s" "$HOSTS_LINE" | grep -qE 'files.*dns'; then
    ok "nsswitch: 'files' before 'dns'"
else
    warn "nsswitch: 'files' is not before 'dns' – /etc/hosts may be bypassed"
    info "  Expected: hosts: files dns myhostname"
    if [ "$APPLY_MODE" -eq 1 ]; then
        if askYesNo "Fix nsswitch.conf hosts line?" "y"; then
            backup_file "$NSSWITCH"
            _run_root sed -i 's/^hosts:.*/hosts:      files dns myhostname/' "$NSSWITCH"
            ok "nsswitch.conf: hosts line fixed"
        fi
    fi
fi

# =============================================================================
# 5. IPv6 disable
# =============================================================================

section "IPv6"

IPV6_ALL="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)"
IPV6_DEF="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)"

if [ "${IPV6_ALL}" = "1" ] && [ "${IPV6_DEF}" = "1" ]; then
    ok "IPv6 disabled (sysctl)"
else
    warn "IPv6 is active – Node Manager may bind to ::1 instead of 127.0.0.1"
    info "  net.ipv6.conf.all.disable_ipv6     = ${IPV6_ALL:-0}"
    info "  net.ipv6.conf.default.disable_ipv6 = ${IPV6_DEF:-0}"
    info "  Note: also set explicit ListenAddress=127.0.0.1 in WLS and nodemanager.properties"
fi

# Check sysctl file (will be written by 01-root_os_baseline.sh with all kernel params)
SYSCTL_FMW="/etc/sysctl.d/99-oracle-fmw.conf"
if [ -f "$SYSCTL_FMW" ] && grep -q "disable_ipv6" "$SYSCTL_FMW" 2>/dev/null; then
    ok "IPv6 disable entries present in $SYSCTL_FMW (persistent)"
else
    info "IPv6 disable will be written to $SYSCTL_FMW by 01-root_os_baseline.sh"
fi

# =============================================================================
# 6. SSH configuration
# =============================================================================

section "SSH Configuration"

SSHD_CFG="/etc/ssh/sshd_config"

_check_sshd() {
    local key="$1" expected="$2"
    local val
    val="$(grep -E "^[[:space:]]*${key}[[:space:]]" "$SSHD_CFG" 2>/dev/null \
        | awk '{print $2}' | head -1)"
    if [ "$val" = "$expected" ]; then
        ok "sshd: $key=$val"
        return 0
    else
        warn "sshd: $key=${val:-(not set, using default)} (expected: $expected)"
        return 1
    fi
}

X11_OK=0
ADDR_OK=0
_check_sshd "X11Forwarding"   "yes"  && X11_OK=1
_check_sshd "X11UseLocalhost" "no"
_check_sshd "AddressFamily"   "inet" && ADDR_OK=1

if [ "$APPLY_MODE" -eq 1 ] && { [ "$X11_OK" -eq 0 ] || [ "$ADDR_OK" -eq 0 ]; }; then
    if askYesNo "Apply SSH configuration changes?" "y"; then
        backup_file "$SSHD_CFG"

        _sshd_set() {
            local key="$1" val="$2"
            if grep -qE "^[[:space:]]*${key}[[:space:]]" "$SSHD_CFG"; then
                _run_root sed -i "s|^[[:space:]#]*${key}[[:space:]].*|${key} ${val}|" "$SSHD_CFG"
            else
                printf "%s %s\n" "$key" "$val" | _run_root tee -a "$SSHD_CFG" > /dev/null
            fi
        }

        _sshd_set "X11Forwarding"   "yes"
        _sshd_set "X11UseLocalhost" "no"
        _sshd_set "AddressFamily"   "inet"

        if _run_root sshd -t; then
            _run_root systemctl reload sshd 2>/dev/null || _run_root systemctl reload ssh 2>/dev/null
            ok "sshd configuration applied and reloaded"
        else
            fail "sshd -t failed – check $SSHD_CFG manually"
        fi
    fi
fi

# =============================================================================
# 7. Chrony (time synchronization)
# =============================================================================

section "Time Synchronization (chrony)"

if ! command -v chronyc > /dev/null 2>&1; then
    warn "chronyd not installed – install with: dnf install chrony"
    info "  Time synchronization is required for SSL certificates and WLS cluster"
else
    # Service running?
    if _run_root systemctl is-active chronyd > /dev/null 2>&1; then
        ok "chronyd is active"
    else
        fail "chronyd is not running"
        info "  Start: systemctl enable --now chronyd"
        if [ "$APPLY_MODE" -eq 1 ]; then
            if askYesNo "Enable and start chronyd?" "y"; then
                _run_root systemctl enable --now chronyd && \
                    ok "chronyd started" || fail "Failed to start chronyd"
            fi
        fi
    fi

    # Synchronized?
    SYNC_STATUS="$(timedatectl show --property=NTPSynchronized --value 2>/dev/null)"
    if [ "$SYNC_STATUS" = "yes" ]; then
        ok "System clock synchronized (chrony)"
        # Show tracking info
        CHRONY_REF="$(chronyc tracking 2>/dev/null | grep 'Reference ID' | head -1)"
        [ -n "$CHRONY_REF" ] && info "  $CHRONY_REF"
    else
        warn "System clock not yet synchronized – time drift may cause SSL/WLS issues"
        info "  Check: chronyc tracking"
        info "  Sync:  chronyc makestep"
    fi

    # NTP server from environment.conf
    if [ -n "${NTP_SERVER:-}" ]; then
        CHRONY_CONF="/etc/chrony.conf"
        if grep -q "$NTP_SERVER" "$CHRONY_CONF" 2>/dev/null; then
            ok "NTP_SERVER $NTP_SERVER already in $CHRONY_CONF"
        else
            warn "NTP_SERVER $NTP_SERVER not in $CHRONY_CONF"
            info "  Add: server $NTP_SERVER iburst"
            if [ "$APPLY_MODE" -eq 1 ]; then
                if askYesNo "Add $NTP_SERVER to $CHRONY_CONF?" "y"; then
                    backup_file "$CHRONY_CONF"
                    printf "server %s iburst\n" "$NTP_SERVER" \
                        | _run_root tee -a "$CHRONY_CONF" > /dev/null
                    _run_root systemctl restart chronyd
                    ok "NTP server $NTP_SERVER added to chrony"
                fi
            fi
        fi
    else
        info "NTP_SERVER not set in environment.conf – using chrony defaults"
    fi
fi

# =============================================================================
# Summary
# =============================================================================

printLine
if [ "$APPLY_MODE" -eq 0 ] && [ "$CNT_FAIL" -gt 0 ]; then
    info "Re-run with --apply to fix reported issues"
fi
if [ "$CNT_FAIL" -eq 0 ] && [ "$CNT_WARN" -eq 0 ]; then
    info "Network configuration complete – proceed to 01-root_os_baseline.sh"
fi

print_summary
exit "$EXIT_CODE"
