#!/bin/bash
# =============================================================================
# Script   : 99-oracle_deinstall_fmw.sh
# Purpose  : Remove the complete FMW installation (Forms/Reports + WebLogic,
#            ORACLE_HOME, DOMAIN_HOME, FMW client ADR, temp leftovers) so the
#            host can be rebuilt with 01-setup-interview.sh – while keeping a
#            repository database on the same host, its inventory entries, the
#            JDK, the patch storage, the RCU schemas and the encrypted
#            password files untouched.
# Call     : ./09-Install/99-oracle_deinstall_fmw.sh            (dry-run)
#            ./09-Install/99-oracle_deinstall_fmw.sh --apply    (IRREVERSIBLE)
# Options  : --apply   Execute (asks to type "DEINSTALL <hostname>" first)
#            --help    Show usage
# Runs as  : oracle
# Ref      : 09-Install/docs/99-oracle_deinstall_fmw.md
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_SH="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"

if [ ! -f "$LIB_SH" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB_SH" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB_SH"

check_env_conf "$ROOT_DIR/environment.conf" || exit 2
# shellcheck source=../environment.conf
source "$ROOT_DIR/environment.conf"

# =============================================================================
# Arguments
# =============================================================================

APPLY=false

for _arg in "$@"; do
    case "$_arg" in
        --apply)    APPLY=true ;;
        --help|-h)
            printf "Usage: %s [--apply]\n\n" "$(basename "$0")"
            printf "  %-10s %s\n" "(none)"  "Dry-run: preflight + show everything that would be removed/kept"
            printf "  %-10s %s\n" "--apply" "Deinstall FMW – IRREVERSIBLE, asks for typed confirmation"
            printf "  %-10s %s\n" "--help"  "Show this help"
            printf "\nKeeps: database homes/data/ADR, central inventory (only the FMW entry is\n"
            printf "removed), JDK_HOME, PATCH_STORAGE, RCU schemas, this repository incl. *.des3.\n"
            printf "Ref: 09-Install/docs/99-oracle_deinstall_fmw.md\n"
            exit 0 ;;
        *) warn "Unknown argument: $_arg" ;;
    esac
done
unset _arg

# =============================================================================
# Log setup
# =============================================================================

LOG_FILE="$ROOT_DIR/log/$(date +%Y%m%d)/deinstall_fmw_$(date +%H%M%S).log"
mkdir -p "$(dirname "$LOG_FILE")"
{
    printf "# 99-oracle_deinstall_fmw.sh log\n"
    printf "# Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# Host    : %s\n" "$(_get_hostname)"
    printf "# Apply   : %s\n" "$APPLY"
} > "$LOG_FILE"

_abort() {
    fail "$1"
    [ -n "${2:-}" ] && info "$2"
    print_summary
    exit 2
}

# =============================================================================
# Header
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – Deinstall FMW (database is kept)\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"      | tee -a "$LOG_FILE"
printf "  ORACLE_BASE : %s\n" "${ORACLE_BASE:-?}"     | tee -a "$LOG_FILE"
printf "  ORACLE_HOME : %s\n" "${ORACLE_HOME:-?}"     | tee -a "$LOG_FILE"
printf "  DOMAIN_HOME : %s\n" "${DOMAIN_HOME:-?}"     | tee -a "$LOG_FILE"
printf "  Apply       : %s\n" "$APPLY"                | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"             | tee -a "$LOG_FILE"
printLine

# =============================================================================
# 0. Preflight (read-only)
# =============================================================================

section "Preflight – Environment"

for _var in ORACLE_BASE ORACLE_HOME DOMAIN_HOME; do
    [ -n "${!_var:-}" ] || _abort "$_var is not set in environment.conf"
    ok "$(printf "  %-12s = %s" "$_var" "${!_var}")"
done
unset _var

if [ "$(id -un)" != "${ORACLE_OS_USER:-oracle}" ]; then
    _abort "Must run as ${ORACLE_OS_USER:-oracle}, not $(id -un)"
fi

# --- Password gate -----------------------------------------------------------
section "Preflight – Password Files (must still decrypt)"

if ( load_weblogic_password >/dev/null 2>&1 && [ -n "${INTERNAL_WL_PWD:-}" ] ); then
    ok "weblogic_sec.conf.des3 decrypts (WebLogic admin password present)"
else
    _abort "weblogic_sec.conf.des3 cannot be decrypted or is empty" \
           "Fix first: 00-Setup/weblogic_sec.sh --apply – do not deinstall without it"
fi

if ( load_secrets_file "$ROOT_DIR/db_sys_sec.conf.des3" >/dev/null 2>&1 \
     && [ -n "${DB_SYS_PWD:-}" ] && [ -n "${DB_SCHEMA_PWD:-}" ] ); then
    ok "db_sys_sec.conf.des3 decrypts (DB_SYS_PWD + DB_SCHEMA_PWD present)"
else
    _abort "db_sys_sec.conf.des3 cannot be decrypted or DB_SYS_PWD/DB_SCHEMA_PWD empty" \
           "Fix first: 09-Install/01-setup-interview.sh (DB passwords) – needed for the RCU rebuild"
fi

if ( load_secrets_file "$ROOT_DIR/mos_sec.conf.des3" >/dev/null 2>&1 && [ -n "${MOS_PWD:-}" ] ); then
    ok "mos_sec.conf.des3 decrypts (MOS_PWD present)"
else
    _abort "mos_sec.conf.des3 cannot be decrypted or MOS_PWD empty" \
           "Fix first: 00-Setup/mos_sec.sh --apply"
fi
info "Password files stay in $ROOT_DIR (outside every delete target)"

# --- Central inventory -------------------------------------------------------
section "Preflight – Central Inventory"

[ -f /etc/oraInst.loc ] || _abort "/etc/oraInst.loc not found – cannot locate the central inventory"
INV_LOC="$(sed -n 's/^inventory_loc=//p' /etc/oraInst.loc | head -1)"
INV_XML="$INV_LOC/ContentsXML/inventory.xml"
[ -f "$INV_XML" ] || _abort "inventory.xml not found: $INV_XML"
ok "Central inventory: $INV_LOC  (from /etc/oraInst.loc)"
if [ -n "${ORACLE_INVENTORY:-}" ] && [ "$ORACLE_INVENTORY" != "$INV_LOC" ]; then
    warn "environment.conf ORACLE_INVENTORY=$ORACLE_INVENTORY differs – /etc/oraInst.loc wins"
fi

# _inv_homes – print "NAME|LOC|REMOVED" per registered home
_inv_homes() {
    grep -o '<HOME [^>]*>' "$INV_XML" | while IFS= read -r _h; do
        printf "%s|%s|%s\n" \
            "$(printf '%s' "$_h" | sed -n 's/.* NAME="\([^"]*\)".*/\1/p')" \
            "$(printf '%s' "$_h" | sed -n 's/.* LOC="\([^"]*\)".*/\1/p')" \
            "$(printf '%s' "$_h" | sed -n 's/.* REMOVED="\([^"]*\)".*/\1/p')"
    done
}

FMW_REGISTERED=false
OTHER_HOMES=()
while IFS='|' read -r _name _loc _removed; do
    [ -z "$_loc" ] && continue
    if [ "$_loc" = "$ORACLE_HOME" ]; then
        if [ "$_removed" = "T" ]; then
            info "$(printf "  %-22s %s  (FMW, already marked removed)" "$_name" "$_loc")"
        else
            FMW_REGISTERED=true
            ok "$(printf "  %-22s %s  ← FMW home, will be deinstalled" "$_name" "$_loc")"
        fi
    else
        OTHER_HOMES+=("$_loc")
        info "$(printf "  %-22s %s  ← kept" "$_name" "$_loc")"
    fi
done < <(_inv_homes)
unset _name _loc _removed
$FMW_REGISTERED || warn "ORACLE_HOME is not registered in the inventory – only leftover files will be removed"

# --- FMW distributions (read before the home is gone) ------------------------
DISTRIBUTIONS=()
if $FMW_REGISTERED && [ -f "$ORACLE_HOME/inventory/registry.xml" ]; then
    _first=() _last=()
    while IFS= read -r _d; do
        case "$_d" in
            *WebLogic*|*Infrastructure*) _last+=("$_d") ;;
            *)                           _first+=("$_d") ;;
        esac
    done < <(grep -o '<distribution status="installed" name="[^"]*"' "$ORACLE_HOME/inventory/registry.xml" \
             | sed 's/.*name="\([^"]*\)"/\1/')
    DISTRIBUTIONS=("${_first[@]}" "${_last[@]}")
    unset _first _last _d
    for _d in "${DISTRIBUTIONS[@]}"; do ok "  Distribution to deinstall: $_d"; done
    unset _d
    [ -x "$ORACLE_HOME/oui/bin/deinstall.sh" ] || _abort "Deinstaller not found: $ORACLE_HOME/oui/bin/deinstall.sh"
fi

# --- Database status (information only) --------------------------------------
section "Preflight – Database on this host (kept)"

DB_PMON_BEFORE="$(pgrep -fa 'ora_pmon_' 2>/dev/null | grep -v pgrep | awk '{print $2}' | tr '\n' ' ')"
if [ -n "$DB_PMON_BEFORE" ]; then
    ok "Database instance(s) running: $DB_PMON_BEFORE– will NOT be stopped"
else
    info "No database instance running on this host"
fi
pgrep -x tnslsnr >/dev/null 2>&1 && ok "Listener running – will NOT be stopped"

# =============================================================================
# Delete guard
# =============================================================================

# Protected trees: never delete them, anything inside them, or any parent.
DOMAIN_NAME="${DOMAIN_NAME:-$(basename "$DOMAIN_HOME")}"
AUTOSTART_DIR="$ORACLE_BASE/admin/$DOMAIN_NAME"          # 30-configure_autostart.sh
AUTOSTART_UNIT="/etc/systemd/system/fmw-${DOMAIN_NAME}.service"

PROTECT_TREE=("$ROOT_DIR" "$INV_LOC" "${OTHER_HOMES[@]}"
              "$ORACLE_BASE/product" "$ORACLE_BASE/oradata" "$ORACLE_BASE/diag"
              "$ORACLE_BASE/audit" "$ORACLE_BASE/flash_recovery_area"
              "$ORACLE_BASE/autoupgrade" "$ORACLE_BASE/cfgtoollogs")
# $ORACLE_BASE/admin: every subdirectory except the domain's autostart dir is
# protected (database admin dirs such as admin/<DB_NAME>)
for _a in "$ORACLE_BASE"/admin/*/; do
    [ -d "$_a" ] || continue
    [ "${_a%/}" = "$AUTOSTART_DIR" ] || PROTECT_TREE+=("${_a%/}")
done
unset _a
[ -n "${JDK_HOME:-}" ]      && PROTECT_TREE+=("$JDK_HOME")
[ -n "${PATCH_STORAGE:-}" ] && PROTECT_TREE+=("$PATCH_STORAGE")
# Protected nodes: never delete them or any parent (children are fine).
PROTECT_NODE=("/" "$ORACLE_BASE" "$ORACLE_BASE/admin" "$HOME" "/tmp" "$(dirname "$ORACLE_BASE")")

# Explicit whitelist – nothing outside this list is ever deleted.
DELETE_TARGETS=("$ORACLE_HOME" "$DOMAIN_HOME" "$HOME/oradiag_oracle")
[ -n "$DOMAIN_NAME" ] && DELETE_TARGETS+=("$AUTOSTART_DIR")
case "${REPORTS_TMP:-}" in /tmp/?*) DELETE_TARGETS+=("$REPORTS_TMP") ;; esac
for _t in /tmp/ihw_*; do [ -e "$_t" ] && DELETE_TARGETS+=("$_t"); done
unset _t

# _safe_rm_target  path  – 0 = allowed to delete, 1 = refused (reason on stdout)
_safe_rm_target() {
    local t p w listed=false
    [ -z "${1:-}" ] && { printf "empty path"; return 1; }
    t="$(realpath -m -- "$1")"
    [ "$(printf '%s' "$t" | tr -cd '/' | wc -c)" -lt 2 ] && { printf "path too shallow: %s" "$t"; return 1; }
    for w in "${DELETE_TARGETS[@]}"; do
        [ "$t" = "$(realpath -m -- "$w")" ] && listed=true
    done
    $listed || { printf "not on the delete whitelist: %s" "$t"; return 1; }
    for p in "${PROTECT_TREE[@]}"; do
        [ -z "$p" ] && continue
        p="$(realpath -m -- "$p")"
        case "$t/" in "$p/"*) printf "inside protected tree %s" "$p"; return 1 ;; esac
        case "$p/" in "$t/"*) printf "would delete protected tree %s" "$p"; return 1 ;; esac
    done
    for p in "${PROTECT_NODE[@]}"; do
        [ -z "$p" ] && continue
        p="$(realpath -m -- "$p")"
        case "$p/" in "$t/"*) printf "would delete protected directory %s" "$p"; return 1 ;; esac
    done
    return 0
}

section "Preflight – Targets"

for _t in "${DELETE_TARGETS[@]}"; do
    if [ ! -e "$_t" ]; then
        info "$(printf "  %-50s %s" "$_t" "(not present)")"
    elif _reason="$(_safe_rm_target "$_t")"; then
        ok "$(printf "  DELETE %-44s %s" "$_t" "$(du -sh "$_t" 2>/dev/null | cut -f1)")"
    else
        _abort "Delete target refused by guard: $_t – $_reason"
    fi
done
unset _t _reason
for _k in "$INV_LOC" "${OTHER_HOMES[@]}" "$ORACLE_BASE/diag" "${JDK_HOME:-}" "${PATCH_STORAGE:-}" \
          "${FORMS_CUSTOMER_DIR:-}" "${REPORTS_CUSTOMER_DIR:-}" "$ROOT_DIR"; do
    [ -n "$_k" ] && [ -e "$_k" ] && info "$(printf "  KEEP   %s" "$_k")"
done
unset _k

[ -f "$AUTOSTART_UNIT" ] && info "$(printf "  REMOVE %s  (autostart unit, disabled first)" "$AUTOSTART_UNIT")"

ENV_TARGET="$(readlink -f "$ROOT_DIR/environment.conf")"
info "  ASIDE  $ENV_TARGET  → .pre_deinstall_<timestamp>"

# =============================================================================
# Dry-run exit / confirmation
# =============================================================================

if ! $APPLY; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "Dry-run – nothing changed. Re-run with --apply to deinstall (irreversible)."
    print_summary
    exit "$EXIT_CODE"
fi

_CONFIRM_TEXT="DEINSTALL $(_get_hostname)"
printf "\n  \033[31mThis removes the FMW installation irreversibly.\033[0m\n"
printf "  Type exactly '%s' to continue: " "$_CONFIRM_TEXT"
read -r _answer
[ "$_answer" = "$_CONFIRM_TEXT" ] || _abort "Confirmation not given – nothing changed"
ok "Confirmed by user"
unset _answer _CONFIRM_TEXT

# =============================================================================
# 1. Backup
# =============================================================================

section "1. Backup"

"$ROOT_DIR/07-Maintenance/backup_config.sh" --apply >> "$LOG_FILE" 2>&1
_rc=$?
# Project convention: 0=OK, 1=WARN (e.g. optional files not present), 2=FAIL
case "$_rc" in
    0) ok   "backup_config.sh completed" ;;
    1) warn "backup_config.sh completed with warnings (missing optional files) – see $LOG_FILE" ;;
    *) _abort "backup_config.sh failed (rc=$_rc) – see $LOG_FILE" ;;
esac
unset _rc
BACKUP_DIR="$(ls -1dt "$ROOT_DIR"/07-Maintenance/ConfigBackup/*/ 2>/dev/null | head -1)"
BACKUP_DIR="${BACKUP_DIR%/}"
[ -d "$BACKUP_DIR" ] || _abort "Backup directory not found after backup_config.sh"
[ -f "$DOMAIN_HOME/config/config.xml" ] && cp -p "$DOMAIN_HOME/config/config.xml" "$BACKUP_DIR/"
[ -f "$ENV_TARGET" ] && cp -p "$ENV_TARGET" "$BACKUP_DIR/environment.conf.pre_deinstall"
ok "Backup: $BACKUP_DIR (incl. config.xml + environment.conf)"

# =============================================================================
# 2. Stop all FMW processes (database keeps running)
# =============================================================================

section "2. Stop FMW Processes"

# Autostart (30-configure_autostart.sh): disable + remove the unit first, so
# systemd does not restart anything; the servers are stopped below as usual.
if [ -f "$AUTOSTART_UNIT" ]; then
    _unit="$(basename "$AUTOSTART_UNIT")"
    if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
        _sudo=""; [ "$(id -u)" -eq 0 ] || _sudo="sudo"
        $_sudo systemctl disable "$_unit" >/dev/null 2>&1
        $_sudo rm -f "$AUTOSTART_UNIT" && ok "Autostart unit removed: $AUTOSTART_UNIT"
        $_sudo systemctl daemon-reload
        unset _sudo
    else
        warn "No sudo – remove the autostart unit as root afterwards:"
        info "  systemctl disable $_unit && rm -f $AUTOSTART_UNIT && systemctl daemon-reload"
    fi
    unset _unit
fi

"$ROOT_DIR/01-Run/startStop.sh" stop-all --apply 2>&1 | tee -a "$LOG_FILE"
info "startStop.sh stop-all finished (rc=${PIPESTATUS[0]})"

# _fmw_pids – PIDs of remaining FMW processes, by exact pattern only
_fmw_pids() {
    {
        pgrep -f 'Dweblogic.Name='
        pgrep -f 'weblogic.nodemanager'
        pgrep -x rwrun; pgrep -x rwserver; pgrep -x rwengine; pgrep -x frmweb
        [ -n "${DISPLAY_VAR:-}" ] && pgrep -f "^Xvfb ${DISPLAY_VAR}( |$)"
    } 2>/dev/null | grep -v -x -e "$$" -e "$PPID" | sort -u
}

_left="$(_fmw_pids | tr '\n' ' ')"
if [ -n "$_left" ]; then
    warn "Remaining FMW processes: $_left– sending TERM"
    # shellcheck disable=SC2086
    kill $_left 2>/dev/null
    for _i in $(seq 1 15); do [ -z "$(_fmw_pids)" ] && break; sleep 1; done
    _left="$(_fmw_pids | tr '\n' ' ')"
    if [ -n "$_left" ]; then
        warn "Still running after 15s: $_left– sending KILL"
        # shellcheck disable=SC2086
        kill -9 $_left 2>/dev/null
        sleep 2
    fi
fi
unset _left _i

require_wls_stopped || _abort "WebLogic still running – deinstall stopped before any change"

if [ -n "$DB_PMON_BEFORE" ]; then
    _pmon_now="$(pgrep -fa 'ora_pmon_' 2>/dev/null | grep -v pgrep | awk '{print $2}' | tr '\n' ' ')"
    [ "$_pmon_now" = "$DB_PMON_BEFORE" ] \
        || _abort "Database instances changed ($DB_PMON_BEFORE→ $_pmon_now) – stopping, check the DB!"
    ok "Database still running: $_pmon_now"
    unset _pmon_now
fi

# =============================================================================
# 3. Deinstall via OUI
# =============================================================================

section "3. Deinstall (Oracle Universal Installer)"

if $FMW_REGISTERED; then
    for _d in "${DISTRIBUTIONS[@]}"; do
        info "Running: deinstall.sh -silent -distributionName \"$_d\""
        "$ORACLE_HOME/oui/bin/deinstall.sh" -silent -distributionName "$_d" 2>&1 | tee -a "$LOG_FILE"
        _rc=${PIPESTATUS[0]}
        [ "$_rc" -eq 0 ] || _abort "Deinstall of \"$_d\" failed (rc=$_rc) – nothing deleted" \
                                   "OUI logs: $INV_LOC/logs/"
        ok "Deinstalled: $_d"
    done
    unset _d _rc

    if _inv_homes | grep -q "|${ORACLE_HOME}|$"; then
        _abort "FMW home is still registered in $INV_XML after deinstall" "OUI logs: $INV_LOC/logs/"
    fi
    ok "FMW home no longer registered in the central inventory"
    for _h in "${OTHER_HOMES[@]}"; do
        _inv_homes | grep -q "|${_h}|" && ok "  still registered: $_h" \
                                       || fail "  home disappeared from inventory: $_h"
    done
    unset _h
else
    info "Skipped – FMW home was not registered"
fi

# =============================================================================
# 4. Remove leftovers
# =============================================================================

section "4. Remove Leftovers"

for _t in "${DELETE_TARGETS[@]}"; do
    [ -e "$_t" ] || { info "  already gone: $_t"; continue; }
    if ! _reason="$(_safe_rm_target "$_t")"; then
        fail "  refused by guard: $_t – $_reason"
        continue
    fi
    rm -rf -- "$_t"
    [ -e "$_t" ] && fail "  could not remove: $_t" || ok "  removed: $_t"
done
unset _t _reason

_domains_parent="$(dirname "$DOMAIN_HOME")"
if [ "$(basename "$_domains_parent")" = "domains" ] && [ -d "$_domains_parent" ] \
   && [ -z "$(ls -A "$_domains_parent")" ]; then
    rmdir "$_domains_parent" && ok "  removed empty: $_domains_parent"
fi
unset _domains_parent

# =============================================================================
# 5. environment.conf aside
# =============================================================================

section "5. environment.conf aside"

_ts="$(date +%Y%m%d_%H%M%S)"
if [ -L "$ROOT_DIR/environment.conf" ]; then
    mv "$ENV_TARGET" "${ENV_TARGET}.pre_deinstall_${_ts}" && rm -f "$ROOT_DIR/environment.conf" \
        && ok "Moved ${ENV_TARGET} → .pre_deinstall_${_ts}, symlink removed"
elif [ -f "$ROOT_DIR/environment.conf" ]; then
    mv "$ROOT_DIR/environment.conf" "$ROOT_DIR/environment.conf.pre_deinstall_${_ts}" \
        && ok "Moved environment.conf → environment.conf.pre_deinstall_${_ts}"
fi
unset _ts
ok "Password files kept: $(ls "$ROOT_DIR"/*.des3 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"

# =============================================================================
# 6. Next steps
# =============================================================================

printLine
info "Next steps (reinstall):"
info "  1. ./09-Install/01-setup-interview.sh --apply"
info "     ORACLE_INVENTORY = $INV_LOC   (NOT the suggested default – shared with the DB homes!)"
info "  2. Phase 0–3 as in 09-Install/README.md"
info "  3. RCU rebuild (old OPSS store is bound to the old domain):"
info "       ./09-Install/07-oracle_setup_repository.sh --drop"
info "       ./09-Install/07-oracle_setup_repository.sh --apply"
info "  4. ./09-Install/08-oracle_setup_domain.sh and the remaining phases"
printLine

print_summary
exit "$EXIT_CODE"
