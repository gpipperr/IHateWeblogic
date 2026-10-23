#!/bin/bash
# =============================================================================
# Script   : init_env.sh
# Purpose  : Detect FMW/Domain paths and running processes → generate a named
#            environment conf file in 00-Setup/environments/ and update the
#            environment.conf symlink in the project root.
#            Use once per environment (installation time or new domain).
#            For daily environment switching use set_env.sh instead.
#
# Call     : ./00-Setup/init_env.sh [--apply] [--interview]
#              FMW mode (default): detect FMW/Domain paths, write environments/<domain>.conf
#                                  + update environment.conf symlink
#            ./00-Setup/init_env.sh --db [--apply] [--interview]
#              DB  mode:           detect Oracle DB home, write environments/db_<SID>.conf
#                                  symlink is NOT changed (FMW env stays active)
#            Without --apply: dry-run – show what would be detected/written.
#            With    --interview: confirm each detected value interactively.
#
# Output   : 00-Setup/environments/<domain_name>.conf   (FMW)
#            00-Setup/environments/db_<SID>.conf         (DB)
#            environment.conf → symlink, only updated in FMW mode
#
# Requires : ps, find, awk, hostname, stat, ln
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 00-Setup/set_environment.md
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_SH="$SCRIPT_DIR/IHateWeblogic_lib.sh"
ENV_CONF_DIR="$SCRIPT_DIR/environments"
ENV_LINK="$ROOT_DIR/environment.conf"    # always a symlink after first --apply

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
DB_MODE=false
for _arg in "$@"; do
    case "$_arg" in
        --apply)     APPLY=true ;;
        --interview) INTERVIEW=true ;;
        --db)        DB_MODE=true ;;
        --help|-h)
            printf "Usage: %s [--apply] [--interview] [--db]\n\n" "$(basename "$0")"
            printf "  %-20s %s\n" "--apply"     "Write environments/<name>.conf and update symlink"
            printf "  %-20s %s\n" "--interview" "Confirm each detected value interactively before writing"
            printf "  %-20s %s\n" "--db"        "Detect Oracle DB home and create environments/db_<SID>.conf"
            printf "\nWithout --apply: dry-run only.\n"
            printf "Output: %s/<domain_name|db_SID>.conf\n" "$ENV_CONF_DIR"
            exit 0
            ;;
    esac
done
unset _arg

# --- Bootstrap log (environment.conf may not yet be available) ----------------
LOG_BOOT_DIR="$ROOT_DIR/log/$(date +%Y%m%d)"
mkdir -p "$LOG_BOOT_DIR"
LOG_FILE="$LOG_BOOT_DIR/init_env_$(date +%H%M%S).log"
{
    printf "# init_env.sh log\n"
    printf "# Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# Host    : %s\n" "$(_get_hostname)"
    printf "# Apply   : %s\n" "$APPLY"
    printf "# ---\n"
} > "$LOG_FILE"

mkdir -p "$ENV_CONF_DIR"

# =============================================================================
# DB MODE  (--db flag): detect Oracle DB home → write environments/db_<SID>.conf
# Exits after completion; the FMW detection below is skipped.
# =============================================================================
if $DB_MODE; then
    printf "\n\033[1m  IHateWeblogic – DB Environment Initialisation\033[0m\n" | tee -a "$LOG_FILE"
    printf "  Host   : %s\n" "$(_get_hostname)" | tee -a "$LOG_FILE"
    printf "  Apply  : %s\n" "$APPLY"           | tee -a "$LOG_FILE"
    printLine

    section "Detecting Oracle DB SID"
    DET_DB_SID="$(detect_oracle_sid)"
    if [ -n "$DET_DB_SID" ]; then
        ok "ORACLE_SID detected: $DET_DB_SID"
    else
        warn "ORACLE_SID not auto-detected"
        if $INTERVIEW; then
            printf "  ORACLE_SID [ORCL]: "
            read -r DET_DB_SID </dev/tty
            [ -z "$DET_DB_SID" ] && DET_DB_SID="ORCL"
        else
            DET_DB_SID="ORCL"
            info "  Using default: ORCL  (use --interview to override)"
        fi
    fi

    section "Detecting Oracle DB Home"
    DET_DB_ORACLE_HOME="$(detect_db_home "$DET_DB_SID")"
    if [ -n "$DET_DB_ORACLE_HOME" ] && [ -f "$DET_DB_ORACLE_HOME/bin/sqlplus" ]; then
        ok "ORACLE_HOME detected: $DET_DB_ORACLE_HOME"
    else
        warn "DB ORACLE_HOME not auto-detected"
        if $INTERVIEW; then
            printf "  ORACLE_HOME [/u01/app/oracle/product/19c/dbhome_1]: "
            read -r DET_DB_ORACLE_HOME </dev/tty
            [ -z "$DET_DB_ORACLE_HOME" ] && DET_DB_ORACLE_HOME="/u01/app/oracle/product/19c/dbhome_1"
        else
            DET_DB_ORACLE_HOME="/u01/app/oracle/product/19c/dbhome_1"
            info "  Using default (use --interview to override)"
        fi
    fi

    DET_DB_ORACLE_BASE="$(detect_oracle_base "$DET_DB_ORACLE_HOME")"
    printList "ORACLE_HOME" 28 "$DET_DB_ORACLE_HOME"
    printList "ORACLE_BASE" 28 "$DET_DB_ORACLE_BASE"

    # sqlplus version check
    if [ -x "$DET_DB_ORACLE_HOME/bin/sqlplus" ]; then
        DET_DB_VER="$("$DET_DB_ORACLE_HOME/bin/sqlplus" -V 2>/dev/null | head -1)"
        ok "sqlplus: $DET_DB_VER"
    else
        warn "sqlplus not found: $DET_DB_ORACLE_HOME/bin/sqlplus"
    fi

    section "Detecting NLS_LANG and DB Connection"
    DET_NLS_LANG="${NLS_LANG:-AMERICAN_AMERICA.AL32UTF8}"
    DET_DB_HOST="localhost"
    DET_DB_PORT="1521"
    DET_DB_SERVICE="$DET_DB_SID"

    # /etc/oratab has no connection details; try tnsnames.ora
    local_tns="$DET_DB_ORACLE_HOME/network/admin/tnsnames.ora"
    if [ -f "$local_tns" ]; then
        ok "tnsnames.ora found: $local_tns"
        DET_DB_HOST="$(grep -A5 -i "${DET_DB_SID}" "$local_tns" 2>/dev/null \
            | grep -oiP '(?<=HOST\s=\s)\S+' | tr -d '()' | head -1)"
        DET_DB_PORT="$(grep -A5 -i "${DET_DB_SID}" "$local_tns" 2>/dev/null \
            | grep -oiP '(?<=PORT\s=\s)\d+' | head -1)"
        [ -z "$DET_DB_HOST" ] && DET_DB_HOST="localhost"
        [ -z "$DET_DB_PORT" ] && DET_DB_PORT="1521"
    else
        info "tnsnames.ora not found – using defaults"
    fi

    if $INTERVIEW; then
        printf "\n  Confirm values (Enter = keep, type to override):\n\n"
        printf "  %-28s [%s]: " "ORACLE_SID" "$DET_DB_SID"
        read -r _in </dev/tty; [ -n "$_in" ] && DET_DB_SID="$_in"

        printf "  %-28s [%s]: " "ORACLE_HOME" "$DET_DB_ORACLE_HOME"
        read -r _in </dev/tty; [ -n "$_in" ] && DET_DB_ORACLE_HOME="$_in"

        printf "  %-28s [%s]: " "ORACLE_BASE" "$DET_DB_ORACLE_BASE"
        read -r _in </dev/tty; [ -n "$_in" ] && DET_DB_ORACLE_BASE="$_in"

        printf "  %-28s [%s]: " "NLS_LANG" "$DET_NLS_LANG"
        read -r _in </dev/tty; [ -n "$_in" ] && DET_NLS_LANG="$_in"

        printf "  %-28s [%s]: " "DB_HOST" "$DET_DB_HOST"
        read -r _in </dev/tty; [ -n "$_in" ] && DET_DB_HOST="$_in"

        printf "  %-28s [%s]: " "DB_PORT" "$DET_DB_PORT"
        read -r _in </dev/tty; [ -n "$_in" ] && DET_DB_PORT="$_in"

        printf "  %-28s [%s]: " "DB_SERVICE" "$DET_DB_SERVICE"
        read -r _in </dev/tty; [ -n "$_in" ] && DET_DB_SERVICE="$_in"
        unset _in
    fi

    printList "ORACLE_SID"  28 "$DET_DB_SID"
    printList "NLS_LANG"    28 "$DET_NLS_LANG"
    printList "DB_HOST"     28 "$DET_DB_HOST"
    printList "DB_PORT"     28 "$DET_DB_PORT"
    printList "DB_SERVICE"  28 "$DET_DB_SERVICE"

    DB_ENV_NAME="db_${DET_DB_SID}"
    DB_ENV_CONF="$ENV_CONF_DIR/${DB_ENV_NAME}.conf"
    printList "Conf target" 28 "$DB_ENV_CONF"

    section "Writing DB environment conf"
    printLine

    if $APPLY; then
        if [ -f "$DB_ENV_CONF" ]; then
            backup_file "$DB_ENV_CONF" "$ENV_CONF_DIR"
        fi

        cat > "$DB_ENV_CONF" <<DBENVEOF
# ENV_TYPE=DB
# ENV_LABEL=Oracle DB ${DET_DB_SID} @ $(_get_hostname)
# =============================================================================
# environment conf – Oracle Database Home
# Generated by 00-Setup/init_env.sh --db
# Host : $(_get_hostname)
# Date : $(date '+%Y-%m-%d %H:%M:%S')
# DO NOT check into git!
# =============================================================================

ORACLE_HOME="${DET_DB_ORACLE_HOME}"
ORACLE_BASE="${DET_DB_ORACLE_BASE}"
ORACLE_SID="${DET_DB_SID}"
NLS_LANG="${DET_NLS_LANG}"

# Optional: used by IHateWeblogic DB scripts
DB_HOST="${DET_DB_HOST}"
DB_PORT="${DET_DB_PORT}"
DB_SERVICE="${DET_DB_SERVICE}"
DBENVEOF

        chmod 600 "$DB_ENV_CONF"
        ok "DB conf written: $DB_ENV_CONF"
        info "Activate with: . ./00-Setup/set_env.sh"
    else
        warn "Dry-run – use --apply to write conf"
        printf "  Would write: %s\n" "$DB_ENV_CONF" | tee -a "$LOG_FILE"
    fi

    print_summary
    exit $EXIT_CODE
fi

# =============================================================================
# Detection helpers
# =============================================================================

# detect_oracle_home
# Scans standard paths and running WLS processes for the FMW installation root.
detect_oracle_home() {
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
        # wls_home points to <oracle_home>/wlserver – strip last component
        [ -n "$wls_home" ] && result="${wls_home%/wlserver}"
    fi

    # 3. Environment variables
    if [ -z "$result" ]; then
        for var in ORACLE_HOME MW_HOME; do
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
# Returns one path per line – all reptools* directories under ReportsToolsComponent.
detect_reports_instances() {
    local domain_home="$1"
    local reptools_base="$domain_home/config/fmwconfig/components/ReportsToolsComponent"

    [ -d "$reptools_base" ] || return
    find "$reptools_base" -maxdepth 1 -mindepth 1 -type d -name "reptools*" 2>/dev/null | sort
}

# detect_reports_server_instances  domain_home
# Returns one name per line – all instance names under ReportsServerComponent.
detect_reports_server_instances() {
    local domain_home="$1"
    local repserver_base="$domain_home/config/fmwconfig/components/ReportsServerComponent"

    # No default here – the caller falls back to the interview values
    [ -d "$repserver_base" ] || return
    find "$repserver_base" -maxdepth 1 -mindepth 1 -type d -name "repserver*" 2>/dev/null \
        | xargs -I{} basename {} | sort
}

# detect_forms_instance  domain_home
# Returns the Forms instance name (basename) from the FORMS/instances directory.
detect_forms_instance() {
    local domain_home="$1"
    local forms_base="$domain_home/config/fmwconfig/components/FORMS/instances"
    local result=""

    if [ -d "$forms_base" ]; then
        result="$(find "$forms_base" -maxdepth 1 -mindepth 1 -type d 2>/dev/null \
            | sort | head -1 | xargs -r basename 2>/dev/null)"
    fi

    printf "%s" "${result:-forms1}"
}

# detect_wls_forms_server  domain_home
# Returns the name of the WLS managed server that has Forms deployed.
detect_wls_forms_server() {
    local domain_home="$1"
    local result=""

    if [ -f "$domain_home/config/config.xml" ]; then
        result="$(grep -oP '(?<=<name>)[^<]+(?=</name>)' \
            "$domain_home/config/config.xml" 2>/dev/null \
            | grep -iE 'forms|WLS_FORM' | head -1)"
    fi

    printf "%s" "${result:-WLS_FORMS}"
}

# detect_wls_reports_server  domain_home
# Returns the name of the WLS managed server that has Reports deployed.
detect_wls_reports_server() {
    local domain_home="$1"
    local result=""

    if [ -d "$domain_home/servers" ]; then
        while IFS= read -r -d '' srv; do
            if [ -d "$srv/applications" ] && \
               ls "$srv/applications/" 2>/dev/null | grep -qi "reports"; then
                result="$(basename "$srv")"
                break
            fi
        done < <(find "$domain_home/servers" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
    fi

    if [ -z "$result" ] && [ -f "$domain_home/config/config.xml" ]; then
        result="$(grep -oP '(?<=<name>)[^<]+(?=</name>)' \
            "$domain_home/config/config.xml" 2>/dev/null \
            | grep -iE 'report|WLS_REP' | head -1)"
    fi

    printf "%s" "${result:-WLS_REPORTS}"
}

# detect_java_home  oracle_home
# Checks FMW bundled JDK first, then running processes, then system JAVA_HOME.
detect_java_home() {
    local oracle_home="$1"
    local result=""

    for jdk_path in \
        "$oracle_home/oracle_common/jdk" \
        "$oracle_home/jdk" \
        "$oracle_home/../jdk"; do
        if [ -x "${jdk_path}/bin/java" ]; then
            result="$(realpath "$jdk_path" 2>/dev/null || printf "%s" "$jdk_path")"
            break
        fi
    done

    if [ -z "$result" ]; then
        result="$(ps -eo args 2>/dev/null \
            | grep -oP '(?<=-Djava\.home=)[^ ]+' \
            | head -1)"
    fi

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

# detect_db_home  [oracle_sid]
# Returns the Oracle DB ORACLE_HOME: /etc/oratab → ora_pmon process → standard paths.
detect_db_home() {
    local sid="${1:-}"
    local result=""

    # 1. /etc/oratab – most reliable source on Linux
    if [ -f /etc/oratab ]; then
        while IFS=: read -r orasid orahome _; do
            [[ "$orasid" == \#* ]] && continue
            [ -z "$orasid" ] && continue
            if [ -n "$sid" ] && [ "$orasid" != "$sid" ]; then continue; fi
            if [ -f "${orahome}/bin/sqlplus" ]; then
                result="$orahome"
                break
            fi
        done < /etc/oratab
    fi

    # 2. Running ora_pmon_<SID>: binary path is $ORACLE_HOME/bin/oracle
    if [ -z "$result" ]; then
        local pmon_exe
        pmon_exe="$(ps -eo args 2>/dev/null \
            | grep -E '^ora_pmon_' | grep -v grep | awk '{print $1}' | head -1)"
        if [ -n "$pmon_exe" ] && [ -f "$pmon_exe" ]; then
            result="$(dirname "$(dirname "$pmon_exe")")"
        fi
    fi

    # 3. Standard Oracle DB installation paths
    if [ -z "$result" ]; then
        for p in \
            /u01/app/oracle/product/19c/dbhome_1 \
            /u01/app/oracle/product/19c/db_1 \
            /u01/oracle/product/19c/dbhome_1 \
            /opt/oracle/product/19c/dbhome_1 \
            /home/oracle/product/19c/dbhome_1; do
            [ -f "${p}/bin/sqlplus" ] && result="$p" && break
        done
    fi

    printf "%s" "$result"
}

# detect_oracle_sid
# Returns the ORACLE_SID: ora_pmon process name → /etc/oratab first active entry.
detect_oracle_sid() {
    local result=""

    # 1. Running instance: process name is ora_pmon_<SID>
    result="$(ps -eo comm 2>/dev/null \
        | grep -oP '(?<=ora_pmon_)\S+' \
        | head -1)"

    # 2. /etc/oratab – first non-comment entry
    if [ -z "$result" ] && [ -f /etc/oratab ]; then
        while IFS=: read -r orasid _ flag; do
            [[ "$orasid" == \#* ]] && continue
            [ -z "$orasid" ] && continue
            result="$orasid"
            break
        done < /etc/oratab
    fi

    printf "%s" "$result"
}

# detect_oracle_base  oracle_home
# Derives ORACLE_BASE from ORACLE_HOME using the standard Oracle directory layout.
# Standard layout: $ORACLE_BASE/product/<ver>/dbhome_1 → strip last 3 components.
detect_oracle_base() {
    local oracle_home="$1"
    local base
    base="$(dirname "$(dirname "$(dirname "$oracle_home")")")"
    # Fallback: read orabasetab if present
    local orabasetab="$oracle_home/install/orabasetab"
    if [ -f "$orabasetab" ]; then
        local tb_base
        tb_base="$(awk -F: 'NR>1 && $1==ENVIRON["ORACLE_HOME"]{print $4}' \
            ORACLE_HOME="$oracle_home" "$orabasetab" 2>/dev/null | head -1)"
        [ -n "$tb_base" ] && base="$tb_base"
    fi
    printf "%s" "$base"
}

# detect_rwserver_conf  domain_home  wls_server
# Finds rwserver.conf by scanning the deployment directory.
detect_rwserver_conf() {
    local domain_home="$1"
    local wls_server="${2:-WLS_REPORTS}"
    local conf_base="$domain_home/config/fmwconfig/servers/$wls_server/applications"
    local result=""

    if [ -d "$conf_base" ]; then
        result="$(find "$conf_base" -name "rwserver.conf" 2>/dev/null | head -1)"
    fi

    if [ -z "$result" ]; then
        result="$(find "$domain_home/config" -name "rwserver.conf" 2>/dev/null | head -1)"
    fi

    if [ -z "$result" ]; then
        result="$conf_base/reports_14.1.2/configuration/rwserver.conf"
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
        result="$(find "$(dirname "$conf_dir")" -name "cgicmd.dat" 2>/dev/null | head -1)"
    fi

    printf "%s" "${result:-$conf_dir/cgicmd.dat}"
}

# detect_db_from_jps  domain_home
# Reads jps-config.xml and extracts Oracle DB connection parameters.
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

    if printf "%s" "$jdbc_url" | grep -qi '(host='; then
        # TNS descriptor: jdbc:oracle:thin:@(DESCRIPTION=(ADDRESS=(HOST=..)(PORT=..))(CONNECT_DATA=(SERVICE_NAME=..)))
        DET_DB_HOST="$(   printf "%s" "$jdbc_url" | sed -n 's/.*[Hh][Oo][Ss][Tt]=\([^)]*\).*/\1/p'         | head -1)"
        DET_DB_PORT="$(   printf "%s" "$jdbc_url" | sed -n 's/.*[Pp][Oo][Rr][Tt]=\([^)]*\).*/\1/p'         | head -1)"
        DET_DB_SERVICE="$(printf "%s" "$jdbc_url" | sed -n 's/.*[Ss][Ee][Rr][Vv][Ii][Cc][Ee]_[Nn][Aa][Mm][Ee]=\([^)]*\).*/\1/p' | head -1)"
        DET_DB_SERVER="$( printf "%s" "$jdbc_url" | sed -n 's/.*[Ss][Ee][Rr][Vv][Ee][Rr]=\([^)]*\).*/\1/p'       | head -1)"
    else
        # EZConnect, as written by 08-oracle_setup_domain.sh / the Configuration
        # Wizard: jdbc:oracle:thin:@//host:port/service[:server] or @host:port/service.
        # Before 2026-10-15 only the TNS form was parsed -> empty DB_HOST/DB_SERVICE.
        local ez="${jdbc_url#*@}"; ez="${ez#//}"
        DET_DB_HOST="${ez%%[:/]*}"
        local rest="${ez#"$DET_DB_HOST"}"
        case "$rest" in :[0-9]*) DET_DB_PORT="$(printf "%s" "$rest" | sed -n 's/^:\([0-9]*\).*/\1/p')" ;; esac
        DET_DB_SERVICE="$(printf "%s" "$rest" | sed -n 's|^[^/]*/\([^:?]*\).*|\1|p')"
        DET_DB_SERVER="$( printf "%s" "$rest" | sed -n 's|^[^/]*/[^:]*:\([A-Za-z]*\).*|\1|p')"
    fi
    DET_DB_PORT="${DET_DB_PORT:-1521}"
    DET_DB_SERVER="${DET_DB_SERVER:-dedicated}"
    return 0
}

# =============================================================================
# Helpers – interview and conf writing
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
        printf "  \033[32m  overridden: %s = %s\033[0m\n" "$var" "$input" | tee -a "$LOG_FILE"
    fi
}

# _conf_has_key  key  file – returns 0 if key already set in file
_conf_has_key() {
    local key="$1" file="$2"
    [ -f "$file" ] && grep -qE "^${key}=" "$file" 2>/dev/null
}

# _append_if_missing  key  value  file – appends key="value" only when not yet present
_append_if_missing() {
    local key="$1" val="$2" file="$3"
    if ! _conf_has_key "$key" "$file"; then
        printf '%s="%s"\n' "$key" "$val" >> "$file"
    fi
}

# _update_symlink  target  link
# Creates or updates link → target; reports result.
_update_symlink() {
    local target="$1" link="$2"
    if ln -sfn "$target" "$link" 2>/dev/null; then
        ok "Symlink: $link"
        info "      -> $target"
    else
        fail "Cannot create symlink: $link -> $target"
        info "  Check write permissions on: $(dirname "$link")"
    fi
}

# =============================================================================
# MAIN
# =============================================================================

printLine
printf "\n\033[1m  IHateWeblogic – Environment Initialisation\033[0m\n" | tee -a "$LOG_FILE"
printf "  Host      : %s\n" "$(_get_hostname)"  | tee -a "$LOG_FILE"
printf "  Apply     : %s\n" "$APPLY"            | tee -a "$LOG_FILE"
printf "  Interview : %s\n" "$INTERVIEW"        | tee -a "$LOG_FILE"
printf "  Log       : %s\n" "$LOG_FILE"         | tee -a "$LOG_FILE"
printf "  Output    : %s\n" "$ENV_CONF_DIR/"    | tee -a "$LOG_FILE"
printLine

# =============================================================================
# No active environment.conf: collect install parameters and exit
# =============================================================================
if [ ! -f "$ENV_LINK" ]; then
    section "No active environment – collecting install parameters"
    info "For a full guided interview (incl. passwords/DB) use: 09-Install/01-setup-interview.sh"
    printf "\n"

    INTERVIEW=true

    DET_JDK_HOME="$(detect_jdk_home_os)"
    if [ -n "$DET_JDK_HOME" ]; then
        ok "Oracle JDK found: $DET_JDK_HOME"
    else
        warn "Oracle JDK not found – using default (run 09-Install/02b-root_os_java.sh first)"
        DET_JDK_HOME="/u01/app/oracle/java/jdk-21"
    fi

    _confirm_val CONF_ORACLE_BASE    "/u01/app/oracle"                   "ORACLE_BASE"
    _confirm_val CONF_ORACLE_HOME    "\${ORACLE_BASE}/fmw"               "ORACLE_HOME"
    _confirm_val CONF_JDK_HOME       "$DET_JDK_HOME"                    "JDK_HOME"
    _confirm_val CONF_DOMAIN_HOME_I  "\${ORACLE_BASE}/domains/fr_domain" "DOMAIN_HOME"
    _confirm_val CONF_PATCH_STORAGE  "/srv/patch_storage"                "PATCH_STORAGE"
    # one Oracle Net directory for all processes (02-Checks/tns_admin_check.sh)
    _confirm_val CONF_TNS_ADMIN      "\${ORACLE_BASE}/admin/tns_names"   "TNS_ADMIN"

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

    # Derive environment name from the domain home path
    ENV_NAME="$(basename "${CONF_DOMAIN_HOME_I%%\}*}" | tr -cd '[:alnum:]_-')"
    [ -z "$ENV_NAME" ] || [ "$ENV_NAME" = "domains" ] && ENV_NAME="fr_domain"
    ENV_CONF="$ENV_CONF_DIR/${ENV_NAME}.conf"

    if $APPLY; then
        {
            printf "# ENV_TYPE=FMW\n"
            printf "# ENV_LABEL=%s @ %s\n" "$ENV_NAME" "$(_get_hostname)"
            printf "# =============================================================================\n"
            printf "# environment conf – generated by 00-Setup/init_env.sh\n"
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
            printf 'TNS_ADMIN="%s"\n'           "$CONF_TNS_ADMIN"
            printf 'INSTALL_COMPONENTS="%s"\n'  "$CONF_INSTALL_COMPONENTS"
            printf "# === END 09-INSTALL =========================================================\n"
        } > "$ENV_CONF"
        chmod 600 "$ENV_CONF"
        ok "Conf written: $ENV_CONF"
        _update_symlink "$ENV_CONF" "$ENV_LINK"
        info "Next:"
        info "  1. 09-Install/01-setup-interview.sh --apply  (domain / DB / MOS / passwords)"
        info "  2. 09-Install/ Phase 0 root scripts"
        info "  3. After FMW install: 00-Setup/init_env.sh --apply  (extend with runtime values)"
    else
        warn "Dry-run – use --apply to write conf"
        printLine
        printf "  Preview (install parameters):\n" | tee -a "$LOG_FILE"
        printList "  ORACLE_BASE"         28 "$CONF_ORACLE_BASE"
        printList "  ORACLE_HOME"         28 "$CONF_ORACLE_HOME"
        printList "  JDK_HOME"            28 "$CONF_JDK_HOME"
        printList "  DOMAIN_HOME"         28 "$CONF_DOMAIN_HOME_I"
        printList "  PATCH_STORAGE"       28 "$CONF_PATCH_STORAGE"
        printList "  TNS_ADMIN"           28 "$CONF_TNS_ADMIN"
        printList "  INSTALL_COMPONENTS"  28 "$CONF_INSTALL_COMPONENTS"
        info "Would write to: $ENV_CONF_DIR/${ENV_NAME}.conf"
        info "Would symlink:  $ENV_LINK -> $ENV_CONF_DIR/${ENV_NAME}.conf"
    fi

    print_summary
    exit $EXIT_CODE
fi

# --------------------------------------------------------------------------
# Active environment exists → runtime detection
# (Source conf via symlink so detection has current values as baseline)
# --------------------------------------------------------------------------
# shellcheck source=../environment.conf
source "$ENV_LINK"

# --------------------------------------------------------------------------
# Everything below this point only DETECTS runtime values (paths, running
# processes, DB connection from jps-config.xml, ...) and backfills them via
# _append_if_missing. It never collects or backfills the install-time
# parameters below - those are only ever asked for by 01-setup-interview.sh
# (full guided interview) or the "no active environment" fresh-install
# branch above. Warn here so an incomplete environment.conf (e.g. written
# by an older init_env.sh, or never run through 01-setup-interview.sh at
# all) doesn't silently look "done" just because this script finished
# without errors.
section "Checking for 09-Install Parameters"

MISSING_INSTALL_KEYS=()
for _key in \
    ORACLE_BASE ORACLE_INVENTORY PATCH_STORAGE TNS_ADMIN INSTALL_COMPONENTS \
    WLS_ADMIN_USER WLS_ADMIN_PORT WLS_NODEMANAGER_PORT WLS_FORMS_PORT WLS_REPORTS_PORT \
    FORMS_CUSTOMER_DIR REPORTS_CUSTOMER_DIR \
    EXPECTED_SESSIONS ULIMIT_NOFILE ULIMIT_NPROC \
    MOS_USER
do
    [ -z "${!_key:-}" ] && MISSING_INSTALL_KEYS+=("$_key")
done
unset _key

if [ "${#MISSING_INSTALL_KEYS[@]}" -eq 0 ]; then
    ok "All 09-Install parameters present in environment.conf"
else
    warn "${#MISSING_INSTALL_KEYS[@]} install parameter(s) missing from environment.conf:"
    for _key in "${MISSING_INSTALL_KEYS[@]}"; do
        info "  $_key"
    done
    unset _key
    warn "init_env.sh only detects RUNTIME values - it does not collect these"
    warn "install-time parameters, even in --interview mode."
    info "Run: 09-Install/01-setup-interview.sh --apply   (full guided interview)"
fi

# --------------------------------------------------------------------------
section "Detecting ORACLE_HOME"
DET_ORACLE_HOME="$(detect_oracle_home)"

if [ -n "$DET_ORACLE_HOME" ] && [ -d "$DET_ORACLE_HOME" ]; then
    ok "ORACLE_HOME detected: $DET_ORACLE_HOME"
else
    warn "ORACLE_HOME not auto-detected – using value from conf: ${ORACLE_HOME:-/u01/oracle/fmw}"
    DET_ORACLE_HOME="${ORACLE_HOME:-/u01/oracle/fmw}"
fi

printList "ORACLE_HOME" 30 "$DET_ORACLE_HOME"

for component in \
    "wlserver/server/lib/weblogic.jar:WebLogic core JAR" \
    "oracle_common/common/bin/wlst.sh:WLST" \
    "bin/rwrun:rwrun binary" \
    "bin/rwclient:rwclient binary"; do
    local_path="${component%%:*}"
    local_label="${component##*:}"
    if [ -e "$DET_ORACLE_HOME/$local_path" ]; then
        ok "$local_label: $DET_ORACLE_HOME/$local_path"
    else
        warn "$local_label not found: $DET_ORACLE_HOME/$local_path"
    fi
done

# --------------------------------------------------------------------------
section "Detecting DOMAIN_HOME"
DET_DOMAIN_HOME="$(detect_domain_home)"

if [ -n "$DET_DOMAIN_HOME" ] && [ -f "$DET_DOMAIN_HOME/config/config.xml" ]; then
    ok "DOMAIN_HOME detected: $DET_DOMAIN_HOME"
else
    warn "DOMAIN_HOME not auto-detected – using value from conf: ${DOMAIN_HOME:-/u01/user_projects/domains/fr_domain}"
    DET_DOMAIN_HOME="${DOMAIN_HOME:-/u01/user_projects/domains/fr_domain}"
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

# ReportsTools instance name (basename of first detected directory)
DET_REPORTS_TOOLS_INSTANCE="$(basename "${DET_REPTOOLS_INSTANCES[0]:-reptools_ent}")"

# ReportsServer instance names (space-separated)
mapfile -t _repserver_arr < <(detect_reports_server_instances "$DET_DOMAIN_HOME")
# Fresh install (components not created yet by 13-): use the names from the
# setup interview (REPORTS_SERVER_NAMES / REPORTS_SERVER_NAME) – before
# 2026-10-15 the fallback was a hard "repserver_ent" that did not match
# REPORTS_SERVER_NAME=repserver01 from the interview
if [ "${#_repserver_arr[@]}" -eq 0 ]; then
    if [ "${#REPORTS_SERVER_NAMES[@]}" -gt 0 ] 2>/dev/null && [ -n "${REPORTS_SERVER_NAMES[0]:-}" ]; then
        _repserver_arr=("${REPORTS_SERVER_NAMES[@]}")
    elif [ -n "${REPORTS_SERVER_NAME:-}" ]; then
        _repserver_arr=("$REPORTS_SERVER_NAME")
    fi
fi
DET_REPORTS_SERVER_INSTANCES="${_repserver_arr[*]:-repserver_ent}"
unset _repserver_arr

# Runtime paths – use existing conf values as baseline, fall back to defaults
# REPORTS_CUSTOMER_DIR comes from the setup interview (customer .rdf/.rep files)
# Default layout: $ORACLE_BASE/reports/{source,images,tmp} (outside ORACLE_HOME
# and /tmp). REPORTS_PATH = sources + images (':'-separated, also granted in
# rwserver.conf <folderAccess><read>, there ';'-separated by 13-).
_rep_base="${ORACLE_BASE:-${CONF_ORACLE_BASE:-/u01/app/oracle}}/reports"
DET_REPORTS_PATH="${REPORTS_PATH:-${REPORTS_CUSTOMER_DIR:-$_rep_base/source}:${REPORTS_IMAGE_DIR:-$_rep_base/images}}"
DET_REPORTS_TMP="${REPORTS_TMP:-$_rep_base/tmp}"
unset _rep_base
DET_REPORTS_BROADCAST_PORT="${REPORTS_BROADCAST_PORT:-14027}"

printList "REPORTS_COMPONENT_HOME"    30 "$DET_REPORTS_COMPONENT"
printList "REPORTS_TOOLS_INSTANCE"    30 "$DET_REPORTS_TOOLS_INSTANCE"
printList "REPORTS_SERVER_INSTANCES"  30 "$DET_REPORTS_SERVER_INSTANCES"
printList "REPORTS_ADMIN"             30 "$DET_REPORTS_ADMIN"
printList "UIFONT_ALI"                30 "$DET_UIFONT_ALI"
printList "REPORTS_FONT_DIR"          30 "$DET_REPORTS_FONT_DIR"
printList "REPORTS_PATH"              30 "$DET_REPORTS_PATH"
printList "REPORTS_TMP"               30 "$DET_REPORTS_TMP"
printList "REPORTS_BROADCAST_PORT"    30 "$DET_REPORTS_BROADCAST_PORT"

[ -d "$DET_REPORTS_ADMIN" ] \
    && ok "REPORTS_ADMIN directory exists" \
    || warn "REPORTS_ADMIN not found: $DET_REPORTS_ADMIN"
[ -f "$DET_UIFONT_ALI" ] \
    && ok "uifont.ali found" \
    || warn "uifont.ali not found: $DET_UIFONT_ALI"
[ -d "$DET_REPORTS_FONT_DIR" ] \
    && ok "REPORTS_FONT_DIR exists ($(find "$DET_REPORTS_FONT_DIR" \
        -name "*.ttf" -o -name "*.TTF" 2>/dev/null | wc -l) TTF)" \
    || warn "REPORTS_FONT_DIR not found (run deploy_fonts.sh --apply)"

# --------------------------------------------------------------------------
section "Detecting Forms Components"

DET_FORMS_INSTANCE_NAME="$(detect_forms_instance "$DET_DOMAIN_HOME")"
DET_WLS_FORMS_SERVER="$(detect_wls_forms_server "$DET_DOMAIN_HOME")"
printList "FORMS_INSTANCE_NAME" 30 "$DET_FORMS_INSTANCE_NAME"
printList "WLS_FORMS_SERVER"    30 "$DET_WLS_FORMS_SERVER"
# Forms directories - default layout $ORACLE_BASE/forms/{moduls,tmp}
# (outside ORACLE_HOME and /tmp; created by 09-Install/14-oracle_setup_forms.sh)
_frm_base="${ORACLE_BASE:-${CONF_ORACLE_BASE:-/u01/app/oracle}}/forms"
DET_FORMS_CUSTOMER_DIR="${FORMS_CUSTOMER_DIR:-$_frm_base/moduls}"
DET_FORMS_TMP="${FORMS_TMP:-$_frm_base/tmp}"
unset _frm_base
printList "FORMS_CUSTOMER_DIR"  30 "$DET_FORMS_CUSTOMER_DIR"
printList "FORMS_TMP"           30 "$DET_FORMS_TMP"

_forms_inst_dir="$DET_DOMAIN_HOME/config/fmwconfig/components/FORMS/instances/$DET_FORMS_INSTANCE_NAME"
if [ -d "$_forms_inst_dir" ]; then
    ok "Forms instance dir exists: $_forms_inst_dir"
else
    info "Forms instance dir not found (normal before 14-oracle_setup_forms.sh): $_forms_inst_dir"
fi
unset _forms_inst_dir

# --------------------------------------------------------------------------
section "Detecting WLS Managed Server"

DET_WLS_SERVER_FQDN="$(hostname -f 2>/dev/null || hostname)"
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

[ -f "$DET_RWSERVER_CONF" ]  && ok "rwserver.conf found"    || warn "rwserver.conf not found (template path used)"
[ -f "$DET_CGICMD_DAT" ]     && ok "cgicmd.dat found"       || warn "cgicmd.dat not found (template path used)"
[ -f "$DET_SETDOMAINENV" ]   && ok "setDomainEnv.sh found"  || warn "setDomainEnv.sh not found"

# --------------------------------------------------------------------------
section "Detecting Java"

DET_JAVA_HOME="$(detect_java_home "$DET_ORACLE_HOME")"
[ -n "$DET_JAVA_HOME" ] || DET_JAVA_HOME="$DET_ORACLE_HOME/oracle_common/jdk"
printList "JDK_HOME" 30 "$DET_JAVA_HOME"

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
    ok "DB_ORACLE connection found in jps-config.xml"
    printList "DB_HOST"    30 "$DET_DB_HOST"
    printList "DB_PORT"    30 "$DET_DB_PORT"
    printList "DB_SERVICE" 30 "$DET_DB_SERVICE"
    printList "DB_SERVER"  30 "$DET_DB_SERVER"
else
    info "No DB_ORACLE connection detected (jps-config.xml missing or no DB_ORACLE entry)"
    info "  Configure manually: 02-Checks/db_connect_check.sh --new"
fi

# --------------------------------------------------------------------------
section "X11 Display Check"

if [ -n "${DISPLAY:-}" ]; then
    printList "DISPLAY" 30 "${DISPLAY}"
    ok "DISPLAY is set: ${DISPLAY}"
else
    warn "DISPLAY is not set – rwrun may segfault without Xvfb"
    info "Fix: run 02-Checks/display_check.sh"
fi

# =============================================================================
# Confirm detected values (interview mode) + derive ENV_NAME
# =============================================================================
section "Generate environment conf"

if $INTERVIEW; then
    printLine
    printf "\n  Confirm detected values (Enter = keep, type to override):\n\n"
fi

_confirm_val CONF_FORMS_INSTANCE_NAME "$DET_FORMS_INSTANCE_NAME" "FORMS_INSTANCE_NAME"
_confirm_val CONF_WLS_FORMS_SERVER    "$DET_WLS_FORMS_SERVER"    "WLS_FORMS_SERVER"
_confirm_val CONF_FORMS_CUSTOMER_DIR  "$DET_FORMS_CUSTOMER_DIR"  "FORMS_CUSTOMER_DIR"
_confirm_val CONF_FORMS_TMP           "$DET_FORMS_TMP"           "FORMS_TMP"
_confirm_val CONF_WLS_SERVER_FQDN "$DET_WLS_SERVER_FQDN"  "WLS_SERVER_FQDN"
_confirm_val CONF_ORACLE_HOME    "$DET_ORACLE_HOME"       "ORACLE_HOME"
_confirm_val CONF_JAVA_HOME      "$DET_JAVA_HOME"         "JDK_HOME"
_confirm_val CONF_DOMAIN_HOME    "$DET_DOMAIN_HOME"       "DOMAIN_HOME"
_confirm_val CONF_REPORTS_COMP   "$DET_REPORTS_COMPONENT" "REPORTS_COMPONENT_HOME"
_confirm_val CONF_WLS_MANAGED    "$DET_WLS_MANAGED"       "WLS_MANAGED_SERVER"
_confirm_val CONF_RWSERVER_CONF             "$DET_RWSERVER_CONF"            "RWSERVER_CONF"
_confirm_val CONF_CGICMD_DAT               "$DET_CGICMD_DAT"               "CGICMD_DAT"
_confirm_val CONF_REPORTS_TOOLS_INSTANCE   "$DET_REPORTS_TOOLS_INSTANCE"   "REPORTS_TOOLS_INSTANCE"
_confirm_val CONF_REPORTS_SERVER_INSTANCES "$DET_REPORTS_SERVER_INSTANCES" "REPORTS_SERVER_INSTANCES"
_confirm_val CONF_REPORTS_PATH             "$DET_REPORTS_PATH"             "REPORTS_PATH"
_confirm_val CONF_REPORTS_TMP              "$DET_REPORTS_TMP"              "REPORTS_TMP"
_confirm_val CONF_REPORTS_BROADCAST_PORT   "$DET_REPORTS_BROADCAST_PORT"   "REPORTS_BROADCAST_PORT"
_confirm_val CONF_ORACLE_USER              "$DET_ORACLE_USER"              "ORACLE_OS_USER"
_confirm_val CONF_DB_HOST        "$DET_DB_HOST"           "DB_HOST"
_confirm_val CONF_DB_PORT        "${DET_DB_PORT:-1521}"   "DB_PORT"
_confirm_val CONF_DB_SERVICE     "$DET_DB_SERVICE"        "DB_SERVICE"
_confirm_val CONF_DB_SERVER      "${DET_DB_SERVER:-dedicated}" "DB_SERVER"

# Derive env name and target conf path from the confirmed DOMAIN_HOME
ENV_NAME="$(basename "$CONF_DOMAIN_HOME")"
ENV_CONF="$ENV_CONF_DIR/${ENV_NAME}.conf"
printList "Conf target" 30 "$ENV_CONF"
printList "Symlink"     30 "$ENV_LINK -> $ENV_CONF"

# Build REPORTS_INSTANCES array string
INSTANCES_ARRAY_STR=""
for inst in "${DET_REPTOOLS_INSTANCES[@]}"; do
    INSTANCES_ARRAY_STR="${INSTANCES_ARRAY_STR}  \"${inst}\"\n"
done

# =============================================================================
if $APPLY; then

    if [ -f "$ENV_CONF" ]; then
        # --- Extend mode: existing conf – only append missing keys ---
        backup_file "$ENV_CONF" "$ENV_CONF_DIR"

        if ! grep -q "# --- Runtime: init_env.sh" "$ENV_CONF" 2>/dev/null; then
            {
                printf "\n"
                printf "# --- Runtime: init_env.sh auto-detected %s ---\n" \
                    "$(date '+%Y-%m-%d %H:%M:%S')"
            } >> "$ENV_CONF"
        fi

        _append_if_missing "FORMS_INSTANCE_NAME"   "$CONF_FORMS_INSTANCE_NAME" "$ENV_CONF"
        _append_if_missing "WLS_FORMS_SERVER"     "$CONF_WLS_FORMS_SERVER"    "$ENV_CONF"
        _append_if_missing "FORMS_CUSTOMER_DIR"   "$CONF_FORMS_CUSTOMER_DIR"  "$ENV_CONF"
        _append_if_missing "FORMS_TMP"            "$CONF_FORMS_TMP"           "$ENV_CONF"
        _append_if_missing "FORMS_PRESTART_SECTION" ""                        "$ENV_CONF"
        _append_if_missing "FORMS_PRESTART_INIT"  "5"                         "$ENV_CONF"
        _append_if_missing "FORMS_PRESTART_MIN"   "4"                         "$ENV_CONF"
        _append_if_missing "FORMS_PRESTART_INCREMENT" "1"                     "$ENV_CONF"
        _append_if_missing "FORMS_WEBUTIL_JACOB"  "false"                     "$ENV_CONF"
        _append_if_missing "FORMS_SIGN_KEYSTORE"  ""                          "$ENV_CONF"
        _append_if_missing "FORMS_SIGN_ALIAS"     "forms_codesign"            "$ENV_CONF"
        _append_if_missing "FORMS_SIGN_TSA_URL"   ""                          "$ENV_CONF"
        _append_if_missing "FORMS_SIGN_LOCALCA"   "false"                     "$ENV_CONF"
        _append_if_missing "SSH_ALLOW_USERS"      ""                          "$ENV_CONF"
        _append_if_missing "SSH_PASSWORD_USERS"   ""                          "$ENV_CONF"
        _append_if_missing "ORACLE_HOME"           "$CONF_ORACLE_HOME"      "$ENV_CONF"
        _append_if_missing "WL_HOME"               "\${ORACLE_HOME}/wlserver" "$ENV_CONF"
        _append_if_missing "JDK_HOME"              "$CONF_JAVA_HOME"        "$ENV_CONF"
        _append_if_missing "DOMAIN_HOME"           "$CONF_DOMAIN_HOME"      "$ENV_CONF"
        _append_if_missing "DOMAIN_NAME"           "$DET_DOMAIN_NAME"       "$ENV_CONF"
        _append_if_missing "WL_ADMIN_URL"          "t3://localhost:7001"     "$ENV_CONF"
        _append_if_missing "WLS_SERVER_FQDN"       "$CONF_WLS_SERVER_FQDN"  "$ENV_CONF"
        _append_if_missing "WLS_LISTEN_ADDRESS"    "localhost"               "$ENV_CONF"
        _append_if_missing "WLS_MANAGED_SERVER"    "$CONF_WLS_MANAGED"      "$ENV_CONF"
        _append_if_missing "REPORTS_COMPONENT_HOME" "$CONF_REPORTS_COMP"    "$ENV_CONF"
        _append_if_missing "REPORTS_ADMIN"         "\${REPORTS_COMPONENT_HOME}/guicommon/tk/admin" "$ENV_CONF"
        _append_if_missing "UIFONT_ALI"            "\${REPORTS_ADMIN}/uifont.ali" "$ENV_CONF"
        _append_if_missing "TK_FONTALIAS"          "\${UIFONT_ALI}"         "$ENV_CONF"
        _append_if_missing "ORACLE_FONTALIAS"      "\${UIFONT_ALI}"         "$ENV_CONF"
        _append_if_missing "REPORTS_FONT_DIR"      "\${DOMAIN_HOME}/reports/fonts" "$ENV_CONF"
        _append_if_missing "RWRUN"                 "\${ORACLE_HOME}/bin/rwrun"   "$ENV_CONF"
        _append_if_missing "RWCLIENT"              "\${ORACLE_HOME}/bin/rwclient" "$ENV_CONF"
        _append_if_missing "WLST"                  "\${ORACLE_HOME}/oracle_common/common/bin/wlst.sh" "$ENV_CONF"
        _append_if_missing "RWSERVER_CONF"            "$CONF_RWSERVER_CONF"              "$ENV_CONF"
        _append_if_missing "CGICMD_DAT"             "$CONF_CGICMD_DAT"                 "$ENV_CONF"
        _append_if_missing "SETDOMAINENV"           "\${DOMAIN_HOME}/bin/setDomainEnv.sh" "$ENV_CONF"
        _append_if_missing "REPORTS_TOOLS_INSTANCE"    "$CONF_REPORTS_TOOLS_INSTANCE"    "$ENV_CONF"
        _append_if_missing "REPORTS_SERVER_INSTANCES"  "$CONF_REPORTS_SERVER_INSTANCES"  "$ENV_CONF"
        _append_if_missing "REPORTS_PATH"              "$CONF_REPORTS_PATH"              "$ENV_CONF"
        _append_if_missing "REPORTS_TMP"               "$CONF_REPORTS_TMP"               "$ENV_CONF"
        _append_if_missing "REPORTS_SECURITY"          "ldap"                            "$ENV_CONF"
        _append_if_missing "REPORTS_BROADCAST_PORT"    "$CONF_REPORTS_BROADCAST_PORT"    "$ENV_CONF"
        _append_if_missing "REPORTS_ENGINE_INIT"       "2"                               "$ENV_CONF"
        _append_if_missing "REPORTS_ENGINE_MAX"        "5"                               "$ENV_CONF"
        _append_if_missing "REPORTS_ENGINE_MIN"        "2"                               "$ENV_CONF"
        _append_if_missing "REPORTS_ENGINE_LIFE"       "50"                              "$ENV_CONF"
        _append_if_missing "REPORTS_ENGINE_MAX_IDLE"   ""                                "$ENV_CONF"
        _append_if_missing "REPORTS_ENGINE_JVM_OPTIONS" ""                               "$ENV_CONF"
        _append_if_missing "REPORTS_MAX_CONNECT"       "300"                             "$ENV_CONF"
        _append_if_missing "REPORTS_MAX_QUEUE"         "4000"                            "$ENV_CONF"
        _append_if_missing "REPORTS_COOKIE_KEY"        ""                                "$ENV_CONF"
        _append_if_missing "WLS_LOG_DIR"           "\${DOMAIN_HOME}/servers/\${WLS_MANAGED_SERVER}/logs" "$ENV_CONF"
        _append_if_missing "DIAG_LOG_DIR"          "\${ROOT_DIR}/log/\$(date +%Y%m%d)" "$ENV_CONF"
        _append_if_missing "CONFIG_BACKUP_KEEP"    "10"                     "$ENV_CONF"
        _append_if_missing "BAK_FILES_KEEP"        "3"                      "$ENV_CONF"
        _append_if_missing "SEC_CONF"              "\${ROOT_DIR}/weblogic_sec.conf.des3" "$ENV_CONF"
        _append_if_missing "ORACLE_OS_USER"        "$CONF_ORACLE_USER"      "$ENV_CONF"
        _append_if_missing "DB_HOST"               "$CONF_DB_HOST"          "$ENV_CONF"
        _append_if_missing "DB_PORT"               "$CONF_DB_PORT"          "$ENV_CONF"
        _append_if_missing "DB_SERVICE"            "$CONF_DB_SERVICE"       "$ENV_CONF"
        _append_if_missing "DB_SERVER"             "$CONF_DB_SERVER"        "$ENV_CONF"
        _append_if_missing "DB_SCHEMA_PREFIX"      ""                       "$ENV_CONF"
        _append_if_missing "RCU_TABLESPACE"        ""                       "$ENV_CONF"
        _append_if_missing "RCU_TEMP_TABLESPACE"   "TEMP"                   "$ENV_CONF"
        _append_if_missing "RCU_DB_TYPE"           "EBR"                    "$ENV_CONF"
        _append_if_missing "SQLPLUS_BIN"           ""                       "$ENV_CONF"
        _append_if_missing "SEC_CONF_DB"           "\${ROOT_DIR}/db_connect.conf.des3" "$ENV_CONF"
        _append_if_missing "LOCAL_REP_DB"          "false"                  "$ENV_CONF"
        _append_if_missing "DISPLAY_VAR"           ":99"                    "$ENV_CONF"

        if ! _conf_has_key "REPORTS_INSTANCES" "$ENV_CONF"; then
            {
                printf 'REPORTS_INSTANCES=(\n'
                printf "%b" "$INSTANCES_ARRAY_STR"
                printf ')\n'
            } >> "$ENV_CONF"
        fi

        chmod 600 "$ENV_CONF"
        ok "Conf extended with missing runtime values: $ENV_CONF"

    else
        # --- Fresh write ---
        cat > "$ENV_CONF" <<ENVEOF
# ENV_TYPE=FMW
# ENV_LABEL=${ENV_NAME} @ $(_get_hostname)
# =============================================================================
# environment conf – generated by 00-Setup/init_env.sh
# Host  : $(_get_hostname)
# Date  : $(date '+%Y-%m-%d %H:%M:%S')
# DO NOT check into git!
# =============================================================================

# --- Oracle FMW Installation -------------------------------------------------
ORACLE_HOME="${CONF_ORACLE_HOME}"
WL_HOME="\${ORACLE_HOME}/wlserver"
JDK_HOME="${CONF_JAVA_HOME}"

# --- WebLogic Domain ---------------------------------------------------------
DOMAIN_HOME="${CONF_DOMAIN_HOME}"
DOMAIN_NAME="${DET_DOMAIN_NAME}"
WL_ADMIN_URL="t3://localhost:7001"
# External FQDN – used by Nginx SSL config and WebLogic Frontend Host setting
WLS_SERVER_FQDN="${CONF_WLS_SERVER_FQDN}"
# localhost = NGINX reverse proxy (recommended); 0.0.0.0 = all interfaces (no proxy)
WLS_LISTEN_ADDRESS="localhost"
WLS_MANAGED_SERVER="${CONF_WLS_MANAGED}"

# --- Reports Component (primary instance) ------------------------------------
REPORTS_COMPONENT_HOME="${CONF_REPORTS_COMP}"
REPORTS_ADMIN="\${REPORTS_COMPONENT_HOME}/guicommon/tk/admin"
UIFONT_ALI="\${REPORTS_ADMIN}/uifont.ali"
TK_FONTALIAS="\${UIFONT_ALI}"
ORACLE_FONTALIAS="\${UIFONT_ALI}"
REPORTS_FONT_DIR="\${DOMAIN_HOME}/reports/fonts"

# --- All detected Reports instances (bash array) -----------------------------
REPORTS_INSTANCES=(
$(printf "%b" "$INSTANCES_ARRAY_STR"))

# --- Reports Instance Names --------------------------------------------------
# REPORTS_TOOLS_INSTANCE: always exactly one per domain
REPORTS_TOOLS_INSTANCE="${CONF_REPORTS_TOOLS_INSTANCE}"
# REPORTS_SERVER_INSTANCES: space-separated; multiple allowed
REPORTS_SERVER_INSTANCES="${CONF_REPORTS_SERVER_INSTANCES}"

# --- Reports Runtime Configuration -------------------------------------------
# REPORTS_PATH: report sources (.rdf/.rep) + images, ':'-separated
REPORTS_PATH="${CONF_REPORTS_PATH}"
# REPORTS_TMP: writable directory for temporary output files (not /tmp)
REPORTS_TMP="${CONF_REPORTS_TMP}"
# REPORTS_SECURITY: ldap (secured, WebLogic users/roles via embedded LDAP) |
#                   identifier (not secured) - see 09-Install/docs/13 Step 5a
REPORTS_SECURITY="ldap"
# Broadcasting port – unique per environment in the subnet (range: 14021–14030)
# 14027 = FMW 14.1.2.0.0 production,  14028 = standby  (Doc ID 437228.1)
REPORTS_BROADCAST_PORT="${CONF_REPORTS_BROADCAST_PORT}"
# rwserver.conf engine tuning (see 09-Install/docs/13-reports-detail-settings.md)
REPORTS_ENGINE_INIT="2"
REPORTS_ENGINE_MAX="5"
REPORTS_ENGINE_MIN="2"
REPORTS_ENGINE_LIFE="50"
# maxIdle (minutes) / engine jvmOptions (e.g. "-Xmx1g"): empty = Oracle default
REPORTS_ENGINE_MAX_IDLE=""
REPORTS_ENGINE_JVM_OPTIONS=""
REPORTS_MAX_CONNECT="300"
REPORTS_MAX_QUEUE="4000"
# rwservlet.properties cookie encryption key – generate once, keep stable
REPORTS_COOKIE_KEY=""

# --- Forms Components --------------------------------------------------------
# FORMS_INSTANCE_NAME: name of the Forms system component instance (e.g. forms1)
FORMS_INSTANCE_NAME="${CONF_FORMS_INSTANCE_NAME}"
# WLS_FORMS_SERVER: name of the WLS managed server running Oracle Forms
WLS_FORMS_SERVER="${CONF_WLS_FORMS_SERVER}"
# Forms directories (created by 09-Install/14-oracle_setup_forms.sh):
# FORMS_CUSTOMER_DIR: Forms modules (.fmx/.fmb, first entry of FORMS_PATH)
FORMS_CUSTOMER_DIR="${CONF_FORMS_CUSTOMER_DIR}"
# FORMS_TMP: TMPDIR of the Forms runtime (default.env, not /tmp)
FORMS_TMP="${CONF_FORMS_TMP}"
# Forms runtime pooling (formsweb.cfg prestart*) only in this section (e.g.
# webstart); empty = no pooling. Never [default] (Oracle) – set by 14-
FORMS_PRESTART_SECTION=""
FORMS_PRESTART_INIT="5"
FORMS_PRESTART_MIN="4"
FORMS_PRESTART_INCREMENT="1"
# FORMS_WEBUTIL_JACOB: install JACOB for WebUtil OLE / Office automation
# (CLIENT_OLE2) – downloaded by 04-, installed by 14- (default: false)
FORMS_WEBUTIL_JACOB="false"
# Code signing of jacob.jar by 14- (empty keystore = do not sign).
# Keystore: PKCS12, e.g. from 08-SSL/ssl_local_ca.sh codesign --apply
# (\$ORACLE_BASE/admin/pki/codesign/codesign.p12); password in
# forms_sign_sec.conf.des3. TSA URL: timestamp server (empty = no timestamp)
FORMS_SIGN_KEYSTORE=""
FORMS_SIGN_ALIAS="forms_codesign"
FORMS_SIGN_TSA_URL=""
# true = 14- creates a missing keystore with the own root CA (ssl_local_ca.sh)
FORMS_SIGN_LOCALCA="false"

# --- Reports / Forms Binaries ------------------------------------------------
RWRUN="\${ORACLE_HOME}/bin/rwrun"
RWCLIENT="\${ORACLE_HOME}/bin/rwclient"
WLST="\${ORACLE_HOME}/oracle_common/common/bin/wlst.sh"

# --- Configuration Files -----------------------------------------------------
RWSERVER_CONF="${CONF_RWSERVER_CONF}"
CGICMD_DAT="${CONF_CGICMD_DAT}"
SETDOMAINENV="\${DOMAIN_HOME}/bin/setDomainEnv.sh"

# --- Log Directories ---------------------------------------------------------
WLS_LOG_DIR="\${DOMAIN_HOME}/servers/\${WLS_MANAGED_SERVER}/logs"
DIAG_LOG_DIR="\${ROOT_DIR}/log/\$(date +%Y%m%d)"

# --- Backup retention (07-Maintenance/README.md) -----------------------------
# backup_config.sh --apply keeps the newest N sets in ConfigBackup/,
# bak_cleanup.sh --apply the newest N *.bak_<ts> copies per file
CONFIG_BACKUP_KEEP="10"
BAK_FILES_KEEP="3"

# --- Security ----------------------------------------------------------------
SEC_CONF="\${ROOT_DIR}/weblogic_sec.conf.des3"
ORACLE_OS_USER="${CONF_ORACLE_USER}"

# --- Oracle DB Connection ----------------------------------------------------
DB_HOST="${CONF_DB_HOST}"
DB_PORT="${CONF_DB_PORT}"
DB_SERVICE="${CONF_DB_SERVICE}"
DB_SERVER="${CONF_DB_SERVER}"
DB_SCHEMA_PREFIX=""
SQLPLUS_BIN=""
SEC_CONF_DB="\${ROOT_DIR}/db_connect.conf.des3"

# --- RCU Tablespace ----------------------------------------------------------
RCU_TABLESPACE=""
RCU_TEMP_TABLESPACE="TEMP"

# LOCAL_REP_DB: true if an Oracle DB runs on THIS host alongside WebLogic.
LOCAL_REP_DB="false"

# --- X11 / Display -----------------------------------------------------------
DISPLAY_VAR=":99"
ENVEOF

        chmod 600 "$ENV_CONF"
        ok "Conf written (fresh): $ENV_CONF"
    fi

    _update_symlink "$ENV_CONF" "$ENV_LINK"
    info "Next step: run 00-Setup/weblogic_sec.sh --apply"

else
    warn "Dry-run: conf NOT written (use --apply to write)"
    printList "  Would write to" 28 "$ENV_CONF"
    printList "  Would symlink"  28 "$ENV_LINK -> $ENV_CONF"
    printLine
    printf "  Preview (key values detected):\n" | tee -a "$LOG_FILE"
    printList "  WLS_SERVER_FQDN"       28 "$CONF_WLS_SERVER_FQDN"
    printList "  ORACLE_HOME"           28 "$CONF_ORACLE_HOME"
    printList "  DOMAIN_HOME"           28 "$CONF_DOMAIN_HOME"
    printList "  REPORTS_COMPONENT"        28 "$CONF_REPORTS_COMP"
    printList "  REPORTS_TOOLS_INSTANCE"  28 "$CONF_REPORTS_TOOLS_INSTANCE"
    printList "  REPORTS_SERVER_INSTANCES" 28 "$CONF_REPORTS_SERVER_INSTANCES"
    printList "  REPORTS_PATH"            28 "$CONF_REPORTS_PATH"
    printList "  REPORTS_TMP"             28 "$CONF_REPORTS_TMP"
    printList "  REPORTS_BROADCAST_PORT"  28 "$CONF_REPORTS_BROADCAST_PORT"
    printList "  FORMS_INSTANCE_NAME"     28 "$CONF_FORMS_INSTANCE_NAME"
    printList "  WLS_FORMS_SERVER"        28 "$CONF_WLS_FORMS_SERVER"
    printList "  WLS_MANAGED_SERVER"      28 "$CONF_WLS_MANAGED"
    printList "  JDK_HOME"              28 "$CONF_JAVA_HOME"
    printList "  RWSERVER_CONF"         28 "$CONF_RWSERVER_CONF"
    printList "  ORACLE_OS_USER"        28 "$CONF_ORACLE_USER"
    [ -f "$ENV_CONF" ] && \
        info "Existing conf will be EXTENDED (missing keys only) – existing values kept"
fi

# =============================================================================
print_summary
exit $EXIT_CODE
