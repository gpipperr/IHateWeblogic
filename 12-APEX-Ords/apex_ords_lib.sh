#!/bin/bash
# =============================================================================
# Script   : apex_ords_lib.sh
# Purpose  : Shared functions of the 12-APEX-Ords scripts (logic once):
#              apex_profile_run   DB profile APEX_DB_PROFILE (apex_user_profile.sql)
#              ords_bin / ords_cmd  ORDS command line of an instance (JDK_HOME)
#              ords_unpack        ORDS ZIP -> $APEX_ORDS_BASE/ords-<ver>
#              ords_linked_ver    version behind ords_N/ords
#              ords_repo_ver      ORDS_METADATA version in the database
#              ords_wait_http     wait until the ORDS listener answers
#              ver_ge             version compare (sort -V)
#              _run_sql_file / _sql_errors / _q  SQL*Plus as SYS on $ALIAS
#              tpl_render         ##KEY## templates (12-APEX-Ords/templates/)
# Use      : source "$SCRIPT_DIR/apex_ords_lib.sh" after IHateWeblogic_lib.sh
#            and environment.conf; needs ALIAS and IHW_SYS_PWD for the SQL parts.
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

APEX_ORDS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ver_ge A B – 0 if version A >= version B
ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }

# apex_profile_run MODE – MODE "-" (profile only) or "assign" (also the
# existing runtime accounts); IHW:OK|WARN|FAIL lines -> ok / warn / fail
apex_profile_run() {
    local mode="${1:--}" prof="${APEX_DB_PROFILE:-APEX_USER}" out line
    out="$(printf '@%s %s %s\n' "$APEX_ORDS_LIB_DIR/apex_user_profile.sql" "$prof" "$mode" \
           | ihw_sql_sys "$ALIAS" 2>&1)"
    if ! printf '%s\n' "$out" | grep -q '^IHW:'; then
        fail "apex_user_profile.sql failed: $(printf '%s\n' "$out" | grep -oE '(ORA|SP2)-[0-9]+' | sort -u | tr '\n' ' ')"
        return 1
    fi
    while IFS= read -r line; do
        case "$line" in
            IHW:OK:*)   ok   "${line#IHW:OK:}" ;;
            IHW:WARN:*) warn "${line#IHW:WARN:}" ;;
            IHW:FAIL:*) fail "${line#IHW:FAIL:}" ;;
        esac
    done <<< "$out"
}

# ords_bin N – path of the ords command line of instance N (via the link)
ords_bin() { printf '%s/ords_%s/ords/bin/ords' "$APEX_ORDS_BASE" "$1"; }

# ords_cmd N ARGS... – ords --config <instance config> ARGS with JDK_HOME
ords_cmd() {
    local n="$1"; shift
    JAVA_HOME="$JDK_HOME" PATH="$JDK_HOME/bin:$PATH" \
        "$(ords_bin "$n")" --config "$APEX_ORDS_BASE/ords_$n/config" "$@"
}

# ords_zip_ver ZIP – ORDS version from the patch storage path (ords/<ver>/x.zip)
ords_zip_ver() { basename "$(dirname "$1")"; }

# ords_unpack ZIP – unpack into $APEX_ORDS_BASE/ords-<ver> (skip if present);
# prints the directory
ords_unpack() {
    local zip="$1" ver dir
    ver="$(ords_zip_ver "$zip")"; dir="$APEX_ORDS_BASE/ords-$ver"
    if [ ! -f "$dir/ords.war" ]; then
        mkdir -p "$dir" && unzip -q -o "$zip" -d "$dir" || return 1
    fi
    printf '%s\n' "$dir"
}

# ords_linked_ver N – version of the software behind ords_N/ords ("" = none)
ords_linked_ver() {
    local t; t="$(readlink "$APEX_ORDS_BASE/ords_$1/ords" 2>/dev/null)" || return 0
    t="$(basename "$t")"; printf '%s\n' "${t#ords-}"
}

# ords_repo_ver – ORDS_METADATA version in the DB ("" = no repository)
ords_repo_ver() {
    printf '%s\n' "select 'ORDSV|'||version from ords_metadata.ords_version;" \
        | ihw_sql_sys "$ALIAS" 2>/dev/null | sed -n 's/^ORDSV|//p' | head -1
}

# ords_wait_http URL [SECONDS] – wait until URL answers with a HTTP code < 500;
# prints the last code
ords_wait_http() {
    local url="$1" max="${2:-120}" i=0 code=000
    while [ "$i" -lt "$max" ]; do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null)"
        [ "${code:-000}" != "000" ] && [ "$code" -lt 500 ] && break
        sleep 3; i=$((i + 3))
    done
    printf '%s\n' "$code"
}

# _run_sql_file DIR LOG "SQL lines" – SQL*Plus in DIR (the APEX scripts use
# relative @@ paths), connected as SYS to $ALIAS, with spool LOG; input after
# the connect line comes from the third argument (answers to ACCEPT prompts).
# LOG "-" = no spool, output on stdout – for scripts fed with a password
# (SQL*Plus echoes a misread input line in SP2-0734, it must not reach a file).
# Answers: SQL*Plus skips EMPTY stdin lines at an ACCEPT, and ACCEPT ... HIDE
# reads nothing without a TTY – never rely on prompts for passwords.
_run_sql_file() {
    local dir="$1" log="$2" body="$3"
    ( cd "$dir" || exit 1
      { printf 'connect sys/"%s"@%s as sysdba\n' "$IHW_SYS_PWD" "$ALIAS"
        [ "$log" = "-" ] || printf 'spool %s append\n' "$log"
        printf '%s\n' "$body"
        [ "$log" = "-" ] || printf 'spool off\n'
        printf 'exit\n'
      } | if [ "$log" = "-" ]; then ihw_sqlplus -L /nolog 2>&1; else ihw_sqlplus -L /nolog > /dev/null 2>&1; fi )
}

# _sql_errors OUTPUT – only the error codes (ORA-/SP2-/PLS-), never the text
_sql_errors() { printf '%s\n' "$1" | grep -oE '(ORA|SP2|PLS)-[0-9]+' | sort -u | tr '\n' ' '; }

# _q SQL – one statement batch as SYS on $ALIAS ("KEY|..." result lines)
_q() { printf '%s\n' "$1" | ihw_sql_sys "$ALIAS" 2>&1; }

# tpl_render TEMPLATE OUT KEY=VAL ... – replace ##KEY## (pattern of
# 09-Install/30-configure_autostart.sh _render); FAIL on a placeholder left in
# a non-comment line
tpl_render() {
    local tpl="$1" out="$2" kv; shift 2
    local -a args=()
    for kv in "$@"; do
        args+=(-e "s|##${kv%%=*}##|${kv#*=}|g")
    done
    sed "${args[@]}" "$tpl" > "$out" || return 1
    if grep -v '^[[:space:]]*#' "$out" | grep -q '##[A-Z0-9_]*##'; then
        fail "Unreplaced placeholder in $out: $(grep -v '^[[:space:]]*#' "$out" | grep -o '##[A-Z0-9_]*##' | sort -u | tr '\n' ' ')"
        return 1
    fi
}

# ords_apexlang_ver DIR – version of the APEXlang compiler inside DIR/ords.war
# (WEB-INF/lib/apexlang-compiler-<ver>.jar); APEX release N needs a compiler
# of release >= N, so ORDS and APEX are patched as a pair
ords_apexlang_ver() {
    unzip -l "$1/ords.war" 2>/dev/null \
        | sed -n 's|.*WEB-INF/lib/apexlang-compiler-\([0-9][0-9.]*\)\.jar$|\1|p' | head -1
}

# java_major JAVA_HOME – major version of that JDK (17, 21, 25 …)
java_major() {
    "$1/bin/java" -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -1
}
