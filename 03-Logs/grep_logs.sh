#!/bin/bash
# =============================================================================
# Script   : grep_logs.sh
# Purpose  : Search a pattern across all WebLogic/Reports/Forms log files
#            including rotated and gzip-compressed logs.
# Call     : ./grep_logs.sh <pattern> [options]
#            ./grep_logs.sh "REP-3000"
#            ./grep_logs.sh "REP-" --component WLS_REPORTS --since 2026-03-04
#            ./grep_logs.sh "Exception" --context 5 --level ERROR
#            ./grep_logs.sh "Exception" --since-minutes 30
# Options  : --component     all|AdminServer|WLS_REPORTS|WLS_FORMS  (default: all)
#            --since         YYYY-MM-DD   only files modified on/after this date
#            --since-minutes N            only files modified within the last N minutes
#            --context       N            lines of context per match (default: 3)
#            --level         ERROR|WARNING|INFO  pre-filter file by severity keyword
# Requires : grep, find, zgrep (for .gz files)
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
# Argument parsing
# =============================================================================

PATTERN=""
COMPONENT="all"
SINCE=""
SINCE_MINUTES=""
CONTEXT=3
LEVEL_FILTER=""

_usage() {
    printf "Usage: %s <pattern> [options]\n\n" "$(basename "$0")"
    printf "  %-34s %s\n" "<pattern>"                  "Search pattern (required, case-insensitive)"
    printf "  %-34s %s\n" "--component <name>"         "all|AdminServer|WLS_REPORTS|WLS_FORMS (default: all)"
    printf "  %-34s %s\n" "--since YYYY-MM-DD"         "Only search files modified on/after this date"
    printf "  %-34s %s\n" "--since-minutes N"          "Only search files modified within the last N minutes"
    printf "  %-34s %s\n" "--context N"                "Lines of context around each match (default: 3)"
    printf "  %-34s %s\n" "--level ERROR|WARNING|INFO" "Only show files containing this severity keyword"
    printf "\nExamples:\n"
    printf "  %s 'REP-3000'\n" "$(basename "$0")"
    printf "  %s 'REP-' --component WLS_REPORTS --since 2026-03-04\n" "$(basename "$0")"
    printf "  %s 'Exception' --context 10 --level ERROR\n" "$(basename "$0")"
    printf "  %s 'Exception' --since-minutes 30\n" "$(basename "$0")"
    printf "  %s 'REP-' --since-minutes 5 --component WLS_REPORTS\n" "$(basename "$0")"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --component)     COMPONENT="$2";      shift 2 ;;
        --since)         SINCE="$2";          shift 2 ;;
        --since-minutes) SINCE_MINUTES="$2";  shift 2 ;;
        --context)       CONTEXT="$2";        shift 2 ;;
        --level)         LEVEL_FILTER="$2";   shift 2 ;;
        --help|-h)   _usage ;;
        -*)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
        *)
            if [ -z "$PATTERN" ]; then
                PATTERN="$1"
            else
                printf "\033[31mERROR\033[0m Unexpected argument: %s\n" "$1" >&2
                _usage
            fi
            shift
            ;;
    esac
done

if [ -z "$PATTERN" ]; then
    printf "\033[31mERROR\033[0m Search pattern required.\n\n" >&2
    _usage
fi

if [ -z "${DOMAIN_HOME:-}" ]; then
    fail "DOMAIN_HOME is not set – cannot locate log directories"
    print_summary
    exit 2
fi

# --since and --since-minutes are mutually exclusive
if [ -n "$SINCE" ] && [ -n "$SINCE_MINUTES" ]; then
    printf "\033[31mERROR\033[0m --since and --since-minutes cannot be combined.\n" >&2
    exit 1
fi

# Validate --since-minutes: must be a positive integer
if [ -n "$SINCE_MINUTES" ]; then
    if ! [[ "$SINCE_MINUTES" =~ ^[1-9][0-9]*$ ]]; then
        printf "\033[31mERROR\033[0m --since-minutes requires a positive integer, got: '%s'\n" \
            "$SINCE_MINUTES" >&2
        exit 1
    fi
fi

# Build find time-filter argument array
declare -a FIND_SINCE=()
if [ -n "$SINCE_MINUTES" ]; then
    FIND_SINCE=( -mmin "-${SINCE_MINUTES}" )
elif [ -n "$SINCE" ]; then
    if ! date -d "$SINCE" '+%Y-%m-%d' > /dev/null 2>&1; then
        printf "\033[31mERROR\033[0m Invalid date for --since: '%s' (expected YYYY-MM-DD)\n" \
            "$SINCE" >&2
        exit 1
    fi
    FIND_SINCE=( -newermt "$SINCE" )
fi

# =============================================================================
# Build search directory list based on --component
# =============================================================================

_REPTOOLS_BASE="${DOMAIN_HOME}/config/fmwconfig/components/ReportsToolsComponent"

declare -a SEARCH_DIRS
case "${COMPONENT,,}" in
    adminserver)
        SEARCH_DIRS=(
            "${DOMAIN_HOME}/servers/AdminServer/logs"
            "${DOMAIN_HOME}/diagnostics/logs/AdminServer"
        )
        ;;
    wls_reports)
        SEARCH_DIRS=(
            "${DOMAIN_HOME}/servers/WLS_REPORTS/logs"
            "$_REPTOOLS_BASE"
            "${DOMAIN_HOME}/diagnostics/logs/WLS_REPORTS"
        )
        ;;
    wls_forms)
        SEARCH_DIRS=(
            "${DOMAIN_HOME}/servers/WLS_FORMS/logs"
            "${DOMAIN_HOME}/diagnostics/logs/WLS_FORMS"
        )
        ;;
    all|*)
        SEARCH_DIRS=(
            "${DOMAIN_HOME}/servers/AdminServer/logs"
            "${DOMAIN_HOME}/servers/WLS_REPORTS/logs"
            "${DOMAIN_HOME}/servers/WLS_FORMS/logs"
            "$_REPTOOLS_BASE"
            "${DOMAIN_HOME}/diagnostics/logs"
            "${DOMAIN_HOME}/nodemanager"
        )
        ;;
esac

# =============================================================================
# Output helpers
# =============================================================================

ESC=$'\033'

# _colorize – highlights known Oracle error codes and severity keywords
_colorize() {
    sed -E \
        -e "s/(REP-[0-9]+)/${ESC}[31m\1${ESC}[0m/g" \
        -e "s/(FRM-[0-9]+)/${ESC}[31m\1${ESC}[0m/g" \
        -e "s/(BEA-[0-9]+)/${ESC}[33m\1${ESC}[0m/g" \
        -e "s/(ORA-[0-9]+)/${ESC}[33m\1${ESC}[0m/g" \
        -e "s/(SEVERE|ERROR)/${ESC}[31m\1${ESC}[0m/g" \
        -e "s/(WARNING|WARN)/${ESC}[33m\1${ESC}[0m/g"
}

# =============================================================================
# Search engine
# =============================================================================

TOTAL_MATCHES=0
TOTAL_FILES=0
TOTAL_SEARCHED=0

# _grep_file  file  use_zgrep(true|false)
# Searches file for PATTERN; prints results with context.
# Optional LEVEL_FILTER: skip files that do not also contain the level keyword.
_grep_file() {
    local file="$1"
    local use_zgrep="${2:-false}"

    TOTAL_SEARCHED=$(( TOTAL_SEARCHED + 1 ))

    # Fast path: count matches before doing anything else
    local matches
    if [ "$use_zgrep" = "true" ]; then
        matches=$(zgrep -ic "$PATTERN" "$file" 2>/dev/null)
    else
        matches=$(grep -ic "$PATTERN" "$file" 2>/dev/null)
    fi
    matches="${matches:-0}"
    [ "$matches" -eq 0 ] && return

    # File-level level filter: skip file if severity keyword not present anywhere
    if [ -n "$LEVEL_FILTER" ]; then
        if [ "$use_zgrep" = "true" ]; then
            zgrep -qi "$LEVEL_FILTER" "$file" 2>/dev/null || return
        else
            grep -qi "$LEVEL_FILTER" "$file" 2>/dev/null || return
        fi
    fi

    # Print file header
    printf "\n${ESC}[1m--- %s ---${ESC}[0m\n" "$file" \
        | tee -a "${LOG_FILE:-/dev/null}"

    # Print matching lines with context
    local output
    if [ "$use_zgrep" = "true" ]; then
        output=$(zgrep -in -C "$CONTEXT" "$PATTERN" "$file" 2>/dev/null)
    else
        output=$(grep -in -C "$CONTEXT" "$PATTERN" "$file" 2>/dev/null)
    fi
    printf "%s\n" "$output" | _colorize | tee -a "${LOG_FILE:-/dev/null}"

    TOTAL_MATCHES=$(( TOTAL_MATCHES + matches ))
    TOTAL_FILES=$(( TOTAL_FILES + 1 ))
}

# _search_dir  dir  maxdepth
_search_dir() {
    local dir="$1"
    local maxdepth="${2:-4}"

    [ -d "$dir" ] || return

    # Plain log and stdout files (active + rotated)
    while IFS= read -r -d '' f; do
        _grep_file "$f" false
    done < <(find "$dir" -maxdepth "$maxdepth" \
        \( -name "*.log" -o -name "*.log[0-9]*" -o -name "*.out" \) \
        "${FIND_SINCE[@]}" \
        -type f -print0 2>/dev/null | sort -z)

    # Compressed logs via zgrep
    if command -v zgrep > /dev/null 2>&1; then
        while IFS= read -r -d '' f; do
            _grep_file "$f" true
        done < <(find "$dir" -maxdepth "$maxdepth" \
            \( -name "*.gz" -o -name "*.bz2" \) \
            "${FIND_SINCE[@]}" \
            -type f -print0 2>/dev/null | sort -z)
    fi
}

# =============================================================================
# Main
# =============================================================================

printLine
section "Log Search"
_since_label() {
    if   [ -n "$SINCE_MINUTES" ]; then printf "last %d min" "$SINCE_MINUTES"
    elif [ -n "$SINCE"         ]; then printf "%s" "$SINCE"
    else                                printf "(all files)"
    fi
}

printf "  %-16s \"%s\"\n"   "Pattern:"   "$PATTERN"          | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-16s %s\n"       "Component:" "$COMPONENT"        | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-16s %s\n"       "Since:"     "$(_since_label)"   | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-16s %s lines\n" "Context:"   "$CONTEXT"          | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-16s %s\n"       "Level:"     "${LEVEL_FILTER:-(all)}" | tee -a "${LOG_FILE:-/dev/null}"
printLine

for dir in "${SEARCH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    # Deeper maxdepth for components with nested log directories
    local_depth=2
    [[ "$dir" == *"ReportsToolsComponent"* ]] && local_depth=4
    [[ "$dir" == *"diagnostics/logs"*      ]] && local_depth=3
    _search_dir "$dir" "$local_depth"
done

# =============================================================================
# Result summary
# =============================================================================

printf "\n" | tee -a "${LOG_FILE:-/dev/null}"
printLine
section "Search Results"
printf "  %-22s \"%s\"\n" "Pattern:"         "$PATTERN"        | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-22s %d\n"     "Files searched:"  "$TOTAL_SEARCHED" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-22s %d\n"     "Files with hits:" "$TOTAL_FILES"    | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-22s %d\n"     "Matching lines:"  "$TOTAL_MATCHES"  | tee -a "${LOG_FILE:-/dev/null}"

if [ "$TOTAL_MATCHES" -eq 0 ]; then
    ok "No matches found for pattern: \"$PATTERN\""
else
    warn "Found $TOTAL_MATCHES matching line(s) in $TOTAL_FILES file(s) – review output above"
fi

print_summary
exit $EXIT_CODE
