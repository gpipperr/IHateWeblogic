#!/bin/bash
# =============================================================================
# Script   : 04-oracle_pre_download.sh
# Purpose  : Download FMW 14.1.2 base installers and MOS patches into
#            PATCH_STORAGE.
#            eDelivery path : manual file placement (primary) or Bearer Token wget.
#            MOS path       : getMOSPatch.jar for OPatch + post-install patches.
#            GitHub         : JACOB (WebUtil OLE) if FORMS_WEBUTIL_JACOB=true.
#            MOS, 2nd platform: client Java (Windows x64) if FORMS_CLIENT_DIST=true
#                             -> $PATCH_STORAGE/client/jdk/<nr>/ (concept docs/40).
#            URL            : shortcut icon if FORMS_CLIENT_ICON is an http(s) URL
#            Repository     : default shortcut icon forms_templates/IHateWeblogic.ico
#                             -> $PATCH_STORAGE/icon/ (forms_client_icon_path).
#            OTN            : APEX + ORDS "latest" ZIPs if INSTALL_APEX=true
#                             -> $PATCH_STORAGE/apex/<ver>/, ords/<ver>/ (version from the ZIP)
#            MOS, Generic   : APEX patch set bundle (APEX_PATCH_NR, platform 2000P)
#                             -> $PATCH_STORAGE/apex/<ver>/patch/<nr>/ (--mos)
#            MOS, Linux     : standalone CVU (DB_CVU_PATCH_NR, only LOCAL_REP_DB=true)
#                             -> $PATCH_STORAGE/database/cvu/ (--mos)
# Call     : ./09-Install/04-oracle_pre_download.sh [--apply] [--wget] [--mos|--all] [--fresh-patches]
#            (none)              – dry-run: show expected paths and checksums
#            --apply             – eDelivery: create dirs, prompt placement, verify
#            --apply --wget      – eDelivery via Bearer Token wget (no manual copy)
#            --apply --mos       – eDelivery + getMOSPatch (OPatch + patches)
#            --apply --all       – alias for --apply --mos
#            --apply --wget --mos – Bearer Token wget + getMOSPatch
#            --apply --fresh-patches --mos – archive patches/ to patches_<timestamp>/
#                                   first, then download into a clean patches/
#                                   (use at the start of a new patch cycle - the
#                                   per-patch skip-if-present check only looks for
#                                   ANY zip in the directory, not the right version,
#                                   so leftover builds from a previous cycle can
#                                   get silently reused instead of re-downloaded)
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
    printf "  Run first: 00-Setup/init_env.sh --apply\n" >&2; exit 2
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
FRESH_PATCHES=false

_usage() {
    printf "Usage: %s [--apply] [--wget] [--mos|--all] [--fresh-patches] [--help]\n\n" "$(basename "$0")"
    printf "  %-22s %s\n" "(none)"        "Dry-run: show expected paths and checksums"
    printf "  %-22s %s\n" "--apply"       "Create dirs, prompt placement, verify (eDelivery)"
    printf "  %-22s %s\n" "--apply --wget" "Download via Bearer Token instead of manual copy"
    printf "  %-22s %s\n" "--apply --mos"  "eDelivery + getMOSPatch (OPatch + patches)"
    printf "  %-22s %s\n" "--apply --all"  "Alias for --apply --mos"
    printf "  %-22s %s\n" "--fresh-patches" "Archive existing patches/ to patches_<timestamp>/ first"
    printf "\nBearer Token: edelivery.oracle.com → WGET Options → Generate Token (valid 1 h)\n"
    exit 0
}

for _arg in "$@"; do
    case "$_arg" in
        --apply)          APPLY=true ;;
        --wget)           WGET_MODE=true ;;
        --mos|--all)      MOS_MODE=true ;;
        --fresh-patches)  FRESH_PATCHES=true ;;
        --help|-h)        _usage ;;
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

# _gmp_run <getMOSPatch args …> – run getMOSPatch.jar in the CURRENT directory
# with MOS user/password typed into a pseudo terminal: getMOSPatch asks on its
# console when MOSUser/MOSPass are not given. The password never appears on a
# command line (MOSPass= was visible in ps for every user – fixed 2026-10-20)
# and is masked in the output. User + password reach python via stdin.
_gmp_run() {
    printf '%s\n%s\n' "$MOS_USER" "$MOS_PWD" | python3 -I -c '
import os, pty, select, sys
user = sys.stdin.readline().rstrip("\n"); pwd = sys.stdin.readline().rstrip("\n")
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
tail, sent_u, sent_p = b"", False, False
while True:
    r, _, _ = select.select([fd], [], [], 1800)
    if not r:
        break
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d:
        break
    tail = (tail + d)[-300:].lower()
    if not sent_u and b"username" in tail:
        os.write(fd, (user + "\n").encode()); sent_u, tail = True, b""
    elif sent_u and not sent_p and b"password" in tail:
        os.write(fd, (pwd + "\n").encode()); sent_p, tail = True, b""
    if pwd:
        d = d.replace(pwd.encode(), b"****")
    sys.stdout.buffer.write(d); sys.stdout.flush()
_, st = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(st))
' java $(_java_proxy_opts) -jar "$PATCH_STORAGE/bin/getMOSPatch.jar" "$@"
}

# _java_proxy_opts – https_proxy/http_proxy/no_proxy as JVM system properties:
# java ignores the shell variables, curl and wget use them
_java_proxy_opts() {
    local p="${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}" hp host port
    [ -z "$p" ] && return 0
    hp="${p#*://}"; hp="${hp#*@}"; hp="${hp%%/*}"
    host="${hp%%:*}"; port=80
    [ "$hp" != "$host" ] && port="${hp##*:}"
    printf -- "-Dhttps.proxyHost=%s -Dhttps.proxyPort=%s -Dhttp.proxyHost=%s -Dhttp.proxyPort=%s" \
        "$host" "$port" "$host" "$port"
    local np="${no_proxy:-${NO_PROXY:-}}"
    [ -n "$np" ] && printf -- " -Dhttp.nonProxyHosts=%s" "$(printf '%s' "$np" | tr ',' '|' | tr -d ' ')"
}

# _mos_download_one  patch_nr  dest_dir  [regexp]  [platform]
# Download one patch or OPatch via getMOSPatch.jar.
# regexp (optional): passed as regexp= to getMOSPatch to restrict which files are downloaded.
# platform (optional): MOS platform code for this directory only (e.g. 233P for the
#   Windows client Java) – written as "<platform>;<language>" into the directory's
#   .getMOSPatch.cfg instead of copying the master cfg (MOS_PLATFORM).
# Retries up to MOS_RETRY_MAX times (default 3) on failure to handle transient DNS timeouts.
_mos_download_one() {
    local patch_nr="$1"
    local dest_dir="$2"
    local gmp_regexp="${3:-}"
    local gmp_platform="${4:-}"
    # getMOSPatch matches the regexp (String.matches) against the file name
    # WITHOUT ".zip" (checked in the class 2026-10-28) – strip a trailing \.zip
    gmp_regexp="${gmp_regexp%\\.zip}"; gmp_regexp="${gmp_regexp%.zip}"
    local retry_max="${MOS_RETRY_MAX:-3}"
    local retry_wait="${MOS_RETRY_WAIT:-10}"

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
    if [ -n "$gmp_platform" ]; then
        printf "%s;%s\n" "$gmp_platform" "${MOS_LANGUAGE:-4L}" > "$dest_dir/.getMOSPatch.cfg"
        info "$(printf "%-12s %s" "Patch $patch_nr:" "platform $gmp_platform (own .getMOSPatch.cfg)")"
    else
        cp "$PATCH_STORAGE/bin/.getMOSPatch.cfg" "$dest_dir/.getMOSPatch.cfg" 2>/dev/null
    fi

    local attempt rc
    for attempt in $(seq 1 "$retry_max"); do
        [ "$attempt" -gt 1 ] && info "$(printf "Patch %-10s retry %d/%d (DNS timeout?) – waiting %ss" \
            "$patch_nr" "$attempt" "$retry_max" "$retry_wait")" && sleep "$retry_wait"

        (
            cd "$dest_dir" || exit 1
            if [ -n "$gmp_regexp" ]; then
                _gmp_run patch="$patch_nr" regexp="$gmp_regexp" download=all
            else
                _gmp_run patch="$patch_nr" download=all
            fi
        )
        rc=$?
        [ "$rc" -eq 0 ] && break
        warn "$(printf "Patch %-10s attempt %d/%d failed (rc=%d)" "$patch_nr" "$attempt" "$retry_max" "$rc")"
    done

    if [ "$rc" -ne 0 ]; then
        fail "getMOSPatch failed for patch $patch_nr after $retry_max attempt(s) (rc=$rc)"
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
    [ -f "$MOS_SEC_FILE" ] && ok "mos_sec.conf.des3 found: $MOS_SEC_FILE" \
        || { fail "MOS credentials not found: $MOS_SEC_FILE"; info "  Run first: 00-Setup/mos_sec.sh --apply"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
    command -v java >/dev/null 2>&1 && ok "java found: $(java -version 2>&1 | head -1)" \
        || { fail "java not installed (required for --mos)"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
fi

# --- Download sources reachable? ----------------------------------------------
# A cloud VM in a private subnet (OCI: no NAT gateway – a Service Gateway only
# reaches the Oracle Services Network, e.g. Object Storage and the regional yum
# mirror, NOT eDelivery/MOS) or a silent-DROP firewall lets wget/getMOSPatch
# hang for minutes per file (seen at a customer, 2026-10-29). Test first, with
# a short connect timeout; curl honours https_proxy.
_DL_HOSTS=""
$WGET_MODE && _DL_HOSTS="$_DL_HOSTS edelivery.oracle.com"
$MOS_MODE  && _DL_HOSTS="$_DL_HOSTS updates.oracle.com login-ext.identity.oraclecloud.com"
if [ -n "$_DL_HOSTS" ] && command -v curl >/dev/null 2>&1; then
    _dl_down=0
    for _h in $_DL_HOSTS; do
        curl -s -o /dev/null --connect-timeout 10 --max-time 20 "https://$_h/" 2>/dev/null
        case $? in
            0|22|35|60) ok "$(printf "%-24s reachable" "$_h")" ;;
            6)  fail "$(printf "%-24s name not resolvable" "$_h")"; _dl_down=1 ;;
            *)  fail "$(printf "%-24s not reachable (no route / firewall / no proxy)" "$_h")"; _dl_down=1 ;;
        esac
    done
    if [ "$_dl_down" -eq 1 ]; then
        info "  Proxy: export https_proxy=http://<proxy>:<port> (curl/wget; getMOSPatch gets it as -Dhttps.proxyHost)"
        info "  OCI private subnet: NAT gateway needed – the Service Gateway does not reach eDelivery/MOS"
        info "  Other sites work (github.com)? Egress allow-list – ask for *.oracle.com + login-ext.identity.oraclecloud.com"
        info "  Offline: run this script on a host WITH internet access (same oracle_software_version.conf),"
        info "  copy PATCH_STORAGE here (rsync -a <host>:$PATCH_STORAGE/ $PATCH_STORAGE/), then"
        info "  re-run without --wget/--mos – present files are verified and skipped"
        info "  See: 09-Install/docs/04-oracle_pre_download.md \"Host without internet access\""
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi
    unset _h _dl_down
fi
unset _DL_HOSTS

# --- Client Java for the Forms client distribution (concept docs/40) ----------
# Same JDK patch as the server, other platform -> own directory: the skip check
# of _mos_download_one treats ANY zip in a directory as "already downloaded".
DOWNLOAD_CLIENT_JDK=false
case "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" in
    FORMS_AND_REPORTS|FORMS_ONLY)
        [ "${FORMS_CLIENT_DIST:-false}" = "true" ] && DOWNLOAD_CLIENT_JDK=true ;;
esac
CLIENT_JDK_NR="${CLIENT_JDK_PATCH_NR:-${JDK_PATCH_NR:-}}"
CLIENT_JDK_PLAT="${CLIENT_JDK_PLATFORM:-233P}"
CLIENT_JDK_DIR="$PATCH_STORAGE/client/jdk/$CLIENT_JDK_NR"
[ -z "$CLIENT_JDK_NR" ] && DOWNLOAD_CLIENT_JDK=false

# =============================================================================
# --fresh-patches: archive existing patches/ before downloading anything new
# =============================================================================
# _mos_download_one's skip-if-present check only looks for ANY zip in the
# destination directory, not whether it is the version actually needed for
# the current cycle - a leftover build from a previous quarter (or a patch
# that ships multiple product-version variants under the same patch number)
# can otherwise get silently reused instead of freshly downloaded. Moving the
# whole patches/ directory aside guarantees every patch is re-fetched clean.
if $FRESH_PATCHES; then
    section "Archiving patches/ (--fresh-patches)"

    PATCHES_DIR="$PATCH_STORAGE/patches"
    if [ -d "$PATCHES_DIR" ] && [ -n "$(ls -A "$PATCHES_DIR" 2>/dev/null)" ]; then
        FRESH_PATCHES_ARCHIVE="${PATCH_STORAGE}/patches_$(date +%Y%m%d_%H%M%S)"
        if $APPLY; then
            if mv "$PATCHES_DIR" "$FRESH_PATCHES_ARCHIVE"; then
                ok "Archived: $PATCHES_DIR -> $FRESH_PATCHES_ARCHIVE"
                mkdir -p "$PATCHES_DIR"
                ok "Fresh patches/ directory ready: $PATCHES_DIR"
            else
                fail "Could not archive $PATCHES_DIR -> $FRESH_PATCHES_ARCHIVE"
                EXIT_CODE=2; print_summary; exit $EXIT_CODE
            fi
        else
            warn "Dry-run: would archive $PATCHES_DIR -> $FRESH_PATCHES_ARCHIVE"
        fi
    else
        ok "patches/ is empty or does not exist yet – nothing to archive"
    fi

    # client Java (same constant ZIP name problem as the server JDK)
    CLIENT_JDK_ROOT="$PATCH_STORAGE/client/jdk"
    if [ -d "$CLIENT_JDK_ROOT" ] && [ -n "$(ls -A "$CLIENT_JDK_ROOT" 2>/dev/null)" ]; then
        _cj_archive="${CLIENT_JDK_ROOT}_$(date +%Y%m%d_%H%M%S)"
        if $APPLY; then
            if mv "$CLIENT_JDK_ROOT" "$_cj_archive"; then
                ok "Archived: $CLIENT_JDK_ROOT -> $_cj_archive"
            else
                fail "Could not archive $CLIENT_JDK_ROOT -> $_cj_archive"
                EXIT_CODE=2; print_summary; exit $EXIT_CODE
            fi
        else
            warn "Dry-run: would archive $CLIENT_JDK_ROOT -> $_cj_archive"
        fi
        unset _cj_archive
    fi
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
    if [ -n "${WLS_SPB_PATCH_NR:-}" ]; then
        info "  WLS Stack Patch Bundle (Patch $WLS_SPB_PATCH_NR) → $PATCH_STORAGE/patches/$WLS_SPB_PATCH_NR/"
    fi
    for _p in $INSTALL_PATCHES; do
        [ -n "$_p" ] && info "  Patch   : $_p → $PATCH_STORAGE/patches/$_p/"
    done
    unset _p
    $DOWNLOAD_CLIENT_JDK && \
        info "  Client Java (Patch $CLIENT_JDK_NR, platform $CLIENT_JDK_PLAT) → $CLIENT_JDK_DIR/"
fi

# --- Storage inventory: what is already present? -------------------------------
# Read-only. Answers "is everything already downloaded?" without --apply.
section "Storage Inventory ($PATCH_STORAGE)"
INVENTORY_MISSING=0

_inv_file() {
    local path="$1" label="$2"
    if [ -f "$path" ]; then
        ok "$(printf "  %-26s present  %s" "$label" "$(du -h "$path" 2>/dev/null | cut -f1)")"
    else
        warn "$(printf "  %-26s MISSING  %s" "$label" "$path")"
        INVENTORY_MISSING=$(( INVENTORY_MISSING + 1 ))
    fi
}

_inv_patch() {
    local nr="$1" label="$2" zips
    zips="$(ls "$PATCH_STORAGE/patches/$nr"/p${nr}_*.zip 2>/dev/null | wc -l)"
    if [ "$zips" -gt 0 ]; then
        ok "$(printf "  %-26s present  %d ZIP(s) in patches/%s/" "$label" "$zips" "$nr")"
        return 0
    fi
    return 1
}

_inv_file "$PATCH_STORAGE/wls/$FMW_INFRA_ZIP" "FMW Infrastructure ZIP"
$DOWNLOAD_FR && _inv_file "$PATCH_STORAGE/fr/$FMW_FR_ZIP" "Forms & Reports ZIP"

_spb_zip="$(ls "$PATCH_STORAGE/patches/${WLS_SPB_PATCH_NR:-none}"/p${WLS_SPB_PATCH_NR:-none}_*.zip 2>/dev/null | head -1)"
_opatch_nr="${OPATCH_UPGRADE_PATCH_NR:-28186730}"
if ! _inv_patch "$_opatch_nr" "OPatch upgrade $_opatch_nr"; then
    # 05-oracle_patch_weblogic.sh prefers the copy bundled in the SPB (tools/opatch/generic/)
    if [ -n "$_spb_zip" ] && unzip -l "$_spb_zip" 2>/dev/null | grep -q "tools/opatch/generic/p${_opatch_nr}_"; then
        ok "$(printf "  %-26s bundled in SPB %s – no separate download needed" "OPatch upgrade $_opatch_nr" "$WLS_SPB_PATCH_NR")"
    else
        warn "$(printf "  %-26s MISSING  (not in patches/ and not bundled in an SPB)" "OPatch upgrade $_opatch_nr")"
        INVENTORY_MISSING=$(( INVENTORY_MISSING + 1 ))
    fi
fi

_inv_list="${WLS_SPB_PATCH_NR:-} ${JDK_PATCH_NR:-} ${FMW_JDK_PATCH_NR:-} ${INSTALL_PATCHES:-} ${INSTALL_PATCHES_FR_COMMON:-} ${INSTALL_PATCHES_REPORTS:-}"
case "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" in
    FORMS_AND_REPORTS|FORMS_ONLY) _inv_list="$_inv_list ${INSTALL_PATCHES_FORMS:-}" ;;
esac
[ "${REPORTS_BIDIPARENTHESIS:-}" = "YES" ] && _inv_list="$_inv_list ${INSTALL_PATCHES_FR_OPTIONAL:-}"
for _p in $_inv_list; do
    if ! _inv_patch "$_p" "Patch $_p"; then
        warn "$(printf "  %-26s MISSING  patches/%s/" "Patch $_p" "$_p")"
        INVENTORY_MISSING=$(( INVENTORY_MISSING + 1 ))
    fi
done
unset _p _inv_list _spb_zip _opatch_nr

# JACOB (GitHub, not MOS) – only for Forms with FORMS_WEBUTIL_JACOB=true
DOWNLOAD_JACOB=false
case "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" in
    FORMS_AND_REPORTS|FORMS_ONLY)
        [ "${FORMS_WEBUTIL_JACOB:-false}" = "true" ] && [ -n "${JACOB_ZIP:-}" ] && DOWNLOAD_JACOB=true ;;
esac
$DOWNLOAD_JACOB && _inv_file "$PATCH_STORAGE/jacob/$JACOB_ZIP" "JACOB ZIP (WebUtil OLE)"

# Client Java (FORMS_CLIENT_DIST=true, Forms only) – must not be a Linux ZIP
if $DOWNLOAD_CLIENT_JDK; then
    _cj_zip="$(ls "$CLIENT_JDK_DIR"/p"${CLIENT_JDK_NR}"_*.zip 2>/dev/null | grep -v 'Linux' | head -1)"
    if [ -n "$_cj_zip" ]; then
        ok "$(printf "  %-26s present  %s" "Client Java ($CLIENT_JDK_PLAT)" "$(basename "$_cj_zip")")"
    else
        warn "$(printf "  %-26s MISSING  client/jdk/%s/" "Client Java ($CLIENT_JDK_PLAT)" "$CLIENT_JDK_NR")"
        INVENTORY_MISSING=$(( INVENTORY_MISSING + 1 ))
    fi
    unset _cj_zip
elif [ "${FORMS_CLIENT_DIST:-false}" = "true" ] && [ -z "$CLIENT_JDK_NR" ]; then
    warn "FORMS_CLIENT_DIST=true but neither CLIENT_JDK_PATCH_NR nor JDK_PATCH_NR is set"
fi

# Shortcut icon of the Forms client (FORMS_CLIENT_ICON as URL -> $PATCH_STORAGE/icon/,
# default $PATCH_STORAGE/icon/IHateWeblogic.ico <- forms_templates/IHateWeblogic.ico)
DOWNLOAD_ICON=false
COPY_ICON=false
CLIENT_ICON_FILE=""
DEFAULT_ICON_SRC="$SCRIPT_DIR/forms_templates/IHateWeblogic.ico"
if $DOWNLOAD_CLIENT_JDK || [ "${FORMS_CLIENT_DIST:-false}" = "true" ]; then
    case "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" in
        FORMS_AND_REPORTS|FORMS_ONLY)
            case "${FORMS_CLIENT_ICON:-}" in
                http://*|https://*)
                    DOWNLOAD_ICON=true
                    CLIENT_ICON_FILE="$(forms_client_icon_path)"
                    _inv_file "$CLIENT_ICON_FILE" "Client shortcut icon" ;;
                */icon/IHateWeblogic.ico)
                    COPY_ICON=true
                    CLIENT_ICON_FILE="$(forms_client_icon_path)"
                    _inv_file "$CLIENT_ICON_FILE" "Client icon (default)" ;;
            esac ;;
    esac
fi

# Standalone CVU for the local RCU database (60-RCU-DB-19c/00b-db_cvu_check.sh)
DOWNLOAD_CVU=false
[ "${LOCAL_REP_DB:-false}" = "true" ] && [ -n "${DB_CVU_PATCH_NR:-}" ] && DOWNLOAD_CVU=true

# APEX + ORDS (OTN "latest" ZIPs, version from the ZIP) + APEX patch (MOS Generic)
DOWNLOAD_APEX=false
[ "${INSTALL_APEX:-false}" = "true" ] && DOWNLOAD_APEX=true

APEX_ZIP_FILE="" ; APEX_VER="" ; ORDS_ZIP_FILE="" ; ORDS_VER=""
if $DOWNLOAD_APEX; then
    APEX_ZIP_FILE="$(otn_newest_zip "$PATCH_STORAGE/apex" 'apex_*.zip')"
    ORDS_ZIP_FILE="$(otn_newest_zip "$PATCH_STORAGE/ords" 'ords-*.zip')"
    [ -n "$APEX_ZIP_FILE" ] && APEX_VER="$(basename "$(dirname "$APEX_ZIP_FILE")")"
    [ -n "$ORDS_ZIP_FILE" ] && ORDS_VER="$(basename "$(dirname "$ORDS_ZIP_FILE")")"
    if [ -n "$APEX_ZIP_FILE" ]; then
        ok "$(printf "  %-26s present  %s" "APEX $APEX_VER" "apex/$APEX_VER/$(basename "$APEX_ZIP_FILE")")"
    else
        warn "$(printf "  %-26s MISSING  apex/<ver>/ (%s)" "APEX" "${APEX_ZIP_URL:-APEX_ZIP_URL not set}")"
        INVENTORY_MISSING=$(( INVENTORY_MISSING + 1 ))
    fi
    if [ -n "$ORDS_ZIP_FILE" ]; then
        ok "$(printf "  %-26s present  %s" "ORDS $ORDS_VER" "ords/$ORDS_VER/$(basename "$ORDS_ZIP_FILE")")"
    else
        warn "$(printf "  %-26s MISSING  ords/<ver>/ (%s)" "ORDS" "${ORDS_ZIP_URL:-ORDS_ZIP_URL not set}")"
        INVENTORY_MISSING=$(( INVENTORY_MISSING + 1 ))
    fi
    if [ -n "${APEX_PATCH_NR:-}" ]; then
        if ls "$PATCH_STORAGE/apex/${APEX_VER:-none}/patch/$APEX_PATCH_NR"/p"${APEX_PATCH_NR}"_*.zip >/dev/null 2>&1; then
            ok "$(printf "  %-26s present  apex/%s/patch/%s/" "APEX patch $APEX_PATCH_NR" "$APEX_VER" "$APEX_PATCH_NR")"
        else
            warn "$(printf "  %-26s MISSING  apex/%s/patch/%s/ (--mos)" "APEX patch $APEX_PATCH_NR" "${APEX_VER:-<ver>}" "$APEX_PATCH_NR")"
            INVENTORY_MISSING=$(( INVENTORY_MISSING + 1 ))
        fi
    else
        info "$(printf "  %-26s none configured (APEX_PATCH_NR – see the APEX download page)" "APEX patch set bundle")"
    fi
fi

if $DOWNLOAD_CVU; then
    if ls "$PATCH_STORAGE/database/cvu"/p"${DB_CVU_PATCH_NR}"_*.zip >/dev/null 2>&1; then
        ok "$(printf "  %-26s present  database/cvu/" "CVU $DB_CVU_PATCH_NR (local DB)")"
    else
        warn "$(printf "  %-26s MISSING  database/cvu/ (--mos)" "CVU $DB_CVU_PATCH_NR (local DB)")"
        INVENTORY_MISSING=$(( INVENTORY_MISSING + 1 ))
    fi
fi

if [ "$INVENTORY_MISSING" -eq 0 ]; then
    ok "All required installers and patches are present – no download needed"
else
    info "$INVENTORY_MISSING item(s) missing – download with: $(basename "$0") --apply --mos"
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
# Section 1b: JACOB from GitHub (FORMS_WEBUTIL_JACOB=true only)
# =============================================================================
if $DOWNLOAD_JACOB; then
    section "JACOB (WebUtil OLE) – GitHub"
    _jacob_dir="$PATCH_STORAGE/jacob"
    _jacob_zip="$_jacob_dir/$JACOB_ZIP"
    mkdir -p "$_jacob_dir"
    if [ ! -f "$_jacob_zip" ]; then
        info "Downloading $JACOB_URL"
        if curl -fsSL --max-time 300 -o "${_jacob_zip}.part" "$JACOB_URL"; then
            mv -f "${_jacob_zip}.part" "$_jacob_zip"
        else
            rm -f "${_jacob_zip}.part"
            fail "Download failed: $JACOB_URL"
            info "  Manual: download $JACOB_ZIP from https://github.com/freemansoft/jacob-project/releases"
            info "          and place it in $_jacob_dir/"
            EXIT_CODE=1
        fi
    fi
    if [ -f "$_jacob_zip" ]; then
        _sha="$(sha256sum "$_jacob_zip" | cut -d' ' -f1)"
        if [ -z "${JACOB_SHA256:-}" ]; then
            warn "No JACOB_SHA256 in oracle_software_version.conf – checksum not verified ($_sha)"
        elif [ "${_sha,,}" = "${JACOB_SHA256,,}" ]; then
            ok "$JACOB_ZIP SHA-256 verified"
        else
            fail "$JACOB_ZIP SHA-256 mismatch: $_sha (expected $JACOB_SHA256)"
            mv -f "$_jacob_zip" "${_jacob_zip}.bad_$(date +%Y%m%d_%H%M%S)"
            info "  Moved aside – re-run to download again"
            EXIT_CODE=1
        fi
        unset _sha
    fi
    unset _jacob_dir _jacob_zip
fi

# =============================================================================
# Section 1c: shortcut icon of the Forms client (FORMS_CLIENT_ICON default / URL)
# =============================================================================
if $COPY_ICON; then
    section "Forms client shortcut icon"
    if [ -s "$CLIENT_ICON_FILE" ]; then
        ok "Already present (kept): $CLIENT_ICON_FILE"
    elif [ -f "$DEFAULT_ICON_SRC" ]; then
        mkdir -p "$(dirname "$CLIENT_ICON_FILE")" \
            && cp "$DEFAULT_ICON_SRC" "$CLIENT_ICON_FILE" \
            && ok "Default icon copied: $CLIENT_ICON_FILE" \
            || warn "Cannot copy $DEFAULT_ICON_SRC -> $CLIENT_ICON_FILE"
    else
        warn "Default icon template missing: $DEFAULT_ICON_SRC"
    fi
fi
if $DOWNLOAD_ICON; then
    section "Forms client shortcut icon"
    if [ -s "$CLIENT_ICON_FILE" ]; then
        ok "Already present: $CLIENT_ICON_FILE"
    else
        mkdir -p "$(dirname "$CLIENT_ICON_FILE")"
        info "Downloading $FORMS_CLIENT_ICON"
        if curl -fsSL --max-time 60 -A "Mozilla/5.0" -o "${CLIENT_ICON_FILE}.part" "$FORMS_CLIENT_ICON" \
                && _magic="$(od -An -tx1 -N4 "${CLIENT_ICON_FILE}.part" | tr -d ' \n')" \
                && { [ "$_magic" = "00000100" ] || [ "$_magic" = "89504e47" ]; }; then
            mv -f "${CLIENT_ICON_FILE}.part" "$CLIENT_ICON_FILE"
            ok "Icon saved: $CLIENT_ICON_FILE"
        else
            rm -f "${CLIENT_ICON_FILE}.part"
            warn "Icon download failed or not an ICO/PNG (some sites demand a browser check)"
            info "  Download it in a browser and place it as:"
            info "    $CLIENT_ICON_FILE"
        fi
        unset _magic
    fi
fi

# =============================================================================
# Section 1d: APEX + ORDS from OTN (INSTALL_APEX=true) – "latest" ZIPs
# =============================================================================
# otn_get / otn_newest_zip / otn_zip_version: 00-Setup/IHateWeblogic_lib.sh
if $DOWNLOAD_APEX; then
    section "APEX + ORDS (OTN, INSTALL_APEX=true)"
    otn_get apex "${APEX_ZIP_URL:-}" "$PATCH_STORAGE/apex" "${APEX_SHA256:-}" || EXIT_CODE=1
    otn_get ords "${ORDS_ZIP_URL:-}" "$PATCH_STORAGE/ords" "${ORDS_SHA256:-}" || EXIT_CODE=1
    APEX_ZIP_FILE="$(otn_newest_zip "$PATCH_STORAGE/apex" 'apex_*.zip')"
    ORDS_ZIP_FILE="$(otn_newest_zip "$PATCH_STORAGE/ords" 'ords-*.zip')"
    APEX_VER="$( [ -n "$APEX_ZIP_FILE" ] && basename "$(dirname "$APEX_ZIP_FILE")")"
    ORDS_VER="$( [ -n "$ORDS_ZIP_FILE" ] && basename "$(dirname "$ORDS_ZIP_FILE")")"
    # Oracle: the ORDS version must be equal to or newer than the APEX version
    if [ -n "$APEX_VER" ] && [ -n "$ORDS_VER" ]; then
        if [ "$(printf '%s\n%s\n' "$APEX_VER" "${ORDS_VER%.*.*}" | sort -V | head -1)" = "$APEX_VER" ]; then
            ok "ORDS $ORDS_VER >= APEX $APEX_VER"
        else
            warn "ORDS $ORDS_VER is older than APEX $APEX_VER – Oracle: ORDS must be >= APEX"
        fi
    fi
fi

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

    # --- .getMOSPatch.cfg: create or repair ------------------------------------
    # Format REQUIRED by getMOSPatch.jar's platforms() parser: a single line
    # "<platform>;<language>" (semicolon-joined). getMOSPatch reads this from
    # the CURRENT WORKING DIR. The master copy lives in $PATCH_STORAGE/bin/;
    # _mos_download_one copies it to each destination directory before
    # invoking getMOSPatch.
    #
    # A cfg written as two separate lines (platform on one line, language on
    # the next - what this script used to write) makes getMOSPatch crash with
    # "ArrayIndexOutOfBoundsException: Index 1 out of bounds for length 1":
    # platforms() splits each line on ";" expecting exactly 2 parts, and a
    # line with no ";" yields a 1-element array. Confirmed by decompiling
    # getMOSPatch.jar (platforms() source line 481). If an old, wrongly
    # formatted cfg already exists from before this fix, it is rewritten here
    # rather than left in place.
    GMP_CFG_EXPECTED="${MOS_PLATFORM:-226P};${MOS_LANGUAGE:-4L}"
    if [ ! -f "$GMP_CFG" ] || [ "$(cat "$GMP_CFG" 2>/dev/null)" != "$GMP_CFG_EXPECTED" ]; then
        [ -f "$GMP_CFG" ] && warn ".getMOSPatch.cfg has the wrong format (expected a single \"platform;language\" line) – rewriting"
        mkdir -p "$(dirname "$GMP_CFG")"
        printf "%s\n" "$GMP_CFG_EXPECTED" > "$GMP_CFG"
        ok "$(printf "Wrote .getMOSPatch.cfg  platform=%-6s lang=%s" \
            "${MOS_PLATFORM:-226P}" "${MOS_LANGUAGE:-4L}")"
    else
        ok ".getMOSPatch.cfg exists: $GMP_CFG"
    fi

    # --- Decrypt MOS password -------------------------------------------------
    section "MOS Authentication"
    unset MOS_USER MOS_PWD
    if ! load_secrets_file "$MOS_SEC_FILE"; then
        info "  Run first: 00-Setup/mos_sec.sh --apply"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi
    if [ -z "${MOS_PWD:-}" ]; then
        fail "MOS_PWD not found in $MOS_SEC_FILE – re-run: 00-Setup/mos_sec.sh --apply"
        EXIT_CODE=2; print_summary; exit $EXIT_CODE
    fi
    # MOS_USER from secrets file (overrides environment.conf if set there too)
    [ -n "${MOS_USER:-}" ] && ok "MOS user: $MOS_USER" \
        || { fail "MOS_USER not set – re-run: 00-Setup/mos_sec.sh --apply"; EXIT_CODE=2; print_summary; exit $EXIT_CODE; }
    ok "MOS password decrypted (${#MOS_PWD} characters)"

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

    # --- WLS Stack Patch Bundle (applied via opatch napply, see 05-script) ---
    if [ -n "${WLS_SPB_PATCH_NR:-}" ]; then
        section "WLS Stack Patch Bundle (patch $WLS_SPB_PATCH_NR)"
        info "This ZIP is large (several hundred MB) and contains the SPB"
        info "applied by 05-oracle_patch_weblogic.sh via opatch napply."
        _mos_download_one "$WLS_SPB_PATCH_NR" "$PATCH_STORAGE/patches/$WLS_SPB_PATCH_NR" \
            || MOS_ERRORS=$(( MOS_ERRORS + 1 ))
    fi

    # --- Java SE (JDK 21 updates exist only on MOS since the NFTC ended) -----
    # The only download place – 02b-root_os_java.sh --upgrade-jdk and
    # 07-Maintenance/80-patch_java_os.sh --apply only read patches/<nr>/.
    if [ -n "${JDK_PATCH_NR:-}" ]; then
        section "Java SE (patch $JDK_PATCH_NR)"
        info "Oracle JDK 21 – tar.gz/rpm/deb + SHA256_VALUES (~565 MB), installed by --upgrade-jdk"
        _mos_download_one "$JDK_PATCH_NR" "$PATCH_STORAGE/patches/$JDK_PATCH_NR" \
            || MOS_ERRORS=$(( MOS_ERRORS + 1 ))
    fi
    [ -z "${FMW_JDK_PATCH_NR:-}" ] && \
        info "FMW_JDK_PATCH_NR empty – no patch for the FMW-bundled JDK (oracle_common/jdk) configured yet"

    # --- Client Java for the Forms client distribution (2nd platform) --------
    if $DOWNLOAD_CLIENT_JDK; then
        section "Client Java (patch $CLIENT_JDK_NR, platform $CLIENT_JDK_PLAT)"
        info "Java runtime source of the Forms client bundle (docs/40-forms_client_distribution.md)"
        _mos_download_one "$CLIENT_JDK_NR" "$CLIENT_JDK_DIR" "" "$CLIENT_JDK_PLAT" \
            || MOS_ERRORS=$(( MOS_ERRORS + 1 ))
        if ls "$CLIENT_JDK_DIR"/*Linux*.zip >/dev/null 2>&1; then
            fail "Linux ZIP in $CLIENT_JDK_DIR – the platform $CLIENT_JDK_PLAT was not used"
            MOS_ERRORS=$(( MOS_ERRORS + 1 ))
        fi
    fi

    # --- Standalone CVU (only local RCU DB) -------------------------------------
    section "Standalone CVU (patch ${DB_CVU_PATCH_NR:-?}, local RCU DB)"
    if $DOWNLOAD_CVU; then
        info "Pre-install check of the 19c host: 60-RCU-DB-19c/00b-db_cvu_check.sh"
        _mos_download_one "$DB_CVU_PATCH_NR" "$PATCH_STORAGE/database/cvu" "${DB_CVU_REGEXP:-}" \
            || MOS_ERRORS=$(( MOS_ERRORS + 1 ))
    else
        info "Skipped – LOCAL_REP_DB=${LOCAL_REP_DB:-false} (RCU database on another server)"
    fi

    # --- APEX patch set bundle (platform Generic, own .getMOSPatch.cfg) -------
    if $DOWNLOAD_APEX && [ -n "${APEX_PATCH_NR:-}" ]; then
        section "APEX Patch Set Bundle (patch $APEX_PATCH_NR, platform ${APEX_PATCH_PLATFORM:-2000P})"
        if [ -z "$APEX_VER" ]; then
            warn "APEX base version not downloaded – patch skipped (run without --mos first)"
        else
            _mos_download_one "$APEX_PATCH_NR" "$PATCH_STORAGE/apex/$APEX_VER/patch/$APEX_PATCH_NR" \
                "" "${APEX_PATCH_PLATFORM:-2000P}" || MOS_ERRORS=$(( MOS_ERRORS + 1 ))
        fi
    fi

    # --- Post-install patches -------------------------------------------------
    section "Post-Install Patches"

    if [ -z "${INSTALL_PATCHES:-}" ]; then
        warn "INSTALL_PATCHES not set in oracle_software_version.conf – skipping WLS patch downloads"
    else
        for _PATCH_NR in $INSTALL_PATCHES; do
            [ -z "$_PATCH_NR" ] && continue
            _mos_download_one "$_PATCH_NR" "$PATCH_STORAGE/patches/$_PATCH_NR" \
                || MOS_ERRORS=$(( MOS_ERRORS + 1 ))
        done
        unset _PATCH_NR
    fi

    # --- Forms & Reports QPR patches ------------------------------------------
    section "Forms & Reports QPR Patches"

    FR_PATCHES="${INSTALL_PATCHES_FR_COMMON:-} ${INSTALL_PATCHES_REPORTS:-} ${INSTALL_PATCHES_FORMS:-}"
    [ "${REPORTS_BIDIPARENTHESIS:-}" = "YES" ] && FR_PATCHES="$FR_PATCHES ${INSTALL_PATCHES_FR_OPTIONAL:-}"
    FR_PATCHES="$(printf "%s" "$FR_PATCHES" | xargs)"

    if [ -z "$FR_PATCHES" ]; then
        ok "No Forms/Reports-specific patches configured – nothing to download"
        info "  (set INSTALL_PATCHES_REPORTS / INSTALL_PATCHES_FORMS in oracle_software_version.conf)"
    else
        for _PATCH_NR in $FR_PATCHES; do
            [ -z "$_PATCH_NR" ] && continue
            _mos_download_one "$_PATCH_NR" "$PATCH_STORAGE/patches/$_PATCH_NR" \
                || MOS_ERRORS=$(( MOS_ERRORS + 1 ))
        done
        unset _PATCH_NR
    fi

    # Clear MOS password from memory
    MOS_PWD="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    unset MOS_PWD

    [ "$MOS_ERRORS" -gt 0 ] && { fail "$MOS_ERRORS MOS download(s) failed – check: $LOG_FILE"; EXIT_CODE=1; }

    printf "\n" | tee -a "$LOG_FILE"
    info "After FMW installation – update OPatch and apply patches:"
    info "  05-oracle_patch_weblogic.sh --apply"
    info "  → OPatch upgrade via: patches/${OPATCH_UPGRADE_PATCH_NR:-28186730}/opatch_generic.jar"
    info "  → WLS Stack Patch Bundle: ${WLS_SPB_PATCH_NR:-(none configured)}"
    info "  → WLS patches: ${INSTALL_PATCHES:-see oracle_software_version.conf}"
    info "  06-oracle_patch_forms_reports.sh --apply"
    info "  → Reports patches: ${INSTALL_PATCHES_REPORTS:-(none configured)}"
    info "  → Forms patches:   ${INSTALL_PATCHES_FORMS:-(none configured)} (only if Forms is installed)"

fi

# =============================================================================
print_summary
exit $EXIT_CODE
