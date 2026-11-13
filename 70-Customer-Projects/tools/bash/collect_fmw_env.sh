#!/bin/bash
# =============================================================================
# Script   : collect_fmw_env.sh
# Purpose  : Collect the metadata of an Oracle Forms & Reports / FMW host
#            (12.2.1.x and 14.1.2) –
#            from the OS to Forms – into one directory + tar.gz for analysis.
#            READ-ONLY: writes only into the output directory (OPatch itself
#            writes its usual logs to $ORACLE_HOME/cfgtoollogs when it reads
#            the inventory). Secrets are masked before they are stored.
#            No IHateWeblogic library - bash + coreutils (+ openssl) and the
#            shared helpers ihw_tools_lib.sh next to this script.
#            The archive is ENCRYPTED by default (ZIP + openssl AES-256, the
#            passphrase is asked twice at the start): masked, but it holds host
#            names, IPs and paths of the customer.
# Call     : ./collect_fmw_env.sh [-o ORACLE_HOME] [-d DOMAIN_HOME] [-t OUTBASE]
#                                 [--full] [--logs] [--no-encrypt] [--keep]
#            -o / -d  default: environment, $ORACLE_HOME/domain-registry.xml,
#                     /oracle/product/mw, /u01/app/oracle/fmw …
#            -t       base directory of the output (default /tmp)
#            --full   also "opatch lsinventory -details" and "-bugs_fixed"
#                     (slow, large – needed for bug / CVE questions)
#            --logs   also the error lines of the server logs (last 200)
#            --no-encrypt  plain ZIP (still masked) - e.g. without a terminal
#            --keep   keep the output directory next to the archive
# Runs as  : the software owner of the Oracle Home (oracle), not root
# Output   : <OUTBASE>/fmw_collect_<host>_<yyyymmdd_hhmmss>.zip.enc (+ .sha256)
#            decrypt: openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 \
#                       -in <file>.zip.enc -out <file>.zip
#            00_summary.txt = key facts; every other file = one area.
#            Host names, IPs and paths stay in the output (needed for the
#            analysis) – passwords, {AES} values, userid= values do not.
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

set -u
umask 077
VERSION="2026-11-13.1"   # bump on every change – shown in 00_summary.txt

_IHWT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ihw_tools_lib.sh
. "$_IHWT_DIR/ihw_tools_lib.sh" || { printf 'ihw_tools_lib.sh missing next to %s\n' "$0" >&2; exit 2; }

OH="${ORACLE_HOME:-}"; DH="${DOMAIN_HOME:-}"; OUTBASE="/tmp"; FULL=false; LOGS=false
ENCRYPT=true; KEEP=false
while [ $# -gt 0 ]; do
    case "$1" in
        -o) OH="${2:-}"; shift ;;
        -d) DH="${2:-}"; shift ;;
        -t) OUTBASE="${2:-/tmp}"; shift ;;
        --full) FULL=true ;;
        --logs) LOGS=true ;;
        --no-encrypt) ENCRYPT=false ;;
        --keep) KEEP=true ;;
        -h|--help) sed -n '2,34p' "$0"; printf 'Version: %s\n' "$VERSION"; exit 0 ;;
        -V|--version) printf '%s\n' "$VERSION"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

HOST="$(hostname -s 2>/dev/null || hostname)"
TS="$(date +%Y%m%d_%H%M%S)"
OUTBASE="$(cd "$OUTBASE" 2>/dev/null && pwd)" || { printf 'Output directory does not exist\n' >&2; exit 2; }
NAME="fmw_collect_${HOST}_${TS}"
OUT="$OUTBASE/$NAME"
# customer data (host names, IPs, paths) never into a git work tree
ihwt_git_guard "$OUTBASE" "$NAME.zip" || exit 2
# passphrase first - before the minutes of collecting
IHWT_PASS=""
if $ENCRYPT; then
    ihwt_read_passphrase "collector archive" || { printf '  -> or use --no-encrypt (plain ZIP, masked)\n' >&2; exit 2; }
fi
mkdir -p "$OUT" || { printf 'Cannot create %s\n' "$OUT" >&2; exit 2; }
trap 'IHWT_PASS=""' EXIT
SUM="$OUT/00_summary.txt"

# --- helpers -----------------------------------------------------------------
# mask: ihw_tools_lib.sh (passwords, <identifier>, {AES}, userid= / authid=,
# -D...password=, user/pw@) - the same rules as the configuration export
mask() { ihwt_mask; }
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

say "collect_fmw_env.sh version $VERSION"
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
    printf '%s\n\n' "collect_fmw_env.sh version $VERSION (ihw_tools_lib $(ihwt_lib_version), read-only, secrets masked)"
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
runsh 10_os.txt "Packages relevant for patches (CA / SSL / kernel)" "rpm -q openssl openssl-libs ca-certificates kernel kernel-uek 2>&1; rpm -qa --last 2>/dev/null | head -15"
run 10_os.txt "Network addresses"   ip -br addr
runsh 10_os.txt "Listening ports"     "ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null"
runsh 10_os.txt "systemd units (oracle/wls/forms/reports/nginx/httpd)" "systemctl list-unit-files 2>/dev/null | grep -iE 'oracle|weblogic|wls|fmw|forms|report|nodemanager|nginx|httpd|ohs'"
run 10_os.txt "crontab (this user)" crontab -l
fact "OS" "$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release 2>/dev/null)"
fact "glibc" "$(ldd --version 2>/dev/null | head -1 | awk '{print $NF}')"
fact "Uptime" "$(uptime -p 2>/dev/null || uptime)"
fact "Memory MB (total/avail)" "$(free -m 2>/dev/null | awk '/^Mem:/{print $2" / "$7}')"
fact "SELinux" "$(getenforce 2>/dev/null || printf 'n/a')"
fact "openssl / ca-certificates" "$(rpm -q openssl ca-certificates 2>/dev/null | tr '\n' ' ')"

# =============================================================================
# 2. Java
# =============================================================================
say "2/7 Java"
JAVA_CANDIDATES="$( { [ -n "$OH" ] && sed -n 's/^JAVA_HOME[A-Z0-9_]*=//p' "$OH/oui/.globalEnv.properties" 2>/dev/null;
                     [ -n "$OH" ] && [ -x "$OH/oracle_common/jdk/bin/java" ] && printf '%s\n' "$OH/oracle_common/jdk";
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
BJ="$OH/oracle_common/jdk"
fact "Bundled JDK (oracle_common/jdk)" "$( [ -x "$BJ/bin/java" ] && "$BJ/bin/java" -version 2>&1 | head -1 || printf 'none')"
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
    # product versions (registry.xml) - selects the patch list of KA1182
    runsh 30_inventory.txt "Installed distributions / features (inventory/registry.xml)" \
        "grep -oE '<(distribution|feature)[^>]* name=\"[^\"]*\"[^>]* version=\"[^\"]*\"' '$OH/inventory/registry.xml' | sed -E 's/.* name=\"([^\"]*)\".* version=\"([^\"]*)\".*/\1 \2/' | sort -u"
    # components that decide single patches (DB client, Perl, OHS, WebGate, Infrastructure bundles)
    runsh 33_components.txt "Patch-relevant components (comps.xml)" \
        "grep -oE 'COMP NAME=\"[^\"]*\" VER=\"[^\"]*\"' '$OH/inventory/ContentsXML/comps.xml' | grep -iE 'rdbms|client|perl|ohs|webgate|wls|weblogic|coherence|adf|jrf|opss|owsm|wsm|em|ums|webcenter|libovd|oamclient|forms|reports|jdk|dbclient' | sed 's/COMP NAME=//; s/ VER=/ /; s/\"//g' | sort -u"
    run 33_components.txt "DB client in the home (sqlplus -V)" "$OH/bin/sqlplus" -V
    run 33_components.txt "Perl in the home"                      "$OH/perl/bin/perl" -v
    runsh 33_components.txt "OHS / WebGate in the home" "ls -ld '$OH/ohs' '$OH/webgate' '$OH'/webgate/* 2>&1; ls '$OH'/ohs/bin/httpd* 2>&1"
    # every Oracle home of the central inventory (separate OHS / WebGate / DB client / old FMW homes)
    if [ -n "$INV" ] && [ -r "$INV/ContentsXML/inventory.xml" ]; then
        grep '<HOME ' "$INV/ContentsXML/inventory.xml" | grep -v 'REMOVED="T"' | sed -n 's/.*LOC="\([^"]*\)".*/\1/p' | while read -r h; do
            [ "$(readlink -f "$h")" = "$(readlink -f "$OH")" ] && continue
            if [ -x "$h/OPatch/opatch" ]; then
                run 34_other_homes.txt "opatch lspatches -oh $h" "$h/OPatch/opatch" lspatches -oh "$h"
            else
                printf '### %s: no OPatch (missing / not a patchable home)\n\n' "$h" >> "$OUT/34_other_homes.txt"
            fi
        done
    fi
    # OPatch prerequisites: inventory locks, ownership, rollback storage, free space
    runsh 35_opatch_prereq.txt "Inventory locks" "ls -la '${INV:-/nonexistent}/locks' 2>&1"
    runsh 35_opatch_prereq.txt "Owner / mode of ORACLE_HOME and inventory" "ls -ld '$OH' '$OH/inventory' '$OH/OPatch' '${INV:-/nonexistent}' 2>&1; id"
    runsh 35_opatch_prereq.txt "Files in the home NOT owned by this user (first 20)" "find '$OH' -xdev ! -user \"\$(id -un)\" 2>/dev/null | head -20"
    runsh 35_opatch_prereq.txt "Rollback storage (.patch_storage)" "du -sh '$OH/.patch_storage' 2>&1; ls '$OH/.patch_storage' 2>/dev/null | wc -l"
    runsh 35_opatch_prereq.txt "Free space: home / inventory / /tmp" "df -hP '$OH' '${INV:-/tmp}' /tmp 2>&1"
    runsh 35_opatch_prereq.txt "Last OPatch logs (cfgtoollogs/opatch)" "ls -lt --time-style=long-iso '$OH/cfgtoollogs/opatch' 2>/dev/null | head -15"
    runsh 35_opatch_prereq.txt "Last patch runs (apply / napply / rollback) with result" "for f in \$(ls -t '$OH'/cfgtoollogs/opatch/opatch*.log 2>/dev/null); do c=\$(grep -m1 -oE \"OPatch invoked as follows: '(apply|napply|rollback|nrollback)[^']*'\" \"\$f\"); [ -n \"\$c\" ] || continue; printf '%s | %s | %s\\n' \"\$(basename \$f)\" \"\${c#OPatch invoked as follows: }\" \"\$(grep -hE 'successfully (applied|rolled back)|OPatch (failed|stopped)|UtilSession failed|Prereq .* failed' \"\$f\" | sed 's/^\\[[^]]*\\] *//' | sort -u | tr '\\n' ' ' | cut -c1-300)\"; done | head -20"
    fact "Distributions" "$("$OH/oui/bin/viewInventory.sh" 2>/dev/null | sed -n 's/.*Distribution: //p' | sort -u | tr '\n' ';')"
    fact "OPatch" "$("$OP" version 2>/dev/null | sed -n 's/^OPatch Version: //p')"
    fact "Patches (lspatches)" "$("$OP" lspatches 2>/dev/null | grep -c '^[0-9]')"
    fact "Reports component in home" "$(ls "$OH"/inventory/Components 2>/dev/null | grep -ciE 'reports') entries"
    # comps.xml = the home inventory OPatch uses; Reports binaries on disk
    # without these entries are never patched by OPatch (2026-10-29)
    runsh 30_inventory.txt "Reports / Forms components in comps.xml (OPatch view)" \
        "grep -o 'COMP NAME=\"oracle\\.\\(reports\\|forms\\|developer\\)[^\"]*\" VER=\"[^\"]*\"' '$OH/inventory/ContentsXML/comps.xml' | sort -u"
    _rc="$(grep -o 'COMP NAME="oracle\.reports[^"]*"' "$OH/inventory/ContentsXML/comps.xml" 2>/dev/null | sort -u | wc -l)"
    _rb="$(ls "$OH/bin/rwserver" "$OH/bin/rwrun" 2>/dev/null | wc -l)"
    fact "Reports comps.xml / binaries" "$_rc component(s) / $_rb of rwserver,rwrun"
    [ "$_rc" -eq 0 ] && [ "$_rb" -gt 0 ] && \
        fact "!! Reports NOT REGISTERED" "binaries in the home but no oracle.reports component – OPatch would never patch them"
    fact "OHS component in home" "$(ls "$OH"/inventory/Components 2>/dev/null | grep -ciE 'ohs') entries"
    fact "Product versions (registry.xml)" "$(grep -oE '<distribution[^>]* name="[^"]*"[^>]* version="[^"]*"' "$OH/inventory/registry.xml" 2>/dev/null | sed -E 's/.* name="([^"]*)".* version="([^"]*)".*/\1 \2/' | sort -u | paste -sd';' -)"
    fact "DB client in home" "$("$OH/bin/sqlplus" -V 2>/dev/null | grep -oE 'Version [0-9.]+' | head -1)"
    fact "Perl in home" "$("$OH/perl/bin/perl" -e 'print $^V' 2>/dev/null)"
    fact "WebGate in home" "$( [ -d "$OH/webgate" ] && printf yes || printf no)"
    fact ".patch_storage" "$(du -sh "$OH/.patch_storage" 2>/dev/null | cut -f1)"
    fact "Free space of the home" "$(df -hP "$OH" 2>/dev/null | awk 'NR==2{print $4 " free of " $2}')"
    fact "Inventory locks" "$(ls "${INV:-/nonexistent}/locks" 2>/dev/null | wc -l) file(s)"
    fact "Other Oracle homes (inventory)" "$(grep '<HOME ' "${INV:-/x}/ContentsXML/inventory.xml" 2>/dev/null | grep -v 'REMOVED="T"' | sed -n 's/.*LOC="\([^"]*\)".*/\1/p' | grep -vx "$OH" | tr '\n' ' ')"
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
    # client JRE of the Forms users (Java alerts also concern the client JREs)
    runsh 44_forms_client.txt "JNLP j2se / java versions" "grep -Hn -iE 'j2se|<java ' '$OH'/forms/java/*.jnlp '$OH'/forms/templates/config/*.jnlp \$(find '$DH/config/fmwconfig' -name '*.jnlp' 2>/dev/null) 2>/dev/null | head -40"
    runsh 44_forms_client.txt "formsweb.cfg Java plug-in / client keys" "for f in \$(find '$DH/config/fmwconfig/servers' -name formsweb.cfg 2>/dev/null); do grep -Hn -iE '^(jpi_|baseHTMLjpi|webstart|fsal|java_version|jre)' \"\$f\"; done | head -40"
    runsh 44_forms_client.txt "FSAL / client jars (frmsal.jar)" "ls -l --time-style=long-iso '$OH'/forms/java/frmsal*.jar '$OH'/forms/java/frmall.jar 2>&1; unzip -p '$OH/forms/java/frmsal.jar' META-INF/MANIFEST.MF 2>/dev/null | grep -iE 'version|built'"
    fact "Domain version (config.xml)" "$(sed -n 's/.*<domain-version>\([^<]*\)<.*/\1/p' "$DH/config/config.xml" | head -1)"
    fact "Domain" "$(sed -n 's/.*<name>\([^<]*\)<\/name>.*/\1/p' "$DH/config/config.xml" | head -1)"
    fact "Servers (config.xml)" "$(awk '/<server>/{s=1} s&&/<name>/{gsub(/.*<name>|<\/name>.*/,"");printf "%s ",$0;s=0}' "$DH/config/config.xml")"
fi

# =============================================================================
# 5. Running processes
# =============================================================================
say "5/7 Processes"
runsh 50_processes.txt "WLS / Node Manager / Forms / Reports / OHS processes" \
    "ps -eo pid,ppid,user,lstart,etime,rss,args | grep -E 'weblogic\\.(Server|NodeManager)|frmweb|rwserver|rwengine|rwrun|httpd|nginx|NetworkServerControl' | grep -v grep"
runsh 50_processes.txt "Process tree of $(id -un) (other users are not collected)" "ps -u \"\$(id -un)\" fww -o pid,ppid,lstart,etime,rss,args"
fact "frmweb processes" "$(pgrep -c frmweb 2>/dev/null; true)"
# Which home do the running FMW processes come from? (2026-10-29)
runsh 50_processes.txt "Binary (/proc/<pid>/exe) of WLS / Forms / Reports processes" \
    "for p in \$(pgrep -f 'weblogic\\.(Server|NodeManager)|frmweb|rwserver|rwEng|rwengine'); do printf '%s %s\n' \$p \"\$(readlink -f /proc/\$p/exe 2>/dev/null)\"; done | grep -E '/(java|frmweb|rwserver|rwrun|rwengine)\$'"
_jdk="$(sed -n 's/^JAVA_HOME=//p' "${OH:-/x}/oui/.globalEnv.properties" 2>/dev/null | head -1)"
_foreign="$(for p in $(pgrep -f 'weblogic\.(Server|NodeManager)|frmweb|rwserver|rwEng|rwengine' 2>/dev/null); do readlink -f "/proc/$p/exe" 2>/dev/null; done \
    | grep -E '/(java|frmweb|rwserver|rwrun|rwengine)$' | sort -u | grep -v "^$(readlink -f "${OH:-/nonexistent}")/" | grep -v "^$(readlink -f "${_jdk:-/nonexistent}")/" | tr '\n' ' ')"
fact "Processes outside ORACLE_HOME / JDK" "${_foreign:-none}"
fact "WLS servers running" "$(ps -eo args= | sed -n 's/.*-Dweblogic[.]Name=\([^ ]*\).*/\1/p' | sort -u | tr '\n' ' ')"
# Apache Derby = WebLogic evaluation database, started by every startWebLogic.sh
# while DERBY_FLAG is not false (80-FMW-Architecture/fmw_derby_history.md)
_dpid="$(pgrep -f 'org\.apache\.derby\.drda\.NetworkServerControl start' 2>/dev/null | head -1)"
_dlsn="$(ss -ltn 2>/dev/null | awk '$4 ~ /:1527$/ {print $4}' | head -1)"
if [ -n "$_dpid" ] || [ -n "$_dlsn" ]; then
    fact "Derby network server" "running (pid ${_dpid:-?}, ${_dlsn:-1527})"
else
    fact "Derby network server" "not running"
fi
if [ -n "$DH" ]; then
    grep -qE '^[[:space:]]*(export[[:space:]]+)?DERBY_FLAG="?false"?' "$DH/bin/setUserOverrides.sh" 2>/dev/null \
        && fact "DERBY_FLAG (setUserOverrides)" "false" || fact "DERBY_FLAG (setUserOverrides)" "not set (Derby starts with every server)"
fi
unset _dpid _dlsn

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
# OS web servers in front of WebLogic (configuration is usually world-readable;
# what the oracle user cannot read is reported, not forced)
runsh 61_webserver.txt "Versions" "nginx -v 2>&1; httpd -v 2>&1; rpm -q nginx httpd mod_ssl 2>&1"
runsh 61_webserver.txt "Which process owns 80 / 443 (needs root to show the pid)" "ss -ltnp 2>/dev/null | grep -E ':(80|443|8080|8443|7777|4443) '"
runsh 61_webserver.txt "WebLogic proxy plug-in for Apache (mod_wl*)" "ls -l /etc/httpd/modules/mod_wl* /usr/lib64/httpd/modules/mod_wl* /etc/apache2/modules/mod_wl* /usr/local/apache2/modules/mod_wl* 2>&1"
# every web server (running or installed, standalone OHS domains too) with all
# includes inlined, masked; routing table in front (ihw_tools_lib ihwt_webtier_*)
mapfile -t WT_FOUND < <(ihwt_webtier_find "$DH")
{
    printf '### Web servers found (type;main configuration)\n'
    printf '%s\n' "${WT_FOUND[@]:-none}"
    printf '\n### Routing (%s)\n' "$IHWT_WT_HEAD"
    for e in "${WT_FOUND[@]}"; do ihwt_webtier_flatten "${e%%;*}" "${e#*;}" | ihwt_webtier_routes "${e%%;*}" "${e#*;}"; done
    printf '\n### Rated directives (type;conf;key;value;file)\n'
    for e in "${WT_FOUND[@]}"; do ihwt_webtier_flatten "${e%%;*}" "${e#*;}" | ihwt_webtier_settings "${e%%;*}" "${e#*;}"; done
    printf '\n'
} >> "$OUT/61_webserver.txt"
for e in "${WT_FOUND[@]}"; do
    # OHS of this domain: 43_ohs_config.txt has the files already
    case "${e#*;}" in "$DH"/*) continue ;; esac
    { printf '### configuration %s (%s) - includes inlined, #@@ = file markers\n' "${e#*;}" "${e%%;*}"
      ihwt_webtier_flatten "${e%%;*}" "${e#*;}" | mask; printf '\n'; } >> "$OUT/61_webserver.txt"
done
fact "Web tier" "$(printf '%s\n' "${WT_FOUND[@]}" | cut -d';' -f1 | sort | uniq -c | awk '{printf "%s%s x%s", (NR>1?", ":""), $2, $1}')"
fact "Web tier unreadable" "$(for e in "${WT_FOUND[@]}"; do ihwt_webtier_flatten "${e%%;*}" "${e#*;}"; done | grep -c '^#@@ UNREADABLE') file(s)"
# built with the IHateWeblogic library? (decides the patch route of the patch
# analysis: library scripts 07-Maintenance/8x- or the cookbook)
_ihwlib="$(for d in "$HOME" "${ORACLE_BASE:-}" "$(dirname "${OH:-/nonexistent}")" /development /u01/app/oracle /opt; do
              [ -n "$d" ] && [ -d "$d" ] && timeout 20 find "$d" -maxdepth 4 -path '*/00-Setup/IHateWeblogic_lib.sh' -type f 2>/dev/null
          done | head -1)"
if [ -n "$_ihwlib" ]; then
    _ihwroot="$(dirname "$(dirname "$_ihwlib")")"
    fact "IHateWeblogic library" "$_ihwroot (environment.conf -> $(readlink "$_ihwroot/environment.conf" 2>/dev/null || printf 'none'); shell switcher $( [ -f "$HOME/.bashrc.d/ihw_env.sh" ] && printf yes || printf no))"
    runsh 30_inventory.txt "IHateWeblogic library" "ls -l '$_ihwroot/environment.conf' 2>&1; git -C '$_ihwroot' log -1 --format='%h %ci' 2>/dev/null"
else
    fact "IHateWeblogic library" "none"
fi
unset _ihwlib _ihwroot

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
ihwt_pack "$OUTBASE" "$NAME" "$ENCRYPT" || exit 2
ARCH="$IHWT_ARCHIVE"
$KEEP || rm -rf "${OUTBASE:?}/${NAME:?}"
say "Archive : $OUTBASE/$ARCH ($(du -h "$OUTBASE/$ARCH" 2>/dev/null | cut -f1))"
say "SHA-256 : $OUTBASE/$ARCH.sha256"
$ENCRYPT && say "Decrypt : openssl enc -d $IHWT_ENC_OPTS -in $ARCH -out ${ARCH%.enc}"
$KEEP && say "Kept    : $OUT (00_summary.txt = key facts)"
say "Secrets are masked; host names, IPs and paths are included - send the encrypted archive."
exit 0
