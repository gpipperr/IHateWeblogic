#!/bin/bash
# =============================================================================
# Script   : font_inventory.sh
# Purpose  : Full inventory of fonts available to Oracle Reports:
#             1. TTF fonts in REPORTS_FONT_DIR (with fc-query family names)
#             2. System fonts relevant to Oracle Reports (Liberation, DejaVu)
#             3. Legacy AFM/Type1 font directory under FMW_HOME
#             4. Current [PDF:Subset] section from uifont.ali
#             5. Coverage check: each [PDF:Subset] entry vs REPORTS_FONT_DIR
# Call     : ./font_inventory.sh
# Requires : fc-list, fc-query, find
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
# Variables
# =============================================================================
REPORTS_FONT_DIR="${REPORTS_FONT_DIR:-$DOMAIN_HOME/reports/fonts}"
UIFONT_ALI="${UIFONT_ALI:-}"
CUSTOM_FONTS_DIR="$SCRIPT_DIR/custom_fonts_dir"

# =============================================================================
# Banner
# =============================================================================
printLine
printf "\n\033[1mIHateWeblogic – Font Inventory\033[0m\n"
printf "Host    : %s\n" "$(_get_hostname)"
printf "Date    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "Log     : %s\n\n" "$LOG_FILE"

# =============================================================================
# Section 1: Prerequisites
# =============================================================================
section "Prerequisites"

FC_QUERY_OK=false
FC_LIST_OK=false

if command -v fc-query >/dev/null 2>&1; then
    ok "fc-query available: $(command -v fc-query)"
    FC_QUERY_OK=true
else
    warn "fc-query not found – font family names will not be shown"
    info "  Install with: sudo dnf install -y fontconfig"
fi

if command -v fc-list >/dev/null 2>&1; then
    ok "fc-list available: $(command -v fc-list)"
    FC_LIST_OK=true
else
    warn "fc-list not found – system font list will be skipped"
fi

# =============================================================================
# Section 2: TTF fonts in REPORTS_FONT_DIR
# =============================================================================
section "TTF Fonts in REPORTS_FONT_DIR"

printList "REPORTS_FONT_DIR" 32 "$REPORTS_FONT_DIR"
printf "\n"

REPORTS_TTFS=()
declare -A REPORTS_FONT_BASES   # base_name → 1

if [ ! -d "$REPORTS_FONT_DIR" ]; then
    warn "REPORTS_FONT_DIR does not exist: $REPORTS_FONT_DIR"
    info "  Run deploy_fonts.sh --apply to create and populate it"
else
    while IFS= read -r f; do
        REPORTS_TTFS+=("$f")
    done < <(find "$REPORTS_FONT_DIR" -name "*.ttf" -o -name "*.TTF" -o -name "*.ttc" 2>/dev/null | sort)

    if [ "${#REPORTS_TTFS[@]}" -eq 0 ]; then
        warn "No TTF/TTC files found in REPORTS_FONT_DIR"
        info "  Run deploy_fonts.sh --apply to copy fonts"
    else
        ok "${#REPORTS_TTFS[@]} font file(s)"
        printf "\n"
        printf "  %-45s  %-30s  %s\n" "File" "Family" "Style"
        printf "  %-45s  %-30s  %s\n" \
            "---------------------------------------------" \
            "------------------------------" \
            "-------------------"

        for ttf in "${REPORTS_TTFS[@]}"; do
            local_base="$(basename "$ttf")"
            local_base_no_ext="${local_base%.ttf}"
            local_base_no_ext="${local_base_no_ext%.TTF}"
            local_base_no_ext="${local_base_no_ext%.ttc}"
            REPORTS_FONT_BASES["$local_base_no_ext"]=1

            if $FC_QUERY_OK; then
                family="$(fc-query --format '%{family}\n' "$ttf" 2>/dev/null | head -1)"
                style="$(fc-query --format '%{style}\n' "$ttf" 2>/dev/null | head -1)"
            else
                family="(fc-query unavailable)"
                style=""
            fi
            printf "  %-45s  %-30s  %s\n" "$local_base" "${family:-unknown}" "${style:-unknown}" \
                | tee -a "${LOG_FILE:-/dev/null}"
        done
    fi
fi

# =============================================================================
# Section 3: Custom fonts dir
# =============================================================================
section "Custom Fonts (custom_fonts_dir/)"

printList "custom_fonts_dir" 32 "$CUSTOM_FONTS_DIR"
printf "\n"

if [ ! -d "$CUSTOM_FONTS_DIR" ]; then
    info "custom_fonts_dir not found – no custom/licensed fonts staged"
    info "  Place *.ttf files there for corporate or licensed fonts, then run deploy_fonts.sh --apply"
else
    CUSTOM_TTFS=()
    while IFS= read -r f; do
        CUSTOM_TTFS+=("$f")
    done < <(find "$CUSTOM_FONTS_DIR" -name "*.ttf" -o -name "*.TTF" -o -name "*.ttc" 2>/dev/null | sort)

    if [ "${#CUSTOM_TTFS[@]}" -eq 0 ]; then
        info "custom_fonts_dir/ is empty"
    else
        ok "${#CUSTOM_TTFS[@]} custom font file(s)"
        for ttf in "${CUSTOM_TTFS[@]}"; do
            base="$(basename "$ttf")"
            base_no_ext="${base%.ttf}"
            base_no_ext="${base_no_ext%.TTF}"
            deployed=""
            [ -n "${REPORTS_FONT_BASES[$base_no_ext]:-}" ] && deployed="  [deployed]" || deployed="  [NOT deployed – run deploy_fonts.sh --apply]"
            if $FC_QUERY_OK; then
                family="$(fc-query --format '%{family}\n' "$ttf" 2>/dev/null | head -1)"
                printList "  $base" 44 "family='${family:-unknown}'$deployed"
            else
                printList "  $base" 44 "$deployed"
            fi
        done
    fi
fi

# =============================================================================
# Section 4: System fonts (Liberation + DejaVu via fc-list)
# =============================================================================
section "System Fonts: Liberation & DejaVu (fc-list)"

if ! $FC_LIST_OK; then
    warn "fc-list not available – skipping system font check"
else
    printf "\n"
    info "-- Liberation fonts (metric-compatible Arial / Times / Courier replacement) --"
    LIB_FONTS="$(fc-list | grep -i 'liberation' | sort 2>/dev/null)"
    if [ -z "$LIB_FONTS" ]; then
        warn "No Liberation fonts found in system font cache"
        info "  Install: sudo dnf install -y liberation-fonts-common liberation-sans-fonts liberation-serif-fonts liberation-mono-fonts"
    else
        while IFS= read -r line; do
            info "  $line"
        done <<< "$LIB_FONTS"
    fi

    printf "\n"
    info "-- DejaVu fonts (approximate Tahoma / Verdana replacement) --"
    DEJAVU_FONTS="$(fc-list | grep -i 'dejavu' | sort 2>/dev/null)"
    if [ -z "$DEJAVU_FONTS" ]; then
        warn "No DejaVu fonts found in system font cache"
        info "  Install: sudo dnf install -y dejavu-fonts-all"
    else
        while IFS= read -r line; do
            info "  $line"
        done <<< "$DEJAVU_FONTS"
    fi
fi

# =============================================================================
# Section 5: Legacy AFM/Type1 fonts in FMW_HOME
# =============================================================================
section "Legacy AFM/Type1 Fonts in FMW_HOME"

FMW_AFM_DIR="${FMW_HOME}/guicommon/tk/admin/AFM"
printList "FMW AFM directory" 32 "$FMW_AFM_DIR"

if [ ! -d "$FMW_AFM_DIR" ]; then
    info "AFM directory not found – legacy PS fonts not installed or FMW_HOME not set"
else
    AFM_COUNT="$(find "$FMW_AFM_DIR" -name "*.afm" -o -name "*.AFM" 2>/dev/null | wc -l)"
    ok "$AFM_COUNT AFM file(s) found"
    info "  AFM fonts are used by the legacy PostScript font model (REPORTS_ENHANCED_FONTHANDLING unset)"
    info "  When REPORTS_ENHANCED_FONTHANDLING=yes, the TTF model takes precedence"
fi

# Also check for Type1 .pfb / .pfa
FMW_TYPE1_DIR="${FMW_HOME}/guicommon/tk/admin"
TYPE1_COUNT=0
if [ -d "$FMW_TYPE1_DIR" ]; then
    TYPE1_COUNT="$(find "$FMW_TYPE1_DIR" -name "*.pfb" -o -name "*.pfa" 2>/dev/null | wc -l)"
    [ "$TYPE1_COUNT" -gt 0 ] && info "  $TYPE1_COUNT Type1 (pfb/pfa) file(s) in $FMW_TYPE1_DIR"
fi

# =============================================================================
# Section 6: Current uifont.ali [PDF:Subset]
# =============================================================================
section "uifont.ali – Current [PDF:Subset] Section"

# Locate uifont.ali (same logic as uifont_ali_update.sh)
_find_uifont_ali() {
    # 1. TK_FONTALIAS environment variable
    if [ -n "${TK_FONTALIAS:-}" ] && [ -f "$TK_FONTALIAS" ]; then
        printf "%s" "$TK_FONTALIAS"
        return 0
    fi
    # 2. ORACLE_FONTALIAS environment variable
    if [ -n "${ORACLE_FONTALIAS:-}" ] && [ -f "$ORACLE_FONTALIAS" ]; then
        printf "%s" "$ORACLE_FONTALIAS"
        return 0
    fi
    # 3. UIFONT_ALI from environment.conf
    if [ -n "${UIFONT_ALI:-}" ] && [ -f "$UIFONT_ALI" ]; then
        printf "%s" "$UIFONT_ALI"
        return 0
    fi
    # 4. Search in domain config
    local found
    found="$(find "$DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent" \
        -name "uifont.ali" 2>/dev/null | head -1)"
    if [ -n "$found" ]; then
        printf "%s" "$found"
        return 0
    fi
    # 5. FMW_HOME fallback
    found="$(find "$FMW_HOME/guicommon/tk/admin" -name "uifont.ali" 2>/dev/null | head -1)"
    if [ -n "$found" ]; then
        printf "%s" "$found"
        return 0
    fi
    return 1
}

UIFONT_FILE="$(_find_uifont_ali)"

if [ -z "$UIFONT_FILE" ]; then
    warn "uifont.ali not found"
    info "  Expected under: \$DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/"
else
    ok "Found: $UIFONT_FILE"
    printf "\n"

    # Extract [PDF:Subset] section
    SUBSET_SECTION="$(python3 - "$UIFONT_FILE" <<'PYEOF'
import sys, re
with open(sys.argv[1], "r", errors="replace") as fh:
    content = fh.read()
m = re.search(
    r'(\[\s*PDF\s*:\s*Subset\s*\][^\[]*)',
    content, re.IGNORECASE | re.DOTALL
)
if m:
    print(m.group(1).rstrip())
else:
    print("(no [PDF:Subset] section found)")
PYEOF
)"
    info "-- [PDF:Subset] contents --"
    while IFS= read -r line; do
        printf "  %s\n" "$line" | tee -a "${LOG_FILE:-/dev/null}"
    done <<< "$SUBSET_SECTION"
fi

# =============================================================================
# Section 7: Coverage check – [PDF:Subset] entries vs REPORTS_FONT_DIR
# =============================================================================
section "Coverage Check: [PDF:Subset] vs REPORTS_FONT_DIR"

if [ -z "$UIFONT_FILE" ] || [ "${#REPORTS_TTFS[@]}" -eq 0 ]; then
    info "Skipping – uifont.ali or REPORTS_FONT_DIR not available"
else
    # Extract mapped TTF base names from [PDF:Subset] (active, non-commented lines)
    MAPPED_BASES=()
    while IFS= read -r base; do
        [ -z "$base" ] && continue
        MAPPED_BASES+=("$base")
    done < <(python3 - "$UIFONT_FILE" <<'PYEOF'
import sys, re

with open(sys.argv[1], "r", errors="replace") as fh:
    content = fh.read()

m = re.search(
    r'\[\s*PDF\s*:\s*Subset\s*\]([^\[]*)',
    content, re.IGNORECASE | re.DOTALL
)
if not m:
    sys.exit(0)

section = m.group(1)
for line in section.splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    # Format: "PS Name" = TTF_base
    parts = line.split("=", 1)
    if len(parts) == 2:
        ttf_base = parts[1].strip().strip('"')
        if ttf_base:
            print(ttf_base)
PYEOF
)

    printf "\n"
    MISSING_FROM_DIR=0
    FOUND_IN_DIR=0

    for base in "${MAPPED_BASES[@]}"; do
        if [ -n "${REPORTS_FONT_BASES[$base]:-}" ]; then
            ok "  Mapped + present : $base"
            FOUND_IN_DIR=$(( FOUND_IN_DIR + 1 ))
        else
            fail "  Mapped but MISSING from REPORTS_FONT_DIR: $base.ttf"
            info "    Run deploy_fonts.sh --apply to copy this font"
            MISSING_FROM_DIR=$(( MISSING_FROM_DIR + 1 ))
        fi
    done

    # Also check for TTFs in REPORTS_FONT_DIR not referenced in [PDF:Subset]
    declare -A MAPPED_SET
    for base in "${MAPPED_BASES[@]}"; do
        MAPPED_SET["$base"]=1
    done

    UNREFERENCED=0
    for base in "${!REPORTS_FONT_BASES[@]}"; do
        if [ -z "${MAPPED_SET[$base]:-}" ]; then
            warn "  In REPORTS_FONT_DIR but NOT in [PDF:Subset]: $base"
            UNREFERENCED=$(( UNREFERENCED + 1 ))
        fi
    done

    printf "\n"
    printf "  [PDF:Subset] entries with TTF present : %d\n" "$FOUND_IN_DIR"
    printf "  [PDF:Subset] entries MISSING TTF file : %d\n" "$MISSING_FROM_DIR"
    printf "  TTF files not in [PDF:Subset]         : %d\n" "$UNREFERENCED"

    if [ "$UNREFERENCED" -gt 0 ]; then
        info "  Run uifont_ali_update.sh --apply to add unmapped fonts to [PDF:Subset]"
    fi
fi

# =============================================================================
# Summary
# =============================================================================
printLine
print_summary
exit $EXIT_CODE
