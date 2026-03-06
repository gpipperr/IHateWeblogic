#!/bin/bash
# =============================================================================
# Script   : forms_settings.sh
# Purpose  : Configuration overview for Oracle Forms:
#            version, FORMS_PATH, config files, servlet config, fonts,
#            live frmweb processes, shared library dependencies.
# Call     : ./forms_settings.sh
#            ./forms_settings.sh --forms-home /u01/oracle/fmw/forms
# Options  : --forms-home PATH   Explicit ORACLE_FORMS_HOME (auto-detected otherwise)
#            --help              Show usage
# Requires : find, pgrep, ldd (optional)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 06-FormsDiag/README.md
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

check_env_conf "$ENV_CONF" || exit 2
source "$ENV_CONF"
init_log

# =============================================================================
# Arguments
# =============================================================================

OVERRIDE_FORMS_HOME=""

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-28s %s\n" "--forms-home PATH" "Explicit Forms home directory"
    printf "  %-28s %s\n" "--help"            "Show this help"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --forms-home) OVERRIDE_FORMS_HOME="$2"; shift 2 ;;
        --help|-h)    _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
    esac
done

# =============================================================================
# Helper: detect Forms home directory
# =============================================================================

# Tries (in order):
#   1. --forms-home argument
#   2. ORACLE_FORMS_HOME from environment.conf
#   3. $FMW_HOME/forms  (standard FMW layout)
#   4. find frmcmp binary under FMW_HOME
_detect_forms_home() {
    local candidate

    [ -n "$OVERRIDE_FORMS_HOME" ] && { printf "%s" "$OVERRIDE_FORMS_HOME"; return; }
    [ -n "${ORACLE_FORMS_HOME:-}" ] && [ -d "$ORACLE_FORMS_HOME" ] && \
        { printf "%s" "$ORACLE_FORMS_HOME"; return; }

    candidate="${FMW_HOME:-}/forms"
    [ -d "$candidate" ] && { printf "%s" "$candidate"; return; }

    # find via binary
    candidate="$(find "${FMW_HOME:-/u01/oracle/fmw}" -maxdepth 4 -name "frmcmp" \
        2>/dev/null | head -1 | sed 's|/bin/frmcmp||')"
    [ -n "$candidate" ] && { printf "%s" "$candidate"; return; }

    printf ""
}

# Helper: check file and report OK/WARN
_check_file() {
    local label="$1"
    local path="$2"
    if [ -f "$path" ]; then
        ok "$(printf "%-30s %s" "${label}:" "$path")"
        printf "%s" "$path"
    else
        warn "$(printf "%-30s NOT FOUND: %s" "${label}:" "$path")"
        printf ""
    fi
}

# Helper: find formsweb.cfg – checks multiple standard locations
_find_formsweb_cfg() {
    local fh="$1"
    local candidate

    # FMW 14c location
    candidate="$(find "${DOMAIN_HOME}/config/fmwconfig/servers" \
        -maxdepth 5 -name "formsweb.cfg" 2>/dev/null | head -1)"
    [ -n "$candidate" ] && { printf "%s" "$candidate"; return; }

    # Classic location under Forms home
    candidate="${fh}/server/formsweb.cfg"
    [ -f "$candidate" ] && { printf "%s" "$candidate"; return; }

    # Generic search under FMW_HOME
    find "${FMW_HOME:-/u01/oracle/fmw}" -maxdepth 6 -name "formsweb.cfg" \
        2>/dev/null | head -1
}

# Helper: find default.env
_find_default_env() {
    local fh="$1"
    local candidate

    candidate="$(find "${DOMAIN_HOME}/config/fmwconfig/servers" \
        -maxdepth 5 -name "default.env" 2>/dev/null | head -1)"
    [ -n "$candidate" ] && { printf "%s" "$candidate"; return; }

    candidate="${fh}/server/default.env"
    [ -f "$candidate" ] && { printf "%s" "$candidate"; return; }

    find "${FMW_HOME:-/u01/oracle/fmw}" -maxdepth 6 -name "default.env" \
        2>/dev/null | head -1
}

# =============================================================================
# Banner
# =============================================================================

printLine
section "Forms Configuration Overview – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-26s %s\n" "Host:"        "$(hostname -f 2>/dev/null || hostname)" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "FMW_HOME:"    "${FMW_HOME:-not set}"                   | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "DOMAIN_HOME:" "${DOMAIN_HOME}"                          | tee -a "${LOG_FILE:-/dev/null}"
printLine

FORMS_HOME="$(_detect_forms_home)"
if [ -n "$FORMS_HOME" ]; then
    ok "Forms home: $FORMS_HOME"
else
    warn "Forms home directory not detected – some sections may be incomplete"
    info "  Set ORACLE_FORMS_HOME in environment.conf or use --forms-home"
fi

# =============================================================================
# 1. Forms Version
# =============================================================================

printLine
section "Forms Version"

FRMCMP="${FORMS_HOME:+${FORMS_HOME}/bin/frmcmp}"
FRMWEB_BIN="${FORMS_HOME:+${FORMS_HOME}/bin/frmweb}"

if [ -n "$FRMCMP" ] && [ -f "$FRMCMP" ]; then
    ok "frmcmp found: $FRMCMP"
    # frmcmp version string (may take a second, tolerate failure)
    FRMCMP_VER="$("$FRMCMP" -help 2>&1 | grep -i 'version\|release\|Forms' | head -2 || true)"
    [ -n "$FRMCMP_VER" ] && printf "  %s\n" "$FRMCMP_VER" | tee -a "${LOG_FILE:-/dev/null}"
else
    warn "frmcmp not found${FORMS_HOME:+ in $FORMS_HOME/bin}"
fi

# Version from FMW inventory registry
REGISTRY_XML="${FMW_HOME:-}/oracle_common/inventory/registry.xml"
if [ -f "$REGISTRY_XML" ]; then
    FORMS_VER="$(grep -i 'oracle.forms\|FormsHome' "$REGISTRY_XML" 2>/dev/null \
        | grep -oP 'VERSION="\K[^"]+' | head -1)"
    [ -n "$FORMS_VER" ] && \
        printf "  %-26s %s\n" "Registry version:" "$FORMS_VER" | tee -a "${LOG_FILE:-/dev/null}"
fi

# Version from opatch lsinventory (if available and quick)
if command -v opatch > /dev/null 2>&1; then
    info "opatch available – run 'opatch lsinventory' for full patch list"
fi

# =============================================================================
# 2. FORMS_PATH – where are FMX / FMB files?
# =============================================================================

printLine
section "FORMS_PATH (FMX / FMB locations)"

# FORMS_PATH may come from: environment.conf, default.env, running process, or FMW default
FORMS_PATH_VAL="${FORMS_PATH:-}"

# Try to extract from default.env if not set
DEFAULT_ENV_FILE="$(_find_default_env "$FORMS_HOME")"
if [ -z "$FORMS_PATH_VAL" ] && [ -n "$DEFAULT_ENV_FILE" ] && [ -f "$DEFAULT_ENV_FILE" ]; then
    FORMS_PATH_VAL="$(grep -E '^FORMS_PATH' "$DEFAULT_ENV_FILE" 2>/dev/null \
        | tail -1 | sed 's/^FORMS_PATH[[:space:]]*=[[:space:]]*//')"
fi

# Try running WLS_FORMS process environment
if [ -z "$FORMS_PATH_VAL" ]; then
    WLS_FORMS_PID="$(pgrep -f 'weblogic.Name=WLS_FORMS' 2>/dev/null | head -1)"
    if [ -n "$WLS_FORMS_PID" ] && [ -r "/proc/${WLS_FORMS_PID}/environ" ]; then
        FORMS_PATH_VAL="$(tr '\0' '\n' < "/proc/${WLS_FORMS_PID}/environ" 2>/dev/null \
            | grep '^FORMS_PATH=' | sed 's/FORMS_PATH=//' | head -1)"
    fi
fi

if [ -n "$FORMS_PATH_VAL" ]; then
    ok "FORMS_PATH is set"
    # Split on colon and report each directory
    IFS=':' read -ra FP_DIRS <<< "$FORMS_PATH_VAL"
    for fp_dir in "${FP_DIRS[@]}"; do
        [ -z "$fp_dir" ] && continue
        if [ -d "$fp_dir" ]; then
            fmx_count="$(find "$fp_dir" -maxdepth 2 -name "*.fmx" 2>/dev/null | wc -l | tr -d ' ')"
            fmb_count="$(find "$fp_dir" -maxdepth 2 -name "*.fmb" 2>/dev/null | wc -l | tr -d ' ')"
            printf "  %-8s %s  (fmx: %s, fmb: %s)\n" "  DIR:" "$fp_dir" "$fmx_count" "$fmb_count" \
                | tee -a "${LOG_FILE:-/dev/null}"
        else
            warn "FORMS_PATH entry not found: $fp_dir"
        fi
    done
else
    warn "FORMS_PATH not set – Forms cannot find .fmx files at runtime"
    info "  Set FORMS_PATH in default.env or environment.conf"
    # Attempt heuristic search
    if [ -n "$FORMS_HOME" ]; then
        HEURISTIC_FMX="$(find "$FORMS_HOME" "${DOMAIN_HOME}" \
            -maxdepth 5 -name "*.fmx" 2>/dev/null | head -5)"
        if [ -n "$HEURISTIC_FMX" ]; then
            info "  Possible FMX locations found:"
            printf "%s" "$HEURISTIC_FMX" | while IFS= read -r f; do
                printf "    %s\n" "$f" | tee -a "${LOG_FILE:-/dev/null}"
            done
        fi
    fi
fi

# =============================================================================
# 3. Configuration Files
# =============================================================================

printLine
section "Configuration Files"

FORMSWEB_CFG="$(_find_formsweb_cfg "$FORMS_HOME")"
DEFAULT_ENV_FILE="$(_find_default_env "$FORMS_HOME")"

if [ -n "$FORMSWEB_CFG" ] && [ -f "$FORMSWEB_CFG" ]; then
    ok "formsweb.cfg: $FORMSWEB_CFG"
else
    warn "formsweb.cfg not found"
fi

if [ -n "$DEFAULT_ENV_FILE" ] && [ -f "$DEFAULT_ENV_FILE" ]; then
    ok "default.env:  $DEFAULT_ENV_FILE"
else
    warn "default.env not found"
fi

# registry.dat (Forms registry, not Windows registry)
REGISTRY_DAT="${FORMS_HOME:+${FORMS_HOME}/resources/registry.dat}"
if [ -n "$REGISTRY_DAT" ] && [ -f "$REGISTRY_DAT" ]; then
    ok "registry.dat: $REGISTRY_DAT"
else
    info "registry.dat not found at: ${REGISTRY_DAT:-(unknown)}"
fi

# =============================================================================
# 4. Servlet Configuration (formsweb.cfg key parameters)
# =============================================================================

printLine
section "Servlet Configuration (formsweb.cfg)"

if [ -n "$FORMSWEB_CFG" ] && [ -f "$FORMSWEB_CFG" ]; then
    # Extract key values from the [default] or global section (non-indented keys)
    _cfg_val() {
        grep -E "^[[:space:]]*${1}[[:space:]]*=" "$FORMSWEB_CFG" 2>/dev/null \
            | tail -1 | sed "s/^[[:space:]]*${1}[[:space:]]*=[[:space:]]*//"
    }

    CFG_SERVERURL="$(_cfg_val serverURL)"
    CFG_LOOK="$(     _cfg_val lookAndFeel)"
    CFG_HBEAT="$(    _cfg_val heartbeatInterval)"
    CFG_USERID="$(   _cfg_val userid)"
    CFG_MODULE="$(   _cfg_val form)"
    CFG_COLORSCHEME="$(_cfg_val colorScheme)"
    CFG_SEPARATEFRAME="$(_cfg_val separateFrame)"
    CFG_WIDTH="$(    _cfg_val width)"
    CFG_HEIGHT="$(   _cfg_val height)"

    printf "  %-28s %s\n" "serverURL:"        "${CFG_SERVERURL:-(not set)}"     | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-28s %s\n" "lookAndFeel:"      "${CFG_LOOK:-(default)}"          | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-28s %s\n" "heartbeatInterval:""${CFG_HBEAT:-(default)}"         | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-28s %s\n" "separateFrame:"    "${CFG_SEPARATEFRAME:-(default)}" | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-28s %s\n" "colorScheme:"      "${CFG_COLORSCHEME:-(default)}"   | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-28s %s\n" "width × height:"   "${CFG_WIDTH:--} × ${CFG_HEIGHT:--}" | tee -a "${LOG_FILE:-/dev/null}"

    # Count named sections [sectionName]
    SECTION_COUNT="$(grep -cE '^\[[^]]+\]' "$FORMSWEB_CFG" 2>/dev/null || printf 0)"
    printf "  %-28s %s\n" "Named sections:"   "$SECTION_COUNT" | tee -a "${LOG_FILE:-/dev/null}"
    ok "formsweb.cfg parsed"
else
    warn "formsweb.cfg not available – servlet configuration unknown"
fi

# =============================================================================
# 5. Fonts (uifont.ali – Forms section)
# =============================================================================

printLine
section "Font Configuration (Forms)"

# TK_FONTALIAS may be set in environment.conf or default.env
FONTALIAS="${TK_FONTALIAS:-}"
if [ -z "$FONTALIAS" ] && [ -n "$DEFAULT_ENV_FILE" ] && [ -f "$DEFAULT_ENV_FILE" ]; then
    FONTALIAS="$(grep -E '^TK_FONTALIAS' "$DEFAULT_ENV_FILE" 2>/dev/null \
        | tail -1 | sed 's/^TK_FONTALIAS[[:space:]]*=[[:space:]]*//')"
fi
# Last resort: standard path under Forms home
[ -z "$FONTALIAS" ] && FONTALIAS="${FORMS_HOME:+${FORMS_HOME}/resources/uifont.ali}"

printf "  %-26s %s\n" "TK_FONTALIAS:" "${FONTALIAS:-(not set)}" | tee -a "${LOG_FILE:-/dev/null}"

if [ -n "$FONTALIAS" ] && [ -f "$FONTALIAS" ]; then
    ok "uifont.ali found: $FONTALIAS"
    # Check for [PDF:Subset] and [PDF:Base14Fonts] sections
    if grep -q '^\[PDF:Subset\]' "$FONTALIAS" 2>/dev/null; then
        ok "[PDF:Subset] section present"
    else
        warn "[PDF:Subset] section missing – PDF TrueType embedding may not work"
    fi
    # Count alias entries
    ALIAS_COUNT="$(grep -cE '^[[:space:]]*"' "$FONTALIAS" 2>/dev/null || printf 0)"
    printf "  %-26s %s\n" "Alias entries:" "$ALIAS_COUNT" | tee -a "${LOG_FILE:-/dev/null}"
else
    warn "uifont.ali not found – Forms may use system font fallback"
    info "  See: 04-ReportsFonts/uifont_ali_update.sh for font configuration"
fi

# =============================================================================
# 6. Live frmweb Processes
# =============================================================================

printLine
section "Live Forms Sessions (frmweb)"

FRMWEB_COUNT="$(pgrep -f "frmweb" 2>/dev/null | wc -l | tr -d ' ')"
FRMWEB_PIDS="$( pgrep -d ',' -f "frmweb" 2>/dev/null || printf "(none)")"

# WLS_FORMS JVM process
WLS_FORMS_PID="$(pgrep -f 'weblogic.Name=WLS_FORMS' 2>/dev/null | head -1)"

printf "  %-26s %s\n" "WLS_FORMS JVM PID:" "${WLS_FORMS_PID:-(not running)}" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "Active frmweb sessions:" "$FRMWEB_COUNT"               | tee -a "${LOG_FILE:-/dev/null}"
[ "$FRMWEB_COUNT" -gt 0 ] && \
    printf "  %-26s %s\n" "frmweb PIDs:" "$FRMWEB_PIDS" | tee -a "${LOG_FILE:-/dev/null}"

if [ -z "$WLS_FORMS_PID" ]; then
    warn "WLS_FORMS JVM not running"
    info "  Start: ./01-Run/startStop.sh start WLS_FORMS --apply"
elif [ "$FRMWEB_COUNT" -eq 0 ]; then
    ok "WLS_FORMS running – no active frmweb sessions"
else
    ok "$(printf "WLS_FORMS running – %s active session(s)" "$FRMWEB_COUNT")"
fi

# =============================================================================
# 7. Shared Library Dependencies (frmweb)
# =============================================================================

printLine
section "Shared Library Dependencies (frmweb)"

FRMWEB_BIN_PATH="${FORMS_HOME:+${FORMS_HOME}/bin/frmweb}"

if [ -z "$FRMWEB_BIN_PATH" ] || [ ! -f "$FRMWEB_BIN_PATH" ]; then
    # Try to find via running process
    if [ -n "$WLS_FORMS_PID" ]; then
        # WLS_FORMS is the JVM – frmweb is a separate native binary spawned on demand
        info "frmweb binary path: ${FRMWEB_BIN_PATH:-(not found)}"
    else
        warn "frmweb binary not found – cannot check shared library dependencies"
        info "  Set ORACLE_FORMS_HOME in environment.conf or use --forms-home"
    fi
else
    ok "frmweb binary: $FRMWEB_BIN_PATH"
    if command -v ldd > /dev/null 2>&1; then
        MISSING="$(ldd "$FRMWEB_BIN_PATH" 2>/dev/null \
            | grep 'not found' | awk '{print $1}' | sort -u)"
        if [ -n "$MISSING" ]; then
            fail "Missing shared libraries for frmweb:"
            printf "%s" "$MISSING" | while IFS= read -r lib; do
                printf "    \033[31m%s\033[0m\n" "$lib" | tee -a "${LOG_FILE:-/dev/null}"
            done
            info "  Install missing libs: sudo dnf install <package>"
        else
            ok "All shared libraries resolved"
        fi
        # Show LD_LIBRARY_PATH
        LD_PATH="${LD_LIBRARY_PATH:-}"
        [ -n "$LD_PATH" ] && \
            printf "  %-26s %s\n" "LD_LIBRARY_PATH:" "$LD_PATH" | tee -a "${LOG_FILE:-/dev/null}"
    else
        info "ldd not available – shared library check skipped"
    fi
fi

# =============================================================================
# Summary
# =============================================================================

print_summary
exit "$EXIT_CODE"
