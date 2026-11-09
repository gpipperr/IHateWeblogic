#!/bin/bash
# =============================================================================
# Script   : export_forms_reports_conf.sh
# Purpose  : Export the customer-specific Forms & Reports configuration of an
#            EXISTING environment (12.2.1.x or 14.1.2) into one archive, for
#            the rebuild with the IHateWeblogic 14c library:
#              raw/        1:1 copies (original paths below domain/,
#                          oracle_home/, other/) – formsweb.cfg + every
#                          envFile, Registry.dat, webutil.cfg, *.res,
#                          jnlp files, rwserver.conf / rwnetwork.conf /
#                          rwservlet.properties / cgicmd.dat of every Reports
#                          server, ReportsTools (uifont.ali, PPD, AFM),
#                          reports.sh, domain scripts, tnsnames / sqlnet,
#                          web tier: Nginx / Apache (+ mod_wl) / OHS with
#                          every include (ihw_import/web_tier.txt = routing)
#              ihw_import/ prepared for the library (proposals, nothing is
#                          applied): customer formsweb.cfg keys + sections,
#                          env keys, webutil keys, cgicmd keys, uifont.ali
#                          aliases, custom fonts, customer jars (never
#                          FSAL / JACOB / frm*.jar – they come from 14- / 40-),
#                          environment.conf proposal, Reports server list
#              sources_*   paths of the Forms / Reports sources incl.
#                          dependencies – inventory only, NO module content
#                          (.fmb .fmx .pll .plx .mmb .mmx .olb .rdf .rep ...)
#            READ-ONLY on the system: writes only below -t OUTDIR.
#            Passwords stay in the files (1:1) – the archive is ENCRYPTED
#            (openssl AES-256, passphrase asked twice); --masked masks them
#            and leaves the archive unencrypted (shareable for analysis).
#            NEVER commit an export: OUTDIR inside a git work tree is refused
#            unless git ignores it.
#            No IHateWeblogic library - bash + coreutils + openssl and the
#            shared helpers ihw_tools_lib.sh next to this script.
# Call     : ./export_forms_reports_conf.sh [-o ORACLE_HOME] [-d DOMAIN_HOME]
#                 [-t OUTDIR] [--masked] [--no-fonts] [--keep] [--no-load]
#                 [--load-days N] [--rw-auth USER]
#            -o / -d    default: environment, domain-registry.xml, process,
#                       /oracle/product/mw, /u01/app/oracle/fmw ...
#            -t         output directory (default /tmp)
#            --masked   mask passwords, do not encrypt
#            --no-fonts do not copy font files (only list them)
#            --keep     keep the unpacked staging directory
#            --no-load  no load profile (default: aggregated counts of the
#                       last --load-days N days, default 90 - see 6b)
#            --rw-auth USER  Reports admin for getserverinfo / showjobs of a
#                       secured Reports server (password asked hidden; or
#                       IHW_RW_AUTH=user/password in the environment)
# Runs as  : the software owner (oracle), not root
# Output   : <OUTDIR>/ihw_export_<host>_<ts>.zip.enc (+ .sha256)
#            decrypt: openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 \
#                       -in <file>.zip.enc -out <file>.zip
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

set -u
umask 077
_IHWT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ihw_tools_lib.sh
. "$_IHWT_DIR/ihw_tools_lib.sh" || { printf 'ihw_tools_lib.sh missing next to %s\n' "$0" >&2; exit 2; }
VERSION="2026-11-09.2"   # bump on every change – shown in the report

OH="${ORACLE_HOME:-}"; DH="${DOMAIN_HOME:-}"; OUTBASE="/tmp"
MASKED=false; FONTS=true; KEEP=false; LOADP=true; LOAD_DAYS=90; RW_AUTH_USER=""; RWAUTH="${IHW_RW_AUTH:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        -o) OH="${2:-}"; shift ;;
        -d) DH="${2:-}"; shift ;;
        -t) OUTBASE="${2:-/tmp}"; shift ;;
        --masked)   MASKED=true ;;
        --no-fonts) FONTS=false ;;
        --keep)     KEEP=true ;;
        --no-load)  LOADP=false ;;
        --load-days) LOAD_DAYS="${2:-90}"; shift ;;
        --rw-auth)  RW_AUTH_USER="${2:-}"; shift ;;
        -h|--help)  sed -n '2,52p' "$0"; printf 'Version: %s\n' "$VERSION"; exit 0 ;;
        -V|--version) printf '%s\n' "$VERSION"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

say()  { printf '  %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; WARNINGS+=("$*"); }
WARNINGS=()

# --- never into git -------------------------------------------------------------
OUTBASE="$(cd "$OUTBASE" 2>/dev/null && pwd)" || { printf 'Output directory does not exist\n' >&2; exit 2; }
HOST="$(hostname -s 2>/dev/null || hostname)"
TS="$(date +%Y%m%d_%H%M%S)"
NAME="ihw_export_${HOST}_${TS}"
ihwt_git_guard "$OUTBASE" "$NAME.zip" || exit 2

# --- passphrase first (before minutes of collecting) ---------------------------
IHWT_PASS=""
if ! $MASKED; then
    ihwt_read_passphrase "export archive" || { printf '  -> or use --masked\n' >&2; exit 2; }
fi

if $LOADP && [ -n "$RW_AUTH_USER" ] && [ -z "$RWAUTH" ]; then
    [ -t 0 ] || { printf -- '--rw-auth needs a terminal for the password (or IHW_RW_AUTH)\n' >&2; exit 2; }
    read -r -s -p "  Password of the Reports admin $RW_AUTH_USER: " _rp; printf '\n'
    RWAUTH="$RW_AUTH_USER/$_rp"; unset _rp
fi

# --- locate ORACLE_HOME / DOMAIN_HOME (as collect_fmw_env.sh) --------------------
if [ -z "$OH" ] || [ ! -d "$OH/OPatch" ]; then
    for c in /oracle/product/mw /u01/app/oracle/fmw /u01/oracle/fmw \
             /u01/app/oracle/middleware /u01/oracle/middleware; do
        [ -d "$c/OPatch" ] && { OH="$c"; break; }
    done
fi
[ -d "${OH:-/nonexistent}" ] || { printf 'ORACLE_HOME not found – use -o\n' >&2; exit 2; }
if [ -z "$DH" ] && [ -r "$OH/domain-registry.xml" ]; then
    DH="$(sed -n 's/.*location="\([^"]*\)".*/\1/p' "$OH/domain-registry.xml" | head -1)"
fi
[ -z "$DH" ] && DH="$(ps -eo args 2>/dev/null | sed -n 's/.*-Dweblogic\.RootDirectory=\([^ ]*\).*/\1/p' | head -1)"
[ -f "${DH:-/nonexistent}/config/config.xml" ] || { printf 'DOMAIN_HOME not found (config/config.xml) – use -d\n' >&2; exit 2; }
CFG="$DH/config/fmwconfig"

STAGE="$OUTBASE/$NAME"
mkdir -p "$STAGE/raw" "$STAGE/ihw_import" || exit 2
# Abort (Ctrl-C, kill, error exit) before the end: remove the staging directory
# (clear-text passwords in the default mode) and a half-written / still
# unencrypted archive. --keep keeps the staging directory also then.
DONE=false; ARCH=""
_cleanup() {
    local rc=$?
    $DONE && return
    IHWT_PASS=""; RWAUTH=""
    [ -n "$ARCH" ] && rm -f "$OUTBASE/$ARCH" "$OUTBASE/$ARCH.enc"
    if $KEEP; then
        printf '\n  ABORTED (rc %s) – staging kept (--keep): %s – contains %s data, delete it\n' \
            "$rc" "$STAGE" "$($MASKED && printf masked || printf CLEAR-TEXT)" >&2
    else
        rm -rf "${STAGE:?}"
        printf '\n  ABORTED (rc %s) – staging directory and partial archive removed\n' "$rc" >&2
    fi
}
trap _cleanup EXIT
trap 'exit 130' INT TERM HUP
REPORT="$STAGE/00_report.txt"
MANIFEST="$STAGE/manifest.csv"
printf 'category;source;stored;size;sha256\n' > "$MANIFEST"
say "export_forms_reports_conf.sh $VERSION"
say "ORACLE_HOME $OH"
say "DOMAIN_HOME $DH"
say "staging     $STAGE"

# --- helpers -----------------------------------------------------------------
# mask / ini parsing / font classes: ihw_tools_lib.sh (ihwt_*)
mask() { ihwt_mask; }
SECRETS="$STAGE/secrets_locations.txt"
: > "$SECRETS"
declare -A SEEN=()

# _store SRC CATEGORY [DEST_REL] – copy into raw/ (or DEST_REL below the stage)
_store() {
    local src="$1" cat="$2" rel="${3:-}" dst
    [ -f "$src" ] && [ -r "$src" ] || return 1
    src="$(readlink -f "$src")"
    if [ -z "$rel" ]; then
        case "$src" in
            "$DH"/*) rel="raw/domain/${src#"$DH"/}" ;;
            "$OH"/*) rel="raw/oracle_home/${src#"$OH"/}" ;;
            *)       rel="raw/other${src}" ;;
        esac
    fi
    [ -n "${SEEN[$rel]:-}" ] && return 0
    SEEN[$rel]=1
    dst="$STAGE/$rel"
    mkdir -p "$(dirname "$dst")"
    if $MASKED && grep -Iq . "$src" 2>/dev/null; then
        mask < "$src" > "$dst"; touch -r "$src" "$dst"
    else
        cp -p "$src" "$dst"
    fi
    # where secrets are (file + line + keyword, never the value)
    if grep -Iq . "$src" 2>/dev/null; then
        grep -noiE '(password|passwd|dbpassword|authid|userid|<identifier|\{AES)' "$src" 2>/dev/null \
            | sed "s|^|$rel:|" >> "$SECRETS"
    fi
    printf '%s;%s;%s;%s;%s\n' "$cat" "$src" "$rel" "$(stat -c %s "$src")" \
        "$(sha256sum "$src" | cut -d' ' -f1)" >> "$MANIFEST"
}
# _expand PATHSTRING – resolve the usual variables of env files / scripts
_expand() {
    printf '%s' "$1" | sed -e "s#\${\?ORACLE_HOME}\?#$OH#g" -e "s#\${\?DOMAIN_HOME}\?#$DH#g" \
        -e "s#\${\?MW_HOME}\?#$OH#g" -e "s#\${\?WL_HOME}\?#$OH/wlserver#g"
}
_cfgval()   { ihwt_cfgval "$@"; }
_sections() { ihwt_sections "$@"; }
_keys()     { ihwt_keys "$@"; }

# =============================================================================
# 1. Forms
# =============================================================================
say "Forms ..."
FORMS_CFGS=(); ENV_FILES=()
while IFS= read -r f; do FORMS_CFGS+=("$f"); done < <(
    find "$CFG/servers" -maxdepth 5 -path '*/applications/*/config/formsweb.cfg' 2>/dev/null \
        | grep -E '/(forms|formsapp)_[^/]*/config/formsweb.cfg$' | sort)

for fw in "${FORMS_CFGS[@]}"; do
    cdir="$(dirname "$fw")"
    _store "$fw" forms_wls
    for f in "$cdir"/*.env "$cdir"/*.cfg "$cdir"/oracle/forms/registry/*; do _store "$f" forms_wls; done
    # every envFile of every section (relative = config dir)
    while IFS= read -r e; do
        [ -z "$e" ] && continue
        case "$e" in /*) ef="$e" ;; *) ef="$cdir/$e" ;; esac
        ef="$(_expand "$ef")"
        if [ -f "$ef" ]; then _store "$ef" forms_env; ENV_FILES+=("$(readlink -f "$ef")")
        else warn "envFile $e of $fw not found"; fi
    done < <(_cfgval "$fw" envFile | sort -u)
done
[ ${#FORMS_CFGS[@]} -eq 0 ] && warn "no formsweb.cfg found (Forms not deployed?)"
mapfile -t ENV_FILES < <(printf '%s\n' "${ENV_FILES[@]}" | sort -u | sed '/^$/d')

for d in "$CFG"/components/FORMS/instances/* "$CFG"/components/FORMS/*; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in instances|mbeans) continue ;; esac
    for f in "$d"/server/*.cfg "$d"/server/*.conf "$d"/server/*.xml "$d"/admin/resource/*/fmrweb*.res; do
        _store "$f" forms_inst
    done
done
for f in "$OH"/forms/java/*.jnlp "$OH"/forms/server/*.jnlp; do _store "$f" forms_jnlp; done
# session-timeout of the Forms servlet (formsapp.ear -> formsweb.war WEB-INF/weblogic.xml):
# needed for the timeout chain heartBeat < FORMS_TIMEOUT < session-timeout
for ear in "$OH"/forms/j2ee/formsapp.ear; do
    [ -f "$ear" ] && command -v unzip >/dev/null 2>&1 || continue
    _wt="$STAGE/.ear"; mkdir -p "$_wt"
    if unzip -q -o "$ear" formsweb.war -d "$_wt" 2>/dev/null; then
        for x in weblogic.xml web.xml; do
            unzip -p "$_wt/formsweb.war" "WEB-INF/$x" > "$_wt/$x" 2>/dev/null && [ -s "$_wt/$x" ] && \
                _store "$_wt/$x" forms_ear "raw/oracle_home/forms/j2ee/formsapp.ear/formsweb.war/WEB-INF/$x"
        done
    fi
    rm -rf "${_wt:?}"
done

# --- customer jars (never frm*.jar / frmsal / jacob – they come from 14-/40-) ---
JARS="$STAGE/ihw_import/jars.txt"
printf 'jar;size;sha256;referenced_in;stored\n' > "$JARS"
declare -A JREF=()
# relative jar names (archive=, jnlp href) live in $OH/forms/java
_jpath() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s' "$OH/forms/java/${1#./}" ;; esac; }
for fw in "${FORMS_CFGS[@]}"; do
    while IFS=$'\t' read -r sec k v; do
        case "$k" in archive|archive_*|WebUtilArchive|webUtilArchive)
            for j in ${v//,/ }; do JREF[$(_jpath "$j")]+="formsweb.cfg[$sec].$k "; done ;; esac
    done < <(_sections "$fw")
done
for ef in "${ENV_FILES[@]}"; do
    for p in $(_cfgval "$ef" CLASSPATH | tr ':' ' '); do
        case "$p" in *%*|*'$'*) continue ;; esac              # Oracle placeholders (%ORACLE_HOME% …)
        case "$p" in *.jar) JREF[$(_jpath "$(_expand "$p")")]+="$(basename "$ef"):CLASSPATH " ;; esac
    done
done
for jn in "$OH"/forms/java/extensions.jnlp; do
    [ -f "$jn" ] || continue
    for j in $(grep -v '^[[:space:]]*<!--' "$jn" | grep -oE 'href="[^"]+\.jar"' | sed 's/href="//; s/"$//'); do
        JREF[$(_jpath "$j")]+="extensions.jnlp "
    done
done
for j in "$OH"/forms/java/*.jar; do [ -f "$j" ] && JREF[$j]+=""; done
for jp in $(printf '%s\n' "${!JREF[@]}" | sort); do
    j="$jp"
    jb="$(basename "$jp")"
    case "$jb" in frm*.jar|jacob*.jar) continue ;; esac       # Oracle / our 14c logic
    case "$jp" in "$OH"/*) case "$jp" in "$OH"/forms/java/*) ;; *) continue ;; esac ;; esac  # other Oracle jars
    if [ -f "$jp" ]; then
        _store "$jp" customer_jar "ihw_import/forms_java/$jb"
        printf '%s;%s;%s;%s;%s\n' "$jp" "$(stat -c %s "$jp")" "$(sha256sum "$jp" | cut -d' ' -f1)" \
            "${JREF[$j]:-in forms/java, not referenced}" "ihw_import/forms_java/$jb" >> "$JARS"
    else
        printf '%s;-;-;%s;MISSING\n' "$jp" "${JREF[$j]}" >> "$JARS"
    fi
done

_kt="$OH/oracle_common/jdk/bin/keytool"; [ -x "$_kt" ] || _kt="$(command -v keytool 2>/dev/null)"
if [ -n "$_kt" ]; then
    for j in "$STAGE"/ihw_import/forms_java/*.jar; do
        [ -f "$j" ] || continue
        _o="$("$_kt" -printcert -jarfile "$j" 2>/dev/null | awk '/^Signer #1/{s=1} s&&/^Owner:/&&!o{sub(/^Owner: /,""); o=$0} s&&/^Issuer:/&&!i{sub(/^Issuer: /,""); i=$0} s&&/until:/&&!u{sub(/.*until: /,""); u=$0} END{print o "|" i "|" u}')"
        [ "$_o" = "||" ] && continue
        printf 'jar %s;%s;%s;%s\n' "$(basename "$j")" "$(printf '%s' "$_o" | cut -d'|' -f1 | tr ';' ',')" \
            "$(printf '%s' "$_o" | cut -d'|' -f2 | tr ';' ',')" "$(printf '%s' "$_o" | cut -d'|' -f3)" >> "$STAGE/ihw_import/.jar_certs"
    done
fi
unset _kt _o

# =============================================================================
# 2. Reports
# =============================================================================
say "Reports ..."
RSV="$STAGE/ihw_import/reports_servers.txt"
printf 'name;type;running;rwserver.conf;engines(init/min/max);engLife;identifier;securityId;jobStatusRepository;broadcast_port\n' > "$RSV"
_rs_line() {   # name type conf netconf
    local n="$1" t="$2" c="$3" net="$4" run eng life idf sec jsr port
    pgrep -f "rwserver.* server=$n( |$)" >/dev/null 2>&1 && run=yes || run=no
    eng="$(grep -m1 -oE 'initEngine="[0-9]+"[^>]*' "$c" 2>/dev/null)"
    eng="$(printf '%s' "$eng" | grep -oE '(initEngine|minEngine|maxEngine)="[0-9]+"' | sed 's/.*="//; s/"//' | paste -sd/)"
    life="$(grep -m1 -oE 'engLife="[0-9]+"' "$c" 2>/dev/null | grep -oE '[0-9]+')"
    if grep -q '<identifier[^>]*encrypted="yes"' "$c" 2>/dev/null; then idf=encrypted
    elif grep -q '<identifier' "$c" 2>/dev/null; then idf=clear; else idf=none; fi
    grep -q 'securityId=' "$c" 2>/dev/null && sec=yes || sec=no
    awk '/<!--/{c=1} c&&/-->/{c=0;next} !c' "$c" 2>/dev/null | grep -q '<jobStatusRepository' && jsr=yes || jsr=no
    port="$(sed -nE 's/.*<(multicast|cluster)[^>]*port="([0-9]+)".*/\2/p' "$net" 2>/dev/null | head -1)"
    printf '%s;%s;%s;%s;%s;%s;%s;%s;%s;%s\n' "$n" "$t" "$run" "$c" "${eng:--}" "${life:--}" "$idf" "$sec" "$jsr" "${port:--}" >> "$RSV"
}
RS_NAMES=()
while IFS= read -r n; do [ -n "$n" ] && RS_NAMES+=("$n"); done < <(
    awk '/<system-component>/{n="";t=""} /<name>/&&n==""{n=$0; gsub(/.*<name>|<\/name>.*/,"",n)}
         /<component-type>ReportsServerComponent</{t="R"} /<\/system-component>/{if(t=="R")print n}' "$DH/config/config.xml")
for d in "$CFG"/components/ReportsServerComponent/*; do
    [ -d "$d" ] || continue; n="$(basename "$d")"; [ "$n" = mbeans ] && continue
    printf '%s\n' "${RS_NAMES[@]}" | grep -qx "$n" || RS_NAMES+=("$n")
done
for n in "${RS_NAMES[@]}"; do
    d="$CFG/components/ReportsServerComponent/$n"
    for f in "$d"/*.conf "$d"/*.xml "$d"/*.properties; do _store "$f" reports_server; done
    _rs_line "$n" standalone "$d/rwserver.conf" "$d/rwnetwork.conf"
done
INPROC_DIRS=()
while IFS= read -r d; do INPROC_DIRS+=("$d"); done < <(
    find "$CFG/servers" -maxdepth 4 -type d -path '*/applications/reports_*/configuration' 2>/dev/null | sort)
for d in "${INPROC_DIRS[@]}"; do
    for f in "$d"/rwserver.conf "$d"/rwservlet.properties "$d"/cgicmd.dat "$d"/CGICMD.DAT "$d"/rwnetwork.conf "$d"/*.xml; do
        _store "$f" reports_wls
    done
    _srv="$(sed -n 's:.*<server>\([^<]*\)</server>.*:\1:p' "$d/rwservlet.properties" 2>/dev/null | head -1)"
    _inp="$(sed -n 's:.*<inprocess>\([^<]*\)</inprocess>.*:\1:p' "$d/rwservlet.properties" 2>/dev/null | head -1)"
    [ "$_inp" = "yes" ] && _rs_line "${_srv:-in-process}" "in-process" "$d/rwserver.conf" "$d/rwnetwork.conf"
    printf '# rwservlet %s: server=%s inprocess=%s\n' "$d" "${_srv:--}" "${_inp:--}" >> "$RSV"
done
_store "$OH/reports/conf/cgicmd.dat" reports_fmw
TOOLS_DIRS=()
for d in "$CFG"/components/ReportsToolsComponent/*; do
    [ -d "$d" ] || continue; [ "$(basename "$d")" = mbeans ] && continue
    TOOLS_DIRS+=("$d")
    for f in "$d"/*.conf "$d"/guicommon/tk/admin/uifont.ali "$d"/guicommon/tk/admin/PPD/*.ppd \
             "$d"/guicommon/tk/admin/AFM/*; do _store "$f" reports_tools; done
done
_store "$DH/reports/bin/reports.sh" reports_script

# =============================================================================
# 3. Domain, Oracle Net, web tier
# =============================================================================
say "Domain / Oracle Net / web tier ..."
for f in "$DH/bin/setUserOverrides.sh" "$DH/bin/setDomainEnv.sh" "$DH/nodemanager/nodemanager.properties" \
         "$DH/config/config.xml" "$CFG/jps-config-jse.xml"; do _store "$f" domain; done
TNS_DIRS=("$CFG" "$OH/network/admin")
for ef in "${ENV_FILES[@]}"; do t="$(_cfgval "$ef" TNS_ADMIN | head -1)"; [ -n "$t" ] && TNS_DIRS+=("$(_expand "$t")"); done
for c in "$DH/reports/bin/reports.sh" "${INPROC_DIRS[@]/%//rwserver.conf}" "$CFG"/components/ReportsServerComponent/*/rwserver.conf; do
    t="$(grep -oE 'TNS_ADMIN"?[[:space:]]*(value="|=)[^";[:space:]]+' "$c" 2>/dev/null | sed -E 's/.*(value="|=)//' | head -1)"
    [ -n "$t" ] && TNS_DIRS+=("$(_expand "$t")")
done
mapfile -t TNS_DIRS < <(printf '%s\n' "${TNS_DIRS[@]}" | sort -u)
for t in "${TNS_DIRS[@]}"; do for f in "$t"/tnsnames.ora "$t"/sqlnet.ora "$t"/ldap.ora; do _store "$f" oracle_net; done; done
for d in "$CFG"/components/OHS/*; do
    [ -d "$d" ] || continue; [ "$(basename "$d")" = instances ] && continue
    for f in "$d"/mod_wl_ohs.conf "$d"/httpd.conf "$d"/ssl.conf "$d"/moduleconf/*.conf; do _store "$f" ohs; done
done
# JDBC system resources (RCU data sources: URL + schema user; passwords are {AES})
for f in "$DH"/config/jdbc/*-jdbc.xml; do _store "$f" domain_jdbc; done
JDBC_TXT="$STAGE/ihw_import/jdbc.txt"
printf 'datasource;url;user\n' > "$JDBC_TXT"
for f in "$DH"/config/jdbc/*-jdbc.xml; do
    [ -f "$f" ] || continue
    _u="$(sed -n 's:.*<url>\([^<]*\)</url>.*:\1:p' "$f" | head -1)"
    _usr="$(tr '\n' ' ' < "$f" | grep -oE '<name>user</name>[[:space:]]*<value>[^<]*' | sed 's/.*<value>//' | head -1)"
    printf '%s;%s;%s\n' "$(basename "$f" -jdbc.xml)" "$_u" "$_usr" >> "$JDBC_TXT"
done
# web tier in front of WebLogic: Nginx, Apache (+ WebLogic plug-in mod_wl), OHS
# (in this domain or a standalone web tier domain) - every configuration file
# incl. includes into raw/, the routing into ihw_import/web_tier.txt
WT_TXT="$STAGE/ihw_import/web_tier.txt"; WTS_TXT="$STAGE/ihw_import/web_tier_settings.txt"
printf '%s\n' "$IHWT_WT_HEAD" > "$WT_TXT"; printf 'type;conf;key;value;file\n' > "$WTS_TXT"
mapfile -t WT_FOUND < <(ihwt_webtier_find "$DH")
for _e in "${WT_FOUND[@]}"; do
    _t="${_e%%;*}"; _m="${_e#*;}"
    ihwt_webtier_flatten "$_t" "$_m" > "$STAGE/.wt_flat"
    while IFS= read -r _f; do _store "$_f" "web_tier_$_t" || true; done < <(sed -n 's/^#@@ FILE //p' "$STAGE/.wt_flat")
    while IFS= read -r _f; do warn "web tier ($_t): not readable as $(id -un): $_f – copy it by hand (root)"; done \
        < <(sed -n 's/^#@@ UNREADABLE //p' "$STAGE/.wt_flat")
    ihwt_webtier_routes "$_t" "$_m" < "$STAGE/.wt_flat" >> "$WT_TXT"
    ihwt_webtier_settings "$_t" "$_m" < "$STAGE/.wt_flat" >> "$WTS_TXT"
done
rm -f "$STAGE/.wt_flat"
[ ${#WT_FOUND[@]} -eq 0 ] && warn "web tier: no Nginx / Apache / OHS configuration found (other host? -> export it there too)"
# certificates - public part only (subject / issuer / expiry): every HTTPS
# listener of the web tier (s_client with the server name, else the certificate
# file) and the signers of the jars
CERT_TXT="$STAGE/ihw_import/certificates.txt"
printf 'source;subject;issuer;not_after\n' > "$CERT_TXT"
if command -v openssl >/dev/null 2>&1; then
    awk -F';' 'NR>1 && $5=="yes" { n=split($3, L, ","); sn=$4; sub(/,.*/, "", sn)
                for (i=1; i<=n; i++) if (L[i] !~ /^\[/ || L[i] ~ /^\[::\]:/) print $1 ";" L[i] ";" sn ";" $10 }' "$WT_TXT" \
        | awk -F';' '{ p=$2; sub(/.*:/, "", p) } !seen[$1 ";" p ";" $3]++' \
        | while IFS=';' read -r _t _l _sn _cf; do
        _h="${_l%:*}"; _p="${_l##*:}"
        case "$_h" in '*'|0.0.0.0|'[::]'|'') _h=127.0.0.1 ;; esac
        case "$_sn" in ''|_|'*'*|localhost) _sn="$(hostname -f 2>/dev/null || hostname)" ;; esac
        _src="https $_t $_l ($_sn)"
        _c="$(timeout 10 openssl s_client -connect "$_h:$_p" -servername "$_sn" </dev/null 2>/dev/null \
              | openssl x509 -noout -subject -issuer -enddate 2>/dev/null)"
        if [ -z "$_c" ] && [ -f "$_cf" ] && [ -r "$_cf" ]; then
            _c="$(openssl x509 -in "$_cf" -noout -subject -issuer -enddate 2>/dev/null)"; _src="https $_t $_l (file $_cf)"
        fi
        if [ -n "$_c" ]; then
            printf '%s;%s;%s;%s\n' "$_src" "$(printf '%s\n' "$_c" | sed -n 's/^subject= *//p' | tr ';' ',')" \
                "$(printf '%s\n' "$_c" | sed -n 's/^issuer= *//p' | tr ';' ',')" "$(printf '%s\n' "$_c" | sed -n 's/^notAfter=//p')"
        else
            printf '%s;-;-;not reachable / no readable certificate file\n' "$_src"
        fi
    done >> "$CERT_TXT"
fi
[ -f "$STAGE/ihw_import/.jar_certs" ] && { sort -u "$STAGE/ihw_import/.jar_certs" >> "$CERT_TXT"; rm -f "$STAGE/ihw_import/.jar_certs"; }
unset _h _p _c _u _usr _t _m _e _f _l _sn _cf _src

# =============================================================================
# 4. Fonts
# =============================================================================
say "Fonts ..."
FONT_DIRS=("$DH/reports/fonts")
for f in "$DH/reports/bin/reports.sh" "$DH/bin/setUserOverrides.sh" "${ENV_FILES[@]}"; do
    while IFS= read -r v; do [ -n "$v" ] && FONT_DIRS+=("$(_expand "$v")"); done < <(
        grep -oE 'REPORTS_FONT_DIRECTORY[[:space:]]*=[[:space:]]*"?[^";[:space:]]+' "$f" 2>/dev/null | sed -E 's/.*=[[:space:]]*"?//')
done
mapfile -t FONT_DIRS < <(printf '%s\n' "${FONT_DIRS[@]}" | tr ':' '\n' | sort -u | sed '/^$/d')
FONTS_TXT="$STAGE/ihw_import/fonts.txt"
printf 'font;size;dir;class;replacement_14c;exported\n' > "$FONTS_TXT"
_font_class() { ihwt_font_class "$@"; }   # classes: ihw_tools_lib.sh
for fd in "${FONT_DIRS[@]}"; do
    [ -d "$fd" ] || continue
    while IFS= read -r ff; do
        fb="$(basename "$ff")"
        fc="$(_font_class "$fb")"
        case "$fc" in free\;*) printf '%s;%s;%s;%s;no (OS package – 14b- deploys it)\n' "$fb" "$(stat -c %s "$ff")" "$fd" "$fc" >> "$FONTS_TXT"; continue ;; esac
        if $FONTS; then
            _store "$ff" fonts "ihw_import/custom_fonts_dir/$fb"
            printf '%s;%s;%s;%s;ihw_import/custom_fonts_dir/\n' "$fb" "$(stat -c %s "$ff")" "$fd" "$fc" >> "$FONTS_TXT"
        else
            printf '%s;%s;%s;%s;no (--no-fonts)\n' "$fb" "$(stat -c %s "$ff")" "$fd" "$fc" >> "$FONTS_TXT"
        fi
    done < <(find "$fd" -maxdepth 1 -type f \( -iname '*.ttf' -o -iname '*.ttc' -o -iname '*.otf' \) 2>/dev/null | sort)
done

# =============================================================================
# 5. ihw_import – customer settings against Oracle's templates
# =============================================================================
say "Comparing with Oracle's templates ..."
IMP="$STAGE/ihw_import"
TPL="$OH/forms/templates/config"
# formsweb.cfg: [default] overrides + customer sections / changed keys
for fw in "${FORMS_CFGS[@]}"; do
    _sections "$TPL/formsweb.cfg" | sort > "$STAGE/.base_fw"
    _sections "$fw" | sort > "$STAGE/.cust_fw"
    {
        printf '# %s – [default] keys that differ from / are missing in Oracle'"'"'s %s\n' "$fw" "$TPL/formsweb.cfg"
        printf '# target: 09-Install/forms_templates/formsweb.cfg.template ([default] overrides)\n'
        comm -13 "$STAGE/.base_fw" "$STAGE/.cust_fw" | awk -F'\t' '$1=="default"{print $2 "=" $3}'
    } >> "$IMP/formsweb.cfg.default_overrides"
    {
        printf '# %s – customer sections and changed keys of other sections\n' "$fw"
        printf '# (14- has no mechanism for own sections yet – later import step)\n'
        comm -13 "$STAGE/.base_fw" "$STAGE/.cust_fw" | awk -F'\t' '$1!="default"{if($1!=s){print ""; print "[" $1 "]"; s=$1} print $2 "=" $3}'
    } >> "$IMP/formsweb.cfg.sections"
done
# env files: keys differing from Oracle's default.env
for ef in "${ENV_FILES[@]}"; do
    _keys "$TPL/default.env" | sort > "$STAGE/.base_env"
    _keys "$ef" | sort > "$STAGE/.cust_env"
    {
        printf '# %s – keys that differ from / are missing in Oracle'"'"'s default.env\n' "$ef"
        printf '# target: forms_templates/default.env.template (FORMS_PATH, NLS_*, CLASSPATH extras, own variables)\n'
        # keys 14- sets itself from environment.conf / Oracle's paths: only as
        # comment; for CLASSPATH / FORMS_PATH only the customer entries
        comm -13 "$STAGE/.base_env" "$STAGE/.cust_env" | awk -F'\t' -v oh="$OH" -v dh="$DH" '
            BEGIN { split("ORACLE_HOME PATH LD_LIBRARY_PATH LD_PRELOAD FORMS_INSTANCE COMPONENT_CONFIG_PATH TNS_ADMIN TMPDIR", L, " ")
                    for (i in L) lib[L[i]] = 1 }
            $1 == "CLASSPATH" || $1 == "FORMS_PATH" {
                n = split($2, e, ":"); x = ""
                for (i = 1; i <= n; i++) if (e[i] != "" && index(e[i], oh) != 1 && index(e[i], dh) != 1 && e[i] !~ /^\$/) x = x (x == "" ? "" : ":") e[i]
                print "# " $1 " (full): " $2
                if (x != "") print $1 "_CUSTOMER=" x
                next }
            ($1 in lib) { print "# (set by 14- / environment.conf) " $1 "=" $2; next }
            { print $1 "=" $2 }'
        printf '\n'
    } >> "$IMP/default.env.customer_keys"
done
# webutil.cfg: differing keys (install.syslib stays Oracle's)
for wc in "$CFG"/components/FORMS/instances/*/server/webutil.cfg; do
    [ -f "$wc" ] || continue
    _keys "$TPL/webutil.cfg" | grep -v '^install\.syslib' | sort > "$STAGE/.base_wu"
    _keys "$wc" | grep -v '^install\.syslib' | sort > "$STAGE/.cust_wu"
    { printf '# %s – keys that differ from Oracle'"'"'s webutil.cfg (install.syslib.* skipped)\n' "$wc"
      printf '# target: forms_templates/webutil.cfg.template\n'
      comm -13 "$STAGE/.base_wu" "$STAGE/.cust_wu" | awk -F'\t' '{print $1 "=" $2}'; printf '\n'; } >> "$IMP/webutil.cfg.overrides"
done
# cgicmd.dat: every active key (not the IHateWeblogic block)
for cg in "${INPROC_DIRS[@]/%//cgicmd.dat}" "$OH/reports/conf/cgicmd.dat"; do
    [ -f "$cg" ] || continue
    { printf '# %s – active keys (target: after the END marker of 14b-'"'"'s block)\n' "$cg"
      # Oracle's sample keys of the shipped cgicmd.dat are not customer keys
      awk '/IHateWeblogic BEGIN/{s=1} /IHateWeblogic END/{s=0;next} s{next}
           /^[[:space:]]*[#;]/{next} /^[[:space:]]*$/{next}
           { k=$0; sub(/[[:space:]]*:.*/, "", k)
             if (k ~ /^(orqa|report_defaultid|report_secure|run|breakbparam|runp|express)$/) next; print }' "$cg"; printf '\n'; } >> "$IMP/cgicmd.dat.customer_keys"
done
# uifont.ali: lines not in Oracle's template, with their section
_ubase="$(find "$OH/frcommon/templates" "$OH/guicommon/tk/admin" -maxdepth 4 -name uifont.ali 2>/dev/null | head -1)"
for d in "${TOOLS_DIRS[@]}"; do
    ua="$d/guicommon/tk/admin/uifont.ali"
    [ -f "$ua" ] || continue
    { printf '# %s – lines not in Oracle'"'"'s %s (target: 04-ReportsFonts/uifont_ali_template.ali)\n' "$ua" "${_ubase:-template (not found)}"
      awk 'NR==FNR{if($0!~/^[[:space:]]*#/ && $0!~/^[[:space:]]*$/) b[$0]=1; next}
           /^[[:space:]]*\[/{sec=$0; next} /^[[:space:]]*#/||/^[[:space:]]*$/{next}
           !($0 in b){if(sec!=last){print sec; last=sec} print}' "${_ubase:-/dev/null}" "$ua"; printf '\n'; } >> "$IMP/uifont.ali.customer"
done
rm -f "$STAGE"/.base_* "$STAGE"/.cust_*

# =============================================================================
# 6. Sources – paths + dependencies, inventory only (no module content)
# =============================================================================
say "Sources inventory ..."
declare -A SRCDIR=()
_adddir() { local p; p="$(_expand "$1")"; p="${p%/}"; [ -n "$p" ] && SRCDIR[$p]+="$2 "; }
for ef in "${ENV_FILES[@]}"; do
    for p in $(_cfgval "$ef" FORMS_PATH | tr ':' ' '); do _adddir "$p" "FORMS_PATH($(basename "$ef"))"; done
    v="$(_cfgval "$ef" REPORTS_PATH | head -1)"; for p in ${v//:/ }; do _adddir "$p" "REPORTS_PATH($(basename "$ef"))"; done
done
for f in "$DH/reports/bin/reports.sh"; do
    v="$(grep -oE '^REPORTS_PATH=[^;]+' "$f" 2>/dev/null | tail -1 | sed 's/^REPORTS_PATH=//')"
    for p in ${v//:/ }; do case "$p" in *REPORTS_PATH*) ;; *) _adddir "$p" "REPORTS_PATH(reports.sh)" ;; esac; done
done
for c in "${INPROC_DIRS[@]/%//rwserver.conf}" "$CFG"/components/ReportsServerComponent/*/rwserver.conf; do
    [ -f "$c" ] || continue
    v="$(sed -n 's/.*name="REPORTS_PATH"[^>]*value="\([^"]*\)".*/\1/p' "$c" | head -1)"
    for p in ${v//[:;]/ }; do _adddir "$p" "REPORTS_PATH($(basename "$(dirname "$c")"))"; done
    v="$(sed -n 's:.*<read>\([^<]*\)</read>.*:\1:p' "$c" | head -1)"; for p in ${v//;/ }; do _adddir "$p" "folderAccess.read"; done
    v="$(sed -n 's:.*<write>\([^<]*\)</write>.*:\1:p' "$c" | head -1)"; for p in ${v//;/ }; do _adddir "$p" "folderAccess.write"; done
done
for wc in "$CFG"/components/FORMS/instances/*/server/webutil.cfg; do
    while IFS=$'\t' read -r k v; do
        case "$k" in transfer.appsrv.read.*|transfer.appsrv.write.*|transfer.appsrv.workAreaRoot) _adddir "$v" "webutil:$k" ;; esac
    done < <(_keys "$wc" 2>/dev/null)
done
for fw in "${FORMS_CFGS[@]}"; do
    _rd="$(dirname "$fw")/oracle/forms/registry/Registry.dat"
    v="$(_cfgval "$_rd" default.icons.iconpath | head -1)"
    case "$v" in /*) _adddir "$v" "Registry.dat iconpath" ;; ?*) printf 'Registry.dat iconpath (URL / relative): %s\n' "$v" >> "$STAGE/sources_dependencies.txt" ;; esac
done

INV="$STAGE/sources_inventory.csv"; FILES="$STAGE/sources_files.txt"; DEP="$STAGE/sources_dependencies.txt"
EXTS="fmb fmx pll plx mmb mmx olb rdf rep jsp xml gif jpg png ico"
printf 'path;configured_in;exists;owner:mode;%s;newest\n' "$(printf '%s;' $EXTS | sed 's/;$//')" > "$INV"
printf '# per source directory: file;size;mtime – NO content is exported\n' > "$FILES"
{ printf '# HEURISTIC – dependencies read with "strings" from compiled modules (.fmx/.mmx/.plx)\n'
  printf '# and from text reports (.rep/.jsp/.xml); .fmb/.rdf are binary and not read.\n\n'; } >> "$DEP"
LIBS="$STAGE/.libs"; : > "$LIBS"; printf 'WEBUTIL\n' >> "$LIBS"
for p in "${!SRCDIR[@]}"; do
    [ -d "$p" ] && find "$p" -maxdepth 1 -type f \( -iname '*.plx' -o -iname '*.pll' -o -iname '*.mmx' \) -printf '%f\n' 2>/dev/null \
        | sed 's/\.[^.]*$//' | tr '[:lower:]' '[:upper:]' >> "$LIBS"
done
sort -u -o "$LIBS" "$LIBS"
for p in $(printf '%s\n' "${!SRCDIR[@]}" | sort); do
    if [ ! -d "$p" ]; then printf '%s;%s;no;-;%s-\n' "$p" "${SRCDIR[$p]}" "$(printf -- '-;%.0s' $EXTS)" >> "$INV"; continue; fi
    cnts=""; for e in $EXTS; do cnts+="$(find "$p" -maxdepth 1 -type f -iname "*.$e" 2>/dev/null | wc -l);"; done
    newest="$(find "$p" -maxdepth 1 -type f -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort | tail -1)"
    printf '%s;%s;yes;%s;%s%s\n' "$p" "${SRCDIR[$p]}" "$(stat -c '%U:%a' "$p")" "$cnts" "${newest:--}" >> "$INV"
    { printf '\n## %s\n' "$p"
      find "$p" -maxdepth 1 -type f \( -iname '*.fm?' -o -iname '*.pl?' -o -iname '*.mm?' -o -iname '*.olb' \
           -o -iname '*.rdf' -o -iname '*.rep' -o -iname '*.jsp' -o -iname '*.xml' \) \
           -printf '%f;%s;%TY-%Tm-%Td %TH:%TM\n' 2>/dev/null | sort; } >> "$FILES"
    while IFS= read -r m; do
        used="$(strings -n 3 "$m" 2>/dev/null | tr '[:lower:]' '[:upper:]' | grep -owFf "$LIBS" | sort -u | paste -sd, -)"
        refs="$(strings -n 4 "$m" 2>/dev/null | grep -oiE '[A-Za-z0-9_$#-]+\.(plx|pll|mmx|mmb|olb|fmx)' | sort -u | paste -sd, -)"
        [ -n "$used$refs" ] && printf '%s: libraries/menus=%s explicit=%s\n' "$m" "${used:--}" "${refs:--}" >> "$DEP"
    done < <(find "$p" -maxdepth 1 -type f \( -iname '*.fmx' -o -iname '*.mmx' -o -iname '*.plx' \) 2>/dev/null | sort)
    while IFS= read -r r; do
        for ref in $(grep -oiE '[^"'"'"' <>=]+\.(gif|jpe?g|png|bmp|xsl|css|js)' "$r" 2>/dev/null | sort -u); do
            [ -e "$ref" ] || [ -e "$p/$ref" ] || printf '%s: referenced file not found: %s\n' "$r" "$ref" >> "$DEP"
        done
    done < <(find "$p" -maxdepth 1 -type f \( -iname '*.rep' -o -iname '*.jsp' \) 2>/dev/null)
done
# libraries / menus referenced explicitly but not present in any source directory
{ printf '\n# explicit references without a file in the source directories:\n'
  grep -oE 'explicit=[^ ]+' "$DEP" | sed 's/explicit=//' | tr ',' '\n' | grep -v '^-$' | sort -u | while read -r x; do
      grep -qix "${x%.*}" "$LIBS" || printf '  %s\n' "$x"; done; } >> "$DEP"
# TNS aliases used (userid=x/y@ALIAS) vs tnsnames.ora
{ printf '\n# TNS aliases used in env files / cgicmd.dat / reports config:\n'
  { cat /dev/null "${ENV_FILES[@]}" 2>/dev/null;   # /dev/null: never stdin when ENV_FILES is empty (no Forms)
    grep -v '^#' "$IMP/cgicmd.dat.customer_keys" 2>/dev/null; } \
      | grep -oE '@[A-Za-z0-9_.]+' | sort -u | sed 's/^@//' | while read -r a; do
          if cat "${TNS_DIRS[@]/%//tnsnames.ora}" 2>/dev/null | grep -qiE "^[[:space:]]*$a[[:space:]]*="; then printf '  %s (in tnsnames.ora)\n' "$a"
          else printf '  %s (NOT in a collected tnsnames.ora)\n' "$a"; fi; done; } >> "$DEP"
rm -f "$LIBS"

# =============================================================================
# 6b. Load profile - AGGREGATED counts only (no raw log line leaves the host:
#     access logs hold client IPs, user names and - with GET report calls -
#     even passwords). Read-only; --no-load skips it.
# =============================================================================
LOAD="$STAGE/load"
if $LOADP; then
    say "Load profile (last $LOAD_DAYS days, aggregated) ..."
    mkdir -p "$LOAD"
    # _logs SERVER_GLOB - access logs of the servers, modified in the last LOAD_DAYS days
    _logs() { find "$DH"/servers/$1/logs -maxdepth 1 -type f -name 'access.log*' -mtime -"$LOAD_DAYS" 2>/dev/null | sort; }
    _cat()  { case "$1" in *.gz) zcat -- "$1" 2>/dev/null ;; *) cat -- "$1" 2>/dev/null ;; esac; }
    # ELF access log (WebLogic "extended", #Fields header) - field positions from the header
    _elf_awk='
        /^#Fields:/ { dI=tI=uI=sI=ttI=0; n=split($0,a,/[ \t]+/)
                      for (i=2;i<=n;i++) { f=a[i]; j=i-1
                          if (f=="date") dI=j; else if (f=="time") tI=j; else if (f=="cs-uri") uI=j
                          else if (f=="sc-status") sI=j; else if (f=="time-taken") ttI=j }
                      next }
        /^#/ || !dI || !uI { next }
        { d=$dI; h=substr($tI,1,2); u=$uI; st=$sI; if (d !~ /^[0-9][0-9][0-9][0-9]-/ || d < cut) next }'
    LOAD_CUT="$(date -d "-$LOAD_DAYS days" +%Y-%m-%d)"
    # --- Forms ---------------------------------------------------------------
    mapfile -t _fl < <(_logs '*FORMS*')
    if [ ${#_fl[@]} -gt 0 ]; then
        for f in "${_fl[@]}"; do _cat "$f"; done | awk -v cut="$LOAD_CUT" "$_elf_awk"'
            u ~ /\/frmservlet/ && st ~ /^2/ { c="default"
                if (match(u, /[?&]config=[^&]+/)) { c=substr(u, RSTART+8, RLENGTH-8) }
                gsub(/[;\t ]/, "_", c); starts[d ";" c]++; hour[h]++ }
            u ~ /\/lservlet/ { ls[d]++ }
            { req[d]++; if (st ~ /^5/) e5[d]++; if (ttI && $ttI ~ /^[0-9.]+$/) { tt[d]+=$ttI; tn[d]++ } }
            END {
                for (k in starts) print k ";" starts[k] > "'"$LOAD"'/forms_starts.csv"
                for (x in hour) print x ";" hour[x] > "'"$LOAD"'/forms_hourly.csv"
                for (x in req) printf "%s;%d;%d;%d;%s\n", x, req[x], ls[x], e5[x], (tn[x] ? sprintf("%.0f", 1000*tt[x]/tn[x]) : "-") > "'"$LOAD"'/forms_traffic.csv"
            }'
        printf '%s\n' "${_fl[@]}" | sed "s#^$DH/#\$DOMAIN_HOME/#" > "$LOAD/forms_logfiles.txt"
    fi
    # frmweb processes right now (concurrent sessions + pool)
    _rss="$(ps -C frmweb -o rss= 2>/dev/null)"
    printf 'frmweb_count=%s\nfrmweb_rss_avg_mb=%s\nfrmweb_rss_max_mb=%s\nfrmweb_rss_total_mb=%s\n' \
        "$(printf '%s\n' "$_rss" | grep -c '[0-9]')" \
        "$(printf '%s\n' "$_rss" | awk 'NF{s+=$1;n++} END{print (n?int(s/n/1024):0)}')" \
        "$(printf '%s\n' "$_rss" | awk 'NF&&$1>m{m=$1} END{print int(m/1024)}')" \
        "$(printf '%s\n' "$_rss" | awk 'NF{s+=$1} END{print int(s/1024)}')" > "$LOAD/now.txt"
    # --- Reports: servlet requests per day and command --------------------------
    mapfile -t _rl < <(_logs '*REPORTS*')
    if [ ${#_rl[@]} -gt 0 ]; then
        for f in "${_rl[@]}"; do _cat "$f"; done | awk -v cut="$LOAD_CUT" "$_elf_awk"'
            u ~ /\/rwservlet/ { c=u; sub(/^.*\/rwservlet\/?/, "", c); sub(/[?;].*$/, "", c); if (c=="") c="(report run)"
                gsub(/[0-9]+$/, "", c); k=d ";" c; r[k]++; if (st ~ /^5/) e[k]++ }
            END { for (k in r) printf "%s;%d;%d\n", k, r[k], e[k] > "'"$LOAD"'/reports_requests.csv" }'
    fi
    # engine processes right now
    printf 'rwengine_count=%s\n' "$(pgrep -fc 'RWEngine|rwEng-[0-9]' 2>/dev/null)" >> "$LOAD/now.txt"
    # --- Reports: getserverinfo + past jobs of every RUNNING server --------------
    # (a not running in-process server is NOT asked - the request would start it)
    _rport="$(awk '/<server>/{s=1;n="";p=""} s&&/<name>/&&n==""{n=$0; gsub(/.*<name>|<\/name>.*/,"",n)} s&&/<listen-port>/{p=$0; gsub(/.*<listen-port>|<\/listen-port>.*/,"",p)}
                   /<\/server>/{ if (s && n ~ /REPORTS/ && p != "") { print p; exit } s=0 }' "$DH/config/config.xml" 2>/dev/null)"
    RWURL="http://127.0.0.1:${_rport:-9002}/reports/rwservlet"
    # _rw CMD SERVER OUTFILE [extra data] - POST, authid only via curl config on stdin
    _rw() {
        { printf 'url = "%s/%s"\n' "$RWURL" "$1"
          printf 'data = "server=%s&statusformat=XML%s"\n' "$2" "${4:+&$4}"
          [ -n "$RWAUTH" ] && printf 'data-urlencode = "authid=%s"\n' "$RWAUTH"
        } | curl -s -m 60 -K - -o "$3" -w '%{http_code}' 2>/dev/null
    }
    if command -v curl >/dev/null 2>&1; then
        awk -F';' 'NR>1 && $1!~/^#/ && $3=="yes" {print $1}' "$RSV" | sort -u | while read -r rs; do
            code="$(_rw getserverinfo "$rs" "$LOAD/reports_${rs}_serverinfo.xml")"
            if ! grep -q '<serverInfo' "$LOAD/reports_${rs}_serverinfo.xml" 2>/dev/null; then
                printf '%s;getserverinfo;HTTP %s - no serverInfo (secured server: --rw-auth USER)\n' "$rs" "$code" >> "$LOAD/reports_not_collected.txt"
                rm -f "$LOAD/reports_${rs}_serverinfo.xml"; continue
            fi
            _rw showjobs "$rs" "$LOAD/.sj.xml" "queuetype=past&count=1000" >/dev/null
            # one line per past job: server;id;report;status;started_epoch;seconds (no owner, no parameters)
            tr '\n' ' ' < "$LOAD/.sj.xml" | sed 's/<job /\n<job /g' | awk -v s="$rs" '
                function ep(t,   a, m, p, h) { # "Nov 3, 2026, 3:32:15/PM"
                    if (!match(t, /([A-Z][a-z][a-z]) ([0-9]+), ([0-9]+), ([0-9]+):([0-9]+):([0-9]+)\/(AM|PM)/, a)) return ""
                    m = index("JanFebMarAprMayJunJulAugSepOctNovDec", a[1]); m = (m + 2) / 3; h = a[4] % 12; if (a[7] == "PM") h += 12
                    return mktime(a[3] " " m " " a[2] " " h " " a[5] " " a[6]) }
                /^<job / { id=$0; sub(/^<job id="/, "", id); sub(/".*/, "", id)
                    n=$0; if (match(n, /<name>[^<]*<\/name>/)) n=substr(n, RSTART+6, RLENGTH-13); else n="-"
                    c=$0; if (match(c, /<status code="[0-9]+"/)) c=substr(c, RSTART+14, RLENGTH-15); else c="-"
                    a1=$0; b1=$0; st=""; fi=""; sr=""; fr=""
                    if (match(a1, /<started>[^<]*<\/started>/)) { sr=substr(a1, RSTART+9, RLENGTH-19); st=ep(sr) }
                    if (match(b1, /<finished>[^<]*<\/finished>/)) { fr=substr(b1, RSTART+10, RLENGTH-21); fi=ep(fr) }
                    gsub(/[;]/, "_", n); gsub(/[;]/, ",", sr); gsub(/[;]/, ",", fr)
                    printf "%s;%s;%s;%s;%s;%s;%s;%s\n", s, id, n, c, st, ((st != "" && fi != "") ? fi - st : ""), sr, fr }' >> "$LOAD/reports_jobs.csv"
            rm -f "$LOAD/.sj.xml"
        done
    else
        printf 'all;-;curl missing\n' >> "$LOAD/reports_not_collected.txt"
    fi
    RWAUTH=""
    # --- host: sar history (sysstat) + now --------------------------------------
    if command -v sar >/dev/null 2>&1; then
        for f in $(find /var/log/sa -maxdepth 1 -name 'sa[0-9][0-9]' -mtime -"$LOAD_DAYS" 2>/dev/null | sort); do
            d="$(LC_ALL=C sar -f "$f" 2>/dev/null | head -1 | grep -oE '[0-9]{2}/[0-9]{2}/[0-9]{2,4}' | head -1 | awk -F/ '{y=$3; if (length(y)==2) y="20" y; print y "-" $1 "-" $2}')"
            cpu="$(LC_ALL=C sar -u -f "$f" 2>/dev/null | awk '/^Average/ {printf "%.0f", 100 - $NF}')"
            mem="$(LC_ALL=C sar -r -f "$f" 2>/dev/null | awk '/%memused/ {for (i=1;i<=NF;i++) if ($i=="%memused") c=i} /^Average/ && c && $c ~ /^[0-9.]+$/ && $c+0 <= 100 {printf "%.0f", $c; exit}')"
            cpm="$(LC_ALL=C sar -u -f "$f" 2>/dev/null | awk '$1 ~ /^[0-9]/ && $NF ~ /^[0-9.]+$/ {b=100-$NF; if (b>m) m=b} END {printf "%.0f", m}')"
            [ -n "$d" ] && printf '%s;%s;%s;%s\n' "$d" "${cpu:--}" "${cpm:--}" "${mem:--}"
        done > "$LOAD/host_sar.csv"
    fi
    { printf 'uptime=%s\n' "$(uptime -p 2>/dev/null)"
      printf 'loadavg=%s\n' "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
      printf 'load_days=%s\n' "$LOAD_DAYS"; } >> "$LOAD/now.txt"
fi

# =============================================================================
# 7. environment.conf proposal
# =============================================================================
PROP="$IMP/environment.conf.proposal"
_first_rs="$(sed -n '2p' "$RSV" | cut -d';' -f1)"
_rc="$(sed -n '2p' "$RSV" | cut -d';' -f4)"
_eng() { grep -m1 -oE "$1=\"[0-9]+\"" "$_rc" 2>/dev/null | grep -oE '[0-9]+'; }
_fp1="$(for ef in "${ENV_FILES[@]}"; do _cfgval "$ef" FORMS_PATH; done | head -1 | cut -d: -f1)"
{
    printf '# Proposal for environment.conf of the 14c installation – review, nothing is applied\n'
    printf '# source host: %s, %s\n\n' "$HOST" "$(date '+%Y-%m-%d %H:%M')"
    printf 'REPORTS_SERVER_NAMES="%s"\n' "$(awk -F';' 'NR>1 && $1!~/^#/{print $1}' "$RSV" | paste -sd' ')"
    printf 'REPORTS_PATH="%s"\n' "$(printf '%s\n' "${!SRCDIR[@]}" | while read -r p; do case "${SRCDIR[$p]}" in *REPORTS_PATH*|*folderAccess.read*) printf '%s\n' "$p";; esac; done | sort -u | paste -sd:)"
    # REPORTS_TMP: the <write> directory; many sibling directories (one per
    # user) -> propose their parent instead of the first user's directory
    _wd="$(printf '%s\n' "${!SRCDIR[@]}" | while read -r p; do case "${SRCDIR[$p]}" in *folderAccess.write*) printf '%s\n' "$p";; esac; done | sort)"
    _wp="$(printf '%s\n' "$_wd" | sed '/^$/d' | sed 's#/[^/]*$##' | sort | uniq -c | sort -rn | awk '$1 > 5 {print $2; exit}')"
    if [ -n "$_wp" ]; then
        printf 'REPORTS_TMP="%s"   # %s write directories below it (one per user?) - choose one output directory\n' \
            "$_wp" "$(printf '%s\n' "$_wd" | grep -c "^$_wp/")"
    else
        printf 'REPORTS_TMP="%s"\n' "$(printf '%s\n' "$_wd" | sed '/^$/d' | head -1)"
    fi
    unset _wd _wp
    printf 'REPORTS_ENGINE_INIT="%s"\nREPORTS_ENGINE_MIN="%s"\nREPORTS_ENGINE_MAX="%s"\nREPORTS_ENGINE_LIFE="%s"\n' \
        "$(_eng initEngine)" "$(_eng minEngine)" "$(_eng maxEngine)" "$(_eng engLife)"
    printf 'REPORTS_MAX_CONNECT="%s"\n' "$(grep -m1 -oE 'maxConnect="[0-9]+"' "$_rc" 2>/dev/null | grep -oE '[0-9]+')"
    printf 'REPORTS_MAX_QUEUE="%s"\n' "$(grep -m1 -oE 'maxQueueSize="[0-9]+"' "$_rc" 2>/dev/null | grep -oE '[0-9]+')"
    printf 'REPORTS_BROADCAST_PORT="%s"   # 14c: choose a port unique in the subnet\n' "$(sed -n '2p' "$RSV" | cut -d';' -f10)"
    printf 'FORMS_CUSTOMER_DIR="%s"\n' "$(_expand "${_fp1:-}")"
    printf 'NLS_LANG="%s"\n' "$(for ef in "${ENV_FILES[@]}"; do _cfgval "$ef" NLS_LANG; done | head -1)"
    printf 'TNS_ADMIN_SOURCE="%s"   # old TNS_ADMIN directories; 14c uses one TNS_ADMIN\n' "$(printf '%s ' "${TNS_DIRS[@]}")"
    for fw in "${FORMS_CFGS[@]}"; do
        printf 'FORMS_MAX_RUNTIME_PROCESSES="%s"\n' "$(_sections "$fw" | awk -F'\t' '$1=="default"&&$2=="maxRuntimeProcesses"{print $3}')"
        _sections "$fw" | awk -F'\t' '$2=="prestartRuntimes"&&tolower($3)=="true"{print "FORMS_PRESTART_SECTION=\"" $1 "\""}' | head -1
    done
    # ports / listen address of the servers (config.xml; AdminServer default 7001)
    _sp() { awk -v w="$1" '/<server>/{s=1;n="";p="";a="";sub_=0} /<(ssl|network-access-point|web-server|server-start|log)>/{sub_++} /<\/(ssl|network-access-point|web-server|server-start|log)>/{sub_--; next} sub_>0{next}
              s&&/<name>/&&n==""{n=$0; gsub(/.*<name>|<\/name>.*/,"",n)}
              s&&/<listen-port>/&&p==""{p=$0; gsub(/.*<listen-port>|<\/listen-port>.*/,"",p)}
              s&&/<listen-address>/&&a==""{a=$0; gsub(/.*<listen-address>|<\/listen-address>.*/,"",a)}
              /<\/server>/{ if (s && n ~ w) { print (p==""?"7001":p) ";" a; exit } s=0 }' "$DH/config/config.xml" 2>/dev/null; }
    printf 'WLS_ADMIN_PORT="%s"\n'   "$(_sp '^AdminServer$' | cut -d';' -f1)"
    printf 'WLS_FORMS_PORT="%s"\n'   "$(_sp 'FORMS' | cut -d';' -f1)"
    printf 'WLS_REPORTS_PORT="%s"\n' "$(_sp 'REPORTS' | cut -d';' -f1)"
    printf 'WLS_LISTEN_ADDRESS="%s"   # 14c default: 127.0.0.1 behind Nginx\n' "$(_sp '^AdminServer$' | cut -d';' -f2)"
    printf 'WLS_NODEMANAGER_PORT="%s"\n' "$(_cfgval "$DH/nodemanager/nodemanager.properties" ListenPort | tail -1)"
    # old public name: server name of the HTTPS route to /forms, else any HTTPS / OHS ServerName
    _sn="$(awk -F';' 'NR>1 && $5=="yes" && $7 ~ /forms/ {print $4} NR>1 && $5=="yes" {print $4} NR>1 {print $4}' "$WT_TXT" \
           | tr ',' '\n' | grep -vE '^(_|localhost|\*.*|-)?$' | head -1)"
    [ -z "$_sn" ] && _sn="$(for h in "$CFG"/components/OHS/*/httpd.conf; do sed -n 's/^[[:space:]]*ServerName[[:space:]]\+//p' "$h" 2>/dev/null; done | head -1)"
    _sn="${_sn#*://}"; _sn="${_sn%%:*}"
    printf 'WLS_SERVER_FQDN="%s"   # OLD public name - the 14c host may get a new name / DNS alias\n' "${_sn:-$(hostname -f 2>/dev/null)}"
    printf 'WEB_TIER_OLD="%s"   # web server(s) in front today - 14c: Nginx (04-root_nginx.sh)\n' \
        "$(printf '%s\n' "${WT_FOUND[@]}" | cut -d';' -f1 | sort -u | paste -sd' ')"
    # RCU database of the domain (WLSSchemaDataSource: jdbc:oracle:thin:@//host:port/service
    # or a descriptor - RCU writes (host=..)(port=..)(service_name=..) in lower case: sed I)
    _ru="$(awk -F';' '$1=="WLSSchemaDataSource"{print $2 ";" $3}' "$JDBC_TXT" 2>/dev/null)"
    _url="${_ru%%;*}"; _usr="${_ru#*;}"
    _hp="$(printf '%s' "$_url" | sed -n 's#.*@//\([^/]*\)/\(.*\)#\1;\2#p')"
    [ -z "$_hp" ] && _hp="$(printf '%s' "$_url" | sed -n 's#.*HOST=\([^)]*\).*PORT=\([0-9]*\).*SERVICE_NAME=\([^)]*\).*#\1:\2;\3#Ip')"
    printf 'DB_HOST="%s"   # RCU database of the OLD domain - 14c needs a new RCU (14.1.2 schemas)\n' "$(printf '%s' "${_hp%%;*}" | cut -d: -f1)"
    printf 'DB_PORT="%s"\n' "$(printf '%s' "${_hp%%;*}" | sed -n 's/.*:\([0-9]*\)$/\1/p')"
    printf 'DB_SERVICE="%s"\n' "${_hp#*;}"
    printf 'DB_SCHEMA_PREFIX="%s"   # old prefix - choose a new one for the 14c RCU\n' "${_usr%%_*}"
    unset _sn _ru _url _usr _hp
} > "$PROP"
unset _first_rs _rc _fp1

# =============================================================================
# 8. Report + packaging
# =============================================================================
{
    printf 'Forms & Reports configuration export – %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf 'export_forms_reports_conf.sh %s (ihw_tools_lib %s) – %s\n\n' "$VERSION" "$(ihwt_lib_version)" "$($MASKED && printf 'passwords MASKED' || printf 'passwords INCLUDED – archive encrypted')"
    printf '!!! Contains customer data – NEVER commit to git, keep encrypted, delete after the import.\n\n'
    printf '%-24s %s\n' Host "$(hostname -f 2>/dev/null || hostname)" ORACLE_HOME "$OH" DOMAIN_HOME "$DH"
    printf '%-24s %s\n' "FMW version" "$(grep -m1 -oE 'version="1[0-9.]+"' "$OH/inventory/registry.xml" 2>/dev/null)"
    printf '%-24s %s\n' "Java" "$("$OH/oracle_common/jdk/bin/java" -version 2>&1 | head -1)"
    printf '%-24s %s\n' "CPUs" "$(nproc 2>/dev/null)"
    printf '%-24s %s\n' "RAM MB" "$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    printf '\n== Forms ==\n'; printf '  %s\n' "${FORMS_CFGS[@]:-none}"
    printf '  env files: %s\n' "${ENV_FILES[*]:-none}"
    printf '  sections: %s\n' "$(for fw in "${FORMS_CFGS[@]}"; do grep -oE '^\[[^]]+\]' "$fw"; done | tr -d '[]' | sort -u | paste -sd' ')"
    printf '\n== Reports servers (ihw_import/reports_servers.txt) ==\n'; sed 's/^/  /' "$RSV"
    printf '\n== Web tier (ihw_import/web_tier.txt, web_tier_settings.txt) ==\n'
    [ ${#WT_FOUND[@]} -gt 0 ] && printf '  %s\n' "${WT_FOUND[@]}" || printf '  none found\n'
    awk -F';' 'NR>1 {n[$1]++} END {for (t in n) printf "  %s: %d route(s)\n", t, n[t]}' "$WT_TXT"
    printf '\n== Customer jars (ihw_import/jars.txt) – FSAL / JACOB / frm*.jar excluded ==\n'; sed 's/^/  /' "$JARS"
    printf '\n== Fonts (ihw_import/fonts.txt) ==\n'
    printf '  %s font file(s): %s customer, %s Microsoft, %s free (skipped – 14b- deploys them)\n' \
        "$(($(wc -l < "$FONTS_TXT") - 1))" "$(grep -c ';customer;' "$FONTS_TXT")" "$(grep -c ';ms;' "$FONTS_TXT")" "$(grep -c ';free;' "$FONTS_TXT")"
    printf '\n  Customer fonts (barcode, corporate ...) – must move to 14c, no replacement:\n'
    awk -F';' '$4=="customer"{printf "    %-28s %10s  %s\n", $1, $2, $3}' "$FONTS_TXT"
    printf '\n  Microsoft fonts – licensed with Windows / Office of THIS host: the Windows licence does\n'
    printf '  NOT allow copying them to another server (Microsoft font FAQ). 14c uses the free\n'
    printf '  replacement; the original only with extended rights (Monotype / foundry). "similar" =\n'
    printf '  line breaks / field widths can shift; symbol fonts have no replacement.\n'
    printf '  Background: 80-FMW-Architecture/reports_fonts_architecture.md\n'
    awk -F';' '$4=="ms"{printf "    %-28s %10s  -> %s\n", $1, $2, $5}' "$FONTS_TXT"

    printf '\n== Source directories (sources_inventory.csv) – inventory only, no module content ==\n'; sed 's/^/  /' "$INV"
    printf '\n== Secrets (secrets_locations.txt: file:line:keyword – values never listed) ==\n'
    printf '  %s locations\n' "$(wc -l < "$SECRETS")"
    printf '\n== ihw_import/ – what goes where ==\n'
    printf '  Import with 00-Setup/customer_conf_import.sh -i <this archive> (overlay environments/<env>.customer/,\n'
    printf '  read by 13- / 14- / 14b-; process: 09-Install/docs/00-transfer_customer_settings.md)\n'
    printf '  formsweb.cfg.default_overrides -> overlay forms/formsweb.default.cfg      (14-)\n'
    printf '  formsweb.cfg.sections          -> overlay forms/formsweb.sections.cfg     (14-)\n'
    printf '  default.env.customer_keys      -> overlay forms/env/<name>.env            (14-)\n'
    printf '  webutil.cfg.overrides          -> overlay forms/webutil.cfg.overrides     (14-)\n'
    printf '  forms_java/ + jars.txt         -> overlay forms/jars/ (deduplicated, signed by 14-)\n'
    printf '  reports_servers.txt            -> REPORTS_SERVER_INSTANCES + overlay reports/<server>.env (13-)\n'
    printf '  cgicmd.dat.customer_keys       -> overlay reports/cgicmd.dat.customer, without logins (14b-)\n'
    printf '  uifont.ali.customer            -> overlay fonts/uifont.ali.customer       (14b-)\n'
    printf '  custom_fonts_dir/              -> overlay fonts/ (customer fonts; Microsoft fonts only with licence – fonts.txt class)\n'
    printf '  environment.conf.proposal      -> import block of environments/<env>.conf\n'
    printf '  web_tier.txt                   -> 09-Install/nginx-wls.conf.template (04-root_nginx.sh): own paths by hand\n'
    if $LOADP; then
        printf '\n== Load profile (load/, last %s days, aggregated - no log lines) ==\n' "$LOAD_DAYS"
        printf '  Forms starts: %s   Forms days: %s   Reports jobs (past queue): %s   sar days: %s\n' \
            "$(awk -F';' '{s+=$3} END{print s+0}' "$LOAD/forms_starts.csv" 2>/dev/null)" "$(cat "$LOAD/forms_traffic.csv" 2>/dev/null | wc -l)" \
            "$(cat "$LOAD/reports_jobs.csv" 2>/dev/null | wc -l)" "$(cat "$LOAD/host_sar.csv" 2>/dev/null | wc -l)"
        # a missing file is no error: no jobs (secured server without --rw-auth -> "not collected"), no sysstat
        [ -f "$LOAD/reports_not_collected.txt" ] && sed 's/^/  not collected: /' "$LOAD/reports_not_collected.txt"
        sed 's/^/  /' "$LOAD/now.txt"
    fi
    [ ${#WARNINGS[@]} -gt 0 ] && { printf '\n== Warnings ==\n'; printf '  %s\n' "${WARNINGS[@]}"; }
    printf '\n== Files (manifest.csv) ==\n  %s files\n' "$(($(wc -l < "$MANIFEST") - 1))"
} > "$REPORT"

# --masked: the derived files (ihw_import/, reports_servers, dependencies …)
# quote config lines too – mask every text file outside raw/ (already masked)
if $MASKED; then
    while IFS= read -r -d '' f; do
        grep -Iq . "$f" 2>/dev/null || continue                # text files only (no jars / fonts)
        mask < "$f" > "$f.m" && mv -f "$f.m" "$f"
    done < <(find "$STAGE" -path "$STAGE/raw" -prune -o -type f -print0)
fi

cd "$OUTBASE" || exit 2
ARCH="$NAME.zip"                                   # for the abort trap
ihwt_pack "$OUTBASE" "$NAME" "$($MASKED && printf false || printf true)" || exit 2
ARCH="$IHWT_ARCHIVE"
$KEEP || rm -rf "${OUTBASE:?}/${NAME:?}"
DONE=true

printf '\n'
say "Archive : $OUTBASE/$ARCH ($(du -h "$ARCH" | cut -f1))"
say "SHA-256 : $OUTBASE/$ARCH.sha256"
if ! $MASKED; then
    say "Decrypt : openssl enc -d $IHWT_ENC_OPTS -in $ARCH -out ${ARCH%.enc}"
fi
$KEEP && say "Staging : $STAGE (kept – contains $($MASKED && printf 'masked' || printf 'CLEAR-TEXT') data, delete it)"
[ ${#WARNINGS[@]} -gt 0 ] && say "${#WARNINGS[@]} warning(s) – see 00_report.txt"
say "Contains customer data – never commit it to git."
exit 0
