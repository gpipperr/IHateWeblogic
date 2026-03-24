#!/bin/bash
# =============================================================================
# Script   : 08-oracle_setup_domain.sh
# Purpose  : Create the WebLogic domain for Oracle Forms & Reports 14.1.2
#            using WLST in silent/offline mode.
#            Creates AdminServer, WLS_FORMS, WLS_REPORTS.
#            All servers listen on WLS_LISTEN_ADDRESS (default: 127.0.0.1).
#            Run AFTER 07-oracle_setup_repository.sh --apply.
# Call     : ./09-Install/08-oracle_setup_domain.sh
#            ./09-Install/08-oracle_setup_domain.sh --apply
#            ./09-Install/08-oracle_setup_domain.sh --help
# Options  : (none)    Dry-run: show planned domain configuration
#            --apply   Create the domain (runs WLST)
#            --help    Show usage
# Runs as  : oracle
# Requires : weblogic_sec.conf.des3 (WLS admin password, written by
#              00-Setup/weblogic_sec.sh --apply)
#            db_sys_sec.conf.des3 (DB schema password, written by
#              00-Setup/database_rcu_sec.sh --apply)
#            09-Install/response_files/domain_config.py.template
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/docs/08-oracle_setup_domain.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"
WLS_SEC_FILE="$ROOT_DIR/weblogic_sec.conf.des3"
DB_SYS_SEC_FILE="$ROOT_DIR/db_sys_sec.conf.des3"
DOMAIN_PY_TEMPLATE="$SCRIPT_DIR/response_files/domain_config.py.template"

# --- Source library -----------------------------------------------------------
if [ ! -f "$LIB" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB" >&2; exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"

# --- Source environment.conf --------------------------------------------------
if [ ! -f "$ENV_CONF" ]; then
    printf "\033[31mFATAL\033[0m: environment.conf not found: %s\n" "$ENV_CONF" >&2
    printf "  Run first: 09-Install/01-setup-interview.sh --apply\n" >&2; exit 2
fi
# shellcheck source=../environment.conf
source "$ENV_CONF"

# --- Bootstrap log ------------------------------------------------------------
DIAG_LOG_DIR="${DIAG_LOG_DIR:-$ROOT_DIR/log/$(date +%Y%m%d)}"
init_log "$DIAG_LOG_DIR"

# =============================================================================
# Argument parsing
# =============================================================================

APPLY=false

for _arg in "$@"; do
    case "$_arg" in
        --apply) APPLY=true ;;
        --help)
            printf "Usage: %s [--apply] [--help]\n\n" "$0"
            printf "  (none)   Dry-run: show planned domain configuration\n"
            printf "  --apply  Create WebLogic domain via WLST\n"
            printf "  --help   Show this help\n\n"
            exit 0
            ;;
        *) warn "Unknown argument: $_arg (ignored)" ;;
    esac
done
unset _arg

# =============================================================================
# Header
# =============================================================================

printLine
printf "\n"
printf "\033[1m  IHateWeblogic – WebLogic Domain Setup\033[0m\n"
printf "  Host        : %s\n" "$(_get_hostname)"
printf "  Date        : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "  Apply       : %s\n" "$APPLY"
printf "  Log         : %s\n" "$LOG_FILE"
printLine

# =============================================================================
# Derived values
# =============================================================================

DOMAIN_NAME="$(basename "$DOMAIN_HOME")"
WLST_BIN="$ORACLE_HOME/oracle_common/common/bin/wlst.sh"

TPL_WLS="$ORACLE_HOME/wlserver/common/templates/wls/wls.jar"
TPL_JRF="$ORACLE_HOME/oracle_common/common/templates/wls/oracle.jrf_template.jar"
TPL_FORMS="$ORACLE_HOME/forms/common/templates/wls/forms_template.jar"
TPL_REPORTS="$ORACLE_HOME/reports/common/templates/wls/oracle.reports_app_template.jar"

# =============================================================================
# Pre-checks
# =============================================================================

section "Pre-checks"

ok "$(printf "ORACLE_HOME  = %s" "$ORACLE_HOME")"

[ -x "$WLST_BIN" ] \
    && ok "$(printf "wlst.sh found: %s" "$WLST_BIN")" \
    || { fail "wlst.sh not found: $WLST_BIN"; EXIT_CODE=2; }

for _tpl in "$TPL_WLS" "$TPL_JRF" "$TPL_FORMS" "$TPL_REPORTS"; do
    [ -f "$_tpl" ] \
        && ok "$(printf "Template      : %s" "$(basename "$_tpl")")" \
        || { fail "$(printf "Template missing: %s" "$_tpl")"; EXIT_CODE=2; }
done
unset _tpl

[ -f "$DOMAIN_PY_TEMPLATE" ] \
    && ok "$(printf "WLST template : %s" "$DOMAIN_PY_TEMPLATE")" \
    || { fail "WLST template missing: $DOMAIN_PY_TEMPLATE"; EXIT_CODE=2; }

[ -f "$WLS_SEC_FILE" ] \
    && ok "$(printf "WLS sec file  : %s" "$WLS_SEC_FILE")" \
    || { fail "WLS credentials not found: $WLS_SEC_FILE"; \
         fail "  Run first: 00-Setup/weblogic_sec.sh --apply"; EXIT_CODE=2; }

[ -f "$DB_SYS_SEC_FILE" ] \
    && ok "$(printf "DB sec file   : %s" "$DB_SYS_SEC_FILE")" \
    || { fail "DB credentials not found: $DB_SYS_SEC_FILE"; \
         fail "  Run first: 00-Setup/database_rcu_sec.sh --apply"; EXIT_CODE=2; }

[ "$EXIT_CODE" -ne 0 ] && { print_summary; exit $EXIT_CODE; }

# =============================================================================
# Decrypt credentials
# =============================================================================

section "Credentials"

unset WL_USER INTERNAL_WL_PWD WL_PASSWORD
if ! load_weblogic_password "$WLS_SEC_FILE"; then
    info "  Run first: 00-Setup/weblogic_sec.sh --apply"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi
[ -n "${WL_USER:-}" ] \
    && ok "$(printf "WLS admin user : %s" "$WL_USER")" \
    || { fail "WL_USER not found in $WLS_SEC_FILE"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
[ -n "${INTERNAL_WL_PWD:-}" ] \
    && ok "WLS admin password decrypted" \
    || { fail "WL_PASSWORD not found in $WLS_SEC_FILE"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

unset DB_SCHEMA_PWD
if ! load_secrets_file "$DB_SYS_SEC_FILE"; then
    info "  Run first: 00-Setup/database_rcu_sec.sh --apply"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi
[ -n "${DB_SCHEMA_PWD:-}" ] \
    && ok "DB schema password decrypted" \
    || { fail "DB_SCHEMA_PWD not found in $DB_SYS_SEC_FILE"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# =============================================================================
# Show planned domain configuration
# =============================================================================

section "Planned Domain Configuration"

printList "Domain name"        30 "$DOMAIN_NAME"
printList "DOMAIN_HOME"        30 "$DOMAIN_HOME"
printList "ORACLE_HOME"        30 "$ORACLE_HOME"
printList "Admin user"         30 "${WL_USER}"
printList "Admin listen"       30 "${WLS_LISTEN_ADDRESS}:${WLS_ADMIN_PORT}"
printList "WLS_FORMS listen"   30 "${WLS_LISTEN_ADDRESS}:${WLS_FORMS_PORT}"
printList "WLS_REPORTS listen" 30 "${WLS_LISTEN_ADDRESS}:${WLS_REPORTS_PORT}"
printList "NodeManager port"   30 "${WLS_NODEMANAGER_PORT}"
printList "DB connect"         30 "${DB_HOST}:${DB_PORT}/${DB_SERVICE}"
printList "Schema prefix"      30 "${DB_SCHEMA_PREFIX}"
printf "\n" | tee -a "$LOG_FILE"
printList "Templates" 30 "$(basename "$TPL_WLS")"
info "$(printf "%30s  %s" "" "$(basename "$TPL_JRF")")"
info "$(printf "%30s  %s" "" "$(basename "$TPL_FORMS")")"
info "$(printf "%30s  %s" "" "$(basename "$TPL_REPORTS")")"

printf "\n" | tee -a "$LOG_FILE"

if ! $APPLY; then
    info "Dry-run complete – use --apply to create the domain"
    print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# Safety check: abort if domain already exists
# =============================================================================

if [ -f "$DOMAIN_HOME/config/config.xml" ]; then
    fail "Domain already exists: $DOMAIN_HOME/config/config.xml"
    fail "  Delete it first or use a different DOMAIN_HOME."
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

# =============================================================================
# Build WLST Python script  (temp file, mode 600, deleted via trap)
# =============================================================================

WLST_PY_FILE="/tmp/domain_cfg_$$.py"

_cleanup_domain_py() {
    if [ -f "$WLST_PY_FILE" ]; then
        dd if=/dev/zero of="$WLST_PY_FILE" bs=1 \
            count="$(stat -c '%s' "$WLST_PY_FILE" 2>/dev/null || printf 512)" 2>/dev/null
        rm -f "$WLST_PY_FILE"
    fi
    INTERNAL_WL_PWD="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    DB_SCHEMA_PWD="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    unset INTERNAL_WL_PWD DB_SCHEMA_PWD
}

trap '_cleanup_domain_py' EXIT

section "WLST Script"

# Substitute all ##PLACEHOLDER## markers in the template
sed \
    -e "s|##ORACLE_HOME##|${ORACLE_HOME}|g" \
    -e "s|##DOMAIN_HOME##|${DOMAIN_HOME}|g" \
    -e "s|##DOMAIN_NAME##|${DOMAIN_NAME}|g" \
    -e "s|##WLS_ADMIN_USER##|${WL_USER}|g" \
    -e "s|##WLS_ADMIN_PWD##|${INTERNAL_WL_PWD}|g" \
    -e "s|##WLS_LISTEN_ADDRESS##|${WLS_LISTEN_ADDRESS}|g" \
    -e "s|##WLS_ADMIN_PORT##|${WLS_ADMIN_PORT}|g" \
    -e "s|##WLS_FORMS_PORT##|${WLS_FORMS_PORT}|g" \
    -e "s|##WLS_REPORTS_PORT##|${WLS_REPORTS_PORT}|g" \
    -e "s|##DB_HOST##|${DB_HOST}|g" \
    -e "s|##DB_PORT##|${DB_PORT}|g" \
    -e "s|##DB_SERVICE##|${DB_SERVICE}|g" \
    -e "s|##DB_SCHEMA_PWD##|${DB_SCHEMA_PWD}|g" \
    -e "s|##DB_SCHEMA_PREFIX##|${DB_SCHEMA_PREFIX}|g" \
    "$DOMAIN_PY_TEMPLATE" > "$WLST_PY_FILE"

chmod 600 "$WLST_PY_FILE"
ok "$(printf "WLST script written: %s (mode 600)" "$WLST_PY_FILE")"

# =============================================================================
# Run WLST
# =============================================================================

section "WLST createDomain"

printf "\n  WLST started: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
printf "  Domain     : %s\n" "$DOMAIN_HOME" | tee -a "$LOG_FILE"
printf "  Admin user : %s\n\n" "$WL_USER" | tee -a "$LOG_FILE"

"$WLST_BIN" "$WLST_PY_FILE" 2>&1 | tee -a "$LOG_FILE"
WLST_RC=${PIPESTATUS[0]}

printf "\n  WLST finished: %s  (rc=%s)\n" \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$WLST_RC" | tee -a "$LOG_FILE"

if [ "$WLST_RC" -ne 0 ]; then
    fail "WLST exited with rc=$WLST_RC"
    fail "  Check output above for Python/WLST error details"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi
ok "WLST completed successfully"

# =============================================================================
# Configure nodemanager.properties
# =============================================================================

section "NodeManager Configuration"

NM_PROPS="$DOMAIN_HOME/nodemanager/nodemanager.properties"
NM_BACKUP="${NM_PROPS}.bak.$(date +%Y%m%d_%H%M%S)"

if [ -f "$NM_PROPS" ]; then
    cp "$NM_PROPS" "$NM_BACKUP"
    ok "$(printf "Backup: %s" "$NM_BACKUP")"
fi

# Write nodemanager.properties (localhost only, no SSL)
cat > "$NM_PROPS" << EOF
ListenAddress=127.0.0.1
ListenPort=${WLS_NODEMANAGER_PORT}
SecureListener=false
LogLimit=0
PropertiesVersion=14.1.2
AuthenticationEnabled=true
NodeManagerHome=${DOMAIN_HOME}/nodemanager
JavaHome=${JDK_HOME}
LogFile=${DOMAIN_HOME}/nodemanager/nodemanager.log
LogLevel=INFO
EOF

ok "$(printf "nodemanager.properties written: %s" "$NM_PROPS")"
ok "$(printf "  ListenAddress = 127.0.0.1:%s" "$WLS_NODEMANAGER_PORT")"
ok "$(printf "  JavaHome      = %s" "$JDK_HOME")"

# =============================================================================
# Verify domain structure
# =============================================================================

section "Verification"

VERIFY_FAILS=0
for _path in \
    "$DOMAIN_HOME/config/config.xml" \
    "$DOMAIN_HOME/bin/startWebLogic.sh" \
    "$DOMAIN_HOME/bin/startManagedWebLogic.sh" \
    "$DOMAIN_HOME/nodemanager/nodemanager.properties"
do
    if [ -e "$_path" ]; then
        ok "$(printf "Found: %s" "$_path")"
    else
        warn "$(printf "Missing: %s" "$_path")"
        VERIFY_FAILS=$(( VERIFY_FAILS + 1 ))
    fi
done
unset _path

[ "$VERIFY_FAILS" -gt 0 ] && \
    warn "$VERIFY_FAILS expected file(s) not found – domain may be incomplete"

printf "\n" | tee -a "$LOG_FILE"
info "Next step: start AdminServer and verify domain"
info "  $DOMAIN_HOME/bin/startWebLogic.sh &"
info "  # wait ~60s, then:"
info "  curl -s http://${WLS_LISTEN_ADDRESS}:${WLS_ADMIN_PORT}/console/"

# =============================================================================
print_summary
exit "$EXIT_CODE"
