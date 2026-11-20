"""Development step 2: the security rules of the GUI (concept section 7).

No inline code, no innerHTML / eval, no inline styles, no external resources -
so the strict CSP of the Nginx include (concept section 6) never needs to be
weakened. Checked statically over 11-wlsmon/www/.
"""
import os
import re
import unittest

from tests.helpers import BASE

WWW = os.path.join(BASE, "www")

JS_FORBIDDEN = [
    (r"\.innerHTML\s*=|\.outerHTML\s*=|insertAdjacentHTML", "HTML string injection"),
    (r"\beval\s*\(", "eval"),
    (r"new\s+Function\s*\(", "new Function"),
    (r"document\.write", "document.write"),
    (r"setAttribute\(\s*['\"]style['\"]", "style attribute (CSP style-src)"),
    (r"setAttribute\(\s*['\"]on[a-z]+['\"]", "inline event handler"),
    (r"setTimeout\(\s*['\"]|setInterval\(\s*['\"]", "string timer (eval)"),
    (r"https?://(?!www\.w3\.org/2000/svg)", "external URL"),
    (r"=>|`", "ES6 syntax (the GUI stays plain ES5)"),
]
HTML_FORBIDDEN = [
    (r"<script(?![^>]*\bsrc=)[^>]*>", "inline script"),
    (r"\son[a-z]+\s*=", "inline event handler"),
    (r"\sstyle\s*=", "inline style"),
    (r"<style", "style element"),
    (r"javascript:", "javascript: URL"),
    (r"(src|href)\s*=\s*\"https?://(?!github\.com/gpipperr/IHateWeblogic\")", "external resource"),
]


def files(ext):
    for root, _dirs, names in os.walk(WWW):
        for n in sorted(names):
            if n.endswith(ext):
                yield os.path.join(root, n)


def strip_js_comments(src):
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return re.sub(r"(^|[^:\\])//[^\n]*", r"\1", src)


class GuiRulesTest(unittest.TestCase):

    def test_js(self):
        found = []
        for p in files(".js"):
            with open(p, encoding="utf-8") as fh:
                src = strip_js_comments(fh.read())
            for pat, why in JS_FORBIDDEN:
                for m in re.finditer(pat, src):
                    line = src.count("\n", 0, m.start()) + 1
                    found.append("%s:%d %s" % (os.path.relpath(p, BASE), line, why))
        self.assertEqual(found, [])

    def test_html(self):
        found = []
        for p in files(".html"):
            with open(p, encoding="utf-8") as fh:
                src = fh.read()
            for pat, why in HTML_FORBIDDEN:
                if re.search(pat, src, flags=re.I):
                    found.append("%s: %s" % (os.path.relpath(p, BASE), why))
        self.assertEqual(found, [])

    def test_ui_json_default(self):
        """The repository ui.json carries only the locale - library paths are
        written by 01-install-wlsmon_fmw.sh on the host."""
        import json
        with open(os.path.join(WWW, "ui.json"), encoding="utf-8") as fh:
            ui = json.load(fh)
        self.assertEqual(sorted(ui), ["locale"])

    def test_no_demo_data_in_www(self):
        self.assertFalse(os.path.isdir(os.path.join(WWW, "api")),
                         "sample data belong into a scratch directory, not www/")


if __name__ == "__main__":
    unittest.main()
