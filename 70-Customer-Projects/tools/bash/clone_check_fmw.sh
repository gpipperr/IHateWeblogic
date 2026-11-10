#!/bin/bash
# =============================================================================
# Script   : clone_check_fmw.sh
# Purpose  : Is this Forms / Reports installation clone-capable (golden image,
#            easy to move)? Standalone version of 02-Checks/clone_check.sh for
#            customer hosts (12.2.1.x and 14.1.2) – no IHateWeblogic library,
#            no environment.conf. READ-ONLY: changes nothing, prints the WLST /
#            file changes that would make it clone-capable.
#            Target: everything internal on 127.0.0.1, only the web tier
#            (OHS / Apache / Nginx) and the certificate carry the host name.
#              1. listening sockets of WebLogic, Node Manager, Forms, Reports,
#                 OHS by bind address (loopback / all interfaces / host IP)
#              2. WebLogic: listen addresses, SSL listen ports, Coherence
#                 unicast address, Node Manager
#              3. Reports: ORB on 127.0.0.1 (reports.sh / setUserOverrides.sh),
#                 discovery port
#              4. host name / IP in the domain configuration (JDBC, OPSS …)
#                 and in $DOMAIN_HOME/bin/*.sh, ADMIN_URL of the scripts and the
#                 shell not on localhost, AdminURL of servers/*/data/nodemanager/
#                 startup.properties, RCU repository local or external
#              5. machine identity (domain key, wallets, WLST key files)
#              6. host-specific places by design (web tier, certificate,
#                 tnsnames.ora)
# Call     : ./clone_check_fmw.sh [-o ORACLE_HOME] [-d DOMAIN_HOME] [-t OUTDIR] [--config]
#              -o / -d  default: environment, running WebLogic,
#                       domain-registry.xml, /oracle/product/mw, /u01/app/oracle/fmw …
#              -t       directory of the log file (default /tmp)
#              --config under each finding: the configuration file (full path)
#                       and its lines (line number) with the host name / IP or
#                       the setting to change; {AES} values / passwords masked
# Runs as  : the software owner (oracle); as root the socket owners are shown
# Output   : stdout + <OUTDIR>/clone_check_<host>_<yyyymmdd_hhmmss>.log
# Exit     : 0 = clone-capable, 1 = items to fix first, 2 = error
# Doc      : 70-Customer-Projects/tools/README.md,
#            80-FMW-Architecture/clone_golden_image.md (recipe §6)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================
set -u
VERSION="2026-11-10.4"   # bump on every change

OH="${ORACLE_HOME:-}"; DH="${DOMAIN_HOME:-}"; OUTBASE="/tmp"; SHOWCFG=false
while [ $# -gt 0 ]; do
    case "$1" in
        -o) OH="${2:-}"; shift ;;
        -d) DH="${2:-}"; shift ;;
        -t) OUTBASE="${2:-/tmp}"; shift ;;
        --config) SHOWCFG=true ;;
        -h|--help) sed -n '2,38p' "$0"; printf 'Version: %s\n' "$VERSION"; exit 0 ;;
        -V|--version) printf '%s\n' "$VERSION"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

H_FQDN="$(hostname -f 2>/dev/null)"; H_SHORT="$(hostname -s 2>/dev/null)"
H_IPS="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -vE '^(127\.|::1|$)')"
LOG="$OUTBASE/clone_check_${H_SHORT:-host}_$(date +%Y%m%d_%H%M%S).log"
: > "$LOG" 2>/dev/null || LOG=/dev/null
FIXES=0; STEPS=0

# --- output helpers (stdout + log) ----------------------------------------------
_p()   { printf '%s\n' "$*" | tee -a "$LOG"; }
ok()   { printf '\033[32m  OK  \033[0m %s\n' "$*"; printf '  OK   %s\n' "$*" >> "$LOG"; }
fix()  { FIXES=$((FIXES + 1)); printf '\033[33m FIX  \033[0m %s\n' "$*"; printf ' FIX   %s\n' "$*" >> "$LOG"; }
step() { STEPS=$((STEPS + 1)); printf '\033[36m STEP \033[0m %s\n' "$*"; printf ' STEP  %s\n' "$*" >> "$LOG"; }
info() { printf '       %s\n' "$*" | tee -a "$LOG"; }
section() { _p ""; _p "=== $* ==="; }
# --config: _cfg FILE [ERE [NOTE]] - full path + matching lines "nnn: text" (max 8, masked);
# without ERE only the file; NOTE is printed when no line matches (setting missing).
# _cfgline FILE LINE - one line by number. Both do nothing without --config.
_cfgline() {
    $SHOWCFG || return 0
    info "    -> $1"
    [ -n "${2:-}" ] && info "       $2: $(sed -n "${2}p" "$1" | sed 's/^[[:space:]]*//' | cut -c1-200)"
    return 0
}
_cfg() {
    $SHOWCFG || return 0
    local f="$1" re="${2:-}" note="${3:-}" n
    [ -n "$f" ] || return 0
    if [ ! -r "$f" ]; then info "    -> $f (not readable)"; return 0; fi
    info "    -> $f"
    [ -n "$re" ] || return 0
    n="$(grep -cE "$re" "$f" 2>/dev/null)"
    [ "${n:-0}" -eq 0 ] && [ -n "$note" ] && info "       (no such line: $note)"
    grep -nE "$re" "$f" 2>/dev/null | head -8 \
        | sed -E 's/\{AES[^}<"]*\}[^<" ]*/{AES}***/g
                 s/<([A-Za-z_.-]*(password|passwd|pwd)[A-Za-z_.-]*)>[^<]*/<\1>***/Ig
                 s/((password|passwd|pwd)[A-Za-z_.-]*[[:space:]]*[=:][[:space:]]*"?)[^"<[:space:]]+/\1***/Ig' \
        | cut -c1-200 | while IFS= read -r _l; do info "       ${_l%%:*}: $(printf '%s' "${_l#*:}" | sed 's/^[[:space:]]*//')"; done
    [ "${n:-0}" -gt 8 ] && info "       … $((n - 8)) more line(s)"
    return 0
}

# --- locate ORACLE_HOME / DOMAIN_HOME (same order as collect_fmw_env.sh) --------
if [ -z "$OH" ] || [ ! -d "$OH/OPatch" ]; then
    OH="$(ps -eo args= 2>/dev/null | sed -n 's/.*-Dweblogic\.home=\([^ ]*\)\/wlserver\/server.*/\1/p' | head -1)"
    if [ ! -d "${OH:-/x}/OPatch" ]; then
        OH=""
        for c in /oracle/product/mw /u01/app/oracle/fmw /u01/oracle/fmw \
                 /u01/app/oracle/middleware /u01/oracle/middleware; do
            [ -d "$c/OPatch" ] && { OH="$c"; break; }
        done
    fi
fi
if [ -z "$DH" ] && [ -r "${OH:-/x}/domain-registry.xml" ]; then
    DH="$(sed -n 's/.*location="\([^"]*\)".*/\1/p' "$OH/domain-registry.xml" | head -1)"
fi
[ -z "$DH" ] && DH="$(ps -eo args= 2>/dev/null | sed -n 's/.*-Dweblogic\.RootDirectory=\([^ ]*\).*/\1/p' | head -1)"
CONFIG_XML="$DH/config/config.xml"
if [ ! -f "$CONFIG_XML" ]; then
    printf 'DOMAIN_HOME not found (no config/config.xml: %s) – use -d\n' "${DH:-?}" >&2; exit 2
fi
PY=""
for _c in python3 /usr/libexec/platform-python python; do
    command -v "$_c" > /dev/null 2>&1 && { PY="$(command -v "$_c")"; break; }
done

_p "clone_check_fmw.sh $VERSION – $(date '+%Y-%m-%d %H:%M:%S') – read-only"
_p "Host       : ${H_FQDN:-?} (${H_SHORT:-?})  IPs: $(printf '%s ' $H_IPS)"
_p "ORACLE_HOME: ${OH:-(not found)}"
_p "DOMAIN_HOME: $DH"
_p "Log        : $LOG"

# server|listen-address|ssl-enabled|coherence-unicast|cluster from config.xml
SRV_INFO=""
if [ -n "$PY" ]; then
    SRV_INFO="$("$PY" - "$CONFIG_XML" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
ns = {'d': 'http://xmlns.oracle.com/weblogic/domain'}
root = ET.parse(sys.argv[1]).getroot()
for s in root.findall('d:server', ns):
    name = s.findtext('d:name', '', ns)
    la = s.findtext('d:listen-address', '', ns) or ''
    ssl = s.find('d:ssl', ns)
    en = 'false'
    if ssl is not None:
        en = (ssl.findtext('d:enabled', 'false', ns) or 'false').lower()
    cm = s.find('d:coherence-member-config', ns)
    ua = (cm.findtext('d:unicast-listen-address', '', ns) or '') if cm is not None else ''
    cl = s.findtext('d:cluster', '', ns) or ''
    print('%s|%s|%s|%s|%s' % (name, la, en, ua, cl))
PYEOF
)"
fi
COH_PORT="$(sed -n 's:.*<cluster-listen-port>\([0-9]*\)<.*:\1:p' "$DH"/config/coherence/*/*.xml 2>/dev/null | head -1)"
COH_PORT="${COH_PORT:-7574}"
RWNET="$(find "$DH/config/fmwconfig/components" -name rwnetwork.conf 2>/dev/null | head -1)"
DISC_PORT="$(sed -n 's/.*port="\([0-9]*\)".*/\1/p' "${RWNET:-/x}" 2>/dev/null | head -1)"
DISC_PORT="${DISC_PORT:-14021}"

# =============================================================================
section "1. Listening sockets (non-loopback)"
# =============================================================================
[ "$(id -u)" -ne 0 ] && info "(as $(id -un): process names only for own sockets – run as root to see all)"
_frm=0
while read -r _proto _local _proc; do
    _addr="${_local%:*}"; _port="${_local##*:}"
    case "$_addr" in 127.*|\[::1\]|\[::ffff:127.*) continue ;; esac
    _name="$(printf '%s' "$_proc" | sed -n 's/.*(("\([^"]*\)",pid=\([0-9]*\).*/\1 \2/p')"
    _pid="${_name#* }"; _cmd=""
    [ -r "/proc/$_pid/cmdline" ] && _cmd="$(tr '\0' ' ' < "/proc/$_pid/cmdline")"
    _who="$(printf '%s' "$_cmd" | grep -oE 'weblogic.Name=[A-Za-z0-9_]+|oracle.reports.component=[A-Za-z0-9_-]+|NodeManager' | head -1)"
    _who="${_who#*=}"; _who="${_who:-${_name%% *}}"
    case "${_name%% *}" in
        frmweb) _frm=$((_frm + 1)); continue ;;
        httpd|nginx)
            info "$(printf '%-5s %-24s %-14s web tier – the entry by design (host name + certificate)' "$_proto" "$_local" "$_who")"; continue ;;
    esac
    if [ "$_port" = "$DISC_PORT" ]; then
        info "$(printf '%-5s %-24s %-14s Reports multicast discovery (section 3)' "$_proto" "$_local" "$_who")"; continue
    fi
    if [ "${_name%% *}" = "java" ] && printf '%s\n' "$SRV_INFO" | grep -qE "^${_who}\|[^|]*\|[^|]*\|(127\.0\.0\.1|localhost)\|" \
       && { [ "$_port" = "$COH_PORT" ] || printf '%s\n' $H_IPS | grep -qxF "${_addr//[\[\]]/}"; }; then
        info "$(printf '%-5s %-24s %-14s Coherence remainder (member traffic on loopback) – firewall' "$_proto" "$_local" "$_who")"; continue
    fi
    if printf '%s\n' $H_IPS | grep -qxF "${_addr//[\[\]]/}"; then
        fix "$(printf '%-5s %-24s %-14s bound to the host IP' "$_proto" "$_local" "$_who")"
    else
        fix "$(printf '%-5s %-24s %-14s all interfaces' "$_proto" "$_local" "$_who")"
    fi
done < <(ss -Hltnpu 2>/dev/null | awk '/java|frmweb|rwserver|httpd|nginx/ { print $1, $5, $7 }')
[ "$_frm" -gt 0 ] && info "frmweb: $_frm socket(s) on all interfaces – not configurable (no Oracle option), no host name inside; firewall"

# =============================================================================
section "2. WebLogic (config.xml, Node Manager)"
# =============================================================================
NEED_WLST=""
if [ -z "$PY" ]; then
    fix "no python – config.xml not parsed (listen address / SSL / Coherence unknown)"
fi
while IFS='|' read -r _s _la _ssl _ua _cl; do
    [ -z "$_s" ] && continue
    case "$_la" in
        localhost|127.0.0.1) ok "$(printf '%-14s listen %s' "$_s" "$_la")" ;;
        "") fix "$(printf '%-14s listen address empty = all interfaces' "$_s")"
            # the <name> line of the <server> block - <listen-address> belongs below it
            _cfgline "$CONFIG_XML" "$(awk -v n="<name>${_s}</name>" 'p ~ /<server>/ && index($0, n) {print NR; exit} /[^[:space:]]/ {p=$0}' "$CONFIG_XML")"
            $SHOWCFG && info "       (no <listen-address> in this <server> block - WLST: cd('/Servers/${_s}'); set('ListenAddress','127.0.0.1'))" ;;
        *)  fix "$(printf '%-14s listen %s (not loopback)' "$_s" "$_la")"
            _cfg "$CONFIG_XML" "<listen-address>${_la//./\\.}</listen-address>" ;;
    esac
    if [ "$_ssl" = "true" ]; then
        fix "$(printf '%-14s SSL listen port enabled (demo certificate unless replaced)' "$_s")"
        NEED_WLST="$NEED_WLST $_s:ssl"
    else
        ok "$(printf '%-14s SSL listen port off' "$_s")"
    fi
    if [ -n "$_cl" ]; then
        case "$_ua" in
            127.0.0.1|localhost) ok "$(printf '%-14s Coherence unicast %s' "$_s" "$_ua")" ;;
            *) fix "$(printf '%-14s Coherence unicast %s – member traffic on the host IP, clones can join' "$_s" "${_ua:-(auto = host IP)}")"
               _cfg "$CONFIG_XML" "unicast-listen-address" "no <unicast-listen-address> = automatic (host IP) - WLST under Result"
               NEED_WLST="$NEED_WLST $_s:coh" ;;
        esac
    fi
done <<< "$SRV_INFO"
_nm="$DH/nodemanager/nodemanager.properties"
if [ -f "$_nm" ]; then
    _nla="$(sed -n 's/^ListenAddress=//p' "$_nm" | tail -1)"
    case "$_nla" in
        localhost|127.0.0.1) ok "$(printf '%-14s listen %s' NodeManager "$_nla")" ;;
        *) fix "$(printf '%-14s listen %s – ListenAddress=localhost in nodemanager.properties + machine address in config.xml' NodeManager "${_nla:-(all)}")"
           _cfg "$_nm" '^ListenAddress='; _cfg "$CONFIG_XML" '<listen-address>|<node-manager>' ;;
    esac
fi

# =============================================================================
section "3. Reports (ORB, discovery)"
# =============================================================================
_rsh="$DH/reports/bin/reports.sh"
if [ -f "$_rsh" ]; then
    if grep -q 'ORBServerHost=127.0.0.1' "$_rsh" 2>/dev/null; then
        ok "reports.sh: ORB of Reports server + engines on 127.0.0.1 (ORBServerHost)"
    else
        fix "reports.sh: no -Dcom.sun.corba.ee.ORBServerHost=127.0.0.1 in REPORTS_JVM_OPTIONS – server / engines on all interfaces"
        _cfg "$_rsh" 'REPORTS_JVM_OPTIONS' "no REPORTS_JVM_OPTIONS - add -DORBWaitForResponseTimeout=999999999 -Dcom.sun.corba.ee.ORBServerHost=127.0.0.1 there"
    fi
    # Oracle (Utility.getOrbProperties): REPORTS_JVM_OPTIONS set without
    # -DORBWaitForResponseTimeout= -> NullPointerException, REP-50125 at the start
    if grep -qE '^[[:space:]]*(export[[:space:]]+)?REPORTS_JVM_OPTIONS=' "$_rsh" 2>/dev/null \
       && ! grep -E '^[[:space:]]*(export[[:space:]]+)?REPORTS_JVM_OPTIONS=' "$_rsh" | tail -1 | grep -q 'ORBWaitForResponseTimeout='; then
        fix "reports.sh: REPORTS_JVM_OPTIONS without -DORBWaitForResponseTimeout=999999999 – the Reports server stops at the start (REP-50125 NullPointerException in getOrbProperties)"
        _cfg "$_rsh" 'REPORTS_JVM_OPTIONS' "add -DORBWaitForResponseTimeout=999999999 to the last REPORTS_JVM_OPTIONS line"
    fi
    if grep -q 'ORBServerHost=127.0.0.1' "$DH/bin/setUserOverrides.sh" 2>/dev/null; then
        ok "setUserOverrides.sh: rwservlet ORB (WLS_REPORTS) on 127.0.0.1"
    else
        fix "setUserOverrides.sh: rwservlet ORB (WLS_REPORTS) on all interfaces – -Dcom.sun.corba.ee.ORBServerHost=127.0.0.1 for WLS_REPORTS"
        _cfg "$DH/bin/setUserOverrides.sh" 'WLS_REPORTS|ORBServerHost' "no WLS_REPORTS block - JAVA_OPTIONS for SERVER_NAME=WLS_REPORTS with -Dcom.sun.corba.ee.ORBServerHost=127.0.0.1"
    fi
    _rs="$(find "$DH/config/fmwconfig/components/ReportsServerComponent" -mindepth 1 -maxdepth 1 -type d ! -name mbeans -printf '%f ' 2>/dev/null)"
    step "discovery: multicast port $DISC_PORT, server(s) ${_rs:-none} – a clone in the same subnet needs its own port (14021-14030, all rwnetwork.conf) or name"
    _cfg "$RWNET" '<multicast'
else
    info "no \$DOMAIN_HOME/reports/bin/reports.sh – Reports not configured in this domain"
fi

# =============================================================================
section "4. Host name / IP in \$DOMAIN_HOME/config and bin"
# =============================================================================
_pat="$(printf '%s\n' "$H_FQDN" "$H_SHORT" $H_IPS | grep -v '^$' | sed 's/\./\\./g' | paste -sd'|')"
if [ -n "$_pat" ]; then
    _hre="(^|[^A-Za-z0-9.-])(${_pat})([^A-Za-z0-9-]|$)"
    _hits="$(grep -rlIE "$_hre" "$DH/config" "$DH/init-info" "$DH"/bin/*.sh 2>/dev/null \
        | grep -vE '\.bak|/logs?/|\.log|/tmp/' | sort)"
    if [ -z "$_hits" ]; then
        ok "no own host name / IP"
    else
        while read -r _f; do
            _rel="${_f#"$DH"/}"
            case "$_rel" in
                config/jdbc/*|config/fmwconfig/jps-config*.xml)
                    step "$(printf '%-50s DB host = this host – keep only if the DB moves along, else localhost / alias' "$_rel")" ;;
                config/fmwconfig/components/OHS/*)
                    step "$(printf '%-50s OHS (web tier) – ServerName / Listen of the clone' "$_rel")" ;;
                bin/*)
                    fix "$(printf '%-50s host name in a domain script (e.g. ADMIN_URL) – on a clone it addresses the SOURCE AdminServer – localhost' "$_rel")" ;;
                init-info/*|*uifont.ali)
                    info "$(printf '%-50s informational (not read at runtime / comment)' "$_rel")" ;;
                *)  fix "$(printf '%-50s host name / IP – check' "$_rel")" ;;
            esac
            # show where: line number + text (max 3 lines, 110 chars)
            grep -nE "$_hre" "$_f" 2>/dev/null | head -3 | cut -c1-110 \
                | while IFS= read -r _hl; do info "$(printf '         %s' "$_hl")"; done
            _cfg "$_f" "$_hre"
        done <<< "$_hits"
    fi
fi
# AdminServer address of the domain scripts and of the shell: a FOREIGN host
# (e.g. the source after a clone) makes stopWebLogic.sh stop the source
# AdminServer when the network is open. Own host name: reported above.
_are='^[[:space:]]*(export[[:space:]]+)?ADMIN_URL=["'"'"']?[a-z0-9]+://'
_au="$(grep -HnE "$_are" "$DH"/bin/*.sh 2>/dev/null \
    | grep -vE '://(localhost|127\.0\.0\.1)[:/"'"'"']' | grep -vE "://(${_pat:-^\$})[:/\"']")"
if [ -n "$_au" ]; then
    while IFS= read -r _l; do
        _f="${_l%%:*}"; _r="${_l#*:}"; _n="${_r%%:*}"
        fix "$(printf '%-50s %s – foreign AdminServer address, a clone addresses the source – localhost' "${_f#"$DH"/}:$_n" "$(printf '%s' "${_r#*:}" | sed 's/^[[:space:]]*//' | cut -c1-60)")"
        _cfg "$_f" "$_are"
    done <<< "$_au"
fi
if [ -n "${ADMIN_URL:-}" ] && ! printf '%s' "$ADMIN_URL" | grep -qE '://(localhost|127\.0\.0\.1)([:/]|$)'; then
    fix "$(printf '%-50s %s – stopWebLogic.sh uses it – set t3://localhost:<port> in the profile or unset' "shell: ADMIN_URL" "$ADMIN_URL")"
fi
# AdminURL the Node Manager passes on a DIRECT start (autostart, nmStart without
# AdminServer): servers/<ms>/data/nodemanager/startup.properties keeps the
# address of the last start via the AdminServer. Host name / IP there while the
# AdminServer listens on 127.0.0.1 = "Managed Server independence mode", EM
# shows the server shut down (live 2026-11-10, BEA-149505 only).
for _sp in "$DH"/servers/*/data/nodemanager/startup.properties; do
    [ -f "$_sp" ] || continue
    _su="$(sed -n 's/^AdminURL=//p' "$_sp" | sed 's/\\//g' | head -1)"
    [ -z "$_su" ] && continue
    printf '%s' "$_su" | grep -qE '://(localhost|127\.0\.0\.1)([:/]|$)' && continue
    fix "$(printf '%-50s AdminURL=%s – Node Manager start without AdminServer: MSI mode (EM: down) / on a clone the source – http://localhost:<port>' "${_sp#"$DH"/}" "$_su")"
    _cfg "$_sp" '^AdminURL='
done
_ds="$DH/config/jdbc/WLSSchemaDataSource-jdbc.xml"
[ -f "$_ds" ] || _ds="$(ls "$DH"/config/jdbc/*opss*-jdbc.xml 2>/dev/null | head -1)"
if [ -f "${_ds:-/x}" ]; then
    _dburl="$(sed -n 's:.*<url>\([^<]*\)</url>.*:\1:p' "$_ds" | head -1)"
    # descriptor (RCU writes (host=..) in lower case) first, then @//host:port/service
    _dbh="$(printf '%s' "$_dburl" | sed -n 's|.*(HOST *= *\([^)]*\)).*|\1|Ip; s|.*@/*\([^:/(]*\):.*|\1|p' | head -1)"
    _pfx="$(grep -A1 '<name>user</name>' "$_ds" | sed -n 's:.*<value>\([A-Za-z0-9]*\)_[A-Z_]*</value>.*:\1:p' | head -1)"
    if [ "$_dbh" = "localhost" ] || [ "${_dbh%%.*}" = "$H_SHORT" ] || printf '%s\n' $H_IPS 127.0.0.1 | grep -qxF "$_dbh"; then
        ok "RCU repository on this host ($_dbh, prefix ${_pfx:-?}) – cloned along with the DB"
    else
        step "RCU repository EXTERNAL (${_dbh:-?}, prefix ${_pfx:-?}) – a clone needs its own prefix / repository; never start it against the source repository (two domains in one OPSS store)"
        _cfg "$_ds" '<url>'
    fi
fi

# =============================================================================
section "5. Machine identity"
# =============================================================================
[ -f "$DH/security/SerializedSystemIni.dat" ] && \
    info "domain key security/SerializedSystemIni.dat: travels with the clone – every clone can decrypt the same {AES} values (boot.properties, JDBC, NM cache)"
_wl="$(ls ~/*-WebLogicConfig.properties 2>/dev/null | tr '\n' ' ')"
[ -n "$_wl" ] && step "stored WLST credentials ($_wl) – valid only while the passwords stay the same"
info "/etc/machine-id, ssh host keys, /etc/hosts, oraInst.loc: OS clone tooling (virt-sysprep / cloud-init)"

# =============================================================================
section "6. Host-specific by design (change after a clone)"
# =============================================================================
for _c in "$DH"/config/fmwconfig/components/OHS/*/httpd.conf; do
    [ -f "$_c" ] || continue
    _i="$(basename "$(dirname "$_c")")"
    step "$(printf 'OHS %-10s ServerName %s, Listen %s' "$_i" "$(sed -n 's/^ServerName *//p' "$_c" | head -1)" "$(sed -n 's/^Listen *//p' "$_c" | paste -sd' ')")"
    _cfg "$_c" '^(ServerName|Listen)[[:space:]]'
done
for _c in /etc/nginx/conf.d/*.conf /etc/httpd/conf.d/*.conf /etc/httpd/conf/httpd.conf; do
    [ -r "$_c" ] || continue
    _sn="$(grep -hE '^\s*(server_name|ServerName)\s' "$_c" | awk '{print $2}' | tr -d ';' | sort -u | paste -sd' ')"
    [ -n "$_sn" ] && { step "$(printf '%-40s server name %s + TLS certificate (CN/SAN)' "$_c" "$_sn")"
                       _cfg "$_c" '^[[:space:]]*(server_name|ServerName|ssl_certificate|SSLCertificateFile)[[:space:]]'; }
done
_tns="${TNS_ADMIN:-}"
[ -z "$_tns" ] && _tns="$(grep -h '^TNS_ADMIN=' "$DH"/config/fmwconfig/servers/*/applications/*/config/default.env 2>/dev/null | head -1 | cut -d= -f2)"
for _t in "$_tns/tnsnames.ora" "$DH/config/fmwconfig/tnsnames.ora"; do
    [ -f "$_t" ] || continue
    step "$(printf 'tnsnames.ora %-34s HOST %s' "$_t" "$(grep -oiE 'HOST *= *[^)]+' "$_t" | sed 's/.*= *//' | sort -u | paste -sd' ')")"
    _cfg "$_t" '[Hh][Oo][Ss][Tt][[:space:]]*='
    break
done

# =============================================================================
section "Result"
# =============================================================================
if [ -n "$NEED_WLST" ]; then
    info "WLST online to switch off SSL / put Coherence on 127.0.0.1 (AdminServer running,"
    info "then restart the managed servers) – nothing was changed by this script:"
    info "  connect('<admin>', '<password>', 't3://localhost:<admin port>'); edit(); startEdit()"
    for _e in $NEED_WLST; do
        case "$_e" in
            *:ssl) info "  cd('/Servers/${_e%:*}/SSL/${_e%:*}'); set('Enabled','false')" ;;
            *:coh) info "  cd('/Servers/${_e%:*}/CoherenceMemberConfig/${_e%:*}'); set('UnicastListenAddress','127.0.0.1')" ;;
        esac
    done
    info "  save(); activate(block='true')"
fi
if [ "$FIXES" -eq 0 ]; then
    ok "Clone-capable: yes – $STEPS step(s) after cloning (STEP above)"; RC=0
else
    _p "Clone-capable: NOT YET – $FIXES item(s) to fix first (FIX), then $STEPS step(s) after cloning (STEP)"; RC=1
fi
_p "Recipe: 80-FMW-Architecture/clone_golden_image.md §6 – log: $LOG"
exit "$RC"
