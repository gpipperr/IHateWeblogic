#!/bin/bash
# =============================================================================
# Script   : ihw_tools_lib.sh
# Purpose  : Shared helpers of the standalone customer tools in
#            70-Customer-Projects/tools/bash (export_forms_reports_conf.sh,
#            collect_fmw_env.sh, status.sh, ...) and of the customer import
#            (00-Setup/customer_conf_import.sh). NOT the IHateWeblogic
#            library (00-Setup/IHateWeblogic_lib.sh) - no environment.conf,
#            no ok/warn/fail; plain bash + coreutils.
#            The road map (Start_beim_Kunden_kochbuch_de.txt step 1) copies all
#            tools/bash/*.sh, so this file always lies next to the tools.
# Use      : _d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#            . "$_d/ihw_tools_lib.sh" || { printf 'ihw_tools_lib.sh missing\n' >&2; exit 2; }
# Rules    : functions only - no top-level set -u / exit / output; prefix ihwt_
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================

IHWT_LIB_VERSION="2026-11-18.1"
ihwt_lib_version() { printf '%s' "$IHWT_LIB_VERSION"; }

# -----------------------------------------------------------------------------
# ihwt_mask - mask secrets in a text stream (stdin -> stdout)
#   collect_fmw_env.sh rules + <identifier>, name="..pass.." value=,
#   {AES}..., userid= / authid= / password=, -D...password=, user/pw@alias
# -----------------------------------------------------------------------------
ihwt_mask() {
    sed -E \
        -e 's/(<[^>/]*[Pp]ass[Ww]or[dD][^>]*>)[^<]*/\1***MASKED***/g' \
        -e 's/(<identifier[^>]*>)[^<]*/\1***MASKED***/g' \
        -e 's/(name="[^"]*([Pp]ass[Ww](or)?[dD]|pwd|PWD)[^"]*"[[:space:]]+value=")[^"]*/\1***MASKED***/g' \
        -e 's/\{AES(256)?\}[A-Za-z0-9+\/=]+/{AES}***MASKED***/g' \
        -e 's/((^|[[:space:];&?])(userid|USERID|UserId|authid|AUTHID|password|PASSWORD|Password|passwd|pwd|PWD|dbpassword)[[:space:]]*=[[:space:]]*)[^[:space:];&]+/\1***MASKED***/g' \
        -e 's/(-D[A-Za-z0-9._]*[Pp]ass[Ww]ord[A-Za-z0-9._]*=)[^[:space:]]+/\1***MASKED***/g' \
        -e 's#([A-Za-z0-9_]+)/[^@[:space:]/"]+@#\1/***MASKED***@#g'
}

# -----------------------------------------------------------------------------
# config file parsing
# -----------------------------------------------------------------------------
# ihwt_cfgval FILE KEY - values of KEY=... (all occurrences, without comments)
ihwt_cfgval() { sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" 2>/dev/null | sed 's/[[:space:]]*$//'; }

# ihwt_sections FILE - "section<TAB>key<TAB>value" of an ini-like file
ihwt_sections() {
    awk 'BEGIN{s=""} /^[[:space:]]*[#;]/{next}
         /^[[:space:]]*\[[^]]+\]/{s=$0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/,"",s); next}
         /=/{k=$0; sub(/=.*/,"",k); gsub(/[[:space:]]/,"",k); v=$0; sub(/^[^=]*=/,"",v); sub(/[[:space:]]+$/,"",v)
             if(k!="") print s "\t" k "\t" v}' "$1" 2>/dev/null
}

# ihwt_keys FILE - "key<TAB>value" of a key=value file (no sections)
ihwt_keys() {
    awk '/^[[:space:]]*[#;]/{next} /=/{k=$0; sub(/=.*/,"",k); gsub(/[[:space:]]/,"",k); v=$0; sub(/^[^=]*=/,"",v); sub(/[[:space:]]+$/,"",v); if(k!="") print k "\t" v}' "$1" 2>/dev/null
}

# -----------------------------------------------------------------------------
# ihwt_font_class FILE_NAME - "class;replacement" (04-ReportsFonts/README.md)
#   customer  own / bought fonts (barcode ...) - must move, no replacement
#   ms        Microsoft fonts (Windows / Office licence of the customer) - the
#             library uses free replacements; "identical" = same metrics
#   free      Liberation / DejaVu - OS packages, 14b- deploys them
# -----------------------------------------------------------------------------
ihwt_font_class() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        liberation*|dejavu*|carlito*|caladea*)        printf 'free;OS package (14b-)' ;;
        arialuni*|arial-unicode*|arial_unicode*)      printf 'ms;DejaVu Sans / Noto (similar – only needed for non-Latin text)' ;;
        arialn*)                                      printf 'ms;Liberation Sans Narrow (identical metrics)' ;;
        arial*|ariblk*)                               printf 'ms;Liberation Sans (identical metrics)' ;;
        times*)                                       printf 'ms;Liberation Serif (identical metrics)' ;;
        cour*)                                        printf 'ms;Liberation Mono (identical metrics)' ;;
        calibri*)                                     printf 'ms;Carlito (identical metrics)' ;;
        cambria*)                                     printf 'ms;Caladea (identical metrics) - not set up in 14c yet, see reports_fonts_architecture.md' ;;
        verdana*|tahoma*|trebuc*|segoe*|micross*)     printf 'ms;DejaVu Sans (similar – layout can shift)' ;;
        georgia*|pala*|book*|constan*)                printf 'ms;Liberation Serif (similar – layout can shift)' ;;
        consola*|lucon*)                              printf 'ms;Liberation Mono (similar)' ;;
        wingding*|webdings*|symbol*|marlett*)         printf 'ms;none – symbol font, original TTF needed' ;;
        candara*|corbel*|comic*|impact*|l_10646*|gara*|century*|gothic*|franklin*)
                                                      printf 'ms;DejaVu Sans / Liberation (similar – check)' ;;
        *)                                            printf 'customer;none – must move' ;;
    esac
}

# -----------------------------------------------------------------------------
# ihwt_git_guard DIR NAME - refuse to write customer data into a git work
# tree unless git ignores DIR/NAME. rc 0 = ok, 2 = refused (message on stderr)
# -----------------------------------------------------------------------------
ihwt_git_guard() {
    local dir="$1" name="$2" top
    command -v git >/dev/null 2>&1 || return 0
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 0
    if [ "$dir" = "$top" ]; then
        git -C "$top" check-ignore -q -- "$name" 2>/dev/null && return 0
    elif git -C "$top" check-ignore -q -- "${dir#"$top"/}/$name" 2>/dev/null; then
        return 0
    fi
    printf 'REFUSED: %s is inside the git work tree %s and not ignored –\n' "$dir" "$top" >&2
    printf '         it would contain customer data. Use a path outside git or an ignored path.\n' >&2
    return 2
}

# -----------------------------------------------------------------------------
# Archive encryption (export_forms_reports_conf.sh, collect_fmw_env.sh): ZIP (tar.gz without zip), openssl
# AES-256-CBC with PBKDF2 (200 000 iterations, SHA-256, salt). The passphrase
# is read hidden and handed to openssl via a file descriptor - never on a
# command line (ps / /proc/<pid>/cmdline), never written to a file.
# Decrypt by hand:  openssl enc -d $IHWT_ENC_OPTS -in <file>.zip.enc -out <file>.zip
# -----------------------------------------------------------------------------
IHWT_ENC_OPTS="-aes-256-cbc -pbkdf2 -iter 200000 -md sha256"

# ihwt_read_passphrase [WHAT] - ask twice (hidden), sets IHWT_PASS; rc 2 when
# there is no terminal or no openssl (the caller offers its no-encrypt option)
ihwt_read_passphrase() {
    local what="${1:-archive}" p2
    IHWT_PASS=""
    command -v openssl >/dev/null 2>&1 || { printf 'openssl missing - cannot encrypt the %s\n' "$what" >&2; return 2; }
    [ -t 0 ] || { printf 'Encryption needs a passphrase from a terminal (%s)\n' "$what" >&2; return 2; }
    while :; do
        read -r -s -p "  Passphrase for the $what: " IHWT_PASS; printf '\n'
        read -r -s -p "  Repeat passphrase               : " p2; printf '\n'
        [ -n "$IHWT_PASS" ] && [ "$IHWT_PASS" = "$p2" ] && break
        printf '  empty or not equal - again\n'
    done
    return 0
}

# ihwt_pack BASE NAME ENCRYPT - pack BASE/NAME into BASE/NAME.zip (or .tar.gz),
# with ENCRYPT=true into NAME.zip.enc using IHWT_PASS (cleared afterwards), plus
# a .sha256. Sets IHWT_ARCHIVE (file name below BASE). On an error every
# partial / unencrypted file is removed, rc 2.
ihwt_pack() {
    local base="$1" name="$2" enc="${3:-false}" a
    IHWT_ARCHIVE=""
    ( cd "$base" || exit 2
      if command -v zip >/dev/null 2>&1; then a="$name.zip"; zip -qr "$a" "$name" || { rm -f "$a"; exit 2; }
      else a="$name.tar.gz"; tar -czf "$a" "$name" || { rm -f "$a"; exit 2; }; fi
      printf '%s' "$a" > "$name.packed" ) || { printf 'packing failed\n' >&2; return 2; }
    a="$(cat "$base/$name.packed")"; rm -f "$base/$name.packed"
    if [ "$enc" = true ]; then
        # shellcheck disable=SC2086
        if ! openssl enc $IHWT_ENC_OPTS -salt -in "$base/$a" -out "$base/$a.enc" -pass fd:3 3<<<"$IHWT_PASS"; then
            IHWT_PASS=""; rm -f "$base/$a" "$base/$a.enc"
            printf 'encryption failed - unencrypted archive removed\n' >&2; return 2
        fi
        IHWT_PASS=""; rm -f "$base/$a"; a="$a.enc"
    fi
    ( cd "$base" && sha256sum "$a" > "$a.sha256" )
    IHWT_ARCHIVE="$a"
}

# ihwt_decrypt IN OUT - decrypt IN (.enc) into OUT; the passphrase is asked
# hidden (once). rc 2 on a wrong passphrase / no terminal (OUT removed).
ihwt_decrypt() {
    local in="$1" out="$2" pw
    [ -t 0 ] || { printf 'decryption needs a passphrase from a terminal\n' >&2; return 2; }
    read -r -s -p "  Passphrase of $(basename "$in"): " pw; printf '\n'
    # shellcheck disable=SC2086
    if ! openssl enc -d $IHWT_ENC_OPTS -in "$in" -out "$out" -pass fd:3 3<<<"$pw" 2>/dev/null; then
        pw=""; rm -f "$out"; printf 'decryption failed (wrong passphrase?)\n' >&2; return 2
    fi
    pw=""
}

# -----------------------------------------------------------------------------
# Web tier in front of WebLogic: Nginx, Apache httpd (+ WebLogic proxy plug-in
# mod_wl) and Oracle HTTP Server (OHS). Used by collect_fmw_env.sh,
# export_forms_reports_conf.sh and the customer import.
#   ihwt_webtier_find [DOMAIN_HOME ...]  -> "type;main_conf" (type nginx|apache|ohs)
#   ihwt_webtier_flatten TYPE MAIN       -> config with all includes inlined
#   ihwt_webtier_routes TYPE MAIN        -> routing rows (stdin = flattened config)
#   ihwt_webtier_settings TYPE MAIN      -> security-relevant directives (stdin)
# Read-only; what the caller cannot read is reported, never forced.
# -----------------------------------------------------------------------------
IHWT_WT_HEAD="type;conf;listen;server_name;tls;protocols;path;target;access;cert"

# ihwt_webtier_find [DOMAIN_HOME ...] - running processes first, then the
# default paths and the OHS components of the given domains (+ a bounded search
# for standalone OHS domains). One line per main configuration file.
ihwt_webtier_find() {
    local l bin conf root t d f
    {
        # running: nginx master / httpd (Apache or OHS) - ps shows the args of all users
        ps -eo args 2>/dev/null | while IFS= read -r l; do
            case "$l" in
                "nginx: master process "*)
                    l="${l#nginx: master process }"; bin="${l%% *}"
                    conf="$(printf '%s' "$l" | sed -n 's/.*[[:space:]]-c[[:space:]]\+\([^[:space:]]*\).*/\1/p')"
                    [ -z "$conf" ] && [ -x "$bin" ] && conf="$("$bin" -V 2>&1 | grep -o -- '--conf-path=[^[:space:]]*' | cut -d= -f2)"
                    printf 'nginx;%s\n' "${conf:-/etc/nginx/nginx.conf}" ;;
                */httpd\ *|*/httpd|*/httpd.worker*|*/httpd.event*|*/httpd.prefork*|*/apache2\ *|*/apache2|httpd\ *|apache2\ *)
                    bin="${l%% *}"
                    conf="$(printf '%s' "$l" | sed -n 's/.*[[:space:]]-f[[:space:]]\+\([^[:space:]]*\).*/\1/p')"
                    root="$(printf '%s' "$l" | sed -n 's/.*[[:space:]]-d[[:space:]]\+\([^[:space:]]*\).*/\1/p')"
                    t=apache
                    case "$l" in *OHS*|*/ohs/*) t=ohs ;; esac
                    if [ -z "$conf" ] && [ -n "$root" ]; then conf="$root/httpd.conf"
                    elif [ -z "$conf" ] && [ -x "$bin" ]; then
                        conf="$("$bin" -V 2>/dev/null | sed -n 's/.*SERVER_CONFIG_FILE="\([^"]*\)".*/\1/p')"
                        root="$("$bin" -V 2>/dev/null | sed -n 's/.*HTTPD_ROOT="\([^"]*\)".*/\1/p')"
                        case "$conf" in /*) ;; ?*) conf="$root/$conf" ;; esac
                    fi
                    # OHS runs from instances/<name> - the master copy is components/OHS/<name>
                    [ "$t" = ohs ] && conf="$(printf '%s' "$conf" | sed 's#/components/OHS/instances/\([^/]*\)/#/components/OHS/\1/#')"
                    [ -n "$conf" ] && printf '%s;%s\n' "$t" "$conf" ;;
            esac
        done
        # installed, maybe not running
        for f in /etc/nginx/nginx.conf /usr/local/nginx/conf/nginx.conf /opt/nginx/conf/nginx.conf; do
            [ -e "$f" ] && printf 'nginx;%s\n' "$f"
        done
        for f in /etc/httpd/conf/httpd.conf /etc/apache2/apache2.conf /usr/local/apache2/conf/httpd.conf \
                 /opt/apache*/conf/httpd.conf /opt/httpd*/conf/httpd.conf; do
            [ -e "$f" ] && printf 'apache;%s\n' "$f"
        done
        for d in "$@"; do
            for f in "$d"/config/fmwconfig/components/OHS/*/httpd.conf; do
                case "$f" in */instances/*) continue ;; esac
                [ -e "$f" ] && printf 'ohs;%s\n' "$f"
            done
        done
        # standalone OHS domains (separate web tier domain on the same host)
        for d in /u01 /u02 /oracle /opt /app; do
            [ -d "$d" ] || continue
            timeout 20 find "$d" -maxdepth 9 -path '*/config/fmwconfig/components/OHS/*/httpd.conf' \
                -not -path '*/instances/*' 2>/dev/null | sed 's/^/ohs;/'
        done
    } | while IFS=';' read -r t f; do
        [ -e "$f" ] || continue
        printf '%s;%s\n' "$t" "$(readlink -f "$f")"
    done | awk -F';' '!seen[$2]++'
}

# _ihwt_wt_flat TYPE FILE ROOT VARS DEPTH - recursive include expansion
_ihwt_wt_flat() {
    local type="$1" f="$2" root="$3" vars="$4" depth="$5" line inc p k v
    [ "$depth" -gt 8 ] && { printf '#@@ TOO_DEEP %s\n' "$f"; return; }
    if [ ! -r "$f" ]; then printf '#@@ UNREADABLE %s\n' "$f"; return; fi
    printf '#@@ FILE %s\n' "$f"
    while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\n' "$line"
        inc=""
        if [ "$type" = nginx ]; then
            [[ "$line" =~ ^[[:space:]]*include[[:space:]]+([^\;]+)\; ]] && inc="${BASH_REMATCH[1]}"
        else
            [[ "$line" =~ ^[[:space:]]*[Ii][Nn][Cc][Ll][Uu][Dd][Ee]([Oo][Pp][Tt][Ii][Oo][Nn][Aa][Ll])?[[:space:]]+\"?([^\"]+)\"? ]] && inc="${BASH_REMATCH[2]}"
        fi
        [ -n "$inc" ] || continue
        inc="${inc%"${inc##*[![:space:]]}"}"; inc="${inc//\"/}"; inc="${inc//\'/}"
        # ${VAR} of OHS / Apache (VARS = "NAME=value NAME=value")
        for p in $vars; do k="${p%%=*}"; v="${p#*=}"; inc="${inc//\$\{$k\}/$v}"; done
        inc="$(printf '%s' "$inc" | sed 's#/components/OHS/instances/\([^/]*\)/#/components/OHS/\1/#')"
        case "$inc" in *'${'*) printf '#@@ UNRESOLVED %s\n' "$inc"; continue ;; /*) ;; *) inc="$root/$inc" ;; esac
        case "$(basename "$inc")" in
            mime.types|*fastcgi_params|uwsgi_params|scgi_params|koi-*|win-utf) printf '#@@ SKIPPED %s\n' "$inc"; continue ;;
        esac
        local found=false
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            found=true
            [ -d "$p" ] && continue
            _ihwt_wt_flat "$type" "$p" "$root" "$vars" $((depth + 1))
        done < <(compgen -G "$inc" | sort)
        $found || printf '#@@ NOT_FOUND %s\n' "$inc"
    done < "$f"
    printf '#@@ END %s\n' "$f"
}

# ihwt_webtier_flatten TYPE MAIN - like "nginx -T" / "httpd -t -D DUMP_INCLUDES",
# but without needing the binary, root or a valid configuration. Markers:
# "#@@ FILE|END|UNREADABLE|NOT_FOUND|UNRESOLVED|SKIPPED <path>".
ihwt_webtier_flatten() {
    local type="$1" main="$2" root vars="" d n
    case "$type" in
        nginx) root="$(dirname "$main")" ;;
        ohs)   root="$(dirname "$main")"
               # components/OHS/<name>/httpd.conf: ORACLE_INSTANCE = domain home
               n="$(basename "$root")"; d="${root%/config/fmwconfig/components/OHS/*}"
               vars="ORACLE_INSTANCE=$d DOMAIN_HOME=$d COMPONENT_TYPE=OHS COMPONENT_NAME=$n" ;;
        *)     root="$(sed -n 's/^[[:space:]]*ServerRoot[[:space:]]\+"\?\([^"[:space:]]*\)"\?.*/\1/p' "$main" 2>/dev/null | head -1)"
               [ -d "$root" ] || root="$(dirname "$(dirname "$main")")" ;;
    esac
    _ihwt_wt_flat "$type" "$main" "$root" "$vars" 0
}

# ihwt_webtier_routes TYPE MAIN < flattened - one row per route ($IHWT_WT_HEAD):
#   listen     "addr:port" list of the server / virtual host
#   tls        yes / no
#   protocols  ssl_protocols / SSLProtocol (server, else global; "" = default)
#   path       location / Location / ProxyPass path / MatchExpression ("-" = none)
#   target     host:port (WebLogic) | upstream name(host:port,...) | redirect URL | static DIR | -
#   access     restricted (allow / deny / Require / Auth) | open
#   cert       certificate file (public part)
ihwt_webtier_routes() {
    local type="$1" main="$2"
    if [ "$type" = nginx ]; then
        sed -e '/^#@@/d' -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//' \
            -e 's/{/{\n/g' -e 's/}/\n}\n/g' -e 's/;/;\n/g' | awk -v conf="$main" '
        function trim(s) { gsub(/^[[:space:]]+|[[:space:];{]+$/, "", s); return s }
        function args(s) { s=trim(s); sub(/^[^[:space:]]+[[:space:]]*/, "", s); return s }
        { l=trim($0); if (l == "" && $0 !~ /}/) next; w=l; sub(/[[:space:]].*/, "", w) }
        /\{[[:space:]]*$/ { sp++; ctx[sp]=w; carg[sp]=args(l)
            if (w=="server" && ctx[sp-1]=="http") { ns++; sl[ns]=""; sn[ns]=""; stls[ns]="no"; spr[ns]=""; sacc[ns]=""; scert[ns]=""; srows[ns]=0; cur=ns }
            if (w=="location") { lp[sp]=carg[sp]; lt[sp]="-"; la[sp]="" }
            if (w=="upstream") up=carg[sp]
            next }
        /^}/ { if (ctx[sp]=="location" && cur) { r=++nr; rs[r]=cur; rp[r]=lp[sp]; rt[r]=lt[sp]; ra[r]=la[sp]; srows[cur]++ }
               if (ctx[sp]=="server") cur=0
               if (ctx[sp]=="upstream") up=""
               sp--; next }
        { a=args(l) }
        w=="ssl_protocols" { if (cur) spr[cur]=a; else gpr=a }
        w=="upstream" { next }
        ctx[sp]=="upstream" && w=="server" { u=a; sub(/[[:space:]].*/, "", u); ups[up]=(ups[up]=="" ? u : ups[up] "," u); next }
        !cur { next }
        w=="listen" { v=a; if (v ~ /(^|[[:space:]])ssl([[:space:]]|$)/) stls[cur]="yes"; sub(/[[:space:]].*/, "", v); if (v !~ /:/) v="*:" v; sl[cur]=(sl[cur]=="" ? v : sl[cur] "," v) }
        w=="ssl" && a ~ /^on/ { stls[cur]="yes" }
        w=="server_name" { sn[cur]=a; gsub(/[[:space:]]+/, ",", sn[cur]) }
        w=="ssl_certificate" { scert[cur]=a }
        (w=="allow" && a !~ /^all/) || (w=="deny" && a ~ /^all/) || (w=="auth_basic" && a !~ /^off/) || w=="auth_request" {
            if (ctx[sp]=="location") la[sp]="restricted"; else sacc[cur]="restricted" }
        ctx[sp]=="location" && w=="proxy_pass" { t=a; sub(/^[a-z]+:\/\//, "", t); h=t; sub(/\/.*/, "", h); lt[sp]=h; lpath[sp]=t }
        ctx[sp]=="location" && w=="return" && a ~ /^30[1278]/ { t=a; sub(/^[0-9]+[[:space:]]*/, "", t); lt[sp]="redirect " t }
        ctx[sp]=="location" && (w=="alias" || w=="root") && lt[sp]=="-" { lt[sp]="static " a }
        ctx[sp]=="server" && w=="return" && a ~ /^30[1278]/ { t=a; sub(/^[0-9]+[[:space:]]*/, "", t); sret[cur]="redirect " t }
        END { for (r=1; r<=nr; r++) { s=rs[r]; t=rt[r]; h=t
                  if (t !~ /^(redirect|static) / && t != "-" && t !~ /:/ && (t in ups)) t=t "(" ups[t] ")"
                  printf "nginx;%s;%s;%s;%s;%s;%s;%s;%s;%s\n", conf, sl[s], sn[s], stls[s], (spr[s]!="" ? spr[s] : gpr), rp[r], t,
                      (ra[r]!="" ? ra[r] : (sacc[s]!="" ? sacc[s] : "open")), scert[s] }
              for (s=1; s<=ns; s++) if (!srows[s])
                  printf "nginx;%s;%s;%s;%s;%s;-;%s;%s;%s\n", conf, sl[s], sn[s], stls[s], (spr[s]!="" ? spr[s] : gpr),
                      (sret[s]!="" ? sret[s] : "-"), (sacc[s]!="" ? sacc[s] : "open"), scert[s] }' | sed 's/[[:space:]]*;/;/g'
    else
        sed -e '/^#@@/d' -e 's/^[[:space:]]*#.*$//' | awk -v type="$type" -v conf="$main" '
        function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        function unq(s) { gsub(/"/, "", s); return s }
        # WebLogic target: Location -> VirtualHost -> global (IfModule weblogic_module)
        function wlt(h, p, c) { if (c != "") return c
            if (h == "" && p == "") { if (vh && vwc[vh] != "") return vwc[vh]; if (gwc != "") return gwc }
            if (h == "") h = (vh && vwh[vh] != "" ? vwh[vh] : gwh); if (p == "") p = (vh && vwp[vh] != "" ? vwp[vh] : gwp)
            return h ":" p }
        function row(path, target, acc) { nr++; rv[nr]=vh; rpth[nr]=path; rtg[nr]=target; racc[nr]=acc; if (vh) vrows[vh]++; else grows++ }
        { l=trim($0); if (l=="") next; w=tolower(l); sub(/[[:space:]].*/, "", w); a=l; sub(/^[^[:space:]]+[[:space:]]*/, "", a); a=trim(a) }
        w ~ /^<virtualhost/ { nv++; vh=nv; v=a; sub(/>$/, "", v); vl[vh]=v; gsub(/[[:space:]]+/, ",", vl[vh]); vt[vh]="no"; vpr[vh]=""; vn[vh]=""; vcert[vh]=""; next }
        w ~ /^<\/virtualhost/ { vh=0; next }
        w ~ /^<location(match)?$/ || w ~ /^<location(match)?>/ { inl=1; lpth=unq(a); sub(/>$/, "", lpth); lh=0; lwh=""; lwp=""; lwc=""; lacc="open"; lpx=""; next }
        w ~ /^<\/location/ { if (lh || lpx != "") row(lpth, (lpx != "" ? lpx : wlt(lwh, lwp, lwc)), lacc)
                             inl=0; next }
        w=="listen" { v=a; s="no"; if (v ~ /[[:space:]]https$/) s="yes"; sub(/[[:space:]].*/, "", v); if (v !~ /:/) v="*:" v; gl=(gl=="" ? v : gl "," v)
            if (s=="yes") { q=v; sub(/.*:/, "", q); hport[q]=1 }; next }
        w=="servername" { v=a; sub(/^https?:\/\//, "", v); sub(/:.*/, "", v); if (vh) vn[vh]=v; else gn=v; next }
        w=="serveralias" && vh { vn[vh]=vn[vh] "," a; gsub(/[[:space:]]+/, ",", vn[vh]); next }
        w=="sslengine" && tolower(a) ~ /^on/ { if (vh) vt[vh]="yes"; else gt="yes"; next }
        w=="sslprotocol" { if (vh) vpr[vh]=a; else gpr=a; next }
        w=="sslcertificatefile" || w=="sslwallet" { if (vh) vcert[vh]=unq(a); else gcert=unq(a); next }
        w=="sethandler" && tolower(a) ~ /weblogic-handler/ && inl { lh=1; next }
        w=="weblogichost" { if (inl) lwh=a; else if (vh) vwh[vh]=a; else gwh=a; next }
        w=="weblogicport" { if (inl) lwp=a; else if (vh) vwp[vh]=a; else gwp=a; next }
        w=="weblogiccluster" { if (inl) lwc=a; else if (vh) vwc[vh]=a; else gwc=a; next }
        (w=="require" && tolower(a) !~ /^all granted/) || w=="allow" || w=="deny" || w=="authtype" { if (inl) lacc="restricted"; next }
        w=="matchexpression" { m=a; sub(/[[:space:]].*/, "", m)
            row(m, wlt("", "", ""), "open"); next }
        w=="proxypass" { split(a, pp, /[[:space:]]+/); if (pp[2]=="!" ) next
            t=pp[2]; sub(/^[a-z]+:\/\//, "", t); sub(/\/.*/, "", t)
            if (inl) { lpx=t } else row(pp[1], t, "open"); next }
        w=="redirect" || w=="redirectmatch" || (w=="rewriterule" && a ~ /https:/) { if (vh) vred[vh]="redirect " a; else gred="redirect " a; next }
        # global <Location> / ProxyPass / MatchExpression apply to every
        # VirtualHost without own routes (Apache inheritance): those vhosts
        # get the global rows with their listen / tls / certificate, the
        # global rows keep only the listeners no vhost covers (and no
        # "Listen ... https" port)
        END { for (v=1; v<=nv; v++) if (!vrows[v] && grows) { inh[v]=1; n=split(vl[v], L, ","); for (i=1; i<=n; i++) { q=L[i]; sub(/.*:/, "", q); used[q]=1 } }
              n=split(gl, L, ","); glp=""; for (i=1; i<=n; i++) { q=L[i]; sub(/.*:/, "", q); if (!(q in used) && !(q in hport)) glp=(glp=="" ? L[i] : glp "," L[i]) }
              if (!nv) glp=gl
              for (r=1; r<=nr; r++) { v=rv[r]
                  if (!v && glp=="") continue
                  printf "%s;%s;%s;%s;%s;%s;%s;%s;%s;%s\n", type, conf, (v ? vl[v] : glp), (v ? (vn[v] != "" ? vn[v] : gn) : gn),
                      (v ? vt[v] : (gt != "" ? gt : "no")), (v && vpr[v] != "" ? vpr[v] : gpr), rpth[r], rtg[r], racc[r], (v && vcert[v] != "" ? vcert[v] : gcert) }
              for (v=1; v<=nv; v++) if (inh[v]) for (r=1; r<=nr; r++) if (!rv[r])
                  printf "%s;%s;%s;%s;%s;%s;%s;%s;%s;%s\n", type, conf, vl[v], (vn[v] != "" ? vn[v] : gn), vt[v], (vpr[v] != "" ? vpr[v] : gpr),
                      rpth[r], rtg[r], racc[r], (vcert[v] != "" ? vcert[v] : gcert)
              for (v=1; v<=nv; v++) if (!vrows[v] && !inh[v])
                  printf "%s;%s;%s;%s;%s;%s;-;%s;open;%s\n", type, conf, vl[v], (vn[v] != "" ? vn[v] : gn), vt[v], (vpr[v] != "" ? vpr[v] : gpr),
                      (vred[v] != "" ? vred[v] : "-"), (vcert[v] != "" ? vcert[v] : gcert)
              if (!nv && !grows) printf "%s;%s;%s;%s;%s;%s;-;%s;open;%s\n", type, conf, gl, gn, (gt != "" ? gt : "no"), gpr, (gred != "" ? gred : "-"), gcert }'
    fi | if [ "$type" = ohs ]; then
        # ${ORACLE_INSTANCE} ... of the OHS wallet / certificate paths
        local cd n d; cd="$(dirname "$main")"; n="$(basename "$cd")"; d="${cd%/config/fmwconfig/components/OHS/*}"
        sed -e "s#\${ORACLE_INSTANCE}#$d#g; s#\${DOMAIN_HOME}#$d#g; s#\${COMPONENT_TYPE}#OHS#g; s#\${COMPONENT_NAME}#$n#g" \
            -e 's#/components/OHS/instances/\([^/]*\)/#/components/OHS/\1/#g'
    else cat; fi | ihwt_mask
}

# ihwt_webtier_settings TYPE MAIN < flattened - "type;conf;key;value;file" of the
# directives the analysis rates (server_tokens, ServerTokens, ServerSignature,
# TraceEnable, DebugConfigInfo, autoindex, Options Indexes)
ihwt_webtier_settings() {
    awk -v type="$1" -v conf="$2" '
        /^#@@ FILE / { f=$0; sub(/^#@@ FILE /, "", f); stk[++n]=f; next }
        /^#@@ END /  { n--; next }
        /^[[:space:]]*#/ { next }
        { l=$0; gsub(/^[[:space:]]+|[[:space:];]+$/, "", l); w=l; sub(/[[:space:]].*/, "", w); a=l; sub(/^[^[:space:]]+[[:space:]]*/, "", a); lw=tolower(w) }
        lw ~ /^(server_tokens|servertokens|serversignature|traceenable|debugconfiginfo|autoindex|wlproxyssl|wlproxysslpassthrough)$/ { printf "%s;%s;%s;%s;%s\n", type, conf, w, a, stk[n] }
        lw=="options" && tolower(a) ~ /(^|[[:space:]])\+?indexes/ { printf "%s;%s;Options;%s;%s\n", type, conf, a, stk[n] }'
}

# -----------------------------------------------------------------------------
# Unpack + clear-text check (customer import, also used by our analysis)
# -----------------------------------------------------------------------------
# ihwt_unpack IN DIR - unpack an archive of the tools into DIR (.zip.enc asks
# the passphrase, .zip, .tar.gz); rc 2 on an error (DIR may be partly filled)
ihwt_unpack() {
    local in="$1" dir="$2"
    mkdir -p "$dir" || return 2
    case "$in" in
        *.enc)
            ihwt_decrypt "$in" "$dir/.archive.zip" || return 2
            unzip -q "$dir/.archive.zip" -d "$dir" || { rm -f "$dir/.archive.zip"; printf 'unzip failed\n' >&2; return 2; }
            rm -f "$dir/.archive.zip" ;;
        *.zip)    unzip -q "$in" -d "$dir" || { printf 'unzip failed\n' >&2; return 2; } ;;
        *.tar.gz) tar -xzf "$in" -C "$dir" || { printf 'tar failed\n' >&2; return 2; } ;;
        *) printf 'unknown archive format: %s\n' "$in" >&2; return 2 ;;
    esac
}

# ihwt_report_secret_check FILE - second safety line of every report: clear-text
# password / {AES} / <identifier> / user/pw@ patterns. On a hit FILE is DELETED,
# the lines (values cut) go to stderr, rc 1.
ihwt_report_secret_check() {
    local f="$1" hits
    hits="$(grep -nE '(password|passwd|pwd|userid|authid)[[:space:]]*=[[:space:]]*[^*%[:space:]<;|]' "$f" | grep -v '\*\*\*MASKED\*\*\*' ;
            grep -nE '\{AES(256)?\}[A-Za-z0-9+/]{8,}' "$f" ;
            grep -nE '<identifier[^>]*>[^<*][^<]*</identifier>' "$f" ;
            grep -nE '[A-Za-z0-9_]+/[^*@[:space:]/|;]+@[A-Za-z][A-Za-z0-9_.]*' "$f" | grep -vE '@//|https?://' )"
    [ -z "$hits" ] && return 0
    rm -f "$f"
    printf '  ERROR possible clear-text secret in the report - report deleted. Lines (values cut):\n' >&2
    printf '%s\n' "$hits" | cut -c1-60 | sed 's/^/    /' >&2
    return 1
}

# -----------------------------------------------------------------------------
# ihwt_ops_env TOOLS_DIR - values of the operation tools (status.sh, show_log.sh,
# show_errors.sh, show_all_logs.sh). patch_install.ini is optional:
#   1. IHW_INI=/path set by hand             explicit, wins over everything
#   2. domain selected with setdb            wins over patch_install.ini
#   3. patch_install.ini next to the tools   same domain as setdb / nothing selected
#   4. DOMAIN_HOME of the login              when there is no ini
# Values the ini does not give come from the domain (ihwt_ops_from_domain).
# Sets the ini variables + IHWT_OPS_SRC (for the header). Rc 2 + message on stderr
# when no domain is known. German messages like the tools.
# -----------------------------------------------------------------------------
ihwt_ops_env() {
    local tools_dir="$1" ini="" ini_dh="" sel="" use_ini=false

    case "${IHW_ENV_KEY:-}" in
        "FMW "*" -") ;;                     # setdb: home only
        "FMW "*) [ -n "${DOMAIN_HOME:-}" ] && sel="$DOMAIN_HOME" ;;
    esac
    if [ -n "${IHW_INI:-}" ]; then
        if [ ! -f "$IHW_INI" ]; then
            printf "FEHLER: IHW_INI=%s nicht gefunden\n" "$IHW_INI" >&2
            return 2
        fi
        ini="$IHW_INI"; use_ini=true; sel=""
    elif [ -f "$tools_dir/patch_install.ini" ]; then
        ini="$tools_dir/patch_install.ini"
        if [ -z "$sel" ]; then
            use_ini=true
        else
            # shellcheck source=/dev/null
            ini_dh="$(. "$ini" >/dev/null 2>&1; printf '%s' "${DOMAIN_HOME:-}")"
            if [ "$(readlink -f "$ini_dh" 2>/dev/null)" = "$(readlink -f "$sel" 2>/dev/null)" ]; then
                use_ini=true
            else
                printf "Hinweis: setdb-Domain %s, patch_install.ini hat %s - verwendet wird %s\n" "$sel" "${ini_dh:-?}" "$sel" >&2
            fi
        fi
    fi

    if $use_ini; then
        # shellcheck source=/dev/null
        . "$ini"
        [ -n "$sel" ] && DOMAIN_HOME="$sel"
        IHWT_OPS_SRC="$ini"
    else
        # nothing of another domain may survive (exports of set_script_env.sh)
        local _keep_extra="" _keep_min=""
        if [ -n "$ini" ]; then
            # shellcheck source=/dev/null
            _keep_extra="$(. "$ini" >/dev/null 2>&1; printf '%s' "${EXTRA_PORTS:-}")"
            # shellcheck source=/dev/null
            _keep_min="$(. "$ini" >/dev/null 2>&1; printf '%s' "${LOG_MINUTES:-}")"
        fi
        unset DOMAIN_NAME ADMIN_SERVER MANAGED_SERVERS REPORTS_SERVERS REPORTS_SERVER_NAME \
              WLS_ADMIN_PORT WLS_NODEMANAGER_PORT NM_HOST NM_TYPE WLST_CONFIG_FILE WLST_KEY_FILE
        [ -n "$_keep_extra" ] && EXTRA_PORTS="$_keep_extra"
        [ -n "$_keep_min" ] && LOG_MINUTES="$_keep_min"
        if [ -n "$sel" ]; then
            IHWT_OPS_SRC="setdb"
        elif [ -n "${DOMAIN_HOME:-}" ] && [ "${IHW_ENV_KEY:-}" = "" ]; then
            IHWT_OPS_SRC="Login-Umgebung"
        else
            printf "FEHLER: keine Domain bekannt.\n" >&2
            printf "  setdb         eine FMW-Domain waehlen (nicht \"home only\" / DB)\n" >&2
            printf "  oder          patch_install.ini neben die Tools legen (%s)\n" "$tools_dir" >&2
            return 2
        fi
    fi

    if [ ! -f "$DOMAIN_HOME/config/config.xml" ]; then
        printf "FEHLER: keine Domain unter DOMAIN_HOME=%s (config/config.xml fehlt) - Quelle: %s\n" "$DOMAIN_HOME" "$IHWT_OPS_SRC" >&2
        return 2
    fi
    ihwt_ops_from_domain
    return 0
}

# ihwt_ops_from_domain - fills what is still empty from config.xml and
# nodemanager.properties (same parsing as 09-Install/30-configure_autostart.sh)
ihwt_ops_from_domain() {
    local cfg="$DOMAIN_HOME/config/config.xml" nmp="$DOMAIN_HOME/nodemanager/nodemanager.properties" list v
    [ -n "${DOMAIN_NAME:-}" ] || DOMAIN_NAME="$(grep -m1 -o '<name>[^<]*</name>' "$cfg" | sed 's/<[^>]*>//g')"
    [ -n "${ADMIN_SERVER:-}" ] || ADMIN_SERVER="$(sed -n 's|.*<admin-server-name>\([^<]*\)</admin-server-name>.*|\1|p' "$cfg" | head -1)"
    ADMIN_SERVER="${ADMIN_SERVER:-AdminServer}"
    # name:port of every server; first <name> / <listen-port> outside <ssl> and
    # <network-access-point>; no <listen-port> = WebLogic's default 7001
    list="$(awk '
        /<server>[[:space:]]*$/ { s=1; n=""; p=""; skip=0; next }
        /<\/server>[[:space:]]*$/ { if (s && n != "" && tolower(n) != "template") print n ":" (p == "" ? "7001" : p); s=0; next }
        s && /<(ssl|network-access-point)>[[:space:]]*$/ { skip++; next }
        s && /<\/(ssl|network-access-point)>[[:space:]]*$/ { skip--; next }
        s && !skip && n == "" && /<name>/ { v=$0; gsub(/.*<name>|<\/name>.*/, "", v); n=v }
        s && !skip && p == "" && /<listen-port>/ { v=$0; gsub(/.*<listen-port>|<\/listen-port>.*/, "", v); p=v }
    ' "$cfg")"
    if [ -z "${WLS_ADMIN_PORT:-}" ]; then
        v="$(printf '%s\n' "$list" | sed -n "s/^${ADMIN_SERVER}://p" | head -1)"
        WLS_ADMIN_PORT="${v:-7001}"
    fi
    [ -n "${MANAGED_SERVERS:-}" ] || MANAGED_SERVERS="$(printf '%s\n' "$list" | grep -v "^${ADMIN_SERVER}:" | xargs)"
    [ -n "${REPORTS_SERVERS:-}" ] || REPORTS_SERVERS="$(awk '
        /<system-component>/ { c=1; n=""; t="" }
        c && /<name>/ && n == "" { n=$0; gsub(/.*<name>|<\/name>.*/, "", n) }
        c && /<component-type>/ { t=$0; gsub(/.*<component-type>|<\/component-type>.*/, "", t) }
        /<\/system-component>/ { if (t == "ReportsServerComponent") print n; c=0 }
    ' "$cfg" | xargs)"
    if [ -f "$nmp" ]; then
        [ -n "${WLS_NODEMANAGER_PORT:-}" ] || WLS_NODEMANAGER_PORT="$(sed -n 's/^ListenPort=//p' "$nmp" | tr -d ' \r' | head -1)"
        [ -n "${NM_HOST:-}" ] || NM_HOST="$(sed -n 's/^ListenAddress=//p' "$nmp" | tr -d ' \r' | head -1)"
        if [ -z "${NM_TYPE:-}" ]; then
            case "$(sed -n 's/^SecureListener=//p' "$nmp" | tr -d ' \r' | head -1)" in
                false) NM_TYPE="plain" ;;
                *)     NM_TYPE="ssl" ;;
            esac
        fi
    fi
    WLS_NODEMANAGER_PORT="${WLS_NODEMANAGER_PORT:-5556}"
    NM_HOST="${NM_HOST:-localhost}"
    NM_TYPE="${NM_TYPE:-plain}"
    # ORACLE_HOME for wlst.sh: from setdb / the ini / the login, else from the domain
    if [ -z "${ORACLE_HOME:-}" ]; then
        v="$(sed -n 's/^[[:space:]]*\(export \)\{0,1\}\(ORACLE_HOME\|MW_HOME\)="\{0,1\}\([^"$]*\)"\{0,1\}.*/\3/p' "$DOMAIN_HOME/bin/setDomainEnv.sh" 2>/dev/null | head -1)"
        [ -n "$v" ] && ORACLE_HOME="$v"
    fi
}

# =============================================================================
# Building blocks shared by collect_fmw_env.sh (installed / patch / Java / OS /
# performance / security) and export_forms_reports_conf.sh (configuration for
# the rebuild) - 2026-11-16: the load profile and the certificates moved from
# the export into the collector.
# =============================================================================

# ihwt_identity WIDTH OH DH - identification lines "KEY<pad>value" of a run
ihwt_identity() {
    local w="$1" oh="$2" dh="$3"
    printf "%-${w}s %s\n" Host "$(hostname -f 2>/dev/null || hostname)" \
        ORACLE_HOME "${oh:-(not found)}" DOMAIN_HOME "${dh:-(not found)}" \
        Platform "$(uname -sm 2>/dev/null)" \
        "FMW version" "$(grep -m1 -oE 'version="1[0-9.]+"' "$oh/inventory/registry.xml" 2>/dev/null)" \
        Java "$("$oh/oracle_common/jdk/bin/java" -version 2>&1 | head -1)" \
        CPUs "$(nproc 2>/dev/null)" \
        "RAM MB" "$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
}

# ihwt_rs_list DOMAIN_HOME - Reports servers of the domain, one line each:
#   name;type;rwserver.conf;rwnetwork.conf;dir
#   type standalone = system component; in-process = rwservlet with
#   <inprocess>yes; servlet = rwservlet configuration pointing to another server
ihwt_rs_list() {
    local dh="$1" cfg="$1/config/fmwconfig" n d srv inp names=()
    while IFS= read -r n; do [ -n "$n" ] && names+=("$n"); done < <(
        awk '/<system-component>/{n="";t=""} /<name>/&&n==""{n=$0; gsub(/.*<name>|<\/name>.*/,"",n)}
             /<component-type>ReportsServerComponent</{t="R"} /<\/system-component>/{if(t=="R")print n}' "$dh/config/config.xml" 2>/dev/null)
    for d in "$cfg"/components/ReportsServerComponent/*; do
        [ -d "$d" ] || continue; n="$(basename "$d")"; [ "$n" = mbeans ] && continue
        printf '%s\n' "${names[@]}" | grep -qx "$n" || names+=("$n")
    done
    for n in "${names[@]}"; do
        d="$cfg/components/ReportsServerComponent/$n"
        printf '%s;standalone;%s;%s;%s\n' "$n" "$d/rwserver.conf" "$d/rwnetwork.conf" "$d"
    done
    find "$cfg/servers" -maxdepth 4 -type d -path '*/applications/reports_*/configuration' 2>/dev/null | sort | while IFS= read -r d; do
        srv="$(sed -n 's:.*<server>\([^<]*\)</server>.*:\1:p' "$d/rwservlet.properties" 2>/dev/null | head -1)"
        inp="$(sed -n 's:.*<inprocess>\([^<]*\)</inprocess>.*:\1:p' "$d/rwservlet.properties" 2>/dev/null | head -1)"
        if [ "$inp" = yes ]; then printf '%s;in-process;%s;%s;%s\n' "${srv:-in-process}" "$d/rwserver.conf" "$d/rwnetwork.conf" "$d"
        else printf '%s;servlet;%s;%s;%s\n' "${srv:--}" "$d/rwserver.conf" "$d/rwnetwork.conf" "$d"; fi
    done
}
# ihwt_rs_running NAME - rc 0 when the Reports server NAME runs
ihwt_rs_running() { pgrep -f "rwserver.* server=$1( |$)" >/dev/null 2>&1; }

# ihwt_load_profile DOMAIN_HOME LOADDIR DAYS - AGGREGATED load counts of the
# last DAYS days into LOADDIR (no raw log line leaves the host: access logs
# hold client IPs, user names and - with GET report calls - even passwords).
# Reports admin for getserverinfo / showjobs of a secured server: IHWT_RWAUTH
# (user/password, set by the caller, cleared here). Read-only.
ihwt_load_profile() {
    local dh="$1" load="$2" days="$3" cut f rs code rport rwurl elf
    local -a fl rl
    mkdir -p "$load" || return 1
    cut="$(date -d "-$days days" +%Y-%m-%d)"
    _ihwt_lp_logs() { find "$dh"/servers/$1/logs -maxdepth 1 -type f -name 'access.log*' -mtime -"$days" 2>/dev/null | sort; }
    _ihwt_lp_cat()  { case "$1" in *.gz) zcat -- "$1" 2>/dev/null ;; *) cat -- "$1" 2>/dev/null ;; esac; }
    # ELF access log (WebLogic "extended", #Fields header) - field positions from the header
    elf='
        /^#Fields:/ { dI=tI=uI=sI=ttI=0; n=split($0,a,/[ \t]+/)
                      for (i=2;i<=n;i++) { f=a[i]; j=i-1
                          if (f=="date") dI=j; else if (f=="time") tI=j; else if (f=="cs-uri") uI=j
                          else if (f=="sc-status") sI=j; else if (f=="time-taken") ttI=j }
                      next }
        /^#/ || !dI || !uI { next }
        { d=$dI; h=substr($tI,1,2); u=$uI; st=$sI; if (d !~ /^[0-9][0-9][0-9][0-9]-/ || d < cut) next }'
    # --- Forms ---------------------------------------------------------------
    mapfile -t fl < <(_ihwt_lp_logs '*FORMS*')
    if [ ${#fl[@]} -gt 0 ]; then
        for f in "${fl[@]}"; do _ihwt_lp_cat "$f"; done | awk -v cut="$cut" "$elf"'
            u ~ /\/frmservlet/ && st ~ /^2/ { c="default"
                if (match(u, /[?&]config=[^&]+/)) { c=substr(u, RSTART+8, RLENGTH-8) }
                gsub(/[;\t ]/, "_", c); starts[d ";" c]++; hour[h]++ }
            u ~ /\/lservlet/ { ls[d]++ }
            { req[d]++; if (st ~ /^5/) e5[d]++; if (ttI && $ttI ~ /^[0-9.]+$/) { tt[d]+=$ttI; tn[d]++ } }
            END {
                for (k in starts) print k ";" starts[k] > "'"$load"'/forms_starts.csv"
                for (x in hour) print x ";" hour[x] > "'"$load"'/forms_hourly.csv"
                for (x in req) printf "%s;%d;%d;%d;%s\n", x, req[x], ls[x], e5[x], (tn[x] ? sprintf("%.0f", 1000*tt[x]/tn[x]) : "-") > "'"$load"'/forms_traffic.csv"
            }'
        printf '%s\n' "${fl[@]}" | sed "s#^$dh/#\$DOMAIN_HOME/#" > "$load/forms_logfiles.txt"
    fi
    # frmweb processes right now (concurrent sessions + pool)
    f="$(ps -C frmweb -o rss= 2>/dev/null)"
    printf 'frmweb_count=%s\nfrmweb_rss_avg_mb=%s\nfrmweb_rss_max_mb=%s\nfrmweb_rss_total_mb=%s\n' \
        "$(printf '%s\n' "$f" | grep -c '[0-9]')" \
        "$(printf '%s\n' "$f" | awk 'NF{s+=$1;n++} END{print (n?int(s/n/1024):0)}')" \
        "$(printf '%s\n' "$f" | awk 'NF&&$1>m{m=$1} END{print int(m/1024)}')" \
        "$(printf '%s\n' "$f" | awk 'NF{s+=$1} END{print int(s/1024)}')" > "$load/now.txt"
    # --- Reports: servlet requests per day and command --------------------------
    mapfile -t rl < <(_ihwt_lp_logs '*REPORTS*')
    if [ ${#rl[@]} -gt 0 ]; then
        for f in "${rl[@]}"; do _ihwt_lp_cat "$f"; done | awk -v cut="$cut" "$elf"'
            u ~ /\/rwservlet/ { c=u; sub(/^.*\/rwservlet\/?/, "", c); sub(/[?;].*$/, "", c); if (c=="") c="(report run)"
                gsub(/[0-9]+$/, "", c); k=d ";" c; r[k]++; if (st ~ /^5/) e[k]++ }
            END { for (k in r) printf "%s;%d;%d\n", k, r[k], e[k] > "'"$load"'/reports_requests.csv" }'
    fi
    printf 'rwengine_count=%s\n' "$(pgrep -fc 'RWEngine|rwEng-[0-9]' 2>/dev/null)" >> "$load/now.txt"
    # --- Reports: getserverinfo + past jobs of every RUNNING server --------------
    # (a not running in-process server is NOT asked - the request would start it)
    rport="$(awk '/<server>/{s=1;n="";p=""} s&&/<name>/&&n==""{n=$0; gsub(/.*<name>|<\/name>.*/,"",n)} s&&/<listen-port>/{p=$0; gsub(/.*<listen-port>|<\/listen-port>.*/,"",p)}
                   /<\/server>/{ if (s && n ~ /REPORTS/ && p != "") { print p; exit } s=0 }' "$dh/config/config.xml" 2>/dev/null)"
    rwurl="http://127.0.0.1:${rport:-9002}/reports/rwservlet"
    # _ihwt_rw CMD SERVER OUTFILE [extra data] - POST, authid only via curl config on stdin
    _ihwt_rw() {
        { printf 'url = "%s/%s"\n' "$rwurl" "$1"
          printf 'data = "server=%s&statusformat=XML%s"\n' "$2" "${4:+&$4}"
          [ -n "${IHWT_RWAUTH:-}" ] && printf 'data-urlencode = "authid=%s"\n' "$IHWT_RWAUTH"
        } | curl -s -m 60 -K - -o "$3" -w '%{http_code}' 2>/dev/null
    }
    if command -v curl >/dev/null 2>&1; then
        ihwt_rs_list "$dh" | awk -F';' '$2!="servlet" {print $1}' | sort -u | while read -r rs; do
            ihwt_rs_running "$rs" || continue
            code="$(_ihwt_rw getserverinfo "$rs" "$load/reports_${rs}_serverinfo.xml")"
            if ! grep -q '<serverInfo' "$load/reports_${rs}_serverinfo.xml" 2>/dev/null; then
                printf '%s;getserverinfo;HTTP %s - no serverInfo (secured server: --rw-auth USER)\n' "$rs" "$code" >> "$load/reports_not_collected.txt"
                rm -f "$load/reports_${rs}_serverinfo.xml"; continue
            fi
            _ihwt_rw showjobs "$rs" "$load/.sj.xml" "queuetype=past&count=1000" >/dev/null
            # one line per past job: server;id;report;status;started_epoch;seconds (no owner, no parameters)
            tr '\n' ' ' < "$load/.sj.xml" | sed 's/<job /\n<job /g' | awk -v s="$rs" '
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
                    printf "%s;%s;%s;%s;%s;%s;%s;%s\n", s, id, n, c, st, ((st != "" && fi != "") ? fi - st : ""), sr, fr }' >> "$load/reports_jobs.csv"
            rm -f "$load/.sj.xml"
        done
    else
        printf 'all;-;curl missing\n' >> "$load/reports_not_collected.txt"
    fi
    IHWT_RWAUTH=""
    # --- host: sar history (sysstat) + now --------------------------------------
    if command -v sar >/dev/null 2>&1; then
        for f in $(find /var/log/sa -maxdepth 1 -name 'sa[0-9][0-9]' -mtime -"$days" 2>/dev/null | sort); do
            local d cpu mem cpm
            d="$(LC_ALL=C sar -f "$f" 2>/dev/null | head -1 | grep -oE '[0-9]{2}/[0-9]{2}/[0-9]{2,4}' | head -1 | awk -F/ '{y=$3; if (length(y)==2) y="20" y; print y "-" $1 "-" $2}')"
            cpu="$(LC_ALL=C sar -u -f "$f" 2>/dev/null | awk '$1 ~ /^[0-9]/ && $NF ~ /^[0-9.]+$/ {s+=100-$NF; n++} END {if (n) printf "%.0f", s/n}')"
            # memory in use = 100 - available / total (like "available" of free):
            # %memused counts the page cache with sysstat < 12 (OL8 11.7: 98 %
            # on a host with 2/3 available), total = kbmemused * 100 / %memused
            # works with every version; without kbavail (sysstat 10) %memused
            mem="$(LC_ALL=C sar -r -f "$f" 2>/dev/null | awk '/%memused/ {for (i=1;i<=NF;i++) {if ($i=="%memused") c=i; if ($i=="kbmemused") u=i; if ($i=="kbavail") a=i}}
                /^Average/ && c && $c ~ /^[0-9.]+$/ && $c+0 <= 100 {
                    if (a && u && $c+0 > 0 && $u+0 > 0) { t=$u*100/$c; p=100-$a*100/t; if (p<0) p=0; printf "%.0f", p }
                    else printf "%.0f", $c
                    exit }')"
            cpm="$(LC_ALL=C sar -u -f "$f" 2>/dev/null | awk '$1 ~ /^[0-9]/ && $NF ~ /^[0-9.]+$/ {b=100-$NF; if (b>m) m=b} END {printf "%.0f", m}')"
            [ -n "$d" ] && printf '%s;%s;%s;%s\n' "$d" "${cpu:--}" "${cpm:--}" "${mem:--}"
        done > "$load/host_sar.csv"
    fi
    { printf 'uptime=%s\n' "$(uptime -p 2>/dev/null)"
      printf 'loadavg=%s\n' "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
      printf 'load_days=%s\n' "$days"; } >> "$load/now.txt"
    unset -f _ihwt_lp_logs _ihwt_lp_cat _ihwt_rw
}

# ihwt_certificates < routes - public part only of every HTTPS listener of the
# routing table ($IHWT_WT_HEAD rows on stdin): s_client with the server name,
# else the certificate file of the route. Output (no header)
#   "source;subject;issuer;not_after;san;key;sig;chain"
#   san   DNS names / IPs of subjectAltName, comma separated
#   key   "RSA 2048" / "EC 256" ...      sig  signature algorithm (openssl name)
#   chain number of certificates the server sends (leaf + intermediates), "file"
# The first four columns are the old format (2026-11-16.6 and older).
_ihwt_cert_details() {   # PEM (leaf) on stdin -> "subject;issuer;not_after;san;key;sig"
    local p t
    p="$(cat)"; [ -n "$p" ] || return 1
    t="$(printf '%s\n' "$p" | openssl x509 -noout -text 2>/dev/null)" || return 1
    printf '%s;%s;%s;%s;%s;%s\n' \
        "$(printf '%s\n' "$p" | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject= *//' | tr ';' ',')" \
        "$(printf '%s\n' "$p" | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer= *//' | tr ';' ',')" \
        "$(printf '%s\n' "$p" | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')" \
        "$(printf '%s\n' "$t" | awk '/X509v3 Subject Alternative Name/ {getline; print; exit}' | sed 's/^[[:space:]]*//; s/DNS://g; s/IP Address://g; s/[[:space:]]//g' | tr ';' ',')" \
        "$(printf '%s\n' "$t" | awk '/Public Key Algorithm:/ {a=$NF} /Public-Key: \(/ {b=$0; gsub(/.*\(| bit.*/, "", b)} END {
              if (a=="rsaEncryption") a="RSA"; else if (a=="id-ecPublicKey") a="EC"; else if (a=="rsassaPss") a="RSA-PSS"
              printf "%s %s", a, b}')" \
        "$(printf '%s\n' "$t" | awk '/Signature Algorithm:/ {print $NF; exit}')"
}
ihwt_certificates() {
    command -v openssl >/dev/null 2>&1 || return 0
    awk -F';' '$5=="yes" { n=split($3, L, ","); sn=$4; sub(/,.*/, "", sn)
                for (i=1; i<=n; i++) if (L[i] !~ /^\[/ || L[i] ~ /^\[::\]:/) print $1 ";" L[i] ";" sn ";" $10 }' \
        | awk -F';' '{ p=$2; sub(/.*:/, "", p) } !seen[$1 ";" p ";" $3]++' \
        | while IFS=';' read -r _t _l _sn _cf; do
        local _h="${_l%:*}" _p="${_l##*:}" _src _sc _d _n
        case "$_h" in '*'|0.0.0.0|'[::]'|'') _h=127.0.0.1 ;; esac
        case "$_sn" in ''|_|'*'*|localhost) _sn="$(hostname -f 2>/dev/null || hostname)" ;; esac
        _src="https $_t $_l ($_sn)"
        _sc="$(timeout 10 openssl s_client -connect "$_h:$_p" -servername "$_sn" -showcerts </dev/null 2>/dev/null)"
        _n="$(printf '%s\n' "$_sc" | grep -c 'BEGIN CERTIFICATE')"
        _d="$(printf '%s\n' "$_sc" | awk '/BEGIN CERTIFICATE/ {on=1} on {print} /END CERTIFICATE/ {exit}' | _ihwt_cert_details)"
        if [ -z "$_d" ] && [ -f "$_cf" ] && [ -r "$_cf" ]; then
            _d="$(awk '/BEGIN CERTIFICATE/ {on=1} on {print} /END CERTIFICATE/ {exit}' "$_cf" | _ihwt_cert_details)"; _src="https $_t $_l (file $_cf)"; _n="file"
        fi
        if [ -n "$_d" ]; then
            printf '%s;%s;%s\n' "$_src" "$_d" "$_n"
        else
            printf '%s;-;-;not reachable / no readable certificate file;-;-;-;-\n' "$_src"
        fi
    done
}

# ihwt_os_advisories - open OS security advisories from the dnf CACHE (no
# network, works as a normal user when the cache is readable). Prints
#   "N advisories (C critical/important, P packages)" or "not available (...)"
# and writes the list to stdout of IHWT_ADV_LIST when that variable names a file.
ihwt_os_advisories() {
    local l
    command -v dnf >/dev/null 2>&1 || { printf 'not available (no dnf)'; return 0; }
    if ! l="$(timeout 60 dnf -q --cacheonly updateinfo list --security 2>/dev/null)"; then
        printf 'not available (no readable dnf cache)'; return 0
    fi
    [ -n "${IHWT_ADV_LIST:-}" ] && printf '%s\n' "$l" > "$IHWT_ADV_LIST"
    printf '%s\n' "$l" | awk 'NF>=3 { a[$1]=1; p[$NF]=1; if ($2 ~ /^(Critical|Important)/) c[$1]=1 }
        END { printf "%d advisories (%d critical/important, %d packages)", length(a), length(c), length(p) }'
}
# ihwt_dnf_cache_age - age of the dnf metadata cache in days ("-" if none)
ihwt_dnf_cache_age() {
    local f
    f="$(find /var/cache/dnf "$HOME/.cache/dnf" -maxdepth 3 \( -name 'repomd.xml' -o -name '*.solv' \) -printf '%T@\n' 2>/dev/null | sort -n | tail -1)"
    [ -n "$f" ] && printf '%s' $(( ( $(date +%s) - ${f%.*} ) / 86400 )) || printf '-'
}

# ihwt_epoch_of_pid PID - start time of a process as epoch (readable without root)
ihwt_epoch_of_pid() { local t; t="$(ps -o lstart= -p "$1" 2>/dev/null)"; [ -n "$t" ] && date -d "$t" +%s 2>/dev/null; }

# ihwt_nginx_patch [ADVISORY_LIST] - patch facts of the Nginx of this host
# (the library builds on Nginx in front of WebLogic), one "key;value" per line.
# Read-only, no root, no network (dnf cache only). ADVISORY_LIST = output of
# "dnf updateinfo list --security" (ihwt_os_advisories, IHWT_ADV_LIST).
ihwt_nginx_patch() {
    local adv="${1:-}" bin v pk inst ven repo stream upd mpid mst ossl_inst
    bin="$(command -v nginx 2>/dev/null || { [ -x /usr/sbin/nginx ] && printf /usr/sbin/nginx; })"
    mpid="$(pgrep -f 'nginx: master process' 2>/dev/null | head -1)"
    if [ -z "$bin" ] && [ -z "$mpid" ]; then printf 'installed;no\n'; return 0; fi
    printf 'installed;yes\nbinary;%s\n' "${bin:-(not in PATH)}"
    if [ -n "$bin" ]; then
        v="$("$bin" -V 2>&1)"
        printf 'version;%s\n' "$(printf '%s\n' "$v" | sed -n 's#^nginx version: nginx/##p')"
        printf 'openssl;%s\n' "$(printf '%s\n' "$v" | sed -n 's/^built with //p')"
        printf 'dynamic_modules_dir;%s\n' "$(printf '%s\n' "$v" | grep -oE -- '--modules-path=[^ ]+' | cut -d= -f2)"
    fi
    pk="$(rpm -qf --qf '%{NAME} %{VERSION}-%{RELEASE}\n' "${bin:-/usr/sbin/nginx}" 2>/dev/null | head -1)"
    case "$pk" in
        ""|*"not owned"*)
            printf 'package;none (built / copied by hand - no patches through dnf)\norigin;own build\n' ;;
        *)  inst="$(rpm -q --qf '%{INSTALLTIME}' "${pk%% *}" 2>/dev/null)"
            ven="$(rpm -q --qf '%{VENDOR}' "${pk%% *}" 2>/dev/null)"
            repo="$(timeout 30 dnf -q --cacheonly info --installed "${pk%% *}" 2>/dev/null | sed -n 's/^From repo *: *//p' | head -1)"
            printf 'package;%s\npackage_installed;%s\n' "$pk" "$(date -d "@$inst" '+%Y-%m-%d %H:%M' 2>/dev/null)"
            case "$ven$repo" in
                *nginx*|*Nginx*|*F5*) printf 'origin;nginx.org repository (%s)\n' "${repo:-$ven}" ;;
                *) printf 'origin;OS repository (%s, %s)\n' "${repo:-?}" "${ven:-?}" ;;
            esac
            stream="$(timeout 30 dnf -q --cacheonly module list --installed nginx 2>/dev/null | awk '$1=="nginx" {print $2; exit}')"
            printf 'module_stream;%s\n' "${stream:-none (default version of the OS release)}"
            upd="$(timeout 60 dnf -q --cacheonly list --upgrades 'nginx*' 2>/dev/null | awk 'NF==3 && $1 ~ /^nginx/ {print $1 " " $2}' | paste -sd, -)"
            printf 'update_available;%s\n' "${upd:-none (dnf cache)}"
            printf 'modules_installed;%s\n' "$(rpm -qa --qf '%{NAME} ' 'nginx-mod-*' 2>/dev/null)"
            ;;
    esac
    if [ -n "$adv" ] && [ -f "$adv" ]; then
        printf 'advisories_nginx;%s\n' "$(awk '$NF ~ /^nginx/ {a[$1]=$2} END {for (k in a) printf "%s(%s) ", k, a[k]}' "$adv")"
        printf 'advisories_openssl;%s\n' "$(awk '$NF ~ /^openssl/ {a[$1]=$2} END {for (k in a) printf "%s(%s) ", k, a[k]}' "$adv")"
    fi
    if [ -n "$mpid" ]; then
        mst="$(ihwt_epoch_of_pid "$mpid")"
        printf 'master_pid;%s\nmaster_started;%s\n' "$mpid" "$(date -d "@$mst" '+%Y-%m-%d %H:%M' 2>/dev/null)"
        ossl_inst="$(rpm -q --qf '%{INSTALLTIME}' openssl-libs 2>/dev/null)"
        if [ -n "$inst" ] && [ -n "$mst" ] && [ "$mst" -lt "$inst" ]; then
            printf 'restart_pending;yes (nginx package newer than the running master)\n'
        elif [ -n "$ossl_inst" ] && [ -n "$mst" ] && [ "$ossl_inst" -gt "$mst" ] 2>/dev/null; then
            printf 'restart_pending;yes (openssl-libs newer than the running master)\n'
        else
            printf 'restart_pending;no\n'
        fi
    else
        printf 'master_pid;not running\n'
    fi
}

# -----------------------------------------------------------------------------
# Licence indicators (80-FMW-Architecture/fmw_forms_reports_licence.md) - NO
# licence statement, only what the configuration shows.
# ihwt_wls_basic DH OH - the WebLogic Server Basic restrictions that are
#   visible OFFLINE in config.xml / config/jdbc / config/jms (the checks of MOS
#   note 885587.1 that need no running server), plus every application and
#   library of the domain. Lines (same in ihw_tools_lib.ps1):
#     context;<key>;<value>
#     deployment;<name>;<module-type>;<deployment-order|->;<targets>;<in_oracle_home yes|no>
#     library;<name>;<targets>;<in_oracle_home yes|no>
#     indicator;<key>;<object>;<value>      (only when the feature is configured)
# -----------------------------------------------------------------------------
ihwt_wls_basic() {
    local dh="$1" oh="${2:-}" c="$1/config/config.xml" f
    [ -f "$c" ] || return 0
    awk -v oh="$oh" -v dh="$dh" '
        function tagof(l,  t) { t = l; sub(/^[ \t]*<\/?/, "", t); sub(/[ \t>\/].*$/, "", t); sub(/^[A-Za-z0-9_]+:/, "", t); return t }
        function inoh(p) { if (p == "") return "-"; if (p !~ /^\//) return "yes (relative)"; return (oh != "" && index(p, oh "/") == 1) ? "yes" : "no" }
        { sub(/\r$/, "") }
        # leaf <x>value</x>
        /^[ \t]*<[A-Za-z][^>]*>[^<]*<\/[^>]+>[ \t]*$/ {
            t = tagof($0); v = $0; sub(/^[ \t]*<[^>]*>/, "", v); sub(/<\/[^>]*>[ \t]*$/, "", v)
            p = ""; for (i = 2; i <= d; i++) p = p (p == "" ? "" : "/") S[i]
            if (t == "name" && !(d in N)) N[d] = v
            if (p == "") {
                if (t == "production-mode-enabled") prod = v
                if (t == "administration-port-enabled") aport = v
                if (t == "cluster-constraints-enabled" && v == "true") print "indicator;cluster_constraints;domain;true"
            }
            if (p == "security-configuration/secure-mode" && t == "secure-mode-enabled") smode = v
            if (p == "app-deployment" || p == "library") { if (t == "module-type") mt = v; if (t == "deployment-order") ord = v; if (t == "target") tg = v; if (t == "source-path") sp = v }
            if (p == "server") {
                if (t == "startup-mode" && (toupper(v) == "ADMIN" || toupper(v) == "STANDBY")) SI["server_startup_mode"] = toupper(v)
                if (t == "auto-migration-enabled" && v == "true") SI["auto_migration"] = "true"
            }
            if (p == "cluster") {
                if (t == "cluster-type" && (v == "man" || v == "wan")) SI["cluster_type"] = v
                if (t == "migration-basis" && v == "consensus") SI["migration_basis"] = v
            }
            if ((p == "server/overload-protection" || p == "cluster/overload-protection") && (t == "failure-action" || t == "panic-action") && v != "no-action") OV = OV (OV == "" ? "" : " ") t "=" v
            if (p == "migratable-target" && t == "migration-policy" && v != "manual") SI["migration_policy"] = v
            if (p == "self-tuning/work-manager" && t == "name") print "indicator;global_work_manager;" v ";-"
            if (p == "snmp-agent" && t == "enabled" && v == "true") print "indicator;snmp_agent;domain;enabled"
            next
        }
        # empty element / processing instruction / comment
        /^[ \t]*<[A-Za-z][^>]*\/>[ \t]*$/ || /^[ \t]*<[?!]/ { next }
        # closing tag
        /^[ \t]*<\/[^>]+>/ {
            t = tagof($0); nm = (d in N) ? N[d] : "-"
            p = ""; for (i = 2; i < d; i++) p = p (p == "" ? "" : "/") S[i]
            if (p == "" && t == "app-deployment") {
                print "deployment;" nm ";" (mt == "" ? "-" : mt) ";" (ord == "" ? "-" : ord) ";" (tg == "" ? "-" : tg) ";" inoh(sp)
                if (mt == "jdbc" || mt == "jms" || mt == "wldf") print "indicator;module_deployment;" nm ";" mt
            }
            if (p == "" && t == "library") {
                print "library;" nm ";" (tg == "" ? "-" : tg) ";" inoh(sp)
                if (tolower(nm) ~ /^pubsub/) print "indicator;http_pubsub;" nm ";-"
            }
            if (p == "" && (t == "server" || t == "cluster" || t == "migratable-target")) {
                for (k in SI) print "indicator;" k ";" nm ";" SI[k]
                if (OV != "") print "indicator;overload_protection;" nm ";" OV
                delete SI; OV = ""
            }
            if (p == "" && t == "singleton-service") print "indicator;singleton_service;" nm ";-"
            if (p == "" && t == "saf-agent") print "indicator;saf_agent;" nm ";-"
            if (p == "" && t == "wtc-server") print "indicator;wtc_server;" nm ";-"
            if (p == "" && t == "snmp-agent-deployment") print "indicator;snmp_agent;" nm ";deployment"
            if (p == "" && t == "wldf-system-resource" && nm !~ /^Module-FMWDFW/) print "indicator;wldf_resource;" nm ";-"
            if (p == "" && (t == "app-deployment" || t == "library")) { mt = ""; ord = ""; tg = ""; sp = "" }
            delete N[d]; d--
            next
        }
        # opening tag
        /^[ \t]*<[A-Za-z][^>]*>[ \t]*$/ { d++; S[d] = tagof($0); delete N[d]; next }
        END {
            print "context;production_mode;" (prod == "" ? "not set" : prod)
            print "context;secure_mode;" (smode == "" ? "not set" : smode)
            print "context;admin_port_domain;" (aport == "" ? "not set" : aport)
            if (aport == "true") print "indicator;admin_port_domain;domain;true"
        }' "$c"
    # data sources with Active GridLink (FAN / ONS) - JDBC system modules
    for f in "$dh"/config/jdbc/*-jdbc.xml; do
        [ -f "$f" ] || continue
        if grep -qE '<fan-enabled>true</fan-enabled>|<ons-node-list>[^<]+</ons-node-list>|<active-gridlink>true' "$f"; then
            printf 'indicator;active_gridlink;%s;fan / ons\n' "$(basename "$f")"
        fi
    done
    # JMS system modules: Unit-of-Order / Unit-of-Work other than the default
    for f in "$dh"/config/jms/*.xml; do
        [ -f "$f" ] || continue
        grep -qE '<default-unit-of-order>[^<]*</default-unit-of-order>' "$f" && \
            ! grep -qE '<default-unit-of-order>None</default-unit-of-order>' "$f" && printf 'indicator;jms_unit_of_order;%s;-\n' "$(basename "$f")"
        grep -qE '<unit-of-work-handling-policy>' "$f" && ! grep -qE '<unit-of-work-handling-policy>PassThrough<' "$f" && \
            printf 'indicator;jms_unit_of_work;%s;-\n' "$(basename "$f")"
    done
    return 0
}

# ihwt_db_edition DB_HOME - edition chosen at the installation (EE, SE2, SE,
#   SEONE ...) from inventory/globalvariables/oracle.server/globalvariables.xml
#   (oracle_install_db_InstallEdition, 11g - 19c checked); empty = no DB home
ihwt_db_edition() {
    sed -n 's/.*NAME="oracle_install_db_InstallEdition"[^>]*VALUE="\([^"]*\)".*/\1/p' \
        "$1/inventory/globalvariables/oracle.server/globalvariables.xml" 2>/dev/null | head -1
}

# ihwt_cloud - public cloud of this host from the DMI data (readable without
#   root, same markers as cloud-init): oci (chassis asset tag OracleCloud.com,
#   VM and bare metal), azure (chassis asset tag 7783-7084-3265-9085-8269-3286-77),
#   aws (vendor / BIOS "Amazon EC2" / amazon), gcp (product "Google Compute
#   Engine") - else none. Cloud licence rules differ from the on-premises
#   processor count (Core Factor Table "Important Notes", cloud licensing policy)
ihwt_cloud() {
    local d="${IHWT_DMI_DIR:-/sys/class/dmi/id}" at sv pr bv   # IHWT_DMI_DIR: tests only
    at="$(cat "$d/chassis_asset_tag" 2>/dev/null)"; sv="$(cat "$d/sys_vendor" 2>/dev/null)"
    pr="$(cat "$d/product_name" 2>/dev/null)"; bv="$(cat "$d/bios_version" "$d/bios_vendor" 2>/dev/null | paste -sd' ' -)"
    case "$at" in
        *OracleCloud*) printf 'oci\n'; return ;;
        7783-7084-3265-9085-8269-3286-77) printf 'azure\n'; return ;;
    esac
    case "$sv $bv" in *"Amazon EC2"*|*amazon*) printf 'aws\n'; return ;; esac
    case "$pr" in *"Google Compute Engine"*) printf 'gcp\n'; return ;; esac
    printf 'none\n'
}

# ihwt_licence_host OH DH - host facts for the licence (not in the MOS script):
#   host;<key>;<value> - CPU sockets / cores / threads / model, virtualization,
#   Oracle database instances, ORDS processes, WebLogic domains of the home
ihwt_licence_host() {
    local oh="${1:-}" dh="${2:-}" so co th mo vi pr db od dm
    so="$(lscpu 2>/dev/null | awk -F: '/^Socket\(s\)/ {gsub(/ /,"",$2); print $2}')"
    co="$(lscpu 2>/dev/null | awk -F: '/^Core\(s\) per socket/ {gsub(/ /,"",$2); print $2}')"
    th="$(lscpu 2>/dev/null | awk -F: '/^Thread\(s\) per core/ {gsub(/ /,"",$2); print $2}')"
    mo="$(lscpu 2>/dev/null | awk -F: '/^Model name/ {sub(/^[ \t]+/,"",$2); print $2; exit}')"
    printf 'host;cpu_sockets;%s\n' "${so:--}"
    printf 'host;cpu_cores;%s\n' "$( [ -n "$so" ] && [ -n "$co" ] && printf '%s' "$((so * co))" || printf '%s' "$(nproc 2>/dev/null)")"
    printf 'host;cpu_threads_per_core;%s\n' "${th:--}"
    printf 'host;cpu_model;%s\n' "${mo:--}"
    vi="$(systemd-detect-virt 2>/dev/null)"
    [ -z "$vi" ] && vi="$(lscpu 2>/dev/null | awk -F: '/^Hypervisor vendor/ {gsub(/^[ \t]+/,"",$2); print tolower($2)}')"
    pr="$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
    printf 'host;virtualization;%s\n' "${vi:-none}"
    printf 'host;product_name;%s\n' "${pr:--}"
    printf 'host;cpu_arch;%s\n' "$(uname -m 2>/dev/null || printf -- '-')"
    printf 'host;cloud;%s\n' "$(ihwt_cloud)"
    db="$(ps -eo args= 2>/dev/null | sed -n 's/^ora_pmon_\(.*\)$/\1/p' | sort -u | paste -sd, -)"
    printf 'host;oracle_db_instances;%s\n' "${db:-none}"
    # edition chosen at the installation of the database home (oracle.server
    # globalvariables, oracle_install_db_InstallEdition: EE / SE2 / SE ...) -
    # running instance -> home through /proc/<pmon>/exe, no database login
    local p sid exe hm ed inv h
    for p in $(pgrep -f '^ora_pmon_' 2>/dev/null); do
        sid="$(ps -o args= -p "$p" 2>/dev/null | sed 's/^ora_pmon_//')"
        exe="$(readlink "/proc/$p/exe" 2>/dev/null)"; hm="${exe%/bin/oracle}"
        if [ -n "$exe" ]; then ed="$(ihwt_db_edition "$hm")"; else hm="(not readable as $(id -un))"; ed="unknown"; fi
        printf 'host;oracle_db_edition;%s=%s (%s)\n' "$sid" "${ed:-unknown}" "$hm"
    done
    inv="$(sed -n 's/^inventory_loc=//p' /etc/oraInst.loc 2>/dev/null)"
    for h in $(grep '<HOME ' "${inv:-/nonexistent}/ContentsXML/inventory.xml" 2>/dev/null | grep -v 'REMOVED="T"' | sed -n 's/.* LOC="\([^"]*\)".*/\1/p'); do
        ed="$(ihwt_db_edition "$h")"; [ -n "$ed" ] && printf 'host;oracle_db_home;%s=%s\n' "$h" "$ed"
    done
    od="$(ps -eo pid=,args= 2>/dev/null | awk '/ords\.war|ords[ \t]+serve|oracle\.dbtools\.launcher/ && !/awk/ {print $1}' | paste -sd, -)"
    printf 'host;ords_process;%s\n' "${od:-none}"
    dm="$( [ -n "$oh" ] && sed -n 's/.*location="\([^"]*\)".*/\1/p' "$oh/domain-registry.xml" 2>/dev/null | paste -sd, -)"
    printf 'host;wls_domains;%s\n' "${dm:-${dh:--}}"
}

# ihwt_listen_ports - listening TCP ports, normalised (ss, else netstat):
#   "port;<addr>;<port>;<scope>;<pid>;<process>" - scope local (loopback),
#   ip (one address) or all (0.0.0.0 / * / [::]); pid / process only where the
#   OS shows them (without root: the processes of this user), else "-".
#   Sorted by port, then address; one line per address:port.
ihwt_listen_ports() {
    { ss -ltnpH 2>/dev/null | awk '{print $4 " " $NF}' \
      || netstat -ltnp 2>/dev/null | awk '$1 ~ /^tcp/ {print $4 " " $7}'; } | ihwt_listen_ports_parse
}
# ihwt_listen_ports_parse - "local_address process" lines on stdin (from ss /
#   netstat, or the raw "ss -ltnp" block of an older collection) -> the
#   normalised port lines of ihwt_listen_ports
ihwt_listen_ports_parse() {
    awk '{ a=$1; pr=$2; port=a; sub(/.*:/, "", port); ad=substr(a, 1, length(a)-length(port)-1); gsub(/%[^]]*/, "", ad)
             if (port !~ /^[0-9]+$/) next
             sc="ip"
             if (ad ~ /^(\*|0\.0\.0\.0|\[::\]|::|\[::ffff:0\.0\.0\.0\])$/) sc="all"
             else if (ad ~ /^(127\.|\[::1\]|::1|\[::ffff:127\.)/) sc="local"
             pid="-"; pn="-"
             if (pr ~ /pid=/) { pid=pr; sub(/.*pid=/, "", pid); sub(/[^0-9].*/, "", pid); pn=pr; sub(/^[^"]*"/, "", pn); sub(/".*/, "", pn) }
             else if (pr ~ /^[0-9]+\//) { pid=pr; sub(/\/.*/, "", pid); pn=pr; sub(/^[0-9]+\//, "", pn) }
             k=ad ":" port; if (k in seen) next; seen[k]=1
             printf "port;%s;%s;%s;%s;%s\n", ad, port, sc, pid, pn }' \
    | LC_ALL=C sort -t';' -k3,3n -k2,2
}

# ihwt_java4shell OH DH - Java4Shell (CVE-2026-114938, Base64 intrinsic of
#   HotSpot, AVX-512 VBMI path) facts of this host, read-only, one
#   "java4shell;key;..." line each:
#     java4shell;cpu;<model>;avx512f=y|n avx512bw=.. avx512vbmi=.. bmi2=..;vulnerable=yes|no
#     java4shell;bundled_jdk;<version>;affected|not-affected|java8|none
#     java4shell;reports_sh;<file>;flag=yes|no|no-file
#     java4shell;engine;<rwserver.conf>;<engine id>;flag=yes|no   (engines with jvmOptions only)
#     java4shell;process;<pid>;<name>;<binary>;flag=yes|no        (processes on the bundled JDK)
#   Affected range (Oracle / OpenJDK advisory 2026-11-17): 17.0.6 - 17.0.21.0.x,
#   21 < 21.0.13.1, 25 < 25.0.5.1, 27 < 27.0.1.1; 8 / 11 not listed. Mitigation
#   -XX:-UseBASE64Intrinsics (Java 11+ only, Java 8 does not start with it) -
#   IHateWeblogic 09-Install/docs/00-patch-references.md "Java4Shell".
ihwt_java4shell() {
    local oh="$1" dh="$2" fl x line="" vul=yes v m st lo fix f e pid cmd nm flag bj
    fl="$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | tr ' ' '\n')"
    for x in avx512f avx512bw avx512vbmi bmi2; do
        if printf '%s\n' "$fl" | grep -qx "$x"; then line="$line $x=y"; else line="$line $x=n"; vul=no; fi
    done
    printf 'java4shell;cpu;%s;%s;vulnerable=%s\n' \
        "$(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | sed 's/^[^:]*:[[:space:]]*//; s/;/,/g')" "${line# }" "$vul"
    bj="$oh/oracle_common/jdk"
    if [ -z "$oh" ] || [ ! -x "$bj/bin/java" ]; then
        printf 'java4shell;bundled_jdk;-;none\n'
    else
        v="$("$bj/bin/java" -version 2>&1 | head -1 | grep -oE '"[0-9][^"]*"' | tr -d '"')"
        m="$(printf '%s' "$v" | awk -F'[._-]' '{ print ($1 == 1) ? $2 : $1 }')"
        lo=""; fix=""
        case "$m" in
            8)  st=java8 ;;
            17) lo="17.0.6"; fix="17.0.21.1" ;;
            21) fix="21.0.13.1" ;;
            25) fix="25.0.5.1" ;;
            27) fix="27.0.1.1" ;;
            *)  st=not-affected ;;
        esac
        if [ -n "$fix" ]; then
            st=affected
            [ -n "$lo" ] && [ "$(printf '%s\n%s\n' "$v" "$lo" | sort -V | head -1)" != "$lo" ] && st=not-affected
            [ "$(printf '%s\n%s\n' "$v" "$fix" | sort -V | head -1)" = "$fix" ] && st=not-affected
        fi
        printf 'java4shell;bundled_jdk;%s;%s\n' "${v:-?}" "$st"
    fi
    if [ -n "$dh" ]; then
        f="$dh/reports/bin/reports.sh"
        if [ ! -f "$f" ]; then flag=no-file
        elif grep '^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}REPORTS_JVM_OPTIONS=' "$f" | grep -q 'UseBASE64Intrinsics'; then flag=yes
        else flag=no; fi
        printf 'java4shell;reports_sh;%s;flag=%s\n' "$f" "$flag"
        find "$dh/config/fmwconfig" -name rwserver.conf 2>/dev/null | while read -r f; do
            grep -o '<engine [^>]*jvmOptions="[^"]*"' "$f" 2>/dev/null | while read -r e; do
                flag=no; printf '%s' "$e" | grep -q 'UseBASE64Intrinsics' && flag=yes
                printf 'java4shell;engine;%s;%s;flag=%s\n' "$f" "$(printf '%s' "$e" | sed -n 's/.*id="\([^"]*\)".*/\1/p')" "$flag"
            done
        done
    fi
    [ -n "$oh" ] || return 0
    for pid in $(pgrep -u "$(id -u)" -f "$bj/bin/java|$oh/bin/rw" 2>/dev/null); do
        cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
        [ -n "$cmd" ] || continue
        nm="$(printf '%s' "$cmd" | grep -oE 'oracle\.reports\.component=[^ ]+' | cut -d= -f2)"
        [ -z "$nm" ] && nm="$(basename "$(printf '%s' "$cmd" | awk '{print $1}')")"
        flag=no
        # native rwserver: the embedded JVM reads REPORTS_JVM_OPTIONS from its environment
        if printf '%s' "$cmd" | grep -q 'UseBASE64Intrinsics' \
           || tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep '^REPORTS_JVM_OPTIONS=' | grep -q 'UseBASE64Intrinsics'; then
            flag=yes
        fi
        printf 'java4shell;process;%s;%s;%s;flag=%s\n' "$pid" "$nm" "$(readlink -f "/proc/$pid/exe" 2>/dev/null)" "$flag"
    done
    return 0
}

# ihwt_domains_find OH DH - the OTHER WebLogic domains of this host (top level
#   only, read-only): domain-registry.xml and nodemanager.domains of OH and of
#   every home of the central inventory, running servers (-Dweblogic.RootDirectory,
#   -Ddomain.home, working directory), nodemanager.domains of DH and the sibling
#   directories of DH. One realpath per line, DH itself left out.
#   IHWT_DOMAINS_EXTRA (tests only): additional candidates.
ihwt_domains_find() {
    local oh="${1:-}" dh="${2:-}" inv h p rd
    inv="$(sed -n 's/^inventory_loc=//p' /etc/oraInst.loc 2>/dev/null | head -1)"
    rd="$( [ -n "$dh" ] && readlink -f "$dh")"
    {
        { [ -n "$oh" ] && printf '%s\n' "$oh"
          [ -n "$inv" ] && grep '<HOME ' "$inv/ContentsXML/inventory.xml" 2>/dev/null | grep -v 'REMOVED="T"' | sed -n 's/.*LOC="\([^"]*\)".*/\1/p'
        } | sort -u | while read -r h; do
            sed -n 's/.*location="\([^"]*\)".*/\1/p' "$h/domain-registry.xml" 2>/dev/null
            sed -n 's/^[^#=]*=\(.*\)$/\1/p' "$h/oracle_common/common/nodemanager/nodemanager.domains" 2>/dev/null
        done
        ps -eo args= 2>/dev/null | sed -n 's/.*-Dweblogic\.RootDirectory=\([^ ]*\).*/\1/p; s/.*-Ddomain\.home=\([^ ]*\).*/\1/p'
        for p in $(ps -eo pid=,args= 2>/dev/null | awk '/-Dweblogic\.Name=/ && !/awk/ {print $1}'); do
            readlink -f "/proc/$p/cwd" 2>/dev/null
        done
        if [ -n "$dh" ]; then
            sed -n 's/^[^#=]*=\(.*\)$/\1/p' "$dh/nodemanager/nodemanager.domains" 2>/dev/null
            for p in "$(dirname "$dh")"/*/; do printf '%s\n' "${p%/}"; done
        fi
        [ -n "${IHWT_DOMAINS_EXTRA:-}" ] && printf '%s\n' $IHWT_DOMAINS_EXTRA
    } | while read -r p; do
        [ -n "$p" ] && [ -f "$p/config/config.xml" ] || continue
        p="$(readlink -f "$p")"; [ "$p" = "$rd" ] && continue
        printf '%s\n' "$p"
    done | sort -u
}

# ihwt_domain_product NAME - product of a deployment / server name (BI
#   Publisher, OAM, ... - for the overview of the other domains)
ihwt_domain_product() {
    case "$(printf '%s' "${1%%#*}" | tr '[:upper:]' '[:lower:]')" in
        formsapp*) printf 'Forms' ;;
        reports*) printf 'Reports' ;;
        xmlpserver*|bipublisher*) printf 'BI Publisher' ;;
        analytics*|bimad*|bi-*|biee*|bicomposer*) printf 'BI / Oracle Analytics' ;;
        oam_server*|oam_admin*|oamsso*) printf 'OAM' ;;
        oim*|identity*) printf 'OIM' ;;
        soa-infra*|soa_server*) printf 'SOA' ;;
        ords*) printf 'ORDS' ;;
        apex*) printf 'APEX' ;;
        fads*) printf 'FADS' ;;
        em) printf 'Fusion Middleware Control' ;;
        wsm-pm*) printf 'OWSM' ;;
        *) printf '' ;;
    esac
}

# ihwt_domain_summary D - top level of one domain, key;value lines (no
#   configuration content, no secrets): name, version, production mode, Oracle
#   home and JAVA_HOME of setDomainEnv.sh, every server with listen address /
#   port / cluster and - when running - pid, java binary and -Xmx, every
#   application deployment with its targets, the products derived from them
ihwt_domain_summary() {
    local d="$1" c="$1/config/config.xml" wl oh jh ps_ pr
    [ -f "$c" ] || return 0
    printf 'domain;path;%s\n' "$d"
    printf 'domain;name;%s\n' "$(sed -n 's/.*<name>\([^<]*\)<\/name>.*/\1/p' "$c" | head -1)"
    printf 'domain;version;%s\n' "$(sed -n 's/.*<domain-version>\([^<]*\)<.*/\1/p' "$c" | head -1)"
    printf 'domain;production_mode;%s\n' "$(sed -n 's/.*<production-mode-enabled>\([^<]*\)<.*/\1/p' "$c" | head -1)"
    wl="$(sed -n 's/^[[:space:]]*\(export \)\{0,1\}WL_HOME="\{0,1\}\([^"$]*\)"\{0,1\}[[:space:]]*$/\2/p' "$d/bin/setDomainEnv.sh" 2>/dev/null | head -1)"
    oh="$( [ -n "$wl" ] && dirname "$wl")"
    [ -z "$oh" ] && oh="$(sed -n 's/^[[:space:]]*\(export \)\{0,1\}\(MW_HOME\|ORACLE_HOME\)="\{0,1\}\([^"$]*\)"\{0,1\}[[:space:]]*$/\3/p' "$d/bin/setDomainEnv.sh" 2>/dev/null | head -1)"
    jh="$(sed -n 's/^[[:space:]]*\(export \)\{0,1\}JAVA_HOME="\{0,1\}\([^"$]*\)"\{0,1\}[[:space:]]*$/\2/p' "$d/bin/setDomainEnv.sh" 2>/dev/null | tail -1)"
    # WebLogic plug-in enabled (domain web-app-container, cluster, server):
    # needed when TLS ends in front of WebLogic (WL-Proxy-SSL header honoured)
    printf 'domain;weblogic_plugin_enabled;%s\n' "$(awk 'function ind(x) { match(x, /^[ \t]*/); return RLENGTH }
        di<0 && /<name>/ {di=ind($0); next}
        BEGIN {di=-1}
        di>=0 && ind($0)==di && /^[ \t]*<(server|cluster|web-app-container)>/ {k=$0; gsub(/[ \t<>]/, "", k); n=(k=="web-app-container" ? "domain" : ""); next}
        k!="" && n=="" && /<name>/ {n=$0; gsub(/.*<name>|<\/name>.*/, "", n)}
        k!="" && /<weblogic-plugin-enabled>/ {v=$0; gsub(/.*<weblogic-plugin-enabled>|<\/weblogic-plugin-enabled>.*/, "", v); o=o (o==""?"":",") n "=" v}
        di>=0 && ind($0)==di && /^[ \t]*<\/(server|cluster|web-app-container)>/ {k=""; n=""}
        END {print (o=="" ? "not set" : o)}' "$c")"
    printf 'domain;oracle_home;%s\n' "${oh:--}"
    printf 'domain;java_home;%s\n' "${jh:--}"
    ps_="$(ps -eo pid=,args= 2>/dev/null | awk '/-Dweblogic\.Name=/ && !/awk/')"
    # direct children of <server> only: same indentation as its first <name>
    # (nested network-access-point / ssl elements have their own listen-port)
    awk 'function ind(x) { match(x, /^[ \t]*/); return RLENGTH }
         !s && /^[ \t]*<server>[ \t]*$/ {s=1; n=""; a=""; p=""; cl=""; ci=-1; si=ind($0); next}
         s && /^[ \t]*<\/server>/ && ind($0)==si {print n ";" (a=="" ? "-" : a) ";" (p=="" ? "7001" : p) ";" (cl=="" ? "-" : cl); s=0; next}
         s && n=="" && /<name>/ {n=$0; gsub(/.*<name>|<\/name>.*/, "", n); ci=ind($0); next}
         s && ind($0)!=ci {next}
         s && /<listen-address>/ {a=$0; gsub(/.*<listen-address>|<\/listen-address>.*/, "", a)}
         s && /<listen-port>/ {p=$0; gsub(/.*<listen-port>|<\/listen-port>.*/, "", p)}
         s && /<cluster>/ {cl=$0; gsub(/.*<cluster>|<\/cluster>.*/, "", cl)}' "$c" \
    | while IFS=';' read -r n a p cl; do
        local pid="" ja="-" xm="-" l
        while read -r l; do
            [ -n "$l" ] || continue
            case "$l" in *"-Dweblogic.Name=$n "*|*"-Dweblogic.Name=$n") ;; *) continue ;; esac
            case "$l" in *"=$d "*|*"=$d/"*|*"$d/"*) pid="${l%% *}" ;;
                *) [ "$(readlink -f "/proc/${l%% *}/cwd" 2>/dev/null)" = "$d" ] && pid="${l%% *}" ;; esac
            if [ -n "$pid" ]; then
                ja="$(printf '%s' "$l" | awk '{print $2}')"
                xm="$(printf '%s' "$l" | grep -oE -- '-Xmx[0-9]+[kKmMgG]?' | tail -1)"; break
            fi
        done <<< "$ps_"
        printf 'server;%s;%s;%s;%s;%s;%s;%s\n' "$n" "$a" "$p" "$cl" "${pid:-no}" "$ja" "${xm:--}"
    done
    awk '/<app-deployment>/ {s=1; n=""; t=""; next}
         s && /<\/app-deployment>/ {print n ";" t; s=0; next}
         s && n=="" && /<name>/ {n=$0; gsub(/.*<name>|<\/name>.*/, "", n)}
         s && /<target>/ {t=$0; gsub(/.*<target>|<\/target>.*/, "", t)}' "$c" \
        | while IFS=';' read -r n t; do printf 'deployment;%s;%s\n' "$n" "$t"; done
    pr="$( { awk '/<app-deployment>/ {s=1; next} s && /<name>/ {n=$0; gsub(/.*<name>|<\/name>.*/, "", n); print n; s=0}' "$c"
             awk '/^[ \t]*<server>[ \t]*$/ {s=1; next} s && /<name>/ {n=$0; gsub(/.*<name>|<\/name>.*/, "", n); print n; s=0}' "$c"; } \
           | while read -r n; do ihwt_domain_product "$n"; printf '\n'; done | grep -v '^$' | sort -u | paste -sd, -)"
    printf 'domain;products;%s\n' "${pr:-unknown}"
}

# ihwt_webgate DH - WebGate configured in the OHS instances of the domain?
#   (installed in the home = binaries only; configured = webgate/config/
#   ObAccessClient.xml of the instance, written by the OAM agent registration)
#   "webgate;<instance>;loaded=<yes|no>;id=..;security=..;primary=host:port;cert_until=.."
#   or "webgate;none;-". Only names, mode, server and the certificate expiry -
#   no passphrase. The language catalogues webgate/ohs/lang/*/ObAccessClient.xml
#   of the home are not agent configurations.
ihwt_webgate() {
    local dh="${1:-}" f inst base kv id sec host port ce ld n=0
    [ -n "$dh" ] && [ -d "$dh/config/fmwconfig/components/OHS" ] || { printf 'webgate;none;-\n'; return 0; }
    while read -r f; do
        [ -n "$f" ] || continue
        base="${f%/webgate/config/ObAccessClient.xml}"; inst="${base##*/}"
        case "$base" in */instances/*) inst="instances/$inst" ;; esac
        kv="$(tr '\n' ' ' < "$f" | grep -oE 'ParamName="[^"]*"[[:space:]]+Value="[^"]*"' | sed -E 's/ParamName="([^"]*)"[[:space:]]+Value="([^"]*)"/\1=\2/')"
        id="$(printf '%s\n' "$kv" | grep -iE '^id=' | head -1 | cut -d= -f2-)"
        sec="$(printf '%s\n' "$kv" | grep -iE '^security=' | head -1 | cut -d= -f2-)"
        host="$(printf '%s\n' "$kv" | grep -iE '^host=' | head -1 | cut -d= -f2-)"
        port="$(printf '%s\n' "$kv" | grep -iE '^port=' | head -1 | cut -d= -f2-)"
        ce="$(find "$base/webgate/config" -name 'aaa_cert.pem' 2>/dev/null | while read -r c; do openssl x509 -noout -enddate -in "$c" 2>/dev/null | sed 's/^notAfter=//'; done | head -1)"
        ld=no; grep -qsE '^[[:space:]]*include[[:space:]].*webgate\.conf' "$base/httpd.conf" && ld=yes
        printf 'webgate;%s;loaded=%s;id=%s;security=%s;primary=%s;cert_until=%s\n' "$inst" "$ld" "${id:--}" "${sec:--}" "${host:+$host:$port}" "${ce:--}"
        n=$((n + 1))
    done < <(find "$dh/config/fmwconfig/components/OHS" -path '*/webgate/config/ObAccessClient.xml' ! -path '*/lang/*' 2>/dev/null | sort)
    [ "$n" -eq 0 ] && printf 'webgate;none;-\n'
    return 0
}
