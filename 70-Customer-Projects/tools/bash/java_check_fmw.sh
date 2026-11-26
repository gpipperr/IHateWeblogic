#!/bin/bash
# =============================================================================
# Script   : java_check_fmw.sh
# Purpose  : Which Java does this Forms / Reports host really use - and where
#            is a JDK path pinned that breaks after a JDK switch? Standalone
#            version of 02-Checks/java_check.sh + 07-Maintenance/
#            domain_jdk_path.sh for customer hosts (12.2.1.x and 14.1.2) -
#            no IHateWeblogic library, no environment.conf. READ-ONLY.
#              1. JDK of the configuration: JAVA_HOME of the shell, of
#                 oui/.globalEnv.properties (WLST / OPatch), setDomainEnv.sh,
#                 setNMJavaHome.sh, nodemanager.properties, systemd units -
#                 link or versioned directory, version, Oracle JDK / OpenJDK
#              2. the FMW-bundled JDK $ORACLE_HOME/oracle_common/jdk - used by
#                 reports.sh (Reports engines + the JVM inside rwserver), the
#                 Forms / Reports tools: real directory? replaced by a link /
#                 another JDK ("bent")? files changed lately? libjvm.so there?
#              3. Reports: the Java of reports.sh (PATH / LD_LIBRARY_PATH),
#                 directories it names exist?, the libjvm.so loaded by the
#                 running rwserver and the java of the engines
#              4. running processes: WebLogic servers, Node Manager, Reports
#                 engines, rwserver, frmweb - executable, version, vendor
#              5. every file with a JDK path: missing directory = FAIL
#                 (start breaks), versioned directory instead of the link =
#                 WARN (breaks with the next JDK update) - with the file to fix
# Call     : ./java_check_fmw.sh [-o ORACLE_HOME] [-d DOMAIN_HOME] [-t OUTDIR]
#              -o / -d  default: environment, running WebLogic,
#                       domain-registry.xml, /app/oracle/mw, /u01/app/oracle/fmw …
#              -t       directory of the log file (default /tmp)
# Runs as  : the software owner (oracle), no root needed
# Output   : stdout + <OUTDIR>/java_check_<host>_<yyyymmdd_hhmmss>.log
# Exit     : 0 = ok, 1 = warnings, 2 = failures (something will not start)
# Doc      : 70-Customer-Projects/tools/README.md
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================
set -u
VERSION="2026-11-26.1"   # bump on every change

OH="${ORACLE_HOME:-}"; DH="${DOMAIN_HOME:-}"; OUTBASE="/tmp"
while [ $# -gt 0 ]; do
    case "$1" in
        -o) OH="${2:-}"; shift ;;
        -d) DH="${2:-}"; shift ;;
        -t) OUTBASE="${2:-/tmp}"; shift ;;
        -h|--help) sed -n '2,33p' "$0"; printf 'Version: %s\n' "$VERSION"; exit 0 ;;
        -V|--version) printf '%s\n' "$VERSION"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

LOG="$OUTBASE/java_check_$(hostname -s 2>/dev/null || hostname)_$(date +%Y%m%d_%H%M%S).log"
: > "$LOG" 2>/dev/null || LOG=/dev/null
N_WARN=0; N_FAIL=0; FIXLIST=()

_p()   { printf '%s\n' "$*" | tee -a "$LOG"; }
ok()   { printf '\033[32m  OK  \033[0m %s\n' "$*"; printf '  OK   %s\n' "$*" >> "$LOG"; }
warn() { N_WARN=$((N_WARN + 1)); printf '\033[33m WARN \033[0m %s\n' "$*"; printf ' WARN  %s\n' "$*" >> "$LOG"; }
fail() { N_FAIL=$((N_FAIL + 1)); printf '\033[31m FAIL \033[0m %s\n' "$*"; printf ' FAIL  %s\n' "$*" >> "$LOG"; }
info() { printf '       %s\n' "$*" | tee -a "$LOG"; }
section() { _p ""; _p "=== $* ==="; }
fixit() { FIXLIST+=("$*"); }

# --- locate ORACLE_HOME / DOMAIN_HOME (as clone_check_fmw.sh) -------------------
if [ -z "$OH" ] || [ ! -d "$OH/OPatch" ]; then
    OH="$(ps -eo args= 2>/dev/null | sed -n 's/.*-Dweblogic\.home=\([^ ]*\)\/wlserver\/server.*/\1/p' | head -1)"
    if [ ! -d "${OH:-/x}/OPatch" ]; then
        OH=""
        for c in /app/oracle/mw /oracle/product/mw /u01/app/oracle/fmw /u01/oracle/fmw \
                 /u01/app/oracle/middleware /u01/oracle/middleware; do
            [ -d "$c/OPatch" ] && { OH="$c"; break; }
        done
    fi
fi
while [ "${OH%/}" != "$OH" ] && [ "$OH" != / ]; do OH="${OH%/}"; done
if [ -z "$DH" ] && [ -r "${OH:-/x}/domain-registry.xml" ]; then
    DH="$(sed -n 's/.*location="\([^"]*\)".*/\1/p' "$OH/domain-registry.xml" | head -1)"
fi
[ -z "$DH" ] && DH="$(ps -eo args= 2>/dev/null | sed -n 's/.*-Dweblogic\.RootDirectory=\([^ ]*\).*/\1/p' | head -1)"
while [ "${DH%/}" != "$DH" ] && [ "$DH" != / ]; do DH="${DH%/}"; done
[ -d "${OH:-/x}/OPatch" ] || { printf 'ORACLE_HOME not found - use -o\n' >&2; exit 2; }
[ -f "${DH:-/x}/config/config.xml" ] || { printf 'DOMAIN_HOME not found - use -d\n' >&2; DH=""; }
BUNDLED="$OH/oracle_common/jdk"

# --- helpers --------------------------------------------------------------------
declare -A JV=()
# _jver JAVA_BIN -> "17.0.12 Oracle" / "21.0.9 OpenJDK" (cached)
_jver() {
    local b="$1" o v vend
    [ -n "${JV[$b]:-}" ] && { printf '%s' "${JV[$b]}"; return; }
    [ -x "$b" ] || { printf 'not executable'; return; }
    o="$("$b" -version 2>&1)"
    v="$(printf '%s\n' "$o" | sed -n '1s/.*version "\([^"]*\)".*/\1/p')"
    case "$o" in *OpenJDK*) vend=OpenJDK ;; *HotSpot*|*"Java(TM)"*) vend=Oracle ;; *) vend=? ;; esac
    JV[$b]="${v:-?} $vend"; printf '%s' "${JV[$b]}"
}
# _jdk_of PATH -> JDK root of a java binary / lib path (…/bin/java -> …)
_jdk_of() { printf '%s' "$1" | sed -E 's#/(jre/)?(bin/java|lib/server/libjvm\.so|lib/libjvm\.so)$##'; }
# _kind PATH -> link | versioned | plain  (versioned = jdk dir with a version in the name)
_kind() {
    local p="$1"
    if [ -L "$p" ]; then printf 'link'
    elif printf '%s' "$(basename "$p")" | grep -qE '(jdk|jre|java)[-_]?[0-9]+[._][0-9]'; then printf 'versioned'
    else printf 'plain'; fi
}

_p "java_check_fmw.sh $VERSION - $(date '+%Y-%m-%d %H:%M:%S')"
_p "ORACLE_HOME : $OH"
_p "DOMAIN_HOME : ${DH:-<not found>}"
_p "Log         : $LOG"

# =============================================================================
# 1. JDK of the configuration
# =============================================================================
section "1. JDK of the configuration (who starts with which JAVA_HOME)"
declare -A CFGJDK=()
_cfgjdk() { [ -n "$2" ] && CFGJDK["$1"]="$2"; }
_cfgjdk "shell JAVA_HOME" "${JAVA_HOME:-}"
_cfgjdk "oui/.globalEnv.properties (WLST, OPatch)" "$(sed -n 's/^JAVA_HOME=//p' "$OH/oui/.globalEnv.properties" 2>/dev/null | tail -1)"
if [ -n "$DH" ]; then
    # the literal value (lines like JAVA_HOME="${JAVA_HOME}" only pass it on)
    _cfgjdk "bin/setDomainEnv.sh" "$(grep -hE '^[[:space:]]*(export[[:space:]]+)?JAVA_HOME=' "$DH/bin/setDomainEnv.sh" 2>/dev/null | grep -v '\$' | tail -1 | sed -E 's/.*JAVA_HOME="?([^";]*).*/\1/')"
    _cfgjdk "bin/setNMJavaHome.sh" "$(grep -hE 'JAVA_HOME=' "$DH/bin/setNMJavaHome.sh" 2>/dev/null | grep -v '\$' | tail -1 | sed -E 's/.*JAVA_HOME="?([^";]*).*/\1/')"
    _cfgjdk "nodemanager/nodemanager.properties (JavaHome)" "$(sed -n 's/^JavaHome=//p' "$DH/nodemanager/nodemanager.properties" 2>/dev/null | tail -1)"
fi
UNITS="$(systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -iE 'weblogic|nodemanager|wls|fmw|forms|report|oracle' | grep -v '@\.service$')"
for u in $UNITS; do
    j="$(systemctl cat "$u" 2>/dev/null | sed -n 's/^Environment="\{0,1\}JAVA_HOME=\([^" ]*\).*/\1/p' | tail -1)"
    _cfgjdk "systemd $u" "$j"
done
for k in "${!CFGJDK[@]}"; do
    p="${CFGJDK[$k]}"; p="${p%/}"
    if [ ! -d "$p" ]; then
        fail "$(printf '%-48s %s - DIRECTORY MISSING' "$k" "$p")"; fixit "$k: JAVA_HOME=$p does not exist"
        continue
    fi
    kd="$(_kind "$p")"; v="$(_jver "$p/bin/java")"
    case "$kd" in
        link)      ok "$(printf '%-48s %s -> %s (%s)' "$k" "$p" "$(readlink -f "$p")" "$v")" ;;
        versioned) warn "$(printf '%-48s %s (%s) - versioned directory, not the link' "$k" "$p" "$v")"; fixit "$k: $p -> use the JDK link" ;;
        *)         info "$(printf '%-48s %s (%s)' "$k" "$p" "$v")" ;;
    esac
    case "$v" in *OpenJDK*) warn "  $k is OpenJDK - FMW is certified with the Oracle JDK" ;; esac
done
[ ${#CFGJDK[@]} -eq 0 ] && warn "no JAVA_HOME found in the configuration"
PJ="$(command -v java 2>/dev/null)"
[ -n "$PJ" ] && info "$(printf '%-48s %s -> %s (%s)' "java in PATH" "$PJ" "$(readlink -f "$PJ")" "$(_jver "$(readlink -f "$PJ")")")"
[ -n "$UNITS" ] && info "systemd units: $(printf '%s ' $UNITS)(ExecStart: systemctl cat <unit>)"

# =============================================================================
# 2. FMW-bundled JDK oracle_common/jdk
# =============================================================================
section "2. FMW-bundled JDK $BUNDLED (Reports engines, rwserver, tools)"
if [ -L "$BUNDLED" ]; then
    fail "oracle_common/jdk is a LINK -> $(readlink -f "$BUNDLED") - the bundled JDK was replaced"
    info "  reports.sh starts the Reports engines and loads libjvm.so from here - another JDK"
    info "  release breaks Reports; Oracle replaces this JDK only with its own patch"
    fixit "oracle_common/jdk: restore the original directory (backup / patch storage) instead of the link"
elif [ -d "$BUNDLED" ]; then
    ok "oracle_common/jdk is a real directory ($(stat -c '%y' "$BUNDLED" 2>/dev/null | cut -c1-16))"
else
    fail "oracle_common/jdk missing - Reports engines / tools cannot start"
    fixit "oracle_common/jdk missing"
fi
if [ -d "$BUNDLED" ]; then
    bv="$(_jver "$BUNDLED/bin/java")"
    info "version: $bv   release: $(sed -n 's/^JAVA_VERSION="\(.*\)"/\1/p' "$BUNDLED/release" 2>/dev/null)"
    case "$bv" in
        17.*Oracle*) ok "bundled JDK is Oracle JDK 17 (FMW 14.1.2 ships 17.0.x)" ;;
        1.8*Oracle*) ok "bundled JDK is Oracle JDK 8 (FMW 12.2.1.x)" ;;
        *) warn "bundled JDK is $bv - not the release FMW ships (14.1.2: Oracle JDK 17, 12.2.1.x: 8)"
           fixit "oracle_common/jdk holds $bv - check whether it was overwritten / bent" ;;
    esac
    for f in bin/java lib/server/libjvm.so; do
        if [ -L "$BUNDLED/$f" ]; then fail "oracle_common/jdk/$f is a link -> $(readlink -f "$BUNDLED/$f")"; fixit "oracle_common/jdk/$f is a link"
        elif [ ! -e "$BUNDLED/$f" ]; then fail "oracle_common/jdk/$f missing"; fixit "oracle_common/jdk/$f missing"
        else ok "oracle_common/jdk/$f present"; fi
    done
    # links below legal/ (COPYRIGHT -> ../java.base/) are part of every JDK
    nl="$(find "$BUNDLED" -type l ! -path '*/legal/*' 2>/dev/null | wc -l)"
    if [ "$nl" -gt 0 ]; then
        warn "$nl symbolic link(s) inside oracle_common/jdk (outside legal/):"
        find "$BUNDLED" -type l ! -path '*/legal/*' -printf '         %p -> %l\n' 2>/dev/null | head -10 | tee -a "$LOG"
    else
        ok "no symbolic links inside oracle_common/jdk (legal/ aside)"
    fi
    nn="$(find "$BUNDLED" -type f -newer "$BUNDLED/release" 2>/dev/null | wc -l)"
    if [ "$nn" -gt 0 ]; then
        warn "$nn file(s) in oracle_common/jdk newer than its release file - changed after the install / patch:"
        find "$BUNDLED" -type f -newer "$BUNDLED/release" -printf '         %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort -r | head -10 | tee -a "$LOG"
    else
        ok "no file in oracle_common/jdk changed after its release file"
    fi
fi
sib="$(ls -d "$OH"/oracle_common/jdk?* "$OH"/oracle_common/*jdk*.* 2>/dev/null | grep -v "^$BUNDLED$")"
[ -n "$sib" ] && { info "other JDK copies next to it (backup / old switch?):"; printf '%s\n' "$sib" | sed 's/^/         /' | tee -a "$LOG"; }

# =============================================================================
# 3. Reports: reports.sh and the running Reports processes
# =============================================================================
section "3. Reports - Java of reports.sh and of the running processes"
RSH="${DH:+$DH/reports/bin/reports.sh}"
if [ -n "$RSH" ] && [ -f "$RSH" ]; then
    info "$RSH ($(stat -c '%y' "$RSH" 2>/dev/null | cut -c1-16))"
    # Linux branch: the PATH line and the LD_LIBRARY_PATH line with lib/server
    grep -nE '^[[:space:]]*(PATH|LD_LIBRARY_PATH)=' "$RSH" | grep -E 'oracle_common/jdk/(bin|lib/server)|jdk|java' \
        | grep -vE 'IA64W|PA_RISC|ia64|i386|alpha|ppc64|amd64|sparcv9' | cut -c1-200 | sed 's/^/         /' | tee -a "$LOG"
    other="$(grep -nE '(jdk|jre|java)[^/]*/' "$RSH" | grep -v 'oracle_common/jdk' | grep -vE '^[0-9]+:[[:space:]]*#' | cut -c1-160)"
    if [ -n "$other" ]; then
        warn "reports.sh names another JDK than oracle_common/jdk (edited by hand?):"
        printf '%s\n' "$other" | sed 's/^/         /' | tee -a "$LOG"
        fixit "reports.sh: $(printf '%s' "$other" | head -1 | cut -d: -f1) - JDK path changed by hand"
    else
        ok "reports.sh uses only \${ORACLE_HOME}/oracle_common/jdk (as delivered)"
    fi
    grep -q 'UseBASE64Intrinsics' "$RSH" && info "reports.sh carries -XX:-UseBASE64Intrinsics (Java4Shell mitigation)"
else
    info "no reports.sh (no Reports in this domain)"
fi
for c in ${DH:+$DH/config/fmwconfig/components/ReportsServerComponent/*/rwserver.conf}; do
    [ -f "$c" ] || continue
    jo="$(grep -oE 'jvmOptions="[^"]*"' "$c" | head -1)"
    info "$(basename "$(dirname "$c")") rwserver.conf engine ${jo:-jvmOptions not set}"
done
for p in $(pgrep -x rwserver 2>/dev/null); do
    lj="$(grep -m1 -oE '/[^ ]*libjvm\.so' "/proc/$p/maps" 2>/dev/null)"
    if [ -z "$lj" ]; then info "rwserver pid $p: no libjvm.so loaded (yet)"; continue; fi
    jr="$(_jdk_of "$lj")"
    case "$(readlink -f "$jr")" in
        "$(readlink -f "$BUNDLED")") ok "rwserver pid $p loads libjvm.so of oracle_common/jdk ($(_jver "$jr/bin/java"))" ;;
        *) warn "rwserver pid $p loads libjvm.so from $lj ($(_jver "$jr/bin/java")) - not oracle_common/jdk"
           fixit "rwserver uses $jr - check LD_LIBRARY_PATH of reports.sh / the shell that started the Reports server" ;;
    esac
done
[ -z "$(pgrep -x rwserver 2>/dev/null)" ] && warn "no rwserver running - Reports server down (as reported?) - check its log: \$DOMAIN_HOME/servers/<WLS_REPORTS>/logs/reports/ and the component logs"

# =============================================================================
# 4. Running processes
# =============================================================================
section "4. Running processes - executable, version, vendor"
for p in $(pgrep -f 'weblogic\.(Server|NodeManager)|rwrun\.jar|rwEng|rwengine' 2>/dev/null) $(pgrep -x frmweb 2>/dev/null | head -1); do
    a="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"; [ -n "$a" ] || continue
    exe="$(readlink -f "/proc/$p/exe" 2>/dev/null)"
    case "$a" in
        *weblogic.NodeManager*) what="Node Manager" ;;
        *-Dweblogic.Name=*) what="$(printf '%s' "$a" | grep -oE '\-Dweblogic\.Name=[^ ]+' | cut -d= -f2)" ;;
        *rwrun.jar*|*rwEng*|*rwengine*) what="Reports engine" ;;
        *frmweb*) what="frmweb (one of $(pgrep -c -x frmweb))" ;;
        *) what="?" ;;
    esac
    case "$(basename "$exe")" in
        java) v="$(_jver "$exe")"; jr="$(_jdk_of "$exe")" ;;
        *) lj="$(grep -m1 -oE '/[^ ]*libjvm\.so' "/proc/$p/maps" 2>/dev/null)"; jr="$(_jdk_of "${lj:-}")"; v="libjvm ${lj:-not loaded}" ;;
    esac
    line="$(printf '%-22s pid %-8s %s (%s)' "$what" "$p" "${jr:-$exe}" "$v")"
    case "$v" in
        *OpenJDK*) warn "$line - OpenJDK"; fixit "$what runs on OpenJDK ($jr)" ;;
        *) case "$what" in
               "Reports engine") [ "$(readlink -f "$jr")" = "$(readlink -f "$BUNDLED")" ] && ok "$line" || warn "$line - not oracle_common/jdk" ;;
               *) ok "$line" ;;
           esac ;;
    esac
    # frmweb: LD_PRELOAD / LD_LIBRARY_PATH it really runs with
    case "$what" in frmweb*)
        tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -E '^LD_(PRELOAD|LIBRARY_PATH)=' | sed 's/^/         /' | tee -a "$LOG" ;;
    esac
done

# =============================================================================
# 5. Files with a JDK path: exists? link or versioned directory?
# =============================================================================
section "5. Files with a JDK path (missing = FAIL, versioned dir = WARN)"
FILES=()
if [ -n "$DH" ]; then
    for f in "$DH"/bin/*.sh "$DH"/nodemanager/nodemanager.properties "$DH"/reports/bin/reports.sh \
             "$DH"/config/fmwconfig/servers/*/applications/*/config/*.env \
             "$DH"/config/fmwconfig/components/ReportsServerComponent/*/rwserver.conf \
             "$DH"/config/fmwconfig/components/FORMS/instances/*/bin/*.sh \
             "$DH"/servers/*/data/nodemanager/startup.properties; do
        [ -f "$f" ] && case "$f" in *.bak*|*.ori|*.orig) ;; *) FILES+=("$f") ;; esac
    done
fi
for f in "$OH"/oui/.globalEnv.properties "$OH"/oui/bin/*.sh; do [ -f "$f" ] && FILES+=("$f"); done
TMPU="$(mktemp 2>/dev/null || printf '/tmp/java_check_units.%s' $$)"
for u in $UNITS; do printf '# unit %s\n' "$u"; systemctl cat "$u" 2>/dev/null; done > "$TMPU"
[ -s "$TMPU" ] && FILES+=("$TMPU")
BAD=0
# every JDK root named in a file: variables of the domain resolved, the path
# cut after its jdk* / jre* / java* component (…/oracle_common/jdk/jre/lib/x
# -> …/oracle_common/jdk); paths with an unresolved variable are skipped
for f in "${FILES[@]}"; do
    sed -e "s#\${ORACLE_HOME}#$OH#g" -e "s#\$ORACLE_HOME#$OH#g" -e "s#\${MW_HOME}#$OH#g" \
        -e "s#\${DOMAIN_HOME}#$DH#g" -e "s#\$DOMAIN_HOME#$DH#g" -e "s#%ORACLE_HOME%#$OH#g" "$f" 2>/dev/null \
    | awk -v f="$f" '
        /^[[:space:]]*#/ { next }
        { line = $0
          while (match(line, /(\/[A-Za-z0-9._@-]+)+/)) {
              pre = (RSTART > 1) ? substr(line, RSTART - 1, 1) : ""
              p = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
              if (pre ~ /[A-Za-z0-9_}%]/ || substr(line, 1, 1) == "$") continue   # behind an unresolved variable
              n = split(p, c, "/"); r = ""; hit = 0
              # a JDK root: jdk*, jre*, java-<x> / java<ver>, default-java; a plain
              # "java" only with bin / lib / jre below it (/u01/app/oracle/java is a container)
              for (i = 2; i <= n; i++) { r = r "/" c[i]
                  if (c[i] ~ /^(jdk|jre)([-_.]?[0-9A-Za-z][A-Za-z0-9._-]*)?$|^java[-_.]?[0-9][A-Za-z0-9._-]*$|^java-[A-Za-z][A-Za-z0-9._-]*$|^default-java$/ \
                      || (c[i] == "java" && c[i+1] ~ /^(bin|lib|jre)$/)) { hit = 1; break } }
              if (hit) printf "%s|%d|%s\n", f, NR, r
          } }'
done | sort -u -t'|' -k1,1 -k3,3 > "$TMPU.hits"
while IFS='|' read -r f ln path; do
    name="$f"; [ "$f" = "$TMPU" ] && name="systemd unit(s)"; name="${name#"$DH"/}"
    [ "$path" = "$BUNDLED" ] && continue                      # the bundled JDK: section 2
    if [ ! -e "$path" ]; then
        BAD=$((BAD + 1)); fail "$(printf '%-60s line %-5s %s - MISSING' "$name" "$ln" "$path")"; fixit "$name line $ln: $path does not exist"
    elif [ "$(_kind "$path")" = versioned ] && [ ! -L "$path" ]; then
        BAD=$((BAD + 1)); warn "$(printf '%-60s line %-5s %s - versioned, not the link' "$name" "$ln" "$path")"; fixit "$name line $ln: $path -> JDK link"
    fi
done < "$TMPU.hits"
[ "$BAD" -eq 0 ] && ok "every JDK path in $(printf '%s' "${#FILES[@]}") file(s) exists and uses a link / the bundled JDK"
rm -f "$TMPU" "$TMPU.hits"

# =============================================================================
# Summary
# =============================================================================
section "Summary - what to adjust"
if [ ${#FIXLIST[@]} -eq 0 ]; then
    ok "nothing to adjust"
else
    printf '%s\n' "${FIXLIST[@]}" | awk '!s[$0]++' | sed 's/^/  - /' | tee -a "$LOG"
fi
_p ""
_p "Result: $N_FAIL FAIL, $N_WARN WARN - log: $LOG"
[ "$N_FAIL" -gt 0 ] && exit 2
[ "$N_WARN" -gt 0 ] && exit 1
exit 0
