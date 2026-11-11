#!/bin/bash
# =============================================================================
# Script   : render_ascii.sh
# Purpose  : Wrapper for render_ascii.py – ASCII diagrams in Markdown as SVG.
#            Puts ~/.local/bin (d2, svgbob) on the PATH and calls the Python tool.
# Call     : tools/render_ascii/render_ascii.sh --file X.md | --all
#                                     [--engine d2|svgbob] [--force] [--dry-run]
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : tools/render_ascii/README.md
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATH="$HOME/.local/bin:$PATH"
export PATH
if ! command -v python3 >/dev/null 2>&1; then
    printf "\033[31mFAIL\033[0m  python3 not found\n" >&2
    exit 2
fi
exec python3 "$SCRIPT_DIR/render_ascii.py" "$@"
