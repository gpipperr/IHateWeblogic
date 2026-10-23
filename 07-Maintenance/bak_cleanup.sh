#!/bin/bash
# =============================================================================
# Script   : bak_cleanup.sh
# Purpose  : Retention for the *.bak_<YYYYMMDD_HHMM[SS]> copies our --apply
#            scripts leave next to the Oracle files (backup_file in the lib,
#            13-, 14- …). Lists them per original file; --apply deletes all
#            but the newest N per file.
#            Never deleted, only reported: directories (OPatch.bak_* = rollback
#            of 05-), *.des3.bak_* (secret files), files of another owner.
# Call     : ./07-Maintenance/bak_cleanup.sh
#            ./07-Maintenance/bak_cleanup.sh --apply [--keep N]
# Options  : --apply   delete the copies beyond --keep (default: list only)
#            --keep N  copies kept per file (default BAK_FILES_KEEP, 3)
#            --help    Show usage
# Runs as  : oracle
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 07-Maintenance/README.md (bak_cleanup.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"

LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m Cannot find IHateWeblogic_lib.sh: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"
check_env_conf "$ENV_CONF" || exit 2
# shellcheck source=../environment.conf
source "$ENV_CONF"

init_log

APPLY=false
KEEP="${BAK_FILES_KEEP:-3}"
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)  APPLY=true ;;
        --keep)   KEEP="${2:-}"; shift ;;
        --keep=*) KEEP="${1#*=}" ;;
        --help|-h)
            printf "Usage: %s [--apply] [--keep N]\n" "$(basename "$0")"
            printf "  (none)    list the *.bak_<ts> copies per file\n"
            printf "  --apply   delete all but the newest N copies per file\n"
            printf "  --keep N  copies kept per file (default BAK_FILES_KEEP=%s)\n" "${BAK_FILES_KEEP:-3}"
            exit 0 ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 2 ;;
    esac
    shift
done
if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || [ "$KEEP" -lt 1 ]; then
    printf "\033[31mERROR\033[0m --keep needs a number >= 1 (got '%s')\n" "$KEEP" >&2
    exit 2
fi

BAK_RE='\\.bak_[0-9]{8}(_[0-9]{4,6})?$'
ME="$(id -un)"

printLine
section "*.bak_<ts> copies – keep $KEEP per file ($(date '+%Y-%m-%d %H:%M:%S'))"

# =============================================================================
# 1. Collect – "<path>\t<type>\t<owner>\t<bytes>" for every match
# =============================================================================
_home="$(getent passwd "$ME" | cut -d: -f6)"
_find() {   # _find DIR MAXDEPTH
    [ -d "$1" ] || return 0
    find "$1" -xdev ${2:+-maxdepth "$2"} -name '*.bak_[0-9]*' -printf '%p\t%y\t%u\t%s\n' 2>/dev/null
}
LIST="$(
    {
        _find "${DOMAIN_HOME:-}"
        _find "${ORACLE_HOME:-}/forms/java"
        _find "${ORACLE_HOME:-}/reports/conf"
        _find "${ORACLE_HOME:-}" 1
        _find "${ORACLE_BASE:-}/admin"
        _find "${ORACLE_BASE:-}/reports"
        _find "${ORACLE_BASE:-}/forms"
        _find "$ROOT_DIR" 1
        _find "$ROOT_DIR/00-Setup/environments" 1
        _find "$_home" 1
    } | awk -F'\t' -v re="$BAK_RE" '$1 ~ re && !seen[$1]++'
)"

if [ -z "$LIST" ]; then
    ok "No *.bak_<ts> copies found"
    printLine; print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# 2. Report what is never deleted
# =============================================================================
section "Not touched (report only)"
_skip=0
while IFS=$'\t' read -r _p _t _u _s; do
    if [ "$_t" = "d" ]; then
        info "$(printf "  %-10s %s" "directory" "$_p")"
    elif [[ "$_p" == *.des3.bak_* ]]; then
        info "$(printf "  %-10s %s" "secret" "$_p")"
    elif [ "$_u" != "$ME" ]; then
        info "$(printf "  %-10s %s (owner %s)" "owner" "$_p" "$_u")"
    else
        continue
    fi
    _skip=$(( _skip + 1 ))
done <<< "$LIST"
[ "$_skip" -eq 0 ] && ok "none"
[ "$_skip" -gt 0 ] && info "  directories: OPatch / inventory rollback of 09-Install/05- – remove by hand after a successful patch"

# =============================================================================
# 3. Group per original file, newest first – "<orig>\t<copy>\t<bytes>\t<rank>"
# =============================================================================
RANKED="$(
    printf '%s\n' "$LIST" \
        | awk -F'\t' -v me="$ME" '$2 == "f" && $3 == me && $1 !~ /\.des3\.bak_/' \
        | awk -F'\t' '{ o = $1; sub(/\.bak_[0-9_]+$/, "", o); print o "\t" $1 "\t" $4 }' \
        | sort -t$'\t' -k1,1 -k2,2r \
        | awk -F'\t' '{ n[$1]++; print $0 "\t" n[$1] }'
)"

section "Copies per file"
printf "  %-6s %-5s %-6s %8s  %s\n" "copies" "keep" "remove" "size" "file" | tee -a "${LOG_FILE:-/dev/null}"
DEL_FILES=()
_tot=0
while IFS=$'\t' read -r _orig _cnt _rm _bytes; do
    [ -z "$_orig" ] && continue
    _line="$(printf "  %-6s %-5s %-6s %8s  %s" "$_cnt" "$(( _cnt < KEEP ? _cnt : KEEP ))" "$_rm" \
        "$(numfmt --to=iec "$_bytes" 2>/dev/null || printf '%s' "$_bytes")" "$_orig")"
    if [ "$_rm" -gt 0 ]; then warn "${_line#  }"; else ok "${_line#  }"; fi
    _tot=$(( _tot + _cnt ))
done < <(printf '%s\n' "$RANKED" | awk -F'\t' -v k="$KEEP" '
    $1 != "" { c[$1]++; s[$1] += $3; if ($4 > k) r[$1]++ }
    END { for (o in c) print o "\t" c[o] "\t" (r[o] + 0) "\t" s[o] }' | sort)

while IFS=$'\t' read -r _orig _copy _bytes _rank; do
    [ -n "$_copy" ] && [ "$_rank" -gt "$KEEP" ] && DEL_FILES+=("$_copy")
done <<< "$RANKED"

info "$(printf "%s copies, %s beyond --keep %s" "$_tot" "${#DEL_FILES[@]}" "$KEEP")"

# =============================================================================
# 4. Delete (--apply)
# =============================================================================
if [ "${#DEL_FILES[@]}" -eq 0 ]; then
    ok "Nothing to delete"
elif ! $APPLY; then
    info "Dry-run – delete them with: $(basename "$0") --apply${KEEP:+ --keep $KEEP}"
else
    section "Delete"
    _ok=0
    for _f in "${DEL_FILES[@]}"; do
        if rm -f -- "$_f"; then
            _ok=$(( _ok + 1 ))
        else
            fail "Cannot delete: $_f"
        fi
    done
    ok "$(printf "%s old copies deleted (newest %s per file kept)" "$_ok" "$KEEP")"
fi

printLine
print_summary
exit "$EXIT_CODE"
