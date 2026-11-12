#!/usr/bin/env python3
# =============================================================================
# Script   : render_ascii.py
# Purpose  : Render marked ASCII diagrams of Markdown files additionally as SVG.
#            Block marker:   ```ascii?name=<name>  (old form ```ascii name=<name>
#                            is still read and rewritten - kramdown / GitHub
#                            Pages takes only '<lang>?...' after the backticks)
#            Engine d2 (default): ASCII + STYLE -> diagrams/<name>.prompt ->
#              LLM -> diagrams/<name>.d2 -> "d2 --layout dagre|elk" -> <name>.svg
#            Engine svgbob: ASCII -> svgbob -> <name>.svg (no LLM)
#            The MD gets the image link + a source line (link to the .prompt)
#            in front of the block; the ASCII block is folded into
#            <details markdown="block"><summary>ASCII version</summary>
#            (markdown="block": kramdown parses the fenced block inside,
#            so a <placeholder> in the ASCII cannot swallow the page). Idempotent.
#            Unmarked blocks that look like a diagram are only reported.
# Call     : render_ascii.py --file X.md | --all  [--engine d2|svgbob]
#                            [--force] [--dry-run]
# Config   : tools/render_ascii/render_ascii.conf (KEY=VALUE, git-ignored) or
#            environment: RENDER_ASCII_PROVIDER claude-cli|manual|anthropic|azure,
#            RENDER_ASCII_MODEL, RENDER_ASCII_LAYOUT dagre|elk, CLAUDE_BIN, ANTHROPIC_API_KEY (env only),
#            AZURE_AI_URL, AZURE_AI_FORMAT openai|anthropic, AZURE_AI_KEY (env
#            only), AZURE_AI_DEPLOYMENT; RENDER_ASCII_FAKE_LLM=<file> (tests)
# Requires : python3 (stdlib only), d2 (engine d2), svgbob (engine svgbob),
#            claude CLI (provider claude-cli)
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref      : tools/render_ascii/README.md
# =============================================================================
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.abspath(os.path.join(TOOL_DIR, "..", ".."))
STYLE_DEFAULT = os.path.join(TOOL_DIR, "style_default.txt")
CONF_FILE = os.path.join(TOOL_DIR, "render_ascii.conf")

FENCE_RE = re.compile(r"^(\s*)(`{3,})(.*)$")
MARK_RE = re.compile(r"^ascii(?:\s+|\?)name=([a-z0-9][a-z0-9_-]*)\s*$")
BOXY_RE = re.compile(r"(\+-{2,}|-{2,}\+|[┌┐└┘├┤┬┴┼─│═║╔╗╚╝▶◀▼▲]|-->|<--|==>|-{3,}>)")
SUMMARY = '<details markdown="block"><summary>ASCII version</summary>'
# older wrappers (without markdown="block" until 2026-11-12, German until
# 2026-11-11) are still recognised and rewritten
BLOB_URL = "https://github.com/gpipperr/IHateWeblogic/blob/main/"
SUMMARIES = (SUMMARY, "<details><summary>ASCII version</summary>",
             "<details><summary>ASCII-Version</summary>")

COUNT = {"OK": 0, "WARN": 0, "FAIL": 0}
LOG_FH = None


# --- output -------------------------------------------------------------------
def _out(tag, msg, color):
    line = "  %-4s  %s" % (tag, msg)
    if sys.stdout.isatty():
        print("\033[%sm  %-4s\033[0m  %s" % (color, tag, msg))
    else:
        print(line)
    if LOG_FH:
        LOG_FH.write(line + "\n")


def ok(m):
    COUNT["OK"] += 1
    _out("OK", m, "32")


def warn(m):
    COUNT["WARN"] += 1
    _out("WARN", m, "33")


def fail(m):
    COUNT["FAIL"] += 1
    _out("FAIL", m, "31")


def info(m):
    _out("", m, "34")


# --- config -------------------------------------------------------------------
def load_conf():
    conf = {}
    if os.path.isfile(CONF_FILE):
        with open(CONF_FILE, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                if k.endswith("_KEY"):          # keys only from the environment
                    continue
                conf[k] = v.strip().strip('"').strip("'")
    for k, v in os.environ.items():           # environment wins
        if k.startswith(("RENDER_ASCII_", "AZURE_AI_", "ANTHROPIC_")) or k == "CLAUDE_BIN":
            conf[k] = v
    conf.setdefault("RENDER_ASCII_PROVIDER", "claude-cli")
    # dagre places connection labels as layout objects (no overlap of the
    # labels of converging arrows); elk stays selectable (2026-11-10)
    conf.setdefault("RENDER_ASCII_LAYOUT", "dagre")
    return conf


# --- helpers ------------------------------------------------------------------
def sha256(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def which(names):
    for n in names:
        p = shutil.which(n) or (os.path.expanduser("~/.local/bin/" + n)
                                if os.path.isfile(os.path.expanduser("~/.local/bin/" + n)) else None)
        if p:
            return p
    return None


def tracked_md_files():
    try:
        out = subprocess.run(["git", "-C", REPO_DIR, "ls-files", "*.md"],
                             capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        fail("git ls-files failed – run inside the repository")
        return []
    return [os.path.join(REPO_DIR, f) for f in out.splitlines()
            if "customer-analyse/" not in f]


# --- Markdown parsing ---------------------------------------------------------
def parse_blocks(lines):
    """Return fenced blocks: dict(start, end, info, indent, fence, body)."""
    blocks, i = [], 0
    while i < len(lines):
        m = FENCE_RE.match(lines[i])
        if m:
            indent, fence, info_s = m.group(1), m.group(2), m.group(3).strip()
            j = i + 1
            while j < len(lines):
                m2 = FENCE_RE.match(lines[j])
                if m2 and m2.group(2).startswith(fence[0] * len(fence)) and not m2.group(3).strip():
                    break
                j += 1
            blocks.append({"start": i, "end": j, "info": info_s, "indent": indent,
                           "fence": fence, "body": lines[i + 1:j]})
            i = j + 1
        else:
            i += 1
    return blocks


def looks_like_diagram(block):
    if block["info"] not in ("", "text", "txt", "none"):
        return False
    hits = sum(1 for b in block["body"] if BOXY_RE.search(b))
    return hits >= 3 and len(block["body"]) >= 4


def img_ref(md_path, name):
    """Image line with ?v=<first 8 hex of the SVG's SHA-256> - a changed SVG
    gets a new URL, so browsers and GitHub's image proxy load it again."""
    f_svg = os.path.join(os.path.dirname(md_path), "diagrams", name + ".svg")
    if os.path.isfile(f_svg):
        with open(f_svg, "rb") as fh:
            v = hashlib.sha256(fh.read()).hexdigest()[:8]
        return "![%s](diagrams/%s.svg?v=%s)" % (name, name, v)
    return "![%s](diagrams/%s.svg)" % (name, name)


def wrapper_state(lines, b, name):
    """Is the block already wrapped?
    Returns (img_line_idx or None, wrapped bool, summary_line_idx or None)."""
    img_re = re.compile(r"^!\[%s\]\(diagrams/%s\.svg(\?v=[0-9a-f]+)?\)$"
                        % (re.escape(name), re.escape(name)))
    k = b["start"] - 1
    while k >= 0 and not lines[k].strip():
        k -= 1
    if k >= 0 and lines[k].strip() in SUMMARIES:
        # look upwards for the image line (source line in between)
        for kk in range(k - 1, max(-1, k - 6), -1):
            if img_re.match(lines[kk].strip()):
                return kk, True, k
        return None, True, k
    return None, False, None


# --- prompt -------------------------------------------------------------------
def style_for(md_path, name):
    d = os.path.join(os.path.dirname(md_path), "diagrams")
    for p in (os.path.join(d, name + ".style"), os.path.join(d, "_style.txt"), STYLE_DEFAULT):
        if os.path.isfile(p):
            return read(p).rstrip("\n")
    return ""


def build_prompt(style, ascii_text):
    return "### STYLE\n%s\n\n### ASCII\n%s\n" % (style, ascii_text)


def split_prompt(text):
    m = re.search(r"^### STYLE\n(.*?)\n\n### ASCII\n(.*)$", text, re.S | re.M)
    if not m:
        return None, None
    return m.group(1), m.group(2).rstrip("\n")


def read_state(path):
    st = {}
    if os.path.isfile(path):
        for line in read(path).splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[0] in ("prompt", "ascii", "layout"):
                st[parts[0]] = parts[1]
            elif len(parts) == 1 and re.fullmatch(r"[0-9a-f]{64}", parts[0]):
                st["prompt"] = parts[0]
    return st


def write_state(path, prompt_sha, ascii_sha, layout="-"):
    write(path, "prompt %s\nascii %s\nlayout %s\n" % (prompt_sha, ascii_sha, layout))


# --- LLM ----------------------------------------------------------------------
def strip_fence(text):
    t = text.strip()
    m = re.match(r"^```[a-zA-Z0-9]*\n(.*?)\n```$", t, re.S)
    return (m.group(1) if m else t).strip() + "\n"


def http_json(url, headers, body, timeout=300):
    req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"),
                                 headers=dict(headers, **{"content-type": "application/json"}))
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def ask_llm(conf, prompt):
    """Return D2 text or raise RuntimeError."""
    fake = conf.get("RENDER_ASCII_FAKE_LLM")
    if fake:
        files = [f for f in fake.split(":") if f]
        n = conf.setdefault("_fake_n", 0)
        conf["_fake_n"] = n + 1
        return strip_fence(read(files[min(n, len(files) - 1)]))
    prov = conf["RENDER_ASCII_PROVIDER"]
    model = conf.get("RENDER_ASCII_MODEL", "")
    if prov == "claude-cli":
        cbin = conf.get("CLAUDE_BIN") or which(["claude"])
        if not cbin:
            raise RuntimeError("claude CLI not found (CLAUDE_BIN or PATH)")
        cmd = [cbin, "-p", "--output-format", "text"]
        if model:
            cmd += ["--model", model]
        r = subprocess.run(cmd, input=prompt, capture_output=True, text=True,
                           timeout=int(conf.get("RENDER_ASCII_TIMEOUT", "600")))
        if r.returncode != 0 or not r.stdout.strip():
            raise RuntimeError("claude -p rc=%s: %s" % (r.returncode, (r.stderr or r.stdout).strip()[:300]))
        return strip_fence(r.stdout)
    if prov == "anthropic":
        key = os.environ.get("ANTHROPIC_API_KEY")
        if not key:
            raise RuntimeError("ANTHROPIC_API_KEY not set (environment only)")
        d = http_json("https://api.anthropic.com/v1/messages",
                      {"x-api-key": key, "anthropic-version": "2023-06-01"},
                      {"model": model or "claude-sonnet-5-5", "max_tokens": 8000,
                       "messages": [{"role": "user", "content": prompt}]})
        return strip_fence("".join(c.get("text", "") for c in d.get("content", [])))
    if prov == "azure":
        key, url = os.environ.get("AZURE_AI_KEY"), conf.get("AZURE_AI_URL")
        if not key or not url:
            raise RuntimeError("AZURE_AI_URL (conf/env) and AZURE_AI_KEY (env) required")
        fmt = conf.get("AZURE_AI_FORMAT", "openai")
        dep = conf.get("AZURE_AI_DEPLOYMENT", model)
        if fmt == "anthropic":
            d = http_json(url, {"x-api-key": key, "api-key": key, "anthropic-version": "2023-06-01"},
                          {"model": dep, "max_tokens": 8000,
                           "messages": [{"role": "user", "content": prompt}]})
            return strip_fence("".join(c.get("text", "") for c in d.get("content", [])))
        d = http_json(url, {"api-key": key, "authorization": "Bearer " + key},
                      {"model": dep, "max_tokens": 8000,
                       "messages": [{"role": "user", "content": prompt}]})
        return strip_fence(d["choices"][0]["message"]["content"])
    raise RuntimeError("unknown provider: %s" % prov)


# --- render -------------------------------------------------------------------
def d2_render(d2bin, d2file, svgfile, layout="dagre"):
    r = subprocess.run([d2bin, "--layout", layout, d2file, svgfile],
                       capture_output=True, text=True, timeout=300)
    if r.returncode == 0 and os.path.isfile(svgfile):
        os.chmod(svgfile, 0o644)            # d2 writes 0600 – repo files are 0644
    return r.returncode == 0, (r.stderr + r.stdout).strip()


def svgbob_render(sbin, ascii_text, svgfile):
    r = subprocess.run([sbin], input=ascii_text, capture_output=True, text=True, timeout=120)
    if r.returncode == 0 and "<svg" in r.stdout:
        write(svgfile, r.stdout)
        return True, ""
    return False, (r.stderr or r.stdout).strip()


# --- per block ----------------------------------------------------------------
def process_block(md_path, lines, b, name, args, conf, tools):
    """Returns (changed_lines or None). Writes diagram files unless dry-run."""
    rel = os.path.relpath(md_path, REPO_DIR)
    ddir = os.path.join(os.path.dirname(md_path), "diagrams")
    f_prompt, f_sha = os.path.join(ddir, name + ".prompt"), os.path.join(ddir, name + ".sha256")
    f_d2, f_svg = os.path.join(ddir, name + ".d2"), os.path.join(ddir, name + ".svg")
    ascii_text = "\n".join(b["body"])
    st = read_state(f_sha)
    tag = "%s:%d %s" % (rel, b["start"] + 1, name)

    if args.engine == "svgbob":
        a_sha = sha256(ascii_text)
        if not args.force and st.get("ascii") == a_sha and os.path.isfile(f_svg):
            ok("%s – unchanged, skipped" % tag)
            return ascii_text
        if args.dry_run:
            info("%s – would render with svgbob -> diagrams/%s.svg" % (tag, name))
            return None
        good, err = svgbob_render(tools["svgbob"], ascii_text, f_svg)
        if not good:
            fail("%s – svgbob: %s" % (tag, err[:300]))
            return None
        write_state(f_sha, st.get("prompt", "-"), a_sha)
        ok("%s – svgbob -> diagrams/%s.svg" % (tag, name))
        return ascii_text

    # engine d2: which side is the source – MD block or hand-edited .prompt?
    expected = build_prompt(style_for(md_path, name), ascii_text)
    prompt = expected
    if os.path.isfile(f_prompt):
        current = read(f_prompt)
        if current != expected:
            p_edited = st.get("prompt") and sha256(current) != st.get("prompt")
            a_edited = st.get("ascii") and sha256(ascii_text) != st.get("ascii")
            if p_edited and a_edited:
                fail("%s – both diagrams/%s.prompt and the ASCII in the MD were changed – "
                     "keep one change, then run again" % (tag, name))
                return None
            if p_edited:
                p_style, p_ascii = split_prompt(current)
                if p_ascii is None:
                    fail("%s – diagrams/%s.prompt has no '### STYLE' / '### ASCII' sections" % (tag, name))
                    return None
                warn("%s – diagrams/%s.prompt was edited by hand: used as source, "
                     "its ASCII is written back into the MD" % (tag, name))
                prompt, ascii_text = current, p_ascii
                if p_style != style_for(md_path, name) and not args.dry_run:
                    write(os.path.join(ddir, name + ".style"), p_style + "\n")
                    info("%s – own STYLE kept in diagrams/%s.style" % (tag, name))
    p_sha, a_sha = sha256(prompt), sha256(ascii_text)

    d2_hand = (os.path.isfile(f_d2) and os.path.isfile(f_sha)
               and os.path.getmtime(f_d2) > os.path.getmtime(f_sha) + 1)
    layout = conf["RENDER_ASCII_LAYOUT"]
    if not args.force and st.get("prompt") == p_sha and os.path.isfile(f_svg) and not d2_hand:
        if st.get("layout", layout) == layout:
            ok("%s – unchanged, skipped" % tag)
            return ascii_text
        # only the layout engine changed: render the existing .d2 again, no LLM
        if args.dry_run:
            info("%s – would re-render with layout %s (no LLM)" % (tag, layout))
            return None
        good, err = d2_render(tools["d2"], f_d2, f_svg, layout)
        if not good:
            fail("%s – d2 (%s) failed: %s" % (tag, layout, err[:300]))
            return None
        write_state(f_sha, p_sha, a_sha, layout)
        ok("%s – re-rendered with layout %s" % (tag, layout))
        return ascii_text
    if args.dry_run:
        what = ("render the hand-edited .d2" if d2_hand and not args.force
                else "prompt -> %s -> d2 -> svg" % conf["RENDER_ASCII_PROVIDER"])
        info("%s – would %s (diagrams/%s.*)" % (tag, what, name))
        return None

    write(f_prompt, prompt)
    if d2_hand and not args.force:
        warn("%s – diagrams/%s.d2 is newer than its .sha256 (edited by hand): "
             "not regenerated (use --force), rendering it" % (tag, name))
    elif conf["RENDER_ASCII_PROVIDER"] == "manual":
        if not os.path.isfile(f_d2) or st.get("prompt") != p_sha:
            warn("%s – provider manual: write diagrams/%s.d2 from the .prompt, then run again" % (tag, name))
            return None
    else:
        try:
            write(f_d2, ask_llm(conf, prompt))
        except (RuntimeError, OSError, urllib.error.URLError, subprocess.TimeoutExpired, KeyError) as e:
            fail("%s – LLM: %s" % (tag, e))
            return None
    good, err = d2_render(tools["d2"], f_d2, f_svg, conf["RENDER_ASCII_LAYOUT"])
    if not good and not (d2_hand and not args.force) and conf["RENDER_ASCII_PROVIDER"] != "manual":
        first = next((x for x in err.splitlines() if "err" in x.lower()), err.splitlines()[0] if err else "")
        warn("%s – d2 failed, asking the LLM once for a fix: %s" % (tag, first.strip()[:200]))
        fix = ("%s\n\n### PREVIOUS D2 (failed)\n%s\n### D2 ERROR\n%s\n\n"
               "Fix the D2 code. Output ONLY the corrected D2 code.\n"
               % (prompt, read(f_d2), err[:2000]))
        try:
            write(f_d2, ask_llm(conf, fix))
            good, err = d2_render(tools["d2"], f_d2, f_svg, conf["RENDER_ASCII_LAYOUT"])
        except (RuntimeError, OSError, urllib.error.URLError, subprocess.TimeoutExpired, KeyError) as e:
            good, err = False, "LLM: %s" % e
    if not good:
        fail("%s – d2 failed, MD unchanged for this block: %s" % (tag, err[:400]))
        return None
    write_state(f_sha, p_sha, a_sha, layout)
    ok("%s – diagrams/%s.svg written" % (tag, name))
    return ascii_text


def head_lines(md_path, b, name, engine="d2"):
    """Image line, source line, blank, summary - the part above the block."""
    ind = b["indent"]
    if engine == "svgbob":
        src = ind + "<sub>Source: ASCII version below (svgbob)</sub>"
    else:
        # absolute GitHub view: on GitHub Pages a relative .prompt / .d2 link
        # would be served as a raw file / download (the SVG stays relative)
        d = os.path.relpath(os.path.join(os.path.dirname(os.path.abspath(md_path)), "diagrams"), REPO_DIR)
        base = BLOB_URL + d.replace(os.sep, "/") + "/"
        src = (ind + "<sub>Source: [diagrams/%s.prompt](%s%s.prompt) · "
               "[D2](%s%s.d2)</sub>" % (name, base, name, base, name))
    return [ind + img_ref(md_path, name), src, "", ind + SUMMARY]


def wrap_lines(md_path, lines, b, name, ascii_text, engine="d2"):
    """Edits for block b: (start, end, new_lines) - the head (image with ?v=,
    source line, summary) and the block body."""
    ind, fence = b["indent"], b["fence"]
    img_idx, wrapped, sum_idx = wrapper_state(lines, b, name)
    body = ascii_text.split("\n")
    # marker always in the kramdown-safe form ```ascii?name=<name>
    info = "ascii?name=%s" % name
    block = [ind + fence + info] + body + [ind + fence]
    head = head_lines(md_path, b, name, engine)
    if not wrapped:
        tail = ["", ind + "</details>"]
        return [(b["start"], b["end"] + 1, head + [""] + block + tail)]
    edits = []
    if body != b["body"] or b["info"] != info:
        edits.append((b["start"], b["end"] + 1, block))
    if img_idx is not None and lines[img_idx:sum_idx + 1] != head:
        edits.append((img_idx, sum_idx + 1, head))
    return edits


# --- main ---------------------------------------------------------------------
def main():
    global LOG_FH
    ap = argparse.ArgumentParser(description="Render marked ASCII diagrams in Markdown as SVG")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--file", help="one Markdown file")
    g.add_argument("--all", action="store_true", help="all git-tracked Markdown files")
    ap.add_argument("--engine", choices=["d2", "svgbob"], default="d2")
    ap.add_argument("--force", action="store_true", help="ignore hashes and hand edits of .d2")
    ap.add_argument("--dry-run", action="store_true", help="show what would happen, write nothing")
    args = ap.parse_args()

    conf = load_conf()
    logdir = os.path.join(REPO_DIR, "log", datetime.date.today().strftime("%Y%m%d"))
    if not args.dry_run:
        os.makedirs(logdir, exist_ok=True)
        LOG_FH = open(os.path.join(logdir, "render_ascii_%s_%d.log" % (
            datetime.datetime.now().strftime("%H%M%S"), os.getpid())), "w", encoding="utf-8")

    print("render_ascii – engine %s, provider %s, layout %s%s%s" % (
        args.engine, conf["RENDER_ASCII_PROVIDER"] if args.engine == "d2" else "-",
        conf["RENDER_ASCII_LAYOUT"] if args.engine == "d2" else "-",
        ", dry-run" if args.dry_run else "", ", force" if args.force else ""))
    tools = {"d2": which(["d2"]), "svgbob": which(["svgbob", "svgbob_cli"])}
    if args.engine == "d2" and not tools["d2"]:
        fail("d2 not found – install: release binary from https://github.com/d2lang/d2/releases "
             "(d2-<v>-linux-amd64.tar.gz, bin/d2 -> ~/.local/bin/d2)")
        return 2
    if args.engine == "svgbob" and not tools["svgbob"]:
        fail("svgbob not found – install: cargo install svgbob_cli (Rust toolchain via rustup), "
             "binary to ~/.local/bin")
        return 2
    if args.engine == "d2" and not args.dry_run:
        prov = conf["RENDER_ASCII_PROVIDER"]
        if prov == "claude-cli" and not (conf.get("CLAUDE_BIN") or which(["claude"])):
            fail("provider claude-cli: claude CLI not found (set CLAUDE_BIN)")
            return 2
        if prov == "anthropic" and not os.environ.get("ANTHROPIC_API_KEY"):
            fail("provider anthropic: ANTHROPIC_API_KEY not set (environment only)")
            return 2
        if prov == "azure" and not (os.environ.get("AZURE_AI_KEY") and conf.get("AZURE_AI_URL")):
            fail("provider azure: AZURE_AI_URL and AZURE_AI_KEY (environment) required")
            return 2

    files = tracked_md_files() if args.all else [os.path.abspath(args.file)]
    candidates = 0
    for md in files:
        if not os.path.isfile(md):
            fail("not found: %s" % md)
            continue
        lines = read(md).split("\n")
        blocks = parse_blocks(lines)
        names = {}
        edits = []
        for b in blocks:
            m = MARK_RE.match(b["info"])
            if not m:
                if looks_like_diagram(b):
                    candidates += 1
                    first = next((x.strip() for x in b["body"] if x.strip()), "")[:60]
                    info("candidate (unmarked) %s:%d  %s" % (os.path.relpath(md, REPO_DIR),
                                                             b["start"] + 1, first))
                continue
            name = m.group(1)
            if name in names:
                fail("%s: name '%s' used twice (lines %d and %d)" % (
                    os.path.relpath(md, REPO_DIR), name, names[name] + 1, b["start"] + 1))
                continue
            names[name] = b["start"]
            new_ascii = process_block(md, lines, b, name, args, conf, tools)
            if new_ascii is None:
                continue
            edits.extend(wrap_lines(md, lines, b, name, new_ascii, args.engine))
        if edits and args.dry_run:
            info("%s – would update %d place(s) in the MD (image ?v= / source line / block)"
                 % (os.path.relpath(md, REPO_DIR), len(edits)))
        if edits and not args.dry_run:
            for s, e, new in sorted(edits, reverse=True):
                lines[s:e] = new
            bdir = os.path.join(logdir, "render_ascii_backup")
            os.makedirs(bdir, exist_ok=True)
            bak = os.path.join(bdir, os.path.relpath(md, REPO_DIR).replace("/", "__") +
                               ".bak_" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))
            shutil.copy2(md, bak)
            write(md, "\n".join(lines))
            ok("%s – updated (%d block(s)), backup %s" % (os.path.relpath(md, REPO_DIR),
                                                          len(edits), os.path.relpath(bak, REPO_DIR)))
    print("\nSummary: OK %d  WARN %d  FAIL %d  unmarked candidates %d" % (
        COUNT["OK"], COUNT["WARN"], COUNT["FAIL"], candidates))
    if LOG_FH:
        LOG_FH.close()
    return 2 if COUNT["FAIL"] else (1 if COUNT["WARN"] else 0)


if __name__ == "__main__":
    sys.exit(main())
