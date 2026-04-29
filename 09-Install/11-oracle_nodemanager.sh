#!/bin/bash
# =============================================================================
# Script   : 11-oracle_nodemanager.sh
# Purpose  : Configure NodeManager for plain (non-SSL) communication and
#            optionally register it as a systemd service.
#
#            By default WebLogic configures NodeManager with SecureListener=true
#            (SSL). For internal environments without a proper PKI this causes
#            "Unrecognized SSL message, plaintext connection?" errors when
#            starting managed servers.
#
#            This script:
#              1. Sets SecureListener=false in nodemanager.properties
#              2. Aligns the domain's NodeManager type to "Plain" via WLST
#              3. Verifies the final configuration
#
# Call     : ./09-Install/11-oracle_nodemanager.sh
#            ./09-Install/11-oracle_nodemanager.sh --apply
#            ./09-Install/11-oracle_nodemanager.sh --apply --skip-wlst
#
#            Without --apply  : dry-run, show current settings, no changes
#            --skip-wlst      : skip domain config update (AdminServer not running)
#
# Requires : environment.conf (DOMAIN_HOME, ORACLE_HOME)
#            weblogic_sec.conf.des3 (for WLST authentication)
# Runs as  : oracle
# Ref      : 09-Install/docs/11-oracle_nodemanager.md
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
check_env_conf "$ROOT_DIR/environment.conf" || exit 2
# shellcheck source=../environment.conf
source "$ROOT_DIR/environment.conf"

# --- Arguments ----------------------------------------------------------------
APPLY=false
SKIP_WLST=false

for _arg in "$@"; do
    case "$_arg" in
        --apply)      APPLY=true ;;
        --skip-wlst)  SKIP_WLST=true ;;
        --help|-h)
            printf "Usage: %s [--apply] [--skip-wlst]\n\n" "$(basename "$0")"
            printf "  %-16s %s\n" "--apply"      "Write changes to nodemanager.properties and domain config"
            printf "  %-16s %s\n" "--skip-wlst"  "Skip WLST domain update (use if AdminServer is not running)"
            printf "\nWithout --apply: dry-run, no files changed.\n"
            exit 0 ;;
        *) warn "Unknown argument: $_arg" ;;
    esac
done
unset _arg

# --- Log setup ----------------------------------------------------------------
LOG_FILE="$ROOT_DIR/log/$(date +%Y%m%d)/nodemanager_$(date +%H%M%S).log"
mkdir -p "$(dirname "$LOG_FILE")"
{
    printf "# 11-oracle_nodemanager.sh log\n"
    printf "# Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# Host    : %s\n" "$(_get_hostname)"
    printf "# Apply   : %s\n" "$APPLY"
} > "$LOG_FILE"

# =============================================================================
# Header
# =============================================================================
printLine
printf "\n\033[1m  IHateWeblogic – NodeManager Configuration\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host        : %s\n" "$(_get_hostname)"  | tee -a "$LOG_FILE"
printf "  DOMAIN_HOME : %s\n" "${DOMAIN_HOME:-?}" | tee -a "$LOG_FILE"
printf "  Apply       : %s\n" "$APPLY"             | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"           | tee -a "$LOG_FILE"
printLine

# =============================================================================
# 1. Prerequisites
# =============================================================================
section "Prerequisites"

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

if [ -z "${ORACLE_HOME:-}" ]; then
    fail "ORACLE_HOME is not set in environment.conf"
    print_summary; exit "$EXIT_CODE"
fi
ok "ORACLE_HOME: $ORACLE_HOME"

WLST_SH="$ORACLE_HOME/oracle_common/common/bin/wlst.sh"
if [ -f "$WLST_SH" ]; then
    ok "wlst.sh found: $WLST_SH"
else
    warn "wlst.sh not found at: $WLST_SH"
    info "  WLST step will be skipped"
    SKIP_WLST=true
fi

# =============================================================================
# 2. nodemanager.properties
# =============================================================================
section "NodeManager Properties File"

NM_PROPS="$DOMAIN_HOME/nodemanager/nodemanager.properties"

if [ ! -f "$NM_PROPS" ]; then
    fail "nodemanager.properties not found: $NM_PROPS"
    info "  Domain not yet created or NodeManager not yet configured"
    info "  Run 08-oracle_setup_domain.sh first"
    print_summary; exit "$EXIT_CODE"
fi
ok "File found: $NM_PROPS"

# Show current SSL-relevant settings
info "Current settings:"
for _key in SecureListener ListenAddress ListenPort StartScriptEnabled; do
    _val="$(grep -i "^${_key}" "$NM_PROPS" 2>/dev/null | head -1)"
    if [ -n "$_val" ]; then
        printf "  %-28s %s\n" "" "$_val" | tee -a "$LOG_FILE"
    else
        printf "  %-28s %s\n" "" "${_key}=(not set)" | tee -a "$LOG_FILE"
    fi
done
unset _key _val

# Check current SecureListener value
_current_secure="$(grep -i '^SecureListener' "$NM_PROPS" 2>/dev/null | cut -d= -f2 | tr -d ' ')"
if [ "${_current_secure,,}" = "false" ]; then
    ok "SecureListener is already false – no change needed"
    _nm_change_needed=false
else
    warn "SecureListener=${_current_secure:-true} → will set to false"
    _nm_change_needed=true
fi
unset _current_secure

if $APPLY && $_nm_change_needed; then
    # Backup
    _backup="$NM_PROPS.bak_$(date +%Y%m%d_%H%M%S)"
    cp "$NM_PROPS" "$_backup"
    ok "Backup: $_backup"

    # Set SecureListener=false (replace existing or append)
    if grep -qi '^SecureListener' "$NM_PROPS"; then
        sed -i 's/^[Ss]ecure[Ll]istener=.*/SecureListener=false/' "$NM_PROPS"
    else
        printf "SecureListener=false\n" >> "$NM_PROPS"
    fi
    ok "SecureListener=false written to $NM_PROPS"

    # Ensure StartScriptEnabled=true (required to start managed servers via NM)
    if grep -qi '^StartScriptEnabled' "$NM_PROPS"; then
        sed -i 's/^[Ss]tart[Ss]cript[Ee]nabled=.*/StartScriptEnabled=true/' "$NM_PROPS"
    else
        printf "StartScriptEnabled=true\n" >> "$NM_PROPS"
    fi
    ok "StartScriptEnabled=true written"

    unset _backup
elif ! $APPLY && $_nm_change_needed; then
    info "  Dry-run – would set: SecureListener=false"
    info "  Dry-run – would set: StartScriptEnabled=true"
fi
unset _nm_change_needed

# =============================================================================
# 3. Domain Configuration via WLST (NodeManagerType = Plain)
# =============================================================================
section "Domain NodeManager Type (WLST)"

if $SKIP_WLST; then
    info "Skipping WLST step (--skip-wlst or wlst.sh not found)"
    info "  Set NodeManager type manually in EM:"
    info "  fr_domain → WebLogic Domain → Security → General"
    info "  → NodeManager Type: Plain → Lock & Edit → Save → Activate"
else
    # Check AdminServer port is open
    _adm_port="${WL_ADMIN_PORT:-7001}"
    _adm_url="${WL_ADMIN_URL:-t3://localhost:${_adm_port}}"

    if ! timeout 3 bash -c "echo >/dev/tcp/localhost/${_adm_port}" 2>/dev/null; then
        warn "AdminServer not reachable on port $_adm_port"
        info "  Start AdminServer first, then re-run without --skip-wlst"
        info "  Or run with --skip-wlst and set NodeManager Type manually in EM"
    else
        ok "AdminServer reachable on port $_adm_port"

        if $APPLY; then
            # Load credentials
            if ! load_weblogic_password; then
                fail "Cannot load WebLogic credentials – run 00-Setup/weblogic_sec.sh --apply"
                print_summary; exit "$EXIT_CODE"
            fi

            # Determine domain name from DOMAIN_HOME
            _domain_name="$(basename "$DOMAIN_HOME")"

            # Write WLST script to temp file
            _wlst_script="$(mktemp --suffix=.py)"
            cat > "$_wlst_script" <<WLST_EOF
import os, sys

wl_user = os.environ.get('_IHW_WL_USER', '')
wl_pass = os.environ.get('_IHW_WL_PASS', '')
adm_url = os.environ.get('_IHW_ADM_URL', 't3://localhost:7001')
domain  = os.environ.get('_IHW_DOMAIN',  'fr_domain')

try:
    connect(wl_user, wl_pass, adm_url)
    edit()
    startEdit()
    cd('/SecurityConfiguration/' + domain)
    cmo.setNodeManagerType('Plain')
    save()
    activate(block='true')
    print('IHW:OK:NodeManagerType set to Plain')
    disconnect()
except Exception as e:
    print('IHW:FAIL:WLST error: ' + str(e))
    sys.exit(1)
WLST_EOF

            export _IHW_WL_USER="$WL_USER"
            export _IHW_WL_PASS="$INTERNAL_WL_PWD"
            export _IHW_ADM_URL="$_adm_url"
            export _IHW_DOMAIN="$_domain_name"

            _wlst_out="$("$WLST_SH" "$_wlst_script" 2>&1)"

            # Clear credentials immediately
            unset _IHW_WL_USER _IHW_WL_PASS INTERNAL_WL_PWD

            # Parse sentinel output
            while IFS= read -r _line; do
                case "$_line" in
                    IHW:OK:*)   ok "$(printf '%s' "$_line" | cut -d: -f3-)" ;;
                    IHW:WARN:*) warn "$(printf '%s' "$_line" | cut -d: -f3-)" ;;
                    IHW:FAIL:*) fail "$(printf '%s' "$_line" | cut -d: -f3-)" ;;
                esac
            done <<< "$_wlst_out"

            rm -f "$_wlst_script"
            unset _wlst_script _wlst_out _domain_name WL_USER

        else
            info "Dry-run – would connect to $_adm_url and set NodeManagerType=Plain"
        fi
    fi
    unset _adm_port _adm_url
fi

# =============================================================================
# 4. Verification
# =============================================================================
section "Verification"

_sec="$(grep -i '^SecureListener' "$NM_PROPS" 2>/dev/null | cut -d= -f2 | tr -d ' ')"
if [ "${_sec,,}" = "false" ]; then
    ok "nodemanager.properties: SecureListener=false"
else
    warn "nodemanager.properties: SecureListener=${_sec:-not set} (expected false)"
fi
unset _sec

_sse="$(grep -i '^StartScriptEnabled' "$NM_PROPS" 2>/dev/null | cut -d= -f2 | tr -d ' ')"
if [ "${_sse,,}" = "true" ]; then
    ok "nodemanager.properties: StartScriptEnabled=true"
else
    info "nodemanager.properties: StartScriptEnabled=${_sse:-not set}"
fi
unset _sse

# =============================================================================
# 5. Next steps
# =============================================================================
section "Next Steps"
info "1. Start NodeManager:"
info "   nohup \$DOMAIN_HOME/bin/startNodeManager.sh > \$DOMAIN_HOME/nodemanager/nm.out 2>&1 &"
info "2. In EM verify: NodeManager Type = Plain"
info "   fr_domain → WebLogic Domain → Security → General"
info "3. Start managed servers via EM or startManagedWebLogic.sh"

# =============================================================================
print_summary
exit "$EXIT_CODE"
