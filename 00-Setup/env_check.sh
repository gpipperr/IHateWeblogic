#!/bin/bash
# =============================================================================
# Script   : env_check.sh
# Purpose  : Detect FMW/Domain paths and running processes → generate environment.conf
# Call     : ./env_check.sh [--apply]
#            Without --apply: read-only detection, shows what would be written.
#            With    --apply: writes environment.conf to project root.
# Requires : ps, find, awk, hostname, stat
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : https://docs.oracle.com/en/middleware/developer-tools/forms/14.1.2/
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

# --- Arguments ----------------------------------------------------------------
APPLY=false
INTERVIEW=false
for _arg in "$@"; do
    case "$_arg" in
        --apply)    APPLY=true ;;
        --interview) INTERVIEW=true ;;
        --help|-h)
            printf "Usage: %s [--apply] [--interview]\n\n" "$(basename "$0")"
            printf "  %-20s %s\n" "--apply"     "Write environment.conf (extend existing, never overwrite)"
            printf "  %-20s %s\n" "--interview" "Confirm each detected value interactively before writing"
            printf "\nWithout --apply: dry-run only.\n"
            exit 0
            ;;
    esac
done
unset _arg

# --- Bootstrap log (environment.conf not yet available) ----------------------
LOG_BOOT_DIR="$ROOT_DIR/log/$(date +%Y%m%d)"
mkdir -p "$LOG_BOOT_DIR"
LOG_FILE="$LOG_BOOT_DIR/env_check_$(date +%H%M%S).log"
{
    printf "# env_check.sh log\n"
    printf "# Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# Host    : %s\n" "$(_get_hostname)"
    printf "# Apply   : %s\n" "$APPLY"
    printf "# ---\n"
} > "$LOG_FILE"

# =============================================================================
# Detection helpers
# =============================================================================

# detect_fmw_home
# Scans standard paths and running WLS processes for the FMW installation root.
detect_fmw_home() {
    local result=""

    # 1. Standard Oracle installation paths (check for weblogic.jar as proof)
    for path in \
        /u01/oracle/fmw \
        /u01/app/oracle/fmw \
        /opt/oracle/fmw \
        /oracle/fmw \
        /home/oracle/fmw; do
        if [ -f "${path}/wlserver/server/lib/weblogic.jar" ]; then
            result="$path"
            break
        fi
    done

    # 2. Running WLS process: extract -Dwls.home=<path>/wlserver
    if [ -z "$result" ]; then
        local wls_home
        wls_home="$(ps -eo args 2>/dev/null \
            | grep -oP '(?<=-Dwls\.home=)[^ ]+' \
            | head -1)"
        # wls_home points to <fmw>/wlserver – strip last component
        [ -n "$wls_home" ] && result="${wls_home%/wlserver}"
    fi

    # 3. Environment variables
    if [ -z "$result" ]; then
        for var in MW_HOME ORACLE_HOME; do
            local val="${!var:-}"
            if [ -n "$val" ] && [ -f "${val}/wlserver/server/lib/weblogic.jar" ]; then
                result="$val"
                break
            fi
        done
    fi

    printf "%s" "$result"
}

# detect_domain_home
# Scans running AdminServer/NodeManager processes and standard paths.
detect_domain_home() {
    local result=""

    # 1. Running AdminServer: -Dweblogic.RootDirectory=<path>
    result="$(ps -eo args 2>/dev/null \
        | grep -oP '(?<=-Dweblogic\.RootDirectory=)[^ ]+' \
        | head -1)"

    # 2. Standard domain base directories
    if [ -z "$result" ]; then
        for base in \
            /u01/user_projects/domains \
            /u01/app/oracle/user_projects/domains \
            /home/oracle/user_projects/domains \
            /opt/oracle/user_projects/domains; do
            if [ -d "$base" ]; then
                # First subdirectory that has config/config.xml
                while IFS= read -r -d '' domain_dir; do
                    if [ -f "$domain_dir/config/config.xml" ]; then
                        result="$domain_dir"
                        break 2
                    fi
                done < <(find "$base" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
            fi
        done
    fi

    printf "%s" "$result"
}

# detect_reports_instances  domain_home
# Returns one path per line – all reptools* directories found under ReportsToolsComponent.
detect_reports_instances() {
    local domain_home="$1"
    local reptools_base="$domain_home/config/fmwconfig/components/ReportsToolsComponent"

    if [ ! -d "$reptools_base" ]; then
        return
    fi
    find "$reptools_base" -maxdepth 1 -mindepth 1 -type d -name "reptools*" 2>/dev/null | sort
}

# detect_wls_reports_server  domain_home
# Returns the name of the WLS managed server that has Reports deployed.
detect_wls_reports_server() {
    local domain_home="$1"
    local result=""

    # Scan servers/<name>/applications/ for a reports_* deployment directory
    if [ -d "$domain_home/servers" ]; then
        while IFS= read -r -d '' srv; do
            if [ -d "$srv/applications" ] && \
               ls "$srv/applications/" 2>/dev/null | grep -qi "reports"; then
                result="$(basename "$srv")"
                break
            fi
        done < <(find "$domain_home/servers" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
    fi

    # Fallback: parse config.xml for a server name containing "report"
    if [ -z "$result" ] && [ -f "$domain_home/config/config.xml" ]; then
        result="$(grep -oP '(?<=<name>)[^<]+(?=</name>)' \
            "$domain_home/config/config.xml" 2>/dev/null \
            | grep -iE 'report|WLS_REP' | head -1)"
    fi

    printf "%s" "${result:-WLS_REPORTS}"
}

# detect_java_home  fmw_home
# Checks FMW bundled JDK first, then running processes, then system JAVA_HOME.
detect_java_home() {
    local fmw_home="$1"
    local result=""

    # FMW bundled JDK locations
    for jdk_path in \
        "$fmw_home/oracle_common/jdk" \
        "$fmw_home/jdk" \
        "$fmw_home/../jdk"; do
        if [ -x "${jdk_path}/bin/java" ]; then
            result="$(realpath "$jdk_path" 2>/dev/null || printf "%s" "$jdk_path")"
            break
        fi
    done

    # Running WLS process: -Djava.home=<path>
    if [ -z "$result" ]; then
        result="$(ps -eo args 2>/dev/null \
            | grep -oP '(?<=-Djava\.home=)[^ ]+' \
            | head -1)"
    fi

    # System JAVA_HOME
    if [ -z "$result" ] && [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
        result="$JAVA_HOME"
    fi

    printf "%s" "$result"
}

# detect_oracle_user
# Returns the OS user running WebLogic/Reports processes.
detect_oracle_user() {
    local result
    result="$(ps -eo user,args 2>/dev/null \
        | grep -E 'weblogic|WLS|AdminServer|NodeManager' \
        | grep -v grep \
        | awk '{print $1}' \
        | sort | uniq -c | sort -rn \
        | head -1 \
        | awk '{print $2}')"
    printf "%s" "${result:-oracle}"
}

# detect_jdk_home_os
# Finds an Oracle JDK installed on the OS (by 02b-root_os_java.sh) before FMW exists.
detect_jdk_home_os() {
    local result=""

    # Common Oracle JDK symlink paths (created by 02b-root_os_java.sh)
    for p in \
        /u01/app/oracle/java/jdk-21 \
        /u01/oracle/java/jdk-21 \
        /opt/oracle/java/jdk-21 \
        /home/oracle/java/jdk-21; do
        if [ -x "${p}/bin/java" ]; then
            result="$p"
            break
        fi
    done

    # alternatives: strip /bin/java from the resolved path
    if [ -z "$result" ]; then
        local alt_java
        alt_java="$(update-alternatives --query java 2>/dev/null \
            | awk '/^Value:/{print $2}')"
        if [ -n "$alt_java" ]; then
            result="${alt_java%/bin/java}"
            [ -d "$result" ] || result=""
        fi
    fi

    printf "%s" "$result"
}

# detect_rwserver_conf  domain_home  wls_server
# Finds rwserver.conf by scanning the deployment directory; falls back to template path.
detect_rwserver_conf() {
    local domain_home="$1"
    local wls_server="${2:-WLS_REPORTS}"
    local conf_base="$domain_home/config/fmwconfig/servers/$wls_server/applications"
    local result=""

    # Search for rwserver.conf under this server's application directory
    if [ -d "$conf_base" ]; then
        result="$(find "$conf_base" -name "rwserver.conf" 2>/dev/null | head -1)"
    fi

    # Fallback: search entire domain config
    if [ -z "$result" ]; then
        result="$(find "$domain_home/config" -name "rwserver.conf" 2>/dev/null | head -1)"
    fi

    # If not found at all, provide the standard template path (Reports 12.2.1)
    if [ -z "$result" ]; then
        result="$conf_base/reports_12.2.1/configuration/rwserver.conf"
    fi

    printf "%s" "$result"
}

# detect_cgicmd_dat  rwserver_conf_path
# cgicmd.dat lives in the same configuration directory as rwserver.conf.
detect_cgicmd_dat() {
    local rwserver_conf="$1"
    local conf_dir
    conf_dir="$(dirname "$rwserver_conf")"
    local result="$conf_dir/cgicmd.dat"

    if [ ! -f "$result" ]; then
        # Search fallback
        result="$(find "$(dirname "$conf_dir")" -name "cgicmd.dat" 2>/dev/null | head -1)"
    fi

    printf "%s" "${result:-$conf_dir/cgicmd.dat}"
}

# detect_db_from_jps  domain_home
# Reads jps-config.xml and extracts Oracle DB connection parameters from the
# first DB_ORACLE propertySet.  Sets DET_DB_HOST/PORT/SERVICE/SERVER.
detect_db_from_jps() {
    local domain_home="$1"
    local jps_config="$domain_home/config/fmwconfig/jps-config.xml"
    DET_DB_HOST="" DET_DB_PORT="1521" DET_DB_SERVICE="" DET_DB_SERVER="dedicated"

    [ -f "$jps_config" ] || return 1

    local in_block=0 block="" jdbc_url=""
    while IFS= read -r line; do
        if [[ "$line" == *"<propertySet "* ]]; then
            in_block=1; block="${line}"$'\n'
        elif [ "$in_block" -eq 1 ]; then
            block+="${line}"$'\n'
            if [[ "$line" == *"</propertySet>"* ]]; then
                if printf "%s" "$block" | grep -q 'value="DB_ORACLE"'; then
                    jdbc_url="$(printf "%s" "$block" \
                        | sed -n 's/.*name="jdbc\.url"[[:space:]]*value="\([^"]*\)".*/\1/p' \
                        | head -1)"
                    [ -n "$jdbc_url" ] && break
                fi
                in_block=0; block=""
            fi
        fi
    done < "$jps_config"

    [ -z "$jdbc_url" ] && return 1

    DET_DB_HOST="$(   printf "%s" "$jdbc_url" | sed -n 's/.*host=\([^)]*\).*/\1/p'         | head -1)"
    DET_DB_PORT="$(   printf "%s" "$jdbc_url" | sed -n 's/.*port=\([^)]*\).*/\1/p'         | head -1)"
    DET_DB_SERVICE="$(printf "%s" "$jdbc_url" | sed -n 's/.*service_name=\([^)]*\).*/\1/p' | head -1)"
    DET_DB_SERVER="$( printf "%s" "$jdbc_url" | sed -n 's/.*server=\([^)]*\).*/\1/p'       | head -1)"
    DET_DB_PORT="${DET_DB_PORT:-1521}"
    DET_DB_SERVER="${DET_DB_SERVER:-dedicated}"
    return 0
}

# =============================================================================
# MAIN
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – Environment Check\033[0m\n" | tee -a "$LOG_FILE"
printf "  Version : 1.0.0\n"                                   | tee -a "$LOG_FILE"
printf "  Host    : %s\n" "$(_get_hostname)" | tee -a "$LOG_FILE"
printf "  Date    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"       | tee -a "$LOG_FILE"
printf "  Apply   : %s\n" "$APPLY"                             | tee -a "$LOG_FILE"
printf "  Interview: %s\n" "$INTERVIEW"                       | tee -a "$LOG_FILE"
printf "  Log     : %s\n" "$LOG_FILE"                         | tee -a "$LOG_FILE"
printLine

# =============================================================================
# Helpers – shared by install-param interview and runtime detection
# =============================================================================

# _confirm_val  var  detected  label
# Sets $var = detected, or prompts user to override when INTERVIEW=true.
_confirm_val() {
    local var="$1"
    local detected="$2"
    local label="${3:-$var}"

    if ! $INTERVIEW; then
        eval "${var}=\"${detected}\""
        return 0
    fi

    printf "  \033[1m%-30s\033[0m [%s]: " "$label" "$detected"
    local input
    read -r input
    if [ -z "$input" ]; then
        eval "${var}=\"${detected}\""
    else
        eval "${var}=\"${input}\""
        printf "  \033[32m  ✓  overridden: %s = %s\033[0m\n" "$var" "$input" | tee -a "$LOG_FILE"
    fi
}

# _conf_has_key  key – returns 0 if key already set in ENV_CONF
_conf_has_key() {
    local key="$1"
    [ -f "$ENV_CONF" ] && grep -qE "^${key}=" "$ENV_CONF" 2>/dev/null
}

# _append_if_missing  key  value – appends key="value" only when not yet present
_append_if_missing() {
    local key="$1"
    local val="$2"
    if ! _conf_has_key "$key"; then
        printf '%s="%s"\n' "$key" "$val" >> "$ENV_CONF"
    fi
}

# =============================================================================
# No environment.conf: collect install parameters and exit
# =============================================================================
if [ ! -f "$ENV_CONF" ]; then
    section "No environment.conf – collecting install parameters"
    info "For a full guided interview (incl. passwords/DB) use: 09-Install/01-setup-interview.sh"
    printf "\n"

    INTERVIEW=true

    # Detect Oracle JDK from OS (installed by 02b-root_os_java.sh, needed before FMW)
    DET_JDK_HOME="$(detect_jdk_home_os)"
    if [ -n "$DET_JDK_HOME" ]; then
        ok "Oracle JDK found: $DET_JDK_HOME"
    else
        warn "Oracle JDK not found – will use default (run 09-Install/02b-root_os_java.sh first)"
        DET_JDK_HOME="/u01/app/oracle/java/jdk-21"
    fi

    _confirm_val CONF_ORACLE_BASE    "/u01/app/oracle"                    "ORACLE_BASE"
    _confirm_val CONF_ORACLE_HOME    "\${ORACLE_BASE}/fmw"                "ORACLE_HOME"
    _confirm_val CONF_JDK_HOME       "$DET_JDK_HOME"                     "JDK_HOME"
    _confirm_val CONF_DOMAIN_HOME_I  "\${ORACLE_BASE}/domains/fr_domain"  "DOMAIN_HOME"
    _confirm_val CONF_PATCH_STORAGE  "/srv/patch_storage"                 "PATCH_STORAGE"

    printf "\n  What should be installed?\n"
    printf "    [1] Forms and Reports (default)\n"
    printf "    [2] Forms only\n"
    printf "    [3] Reports only\n"
    printf "  Choice [1]: "
    _ic=""
    read -r _ic
    case "$_ic" in
        2) CONF_INSTALL_COMPONENTS="FORMS_ONLY" ;;
        3) CONF_INSTALL_COMPONENTS="REPORTS_ONLY" ;;
        *) CONF_INSTALL_COMPONENTS="FORMS_AND_REPORTS" ;;
    esac
    unset _ic
    ok "INSTALL_COMPONENTS = $CONF_INSTALL_COMPONENTS"

    if $APPLY; then
        {
            printf "# =============================================================================\n"
            printf "# environment.conf – generated by 00-Setup/env_check.sh\n"
            printf "# Host  : %s\n" "$(_get_hostname)"
            printf "# Date  : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
            printf "# DO NOT check into git!\n"
            printf "# =============================================================================\n"
            printf "\n"
            printf "# === 09-INSTALL === install parameters ======================================\n"
            printf 'ORACLE_BASE="%s"\n'         "$CONF_ORACLE_BASE"
            printf 'ORACLE_HOME="%s"\n'         "$CONF_ORACLE_HOME"
            printf 'JDK_HOME="%s"\n'            "$CONF_JDK_HOME"
            printf 'DOMAIN_HOME="%s"\n'         "$CONF_DOMAIN_HOME_I"
            printf 'PATCH_STORAGE="%s"\n'       "$CONF_PATCH_STORAGE"
            printf 'INSTALL_COMPONENTS="%s"\n'  "$CONF_INSTALL_COMPONENTS"
            printf "# === END 09-INSTALL =========================================================\n"
        } > "$ENV_CONF"
        chmod 600 "$ENV_CONF"
        ok "environment.conf written: $ENV_CONF"
        info "Next:"
        info "  1. 09-Install/01-setup-interview.sh --apply  (domain / DB / MOS / passwords)"
        info "  2. 09-Install/ Phase 0 root scripts"
        info "  3. After FMW install: 00-Setup/env_check.sh --apply  (extend with runtime values)"
    else
        warn "Dry-run – use --apply to write environment.conf"
        printLine
        printf "  Preview (install parameters):\n" | tee -a "$LOG_FILE"
        printList "  ORACLE_BASE"         28 "$CONF_ORACLE_BASE"
        printList "  ORACLE_HOME"         28 "$CONF_ORACLE_HOME"
        printList "  JDK_HOME"            28 "$CONF_JDK_HOME"
        printList "  DOMAIN_HOME"         28 "$CONF_DOMAIN_HOME_I"
        printList "  PATCH_STORAGE"       28 "$CONF_PATCH_STORAGE"
        printList "  INSTALL_COMPONENTS"  28 "$CONF_INSTALL_COMPONENTS"
    fi

    print_summary
    exit $EXIT_CODE
fi

# --------------------------------------------------------------------------
# environment.conf exists → proceed with runtime detection
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
section "Detecting FMW_HOME"
DET_FMW_HOME="$(detect_fmw_home)"

if [ -n "$DET_FMW_HOME" ] && [ -d "$DET_FMW_HOME" ]; then
    ok "FMW_HOME detected: $DET_FMW_HOME"
else
    warn "FMW_HOME not auto-detected – using default: /u01/oracle/fmw"
    DET_FMW_HOME="/u01/oracle/fmw"
fi

printList "FMW_HOME" 30 "$DET_FMW_HOME"

# Verify key FMW components
for component in \
    "wlserver/server/lib/weblogic.jar:WebLogic core JAR" \
    "oracle_common/common/bin/wlst.sh:WLST" \
    "bin/rwrun:rwrun binary" \
    "bin/rwclient:rwclient binary"; do
    local_path="${component%%:*}"
    local_label="${component##*:}"
    if [ -e "$DET_FMW_HOME/$local_path" ]; then
        ok "$local_label: $DET_FMW_HOME/$local_path"
    else
        warn "$local_label not found: $DET_FMW_HOME/$local_path"
    fi
done

# --------------------------------------------------------------------------
section "Detecting DOMAIN_HOME"
DET_DOMAIN_HOME="$(detect_domain_home)"

if [ -n "$DET_DOMAIN_HOME" ] && [ -f "$DET_DOMAIN_HOME/config/config.xml" ]; then
    ok "DOMAIN_HOME detected: $DET_DOMAIN_HOME"
else
    warn "DOMAIN_HOME not auto-detected – using default: /u01/user_projects/domains/fr_domain"
    DET_DOMAIN_HOME="/u01/user_projects/domains/fr_domain"
fi

DET_DOMAIN_NAME="$(basename "$DET_DOMAIN_HOME")"
printList "DOMAIN_HOME"  30 "$DET_DOMAIN_HOME"
printList "DOMAIN_NAME"  30 "$DET_DOMAIN_NAME"

[ -f "$DET_DOMAIN_HOME/config/config.xml" ] \
    && ok "config.xml found" \
    || warn "config.xml not found – domain may not be configured yet"

# --------------------------------------------------------------------------
section "Detecting Reports Component Instances"

mapfile -t DET_REPTOOLS_INSTANCES < <(detect_reports_instances "$DET_DOMAIN_HOME")

if [ "${#DET_REPTOOLS_INSTANCES[@]}" -gt 0 ]; then
    ok "Found ${#DET_REPTOOLS_INSTANCES[@]} Reports component instance(s)"
    local_idx=1
    for inst in "${DET_REPTOOLS_INSTANCES[@]}"; do
        printList "  Instance $local_idx" 28 "$inst"
        local_idx=$((local_idx + 1))
    done
    DET_REPORTS_COMPONENT="${DET_REPTOOLS_INSTANCES[0]}"
else
    warn "No reptools* instances found – using default path"
    DET_REPORTS_COMPONENT="$DET_DOMAIN_HOME/config/fmwconfig/components/ReportsToolsComponent/reptools1"
    DET_REPTOOLS_INSTANCES=("$DET_REPORTS_COMPONENT")
fi

DET_REPORTS_ADMIN="$DET_REPORTS_COMPONENT/guicommon/tk/admin"
DET_UIFONT_ALI="$DET_REPORTS_ADMIN/uifont.ali"
DET_REPORTS_FONT_DIR="$DET_DOMAIN_HOME/reports/fonts"

printList "REPORTS_COMPONENT_HOME" 30 "$DET_REPORTS_COMPONENT"
printList "REPORTS_ADMIN"          30 "$DET_REPORTS_ADMIN"
printList "UIFONT_ALI"             30 "$DET_UIFONT_ALI"
printList "TK_FONTALIAS"           30 "$DET_UIFONT_ALI"
printList "ORACLE_FONTALIAS"       30 "$DET_UIFONT_ALI"
printList "REPORTS_FONT_DIR"       30 "$DET_REPORTS_FONT_DIR"

[ -d "$DET_REPORTS_ADMIN" ] \
    && ok "REPORTS_ADMIN directory exists" \
    || warn "REPORTS_ADMIN not found: $DET_REPORTS_ADMIN"
[ -f "$DET_UIFONT_ALI" ] \
    && ok "uifont.ali found (TK_FONTALIAS / ORACLE_FONTALIAS will point here)" \
    || warn "uifont.ali not found: $DET_UIFONT_ALI"
[ -d "$DET_REPORTS_FONT_DIR" ] \
    && ok "REPORTS_FONT_DIR exists ($(find "$DET_REPORTS_FONT_DIR" -name "*.ttf" -o -name "*.TTF" 2>/dev/null | wc -l) TTF)" \
    || warn "REPORTS_FONT_DIR not found: $DET_REPORTS_FONT_DIR (run deploy_fonts.sh --apply)"

# --------------------------------------------------------------------------
section "Detecting WLS Managed Server"

DET_WLS_MANAGED="$(detect_wls_reports_server "$DET_DOMAIN_HOME")"
printList "WLS_MANAGED_SERVER" 30 "$DET_WLS_MANAGED"

DET_WLS_LOG_DIR="$DET_DOMAIN_HOME/servers/$DET_WLS_MANAGED/logs"
printList "WLS_LOG_DIR" 30 "$DET_WLS_LOG_DIR"

[ -d "$DET_WLS_LOG_DIR" ] \
    && ok "WLS log directory exists" \
    || warn "WLS log directory not found: $DET_WLS_LOG_DIR"

# --------------------------------------------------------------------------
section "Detecting Configuration Files"

DET_RWSERVER_CONF="$(detect_rwserver_conf "$DET_DOMAIN_HOME" "$DET_WLS_MANAGED")"
DET_CGICMD_DAT="$(detect_cgicmd_dat "$DET_RWSERVER_CONF")"
DET_SETDOMAINENV="$DET_DOMAIN_HOME/bin/setDomainEnv.sh"

printList "RWSERVER_CONF" 30 "$DET_RWSERVER_CONF"
printList "CGICMD_DAT"    30 "$DET_CGICMD_DAT"
printList "SETDOMAINENV"  30 "$DET_SETDOMAINENV"

[ -f "$DET_RWSERVER_CONF" ] \
    && ok "rwserver.conf found" \
    || warn "rwserver.conf not found (template path used)"
[ -f "$DET_CGICMD_DAT" ] \
    && ok "cgicmd.dat found" \
    || warn "cgicmd.dat not found (template path used)"
[ -f "$DET_SETDOMAINENV" ] \
    && ok "setDomainEnv.sh found" \
    || warn "setDomainEnv.sh not found"

# --------------------------------------------------------------------------
section "Detecting Java"

DET_JAVA_HOME="$(detect_java_home "$DET_FMW_HOME")"
[ -n "$DET_JAVA_HOME" ] || DET_JAVA_HOME="$DET_FMW_HOME/oracle_common/jdk"
printList "JAVA_HOME" 30 "$DET_JAVA_HOME"

if [ -x "$DET_JAVA_HOME/bin/java" ]; then
    DET_JAVA_VERSION="$("$DET_JAVA_HOME/bin/java" -version 2>&1 | head -1)"
    ok "Java found: $DET_JAVA_VERSION"
else
    warn "java binary not found: $DET_JAVA_HOME/bin/java"
fi

# --------------------------------------------------------------------------
section "Detecting Oracle OS User"

DET_ORACLE_USER="$(detect_oracle_user)"
printList "ORACLE_OS_USER" 30 "$DET_ORACLE_USER"

# --------------------------------------------------------------------------
section "Running WebLogic / Reports Processes"

WLS_PROCS="$(ps -eo pid,user,args 2>/dev/null \
    | grep -E 'weblogic|AdminServer|NodeManager|WLS_|rwserver|repserver' \
    | grep -v grep)"

if [ -n "$WLS_PROCS" ]; then
    ok "WebLogic/Reports processes detected:"
    while IFS= read -r proc_line; do
        printf "  %s\n" "$proc_line" | tee -a "$LOG_FILE"
    done <<< "$WLS_PROCS"
else
    warn "No WebLogic/Reports processes running (domain not started?)"
fi

# --------------------------------------------------------------------------
section "Detecting Oracle DB Connection (jps-config.xml)"

DET_DB_HOST="" DET_DB_PORT="1521" DET_DB_SERVICE="" DET_DB_SERVER="dedicated"

if detect_db_from_jps "$DET_DOMAIN_HOME"; then
    ok "DB_ORACLE-Verbindung in jps-config.xml gefunden"
    printList "DB_HOST"    30 "$DET_DB_HOST"
    printList "DB_PORT"    30 "$DET_DB_PORT"
    printList "DB_SERVICE" 30 "$DET_DB_SERVICE"
    printList "DB_SERVER"  30 "$DET_DB_SERVER"
else
    info "Keine DB_ORACLE-Verbindung erkannt (jps-config.xml fehlt oder kein DB_ORACLE-Eintrag)"
    info "  Manuell konfigurieren: 02-Checks/db_connect_check.sh --new"
fi

# Check DISPLAY for Xvfb (relevant for rwrun segfault)
section "X11 Display Check"
if [ -n "${DISPLAY:-}" ]; then
    printList "DISPLAY" 30 "${DISPLAY}"
    ok "DISPLAY is set: ${DISPLAY}"
else
    warn "DISPLAY is not set – rwrun may segfault without Xvfb"
    info "Fix: run 02-Checks/display_check.sh"
fi

# =============================================================================
# Generate environment.conf
# =============================================================================
section "Generate environment.conf"

# Run interview prompts when requested
if $INTERVIEW; then
    printLine
    printf "\n  Confirm detected values (Enter = keep, type to override):\n\n"
fi

_confirm_val CONF_FMW_HOME         "$DET_FMW_HOME"       "FMW_HOME"
_confirm_val CONF_JAVA_HOME        "$DET_JAVA_HOME"       "JAVA_HOME"
_confirm_val CONF_DOMAIN_HOME      "$DET_DOMAIN_HOME"     "DOMAIN_HOME"
_confirm_val CONF_REPORTS_COMP     "$DET_REPORTS_COMPONENT" "REPORTS_COMPONENT_HOME"
_confirm_val CONF_WLS_MANAGED      "$DET_WLS_MANAGED"     "WLS_MANAGED_SERVER"
_confirm_val CONF_RWSERVER_CONF    "$DET_RWSERVER_CONF"   "RWSERVER_CONF"
_confirm_val CONF_CGICMD_DAT       "$DET_CGICMD_DAT"      "CGICMD_DAT"
_confirm_val CONF_ORACLE_USER      "$DET_ORACLE_USER"     "ORACLE_OS_USER"
_confirm_val CONF_DB_HOST          "$DET_DB_HOST"         "DB_HOST"
_confirm_val CONF_DB_PORT          "${DET_DB_PORT:-1521}"  "DB_PORT"
_confirm_val CONF_DB_SERVICE       "$DET_DB_SERVICE"      "DB_SERVICE"
_confirm_val CONF_DB_SERVER        "${DET_DB_SERVER:-dedicated}" "DB_SERVER"

# Build REPORTS_INSTANCES array string
INSTANCES_ARRAY_STR=""
for inst in "${DET_REPTOOLS_INSTANCES[@]}"; do
    INSTANCES_ARRAY_STR="${INSTANCES_ARRAY_STR}  \"${inst}\"\n"
done

# ---------------------------------------------------------------------------
if $APPLY; then

    if [ -f "$ENV_CONF" ]; then
        # --- Extend mode: existing conf – only append missing runtime keys ---
        backup_file "$ENV_CONF" "$ROOT_DIR"

        # Add runtime section header once
        if ! grep -q "# --- Runtime: env_check.sh" "$ENV_CONF" 2>/dev/null; then
            {
                printf "\n"
                printf "# --- Runtime: env_check.sh auto-detected %s ---\n" \
                    "$(date '+%Y-%m-%d %H:%M:%S')"
            } >> "$ENV_CONF"
        fi

        _append_if_missing "FMW_HOME"              "$CONF_FMW_HOME"
        _append_if_missing "WL_HOME"               "\${FMW_HOME}/wlserver"
        _append_if_missing "JAVA_HOME"             "$CONF_JAVA_HOME"
        _append_if_missing "DOMAIN_HOME"           "$CONF_DOMAIN_HOME"
        _append_if_missing "DOMAIN_NAME"           "$DET_DOMAIN_NAME"
        _append_if_missing "WL_ADMIN_URL"          "t3://localhost:7001"
        _append_if_missing "WLS_MANAGED_SERVER"    "$CONF_WLS_MANAGED"
        _append_if_missing "REPORTS_COMPONENT_HOME" "$CONF_REPORTS_COMP"
        _append_if_missing "REPORTS_ADMIN"         "\${REPORTS_COMPONENT_HOME}/guicommon/tk/admin"
        _append_if_missing "UIFONT_ALI"            "\${REPORTS_ADMIN}/uifont.ali"
        _append_if_missing "TK_FONTALIAS"          "\${UIFONT_ALI}"
        _append_if_missing "ORACLE_FONTALIAS"      "\${UIFONT_ALI}"
        _append_if_missing "REPORTS_FONT_DIR"      "\${DOMAIN_HOME}/reports/fonts"
        _append_if_missing "RWRUN"                 "\${FMW_HOME}/bin/rwrun"
        _append_if_missing "RWCLIENT"              "\${FMW_HOME}/bin/rwclient"
        _append_if_missing "WLST"                  "\${FMW_HOME}/oracle_common/common/bin/wlst.sh"
        _append_if_missing "RWSERVER_CONF"         "$CONF_RWSERVER_CONF"
        _append_if_missing "CGICMD_DAT"            "$CONF_CGICMD_DAT"
        _append_if_missing "SETDOMAINENV"          "\${DOMAIN_HOME}/bin/setDomainEnv.sh"
        _append_if_missing "WLS_LOG_DIR"           "\${DOMAIN_HOME}/servers/\${WLS_MANAGED_SERVER}/logs"
        _append_if_missing "DIAG_LOG_DIR"          "\${ROOT_DIR}/log/\$(date +%Y%m%d)"
        _append_if_missing "SEC_CONF"              "\${ROOT_DIR}/weblogic_sec.conf.des3"
        _append_if_missing "ORACLE_OS_USER"        "$CONF_ORACLE_USER"
        _append_if_missing "DB_HOST"               "$CONF_DB_HOST"
        _append_if_missing "DB_PORT"               "$CONF_DB_PORT"
        _append_if_missing "DB_SERVICE"            "$CONF_DB_SERVICE"
        _append_if_missing "DB_SERVER"             "$CONF_DB_SERVER"
        _append_if_missing "SQLPLUS_BIN"           ""
        _append_if_missing "SEC_CONF_DB"           "\${ROOT_DIR}/db_connect.conf.des3"
        _append_if_missing "LOCAL_REP_DB"          "false"
        _append_if_missing "DISPLAY_VAR"           ":99"

        # REPORTS_INSTANCES array: only add if not present
        if ! _conf_has_key "REPORTS_INSTANCES"; then
            {
                printf 'REPORTS_INSTANCES=(\n'
                printf "%b" "$INSTANCES_ARRAY_STR"
                printf ')\n'
            } >> "$ENV_CONF"
        fi

        chmod 600 "$ENV_CONF"
        ok "environment.conf extended with missing runtime values: $ENV_CONF"

    else
        # --- Fresh write: no existing conf ---
        cat > "$ENV_CONF" <<ENVEOF
# =============================================================================
# environment.conf – generated by 00-Setup/env_check.sh
# Host  : $(_get_hostname)
# Date  : $(date '+%Y-%m-%d %H:%M:%S')
# DO NOT check into git!
# =============================================================================

# --- Oracle FMW Installation -------------------------------------------------
FMW_HOME="${CONF_FMW_HOME}"
WL_HOME="\${FMW_HOME}/wlserver"
JAVA_HOME="${CONF_JAVA_HOME}"

# --- WebLogic Domain ---------------------------------------------------------
DOMAIN_HOME="${CONF_DOMAIN_HOME}"
DOMAIN_NAME="${DET_DOMAIN_NAME}"
WL_ADMIN_URL="t3://localhost:7001"
WLS_MANAGED_SERVER="${CONF_WLS_MANAGED}"

# --- Reports Component (primary instance) ------------------------------------
REPORTS_COMPONENT_HOME="${CONF_REPORTS_COMP}"
REPORTS_ADMIN="\${REPORTS_COMPONENT_HOME}/guicommon/tk/admin"
UIFONT_ALI="\${REPORTS_ADMIN}/uifont.ali"
# TK_FONTALIAS / ORACLE_FONTALIAS: override uifont.ali search path so Oracle
# Reports uses the domain-config file (not the one in the FMW install tree).
TK_FONTALIAS="\${UIFONT_ALI}"
ORACLE_FONTALIAS="\${UIFONT_ALI}"
REPORTS_FONT_DIR="\${DOMAIN_HOME}/reports/fonts"

# --- All detected Reports instances (bash array) -----------------------------
REPORTS_INSTANCES=(
$(printf "%b" "$INSTANCES_ARRAY_STR"))

# --- Reports / Forms Binaries ------------------------------------------------
RWRUN="\${FMW_HOME}/bin/rwrun"
RWCLIENT="\${FMW_HOME}/bin/rwclient"
WLST="\${FMW_HOME}/oracle_common/common/bin/wlst.sh"

# --- Configuration Files -----------------------------------------------------
RWSERVER_CONF="${CONF_RWSERVER_CONF}"
CGICMD_DAT="${CONF_CGICMD_DAT}"
SETDOMAINENV="\${DOMAIN_HOME}/bin/setDomainEnv.sh"

# --- Log Directories ---------------------------------------------------------
WLS_LOG_DIR="\${DOMAIN_HOME}/servers/\${WLS_MANAGED_SERVER}/logs"
DIAG_LOG_DIR="\${ROOT_DIR}/log/\$(date +%Y%m%d)"

# --- Security ----------------------------------------------------------------
SEC_CONF="\${ROOT_DIR}/weblogic_sec.conf.des3"
ORACLE_OS_USER="${CONF_ORACLE_USER}"

# --- Oracle DB Connection (auto-detected from jps-config.xml) ----------------
# Configure manually: 02-Checks/db_connect_check.sh --new
DB_HOST="${CONF_DB_HOST}"
DB_PORT="${CONF_DB_PORT}"
DB_SERVICE="${CONF_DB_SERVICE}"
DB_SERVER="${CONF_DB_SERVER}"
SQLPLUS_BIN=""       # optional: /path/to/sqlplus
SEC_CONF_DB="\${ROOT_DIR}/db_connect.conf.des3"

# LOCAL_REP_DB: true if an Oracle DB runs on THIS host alongside WebLogic.
# false → conflicting preinstall sysctl values are flagged/removed.
# true  → only WARN, not modified (local DB needs larger shm values).
LOCAL_REP_DB="false"

# --- X11 / Display -----------------------------------------------------------
DISPLAY_VAR=":99"
ENVEOF

        chmod 600 "$ENV_CONF"
        ok "environment.conf written (fresh): $ENV_CONF"
    fi

    info "Next step: run 00-Setup/weblogic_sec.sh --apply"

else
    warn "Dry-run: environment.conf NOT written (use --apply to write)"
    info "Would write to: $ENV_CONF"
    printLine
    printf "  Preview (key values detected):\n" | tee -a "$LOG_FILE"
    printList "  FMW_HOME"              28 "$CONF_FMW_HOME"
    printList "  DOMAIN_HOME"           28 "$CONF_DOMAIN_HOME"
    printList "  REPORTS_COMPONENT"     28 "$CONF_REPORTS_COMP"
    printList "  WLS_MANAGED_SERVER"    28 "$CONF_WLS_MANAGED"
    printList "  JAVA_HOME"             28 "$CONF_JAVA_HOME"
    printList "  RWSERVER_CONF"         28 "$CONF_RWSERVER_CONF"
    printList "  ORACLE_OS_USER"        28 "$CONF_ORACLE_USER"
    [ -f "$ENV_CONF" ] && \
        info "Existing conf will be EXTENDED (missing keys only) – existing values kept"
fi

# =============================================================================
print_summary
exit $EXIT_CODE
