#!/bin/bash
# =============================================================================
# Script   : font_cache_reset.sh
# Purpose  : Rebuild the Linux fontconfig cache after deploying new TTF fonts
#            so that fc-query/fc-list immediately see the new fonts.
#            Covers: REPORTS_FONT_DIR, /usr/share/fonts (Liberation/DejaVu).
#            Also shows Oracle Reports Server restart instructions, because
#            the JVM caches font data at startup and must be restarted.
# Call     : ./font_cache_reset.sh [--apply]
# Requires : fc-cache (fontconfig)
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
            printf "  Default: dry-run – show which caches would be rebuilt\n"
            printf "  --apply: run fc-cache for REPORTS_FONT_DIR and /usr/share/fonts\n"
            exit 0
            ;;
    esac
done

# =============================================================================
# Variables
# =============================================================================
REPORTS_FONT_DIR="${REPORTS_FONT_DIR:-$DOMAIN_HOME/reports/fonts}"

# System font dirs to refresh after dnf install of Liberation/DejaVu
SYS_FONT_DIRS=(
    "/usr/share/fonts/liberation"
    "/usr/share/fonts/liberation-fonts"
    "/usr/share/fonts/dejavu"
    "/usr/share/fonts/dejavu-sans-fonts"
)

# =============================================================================
# Banner
# =============================================================================
printLine
printf "\n\033[1mIHateWeblogic – Font Cache Reset\033[0m\n"
printf "Host    : %s\n" "$(_get_hostname)"
printf "Date    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "Mode    : %s\n" "$( $APPLY_MODE && echo 'APPLY (will run fc-cache)' || echo 'DRY-RUN (use --apply to rebuild)')"
printf "Log     : %s\n\n" "$LOG_FILE"

# =============================================================================
# Section 1: Prerequisites
# =============================================================================
section "Prerequisites"

if ! command -v fc-cache >/dev/null 2>&1; then
    fail "fc-cache not found – install fontconfig"
    info "  Run: sudo dnf install -y fontconfig"
    info "  Or:  ./get_root_install_libs.sh --apply  (same directory)"
    print_summary
    exit $EXIT_CODE
fi
ok "fc-cache available: $(command -v fc-cache)"

if command -v fc-list >/dev/null 2>&1; then
    ok "fc-list  available: $(command -v fc-list)"
    FC_LIST_OK=true
else
    warn "fc-list not found – post-cache verification will be skipped"
    FC_LIST_OK=false
fi

# =============================================================================
# Section 2: Current font state
# =============================================================================
section "Current Font State"

printList "REPORTS_FONT_DIR" 30 "$REPORTS_FONT_DIR"

if [ ! -d "$REPORTS_FONT_DIR" ]; then
    warn "REPORTS_FONT_DIR does not exist: $REPORTS_FONT_DIR"
    info "  Run deploy_fonts.sh --apply first"
else
    TTF_COUNT="$(find "$REPORTS_FONT_DIR" -name "*.ttf" -o -name "*.TTF" 2>/dev/null | wc -l)"
    ok "REPORTS_FONT_DIR exists ($TTF_COUNT TTF file(s))"

    if $FC_LIST_OK; then
        CACHED_COUNT="$(fc-list : file | grep -c "$REPORTS_FONT_DIR" 2>/dev/null || true)"
        if [ "$CACHED_COUNT" -gt 0 ]; then
            ok "fc-list sees $CACHED_COUNT font(s) from REPORTS_FONT_DIR"
        else
            warn "fc-list sees 0 fonts from REPORTS_FONT_DIR – cache may be stale"
        fi
    fi
fi

printf "\n"
info "-- System font dirs that will be refreshed --"
for dir in "${SYS_FONT_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        cnt="$(find "$dir" -name "*.ttf" -o -name "*.TTF" 2>/dev/null | wc -l)"
        ok "  Exists ($cnt TTF): $dir"
    else
        info "  Not present   : $dir  (skipped)"
    fi
done

# =============================================================================
# Section 3: Apply
# =============================================================================
section "fc-cache Rebuild"

_run_fc_cache() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        info "  Skipped (not found): $dir"
        return
    fi
    info "  fc-cache -fv $dir"
    fc-cache -fv "$dir" 2>&1 | while IFS= read -r line; do
        info "    $line"
    done
    ok "  Done: $dir"
}

if ! $APPLY_MODE; then
    info "Would rebuild fc-cache for:"
    info "  1. $REPORTS_FONT_DIR"
    for dir in "${SYS_FONT_DIRS[@]}"; do
        [ -d "$dir" ] && info "  2. $dir"
    done
    info ""
    info "Run with --apply to execute"
else
    # 1. REPORTS_FONT_DIR
    _run_fc_cache "$REPORTS_FONT_DIR"

    # 2. System font dirs (only existing ones)
    for dir in "${SYS_FONT_DIRS[@]}"; do
        [ -d "$dir" ] && _run_fc_cache "$dir"
    done

    # 3. Post-cache verification
    if $FC_LIST_OK; then
        printf "\n"
        info "Post-cache check: Liberation fonts visible to fc-list:"
        fc-list | grep -i 'liberation' | sort | while IFS= read -r line; do
            info "  $line"
        done || info "  (none found)"

        info "Post-cache check: DejaVu fonts visible to fc-list:"
        fc-list | grep -i 'dejavu' | sort | while IFS= read -r line; do
            info "  $line"
        done || info "  (none found)"

        CACHED_AFTER="$(fc-list : file | grep -c "$REPORTS_FONT_DIR" 2>/dev/null || true)"
        if [ "$CACHED_AFTER" -gt 0 ]; then
            ok "fc-list now sees $CACHED_AFTER font(s) from REPORTS_FONT_DIR"
        else
            warn "fc-list still sees 0 fonts from REPORTS_FONT_DIR"
            info "  Check: fc-list : file | grep '$REPORTS_FONT_DIR'"
        fi
    fi
fi

# =============================================================================
# Section 4: Oracle Reports Server restart
# =============================================================================
section "Oracle Reports Server Restart Required"

info "The fontconfig cache is used by fc-query/fc-list (get_font_names.sh)."
info "The Oracle Reports JVM caches font data at startup and does NOT"
info "use the fontconfig cache at runtime – it reads TTFs directly."
printf "\n"
info "A Reports Server restart is required to pick up:"
info "  - New TTF files in REPORTS_FONT_DIR"
info "  - Changes to REPORTS_FONT_DIRECTORY env var"
info "  - Changes to uifont.ali"
printf "\n"

WLS_MANAGED="${WLS_MANAGED_SERVER:-<reports_server_name>}"
info "Restart commands:"
info "  \$DOMAIN_HOME/bin/stopComponent.sh  $WLS_MANAGED"
info "  \$DOMAIN_HOME/bin/startComponent.sh $WLS_MANAGED"
info ""
info "Or via Node Manager / Oracle Enterprise Manager console."

# =============================================================================
# Summary
# =============================================================================
printLine
print_summary
exit $EXIT_CODE
