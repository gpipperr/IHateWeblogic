#!/bin/bash
# =============================================================================
# Script   : 15-deploy-test-report-forms_template.sh
# Purpose  : Convert, compile and deploy the minimal Forms test module and
#            Reports demo report described in
#            docs/20-forms_reports_testmodules.md, as a smoke test that this
#            installation can compile Forms/Reports and reach the database.
#            No customer data, no business logic — just SYSDATE and a row
#            count from USER_OBJECTS.
#
#            Only deploys the component(s) actually selected in
#            INSTALL_COMPONENTS (FORMS_ONLY | REPORTS_ONLY |
#            FORMS_AND_REPORTS) — if only one of Forms/Reports is installed,
#            only that half runs.
#
#            STATUS: PARTIALLY VERIFIED (2026-08-01 live test against FMW
#            14.1.2). The Forms XML "version" attribute and full end-to-end
#            success are still NOT confirmed — see
#            docs/20-forms_reports_testmodules.md Live Test Log for details.
#            Confirmed so far: XML2Forms/frmcmp/rwconverter tool locations,
#            that both Forms and Reports conversion need a working X
#            display, and that "frmxml2f" is not a binary but the Java class
#            oracle.forms.util.xmltools.XML2Forms in frmxmltools.jar.
#
# Call     : ./09-Install/15-deploy-test-report-forms_template.sh
#            ./09-Install/15-deploy-test-report-forms_template.sh --apply
# Options  : (none)    Dry-run: show what would be compiled/deployed
#            --apply   Convert + compile + deploy into customer directories
#            --help    Show usage
# Requires : environment.conf (ORACLE_HOME, JAVA_HOME, TEST_DB_CONNECT,
#              FORMS_CUSTOMER_DIR, REPORTS_CUSTOMER_DIR, INSTALL_COMPONENTS)
#            forms_templates/test_form.xml, reports_templates/test_dual.xml
#            A working X display (DISPLAY + Xvfb) for both Forms and Reports
#              conversion — confirmed required even in pure batch mode.
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
            printf "  %-14s %s\n" "--apply"  "Convert + compile + deploy into customer directories"
            printf "  %-14s %s\n" "--help"   "Show this help"
            printf "\nOnly deploys the component(s) selected in INSTALL_COMPONENTS.\n"
            printf "Requires a working X display (DISPLAY + Xvfb) for both Forms and Reports.\n"
            printf "STATUS: partially verified — see docs/20-forms_reports_testmodules.md\n"
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
printf "\n\033[1m  IHateWeblogic – Forms/Reports Test Module Deploy\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host              : %s\n" "$(_get_hostname)"                        | tee -a "$LOG_FILE"
printf "  INSTALL_COMPONENTS: %s\n" "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" | tee -a "$LOG_FILE"
printf "  Apply             : %s\n" "$APPLY"                                   | tee -a "$LOG_FILE"
printf "  Log               : %s\n" "$LOG_FILE"                                | tee -a "$LOG_FILE"
printLine
warn "STATUS: partially verified only – see docs/20-forms_reports_testmodules.md Live Test Log"

# =============================================================================
# Component selection
# =============================================================================

section "Component Selection"

DEPLOY_FORMS=false
DEPLOY_REPORTS=false
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
# Helper: find the first existing/executable tool from a list of candidate
# names. Confirmed by live test (2026-08-01) that frmcmp/rwconverter live
# directly under $ORACLE_HOME/bin/ (not forms/bin or reports/bin) — this
# helper is kept for robustness across installs, not because the name/path
# is still uncertain.
# =============================================================================

_find_tool() {
    local dir="$1"; shift
    local name
    for name in "$@"; do
        if [ -x "$dir/$name" ]; then
            printf '%s' "$dir/$name"
            return 0
        fi
    done
    return 1
}

# =============================================================================
# Prerequisites
# =============================================================================

section "Prerequisites"

[ -n "${ORACLE_HOME:-}" ] \
    && ok "ORACLE_HOME = $ORACLE_HOME" \
    || { fail "ORACLE_HOME not set in environment.conf"; EXIT_CODE=2; print_summary; exit "$EXIT_CODE"; }

[ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ] \
    && ok "JAVA_HOME = $JAVA_HOME" \
    || { fail "JAVA_HOME not set or java not executable (needed for XML2Forms)"; EXIT_CODE=2; print_summary; exit "$EXIT_CODE"; }

[ -n "${TEST_DB_CONNECT:-}" ] \
    && ok "TEST_DB_CONNECT is set" \
    || { fail "TEST_DB_CONNECT not set in environment.conf"; \
         info "  Add e.g.: TEST_DB_CONNECT=scott/tiger@//host:port/service"; \
         info "  See: 09-Install/docs/00-environment-setup.md"; \
         EXIT_CODE=2; print_summary; exit "$EXIT_CODE"; }

# Confirmed required (2026-08-01 live test) for both Forms and Reports
# conversion, even in pure batch mode — without it XML2Forms fails with
# "_jni_initialize: Failed to create new forms context" and rwconverter
# aborts (SIGABRT) as soon as it's given real arguments.
if [ -n "${DISPLAY:-}" ]; then
    ok "DISPLAY = $DISPLAY"
else
    warn "DISPLAY is not set – Forms/Reports conversion will likely fail"
    info "  Start Xvfb first, e.g.: Xvfb ${DISPLAY_VAR:-:99} -screen 0 1024x768x24 &"
    info "  Then: export DISPLAY=${DISPLAY_VAR:-:99}"
fi

# --- Forms: XML2Forms is a Java class (oracle.forms.util.xmltools.XML2Forms
# in frmxmltools.jar), not a standalone binary — confirmed 2026-08-01.
FRMXMLTOOL_CP=""
FRMCMP=""
if $DEPLOY_FORMS; then
    [ -f "$FORMS_TEMPLATE" ] \
        && ok "Forms template found: $FORMS_TEMPLATE" \
        || { fail "Forms template missing: $FORMS_TEMPLATE"; EXIT_CODE=2; }

    _frmjdapi_jar="$ORACLE_HOME/jlib/frmjdapi.jar"
    _frmxmltools_jar="$ORACLE_HOME/jlib/frmxmltools.jar"
    _xmlparser_jar="$ORACLE_HOME/oracle_common/modules/oracle.xdk/xmlparserv2.jar"
    if [ -f "$_frmjdapi_jar" ] && [ -f "$_frmxmltools_jar" ] && [ -f "$_xmlparser_jar" ]; then
        FRMXMLTOOL_CP="$_frmjdapi_jar:$_frmxmltools_jar:$_xmlparser_jar"
        ok "XML2Forms classpath resolved (frmxmltools.jar found)"
    else
        warn "frmxmltools.jar / frmjdapi.jar / xmlparserv2.jar not found under $ORACLE_HOME"
        info "  Forms may not be installed – check 06-oracle_install_forms_reports.sh"
        DEPLOY_FORMS=false
    fi
    unset _frmjdapi_jar _frmxmltools_jar _xmlparser_jar

    if $DEPLOY_FORMS; then
        FRMCMP="$(_find_tool "$ORACLE_HOME/bin" frmcmp_batch frmcmp)" \
            && ok "frmcmp found: $FRMCMP" \
            || { warn "frmcmp not found under $ORACLE_HOME/bin/"; DEPLOY_FORMS=false; }
    fi

    [ -n "${FORMS_CUSTOMER_DIR:-}" ] \
        && ok "FORMS_CUSTOMER_DIR = $FORMS_CUSTOMER_DIR" \
        || { fail "FORMS_CUSTOMER_DIR not set in environment.conf"; EXIT_CODE=2; }
fi

RWCONVERTER=""
if $DEPLOY_REPORTS; then
    [ -f "$REPORTS_TEMPLATE" ] \
        && ok "Reports template found: $REPORTS_TEMPLATE" \
        || { fail "Reports template missing: $REPORTS_TEMPLATE"; EXIT_CODE=2; }

    RWCONVERTER="$(_find_tool "$ORACLE_HOME/bin" rwconverter)" \
        && ok "rwconverter found: $RWCONVERTER" \
        || { warn "rwconverter not found under $ORACLE_HOME/bin/"; \
             info "  Reports may not be installed – check 06-oracle_install_forms_reports.sh"; \
             DEPLOY_REPORTS=false; }

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
    warn "Dry-run – use --apply to convert/compile and deploy."
    $DEPLOY_FORMS   && info "Would compile: $FORMS_TEMPLATE -> $FORMS_CUSTOMER_DIR/test_form.fmx"
    $DEPLOY_REPORTS && info "Would convert: $REPORTS_TEMPLATE -> $REPORTS_CUSTOMER_DIR/test_dual.rdf"
    print_summary
    exit "$EXIT_CODE"
fi

# =============================================================================
# Staging area (cleaned up on exit)
# =============================================================================

STAGING="$(mktemp -d /tmp/ihw_testmodules_XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

# =============================================================================
# Forms: XML -> FMB -> FMX
# =============================================================================

if $DEPLOY_FORMS; then
    section "Forms Test Module"

    cp "$FORMS_TEMPLATE" "$STAGING/test_form.xml"

    # XML2Forms is the real class behind "frmxml2f" (confirmed 2026-08-01).
    # Options must precede the filename; USERID= is uppercase (tool's own
    # usage text) and is genuinely required ("for record group queries").
    info "Running: java oracle.forms.util.xmltools.XML2Forms OVERWRITE=YES USERID=*** test_form.xml"
    ( cd "$STAGING" \
      && LD_LIBRARY_PATH="$JAVA_HOME/lib/server:$ORACLE_HOME/lib" \
         "$JAVA_HOME/bin/java" -classpath "$FRMXMLTOOL_CP" oracle.forms.util.xmltools.XML2Forms \
             OVERWRITE=YES "USERID=$TEST_DB_CONNECT" test_form.xml ) \
        2>&1 | tee -a "$LOG_FILE"
    FRMXML2F_RC=${PIPESTATUS[0]}

    if [ "$FRMXML2F_RC" -ne 0 ] || [ ! -f "$STAGING/test_form.fmb" ]; then
        fail "XML2Forms failed (rc=$FRMXML2F_RC) – test_form.fmb not produced"
        fail "  This is a known unverified step (Module 'version' attribute etc.)"
        info "  See docs/20-forms_reports_testmodules.md – Open Verification Points / JDAPI Plan B"
    else
        ok "XML2Forms succeeded: test_form.fmb"

        info "Running: frmcmp module=test_form.fmb ..."
        ( cd "$STAGING" \
          && LD_LIBRARY_PATH="$JAVA_HOME/lib/server:$ORACLE_HOME/lib" \
             "$FRMCMP" module=test_form.fmb "userid=$TEST_DB_CONNECT" \
                 module_type=form batch=yes compile_all=yes output_file=test_form.fmx ) \
            2>&1 | tee -a "$LOG_FILE"
        FRMCMP_RC=${PIPESTATUS[0]}

        if [ "$FRMCMP_RC" -ne 0 ] || [ ! -f "$STAGING/test_form.fmx" ]; then
            fail "frmcmp failed (rc=$FRMCMP_RC) – test_form.fmx not produced"
        else
            ok "frmcmp succeeded: test_form.fmx"

            mkdir -p "$FORMS_CUSTOMER_DIR"
            if [ -f "$FORMS_CUSTOMER_DIR/test_form.fmx" ]; then
                cp "$FORMS_CUSTOMER_DIR/test_form.fmx" \
                   "$FORMS_CUSTOMER_DIR/test_form.fmx.bak_$(date +%Y%m%d_%H%M%S)"
            fi
            cp "$STAGING/test_form.fmx" "$FORMS_CUSTOMER_DIR/test_form.fmx"
            ok "Deployed: $FORMS_CUSTOMER_DIR/test_form.fmx"
        fi
    fi
fi

# =============================================================================
# Reports: XML -> RDF
# =============================================================================

if $DEPLOY_REPORTS; then
    section "Reports Demo Report"

    cp "$REPORTS_TEMPLATE" "$STAGING/test_dual.xml"

    info "Running: rwconverter source=test_dual.xml stype=xmlfile dtype=rdffile"
    ( cd "$STAGING" \
      && LD_LIBRARY_PATH="$JAVA_HOME/lib/server:$ORACLE_HOME/lib" \
         "$RWCONVERTER" "userid=$TEST_DB_CONNECT" batch=yes overwrite=yes \
             source=test_dual.xml stype=xmlfile dest=test_dual.rdf dtype=rdffile ) \
        2>&1 | tee -a "$LOG_FILE"
    RWCONVERTER_RC=${PIPESTATUS[0]}

    if [ "$RWCONVERTER_RC" -ne 0 ] || [ ! -f "$STAGING/test_dual.rdf" ]; then
        fail "rwconverter failed (rc=$RWCONVERTER_RC) – test_dual.rdf not produced"
        info "  See docs/20-forms_reports_testmodules.md – Open Verification Points"
    else
        ok "rwconverter succeeded: test_dual.rdf"

        mkdir -p "$REPORTS_CUSTOMER_DIR"
        if [ -f "$REPORTS_CUSTOMER_DIR/test_dual.rdf" ]; then
            cp "$REPORTS_CUSTOMER_DIR/test_dual.rdf" \
               "$REPORTS_CUSTOMER_DIR/test_dual.rdf.bak_$(date +%Y%m%d_%H%M%S)"
        fi
        cp "$STAGING/test_dual.rdf" "$REPORTS_CUSTOMER_DIR/test_dual.rdf"
        ok "Deployed: $REPORTS_CUSTOMER_DIR/test_dual.rdf"
    fi
fi

# =============================================================================
# Next steps
# =============================================================================

printf "\n" | tee -a "$LOG_FILE"
info "Next: verify manually, e.g."
$DEPLOY_FORMS && info "  $FRMCMP module=$FORMS_CUSTOMER_DIR/test_form.fmx userid=\$TEST_DB_CONNECT module_type=form batch=yes"
$DEPLOY_REPORTS && info "  rwclient server=<rep_server> report=$REPORTS_CUSTOMER_DIR/test_dual.rdf userid=\$TEST_DB_CONNECT destype=cache desformat=pdf"

# =============================================================================
print_summary
exit "$EXIT_CODE"
