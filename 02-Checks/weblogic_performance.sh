#!/bin/bash
# =============================================================================
# Script   : weblogic_performance.sh
# Purpose  : Check and optionally apply two WebLogic startup performance settings:
#            1. java.security – securerandom.source (non-blocking entropy source)
#            2. setUserOverrides.sh – JVM heap per managed server + Log4j guard
# Call     : ./weblogic_performance.sh
#            ./weblogic_performance.sh --apply
# Options  : --apply   Interactive update of both settings (backup first)
#            --help    Show usage
# Requires : grep, sed, cp
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 02-Checks/README.md
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

APPLY_MODE=0

_usage() {
    printf "Usage: %s [options]\n\n" "$(basename "$0")"
    printf "  %-16s %s\n" "--apply" "Interactive update of performance settings (backup first)"
    printf "  %-16s %s\n" "--help"  "Show this help"
    printf "\nExamples:\n"
    printf "  %s\n"         "$(basename "$0")"
    printf "  %s --apply\n" "$(basename "$0")"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)   APPLY_MODE=1; shift ;;
        --help|-h) _usage ;;
        *)
            printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2
            _usage
            ;;
    esac
done

# =============================================================================
# Banner
# =============================================================================

printLine
section "WebLogic Performance Settings – $(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-26s %s\n" "Host:"        "$(hostname -f 2>/dev/null || hostname)" | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "JAVA_HOME:"   "${JAVA_HOME:-not set}"                   | tee -a "${LOG_FILE:-/dev/null}"
printf "  %-26s %s\n" "DOMAIN_HOME:" "${DOMAIN_HOME}"                           | tee -a "${LOG_FILE:-/dev/null}"
[ "$APPLY_MODE" -eq 1 ] && \
    printf "  %-26s %s\n" "Mode:" "APPLY (will write changes)" | tee -a "${LOG_FILE:-/dev/null}"
printLine

# =============================================================================
# 1. java.security – SecureRandom Source
# =============================================================================

section "java.security – SecureRandom Source"

# Locate java.security for the configured JAVA_HOME.
# JDK 8  : $JAVA_HOME/jre/lib/security/java.security
# JDK 11+: $JAVA_HOME/conf/security/java.security
_find_java_security() {
    local jh="${JAVA_HOME:-}"
    local candidate

    # JDK 11+ path (also JDK 17, 21)
    candidate="${jh}/conf/security/java.security"
    [ -f "$candidate" ] && { printf "%s" "$candidate"; return; }

    # JDK 8 path
    candidate="${jh}/jre/lib/security/java.security"
    [ -f "$candidate" ] && { printf "%s" "$candidate"; return; }

    # Last resort: find under JAVA_HOME
    find "${jh}" -maxdepth 6 -name "java.security" 2>/dev/null | head -1
}

JAVA_SEC=""
if [ -z "${JAVA_HOME:-}" ]; then
    warn "JAVA_HOME not set – cannot locate java.security"
    info "  Set JAVA_HOME in environment.conf"
else
    JAVA_SEC="$(_find_java_security)"
    if [ -z "$JAVA_SEC" ] || [ ! -f "$JAVA_SEC" ]; then
        warn "java.security not found under JAVA_HOME: $JAVA_HOME"
    else
        ok "Found: $JAVA_SEC"
    fi
fi

if [ -n "$JAVA_SEC" ] && [ -f "$JAVA_SEC" ]; then
    # Extract the effective securerandom.source line (ignore comment lines)
    SR_LINE="$(grep -E '^[[:space:]]*securerandom\.source' "$JAVA_SEC" 2>/dev/null | tail -1)"
    SR_VALUE="$(printf "%s" "${SR_LINE}" | sed 's/.*securerandom\.source[[:space:]]*=[[:space:]]*//')"

    printf "  %-32s %s\n" "securerandom.source:" "${SR_VALUE:-(not set, JVM default)}" \
        | tee -a "${LOG_FILE:-/dev/null}"

    # Evaluate
    case "${SR_VALUE}" in
        "file:/dev/random")
            fail "securerandom.source=file:/dev/random – BLOCKING entropy source"
            warn "WebLogic startup will stall until OS entropy pool is filled"
            info "  Fix: change to file:/dev/./urandom (see --apply)"
            info "  Background: JVM treats /dev/random as blocking; /dev/./urandom bypasses this"
            JAVA_SEC_OK=0
            ;;
        "file:/dev/./urandom"|"file:/dev/./random"|"file:/dev/urandom")
            ok "$(printf "securerandom.source=%s – non-blocking (optimal)" "$SR_VALUE")"
            JAVA_SEC_OK=1
            ;;
        "")
            info "securerandom.source not explicitly set – JVM uses compile-time default"
            info "  On Oracle JDK for Linux the default is /dev/random (may block)"
            info "  Recommendation: set explicitly to file:/dev/./urandom"
            JAVA_SEC_OK=0
            ;;
        *)
            warn "$(printf "securerandom.source=%s – non-standard value, verify correctness" "$SR_VALUE")"
            JAVA_SEC_OK=1
            ;;
    esac

    # --apply: update java.security
    if [ "$APPLY_MODE" -eq 1 ] && [ "${JAVA_SEC_OK:-0}" -eq 0 ]; then
        printf "\n"
        if askYesNo "Set securerandom.source=file:/dev/./urandom in java.security?" "y"; then
            backup_file "$JAVA_SEC" || { fail "Backup failed – aborting java.security change"; }

            if grep -qE '^[[:space:]]*securerandom\.source' "$JAVA_SEC" 2>/dev/null; then
                # Replace existing (commented or uncommented) line
                sed -i 's|^[[:space:]#]*securerandom\.source=.*|securerandom.source=file:/dev/./urandom|' \
                    "$JAVA_SEC"
            else
                # Append if not present at all
                printf '\nsecurerandom.source=file:/dev/./urandom\n' >> "$JAVA_SEC"
            fi
            ok "java.security updated: securerandom.source=file:/dev/./urandom"
            info "No restart required for java.security – takes effect on next JVM start"
        else
            info "java.security – no changes made"
        fi
    fi
fi

# =============================================================================
# 2. setUserOverrides.sh – JVM Heap per Server
# =============================================================================

printLine
section "setUserOverrides.sh – JVM Heap per Server"

OVERRIDES="${DOMAIN_HOME}/bin/setUserOverrides.sh"

if [ ! -f "$OVERRIDES" ]; then
    warn "setUserOverrides.sh not found: $OVERRIDES"
    info "  The file will be created by --apply if confirmed"
    OVERRIDES_EXISTS=0
else
    ok "Found: $OVERRIDES"
    OVERRIDES_EXISTS=1
fi

# Helper: extract USER_MEM_ARGS for a given SERVER_NAME block from the file.
# Searches for:  if [ "${SERVER_NAME}" = "NAME" ]  ...  USER_MEM_ARGS="..."
_mem_args_for() {
    local file="$1"
    local srv="$2"
    awk -v srv="$srv" '
        /SERVER_NAME.*==.*"/ || /SERVER_NAME.*=.*"/ {
            gsub(/.*"/, ""); gsub(/".*/, "")
            current=$0
        }
        current == srv && /USER_MEM_ARGS/ {
            gsub(/.*USER_MEM_ARGS[[:space:]]*=[[:space:]]*"/, "")
            gsub(/".*/, "")
            print; exit
        }
    ' "$file" 2>/dev/null
}

# Parse and display current settings
if [ "$OVERRIDES_EXISTS" -eq 1 ]; then
    MEM_ADMIN="$(_mem_args_for "$OVERRIDES" "AdminServer")"
    MEM_FORMS="$(_mem_args_for "$OVERRIDES" "WLS_FORMS")"
    MEM_REPORTS="$(_mem_args_for "$OVERRIDES" "WLS_REPORTS")"

    printf "\n  %-14s %s\n" "Server" "USER_MEM_ARGS" | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-14s %s\n"   "──────────────" "─────────────────────────────────────" \
        | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-14s %s\n"   "AdminServer"  "${MEM_ADMIN:-(not set)}"  | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-14s %s\n"   "WLS_FORMS"    "${MEM_FORMS:-(not set)}"  | tee -a "${LOG_FILE:-/dev/null}"
    printf "  %-14s %s\n"   "WLS_REPORTS"  "${MEM_REPORTS:-(not set)}"| tee -a "${LOG_FILE:-/dev/null}"
    printf "\n"

    # Log4j CVE-2021-44228 guard
    if grep -q 'LOG4J_FORMAT_MSG_NO_LOOKUPS' "$OVERRIDES" 2>/dev/null; then
        ok "Log4j guard present (LOG4J_FORMAT_MSG_NO_LOOKUPS=true)"
    else
        warn "Log4j CVE-2021-44228 guard missing"
        info "  Add to setUserOverrides.sh:"
        info "    export LOG4J_FORMAT_MSG_NO_LOOKUPS=true"
        info "    export JAVA_OPTIONS=\"\$JAVA_OPTIONS -Dlog4j2.formatMsgNoLookups=true\""
    fi

    # Forms encryption flag
    if grep -q 'forms.userid.encryption.enabled' "$OVERRIDES" 2>/dev/null; then
        ok "Forms user-ID encryption enabled (-Dforms.userid.encryption.enabled=true)"
    else
        info "forms.userid.encryption.enabled not set (optional – encrypts userid in URL)"
    fi

    # Warn on absent server blocks
    [ -z "$MEM_ADMIN"   ] && warn "No USER_MEM_ARGS block for AdminServer in setUserOverrides.sh"
    [ -z "$MEM_FORMS"   ] && warn "No USER_MEM_ARGS block for WLS_FORMS in setUserOverrides.sh"
    [ -z "$MEM_REPORTS" ] && warn "No USER_MEM_ARGS block for WLS_REPORTS in setUserOverrides.sh"
fi

# --apply: write setUserOverrides.sh
if [ "$APPLY_MODE" -eq 1 ]; then
    printLine
    section "Apply – setUserOverrides.sh"
    info "Current values shown in brackets. Press Enter to keep."
    printf "\n"

    _prompt_str() {
        local label="$1"
        local current="$2"
        local answer
        printf "  %s [%s]: " "$label" "${current:--}" >&2
        read -r answer
        printf "%s" "${answer:-$current}"
    }

    NEW_ADMIN="$(  _prompt_str "AdminServer  USER_MEM_ARGS" \
        "${MEM_ADMIN:--Xms1024m -Xmx1536m -XX:MaxMetaspaceSize=2G}")"
    NEW_FORMS="$(  _prompt_str "WLS_FORMS    USER_MEM_ARGS" \
        "${MEM_FORMS:--Xms2g -Xmx2g -XX:NewSize=1g}")"
    NEW_REPORTS="$(_prompt_str "WLS_REPORTS  USER_MEM_ARGS" \
        "${MEM_REPORTS:--Xms2g -Xmx2g -XX:NewSize=1g}")"

    printf "\n  Changes to write:\n"
    printf "    AdminServer:  %s\n" "$NEW_ADMIN"
    printf "    WLS_FORMS:    %s\n" "$NEW_FORMS"
    printf "    WLS_REPORTS:  %s\n" "$NEW_REPORTS"
    printf "\n"

    if ! askYesNo "Write setUserOverrides.sh?" "n"; then
        info "Aborted – no changes written"
        print_summary
        exit 0
    fi

    # Backup if file exists
    [ "$OVERRIDES_EXISTS" -eq 1 ] && \
        { backup_file "$OVERRIDES" || { fail "Backup failed – aborting"; print_summary; exit 2; }; }

    # Write the file
    cat > "$OVERRIDES" << HEREDOC
#!/bin/bash
# =============================================================================
# setUserOverrides.sh – WebLogic JVM performance settings
# Managed by: 02-Checks/weblogic_performance.sh
# Written   : $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================

# Default heap for any server not listed below
export USER_MEM_ARGS="-Xms256m -Xmx512m"

if [ "\${SERVER_NAME}" = "AdminServer" ]; then
    export USER_MEM_ARGS="${NEW_ADMIN}"
    export EXTRA_JAVA_PROPERTIES="\${EXTRA_JAVA_PROPERTIES} -Dforms.userid.encryption.enabled=true"
fi

if [ "\${SERVER_NAME}" = "WLS_FORMS" ]; then
    export USER_MEM_ARGS="${NEW_FORMS}"
    export EXTRA_JAVA_PROPERTIES="\${EXTRA_JAVA_PROPERTIES} -Dforms.userid.encryption.enabled=true"
fi

if [ "\${SERVER_NAME}" = "WLS_REPORTS" ]; then
    export USER_MEM_ARGS="${NEW_REPORTS}"
fi

# Log4j CVE-2021-44228 / CVE-2021-45046 mitigation
export LOG4J_FORMAT_MSG_NO_LOOKUPS=true
export JAVA_OPTIONS="\${JAVA_OPTIONS} -Dlog4j2.formatMsgNoLookups=true"
HEREDOC

    chmod 640 "$OVERRIDES"
    ok "setUserOverrides.sh written: $OVERRIDES"
    warn "Restart all managed servers for changes to take effect"
    info "  ./01-Run/startStop.sh restart AdminServer --apply"
    info "  ./01-Run/startStop.sh restart WLS_FORMS   --apply"
    info "  ./01-Run/startStop.sh restart WLS_REPORTS --apply"
fi

# =============================================================================
# Summary
# =============================================================================

print_summary
exit "$EXIT_CODE"
