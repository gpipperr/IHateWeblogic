#!/bin/bash
# =============================================================================
# Script   : collect_ords_apex.sh
# Purpose  : Collect the ORDS / APEX environment of a host for the third
#            analysis (customer-analyse/analyse_ords_apex.sh):
#            - every ORDS installation: standalone (Jetty), Tomcat, WebLogic
#              deployment, systemd units, stopped / unpacked ones, the old
#              configuration layout before ORDS 22 (ihwt_ords_find)
#            - version (jar names of ords.war + "ords --version"), Java,
#              configuration of every pool ("ords config list
#              --include-defaults", masked copies of settings.xml / pool.xml),
#              file-based ORDS users ("ords config user list", no passwords)
#            - APEX images (/i/): directory + apex_version.txt - the APEX
#              version is only "guessed" from the images, no database connect
#            - web tier routes to ORDS / /i/, fixed Authorization headers, AJP
#            - security: listen address of the ORDS ports, the additional
#              features (Database Actions, REST Enabled SQL, Database API),
#              Tomcat AJP connectors / version / tomcat-users.xml
#            - logs of the last --log-days days, AGGREGATED (requests per day,
#              status classes, hits on the SQL endpoints, errors per day)
#            READ-ONLY: writes only into the output directory. Runs the ORDS
#            program read-only ("--version", "config list", "config user
#            list" - a JVM for a few seconds each, timeout 90 s) unless
#            --no-exec; skipped when less than 512 MB memory is available.
#            Secrets are masked (the wallet is never copied, passwords of
#            "config list" are shown as ****** by ORDS itself).
#            No IHateWeblogic library - bash + coreutils (+ unzip, openssl) and
#            the shared helpers ihw_tools_lib.sh next to this script.
# Call     : ./collect_ords_apex.sh [-t OUTBASE] [--no-encrypt] [--keep]
#                                   [--no-exec] [--log-days N] [--ords DIR]...
#            -t          base directory of the output (default /tmp)
#            --no-exec   do not run the ORDS program (files only)
#            --log-days  days of logs to aggregate (default 7)
#            --ords DIR  more ORDS homes / config directories to look at
#                        (repeatable) - when the discovery finds nothing
#            --no-encrypt / --keep  as collect_fmw_env.sh
# Runs as  : the owner of the ORDS installation (oracle), not root
# Output   : <OUTBASE>/ords_collect_<host>_<yyyymmdd_hhmmss>.zip.enc (+ .sha256)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : 80-FMW-Architecture/ords_architecture.md, 12-APEX-Ords/
# =============================================================================

set -u
umask 077
VERSION="2026-11-27.1"   # bump on every change – shown in 00_summary.txt

_IHWT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ihw_tools_lib.sh
. "$_IHWT_DIR/ihw_tools_lib.sh" || { printf 'ihw_tools_lib.sh missing next to %s\n' "$0" >&2; exit 2; }

OUTBASE="/tmp"; ENCRYPT=true; KEEP=false; EXEC=true; LOG_DAYS=7; IHWT_ORDS_EXTRA=""
while [ $# -gt 0 ]; do
    case "$1" in
        -t) OUTBASE="${2:-/tmp}"; shift ;;
        --no-encrypt) ENCRYPT=false ;;
        --keep) KEEP=true ;;
        --no-exec) EXEC=false ;;
        --log-days) LOG_DAYS="${2:-7}"; shift ;;
        --ords) IHWT_ORDS_EXTRA="$IHWT_ORDS_EXTRA ${2:-}"; shift ;;
        -h|--help) sed -n '2,42p' "$0"; printf 'Version: %s\n' "$VERSION"; exit 0 ;;
        -V|--version) printf '%s\n' "$VERSION"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
[[ "$LOG_DAYS" =~ ^[0-9]+$ ]] || { printf -- '--log-days N\n' >&2; exit 2; }
export IHWT_ORDS_EXTRA

HOST="$(hostname -s 2>/dev/null || hostname)"
TS="$(date +%Y%m%d_%H%M%S)"
OUTBASE="$(cd "$OUTBASE" 2>/dev/null && pwd)" || { printf 'Output directory does not exist\n' >&2; exit 2; }
NAME="ords_collect_${HOST}_${TS}"
OUT="$OUTBASE/$NAME"
ihwt_git_guard "$OUTBASE" "$NAME.zip" || exit 2
if $ENCRYPT; then
    ihwt_read_passphrase "ORDS collector archive" || { printf '  -> or use --no-encrypt (plain ZIP, masked)\n' >&2; exit 2; }
fi
mkdir -p "$OUT" || { printf 'Cannot create %s\n' "$OUT" >&2; exit 2; }
trap 'IHWT_PASS=""' EXIT
SUM="$OUT/00_summary.txt"

# --- helpers (as collect_fmw_env.sh) -------------------------------------------
mask() { ihwt_mask; }
# key;value[;source] lines: masked + every key that names a secret (old pool.xml
# with db.password in clear text, before the wallet)
mask_kv() { ihwt_mask | awk -F";" -v OFS=";" 'tolower($1) ~ /pass|secret|pwd|credential/ && $2 != "" {$2="***MASKED***"} {print}'; }
runsh() {
    local f="$OUT/$1" t="$2" c="$3"
    { printf '### %s\n### $ %s\n' "$t" "$c"
      timeout 120 bash -c "$c" 2>&1 | mask
      printf '### rc=%s\n\n' "${PIPESTATUS[0]}"; } >> "$f"
}
copy() {
    local dst="$OUT/$1" src="$2"
    [ -r "$src" ] || return 0
    { printf '### file: %s (%s bytes, %s)\n' "$src" "$(wc -c < "$src")" "$(date -r "$src" '+%Y-%m-%d %H:%M' 2>/dev/null)"
      mask < "$src"; printf '\n'; } >> "$dst"
}
fact() { printf '%-28s %s\n' "$1" "$2" >> "$SUM"; }
say()  { printf '  %s\n' "$*"; }
line() { printf '%s\n' "$2" >> "$OUT/$1"; }    # machine-readable line (fields without ';')
nosemi() { printf '%s' "$*" | tr ';\n' ',,'; }

say "collect_ords_apex.sh version $VERSION"
say "Output: $OUT"
{
    printf 'ORDS / APEX collection – %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '%s\n\n' "collect_ords_apex.sh version $VERSION (ihw_tools_lib $(ihwt_lib_version), read-only, secrets masked)"
} > "$SUM"
fact "Host" "$(hostname -f 2>/dev/null || hostname)"
fact "User" "$(id)"
fact "OS" "$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-?}")"
MEM_AVAIL="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
fact "Memory available MB" "${MEM_AVAIL:-?}"
if $EXEC && [ "${MEM_AVAIL:-0}" -lt 512 ]; then EXEC=false; fact "ORDS program calls" "skipped (less than 512 MB available)"
elif $EXEC; then fact "ORDS program calls" "yes (--version, config list, config user list)"
else fact "ORDS program calls" "no (--no-exec)"; fi

# =============================================================================
# 1. Discovery
# =============================================================================
say "1/7 Discovery"
mapfile -t INST < <(ihwt_ords_find)
{ printf '### ORDS installations: ords;id;mode;home;war;config;pid;unit;user;ports\n'
  printf '%s\n' "${INST[@]}"; printf '### rc=0\n\n'; } >> "$OUT/10_instances.txt"
# instances = everything except unpacked software
mapfile -t RUNI < <(printf '%s\n' "${INST[@]}" | awk -F';' '$3 !~ /^software/ && NF > 5')
fact "ORDS installations" "$( [ ${#RUNI[@]} -eq 0 ] && printf 'none' || printf '%s\n' "${RUNI[@]}" | awk -F';' '{c[$3]++} END {for (m in c) s=s (s==""?"":", ") c[m] " " m; print NR " (" s ")"}')"
fact "ORDS software dirs" "$(printf '%s\n' "${INST[@]}" | awk -F';' '$3 ~ /^software/ {n++; if ($3=="software") u++} END {printf "%d (%d not used by an instance)", n, u}')"
if [ ${#INST[@]} -eq 0 ]; then
    say "no ORDS found (use --ords DIR if it lives somewhere else)"
fi
for l in "${RUNI[@]}"; do
    IFS=';' read -r _ id mode home war cfg pid unit usr ports <<< "$l"
    [ "$pid" != - ] && runsh 10_instances.txt "process of $id (pid $pid)" "tr '\\0' ' ' < /proc/$pid/cmdline; printf '\\n'; ps -o pid,user,lstart,etime,rss -p $pid"
    if [ "$unit" != - ]; then
        runsh 10_instances.txt "systemd unit $unit" "systemctl cat '$unit'; systemctl show -p ActiveState,SubState,UnitFileState,User,MainPID,ExecMainStartTimestamp '$unit'"
    fi
done

# --- per instance: java, ords command ----------------------------------------
_java_of() {   # pid unit home -> java binary
    local pid="$1" unit="$2" home="$3" j=""
    [ "$pid" != - ] && j="$(readlink -f "/proc/$pid/exe" 2>/dev/null)"
    if [ -z "$j" ] && [ "$unit" != - ]; then
        j="$(systemctl cat "$unit" 2>/dev/null | sed -n 's/^Environment="\{0,1\}JAVA_HOME=\([^" ]*\).*/\1/p' | tail -1)"; [ -n "$j" ] && j="$j/bin/java"
    fi
    [ -z "$j" ] && [ -n "${JAVA_HOME:-}" ] && j="$JAVA_HOME/bin/java"
    [ -z "$j" ] && j="$(command -v java 2>/dev/null)"
    printf '%s' "$j"
}
_ords_run() {  # java home war cfg args... -> output of the ORDS program (timeout 90 s)
    local j="$1" home="$2" war="$3" cfg="$4"; shift 4
    [ -x "$j" ] || return 1
    if [ -x "$home/bin/ords" ]; then
        JAVA_HOME="$(dirname "$(dirname "$j")")" timeout 90 "$home/bin/ords" --config "$cfg" "$@" 2>&1
    elif [ -f "$war" ]; then
        timeout 90 "$j" -jar "$war" --config "$cfg" "$@" 2>&1
    else return 1; fi
}

# =============================================================================
# 2. Versions + Java
# =============================================================================
say "2/7 Versions"
VERS=""
for l in "${INST[@]}"; do
    IFS=';' read -r _ id mode home war cfg pid unit usr ports <<< "$l"
    v="-"; [ -f "$war" ] && v="$(ihwt_ords_war_version "$war")"
    [ -d "$war" ] && v="$(ls "$war"/WEB-INF/lib/ 2>/dev/null | grep -oE '^ords-[a-z-]+-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | grep -oE '[0-9.]+$' | sort | uniq -c | sort -rn | awk 'NR==1 {print $2}')"
    line 20_version.txt "version;$id;$mode;jar;${v:--}"
    case "$mode" in software*) continue ;; esac
    VERS="$VERS${VERS:+, }$id ${v:-?}"
    j="$(_java_of "$pid" "$unit" "$home")"
    # Java only where it is known: process or unit (not the PATH java for a stopped copy)
    if [ "$pid" != - ] || [ "$unit" != - ]; then
        jv="-"; [ -x "$j" ] && jv="$("$j" -version 2>&1 | head -1 | tr ';' ',')"
        line 20_version.txt "java;$id;${j:--};$jv"
    fi
    if $EXEC && [ "$cfg" != - ] && [ -r "$cfg" ]; then
        ev="$(_ords_run "$j" "$home" "$war" "$cfg" --version | sed -n 's/.*Oracle REST Data Services[[:space:]]*\([0-9][^[:space:]]*\).*/\1/p' | head -1)"
        line 20_version.txt "version;$id;$mode;exec;${ev:-not readable}"
    fi
done
fact "ORDS versions" "${VERS:-none}"
fact "ORDS Java" "$(awk -F';' '$1=="java" {s=s (s==""?"":", ") $2 " " $4} END {print (s=="" ? "-" : s)}' "$OUT/20_version.txt" 2>/dev/null)"

# =============================================================================
# 3. Configuration: pools, features, users, wallet, old layout
# =============================================================================
say "3/7 Configuration"
for l in "${RUNI[@]}"; do
    IFS=';' read -r _ id mode home war cfg pid unit usr ports <<< "$l"
    [ "$cfg" != - ] && [ -d "$cfg" ] || continue
    j="$(_java_of "$pid" "$unit" "$home")"
    if [ "$mode" = old-layout ]; then
        copy 30_config.txt "$cfg/defaults.xml"
        for f in "$cfg"/conf/*.xml; do copy 30_config.txt "$f"; done
        sed -n 's#.*<entry key="\([^"]*\)">\([^<]*\)</entry>.*#\1;\2#p' "$cfg/defaults.xml" 2>/dev/null | mask_kv \
            | while IFS=';' read -r k v; do line 30_config.txt "cfg;$id;global;$k;$(nosemi "$v");file"; done
        continue
    fi
    copy 30_config.txt "$cfg/global/settings.xml"
    pools="$(for d in "$cfg"/databases/*/; do [ -d "$d" ] && basename "$d"; done)"
    for pl in $pools; do
        copy 30_config.txt "$cfg/databases/$pl/pool.xml"
        for w in "$cfg/databases/$pl"/wallet/*; do
            [ -e "$w" ] && line 30_config.txt "wallet;$id;$pl;$w;$(stat -c '%a %U:%G' "$w" 2>/dev/null)"
        done
    done
    got=false
    if $EXEC; then
        for pl in ${pools:-default}; do
            out="$(_ords_run "$j" "$home" "$war" "$cfg" config --db-pool "$pl" list --include-defaults)" || continue
            printf '%s\n' "$out" | grep -q -- '^-----' || continue
            got=true
            # columns from the dash line (Setting / Value / Source - values may hold blanks)
            printf '%s\n' "$out" | awk '
                /^-----/ { n=0; for (i=1; i<=length($0); i++) if (substr($0,i,1)=="-" && (i==1 || substr($0,i-1,1)==" ")) st[++n]=i; on=1; next }
                on && NF >= 1 { k=substr($0, st[1], st[2]-st[1]); v=substr($0, st[2], st[3]-st[2]); s=substr($0, st[3])
                    gsub(/^ +| +$/, "", k); gsub(/^ +| +$/, "", v); gsub(/^ +| +$/, "", s); if (k != "") print k ";" v ";" s }' | mask_kv \
                | while IFS=';' read -r k v s; do line 30_config.txt "cfg;$id;$pl;$k;$(nosemi "$v");$s"; done
        done
        uo="$(_ords_run "$j" "$home" "$war" "$cfg" config user list)"
        printf '%s\n' "$uo" | awk '/^-----/ {on=1; next} on && NF >= 1 {u=$1; r=""; for (i=2; i<=NF; i++) r=r (r==""?"":" ") $i; print u ";" r}' \
            | while IFS=';' read -r u r; do line 30_config.txt "user;$id;$u;$(nosemi "$r")"; done
    fi
    if ! $got; then   # files only: global + every pool, source = file
        sed -n 's#.*<entry key="\([^"]*\)">\([^<]*\)</entry>.*#\1;\2#p' "$cfg/global/settings.xml" 2>/dev/null | mask_kv \
            | while IFS=';' read -r k v; do line 30_config.txt "cfg;$id;global;$k;$(nosemi "$v");file"; done
        for pl in $pools; do
            sed -n 's#.*<entry key="\([^"]*\)">\([^<]*\)</entry>.*#\1;\2#p' "$cfg/databases/$pl/pool.xml" 2>/dev/null | mask_kv \
                | while IFS=';' read -r k v; do line 30_config.txt "cfg;$id;$pl;$k;$(nosemi "$v");file"; done
        done
    fi
    # file-based users (ords config user add): credentials file, never its content
    for f in "$cfg/global/credentials" "$cfg/credentials"; do
        [ -f "$f" ] && line 30_config.txt "credfile;$id;$f;$(grep -c . "$f" 2>/dev/null) entries;$(stat -c '%a %U:%G' "$f" 2>/dev/null)"
    done
done
CFGF="$OUT/30_config.txt"
fact "ORDS pools" "$(awk -F';' '$1=="cfg" && $3!="global" {p[$2 "/" $3]=1} END {for (k in p) s=s (s==""?"":", ") k; print (s=="" ? "-" : s)}' "$CFGF" 2>/dev/null)"
# features per pool (pool value, else global, else ORDS default false / enabled)
_feat() { awk -F';' -v id="$1" -v pl="$2" -v k="$3" '$1=="cfg" && $2==id && $4==k { if ($3==pl) p=$5; else if ($3=="global") g=$5 } END {print (p != "" ? p : g)}' "$CFGF" 2>/dev/null; }
FEATS=""
for l in "${RUNI[@]}"; do
    IFS=';' read -r _ id mode _ _ cfg _ <<< "$l"
    for pl in $(awk -F';' -v id="$id" '$1=="cfg" && $2==id && $3!="global" {print $3}' "$CFGF" 2>/dev/null | sort -u); do
        sdw="$(_feat "$id" "$pl" feature.sdw)"; rsq="$(_feat "$id" "$pl" restEnabledSql.active)"
        dba="$(_feat "$id" "$pl" database.api.enabled)"; gql="$(_feat "$id" "$pl" feature.graphql)"
        # the installer choice "additional features" (1 Database Actions ... 5 None)
        if [ "$sdw" = true ]; then ch=1
        elif [ "$rsq" = true ] && [ "$dba" = true ]; then ch=2
        elif [ "$rsq" = true ]; then ch=3
        elif [ "$dba" = true ]; then ch=4
        else ch=5; fi
        line 70_security.txt "feature;$id;$pl;${sdw:-false};${rsq:-false};${dba:-false};${gql:-default};$ch"
        FEATS="$FEATS${FEATS:+, }$id/$pl choice $ch"
    done
done
fact "ORDS features" "${FEATS:--} (1 Database Actions, 2 REST SQL + DB API, 3 REST SQL, 4 DB API, 5 none)"
fact "ORDS file users" "$(awk -F';' '$1=="user" {n++} $1=="credfile" {f++} END {printf "%d user(s), %d credentials file(s)", n, f}' "$CFGF" 2>/dev/null)"

# =============================================================================
# 4. Web tier: routes to ORDS / /i/, fixed Authorization headers, AJP
# =============================================================================
say "4/7 Web tier"
ORDS_PORTS="$(printf '%s\n' "${RUNI[@]}" | awk -F';' '$10 != "-" {print $10}' | tr ',' '\n' | sort -u | paste -sd'|' -)"
for l in "${RUNI[@]}"; do   # configured port of stopped instances too
    IFS=';' read -r _ id _ _ _ cfg _ <<< "$l"; p="$(_ihwt_ords_cfgval "$cfg" standalone.http.port)"
    [ -n "$p" ] && ORDS_PORTS="${ORDS_PORTS:+$ORDS_PORTS|}$p"
done
mapfile -t WT_FOUND < <(ihwt_webtier_find)
WTR="$OUT/50_webtier.txt"
printf '### routes to ORDS / APEX images (%s)\n' "$IHWT_WT_HEAD" >> "$WTR"
for _e in "${WT_FOUND[@]}"; do
    _t="${_e%%;*}"; _m="${_e#*;}"
    ihwt_webtier_flatten "$_t" "$_m" > "$OUT/.wt_flat" 2>/dev/null
    ihwt_webtier_routes "$_t" "$_m" < "$OUT/.wt_flat" 2>/dev/null \
        | awk -F';' -v p="${ORDS_PORTS:-none}" '$7 ~ /^\/(ords|i|apex|ords\/)/ || $7 ~ /ords/ || $8 ~ (":(" p ")([^0-9]|$)") {print}' >> "$WTR"
    # fixed Authorization header towards a backend = one login for everybody
    grep -nE '^[^#]*(proxy_set_header|RequestHeader[[:space:]]+(set|append|add|merge))[[:space:]]+"?Authorization' "$OUT/.wt_flat" 2>/dev/null \
        | sed -E 's/(Basic|Bearer)[[:space:]]+[^";[:space:]]+/\1 ***MASKED***/I' | while IFS= read -r x; do line 70_security.txt "authhdr;$_t;$_m;$(nosemi "$x")"; done
    # AJP towards a backend (mod_proxy_ajp / mod_jk)
    grep -nE '^[^#]*(ajp://|JkMount|JkWorkersFile)' "$OUT/.wt_flat" 2>/dev/null | while IFS= read -r x; do line 70_security.txt "ajp;web;$_t;$(nosemi "$x")"; done
done
rm -f "$OUT/.wt_flat"
printf '### rc=0\n\n' >> "$WTR"
fact "Web tier routes to ORDS" "$(grep -c '^[^#]' "$WTR" 2>/dev/null) (web servers: $(printf '%s\n' "${WT_FOUND[@]}" | cut -d';' -f1 | sort -u | paste -sd' ' -))"

# =============================================================================
# 5. APEX images (/i/): web server static dirs, ORDS static path, Tomcat i/
# =============================================================================
say "5/7 APEX images"
{
    awk -F';' '$8 ~ /^static / {d=$8; sub(/^static /, "", d); print d "\t" $1 " " $7}' "$WTR" 2>/dev/null
    for l in "${RUNI[@]}"; do
        IFS=';' read -r _ id mode home _ cfg _ <<< "$l"
        d="$(_ihwt_ords_cfgval "$cfg" standalone.static.path)"; [ -n "$d" ] && printf '%s\tords %s static %s\n' "$d" "$id" "$(_ihwt_ords_cfgval "$cfg" standalone.static.context.path)"
        [ "$mode" = tomcat ] && [ -d "$home/webapps/i" ] && printf '%s\ttomcat %s /i/\n' "$home/webapps/i" "$id"
    done
    roots=""; for f in /u01 /u02 /opt /app /srv /oracle /var/www; do [ -d "$f" ] && roots="$roots $f"; done
    [ -n "$roots" ] && timeout 60 find $roots -maxdepth 6 -name apex_version.txt -type f 2>/dev/null | grep -v -e '/\.patch_storage/' -e '/apex/images/' \
        | while read -r f; do printf '%s\t-\n' "$(dirname "$f")"; done
} | awk -F'\t' '{d=$1; sub(/\/$/, "", d); if (!(d in s) || s[d] == "-") s[d]=$2} END {for (d in s) print d "\t" s[d]}' | sort \
  | while IFS=$'\t' read -r d by; do
      [ -d "$d" ] || continue
      v="$(ihwt_apex_version "$d")"
      line 40_apex_images.txt "apex;$d;${v:--};$(date -r "$d/apex_version.txt" '+%Y-%m-%d' 2>/dev/null || printf -- -);$(nosemi "$by")"
  done
fact "APEX images" "$(awk -F';' '$1=="apex" {s=s (s==""?"":", ") $3 " (" $2 ")"} END {print (s=="" ? "none found" : s)}' "$OUT/40_apex_images.txt" 2>/dev/null)"

# =============================================================================
# 6. Security: listen addresses, firewall, Tomcat (AJP, version, users)
# =============================================================================
say "6/7 Security"
for l in "${RUNI[@]}"; do
    IFS=';' read -r _ id mode home war cfg pid unit usr ports <<< "$l"
    for p in ${ports//,/ }; do
        [ "$p" = - ] && continue
        ss -Hltn 2>/dev/null | awk -v p="$p" '{n=split($4, x, ":"); if (x[n]==p) print $4}' | sort -u | while read -r a; do
            case "$a" in 127.*|'[::1]'*|'[::ffff:127.'*) sc=loopback ;; *) sc=network ;; esac
            line 70_security.txt "listen;$id;$a;$sc"
        done
    done
    [ "$mode" = standalone-stopped ] || [ "$mode" = not-running ] && line 70_security.txt "listen;$id;$(_ihwt_ords_cfgval "$cfg" standalone.binds):$(_ihwt_ords_cfgval "$cfg" standalone.http.port);configured"
    if [ "${mode%-stopped}" = tomcat ]; then
        tv="$(unzip -p "$home/lib/catalina.jar" org/apache/catalina/util/ServerInfo.properties 2>/dev/null | sed -n 's/^server\.number=//p')"
        [ -z "$tv" ] && tv="$(unzip -p "${CATALINA_HOME:-$home}/lib/catalina.jar" org/apache/catalina/util/ServerInfo.properties 2>/dev/null | sed -n 's/^server\.number=//p')"
        line 70_security.txt "tomcat;$id;version;${tv:-?}"
        # comments removed first (a commented-out AJP connector is no finding)
        awk 'BEGIN{RS="^$"} { t=$0; o=""; while ((i=index(t, "<!--")) > 0) { o=o substr(t, 1, i-1); t=substr(t, i+4); j=index(t, "-->"); if (!j) {t=""; break}; t=substr(t, j+3) }; printf "%s", o t }' "$home/conf/server.xml" 2>/dev/null \
            | awk 'BEGIN{RS="<"} /^Connector/ && /AJP/ {gsub(/[\n\t]+/, " "); sub(/>[^>]*$/, ">"); print "<" $0}' \
            | sed -E 's/([Ss]ecret=")[^"]*/\1***MASKED***/' | mask | while IFS= read -r x; do line 70_security.txt "ajp;tomcat;$id;$(nosemi "$x")"; done
        n="$(grep -c '<user[^>]*password=' "$home/conf/tomcat-users.xml" 2>/dev/null)"
        line 70_security.txt "tomcatusers;$id;${n:-0}"
        copy 30_config.txt "$home/conf/server.xml"
    fi
done
FW="$(timeout 10 firewall-cmd --state 2>&1 | grep -oE '^(running|not running)' | head -1)"
[ -z "$FW" ] && { command -v firewall-cmd >/dev/null 2>&1 && FW="not readable (no root)" || FW="not installed"; }
line 70_security.txt "firewalld;state;$FW"
case "$FW" in running) line 70_security.txt "firewalld;open;$(nosemi "$(timeout 10 firewall-cmd --list-ports 2>/dev/null) $(timeout 10 firewall-cmd --list-services 2>/dev/null)")" ;; esac
SECF="$OUT/70_security.txt"
fact "ORDS listen" "$(awk -F';' '$1=="listen" {s=s (s==""?"":", ") $2 " " $3 " (" $4 ")"} END {print (s=="" ? "-" : s)}' "$SECF" 2>/dev/null)"
fact "ORDS AJP / auth headers" "$(awk -F';' '$1=="ajp" {a++} $1=="authhdr" {h++} END {printf "%d AJP, %d fixed Authorization header(s)", a, h}' "$SECF" 2>/dev/null)"

# =============================================================================
# 7. Logs of the last N days - aggregated (no single request, no client IP)
# =============================================================================
say "7/7 Logs (last $LOG_DAYS days)"
LIM="$(date -d "-$LOG_DAYS days" +%Y-%m-%d)"
LOGF="$OUT/60_logs.txt"
for l in "${RUNI[@]}"; do
    IFS=';' read -r _ id mode home war cfg pid unit usr ports <<< "$l"
    acc=""; errs=""
    a="$(_ihwt_ords_cfgval "$cfg" standalone.access.log)"
    [ -n "$a" ] && [ -d "$a" ] && acc="$(find "$a" -maxdepth 1 -type f -newermt "$LIM" \( -name 'ords_*.log' -o -name '*access*' \) ! -name 'ords_sys*' ! -name 'ords_std*' 2>/dev/null)"
    [ "$mode" = tomcat ] && acc="$acc $(find "$home/logs" -maxdepth 1 -type f -newermt "$LIM" -name '*access_log*' 2>/dev/null)"
    # error logs: java.util.logging file of the instance, stdout / stderr of the unit, catalina.out
    lp="$(sed -n 's/^java\.util\.logging\.FileHandler\.pattern=//p' "$cfg/global/logging.properties" 2>/dev/null | head -1)"
    [ -n "$lp" ] && errs="$(ls ${lp//%g/*} 2>/dev/null)"
    if [ "$unit" != - ]; then
        errs="$errs $(systemctl cat "$unit" 2>/dev/null | sed -n 's/^Standard\(Output\|Error\)=\(append\|file\)://p' | sed "s/%i/$id/g")"
    fi
    [ "$mode" = tomcat ] && errs="$errs $home/logs/catalina.out"
    line 60_logs.txt "logfiles;$id;access;$(nosemi "$(printf '%s ' $acc)")"
    line 60_logs.txt "logfiles;$id;errors;$(nosemi "$(printf '%s ' $errs)")"
    # access log (NCSA): day, status class, internal / external client, SQL endpoints
    [ -n "${acc// /}" ] && cat $acc 2>/dev/null | awk -v id="$id" -v lim="$LIM" '
        BEGIN { split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " "); for (i=1; i<=12; i++) mo[m[i]]=sprintf("%02d", i) }
        match($0, /\[[0-9]+\/[A-Za-z]+\/[0-9]+/) {
            d=substr($0, RSTART+1, RLENGTH-1); split(d, x, "/"); day=x[3] "-" mo[x[2]] "-" sprintf("%02d", x[1])
            if (day < lim) next
            st=""; if (match($0, /" [0-9][0-9][0-9] /)) st=substr($0, RSTART+2, 3)
            ip=$1; ext=(ip ~ /^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|::1|-)/) ? "int" : "ext"
            req=""; if (match($0, /"[A-Z]+ [^ "]+/)) { req=substr($0, RSTART+1, RLENGTH-1); sub(/^[A-Z]+ /, "", req) }
            n[day]++; c[day, substr(st,1,1)]++; e[day, ext]++
            ep=""
            if (req ~ /\/sql-developer|\/_sdw/) ep="database_actions"; else if (req ~ /\/_\/sql/) ep="rest_enabled_sql"
            else if (req ~ /\/_\/db-api/) ep="database_api"; else if (req ~ /\/graphql/) ep="graphql"
            else if (req ~ /\/_\/landing/) ep="landing"; else if (req ~ /\/apex|f\?p=|\/r\//) ep="apex"
            if (ep != "") { h[ep]++; if (st ~ /^2/) ok[ep]++ }
        }
        END {
            for (d in n) printf "access;%s;%s;%d;%d;%d;%d;%d;%d;%d\n", id, d, n[d], c[d,"2"], c[d,"3"], c[d,"4"], c[d,"5"], e[d,"int"], e[d,"ext"]
            for (k in h) printf "endpoint;%s;%s;%d;%d\n", id, k, h[k], ok[k]
        }' | sort >> "$LOGF"
    # errors per day + the last 50 lines
    for f in $errs; do
        [ -s "$f" ] || continue
        awk -v id="$id" -v lim="$LIM" -v f="$f" '/SEVERE|ERROR|Exception/ { if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2}/)) { d=substr($0, 1, 10); if (d >= lim) n[d]++ } else u++ }
            END { for (d in n) printf "errors;%s;%s;%s;%d\n", id, f, d, n[d]; if (u) printf "errors;%s;%s;undated;%d\n", id, f, u }' "$f" | sort >> "$LOGF"
        { printf '### last error lines: %s\n' "$f"; grep -E 'SEVERE|ERROR' "$f" 2>/dev/null | tail -50 | cut -c1-400 | mask; printf '\n'; } >> "$LOGF"
    done
done
fact "ORDS requests (log)" "$(awk -F';' '$1=="access" {n+=$4; x+=$11} END {printf "%d in the last %s days (%d from outside the private nets)", n, d, x}' d="$LOG_DAYS" "$LOGF" 2>/dev/null)"
fact "ORDS SQL endpoint hits" "$(awk -F';' '$1=="endpoint" && $3 ~ /database_actions|rest_enabled_sql|database_api|graphql/ {s=s (s==""?"":", ") $3 " " $4 " (" $5 " ok)"} END {print (s=="" ? "none" : s)}' "$LOGF" 2>/dev/null)"

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
