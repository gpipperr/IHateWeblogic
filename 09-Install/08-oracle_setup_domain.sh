#!/bin/bash
# =============================================================================
# Script   : 08-oracle_setup_domain.sh
# Purpose  : Create the WebLogic domain for Oracle Forms & Reports 14.1.2
#            using WLST in silent/offline mode.
#            Creates AdminServer, WLS_FORMS, WLS_REPORTS – per INSTALL_COMPONENTS
#            only the installed half (REPORTS_ONLY: no WLS_FORMS/forms1,
#            FORMS_ONLY: no WLS_REPORTS/Reports components).
#            Afterwards the JDK path is reset to the JDK_HOME symlink
#            (07-Maintenance/domain_jdk_path.sh).
#            All servers listen on WLS_LISTEN_ADDRESS (default: 127.0.0.1).
#            Run AFTER 07-oracle_setup_repository.sh --apply – checked before
#            WLST: login as <prefix>_OPSS (schemas present, password valid),
#            no existing config.xml.
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
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$_arg" >&2; exit 1 ;;
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
TPL_REPSRV="$ORACLE_HOME/ReportsServerComponent/common/templates/wls/oracle.reports_server_template.jar"

# Components from INSTALL_COMPONENTS – the domain gets only the managed servers
# of the installed products (Reports-only: no WLS_FORMS / forms1, 2026-10-15)
WITH_FORMS=true
WITH_REPORTS=true
case "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" in
    FORMS_AND_REPORTS) ;;
    FORMS_ONLY)        WITH_REPORTS=false ;;
    REPORTS_ONLY)      WITH_FORMS=false ;;
    *)
        fail "Unknown INSTALL_COMPONENTS: $INSTALL_COMPONENTS (FORMS_AND_REPORTS | FORMS_ONLY | REPORTS_ONLY)"
        print_summary; exit 2
        ;;
esac

TEMPLATES=("$TPL_WLS" "$TPL_JRF")
$WITH_FORMS   && TEMPLATES+=("$TPL_FORMS")
$WITH_REPORTS && TEMPLATES+=("$TPL_REPORTS" "$TPL_REPSRV")

# =============================================================================
# Pre-checks
# =============================================================================

section "Pre-checks"

ok "$(printf "ORACLE_HOME  = %s" "$ORACLE_HOME")"

[ -x "$WLST_BIN" ] \
    && ok "$(printf "wlst.sh found: %s" "$WLST_BIN")" \
    || { fail "wlst.sh not found: $WLST_BIN"; EXIT_CODE=2; }

for _tpl in "${TEMPLATES[@]}"; do
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
printList "INSTALL_COMPONENTS" 30 "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}"
$WITH_FORMS   && printList "WLS_FORMS listen"   30 "${WLS_LISTEN_ADDRESS}:${WLS_FORMS_PORT}"
$WITH_REPORTS && printList "WLS_REPORTS listen" 30 "${WLS_LISTEN_ADDRESS}:${WLS_REPORTS_PORT}"
printList "NodeManager port"   30 "${WLS_NODEMANAGER_PORT}"
printList "DB connect"         30 "${DB_HOST}:${DB_PORT}/${DB_SERVICE}"
printList "Schema prefix"      30 "${DB_SCHEMA_PREFIX}"
printf "\n" | tee -a "$LOG_FILE"
printList "Templates" 30 "$(basename "${TEMPLATES[0]}")"
for _tpl in "${TEMPLATES[@]:1}"; do
    info "$(printf "%30s  %s" "" "$(basename "$_tpl")")"
done
unset _tpl
$WITH_FORMS   || info "$(printf "%30s  %s" "" "(no Forms template – INSTALL_COMPONENTS=REPORTS_ONLY)")"
$WITH_REPORTS || info "$(printf "%30s  %s" "" "(no Reports templates – INSTALL_COMPONENTS=FORMS_ONLY)")"

printf "\n" | tee -a "$LOG_FILE"

# =============================================================================
# Repository check: RCU schemas present, schema password valid
#
# writeDomain needs <prefix>_OPSS (security store) and the other RCU schemas.
# Without them WLST fails only after minutes in the "OPSS Processing" phase and
# leaves a partial DOMAIN_HOME. One login as <prefix>_OPSS (read-only) proves
# DB reachable + schema exists + password right + account open.
# =============================================================================

section "Repository"

if [ -f "$DOMAIN_HOME/config/config.xml" ]; then
    if $APPLY; then
        fail "Domain already exists: $DOMAIN_HOME/config/config.xml"
        fail "  Delete it first (and re-create the RCU schemas, see docs) or use a different DOMAIN_HOME."
        EXIT_CODE=2
    else
        warn "Domain already exists: $DOMAIN_HOME/config/config.xml – --apply would refuse"
    fi
elif [ -d "$DOMAIN_HOME" ] && [ -n "$(ls -A "$DOMAIN_HOME" 2>/dev/null)" ]; then
    warn "DOMAIN_HOME exists without config.xml (partial domain?) – WLST overwrites it"
fi

if ! timeout 3 bash -c ">/dev/null </dev/tcp/${DB_HOST}/${DB_PORT}" 2>/dev/null; then
    fail "Cannot reach ${DB_HOST}:${DB_PORT} – listener down or firewall?"
    EXIT_CODE=2
elif [ -x "$ORACLE_HOME/bin/sqlplus" ]; then
    _opss="${DB_SCHEMA_PREFIX^^}_OPSS"
    _out="$(LD_LIBRARY_PATH="$ORACLE_HOME/lib" "$ORACLE_HOME/bin/sqlplus" -S -L /nolog 2>&1 <<SQLEOF
CONNECT ${_opss}/"${DB_SCHEMA_PWD}"@//${DB_HOST}:${DB_PORT}/${DB_SERVICE}
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT 'IHW:LOGIN_OK' FROM DUAL;
EXIT;
SQLEOF
)"
    if printf '%s\n' "$_out" | grep -q 'IHW:LOGIN_OK'; then
        ok "Login ${_opss} on ${DB_HOST}:${DB_PORT}/${DB_SERVICE} – RCU schemas present"
    else
        _ora="$(printf '%s\n' "$_out" | grep -m1 -oE 'ORA-[0-9]+[^[:cntrl:]]*')"
        fail "Login ${_opss} failed: ${_ora:-no answer}"
        case "$_ora" in
            ORA-01017*) info "  Schema missing (RCU not run for prefix ${DB_SCHEMA_PREFIX}) or wrong DB_SCHEMA_PWD:"
                        info "  09-Install/07-oracle_setup_repository.sh --apply" ;;
            ORA-28000*) info "  Account locked: 09-Install/07-oracle_setup_repository.sh --profile, then unlock" ;;
            ORA-28001*) info "  Password expired: 09-Install/07-oracle_setup_repository.sh --profile" ;;
            ORA-12514*) info "  Service ${DB_SERVICE} not registered at the listener (DB_SERVICE = PDB name?)" ;;
        esac
        EXIT_CODE=2
    fi
    unset _opss _out _ora
else
    warn "sqlplus not found in ORACLE_HOME – RCU schemas not checked"
fi

if [ "$EXIT_CODE" -ge 2 ]; then
    print_summary; exit $EXIT_CODE
fi

if ! $APPLY; then
    info "Dry-run complete – use --apply to create the domain"
    print_summary; exit "$EXIT_CODE"
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
    -e "s|##WITH_FORMS##|${WITH_FORMS}|g" \
    -e "s|##WITH_REPORTS##|${WITH_REPORTS}|g" \
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

_log_lines_before=$(wc -l < "$LOG_FILE")
"$WLST_BIN" "$WLST_PY_FILE" 2>&1 | tee -a "$LOG_FILE"
WLST_RC=${PIPESTATUS[0]}

printf "\n  WLST finished: %s  (rc=%s)\n" \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$WLST_RC" | tee -a "$LOG_FILE"

if [ "$WLST_RC" -ne 0 ]; then
    fail "WLST exited with rc=$WLST_RC"
    # The OPSS security store in <prefix>_OPSS is bound to the domain that
    # created it – a new domain cannot reuse it (confirmed 2026-10-15)
    if tail -n +"$((_log_lines_before + 1))" "$LOG_FILE" \
         | grep -q "is already in use for security store"; then
        fail "  ${DB_SCHEMA_PREFIX}_OPSS still holds the security store of a previous domain"
        info "  A new domain needs fresh RCU schemas (the old domain's OPSS data is lost anyway):"
        info "    rm -rf $DOMAIN_HOME                                  (partial domain from this run)"
        info "    09-Install/07-oracle_setup_repository.sh --drop"
        [ -n "${RCU_TABLESPACE:-}" ] && \
            info "    60-RCU-DB-19c/05-db_fmw_tablespace.sh --apply        (drop removes ${RCU_TABLESPACE})"
        info "    09-Install/07-oracle_setup_repository.sh --apply"
        info "    09-Install/08-oracle_setup_domain.sh --apply"
    else
        fail "  Check output above for Python/WLST error details"
    fi
    [ -d "$DOMAIN_HOME" ] && [ ! -f "$DOMAIN_HOME/config/config.xml" ] && \
        warn "  Partial domain directory left behind: $DOMAIN_HOME – remove it before re-running"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi
ok "WLST completed successfully"
# The template's helpers try cd() first and create the MBean when it is
# missing - WLST prints "Error: cd() failed" / "runCmd() failed" for each try
# even though the except branch handles it. Expected on a fresh domain:
# CoherenceMemberConfig (per managed server) + WebServerLog (WLS_FORMS).
_cd_err="$(tail -n +"$((_log_lines_before + 1))" "$LOG_FILE" | grep -c 'Error: cd() failed')"
_cd_exp=0
$WITH_FORMS   && _cd_exp=$(( _cd_exp + 2 ))
$WITH_REPORTS && _cd_exp=$(( _cd_exp + 1 ))
if [ "$_cd_err" -gt 0 ]; then
    info "$(printf "%s × 'Error: cd() failed' in the WLST output (expected %s: MBeans created by the template helpers) – result checked below" "$_cd_err" "$_cd_exp")"
fi
unset _cd_err _cd_exp

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
# JDK path: symlink instead of the resolved directory
#
# writeDomain resolves JDK_HOME (jdk-21 -> jdk-21.0.x) and writes the versioned
# directory into setDomainEnv.sh, setNMJavaHome.sh, the Forms instance scripts
# and init-info/* – a later JDK upgrade by switching the symlink would not
# reach the domain (seen 2026-10-15).
# =============================================================================

section "JDK Path"

if [ -x "$ROOT_DIR/07-Maintenance/domain_jdk_path.sh" ]; then
    # evaluate the exit code - grep "FAIL" also matched its summary line
    # "FAIL: 0" and always warned (until 2026-11-03)
    _jdk_out="$("$ROOT_DIR/07-Maintenance/domain_jdk_path.sh" --apply 2>&1)"
    _jdk_rc=$?
    printf '%s\n' "$_jdk_out" | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -E "No file pins|Backup:|^ *(OK|WARN|FAIL) {2}" | tee -a "$LOG_FILE"
    if [ "$_jdk_rc" -ge 2 ]; then
        warn "07-Maintenance/domain_jdk_path.sh failed (rc=$_jdk_rc) – run it manually: 07-Maintenance/domain_jdk_path.sh"
    else
        ok "$(printf "Domain uses JDK_HOME: %s" "$JDK_HOME")"
    fi
    unset _jdk_out _jdk_rc
else
    warn "07-Maintenance/domain_jdk_path.sh not found – domain pins $(readlink -f "$JDK_HOME")"
fi

# =============================================================================
# AdminServer boot.properties  (enables unattended startup without stdin prompt)
#
# Written here already so AdminServer can be started right after domain creation,
# without waiting for Phase 6. 10-oracle_boot_properties.sh re-writes this same
# file later (harmless – identical content) as part of its full pass over
# AdminServer + all managed servers.
# =============================================================================

section "AdminServer boot.properties"

BOOT_DIR="$DOMAIN_HOME/servers/AdminServer/security"
BOOT_FILE="$BOOT_DIR/boot.properties"

mkdir -p "$BOOT_DIR"
chmod 750 "$BOOT_DIR"

# Write plaintext – WLS encrypts the file automatically on first startup
printf 'username=%s\npassword=%s\n' "$WL_USER" "$INTERNAL_WL_PWD" > "$BOOT_FILE"
chmod 600 "$BOOT_FILE"
ok "$(printf "boot.properties written: %s (mode 600)" "$BOOT_FILE")"
info "  WLS will encrypt the password on first AdminServer startup."

# =============================================================================
# Verify domain structure
# =============================================================================

section "Verification"

VERIFY_FAILS=0
for _path in \
    "$DOMAIN_HOME/config/config.xml" \
    "$DOMAIN_HOME/bin/startWebLogic.sh" \
    "$DOMAIN_HOME/bin/startManagedWebLogic.sh" \
    "$DOMAIN_HOME/nodemanager/nodemanager.properties" \
    "$DOMAIN_HOME/servers/AdminServer/security/boot.properties"
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

# What the template set before writeDomain - visible in the written domain
_cfg="$DOMAIN_HOME/config/config.xml"
if [ -f "$_cfg" ]; then
    _bad_ds="$(grep -l 'dbhost.example.com' "$DOMAIN_HOME"/config/jdbc/*.xml 2>/dev/null | xargs -r -n1 basename | xargs)"
    [ -z "$_bad_ds" ] && ok "Data sources: no template placeholder URL left" \
        || { fail "Data sources still at dbhost.example.com: $_bad_ds"; EXIT_CODE=2; }
    _ms_n=0; $WITH_FORMS && _ms_n=$(( _ms_n + 1 )); $WITH_REPORTS && _ms_n=$(( _ms_n + 1 ))
    _uni="$(grep -cE "<unicast-listen-address>(${WLS_LISTEN_ADDRESS}|localhost|127\.0\.0\.1)</unicast-listen-address>" "$_cfg")"
    [ "$_uni" -ge "$_ms_n" ] && ok "Coherence unicast on loopback: ${_uni} of ${_ms_n} managed server(s)" \
        || warn "Coherence unicast on loopback: only ${_uni} of ${_ms_n} – 02-Checks/clone_check.sh"
    if $WITH_FORMS; then
        grep -q 'time-taken' "$_cfg" && ok "WLS_FORMS access log with time-taken" \
            || warn "time-taken missing in the WLS_FORMS access log – 06-FormsDiag/forms_perf_settings.sh --apply --fix-accesslog"
    fi
    unset _bad_ds _ms_n _uni
fi
unset _cfg

printf "\n" | tee -a "$LOG_FILE"
# WLS 14.1.2 has no Administration Console (/console) any more – the domain is
# configured by 09-oracle_configure.sh before the first start
info "Next step: post-domain configuration (domain is started afterwards)"
info "  09-Install/09-oracle_configure.sh   (dry-run, then --apply)"

# =============================================================================
print_summary
exit "$EXIT_CODE"
