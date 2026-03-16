#!/bin/bash
# =============================================================================
# Script   : os_check.sh
# Purpose  : Validate OS version, kernel, system resources, ulimits,
#            kernel parameters, SELinux, and required OS packages
#            for Oracle Forms/Reports 12c / 14c on OL8/9
# Call     : ./os_check.sh
# Requires : uname, rpm, ulimit, free, df, sysctl, getenforce, systemctl
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

# CV_ASSUME_DISTID – required on OL9 for Oracle Universal Installer
CV_ASSUME="${CV_ASSUME_DISTID:-}"
printList "CV_ASSUME_DISTID" 30 "${CV_ASSUME:-not set}"
if [ -z "$CV_ASSUME" ]; then
    warn "CV_ASSUME_DISTID not set – required on OL9 for Oracle Universal Installer"
    info "  Add to oracle user .bash_profile: export CV_ASSUME_DISTID=RHEL8"
else
    ok "CV_ASSUME_DISTID=${CV_ASSUME}"
fi

printf "\n"

# LANG / LC_ALL – Oracle FMW requires en_US.UTF-8 for correct Unicode handling
# Ref: Oracle WLS 14.1.2 install guide section 2.1.1
LANG_VAL="${LANG:-}"
LC_ALL_VAL="${LC_ALL:-}"
printList "LANG"   30 "${LANG_VAL:-not set}"
printList "LC_ALL" 30 "${LC_ALL_VAL:-not set}"

if [ "${LANG_VAL}" = "en_US.UTF-8" ]; then
    ok "LANG=en_US.UTF-8"
else
    warn "LANG '${LANG_VAL}' – Oracle FMW recommends LANG=en_US.UTF-8"
    info "  Add to oracle user .bashrc: export LC_ALL=en_US.UTF-8"
fi

printf "\n"

# umask – Oracle requires umask 027 during FMW installation
UMASK_VAL="$(umask 2>/dev/null)"
printList "umask" 30 "$UMASK_VAL"
if [ "$UMASK_VAL" = "0027" ] || [ "$UMASK_VAL" = "027" ]; then
    ok "umask 027 – meets Oracle FMW requirement"
else
    warn "umask ${UMASK_VAL} – Oracle FMW installation requires umask 027"
    info "  Add to oracle user .bash_profile: umask 027"
fi

# =============================================================================
# Section 2: System Resources – RAM, CPU, Disk, Swap
# =============================================================================
section "System Resources"

# RAM – Oracle FMW 14.1.2 requirements:
# OS minimum: 8 GB; DEV/QS: 16 GB; PRD: 64 GB (incl. DB if on same server)
# Ref: Oracle WLS 14.1.2 install guide – Memory Requirements table
if [ -f /proc/meminfo ]; then
    MEM_TOTAL_KB="$(awk '/MemTotal/    {print $2}' /proc/meminfo)"
    MEM_FREE_KB="$(awk  '/MemAvailable/{print $2}' /proc/meminfo)"
    MEM_TOTAL_GB=$(( MEM_TOTAL_KB / 1048576 ))

    printList "Total RAM"     30 "$(_kb_to_human "$MEM_TOTAL_KB")"
    printList "Available RAM" 30 "$(_kb_to_human "$MEM_FREE_KB")"

    if   [ "$MEM_TOTAL_GB" -lt 8 ]; then
        fail "RAM ${MEM_TOTAL_GB} GB – below OS minimum 8 GB for Oracle FMW"
    elif [ "$MEM_TOTAL_GB" -lt 16 ]; then
        warn "RAM ${MEM_TOTAL_GB} GB – OS minimum met; DEV/QS requires >= 16 GB"
    elif [ "$MEM_TOTAL_GB" -lt 64 ]; then
        ok   "RAM ${MEM_TOTAL_GB} GB – meets DEV/QS requirement (PRD needs >= 64 GB incl. DB)"
    else
        ok   "RAM ${MEM_TOTAL_GB} GB – meets production requirement (>= 64 GB)"
    fi

    # Swap
    SWAP_TOTAL_KB="$(awk '/SwapTotal/{print $2}' /proc/meminfo)"
    SWAP_FREE_KB="$(awk  '/SwapFree/ {print $2}' /proc/meminfo)"
    printList "Swap Total" 30 "$(_kb_to_human "$SWAP_TOTAL_KB")"
    printList "Swap Free"  30 "$(_kb_to_human "$SWAP_FREE_KB")"
    SWAP_TOTAL_GB=$(( SWAP_TOTAL_KB / 1048576 ))
    if [ "$SWAP_TOTAL_GB" -lt 2 ]; then
        warn "Swap ${SWAP_TOTAL_GB} GB – Oracle installer requires >= 512 MB; recommend >= 2 GB"
    else
        ok "Swap ${SWAP_TOTAL_GB} GB – sufficient"
    fi
else
    warn "/proc/meminfo not available – cannot check RAM"
    MEM_TOTAL_KB=0
fi

printf "\n"

# CPU – Oracle FMW 14.1.2: min 1 CPU, DEV 2 CPU, PRD 4 CPU
CPU_COUNT="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 0)"
CPU_MODEL="$(grep '^model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs)"
printList "CPU Cores" 30 "$CPU_COUNT"
printList "CPU Model" 30 "${CPU_MODEL:-unknown}"

if   [ "${CPU_COUNT}" -lt 2 ]; then
    warn "CPU cores ${CPU_COUNT} – minimum 1 met; DEV requires >= 2, PRD >= 4"
elif [ "${CPU_COUNT}" -lt 4 ]; then
    ok   "CPU cores ${CPU_COUNT} – meets DEV/QS requirement (PRD requires >= 4)"
else
    ok   "CPU cores ${CPU_COUNT} – meets production requirement (>= 4)"
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
                warn "/tmp: only ${AVAIL_GB} GB free (Oracle installer needs ~300 MB)" || \
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

# Oracle WebLogic / FMW required limits (oracle-database-preinstall-19c.conf values):
# Ref: Oracle WLS 14.1.2 install guide – section 2.1.2
info "Oracle FMW required ulimits (for the oracle OS user):"
info "  nofile: soft >= 4096,      hard >= 65536"
info "  nproc : soft >= 16384,     hard >= 16384"
info "  stack : soft >= 10240 kB,  hard >= 32768 kB"
info "  memlock: soft/hard >= 134217728 kB (128 GB cap or 90% of RAM)"
info "  data  : unlimited"
printf "\n"

info "Current session limits (user: $(id -un)):"

# _check_ulimit name flag min_soft min_hard
# min_soft / min_hard = 0 means skip that check
_check_ulimit() {
    local name="$1"
    local flag="$2"
    local min_soft="${3:-0}"
    local min_hard="${4:-0}"

    local soft hard
    soft="$(ulimit -S "$flag" 2>/dev/null)"
    hard="$(ulimit -H "$flag" 2>/dev/null)"

    printList "  $name soft" 30 "$soft"
    printList "  $name hard" 30 "$hard"

    # Check soft
    if [ "$min_soft" -gt 0 ]; then
        if [ "$soft" = "unlimited" ]; then
            ok "  $name soft: unlimited (>= ${min_soft})"
        elif [ "$soft" -lt "$min_soft" ] 2>/dev/null; then
            warn "  $name soft ${soft} < recommended ${min_soft}"
        else
            ok "  $name soft ${soft} >= ${min_soft}"
        fi
    fi

    # Check hard
    if [ "$min_hard" -gt 0 ]; then
        if [ "$hard" = "unlimited" ]; then
            ok "  $name hard: unlimited (>= ${min_hard})"
        elif [ "$hard" -lt "$min_hard" ] 2>/dev/null; then
            fail "  $name hard ${hard} < required ${min_hard}"
        else
            ok "  $name hard ${hard} >= ${min_hard}"
        fi
    fi
}

_check_ulimit "nofile (open files)" "-n" 4096   65536
_check_ulimit "nproc  (max procs)"  "-u" 16384  16384
_check_ulimit "stack  (kB)"         "-s" 10240  32768
_check_ulimit "core   (kB)"         "-c" 0      0

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
    info "    ${ORACLE_USER} soft nofile  4096"
    info "    ${ORACLE_USER} hard nofile  65536"
    info "    ${ORACLE_USER} soft nproc   16384"
    info "    ${ORACLE_USER} hard nproc   16384"
    info "    ${ORACLE_USER} soft stack   10240"
    info "    ${ORACLE_USER} hard stack   32768"
    info "    ${ORACLE_USER} soft memlock 134217728"
    info "    ${ORACLE_USER} hard memlock 134217728"
    info "    ${ORACLE_USER} soft data    unlimited"
    info "    ${ORACLE_USER} hard data    unlimited"
fi

# =============================================================================
# Section 4: Kernel Parameters
# =============================================================================
section "Kernel Parameters"

# Required kernel parameters per Oracle WLS 14.1.2 install guide
# Ref: oracle-database-preinstall-19c-sysctl.conf values used in this installation
# File: /etc/sysctl.d/99-oracle-database-preinstall-19c-sysctl.conf
info "Checking sysctl kernel parameters against Oracle FMW requirements:"
printf "\n"

if ! command -v sysctl >/dev/null 2>&1; then
    warn "sysctl not available – kernel parameter check skipped"
else
    # _check_sysctl param min_value description
    _check_sysctl() {
        local param="$1"
        local min="$2"
        local desc="${3:-}"
        local value
        value="$(sysctl -n "$param" 2>/dev/null)"

        if [ -z "$value" ]; then
            printList "  $param" 36 "n/a"
            warn "  Cannot read $param"
            return
        fi

        # Take first number for multi-value params (e.g. kernel.sem)
        local first_val
        first_val="$(echo "$value" | awk '{print $1}')"
        printList "  $param" 36 "$value"

        if [ "$min" = "0" ]; then
            info "  $param = ${value}${desc:+ (${desc})}"
            return
        fi

        if [ "$first_val" -ge "$min" ] 2>/dev/null; then
            ok "  $param ${first_val} >= ${min}${desc:+ (${desc})}"
        else
            fail "  $param ${first_val} < required ${min}${desc:+ (${desc})}"
        fi
    }

    # fs.file-max – max open file handles system-wide; Oracle requires >= 6815744
    _check_sysctl "fs.file-max" 6815744 "required by Oracle FMW"

    # fs.aio-max-nr – async I/O; Oracle requires >= 1048576
    _check_sysctl "fs.aio-max-nr" 1048576 "async I/O limit"

    # kernel.sem – semaphore params: semmsl semmns semopm semmni
    # Oracle requires: 250 32000 100 128
    SEM_VAL="$(sysctl -n kernel.sem 2>/dev/null)"
    if [ -n "$SEM_VAL" ]; then
        printList "  kernel.sem" 36 "$SEM_VAL"
        SEM_ARR=( $SEM_VAL )
        SEM_OK=true
        [ "${SEM_ARR[0]:-0}" -lt 250 ]  && SEM_OK=false
        [ "${SEM_ARR[1]:-0}" -lt 32000 ] && SEM_OK=false
        [ "${SEM_ARR[2]:-0}" -lt 100 ]  && SEM_OK=false
        [ "${SEM_ARR[3]:-0}" -lt 128 ]  && SEM_OK=false
        if $SEM_OK; then
            ok "  kernel.sem meets Oracle requirement (250 32000 100 128)"
        else
            fail "  kernel.sem ${SEM_VAL} < required '250 32000 100 128'"
        fi
    else
        warn "  kernel.sem: cannot read"
    fi

    # Shared memory parameters
    _check_sysctl "kernel.shmmni" 4096 "shared memory segments"

    # kernel.shmall: for pure WebLogic/FMW set to total RAM expressed in 4K pages.
    # Oracle DB preinstall sets 1073741824 pages (= 4 TB) – a DB-only requirement, not needed here.
    # Ref: 09-Install/01-root_os_baseline.sh – SYSCTL_WANT["kernel.shmall"] = RAM_kB / 4
    SHMALL_VAL="$(sysctl -n kernel.shmall 2>/dev/null)"
    if [ -n "$SHMALL_VAL" ]; then
        printList "  kernel.shmall" 36 "$SHMALL_VAL"
        if [ "${MEM_TOTAL_KB:-0}" -gt 0 ]; then
            SHMALL_MIN=$(( MEM_TOTAL_KB / 4 ))    # total RAM in 4K pages
            if [ "$SHMALL_VAL" -ge "$SHMALL_MIN" ] 2>/dev/null; then
                ok "  kernel.shmall ${SHMALL_VAL} >= RAM pages ${SHMALL_MIN} (WLS FMW OK)"
            else
                warn "  kernel.shmall ${SHMALL_VAL} – recommend >= RAM pages ${SHMALL_MIN}"
            fi
        else
            ok "  kernel.shmall = ${SHMALL_VAL}"
        fi
    else
        warn "  Cannot read kernel.shmall"
    fi

    # kernel.shmmax – must be >= half of physical RAM, per Oracle docs
    SHMMAX_VAL="$(sysctl -n kernel.shmmax 2>/dev/null)"
    if [ -n "$SHMMAX_VAL" ] && [ "${MEM_TOTAL_KB:-0}" -gt 0 ]; then
        SHMMAX_MIN=$(( MEM_TOTAL_KB * 512 ))   # half of RAM in bytes (KB * 1024 / 2)
        printList "  kernel.shmmax" 36 "$SHMMAX_VAL"
        if [ "$SHMMAX_VAL" -ge "$SHMMAX_MIN" ] 2>/dev/null; then
            ok "  kernel.shmmax ${SHMMAX_VAL} >= half RAM (${SHMMAX_MIN})"
        else
            warn "  kernel.shmmax ${SHMMAX_VAL} – recommend >= half RAM (${SHMMAX_MIN})"
        fi
    elif [ -n "$SHMMAX_VAL" ]; then
        printList "  kernel.shmmax" 36 "$SHMMAX_VAL"
        ok "  kernel.shmmax = ${SHMMAX_VAL}"
    fi

    # Network buffer parameters
    _check_sysctl "net.core.rmem_default" 262144  "receive buffer default"
    _check_sysctl "net.core.rmem_max"     4194304 "receive buffer max"
    _check_sysctl "net.core.wmem_default" 262144  "send buffer default"
    _check_sysctl "net.core.wmem_max"     1048576 "send buffer max"

    # IP port range – Oracle requires starting at 9000
    PORT_RANGE="$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null)"
    if [ -n "$PORT_RANGE" ]; then
        PORT_LOW="$(echo "$PORT_RANGE" | awk '{print $1}')"
        printList "  net.ipv4.ip_local_port_range" 36 "$PORT_RANGE"
        if [ "${PORT_LOW:-32768}" -le 9000 ] 2>/dev/null; then
            ok "  net.ipv4.ip_local_port_range starts at ${PORT_LOW} (<= 9000)"
        else
            warn "  net.ipv4.ip_local_port_range starts at ${PORT_LOW} – Oracle recommends 9000 65500"
        fi
    fi

    printf "\n"
    info "  Reference config (save to /etc/sysctl.d/99-oracle-fmw.conf as root):"
    info "    fs.file-max = 6815744"
    info "    fs.aio-max-nr = 1048576"
    info "    kernel.sem = 250 32000 100 128"
    info "    kernel.shmmni = 4096"
    info "    kernel.shmall = <total RAM in 4K pages>  e.g. $(( ${MEM_TOTAL_KB:-0} / 4 )) for this host"
    info "    kernel.shmmax = <half of physical RAM in bytes>"
    info "    net.core.rmem_default = 262144"
    info "    net.core.rmem_max = 4194304"
    info "    net.core.wmem_default = 262144"
    info "    net.core.wmem_max = 1048576"
    info "    net.ipv4.ip_local_port_range = 9000 65500"
    info "  Activate with: /sbin/sysctl -p"
fi

# =============================================================================
# Section 5: SELinux & Firewall
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
# Section 6: Required OS Packages
# =============================================================================
section "Required OS Packages"

# Ref: Oracle Forms 14c / Reports 12c Install Guide – system requirements
# Ref: Oracle WLS 14.1.2 install guide – OS library requirements
# Ref: Oracle Forms/Reports 14.1.2 Install Guide – system requirements (OL8/9)
# Critical: binutils gcc gcc-c++ glibc glibc-devel libaio libaio-devel libgcc
#   libstdc++ libstdc++-devel libX11 libXi libXtst libXext libXrender fontconfig
#   freetype dejavu-serif-fonts ksh make numactl motif motif-devel unzip

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

    # Critical: Oracle WLS/FMW will not install or start without these
    # Source: Oracle WLS 14.1.2 install guide + Oracle Forms/Reports certify list
    CRITICAL_PKGS=(
        "binutils"
        "gcc"
        "gcc-c++"
        "glibc"
        "glibc-devel"
        "libaio"
        "libaio-devel"
        "libgcc"
        "libstdc++"
        "libstdc++-devel"
        "libXi"
        "libXtst"
        "libXext"
        "libXrender"
        "libX11"
        "fontconfig"
        "freetype"
        "dejavu-serif-fonts"
        "ksh"
        "make"
        "numactl"
        "motif"
        "motif-devel"
        "unzip"
    )

    # Compatibility packages (may have different names on OL8/9 vs OL7)
    COMPAT_PKGS=(
        "compat-libcap1"
        "glibc.i686"
        "libgcc.i686"
        "libstdc++.i686"
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

    info "-- Critical packages (Oracle WLS/FMW installation requires these) --"
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
    info "-- Compatibility packages (32-bit + compat libs; may differ by OS version) --"
    MISSING_COMPAT=0
    for pkg in "${COMPAT_PKGS[@]}"; do
        if ! _check_pkg "$pkg"; then
            warn "  ${pkg} – NOT installed"
            ALL_MISSING+=("$pkg")
            MISSING_COMPAT=$(( MISSING_COMPAT + 1 ))
        fi
    done
    if [ "$MISSING_COMPAT" -gt 0 ]; then
        info "  Note: compat-libcap1 / compat-libstdc++ may not be available on OL9"
        info "        glibc.i686 / libgcc.i686 are required by some Oracle tools"
    else
        ok "All compatibility packages present"
    fi

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

    # Print consolidated install command
    if [ "${#ALL_MISSING[@]}" -gt 0 ]; then
        printf "\n"
        info "To install all missing packages (run as root):"
        info "  dnf install -y ${ALL_MISSING[*]}"
    fi
fi

# =============================================================================
# Section 7: Hostname & Network
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
