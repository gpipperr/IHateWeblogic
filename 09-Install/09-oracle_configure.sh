#!/bin/bash
# =============================================================================
# Script   : 09-oracle_configure.sh
# Purpose  : Orchestrate the post-domain configuration for Oracle Forms &
#            Reports 14.1.2.  Calls existing scripts in the correct sequence;
#            does not implement new functionality.
#            After this script completes the domain is ready to start.
# Call     : ./09-Install/09-oracle_configure.sh
#            ./09-Install/09-oracle_configure.sh --apply
#            ./09-Install/09-oracle_configure.sh --apply --skip-fonts
#            ./09-Install/09-oracle_configure.sh --help
# Options  : (none)        Dry-run: show planned configuration steps
#            --apply       Execute all configuration steps
#            --skip-fonts  Skip font-related steps (3-5)
#            --help        Show usage
# Runs as  : oracle
# Requires : 08-oracle_setup_domain.sh must have completed successfully
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/docs/09-oracle_configure.md
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
            printf "  (none)        Dry-run: show planned configuration steps\n"
            printf "  --apply       Execute all configuration steps\n"
            printf "  --skip-fonts  Skip font installation and configuration (steps 3-5)\n"
            printf "  --help        Show this help\n\n"
            printf "Prerequisite: 08-oracle_setup_domain.sh must have completed successfully.\n"
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
    # Remaining args are passed to the script

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
printf "\033[1m  IHateWeblogic – Post-Domain Configuration\033[0m\n"
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

# Domain must exist
[ -f "$DOMAIN_HOME/config/config.xml" ] \
    && ok "Domain found: $DOMAIN_HOME" \
    || { fail "Domain not found: $DOMAIN_HOME/config/config.xml"; \
         fail "  Run first: 09-Install/08-oracle_setup_domain.sh --apply"; \
         EXIT_CODE=2; }

# Verify required subscripts
for _s in \
    "$ROOT_DIR/02-Checks/weblogic_performance.sh" \
    "$ROOT_DIR/04-ReportsFonts/get_root_install_libs.sh" \
    "$ROOT_DIR/04-ReportsFonts/font_cache_reset.sh" \
    "$ROOT_DIR/04-ReportsFonts/uifont_ali_update.sh" \
    "$ROOT_DIR/04-ReportsFonts/fontpath_config.sh" \
    "$ROOT_DIR/07-Maintenance/backup_config.sh"
do
    [ -f "$_s" ] \
        && ok "$(printf "Script found   : %s" "$(basename "$_s")")" \
        || { warn "$(printf "Script missing : %s" "$_s")"; }
done
unset _s

# cgicmd.dat template
[ -f "$CGICMD_TEMPLATE" ] \
    && ok "$(printf "Template found : %s" "$(basename "$CGICMD_TEMPLATE")")" \
    || { fail "cgicmd.dat template missing: $CGICMD_TEMPLATE"; EXIT_CODE=2; }

# CGICMD_DAT from environment.conf
if [ -z "${CGICMD_DAT:-}" ]; then
    warn "CGICMD_DAT not set in environment.conf – cgicmd.dat step will be skipped"
    warn "  Run: 00-Setup/init_env.sh --apply  to set CGICMD_DAT"
elif [ ! -f "$CGICMD_DAT" ]; then
    warn "CGICMD_DAT file not found: $CGICMD_DAT"
    info "  File will be created from template with --apply"
else
    ok "$(printf "CGICMD_DAT     : %s" "$CGICMD_DAT")"
fi

# WLS_MANAGED_SERVER for Reports Server name substitution
[ -n "${WLS_MANAGED_SERVER:-}" ] \
    && ok "$(printf "Reports server : %s" "$WLS_MANAGED_SERVER")" \
    || warn "WLS_MANAGED_SERVER not set in environment.conf – using 'repserver01' as fallback"

[ "$EXIT_CODE" -ne 0 ] && { print_summary; exit "$EXIT_CODE"; }

# =============================================================================
# Planned steps (dry-run summary)
# =============================================================================

section "Configuration Steps"

_reports_server="${WLS_MANAGED_SERVER:-repserver01}"

printf "  %-3s  %-12s  %s\n" "Nr" "Status" "Action" | tee -a "$LOG_FILE"
printf "  %-3s  %-12s  %s\n" "---" "------------" "------" | tee -a "$LOG_FILE"
printf "  %-3s  %-12s  %s\n" "1" "planned" \
    "JVM settings        → 02-Checks/weblogic_performance.sh --apply" | tee -a "$LOG_FILE"
if $SKIP_FONTS; then
    printf "  %-3s  %-12s  %s\n" "2" "SKIPPED" \
        "Font OS packages    → 04-ReportsFonts/get_root_install_libs.sh --apply" | tee -a "$LOG_FILE"
    printf "  %-3s  %-12s  %s\n" "3" "SKIPPED" \
        "Font cache rebuild  → 04-ReportsFonts/font_cache_reset.sh --apply" | tee -a "$LOG_FILE"
    printf "  %-3s  %-12s  %s\n" "4" "SKIPPED" \
        "uifont.ali update   → 04-ReportsFonts/uifont_ali_update.sh --apply" | tee -a "$LOG_FILE"
    printf "  %-3s  %-12s  %s\n" "5" "SKIPPED" \
        "Font path in domain → 04-ReportsFonts/fontpath_config.sh --apply" | tee -a "$LOG_FILE"
else
    printf "  %-3s  %-12s  %s\n" "2" "planned" \
        "Font OS packages    → 04-ReportsFonts/get_root_install_libs.sh --apply" | tee -a "$LOG_FILE"
    printf "  %-3s  %-12s  %s\n" "3" "planned" \
        "Font cache rebuild  → 04-ReportsFonts/font_cache_reset.sh --apply" | tee -a "$LOG_FILE"
    printf "  %-3s  %-12s  %s\n" "4" "planned" \
        "uifont.ali update   → 04-ReportsFonts/uifont_ali_update.sh --apply" | tee -a "$LOG_FILE"
    printf "  %-3s  %-12s  %s\n" "5" "planned" \
        "Font path in domain → 04-ReportsFonts/fontpath_config.sh --apply" | tee -a "$LOG_FILE"
fi
printf "  %-3s  %-12s  %s\n" "6" "planned" \
    "cgicmd.dat default  → append template (server: $_reports_server)" | tee -a "$LOG_FILE"
printf "  %-3s  %-12s  %s\n" "7" "planned" \
    "Validate domain     → nodemanager.properties, setUserOverrides.sh" | tee -a "$LOG_FILE"
printf "  %-3s  %-12s  %s\n" "8" "planned" \
    "Initial backup      → 07-Maintenance/backup_config.sh --apply" | tee -a "$LOG_FILE"
printf "\n" | tee -a "$LOG_FILE"

if ! $APPLY; then
    info "Dry-run complete – use --apply to execute all steps"
    print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# Step 0 – boot.properties (must exist before first domain start)
# =============================================================================

_run_step "boot.properties" \
    "$ROOT_DIR/09-Install/10-oracle_boot_properties.sh" --apply

# =============================================================================
# Step 1 – JVM performance settings
# =============================================================================

_run_step "JVM Settings" \
    "$ROOT_DIR/02-Checks/weblogic_performance.sh" --apply

# =============================================================================
# Steps 2-5 – Font configuration  (skippable via --skip-fonts)
# =============================================================================

if ! $SKIP_FONTS; then

    # Step 2 – Font OS packages
    # get_root_install_libs.sh --apply requires root or sudo.
    # Check availability before attempting.
    section "Step: Font OS Packages"
    _font_lib_script="$ROOT_DIR/04-ReportsFonts/get_root_install_libs.sh"

    if [ "$(id -u)" -eq 0 ]; then
        bash "$_font_lib_script" --apply 2>&1 | tee -a "$LOG_FILE"
        [ "${PIPESTATUS[0]}" -ne 0 ] && STEP_FAILS=$(( STEP_FAILS + 1 ))
    elif sudo -n true 2>/dev/null; then
        sudo bash "$_font_lib_script" --apply 2>&1 | tee -a "$LOG_FILE"
        [ "${PIPESTATUS[0]}" -ne 0 ] && STEP_FAILS=$(( STEP_FAILS + 1 ))
    else
        warn "No root/sudo access – font OS packages cannot be installed automatically"
        info "  Run manually as root:"
        info "    sudo bash $ROOT_DIR/04-ReportsFonts/get_root_install_libs.sh --apply"
        # dry-run to show which packages are needed
        bash "$_font_lib_script" 2>&1 | tee -a "$LOG_FILE"
    fi
    unset _font_lib_script

    # Step 3 – Font cache rebuild
    _run_step "Font Cache Rebuild" \
        "$ROOT_DIR/04-ReportsFonts/font_cache_reset.sh" --apply

    # Step 4 – uifont.ali update
    _run_step "uifont.ali Update" \
        "$ROOT_DIR/04-ReportsFonts/uifont_ali_update.sh" --apply

    # Step 5 – Font path in setUserOverrides.sh
    _run_step "Font Path (setUserOverrides.sh)" \
        "$ROOT_DIR/04-ReportsFonts/fontpath_config.sh" --apply

fi

# =============================================================================
# Step 6 – cgicmd.dat default configuration
# =============================================================================

section "Step: cgicmd.dat Default Configuration"

_reports_server="${WLS_MANAGED_SERVER:-repserver01}"
_ts="$(date '+%Y-%m-%d %H:%M:%S')"
_marker_begin="# --- IHateWeblogic BEGIN ---"
_marker_end="# --- IHateWeblogic END ---"

if [ -z "${CGICMD_DAT:-}" ]; then
    warn "CGICMD_DAT not set – skipping cgicmd.dat configuration"
    info "  Set CGICMD_DAT in environment.conf and re-run this step"
else
    # Check if block already present (idempotent)
    if [ -f "$CGICMD_DAT" ] && grep -qF "$_marker_begin" "$CGICMD_DAT" 2>/dev/null; then
        ok "IHateWeblogic block already present in $CGICMD_DAT – skipping"
        info "  Remove the block manually to re-apply"
    else
        # Substitute placeholders in template → temp file
        _cgicmd_tmp="$(mktemp)" || { fail "Cannot create temp file"; EXIT_CODE=2; }

        sed \
            -e "s|##REPORTS_SERVER##|${_reports_server}|g" \
            -e "s|##TIMESTAMP##|${_ts}|g" \
            "$CGICMD_TEMPLATE" > "$_cgicmd_tmp"

        if [ ! -f "$CGICMD_DAT" ]; then
            # File doesn't exist yet – create it
            info "cgicmd.dat not found – creating: $CGICMD_DAT"
            mkdir -p "$(dirname "$CGICMD_DAT")" 2>/dev/null
            mv "$_cgicmd_tmp" "$CGICMD_DAT"
            chmod 640 "$CGICMD_DAT"
            ok "cgicmd.dat created: $CGICMD_DAT"
        else
            # Append to existing file
            backup_file "$CGICMD_DAT"
            printf "\n" >> "$CGICMD_DAT"
            cat "$_cgicmd_tmp" >> "$CGICMD_DAT"
            rm -f "$_cgicmd_tmp"
            ok "IHateWeblogic block appended to: $CGICMD_DAT"
        fi

        info "  Reports Server : $_reports_server"
        info "  default: key   → server=$_reports_server statusformat=xml"
        info "  Named keys     → see comments in $CGICMD_TEMPLATE"
        info "  authid user    → create with: 09-Install/10-oracle_setup_reports_user.sh"
    fi
fi

unset _reports_server _ts _marker_begin _marker_end _cgicmd_tmp

# =============================================================================
# Step 7 – Validate domain artifacts
# =============================================================================

section "Step: Domain Validation"

_val_fails=0
for _path in \
    "$DOMAIN_HOME/config/config.xml" \
    "$DOMAIN_HOME/bin/setDomainEnv.sh" \
    "$DOMAIN_HOME/bin/setUserOverrides.sh" \
    "$DOMAIN_HOME/nodemanager/nodemanager.properties" \
    "$DOMAIN_HOME/servers/AdminServer/security/boot.properties"
do
    if [ -f "$_path" ]; then
        ok "$(printf "Found: %s" "$_path")"
    else
        warn "$(printf "Missing: %s" "$_path")"
        _val_fails=$(( _val_fails + 1 ))
    fi
done
unset _path

[ "$_val_fails" -gt 0 ] && \
    warn "$_val_fails artifact(s) not found – check domain setup"

# Check nodemanager.properties ListenAddress
_nm_props="$DOMAIN_HOME/nodemanager/nodemanager.properties"
if [ -f "$_nm_props" ]; then
    _nm_listen="$(grep -E '^ListenAddress' "$_nm_props" 2>/dev/null | cut -d= -f2)"
    _nm_port="$(grep -E '^ListenPort' "$_nm_props" 2>/dev/null | cut -d= -f2)"
    ok "$(printf "NodeManager    : %s:%s" "${_nm_listen:-?}" "${_nm_port:-?}")"
fi
unset _nm_props _nm_listen _nm_port _val_fails

# =============================================================================
# Step 8 – Initial configuration backup
# =============================================================================

_run_step "Initial Config Backup" \
    "$ROOT_DIR/07-Maintenance/backup_config.sh" --apply

# =============================================================================
# Next steps
# =============================================================================

section "Next Steps"

info "Configuration complete. Recommended next steps:"
info ""
info "  1. Start AdminServer (no password prompt – boot.properties in place):"
info "       \$DOMAIN_HOME/bin/startWebLogic.sh &"
info "       # Wait ~60s, then verify:"
info "       curl -s http://${WLS_LISTEN_ADDRESS:-localhost}:${WLS_ADMIN_PORT:-7001}/console/"
info "       # On first start WebLogic encrypts boot.properties automatically"
info ""
info "  2. Start managed servers via Node Manager:"
info "       \$DOMAIN_HOME/bin/startManagedWebLogic.sh ${WLS_MANAGED_SERVER:-WLS_REPORTS} \\"
info "           http://${WLS_LISTEN_ADDRESS:-localhost}:${WLS_ADMIN_PORT:-7001}"
info ""
info "  3. Verify Reports Server:"
info "       ./01-Run/rwserver_status.sh"
info ""
info "  4. Create Reports execution user (needed for authid in cgicmd.dat):"
info "       ./09-Install/10-oracle_setup_reports_user.sh --apply"
info ""
info "  5. Font verification after first report run:"
info "       ./04-ReportsFonts/pdf_font_verify.sh <pdf_output_file>"

# =============================================================================
# Summary
# =============================================================================

if [ "$STEP_FAILS" -gt 0 ]; then
    warn "$STEP_FAILS configuration step(s) reported errors – check log: $LOG_FILE"
fi

printLine
print_summary
exit "$EXIT_CODE"
