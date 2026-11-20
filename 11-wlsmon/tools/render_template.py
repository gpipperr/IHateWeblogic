#!/usr/bin/env python3
# =============================================================================
# Script   : render_template.py
# Purpose  : Renders the wlsmon templates (11-wlsmon/templates/) - the one
#            renderer for 00-setup-interview.sh, 01-install-wlsmon_fmw.sh,
#            02-install-wlsmon_root.sh and the tests (development plan step 8):
#              ##VARIABLE##          replaced by its value (comment lines are
#                                    left alone - they document the variables)
#              #@NAME_BEGIN@ ... #@NAME_END@   block kept with --keep NAME,
#                                    otherwise removed; marker lines always go
#              --multi VAR           a line holding ##VAR## is repeated once per
#                                    entry of the value, separated by commas or
#                                    blanks ("allow ##ADMIN_IP_RANGE##;" -> one
#                                    allow line per network); the value "any"
#                                    removes the line and the "deny all;" right
#                                    after it (no IP restriction) - the same rule
#                                    as 09-Install/04-root_nginx.sh
#            Fails when a ##VARIABLE## is left outside comments or a block is
#            not closed - nothing half rendered is ever written.
# Call     : render_template.py TEMPLATE --out FILE [--var K=V ...] [--keep NAME ...]
#                               [--multi VAR ...]
# Exit     : 0 = written, 1 = unresolved variable / marker error, 2 = usage
# Needs    : python3 (3.6+), standard library only
# License  : Apache 2.0
# =============================================================================
import argparse
import os
import re
import sys
import tempfile

VAR_RE = re.compile(r"##([A-Z0-9_]+)##")
MARK_RE = re.compile(r"^\s*#@([A-Z0-9_]+)_(BEGIN|END)@\s*$")


def render(text, values, keep=(), multi=()):
    """-> (rendered text, [errors])"""
    out, errors, stack = [], [], []
    skip_deny = False
    for no, line in enumerate(text.splitlines(True), 1):
        if skip_deny:
            skip_deny = False
            if re.match(r"^\s*deny\s+all;", line):
                continue
        m = MARK_RE.match(line)
        if m:
            name, kind = m.groups()
            if kind == "BEGIN":
                stack.append(name)
            elif not stack or stack[-1] != name:
                errors.append("line %d: %s_END without BEGIN" % (no, name))
            else:
                stack.pop()
            continue
        if any(b not in keep for b in stack):
            continue
        if line.lstrip().startswith("#"):
            out.append(line)
            continue
        names = VAR_RE.findall(line)
        missing = [n for n in names if n not in values]
        if missing:
            errors.append("line %d: no value for %s" % (no, ", ".join("##%s##" % n for n in missing)))
            continue
        mv = [n for n in names if n in multi]
        if mv:
            words = values[mv[0]].replace(",", " ").split()
            if words in ([], ["any"]):
                skip_deny = line.lstrip().startswith("allow ")
                continue
            for w in words:
                one = dict(values)
                one[mv[0]] = w
                out.append(VAR_RE.sub(lambda x: one[x.group(1)], line))
            continue
        out.append(VAR_RE.sub(lambda x: values[x.group(1)], line))
    if stack:
        errors.append("block %s not closed" % stack[-1])
    return "".join(out), errors


def main(argv):
    ap = argparse.ArgumentParser(description="render a wlsmon template")
    ap.add_argument("template")
    ap.add_argument("--out", required=True)
    ap.add_argument("--var", action="append", default=[], help="KEY=value")
    ap.add_argument("--keep", action="append", default=[], help="block name to keep")
    ap.add_argument("--multi", action="append", default=[], help="variable with one line per word")
    a = ap.parse_args(argv[1:])
    values = {}
    for kv in a.var:
        if "=" not in kv:
            print("--var needs KEY=value: %s" % kv, file=sys.stderr)
            return 2
        k, v = kv.split("=", 1)
        values[k] = v
    with open(a.template, "r", encoding="utf-8") as fh:
        text, errors = render(fh.read(), values, set(a.keep), set(a.multi))
    if errors:
        for e in errors:
            print("FAIL  %s: %s" % (os.path.basename(a.template), e), file=sys.stderr)
        return 1
    d = os.path.dirname(os.path.abspath(a.out))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp_render_")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
