#!/bin/bash
# =============================================================================
# Script   : cleanLogFiles.sh
# Purpose  : Truncate active log files and delete old rotated logs to establish
#            a clean diagnostic baseline before reproducing an issue.
# Call     : ./cleanLogFiles.sh               # dry-run: show what would be done
#            ./cleanLogFiles.sh --apply        # execute truncation + deletion
# Options  : --apply                    Execute changes (default: dry-run)
#            --retain-days N            Keep rotated logs for N days (default: LOG_RETAIN_DAYS=7)
#            --include-out              Also truncate *.out (stdout) files
# Rules    : Active logs  (*.log, *.out) → truncate -s 0  (file stays, server keeps writing)
#            Rotated logs (*.log[0-9]*) older than retain-days → delete
#            Reports Engine logs        → delete if older than retain-days (new file per run)
#            diagnostics/ and nodemanager/ → never touched (left for Oracle Support)
# WARNING  : Truncation is irreversible. Run grep_logs.sh first to capture errors.
# Requires : find, stat, truncate, du
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
# Arguments
# =============================================================================

APPLY=false
RETAIN_DAYS="${LOG_RETAIN_DAYS:-7}"
INCLUDE_OUT=false

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)        APPLY=true; shift ;;
        --retain-days)  RETAIN_DAYS="$2"; shift 2 ;;
        --include-out)  INCLUDE_OUT=true; shift ;;
        --help|-h)
            printf "Usage: %s [--apply] [--retain-days N] [--include-out]\n" \
                "$(basename "$0")"
            exit 1 ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            exit 1 ;;
    esac
done

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

# =============================================================================
# Scan – build action plan
# =============================================================================

# Plan arrays: parallel arrays of (file, action, size_bytes, age_days)
declare -a PLAN_FILE=()
declare -a PLAN_ACTION=()   # TRUNCATE | DELETE | SKIP
declare -a PLAN_REASON=()
declare -a PLAN_SIZE=()
PLAN_TRUNCATE_BYTES=0
PLAN_DELETE_BYTES=0
PLAN_SKIP_BYTES=0

# _scan_server_logs  dir
# Plans: TRUNCATE for active *.log (and *.out if INCLUDE_OUT), DELETE/SKIP for rotated.
_scan_server_logs() {
    local dir="$1"
    [ -d "$dir" ] || return

    # Active *.log files (no numeric suffix)
    while IFS= read -r -d '' f; do
        local sz
        sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
        PLAN_FILE+=("$f");    PLAN_ACTION+=("TRUNCATE")
        PLAN_REASON+=("active log – truncate in place")
        PLAN_SIZE+=("$sz")
        PLAN_TRUNCATE_BYTES=$(( PLAN_TRUNCATE_BYTES + sz ))
    done < <(find "$dir" -maxdepth 1 -name "*.log" -not -name "*.[0-9]*" \
        -type f -print0 2>/dev/null | sort -z)

    # Active *.out files
    while IFS= read -r -d '' f; do
        local sz
        sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
        if $INCLUDE_OUT; then
            PLAN_FILE+=("$f");  PLAN_ACTION+=("TRUNCATE")
            PLAN_REASON+=("stdout log – truncate in place (--include-out)")
            PLAN_SIZE+=("$sz")
            PLAN_TRUNCATE_BYTES=$(( PLAN_TRUNCATE_BYTES + sz ))
        else
            PLAN_FILE+=("$f");  PLAN_ACTION+=("SKIP")
            PLAN_REASON+=("stdout log – skipped (use --include-out to truncate)")
            PLAN_SIZE+=("$sz")
            PLAN_SKIP_BYTES=$(( PLAN_SKIP_BYTES + sz ))
        fi
    done < <(find "$dir" -maxdepth 1 -name "*.out" -type f -print0 2>/dev/null | sort -z)

    # Rotated *.log[0-9]* files
    while IFS= read -r -d '' f; do
        local sz mtime days
        sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
        mtime="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
        days="$(_days_since_epoch "$mtime")"
        if [ "$days" -ge "$RETAIN_DAYS" ]; then
            PLAN_FILE+=("$f");  PLAN_ACTION+=("DELETE")
            PLAN_REASON+=("rotated – ${days}d old, retain: ${RETAIN_DAYS}d")
            PLAN_SIZE+=("$sz")
            PLAN_DELETE_BYTES=$(( PLAN_DELETE_BYTES + sz ))
        else
            PLAN_FILE+=("$f");  PLAN_ACTION+=("SKIP")
            PLAN_REASON+=("rotated – ${days}d old, retain: ${RETAIN_DAYS}d (too recent)")
            PLAN_SIZE+=("$sz")
            PLAN_SKIP_BYTES=$(( PLAN_SKIP_BYTES + sz ))
        fi
    done < <(find "$dir" -maxdepth 1 -name "*.log[0-9]*" \
        -type f -print0 2>/dev/null | sort -z)
}

# _scan_engine_logs  dir  maxdepth
# Reports Engine creates a new *.log per run – all are candidates for deletion if old.
_scan_engine_logs() {
    local dir="$1"
    local depth="${2:-4}"
    [ -d "$dir" ] || return

    while IFS= read -r -d '' f; do
        local sz mtime days
        sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
        mtime="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
        days="$(_days_since_epoch "$mtime")"
        if [ "$days" -ge "$RETAIN_DAYS" ]; then
            PLAN_FILE+=("$f");  PLAN_ACTION+=("DELETE")
            PLAN_REASON+=("engine log – ${days}d old, retain: ${RETAIN_DAYS}d")
            PLAN_SIZE+=("$sz")
            PLAN_DELETE_BYTES=$(( PLAN_DELETE_BYTES + sz ))
        else
            PLAN_FILE+=("$f");  PLAN_ACTION+=("SKIP")
            PLAN_REASON+=("engine log – ${days}d old, retain: ${RETAIN_DAYS}d (too recent)")
            PLAN_SIZE+=("$sz")
            PLAN_SKIP_BYTES=$(( PLAN_SKIP_BYTES + sz ))
        fi
    done < <(find "$dir" -maxdepth "$depth" \
        \( -name "*.log" -o -name "*.log[0-9]*" \) \
        -type f -print0 2>/dev/null | sort -z)
}

# =============================================================================
# Build plan
# =============================================================================

printLine
section "Clean Log Files – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-22s %s\n" "DOMAIN_HOME:"    "${DOMAIN_HOME}"   | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-22s %d days\n" "Retain rotated:" "$RETAIN_DAYS" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-22s %s\n" "Truncate *.out:"  "$INCLUDE_OUT"    | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-22s %s\n" "Mode:"  "$(  $APPLY && echo 'APPLY – changes will be made' \
    || echo 'DRY-RUN – no changes')"  | tee -a "${LOG_FILE:-/dev/null}"
printLine

if [ -z "${DOMAIN_HOME:-}" ]; then
    fail "DOMAIN_HOME is not set"
    print_summary; exit 2
fi

info "Scanning log directories..."
_scan_server_logs "${DOMAIN_HOME}/servers/AdminServer/logs"
_scan_server_logs "${DOMAIN_HOME}/servers/WLS_REPORTS/logs"
_scan_server_logs "${DOMAIN_HOME}/servers/WLS_FORMS/logs"
_scan_engine_logs "${DOMAIN_HOME}/config/fmwconfig/components/ReportsToolsComponent" 4

# =============================================================================
# Print plan
# =============================================================================

section "Action Plan"
printf "  \033[1m%-10s  %-52s  %10s  %s\033[0m\n" \
    "Action" "File" "Size" "Reason" | tee -a "${LOG_FILE:-/dev/null}"
printLine

last_dir=""
for (( i=0; i < ${#PLAN_FILE[@]}; i++ )); do
    f="${PLAN_FILE[$i]}"
    action="${PLAN_ACTION[$i]}"
    reason="${PLAN_REASON[$i]}"
    sz="${PLAN_SIZE[$i]}"
    dir="$(dirname "$f")"
    fname="$(basename "$f")"
    size_human="$(_human_size "$sz")"

    # Print directory header when it changes
    if [ "$dir" != "$last_dir" ]; then
        printf "\n  \033[1m%s\033[0m\n" "$dir" | tee -a "${LOG_FILE:-/dev/null}"
        last_dir="$dir"
    fi

    case "$action" in
        TRUNCATE)
            printf "  \033[33m%-10s\033[0m  %-52s  %10s  %s\n" \
                "$action" "$fname" "$size_human" "$reason" \
                | tee -a "${LOG_FILE:-/dev/null}"
            ;;
        DELETE)
            printf "  \033[31m%-10s\033[0m  %-52s  %10s  %s\n" \
                "$action" "$fname" "$size_human" "$reason" \
                | tee -a "${LOG_FILE:-/dev/null}"
            ;;
        SKIP)
            printf "  \033[2m%-10s  %-52s  %10s  %s\033[0m\n" \
                "$action" "$fname" "$size_human" "$reason" \
                | tee -a "${LOG_FILE:-/dev/null}"
            ;;
    esac
done

printf "\n" | tee -a "${LOG_FILE:-/dev/null}"
printLine
printf "  %-30s %s\n" "To truncate (set to 0):" \
    "$(_human_size "$PLAN_TRUNCATE_BYTES")" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-30s %s\n" "To delete (free disk):" \
    "$(_human_size "$PLAN_DELETE_BYTES")"  | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-30s %s\n" "Skipped (kept):" \
    "$(_human_size "$PLAN_SKIP_BYTES")"   | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-30s %s\n" "Total disk freed:" \
    "$(_human_size "$PLAN_DELETE_BYTES")" | tee -a "${LOG_FILE:-/dev/null}"

if [ "${#PLAN_FILE[@]}" -eq 0 ]; then
    ok "Nothing to do – no log files found in scanned directories"
    print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# Dry-run exit
# =============================================================================

if ! $APPLY; then
    printf "\n" | tee -a "${LOG_FILE:-/dev/null}"
    info "Dry-run complete – add --apply to execute the plan above."
    info "Recommended: run grep_logs.sh first to save any relevant errors."
    ok "Dry-run: no changes made"
    print_summary
    exit "$EXIT_CODE"
fi

# =============================================================================
# Execute
# =============================================================================

section "Executing"
FREED_BYTES=0

for (( i=0; i < ${#PLAN_FILE[@]}; i++ )); do
    f="${PLAN_FILE[$i]}"
    action="${PLAN_ACTION[$i]}"
    sz="${PLAN_SIZE[$i]}"
    fname="$(basename "$f")"

    case "$action" in
        TRUNCATE)
            if truncate -s 0 "$f" 2>/dev/null; then
                ok "Truncated: $fname  ($(_human_size "$sz") → 0 B)"
                FREED_BYTES=$(( FREED_BYTES + sz ))
            else
                fail "Cannot truncate: $f"
            fi
            ;;
        DELETE)
            if rm -f "$f" 2>/dev/null; then
                ok "Deleted:   $fname  ($(_human_size "$sz"))"
                FREED_BYTES=$(( FREED_BYTES + sz ))
            else
                fail "Cannot delete: $f"
            fi
            ;;
        SKIP)
            # Nothing to do
            ;;
    esac
done

printf "\n" | tee -a "${LOG_FILE:-/dev/null}"
printLine
printf "  \033[1mDisk freed: %s\033[0m\n" "$(_human_size "$FREED_BYTES")" \
    | tee -a "${LOG_FILE:-/dev/null}"

print_summary
exit $EXIT_CODE
