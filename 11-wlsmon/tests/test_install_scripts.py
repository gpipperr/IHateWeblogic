"""Development steps 9 - 11: the install scripts in an isolated copy.

Always with --base in a temporary directory and --env-conf /dev/null, so no
real secret (the library's *.des3 files) is read and nothing outside the
temporary directory is written.
"""
import hashlib
import os
import stat
import subprocess
import unittest

from tests.helpers import BASE, TempDir
import wlsmon

INTERVIEW = os.path.join(BASE, "00-setup-interview.sh")


def run(args, timeout=60):
    p = subprocess.run(["bash", INTERVIEW] + args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, universal_newlines=True, timeout=timeout)
    return p.returncode, p.stdout


def mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


def md5(path):
    with open(path, "rb") as fh:
        return hashlib.md5(fh.read()).hexdigest()


@unittest.skipIf(os.geteuid() == 0, "the interview refuses root")
class InterviewTest(unittest.TestCase):

    def test_dry_run_writes_nothing(self):
        with TempDir() as d:
            rc, out = run(["--defaults", "--base", os.path.join(d, "w"), "--env-conf", "/dev/null"])
            self.assertIn(rc, (0, 1), out)
            self.assertIn("Dry-run", out)
            self.assertFalse(os.path.exists(os.path.join(d, "w")))

    def test_apply_and_rerun(self):
        with TempDir() as d:
            base = os.path.join(d, "w")
            args = ["--defaults", "--apply", "--base", base, "--env-conf", "/dev/null"]
            rc, out = run(args)
            self.assertIn(rc, (0, 1), out)
            conf = os.path.join(base, "etc", "wlsmon.conf")
            sec = os.path.join(base, "etc", "pending", "wls_monitor")
            self.assertEqual(mode(os.path.join(base, "etc")), 0o700)
            self.assertEqual(mode(os.path.join(base, "etc", "pending")), 0o700)
            self.assertEqual(mode(conf), 0o600)
            self.assertEqual(mode(sec), 0o600)
            cfg = wlsmon.Config(base)
            self.assertEqual(cfg.unknown, [])
            self.assertEqual(cfg.get("WLSMON_BASE"), base)
            self.assertEqual(cfg.get("WLSMON_STYLE_SRC"), "'self'")
            with open(sec) as fh:
                pw = fh.read().strip()
            self.assertGreaterEqual(len(pw), 20)
            self.assertTrue(any(c.isupper() for c in pw) and any(c.isdigit() for c in pw))
            self.assertNotIn(pw, out)                       # never printed
            before = md5(sec)
            rc, out = run(args)                             # second run keeps the secret
            self.assertIn("already handed over", out)
            self.assertEqual(md5(sec), before)
            self.assertIn("unchanged", out)
            rc, out = run(["--defaults", "--apply", "--base", base, "--env-conf", "/dev/null",
                           "--secret", "wls_monitor"])     # explicit: new one
            self.assertNotEqual(md5(sec), before)

    def test_unknown_secret(self):
        rc, out = run(["--secret", "nope"])
        self.assertEqual(rc, 2)


INSTALL_FMW = os.path.join(BASE, "01-install-wlsmon_fmw.sh")


class MonitorUserTest(unittest.TestCase):
    """wlsmon.py monitor-user against a fake REST realm (no WebLogic)."""

    def setUp(self):
        self.realm = {"users": {"webadmin": ["Administrators"]}, "pw": {}}
        self.calls = []
        self.saved = (wlsmon.http, dict(wlsmon.STDIN_SECRETS))

    def tearDown(self):
        wlsmon.http = self.saved[0]
        wlsmon.STDIN_SECRETS.clear()
        wlsmon.STDIN_SECRETS.update(self.saved[1])

    def fake(self, url, data=None, user=None, password=None, headers=None, timeout=20, cafile=None, method=None):
        import json as _j
        op = url.rsplit("/", 1)[1].split("?")[0]
        self.calls.append(op)
        if op == "serverRuntimes":                                   # monitor login test
            if (headers or {}).get("X-Requested-By") is None:        # 14.1.2: 400 without it
                return 400, "{}"
            ok_ = self.realm["pw"].get(user) == password
            return (200 if ok_ else 401), "{}"
        if password != "admin-pw":
            return 401, ""
        b = _j.loads(data or "{}")
        u = self.realm["users"]
        if op == "userExists":
            return 200, _j.dumps({"return": b["userName"] in u})
        if op == "createUser":
            u[b["userName"]] = []
            self.realm["pw"][b["userName"]] = b["password"]
            return 204, ""
        if op == "addMemberToGroup":
            u[b["memberUserOrGroupName"]].append(b["groupName"])
            return 204, ""
        if op == "listMemberGroups":                                 # real 14.1.2: a cursor
            self.cursor = list(u.get(b["memberUserOrGroupName"], []))
            return 200, _j.dumps({"return": "Cursor_1"})
        if op == "haveCurrent":
            return 200, _j.dumps({"return": bool(self.cursor)})
        if op == "getCurrentName":
            return 200, _j.dumps({"return": self.cursor[0]})
        if op == "advance":
            self.cursor.pop(0)
            return 200, "{}"
        if op == "close":
            return 200, "{}"
        if op == "resetUserPassword":
            self.realm["pw"][b["userName"]] = b["newPassword"]
            return 204, ""
        return 404, ""

    def call(self, action, admin_pw="admin-pw", mon_pw="mon-pw"):
        import contextlib
        import io
        import json as _j
        wlsmon.http = self.fake
        wlsmon.STDIN_SECRETS.clear()
        wlsmon.STDIN_SECRETS.update({"admin_user": "webadmin", "admin_password": admin_pw, "wls_monitor": mon_pw})
        out = io.StringIO()
        with TempDir() as d, contextlib.redirect_stdout(out):
            os.environ["WLSMON_BASE"] = d
            try:
                rc = wlsmon.monitor_user([action])
            finally:
                del os.environ["WLSMON_BASE"]
        return rc, _j.loads(out.getvalue())

    def test_check_create_check(self):
        rc, r = self.call("check")
        self.assertEqual((rc, r["exists"]), (1, False))
        rc, r = self.call("create")
        self.assertEqual(rc, 0)
        self.assertTrue(r["created"])
        self.assertEqual(r["groups"], ["Monitors"])
        self.assertEqual(r["login"], 200)
        rc, r = self.call("create")                                  # idempotent: no second createUser
        self.assertEqual(self.calls.count("createUser"), 1)

    def test_wrong_password_and_reset(self):
        self.call("create")
        rc, r = self.call("check", mon_pw="other")
        self.assertEqual((rc, r["login"]), (1, 401))
        rc, r = self.call("reset", mon_pw="other")
        self.assertEqual((rc, r["login"]), (0, 200))

    def test_admin_401_stops_at_once(self):
        rc, r = self.call("create", admin_pw="wrong")
        self.assertEqual(rc, 1)
        self.assertIn("stop", r["error"])
        self.assertEqual(self.calls, ["userExists"])                 # one attempt, no retries


@unittest.skipIf(os.geteuid() == 0, "the scripts refuse root")
class InstallFmwTest(unittest.TestCase):

    def test_apply_no_user_and_remove(self):
        with TempDir() as d:
            base = os.path.join(d, "w")
            run(["--defaults", "--apply", "--base", base, "--env-conf", "/dev/null"])
            p = subprocess.run(["bash", INSTALL_FMW, "--apply", "--no-user", "--base", base],
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               universal_newlines=True, timeout=120)
            self.assertIn(p.returncode, (0, 1), p.stdout)
            self.assertEqual(mode(os.path.join(base, "bin", "wlsmon.py")), 0o700)
            self.assertEqual(mode(os.path.join(base, "www")), 0o750)
            self.assertEqual(mode(os.path.join(base, "www", "js")), 0o750)
            self.assertTrue(os.path.isfile(os.path.join(base, "www", "ui.json")))
            self.assertTrue(os.path.isfile(os.path.join(base, "etc", "wlsmon_rules.local.cfg")))
            self.assertNotIn("HTTP 401", p.stdout)                   # no login with an unverified user
            subprocess.run(["bash", INSTALL_FMW, "--remove", "--apply", "--base", base],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=60)
            self.assertEqual(sorted(os.listdir(base)), ["etc"])


if __name__ == "__main__":
    unittest.main()
