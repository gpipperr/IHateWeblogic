#!/bin/bash
# =============================================================================
# Script   : customer_conf_import.sh
# Purpose  : Import the configuration of an existing customer environment
#            (12c / 14c, export of 70-Customer-Projects/tools/bash/
#            export_forms_reports_conf.sh) into the customer overlay of a
#            library environment (doc 09-Install/docs/17-customer_conf_import.md):
#              00-Setup/environments/<env>.customer/   forms/, reports/, fonts/
#              + IMPORT_DECISIONS.md (every correction, how to take it back)
#              + a "# === CUSTOMER IMPORT" block in environments/<env>.conf
#                (only keys that are not set yet; CUSTOMER_CONF_DIR)
#            The install scripts 13- / 14- / 14b- (+ 04-ReportsFonts) read
#            the overlay - Way 1 new installation, Way 2 existing environment
#            (07-Maintenance/apply_customer_conf.sh).
#            WARN findings are corrected to the 14c value; --keep-customer
#            RULE takes the customer value on purpose. Passwords never go
#            into the overlay (stored logins are removed).
# Call     : ./00-Setup/customer_conf_import.sh -i <export.zip|.zip.enc|dir>
#                 [--env <name>] [--keep-customer RULE ...] [--apply]
#            -i      export (encrypted zip asks the passphrase, zip, directory)
#            --env   target environments/<name>.conf (default: the one the
#                    environment.conf link points to); a missing conf is
#                    created with the import block only (Way 1, then
#                    09-Install/01-setup-interview.sh)
#            --keep-customer RULE   see the rule list (--rules)
#            --rules list the correction rules and exit
#            --apply write the overlay + conf block (default: dry run)
# Output   : dry run - tree, decisions, conf block; --apply - files above,
#            an existing overlay is moved to <env>.customer.bak_<ts> first
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
TLIB="$ROOT_DIR/70-Customer-Projects/tools/bash/ihw_tools_lib.sh"
[ -f "$LIB" ] || { printf "Cannot find IHateWeblogic_lib.sh: %s\n" "$LIB" >&2; exit 2; }
# shellcheck source=IHateWeblogic_lib.sh
source "$LIB"
# shellcheck source=../70-Customer-Projects/tools/bash/ihw_tools_lib.sh
source "$TLIB" || { printf "Cannot find ihw_tools_lib.sh: %s\n" "$TLIB" >&2; exit 2; }
VERSION="2026-11-05.1"
umask 077

# --- correction rules (ID -> description); --keep-customer ID keeps the customer value
declare -A RULES=(
    [FORMS_DEBUG]="formsweb.cfg allow_debug=true -> false"
    [FORMS_URLPARAMS]="own restrictedURLparams -> the 14c list of our template"
    [FORMS_ENTER_QUERY]="FORMS_RESTRICT_ENTER_QUERY=FALSE -> TRUE"
    [WEBUTIL_ACCESS]="webutil transfer.appsrv.accessControl=FALSE -> TRUE"
    [WEBUTIL_DIRS]="webutil transfer directories /tmp etc. -> ##FORMS_TMP##/webutil"
    [REPORTS_ENGINE]="engine values of the customer (engLife=1 ...) -> REPORTS_ENGINE_* of the library"
    [REPORTS_INPROC]="in-process Reports server -> not taken over (standalone servers only)"
    [JARS_UNUSED]="jars not referenced anywhere -> not taken over"
    [FONT_MS]="Microsoft fonts -> not taken over (licence, free replacements of 14b-)"
)
NOKEEP="FORMS_USERID (stored logins are always removed)"

INP=""; ENVNAME=""; APPLY=false; declare -A KEEP=()
while [ $# -gt 0 ]; do
    case "$1" in
        -i) INP="${2:-}"; shift ;;
        --env) ENVNAME="${2:-}"; shift ;;
        --keep-customer) KEEP[${2:-}]=1; [ -n "${RULES[${2:-}]+x}" ] || { printf 'unknown rule: %s (--rules)\n' "${2:-}" >&2; exit 2; }; shift ;;
        --apply) APPLY=true ;;
        --rules) for k in $(printf '%s\n' "${!RULES[@]}" | sort); do printf '  %-18s %s\n' "$k" "${RULES[$k]}"; done
                 printf '  never kept: %s\n' "$NOKEEP"; exit 0 ;;
        -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
        *) printf 'Unknown option: %s (see --help)\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$INP" ] && [ -e "$INP" ] || { printf 'export not found: -i <export.zip|.zip.enc|dir>\n' >&2; exit 2; }
keep() { [ -n "${KEEP[$1]+x}" ]; }

# --- target environment --------------------------------------------------------
if [ -z "$ENVNAME" ]; then
    [ -L "$ENV_CONF" ] || { printf 'no environment.conf link - use --env <name>\n' >&2; exit 2; }
    ENVNAME="$(basename "$(readlink -f "$ENV_CONF")" .conf)"
fi
[[ "$ENVNAME" =~ ^[A-Za-z0-9_.-]+$ ]] || { printf -- '--env: letters, digits, . _ - only\n' >&2; exit 2; }
TCONF="$ROOT_DIR/00-Setup/environments/$ENVNAME.conf"
OVL="$ROOT_DIR/00-Setup/environments/$ENVNAME.customer"
# values of the target (paths of the new host) - only read, never executed blind
if [ -f "$TCONF" ]; then
    # shellcheck disable=SC1090
    source "$TCONF"
fi
init_log

section "Customer configuration import $VERSION"
printList "Export" 22 "$INP"
printList "Target conf" 22 "$TCONF$( [ -f "$TCONF" ] || printf ' (new - created with the import block)')"
printList "Overlay" 22 "$OVL"
printList "Mode" 22 "$($APPLY && printf 'APPLY' || printf 'dry run')"
[ ${#KEEP[@]} -gt 0 ] && printList "keep customer value" 22 "${!KEEP[*]}"

# --- unpack (clear text with an encrypted export - private temp, removed at exit)
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
if [ -d "$INP" ]; then
    XD="$INP"
else
    ihwt_unpack "$(readlink -f "$INP")" "$WORK/export" || { fail "unpacking failed"; print_summary; exit 2; }
    XD="$WORK/export"
fi
X="$(dirname "$(find "$XD" -maxdepth 3 -name 00_report.txt | head -1)")"
IMP="$X/ihw_import"; RAW="$X/raw"
[ -f "$X/00_report.txt" ] && [ -d "$IMP" ] || { fail "no export (00_report.txt / ihw_import) in $INP"; print_summary; exit 2; }
_rv() { sed -n "s/^$1[[:space:]]\{2,\}//p" "$X/00_report.txt" | head -1; }
OLD_OH="$(_rv ORACLE_HOME)"; OLD_DH="$(_rv DOMAIN_HOME)"; OLD_HOST="$(_rv Host)"
EXP_VER="$(sed -n '2s/^export_forms_reports_conf.sh \([0-9.-]*\).*/\1/p' "$X/00_report.txt")"
PROP="$IMP/environment.conf.proposal"
_pv() { sed -n "s/^$1=\"\\([^\"]*\\)\".*/\\1/p" "$PROP" 2>/dev/null | head -1; }
OLD_FQDN="$(_pv WLS_SERVER_FQDN)"; OLD_FQDN="${OLD_FQDN%% *}"
# an IP is no public name: DNS name of the HTTPS listeners of the web tier
if [[ "$OLD_FQDN" =~ ^[0-9.]*$ ]] && [ -f "$IMP/web_tier.txt" ]; then
    _n="$(awk -F';' 'NR>1 && $5=="yes" {print $4}' "$IMP/web_tier.txt" | tr ',' '\n' | grep -vE '^(_|localhost|\*.*|-|[0-9.]+)?$' | head -1)"
    [ -n "$_n" ] && OLD_FQDN="$_n"
fi
[ -z "$OLD_FQDN" ] && OLD_FQDN="$OLD_HOST"
printList "Source host" 22 "$OLD_HOST (export $EXP_VER)"
printList "Source ORACLE_HOME" 22 "$OLD_OH"
printList "Source DOMAIN_HOME" 22 "$OLD_DH"

STG="$WORK/overlay"; mkdir -p "$STG/forms/env" "$STG/forms/jars" "$STG/reports" "$STG/fonts"
DEC="$WORK/decisions.csv"; : > "$DEC"
# dec RULE FILE/KEY CUSTOMER 14C REASON
dec() { printf '%s;%s;%s;%s;%s\n' "$1" "$2" "$(printf '%s' "$3" | ihwt_mask | sed 's/;/,/g' | cut -c1-120)" "$(printf '%s' "$4" | sed 's/;/,/g')" "$5" >> "$DEC"; }

# primary module directory of the customer (the one with the most .fmx)
OLD_FMX="$(awk -F';' 'NR>1 && $1 !~ /^\$ORACLE_HOME/ && $6 ~ /^[0-9]+$/ && $6+0 > m {m=$6; d=$1} END {print d}' "$X/sources_inventory.csv" 2>/dev/null)"
# path rewrite of one value: old homes / module dir / host -> placeholders
rew() {
    local v="$1"
    [ -n "$OLD_DH" ] && v="${v//$OLD_DH/##DOMAIN_HOME##}"
    [ -n "$OLD_OH" ] && v="${v//$OLD_OH/##ORACLE_HOME##}"
    [ -n "$OLD_FMX" ] && v="$(printf '%s' "$v" | sed -E "s|(^\|[:;=])${OLD_FMX}([:;/]\|\$)|\\1##FORMS_CUSTOMER_DIR##\\2|g")"
    [ -n "$OLD_FQDN" ] && v="${v//$OLD_FQDN/##WLS_SERVER_FQDN##}"
    [ -n "$OLD_HOST" ] && v="${v//$OLD_HOST/##WLS_SERVER_FQDN##}"
    printf '%s' "$v"
}

# =============================================================================
# 1. formsweb.cfg
# =============================================================================
section "Forms - formsweb.cfg"
STD=" default sepwin debug webutil jnlp webutil_jnlp webstart webutil_webstart standaloneapp webutil_standaloneapp "
: > "$STG/forms/formsweb.default.cfg"
if [ -f "$IMP/formsweb.cfg.default_overrides" ]; then
    grep -v '^[[:space:]]*#' "$IMP/formsweb.cfg.default_overrides" | grep '=' | while IFS= read -r l; do
        k="${l%%=*}"; v="${l#*=}"
        case "$k" in
            userid) dec FORMS_USERID "formsweb.cfg [default] userid" "(login)" "removed" "no stored database login - 14c: SSO / login form" ;;
            allow_debug) if [ "${v,,}" = true ] && ! keep FORMS_DEBUG; then dec FORMS_DEBUG "formsweb.cfg [default] allow_debug" "$v" "false (template)" "debug mode shows the runtime to every user"; else printf '%s=%s\n' "$k" "$v"; fi ;;
            restrictedURLparams) if keep FORMS_URLPARAMS; then printf '%s=%s\n' "$k" "$v"; else dec FORMS_URLPARAMS "formsweb.cfg [default] restrictedURLparams" "$v" "14c list of the template" "own list is shorter than the 14c standard"; fi ;;
            *) printf '%s=%s\n' "$k" "$(rew "$v")" ;;
        esac
    done >> "$STG/forms/formsweb.default.cfg"
fi
: > "$STG/forms/formsweb.sections.cfg"
if [ -f "$IMP/formsweb.cfg.sections" ]; then
    awk -v std="$STD" '
        /^[[:space:]]*#/ { next }
        /^\[[^]]+\]/ { s=$0; gsub(/^\[|\].*$/, "", s); on = (index(std, " " s " ") == 0); if (on) { print ""; print "[" s "]" }; next }
        on && /=/ { print }' "$IMP/formsweb.cfg.sections" > "$WORK/sec.raw"
    sec=""
    while IFS= read -r l; do
        case "$l" in
            '') printf '\n' ;;
            '['*) sec="${l#[}"; sec="${sec%]}"; printf '%s\n' "$l" ;;
            *) k="${l%%=*}"; v="${l#*=}"
               case "$k" in
                   userid) dec FORMS_USERID "formsweb.cfg [$sec] userid" "(login)" "removed" "no stored database login - 14c: login dialog / SSO" ;;
                   allow_debug) if [ "${v,,}" = true ] && ! keep FORMS_DEBUG; then dec FORMS_DEBUG "formsweb.cfg [$sec] allow_debug" "$v" "removed (false of [default])" "debug mode shows the runtime to every user"; else printf '%s\n' "$l"; fi ;;
                   restrictedURLparams) if keep FORMS_URLPARAMS; then printf '%s\n' "$l"; else dec FORMS_URLPARAMS "formsweb.cfg [$sec] restrictedURLparams" "$v" "removed (14c list of [default])" "own list per section is shorter than the 14c standard"; fi ;;
                   *) printf '%s=%s\n' "$k" "$(rew "$v")" ;;
               esac ;;
        esac
    done < "$WORK/sec.raw" | sed '1{/^$/d}' > "$STG/forms/formsweb.sections.cfg"
fi
NSEC="$(grep -c '^\[' "$STG/forms/formsweb.sections.cfg")"
ok "$(printf "  %-26s %s" "[default] keys" "$(grep -c '=' "$STG/forms/formsweb.default.cfg")")"
ok "$(printf "  %-26s %s" "customer sections" "$NSEC ($(grep '^\[' "$STG/forms/formsweb.sections.cfg" | tr -d '[]' | paste -sd' '))")"
# sections without a start in the load period - kept, decision for the customer
if [ -f "$X/load/forms_starts.csv" ]; then
    for s in $(grep '^\[' "$STG/forms/formsweb.sections.cfg" | tr -d '[]'); do
        awk -F';' -v s="$s" '$2==s {n+=$3} END {exit (n > 0)}' "$X/load/forms_starts.csv" && \
            dec SECTION_UNUSED "formsweb.cfg [$s]" "no application start in the load period" "taken over" "clarify with the customer: drop the section in the overlay if it is not needed"
    done
fi

# =============================================================================
# 2. env files (one per envFile= + default.env)
# =============================================================================
section "Forms - env files"
TPL_CP="$(sed -n 's/^CLASSPATH=//p' "$ROOT_DIR/09-Install/forms_templates/default.env.template" | head -1)"
TPL_FP="$(sed -n 's/^FORMS_PATH=##FORMS_CUSTOMER_DIR##://p' "$ROOT_DIR/09-Install/forms_templates/default.env.template" | head -1)"
SKIP_ENV=" WEBUTIL_CONFIG ORACLE_HOME FORMS_INSTANCE TNS_ADMIN COMPONENT_CONFIG_PATH PATH LD_LIBRARY_PATH LD_PRELOAD TMPDIR FORMS_MODULE_PATH CLASSPATH FORMS_PATH "
if [ -f "$IMP/default.env.customer_keys" ]; then
    awk '/^# \// { f=$2; n=split(f, a, "/"); f=a[n]; next } /^[[:space:]]*#/ || !/=/ { next } { print f "\t" $0 }' \
        "$IMP/default.env.customer_keys" > "$WORK/env.tsv"
    for ef in $(cut -f1 "$WORK/env.tsv" | sort -u); do
        out="$STG/forms/env/$ef"; : > "$out"
        while IFS=$'\t' read -r f l; do
            [ "$f" = "$ef" ] || continue
            k="${l%%=*}"; v="${l#*=}"
            case " $SKIP_ENV " in *" $k "*) continue ;; esac
            case "$k" in
                FORMS_PATH_CUSTOMER)
                    nv="$(rew "$v")"; printf 'FORMS_PATH=%s:%s\n' "$nv" "$TPL_FP" >> "$out"
                    for _p in ${nv//:/ }; do
                        [[ "$_p" == "##"* ]] || dec PATH_KEPT "$ef FORMS_PATH" "$_p" "$_p (kept)" "directory outside the library tree - create / move it on the new host or map it in the overlay"
                    done ;;
                CLASSPATH_CUSTOMER)
                    printf 'CLASSPATH=%s:%s\n' "$TPL_CP" "$(rew "$v")" >> "$out" ;;
                FORMS_RESTRICT_ENTER_QUERY)
                    if [ "${v^^}" = FALSE ] && ! keep FORMS_ENTER_QUERY; then
                        printf 'FORMS_RESTRICT_ENTER_QUERY=TRUE\n' >> "$out"
                        dec FORMS_ENTER_QUERY "$ef FORMS_RESTRICT_ENTER_QUERY" "$v" "TRUE" "FALSE lets users enter own WHERE conditions in Enter Query mode"
                    else printf '%s=%s\n' "$k" "$v" >> "$out"; fi ;;
                REPORTS_TMP)
                    printf 'REPORTS_TMP=##REPORTS_TMP##\n' >> "$out"
                    dec PATH_MAPPED "$ef REPORTS_TMP" "$v" "##REPORTS_TMP## (environment.conf)" "one Reports output directory of the library" ;;
                *)
                    nv="$(rew "$v")"; printf '%s=%s\n' "$k" "$nv" >> "$out"
                    [ "$nv" != "$v" ] && [[ "$nv" == *WLS_SERVER_FQDN* ]] && \
                        dec HOST_MAPPED "$ef $k" "$v" "$nv" "old host name -> WLS_SERVER_FQDN of the new host (check ports / protocol in the value)" ;;
            esac
        done < "$WORK/env.tsv"
        ok "$(printf "  %-26s %s keys" "$ef" "$(grep -c '=' "$out")")"
    done
fi
# env files of the old host that no section uses
_fwd="$(dirname "$(find "$RAW" -path '*/config/formsweb.cfg' 2>/dev/null | head -1)")"
for _e in "$_fwd"/*.env; do
    [ -f "$_e" ] || continue
    [ -f "$STG/forms/env/$(basename "$_e")" ] || dec ENV_UNUSED "env file $(basename "$_e")" "no envFile= of a section uses it" "not taken over" "leftover - add a section with envFile=$(basename "$_e") to the overlay if it is still needed"
done

# =============================================================================
# 3. webutil.cfg
# =============================================================================
section "Forms - webutil.cfg"
: > "$STG/forms/webutil.cfg.overrides"
if [ -f "$IMP/webutil.cfg.overrides" ]; then
    grep -v '^[[:space:]]*#' "$IMP/webutil.cfg.overrides" | grep '=' | while IFS= read -r l; do
        k="${l%%=*}"; v="${l#*=}"
        case "$k" in
            transfer.appsrv.accessControl)
                if [ "${v^^}" = FALSE ] && ! keep WEBUTIL_ACCESS; then
                    printf '%s=TRUE\n' "$k"; dec WEBUTIL_ACCESS "webutil.cfg $k" "$v" "TRUE" "without access control the client can read / write every file of the server user"
                else printf '%s\n' "$l"; fi ;;
            transfer.appsrv.workAreaRoot|transfer.appsrv.read.*|transfer.appsrv.write.*)
                if [[ "$v" =~ ^/(tmp|var/tmp)/?$|^/$ ]] && ! keep WEBUTIL_DIRS; then
                    printf '%s=##FORMS_TMP##/webutil\n' "$k"; dec WEBUTIL_DIRS "webutil.cfg $k" "$v" "##FORMS_TMP##/webutil" "only a dedicated transfer directory below the Forms work area"
                else printf '%s=%s\n' "$k" "$(rew "$v")"; fi ;;
            *) printf '%s=%s\n' "$k" "$(rew "$v")" ;;
        esac
    done | sort -u > "$STG/forms/webutil.cfg.overrides"
fi
ok "$(printf "  %-26s %s" "keys" "$(grep -c '=' "$STG/forms/webutil.cfg.overrides")")"

# =============================================================================
# 4. customer jars (deduplicated by content and by case)
# =============================================================================
section "Forms - customer jars"
if [ -f "$IMP/jars.txt" ]; then
    # referenced first, then by name: the first of one sha256 wins
    awk -F';' 'NR>1 { r = ($4 ~ /not referenced/ ? 1 : 0); n=$1; sub(/.*\//, "", n); print r ";" $3 ";" n ";" $5 }' "$IMP/jars.txt" \
        | sort -t';' -k1,1n -k3,3 > "$WORK/jars.srt"
    declare -A SEEN_SHA=() SEEN_LC=()
    while IFS=';' read -r unref sha name stored; do
        src="$X/$stored"; lc="${name,,}"
        if [ -n "${SEEN_SHA[$sha]:-}" ]; then
            dec JAR_DUPLICATE "jar $name" "same content as ${SEEN_SHA[$sha]}" "not taken over" "one file per content - archive= uses ${SEEN_SHA[$sha]}"; continue
        fi
        if [ -n "${SEEN_LC[$lc]:-}" ]; then
            dec JAR_DUPLICATE "jar $name" "same name as ${SEEN_LC[$lc]} in another case, other content" "not taken over" "Linux is case-sensitive - check which one the application needs"; continue
        fi
        if [ "$unref" = 1 ] && ! keep JARS_UNUSED; then
            dec JARS_UNUSED "jar $name" "not referenced in formsweb.cfg / env files" "not taken over" "probably obsolete"; continue
        fi
        [ -f "$src" ] || { warn "jar missing in the export: $stored"; continue; }
        cp -p "$src" "$STG/forms/jars/$name"; SEEN_SHA[$sha]="$name"; SEEN_LC[$lc]="$name"
    done < "$WORK/jars.srt"
fi
ok "$(printf "  %-26s %s" "jars taken over" "$(ls "$STG/forms/jars" | wc -l)")"

# =============================================================================
# 5. Reports servers, cgicmd.dat
# =============================================================================
section "Reports"
RS_LIST=""
if [ -f "$IMP/reports_servers.txt" ]; then
    while IFS=';' read -r name type running conf eng life ident secid jsr bport; do
        case "$name" in name|'#'*|'') continue ;; esac
        if [ "$type" != standalone ] && ! keep REPORTS_INPROC; then
            dec REPORTS_INPROC "Reports server $name ($type)" "running=$running" "not taken over" "14c: standalone servers only (the in-process server is a leftover of the default installation)"; continue
        fi
        RS_LIST="${RS_LIST:+$RS_LIST }$name"
        [ "$life" = 1 ] || [ "${life:-50}" -lt 10 ] 2>/dev/null && ! keep REPORTS_ENGINE && \
            dec REPORTS_ENGINE "Reports server $name engLife" "$life" "REPORTS_ENGINE_LIFE of environment.conf (library 50)" "engLife=1 restarts the engine after every job - measure instead (05-ReportsPerformance)"
        rc="$RAW/other$conf"; [ -f "$rc" ] || rc="$(find "$RAW" -path "*ReportsServerComponent/$name/rwserver.conf" | head -1)"
        out="$STG/reports/$name.env"; : > "$out"
        if [ -f "$rc" ]; then
            sed -n 's/.*<envVariable[[:space:]]\+name="\([^"]*\)"[[:space:]]\+value="\([^"]*\)".*/\1=\2/p' "$rc" | while IFS='=' read -r k v; do
                case "$k" in
                    REPORTS_PATH|REPORTS_TMP|REPORTS_TEMP|REPORTS_FONT_DIRECTORY|TNS_ADMIN|ORACLE_HOME|PATH|LD_LIBRARY_PATH|COMPONENT_CONFIG_PATH|DOMAIN_HOME)
                        dec PATH_MAPPED "rwserver.conf $name $k" "$v" "set by 13- from environment.conf" "paths of the old host are not taken over" ;;
                    *)  nv="$(rew "$v")"
                        if [[ "$nv" == *"##"* ]]; then dec PATH_MAPPED "rwserver.conf $name $k" "$v" "not taken over" "contains a path of the old host - set it in environment.conf"
                        else printf '%s=%s\n' "$k" "$v" >> "$out"; fi ;;
                esac
            done
            # -Xoss and other obsolete JVM options: the engine values come from environment.conf
            grep -q -- '-Xoss' "$rc" && ! keep REPORTS_ENGINE && \
                dec REPORTS_ENGINE "rwserver.conf $name jvmOptions" "$(grep -o 'jvmOptions="[^"]*"' "$rc" | head -1)" "REPORTS_ENGINE_* / REPORTS_JVM_OPTIONS of environment.conf" "-Xoss is obsolete since JDK 8"
        fi
        [ -s "$out" ] || rm -f "$out"
        ok "$(printf "  %-26s %s" "server $name" "$( [ -f "$out" ] && printf '%s environment value(s)' "$(wc -l < "$out")" || printf 'no own environment values')")"
    done < "$IMP/reports_servers.txt"
fi
if [ -f "$IMP/cgicmd.dat.customer_keys" ]; then
    grep -v '^[[:space:]]*#' "$IMP/cgicmd.dat.customer_keys" | sed '/^[[:space:]]*$/d' | while IFS= read -r l; do
        key="${l%%:*}"
        if printf '%s' "$l" | grep -qiE '(^|[[:space:]])userid[[:space:]]*='; then
            printf '%s\n' "$l" | sed -E 's/(^|[[:space:]])userid[[:space:]]*=[^[:space:]]*//I'
            dec FORMS_USERID "cgicmd.dat key $key" "(login)" "userid removed" "14c: login via cmdkey of the RepRunner user / %D"
        else printf '%s\n' "$l"; fi
    done > "$STG/reports/cgicmd.dat.customer"
    [ -s "$STG/reports/cgicmd.dat.customer" ] || rm -f "$STG/reports/cgicmd.dat.customer"
fi
ok "$(printf "  %-26s %s" "cgicmd.dat keys" "$( [ -f "$STG/reports/cgicmd.dat.customer" ] && wc -l < "$STG/reports/cgicmd.dat.customer" || printf 0)")"
dec REPORTS_SECURITY "rwservlet / rwserver.conf" "webcommandaccess / securityId / identifier of the customer" "secured 14c server (13-: securityId, encrypted identifier, webcommandaccess L1)" "taken from the library - no customer value"

# =============================================================================
# 6. fonts
# =============================================================================
section "Fonts"
if [ -f "$IMP/fonts.txt" ]; then
    awk -F';' 'NR>1 {print $1 ";" $4 ";" $5}' "$IMP/fonts.txt" | while IFS=';' read -r fnt cls repl; do
        src="$IMP/custom_fonts_dir/$fnt"
        case "$cls" in
            customer) [ -f "$src" ] && cp -p "$src" "$STG/fonts/" ;;
            ms) if keep FONT_MS; then [ -f "$src" ] && cp -p "$src" "$STG/fonts/"
                    dec FONT_MS "font $fnt" "Microsoft font" "taken over (--keep-customer FONT_MS)" "only with a licence that allows the copy to the new server"
                else dec FONT_MS "font $fnt" "Microsoft font" "${repl:-free replacement}" "Windows / Office licence does not allow copying the font to another server"; fi ;;
        esac
    done
fi
if [ -f "$IMP/uifont.ali.customer" ] && grep -qv '^[[:space:]]*\(#\|$\)' "$IMP/uifont.ali.customer"; then
    grep -v '^[[:space:]]*#' "$IMP/uifont.ali.customer" > "$STG/fonts/uifont.ali.customer"
fi
ok "$(printf "  %-26s %s" "customer fonts" "$(find "$STG/fonts" -maxdepth 1 \( -iname '*.ttf' -o -iname '*.otf' -o -iname '*.ttc' \) | wc -l)")"

# =============================================================================
# 7. environment.conf block (only keys not set yet)
# =============================================================================
section "environment.conf block"
BLK="$WORK/conf_block"
_set() {   # KEY VALUE COMMENT - only when not set in the target conf
    local k="$1" v="$2" c="${3:-}"
    [ -n "$v" ] || return 0
    if [ -f "$TCONF" ] && grep -qE "^[[:space:]]*(export[[:space:]]+)?$k=" "$TCONF"; then
        local cur="${!k:-}"
        if [ "$cur" = "$v" ]; then info "$(printf "  %-28s %s" "$k" "already set - same value")"
        else
            case "$k" in
                REPORTS_SERVER_INSTANCES|INSTALL_COMPONENTS|FORMS_WEBUTIL_JACOB)
                    warn "$(printf "  %-28s kept '%s' - customer: '%s' (the overlay needs the customer value - change it in %s)" "$k" "$cur" "$v" "$(basename "$TCONF")")" ;;
                *)  info "$(printf "  %-28s kept '%s' (customer: '%s')" "$k" "$cur" "$v")" ;;
            esac
        fi
        return 0
    fi
    printf '%s="%s"%s\n' "$k" "$v" "${c:+   # $c}" >> "$BLK"
}
{
    printf '\n# === CUSTOMER IMPORT %s (customer_conf_import.sh %s, export of %s) ===\n' "$(date '+%Y-%m-%d %H:%M')" "$VERSION" "$OLD_HOST"
    printf '# overlay + decisions: %s (IMPORT_DECISIONS.md)\n' "$OVL"
} > "$BLK"
_set CUSTOMER_CONF_DIR "$OVL"
_ic="FORMS"; [ -n "$RS_LIST" ] && { [ "$NSEC" -gt 0 ] && _ic="FORMS_AND_REPORTS" || _ic="REPORTS_ONLY"; }
_set INSTALL_COMPONENTS "$_ic" "from the export: $NSEC customer sections, servers: ${RS_LIST:-none}"
_set REPORTS_SERVER_INSTANCES "$RS_LIST" "standalone Reports servers of the export"
grep -qi 'jacob' "$STG/forms/formsweb.sections.cfg" "$STG/forms/formsweb.default.cfg" 2>/dev/null && _set FORMS_WEBUTIL_JACOB "true" "WebUtilArchive with jacob.jar"
_set NLS_LANG "$(_pv NLS_LANG)" "from the export (per env file / server: overlay)"
for k in WLS_ADMIN_PORT WLS_FORMS_PORT WLS_REPORTS_PORT WLS_NODEMANAGER_PORT; do _set "$k" "$(_pv $k)" "port of the old domain"; done
_set REPORTS_BROADCAST_PORT "$(_pv REPORTS_BROADCAST_PORT)" "old value - must be unique in the subnet"
_set WLS_SERVER_FQDN "$OLD_FQDN" "OLD public name - keep (DNS alias) or change before the installation"
_cl="$(awk -F';' 'NR>0 && $3+0 > m {m=$3; s=$2} END {print s}' "$X/load/forms_starts.csv" 2>/dev/null)"
[ -z "$_cl" ] && _cl="$(grep -m1 '^\[' "$STG/forms/formsweb.sections.cfg" | tr -d '[]')"
_set FORMS_CLIENT_CONFIG "$_cl" "section with the most application starts"
_set FORMS_CLIENT_FORM "$(awk -v s="[$_cl]" '$0==s {on=1; next} /^\[/ {on=0} on && /^form=/ {sub(/^form=/, ""); print; exit}' "$STG/forms/formsweb.sections.cfg")"
[ -n "$OLD_FMX" ] && dec PATH_MAPPED "FORMS_CUSTOMER_DIR" "$OLD_FMX" "##FORMS_CUSTOMER_DIR## (environment.conf, library default \$ORACLE_BASE/forms/moduls)" "the old module directory is mapped - keep the old path by setting FORMS_CUSTOMER_DIR=$OLD_FMX"
dec RCU_NEW "DB_* (RCU)" "$(_pv DB_HOST):$(_pv DB_PORT)/$(_pv DB_SERVICE) prefix $(_pv DB_SCHEMA_PREFIX)" "asked by 01-setup-interview.sh" "14c needs a new RCU repository (14.1.2 schemas)"
sed 's/^/  /' "$BLK" | tee -a "${LOG_FILE:-/dev/null}"

# =============================================================================
# 8. decisions, README, clear-text check
# =============================================================================
section "Decisions"
{
    printf '# Import decisions – %s\n\n' "$ENVNAME"
    printf 'Export of `%s` (export_forms_reports_conf.sh %s), imported %s with customer_conf_import.sh %s.\n\n' "$OLD_HOST" "$EXP_VER" "$(date '+%Y-%m-%d %H:%M')" "$VERSION"
    printf 'Every row: what the import changed against the customer configuration. Take a customer value back on purpose with\n'
    printf '`00-Setup/customer_conf_import.sh -i <export> --env %s --keep-customer <rule> --apply`, or edit the overlay file and re-run 13- / 14- / 14b-.\n\n' "$ENVNAME"
    printf '| Rule | File / key | Customer value | 14c value | Reason |\n|---|---|---|---|---|\n'
    sort -t';' -k1,1 -s "$DEC" | awk -F';' '{gsub(/\|/, "\\|"); printf "| %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5}'
    printf '\nRules: `customer_conf_import.sh --rules`. Never kept: %s.\n' "$NOKEEP"
} > "$STG/IMPORT_DECISIONS.md"
awk -F';' '{print $1}' "$DEC" | sort | uniq -c | while read -r n r; do info "$(printf "  %-18s %3s row(s)" "$r" "$n")"; done
# the whole decision table into the log (the log is what goes back for review)
{ printf '\n# --- IMPORT_DECISIONS (%s rows) ---\n' "$(wc -l < "$DEC")"; sort -t';' -k1,1 -s "$DEC"; printf '# --- end ---\n'; } >> "${LOG_FILE:-/dev/null}"
cat > "$STG/README.txt" <<EOF
Customer overlay of environment $ENVNAME - written by 00-Setup/customer_conf_import.sh $VERSION
Source: export of $OLD_HOST ($EXP_VER). CUSTOMER DATA - git-ignored, never commit.
  forms/formsweb.default.cfg    [default] keys             -> 09-Install/14- step 4
  forms/formsweb.sections.cfg   customer sections          -> 14- step 4
  forms/env/*.env               env file overlays          -> 14- step 3 (##PLACEHOLDER## = environment.conf value)
  forms/webutil.cfg.overrides   WebUtil keys               -> 14- step 2
  forms/jars/                   customer jars              -> 14- step 4b (signed)
  reports/<server>.env          <environment> per server   -> 13- step 5
  reports/cgicmd.dat.customer   customer keys              -> 14b- step 5
  fonts/                        customer fonts, uifont.ali -> 14b- / 04-ReportsFonts
  IMPORT_DECISIONS.md           what was changed and why
EOF
# second safety line: no clear-text secret in the overlay
cat "$STG"/forms/*.cfg "$STG"/forms/*.overrides "$STG"/forms/env/*.env "$STG"/reports/*.env "$STG"/reports/*.customer 2>/dev/null > "$WORK/check.txt"
cp "$STG/IMPORT_DECISIONS.md" "$WORK/check2.txt"
if ! ihwt_report_secret_check "$WORK/check.txt" || ! ihwt_report_secret_check "$WORK/check2.txt"; then
    fail "possible clear-text secret in the overlay - nothing written"; print_summary; exit 1
fi
ok "clear-text check of the overlay: no secret found"

section "Overlay"
(cd "$STG" && find . -type f -printf '%p %s\n' | sort | sed 's#^\./#  #') | tee -a "${LOG_FILE:-/dev/null}"
info "Log: ${LOG_FILE:-}"

# =============================================================================
# 9. apply
# =============================================================================
if ! $APPLY; then
    info "Dry run - nothing written. Write with --apply (decisions: $(wc -l < "$DEC") rows)"
    print_summary; exit "$EXIT_CODE"
fi
section "Apply"
if [ -d "$OVL" ]; then
    mv "$OVL" "$OVL.bak_$(date +%Y%m%d_%H%M%S)" && ok "old overlay saved: $OVL.bak_*"
fi
mkdir -p "$OVL" && cp -a "$STG/." "$OVL/" && chmod -R go-rwx "$OVL" && ok "overlay written: $OVL"
if [ -f "$TCONF" ]; then
    backup_file "$TCONF" >/dev/null && ok "backup of $TCONF"
fi
if grep -q '=' "$BLK"; then
    cat "$BLK" >> "$TCONF" && chmod 600 "$TCONF" && ok "import block appended to $TCONF"
else
    info "environment.conf: no new keys"
fi
info "Next: Way 1 - 09-Install/01-setup-interview.sh, then the install chain;"
info "      Way 2 - 07-Maintenance/backup_config.sh --apply, then 14- / 14b- / 13- --apply (apply_customer_conf.sh)"
print_summary
exit "$EXIT_CODE"
