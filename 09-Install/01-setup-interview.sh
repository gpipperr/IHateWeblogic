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
        # Keep the full array already sourced from environment.conf; fall back
        # to the primary value only if the array was not defined there.
        local _cnt
        eval "_cnt=\${#${array_var}[@]}"
        [ "$_cnt" -eq 0 ] && eval "${array_var}=(\"${existing}\")"
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

# _derive_oracle_inventory  oracle_base
# Derive the Central Inventory path from ORACLE_BASE parent.
# Returns empty string when ORACLE_BASE is at depth 1 (parent = /).
_derive_oracle_inventory() {
    local base="$1"
    local parent
    parent="$(dirname "$base")"
    [ "$parent" = "/" ] && echo "" || echo "${parent}/oraInventory"
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

# ORACLE_INVENTORY: derive default from ORACLE_BASE parent (one level up)
# If ORACLE_BASE is at depth 1 (e.g. /oracle → parent=/), auto-derive would put
# the inventory at /oraInventory (root filesystem) — not acceptable.
_inv_default="$(_derive_oracle_inventory "$ORACLE_BASE")"
printf "\n"
info "Oracle Central Inventory – one level ABOVE ORACLE_BASE, shared by FMW + DB."
info "  Standard:  \$(dirname ORACLE_BASE)/oraInventory = ${_inv_default:-<cannot auto-derive>}"
info "  Created by root (03-root_user_oracle.sh) via /etc/oraInst.loc."
if [ -z "$_inv_default" ]; then
    warn "ORACLE_BASE '${ORACLE_BASE}' has depth 1 — cannot auto-derive ORACLE_INVENTORY."
    warn "  Oracle installer default would be /opt/oraInventory."
    _ask ORACLE_INVENTORY "Oracle Central Inventory" "/opt/oraInventory" "_val_dir"
else
    _ask ORACLE_INVENTORY "Oracle Central Inventory" "$_inv_default"    "_val_dir"
fi
# Post-validation: warn if inventory is inside ORACLE_BASE
case "$ORACLE_INVENTORY" in
    "${ORACLE_BASE}"/*|"${ORACLE_BASE}")
        warn "ORACLE_INVENTORY is inside ORACLE_BASE — Oracle standard requires it one level above."
        warn "  Recommended: $(dirname "$ORACLE_BASE")/oraInventory"
        ;;
esac
unset _inv_default

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

printf "\n"
info "WebLogic listen address – which network interface WebLogic binds to."
info "  Option 1 (localhost) requires NGINX as reverse proxy on the same host."
info "  Ref: 09-Install/docs/05-root_nginx_ssl.md"
_ask_menu WLS_LISTEN_ADDRESS "WLS listen address" \
    "localhost:localhost – NGINX handles external access + SSL (recommended)" \
    "0.0.0.0:0.0.0.0   – all interfaces, WebLogic exposed directly (no proxy)" \
    "custom:Custom      – enter hostname or IP manually"

if [ "${WLS_LISTEN_ADDRESS:-}" = "custom" ]; then
    _ask WLS_LISTEN_ADDRESS "WLS listen address (FQDN or IP)" "$(_get_hostname)"
fi

printf "\n"
_ask_list REPORTS_SERVER_NAMES REPORTS_SERVER_NAME \
    "Reports Server name(s)"  "repserver01"
_ask FORMS_CUSTOMER_DIR      "Forms module directory (.fmx/.fmb)" "${ORACLE_BASE}/forms/moduls"
_ask FORMS_TMP               "Forms temp directory (TMPDIR)" "${ORACLE_BASE}/forms/tmp"
_ask REPORTS_CUSTOMER_DIR    "Reports source directory (.rdf/.rep)" "${ORACLE_BASE}/reports/source"
_ask REPORTS_IMAGE_DIR       "Reports image directory"      "${ORACLE_BASE}/reports/images"

# Reports server security (13-oracle_setup_reports.sh, docs/13 Step 5a):
# ldap = securityId + JSE identity store -> WebLogic embedded LDAP, needs the
# password of the embedded LDAP administrator cn=Admin (13- sets it in the
# domain if it differs, then the AdminServer must be restarted once).
REPORTS_SECURITY="${REPORTS_SECURITY:-}"
EMBEDDED_LDAP_SEC_FILE="$ROOT_DIR/embedded_ldap_sec.conf.des3"
REPORTS_ADMIN_SEC_FILE="$ROOT_DIR/reports_admin_sec.conf.des3"
case "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" in
    FORMS_AND_REPORTS|REPORTS_ONLY)
        printf "\n"
        _ask_menu REPORTS_SECURITY "Reports server security" \
            "ldap:Secured - WebLogic users/roles (RW_MONITOR, RW_EXECREPORTS) via embedded LDAP (default)" \
            "identifier:Not secured - getserverinfo only for the <identifier> admin, no user check for reports"
        if [ "$REPORTS_SECURITY" = "ldap" ]; then
            info "Embedded LDAP admin (cn=Admin) password -> encrypted to: $(basename "$EMBEDDED_LDAP_SEC_FILE")"
            info "  letters and digits only - 13- sets it in the domain"
            _ask_password EMBEDDED_LDAP_PWD "Embedded LDAP cn=Admin password" "$EMBEDDED_LDAP_SEC_FILE"
        fi
        # Reports server administrator = rwserver.conf <identifier> (not a
        # WebLogic user): web commands with REPORTS_SECURITY=identifier,
        # emergency admin with ldap. 13- writes it from the des3 file.
        printf "\n"
        _ask REPORTS_ADMIN_USER "Reports server admin (<identifier>)" "rep_admin"
        info "Reports server admin password -> encrypted to: $(basename "$REPORTS_ADMIN_SEC_FILE")"
        info "  letters and digits only (no / & < > \" ' blank) - 13- writes it into rwserver.conf"
        _ask_password REPORTS_ADMIN_PWD "Reports server admin password" "$REPORTS_ADMIN_SEC_FILE"
        ;;
    *) REPORTS_SECURITY="${REPORTS_SECURITY:-identifier}" ;;
esac

printf "\n"
info "Sizes ulimits (nofile/nproc) for the oracle OS user – see"
info "  09-Install/docs/00-root_set_os_parameter.md for the full rationale."
info "  Only the 100-500 tier is a confirmed real-world production value;"
info "  the others are linear estimates around it."
_ask_menu EXPECTED_SESSIONS  "Expected concurrent Forms/Reports sessions" \
    "lt100:< 100 sessions (nofile/nproc 65536/16384)" \
    "100-500:100-500 sessions (nofile/nproc 81920/81920 – confirmed production reference)" \
    "500-1000:500-1000 sessions (nofile/nproc ~131072/~131072 – estimated, unconfirmed)" \
    "gt1000:> 1000 sessions (nofile/nproc ~262144/~262144 – lowest confidence, no real reference)"

case "$EXPECTED_SESSIONS" in
    lt100)     ULIMIT_NOFILE=65536;  ULIMIT_NPROC=16384  ;;
    100-500)   ULIMIT_NOFILE=81920;  ULIMIT_NPROC=81920  ;;
    500-1000)  ULIMIT_NOFILE=131072; ULIMIT_NPROC=131072 ;;
    gt1000)
        ULIMIT_NOFILE=262144
        ULIMIT_NPROC=262144
        warn "No real-world reference for >1000 sessions – 262144/262144 is a"
        warn "  cautious doubling of the (already estimated) 500-1000 tier, not a"
        warn "  measurement. Verify via capacity planning / load testing and"
        warn "  adjust ULIMIT_NOFILE/ULIMIT_NPROC in environment.conf if needed."
        ;;
esac

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

# LOCAL_REP_DB drives 01-root_os_baseline.sh: with "false" it comments out the
# large shm sysctl values a local Oracle DB needs – so detect, don't hardcode.
_local_db_detected="false"
_local_db_reason="no local DB instance, DB_HOST is remote"
if pgrep -f 'ora_pmon_' >/dev/null 2>&1; then
    _local_db_detected="true"
    _local_db_reason="ora_pmon running on this host"
else
    for _addr in localhost 127.0.0.1 "$(hostname -s 2>/dev/null)" "$(hostname -f 2>/dev/null)" \
                 $(hostname -I 2>/dev/null); do
        if [ -n "$_addr" ] && [ "$DB_HOST" = "$_addr" ]; then
            _local_db_detected="true"
            _local_db_reason="DB_HOST $DB_HOST is this host"
            break
        fi
    done
    unset _addr
fi
printf "\n"
info "Local repository DB detection: $_local_db_detected ($_local_db_reason)"
if [ "$_local_db_detected" = "true" ]; then
    _ask_menu LOCAL_REP_DB "Does an Oracle database run on THIS host?" \
        "true:Yes – DB on this host, keep its kernel/shm settings (detected)" \
        "false:No – DB is on a separate server"
else
    _ask_menu LOCAL_REP_DB "Does an Oracle database run on THIS host?" \
        "false:No – DB is on a separate server (detected)" \
        "true:Yes – DB on this host, keep its kernel/shm settings"
fi
unset _local_db_detected _local_db_reason

printf "\n"
info "RCU tablespace: leave empty → RCU creates its own tablespaces automatically"
info "  Set only if DBA pre-creates a dedicated tablespace (e.g. FMW_DATA)"
info "  See: 09-Install/docs/07-oracle_setup_repository.md"
_ask RCU_TABLESPACE      "RCU data tablespace (optional)" "" "" "optional"
_ask RCU_TEMP_TABLESPACE "RCU temp tablespace"            "TEMP"
printf "\n"
_ask_menu RCU_DB_TYPE "RCU database type" \
    "EBR:Oracle Database enabled for edition-based redefinition (default)" \
    "ORACLE:Oracle Database (no editions)"

printf "\n"
info "DB SYS + FMW schema passwords → encrypted to: db_sys_sec.conf.des3"
info "  DB_SYS_PWD    – SYS password, used only for RCU (one-time)"
info "  DB_SCHEMA_PWD – assigned to all FMW schemas (DEV_STB, DEV_MDS, …)"
DB_SYS_SEC_FILE="$ROOT_DIR/db_sys_sec.conf.des3"
_ask_password DB_SYS_PWD    "DB SYS password (SYSDBA)"         "$DB_SYS_SEC_FILE"
_ask_password DB_SCHEMA_PWD "FMW schema password (all schemas)" "$DB_SYS_SEC_FILE"

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
_show "ORACLE_INVENTORY"     "$ORACLE_INVENTORY"
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
_show "WLS_LISTEN_ADDRESS"   "$WLS_LISTEN_ADDRESS"
_show "REPORTS_SERVER_NAME"  "$REPORTS_SERVER_NAME  (primary)"
for _s in "${REPORTS_SERVER_NAMES[@]:1}"; do
    _show "  + additional"  "$_s"
done
unset _s
_show "FORMS_CUSTOMER_DIR"   "$FORMS_CUSTOMER_DIR"
_show "FORMS_TMP"            "$FORMS_TMP"
_show "REPORTS_CUSTOMER_DIR" "$REPORTS_CUSTOMER_DIR"
_show "REPORTS_IMAGE_DIR"    "$REPORTS_IMAGE_DIR"
_show "REPORTS_SECURITY"     "$REPORTS_SECURITY"
_show "REPORTS_ADMIN_USER"   "${REPORTS_ADMIN_USER:-}"
_show "EXPECTED_SESSIONS"    "$EXPECTED_SESSIONS"
_show "ULIMIT_NOFILE"        "${ULIMIT_NOFILE:-(unset – manual capacity planning)}"
_show "ULIMIT_NPROC"         "${ULIMIT_NPROC:-(unset – manual capacity planning)}"
_show "DB_HOST"              "$DB_HOST"
_show "DB_PORT"              "$DB_PORT"
_show "DB_SERVICE"           "$DB_SERVICE"
_show "DB_SCHEMA_PREFIX"     "$DB_SCHEMA_PREFIX"
_show "LOCAL_REP_DB"         "$LOCAL_REP_DB"
_show "RCU_TABLESPACE"       "${RCU_TABLESPACE:-(empty – RCU auto-creates)}"
_show "RCU_TEMP_TABLESPACE"  "$RCU_TEMP_TABLESPACE"
_show "RCU_DB_TYPE"          "${RCU_DB_TYPE:-EBR}"
_show "DB_SYS_PWD"           "****  → $(basename "$DB_SYS_SEC_FILE")"
_show "DB_SCHEMA_PWD"        "****  → $(basename "$DB_SYS_SEC_FILE")"
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

# Target layout (same as 00-Setup/init_env.sh, see 00-Setup/set_environment.md):
#   environment.conf  →  symlink to 00-Setup/environments/<basename DOMAIN_HOME>.conf
# Writing a plain file here would later be replaced by init_env.sh's symlink,
# silently dropping every interview value.
ENV_CONF_DIR="$ROOT_DIR/00-Setup/environments"
mkdir -p "$ENV_CONF_DIR"
if [ -L "$ENV_CONF" ]; then
    WRITE_CONF="$(readlink -f "$ENV_CONF")"
    info "environment.conf is a symlink – writing to its target: $WRITE_CONF"
else
    WRITE_CONF="$ENV_CONF_DIR/$(basename "$DOMAIN_HOME").conf"
    if [ -f "$ENV_CONF" ]; then
        if [ -e "$WRITE_CONF" ]; then
            fail "environment.conf is a plain file and $WRITE_CONF already exists – merge manually"
            print_summary
            exit 2
        fi
        mv "$ENV_CONF" "$WRITE_CONF" \
            && ok "Migrated plain environment.conf → $WRITE_CONF"
    fi
fi

if [ -f "$WRITE_CONF" ]; then
    backup_file "$WRITE_CONF" "$ENV_CONF_DIR"
fi

# Always replace an existing 09-INSTALL block (all its values were read and kept
# above) – appending a second block on every --apply run caused duplicates.
if [ -f "$WRITE_CONF" ]; then
    sed -i '/^# === 09-INSTALL/,/^# === END 09-INSTALL/d' "$WRITE_CONF" 2>/dev/null || true
fi

# Build REPORTS_SERVER_NAMES array string for env.conf
_SRV_ARRAY_STR=""
for _s in "${REPORTS_SERVER_NAMES[@]}"; do
    _SRV_ARRAY_STR="${_SRV_ARRAY_STR}  \"${_s}\"\n"
done
unset _s

# Append install parameters (touch creates the file if it does not yet exist)
touch "$WRITE_CONF"
cat >> "$WRITE_CONF" <<ENVEOF

# === 09-INSTALL: ORACLE INSTALLATION ===
# Generated : $(date '+%Y-%m-%d %H:%M:%S') – 09-Install/01-setup-interview.sh
# Host      : $(_get_hostname)

# --- Installation Paths -------------------------------------------------------
ORACLE_BASE="${ORACLE_BASE}"
# Central Oracle Inventory – one level above ORACLE_BASE (shared by FMW + DB)
# /etc/oraInst.loc (root-owned) points here; created by 03-root_user_oracle.sh
ORACLE_INVENTORY="${ORACLE_INVENTORY}"
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
# localhost = NGINX reverse proxy (recommended); 0.0.0.0 = all interfaces (no proxy)
WLS_LISTEN_ADDRESS="${WLS_LISTEN_ADDRESS}"
REPORTS_SERVER_NAME="${REPORTS_SERVER_NAME}"
REPORTS_SERVER_NAMES=(
$(printf "%b" "$_SRV_ARRAY_STR"))
FORMS_CUSTOMER_DIR="${FORMS_CUSTOMER_DIR}"
FORMS_TMP="${FORMS_TMP}"
REPORTS_CUSTOMER_DIR="${REPORTS_CUSTOMER_DIR}"
REPORTS_IMAGE_DIR="${REPORTS_IMAGE_DIR}"
# ldap = secured Reports server (EMBEDDED_LDAP_PWD -> embedded_ldap_sec.conf.des3)
REPORTS_SECURITY="${REPORTS_SECURITY}"
# Reports server admin = rwserver.conf <identifier> (password -> reports_admin_sec.conf.des3)
REPORTS_ADMIN_USER="${REPORTS_ADMIN_USER:-rep_admin}"

# --- ulimits (oracle OS user) -------------------------------------------------
# Sized from EXPECTED_SESSIONS; only the 100-500 tier (81920/81920) is a
# confirmed real-world production value. See docs/00-root_set_os_parameter.md.
EXPECTED_SESSIONS="${EXPECTED_SESSIONS}"
ULIMIT_NOFILE="${ULIMIT_NOFILE}"
ULIMIT_NPROC="${ULIMIT_NPROC}"

# --- Database (RCU) -----------------------------------------------------------
DB_HOST="${DB_HOST}"
DB_PORT="${DB_PORT}"
DB_SERVICE="${DB_SERVICE}"
DB_SCHEMA_PREFIX="${DB_SCHEMA_PREFIX}"
# RCU_TABLESPACE: empty = RCU creates its own tablespaces automatically
# Set to a DBA-pre-created tablespace name for enterprise/production installs
# See: 09-Install/docs/07-oracle_setup_repository.md
RCU_TABLESPACE="${RCU_TABLESPACE}"
RCU_TEMP_TABLESPACE="${RCU_TEMP_TABLESPACE}"
# RCU_DB_TYPE: EBR (editions enabled, default) | ORACLE - passed as -databaseType
RCU_DB_TYPE="${RCU_DB_TYPE:-EBR}"
# DB_SYS_PWD + DB_SCHEMA_PWD → encrypted: db_sys_sec.conf.des3
# true = Oracle DB on this host (01-root_os_baseline.sh keeps its shm/sysctl values)
LOCAL_REP_DB="${LOCAL_REP_DB}"

# --- My Oracle Support --------------------------------------------------------
MOS_USER="${MOS_USER}"
# MOS_PWD → encrypted: mos_sec.conf.des3
# Patch numbers / software versions → 09-Install/oracle_software_version.conf

# === END 09-INSTALL ===
ENVEOF

chmod 600 "$WRITE_CONF"
ok "Conf written: $WRITE_CONF"
if [ ! -L "$ENV_CONF" ]; then
    ln -sfn "$WRITE_CONF" "$ENV_CONF" && ok "Symlink: $ENV_CONF -> $WRITE_CONF"
fi

# =============================================================================
# Encrypt passwords
# =============================================================================

if [ -n "$WLS_ADMIN_PWD" ] && [ "$WLS_ADMIN_PWD" != "****" ]; then
    WLS_ADMIN_URL="t3://localhost:${WLS_ADMIN_PORT:-7001}"
    save_weblogic_password "$WLS_ADMIN_USER" "$WLS_ADMIN_PWD" "$WLS_ADMIN_URL" "$WLS_SEC_FILE"
    unset WLS_ADMIN_PWD
fi

if [ -n "${EMBEDDED_LDAP_PWD:-}" ] && [ "$EMBEDDED_LDAP_PWD" != "****" ]; then
    _write_secrets_file "$EMBEDDED_LDAP_SEC_FILE" \
        "EMBEDDED_LDAP_USER=cn=Admin" "EMBEDDED_LDAP_PWD=$EMBEDDED_LDAP_PWD"
    unset EMBEDDED_LDAP_PWD
fi

if [ -n "${REPORTS_ADMIN_PWD:-}" ] && [ "$REPORTS_ADMIN_PWD" != "****" ]; then
    _write_secrets_file "$REPORTS_ADMIN_SEC_FILE" \
        "REPORTS_ADMIN_USER=${REPORTS_ADMIN_USER:-rep_admin}" "REPORTS_ADMIN_PWD=$REPORTS_ADMIN_PWD"
    unset REPORTS_ADMIN_PWD
fi

if [ -n "$MOS_PWD" ] && [ "$MOS_PWD" != "****" ]; then
    _write_secrets_file "$MOS_SEC_FILE" "MOS_USER=$MOS_USER" "MOS_PWD=$MOS_PWD"
    unset MOS_PWD
fi

if [ -n "$DB_SYS_PWD" ] && [ "$DB_SYS_PWD" != "****" ]; then
    _write_secrets_file "$DB_SYS_SEC_FILE" \
        "DB_SYS_PWD=$DB_SYS_PWD" \
        "DB_SCHEMA_PWD=${DB_SCHEMA_PWD:-}"
    unset DB_SYS_PWD DB_SCHEMA_PWD
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
ORACLE_INVENTORY="${ORACLE_INVENTORY}"
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
WLS_LISTEN_ADDRESS="${WLS_LISTEN_ADDRESS}"
REPORTS_SERVER_NAME="${REPORTS_SERVER_NAME}"
REPORTS_SERVER_NAMES=(
$(printf "%b" "$_SRV_ARRAY_STR"))
FORMS_CUSTOMER_DIR="${FORMS_CUSTOMER_DIR}"
FORMS_TMP="${FORMS_TMP}"
REPORTS_CUSTOMER_DIR="${REPORTS_CUSTOMER_DIR}"
REPORTS_IMAGE_DIR="${REPORTS_IMAGE_DIR}"
# ldap = secured Reports server (EMBEDDED_LDAP_PWD -> embedded_ldap_sec.conf.des3)
REPORTS_SECURITY="${REPORTS_SECURITY}"
# Reports server admin = rwserver.conf <identifier> (password -> reports_admin_sec.conf.des3)
REPORTS_ADMIN_USER="${REPORTS_ADMIN_USER:-rep_admin}"
EXPECTED_SESSIONS="${EXPECTED_SESSIONS}"
ULIMIT_NOFILE="${ULIMIT_NOFILE}"
ULIMIT_NPROC="${ULIMIT_NPROC}"
DB_HOST="${DB_HOST}"
DB_PORT="${DB_PORT}"
DB_SERVICE="${DB_SERVICE}"
DB_SCHEMA_PREFIX="${DB_SCHEMA_PREFIX}"
LOCAL_REP_DB="${LOCAL_REP_DB}"
RCU_TABLESPACE="${RCU_TABLESPACE}"
RCU_TEMP_TABLESPACE="${RCU_TEMP_TABLESPACE}"
# RCU_DB_TYPE: EBR (editions enabled, default) | ORACLE - passed as -databaseType
RCU_DB_TYPE="${RCU_DB_TYPE:-EBR}"
MOS_USER="${MOS_USER}"
# WLS_ADMIN_PWD  → weblogic_sec.conf.des3
# MOS_PWD        → mos_sec.conf.des3
# DB_SYS_PWD + DB_SCHEMA_PWD → db_sys_sec.conf.des3
# EMBEDDED_LDAP_PWD → embedded_ldap_sec.conf.des3 (REPORTS_SECURITY=ldap)
# REPORTS_ADMIN_PWD → reports_admin_sec.conf.des3 (rwserver.conf <identifier>)
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
