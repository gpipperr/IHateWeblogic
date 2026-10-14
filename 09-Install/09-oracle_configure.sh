#!/bin/bash
# =============================================================================
# Script   : 09-oracle_configure.sh
# Purpose  : Orchestrate the post-domain configuration for Oracle Forms &
#            Reports 14.1.2 BEFORE the first start: boot.properties, JVM
#            settings, font OS packages, validation, initial backup.
#            Calls existing scripts; does not implement new functionality.
#            Font/uifont.ali/cgicmd.dat need the Reports components and run
#            later in 14b-oracle_reports_fonts.sh (split 2026-10-15).
# Call     : ./09-Install/09-oracle_configure.sh
#            ./09-Install/09-oracle_configure.sh --apply
#            ./09-Install/09-oracle_configure.sh --apply --skip-fonts
#            ./09-Install/09-oracle_configure.sh --help
# Options  : (none)        Dry-run: show planned configuration steps
#            --apply       Execute all configuration steps
#            --skip-fonts  Skip the font OS package step (2)
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
            printf "  --skip-fonts  Skip the font OS package step (2)\n"
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
    "$ROOT_DIR/09-Install/10-oracle_boot_properties.sh" \
    "$ROOT_DIR/04-ReportsFonts/get_root_install_libs.sh" \
    "$ROOT_DIR/07-Maintenance/backup_config.sh"
do
    [ -f "$_s" ] \
        && ok "$(printf "Script found   : %s" "$(basename "$_s")")" \
        || { warn "$(printf "Script missing : %s" "$_s")"; }
done
unset _s

[ "$EXIT_CODE" -ne 0 ] && { print_summary; exit "$EXIT_CODE"; }

# =============================================================================
# Planned steps (dry-run summary)
# =============================================================================

section "Configuration Steps"


printf "  %-3s  %-12s  %s\n" "Nr" "Status" "Action" | tee -a "$LOG_FILE"
printf "  %-3s  %-12s  %s\n" "---" "------------" "------" | tee -a "$LOG_FILE"
printf "  %-3s  %-12s  %s\n" "0" "planned" \
    "boot.properties     → 09-Install/10-oracle_boot_properties.sh --apply" | tee -a "$LOG_FILE"
printf "  %-3s  %-12s  %s\n" "1" "planned" \
    "JVM settings        → 02-Checks/weblogic_performance.sh --apply" | tee -a "$LOG_FILE"
printf "  %-3s  %-12s  %s\n" "2" "$($SKIP_FONTS && printf 'SKIPPED' || printf 'planned')" \
    "Font OS packages    → 04-ReportsFonts/get_root_install_libs.sh --apply" | tee -a "$LOG_FILE"
printf "  %-3s  %-12s  %s\n" "3" "planned" \
    "Validate domain     → nodemanager.properties, setUserOverrides.sh" | tee -a "$LOG_FILE"
printf "  %-3s  %-12s  %s\n" "4" "planned" \
    "Initial backup      → 07-Maintenance/backup_config.sh --apply" | tee -a "$LOG_FILE"
printf "  %-3s  %-12s  %s\n" "-" "later" \
    "Fonts/uifont.ali/cgicmd.dat → 14b-oracle_reports_fonts.sh (after 13/14 + first start)" | tee -a "$LOG_FILE"
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
# Step 2 – Font OS packages  (skippable via --skip-fonts)
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

fi

# =============================================================================
# Step 3 – Validate domain artifacts
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
# Step 4 – Initial configuration backup (domain only – Reports/Forms config
#          is backed up again by 14b- once it exists)
# =============================================================================

_run_step "Initial Config Backup" \
    "$ROOT_DIR/07-Maintenance/backup_config.sh" --apply

# =============================================================================
# Next steps
# =============================================================================

section "Next Steps"

info "Pre-start configuration complete. Next steps (see 09-Install/README.md, Phase 6):"
info "  10-oracle_boot_properties.sh, 11-oracle_nodemanager.sh, 12-oracle_reports_users.sh,"
info "  13-root_reports_fix.sh, 13-oracle_setup_reports.sh, 14-oracle_setup_forms.sh,"
info "  then start the domain once and run 14b-oracle_reports_fonts.sh --apply"
info "  (fonts, uifont.ali, cgicmd.dat – need the Reports components)"

# =============================================================================
# Summary
# =============================================================================

if [ "$STEP_FAILS" -gt 0 ]; then
    warn "$STEP_FAILS configuration step(s) reported errors – check log: $LOG_FILE"
fi

printLine
print_summary
exit "$EXIT_CODE"
