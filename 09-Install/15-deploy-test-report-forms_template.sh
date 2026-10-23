#!/bin/bash
# =============================================================================
# Script   : 15-deploy-test-report-forms_template.sh
# Purpose  : Smoke test of a Forms/Reports installation without Builder:
#            convert, compile and deploy the minimal Forms test module and
#            Reports demo report described in
#            docs/20-forms_reports_testmodules.md, then run the report through
#            the Reports server (rwservlet -> PDF).
#            No customer data, no business logic - just SYSDATE and a row
#            count from USER_OBJECTS.
#
#            Only the component(s) selected in INSTALL_COMPONENTS
#            (FORMS_ONLY | REPORTS_ONLY | FORMS_AND_REPORTS) are tested.
#
#            STATUS: VERIFIED end-to-end 2026-10-16 (FMW 14.1.2):
#              Forms   XML -> FMB (XML2Forms) -> FMX (frmcmp_batch)
#              Reports XML -> RDF (rwconverter) -> rwservlet -> PDF
#            Findings (details in docs/20, Live Test Log 2026-10-16):
#              - use the instance wrappers (frmxml2f.sh / frmcmp_batch.sh of
#                the Forms instance, $DOMAIN_HOME/reports/bin/rwconverter.sh)
#                - $ORACLE_HOME/bin/rwconverter alone aborts (SIGABRT,
#                Reports environment missing)
#              - Forms JDAPI needs FORMS_API_TK_BYPASS=TRUE, then no X
#                display is needed ("_jni_initialize: Failed to create new
#                forms context" otherwise)
#              - Forms tools split userid at "/": EZConnect host:port/service
#                fails silently ("Form not created") - a TNS alias is used
#                (alias of $TNS_ADMIN/tnsnames.ora with the test DB service;
#                temporary TNS_ADMIN only if environment.conf has none -
#                reports.sh of 13- overrides a temporary one for rwconverter)
#
# Call     : ./09-Install/15-deploy-test-report-forms_template.sh
#            ./09-Install/15-deploy-test-report-forms_template.sh --apply
# Options  : (none)    Dry-run: show what would be compiled/deployed
#            --apply   Convert + compile + deploy + run the report
#            --help    Show usage
# Requires : environment.conf (ORACLE_HOME, DOMAIN_HOME, DB_HOST/DB_PORT/
#              DB_SERVICE or TEST_DB_HOST/TEST_DB_PORT/TEST_DB_SERVICE,
#              FORMS_CUSTOMER_DIR, REPORTS_CUSTOMER_DIR, INSTALL_COMPONENTS)
#            test_db_sec.conf.des3 (TEST_DB_USER, TEST_DB_PWD - asked once
#              by this script on a terminal and stored encrypted)
#            forms_templates/test_form.xml, reports_templates/test_dual.xml
# Runs as  : oracle
# Ref      : 09-Install/docs/20-forms_reports_testmodules.md
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_SH="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
FORMS_TEMPLATE="$SCRIPT_DIR/forms_templates/test_form.xml"
REPORTS_TEMPLATE="$SCRIPT_DIR/reports_templates/test_dual.xml"
TEST_DB_SEC="$ROOT_DIR/test_db_sec.conf.des3"
TNS_ALIAS="IHW_SMOKE_DB"

if [ ! -f "$LIB_SH" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB_SH" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB_SH"

check_env_conf "$ROOT_DIR/environment.conf" || exit 2
# shellcheck source=../environment.conf
source "$ROOT_DIR/environment.conf"

# =============================================================================
# Arguments
# =============================================================================

APPLY=false

for _arg in "$@"; do
    case "$_arg" in
        --apply)    APPLY=true ;;
        --help|-h)
            printf "Usage: %s [--apply]\n\n" "$(basename "$0")"
            printf "  %-14s %s\n" "(none)"   "Dry-run: show what would be compiled/deployed"
            printf "  %-14s %s\n" "--apply"  "Convert + compile + deploy + run the report (PDF)"
            printf "  %-14s %s\n" "--help"   "Show this help"
            printf "\nOnly tests the component(s) selected in INSTALL_COMPONENTS.\n"
            printf "DB user/password: %s (asked once on a terminal).\n" "$(basename "$TEST_DB_SEC")"
            exit 0 ;;
        *) warn "Unknown argument: $_arg" ;;
    esac
done
unset _arg

# =============================================================================
# Log setup
# =============================================================================

LOG_FILE="$ROOT_DIR/log/$(date +%Y%m%d)/deploy_testmodules_$(date +%H%M%S).log"
mkdir -p "$(dirname "$LOG_FILE")"
{
    printf "# 15-deploy-test-report-forms_template.sh log\n"
    printf "# Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# Host    : %s\n" "$(_get_hostname)"
    printf "# Apply   : %s\n" "$APPLY"
} > "$LOG_FILE"

# =============================================================================
# Header
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – Forms/Reports Smoke Test\033[0m\n"        | tee -a "$LOG_FILE"
printf "  Host              : %s\n" "$(_get_hostname)"                        | tee -a "$LOG_FILE"
printf "  INSTALL_COMPONENTS: %s\n" "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" | tee -a "$LOG_FILE"
printf "  Apply             : %s\n" "$APPLY"                                   | tee -a "$LOG_FILE"
printf "  Log               : %s\n" "$LOG_FILE"                                | tee -a "$LOG_FILE"
printLine

# =============================================================================
# Component selection
# =============================================================================

section "Component Selection"

DEPLOY_FORMS=false
DEPLOY_REPORTS=false
FORMS_DEPLOYED=false
case "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" in
    FORMS_ONLY)        DEPLOY_FORMS=true ;;
    REPORTS_ONLY)      DEPLOY_REPORTS=true ;;
    FORMS_AND_REPORTS) DEPLOY_FORMS=true; DEPLOY_REPORTS=true ;;
    *)
        fail "Unknown INSTALL_COMPONENTS: ${INSTALL_COMPONENTS:-not set}"
        info "  Valid values: FORMS_ONLY | REPORTS_ONLY | FORMS_AND_REPORTS"
        EXIT_CODE=2; print_summary; exit "$EXIT_CODE" ;;
esac

$DEPLOY_FORMS \
    && ok "$(printf "Forms test module   selected (INSTALL_COMPONENTS=%s)" "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}")" \
    || info "$(printf "Forms test module   skipped  (INSTALL_COMPONENTS=%s)" "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}")"
$DEPLOY_REPORTS \
    && ok "$(printf "Reports demo report selected (INSTALL_COMPONENTS=%s)" "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}")" \
    || info "$(printf "Reports demo report skipped  (INSTALL_COMPONENTS=%s)" "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}")"

# =============================================================================
# Prerequisites
# =============================================================================

section "Prerequisites"

[ -n "${ORACLE_HOME:-}" ] && [ -d "$ORACLE_HOME" ] \
    && ok "ORACLE_HOME = $ORACLE_HOME" \
    || { fail "ORACLE_HOME not set or missing: ${ORACLE_HOME:-}"; EXIT_CODE=2; print_summary; exit "$EXIT_CODE"; }
[ -n "${DOMAIN_HOME:-}" ] && [ -d "$DOMAIN_HOME" ] \
    && ok "DOMAIN_HOME = $DOMAIN_HOME" \
    || { fail "DOMAIN_HOME not set or missing: ${DOMAIN_HOME:-}"; EXIT_CODE=2; print_summary; exit "$EXIT_CODE"; }

# --- Test database (may differ from the repository DB)
_DB_HOST="${TEST_DB_HOST:-${DB_HOST:-}}"
_DB_PORT="${TEST_DB_PORT:-${DB_PORT:-1521}}"
_DB_SERVICE="${TEST_DB_SERVICE:-${DB_SERVICE:-}}"
if [ -n "$_DB_HOST" ] && [ -n "$_DB_SERVICE" ]; then
    ok "$(printf "Test DB = %s:%s/%s" "$_DB_HOST" "$_DB_PORT" "$_DB_SERVICE")"
else
    fail "Test DB unknown - set DB_HOST/DB_SERVICE (or TEST_DB_HOST/TEST_DB_SERVICE) in environment.conf"
    EXIT_CODE=2
fi

# --- Test DB user/password (encrypted, never in environment.conf)
TEST_DB_USER="" TEST_DB_PWD=""
if [ -f "$TEST_DB_SEC" ]; then
    if load_secrets_file "$TEST_DB_SEC" > /dev/null 2>&1 && [ -n "$TEST_DB_USER" ] && [ -n "$TEST_DB_PWD" ]; then
        ok "Test DB user: $TEST_DB_USER (password from $(basename "$TEST_DB_SEC"))"
    else
        fail "Cannot read $TEST_DB_SEC - delete it and re-run on a terminal"
        EXIT_CODE=2
    fi
elif $APPLY && [ -t 0 ]; then
    info "Test DB user/password not stored yet -> $(basename "$TEST_DB_SEC")"
    info "  any schema with CREATE SESSION (reads only DUAL / USER_OBJECTS)"
    printf "  %-30s : " "Test DB user"; read -r TEST_DB_USER
    _pw2="x"
    while [ -n "$TEST_DB_USER" ] && { [ -z "$TEST_DB_PWD" ] || [ "$TEST_DB_PWD" != "$_pw2" ]; }; do
        printf "  %-30s : " "Test DB password"; read -rs TEST_DB_PWD; printf "\n"
        printf "  %-30s : " "Confirm password"; read -rs _pw2; printf "\n"
        [ "$TEST_DB_PWD" != "$_pw2" ] && printf "  Passwords do not match. Try again.\n"
    done
    unset _pw2
    if [ -n "$TEST_DB_USER" ] && [ -n "$TEST_DB_PWD" ]; then
        _write_secrets_file "$TEST_DB_SEC" "TEST_DB_USER=$TEST_DB_USER" "TEST_DB_PWD=$TEST_DB_PWD" \
            || EXIT_CODE=2
    else
        fail "No test DB user given"; EXIT_CODE=2
    fi
elif $APPLY; then
    fail "$(basename "$TEST_DB_SEC") missing - run this script once on a terminal (it asks user/password)"
    EXIT_CODE=2
else
    info "Dry-run - $(basename "$TEST_DB_SEC") missing: --apply on a terminal asks user/password"
fi
case "$TEST_DB_USER$TEST_DB_PWD" in
    *[/@\ \"\'\\]*) fail "Test DB user/password must not contain / @ quotes, backslash or blanks"; EXIT_CODE=2 ;;
esac

# --- Tools: wrappers of the instances (set the Forms/Reports environment)
FORMS_BIN="$DOMAIN_HOME/config/fmwconfig/components/FORMS/instances/${FORMS_INSTANCE_NAME:-forms1}/bin"
FRMXML2F="$FORMS_BIN/frmxml2f.sh"
FRMCMP="$FORMS_BIN/frmcmp_batch.sh"
RWCONVERTER="$DOMAIN_HOME/reports/bin/rwconverter.sh"

if $DEPLOY_FORMS; then
    [ -f "$FORMS_TEMPLATE" ] \
        && ok "Forms template found: $FORMS_TEMPLATE" \
        || { fail "Forms template missing: $FORMS_TEMPLATE"; EXIT_CODE=2; }
    if [ -x "$FRMXML2F" ] && [ -x "$FRMCMP" ]; then
        ok "Forms tools: $FORMS_BIN/{frmxml2f,frmcmp_batch}.sh"
    else
        fail "frmxml2f.sh / frmcmp_batch.sh not found in $FORMS_BIN"
        info "  Forms instance missing? - check 08-oracle_setup_domain.sh / FORMS_INSTANCE_NAME"
        DEPLOY_FORMS=false
    fi
    [ -n "${FORMS_CUSTOMER_DIR:-}" ] \
        && ok "FORMS_CUSTOMER_DIR = $FORMS_CUSTOMER_DIR" \
        || { fail "FORMS_CUSTOMER_DIR not set in environment.conf"; EXIT_CODE=2; }
fi

if $DEPLOY_REPORTS; then
    [ -f "$REPORTS_TEMPLATE" ] \
        && ok "Reports template found: $REPORTS_TEMPLATE" \
        || { fail "Reports template missing: $REPORTS_TEMPLATE"; EXIT_CODE=2; }
    if [ -x "$RWCONVERTER" ]; then
        ok "Reports tool: $RWCONVERTER"
    else
        fail "rwconverter.sh not found: $RWCONVERTER"
        info "  ReportsTools instance missing? - check 13-oracle_setup_reports.sh"
        DEPLOY_REPORTS=false
    fi
    [ -n "${REPORTS_CUSTOMER_DIR:-}" ] \
        && ok "REPORTS_CUSTOMER_DIR = $REPORTS_CUSTOMER_DIR" \
        || { fail "REPORTS_CUSTOMER_DIR not set in environment.conf"; EXIT_CODE=2; }
fi

[ "$EXIT_CODE" -ne 0 ] && { print_summary; exit "$EXIT_CODE"; }

if ! $DEPLOY_FORMS && ! $DEPLOY_REPORTS; then
    warn "Nothing to deploy – neither Forms nor Reports available/selected"
    print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# Dry-run exit
# =============================================================================

if ! $APPLY; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "Dry-run – use --apply to convert/compile, deploy and run."
    $DEPLOY_FORMS   && info "Would compile: $FORMS_TEMPLATE -> $FORMS_CUSTOMER_DIR/test_form.{fmb,fmx}"
    $DEPLOY_REPORTS && info "Would convert: $REPORTS_TEMPLATE -> $REPORTS_CUSTOMER_DIR/test_dual.rdf"
    $DEPLOY_REPORTS && info "Would run    : rwservlet report=test_dual.rdf desformat=pdf"
    print_summary
    exit "$EXIT_CODE"
fi

# =============================================================================
# Staging area + temporary TNS alias (cleaned up on exit)
# =============================================================================

STAGING="$(mktemp -d /tmp/ihw_testmodules_XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
chmod 700 "$STAGING"
# Forms tools split userid at "/" - EZConnect does not work, use an alias.
if [ -n "${TNS_ADMIN:-}" ]; then
    # One Oracle Net directory: reports.sh (13-) sets TNS_ADMIN for rwconverter
    # itself, a temporary directory would be ignored (ORA-12162, 2026-10-23) -
    # take the alias of the test DB service from $TNS_ADMIN/tnsnames.ora
    TNS_ALIAS="$(tns_alias_for_service "$_DB_SERVICE")"
    # the Forms tools (instances/<inst>/bin/frm*.sh) default to
    # $DOMAIN_HOME/config/fmwconfig unless TNS_ADMIN is exported
    export TNS_ADMIN
    if [ -n "$TNS_ALIAS" ]; then
        ok "$(printf "TNS alias %s (service %s) from %s/tnsnames.ora" "$TNS_ALIAS" "$_DB_SERVICE" "$TNS_ADMIN")"
    else
        fail "No alias with SERVICE_NAME=$_DB_SERVICE in $TNS_ADMIN/tnsnames.ora – add one there"
        print_summary; exit 2
    fi
else
    mkdir "$STAGING/tns"
    _tns_src="$DOMAIN_HOME/config/fmwconfig/tnsnames.ora"
    [ -f "$_tns_src" ] && cp "$_tns_src" "$STAGING/tns/tnsnames.ora"
    printf "\n%s=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=%s)(PORT=%s))(CONNECT_DATA=(SERVICE_NAME=%s)))\n" \
        "$TNS_ALIAS" "$_DB_HOST" "$_DB_PORT" "$_DB_SERVICE" >> "$STAGING/tns/tnsnames.ora"
    unset _tns_src
    export TNS_ADMIN="$STAGING/tns"
fi
_CONNECT="$TEST_DB_USER/$TEST_DB_PWD@$TNS_ALIAS"

# _deploy  src  dest_dir  - copy with backup of an existing file
_deploy() {
    local src="$1" dir="$2" dest
    dest="$dir/$(basename "$src")"
    if ! mkdir -p "$dir" 2>/dev/null; then
        fail "Cannot create $dir - create it as root and chown to $(id -un)"
        return 1
    fi
    [ -f "$dest" ] && cp "$dest" "$dest.bak_$(date +%Y%m%d_%H%M%S)"
    if cp "$src" "$dest"; then
        ok "Deployed: $dest"
    else
        fail "Copy failed: $dest"; return 1
    fi
}

# =============================================================================
# Forms: XML -> FMB -> FMX
# =============================================================================

if $DEPLOY_FORMS; then
    section "Forms Test Module"

    cp "$FORMS_TEMPLATE" "$STAGING/test_form.xml"

    # FORMS_API_TK_BYPASS=TRUE: JDAPI without Motif/X display (2026-10-16)
    info "Running: frmxml2f.sh OVERWRITE=YES USERID=*** test_form.xml"
    ( cd "$STAGING" && FORMS_API_TK_BYPASS=TRUE \
        "$FRMXML2F" OVERWRITE=YES "USERID=$_CONNECT" test_form.xml ) \
        2>&1 | grep -v '^$' | tee -a "$LOG_FILE"
    FRMXML2F_RC=${PIPESTATUS[0]}

    if [ "$FRMXML2F_RC" -ne 0 ] || [ ! -f "$STAGING/test_form.fmb" ]; then
        fail "XML2Forms failed (rc=$FRMXML2F_RC) – test_form.fmb not produced"
        info "  See docs/20-forms_reports_testmodules.md – Troubleshooting"
    else
        ok "XML2Forms succeeded: test_form.fmb"

        info "Running: frmcmp_batch.sh module=test_form.fmb userid=*** compile_all=yes"
        ( cd "$STAGING" && FORMS_API_TK_BYPASS=TRUE \
            "$FRMCMP" module=test_form.fmb "userid=$_CONNECT" \
                module_type=form compile_all=yes output_file=test_form.fmx ) \
            2>&1 | grep -v '^$' | tee -a "$LOG_FILE"
        FRMCMP_RC=${PIPESTATUS[0]}

        # frmcmp_batch returns 0 also for "Form not created" - check the file
        if [ ! -f "$STAGING/test_form.fmx" ]; then
            fail "frmcmp failed (rc=$FRMCMP_RC) – test_form.fmx not produced"
            info "  'Form not created' without a message = DB logon failed (user/password/TNS)"
        else
            ok "frmcmp succeeded: test_form.fmx (trigger compiled against the DB)"
            _deploy "$STAGING/test_form.fmb" "$FORMS_CUSTOMER_DIR" \
                && _deploy "$STAGING/test_form.fmx" "$FORMS_CUSTOMER_DIR" \
                && FORMS_DEPLOYED=true
        fi
    fi

    # --- Forms servlet: config=webstart must return a JNLP (formsweb.cfg
    # with Oracle's [webstart] section - 14- since 2026-10-16)
    _ct="$(curl -s -o /dev/null --max-time 60 -w '%{http_code} %{content_type}' \
             "http://localhost:${WLS_FORMS_PORT:-9001}/forms/frmservlet?config=webstart&form=test_form" 2>/dev/null)"
    case "$_ct" in
        200*jnlp*) ok "Forms servlet: config=webstart returns a JNLP (Java Web Start ready)" ;;
        200*)      warn "Forms servlet: config=webstart returns HTML, no JNLP - [webstart] missing in formsweb.cfg"
                   info "  Re-run 14-oracle_setup_forms.sh --apply, restart WLS_FORMS" ;;
        *)         warn "Forms servlet not reachable on localhost:${WLS_FORMS_PORT:-9001} (${_ct:-no answer}) - WLS_FORMS running?" ;;
    esac
    unset _ct
fi

# =============================================================================
# Reports: XML -> RDF -> run via rwservlet (PDF)
# =============================================================================

if $DEPLOY_REPORTS; then
    section "Reports Demo Report"

    cp "$REPORTS_TEMPLATE" "$STAGING/test_dual.xml"

    info "Running: rwconverter.sh userid=*** source=test_dual.xml stype=xmlfile dtype=rdffile"
    ( cd "$STAGING" && "$RWCONVERTER" "userid=$_CONNECT" batch=yes overwrite=yes \
             source=test_dual.xml stype=xmlfile dest=test_dual.rdf dtype=rdffile ) \
        2>&1 | grep -v '^$\|REP-0004' | tee -a "$LOG_FILE"
    RWCONVERTER_RC=${PIPESTATUS[0]}

    _rdf_ok=false
    if [ "$RWCONVERTER_RC" -ne 0 ] || [ ! -f "$STAGING/test_dual.rdf" ]; then
        fail "rwconverter failed (rc=$RWCONVERTER_RC) – test_dual.rdf not produced"
        info "  See docs/20-forms_reports_testmodules.md – Troubleshooting"
    else
        ok "rwconverter succeeded: test_dual.rdf"
        _deploy "$STAGING/test_dual.rdf" "$REPORTS_CUSTOMER_DIR" && _rdf_ok=true
    fi

    # --- Run through the Reports server. The engine resolves the DB itself
    # (EZConnect works there). With a cgicmd.dat key "default" (14b-, carries
    # server= and authid=) the key is used, otherwise server= directly.
    if $_rdf_ok; then
        _url="http://localhost:${WLS_REPORTS_PORT:-9002}/reports/rwservlet?report=test_dual.rdf&destype=cache&desformat=pdf"
        if [ -n "${CGICMD_DAT:-}" ] && grep -q '^default:' "$CGICMD_DAT" 2>/dev/null; then
            _url="${_url}&cmdkey=default"
            info "Running: rwservlet cmdkey=default report=test_dual.rdf desformat=pdf"
        else
            _url="${_url}&server=${REPORTS_SERVER_NAME:-repserver01}"
            info "Running: rwservlet server=${REPORTS_SERVER_NAME:-repserver01} report=test_dual.rdf desformat=pdf"
        fi
        # URL with password via curl config on stdin - not in the process list
        _http="$(printf 'url = "%s&userid=%s/%s@//%s:%s/%s"\n' "$_url" \
                    "$TEST_DB_USER" "$TEST_DB_PWD" "$_DB_HOST" "$_DB_PORT" "$_DB_SERVICE" \
                 | curl -s --max-time 180 -K - -o "$STAGING/test_dual.pdf" \
                        -w '%{http_code} %{time_total}' 2>/dev/null)"
        if [ "$(head -c 5 "$STAGING/test_dual.pdf" 2>/dev/null)" = "%PDF-" ]; then
            ok "$(printf "Report run OK: PDF %s bytes (HTTP %s, %ss)" \
                "$(wc -c < "$STAGING/test_dual.pdf")" "${_http%% *}" "${_http#* }")"
        else
            fail "Report run failed (HTTP ${_http%% *}) - no PDF returned"
            _rep="$(grep -ao 'REP-[0-9]*[^<"]\{0,100\}' "$STAGING/test_dual.pdf" 2>/dev/null | head -1)"
            [ -n "$_rep" ] && info "  $_rep"
            info "  HTTP 499 = login required (secured server without cmdkey) - see 14b-"
        fi
        unset _url _http _rep
    fi
    unset _rdf_ok
fi
unset _CONNECT TEST_DB_PWD

# =============================================================================
# How to start the test form (browsers have no Java plugin any more:
# Java Web Start or the Forms Standalone Launcher FSAL)
# =============================================================================

if ${FORMS_DEPLOYED:-false}; then
    section "Start the Test Form"
    # WLS_LISTEN_ADDRESS=localhost: WLS_FORMS only behind the NGINX proxy
    if [ "${WLS_LISTEN_ADDRESS:-localhost}" = "localhost" ]; then
        _fbase="https://${WLS_SERVER_FQDN:-$(_get_hostname)}/forms"
    else
        _fbase="http://${WLS_SERVER_FQDN:-$(_get_hostname)}:${WLS_FORMS_PORT:-9001}/forms"
    fi
    info "Login: Forms logon dialog (no userid in the URL - it would end up in history/logs)"
    info "Java Web Start (opens a .jnlp, needs javaws / OpenWebStart on the client):"
    info "  ${_fbase}/frmservlet?config=webstart&form=test_form"
    info "Standalone Launcher FSAL (client: Java 8+ and frmsal.jar from ${_fbase}/html/fsal.htm):"
    info "  java -jar frmsal.jar -url \"${_fbase}/frmservlet?config=standaloneapp&form=test_form\" -t 30000"
    info "Browser only (needs the Java plugin - modern browsers: 'Oracle Java is required'):"
    info "  ${_fbase}/frmservlet?form=test_form"
    info "Expected: IT_SYSDATE = server date/time, IT_OBJ_COUNT = USER_OBJECTS count of the schema"
    unset _fbase
fi

# =============================================================================
print_summary
exit "$EXIT_CODE"
