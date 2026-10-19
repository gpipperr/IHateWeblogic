#!/bin/bash
# =============================================================================
# Script   : cve_inventory.sh
# Purpose  : CVE watch step 1 – what is really installed and at which patch
#            level, in one view (read-only, no changes):
#              1. Oracle Home components  -> advisory product names
#              2. Patch cycle: configured (oracle_software_version.conf) vs.
#                 installed (opatch lspatches), SPB level, OPatch version
#              3. Both JDKs (JDK_HOME and the FMW-bundled oracle_common/jdk)
#                 and which one the domain uses
#              4. Active use and exposure: running processes per product,
#                 which JDK each running JVM really uses, sockets of the
#                 oracle processes beyond loopback, firewall state
#              5. OS: release, kernel, Nginx/OpenSSL/glibc, security errata
#              6. --online: Oracle advisories (CPU/CSPU) released after the
#                 configured cycle -> not yet covered
#            Patch scope = everything on disk (a tool that is not running can
#            still be started and exploited); active use / exposure only
#            decides the urgency.
#            Writes inventory.json for the next CVE-watch steps (product
#            names, versions, patch numbers only – no host or customer data).
#
# Call     : ./10-Monitoring/cve_inventory.sh [--online] [--no-os] [--json FILE]
#              --online   also read https://www.oracle.com/security-alerts/
#              --no-os    skip the OS errata check (dnf can hang without repos)
#              --json F   JSON output file
#                         (default 10-Monitoring/reports/inventory_<date>.json)
# Exit     : 0 ok, 1 warnings (newer advisory, old JDK, optional patches),
#            2 configured patches missing
# Doc      : 10-Monitoring/README.md, section "CVE Watch"
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"

if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m Cannot find IHateWeblogic_lib.sh: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=../00-Setup/IHateWeblogic_lib.sh
source "$LIB"
check_env_conf "$ENV_CONF" || exit 2
# shellcheck source=../environment.conf
source "$ENV_CONF"

VERSION_CONF="$ROOT_DIR/09-Install/oracle_software_version.conf"
# shellcheck source=../09-Install/oracle_software_version.conf
[ -f "$VERSION_CONF" ] && source "$VERSION_CONF"

# =============================================================================
# Arguments
# =============================================================================
ONLINE=false
CHECK_OS=true
JSON_FILE="$SCRIPT_DIR/reports/inventory_$(date +%Y%m%d).json"

_usage() {
    sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --online) ONLINE=true ;;
        --no-os)  CHECK_OS=false ;;
        --json)   shift; JSON_FILE="${1:?--json needs a file name}" ;;
        --help|-h) _usage ;;
        *) printf "\033[31mERROR\033[0m Unknown option: %s\n" "$1" >&2; exit 2 ;;
    esac
    shift
done

LOG_FILE="$ROOT_DIR/log/$(date +%Y%m%d)/cve_inventory_$(date +%H%M%S).log"
mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
REC="$WORK_DIR/records.tsv"     # kind <TAB> key <TAB> value <TAB> extra – becomes JSON
: > "$REC"

# _rec kind key value [extra]
_rec() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$REC"; }

_version_lt() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ] && [ "$1" != "$2" ]
}

printLine
printf "\n\033[1m  IHateWeblogic – CVE inventory (installed components and patch level)\033[0m\n" \
    | tee -a "$LOG_FILE"
printf "  Oracle Home : %s\n" "$ORACLE_HOME" | tee -a "$LOG_FILE"
printf "  Log         : %s\n" "$LOG_FILE"    | tee -a "$LOG_FILE"
printLine

# =============================================================================
# 1. Oracle Home components
# =============================================================================
section "1. Oracle Home components (advisory product names)"

COMPS_XML="$ORACLE_HOME/inventory/ContentsXML/comps.xml"
FORMS_INSTALLED=false
REPORTS_INSTALLED=false
OHS_INSTALLED=false
WEBGATE_INSTALLED=false

# advisory product | comps.xml component | runtime check (used / configured)
_PRODUCTS=(
    "Oracle WebLogic Server|oracle.wls.core.app.server"
    "Oracle Fusion Middleware (JRF / Infrastructure)|oracle.opss.jrf"
    "Oracle Platform Security for Java|oracle.opss.core"
    "Oracle Coherence|oracle.coherence"
    "Oracle Forms|oracle.developer.forms.runtime"
    "Oracle Reports|oracle.reports.server"
    "Oracle HTTP Server|oracle.ohs2"
    "Oracle Access Manager WebGate|oracle.oamclient.webgate.ohs"
)

if [ ! -r "$COMPS_XML" ]; then
    fail "Inventory not readable: $COMPS_XML"
else
    for _p in "${_PRODUCTS[@]}"; do
        _prod="${_p%%|*}"; _comp="${_p##*|}"
        _ver="$(grep -oE "<COMP NAME=\"${_comp//./\\.}\" VER=\"[^\"]+\"" "$COMPS_XML" \
                | head -1 | sed 's/.*VER="\([^"]*\)"/\1/')"
        [ -z "$_ver" ] && continue
        _use=""
        case "$_comp" in
            oracle.developer.forms.runtime)
                FORMS_INSTALLED=true
                [ -d "$DOMAIN_HOME/config/fmwconfig/components/FORMS" ] \
                    && _use="configured in the domain" || _use="binaries only" ;;
            oracle.reports.server)
                REPORTS_INSTALLED=true
                [ -d "$DOMAIN_HOME/config/fmwconfig/components/ReportsServerComponent" ] \
                    && _use="configured in the domain" || _use="binaries only" ;;
            oracle.ohs2)
                OHS_INSTALLED=true
                [ -d "$DOMAIN_HOME/config/fmwconfig/components/OHS" ] \
                    && _use="configured in the domain" || _use="binaries only (no OHS instance)" ;;
            oracle.oamclient.webgate.ohs)
                WEBGATE_INSTALLED=true
                _use="binaries only (no OHS instance)"
                [ -d "$DOMAIN_HOME/config/fmwconfig/components/OHS" ] && _use="OHS instance present" ;;
        esac
        ok "$(printf "  %-46s %-12s %s" "$_prod" "$_ver" "$_use")"
        _rec product "$_prod" "$_ver" "$_use"
    done
    # libOVD has no own component entry – it lives in oracle_common
    _ovd="$ORACLE_HOME/oracle_common/modules/oracle.ovd/ovd.jar"
    if [ -f "$_ovd" ]; then
        _d="$(date -r "$_ovd" +%Y-%m-%d)"
        info "$(printf "  %-46s %-12s %s" "libOVD (oracle_common)" "$FMW_PRODUCT_RELEASE" "ovd.jar from $_d")"
        _rec product "libOVD" "${FMW_PRODUCT_RELEASE:-?}" "ovd.jar $_d"
    fi
fi

# =============================================================================
# 2. Patch cycle
# =============================================================================
section "2. Patch level: configured cycle vs. installed patches"

OPATCH="$ORACLE_HOME/OPatch/opatch"
LSPATCHES="$WORK_DIR/lspatches.txt"
"$OPATCH" lspatches -oh "$ORACLE_HOME" 2>/dev/null | grep -E '^[0-9]+;' > "$LSPATCHES"

printList "Configured cycle" 22 "${PATCH_CYCLE:-(PATCH_CYCLE not set in oracle_software_version.conf)}  ${PATCH_CYCLE_DATE:+released $PATCH_CYCLE_DATE}"
_rec cycle "configured" "${PATCH_CYCLE:-unknown}" "${PATCH_CYCLE_DATE:-}"

_opv="$("$OPATCH" version 2>/dev/null | awk '/OPatch Version/ {print $3}')"
if [ -z "$_opv" ]; then
    fail "OPatch version unknown ($OPATCH)"
elif [ -n "${OPATCH_VERSION_MIN:-}" ] && _version_lt "$_opv" "$OPATCH_VERSION_MIN"; then
    warn "$(printf "  %-22s %s (minimum %s)" "OPatch" "$_opv" "$OPATCH_VERSION_MIN")"
else
    ok "$(printf "  %-22s %s" "OPatch" "$_opv")"
fi
_rec opatch "version" "${_opv:-unknown}"

# SPB level from the description of the marker patch ("... 14.1.2.0.YYMMDD ...")
_spb_line="$(grep -E "STACK PATCH BUNDLE" "$LSPATCHES" | head -1)"
_spb_ver="$(printf '%s' "$_spb_line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]{6}' | head -1)"
if [ -n "$_spb_ver" ]; then
    _yymmdd="${_spb_ver##*.}"
    ok "$(printf "  %-22s %s  (built 20%s-%s-%s)" "WLS Stack Patch Bundle" "$_spb_ver" \
        "${_yymmdd:0:2}" "${_yymmdd:2:2}" "${_yymmdd:4:2}")"
    _rec spb "version" "$_spb_ver"
else
    warn "No WLS Stack Patch Bundle in the inventory (opatch lspatches)"
fi

# Expected patch set of the configured cycle
_expected=()
[ -n "${WLS_SPB_MARKER_PATCH:-}" ] && _expected+=("${WLS_SPB_MARKER_PATCH}:WLS SPB ${WLS_SPB_VERSION:-}")
for _p in ${INSTALL_PATCHES:-};           do _expected+=("$_p:INSTALL_PATCHES"); done
if $FORMS_INSTALLED || $REPORTS_INSTALLED; then
    for _p in ${INSTALL_PATCHES_FR_COMMON:-}; do _expected+=("$_p:Forms/Reports common"); done
fi
if $REPORTS_INSTALLED; then
    for _p in ${INSTALL_PATCHES_REPORTS:-}; do _expected+=("$_p:Reports QPR"); done
fi
if $FORMS_INSTALLED; then
    for _p in ${INSTALL_PATCHES_FORMS:-};   do _expected+=("$_p:Forms QPR"); done
fi

_missing=0
for _e in "${_expected[@]}"; do
    _nr="${_e%%:*}"; _what="${_e#*:}"
    if grep -q "^${_nr};" "$LSPATCHES"; then
        ok "$(printf "  %-10s %-26s installed" "$_nr" "$_what")"
        _rec patch "$_nr" "installed" "$_what"
    else
        fail "$(printf "  %-10s %-26s MISSING – configured for %s" "$_nr" "$_what" "${PATCH_CYCLE:-this cycle}")"
        _rec patch "$_nr" "missing" "$_what"
        _missing=$(( _missing + 1 ))
    fi
done
[ "$_missing" -gt 0 ] && info "  Apply: 07-Maintenance patch cycle (README section 3)"

# Everything else in the inventory (SPB content, one-offs)
info "Installed patches (opatch lspatches):"
while IFS=';' read -r _nr _desc; do
    printf "      %-10s %s\n" "$_nr" "$_desc" | tee -a "$LOG_FILE"
    _rec installed "$_nr" "$_desc"
done < "$LSPATCHES"

# Conditional patches: component in the home -> Oracle lists a patch for it
if $OHS_INSTALLED; then
    warn "Oracle HTTP Server binaries are in this Oracle Home (installed with Forms & Reports)"
    info "  Not used with the Nginx frontend, but on disk: OHS CVEs apply to the binaries."
    info "  KA1182 lists an OHS bundle patch per cycle – decide: apply it, or accept (document)."
fi
if $WEBGATE_INSTALLED; then
    warn "OAM WebGate binaries are in this Oracle Home (installed with Forms & Reports)"
    info "  Same decision as for OHS (WebGate bundle patch in KA1182)."
fi

# _role pid – what a process is (from its binary and command line).
# Only real processes of this user are looked at – never the command line of
# a calling shell that merely contains the search words.
_role() {
    local pid="$1" exe args
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null)"
    args="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    case "${exe##*/}" in
        java)
            case "$args" in
                *weblogic.NodeManager*) printf 'NodeManager' ;;
                *-Dweblogic.Name=*)     printf 'WLS %s' "$(printf '%s' "$args" | grep -oE -- '-Dweblogic.Name=[^ ]+' | cut -d= -f2)" ;;
                *rwrun.jar*)            printf 'Reports engine' ;;
                *derby*)                printf 'Derby (WLS sample DB)' ;;
                *)                      printf 'other java' ;;
            esac ;;
        frmweb)   printf 'Forms runtime (frmweb)' ;;
        rwserver) printf 'Reports server (rwserver)' ;;
        httpd)    [[ "$exe" == "$ORACLE_HOME"/* ]] && printf 'Oracle HTTP Server' || printf 'httpd (OS)' ;;
        tnslsnr|oracle) printf 'Oracle Database (not FMW)' ;;
        sshd*)    printf 'sshd (X11 forwarding)' ;;
        *)        case "$args" in ora_*) printf 'Oracle Database (not FMW)' ;; *) printf '%s' "${exe##*/}" ;; esac ;;
    esac
}

# Roles of all processes of this user (pid <TAB> role), computed once
ROLES="$WORK_DIR/roles.tsv"
for _pid in $(pgrep -u "$(id -u)"); do
    [ "$_pid" = "$$" ] || [ "$_pid" = "$BASHPID" ] && continue
    printf '%s\t%s\n' "$_pid" "$(_role "$_pid")"
done > "$ROLES"

# =============================================================================
# 3. JDKs
# =============================================================================
section "3. Java (both JDKs)"

_domain_java="$(grep -h '^JavaHome=' "$DOMAIN_HOME/nodemanager/nodemanager.properties" 2>/dev/null | cut -d= -f2)"
_domain_java="${_domain_java:-$(grep -h 'JAVA_HOME=' "$DOMAIN_HOME/bin/setDomainEnv.sh" 2>/dev/null | grep -oE '/[^"]+' | head -1)}"

for _pair in "JDK_HOME|${JDK_HOME:-}" "FMW-bundled|$ORACLE_HOME/oracle_common/jdk"; do
    _label="${_pair%%|*}"; _jh="${_pair#*|}"
    [ -x "$_jh/bin/java" ] || { info "$(printf "  %-12s %s – not present" "$_label" "$_jh")"; continue; }
    _props="$("$_jh/bin/java" -XshowSettings:properties -version 2>&1)"
    _jv="$(printf '%s\n' "$_props" | awk -F' = ' '/^ *java.version = / {print $2}')"
    _jd="$(printf '%s\n' "$_props" | awk -F' = ' '/^ *java.version.date = / {print $2}')"
    _vendor="$(printf '%s\n' "$_props" | awk -F' = ' '/^ *java.vendor = / {print $2}')"
    # really used = running JVMs whose binary lives in this JDK (not only config)
    _jreal="$(readlink -f "$_jh")"
    _users="$(while IFS=$'\t' read -r _pid _r; do
                  [[ "$(readlink -f "/proc/$_pid/exe" 2>/dev/null)" == "$_jreal"/* ]] && printf '%s\n' "$_r"
              done < "$ROLES" | sort | uniq -c \
              | awk '{c=$1; $1=""; sub(/^ /,""); printf "%s%s x%s", (n++?", ":""), $0, c}')"
    if [ -n "$_users" ]; then
        _used="RUNNING: $_users"
    else
        _used="no running JVM"
    fi
    [ -n "$_domain_java" ] && [ "$_jreal" = "$(readlink -f "$_domain_java")" ] && _used="$_used; domain JavaHome"
    _line="$(printf "  %-12s %-12s %s  %s  (%s)" "$_label" "$_jv" "$_jd" "$_vendor" "$_used")"
    _major="${_jv%%.*}"
    if [ -n "${JDK_VERSION_MIN:-}" ] && [ "$_major" = "${JDK_VERSION_MIN%%.*}" ] \
       && _version_lt "$_jv" "$JDK_VERSION_MIN"; then
        warn "$_line – below JDK_VERSION_MIN $JDK_VERSION_MIN"
    elif [ "$_major" != "${JDK_VERSION_MIN%%.*}" ] && [ -n "$_jd" ] \
         && [ "$(( ( $(date +%s) - $(date -d "$_jd" +%s 2>/dev/null || date +%s) ) / 86400 ))" -gt 365 ]; then
        warn "$_line – older than one year"
        [[ "$_used" == RUNNING* ]] && info "    in use – not covered by JDK_HOME updates (e.g. Reports: \$DOMAIN_HOME/reports/bin/reports.sh puts oracle_common/jdk first in PATH)"
    else
        ok "$_line"
    fi
    _rec java "$_label" "$_jv" "$_jd $_vendor, $_used"
done
info "  Domain JAVA_HOME: ${_domain_java:-unknown} (nodemanager.properties / setDomainEnv.sh)"

# =============================================================================
# 4. Active use and exposure
# =============================================================================
section "4. Active use and exposure (running = urgency, on disk = patch scope)"

_count() { awk -F'\t' -v r="$1" '$2 == r' "$ROLES" | grep -c .; }

_wls="$(awk -F'\t' '$2 ~ /^WLS / {sub(/^WLS /, "", $2); print $2}' "$ROLES" | sort -u | tr '\n' ' ')"
_act() {   # label  count  detail
    local l="$1" n="$2" d="$3"
    if [ "$n" -gt 0 ]; then
        ok "$(printf "  %-30s RUNNING  %3s  %s" "$l" "$n" "$d")"
        _rec active "$l" "running" "$n $d"
    else
        info "$(printf "  %-30s not running     %s" "$l" "$d")"
        _rec active "$l" "not running" "$d"
    fi
}
_act "WebLogic servers"          "$(printf '%s' "$_wls" | wc -w)" "$_wls"
_act "Node Manager"              "$(_count 'NodeManager')" ""
_act "Forms runtime (frmweb)"    "$(_count 'Forms runtime (frmweb)')" \
     "$(grep -h '^prestartRuntimes=true' "$DOMAIN_HOME"/config/fmwconfig/servers/*/applications/formsapp_*/config/formsweb.cfg >/dev/null 2>&1 && printf 'prestartRuntimes=true – processes started without users')"
_act "Reports server (rwserver)" "$(_count 'Reports server (rwserver)')" ""
_act "Reports engines (java)"    "$(_count 'Reports engine')" ""
_act "Oracle HTTP Server"        "$(_count 'Oracle HTTP Server')" "binaries in \$ORACLE_HOME/ohs"
_act "Nginx (frontend)"          "$(pgrep -x nginx 2>/dev/null | grep -c .)" "master + workers"

# Sockets of this user's processes: loopback vs. all interfaces / host address.
# Only the classification goes into the JSON – no addresses.
_sock="$WORK_DIR/sockets.txt"
ss -ltnpH 2>/dev/null | awk '{print $4, $6}' \
    | sed -nE 's/^(.*):([0-9]+) users:\(\("([^"]+)",pid=([0-9]+).*/\1 \2 \3 \4/p' > "$_sock"
_ext="$WORK_DIR/external.txt"
while read -r _addr _port _proc _pid; do
    [[ "$_addr" =~ ^(127\.|\[::1\]$|::1$) ]] && continue
    _r="$(awk -F'\t' -v p="$_pid" '$1 == p {print $2}' "$ROLES")"
    printf '%s\n' "${_r:-$_proc}"
done < "$_sock" | sort | uniq -c | sort -rn > "$_ext"

# Firewall first – it decides whether those sockets are reachable.
# systemctl works without root; firewall-cmd --state needs root (dbus policy).
_fw="unknown"; _fw_open=""
if systemctl list-unit-files firewalld.service > /dev/null 2>&1 \
   && systemctl cat firewalld.service > /dev/null 2>&1; then
    _fw="$(systemctl is-active firewalld 2>/dev/null)"
    if [ "$_fw" = "active" ]; then
        _fw_open="$(sudo -n firewall-cmd --list-services 2>/dev/null) $(sudo -n firewall-cmd --list-ports 2>/dev/null)"
        _fw_open="$(printf '%s' "$_fw_open" | xargs)"
    fi
    _rec firewall "firewalld" "$_fw" "$_fw_open"
elif command -v nft > /dev/null 2>&1 && sudo -n nft list ruleset 2>/dev/null | grep -q 'chain'; then
    _fw="nftables"
    _rec firewall "nftables" "ruleset present"
else
    _rec firewall "none" "not found"
fi

if [ "$_fw" = "active" ]; then
    ok "firewalld: active ($(systemctl is-enabled firewalld 2>/dev/null))${_fw_open:+ – open: $_fw_open}"
    [ -z "$_fw_open" ] && info "  open services/ports: run as root or with sudo (firewall-cmd --list-all)"
    case " $_fw_open " in *" cockpit "*) warn "firewalld: service 'cockpit' open – not needed on an FMW server" ;; esac
elif [ "$_fw" = "nftables" ]; then
    info "firewalld not installed – nftables ruleset present (check manually)"
else
    warn "Firewall: ${_fw} – every socket below is reachable from the network"
fi

if [ -s "$_ext" ]; then
    if [ "$_fw" = "active" ]; then
        info "Processes listening beyond loopback (filtered by firewalld – only the open services above pass):"
    else
        warn "Processes listening beyond loopback (reachable from the network – no firewall):"
    fi
    while read -r _n _proc; do
        printf "      %-30s %3s socket(s)\n" "$_proc" "$_n" | tee -a "$LOG_FILE"
        _rec exposed "$_proc" "$_n"
    done < "$_ext"
    info "  Only Nginx (80/443) should be reachable from outside; WebLogic listens on 127.0.0.1."
else
    ok "All oracle processes listen on loopback only"
fi

# =============================================================================
# 5. Operating system
# =============================================================================
section "5. Operating system"

_os="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown}")"
printList "OS"     22 "$_os"
printList "Kernel" 22 "$(uname -r)"
_rec os "release" "$_os"
_rec os "kernel" "$(uname -r)"
for _pkg in nginx openssl glibc; do
    _v="$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$_pkg" 2>/dev/null)" || _v="not installed"
    printList "$_pkg" 22 "$_v"
    _rec os "$_pkg" "$_v"
done

if $CHECK_OS; then
    # --cacheonly: no repository access needed (hung without it); data as old as the cache
    _err="$WORK_DIR/errata.txt"
    if timeout 60 dnf -q --cacheonly updateinfo list --security > "$_err" 2>/dev/null; then
        # one line per package – count advisories (ELSA ids) and packages
        _n="$(awk '{print $1}' "$_err" | sort -u | grep -c .)"
        _crit="$(awk '$2 ~ /^(Critical|Important)\/Sec/ {print $1}' "$_err" | sort -u | grep -c .)"
        _pk="$(grep -c . "$_err")"
        if [ "$_n" -eq 0 ]; then
            ok "No open security errata (dnf cache)"
        else
            warn "$(printf "%s open security advisories (%s Critical/Important, %s packages, dnf cache) – dnf updateinfo list --security" "$_n" "$_crit" "$_pk")"
            awk '{print $1, $2}' "$_err" | sort -u | sed 's/^/      /' | tee -a "$LOG_FILE"
        fi
        _rec os "security_errata" "$_n" "critical_important=$_crit packages=$_pk"
    else
        info "Security errata not checked (dnf cache empty / no access within 60 s)"
        _rec os "security_errata" "not checked"
    fi
fi

# =============================================================================
# 6. Oracle advisories (--online)
# =============================================================================
section "6. Oracle security advisories after the configured cycle"

# third Tuesday of month (YYYY MM) -> YYYY-MM-DD
_third_tuesday() {
    local first dow
    first="$(date -d "$1-$2-01" +%u)"          # 1=Mon … 7=Sun
    dow=$(( (2 - first + 7) % 7 + 1 + 14 ))
    printf '%s-%s-%02d' "$1" "$2" "$dow"
}

if ! $ONLINE; then
    info "Skipped – run with --online to compare with https://www.oracle.com/security-alerts/"
elif [ -z "${PATCH_CYCLE_DATE:-}" ]; then
    warn "PATCH_CYCLE_DATE not set in oracle_software_version.conf – cannot compare"
else
    _idx="$WORK_DIR/index.html"
    if ! curl -sfL -m 30 -A "Mozilla/5.0" -o "$_idx" https://www.oracle.com/security-alerts/; then
        warn "https://www.oracle.com/security-alerts/ not reachable – advisories not checked"
    else
        _today="$(date +%F)"
        _newer=0
        for _a in $(grep -oE 'c(s)?pu[a-z]{3}[0-9]{4}\.html' "$_idx" | sort -u); do
            _name="${_a%.html}"; _type="CPU"; [[ "$_name" == cspu* ]] && _type="CSPU"
            _mon="${_name: -7:3}"; _yr="${_name: -4}"
            _mm="$(date -d "1 $_mon $_yr" +%m 2>/dev/null)" || continue
            _rel="$(_third_tuesday "$_yr" "$_mm")"
            [[ "$_rel" > "$PATCH_CYCLE_DATE" ]] || continue
            _url="https://www.oracle.com/security-alerts/$_a"
            if [[ "$_rel" > "$_today" ]]; then
                info "$(printf "  %-5s %s  %s  announced (pre-release) – %s" "$_type" "$_name" "$_rel" "$_url")"
                _rec advisory "$_name" "announced" "$_rel"
            else
                warn "$(printf "  %-5s %s  %s  released – NOT covered by %s – %s" "$_type" "$_name" "$_rel" "$PATCH_CYCLE" "$_url")"
                _rec advisory "$_name" "released" "$_rel"
                _newer=$(( _newer + 1 ))
            fi
        done
        [ "$_newer" -eq 0 ] && ok "No advisory released after $PATCH_CYCLE ($PATCH_CYCLE_DATE)"
        [ "$_newer" -gt 0 ] && info "  Next: KA1182 → oracle_software_version.conf, 09-Install/docs/00-patch-references.md"
    fi
fi

# =============================================================================
# JSON for the next CVE-watch steps
# =============================================================================
mkdir -p "$(dirname "$JSON_FILE")"
if python3 -I - "$REC" "$JSON_FILE" "$(date -Iseconds)" <<'PYEOF'
import sys, json
rec, out, ts = sys.argv[1], sys.argv[2], sys.argv[3]
doc = {"generated": ts, "products": [], "patch_cycle": {}, "opatch": None, "spb": None,
       "patches_expected": [], "patches_installed": [], "java": [], "os": {}, "advisories": []}
for line in open(rec, encoding="utf-8"):
    kind, key, val, extra = (line.rstrip("\n").split("\t") + ["", "", "", ""])[:4]
    if kind == "product":   doc["products"].append({"product": key, "version": val, "usage": extra})
    elif kind == "cycle":   doc["patch_cycle"] = {"name": val, "release_date": extra}
    elif kind == "opatch":  doc["opatch"] = val
    elif kind == "spb":     doc["spb"] = val
    elif kind == "patch":   doc["patches_expected"].append({"patch": key, "state": val, "role": extra})
    elif kind == "installed": doc["patches_installed"].append({"patch": key, "description": val})
    elif kind == "java":    doc["java"].append({"home": key, "version": val, "details": extra})
    elif kind == "os":      doc["os"][key] = val if not extra else {"value": val, "details": extra}
    elif kind == "advisory": doc["advisories"].append({"advisory": key, "state": val, "release_date": extra})
    elif kind == "active":  doc.setdefault("active", []).append({"what": key, "state": val, "details": extra})
    elif kind == "exposed": doc.setdefault("exposed_processes", []).append({"process": key, "sockets": val})
    elif kind == "firewall": doc["firewall"] = {"type": key, "state": val}
json.dump(doc, open(out, "w", encoding="utf-8"), indent=2)
PYEOF
then
    chmod 640 "$JSON_FILE"
    info "Inventory written: $JSON_FILE"
else
    warn "JSON not written: $JSON_FILE"
fi

print_summary
exit "$EXIT_CODE"
