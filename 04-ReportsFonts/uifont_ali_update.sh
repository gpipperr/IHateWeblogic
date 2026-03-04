#!/bin/bash
# =============================================================================
# Script   : uifont_ali_update.sh
# Purpose  : Backup uifont.ali, rebuild the [PDF:Subset] section with
#            Liberation and custom font mappings. All other sections
#            (Global, Printer:*, Display:*, etc.) are preserved unchanged.
#            Default: dry-run (show diff). Use --apply to write.
# Call     : ./uifont_ali_update.sh [--apply]
# Requires : fc-query (fontconfig), cp, python3, find
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_font003.htm
#            fonts.md (this project)
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
            printf "  Default: dry-run (show what would change)\n"
            printf "  --apply: backup uifont.ali and update [PDF:Subset] section\n"
            exit 0
            ;;
    esac
done

# =============================================================================
# Directories and key paths
# =============================================================================
CUSTOM_FONTS_DIR="$SCRIPT_DIR/custom_fonts_dir"
REPORTS_FONT_DIR="${REPORTS_FONT_DIR:-$DOMAIN_HOME/reports/fonts}"

# =============================================================================
# Banner
# =============================================================================
printLine
printf "\n\033[1mIHateWeblogic – uifont.ali Update\033[0m\n"
printf "Host    : %s\n" "$(_get_hostname)"
printf "Date    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "Mode    : %s\n" "$( $APPLY_MODE && echo 'APPLY (will modify uifont.ali)' || echo 'DRY-RUN (use --apply to write)')"
printf "Log     : %s\n\n" "$LOG_FILE"

# =============================================================================
# Helper: find uifont.ali
# Search order: TK_FONTALIAS → ORACLE_FONTALIAS → domain config → FMW fallback
# =============================================================================
_find_uifont_ali() {
    # 1. Explicit environment variable override
    if [ -n "${TK_FONTALIAS:-}" ] && [ -f "$TK_FONTALIAS" ]; then
        printf "%s" "$TK_FONTALIAS"
        return 0
    fi
    if [ -n "${ORACLE_FONTALIAS:-}" ] && [ -f "$ORACLE_FONTALIAS" ]; then
        printf "%s" "$ORACLE_FONTALIAS"
        return 0
    fi

    # 2. Standard domain config path (new font model, 12c/14c)
    #    $DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/*/guicommon/tk/admin/
    local found
    found="$(find "$DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent" \
        -name "uifont.ali" -path "*/guicommon/tk/admin/*" 2>/dev/null \
        | head -1)"
    if [ -n "$found" ]; then
        printf "%s" "$found"
        return 0
    fi

    # 3. Also search tools/common path (some versions use this)
    found="$(find "$DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent" \
        -name "uifont.ali" -path "*/tools/common/*" 2>/dev/null \
        | head -1)"
    if [ -n "$found" ]; then
        printf "%s" "$found"
        return 0
    fi

    # 4. Oracle Home fallback
    if [ -f "$FMW_HOME/guicommon/tk/admin/uifont.ali" ]; then
        printf "%s" "$FMW_HOME/guicommon/tk/admin/uifont.ali"
        return 0
    fi

    return 1
}

# =============================================================================
# Helper: get TTF base name (without extension) for a path
# =============================================================================
_ttf_base() {
    local path="$1"
    local base
    base="$(basename "$path")"
    base="${base%.ttf}"
    base="${base%.TTF}"
    base="${base%.ttc}"
    printf "%s" "$base"
}

# =============================================================================
# Helper: check if TTF file exists in REPORTS_FONT_DIR or custom_fonts_dir
# =============================================================================
_font_available() {
    local base="$1"
    [ -f "$REPORTS_FONT_DIR/${base}.ttf" ]    || \
    [ -f "$REPORTS_FONT_DIR/${base}.TTF" ]    || \
    [ -f "$REPORTS_FONT_DIR/${base}.ttc" ]    || \
    [ -f "$CUSTOM_FONTS_DIR/${base}.ttf" ]    || \
    [ -f "$CUSTOM_FONTS_DIR/${base}.TTF" ]
}

# =============================================================================
# Helper: build one [PDF:Subset] mapping line (or a comment if font missing)
# =============================================================================
_subset_line() {
    local ps_name="$1"
    local ttf_base="$2"

    if _font_available "$ttf_base"; then
        printf '%-40s = %s\n' "\"${ps_name}\"" "${ttf_base}"
    else
        # Comment out entries for missing fonts – shows intent but doesn't break Reports
        printf '#%-39s = %s  (font not deployed)\n' "\"${ps_name}\"" "${ttf_base}"
    fi
}

# =============================================================================
# Helper: convert fc-query style string → uifont.ali qualifier (outside quotes)
# Returns empty string for Regular/Book/Plain (= no qualifier needed).
# Format: "FamilyName"<qualifier> = TTFbase
#   ..Italic.Bold  → style=Italic, weight=Bold   (most specific)
#   ...Bold        → any style,   weight=Bold
#   ..Italic.Light → style=Italic, weight=Light
#   ..Italic       → style=Italic, any weight
#   ...Light       → any style,   weight=Light
#   (empty)        → Regular/Plain                (least specific)
# =============================================================================
_style_to_qualifier() {
    local s="${1,,}"   # lowercase
    local bold=0 italic=0 light=0
    [[ "$s" == *bold* ]]                        && bold=1
    [[ "$s" == *italic* || "$s" == *oblique* ]] && italic=1
    [[ "$s" == *light* ]]                       && light=1

    if   (( bold && italic ));  then printf "..Italic.Bold"
    elif (( bold ));            then printf "...Bold"
    elif (( italic && light )); then printf "..Italic.Light"
    elif (( italic ));          then printf "..Italic"
    elif (( light ));           then printf "...Light"
    fi
    # Regular/Book/Plain → empty (no qualifier)
}

# =============================================================================
# Helper: sort priority for fc-query style (lower = more specific → emitted first)
# uifont.ali requires: specific entries BEFORE generic ones.
# =============================================================================
_style_sort_priority() {
    local s="${1,,}"
    local bold=0 italic=0 light=0
    [[ "$s" == *bold* ]]                        && bold=1
    [[ "$s" == *italic* || "$s" == *oblique* ]] && italic=1
    [[ "$s" == *light* ]]                       && light=1
    if   (( bold && italic ));  then printf "1"   # BoldItalic
    elif (( bold ));            then printf "2"   # Bold
    elif (( italic && light )); then printf "3"   # LightItalic
    elif (( italic ));          then printf "4"   # Italic
    elif (( light ));           then printf "5"   # Light
    else                             printf "9"   # Regular/Book/Plain
    fi
}

# =============================================================================
# Helper: emit one [PDF:Subset] line – qualifier is placed OUTSIDE the quotes
#   "FamilyName"<qualifier>  = ttf_base
# =============================================================================
_subset_line_q() {
    local family="$1"
    local qualifier="$2"
    local ttf_base="$3"
    local key="\"${family}\"${qualifier}"

    if _font_available "$ttf_base"; then
        printf '%-40s = %s\n' "${key}" "${ttf_base}"
    else
        printf '#%-39s = %s  (font not deployed)\n' "${key}" "${ttf_base}"
    fi
}

# =============================================================================
# Section 1: Find uifont.ali
# =============================================================================
section "Locate uifont.ali"

UIFONT_ALI="$(_find_uifont_ali)"

if [ -z "$UIFONT_ALI" ]; then
    fail "uifont.ali not found"
    info "  Searched:"
    info "    TK_FONTALIAS / ORACLE_FONTALIAS env vars"
    info "    $DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/**/guicommon/tk/admin/"
    info "    $FMW_HOME/guicommon/tk/admin/"
    info "  Verify that Oracle Reports is installed and DOMAIN_HOME is correct"
    print_summary
    exit $EXIT_CODE
fi

ok "Found: $UIFONT_ALI"
printList "  Size"    32 "$(wc -c < "$UIFONT_ALI" 2>/dev/null) bytes"
printList "  Lines"   32 "$(wc -l < "$UIFONT_ALI" 2>/dev/null)"

# Show current [PDF:Subset] status
EXISTING_SUBSET="$(awk 'tolower($0) ~ /^\[ *pdf *: *subset *\]/{found=1; next} /^\[/{found=0} found && /[^ \t#\n]/{print}' "$UIFONT_ALI" 2>/dev/null)"
if [ -n "$EXISTING_SUBSET" ]; then
    info "  Current [PDF:Subset] entries:"
    echo "$EXISTING_SUBSET" | while IFS= read -r line; do
        printList "    " 4 "$line"
    done
else
    warn "  No [PDF:Subset] section found in current uifont.ali"
fi

# =============================================================================
# Section 2: Check font availability in REPORTS_FONT_DIR
# =============================================================================
section "Font File Availability Check"

printList "REPORTS_FONT_DIR" 32 "$REPORTS_FONT_DIR"
printList "custom_fonts_dir" 32 "$CUSTOM_FONTS_DIR"
printf "\n"

if [ ! -d "$REPORTS_FONT_DIR" ]; then
    warn "REPORTS_FONT_DIR does not exist – mappings will be commented out"
    info "  Run deploy_fonts.sh --apply to create and populate it"
else
    FONT_COUNT="$(find "$REPORTS_FONT_DIR" -name "*.ttf" -o -name "*.TTF" 2>/dev/null | wc -l)"
    ok "REPORTS_FONT_DIR exists with $FONT_COUNT TTF file(s)"
fi

# =============================================================================
# Section 3: Build new [PDF:Subset] block
# =============================================================================
section "Building [PDF:Subset] Content"

# Collect all lines for the new [PDF:Subset] section
NEW_SUBSET_LINES=()
NEW_SUBSET_LINES+=("[ PDF:Subset ]")
NEW_SUBSET_LINES+=("# Updated by uifont_ali_update.sh on $(date '+%Y-%m-%d %H:%M:%S')")
NEW_SUBSET_LINES+=("# Host: $(_get_hostname) | REPORTS_FONT_DIR: $REPORTS_FONT_DIR")
NEW_SUBSET_LINES+=("#")
NEW_SUBSET_LINES+=("# Format: \"PostScript font name in report\" = TTF-filename-in-reports-fonts-dir")
NEW_SUBSET_LINES+=("# Commented lines: font TTF not deployed yet → run deploy_fonts.sh --apply")
NEW_SUBSET_LINES+=("")

# ─── Liberation Sans / Helvetica / Arial ──────────────────────────────────────
NEW_SUBSET_LINES+=("# ─── Helvetica / Arial → Liberation Sans ─────────────────────────────────────")
NEW_SUBSET_LINES+=("$(_subset_line "Helvetica"              "LiberationSans-Regular")")
NEW_SUBSET_LINES+=("$(_subset_line "Helvetica-Bold"         "LiberationSans-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line "Helvetica-Oblique"      "LiberationSans-Italic")")
NEW_SUBSET_LINES+=("$(_subset_line "Helvetica-BoldOblique"  "LiberationSans-BoldItalic")")
NEW_SUBSET_LINES+=("$(_subset_line "Arial"                  "LiberationSans-Regular")")
NEW_SUBSET_LINES+=("$(_subset_line "Arial Bold"             "LiberationSans-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line "Arial Italic"           "LiberationSans-Italic")")
NEW_SUBSET_LINES+=("$(_subset_line "Arial Bold Italic"      "LiberationSans-BoldItalic")")
NEW_SUBSET_LINES+=("")

# ─── Liberation Serif / Times ─────────────────────────────────────────────────
NEW_SUBSET_LINES+=("# ─── Times / Times New Roman → Liberation Serif ──────────────────────────────")
NEW_SUBSET_LINES+=("$(_subset_line "Times-Roman"            "LiberationSerif-Regular")")
NEW_SUBSET_LINES+=("$(_subset_line "Times-Bold"             "LiberationSerif-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line "Times-Italic"           "LiberationSerif-Italic")")
NEW_SUBSET_LINES+=("$(_subset_line "Times-BoldItalic"       "LiberationSerif-BoldItalic")")
NEW_SUBSET_LINES+=("$(_subset_line "Times New Roman"        "LiberationSerif-Regular")")
NEW_SUBSET_LINES+=("$(_subset_line "Times New Roman Bold"   "LiberationSerif-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line "Times New Roman Italic" "LiberationSerif-Italic")")
NEW_SUBSET_LINES+=("")

# ─── Liberation Mono / Courier ────────────────────────────────────────────────
NEW_SUBSET_LINES+=("# ─── Courier / Courier New → Liberation Mono ─────────────────────────────────")
NEW_SUBSET_LINES+=("$(_subset_line "Courier"                "LiberationMono-Regular")")
NEW_SUBSET_LINES+=("$(_subset_line "Courier-Bold"           "LiberationMono-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line "Courier-Oblique"        "LiberationMono-Italic")")
NEW_SUBSET_LINES+=("$(_subset_line "Courier-BoldOblique"    "LiberationMono-BoldItalic")")
NEW_SUBSET_LINES+=("$(_subset_line "Courier New"            "LiberationMono-Regular")")
NEW_SUBSET_LINES+=("$(_subset_line "Courier New Bold"       "LiberationMono-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line "Courier New Italic"     "LiberationMono-Italic")")
NEW_SUBSET_LINES+=("")

# ─── DejaVu Sans / Tahoma / Verdana ──────────────────────────────────────────
NEW_SUBSET_LINES+=("# ─── Tahoma / Verdana → DejaVu Sans (approximate metric match) ───────────────")
NEW_SUBSET_LINES+=("$(_subset_line "Tahoma"                 "DejaVuSans")")
NEW_SUBSET_LINES+=("$(_subset_line "Tahoma Bold"            "DejaVuSans-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line "Verdana"                "DejaVuSans")")
NEW_SUBSET_LINES+=("$(_subset_line "Verdana Bold"           "DejaVuSans-Bold")")
NEW_SUBSET_LINES+=("")

# ─── Custom fonts from custom_fonts_dir/ ──────────────────────────────────────
# Two-pass approach:
#   Pass 1: collect "family|priority|qualifier|ttf_base" for every custom TTF
#   Pass 2: sort by family name then by specificity (most specific first),
#           emit grouped by family with one header comment per family.
# This prevents duplicate keys (e.g. four identical "Sparkasse Rg" entries)
# and ensures Oracle Reports picks the right variant for Bold/Italic rendering.
CUSTOM_ADDED=0
if [ -d "$CUSTOM_FONTS_DIR" ]; then
    CUSTOM_TTFS=()
    while IFS= read -r f; do
        CUSTOM_TTFS+=("$f")
    done < <(find "$CUSTOM_FONTS_DIR" -name "*.ttf" -o -name "*.TTF" -o -name "*.ttc" 2>/dev/null | sort)

    if [ "${#CUSTOM_TTFS[@]}" -gt 0 ]; then
        NEW_SUBSET_LINES+=("# ─── Custom fonts (from custom_fonts_dir/) ────────────────────────────────────")
        NEW_SUBSET_LINES+=("# Specific entries (BoldItalic, Bold, Italic) precede the generic (Regular)")

        # Pass 1 – collect font metadata into a temp file
        _FONT_INFO="$(mktemp)"

        for ttf in "${CUSTOM_TTFS[@]}"; do
            base="$(_ttf_base "$ttf")"
            case "$base" in Liberation*|DejaVu*) continue ;; esac

            family="" ; style=""
            if command -v fc-query >/dev/null 2>&1; then
                family="$(fc-query --format '%{family}\n' "$ttf" 2>/dev/null | head -1)"
                style="$(fc-query --format '%{style}\n'  "$ttf" 2>/dev/null | head -1)"
            fi
            family="${family:-$base}"

            printf "%s|%s|%s|%s\n" \
                "$family" \
                "$(_style_sort_priority "$style")" \
                "$(_style_to_qualifier  "$style")" \
                "$base" >> "$_FONT_INFO"
            CUSTOM_ADDED=$(( CUSTOM_ADDED + 1 ))
        done

        # Pass 2 – sort by family (col 1 alpha) then specificity (col 2 numeric),
        #          emit grouped with one header comment per family
        _PREV_FAMILY=""
        while IFS='|' read -r family _prio qualifier ttf_base; do
            if [ "$family" != "$_PREV_FAMILY" ]; then
                [ -n "$_PREV_FAMILY" ] && NEW_SUBSET_LINES+=("")
                NEW_SUBSET_LINES+=("# $family")
                _PREV_FAMILY="$family"
            fi
            NEW_SUBSET_LINES+=("$(_subset_line_q "$family" "$qualifier" "$ttf_base")")
        done < <(sort -t'|' -k1,1 -k2,2n "$_FONT_INFO")

        rm -f "$_FONT_INFO"
        NEW_SUBSET_LINES+=("")
    fi
fi

# Show what was built
for line in "${NEW_SUBSET_LINES[@]}"; do
    info "  $line"
done

# =============================================================================
# Section 4: Diff and Apply
# =============================================================================
section "$( $APPLY_MODE && echo 'Applying Changes to uifont.ali' || echo 'Preview Changes (dry-run)')"

if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 not found – required for safe section replacement in uifont.ali"
    print_summary
    exit $EXIT_CODE
fi

# Write new [PDF:Subset] block to a temp file
TEMP_SECTION="$(mktemp /tmp/pdf_subset_XXXXXX.tmp)"
printf "%s\n" "${NEW_SUBSET_LINES[@]}" > "$TEMP_SECTION"

# Generate the updated uifont.ali using Python (safe section replacement)
TEMP_NEW_ALI="$(mktemp /tmp/uifont_ali_new_XXXXXX.tmp)"

python3 - "$UIFONT_ALI" "$TEMP_SECTION" "$TEMP_NEW_ALI" << 'PYEOF'
import sys, re

src_file  = sys.argv[1]
sec_file  = sys.argv[2]
dst_file  = sys.argv[3]

with open(src_file, encoding='utf-8', errors='replace') as f:
    content = f.read()

with open(sec_file, encoding='utf-8') as f:
    new_section = f.read()

# Match [PDF:Subset] section: from the section header until the next [ or EOF
# Flags: DOTALL so . matches newline, IGNORECASE for section name
pattern = r'\[\s*PDF\s*:\s*Subset\s*\][^\[]*'

if re.search(pattern, content, re.IGNORECASE | re.DOTALL):
    # Replace existing [PDF:Subset] section
    updated = re.sub(pattern, new_section + '\n', content,
                     flags=re.IGNORECASE | re.DOTALL)
else:
    # Append new [PDF:Subset] section
    updated = content.rstrip('\n') + '\n\n' + new_section + '\n'

with open(dst_file, 'w', encoding='utf-8') as f:
    f.write(updated)
PYEOF

PY_RC=$?
if [ "$PY_RC" -ne 0 ]; then
    fail "Python section replacement failed (rc=$PY_RC)"
    rm -f "$TEMP_SECTION" "$TEMP_NEW_ALI"
    print_summary
    exit $EXIT_CODE
fi

# Show diff
if command -v diff >/dev/null 2>&1; then
    DIFF_OUT="$(diff "$UIFONT_ALI" "$TEMP_NEW_ALI" 2>/dev/null)"
    if [ -z "$DIFF_OUT" ]; then
        ok "No changes needed – [PDF:Subset] is already up to date"
    else
        printf "\n"
        info "Changes to uifont.ali (< = remove, > = add):"
        echo "$DIFF_OUT" | while IFS= read -r dline; do
            printf "  %s\n" "$dline"
        done
    fi
fi

if $APPLY_MODE; then
    # Backup original
    backup_file "$UIFONT_ALI"
    if [ "$LAST_BACKUP" = "" ]; then
        fail "Backup failed – aborting write"
        rm -f "$TEMP_SECTION" "$TEMP_NEW_ALI"
        print_summary
        exit $EXIT_CODE
    fi

    # Apply new content
    if cp "$TEMP_NEW_ALI" "$UIFONT_ALI" 2>/dev/null; then
        ok "uifont.ali updated: $UIFONT_ALI"
        ok "Backup stored at : $LAST_BACKUP"
    else
        fail "Failed to write $UIFONT_ALI"
        info "  Restoring from backup: $LAST_BACKUP"
        cp "$LAST_BACKUP" "$UIFONT_ALI" 2>/dev/null
    fi
else
    info "Run with --apply to apply the changes shown above"
fi

# Cleanup temp files
rm -f "$TEMP_SECTION" "$TEMP_NEW_ALI"

# =============================================================================
# Section 5: Post-update reminder
# =============================================================================
section "Next Steps"

if $APPLY_MODE; then
    info "uifont.ali updated. Required follow-up steps:"
fi
info "  1. Run fontpath_config.sh --apply  → set REPORTS_FONT_DIRECTORY in rwserver.conf"
info "  2. Restart Reports Server          → startStop.sh STOP/START WLS_REPORTS"
info "  3. Generate a test report as PDF"
info "  4. Run pdf_font_verify.sh          → verify: emb=yes, type=TrueType in PDF"

if [ "$CUSTOM_ADDED" -gt 0 ]; then
    printf "\n"
    info "  Custom fonts added: $CUSTOM_ADDED font(s) from custom_fonts_dir/"
    info "  Verify the font names match what the report designer used in the report layout"
    info "  If they differ: add a [Global] alias entry in uifont.ali:"
    info '    "Name used in report design" = "Name returned by fc-query"'
fi

# =============================================================================
# Summary
# =============================================================================
print_summary
exit $EXIT_CODE
