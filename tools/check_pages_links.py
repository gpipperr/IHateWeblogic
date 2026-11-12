#!/usr/bin/env python3
# =============================================================================
# Script   : tools/check_pages_links.py
# Purpose  : Link check for the two ways the docs are read:
#              github.com (Markdown view)  and  GitHub Pages (Jekyll site)
#            Local mode (default) reads every git-tracked .md and checks each
#            relative link:
#              missing     target file / folder does not exist
#              anchor      #anchor not found in the target .md
#              folder      folder without README.md - 404 on Pages
#              excluded    target excluded in _config.yml - 404 on Pages
#              raw         link to a code / raw file (.sh, .txt, .d2 ...) -
#                          Pages serves it raw or as a download
#              permalink   README with front matter but without permalink -
#                          the folder address is 404 on Pages
#            --live checks the published site: every page of the sitemap,
#            every internal href (HTTP status) and #anchor (id= in the HTML).
# Call     : tools/check_pages_links.py                  local check
#            tools/check_pages_links.py --live           published site
#            tools/check_pages_links.py --fix raw,folder,excluded [FILE ...]
#                                                        show the rewrite (diff)
#            ... --fix ... --apply                       write it (backup in log/)
#            tools/check_pages_links.py --link-code [FILE ...] [--apply]
#                                     link the first `file.sh` / `doc.md` code
#                                     mention per section, every table row
#                                     (skips CHANGELOG, TODO, SKILL.md, headings,
#                                     fenced code, ambiguous names)
# Rewrite  : raw / excluded file -> https://github.com/<repo>/blob/main/<path>
#            folder / excluded folder -> .../tree/main/<path>
#            .zip, images and .md stay relative (fine in both worlds).
# Exit     : 0 = no findings, 1 = findings, 2 = error
# Needs    : Python 3 standard library only
# License  : Apache 2.0
# =============================================================================

import argparse
import datetime
import difflib
import html.parser
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

VERSION = "2026-11-12.1"
REPO = "gpipperr/IHateWeblogic"
BLOB = "https://github.com/%s/blob/main/" % REPO
TREE = "https://github.com/%s/tree/main/" % REPO
SITE = "https://gpipperr.github.io/IHateWeblogic/"

PAGE_EXT = (".md",)
KEEP_EXT = (".svg", ".png", ".jpg", ".jpeg", ".gif", ".zip")   # fine relative

LINK_RE = re.compile(r'(!?)\[((?:[^\[\]]|\[[^\]]*\])*)\]\(([^)\s]+)(\s+"[^"]*")?\)')
HTML_RE = re.compile(r'\b(href|src)="([^"]+)"')
HEAD_RE = re.compile(r'^(#{1,6})\s+(.*?)\s*#*\s*$')
FENCE_RE = re.compile(r'^\s*(```|~~~)')


# --- helpers -------------------------------------------------------------------
def git_md_files(root):
    out = subprocess.check_output(["git", "ls-files", "*.md"], cwd=root).decode()
    return sorted(f for f in out.split("\n") if f and not f.startswith(".github/"))


def config_excludes(root):
    """exclude: list of _config.yml (simple parser - '  - entry' lines)."""
    ex, inside = [], False
    try:
        lines = open(os.path.join(root, "_config.yml"), encoding="utf-8").read().split("\n")
    except OSError:
        return ex
    for line in lines:
        if re.match(r'^exclude\s*:', line):
            inside = True
            continue
        if inside:
            m = re.match(r'^\s*-\s*["\']?([^"\']+?)["\']?\s*$', line)
            if m:
                ex.append(m.group(1))
            elif line.strip() and not line.startswith(" "):
                inside = False
    return ex


def is_excluded(path, excludes):
    for e in excludes:
        e = e.rstrip("/")
        if path == e or path.startswith(e + "/"):
            return True
    return False


def slug(text):
    """GitHub heading id (kramdown's GFM parser builds the same ids)."""
    t = re.sub(r'!?\[([^\]]*)\]\([^)]*\)', r'\1', text)      # links -> label
    # html tags are dropped - but not inside `code` (shown literally there)
    parts = t.split('`')
    t = ''.join(x if i % 2 else re.sub(r'<[^>]+>', '', x) for i, x in enumerate(parts))
    t = t.strip().lower()
    t = re.sub(r'[^\w\- ]', '', t)
    return t.replace(' ', '-')


_anchor_cache = {}


def anchors_of(path):
    if path in _anchor_cache:
        return _anchor_cache[path]
    ids, seen, fence = set(), {}, False
    try:
        lines = open(path, encoding="utf-8").read().split("\n")
    except OSError:
        lines = []
    for line in lines:
        if FENCE_RE.match(line):
            fence = not fence
            continue
        if fence:
            continue
        for m in re.finditer(r'<a\s+(?:name|id)="([^"]+)"', line):
            ids.add(m.group(1))
        m = HEAD_RE.match(line)
        if m:
            s = slug(m.group(2))
            n = seen.get(s, 0)
            ids.add(s if n == 0 else "%s-%d" % (s, n))
            seen[s] = n + 1
    _anchor_cache[path] = ids
    return ids


def has_front_matter(path):
    try:
        with open(path, encoding="utf-8") as fh:
            first = fh.readline().rstrip("\n")
            if first != "---":
                return None
            fm = []
            for line in fh:
                if line.rstrip("\n") == "---":
                    return fm
                fm.append(line)
    except OSError:
        pass
    return None


def iter_links(md):
    """(line_no, kind, target) for every relative link outside fenced code."""
    fence = False
    for no, line in enumerate(open(md, encoding="utf-8").read().split("\n"), 1):
        if FENCE_RE.match(line):
            fence = not fence
            continue
        if fence:
            continue
        for m in LINK_RE.finditer(line):
            yield no, ("image" if m.group(1) else "link"), m.group(3)
        for m in HTML_RE.finditer(re.sub(r'`[^`]*`', '', line)):   # not in `code`
            yield no, "html", m.group(2)


def classify(root, md, target, excludes):
    """List of (category, suggestion) for one link target; [] = fine."""
    if re.match(r'^[a-z][a-z0-9+.-]*:', target, re.I) or target.startswith("//"):
        return []                                           # absolute URL / mailto
    path, _, anchor = target.partition("#")
    path = path.split("?")[0]
    if not path:                                            # same-page anchor
        if anchor and anchor not in anchors_of(os.path.join(root, md)):
            return [("anchor", "#%s not in this file" % anchor)]
        return []
    rel = os.path.normpath(os.path.join(os.path.dirname(md), urllib.parse.unquote(path)))
    full = os.path.join(root, rel)
    frag = ("#" + anchor) if anchor else ""
    if not os.path.exists(full):
        return [("missing", rel)]
    res = []
    if os.path.isdir(full):
        if is_excluded(rel, excludes):
            res.append(("excluded", TREE + rel))
        elif not os.path.isfile(os.path.join(full, "README.md")):
            res.append(("folder", TREE + rel))
        return res
    if anchor and rel.endswith(".md") and anchor not in anchors_of(full):
        res.append(("anchor", "#%s not in %s" % (anchor, rel)))
    if is_excluded(rel, excludes):
        res.append(("excluded", BLOB + rel + frag))
    elif not rel.lower().endswith(PAGE_EXT + KEEP_EXT):
        res.append(("raw", BLOB + rel + frag))
    return res


# --- local check -------------------------------------------------------------------
def local_check(root, files, excludes):
    findings = []
    for md in files:
        # a file that is not on Pages itself (excluded) only needs links that
        # work on github.com: missing / anchor
        off_pages = is_excluded(md, excludes)
        for no, kind, target in iter_links(md):
            for cat, sug in classify(root, md, target, excludes):
                if off_pages and cat not in ("missing", "anchor"):
                    continue
                findings.append((md, no, cat, target, sug))
        base = os.path.basename(md)
        fm = has_front_matter(os.path.join(root, md))
        if base == "README.md" and fm is not None and md != "README.md" \
                and not any(l.startswith("permalink:") for l in fm):
            findings.append((md, 1, "permalink", "-", "permalink: /%s/" % os.path.dirname(md)))
    return findings


# --- rewrite ---------------------------------------------------------------------------
def fix_files(root, files, excludes, cats, apply):
    changed = 0
    stamp = datetime.datetime.now()
    bdir = os.path.join(root, "log", stamp.strftime("%Y-%m-%d"),
                        "check_pages_links_backup_" + stamp.strftime("%H%M%S"))
    for md in files:
        old = open(os.path.join(root, md), encoding="utf-8").read()
        lines, fence = old.split("\n"), False
        for i, line in enumerate(lines):
            if FENCE_RE.match(line):
                fence = not fence
                continue
            if fence:
                continue

            def rp(m):
                if m.group(1):                               # images stay
                    return m.group(0)
                for cat, sug in classify(root, md, m.group(3), excludes):
                    if cat in cats and sug.startswith("https://"):
                        return "[%s](%s%s)" % (m.group(2), sug, m.group(4) or "")
                return m.group(0)
            lines[i] = LINK_RE.sub(rp, line)
        new = "\n".join(lines)
        if new == old:
            continue
        changed += 1
        sys.stdout.writelines(difflib.unified_diff(
            old.splitlines(True), new.splitlines(True), "a/" + md, "b/" + md, n=0))
        if apply:
            os.makedirs(os.path.join(bdir, os.path.dirname(md)), exist_ok=True)
            shutil.copy2(os.path.join(root, md), os.path.join(bdir, md))
            open(os.path.join(root, md), "w", encoding="utf-8").write(new)
    print("\n%d file(s) %s" % (changed, "changed (backup: %s)" % bdir if apply and changed
                               else "would change (dry run - add --apply)"))
    return changed


# --- live check ---------------------------------------------------------------------------
class _Page(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.hrefs, self.ids = [], set()

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if a.get("id"):
            self.ids.add(a["id"])
        if tag == "a" and a.get("name"):
            self.ids.add(a["name"])
        if tag == "a" and a.get("href"):
            self.hrefs.append(a["href"])


def _get(url, cache):
    if url in cache:
        return cache[url]
    req = urllib.request.Request(url, headers={"User-Agent": "check_pages_links/" + VERSION})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            body = r.read()
            ctype = r.headers.get("Content-Type", "")
            res = (r.status, body.decode("utf-8", "replace") if "html" in ctype or "xml" in ctype else "")
    except urllib.error.HTTPError as e:
        res = (e.code, "")
    except (urllib.error.URLError, OSError) as e:
        res = (0, str(e))
    cache[url] = res
    return res


def live_check(site):
    cache = {}
    status, sm = _get(urllib.parse.urljoin(site, "sitemap.xml"), cache)
    if status != 200:
        print("sitemap.xml: HTTP %s" % status)
        return 2
    pages = re.findall(r'<loc>([^<]+)</loc>', sm)
    print("sitemap: %d pages" % len(pages))
    parsed, bad, checked = {}, [], 0
    for page in pages:
        st, body = _get(page, cache)
        if st != 200:
            bad.append((page, page, st))
            continue
        p = _Page()
        p.feed(body)
        parsed[page] = p
    for page, p in parsed.items():
        for href in p.hrefs:
            url = urllib.parse.urljoin(page, href)
            if not url.startswith(site):
                continue
            base, _, anchor = url.partition("#")
            checked += 1
            st, body = _get(base, cache)
            if st != 200:
                bad.append((page, href, st))
                continue
            if anchor:
                if base not in parsed and body:
                    q = _Page()
                    q.feed(body)
                    parsed[base] = q
                ids = parsed[base].ids if base in parsed else set()
                if ids and urllib.parse.unquote(anchor) not in ids:
                    bad.append((page, href, "anchor"))
    print("internal links checked: %d, targets: %d" % (checked, len(cache)))
    for page, href, st in bad:
        print("  %-7s %s  <- %s" % (st, href, page.replace(site, "/")))
    print("findings: %d" % len(bad))
    return 1 if bad else 0


# --- link `code` mentions ------------------------------------------------------------
CODE_RE = re.compile(r'`([^`\s]+)`')
TABLE_RE = re.compile(r'^\s*\|')
# never linked: ambiguous / not a page / everywhere
CODE_SKIP = {"README.md", "CHANGELOG.md", "TODO.md", "environment.conf", "SKILL.md"}
CODE_NO_SOURCE = ("CHANGELOG.md", "TODO.md")


def file_index(root):
    out = subprocess.check_output(["git", "ls-files"], cwd=root).decode().split("\n")
    by_base, paths = {}, set()
    for f in out:
        if not f:
            continue
        paths.add(f)
        by_base.setdefault(os.path.basename(f), []).append(f)
    return by_base, paths


def code_target(md, name, by_base, paths, excludes):
    """Repo path a code span `name` stands for - or None."""
    # bare dot files (.gitignore) mostly mean the reader's own file, not ours
    if name in CODE_SKIP or name.startswith(".") or name.endswith("/") \
            or "$" in name or "*" in name:
        return None
    if not re.search(r'\.[A-Za-z0-9]+$', name):          # file names only
        return None
    cand = None
    if "/" in name:
        for c in (os.path.normpath(os.path.join(os.path.dirname(md), name)), os.path.normpath(name)):
            if c in paths:
                cand = c
                break
    else:
        hits = by_base.get(name, [])
        if len(hits) == 1:
            cand = hits[0]
    if not cand or cand == md or os.path.basename(cand) in CODE_SKIP:
        return None
    return cand


def link_for(md, path, excludes):
    if path.endswith(".md") and not is_excluded(path, excludes):
        return os.path.relpath(path, os.path.dirname(md) or ".").replace(os.sep, "/")
    if path.lower().endswith(KEEP_EXT) and not is_excluded(path, excludes):
        return os.path.relpath(path, os.path.dirname(md) or ".").replace(os.sep, "/")
    return BLOB + path


def link_code(root, files, excludes, apply):
    by_base, paths = file_index(root)
    changed, total = 0, 0
    stamp = datetime.datetime.now()
    bdir = os.path.join(root, "log", stamp.strftime("%Y-%m-%d"),
                        "check_pages_links_code_" + stamp.strftime("%H%M%S"))
    for md in files:
        if md.endswith(CODE_NO_SOURCE) or os.path.basename(md) == "SKILL.md" \
                or is_excluded(md, excludes):
            continue
        old = open(os.path.join(root, md), encoding="utf-8").read()
        lines, fence, pre, seen = old.split("\n"), False, False, set()
        for i, line in enumerate(lines):
            if FENCE_RE.match(line):
                fence = not fence
                continue
            if "<pre" in line:
                pre = True
            if "</pre>" in line:
                pre = False
                continue
            if fence or pre:
                continue
            if HEAD_RE.match(line):
                seen = set()                                  # new section
                continue
            table = bool(TABLE_RE.match(line))
            row_seen = set()
            # names already linked on this line count as mentioned
            spans = [(m.start(), m.end()) for m in LINK_RE.finditer(line)]
            for m in LINK_RE.finditer(line):
                for c in CODE_RE.finditer(m.group(2)):
                    t = code_target(md, c.group(1), by_base, paths, excludes)
                    if t:
                        (row_seen if table else seen).add(t)
            out, pos = [], 0
            for c in CODE_RE.finditer(line):
                if any(a <= c.start() < b for a, b in spans):
                    continue
                t = code_target(md, c.group(1), by_base, paths, excludes)
                if not t:
                    continue
                bucket = row_seen if table else seen
                if t in bucket:
                    continue
                bucket.add(t)
                out.append(line[pos:c.start()])
                out.append("[%s](%s)" % (c.group(0), link_for(md, t, excludes)))
                pos = c.end()
                total += 1
            if out:
                out.append(line[pos:])
                lines[i] = "".join(out)
        new = "\n".join(lines)
        if new == old:
            continue
        changed += 1
        sys.stdout.writelines(difflib.unified_diff(
            old.splitlines(True), new.splitlines(True), "a/" + md, "b/" + md, n=0))
        if apply:
            os.makedirs(os.path.join(bdir, os.path.dirname(md)), exist_ok=True)
            shutil.copy2(os.path.join(root, md), os.path.join(bdir, md))
            open(os.path.join(root, md), "w", encoding="utf-8").write(new)
    print("\n%d link(s) in %d file(s) %s" % (total, changed, "written (backup: %s)" % bdir
                                             if apply and changed else "(dry run - add --apply)"))
    return changed


# --- main ------------------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="Link check for github.com + GitHub Pages")
    ap.add_argument("files", nargs="*", help="only these .md files (default: all)")
    ap.add_argument("--live", action="store_true", help="check the published site")
    ap.add_argument("--site", default=SITE)
    ap.add_argument("--fix", help="rewrite categories: raw,folder,excluded")
    ap.add_argument("--link-code", action="store_true",
                    help="link the first `file` mention per section (every table row)")
    ap.add_argument("--apply", action="store_true", help="write the rewrite")
    ap.add_argument("--category", help="show only these categories (comma list)")
    a = ap.parse_args()

    root = subprocess.check_output(["git", "rev-parse", "--show-toplevel"]).decode().strip()
    os.chdir(root)
    if a.live:
        return live_check(a.site)
    excludes = config_excludes(root)
    files = a.files or git_md_files(root)
    if a.link_code:
        link_code(root, files, excludes, a.apply)
        return 0
    if a.fix:
        cats = set(a.fix.split(","))
        fix_files(root, files, excludes, cats, a.apply)
        return 0

    findings = local_check(root, files, excludes)
    if a.category:
        keep = set(a.category.split(","))
        findings = [f for f in findings if f[2] in keep]
    print("check_pages_links.py %s - %d files, exclude: %s\n" % (VERSION, len(files), ", ".join(excludes)))
    last = None
    for md, no, cat, target, sug in findings:
        if md != last:
            print(md)
            last = md
        print("  %5d  %-9s %s\n                   -> %s" % (no, cat, target, sug))
    counts = {}
    for f in findings:
        counts[f[2]] = counts.get(f[2], 0) + 1
    print("\nfindings: %d  %s" % (len(findings), "  ".join("%s=%d" % kv for kv in sorted(counts.items()))))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
