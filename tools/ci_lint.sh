#!/bin/bash
# =============================================================================
# Script   : ci_lint.sh
# Purpose  : Syntax / lint gate for all shell scripts under git - the same
#            check locally and in GitHub Actions (.github/workflows/lint.yml).
#              1. bash -n        every *.sh and *.sh.template      -> gate
#              2. shellcheck -S error   (real errors only)         -> gate
#              3. shellcheck -S warning (report only, never fails)
# Call     : tools/ci_lint.sh               from anywhere inside the repo
# Exit     : 0 = gate passed, 1 = bash -n or shellcheck error, 2 = setup error
# Needs    : bash, git; shellcheck for steps 2 + 3 (missing locally -> skipped
#            with a hint; in CI it is preinstalled on ubuntu-latest)
#            CI_LINT_VERBOSE=1 tools/ci_lint.sh   also lists every warning
# License  : Apache 2.0
# =============================================================================

VERSION="2026-11-11.2"

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
