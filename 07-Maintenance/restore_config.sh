#!/bin/bash
# =============================================================================
# Script   : restore_config.sh
# Purpose  : List available config backups (created by backup_config.sh) and
#            restore a selected backup set back to the original locations.
#            Before restoring, the current state is backed up automatically
#            with a "pre-restore" tag.
# Call     : ./restore_config.sh [--apply]
# Requires : cp, find
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
CATEGORIES=""      # empty = all categories of the set
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY_MODE=true; shift ;;
        --category) CATEGORIES="$2"; shift 2 ;;
        --help)
            printf "Usage: %s [--apply] [--category LIST]\n" "$(basename "$0")"
            printf "  Default: list available backups and show manifest\n"
            printf "  --apply: interactively select and restore a backup set\n"
            printf "  --category LIST: only these categories, comma separated\n"
            printf "      (fonts,fonts_ttf,fonts_custom,reports_afm,reports_comp,reports_tools,reports_wls,\n"
            printf "       fmw,forms_wls,forms_inst,security,logging,domain,ihw)\n"
            exit 0
            ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 2 ;;
    esac
done

# _cat_selected CATEGORY – 0 if CATEGORY is part of --category (or no filter)
_cat_selected() { [ -z "$CATEGORIES" ] || [[ ",$CATEGORIES," == *",$1,"* ]]; }

# _dest_allowed PATH – restore only below the known homes (a manifest is a
# plain text file – never write to arbitrary paths from it)
_dest_allowed() {
    local d
    for d in "${DOMAIN_HOME:-}" "${ORACLE_HOME:-${FMW_HOME:-}}" "$ROOT_DIR" "${REPORTS_FONT_DIR:-}"; do
        [ -n "$d" ] && [[ "$1" == "$d"/* ]] && [[ "$1" != *"/../"* ]] && return 0
    done
    return 1
}

# Pre-restore backup and restored files: owner only
umask 077

# =============================================================================
# Variables
# =============================================================================
BACKUP_BASE="$SCRIPT_DIR/ConfigBackup"

# =============================================================================
# Banner
# =============================================================================
printLine
printf "\n\033[1mIHateWeblogic – Configuration Restore\033[0m\n"
printf "Host    : %s\n" "$(_get_hostname)"
printf "Date    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "Mode    : %s\n" "$( $APPLY_MODE && echo 'APPLY (will restore selected backup)' || echo 'DRY-RUN (list backups only)')"
printf "Log     : %s\n\n" "$LOG_FILE"

# =============================================================================
# Section 1: Find available backups
# =============================================================================
section "Available Backups"

if [ ! -d "$BACKUP_BASE" ]; then
    fail "Backup directory not found: $BACKUP_BASE"
    info "  Run backup_config.sh --apply first"
    print_summary
    exit $EXIT_CODE
fi

BACKUP_DIRS=()
while IFS= read -r d; do
    BACKUP_DIRS+=("$d")
done < <(find "$BACKUP_BASE" -mindepth 2 -maxdepth 2 -name manifest.txt -printf '%T@ %h\n' 2>/dev/null \
          | sort -rn | cut -d' ' -f2-)
# Only sets with a manifest.txt (backup_config.sh, pre-restore), newest first.
# Other directories in ConfigBackup/ come from single scripts (e.g.
# domain_jdk_path.sh jdk_path_<ts>/) and are restored by hand.
_other="$(find "$BACKUP_BASE" -mindepth 1 -maxdepth 1 -type d ! -exec test -f '{}/manifest.txt' ';' -printf '%f ' 2>/dev/null)"
[ -n "$_other" ] && info "Without manifest (not restorable here): $_other"

if [ "${#BACKUP_DIRS[@]}" -eq 0 ]; then
    fail "No backup sets found in $BACKUP_BASE"
    info "  Run backup_config.sh --apply to create one"
    print_summary
    exit $EXIT_CODE
fi

ok "${#BACKUP_DIRS[@]} backup set(s) found:"
printf "\n"

# Display each backup with file count and manifest summary
BACKUP_LABELS=()
for bdir in "${BACKUP_DIRS[@]}"; do
    label="$(basename "$bdir")"
    fc="$(find "$bdir" -type f ! -name "manifest.txt" 2>/dev/null | wc -l)"
    BACKUP_LABELS+=("$label  ($fc files)")
    printf "  %s  (%d files)\n" "$label" "$fc" | tee -a "${LOG_FILE:-/dev/null}"
done

# =============================================================================
# Section 2: Show manifests (dry-run) or select backup (apply)
# =============================================================================
if ! $APPLY_MODE; then
    section "Manifest Contents"

    for bdir in "${BACKUP_DIRS[@]}"; do
        label="$(basename "$bdir")"
        manifest="$bdir/manifest.txt"
        printf "\n"
        info "-- $label --"
        if [ -f "$manifest" ]; then
            while IFS= read -r line; do
                printf "  %s\n" "$line" | tee -a "${LOG_FILE:-/dev/null}"
            done < "$manifest"
        else
            warn "  No manifest.txt found in $bdir"
        fi
    done

    printf "\n"
    info "Run with --apply to select and restore a backup"
    printLine
    print_summary
    exit $EXIT_CODE
fi

# =============================================================================
# Section 3: Select backup to restore (interactive)
# =============================================================================
section "Select Backup to Restore"

if [ "${#BACKUP_DIRS[@]}" -eq 1 ]; then
    # Only one backup available – use it directly
    SELECTED_DIR="${BACKUP_DIRS[0]}"
    info "Only one backup available – using: $(basename "$SELECTED_DIR")"
else
    readSelection \
        "Which backup set should be restored?" \
        1 \
        "${BACKUP_LABELS[@]}"
    SELECTED_DIR="${BACKUP_DIRS[$((SELECTION_IDX - 1))]}"
fi

SELECTED_LABEL="$(basename "$SELECTED_DIR")"
ok "Selected: $SELECTED_LABEL"

# =============================================================================
# Section 4: Show manifest of selected backup
# =============================================================================
section "Manifest: $SELECTED_LABEL"

MANIFEST="$SELECTED_DIR/manifest.txt"

if [ ! -f "$MANIFEST" ]; then
    fail "manifest.txt not found in $SELECTED_DIR"
    info "  Backup may be incomplete – aborting"
    print_summary
    exit $EXIT_CODE
fi

while IFS= read -r line; do
    printf "  %s\n" "$line" | tee -a "${LOG_FILE:-/dev/null}"
done < "$MANIFEST"
printf "\n"

# =============================================================================
# Section 5: Parse manifest – build restore list
# =============================================================================
# Manifest data lines format: "  category  filename  original_path"
# (lines starting with # are comments)

declare -A RESTORE_MAP   # backup_file_path → original_path
declare -A RESTORE_CAT   # backup_file_path → category
declare -A RESTORED_CATS # category → 1
RESTORE_COUNT=0

while IFS= read -r line; do
    # Skip comment lines and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [ -z "${line// /}" ]            && continue

    # Parse: "  category  filename  original_path" (path = rest of the line)
    read -r category fname orig_path <<< "$line"

    [ -z "$category" ] || [ -z "$fname" ] || [ -z "$orig_path" ] && continue
    _cat_selected "$category" || continue
    if ! _dest_allowed "$orig_path"; then
        warn "Destination outside DOMAIN_HOME / ORACLE_HOME / repository – skipped: $orig_path"
        continue
    fi

    backup_file="$SELECTED_DIR/$category/$fname"

    if [ ! -f "$backup_file" ]; then
        warn "Backup file not found (manifest entry skipped): $backup_file"
        continue
    fi

    RESTORE_MAP["$backup_file"]="$orig_path"
    RESTORE_CAT["$backup_file"]="$category"
    RESTORED_CATS[$category]=1
    RESTORE_COUNT=$(( RESTORE_COUNT + 1 ))

done < "$MANIFEST"

# domain / security files (config.xml, jps-config*.xml, nodemanager.properties)
# must not be replaced under a running domain – WebLogic rewrites them
if [ -n "${RESTORED_CATS[domain]:-}${RESTORED_CATS[security]:-}" ] && $APPLY_MODE && ! check_wls_stopped; then
    fail "Categories domain/security selected while WebLogic runs – stop the domain first (01-Run/startStop.sh stop-all --apply)"
    info "  or restore the other categories only: --category fonts,reports_comp,..."
    printf '%s' "$WLS_RUNNING_COMPONENTS" | sed 's/^/  - /' | tee -a "${LOG_FILE:-/dev/null}"
    print_summary
    exit 2
fi
[ -n "${RESTORED_CATS[ihw]:-}" ] && \
    warn "Category ihw restores an older environment.conf – variables added since that backup are lost (diff it first)"

if [ "$RESTORE_COUNT" -eq 0 ]; then
    fail "No restorable files found in manifest"
    print_summary
    exit $EXIT_CODE
fi

info "$RESTORE_COUNT file(s) to restore:"
for bfile in "${!RESTORE_MAP[@]}"; do
    info "  $(basename "$bfile")  →  ${RESTORE_MAP[$bfile]}"
done

# =============================================================================
# Section 6: Confirm
# =============================================================================
section "Confirm Restore"

printf "\n"
warn "This will OVERWRITE the current configuration files with the backup."
printf "\n"

if ! askYesNo "Proceed with restore from $SELECTED_LABEL?" "n"; then
    info "Restore cancelled by user"
    printLine
    print_summary
    exit 0
fi

# =============================================================================
# Section 7: Pre-restore backup of current state
# =============================================================================
section "Pre-Restore Backup of Current State"

PRE_TS="$(date '+%Y%m%d_%H%M')_pre_restore"
PRE_DIR="$BACKUP_BASE/$PRE_TS"

info "Saving current state to: $PRE_DIR"

for cat in "${!RESTORED_CATS[@]}"; do
    mkdir -p "$PRE_DIR/$cat" 2>/dev/null
done

PRE_MANIFEST="$PRE_DIR/manifest.txt"
{
    printf "# IHateWeblogic Config Backup Manifest (pre-restore)\n"
    printf "# Host     : %s\n" "$(_get_hostname)"
    printf "# Created  : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# Backup   : %s\n" "$PRE_DIR"
    printf "# Restoring from: %s\n" "$SELECTED_LABEL"
    printf "# ---\n"
    printf "# %-10s  %-35s  %s\n" "Category" "Filename" "Original Path"
} > "$PRE_MANIFEST"

# Re-use manifest entries to find which files to pre-backup
while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [ -z "${line// /}" ]            && continue

    read -r category fname orig_path <<< "$line"
    [ -z "$orig_path" ] && continue
    [ -n "${RESTORE_MAP[$SELECTED_DIR/$category/$fname]:-}" ] || continue

    if [ -f "$orig_path" ]; then
        if cp "$orig_path" "$PRE_DIR/$category/$fname" 2>/dev/null; then
            ok "  Pre-backup: $fname"
            printf "  %-10s  %-35s  %s\n" "$category" "$fname" "$orig_path" >> "$PRE_MANIFEST"
        else
            warn "  Pre-backup failed for: $orig_path"
        fi
    else
        info "  Pre-backup skip (not found): $orig_path"
    fi
done < "$MANIFEST"

ok "Pre-restore backup saved: $PRE_DIR"

# =============================================================================
# Section 8: Restore files
# =============================================================================
section "Restoring Files"

RESTORED=0
FAILED=0

for bfile in "${!RESTORE_MAP[@]}"; do
    orig_path="${RESTORE_MAP[$bfile]}"
    fname="$(basename "$bfile")"

    # Ensure destination directory exists
    dst_dir="$(dirname "$orig_path")"
    if [ ! -d "$dst_dir" ]; then
        warn "  Destination directory does not exist: $dst_dir"
        warn "  Skipping: $fname"
        FAILED=$(( FAILED + 1 ))
        continue
    fi

    if cp "$bfile" "$orig_path" 2>/dev/null; then
        ok "  Restored: $fname → $orig_path"
        RESTORED=$(( RESTORED + 1 ))
    else
        fail "  Failed to restore: $bfile → $orig_path"
        FAILED=$(( FAILED + 1 ))
    fi
done

printf "\n"
printf "  Restored : %d\n" "$RESTORED"
printf "  Failed   : %d\n" "$FAILED"

# =============================================================================
# Section 9: Next Steps
# =============================================================================
section "Next Steps"

info "Configuration restored from: $SELECTED_LABEL"
if [ "$FAILED" -gt 0 ]; then
    warn "  $FAILED file(s) could not be restored – check log: $LOG_FILE"
fi
info "  Restored categories: $(printf '%s ' "${!RESTORED_CATS[@]}")"
_rs="${REPORTS_SERVER_NAME:-repserver01}"
_restart() { info "    ./01-Run/startStop.sh stop $1 --apply && ./01-Run/startStop.sh start $1 --apply"; }
if [ -n "${RESTORED_CATS[fonts_ttf]:-}${RESTORED_CATS[fonts_custom]:-}" ]; then
    info "  Fonts: ./04-ReportsFonts/deploy_fonts.sh --apply (customer originals) + ./04-ReportsFonts/font_cache_reset.sh --apply"
fi
if [ -n "${RESTORED_CATS[fonts]:-}${RESTORED_CATS[fonts_ttf]:-}${RESTORED_CATS[reports_afm]:-}${RESTORED_CATS[reports_comp]:-}${RESTORED_CATS[reports_tools]:-}" ]; then
    info "  Reports server (reads its config + fonts at start):"; _restart "$_rs"
fi
[ -n "${RESTORED_CATS[reports_wls]:-}${RESTORED_CATS[fmw]:-}" ] && { info "  Reports servlet:"; _restart "${WLS_REPORTS_SERVER:-WLS_REPORTS}"; }
[ -n "${RESTORED_CATS[forms_wls]:-}${RESTORED_CATS[forms_inst]:-}" ] && { info "  Forms:"; _restart "${WLS_FORMS_SERVER:-WLS_FORMS}"; }
[ -n "${RESTORED_CATS[domain]:-}${RESTORED_CATS[security]:-}${RESTORED_CATS[logging]:-}" ] && \
    info "  Domain / security / logging: ./01-Run/startStop.sh start-all --apply (domain was stopped)"

# =============================================================================
# Summary
# =============================================================================
printLine
print_summary
exit $EXIT_CODE
