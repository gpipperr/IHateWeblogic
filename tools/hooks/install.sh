#!/bin/bash
# =============================================================================
# Script   : tools/hooks/install.sh
# Purpose  : Activate the repository hooks for this clone and create the local
#            customer-name list from the example if it does not exist yet.
#              git config core.hooksPath tools/hooks
#              ~/.config/ihw/customer_patterns  (mode 600, never in git)
# Call     : tools/hooks/install.sh          once per clone
# License  : Apache 2.0
# =============================================================================

VERSION="2026-11-11.1"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { printf 'not inside a git repository\n' >&2; exit 2; }
cd "$ROOT" || exit 2

git config core.hooksPath tools/hooks
chmod +x tools/hooks/pre-commit
printf 'OK    core.hooksPath = %s\n' "$(git config core.hooksPath)"

LIST="${IHW_CUSTOMER_PATTERNS:-$HOME/.config/ihw/customer_patterns}"
if [ -e "$LIST" ]; then
    printf 'OK    customer list exists: %s (%s entries)\n' "$LIST" \
        "$(grep -cvE '^[[:space:]]*(#|$)' "$LIST")"
else
    mkdir -p "$(dirname "$LIST")"
    install -m 600 tools/hooks/customer_patterns.example "$LIST"
    printf 'NEW   %s created from the example - put in your customer names\n' "$LIST"
fi
exit 0
