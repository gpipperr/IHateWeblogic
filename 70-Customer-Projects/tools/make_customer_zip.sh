#!/bin/bash
# =============================================================================
# Script   : make_customer_zip.sh
# Purpose  : Build the download ZIPs of the customer tools - one per platform -
#            from the committed files, so a single link is enough at the
#            customer (no git clone on the customer host):
#              ihw_customer_tools_linux.zip     tools/*.sh (bash/), the road
#                                               map, README and the
#                                               patch_install.ini template
#                                               in tools/doc/
#              ihw_customer_tools_windows.zip   tools/*.ps1 + *.java
#                                               (powershell/) + README
#            each with VERSIONS.txt (version + sha256 of every file) and a
#            .sha256 next to the ZIP.
#            The ZIPs are deterministic (fixed time stamps, sorted, no extra
#            attributes): the same files give byte-identical ZIPs, so git only
#            sees a change when a tool really changed.
#            NOT in the ZIPs: analyse_forms_reports_export.sh + customer-analyse/
#            (the analysis runs on our host), the local cookbook formatter.
# Call     : ./make_customer_zip.sh            check only: are the ZIPs current?
#                                              (exit 1 = stale - run with --apply)
#            ./make_customer_zip.sh --apply    rebuild the stale ZIPs
# Rule     : run before every commit that touches tools/bash or
#            tools/powershell (part of the commit routine, like the
#            customer-data scan) - a stale ZIP sends old tools to the customer
# Download : https://github.com/gpipperr/IHateWeblogic/raw/main/70-Customer-Projects/tools/ihw_customer_tools_linux.zip
#            https://github.com/gpipperr/IHateWeblogic/raw/main/70-Customer-Projects/tools/ihw_customer_tools_windows.zip
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

set -u
APPLY=false
case "${1:-}" in
    --apply) APPLY=true ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    "") ;;
    *) printf 'Unknown option: %s (--apply, --help)\n' "$1" >&2; exit 2 ;;
esac

TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(dirname "$TOOLS")"
for c in zip unzip sha256sum; do command -v "$c" >/dev/null 2>&1 || { printf 'missing: %s\n' "$c" >&2; exit 2; }; done
WORK="$(mktemp -d)" || exit 2
trap 'rm -rf "${WORK:?}"' EXIT
STALE=0

# files per platform: "source;path in the ZIP;mode"
_files_linux() {
    local f
    for f in "$TOOLS"/bash/*.sh; do
        case "$(basename "$f")" in analyse_forms_reports_export.sh) continue ;; esac
        printf '%s;tools/%s;755\n' "$f" "$(basename "$f")"
    done
    printf '%s;tools/doc/README.md;644\n' "$TOOLS/README.md"
    printf '%s;tools/doc/Start_beim_Kunden_kochbuch_de.txt;644\n' "$PROJ/Start_beim_Kunden_kochbuch_de.txt"
    printf '%s;tools/doc/patch_install.ini.template;644\n' "$PROJ/Reports14_linux_manual_install/patch_install.ini"
}
_files_windows() {
    local f
    for f in "$TOOLS"/powershell/*; do
        [ -f "$f" ] || continue
        case "$f" in *.md) printf '%s;tools/doc/%s;644\n' "$f" "$(basename "$f")" ;;
                     *)    printf '%s;tools/%s;644\n' "$f" "$(basename "$f")" ;; esac
    done
}

# _version FILE - first VERSION="..." / *_VERSION="..." of a script
_version() { grep -m1 -oE '[A-Z_]*VERSION="[0-9][^"]*"' "$1" 2>/dev/null | sed 's/.*="//; s/"$//'; }

# _build PLATFORM OUT_ZIP - deterministic ZIP into OUT_ZIP
_build() {
    local plat="$1" out="$2" stage="$WORK/$1" src dst mode
    rm -rf "${stage:?}"; mkdir -p "$stage"
    while IFS=';' read -r src dst mode; do
        [ -f "$src" ] || { printf 'missing source: %s\n' "$src" >&2; return 2; }
        mkdir -p "$stage/$(dirname "$dst")"
        cp "$src" "$stage/$dst"; chmod "$mode" "$stage/$dst"
    done < <("_files_$plat")
    {   printf '# IHateWeblogic customer tools (%s) - https://github.com/gpipperr/IHateWeblogic\n' "$plat"
        printf '# file;version;sha256 - unpack: see doc/Start_beim_Kunden_kochbuch_de.txt (Linux) / doc/README.md\n'
        (cd "$stage" && find tools -type f | LC_ALL=C sort | while read -r f; do
            printf '%s;%s;%s\n' "${f#tools/}" "$(_version "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
        done)
    } > "$stage/VERSIONS.txt"
    mv "$stage/VERSIONS.txt" "$stage/tools/VERSIONS.txt"; chmod 644 "$stage/tools/VERSIONS.txt"
    # fixed time stamp (also for the directories) -> same input, same bytes
    find "$stage" -exec env TZ=UTC touch -h -t 202601010000.00 {} +
    rm -f "$out"
    (cd "$stage" && find tools | LC_ALL=C sort | TZ=UTC zip -X -q -D -@ "$out") || return 2
}

for plat in linux windows; do
    zf="$TOOLS/ihw_customer_tools_$plat.zip"
    new="$WORK/ihw_customer_tools_$plat.zip"
    _build "$plat" "$new" || exit 2
    if [ -f "$zf" ] && cmp -s "$zf" "$new"; then
        printf '  OK     %s is current (%s files)\n' "$(basename "$zf")" "$(unzip -Z1 "$zf" | grep -vc '/$')"
        continue
    fi
    STALE=1
    if [ -f "$zf" ]; then
        printf '  STALE  %s - changed files:\n' "$(basename "$zf")"
        diff <(unzip -p "$zf" tools/VERSIONS.txt 2>/dev/null | grep -v '^#') \
             <(unzip -p "$new" tools/VERSIONS.txt | grep -v '^#') | sed -n 's/^> /           /p'
    else
        printf '  NEW    %s does not exist yet\n' "$(basename "$zf")"
    fi
    if $APPLY; then
        cp "$new" "$zf"
        (cd "$TOOLS" && sha256sum "$(basename "$zf")" > "$(basename "$zf").sha256")
        printf '  BUILT  %s (%s KB)\n' "$(basename "$zf")" "$(( $(stat -c %s "$zf") / 1024 ))"
    fi
done

if [ "$STALE" -eq 1 ] && ! $APPLY; then
    printf '\n  ZIPs are stale - rebuild: %s --apply\n' "$0"
    exit 1
fi
exit 0
