#!/bin/bash
# =============================================================================
# Script   : IHateWeblogic_lib.sh
# Purpose  : Central library – output functions, password handling, environment helpers
# Usage    : source /path/to/00-Setup/IHateWeblogic_lib.sh
# Requires : openssl, hostname, tee, awk
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Version  : 1.0.0
# Ref      : https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/
# =============================================================================

# Guard: must be sourced, not executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf "\033[33mWARNING\033[0m: %s must be sourced, not executed directly.\n" \
        "$(basename "${BASH_SOURCE[0]}")"
    printf "  Usage: source %s\n" "${BASH_SOURCE[0]}"
    exit 1
fi

# =============================================================================
# Portable hostname helper (handles environments where hostname may not be in PATH)
# =============================================================================
_get_hostname() {
    hostname -f 2>/dev/null \
        || hostname 2>/dev/null \
        || cat /etc/hostname 2>/dev/null | tr -d '\n' \
        || printf "unknown"
}

# =============================================================================
# Global state (reset each time lib is sourced)
# =============================================================================
CNT_OK=0
CNT_WARN=0
CNT_FAIL=0
EXIT_CODE=0
LOG_FILE=""
LAST_BACKUP=""
SELECTION=""
SELECTION_IDX=0

# =============================================================================
# Output functions  (printf-based, tee to LOG_FILE if set)
# =============================================================================

# ok  message  – increment OK counter, print green OK line
ok() {
    CNT_OK=$((CNT_OK + 1))
    printf "\033[32m  OK\033[0m  %s\n" "$*" | tee -a "${LOG_FILE:-/dev/null}"
}

# warn  message  – increment WARN counter, print yellow WARN line
warn() {
    CNT_WARN=$((CNT_WARN + 1))
    printf "\033[33mWARN\033[0m  %s\n" "$*" | tee -a "${LOG_FILE:-/dev/null}"
}

# fail  message  – increment FAIL counter, print red FAIL line
fail() {
    CNT_FAIL=$((CNT_FAIL + 1))
    printf "\033[31mFAIL\033[0m  %s\n" "$*" | tee -a "${LOG_FILE:-/dev/null}"
}

# info  message  – print blue INFO line (no counter)
info() {
    printf "\033[34mINFO\033[0m  %s\n" "$*" | tee -a "${LOG_FILE:-/dev/null}"
}

# section  title  – print bold section header
section() {
    printf "\n\033[1m=== %s ===\033[0m\n" "$*" | tee -a "${LOG_FILE:-/dev/null}"
}

# printError  message  – print red ERROR to stderr
printError() {
    printf "\033[31mERROR\033[0m %s\n" "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2
}

# printLine  – magenta horizontal rule
printLine() {
    printf "\033[35m%s\033[0m\n" \
        "--------------------------------------------------------------------------------" \
        | tee -a "${LOG_FILE:-/dev/null}"
}

# printList  key  col_width  value  – aligned cyan key / value pair
printList() {
    local key="$1"
    local col_width="${2:-30}"
    local value="$3"
    printf "  \033[36m%-${col_width}s\033[0m %s\n" "$key" "$value" \
        | tee -a "${LOG_FILE:-/dev/null}"
}

# =============================================================================
# Interactive functions
# =============================================================================

# askYesNo  "prompt"  [default: y|n]
# Returns 0 (yes) or 1 (no).  Prompts and errors go to stderr.
askYesNo() {
    local prompt="${1:-Continue?}"
    local default="${2:-n}"
    local max_retries=3
    local answer
    local retry=0
    local hint

    [ "${default,,}" = "y" ] && hint="[Y/n]" || hint="[y/N]"

    while [ "$retry" -lt "$max_retries" ]; do
        printf "  %s %s: " "$prompt" "$hint" >&2
        read -r answer
        answer="${answer:-$default}"
        answer="${answer,,}"
        case "$answer" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)
                printf "  Please enter y or n.\n" >&2
                retry=$((retry + 1))
                ;;
        esac
    done

    # Max retries reached – fall back to default
    [ "${default,,}" = "y" ] && return 0 || return 1
}

# readSelection  "prompt"  default_idx  option1  option2  ...
# Sets SELECTION (text) and SELECTION_IDX (1-based).  Prompts go to stderr.
readSelection() {
    local prompt="$1"
    local default="$2"
    shift 2
    local options=("$@")
    local count="${#options[@]}"
    local max_retries=3
    local answer
    local retry=0
    local i

    printf "\n  %s\n" "$prompt" >&2
    for (( i = 0; i < count; i++ )); do
        printf "    [%d] %s\n" "$((i + 1))" "${options[$i]}" >&2
    done
    printf "  Selection [%s]: " "$default" >&2

    while [ "$retry" -lt "$max_retries" ]; do
        read -r answer
        answer="${answer:-$default}"
        if [[ "$answer" =~ ^[0-9]+$ ]] \
            && [ "$answer" -ge 1 ] \
            && [ "$answer" -le "$count" ]; then
            SELECTION="${options[$((answer - 1))]}"
            SELECTION_IDX="$answer"
            return 0
        fi
        printf "  Invalid. Enter 1-%d: " "$count" >&2
        retry=$((retry + 1))
    done

    # Fallback to default
    SELECTION="${options[$((default - 1))]}"
    SELECTION_IDX="$default"
    return 0
}

# =============================================================================
# Utility functions
# =============================================================================

# init_log  [log_dir]
# Creates log directory and sets LOG_FILE.  Must be called after DIAG_LOG_DIR is set.
init_log() {
    local log_dir="${1:-${DIAG_LOG_DIR:-/tmp/IHateWeblogic_log}}"

    mkdir -p "$log_dir" 2>/dev/null || {
        printf "\033[31mERROR\033[0m Cannot create log directory: %s\n" "$log_dir" >&2
        LOG_FILE="/dev/null"
        return 1
    }

    # Derive caller script name from the call stack
    local caller_name
    caller_name="$(basename "${BASH_SOURCE[1]:-script}" .sh)"
    LOG_FILE="${log_dir}/${caller_name}_$(date +%H%M%S).log"

    {
        printf "# IHateWeblogic Log\n"
        printf "# Script  : %s\n" "${BASH_SOURCE[1]:-unknown}"
        printf "# Host    : %s\n" "$(_get_hostname)"
        printf "# Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
        printf "# ---\n"
    } > "$LOG_FILE"

    return 0
}

# backup_file  source_file  [backup_dir]
# Copies file to backup_dir with timestamp suffix.  Sets LAST_BACKUP.
backup_file() {
    local file="$1"
    local backup_dir="${2:-$(dirname "$file")}"
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    local backup="${backup_dir}/$(basename "$file").bak_${ts}"

    if [ ! -f "$file" ]; then
        warn "backup_file: '$file' does not exist – nothing to backup"
        return 1
    fi

    if cp "$file" "$backup"; then
        ok "Backup created: $backup"
        LAST_BACKUP="$backup"
        return 0
    else
        fail "backup_file: failed to copy '$file' → '$backup'"
        return 1
    fi
}

# check_env_conf  [path_to_environment.conf]
# Returns 0 if found, 1 if missing (prints error).
check_env_conf() {
    local env_conf="${1:-${ENV_CONF:-}}"

    if [ -z "$env_conf" ]; then
        printError "ENV_CONF variable not set"
        return 1
    fi
    if [ ! -f "$env_conf" ]; then
        printError "environment.conf not found: $env_conf"
        printError "Run first: 00-Setup/env_check.sh --apply"
        return 1
    fi
    return 0
}

# print_summary
# Prints OK/WARN/FAIL counters and sets EXIT_CODE (0=OK, 1=WARN, 2=FAIL).
print_summary() {
    local exit_code=0

    printLine
    section "Summary"
    printf "  \033[32m OK : %3d\033[0m\n"  "${CNT_OK:-0}"   | tee -a "${LOG_FILE:-/dev/null}"
    printf "  \033[33mWARN: %3d\033[0m\n"  "${CNT_WARN:-0}" | tee -a "${LOG_FILE:-/dev/null}"
    printf "  \033[31mFAIL: %3d\033[0m\n"  "${CNT_FAIL:-0}" | tee -a "${LOG_FILE:-/dev/null}"

    [ "${CNT_FAIL:-0}" -gt 0 ]                           && exit_code=2
    [ "${CNT_WARN:-0}" -gt 0 ] && [ "$exit_code" -lt 1 ] && exit_code=1

    if [ -n "${LOG_FILE:-}" ] && [ "$LOG_FILE" != "/dev/null" ]; then
        printf "  Log : %s\n" "$LOG_FILE" | tee -a "$LOG_FILE"
    fi

    EXIT_CODE=$exit_code
    return $exit_code
}

# =============================================================================
# Security / Password functions  (pipperr.de concept)
# Source: https://www.pipperr.de/dokuwiki/doku.php?id=dba:passwort_verschluesselt_hinterlegen
# =============================================================================

# _get_system_identifier
# Returns machine-unique key derived from disk UUID (or /etc/machine-id as fallback).
_get_system_identifier() {
    local uuid
    uuid="$(ls -l /dev/disk/by-uuid/ 2>/dev/null | awk '{ print $9 }' | tail -1)"

    if [ -z "$uuid" ]; then
        # Fallback: /etc/machine-id (Oracle Linux always has this)
        uuid="$(cat /etc/machine-id 2>/dev/null)"
    fi
    if [ -z "$uuid" ]; then
        # Last resort: hostname
        uuid="$(_get_hostname)"
    fi

    printf "%s" "$uuid"
}

# =============================================================================
# Generic secret file helpers  (pipperr.de concept – same openssl des3 key)
# =============================================================================

# _write_secrets_file  des3_file  KEY=val [KEY2=val2 ...]
# Creates a shell-sourceable encrypted file.  Each positional argument after
# des3_file is written as:  export KEY="val"
# Plaintext intermediate file is deleted immediately after encryption.
_write_secrets_file() {
    local des3_file="$1"; shift
    local plaintext="${des3_file%.des3}"

    local sys_id
    sys_id="$(_get_system_identifier)"
    if [ -z "$sys_id" ]; then
        fail "Cannot determine system identifier for encryption"
        return 1
    fi

    # Build shell-sourceable plaintext
    : > "$plaintext"
    chmod 600 "$plaintext"
    local pair key val
    for pair in "$@"; do
        key="${pair%%=*}"
        val="${pair#*=}"
        printf 'export %s="%s"\n' "$key" "$val" >> "$plaintext"
    done

    openssl des3 -pbkdf2 -salt \
        -in  "$plaintext" \
        -out "$des3_file" \
        -pass pass:"${sys_id}" > /dev/null 2>&1
    local rc=$?
    rm -f "$plaintext"

    if [ "$rc" -ne 0 ]; then
        fail "openssl encryption failed (rc=$rc)"
        return 1
    fi

    chmod 600 "$des3_file"
    ok "Secrets saved (encrypted): $des3_file"
    return 0
}

# load_secrets_file  des3_file
# Decrypts a file written by _write_secrets_file and sources it.
# All export KEY="val" lines become available as shell variables.
# Plaintext intermediate file is deleted immediately after sourcing.
load_secrets_file() {
    local des3_file="$1"
    local plaintext="${des3_file%.des3}"

    if [ ! -f "$des3_file" ]; then
        fail "Encrypted secrets file not found: $des3_file"
        return 1
    fi

    local sys_id
    sys_id="$(_get_system_identifier)"
    if [ -z "$sys_id" ]; then
        fail "Cannot determine system identifier for decryption"
        return 1
    fi

    openssl des3 -pbkdf2 -d -salt \
        -in  "$des3_file" \
        -out "$plaintext" \
        -pass pass:"${sys_id}" > /dev/null 2>&1
    local rc=$?

    if [ "$rc" -ne 0 ]; then
        rm -f "$plaintext"
        fail "Decryption failed (rc=$rc) – wrong machine or corrupted file?"
        return 1
    fi

    # shellcheck source=/dev/null
    source "$plaintext"
    rm -f "$plaintext"
    return 0
}

# save_weblogic_password  wl_user  wl_password  [wl_admin_url]  [output_des3_file]
# Writes weblogic_sec.conf, encrypts to .des3, deletes plaintext immediately.
save_weblogic_password() {
    local wl_user="$1"
    local wl_password="$2"
    local wl_admin_url="${3:-t3://localhost:7001}"
    local sec_conf_des3="${4:-${SEC_CONF:-${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}/weblogic_sec.conf.des3}}"
    local plaintext="${sec_conf_des3%.des3}"

    local systemid
    systemid="$(_get_system_identifier)"

    if [ -z "$systemid" ]; then
        fail "Cannot determine system identifier for password encryption"
        return 1
    fi

    # Write plaintext config (mode 600)
    {
        printf 'export WL_USER="%s"\n'      "$wl_user"
        printf 'export WL_PASSWORD="%s"\n'  "$wl_password"
        printf 'export WL_ADMIN_URL="%s"\n' "$wl_admin_url"
    } > "$plaintext"
    chmod 600 "$plaintext"

    # Encrypt with openssl des3 -pbkdf2 (pipperr.de concept)
    openssl des3 -pbkdf2 -salt \
        -in  "$plaintext" \
        -out "$sec_conf_des3" \
        -pass pass:"${systemid}" > /dev/null 2>&1
    local rc=$?

    # Always delete plaintext immediately, regardless of outcome
    rm -f "$plaintext"

    if [ "$rc" -ne 0 ]; then
        fail "openssl encryption failed (rc=$rc)"
        return 1
    fi

    chmod 600 "$sec_conf_des3"
    ok "Credentials saved (encrypted): $sec_conf_des3"
    return 0
}

# load_weblogic_password  [des3_file]
# Decrypts, sources (exports WL_USER, WL_ADMIN_URL), deletes plaintext,
# copies password to INTERNAL_WL_PWD, redacts WL_PASSWORD.
load_weblogic_password() {
    local sec_conf_des3="${1:-${SEC_CONF:-${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}/weblogic_sec.conf.des3}}"
    local plaintext="${sec_conf_des3%.des3}"

    if [ ! -f "$sec_conf_des3" ]; then
        fail "Encrypted credentials not found: $sec_conf_des3"
        info "Run first: 00-Setup/weblogic_sec.sh --apply"
        return 1
    fi

    local systemid
    systemid="$(_get_system_identifier)"

    # Decrypt
    openssl des3 -pbkdf2 -d -salt \
        -in  "$sec_conf_des3" \
        -out "$plaintext" \
        -pass pass:"${systemid}" > /dev/null 2>&1
    local rc=$?

    if [ "$rc" -ne 0 ]; then
        rm -f "$plaintext"
        fail "Decryption failed (rc=$rc) – wrong machine or corrupted file?"
        return 1
    fi

    # Source and immediately delete plaintext
    # shellcheck source=/dev/null
    source "$plaintext"
    rm -f "$plaintext"

    # Move password to internal variable, redact exported variable
    INTERNAL_WL_PWD="${WL_PASSWORD}"
    export WL_PASSWORD="REDACTED"

    ok "Credentials loaded for user: ${WL_USER:-unknown}"
    return 0
}
