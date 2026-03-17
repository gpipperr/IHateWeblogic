#!/bin/bash
# =============================================================================
# Script   : 04-oracle_pre_download.sh
# Purpose  : Download FMW 14.1.2 base installers and MOS patches into
#            PATCH_STORAGE.
#            eDelivery path : manual file placement (primary) or Bearer Token wget.
#            MOS path       : getMOSPatch.jar for OPatch + post-install patches.
# Call     : ./09-Install/04-oracle_pre_download.sh [--apply] [--wget] [--mos|--all]
#            (none)          – dry-run: show expected paths and checksums
#            --apply         – eDelivery: create dirs, prompt placement, verify
#            --apply --wget  – eDelivery via Bearer Token wget (no manual copy)
#            --apply --mos   – eDelivery + getMOSPatch (OPatch + patches)
#            --apply --all   – alias for --apply --mos
#            --apply --wget --mos – Bearer Token wget + getMOSPatch
# Runs as  : oracle
# Requires : sha256sum, od, java (--mos), wget (--wget)
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
MOS_SEC_FILE="$ROOT_DIR/mos_sec.conf.des3"

# --- Source library -----------------------------------------------------------
if [ ! -f "$LIB" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB" >&2; exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"

# --- Source environment.conf --------------------------------------------------
if [ ! -f "$ENV_CONF" ]; then
    printf "\033[31mFATAL\033[0m: environment.conf not found: %s\n" "$ENV_CONF" >&2
    printf "  Run first: 00-Setup/env_check.sh --apply\n" >&2; exit 2
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
LOG_FILE="$LOG_BOOT_DIR/oracle_pre_download_$(date +%H%M%S).log"
{
    printf "# 04-oracle_pre_download.sh log\n"
    printf "# Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# Host    : %s\n" "$(_get_hostname)"
} > "$LOG_FILE"

# --- Arguments ----------------------------------------------------------------
APPLY=false
WGET_MODE=false
MOS_MODE=false

_usage() {
    printf "Usage: %s [--apply] [--wget] [--mos|--all] [--help]\n\n" "$(basename "$0")"
    printf "  %-22s %s\n" "(none)"        "Dry-run: show expected paths and checksums"
    printf "  %-22s %s\n" "--apply"       "Create dirs, prompt placement, verify (eDelivery)"
    printf "  %-22s %s\n" "--apply --wget" "Download via Bearer Token instead of manual copy"
    printf "  %-22s %s\n" "--apply --mos"  "eDelivery + getMOSPatch (OPatch + patches)"
    printf "  %-22s %s\n" "--apply --all"  "Alias for --apply --mos"
    printf "\nBearer Token: edelivery.oracle.com → WGET Options → Generate Token (valid 1 h)\n"
    exit 0
}

for _arg in "$@"; do
    case "$_arg" in
        --apply)    APPLY=true ;;
        --wget)     WGET_MODE=true ;;
        --mos|--all) MOS_MODE=true ;;
        --help|-h)  _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$_arg" >&2; exit 1 ;;
    esac
done
unset _arg

# =============================================================================
# Helpers – eDelivery
# =============================================================================

# _is_zip  file  – returns 0 if file starts with ZIP magic bytes PK (50 4b 03 04)
_is_zip() {
    local magic
    magic="$(od -N4 -tx1 -An "$1" 2>/dev/null | tr -d ' \n')"
    [ "$magic" = "504b0304" ]
}

# _verify_sha256  file  expected
# Returns 0 if checksums match.  If expected is empty: prints computed hash as WARN.
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

# _install_one  zip_file  dest_dir  expected_sha256  edel_search  [bearer_token]
# Full install flow for one ZIP: skip-if-ok, manual or wget, verify.
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
    if $WGET_MODE; then
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
# Helpers – MOS / getMOSPatch
# =============================================================================

# _load_mos_password
# Decrypts mos_sec.conf.des3 (written by 01-setup-interview.sh).
# Sets MOS_PASS on success; returns 1 on failure.
_load_mos_password() {
    if [ ! -f "$MOS_SEC_FILE" ]; then
        fail "MOS password file not found: $MOS_SEC_FILE"
        info "  Run first: 09-Install/01-setup-interview.sh --apply"
        return 1
    fi

    local sys_id
    sys_id="$(_get_system_identifier)"
    if [ -z "$sys_id" ]; then
        fail "Cannot determine system identifier for decryption"
        return 1
    fi

    local plaintext
    plaintext="$(openssl des3 -pbkdf2 -d -salt \
        -in "$MOS_SEC_FILE" -pass pass:"${sys_id}" 2>/dev/null)"
    local rc=$?

    if [ "$rc" -ne 0 ] || [ -z "$plaintext" ]; then
        fail "Cannot decrypt MOS password (rc=$rc) – wrong machine or corrupted file?"
        return 1
    fi

    MOS_PASS="$plaintext"
    ok "MOS password decrypted (${#MOS_PASS} characters)"
    return 0
}

# _mos_download_one  patch_nr  dest_dir  [regexp]
# Download one patch or OPatch via getMOSPatch.jar.
# regexp (optional): passed as regexp= to getMOSPatch to restrict which files are downloaded.
_mos_download_one() {
    local patch_nr="$1"
    local dest_dir="$2"
    local gmp_regexp="${3:-}"

    if ls "$dest_dir"/p"${patch_nr}"_*.zip "$dest_dir"/p"${patch_nr}"*.zip \
           "$dest_dir"/*.zip 2>/dev/null | grep -q .; then
        ok "$(printf "%-12s %s" "Patch $patch_nr:" "already present in $dest_dir – skipping")"
        return 0
    fi

    if ! $APPLY; then
        warn "Dry-run: patch $patch_nr not yet in $dest_dir"
        return 0
    fi

    mkdir -p "$dest_dir"
    ok "$(printf "%-12s %s" "Patch $patch_nr:" "downloading to $dest_dir")"

    # getMOSPatch reads .getMOSPatch.cfg from the current working directory
    cp "$PATCH_STORAGE/bin/.getMOSPatch.cfg" "$dest_dir/.getMOSPatch.cfg" 2>/dev/null

    (
        cd "$dest_dir" || exit 1
        if [ -n "$gmp_regexp" ]; then
            java -jar "$PATCH_STORAGE/bin/getMOSPatch.jar" \
                MOSUser="$MOS_USER" \
                MOSPass="$MOS_PASS" \
                patch="$patch_nr" \
                regexp="$gmp_regexp" \
                download=all
        else
            java -jar "$PATCH_STORAGE/bin/getMOSPatch.jar" \
                MOSUser="$MOS_USER" \
                MOSPass="$MOS_PASS" \
                patch="$patch_nr" \
                download=all
        fi
    )
    local rc=$?

    if [ "$rc" -ne 0 ]; then
        fail "getMOSPatch failed for patch $patch_nr (rc=$rc)"
        return 1
    fi

    # Verify at least one ZIP was created
    if ! ls "$dest_dir"/*.zip 2>/dev/null | grep -q .; then
        fail "No ZIP found in $dest_dir after download – getMOSPatch may have failed silently"
        return 1
    fi

    local size
    size="$(du -sh "$dest_dir" 2>/dev/null | awk '{print $1}')"
    ok "$(printf "Patch %-12s downloaded  %s  (%s)" "$patch_nr" "$dest_dir" "$size")"
    return 0
}

# =============================================================================
# MAIN
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – FMW 14.1.2 Software Download\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host     : %s\n" "$(_get_hostname)"             | tee -a "$LOG_FILE"
printf "  Date     : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
printf "  Apply    : %s\n" "$APPLY"                        | tee -a "$LOG_FILE"
printf "  Wget     : %s\n" "$WGET_MODE"                    | tee -a "$LOG_FILE"
printf "  MOS      : %s\n" "$MOS_MODE"                     | tee -a "$LOG_FILE"
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

command -v sha256sum >/dev/null 2>&1 && ok "sha256sum found" \
    || { fail "sha256sum not installed"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
command -v od >/dev/null 2>&1 && ok "od found" \
    || { fail "od not installed"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }

if $WGET_MODE; then
    command -v wget >/dev/null 2>&1 && ok "wget found" \
        || { fail "wget not installed (required for --wget)"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
fi

if $MOS_MODE; then
    [ -n "$MOS_USER" ] && ok "MOS_USER = $MOS_USER" \
        || { fail "MOS_USER not set in environment.conf – run 09-Install/01-setup-interview.sh"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
    command -v java >/dev/null 2>&1 && ok "java found: $(java -version 2>&1 | head -1)" \
        || { fail "java not installed (required for --mos)"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
fi

# --- Which eDelivery files? ---------------------------------------------------
DOWNLOAD_FR=false
case "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" in
    FORMS_AND_REPORTS|FORMS_ONLY|REPORTS_ONLY)
        [ -n "${FMW_FR_ZIP:-}" ] && DOWNLOAD_FR=true ;;
esac

printf "\n" | tee -a "$LOG_FILE"
info "eDelivery files:"
info "  FMW Infrastructure : $FMW_INFRA_ZIP → $PATCH_STORAGE/wls/"
$DOWNLOAD_FR \
    && info "  Forms & Reports    : $FMW_FR_ZIP → $PATCH_STORAGE/fr/" \
    || info "  Forms & Reports    : skipped (INSTALL_COMPONENTS=${INSTALL_COMPONENTS:-not set})"

if $MOS_MODE; then
    printf "\n" | tee -a "$LOG_FILE"
    info "MOS downloads:"
    info "  OPatch upgrade (Patch ${OPATCH_UPGRADE_PATCH_NR:-28186730}) → $PATCH_STORAGE/patches/${OPATCH_UPGRADE_PATCH_NR:-28186730}/"
    IFS=',' read -ra _patch_list <<< "${INSTALL_PATCHES:-}"
    for _p in "${_patch_list[@]}"; do
        [ -n "$_p" ] && info "  Patch   : $_p → $PATCH_STORAGE/patches/$_p/"
    done
    unset _patch_list _p
fi

# --- Dry-run exit -------------------------------------------------------------
if ! $APPLY; then
    printf "\n" | tee -a "$LOG_FILE"
    warn "Dry-run – use --apply to create directories and process files."
    $WGET_MODE \
        && info "Wget mode (--wget): will prompt for Bearer Token and download URLs." \
        || info "Manual mode: will prompt to place files in target directories."
    $MOS_MODE \
        && info "MOS mode (--mos): will download OPatch + patches via getMOSPatch.jar." \
        || info "MOS mode not active. Add --mos to also download OPatch and patches."
    print_summary
    exit $EXIT_CODE
fi

# =============================================================================
# Section 1: eDelivery installers
# =============================================================================
section "eDelivery Installers"

# --- Bearer Token (only in wget mode) -----------------------------------------
BEARER_TOKEN=""
if $WGET_MODE; then
    printLine
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

[ "$ERRORS" -gt 0 ] && { fail "$ERRORS eDelivery file(s) failed"; EXIT_CODE=1; }

# =============================================================================
# Section 2: getMOSPatch – OPatch + post-install patches
# =============================================================================
if $MOS_MODE; then

    section "MOS Downloads (getMOSPatch)"

    # --- getMOSPatch.jar check ------------------------------------------------
    GMP_JAR="$PATCH_STORAGE/bin/getMOSPatch.jar"
    GMP_CFG="$PATCH_STORAGE/bin/.getMOSPatch.cfg"

    GMP_GITHUB_URL="https://raw.githubusercontent.com/MarisElsins/getMOSPatch/master/getMOSPatch.jar"

    if [ -f "$GMP_JAR" ]; then
        ok "getMOSPatch.jar found: $GMP_JAR"
    else
        warn "getMOSPatch.jar not found – attempting download from GitHub"
        info "  $GMP_GITHUB_URL"

        mkdir -p "$(dirname "$GMP_JAR")"

        _dl_tool=""
        command -v wget  >/dev/null 2>&1 && _dl_tool="wget"
        command -v curl  >/dev/null 2>&1 && [ -z "$_dl_tool" ] && _dl_tool="curl"

        if [ -z "$_dl_tool" ]; then
            fail "Neither wget nor curl found – cannot download getMOSPatch.jar"
            info "  Install wget or curl, or place the JAR manually at: $GMP_JAR"
            EXIT_CODE=2; print_summary; exit $EXIT_CODE
        fi

        if [ "$_dl_tool" = "wget" ]; then
            wget -q --show-progress -O "$GMP_JAR" "$GMP_GITHUB_URL"
        else
            curl -fsSL -o "$GMP_JAR" "$GMP_GITHUB_URL"
        fi
        _dl_rc=$?

        if [ "$_dl_rc" -ne 0 ] || [ ! -s "$GMP_JAR" ]; then
            rm -f "$GMP_JAR"
            fail "Download of getMOSPatch.jar failed (rc=$_dl_rc)"
            info "  Manual download: https://github.com/MarisElsins/getMOSPatch"
            EXIT_CODE=2; print_summary; exit $EXIT_CODE
        fi

        ok "getMOSPatch.jar downloaded: $GMP_JAR  ($(du -sh "$GMP_JAR" | awk '{print $1}'))"
    fi

    # --- .getMOSPatch.cfg: create if missing ----------------------------------
    # Format: one entry per line – getMOSPatch reads this from the CURRENT WORKING DIR.
    # The master copy lives in $PATCH_STORAGE/bin/; _mos_download_one copies it
    # to each destination directory before invoking getMOSPatch.
    if [ ! -f "$GMP_CFG" ]; then
        mkdir -p "$(dirname "$GMP_CFG")"
        printf "%s\n%s\n" "${MOS_PLATFORM:-226P}" "${MOS_LANGUAGE:-4L}" > "$GMP_CFG"
        ok "$(printf "Created .getMOSPatch.cfg  platform=%-6s lang=%s" \
            "${MOS_PLATFORM:-226P}" "${MOS_LANGUAGE:-4L}")"
    else
        ok ".getMOSPatch.cfg exists: $GMP_CFG"
    fi

    # --- Decrypt MOS password -------------------------------------------------
    section "MOS Authentication"
    MOS_PASS=""
    if ! _load_mos_password; then
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi

    MOS_ERRORS=0

    # --- OPatch Upgrade Patch (28186730) -------------------------------------
    # Since OPatch >= 13.6, OPatch is upgraded via opatch_generic.jar (OUI tooling).
    # Patch 28186730 is the FMW/WLS-specific package containing opatch_generic.jar.
    # It downloads to patches/$OPATCH_UPGRADE_PATCH_NR/ – where 05-oracle_patch_weblogic.sh
    # expects it. Patch 6880880 (raw OPatch files) is NOT used by the patch script.
    section "OPatch Upgrade (patch ${OPATCH_UPGRADE_PATCH_NR:-28186730})"
    info "Contains opatch_generic.jar for FMW/WLS OPatch upgrade (OUI tooling)"
    info "Target version : ${OPATCH_VERSION_INSTALL:-13.9.4.2.22}  |  minimum required: ${OPATCH_VERSION_MIN:-13.9.4.2.17}"

    OPATCH_UPGRADE_DL_DIR="$PATCH_STORAGE/patches/${OPATCH_UPGRADE_PATCH_NR:-28186730}"
    _mos_download_one "${OPATCH_UPGRADE_PATCH_NR:-28186730}" "$OPATCH_UPGRADE_DL_DIR" \
        || MOS_ERRORS=$(( MOS_ERRORS + 1 ))

    # --- Post-install patches -------------------------------------------------
    section "Post-Install Patches"

    if [ -z "${INSTALL_PATCHES:-}" ]; then
        warn "INSTALL_PATCHES not set in oracle_software_version.conf – skipping patch downloads"
    else
        IFS=',' read -ra PATCH_LIST <<< "$INSTALL_PATCHES"
        for PATCH_NR in "${PATCH_LIST[@]}"; do
            PATCH_NR="${PATCH_NR// /}"   # trim whitespace
            [ -z "$PATCH_NR" ] && continue
            PATCH_DIR="$PATCH_STORAGE/patches/$PATCH_NR"
            _mos_download_one "$PATCH_NR" "$PATCH_DIR" \
                || MOS_ERRORS=$(( MOS_ERRORS + 1 ))
        done
        unset PATCH_LIST PATCH_NR PATCH_DIR
    fi

    # Clear MOS password from memory
    MOS_PASS="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    unset MOS_PASS

    [ "$MOS_ERRORS" -gt 0 ] && { fail "$MOS_ERRORS MOS download(s) failed – check: $LOG_FILE"; EXIT_CODE=1; }

    printf "\n" | tee -a "$LOG_FILE"
    info "After FMW installation – update OPatch and apply patches:"
    info "  05-oracle_patch_weblogic.sh --apply"
    info "  → OPatch upgrade via: patches/${OPATCH_UPGRADE_PATCH_NR:-28186730}/opatch_generic.jar"
    info "  → Patches: ${INSTALL_PATCHES:-see oracle_software_version.conf}"
    info "  See: 09-Install/docs/05-oracle_patch_weblogic.md"

fi

# =============================================================================
print_summary
exit $EXIT_CODE
