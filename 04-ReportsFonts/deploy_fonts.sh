#!/bin/bash
# =============================================================================
# Script   : deploy_fonts.sh
# Purpose  : Deploy Liberation, DejaVu, and custom fonts to the Oracle Reports
#            font directory ($DOMAIN_HOME/reports/fonts/) and optionally to the
#            system font path. Handles custom_fonts_dir/ for corporate/licensed
#            TTF fonts (Wingdings, corporate fonts, etc.).
# Call     : ./deploy_fonts.sh [--apply]
# Requires : find, cp, fc-cache (fontconfig)
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
            printf "  Default: dry-run (show what would be deployed)\n"
            printf "  --apply: actually copy fonts and run fc-cache\n"
            exit 0
            ;;
    esac
done

# =============================================================================
# Directories
# =============================================================================
CUSTOM_FONTS_DIR="$SCRIPT_DIR/custom_fonts_dir"
REPORTS_FONT_DIR="${REPORTS_FONT_DIR:-$DOMAIN_HOME/reports/fonts}"

# =============================================================================
# Banner
# =============================================================================
printLine
printf "\n\033[1mIHateWeblogic – Font Deployment\033[0m\n"
printf "Host    : %s\n" "$(_get_hostname)"
printf "Date    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "Mode    : %s\n" "$( $APPLY_MODE && echo 'APPLY (will copy fonts)' || echo 'DRY-RUN (use --apply to write)')"
printf "Log     : %s\n\n" "$LOG_FILE"

# =============================================================================
# Helper: deploy a single font file
# Reports: ok = already there / deployed, info = would copy, fail = copy error
# =============================================================================
DEPLOY_COUNT=0
SKIP_COUNT=0

_deploy_font() {
    local src="$1"
    local dst_dir="$2"
    local fname
    fname="$(basename "$src")"
    local dst="$dst_dir/$fname"

    if [ -f "$dst" ]; then
        # Check if source and dest are the same file (same inode / size+mtime)
        if [ "$src" -ef "$dst" ]; then
            info "  Skipped (same file): $fname"
        else
            ok "  Already deployed: $fname"
        fi
        SKIP_COUNT=$(( SKIP_COUNT + 1 ))
        return 0
    fi

    if $APPLY_MODE; then
        if cp "$src" "$dst" 2>/dev/null; then
            ok "  Deployed: $fname → $dst_dir/"
            DEPLOY_COUNT=$(( DEPLOY_COUNT + 1 ))
        else
            fail "  Failed to copy: $fname → $dst_dir/"
        fi
    else
        info "  Would deploy: $fname → $dst_dir/"
        DEPLOY_COUNT=$(( DEPLOY_COUNT + 1 ))
    fi
}

# =============================================================================
# Section 1: Target directory
# =============================================================================
section "Target Directory"

printList "REPORTS_FONT_DIR" 32 "$REPORTS_FONT_DIR"

if [ ! -d "$REPORTS_FONT_DIR" ]; then
    if $APPLY_MODE; then
        if mkdir -p "$REPORTS_FONT_DIR" 2>/dev/null; then
            ok "Created: $REPORTS_FONT_DIR"
        else
            fail "Cannot create: $REPORTS_FONT_DIR"
            print_summary
            exit $EXIT_CODE
        fi
    else
        warn "Directory does not exist: $REPORTS_FONT_DIR (will be created with --apply)"
    fi
else
    CURRENT_COUNT="$(find "$REPORTS_FONT_DIR" -name "*.ttf" -o -name "*.TTF" -o -name "*.ttc" 2>/dev/null | wc -l)"
    ok "Directory exists, current TTF count: $CURRENT_COUNT"
fi

# =============================================================================
# Section 2: Liberation Fonts (system packages)
# =============================================================================
section "Liberation Fonts (from OS packages)"

info "Searching for Liberation fonts in /usr/share/fonts/..."
LIBERATION_TTFS=()
while IFS= read -r f; do
    LIBERATION_TTFS+=("$f")
done < <(find /usr/share/fonts -name "Liberation*.ttf" 2>/dev/null | sort)

if [ "${#LIBERATION_TTFS[@]}" -eq 0 ]; then
    fail "No Liberation fonts found in /usr/share/fonts/"
    info "  Install with: dnf install -y liberation-fonts liberation-fonts-common"
    info "  Or run: ./04-ReportsFonts/get_root_install_libs.sh"
else
    ok "${#LIBERATION_TTFS[@]} Liberation TTF file(s) found"
    for ttf in "${LIBERATION_TTFS[@]}"; do
        _deploy_font "$ttf" "$REPORTS_FONT_DIR"
    done
fi

# =============================================================================
# Section 3: DejaVu Fonts (system packages)
# =============================================================================
section "DejaVu Fonts (from OS packages)"

info "Searching for DejaVu fonts in /usr/share/fonts/..."
DEJAVU_TTFS=()
while IFS= read -r f; do
    DEJAVU_TTFS+=("$f")
done < <(find /usr/share/fonts -name "DejaVu*.ttf" 2>/dev/null | sort)

if [ "${#DEJAVU_TTFS[@]}" -eq 0 ]; then
    warn "No DejaVu fonts found in /usr/share/fonts/"
    info "  Install with: dnf install -y dejavu-fonts-all dejavu-serif-fonts"
    info "  DejaVu is needed for Tahoma/Verdana substitution"
else
    ok "${#DEJAVU_TTFS[@]} DejaVu TTF file(s) found"
    for ttf in "${DEJAVU_TTFS[@]}"; do
        _deploy_font "$ttf" "$REPORTS_FONT_DIR"
    done
fi

# =============================================================================
# Section 4: Custom Fonts from custom_fonts_dir/
# =============================================================================
section "Custom Fonts (custom_fonts_dir/)"

info "Source directory: $CUSTOM_FONTS_DIR"
printLine

if [ ! -d "$CUSTOM_FONTS_DIR" ]; then
    warn "custom_fonts_dir not found: $CUSTOM_FONTS_DIR"
    info "  Create it and place corporate or licensed TTF fonts there"
    info "  Example: Wingdings.ttf, CorporateFont-Regular.ttf"
else
    CUSTOM_TTFS=()
    while IFS= read -r f; do
        CUSTOM_TTFS+=("$f")
    done < <(find "$CUSTOM_FONTS_DIR" -name "*.ttf" -o -name "*.TTF" -o -name "*.ttc" 2>/dev/null | sort)

    if [ "${#CUSTOM_TTFS[@]}" -eq 0 ]; then
        info "custom_fonts_dir/ is empty – no custom fonts to deploy"
        info "  Place *.ttf files there for corporate or licensed fonts (e.g. Wingdings.ttf)"
    else
        ok "${#CUSTOM_TTFS[@]} custom TTF/TTC file(s) found"

        for ttf in "${CUSTOM_TTFS[@]}"; do
            fname="$(basename "$ttf")"

            # Warn about known licensed fonts that require attention
            case "${fname,,}" in
                wingdings*|webdings*|symbol.ttf|marlett.ttf)
                    info "  Note: $fname – Windows-licensed font; ensure valid license"
                    ;;
                arial*|times*|courier*|tahoma*|verdana*|calibri*)
                    info "  Note: $fname – Microsoft font; Liberation equivalent may be preferred"
                    ;;
            esac

            _deploy_font "$ttf" "$REPORTS_FONT_DIR"
        done
    fi
fi

# =============================================================================
# Section 5: fc-cache refresh
# =============================================================================
section "Fontconfig Cache Refresh"

# fc-cache is needed so fc-query can discover fonts in the reports/fonts dir
# when called by get_font_names.sh and uifont_ali_update.sh.
# The Oracle Reports engine itself reads TTF files directly from REPORTS_FONT_DIR
# without relying on fontconfig.

if ! command -v fc-cache >/dev/null 2>&1; then
    warn "fc-cache not found – fontconfig not installed"
    info "  Install with: dnf install -y fontconfig"
    info "  fc-cache is needed for get_font_names.sh (fc-query name discovery)"
else
    if $APPLY_MODE; then
        if [ "$DEPLOY_COUNT" -gt 0 ]; then
            info "Running fc-cache -fv on $REPORTS_FONT_DIR ..."
            fc-cache -fv "$REPORTS_FONT_DIR" 2>&1 | while IFS= read -r line; do
                info "  $line"
            done
            ok "fc-cache completed"
        else
            info "No new fonts deployed – fc-cache not needed"
        fi
    else
        info "fc-cache will be run on $REPORTS_FONT_DIR (with --apply)"
    fi
fi

# =============================================================================
# Section 6: Next Steps
# =============================================================================
section "Next Steps"

if ! $APPLY_MODE; then
    info "Run with --apply to execute the deployment above"
    info "After deployment:"
fi
info "  1. Run get_font_names.sh  → verify fc-query names and generate uifont.ali entries"
info "  2. Run uifont_ali_update.sh --apply → update [PDF:Subset] in uifont.ali"
info "  3. Run fontpath_config.sh --apply   → set REPORTS_FONT_DIRECTORY in rwserver.conf"
info "  4. Restart Reports Server"
info "  5. Run pdf_font_verify.sh           → verify PDFs contain embedded TrueType fonts"

# =============================================================================
# Summary
# =============================================================================
printLine
printf "  Fonts deployed : %d\n" "$DEPLOY_COUNT"
printf "  Already present: %d\n" "$SKIP_COUNT"
printf "\n"
print_summary
exit $EXIT_CODE
