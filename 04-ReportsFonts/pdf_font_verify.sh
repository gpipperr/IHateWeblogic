#!/bin/bash
# =============================================================================
# Script   : pdf_font_verify.sh
# Purpose  : Use pdffonts (poppler-utils) to verify that PDF files generated
#            by Oracle Reports contain properly embedded TrueType fonts.
#            Checks each font entry for: type=TrueType, emb=yes, sub=yes.
#            Fails for unembedded fonts; warns for non-TrueType embedded fonts.
# Call     : ./pdf_font_verify.sh [PDF_FILE|DIRECTORY] [--apply]
#            With no argument: scans the current directory for *.pdf files.
#            --apply has no effect (script is read-only by design).
# Requires : pdffonts (poppler-utils)
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
PDF_TARGET=""
for arg in "$@"; do
    case "$arg" in
        --apply) ;; # no-op: script is read-only
        --help)
            printf "Usage: %s [PDF_FILE|DIRECTORY]\n" "$(basename "$0")"
            printf "  PDF_FILE  : verify a single PDF\n"
            printf "  DIRECTORY : scan directory for *.pdf files (recursive)\n"
            printf "  (no arg)  : scan current directory for *.pdf files\n"
            exit 0
            ;;
        *)
            PDF_TARGET="$arg"
            ;;
    esac
done

# =============================================================================
# Banner
# =============================================================================
printLine
printf "\n\033[1mIHateWeblogic – PDF Font Verification\033[0m\n"
printf "Host    : %s\n" "$(_get_hostname)"
printf "Date    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "Log     : %s\n\n" "$LOG_FILE"

# =============================================================================
# Section 1: Prerequisites
# =============================================================================
section "Prerequisites"

if ! command -v pdffonts >/dev/null 2>&1; then
    fail "pdffonts not found – install poppler-utils"
    info "  Run: ./04-ReportsFonts/get_root_install_libs.sh --apply"
    info "  Or:  sudo dnf install -y poppler-utils"
    print_summary
    exit $EXIT_CODE
fi
ok "pdffonts available: $(command -v pdffonts)"

# =============================================================================
# Section 2: Collect PDF files
# =============================================================================
section "PDF Files to Verify"

PDF_FILES=()

if [ -z "$PDF_TARGET" ]; then
    PDF_TARGET="$(pwd)"
fi

if [ -f "$PDF_TARGET" ]; then
    if [[ "${PDF_TARGET,,}" == *.pdf ]]; then
        PDF_FILES+=("$PDF_TARGET")
        ok "Single file: $PDF_TARGET"
    else
        fail "Not a PDF file: $PDF_TARGET"
        print_summary
        exit $EXIT_CODE
    fi
elif [ -d "$PDF_TARGET" ]; then
    while IFS= read -r f; do
        PDF_FILES+=("$f")
    done < <(find "$PDF_TARGET" -iname "*.pdf" 2>/dev/null | sort)

    if [ "${#PDF_FILES[@]}" -eq 0 ]; then
        warn "No PDF files found in: $PDF_TARGET"
        print_summary
        exit $EXIT_CODE
    fi
    ok "${#PDF_FILES[@]} PDF file(s) found in: $PDF_TARGET"
else
    fail "Path not found: $PDF_TARGET"
    print_summary
    exit $EXIT_CODE
fi

# =============================================================================
# Section 3: Analyse each PDF
# =============================================================================
# pdffonts output columns (fixed-width):
#  name                                 type              encoding         emb sub uni object ID
#  ------------------------------------ ----------------- ---------------- --- --- --- ---------
# Columns (0-based character positions in pdffonts output):
#   name      : col 0
#   type      : after name field (~col 38)
#   emb       : "yes"/"no" in the emb column
#   sub       : "yes"/"no" in the sub column

PDF_PASS=0
PDF_FAIL=0
PDF_WARN=0

_verify_pdf() {
    local pdf="$1"
    local fname
    fname="$(basename "$pdf")"

    printf "\n"
    info "File: $pdf"

    local raw
    raw="$(pdffonts "$pdf" 2>&1)"
    local pdffonts_rc=$?

    if [ "$pdffonts_rc" -ne 0 ]; then
        fail "  pdffonts failed (rc=$pdffonts_rc): $fname"
        PDF_FAIL=$(( PDF_FAIL + 1 ))
        return
    fi

    # Count data lines (skip 2-line header)
    local data_lines
    data_lines="$(printf "%s\n" "$raw" | tail -n +3)"

    if [ -z "$data_lines" ]; then
        warn "  No fonts found in PDF – may be a scanned/image-only PDF: $fname"
        PDF_WARN=$(( PDF_WARN + 1 ))
        return
    fi

    local file_ok=true
    local font_count=0
    local unembedded_count=0
    local non_tt_embedded=0

    # Parse each font line using Python3 for reliable fixed-width column parsing
    local analysis
    analysis="$(python3 - "$pdf" <<'PYEOF'
import sys, subprocess, re

pdf = sys.argv[1]

proc = subprocess.run(
    ["pdffonts", pdf],
    capture_output=True, text=True
)
lines = proc.stdout.splitlines()

# Skip two header lines
data = lines[2:]
if not data:
    print("EMPTY")
    sys.exit(0)

for line in data:
    if not line.strip():
        continue
    # pdffonts columns are space-separated but name can contain spaces;
    # the fixed fields from the right are more reliable.
    # Split from right: last 5 tokens = uni, obj-id, obj-gen (3 tokens), sub, emb
    # Actually layout: name(padded) type(padded) encoding(padded) emb sub uni objID gen
    # emb and sub are always "yes" or "no", 3 chars wide
    parts = line.split()
    if len(parts) < 7:
        continue
    # emb is 4th from end (before uni, objID, gen) – but uni/obj can shift
    # Safer: use fixed column offsets from pdffonts man page output
    # emb=col 68 (0-indexed), sub=col 72, uni=col 76 in standard output
    # But widths vary. Use the header dashes line to locate columns.
    # Simplest reliable method: search right-side tokens for yes/no pattern
    # Reverse: parts[-1]=gen, parts[-2]=objID, parts[-3]=uni, parts[-4]=sub, parts[-5]=emb
    # type ends somewhere around index 1..3 depending on name
    # Use: split the line at the type field by matching known type names
    m = re.match(
        r'^(.+?)\s{2,}'                               # name (greedy to 2+ spaces)
        r'(Type 1|TrueType|Type 3|CID TrueType|CID Type 0|CID Type 0C|'
        r'Type 1C|OpenType|Type 0|unknown|None)\s+'   # type
        r'(\S+)\s+'                                    # encoding
        r'(yes|no)\s+'                                 # emb
        r'(yes|no)\s+'                                 # sub
        r'(yes|no)\s+'                                 # uni
        r'(\d+)\s+(\d+)',                             # object ID
        line, re.IGNORECASE
    )
    if not m:
        # Fallback: positional from right
        if len(parts) >= 6:
            name = parts[0]
            emb  = parts[-5] if len(parts) >= 8 else "?"
            sub  = parts[-4] if len(parts) >= 8 else "?"
            ftype = "unknown"
        else:
            continue
    else:
        name  = m.group(1).strip()
        ftype = m.group(2).strip()
        emb   = m.group(4)
        sub   = m.group(5)

    # Classify
    is_tt  = "TrueType" in ftype
    is_emb = (emb == "yes")
    is_sub = (sub == "yes")

    if not is_emb:
        status = "FAIL_UNEMB"
    elif is_tt and is_emb and is_sub:
        status = "OK"
    elif is_tt and is_emb:
        status = "WARN_NOSUB"
    elif is_emb:
        status = "WARN_TYPE"
    else:
        status = "WARN_OTHER"

    print(f"{status}|{name}|{ftype}|emb={emb}|sub={sub}")
PYEOF
)"
    PY_RC=$?

    if [ "$PY_RC" -ne 0 ]; then
        fail "  Python3 analysis failed for: $fname"
        PDF_FAIL=$(( PDF_FAIL + 1 ))
        return
    fi

    if [ "$analysis" = "EMPTY" ]; then
        warn "  No fonts found in PDF (image-only?): $fname"
        PDF_WARN=$(( PDF_WARN + 1 ))
        return
    fi

    while IFS='|' read -r status name ftype emb sub; do
        [ -z "$status" ] && continue
        font_count=$(( font_count + 1 ))
        case "$status" in
            OK)
                ok "    %-45s %-18s %s  %s" "$name" "$ftype" "$emb" "$sub"
                ;;
            WARN_NOSUB)
                warn "  No subset: %-42s %-18s %s  %s" "$name" "$ftype" "$emb" "$sub"
                non_tt_embedded=$(( non_tt_embedded + 1 ))
                file_ok=false
                ;;
            WARN_TYPE)
                warn "  Non-TTF:   %-42s %-18s %s  %s" "$name" "$ftype" "$emb" "$sub"
                non_tt_embedded=$(( non_tt_embedded + 1 ))
                file_ok=false
                ;;
            FAIL_UNEMB)
                fail "  UNEMBED:   %-42s %-18s %s  %s" "$name" "$ftype" "$emb" "$sub"
                unembedded_count=$(( unembedded_count + 1 ))
                file_ok=false
                ;;
            *)
                warn "  Unknown:   %-42s %-18s %s  %s" "$name" "$ftype" "$emb" "$sub"
                file_ok=false
                ;;
        esac
    done <<< "$analysis"

    info "  Fonts in file: $font_count  |  Unembedded: $unembedded_count  |  Non-TrueType: $non_tt_embedded"

    if $file_ok; then
        PDF_PASS=$(( PDF_PASS + 1 ))
    elif [ "$unembedded_count" -gt 0 ]; then
        PDF_FAIL=$(( PDF_FAIL + 1 ))
    else
        PDF_WARN=$(( PDF_WARN + 1 ))
    fi
}

section "Font Analysis per PDF"

for pdf in "${PDF_FILES[@]}"; do
    _verify_pdf "$pdf"
done

# =============================================================================
# Section 4: Summary
# =============================================================================
section "PDF Font Verification Summary"

printf "  PDFs analysed : %d\n" "${#PDF_FILES[@]}"
printf "  \033[32mPass\033[0m (all fonts TrueType+embedded) : %d\n" "$PDF_PASS"
printf "  \033[33mWarn\033[0m (non-TrueType or no subset)   : %d\n" "$PDF_WARN"
printf "  \033[31mFail\033[0m (unembedded fonts)             : %d\n" "$PDF_FAIL"
printf "\n"

if [ "$PDF_FAIL" -gt 0 ]; then
    info "To fix unembedded fonts:"
    info "  1. Run deploy_fonts.sh --apply      – ensure TTFs are in REPORTS_FONT_DIR"
    info "  2. Run uifont_ali_update.sh --apply – update [PDF:Subset] in uifont.ali"
    info "  3. Run fontpath_config.sh --apply   – set REPORTS_FONT_DIRECTORY env var"
    info "  4. Restart Reports Server"
    info "  5. Re-generate the PDF and re-run this script"
fi

# =============================================================================
# Summary
# =============================================================================
printLine
print_summary
exit $EXIT_CODE
