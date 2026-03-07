#!/bin/bash
# =============================================================================
# Script   : 02-root_os_packages.sh
# Purpose  : Phase 0 – Package installation for Oracle FMW 14.1.2 on OL 9
#            Installs FMW prerequisite libs, font stack, admin tools, and JDK 21.
# Call     : ./09-Install/02-root_os_packages.sh
#            ./09-Install/02-root_os_packages.sh --apply
# Options  : --apply      Install missing packages and JDK
#            --skip-jdk   Skip JDK install (already installed separately)
#            --help       Show usage
# Requires : dnf, rpm
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
SKIP_JDK=0

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-20s %s\n" "--apply"     "Install missing packages and JDK"
    printf "  %-20s %s\n" "--skip-jdk"  "Skip JDK installation"
    printf "  %-20s %s\n" "--help"      "Show this help"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)    APPLY_MODE=1; shift ;;
        --skip-jdk) SKIP_JDK=1;   shift ;;
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
printf "  %-26s %s\n" "Host:"          "$(hostname -f 2>/dev/null || hostname)" \
    | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "JDK_HOME:"      "${JDK_HOME:-(not set)}"  \
    | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "PATCH_STORAGE:" "${PATCH_STORAGE:-(not set)}" \
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
# 4. JDK 21
# =============================================================================

section "JDK 21"

if [ "$SKIP_JDK" -eq 1 ]; then
    info "JDK installation skipped (--skip-jdk)"
else
    JDK_HOME="${JDK_HOME:-/u01/app/oracle/java/jdk-21}"
    printf "  %-26s %s\n" "JDK_HOME:" "$JDK_HOME" | tee -a "${LOG_FILE:-/dev/null}"

    if [ -x "$JDK_HOME/bin/java" ]; then
        JDK_VERSION="$("$JDK_HOME/bin/java" -version 2>&1 | head -1)"
        ok "JDK found: $JDK_VERSION"
        # Verify it's JDK 21
        if printf "%s" "$JDK_VERSION" | grep -q '"21\.'; then
            ok "JDK version is 21 (required for FMW 14.1.2)"
        else
            warn "JDK version is not 21: $JDK_VERSION"
            info "  FMW 14.1.2 certification: JDK 21.x.x (Oracle JDK)"
        fi
    else
        fail "JDK not found at JDK_HOME: $JDK_HOME"
        info "  JDK must be installed to JDK_HOME before FMW installation"

        # Look for JDK installer in PATCH_STORAGE
        JDK_TAR=""
        JDK_RPM=""
        if [ -n "${PATCH_STORAGE:-}" ] && [ -d "$PATCH_STORAGE" ]; then
            JDK_TAR="$(find "$PATCH_STORAGE" -maxdepth 3 -name "jdk-21*.tar.gz" 2>/dev/null | head -1)"
            JDK_RPM="$(find "$PATCH_STORAGE" -maxdepth 3 -name "jdk-21*.rpm"    2>/dev/null | head -1)"
        fi

        if [ -n "$JDK_TAR" ]; then
            info "  JDK installer found: $JDK_TAR"
            if [ "$APPLY_MODE" -eq 1 ]; then
                if askYesNo "Extract $JDK_TAR to $(dirname "$JDK_HOME")?" "y"; then
                    JDK_PARENT="$(dirname "$JDK_HOME")"
                    _run_root mkdir -p "$JDK_PARENT"
                    _run_root tar xf "$JDK_TAR" -C "$JDK_PARENT"
                    # Find what was extracted
                    EXTRACTED="$(tar tf "$JDK_TAR" 2>/dev/null | head -1 | cut -d/ -f1)"
                    EXTRACTED_PATH="$JDK_PARENT/$EXTRACTED"
                    if [ -d "$EXTRACTED_PATH" ] && [ "$EXTRACTED_PATH" != "$JDK_HOME" ]; then
                        _run_root mv "$EXTRACTED_PATH" "$JDK_HOME"
                    fi
                    if [ -x "$JDK_HOME/bin/java" ]; then
                        ok "JDK installed: $("$JDK_HOME/bin/java" -version 2>&1 | head -1)"
                    else
                        fail "JDK extraction failed – $JDK_HOME/bin/java not found"
                    fi
                fi
            fi
        elif [ -n "$JDK_RPM" ]; then
            info "  JDK RPM found: $JDK_RPM"
            if [ "$APPLY_MODE" -eq 1 ]; then
                if askYesNo "Install $JDK_RPM?" "y"; then
                    _run_root dnf install -y --nogpgcheck "$JDK_RPM"
                    ok "JDK RPM installed"
                fi
            fi
        else
            info "  No JDK installer found in PATCH_STORAGE: ${PATCH_STORAGE:-(not set)}"
            info "  Download JDK 21 from: https://www.oracle.com/java/technologies/downloads/"
            info "  Place in: $PATCH_STORAGE/"
        fi
    fi

    # Register with alternatives (without setting as system default)
    if [ -x "$JDK_HOME/bin/java" ]; then
        if ! alternatives --display java 2>/dev/null | grep -q "$JDK_HOME"; then
            info "JDK not registered with alternatives"
            if [ "$APPLY_MODE" -eq 1 ]; then
                _run_root alternatives --install /usr/bin/java java "$JDK_HOME/bin/java" 1000
                # Do NOT set as default — system JDK stays unchanged
                ok "JDK registered with alternatives (not set as system default)"
            else
                info "  Register: alternatives --install /usr/bin/java java $JDK_HOME/bin/java 1000"
            fi
        else
            ok "JDK registered with alternatives"
        fi

        # Verify HugePages flag (should work without config, falls back gracefully)
        HP_CHECK="$("$JDK_HOME/bin/java" -XX:+PrintFlagsFinal -version 2>/dev/null \
            | grep -i 'UseLargePages' | awk '{print $NF}' | head -1)"
        printf "  %-26s %s\n" "UseLargePages:" "${HP_CHECK:-(unknown)}" \
            | tee -a "${LOG_FILE:-/dev/null}"
    fi
fi

# =============================================================================
# Summary
# =============================================================================

printLine
if [ "$CNT_FAIL" -eq 0 ] && [ "$CNT_WARN" -eq 0 ]; then
    info "Package installation complete – proceed to 03-root_user_oracle.sh"
else
    [ "$APPLY_MODE" -eq 0 ] && info "Re-run with --apply to install missing packages"
fi

print_summary
exit "$EXIT_CODE"
