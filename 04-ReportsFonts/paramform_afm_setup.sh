#!/bin/bash
# =============================================================================
# Script   : paramform_afm_setup.sh
# Purpose  : Prepare the Oracle Reports "screen printer" path (HTML output /
#            HTML parameter form) for correct font rendering. This is a
#            completely separate font path from [PDF:Subset]/uifont.ali
#            (see uifont_ali_update.sh) -- the screen printer resolves fonts
#            via screenprinter.ppd + AFM metric files, not via
#            REPORTS_FONT_DIRECTORY TTF embedding. Without an AFM, a font
#            falls back to *DefaultFont or renders as Symbol (Greek glyphs).
#            See HTML_ParameterForm_Fonts.md for the full root-cause writeup.
#            Step A: FontSpecific copies of the standard PostScript AFMs
#              (Helvetica/Courier/Times) from the Oracle Home AFM directory
#              into the domain-local AFM directory (never touches Oracle Home).
#            Step B: generate AFM files for the TTF fonts deployed in
#              REPORTS_FONT_DIR via ttf2reports_afm.py, then --check each one.
#            Step C: add the matching *Font lines to screenprinter.ppd.
#            Default: dry-run. Use --apply to write.
# Call     : ./paramform_afm_setup.sh [--apply] [--scan-reports <dir>]
# Requires : python3-fonttools, fc-query (fontconfig), sed, grep
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 04-ReportsFonts/HTML_ParameterForm_Fonts.md
#            MOS Doc ID 300416.1
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
SCAN_REPORTS_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)
            APPLY_MODE=true
            shift
            ;;
        --scan-reports)
            SCAN_REPORTS_DIR="$2"
            shift 2
            ;;
        --help)
            printf "Usage: %s [--apply] [--scan-reports <dir>]\n" "$(basename "$0")"
            printf "  Default: dry-run – show what would change, write nothing\n"
            printf "  --apply: create FontSpecific AFM copies, generate AFMs from\n"
            printf "           TTF fonts in REPORTS_FONT_DIR, and add *Font lines\n"
            printf "           to screenprinter.ppd\n"
            printf "  --scan-reports <dir>: list face=\"...\" fonts referenced by\n"
            printf "           XML report sources under <dir> and flag any that\n"
            printf "           have no *Font entry / AFM file (information only)\n"
            exit 0
            ;;
        *)
            printf "\033[31mERROR\033[0m Unknown argument: %s\n" "$1" >&2
            exit 1
            ;;
    esac
done

# =============================================================================
# Guard: must run as the Oracle software owner, not as root
# =============================================================================
if [ "$(id -un)" = "root" ]; then
    fail "Run as the Oracle software owner (e.g. oracle), not as root"
    info "  AFM/PPD files must be owned by the user the Reports engine runs as"
    printLine
    print_summary
    exit $EXIT_CODE
fi

# =============================================================================
# Check: python3-fonttools (generation only, --check needs no extra module)
# =============================================================================
if ! python3 -c 'import fontTools' 2>/dev/null; then
    fail "python3-fonttools not installed (required by ttf2reports_afm.py)"
    info "  Install: sudo dnf install python3-fonttools"
    printLine
    print_summary
    exit $EXIT_CODE
fi

# =============================================================================
# Paths
# =============================================================================
TTF2AFM="$SCRIPT_DIR/ttf2reports_afm.py"
REPORTS_FONT_DIR="${REPORTS_FONT_DIR:-$DOMAIN_HOME/reports/fonts}"

if [ -n "${REPORTS_ADMIN:-}" ]; then
    TK_ADMIN="$REPORTS_ADMIN"
else
    _reptools_dir="$(find "$DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent" \
        -maxdepth 1 -mindepth 1 -type d -name "reptools*" 2>/dev/null | sort | head -1)"
    if [ -z "$_reptools_dir" ]; then
        fail "Cannot locate a ReportsToolsComponent instance under $DOMAIN_HOME"
        info "  Set REPORTS_ADMIN/REPORTS_COMPONENT_HOME in environment.conf"
        printLine
        print_summary
        exit $EXIT_CODE
    fi
    TK_ADMIN="$_reptools_dir/guicommon/tk/admin"
fi
unset _reptools_dir

OH_AFM="$ORACLE_HOME/guicommon/tk/admin/AFM"
AFM_DIR="$TK_ADMIN/AFM"
PPD="$TK_ADMIN/PPD/screenprinter.ppd"

# =============================================================================
# Banner
# =============================================================================
printLine
printf "\n\033[1mIHateWeblogic – Reports Parameter Form Font Setup (AFM/PPD)\033[0m\n"
printf "Host    : %s\n" "$(_get_hostname)"
printf "Date    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "Mode    : %s\n" "$( $APPLY_MODE && echo 'APPLY (will write AFM/PPD files)' || echo 'DRY-RUN (use --apply to write)')"
printf "Log     : %s\n\n" "$LOG_FILE"

section "Target Paths"
printList "Oracle Home AFM"    40 "$OH_AFM"
printList "Domain AFM dir"     40 "$AFM_DIR"
printList "screenprinter.ppd"  40 "$PPD"
printList "REPORTS_FONT_DIR"   40 "$REPORTS_FONT_DIR"

printf "\n"

if [ ! -d "$OH_AFM" ]; then
    fail "Oracle Home AFM directory not found: $OH_AFM"
    info "  Check ORACLE_HOME in environment.conf"
    printLine
    print_summary
    exit $EXIT_CODE
fi

if [ ! -f "$PPD" ]; then
    fail "screenprinter.ppd not found: $PPD"
    info "  Check that the ReportsToolsComponent instance is fully installed"
    printLine
    print_summary
    exit $EXIT_CODE
fi

if [ ! -d "$REPORTS_FONT_DIR" ]; then
    warn "Font directory does not exist: $REPORTS_FONT_DIR"
    info "  Run deploy_fonts.sh --apply first to populate it"
fi

if $APPLY_MODE; then
    mkdir -p "$AFM_DIR" 2>/dev/null
fi

# =============================================================================
# Step A: FontSpecific copies of the standard PostScript AFMs
# =============================================================================
section "Step A: FontSpecific Copies of Standard AFMs"

STD_AFM_PATTERNS=("Helvetica*" "Courier*" "Times*")
STD_COPIED=0
STD_SKIPPED=0

for pattern in "${STD_AFM_PATTERNS[@]}"; do
    for src in "$OH_AFM"/$pattern; do
        [ -f "$src" ] || continue
        name="$(basename "$src")"
        tgt="$AFM_DIR/$name"

        if [ -f "$tgt" ] && grep -q '^EncodingScheme FontSpecific' "$tgt" 2>/dev/null; then
            ok "  Already FontSpecific: $name"
            STD_SKIPPED=$((STD_SKIPPED + 1))
            continue
        fi

        if $APPLY_MODE; then
            sed 's/^EncodingScheme .*/EncodingScheme FontSpecific/' "$src" > "$tgt"
            ok "  FontSpecific copy written: $name"
        else
            info "  Would create FontSpecific copy: $name"
        fi
        STD_COPIED=$((STD_COPIED + 1))
    done
done

printf "\n"
printList "Standard AFMs copied/updated" 40 "$STD_COPIED"
printList "Standard AFMs already ok"     40 "$STD_SKIPPED"

# =============================================================================
# Step B: generate AFMs for TTF fonts in REPORTS_FONT_DIR, then --check
# =============================================================================
section "Step B: AFM Generation for Deployed TTF Fonts"

GEN_OK=0
GEN_FAIL=0
GEN_SKIPPED=0
declare -a PPD_KEYS=()

if [ -d "$REPORTS_FONT_DIR" ] && command -v fc-query >/dev/null 2>&1; then
    while IFS= read -r -d '' ttf; do
        family="$(fc-query --format '%{family}\n' "$ttf" 2>/dev/null | head -1)"
        style="$(fc-query --format '%{style}\n' "$ttf" 2>/dev/null | head -1)"
        [ -n "$family" ] || continue

        family_key="$(printf "%s" "$family" | tr -d '[:space:]')"
        case "$style" in
            *Bold*Italic*|*Italic*Bold*) key="${family_key}-BoldItalic" ;;
            *Bold*)                      key="${family_key}-Bold" ;;
            *Italic*|*Oblique*)          key="${family_key}-Italic" ;;
            *)                           key="${family_key}" ;;
        esac

        PPD_KEYS+=("$key")
        afm_file="$AFM_DIR/$key"

        if [ -f "$afm_file" ]; then
            if check_msg="$(python3 "$TTF2AFM" --check "$afm_file" 2>&1)"; then
                ok "  AFM already present and ok: $key"
                GEN_SKIPPED=$((GEN_SKIPPED + 1))
                continue
            else
                warn "  AFM present but flagged by --check, regenerating: $key"
            fi
        fi

        if $APPLY_MODE; then
            gen_err="$(mktemp)"
            if python3 "$TTF2AFM" "$ttf" "$key" -o "$afm_file" 2>"$gen_err"; then
                if check_msg="$(python3 "$TTF2AFM" --check "$afm_file" 2>&1)"; then
                    ok "  Generated and checked ok: $key ($(basename "$ttf"))"
                    GEN_OK=$((GEN_OK + 1))
                else
                    warn "  Generated but --check flagged issues: $key"
                    while IFS= read -r line; do info "    $line"; done <<< "$check_msg"
                    GEN_FAIL=$((GEN_FAIL + 1))
                fi
            else
                fail "  Generation failed: $key ($(basename "$ttf"))"
                info "    $(cat "$gen_err" 2>/dev/null)"
                GEN_FAIL=$((GEN_FAIL + 1))
            fi
            rm -f "$gen_err"
        else
            info "  Would generate AFM: $key (from $(basename "$ttf"), style=\"$style\")"
            GEN_OK=$((GEN_OK + 1))
        fi
    done < <(find "$REPORTS_FONT_DIR" \( -iname "*.ttf" -o -iname "*.ttc" \) -print0 2>/dev/null)
elif [ -d "$REPORTS_FONT_DIR" ]; then
    warn "fc-query not found -- cannot enumerate fonts in $REPORTS_FONT_DIR"
    info "  Install fontconfig (get_root_install_libs.sh) to use this step"
fi

printf "\n"
printList "AFMs generated/updated" 40 "$GEN_OK"
printList "AFMs already ok"        40 "$GEN_SKIPPED"
printList "AFMs with problems"     40 "$GEN_FAIL"

# =============================================================================
# Step C: add matching *Font lines to screenprinter.ppd
# =============================================================================
section "Step C: screenprinter.ppd *Font Entries"

PPD_ADDED=0
PPD_SKIPPED=0
PPD_BACKED_UP=false

ALL_KEYS=("Helvetica" "Helvetica-Bold" "Helvetica-Oblique" "Helvetica-BoldOblique" \
          "Courier" "Courier-Bold" "Courier-Oblique" "Courier-BoldOblique" \
          "Times-Roman" "Times-Bold" "Times-Italic" "Times-BoldItalic" \
          "${PPD_KEYS[@]}")

for key in "${ALL_KEYS[@]}"; do
    [ -n "$key" ] || continue
    if grep -q "^\*Font ${key}:" "$PPD" 2>/dev/null; then
        ok "  Already present: *Font ${key}:"
        PPD_SKIPPED=$((PPD_SKIPPED + 1))
        continue
    fi

    LINE="*Font ${key}: Standard \"(001.000)\" Standard ROM"
    if $APPLY_MODE; then
        if ! $PPD_BACKED_UP; then
            backup_file "$PPD"
            PPD_BACKED_UP=true
        fi
        LAST_FONT_LINE="$(grep -n '^\*Font ' "$PPD" | tail -1 | cut -d: -f1)"
        if [ -n "$LAST_FONT_LINE" ]; then
            sed -i "${LAST_FONT_LINE}a ${LINE}" "$PPD"
        else
            printf "%s\n" "$LINE" >> "$PPD"
        fi
        ok "  Added: $LINE"
    else
        info "  Would add: $LINE"
    fi
    PPD_ADDED=$((PPD_ADDED + 1))
done

printf "\n"
printList "*Font lines added"   40 "$PPD_ADDED"
printList "*Font lines already present" 40 "$PPD_SKIPPED"

# =============================================================================
# Optional: --scan-reports
# =============================================================================
if [ -n "$SCAN_REPORTS_DIR" ]; then
    section "Report Source Scan: $SCAN_REPORTS_DIR"

    if [ ! -d "$SCAN_REPORTS_DIR" ]; then
        warn "Directory not found: $SCAN_REPORTS_DIR"
    else
        USED_FACES="$(grep -rho 'face="[^"]*"' "$SCAN_REPORTS_DIR" 2>/dev/null \
            | sed -E 's/face="([^"]*)"/\1/' | sort -u)"
        if [ -z "$USED_FACES" ]; then
            info "  No face=\"...\" attributes found in report sources under this directory"
        else
            while IFS= read -r face; do
                [ -n "$face" ] || continue
                face_key="$(printf "%s" "$face" | tr -d '[:space:]')"
                if grep -q "^\*Font ${face_key}:" "$PPD" 2>/dev/null || [ -f "$AFM_DIR/$face_key" ]; then
                    ok "  face=\"$face\" -> *Font/AFM present"
                else
                    warn "  face=\"$face\" -> no *Font entry / AFM file ($face_key)"
                fi
            done <<< "$USED_FACES"
        fi
    fi
fi

# =============================================================================
# Next Steps
# =============================================================================
section "Next Steps"

if ! $APPLY_MODE; then
    info "Run with --apply to write the changes above"
fi
info "  Restart the Reports engine to pick up the new AFM/PPD configuration:"
info "    kill -TERM \$(pgrep -f 'RWEngine name=rwEng-0')"
info "  (the engine is respawned automatically by the Reports Server)"
info "  See HTML_ParameterForm_Fonts.md for background and the manual verification steps"

# =============================================================================
# Summary
# =============================================================================
printLine
print_summary
exit $EXIT_CODE
