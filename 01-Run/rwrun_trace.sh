#!/bin/bash
# =============================================================================
# Script   : rwrun_trace.sh
# Purpose  : Run ONE report with rwrun (in-process, no Reports server) and
#            collect everything needed for a root-cause analysis in one
#            directory: report output, rwrun trace (TRACEOPTS), console
#            output (LOGFILE is deprecated in 14.1.2, REP-34551), the new lines of the ODL runtime log and new ADR
#            incidents (hard crashes of the native engine).
#            Uses the wrapper of the ReportsTools instance
#            ($DOMAIN_HOME/reports/bin/rwrun.sh - sets the Reports
#            environment; no X display needed, REPORTS_DEFAULT_DISPLAY=YES).
#            The DB password goes into a cmdfile (mode 600, removed after the
#            run) - never on the command line / in the process list.
# Call     : ./rwrun_trace.sh --report test_dual.rdf
#            ./rwrun_trace.sh --report /path/my.rdf --params "P_DEPT=10 P_FROM=2026"
#            ./rwrun_trace.sh --report my.rdf --odl --apply
# Options  : --report FILE   .rdf/.rep/.xml; absolute or name searched in
#                            REPORTS_CUSTOMER_DIR and REPORTS_PATH (required)
#            --format FMT    desformat (default pdf)
#            --params "..."  report parameters NAME=VALUE (blank-separated)
#            --traceopts OPT TRACE_ALL (default) | TRACE_ERR | TRACE_SQL |
#                            TRACE_PLS | TRACE_PRF | TRACE_APP | ... (rwrun)
#            --db-sec FILE   DB credentials (default test_db_sec.conf.des3:
#                            TEST_DB_USER, TEST_DB_PWD; DB = TEST_DB_HOST/PORT/
#                            SERVICE or DB_HOST/PORT/SERVICE)
#            --odl           also set the ODL logger oracle.reports.runtime to
#                            TRACE:32 for this run (needs --apply; logging.xml
#                            of the ReportsTools instance is restored afterwards)
#            --apply         allow the temporary logging.xml change (--odl)
#            --help          show usage
# Ref      : 01-Run/README.md (rwrun_trace.sh), memory/rwrun findings 2026-10-14
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
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
REPORT="" FORMAT="pdf" PARAMS="" TRACEOPTS="TRACE_ALL"
DB_SEC="$ROOT_DIR/test_db_sec.conf.des3"
ODL=false APPLY=false

_usage() {
    sed -n '/^# Call/,/^# Ref/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --report)    REPORT="${2:-}";    shift 2 ;;
        --format)    FORMAT="${2:-pdf}"; shift 2 ;;
        --params)    PARAMS="${2:-}";    shift 2 ;;
        --traceopts) TRACEOPTS="${2^^}"; shift 2 ;;
        --db-sec)    DB_SEC="${2:-}";    shift 2 ;;
        --odl)       ODL=true;  shift ;;
        --apply)     APPLY=true; shift ;;
        --help|-h)   _usage ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s (see --help)\n" "$1" >&2; exit 2 ;;
    esac
done
[ -z "$REPORT" ] && { printf "\033[31mERROR\033[0m --report is required (see --help)\n" >&2; exit 2; }

# =============================================================================
# Pre-checks
# =============================================================================
section "rwrun trace – $(date '+%Y-%m-%d %H:%M:%S')"

RWRUN="$DOMAIN_HOME/reports/bin/rwrun.sh"
TOOLS_INST="${REPORTS_TOOLS_INSTANCE:-reptools1}"
TOOLS_LOGGING="$DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/$TOOLS_INST/logging.xml"
RUNTIME_LOG="$DOMAIN_HOME/servers/$TOOLS_INST/logs/runtime_diagnostic.log"
ADR_BASE="$HOME/oradiag_$(id -un)/diag/clients/user_$(id -un)"

if [ ! -x "$RWRUN" ]; then
    fail "rwrun wrapper not found: $RWRUN"
    info "  ReportsTools instance missing? -> 09-Install/13-oracle_setup_reports.sh"
    print_summary; exit 2
fi
ok "rwrun wrapper: $RWRUN"

# Resolve the report: absolute path or search REPORTS_CUSTOMER_DIR / REPORTS_PATH
REPORT_FILE=""
if [ -f "$REPORT" ]; then
    REPORT_FILE="$(readlink -f "$REPORT")"
else
    IFS=':' read -r -a _dirs <<< "${REPORTS_CUSTOMER_DIR:-}:${REPORTS_PATH:-}"
    for _d in "${_dirs[@]}"; do
        [ -n "$_d" ] && [ -f "$_d/$REPORT" ] && { REPORT_FILE="$_d/$REPORT"; break; }
    done
    unset _dirs _d
fi
if [ -z "$REPORT_FILE" ]; then
    fail "Report not found: $REPORT (absolute path, REPORTS_CUSTOMER_DIR or REPORTS_PATH)"
    print_summary; exit 2
fi
ok "Report: $REPORT_FILE"

if ! load_secrets_file "$DB_SEC" > /dev/null 2>&1 || [ -z "${TEST_DB_USER:-}" ] || [ -z "${TEST_DB_PWD:-}" ]; then
    fail "DB credentials not readable: $DB_SEC (TEST_DB_USER / TEST_DB_PWD)"
    info "  09-Install/15-deploy-test-report-forms_template.sh --apply asks for them once"
    print_summary; exit 2
fi
_DBH="${TEST_DB_HOST:-${DB_HOST:-}}"; _DBP="${TEST_DB_PORT:-${DB_PORT:-1521}}"; _DBS="${TEST_DB_SERVICE:-${DB_SERVICE:-}}"
if [ -z "$_DBH" ] || [ -z "$_DBS" ]; then
    fail "Test DB unknown – DB_HOST/DB_SERVICE (or TEST_DB_*) in environment.conf"
    print_summary; exit 2
fi
ok "DB user: $TEST_DB_USER @ ${_DBH}:${_DBP}/${_DBS}"

if $ODL && ! $APPLY; then
    warn "--odl changes logging.xml of $TOOLS_INST for the run – add --apply (dry-run: ODL skipped)"
    ODL=false
fi
if $ODL && [ ! -f "$TOOLS_LOGGING" ]; then
    warn "logging.xml not found: $TOOLS_LOGGING – ODL trace skipped"
    ODL=false
fi

# =============================================================================
# Work directory, cmdfile, TNS alias
# =============================================================================
TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="$ROOT_DIR/log/$(date +%Y%m%d)/rwrun_trace_${TS}"
mkdir -p "$OUT_DIR/tns" && chmod 700 "$OUT_DIR"
CMDFILE="$OUT_DIR/.cmdfile"
LOGGING_BAK=""

_cleanup() {
    [ -f "$CMDFILE" ] && { shred -u "$CMDFILE" 2>/dev/null || rm -f "$CMDFILE"; }
    if [ -n "$LOGGING_BAK" ] && [ -f "$LOGGING_BAK" ]; then
        cp -p "$LOGGING_BAK" "$TOOLS_LOGGING" && rm -f "$LOGGING_BAK"
    fi
    TEST_DB_PWD=""
}
trap _cleanup EXIT INT TERM

# Reports tools resolve the DB via TNS: own alias, existing aliases kept
_tns_src="${TNS_ADMIN:-$DOMAIN_HOME/config/fmwconfig}/tnsnames.ora"
[ -f "$_tns_src" ] && cp "$_tns_src" "$OUT_DIR/tns/tnsnames.ora"
printf "\nIHW_TRACE_DB=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=%s)(PORT=%s))(CONNECT_DATA=(SERVICE_NAME=%s)))\n" \
    "$_DBH" "$_DBP" "$_DBS" >> "$OUT_DIR/tns/tnsnames.ora"
unset _tns_src

( umask 077; printf 'userid=%s/%s@IHW_TRACE_DB\n' "$TEST_DB_USER" "$TEST_DB_PWD" > "$CMDFILE" )
TEST_DB_PWD=""

OUTPUT="$OUT_DIR/output.${FORMAT,,}"
TRACE="$OUT_DIR/rwrun.trc"
CONSOLE="$OUT_DIR/console.txt"

printList "Work directory" 20 "$OUT_DIR"
printList "Trace options"  20 "$TRACEOPTS"
printList "Parameters"     20 "${PARAMS:-(none)}"
printList "ODL TRACE:32"   20 "$($ODL && printf yes || printf no)"

# =============================================================================
# ODL trace (optional, temporary)
# =============================================================================
if $ODL; then
    LOGGING_BAK="$OUT_DIR/logging.xml.orig"
    cp -p "$TOOLS_LOGGING" "$LOGGING_BAK"
    sed -i "s|\(<logger name='oracle.reports.runtime' level='\)[^']*'|\1TRACE:32'|" "$TOOLS_LOGGING"
    if grep -q "name='oracle.reports.runtime' level='TRACE:32'" "$TOOLS_LOGGING"; then
        ok "ODL logger oracle.reports.runtime = TRACE:32 (restored after the run)"
    else
        warn "ODL logger not found in logging.xml – ODL trace not active"
    fi
fi

# Positions before the run: new runtime log lines, new ADR incidents
RT_SIZE=0; [ -f "$RUNTIME_LOG" ] && RT_SIZE="$(stat -c %s "$RUNTIME_LOG")"
ADR_BEFORE="$(find "$ADR_BASE" -maxdepth 3 -type d -path '*/incident/incdir_*' 2>/dev/null | sort)"

# =============================================================================
# Run
# =============================================================================
section "Running rwrun"

args=( "report=$REPORT_FILE" "cmdfile=$CMDFILE" batch=yes
       destype=file "desformat=$FORMAT" "desname=$OUTPUT"
       "tracefile=$TRACE" tracemode=trace_replace "traceopts=$TRACEOPTS" )
# shellcheck disable=SC2206
[ -n "$PARAMS" ] && args+=( $PARAMS )

info "rwrun.sh report=$(basename "$REPORT_FILE") desformat=$FORMAT traceopts=$TRACEOPTS ${PARAMS}"
T0=$(date +%s)
TNS_ADMIN="$OUT_DIR/tns" timeout 900 "$RWRUN" "${args[@]}" > "$CONSOLE" 2>&1
RC=$?
T1=$(date +%s)
printList "Exit code"  20 "$RC  ($((T1 - T0)) s)"

# restore logging.xml now (trap is the safety net)
if [ -n "$LOGGING_BAK" ] && [ -f "$LOGGING_BAK" ]; then
    cp -p "$LOGGING_BAK" "$TOOLS_LOGGING" && rm -f "$LOGGING_BAK" && LOGGING_BAK=""
    ok "logging.xml restored"
fi

# =============================================================================
# Collect
# =============================================================================
section "Result"

if [ -s "$OUTPUT" ]; then
    ok "$(printf "Output: %s (%s bytes)" "$OUTPUT" "$(stat -c %s "$OUTPUT")")"
else
    fail "No output written ($OUTPUT)"
fi
[ "$RC" -eq 0 ] || fail "rwrun exit code $RC$( [ "$RC" -eq 124 ] && printf ' (timeout 900 s)' )"

# REP- / ORA- messages from console and trace
_msgs="$(cat "$CONSOLE" "$TRACE" 2>/dev/null | grep -oE '(REP|ORA)-[0-9]+.{0,100}' | sort -u | head -10)"
if [ -n "$_msgs" ]; then
    warn "Messages:"
    printf '%s\n' "$_msgs" | while IFS= read -r _m; do info "  $_m"; done
fi
unset _msgs

# New lines of the ODL runtime log
if [ -f "$RUNTIME_LOG" ]; then
    tail -c +"$((RT_SIZE + 1))" "$RUNTIME_LOG" > "$OUT_DIR/runtime_diagnostic_excerpt.log" 2>/dev/null
    _n="$(wc -l < "$OUT_DIR/runtime_diagnostic_excerpt.log")"
    info "runtime_diagnostic.log: ${_n} new lines -> runtime_diagnostic_excerpt.log"
    unset _n
fi

# New ADR incidents = hard crash of the native engine
ADR_AFTER="$(find "$ADR_BASE" -maxdepth 3 -type d -path '*/incident/incdir_*' 2>/dev/null | sort)"
_new="$(comm -13 <(printf '%s\n' "$ADR_BEFORE") <(printf '%s\n' "$ADR_AFTER") | sed '/^$/d')"
if [ -n "$_new" ]; then
    fail "New ADR incident(s) – native crash:"
    printf '%s\n' "$_new" | tee "$OUT_DIR/adr_incidents.txt" | while IFS= read -r _i; do info "  $_i"; done
fi
unset _new

printList "Trace file"   20 "$( [ -s "$TRACE" ] && printf '%s (%s lines)' "$TRACE" "$(wc -l < "$TRACE")" || printf 'none' )"
printList "Console"      20 "$CONSOLE"
info "All files: $OUT_DIR"

print_summary
exit "$EXIT_CODE"
