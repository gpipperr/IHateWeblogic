#!/bin/bash
# =============================================================================
# Script   : ihw_tools_lib.sh
# Purpose  : Shared helpers of the standalone customer tools in
#            70-Customer-Projects/tools/bash (export_forms_reports_conf.sh,
#            analyse_forms_reports_export.sh, ...). NOT the IHateWeblogic
#            library (00-Setup/IHateWeblogic_lib.sh) - no environment.conf,
#            no ok/warn/fail; plain bash + coreutils.
#            The road map (Start_beim_Kunden_kochbuch_de.txt step 1) copies all
#            tools/bash/*.sh, so this file always lies next to the tools.
# Use      : _d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#            . "$_d/ihw_tools_lib.sh" || { printf 'ihw_tools_lib.sh missing\n' >&2; exit 2; }
# Rules    : functions only - no top-level set -u / exit / output; prefix ihwt_
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

IHWT_LIB_VERSION="2026-11-04.1"
ihwt_lib_version() { printf '%s' "$IHWT_LIB_VERSION"; }

# -----------------------------------------------------------------------------
# ihwt_mask - mask secrets in a text stream (stdin -> stdout)
#   collect_fmw_env.sh rules + <identifier>, name="..pass.." value=,
#   {AES}..., userid= / authid= / password=, -D...password=, user/pw@alias
# -----------------------------------------------------------------------------
ihwt_mask() {
    sed -E \
        -e 's/(<[^>/]*[Pp]ass[Ww]or[dD][^>]*>)[^<]*/\1***MASKED***/g' \
        -e 's/(<identifier[^>]*>)[^<]*/\1***MASKED***/g' \
        -e 's/(name="[^"]*([Pp]ass[Ww](or)?[dD]|pwd|PWD)[^"]*"[[:space:]]+value=")[^"]*/\1***MASKED***/g' \
        -e 's/\{AES(256)?\}[A-Za-z0-9+\/=]+/{AES}***MASKED***/g' \
        -e 's/((^|[[:space:];&?])(userid|USERID|UserId|authid|AUTHID|password|PASSWORD|Password|passwd|pwd|PWD|dbpassword)[[:space:]]*=[[:space:]]*)[^[:space:];&]+/\1***MASKED***/g' \
        -e 's/(-D[A-Za-z0-9._]*[Pp]ass[Ww]ord[A-Za-z0-9._]*=)[^[:space:]]+/\1***MASKED***/g' \
        -e 's#([A-Za-z0-9_]+)/[^@[:space:]/"]+@#\1/***MASKED***@#g'
}

# -----------------------------------------------------------------------------
# config file parsing
# -----------------------------------------------------------------------------
# ihwt_cfgval FILE KEY - values of KEY=... (all occurrences, without comments)
ihwt_cfgval() { sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" 2>/dev/null | sed 's/[[:space:]]*$//'; }

# ihwt_sections FILE - "section<TAB>key<TAB>value" of an ini-like file
ihwt_sections() {
    awk 'BEGIN{s=""} /^[[:space:]]*[#;]/{next}
         /^[[:space:]]*\[[^]]+\]/{s=$0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/,"",s); next}
         /=/{k=$0; sub(/=.*/,"",k); gsub(/[[:space:]]/,"",k); v=$0; sub(/^[^=]*=/,"",v); sub(/[[:space:]]+$/,"",v)
             if(k!="") print s "\t" k "\t" v}' "$1" 2>/dev/null
}

# ihwt_keys FILE - "key<TAB>value" of a key=value file (no sections)
ihwt_keys() {
    awk '/^[[:space:]]*[#;]/{next} /=/{k=$0; sub(/=.*/,"",k); gsub(/[[:space:]]/,"",k); v=$0; sub(/^[^=]*=/,"",v); sub(/[[:space:]]+$/,"",v); if(k!="") print k "\t" v}' "$1" 2>/dev/null
}

# -----------------------------------------------------------------------------
# ihwt_font_class FILE_NAME - "class;replacement" (04-ReportsFonts/README.md)
#   customer  own / bought fonts (barcode ...) - must move, no replacement
#   ms        Microsoft fonts (Windows / Office licence of the customer) - the
#             library uses free replacements; "identical" = same metrics
#   free      Liberation / DejaVu - OS packages, 14b- deploys them
# -----------------------------------------------------------------------------
ihwt_font_class() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        liberation*|dejavu*|carlito*|caladea*)        printf 'free;OS package (14b-)' ;;
        arialuni*|arial-unicode*|arial_unicode*)      printf 'ms;DejaVu Sans / Noto (similar – only needed for non-Latin text)' ;;
        arialn*)                                      printf 'ms;Liberation Sans Narrow (identical metrics)' ;;
        arial*|ariblk*)                               printf 'ms;Liberation Sans (identical metrics)' ;;
        times*)                                       printf 'ms;Liberation Serif (identical metrics)' ;;
        cour*)                                        printf 'ms;Liberation Mono (identical metrics)' ;;
        calibri*)                                     printf 'ms;Carlito (identical metrics)' ;;
        cambria*)                                     printf 'ms;Caladea (identical metrics) - not set up in 14c yet, see reports_fonts_architecture.md' ;;
        verdana*|tahoma*|trebuc*|segoe*|micross*)     printf 'ms;DejaVu Sans (similar – layout can shift)' ;;
        georgia*|pala*|book*|constan*)                printf 'ms;Liberation Serif (similar – layout can shift)' ;;
        consola*|lucon*)                              printf 'ms;Liberation Mono (similar)' ;;
        wingding*|webdings*|symbol*|marlett*)         printf 'ms;none – symbol font, original TTF needed' ;;
        candara*|corbel*|comic*|impact*|l_10646*|gara*|century*|gothic*|franklin*)
                                                      printf 'ms;DejaVu Sans / Liberation (similar – check)' ;;
        *)                                            printf 'customer;none – must move' ;;
    esac
}

# -----------------------------------------------------------------------------
# ihwt_git_guard DIR NAME - refuse to write customer data into a git work
# tree unless git ignores DIR/NAME. rc 0 = ok, 2 = refused (message on stderr)
# -----------------------------------------------------------------------------
ihwt_git_guard() {
    local dir="$1" name="$2" top
    command -v git >/dev/null 2>&1 || return 0
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 0
    if [ "$dir" = "$top" ]; then
        git -C "$top" check-ignore -q -- "$name" 2>/dev/null && return 0
    elif git -C "$top" check-ignore -q -- "${dir#"$top"/}/$name" 2>/dev/null; then
        return 0
    fi
    printf 'REFUSED: %s is inside the git work tree %s and not ignored –\n' "$dir" "$top" >&2
    printf '         it would contain customer data. Use a path outside git or an ignored path.\n' >&2
    return 2
}

# -----------------------------------------------------------------------------
# ihwt_md_table "Col1;Col2;..." - ';'-CSV on stdin -> Markdown table
#   (no header line in the input). "|" in values is escaped, empty input
#   prints "_none found_".
# -----------------------------------------------------------------------------
ihwt_md_table() {
    awk -F';' -v head="$1" '
        BEGIN { n = split(head, h, ";"); line = "|"; sep = "|"
                for (i = 1; i <= n; i++) { line = line " " h[i] " |"; sep = sep "---|" } }
        NF == 0 { next }
        { if (!rows++) { print line; print sep }
          out = "|"
          for (i = 1; i <= n; i++) { v = (i <= NF ? $i : ""); gsub(/\|/, "\\|", v); if (i == n && NF > n) for (j = n + 1; j <= NF; j++) v = v ";" $j
              out = out " " v " |" }
          print out }
        END { if (!rows) print "_none found_" }'
}
