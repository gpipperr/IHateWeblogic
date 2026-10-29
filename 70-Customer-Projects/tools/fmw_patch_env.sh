#!/bin/bash
# =============================================================================
# Script   : fmw_patch_env.sh
# Purpose  : Detect the variables of the manual patch cookbooks
#            (Patch_Kochbuch_*_de.txt, block VORAUSSETZUNGEN) from the running
#            environment and set them:
#              ORACLE_HOME DOMAIN_HOME INV_PTR INVENTORY JDK_LINK NEW_JDK_BASE
#              PATCH_DIR STAGE BACKUP LOGDIR
#            Standalone – no IHateWeblogic library, plain bash + coreutils.
# Call     : . ./fmw_patch_env.sh [options]     SOURCED: exports into this shell
#            ./fmw_patch_env.sh [options]       executed: shows the values only
#              -o DIR     Oracle Home  (default: $ORACLE_HOME, running WebLogic,
#                         /oracle/product/mw, /u01/app/oracle/fmw …)
#              -d DIR     Domain Home  (default: $DOMAIN_HOME, domain-registry.xml,
#                         running AdminServer)
#              -b DIR     base directory of the patch run (default: current dir)
#                         -> PATCH_DIR=<b>/zip  STAGE=<b>/stage  LOGDIR=<STAGE>/logs
#              -k DIR     backup directory (default: <prefix>/backup/<name> when
#                         <b> = <prefix>/install/<name>, else <b>/backup)
#              --apply    create PATCH_DIR / STAGE / LOGDIR / BACKUP and write
#                         <b>/patch_env.sh (". <b>/patch_env.sh" in a 2nd terminal)
# Runs as  : the software owner of the Oracle Home (oracle), not root
# Doc      : 70-Customer-Projects/tools/README.md
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================
# No "set -u" / "exit" at top level: the script is meant to be sourced.

_fpe_main() {
    local VERSION="2026-10-29.1"   # bump on every change
    local oh="${ORACLE_HOME:-}" dh="${DOMAIN_HOME:-}" base="$PWD" bk="" apply=false
    local sourced=false args="$*" v
    [ "${BASH_SOURCE[1]}" != "$0" ] && sourced=true
    while [ $# -gt 0 ]; do
        case "$1" in
            -o) oh="${2:-}"; shift ;;
            -d) dh="${2:-}"; shift ;;
            -b) base="${2:-}"; shift ;;
            -k) bk="${2:-}"; shift ;;
            --apply) apply=true ;;
            -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; printf 'Version: %s\n' "$VERSION"; return 0 ;;
            -V|--version) printf '%s\n' "$VERSION"; return 0 ;;
            *) printf 'Unknown option: %s\n' "$1" >&2; return 2 ;;
        esac
        shift
    done
    local nfail=0 nwarn=0
    _ok()   { printf '\033[32m  OK  \033[0m %s\n' "$*"; }
    _warn() { nwarn=$((nwarn + 1)); printf '\033[33m WARN \033[0m %s\n' "$*"; }
    _fail() { nfail=$((nfail + 1)); printf '\033[31m FAIL \033[0m %s\n' "$*"; }
    _var()  { printf '  %-13s %s\n' "$1" "$2"; }

    printf 'fmw_patch_env.sh %s – %s – %s\n' "$VERSION" "$(hostname -s 2>/dev/null)" \
        "$($sourced && printf 'sourced: variables are exported' || printf 'executed: display only (source it to set the variables)')"
    [ "$(id -u)" -eq 0 ] && _warn "running as root – the cookbook runs as the software owner"

    # --- ORACLE_HOME --------------------------------------------------------------
    local c src_oh="option / environment"
    if [ -z "$oh" ] || [ ! -d "$oh/OPatch" ]; then
        oh="$(ps -eo args= 2>/dev/null | sed -n 's/.*-Dweblogic\.home=\([^ ]*\)\/wlserver\/server.*/\1/p' | head -1)"
        src_oh="running WebLogic (-Dweblogic.home)"
        if [ ! -d "$oh/OPatch" ]; then
            oh=""
            for c in /oracle/product/mw /u01/app/oracle/fmw /u01/oracle/fmw \
                     /u01/app/oracle/middleware /u01/oracle/middleware; do
                [ -d "$c/OPatch" ] && { oh="$c"; src_oh="default path"; break; }
            done
        fi
    fi
    [ -d "${oh:-/nonexistent}/OPatch" ] || { _fail "ORACLE_HOME not found – use -o"; oh=""; }

    # --- DOMAIN_HOME --------------------------------------------------------------
    local src_dh="option / environment"
    if [ -z "$dh" ] && [ -n "$oh" ] && [ -r "$oh/domain-registry.xml" ]; then
        dh="$(sed -n 's/.*location="\([^"]*\)".*/\1/p' "$oh/domain-registry.xml" | head -1)"
        src_dh="$oh/domain-registry.xml"
        [ "$(sed -n 's/.*location="\([^"]*\)".*/\1/p' "$oh/domain-registry.xml" | wc -l)" -gt 1 ] && \
            _warn "domain-registry.xml lists more than one domain – first one taken, check / use -d"
    fi
    if [ -z "$dh" ]; then
        dh="$(ps -eo args= 2>/dev/null | sed -n 's/.*-Dweblogic\.RootDirectory=\([^ ]*\).*/\1/p' | head -1)"
        src_dh="running WebLogic (-Dweblogic.RootDirectory)"
    fi
    [ -f "${dh:-/nonexistent}/config/config.xml" ] || { _fail "DOMAIN_HOME not found (no config/config.xml) – use -d"; dh=""; }

    # --- Inventory ----------------------------------------------------------------
    local invptr="" inv=""
    for c in /etc/oraInst.loc "$oh/oraInst.loc"; do
        [ -r "$c" ] && { invptr="$c"; break; }
    done
    [ -n "$invptr" ] && inv="$(sed -n 's/^inventory_loc=//p' "$invptr" | head -1)"
    [ -d "${inv:-/nonexistent}/ContentsXML" ] || _fail "central inventory not found (oraInst.loc: ${invptr:-none})"

    # --- JDK of OPatch / the servers (.globalEnv.properties) ------------------------
    local jdk="" jdkv="" jtype=""
    [ -n "$oh" ] && jdk="$(sed -n 's/^JAVA_HOME=//p' "$oh/oui/.globalEnv.properties" 2>/dev/null | head -1)"
    if [ -x "${jdk:-/nonexistent}/bin/java" ]; then
        jdkv="$("$jdk/bin/java" -version 2>&1 | sed -n 's/.*build \(1\.8[^)]*\|[0-9][^)]*\)).*/\1/p' | head -1)"
        if [ -L "$jdk" ]; then jtype="link -> $(readlink "$jdk")  (cookbook 4.4 variant a)"
        else jtype="real directory  (cookbook 4.4 variant b: make it a link once)"; fi
        case "$jdk" in "$oh"/*) _fail "JAVA_HOME of .globalEnv.properties lies INSIDE ORACLE_HOME (KB175049)" ;; esac
    else
        _fail "JAVA_HOME in $oh/oui/.globalEnv.properties not found / not executable: ${jdk:-empty}"
    fi

    # --- patch run directories ------------------------------------------------------
    base="$(cd "$base" 2>/dev/null && pwd || printf '%s' "$base")"
    if [ -z "$bk" ]; then
        case "$base" in
            */install/*) bk="${base%/install/*}/backup/$(basename "$base")" ;;
            *)           bk="$base/backup" ;;
        esac
    fi
    case "$base/" in "$oh"/*|"$dh"/*) _fail "base directory $base lies inside ORACLE_HOME / DOMAIN_HOME" ;; esac

    # --- set ------------------------------------------------------------------------
    export ORACLE_HOME="$oh" DOMAIN_HOME="$dh" INV_PTR="$invptr" INVENTORY="$inv"
    export JDK_LINK="$jdk" NEW_JDK_BASE="$(dirname "${jdk:-/x}")"
    export PATCH_DIR="$base/zip" STAGE="$base/stage" BACKUP="$bk"
    export LOGDIR="$STAGE/logs"

    printf '\nVariables of the cookbook (block VORAUSSETZUNGEN):\n'
    _var ORACLE_HOME  "$ORACLE_HOME   [$src_oh]"
    _var DOMAIN_HOME  "$DOMAIN_HOME   [$src_dh]"
    _var INV_PTR      "$INV_PTR"
    _var INVENTORY    "$INVENTORY"
    _var JDK_LINK     "$JDK_LINK   [.globalEnv.properties]"
    _var NEW_JDK_BASE "$NEW_JDK_BASE"
    _var PATCH_DIR    "$PATCH_DIR"
    _var STAGE        "$STAGE"
    _var BACKUP       "$BACKUP"
    _var LOGDIR       "$LOGDIR"

    # --- facts the cookbook decides on ------------------------------------------------
    printf '\nFacts:\n'
    [ -n "$jdk" ] && _var "JDK" "$jdkv – $jtype"
    [ -x "$oh/oracle_common/jdk/bin/java" ] && \
        _var "bundled JDK" "$("$oh/oracle_common/jdk/bin/java" -version 2>&1 | sed -n 's/.*build \([^)]*\)).*/\1/p' | head -1)  (cookbook 4.7)"
    [ -n "$oh" ] && _var "OPatch" "$("$oh/OPatch/opatch" version 2>/dev/null | sed -n 's/^OPatch Version: //p')"
    _var "glibc" "$(ldd --version 2>/dev/null | head -1 | awk '{print $NF}')  (>= 2.34: Forms QPR before Reports QPR, KB873815)"
    local ohs
    ohs="$(ls "$dh/config/fmwconfig/components/OHS" 2>/dev/null | grep -v '^instances$' | tr '\n' ' ')"
    [ -n "$dh" ] && _var "OHS instances" "${ohs:-none (step 9 still applies when the OHS binaries are in the home)}"
    local nzip=0
    nzip="$(find "$PATCH_DIR" -maxdepth 2 -name 'p*.zip' 2>/dev/null | wc -l)"
    _var "ZIPs" "$nzip in $PATCH_DIR"
    local running
    running="$(ps -eo args= 2>/dev/null | grep -cE "weblogic\.(Server|NodeManager)|frmweb|rwserver|rwengine" )"
    _var "processes" "$running WebLogic / Node Manager / Forms / Reports (must be 0 from step 2 on)"

    # --- free space -------------------------------------------------------------------
    local d p
    for v in STAGE BACKUP; do
        d="${!v}"; p="$d"; while [ ! -d "$p" ] && [ "$p" != "/" ]; do p="$(dirname "$p")"; done
        _var "free $v" "$(df -Ph "$p" | awk 'NR==2 {print $4" on "$6}')"
    done
    p="$BACKUP"; while [ ! -d "$p" ] && [ "$p" != "/" ]; do p="$(dirname "$p")"; done
    if [ -n "$oh" ] && [ "$(df -P "$p" | awk 'NR==2 {print $6}')" = "$(df -P "$oh" | awk 'NR==2 {print $6}')" ]; then
        _warn "BACKUP is on the same file system as ORACLE_HOME – better another one (-k)"
    fi

    # --- --apply: directories + env file ----------------------------------------------
    local envf="$base/patch_env.sh"
    if $apply && [ "$nfail" -eq 0 ]; then
        mkdir -p "$PATCH_DIR" "$STAGE" "$LOGDIR" "$BACKUP" || _fail "mkdir failed"
        {
            printf '# written by fmw_patch_env.sh %s on %s - load with: . %s\n' "$VERSION" "$(date '+%Y-%m-%d %H:%M')" "$envf"
            for v in ORACLE_HOME DOMAIN_HOME INV_PTR INVENTORY JDK_LINK NEW_JDK_BASE PATCH_DIR STAGE BACKUP LOGDIR; do
                printf 'export %s=%q\n' "$v" "${!v}"
            done
        } > "$envf" && _ok "written: $envf  (in a 2nd terminal: . $envf)"
    elif $apply; then
        _fail "nothing created – fix the FAIL lines first"
    else
        printf '\n  --apply creates the directories and writes %s\n' "$envf"
    fi

    printf '\n'
    if [ "$nfail" -gt 0 ]; then
        _fail "$nfail value(s) missing – check before starting the cookbook"; return 2
    fi
    $sourced && _ok "variables exported – continue with SCHRITT 0 of the cookbook" \
             || printf '  To set them in this shell: . %s %s\n' "${BASH_SOURCE[0]}" "$args"
    [ "$nwarn" -gt 0 ] && return 1
    return 0
}
_fpe_main "$@"
_fpe_rc=$?
unset -f _fpe_main _ok _warn _fail _var
# sourced: return (keeps the shell), executed: exit
return "$_fpe_rc" 2>/dev/null || exit "$_fpe_rc"
