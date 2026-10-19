#!/bin/bash
# =============================================================================
# Script   : forms_lib.sh  (sourced, not executed)
# Purpose  : One place that knows how to find and read the Oracle Forms
#            configuration and runtime processes of an FMW 14.1.2 domain –
#            used by the 06-FormsDiag scripts (and later 14- / 15-).
#
# Verified live 2026-10-19 (test host):
#   - formsweb.cfg / default.env of the deployed application:
#     config/fmwconfig/servers/<WLS_FORMS>/applications/formsapp_<ver>/config/
#     (default.env = envFile of [default], relative to that directory)
#   - formsweb.cfg: [default] + named sections; a section inherits every key
#     it does not set itself from [default] (Oracle: "you need only specify
#     the parameters you want to change")
#   - Forms runtime = native process $ORACLE_HOME/bin/frmweb, one per session
#     (and per prestarted runtime), child of the WLS_FORMS JVM, command line
#     "frmweb webfile=HTTP-0,<config section>"
#   - WLS session-timeout of the Forms servlet: WEB-INF/weblogic.xml in
#     $ORACLE_HOME/forms/j2ee/formsapp.ear (timeout-secs 7200)
#
# Usage    : source "$ROOT_DIR/06-FormsDiag/forms_lib.sh"
#            frm_wls_server                 -> WLS managed server name
#            frm_wls_pid SERVER             -> PID of the WLS_FORMS JVM
#            frm_find_files [cfg]           -> sets FRM_CONFIG_DIR, FRM_CFG, FRM_ENV
#            frm_sections FILE              -> section names (default first)
#            frm_cfg_get FILE SECTION KEY   -> effective value (section, else [default])
#            frm_cfg_where FILE SECTION KEY -> section that sets the key (or empty)
#            frm_cfg_set FILE SECTION KEY VALUE / frm_cfg_unset FILE SECTION KEY
#            frm_env_get FILE KEY           -> value of KEY=... in default.env
#            frm_frmweb_list [WLS_PID]      -> lines: pid<TAB>section<TAB>rss_mb<TAB>etime
#            frm_session_timeout_min        -> WLS session timeout of the Forms servlet
# Keys are compared case-insensitively (heartBeat = heartbeat).
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

# frm_wls_server – WLS_FORMS_SERVER > running JVM with "forms" in its name > WLS_FORMS
frm_wls_server() {
    local found
    [ -n "${WLS_FORMS_SERVER:-}" ] && { printf "%s" "$WLS_FORMS_SERVER"; return; }
    found="$(pgrep -a -f 'weblogic.Name=' 2>/dev/null \
        | sed -n 's/.*-Dweblogic\.Name=\([^ ]*\).*/\1/p' | grep -i 'forms' | head -1)"
    printf "%s" "${found:-WLS_FORMS}"
}

# frm_wls_pid SERVER
frm_wls_pid() { pgrep -f "weblogic.Name=${1}( |\$)" 2>/dev/null | head -1; }

# frm_find_files [formsweb.cfg] – sets FRM_CONFIG_DIR, FRM_CFG, FRM_ENV
frm_find_files() {
    local srv env_name
    FRM_CFG="${1:-}" FRM_ENV="" FRM_CONFIG_DIR=""
    if [ -z "$FRM_CFG" ]; then
        srv="$(frm_wls_server)"
        FRM_CFG="$(ls -d "$DOMAIN_HOME/config/fmwconfig/servers/$srv"/applications/formsapp_*/config/formsweb.cfg 2>/dev/null | tail -1)"
        [ -z "$FRM_CFG" ] && FRM_CFG="$(find "$DOMAIN_HOME/config/fmwconfig/servers" -maxdepth 6 -name formsweb.cfg 2>/dev/null | head -1)"
    fi
    [ -n "$FRM_CFG" ] && [ -f "$FRM_CFG" ] || { FRM_CFG=""; return 1; }
    FRM_CONFIG_DIR="$(dirname "$FRM_CFG")"
    env_name="$(frm_cfg_get "$FRM_CFG" default envFile)"
    case "${env_name:-default.env}" in
        /*) FRM_ENV="$env_name" ;;
        *)  FRM_ENV="$FRM_CONFIG_DIR/${env_name:-default.env}" ;;
    esac
    [ -f "$FRM_ENV" ] || FRM_ENV=""
    return 0
}

# frm_sections FILE – "default" first, then the named sections in file order
frm_sections() {
    awk '/^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            s=$0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", s); print s }' "$1" 2>/dev/null
}

# _frm_sec_val FILE SECTION KEY – value set directly in SECTION (empty + rc 1 if not)
_frm_sec_val() {
    awk -v sec="$2" -v key="$3" '
        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            s=$0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", s); cur=s; next }
        /^[[:space:]]*[#;]/ { next }
        cur == sec {
            i = index($0, "=")
            if (i > 0) {
                k = substr($0, 1, i-1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
                if (tolower(k) == tolower(key)) {
                    v = substr($0, i+1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                    val = v; found = 1
                }
            }
        }
        END { if (found) { print val; exit 0 } exit 1 }' "$1" 2>/dev/null
}

# frm_cfg_where FILE SECTION KEY – SECTION, "default" or empty
frm_cfg_where() {
    if [ "$2" != "default" ] && _frm_sec_val "$1" "$2" "$3" > /dev/null; then
        printf "%s" "$2"
    elif _frm_sec_val "$1" default "$3" > /dev/null; then
        printf "default"
    fi
}

# frm_cfg_get FILE SECTION KEY – effective value (inherited from [default])
frm_cfg_get() {
    local v
    if [ "$2" != "default" ] && v="$(_frm_sec_val "$1" "$2" "$3")"; then
        printf "%s" "$v"; return 0
    fi
    _frm_sec_val "$1" default "$3"
}

# frm_cfg_set FILE SECTION KEY VALUE – change the key inside SECTION, or add it
# at the end of SECTION. Comments, other sections, Oracle entries untouched.
# No backup here – the caller runs backup_file first.
frm_cfg_set() {
    python3 -I - "$@" << 'FRM_PY'
import re, sys
path, sec, key, val = sys.argv[1:5]
lines = open(path, encoding='iso-8859-1').read().split('\n')
hdr = re.compile(r'^\s*\[([^\]]+)\]\s*$')
cur, start, end, hit = None, None, None, None
for i, l in enumerate(lines):
    m = hdr.match(l)
    if m:
        if cur == sec and end is None:
            end = i
        cur = m.group(1)
        if cur == sec:
            start = i
        continue
    if cur == sec and not re.match(r'^\s*[#;]', l) and '=' in l:
        if l.split('=', 1)[0].strip().lower() == key.lower():
            hit = i
if start is None:
    sys.exit('section [%s] not found' % sec)
if end is None:
    end = len(lines)
if hit is not None:
    lines[hit] = '%s=%s' % (key, val)
else:
    ins = end
    while ins > start + 1 and lines[ins - 1].strip() == '':
        ins -= 1
    lines.insert(ins, '%s=%s' % (key, val))
open(path, 'w', encoding='iso-8859-1').write('\n'.join(lines))
FRM_PY
}

# frm_cfg_unset FILE SECTION KEY – remove the key from SECTION only
frm_cfg_unset() {
    python3 -I - "$@" << 'FRM_PY'
import re, sys
path, sec, key = sys.argv[1:4]
lines = open(path, encoding='iso-8859-1').read().split('\n')
hdr = re.compile(r'^\s*\[([^\]]+)\]\s*$')
cur, out = None, []
for l in lines:
    m = hdr.match(l)
    if m:
        cur = m.group(1)
    elif cur == sec and not re.match(r'^\s*[#;]', l) and '=' in l \
            and l.split('=', 1)[0].strip().lower() == key.lower():
        continue
    out.append(l)
open(path, 'w', encoding='iso-8859-1').write('\n'.join(out))
FRM_PY
}

# frm_env_get FILE KEY – KEY=value from default.env (last one wins)
frm_env_get() {
    grep -E "^[[:space:]]*${2}[[:space:]]*=" "$1" 2>/dev/null | tail -1 \
        | sed "s/^[[:space:]]*${2}[[:space:]]*=[[:space:]]*//; s/^[\"']//; s/[\"'][[:space:]]*\$//"
}

# frm_frmweb_list [WLS_PID] – one line per frmweb process:
#   pid<TAB>section<TAB>rss_mb<TAB>etime
# Only children of the WLS_FORMS JVM when its PID is given.
frm_frmweb_list() {
    local p sec rss et
    for p in $(pgrep -x frmweb 2>/dev/null); do
        if [ -n "${1:-}" ] && [ "$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')" != "$1" ]; then
            continue
        fi
        sec="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | sed -n 's/.*webfile=[^,]*,\([^ ]*\).*/\1/p')"
        rss="$(awk '/^VmRSS/ {print int($2/1024)}' "/proc/$p/status" 2>/dev/null)"
        et="$(ps -o etime= -p "$p" 2>/dev/null | tr -d ' ')"
        printf "%s\t%s\t%s\t%s\n" "$p" "${sec:-?}" "${rss:-0}" "${et:--}"
    done
}

# frm_session_timeout_min – timeout-secs of the Forms servlet (formsapp.ear
# WEB-INF/weblogic.xml) in minutes; empty if not readable
frm_session_timeout_min() {
    local ear="${ORACLE_HOME:-${FMW_HOME:-}}/forms/j2ee/formsapp.ear" secs tmp
    [ -f "$ear" ] && command -v unzip > /dev/null 2>&1 || return 1
    tmp="$(mktemp -d)"
    unzip -q -o "$ear" formsweb.war -d "$tmp" 2>/dev/null
    secs="$(unzip -p "$tmp/formsweb.war" WEB-INF/weblogic.xml 2>/dev/null \
        | sed -n 's/.*<timeout-secs>\([0-9]*\)<\/timeout-secs>.*/\1/p' | head -1)"
    rm -rf "$tmp"
    [ -n "$secs" ] && printf "%s" $(( secs / 60 ))
}
