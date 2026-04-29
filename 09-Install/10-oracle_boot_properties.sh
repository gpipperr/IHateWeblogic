#!/bin/bash
# =============================================================================
# Script   : 10-oracle_boot_properties.sh
# Purpose  : Create boot.properties for WebLogic AdminServer and managed
#            servers so that WebLogic starts without an interactive password
#            prompt.
#
#            WebLogic reads username/password from
#              $DOMAIN_HOME/servers/<server>/security/boot.properties
#            on startup and encrypts the plaintext file automatically
#            on the first successful start.
#
# Call     : ./09-Install/10-oracle_boot_properties.sh [--apply]
#
#            Without --apply : dry-run – show which files would be written
#            With    --apply : create security/ directories and boot.properties
#
# Requires : environment.conf (DOMAIN_HOME, WLS_MANAGED_SERVER)
#            weblogic_sec.conf.des3 (WebLogic admin credentials)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_SH="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"

# --- Source library -----------------------------------------------------------
if [ ! -f "$LIB_SH" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB_SH" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB_SH"

# --- Source environment.conf --------------------------------------------------
check_env_conf
# shellcheck source=../environment.conf
source "$ROOT_DIR/environment.conf"

# --- Arguments ----------------------------------------------------------------
APPLY=false
for _arg in "$@"; do
    case "$_arg" in
        --apply) APPLY=true ;;
        --help|-h)
            printf "Usage: %s [--apply]\n\n" "$(basename "$0")"
            printf "  %-14s %s\n" "--apply" "Write boot.properties to servers/<name>/security/"
            printf "\nWithout --apply: dry-run, no files written.\n"
            exit 0 ;;
        *) warn "Unknown argument: $_arg" ;;
    esac
done
unset _arg

# --- Log setup ----------------------------------------------------------------
LOG_FILE="$ROOT_DIR/log/$(date +%Y%m%d)/boot_properties_$(date +%H%M%S).log"
mkdir -p "$(dirname "$LOG_FILE")"
{
    printf "# 10-oracle_boot_properties.sh log\n"
    printf "# Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# Host    : %s\n" "$(_get_hostname)"
    printf "# Apply   : %s\n" "$APPLY"
} > "$LOG_FILE"

# =============================================================================
# Header
# =============================================================================
printLine
printf "\n\033[1m  IHateWeblogic – WebLogic boot.properties Setup\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"  | tee -a "$LOG_FILE"
printf "  DOMAIN_HOME : %s\n" "$DOMAIN_HOME"      | tee -a "$LOG_FILE"
printf "  Apply       : %s\n" "$APPLY"             | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"          | tee -a "$LOG_FILE"
printLine

# =============================================================================
# Validation
# =============================================================================
section "Checking prerequisites"

if [ -z "${DOMAIN_HOME:-}" ]; then
    fail "DOMAIN_HOME is not set in environment.conf"
    print_summary; exit "$EXIT_CODE"
fi

if [ ! -d "$DOMAIN_HOME" ]; then
    fail "DOMAIN_HOME directory does not exist: $DOMAIN_HOME"
    info "  Run 08-oracle_setup_domain.sh first"
    print_summary; exit "$EXIT_CODE"
fi
ok "DOMAIN_HOME exists: $DOMAIN_HOME"

if [ ! -d "$DOMAIN_HOME/servers" ]; then
    fail "No servers/ directory in domain – domain not yet configured?"
    print_summary; exit "$EXIT_CODE"
fi
ok "servers/ directory found"

# =============================================================================
# Load WebLogic credentials
# =============================================================================
section "Loading WebLogic credentials"

if ! load_weblogic_password; then
    fail "Cannot load WebLogic credentials"
    info "  Run first: 00-Setup/weblogic_sec.sh --apply"
    print_summary; exit "$EXIT_CODE"
fi

# load_weblogic_password sets INTERNAL_WL_PWD and WL_USER
if [ -z "${WL_USER:-}" ] || [ -z "${INTERNAL_WL_PWD:-}" ]; then
    fail "WL_USER or WL_PASSWORD empty after decryption"
    print_summary; exit "$EXIT_CODE"
fi
ok "Credentials ready for user: $WL_USER"

# =============================================================================
# Collect target servers
# =============================================================================
section "Collecting target servers"

# Always include AdminServer
BOOT_SERVERS=("AdminServer")

# Always include the Reports managed server
_ms="${WLS_MANAGED_SERVER:-WLS_REPORTS}"
BOOT_SERVERS+=("$_ms")
unset _ms

# Add WLS_FORMS if it has a server directory
for _srv_dir in "$DOMAIN_HOME/servers"/WLS_FORMS*; do
    if [ -d "$_srv_dir" ]; then
        _srv="$(basename "$_srv_dir")"
        BOOT_SERVERS+=("$_srv")
        info "Additional managed server found: $_srv"
    fi
done
unset _srv_dir _srv

for srv in "${BOOT_SERVERS[@]}"; do
    printList "  Server" 20 "$srv"
done

# =============================================================================
# Write boot.properties
# =============================================================================
section "Writing boot.properties files"

_write_boot_properties() {
    local server="$1"
    local sec_dir="$DOMAIN_HOME/servers/$server/security"
    local boot_file="$sec_dir/boot.properties"

    printf "\n" | tee -a "$LOG_FILE"
    printList "Server" 24 "$server" | tee -a "$LOG_FILE"
    printList "Target" 24 "$boot_file" | tee -a "$LOG_FILE"

    # Check: server directory must exist (domain is configured)
    if [ ! -d "$DOMAIN_HOME/servers/$server" ]; then
        warn "Server directory not found: $DOMAIN_HOME/servers/$server"
        info "  Start AdminServer once so WebLogic creates the server directories,"
        info "  then re-run this script."
        return
    fi

    # Check: is file already present?
    if [ -f "$boot_file" ]; then
        # Check if already encrypted (WebLogic-encrypted lines start with {AES})
        if grep -q '{AES}' "$boot_file" 2>/dev/null; then
            ok "boot.properties already encrypted by WebLogic – skipping"
            return
        fi
        warn "boot.properties exists (plaintext) – will overwrite"
    fi

    if $APPLY; then
        mkdir -p "$sec_dir"
        chmod 750 "$sec_dir"

        # Write plaintext – WebLogic encrypts this on first successful start
        printf "username=%s\npassword=%s\n" "$WL_USER" "$INTERNAL_WL_PWD" \
            > "$boot_file"
        chmod 600 "$boot_file"

        ok "Written: $boot_file"
        info "  Permissions: 600 (owner only)"
        info "  WebLogic will encrypt this file on the next successful start"
    else
        info "  Dry-run – would write: $boot_file"
        info "  Content:  username=$WL_USER  password=***"
    fi
}

for srv in "${BOOT_SERVERS[@]}"; do
    _write_boot_properties "$srv"
done

# Wipe password from memory
INTERNAL_WL_PWD=""

# =============================================================================
printf "\n" | tee -a "$LOG_FILE"
printLine
if $APPLY; then
    info "Note: boot.properties contain the password in plaintext until"
    info "WebLogic rewrites the file on its first successful start."
    info "Files are protected with permissions 600 (oracle owner only)."
else
    warn "Dry-run – use --apply to create boot.properties files"
fi

print_summary
exit "$EXIT_CODE"
