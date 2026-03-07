#!/bin/bash
# =============================================================================
# Script   : 02-root_os_packages.sh
# Purpose  : Phase 0 – Package installation for Oracle FMW 14.1.2 on OL 9
#            Installs FMW prerequisite libs, font stack, admin tools, and JDK 21.
# Call     : ./09-Install/02-root_os_packages.sh
#            ./09-Install/02-root_os_packages.sh --apply
# Options  : --apply      Install missing packages
#            --help       Show usage
# Requires : dnf, rpm
# Note     : JDK installation is handled by 02b-root_os_java.sh
# Runs as  : root or oracle with sudo
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/docs/01-root_install_packages.md
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
    printf "  %-20s %s\n" "--apply"     "Install missing packages"
    printf "  %-20s %s\n" "--help"      "Show this help"
    printf "\nNote: JDK installation is handled by 02b-root_os_java.sh\n"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)    APPLY_MODE=1; shift ;;
        --help|-h)  _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
    esac
done

# =============================================================================
# Root / sudo helpers
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
        print_summary; exit 2
    fi
}

# =============================================================================
# Banner
# =============================================================================

printLine
section "Package Installation – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-26s %s\n" "Host:" "$(hostname -f 2>/dev/null || hostname)" \
    | tee -a "${LOG_FILE:-/dev/null}"
[ "$APPLY_MODE" -eq 1 ] && \
    printf "  %-26s %s\n" "Mode:" "APPLY (will install packages)" \
        | tee -a "${LOG_FILE:-/dev/null}"
printLine

_check_root_access

# =============================================================================
# Package check helper
# =============================================================================

MISSING_PKGS=()

_check_pkg() {
    local pkg="$1"
    if rpm -q "$pkg" > /dev/null 2>&1; then
        ok "Installed: $pkg"
    else
        warn "Missing:   $pkg"
        MISSING_PKGS+=("$pkg")
    fi
}

# =============================================================================
# 1. FMW Prerequisite Libraries
# =============================================================================

section "FMW Prerequisite Libraries"

for PKG in \
    binutils \
    compat-openssl11 \
    cups-libs \
    gcc \
    gcc-c++ \
    glibc \
    glibc-devel \
    ksh \
    libaio \
    libaio-devel \
    libX11 \
    libXau \
    libXi \
    libXrender \
    libXtst \
    libgcc \
    libstdc++ \
    libstdc++-devel \
    libnsl \
    make \
    motif \
    motif-devel \
    net-tools \
    nfs-utils \
    numactl \
    unzip \
    wget \
    curl \
    tar
do
    _check_pkg "$PKG"
done

# =============================================================================
# 2. Font Stack (Reports PDF rendering)
# =============================================================================

section "Font Stack (Reports PDF Rendering)"

for PKG in \
    fontconfig \
    freetype \
    dejavu-sans-fonts \
    dejavu-serif-fonts \
    dejavu-sans-mono-fonts \
    dejavu-lgc-sans-fonts \
    dejavu-lgc-serif-fonts \
    liberation-sans-fonts \
    liberation-serif-fonts \
    liberation-mono-fonts \
    xorg-x11-utils \
    xorg-x11-fonts-Type1
do
    _check_pkg "$PKG"
done

# =============================================================================
# 3. Admin and Monitoring Tools
# =============================================================================

section "Admin and Monitoring Tools"

for PKG in \
    sysstat \
    smartmontools \
    nmon \
    tmux \
    lsof \
    strace \
    psmisc \
    xauth \
    bind-utils \
    tcpdump \
    nc
do
    _check_pkg "$PKG"
done

# =============================================================================
# Install missing packages
# =============================================================================

if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
    printf "\n  Missing packages (%d):\n" "${#MISSING_PKGS[@]}" \
        | tee -a "${LOG_FILE:-/dev/null}"
    for P in "${MISSING_PKGS[@]}"; do
        printf "    - %s\n" "$P" | tee -a "${LOG_FILE:-/dev/null}"
    done

    if [ "$APPLY_MODE" -eq 1 ]; then
        if askYesNo "Install all missing packages?" "y"; then
            _run_root dnf install -y "${MISSING_PKGS[@]}"
            if [ $? -eq 0 ]; then
                ok "All packages installed"
                # Re-check to confirm
                for PKG in "${MISSING_PKGS[@]}"; do
                    rpm -q "$PKG" > /dev/null 2>&1 || warn "Still missing after install: $PKG"
                done
            else
                fail "dnf install returned an error – check output above"
            fi
        fi
    else
        info "Run with --apply to install missing packages"
        info "  Manual: dnf install -y ${MISSING_PKGS[*]}"
    fi
else
    ok "All required packages are installed"
fi

# =============================================================================
# Summary
# =============================================================================

printLine
if [ "$CNT_FAIL" -eq 0 ] && [ "$CNT_WARN" -eq 0 ]; then
    info "All packages installed – next: 09-Install/02b-root_os_java.sh"
else
    [ "$APPLY_MODE" -eq 0 ] && info "Re-run with --apply to install missing packages"
    info "After packages complete: 09-Install/02b-root_os_java.sh (JDK 21 installation)"
fi

print_summary
exit "$EXIT_CODE"
