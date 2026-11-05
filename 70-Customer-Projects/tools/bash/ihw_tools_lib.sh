#!/bin/bash
# =============================================================================
# Script   : ihw_tools_lib.sh
# Purpose  : Shared helpers of the standalone customer tools in
#            70-Customer-Projects/tools/bash (export_forms_reports_conf.sh,
#            analyse_forms_reports_export.sh, ...). NOT the IHateWeblogic
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

IHWT_LIB_VERSION="2026-11-05.2"
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
# ihwt_md_table "Col1;Col2;..." - ';'-CSV on stdin -> Markdown table
#   (no header line in the input). "|" in values is escaped, empty input
#   prints "_none found_".
# -----------------------------------------------------------------------------
ihwt_md_table() {
    awk -F';' -v head="$1" '
        BEGIN { n = split(head, h, ";"); line = "|"; sep = "|"
                for (i = 1; i <= n; i++) { line = line " " h[i] " |"; sep = sep "---|" } }
        NF == 0 { next }
        { if (!rows++) { print line; print sep }
          out = "|"
          for (i = 1; i <= n; i++) { v = (i <= NF ? $i : ""); gsub(/\|/, "\\|", v); if (i == n && NF > n) for (j = n + 1; j <= NF; j++) v = v ";" $j
              out = out " " v " |" }
          print out }
        END { if (!rows) print "_none found_" }'
}

# -----------------------------------------------------------------------------
# Archive encryption (export_forms_reports_conf.sh, collect_fmw_env.sh,
# analyse_forms_reports_export.sh): ZIP (tar.gz without zip), openssl
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
# export_forms_reports_conf.sh and analyse_forms_reports_export.sh.
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
                    case "$l" in *OHS*|*/ohs/*|*components/OHS*) t=ohs ;; esac
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
        w=="listen" { v=a; s="no"; if (v ~ /[[:space:]]https$/) s="yes"; sub(/[[:space:]].*/, "", v); if (v !~ /:/) v="*:" v; gl=(gl=="" ? v : gl "," v); next }
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
        END { for (r=1; r<=nr; r++) { v=rv[r]
                  printf "%s;%s;%s;%s;%s;%s;%s;%s;%s;%s\n", type, conf, (v ? vl[v] : gl), (v ? (vn[v] != "" ? vn[v] : gn) : gn),
                      (v ? vt[v] : (gt != "" ? gt : "no")), (v && vpr[v] != "" ? vpr[v] : gpr), rpth[r], rtg[r], racc[r], (v && vcert[v] != "" ? vcert[v] : gcert) }
              for (v=1; v<=nv; v++) if (!vrows[v])
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
        lw ~ /^(server_tokens|servertokens|serversignature|traceenable|debugconfiginfo|autoindex)$/ { printf "%s;%s;%s;%s;%s\n", type, conf, w, a, stk[n] }
        lw=="options" && tolower(a) ~ /(^|[[:space:]])\+?indexes/ { printf "%s;%s;Options;%s;%s\n", type, conf, a, stk[n] }'
}
