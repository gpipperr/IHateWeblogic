#!/bin/bash
# =============================================================================
# ihw_shell_env.sh - switch the Oracle environment of the CURRENT shell
# =============================================================================
# One menu for FMW homes / domains and DB homes / SIDs, in the style of
# OraBashShell .profile (setdb, https://github.com/gpipperr/OraBashShell).
#
#   setdb [n|nt|t|c|h|q] menu; n = select entry n directly, nt = select + cd to the
#                   tools, t = cd to the tools, c = clear, h = help (+ tool list),
#                   q = quit without change
#   setfmw / setfw  aliases of setdb (same menu)
#   whichenv        show the current environment
#   ihwenv_configure [-f]   detect homes again -> ~/.ihw_env.conf (editable)
#   SQLPATH / ORACLE_PATH = ~/sql only for a DB entry (login.sql disturbs
#   datapatch / utlrp) - removed by FMW entries and "setdb c"
#   wlst, cdoh, cddh (alias domain), cdcfg, cdnm, cdt, cdlog [server]   helpers (see setdb h)
#   IHW_TOOLS_DIR   customer tools (status.sh, show_log.sh ... - they use the domain
#                   selected here): $ORACLE_BASE/tools, tools above a known home, or
#                   IHW_TOOLS_DIR=/path in ~/.ihw_env.conf - put in PATH
#
# Install (as oracle):  mkdir -p ~/.bashrc.d
#                       cp ihw_shell_env.sh ~/.bashrc.d/ihw_env.sh
# The OL9 default ~/.bashrc sources ~/.bashrc.d/*; open a new shell.
# Only the current shell is changed - no file of the installation, no
# environment.conf of the IHateWeblogic library. Standalone, no dependency.
# One exception, only after asking: "t" offers to create patch_install.ini when
# the tools directory has none (make_patch_install_ini.sh).
#
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

# only interactive shells - scp / sftp / cron stay silent and unchanged
[[ $- == *i* ]] || return 0 2>/dev/null

IHW_SHELL_ENV_VERSION="2026-11-06.3"
IHW_ENV_CONF="${IHW_ENV_CONF:-$HOME/.ihw_env.conf}"

# ---------------------------------------------------------------- output ----
_ihwse_c() {   # colour text: _ihwse_c 32 "text"
    if [ -t 1 ]; then printf "\033[%sm%s\033[0m" "$1" "$2"; else printf "%s" "$2"; fi
}
_ihwse_line() { _ihwse_c 35 "-----------------------------------------------------------"; printf "\n"; }
_ihwse_kv()   { printf "    %-22s " "$1"; _ihwse_c 32 "$2"; printf "\n"; }
_ihwse_err()  { _ihwse_c 31 "!! $1"; printf "\n"; }

# DB group header: home name + path
_ihwse_home_head() {
    printf "    "
    _ihwse_c 36 "$(printf "%-31s" "$1")"
    _ihwse_c 32 "$2"
    printf "\n"
}

# one menu line: nr label home [mark]
_ihwse_entry() {
    printf "  %s %3s ---> %-22s " "${4:- }" "$1" "$2"
    _ihwse_c 31 "Home: "
    _ihwse_c 32 "$3"
    printf "\n"
}

# --------------------------------------------------- login state / reset ----
# saved on the FIRST call (not at load time: ~/.bash_profile sources ~/.bashrc
# before it exports ORACLE_HOME / JAVA_HOME / PATH); exported so a sub-shell
# keeps the login values instead of saving the switched ones
_ihwse_save_orig() {
    [ -n "${IHW_ORIG_SAVED:-}" ] && return 0
    export IHW_ORIG_PATH="$PATH"
    export IHW_ORIG_ORACLE_HOME="${ORACLE_HOME:-}"
    export IHW_ORIG_ORACLE_BASE="${ORACLE_BASE:-}"
    export IHW_ORIG_ORACLE_SID="${ORACLE_SID:-}"
    export IHW_ORIG_JAVA_HOME="${JAVA_HOME:-}"
    export IHW_ORIG_SAVED=1
}

# login PATH without the entries of the login ORACLE_HOME / JAVA_HOME
# (.bash_profile puts $JAVA_HOME/bin and $ORACLE_HOME/OPatch in front)
_ihwse_base_path() {
    local p out="" IFS=:
    for p in $IHW_ORIG_PATH; do
        [ -z "$p" ] && continue
        if [ -n "$IHW_ORIG_ORACLE_HOME" ] && [[ "$p" == "$IHW_ORIG_ORACLE_HOME"/* ]]; then continue; fi
        if [ -n "$IHW_ORIG_JAVA_HOME" ] && [[ "$p" == "$IHW_ORIG_JAVA_HOME"/* ]]; then continue; fi
        out="${out:+$out:}$p"
    done
    printf "%s" "$out"
}

_ihwse_set_or_unset() {   # name value - export, or unset when empty
    if [ -n "$2" ]; then export "$1=$2"; else unset "$1"; fi
}

# back to the login values, remove everything the switcher set
_ihwse_clear() {
    # SQLPATH / ORACLE_PATH only for a DB entry: a personal login.sql disturbs
    # datapatch / catcon / utlrp and every scripted sqlplus call while patching
    unset SQLPATH ORACLE_PATH
    unset WL_HOME DOMAIN_HOME DOMAIN_NAME JDK_HOME WLST NM_HOME FMWCONFIG \
          FORMS_INSTANCE FORMS_APP_CONF REPORTS_APP_CONF \
          REPORTS_SERVER_CONF_DIR REPORTS_TOOLS_CONF_DIR \
          IHW_ENV_NAME IHW_ENV_KEY
    unset -f wlst 2>/dev/null
    export PATH="$IHW_ORIG_PATH"
    _ihwse_set_or_unset ORACLE_HOME "$IHW_ORIG_ORACLE_HOME"
    _ihwse_set_or_unset ORACLE_BASE "$IHW_ORIG_ORACLE_BASE"
    _ihwse_set_or_unset ORACLE_SID  "$IHW_ORIG_ORACLE_SID"
    _ihwse_set_or_unset JAVA_HOME   "$IHW_ORIG_JAVA_HOME"
}

# ------------------------------------------------------------- detection ----
_ihwse_fmw_jdk() {   # JDK of a FMW home: .globalEnv.properties, else bundled
    local oh="$1" j
    j="$(sed -n 's/^JAVA_HOME=//p' "$oh/oui/.globalEnv.properties" 2>/dev/null | head -1)"
    [ -n "$j" ] && [ -x "$j/bin/java" ] && { printf "%s" "$j"; return; }
    printf "%s" "$oh/oracle_common/jdk"
}

_ihwse_norm() {   # comparison key: no trailing "/", symlinks resolved (same home, other spelling)
    local p="${1%/}"
    readlink -f "$p" 2>/dev/null || printf "%s\n" "$p"
}

_ihwse_db_home_name() {   # home name: install/orabasetab field 3, else central inventory
    local oh="$1" invfile="$2" n
    n="$(awk -F: -v h="$oh" '$0 !~ /^#/ && $1 == h { print $3; exit }' "$oh/install/orabasetab" 2>/dev/null)"
    [ -z "$n" ] && n="$(grep "LOC=\"$oh\"" "$invfile" 2>/dev/null | sed -n 's/.*HOME NAME="\([^"]*\)".*/\1/p' | head -1)"
    printf "%s" "${n:-$(basename "$(dirname "$oh")")/$(basename "$oh")}"
}

_ihwse_db_sids() {   # SIDs of a DB home: /etc/oratab + running pmon processes
    local oh="$1" pid sid line
    {
        if [ -r /etc/oratab ]; then
            while IFS= read -r line; do
                case "$line" in ''|\#*|\**) continue ;; esac
                [ "$(_ihwse_norm "$(printf "%s" "$line" | cut -d: -f2)")" = "$(_ihwse_norm "$oh")" ] || continue
                printf "%s\n" "${line%%:*}"
            done < /etc/oratab
        fi
        for pid in $(pgrep -f '^ora_pmon_' 2>/dev/null); do
            [ "$(readlink -f "/proc/$pid/exe" 2>/dev/null)" = "$(_ihwse_norm "$oh")/bin/oracle" ] || continue
            sid="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | sed -n 's/^ora_pmon_\([^ ]*\).*/\1/p')"
            [ -n "$sid" ] && printf "%s\n" "$sid"
        done
    } | sort -u
}

# ihwenv_configure [-f] - detect homes, write ~/.ihw_env.conf (editable)
ihwenv_configure() {
    local force="$1" inv="" invfile h d jdk base sid hname n_fmw=0 n_db=0 answer tmp
    if [ -f "$IHW_ENV_CONF" ] && [ "$force" != "-f" ]; then
        read -r -p "   $IHW_ENV_CONF exists - overwrite? [NO]: " answer </dev/tty
        [ "$answer" = "YES" ] || [ "$answer" = "yes" ] || { printf "   unchanged\n"; return 0; }
    fi
    [ -r /etc/oraInst.loc ] && inv="$(sed -n 's/^inventory_loc=//p' /etc/oraInst.loc)"
    invfile="$inv/ContentsXML/inventory.xml"
    local -a skipped=()

    tmp="$(mktemp)" || return 1
    {
        printf "# %s - created %s by ihwenv_configure (ihw_shell_env.sh %s)\n" \
               "$IHW_ENV_CONF" "$(date '+%F %T')" "$IHW_SHELL_ENV_VERSION"
        printf "# Edit freely; 'ihwenv_configure' detects again.\n"
        printf "# IHW_FMW_ENV: label ORACLE_HOME DOMAIN_HOME|- JDK_HOME   (label - = home only)\n"
        printf "# IHW_DB_ENV : SID|- ORACLE_HOME ORACLE_BASE HOME_NAME   (SID - = home without ORACLE_SID, one per home)\n"
        printf "# IHW_TOOLS_DIR=/path   (optional line) tools directory, when it is not found by itself\n"
        printf "# Inventory  : %s\n" "${invfile}"
        # candidate homes (each normalised, duplicates removed):
        #  - central inventory (/etc/oraInst.loc), entries not REMOVED
        #  - further inventories named in <home>/oraInst.loc (DB installed with
        #    its own -invPtrLoc / by another team: not in the central inventory)
        #  - /etc/oratab
        #  - standard locations */product/<ver>/<home> - a DB home without SID
        #    is in no oratab, and without these it would stay invisible
        _ihwse_candidates "$invfile" | while read -r h; do
            [ -d "$h" ] || { printf "#SKIP %s (directory missing)\n" "$h"; continue; }
            if [ -f "$h/wlserver/server/lib/weblogic.jar" ]; then
                jdk="$(_ihwse_fmw_jdk "$h")"
                printf 'IHW_FMW_ENV+=("%s %s %s %s")\n' "-" "$h" "-" "$jdk"
                for d in $(sed -n 's/.*location="\([^"]*\)".*/\1/p' "$h/domain-registry.xml" 2>/dev/null); do
                    [ -f "$d/config/config.xml" ] || continue
                    printf 'IHW_FMW_ENV+=("%s %s %s %s")\n' "$(basename "$d")" "$h" "$d" "$jdk"
                done
            elif [ -x "$h/bin/oracle" ] && [ -x "$h/bin/sqlplus" ]; then
                base="$(ORACLE_HOME="$h" "$h/bin/orabase" 2>/dev/null)"
                base="${base:-${ORACLE_BASE:-$(dirname "$(dirname "$(dirname "$h")")")}}"
                # per home: one line per SID, then ALWAYS the home without SID
                # (OPatch / home work without ORACLE_SID) - like FMW "home only"
                hname="$(_ihwse_db_home_name "$h" "$invfile")"
                for sid in $(_ihwse_db_sids "$h"); do
                    printf 'IHW_DB_ENV+=("%s %s %s %s")\n' "$sid" "$h" "$base" "$hname"
                done
                printf 'IHW_DB_ENV+=("%s %s %s %s")\n' "-" "$h" "$base" "$hname"
            elif [ -x "$h/bin/sqlplus" ]; then
                printf "#SKIP %s (client home - no bin/oracle)\n" "$h"
            else
                printf "#SKIP %s (neither FMW nor DB home)\n" "$h"
            fi
        done
    } > "$tmp.raw"
    # order: header, FMW (home only before its domains), DB per home (SIDs, then no SID)
    {
        grep '^# ' "$tmp.raw"
        grep '^IHW_TOOLS_DIR=' "$IHW_ENV_CONF" 2>/dev/null   # set by hand: survives a new detection
        grep '^IHW_FMW_ENV' "$tmp.raw"
        grep '^IHW_DB_ENV' "$tmp.raw"
        grep '^#SKIP' "$tmp.raw" | sed 's/^#SKIP/# skipped:/'
    } > "$tmp"
    rm -f "$tmp.raw"
    mv "$tmp" "$IHW_ENV_CONF" && chmod 600 "$IHW_ENV_CONF"
    _ihwse_load
    n_fmw=${#IHW_FMW_ENV[@]}; n_db=${#IHW_DB_ENV[@]}
    _ihwse_line
    printf "   %s FMW and %s DB entries written to %s\n" "$n_fmw" "$n_db" "$IHW_ENV_CONF"
    _ihwse_line
    grep -v '^#' "$IHW_ENV_CONF"
    grep '^# skipped:' "$IHW_ENV_CONF"
}

# candidate homes for ihwenv_configure, one normalised path per line
_ihwse_candidates() {
    local invfile="$1" h loc f
    local -a invs=("$invfile")
    {
        for h in $(grep '<HOME ' "$invfile" 2>/dev/null | grep -v 'REMOVED="T"' \
                   | sed -n 's/.*LOC="\([^"]*\)".*/\1/p'); do
            printf "%s\n" "$h"
            # inventory of this home, if it is another one
            f="$(sed -n 's/^inventory_loc=//p' "$h/oraInst.loc" 2>/dev/null)"
            [ -n "$f" ] && invs+=("$f/ContentsXML/inventory.xml")
        done
        [ -r /etc/oratab ] && awk -F: '$0 !~ /^[[:space:]]*#/ && $1 != "*" && NF >= 2 { print $2 }' /etc/oratab
        for h in /u0[0-9]/app/*/product/*/* /u0[0-9]/*/product/*/* /opt/oracle/product/*/* \
                 /oracle/product/*/* ${ORACLE_BASE:+$ORACLE_BASE/product/*/*}; do
            [ -x "$h/bin/oracle" ] && printf "%s\n" "$h"
        done
        # homes of further inventories (also their oraInst.loc of DB homes)
        for h in $(awk -F: '$0 !~ /^[[:space:]]*#/ && NF >= 2 { print $2 }' /etc/oratab 2>/dev/null) \
                 /u0[0-9]/app/*/product/*/* /oracle/product/*/*; do
            f="$(sed -n 's/^inventory_loc=//p' "$h/oraInst.loc" 2>/dev/null)"
            [ -n "$f" ] && invs+=("$f/ContentsXML/inventory.xml")
        done
        for f in $(printf "%s\n" "${invs[@]}" | sort -u); do
            [ "$f" = "$invfile" ] && continue
            grep '<HOME ' "$f" 2>/dev/null | grep -v 'REMOVED="T"' | sed -n 's/.*LOC="\([^"]*\)".*/\1/p'
        done
    } | while read -r loc; do
        # first spelling wins (inventory before oratab / glob) - OPatch expects
        # the registered path; the resolved path is only the duplicate key
        [ -n "$loc" ] && printf "%s\t%s\n" "$(_ihwse_norm "$loc")" "${loc%/}"
    done | awk -F'\t' 'NF == 2 && !seen[$1]++ { print $2 }'
}

_ihwse_load() {
    unset IHW_FMW_ENV IHW_DB_ENV
    IHW_FMW_ENV=(); IHW_DB_ENV=()
    # shellcheck disable=SC1090
    [ -f "$IHW_ENV_CONF" ] && . "$IHW_ENV_CONF"
}

# ----------------------------------------------------------------- apply ----
_ihwse_first_dir() {   # first directory matching a glob that holds file $2
    local d
    for d in $1; do [ -f "$d/$2" ] && { printf "%s" "$d"; return; }; done
}

_ihwse_apply_fmw() {   # label oh dh jdk
    local label="$1" oh="$2" dh="$3" jdk="$4" p cfg d
    _ihwse_clear
    unset ORACLE_SID
    export ORACLE_HOME="$oh" WL_HOME="$oh/wlserver" JDK_HOME="$jdk" JAVA_HOME="$jdk"
    export WLST="$oh/oracle_common/common/bin/wlst.sh"
    p="$jdk/bin:$oh/oracle_common/common/bin:$oh/bin:$oh/OPatch"
    if [ "$dh" != "-" ]; then
        export DOMAIN_HOME="$dh" DOMAIN_NAME="$(basename "$dh")"
        cfg="$dh/config/fmwconfig"
        [ -d "$dh/bin" ]         && p="$dh/bin:$p"
        [ -d "$dh/reports/bin" ] && p="$dh/reports/bin:$p"
        [ -d "$dh/nodemanager" ] && export NM_HOME="$dh/nodemanager"
        [ -d "$cfg" ]            && export FMWCONFIG="$cfg"
        d="$(_ihwse_first_dir "$cfg/components/FORMS/instances/*" "converter.properties")"
        [ -n "$d" ] && export FORMS_INSTANCE="$d"
        d="$(_ihwse_first_dir "$cfg/servers/*/applications/formsapp_*/config" "formsweb.cfg")"
        [ -n "$d" ] && export FORMS_APP_CONF="$d"
        d="$(_ihwse_first_dir "$cfg/servers/*/applications/reports_*/configuration" "rwservlet.properties")"
        [ -n "$d" ] && export REPORTS_APP_CONF="$d"
        d="$(_ihwse_first_dir "$cfg/components/ReportsServerComponent/*" "rwserver.conf")"
        [ -n "$d" ] && export REPORTS_SERVER_CONF_DIR="$d"
        d="$(_ihwse_first_dir "$cfg/components/ReportsToolsComponent/*" "rwbuilder.conf")"
        [ -n "$d" ] && export REPORTS_TOOLS_CONF_DIR="$d"
        export IHW_ENV_NAME="FMW:$label"
    else
        export IHW_ENV_NAME="FMW:home-only"
    fi
    export PATH="$p:$(_ihwse_base_path)"
    # FMW wlst.sh (JRF / OPSS commands) - without arguments it starts in the domain
    wlst() {
        if [ $# -eq 0 ]; then ( cd "${DOMAIN_HOME:-$ORACLE_HOME}" && "$WLST" ); else "$WLST" "$@"; fi
    }
}

_ihwse_apply_db() {   # sid oh base
    local sid="$1" oh="$2" base="$3"
    _ihwse_clear
    export ORACLE_HOME="$oh" ORACLE_BASE="$base"
    if [ "$sid" != "-" ]; then export ORACLE_SID="$sid"; else unset ORACLE_SID; fi
    export PATH="$oh/bin:$oh/OPatch:$(_ihwse_base_path)"
    # personal SQL scripts + login.sql (sqlplus SQLPATH, SQLcl ORACLE_PATH)
    if [ -d "$HOME/sql" ]; then
        export SQLPATH="$HOME/sql" ORACLE_PATH="$HOME/sql"
    fi
    if [ "$sid" = "-" ]; then export IHW_ENV_NAME="DB:no-SID"; else export IHW_ENV_NAME="DB:${sid}"; fi
}

# ------------------------------------------------------------------ menu ----
setdb() {
    _ihwse_save_orig
    local sel="$1" n=0 i e mark key total last_home="" e4
    local -a types=() idx=()
    for i in "${!IHW_FMW_ENV[@]}"; do types+=(FMW); idx+=("$i"); done
    for i in "${!IHW_DB_ENV[@]}";  do types+=(DB);  idx+=("$i"); done
    total=${#types[@]}

    if [ -z "$sel" ]; then
        _ihwse_line
        _ihwse_kv "Current environment :" "${IHW_ENV_NAME:-login values}"
        _ihwse_line
        [ "$total" -eq 0 ] && _ihwse_err "no environments in $IHW_ENV_CONF - run ihwenv_configure"
        [ "${#IHW_FMW_ENV[@]}" -gt 0 ] && printf "  FMW\n"
        for ((n = 0; n < total; n++)); do
            [ "${types[$n]}" = DB ] && [ "$n" -eq "${#IHW_FMW_ENV[@]}" ] && { [ "$n" -gt 0 ] && _ihwse_line; printf "  DB\n"; }
            if [ "${types[$n]}" = FMW ]; then
                read -r e1 e2 e3 _ <<< "${IHW_FMW_ENV[${idx[$n]}]}"
                key="FMW $e2 $e3"
                [ "$e1" = "-" ] && e1="-  (home only)"
            else
                read -r e1 e2 _ e4 <<< "${IHW_DB_ENV[${idx[$n]}]}"
                key="DB $e2 $e1"
                [ "$e1" = "-" ] && e1="-  (no SID)"
                # one header per DB home: home name + path, entries below it
                if [ "$e2" != "$last_home" ]; then
                    _ihwse_home_head "${e4:-$(basename "$(dirname "$e2")")/$(basename "$e2")}" "$e2"
                    last_home="$e2"
                fi
            fi
            mark=" "; [ "$key" = "${IHW_ENV_KEY:-}" ] && mark="*"
            if [ "${types[$n]}" = DB ]; then
                printf "  %s %3s ---> %s\n" "$mark" "$((n + 1))" "$e1"
            else
                _ihwse_entry "$((n + 1))" "$e1" "$e2" "$mark"
            fi
        done
        _ihwse_line
        printf "      t ---> tools                (cd to the tools directory, 2t = entry 2 + tools)\n"
        printf "      c ---> clear environment    (back to the login values)\n"
        printf "      h ---> help                 (aliases / functions / tools / variables)\n"
        printf "      q ---> quit                 (nothing changed)\n"
        if ! read -r -p "   Selection [1]: " sel </dev/tty; then
            _ihwse_err "no terminal - Environment not changed (use setdb <n>)"
            return 1
        fi
        sel="${sel:-1}"
    fi

    # 2t = select entry 2, then cd to the tools
    local to_tools=false
    if [[ "$sel" =~ ^([0-9]+)[tT]$ ]]; then sel="${BASH_REMATCH[1]}"; to_tools=true; fi
    case "$sel" in
        t|T) cdt; return $? ;;
        c|C) _ihwse_clear; _ihwse_line; _ihwse_kv "Environment cleared" "login values"; whichenv; return 0 ;;
        h|H) ihwenv_help; setdb; return $? ;;
        q|Q) printf "   Environment not changed\n"; return 0 ;;
    esac
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "$total" ]; then
        _ihwse_err "Environment not changed (valid: 1-$total, 1-${total} + t, t, c, h, q)"
        return 1
    fi
    n=$((sel - 1))
    if [ "${types[$n]}" = FMW ]; then
        read -r e1 e2 e3 e4 <<< "${IHW_FMW_ENV[${idx[$n]}]}"
        _ihwse_apply_fmw "$e1" "$e2" "$e3" "$e4"
        export IHW_ENV_KEY="FMW $e2 $e3"
    else
        read -r e1 e2 e3 _ <<< "${IHW_DB_ENV[${idx[$n]}]}"
        _ihwse_apply_db "$e1" "$e2" "$e3"
        export IHW_ENV_KEY="DB $e2 $e1"
    fi
    unset e1 e2 e3 e4
    _ihwse_tools_path
    whichenv
    # change the prompt if the function was defined in .bash_profile
    declare -F myprompt > /dev/null && myprompt
    $to_tools && cdt
    return 0
}
alias setfmw=setdb
alias setfw=setdb

whichenv() {
    _ihwse_line
    _ihwse_kv "Environment"  "${IHW_ENV_NAME:-login values}"
    _ihwse_kv "ORACLE_HOME"  "${ORACLE_HOME:--}"
    [ -n "${ORACLE_SID:-}" ]  && _ihwse_kv "ORACLE_SID"  "$ORACLE_SID"
    [ -n "${ORACLE_BASE:-}" ] && _ihwse_kv "ORACLE_BASE" "$ORACLE_BASE"
    [ -n "${DOMAIN_HOME:-}" ] && _ihwse_kv "DOMAIN_HOME" "$DOMAIN_HOME"
    _ihwse_kv "JAVA_HOME"    "${JAVA_HOME:--}"
    [ -n "${WLST:-}" ]        && _ihwse_kv "WLST"        "$WLST"
    _ihwse_kv "TNS_ADMIN"    "${TNS_ADMIN:--}"
    _ihwse_kv "NLS_LANG"     "${NLS_LANG:--}"
    [ -n "${SQLPATH:-}" ]     && _ihwse_kv "SQLPATH"     "$SQLPATH"
    [ -n "${IHW_TOOLS_DIR:-}" ] && _ihwse_kv "Tools" "$IHW_TOOLS_DIR  (cdt, status.sh -q, setdb h)"
    _ihwse_line
}

ihwenv_help() {
    _ihwse_line
    printf "   ihw_shell_env.sh %s - cache %s\n" "$IHW_SHELL_ENV_VERSION" "$IHW_ENV_CONF"
    _ihwse_line
    printf "   %-24s %s\n" "setdb [n|nt|t|c|h|q]" "menu: FMW homes/domains, DB homes/SIDs; n = direct, q = quit"
    printf "   %-24s %s\n" ""                   "t = cd to the tools, nt = entry n + cd to the tools"
    printf "   %-24s %s\n" "setfmw, setfw"      "aliases of setdb (same menu)"
    printf "   %-24s %s\n" "whichenv"           "show the current environment"
    printf "   %-24s %s\n" "ihwenv_configure [-f]" "detect homes again (-f = without asking)"
    printf "   %-24s %s\n" "wlst [script args]" "FMW wlst.sh (oracle_common), no args: starts in DOMAIN_HOME"
    printf "   %-24s %s\n" "cdoh / cddh, domain" "cd ORACLE_HOME / DOMAIN_HOME (domain = cddh)"
    printf "   %-24s %s\n" "cdcfg / cdnm"       "cd DOMAIN_HOME/config/fmwconfig / nodemanager"
    printf "   %-24s %s\n" "cdt"                "cd to the tools directory"
    printf "   %-24s %s\n" "cdlog [server]"     "cd server logs (FMW, no arg = list) / ADR diag (DB)"
    _ihwse_line
    _ihwse_tools_help
    _ihwse_line
    printf "   Set by an FMW entry: ORACLE_HOME WL_HOME DOMAIN_HOME DOMAIN_NAME JDK_HOME\n"
    printf "     JAVA_HOME WLST NM_HOME FMWCONFIG FORMS_INSTANCE FORMS_APP_CONF (formsweb.cfg,\n"
    printf "     default.env) REPORTS_APP_CONF (rwservlet.properties, cgicmd.dat)\n"
    printf "     REPORTS_SERVER_CONF_DIR (rwserver.conf) REPORTS_TOOLS_CONF_DIR (rwbuilder.conf)\n"
    printf "     PATH: domain reports/bin, domain bin, JDK,\n"
    printf "     oracle_common/common/bin, ORACLE_HOME/bin, OPatch\n"
    printf "   Set by a DB entry : ORACLE_HOME ORACLE_SID ORACLE_BASE SQLPATH ORACLE_PATH (~/sql)\n"
    printf "     PATH: bin, OPatch - before datapatch / utlrp: setdb c (removes SQLPATH)\n"
    printf "   Removed by c / FMW: SQLPATH ORACLE_PATH (login.sql disturbs patching)\n"
    printf "   Never changed     : TNS_ADMIN NLS_LANG\n"
    _ihwse_line
}

# tools of the directory that exist, one line each (setdb h)
_ihwse_tools_help() {
    local l t txt
    if [ -z "${IHW_TOOLS_DIR:-}" ]; then
        printf "   Tools: not found - unpack the tools ZIP into \$ORACLE_BASE/tools,\n"
        printf "          or add IHW_TOOLS_DIR=/path to %s\n" "$IHW_ENV_CONF"
        return 0
    fi
    printf "   Tools in %s (in PATH; they use the domain selected here):\n" "$IHW_TOOLS_DIR"
    while IFS='|' read -r l t txt; do
        [ -f "$IHW_TOOLS_DIR/${t#. }" ] || continue
        printf "   %-8s %-30s %s\n" "$l" "${t}${txt%%|*}" "${txt#*|}"
    done <<'EOF'
Status|status.sh| [-q]|ports, processes, HTTP, Node Manager (-q = without WLST)
Status|status.sh| --store-nm-key|store the Node Manager login once, for status.sh
Logs|show_log.sh| [component]|follow the log of one component
Logs|show_errors.sh| [-r]|errors of all logs, live (-r = first the last hour)
Logs|show_all_logs.sh||follow all logs written in the last hour
Analysis|collect_fmw_env.sh||collect the patch level etc. for the analysis (read-only)
Analysis|export_forms_reports_conf.sh||export the configuration, for the 14c move (read-only)
Analysis|clone_check_fmw.sh||is the environment clone-capable?
Analysis|check_disk_space.sh||where is the disk space, what can be cleaned
Patch|clean_domain_tmp.sh| [--apply]|delete servers/*/tmp + cache of the stopped domain, rebuilt at the next start
Patch|make_patch_install_ini.sh| [--apply]|create patch_install.ini from the domain (for the cookbooks)
Patch|. set_script_env.sh||values of patch_install.ini for the cookbook commands
Patch|fmw_patch_env.sh||variables of the manual patch cookbooks
Patch|mos_patch_download.sh||download a patch list from My Oracle Support
EOF
    printf "   patch_install.ini: optional for status / logs (they use the selected domain),\n"
    printf "     needed by the cookbooks. Missing: t / cdt offer once per session to create it.\n"
}

# ------------------------------------------------------------ cd helpers ----
_ihwse_cd() { if [ -n "$2" ] && [ -d "$2" ]; then cd "$2" || return; else _ihwse_err "$1 not set - setdb"; return 1; fi; }
cdoh()  { _ihwse_cd ORACLE_HOME "${ORACLE_HOME:-}"; }
cddh()  { _ihwse_cd DOMAIN_HOME "${DOMAIN_HOME:-}"; }
cdcfg() { _ihwse_cd FMWCONFIG   "${FMWCONFIG:-}"; }
cdnm()  { _ihwse_cd NM_HOME     "${NM_HOME:-}"; }
cdt() {
    _ihwse_tools_path
    if [ -z "${IHW_TOOLS_DIR:-}" ]; then
        _ihwse_err "tools directory not found - unpack the tools ZIP into \$ORACLE_BASE/tools,"
        _ihwse_err "or add IHW_TOOLS_DIR=/path to $IHW_ENV_CONF"
        return 1
    fi
    cd "$IHW_TOOLS_DIR" || return
    printf "   %s - setdb h lists the tools (status.sh -q, show_log.sh, show_errors.sh ...)\n" "$PWD"
    _ihwse_ini_offer
}

# no patch_install.ini next to the tools + a domain selected: ask once per session.
# Only the cookbooks need the file. Written by the tool, never here.
_ihwse_ini_offer() {
    local a tool="$IHW_TOOLS_DIR/make_patch_install_ini.sh"
    [ -f "$IHW_TOOLS_DIR/patch_install.ini" ] && return 0
    [ -n "${IHW_INI_ASKED:-}" ] && return 0
    [ -x "$tool" ] || return 0
    case "${IHW_ENV_KEY:-}" in
        "FMW "*" -"|"") return 0 ;;
        "FMW "*) ;;
        *) return 0 ;;
    esac
    export IHW_INI_ASKED=1
    read -r -p "   no patch_install.ini (only the cookbooks need it) - create it from domain ${DOMAIN_NAME:-?}? [y/N]: " a </dev/tty 2>/dev/null || return 0
    case "$a" in
        y|Y|yes|YES|j|J|ja|JA) "$tool" --apply ;;
        *) printf "   not created - later: make_patch_install_ini.sh\n" ;;
    esac
}
alias domain=cddh
cdlog() {
    if [ -n "${DOMAIN_HOME:-}" ]; then
        if [ -z "$1" ]; then
            printf "   servers: "; ls "$DOMAIN_HOME/servers" 2>/dev/null | tr '\n' ' '; printf "\n"
            printf "   cdlog <server>\n"
            return 0
        fi
        _ihwse_cd "logs of $1" "$DOMAIN_HOME/servers/$1/logs"
    elif [ -n "${ORACLE_BASE:-}" ] && [ -d "$ORACLE_BASE/diag" ]; then
        cd "$ORACLE_BASE/diag" || return
        command -v adrci > /dev/null && adrci exec="show homes"
    else
        _ihwse_err "no DOMAIN_HOME / ORACLE_BASE - setdb"
        return 1
    fi
}

# ----------------------------------------------------------- tools dir ----
# _ihwse_tools_find - first directory with the tools: IHW_TOOLS_DIR (also from
# ~/.ihw_env.conf), $ORACLE_BASE/tools, tools above a known home
# (/u01/app/oracle/fmw -> /u01/app/oracle/tools, /oracle/product/mw ->
# /oracle/tools), the base of a DB entry, fixed paths. ORACLE_BASE may be empty
# at load (.bash_profile sources .bashrc before its exports).
_ihwse_tools_find() {
    local d e oh base
    local -a c=()
    [ -n "${ORACLE_BASE:-}" ] && c+=("$ORACLE_BASE/tools")
    for oh in "${ORACLE_HOME:-}"; do
        [ -n "$oh" ] && c+=("$(dirname "$oh")/tools" "$(dirname "$(dirname "$(dirname "$oh")")")/tools")
    done
    for e in "${IHW_FMW_ENV[@]}"; do
        read -r _ oh _ <<< "$e"
        c+=("$(dirname "$oh")/tools" "$(dirname "$(dirname "$(dirname "$oh")")")/tools")
    done
    for e in "${IHW_DB_ENV[@]}"; do
        read -r _ oh base _ <<< "$e"
        c+=("$base/tools" "$(dirname "$(dirname "$(dirname "$oh")")")/tools")
    done
    c+=(/u01/oracle/tools /u01/app/oracle/tools)
    for d in "${c[@]}"; do
        if [ -f "$d/status.sh" ] || [ -f "$d/set_script_env.sh" ]; then
            printf "%s" "$d"
            return 0
        fi
    done
    return 1
}

# _ihwse_tools_path - set IHW_TOOLS_DIR if still empty, keep it in PATH: also in the
# saved login PATH, so it stays after "setdb c"
_ihwse_tools_path() {
    [ -n "${IHW_TOOLS_DIR:-}" ] || IHW_TOOLS_DIR="$(_ihwse_tools_find)"
    if [ -z "$IHW_TOOLS_DIR" ] || [ ! -d "$IHW_TOOLS_DIR" ]; then
        unset IHW_TOOLS_DIR
        return 0
    fi
    export IHW_TOOLS_DIR
    case ":$PATH:" in
        *":$IHW_TOOLS_DIR:"*) ;;
        *) export PATH="$IHW_TOOLS_DIR:$PATH" ;;
    esac
    if [ -n "${IHW_ORIG_PATH:-}" ]; then
        case ":$IHW_ORIG_PATH:" in
            *":$IHW_TOOLS_DIR:"*) ;;
            *) export IHW_ORIG_PATH="$IHW_TOOLS_DIR:$IHW_ORIG_PATH" ;;
        esac
    fi
}

# ------------------------------------------------------------------ load ----
# a second copy in ~/.bashrc.d (e.g. ihw_shell_env.sh next to ihw_env.sh) is
# loaded later and silently replaces these functions with its version
for _ihwse_f in "$HOME"/.bashrc.d/*; do
    [ -f "$_ihwse_f" ] && [ "$_ihwse_f" -ef "${BASH_SOURCE[0]}" ] && continue
    grep -q '^IHW_SHELL_ENV_VERSION=' "$_ihwse_f" 2>/dev/null || continue
    _ihwse_err "ihw_shell_env: second copy $_ihwse_f ($(sed -n 's/^IHW_SHELL_ENV_VERSION=//p' "$_ihwse_f" | tr -d '"')) - keep only ~/.bashrc.d/ihw_env.sh"
done
unset _ihwse_f
_ihwse_load
if [ ! -f "$IHW_ENV_CONF" ]; then
    printf "ihw_shell_env: first start - detecting the Oracle homes\n"
    ihwenv_configure -f
fi
_ihwse_tools_path
