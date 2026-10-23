#!/bin/bash
# =============================================================================
# Script   : install_db_client_tools.sh
# Purpose  : Database client tools of this library, independent of a local DB
#            or the FMW home:
#              - Oracle Instant Client 23.26.x (basic + sqlplus + tools) –
#                SQL*Plus for Oracle installer scripts (APEX), DB checks,
#                sqlldr / expdp / impdp
#              - SQLcl – apex export, rest export, Liquibase
#            Download from OTN (no login) into $PATCH_STORAGE/instantclient/<ver>/
#            and $PATCH_STORAGE/sqlcl/<ver>/, install into
#            $ORACLE_BASE/product/instantclient_<ver> / sqlcl_<ver>, links
#            instantclient / sqlcl -> current version (switched only after a
#            successful smoke test). Re-run = update; old versions stay for
#            --rollback; --keep N removes older ones.
# Call     : ./00-Setup/install_db_client_tools.sh [--apply] [--rollback] [--keep N]
# Runs as  : oracle
# Requires : curl, unzip, python3, libaio (Instant Client), JDK_HOME (SQLcl)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 00-Setup/README.md (install_db_client_tools.sh),
#            09-Install/oracle_software_version.conf (IC_*, SQLCL_*)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"
SW_CONF="$ROOT_DIR/09-Install/oracle_software_version.conf"

LIB="$SCRIPT_DIR/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m Cannot find IHateWeblogic_lib.sh: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=./IHateWeblogic_lib.sh
source "$LIB"
check_env_conf "$ENV_CONF" || exit 2
# shellcheck source=../environment.conf
source "$ENV_CONF"
# shellcheck source=../09-Install/oracle_software_version.conf
[ -f "$SW_CONF" ] && source "$SW_CONF"

init_log

APPLY=false; ROLLBACK=false; KEEP=2
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)    APPLY=true ;;
        --rollback) ROLLBACK=true ;;
        --keep)     KEEP="${2:-}"; shift ;;
        --keep=*)   KEEP="${1#*=}" ;;
        --help|-h)
            printf "Usage: %s [--apply] [--rollback] [--keep N]\n" "$(basename "$0")"
            printf "  (none)      show installed / configured versions (read-only)\n"
            printf "  --apply     download + install / update, switch the links\n"
            printf "  --rollback  with --apply: link back to the previous version\n"
            printf "  --keep N    versions kept per tool (default 2)\n"
            exit 0 ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 2 ;;
    esac
    shift
done
[[ "$KEEP" =~ ^[0-9]+$ ]] && [ "$KEEP" -ge 1 ] || { printf "\033[31mERROR\033[0m --keep needs a number >= 1\n" >&2; exit 2; }

PROD="${ORACLE_BASE:?ORACLE_BASE not set}/product"
IC_LINK="$PROD/instantclient"
SQLCL_LINK="$PROD/sqlcl"
IC_STORE="${PATCH_STORAGE:?PATCH_STORAGE not set}/instantclient"
SQLCL_STORE="$PATCH_STORAGE/sqlcl"

printLine
section "DB client tools ($(date '+%Y-%m-%d %H:%M:%S'))"

# _current LINK – version the link points to (suffix after the last "_")
_current() { local t; t="$(readlink "$1" 2>/dev/null)"; [ -n "$t" ] && printf '%s' "${t##*_}"; }
# _versions PREFIX – installed version directories, oldest first
_versions() { ls -d "$1"_* 2>/dev/null | sed "s|^$1_||" | sort -V; }

# _ic_smoke DIR / _sqlcl_smoke DIR – version line or nothing
_ic_smoke()    { LD_LIBRARY_PATH="$1" "$1/sqlplus" -V 2>/dev/null | grep -m1 -i 'release\|version'; }
_sqlcl_smoke() { JAVA_HOME="${JDK_HOME:-}" "$1/bin/sql" -V 2>/dev/null | grep -m1 -iE 'sqlcl|release|[0-9]+\.[0-9]+'; }

# _switch NAME LINK DIR VERSION SMOKEFN – link to DIR after a successful smoke test
_switch() {
    local name="$1" link="$2" dir="$3" ver="$4" smoke="$5" out
    out="$($smoke "$dir")"
    if [ -z "$out" ]; then
        fail "$name $ver: smoke test failed – link not switched ($dir)"
        return 1
    fi
    ok "$(printf "%s %s smoke test: %s" "$name" "$ver" "$out")"
    if [ "$(readlink "$link" 2>/dev/null)" = "$(basename "$dir")" ]; then
        ok "$name link already on $ver"
    else
        ln -sfn "$(basename "$dir")" "$link" && ok "$(printf "%s link -> %s" "$name" "$(basename "$dir")")"
    fi
}

# _cleanup NAME PREFIX LINK – keep the newest KEEP versions and the current one
_cleanup() {
    local name="$1" prefix="$2" link="$3" cur n v
    cur="$(_current "$link")"
    n="$(_versions "$prefix" | wc -l)"
    [ "$n" -le "$KEEP" ] && return 0
    for v in $(_versions "$prefix" | head -n $(( n - KEEP ))); do
        [ "$v" = "$cur" ] && continue
        if $APPLY; then
            rm -rf -- "${prefix}_${v}" && ok "$name $v removed (--keep $KEEP)"
        else
            info "$name $v would be removed (--keep $KEEP)"
        fi
    done
}

# =============================================================================
# 0. Prerequisites
# =============================================================================
section "Prerequisites"
for _t in curl unzip python3; do
    command -v "$_t" > /dev/null 2>&1 && ok "$_t found" || fail "$_t missing"
done
if rpm -q libaio > /dev/null 2>&1 || rpm -q libaio1t64 > /dev/null 2>&1; then
    ok "libaio installed (Instant Client)"
else
    fail "libaio missing – as root: dnf install libaio"
fi
[ -x "${JDK_HOME:-}/bin/java" ] && ok "JDK_HOME for SQLcl: $JDK_HOME" || warn "JDK_HOME not set / no java – SQLcl smoke test will fail"
mkdir -p "$PROD" 2>/dev/null

# =============================================================================
# 1. Rollback (--rollback --apply)
# =============================================================================
if $ROLLBACK; then
    section "Rollback"
    for _t in "Instant Client|$IC_LINK|_ic_smoke" "SQLcl|$SQLCL_LINK|_sqlcl_smoke"; do
        IFS='|' read -r _n _l _s <<< "$_t"
        _cur="$(_current "$_l")"
        _prev="$(_versions "$_l" | grep -B1 -x "$_cur" | head -1)"
        if [ -z "$_cur" ] || [ -z "$_prev" ] || [ "$_prev" = "$_cur" ]; then
            info "$_n: no previous version (current ${_cur:-none})"
        elif $APPLY; then
            _switch "$_n" "$_l" "${_l}_${_prev}" "$_prev" "$_s"
        else
            info "$_n: would link back $_cur -> $_prev (--apply)"
        fi
    done
    printLine; print_summary; exit "$EXIT_CODE"
fi

# =============================================================================
# 2. Instant Client
# =============================================================================
section "Oracle Instant Client ${IC_VERSION:-?} (${IC_PACKAGES:-basic sqlplus tools})"
IC_DIR="${IC_LINK}_${IC_VERSION}"
info "$(printf "%-20s %s" "installed (link):" "$(_current "$IC_LINK" || true)")"
info "$(printf "%-20s %s" "configured:" "${IC_VERSION:-(IC_VERSION not set)}")"
if [ -z "${IC_VERSION:-}" ] || [ -z "${IC_URL_BASE:-}" ]; then
    fail "IC_VERSION / IC_URL_BASE not set in oracle_software_version.conf"
elif ! $APPLY; then
    for _p in ${IC_PACKAGES:-basic sqlplus tools}; do
        _f="$IC_STORE/$IC_VERSION/instantclient-${_p}-linux.x64-${IC_VERSION}.zip"
        [ -f "$_f" ] && ok "  storage: $(basename "$_f")" || info "  storage: $(basename "$_f") – downloaded by --apply"
    done
    [ -d "$IC_DIR" ] && ok "  installed: $IC_DIR" || info "  not installed: $IC_DIR – --apply"
else
    _ok=true
    for _p in ${IC_PACKAGES:-basic sqlplus tools}; do
        otn_get ic "$IC_URL_BASE/instantclient-${_p}-linux.x64-${IC_VERSION}.zip" "$IC_STORE" "" "$IC_VERSION" || _ok=false
    done
    if $_ok; then
        if [ -x "$IC_DIR/sqlplus" ]; then
            ok "already installed: $IC_DIR"
        else
            _tmp="$(mktemp -d "$PROD/.ic_XXXXXX")"
            for _p in ${IC_PACKAGES:-basic sqlplus tools}; do
                unzip -q -o "$IC_STORE/$IC_VERSION/instantclient-${_p}-linux.x64-${IC_VERSION}.zip" -x 'META-INF/*' -d "$_tmp" \
                    || { fail "unzip failed: $_p"; _ok=false; }
            done
            _src="$(ls -d "$_tmp"/instantclient_* 2>/dev/null | head -1)"
            if $_ok && [ -n "$_src" ]; then
                mv "$_src" "$IC_DIR" && ok "installed: $IC_DIR"
            else
                fail "Instant Client not installed (unzip result missing)"
            fi
            rm -rf -- "$_tmp"
        fi
        [ -x "$IC_DIR/sqlplus" ] && _switch "Instant Client" "$IC_LINK" "$IC_DIR" "$IC_VERSION" _ic_smoke
    fi
fi
_cleanup "Instant Client" "$IC_LINK" "$IC_LINK"

# =============================================================================
# 3. SQLcl
# =============================================================================
section "SQLcl (latest)"
info "$(printf "%-20s %s" "installed (link):" "$(_current "$SQLCL_LINK" || true)")"
if ! $APPLY; then
    _z="$(otn_newest_zip "$SQLCL_STORE" 'sqlcl-*.zip')"
    [ -n "$_z" ] && ok "  storage: ${_z#"$PATCH_STORAGE"/}" || info "  storage: none – downloaded by --apply ($SQLCL_ZIP_URL)"
else
    if otn_get sqlcl "${SQLCL_ZIP_URL:-}" "$SQLCL_STORE" "${SQLCL_SHA256:-}"; then
        SQLCL_VER="$(basename "$(dirname "$OTN_FILE")")"
        SQLCL_DIR="${SQLCL_LINK}_${SQLCL_VER}"
        if [ -x "$SQLCL_DIR/bin/sql" ]; then
            ok "already installed: $SQLCL_DIR"
        else
            _tmp="$(mktemp -d "$PROD/.sqlcl_XXXXXX")"
            if unzip -q -o "$OTN_FILE" -d "$_tmp" && [ -d "$_tmp/sqlcl" ]; then
                mv "$_tmp/sqlcl" "$SQLCL_DIR" && ok "installed: $SQLCL_DIR"
            else
                fail "SQLcl not installed (unzip failed)"
            fi
            rm -rf -- "$_tmp"
        fi
        [ -x "$SQLCL_DIR/bin/sql" ] && _switch "SQLcl" "$SQLCL_LINK" "$SQLCL_DIR" "$SQLCL_VER" _sqlcl_smoke
    fi
fi
_cleanup "SQLcl" "$SQLCL_LINK" "$SQLCL_LINK"

# =============================================================================
# 4. environment.conf – link paths (one value, one source)
# =============================================================================
section "environment.conf"
_set_env() {   # _set_env KEY VALUE
    local k="$1" v="$2" cur
    cur="$(sed -n "s/^${k}=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$ENV_CONF" | tail -1)"
    if [ "$cur" = "$v" ]; then
        ok "$(printf "%-20s %s" "$k" "$v")"
    elif ! $APPLY; then
        info "$(printf "%-20s %s  (would be set, now: %s)" "$k" "$v" "${cur:-unset}")"
    else
        if grep -q "^${k}=" "$ENV_CONF"; then
            sed -i --follow-symlinks "s|^${k}=.*|${k}=\"${v}\"|" "$ENV_CONF"
        else
            printf '%s="%s"\n' "$k" "$v" >> "$(readlink -f "$ENV_CONF")"
        fi
        ok "$(printf "%-20s %s  (written)" "$k" "$v")"
    fi
}
if $APPLY; then backup_file "$ENV_CONF" > /dev/null; fi
_set_env INSTANT_CLIENT_HOME "$IC_LINK"
_set_env SQLPLUS_BIN         "$IC_LINK/sqlplus"
_set_env SQLCL_HOME          "$SQLCL_LINK"
_set_env SQLCL_BIN           "$SQLCL_LINK/bin/sql"

printLine
print_summary
exit "$EXIT_CODE"
