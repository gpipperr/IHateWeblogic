#!/bin/bash
# =============================================================================
# Script   : backup_config.sh
# Purpose  : Backup all relevant Oracle Reports/Forms configuration files to
#            ConfigBackup/YYYYMMDD_HHMM/ before making changes (fonts, server
#            config, domain environment).  Creates a manifest.txt with original
#            path, filename, and timestamp for each backed-up file.
#            Run before: deploy_fonts.sh, uifont_ali_update.sh, fontpath_config.sh
# Call     : ./backup_config.sh [--apply]
# Requires : cp, mkdir, find
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"

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
APPLY_MODE=false
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY_MODE=true ;;
        --help)
            printf "Usage: %s [--apply]\n" "$(basename "$0")"
            printf "  Default: dry-run – show which files would be backed up\n"
            printf "  --apply: create ConfigBackup/YYYYMMDD_HHMM/ and copy files\n"
            exit 0
            ;;
    esac
done

# =============================================================================
# Variables
# =============================================================================
BACKUP_BASE="$SCRIPT_DIR/ConfigBackup"
TS="$(date '+%Y%m%d_%H%M')"
BACKUP_DIR="$BACKUP_BASE/$TS"

UIFONT_ALI="${UIFONT_ALI:-}"
SETDOMAINENV="${SETDOMAINENV:-$DOMAIN_HOME/bin/setDomainEnv.sh}"
OVERRIDES_SH="$DOMAIN_HOME/bin/setUserOverrides.sh"

# =============================================================================
# Discover configuration paths via find (paths contain dynamic version numbers
# and server instance names; environment.conf only covers the most common ones)
# =============================================================================

# --- ReportsServerComponent dir ---
# $DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent/<name>/
REPORTS_COMP_DIR=""
_rsc_base="$DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent"
if [ -d "$_rsc_base" ]; then
    REPORTS_COMP_DIR="$(find "$_rsc_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -1)"
fi

RWSERVER_CONF_COMP=""   # ReportsServerComponent/rwserver.conf
RWNETWORK_CONF=""        # ReportsServerComponent/rwnetwork.conf
if [ -n "$REPORTS_COMP_DIR" ]; then
    [ -f "$REPORTS_COMP_DIR/rwserver.conf" ]  && RWSERVER_CONF_COMP="$REPORTS_COMP_DIR/rwserver.conf"
    [ -f "$REPORTS_COMP_DIR/rwnetwork.conf" ] && RWNETWORK_CONF="$REPORTS_COMP_DIR/rwnetwork.conf"
fi
# Fallback: use RWSERVER_CONF from environment.conf if component dir not found
if [ -z "$RWSERVER_CONF_COMP" ] && [ -n "${RWSERVER_CONF:-}" ] && [ -f "$RWSERVER_CONF" ]; then
    RWSERVER_CONF_COMP="$RWSERVER_CONF"
fi

# --- Reports WLS application dir ---
# $DOMAIN_HOME/config/fmwconfig/servers/$WLS_MANAGED_SERVER/applications/reports_<version>/configuration/
REPORTS_WLS_CONF_DIR=""
if [ -n "${WLS_MANAGED_SERVER:-}" ]; then
    _rapp_base="$DOMAIN_HOME/config/fmwconfig/servers/$WLS_MANAGED_SERVER/applications"
    if [ -d "$_rapp_base" ]; then
        REPORTS_WLS_CONF_DIR="$(find "$_rapp_base" -maxdepth 3 -type d -name "configuration" \
            2>/dev/null | grep -i "reports_" | head -1)"
    fi
fi
# Fallback: search all server dirs
if [ -z "$REPORTS_WLS_CONF_DIR" ]; then
    REPORTS_WLS_CONF_DIR="$(find "$DOMAIN_HOME/config/fmwconfig/servers" \
        -maxdepth 5 -type d -name "configuration" 2>/dev/null | grep -i "reports_" | head -1)"
fi

RWSERVER_CONF_WLS=""     # In-Process WLS rwserver.conf
RWSERVLET_PROPS=""        # rwservlet.properties
CGICMD_DAT=""             # cgicmd.dat (domain deployment)
if [ -n "$REPORTS_WLS_CONF_DIR" ]; then
    [ -f "$REPORTS_WLS_CONF_DIR/rwserver.conf" ]        && RWSERVER_CONF_WLS="$REPORTS_WLS_CONF_DIR/rwserver.conf"
    [ -f "$REPORTS_WLS_CONF_DIR/rwservlet.properties" ] && RWSERVLET_PROPS="$REPORTS_WLS_CONF_DIR/rwservlet.properties"
    for _c in "$REPORTS_WLS_CONF_DIR/cgicmd.dat" "$REPORTS_WLS_CONF_DIR/CGICMD.DAT"; do
        [ -f "$_c" ] && { CGICMD_DAT="$_c"; break; }
    done
fi

# --- FMW installation cgicmd.dat ---
# $FMW_HOME/reports/conf/cgicmd.dat  (separate backup category to avoid name collision)
FMW_CGICMD=""
for _c in "${FMW_HOME}/reports/conf/cgicmd.dat" "${FMW_HOME}/reports/conf/CGICMD.DAT"; do
    [ -f "$_c" ] && { FMW_CGICMD="$_c"; break; }
done

# --- Forms WLS application dir ---
# $DOMAIN_HOME/config/fmwconfig/servers/WLS_FORMS/applications/forms_<version>/config/
FORMS_WLS_CONF_DIR=""
FORMS_WLS_CONF_DIR="$(find "$DOMAIN_HOME/config/fmwconfig/servers" \
    -maxdepth 5 -type d -name "config" 2>/dev/null | grep -i "forms_" | head -1)"

FORMSWEB_CFG=""   # formsweb.cfg
DEFAULT_ENV=""    # default.env
if [ -n "$FORMS_WLS_CONF_DIR" ]; then
    [ -f "$FORMS_WLS_CONF_DIR/formsweb.cfg" ] && FORMSWEB_CFG="$FORMS_WLS_CONF_DIR/formsweb.cfg"
    [ -f "$FORMS_WLS_CONF_DIR/default.env" ]   && DEFAULT_ENV="$FORMS_WLS_CONF_DIR/default.env"
fi

# =============================================================================
# Banner
# =============================================================================
printLine
printf "\n\033[1mIHateWeblogic – Configuration Backup\033[0m\n"
printf "Host    : %s\n" "$(_get_hostname)"
printf "Date    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "Mode    : %s\n" "$( $APPLY_MODE && echo 'APPLY (will create backup)' || echo 'DRY-RUN (use --apply to write)')"
printf "Backup  : %s\n" "$BACKUP_DIR"
printf "Log     : %s\n\n" "$LOG_FILE"

# Show discovered paths
printList "REPORTS_COMP_DIR"    36 "${REPORTS_COMP_DIR:-(not found)}"
printList "REPORTS_WLS_CONF_DIR" 36 "${REPORTS_WLS_CONF_DIR:-(not found)}"
printList "FORMS_WLS_CONF_DIR"  36 "${FORMS_WLS_CONF_DIR:-(not found)}"
printf "\n"

# =============================================================================
# Define backup items: "category|source_path|description"
# =============================================================================
BACKUP_ITEMS=(
    # Font configuration
    "fonts|${UIFONT_ALI}|Oracle Reports font alias file (uifont.ali)"
    # Reports Server Component (ReportsServerComponent/<name>/)
    "reports_comp|${RWSERVER_CONF_COMP}|Reports Server Component config (rwserver.conf)"
    "reports_comp|${RWNETWORK_CONF}|Reports Server network config (rwnetwork.conf)"
    # Reports WLS application (reports_<version>/configuration/)
    "reports_wls|${RWSERVER_CONF_WLS}|Reports In-Process WLS config (rwserver.conf)"
    "reports_wls|${RWSERVLET_PROPS}|Reports servlet properties (rwservlet.properties)"
    "reports_wls|${CGICMD_DAT}|Reports CGI command mapping – domain (cgicmd.dat)"
    # FMW installation (separate category – same filename as domain cgicmd.dat)
    "fmw|${FMW_CGICMD}|Reports CGI command mapping – FMW install (cgicmd.dat)"
    # Forms WLS application (forms_<version>/config/)
    "forms_wls|${FORMSWEB_CFG}|Forms web configuration (formsweb.cfg)"
    "forms_wls|${DEFAULT_ENV}|Forms default environment (default.env)"
    # Domain environment
    "domain|${SETDOMAINENV}|WebLogic domain environment script (setDomainEnv.sh)"
    "domain|${OVERRIDES_SH}|Domain environment customizations (setUserOverrides.sh)"
    # IHateWeblogic
    "ihw|${ENV_CONF}|IHateWeblogic environment configuration (environment.conf)"
)

# =============================================================================
# Section 1: Check source files
# =============================================================================
section "Source Files to Back Up"

# Associate array: track which items can actually be backed up
declare -A ITEM_OK   # src_path → 1 if file exists
FOUND_COUNT=0
MISSING_COUNT=0

for item in "${BACKUP_ITEMS[@]}"; do
    IFS='|' read -r category src_path description <<< "$item"

    if [ -z "$src_path" ]; then
        warn "  %-10s  %s  (path not set in environment.conf)" "$category" "$description"
        MISSING_COUNT=$(( MISSING_COUNT + 1 ))
        continue
    fi

    if [ -f "$src_path" ]; then
        sz="$(du -h "$src_path" 2>/dev/null | cut -f1)"
        ok "  %-10s  %-35s  %s (%s)" "$category" "$(basename "$src_path")" "$src_path" "$sz"
        ITEM_OK["$src_path"]=1
        FOUND_COUNT=$(( FOUND_COUNT + 1 ))
    else
        warn "  %-10s  %-35s  NOT FOUND: %s" "$category" "$(basename "$src_path")" "$src_path"
        MISSING_COUNT=$(( MISSING_COUNT + 1 ))
    fi
done

printf "\n"
info "$FOUND_COUNT file(s) ready to back up, $MISSING_COUNT not found / not configured"

# =============================================================================
# Section 2: Existing backups overview
# =============================================================================
section "Existing Backups in ConfigBackup/"

if [ ! -d "$BACKUP_BASE" ]; then
    info "No backup directory yet: $BACKUP_BASE"
else
    EXISTING=()
    while IFS= read -r d; do
        EXISTING+=("$(basename "$d")")
    done < <(find "$BACKUP_BASE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)

    if [ "${#EXISTING[@]}" -eq 0 ]; then
        info "No existing backups found"
    else
        ok "${#EXISTING[@]} existing backup(s):"
        for d in "${EXISTING[@]}"; do
            fc="$(find "$BACKUP_BASE/$d" -type f 2>/dev/null | wc -l)"
            printf "    %s  (%d files)\n" "$d" "$fc" | tee -a "${LOG_FILE:-/dev/null}"
        done
    fi
fi

# =============================================================================
# Section 3: Apply – create backup
# =============================================================================
section "Backup Execution"

if ! $APPLY_MODE; then
    info "Dry-run complete – run with --apply to create the backup"
    info "Target directory: $BACKUP_DIR"
    printLine
    print_summary
    exit $EXIT_CODE
fi

if [ "$FOUND_COUNT" -eq 0 ]; then
    warn "No files to back up – all sources are missing or not configured"
    printLine
    print_summary
    exit $EXIT_CODE
fi

# Create category subdirectories
for cat in fonts reports_comp reports_wls fmw forms_wls domain ihw; do
    if ! mkdir -p "$BACKUP_DIR/$cat" 2>/dev/null; then
        fail "Cannot create backup directory: $BACKUP_DIR/$cat"
        print_summary
        exit $EXIT_CODE
    fi
done
ok "Backup directory created: $BACKUP_DIR"

# Write manifest header
MANIFEST="$BACKUP_DIR/manifest.txt"
{
    printf "# IHateWeblogic Config Backup Manifest\n"
    printf "# Host     : %s\n" "$(_get_hostname)"
    printf "# Created  : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# Backup   : %s\n" "$BACKUP_DIR"
    printf "# ---\n"
    printf "# %-10s  %-35s  %s\n" "Category" "Filename" "Original Path"
    printf "# %-10s  %-35s  %s\n" \
        "----------" "-----------------------------------" "-----------"
} > "$MANIFEST"

# Copy each file and append to manifest
for item in "${BACKUP_ITEMS[@]}"; do
    IFS='|' read -r category src_path description <<< "$item"

    [ -z "$src_path" ]                       && continue
    [ "${ITEM_OK[$src_path]:-0}" -ne 1 ]     && continue

    fname="$(basename "$src_path")"
    dst="$BACKUP_DIR/$category/$fname"

    if cp "$src_path" "$dst" 2>/dev/null; then
        ok "  Backed up [%-6s] %s" "$category" "$fname"
        printf "  %-10s  %-35s  %s\n" "$category" "$fname" "$src_path" >> "$MANIFEST"
    else
        fail "  Failed to copy: $src_path → $dst"
    fi
done

ok "Manifest written: $MANIFEST"

# =============================================================================
# Section 4: Next Steps
# =============================================================================
section "Next Steps"

info "Backup stored in: $BACKUP_DIR"
info "  Restore with  : ./restore_config.sh --apply"
info "  Now safe to run:"
info "    deploy_fonts.sh --apply"
info "    uifont_ali_update.sh --apply"
info "    fontpath_config.sh --apply"

# =============================================================================
# Summary
# =============================================================================
printLine
print_summary
exit $EXIT_CODE
