#!/bin/bash
# =============================================================================
# Script   : 00-install-status.sh
# Purpose  : Where does the installation stand? Read-only overview of all
#            installation steps in the order of 09-Install/README.md
#            (Phase 0 … 7d, Phase DB, APEX / ORDS) with the state of each step:
#              DONE        last --apply run rc 0 (check steps: any run)
#              DONE (WARN) last run rc 1
#              FAILED      last run rc >= 2 – the step must be repeated
#              DRY-RUN     only run without --apply so far
#              PRESENT     no --apply run in the history, but the result is
#                          on the system (done before the history existed, by
#                          hand, or a step outside the recorded folders)
#              not recorded  no run, no probe, but later steps of the same
#                          track are done – passed before the history existed
#              OPEN        not run, result not found – the first one is the
#                          "next step"
#              SKIP        not needed for this installation (environment.conf)
#            Source: log/run_history.csv (written by print_summary of every
#            script in 09-Install, 07-Maintenance, 08-SSL, 12-APEX-Ords,
#            60-RCU-DB-19c) + a short probe per step; prints the next step.
# Call     : ./09-Install/00-install-status.sh [--runs N] [--all-hosts]
#              --runs N     also show the last N rows of the run history
#              --all-hosts  count runs of every host in the history (default:
#                           only this host – a copied repository keeps log/)
# Runs as  : oracle or root (read-only)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/README.md (installation flow)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"

if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m Cannot find IHateWeblogic_lib.sh: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"
# environment.conf is optional here: before the interview it does not exist
HAVE_ENV=false
# shellcheck source=../environment.conf
[ -f "$ENV_CONF" ] && source "$ENV_CONF" && HAVE_ENV=true
# the status view itself is not an installation step
IHW_RUN_RECORDED=1

init_log

RUNS=0; ALL_HOSTS=false
while [ $# -gt 0 ]; do
    case "$1" in
        --runs)      RUNS="${2:?--runs needs a number}"; shift ;;
        --all-hosts) ALL_HOSTS=true ;;
        --help|-h)   sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 2 ;;
    esac
    shift
done

HIST="$(run_history_file)"
HOST="$(hostname -s 2>/dev/null)"

# DB values live in 60-RCU-DB-19c/environment_db.conf – read in a subshell,
# the file sets its own ORACLE_BASE / ORACLE_HOME
DB_CONF="$ROOT_DIR/60-RCU-DB-19c/environment_db.conf"
_db_val() { [ -f "$DB_CONF" ] && ( source "$DB_CONF" > /dev/null 2>&1; eval "printf '%s' \"\${$1:-}\"" ); }
DB_HOME_V="$(_db_val DB_ORACLE_HOME)"; DB_SID_V="$(_db_val DB_SID)"
SSL_SRC="$(sed -n 's/^SSL_CERT_SOURCE="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$ROOT_DIR/08-SSL/ssl.conf" 2>/dev/null | tail -1)"
COMP="${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}"

# =============================================================================
# Conditions + probes (cheap, read-only)
# =============================================================================
_c_db()      { [ "${LOCAL_REP_DB:-false}" = "true" ]; }
_c_apex()    { [ "${INSTALL_APEX:-false}" = "true" ]; }
_c_client()  { [ "${FORMS_CLIENT_DIST:-false}" = "true" ]; }
_c_forms()   { [ "$COMP" != "REPORTS_ONLY" ]; }
_c_reports() { [ "$COMP" != "FORMS_ONLY" ]; }
_c_custssl() { [ "$SSL_SRC" = "customer" ]; }
_c_localca() { [ "$SSL_SRC" != "customer" ]; }
_c_ol9()     { grep -q 'el9' /proc/version 2>/dev/null && _c_reports; }

# _any GLOB… – does at least one of the expanded paths exist (ls fails as soon
# as one of several globs matches nothing)
_any() { local f; for f in "$@"; do [ -e "$f" ] && return 0; done; return 1; }

_p_env()      { grep -q '^# === 09-INSTALL' "$ENV_CONF" 2>/dev/null; }
_p_sysctl()   { [ -f /etc/sysctl.d/99-oracle-fmw.conf ]; }
_p_pkgs()     { rpm -q motif > /dev/null 2>&1; }
_p_jdk()      { [ -x "${JDK_HOME:-/nonexistent}/bin/java" ]; }
_p_user()     { [ -f /etc/sudoers.d/oracle-fmw ] || id "${ORACLE_OS_USER:-oracle}" > /dev/null 2>&1; }
_p_nginx()    { [ -f /etc/nginx/conf.d/oracle-wls.conf ]; }
_p_nginxssl() { [ -d /etc/nginx/ssl ]; }
_p_cert()     { ls "$ROOT_DIR"/08-SSL/certs/* > /dev/null 2>&1; }
_p_wls()      { [ -d "${ORACLE_HOME:-/nonexistent}/wlserver" ]; }
_p_fr()       { [ -d "${ORACLE_HOME:-/nonexistent}/forms" ] || [ -d "${ORACLE_HOME:-/nonexistent}/reports" ]; }
_p_dbsec()    { [ -f "${DB_SYS_SEC_FILE:-$ROOT_DIR/db_sys_sec.conf.des3}" ]; }
_p_domain()   { [ -f "${DOMAIN_HOME:-/nonexistent}/config/config.xml" ]; }
_p_initenv()  { grep -q '^DIAG_LOG_DIR=' "$ENV_CONF" 2>/dev/null; }
_p_boot()     { [ -f "${DOMAIN_HOME:-/nonexistent}/servers/AdminServer/security/boot.properties" ]; }
_p_nm()       { [ -f "${DOMAIN_HOME:-/nonexistent}/nodemanager/nodemanager.properties" ]; }
_p_libnsl()   { [ -L "${ORACLE_HOME:-/nonexistent}/lib/libnsl.so.2" ]; }
_p_autostart(){ [ -f "/etc/systemd/system/fmw-${DOMAIN_NAME:-$(basename "${DOMAIN_HOME:-x}")}.service" ]; }
_p_client()   { ls "${FORMS_CLIENT_DIR:-/srv/formsWeb}"/* > /dev/null 2>&1; }
_p_dbconf()   { [ -f "$DB_CONF" ]; }
_p_dbhome()   { [ -n "$DB_HOME_V" ] && [ -x "$DB_HOME_V/bin/sqlplus" ]; }
_p_listener() { [ -n "$DB_HOME_V" ] && [ -f "$DB_HOME_V/network/admin/listener.ora" -o -f "${TNS_ADMIN:-/nonexistent}/listener.ora" ]; }
_p_db()       { [ -n "$DB_SID_V" ] && grep -q "^${DB_SID_V}:" /etc/oratab 2>/dev/null; }
_p_dbunit()   { _any /etc/systemd/system/oracle-db*.service /etc/systemd/system/*dbora*.service; }
_p_dbos()     { [ -f /etc/sysctl.d/60-oracle-db.conf ]; }
_p_audit()    { local d; d="$(_db_val DB_DATA_DIR)"; [ -n "$d" ] && _any "$d"/*/auditlog*.dbf "$d"/*/*/auditlog*.dbf; }
_p_apexsw()   { ls -d "${APEX_SW_BASE:-${ORACLE_BASE:-/u01/app/oracle}/product/apex}"/APEX_* > /dev/null 2>&1; }
_p_apexweb()  { ls -d "${APEX_WEB_DIR:-/srv/apex}"/apex_* > /dev/null 2>&1; }
_p_ords()     { ls -d "${APEX_ORDS_BASE:-${ORACLE_BASE:-/u01/app/oracle}/product/ords}"/ords_* > /dev/null 2>&1; }
_p_ordsnginx(){ ls /etc/nginx/oracle-wls.d/ords_*.conf > /dev/null 2>&1; }

# =============================================================================
# The installation flow (09-Install/README.md)
#   phase | user | spec | kind | condition | probe | shown command
#   spec  : script (relative) [+token must / -token must not be in the args]
#   kind  : apply (needs --apply) | check (any run) | opt (optional, not
#           blocking) | manual (outside the run history: probe only)
# =============================================================================
STEPS=(
"Setup|oracle|09-Install/01-setup-interview.sh|apply|-|_p_env|--apply"
"0|root|09-Install/00-root_os_network.sh|check|-|-|"
"0|root|09-Install/01-root_os_baseline.sh|apply|-|_p_sysctl|--apply  (then reboot)"
"0|root|09-Install/02-root_os_packages.sh|apply|-|_p_pkgs|--apply"
"0|root|09-Install/02b-root_os_java.sh -upgrade-jdk|apply|-|_p_jdk|--apply"
"0|root|09-Install/03-root_user_oracle.sh|apply|-|_p_user|--apply"
"0|root|09-Install/04-root_nginx.sh|apply|-|_p_nginx|--apply"
"0|oracle|08-SSL/ssl_customer_certs.sh|apply|_c_custssl|_p_cert|--apply"
"0|oracle|08-SSL/ssl_prepare_cert.sh|apply|_c_localca|_p_cert|LOCALCA --apply"
"0|root|09-Install/05-root_nginx_ssl.sh|apply|-|_p_nginxssl|--apply"
"1|oracle|09-Install/04-oracle_pre_checks.sh|check|-|-|"
"1|oracle|09-Install/04-oracle_pre_download.sh|check|-|-|[--apply --mos]"
"1|root|09-Install/02b-root_os_java.sh +upgrade-jdk|opt|-|-|--apply --upgrade-jdk"
"2|oracle|09-Install/05-oracle_install_weblogic.sh|apply|-|_p_wls|--apply"
"2|oracle|09-Install/05-oracle_patch_weblogic.sh|apply|-|-|--apply"
"3|oracle|09-Install/06-oracle_install_forms_reports.sh|apply|-|_p_fr|--apply"
"3|oracle|09-Install/06-oracle_patch_forms_reports.sh|apply|-|-|--apply"
"DB|oracle|60-RCU-DB-19c/00a-db_env_interview.sh|apply|_c_db|_p_dbconf|--apply"
"DB|root|60-RCU-DB-19c/00-root_db_os_baseline.sh|apply|_c_db|_p_dbos|--apply"
"DB|oracle|60-RCU-DB-19c/00b-db_cvu_check.sh|apply|_c_db|-|--apply"
"DB|oracle|60-RCU-DB-19c/01-db_install_software.sh|apply|_c_db|_p_dbhome|--apply"
"DB|oracle|60-RCU-DB-19c/02-db_setup_listener.sh|apply|_c_db|_p_listener|--apply"
"DB|oracle|60-RCU-DB-19c/03-db_create_database.sh|apply|_c_db|_p_db|--apply"
"DB|oracle|60-RCU-DB-19c/04-db_audit_setup.sh|apply|_c_db|_p_audit|--apply"
"DB|oracle|60-RCU-DB-19c/05-db_fmw_tablespace.sh|opt|_c_db|-|--apply"
"DB|oracle|60-RCU-DB-19c/06-db_rcu_profile.sh|apply|_c_db|-|--apply"
"DB|oracle|60-RCU-DB-19c/08-db_auto_start.sh|apply|_c_db|_p_dbunit|--apply"
"4|oracle|00-Setup/database_rcu_sec.sh|manual|-|_p_dbsec|--apply"
"4|oracle|09-Install/07-oracle_setup_repository.sh|apply|-|-|--apply"
"4|oracle|09-Install/08-oracle_setup_domain.sh|apply|-|_p_domain|--apply"
"5|oracle|09-Install/09-oracle_configure.sh|apply|-|-|--apply"
"6|oracle|00-Setup/init_env.sh|manual|-|_p_initenv|--apply"
"6|oracle|09-Install/10-oracle_boot_properties.sh|apply|-|_p_boot|--apply"
"6|oracle|09-Install/11-oracle_nodemanager.sh|apply|-|_p_nm|--apply"
"6|oracle|09-Install/12-oracle_reports_users.sh|apply|_c_reports|-|--apply"
"6|root|09-Install/13-root_reports_fix.sh|apply|_c_ol9|_p_libnsl|--apply"
"6|oracle|09-Install/13-oracle_setup_reports.sh|apply|_c_reports|-|--apply"
"6|oracle|09-Install/14-oracle_setup_forms.sh|apply|_c_forms|-|--apply"
"6|oracle|09-Install/14b-oracle_reports_fonts.sh|apply|_c_reports|-|--apply"
"7b|oracle|09-Install/15-deploy-test-report-forms_template.sh|apply|-|-|--apply"
"7c|oracle|09-Install/30-configure_autostart.sh|apply|-|_p_autostart|--apply"
"7d|oracle|09-Install/40-oracle_forms_client_bundle.sh|apply|_c_client|_p_client|--apply"
"APEX|oracle|12-APEX-Ords/01-prepare-database.sh|apply|_c_apex|_p_apexsw|--apply"
"APEX|oracle|12-APEX-Ords/02-install-apex.sh|apply|_c_apex|_p_apexweb|--apply"
"APEX|oracle|12-APEX-Ords/03-patch-apex.sh|opt|_c_apex|-|--apply"
"APEX|oracle|12-APEX-Ords/04-install-ords.sh|apply|_c_apex|_p_ords|--apply"
"APEX|oracle|12-APEX-Ords/05-setup-nginx.sh|apply|_c_apex|_p_ordsnginx|--apply"
"APEX|oracle|12-APEX-Ords/06-patch-ords.sh|opt|_c_apex|-|--apply"
)

# _runs SPEC – "apply_rc;apply_ts;any_rc;any_ts;count" of the matching runs
_runs() {
    local spec="$1" script plus="" minus="" t
    script="${spec%% *}"
    for t in ${spec#"$script"}; do
        case "$t" in +*) plus="--${t#+}" ;; -*) minus="--${t#-}" ;; esac
    done
    [ -f "$HIST" ] || { printf ';;;;0'; return; }
    # renamed scripts: runs recorded under the old name count for the new one
    # (60-RCU-DB-19c 04-/05-/06-/07-/07b- -> 02-/03-/04-/05-/06-, 2026-11-02)
    awk -F';' -v s="$script" -v p="$plus" -v m="$minus" -v h="$HOST" -v all="$ALL_HOSTS" '
        BEGIN { R["60-RCU-DB-19c/04-db_setup_listener.sh"] = "60-RCU-DB-19c/02-db_setup_listener.sh"
                R["60-RCU-DB-19c/05-db_create_database.sh"] = "60-RCU-DB-19c/03-db_create_database.sh"
                R["60-RCU-DB-19c/06-db_audit_setup.sh"]     = "60-RCU-DB-19c/04-db_audit_setup.sh"
                R["60-RCU-DB-19c/07-db_fmw_tablespace.sh"]  = "60-RCU-DB-19c/05-db_fmw_tablespace.sh"
                R["60-RCU-DB-19c/07b-db_rcu_profile.sh"]    = "60-RCU-DB-19c/06-db_rcu_profile.sh" }
        { sc = ($4 in R) ? R[$4] : $4 }
        NR > 1 && sc == s && (all == "true" || $2 == h) {
            a = " " $5 " "
            if (p != "" && !index(a, " " p " ")) next
            if (m != "" && index(a, " " m " ")) next
            n++; anyrc = $7; anyts = $1
            if ($6 == "yes") { aprc = $7; apts = $1 }
        }
        END { printf "%s;%s;%s;%s;%d", aprc, apts, anyrc, anyts, n }' "$HIST"
}

# =============================================================================
# Evaluate
# =============================================================================
printLine
section "Installation status – $(hostname -f 2>/dev/null) – $(date '+%Y-%m-%d %H:%M')"
printList "Run history" 16 "$HIST$( [ -f "$HIST" ] || printf ' (not yet written)')"
$HAVE_ENV || warn "environment.conf missing – start with the interview (09-Install/01-setup-interview.sh --apply)"
$HAVE_ENV && printList "Installation" 16 "$COMP, local RCU DB ${LOCAL_REP_DB:-false}, APEX ${INSTALL_APEX:-false}, client dist ${FORMS_CLIENT_DIST:-false}, cert ${SSL_SRC:-LOCALCA}"

# pass 1: state per step; pass 2: print. A step without a recorded run before
# the last done step of its track (main / DB / APEX) was done before the run
# history existed (or by hand) – "not recorded", not the next step.
_track() { case "$1" in DB) printf db ;; APEX) printf apex ;; *) printf main ;; esac; }
declare -a ST_STATE ST_LVL
declare -A LAST_DONE=()
_i=0
for _s in "${STEPS[@]}"; do
    IFS='|' read -r _ph _user _spec _kind _cond _probe _cmd <<< "$_s"
    if [ "$_cond" != "-" ] && ! $_cond; then
        ST_STATE[$_i]="SKIP (not needed)"; ST_LVL[$_i]=info; _i=$(( _i + 1 )); continue
    fi
    IFS=';' read -r _arc _ats _rc _ts _n <<< "$( [ "$_kind" = "manual" ] && printf ';;;;0' || _runs "$_spec")"
    [ "$_kind" = "check" ] && { _arc="$_rc"; _ats="$_ts"; }
    _state=""; _lvl=info
    if [ -n "$_arc" ]; then
        case "$_arc" in
            0) _state="DONE"        _lvl=ok ;;
            1) _state="DONE (WARN)" _lvl=ok ;;
            *) _state="FAILED (rc $_arc)" _lvl=fail ;;
        esac
        _state="$_state  ${_ats:0:16}"
        [ "$_n" -gt 1 ] && _state="$_state  ($_n runs)"
    elif [ "$_probe" != "-" ] && $_probe; then
        # the result is there – a dry-run in the history does not change that
        _state="PRESENT (no --apply run in the history)"; _lvl=ok
    elif [ -n "$_rc" ]; then
        _state="DRY-RUN only  ${_ts:0:16}"; _lvl=warn
    elif [ "$_kind" = "opt" ]; then
        _state="optional – not run"
    else
        _state="OPEN"; _lvl=warn
    fi
    case "$_state" in DONE*|PRESENT*) [ "$_kind" = "opt" ] || LAST_DONE[$(_track "$_ph")]=$_i ;; esac
    ST_STATE[$_i]="$_state"; ST_LVL[$_i]=$_lvl
    _i=$(( _i + 1 ))
done

N_DONE=0; N_TOTAL=0; NEXT=""; LAST_PH=""; _i=0
for _s in "${STEPS[@]}"; do
    IFS='|' read -r _ph _user _spec _kind _cond _probe _cmd <<< "$_s"
    _script="${_spec%% *}"
    if [ "$_ph" != "$LAST_PH" ]; then
        case "$_ph" in
            Setup) section "Setup – interview" ;;
            DB)    section "Phase DB – 19c RCU database (LOCAL_REP_DB)" ;;
            APEX)  section "APEX / ORDS beside Forms (INSTALL_APEX)" ;;
            *)     section "Phase $_ph" ;;
        esac
        LAST_PH="$_ph"
    fi
    _label="$(printf "%-7s %-52s" "[$_user]" "$_script$(case "$_spec" in *+upgrade-jdk*) printf ' --upgrade-jdk' ;; esac)")"
    _state="${ST_STATE[$_i]}"; _lvl="${ST_LVL[$_i]}"
    if [ "$_state" = "OPEN" ] && [ "$_i" -lt "${LAST_DONE[$(_track "$_ph")]:--1}" ]; then
        _state="not recorded (later steps done – before the history / by hand?)"; _lvl=info
    fi
    if [[ "$_state" != SKIP* ]]; then
        [ "$_kind" = "opt" ] || N_TOTAL=$(( N_TOTAL + 1 ))
        case "$_state" in
            DONE*|PRESENT*|"not recorded"*) [ "$_kind" = "opt" ] || N_DONE=$(( N_DONE + 1 )) ;;
            *)  if [ -z "$NEXT" ] && [ "$_kind" != "opt" ]; then
                    if [ "$_kind" = "manual" ] && [[ "$_script" != *.sh ]]; then
                        NEXT="[$_user] cd $(dirname "$_script") && $_cmd"
                    else
                        NEXT="[$_user] ./$_script${_cmd:+ $_cmd}"
                    fi
                fi ;;
        esac
    fi
    $_lvl "$(printf "%s %s" "$_label" "$_state")"
    _i=$(( _i + 1 ))
done

# =============================================================================
# Summary + next step
# =============================================================================
section "Progress"
_pct=0; [ "$N_TOTAL" -gt 0 ] && _pct=$(( N_DONE * 100 / N_TOTAL ))
_bar="$(printf '%*s' $(( _pct / 5 )) '' | tr ' ' '#')$(printf '%*s' $(( 20 - _pct / 5 )) '' | tr ' ' '.')"
ok "$(printf "[%s] %d %% – %d of %d required steps done, present or passed" "$_bar" "$_pct" "$N_DONE" "$N_TOTAL")"
if [ -n "$NEXT" ]; then
    info "Next step: $NEXT"
    info "  (order and details: 09-Install/README.md – a FAILED step: check its log, fix, run it again)"
else
    ok "All required steps done – validation: 09-Install/docs/90-oracle_validate.md"
fi
[ -f "$HIST" ] || info "No run history yet – states come from the probes only (PRESENT / OPEN)"

if [ "$RUNS" -gt 0 ] && [ -f "$HIST" ]; then
    section "Run history – last $RUNS rows"
    tail -n "$RUNS" "$HIST" | awk -F';' '$1 != "timestamp" { printf "  %s  %-8s %-6s %-46s apply=%-3s rc=%s  %s\n", substr($1,1,16), $2, $3, $4, $6, $7, $5 }' \
        | tee -a "${LOG_FILE:-/dev/null}"
fi

print_summary
exit "$EXIT_CODE"
