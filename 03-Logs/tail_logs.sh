#!/bin/bash
# =============================================================================
# Script   : tail_logs.sh
# Purpose  : Live-tail multiple WebLogic/Reports/Forms log files simultaneously.
#            tmux available : split-pane view (one pane per log, tiled layout)
#            No tmux        : tail -f with colour-filtered output
# Call     : ./tail_logs.sh
#            ./tail_logs.sh --component WLS_REPORTS
#            ./tail_logs.sh --component all --lines 50
#            ./tail_logs.sh --no-tmux
# Options  : --component  all|AdminServer|WLS_REPORTS|WLS_FORMS  (default: all)
#            --lines N    initial tail lines shown per file (default: 20)
#            --no-tmux    force plain tail mode even when tmux is available
# Requires : tail (always); tmux >= 1.9 (optional, for split-pane mode)
# Note     : Read-only monitoring tool – no --apply needed.
#            In tmux mode press Ctrl-b d to detach, Ctrl-b & to close window.
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

COMPONENT="all"
LINES=20
FORCE_PLAIN=false

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-34s %s\n" "--component all|AdminServer|..."  "Component filter (default: all)"
    printf "  %-34s %s\n" "--lines N"                        "Initial lines per file (default: 20)"
    printf "  %-34s %s\n" "--no-tmux"                        "Plain tail mode, no tmux"
    printf "\nComponents: all  AdminServer  WLS_REPORTS  WLS_FORMS\n"
    printf "\nExamples:\n"
    printf "  %s\n" "$(basename "$0")"
    printf "  %s --component WLS_REPORTS\n" "$(basename "$0")"
    printf "  %s --component all --lines 50\n" "$(basename "$0")"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --component) COMPONENT="$2"; shift 2 ;;
        --lines)     LINES="$2";     shift 2 ;;
        --no-tmux)   FORCE_PLAIN=true; shift ;;
        --help|-h)   _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
    esac
done

# =============================================================================
# Build log file list
# =============================================================================

_REPTOOLS_BASE="${DOMAIN_HOME}/config/fmwconfig/components/ReportsToolsComponent"

# _find_active_logs  dir  [maxdepth]
# Prints paths of active (non-rotated) *.log files, most recently modified first.
_find_active_logs() {
    local dir="$1"
    local depth="${2:-1}"
    [ -d "$dir" ] || return
    find "$dir" -maxdepth "$depth" \
        -name "*.log" \
        -not -name "*.[0-9]*" \
        -type f 2>/dev/null \
        | xargs ls -t 2>/dev/null
}

# _find_reptools_log
# Returns the most recently modified log under ReportsToolsComponent.
_find_reptools_log() {
    [ -d "$_REPTOOLS_BASE" ] || return
    find "$_REPTOOLS_BASE" -maxdepth 4 \
        -name "*.log" \
        -not -name "*.[0-9]*" \
        -type f 2>/dev/null \
        | xargs ls -t 2>/dev/null \
        | head -1
}

declare -a LOG_FILES=()

_add_logs() {
    local dir="$1"
    local depth="${2:-1}"
    while IFS= read -r f; do
        [ -f "$f" ] && LOG_FILES+=("$f")
    done < <(_find_active_logs "$dir" "$depth")
}

case "${COMPONENT,,}" in
    adminserver)
        _add_logs "${DOMAIN_HOME}/servers/AdminServer/logs"
        ;;
    wls_reports)
        _add_logs "${DOMAIN_HOME}/servers/WLS_REPORTS/logs"
        replog="$(_find_reptools_log)"
        [ -n "$replog" ] && LOG_FILES+=("$replog")
        ;;
    wls_forms)
        _add_logs "${DOMAIN_HOME}/servers/WLS_FORMS/logs"
        ;;
    all|*)
        _add_logs "${DOMAIN_HOME}/servers/AdminServer/logs"
        _add_logs "${DOMAIN_HOME}/servers/WLS_REPORTS/logs"
        _add_logs "${DOMAIN_HOME}/servers/WLS_FORMS/logs"
        replog="$(_find_reptools_log)"
        [ -n "$replog" ] && LOG_FILES+=("$replog")
        ;;
esac

# Remove duplicates while preserving order
declare -a UNIQUE_FILES=()
declare -A _SEEN=()
for f in "${LOG_FILES[@]}"; do
    if [ -z "${_SEEN[$f]+x}" ]; then
        UNIQUE_FILES+=("$f")
        _SEEN[$f]=1
    fi
done
LOG_FILES=("${UNIQUE_FILES[@]}")

# =============================================================================
# Pre-flight checks
# =============================================================================

printLine
section "tail_logs – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-18s %s\n" "Component:"  "$COMPONENT"  | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-18s %s\n" "DOMAIN_HOME:" "${DOMAIN_HOME}" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-18s %d\n" "Initial lines:" "$LINES"   | tee -a "${LOG_FILE:-/dev/null}"
printLine

if [ "${#LOG_FILES[@]}" -eq 0 ]; then
    fail "No active log files found for component: $COMPONENT"
    info "Check that the server is running and DOMAIN_HOME is correct."
    print_summary
    exit 1
fi

info "Log files to tail:"
for f in "${LOG_FILES[@]}"; do
    printf "  \033[36m%s\033[0m\n" "$f" | tee -a "${LOG_FILE:-/dev/null}"
done
printf "\n" | tee -a "${LOG_FILE:-/dev/null}"

# =============================================================================
# Colour filter – used in plain-tail fallback mode
# Reads from stdin, writes coloured output to stdout.
# =============================================================================

_colour_filter() {
    while IFS= read -r line; do
        case "$line" in
            # tail -f file separator header
            '==>'*'<=='*)
                printf '\033[36;1m%s\033[0m\n' "$line" ;;
            # WLS format <Error> / ODL [ERROR] / SEVERE keyword
            *'<Error>'*|*'[ERROR]'*|*' ERROR '*|*SEVERE*|'####'*'<Error>'*)
                printf '\033[31m%s\033[0m\n' "$line" ;;
            # WLS format <Warning> / ODL [WARNING] / WARN keyword
            *'<Warning>'*|*'[WARNING]'*|*' WARNING '*|*' WARN '*)
                printf '\033[33m%s\033[0m\n' "$line" ;;
            # WLS format <Notice>/<Info> / ODL [NOTIFICATION]/[INFO]
            *'<Info>'*|*'<Notice>'*|*'[INFO]'*|*'[NOTIFICATION]'*)
                printf '\033[32m%s\033[0m\n' "$line" ;;
            # Oracle error codes
            *'REP-'*|*'FRM-'*)
                printf '\033[31m%s\033[0m\n' "$line" ;;
            *)
                printf '%s\n' "$line" ;;
        esac
    done
}

# =============================================================================
# Plain tail mode (fallback / --no-tmux)
# =============================================================================

_launch_plain() {
    info "Mode: plain tail (tmux not available or --no-tmux)"
    printf "\n" | tee -a "${LOG_FILE:-/dev/null}"
    printf "  Press \033[1mCtrl-C\033[0m to stop.\n\n"

    # Show a coloured header per file before starting
    for f in "${LOG_FILES[@]}"; do
        printf "\033[36;1m>>> watching: %s\033[0m\n" "$f"
    done
    printf "\n"

    # tail -f with multiple files prints "==> file <==" headers when switching.
    # Pipe through colour filter.
    tail -f -n "$LINES" "${LOG_FILES[@]}" | _colour_filter
}

# =============================================================================
# tmux mode
# =============================================================================

# _tmux_pane_cmd  file  lines
# Returns the shell command to run inside a tmux pane for this log file.
_tmux_pane_cmd() {
    local file="$1"
    local n="$2"
    # Run tail; on exit (e.g. file removed) wait for a keypress before closing pane
    printf "tail -f -n %d '%s' || { printf '\\n\\033[31m[tail exited]\\033[0m Press Enter...; read; }'" \
        "$n" "$file"
}

_launch_tmux() {
    local session="ihw-logs-$$"
    local in_tmux="${TMUX:-}"

    info "Mode: tmux split-pane  (session: $session)"
    printf "  Tip: \033[1mCtrl-b d\033[0m detach   \033[1mCtrl-b &\033[0m close window\n\n"

    local first_file="${LOG_FILES[0]}"

    if [ -n "$in_tmux" ]; then
        # ── Already inside tmux: open a new window ──────────────────────────────
        tmux new-window -n "ihw-logs" "$(_tmux_pane_cmd "$first_file" "$LINES")"
        # Enable pane border title display
        tmux set-option -w pane-border-status top
        tmux set-option -w pane-border-format " #{pane_title} "
        tmux select-pane -T "$(basename "$first_file")"

        for (( i=1; i < ${#LOG_FILES[@]}; i++ )); do
            tmux split-window "$(_tmux_pane_cmd "${LOG_FILES[$i]}" "$LINES")"
            tmux select-pane -T "$(basename "${LOG_FILES[$i]}")"
        done

        tmux select-layout tiled
        # Focus the first pane
        tmux select-pane -t 0
        info "tmux window 'ihw-logs' opened in current session."

    else
        # ── Outside tmux: create a new detached session, then attach ────────────
        tmux new-session -d -s "$session" -n "ihw-logs" \
            "$(_tmux_pane_cmd "$first_file" "$LINES")"

        # Enable pane border title display for this session
        tmux set-option -t "$session" pane-border-status top
        tmux set-option -t "$session" pane-border-format " #{pane_title} "
        tmux select-pane -t "${session}:0.0" -T "$(basename "$first_file")"

        for (( i=1; i < ${#LOG_FILES[@]}; i++ )); do
            tmux split-window -t "$session" \
                "$(_tmux_pane_cmd "${LOG_FILES[$i]}" "$LINES")"
            tmux select-pane -t "${session}" -T "$(basename "${LOG_FILES[$i]}")"
        done

        # Tiled layout distributes all panes evenly regardless of count
        tmux select-layout -t "$session" tiled
        # Focus the first pane
        tmux select-pane -t "${session}:0.0"

        # Replace current shell with tmux attach (Ctrl-C kills attach, not session)
        exec tmux attach-session -t "$session"
    fi
}

# =============================================================================
# Launch
# =============================================================================

if ! $FORCE_PLAIN && command -v tmux > /dev/null 2>&1; then
    ok "tmux detected – launching split-pane view"
    _launch_tmux
else
    if $FORCE_PLAIN; then
        info "tmux disabled by --no-tmux"
    else
        warn "tmux not found – falling back to plain tail mode"
        info "Install tmux for split-pane view:  sudo dnf install tmux"
    fi
    _launch_plain
fi
