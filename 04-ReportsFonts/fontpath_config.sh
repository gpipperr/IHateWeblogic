#!/bin/bash
# =============================================================================
# Script   : fontpath_config.sh
# Purpose  : Check and set REPORTS_FONT_DIRECTORY / REPORTS_ENHANCED_FONTHANDLING
#            in $DOMAIN_HOME/bin/setUserOverrides.sh so Oracle Reports finds
#            the deployed TTF fonts at JVM startup.
#            Also locates rwserver.conf and setDomainEnv.sh for reference.
# Call     : ./fontpath_config.sh [--apply]
# Requires : grep, cp, python3
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_font002.htm
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"

LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m Cannot find IHateWeblogic_lib.sh: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=00-Setup/IHateWeblogic_lib.sh
source "$LIB"

check_env_conf "$ENV_CONF" || exit 2
source "$ENV_CONF"

init_log

# =============================================================================
# Parse arguments
# =============================================================================
APPLY_MODE=false
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY_MODE=true ;;
        --help)
            printf "Usage: %s [--apply]\n" "$(basename "$0")"
            printf "  Default: dry-run – show current config and what would change\n"
            printf "  --apply: write REPORTS_FONT_DIRECTORY into setUserOverrides.sh\n"
            exit 0
            ;;
    esac
done

# =============================================================================
# Variables
# =============================================================================
REPORTS_FONT_DIR="${REPORTS_FONT_DIR:-$DOMAIN_HOME/reports/fonts}"
OVERRIDES_SH="$DOMAIN_HOME/bin/setUserOverrides.sh"

# =============================================================================
# Banner
# =============================================================================
printLine
printf "\n\033[1mIHateWeblogic – Reports Font Path Configuration\033[0m\n"
printf "Host    : %s\n" "$(_get_hostname)"
printf "Date    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "Mode    : %s\n" "$( $APPLY_MODE && echo 'APPLY (will update setUserOverrides.sh)' || echo 'DRY-RUN (use --apply to write)')"
printf "Log     : %s\n\n" "$LOG_FILE"

# =============================================================================
# Section 1: Target configuration
# =============================================================================
section "Target Font Configuration"

printList "REPORTS_FONT_DIRECTORY"         40 "$REPORTS_FONT_DIR"
printList "REPORTS_ENHANCED_FONTHANDLING"  40 "yes"
printList "setUserOverrides.sh"            40 "$OVERRIDES_SH"

printf "\n"

if [ ! -d "$REPORTS_FONT_DIR" ]; then
    warn "Font directory does not exist: $REPORTS_FONT_DIR"
    info "  Run deploy_fonts.sh --apply first to populate it"
else
    FONT_COUNT="$(find "$REPORTS_FONT_DIR" -name "*.ttf" -o -name "*.TTF" 2>/dev/null | wc -l)"
    ok "Font directory exists ($FONT_COUNT TTF file(s))"
fi

# =============================================================================
# Section 2: Current state in setUserOverrides.sh
# =============================================================================
section "Current State: setUserOverrides.sh"

if [ ! -f "$OVERRIDES_SH" ]; then
    warn "setUserOverrides.sh not found: $OVERRIDES_SH"
    info "  File will be created with --apply"
else
    ok "File found: $OVERRIDES_SH"

    CURRENT_FONT_DIR="$(grep -E '^[[:space:]]*(export[[:space:]]+)?REPORTS_FONT_DIRECTORY[[:space:]]*=' \
        "$OVERRIDES_SH" 2>/dev/null | tail -1)"
    CURRENT_ENHANCED="$(grep -E '^[[:space:]]*(export[[:space:]]+)?REPORTS_ENHANCED_FONTHANDLING[[:space:]]*=' \
        "$OVERRIDES_SH" 2>/dev/null | tail -1)"

    if [ -n "$CURRENT_FONT_DIR" ]; then
        ok "  REPORTS_FONT_DIRECTORY set    : $CURRENT_FONT_DIR"
    else
        warn "  REPORTS_FONT_DIRECTORY not set in setUserOverrides.sh"
    fi

    if [ -n "$CURRENT_ENHANCED" ]; then
        ok "  REPORTS_ENHANCED_FONTHANDLING : $CURRENT_ENHANCED"
    else
        warn "  REPORTS_ENHANCED_FONTHANDLING not set in setUserOverrides.sh"
    fi
fi

# =============================================================================
# Section 3: setDomainEnv.sh (check for existing REPORTS_FONT settings)
# =============================================================================
section "setDomainEnv.sh Check"

SETDOMAINENV="${SETDOMAINENV:-$DOMAIN_HOME/bin/setDomainEnv.sh}"
printList "setDomainEnv.sh" 40 "$SETDOMAINENV"

if [ ! -f "$SETDOMAINENV" ]; then
    warn "setDomainEnv.sh not found: $SETDOMAINENV"
else
    ok "Found: $SETDOMAINENV"

    # Check if setDomainEnv.sh sources setUserOverrides.sh (standard FMW behaviour)
    if grep -q 'setUserOverrides' "$SETDOMAINENV" 2>/dev/null; then
        ok "  setDomainEnv.sh sources setUserOverrides.sh (FMW standard)"
    else
        warn "  setUserOverrides.sh is NOT sourced by setDomainEnv.sh"
        info "  Consider adding to setDomainEnv.sh directly or upgrading the domain"
    fi

    # Show any existing font-related lines
    EXISTING_FONT_LINES="$(grep -n 'REPORTS_FONT\|ENHANCED_FONT' "$SETDOMAINENV" 2>/dev/null)"
    if [ -n "$EXISTING_FONT_LINES" ]; then
        info "  Existing REPORTS_FONT* lines in setDomainEnv.sh:"
        while IFS= read -r line; do
            info "    $line"
        done <<< "$EXISTING_FONT_LINES"
    else
        info "  No REPORTS_FONT* settings in setDomainEnv.sh"
    fi
fi

# =============================================================================
# Section 4: rwserver.conf (information only)
# =============================================================================
section "rwserver.conf (Information)"

RWS="${RWSERVER_CONF:-}"
if [ -z "$RWS" ] || [ ! -f "$RWS" ]; then
    RWS="$(find "$DOMAIN_HOME/config" -name "rwserver.conf" 2>/dev/null | head -1)"
fi

if [ -z "$RWS" ]; then
    warn "rwserver.conf not found under $DOMAIN_HOME/config"
    info "  Expected: \$DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/<server>/rwserver.conf"
else
    ok "Found: $RWS"
    FONT_IN_RWS="$(grep -i 'REPORTS_FONT\|FONTPATH\|ENHANCED_FONT' "$RWS" 2>/dev/null)"
    if [ -n "$FONT_IN_RWS" ]; then
        info "  Existing font settings in rwserver.conf:"
        while IFS= read -r line; do
            info "    $line"
        done <<< "$FONT_IN_RWS"
    else
        info "  No REPORTS_FONT* settings in rwserver.conf (env vars are the preferred method)"
    fi
fi

# =============================================================================
# Section 5: Preview / Apply
# =============================================================================
section "setUserOverrides.sh Update"

LINE_FONT_DIR="export REPORTS_FONT_DIRECTORY=\"${REPORTS_FONT_DIR}\""
LINE_ENHANCED='export REPORTS_ENHANCED_FONTHANDLING="yes"'

if ! $APPLY_MODE; then
    info "Would add/update in $OVERRIDES_SH:"
    info "  $LINE_FONT_DIR"
    info "  $LINE_ENHANCED"
    info ""
    info "Run with --apply to write"
else
    # Create the file if it doesn't exist
    if [ ! -f "$OVERRIDES_SH" ]; then
        info "Creating new setUserOverrides.sh ..."
        mkdir -p "$(dirname "$OVERRIDES_SH")" 2>/dev/null
        {
            printf "#!/bin/bash\n"
            printf "# setUserOverrides.sh – Domain-specific environment customizations\n"
            printf "# Sourced by setDomainEnv.sh at server startup.\n"
            printf "# IHateWeblogic block below is managed by fontpath_config.sh\n"
        } > "$OVERRIDES_SH"
        chmod 750 "$OVERRIDES_SH"
        ok "Created: $OVERRIDES_SH"
    else
        backup_file "$OVERRIDES_SH"
    fi

    # Use Python3 to safely add or replace the managed block
    PY_ACTION="$(python3 - "$OVERRIDES_SH" "$REPORTS_FONT_DIR" <<'PYEOF'
import sys, re

filepath  = sys.argv[1]
font_dir  = sys.argv[2]

marker_s  = "# --- IHateWeblogic: Reports Font Configuration ---\n"
marker_e  = "# --- END IHateWeblogic: Reports Font Configuration ---\n"
line_fd   = f'export REPORTS_FONT_DIRECTORY="{font_dir}"\n'
line_en   = 'export REPORTS_ENHANCED_FONTHANDLING="yes"\n'
new_block = marker_s + line_fd + line_en + marker_e

with open(filepath, "r") as fh:
    content = fh.read()

block_re = re.compile(
    r"# --- IHateWeblogic: Reports Font Configuration ---\n"
    r".*?"
    r"# --- END IHateWeblogic: Reports Font Configuration ---\n",
    re.DOTALL,
)

if block_re.search(content):
    updated = block_re.sub(new_block, content)
    action  = "updated"
else:
    updated = content.rstrip("\n") + "\n\n" + new_block
    action  = "appended"

with open(filepath, "w") as fh:
    fh.write(updated)

print(action)
PYEOF
)"
    PY_RC=$?

    if [ "$PY_RC" -eq 0 ]; then
        ok "setUserOverrides.sh $PY_ACTION"
        info "  $LINE_FONT_DIR"
        info "  $LINE_ENHANCED"
    else
        fail "Failed to update setUserOverrides.sh (python3 rc=$PY_RC)"
    fi
fi

# =============================================================================
# Section 6: Next Steps
# =============================================================================
section "Next Steps"

if ! $APPLY_MODE; then
    info "Run with --apply to write the configuration above"
    info "After configuration:"
fi
info "  1. Restart the Reports Server to pick up the new environment:"
info "       \$DOMAIN_HOME/bin/stopComponent.sh  <reports_server_name>"
info "       \$DOMAIN_HOME/bin/startComponent.sh <reports_server_name>"
info "  2. Run pdf_font_verify.sh <pdf_file>  to confirm fonts are embedded"
info "  Note: REPORTS_FONT_DIRECTORY is read at JVM startup – restart required"

# =============================================================================
# Summary
# =============================================================================
printLine
print_summary
exit $EXIT_CODE
