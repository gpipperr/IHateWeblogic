#!/bin/bash
# =============================================================================
# Script   : 04a-edelivery_download.sh
# Purpose  : Prepare Oracle eDelivery base installers in PATCH_STORAGE.
#            Primary path: creates target directories, asks user to place the
#            ZIP files manually, then verifies ZIP integrity and SHA-256.
#            Alternative: automated wget download using a Bearer Token
#            obtained from edelivery.oracle.com (WGET Options → Generate Token).
# Call     : ./09-Install/04a-edelivery_download.sh [--apply] [--download]
#            Without --apply   : dry-run, shows expected paths and checksums.
#            With    --apply   : create dirs, prompt placement, verify.
#            With    --download: use Bearer Token wget instead of manual copy.
# Runs as  : oracle
# Requires : wget (only for --download), sha256sum, od
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/docs/04-oracle_pre_download.md
#            09-Install/oracle_software_version.conf
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"
SW_CONF="$SCRIPT_DIR/oracle_software_version.conf"

# --- Source library -----------------------------------------------------------
if [ ! -f "$LIB" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB" >&2; exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"

# --- Source environment.conf --------------------------------------------------
if [ ! -f "$ENV_CONF" ]; then
    printf "\033[31mFATAL\033[0m: environment.conf not found: %s\n" "$ENV_CONF" >&2; exit 2
fi
# shellcheck source=../environment.conf
source "$ENV_CONF"

# --- Source oracle_software_version.conf --------------------------------------
if [ ! -f "$SW_CONF" ]; then
    printf "\033[31mFATAL\033[0m: oracle_software_version.conf not found: %s\n" "$SW_CONF" >&2; exit 2
fi
# shellcheck source=./oracle_software_version.conf
source "$SW_CONF"

# --- Bootstrap log ------------------------------------------------------------
LOG_BOOT_DIR="${DIAG_LOG_DIR:-$ROOT_DIR/log/$(date +%Y%m%d)}"
mkdir -p "$LOG_BOOT_DIR"
LOG_FILE="$LOG_BOOT_DIR/edelivery_download_$(date +%H%M%S).log"
{
    printf "# 04a-edelivery_download.sh log\n"
    printf "# Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# Host    : %s\n" "$(_get_hostname)"
} > "$LOG_FILE"

# --- Arguments ----------------------------------------------------------------
APPLY=false
DOWNLOAD_MODE=false
for _arg in "$@"; do
    case "$_arg" in
        --apply)    APPLY=true ;;
        --download) DOWNLOAD_MODE=true ;;
        --help|-h)
            printf "Usage: %s [--apply] [--download]\n\n" "$(basename "$0")"
            printf "  %-20s %s\n" "--apply"    "Create dirs, verify placed files (or run --download)"
            printf "  %-20s %s\n" "--download" "Download via Bearer Token instead of manual placement"
            printf "\nWithout --apply: dry-run only.\n\n"
            printf "Bearer Token: edelivery.oracle.com → select files → WGET Options → Generate Token\n"
            exit 0 ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$_arg" >&2; exit 1 ;;
    esac
done
unset _arg

# =============================================================================
# Helpers
# =============================================================================

# _is_zip  file  – returns 0 if file starts with ZIP magic bytes PK (50 4b 03 04)
_is_zip() {
    local magic
    magic="$(od -N4 -tx1 -An "$1" 2>/dev/null | tr -d ' \n')"
    [ "$magic" = "504b0304" ]
}

# _verify_sha256  file  expected
# Returns 0 if checksums match. If expected is empty: prints computed hash as WARN.
_verify_sha256() {
    local file="$1" expected="${2:-}"
    local computed
    computed="$(sha256sum "$file" 2>/dev/null | awk '{print toupper($1)}')"

    if [ -z "$expected" ]; then
        warn "SHA-256 not configured – computed: $computed"
        info "  → set FMW_INFRA_SHA256 / FMW_FR_SHA256 in oracle_software_version.conf"
        return 0
    fi

    local expected_uc
    expected_uc="$(printf "%s" "$expected" | tr '[:lower:]' '[:upper:]')"

    if [ "$computed" = "$expected_uc" ]; then
        ok "SHA-256 OK  $computed"
    else
        fail "SHA-256 MISMATCH"
        fail "  expected : $expected_uc"
        fail "  computed : $computed"
        return 1
    fi
}

# _check_file  dest_path  expected_sha256
# Returns 0 if file is present, is a ZIP, and checksum matches.
_check_file() {
    local dest_path="$1" expected_sha256="$2"
    [ -f "$dest_path" ] && [ -s "$dest_path" ] || return 1
    _is_zip "$dest_path"                        || return 1
    _verify_sha256 "$dest_path" "$expected_sha256" 2>/dev/null
}

# _wget_download  dest_path  bearer_token  dl_url
# Download one file via wget with Bearer Token authentication.
_wget_download() {
    local dest_path="$1" bearer_token="$2" dl_url="$3"

    info "Starting wget download (resume-capable) …"
    printf "\n"
    wget \
        --header="Authorization: Bearer ${bearer_token}" \
        -c \
        --show-progress \
        --progress=bar:force:noscroll \
        -a "$LOG_FILE" \
        -O "$dest_path" \
        "$dl_url"
    local rc=$?
    printf "\n"

    [ "$rc" -ne 0 ] && { fail "wget failed (exit code $rc)"; rm -f "$dest_path"; return 1; }

    _is_zip "$dest_path" \
        || { fail "Downloaded file is not a ZIP (HTML error page? Token expired?)"; rm -f "$dest_path"; return 1; }

    ok "ZIP magic bytes OK"
    return 0
}

# =============================================================================
# _install_one  zip_file  dest_dir  expected_sha256  edel_search  bearer_token
# Full install flow for one ZIP: skip-if-ok, manual or wget, verify.
# =============================================================================
_install_one() {
    local zip_file="$1"
    local dest_dir="$2"
    local expected_sha256="$3"
    local edel_search="$4"
    local bearer_token="${5:-}"
    local dest_path="$dest_dir/$zip_file"

    printLine
    printf "\n" | tee -a "$LOG_FILE"
    ok "$(printf "%-20s %s" "File:"    "$zip_file")"
    ok "$(printf "%-20s %s" "Target:"  "$dest_path")"
    if [ -n "$expected_sha256" ]; then
        ok "$(printf "%-20s %s" "SHA-256:" "$expected_sha256")"
    else
        warn "$(printf "%-20s %s" "SHA-256:" "not configured in oracle_software_version.conf")"
    fi

    # --- Already present and valid? -------------------------------------------
    if _check_file "$dest_path" "$expected_sha256"; then
        ok "Already present and checksum OK – skipping"
        return 0
    fi
    [ -f "$dest_path" ] && warn "File present but invalid – will replace"

    # --- Dry-run --------------------------------------------------------------
    if ! $APPLY; then
        warn "Dry-run: $dest_path not yet present"
        return 0
    fi

    mkdir -p "$dest_dir"
    ok "Target directory ready: $dest_dir"

    # --- Download mode: wget via Bearer Token ---------------------------------
    if $DOWNLOAD_MODE; then
        printf "\n"
        info "Download URL for $zip_file:"
        info "  1. Go to: https://edelivery.oracle.com"
        info "  2. Search for:  $(printf "\033[1m%s\033[0m" "$edel_search")"
        info "  3. Select $zip_file → WGET Options → copy the URL for this file"
        printf "\n  URL for %s: " "$zip_file"
        local dl_url
        read -r dl_url
        printf "\n"
        [ -z "$dl_url" ] && { fail "No URL provided – skipping $zip_file"; return 1; }

        _wget_download "$dest_path" "$bearer_token" "$dl_url" || return 1

    # --- Manual placement path ------------------------------------------------
    else
        printf "\n"
        info "Please place the installer here:"
        printf "    \033[1m%s\033[0m\n" "$dest_path"
        info "Download from Oracle Software Delivery Cloud (eDelivery):"
        info "  https://edelivery.oracle.com  →  search for:"
        printf "    \033[1m%s\033[0m\n" "$edel_search"
        printf "\n  Press Enter when the file has been placed, or type 's' to skip: "
        local ans
        read -r ans
        printf "\n"

        if [[ "$ans" =~ ^[Ss] ]]; then
            warn "Skipped: $zip_file"
            return 0
        fi
    fi

    # --- Verification ---------------------------------------------------------
    section "Verifying $zip_file"

    if [ ! -f "$dest_path" ] || [ ! -s "$dest_path" ]; then
        fail "File not found: $dest_path"
        return 1
    fi

    if ! _is_zip "$dest_path"; then
        fail "Not a valid ZIP file: $dest_path"
        fail "  (HTML page? Wrong file placed? Token expired during download?)"
        return 1
    fi
    ok "ZIP magic bytes OK"

    _verify_sha256 "$dest_path" "$expected_sha256" || return 1

    local size
    size="$(du -sh "$dest_path" 2>/dev/null | awk '{print $1}')"
    ok "$(printf "%-20s %s  (%s)" "Verified:" "$dest_path" "$size")"
    return 0
}

# =============================================================================
# MAIN
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – eDelivery Installer Preparation\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host     : %s\n" "$(_get_hostname)"              | tee -a "$LOG_FILE"
printf "  Date     : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"  | tee -a "$LOG_FILE"
printf "  Apply    : %s\n" "$APPLY"                        | tee -a "$LOG_FILE"
printf "  Download : %s\n" "$DOWNLOAD_MODE"                | tee -a "$LOG_FILE"
printf "  Log      : %s\n" "$LOG_FILE"                     | tee -a "$LOG_FILE"
printLine

# --- Pre-checks ---------------------------------------------------------------
section "Pre-checks"

[ -n "$PATCH_STORAGE" ] \
    && ok "PATCH_STORAGE = $PATCH_STORAGE" \
    || { fail "PATCH_STORAGE not set in environment.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -n "$FMW_INFRA_ZIP" ] \
    && ok "FMW_INFRA_ZIP = $FMW_INFRA_ZIP" \
    || { fail "FMW_INFRA_ZIP not set in oracle_software_version.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

if $DOWNLOAD_MODE; then
    command -v wget >/dev/null 2>&1 \
        && ok "wget found" \
        || { fail "wget not installed (required for --download mode)"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
fi

command -v sha256sum >/dev/null 2>&1 && ok "sha256sum found" \
    || { fail "sha256sum not installed"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
command -v od >/dev/null 2>&1 && ok "od found" \
    || { fail "od not installed"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# --- Which files? -------------------------------------------------------------
DOWNLOAD_FR=false
case "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" in
    FORMS_AND_REPORTS|FORMS_ONLY|REPORTS_ONLY)
        [ -n "${FMW_FR_ZIP:-}" ] && DOWNLOAD_FR=true ;;
esac

printf "\n" | tee -a "$LOG_FILE"
info "Files to prepare:"
info "  FMW Infrastructure : $FMW_INFRA_ZIP → $PATCH_STORAGE/wls/"
$DOWNLOAD_FR \
    && info "  Forms & Reports    : $FMW_FR_ZIP → $PATCH_STORAGE/fr/" \
    || info "  Forms & Reports    : skipped (FMW_FR_ZIP not set)"

# --- Dry-run exit -------------------------------------------------------------
if ! $APPLY; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "Dry-run – use --apply to create directories and verify files."
    $DOWNLOAD_MODE \
        && info "Download mode (--download): will prompt for Bearer Token and URLs" \
        || info "Manual mode: will prompt to place files in target directories"
    print_summary
    exit $EXIT_CODE
fi

# --- Bearer Token (only in download mode) -------------------------------------
BEARER_TOKEN=""
if $DOWNLOAD_MODE; then
    section "Oracle eDelivery Bearer Token"
    printf "\n"
    printf "  Steps:\n"
    printf "    1. Open \033[1mhttps://edelivery.oracle.com\033[0m → log in (2FA)\n"
    printf "    2. Search for and add to cart:\n"
    printf "         \033[1m%s\033[0m\n" "${FMW_INFRA_EDEL_SEARCH:-Oracle Fusion Middleware Infrastructure 14.1.2.0.0 for Linux x86-64}"
    $DOWNLOAD_FR && printf "         \033[1m%s\033[0m\n" "${FMW_FR_EDEL_SEARCH:-Oracle Forms and Reports 14.1.2.0.0}"
    printf "    3. Click \033[1mWGET Options\033[0m → \033[1mGenerate Token\033[0m → Copy\n"
    printf "    Token valid: 1 hour   |   Download URLs valid: 8 hours\n\n"
    printf "  Bearer Token: "
    read -rs BEARER_TOKEN
    printf "\n"
    [ -z "$BEARER_TOKEN" ] && { fail "No token provided"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
    ok "Bearer Token received (${#BEARER_TOKEN} characters)"
fi

# --- Process files ------------------------------------------------------------
section "Installer Files"

ERRORS=0

_install_one "$FMW_INFRA_ZIP" \
    "$PATCH_STORAGE/wls" \
    "${FMW_INFRA_SHA256:-}" \
    "${FMW_INFRA_EDEL_SEARCH:-Oracle Fusion Middleware Infrastructure 14.1.2.0.0 for Linux x86-64}" \
    "$BEARER_TOKEN" \
    || ERRORS=$(( ERRORS + 1 ))

if $DOWNLOAD_FR && [ -n "${FMW_FR_ZIP:-}" ]; then
    _install_one "$FMW_FR_ZIP" \
        "$PATCH_STORAGE/fr" \
        "${FMW_FR_SHA256:-}" \
        "${FMW_FR_EDEL_SEARCH:-Oracle Forms and Reports 14.1.2.0.0}" \
        "$BEARER_TOKEN" \
        || ERRORS=$(( ERRORS + 1 ))
fi

# Clear token from memory
BEARER_TOKEN="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
unset BEARER_TOKEN

[ "$ERRORS" -gt 0 ] && { fail "$ERRORS file(s) failed – check: $LOG_FILE"; EXIT_CODE=1; }

# =============================================================================
print_summary
exit $EXIT_CODE
