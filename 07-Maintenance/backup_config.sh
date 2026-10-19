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
# Backups hold rwserver.conf (<identifier>), default.env, jps-config*.xml,
# environment.conf – owner only (dirs 700, files 600)
umask 077
BACKUP_DIR="$BACKUP_BASE/$TS"

UIFONT_ALI="${UIFONT_ALI:-}"
SETDOMAINENV="${SETDOMAINENV:-$DOMAIN_HOME/bin/setDomainEnv.sh}"
OVERRIDES_SH="$DOMAIN_HOME/bin/setUserOverrides.sh"

# =============================================================================
# Discover configuration paths via find (paths contain dynamic version numbers
# and server instance names; environment.conf only covers the most common ones)
# =============================================================================

# --- ReportsServerComponent dir ---
# $DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent/<instance>/
# Find the instance directory that actually contains rwserver.conf (not 'mbeans').
REPORTS_COMP_DIR=""
_rsc_base="$DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent"
if [ -d "$_rsc_base" ]; then
    REPORTS_COMP_DIR="$(find "$_rsc_base" -mindepth 2 -maxdepth 2 \
        -name "rwserver.conf" 2>/dev/null | xargs -I{} dirname {} 2>/dev/null | head -1)"
    # Fallback: first non-mbeans subdirectory
    if [ -z "$REPORTS_COMP_DIR" ]; then
        REPORTS_COMP_DIR="$(find "$_rsc_base" -mindepth 1 -maxdepth 1 -type d \
            ! -name "mbeans" 2>/dev/null | sort | head -1)"
    fi
fi

RWSERVER_CONF_COMP=""   # ReportsServerComponent/<instance>/rwserver.conf
RWNETWORK_CONF_RSC=""   # ReportsServerComponent/<instance>/rwnetwork.conf
if [ -n "$REPORTS_COMP_DIR" ]; then
    [ -f "$REPORTS_COMP_DIR/rwserver.conf" ]  && RWSERVER_CONF_COMP="$REPORTS_COMP_DIR/rwserver.conf"
    [ -f "$REPORTS_COMP_DIR/rwnetwork.conf" ] && RWNETWORK_CONF_RSC="$REPORTS_COMP_DIR/rwnetwork.conf"
fi
# Fallback: use RWSERVER_CONF from environment.conf if component dir not found
if [ -z "$RWSERVER_CONF_COMP" ] && [ -n "${RWSERVER_CONF:-}" ] && [ -f "$RWSERVER_CONF" ]; then
    RWSERVER_CONF_COMP="$RWSERVER_CONF"
fi

# --- ReportsToolsComponent dir ---
# $DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/<instance>/rwnetwork.conf
RWNETWORK_CONF_RTC=""
_rtc_base="$DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent"
if [ -d "$_rtc_base" ]; then
    RWNETWORK_CONF_RTC="$(find "$_rtc_base" -name "rwnetwork.conf" 2>/dev/null | sort | head -1)"
fi

# --- Reports Font Directory (TTF files to back up) ---
REPORTS_FONT_DIR="${REPORTS_FONT_DIR:-$DOMAIN_HOME/reports/fonts}"
TTF_FILES=()
if [ -d "$REPORTS_FONT_DIR" ]; then
    while IFS= read -r _ttf; do
        TTF_FILES+=("$_ttf")
    done < <(find "$REPORTS_FONT_DIR" -maxdepth 1 -type f \
        \( -iname "*.ttf" -o -iname "*.ttc" -o -iname "*.otf" \) 2>/dev/null | sort)
fi

# --- Customer / licensed font originals (04-ReportsFonts/custom_fonts_dir/) ---
# Source for deploy_fonts.sh – gitignored (licences), so this backup is the
# only copy next to the deployed files in REPORTS_FONT_DIR
CUSTOM_FONTS_DIR="$ROOT_DIR/04-ReportsFonts/custom_fonts_dir"
CUSTOM_FONT_FILES=()
if [ -d "$CUSTOM_FONTS_DIR" ]; then
    while IFS= read -r _cf; do CUSTOM_FONT_FILES+=("$_cf"); done \
        < <(find "$CUSTOM_FONTS_DIR" -maxdepth 1 -type f \
            \( -iname "*.ttf" -o -iname "*.ttc" -o -iname "*.otf" \) 2>/dev/null | sort)
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
# $ORACLE_HOME/reports/conf/cgicmd.dat  (separate backup category to avoid name collision)
FMW_CGICMD=""
for _c in "${ORACLE_HOME:-${FMW_HOME}}/reports/conf/cgicmd.dat" "${ORACLE_HOME:-${FMW_HOME}}/reports/conf/CGICMD.DAT"; do
    [ -f "$_c" ] && { FMW_CGICMD="$_c"; break; }
done

# --- Forms WLS application dir ---
# $DOMAIN_HOME/config/fmwconfig/servers/WLS_FORMS/applications/forms_<version>/config/
FORMS_WLS_CONF_DIR=""
FORMS_WLS_CONF_DIR="$(find "$DOMAIN_HOME/config/fmwconfig/servers" \
    -maxdepth 5 -type d -name "config" 2>/dev/null \
    | grep -iE "/(formsapp|forms)_[^/]*/config$" | head -1)"
# 14.1.2: servers/WLS_FORMS/applications/formsapp_14.1.2/config - the old
# pattern "forms_" (12c: forms_12.2.1) never matched it (2026-10-15)

FORMSWEB_CFG=""   # formsweb.cfg
DEFAULT_ENV=""    # default.env
if [ -n "$FORMS_WLS_CONF_DIR" ]; then
    [ -f "$FORMS_WLS_CONF_DIR/formsweb.cfg" ] && FORMSWEB_CFG="$FORMS_WLS_CONF_DIR/formsweb.cfg"
    [ -f "$FORMS_WLS_CONF_DIR/default.env" ]   && DEFAULT_ENV="$FORMS_WLS_CONF_DIR/default.env"
fi

# --- Files written by our own scripts (12- to 14b-, 03-Logs/setLogLevel.sh,
#     04-ReportsFonts/paramform_afm_setup.sh) – added 2026-10-19 ---
_frm_inst_name="${FORMS_INSTANCE_NAME:-forms1}"
WEBUTIL_CFG="$DOMAIN_HOME/config/fmwconfig/components/FORMS/instances/$_frm_inst_name/server/webutil.cfg"
WEBUTIL_CFG_ALT="$DOMAIN_HOME/config/fmwconfig/components/FORMS/$_frm_inst_name/server/webutil.cfg"
REGISTRY_DAT="${FORMS_WLS_CONF_DIR:+$FORMS_WLS_CONF_DIR/oracle/forms/registry/Registry.dat}"
JPS_CONFIG="$DOMAIN_HOME/config/fmwconfig/jps-config.xml"
JPS_CONFIG_JSE="$DOMAIN_HOME/config/fmwconfig/jps-config-jse.xml"
CONFIG_XML="$DOMAIN_HOME/config/config.xml"
NM_PROPS="$DOMAIN_HOME/nodemanager/nodemanager.properties"
_rtc_inst="$(dirname "${RWNETWORK_CONF_RTC:-/x/x}")"
RWBUILDER_CONF="$_rtc_inst/rwbuilder.conf"
SCREEN_PPD="$_rtc_inst/guicommon/tk/admin/PPD/screenprinter.ppd"
AFM_DIR="$_rtc_inst/guicommon/tk/admin/AFM"
AFM_FILES=()
if [ -d "$AFM_DIR" ]; then
    while IFS= read -r _a; do AFM_FILES+=("$_a"); done \
        < <(find "$AFM_DIR" -maxdepth 1 -type f 2>/dev/null | sort)
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
printList "REPORTS_FONT_DIR"    36 "${REPORTS_FONT_DIR}  (${#TTF_FILES[@]} TTF/OTF file(s))"
printf "\n"

# =============================================================================
# Define backup items: "category|source_path|description[|stored_name]"
# stored_name: only when two sources share a file name in one category
# =============================================================================
BACKUP_ITEMS=(
    # Font configuration
    "fonts|${UIFONT_ALI}|Oracle Reports font alias file (uifont.ali)"
    # Reports Server Component (ReportsServerComponent/<instance>/)
    "reports_comp|${RWSERVER_CONF_COMP}|Reports Server Component config (rwserver.conf)"
    "reports_comp|${RWNETWORK_CONF_RSC}|Reports Server Component network config (rwnetwork.conf)"
    # Reports Tools Component (ReportsToolsComponent/<instance>/)
    "reports_tools|${RWNETWORK_CONF_RTC}|Reports Tools Component network config (rwnetwork.conf)"
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
    # Forms instance + application (14-oracle_setup_forms.sh)
    "forms_inst|${WEBUTIL_CFG}|WebUtil configuration – instance (webutil.cfg)"
    "forms_inst|${WEBUTIL_CFG_ALT}|WebUtil configuration – second location (webutil.cfg)|webutil_alt.cfg"
    "forms_wls|${REGISTRY_DAT}|Forms colour schemes (Registry.dat)"
    # Reports tools: rwrun / font metrics for the HTML parameter form (14b-)
    "reports_tools|${RWBUILDER_CONF}|Reports tools runtime config (rwbuilder.conf)"
    "reports_tools|${SCREEN_PPD}|Screen printer PPD (paramform_afm_setup.sh)"
    # Security stores (13-: identity store of the standalone Reports server)
    "security|${JPS_CONFIG}|OPSS configuration (jps-config.xml)"
    "security|${JPS_CONFIG_JSE}|OPSS configuration Java SE (jps-config-jse.xml)"
    # Domain configuration (restore only with the domain stopped)
    "domain|${CONFIG_XML}|WebLogic domain configuration (config.xml)"
    "domain|${NM_PROPS}|Node Manager configuration (nodemanager.properties)"
    # IHateWeblogic
    "ihw|${ENV_CONF}|IHateWeblogic environment configuration (environment.conf)"
)
# ODL logging configuration per server / Reports component (setLogLevel.sh --persist)
for _lx in "$DOMAIN_HOME"/config/fmwconfig/servers/*/logging.xml \
           "$DOMAIN_HOME"/config/fmwconfig/components/Reports*Component/*/logging.xml; do
    [ -f "$_lx" ] || continue
    _ln="$(basename "$(dirname "$_lx")")"
    BACKUP_ITEMS+=("logging|${_lx}|ODL logging configuration ${_ln} (logging.xml)|${_ln}_logging.xml")
done

# =============================================================================
# Section 1: Check source files
# =============================================================================
section "Source Files to Back Up"

# Associate array: track which items can actually be backed up
declare -A ITEM_OK   # src_path → 1 if file exists
FOUND_COUNT=0
MISSING_COUNT=0

for item in "${BACKUP_ITEMS[@]}"; do
    IFS='|' read -r category src_path description _stored <<< "$item"

    if [ -z "$src_path" ]; then
        warn "$(printf "  %-14s  %s  (not found – will be skipped)" "$category" "$description")"
        MISSING_COUNT=$(( MISSING_COUNT + 1 ))
        continue
    fi

    if [ -f "$src_path" ]; then
        sz="$(du -h "$src_path" 2>/dev/null | cut -f1)"
        ok "$(printf "  %-14s  %-35s  %s (%s)" "$category" "${_stored:-$(basename "$src_path")}" "$src_path" "$sz")"
        ITEM_OK["$src_path"]=1
        FOUND_COUNT=$(( FOUND_COUNT + 1 ))
    else
        warn "$(printf "  %-14s  %-35s  NOT FOUND: %s" "$category" "$(basename "$src_path")" "$src_path")"
        MISSING_COUNT=$(( MISSING_COUNT + 1 ))
    fi
done

# TTF fonts summary
if [ "${#TTF_FILES[@]}" -gt 0 ]; then
    _ttf_sz="$(du -sh "$REPORTS_FONT_DIR" 2>/dev/null | cut -f1)"
    ok "$(printf "  %-14s  %-35s  %s (%d files, %s total)" \
        "fonts_ttf" "*.ttf / *.TTF / *.otf" "$REPORTS_FONT_DIR" "${#TTF_FILES[@]}" "${_ttf_sz:--}")"
    for _f in "${TTF_FILES[@]}"; do
        info "$(printf "    %s" "$(basename "$_f")")"
    done
else
    warn "$(printf "  %-14s  %s  (directory empty or not found: %s)" \
        "fonts_ttf" "No font files found" "$REPORTS_FONT_DIR")"
fi

if [ "${#CUSTOM_FONT_FILES[@]}" -gt 0 ]; then
    ok "$(printf "  %-14s  %-35s  %s (%d files)" "fonts_custom" "customer font originals" "$CUSTOM_FONTS_DIR" "${#CUSTOM_FONT_FILES[@]}")"
else
    info "$(printf "  %-14s  %s" "fonts_custom" "no customer fonts in $CUSTOM_FONTS_DIR")"
fi
if [ "${#AFM_FILES[@]}" -gt 0 ]; then
    ok "$(printf "  %-14s  %-35s  %s (%d files)" "reports_afm" "AFM metric files" "$AFM_DIR" "${#AFM_FILES[@]}")"
fi

printf "\n"
info "$FOUND_COUNT config file(s) + ${#TTF_FILES[@]} font file(s) + ${#CUSTOM_FONT_FILES[@]} customer font original(s) + ${#AFM_FILES[@]} AFM file(s) ready to back up, $MISSING_COUNT not found / not configured"
info "Not included on purpose: *.des3 secrets (machine-bound key, re-create via the interview), the own CA in \$ORACLE_BASE/admin/pki (back up offline – 08-SSL/README.md), Nginx config (root)"

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
for cat in fonts fonts_ttf fonts_custom reports_afm reports_comp reports_tools reports_wls fmw forms_wls forms_inst security logging domain ihw; do
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
    IFS='|' read -r category src_path description _stored <<< "$item"

    [ -z "$src_path" ]                       && continue
    [ "${ITEM_OK[$src_path]:-0}" -ne 1 ]     && continue

    fname="${_stored:-$(basename "$src_path")}"
    dst="$BACKUP_DIR/$category/$fname"

    if cp "$src_path" "$dst" 2>/dev/null; then
        ok "$(printf "  Backed up [%-12s]  %s" "$category" "$fname")"
        printf "  %-14s  %-35s  %s\n" "$category" "$fname" "$src_path" >> "$MANIFEST"
    else
        fail "  Failed to copy: $src_path → $dst"
    fi
done

# Copy TTF/OTF fonts
if [ "${#TTF_FILES[@]}" -gt 0 ]; then
    printf "  %-14s  %s\n" "fonts_ttf" "Copying ${#TTF_FILES[@]} font file(s) from $REPORTS_FONT_DIR ..."
    printf "# fonts_ttf  (source: %s)\n" "$REPORTS_FONT_DIR" >> "$MANIFEST"
    _ttf_ok=0
    _ttf_fail=0
    for _f in "${TTF_FILES[@]}"; do
        _fn="$(basename "$_f")"
        if cp "$_f" "$BACKUP_DIR/fonts_ttf/$_fn" 2>/dev/null; then
            printf "  %-14s  %-35s  %s\n" "fonts_ttf" "$_fn" "$_f" >> "$MANIFEST"
            _ttf_ok=$(( _ttf_ok + 1 ))
        else
            fail "  Failed to copy font: $_f"
            _ttf_fail=$(( _ttf_fail + 1 ))
        fi
    done
    ok "  fonts_ttf: ${_ttf_ok} font(s) backed up$( [ "$_ttf_fail" -gt 0 ] && printf ", %s failed" "$_ttf_fail")"
fi

# Copy customer font originals
if [ "${#CUSTOM_FONT_FILES[@]}" -gt 0 ]; then
    printf "# fonts_custom  (source: %s)\n" "$CUSTOM_FONTS_DIR" >> "$MANIFEST"
    _cf_ok=0
    for _f in "${CUSTOM_FONT_FILES[@]}"; do
        _fn="$(basename "$_f")"
        if cp "$_f" "$BACKUP_DIR/fonts_custom/$_fn" 2>/dev/null; then
            printf "  %-14s  %-35s  %s\n" "fonts_custom" "$_fn" "$_f" >> "$MANIFEST"
            _cf_ok=$(( _cf_ok + 1 ))
        else
            fail "  Failed to copy customer font: $_f"
        fi
    done
    ok "  fonts_custom: ${_cf_ok} file(s) backed up"
fi

# Copy AFM font metrics (files without extension, e.g. Helvetica) – HTML
# parameter form / substitute fonts in PDF
if [ "${#AFM_FILES[@]}" -gt 0 ]; then
    printf "# reports_afm  (source: %s)\n" "$AFM_DIR" >> "$MANIFEST"
    _afm_ok=0
    for _f in "${AFM_FILES[@]}"; do
        _fn="$(basename "$_f")"
        if cp "$_f" "$BACKUP_DIR/reports_afm/$_fn" 2>/dev/null; then
            printf "  %-14s  %-35s  %s\n" "reports_afm" "$_fn" "$_f" >> "$MANIFEST"
            _afm_ok=$(( _afm_ok + 1 ))
        else
            fail "  Failed to copy AFM: $_f"
        fi
    done
    ok "  reports_afm: ${_afm_ok} file(s) backed up"
fi

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
