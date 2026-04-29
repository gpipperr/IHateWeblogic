#!/bin/bash
# =============================================================================
# Script   : 12-oracle_reports_users.sh
# Purpose  : Create WebLogic security realm users for Reports Server access
#            and configure the corresponding Application Roles and Policies.
#
#            Three users are set up:
#              1. weblogic → RW_ADMINISTRATOR  (Reports admin UI in EM)
#              2. monPrtgUser → RW_MONITOR     (getserverinfo / monitoring tools)
#              3. EXECREPORTS → RW_EXECREPORTS (report execution via cgicmd.dat)
#
# Call     : ./09-Install/12-oracle_reports_users.sh [--apply]
#
#            Without --apply : dry-run – show plan, no changes made
#            With    --apply : execute all steps via WLST
#
# Requires : environment.conf (WL_ADMIN_URL, ORACLE_HOME, DOMAIN_HOME)
#            weblogic_sec.conf.des3  (WebLogic admin credentials)
#            reports_users.conf.des3 (monitoring + exec user passwords;
#                                     created interactively on first run)
#            AdminServer must be RUNNING
#
# Source   : https://www.pipperr.de/dokuwiki/doku.php?id=forms:oracle_reports_14c_windows64
#            #reports_servlet_admin_oberflaeche_erlauben_-_monitoring_und_report_user_anlegen
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_SH="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"

# --- Source library -----------------------------------------------------------
if [ ! -f "$LIB_SH" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB_SH" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB_SH"

# --- Source environment.conf --------------------------------------------------
check_env_conf
# shellcheck source=../environment.conf
source "$ROOT_DIR/environment.conf"

# --- Arguments ----------------------------------------------------------------
APPLY=false
for _arg in "$@"; do
    case "$_arg" in
        --apply) APPLY=true ;;
        --help|-h)
            printf "Usage: %s [--apply]\n\n" "$(basename "$0")"
            printf "  %-14s %s\n" "--apply" "Execute all steps via WLST (default: dry-run)"
            printf "\nRequires AdminServer to be running.\n"
            printf "User credentials are read from reports_users.conf.des3\n"
            printf "or prompted interactively on first run.\n"
            exit 0 ;;
        *) warn "Unknown argument: $_arg" ;;
    esac
done
unset _arg

# --- Log setup ----------------------------------------------------------------
LOG_FILE="$ROOT_DIR/log/$(date +%Y%m%d)/reports_users_$(date +%H%M%S).log"
mkdir -p "$(dirname "$LOG_FILE")"
{
    printf "# 12-oracle_reports_users.sh log\n"
    printf "# Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# Host    : %s\n" "$(_get_hostname)"
    printf "# Apply   : %s\n" "$APPLY"
} > "$LOG_FILE"

# =============================================================================
# Header
# =============================================================================
printLine
printf "\n\033[1m  IHateWeblogic – Reports Server User Setup\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"   | tee -a "$LOG_FILE"
printf "  WL_ADMIN_URL: %s\n" "${WL_ADMIN_URL:-t3://localhost:7001}" | tee -a "$LOG_FILE"
printf "  Apply       : %s\n" "$APPLY"              | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"           | tee -a "$LOG_FILE"
printLine

# =============================================================================
# Default user names (can be overridden in environment.conf)
# =============================================================================
REPORTS_MON_USER="${REPORTS_MON_USER:-monPrtgUser}"
REPORTS_EXEC_USER="${REPORTS_EXEC_USER:-EXECREPORTS}"
REPORTS_USERS_SEC="$ROOT_DIR/reports_users.conf.des3"

# =============================================================================
# Prerequisites
# =============================================================================
section "Checking prerequisites"

# --- WLST ---
WLST_SH="${ORACLE_HOME}/oracle_common/common/bin/wlst.sh"
if [ ! -x "$WLST_SH" ]; then
    _alt="${WL_HOME:-${ORACLE_HOME}/wlserver}/common/bin/wlst.sh"
    if [ -x "$_alt" ]; then
        WLST_SH="$_alt"
    else
        fail "wlst.sh not found: $WLST_SH"
        info "  Check ORACLE_HOME in environment.conf"
        print_summary; exit "$EXIT_CODE"
    fi
fi
ok "wlst.sh found: $WLST_SH"

# --- AdminServer port ---
_wl_url="${WL_ADMIN_URL:-t3://localhost:7001}"
_admin_port="$(printf "%s" "$_wl_url" | sed 's|.*:||')"
_admin_port="${_admin_port:-7001}"
unset _wl_url _alt

if ss -tlnp 2>/dev/null | awk '{print $4}' | grep -q ":${_admin_port}$"; then
    ok "AdminServer port ${_admin_port} is listening"
else
    fail "AdminServer port ${_admin_port} not listening – is AdminServer running?"
    info "  Start AdminServer first: ./01-Run/startStop.sh start AdminServer --apply"
    print_summary; exit "$EXIT_CODE"
fi
unset _admin_port

# =============================================================================
# Load WebLogic credentials  (for WLST connect)
# =============================================================================
section "Loading WebLogic credentials"

if ! load_weblogic_password; then
    fail "Cannot load WebLogic credentials"
    info "  Run first: 00-Setup/weblogic_sec.sh --apply"
    print_summary; exit "$EXIT_CODE"
fi
if [ -z "${WL_USER:-}" ] || [ -z "${INTERNAL_WL_PWD:-}" ]; then
    fail "WL_USER or INTERNAL_WL_PWD empty after decryption"
    print_summary; exit "$EXIT_CODE"
fi
ok "WebLogic credentials loaded for user: $WL_USER"

# =============================================================================
# Load / collect Reports user credentials
# =============================================================================
section "Loading Reports user credentials"

REPORTS_MON_PWD=""
REPORTS_EXEC_PWD=""

_prompt_password() {
    local prompt="$1"
    local -n _ref="$2"
    local _p1 _p2
    while true; do
        printf "  %s: " "$prompt" >&2
        read -r -s _p1; printf "\n" >&2
        printf "  Confirm password: " >&2
        read -r -s _p2; printf "\n" >&2
        if [ -z "$_p1" ]; then
            printf "  Password must not be empty.\n" >&2
        elif [ "$_p1" != "$_p2" ]; then
            printf "  Passwords do not match – try again.\n" >&2
        else
            _ref="$_p1"
            return 0
        fi
    done
}

if [ -f "$REPORTS_USERS_SEC" ]; then
    if load_secrets_file "$REPORTS_USERS_SEC"; then
        # load_secrets_file sources the file – variables now set
        REPORTS_MON_USER="${REPORTS_MON_USER:-monPrtgUser}"
        REPORTS_EXEC_USER="${REPORTS_EXEC_USER:-EXECREPORTS}"
        ok "Reports user credentials loaded from: $REPORTS_USERS_SEC"
        info "  Monitor user : $REPORTS_MON_USER"
        info "  Exec user    : $REPORTS_EXEC_USER"
    else
        fail "Failed to decrypt: $REPORTS_USERS_SEC"
        print_summary; exit "$EXIT_CODE"
    fi
else
    info "No reports_users.conf.des3 found – credentials needed"
    if $APPLY; then
        printf "\n  Setting up monitoring user: \033[1m%s\033[0m\n" "$REPORTS_MON_USER"
        _prompt_password "Password for $REPORTS_MON_USER" REPORTS_MON_PWD

        printf "\n  Setting up execution user: \033[1m%s\033[0m\n" "$REPORTS_EXEC_USER"
        _prompt_password "Password for $REPORTS_EXEC_USER" REPORTS_EXEC_PWD

        # Save encrypted for future runs
        printf "\n"
        if _write_secrets_file "$REPORTS_USERS_SEC" \
            "REPORTS_MON_USER=$REPORTS_MON_USER" \
            "REPORTS_MON_PWD=$REPORTS_MON_PWD"   \
            "REPORTS_EXEC_USER=$REPORTS_EXEC_USER" \
            "REPORTS_EXEC_PWD=$REPORTS_EXEC_PWD"; then
            ok "Credentials saved to: $REPORTS_USERS_SEC"
        else
            warn "Could not save credentials – will prompt again next run"
        fi
    else
        info "  Dry-run: credential file will be created on first --apply run"
        REPORTS_MON_PWD="***"
        REPORTS_EXEC_PWD="***"
    fi
fi

# =============================================================================
# Show plan
# =============================================================================
section "Configuration plan"

printList "Admin user"     30 "$WL_USER  →  RW_ADMINISTRATOR"  | tee -a "$LOG_FILE"
printList "Monitor user"   30 "$REPORTS_MON_USER  →  RW_MONITOR (getserverinfo only)" | tee -a "$LOG_FILE"
printList "Exec user"      30 "$REPORTS_EXEC_USER  →  RW_EXECREPORTS (run reports)"   | tee -a "$LOG_FILE"
printList "cgicmd.dat key" 30 "authid=$REPORTS_EXEC_USER/<pwd>  (manual step)"        | tee -a "$LOG_FILE"

if ! $APPLY; then
    printf "\n"
    warn "Dry-run – use --apply to create users and assign roles"
    info "  Note: AdminServer must be running when using --apply"
    print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# Write WLST Python script
# =============================================================================
section "Preparing WLST script"

WLST_PY="$(mktemp /tmp/reports_users_XXXXXX.py)"
chmod 600 "$WLST_PY"

cat > "$WLST_PY" << 'WLST_EOF'
# Reports Server User Setup – Jython 2.7 / WebLogic 14c
# All sensitive values are passed via environment variables.
import os, sys

WL_USER   = os.environ.get('_IHW_WL_USER',   '')
WL_PWD    = os.environ.get('_IHW_WL_PWD',    '')
WL_URL    = os.environ.get('_IHW_WL_URL',    't3://localhost:7001')
MON_USER  = os.environ.get('_IHW_MON_USER',  'monPrtgUser')
MON_PWD   = os.environ.get('_IHW_MON_PWD',   '')
EXEC_USER = os.environ.get('_IHW_EXEC_USER', 'EXECREPORTS')
EXEC_PWD  = os.environ.get('_IHW_EXEC_PWD',  '')

APP             = 'reports'
WL_PRINCIPAL    = 'weblogic.security.principal.WLSUserImpl'
ROLE_PRINCIPAL  = 'oracle.security.jps.service.policystore.ApplicationRole'

# Sentinel-prefixed output so the Bash wrapper can parse results
def ihw(tag, msg):
    print('IHW:' + tag + ':' + msg)
    sys.stdout.flush()

# --- Helper: create Security Realm user ---------------------------------------
def create_realm_user(realm_path, username, password, description):
    ihw('STEP', 'create user: ' + username)
    try:
        cd(realm_path)
        cmo.createUser(username, password, description)
        ihw('USER_CREATED', username)
    except Exception as e:
        if 'already exists' in str(e).lower() or 'duplicate' in str(e).lower():
            ihw('USER_EXISTS', username)
        else:
            ihw('USER_ERROR', username + ': ' + str(e))
            raise

# --- Helper: create Application Role (idempotent) ----------------------------
def ensure_app_role(app_stripe, role_name):
    ihw('STEP', 'ensure role: ' + role_name)
    try:
        createAppRole(appStripe=app_stripe, appRoleName=role_name)
        ihw('ROLE_CREATED', role_name)
    except Exception as e:
        if 'already exists' in str(e).lower():
            ihw('ROLE_EXISTS', role_name)
        else:
            ihw('ROLE_ERROR', role_name + ': ' + str(e))
            raise

# --- Helper: grant user to Application Role ----------------------------------
def grant_role(app_stripe, role_name, principal_name):
    ihw('STEP', 'grant role: ' + principal_name + ' -> ' + role_name)
    try:
        grantAppRole(appStripe=app_stripe,
                     appRoleName=role_name,
                     principalClass=WL_PRINCIPAL,
                     principalName=principal_name)
        ihw('ROLE_GRANTED', principal_name + ' -> ' + role_name)
    except Exception as e:
        msg = str(e).lower()
        if 'already' in msg or 'exists' in msg:
            ihw('ROLE_ALREADY_GRANTED', principal_name + ' -> ' + role_name)
        else:
            ihw('ROLE_GRANT_ERROR', principal_name + ' -> ' + role_name + ': ' + str(e))
            raise

# --- Helper: grant permission to Application Role ----------------------------
def grant_perm(app_stripe, role_name, perm_class, perm_target):
    ihw('STEP', 'grant permission: ' + role_name + ' / ' + perm_class)
    try:
        grantPermission(appStripe=app_stripe,
                        principalClass=ROLE_PRINCIPAL,
                        principalName=role_name,
                        permClass=perm_class,
                        permTarget=perm_target,
                        permActions='ALL')
        ihw('PERM_GRANTED', role_name + ' / ' + perm_class)
    except Exception as e:
        msg = str(e).lower()
        if 'already' in msg or 'duplicate' in msg:
            ihw('PERM_EXISTS', role_name + ' / ' + perm_class)
        else:
            ihw('PERM_ERROR', role_name + ': ' + str(e))
            raise

# ===========================================================================
# Main
# ===========================================================================
try:
    ihw('CONNECT', WL_URL)
    connect(WL_USER, WL_PWD, WL_URL)
    domain_name = cmo.getName()
    realm_path = ('/SecurityConfiguration/' + domain_name
                  + '/Realms/myrealm/AuthenticationProviders/DefaultAuthenticator')
    ihw('DOMAIN', domain_name)

    # --- Step 1: weblogic -> RW_ADMINISTRATOR ---
    ihw('SECTION', '1 - weblogic -> RW_ADMINISTRATOR')
    grant_role(APP, 'RW_ADMINISTRATOR', WL_USER)

    # --- Step 2: Monitoring user ---
    ihw('SECTION', '2 - Monitoring user: ' + MON_USER)
    create_realm_user(realm_path, MON_USER, MON_PWD,
                      'Reports monitoring user – getserverinfo access only')
    ensure_app_role(APP, 'RW_MONITOR')
    grant_role(APP, 'RW_MONITOR', MON_USER)
    grant_perm(APP, 'RW_MONITOR',
               'oracle.reports.server.WebCommandPermission',
               'webcommands=showmyjobs,getjobid,showjobid,getserverinfo,showjobs server=*')

    # --- Step 3: Execution user ---
    ihw('SECTION', '3 - Execution user: ' + EXEC_USER)
    create_realm_user(realm_path, EXEC_USER, EXEC_PWD,
                      'Report execution user – cgicmd.dat authid parameter')
    ensure_app_role(APP, 'RW_EXECREPORTS')
    grant_role(APP, 'RW_EXECREPORTS', EXEC_USER)
    grant_perm(APP, 'RW_EXECREPORTS',
               'oracle.reports.server.ReportsPermission',
               'report=* server=* destype=* desformat=* allowcustomargs=true')

    ihw('DONE', 'All steps completed successfully')

except Exception as e:
    ihw('FATAL', str(e))
    sys.exit(1)
WLST_EOF

ok "WLST script written: $WLST_PY"

# =============================================================================
# Execute WLST
# =============================================================================
section "Running WLST"

WLST_LOG="$(dirname "$LOG_FILE")/wlst_reports_users_$(date +%H%M%S).log"

export _IHW_WL_USER="$WL_USER"
export _IHW_WL_PWD="$INTERNAL_WL_PWD"
export _IHW_WL_URL="${WL_ADMIN_URL:-t3://localhost:7001}"
export _IHW_MON_USER="$REPORTS_MON_USER"
export _IHW_MON_PWD="$REPORTS_MON_PWD"
export _IHW_EXEC_USER="$REPORTS_EXEC_USER"
export _IHW_EXEC_PWD="$REPORTS_EXEC_PWD"

info "WLST output log: $WLST_LOG"
"$WLST_SH" "$WLST_PY" 2>&1 | tee "$WLST_LOG"
WLST_RC="${PIPESTATUS[0]}"

unset _IHW_WL_USER _IHW_WL_PWD _IHW_WL_URL
unset _IHW_MON_USER _IHW_MON_PWD _IHW_EXEC_USER _IHW_EXEC_PWD
INTERNAL_WL_PWD=""
REPORTS_MON_PWD=""
REPORTS_EXEC_PWD=""

rm -f "$WLST_PY"

# =============================================================================
# Parse WLST sentinel output
# =============================================================================
section "Evaluating WLST results"

_parse_wlst_output() {
    local log_file="$1"
    local had_fatal=false

    while IFS=: read -r _prefix _tag _msg; do
        [ "$_prefix" = "IHW" ] || continue
        case "$_tag" in
            SECTION)
                printf "\n" | tee -a "$LOG_FILE"
                info "--- $_msg ---" ;;
            CONNECT|DOMAIN)
                info "$_tag: $_msg" ;;
            STEP)
                info "  $_msg" ;;
            USER_CREATED|ROLE_CREATED|ROLE_GRANTED|PERM_GRANTED)
                ok "$_tag: $_msg" ;;
            USER_EXISTS|ROLE_EXISTS|ROLE_ALREADY_GRANTED|PERM_EXISTS)
                ok "$(printf "%-22s %s" "already configured:" "$_msg")" ;;
            USER_ERROR|ROLE_ERROR|ROLE_GRANT_ERROR|PERM_ERROR)
                fail "$_tag: $_msg" ;;
            FATAL)
                fail "FATAL: $_msg"
                had_fatal=true ;;
            DONE)
                ok "$_msg" ;;
        esac
    done < "$log_file"

    if $had_fatal; then
        return 1
    fi
}

if ! _parse_wlst_output "$WLST_LOG"; then
    fail "WLST reported a fatal error – check log: $WLST_LOG"
elif [ "$WLST_RC" -ne 0 ]; then
    fail "WLST exited with rc=$WLST_RC – check log: $WLST_LOG"
else
    printf "\n" | tee -a "$LOG_FILE"
    info "Full WLST output: $WLST_LOG"
fi

# =============================================================================
# Next steps hint
# =============================================================================
if [ "$CNT_FAIL" -eq 0 ]; then
    printf "\n" | tee -a "$LOG_FILE"
    info "Next step: add authid to cgicmd.dat"
    info "  File: \$DOMAIN_HOME/config/fmwconfig/servers/WLS_REPORTS/applications/reports_14.1.2/configuration/cgicmd.dat"
    info "  Add after %2: authid=$REPORTS_EXEC_USER/<pwd>"
    info "  Restart WLS_REPORTS after cgicmd.dat change"
fi

# =============================================================================
print_summary
exit "$EXIT_CODE"
