#!/bin/bash
# =============================================================================
# Script   : 06-patch-ords.sh
# Purpose  : New ORDS release for an instance (ords_N) = new installation
#            beside the old one, link switch, repository upgrade:
#              1. newest ORDS ZIP in the patch storage > linked version?
#                 ORDS >= APEX and APEXlang compiler in ords.war >= APEX
#              2. unpack ords-<new>, stop ords@ords_N, link ords_N/ords -> new
#              3. ords install (existing pool) = upgrade of ORDS_METADATA –
#                 ONE-WAY: a database backup before is the only way back
#              4. start, wait, HTTP check, repository version
#            --rollback: link back to the previous ords-<ver> – only while
#            ORDS_METADATA is still on that version (else: restore the DB).
#            --keep N: keep N ords-<ver> directories (default 2), never the
#            linked one.
# Call     : ./12-APEX-Ords/06-patch-ords.sh [--apply] [--instance N] [--rollback]
#            [--keep N] [--sys-sec FILE]
# Runs as  : oracle (systemctl via sudo)
# Requires : 04-install-ords.sh, new ZIP from 09-Install/04-oracle_pre_download.sh
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 12-APEX-Ords/README.md §6, 80-FMW-Architecture/ords_architecture.md
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

APPLY=false; INST=1; ROLLBACK=false; KEEP=2; SYS_SEC="$ROOT_DIR/db_sys_sec.conf.des3"
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)    APPLY=true ;;
        --instance) INST="${2:-}"; shift ;;
        --rollback) ROLLBACK=true ;;
        --keep)     KEEP="${2:-2}"; shift ;;
        --sys-sec)  SYS_SEC="${2:-}"; shift ;;
        --help|-h)
            printf "Usage: %s [--apply] [--instance N] [--rollback] [--keep N] [--sys-sec FILE]\n" "$(basename "$0")"
            exit 0 ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 2 ;;
    esac
    shift
done

_v() { local n="ORDS_${INST}_$1"; printf '%s' "${!n:-$2}"; }
ALIAS="$(_v DB_ALIAS "")"
PORT="$(_v PORT $((8080 + INST)))"
CTX="$(_v CONTEXT "/ords")"
APEX_ORDS_BASE="${APEX_ORDS_BASE:-$ORACLE_BASE/product/ords}"
HOME_N="$APEX_ORDS_BASE/ords_${INST}"
UNIT="ords@ords_${INST}.service"
TS="${APEX_TABLESPACE:-APEX_DATA}"; TS="${TS^^}"
TEMP="${APEX_TEMP_TABLESPACE:-TEMP}"; TEMP="${TEMP^^}"

ORDS_ZIP="$(otn_newest_zip "$PATCH_STORAGE/ords" 'ords*.zip')"
NEW_VER="$( [ -n "$ORDS_ZIP" ] && ords_zip_ver "$ORDS_ZIP")"
CUR_VER="$(ords_linked_ver "$INST")"

printLine
section "ORDS release change – ords_${INST} ($(date '+%Y-%m-%d %H:%M:%S'))"
printList "Linked"        20 "${CUR_VER:-(none – 04-install-ords.sh first)}"
printList "Newest ZIP"    20 "${NEW_VER:-(none)}"
printList "Installed"     20 "$(ls -d "$APEX_ORDS_BASE"/ords-* 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
[ -n "$CUR_VER" ] || { fail "ords_${INST} has no linked ORDS – 04-install-ords.sh"; print_summary; exit 2; }
[ -n "$ALIAS" ]   || { fail "ORDS_${INST}_DB_ALIAS not set"; print_summary; exit 2; }

load_secrets_file "$SYS_SEC" > /dev/null 2>&1
IHW_SYS_PWD="${DB_SYS_PWD:-}"; unset DB_SYS_PWD DB_SCHEMA_PWD
[ -n "$IHW_SYS_PWD" ] || { fail "SYS password not found in $SYS_SEC (DB_SYS_PWD)"; print_summary; exit 2; }
REPO="$(ords_repo_ver)"
printList "ORDS_METADATA" 20 "${REPO:-?}"

# restart + check, used by both paths
_start_check() {
    ihw_run_root systemctl start "$UNIT" && ok "$UNIT started"
    local code; code="$(ords_wait_http "http://127.0.0.1:${PORT}${CTX}/" 150)"
    if [ "${code:-000}" != "000" ] && [ "$code" -lt 500 ]; then
        ok "ORDS answers: HTTP $code ($(ords_cmd "$INST" --version 2>&1 | grep -m1 'Oracle REST Data Services'))"
    else
        fail "ORDS does not answer (HTTP ${code:-none}) – journalctl -u $UNIT"
    fi
}

# =============================================================================
# Rollback – link back while the repository still fits the old software
# =============================================================================
if $ROLLBACK; then
    section "Rollback"
    PREV="$(ls -d "$APEX_ORDS_BASE"/ords-* 2>/dev/null | xargs -n1 basename | sed 's/^ords-//' \
            | grep -vx "$CUR_VER" | sort -V | tail -1)"
    [ -n "$PREV" ] || { fail "no previous ords-<ver> directory left"; print_summary; exit 2; }
    # repository version looks like 26.3.0.r2721811, software 26.3.0.272.1811
    _rmm="$(printf '%s' "$REPO" | cut -d. -f1-3)"; _pmm="$(printf '%s' "$PREV" | cut -d. -f1-3)"
    if [ "$_rmm" != "$_pmm" ]; then
        fail "ORDS_METADATA is $REPO, previous software $PREV – the repository was upgraded; rollback = restore the database backup"
        print_summary; exit 2
    fi
    info "link ords_${INST}/ords: ords-$CUR_VER -> ords-$PREV"
    if $APPLY; then
        ihw_run_root systemctl stop "$UNIT" && ok "$UNIT stopped"
        ln -sfn "../ords-$PREV" "$HOME_N/ords" && ok "link -> ords-$PREV"
        _start_check
    else
        info "Dry-run – --apply --rollback switches the link back"
    fi
    IHW_SYS_PWD=""; printLine; print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# 0. Checks
# =============================================================================
section "Checks"
if [ -z "$NEW_VER" ] || ver_ge "$CUR_VER" "$NEW_VER"; then
    ok "ORDS $CUR_VER is the newest in the patch storage – nothing to do (download: 04-oracle_pre_download.sh)"
    DO_UPGRADE=false
else
    info "ORDS $CUR_VER -> $NEW_VER"
    DO_UPGRADE=true
    _apex="$(_q "select 'APEX|'||version from dba_registry where comp_id = 'APEX';" | sed -n 's/^APEX|//p' | cut -d. -f1-2)"
    if [ -n "$_apex" ]; then
        ver_ge "$NEW_VER" "$_apex" && ok "ORDS $NEW_VER >= APEX $_apex" || fail "ORDS $NEW_VER older than APEX $_apex"
        _wd="$(mktemp -d)"; unzip -q -o "$ORDS_ZIP" ords.war -d "$_wd" 2>/dev/null
        _al="$(ords_apexlang_ver "$_wd")"; rm -rf "$_wd"
        [ -n "$_al" ] && ver_ge "$_al" "$_apex" && ok "APEXlang compiler $_al >= APEX $_apex" \
            || fail "APEXlang compiler ${_al:-none} in the new ords.war does not fit APEX $_apex"
    fi
    warn "ords install upgrades ORDS_METADATA ($REPO) – one-way, take a DB backup first"
fi

# =============================================================================
# Clean-up of old software (--keep), never the linked one
# =============================================================================
_cleanup() {
    local keep="$1" d n=0
    for d in $(ls -d "$APEX_ORDS_BASE"/ords-* 2>/dev/null | sort -V -r); do
        n=$((n + 1))
        [ "$n" -le "$keep" ] && continue
        [ "$(basename "$d")" = "ords-$(ords_linked_ver "$INST")" ] && continue
        if $APPLY; then rm -rf "$d" && ok "removed old $(basename "$d")"; else info "would remove $(basename "$d") (--keep $keep)"; fi
    done
}

if ! $DO_UPGRADE || ! $APPLY || [ "${CNT_FAIL:-0}" -gt 0 ]; then
    _cleanup "$KEEP"
    $DO_UPGRADE && ! $APPLY && info "Dry-run – --apply installs ords-$NEW_VER, upgrades the repository, switches the link"
    IHW_SYS_PWD=""; printLine; print_summary; exit "$EXIT_CODE"
fi
askYesNo "Upgrade ords_${INST} to $NEW_VER now (DB backup taken, short downtime)?" "n" \
    || { info "Aborted – nothing changed"; IHW_SYS_PWD=""; print_summary; exit 0; }

# =============================================================================
# 1. Software, stop, link
# =============================================================================
section "Software"
SW_DIR="$(ords_unpack "$ORDS_ZIP")" && ok "unpacked: $SW_DIR" || { fail "unzip failed"; print_summary; exit 2; }
ihw_run_root systemctl stop "$UNIT" && ok "$UNIT stopped"
ln -sfn "../ords-$NEW_VER" "$HOME_N/ords" && ok "link ords_${INST}/ords -> ords-$NEW_VER (rollback until the upgrade: --rollback)"

# =============================================================================
# 2. Repository upgrade (only the admin password – the pool exists)
# =============================================================================
section "ords install (repository upgrade)"
INST_LOG="$(dirname "$LOG_FILE")/ords_upgrade_${INST}_$(date +%H%M%S)"
mkdir -p "$INST_LOG"
ords_cmd "$INST" install --db-only --admin-user "SYS AS SYSDBA" \
    --schema-tablespace "$TS" --schema-temp-tablespace "$TEMP" \
    --log-folder "$INST_LOG" --password-stdin > "$INST_LOG/ords_install_stdout.log" 2>&1 <<EOF
$IHW_SYS_PWD
EOF
_rc=$?
NEW_REPO="$(ords_repo_ver)"
if [ "$_rc" -eq 0 ] && [ "$NEW_REPO" != "$REPO" ]; then
    ok "ORDS_METADATA $REPO -> $NEW_REPO"
elif [ "$_rc" -eq 0 ]; then
    warn "ords install rc=0, repository still $NEW_REPO – see $INST_LOG"
else
    fail "ords install rc=$_rc – see $INST_LOG (link still on ords-$NEW_VER; --rollback if the repository is unchanged)"
fi

# =============================================================================
# 3. Start + check, clean-up
# =============================================================================
section "Start"
_start_check
_cleanup "$KEEP"

IHW_SYS_PWD=""
printLine
print_summary
exit "$EXIT_CODE"
