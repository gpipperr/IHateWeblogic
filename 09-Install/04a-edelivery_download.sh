#!/bin/bash
# =============================================================================
# Script   : 04a-edelivery_download.sh
# Purpose  : Download Oracle eDelivery base installers using a Bearer Token.
#            The token is obtained manually from edelivery.oracle.com after
#            login (2FA) by clicking "WGET Options" → "Generate Token".
# Call     : ./09-Install/04a-edelivery_download.sh [--apply]
#            Without --apply: dry-run, shows what would be downloaded.
#            With    --apply: prompts for token + URLs, executes downloads.
# Runs as  : oracle
# Requires : wget, sha256sum, od
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
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"

# --- Source environment.conf --------------------------------------------------
if [ ! -f "$ENV_CONF" ]; then
    printf "\033[31mFATAL\033[0m: environment.conf not found: %s\n" "$ENV_CONF" >&2
    exit 2
fi
# shellcheck source=../environment.conf
source "$ENV_CONF"

# --- Source oracle_software_version.conf --------------------------------------
if [ ! -f "$SW_CONF" ]; then
    printf "\033[31mFATAL\033[0m: oracle_software_version.conf not found: %s\n" "$SW_CONF" >&2
    exit 2
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
for _arg in "$@"; do
    case "$_arg" in
        --apply)   APPLY=true ;;
        --help|-h)
            printf "Usage: %s [--apply]\n\n" "$(basename "$0")"
            printf "  %-20s %s\n" "--apply" "Prompt for Bearer Token and execute downloads"
            printf "\nWithout --apply: dry-run only.\n\n"
            printf "How to get the Bearer Token:\n"
            printf "  1. https://edelivery.oracle.com → login (2FA)\n"
            printf "  2. Select files → WGET Options → Generate Token → Copy\n"
            printf "  Token valid: 1 hour   |   Download URLs valid: 8 hours\n"
            exit 0
            ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$_arg" >&2
            exit 1
            ;;
    esac
done
unset _arg

# =============================================================================
# Helpers
# =============================================================================

# _is_zip  file
# Returns 0 if the file starts with ZIP magic bytes PK (50 4b 03 04).
_is_zip() {
    local file="$1"
    local magic
    magic="$(od -N4 -tx1 -An "$file" 2>/dev/null | tr -d ' \n')"
    [ "$magic" = "504b0304" ]
}

# _verify_sha256  file  expected
# Compares SHA-256 of file against expected (case-insensitive).
# If expected is empty: prints computed hash as WARN for manual recording.
_verify_sha256() {
    local file="$1"
    local expected="${2:-}"
    local computed
    computed="$(sha256sum "$file" 2>/dev/null | awk '{print toupper($1)}')"

    if [ -z "$expected" ]; then
        warn "$(printf "SHA-256 not configured in oracle_software_version.conf")"
        warn "$(printf "  computed: %s" "$computed")"
        info "  → add the value above to FMW_INFRA_SHA256 / FMW_FR_SHA256"
        return 0
    fi

    local expected_uc
    expected_uc="$(printf "%s" "$expected" | tr '[:lower:]' '[:upper:]')"

    if [ "$computed" = "$expected_uc" ]; then
        ok "$(printf "SHA-256 OK  %s" "$computed")"
        return 0
    else
        fail "SHA-256 MISMATCH"
        fail "$(printf "  expected : %s" "$expected_uc")"
        fail "$(printf "  computed : %s" "$computed")"
        return 1
    fi
}

# _download_one  zip_filename  dest_dir  expected_sha256  bearer_token  edel_search
# Handles one file: skip-if-ok, prompt URL, wget, magic check, sha256 verify.
# edel_search: product name to search for on edelivery.oracle.com (shown in prompt).
_download_one() {
    local zip_file="$1"
    local dest_dir="$2"
    local expected_sha256="$3"
    local bearer_token="$4"
    local edel_search="${5:-$zip_file}"
    local dest_path="$dest_dir/$zip_file"

    printLine
    printf "\n" | tee -a "$LOG_FILE"
    ok "$(printf "%-22s %s" "File:" "$zip_file")"
    ok "$(printf "%-22s %s" "Target:" "$dest_path")"
    if [ -n "$expected_sha256" ]; then
        ok "$(printf "%-22s %s" "SHA-256 expected:" "$expected_sha256")"
    else
        warn "$(printf "%-22s %s" "SHA-256:" "not configured")"
    fi

    # --- Already downloaded and valid? ----------------------------------------
    if [ -f "$dest_path" ] && [ -s "$dest_path" ]; then
        if _is_zip "$dest_path"; then
            if [ -z "$expected_sha256" ]; then
                warn "No checksum configured – cannot verify existing file, re-downloading"
            else
                local existing_sum
                existing_sum="$(sha256sum "$dest_path" 2>/dev/null | awk '{print toupper($1)}')"
                if [ "$existing_sum" = "$(printf "%s" "$expected_sha256" | tr '[:lower:]' '[:upper:]')" ]; then
                    ok "Already downloaded and checksum OK – skipping"
                    return 0
                else
                    warn "File exists but checksum mismatch – re-downloading"
                    rm -f "$dest_path"
                fi
            fi
        else
            warn "File exists but is not a valid ZIP – re-downloading"
            rm -f "$dest_path"
        fi
    fi

    # --- Dry-run --------------------------------------------------------------
    if ! $APPLY; then
        warn "Dry-run: would download $zip_file → $dest_dir"
        return 0
    fi

    mkdir -p "$dest_dir"

    # --- Prompt for download URL ----------------------------------------------
    printf "\n"
    info "How to get the download URL for this file:"
    info "  1. Go to: https://edelivery.oracle.com"
    info "  2. Search for:"
    printf "       \033[1m%s\033[0m\n" "$edel_search"
    info "  3. Select the file \033[1m$zip_file\033[0m, click 'WGET Options'"
    info "  4. In the wget script, copy the URL for $zip_file"
    info "     (long URL starting with https://edelivery.oracle.com/osdc/softwareDownload?...)"
    printf "\n  Download URL for %s: " "$zip_file"
    local dl_url
    read -r dl_url
    printf "\n"

    if [ -z "$dl_url" ]; then
        fail "No URL provided – skipping $zip_file"
        return 1
    fi
    printf "  URL accepted (%d chars)\n" "${#dl_url}" | tee -a "$LOG_FILE"

    # --- wget download --------------------------------------------------------
    info "Starting download (resume-capable, progress shown below) …"
    printf "\n"

    wget \
        --header="Authorization: Bearer ${bearer_token}" \
        -c \
        --show-progress \
        --progress=bar:force:noscroll \
        -a "$LOG_FILE" \
        -O "$dest_path" \
        "$dl_url"
    local wget_rc=$?
    printf "\n"

    if [ "$wget_rc" -ne 0 ]; then
        fail "wget failed (exit code $wget_rc) – check log: $LOG_FILE"
        rm -f "$dest_path"
        return 1
    fi

    # --- Magic bytes check ----------------------------------------------------
    if ! _is_zip "$dest_path"; then
        fail "Downloaded file is not a ZIP (HTML error page? Token expired?)"
        fail "  Delete $dest_path and re-run with a fresh token."
        rm -f "$dest_path"
        return 1
    fi
    ok "ZIP magic bytes OK (PK header)"

    # --- SHA-256 verification -------------------------------------------------
    _verify_sha256 "$dest_path" "$expected_sha256" || return 1

    local size
    size="$(du -sh "$dest_path" 2>/dev/null | awk '{print $1}')"
    ok "$(printf "Download complete: %s  (%s)" "$dest_path" "$size")"
    printf "\n" | tee -a "$LOG_FILE"
    return 0
}

# =============================================================================
# MAIN
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – Oracle eDelivery Download\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host    : %s\n" "$(_get_hostname)"              | tee -a "$LOG_FILE"
printf "  Date    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"  | tee -a "$LOG_FILE"
printf "  Apply   : %s\n" "$APPLY"                        | tee -a "$LOG_FILE"
printf "  Log     : %s\n" "$LOG_FILE"                     | tee -a "$LOG_FILE"
printLine

# --- Pre-checks ---------------------------------------------------------------
section "Pre-checks"

[ -n "$PATCH_STORAGE" ] \
    && ok "PATCH_STORAGE = $PATCH_STORAGE" \
    || { fail "PATCH_STORAGE not set in environment.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

[ -n "$FMW_INFRA_ZIP" ] \
    && ok "FMW_INFRA_ZIP = $FMW_INFRA_ZIP" \
    || { fail "FMW_INFRA_ZIP not set in oracle_software_version.conf"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

command -v wget      >/dev/null 2>&1 && ok "wget found"      || { fail "wget not installed";      EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
command -v sha256sum >/dev/null 2>&1 && ok "sha256sum found" || { fail "sha256sum not installed"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
command -v od        >/dev/null 2>&1 && ok "od found"        || { fail "od not installed";        EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

# --- Which files to download? -------------------------------------------------
DOWNLOAD_FR=false
case "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" in
    FORMS_AND_REPORTS|FORMS_ONLY|REPORTS_ONLY)
        [ -n "${FMW_FR_ZIP:-}" ] && DOWNLOAD_FR=true
        ;;
esac

printf "\n" | tee -a "$LOG_FILE"
info "Files to download:"
info "  FMW Infrastructure : $FMW_INFRA_ZIP → $PATCH_STORAGE/wls/"
$DOWNLOAD_FR \
    && info "  Forms & Reports    : $FMW_FR_ZIP → $PATCH_STORAGE/fr/" \
    || info "  Forms & Reports    : skipped (FMW_FR_ZIP not set)"

# --- Dry-run exit -------------------------------------------------------------
if ! $APPLY; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "Dry-run – use --apply to execute downloads."
    info "Ensure you have:"
    info "  - An active edelivery.oracle.com session (login with 2FA)"
    info "  - Bearer Token (WGET Options → Generate Token, valid 1h)"
    info "  - Download URLs per file (from the generated wget script, valid 8h)"
    print_summary
    exit $EXIT_CODE
fi

# --- Bearer Token prompt ------------------------------------------------------
section "Oracle eDelivery Bearer Token"

printf "\n"
printf "  Steps:\n" | tee -a "$LOG_FILE"
printf "    1. Open \033[1mhttps://edelivery.oracle.com\033[0m → log in (2FA)\n"
printf "    2. Search for and add to your cart:\n"
printf "         \033[1m%s\033[0m\n" "${FMW_INFRA_EDEL_SEARCH:-Oracle Fusion Middleware Infrastructure 14.1.2.0.0 for Linux x86-64}"
if $DOWNLOAD_FR && [ -n "${FMW_FR_ZIP:-}" ]; then
    printf "         \033[1m%s\033[0m\n" "${FMW_FR_EDEL_SEARCH:-Oracle Forms and Reports 14.1.2.0.0}"
fi
printf "    3. Proceed to download page → click \033[1mWGET Options\033[0m\n"
printf "    4. Click \033[1mGenerate Token\033[0m → \033[1mCopy\033[0m\n"
printf "    5. Paste the token below (hidden input, valid 1 hour)\n\n"

BEARER_TOKEN=""
printf "  Bearer Token: "
read -rs BEARER_TOKEN
printf "\n"

if [ -z "$BEARER_TOKEN" ]; then
    fail "No token provided"
    EXIT_CODE=2
    print_summary
    exit $EXIT_CODE
fi
ok "Bearer Token received (${#BEARER_TOKEN} characters)"

# --- Execute downloads --------------------------------------------------------
section "Downloads"

DOWNLOAD_ERRORS=0

_download_one "$FMW_INFRA_ZIP" \
    "$PATCH_STORAGE/wls" \
    "${FMW_INFRA_SHA256:-}" \
    "$BEARER_TOKEN" \
    "${FMW_INFRA_EDEL_SEARCH:-Oracle Fusion Middleware Infrastructure 14.1.2.0.0 for Linux x86-64}" \
    || DOWNLOAD_ERRORS=$(( DOWNLOAD_ERRORS + 1 ))

if $DOWNLOAD_FR && [ -n "${FMW_FR_ZIP:-}" ]; then
    _download_one "$FMW_FR_ZIP" \
        "$PATCH_STORAGE/fr" \
        "${FMW_FR_SHA256:-}" \
        "$BEARER_TOKEN" \
        "${FMW_FR_EDEL_SEARCH:-Oracle Forms and Reports 14.1.2.0.0}" \
        || DOWNLOAD_ERRORS=$(( DOWNLOAD_ERRORS + 1 ))
fi

# Clear token from memory
BEARER_TOKEN="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
unset BEARER_TOKEN

if [ "$DOWNLOAD_ERRORS" -gt 0 ]; then
    fail "$DOWNLOAD_ERRORS download(s) failed – check: $LOG_FILE"
    EXIT_CODE=1
fi

# =============================================================================
print_summary
exit $EXIT_CODE
