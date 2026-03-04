#!/bin/bash
# =============================================================================
# Script   : get_root_install_libs.sh
# Purpose  : Check which font/PDF system packages are installed, show status
#            per package, and print the ready-to-run dnf install command for
#            everything that is missing.  Run with --apply (as root or via
#            sudo) to actually install.
# Call     : ./get_root_install_libs.sh [--apply]
# Requires : rpm, dnf (install only)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_font002.htm
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
# Parse arguments
# =============================================================================
APPLY_MODE=false
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY_MODE=true ;;
        --help)
            printf "Usage: %s [--apply]\n" "$(basename "$0")"
            printf "  Default: check package status, print missing dnf command\n"
            printf "  --apply: run dnf install for missing packages (needs root/sudo)\n"
            exit 0
            ;;
    esac
done

# =============================================================================
# Package lists
# =============================================================================

# Font packages required for Oracle Reports TrueType font rendering
FONT_PKGS=(
    liberation-fonts-common     # Liberation shared data
    liberation-sans-fonts       # Liberation Sans  (Arial/Helvetica substitute)
    liberation-serif-fonts      # Liberation Serif (Times New Roman substitute)
    liberation-mono-fonts       # Liberation Mono  (Courier New substitute)
    dejavu-sans-fonts           # DejaVu Sans       (Tahoma/Verdana substitute)
    dejavu-sans-mono-fonts      # DejaVu Sans Mono  (monospace)
    dejavu-serif-fonts          # DejaVu Serif      (serif fallback)
    dejavu-lgc-sans-fonts       # DejaVu LGC Sans   (Latin-Greek-Cyrillic)
    dejavu-lgc-sans-mono-fonts  # DejaVu LGC Mono
    dejavu-lgc-serif-fonts      # DejaVu LGC Serif
    fontconfig                  # fc-query, fc-cache, fc-list
)

# PDF verification
PDF_PKGS=(
    poppler-utils               # pdffonts – PDF font audit
)

# Oracle FMW/WebLogic/Forms+Reports OS prerequisites (Oracle install guide 14.1.2)
FMW_PKGS=(
    binutils
    gcc
    gcc-c++
    glibc-devel
    libaio
    libaio-devel
    libgcc
    libstdc++
    libstdc++-devel
    ksh
    make
    numactl
    numactl-devel
    motif
    motif-devel
    sysstat
    openssl
)

# i686 / compat packages (architecture-specific)
COMPAT_PKGS=(
    compat-libcap1
    "glibc.i686"
    "libgcc.i686"
    "libstdc++.i686"
)

# =============================================================================
# Banner
# =============================================================================
printLine
printf "\n\033[1mIHateWeblogic – System Package Checker\033[0m\n"
printf "Host    : %s\n" "$(_get_hostname)"
printf "Date    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "Mode    : %s\n" "$( $APPLY_MODE && echo 'APPLY (will run dnf install)' || echo 'DRY-RUN (print command only)')"
printf "Log     : %s\n\n" "$LOG_FILE"

# =============================================================================
# Helper: check one package with rpm -q
# =============================================================================
MISSING_PKGS=()

_check_pkg() {
    local pkg="$1"

    if rpm -q "$pkg" >/dev/null 2>&1; then
        local ver
        ver="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$pkg" 2>/dev/null)"
        ok "  Installed : %-40s %s" "$pkg" "$ver"
    else
        warn "  Missing   : $pkg"
        MISSING_PKGS+=("$pkg")
    fi
}

# =============================================================================
# Section 1: rpm/dnf available?
# =============================================================================
section "Prerequisites"

if ! command -v rpm >/dev/null 2>&1; then
    fail "rpm not found – not an RPM-based system?"
    print_summary
    exit $EXIT_CODE
fi
ok "rpm available"

if command -v dnf >/dev/null 2>&1; then
    ok "dnf available: $(command -v dnf)"
    DNF_CMD="dnf"
elif command -v yum >/dev/null 2>&1; then
    ok "yum available (dnf not found – falling back to yum)"
    DNF_CMD="yum"
else
    warn "dnf/yum not found – install command cannot be run automatically"
    DNF_CMD="dnf"
fi

# =============================================================================
# Section 2: Font packages
# =============================================================================
section "Font Packages (required for Oracle Reports TTF rendering)"

for pkg in "${FONT_PKGS[@]}"; do
    _check_pkg "$pkg"
done

# =============================================================================
# Section 3: PDF verification packages
# =============================================================================
section "PDF Verification Packages"

for pkg in "${PDF_PKGS[@]}"; do
    _check_pkg "$pkg"
done

# =============================================================================
# Section 4: FMW OS prerequisite packages
# =============================================================================
section "FMW OS Prerequisite Packages (Oracle Install Guide 14.1.2)"

for pkg in "${FMW_PKGS[@]}"; do
    _check_pkg "$pkg"
done

# =============================================================================
# Section 5: i686 / compat packages
# =============================================================================
section "i686 / Compat Packages"

for pkg in "${COMPAT_PKGS[@]}"; do
    _check_pkg "$pkg"
done

# =============================================================================
# Section 6: Install command
# =============================================================================
section "dnf Install Command"

if [ "${#MISSING_PKGS[@]}" -eq 0 ]; then
    ok "All packages are already installed – nothing to do"
else
    warn "${#MISSING_PKGS[@]} package(s) missing"
    printf "\n"
    info "Run the following as root to install all missing packages:"
    printf "\n"
    # Print multi-line command to terminal (not via info to preserve formatting)
    printf "  sudo dnf install -y"
    for pkg in "${MISSING_PKGS[@]}"; do
        printf " \\\n    %s" "$pkg"
    done
    printf "\n\n"
    # Also log flat version
    printf "# dnf install command: sudo %s install -y %s\n" \
        "$DNF_CMD" "${MISSING_PKGS[*]}" >> "${LOG_FILE:-/dev/null}"
fi

# =============================================================================
# Section 7: Apply
# =============================================================================
if $APPLY_MODE; then
    section "Installing Missing Packages"

    if [ "${#MISSING_PKGS[@]}" -eq 0 ]; then
        info "Nothing to install"
    else
        # Determine if we need sudo
        if [ "$(id -u)" -eq 0 ]; then
            INSTALL_PRE=""
        elif command -v sudo >/dev/null 2>&1; then
            info "Not running as root – using sudo"
            INSTALL_PRE="sudo"
        else
            fail "Not root and sudo not available – cannot install packages"
            info "  Run as root: $DNF_CMD install -y ${MISSING_PKGS[*]}"
            print_summary
            exit $EXIT_CODE
        fi

        info "Running: ${INSTALL_PRE:+$INSTALL_PRE }$DNF_CMD install -y ${MISSING_PKGS[*]}"
        # shellcheck disable=SC2086
        if ${INSTALL_PRE:+$INSTALL_PRE} $DNF_CMD install -y "${MISSING_PKGS[@]}" 2>&1 \
            | while IFS= read -r line; do info "  $line"; done; then
            ok "Package installation completed"
        else
            fail "Package installation failed – check output above"
        fi
    fi
fi

# =============================================================================
# Summary
# =============================================================================
printLine
print_summary
exit $EXIT_CODE
