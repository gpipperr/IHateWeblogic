"""Shared helpers for the wlsmon unit tests (stdlib only, python 3.6+)."""
import json
import os
import shutil
import sys
import tempfile

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(BASE, "tools")
FIXTURES = os.path.join(BASE, "tests", "fixtures")
for p in (BASE, TOOLS):
    if p not in sys.path:
        sys.path.insert(0, p)


class TempDir(object):
    """with TempDir() as d: ... - removed afterwards."""

    def __enter__(self):
        self.path = tempfile.mkdtemp(prefix="wlsmon_test_")
        return self.path

    def __exit__(self, *exc):
        shutil.rmtree(self.path, ignore_errors=True)


def read_json(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def write_json(path, obj):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(obj, fh)
