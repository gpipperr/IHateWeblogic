#!/bin/bash
# =============================================================================
# Script   : 90-oracle_validate.sh
# Purpose  : Phase 7 - acceptance of a finished installation: calls the
#            read-only analyse scripts of 01-08/10 (no own check logic -
#            folder roles), adds a few direct checks for what the
#            installation steps set up (code signing, Node Manager, access
#            logs, autostart, HTTP through Nginx) and writes one summary.
#            Every step runs WITHOUT --apply - nothing is changed, except
#            with --smoke (smoke test 15- deploys its test modules).
# Call     : ./09-Install/90-oracle_validate.sh
#            ./09-Install/90-oracle_validate.sh --smoke
#            ./09-Install/90-oracle_validate.sh --skip-db --skip-ssl
# Options  : --smoke      also run 15-deploy-test-report-forms_template.sh --apply
#                         (compiles a Forms module, runs a report via rwservlet)
#            --skip-db    skip DB login, RCU repository check
#            --skip-ssl   skip the TLS checks (Nginx not configured yet)
#            --timeout N  timeout per step in seconds (default 600)
#            --help       Show usage
# Exit     : 0 all OK, 1 WARN only, 2 any FAIL (worst step)
# Runs as  : oracle - domain started (startStop.sh start-all)
# Ref      : 09-Install/docs/90-oracle_validate.md
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"

if [ ! -f "$LIB" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB" >&2; exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"
check_env_conf "$ENV_CONF" || exit 2
# shellcheck source=../environment.conf
source "$ENV_CONF"

DIAG_LOG_DIR="${DIAG_LOG_DIR:-$ROOT_DIR/log/$(date +%Y%m%d)}"
init_log "$DIAG_LOG_DIR"

# =============================================================================
# Arguments
# =============================================================================

SMOKE=false
SKIP_DB=false
SKIP_SSL=false
STEP_TIMEOUT=600

while [ $# -gt 0 ]; do
    case "$1" in
        --smoke)    SMOKE=true ;;
        --skip-db)  SKIP_DB=true ;;
        --skip-ssl) SKIP_SSL=true ;;
        --timeout)  [[ "${2:-}" =~ ^[0-9]+$ ]] || { printf "\033[31mERROR\033[0m --timeout needs seconds\n" >&2; exit 1; }
                    STEP_TIMEOUT="$2"; shift ;;
        --help|-h)
            printf "Usage: %s [--smoke] [--skip-db] [--skip-ssl] [--timeout N]\n\n" "$(basename "$0")"
            printf "  %-12s %s\n" "--smoke"    "also run the smoke test 15- --apply (deploys test modules)"
            printf "  %-12s %s\n" "--skip-db"  "skip DB login + RCU repository check"
            printf "  %-12s %s\n" "--skip-ssl" "skip the TLS checks"
            printf "  %-12s %s\n" "--timeout N" "timeout per step in seconds (default 600)"
            printf "\nRead-only (except --smoke). Domain must be running.\n"
            exit 0 ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
    shift
done

STEP_LOG_DIR="$DIAG_LOG_DIR/validate_$(date +%H%M%S)"
mkdir -p "$STEP_LOG_DIR"

# =============================================================================
# Header
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic - Installation Validation (Phase 7)\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"                            | tee -a "$LOG_FILE"
printf "  Date        : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"               | tee -a "$LOG_FILE"
printf "  DOMAIN_HOME : %s\n" "${DOMAIN_HOME:-?}"                           | tee -a "$LOG_FILE"
printf "  Options     : smoke=%s skip-db=%s skip-ssl=%s timeout=%ss\n" \
    "$SMOKE" "$SKIP_DB" "$SKIP_SSL" "$STEP_TIMEOUT"                         | tee -a "$LOG_FILE"
printf "  Step logs   : %s\n" "$STEP_LOG_DIR"                               | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"                                   | tee -a "$LOG_FILE"
printLine

# =============================================================================
# Step runner - every called script keeps its own OK/WARN/FAIL; here only
# its result line + its WARN / FAIL lines, the full output in the step log
# =============================================================================

RES_LABEL=(); RES_STATE=(); RES_LOG=()
WORST=0

_record() {   # label state(OK|WARN|FAIL|SKIP) log
    RES_LABEL+=("$1"); RES_STATE+=("$2"); RES_LOG+=("${3:--}")
    case "$2" in
        FAIL) WORST=2 ;;
        WARN) [ "$WORST" -lt 1 ] && WORST=1 ;;
    esac
}

# _step "label" script [args...]
_step() {
    local label="$1" script="$2"; shift 2
    local slog rc state
    slog="$STEP_LOG_DIR/$(printf '%02d' $(( ${#RES_LABEL[@]} + 1 )))_$(basename "$script" .sh).log"
    section "$label"
    if [ ! -x "$ROOT_DIR/$script" ]; then
        fail "Script not found: $script"
        _record "$label" FAIL; return
    fi
    printf "  %s %s\n" "$script" "$*" | tee -a "$LOG_FILE"
    ( cd "$ROOT_DIR" && timeout "$STEP_TIMEOUT" "./$script" "$@" ) > "$slog" 2>&1 < /dev/null
    rc=$?
    # the called script's WARN / FAIL lines (colour codes removed)
    sed 's/\x1b\[[0-9;]*m//g' "$slog" | grep -E '^(FAIL|WARN)  ' | head -8 \
        | while IFS= read -r _l; do printf "    %s\n" "$_l" | tee -a "$LOG_FILE"; done
    case "$rc" in
        0)   state=OK;   ok   "$label" ;;
        1)   state=WARN; warn "$label - warnings, see $slog" ;;
        124) state=FAIL; fail "$label - timeout after ${STEP_TIMEOUT}s, see $slog" ;;
        *)   state=FAIL; fail "$label - rc=$rc, see $slog" ;;
    esac
    _record "$label" "$state" "$slog"
}

_skip() { section "$1"; info "skipped ($2)"; _record "$1" SKIP; }

# _direct "label" OK|WARN|FAIL "message"  - result of a direct check
_direct() {
    case "$2" in
        OK)   ok   "$3" ;;
        WARN) warn "$3" ;;
        FAIL) fail "$3" ;;
        *)    info "$3" ;;
    esac
    _record "$1" "$2"
}

# =============================================================================
# 0. Installation progress (information only)
# =============================================================================

section "Installation progress (00-install-status.sh)"
( cd "$ROOT_DIR" && timeout 120 ./09-Install/00-install-status.sh ) 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g' | grep -E '\[[#.]+\]|Next step' | head -3 \
    | while IFS= read -r _l; do printf "    %s\n" "$_l" | tee -a "$LOG_FILE"; done
info "  (information only - full list: ./09-Install/00-install-status.sh)"

# =============================================================================
# 1. Analyse scripts of the library (read-only)
# =============================================================================

_step "OS (version, RAM, disk, ulimits)"          02-Checks/os_check.sh
_step "Java (JDK_HOME, bundled JDK)"               02-Checks/java_check.sh
_step "Ports"                                      02-Checks/port_check.sh
_step "JVM settings (SecureRandom, heap)"          02-Checks/weblogic_performance.sh
if $SKIP_DB; then
    _skip "DB listener / service"                   "--skip-db"
else
    # listener + service (no --login: that needs credentials saved with
    # db_connect_check.sh --new, which the installation never writes - the
    # real logins are checked by rcu_repository_check.sh below)
    _step "DB listener / service"                  02-Checks/db_connect_check.sh
fi
if $SKIP_SSL; then
    _skip "TLS - Nginx certificate"                 "--skip-ssl"
    _skip "TLS - WebLogic keystores / ports"        "--skip-ssl"
else
    _step "TLS - Nginx certificate"                08-SSL/ssl_config.sh
    _step "TLS - WebLogic keystores / ports"       02-Checks/ssl_check.sh
fi
if [ "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" != "FORMS_ONLY" ]; then
    _step "Reports server (getserverinfo, engines)" 01-Run/rwserver_status.sh
    _step "Reports engine parameters"               05-ReportsPerformance/engine_perf_settings.sh
fi
if [ "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" != "REPORTS_ONLY" ]; then
    _step "Forms configuration"                     06-FormsDiag/forms_settings.sh
    _step "Forms timeouts / limit / pooling"        06-FormsDiag/forms_perf_settings.sh
fi
_step "TNS_ADMIN everywhere"                       02-Checks/tns_admin_check.sh
_step "Loopback only / clone-capable"              02-Checks/clone_check.sh
_step "Outbound connections"                       02-Checks/egress_check.sh
if $SKIP_DB; then
    _skip "RCU repository"                          "--skip-db"
else
    _step "RCU repository"                         07-Maintenance/rcu_repository_check.sh
fi
_step "Certificate expiry (incl. cron)"            10-Monitoring/cert_expiry_check.sh

# =============================================================================
# 2. Direct checks - what the installation steps set up
# =============================================================================

section "Installation specifics (direct checks)"

_cfg="$DOMAIN_HOME/config/config.xml"

# Node Manager: Plain + credentials = admin user (08- / 11-)
_nmt="$(grep -m1 -o '<nm-type>[^<]*' "$_cfg" 2>/dev/null | sed 's/<nm-type>//')"
[ "$_nmt" = "Plain" ] \
    && _direct "Node Manager type" OK   "Node Manager type Plain (11-)" \
    || _direct "Node Manager type" FAIL "Node Manager type '${_nmt:-?}' - 09-Install/11-oracle_nodemanager.sh --apply"
_nmu="$(sed -n 's:.*<node-manager-username>\(.*\)</node-manager-username>.*:\1:p' "$_cfg" | head -1)"
_adm="${WLS_ADMIN_USER:-webadmin}"
[ "$_nmu" = "$_adm" ] \
    && _direct "Node Manager user" OK   "Node Manager user = admin user ($_adm)" \
    || _direct "Node Manager user" FAIL "Node Manager user '${_nmu:-?}' ≠ $_adm - 09-Install/11-oracle_nodemanager.sh --apply"

# Secured Reports server (13-, REPORTS_SECURITY=ldap)
if [ "${REPORTS_SECURITY:-ldap}" = "ldap" ] && [ "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" != "FORMS_ONLY" ]; then
    grep -q 'serviceInstanceRef ref="idstore.ldap.embedded"' "$DOMAIN_HOME/config/fmwconfig/jps-config-jse.xml" 2>/dev/null \
        && _direct "Reports security" OK   "Reports JSE identity store = embedded LDAP (13-)" \
        || _direct "Reports security" FAIL "Reports server not secured (jps-config-jse.xml) - 13-oracle_setup_reports.sh --apply"
fi

# Forms access log with time-taken (08-)
if [ "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" != "REPORTS_ONLY" ]; then
    grep -q 'time-taken' "$_cfg" \
        && _direct "Forms access log" OK   "WLS_FORMS access log with time-taken" \
        || _direct "Forms access log" WARN "time-taken missing - 06-FormsDiag/forms_perf_settings.sh --apply --fix-accesslog"
fi

# JACOB signed + active (14-)
if [ "${FORMS_WEBUTIL_JACOB:-false}" = "true" ]; then
    _jar="$ORACLE_HOME/forms/java/jacob.jar"
    _js="${JDK_HOME:-$ORACLE_HOME/oracle_common/jdk}/bin/jarsigner"
    _jout="$("$_js" -verify -verbose -certs "$_jar" 2>&1)"
    if ! printf '%s\n' "$_jout" | grep -q '^jar verified'; then
        _direct "jacob.jar signature" FAIL "jacob.jar not signed - 09-Install/14-oracle_setup_forms.sh --apply"
    else
        _exp="$(printf '%s\n' "$_jout" | grep -iE 'as early as|signer certificate will expire' \
            | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)"
        if printf '%s\n' "$_jout" | grep -q 'Timestamped by'; then
            _direct "jacob.jar signature" OK "jacob.jar signed + timestamped (certificate until ${_exp:-?})"
        else
            _days=$(( ( $(date -d "${_exp:-today}" +%s) - $(date +%s) ) / 86400 ))
            [ "$_days" -lt 90 ] \
                && _direct "jacob.jar signature" WARN "jacob.jar signed WITHOUT timestamp - invalid from $_exp ($_days days): renew + 14- --apply --resign" \
                || _direct "jacob.jar signature" OK   "jacob.jar signed without timestamp - valid until $_exp ($_days days)"
        fi
    fi
    _fw="$(ls "$DOMAIN_HOME"/config/fmwconfig/servers/"${WLS_FORMS_SERVER:-WLS_FORMS}"/applications/formsapp_*/config/formsweb.cfg 2>/dev/null | tail -1)"
    grep -q '^WebUtilArchive=.*jacob\.jar' "$_fw" 2>/dev/null \
        && _direct "jacob.jar active" OK   "WebUtilArchive contains jacob.jar" \
        || _direct "jacob.jar active" FAIL "jacob.jar not in WebUtilArchive - 09-Install/14-oracle_setup_forms.sh --apply"
    unset _jar _js _jout _exp _days _fw
fi

# Nginx access log with times (04-root_nginx.sh)
_ngx="/etc/nginx/conf.d/oracle-wls.conf"
if [ -r "$_ngx" ]; then
    grep -q 'ihw_timing' "$_ngx" \
        && _direct "Nginx timing log" OK   "Nginx access log with rt / urt / uct" \
        || _direct "Nginx timing log" WARN "Nginx log without times - 09-Install/04-root_nginx.sh --apply (root)"
fi

# HTTP: Forms servlet direct and through Nginx
if [ "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" != "REPORTS_ONLY" ]; then
    _c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://localhost:${WLS_FORMS_PORT:-9001}/forms/frmservlet")"
    [ "$_c" = "200" ] \
        && _direct "Forms servlet (WLS_FORMS)" OK   "frmservlet on localhost:${WLS_FORMS_PORT:-9001}: HTTP 200" \
        || _direct "Forms servlet (WLS_FORMS)" FAIL "frmservlet on localhost:${WLS_FORMS_PORT:-9001}: HTTP ${_c:-none}"
    if ! $SKIP_SSL; then
        _c="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 "https://localhost/forms/frmservlet")"
        [ "$_c" = "200" ] \
            && _direct "Forms through Nginx" OK   "https://localhost/forms/frmservlet: HTTP 200" \
            || _direct "Forms through Nginx" FAIL "https://localhost/forms/frmservlet: HTTP ${_c:-none} - Nginx / 05-root_nginx_ssl.sh"
    fi
fi

# Configuration backup present (09- / 14b-)
_bk="$(find "$ROOT_DIR/07-Maintenance/ConfigBackup" -mindepth 1 -maxdepth 1 -type d -name '20*' 2>/dev/null | wc -l)"
[ "$_bk" -gt 0 ] \
    && _direct "Config backup" OK   "$_bk configuration backup set(s) in 07-Maintenance/ConfigBackup" \
    || _direct "Config backup" WARN "no configuration backup - 07-Maintenance/backup_config.sh --apply"

# Autostart (Phase 7c - may come after this validation)
_unit="fmw-$(basename "$DOMAIN_HOME").service"
if systemctl is-enabled "$_unit" >/dev/null 2>&1; then
    _direct "Autostart" OK "systemd unit $_unit enabled"
else
    _direct "Autostart" WARN "systemd unit $_unit not enabled - Phase 7c: 09-Install/30-configure_autostart.sh --apply"
fi
unset _cfg _nmt _nmu _adm _ngx _c _bk _unit

# =============================================================================
# 3. Smoke test (only --smoke - writes test modules)
# =============================================================================

if $SMOKE; then
    _step "Smoke test Forms / Reports (15- --apply)" 09-Install/15-deploy-test-report-forms_template.sh --apply
else
    _skip "Smoke test Forms / Reports" "only with --smoke - deploys test modules"
fi

# =============================================================================
# Summary table
# =============================================================================

section "Validation result"
_n_ok=0; _n_warn=0; _n_fail=0; _n_skip=0
for _i in "${!RES_LABEL[@]}"; do
    case "${RES_STATE[$_i]}" in
        OK) _n_ok=$((_n_ok+1)) ;; WARN) _n_warn=$((_n_warn+1)) ;;
        FAIL) _n_fail=$((_n_fail+1)) ;; SKIP) _n_skip=$((_n_skip+1)) ;;
    esac
    printf "  %-5s %-44s %s\n" "${RES_STATE[$_i]}" "${RES_LABEL[$_i]}" \
        "$([ "${RES_LOG[$_i]}" != "-" ] && basename "${RES_LOG[$_i]}")" | tee -a "$LOG_FILE"
done
printf "\n  %d checks: %d OK, %d WARN, %d FAIL, %d skipped\n" \
    "${#RES_LABEL[@]}" "$_n_ok" "$_n_warn" "$_n_fail" "$_n_skip" | tee -a "$LOG_FILE"
case "$WORST" in
    0) ok   "Installation validated - ready for production" ;;
    1) warn "Validated with warnings - review them (may be acceptable for this environment)" ;;
    *) fail "Validation FAILED - resolve the FAIL items before going live" ;;
esac
info "Step logs: $STEP_LOG_DIR"
unset _i _n_ok _n_warn _n_fail _n_skip

printLine
print_summary
[ "$WORST" -gt "$EXIT_CODE" ] && EXIT_CODE="$WORST"
exit "$EXIT_CODE"
