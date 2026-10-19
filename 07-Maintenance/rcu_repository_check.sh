#!/bin/bash
# =============================================================================
# Script   : rcu_repository_check.sh
# Purpose  : Check the FMW repository (RCU schemas) of this domain - and back
#            it up before an upgrade / move.
#            Read-only checks (as SYSDBA over the network, sqlplus of the
#            Oracle Home):
#              1. database: db_securefile, schema version registry present,
#                 all prefixes of the registry (other domains only reported)
#              2. registry rows of DB_SCHEMA_PREFIX: VERSION, STATUS = VALID,
#                 UPGRADED, EDITION, EBR (RCU_DB_TYPE)
#              3. schema accounts: OPEN, profile RCU_DB_PROFILE (no expiry),
#                 EXPIRY_DATE (WARN < RCU_EXPIRY_WARN_DAYS, default 30)
#              4. data sources of the domain (config/jdbc/*-jdbc.xml): user is
#                 an RCU schema of the prefix, URL = DB_HOST/DB_PORT/DB_SERVICE,
#                 login with DB_SCHEMA_PWD works
#              5. service table <prefix>_STB: one row per registry entry
#            --apply: Data Pump export (expdp of the Oracle Home, over the
#              network into DATA_PUMP_DIR on the DB server) of all schemas of
#              the prefix + SYSTEM.SCHEMA_VERSION_REGISTRY$ (Oracle requires
#              the registry in the backup before an Upgrade Assistant run).
# Call     : ./rcu_repository_check.sh [--apply]
# Background: 80-FMW-Architecture/rcu_middleware_architecture.md
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"
DB_SYS_SEC_FILE="$ROOT_DIR/db_sys_sec.conf.des3"
OVERVIEW_SQL="$ROOT_DIR/60-RCU-DB-19c/rcu_registry_overview.sql"

LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m Cannot find IHateWeblogic_lib.sh: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=00-Setup/IHateWeblogic_lib.sh
source "$LIB"

check_env_conf "$ENV_CONF" || exit 2
source "$ENV_CONF"

init_log

# =============================================================================
# Parse arguments
# =============================================================================
APPLY=false
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=true ;;
        --help)
            printf "Usage: %s [--apply]\n" "$(basename "$0")"
            printf "  Default: read-only checks of the RCU repository (registry, schema\n"
            printf "           accounts, profile/expiry, data sources, service table)\n"
            printf "  --apply: additionally Data Pump export of the prefix schemas and\n"
            printf "           SYSTEM.SCHEMA_VERSION_REGISTRY\$ into DATA_PUMP_DIR (DB server)\n"
            exit 0
            ;;
        *) printf "Unknown option: %s (see --help)\n" "$arg" >&2; exit 2 ;;
    esac
done

RCU_DB_PROFILE="${RCU_DB_PROFILE:-RCU_USER}"
RCU_DB_TYPE="${RCU_DB_TYPE:-EBR}"
WARN_DAYS="${RCU_EXPIRY_WARN_DAYS:-30}"
PFX="${DB_SCHEMA_PREFIX^^}"
SQLPLUS="$ORACLE_HOME/bin/sqlplus"
EXPDP="$ORACLE_HOME/bin/expdp"

# =============================================================================
# Pre-checks
# =============================================================================
section "Repository"

for _v in DB_HOST DB_PORT DB_SERVICE DB_SCHEMA_PREFIX; do
    if [ -z "${!_v:-}" ]; then
        fail "$_v not set in environment.conf"; print_summary; exit 2
    fi
done
unset _v
printList "Database"        20 "${DB_HOST}:${DB_PORT}/${DB_SERVICE}"
printList "Schema prefix"   20 "$PFX"
printList "RCU_DB_TYPE"     20 "$RCU_DB_TYPE"
printList "RCU_DB_PROFILE"  20 "$RCU_DB_PROFILE"

[ -x "$SQLPLUS" ] || { fail "sqlplus not found: $SQLPLUS"; print_summary; exit 2; }
[ -f "$OVERVIEW_SQL" ] || { fail "missing: $OVERVIEW_SQL"; print_summary; exit 2; }
if ! load_secrets_file "$DB_SYS_SEC_FILE" > /dev/null 2>&1 || [ -z "${DB_SYS_PWD:-}" ]; then
    fail "DB credentials not readable: $DB_SYS_SEC_FILE"
    info "  09-Install/01-setup-interview.sh or 00-Setup/database_rcu_sec.sh --apply"
    print_summary; exit 2
fi
trap 'DB_SYS_PWD=""; DB_SCHEMA_PWD=""' EXIT

export LD_LIBRARY_PATH="$ORACLE_HOME/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# _sys_sql <sql text> - run as SYSDBA, password via stdin (not in the process list)
_sys_sql() {
    "$SQLPLUS" -S -L /nolog <<SQLEOF 2>&1
CONNECT sys/"${DB_SYS_PWD}"@//${DB_HOST}:${DB_PORT}/${DB_SERVICE} AS SYSDBA
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 400 VERIFY OFF TRIMSPOOL ON
$1
EXIT;
SQLEOF
}

OUT="$(_sys_sql "@${OVERVIEW_SQL}
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 400
SELECT 'REG|' || comp_id || '|' || owner || '|' || version || '|' || status || '|' || upgraded || '|' || NVL(edition,'-')
  FROM system.schema_version_registry\$ WHERE mrc_name = '${PFX}' ORDER BY owner;
SELECT 'USR|' || u.username || '|' || u.account_status || '|' || u.profile || '|'
       || NVL(TO_CHAR(u.expiry_date,'YYYY-MM-DD'),'-') || '|'
       || NVL(TO_CHAR(TRUNC(u.expiry_date - SYSDATE)),'-') || '|' || u.editions_enabled
  FROM dba_users u
 WHERE u.username IN (SELECT owner FROM system.schema_version_registry\$ WHERE mrc_name = '${PFX}')
 ORDER BY u.username;
SELECT 'STB|' || COUNT(*) FROM dba_tables WHERE owner = '${PFX}_STB' AND table_name = 'COMPONENT_SCHEMA_INFO';")"

if printf '%s\n' "$OUT" | grep -qE "ORA-|SP2-"; then
    fail "SQL as SYSDBA failed:"
    printf '%s\n' "$OUT" | grep -E "ORA-|SP2-" | head -3 | while IFS= read -r _l; do fail "  $_l"; done
    print_summary; exit 2
fi

# =============================================================================
# 1. Database / all prefixes
# =============================================================================
section "1. Database and schema version registry"

_sf="$(printf '%s\n' "$OUT" | sed -n 's/^IHW:SECUREFILE|//p' | head -1)"
if [ "$_sf" = "FORCE" ]; then
    warn "db_securefile=FORCE – a new registry/RCU run would fail (ORA-43853, SYSTEM is not ASSM)"
else
    ok "db_securefile=${_sf:-?}"
fi
if printf '%s\n' "$OUT" | grep -q '^IHW:NOREG'; then
    fail "SYSTEM.SCHEMA_VERSION_REGISTRY\$ does not exist – no RCU repository in this DB"
    print_summary; exit 2
fi
ok "SYSTEM.SCHEMA_VERSION_REGISTRY\$ present"
printf "  %-3s %-10s %-7s %-7s %-20s %-14s %-11s %s\n" "" "Prefix" "Schemas" "Missing" "Profile(s)" "Status" "Expiry" "EBR" \
    | tee -a "${LOG_FILE:-/dev/null}"
while IFS='|' read -r t p n miss prof st exp ebr; do
    [ "$t" = "IHW:PREFIX" ] || continue
    mark="   "; [ "$p" = "$PFX" ] && mark=" * "
    printf "  %-3s %-10s %-7s %-7s %-20s %-14s %-11s %s\n" "$mark" "$p" "$n" "$miss" "$prof" "$st" "$exp" "$ebr" \
        | tee -a "${LOG_FILE:-/dev/null}"
    [ "$miss" != "0" ] && warn "  ${p}: ${miss} registry row(s) without database user (orphaned)"
done <<< "$OUT"
info "  * = this domain (DB_SCHEMA_PREFIX); other prefixes are only reported"
unset _sf

# =============================================================================
# 2. Registry rows of the prefix
# =============================================================================
section "2. Registry rows of prefix ${PFX}"

declare -A REG_OWNER=()
_n=0
while IFS='|' read -r t comp owner ver st upg ed; do
    [ "$t" = "REG" ] || continue
    _n=$((_n + 1)); REG_OWNER[$owner]="$comp"
    line="$(printf "%-14s %-18s %-12s %-8s upgraded=%s edition=%s" "$comp" "$owner" "$ver" "$st" "$upg" "$ed")"
    if [ "$st" = "VALID" ]; then ok "  $line"; else fail "  $line  (status not VALID)"; fi
    if [ "$RCU_DB_TYPE" = "EBR" ] && [ "$ed" = "-" ]; then
        warn "    ${owner}: no edition in the registry, but RCU_DB_TYPE=EBR"
    fi
done <<< "$OUT"
if [ "$_n" -eq 0 ]; then
    fail "No registry rows for prefix ${PFX} – RCU not run, wrong prefix or registry damaged"
    info "  See rcu_middleware_architecture.md 4.1"
fi

# =============================================================================
# 3. Schema accounts
# =============================================================================
section "3. Schema accounts (status, profile, password expiry)"

_users=()
while IFS='|' read -r t u st prof exp days ed; do
    [ "$t" = "USR" ] || continue
    _users+=("$u")
    line="$(printf "%-18s %-16s profile=%-10s expiry=%-10s editions=%s" "$u" "$st" "$prof" "$exp" "$ed")"
    if [ "$st" != "OPEN" ]; then
        fail "  $line  (account not OPEN)"
    elif [ "$days" != "-" ] && [ "$days" -lt "$WARN_DAYS" ] 2>/dev/null; then
        fail "  $line  (password expires in ${days} days)"
    elif [ "$prof" != "$RCU_DB_PROFILE" ]; then
        warn "  $line  (profile not ${RCU_DB_PROFILE} – password may expire)"
    else
        ok "  $line"
    fi
    if [ "$RCU_DB_TYPE" = "EBR" ] && [ "$ed" != "Y" ]; then
        warn "    ${u}: not editions-enabled, but RCU_DB_TYPE=EBR"
    elif [ "$RCU_DB_TYPE" = "ORACLE" ] && [ "$ed" = "Y" ]; then
        warn "    ${u}: editions-enabled, but RCU_DB_TYPE=ORACLE"
    fi
done <<< "$OUT"
for o in "${!REG_OWNER[@]}"; do
    printf '%s\n' "${_users[@]}" | grep -qx "$o" || fail "  registry owner $o has no database user"
done
if printf '%s\n' "$OUT" | grep '^USR|' | grep -qv "|${RCU_DB_PROFILE}|"; then
    info "  Assign the profile: 09-Install/07-oracle_setup_repository.sh --profile"
fi

# =============================================================================
# 4. Data sources of the domain
# =============================================================================
section "4. Data sources (\$DOMAIN_HOME/config/jdbc)"

if [ ! -d "${DOMAIN_HOME:-}/config/jdbc" ]; then
    warn "No data source directory: ${DOMAIN_HOME:-<DOMAIN_HOME not set>}/config/jdbc"
else
    for f in "$DOMAIN_HOME"/config/jdbc/*-jdbc.xml; do
        [ -f "$f" ] || continue
        ds="$(basename "$f" -jdbc.xml)"
        user="$(tr -d '\n' < "$f" | sed -n 's|.*<name>user</name>[[:space:]]*<value>\([^<]*\)</value>.*|\1|p')"
        url="$(sed -n 's|.*<url>\([^<]*\)</url>.*|\1|p' "$f" | head -1)"
        [ -z "$user" ] && { info "  $(printf '%-30s no user property - skipped' "$ds")"; continue; }
        msg="$(printf '%-30s user=%-18s' "$ds" "$user")"
        # user must be a registry schema of this prefix
        if [ -z "${REG_OWNER[${user^^}]:-}" ]; then
            warn "  $msg not an RCU schema of prefix ${PFX}"
            continue
        fi
        # URL must point to the repository DB of environment.conf
        u_lc="${url,,}"
        if [[ "$u_lc" != *"${DB_HOST,,}"*"${DB_PORT}"*"${DB_SERVICE,,}"* ]]; then
            warn "  $msg URL differs from ${DB_HOST}:${DB_PORT}/${DB_SERVICE}: ${url}"
        fi
        # login test with the schema password of db_sys_sec.conf.des3
        r="$("$SQLPLUS" -S -L /nolog <<SQLEOF 2>&1
CONNECT ${user}/"${DB_SCHEMA_PWD}"@//${DB_HOST}:${DB_PORT}/${DB_SERVICE}
SET HEADING OFF FEEDBACK OFF
SELECT 'LOGIN_OK' FROM dual;
EXIT;
SQLEOF
)"
        if printf '%s' "$r" | grep -q LOGIN_OK; then
            ok "  $msg login OK"
        else
            fail "  $msg login failed: $(printf '%s\n' "$r" | grep -oE 'ORA-[0-9]+[^\n]{0,60}' | head -1)"
        fi
    done
fi

# =============================================================================
# 5. Service table
# =============================================================================
section "5. Service table ${PFX}_STB"

if printf '%s\n' "$OUT" | grep -q '^STB|1'; then
    stb="$("$SQLPLUS" -S -L /nolog <<SQLEOF 2>&1
CONNECT ${PFX}_STB/"${DB_SCHEMA_PWD}"@//${DB_HOST}:${DB_PORT}/${DB_SERVICE}
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT 'STBN|' || COUNT(*) FROM component_schema_info;
EXIT;
SQLEOF
)"
    stbn="$(printf '%s\n' "$stb" | sed -n 's/^STBN|//p' | tr -d ' ')"
    if [ -z "$stbn" ]; then
        warn "Service table not readable as ${PFX}_STB"
    elif [ "$stbn" -eq "$_n" ]; then
        ok "COMPONENT_SCHEMA_INFO: ${stbn} rows = ${_n} registry rows"
    else
        warn "COMPONENT_SCHEMA_INFO: ${stbn} rows, registry: ${_n} – STB and registry differ"
    fi
else
    warn "No ${PFX}_STB.COMPONENT_SCHEMA_INFO – service table missing"
fi

# =============================================================================
# 6. Backup (--apply): Data Pump export
# =============================================================================
section "6. Backup (Data Pump)"

if ! $APPLY; then
    info "Read-only run – with --apply: Data Pump export of the ${PFX}_* schemas"
    info "  and SYSTEM.SCHEMA_VERSION_REGISTRY\$ (before an upgrade or a move)"
elif [ ! -x "$EXPDP" ]; then
    fail "expdp not found: $EXPDP"
elif [ ${#REG_OWNER[@]} -eq 0 ]; then
    fail "Nothing to export – no schemas of prefix ${PFX}"
else
    ts="$(date +%Y%m%d_%H%M%S)"
    schemas="$(printf '%s\n' "${!REG_OWNER[@]}" | sort | paste -sd, -)"
    dpdir="$(_sys_sql "SELECT directory_path FROM dba_directories WHERE directory_name = 'DATA_PUMP_DIR';" | head -1 | tr -d ' ')"
    printList "DATA_PUMP_DIR" 20 "${dpdir:-?} (on the DB server)"
    pf="$(mktemp)"; chmod 600 "$pf"
    # parfile holds the SYS password – remove it also on Ctrl-C / error
    trap 'DB_SYS_PWD=""; DB_SCHEMA_PWD=""; [ -n "${pf:-}" ] && { shred -u "$pf" 2>/dev/null || rm -f "$pf"; }' EXIT INT TERM
    # Note: Oracle recommends SYSDBA for Data Pump only when needed; on a
    # production DB a DBA may prefer an own export user.
    for job in schemas registry; do
        {
            printf "userid='sys/\"%s\"@//%s:%s/%s as sysdba'\n" "$DB_SYS_PWD" "$DB_HOST" "$DB_PORT" "$DB_SERVICE"
            printf 'directory=DATA_PUMP_DIR\n'
            printf 'dumpfile=rcu_%s_%s_%s.dmp\n' "$PFX" "$job" "$ts"
            printf 'logfile=rcu_%s_%s_%s.log\n' "$PFX" "$job" "$ts"
            if [ "$job" = "schemas" ]; then
                printf 'schemas=%s\n' "$schemas"
            else
                printf 'tables=SYSTEM.SCHEMA_VERSION_REGISTRY$\n'
            fi
        } > "$pf"
        info "expdp ${job}: rcu_${PFX}_${job}_${ts}.dmp"
        res="$("$EXPDP" parfile="$pf" 2>&1)"
        printf '%s\n' "$res" >> "${LOG_FILE:-/dev/null}"
        if printf '%s\n' "$res" | grep -q "successfully completed"; then
            ok "  ${job}: $(printf '%s\n' "$res" | grep -E 'successfully completed' | tail -1 | sed 's/^ *//')"
        else
            fail "  ${job}: export failed – $(printf '%s\n' "$res" | grep -E 'ORA-|UDE-|LRM-' | head -1)"
        fi
    done
    shred -u "$pf" 2>/dev/null || rm -f "$pf"
    info "Dump files on the DB server: ${dpdir:-DATA_PUMP_DIR}/rcu_${PFX}_*_${ts}.dmp (+ .log)"
fi

print_summary
exit "$EXIT_CODE"
