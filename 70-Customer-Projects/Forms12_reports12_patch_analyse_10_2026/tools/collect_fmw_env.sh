#!/bin/bash
# =============================================================================
# Script   : collect_fmw_env.sh
# Purpose  : Collect the metadata of an Oracle Forms & Reports / FMW host –
#            from the OS to Forms – into one directory + tar.gz for analysis.
#            READ-ONLY: writes only into the output directory (OPatch itself
#            writes its usual logs to $ORACLE_HOME/cfgtoollogs when it reads
#            the inventory). Secrets are masked before they are stored.
#            Standalone – no IHateWeblogic library, plain bash + coreutils.
# Call     : ./collect_fmw_env.sh [-o ORACLE_HOME] [-d DOMAIN_HOME] [-t OUTBASE]
#                                 [--full] [--logs]
#            -o / -d  default: environment, $ORACLE_HOME/domain-registry.xml,
#                     /oracle/product/mw, /u01/app/oracle/fmw …
#            -t       base directory of the output (default /tmp)
#            --full   also "opatch lsinventory -details" and "-bugs_fixed"
#                     (slow, large – needed for bug / CVE questions)
#            --logs   also the error lines of the server logs (last 200)
# Runs as  : the software owner of the Oracle Home (oracle), not root
# Output   : <OUTBASE>/fmw_collect_<host>_<yyyymmdd_hhmmss>/ + .tar.gz
#            00_summary.txt = key facts; every other file = one area.
#            Host names, IPs and paths stay in the output (needed for the
#            analysis) – passwords, {AES} values, userid= values do not.
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

set -u
umask 077

OH="${ORACLE_HOME:-}"; DH="${DOMAIN_HOME:-}"; OUTBASE="/tmp"; FULL=false; LOGS=false
while [ $# -gt 0 ]; do
    case "$1" in
        -o) OH="${2:-}"; shift ;;
        -d) DH="${2:-}"; shift ;;
        -t) OUTBASE="${2:-/tmp}"; shift ;;
        --full) FULL=true ;;
        --logs) LOGS=true ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

HOST="$(hostname -s 2>/dev/null || hostname)"
TS="$(date +%Y%m%d_%H%M%S)"
OUT="$OUTBASE/fmw_collect_${HOST}_${TS}"
mkdir -p "$OUT" || { printf 'Cannot create %s\n' "$OUT" >&2; exit 2; }
SUM="$OUT/00_summary.txt"

# --- helpers -----------------------------------------------------------------
# mask: passwords, {AES}/{AES256} values, userid=/password= values, -D…password=
mask() {
    sed -E \
        -e 's/(<[^>/]*[Pp]ass[Ww]or[dD][^>]*>)[^<]*/\1***MASKED***/g' \
        -e 's/\{AES(256)?\}[A-Za-z0-9+\/=]+/{AES}***MASKED***/g' \
        -e 's/((^|[[:space:];&?])(userid|USERID|UserId|authid|AUTHID|password|PASSWORD|Password|passwd|pwd|PWD)[[:space:]]*=[[:space:]]*)[^[:space:];&]+/\1***MASKED***/g' \
        -e 's/(-D[A-Za-z0-9._]*[Pp]ass[Ww]ord[A-Za-z0-9._]*=)[^[:space:]]+/\1***MASKED***/g' \
        -e 's#([A-Za-z0-9_]+)/[^@[:space:]/]+@#\1/***MASKED***@#g'
}
# run FILE TITLE CMD… – run a command, append title, output (masked) and rc
run() {
    local f="$OUT/$1" t="$2"; shift 2
    {
        printf '### %s\n### $ %s\n' "$t" "$*"
        timeout 600 "$@" 2>&1 | mask
        printf '### rc=%s\n\n' "${PIPESTATUS[0]}"
    } >> "$f"
}
# runsh FILE TITLE "shell string" – like run, for pipes
runsh() {
    local f="$OUT/$1" t="$2" c="$3"
    {
        printf '### %s\n### $ %s\n' "$t" "$c"
        timeout 600 bash -c "$c" 2>&1 | mask
        printf '### rc=%s\n\n' "${PIPESTATUS[0]}"
    } >> "$f"
}
# copy FILE_IN_OUTPUT SOURCE – masked copy of a config file
copy() {
    local dst="$OUT/$1" src="$2"
    [ -r "$src" ] || return 0
    { printf '### file: %s (%s bytes, %s)\n' "$src" "$(wc -c < "$src")" \
          "$(date -r "$src" '+%Y-%m-%d %H:%M' 2>/dev/null)"
      mask < "$src"; printf '\n'; } >> "$dst"
}
fact() { printf '%-28s %s\n' "$1" "$2" >> "$SUM"; }
say()  { printf '  %s\n' "$*"; }

say "Output: $OUT"

# --- locate ORACLE_HOME / DOMAIN_HOME ------------------------------------------
if [ -z "$OH" ] || [ ! -d "$OH/OPatch" ]; then
    for c in /oracle/product/mw /u01/app/oracle/fmw /u01/oracle/fmw \
             /u01/app/oracle/middleware /u01/oracle/middleware; do
        [ -d "$c/OPatch" ] && { OH="$c"; break; }
    done
fi
[ -d "${OH:-/nonexistent}/OPatch" ] || { printf 'ORACLE_HOME not found – use -o\n' >&2; OH=""; }
if [ -z "$DH" ] && [ -n "$OH" ] && [ -r "$OH/domain-registry.xml" ]; then
    DH="$(sed -n 's/.*location="\([^"]*\)".*/\1/p' "$OH/domain-registry.xml" | head -1)"
fi
if [ -z "$DH" ]; then
    DH="$(ps -eo args 2>/dev/null | sed -n 's/.*-Dweblogic\.RootDirectory=\([^ ]*\).*/\1/p' | head -1)"
fi
[ -n "$DH" ] && [ ! -f "$DH/config/config.xml" ] && { printf 'DOMAIN_HOME %s has no config.xml – use -d\n' "$DH" >&2; DH=""; }

{
    printf 'FMW environment collection – %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '%s\n\n' "collect_fmw_env.sh (read-only, secrets masked)"
} > "$SUM"
fact "Host" "$(hostname -f 2>/dev/null || hostname)"
fact "User" "$(id)"
fact "ORACLE_HOME" "${OH:-(not found)}"
fact "DOMAIN_HOME" "${DH:-(not found)}"

# =============================================================================
# 1. Operating system
# =============================================================================
say "1/7 OS"
run 10_os.txt "OS release"          cat /etc/os-release
run 10_os.txt "Kernel"              uname -a
run 10_os.txt "glibc"               ldd --version
run 10_os.txt "Uptime"              uptime
run 10_os.txt "Memory"              free -m
run 10_os.txt "Disks"               df -hP
run 10_os.txt "Mounts (noexec?)"    findmnt -rno TARGET,FSTYPE,OPTIONS
run 10_os.txt "ulimit (this user)"  bash -c 'ulimit -a'
run 10_os.txt "SELinux"             getenforce
run 10_os.txt "Time / zone"         timedatectl
run 10_os.txt "Locale"              locale
runsh 10_os.txt "Kernel parameters"   "sysctl -a 2>/dev/null | grep -E '^(kernel\\.(sem|shm)|fs\\.file-max|net\\.ipv4\\.ip_local_port_range|vm\\.swappiness)'"
runsh 10_os.txt "Packages (FMW prerequisites)" "rpm -q binutils gcc gcc-c++ glibc glibc-devel libaio libaio-devel libgcc libstdc++ libstdc++-devel libXext libXi libXtst libnsl make motif motif-devel ksh sysstat fontconfig xorg-x11-utils 2>&1"
run 10_os.txt "Network addresses"   ip -br addr
runsh 10_os.txt "Listening ports"     "ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null"
runsh 10_os.txt "systemd units (oracle/wls/forms/reports/nginx/httpd)" "systemctl list-unit-files 2>/dev/null | grep -iE 'oracle|weblogic|wls|fmw|forms|report|nodemanager|nginx|httpd|ohs'"
run 10_os.txt "crontab (this user)" crontab -l
fact "OS" "$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release 2>/dev/null)"
fact "glibc" "$(ldd --version 2>/dev/null | head -1 | awk '{print $NF}')"
fact "Uptime" "$(uptime -p 2>/dev/null || uptime)"
fact "Memory MB (total/avail)" "$(free -m 2>/dev/null | awk '/^Mem:/{print $2" / "$7}')"
fact "SELinux" "$(getenforce 2>/dev/null || printf 'n/a')"

# =============================================================================
# 2. Java
# =============================================================================
say "2/7 Java"
JAVA_CANDIDATES="$( { [ -n "$OH" ] && sed -n 's/^JAVA_HOME[A-Z0-9_]*=//p' "$OH/oui/.globalEnv.properties" 2>/dev/null;
                     [ -n "${JAVA_HOME:-}" ] && printf '%s\n' "$JAVA_HOME";
                     for p in $(pgrep -f 'java' 2>/dev/null); do readlink -f "/proc/$p/exe" 2>/dev/null | sed 's#/\(jre/\)\{0,1\}bin/java$##'; done; } | sort -u)"
for J in $JAVA_CANDIDATES; do
    [ -x "$J/bin/java" ] || continue
    run 20_java.txt "java -version: $J" "$J/bin/java" -version
    runsh 20_java.txt "link / release: $J" "ls -ld '$J'; readlink -f '$J'; cat '$J/release' 2>/dev/null"
done
runsh 20_java.txt "Java installations next to the JDK link" "for d in \$(printf '%s\n' $JAVA_CANDIDATES | xargs -n1 dirname 2>/dev/null | sort -u); do ls -l \$d; done"
runsh 20_java.txt "Java of the running processes" "for p in \$(pgrep -f java); do printf '%s %s\n' \$p \"\$(readlink -f /proc/\$p/exe 2>/dev/null)\"; done"
[ -n "$OH" ] && copy 20_java.txt "$OH/oui/.globalEnv.properties"
J1="$( [ -n "$OH" ] && sed -n 's/^JAVA_HOME=//p' "$OH/oui/.globalEnv.properties" 2>/dev/null | head -1)"
fact "JDK of OPatch (.globalEnv)" "${J1:-?} -> $(readlink -f "${J1:-/x}" 2>/dev/null)"
fact "JDK version (.globalEnv)" "$("${J1:-/x}/bin/java" -version 2>&1 | head -2 | tr '\n' ' ')"
fact "JDKs of running processes" "$(for p in $(pgrep -f java 2>/dev/null); do readlink -f "/proc/$p/exe" 2>/dev/null; done | sort -u | tr '\n' ' ')"

# =============================================================================
# 3. Oracle Home, inventory, patches
# =============================================================================
say "3/7 Oracle Home / OPatch"
if [ -n "$OH" ]; then
    OP="$OH/OPatch/opatch"
    copy 30_inventory.txt /etc/oraInst.loc
    INV="$(sed -n 's/^inventory_loc=//p' /etc/oraInst.loc 2>/dev/null)"
    [ -n "$INV" ] && copy 30_inventory.txt "$INV/ContentsXML/inventory.xml"
    runsh 30_inventory.txt "Distributions" "'$OH/oui/bin/viewInventory.sh' 2>/dev/null | grep -iE 'distribution|feature set' | sort -u"
    run 31_opatch.txt "opatch version"  "$OP" version
    run 31_opatch.txt "opatch lspatches" "$OP" lspatches
    run 31_opatch.txt "opatch lsinventory" "$OP" lsinventory
    if $FULL; then
        run 32_opatch_details.txt "opatch lsinventory -details"   "$OP" lsinventory -details
        run 32_opatch_details.txt "opatch lsinventory -bugs_fixed" "$OP" lsinventory -bugs_fixed
    fi
    runsh 30_inventory.txt "Components (Forms / Reports / OHS / WebGate / SQL Developer)" \
        "ls -d '$OH'/inventory/Components/* 2>/dev/null | xargs -n1 basename | grep -iE 'forms|reports|ohs|webgate|sqldeveloper|oracle\\.rdbms|perl' | sort -u"
    runsh 30_inventory.txt "Top level of the Oracle Home" "ls -l '$OH'"
    runsh 30_inventory.txt "Forms / Reports binaries" "ls -l --time-style=long-iso '$OH'/bin/{frmweb,frmcmp,frmcmp_batch,rwserver,rwrun,rwbuilder,rwconverter} 2>&1"
    copy 30_inventory.txt "$OH/domain-registry.xml"
    fact "Distributions" "$("$OH/oui/bin/viewInventory.sh" 2>/dev/null | sed -n 's/.*Distribution: //p' | sort -u | tr '\n' ';')"
    fact "OPatch" "$("$OP" version 2>/dev/null | sed -n 's/^OPatch Version: //p')"
    fact "Patches (lspatches)" "$("$OP" lspatches 2>/dev/null | grep -c '^[0-9]')"
    fact "Reports component in home" "$(ls "$OH"/inventory/Components 2>/dev/null | grep -ciE 'reports') entries"
    fact "OHS component in home" "$(ls "$OH"/inventory/Components 2>/dev/null | grep -ciE 'ohs') entries"
fi

# =============================================================================
# 4. Domain configuration (masked)
# =============================================================================
say "4/7 Domain"
if [ -n "$DH" ]; then
    copy 40_config.xml.txt "$DH/config/config.xml"
    runsh 40_domain.txt "Servers / listen addresses / ports (config.xml)" \
        "grep -E '<(name|listen-address|listen-port|machine|cluster|enabled|nm-type|listen-port-enabled)>' '$DH/config/config.xml' | sed 's/^ *//' | head -200"
    runsh 40_domain.txt "Servers on disk" "ls -l '$DH/servers'"
    runsh 40_domain.txt "Domain files" "ls -l '$DH' '$DH/bin' '$DH/nodemanager' 2>&1"
    for f in "$DH/nodemanager/nodemanager.properties" "$DH/bin/setUserOverrides.sh" \
             "$DH/bin/setDomainEnv.sh" "$DH/bin/startNodeManager.sh"; do
        copy 41_domain_scripts.txt "$f"
    done
    runsh 40_domain.txt "Versioned JDK paths in the domain (instead of a link)" \
        "grep -rn 'jdk1\\.8\\.0_\\|jdk-[0-9]' '$DH/bin' '$DH/nodemanager' 2>/dev/null | head -50"
    # Forms / Reports configuration files
    for pat in formsweb.cfg default.env webutil.cfg ftrace.cfg registry.dat rwserver.conf \
               rwservlet.properties cgicmd.dat uifont.ali rwnetwork.conf; do
        find "$DH/config/fmwconfig" -name "$pat" -type f 2>/dev/null | head -10 | while read -r f; do
            copy "42_forms_reports_config.txt" "$f"
        done
    done
    # OHS instances (domain configuration, not the runtime copy)
    for d in "$DH"/config/fmwconfig/components/OHS/*/; do
        [ -d "$d" ] || continue
        case "$d" in */instances/) continue ;; esac
        for f in httpd.conf ssl.conf admin.conf mod_wl_ohs.conf; do
            copy 43_ohs_config.txt "$d$f"
        done
        for f in "$d"moduleconf/*.conf; do copy 43_ohs_config.txt "$f"; done
        runsh 43_ohs_config.txt "default index.html in $d" \
            "ls -l '${d}htdocs/index.html' 2>&1; grep -ic 'oracle http server' '${d}htdocs/index.html' 2>/dev/null"
    done
    fact "Domain" "$(sed -n 's/.*<name>\([^<]*\)<\/name>.*/\1/p' "$DH/config/config.xml" | head -1)"
    fact "Servers (config.xml)" "$(awk '/<server>/{s=1} s&&/<name>/{gsub(/.*<name>|<\/name>.*/,"");printf "%s ",$0;s=0}' "$DH/config/config.xml")"
fi

# =============================================================================
# 5. Running processes
# =============================================================================
say "5/7 Processes"
runsh 50_processes.txt "WLS / Node Manager / Forms / Reports / OHS processes" \
    "ps -eo pid,ppid,user,lstart,etime,rss,args | grep -E 'weblogic\\.(Server|NodeManager)|frmweb|rwserver|rwengine|rwrun|httpd|nginx' | grep -v grep"
runsh 50_processes.txt "Process tree" "ps auxf"
fact "frmweb processes" "$(pgrep -c frmweb 2>/dev/null; true)"
fact "WLS servers running" "$(ps -eo args= | sed -n 's/.*-Dweblogic[.]Name=\([^ ]*\).*/\1/p' | sort -u | tr '\n' ' ')"

# =============================================================================
# 6. Oracle Net, web tier
# =============================================================================
say "6/7 Oracle Net / web tier"
for d in "${TNS_ADMIN:-}" "$DH/config/fmwconfig" "$OH/network/admin"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    find "$d" -maxdepth 4 \( -name tnsnames.ora -o -name sqlnet.ora -o -name ldap.ora \) -type f 2>/dev/null \
        | head -10 | while read -r f; do copy 60_net.txt "$f"; done
done
runsh 60_net.txt "Web server in front (nginx / httpd / OHS)" \
    "command -v nginx httpd apachectl 2>/dev/null; ls -d /etc/nginx /etc/httpd '$DH'/config/fmwconfig/components/OHS 2>/dev/null"

# =============================================================================
# 7. Logs (sizes always, error lines only with --logs)
# =============================================================================
say "7/7 Logs"
if [ -n "$DH" ]; then
    runsh 70_logs.txt "Server log files" "ls -l --time-style=long-iso '$DH'/servers/*/logs/ 2>/dev/null"
    runsh 70_logs.txt "Error counts per server log" \
        "for f in '$DH'/servers/*/logs/*.log; do printf '%6s %s\n' \$(grep -c '<Error>' \"\$f\" 2>/dev/null) \"\$f\"; done"
    if $LOGS; then
        for f in "$DH"/servers/*/logs/*.log "$DH"/servers/*/logs/*.out; do
            [ -r "$f" ] || continue
            { printf '### errors: %s\n' "$f"
              grep -E '<Error>|<Critical>|<Alert>|<Emergency>|FRM-|REP-|ORA-' "$f" | tail -200 | mask
              printf '\n'; } >> "$OUT/71_log_errors.txt"
        done
    fi
fi

# =============================================================================
# Pack
# =============================================================================
printf '\nFiles:\n' >> "$SUM"; (cd "$OUT" && ls -l) >> "$SUM"
tar -czf "$OUT.tar.gz" -C "$OUTBASE" "$(basename "$OUT")" 2>/dev/null
say "Summary : $SUM"
say "Archive : $OUT.tar.gz ($(du -h "$OUT.tar.gz" 2>/dev/null | cut -f1))"
say "Secrets are masked – check 00_summary.txt and the files before sending."
exit 0
