#!/bin/bash
# =============================================================================
# Script   : get_all_logs.sh
# Purpose  : Inventory all WebLogic/Reports/Forms log files with size, age and status
# Call     : ./get_all_logs.sh
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
    fname="$(basename "$file")"

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
# Lists all log/out files in dir grouped by type. Warns on threshold violations.
_scan_log_dir() {
    local label="$1"
    local dir="$2"
    local maxdepth="${3:-2}"

    section "$label"

    if [ ! -d "$dir" ]; then
        info "Directory not found – $dir"
        printf "\n" | tee -a "${LOG_FILE:-/dev/null}"
        return
    fi

    # Column header
    printf "  \033[1m%-50s %9s  %-16s  %s\033[0m\n" \
        "File" "Size" "Modified" "Status" \
        | tee -a "${LOG_FILE:-/dev/null}"
    printLine

    local found=0

    # Active logs: *.log, *.out (exact suffix, no numeric extension)
    while IFS= read -r -d '' f; do
        _print_log_row "$f" "active"
        found=1
    done < <(find "$dir" -maxdepth "$maxdepth" \
        \( -name "*.log" -o -name "*.out" \) \
        -type f -print0 2>/dev/null | sort -z)

    # Rotated logs: *.log followed by digits (e.g. WLS_REPORTS.log00001)
    while IFS= read -r -d '' f; do
        _print_log_row "$f" "rotated"
        found=1
    done < <(find "$dir" -maxdepth "$maxdepth" \
        -name "*.log[0-9]*" \
        -type f -print0 2>/dev/null | sort -z)

    # Compressed logs: *.gz, *.bz2
    while IFS= read -r -d '' f; do
        _print_log_row "$f" "compressed"
        found=1
    done < <(find "$dir" -maxdepth "$maxdepth" \
        \( -name "*.gz" -o -name "*.bz2" \) \
        -type f -print0 2>/dev/null | sort -z)

    if [ "$found" -eq 0 ]; then
        info "No log files found"
    fi

    # Group disk usage
    local total
    total="$(du -sh "$dir" 2>/dev/null | awk '{print $1}')"
    printf "\n  Group total: \033[1m%s\033[0m  (%s)\n\n" \
        "${total:-n/a}" "$dir" \
        | tee -a "${LOG_FILE:-/dev/null}"

    ok "Scanned: $label"
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

# --- WebLogic server logs ---
_scan_log_dir "AdminServer"  "${DOMAIN_HOME}/servers/AdminServer/logs"
_scan_log_dir "WLS_REPORTS"  "${DOMAIN_HOME}/servers/WLS_REPORTS/logs"
_scan_log_dir "WLS_FORMS"    "${DOMAIN_HOME}/servers/WLS_FORMS/logs"

# --- Reports Engine logs (instance dir varies: reptools1, repserver1, ...) ---
_REPTOOLS_BASE="${DOMAIN_HOME}/config/fmwconfig/components/ReportsToolsComponent"
_scan_log_dir "Reports Engine (ReportsToolsComponent)" "$_REPTOOLS_BASE" 4

# --- ODL diagnostic logs ---
_scan_log_dir "ODL / AdminServer"  "${DOMAIN_HOME}/diagnostics/logs/AdminServer"  3
_scan_log_dir "ODL / WLS_REPORTS"  "${DOMAIN_HOME}/diagnostics/logs/WLS_REPORTS"  3
_scan_log_dir "ODL / WLS_FORMS"    "${DOMAIN_HOME}/diagnostics/logs/WLS_FORMS"    3

# --- Node Manager ---
_scan_log_dir "Node Manager" "${DOMAIN_HOME}/nodemanager"

# =============================================================================
# Disk usage summary
# =============================================================================
section "Disk Usage Summary"
printList "servers/ (WLS logs + stdout)"       45 \
    "$(du -sh "${DOMAIN_HOME}/servers"     2>/dev/null | awk '{print $1}' || echo 'n/a')"
printList "diagnostics/ (ODL logs)"             45 \
    "$(du -sh "${DOMAIN_HOME}/diagnostics" 2>/dev/null | awk '{print $1}' || echo 'n/a')"
printList "ReportsToolsComponent/ (Engine logs)" 45 \
    "$(du -sh "$_REPTOOLS_BASE"            2>/dev/null | awk '{print $1}' || echo 'n/a')"

print_summary
exit $EXIT_CODE
