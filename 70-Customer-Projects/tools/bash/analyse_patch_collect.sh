#!/bin/bash
# =============================================================================
# Script   : analyse_patch_collect.sh
# Purpose  : Turn a collection of collect_fmw_env.sh into the patch analysis
#            report (Markdown) for the customer: environment, installed
#            patches, the patch list of the cycle against this environment
#            (applies / installed / missing), Java, other homes, web tier,
#            OPatch prerequisites, the order of work and the route (cookbook
#            or IHateWeblogic library) plus rule-based findings.
#            Reference = our patch lists (no number is typed twice):
#              14.1.2   09-Install/download/patches_fmw.csv
#                       + 09-Install/oracle_software_version.conf (minimums)
#              12.2.1.x newest 70-Customer-Projects/FormsReports12_patch_cpu_*/patches_*.csv
#            Template: ../customer-analyse/patch_analyse_template.md
#            Runs on OUR side (needs the repository) - not part of the
#            customer tools ZIP.
# Call     : analyse_patch_collect.sh -i <fmw_collect_*.zip.enc|.zip|dir>
#                 -k <customer> [-o <outbase>] [--date YYYY-MM-DD]
#                 [--csv <patch list>] [--fresh]
#            -i       the collection (encrypted zip, zip, tar.gz or directory)
#            -k       short customer name (directory + report name)
#            -o       base directory (default ../customer-analyse next to this
#                     script) - must be git-ignored inside a work tree
#            --date   date of the run directory (default today)
#            --csv    patch list instead of the automatic choice by release
#            --fresh  unpack the collection again (default: reuse collect/)
# Output   : <outbase>/<date>_<customer>/patch_analyse_<customer>_<date>.md
#            + csv/patch/ (tables) + collect/ (unpacked collection)
# Safety   : the collection is masked at the source; every value passes
#            ihwt_mask again and the finished report is checked for
#            clear-text patterns (deleted on a hit). Customer data - NEVER
#            commit the output.
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

set -u
umask 077
VERSION="2026-11-05.3"
_IHWT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ihw_tools_lib.sh
. "$_IHWT_DIR/ihw_tools_lib.sh" || { printf 'ihw_tools_lib.sh missing next to %s\n' "$0" >&2; exit 2; }
REPO="$(cd "$_IHWT_DIR/../../.." && pwd)"
GH="https://github.com/gpipperr/IHateWeblogic/blob/main"

IN=""; CUST=""; OUTBASE="$_IHWT_DIR/../customer-analyse"; DATE="$(date +%Y-%m-%d)"
PCSV=""; FRESH=false
TEMPLATE="$_IHWT_DIR/../customer-analyse/patch_analyse_template.md"
while [ $# -gt 0 ]; do
    case "$1" in
        -i) IN="${2:-}"; shift ;;
        -k) CUST="${2:-}"; shift ;;
        -o) OUTBASE="${2:-}"; shift ;;
        --date) DATE="${2:-}"; shift ;;
        --csv) PCSV="${2:-}"; shift ;;
        --fresh) FRESH=true ;;
        -h|--help) sed -n '2,36p' "$0"; printf 'Version: %s\n' "$VERSION"; exit 0 ;;
        -V|--version) printf '%s\n' "$VERSION"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
say() { printf '  %s\n' "$*"; }
die() { printf '  ERROR %s\n' "$*" >&2; exit 2; }
[ -n "$IN" ] && [ -e "$IN" ] || die "collection not found: -i <fmw_collect_*.zip.enc|.zip|dir>"
[[ "$CUST" =~ ^[A-Za-z0-9_-]+$ ]] || die "-k <customer>: letters, digits, _ and - only"
[[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--date YYYY-MM-DD"
[ -f "$TEMPLATE" ] || die "template missing: $TEMPLATE"
[ -z "$PCSV" ] || [ -f "$PCSV" ] || die "patch list not found: $PCSV"
mkdir -p "$OUTBASE" 2>/dev/null
OUTBASE="$(cd "$OUTBASE" 2>/dev/null && pwd)" || die "output base not found"
RUNNAME="${DATE}_${CUST}"
ihwt_git_guard "$OUTBASE" "$RUNNAME" || exit 2

RUN="$OUTBASE/$RUNNAME"
REPORT="$RUN/patch_analyse_${CUST}_${DATE}.md"
CSV="$RUN/csv/patch"; MD="$RUN/.md_patch"
mkdir -p "$RUN" "$CSV" "$MD" || exit 2
IN="$(readlink -f "$IN")"
say "analyse_patch_collect.sh $VERSION (ihw_tools_lib $(ihwt_lib_version))"
say "collection $IN"
say "run dir    $RUN"

# =============================================================================
# 1. unpack, facts
# =============================================================================
if [ -d "$IN" ]; then
    CDIR="$IN"
else
    CDIR="$RUN/collect"
    if $FRESH || [ ! -d "$CDIR" ]; then
        rm -rf "${CDIR:?}"
        ihwt_unpack "$IN" "$CDIR" || die "unpacking failed: $IN"
    fi
fi
ROOT="$(dirname "$(find "$CDIR" -maxdepth 3 -name 00_summary.txt | head -1)")"
SUM="$ROOT/00_summary.txt"
[ -f "$SUM" ] || die "no 00_summary.txt in the collection"

M()   { ihwt_mask; }
md()  { ihwt_md_table "$1" > "$MD/$2.md"; }
F()   { ihwt_fact "$SUM" "$1"; }
B()   { ihwt_block "$ROOT/$1" "$2"; }
cnt() { grep -c "$1" "$2" 2>/dev/null || true; }
vge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }   # vge A B: A >= B
FIND="$CSV/findings.csv"; : > "$FIND"
NOTCHK="$CSV/not_checked.csv"; : > "$NOTCHK"
f_add()  { printf '%s;%s;%s;%s\n' "$1" "$2" "$(printf '%s' "$3" | sed 's/;/,/g')" "$(printf '%s' "$4" | sed 's/;/,/g')" >> "$FIND"; }
nc_add() { printf '%s;%s\n' "$1" "$2" >> "$NOTCHK"; }
ev()     { printf '%s;%s;%s\n' "$1" "$(printf '%s' "$2" | sed 's/;/,/g')" "$(printf '%s' "$3" | sed 's/;/,/g')"; }

COL_VER="$(sed -n '2s/^collect_fmw_env.sh version \([0-9.-]*\).*/\1/p' "$SUM")"
COL_DATE="$(sed -n '1s/^.* – //p' "$SUM")"
SRC_HOST="$(F Host)"; SRC_OH="$(F ORACLE_HOME)"; SRC_DH="$(F DOMAIN_HOME)"
SRC_OS="$(F OS)"; SRC_GLIBC="$(F glibc)"
PV="$(F 'Product versions (registry.xml)')"; [ -z "$PV" ] && PV="$(F Distributions)"
FMW_VER="$(printf '%s' "$PV" | tr ';' '\n' | grep -v OPatch | grep -oE '1[24]\.[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -V | tail -1)"
case "$FMW_VER" in 14.1.2*) REL=14 ;; 12.2.1*) REL=12 ;; *) REL="" ;; esac
[ -n "$COL_VER" ] || say "WARN unknown collector version"
vge "${COL_VER:-0}" "2026-11-05.1" || nc_add "components / other homes / OPatch prerequisites / client JRE (files 33/34/35/44)" "collector older than 2026-11-05.1 - fresh collection"

# =============================================================================
# 2. reference: patch list of the cycle
# =============================================================================
COOKBOOK=""
if [ -z "$PCSV" ]; then
    case "$REL" in
        14) PCSV="$REPO/09-Install/download/patches_fmw.csv" ;;
        12) d="$(ls -d "$REPO"/70-Customer-Projects/FormsReports12_patch_cpu_* 2>/dev/null | sort | tail -1)"
            PCSV="$(ls "$d"/patches_*.csv 2>/dev/null | head -1)" ;;
    esac
fi
[ -f "$PCSV" ] || die "no patch list for FMW version '${FMW_VER:-unknown}' - use --csv"
case "$REL" in
    14) d="$(ls -d "$REPO"/70-Customer-Projects/FormsReports14_patch_cpu_* 2>/dev/null | sort | tail -1)"
        COOKBOOK="$(ls "$d"/*manual*.md 2>/dev/null | head -1)" ;;
    12) d="$(ls -d "$REPO"/70-Customer-Projects/FormsReports12_patch_cpu_* 2>/dev/null | sort | tail -1)"
        COOKBOOK="$(ls "$d"/*Kochbuch*.txt 2>/dev/null | head -1)" ;;
esac
CYCLE="$(sed -n '1s/^#.* - \(.*\)$/\1/p' "$PCSV")"; [ -z "$CYCLE" ] && CYCLE="$(basename "$PCSV")"
CSV_NAME="$(basename "$PCSV")"
LIBCSV=false; [ "$(readlink -f "$PCSV")" = "$(readlink -f "$REPO/09-Install/download/patches_fmw.csv")" ] && LIBCSV=true
# minimums: library conf for the library list, else from the descriptions
CONF="$REPO/09-Install/oracle_software_version.conf"
_cv() { sed -n "s/^$1=\"\\([^\"]*\\)\".*/\\1/p" "$CONF" 2>/dev/null | head -1; }
OPATCH_MIN=""; JDK_MIN=""; SPB_MARKER=""
if $LIBCSV; then
    OPATCH_MIN="$(_cv OPATCH_VERSION_MIN)"; JDK_MIN="$(_cv JDK_VERSION_MIN)"; SPB_MARKER="$(_cv WLS_SPB_MARKER_PATCH)"
    _pc="$(_cv PATCH_CYCLE)"; [ -n "$_pc" ] && CYCLE="$_pc ($(_cv PATCH_CYCLE_DATE))"
fi
# rows: patch;platform;file_regexp;required;step;description[;dir;sha256]
grep -vE '^[[:space:]]*(#|$)|^patch;' "$PCSV" | awk -F';' '!seen[$1 ";" $5]++ {print $1 ";" $4 ";" $5 ";" $6}' > "$CSV/.rows"
[ -z "$OPATCH_MIN" ] && OPATCH_MIN="$(grep -i 'opatch' "$CSV/.rows" | grep -oE 'OPatch [0-9.]+' | head -1 | cut -d' ' -f2)"
# superseded (old -> new): conf comments "# old ... -> superseded by new" + 06- SUPERSEDES map
{ sed -n 's/^#[[:space:]]*\([0-9]\{7,\}\).*superseded by \([0-9]\{7,\}\).*/\1;\2/p' "$CONF" 2>/dev/null
  sed -n 's/^[[:space:]]*\[\([0-9]\{7,\}\)\]=\([0-9]\{7,\}\).*/\2;\1/p' "$REPO/09-Install/06-oracle_patch_forms_reports.sh" 2>/dev/null
} | sort -u > "$CSV/.superseded"
say "release ${FMW_VER:-?} -> patch list $CSV_NAME ($CYCLE)"

# =============================================================================
# 3. environment / components
# =============================================================================
B 31_opatch.txt "opatch lspatches" | grep -E '^[0-9]+;' > "$CSV/.lsp"
N_LSP="$(wc -l < "$CSV/.lsp")"
[ "$N_LSP" -eq 0 ] && f_add WARN "OPatch" "no patch list in the collection (opatch lspatches failed?)" "check 31_opatch.txt - OPatch must run as the software owner"
COMPS="$(B 30_inventory.txt "Reports / Forms components in comps.xml (OPatch view)")"
HAS_FORMS=false; printf '%s' "$COMPS" | grep -q 'oracle\.developer\.forms\.runtime\|oracle\.forms' && HAS_FORMS=true
B 30_inventory.txt "Forms / Reports binaries" | grep -q '/frmweb$' && HAS_FORMS=true
_rr="$(F 'Reports comps.xml / binaries')"
HAS_REPORTS=false; [ "${_rr%% *}" != "0" ] && [ -n "$_rr" ] && HAS_REPORTS=true
printf '%s' "$COMPS" | grep -q 'oracle\.reports' && HAS_REPORTS=true
_o="$(F 'OHS component in home')"; HAS_OHS=false; [ -n "$_o" ] && [ "${_o%% *}" != "0" ] && HAS_OHS=true
HAS_WEBGATE=false; [ "$(F 'WebGate in home')" = yes ] && HAS_WEBGATE=true
DBC="$(F 'DB client in home')"; HAS_DBC=false; [ -n "$DBC" ] && HAS_DBC=true
PERL="$(F 'Perl in home')"; HAS_PERL=false; [ -n "$PERL" ] && HAS_PERL=true
OPATCH_VER="$(F OPatch)"
JDK_LINE="$(F 'JDK version (.globalEnv)')"
JDK_VER="$(printf '%s' "$JDK_LINE" | grep -oE 'version "[^"]+"' | head -1 | sed 's/version "//; s/"//')"
_jnorm() { printf '%s' "$1" | sed 's/^1\.8\.0_/8.0./'; }       # 1.8.0_511 -> 8.0.511
LIBFACT="$(F 'IHateWeblogic library')"
yn() { $1 && printf yes || printf no; }

{
    ev "Products (inventory/registry.xml)" "$(printf '%s' "$PV" | tr ';' '\n' | grep -v '^OPatch' | sed '/^$/d' | paste -sd, -)" "selects the patch list: $CSV_NAME"
    ev "OPatch" "${OPATCH_VER:--}" "$( [ -n "$OPATCH_MIN" ] && { vge "${OPATCH_VER:-0}" "$OPATCH_MIN" && printf 'ok (minimum %s)' "$OPATCH_MIN" || printf 'upgrade to %s first' "$OPATCH_MIN"; } || printf -- '-')"
    ev "Installed patches" "$N_LSP" "section 3"
    ev "Forms / Reports in the home" "Forms $(yn $HAS_FORMS), Reports $(yn $HAS_REPORTS) ($_rr)" "Forms / Reports patches only for the installed product"
    [ -n "$(F '!! Reports NOT REGISTERED')" ] && ev "!! Reports registration" "$(F '!! Reports NOT REGISTERED')" "OPatch never patches unregistered Reports binaries - clarify with Oracle Support"
    ev "OHS / WebGate in the home" "OHS $(yn $HAS_OHS) ($_o), WebGate $(yn $HAS_WEBGATE)" "OHS / WebGate bundle patches apply also when OHS is not used (binaries in the home)"
    ev "DB client / Perl in the home" "${DBC:-none} / ${PERL:-none}" "DB client update and Perl SPU of the cycle"
    ev "Server JDK (.globalEnv, used by OPatch)" "$(F 'JDK of OPatch (.globalEnv)') - ${JDK_VER:--}" "section 5"
    ev "Domain" "$(F Domain) $(F 'Domain version (config.xml)') - servers: $(F 'Servers (config.xml)')" "running at the collection: $(F 'WLS servers running')"
    ev "Processes outside ORACLE_HOME / JDK" "$(F 'Processes outside ORACLE_HOME / JDK')" "a second home in use? patch it too"
    ev "OS / glibc" "${SRC_OS:--} / ${SRC_GLIBC:--}" "$( [ "$REL" = 12 ] && vge "${SRC_GLIBC:-0}" 2.34 && printf 'glibc >= 2.34: Forms relink note (KB873815) - section 9' || printf -- '-')"
    ev "IHateWeblogic library" "${LIBFACT:-unknown (collector older than 2026-11-05.3)}" "decides route B (section 8.3)"
} | M > "$CSV/environment.csv"
md "Check;Result;Consequence" environment < "$CSV/environment.csv"

# =============================================================================
# 4. patch list against the environment
# =============================================================================
_area() {   # DESC STEP -> area (library roles first, then the description)
    local d; d="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$2" in
        opatch) printf 'OPatch'; return ;;   spb) printf 'WLS Stack Patch Bundle'; return ;;
        jdk) printf 'Server JDK'; return ;;  client_jdk|client) printf 'Client JRE'; return ;;
        cvu) printf 'CVU (local RCU DB)'; return ;; apex) printf 'APEX'; return ;;
    esac
    case "$d" in
        *"stack patch bundle"*)                    printf 'WLS Stack Patch Bundle' ;;
        *opatch*)                                  printf 'OPatch' ;;
        *"forms client"*|*"jre "*client*|*client*jre*) printf 'Client JRE' ;;
        *libovd*|*adf*|*owsm*|*opss*|*ums*|*oamclient*|*webcenter*|*"fmw control"*|*coherence*) printf 'FMW Infrastructure' ;;
        jdk*|jre*|"oracle jdk"*|"java "*)          printf 'Server JDK' ;;
        *webgate*)                                 printf 'WebGate' ;;
        *ohs*|*libdms*|*libiau*)                   printf 'OHS' ;;
        *perl*)                                    printf 'Perl' ;;
        *"db client"*|*dbclient*)                  printf 'DB client' ;;
        *forms*)                                   printf 'Forms' ;;
        *reports*)                                 printf 'Reports' ;;
        *cvu*)                                     printf 'CVU (local RCU DB)' ;;
        *apex*)                                    printf 'APEX' ;;
        *)                                         printf 'FMW Infrastructure' ;;
    esac
}
_inst() { grep -qE "^$1;|\\(Patch $1\\)" "$CSV/.lsp"; }
: > "$CSV/patchlist.csv"; : > "$CSV/.missing"
N_APPLY=0; N_INST=0; N_MISS=0; N_NN=0
while IFS=';' read -r nr req step desc; do
    a="$(_area "$desc" "$step")"; app=yes; why=""
    case "$a" in
        Forms)     $HAS_FORMS   || { app=no; why="Forms not installed"; } ;;
        Reports)   $HAS_REPORTS || { app=no; why="Reports not installed"; } ;;
        OHS)       $HAS_OHS     || { app=no; why="no OHS in the home"; } ;;
        WebGate)   $HAS_WEBGATE || { app=no; why="no WebGate in the home"; } ;;
        "DB client") $HAS_DBC   || { app=no; why="no DB client in the home"; } ;;
        Perl)      $HAS_PERL    || { app=no; why="no Perl in the home"; } ;;
        "Client JRE") app=client ;;
        "CVU (local RCU DB)"|APEX) app=no; why="only with a local RCU DB / APEX" ;;
    esac
    [ "$req" = optional ] && [ "$app" = yes ] && [ "$a" != OPatch ] && { app=optional; why="see the description"; }
    ins=no
    case "$a" in
        OPatch) t="$(printf '%s' "$desc" | grep -oE 'OPatch [0-9.]+' | head -1 | cut -d' ' -f2)"
                [ -n "$t" ] && vge "${OPATCH_VER:-0}" "$t" && ins="yes ($OPATCH_VER)"; app=yes ;;
        "Server JDK")
                t="$(printf '%s' "$desc" | grep -oE '8u[0-9]+' | head -1 | sed 's/^8u/8.0./')"
                [ -z "$t" ] && t="$(printf '%s' "$desc" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)*' | head -1)"
                [ -z "$t" ] && t="$JDK_MIN"
                [ -n "$t" ] && [ -n "$JDK_VER" ] && vge "$(_jnorm "$JDK_VER")" "$t" && ins="yes ($JDK_VER)" ;;
        "Client JRE") ins="-" ;;
        *)      if _inst "$nr" || { [ "$a" = "WLS Stack Patch Bundle" ] && [ -n "$SPB_MARKER" ] && _inst "$SPB_MARKER"; }; then ins=yes; fi ;;
    esac
    case "$app:$ins" in
        client:*)   act="client software distribution (section 5)" ;;
        no:yes*|optional:yes*) act="installed"; [ "$app" = no ] && N_NN=$((N_NN+1)) ;;
        no:*)       act="not needed - $why"; N_NN=$((N_NN+1)) ;;
        optional:*) act="optional - $why"; N_NN=$((N_NN+1)) ;;
        yes:yes*)   act="installed"; N_APPLY=$((N_APPLY+1)); N_INST=$((N_INST+1)) ;;
        yes:*)      act="**install**"; N_APPLY=$((N_APPLY+1)); N_MISS=$((N_MISS+1))
                    printf '%s;%s;%s;%s\n' "$step" "$nr" "$a" "$desc" >> "$CSV/.missing" ;;
    esac
    printf '%s;%s;%s;%s;%s;%s\n' "$nr" "$a" "$desc" "$app" "$ins" "$act"
done < "$CSV/.rows" | M > "$CSV/patchlist.csv"
# counters were set in a subshell - count again from the table
N_APPLY="$(awk -F';' '$4=="yes"' "$CSV/patchlist.csv" | wc -l)"
N_INST="$(awk -F';' '$4=="yes" && $6=="installed"' "$CSV/patchlist.csv" | wc -l)"
N_MISS="$(awk -F';' '$6=="**install**"' "$CSV/patchlist.csv" | wc -l)"
N_NN="$(awk -F';' '$4=="no" || $4=="optional"' "$CSV/patchlist.csv" | wc -l)"
md "Patch;area;description;applies;installed;action" patchlist < "$CSV/patchlist.csv"
x="$(awk -F';' '$6=="**install**" {print $1 " (" $2 ")"}' "$CSV/patchlist.csv" | paste -sd, -)"
[ -n "$x" ] && f_add WARN "Patch level" "$N_MISS patch(es) of $CYCLE missing: $x" "install in the order of section 8.1"
[ "$N_MISS" -eq 0 ] && [ "$N_APPLY" -gt 0 ] && f_add INFO "Patch level" "all $N_APPLY applicable patches of $CYCLE are installed" "next cycle: new collection + analysis"

# =============================================================================
# 5. installed patches
# =============================================================================
# patches applied together with the SPB (napply of the SPB patch list)
B 35_opatch_prereq.txt "Last patch runs (apply / napply / rollback) with result" \
    | awk -F' [|] ' '$2 ~ /napply/ && $2 !~ /-report/ && $3 ~ /successfully applied/ { t=$3; sub(/.*Patches[[:space:]]+/, "", t); sub(/[[:space:]].*/, "", t); gsub(/,/, "\n", t); print t }' \
    | sort -u > "$CSV/.spbset"
_key() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | sed 's/([^)]*)//g' | awk '{print $1 " " $2}'; }
cut -d';' -f1,4 "$CSV/.rows" | while IFS=';' read -r n dsc; do printf '%s;%s\n' "$(_key "$dsc")" "$n"; done > "$CSV/.keys"
while IFS=';' read -r nr desc; do
    if cut -d';' -f1 "$CSV/.rows" | grep -qx "$nr" || { [ -n "$SPB_MARKER" ] && [ "$nr" = "$SPB_MARKER" ]; } \
       || grep -qE "\\(Patch ($(cut -d';' -f1 "$CSV/.rows" | paste -sd'|' -))\\)" <<< "$desc"; then
        st="current cycle"
    elif r="$(awk -F';' -v n="$nr" '$1==n {print $2; exit}' "$CSV/.superseded")" && [ -n "$r" ]; then
        st="older version - replaced by $r"
    elif grep -qx "$nr" "$CSV/.spbset"; then
        st="part of the SPB"
    elif printf '%s' "$desc" | grep -qiE 'STACK PATCH BUNDLE|WLS PATCH SET UPDATE|Coherence|Thirdparty|JDBC[0-9.]* BUNDLE|^RDA |FMW DBCLIENT|DATABASE RELEASE UPDATE'; then
        st="part of the SPB"
    elif r="$(awk -F';' -v k="$(_key "$desc")" '$1==k {print $2; exit}' "$CSV/.keys")" && [ -n "$r" ] && [ "$(_key "$desc")" != "ONE-OFF " ]; then
        st="older version - replaced by $r"
    else
        st="not in the cycle list - check"
    fi
    printf '%s;%s;%s\n' "$nr" "$desc" "$st"
done < "$CSV/.lsp" | M > "$CSV/installed.csv"
md "Patch;description (opatch lspatches);status" installed < "$CSV/installed.csv"
x="$(awk -F';' '$3 ~ /^not in the cycle/ {print $1 " " $2}' "$CSV/installed.csv" | paste -sd, -)"
[ -n "$x" ] && f_add HINT "Patch level" "installed patches outside the cycle list: $x" "check each README: still needed, conflicting with the cycle patches, or superseded"
x="$(awk -F';' '$3 ~ /^older version/ {print $1}' "$CSV/installed.csv" | paste -sd, -)"
[ -n "$x" ] && f_add INFO "Patch level" "older versions of cycle patches installed: $x" "the cycle patch replaces them (OPatch rolls back the old one or the cookbook says so)"

# =============================================================================
# 6. Java
# =============================================================================
jt="$(awk -F';' '$2=="Server JDK" {print $3 " -> " $5; exit}' "$CSV/patchlist.csv")"
BJ="$(F 'Bundled JDK (oracle_common/jdk)')"
{
    ev "Server JDK (.globalEnv)" "$(F 'JDK of OPatch (.globalEnv)') - ${JDK_VER:--}" "cycle: ${jt:--}"
    ev "Bundled JDK (oracle_common/jdk)" "${BJ:--}" "used by the Reports engines and the Reports / Forms tools (reports.sh) - not updated by the CPU"
    ev "JDKs of the running processes" "$(F 'JDKs of running processes')" "every server should run on the server JDK (JAVA_HOME of the domain)"
    if [ -f "$ROOT/44_forms_client.txt" ]; then
        ev "Forms client: JNLP java version" "$(B 44_forms_client.txt "JNLP j2se / java versions" | grep -oE '(java|j2se) version="[^"]*"' | sort -u | paste -sd, -)" "client JRE / FSAL = software distribution of the clients"
        ev "Forms client: formsweb.cfg Java keys" "$(B 44_forms_client.txt "formsweb.cfg Java plug-in / client keys" | sed 's/^[^:]*:[0-9]*://' | sort -u | head -6 | paste -sd, -)" "-"
        ev "Forms client: frmsal.jar" "$(B 44_forms_client.txt "FSAL / client jars (frmsal.jar)" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]+ [^ ]*frmsal[^ ]*' | head -1)" "new frmsal.jar with the Forms patch - clients get it at the next start"
    else
        nc_add "Forms client JRE" "44_forms_client.txt missing (collector older than 2026-11-05.1)"
    fi
} | M > "$CSV/java.csv"
md "Check;Result;Consequence" java < "$CSV/java.csv"
if [ -n "$JDK_VER" ] && ! awk -F';' '$2=="Server JDK" && $5 ~ /^yes/ {f=1} END {exit !f}' "$CSV/patchlist.csv"; then
    f_add WARN "Java" "server JDK $JDK_VER older than the JDK of $CYCLE" "install the JDK patch of section 4 (new JDK directory, JDK link repointed)"
fi
# processes on the bundled JDK: names from the process list (Reports engine / WLS server / other)
BJP="$(grep -E "[[:space:]]$SRC_OH/oracle_common/jdk/(jre/)?bin/java " "$ROOT/50_processes.txt" 2>/dev/null | grep -v '\\_' \
       | awk '{ n="process " $1 } /-Dcomponent\.path=/ { m=$0; sub(/.*-Dcomponent\.path=/, "", m); sub(/ .*/, "", m); n="Reports engine of " m }
              /-Dweblogic\.Name=/ { m=$0; sub(/.*-Dweblogic\.Name=/, "", m); sub(/ .*/, "", m); n="WLS server " m }
              /weblogic\.NodeManager/ { n="Node Manager" } { print n }' | sort -u | paste -sd, -)"
if [ -n "$BJP" ]; then
    f_add WARN "Java" "processes run on the bundled JDK oracle_common/jdk ($BJ): $BJP" "known product gap: reports.sh / rwengine.sh always start the Reports engines with oracle_common/jdk, the server JDK patch does not reach them and the CPU has no patch for it - ask Oracle Support for the supported way (SR), meanwhile no other use of that JDK"
    printf '%s;%s;%s\n' "Processes on the bundled JDK" "$BJP" "not updated by the server JDK patch - see section 9" | M >> "$CSV/java.csv"
    md "Check;Result;Consequence" java < "$CSV/java.csv"
fi
[ -z "$BJP" ] && case "$BJ" in *'"17.'*|*'"1.8'*|*'"11.'*) f_add HINT "Java" "bundled JDK oracle_common/jdk: $BJ" "no running process used it at the collection - the Reports engines and tools use it when they run (reports.sh), not updated by the CPU" ;; esac

# =============================================================================
# 7. other homes, web tier
# =============================================================================
if [ -f "$ROOT/34_other_homes.txt" ]; then
    awk '/^### opatch lspatches -oh / { h=$0; sub(/^### opatch lspatches -oh /, "", h); n[h]=0; ord[++k]=h; next }
         /^### .*: no OPatch/ { h=$0; sub(/^### /, "", h); sub(/: no OPatch.*/, "", h); no[h]=1; ord[++k]=h; next }
         /^### / { next }
         h != "" && /^[0-9]+;/ { n[h]++; if (ru[h]=="" && $0 ~ /Release Update|BUNDLE PATCH|Bundle Patch/) { r=$0; sub(/^[0-9]+;/, "", r); ru[h]=r } }
         END { for (i=1; i<=k; i++) { h=ord[i]
                 note = (h ~ /agent/ ? "Oracle management agent - updated by its own agent update (OEM / OCI)" : (h ~ /db_?home|dbhome|\/db$|product\/(1[89]|2[0-9])/ ? "database home - DB Release Update of its own cycle" : (h ~ /ohs|webgate|webtier|web_tier/ ? "web tier home - OHS / WebGate bundle of the cycle" : "check")))
                 printf "%s;%s;%s;%s\n", h, (h in no ? "no OPatch" : n[h]), (ru[h]=="" ? "-" : ru[h]), (h in no ? "no OPatch - removed or only partly deleted home? (deinstall / detach from the inventory)" : note) } }' \
        "$ROOT/34_other_homes.txt" | M > "$CSV/other_homes.csv"
    n="$(wc -l < "$CSV/other_homes.csv")"
    [ "$n" -gt 0 ] && f_add INFO "Other homes" "$n other Oracle home(s) in the inventory (section 6.1)" "patch each home on its own; remove unused homes (deinstall) - every home is an attack surface"
else
    : > "$CSV/other_homes.csv"; nc_add "Other Oracle homes" "34_other_homes.txt missing (collector older than 2026-11-05.1)"
fi
md "Home;patches;newest RU / bundle;note" other_homes < "$CSV/other_homes.csv"

WT_FACT="$(F 'Web tier')"
awk '/^### Routing \(/ {on=1; next} on && /^$/ {exit} on && /^(nginx|apache|ohs);/' "$ROOT/61_webserver.txt" 2>/dev/null > "$CSV/.wt"
MODWL="$(B 61_webserver.txt "WebLogic proxy plug-in for Apache (mod_wl*)" | grep -oE '/[^ ]*mod_wl[^ ]*\.so' | sort -u | paste -sd, -)"
if [ -s "$CSV/.wt" ]; then
    _wl_on="$(grep -E '^[[:space:]]*LoadModule[[:space:]]+weblogic_module' "$ROOT/61_webserver.txt" 2>/dev/null | head -1)"
    _wl_off="$(grep -E '^[[:space:]]*#[[:space:]]*LoadModule[[:space:]]+weblogic_module' "$ROOT/61_webserver.txt" 2>/dev/null | head -1)"
    _px="$(grep -ciE '^[[:space:]]*ProxyPass[[:space:]]' "$ROOT/61_webserver.txt" 2>/dev/null)"
    [ -z "$MODWL" ] && [ -n "$_wl_on" ] && MODWL="$(printf '%s' "$_wl_on" | awk '{print $3}')"
    APNOTE="$( if [ -n "$MODWL" ]; then printf ' + WebLogic Proxy Plug-In %s (KA1182 tab Proxy Plug-In)' "$MODWL"
               elif [ -n "$_wl_off" ]; then printf ' - WebLogic Proxy Plug-In only commented out (not loaded)%s' "$( [ "${_px:-0}" -gt 0 ] && printf ', routes via mod_proxy')"
               elif [ "${_px:-0}" -gt 0 ]; then printf ' - routes via mod_proxy, no WebLogic plug-in'
               else printf ' - check for the WebLogic Proxy Plug-In'; fi)"
    awk -F';' -v oh="$SRC_OH" -v dh="$SRC_DH" -v apn="$APNOTE" '
        { k=$1 ";" $2; if (!(k in seen)) { seen[k]=1; ord[++n]=k }
          if ($5=="yes") { m=split($3, L, ","); for (j=1; j<=m; j++) if (!((k, L[j]) in tl)) { tl[k, L[j]]=1; tls[k]=tls[k] (tls[k]=="" ? "" : ",") L[j] } }
          if ($8 ~ /:[0-9]/ && $8 !~ /^(redirect|static) /) wl[k]++ }
        END { for (i=1; i<=n; i++) { k=ord[i]; split(k, a, ";")
                if (a[1]=="nginx") note="OS package (dnf update nginx) - not part of the Oracle CPU"
                else if (a[1]=="apache") note="OS package httpd" apn
                else if (index(a[2], oh "/") == 1 || (dh != "" && index(a[2], dh "/") == 1)) note="OHS of this domain / home - OHS bundle of section 4"
                else note="OHS outside this home - OHS bundle of the cycle for that home (section 6.1)"
                printf "%s;%s;%s;%s;%s\n", a[1], a[2], (tls[k]=="" ? "-" : tls[k]), wl[k]+0, note } }' "$CSV/.wt" | M > "$CSV/web_tier.csv"
    WT_INFO="Web servers found at the collection: ${WT_FACT:-see table}. The web tier is patched with its own packages / patches."
    if grep -q '^apache;' "$CSV/web_tier.csv"; then
        if [ -n "$MODWL" ]; then f_add HINT "Web tier" "Apache httpd in front with the WebLogic Proxy Plug-In ($MODWL)" "patch httpd with the OS; the Proxy Plug-In has its own patches (KA1182 tab Proxy Plug-In)"
        else f_add INFO "Web tier" "Apache httpd in front$APNOTE" "patch httpd with the OS (dnf); no Oracle plug-in to patch"; fi
    fi
    grep -q 'OHS outside this home' "$CSV/web_tier.csv" && f_add HINT "Web tier" "OHS outside the Forms & Reports home" "patch that home with the OHS bundle of the cycle (own lspatches in section 6.1)"
    grep -q '^nginx;' "$CSV/web_tier.csv" && f_add INFO "Web tier" "Nginx in front" "OS updates (dnf) - not part of the Oracle CPU"
else
    : > "$CSV/web_tier.csv"
    WT_INFO="${WT_FACT:+Web servers: $WT_FACT. }No routing table in this collection (collector older than 2026-11-05.2)."
    nc_add "Web tier patch notes (Apache Proxy Plug-In, separate OHS)" "61_webserver.txt without routing table - fresh collection"
fi
md "Web server;configuration;HTTPS listeners;routes to WebLogic;patch note" web_tier < "$CSV/web_tier.csv"

# =============================================================================
# 8. OPatch prerequisites, last runs
# =============================================================================
_gb() { printf '%s' "$1" | awk '{v=$1; u=substr(v, length(v)); n=v+0; if (u=="T") n*=1024; else if (u=="M") n/=1024; else if (u=="K") n/=1048576; printf "%d", n}'; }
FREE="$(F 'Free space of the home')"; PST="$(F '.patch_storage')"
LOCKS="$(B 35_opatch_prereq.txt "Inventory locks" | awk 'NF>=9 && $NF != "." && $NF != ".." {print $NF}' | paste -sd, -)"
NOTOWN="$(B 35_opatch_prereq.txt "Files in the home NOT owned by this user (first 20)" | sed '/^$/d')"
TMPF="$(B 35_opatch_prereq.txt "Free space: home / inventory / /tmp" | awk 'NR>1 && $NF ~ /^\// {v=$4} END {print v}')"
{
    ev "OPatch version" "${OPATCH_VER:--}" "$( [ -n "$OPATCH_MIN" ] && printf 'minimum of the cycle: %s' "$OPATCH_MIN" || printf -- '-')"
    ev "Free space of the home" "${FREE:--}" "OPatch needs space for the backup of every patched file (.patch_storage) - at least 10 GB"
    ev "Free space /tmp" "${TMPF:--}" "SPB / OPatch unpack below /tmp (or -Djava.io.tmpdir)"
    ev "Rollback storage .patch_storage" "${PST:--}" "grows with every patch - clean up after a successful cycle (opatch util deleteinactivepatches)"
    ev "Inventory lock files" "${LOCKS:-none}" "inventory.lock alone is normal; other lock files = an OPatch run still active or aborted"
    ev "Files not owned by the software owner" "$( [ -n "$NOTOWN" ] && printf '%s file(s): %s' "$(printf '%s\n' "$NOTOWN" | wc -l)" "$(printf '%s\n' "$NOTOWN" | head -3 | paste -sd, -)" || printf none)" "OPatch fails when it must replace such a file"
    ev "Running servers" "$(F 'WLS servers running')" "all servers, Node Manager, Reports and Forms processes are stopped for OPatch"
} | M > "$CSV/prereq.csv"
md "Check;Result;Consequence" prereq < "$CSV/prereq.csv"
[ -n "$OPATCH_MIN" ] && [ -n "$OPATCH_VER" ] && ! vge "$OPATCH_VER" "$OPATCH_MIN" && \
    f_add WARN "OPatch" "OPatch $OPATCH_VER below the minimum $OPATCH_MIN of the cycle" "upgrade OPatch first (patch 28186730, opatch_generic.jar)"
fg="$(_gb "${FREE%% *}")"; [ -n "$FREE" ] && [ "${fg:-0}" -lt 10 ] && f_add WARN "OPatch" "only $FREE in the file system of the home" "at least 10 GB free before patching"
pg="$(_gb "${PST:-0}")"; [ "${pg:-0}" -ge 5 ] && f_add HINT "OPatch" ".patch_storage is $PST" "after a successful cycle: opatch util deleteinactivepatches (keeps what a rollback needs)"
x="$(printf '%s' "$LOCKS" | tr ',' '\n' | grep -vx 'inventory.lock' | sed '/^$/d' | paste -sd, -)"
[ -n "$x" ] && f_add WARN "OPatch" "lock file(s) in the central inventory: $x" "no other OPatch / installer may run - remove a stale lock only when no Oracle installer process exists"
[ -n "$NOTOWN" ] && f_add HINT "OPatch" "$(printf '%s\n' "$NOTOWN" | wc -l) file(s) in the home not owned by the software owner (e.g. $(printf '%s\n' "$NOTOWN" | head -1))" "chown to the software owner if OPatch has to replace them"
[ -n "$(F '!! Reports NOT REGISTERED')" ] && f_add WARN "Reports" "Reports binaries in the home but no oracle.reports component in comps.xml" "OPatch would skip every Reports patch - clarify with Oracle Support before patching"
x="$(F 'Processes outside ORACLE_HOME / JDK')"
[ -n "$x" ] && [ "$x" != none ] && f_add HINT "Processes" "FMW processes run from outside the home / server JDK: $x" "find the second home - patch it too or stop using it"
[ -n "$(F 'WLS servers running')" ] && f_add INFO "Downtime" "servers running at the collection: $(F 'WLS servers running')" "plan a maintenance window (section 8)"
if [ "$REL" = 12 ] && $HAS_FORMS && vge "${SRC_GLIBC:-0}" 2.34; then
    f_add HINT "Forms" "Forms 12c on glibc $SRC_GLIBC" "relink of frmweb can fail after the Reports QPR (libzrc.so) - Forms QPR before Reports QPR, KB873815 (cookbook)"
fi

B 35_opatch_prereq.txt "Last patch runs (apply / napply / rollback) with result" | awk -F' [|] ' 'NF>=2 {
        log_=$1; c=$2; gsub(/'"'"'/, "", c); split(c, w, " "); cmd=w[1]
        if (match(c, /-id [0-9]+/)) cmd=cmd " " substr(c, RSTART, RLENGTH)
        if (c ~ /-report/) cmd=cmd " -report"
        r=$3; if (r ~ /SEVERE|failed|stopped/) res="FAILED: " substr(r, 1, 140); else if (r ~ /success/) { gsub(/\[INFO\][[:space:]]*/, "", r); res="ok: " substr(r, 1, 100) } else res="no result line (see the log)"
        d=log_; sub(/^opatch/, "", d); sub(/_[0-9]+\.log$/, "", d)
        printf "%s;%s;%s\n", d, cmd, res }' | M > "$CSV/runs.csv"
md "Run (log time);command;result" runs < "$CSV/runs.csv"
if [ -s "$CSV/runs.csv" ]; then
    head -1 "$CSV/runs.csv" | grep -q ';FAILED' && f_add WARN "OPatch" "the last OPatch run failed ($(head -1 "$CSV/runs.csv" | cut -d';' -f1))" "solve the cause (log in cfgtoollogs/opatch) and check lspatches before the next run"
    n="$(tail -n +2 "$CSV/runs.csv" | grep -c ';FAILED')"
    [ "$n" -gt 0 ] && f_add INFO "OPatch" "$n older failed run(s) in the history" "later runs succeeded - check that the patch of that run is in lspatches"
fi
[ -f "$ROOT/32_opatch_details.txt" ] || nc_add "bug-level check (lsinventory -bugs_fixed)" "collection without --full"

# =============================================================================
# 9. route and order of work
# =============================================================================
ROUTE_B_OK=false
[ "$REL" = 14 ] && [ -n "$LIBFACT" ] && [ "$LIBFACT" != none ] && ROUTE_B_OK=true
# step -> how (library role or cookbook step number)
awk -F';' -v lib="$( $LIBCSV && printf 1 || printf 0)" '{
        a=$3; how="opatch apply"
        if (a=="OPatch") how="OPatch upgrade (opatch_generic.jar)"
        else if (a=="WLS Stack Patch Bundle") how="opatch napply (SPB, -phBaseFile)"
        else if (a=="Server JDK") how="new JDK directory, JDK link repointed"
        lib_s = ($1 ~ /^(opatch|spb|wls)$/ ? "81-patch_weblogic.sh" : ($1 ~ /^(fr_common|forms|reports|fr_optional)$/ ? "82-patch_forms_reports.sh" : ($1=="jdk" ? "80-patch_java_os.sh" : "-")))
        printf "%s;%s;%s;%s;%s\n", (lib ? lib_s : "step " $1), $2, a, $4, how }' "$CSV/.missing" | M > "$CSV/plan.csv"
md "Cookbook step / library script;patch;area;description;how" plan < "$CSV/plan.csv"
_spbm=0; grep -q ';WLS Stack Patch Bundle;' "$CSV/.missing" && _spbm=1
DOWNTIME="$( [ "$N_MISS" -eq 0 ] && printf 'none - nothing to install' || printf 'about %s minutes for %s patch(es), plus stop / start and the tests' "$((15 + 5 * N_MISS + 20 * _spbm))" "$N_MISS")"
if [ -n "$COOKBOOK" ]; then
    rel="${COOKBOOK#"$REPO"/}"
    ROUTE_A="Cookbook for this release: [\`$rel\`]($GH/$rel). Work through its steps for the patches of section 8.1 (the cookbook's first step records the state before, the last one is the rollback). The patch numbers of the cookbook and of this report come from the same patch list (\`$CSV_NAME\`)."
else
    ROUTE_A="No cookbook for release ${FMW_VER:-?} in the library yet - it is written per cycle with the patch-cycle analysis (\`10-Monitoring/patch_cycle_analysis.sh analyse --env <collection>\`)."
fi
if $ROUTE_B_OK; then
    ROUTE="B - IHateWeblogic library"
    ROUTE_B="The environment was built with the IHateWeblogic library (\`${LIBFACT%% *}\`). The scripts read the same patch list and skip what is installed:

1. \`09-Install/04-oracle_pre_download.sh --apply --mos\` – patches of the cycle into \`PATCH_STORAGE\`
2. \`07-Maintenance/backup_config.sh --apply\`
3. \`01-Run/startStop.sh stop-all --apply\`
4. \`07-Maintenance/80-patch_java_os.sh --apply\` – server JDK
5. \`07-Maintenance/81-patch_weblogic.sh --apply\` – OPatch, SPB, FMW Infrastructure
6. \`07-Maintenance/82-patch_forms_reports.sh --apply\` – Perl, OHS, WebGate, Forms, Reports
7. Forms: \`09-Install/14-oracle_setup_forms.sh --apply\` (re-activates the signed JACOB); client bundle: \`09-Install/40-oracle_forms_client_bundle.sh --apply\`
8. \`01-Run/startStop.sh start-all --apply\`
9. checks: \`09-Install/15-deploy-test-report-forms_template.sh --apply\`, \`10-Monitoring/cve_inventory.sh\`

Each script without \`--apply\` shows what it would do (details: \`07-Maintenance/README.md\` section 3)."
else
    ROUTE="A - cookbook"
    if [ "$REL" != 14 ]; then ROUTE_B="Not for this environment: the library patches Forms & Reports 14.1.2 only (here: ${FMW_VER:-unknown})."
    elif [ -z "$LIBFACT" ]; then ROUTE_B="Unknown: the collection is older than 2026-11-05.3 and does not show whether the environment was built with the library. Built with the library: steps as in \`07-Maintenance/README.md\` section 3."
    else ROUTE_B="Not for this environment: it was not built with the IHateWeblogic library – the library scripts expect its \`environment.conf\` and directory layout. Use route A."; fi
fi
if [ "$N_MISS" -eq 0 ]; then
    SUMMARY_TEXT="The environment is on the patch level of **$CYCLE** – nothing to install. Check the findings in section 9."
else
    SUMMARY_TEXT="**$N_MISS of $N_APPLY** applicable patches of **$CYCLE** are missing ($(awk -F';' '$6=="**install**" {print $2}' "$CSV/patchlist.csv" | sort | uniq -c | awk '{c=$1; $1=""; sub(/^ /, ""); printf "%s%s %s", (NR>1 ? ", " : ""), c, $0}')). Section 8.1 lists them in the order of work, section 9 what must be solved before."
fi

# =============================================================================
# 9b. traffic light (patch list only - product gaps without a patch are listed below it)
#   green  nothing missing | yellow  partly | red  nothing of the cycle / SPB missing
# =============================================================================
CYC_SHORT="${CYCLE%% (*}"
if [ "$N_MISS" -eq 0 ] && [ "$N_APPLY" -gt 0 ]; then
    PL=green; PTXT="Requirements of $CYC_SHORT met"
elif [ "$N_INST" -eq 0 ] || grep -q ';WLS Stack Patch Bundle;' "$CSV/.missing"; then
    PL=red; PTXT="Not on $CYC_SHORT – $N_MISS of $N_APPLY patches missing$(grep -q ';WLS Stack Patch Bundle;' "$CSV/.missing" && printf ' (incl. the WebLogic Stack Patch Bundle)')"
else
    PL=yellow; PTXT="Partly patched – $N_MISS of $N_APPLY patches of $CYC_SHORT missing"
fi
[ "$N_APPLY" -eq 0 ] && { PL=none; PTXT="no applicable patch list"; }
# points next to the light: WARN findings (not the patch list itself), max. 3
POINTS="$(awk -F';' '$1=="WARN" && $2 != "Patch level" {print "- " $2 ": " $3}' "$FIND" | cut -c1-230 | head -3)"
[ -n "$(awk -F';' '$1=="WARN" && $2=="Java" && $3 ~ /bundled JDK/' "$FIND")" ] && \
    POINTS="$(printf '%s\n' "$POINTS" | sed 's/^- Java: processes run on the bundled JDK/- Known product gap (no patch in the cycle): processes run on the bundled JDK/')"
[ -z "$POINTS" ] && POINTS="- no further point that must be solved (section 9)"
printf 'PATCH_LIGHT=%s\nPATCH_TEXT=%s\nPATCH_MISSING=%s\nPATCH_CYCLE=%s\nPATCH_DATE=%s\n' "$PL" "$PTXT" "$N_MISS" "$CYC_SHORT" "$DATE" > "$CSV/status.env"

# =============================================================================
# 10. findings, fill the template
# =============================================================================
awk -F';' 'BEGIN{o["WARN"]=1; o["HINT"]=2; o["INFO"]=3} {print o[$1] ";" $0}' "$FIND" | sort -t';' -k1,1n -s | cut -d';' -f2- | M > "$CSV/findings_sorted.csv"
md "Severity;area;finding;recommendation" findings < "$CSV/findings_sorted.csv"
md "Rule;reason" not_checked < "$NOTCHK"

export IHWP_CUSTOMER="$CUST" IHWP_DATE="$DATE" IHWP_SRC_HOST="${SRC_HOST:--}" \
    IHWP_SRC_ORACLE_HOME="${SRC_OH:--}" IHWP_SRC_DOMAIN_HOME="${SRC_DH:--}" IHWP_SRC_FMW_VERSION="${FMW_VER:--}" \
    IHWP_SRC_OS="${SRC_OS:--}" IHWP_SRC_GLIBC="${SRC_GLIBC:--}" \
    IHWP_COLLECT_FILE="$(basename "$IN")" IHWP_COLLECT_VERSION="${COL_VER:-unknown}" IHWP_COLLECT_DATE="${COL_DATE:--}" \
    IHWP_CYCLE="$CYCLE" IHWP_CSV_NAME="$CSV_NAME" IHWP_ANALYSE_VERSION="$VERSION" IHWP_LIB_VERSION="$(ihwt_lib_version)" \
    IHWP_N_APPLY="$N_APPLY" IHWP_N_INSTALLED="$N_INST" IHWP_N_MISSING="$N_MISS" IHWP_N_NOT_NEEDED="$N_NN" \
    IHWP_N_LSPATCHES="$N_LSP" IHWP_N_WARN="$(cnt '^WARN;' "$FIND")" IHWP_N_HINT="$(cnt '^HINT;' "$FIND")" \
    IHWP_N_INFO="$(cnt '^INFO;' "$FIND")" IHWP_ROUTE="$ROUTE" IHWP_SUMMARY_TEXT="$SUMMARY_TEXT" \
    IHWP_LIGHT="$(ihwt_light_md "$PL")" IHWP_LIGHT_TEXT="$PTXT" IHWP_LIGHT_POINTS="$(printf '%s' "$POINTS" | M)" \
    IHWP_WT_INFO="$WT_INFO" IHWP_DOWNTIME="$DOWNTIME" IHWP_ROUTE_A="$ROUTE_A" IHWP_ROUTE_B="$ROUTE_B"
awk -v mddir="$MD" '
    /^<!-- BLOCK:[a-z_]+ -->$/ { b=$0; sub(/^<!-- BLOCK:/,"",b); sub(/ -->$/,"",b)
        f=mddir "/" b ".md"; if ((getline l < f) > 0) { print l; while ((getline l < f) > 0) print l; close(f) } else print "_none found_"
        next }
    { while (match($0, /\{\{[A-Z_]+\}\}/)) { k=substr($0, RSTART+2, RLENGTH-4); v=ENVIRON["IHWP_" k]
          $0 = substr($0, 1, RSTART-1) v substr($0, RSTART+RLENGTH) }
      print }' "$TEMPLATE" > "$REPORT.tmp"
ihwt_report_secret_check "$REPORT.tmp" || exit 1
mv -f "$REPORT.tmp" "$REPORT"
rm -rf "${MD:?}" "$CSV"/.[a-z]*

say "Report  : $REPORT"
say "Patches : $N_MISS missing of $N_APPLY applicable ($CYCLE), route $ROUTE - light: $PL"
say "Findings: $IHWP_N_WARN WARN, $IHWP_N_HINT HINT, $IHWP_N_INFO INFO"
say "Customer data - never commit it to git (run dir is git-ignored)."
exit 0
