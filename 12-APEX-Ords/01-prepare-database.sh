#!/bin/bash
# =============================================================================
# Script   : 01-prepare-database.sh
# Purpose  : Prepare the target database (PDB) of an ORDS instance for APEX:
#              - container check (never CDB$ROOT), version, character set
#              - is APEX already installed (version / status / schema) and in
#                which tablespace do the APEX schemas live
#              - APEX tablespace (APEX_TABLESPACE) and temp tablespace
#                (APEX_TEMP_TABLESPACE, empty = DEFAULT_TEMP_TABLESPACE)
#              - ORDS repository (ORDS_METADATA) present?
#              - processes / sessions against the ORDS pool size
#              - DB profile APEX_DB_PROFILE (no expiry / lock-out) and the
#                runtime accounts (profile, expiry, status)
#            --apply creates APEX_TABLESPACE if missing (OMF, else next to the
#            SYSAUX file of the PDB) – it holds APEX **and** ORDS_METADATA –,
#            creates / aligns the profile, assigns it to the existing runtime
#            accounts and writes APEX_TABLESPACE / APEX_TEMP_TABLESPACE back to
#            environment.conf (02- / 04- read them).
# Call     : ./12-APEX-Ords/01-prepare-database.sh [--apply] [--instance N] [--sys-sec FILE]
# Options  : --instance N   ORDS instance (default 1): ORDS_<N>_DB_ALIAS
#            --sys-sec FILE encrypted SYS password (default db_sys_sec.conf.des3,
#                           key DB_SYS_PWD)
# Runs as  : oracle
# Requires : 00-Setup/install_db_client_tools.sh (SQL*Plus), TNS_ADMIN alias
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 12-APEX-Ords/README.md, 80-FMW-Architecture/apex_architecture.md
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
check_env_conf "$ENV_CONF" || exit 2
# shellcheck source=../environment.conf
source "$ENV_CONF"
# shellcheck source=apex_ords_lib.sh
source "$SCRIPT_DIR/apex_ords_lib.sh"

init_log

APPLY=false; INST=1; SYS_SEC="$ROOT_DIR/db_sys_sec.conf.des3"
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)    APPLY=true ;;
        --instance) INST="${2:-}"; shift ;;
        --sys-sec)  SYS_SEC="${2:-}"; shift ;;
        --help|-h)
            printf "Usage: %s [--apply] [--instance N] [--sys-sec FILE]\n" "$(basename "$0")"
            exit 0 ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 2 ;;
    esac
    shift
done

_av="ORDS_${INST}_DB_ALIAS"; ALIAS="${!_av:-}"
TS="${APEX_TABLESPACE:-APEX_DATA}"; TS="${TS^^}"
TEMP_CFG="${APEX_TEMP_TABLESPACE:-}"
PROFILE="${APEX_DB_PROFILE:-APEX_USER}"; PROFILE="${PROFILE^^}"

printLine
section "APEX target database – ords_${INST} ($(date '+%Y-%m-%d %H:%M:%S'))"
printList "TNS alias"        20 "${ALIAS:-($_av not set)}"
printList "APEX tablespace"  20 "$TS"
printList "Temp tablespace"  20 "${TEMP_CFG:-(DB default)}"
printList "DB profile"       20 "$PROFILE$( [ -z "${APEX_DB_PROFILE:-}" ] && printf '  (default – APEX_DB_PROFILE not set)')"
[ -n "$ALIAS" ] || { fail "$_av not set in environment.conf (interview block 4b)"; print_summary; exit 2; }
[ "${INSTALL_APEX:-false}" = "true" ] || warn "INSTALL_APEX is not true in environment.conf"

load_secrets_file "$SYS_SEC" > /dev/null 2>&1
IHW_SYS_PWD="${DB_SYS_PWD:-}"; unset DB_SYS_PWD DB_SCHEMA_PWD
[ -n "$IHW_SYS_PWD" ] || { fail "SYS password not found in $SYS_SEC (DB_SYS_PWD)"; print_summary; exit 2; }

# _q SQL – run as SYS, one result line per row ("KEY|...")

OUT="$(_q "
select 'CON|'||sys_context('userenv','con_name')||'|'||(select version_full from v\$instance) from dual;
select 'CS|'||value from nls_database_parameters where parameter = 'NLS_CHARACTERSET';
select 'APEX|'||version||'|'||status||'|'||schema from dba_registry where comp_id = 'APEX';
select 'USR|'||username||'|'||default_tablespace||'|'||account_status from dba_users
 where username like 'APEX\_2%' escape '\' or username in
       ('FLOWS_FILES','APEX_PUBLIC_USER','APEX_PUBLIC_ROUTER','APEX_REST_PUBLIC_USER','APEX_LISTENER','ORDS_METADATA','ORDS_PUBLIC_USER')
 order by username;
select 'SEG|'||tablespace_name||'|'||count(*)||'|'||round(sum(bytes)/1048576) from dba_segments
 where owner like 'APEX\_%' escape '\' or owner = 'FLOWS_FILES' group by tablespace_name;
select 'DEFTEMP|'||property_value from database_properties where property_name = 'DEFAULT_TEMP_TABLESPACE';
select 'TS|'||t.tablespace_name||'|'||t.contents||'|'||t.status||'|'||
       nvl((select round(sum(bytes)/1048576) from dba_data_files d where d.tablespace_name = t.tablespace_name),
           (select round(sum(bytes)/1048576) from dba_temp_files d where d.tablespace_name = t.tablespace_name))||'|'||
       nvl((select max(autoextensible) from dba_data_files d where d.tablespace_name = t.tablespace_name),
           (select max(autoextensible) from dba_temp_files d where d.tablespace_name = t.tablespace_name))||'|'||
       (select round(sum(bytes)/1048576) from dba_free_space f where f.tablespace_name = t.tablespace_name)
  from dba_tablespaces t where t.tablespace_name in ('$TS', upper('$TEMP_CFG'),
       (select property_value from database_properties where property_name = 'DEFAULT_TEMP_TABLESPACE'));
select 'OMF|'||value from v\$parameter where name = 'db_create_file_dest';
select 'SYSAUX|'||substr(file_name, 1, instr(file_name, '/', -1) - 1) from dba_data_files where tablespace_name = 'SYSAUX' and rownum = 1;
select 'PAR|'||name||'|'||value from v\$parameter where name in ('processes','sessions');
select 'PRF|'||resource_name||'|'||limit from dba_profiles
 where profile = '$PROFILE' and resource_name in ('PASSWORD_LIFE_TIME','FAILED_LOGIN_ATTEMPTS');
select 'RUN|'||username||'|'||profile||'|'||account_status||'|'||nvl(to_char(expiry_date,'YYYY-MM-DD'),'-')
  from dba_users where username in ('ORDS_PUBLIC_USER','APEX_PUBLIC_USER','APEX_REST_PUBLIC_USER','APEX_PUBLIC_ROUTER')
 order by username;
")"
if ! printf '%s\n' "$OUT" | grep -q '^CON|'; then
    fail "Cannot connect as SYS to $ALIAS"
    printf '%s\n' "$OUT" | grep -E 'ORA-|SP2-' | head -3 | sed 's/^/    /'
    print_summary; exit 2
fi
_v() { printf '%s\n' "$OUT" | sed -n "s/^$1|//p"; }

# =============================================================================
# 1. Database
# =============================================================================
section "Database"
IFS='|' read -r CON VER <<< "$(_v CON)"
printList "Container" 20 "$CON"
printList "Version"   20 "$VER"
if [ "$CON" = "CDB\$ROOT" ]; then
    fail "Connected to CDB\$ROOT – APEX belongs into the PDB; the TNS alias must name the PDB service"
else
    ok "PDB / non-CDB container: $CON"
fi
CS="$(_v CS)"
[ "$CS" = "AL32UTF8" ] && ok "Character set AL32UTF8" || warn "Character set $CS – AL32UTF8 recommended for APEX"

# =============================================================================
# 2. APEX already installed?
# =============================================================================
section "APEX in this database"
APEX_REG="$(_v APEX)"
if [ -z "$APEX_REG" ]; then
    info "No APEX in dba_registry – new installation"
else
    IFS='|' read -r A_VER A_STAT A_SCHEMA <<< "$APEX_REG"
    [ "$A_STAT" = "VALID" ] && ok "APEX $A_VER $A_STAT (schema $A_SCHEMA)" || warn "APEX $A_VER $A_STAT (schema $A_SCHEMA)"
fi
while IFS='|' read -r _u _ts _st; do
    [ -n "$_u" ] && info "$(printf "  %-22s tablespace %-12s %s" "$_u" "$_ts" "$_st")"
done <<< "$(_v USR)"
while IFS='|' read -r _ts _n _mb; do
    [ -n "$_ts" ] && info "$(printf "  APEX segments in %-12s %s segments, %s MB" "$_ts" "$_n" "$_mb")"
done <<< "$(_v SEG)"

# =============================================================================
# 3. Tablespaces
# =============================================================================
section "Tablespaces"
DEFTEMP="$(_v DEFTEMP)"
TEMP="${TEMP_CFG:-$DEFTEMP}"; TEMP="${TEMP^^}"
_tsline() { printf '%s\n' "$OUT" | grep "^TS|$1|"; }
if [ -n "$(_tsline "$TS")" ]; then
    IFS='|' read -r _ _n _c _s _mb _ae _free <<< "$(_tsline "$TS")"
    ok "$(printf "APEX tablespace %s: %s %s, %s MB, autoextend %s, free %s MB" "$TS" "$_c" "$_s" "$_mb" "$_ae" "${_free:-0}")"
    TS_EXISTS=true
else
    warn "APEX tablespace $TS does not exist – --apply creates it"
    TS_EXISTS=false
fi
if [ -n "$(_tsline "$TEMP")" ]; then
    ok "$(printf "Temp tablespace %s (%s)" "$TEMP" "$( [ -z "$TEMP_CFG" ] && printf 'DB default' || printf 'APEX_TEMP_TABLESPACE')")"
else
    fail "Temp tablespace $TEMP does not exist"
fi

# =============================================================================
# 4. ORDS repository, pool sizing
# =============================================================================
section "ORDS repository / sessions"
printf '%s\n' "$OUT" | grep -q '^USR|ORDS_METADATA|' \
    && info "ORDS_METADATA exists – ORDS repository installed (upgraded by ords install)" \
    || info "No ORDS_METADATA – created by 12-APEX-Ords/04-install-ords.sh (same tablespace as APEX)"
PROC="$(_v PAR | sed -n 's/^processes|//p')"
SESS="$(_v PAR | sed -n 's/^sessions|//p')"
printList "processes / sessions" 20 "${PROC:-?} / ${SESS:-?}"
[ "${PROC:-0}" -ge 300 ] && ok "processes >= 300 (one ORDS pool MaxLimit 50 + FMW + 50)" \
    || warn "processes ${PROC:-?} – rule: sum of jdbc.MaxLimit of all ORDS + RCU pools + 50..100"

# =============================================================================
# 4b. DB profile of the runtime accounts (never expire / lock – an expired
#     ORDS_PUBLIC_USER stops every APEX page)
# =============================================================================
section "DB profile $PROFILE / runtime accounts"
PRF_LT="$(_v PRF | sed -n 's/^PASSWORD_LIFE_TIME|//p')"
PRF_FL="$(_v PRF | sed -n 's/^FAILED_LOGIN_ATTEMPTS|//p')"
PROFILE_OK=false
if [ -z "$PRF_LT" ]; then
    warn "Profile $PROFILE does not exist – --apply creates it (apex_user_profile.sql)"
elif [ "$PRF_LT" = "UNLIMITED" ] && [ "$PRF_FL" = "UNLIMITED" ]; then
    ok "Profile $PROFILE: PASSWORD_LIFE_TIME / FAILED_LOGIN_ATTEMPTS UNLIMITED"; PROFILE_OK=true
else
    warn "Profile $PROFILE: PASSWORD_LIFE_TIME $PRF_LT, FAILED_LOGIN_ATTEMPTS $PRF_FL – --apply aligns it"
fi
RUN_NEED=false
while IFS='|' read -r _u _p _st _ex; do
    [ -n "$_u" ] || continue
    _line="$(printf "%-22s profile %-10s %-16s expiry %s" "$_u" "$_p" "$_st" "$_ex")"
    if [ "$_p" = "$PROFILE" ] && $PROFILE_OK; then
        ok "$_line"
    else
        warn "$_line – --apply assigns $PROFILE"; RUN_NEED=true
    fi
done <<< "$(_v RUN)"
[ -n "$(_v RUN)" ] || info "No runtime account yet (created by 02-install-apex.sh / 04-install-ords.sh – they assign the profile)"

# =============================================================================
# 5. Apply – create the APEX tablespace, write the names back
# =============================================================================
if $APPLY; then
    section "Apply"
    if ! $TS_EXISTS; then
        OMF="$(_v OMF)"
        if [ -n "$OMF" ]; then
            DF=""
        else
            DF="'$(_v SYSAUX)/${TS,,}01.dbf' "
        fi
        _r="$(_q "create tablespace $TS datafile ${DF}size 500m autoextend on next 100m maxsize 4g;
select 'DONE|'||tablespace_name from dba_tablespaces where tablespace_name = '$TS';")"
        if printf '%s\n' "$_r" | grep -q "^DONE|$TS"; then
            ok "Tablespace $TS created ($( [ -n "$OMF" ] && printf 'OMF %s' "$OMF" || printf '%s' "${DF//\'/}"))"
        else
            fail "create tablespace $TS failed"
            printf '%s\n' "$_r" | grep -E 'ORA-' | head -3 | sed 's/^/    /'
        fi
    fi
    if ! $PROFILE_OK || $RUN_NEED; then
        apex_profile_run assign
    fi
    # one value, one source: 02-install-apex.sh reads the names from environment.conf
    backup_file "$ENV_CONF" > /dev/null
    for _kv in "APEX_TABLESPACE=$TS" "APEX_TEMP_TABLESPACE=$TEMP"; do
        _k="${_kv%%=*}"; _val="${_kv#*=}"
        if grep -q "^${_k}=" "$ENV_CONF"; then
            sed -i --follow-symlinks "s|^${_k}=.*|${_k}=\"${_val}\"|" "$ENV_CONF"
        else
            printf '%s="%s"\n' "$_k" "$_val" >> "$(readlink -f "$ENV_CONF")"
        fi
        ok "environment.conf $_k=$_val"
    done
else
    info "Dry-run – --apply creates a missing APEX tablespace and the profile $PROFILE and writes the names to environment.conf"
fi
IHW_SYS_PWD=""

printLine
print_summary
exit "$EXIT_CODE"
