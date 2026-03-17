#!/bin/bash
# =============================================================================
# Script   : mos_sec.sh
# Purpose  : Store/load My Oracle Support (MOS) credentials encrypted with
#            machine UUID.  Use this to (re-)set the MOS e-mail + password
#            outside of the full installation interview.
#            Concept: https://www.pipperr.de/dokuwiki/doku.php?id=dba:passwort_verschluesselt_hinterlegen
# Call     : ./00-Setup/mos_sec.sh [--apply]
#            Without --apply: show status + test decryption (read-only).
#            With    --apply: interactively enter credentials and encrypt.
# Requires : openssl, /dev/disk/by-uuid (or /etc/machine-id fallback)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/docs/04-oracle_pre_download.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_SH="$SCRIPT_DIR/IHateWeblogic_lib.sh"
ENV_CONF="$ROOT_DIR/environment.conf"

# --- Source library -----------------------------------------------------------
if [ ! -f "$LIB_SH" ]; then
    printf "\033[31mFATAL\033[0m: Library not found: %s\n" "$LIB_SH" >&2
    exit 2
fi
# shellcheck source=./IHateWeblogic_lib.sh
source "$LIB_SH"

# --- Source environment.conf (if available) -----------------------------------
if [ -f "$ENV_CONF" ]; then
    # shellcheck source=../environment.conf
    source "$ENV_CONF"
else
    warn "environment.conf not found – using defaults"
    info "Run first: 00-Setup/env_check.sh --apply"
    SEC_CONF="$ROOT_DIR/mos_sec.conf.des3"
fi

# --- Arguments ----------------------------------------------------------------
APPLY=false
[[ "$*" == *"--apply"* ]] && APPLY=true

# --- Initialize log -----------------------------------------------------------
DIAG_LOG_DIR="${DIAG_LOG_DIR:-$ROOT_DIR/log/$(date +%Y%m%d)}"
init_log "$DIAG_LOG_DIR"

# =============================================================================
# Helper: prompt for password (twice for confirmation)
# Outputs ONLY the accepted password on stdout; all prompts go to stderr.
# =============================================================================
_prompt_password_confirmed() {
    local pw1="" pw2="x"

    while [ "$pw1" != "$pw2" ] || [ -z "$pw1" ]; do
        printf "  MOS password: " >&2
        read -rs pw1
        printf "\n" >&2

        if [ -z "$pw1" ]; then
            printf "  \033[33mPassword cannot be empty. Try again.\033[0m\n" >&2
            pw1="" pw2="x"
            continue
        fi

        printf "  Confirm password       : " >&2
        read -rs pw2
        printf "\n" >&2

        if [ "$pw1" != "$pw2" ]; then
            printf "  \033[33mPasswords do not match. Try again.\033[0m\n" >&2
            pw1="" pw2="x"
        fi
    done

    printf "%s" "$pw1"
}

# =============================================================================
# MAIN
# =============================================================================

MOS_SEC_FILE="${MOS_SEC_FILE:-$ROOT_DIR/mos_sec.conf.des3}"

printLine
printf "\n\033[1m  IHateWeblogic – MOS Credentials Setup\033[0m\n"          | tee -a "$LOG_FILE"
printf "  Concept : pipperr.de – openssl des3 + machine UUID key\n"         | tee -a "$LOG_FILE"
printf "  Host    : %s\n" "$(_get_hostname)"                                 | tee -a "$LOG_FILE"
printf "  Apply   : %s\n" "$APPLY"                                           | tee -a "$LOG_FILE"
printLine

# --------------------------------------------------------------------------
section "System Identifier"
info "Key derived from: disk UUID (/dev/disk/by-uuid) or /etc/machine-id"
info "This machine-unique key means credentials are only usable on THIS host."

SYS_ID="$(_get_system_identifier)"

if [ -n "$SYS_ID" ]; then
    ok "System identifier found"
    SYS_ID_MASKED="${SYS_ID:0:4}****${SYS_ID: -4}"
    printList "System ID (masked)" 30 "$SYS_ID_MASKED"
else
    fail "Cannot determine system identifier"
    fail "Check: ls -l /dev/disk/by-uuid/  or  cat /etc/machine-id"
    print_summary
    exit 2
fi

if ! command -v openssl > /dev/null 2>&1; then
    fail "openssl not found – required for encryption/decryption"
    print_summary
    exit 2
fi
ok "openssl found: $(openssl version)"

# --------------------------------------------------------------------------
section "Encrypted Credentials File"

printList "SEC_CONF path"  30 "$MOS_SEC_FILE"

if [ -f "$MOS_SEC_FILE" ]; then
    ok "Encrypted file exists"
    TS="$(stat -c '%y' "$MOS_SEC_FILE" 2>/dev/null | cut -d. -f1)"
    printList "Last modified" 30 "$TS"
    printList "File size"     30 "$(stat -c '%s' "$MOS_SEC_FILE" 2>/dev/null) bytes"
    info "Use --apply to overwrite with new credentials"
else
    info "No encrypted file found yet"
    if $APPLY; then
        info "Will create new encrypted credentials file"
    else
        warn "No credentials configured – run with --apply to create"
    fi
fi

# --------------------------------------------------------------------------
if $APPLY; then

    section "Enter MOS Credentials"
    info "Credentials are stored encrypted (openssl des3 -pbkdf2) on this machine only."
    printf "\n" | tee -a "$LOG_FILE"

    # --- MOS e-mail address ---
    CURRENT_USER="${MOS_USER:-}"
    if [ -n "$CURRENT_USER" ]; then
        printf "  MOS e-mail address [%s]: " "$CURRENT_USER" >&2
    else
        printf "  MOS e-mail address (required): " >&2
    fi
    read -r INPUT_USER
    INPUT_USER="${INPUT_USER:-$CURRENT_USER}"
    if [ -z "$INPUT_USER" ]; then
        fail "MOS e-mail address cannot be empty"
        print_summary; exit 2
    fi
    printList "MOS user" 30 "$INPUT_USER"

    # --- MOS password (with confirmation) ---
    INPUT_PW="$(_prompt_password_confirmed)"
    printList "MOS password" 30 "*** (${#INPUT_PW} chars)"

    # --- Confirm ---
    printf "\n"
    printLine
    printf "  About to save:\n" | tee -a "$LOG_FILE"
    printList "  MOS_USER"    28 "$INPUT_USER"
    printList "  MOS_PWD"     28 "*** (${#INPUT_PW} chars)"
    printList "  Target file" 28 "$MOS_SEC_FILE"
    printf "\n"

    if askYesNo "Save and encrypt MOS credentials?" "y"; then

        # --- Backup existing file if present ---
        if [ -f "$MOS_SEC_FILE" ]; then
            backup_file "$MOS_SEC_FILE" "$(dirname "$MOS_SEC_FILE")"
        fi

        # --- Encrypt via lib function ---
        section "Encrypting Credentials"
        _write_secrets_file "$MOS_SEC_FILE" \
            "MOS_USER=$INPUT_USER" \
            "MOS_PWD=$INPUT_PW"
        local_rc=$?

        # Immediately clear password from memory
        INPUT_PW="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        unset INPUT_PW

        if [ "$local_rc" -eq 0 ]; then
            # --- Verify: test decryption round-trip ---
            section "Verify Decryption (round-trip test)"
            unset MOS_USER MOS_PWD
            if load_secrets_file "$MOS_SEC_FILE"; then
                ok "Round-trip test passed – credentials verified"
                printList "  MOS_USER"    28 "${MOS_USER:-?}"
                printList "  MOS_PWD"     28 "*** (decrypted OK)"
                [ "${MOS_USER:-}" = "$INPUT_USER" ] \
                    && ok "User matches" \
                    || fail "User mismatch after decryption"
                unset MOS_PWD
            else
                fail "Round-trip decryption test failed"
            fi
        else
            fail "Encryption failed – credentials NOT saved"
        fi

    else
        info "Aborted – credentials NOT saved"
    fi

else
    # --------------------------------------------------------------------------
    # Read-only mode: test whether existing credentials can be decrypted
    section "Decryption Test (read-only)"

    if [ -f "$MOS_SEC_FILE" ]; then
        info "Testing decryption on this machine..."
        unset MOS_USER MOS_PWD
        if load_secrets_file "$MOS_SEC_FILE"; then
            ok "Credentials can be decrypted on this machine"
            printList "  MOS_USER" 28 "${MOS_USER:-?}"
            printList "  MOS_PWD"  28 "*** (decrypted OK)"
            unset MOS_PWD
        else
            fail "Decryption failed – wrong machine or corrupted file?"
            info "Tip: credentials encrypted on a different machine cannot be decrypted here."
            info "     Run with --apply on the original machine to re-create."
        fi
    else
        info "No credentials file to test"
        info "Run: ./00-Setup/mos_sec.sh --apply  to create credentials"
    fi

fi

# =============================================================================
print_summary
exit $EXIT_CODE
