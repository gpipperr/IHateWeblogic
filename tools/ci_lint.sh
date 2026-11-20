#!/bin/bash
# =============================================================================
# Script   : ci_lint.sh
# Purpose  : Syntax / lint gate for all shell scripts under git - the same
#            check locally and in GitHub Actions (.github/workflows/lint.yml).
#              1. bash -n        every *.sh and *.sh.template      -> gate
#              2. shellcheck -S error   (real errors only)         -> gate
#              3. shellcheck -S warning (report only, never fails)
#              P. python: py_compile + Python 3.6 syntax (OL8) for every *.py
#                 under 11-wlsmon/, then its unittests              -> gate
#              J. javascript: ES5 syntax of 11-wlsmon/www/js via Nashorn (jjs
#                 of a JDK 8-14) - skipped when no jjs exists (CI) -> gate
# Call     : tools/ci_lint.sh               from anywhere inside the repo
# Exit     : 0 = gate passed, 1 = bash -n or shellcheck error, 2 = setup error
# Needs    : bash, git; shellcheck for steps 2 + 3 (missing locally -> skipped
#            with a hint; in CI it is preinstalled on ubuntu-latest)
#            CI_LINT_VERBOSE=1 tools/ci_lint.sh   also lists every warning
# License  : Apache 2.0
# =============================================================================

VERSION="2026-11-19.1"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { printf 'not inside a git repository\n' >&2; exit 2; }
cd "$ROOT" || exit 2

mapfile -t FILES < <(git ls-files '*.sh' '*.sh.template' 'tools/hooks/pre-commit')
[ "${#FILES[@]}" -gt 0 ] || { printf 'no shell scripts found\n' >&2; exit 2; }

RC=0
printf 'ci_lint.sh %s - %d files\n\n' "$VERSION" "${#FILES[@]}"

# --- 1. bash -n --------------------------------------------------------------
printf '== 1. bash -n\n'
fail=0
for f in "${FILES[@]}"; do
    if ! out="$(bash -n "$f" 2>&1)"; then
        printf 'FAIL  %s\n%s\n' "$f" "$out"
        fail=$((fail + 1))
    fi
done
if [ "$fail" -eq 0 ]; then
    printf 'OK    all %d files parse\n\n' "${#FILES[@]}"
else
    printf 'FAIL  %d file(s) with syntax errors\n\n' "$fail"
    RC=1
fi

# --- P. python (11-wlsmon: stdlib only, must run on python 3.6 / OL8) -------
mapfile -t PYFILES < <(git ls-files '11-wlsmon/*.py')
if [ "${#PYFILES[@]}" -gt 0 ]; then
    printf '== P. python 3.6 syntax + unittest (%d files)\n' "${#PYFILES[@]}"
    if ! command -v python3 >/dev/null 2>&1; then
        printf 'FAIL  python3 not found\n\n'
        RC=1
    elif out="$(python3 -I tools/py36_check.py "${PYFILES[@]}" 2>&1)"; then
        printf 'OK    %s\n' "$out"
        if [ -d 11-wlsmon/tests ]; then
            if out="$(cd 11-wlsmon && python3 -I -m unittest discover -s tests -t . 2>&1)"; then
                printf 'OK    unittest: %s\n\n' "$(printf '%s\n' "$out" | grep -E '^Ran ')"
            else
                printf 'FAIL  unittest\n%s\n\n' "$out"
                RC=1
            fi
        else
            printf '\n'
        fi
    else
        printf 'FAIL  %s\n\n' "$out"
        RC=1
    fi
fi

# --- J. javascript syntax (11-wlsmon GUI, plain ES5) -------------------------
if [ -x 11-wlsmon/tools/js_syntax_check.sh ] && git ls-files --error-unmatch 11-wlsmon/www/js >/dev/null 2>&1; then
    printf '== J. javascript ES5 syntax\n'
    out="$(11-wlsmon/tools/js_syntax_check.sh 2>&1)"
    case $? in
        0) printf 'OK    %s file(s)\n\n' "$(printf '%s\n' "$out" | grep -c '^OK')" ;;
        3) printf '%s\n\n' "$out" ;;
        *) printf '%s\n\n' "$out" | grep -v '^OK'; RC=1 ;;
    esac
fi

# --- 2. + 3. shellcheck --------------------------------------------------------
if ! command -v shellcheck >/dev/null 2>&1; then
    printf 'SKIP  shellcheck not installed - steps 2 + 3 run in GitHub Actions\n'
    exit "$RC"
fi
printf '%s\n\n' "$(shellcheck --version | grep '^version')"

# Every script is bash; sourced files (environment.conf, lib) are resolved at
# run time, so SC1090 / SC1091 (cannot follow) are excluded.
# One run at warning level, in parallel (8 x 10 files) - the gate counts only
# the "error" lines, the warnings are a report.
OUT="$(mktemp)" || exit 2
trap 'rm -f "$OUT"' EXIT
printf '%s\0' "${FILES[@]}" | xargs -0 -P8 -n10 \
    shellcheck --shell=bash --exclude=SC1090,SC1091 --severity=warning --format=gcc > "$OUT" 2>&1

printf '== 2. shellcheck -S error (gate)\n'
if grep -q ': error: ' "$OUT"; then
    grep ': error: ' "$OUT" | sort
    printf 'FAIL  %s shellcheck error(s)\n\n' "$(grep -c ': error: ' "$OUT")"
    RC=1
else
    printf 'OK    no shellcheck errors\n\n'
fi

printf '== 3. shellcheck -S warning (report only)\n'
printf 'INFO  %s warning(s) - top codes:\n' "$(grep -c ': warning: ' "$OUT")"
grep ': warning: ' "$OUT" | grep -oE '\[SC[0-9]+\]' | sort | uniq -c | sort -rn | head -10
if [ -n "${CI_LINT_VERBOSE:-}" ]; then
    grep ': warning: ' "$OUT" | sort
fi

exit "$RC"
