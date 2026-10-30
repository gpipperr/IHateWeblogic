#!/bin/bash
# =============================================================================
# Script   : 00b-db_cvu_check.sh
# Purpose  : Validate the host BEFORE the 19c installation with Oracle's
#            standalone Cluster Verification Utility (CVU, MOS patch 30839369
#            "Standalone CVU Platform-specific package supports 21c and 19c").
#            Built for clusters, but the component checks also work for a
#            single instance without Clusterware:
#              cluvfy comp sys -p database -r 19   OS packages, kernel parameters,
#                                                  limits, memory / swap,
#                                                  users / groups for a DB home
#            plus own disk checks (DB home 8 GB, data files 4 GB, CV home).
#            No post-install check: cluvfy comp software (files of an installed
#            home) needs Clusterware – PRVG-11902 on a single instance (live
#            2026-10-27).
#            Fixups: CVU writes a root fixup script (-fixup); this script only
#            prints its path – review it, run it as root yourself.
# Call     : ./60-RCU-DB-19c/00b-db_cvu_check.sh            (dry-run)
#            ./60-RCU-DB-19c/00b-db_cvu_check.sh --apply    (unpack CVU, run checks)
# Runs as  : oracle (after 00-root_db_os_baseline.sh, before 01-)
# Requires : environment.conf, environment_db.conf (DB_CVU_DIR, DB_CVU_HOME,
#            DB_ORACLE_HOME), CVU ZIP in DB_CVU_DIR – downloaded by
#            09-Install/04-oracle_pre_download.sh --apply --mos (LOCAL_REP_DB=true)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 60-RCU-DB-19c/docs/00b-db_cvu_check.md
#            https://www.oracle.com/database/technologies/cvu-downloads.html
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"
ENV_DB_CONF="$SCRIPT_DIR/environment_db.conf"
VERSION_CONF="$ROOT_DIR/09-Install/oracle_software_version.conf"

source "$LIB" 2>/dev/null || { printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB" >&2; exit 2; }
for _f in "$ENV_CONF" "$ENV_DB_CONF"; do
    [ ! -f "$_f" ] && { printf "\033[31mFATAL\033[0m: Config not found: %s\n" "$_f" >&2
        [ "$_f" = "$ENV_DB_CONF" ] && printf "  Create it from the template, then edit it (60-RCU-DB-19c/README.md, Configuration):\n    cp %s.example %s && chmod 600 %s\n" "$_f" "$_f" "$_f" >&2
        exit 2; }
    source "$_f"
done
unset _f
# shellcheck source=../09-Install/oracle_software_version.conf
[ -f "$VERSION_CONF" ] && source "$VERSION_CONF"

DIAG_LOG_DIR="${DIAG_LOG_DIR:-$ROOT_DIR/log/$(date +%Y%m%d)}"
init_log "$DIAG_LOG_DIR"

DB_CVU_PATCH_NR="${DB_CVU_PATCH_NR:-30839369}"
DB_CVU_DIR="${DB_CVU_DIR:-${PATCH_STORAGE}/database/cvu}"
DB_CVU_HOME="${DB_CVU_HOME:-${ORACLE_BASE}/cvu}"
CLUVFY="$DB_CVU_HOME/bin/cluvfy"
NODE="$(hostname -s)"

# =============================================================================
# Arguments
# =============================================================================

APPLY=false

_usage() {
    printf "Usage: %s [--apply] [--help]\n\n" "$(basename "$0")"
    printf "  %-10s %s\n" "(none)"  "Dry-run: show CVU archive, CV home and the commands"
    printf "  %-10s %s\n" "--apply" "Unpack the CVU (once) and run the pre-install checks"
    printf "  %-10s %s\n" "--help"  "Show this help"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)   APPLY=true ;;
        --help|-h) _usage ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
    shift
done

printLine
section "CVU check – $(date '+%Y-%m-%d %H:%M:%S')"
printList "Mode"        20 "pre-install (OS)$($APPLY || printf ' – dry-run')"
printList "CVU patch"   20 "$DB_CVU_PATCH_NR"
printList "CVU archive" 20 "$DB_CVU_DIR"
printList "CV home"     20 "$DB_CVU_HOME"
printList "Node"        20 "$NODE"
printLine

# =============================================================================
# Pre-checks
# =============================================================================

section "Pre-checks"

[ "$(id -un)" = "${ORACLE_OS_USER:-oracle}" ] \
    && ok "Running as $(id -un)" \
    || { fail "Run as ${ORACLE_OS_USER:-oracle}, not $(id -un)"; print_summary; exit 2; }

_zip=""
if [ -x "$CLUVFY" ]; then
    ok "CVU already unpacked: $CLUVFY"
else
    # the patch has several kits (26ai = 23.26, OCW RU, 21c / 18c cvupack) – take the
    # current standalone kit p<nr>_<ver>_Linux-x86-64.zip, cvupack only as fallback
    _zip="$(ls -1 "$DB_CVU_DIR"/p"${DB_CVU_PATCH_NR}"_*_Linux-x86-64.zip 2>/dev/null \
            | grep -E "/p${DB_CVU_PATCH_NR}_[0-9]+_Linux-x86-64\.zip$" | sort -V | tail -1)"
    [ -z "$_zip" ] && _zip="$(ls -1 "$DB_CVU_DIR"/cvupack_linux_ol7*.zip 2>/dev/null | head -1)"
    if [ -n "$_zip" ]; then
        ok "CVU archive: $_zip  ($(du -sh "$_zip" 2>/dev/null | cut -f1))"
    else
        fail "No CVU archive in $DB_CVU_DIR (p${DB_CVU_PATCH_NR}_*.zip or cvupack*.zip)"
        info "  Download: 09-Install/04-oracle_pre_download.sh --apply --mos (LOCAL_REP_DB=true)"
        info "  or by hand: MOS patch $DB_CVU_PATCH_NR, platform Linux x86-64 -> $DB_CVU_DIR"
        print_summary; exit 2
    fi
    _parent="$(dirname "$DB_CVU_HOME")"
    _free_mb="$(df -Pm "$_parent" 2>/dev/null | awk 'NR==2{print $4}')"
    if [ "${_free_mb:-0}" -ge 500 ]; then
        ok "$(printf "Free space for the CV home: %s MB in %s (>= 500 MB)" "$_free_mb" "$_parent")"
    else
        fail "$(printf "Free space for the CV home: %s MB in %s (< 500 MB)" "${_free_mb:-?}" "$_parent")"
    fi
fi

# Disk for the DB itself (README sizing: software 8 GB, data files 4 GB)
for _spec in "DB_ORACLE_HOME:${DB_ORACLE_HOME}:8192" "DB_DATA_DIR:${DB_DATA_DIR:-$ORACLE_BASE/oradata}:4096"; do
    IFS=: read -r _lbl _dir _need <<< "$_spec"
    _probe="$_dir"; while [ ! -d "$_probe" ] && [ "$_probe" != "/" ]; do _probe="$(dirname "$_probe")"; done
    _free_mb="$(df -Pm "$_probe" 2>/dev/null | awk 'NR==2{print $4}')"
    _msg="$(printf "%-15s %6s MB free in %s (need %s MB)" "$_lbl" "${_free_mb:-?}" "$_probe" "$_need")"
    [ "${_free_mb:-0}" -ge "$_need" ] && ok "$_msg" || fail "$_msg"
done
unset _spec _lbl _dir _need _probe

CVU_CMD=("$CLUVFY" comp sys -n "$NODE" -p database -r 19 -fixup -verbose)

if ! $APPLY; then
    section "Dry-run"
    [ -n "$_zip" ] && info "  unzip $(basename "$_zip") -> $DB_CVU_HOME, CV_ORACLE_RELEASE=19 in cv/admin/cvu_config"
    info "  ${CVU_CMD[*]}"
    info "  Run with --apply to execute"
    print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# Unpack (once)
# =============================================================================

if [ -n "$_zip" ]; then
    section "Unpack CVU"
    mkdir -p "$DB_CVU_HOME"
    unzip -q -o "$_zip" -d "$DB_CVU_HOME" 2>&1 | tee -a "$LOG_FILE"
    # the MOS patch ZIP can wrap the cvupack ZIP of the README
    _inner="$(ls -1 "$DB_CVU_HOME"/cvupack*.zip 2>/dev/null | head -1)"
    if [ ! -x "$CLUVFY" ] && [ -n "$_inner" ]; then
        unzip -q -o "$_inner" -d "$DB_CVU_HOME" 2>&1 | tee -a "$LOG_FILE" && rm -f "$_inner"
    fi
    if [ -x "$CLUVFY" ]; then
        ok "Unpacked: $CLUVFY"
    else
        fail "bin/cluvfy not found after unzip – check the content of $_zip"
        print_summary; exit 2
    fi
fi

# Default release of the 21c CVU is 21 – the README's alternative to "-r 19"
_cfg="$DB_CVU_HOME/cv/admin/cvu_config"
if [ -f "$_cfg" ]; then
    if grep -q '^CV_ORACLE_RELEASE=19' "$_cfg"; then
        ok "cvu_config: CV_ORACLE_RELEASE=19"
    else
        backup_file "$_cfg" "$DB_CVU_HOME/cv/admin" >/dev/null 2>&1
        sed -i '/^#\{0,1\}[[:space:]]*CV_ORACLE_RELEASE=/d' "$_cfg"
        printf 'CV_ORACLE_RELEASE=19\n' >> "$_cfg"
        ok "cvu_config: CV_ORACLE_RELEASE=19 set"
    fi
fi

# =============================================================================
# Run CVU
# =============================================================================

section "cluvfy comp sys -p database (OS)"
CVU_OUT="$DIAG_LOG_DIR/cvu_pre_$(date +%H%M%S).txt"
info "  ${CVU_CMD[*]}"
info "  Full output: $CVU_OUT"
"${CVU_CMD[@]}" > "$CVU_OUT" 2>&1
_rc=$?

_cvuver="$(sed -n 's/^CVU version:[[:space:]]*//p' "$CVU_OUT" | head -1)"
[ -n "$_cvuver" ] && info "  CVU version: $_cvuver"
# OL9: no 19c reference data yet -> CVU compares with the OL7 data (expected)
_ref="$(grep -m1 -i 'Reference data is not available' "$CVU_OUT")"
[ -n "$_ref" ] && printf '%s\n' "$_ref" | fold -s -w 100 | while IFS= read -r _l; do info "  $_l"; done

# one line per verified item, indented ("  <item> ...PASSED|FAILED|WARNING",
# 21c: "Verifying <item> ..."); the unindented repeats in the summary block
# at the end are skipped
_unexpected=0
while IFS= read -r _line; do
    _item="$(printf '%s' "$_line" | sed -E 's/^[[:space:]]*(Verifying[[:space:]]+)?//; s/[[:space:]]*\.\.\..*$//')"
    _res="$(printf '%s' "$_line" | grep -oE '\.\.\.(PASSED|FAILED|WARNING|IGNORED)' | tr -d '.')"
    _code="$(printf '%s' "$_line" | grep -oE '\((PR[A-Z]+-[0-9]+[^)]*)\)' | head -1)"
    _msg="$(printf "  %-50s %s %s" "${_item:0:50}" "$_res" "$_code")"
    # known findings of this setup (live 2026-10-27, OL9, CVU 23.26 with -r 19):
    # FAIL -> WARN with the reason (docs/00b-db_cvu_check.md)
    if [ "$_res" = "FAILED" ]; then
        case "$_item" in
            *compat-libcap1*)
                grep -q 'el9' /proc/version 2>/dev/null && { warn "$_msg"
                    info "    expected on OL9: package does not exist on OL9, CVU uses the OL7 reference data"
                    continue; } ;;
            "Swap Size")
                warn "$_msg"
                info "    CVU rule: RAM > 16 GB needs 16 GB swap – the RCU DB uses SGA ${DB_SGA_MB:-?} MB;"
                info "    add swap for production, acceptable on a test host"
                continue ;;
        esac
    fi
    case "$_res" in
        PASSED)  ok "$_msg" ;;
        WARNING) warn "$_msg" ;;
        FAILED)  fail "$_msg"; _unexpected=$((_unexpected + 1)) ;;
        *)       info "$_msg" ;;
    esac
done < <(grep -E '^([[:space:]]+|Verifying ).*\.\.\.(PASSED|FAILED|WARNING|IGNORED)' "$CVU_OUT")

if head -3 "$CVU_OUT" | grep -q '^ERROR:'; then
    fail "CVU rejected the call: $(sed -n '2p' "$CVU_OUT")"
elif grep -qiE 'verification of .* was unsuccessful|failures were encountered' "$CVU_OUT" \
   && [ "$_unexpected" -eq 0 ] && grep -qE '\.\.\.FAILED' "$CVU_OUT"; then
    ok "CVU: only the expected findings failed (rc=$_rc) – host ready for 01-db_install_software.sh"
elif grep -qiE 'verification of .* was unsuccessful|failures were encountered' "$CVU_OUT"; then
    warn "CVU: verification unsuccessful (rc=$_rc) – $_unexpected unexpected FAILED item(s), see $CVU_OUT"
    info "  Expected findings on OL9 / for this single-instance setup: docs/00b-db_cvu_check.md"
elif grep -qiE 'verification of .* was successful' "$CVU_OUT"; then
    ok "CVU: verification successful (rc=$_rc)"
else
    warn "CVU: no verification result found (rc=$_rc) – see $CVU_OUT"
    tail -15 "$CVU_OUT" | while IFS= read -r _l; do info "  $_l"; done
fi

_fix="$(grep -oE '/[^[:space:]]*runfixup\.sh' "$CVU_OUT" | head -1)"
if [ -n "$_fix" ]; then
    warn "Fixup script generated: $_fix"
    info "  Review it, then run as root: $_fix"
    info "  (00-root_db_os_baseline.sh --apply is the preferred place for OS settings)"
fi

print_summary
exit "$EXIT_CODE"
