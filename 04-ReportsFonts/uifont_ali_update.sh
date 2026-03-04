#!/bin/bash
# =============================================================================
# Script   : uifont_ali_update.sh
# Purpose  : Backup uifont.ali and REWRITE it completely: sections before
#            the first [PDF...] block are preserved; all [PDF:*] content is
#            replaced by a freshly generated [PDF:Subset] section with
#            Liberation and custom font mappings.
#            Default: dry-run (show diff). Use --apply to write.
# Call     : ./uifont_ali_update.sh [--apply]
# Requires : fc-query (fontconfig), cp, find
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
            printf "  --apply: backup uifont.ali and rewrite the entire file\n"
            printf "           (preserves Global/Printer/Display sections;\n"
            printf "            replaces ALL [PDF:*] sections with a fresh [PDF:Subset])\n"
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
    else                             printf ".."    # Regular/Book/Plain – ".." = any/default qualifier
    fi
    # ".." is required by Oracle Reports enhanced font handler (REPORTS_ENHANCED_FONTHANDLING=yes)
    # for the [PDF:Subset] Regular/default catch-all entry.  An entry without ".." is ignored.
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

# ─── Helvetica / Arial → Liberation Sans ─────────────────────────────────────
# Each family gets both qualifier-based entries (..Bold etc.) AND legacy PS-name
# exact entries (Helvetica-Bold etc.) for reports designed on older systems.
# Qualifier entries use ".." (any qualifier / default) for the Regular catch-all.
# More specific entries (BoldItalic, Bold, Italic) MUST precede the catch-all.
NEW_SUBSET_LINES+=("# ─── Helvetica / Arial → Liberation Sans ─────────────────────────────────────")
NEW_SUBSET_LINES+=("$(_subset_line_q "Helvetica"            "..Italic.Bold" "LiberationSans-BoldItalic")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Helvetica"            "...Bold"       "LiberationSans-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Helvetica"            "..Italic"      "LiberationSans-Italic")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Helvetica"            ".."            "LiberationSans-Regular")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Helvetica-Bold"       ""              "LiberationSans-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Helvetica-Oblique"    ""              "LiberationSans-Italic")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Helvetica-BoldOblique" ""             "LiberationSans-BoldItalic")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Arial"                "..Italic.Bold" "LiberationSans-BoldItalic")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Arial"                "...Bold"       "LiberationSans-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Arial"                "..Italic"      "LiberationSans-Italic")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Arial"                ".."            "LiberationSans-Regular")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Arial Bold"           ""              "LiberationSans-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Arial Italic"         ""              "LiberationSans-Italic")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Arial Bold Italic"    ""              "LiberationSans-BoldItalic")")
NEW_SUBSET_LINES+=("")

# ─── Times / Times New Roman → Liberation Serif ───────────────────────────────
NEW_SUBSET_LINES+=("# ─── Times / Times New Roman → Liberation Serif ──────────────────────────────")
NEW_SUBSET_LINES+=("$(_subset_line_q "Times New Roman"      "..Italic.Bold" "LiberationSerif-BoldItalic")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Times New Roman"      "...Bold"       "LiberationSerif-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Times New Roman"      "..Italic"      "LiberationSerif-Italic")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Times New Roman"      ".."            "LiberationSerif-Regular")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Times New Roman Bold"    ""           "LiberationSerif-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Times New Roman Italic"  ""           "LiberationSerif-Italic")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Times-Roman"          ""              "LiberationSerif-Regular")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Times-Bold"           ""              "LiberationSerif-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Times-Italic"         ""              "LiberationSerif-Italic")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Times-BoldItalic"     ""              "LiberationSerif-BoldItalic")")
NEW_SUBSET_LINES+=("")

# ─── Courier / Courier New → Liberation Mono ──────────────────────────────────
NEW_SUBSET_LINES+=("# ─── Courier / Courier New → Liberation Mono ─────────────────────────────────")
NEW_SUBSET_LINES+=("$(_subset_line_q "Courier"              "..Italic.Bold" "LiberationMono-BoldItalic")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Courier"              "...Bold"       "LiberationMono-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Courier"              "..Italic"      "LiberationMono-Italic")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Courier"              ".."            "LiberationMono-Regular")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Courier-Bold"         ""              "LiberationMono-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Courier-Oblique"      ""              "LiberationMono-Italic")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Courier-BoldOblique"  ""              "LiberationMono-BoldItalic")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Courier New"          "..Italic.Bold" "LiberationMono-BoldItalic")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Courier New"          "...Bold"       "LiberationMono-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Courier New"          "..Italic"      "LiberationMono-Italic")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Courier New"          ".."            "LiberationMono-Regular")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Courier New Bold"     ""              "LiberationMono-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Courier New Italic"   ""              "LiberationMono-Italic")")
NEW_SUBSET_LINES+=("")

# ─── Tahoma / Verdana → DejaVu Sans ──────────────────────────────────────────
NEW_SUBSET_LINES+=("# ─── Tahoma / Verdana → DejaVu Sans (approximate metric match) ───────────────")
NEW_SUBSET_LINES+=("$(_subset_line_q "Tahoma"               "...Bold"       "DejaVuSans-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Tahoma"               ".."            "DejaVuSans")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Tahoma Bold"          ""              "DejaVuSans-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Verdana"              "...Bold"       "DejaVuSans-Bold")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Verdana"              ".."            "DejaVuSans")")
NEW_SUBSET_LINES+=("$(_subset_line_q "Verdana Bold"         ""              "DejaVuSans-Bold")")
NEW_SUBSET_LINES+=("")

# ─── Custom fonts from custom_fonts_dir/ ──────────────────────────────────────
# Two-pass approach:
#   Pass 1: collect "family|priority|qualifier|ttf_base" for every custom TTF
#   Pass 2: sort by family name then by specificity (most specific first),
#           emit grouped by family with one header comment per family.
# This prevents duplicate keys and ensures Oracle Reports picks the right
# variant for Bold/Italic rendering.
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
        # Format: family|priority|qualifier|ttf_base|psname
        # psname = fc-query %{postscriptname} of the Regular variant (no style suffix)
        # Used in Pass 3 to add PS-name alias entries for fonts whose fc-query family
        # name contains spaces (e.g. "Corp Font") but reports use the no-space
        # PostScript name (e.g. "CorpFont").
        _FONT_INFO="$(mktemp)"

        for ttf in "${CUSTOM_TTFS[@]}"; do
            base="$(_ttf_base "$ttf")"
            case "$base" in Liberation*|DejaVu*) continue ;; esac

            family="" ; style="" ; psname=""
            if command -v fc-query >/dev/null 2>&1; then
                family="$(fc-query --format '%{family}\n'         "$ttf" 2>/dev/null | head -1)"
                style="$(fc-query  --format '%{style}\n'          "$ttf" 2>/dev/null | head -1)"
                psname="$(fc-query --format '%{postscriptname}\n' "$ttf" 2>/dev/null | head -1)"
            fi
            family="${family:-$base}"

            printf "%s|%s|%s|%s|%s\n" \
                "$family" \
                "$(_style_sort_priority "$style")" \
                "$(_style_to_qualifier  "$style")" \
                "$base" \
                "${psname:-}" >> "$_FONT_INFO"
            CUSTOM_ADDED=$(( CUSTOM_ADDED + 1 ))
        done

        # Pass 2 – sort by family (col 1 alpha) then specificity (col 2 numeric),
        #          emit grouped with one header comment per family.
        #          Also track the PostScript base name per family (from Regular variant).
        _PREV_FAMILY=""
        declare -A _FAMILY_PSBASE
        while IFS='|' read -r family _prio qualifier ttf_base psname; do
            if [ "$family" != "$_PREV_FAMILY" ]; then
                [ -n "$_PREV_FAMILY" ] && NEW_SUBSET_LINES+=("")
                NEW_SUBSET_LINES+=("# $family")
                _PREV_FAMILY="$family"
            fi
            NEW_SUBSET_LINES+=("$(_subset_line_q "$family" "$qualifier" "$ttf_base")")
            # Capture PS base from Regular (priority=9): strip any bold/italic suffix
            # after the first [-,] so "CorpFont-Bold" → "CorpFont"
            if [ "$_prio" = "9" ] && [ -n "$psname" ]; then
                _FAMILY_PSBASE["$family"]="${psname%%[-,]*}"
            fi
        done < <(sort -t'|' -k1,1 -k2,2n "$_FONT_INFO")

        # Pass 3 – for families where the PS base name differs from the family name
        #          (case-insensitive), emit duplicate [PDF:Subset] entries under
        #          the PS name so reports that use the no-space PostScript name
        #          (e.g. "SparkasseRg") are also mapped to the correct TTF, even
        #          when fc-query reports the family as "Sparkasse Rg" (with space).
        #          Comparison uses the full family string vs psbase (NOT family
        #          stripped of spaces) so "Sparkasse Rg" != "SparkasseRg" → alias.
        for family in "${!_FAMILY_PSBASE[@]}"; do
            psbase="${_FAMILY_PSBASE[$family]}"
            [ -z "$psbase" ] && continue
            if [ "${family,,}" != "${psbase,,}" ]; then
                NEW_SUBSET_LINES+=("")
                NEW_SUBSET_LINES+=("# $psbase  (PS-name alias → \"$family\")")
                while IFS='|' read -r f _prio qualifier ttf_base _ps; do
                    [ "$f" != "$family" ] && continue
                    NEW_SUBSET_LINES+=("$(_subset_line_q "$psbase" "$qualifier" "$ttf_base")")
                done < <(sort -t'|' -k1,1 -k2,2n "$_FONT_INFO")
            fi
        done
        unset _FAMILY_PSBASE

        rm -f "$_FONT_INFO"
        NEW_SUBSET_LINES+=("")
    fi
fi

# Show what was built
for line in "${NEW_SUBSET_LINES[@]}"; do
    info "  $line"
done

# =============================================================================
# Section 4: Build complete new uifont.ali (pure bash – no python3)
# Strategy: preserve every line of the original file that comes BEFORE the
#           first [PDF...] section header; then append the freshly generated
#           [PDF:Subset] block.  All existing [PDF:*] content is discarded and
#           rewritten from scratch – no orphaned entries can survive.
# =============================================================================
section "$( $APPLY_MODE && echo 'Applying Changes to uifont.ali' || echo 'Preview Changes (dry-run)')"

TEMP_NEW_ALI="$(mktemp /tmp/uifont_ali_new_XXXXXX.tmp)" || {
    fail "Cannot create temp file"
    print_summary
    exit $EXIT_CODE
}

# --- Pass 1: copy pre-PDF lines from original file ---------------------------
PRE_PDF_WRITTEN=false
while IFS= read -r line || [ -n "$line" ]; do
    # Stop at first [PDF...] section header (case-insensitive)
    if [[ "${line,,}" =~ ^\[\ *pdf ]]; then
        PRE_PDF_WRITTEN=true
        break
    fi
    printf "%s\n" "$line" >> "$TEMP_NEW_ALI"
done < "$UIFONT_ALI"

# Ensure there is exactly one blank line before the PDF block
printf "\n" >> "$TEMP_NEW_ALI"

# --- Pass 2: append the newly generated [PDF:Subset] block -------------------
printf "%s\n" "${NEW_SUBSET_LINES[@]}" >> "$TEMP_NEW_ALI"

if $PRE_PDF_WRITTEN; then
    info "Pre-PDF sections (Global/Printer/Display) preserved from original"
else
    info "No pre-PDF sections found in original – file contained only PDF content"
fi

# --- Show diff ---------------------------------------------------------------
if command -v diff >/dev/null 2>&1; then
    DIFF_OUT="$(diff "$UIFONT_ALI" "$TEMP_NEW_ALI" 2>/dev/null)"
    if [ -z "$DIFF_OUT" ]; then
        ok "No changes needed – uifont.ali is already up to date"
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
        rm -f "$TEMP_NEW_ALI"
        print_summary
        exit $EXIT_CODE
    fi

    # cp preserves original file permissions and ownership
    if cp "$TEMP_NEW_ALI" "$UIFONT_ALI" 2>/dev/null; then
        ok "uifont.ali rewritten : $UIFONT_ALI"
        ok "Backup stored at     : $LAST_BACKUP"
    else
        fail "Failed to write $UIFONT_ALI"
        info "  Restoring from backup: $LAST_BACKUP"
        cp "$LAST_BACKUP" "$UIFONT_ALI" 2>/dev/null
    fi
else
    info "Run with --apply to apply the changes shown above"
fi

rm -f "$TEMP_NEW_ALI"

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
