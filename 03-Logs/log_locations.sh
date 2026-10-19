#!/bin/bash
# =============================================================================
# Script   : log_locations.sh  (sourced, not executed)
# Purpose  : One place that knows where the logs of an FMW 14.1.2 Forms /
#            Reports domain are – used by all 03-Logs scripts.
#            Discovered from the domain itself instead of fixed names:
#              $DOMAIN_HOME/servers/<name>/logs   for every WebLogic server,
#                                                 Reports server, Reports tools
#              $DOMAIN_HOME/nodemanager           Node Manager
#              $DOMAIN_HOME/servers/AdminServer/sysman/log   Enterprise Manager
#
# Verified live 2026-10-19 (test host): there is NO $DOMAIN_HOME/diagnostics/
# and no log below config/fmwconfig/components/ReportsToolsComponent – the
# ODL logs are servers/<srv>/logs/<srv>-diagnostic.log, the standalone
# Reports server and its engines log to servers/<repserver>/logs/
# (rwserver_diagnostic.log, rwEng-N_diagnostic.log), rwrun / the Reports
# tools to servers/reptools1/logs/runtime_diagnostic.log.
#
# Usage    : source "$SCRIPT_DIR/log_locations.sh"
#            ihw_log_groups [component]   -> lines: role<TAB>name<TAB>dir<TAB>depth
#            ihw_log_kind <file>          -> active | rotated | compressed
#            ihw_log_find <dir> <depth> [find-args] -> all log files (NUL separated)
# Component filter (case-insensitive): all (default), a server name
#            (AdminServer, WLS_REPORTS, repserver01 …), or a role alias:
#            reports (WLS_REPORTS + Reports servers + Reports tools),
#            forms (WLS_FORMS), wls (all WebLogic servers), nm, em
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

# _ihw_role name – role of a directory under $DOMAIN_HOME/servers
_ihw_role() {
    local n="$1" c="$DOMAIN_HOME/config/fmwconfig/components"
    if   [ -d "$c/ReportsServerComponent/$n" ]; then printf 'Reports server'
    elif [ -d "$c/ReportsToolsComponent/$n" ];  then printf 'Reports tools'
    elif [ "$n" = "AdminServer" ];              then printf 'Admin server'
    elif [ -e "$DOMAIN_HOME/servers/$n/logs/$n.log" ] || [ -e "$DOMAIN_HOME/servers/$n/logs/$n.out" ]; then
        printf 'Managed server'
    else printf 'Other'
    fi
}

# _ihw_match role name filter – 0 if the group matches the component filter
_ihw_match() {
    local role="$1" name="$2" f="${3,,}"
    case "$f" in
        ""|all) return 0 ;;
        reports) [[ "$role" == Reports* ]] || [[ "${name,,}" == *report* ]] ;;
        forms)   [[ "${name,,}" == *forms* ]] ;;
        wls)     [[ "$role" == "Admin server" || "$role" == "Managed server" ]] ;;
        nm)      [ "$role" = "Node Manager" ] ;;
        em)      [ "$role" = "Enterprise Manager" ] ;;
        *)       [ "${name,,}" = "$f" ] ;;
    esac
}

# ihw_log_groups [component] – role<TAB>name<TAB>dir<TAB>depth, AdminServer
# first, then managed servers, Reports servers / tools, Node Manager, EM
ihw_log_groups() {
    local filter="${1:-all}" d n role
    [ -n "${DOMAIN_HOME:-}" ] && [ -d "$DOMAIN_HOME/servers" ] || return 0
    {
        for d in "$DOMAIN_HOME"/servers/*/logs; do
            [ -d "$d" ] || continue
            n="$(basename "$(dirname "$d")")"
            role="$(_ihw_role "$n")"
            case "$role" in
                "Admin server")   printf '1' ;;
                "Managed server") printf '2' ;;
                Reports*)         printf '3' ;;
                *)                printf '4' ;;
            esac
            # depth 2: logs/reports/, logs/owsm/ … (rwservlet_diagnostic.log)
            printf '\t%s\t%s\t%s\t%s\n' "$role" "$n" "$d" 2
        done
        [ -d "$DOMAIN_HOME/nodemanager" ] && \
            printf '5\t%s\t%s\t%s\t%s\n' "Node Manager" "nodemanager" "$DOMAIN_HOME/nodemanager" 1
        [ -d "$DOMAIN_HOME/servers/AdminServer/sysman/log" ] && \
            printf '6\t%s\t%s\t%s\t%s\n' "Enterprise Manager" "em" "$DOMAIN_HOME/servers/AdminServer/sysman/log" 1
    } | sort -t$'\t' -k1,1 -k3,3 | cut -f2- | while IFS=$'\t' read -r role n d depth; do
        _ihw_match "$role" "$n" "$filter" && printf '%s\t%s\t%s\t%s\n' "$role" "$n" "$d" "$depth"
    done
}

# ihw_log_kind file – active | rotated | compressed
#   rotated: WLS  X.log00001 / X.out00001, ODL  X-diagnostic-1.log,
#            java.util.logging  X.log.1
ihw_log_kind() {
    local b; b="$(basename "$1")"
    case "$b" in
        *.gz|*.bz2|*.xz|*.zip)        printf 'compressed' ;;
        *.log[0-9]*|*.out[0-9]*)      printf 'rotated' ;;
        *.log.[0-9]*|*.out.[0-9]*)    printf 'rotated' ;;
        *-[0-9].log|*-[0-9][0-9].log|*-[0-9][0-9][0-9].log) printf 'rotated' ;;
        *)                            printf 'active' ;;
    esac
}

# ihw_log_find dir depth [find-args…] – every log file below dir (NUL
# separated, sorted): *.log *.out *.trc and their rotated / compressed forms;
# lock files excluded. Extra find arguments, e.g. -mmin -30 / -newermt DATE
ihw_log_find() {
    local dir="$1" depth="${2:-2}"
    shift 2 2>/dev/null
    find "$dir" -maxdepth "$depth" -type f "$@" \
        \( -name "*.log" -o -name "*.log[0-9]*" -o -name "*.log.[0-9]*" \
           -o -name "*.out" -o -name "*.out[0-9]*" -o -name "*.trc" \
           -o -name "*.log*.gz" -o -name "*.out*.gz" -o -name "*.log*.bz2" \) \
        ! -name "*.lck" -print0 2>/dev/null | sort -z
}
