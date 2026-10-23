#!/bin/bash
# =============================================================================
# Script   : 02-install-apex.sh
# Purpose  : Install (or upgrade) Oracle APEX into the PDB of an ORDS instance:
#              1. unpack apex_<ver>.zip from the patch storage into
#                 $APEX_SW_BASE/APEX_<ver>
#              2. state: same version VALID = skip apexins, older = upgrade
#                 (confirmation), none = new installation
#              3. apexins.sql as SYS in the PDB (TS, TS, TEMP, IMAGE_PREFIX)
#              4. (patch set bundle: 03-patch-apex.sh)
#              5. ADMIN (apxchpwd.sql), APEX_REST_PUBLIC_USER
#                 (apex_rest_config.sql) – APEX 26.2: no APEX_LISTENER,
#                 APEX_PUBLIC_USER stays without password (proxy only)
#              6. language packs (APEX_LANGUAGES)
#              7. images -> $APEX_WEB_DIR/APEX_<ver>/, link apex_<N>
#            Passwords: SYS from db_sys_sec.conf.des3, ADMIN + REST user in
#            apex_sec.conf.des3 (generated if missing, merged) – never printed.
#            Runtime accounts get the profile APEX_DB_PROFILE (no expiry).
# Call     : ./12-APEX-Ords/02-install-apex.sh [--apply] [--instance N] [--sys-sec FILE]
#            [--languages] (load the language packs again)
# Runs as  : oracle
# Requires : 01-prepare-database.sh --apply, 00-Setup/install_db_client_tools.sh,
#            04-oracle_pre_download.sh (APEX ZIP), APEX_WEB_DIR (root, 03-)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 12-APEX-Ords/README.md, 80-FMW-Architecture/apex_architecture.md §2a
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"
SW_CONF="$ROOT_DIR/09-Install/oracle_software_version.conf"

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
# shellcheck source=../09-Install/oracle_software_version.conf
[ -f "$SW_CONF" ] && source "$SW_CONF"
# shellcheck source=apex_ords_lib.sh
source "$SCRIPT_DIR/apex_ords_lib.sh"

init_log

APPLY=false; INST=1; SYS_SEC="$ROOT_DIR/db_sys_sec.conf.des3"; LANGS_AGAIN=false
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)     APPLY=true ;;
        --instance)  INST="${2:-}"; shift ;;
        --sys-sec)   SYS_SEC="${2:-}"; shift ;;
        --languages) LANGS_AGAIN=true ;;
        --help|-h)
            printf "Usage: %s [--apply] [--instance N] [--sys-sec FILE] [--languages]\n" "$(basename "$0")"
            exit 0 ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 2 ;;
    esac
    shift
done

_av="ORDS_${INST}_DB_ALIAS";      ALIAS="${!_av:-}"
_ip="ORDS_${INST}_IMAGE_PREFIX";  IMGPR="${!_ip:-/i/}"
TS="${APEX_TABLESPACE:-APEX_DATA}"
TEMP="${APEX_TEMP_TABLESPACE:-TEMP}"
APEX_SEC="$ROOT_DIR/apex_sec.conf.des3"
SW_BASE="${APEX_SW_BASE:-$ORACLE_BASE/product/apex}"
WEB="${APEX_WEB_DIR:-/srv/apex}"

APEX_ZIP="$(otn_newest_zip "$PATCH_STORAGE/apex" 'apex_*.zip')"
VER="$( [ -n "$APEX_ZIP" ] && basename "$(dirname "$APEX_ZIP")")"
APEX_HOME="$SW_BASE/APEX_${VER}/apex"

printLine
section "APEX installation – ords_${INST} ($(date '+%Y-%m-%d %H:%M:%S'))"
printList "APEX ZIP"        20 "${APEX_ZIP:-(none – 09-Install/04-oracle_pre_download.sh --apply)}"
printList "Version"         20 "${VER:-?}"
printList "TNS alias"       20 "${ALIAS:-($_av not set)}"
printList "Tablespace/temp" 20 "$TS / $TEMP"
printList "Image prefix"    20 "$IMGPR"
printList "Languages"       20 "${APEX_LANGUAGES:-(English only)}"
printList "Images for Nginx" 20 "$WEB/APEX_${VER}  (link $WEB/apex_${INST})"

[ -n "$APEX_ZIP" ] || { fail "No APEX ZIP in $PATCH_STORAGE/apex/"; print_summary; exit 2; }
[ -n "$ALIAS" ]    || { fail "$_av not set (interview block 4b)"; print_summary; exit 2; }

load_secrets_file "$SYS_SEC" > /dev/null 2>&1
IHW_SYS_PWD="${DB_SYS_PWD:-}"; unset DB_SYS_PWD DB_SCHEMA_PWD
[ -n "$IHW_SYS_PWD" ] || { fail "SYS password not found in $SYS_SEC (DB_SYS_PWD)"; print_summary; exit 2; }


# _run_sql_file / _sql_errors: apex_ords_lib.sh

# =============================================================================
# 0. Prerequisites
# =============================================================================
section "Prerequisites"
STATE="$(_q "select 'CON|'||sys_context('userenv','con_name') from dual;
select 'APEX|'||version||'|'||status||'|'||schema from dba_registry where comp_id = 'APEX';
select 'TS|'||tablespace_name from dba_tablespaces where tablespace_name in (upper('$TS'), upper('$TEMP'));
select 'USR|'||username from dba_users where username in ('APEX_REST_PUBLIC_USER');")"
printf '%s\n' "$STATE" | grep -q '^CON|' || { fail "Cannot connect as SYS to $ALIAS"; print_summary; exit 2; }
CON="$(printf '%s\n' "$STATE" | sed -n 's/^CON|//p')"
[ "$CON" = "CDB\$ROOT" ] && { fail "Connected to CDB\$ROOT – APEX belongs into the PDB"; print_summary; exit 2; }
ok "Container $CON"
for _t in "${TS^^}" "${TEMP^^}"; do
    printf '%s\n' "$STATE" | grep -qx "TS|$_t" && ok "Tablespace $_t exists" \
        || fail "Tablespace $_t missing – run 12-APEX-Ords/01-prepare-database.sh --apply"
done
[ -d "$WEB" ] && [ -w "$WEB" ] && ok "$WEB writable" \
    || fail "$WEB missing or not writable – root: 09-Install/03-root_user_oracle.sh --apply (INSTALL_APEX=true)"
_ihw_sp="$(ihw_sqlplus -V 2>/dev/null | grep -m1 "Release")"
[ -n "$_ihw_sp" ] && ok "$_ihw_sp" || fail "No SQL*Plus – 00-Setup/install_db_client_tools.sh --apply"

IFS='|' read -r CUR_VER CUR_STAT CUR_SCHEMA <<< "$(printf '%s\n' "$STATE" | sed -n 's/^APEX|//p')"
CUR_MM="$(printf '%s' "${CUR_VER:-}" | cut -d. -f1-2)"
if [ -z "${CUR_VER:-}" ]; then
    MODE="install";  info "No APEX in the database – new installation of $VER"
elif [ "$CUR_MM" = "$VER" ] && [ "$CUR_STAT" = "VALID" ]; then
    MODE="present";  ok "APEX $CUR_VER VALID already installed (schema $CUR_SCHEMA) – apexins skipped"
elif [ "$(printf '%s\n%s\n' "$CUR_MM" "$VER" | sort -V | head -1)" = "$CUR_MM" ] && [ "$CUR_MM" != "$VER" ]; then
    MODE="upgrade";  warn "APEX $CUR_VER installed – UPGRADE to $VER (stop ORDS, database backup first)"
else
    MODE="other";    fail "APEX $CUR_VER $CUR_STAT – neither older nor a VALID $VER: check by hand"
fi

if [ "$EXIT_CODE" -ne 0 ] || [ "${CNT_FAIL:-0}" -gt 0 ] || ! $APPLY; then
    $APPLY || info "Dry-run – --apply runs the steps (apexins 20-45 min)"
    IHW_SYS_PWD=""; printLine; print_summary; exit "$EXIT_CODE"
fi
if [ "$MODE" = "upgrade" ] && ! askYesNo "Upgrade APEX $CUR_VER -> $VER now (ORDS stopped, DB backup done)?" "n"; then
    info "Aborted – nothing changed"; IHW_SYS_PWD=""; print_summary; exit 0
fi

SQLLOG="$(dirname "$LOG_FILE")/apex_install_${VER}_$(date +%H%M%S).log"
info "SQL*Plus spool: $SQLLOG"

# =============================================================================
# 1. Unpack
# =============================================================================
section "Unpack"
if [ -f "$APEX_HOME/apexins.sql" ]; then
    ok "already unpacked: $APEX_HOME"
else
    mkdir -p "$SW_BASE/APEX_${VER}" && unzip -q -o "$APEX_ZIP" -d "$SW_BASE/APEX_${VER}" \
        && ok "unpacked: $APEX_HOME" || { fail "unzip failed"; print_summary; exit 2; }
fi

# =============================================================================
# 2. apexins.sql (install / upgrade)
# =============================================================================
if [ "$MODE" = "install" ] || [ "$MODE" = "upgrade" ]; then
    section "apexins.sql ($MODE) – 20-45 minutes"
    info "started $(date '+%H:%M:%S') – progress: tail -f $SQLLOG"
    _run_sql_file "$APEX_HOME" "$SQLLOG" "@apexins.sql ${TS^^} ${TS^^} ${TEMP^^} $IMGPR"
    info "finished $(date '+%H:%M:%S') – apexins also writes install*.log in $APEX_HOME"
    R="$(_q "select 'APEX|'||version||'|'||status||'|'||schema from dba_registry where comp_id = 'APEX';")"
    IFS='|' read -r CUR_VER CUR_STAT CUR_SCHEMA <<< "$(printf '%s\n' "$R" | sed -n 's/^APEX|//p')"
    if [ "$CUR_STAT" = "VALID" ]; then
        ok "APEX $CUR_VER VALID (schema $CUR_SCHEMA)"
    else
        fail "APEX ${CUR_VER:-?} ${CUR_STAT:-not registered} – see $SQLLOG"
        IHW_SYS_PWD=""; print_summary; exit 2
    fi
fi

# =============================================================================
# 4. Accounts (APEX 26.2): ADMIN + APEX_REST_PUBLIC_USER
# =============================================================================
section "Accounts"
[ -f "$APEX_SEC" ] && load_secrets_file "$APEX_SEC" > /dev/null 2>&1
_gen() { printf 'Ax%s9#' "$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-18)"; }
NEW_SEC=false
[ -n "${APEX_ADMIN_PWD:-}" ] || { APEX_ADMIN_PWD="$(_gen)"; NEW_SEC=true; warn "No APEX ADMIN password in $(basename "$APEX_SEC") – generated a random one"; }
[ -n "${APEX_REST_PUBLIC_PWD:-}" ] || { APEX_REST_PUBLIC_PWD="Ar$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-20)7"; NEW_SEC=true; }
if $NEW_SEC; then
    merge_secrets_file "$APEX_SEC" "APEX_ADMIN_USER=ADMIN" "APEX_ADMIN_PWD=$APEX_ADMIN_PWD" \
        "APEX_REST_PUBLIC_PWD=$APEX_REST_PUBLIC_PWD" > /dev/null \
        && ok "passwords stored: $(basename "$APEX_SEC")" || fail "cannot write $APEX_SEC"
    info "  show: bash -c 'source 00-Setup/IHateWeblogic_lib.sh; load_secrets_file $APEX_SEC; printf \"%s\\n\" \"\$APEX_ADMIN_PWD\"'"
fi
_admin_exists() {
    _q "select 'ADM|'||count(*) from ${CUR_SCHEMA:-APEX_260200}.wwv_flow_fnd_user
         where security_group_id = 10 and user_name = 'ADMIN';" | grep -qx 'ADM|1'
}
# _sql_pwd_lit VALUE – value as SQL literal ('' escaped)
_sql_pwd_lit() { printf "'%s'" "${1//\'/\'\'}"; }
if [ "$MODE" = "install" ] || [ "$MODE" = "upgrade" ] || $NEW_SEC || ! _admin_exists; then
    # Same calls as apxchpwd.sql, without its ACCEPT ... HIDE: without a TTY
    # SQL*Plus does not read a HIDE answer from stdin (password arrives empty,
    # the input line then runs as a command and is echoed in SP2-0734 –
    # live 2026-10-23). Password -> bind variable via CALL under
    # cursor_sharing=force (no literal in the shared pool), as apxchpwd does.
    _o="$(_run_sql_file "$APEX_HOME" - "set define off verify off feedback off
whenever sqlerror exit failure
alter session set current_schema = ${CUR_SCHEMA:-APEX_260200};
variable PASSWORD varchar2(128)
create or replace procedure wwv_flow_assign_pwd (p_dest out varchar2, p_src in varchar2) is
begin p_dest := p_src; end wwv_flow_assign_pwd;
/
alter session set cursor_sharing=force;
call wwv_flow_assign_pwd(:PASSWORD, $(_sql_pwd_lit "$APEX_ADMIN_PWD"));
alter session set cursor_sharing=exact;
drop procedure wwv_flow_assign_pwd;
begin
    wwv_flow_instance_admin.create_or_update_admin_user (
        p_username => 'ADMIN',
        p_email    => $(_sql_pwd_lit "${APEX_ADMIN_EMAIL:-ADMIN}"),
        p_password => :PASSWORD );
    commit;
end;
/")"
    _e="$(_sql_errors "$_o")"
    if [ -z "$_e" ] && _admin_exists; then
        ok "Instance administrator ADMIN set (create_or_update_admin_user)"
    else
        fail "apxchpwd.sql failed: ${_e:-ADMIN not found} (output not logged – contains input)"
    fi
else
    ok "Instance administrator ADMIN exists (password in $(basename "$APEX_SEC"))"
fi
if printf '%s\n' "$STATE" | grep -qx 'USR|APEX_REST_PUBLIC_USER' && [ "$MODE" = "present" ]; then
    ok "APEX_REST_PUBLIC_USER exists (apex_rest_config.sql not repeated)"
else
    # one ACCEPT: password of APEX_REST_PUBLIC_USER (26.2: APEX_LISTENER gone)
    # its ACCEPT ... HIDE stays empty without a TTY (see ADMIN above); the core
    # script then asks "Enter value for 2" and reads the next line – works,
    # but echoes it, so: no spool, and the password is set again afterwards
    # with ALTER USER (DDL passwords are not kept in v$sql)
    _o="$(_run_sql_file "$APEX_HOME" - "@apex_rest_config.sql
$APEX_REST_PUBLIC_PWD
alter user APEX_REST_PUBLIC_USER identified by \"${APEX_REST_PUBLIC_PWD//\"/}\";")"
    _q "select 'USR|'||username||'|'||account_status from dba_users where username = 'APEX_REST_PUBLIC_USER';" \
        | grep -q '^USR|APEX_REST_PUBLIC_USER|OPEN' && ok "APEX_REST_PUBLIC_USER created (static files)" \
        || fail "APEX_REST_PUBLIC_USER not OPEN: $(_sql_errors "$_o")"
fi
info "APEX_PUBLIC_USER stays without password (26.2 – ORDS reaches it through the proxy right)"
unset APEX_ADMIN_PWD APEX_REST_PUBLIC_PWD
# runtime accounts: profile without expiry / lock-out (01-prepare-database.sh)
apex_profile_run assign

# =============================================================================
# 5. Language packs
# =============================================================================
if [ -n "${APEX_LANGUAGES:-}" ]; then
    section "Language packs: $APEX_LANGUAGES"
    if [ "$MODE" = "install" ] || [ "$MODE" = "upgrade" ] || $LANGS_AGAIN; then
        for _l in $APEX_LANGUAGES; do
            if [ -f "$APEX_HOME/builder/$_l/load_$_l.sql" ]; then
                _run_sql_file "$APEX_HOME/builder/$_l" "$SQLLOG" "@load_$_l.sql $_l"
                ok "language pack $_l loaded"
            else
                warn "no language pack $_l in $APEX_HOME/builder/"
            fi
        done
    else
        ok "not reloaded (APEX already installed) – --languages to load again"
    fi
fi

# =============================================================================
# 6. Images for Nginx – copy per version, link per ORDS instance
# =============================================================================
section "Images for Nginx"
IMG_DIR="$WEB/APEX_${VER}"
if [ -f "$IMG_DIR/apex_version.txt" ]; then
    ok "already copied: $IMG_DIR"
else
    mkdir -p "$IMG_DIR" && cp -r "$APEX_HOME/images/." "$IMG_DIR/" \
        && ok "copied: $IMG_DIR ($(du -sh "$IMG_DIR" | cut -f1))" || fail "copy to $IMG_DIR failed"
fi
chmod -R u=rwX,go=rX "$IMG_DIR"
# keep a link to a patched copy of the same release (APEX_<ver>_p<nr>, 03-)
_cur="$(readlink "$WEB/apex_${INST}" 2>/dev/null)"
if [[ "$_cur" == "APEX_${VER}"* ]]; then
    ok "link $WEB/apex_${INST} -> $_cur (kept)"
else
    ln -sfn "APEX_${VER}" "$WEB/apex_${INST}" && ok "link $WEB/apex_${INST} -> APEX_${VER}${_cur:+ (was $_cur)}"
fi
info "Nginx: location ${IMGPR} { alias $WEB/apex_${INST}/; }  (12-APEX-Ords/README.md §5.7)"

[ -n "${APEX_PATCH_NR:-}" ] && info "Next: 12-APEX-Ords/03-patch-apex.sh --apply (APEX_PATCH_NR=$APEX_PATCH_NR)"

IHW_SYS_PWD=""
printLine
print_summary
exit "$EXIT_CODE"
