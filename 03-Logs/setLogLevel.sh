#!/bin/bash
# =============================================================================
# Script   : setLogLevel.sh
# Purpose  : Query or change Java/ODL logger levels in running WLS servers
#            via WLST (Oracle Diagnostic Logging – listLoggers / setLogLevel).
# Call     : ./setLogLevel.sh --query
#            ./setLogLevel.sh --level FINE --apply
#            ./setLogLevel.sh --level FINE   --logger oracle.reports --apply
#            ./setLogLevel.sh --level INFO   --logger oracle.reports --apply
#            ./setLogLevel.sh --level WARNING --target all --apply
# Options  : --query              Show current logger levels (no --apply needed)
#            --level LEVEL        SEVERE|WARNING|INFO|CONFIG|FINE|FINER|FINEST
#            --logger NAME        Single logger name (default: all managed loggers)
#            --target SERVER      WLS_REPORTS|WLS_FORMS|AdminServer|all
#                                 (default: $WLS_MANAGED_SERVER from environment.conf)
#            --apply              Required to actually change levels (--level only)
# Requires : wlst.sh (oracle_common/common/bin/wlst.sh), weblogic_sec.conf.des3
# Note     : Changes are runtime-only (lost on server restart).
#            FINE/FINER/FINEST produce large log volumes – reset promptly with INFO.
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

ACTION=""          # query | set  (derived below)
LEVEL_ARG=""
LOGGER_ARG=""
TARGET_ARG=""
APPLY=false

_valid_levels="SEVERE WARNING INFO CONFIG FINE FINER FINEST"

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-34s %s\n" "--query"                  "Show current logger levels (no --apply needed)"
    printf "  %-34s %s\n" "--level LEVEL"             "SEVERE|WARNING|INFO|CONFIG|FINE|FINER|FINEST"
    printf "  %-34s %s\n" "--logger NAME"             "Logger prefix (default: all managed loggers)"
    printf "  %-34s %s\n" "--target WLS_REPORTS|all"  "Target server(s) (default: \$WLS_MANAGED_SERVER)"
    printf "  %-34s %s\n" "--apply"                   "Required to actually change levels (--level)"
    printf "\nExamples:\n"
    printf "  %s --query\n" "$(basename "$0")"
    printf "  %s --query --logger oracle.reports --target WLS_REPORTS\n" "$(basename "$0")"
    printf "  %s --level FINE   --logger oracle.reports --apply\n" "$(basename "$0")"
    printf "  %s --level INFO   --logger oracle.reports --apply\n" "$(basename "$0")"
    printf "  %s --level WARNING --apply\n" "$(basename "$0")"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --query)   ACTION="query";  shift ;;
        --level)   ACTION="set";   LEVEL_ARG="${2:-}"; shift 2 ;;
        --logger)  LOGGER_ARG="${2:-}"; shift 2 ;;
        --target)  TARGET_ARG="${2:-}"; shift 2 ;;
        --apply)   APPLY=true; shift ;;
        --help|-h) _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
    esac
done

# Default: query when no action specified
[ -z "$ACTION" ] && ACTION="query"

# Validate --level
if [ "$ACTION" = "set" ]; then
    if [ -z "$LEVEL_ARG" ]; then
        printf "\033[31mERROR\033[0m --level requires a value.\n" >&2
        _usage
    fi
    # Check against valid levels (case-insensitive)
    LEVEL_UP="${LEVEL_ARG^^}"
    valid=false
    for lv in $_valid_levels; do
        [ "$LEVEL_UP" = "$lv" ] && valid=true && break
    done
    if ! $valid; then
        printf "\033[31mERROR\033[0m Invalid level: '%s'\n" "$LEVEL_ARG" >&2
        printf "       Valid levels: %s\n" "$_valid_levels" >&2
        exit 1
    fi
    LEVEL_ARG="$LEVEL_UP"
fi

# =============================================================================
# Resolve WLST executable
# =============================================================================

WLST_SH="${WLST:-}"

# Fallback search if not set in environment.conf
if [ -z "$WLST_SH" ] || [ ! -x "$WLST_SH" ]; then
    for _candidate in \
        "${FMW_HOME:-}/oracle_common/common/bin/wlst.sh" \
        "/u01/oracle/fmw/oracle_common/common/bin/wlst.sh" \
        "/app/oracle/mw/oracle_common/common/bin/wlst.sh"
    do
        if [ -x "$_candidate" ]; then
            WLST_SH="$_candidate"
            break
        fi
    done
fi

if [ -z "$WLST_SH" ] || [ ! -x "$WLST_SH" ]; then
    fail "wlst.sh not found or not executable"
    info "Searched: \${FMW_HOME}/oracle_common/common/bin/wlst.sh"
    info "Check FMW_HOME in environment.conf or set WLST= explicitly"
    print_summary
    exit 2
fi
ok "WLST found: $WLST_SH"

# =============================================================================
# Resolve target server list
# =============================================================================

case "${TARGET_ARG,,}" in
    all)
        WLST_TARGETS="AdminServer ${WLS_MANAGED_SERVER:-WLS_REPORTS} WLS_FORMS"
        ;;
    "")
        WLST_TARGETS="${WLS_MANAGED_SERVER:-WLS_REPORTS}"
        ;;
    *)
        WLST_TARGETS="$TARGET_ARG"
        ;;
esac

# =============================================================================
# Resolve logger list
# =============================================================================

# Default set covers Oracle Reports, Forms, ADF, and WebLogic XML (common noise source)
_DEFAULT_LOGGERS="oracle.reports oracle.forms oracle.adf weblogic.xml.stax"

if [ -n "$LOGGER_ARG" ]; then
    WLST_LOGGERS="$LOGGER_ARG"
else
    WLST_LOGGERS="$_DEFAULT_LOGGERS"
fi

# =============================================================================
# Show current configuration
# =============================================================================

printLine
section "WLST Log Level – $([ "$ACTION" = "query" ] && echo "Query" || echo "Set")"
printList "WLST"        30 "$WLST_SH"
printList "Action"      30 "$ACTION"
printList "Target(s)"   30 "$WLST_TARGETS"
printList "Logger(s)"   30 "$WLST_LOGGERS"
[ "$ACTION" = "set" ] && printList "Level" 30 "$LEVEL_ARG"
printList "Apply"       30 "$APPLY"
printLine

# =============================================================================
# Dry-run preview for --level without --apply
# =============================================================================

if [ "$ACTION" = "set" ] && ! $APPLY; then
    section "Dry-run Preview (add --apply to execute)"
    printf "  Would set the following loggers to \033[1m%s\033[0m:\n\n" \
        "$LEVEL_ARG" | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-20s %s\n" "Target server(s):" "$WLST_TARGETS" \
        | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-20s\n" "Logger(s):" | tee -a "${LOG_FILE:-/dev/null}"
    for _l in $WLST_LOGGERS; do
        printf "    %s  ->  %s\n" "$_l" "$LEVEL_ARG" | tee -a "${LOG_FILE:-/dev/null}"
    done
    printf "\n" | tee -a "${LOG_FILE:-/dev/null}"
    # FINE/FINER/FINEST warning
    case "$LEVEL_ARG" in
        FINE|FINER|FINEST)
            warn "Level $LEVEL_ARG generates very large log volumes on an active server."
            warn "Reset promptly after diagnosis: --level INFO --logger <same> --apply"
            ;;
    esac
    ok "Dry-run complete – no changes made"
    print_summary
    exit "$EXIT_CODE"
fi

# =============================================================================
# Load WebLogic credentials
# =============================================================================

load_weblogic_password || {
    info "Run first: 00-Setup/weblogic_sec.sh --apply"
    print_summary
    exit 2
}

# Export password through a private env var; Python reads it; unset after WLST
export _IHW_WL_PWD="$INTERNAL_WL_PWD"
export WL_USER WL_ADMIN_URL
export WLST_ACTION="$ACTION"
export WLST_LEVEL="${LEVEL_ARG:-INFO}"
export WLST_LOGGERS WLST_TARGETS

# =============================================================================
# Generate WLST Python script
# =============================================================================

WLST_PY="$(mktemp /tmp/ihw_setloglevel_XXXXXX.py)"
trap 'rm -f "$WLST_PY"; unset _IHW_WL_PWD WLST_ACTION WLST_LEVEL WLST_LOGGERS WLST_TARGETS' EXIT

cat > "$WLST_PY" << 'PYEOF'
import sys
import os

wl_user     = os.environ.get('WL_USER',       'weblogic')
wl_password = os.environ.get('_IHW_WL_PWD',   '')
wl_url      = os.environ.get('WL_ADMIN_URL',   't3://localhost:7001')
action      = os.environ.get('WLST_ACTION',    'query')
level       = os.environ.get('WLST_LEVEL',     'INFO')
loggers_str = os.environ.get('WLST_LOGGERS',   'oracle.reports')
targets_str = os.environ.get('WLST_TARGETS',   'WLS_REPORTS')

loggers = [l for l in loggers_str.split() if l]
targets = [t for t in targets_str.split() if t]

SEP = "=" * 70

print(SEP)
print("IHateWeblogic – WLST Log Level: " + action.upper())
print("Admin URL : " + wl_url)
print("User      : " + wl_user)
print(SEP)

# ── Connect ───────────────────────────────────────────────────────────────────
try:
    connect(wl_user, wl_password, wl_url)
except Exception as conn_ex:
    print("\nFAIL: Cannot connect to AdminServer at " + wl_url)
    print("      " + str(conn_ex))
    print("\nCheck:")
    print("  1. AdminServer is running")
    print("  2. Credentials correct: 00-Setup/weblogic_sec.sh --apply")
    print("  3. WL_ADMIN_URL correct in environment.conf")
    sys.exit(1)

# ── QUERY ─────────────────────────────────────────────────────────────────────
if action == 'query':
    print("\n--- Current Log Levels ---")
    for srv in targets:
        print("\n[" + srv + "]")
        for logger in loggers:
            pattern = logger + '*'
            try:
                listLoggers(pattern=pattern, target=srv)
            except NameError:
                print("  ERROR: listLoggers() not available in this WLST.")
                print("  Ensure you use: oracle_common/common/bin/wlst.sh")
                print("  (NOT: wlserver/common/bin/wlst.sh)")
                disconnect()
                sys.exit(2)
            except Exception as e:
                print("  " + pattern + "  -- not accessible: " + str(e))

# ── SET ───────────────────────────────────────────────────────────────────────
elif action == 'set':
    print("\n--- Setting Log Level: " + level + " ---")
    ok_count  = 0
    fail_count = 0
    for srv in targets:
        print("\n[" + srv + "]")
        for logger in loggers:
            try:
                setLogLevel(logger=logger, level=level, target=srv)
                print("  OK    " + logger + "  ->  " + level)
                ok_count += 1
            except NameError:
                print("  ERROR: setLogLevel() not available in this WLST.")
                print("  Ensure you use: oracle_common/common/bin/wlst.sh")
                disconnect()
                sys.exit(2)
            except Exception as e:
                print("  FAIL  " + logger + ": " + str(e))
                fail_count += 1
    print("\nResult: OK=" + str(ok_count) + "  FAIL=" + str(fail_count))

# ── Disconnect ────────────────────────────────────────────────────────────────
try:
    disconnect()
except:
    pass

print("\nDone.")
PYEOF

# =============================================================================
# FINE/FINER/FINEST volume warning (printed before WLST executes)
# =============================================================================

if [ "$ACTION" = "set" ]; then
    case "$LEVEL_ARG" in
        FINE|FINER|FINEST)
            warn "Level $LEVEL_ARG generates very large log volumes on an active server."
            warn "Reset promptly after diagnosis:  --level INFO --logger \"$WLST_LOGGERS\" --apply"
            ;;
    esac
fi

# =============================================================================
# Execute WLST
# =============================================================================

section "WLST Output"
info "Executing: $WLST_SH $WLST_PY"
info "Note: WebLogic prints its startup banner before the script output."
printf "\n" | tee -a "${LOG_FILE:-/dev/null}"

"$WLST_SH" "$WLST_PY" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"
WLST_RC="${PIPESTATUS[0]}"

# =============================================================================
# Evaluate result
# =============================================================================

printf "\n" | tee -a "${LOG_FILE:-/dev/null}"
if [ "$WLST_RC" -eq 0 ]; then
    ok "WLST completed successfully (rc=0)"
elif [ "$WLST_RC" -eq 2 ]; then
    fail "WLST: listLoggers/setLogLevel not available – wrong wlst.sh? (rc=2)"
    info "Required: \${FMW_HOME}/oracle_common/common/bin/wlst.sh"
else
    fail "WLST exited with rc=$WLST_RC – check output above for details"
fi

# Cleanup (trap handles temp file and env var unset)
print_summary
exit $EXIT_CODE
