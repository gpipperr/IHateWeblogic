#!/bin/bash
# =============================================================================
# Script   : 14b-oracle_reports_fonts.sh
# Purpose  : Reports font + cgicmd.dat configuration AFTER the Reports
#            components exist. Split off 09-oracle_configure.sh (2026-10-15):
#            uifont.ali lives in the ReportsToolsComponent created by
#            13-oracle_setup_reports.sh, cgicmd.dat in the WLS_REPORTS
#            application directory that only exists after the first start of
#            the Reports managed server – neither exists right after 08-.
#            Calls existing scripts; does not implement new functionality.
# Call     : ./09-Install/14b-oracle_reports_fonts.sh
#            ./09-Install/14b-oracle_reports_fonts.sh --apply
#            ./09-Install/14b-oracle_reports_fonts.sh --apply --skip-fonts
#            ./09-Install/14b-oracle_reports_fonts.sh --help
# Options  : (none)        Dry-run: show planned steps and prerequisites
#            --apply       Execute all steps
#            --skip-fonts  Only cgicmd.dat + backup (skip font steps 1-4)
#            --help        Show usage
# Runs as  : oracle
# Requires : 13-oracle_setup_reports.sh done (ReportsToolsComponent exists)
#            WLS_REPORTS started once (for cgicmd.dat)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/docs/14b-oracle_reports_fonts.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"
CGICMD_TEMPLATE="$SCRIPT_DIR/response_files/cgicmd.dat.template"

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

DIAG_LOG_DIR="${DIAG_LOG_DIR:-$ROOT_DIR/log/$(date +%Y%m%d)}"
init_log "$DIAG_LOG_DIR"

# =============================================================================
# Argument parsing
# =============================================================================

APPLY=false
SKIP_FONTS=false

for _arg in "$@"; do
    case "$_arg" in
        --apply)       APPLY=true ;;
        --skip-fonts)  SKIP_FONTS=true ;;
        --help)
            printf "Usage: %s [--apply] [--skip-fonts] [--help]\n\n" "$0"
            printf "  (none)        Dry-run: show planned steps and prerequisites\n"
            printf "  --apply       Execute all steps\n"
            printf "  --skip-fonts  Only cgicmd.dat + backup (skip font steps 1-4)\n"
            printf "  --help        Show this help\n\n"
            printf "Prerequisites: 13-oracle_setup_reports.sh done, WLS_REPORTS started once.\n"
            exit 0
            ;;
        *) warn "Unknown argument: $_arg (ignored)" ;;
    esac
done
unset _arg

# =============================================================================
# Helper: run a subscript, track exit code
# =============================================================================

STEP_FAILS=0

_run_step() {
    local label="$1"; shift
    local script="$1"; shift

    section "Step: $label"

    if [ ! -f "$script" ]; then
        fail "Script not found: $script"
        STEP_FAILS=$(( STEP_FAILS + 1 ))
        return 1
    fi

    printf "  Calling: %s %s\n\n" "$script" "$*" | tee -a "$LOG_FILE"
    bash "$script" "$@" 2>&1 | tee -a "$LOG_FILE"
    local rc=${PIPESTATUS[0]}

    printf "\n" | tee -a "$LOG_FILE"
    if [ "$rc" -ne 0 ]; then
        warn "Step '$label' finished with rc=$rc"
        STEP_FAILS=$(( STEP_FAILS + 1 ))
    else
        ok "Step '$label' finished successfully"
    fi
    return "$rc"
}

# =============================================================================
# Header
# =============================================================================

printLine
printf "\n"
printf "\033[1m  IHateWeblogic – Reports Fonts + cgicmd.dat\033[0m\n"
printf "  Host        : %s\n" "$(_get_hostname)"
printf "  Date        : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "  Apply       : %s\n" "$APPLY"
printf "  Skip fonts  : %s\n" "$SKIP_FONTS"
printf "  Log         : %s\n" "$LOG_FILE"
printLine

# =============================================================================
# Pre-checks
# =============================================================================

section "Pre-checks"

[ -f "$DOMAIN_HOME/config/config.xml" ] \
    && ok "Domain found: $DOMAIN_HOME" \
    || { fail "Domain not found: $DOMAIN_HOME/config/config.xml"; EXIT_CODE=2; }

if [ ! -d "$ORACLE_HOME/reports" ]; then
    info "Reports not installed in ORACLE_HOME – nothing to do"
    print_summary; exit "$EXIT_CODE"
fi

for _s in \
    "$ROOT_DIR/04-ReportsFonts/deploy_fonts.sh" \
    "$ROOT_DIR/04-ReportsFonts/font_cache_reset.sh" \
    "$ROOT_DIR/04-ReportsFonts/uifont_ali_update.sh" \
    "$ROOT_DIR/04-ReportsFonts/fontpath_config.sh" \
    "$ROOT_DIR/07-Maintenance/backup_config.sh"
do
    [ -f "$_s" ] \
        && ok "$(printf "Script found   : %s" "$(basename "$_s")")" \
        || { fail "$(printf "Script missing : %s" "$_s")"; EXIT_CODE=2; }
done
unset _s

[ -f "$CGICMD_TEMPLATE" ] \
    && ok "$(printf "Template found : %s" "$(basename "$CGICMD_TEMPLATE")")" \
    || { fail "cgicmd.dat template missing: $CGICMD_TEMPLATE"; EXIT_CODE=2; }

# ReportsToolsComponent (uifont.ali lives in it) – created by 13-
_tools_base="$DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent"
if ! $SKIP_FONTS; then
    # A real instance has guicommon/ – the domain template already ships an
    # "mbeans" directory there (confirmed 2026-10-15), which is not an instance
    _tools_inst="$(for _d in "$_tools_base"/*/guicommon; do [ -d "$_d" ] && basename "$(dirname "$_d")"; done | xargs)"
    if [ -n "$_tools_inst" ]; then
        ok "$(printf "ReportsTools   : %s" "$_tools_inst")"
    else
        fail "No ReportsToolsComponent instance under $_tools_base"
        fail "  Run first: 09-Install/13-oracle_setup_reports.sh --apply"
        EXIT_CODE=2
    fi
fi
unset _tools_base _tools_inst _d

# cgicmd.dat: server= is the Reports SERVER COMPONENT (REPORTS_SERVER_NAME,
# e.g. repserver01), not the WLS managed server (WLS_REPORTS)
WLS_MANAGED_SERVER="${WLS_MANAGED_SERVER:-WLS_REPORTS}"
_reports_server="${REPORTS_SERVER_NAME:-repserver01}"
ok "$(printf "Reports server : %s  (managed server %s)" "$_reports_server" "$WLS_MANAGED_SERVER")"
[ -z "${REPORTS_SERVER_NAME:-}" ] && \
    warn "REPORTS_SERVER_NAME not set in environment.conf – using 'repserver01'"

# The application directory only exists after WLS_REPORTS was started once
CGICMD_DAT="${CGICMD_DAT:-$DOMAIN_HOME/config/fmwconfig/servers/$WLS_MANAGED_SERVER/applications/reports_14.1.2/configuration/cgicmd.dat}"
CGICMD_READY=true
if [ -f "$CGICMD_DAT" ]; then
    ok "$(printf "CGICMD_DAT     : %s" "$CGICMD_DAT")"
elif [ -d "$(dirname "$CGICMD_DAT")" ]; then
    info "$(printf "CGICMD_DAT     : %s (will be created from template)" "$CGICMD_DAT")"
else
    CGICMD_READY=false
    warn "$(printf "CGICMD_DAT     : %s – directory missing" "$CGICMD_DAT")"
    warn "  $WLS_MANAGED_SERVER has never been started – start it once, then re-run this script"
fi

# Execution user for the cgicmd.dat authid (rwservlet runs with
# singlesignon=yes - every report request needs a WebLogic login). Same source
# as 12-oracle_reports_users.sh: reports_users.conf.des3. Password never logged.
REPORTS_USERS_SEC="$ROOT_DIR/reports_users.conf.des3"
REPORTS_EXEC_PWD=""
if [ -f "$REPORTS_USERS_SEC" ] && load_secrets_file "$REPORTS_USERS_SEC" > /dev/null 2>&1; then
    REPORTS_EXEC_USER="${REPORTS_EXEC_USER:-RepRunner}"
fi
if [ -n "${REPORTS_EXEC_USER:-}" ] && [ -n "${REPORTS_EXEC_PWD:-}" ]; then
    ok "$(printf "Exec user      : %s (cgicmd.dat authid, password from %s)" \
        "$REPORTS_EXEC_USER" "$(basename "$REPORTS_USERS_SEC")")"
else
    CGICMD_READY=false
    warn "Execution user/password not found in $REPORTS_USERS_SEC"
    warn "  cgicmd.dat step skipped - run first: 09-Install/12-oracle_reports_users.sh --apply"
fi

[ "$EXIT_CODE" -ne 0 ] && { print_summary; exit "$EXIT_CODE"; }

# =============================================================================
# Planned steps
# =============================================================================

section "Configuration Steps"

_st_fonts="$($SKIP_FONTS && printf 'SKIPPED' || printf 'planned')"
printf "  %-3s  %-12s  %s\n" "Nr" "Status" "Action" | tee -a "$LOG_FILE"
printf "  %-3s  %-12s  %s\n" "---" "------------" "------" | tee -a "$LOG_FILE"
printf "  %-3s  %-12s  %s\n" "1" "$_st_fonts" \
    "Deploy fonts        → 04-ReportsFonts/deploy_fonts.sh --apply" | tee -a "$LOG_FILE"
printf "  %-3s  %-12s  %s\n" "2" "$_st_fonts" \
    "Font cache rebuild  → 04-ReportsFonts/font_cache_reset.sh --apply" | tee -a "$LOG_FILE"
printf "  %-3s  %-12s  %s\n" "3" "$_st_fonts" \
    "uifont.ali update   → 04-ReportsFonts/uifont_ali_update.sh --apply" | tee -a "$LOG_FILE"
printf "  %-3s  %-12s  %s\n" "4" "$_st_fonts" \
    "Font path in domain → 04-ReportsFonts/fontpath_config.sh --apply" | tee -a "$LOG_FILE"
printf "  %-3s  %-12s  %s\n" "5" "$($CGICMD_READY && printf 'planned' || printf 'NOT READY')" \
    "cgicmd.dat default  → template block (server: $_reports_server, authid: ${REPORTS_EXEC_USER:-?})" | tee -a "$LOG_FILE"
printf "  %-3s  %-12s  %s\n" "6" "planned" \
    "Config backup       → 07-Maintenance/backup_config.sh --apply" | tee -a "$LOG_FILE"
printf "\n" | tee -a "$LOG_FILE"
unset _st_fonts

if ! $APPLY; then
    info "Dry-run complete – use --apply to execute all steps"
    print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# Steps 1-4 – Font configuration
# =============================================================================

if ! $SKIP_FONTS; then
    _run_step "Deploy Fonts"        "$ROOT_DIR/04-ReportsFonts/deploy_fonts.sh"      --apply
    _run_step "Font Cache Rebuild"  "$ROOT_DIR/04-ReportsFonts/font_cache_reset.sh"  --apply
    _run_step "uifont.ali Update"   "$ROOT_DIR/04-ReportsFonts/uifont_ali_update.sh" --apply
    _run_step "Font Path (setUserOverrides.sh)" \
                                    "$ROOT_DIR/04-ReportsFonts/fontpath_config.sh"   --apply
fi

# =============================================================================
# Step 5 – cgicmd.dat default configuration
# =============================================================================

section "Step: cgicmd.dat Default Configuration"

_ts="$(date '+%Y-%m-%d %H:%M:%S')"
_marker_begin="# --- IHateWeblogic BEGIN ---"
_marker_end="# --- IHateWeblogic END ---"

if ! $CGICMD_READY; then
    warn "cgicmd.dat step skipped (see pre-checks)"
    info "  Then re-run: 09-Install/14b-oracle_reports_fonts.sh --apply --skip-fonts"
    STEP_FAILS=$(( STEP_FAILS + 1 ))
else
    # sed replacement: escape \ & | in the user/password
    _authid="$(printf '%s/%s' "$REPORTS_EXEC_USER" "$REPORTS_EXEC_PWD" | sed 's/[\\&|]/\\&/g')"
    _cgicmd_tmp="$(mktemp)" || { fail "Cannot create temp file"; EXIT_CODE=2; }
    chmod 600 "$_cgicmd_tmp"
    sed \
        -e "s|##REPORTS_SERVER##|${_reports_server}|g" \
        -e "s|##TIMESTAMP##|${_ts}|g" \
        -e "s|##REPORTS_EXEC_AUTHID##|${_authid}|g" \
        "$CGICMD_TEMPLATE" > "$_cgicmd_tmp"
    unset _authid

    if [ ! -f "$CGICMD_DAT" ]; then
        info "cgicmd.dat not found – creating: $CGICMD_DAT"
        mv "$_cgicmd_tmp" "$CGICMD_DAT"
        ok "cgicmd.dat created: $CGICMD_DAT"
    elif grep -qF "$_marker_begin" "$CGICMD_DAT" 2>/dev/null; then
        # Block already present (older version without authid): replace it -
        # everything outside the markers (Oracle samples, own keys) is kept.
        # The header comment block written before the BEGIN marker is kept
        # unchanged (only the date in it is old).
        backup_file "$CGICMD_DAT"
        _new="$(mktemp)"; chmod 600 "$_new"
        awk -v b="$_marker_begin" -v e="$_marker_end" -v blk="$_cgicmd_tmp" '
            BEGIN { while ((getline l < blk) > 0) { if (l == b) inb = 1; if (inb) nb = nb l "\n"; if (l == e) inb = 0 } }
            $0 == b { printf "%s", nb; skip = 1; next }
            skip && $0 == e { skip = 0; next }
            !skip { print }
        ' "$CGICMD_DAT" > "$_new"
        cat "$_new" > "$CGICMD_DAT"
        rm -f "$_new" "$_cgicmd_tmp"
        ok "IHateWeblogic block replaced in: $CGICMD_DAT"
    else
        backup_file "$CGICMD_DAT"
        printf "\n" >> "$CGICMD_DAT"
        cat "$_cgicmd_tmp" >> "$CGICMD_DAT"
        rm -f "$_cgicmd_tmp"
        ok "IHateWeblogic block appended to: $CGICMD_DAT"
    fi
    # Contains the RepRunner password (rwservlet encrypts it at the next start)
    chmod 640 "$CGICMD_DAT"
    find "$(dirname "$CGICMD_DAT")" -maxdepth 1 -name "$(basename "$CGICMD_DAT").bak_*" -exec chmod 600 {} \;

    if grep -qE "^default:.*%\* authid=${REPORTS_EXEC_USER}/" "$CGICMD_DAT"; then
        ok "default key: server=$_reports_server %* authid=$REPORTS_EXEC_USER/****"
    else
        fail "default key with authid not found in $CGICMD_DAT"
    fi
    info "  Restart $WLS_MANAGED_SERVER to load cgicmd.dat (the password is encrypted then)"
    info "  Backups contain the password in clear text - delete them when no longer needed:"
    info "    ls -l $(dirname "$CGICMD_DAT")/$(basename "$CGICMD_DAT").bak_*"
fi
unset _ts _marker_begin _marker_end _cgicmd_tmp _new
REPORTS_EXEC_PWD="xxxxxxxxxxxxxxxx"; unset REPORTS_EXEC_PWD

# =============================================================================
# Step 6 – Configuration backup (now incl. Reports/Forms/font config)
# =============================================================================

_run_step "Config Backup" "$ROOT_DIR/07-Maintenance/backup_config.sh" --apply

# =============================================================================
# Next steps
# =============================================================================

section "Next Steps"

info "Restart the Reports managed server + components to load fonts / cgicmd.dat:"
info "  01-Run/startStop.sh stop-all --apply && 01-Run/startStop.sh start-all --apply"
info "Verify:"
info "  01-Run/rwserver_status.sh"
info "  04-ReportsFonts/pdf_font_verify.sh <pdf_output_file>   (after the first report run)"
unset _reports_server

if [ "$STEP_FAILS" -gt 0 ]; then
    warn "$STEP_FAILS step(s) reported errors – check log: $LOG_FILE"
fi

printLine
print_summary
exit "$EXIT_CODE"
