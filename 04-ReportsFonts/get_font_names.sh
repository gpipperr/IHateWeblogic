#!/bin/bash
# =============================================================================
# Script   : get_font_names.sh
# Purpose  : Scan REPORTS_FONT_DIRECTORY and custom_fonts_dir/ for TTF fonts,
#            use fc-query to extract exact internal font names, and generate
#            ready-to-use uifont.ali [PDF:Subset] entries.
# Call     : ./get_font_names.sh
# Requires : fc-query (fontconfig), find
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_font003.htm
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

# Directories
CUSTOM_FONTS_DIR="$SCRIPT_DIR/custom_fonts_dir"
REPORTS_FONT_DIR="${REPORTS_FONT_DIR:-$DOMAIN_HOME/reports/fonts}"

# =============================================================================
# Banner
# =============================================================================
printLine
printf "\n\033[1mIHateWeblogic – Font Name Discovery\033[0m\n"
printf "Host    : %s\n" "$(_get_hostname)"
printf "Date    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "Log     : %s\n\n" "$LOG_FILE"

# =============================================================================
# Helper: get internal family name + style from a TTF file via fc-query
# =============================================================================
_fc_query_family() {
    local ttf="$1"
    fc-query --format '%{family}\n' "$ttf" 2>/dev/null | head -1
}

_fc_query_style() {
    local ttf="$1"
    fc-query --format '%{style}\n' "$ttf" 2>/dev/null | head -1
}

# =============================================================================
# Helper: build uifont.ali [PDF:Subset] entry
# Maps PostScript name(s) to the TTF filename (without extension)
# Oracle Reports looks for this filename in REPORTS_FONT_DIRECTORY
# =============================================================================
_make_subset_entry() {
    local ps_name="$1"      # PostScript/Windows font name used in report designs
    local ttf_file="$2"     # TTF filename (without .ttf extension) in reports/fonts/
    printf '%-40s = %s\n' "\"${ps_name}\"" "${ttf_file}"
}

# Accumulated output for the [PDF:Subset] block
SUBSET_LINES=()

# =============================================================================
# Section 1: Check fc-query prerequisite
# =============================================================================
section "Prerequisites"

if ! command -v fc-query >/dev/null 2>&1; then
    fail "fc-query not found – install fontconfig package"
    info "  Run: ./04-ReportsFonts/get_root_install_libs.sh"
    print_summary
    exit $EXIT_CODE
fi
ok "fc-query available: $(command -v fc-query)"

printf "\n"
printList "REPORTS_FONT_DIR" 30 "$REPORTS_FONT_DIR"
printList "custom_fonts_dir" 30 "$CUSTOM_FONTS_DIR"

# =============================================================================
# Section 2: Scan REPORTS_FONT_DIRECTORY
# =============================================================================
section "TTF Fonts in REPORTS_FONT_DIRECTORY"

FONT_DIR_TTFS=()

if [ ! -d "$REPORTS_FONT_DIR" ]; then
    warn "REPORTS_FONT_DIR does not exist: $REPORTS_FONT_DIR"
    info "  Run deploy_fonts.sh --apply to create and populate it"
else
    while IFS= read -r ttf; do
        FONT_DIR_TTFS+=("$ttf")
    done < <(find "$REPORTS_FONT_DIR" -name "*.ttf" -o -name "*.TTF" -o -name "*.ttc" 2>/dev/null | sort)

    if [ "${#FONT_DIR_TTFS[@]}" -eq 0 ]; then
        warn "No TTF/TTC files found in $REPORTS_FONT_DIR"
        info "  Run deploy_fonts.sh --apply to copy fonts"
    else
        ok "${#FONT_DIR_TTFS[@]} TTF/TTC file(s) found"
        for ttf in "${FONT_DIR_TTFS[@]}"; do
            fname="$(basename "$ttf" .ttf)"
            fname="${fname%.TTF}"
            family="$(_fc_query_family "$ttf")"
            style="$(_fc_query_style "$ttf")"
            printList "  $(basename "$ttf")" 38 "family='${family:-unknown}' style='${style:-unknown}'"
        done
    fi
fi

# =============================================================================
# Section 3: Scan custom_fonts_dir/
# =============================================================================
section "Custom Fonts in custom_fonts_dir/"

CUSTOM_TTFS=()

if [ ! -d "$CUSTOM_FONTS_DIR" ]; then
    info "custom_fonts_dir not found: $CUSTOM_FONTS_DIR"
else
    while IFS= read -r ttf; do
        CUSTOM_TTFS+=("$ttf")
    done < <(find "$CUSTOM_FONTS_DIR" -name "*.ttf" -o -name "*.TTF" -o -name "*.ttc" 2>/dev/null | sort)

    if [ "${#CUSTOM_TTFS[@]}" -eq 0 ]; then
        info "No custom fonts in custom_fonts_dir/ – place corporate/customer TTF files there"
        info "  Then run deploy_fonts.sh --apply followed by get_font_names.sh again"
    else
        ok "${#CUSTOM_TTFS[@]} custom TTF/TTC file(s) found"
        for ttf in "${CUSTOM_TTFS[@]}"; do
            family="$(_fc_query_family "$ttf")"
            style="$(_fc_query_style "$ttf")"
            printList "  $(basename "$ttf")" 38 "family='${family:-unknown}' style='${style:-unknown}'"
        done
    fi
fi

# =============================================================================
# Section 4: Generate uifont.ali [PDF:Subset] entries
# =============================================================================
section "Generated uifont.ali [PDF:Subset] Entries"

info "Format: \"PostScript name in report\" = TTF-filename-in-reports-fonts-dir"
info "Reference: fonts.md section 4 – uifont.ali format"
printf "\n"

# Collect ALL available font file base names (reports/fonts/ takes precedence)
# Build a lookup: base_filename → exists_in_reports_dir
declare -A FONT_FILES_AVAILABLE

for ttf in "${FONT_DIR_TTFS[@]}"; do
    base="$(basename "$ttf")"
    base="${base%.ttf}"
    base="${base%.TTF}"
    FONT_FILES_AVAILABLE["$base"]=1
done

# Also note custom fonts (not yet deployed to reports/fonts/)
declare -A CUSTOM_FONT_FILES
for ttf in "${CUSTOM_TTFS[@]}"; do
    base="$(basename "$ttf")"
    base="${base%.ttf}"
    base="${base%.TTF}"
    CUSTOM_FONT_FILES["$base"]=1
done

# ─── Helper: check if a font file is available, warn if not ───────────────────
_check_and_add() {
    local ps_name="$1"
    local ttf_base="$2"

    if [ -n "${FONT_FILES_AVAILABLE[$ttf_base]:-}" ]; then
        SUBSET_LINES+=("$(_make_subset_entry "$ps_name" "$ttf_base")")
        ok "  Mapped: \"$ps_name\" → $ttf_base"
    elif [ -n "${CUSTOM_FONT_FILES[$ttf_base]:-}" ]; then
        SUBSET_LINES+=("$(_make_subset_entry "$ps_name" "$ttf_base")")
        warn "  \"$ps_name\" → $ttf_base (in custom_fonts_dir/ but NOT yet deployed – run deploy_fonts.sh --apply)"
    else
        warn "  MISSING: \"$ps_name\" → $ttf_base.ttf not found in $REPORTS_FONT_DIR"
        info "    Deploy it: run deploy_fonts.sh --apply"
    fi
}

# ─── Standard PostScript → Liberation Sans ────────────────────────────────────
printf "\n"
info "-- Helvetica / Arial → Liberation Sans --"
_check_and_add "Helvetica"              "LiberationSans-Regular"
_check_and_add "Helvetica-Bold"         "LiberationSans-Bold"
_check_and_add "Helvetica-Oblique"      "LiberationSans-Italic"
_check_and_add "Helvetica-BoldOblique"  "LiberationSans-BoldItalic"
_check_and_add "Arial"                  "LiberationSans-Regular"
_check_and_add "Arial Bold"             "LiberationSans-Bold"
_check_and_add "Arial Italic"           "LiberationSans-Italic"
_check_and_add "Arial Bold Italic"      "LiberationSans-BoldItalic"

# ─── Standard PostScript → Liberation Serif ───────────────────────────────────
printf "\n"
info "-- Times / Times New Roman → Liberation Serif --"
_check_and_add "Times-Roman"            "LiberationSerif-Regular"
_check_and_add "Times-Bold"             "LiberationSerif-Bold"
_check_and_add "Times-Italic"           "LiberationSerif-Italic"
_check_and_add "Times-BoldItalic"       "LiberationSerif-BoldItalic"
_check_and_add "Times New Roman"        "LiberationSerif-Regular"
_check_and_add "Times New Roman Bold"   "LiberationSerif-Bold"
_check_and_add "Times New Roman Italic" "LiberationSerif-Italic"

# ─── Standard PostScript → Liberation Mono ────────────────────────────────────
printf "\n"
info "-- Courier / Courier New → Liberation Mono --"
_check_and_add "Courier"                "LiberationMono-Regular"
_check_and_add "Courier-Bold"           "LiberationMono-Bold"
_check_and_add "Courier-Oblique"        "LiberationMono-Italic"
_check_and_add "Courier-BoldOblique"    "LiberationMono-BoldItalic"
_check_and_add "Courier New"            "LiberationMono-Regular"
_check_and_add "Courier New Bold"       "LiberationMono-Bold"
_check_and_add "Courier New Italic"     "LiberationMono-Italic"

# ─── Tahoma / Verdana → DejaVu Sans (if deployed) ─────────────────────────────
printf "\n"
info "-- Tahoma / Verdana → DejaVu Sans (if deployed) --"
_check_and_add "Tahoma"                 "DejaVuSans"
_check_and_add "Tahoma Bold"            "DejaVuSans-Bold"
_check_and_add "Verdana"                "DejaVuSans"
_check_and_add "Verdana Bold"           "DejaVuSans-Bold"

# ─── Custom fonts from custom_fonts_dir/ ──────────────────────────────────────
if [ "${#CUSTOM_TTFS[@]}" -gt 0 ]; then
    printf "\n"
    info "-- Custom fonts (map internal family name to file) --"
    for ttf in "${CUSTOM_TTFS[@]}"; do
        base="$(basename "$ttf")"
        base_no_ext="${base%.ttf}"
        base_no_ext="${base_no_ext%.TTF}"
        family="$(_fc_query_family "$ttf")"

        if [ -n "$family" ]; then
            # Map: if family name != file base name, add both self-mapping and file-name entry
            SUBSET_LINES+=("")
            SUBSET_LINES+=("# Custom: $(basename "$ttf") – internal family: '$family'")
            SUBSET_LINES+=("$(_make_subset_entry "$family" "$base_no_ext")")
            ok "  Custom: \"$family\" → $base_no_ext"
            info "  Note: if reports use a different name, add a [Global] alias entry:"
            info "        \"Windows Font Name\" = \"$family\""
        else
            warn "  Cannot determine family name for: $base"
            SUBSET_LINES+=("# TODO: verify family name for: $base_no_ext")
            SUBSET_LINES+=("# \"???\" = $base_no_ext")
        fi
    done
fi

# =============================================================================
# Section 5: Print complete [PDF:Subset] block
# =============================================================================
section "Complete [PDF:Subset] Block (copy-paste ready)"

if [ "${#SUBSET_LINES[@]}" -eq 0 ]; then
    warn "No font mappings generated – deploy fonts first and re-run this script"
else
    printf "\n"
    printf "# ─────────────────────────────────────────────────────────────────────────\n"
    printf "# Generated by get_font_names.sh on %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# Host: %s | REPORTS_FONT_DIR: %s\n" "$(_get_hostname)" "$REPORTS_FONT_DIR"
    printf "# Paste into uifont.ali or run uifont_ali_update.sh --apply\n"
    printf "# ─────────────────────────────────────────────────────────────────────────\n"
    printf "\n"
    printf "[ PDF:Subset ]\n"
    for line in "${SUBSET_LINES[@]}"; do
        printf "%s\n" "$line"
    done
    printf "\n"
fi

# =============================================================================
# Summary
# =============================================================================
print_summary
exit $EXIT_CODE
