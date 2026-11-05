#!/bin/bash
# =============================================================================
# Script   : analyse_forms_reports_export.sh
# Purpose  : Turn a configuration export of export_forms_reports_conf.sh into
#            a structured analysis report (Markdown) for the customer:
#            Forms sections, env files, WebUtil, customer jars, Reports
#            servers, fonts, source directories, dependencies, TNS aliases,
#            secrets (counted, never shown), the 14c target mapping and
#            rule-based findings (security first).
#            Template: ../customer-analyse/import_analyse_template.md
# Call     : analyse_forms_reports_export.sh -i <export.zip|export.zip.enc|dir>
#                 -k <customer> [-o <outbase>] [--date YYYY-MM-DD]
#                 [--ref-home <14c ORACLE_HOME>] [--fresh]
#            -i          the export (zip, encrypted zip or unpacked directory)
#            -k          short customer name (directory + report name)
#            -o          base directory (default ../customer-analyse next to
#                        this script) - must be git-ignored inside a work tree
#            --date      date of the run directory (default today)
#            --ref-home  14c ORACLE_HOME for the comparison with Oracle's 14c
#                        templates (default $ORACLE_HOME, else
#                        /u01/app/oracle/fmw); without it those rules are
#                        listed as "not checked"
#            --fresh     unpack the export again (default: reuse export/)
# Output   : <outbase>/<date>_<customer>/import_analyse_<customer>_<date>.md
#            + csv/ (tables) + export/ (unpacked export - clear text!)
# Safety   : every value passes ihwt_mask; secrets are only counted; the
#            finished report is checked for clear-text patterns and deleted
#            on a hit. Customer data - NEVER commit the output.
# Runs as  : any user with read access to the export (oracle on our host)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

set -u
umask 077
VERSION="2026-11-05.1"
_IHWT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ihw_tools_lib.sh
. "$_IHWT_DIR/ihw_tools_lib.sh" || { printf 'ihw_tools_lib.sh missing next to %s\n' "$0" >&2; exit 2; }

IN=""; CUST=""; OUTBASE="$_IHWT_DIR/../customer-analyse"; DATE="$(date +%Y-%m-%d)"
REF_HOME="${ORACLE_HOME:-/u01/app/oracle/fmw}"; FRESH=false
TEMPLATE="$_IHWT_DIR/../customer-analyse/import_analyse_template.md"
while [ $# -gt 0 ]; do
    case "$1" in
        -i) IN="${2:-}"; shift ;;
        -k) CUST="${2:-}"; shift ;;
        -o) OUTBASE="${2:-}"; shift ;;
        --date) DATE="${2:-}"; shift ;;
        --ref-home) REF_HOME="${2:-}"; shift ;;
        --fresh) FRESH=true ;;
        -h|--help) sed -n '2,32p' "$0"; printf 'Version: %s\n' "$VERSION"; exit 0 ;;
        -V|--version) printf '%s\n' "$VERSION"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
say() { printf '  %s\n' "$*"; }
die() { printf '  ERROR %s\n' "$*" >&2; exit 2; }
[ -n "$IN" ] && [ -e "$IN" ] || die "export not found: -i <export.zip|.zip.enc|dir>"
[[ "$CUST" =~ ^[A-Za-z0-9_-]+$ ]] || die "-k <customer>: letters, digits, _ and - only"
[[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--date YYYY-MM-DD"
[ -f "$TEMPLATE" ] || die "template missing: $TEMPLATE"
mkdir -p "$OUTBASE" 2>/dev/null
OUTBASE="$(cd "$OUTBASE" 2>/dev/null && pwd)" || die "output base not found"
RUNNAME="${DATE}_${CUST}"
ihwt_git_guard "$OUTBASE" "$RUNNAME" || exit 2

RUN="$OUTBASE/$RUNNAME"
REPORT="$RUN/import_analyse_${CUST}_${DATE}.md"
CSV="$RUN/csv"; MD="$RUN/.md"
mkdir -p "$RUN" "$CSV" "$MD" || exit 2
IN="$(readlink -f "$IN")"
say "analyse_forms_reports_export.sh $VERSION (ihw_tools_lib $(ihwt_lib_version))"
say "export  $IN"
say "run dir $RUN"

# =============================================================================
# 1. unpack
# =============================================================================
if [ -d "$IN" ]; then
    EXPDIR="$IN"
else
    EXPDIR="$RUN/export"
    if $FRESH || [ ! -d "$EXPDIR" ]; then
        rm -rf "${EXPDIR:?}"; mkdir -p "$EXPDIR"
        case "$IN" in
            *.enc)
                ihwt_decrypt "$IN" "$RUN/.export.zip" || die "decryption failed"
                unzip -q "$RUN/.export.zip" -d "$EXPDIR" || { rm -f "$RUN/.export.zip"; die "unzip failed"; }
                rm -f "$RUN/.export.zip" ;;
            *.zip)    unzip -q "$IN" -d "$EXPDIR" || die "unzip failed" ;;
            *.tar.gz) tar -xzf "$IN" -C "$EXPDIR" || die "tar failed" ;;
            *) die "unknown export format: $IN" ;;
        esac
    fi
fi
ROOT="$(dirname "$(find "$EXPDIR" -maxdepth 3 -name 00_report.txt | head -1)")"
[ -f "$ROOT/00_report.txt" ] || die "no 00_report.txt in the export"
IMP="$ROOT/ihw_import"; RAW="$ROOT/raw"

# --- small helpers -------------------------------------------------------------
M()   { ihwt_mask; }                                     # mask whole CSV lines (fields are built without ";")
mv1() { printf '%s' "$1" | ihwt_mask | sed 's/;/,/g; s/|/\\|/g'; }
md()  { ihwt_md_table "$1" > "$MD/$2.md"; }              # stdin CSV -> block file
short() { local p="$1"; p="${p/#$SRC_DH/\$DOMAIN_HOME}"; p="${p/#$SRC_OH/\$ORACLE_HOME}"; printf '%s' "$p"; }
FIND="$CSV/findings.csv"; : > "$FIND"; : > "$CSV/.rs_conf"
NOTCHK="$CSV/not_checked.csv"; : > "$NOTCHK"
f_add() {   # severity area finding recommendation - long lists are cut after 12 items
    local t; t="$(printf '%s' "$3" | sed 's/;/,/g' | awk -F, -v OFS=, '{ if (NF > 12) { n=NF; NF=12; print $0 " ... (+" n-12 " more - see the tables above)" } else print }')"
    printf '%s;%s;%s;%s\n' "$1" "$2" "$t" "$(printf '%s' "$4" | sed 's/;/,/g')" >> "$FIND"
}
nc_add() { printf '%s;%s\n' "$1" "$2" >> "$NOTCHK"; }
cnt() { local n; n="$(grep -c "$@" 2>/dev/null)"; printf '%s' "${n:-0}"; }
# _secret_hits FILE_ERE KEYWORD_ERE - secret keyword hits on ACTIVE lines
# (not comments) of the files matching FILE_ERE (paths in secrets_locations.txt)
_secret_hits() {
    local n=0 rel ln
    [ -f "$ROOT/secrets_locations.txt" ] || { printf 0; return; }
    while IFS=: read -r rel ln _; do
        printf '%s' "$rel" | grep -qE "$1" || continue
        sed -n "${ln}p" "$ROOT/$rel" 2>/dev/null | grep -qE '^[[:space:]]*(#|;|REM[[:space:]]|<!--)' && continue
        n=$((n + 1))
    done < <(grep -iE ":[0-9]+:($2)" "$ROOT/secrets_locations.txt")
    printf '%s' "$n"
}
nlist() { [ -z "$1" ] && { printf 0; return; }; printf '%s' "$1" | tr ',' '\n' | grep -c .; }

# --- header values -------------------------------------------------------------
_hv() { sed -n "s/^$1[[:space:]]\{2,\}//p" "$ROOT/00_report.txt" | head -1; }
SRC_HOST="$(_hv Host)"; SRC_OH="$(_hv ORACLE_HOME)"; SRC_DH="$(_hv DOMAIN_HOME)"
SRC_FMW="$(_hv 'FMW version' | sed 's/version=//; s/"//g')"; SRC_JAVA="$(_hv Java)"
SRC_CPUS="$(_hv CPUs)"; SRC_RAM="$(_hv 'RAM MB')"
EXP_VER="$(sed -n '2s/^export_forms_reports_conf.sh \([0-9.-]*\).*/\1/p' "$ROOT/00_report.txt")"
[ -n "$EXP_VER" ] || say "WARN unknown export version"
REF="$REF_HOME/forms/templates/config"
if [ -f "$REF/formsweb.cfg" ]; then
    REF_INFO="Oracle's 14.1.2 templates in \`$REF\`"; HAVE_REF=true
else
    REF_INFO="none (no --ref-home) – rules against the 14c templates not checked"; HAVE_REF=false
    nc_add "Forms / WebUtil keys against Oracle's 14c templates" "no 14c ORACLE_HOME (--ref-home)"
fi
KEYTOOL=""
for k in "${JAVA_HOME:-/nonexistent}/bin/keytool" "$REF_HOME/oracle_common/jdk/bin/keytool" /u01/app/oracle/java/jdk-21/bin/keytool; do
    [ -x "$k" ] && { KEYTOOL="$k"; break; }
done
[ -z "$KEYTOOL" ] && KEYTOOL="$(command -v keytool 2>/dev/null)"

# raw files of the export
FW="$(find "$RAW" -path '*/config/formsweb.cfg' 2>/dev/null | head -1)"
FWDIR="$(dirname "${FW:-/nonexistent/x}")"
WU="$(find "$RAW" -path '*/FORMS/instances/*/server/webutil.cfg' 2>/dev/null | head -1)"
CONFIG_XML="$(find "$RAW" -path '*/domain/config/config.xml' 2>/dev/null | head -1)"
NMPROP="$(find "$RAW" -name nodemanager.properties 2>/dev/null | head -1)"
mapfile -t TNSFILES < <(find "$RAW" -name tnsnames.ora 2>/dev/null | sort)
mapfile -t SQLNETS  < <(find "$RAW" -name sqlnet.ora 2>/dev/null | sort)
mapfile -t RWSERVLETS < <(find "$RAW" -name rwservlet.properties 2>/dev/null | sort)
mapfile -t RWCONFS < <(find "$RAW" -name rwserver.conf 2>/dev/null | sort)
mapfile -t OHSCONFS < <(find "$RAW" -name mod_wl_ohs.conf 2>/dev/null | sort)
say "Forms / Reports / fonts / sources / net ..."

# =============================================================================
# 2. Forms sections
# =============================================================================
N_SEC=0
if [ -f "$FW" ]; then
    ihwt_sections "$FW" > "$CSV/.fw_all.tsv"
    awk -F'\t' '
        { s=$1; if (!(s in seen)) { seen[s]=1; order[++n]=s } }
        $2=="form"      { form[s]=$3 }
        $2=="envFile"   { env[s]=$3 }
        $2=="archive"   { j=$3; gsub(/[^,]/,"",j); jars[s]=length(j)+1 }
        $2=="userid"    { u[s]=($3=="" ? "-" : ($3 ~ /^%.*%$/ ? $3 : ($3 ~ /^\{AES/ ? "yes (encrypted)" : "yes (clear text)"))) }
        $2=="allow_debug" { dbg[s]=$3 }
        { keys[s]++ }
        END { for (i=1;i<=n;i++) { s=order[i]
                printf "%s;%s;%s;%s;%s;%s;%s\n", s, (s in form?form[s]:"-"), (s in env?env[s]:"-"),
                    (s in jars?jars[s]:"-"), (s in u?u[s]:"-"), (s in dbg?dbg[s]:"-"), keys[s] } }' \
        "$CSV/.fw_all.tsv" | M > "$CSV/forms_sections.csv"
    N_SEC="$(wc -l < "$CSV/forms_sections.csv")"
else
    : > "$CSV/forms_sections.csv"
    nc_add "Forms (formsweb.cfg)" "no formsweb.cfg in the export"
fi
md "Section;form;envFile;jars (archive);userid;allow_debug;keys" forms_sections < "$CSV/forms_sections.csv"

# [default] overrides + 14c standard
if $HAVE_REF; then ihwt_sections "$REF/formsweb.cfg" > "$CSV/.ref_fw.tsv"; else : > "$CSV/.ref_fw.tsv"; fi
grep -v '^#' "$IMP/formsweb.cfg.default_overrides" 2>/dev/null | grep '=' | while IFS= read -r l; do
    k="${l%%=*}"; v="${l#*=}"
    r="$(awk -F'\t' -v k="$k" '$1=="default" && $2==k {print $3; exit}' "$CSV/.ref_fw.tsv")"
    $HAVE_REF && [ -z "$r" ] && r="(not in the 14c template)"
    printf '%s;%s;%s\n' "$k" "$(mv1 "$v")" "$(mv1 "${r:--}")"
done > "$CSV/forms_default.csv"
md "Key;customer value;14c standard" forms_default < "$CSV/forms_default.csv"

# all keys of the customer sections (not Oracle's standard sections)
STD_SECTIONS="default sepwin debug webutil jnlp webutil_jnlp webstart webutil_webstart standaloneapp webutil_standaloneapp"
if [ -f "$FW" ]; then
    awk -F'\t' -v std=" $STD_SECTIONS " 'index(std, " " $1 " ")==0 {print $1 ";" $2 ";" $3}' "$CSV/.fw_all.tsv" \
        | ihwt_mask | sed -E 's/^([^;]*;[^;]*;)(.*)$/\1\2/' \
        | awk -F';' '{v=$0; sub(/^[^;]*;[^;]*;/,"",v); gsub(/;/,",",v); if(length(v)>120) v=substr(v,1,117) "..."; print $1 ";" $2 ";" v}' \
        > "$CSV/forms_section_keys.csv"
else : > "$CSV/forms_section_keys.csv"; fi
md "Section;key;value" forms_section_keys < "$CSV/forms_section_keys.csv"

# =============================================================================
# 3. env files
# =============================================================================
mapfile -t ENVFILES < <(find "$FWDIR" -maxdepth 1 -name '*.env' 2>/dev/null | sort)
: > "$CSV/env_files.csv"
for ef in "${ENVFILES[@]}"; do
    b="$(basename "$ef")"
    secs="$(awk -F'\t' -v b="$b" '$2=="envFile" && $3==b {print $1}' "$CSV/.fw_all.tsv" 2>/dev/null | paste -sd, -)"
    nk="$(ihwt_keys "$ef" | wc -l)"
    nd="$(awk -v f="/$b " 'index($0, f) && /^# / {on=1; next} /^# \// {on=0} on && /=/ && !/^#/ {n++} END{print n+0}' "$IMP/default.env.customer_keys" 2>/dev/null)"
    nls="$(ihwt_cfgval "$ef" NLS_LANG | head -1)"; tns="$(ihwt_cfgval "$ef" TNS_ADMIN | head -1)"
    fp="$(awk -v f="/$b " 'index($0, f) && /^# / {on=1; next} /^# \// {on=0} on && /^FORMS_PATH_CUSTOMER=/ {sub(/^FORMS_PATH_CUSTOMER=/,""); print; exit}' "$IMP/default.env.customer_keys" 2>/dev/null)"
    printf '%s;%s;%s;%s;%s;%s;%s\n' "$b" "${secs:--}" "$nk" "${nd:-0}" "${nls:--}" "$(short "${tns:--}")" "$(short "${fp:--}")"
done | M > "$CSV/env_files.csv"
md "File;used by sections;keys;differ from Oracle;NLS_LANG;TNS_ADMIN;FORMS_PATH (customer part)" env_files < "$CSV/env_files.csv"

awk '/^# \// { f=$2; n=split(f,a,"/"); f=a[n]; next } /^#/ || !/=/ {next}
     { k=$0; sub(/=.*/,"",k); v=$0; sub(/^[^=]*=/,"",v); gsub(/;/,",",v); if(length(v)>100) v=substr(v,1,97) "..."; print f ";" k ";" v }' \
    "$IMP/default.env.customer_keys" 2>/dev/null | M > "$CSV/env_keys.csv"
md "File;key;value" env_keys < "$CSV/env_keys.csv"

# --- Forms runtime: timeout chain per section (rules of 06-FormsDiag/forms_perf_settings.sh) ---
#   heartBeat (formsweb.cfg, minutes, default 2) < FORMS_TIMEOUT (envFile, minutes,
#   default 15, Oracle: valid 3-1440) < session-timeout of the Forms servlet
SESS_XML="$(find "$RAW" -path '*formsweb.war/WEB-INF/weblogic.xml' 2>/dev/null | head -1)"
SESS_MIN=""
[ -f "$SESS_XML" ] && SESS_MIN="$(sed -n 's/.*<timeout-secs>\([0-9]*\)<\/timeout-secs>.*/\1/p' "$SESS_XML" | head -1)"
[ -n "$SESS_MIN" ] && SESS_MIN=$((SESS_MIN / 60))
_fwget() {   # section key -> value (section, else [default]) - keys case-insensitive
    local v
    v="$(awk -F'\t' -v s="$1" -v k="$2" '$1==s && tolower($2)==tolower(k) {print $3}' "$CSV/.fw_all.tsv" 2>/dev/null | tail -1)"
    [ -z "$v" ] && [ "$1" != default ] && v="$(awk -F'\t' -v k="$2" '$1=="default" && tolower($2)==tolower(k) {print $3}' "$CSV/.fw_all.tsv" 2>/dev/null | tail -1)"
    printf '%s' "$v"
}
: > "$CSV/forms_timeouts.csv"
if [ -f "$FW" ]; then
    for sec in $(cut -f1 "$CSV/.fw_all.tsv" | awk '!s[$0]++'); do
        case " $STD_SECTIONS " in *" $sec "*) [ "$sec" = default ] || continue ;; esac
        hb="$(_fwget "$sec" heartBeat)"; hbs="set"; [ -z "$hb" ] && { hb=2; hbs="default"; }
        ef="$(_fwget "$sec" envFile)"; ef="${ef:-default.env}"
        to="$(ihwt_cfgval "$FWDIR/$(basename "$ef")" FORMS_TIMEOUT | tail -1)"; tos="set"; [ -z "$to" ] && { to=15; tos="default"; }
        toe="$to"; [ "$to" -lt 3 ] 2>/dev/null && toe=3; [ "$to" -gt 1440 ] 2>/dev/null && toe=1440
        st="ok"
        awk -v a="$hb" -v b="$toe" 'BEGIN{exit !(a+0 >= b+0)}' && st="heartBeat >= FORMS_TIMEOUT"
        [ -n "$SESS_MIN" ] && awk -v a="$hb" -v b="$SESS_MIN" 'BEGIN{exit !(a+0 >= b+0)}' && st="${st/ok/}${st:+, }heartBeat >= session-timeout"
        printf '%s;%s (%s);%s (%s);%s;%s;%s\n' "$sec" "$hb" "$hbs" "$to" "$tos" "$(basename "$ef")" "${SESS_MIN:-not in export}" "${st#, }"
    done > "$CSV/forms_timeouts.csv"
fi
md "Section;heartBeat (min);FORMS_TIMEOUT (min);envFile;servlet session-timeout (min);check" forms_timeouts < "$CSV/forms_timeouts.csv"

# =============================================================================
# 4. WebUtil
# =============================================================================
grep -v '^#' "$IMP/webutil.cfg.overrides" 2>/dev/null | grep '=' | while IFS= read -r l; do
    k="${l%%=*}"; v="${l#*=}"
    r="$($HAVE_REF && ihwt_cfgval "$REF/webutil.cfg" "$(printf '%s' "$k" | sed 's/[.[\*^$]/\\&/g')" | head -1)"
    printf '%s;%s;%s\n' "$k" "$(mv1 "$v")" "$(mv1 "${r:--}")"
done > "$CSV/webutil.csv"
md "Key;customer value;14c standard" webutil < "$CSV/webutil.csv"

# =============================================================================
# 5. jars
# =============================================================================
: > "$CSV/jars.csv"; : > "$CSV/.jar_sig.csv"
if [ -f "$IMP/jars.txt" ]; then
    tail -n +2 "$IMP/jars.txt" | while IFS=';' read -r jp size sha refs stored; do
        jb="$(basename "$jp")"; jf="$ROOT/$stored"
        sig="-"; alg="-"; cls="-"; exp="-"; tsa="-"
        if [ -f "$jf" ]; then
            sf="$(unzip -Z1 "$jf" 2>/dev/null | grep -iE '^META-INF/[^/]+\.SF$' | head -1)"
            if [ -n "$sf" ]; then
                sig="signed"
                alg="$(unzip -p "$jf" "$sf" 2>/dev/null | grep -oE '^[A-Z0-9-]+-Digest(-Manifest)?' | sed 's/-Digest.*//' | sort -u | paste -sd/ -)"
                if [ -n "$KEYTOOL" ]; then
                    kt="$("$KEYTOOL" -printcert -jarfile "$jf" 2>/dev/null)"
                    exp="$(printf '%s\n' "$kt" | sed -n 's/.*[Uu]ntil: //p' | head -1)"
                    [ -n "$exp" ] && exp="$(date -d "$exp" +%Y-%m-%d 2>/dev/null || printf '%s' "$exp")"
                    printf '%s\n' "$kt" | grep -q '^Timestamp:' && tsa="yes" || tsa="no"
                fi
            else sig="unsigned"; fi
            c1="$(unzip -Z1 "$jf" 2>/dev/null | grep '\.class$' | head -1)"
            if [ -n "$c1" ]; then
                major="$(unzip -p "$jf" "$c1" 2>/dev/null | head -c 8 | od -An -tu1 | awk '{print $7*256+$8}')"
                if [ -n "$major" ] && [ "$major" -ge 49 ]; then cls="Java $((major - 44))"
                elif [ -n "$major" ] && [ "$major" -gt 44 ]; then cls="Java 1.$((major - 44))"; fi
            fi
        fi
        case "$refs" in *"not referenced"*) r="not referenced" ;;
            *) r="$(printf '%s' "$refs" | sed -E 's/formsweb\.cfg\[([^]]+)\]\.[A-Za-z_]+/\1/g' | tr ' ' '\n' | sed '/^$/d' | sort -u | paste -sd, -)" ;; esac
        [ "$stored" = "MISSING" ] && st="MISSING" || st="in export"
        printf '%s;%s;%s;%s;%s;%s;%s;%s;%s;%s\n' "$jb" "$size" "${r:--}" "$st" "$sig" "${alg:--}" "${exp:--}" "$tsa" "$cls" "${sha:0:12}"
    done > "$CSV/jars.csv"
fi
[ -z "$KEYTOOL" ] && nc_add "jar signer certificate expiry" "no keytool found (JAVA_HOME / --ref-home)"
md "Jar;size;referenced in (sections / files);status;signature;digest;signer valid until;timestamp;compiled for;sha256 (start)" jars < "$CSV/jars.csv"

# =============================================================================
# 6. Reports
# =============================================================================
# engines read from the rwserver.conf itself (the order in older exports is not fixed)
_rs_raw() { printf '%s' "${1/#$SRC_DH/$RAW/domain}"; }   # source path -> file in the export
# _rs_attr CONF ATTR - attribute of the REPORT engine (id rwEng / class EngineImpl, not the URL engine)
_rs_attr() {
    awk '/<!--/{c=1} c{ if (/-->/) c=0; next } {print}' "$(_rs_raw "$1")" 2>/dev/null | tr '\n' ' ' \
        | grep -oE '<engine [^>]*oracle\.reports\.engine\.EngineImpl[^>]*>' | head -1 \
        | grep -oE "[[:space:]]$2=\"[^\"]*\"" | sed -E 's/^[[:space:]]*[A-Za-z]+="//; s/"$//'
}
_rs_eng() {   # rwserver.conf path on the source host -> "init/min/max"
    local a v out=""
    for a in initEngine minEngine maxEngine; do
        v="$(_rs_attr "$1" "$a")"; out="$out${out:+/}${v:--}"
    done
    printf '%s' "$out"
}
awk -F';' 'NR>1 && $1!~/^#/' "$IMP/reports_servers.txt" 2>/dev/null | while IFS=';' read -r n t run conf _eng life idf sec jsr port; do
    printf '%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s\n' "$n" "$t" "$run" "$(_rs_eng "$conf")" "$life" "$idf" "$sec" "$jsr" "$port" \
        "$(_rs_attr "$conf" maxIdle)" "$(_rs_attr "$conf" engineResponseTimeOut)" "$(_rs_attr "$conf" jvmOptions | sed 's/;/,/g')"
    printf '%s;%s\n' "$n" "$conf" >> "$CSV/.rs_conf"
done > "$CSV/reports_servers.csv"
N_RS="$(wc -l < "$CSV/reports_servers.csv")"
md "Server;type;running at export;engines (init/min/max);engLife;identifier;securityId;jobStatusRepository;broadcast port;maxIdle (min);engineResponseTimeOut (min);engine jvmOptions" reports_servers < "$CSV/reports_servers.csv"
: > "$CSV/rwservlet.csv"
for f in "${RWSERVLETS[@]}"; do
    body="$(awk '/<!--/{c=1} c&&/-->/{c=0;next} !c' "$f")"
    _x() { printf '%s' "$body" | sed -n "s:.*<$1>\\([^<]*\\)</$1>.*:\\1:p" | head -1; }
    printf '%s;%s;%s;%s;%s\n' "$(short "$(dirname "$f" | sed "s#^$RAW/domain#$SRC_DH#")")" "$(_x server)" "$(_x inprocess)" "$(_x webcommandaccess)" "$(_x singlesignon)"
done | M > "$CSV/rwservlet.csv"
md "Configuration directory;server;inprocess;webcommandaccess;singlesignon" rwservlet < "$CSV/rwservlet.csv"
awk '/^# \// {f=$2; n=split(f,a,"/"); f=a[n-1] "/" a[n]; next} /^#/ || /^[[:space:]]*$/ {next}
     { k=$0; sub(/[[:space:]]*:.*/,"",k); u=($0 ~ /userid=/ ? "yes" : "no"); d=($0 ~ /%D/ ? "yes" : "no"); print f ";" k ";" u ";" d }' \
    "$IMP/cgicmd.dat.customer_keys" 2>/dev/null > "$CSV/cgicmd.csv"
md "File;key;contains userid=;uses %D (encrypted login)" cgicmd < "$CSV/cgicmd.csv"

# =============================================================================
# 7. fonts (class computed here - older exports have no class column)
# =============================================================================
: > "$CSV/fonts.csv"
if [ -f "$IMP/fonts.txt" ]; then
    tail -n +2 "$IMP/fonts.txt" | while IFS=';' read -r fb size dir _rest; do
        cl="$(ihwt_font_class "$fb")"
        printf '%s;%s;%s;%s;%s\n' "$fb" "$size" "$(short "$dir")" "${cl%%;*}" "${cl#*;}"
    done > "$CSV/fonts.csv"
fi
# free fonts (OS packages in 14c) as one line per directory - the rest per file
{ awk -F';' '$4!="free"' "$CSV/fonts.csv"
  awk -F';' '$4=="free" {c[$3]++; n=$1; if (match(n, /^(Liberation|DejaVu|Carlito|Caladea)/)) n=substr(n, 1, RLENGTH); else sub(/[-_.].*/,"",n); f[$3 "|" n]=1}
       END { for (d in c) { s=""; for (x in f) { split(x,p,"|"); if (p[1]==d) s=s (s==""?"":", ") p[2] }
                            print c[d] " free font files (" s ");-;" d ";free;OS packages (14b-), not moved" } }' "$CSV/fonts.csv"
} > "$CSV/.fonts_md"
md "Font file;size;directory;class;14c replacement" fonts < "$CSV/.fonts_md"

# =============================================================================
# 8. sources (many sibling directories, e.g. one per user, collapsed)
# =============================================================================
: > "$CSV/sources.csv"
if [ -f "$ROOT/sources_inventory.csv" ]; then
    tail -n +2 "$ROOT/sources_inventory.csv" | awk -F';' '
        { p=$1; par=p; sub(/\/[^\/]+$/,"",par); cnt[par]++; line[NR]=$0; parent[NR]=par }
        END { for (i=1;i<=NR;i++) { if (cnt[parent[i]] > 5) { if (done[parent[i]]++) continue
                    split(line[i], f, ";"); printf "%s/* (%d directories);%s;-;%s;-;-;-;-;-;-;-;-;-;-\n", parent[i], cnt[parent[i]], f[2], f[4]
                    continue }
                n=split(line[i], f, ";")
                printf "%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s\n", f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11], f[12], f[13], f[n] } }' \
        | awk -F';' -v OFS=';' '{ n=split($2,a," "); s=""; delete u; for(i=1;i<=n;i++) if(!(a[i] in u)){u[a[i]]=1; s=s (s==""?"":", ") a[i]}; $2=s; print }' \
        > "$CSV/sources.csv"
fi
while IFS= read -r l; do printf '%s\n' "$(short "$l")"; done < "$CSV/sources.csv" > "$CSV/.s" && mv "$CSV/.s" "$CSV/sources.csv"
md "Directory;configured in;exists;owner:mode;fmb;fmx;pll;plx;mmb;mmx;olb;rdf;rep;newest file" sources < "$CSV/sources.csv"

# =============================================================================
# 9. dependencies
# =============================================================================
DEPF="$ROOT/sources_dependencies.txt"; N_MOD=0
: > "$CSV/deps_libs.csv"; : > "$CSV/deps_missing.csv"
if [ -f "$DEPF" ]; then
    N_MOD="$(cnt -E '^/.*: libraries/menus=' "$DEPF")"
    # library files present in the source directories (sources_files.txt)
    grep -oiE '^[^;#]+\.(pll|plx|mmb|mmx|olb)' "$ROOT/sources_files.txt" 2>/dev/null | sed 's/\.[^.]*$//' | tr '[:lower:]' '[:upper:]' | sort -u > "$CSV/.libfiles"
    sed -n 's/.*libraries\/menus=\([^ ]*\).*/\1/p' "$DEPF" | tr ',' '\n' | grep -v '^-$' | sort | uniq -c | sort -rn \
        | while read -r n lib; do
            if [ "$lib" = WEBUTIL ] || [ "$lib" = D2KWUTIL ]; then pres="Oracle (WebUtil)"
            elif grep -qx "$lib" "$CSV/.libfiles"; then pres="yes"; else pres="NOT FOUND"; fi
            printf '%s;%s;%s\n' "$lib" "$n" "$pres"
          done > "$CSV/deps_libs.csv"
    sed -n '/^# explicit references without a file/,/^#/p' "$DEPF" | grep '^  ' | sed 's/^  //; s/$/;explicit reference without a file in the source directories/' >> "$CSV/deps_missing.csv"
    grep 'referenced file not found' "$DEPF" | sed 's/: referenced file not found: /;referenced file not found: /' | M >> "$CSV/deps_missing.csv"
    while IFS= read -r l; do printf '%s\n' "$(short "$l")"; done < "$CSV/deps_missing.csv" > "$CSV/.d" && mv "$CSV/.d" "$CSV/deps_missing.csv"
else
    nc_add "Dependencies" "no sources_dependencies.txt in the export"
fi
md "Library / menu;used by modules;file in a source directory" deps_libs < "$CSV/deps_libs.csv"
md "Module / file;problem" deps_missing < "$CSV/deps_missing.csv"

# =============================================================================
# 10. Oracle Net - aliases defined vs used
# =============================================================================
: > "$CSV/.tns_def"
for t in "${TNSFILES[@]}"; do
    awk -v f="$(short "$(printf '%s' "$t" | sed "s#^$RAW/other##; s#^$RAW/domain#$SRC_DH#; s#^$RAW/oracle_home#$SRC_OH#")")" '
        function flush() { if (a != "") print a ";" f ";" style ";" ip }
        /^[[:space:]]*#/ {next}
        /^[A-Za-z0-9_.-]+[[:space:]]*=/ { flush(); a=$0; sub(/[[:space:]]*=.*/,"",a); a=toupper(a); style="SERVICE_NAME"; ip="no" }
        /SID[[:space:]]*=/ && !/SERVICE_NAME/ { style="SID" }
        /HOST[[:space:]]*=[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ { ip="yes" }
        END { flush() }' "$t"
done > "$CSV/.tns_def"
# used: user/<pw>@ALIAS in the active lines of every text file of raw/ (not
# tnsnames.ora) - read unmasked, but ONLY the alias after "@" is kept
find "$RAW" -type f ! -name tnsnames.ora ! -name '*.jar' -print0 2>/dev/null | while IFS= read -r -d '' tf; do
        grep -Iq . "$tf" 2>/dev/null || continue
        # Oracle's sample keys of cgicmd.dat (scott/tiger@mydb ...) are no customer usage
        awk -v cg="$(case "$tf" in *cgicmd.dat) echo 1 ;; esac)" '
            /<!--/{c=1} c{ if (/-->/) c=0; next } /^[[:space:]]*[#;]/{next} /^[[:space:]]*REM[[:space:]]/{next}
            cg && /^[[:space:]]*(orqa|report_defaultid|report_secure|run|breakbparam|runp|express)[[:space:]]*:/ {next}
            {print}' "$tf"
    done \
    | grep -oE "[A-Za-z0-9_\$#]+/[^@[:space:]/\"';&]+@[A-Za-z][A-Za-z0-9_.]*" | grep -viE '^(HOST|HTTP|LDAP|CIFS)/' | sed 's/.*@//' | tr '[:lower:]' '[:upper:]' | sort | uniq -c \
    | awk '{print $2 ";" $1}' > "$CSV/.tns_used"
awk -F';' 'NR==FNR {u[$1]=$2; next} { print $1 ";" $2 ";" $3 ";" $4 ";" ($1 in u ? u[$1] " place(s)" : "not used") }' \
    "$CSV/.tns_used" "$CSV/.tns_def" > "$CSV/tns.csv"
awk -F';' 'NR==FNR {d[$1]=1; next} !($1 in d) {print $1 ";-;-;-;used " $2 " time(s), NOT DEFINED"}' "$CSV/.tns_def" "$CSV/.tns_used" >> "$CSV/tns.csv"
N_TNS_DEF="$(cut -d';' -f1 "$CSV/.tns_def" | sort -u | wc -l)"; N_TNS_USED="$(wc -l < "$CSV/.tns_used")"
[ ${#TNSFILES[@]} -eq 0 ] && nc_add "Oracle Net aliases" "no tnsnames.ora in the export"
md "Alias;file;connect style;IP address as host;used in the configuration" tns < "$CSV/tns.csv"

# =============================================================================
# 11. secrets (counted only)
# =============================================================================
: > "$CSV/secrets.csv"; N_SEC_PLACES=0
if [ -f "$ROOT/secrets_locations.txt" ]; then
    N_SEC_PLACES="$(wc -l < "$ROOT/secrets_locations.txt")"
    # mark each hit active (1) / comment (0) - read the line itself
    while IFS=: read -r rel ln kw; do
        a=1; sed -n "${ln}p" "$ROOT/$rel" 2>/dev/null | grep -qE '^[[:space:]]*(#|;|REM[[:space:]]|<!--|\*)' && a=0
        printf '%s:%s:%s\n' "$rel" "$a" "$kw"
    done < "$ROOT/secrets_locations.txt" > "$CSV/.sec_marked"
    awk -F: '{ f=$1; sub(/^raw\/domain\//,"$DOMAIN_HOME/",f); sub(/^raw\/oracle_home\//,"$ORACLE_HOME/",f); sub(/^raw\/other/,"",f)
               c[f]++; act[f]+=$2; kw=tolower($3); k[f "|" kw]=1 }
         END { for (f in c) { s=""; for (x in k) { split(x, p, "|"); if (p[1]==f) s=s (s==""?"":", ") p[2] }; print f ";" act[f] ";" c[f] ";" s } }' \
        "$CSV/.sec_marked" | sort > "$CSV/secrets.csv"
fi
md "File;active lines;all hits (incl. comments);keywords" secrets < "$CSV/secrets.csv"

# =============================================================================
# 11b. load profile (export >= 2026-11-04.4: load/ with aggregated counts)
# =============================================================================
LD="$ROOT/load"
for b in load_forms_sections load_forms_days load_forms_hours load_reports_servers load_reports_jobs load_reports_requests load_sar; do
    : > "$CSV/$b.csv"
done
LOAD_INFO="No load profile in this export (export version ${EXP_VER:-unknown} - the load profile comes with 2026-11-04.4)."
LOAD_PERIOD="-"; LOAD_FRMWEB="-"; LOAD_RWENG="-"; LOAD_HOST="-"
_nv() { sed -n "s/^$1=//p" "$LD/now.txt" 2>/dev/null | head -1; }
if [ -d "$LD" ]; then
    LOAD_INFO="Counted on the old host at the export, last $(_nv load_days) days of the logs."
    if [ -s "$LD/forms_traffic.csv" ]; then
        d1="$(cut -d';' -f1 "$LD/forms_traffic.csv" | sort | head -1)"; d2="$(cut -d';' -f1 "$LD/forms_traffic.csv" | sort | tail -1)"
        nd="$(wc -l < "$LD/forms_traffic.csv")"
        LOAD_PERIOD="$d1 – $d2 ($nd days with Forms requests)"
    fi
    LOAD_FRMWEB="$(_nv frmweb_count) processes, RSS avg $(_nv frmweb_rss_avg_mb) MB / max $(_nv frmweb_rss_max_mb) MB / total $(_nv frmweb_rss_total_mb) MB"
    LOAD_RWENG="$(_nv rwengine_count)"
    LOAD_HOST="${SRC_CPUS:--} CPUs, ${SRC_RAM:--} MB RAM, $(_nv uptime), load average $(_nv loadavg)"
    # 12.1 starts per section (+ sections without a start)
    { awk -F';' '{n[$2]+=$3; if ($1 > l[$2]) l[$2]=$1} END {for (s in n) print s ";" n[s] ";" l[s]}' "$LD/forms_starts.csv" 2>/dev/null
      [ -f "$FW" ] && cut -f1 "$CSV/.fw_all.tsv" | awk '!s[$0]++' | while read -r sec; do
          grep -q ";$sec;" "$LD/forms_starts.csv" 2>/dev/null || printf '%s;0;-\n' "$sec"; done
    } | awk -F';' -v nd="${nd:-0}" '{printf "%s;%s;%s;%s\n", $1, $2, (nd>0 ? sprintf("%.1f", $2/nd) : "-"), $3}' \
      | sort -t';' -k2,2nr > "$CSV/load_forms_sections.csv"
    # 12.2 per day (newest first, last 31 days)
    sort -r "$LD/forms_traffic.csv" 2>/dev/null | head -31 | while IFS=';' read -r d rq ls e5 tt; do
        st="$(awk -F';' -v d="$d" '$1==d {s+=$3} END {print s+0}' "$LD/forms_starts.csv")"
        printf '%s;%s;%s;%s;%s;%s\n' "$d" "$st" "$rq" "$ls" "$e5" "$tt"
    done > "$CSV/load_forms_days.csv"
    # 12.3 per hour with a bar
    sort "$LD/forms_hourly.csv" 2>/dev/null | awk -F';' '{h[$1]=$2; if ($2>m) m=$2} END {for (i=0;i<24;i++) {k=sprintf("%02d",i); v=h[k]+0; b=""; if (m>0) for (j=0;j<int(30*v/m+0.5);j++) b=b "#"; print k ":00;" v ";" b}}' \
        > "$CSV/load_forms_hours.csv"
    # 12.4 servers
    for x in "$LD"/reports_*_serverinfo.xml; do
        [ -f "$x" ] || continue
        sv="${x##*/reports_}"; sv="${sv%_serverinfo.xml}"
        xp() { grep -o "name=\"$1\"[^/]*value=\"[^\"]*\"" "$x" | sed 's/.*value="//; s/"$//' | head -1; }
        stt="$(sed -n 's:.*<startTime>\([0-9]*\)</startTime>.*:\1:p' "$x" | head -1)"
        since="-"; [ -n "$stt" ] && since="$(date -d "@$((stt / 1000))" '+%Y-%m-%d %H:%M' 2>/dev/null)"
        ok="$(xp successfulJobs)"; fl="$(xp failedJobs)"
        rate="-"; [ -n "$ok$fl" ] && rate="$(awk -v o="${ok:-0}" -v f="${fl:-0}" 'BEGIN {t=o+f; print (t>0 ? sprintf("%.1f %%", 100*f/t) : "-")}')"
        mu="$(grep -o 'maxEnginesUsed="[0-9.]*"' "$x" | grep -o '[0-9.]*')"; au="$(grep -o 'avgEnginesUsed="[0-9.]*"' "$x" | grep -o '[0-9.]*')"
        printf '%s;%s;%s;%s;%s;%s;%s;%s;%s\n' "$sv" "$since" "${ok:--}" "${fl:--}" "$rate" "$(xp currentJobs)" "$(xp futureJobs)" "${mu:--} / ${au:--}" "$(xp averageResponseTime)"
    done > "$CSV/load_reports_servers.csv"
    [ -f "$LD/reports_not_collected.txt" ] && while IFS=';' read -r sv what why; do
        nc_add "Reports load of $sv ($what)" "$why"; done < "$LD/reports_not_collected.txt"
    # 12.5 per report
    awk -F';' '{k=$1 ";" $3; n[k]++; if ($4!="4") f[k]++; if ($6!="") {s[k]+=$6; c[k]++; if ($6>m[k]) m[k]=$6}}
         END {for (k in n) printf "%s;%d;%d;%s;%s\n", k, n[k], f[k], (c[k]?sprintf("%.0f", s[k]/c[k]):"-"), (c[k]?m[k]:"-")}' \
        "$LD/reports_jobs.csv" 2>/dev/null | sort -t';' -k3,3nr > "$CSV/load_reports_jobs.csv"
    # 12.6 servlet requests per day (newest 31 days, commands summed per day)
    awk -F';' '{r[$1]+=$3; e[$1]+=$4; c[$1]=c[$1] (index(c[$1], $2 "=")?"":(c[$1]==""?"":", ") $2 "=") } END {}' /dev/null
    awk -F';' '{r[$1]+=$3; e[$1]+=$4; x[$1 "|" $2]+=$3} END {for (d in r) {s=""; for (k in x) {split(k,p,"|"); if (p[1]==d) s=s (s==""?"":", ") p[2] " " x[k]}; print d ";" r[d] ";" e[d] ";" s}}' \
        "$LD/reports_requests.csv" 2>/dev/null | sort -r | head -31 > "$CSV/load_reports_requests.csv"
    # 12.7 sar (newest first)
    sort -r "$LD/host_sar.csv" 2>/dev/null | head -31 > "$CSV/load_sar.csv"
else
    nc_add "Load profile (Forms starts, Reports jobs, sar)" "export older than 2026-11-04.4 - no load/ directory"
fi
md "Section;starts;per day;last start" load_forms_sections < "$CSV/load_forms_sections.csv"
md "Date;application starts;all requests;lservlet (session traffic);HTTP 5xx;avg response ms" load_forms_days < "$CSV/load_forms_days.csv"
md "Hour;starts;distribution" load_forms_hours < "$CSV/load_forms_hours.csv"
md "Server;counters since;successful jobs;failed jobs;failure rate;current;future;max / avg engines used;avg response ms" load_reports_servers < "$CSV/load_reports_servers.csv"
md "Server;report;runs;not successful;avg seconds;max seconds" load_reports_jobs < "$CSV/load_reports_jobs.csv"
md "Date;requests;HTTP 5xx;by command" load_reports_requests < "$CSV/load_reports_requests.csv"
md "Date;CPU busy avg %;CPU busy peak %;memory used avg %" load_sar < "$CSV/load_sar.csv"

# =============================================================================
# 12b. values for the 14c environment.conf (checklist for the interview)
#   status: from export | decision | asked (new host) | secret (asked) | missing in this export
# =============================================================================
PROPF="$IMP/environment.conf.proposal"
_pv() { sed -n "s/^$1=\"\\([^\"]*\\)\".*/\\1/p" "$PROPF" 2>/dev/null | head -1; }
_ev() { printf '%s;%s;%s;%s\n' "$1" "$(printf '%s' "$2" | sed 's/;/,/g')" "$3" "$4"; }
# raw config.xml fallback for older exports (ports)
_rsp() { awk -v w="$1" '/<server>/{s=1;n="";p="";sub_=0} /<(ssl|network-access-point|web-server|server-start|log)>/{sub_++} /<\/(ssl|network-access-point|web-server|server-start|log)>/{sub_--; next} sub_>0{next}
          s&&/<name>/&&n==""{n=$0; gsub(/.*<name>|<\/name>.*/,"",n)} s&&/<listen-port>/&&p==""{p=$0; gsub(/.*<listen-port>|<\/listen-port>.*/,"",p)}
          /<\/server>/{ if (s && n ~ w) { print (p==""?"7001":p); exit } s=0 }' "$CONFIG_XML" 2>/dev/null; }
ncs="$(awk -F';' -v std=" $STD_SECTIONS " 'index(std, " " $1 " ")==0' "$CSV/forms_sections.csv" | wc -l)"
nrs="$(awk -F';' '$2=="standalone"' "$CSV/reports_servers.csv" | wc -l)"
if [ "$ncs" -gt 0 ] && [ "$nrs" -gt 0 ]; then ic="FORMS_AND_REPORTS"; elif [ "$nrs" -gt 0 ]; then ic="REPORTS_ONLY"; else ic="FORMS"; fi
jac="false"; grep -qi 'jacob' "$CSV/.fw_all.tsv" 2>/dev/null && jac="true"
# client section: the customer section with the most starts (load), else the first with form=
cl="$(awk -F';' -v std=" $STD_SECTIONS " 'index(std, " " $1 " ")==0 && $2+0>0 {print $1; exit}' "$CSV/load_forms_sections.csv" 2>/dev/null)"
[ -z "$cl" ] && cl="$(awk -F';' -v std=" $STD_SECTIONS " 'index(std, " " $1 " ")==0 && $2!="-" {print $1; exit}' "$CSV/forms_sections.csv")"
clf="$(awk -F';' -v s="$cl" '$1==s {print $2}' "$CSV/forms_sections.csv")"
cert="$(awk -F';' 'NR>1 && $1 ~ /^https/ {print $2; exit}' "$IMP/certificates.txt" 2>/dev/null)"
jcert="$(awk -F';' 'NR>1 && $1 ~ /^jar/ {print $2 " (until " $4 ")"; exit}' "$IMP/certificates.txt" 2>/dev/null)"
# module / report directories: the source directory (not below ORACLE_HOME) with the most .fmx / .rdf+.rep
fp_old="$(awk -F';' '$1 !~ /^\$ORACLE_HOME/ && $6 ~ /^[0-9]+$/ && $6+0 > m {m=$6; d=$1} END {print d}' "$CSV/sources.csv")"
rp_old="$(awk -F';' '$1 !~ /^\$ORACLE_HOME/ && $12 ~ /^[0-9]+$/ && $12+$13 > m {m=$12+$13; d=$1} END {print d}' "$CSV/sources.csv")"
rt_old="$(awk -F';' '$2 ~ /folderAccess.write/ && $1 ~ /directories\)/ {print $1; exit}' "$CSV/sources.csv")"
[ -z "$rt_old" ] && rt_old="$(_pv REPORTS_TMP)"
{
    _ev INSTALL_COMPONENTS "$ic" "$ncs customer Forms sections, $nrs standalone Reports servers" "from export"
    _ev REPORTS_SERVER_NAMES "$(awk -F';' '$2=="standalone" {print $1}' "$CSV/reports_servers.csv" | paste -sd' ' -)" "standalone servers (in-process leftover not taken over)" "from export"
    _ev FORMS_WEBUTIL_JACOB "$jac" "WebUtilArchive / install.syslib" "from export"
    _ev NLS_LANG "$(_pv NLS_LANG)" "env files (per server NLS_LANG: section 6.1 / overlay)" "from export"
    _ev REPORTS_BROADCAST_PORT "$(_pv REPORTS_BROADCAST_PORT)" "rwnetwork.conf - choose a port unique in the subnet" "decision"
    for k in WLS_ADMIN_PORT WLS_FORMS_PORT WLS_REPORTS_PORT WLS_NODEMANAGER_PORT; do
        v="$(_pv $k)"; src="environment.conf.proposal"
        if [ -z "$v" ]; then
            case $k in WLS_ADMIN_PORT) v="$(_rsp '^AdminServer$')" ;; WLS_FORMS_PORT) v="$(_rsp FORMS)" ;; WLS_REPORTS_PORT) v="$(_rsp REPORTS)" ;;
                       WLS_NODEMANAGER_PORT) v="$(ihwt_cfgval "$NMPROP" ListenPort | tail -1)" ;; esac
            src="raw config.xml / nodemanager.properties"
        fi
        _ev "$k" "${v:--}" "$src" "from export"
    done
    _ev WLS_LISTEN_ADDRESS "127.0.0.1" "old: $(_pv WLS_LISTEN_ADDRESS)$( [ -z "$(_pv WLS_LISTEN_ADDRESS)" ] && printf 'localhost (config.xml)') - 14c: loopback behind Nginx" "decision"
    v="$(_pv WLS_SERVER_FQDN)"; [ -z "$v" ] && v="$(grep -h '^AS_HOST_NAME=' "${ENVFILES[@]}" 2>/dev/null | head -1 | cut -d= -f2)"
    _ev WLS_SERVER_FQDN "${v:-$SRC_HOST}" "OLD public name - keep (DNS alias) or new name" "decision"
    for k in DB_HOST DB_PORT DB_SERVICE DB_SCHEMA_PREFIX; do
        v="$(_pv $k)"
        if [ -n "$v" ]; then _ev "$k" "$v" "RCU of the old domain (WLSSchemaDataSource) - 14c needs a NEW RCU (14.1.2)" "decision"
        else _ev "$k" "-" "config/jdbc not collected - fresh export (2026-11-04.5)" "missing in this export"; fi
    done
    _ev FORMS_CLIENT_CONFIG "${cl:--}" "most used customer section" "decision"
    _ev FORMS_CLIENT_FORM "${clf:--}" "form= of that section" "from export"
    v="$(_pv FORMS_MAX_RUNTIME_PROCESSES)"
    _ev FORMS_MAX_RUNTIME_PROCESSES "${v:-(proposal from the 14c RAM)}" "not set at the customer (finding) - frm_mrp_proposal on the 14c host" "decision"
    _ev EXPECTED_SESSIONS "-" "load profile (section 12) - frmweb processes / starts per hour" "decision"
    _ev FORMS_CUSTOMER_DIR "${fp_old:--}" "directory with the most .fmx - keep the path or move into \$ORACLE_BASE/forms/moduls" "decision"
    _ev REPORTS_CUSTOMER_DIR "${rp_old:--}" "directory with the most .rdf / .rep - keep or move into \$ORACLE_BASE/reports/source" "decision"
    _ev REPORTS_TMP "${rt_old:--}" "old <write> directory - 14c: one output directory (no subdirectories in <write>)" "decision"
    _ev REPORTS_SECURITY "ldap" "customer: no securityId / identifier (finding) - 14c secured server" "decision"
    _ev "REPORTS_ENGINE_*" "50 / 2 / 2 / 5" "engLife / init / min / max - 14c standard instead of engLife=1 (finding)" "decision"
    if [ -n "$cert" ]; then _ev "SSL_ORG / SSL_COUNTRY / SSL_CA_CN" "$cert" "certificate of the old HTTPS listener" "from export"
    else _ev "SSL_ORG / SSL_COUNTRY / SSL_CA_CN" "-" "certificate subject not in this export - fresh export (2026-11-04.5)" "missing in this export"; fi
    if [ -n "$jcert" ]; then _ev "FORMS_SIGN_*" "$jcert" "signer of the customer jars - code-signing certificate for 14c?" "decision"
    else _ev "FORMS_SIGN_*" "-" "jar signer: see section 5 (fresh export lists the subject)" "decision"; fi
    _ev "ORACLE_BASE, ORACLE_HOME, JDK_HOME, DOMAIN_HOME, ORACLE_INVENTORY, PATCH_STORAGE, TNS_ADMIN, IHW_ENV_TYPE" "-" "layout of the new host" "asked (new host)"
    _ev "LOCAL_REP_DB, RCU_TABLESPACE, RCU_DB_TYPE, INSTALL_APEX, FORMS_CLIENT_DIST, MOS_USER" "-" "decisions for the new host" "asked (new host)"
    _ev WLS_ADMIN_USER "webadmin" "only in the encrypted boot.properties of the old host" "asked (new host)"
    _ev "WLS_ADMIN_PWD, EMBEDDED_LDAP_PWD, REPORTS_ADMIN_PWD, DB_SYS_PWD, DB_SCHEMA_PWD, FORMS_SIGN_STOREPASS, MOS_PWD" "-" "never taken from an export" "secret (asked)"
} | ihwt_mask > "$CSV/env_values.csv"
md "environment.conf key;proposed value;source / note;status" env_values < "$CSV/env_values.csv"
N_ENV_EXPORT="$(cnt ';from export$' "$CSV/env_values.csv")"; N_ENV_DEC="$(cnt ';decision$' "$CSV/env_values.csv")"
N_ENV_MISS="$(cnt ';missing in this export$' "$CSV/env_values.csv")"
[ "$N_ENV_MISS" -gt 0 ] && f_add INFO "Import" "$N_ENV_MISS environment.conf value(s) missing in this export (section 13.1)" "fresh export with export_forms_reports_conf.sh 2026-11-04.5 or newer"

# =============================================================================
# 12. environment.conf proposal (masked)
# =============================================================================
ENV_PROPOSAL="$(grep -v '^#' "$IMP/environment.conf.proposal" 2>/dev/null | sed '/^$/d' | ihwt_mask)"

# =============================================================================
# 13. rules
# =============================================================================
say "rules ..."
# --- Security: Forms -----------------------------------------------------------
_secs_with() { awk -F';' -v c="$1" -v v="$2" '$c ~ v {print $1}' "$CSV/forms_sections.csv" | paste -sd, -; }
x="$(_secs_with 5 'clear text')"
[ -n "$x" ] && f_add WARN "Security / Forms" "database login (userid parameter) in clear text in formsweb.cfg section(s): $x" \
    "remove userid from formsweb.cfg - users log in, or use SSO / a proxy user"
x="$(_secs_with 5 'encrypted')"
[ -n "$x" ] && f_add WARN "Security / Forms" "database login (userid parameter) stored encrypted in formsweb.cfg section(s): $x" \
    "encrypted, but every user of the section is logged in with it automatically - 14c: users log in themselves, or SSO / a proxy user"
if [ -f "$FW" ]; then
    x="$(awk -F'\t' '$2=="userid" && $3 !~ /^\{AES/ && $3 ~ /\// && $3 !~ /@/ {print $1}' "$CSV/.fw_all.tsv" | paste -sd, -)"
    [ -n "$x" ] && f_add HINT "Forms" "stored login without a database alias (no @...) in section(s): $x" \
        "the database then comes from TWO_TASK / LOCAL of the runtime - name it explicitly in 14c"
fi
x="$(_secs_with 6 '^[Tt][Rr][Uu][Ee]$')"
[ -n "$x" ] && f_add WARN "Security / Forms" "allow_debug=true in section(s): $x" \
    "set allow_debug=false (14c standard) - debug mode exposes the Forms debugger to users"
if $HAVE_REF && [ -f "$FW" ]; then
    rd="$(awk -F'\t' '$1=="default" && $2=="restrictedURLparams" {print $3; exit}' "$CSV/.ref_fw.tsv")"
    cu="$(awk -F'\t' '$1=="default" && $2=="restrictedURLparams" {print $3; exit}' "$CSV/.fw_all.tsv")"
    miss=""; for p in ${rd//,/ }; do case ",$cu," in *",$p,"*) ;; *) miss="$miss${miss:+,}$p" ;; esac; done
    [ -n "$miss" ] && f_add WARN "Security / Forms" "restrictedURLparams in [default] lacks entries of the 14c standard: $miss" \
        "use at least Oracle's 14c list: $rd"
    x="$(awk -F'\t' '$1!="default" && $2=="restrictedURLparams" {print $1}' "$CSV/.fw_all.tsv" | paste -sd, -)"
    [ -n "$x" ] && f_add HINT "Security / Forms" "restrictedURLparams overridden in section(s): $x" "check that the section list is not shorter than [default]"
fi
x="$(awk -F'\t' '($2=="record" || $2=="log") && $3!="" && $3 !~ /^%/ {print $1 "." $2 "=" $3}' "$CSV/.fw_all.tsv" 2>/dev/null | paste -sd, -)"
[ -n "$x" ] && f_add HINT "Security / Forms" "client trace / recording switched on: $x" "switch off in production (performance, user data in trace files)"
x="$(awk -F'\t' '($2=="serverURL" || $2=="codebase" || $2 ~ /jnlp/) && $3 ~ /^http:\/\// {print $1 "." $2}' "$CSV/.fw_all.tsv" 2>/dev/null | paste -sd, -)"
[ -n "$x" ] && f_add HINT "Security / Forms" "absolute http:// URL in: $x" "use relative URLs or https:// (14c: TLS terminated by Nginx)"
for ef in "${ENVFILES[@]}"; do
    v="$(ihwt_cfgval "$ef" FORMS_RESTRICT_ENTER_QUERY | head -1)"
    case "$v" in [Ff][Aa][Ll][Ss][Ee]) f_add WARN "Security / Forms" "FORMS_RESTRICT_ENTER_QUERY=FALSE in $(basename "$ef")" \
        "keep TRUE (14c standard) - FALSE lets users enter own WHERE conditions in Enter Query mode" ;; esac
done
n="$(_secret_hits '\.env$' 'password|passwd|pwd|userid|\{AES')"
[ "${n:-0}" -gt 0 ] && f_add WARN "Security / Forms" "$n active line(s) with a password / login keyword in env files" "no passwords in env files - 14c: wallet / proxy user"
# --- Security: WebUtil ---------------------------------------------------------
if [ -f "$WU" ]; then
    ac="$(ihwt_cfgval "$WU" 'transfer\.appsrv\.accessControl' | tail -1)"; en="$(ihwt_cfgval "$WU" 'transfer\.appsrv\.enabled' | tail -1)"
    if [[ "$en" =~ ^[Tt][Rr][Uu][Ee]$ ]] && [[ "$ac" =~ ^[Ff][Aa][Ll][Ss][Ee]$ ]]; then
        f_add WARN "Security / WebUtil" "file transfer to the application server enabled with accessControl=FALSE" \
            "set transfer.appsrv.accessControl=TRUE and allow only dedicated read / write directories (14c: below the Forms work area)"
    fi
    x="$(ihwt_keys "$WU" | awk -F'\t' '$1 ~ /^transfer\.appsrv\.(read|write)\.|workAreaRoot/ && ($2=="/" || $2 ~ /^\/tmp\/?$/ || $2 ~ /^\/var\/tmp\/?$/) {print $1 "=" $2}' | paste -sd, -)"
    [ -n "$x" ] && f_add WARN "Security / WebUtil" "very wide transfer directories: $x" "use own directories per application (shared /tmp lets every user read every file)"
    [[ "$(ihwt_cfgval "$WU" 'transfer\.database\.enabled' | tail -1)" =~ ^[Tt][Rr][Uu][Ee]$ ]] && \
        f_add HINT "Security / WebUtil" "transfer.database.enabled=TRUE" "keep only if the application loads files into / from the database with WebUtil"
    if $HAVE_REF; then
        x="$(grep -E '^install\.syslib\.[0-9]' "$WU" | cut -d= -f2 | cut -d'|' -f1 | sort -u | grep -viE '^jacob' \
             | while read -r d; do grep -q "=$d" "$REF/webutil.cfg" || printf '%s\n' "$d"; done | paste -sd, -)"
        [ -n "$x" ] && f_add HINT "Security / WebUtil" "own client libraries (install.syslib): $x" "native code on the clients - check whether still needed, signed, 64 bit"
    fi
else nc_add "WebUtil rules" "no webutil.cfg in the export"; fi
# --- Security: Reports ---------------------------------------------------------
x="$(awk -F';' '$6=="none" || $6=="clear" {print $1 " (" $6 ")"}' "$CSV/reports_servers.csv" | paste -sd, -)"
[ -n "$x" ] && f_add WARN "Security / Reports" "Reports server without encrypted identifier element: $x" "14c: encrypted identifier element (Reports_Absicherung_kochbuch_de.txt)"
x="$(awk -F';' '$7=="no" {print $1}' "$CSV/reports_servers.csv" | paste -sd, -)"
[ -n "$x" ] && f_add WARN "Security / Reports" "Reports server without securityId (no authentication of jobs): $x" "14c: secured server with securityId, RepRunner via cmdkey, monUser for monitoring"
for c in "${RWCONFS[@]}"; do
    grep -q '<folderAccess' "$c" || f_add WARN "Security / Reports" "no <folderAccess> in $(short "$(printf '%s' "$c" | sed "s#^$RAW/domain#$SRC_DH#")")" "engines may read / write everywhere - set <read> / <write>"
done
x="$(awk -F';' '$4=="L2" {print $1}' "$CSV/rwservlet.csv" | paste -sd, -)"
[ -n "$x" ] && f_add WARN "Security / Reports" "webcommandaccess=L2 (web commands open for everybody): $x" "14c: L1 (only the identifier admin), see 81-reports_rwservlet_security.md"
n="$(grep -ciE 'cgicmd\.dat:[0-9]+:userid' "$ROOT/secrets_locations.txt" 2>/dev/null)"
nk="$(awk -F';' '$3=="yes"' "$CSV/cgicmd.csv" | wc -l)"
[ "$nk" -gt 0 ] && f_add WARN "Security / Reports" "$nk customer key(s) in cgicmd.dat with a database login" "14c: cmdkey with %D / the RepRunner user, no clear-text logins"
[ "${n:-0}" -gt 0 ] && [ "$nk" -eq 0 ] && f_add INFO "Security / Reports" "cgicmd.dat contains logins only in Oracle's sample keys ($n places)" "the 14c library writes its own cgicmd.dat block"
x="$(awk -F';' '$2 ~ /folderAccess/ && $4 ~ /:7[0-7]7$/ {print $1}' "$CSV/sources.csv" | paste -sd, -)"
[ -n "$x" ] && f_add WARN "Security / Reports" "world-writable Reports read / write directories: $x" "mode 770 / 750, group of the Reports server"
# --- Security: domain / node manager / OHS / net ------------------------------
if [ -f "$CONFIG_XML" ]; then
    grep -q '<production-mode-enabled>true' "$CONFIG_XML" || f_add WARN "Security / WebLogic" "domain not in production mode" "14c: production mode (secure defaults)"
    awk '/<server>/{s=1;la="";n=""} s&&/<name>/&&n==""{n=$0; gsub(/.*<name>|<\/name>.*/,"",n)} s&&/<listen-address>/{la=$0; gsub(/.*<listen-address>|<\/listen-address>.*/,"",la)}
         /<\/server>/{ if(s && la=="") print n; s=0 }' "$CONFIG_XML" | paste -sd, - | {
        read -r x; [ -n "$x" ] && f_add WARN "Security / WebLogic" "server(s) listen on all interfaces (no listen-address): $x" "14c: 127.0.0.1 behind Nginx (loopback-only installation)"; }
    grep -qE 'DemoIdentity|DemoTrust' "$CONFIG_XML" && f_add HINT "Security / WebLogic" "WebLogic demo keystores configured" "14c: no WebLogic SSL ports, TLS in Nginx"
else nc_add "WebLogic config.xml rules" "no config.xml in the export"; fi
if [ -f "$NMPROP" ]; then
    la="$(ihwt_cfgval "$NMPROP" ListenAddress | tail -1)"; sl="$(ihwt_cfgval "$NMPROP" SecureListener | tail -1)"
    [[ "$sl" =~ ^[Ff][Aa][Ll][Ss][Ee]$ ]] && [[ ! "$la" =~ ^(localhost|127\.0\.0\.1)$ ]] && \
        f_add WARN "Security / WebLogic" "Node Manager without SSL listens on $la" "listen on 127.0.0.1 only"
    [[ "$(ihwt_cfgval "$NMPROP" AuthenticationEnabled | tail -1)" =~ ^[Ff][Aa][Ll][Ss][Ee]$ ]] && \
        f_add WARN "Security / WebLogic" "Node Manager AuthenticationEnabled=false" "set true"
fi
n="$(_secret_hits '(setDomainEnv|setUserOverrides)\.sh$' 'password|passwd|pwd')"
[ "${n:-0}" -gt 0 ] && f_add WARN "Security / WebLogic" "$n active line(s) with a password keyword in setDomainEnv.sh / setUserOverrides.sh" "no -D...password=... in start scripts - boot.properties / wallet"
for o in "${OHSCONFS[@]}"; do
    grep -qiE '^[[:space:]]*DebugConfigInfo[[:space:]]+ON' "$o" && f_add WARN "Security / Web tier" "OHS DebugConfigInfo ON" "switch off (shows the routing configuration to everybody)"
    x="$(awk '/^[[:space:]]*#/{next} /<Location[[:space:]]+\/(console|em)/{l=$2; gsub(/>/,"",l); r=0} /Require|Allow from|Deny from/{r=1} /<\/Location>/{ if(l!="" && !r) print l; l="" }' "$o" | paste -sd, -)"
    [ -n "$x" ] && f_add WARN "Security / Web tier" "admin consoles routed by the web server without restriction: $x" "14c: /console and /em only from the admin network (Nginx ADMIN_IP_RANGE) or not routed"
done
[ ${#OHSCONFS[@]} -eq 0 ] && nc_add "OHS rules" "no mod_wl_ohs.conf in the export"
if [ ${#SQLNETS[@]} -gt 0 ]; then
    grep -qiE 'SQLNET\.(ENCRYPTION|CRYPTO_CHECKSUM)_CLIENT' "${SQLNETS[@]}" || \
        f_add INFO "Security / Oracle Net" "sqlnet.ora without client encryption settings" "check whether the database enforces Oracle Net encryption"
else nc_add "Oracle Net encryption (sqlnet.ora)" "no sqlnet.ora in the export"; fi
x="$(awk -F';' '$5=="unsigned" {print $1}' "$CSV/jars.csv" | paste -sd, -)"
[ -n "$x" ] && f_add WARN "Security / Jars" "unsigned jar(s): $x" "sign with the code-signing certificate (14-) - Java Web Start / FSAL clients reject unsigned code"
x="$(awk -F';' '$6 ~ /SHA1|MD5/ {print $1}' "$CSV/jars.csv" | paste -sd, -)"
[ -n "$x" ] && f_add WARN "Security / Jars" "jar(s) signed with SHA-1 / MD5: $x" "JDK 17 / 21 treat these as unsigned - re-sign with SHA-256 (14-)"
today="$(date +%Y-%m-%d)"; soon="$(date -d '+90 days' +%Y-%m-%d)"
x="$(awk -F';' -v t="$today" '$7 ~ /^[0-9]{4}-/ && $7 < t && $8!="yes" {print $1 " (" $7 ")"}' "$CSV/jars.csv" | paste -sd, -)"
[ -n "$x" ] && f_add WARN "Security / Jars" "signer certificate expired and no timestamp: $x" "re-sign (14-) - the signature is no longer valid"
x="$(awk -F';' -v t="$today" '$7 ~ /^[0-9]{4}-/ && $7 < t && $8=="yes" {print $1}' "$CSV/jars.csv" | paste -sd, -)"
[ -n "$x" ] && f_add HINT "Security / Jars" "signer certificate expired, signature still valid through its timestamp: $x" \
    "re-sign with the 14c code-signing certificate anyway (one signer for all jars, JDK 21 checks)"
x="$(awk -F';' -v t="$today" -v s="$soon" '$7 ~ /^[0-9]{4}-/ && $7 >= t && $7 < s {print $1 " (" $7 ")"}' "$CSV/jars.csv" | paste -sd, -)"
[ -n "$x" ] && f_add WARN "Security / Jars" "signer certificate expires within 90 days: $x" "re-sign before the date"
[ "$N_SEC_PLACES" -gt 0 ] && f_add INFO "Security / Secrets" "$N_SEC_PLACES places with password / key keywords in the configuration (section 11)" \
    "14c stores secrets encrypted (boot.properties, encrypted identifier, cmdkey, wallet) - nothing in clear text"
case "$SRC_JAVA" in *1.8.0_*)
    u="$(printf '%s' "$SRC_JAVA" | grep -oE '1\.8\.0_[0-9]+' | sed 's/.*_//')"
    [ -n "$u" ] && [ "$u" -lt 511 ] && f_add INFO "Security / Java" "source JDK $SRC_JAVA is older than the current CPU level (8u511, Oct 2026)" "the 14c installation uses JDK 21 - no action for the old host beyond the patch level" ;;
esac

# --- Oracle Net ----------------------------------------------------------------
x="$(awk -F';' '$5=="not used" {print $1}' "$CSV/tns.csv" | sort -u | paste -sd, -)"
[ -n "$x" ] && f_add HINT "Oracle Net" "$(nlist "$x") alias(es) defined but not used in the exported configuration: $x" \
    "check whether still needed (also used by reports / clients?) - 14c: one clean tnsnames.ora"
x="$(awk -F';' '$5 ~ /NOT DEFINED/ {print $1}' "$CSV/tns.csv" | paste -sd, -)"
[ -n "$x" ] && f_add WARN "Oracle Net" "alias(es) used but not defined in a collected tnsnames.ora: $x" "define them in the one 14c tnsnames.ora (or they come from LDAP / another TNS_ADMIN)"
x="$(cut -d';' -f1 "$CSV/.tns_def" | sort | uniq -d | paste -sd, -)"
[ -n "$x" ] && f_add WARN "Oracle Net" "alias(es) defined more than once: $x" "keep one definition"
x="$(awk -F';' '$3=="SID" {print $1}' "$CSV/.tns_def" | paste -sd, -)"
[ -n "$x" ] && f_add HINT "Oracle Net" "old SID= style: $x" "use SERVICE_NAME (PDB / service)"
x="$(awk -F';' '$4=="yes" {print $1}' "$CSV/.tns_def" | paste -sd, -)"
[ -n "$x" ] && f_add HINT "Oracle Net" "IP address as HOST: $x" "use DNS names (moves / failover)"
n="$(grep -o 'TNS_ADMIN_SOURCE="[^"]*"' "$IMP/environment.conf.proposal" 2>/dev/null | tr -cd ' ' | wc -c)"
[ "${n:-0}" -gt 1 ] && f_add HINT "Oracle Net" "$n TNS_ADMIN directories in use" "14c: one TNS_ADMIN for every process (02-Checks/tns_admin_check.sh)"
# --- Forms ---------------------------------------------------------------------
if $HAVE_REF && [ -f "$FW" ]; then
    KNOWN="$_IHWT_DIR/../customer-analyse/rules/formsweb_14c_known_keys.txt"
    x="$(cut -f2 "$CSV/.fw_all.tsv" | sort -u | while read -r k; do
            grep -qiP "^\S*\t\Q$k\E\t" "$CSV/.ref_fw.tsv" && continue
            grep -qix "$k" "$KNOWN" 2>/dev/null && continue
            printf '%s\n' "$k"; done | paste -sd, -)"
    [ -n "$x" ] && f_add HINT "Forms" "formsweb.cfg keys that do not exist in Oracle's 14c template: $x" "own parameters (keep in the section) or obsolete keys (drop) - check each"
    x="$(awk -F';' '$2==$3 {print $1}' "$CSV/forms_default.csv" | paste -sd, -)"
    [ -n "$x" ] && f_add INFO "Forms" "[default] overrides equal to the 14c standard: $x" "not needed in 14c"
fi
grep -o 'envFile [^ ]* of [^ ]* not found' "$ROOT/00_report.txt" 2>/dev/null | while read -r l; do f_add WARN "Forms" "$l" "provide the env file or fix envFile="; done
x="$(awk -F';' '$4=="MISSING" {print $1 " (" $3 ")"}' "$CSV/jars.csv" | paste -sd, -)"
[ -n "$x" ] && f_add WARN "Forms" "referenced jar(s) missing on the old host: $x" "remove from archive= / CLASSPATH or provide the jar"
v="$(cut -d';' -f5 "$CSV/env_files.csv" | grep -v '^-$' | sort -u | wc -l)"
[ "$v" -gt 1 ] && f_add HINT "Forms" "different NLS_LANG in the env files: $(cut -d';' -f1,5 "$CSV/env_files.csv" | tr ';' '=' | paste -sd, -)" "intended per application? 14c: NLS_LANG per env file from the template"
v="$(cut -d';' -f6 "$CSV/env_files.csv" | grep -v '^-$' | sort -u | wc -l)"
[ "$v" -gt 1 ] && f_add HINT "Forms" "different TNS_ADMIN in the env files" "14c: one TNS_ADMIN"
# --- Forms runtime / performance (rules of 06-FormsDiag) --------------------------
if [ -f "$FW" ]; then
    x="$(awk -F';' '$6 ~ /heartBeat >= FORMS_TIMEOUT/ {print $1 " (" $2 " / " $3 ")"}' "$CSV/forms_timeouts.csv" | paste -sd, -)"
    [ -n "$x" ] && f_add WARN "Forms runtime" "heartBeat not below FORMS_TIMEOUT: $x - Oracle: the runtime is terminated, the session hangs" \
        "heartBeat < FORMS_TIMEOUT < session-timeout (06-FormsDiag/forms_perf_settings.sh checks the whole chain)"
    x="$(awk -F';' '$6 ~ /session-timeout/ {print $1}' "$CSV/forms_timeouts.csv" | paste -sd, -)"
    [ -n "$x" ] && f_add WARN "Forms runtime" "heartBeat not below the servlet session-timeout: $x" "Oracle: session-timeout takes precedence - lower heartBeat or raise the timeout"
    [ -z "$SESS_MIN" ] && nc_add "Forms timeout chain: servlet session-timeout" "formsapp.ear weblogic.xml not in the export (export version >= 2026-11-04.3 collects it)"
    x="$(awk -F';' '{split($2,a," "); if (a[1]+0 < 0.5) print $1}' "$CSV/forms_timeouts.csv" | paste -sd, -)"
    [ -n "$x" ] && f_add HINT "Forms runtime" "heartBeat below 0.5 min: $x" "Oracle: too low causes a significant increase in network traffic"
    x="$(awk -F';' '{split($3,a," "); if (a[1]+0 > 120) print $1 " (" a[1] " min)"}' "$CSV/forms_timeouts.csv" | paste -sd, -)"
    [ -n "$x" ] && f_add HINT "Forms runtime" "long FORMS_TIMEOUT: $x - dead client sessions keep their frmweb process (and DB session) that long" "a short FORMS_TIMEOUT with heartBeat keeps active sessions alive and frees dead ones"
    mrp="$(_fwget default maxRuntimeProcesses)"
    if [ -z "$mrp" ] || [ "$mrp" = 0 ]; then
        p=""; [ -n "${SRC_RAM:-}" ] && p=" (old host: ${SRC_RAM} MB RAM -> about $(( (SRC_RAM / 2 / 64) / 10 * 10 )) at 64 MB per session)"
        f_add WARN "Forms runtime" "maxRuntimeProcesses not set in [default] - nothing limits the frmweb processes before the RAM runs out$p" \
            "Oracle: 0 is vulnerable to Denial of Service - IHateWeblogic 14c: maxRuntimeProcesses proposed from the RAM of the 14c host (FORMS_MAX_RUNTIME_PROCESSES, frm_mrp_proposal in 06-FormsDiag/forms_lib.sh), checked by 06-FormsDiag/forms_perf_settings.sh, load measured by forms_perf_analyse.sh"
    fi
    x="$(awk -F'\t' '$1=="default" && tolower($2)=="prestartruntimes" && tolower($3)=="true" {print "default"}' "$CSV/.fw_all.tsv")"
    [ -n "$x" ] && f_add HINT "Forms runtime" "prestartRuntimes=true in [default] - a prestart pool for every section" "Oracle: not in [default] - only in the section used in production (14c: FORMS_PRESTART_SECTION)"
    x="$(awk -F'\t' 'tolower($2)=="prestartruntimes" && tolower($3)=="true" {print $1}' "$CSV/.fw_all.tsv" | paste -sd, -)"
    [ -z "$x" ] && f_add INFO "Forms runtime" "no runtime prestart pool - every logon starts a new frmweb process" \
        "14c option: prestart pool for the production section (FORMS_PRESTART_SECTION, FORMS_PRESTART_INIT in environment.conf) - faster logons, measured with forms_perf_analyse.sh"
    nr="$(_fwget default networkRetries)"
    [ -z "$nr" ] || [ "$nr" = 0 ] && f_add INFO "Forms runtime" "networkRetries=${nr:-0} in [default] - a short network interruption ends the session" \
        "consider a few retries (e.g. 10-30) for WLAN / VPN users - per section possible ($( awk -F'\t' 'tolower($2)=="networkretries" && $1!="default" {print $1 "=" $3}' "$CSV/.fw_all.tsv" | paste -sd, - ))"
    gz="$(_fwget default gzipCompressApplet)"
    [ "${gz,,}" = "true" ] || f_add INFO "Forms runtime" "gzipCompressApplet not TRUE" "Oracle: TRUE can reduce the application start-up time (compressed HTML / JNLP)"
fi
if [ -f "$CONFIG_XML" ]; then
    x="$(awk '/<server>/{s=1;n=""} s&&/<name>/&&n==""{n=$0; gsub(/.*<name>|<\/name>.*/,"",n)} s&&/<elf-fields>/{e=$0}
             /<\/server>/{ if (s && n ~ /FORMS/ && e !~ /time-taken/) print n; s=0; e="" }' "$CONFIG_XML" | paste -sd, -)"
    [ -n "$x" ] && f_add INFO "Forms runtime" "access log of $x without time-taken - no response times per request" \
        "14c: 06-FormsDiag/forms_perf_settings.sh --fix-accesslog, response times in forms_perf_analyse.sh"
fi
# host-specific values in the env files (the 14c host has another name / port)
if [ -n "${SRC_HOST:-}" ]; then
    hs="${SRC_HOST%%.*}"
    x="$(for ef in "${ENVFILES[@]}"; do ihwt_keys "$ef" | awk -F'\t' -v h="$hs" -v f="$(basename "$ef")" 'index(tolower($2), tolower(h)) {print $1 "\t" f}'; done \
         | sort -u | awk -F'\t' '{n[$1]++} END {for (k in n) print k " (" n[k] " env file" (n[k]>1?"s":"") ")"}' | sort | paste -sd, -)"
    [ -n "$x" ] && f_add HINT "Forms" "env file values with the old host name: $x" \
        "14c: these values from environment.conf (WLS_SERVER_FQDN, ports) - otherwise the application still calls the old host after the move"
fi

# --- jars ------------------------------------------------------------------------
x="$(cut -d';' -f1 "$CSV/jars.csv" | tr '[:upper:]' '[:lower:]' | sort | uniq -d | paste -sd, -)"
[ -n "$x" ] && f_add HINT "Jars" "same jar name in different upper / lower case: $x" "keep one spelling (Linux is case-sensitive, Windows clients are not)"
x="$(awk -F';' '$10!="" && $10!="-" {n[$10]=n[$10] (n[$10]==""?"":"=") $1; c[$10]++} END{for(h in c) if(c[h]>1) print n[h]}' "$CSV/jars.csv" | paste -sd, -)"
[ -n "$x" ] && f_add HINT "Jars" "identical jar content under different names: $x" "deliver one file"
x="$(awk -F';' '$3=="not referenced" {print $1}' "$CSV/jars.csv" | paste -sd, -)"
[ -n "$x" ] && f_add HINT "Jars" "jar(s) in forms/java referenced nowhere: $x" "probably obsolete - do not move unless needed"
x="$(awk -F';' '$9 ~ /^Java/ {split($9,a," "); if (a[2]+0 > 8) print $1 " (" $9 ")"}' "$CSV/jars.csv" | paste -sd, -)"
[ -n "$x" ] && f_add INFO "Jars" "compiled for Java > 8: $x" "needs a client JRE of that version (14c client distribution: Java 21)"
# --- Reports ---------------------------------------------------------------------
x="$(awk -F';' '$5 ~ /^[0-9]+$/ && $5+0 < 10 {print $1 " (engLife=" $5 ")"}' "$CSV/reports_servers.csv" | paste -sd, -)"
[ -n "$x" ] && f_add HINT "Reports" "very short engine life: $x - every report starts a new engine JVM (Oracle default 50: recycle after 50 jobs against memory leaks). Usually a workaround: state between reports (PL/SQL package variables, contexts, temporary tables), memory leaks or crashes - question to the customer: why was it set (SR, known problem)?" \
    "IHateWeblogic 14c instead: start with engLife=50 (Oracle default), initEngine/minEngine=2, maxEngine from CPUs x 2-4, engineResponseTimeOut from the measured run times - all values in environment.conf, checked by 05-ReportsPerformance/engine_perf_settings.sh (CPU / RAM rules) and measured by engine_perf_analyse.sh (queuing, pool usage, run times) - then tune with data instead of a fixed workaround - if state between reports is the reason: reset it in the report (e.g. DBMS_SESSION.RESET_PACKAGE in the After Report trigger) or a small engLife (5-10), not 1"
x="$(awk -F';' '$2=="standalone" {k=$4 "|" $5 "|" $10 "|" $12; n[k]=n[k] (n[k]==""?"":",") $1; c[k]++} END{for(k in c) if(c[k]>1) print n[k]}' "$CSV/reports_servers.csv" | paste -sd' ' -)"
[ -n "$x" ] && f_add INFO "Reports" "identical engine settings on several servers: $x (copied configuration)" \
    "in 14c size each server for its own load (05-ReportsPerformance/engine_perf_analyse.sh per server)"
x="$(awk -F';' '$2=="standalone" && $11=="" {print $1}' "$CSV/reports_servers.csv" | paste -sd, -)"
[ -n "$x" ] && f_add HINT "Reports" "no engineResponseTimeOut: $x - a hanging engine (endless query, lock) blocks its slot forever" \
    "14c: engineResponseTimeOut from the measured run times (engine_perf_analyse.sh proposes 2 x the longest job, at least 5 min)"
x="$(awk -F';' '$2=="standalone" {print $1 ";" $12}' "$CSV/reports_servers.csv" | while IFS=';' read -r sv jo; do
        o="$(printf '%s' "$jo" | grep -oE -- '-Xoss[^ ]*|-XX:(Max)?PermSize[^ ]*|-Xincgc|-XX:\+UseConcMarkSweepGC|-XX:\+CMSIncrementalMode|-Xnoclassgc' | paste -sd' ' -)"
        [ -n "$o" ] && printf '%s (%s)\n' "$sv" "$o"
     done | paste -sd, -)"
[ -n "$x" ] && f_add HINT "Reports" "obsolete engine JVM options: $x" \
    "ignored or rejected by newer JVMs (-Xoss ignored since HotSpot, PermGen / CMS removed up to JDK 21) - 14c: REPORTS_ENGINE_JVM_OPTIONS in environment.conf, heap checked against RAM by engine_perf_settings.sh"
x="$(awk -F';' '$2=="standalone" && $12 ~ /-Xms[0-9]+[mM]/ {m=$12; sub(/.*-Xms/,"",m); sub(/[mM].*/,"",m); if (m+0 < 64) print $1 " (-Xms" m "m)"}' "$CSV/reports_servers.csv" | paste -sd, -)"
[ -n "$x" ] && f_add INFO "Reports" "very small initial engine heap: $x" "with a fresh engine per job the heap grows again every time - 14c: -Xms close to the typical need (measured RSS in engine_perf_analyse.sh)"
x="$(awk -F';' '$2=="in-process" && $3=="yes" {print $1}' "$CSV/reports_servers.csv" | paste -sd, -)"
[ -n "$x" ] && f_add HINT "Reports" "in-process Reports server running: $x" "14c: standalone Reports server (own process, restart without WLS_REPORTS)"
x="$(awk -F';' '$2=="in-process" && $3!="yes" {print $1}' "$CSV/reports_servers.csv" | paste -sd, -)"
if [ -n "$x" ]; then
    # is it the servlet's default server? then a request without server= starts it
    d="$(awk -F';' -v s="$x" '$2==s && $3=="yes" {print $1}' "$CSV/rwservlet.csv" | head -1)"
    if [ -n "$d" ]; then
        f_add HINT "Reports" "in-process Reports server $x not running at the export - probably a leftover of the default installation, BUT it is the default server of rwservlet (inprocess=yes): every request without server= starts it inside WLS_REPORTS (with the settings of that rwserver.conf)" \
            "not created in 14c; until then point <server> in rwservlet.properties to a used standalone server or set inprocess=no"
    else
        f_add INFO "Reports" "in-process Reports server $x not running at the export - probably a leftover of the default installation" "not created in 14c"
    fi
fi
x="$(awk -F';' '$9 ~ /^[0-9]+$/ {c[$9]++; n[$9]=n[$9] " " $1} END{for(p in c) if(c[p]>1) print p ":" n[p]}' "$CSV/reports_servers.csv" | paste -sd, -)"
[ -n "$x" ] && f_add WARN "Reports" "several Reports servers with the same broadcast port: $x" "one port per server group, unique in the subnet (multicast discovery)"
# --- fonts -----------------------------------------------------------------------
n="$(awk -F';' '$4=="ms"' "$CSV/fonts.csv" | wc -l)"
[ "$n" -gt 0 ] && f_add HINT "Fonts" "$n Microsoft font file(s)" "14c uses the free replacements (section 7) - the Windows font licence does not allow copying them to another server"
x="$(awk -F';' '$4=="ms" && $5 ~ /^none/ {print $1}' "$CSV/fonts.csv" | paste -sd, -)"
[ -n "$x" ] && f_add WARN "Fonts" "symbol font(s) without a free replacement: $x" "clarify the licence or replace in the reports"
x="$(awk -F';' '$4=="customer" {print $1}' "$CSV/fonts.csv" | paste -sd, -)"
[ -n "$x" ] && f_add HINT "Fonts" "customer font(s) to move: $x" "04-ReportsFonts/custom_fonts_dir/ - licence for the new server?"
# --- sources / dependencies -----------------------------------------------------
x="$(awk -F';' '$3=="no" {print $1 " (" $2 ")"}' "$CSV/sources.csv" | paste -sd, -)"
[ -n "$x" ] && f_add WARN "Sources" "configured directory does not exist: $x" "remove from the path or create - a missing FORMS_PATH / REPORTS_PATH entry costs a lookup per module"
x="$(awk -F';' '$5 ~ /^[0-9]+$/ && $5+0 > 0 && $6+0 == 0 {print $1}' "$CSV/sources.csv" | paste -sd, -)"
[ -n "$x" ] && f_add HINT "Sources" ".fmb without .fmx in: $x" "sources only (compile on 14c) or a separate source tree - clarify"
x="$(awk -F';' '$2 !~ /folderAccess/ && $4 ~ /:7[0-7]7$/ {print $1}' "$CSV/sources.csv" | paste -sd, -)"
[ -n "$x" ] && f_add WARN "Sources" "world-writable source directory: $x" "mode 750 / 770 - otherwise any OS user can replace modules"
x="$(awk -F';' '$3=="NOT FOUND" {print $1}' "$CSV/deps_libs.csv" | paste -sd, -)"
[ -n "$x" ] && f_add WARN "Dependencies" "libraries / menus used but not found in a source directory: $x" "locate them (FORMS_PATH of another env file? only as .pll?) - needed for the 14c compile"
n="$(grep -c 'explicit reference' "$CSV/deps_missing.csv")"
[ "$n" -gt 0 ] && f_add WARN "Dependencies" "$n module(s) referenced explicitly but not present (section 9.2)" "provide or remove the call"
n="$(grep -c 'referenced file not found' "$CSV/deps_missing.csv")"
[ "$n" -gt 0 ] && f_add HINT "Dependencies" "$n referenced file(s) (images, scripts) not found (section 9.2)" "check the report / JSP templates"
# --- platform --------------------------------------------------------------------
case "$SRC_FMW" in 12.*) f_add INFO "Platform" "source is FMW $SRC_FMW with $SRC_JAVA" \
    "14c: FMW 14.1.2 with JDK 21, Forms client via Java Web Start / FSAL (no browser applet), recompile all modules" ;; esac

# --- load profile ------------------------------------------------------------------
if [ -d "$LD" ]; then
    ndays="$(wc -l < "$LD/forms_traffic.csv" 2>/dev/null || echo 0)"
    x="$(awk -F';' '$2=="0" {print $1}' "$CSV/load_forms_sections.csv" | while read -r sec; do
            case " $STD_SECTIONS " in *" $sec "*) ;; *) printf '%s\n' "$sec" ;; esac; done | paste -sd, -)"
    [ -n "$x" ] && [ "${ndays:-0}" -ge 7 ] && f_add HINT "Load" "customer section(s) without an application start in $ndays days of logs: $x" \
        "candidates to leave out of the 14c configuration (clarify: other entry URL, seasonal use?)"
    fc="$(_nv frmweb_count)"; fa="$(_nv frmweb_rss_avg_mb)"
    if [ -n "$fc" ] && [ "$fc" -gt 0 ] 2>/dev/null; then
        f_add INFO "Load" "$fc frmweb processes at the export, about $fa MB RSS each" \
            "sizing basis for 14c: maxRuntimeProcesses ~ half of the RAM / MB per session under load (frm_mrp_proposal) - measure the peak with 06-FormsDiag/forms_perf_analyse.sh"
    fi
    x="$(awk -F';' '{if ($3+0 > 0 && 100*$5/$3 > 1) print $1 " (" $5 " of " $3 ")"}' "$CSV/load_forms_days.csv" | paste -sd, -)"
    [ -n "$x" ] && f_add HINT "Load" "days with more than 1 % HTTP 5xx on WLS_FORMS: $x" "check the Forms servlet / WLS_FORMS logs of these days"
    x="$(awk -F';' '$5 ~ /%/ {v=$5; sub(/ %/,"",v); if (v+0 > 5) print $1 " (" $5 ")"}' "$CSV/load_reports_servers.csv" | paste -sd, -)"
    [ -n "$x" ] && f_add WARN "Load" "Reports failure rate above 5 %: $x" "the failed jobs per report are in section 12.5 - clarify before the move (missing fonts, images, DB objects?)"
    mx="$(awk -F';' '$6 ~ /^[0-9]+$/ && $6+0 > m {m=$6} END {print m+0}' "$CSV/load_reports_jobs.csv")"
    if [ "${mx:-0}" -gt 0 ]; then
        ert="$(awk -v s="$mx" 'BEGIN { m = int((2 * s + 59) / 60); if (m < 5) m = 5; print m }')"
        f_add INFO "Load" "longest report of the past queue: $mx s" "proposal for 14c engineResponseTimeOut: $ert min (2 x longest job, at least 5 - rws_ert_proposal of 05-ReportsPerformance)"
    fi
    while IFS=';' read -r sv mxe; do
        u="$(awk -F';' -v s="$sv" '$1==s {split($8,a," / "); print a[1]}' "$CSV/load_reports_servers.csv")"
        [ -n "$u" ] && [ "$u" != "-" ] && [ -n "$mxe" ] && [ "${u%.*}" -ge "$mxe" ] 2>/dev/null && \
            f_add HINT "Load" "Reports server $sv used all $mxe engines (maxEnginesUsed)" "jobs had to queue - 14c: maxEngine from CPUs and the measured queuing (engine_perf_analyse.sh)"
    done < <(awk -F';' '{print $1 ";" $4}' "$CSV/reports_servers.csv" | sed 's#;.*/#;#')
    x="$(awk -F';' '$3 ~ /^[0-9]+$/ && $3+0 >= 80 {print $1 " (" $3 " %)"}' "$CSV/load_sar.csv" | paste -sd, -)"
    [ -n "$x" ] && f_add HINT "Load" "CPU peaks of 80 % and more: $x" "size the 14c host with reserve (Forms + Reports engines + WebLogic on one host)"
    x="$(awk -F';' '$4 ~ /^[0-9]+$/ && $4+0 >= 90 {print $1 " (" $4 " %)"}' "$CSV/load_sar.csv" | paste -sd, -)"
    [ -n "$x" ] && f_add HINT "Load" "memory use of 90 % and more: $x" "check swap / OOM in the OS log of these days, more RAM for 14c"
    [ -s "$LD/host_sar.csv" ] || nc_add "Host history (sar)" "no sysstat data on the old host"
fi

# --- not checked -----------------------------------------------------------------
nc_add "Reports diagnostic output (showenv) disabled" "not part of the export yet"
md "Rule;reason" not_checked < "$NOTCHK"

# findings: security first, WARN > HINT > INFO
_fsort() { awk -F';' 'BEGIN{o["WARN"]=1;o["HINT"]=2;o["INFO"]=3} {print o[$1] ";" $0}' | sort -t';' -k1,1n -k3,3 | cut -d';' -f2-; }
grep '^[A-Z]*;Security' "$FIND" | _fsort | M > "$CSV/findings_security.csv"
grep -v '^[A-Z]*;Security' "$FIND" | _fsort | M > "$CSV/findings_other.csv"
md "Severity;area;finding;recommendation" findings_security < "$CSV/findings_security.csv"
md "Severity;area;finding;recommendation" findings_other < "$CSV/findings_other.csv"

# =============================================================================
# 14. fill the template
# =============================================================================
say "report ..."
export IHWA_CUSTOMER="$CUST" IHWA_DATE="$DATE" IHWA_SRC_HOST="${SRC_HOST:--}" \
    IHWA_SRC_ORACLE_HOME="${SRC_OH:--}" IHWA_SRC_DOMAIN_HOME="${SRC_DH:--}" \
    IHWA_SRC_FMW_VERSION="${SRC_FMW:--}" IHWA_SRC_JAVA="${SRC_JAVA:--}" \
    IHWA_EXPORT_FILE="$(basename "$IN")" IHWA_EXPORT_VERSION="${EXP_VER:-unknown}" \
    IHWA_REF_INFO="$REF_INFO" IHWA_ANALYSE_VERSION="$VERSION" IHWA_LIB_VERSION="$(ihwt_lib_version)" \
    IHWA_N_FORMS_SECTIONS="$N_SEC" IHWA_N_ENV_FILES="${#ENVFILES[@]}" \
    IHWA_N_JARS="$(wc -l < "$CSV/jars.csv")" IHWA_N_REPORTS_SERVERS="$N_RS" \
    IHWA_N_FONTS="$(wc -l < "$CSV/fonts.csv")" IHWA_N_SOURCE_DIRS="$(tail -n +2 "$ROOT/sources_inventory.csv" 2>/dev/null | wc -l)" \
    IHWA_N_MODULES="$N_MOD" IHWA_N_TNS_DEFINED="$N_TNS_DEF" IHWA_N_TNS_USED="$N_TNS_USED" \
    IHWA_N_SECRETS="$N_SEC_PLACES" \
    IHWA_N_WARN="$(cnt '^WARN;' "$FIND")" IHWA_N_HINT="$(cnt '^HINT;' "$FIND")" IHWA_N_INFO="$(cnt '^INFO;' "$FIND")" \
    IHWA_ENV_PROPOSAL="${ENV_PROPOSAL:-# no proposal in the export}" \
    IHWA_LOAD_INFO="$LOAD_INFO" IHWA_LOAD_PERIOD="$LOAD_PERIOD" IHWA_LOAD_FRMWEB="$LOAD_FRMWEB" \
    IHWA_LOAD_RWENG="$LOAD_RWENG" IHWA_LOAD_HOST="$LOAD_HOST" \
    IHWA_N_ENV_EXPORT="$N_ENV_EXPORT" IHWA_N_ENV_DEC="$N_ENV_DEC" IHWA_N_ENV_MISS="$N_ENV_MISS"
awk -v mddir="$MD" '
    /^<!-- BLOCK:[a-z_]+ -->$/ { b=$0; sub(/^<!-- BLOCK:/,"",b); sub(/ -->$/,"",b)
        f=mddir "/" b ".md"; if ((getline l < f) > 0) { print l; while ((getline l < f) > 0) print l; close(f) } else print "_none found_"
        next }
    { while (match($0, /\{\{[A-Z_]+\}\}/)) { k=substr($0, RSTART+2, RLENGTH-4); v=ENVIRON["IHWA_" k]
          $0 = substr($0, 1, RSTART-1) v substr($0, RSTART+RLENGTH) }
      print }' "$TEMPLATE" > "$REPORT.tmp"

# =============================================================================
# 15. clear-text check of the finished report (second safety line)
# =============================================================================
hits="$(grep -nE '(password|passwd|pwd|userid|authid)[[:space:]]*=[[:space:]]*[^*%[:space:]<;|]' "$REPORT.tmp" | grep -v '\*\*\*MASKED\*\*\*' ;
        grep -nE '\{AES(256)?\}[A-Za-z0-9+/]{8,}' "$REPORT.tmp" ;
        grep -nE '<identifier[^>]*>[^<*][^<]*</identifier>' "$REPORT.tmp" ;
        grep -nE '[A-Za-z0-9_]+/[^*@[:space:]/|;]+@[A-Za-z][A-Za-z0-9_.]*' "$REPORT.tmp" | grep -vE '@//|https?://' )"
if [ -n "$hits" ]; then
    rm -f "$REPORT.tmp"
    printf '  ERROR possible clear-text secret in the report - report deleted. Lines (values cut):\n' >&2
    printf '%s\n' "$hits" | cut -c1-60 | sed 's/^/    /' >&2
    exit 1
fi
mv -f "$REPORT.tmp" "$REPORT"
rm -rf "${MD:?}" "$CSV"/.[a-z]*

say "Report  : $REPORT"
say "Findings: $IHWA_N_WARN WARN, $IHWA_N_HINT HINT, $IHWA_N_INFO INFO"
say "Customer data - never commit it to git (run dir is git-ignored)."
exit 0
