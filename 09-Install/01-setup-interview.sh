#!/bin/bash
# =============================================================================
# Script   : 01-setup-interview.sh
# Purpose  : Configuration interview – collect all installation parameters
#            interactively and write them to environment.conf.
#            Idempotent: prompts only for parameters not yet set.
#            Passwords are encrypted immediately – never stored in plaintext.
# Call     : ./09-Install/01-setup-interview.sh
#            ./09-Install/01-setup-interview.sh --apply
# Options  : --apply   Write environment.conf and encrypted password files
#            --reset   Clear 09-Install block and re-run full interview
#            --help    Show usage
# Runs as  : oracle
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 09-Install/docs/01-setup-interview.md
#            09-Install/docs/00-environment-setup.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"

LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m IHateWeblogic_lib.sh not found: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"

# --- Bootstrap log (environment.conf not yet available) ----------------------
LOG_BOOT_DIR="$ROOT_DIR/log/$(date +%Y%m%d)"
mkdir -p "$LOG_BOOT_DIR"
LOG_FILE="$LOG_BOOT_DIR/setup_interview_$(date +%H%M%S).log"
{
    printf "# 01-setup-interview.sh log\n"
    printf "# Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# Host    : %s\n" "$(_get_hostname)"
} > "$LOG_FILE"

# =============================================================================
# Arguments
# =============================================================================

APPLY_MODE=0
RESET_MODE=0

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-20s %s\n" "--apply"  "Write environment.conf and encrypt passwords"
    printf "  %-20s %s\n" "--reset"  "Re-ask all 09-Install parameters (clear existing block)"
    printf "  %-20s %s\n" "--help"   "Show this help"
    printf "\nWithout --apply: dry-run (shows planned values only).\n"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)    APPLY_MODE=1; shift ;;
        --reset)    RESET_MODE=1; shift ;;
        --help|-h)  _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
    esac
done

# =============================================================================
# Interview helpers
# =============================================================================

# _conf_get  var_name
# Read current value from environment.conf (if exists).
_conf_get() {
    local var="$1"
    [ -f "$ENV_CONF" ] || return 1
    grep -E "^${var}=" "$ENV_CONF" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'
}

# _conf_has  var_name
# Return 0 if var is already set in environment.conf (non-empty).
_conf_has() {
    local val
    val="$(_conf_get "$1")"
    [ -n "$val" ]
}

# _ask  var_name  label  default  [validate_func]  [optional=false]
# If already set in env.conf and not --reset: show and keep.
# Otherwise: prompt, validate, set global variable via eval.
# Pass "optional" as 5th argument to allow leaving the field empty.
_ask() {
    local var="$1"
    local label="$2"
    local default="$3"
    local validate_func="${4:-}"
    local optional="${5:-false}"

    # Already set – skip unless reset
    if _conf_has "$var" && [ "$RESET_MODE" -eq 0 ]; then
        local existing
        existing="$(_conf_get "$var")"
        eval "${var}=\"${existing}\""
        ok "$(printf "  %-30s %s  [kept]" "$var" "$existing")"
        return 0
    fi

    # In reset mode: use existing value as new default
    if [ "$RESET_MODE" -eq 1 ] && _conf_has "$var"; then
        default="$(_conf_get "$var")"
    fi

    local input=""
    local valid=false
    while ! $valid; do
        if [ -n "$default" ]; then
            printf "  \033[1m%-30s\033[0m [%s]: " "$label" "$default"
        elif [ "$optional" = "optional" ]; then
            printf "  \033[1m%-30s\033[0m (optional, Enter to skip): " "$label"
        else
            printf "  \033[1m%-30s\033[0m (required): " "$label"
        fi
        read -r input
        [ -z "$input" ] && input="$default"

        if [ -z "$input" ] && [ "$optional" != "optional" ]; then
            printf "  \033[31m  Required – please enter a value.\033[0m\n"
            continue
        fi

        if [ -n "$input" ] && [ -n "$validate_func" ] && ! "$validate_func" "$input"; then
            continue
        fi
        valid=true
    done

    eval "${var}=\"${input}\""
    if [ -n "$input" ]; then
        printf "  \033[32m  ✓  %s = %s\033[0m\n" "$var" "$input" | tee -a "$LOG_FILE"
    else
        printf "  \033[33m  –  %s  (skipped)\033[0m\n" "$var" | tee -a "$LOG_FILE"
    fi
}

# _ask_password  var_name  label  out_file
# Prompt for password twice (no echo). Skip if encrypted file already exists.
_ask_password() {
    local var="$1"
    local label="$2"
    local out_file="$3"

    if [ -f "$out_file" ] && [ "$RESET_MODE" -eq 0 ]; then
        eval "${var}=\"****\""
        ok "$(printf "  %-30s %s  [existing encrypted file]" "$var" "$(basename "$out_file")")"
        return 0
    fi

    local pw1="" pw2="x"
    while [ "$pw1" != "$pw2" ] || [ -z "$pw1" ]; do
        printf "  \033[1m%-30s\033[0m : " "$label"
        read -rs pw1; printf "\n"
        if [ -z "$pw1" ]; then
            printf "  \033[31m  Password cannot be empty.\033[0m\n"
            pw1="" pw2="x"; continue
        fi
        printf "  %-30s : " "Confirm $label"
        read -rs pw2; printf "\n"
        if [ "$pw1" != "$pw2" ]; then
            printf "  \033[31m  Passwords do not match. Try again.\033[0m\n"
            pw1="" pw2="x"
        fi
    done

    eval "${var}=\"${pw1}\""
    printf "  \033[32m  ✓  %s collected → %s\033[0m\n" \
        "$var" "$(basename "$out_file")" | tee -a "$LOG_FILE"
}

# _ask_list  array_var  primary_var  label  default
# Prompt for one or more string values (Enter on empty line to finish).
# Stores all values in the bash array $array_var; first value also in $primary_var.
# Idempotent: skips if $primary_var already set in env.conf (unless --reset).
_ask_list() {
    local array_var="$1"
    local primary_var="$2"
    local label="$3"
    local default="$4"

    if _conf_has "$primary_var" && [ "$RESET_MODE" -eq 0 ]; then
        local existing
        existing="$(_conf_get "$primary_var")"
        eval "${primary_var}=\"${existing}\""
        eval "${array_var}=(\"${existing}\")"
        ok "$(printf "  %-30s %s  [kept]" "$primary_var" "$existing")"
        return 0
    fi

    local items=() input _idx=1
    while true; do
        if [ "$_idx" -eq 1 ]; then
            printf "  \033[1m%-30s\033[0m [%s]: " "$label" "$default"
        else
            printf "  %-30s  additional (Enter to finish): " " "
        fi
        read -r input
        [ "$_idx" -eq 1 ] && [ -z "$input" ] && input="$default"
        [ -z "$input" ] && break
        items+=("$input")
        printf "  \033[32m  ✓  added: %s\033[0m\n" "$input" | tee -a "$LOG_FILE"
        _idx=$(( _idx + 1 ))
    done
    [ "${#items[@]}" -eq 0 ] && items=("$default")

    eval "${primary_var}=\"${items[0]}\""
    # shellcheck disable=SC2124
    eval "${array_var}=($(printf '"%s" ' "${items[@]}"))"
    printf "  \033[32m  ✓  %s: %d server(s) configured\033[0m\n" \
        "$primary_var" "${#items[@]}" | tee -a "$LOG_FILE"
}

# _ask_menu  var_name  label  key1:desc1  key2:desc2  ...
# Numbered menu – value set to the key part (before ':').
_ask_menu() {
    local var="$1"
    local label="$2"
    shift 2
    local options=("$@")

    if _conf_has "$var" && [ "$RESET_MODE" -eq 0 ]; then
        local existing
        existing="$(_conf_get "$var")"
        eval "${var}=\"${existing}\""
        ok "$(printf "  %-30s %s  [kept]" "$var" "$existing")"
        return 0
    fi

    printf "  \033[1m%s\033[0m\n" "$label"
    local i=1
    for opt in "${options[@]}"; do
        printf "    [%d] %s\n" "$i" "${opt#*:}"
        i=$(( i + 1 ))
    done

    local sel=""
    while true; do
        printf "  Selection [1]: "
        read -r sel
        [ -z "$sel" ] && sel=1
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#options[@]}" ]; then
            break
        fi
        printf "  \033[31m  Enter a number 1–%d.\033[0m\n" "${#options[@]}"
    done

    local key_val="${options[$(( sel - 1 ))]%%:*}"
    eval "${var}=\"${key_val}\""
    printf "  \033[32m  ✓  %s = %s\033[0m\n" "$var" "$key_val" | tee -a "$LOG_FILE"
}

# _encrypt_to_file  plaintext  out_file
# Encrypt using machine UUID as key (same as weblogic_sec.sh).
_encrypt_to_file() {
    local plaintext="$1"
    local out_file="$2"

    local sys_id
    sys_id="$(_get_system_identifier)"
    if [ -z "$sys_id" ]; then
        fail "Cannot determine system identifier for encryption"
        return 1
    fi

    local tmp
    tmp="$(mktemp)"
    printf "%s\n" "$plaintext" > "$tmp"
    if openssl des3 -pbkdf2 -salt \
        -in "$tmp" -out "$out_file" \
        -pass pass:"${sys_id}" 2>/dev/null; then
        chmod 600 "$out_file"
        rm -f "$tmp"
        return 0
    else
        rm -f "$tmp"
        fail "openssl encryption failed for $(basename "$out_file")"
        return 1
    fi
}

# =============================================================================
# Validation helpers
# =============================================================================

_val_dir() {
    local dir="$1"
    local parent
    parent="$(dirname "$dir")"
    if [ -d "$dir" ] && [ -w "$dir" ]; then return 0; fi
    if [ -d "$parent" ] && [ -w "$parent" ]; then return 0; fi
    printf "  \033[33m  Directory not writable or parent missing: %s\033[0m\n" "$dir"
    printf "  \033[33m  Will attempt to create during installation.\033[0m\n"
    printf "  \033[33m  Accept path anyway? [y/N]: \033[0m"
    local ans; read -r ans
    [[ "$ans" =~ ^[Yy] ]]
}

_val_jdk() {
    local jdk="$1"
    if [ -x "$jdk/bin/java" ]; then
        local ver
        ver="$("$jdk/bin/java" -version 2>&1 | head -1)"
        printf "  \033[32m     Found: %s\033[0m\n" "$ver"
        return 0
    fi
    printf "  \033[33m  JDK not found at: %s\033[0m\n" "$jdk"
    printf "  \033[33m  Acceptable if 02b-root_os_java.sh has not run yet.\033[0m\n"
    printf "  \033[33m  Accept path anyway? [y/N]: \033[0m"
    local ans; read -r ans
    [[ "$ans" =~ ^[Yy] ]]
}

_val_patch_storage() {
    local dir="$1"
    _val_dir "$dir" || return 1
    local check="$dir"
    while [ ! -d "$check" ] && [ "$check" != "/" ]; do
        check="$(dirname "$check")"
    done
    if [ -d "$check" ]; then
        local avail_gb
        avail_gb="$(df -BG "$check" 2>/dev/null | awk 'NR==2{gsub("G","",$4);print $4}')"
        if [ -n "$avail_gb" ] && [ "$avail_gb" -lt 20 ] 2>/dev/null; then
            printf "  \033[33m  Only %sG free (≥ 20G recommended for patches).\033[0m\n" "$avail_gb"
            printf "  \033[33m  Accept anyway? [y/N]: \033[0m"
            local ans; read -r ans
            [[ "$ans" =~ ^[Yy] ]] || return 1
        fi
    fi
    return 0
}

_val_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
        return 0
    fi
    printf "  \033[31m  Port must be numeric, 1024–65535.\033[0m\n"
    return 1
}

_val_host() {
    local host="$1"
    if [[ "$host" =~ ^[a-zA-Z0-9._-]+$ ]]; then return 0; fi
    printf "  \033[31m  Invalid hostname format: %s\033[0m\n" "$host"
    return 1
}

# =============================================================================
# Banner
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – Installation Setup Interview\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host    : %s\n" "$(_get_hostname)"                              | tee -a "$LOG_FILE"
printf "  Date    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"                  | tee -a "$LOG_FILE"
printf "  Log     : %s\n" "$LOG_FILE"                                      | tee -a "$LOG_FILE"
if [ "$APPLY_MODE" -eq 1 ]; then
    printf "  Mode    : APPLY (will write environment.conf)\n"             | tee -a "$LOG_FILE"
else
    printf "  Mode    : DRY-RUN (use --apply to write files)\n"            | tee -a "$LOG_FILE"
fi
[ "$RESET_MODE" -eq 1 ] && \
    printf "  Reset   : YES (09-Install parameters will be re-asked)\n"    | tee -a "$LOG_FILE"
printLine

if [ -f "$ENV_CONF" ]; then
    ok "Existing environment.conf found: $ENV_CONF"
    info "  Existing values are kept (use --reset to re-ask 09-Install block)"
    # Source to populate defaults for _ask
    # shellcheck disable=SC1090
    source "$ENV_CONF" 2>/dev/null || true
else
    info "No environment.conf found – fresh interview"
fi
printf "\n"

# =============================================================================
# Block 1 – Directories & Homes
# =============================================================================

section "Block 1 – Directories & Homes"

_ask ORACLE_BASE    "Oracle Base"               "/u01/app/oracle"                  "_val_dir"
_ask ORACLE_HOME    "Oracle Home (FMW)"         "${ORACLE_BASE}/fmw"               "_val_dir"
_ask JDK_HOME       "JDK 21 home (symlink)"     "${ORACLE_BASE}/java/jdk-21"       "_val_jdk"
_ask DOMAIN_HOME    "Domain directory"          "${ORACLE_BASE}/domains/fr_domain" "_val_dir"
_ask PATCH_STORAGE  "Patch storage directory"   "/srv/patch_storage"               "_val_patch_storage"

printf "\n"

# =============================================================================
# Block 2 – Component Selection
# =============================================================================

section "Block 2 – Component Selection"

_ask_menu INSTALL_COMPONENTS "What should be installed?" \
    "FORMS_AND_REPORTS:Forms and Reports (default)" \
    "FORMS_ONLY:Forms only" \
    "REPORTS_ONLY:Reports only"

printf "\n"

# =============================================================================
# Block 3 – Domain Configuration
# =============================================================================

section "Block 3 – Domain Configuration"

_ask WLS_ADMIN_USER          "WLS Admin username"           "webadmin"
_ask WLS_ADMIN_PORT          "WLS Admin port"               "7001"        "_val_port"
_ask WLS_NODEMANAGER_PORT    "NodeManager port"             "5556"        "_val_port"
_ask WLS_FORMS_PORT          "WLS_FORMS managed port"       "9001"        "_val_port"
_ask WLS_REPORTS_PORT        "WLS_REPORTS managed port"     "9002"        "_val_port"
_ask_list REPORTS_SERVER_NAMES REPORTS_SERVER_NAME \
    "Reports Server name(s)"  "repserver01"
_ask FORMS_CUSTOMER_DIR      "Forms customer directory"     "/app/forms/custom"
_ask REPORTS_CUSTOMER_DIR    "Reports customer directory"   "/app/reports/custom"

printf "\n"
info "WLS Admin password → encrypted to: weblogic_sec.conf.des3"
WLS_SEC_FILE="$ROOT_DIR/weblogic_sec.conf.des3"
_ask_password WLS_ADMIN_PWD "WLS Admin password" "$WLS_SEC_FILE"

printf "\n"

# =============================================================================
# Block 4 – Database (RCU)
# =============================================================================

section "Block 4 – Database (RCU)"

_ask DB_HOST          "Database hostname"         ""      "_val_host"
_ask DB_PORT          "Database listener port"    "1521"  "_val_port"
_ask DB_SERVICE       "Database service name"     ""
_ask DB_SCHEMA_PREFIX "RCU schema prefix"         "DEV"

printf "\n"
info "DB SYS password → encrypted to: db_sys_sec.conf.des3"
info "  Used only for RCU – not written to environment.conf"
DB_SYS_SEC_FILE="$ROOT_DIR/db_sys_sec.conf.des3"
_ask_password DB_SYS_PWD "DB SYS password" "$DB_SYS_SEC_FILE"

printf "\n"

# =============================================================================
# Block 5 – My Oracle Support
# =============================================================================

section "Block 5 – My Oracle Support"

_ask MOS_USER        "MOS e-mail address"                   ""

printf "\n"
info "MOS password → encrypted to: mos_sec.conf.des3"
MOS_SEC_FILE="$ROOT_DIR/mos_sec.conf.des3"
_ask_password MOS_PWD "MOS password" "$MOS_SEC_FILE"

printf "\n"

# =============================================================================
# Block 6 – Summary & Confirmation
# =============================================================================

section "Block 6 – Summary"

printLine
printf "\n  Values to write to environment.conf:\n\n"

_show() { printf "  %-30s = %s\n" "$1" "$2" | tee -a "$LOG_FILE"; }

_show "ORACLE_BASE"          "$ORACLE_BASE"
_show "ORACLE_HOME"          "$ORACLE_HOME"
_show "JDK_HOME"             "$JDK_HOME"
_show "DOMAIN_HOME"          "$DOMAIN_HOME"
_show "PATCH_STORAGE"        "$PATCH_STORAGE"
_show "INSTALL_COMPONENTS"   "$INSTALL_COMPONENTS"
_show "WLS_ADMIN_USER"       "$WLS_ADMIN_USER"
_show "WLS_ADMIN_PORT"       "$WLS_ADMIN_PORT"
_show "WLS_ADMIN_PWD"        "****  → $(basename "$WLS_SEC_FILE")"
_show "WLS_NODEMANAGER_PORT" "$WLS_NODEMANAGER_PORT"
_show "WLS_FORMS_PORT"       "$WLS_FORMS_PORT"
_show "WLS_REPORTS_PORT"     "$WLS_REPORTS_PORT"
_show "REPORTS_SERVER_NAME"  "$REPORTS_SERVER_NAME  (primary)"
for _s in "${REPORTS_SERVER_NAMES[@]:1}"; do
    _show "  + additional"  "$_s"
done
unset _s
_show "FORMS_CUSTOMER_DIR"   "$FORMS_CUSTOMER_DIR"
_show "REPORTS_CUSTOMER_DIR" "$REPORTS_CUSTOMER_DIR"
_show "DB_HOST"              "$DB_HOST"
_show "DB_PORT"              "$DB_PORT"
_show "DB_SERVICE"           "$DB_SERVICE"
_show "DB_SCHEMA_PREFIX"     "$DB_SCHEMA_PREFIX"
_show "DB_SYS_PWD"           "****  → $(basename "$DB_SYS_SEC_FILE")"
_show "MOS_USER"             "$MOS_USER"
_show "MOS_PWD"              "****  → $(basename "$MOS_SEC_FILE")"
info "  Patch numbers / download versions → 09-Install/oracle_software_version.conf"
printLine

if [ "$APPLY_MODE" -eq 0 ]; then
    warn "Dry-run – no files written. Re-run with --apply to write."
    print_summary
    exit "$EXIT_CODE"
fi

printf "\n  Write environment.conf and encrypt passwords? [y/N]: "
read -r CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
    warn "Aborted."
    print_summary
    exit 1
fi

# =============================================================================
# Write environment.conf – append 09-INSTALL block
# =============================================================================

if [ -f "$ENV_CONF" ]; then
    backup_file "$ENV_CONF" "$ROOT_DIR"
fi

# --reset: remove existing 09-INSTALL block before re-appending
if [ "$RESET_MODE" -eq 1 ] && [ -f "$ENV_CONF" ]; then
    sed -i '/^# === 09-INSTALL/,/^# === END 09-INSTALL/d' "$ENV_CONF" 2>/dev/null || true
fi

# Build REPORTS_SERVER_NAMES array string for env.conf
_SRV_ARRAY_STR=""
for _s in "${REPORTS_SERVER_NAMES[@]}"; do
    _SRV_ARRAY_STR="${_SRV_ARRAY_STR}  \"${_s}\"\n"
done
unset _s

# Append install parameters (touch creates the file if it does not yet exist)
touch "$ENV_CONF"
cat >> "$ENV_CONF" <<ENVEOF

# === 09-INSTALL: ORACLE INSTALLATION ===
# Generated : $(date '+%Y-%m-%d %H:%M:%S') – 09-Install/01-setup-interview.sh
# Host      : $(_get_hostname)

# --- Installation Paths -------------------------------------------------------
ORACLE_BASE="${ORACLE_BASE}"
ORACLE_HOME="${ORACLE_HOME}"
JDK_HOME="${JDK_HOME}"
PATCH_STORAGE="${PATCH_STORAGE}"

# --- Component Selection ------------------------------------------------------
INSTALL_COMPONENTS="${INSTALL_COMPONENTS}"

# --- WebLogic Domain ----------------------------------------------------------
DOMAIN_HOME="${DOMAIN_HOME}"
WLS_ADMIN_USER="${WLS_ADMIN_USER}"
WLS_ADMIN_PORT="${WLS_ADMIN_PORT}"
WLS_NODEMANAGER_PORT="${WLS_NODEMANAGER_PORT}"
WLS_FORMS_PORT="${WLS_FORMS_PORT}"
WLS_REPORTS_PORT="${WLS_REPORTS_PORT}"
REPORTS_SERVER_NAME="${REPORTS_SERVER_NAME}"
REPORTS_SERVER_NAMES=(
$(printf "%b" "$_SRV_ARRAY_STR"))
FORMS_CUSTOMER_DIR="${FORMS_CUSTOMER_DIR}"
REPORTS_CUSTOMER_DIR="${REPORTS_CUSTOMER_DIR}"

# --- Database (RCU) -----------------------------------------------------------
DB_HOST="${DB_HOST}"
DB_PORT="${DB_PORT}"
DB_SERVICE="${DB_SERVICE}"
DB_SCHEMA_PREFIX="${DB_SCHEMA_PREFIX}"
# DB_SYS_PWD → encrypted: db_sys_sec.conf.des3 (used only for RCU)
LOCAL_REP_DB="false"

# --- My Oracle Support --------------------------------------------------------
MOS_USER="${MOS_USER}"
# MOS_PWD → encrypted: mos_sec.conf.des3
# Patch numbers / software versions → 09-Install/oracle_software_version.conf

# === END 09-INSTALL ===
ENVEOF

chmod 600 "$ENV_CONF"
ok "environment.conf written: $ENV_CONF"

# =============================================================================
# Encrypt passwords
# =============================================================================

if [ -n "$WLS_ADMIN_PWD" ] && [ "$WLS_ADMIN_PWD" != "****" ]; then
    if _encrypt_to_file "$WLS_ADMIN_PWD" "$WLS_SEC_FILE"; then
        ok "WLS Admin password encrypted: $WLS_SEC_FILE"
    fi
fi

if [ -n "$MOS_PWD" ] && [ "$MOS_PWD" != "****" ]; then
    if _encrypt_to_file "$MOS_PWD" "$MOS_SEC_FILE"; then
        ok "MOS password encrypted: $MOS_SEC_FILE"
    fi
fi

if [ -n "$DB_SYS_PWD" ] && [ "$DB_SYS_PWD" != "****" ]; then
    if _encrypt_to_file "$DB_SYS_PWD" "$DB_SYS_SEC_FILE"; then
        ok "DB SYS password encrypted: $DB_SYS_SEC_FILE"
    fi
fi

# =============================================================================
# Write setup.conf – reusable template without passwords
# =============================================================================

SETUP_CONF="$ROOT_DIR/setup.conf"
cat > "$SETUP_CONF" <<SETUPEOF
# =============================================================================
# setup.conf – reusable installation template (no passwords)
# Generated : $(date '+%Y-%m-%d %H:%M:%S')
# Host      : $(_get_hostname)
# Use as    : cp setup.conf ../new-server/environment.conf  (then re-encrypt)
# =============================================================================
ORACLE_BASE="${ORACLE_BASE}"
ORACLE_HOME="${ORACLE_HOME}"
JDK_HOME="${JDK_HOME}"
DOMAIN_HOME="${DOMAIN_HOME}"
PATCH_STORAGE="${PATCH_STORAGE}"
INSTALL_COMPONENTS="${INSTALL_COMPONENTS}"
WLS_ADMIN_USER="${WLS_ADMIN_USER}"
WLS_ADMIN_PORT="${WLS_ADMIN_PORT}"
WLS_NODEMANAGER_PORT="${WLS_NODEMANAGER_PORT}"
WLS_FORMS_PORT="${WLS_FORMS_PORT}"
WLS_REPORTS_PORT="${WLS_REPORTS_PORT}"
REPORTS_SERVER_NAME="${REPORTS_SERVER_NAME}"
REPORTS_SERVER_NAMES=(
$(printf "%b" "$_SRV_ARRAY_STR"))
FORMS_CUSTOMER_DIR="${FORMS_CUSTOMER_DIR}"
REPORTS_CUSTOMER_DIR="${REPORTS_CUSTOMER_DIR}"
DB_HOST="${DB_HOST}"
DB_PORT="${DB_PORT}"
DB_SERVICE="${DB_SERVICE}"
DB_SCHEMA_PREFIX="${DB_SCHEMA_PREFIX}"
MOS_USER="${MOS_USER}"
# WLS_ADMIN_PWD → weblogic_sec.conf.des3
# MOS_PWD       → mos_sec.conf.des3
# DB_SYS_PWD    → db_sys_sec.conf.des3
# Software versions / patch numbers → 09-Install/oracle_software_version.conf
SETUPEOF

chmod 644 "$SETUP_CONF"
ok "Setup template written: $SETUP_CONF"

# =============================================================================
printLine
info "Next steps:"
info "  As root:"
info "    ./09-Install/00-root_os_network.sh --apply"
info "    ./09-Install/01-root_os_baseline.sh --apply   (→ REBOOT required)"
info "    ./09-Install/02-root_os_packages.sh --apply"
info "    ./09-Install/02b-root_os_java.sh --apply"
info "    ./09-Install/03-root_user_oracle.sh --apply"
info "  As oracle:"
info "    ./09-Install/04-oracle_pre_checks.sh"
printLine

print_summary
exit "$EXIT_CODE"
