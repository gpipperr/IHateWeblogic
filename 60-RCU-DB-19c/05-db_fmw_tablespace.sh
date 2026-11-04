#!/bin/bash
# =============================================================================
# Script   : 05-db_fmw_tablespace.sh
# Purpose  : Pre-create the ONE tablespace (FMW_DATA) for all RCU schemas in
#            the PDB – the standard (09-Install/docs/07-…, Tablespace
#            Configuration).
#            If DB_FMW_TABLESPACE is empty → WARN, nothing created (fallback:
#            RCU creates one tablespace per component).
#            If DB_FMW_TABLESPACE is set   → create tablespace, then set
#            RCU_TABLESPACE in environment.conf to match.
# Call     : ./60-RCU-DB-19c/05-db_fmw_tablespace.sh
#            ./60-RCU-DB-19c/05-db_fmw_tablespace.sh --apply
#            ./60-RCU-DB-19c/05-db_fmw_tablespace.sh --help
# Runs as  : oracle
# Requires : environment.conf, environment_db.conf, DB_FMW_TABLESPACE set
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 60-RCU-DB-19c/docs/05-db_fmw_tablespace.md
#            09-Install/docs/07-oracle_setup_repository.md (RCU_TABLESPACE)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"
ENV_DB_CONF="$SCRIPT_DIR/environment_db.conf"

source "$LIB" 2>/dev/null || { printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB" >&2; exit 2; }
for _f in "$ENV_CONF" "$ENV_DB_CONF"; do
    [ ! -f "$_f" ] && { printf "\033[31mFATAL\033[0m: Config not found: %s\n" "$_f" >&2
        [ "$_f" = "$ENV_DB_CONF" ] && printf "  Create it (interview from the template): ./60-RCU-DB-19c/00a-db_env_interview.sh --apply\n" >&2
        exit 2; }
    source "$_f"
done
unset _f

DIAG_LOG_DIR="${DIAG_LOG_DIR:-$ROOT_DIR/log/$(date +%Y%m%d)}"
init_log "$DIAG_LOG_DIR"

# Set ORACLE_HOME + ORACLE_SID for sqlplus OS authentication (/ AS SYSDBA)
export ORACLE_HOME="$DB_ORACLE_HOME"
export ORACLE_SID="${DB_SID}"
SQLPLUS="$DB_ORACLE_HOME/bin/sqlplus"

# =============================================================================
# Arguments
# =============================================================================

APPLY=false

_usage() {
    printf "Usage: %s [--apply] [--help]\n\n" "$(basename "$0")"
    printf "  %-12s %s\n" "(none)"  "Dry-run: show what would be created"
    printf "  %-12s %s\n" "--apply" "Create FMW_DATA tablespace + update environment.conf"
    printf "  %-12s %s\n" "--help"  "Show this help"
    printf "\nOnly runs if DB_FMW_TABLESPACE is set in environment_db.conf.\n"
    exit 0
}

for _arg in "$@"; do
    case "$_arg" in
        --apply)   APPLY=true ;;
        --help|-h) _usage ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$_arg" >&2; exit 1 ;;
    esac
done
unset _arg

# =============================================================================
# Banner
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – DB FMW Tablespace\033[0m\n"  | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"                            | tee -a "$LOG_FILE"
printf "  Date        : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"               | tee -a "$LOG_FILE"
printf "  Mode        : %s\n" "$( $APPLY && printf 'APPLY' || printf 'DRY-RUN')" | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"                                   | tee -a "$LOG_FILE"
printLine

# =============================================================================
# Not configured: WARN (standard = one tablespace), nothing to do
# =============================================================================

section "FMW Tablespace Configuration"

if [ -z "${DB_FMW_TABLESPACE:-}" ]; then
    warn "DB_FMW_TABLESPACE is not set in environment_db.conf – nothing created"
    info "  Fallback: RCU creates one tablespace per component (not the standard)."
    info "  Standard: DB_FMW_TABLESPACE=FMW_DATA here (00a-db_env_interview.sh --reset --apply)"
    info "  and RCU_TABLESPACE=FMW_DATA in environment.conf"
    print_summary; exit $EXIT_CODE
fi

_ts_name="$DB_FMW_TABLESPACE"
_ts_size="${DB_FMW_TABLESPACE_SIZE_MB:-500}"
_data_dir="${DB_DATA_DIR}/${DB_CDB_NAME}/${DB_PDB_NAME}"
_ts_file="${_data_dir}/$(printf "%s" "$_ts_name" | tr '[:upper:]' '[:lower:]')01.dbf"

printList "PDB"                 28 "$DB_PDB_NAME"
printList "Tablespace name"     28 "$_ts_name"
printList "Initial size"        28 "${_ts_size} MB"
printList "Datafile"            28 "$_ts_file"
printList "→ RCU_TABLESPACE"    28 "$_ts_name  (set in environment.conf)"

# =============================================================================
# Pre-checks
# =============================================================================

section "Pre-checks"

[ -x "$SQLPLUS" ] \
    && ok "sqlplus found: $SQLPLUS" \
    || { fail "sqlplus not found"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

_ping=$("$SQLPLUS" -S /nolog <<< "CONNECT / AS SYSDBA
SELECT 'DB_UP' FROM DUAL;
EXIT;" 2>&1)
if printf "%s" "$_ping" | grep -q "DB_UP"; then
    ok "Database is running (ORACLE_SID=${ORACLE_SID})"
else
    fail "Cannot connect / AS SYSDBA (ORACLE_SID=${ORACLE_SID:-unset}) – database not running?"
    printf "%s\n" "$_ping" | grep -E "ORA-|SP2-" | head -3 | while IFS= read -r _l; do fail "  $_l"; done
    EXIT_CODE=2; print_summary; exit $EXIT_CODE
fi
unset _ping

if ! $APPLY; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "Dry-run – use --apply to create tablespace."
    info "Also ensure RCU_TABLESPACE=${_ts_name} is set in environment.conf"
    print_summary; exit $EXIT_CODE
fi

# =============================================================================
# Create tablespace
# =============================================================================

section "Create Tablespace: $_ts_name"

mkdir -p "$_data_dir"

# SERVEROUTPUT for the created/skipping message; an SQL error ends sqlplus with
# rc<>0 (before: rc 0 and "created/verified" even after ORA-01119 / ORA-01543)
_ts_out="$("$SQLPLUS" -S /nolog << SQLEOF 2>&1
CONNECT / AS SYSDBA
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SESSION SET CONTAINER = ${DB_PDB_NAME};

DECLARE
    v_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM DBA_TABLESPACES WHERE TABLESPACE_NAME = UPPER('${_ts_name}');

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('Tablespace ${_ts_name} already exists - skipping.');
    ELSE
        EXECUTE IMMEDIATE
            'CREATE TABLESPACE "${_ts_name}" ' ||
            'DATAFILE ''${_ts_file}'' ' ||
            'SIZE ${_ts_size}M ' ||
            'AUTOEXTEND ON NEXT 100M MAXSIZE UNLIMITED ' ||
            'EXTENT MANAGEMENT LOCAL AUTOALLOCATE ' ||
            'SEGMENT SPACE MANAGEMENT AUTO';
        DBMS_OUTPUT.PUT_LINE('Tablespace ${_ts_name} created.');
    END IF;
END;
/

-- Verification
SELECT TABLESPACE_NAME, STATUS, BLOCK_SIZE, EXTENT_MANAGEMENT
FROM DBA_TABLESPACES WHERE TABLESPACE_NAME = UPPER('${_ts_name}');

SELECT FILE_NAME, BYTES/1024/1024 AS SIZE_MB, AUTOEXTENSIBLE
FROM DBA_DATA_FILES WHERE TABLESPACE_NAME = UPPER('${_ts_name}');

EXIT;
SQLEOF
)"
_sql_rc=$?
printf '%s\n' "$_ts_out" | tee -a "$LOG_FILE"
if [ "$_sql_rc" -eq 0 ] && ! printf '%s\n' "$_ts_out" | grep -q 'ORA-'; then
    ok "Tablespace $_ts_name created/verified"
else
    fail "Tablespace $_ts_name: SQL rc=$_sql_rc $(printf '%s\n' "$_ts_out" | grep -m1 'ORA-')"
    EXIT_CODE=2
fi
unset _ts_out _sql_rc

# =============================================================================
# Update environment.conf with RCU_TABLESPACE
# =============================================================================

section "Sync environment.conf"

if grep -q "^RCU_TABLESPACE=" "$ENV_CONF"; then
    _current_val=$(grep "^RCU_TABLESPACE=" "$ENV_CONF" | cut -d= -f2 | tr -d '"')
    if [ "$_current_val" = "$_ts_name" ]; then
        ok "RCU_TABLESPACE already set to '$_ts_name' in environment.conf"
    else
        backup_file "$ENV_CONF" "$(dirname "$ENV_CONF")"
        sed -i --follow-symlinks "s|^RCU_TABLESPACE=.*|RCU_TABLESPACE=\"${_ts_name}\"|" "$ENV_CONF"
        ok "RCU_TABLESPACE updated to '$_ts_name' in environment.conf"
    fi
else
    warn "RCU_TABLESPACE not found in environment.conf – add it (00-Setup/detect_env_conf.sh --apply or the interview, block 4), then run 05- again"
fi
unset _current_val

printf "\n" | tee -a "$LOG_FILE"
info "Next steps:"
info "  60-RCU-DB-19c/06-db_rcu_profile.sh --apply      (profile RCU_USER)"
info "  60-RCU-DB-19c/08-db_auto_start.sh --apply       (autostart)"
info "  09-Install/07-oracle_setup_repository.sh --apply (RCU)"
info "  DB_SERVICE in environment.conf must be the PDB service: ${DB_PDB_NAME}"

unset _ts_name _ts_size _data_dir _ts_file

# =============================================================================
print_summary
exit $EXIT_CODE
