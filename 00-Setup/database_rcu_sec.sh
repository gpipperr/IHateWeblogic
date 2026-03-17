#!/bin/bash
# =============================================================================
# Script   : database_rcu_sec.sh
# Purpose  : Store/load DB credentials for RCU, encrypted with machine UUID:
#              DB_SYS_PWD    – Oracle SYS password (SYSDBA, used only for RCU)
#              DB_SCHEMA_PWD – password for all FMW metadata schemas
#            Use this to (re-)set passwords outside of the full installation
#            interview.
#            Concept: https://www.pipperr.de/dokuwiki/doku.php?id=dba:passwort_verschluesselt_hinterlegen
# Call     : ./00-Setup/database_rcu_sec.sh [--apply]
#            Without --apply: show status + test decryption (read-only).
#            With    --apply: interactively enter password and encrypt.
# Requires : openssl, /dev/disk/by-uuid (or /etc/machine-id fallback)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/docs/07-oracle_setup_repository.md (RCU)
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
        printf "  DB SYS password: " >&2
        read -rs pw1
        printf "\n" >&2

        if [ -z "$pw1" ]; then
            printf "  \033[33mPassword cannot be empty. Try again.\033[0m\n" >&2
            pw1="" pw2="x"
            continue
        fi

        printf "  Confirm password : " >&2
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

DB_SYS_SEC_FILE="${DB_SYS_SEC_FILE:-$ROOT_DIR/db_sys_sec.conf.des3}"

printLine
printf "\n\033[1m  IHateWeblogic – Database RCU Credentials Setup\033[0m\n"    | tee -a "$LOG_FILE"
printf "  Concept : pipperr.de – openssl des3 + machine UUID key\n"           | tee -a "$LOG_FILE"
printf "  Host    : %s\n" "$(_get_hostname)"                                   | tee -a "$LOG_FILE"
printf "  Apply   : %s\n" "$APPLY"                                             | tee -a "$LOG_FILE"
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

printList "SEC_CONF path"  30 "$DB_SYS_SEC_FILE"

if [ -f "$DB_SYS_SEC_FILE" ]; then
    ok "Encrypted file exists"
    TS="$(stat -c '%y' "$DB_SYS_SEC_FILE" 2>/dev/null | cut -d. -f1)"
    printList "Last modified" 30 "$TS"
    printList "File size"     30 "$(stat -c '%s' "$DB_SYS_SEC_FILE" 2>/dev/null) bytes"
    if [ -n "${DB_HOST:-}" ]; then
        printList "DB_HOST"   30 "$DB_HOST"
        printList "DB_PORT"   30 "${DB_PORT:-1521}"
        printList "DB_SERVICE" 30 "${DB_SERVICE:-}"
    fi
    info "Use --apply to overwrite with new passwords"
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

    section "Enter DB Credentials for RCU"
    info "DB_SYS_PWD    – SYS password (SYSDBA, one-time RCU use only)"
    info "DB_SCHEMA_PWD – password assigned to all FMW metadata schemas (DEV_STB, DEV_MDS, …)"
    info "Both are stored in one encrypted file; connection info comes from environment.conf."
    printf "\n" | tee -a "$LOG_FILE"

    # --- Show connection context from environment.conf ---
    if [ -n "${DB_HOST:-}" ]; then
        printList "DB_HOST"          30 "$DB_HOST"
        printList "DB_PORT"          30 "${DB_PORT:-1521}"
        printList "DB_SERVICE"       30 "${DB_SERVICE:-}"
        printList "DB_SCHEMA_PREFIX" 30 "${DB_SCHEMA_PREFIX:-}"
        printf "\n"
    else
        info "DB_HOST not set in environment.conf – run 09-Install/01-setup-interview.sh first"
    fi

    # --- DB SYS password (with confirmation) ---
    printf "  \033[1mDB SYS password (SYSDBA):\033[0m\n"
    INPUT_SYS_PW="$(_prompt_password_confirmed)"
    printList "DB_SYS_PWD" 30 "*** (${#INPUT_SYS_PW} chars)"

    printf "\n"

    # --- FMW schema password (with confirmation) ---
    printf "  \033[1mFMW schema password (for all %s_* schemas):\033[0m\n" "${DB_SCHEMA_PREFIX:-PREFIX}"
    INPUT_SCHEMA_PW="$(_prompt_password_confirmed)"
    printList "DB_SCHEMA_PWD" 30 "*** (${#INPUT_SCHEMA_PW} chars)"

    # --- Confirm ---
    printf "\n"
    printLine
    printf "  About to save:\n" | tee -a "$LOG_FILE"
    printList "  DB_SYS_PWD"    28 "*** (${#INPUT_SYS_PW} chars)"
    printList "  DB_SCHEMA_PWD" 28 "*** (${#INPUT_SCHEMA_PW} chars)"
    printList "  Target file"   28 "$DB_SYS_SEC_FILE"
    printf "\n"

    if askYesNo "Save and encrypt DB credentials?" "y"; then

        # --- Backup existing file if present ---
        if [ -f "$DB_SYS_SEC_FILE" ]; then
            backup_file "$DB_SYS_SEC_FILE" "$(dirname "$DB_SYS_SEC_FILE")"
        fi

        # --- Encrypt both passwords via lib function ---
        section "Encrypting Credentials"
        _write_secrets_file "$DB_SYS_SEC_FILE" \
            "DB_SYS_PWD=$INPUT_SYS_PW" \
            "DB_SCHEMA_PWD=$INPUT_SCHEMA_PW"
        local_rc=$?

        # Immediately clear passwords from memory
        INPUT_SYS_PW="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        INPUT_SCHEMA_PW="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        unset INPUT_SYS_PW INPUT_SCHEMA_PW

        if [ "$local_rc" -eq 0 ]; then
            # --- Verify: test decryption round-trip ---
            section "Verify Decryption (round-trip test)"
            unset DB_SYS_PWD DB_SCHEMA_PWD
            if load_secrets_file "$DB_SYS_SEC_FILE"; then
                ok "Round-trip test passed – credentials verified"
                printList "  DB_SYS_PWD"    28 "*** (decrypted OK, ${#DB_SYS_PWD} chars)"
                printList "  DB_SCHEMA_PWD" 28 "*** (decrypted OK, ${#DB_SCHEMA_PWD} chars)"
                unset DB_SYS_PWD DB_SCHEMA_PWD
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
    # Read-only mode: test whether existing password can be decrypted
    section "Decryption Test (read-only)"

    if [ -f "$DB_SYS_SEC_FILE" ]; then
        info "Testing decryption on this machine..."
        unset DB_SYS_PWD DB_SCHEMA_PWD
        if load_secrets_file "$DB_SYS_SEC_FILE"; then
            ok "Credentials can be decrypted on this machine"
            printList "  DB_SYS_PWD"    28 "*** (${#DB_SYS_PWD} chars, decrypted OK)"
            printList "  DB_SCHEMA_PWD" 28 "*** (${#DB_SCHEMA_PWD} chars, decrypted OK)"
            unset DB_SYS_PWD DB_SCHEMA_PWD
        else
            fail "Decryption failed – wrong machine or corrupted file?"
            info "Tip: credentials encrypted on a different machine cannot be decrypted here."
            info "     Run with --apply on the original machine to re-create."
        fi
    else
        info "No credentials file to test"
        info "Run: ./00-Setup/database_rcu_sec.sh --apply  to create credentials"
    fi

fi

# =============================================================================
print_summary
exit $EXIT_CODE
