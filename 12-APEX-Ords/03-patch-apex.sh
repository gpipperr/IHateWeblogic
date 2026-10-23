#!/bin/bash
# =============================================================================
# Script   : 03-patch-apex.sh
# Purpose  : Apply an APEX patch set bundle (APEX_PATCH_NR) to the PDB of an
#            ORDS instance – patch README "Patch Installation Instructions":
#              1. patch ZIP from $PATCH_STORAGE/apex/<ver>/patch/<nr>/
#                 (04-oracle_pre_download.sh --apply --mos, platform 2000P)
#              2. already in APEX_PATCHES -> nothing to do; base release check
#              3. stop ORDS (no access during the patch), catpatch.sql as SYS
#                 in the PDB, start ORDS
#              4. images: copy APEX_<ver> -> APEX_<ver>_p<nr>, patch images
#                 over it, link apex_N -> new copy (rollback = link back)
#            Patch = APEX_PATCHES row with PATCH_VERSION / IMAGES_VERSION /
#            APEXLANG_VERSION (APEXlang compiler of ORDS must fit – see
#            80-FMW-Architecture/ords_architecture.md).
# Call     : ./12-APEX-Ords/03-patch-apex.sh [--apply] [--instance N] [--sys-sec FILE]
# Runs as  : oracle (ORDS stop/start via sudo, else the commands are printed)
# Requires : 02-install-apex.sh, APEX_PATCH_NR in oracle_software_version.conf
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 12-APEX-Ords/README.md §6, apex_architecture.md
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
NR="${APEX_PATCH_NR:-}"
SW_BASE="${APEX_SW_BASE:-$ORACLE_BASE/product/apex}"
WEB="${APEX_WEB_DIR:-/srv/apex}"
UNIT="ords@ords_${INST}.service"

printLine
section "APEX patch set bundle – ords_${INST} ($(date '+%Y-%m-%d %H:%M:%S'))"
printList "APEX_PATCH_NR" 20 "${NR:-(not set – 09-Install/oracle_software_version.conf)}"
printList "TNS alias"     20 "${ALIAS:-($_av not set)}"
if [ -z "$NR" ]; then
    info "No patch set bundle configured – nothing to do"
    print_summary; exit 0
fi
[ -n "$ALIAS" ] || { fail "$_av not set (interview block 4b)"; print_summary; exit 2; }

load_secrets_file "$SYS_SEC" > /dev/null 2>&1
IHW_SYS_PWD="${DB_SYS_PWD:-}"; unset DB_SYS_PWD DB_SCHEMA_PWD
[ -n "$IHW_SYS_PWD" ] || { fail "SYS password not found in $SYS_SEC (DB_SYS_PWD)"; print_summary; exit 2; }

# =============================================================================
# 0. State
# =============================================================================
section "State"
R="$(_q "select 'APEX|'||version||'|'||status||'|'||schema from dba_registry where comp_id = 'APEX';")"
IFS='|' read -r CUR_VER CUR_STAT SCHEMA <<< "$(printf '%s\n' "$R" | sed -n 's/^APEX|//p')"
[ -n "${CUR_VER:-}" ] || { fail "No APEX in the database – 02-install-apex.sh first"; print_summary; exit 2; }
VER="$(printf '%s' "$CUR_VER" | cut -d. -f1-2)"
[ "$CUR_STAT" = "VALID" ] && ok "APEX $CUR_VER VALID (schema $SCHEMA)" || warn "APEX $CUR_VER $CUR_STAT"
PATCHES="$(_q "select 'P|'||patch_number||'|'||patch_version||'|'||images_version||'|'||apexlang_version||'|'||to_char(installed_on,'YYYY-MM-DD')
  from ${SCHEMA}.apex_patches order by installed_on;" | sed -n 's/^P|//p')"
while IFS='|' read -r _n _pv _iv _lv _on; do
    [ -n "$_n" ] && info "$(printf "  installed: patch %s  version %s  images %s  APEXlang %s  (%s)" "$_n" "$_pv" "$_iv" "$_lv" "$_on")"
done <<< "$PATCHES"
if printf '%s\n' "$PATCHES" | grep -q "^${NR}|"; then
    ok "Patch $NR already installed – database part done"
    DB_DONE=true
else
    DB_DONE=false
fi

PZ="$(ls "$PATCH_STORAGE/apex/$VER/patch/$NR"/p"${NR}"_*.zip 2>/dev/null | head -1)"
if [ -z "$PZ" ]; then
    $DB_DONE || { fail "No patch ZIP in $PATCH_STORAGE/apex/$VER/patch/$NR/ – 09-Install/04-oracle_pre_download.sh --apply --mos"; print_summary; exit 2; }
else
    ok "Patch ZIP: $PZ"
    # base release of the bundle = <ver> in p<nr>_<261>_Generic.zip -> 26.1
    _base="$(basename "$PZ" | sed -n 's/^p[0-9]*_\([0-9]\)\([0-9]\)\([0-9]\)_.*/\1\2.\3/p')"
    if [ -n "$_base" ] && [ "$_base" != "$VER" ]; then
        fail "Patch $NR is for APEX $_base, the database has APEX $VER"; print_summary; exit 2
    fi
fi
PATCH_HOME="$SW_BASE/APEX_${VER}_patch_${NR}"
IMG_NEW="$WEB/APEX_${VER}_p${NR}"
ORDS_ACTIVE=false
systemctl is-active --quiet "$UNIT" 2>/dev/null && ORDS_ACTIVE=true
printList "ORDS ($UNIT)" 20 "$($ORDS_ACTIVE && printf 'running – stopped during catpatch' || printf 'not running')"
printList "Images"       20 "$IMG_NEW  (link $WEB/apex_${INST})"

if ! $APPLY; then
    info "Dry-run – --apply stops ORDS, runs catpatch.sql, starts ORDS, switches the images"
    IHW_SYS_PWD=""; printLine; print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# 1. Unpack
# =============================================================================
section "Unpack"
if [ -n "$PZ" ] && [ ! -f "$PATCH_HOME/$NR/catpatch.sql" ]; then
    mkdir -p "$PATCH_HOME" && unzip -q -o "$PZ" -d "$PATCH_HOME" \
        && ok "unpacked: $PATCH_HOME/$NR" || { fail "unzip failed"; print_summary; exit 2; }
else
    ok "already unpacked: $PATCH_HOME/$NR"
fi

# =============================================================================
# 2. catpatch.sql (ORDS stopped – no APEX access during the patch)
# =============================================================================
if ! $DB_DONE; then
    section "catpatch.sql"
    if $ORDS_ACTIVE; then
        ihw_run_root systemctl stop "$UNIT" && ok "ORDS stopped ($UNIT)" \
            || { fail "Cannot stop $UNIT – stop ORDS, then run again"; print_summary; exit 2; }
    fi
    SQLLOG="$(dirname "$LOG_FILE")/apex_patch_${NR}_$(date +%H%M%S).log"
    info "started $(date '+%H:%M:%S') – spool $SQLLOG"
    _run_sql_file "$PATCH_HOME/$NR" "$SQLLOG" "@catpatch.sql"
    info "finished $(date '+%H:%M:%S')"
    R="$(_q "select 'P|'||patch_version||'|'||apexlang_version from ${SCHEMA}.apex_patches where patch_number = $NR;
select 'APEX|'||status from dba_registry where comp_id = 'APEX';
select 'INV|'||count(*) from dba_objects where owner = '$SCHEMA' and status = 'INVALID';")"
    _pv="$(printf '%s\n' "$R" | sed -n 's/^P|//p')"
    [ -n "$_pv" ] && ok "Patch $NR installed: version ${_pv%%|*}, APEXlang ${_pv#*|}" \
        || fail "Patch $NR not in APEX_PATCHES – see $SQLLOG"
    [ "$(printf '%s\n' "$R" | sed -n 's/^APEX|//p')" = "VALID" ] && ok "APEX registry VALID" \
        || fail "APEX registry not VALID after the patch – see $SQLLOG"
    _inv="$(printf '%s\n' "$R" | sed -n 's/^INV|//p')"
    [ "${_inv:-0}" -eq 0 ] && ok "no invalid objects in $SCHEMA" || warn "$_inv invalid objects in $SCHEMA"
fi

# =============================================================================
# 3. Images – new copy per patch level, link switch (rollback = link back)
# =============================================================================
section "Images for Nginx"
if [ -f "$IMG_NEW/apex_version.txt" ]; then
    ok "already prepared: $IMG_NEW"
elif [ -d "$PATCH_HOME/$NR/images" ]; then
    _src="$WEB/APEX_${VER}"
    [ -d "$_src" ] || _src="$SW_BASE/APEX_${VER}/apex/images"
    mkdir -p "$IMG_NEW" && cp -r "$_src/." "$IMG_NEW/" && cp -rf "$PATCH_HOME/$NR/images/." "$IMG_NEW/" \
        && chmod -R u=rwX,go=rX "$IMG_NEW" \
        && ok "copied: $IMG_NEW (base $(basename "$_src") + patch images)" || fail "image copy failed"
fi
_old="$(readlink "$WEB/apex_${INST}" 2>/dev/null)"
if [ -d "$IMG_NEW" ] && [ "$_old" != "APEX_${VER}_p${NR}" ]; then
    ln -sfn "APEX_${VER}_p${NR}" "$WEB/apex_${INST}" \
        && ok "link $WEB/apex_${INST} -> APEX_${VER}_p${NR} (rollback: ln -sfn ${_old:-APEX_$VER} $WEB/apex_${INST})"
elif [ -d "$IMG_NEW" ]; then
    ok "link $WEB/apex_${INST} -> $_old"
fi

# =============================================================================
# 4. Start ORDS again
# =============================================================================
if $ORDS_ACTIVE && ! systemctl is-active --quiet "$UNIT" 2>/dev/null; then
    section "ORDS"
    ihw_run_root systemctl start "$UNIT" && ok "ORDS started ($UNIT)" || fail "Cannot start $UNIT"
fi

IHW_SYS_PWD=""
printLine
print_summary
exit "$EXIT_CODE"
