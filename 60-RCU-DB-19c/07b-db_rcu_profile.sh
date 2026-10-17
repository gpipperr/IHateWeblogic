#!/bin/bash
# =============================================================================
# Script   : 07b-db_rcu_profile.sh
# Purpose  : DB preparation before RCU: create the profile for the FMW
#            repository schemas (RCU_DB_PROFILE, default RCU_USER) with
#            PASSWORD_LIFE_TIME UNLIMITED and FAILED_LOGIN_ATTEMPTS UNLIMITED.
#            RCU creates its schemas with profile DEFAULT (19c: password
#            expires after 180 days, account locks after 10 failed logins) –
#            then the domain no longer starts.
#            With --assign the profile is also given to all schemas of
#            DB_SCHEMA_PREFIX that already exist (from the schema version
#            registry) – e.g. for a repository created before this script.
#            --prefix <P> (repeatable) selects other/further prefixes
#            explicitly; there is deliberately no "all prefixes" switch –
#            other repositories in the same DB may belong to other teams.
#            Every run shows ALL prefixes of the registry (schemas, missing
#            users, profiles, status, earliest expiry).
#            09-Install/07-oracle_setup_repository.sh assigns it after RCU.
# Call     : ./60-RCU-DB-19c/07b-db_rcu_profile.sh
#            ./60-RCU-DB-19c/07b-db_rcu_profile.sh --apply
#            ./60-RCU-DB-19c/07b-db_rcu_profile.sh --apply --assign
#            ./60-RCU-DB-19c/07b-db_rcu_profile.sh --apply --assign --prefix DEV --prefix TEST
# Runs as  : oracle (on the DB host, sqlplus / AS SYSDBA)
# Requires : environment.conf, environment_db.conf (DB_ORACLE_HOME, DB_SID,
#            DB_PDB_NAME), 60-RCU-DB-19c/rcu_user_profile.sql
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 60-RCU-DB-19c/docs/07b-db_rcu_profile.md
#            80-FMW-Architecture/rcu_middleware_architecture.md (6.1)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"
ENV_DB_CONF="$SCRIPT_DIR/environment_db.conf"
PROFILE_SQL="$SCRIPT_DIR/rcu_user_profile.sql"
OVERVIEW_SQL="$SCRIPT_DIR/rcu_registry_overview.sql"

source "$LIB" 2>/dev/null || { printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB" >&2; exit 2; }
for _f in "$ENV_CONF" "$ENV_DB_CONF"; do
    [ ! -f "$_f" ] && { printf "\033[31mFATAL\033[0m: Config not found: %s\n" "$_f" >&2; exit 2; }
    source "$_f"
done
unset _f

DIAG_LOG_DIR="${DIAG_LOG_DIR:-$ROOT_DIR/log/$(date +%Y%m%d)}"
init_log "$DIAG_LOG_DIR"

# sqlplus OS authentication (/ AS SYSDBA) on the DB host
export ORACLE_HOME="$DB_ORACLE_HOME"
export ORACLE_SID="${DB_SID}"
SQLPLUS="$DB_ORACLE_HOME/bin/sqlplus"

RCU_DB_PROFILE="${RCU_DB_PROFILE:-RCU_USER}"

# =============================================================================
# Arguments
# =============================================================================

APPLY=false
ASSIGN=false
PREFIXES=()

_usage() {
    printf "Usage: %s [--apply] [--assign] [--help]\n\n" "$(basename "$0")"
    printf "  %-12s %s\n" "(none)"   "Dry-run: show profile and current state"
    printf "  %-12s %s\n" "--apply"  "Create / align profile ${RCU_DB_PROFILE}"
    printf "  %-12s %s\n" "--assign" "With --apply: also assign it to the existing RCU schemas of the prefix(es)"
    printf "  %-12s %s\n" "--prefix P" "Prefix to assign (repeatable); default: DB_SCHEMA_PREFIX (${DB_SCHEMA_PREFIX:-not set})"
    printf "  %-12s %s\n" "--help"   "Show this help"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)   APPLY=true ;;
        --assign)  ASSIGN=true ;;
        --prefix)
            [[ "${2:-}" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] \
                || { printf "\033[31mERROR\033[0m --prefix needs a prefix (letters/digits): %s\n" "${2:-}" >&2; exit 1; }
            PREFIXES+=("${2^^}"); shift ;;
        --help|-h) _usage ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
    shift
done
[ ${#PREFIXES[@]} -eq 0 ] && [ -n "${DB_SCHEMA_PREFIX:-}" ] && PREFIXES=("${DB_SCHEMA_PREFIX^^}")
PREFIX_LIST="$(IFS=,; printf '%s' "${PREFIXES[*]}")"

# =============================================================================
# Banner
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – DB profile for the RCU schemas\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"                            | tee -a "$LOG_FILE"
printf "  Date        : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"               | tee -a "$LOG_FILE"
printf "  Mode        : %s\n" "$( $APPLY && printf 'APPLY' || printf 'DRY-RUN')" | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"                                   | tee -a "$LOG_FILE"
printLine

section "Configuration"

printList "PDB"                  28 "$DB_PDB_NAME"
printList "Profile"              28 "$RCU_DB_PROFILE"
printList "Limits"               28 "PASSWORD_LIFE_TIME UNLIMITED, FAILED_LOGIN_ATTEMPTS UNLIMITED"
printList "Prefix(es) to assign" 28 "${PREFIX_LIST:-<none>}  (assign: $ASSIGN)"

# _securefile_check <sqlplus output> - db_securefile=FORCE breaks the FIRST RCU
# run in a DB: the registry table (CLOB) goes to the non-ASSM tablespace
# SYSTEM -> ORA-43853 (PREFERRED/ALWAYS create it as BasicFile there)
_securefile_check() {
    local sf
    sf="$(printf '%s\n' "$1" | sed -n 's/^IHW:SECUREFILE|//p' | head -1)"
    [ -z "$sf" ] && return 0
    if [ "$sf" = "FORCE" ]; then
        if printf '%s\n' "$1" | grep -q '^IHW:NOREG'; then
            fail "db_securefile=FORCE and no RCU registry yet – RCU will fail (ORA-43853, SYSTEM is not ASSM)"
        else
            warn "db_securefile=FORCE – registry exists, but a new registry/LOB in SYSTEM would fail (ORA-43853)"
        fi
        info "  Fix (DBA): ALTER SYSTEM SET db_securefile=PREFERRED; – at least for the first RCU run"
    else
        ok "db_securefile=${sf} (RCU registry in tablespace SYSTEM possible)"
    fi
}

# _registry_overview <sqlplus output> - all prefixes of the registry, marks the
# selected ones; foreign prefixes are only reported, never changed
_registry_overview() {
    local line t pfx n miss prof st exp ebr mark
    section "RCU registry – all prefixes in this database"
    _securefile_check "$1"
    if printf '%s\n' "$1" | grep -q '^IHW:NOREG'; then
        warn "SYSTEM.SCHEMA_VERSION_REGISTRY\$ not found – no RCU repository in this DB (yet)"
        return 0
    fi
    printf "  %-3s %-10s %-7s %-7s %-22s %-18s %-16s %s\n" "" "Prefix" "Schemas" "Missing" "Profile(s)" "Status" "Earliest expiry" "EBR" \
        | tee -a "${LOG_FILE:-/dev/null}"
    while IFS='|' read -r t pfx n miss prof st exp ebr; do
        [ "$t" = "IHW:PREFIX" ] || continue
        mark="   "
        [[ ",${PREFIX_LIST}," == *",${pfx},"* ]] && mark=" * "
        printf "  %-3s %-10s %-7s %-7s %-22s %-18s %-16s %s\n" "$mark" "$pfx" "$n" "$miss" "$prof" "$st" "$exp" "$ebr" \
            | tee -a "${LOG_FILE:-/dev/null}"
        [ "$miss" != "0" ] && warn "  ${pfx}: ${miss} registry row(s) without database user (orphaned)"
        [[ "$ebr" == *,* ]] && warn "  ${pfx}: schemas mixed EBR/non-EBR (EDITIONS_ENABLED ${ebr})"
        if [ "$prof" != "$RCU_DB_PROFILE" ] && [ "$mark" = "   " ]; then
            info "  ${pfx}: not selected – profile ${prof} left unchanged (add --prefix ${pfx} to include it)"
        fi
    done <<< "$1"
    info "  * = selected for --assign (${PREFIX_LIST:-none})"
    for pfx in "${PREFIXES[@]}"; do
        printf '%s\n' "$1" | grep -q "^IHW:PREFIX|${pfx}|" \
            || warn "  selected prefix ${pfx} is not in the registry – nothing to assign for it"
    done
}

# =============================================================================
# Pre-checks
# =============================================================================

section "Pre-checks"

[ -x "$SQLPLUS" ] \
    && ok "sqlplus found: $SQLPLUS" \
    || { fail "sqlplus not found: $SQLPLUS"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
[ -f "$PROFILE_SQL" ] \
    && ok "SQL script: $PROFILE_SQL" \
    || { fail "SQL script missing: $PROFILE_SQL"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
[ -f "$OVERVIEW_SQL" ] \
    || { fail "SQL script missing: $OVERVIEW_SQL"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
if $ASSIGN && [ -z "$PREFIX_LIST" ]; then
    fail "--assign needs DB_SCHEMA_PREFIX in environment.conf or --prefix"
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi

# Current state (read-only): profile, all registry prefixes, schemas of the selected prefixes
_state=$("$SQLPLUS" -S /nolog <<SQLEOF 2>&1
CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = ${DB_PDB_NAME};
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200
SELECT 'PROFILE|' || resource_name || '|' || limit FROM dba_profiles
 WHERE profile = UPPER('${RCU_DB_PROFILE}') AND resource_name IN ('PASSWORD_LIFE_TIME','FAILED_LOGIN_ATTEMPTS');
@${OVERVIEW_SQL}
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200
SELECT 'USER|' || username || '|' || profile || '|' || account_status || '|' || TO_CHAR(expiry_date,'YYYY-MM-DD')
  FROM dba_users
 WHERE username IN (SELECT owner FROM system.schema_version_registry\$
                     WHERE INSTR(',' || '${PREFIX_LIST:-#}' || ',', ',' || mrc_name || ',') > 0)
 ORDER BY username;
EXIT;
SQLEOF
)
if printf '%s\n' "$_state" | grep -qE "ORA-|SP2-"; then
    fail "Cannot query the PDB ${DB_PDB_NAME} as SYSDBA (ORACLE_SID=${ORACLE_SID:-unset})"
    printf '%s\n' "$_state" | grep -E "ORA-|SP2-" | head -3 | while IFS= read -r _l; do fail "  $_l"; done
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi
if printf '%s\n' "$_state" | grep -q '^PROFILE|'; then
    printf '%s\n' "$_state" | awk -F'|' '/^PROFILE\|/ {printf "  %-26s %s\n", $2, $3}' | tee -a "$LOG_FILE"
else
    info "Profile ${RCU_DB_PROFILE} does not exist yet"
fi
_registry_overview "$_state"
[ -n "$PREFIX_LIST" ] && info "Schemas of the selected prefix(es) ${PREFIX_LIST}:"
while IFS='|' read -r _t _u _p _s _e; do
    [ "$_t" = "USER" ] || continue
    if [ "$_p" = "$RCU_DB_PROFILE" ]; then
        ok "$(printf "  %-20s %-10s %-10s expiry %s" "$_u" "$_p" "$_s" "${_e:--}")"
    else
        warn "$(printf "  %-20s %-10s %-10s expiry %s" "$_u" "$_p" "$_s" "${_e:--}")"
    fi
done <<< "$_state"
unset _state _t _u _p _s _e

if ! $APPLY; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "Dry-run – use --apply (and --assign for existing schemas)."
    print_summary; exit $EXIT_CODE
fi

# =============================================================================
# Create / align profile (+ assign)
# =============================================================================

section "Profile ${RCU_DB_PROFILE}"

_prefix_arg="-"
$ASSIGN && _prefix_arg="$PREFIX_LIST"

_out=$("$SQLPLUS" -S /nolog <<SQLEOF 2>&1
CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = ${DB_PDB_NAME};
@${PROFILE_SQL} ${RCU_DB_PROFILE} ${_prefix_arg}
EXIT;
SQLEOF
)
_rc=$?
printf '%s\n' "$_out" >> "${LOG_FILE:-/dev/null}"
while IFS= read -r _l; do
    case "$_l" in
        IHW:OK:*)   ok   "${_l#IHW:OK:}" ;;
        IHW:WARN:*) warn "${_l#IHW:WARN:}" ;;
        IHW:FAIL:*) fail "${_l#IHW:FAIL:}" ;;
    esac
done <<< "$_out"
if [ "$_rc" -ne 0 ] || printf '%s\n' "$_out" | grep -qE "ORA-|SP2-"; then
    fail "SQL failed (rc=$_rc):"
    printf '%s\n' "$_out" | grep -E "ORA-|SP2-" | head -3 | while IFS= read -r _l; do fail "  $_l"; done
    EXIT_CODE=2
fi
unset _out _rc _l _prefix_arg

printf "\n" | tee -a "$LOG_FILE"
info "RCU creates new schemas with profile DEFAULT – 09-Install/07-oracle_setup_repository.sh"
info "  assigns ${RCU_DB_PROFILE} after -createRepository (or: this script --apply --assign)."

print_summary
exit $EXIT_CODE
