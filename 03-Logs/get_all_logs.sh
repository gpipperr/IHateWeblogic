#!/bin/bash
# =============================================================================
# Script   : get_all_logs.sh
# Purpose  : Inventory all WebLogic/Reports/Forms log files with size, age and status
#            Log directories are discovered from the domain (log_locations.sh):
#            every server under servers/*/logs incl. the standalone Reports
#            server + engines and the Reports tools, Node Manager, EM.
# Call     : ./get_all_logs.sh [--component all|reports|forms|wls|nm|em|ords|<server>]
# Requires : find, stat, date, awk, du
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 03-Logs/README.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"

LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m IHateWeblogic_lib.sh not found: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"

check_env_conf "$ENV_CONF" || exit 2
source "$ENV_CONF"
init_log
# shellcheck source=log_locations.sh
source "$SCRIPT_DIR/log_locations.sh"

COMPONENT="all"
while [ $# -gt 0 ]; do
    case "$1" in
        --component) COMPONENT="${2:?--component needs a value}"; shift 2 ;;
        --help|-h)
            printf "Usage: %s [--component all|reports|forms|wls|nm|em|ords|<server>]\n" "$(basename "$0")"
            exit 0 ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 2 ;;
    esac
done

# =============================================================================
# Thresholds – override in environment.conf if needed
# =============================================================================
LOG_MAX_SIZE_MB="${LOG_MAX_SIZE_MB:-500}"
LOG_RETAIN_DAYS="${LOG_RETAIN_DAYS:-30}"

# =============================================================================
# Helpers
# =============================================================================

_human_size() {
    awk -v b="$1" 'BEGIN {
        if      (b >= 1073741824) printf "%.1f GB", b/1073741824
        else if (b >= 1048576)   printf "%.1f MB", b/1048576
        else if (b >= 1024)      printf "%.1f KB", b/1024
        else                     printf "%d B",    b
    }'
}

_days_since_epoch() {
    echo $(( ( $(date +%s) - $1 ) / 86400 ))
}

# _print_log_row  file  type
# Prints one table row for a log file. type: active|rotated|compressed
# Issues warn() for active logs that exceed size/stale thresholds.
_print_log_row() {
    local file="$1"
    local type="${2:-active}"

    [ -f "$file" ] || return

    local size_bytes mtime days modified size_human size_mb fname
    size_bytes="$(stat -c %s "$file" 2>/dev/null || echo 0)"
    mtime="$(stat -c %Y "$file" 2>/dev/null || echo 0)"
    days="$(_days_since_epoch "$mtime")"
    modified="$(date -d "@$mtime" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
    size_human="$(_human_size "$size_bytes")"
    size_mb=$(( size_bytes / 1048576 ))
    fname="${file#"${SCAN_DIR:-}"/}"    # relative to the group dir (logs/reports/…)

    case "$type" in
        active)
            if [ "$size_mb" -ge "$LOG_MAX_SIZE_MB" ]; then
                warn "$(printf '%-50s %9s  %s  [SIZE > %d MB]' \
                    "$fname" "$size_human" "$modified" "$LOG_MAX_SIZE_MB")"
            elif [ "$days" -ge "$LOG_RETAIN_DAYS" ]; then
                warn "$(printf '%-50s %9s  %s  [STALE: %d days – rotation issue?]' \
                    "$fname" "$size_human" "$modified" "$days")"
            else
                printf "  \033[36m%-50s\033[0m %9s  %s  active\n" \
                    "$fname" "$size_human" "$modified" \
                    | tee -a "${LOG_FILE:-/dev/null}"
            fi
            ;;
        rotated)
            printf "  \033[2m%-50s %9s  %s  rotated\033[0m\n" \
                "$fname" "$size_human" "$modified" \
                | tee -a "${LOG_FILE:-/dev/null}"
            ;;
        compressed)
            printf "  \033[2m%-50s %9s  %s  compressed\033[0m\n" \
                "$fname" "$size_human" "$modified" \
                | tee -a "${LOG_FILE:-/dev/null}"
            ;;
    esac
}

# _scan_log_dir  label  dir  [maxdepth]
# Lists all log/out/trc files in dir (active, rotated, compressed).
# Group total = size of the log files, not of the whole directory.
_scan_log_dir() {
    local label="$1" dir="$2" maxdepth="${3:-2}"
    section "$label"
    if [ ! -d "$dir" ]; then
        info "Directory not found – $dir"
        return
    fi
    printList "Directory" 12 "$dir"
    printf "  \033[1m%-50s %9s  %-16s  %s\033[0m\n" "File" "Size" "Modified" "Status" \
        | tee -a "${LOG_FILE:-/dev/null}"
    printLine

    SCAN_DIR="$dir"
    local f kind found=0 bytes=0
    for kind in active rotated compressed; do
        while IFS= read -r -d '' f; do
            [ "$(ihw_log_kind "$f")" = "$kind" ] || continue
            _print_log_row "$f" "$kind"
            bytes=$(( bytes + $(stat -c %s "$f" 2>/dev/null || echo 0) ))
            found=$(( found + 1 ))
        done < <(ihw_log_find "$dir" "$maxdepth")
    done
    [ "$found" -eq 0 ] && info "No log files found"

    printf "\n  Group total: \033[1m%s\033[0m in %d file(s)\n\n" "$(_human_size "$bytes")" "$found" \
        | tee -a "${LOG_FILE:-/dev/null}"
    TOTAL_BYTES=$(( TOTAL_BYTES + bytes ))
    TOTAL_FILES=$(( TOTAL_FILES + found ))
}

# =============================================================================
# Main
# =============================================================================

printLine
section "Log File Inventory – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-22s %s\n" "Host:"          "$(_get_hostname)"       | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-22s %s\n" "DOMAIN_HOME:"   "${DOMAIN_HOME:-not set}" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-22s size > %d MB  or  not modified for > %d days\n" \
    "Warn threshold:" "$LOG_MAX_SIZE_MB" "$LOG_RETAIN_DAYS" | tee -a "${LOG_FILE:-/dev/null}"
printLine

if [ -z "${DOMAIN_HOME:-}" ]; then
    fail "DOMAIN_HOME is not set – cannot locate log directories"
    print_summary
    exit 2
fi

TOTAL_BYTES=0
TOTAL_FILES=0
NGROUPS=0
while IFS=$'\t' read -r _role _name _dir _depth; do
    _scan_log_dir "$_role – $_name" "$_dir" "$_depth"
    NGROUPS=$(( NGROUPS + 1 ))
done < <(ihw_log_groups "$COMPONENT")
[ "$NGROUPS" -eq 0 ] && warn "No log directory matches --component $COMPONENT"

# =============================================================================
# Disk usage summary
# =============================================================================
section "Disk Usage Summary"
printList "Log files (all groups above)" 40 "$(_human_size "$TOTAL_BYTES") in $TOTAL_FILES file(s)"
# Not logs, but often the real disk consumers below servers/
for _d in "$DOMAIN_HOME"/servers/*/tmp "$DOMAIN_HOME"/servers/*/adr; do
    [ -d "$_d" ] || continue
    printList "${_d#"$DOMAIN_HOME"/} (not logs)" 40 "$(du -sh "$_d" 2>/dev/null | awk '{print $1}')"
done
ok "Inventory complete: $NGROUPS log group(s)"

print_summary
exit $EXIT_CODE
