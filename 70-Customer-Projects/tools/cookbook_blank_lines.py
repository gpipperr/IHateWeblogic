#!/usr/bin/env python3
# Author: Gunther Pipperr | https://pipperr.de | License: Apache 2.0
"""cookbook_blank_lines.py - insert a blank line after every shell command in
a cookbook .txt (rule since 2026-11-03: easier to read at the customer).
Call: python3 -I 70-Customer-Projects/tools/cookbook_blank_lines.py <file.txt> ...
Only blank lines are added - the text itself is never changed. Shell syntax
only (not for Windows cmd cookbooks).
A command = indented line whose first token is a known command, a variable
assignment, a $-path / ./script / *.sh call. Multi-line units (\\ | && ||
continuation, for/while/if blocks, heredocs, { } functions) stay together;
explaining comments right after a command (# Erwartet, #   indented ...) stay
attached. Prose, tables and comments are not touched."""
import re, sys
CMDS = set("""cd export grep echo ls unzip mkdir tar systemctl ps diff . dnf cp nm touch sed vi read unset
python3 cat rm mv nohup ln chmod chown find curl sudo su kill t java keytool readlink sha256sum df du
free head tail awk which rpm id ss openssl source mfontchk zip ldd test true false printf""".split())
def first(l): return l.strip().split()[0] if l.strip() else ''
def is_cmd(l):
    s = l.strip()
    if not l.startswith('  ') or not s or s.startswith('#'): return False
    if re.match(r'^[=\-]{5,}', s): return False
    t = first(l)
    if t in CMDS or t in ('for', 'while', 'if', 'until', '['): return True
    if re.match(r'^[A-Za-z_][A-Za-z0-9_]*=\S', s):
        return not re.search(r'\S\s{3,}[^#\s]', s)            # table row like "cn=Admin   text"
    if t.startswith('$') or t.startswith('"$') or t.startswith('./'): return True
    if t.startswith('/') and t.endswith('.sh'): return True
    if re.match(r'^[A-Za-z_][A-Za-z0-9_]*\(\)', s): return True      # function definition
    return False
def belongs(l):
    s = l.strip()
    return s.startswith('#') and (re.match(r'^#\s{2,}', s) or re.match(r'^#\s*(Erwartet|Zeigt|Steht|Normal|Pruefen|Kontrolle|Ergebnis|"|-> |=> )', s))
def unit_end(L, i):
    """index of the last line of the unit starting at i"""
    s = L[i]
    m = re.search(r"<<-?\s*'?\"?([A-Za-z_]+)'?\"?", s)
    if m:
        tag = m.group(1); j = i + 1
        while j < len(L) and L[j].strip() != tag: j += 1
        return min(j, len(L) - 1)
    depth = 0; j = i
    while j < len(L):
        t = first(L[j]); st = L[j].strip()
        if t in ('for', 'while', 'until') or (t == 'if' and not st.endswith('fi')): depth += 1
        if st.rstrip(';').endswith('{') and not st.endswith('}'): depth += 1
        if t in ('done', 'fi') or st.startswith('done ') or st == '}' : depth -= 1
        cont = re.search(r'(\\|\||&&|\|\|)\s*$', L[j].rstrip())
        if depth <= 0 and not cont: return j
        j += 1
    return len(L) - 1
def fmt(text):
    L = text.split('\n'); out = []; i = 0
    while i < len(L):
        if is_cmd(L[i]):
            e = unit_end(L, i)
            out.extend(L[i:e + 1]); i = e + 1
            ind = len(L[e]) - len(L[e].lstrip())
            prev = None
            while i < len(L) and L[i].strip().startswith('#'):
                c = L[i]; cind = len(c) - len(c.lstrip())
                if cind > ind + 8:                      # continues an end-of-line comment
                    pass
                elif belongs(c):
                    pass
                elif not re.match(r'^#\s*(-{3}|\d+\.\d+|[a-z]\))', c.strip()):
                    pass                                # comment block right under the command explains it
                else:
                    break
                out.append(c); prev = c; i += 1
            if i < len(L) and L[i].strip() != '':
                out.append('')
        else:
            out.append(L[i]); i += 1
    return '\n'.join(out)
for p in sys.argv[1:]:
    s = open(p, encoding='utf-8').read(); n = fmt(s)
    if n != s: open(p, 'w', encoding='utf-8').write(n)
    print(p, n.count('\n') - s.count('\n'), 'lines added')
