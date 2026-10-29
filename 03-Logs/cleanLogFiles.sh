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
#            --component NAME           all|reports|forms|wls|ords|<server> (default: all)
# Scope    : servers/*/logs of every WebLogic server, the standalone Reports
#            server (+ engines) and the Reports tools (log_locations.sh);
#            nodemanager/ and the EM logs are never touched
# Rules    : Active logs  (*.log, *.trc) → truncate -s 0  (file stays, server keeps writing)
#            *.out (stdout, may hold JVM crash info) → only with --include-out
#            Rotated (*.log00001, *.out00001, *-diagnostic-1.log) and
#            compressed logs older than retain-days → delete
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
# shellcheck source=log_locations.sh
source "$SCRIPT_DIR/log_locations.sh"

# =============================================================================
# Arguments
# =============================================================================

APPLY=false
RETAIN_DAYS="${LOG_RETAIN_DAYS:-7}"
INCLUDE_OUT=false
COMPONENT="all"

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)        APPLY=true; shift ;;
        --retain-days)  RETAIN_DAYS="$2"; shift 2 ;;
        --include-out)  INCLUDE_OUT=true; shift ;;
        --component)    COMPONENT="${2:?--component needs a value}"; shift 2 ;;
        --help|-h)
            printf "Usage: %s [--apply] [--retain-days N] [--include-out] [--component NAME]\n" \
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

# _plan file action reason – add one entry to the plan
_plan() {
    local sz; sz="$(stat -c %s "$1" 2>/dev/null || echo 0)"
    PLAN_FILE+=("$1"); PLAN_ACTION+=("$2"); PLAN_REASON+=("$3"); PLAN_SIZE+=("$sz")
    case "$2" in
        TRUNCATE) PLAN_TRUNCATE_BYTES=$(( PLAN_TRUNCATE_BYTES + sz )) ;;
        DELETE)   PLAN_DELETE_BYTES=$(( PLAN_DELETE_BYTES + sz )) ;;
        SKIP)     PLAN_SKIP_BYTES=$(( PLAN_SKIP_BYTES + sz )) ;;
    esac
}

# _scan_group dir depth [role] – plan for every log file of one log directory
_scan_group() {
    local dir="$1" depth="$2" role="${3:-}" f kind days
    while IFS= read -r -d '' f; do
        kind="$(ihw_log_kind "$f")"
        days="$(_days_since_epoch "$(stat -c %Y "$f" 2>/dev/null || echo 0)")"
        case "$kind" in
            active)
                # ORDS: never truncate (java.util.logging writes without append,
                # stdout/stderr belong to root) – only old files are deleted
                if [ "$role" = "ORDS" ]; then
                    _plan "$f" SKIP "ORDS active log – not truncated (old days / generations are deleted)"
                    continue
                fi
                case "$f" in
                    *.out)
                        if $INCLUDE_OUT; then _plan "$f" TRUNCATE "stdout log – truncate in place (--include-out)"
                        else                  _plan "$f" SKIP "stdout log – skipped (--include-out to truncate)"; fi ;;
                    *)  _plan "$f" TRUNCATE "active log – truncate in place" ;;
                esac ;;
            rotated|compressed)
                if [ "$days" -ge "$RETAIN_DAYS" ]; then
                    _plan "$f" DELETE "$kind – ${days}d old, retain: ${RETAIN_DAYS}d"
                else
                    _plan "$f" SKIP "$kind – ${days}d old, retain: ${RETAIN_DAYS}d (too recent)"
                fi ;;
        esac
    done < <(ihw_log_find "$dir" "$depth")
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
while IFS=$'\t' read -r _role _name _dir _depth; do
    # Node Manager and EM logs are never touched (left for Oracle Support)
    case "$_role" in "Node Manager"|"Enterprise Manager") continue ;; esac
    _scan_group "$_dir" "$_depth" "$_role"
done < <(ihw_log_groups "$COMPONENT")

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
    dir="${f%%/logs/*}/logs"            # group header = the server log dir
    [ "$dir" = "$f/logs" ] && dir="$(dirname "$f")"   # no /logs/ in the path (ORDS)
    fname="${f#"$dir"/}"                # logs/reports/… shown as reports/…
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
