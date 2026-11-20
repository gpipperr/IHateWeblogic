#!/usr/bin/env python3
# =============================================================================
# Script   : py36_check.py
# Purpose  : Gate for the python files of 11-wlsmon: they must compile and use
#            only python 3.6 syntax (OL8 ships 3.6). Called by tools/ci_lint.sh.
#              - ast.parse(feature_version=(3, 6)) catches :=, positional-only
#                parameters, match, parenthesised context managers ...
#              - the PEG parser (3.9+) does not enforce feature_version for
#                everything, so an AST walk checks itself: walrus, positional-
#                only parameters, "X | Y" hints, f-string "=", newer modules,
#                and the usual 3.7+ stdlib traps (subprocess capture_output /
#                text, datetime.fromisoformat, str.removeprefix ...)
# Call     : python3 -I tools/py36_check.py file.py [file.py ...]
# Exit     : 0 = all ok, 1 = finding(s), 2 = usage
# License  : Apache 2.0
# =============================================================================
import ast
import re
import sys

NEW_ATTRS = {"fromisoformat", "removeprefix", "removesuffix", "isqrt",
             "cached_property", "get_running_loop", "is_relative_to"}
NEW_KWARGS = {"capture_output", "text"}
NEW_MODULES = {"dataclasses", "contextvars", "graphlib", "zoneinfo", "tomllib",
               "importlib.metadata", "importlib.resources"}


def check(path):
    findings = []
    with open(path, "r", encoding="utf-8") as fh:
        src = fh.read()
    try:
        compile(src, path, "exec")
        tree = ast.parse(src, filename=path, feature_version=(3, 6))
    except SyntaxError as exc:
        return ["%s:%s: syntax (python 3.6): %s" % (path, exc.lineno, exc.msg)]
    for node in ast.walk(tree):
        if type(node).__name__ in ("NamedExpr", "Match"):
            findings.append("%s:%s: %s is 3.8+" % (path, node.lineno,
                            type(node).__name__))
        if isinstance(node, ast.arguments) and getattr(node, "posonlyargs", None):
            findings.append("%s:%s: positional-only parameters are 3.8+"
                            % (path, node.posonlyargs[0].lineno))
        if isinstance(node, ast.Attribute) and node.attr in NEW_ATTRS:
            findings.append("%s:%s: .%s is newer than 3.6"
                            % (path, node.lineno, node.attr))
        fname = getattr(getattr(node, "func", None), "attr", None) \
            or getattr(getattr(node, "func", None), "id", None)
        if isinstance(node, ast.Call) and fname in ("run", "check_output", "Popen",
                                                    "check_call", "call"):
            for kw in node.keywords:
                if kw.arg in NEW_KWARGS:
                    findings.append("%s:%s: keyword %s= (subprocess 3.7+) - use "
                                    "stdout=PIPE / universal_newlines=True"
                                    % (path, node.lineno, kw.arg))
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            names = [a.name for a in node.names] if isinstance(node, ast.Import) \
                else [node.module or ""]
            for name in names:
                if name in NEW_MODULES or name.split(".")[0] in NEW_MODULES:
                    findings.append("%s:%s: module newer than 3.6: %s"
                                    % (path, node.lineno, name))
            if isinstance(node, ast.ImportFrom) and node.module == "__future__":
                if any(a.name == "annotations" for a in node.names):
                    findings.append("%s:%s: from __future__ import annotations is 3.7+"
                                    % (path, node.lineno))
        ann = getattr(node, "annotation", None) or getattr(node, "returns", None)
        if ann is not None:
            for sub in ast.walk(ann):
                if isinstance(sub, ast.BinOp) and isinstance(sub.op, ast.BitOr):
                    findings.append("%s:%s: 'X | Y' type hint is 3.10+"
                                    % (path, node.lineno))
                    break
    # f-string self-documenting "=" (3.8+): f"{x=}" / f"{x = }"
    for no, line in enumerate(src.splitlines(), 1):
        if re.search(r"""\bf["'][^"']*\{[^{}"']*[^=!<>]=\s*(![rsa])?(:[^}]*)?\}""", line):
            findings.append("%s:%s: f-string '=' specifier is 3.8+" % (path, no))
    return findings


def main(argv):
    if len(argv) < 2:
        print("usage: py36_check.py file.py [...]", file=sys.stderr)
        return 2
    allf = []
    for path in argv[1:]:
        allf.extend(check(path))
    if allf:
        print("\n".join(allf))
        return 1
    print("%d file(s) python 3.6 clean" % (len(argv) - 1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
