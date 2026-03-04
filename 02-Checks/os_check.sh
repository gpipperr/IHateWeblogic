#!/bin/bash
# =============================================================================
# Script   : os_check.sh
# Purpose  : Validate OS version, kernel, system resources, ulimits, SELinux,
#            and required OS packages for Oracle Forms/Reports 12c / 14c on OL8/9
# Call     : ./os_check.sh
# Requires : uname, rpm, ulimit, free, df, getenforce, systemctl
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/install-fnr/
#            https://docs.oracle.com/middleware/12213/formsandreports/install-fnr/
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"

LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m Cannot find IHateWeblogic_lib.sh: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=00-Setup/IHateWeblogic_lib.sh
source "$LIB"

check_env_conf "$ENV_CONF" || exit 2
source "$ENV_CONF"

init_log

# =============================================================================
# Banner
# =============================================================================
printLine
printf "\n\033[1mIHateWeblogic – OS & System Check\033[0m\n"
printf "Host    : %s\n" "$(_get_hostname)"
printf "Date    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "User    : %s\n" "$(id)"
printf "Log     : %s\n\n" "$LOG_FILE"

# =============================================================================
# Helper: convert kB to human-readable
# =============================================================================
_kb_to_human() {
    local kb="$1"
    if [ "$kb" -ge 1048576 ]; then
        printf "%d GB" $(( kb / 1048576 ))
    elif [ "$kb" -ge 1024 ]; then
        printf "%d MB" $(( kb / 1024 ))
    else
        printf "%d KB" "$kb"
    fi
}

# =============================================================================
# Section 1: OS Version & Kernel
# =============================================================================
section "OS Version & Kernel"

OS_NAME=""
OS_VERSION=""
OS_FULL=""

if [ -f /etc/oracle-release ]; then
    OS_FULL="$(cat /etc/oracle-release)"
    OS_NAME="Oracle Linux"
    OS_VERSION="$(grep -oE '[0-9]+\.[0-9]+' /etc/oracle-release | head -1)"
elif [ -f /etc/redhat-release ]; then
    OS_FULL="$(cat /etc/redhat-release)"
    OS_NAME="$(awk '{print $1}' /etc/redhat-release)"
    OS_VERSION="$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)"
elif [ -f /etc/os-release ]; then
    OS_FULL="$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
    OS_NAME="$(grep '^NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')"
    OS_VERSION="$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
fi

OS_MAJOR="${OS_VERSION%%.*}"

printList "OS Release" 30 "${OS_FULL:-unknown}"
printList "OS Version" 30 "${OS_VERSION:-unknown}"

# Certification check
# Ref: Oracle Forms 14c certified on OL8/9 – support.oracle.com Certification Matrix
case "${OS_NAME}" in
    *Oracle*)
        case "${OS_MAJOR}" in
            8)  ok "Oracle Linux 8 – certified for Oracle Forms/Reports 12c and 14c" ;;
            9)  ok "Oracle Linux 9 – certified for Oracle Forms 14c" ;;
            7)  warn "Oracle Linux 7 – approaching EOL; Forms 14c prefers OL8/9" ;;
            *)  warn "Oracle Linux ${OS_MAJOR} – verify certification at support.oracle.com" ;;
        esac
        ;;
    *Red*Hat*)
        ok "RHEL ${OS_VERSION} – compatible base OS for Oracle FMW" ;;
    *)
        warn "OS '${OS_NAME}' – verify FMW certification at support.oracle.com" ;;
esac

KERNEL="$(uname -r)"
ARCH="$(uname -m)"
printList "Kernel" 30 "$KERNEL"
printList "Architecture" 30 "$ARCH"

if [ "$ARCH" = "x86_64" ]; then
    ok "Architecture x86_64 – supported"
else
    fail "Architecture ${ARCH} – Oracle Forms/Reports requires x86_64"
fi

# =============================================================================
# Section 2: System Resources – RAM, CPU, Disk, Swap
# =============================================================================
section "System Resources"

# RAM
# Oracle Forms 14c: minimum 4 GB, recommended 8 GB+ for production
if [ -f /proc/meminfo ]; then
    MEM_TOTAL_KB="$(awk '/MemTotal/    {print $2}' /proc/meminfo)"
    MEM_FREE_KB="$(awk  '/MemAvailable/{print $2}' /proc/meminfo)"
    MEM_TOTAL_GB=$(( MEM_TOTAL_KB / 1048576 ))

    printList "Total RAM"     30 "$(_kb_to_human "$MEM_TOTAL_KB")"
    printList "Available RAM" 30 "$(_kb_to_human "$MEM_FREE_KB")"

    if   [ "$MEM_TOTAL_GB" -lt 4 ]; then
        fail "RAM ${MEM_TOTAL_GB} GB – below minimum 4 GB for Oracle FMW"
    elif [ "$MEM_TOTAL_GB" -lt 8 ]; then
        warn "RAM ${MEM_TOTAL_GB} GB – minimum met, 8 GB recommended for production"
    else
        ok   "RAM ${MEM_TOTAL_GB} GB – meets production recommendation (>= 8 GB)"
    fi

    # Swap
    SWAP_TOTAL_KB="$(awk '/SwapTotal/{print $2}' /proc/meminfo)"
    SWAP_FREE_KB="$(awk  '/SwapFree/ {print $2}' /proc/meminfo)"
    printList "Swap Total" 30 "$(_kb_to_human "$SWAP_TOTAL_KB")"
    printList "Swap Free"  30 "$(_kb_to_human "$SWAP_FREE_KB")"
    SWAP_TOTAL_GB=$(( SWAP_TOTAL_KB / 1048576 ))
    if [ "$SWAP_TOTAL_GB" -lt 2 ]; then
        warn "Swap ${SWAP_TOTAL_GB} GB – recommend >= 2 GB (ideally equal to RAM for < 8 GB systems)"
    else
        ok "Swap ${SWAP_TOTAL_GB} GB – sufficient"
    fi
else
    warn "/proc/meminfo not available – cannot check RAM"
fi

printf "\n"

# CPU
CPU_COUNT="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 0)"
CPU_MODEL="$(grep '^model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs)"
printList "CPU Cores" 30 "$CPU_COUNT"
printList "CPU Model" 30 "${CPU_MODEL:-unknown}"

if [ "${CPU_COUNT}" -lt 2 ]; then
    warn "Only ${CPU_COUNT} CPU core(s) – minimum 2 recommended for Forms/Reports"
else
    ok "CPU cores: ${CPU_COUNT}"
fi

printf "\n"

# Disk space per relevant path
for check_dir in "${FMW_HOME}" "${DOMAIN_HOME}" "/tmp" "/var/log"; do
    [ -d "$check_dir" ] || continue
    AVAIL_KB="$(df -k "$check_dir" 2>/dev/null | awk 'NR==2{print $4}')"
    TOTAL_KB="$(df -k "$check_dir" 2>/dev/null | awk 'NR==2{print $2}')"
    USE_PCT="$(df -k  "$check_dir" 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%')"
    AVAIL_GB=$(( ${AVAIL_KB:-0} / 1048576 ))

    printList "Disk: $check_dir" 30 \
        "avail=$(_kb_to_human "${AVAIL_KB:-0}") / total=$(_kb_to_human "${TOTAL_KB:-0}") use=${USE_PCT}%"

    case "$check_dir" in
        "${FMW_HOME}")
            [ "$AVAIL_GB" -lt 5 ] && \
                fail "FMW_HOME: only ${AVAIL_GB} GB free (FMW installation needs ~30 GB)" || \
                ok   "FMW_HOME: ${AVAIL_GB} GB free"
            ;;
        "/tmp")
            [ "$AVAIL_GB" -lt 1 ] && \
                warn "/tmp: only ${AVAIL_GB} GB free (Oracle installer needs ~1 GB)" || \
                ok   "/tmp: ${AVAIL_GB} GB free"
            ;;
    esac

    [ "${USE_PCT:-0}" -ge 90 ] && \
        warn "DISK USAGE ${USE_PCT}% on $check_dir – risk of disk full!"
done

# =============================================================================
# Section 3: ulimits
# =============================================================================
section "ulimits"

# Oracle WebLogic / FMW recommended limits:
# nofile : >= 65536 (recommend 131072)
# nproc  : >= 65536
info "Oracle FMW recommended ulimits (for the oracle OS user):"
info "  nofile (open files): soft/hard >= 65536  (recommended: 131072)"
info "  nproc  (max procs) : soft/hard >= 65536"
printf "\n"

info "Current session limits (user: $(id -un)):"

_check_ulimit() {
    local name="$1"
    local flag="$2"
    local min="${3:-0}"

    local soft hard
    soft="$(ulimit -S "$flag" 2>/dev/null)"
    hard="$(ulimit -H "$flag" 2>/dev/null)"

    printList "  $name soft" 28 "$soft"
    printList "  $name hard" 28 "$hard"

    if [ "$min" -gt 0 ] && [ "$soft" != "unlimited" ]; then
        if [ "$soft" -lt "$min" ]; then
            fail "  $name soft ${soft} < recommended ${min}"
        else
            ok "  $name soft ${soft} >= ${min}"
        fi
    elif [ "$soft" = "unlimited" ]; then
        ok "  $name: unlimited"
    fi
}

_check_ulimit "nofile (open files)" "-n" 65536
_check_ulimit "nproc  (max procs)"  "-u" 65536
_check_ulimit "stack  (kB)"         "-s" 0
_check_ulimit "core   (kB)"         "-c" 0

printf "\n"

# Configured limits in /etc/security/limits.conf and limits.d/
ORACLE_USER="${ORACLE_OS_USER:-oracle}"
info "Configured limits for user '${ORACLE_USER}' in /etc/security/limits*:"

FOUND_ORACLE_LIMITS=false
LIMIT_FILES=()
[ -f /etc/security/limits.conf ] && LIMIT_FILES+=("/etc/security/limits.conf")
while IFS= read -r f; do
    LIMIT_FILES+=("$f")
done < <(find /etc/security/limits.d/ -name "*.conf" 2>/dev/null | sort)

for lf in "${LIMIT_FILES[@]}"; do
    MATCHES="$(grep -E "^\s*(${ORACLE_USER}|\*)\s" "$lf" 2>/dev/null | grep -v '^#')"
    if [ -n "$MATCHES" ]; then
        FOUND_ORACLE_LIMITS=true
        info "  File: $lf"
        while IFS= read -r line; do
            printList "    " 4 "$line"
        done <<< "$MATCHES"
    fi
done

if ! $FOUND_ORACLE_LIMITS; then
    warn "No explicit limits configured for user '${ORACLE_USER}'"
    info "  Recommended: create /etc/security/limits.d/oracle-fmw.conf"
    info "    ${ORACLE_USER} soft nofile 131072"
    info "    ${ORACLE_USER} hard nofile 131072"
    info "    ${ORACLE_USER} soft nproc  65536"
    info "    ${ORACLE_USER} hard nproc  65536"
fi

# =============================================================================
# Section 4: SELinux & Firewall
# =============================================================================
section "SELinux & Firewall"

# SELinux
if command -v getenforce >/dev/null 2>&1; then
    SELINUX_STATUS="$(getenforce 2>/dev/null)"
    printList "SELinux mode (runtime)" 30 "$SELINUX_STATUS"
    case "$SELINUX_STATUS" in
        Disabled)   ok "SELinux Disabled" ;;
        Permissive) ok "SELinux Permissive – actions logged, not blocked" ;;
        Enforcing)
            warn "SELinux Enforcing – may block FMW operations"
            info "  Verify FMW directories have correct SELinux context"
            info "  Temporary switch to permissive: setenforce 0"
            ;;
    esac
else
    info "getenforce not found – SELinux likely not installed"
fi

if [ -f /etc/selinux/config ]; then
    SELINUX_CONF="$(grep '^SELINUX=' /etc/selinux/config | cut -d= -f2)"
    printList "SELinux config (persistent)" 30 "${SELINUX_CONF:-unknown}"
fi

printf "\n"

# Firewall
if command -v firewall-cmd >/dev/null 2>&1; then
    FW_STATE="$(firewall-cmd --state 2>/dev/null)"
    printList "firewalld state" 30 "$FW_STATE"
    if [ "$FW_STATE" = "running" ]; then
        warn "firewalld is running – verify WebLogic/OHS ports are open (see port_check.sh)"
    else
        ok "firewalld not running"
    fi
elif command -v systemctl >/dev/null 2>&1; then
    FW_ACTIVE="$(systemctl is-active firewalld 2>/dev/null || echo 'unknown')"
    printList "firewalld (systemctl)" 30 "$FW_ACTIVE"
fi

# =============================================================================
# Section 5: Required OS Packages
# =============================================================================
section "Required OS Packages"

# Ref: Oracle Forms 14c / Reports 12c Install Guide – system requirements
# https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/install-fnr/

if ! command -v rpm >/dev/null 2>&1; then
    warn "rpm not available – package check skipped"
else
    _check_pkg() {
        local pkg="$1"
        if rpm -q "$pkg" >/dev/null 2>&1; then
            local ver
            ver="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$pkg" 2>/dev/null)"
            ok "  ${pkg} – installed (${ver})"
            return 0
        else
            return 1
        fi
    }

    # Critical: FMW will not install or start without these
    CRITICAL_PKGS=(
        "glibc"
        "libgcc"
        "libstdc++"
        "libXi"
        "libXtst"
        "libXext"
        "libXrender"
        "libX11"
        "fontconfig"
        "freetype"
        "libaio"
        "binutils"
        "unzip"
    )

    # Oracle Reports requires CUPS for print support
    REPORTS_PKGS=(
        "cups"
        "cups-libs"
    )

    # Tools used by other IHateWeblogic scripts
    DIAG_PKGS=(
        "strace"
        "lsof"
        "sysstat"
        "xorg-x11-server-Xvfb"
        "fonttools"
    )

    ALL_MISSING=()

    info "-- Critical packages (FMW requires these) --"
    MISSING_CRITICAL=0
    for pkg in "${CRITICAL_PKGS[@]}"; do
        if ! _check_pkg "$pkg"; then
            fail "  ${pkg} – NOT installed"
            ALL_MISSING+=("$pkg")
            MISSING_CRITICAL=$(( MISSING_CRITICAL + 1 ))
        fi
    done
    [ "$MISSING_CRITICAL" -eq 0 ] && ok "All critical packages present"

    printf "\n"
    info "-- Oracle Reports printer support (CUPS) --"
    MISSING_REPORTS=0
    for pkg in "${REPORTS_PKGS[@]}"; do
        if ! _check_pkg "$pkg"; then
            warn "  ${pkg} – NOT installed (required for Reports print support)"
            ALL_MISSING+=("$pkg")
            MISSING_REPORTS=$(( MISSING_REPORTS + 1 ))
        fi
    done
    [ "$MISSING_REPORTS" -eq 0 ] && ok "All Reports printer packages present"

    printf "\n"
    info "-- Diagnostic tools (used by IHateWeblogic scripts) --"
    MISSING_DIAG=0
    for pkg in "${DIAG_PKGS[@]}"; do
        if ! _check_pkg "$pkg"; then
            warn "  ${pkg} – NOT installed (recommended for diagnostics)"
            ALL_MISSING+=("$pkg")
            MISSING_DIAG=$(( MISSING_DIAG + 1 ))
        fi
    done
    [ "$MISSING_DIAG" -eq 0 ] && ok "All diagnostic tools present"

    # 32-bit glibc (some Oracle tools need it)
    printf "\n"
    info "-- 32-bit glibc (required by some Oracle tools) --"
    if ! _check_pkg "glibc.i686"; then
        warn "  glibc.i686 not installed"
        info "  Install if Oracle tools report missing 32-bit libraries:"
        info "    dnf install -y glibc.i686 libstdc++.i686"
        ALL_MISSING+=("glibc.i686")
    fi

    # Print consolidated install command
    if [ "${#ALL_MISSING[@]}" -gt 0 ]; then
        printf "\n"
        info "To install all missing packages (run as root):"
        info "  dnf install -y ${ALL_MISSING[*]}"
    fi
fi

# =============================================================================
# Section 6: Hostname & Network
# =============================================================================
section "Hostname & Network"

HOSTNAME_SHORT="$(hostname 2>/dev/null)"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || echo 'n/a')"
HOSTNAME_IP="$(hostname -i 2>/dev/null || echo 'n/a')"

printList "Hostname (short)" 30 "$HOSTNAME_SHORT"
printList "Hostname (FQDN)"  30 "$HOSTNAME_FQDN"
printList "IP Address"       30 "$HOSTNAME_IP"

# Oracle FMW requires a resolvable FQDN
if [ "$HOSTNAME_FQDN" = "n/a" ] || [ "$HOSTNAME_FQDN" = "$HOSTNAME_SHORT" ]; then
    warn "FQDN not resolvable or same as short hostname – Oracle FMW may have DNS issues"
    info "  Ensure /etc/hosts or DNS provides a proper FQDN for this host"
else
    ok "FQDN resolvable: $HOSTNAME_FQDN"
fi

# Warn if hostname resolves to loopback
if echo "$HOSTNAME_IP" | grep -qE '^127\.'; then
    warn "Hostname resolves to loopback (${HOSTNAME_IP}) – WebLogic Node Manager/cluster may fail"
    info "  Set a real IP in /etc/hosts for: $HOSTNAME_FQDN"
else
    ok "Hostname resolves to non-loopback: $HOSTNAME_IP"
fi

# Show relevant /etc/hosts entries
HOSTS_ENTRIES="$(grep -E "${HOSTNAME_SHORT}|${HOSTNAME_FQDN}" /etc/hosts 2>/dev/null \
    | grep -v '^#' || true)"
if [ -n "$HOSTS_ENTRIES" ]; then
    info "/etc/hosts entries for this host:"
    while IFS= read -r line; do
        printList "  " 4 "$line"
    done <<< "$HOSTS_ENTRIES"
fi

# =============================================================================
# Summary
# =============================================================================
print_summary
exit $EXIT_CODE
