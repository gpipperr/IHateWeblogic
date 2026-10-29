#!/bin/bash
# =============================================================================
# Script   : archive_logs.sh
# Purpose  : Compress rotated WebLogic/Reports log files with gzip to free disk
#            space while keeping the logs accessible (zgrep, zcat).
# Call     : ./archive_logs.sh              # dry-run: show candidates + estimated savings
#            ./archive_logs.sh --apply       # compress files
# Options  : --apply                    Execute compression (default: dry-run)
#            --min-age N                Only compress files older than N days
#                                       (default: LOG_ARCHIVE_MIN_AGE_DAYS=1)
#            --level N                  gzip compression level 1-9 (default: 9 = --best)
#            --component NAME           all|reports|forms|wls|nm|em|ords|<server> (default: all)
# Scope    : every log group of log_locations.sh (servers/*/logs incl. the
#            standalone Reports server and the Reports tools, Node Manager, EM)
# Rules    : Active logs (*.log, *.out, *.trc without rotation suffix) → never touched
#            Already compressed (*.gz, *.bz2)      → skipped
#            Rotated logs older than min-age (*.log00001, *.out00001,
#            *-diagnostic-1.log, *.log.1)          → compress with gzip
# Requires : gzip, find, stat, awk
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

# =============================================================================
# Arguments
# =============================================================================

APPLY=false
MIN_AGE="${LOG_ARCHIVE_MIN_AGE_DAYS:-1}"
GZIP_LEVEL=9
COMPONENT="all"

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)     APPLY=true;      shift ;;
        --min-age)   MIN_AGE="$2";    shift 2 ;;
        --level)     GZIP_LEVEL="$2"; shift 2 ;;
        --component) COMPONENT="${2:?--component needs a value}"; shift 2 ;;
        --help|-h)
            printf "Usage: %s [--apply] [--min-age N] [--level 1-9] [--component NAME]\n" \
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
# Scan – build compression plan
# =============================================================================

# Parallel arrays: file, action, size_bytes, age_days, reason
declare -a PLAN_FILE=()
declare -a PLAN_ACTION=()   # COMPRESS | SKIP
declare -a PLAN_REASON=()
declare -a PLAN_SIZE=()
PLAN_COMPRESS_BYTES=0
PLAN_SKIP_BYTES=0

# _scan_dir  dir  maxdepth – rotated logs older than MIN_AGE → COMPRESS,
# already compressed → SKIP (listed), active logs are not listed at all
_scan_dir() {
    local dir="$1" depth="${2:-2}" f kind sz days
    [ -d "$dir" ] || return
    while IFS= read -r -d '' f; do
        kind="$(ihw_log_kind "$f")"
        [ "$kind" = "active" ] && continue
        sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
        days="$(_days_since_epoch "$(stat -c %Y "$f" 2>/dev/null || echo 0)")"
        if [ "$kind" = "compressed" ]; then
            PLAN_FILE+=("$f"); PLAN_ACTION+=("SKIP")
            PLAN_REASON+=("already compressed"); PLAN_SIZE+=("$sz")
            PLAN_SKIP_BYTES=$(( PLAN_SKIP_BYTES + sz ))
        elif [ "$days" -lt "$MIN_AGE" ]; then
            PLAN_FILE+=("$f"); PLAN_ACTION+=("SKIP")
            PLAN_REASON+=("${days}d old – min-age: ${MIN_AGE}d (too recent)"); PLAN_SIZE+=("$sz")
            PLAN_SKIP_BYTES=$(( PLAN_SKIP_BYTES + sz ))
        else
            PLAN_FILE+=("$f"); PLAN_ACTION+=("COMPRESS")
            PLAN_REASON+=("${days}d old → gzip -${GZIP_LEVEL}"); PLAN_SIZE+=("$sz")
            PLAN_COMPRESS_BYTES=$(( PLAN_COMPRESS_BYTES + sz ))
        fi
    done < <(ihw_log_find "$dir" "$depth")
}

# =============================================================================
# Build plan
# =============================================================================

printLine
section "Archive Log Files – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-22s %s\n"    "DOMAIN_HOME:"  "${DOMAIN_HOME}"   | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-22s %d days\n" "Min age:"    "$MIN_AGE"          | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-22s gzip -%d\n" "Method:"    "$GZIP_LEVEL"       | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-22s %s\n" "Mode:" \
    "$( $APPLY && echo 'APPLY – files will be compressed' || echo 'DRY-RUN – no changes')" \
    | tee -a "${LOG_FILE:-/dev/null}"
printLine

if [ -z "${DOMAIN_HOME:-}" ]; then
    fail "DOMAIN_HOME is not set"
    print_summary; exit 2
fi

# Verify gzip is available
if ! command -v gzip > /dev/null 2>&1; then
    fail "gzip not found – install with: sudo dnf install gzip"
    print_summary; exit 2
fi

info "Scanning log directories..."
while IFS=$'\t' read -r _role _name _dir _depth; do
    _scan_dir "$_dir" "$_depth"
done < <(ihw_log_groups "$COMPONENT")

# =============================================================================
# Print plan
# =============================================================================

section "Compression Plan"
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

    if [ "$dir" != "$last_dir" ]; then
        printf "\n  \033[1m%s\033[0m\n" "$dir" | tee -a "${LOG_FILE:-/dev/null}"
        last_dir="$dir"
    fi

    case "$action" in
        COMPRESS)
            printf "  \033[32m%-10s\033[0m  %-52s  %10s  %s\n" \
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

# Estimate savings: gzip achieves ~85-90% on WLS text logs (show as 85%)
ESTIMATED_SAVINGS=$(( PLAN_COMPRESS_BYTES * 85 / 100 ))
ESTIMATED_AFTER=$(( PLAN_COMPRESS_BYTES - ESTIMATED_SAVINGS ))

printf "\n" | tee -a "${LOG_FILE:-/dev/null}"
printLine
printf "  %-30s %s\n"  "Candidates:"        \
    "$(_human_size "$PLAN_COMPRESS_BYTES") in ${#PLAN_FILE[@]} file(s)" \
    | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-30s %s\n"  "Estimated saving:"  \
    "~$(_human_size "$ESTIMATED_SAVINGS") (~85%% typical for WLS text logs)" \
    | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-30s %s\n"  "Estimated size after:" \
    "~$(_human_size "$ESTIMATED_AFTER")" \
    | tee -a "${LOG_FILE:-/dev/null}"

if [ "$PLAN_COMPRESS_BYTES" -eq 0 ]; then
    ok "Nothing to compress – no eligible rotated log files found"
    print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# Dry-run exit
# =============================================================================

if ! $APPLY; then
    printf "\n" | tee -a "${LOG_FILE:-/dev/null}"
    info "Dry-run complete – add --apply to execute."
    ok "Dry-run: no changes made"
    print_summary
    exit "$EXIT_CODE"
fi

# =============================================================================
# Execute compression
# =============================================================================

section "Compressing"
ACTUAL_BEFORE=0
ACTUAL_AFTER=0
COMPRESSED_COUNT=0
FAILED_COUNT=0

for (( i=0; i < ${#PLAN_FILE[@]}; i++ )); do
    [ "${PLAN_ACTION[$i]}" = "COMPRESS" ] || continue

    f="${PLAN_FILE[$i]}"
    sz_before="${PLAN_SIZE[$i]}"
    fname="$(basename "$f")"

    if gzip -"$GZIP_LEVEL" "$f" 2>/dev/null; then
        local_gz="${f}.gz"
        sz_after="$(stat -c %s "$local_gz" 2>/dev/null || echo 0)"
        saving=$(( sz_before - sz_after ))
        pct=0
        [ "$sz_before" -gt 0 ] && pct=$(( saving * 100 / sz_before ))

        ok "Compressed: $fname  ($(_human_size "$sz_before") → $(_human_size "$sz_after"), -${pct}%)"
        ACTUAL_BEFORE=$(( ACTUAL_BEFORE + sz_before ))
        ACTUAL_AFTER=$(( ACTUAL_AFTER  + sz_after  ))
        COMPRESSED_COUNT=$(( COMPRESSED_COUNT + 1 ))
    else
        fail "gzip failed: $f"
        FAILED_COUNT=$(( FAILED_COUNT + 1 ))
    fi
done

ACTUAL_SAVED=$(( ACTUAL_BEFORE - ACTUAL_AFTER ))
ACTUAL_PCT=0
[ "$ACTUAL_BEFORE" -gt 0 ] && ACTUAL_PCT=$(( ACTUAL_SAVED * 100 / ACTUAL_BEFORE ))

printf "\n" | tee -a "${LOG_FILE:-/dev/null}"
printLine
printf "  %-30s %d\n"  "Files compressed:"  "$COMPRESSED_COUNT"              | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-30s %s\n"  "Before:"            "$(_human_size "$ACTUAL_BEFORE")" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-30s %s\n"  "After:"             "$(_human_size "$ACTUAL_AFTER")"  | tee -a "${LOG_FILE:-/dev/null}"
printf "  \033[1m%-30s %s  (-%d%%)\033[0m\n" \
    "Saved:" "$(_human_size "$ACTUAL_SAVED")" "$ACTUAL_PCT"                   | tee -a "${LOG_FILE:-/dev/null}"
[ "$FAILED_COUNT" -gt 0 ] && \
    printf "  %-30s %d\n" "Failed:" "$FAILED_COUNT" | tee -a "${LOG_FILE:-/dev/null}"

print_summary
exit $EXIT_CODE
