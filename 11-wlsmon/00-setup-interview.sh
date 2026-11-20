#!/bin/bash
# =============================================================================
# Script   : 00-setup-interview.sh
# Purpose  : wlsmon installation step 1 of 3 (FMW owner): asks everything wlsmon
#            needs on this host and writes $WLSMON_BASE/etc/wlsmon.conf plus the
#            secrets to $WLSMON_BASE/etc/pending/ (clear text, mode 600, until
#            02-install-wlsmon_root.sh encrypts them as systemd credentials).
#            Defaults, in this order: an existing wlsmon.conf (a second run
#            offers the last answers) > environment.conf (when the library is
#            here) > the state of the host (wlsmon.py detect) > the built-in
#            defaults of wlsmon.py.
# Call     : ./11-wlsmon/00-setup-interview.sh                    (dry-run: diff)
#            ./11-wlsmon/00-setup-interview.sh --apply
#            ./11-wlsmon/00-setup-interview.sh --secret reports_mon --apply
# Options  : --apply          write wlsmon.conf and the secrets
#            --defaults       no questions - take every default (tests, re-runs)
#            --secret NAME    change only this secret (wls_monitor | reports_mon |
#                             pull_user | pull_hash | gui_htpasswd | db_monitor)
#            --base DIR       WLSMON_BASE (default $ORACLE_BASE/admin/wlsmon)
#            --env-conf FILE  environment.conf to take defaults from
#            --help
# Secrets  : wls_monitor   generated (password rule of the realm), nobody types it
#            reports_mon   Reports monUser - from reports_users.conf.des3 when the
#                          library has it, otherwise asked (hidden, twice)
#            pull_user     GUI role with data hosts: generated, its hash is shown
#            pull_hash     data role: the hash shown on the GUI host
#            gui_htpasswd  GUI role: one password per GUI user (hidden, twice)
#            db_monitor    only with WLSMON_RCU_CHECK=true (hidden, twice)
#            An existing secret (pending/ or creds/) is kept unless --secret names it.
# Runs as  : FMW owner (oracle), never root - no sudo needed
# Ref      : 11-wlsmon/docs/01-wlsmon_concept.md §9.2, docs/03-wlsmon_development.md step 9
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_SH="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
WLSMON_PY="$SCRIPT_DIR/wlsmon.py"
RENDER_PY="$SCRIPT_DIR/tools/render_template.py"
TEMPLATE="$SCRIPT_DIR/templates/wlsmon.conf.template"
SECRET_NAMES="wls_monitor reports_mon pull_user pull_hash gui_htpasswd db_monitor"

# --- library when it is here (repository), small fallbacks otherwise (tools ZIP)
HAVE_LIB=false
if [ -f "$LIB_SH" ]; then
    # shellcheck source=../00-Setup/IHateWeblogic_lib.sh
    source "$LIB_SH"
    HAVE_LIB=true
else
    CNT_OK=0; CNT_WARN=0; CNT_FAIL=0
    ok()      { CNT_OK=$((CNT_OK + 1));     printf "\033[32m  OK\033[0m  %s\n" "$*" | tee -a "${LOG_FILE:-/dev/null}"; }
    warn()    { CNT_WARN=$((CNT_WARN + 1)); printf "\033[33mWARN\033[0m  %s\n" "$*" | tee -a "${LOG_FILE:-/dev/null}"; }
    fail()    { CNT_FAIL=$((CNT_FAIL + 1)); printf "\033[31mFAIL\033[0m  %s\n" "$*" | tee -a "${LOG_FILE:-/dev/null}"; }
    info()    { printf "\033[34mINFO\033[0m  %s\n" "$*" | tee -a "${LOG_FILE:-/dev/null}"; }
    section() { printf "\n\033[1m=== %s ===\033[0m\n" "$*" | tee -a "${LOG_FILE:-/dev/null}"; }
    backup_file() { cp -p "$1" "$1.bak_$(date +%Y%m%d_%H%M%S)" && ok "Backup created: $1.bak_*"; }
    askYesNo() {
        local a; printf "  %s [y/N]: " "$1" >&2; read -r a
        case "${a,,}" in y|yes|j|ja) return 0 ;; *) return 1 ;; esac
    }
    print_summary() {
        printf "\n  OK: %d  WARN: %d  FAIL: %d\n" "$CNT_OK" "$CNT_WARN" "$CNT_FAIL" | tee -a "${LOG_FILE:-/dev/null}"
        EXIT_CODE=0; [ "$CNT_WARN" -gt 0 ] && EXIT_CODE=1; [ "$CNT_FAIL" -gt 0 ] && EXIT_CODE=2
    }
fi

# =============================================================================
# Arguments
# =============================================================================
APPLY=false
DEFAULTS_ONLY=false
ONE_SECRET=""
BASE_ARG=""
ENV_CONF="$ROOT_DIR/environment.conf"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply)    APPLY=true ;;
        --defaults) DEFAULTS_ONLY=true ;;
        --secret)   ONE_SECRET="${2:-}"; shift ;;
        --base)     BASE_ARG="${2:-}"; shift ;;
        --env-conf) ENV_CONF="${2:-}"; shift ;;
        --help|-h)
            printf "Usage: %s [--apply] [--defaults] [--secret NAME] [--base DIR] [--env-conf FILE]\n\n" "$(basename "$0")"
            printf "  %-16s %s\n" "(none)"         "Dry-run: ask, show the resulting wlsmon.conf as a diff"
            printf "  %-16s %s\n" "--apply"        "Write wlsmon.conf (etc/) and the secrets (etc/pending/)"
            printf "  %-16s %s\n" "--defaults"     "No questions, take every default"
            printf "  %-16s %s\n" "--secret NAME"  "Change only this secret: $SECRET_NAMES"
            printf "  %-16s %s\n" "--base DIR"     "WLSMON_BASE (default \$ORACLE_BASE/admin/wlsmon)"
            printf "  %-16s %s\n" "--env-conf FILE" "environment.conf for the defaults"
            printf "\nNext: 01-install-wlsmon_fmw.sh --apply, then (root) 02-install-wlsmon_root.sh --apply\n"
            exit 0 ;;
        *) printf "Unknown argument: %s (--help)\n" "$1" >&2; exit 2 ;;
    esac
    shift
done

if [ -n "$ONE_SECRET" ] && [[ " $SECRET_NAMES " != *" $ONE_SECRET "* ]]; then
    printf "Unknown secret: %s (one of: %s)\n" "$ONE_SECRET" "$SECRET_NAMES" >&2
    exit 2
fi

LOG_FILE="/dev/null"
if [ -d "$ROOT_DIR/log" ] || mkdir -p "$ROOT_DIR/log" 2>/dev/null; then
    LOG_FILE="$ROOT_DIR/log/$(date +%Y%m%d)/wlsmon_setup_interview_$(date +%H%M%S).log"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || LOG_FILE="/dev/null"
fi

printf "\n\033[1m  wlsmon – setup interview (step 1 of 3, FMW owner)\033[0m\n" | tee -a "$LOG_FILE"
printf "  Apply: %s  Secret only: %s  Library: %s\n" "$APPLY" "${ONE_SECRET:-–}" "$HAVE_LIB" | tee -a "$LOG_FILE"

# =============================================================================
# Pre-checks
# =============================================================================
section "Pre-checks"

if [ "$(id -u)" -eq 0 ]; then
    fail "Runs as the FMW owner, not as root (root comes last: 02-install-wlsmon_root.sh)"
    print_summary; exit "${EXIT_CODE:-2}"
fi
ok "$(printf "  %-22s %s" "user:" "$(id -un)")"

if ! command -v python3 > /dev/null 2>&1; then
    fail "python3 not found – dnf install python3 (BaseOS)"
    print_summary; exit "${EXIT_CODE:-2}"
fi
ok "$(printf "  %-22s %s" "python3:" "$(python3 -c 'import sys; print(sys.version.split()[0])')")"

for _f in "$WLSMON_PY" "$RENDER_PY" "$TEMPLATE"; do
    [ -f "$_f" ] || { fail "Missing: $_f"; print_summary; exit "${EXIT_CODE:-2}"; }
done

ENV_LOADED=false
if [ -f "$ENV_CONF" ]; then
    # shellcheck source=/dev/null
    source "$ENV_CONF" > /dev/null 2>&1 && ENV_LOADED=true
    ok "$(printf "  %-22s %s" "environment.conf:" "$ENV_CONF (defaults)")"
else
    info "No environment.conf – built-in defaults and the state of the host"
fi

# =============================================================================
# Defaults: built-in < environment.conf < host state < existing wlsmon.conf
# =============================================================================
declare -A V
while IFS='=' read -r _k _v; do
    [ -n "$_k" ] && V[$_k]="$_v"
done < <(python3 -I "$WLSMON_PY" defaults)

_set() { [ -n "${2:-}" ] && V[$1]="$2"; }

if $ENV_LOADED; then
    _set WLSMON_DOMAIN_HOME "${DOMAIN_HOME:-}"
    _set WLSMON_ORACLE_HOME "${ORACLE_HOME:-}"
    _set WLSMON_FORMS_SERVER "${WLS_FORMS_SERVER:-}"
    _set WLSMON_REPORTS_SERVER "${WLS_MANAGED_SERVER:-}"
    [ -n "${WLS_ADMIN_PORT:-}" ] && V[WLSMON_ADMIN_URL]="http://localhost:${WLS_ADMIN_PORT}"
    _set WLSMON_NM_PORT "${WLS_NODEMANAGER_PORT:-}"
    if [ -n "${WLS_ADMIN_PORT:-}" ]; then
        V[WLSMON_SERVER_PORTS]="AdminServer:${WLS_ADMIN_PORT}"
        [ -n "${WLS_FORMS_PORT:-}" ]   && V[WLSMON_SERVER_PORTS]+=" ${WLS_FORMS_SERVER:-WLS_FORMS}:${WLS_FORMS_PORT}"
        [ -n "${WLS_REPORTS_PORT:-}" ] && V[WLSMON_SERVER_PORTS]+=" ${WLS_MANAGED_SERVER:-WLS_REPORTS}:${WLS_REPORTS_PORT}"
    fi
    [ -n "${WLS_REPORTS_PORT:-}" ] && V[WLSMON_REPORTS_URL]="http://localhost:${WLS_REPORTS_PORT}/reports/rwservlet"
    if declare -p REPORTS_SERVER_NAMES > /dev/null 2>&1; then
        _set WLSMON_REPORTS_SERVERS "${REPORTS_SERVER_NAMES[*]}"
    fi
    _set WLSMON_REPORTS_SERVERS "${V[WLSMON_REPORTS_SERVERS]:-${REPORTS_SERVER_NAME:-}}"
    _set WLSMON_RCU_PREFIX "${DB_SCHEMA_PREFIX:-}"
    _set WLSMON_ADMIN_IP_RANGE "${ADMIN_IP_RANGE:-}"
    [ -n "${APEX_WEB_DIR:-}" ] && [ -d "$APEX_WEB_DIR/apex_1" ] && V[WLSMON_APEX_DIR]="$APEX_WEB_DIR/apex_1"
fi
V[WLSMON_BASE]="${BASE_ARG:-${ORACLE_BASE:-/u01/app/oracle}/admin/wlsmon}"
V[WLSMON_HOST_ID]="$(hostname -s 2>/dev/null || hostname)"
V[WLSMON_ENV]="${V[WLSMON_ENV]:-prod}"

# the state of this host: patch cycle of the inventory, fixed ports, /i/ libraries
DETECT_JSON="$(python3 -I "$WLSMON_PY" detect --oracle-home "${V[WLSMON_ORACLE_HOME]}" \
                --apex "${V[WLSMON_APEX_DIR]}" 2>/dev/null)"
_dj() { printf '%s' "$DETECT_JSON" | python3 -I -c "import json,sys; d=json.load(sys.stdin); v=d.get('$1'); print(' '.join(map(str,v)) if isinstance(v,list) else ('' if v is None else v))" 2>/dev/null; }
_set WLSMON_PATCH_BASELINE "$(_dj patch_cycle)"
_set WLSMON_EXPECTED_PORTS "$(_dj fixed_ports)"
HAVE_CREDS="$(_dj systemd_creds)"

CONF="${V[WLSMON_BASE]}/etc/wlsmon.conf"
PENDING="${V[WLSMON_BASE]}/etc/pending"
CREDS="${V[WLSMON_BASE]}/etc/creds"
if [ -f "$CONF" ]; then
    while IFS= read -r _line; do
        [[ "$_line" =~ ^(WLSMON_[A-Z0-9_]+)=(.*)$ ]] || continue
        V[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
    done < "$CONF"
    ok "$(printf "  %-22s %s" "existing wlsmon.conf:" "$CONF (its values are the defaults)")"
fi
[ -n "$BASE_ARG" ] && V[WLSMON_BASE]="$BASE_ARG"

# =============================================================================
# Interview
# =============================================================================
# _ask KEY "question" [check]  - check: role | env | locale | dir | ports | pair | bool | ipnet
_valid() {
    local kind="$1" v="$2"
    case "$kind" in
        role)   [[ "$v" =~ ^(both|data|gui)$ ]] ;;
        env)    [[ "$v" =~ ^(prod|qa|test|dev)$ ]] ;;
        locale) [[ "$v" =~ ^[a-z]{2}(-[A-Z]{2})?$ ]] ;;
        dir)    [ -d "$v" ] ;;
        ports)  [[ "$v" =~ ^[0-9\ ]*$ ]] ;;
        pair)   [ -z "$v" ] || [[ "$v" =~ ^[0-9.]+,[0-9.]+$ ]] ;;
        bool)   [[ "$v" =~ ^(true|false)$ ]] ;;
        cycle)  [ -z "$v" ] || [[ "$v" =~ ^20[0-9]{2}-(0[1-9]|1[0-2])$ ]] ;;
        ipnet)  [ -z "$v" ] || [ "$v" = "any" ] || [[ "$v" =~ ^[0-9a-fA-F.:/,\ ]+$ ]] ;;
        *)      return 0 ;;
    esac
}

_ask() {
    local key="$1" text="$2" kind="${3:-}" ans tries=0
    if $DEFAULTS_ONLY || [ ! -t 0 ]; then
        _valid "$kind" "${V[$key]}" || warn "$(printf "  %-26s '%s' does not look valid (%s)" "$key" "${V[$key]}" "$kind")"
        return 0
    fi
    while [ "$tries" -lt 3 ]; do
        read -r -e -i "${V[$key]}" -p "  $text: " ans
        if _valid "$kind" "$ans"; then
            V[$key]="$ans"; return 0
        fi
        printf "  \033[33m'%s' is not valid (%s) – again\033[0m\n" "$ans" "$kind"
        tries=$((tries + 1))
    done
    warn "$(printf "  %-26s kept '%s'" "$key" "${V[$key]}")"
}

if [ -z "$ONE_SECRET" ]; then
    section "This host"
    _ask WLSMON_BASE      "Directory of wlsmon (WLSMON_BASE)"
    _ask WLSMON_ROLE      "Role: both (one host) | data (B, C, D) | gui (A only)" role
    _ask WLSMON_HOST_ID   "Host id (tile name, URL ?host=)"
    _ask WLSMON_PRODUCT   "Product name in the header"
    _ask WLSMON_ENV       "Environment: prod | qa | test | dev" env
    _ask WLSMON_LOCALE    "Date / number format of the GUI (de-DE, en-GB ...)" locale

    if [ "${V[WLSMON_ROLE]}" != "gui" ]; then
        section "Domain (data role)"
        _ask WLSMON_DOMAIN_HOME   "DOMAIN_HOME" dir
        _ask WLSMON_ORACLE_HOME   "ORACLE_HOME (FMW)" dir
        _ask WLSMON_ADMIN_URL     "AdminServer URL (localhost - never through nginx)"
        _ask WLSMON_ADMIN_SERVER  "AdminServer name"
        _ask WLSMON_FORMS_SERVER  "Forms managed server"
        _ask WLSMON_REPORTS_SERVER "Reports managed server"
        _ask WLSMON_SERVER_PORTS  "Server:port list for the fallback checks"
        _ask WLSMON_NM_PORT       "Node Manager port"
        _ask WLSMON_MON_USER      "WebLogic monitor user (group Monitors, created by 01-install)"
        _ask WLSMON_REPORTS_URL   "rwservlet URL (localhost)"
        _ask WLSMON_REPORTS_SERVERS "Reports servers (blank-separated, empty = none)"
        _ask WLSMON_REPORTS_MON_USER "Reports monitoring user (role RW_MONITOR)"
        _ask WLSMON_DISKS         "Disks 'label=path ...' (empty = domain, logs, /tmp, core dir)"
        _ask WLSMON_NGINX_PORT    "nginx HTTPS port"
        _ask WLSMON_EXPECTED_PORTS "Fixed listening ports (not loopback) that are expected" ports
        _ask WLSMON_APEX_DIR      "APEX images directory (/i/, for the GUI libraries)"
        _ask WLSMON_PATCH_BASELINE "Expected patch cycle YYYY-MM (raise it every CPU / CSPU)" cycle
        _ask WLSMON_RCU_CHECK     "RCU schema check (needs a DB monitor user): true | false" bool
        if [ "${V[WLSMON_RCU_CHECK]}" = "true" ]; then
            _ask WLSMON_RCU_PREFIX   "RCU schema prefix"
            _ask WLSMON_DB_MON_USER  "DB monitor user (SELECT on DBA_USERS)"
        fi
    fi

    if [ "${V[WLSMON_ROLE]}" = "data" ]; then
        section "Web tier (data role)"
        _ask WLSMON_GUI_IP "IP of the GUI host A (only client of /wlsmon/api/)" ipnet
    else
        section "Web tier (GUI role)"
        _ask WLSMON_ADMIN_IP_RANGE "Networks of the people (comma-separated, any = no restriction)" ipnet
        [ -z "${V[WLSMON_GUI_USERS]}" ] && V[WLSMON_GUI_USERS]="wlsmon"
        _ask WLSMON_GUI_USERS "GUI login user(s), blank-separated"
        _ask WLSMON_PULL_HOSTS "Data hosts 'id=https://host ...' (empty = only this host)"
        if [ -n "${V[WLSMON_PULL_HOSTS]}" ]; then
            _ask WLSMON_PULL_CAFILE "CA file of the internal PKI for the pull (TLS verified)"
        fi
    fi

    if ! $DEFAULTS_ONLY && [ -t 0 ]; then
        if askYesNo "Change the thresholds (warn,crit)?" n; then
            section "Thresholds"
            for _k in WLSMON_HEAP_PCT WLSMON_CPU_PCT WLSMON_MEM_USED_PCT WLSMON_DISK_PCT WLSMON_LOG_ERRORS \
                      WLSMON_FORMS_SESSIONS WLSMON_REPORTS_QUEUE WLSMON_CERT_DAYS; do
                _ask "$_k" "$_k (warn,crit)" pair
            done
        fi
    fi

    # ---- render and show -------------------------------------------------------
    section "wlsmon.conf"
    CONF="${V[WLSMON_BASE]}/etc/wlsmon.conf"
    PENDING="${V[WLSMON_BASE]}/etc/pending"
    CREDS="${V[WLSMON_BASE]}/etc/creds"
    TMP_CONF="$(mktemp)"
    trap 'rm -f "$TMP_CONF"' EXIT
    _vars=()
    for _k in $(grep -o '##WLSMON_[A-Z0-9_]*##' "$TEMPLATE" | tr -d '#' | sort -u); do
        _vars+=(--var "$_k=${V[$_k]}")
    done
    if ! python3 -I "$RENDER_PY" "$TEMPLATE" --out "$TMP_CONF" "${_vars[@]}"; then
        fail "Rendering of wlsmon.conf failed"
        print_summary; exit "${EXIT_CODE:-2}"
    fi
    if [ -f "$CONF" ]; then
        if diff -q "$CONF" "$TMP_CONF" > /dev/null 2>&1; then
            ok "wlsmon.conf unchanged"
        else
            info "Changes against $CONF:"
            diff -u "$CONF" "$TMP_CONF" | sed -n '3,$p' | grep '^[+-]' | tee -a "$LOG_FILE"
        fi
    else
        info "New file $CONF:"
        grep -v '^#' "$TMP_CONF" | grep -v '^$' | sed 's/^/    /' | tee -a "$LOG_FILE"
    fi
fi

# =============================================================================
# Secrets -> etc/pending/ (only with --apply)
# =============================================================================
# _have NAME - secret already handed over (pending/ or creds/)
_have() { [ -s "$PENDING/$1" ] || [ -s "$CREDS/$1.cred" ] || [ -s "$CREDS/$1" ]; }

# _wanted NAME - secret needed for the role / options of this host
_wanted() {
    case "$1" in
        wls_monitor)  [ "${V[WLSMON_ROLE]}" != "gui" ] ;;
        reports_mon)  [ "${V[WLSMON_ROLE]}" != "gui" ] && [ -n "${V[WLSMON_REPORTS_SERVERS]}" ] ;;
        pull_user)    [ "${V[WLSMON_ROLE]}" != "data" ] && [ -n "${V[WLSMON_PULL_HOSTS]}" ] ;;
        pull_hash)    [ "${V[WLSMON_ROLE]}" = "data" ] ;;
        gui_htpasswd) [ "${V[WLSMON_ROLE]}" != "data" ] ;;
        db_monitor)   [ "${V[WLSMON_RCU_CHECK]}" = "true" ] ;;
    esac
}

# random password: 20 characters, every class, only characters that are safe in
# a curl config, JSON and a URL-encoded body
_gen_password() {
    python3 -I -c '
import secrets, string
cls = [string.ascii_uppercase, string.ascii_lowercase, string.digits, "_-.+"]
while True:
    p = [secrets.choice(c) for c in cls] + [secrets.choice("".join(cls)) for _ in range(16)]
    secrets.SystemRandom().shuffle(p)
    p = "".join(p)
    if p[0].isalpha():
        print(p); break'
}

# _ask_hidden "text" -> REPLY_SECRET (twice, must match, not empty)
_ask_hidden() {
    local a b tries=0
    REPLY_SECRET=""
    [ -t 0 ] || return 1
    while [ "$tries" -lt 3 ]; do
        read -r -s -p "  $1: " a; printf "\n"
        read -r -s -p "  $1 (again): " b; printf "\n"
        if [ -n "$a" ] && [ "$a" = "$b" ]; then REPLY_SECRET="$a"; return 0; fi
        printf "  \033[33mempty or not the same – again\033[0m\n"
        tries=$((tries + 1))
    done
    return 1
}

_put() {   # _put NAME VALUE - clear text file, mode 600, directory 700
    ( umask 077; printf '%s\n' "$2" > "$PENDING/$1" )
}

_secret() {
    local name="$1" val="" user
    case "$name" in
        wls_monitor)
            val="$(_gen_password)"
            if $HAVE_LIB && [ -n "${V[WLSMON_DOMAIN_HOME]}" ]; then
                local why
                why="$(DOMAIN_HOME="${V[WLSMON_DOMAIN_HOME]}" wls_pwd_rule_fail "$val" "${V[WLSMON_MON_USER]}")" \
                    || { fail "Generated password does not meet the realm rule: $why"; return 1; }
            fi
            _put wls_monitor "$val"
            ok "$(printf "  %-14s generated (20 characters) – 01-install creates the user %s with it" "wls_monitor" "${V[WLSMON_MON_USER]}")" ;;
        reports_mon)
            if $HAVE_LIB && [ -f "$ROOT_DIR/reports_users.conf.des3" ]; then
                val="$( load_secrets_file "$ROOT_DIR/reports_users.conf.des3" > /dev/null 2>&1 \
                        && printf '%s' "${REPORTS_MON_PWD:-}" )"
                user="$( load_secrets_file "$ROOT_DIR/reports_users.conf.des3" > /dev/null 2>&1 \
                        && printf '%s' "${REPORTS_MON_USER:-}" )"
                if [ -n "$val" ] && [ -n "$user" ] && [ "$user" != "${V[WLSMON_REPORTS_MON_USER]}" ]; then
                    warn "reports_users.conf.des3 holds user '$user', wlsmon.conf names '${V[WLSMON_REPORTS_MON_USER]}'"
                fi
            fi
            if [ -n "$val" ]; then
                ok "$(printf "  %-14s taken from reports_users.conf.des3 (library)" "reports_mon")"
            elif _ask_hidden "Password of the Reports user ${V[WLSMON_REPORTS_MON_USER]}"; then
                val="$REPLY_SECRET"
                ok "$(printf "  %-14s entered" "reports_mon")"
            else
                warn "reports_mon not set – Reports figures stay n/a (later: --secret reports_mon --apply)"
                return 0
            fi
            _put reports_mon "$val" ;;
        pull_user)
            val="$(_gen_password)"
            _put pull_user "$val"
            ok "$(printf "  %-14s generated for user %s" "pull_user" "${V[WLSMON_PULL_USER]}")"
            info "Hash for the data hosts (their interview asks for it – a hash is no secret):"
            printf '    %s\n' "$(printf '%s' "$val" | openssl passwd -6 -stdin)" | tee -a "$LOG_FILE" ;;
        pull_hash)
            if $DEFAULTS_ONLY || [ ! -t 0 ]; then
                warn "pull_hash not set – needs the hash shown by the interview of the GUI host"
                return 0
            fi
            read -r -p "  Hash of the pull user (from the GUI host, \$6\$...): " val
            [[ "$val" =~ ^\$6\$[^:[:space:]]+$ ]] || { fail "Not a SHA-512 crypt hash (\$6\$...)"; return 1; }
            _put pull_hash "${V[WLSMON_PULL_USER]}:$val"
            ok "$(printf "  %-14s stored" "pull_hash")" ;;
        gui_htpasswd)
            local lines="" u
            for u in ${V[WLSMON_GUI_USERS]}; do
                if _ask_hidden "Password of the GUI user $u"; then
                    lines+="$u:$(printf '%s' "$REPLY_SECRET" | openssl passwd -6 -stdin)"$'\n'
                    REPLY_SECRET=""
                else
                    warn "No password for GUI user $u – the GUI login is set later (--secret gui_htpasswd --apply)"
                fi
            done
            [ -z "$lines" ] && return 0
            _put gui_htpasswd "${lines%$'\n'}"
            ok "$(printf "  %-14s %s user(s), stored as SHA-512 hashes" "gui_htpasswd" "$(printf '%s' "$lines" | grep -c :)")" ;;
        db_monitor)
            if _ask_hidden "Password of the DB monitor user ${V[WLSMON_DB_MON_USER]}"; then
                _put db_monitor "$REPLY_SECRET"
                ok "$(printf "  %-14s entered" "db_monitor")"
            else
                warn "db_monitor not set – the RCU check reports 'not checked'"
            fi ;;
    esac
    val=""; REPLY_SECRET=""
}

section "Secrets"
if [ "$HAVE_CREDS" = "True" ]; then
    info "systemd-creds found – 02-install-wlsmon_root.sh encrypts the secrets, bound to this host"
else
    warn "No systemd-creds (OL8): the secrets stay as files with mode 400 – the weaker variant (concept 3b)"
fi
for _s in $SECRET_NAMES; do
    if [ -n "$ONE_SECRET" ]; then
        [ "$_s" = "$ONE_SECRET" ] || continue
    else
        _wanted "$_s" || continue
        if _have "$_s"; then
            ok "$(printf "  %-14s already handed over – kept (change: --secret %s --apply)" "$_s" "$_s")"
            continue
        fi
    fi
    if ! $APPLY; then
        info "$(printf "  %-14s would be set with --apply" "$_s")"
        continue
    fi
    if [ ! -d "$PENDING" ]; then
        mkdir -p "$PENDING" && chmod 700 "${V[WLSMON_BASE]}/etc" "$PENDING" \
            || { fail "Cannot create $PENDING"; break; }
    fi
    _secret "$_s"
done

# =============================================================================
# Apply wlsmon.conf
# =============================================================================
if [ -z "$ONE_SECRET" ]; then
    section "Write"
    if ! $APPLY; then
        info "Dry-run – nothing written. Write with: $(basename "$0") --apply"
    else
        if mkdir -p "${V[WLSMON_BASE]}/etc" 2>/dev/null && chmod 700 "${V[WLSMON_BASE]}/etc"; then
            [ -f "$CONF" ] && ! diff -q "$CONF" "$TMP_CONF" > /dev/null 2>&1 && backup_file "$CONF"
            if install -m 600 "$TMP_CONF" "$CONF"; then
                ok "$(printf "  %-22s %s" "written:" "$CONF")"
            else
                fail "Cannot write $CONF"
            fi
        else
            fail "Cannot create ${V[WLSMON_BASE]}/etc – the parent must belong to $(id -un)"
        fi
    fi
fi

section "Next"
info "1. ./11-wlsmon/01-install-wlsmon_fmw.sh --apply   (FMW owner: program, GUI, monitor user)"
info "2. sudo ./11-wlsmon/02-install-wlsmon_root.sh --apply   (root: systemd, nginx, credentials)"

print_summary
exit "$EXIT_CODE"
