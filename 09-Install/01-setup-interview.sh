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
# shellcheck source=../06-FormsDiag/forms_lib.sh
source "$ROOT_DIR/06-FormsDiag/forms_lib.sh"   # frm_mrp_proposal

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

_val_patch_archive() {
    local dir="$1"
    if [ ! -d "$dir" ] || [ ! -r "$dir" ]; then
        printf "  \033[31m  Not a readable directory: %s (mount the NFS/ZFS share first).\033[0m\n" "$dir"
        return 1
    fi
    if [ "$(cd "$dir" && pwd -P)" = "$(cd "${PATCH_STORAGE:-/nonexistent}" 2>/dev/null && pwd -P)" ]; then
        printf "  \033[31m  Same directory as PATCH_STORAGE – the archive must be another place.\033[0m\n"
        return 1
    fi
    [ -w "$dir" ] || printf "  \033[33m  Not writable – pull works, clean cannot move files into it.\033[0m\n"
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

_val_env_type() {
    case "$1" in test|prod) return 0 ;; esac
    printf "  \033[31m  Environment type must be test or prod.\033[0m\n"
    return 1
}

_val_mrp() {
    if [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ]; then
        return 0
    fi
    printf "  \033[31m  Number >= 1 (0 = no limit is not allowed here - Oracle: DoS risk).\033[0m\n"
    return 1
}

_val_url_path() {
    local path="$1"
    if [[ "$path" =~ ^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] && [ "$path" != "/forms" ] \
            && [ "$path" != "/reports" ]; then
        return 0
    fi
    printf "  \033[31m  URL path must start with /, no trailing /, not /forms or /reports.\033[0m\n"
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
# Optional archive (NFS / ZFS, same layout as PATCH_STORAGE) = master copy of all
# installers + patches; PATCH_STORAGE is then only the fast local working copy:
# 07-Maintenance/patch_storage.sh pull <step> before, clean after a step
info "  Patch archive: NFS/ZFS mount holding ALL installers/patches (too slow to install from)."
info "  Empty = no archive, everything stays in PATCH_STORAGE."
_ask PATCH_ARCHIVE  "Patch archive (NFS/ZFS)"   ""                                 "_val_patch_archive" "optional"
# test = Claude Code may run here (guarded); prod = never (10-Monitoring/setup_claude.md)
_ask IHW_ENV_TYPE   "Environment type (test|prod)" "prod"                          "_val_env_type"
# One Oracle Net directory (tnsnames.ora / sqlnet.ora) for every process:
# Forms default.env (14-), rwserver.conf + reports.sh (13-), setUserOverrides.sh
# (02-Checks/tns_admin_check.sh), oracle .bash_profile (03-)
_ask TNS_ADMIN      "Oracle Net dir (TNS_ADMIN)" "${ORACLE_BASE}/admin/tns_names"   "_val_dir"

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

info "Public server name – the name the users type in the URL; it must be in the"
info "  certificate (SAN). Differs from the host name in the cloud / with a DNS alias"
info "  (host.subnet.vcn.oraclevcn.com vs. forms.company.com) – Nginx, SSL, client + ORDS URLs"
_ask WLS_SERVER_FQDN         "Public server name (URL / certificate)" "$(hostname -f 2>/dev/null || _get_hostname)" "_val_host"
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

# Forms WebUtil OLE (JACOB) + code signing of jacob.jar (14-oracle_setup_forms.sh,
# docs/14 Step 1). Keystore exists -> alias + password (des3), checked here.
# Keystore missing -> created in 14- by the local CA (08-SSL/ssl_local_ca.sh);
# its subject values go into 08-SSL/ssl.conf (the SSL module's config).
SSL_CONF="$ROOT_DIR/08-SSL/ssl.conf"
FORMS_SIGN_SEC_FILE="$ROOT_DIR/forms_sign_sec.conf.des3"
SSL_CONF_KEYS=()
# Certificate source (08-SSL/ssl.conf): own root CA of this library or the
# customer's PKI (files in 08-SSL/user_certs/, 08-SSL/ssl_customer_certs.sh)
printf "\n"
info "Certificates for Nginx (TLS) and code signing: own root CA or the customer's PKI"
ENV_CONF="$SSL_CONF" _ask_menu SSL_CERT_SOURCE "Certificate source" \
    "localca:Own root CA of this library (08-SSL/ssl_local_ca.sh) - lab / internal (default)" \
    "customer:Customer PKI - files in 08-SSL/user_certs/, import: 08-SSL/ssl_customer_certs.sh --apply"
SSL_CONF_KEYS+=(SSL_CERT_SOURCE)
if [ "$SSL_CERT_SOURCE" = "customer" ]; then
    info "  Put the customer files into 08-SSL/user_certs/ (README there: names, what to request),"
    info "  then: ./08-SSL/ssl_customer_certs.sh  (check)  and  --apply  (import)"
fi
case "${INSTALL_COMPONENTS:-FORMS_AND_REPORTS}" in
    FORMS_AND_REPORTS|FORMS_ONLY)
        # Session limit (formsweb.cfg [default] maxRuntimeProcesses) - Oracle:
        # 0 = no limit = vulnerable to Denial of Service. Proposal from RAM.
        printf "\n"
        info "Forms session limit maxRuntimeProcesses - proposal: half of the RAM / 64 MB per session"
        info "  (correct it later with real sessions: 06-FormsDiag/forms_perf_analyse.sh)"
        _ask FORMS_MAX_RUNTIME_PROCESSES "Max. Forms sessions (maxRuntimeProcesses)" "$(frm_mrp_proposal)" "_val_mrp"
        printf "\n"
        _ask_menu FORMS_WEBUTIL_JACOB "WebUtil OLE / Office automation (JACOB, CLIENT_OLE2)" \
            "false:No - not needed (default)" \
            "true:Yes - install JACOB and sign jacob.jar"
        # Forms client distribution via URL (concept docs/40-forms_client_distribution.md):
        # Nginx serves Java runtime + frmsal.jar + JACOB + trust from FORMS_CLIENT_DIR
        printf "\n"
        _ask_menu FORMS_CLIENT_DIST "Forms client distribution via URL (Java + FSAL, concept 40)" \
            "false:No - clients are installed otherwise (default)" \
            "true:Yes - serve the client bundle through Nginx"
        if [ "${FORMS_CLIENT_DIST:-false}" = "true" ]; then
            _ask FORMS_CLIENT_DIR      "Client bundle directory (Nginx)" "/srv/formsWeb"   "_val_dir"
            _ask FORMS_CLIENT_URL_PATH "Client bundle URL path"          "/formsWeb"       "_val_url_path"
            _ask FORMS_CLIENT_BASE_URL "Server URL used by the clients"  \
                "https://${WLS_SERVER_FQDN:-$(_get_hostname)}"
            _ask FORMS_CLIENT_CONFIG   "formsweb.cfg section for FSAL"   "standaloneapp"
            _ask FORMS_CLIENT_FORM     "Start form (empty = section)"    ""  "" "optional"
            _ask FORMS_CLIENT_APP_NAME "Desktop shortcut name"           "Oracle Forms"
            info "Shortcut icon: .ico or .png (<= 256 px), local path or https URL"
            info "  (URL: 04-oracle_pre_download.sh loads it into \$PATCH_STORAGE/icon/;"
            info "   default IHateWeblogic.ico is copied there by 04- from forms_templates/)"
            _ask FORMS_CLIENT_ICON     "Shortcut icon (path or URL)"     \
                "${PATCH_STORAGE}/icon/IHateWeblogic.ico" "" "optional"
            _ask_menu FORMS_CLIENT_RUNTIME "Java runtime for the clients" \
                "jlink:Slim runtime built with jlink (default)" \
                "jdk:Full JDK ZIP"
            _ca_def="${SSL_CA_DIR:-$(ENV_CONF="$SSL_CONF" _conf_get SSL_CA_DIR)}"
            if [ "$SSL_CERT_SOURCE" = "customer" ]; then
                _ca_def="${_ca_def:-${ORACLE_BASE}/admin/pki}/customer/root.crt"   # written by ssl_customer_certs.sh
            else
                _ca_def="${_ca_def:-${ORACLE_BASE}/admin/pki}/ca/ca.crt"
                [ -f "$_ca_def" ] || _ca_def=""
            fi
            info "CA certificate for the client truststore - empty = public CA (already trusted)"
            _ask FORMS_CLIENT_TRUST_CA "Client truststore CA (.crt)"     "$_ca_def" "" "optional"
            unset _ca_def
        fi
        ;;
    *)
        FORMS_WEBUTIL_JACOB="${FORMS_WEBUTIL_JACOB:-false}"
        FORMS_CLIENT_DIST="false"   # Reports only: no Forms client
        ;;
esac
FORMS_CLIENT_DIST="${FORMS_CLIENT_DIST:-false}"

if [ "${FORMS_WEBUTIL_JACOB:-false}" = "true" ] || [ "$FORMS_CLIENT_DIST" = "true" ]; then
    _ca_dir="${SSL_CA_DIR:-$(ENV_CONF="$SSL_CONF" _conf_get SSL_CA_DIR)}"
    _ca_dir="${_ca_dir:-${ORACLE_BASE}/admin/pki}"
    info "Code-signing keystore (PKCS12) for jacob.jar and the client setup script"
    info "  - existing (company / public CA)"
    info "  or created by the own root CA in 14- if the file does not exist"
    if [ "$SSL_CERT_SOURCE" = "customer" ]; then
        _ask FORMS_SIGN_KEYSTORE "Code-signing keystore (.p12)" "${_ca_dir}/customer/codesign.p12"
    else
        _ask FORMS_SIGN_KEYSTORE "Code-signing keystore (.p12)" "${_ca_dir}/codesign/codesign.p12"
    fi
    _ask FORMS_SIGN_ALIAS    "Keystore alias"               "forms_codesign"

    if [ ! -f "$FORMS_SIGN_KEYSTORE" ] && [ "$SSL_CERT_SOURCE" = "customer" ]; then
        # customer PKI: the PFX comes from 08-SSL/user_certs/codesign.p12 –
        # ssl_customer_certs.sh --apply copies it here and stores alias + password
        FORMS_SIGN_LOCALCA="false"
        info "Keystore not imported yet - put codesign.p12 into 08-SSL/user_certs/ and run"
        info "  ./08-SSL/ssl_customer_certs.sh --only codesign --apply (sets alias + password)"
    elif [ -f "$FORMS_SIGN_KEYSTORE" ]; then
        FORMS_SIGN_LOCALCA="false"
        ok "$(printf "  %-30s %s" "keystore found" "$FORMS_SIGN_KEYSTORE")"
        info "Keystore password -> encrypted to: $(basename "$FORMS_SIGN_SEC_FILE")"
        # Check: keystore opens with the password and contains the alias
        # (password via temp file). A typed password gets 3 attempts; a wrong
        # one is never written to the des3 file.
        _ks_pw="$(mktemp)"; chmod 600 "$_ks_pw"
        _try=1
        while :; do
            _ask_password FORMS_SIGN_STOREPASS "Keystore password" "$FORMS_SIGN_SEC_FILE"
            if [ "$FORMS_SIGN_STOREPASS" = "****" ]; then
                ( load_secrets_file "$FORMS_SIGN_SEC_FILE" >/dev/null 2>&1 \
                    && printf '%s\n' "${FORMS_SIGN_STOREPASS:-}" > "$_ks_pw" )
            else
                printf '%s\n' "$FORMS_SIGN_STOREPASS" > "$_ks_pw"
            fi
            openssl pkcs12 -in "$FORMS_SIGN_KEYSTORE" -nokeys -passin "file:$_ks_pw" \
                -out /dev/null 2>/dev/null && break
            if [ "$FORMS_SIGN_STOREPASS" = "****" ]; then
                warn "Keystore does not open with the password in $(basename "$FORMS_SIGN_SEC_FILE")"
                info "  Re-run with --reset (or delete $(basename "$FORMS_SIGN_SEC_FILE")) to enter it again"
                break
            fi
            if [ "$_try" -ge 3 ]; then
                fail "Keystore does not open with this password – password NOT saved"
                FORMS_SIGN_STOREPASS=""
                break
            fi
            warn "Keystore does not open with this password – try again ($_try/3)"
            _try=$(( _try + 1 ))
        done
        if [ -n "$FORMS_SIGN_STOREPASS" ] && openssl pkcs12 -in "$FORMS_SIGN_KEYSTORE" -nokeys \
                -passin "file:$_ks_pw" -out /dev/null 2>/dev/null; then
            if openssl pkcs12 -in "$FORMS_SIGN_KEYSTORE" -nokeys -passin "file:$_ks_pw" 2>/dev/null \
                    | grep -q "friendlyName: ${FORMS_SIGN_ALIAS}\$"; then
                ok "$(printf "  %-30s %s" "keystore check" "opens, alias ${FORMS_SIGN_ALIAS} present")"
            else
                warn "Alias '${FORMS_SIGN_ALIAS}' not found in $FORMS_SIGN_KEYSTORE"
                info "  List aliases: keytool -list -keystore $FORMS_SIGN_KEYSTORE -storetype PKCS12"
            fi
        fi
        rm -f "$_ks_pw"; unset _ks_pw _try
    else
        FORMS_SIGN_LOCALCA="true"
        info "Keystore not found - 14- creates it with the own root CA (08-SSL/ssl_local_ca.sh)."
        info "  Subject values -> 08-SSL/ssl.conf; keystore password is generated (des3)."
        info "  The root (ca.cer) must later be imported on every client once."
        # Defaults/kept values come from ssl.conf (ENV_CONF redirected for _ask)
        ENV_CONF="$SSL_CONF" _ask SSL_ORG     "Organization (certificate O=)" "Company GmbH"
        ENV_CONF="$SSL_CONF" _ask SSL_COUNTRY "Country (2 letters)"           "DE"
        SSL_CONF_KEYS+=(SSL_ORG SSL_COUNTRY)
        if [ ! -f "${_ca_dir}/ca/ca.crt" ]; then
            ENV_CONF="$SSL_CONF" _ask SSL_CA_CN "Root CA name (new CA)" "${SSL_ORG} Root CA"
            SSL_CONF_KEYS+=(SSL_CA_CN)
        else
            ok "$(printf "  %-30s %s" "root CA exists" "${_ca_dir}/ca/ca.crt")"
        fi
        ENV_CONF="$SSL_CONF" _ask SSL_CODESIGN_CN   "Code-signing certificate name" "${SSL_ORG} Forms Code Signing"
        ENV_CONF="$SSL_CONF" _ask SSL_CODESIGN_DAYS "Code-signing validity (days)"  "1095"
        SSL_CONF_KEYS+=(SSL_CODESIGN_CN SSL_CODESIGN_DAYS)
    fi
    info "Timestamp authority: signatures stay valid after the certificate expires;"
    info "  needs outbound HTTP from this server. Empty = no timestamp (not for production)."
    _ask FORMS_SIGN_TSA_URL "Timestamp URL (jarsigner -tsa)" "http://timestamp.digicert.com" "" "optional"
    unset _ca_dir
else
    FORMS_SIGN_KEYSTORE="${FORMS_SIGN_KEYSTORE:-}"
    FORMS_SIGN_ALIAS="${FORMS_SIGN_ALIAS:-forms_codesign}"
    FORMS_SIGN_TSA_URL="${FORMS_SIGN_TSA_URL:-}"
    FORMS_SIGN_LOCALCA="${FORMS_SIGN_LOCALCA:-false}"
fi

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
# Block 4b – APEX / ORDS (optional, 12-APEX-Ords/README.md)
# =============================================================================

section "Block 4b – APEX / ORDS (optional)"
APEX_SEC_FILE="$ROOT_DIR/apex_sec.conf.des3"
_ask_menu INSTALL_APEX "Oracle APEX + ORDS beside Forms (12-APEX-Ords)" \
    "false:No (default)" \
    "true:Yes - 04- downloads APEX / ORDS, values for the first ORDS (ords_1)"
if [ "${INSTALL_APEX:-false}" = "true" ]; then
    info "Paths: ORDS software + homes, APEX zips (private), image copy for Nginx (/srv)"
    _ask APEX_ORDS_BASE "ORDS base (ords-<ver>, ords_1, ords_2)" "${ORACLE_BASE}/product/ords" "_val_dir"
    _ask APEX_SW_BASE   "APEX software base (APEX_<ver>)"     "${ORACLE_BASE}/product/apex" "_val_dir"
    _ask APEX_WEB_DIR   "APEX images for Nginx"               "/srv/apex"                   "_val_dir"
    # TNS alias of the APEX database: the alias with DB_SERVICE in TNS_ADMIN
    _alias_def="$(TNS_ADMIN="${TNS_ADMIN:-}" tns_alias_for_service "${DB_SERVICE:-}")"
    info "ords_1 - one ORDS per database, TNS alias from ${TNS_ADMIN:-TNS_ADMIN}/tnsnames.ora"
    _ask ORDS_1_DB_ALIAS     "TNS alias of the APEX database"   "${_alias_def:-${DB_SERVICE^^}}"
    _ask ORDS_1_PORT         "ORDS listener port (127.0.0.1)"   "8081"  "_val_port"
    _ask ORDS_1_CONTEXT      "ORDS URL context"                 "/ords" "_val_url_path"
    _ask ORDS_1_IMAGE_PREFIX "APEX image prefix of this DB"     "/i/"
    _ask ORDS_JAVA_HEAP      "ORDS Java heap (-Xms=-Xmx)"       "2G"
    _ask APEX_TABLESPACE     "APEX tablespace"                  "APEX_DATA"
    _ask APEX_TEMP_TABLESPACE "APEX temp tablespace (empty = DB default)" "" "" "optional"
    _ask APEX_LANGUAGES      "APEX language packs (e.g. de)"    "de" "" "optional"
    _ask APEX_DB_PROFILE     "DB profile of the APEX/ORDS runtime users (no expiry)" "APEX_USER"
    _ask ORDS_PUBLIC_URL     "Public URL of APEX (CORS / trusted origin)" "https://${WLS_SERVER_FQDN:-$(hostname -f)}"
    _ask APEX_ADMIN_EMAIL    "E-mail of the APEX ADMIN (empty = ADMIN)" "" "" "optional"
    info "APEX instance administrator ADMIN -> encrypted to: $(basename "$APEX_SEC_FILE")"
    info "  APEX rules: upper + lower case, digit, punctuation character"
    _ask_password APEX_ADMIN_PWD "APEX ADMIN password" "$APEX_SEC_FILE"
    unset _alias_def
fi
INSTALL_APEX="${INSTALL_APEX:-false}"

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
_show "PATCH_ARCHIVE"        "${PATCH_ARCHIVE:-(none)}"
_show "TNS_ADMIN"            "$TNS_ADMIN"
_show "INSTALL_COMPONENTS"   "$INSTALL_COMPONENTS"
_show "WLS_SERVER_FQDN"      "$WLS_SERVER_FQDN"
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
_show "FORMS_MAX_RUNTIME_PROCESSES" "${FORMS_MAX_RUNTIME_PROCESSES:-(proposal by 14-)}"
_show "FORMS_WEBUTIL_JACOB"  "${FORMS_WEBUTIL_JACOB:-false}"
_show "FORMS_CLIENT_DIST"    "$FORMS_CLIENT_DIST"
if [ "$FORMS_CLIENT_DIST" = "true" ]; then
    for _k in FORMS_CLIENT_DIR FORMS_CLIENT_URL_PATH FORMS_CLIENT_BASE_URL FORMS_CLIENT_CONFIG \
              FORMS_CLIENT_FORM FORMS_CLIENT_APP_NAME FORMS_CLIENT_ICON FORMS_CLIENT_RUNTIME FORMS_CLIENT_TRUST_CA; do
        _show "$_k" "${!_k:-(empty)}"
    done
    unset _k
fi
if [ "${FORMS_WEBUTIL_JACOB:-false}" = "true" ] || [ "$FORMS_CLIENT_DIST" = "true" ]; then
    _show "FORMS_SIGN_KEYSTORE" "$FORMS_SIGN_KEYSTORE$([ "$FORMS_SIGN_LOCALCA" = "true" ] && printf '  (created by 14- via local CA)')"
    _show "FORMS_SIGN_ALIAS"    "$FORMS_SIGN_ALIAS"
    _show "FORMS_SIGN_TSA_URL"  "${FORMS_SIGN_TSA_URL:-(none - no timestamp)}"
    if [ "$FORMS_SIGN_LOCALCA" != "true" ]; then
        if [ -n "${FORMS_SIGN_STOREPASS:-}" ]; then
            _show "FORMS_SIGN_STOREPASS" "****  → $(basename "$FORMS_SIGN_SEC_FILE")"
        else
            _show "FORMS_SIGN_STOREPASS" "(not saved – wrong password, run again)"
        fi
    fi
    for _k in "${SSL_CONF_KEYS[@]}"; do
        _show "$_k" "${!_k}  → 08-SSL/ssl.conf"
    done
    unset _k
fi
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
_show "INSTALL_APEX"         "$INSTALL_APEX"
if [ "$INSTALL_APEX" = "true" ]; then
    for _k in APEX_ORDS_BASE APEX_SW_BASE APEX_WEB_DIR ORDS_1_DB_ALIAS ORDS_1_PORT \
              ORDS_1_CONTEXT ORDS_1_IMAGE_PREFIX ORDS_JAVA_HEAP APEX_TABLESPACE APEX_TEMP_TABLESPACE APEX_LANGUAGES \
              APEX_DB_PROFILE ORDS_PUBLIC_URL APEX_ADMIN_EMAIL; do
        _show "$_k" "${!_k:-(empty)}"
    done
    unset _k
    _show "APEX_ADMIN_PWD"       "****  → $(basename "$APEX_SEC_FILE")"
fi
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
    # WLS_SERVER_FQDN now lives in the block – drop a copy appended by hand /
    # by init_env.sh outside of it (its value was read and kept above)
    sed -i '/^WLS_SERVER_FQDN=/d' "$WRITE_CONF" 2>/dev/null || true
    sed -i '/^PATCH_ARCHIVE=/d' "$WRITE_CONF" 2>/dev/null || true
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
# Optional NFS/ZFS archive (master of installers + patches), PATCH_STORAGE = local
# working copy: 07-Maintenance/patch_storage.sh status | pull <step> | clean
PATCH_ARCHIVE="${PATCH_ARCHIVE}"
# Oracle Net configuration (tnsnames.ora, sqlnet.ora) - ONE directory for Forms,
# Reports, WebLogic and the oracle shell; check: 02-Checks/tns_admin_check.sh
TNS_ADMIN="${TNS_ADMIN}"
# Environment type: test | prod - prod = Claude Code is never used on this host
# (10-Monitoring/setup_claude.md, claude_setup_check.sh, guard hook)
IHW_ENV_TYPE="${IHW_ENV_TYPE}"

# --- Component Selection ------------------------------------------------------
INSTALL_COMPONENTS="${INSTALL_COMPONENTS}"

# --- WebLogic Domain ----------------------------------------------------------
DOMAIN_HOME="${DOMAIN_HOME}"
# Public server name (URL the users type, certificate SAN) – Nginx server_name,
# 08-SSL, FORMS_CLIENT_BASE_URL / ORDS_PUBLIC_URL; may differ from hostname -f
WLS_SERVER_FQDN="${WLS_SERVER_FQDN}"
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
# Forms session limit (formsweb.cfg [default] maxRuntimeProcesses, 14-) - 0 = DoS risk
FORMS_MAX_RUNTIME_PROCESSES="${FORMS_MAX_RUNTIME_PROCESSES:-}"

# --- Forms WebUtil OLE (JACOB) + code signing of jacob.jar (14-) ---------------
FORMS_WEBUTIL_JACOB="${FORMS_WEBUTIL_JACOB:-false}"
# PKCS12 keystore; password FORMS_SIGN_STOREPASS -> forms_sign_sec.conf.des3
FORMS_SIGN_KEYSTORE="${FORMS_SIGN_KEYSTORE}"
FORMS_SIGN_ALIAS="${FORMS_SIGN_ALIAS}"
FORMS_SIGN_TSA_URL="${FORMS_SIGN_TSA_URL}"
# true = 14- creates the keystore with the own root CA (08-SSL/ssl_local_ca.sh)
FORMS_SIGN_LOCALCA="${FORMS_SIGN_LOCALCA:-false}"

# --- Forms client distribution via URL (concept docs/40-forms_client_distribution.md)
# true = 03- creates FORMS_CLIENT_DIR, Nginx serves it under FORMS_CLIENT_URL_PATH
FORMS_CLIENT_DIST="${FORMS_CLIENT_DIST}"
FORMS_CLIENT_DIR="${FORMS_CLIENT_DIR:-}"
FORMS_CLIENT_URL_PATH="${FORMS_CLIENT_URL_PATH:-}"
FORMS_CLIENT_BASE_URL="${FORMS_CLIENT_BASE_URL:-}"
FORMS_CLIENT_CONFIG="${FORMS_CLIENT_CONFIG:-}"
FORMS_CLIENT_FORM="${FORMS_CLIENT_FORM:-}"
FORMS_CLIENT_APP_NAME="${FORMS_CLIENT_APP_NAME:-}"
# shortcut icon: .ico, or .png <= 256 px (40- wraps it into an ICO); local path or
# http(s) URL (04- downloads it to $PATCH_STORAGE/icon/); empty = Windows default
FORMS_CLIENT_ICON="${FORMS_CLIENT_ICON:-}"
# jlink = slim runtime, jdk = full JDK ZIP
FORMS_CLIENT_RUNTIME="${FORMS_CLIENT_RUNTIME:-}"
# empty = public CA (already in the runtime's cacerts)
FORMS_CLIENT_TRUST_CA="${FORMS_CLIENT_TRUST_CA:-}"

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

# --- APEX / ORDS (12-APEX-Ords/README.md) -------------------------------------
# Versions / download URLs -> oracle_software_version.conf (APEX_*, ORDS_*)
# ords_1 below; a second ORDS (other DB): ORDS_2_DB_ALIAS / _PORT / _CONTEXT /
# _IMAGE_PREFIX by hand (8082, /ords_2, /i_2/). APEX_ADMIN_PWD -> apex_sec.conf.des3
INSTALL_APEX="${INSTALL_APEX}"
APEX_ORDS_BASE="${APEX_ORDS_BASE:-}"
APEX_SW_BASE="${APEX_SW_BASE:-}"
APEX_WEB_DIR="${APEX_WEB_DIR:-}"
ORDS_1_DB_ALIAS="${ORDS_1_DB_ALIAS:-}"
ORDS_1_PORT="${ORDS_1_PORT:-}"
ORDS_1_CONTEXT="${ORDS_1_CONTEXT:-}"
ORDS_1_IMAGE_PREFIX="${ORDS_1_IMAGE_PREFIX:-}"
ORDS_JAVA_HEAP="${ORDS_JAVA_HEAP:-}"
APEX_TABLESPACE="${APEX_TABLESPACE:-}"
APEX_TEMP_TABLESPACE="${APEX_TEMP_TABLESPACE:-}"
APEX_LANGUAGES="${APEX_LANGUAGES:-}"
APEX_DB_PROFILE="${APEX_DB_PROFILE:-APEX_USER}"
ORDS_PUBLIC_URL="${ORDS_PUBLIC_URL:-}"
APEX_ADMIN_EMAIL="${APEX_ADMIN_EMAIL:-}"
# not asked (defaults): ORDS logs /var/log/ords_N; risky ORDS features off
ORDS_LOG_BASE="${ORDS_LOG_BASE:-/var/log}"
ORDS_FEATURE_SDW="${ORDS_FEATURE_SDW:-false}"
ORDS_FEATURE_REST_SQL="${ORDS_FEATURE_REST_SQL:-false}"
ORDS_FEATURE_DB_API="${ORDS_FEATURE_DB_API:-false}"
ORDS_FEATURE_GRAPHQL="${ORDS_FEATURE_GRAPHQL:-disable_all}"

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

if [ -n "${FORMS_SIGN_STOREPASS:-}" ] && [ "$FORMS_SIGN_STOREPASS" != "****" ]; then
    _write_secrets_file "$FORMS_SIGN_SEC_FILE" "FORMS_SIGN_STOREPASS=$FORMS_SIGN_STOREPASS"
    unset FORMS_SIGN_STOREPASS
fi

# Local CA subject values -> 08-SSL/ssl.conf (replace the key or append it;
# a new ssl.conf holds only these keys, the 08-SSL scripts default the rest)
if [ "${#SSL_CONF_KEYS[@]}" -gt 0 ]; then
    [ -f "$SSL_CONF" ] && backup_file "$SSL_CONF" "$(dirname "$SSL_CONF")"
    if [ ! -f "$SSL_CONF" ]; then
        printf "# ssl.conf – written by 09-Install/01-setup-interview.sh %s\n" \
            "$(date '+%Y-%m-%d %H:%M:%S')" > "$SSL_CONF"
    fi
    chmod 600 "$SSL_CONF"
    for _k in "${SSL_CONF_KEYS[@]}"; do
        _line="$(printf '%s="%s"' "$_k" "${!_k}")"
        if grep -q "^${_k}=" "$SSL_CONF"; then
            _esc="$(printf '%s' "$_line" | sed 's/[&|\\]/\\&/g')"
            sed -i "s|^${_k}=.*|${_esc}|" "$SSL_CONF"
        else
            printf '%s\n' "$_line" >> "$SSL_CONF"
        fi
    done
    unset _k _line _esc
    ok "Local CA parameters written: $SSL_CONF"
fi

if [ -n "${APEX_ADMIN_PWD:-}" ] && [ "$APEX_ADMIN_PWD" != "****" ]; then
    # merge: keeps APEX_REST_PUBLIC_PWD / ORDS_N_PUBLIC_PWD written by 12-APEX-Ords
    merge_secrets_file "$APEX_SEC_FILE" "APEX_ADMIN_USER=ADMIN" "APEX_ADMIN_PWD=$APEX_ADMIN_PWD"
    unset APEX_ADMIN_PWD
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
PATCH_ARCHIVE="${PATCH_ARCHIVE}"
TNS_ADMIN="${TNS_ADMIN}"
INSTALL_COMPONENTS="${INSTALL_COMPONENTS}"
WLS_SERVER_FQDN="${WLS_SERVER_FQDN}"
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
FORMS_MAX_RUNTIME_PROCESSES="${FORMS_MAX_RUNTIME_PROCESSES:-}"
FORMS_WEBUTIL_JACOB="${FORMS_WEBUTIL_JACOB:-false}"
FORMS_SIGN_KEYSTORE="${FORMS_SIGN_KEYSTORE}"
FORMS_SIGN_ALIAS="${FORMS_SIGN_ALIAS}"
FORMS_SIGN_TSA_URL="${FORMS_SIGN_TSA_URL}"
FORMS_SIGN_LOCALCA="${FORMS_SIGN_LOCALCA:-false}"
FORMS_CLIENT_DIST="${FORMS_CLIENT_DIST}"
FORMS_CLIENT_DIR="${FORMS_CLIENT_DIR:-}"
FORMS_CLIENT_URL_PATH="${FORMS_CLIENT_URL_PATH:-}"
FORMS_CLIENT_BASE_URL="${FORMS_CLIENT_BASE_URL:-}"
FORMS_CLIENT_CONFIG="${FORMS_CLIENT_CONFIG:-}"
FORMS_CLIENT_FORM="${FORMS_CLIENT_FORM:-}"
FORMS_CLIENT_APP_NAME="${FORMS_CLIENT_APP_NAME:-}"
FORMS_CLIENT_ICON="${FORMS_CLIENT_ICON:-}"
FORMS_CLIENT_RUNTIME="${FORMS_CLIENT_RUNTIME:-}"
FORMS_CLIENT_TRUST_CA="${FORMS_CLIENT_TRUST_CA:-}"
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
INSTALL_APEX="${INSTALL_APEX}"
APEX_ORDS_BASE="${APEX_ORDS_BASE:-}"
APEX_SW_BASE="${APEX_SW_BASE:-}"
APEX_WEB_DIR="${APEX_WEB_DIR:-}"
ORDS_1_DB_ALIAS="${ORDS_1_DB_ALIAS:-}"
ORDS_1_PORT="${ORDS_1_PORT:-}"
ORDS_1_CONTEXT="${ORDS_1_CONTEXT:-}"
ORDS_1_IMAGE_PREFIX="${ORDS_1_IMAGE_PREFIX:-}"
ORDS_JAVA_HEAP="${ORDS_JAVA_HEAP:-}"
APEX_TABLESPACE="${APEX_TABLESPACE:-}"
APEX_TEMP_TABLESPACE="${APEX_TEMP_TABLESPACE:-}"
APEX_LANGUAGES="${APEX_LANGUAGES:-}"
APEX_DB_PROFILE="${APEX_DB_PROFILE:-APEX_USER}"
ORDS_PUBLIC_URL="${ORDS_PUBLIC_URL:-}"
APEX_ADMIN_EMAIL="${APEX_ADMIN_EMAIL:-}"
# not asked (defaults): ORDS logs /var/log/ords_N; risky ORDS features off
ORDS_LOG_BASE="${ORDS_LOG_BASE:-/var/log}"
ORDS_FEATURE_SDW="${ORDS_FEATURE_SDW:-false}"
ORDS_FEATURE_REST_SQL="${ORDS_FEATURE_REST_SQL:-false}"
ORDS_FEATURE_DB_API="${ORDS_FEATURE_DB_API:-false}"
ORDS_FEATURE_GRAPHQL="${ORDS_FEATURE_GRAPHQL:-disable_all}"
MOS_USER="${MOS_USER}"
# APEX_ADMIN_PWD → apex_sec.conf.des3 (INSTALL_APEX=true)
# WLS_ADMIN_PWD  → weblogic_sec.conf.des3
# MOS_PWD        → mos_sec.conf.des3
# DB_SYS_PWD + DB_SCHEMA_PWD → db_sys_sec.conf.des3
# EMBEDDED_LDAP_PWD → embedded_ldap_sec.conf.des3 (REPORTS_SECURITY=ldap)
# REPORTS_ADMIN_PWD → reports_admin_sec.conf.des3 (rwserver.conf <identifier>)
# FORMS_SIGN_STOREPASS → forms_sign_sec.conf.des3 (code-signing keystore)
# Software versions → 09-Install/oracle_software_version.conf, patch numbers → 09-Install/download/patches_fmw.csv
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
