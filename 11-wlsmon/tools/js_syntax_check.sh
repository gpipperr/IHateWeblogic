#!/bin/bash
# =============================================================================
# Script   : js_syntax_check.sh
# Purpose  : Syntax check of the wlsmon GUI JavaScript (plain ES5) without
#            node: the Nashorn engine of a JDK 8 - 14 (jjs) compiles every file
#            with "new Function(src)". Development tool only - the hosts need
#            no JavaScript engine. Called by tools/ci_lint.sh when a jjs exists.
# Call     : 11-wlsmon/tools/js_syntax_check.sh [file.js ...]
#              without arguments: every 11-wlsmon/www/js/*.js
#            WLSMON_JJS=/path/to/jjs overrides the search
# Exit     : 0 = ok, 1 = syntax error, 3 = no jjs found (skipped)
# License  : Apache 2.0
# =============================================================================

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find_jjs() {
    local c
    for c in "${WLSMON_JJS:-}" "$(command -v jjs 2>/dev/null)" \
             /u01/app/oracle/product/*/db_home*/jdk/bin/jjs \
             /usr/lib/jvm/*/bin/jjs /usr/lib/jvm/*/jre/bin/jjs; do
        [ -n "$c" ] && [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

JJS="$(find_jjs)" || { printf 'SKIP  no jjs (Nashorn, JDK 8-14) found - set WLSMON_JJS\n'; exit 3; }

if [ "$#" -eq 0 ]; then
    set -- "$HERE"/../www/js/*.js
fi

CHECK="$(mktemp --suffix=.js)" || exit 1
trap 'rm -f "$CHECK"' EXIT
cat > "$CHECK" <<'JS'
var Files = java.nio.file.Files, Paths = java.nio.file.Paths;
var rc = 0;
for (var i = 0; i < arguments.length; i++) {
    var f = arguments[i];
    var src = new java.lang.String(Files.readAllBytes(Paths.get(f)), "UTF-8");
    try { new Function(src); print("OK    " + f); }
    catch (e) { print("FAIL  " + f + ": " + e); rc = 1; }
}
exit(rc);
JS

"$JJS" "$CHECK" -- "$@"
