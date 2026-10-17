#!/bin/bash
# =============================================================================
# Script   : 07-oracle_setup_repository.sh
# Purpose  : Run RCU (Repository Creation Utility) in silent mode to create
#            the FMW metadata schemas required before domain creation
#            (8 RCU components, 9 database schemas total — WLS also creates
#            a WLS_RUNTIME sub-schema).
#            IMPORTANT: Run AFTER all software is installed and patched:
#              05-oracle_install_weblogic.sh  → FMW Infrastructure
#              05-oracle_patch_weblogic.sh    → WLS patches
#              06-oracle_install_forms_reports.sh  → Forms/Reports
#              06-oracle_patch_forms_reports.sh    → F&R patches
#            Then: 07-oracle_setup_repository.sh  (this script)
#            Then: 08-oracle_setup_domain.sh       (domain creation)
# Call     : ./09-Install/07-oracle_setup_repository.sh
#            ./09-Install/07-oracle_setup_repository.sh --apply
#            ./09-Install/07-oracle_setup_repository.sh --drop
#            ./09-Install/07-oracle_setup_repository.sh --profile
#            ./09-Install/07-oracle_setup_repository.sh --help
# Options  : (none)    Dry-run: show connection info and schema names
#            --apply   Run RCU -createRepository
#            --drop    Run RCU -dropRepository (CAUTION: destroys all FMW data)
#            --profile Only assign the DB profile RCU_DB_PROFILE (default RCU_USER:
#                      no password expiry, no lock) to the existing schemas
#            --prefix P  with --profile: prefix(es) to assign (repeatable),
#                      default DB_SCHEMA_PREFIX; all registry prefixes are shown
#            --help    Show usage
# Profile  : RCU creates its schemas with profile DEFAULT (19c: password
#            expires after 180 days -> domain does not start). After
#            -createRepository (and with --profile) this script creates/aligns
#            RCU_DB_PROFILE and assigns it to all schemas of the prefix
#            (60-RCU-DB-19c/rcu_user_profile.sql; DB preparation:
#            60-RCU-DB-19c/07b-db_rcu_profile.sh).
# DB type  : RCU_DB_TYPE (EBR | ORACLE, default EBR) is always passed as
#            -databaseType. Without it silent RCU created EBR schemas
#            (editions enabled) on 19c, while the GUI may preselect "Oracle
#            Database" – one explicit type per installation instead of a
#            tool-dependent "default" (rcu_middleware_architecture.md 4.3).
# Runs as  : oracle
# Requires : $ORACLE_HOME/oracle_common/bin/rcu, DB credentials in db_sys_sec.conf.des3
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/docs/07-oracle_setup_repository.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"
DB_SYS_SEC_FILE="$ROOT_DIR/db_sys_sec.conf.des3"

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
# Arguments
# =============================================================================

APPLY=false
DROP=false
PROFILE_ONLY=false
PROFILE_SQL="$ROOT_DIR/60-RCU-DB-19c/rcu_user_profile.sql"
OVERVIEW_SQL="$ROOT_DIR/60-RCU-DB-19c/rcu_registry_overview.sql"
PREFIXES=()
RCU_DB_PROFILE="${RCU_DB_PROFILE:-RCU_USER}"

_usage() {
    printf "Usage: %s [--apply | --drop] [--help]\n\n" "$(basename "$0")"
    printf "  %-12s %s\n" "(none)"   "Dry-run: show connection info and schema names"
    printf "  %-12s %s\n" "--apply"  "Run RCU -createRepository (create 8 FMW component schemas)"
    printf "  %-12s %s\n" "--drop"   "Run RCU -dropRepository (CAUTION: destroys all FMW data)"
    printf "  %-12s %s\n" "--profile" "Only assign DB profile ${RCU_DB_PROFILE} (no expiry/lock) to existing schemas"
    printf "  %-12s %s\n" "--prefix P" "With --profile: prefix to assign (repeatable), default DB_SCHEMA_PREFIX"
    printf "  %-12s %s\n" "--help"   "Show this help"
    printf "\nRuns as: oracle\n"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)   APPLY=true ;;
        --drop)    DROP=true  ;;
        --profile) PROFILE_ONLY=true ;;
        --prefix)
            [[ "${2:-}" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] \
                || { printf "\033[31mERROR\033[0m --prefix needs a prefix (letters/digits): %s\n" "${2:-}" >&2; exit 1; }
            PREFIXES+=("${2^^}"); shift ;;
        --help|-h) _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
    shift
done
if [ ${#PREFIXES[@]} -gt 0 ] && ! $PROFILE_ONLY; then
    printf "\033[31mERROR\033[0m --prefix is only valid with --profile (RCU itself uses DB_SCHEMA_PREFIX)\n" >&2; exit 1
fi
[ ${#PREFIXES[@]} -eq 0 ] && PREFIXES=("${DB_SCHEMA_PREFIX^^}")
PREFIX_LIST="$(IFS=,; printf '%s' "${PREFIXES[*]}")"

if $APPLY && $DROP; then
    printf "\033[31mERROR\033[0m --apply and --drop are mutually exclusive\n" >&2; exit 1
fi
if $PROFILE_ONLY && { $APPLY || $DROP; }; then
    printf "\033[31mERROR\033[0m --profile cannot be combined with --apply / --drop\n" >&2; exit 1
fi

# =============================================================================
# RCU components (8 schemas for FMW 14.1.2 Forms/Reports)
# Verified via: rcu -silent -listComponents
# =============================================================================

RCU_COMPONENTS=(STB MDS OPSS IAU IAU_APPEND IAU_VIEWER UCSUMS WLS)

# =============================================================================
# Banner
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – RCU Repository Setup\033[0m\n"            | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"                             | tee -a "$LOG_FILE"
printf "  Date        : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"                 | tee -a "$LOG_FILE"
if $DROP; then
printf "  Mode        : \033[31mDROP (CAUTION – destroys all FMW schema data)\033[0m\n" | tee -a "$LOG_FILE"
else
printf "  Mode        : %s\n" "$( $APPLY && printf 'APPLY (create schemas)' || printf 'DRY-RUN')" | tee -a "$LOG_FILE"
fi
printf "  Log         : %s\n" "$LOG_FILE"                                    | tee -a "$LOG_FILE"
printLine

# =============================================================================
# Pre-checks
# =============================================================================

section "Pre-checks"

# --- ORACLE_HOME + rcu binary ------------------------------------------------
[ -n "$ORACLE_HOME" ] \
    && ok "ORACLE_HOME = $ORACLE_HOME" \
    || { fail "ORACLE_HOME not set"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

RCU_BIN="$ORACLE_HOME/oracle_common/bin/rcu"
[ -x "$RCU_BIN" ] \
    && ok "rcu found: $RCU_BIN" \
    || { fail "rcu not found: $RCU_BIN"; fail "  Run first: 05-oracle_install_weblogic.sh --apply"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# --- RCU database type ----------------------------------------------------------
RCU_DB_TYPE="${RCU_DB_TYPE:-EBR}"
RCU_DB_TYPE="${RCU_DB_TYPE^^}"
case "$RCU_DB_TYPE" in
    EBR|ORACLE) ok "RCU_DB_TYPE      = $RCU_DB_TYPE  (-databaseType)" ;;
    *) fail "RCU_DB_TYPE must be EBR or ORACLE (is: $RCU_DB_TYPE)"; EXIT_CODE=2 ;;
esac

# --- Database connection params -----------------------------------------------
[ -n "${DB_HOST:-}" ]          && ok "DB_HOST          = $DB_HOST"          || { fail "DB_HOST not set";          EXIT_CODE=2; }
[ -n "${DB_PORT:-}" ]          && ok "DB_PORT          = $DB_PORT"          || { fail "DB_PORT not set";          EXIT_CODE=2; }
[ -n "${DB_SERVICE:-}" ]       && ok "DB_SERVICE       = $DB_SERVICE"       || { fail "DB_SERVICE not set";       EXIT_CODE=2; }
[ -n "${DB_SCHEMA_PREFIX:-}" ] && ok "DB_SCHEMA_PREFIX = $DB_SCHEMA_PREFIX" || { fail "DB_SCHEMA_PREFIX not set"; EXIT_CODE=2; }

[ "$EXIT_CODE" -ne 0 ] && { info "  Run first: 09-Install/01-setup-interview.sh --apply"; print_summary; exit $EXIT_CODE; }

# --- Encrypted credentials file -----------------------------------------------
[ -f "$DB_SYS_SEC_FILE" ] \
    && ok "DB credentials file found: $DB_SYS_SEC_FILE" \
    || { fail "DB credentials not found: $DB_SYS_SEC_FILE"; info "  Run first: 00-Setup/database_rcu_sec.sh --apply"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# =============================================================================
# Schema summary
# =============================================================================

section "Schema Configuration"

printList "Connect string"  28 "${DB_HOST}:${DB_PORT}/${DB_SERVICE}"
printList "DB user"         28 "sys (SYSDBA)"
printList "Schema prefix"   28 "$DB_SCHEMA_PREFIX"
printList "Database type"   28 "$RCU_DB_TYPE  ($( [ "$RCU_DB_TYPE" = EBR ] && printf 'editions enabled, edition ORA$BASE' || printf 'no editions' ))"

# --- Tablespace info (flags are applied per-component in RCU_COMP_FLAGS) -----
if [ -n "${RCU_TABLESPACE:-}" ]; then
    ok "$(printf "%-28s %s" "RCU_TABLESPACE:"      "$RCU_TABLESPACE")"
    ok "$(printf "%-28s %s" "RCU_TEMP_TABLESPACE:" "${RCU_TEMP_TABLESPACE:-TEMP}")"
    info "  → DBA must have pre-created tablespace '$RCU_TABLESPACE' before running RCU"
else
    info "RCU_TABLESPACE not set – RCU will create its own tablespaces automatically"
    info "  (set RCU_TABLESPACE in environment.conf for a DBA-managed tablespace)"
fi

printf "\n" | tee -a "$LOG_FILE"
info "Schemas that will be $( $DROP && printf 'DROPPED' || printf 'created' ):"
# Component ID ≠ schema name: UCSUMS creates <prefix>_UMS, WLS also creates
# <prefix>_WLS_RUNTIME (confirmed via rcu -listSchemas, 2026-10-14)
for _c in "${RCU_COMPONENTS[@]}"; do
    case "$_c" in
        UCSUMS) _s="${DB_SCHEMA_PREFIX}_UMS" ;;
        WLS)    _s="${DB_SCHEMA_PREFIX}_WLS + ${DB_SCHEMA_PREFIX}_WLS_RUNTIME" ;;
        *)      _s="${DB_SCHEMA_PREFIX}_${_c}" ;;
    esac
    info "  $(printf "%-12s %s" "$_c" "$_s")"
done
unset _c _s

# --- Dry-run exit -------------------------------------------------------------
if ! $APPLY && ! $DROP && ! $PROFILE_ONLY; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "Dry-run – use --apply to create schemas or --drop to drop them."
    info "DB credentials will be read from: $DB_SYS_SEC_FILE"
    print_summary
    exit $EXIT_CODE
fi

# =============================================================================
# Safety prompt for --drop
# =============================================================================

if $DROP; then
    printf "\n"
    printf "  \033[31m╔══════════════════════════════════════════════════════════╗\033[0m\n"
    printf "  \033[31m║  WARNING: --drop will DESTROY all FMW schema data!      ║\033[0m\n"
    printf "  \033[31m║  Schemas: %s_STB  _MDS  _OPSS  _IAU  …          ║\033[0m\n" "$DB_SCHEMA_PREFIX"
    printf "  \033[31m╚══════════════════════════════════════════════════════════╝\033[0m\n"
    printf "\n"
    if ! askYesNo "Really DROP all FMW schemas? (type 'yes' to confirm)" "n"; then
        info "Aborted."
        print_summary; exit 0
    fi
fi

# =============================================================================
# Decrypt DB credentials
# =============================================================================

section "DB Credentials"

unset DB_SYS_PWD DB_SCHEMA_PWD
if ! load_secrets_file "$DB_SYS_SEC_FILE"; then
    info "  Run first: 00-Setup/database_rcu_sec.sh --apply"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

[ -n "${DB_SYS_PWD:-}" ] \
    && ok "DB_SYS_PWD decrypted (${#DB_SYS_PWD} chars)" \
    || { fail "DB_SYS_PWD not found in $DB_SYS_SEC_FILE"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -n "${DB_SCHEMA_PWD:-}" ] \
    && ok "DB_SCHEMA_PWD decrypted (${#DB_SCHEMA_PWD} chars)" \
    || { fail "DB_SCHEMA_PWD not found in $DB_SYS_SEC_FILE"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# =============================================================================
# DB profile for the RCU schemas (RCU itself has no profile option)
# =============================================================================

# _rcu_profile - show all registry prefixes, create/align RCU_DB_PROFILE and
# assign it to every schema of PREFIX_LIST in SYSTEM.SCHEMA_VERSION_REGISTRY$
# (exact prefix match; foreign prefixes are only reported). SYS password via stdin.
_rcu_profile() {
    local sqlplus="$ORACLE_HOME/bin/sqlplus" out rc l
    if [ ! -x "$sqlplus" ]; then
        fail "sqlplus not found: $sqlplus – assign the profile on the DB host:"
        info "  60-RCU-DB-19c/07b-db_rcu_profile.sh --apply --assign"
        return 1
    fi
    if [ ! -f "$PROFILE_SQL" ] || [ ! -f "$OVERVIEW_SQL" ]; then
        fail "SQL script missing: $PROFILE_SQL / $OVERVIEW_SQL"; return 1
    fi
    out="$(LD_LIBRARY_PATH="$ORACLE_HOME/lib" "$sqlplus" -S -L /nolog 2>&1 <<SQLEOF
CONNECT sys/"${DB_SYS_PWD}"@//${DB_HOST}:${DB_PORT}/${DB_SERVICE} AS SYSDBA
@${OVERVIEW_SQL}
@${PROFILE_SQL} ${RCU_DB_PROFILE} ${PREFIX_LIST}
EXIT;
SQLEOF
)"
    rc=$?
    printf '%s\n' "$out" >> "${LOG_FILE:-/dev/null}"
    local t pfx n miss prof st exp ebr mark p
    info "RCU registry – all prefixes in this database (* = selected: ${PREFIX_LIST}):"
    while IFS='|' read -r t pfx n miss prof st exp ebr; do
        case "$t" in
            IHW:NOREG) warn "  SYSTEM.SCHEMA_VERSION_REGISTRY\$ not found" ;;
            IHW:PREFIX)
                mark=" "; [[ ",${PREFIX_LIST}," == *",${pfx},"* ]] && mark="*"
                info "$(printf "  %s %-10s schemas %-3s missing %-3s profile %-16s status %-14s expiry %-10s EBR %s" \
                    "$mark" "$pfx" "$n" "$miss" "$prof" "$st" "$exp" "$ebr")"
                [ "$miss" != "0" ] && warn "  ${pfx}: ${miss} registry row(s) without database user (orphaned)"
                [ "$mark" = " " ] && [ "$prof" != "$RCU_DB_PROFILE" ] \
                    && info "    not selected – left unchanged (--profile --prefix ${pfx} to include it)" ;;
        esac
    done <<< "$out"
    for p in "${PREFIXES[@]}"; do
        printf '%s\n' "$out" | grep -q "^IHW:PREFIX|${p}|" \
            || warn "  selected prefix ${p} is not in the registry"
    done
    while IFS= read -r l; do
        case "$l" in
            IHW:OK:*)   ok   "${l#IHW:OK:}" ;;
            IHW:WARN:*) warn "${l#IHW:WARN:}" ;;
            IHW:FAIL:*) fail "${l#IHW:FAIL:}" ;;
        esac
    done <<< "$out"
    if [ "$rc" -ne 0 ] || printf '%s\n' "$out" | grep -qE "ORA-|SP2-"; then
        fail "Profile step failed (rc=$rc):"
        printf '%s\n' "$out" | grep -E "ORA-|SP2-" | head -3 | while IFS= read -r l; do fail "  $l"; done
        return 1
    fi
    return 0
}

if $PROFILE_ONLY; then
    section "DB Profile ${RCU_DB_PROFILE}"
    info "$(printf "Prefix(es) %s on %s:%s/%s – PASSWORD_LIFE_TIME / FAILED_LOGIN_ATTEMPTS UNLIMITED" \
        "$PREFIX_LIST" "$DB_HOST" "$DB_PORT" "$DB_SERVICE")"
    _rcu_profile || EXIT_CODE=2
    unset DB_SYS_PWD DB_SCHEMA_PWD
    print_summary; exit $EXIT_CODE
fi

# =============================================================================
# Build RCU password file  (trap ensures cleanup even on error or Ctrl+C)
# =============================================================================

RCU_PW_FILE="/tmp/rcu_pw_$$.tmp"

_cleanup_pw_file() {
    if [ -f "$RCU_PW_FILE" ]; then
        # Overwrite before delete (best-effort)
        dd if=/dev/zero of="$RCU_PW_FILE" bs=1 count="$(stat -c '%s' "$RCU_PW_FILE" 2>/dev/null || printf 256)" 2>/dev/null
        rm -f "$RCU_PW_FILE"
    fi
    # Clear passwords from memory
    DB_SYS_PWD="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    DB_SCHEMA_PWD="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    unset DB_SYS_PWD DB_SCHEMA_PWD
}

trap '_cleanup_pw_file' EXIT

section "Password File"

{
    printf '%s\n' "$DB_SYS_PWD"     # Line 1: SYS / SYSDBA password
    for _c in "${RCU_COMPONENTS[@]}"; do
        printf '%s\n' "$DB_SCHEMA_PWD"  # One line per component (same schema password)
        # WLS has a sub-schema WLS_RUNTIME that requires an additional password line
        # (RCU log: "Retrieve additional schema password [1] for: WLS")
        if [ "$_c" = "WLS" ]; then
            printf '%s\n' "$DB_SCHEMA_PWD"
        fi
    done
    unset _c
} > "$RCU_PW_FILE"
chmod 600 "$RCU_PW_FILE"

ok "$(printf "Password file created: %s  (%d lines, mode 600)" "$RCU_PW_FILE" "$(wc -l < "$RCU_PW_FILE")")"

# =============================================================================
# Build RCU component flags
# =============================================================================

RCU_COMP_FLAGS=()
for _c in "${RCU_COMPONENTS[@]}"; do
    RCU_COMP_FLAGS+=( -component "$_c" )
    # -tablespace must follow immediately after each -component (RCU requirement)
    # Only valid for -createRepository – -dropRepository rejects it (RCU-6197)
    if [ -n "${RCU_TABLESPACE:-}" ] && ! $DROP; then
        RCU_COMP_FLAGS+=( -tablespace "$RCU_TABLESPACE" \
                          -tempTablespace "${RCU_TEMP_TABLESPACE:-TEMP}" )
    fi
done
unset _c

# =============================================================================
# DB Pre-Flight Check (before RCU touches the database)
# =============================================================================

section "DB Pre-Flight Check"

# --- 1. TCP port reachability -------------------------------------------------
if timeout 3 bash -c ">/dev/null </dev/tcp/${DB_HOST}/${DB_PORT}" 2>/dev/null; then
    ok "$(printf "TCP port reachable : %s:%s" "$DB_HOST" "$DB_PORT")"
else
    fail "$(printf "Cannot reach %s:%s – listener not running or firewall blocking?" "$DB_HOST" "$DB_PORT")"
    fail "  Check on DB server: lsnrctl status"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

# --- 2. DB connection test via rcu -listSchemas ------------------------------
# -listSchemas is a valid RCU command (unlike -checkRequirements which does
# not exist in 14.1.2). It tests SYSDBA auth and lists any existing schemas.
info "Testing DB connection: rcu -listSchemas ..."
LISTSCHEMAS_OUTPUT=$(
    "$RCU_BIN" \
        -silent \
        -listSchemas \
        -databaseType "$RCU_DB_TYPE" \
        -connectString "${DB_HOST}:${DB_PORT}/${DB_SERVICE}" \
        -dbUser sys \
        -dbRole sysdba \
        -f < "$RCU_PW_FILE" 2>&1
)
PREFLIGHT_RC=$?
printf "%s\n" "$LISTSCHEMAS_OUTPUT" | tee -a "$LOG_FILE"

if [ "$PREFLIGHT_RC" -ne 0 ]; then
    fail "rcu -listSchemas failed (rc=$PREFLIGHT_RC)"
    fail "  Possible causes: wrong DB_HOST/DB_PORT/DB_SERVICE, wrong DB_SYS_PWD"
    fail "  Check: /tmp/RCU<timestamp>/logs/rcu.log (newest)"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi
ok "$(printf "DB connection OK – SYSDBA on %s:%s/%s" "$DB_HOST" "$DB_PORT" "$DB_SERVICE")"

# Check if schemas with this prefix already exist
if printf "%s\n" "$LISTSCHEMAS_OUTPUT" | grep -qi "${DB_SCHEMA_PREFIX}_"; then
    if $DROP; then
        ok "$(printf "Schemas with prefix '%s' found – will be dropped" "$DB_SCHEMA_PREFIX")"
        # RCU also drops the tablespace the schemas live in – including a
        # DBA-pre-created one (confirmed 2026-10-14: "drop tablespace FMW_DATA
        # including contents and datafiles" in the RCU log)
        if [ -n "${RCU_TABLESPACE:-}" ]; then
            warn "RCU -dropRepository also drops tablespace '${RCU_TABLESPACE}' INCLUDING DATAFILES"
            warn "  Re-create it before --apply: 60-RCU-DB-19c/07-db_fmw_tablespace.sh --apply"
        fi
    else
        warn "$(printf "Schemas with prefix '%s' already exist in the DB" "$DB_SCHEMA_PREFIX")"
    fi
    if $APPLY && ! $DROP; then
        fail "  Cannot create – prefix already in use. Use --drop first (CAUTION: destroys data)."
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi
else
    if $DROP; then
        ok "$(printf "No schemas with prefix '%s' in the DB – nothing to drop" "$DB_SCHEMA_PREFIX")"
        print_summary; exit $EXIT_CODE
    fi
    ok "$(printf "No existing schemas with prefix '%s' – safe to create" "$DB_SCHEMA_PREFIX")"
fi

# --- 2b. db_securefile (create only) -----------------------------------------
# With db_securefile=FORCE the FIRST RCU run in a database fails: RCU creates
# SYSTEM.SCHEMA_VERSION_REGISTRY$ (CLOB column) in the non-ASSM tablespace
# SYSTEM -> ORA-43853. PREFERRED (default) / ALWAYS create a BasicFile there.
# (live test 2026-10-17, rcu_middleware_architecture.md 4.2)
if ! $DROP && [ -x "$ORACLE_HOME/bin/sqlplus" ] && [ -f "$OVERVIEW_SQL" ]; then
    _pf="$(LD_LIBRARY_PATH="$ORACLE_HOME/lib" "$ORACLE_HOME/bin/sqlplus" -S -L /nolog 2>&1 <<SQLEOF
CONNECT sys/"${DB_SYS_PWD}"@//${DB_HOST}:${DB_PORT}/${DB_SERVICE} AS SYSDBA
@${OVERVIEW_SQL}
EXIT;
SQLEOF
)"
    _sf="$(printf '%s\n' "$_pf" | sed -n 's/^IHW:SECUREFILE|//p' | head -1)"
    if [ -z "$_sf" ]; then
        warn "db_securefile could not be read (sqlplus) – skipped"
    elif [ "$_sf" = "FORCE" ]; then
        if printf '%s\n' "$_pf" | grep -q '^IHW:NOREG'; then
            fail "db_securefile=FORCE and no RCU registry in this DB – RCU would fail with ORA-43853"
            info "  (registry SYSTEM.SCHEMA_VERSION_REGISTRY\$ has a CLOB, tablespace SYSTEM is not ASSM)"
            info "  Fix (DBA): ALTER SYSTEM SET db_securefile=PREFERRED;  (may be reset after RCU)"
            $APPLY && { EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
        else
            warn "db_securefile=FORCE – registry already exists, RCU should work; keep in mind for new DBs"
        fi
    else
        ok "db_securefile=${_sf} – RCU registry in tablespace SYSTEM possible"
    fi
    unset _pf _sf
fi

# --- 3. Tablespace pre-check (if RCU_TABLESPACE is configured, create only) ---
if [ -n "${RCU_TABLESPACE:-}" ] && ! $DROP; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "$(printf "RCU_TABLESPACE='%s' is set – DBA must have pre-created this tablespace." "$RCU_TABLESPACE")"
    info "  Verify on DB server (as SYSDBA):"
    info "    SELECT tablespace_name, status FROM dba_tablespaces"
    info "    WHERE tablespace_name = UPPER('${RCU_TABLESPACE}');"
    info "  If missing – run on DB server: 60-RCU-DB-19c/07-db_fmw_tablespace.sh --apply"
    printf "\n" | tee -a "$LOG_FILE"
    if $APPLY; then
        if ! askYesNo "Tablespace '${RCU_TABLESPACE}' confirmed as pre-created in the DB?" "n"; then
            info "Aborted – create the tablespace first, then re-run."
            print_summary; exit 0
        fi
        ok "Tablespace '${RCU_TABLESPACE}' confirmed by operator"
    fi
fi

# =============================================================================
# Run RCU
# =============================================================================

if $DROP; then
    RCU_ACTION="-dropRepository"
    section "RCU dropRepository"
else
    RCU_ACTION="-createRepository"
    section "RCU createRepository"
fi

printf "\n  RCU started: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
printf "  Connect    : %s:%s/%s\n" "$DB_HOST" "$DB_PORT" "$DB_SERVICE" | tee -a "$LOG_FILE"
printf "  Prefix     : %s\n" "$DB_SCHEMA_PREFIX" | tee -a "$LOG_FILE"
printf "  DB type    : %s\n\n" "$RCU_DB_TYPE" | tee -a "$LOG_FILE"

"$RCU_BIN" \
    -silent \
    "$RCU_ACTION" \
    -databaseType "$RCU_DB_TYPE" \
    -connectString "${DB_HOST}:${DB_PORT}/${DB_SERVICE}" \
    -dbUser sys \
    -dbRole sysdba \
    -schemaPrefix "$DB_SCHEMA_PREFIX" \
    "${RCU_COMP_FLAGS[@]}" \
    -f < "$RCU_PW_FILE" \
    2>&1 | tee -a "$LOG_FILE"

RCU_RC=${PIPESTATUS[0]}

# trap will clean up the password file
printf "\n  RCU finished: %s  (rc=%s)\n" \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$RCU_RC" | tee -a "$LOG_FILE"

if [ "$RCU_RC" -ne 0 ]; then
    fail "RCU exited with rc=$RCU_RC"
    fail "  Check logs: /tmp/RCU<timestamp>/logs/rcu.log (newest)"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

ok "RCU completed successfully"

# =============================================================================
# Verification (--drop): no schema with this prefix may be left
# =============================================================================

if $DROP; then

    section "Verification"

    LISTSCHEMAS_AFTER=$(
        "$RCU_BIN" -silent -listSchemas -databaseType "$RCU_DB_TYPE" \
            -connectString "${DB_HOST}:${DB_PORT}/${DB_SERVICE}" \
            -dbUser sys -dbRole sysdba \
            -f < "$RCU_PW_FILE" 2>&1
    )
    _left="$(printf '%s\n' "$LISTSCHEMAS_AFTER" \
        | grep -oiE "\b${DB_SCHEMA_PREFIX}_[A-Z_]+" | sort -u | xargs)"
    if [ -n "$_left" ]; then
        fail "Schemas still present after drop: $_left"
        EXIT_CODE=2
    else
        ok "$(printf "No schemas with prefix '%s' left in the DB" "$DB_SCHEMA_PREFIX")"
        [ -n "${RCU_TABLESPACE:-}" ] && \
            warn "Tablespace '${RCU_TABLESPACE}' was dropped by RCU – re-create it before --apply"
        printf "\n" | tee -a "$LOG_FILE"
        info "Next step: create the repository again"
        [ -n "${RCU_TABLESPACE:-}" ] && \
            info "  60-RCU-DB-19c/07-db_fmw_tablespace.sh --apply   (tablespace ${RCU_TABLESPACE})"
        info "  07-oracle_setup_repository.sh --apply"
    fi
    unset _left

fi

# =============================================================================
# Verification (--apply only)
# =============================================================================

if $APPLY; then

    section "Verification"

    # RCU wrote its full output (including Completion Summary) to $LOG_FILE via tee.
    # Grep from there — RCU uses component display names, not schema names, in its log.
    COMP_SUCCESS=$(grep -c "Success" "$LOG_FILE" 2>/dev/null || true)
    COMP_FAILURE=$(grep -c "Failure" "$LOG_FILE" 2>/dev/null || true)
    EXPECTED=${#RCU_COMPONENTS[@]}

    if [ "$COMP_FAILURE" -gt 0 ]; then
        fail "$(printf "%d component(s) failed in RCU Completion Summary – check logs above" "$COMP_FAILURE")"
        EXIT_CODE=2
    elif [ "$COMP_SUCCESS" -ge "$EXPECTED" ]; then
        ok "$(printf "All %d components confirmed Success in RCU Completion Summary" "$EXPECTED")"
    else
        warn "$(printf "Only %d/%d Success entries found in log – verify manually" "$COMP_SUCCESS" "$EXPECTED")"
    fi

    # RCU created the schemas with profile DEFAULT (password expiry 180 days)
    section "DB Profile ${RCU_DB_PROFILE}"
    _rcu_profile || {
        warn "Schemas keep profile DEFAULT – passwords expire after 180 days!"
        info "  Retry: 07-oracle_setup_repository.sh --profile"
        [ "$EXIT_CODE" -lt 1 ] && EXIT_CODE=1
    }

    printf "\n" | tee -a "$LOG_FILE"
    info "Next step: create WebLogic domain"
    info "  08-oracle_setup_domain.sh --apply"

fi

# =============================================================================
print_summary
exit $EXIT_CODE
