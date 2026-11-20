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
        # a missing user is a state, not a REST error - 01-install must go on to create
        self.assertNotIn("error", r)
        self.assertIn("does not exist", r["reason"])
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
        self.assertNotIn("error", r)                                 # 01-install reaches the 401 / reset branch
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


class LocalHostsTest(unittest.TestCase):
    """single GUI host (role both, no pull hosts): hosts.json + hosts/<id> -> ../api"""

    def now(self):
        return {"host": "orafusion01", "product": "Forms & Reports", "environment": "prod", "domain": "fr_domain",
                "generated_at": "2026-11-20T12:00:00+01:00", "interval_sec": 300,
                "overall": {"level": "warn", "reasons": [{"level": "warn", "text": "Memory free: 17 %"}]},
                "collector": {"errors": []}, "components": [{"id": "host", "type": "host", "since": "x"}],
                "metrics": [{"id": "load1", "value": 0.5}, {"id": "cpu_pct", "value": None, "display": "n/a"}]}

    def run_local(self, role, pull=""):
        import json as _j
        d = TempDir()
        base = d.__enter__()
        self.addCleanup(d.__exit__, None, None, None)
        for sub in ("api", "hosts", "etc"):
            os.makedirs(os.path.join(base, sub))
        with open(os.path.join(base, "etc", "wlsmon.conf"), "w") as fh:
            fh.write("WLSMON_ROLE=%s\nWLSMON_PULL_HOSTS=%s\n" % (role, pull))
        cfg = wlsmon.Config(base)
        rnd = wlsmon.Round(cfg, {}, wlsmon.now_ts(), False)
        wlsmon.local_hosts(cfg, base, os.path.join(base, "api"), self.now(), rnd)
        hj = os.path.join(base, "hosts", "hosts.json")
        if not os.path.exists(hj):
            return base, None
        with open(hj) as fh:
            return base, _j.load(fh)

    def test_both_writes_own_tile(self):
        base, hj = self.run_local("both")
        self.assertEqual([h["id"] for h in hj["hosts"]], ["orafusion01"])
        self.assertEqual(hj["hosts"][0]["summary"]["load1"], 0.5)
        self.assertEqual(os.readlink(os.path.join(base, "hosts", "orafusion01")), "../api")
        import check_contract
        c = check_contract.Checker(real=True)
        c.check_hosts(hj)
        self.assertEqual(c.findings, [])

    def test_data_role_and_pull_hosts_write_nothing(self):
        self.assertIsNone(self.run_local("data")[1])
        self.assertIsNone(self.run_local("both", "hostb.example.com")[1])


INSTALL_ROOT = os.path.join(BASE, "02-install-wlsmon_root.sh")

# fake root commands: sudo runs the command as this user, everything that would
# change the system only logs; systemd-creds "encrypts" by copying
FAKES = {
    "sudo": 'while [ "${1#-}" != "$1" ]; do shift; done; exec "$@"',
    "systemctl": '[ "$1" = "--version" ] && { echo "systemd 252 (252-1)"; exit 0; }; echo "systemctl $*" >> "$FAKE_LOG"',
    "systemd-creds": 'echo "systemd-creds $*" >> "$FAKE_LOG"; '
                     'for a; do :; done; n=$#; in="${@:n-1:1}"; cp "$in" "$a"',
    "install": 'a=(); while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac; done; '
               'exec /usr/bin/install "${a[@]}"',
    "getent": 'exit 2',
    "runuser": 'exit 1',
    "getfacl": 'exit 0',
}
for _c in ("chown", "chgrp", "groupadd", "groupdel", "usermod", "setfacl", "semanage", "restorecon", "nginx"):
    FAKES[_c] = 'echo "%s $*" >> "$FAKE_LOG"' % _c


@unittest.skipIf(os.geteuid() == 0, "the test needs a non-root user (fake sudo)")
class InstallRootTest(unittest.TestCase):

    def run_root(self, d, base, *args):
        fake = os.path.join(d, "fakebin")
        os.makedirs(fake, exist_ok=True)
        for name, body in FAKES.items():
            p = os.path.join(fake, name)
            with open(p, "w") as fh:
                fh.write("#!/bin/bash\n%s\n" % body)
            os.chmod(p, 0o755)
        env = dict(os.environ, PATH=fake + ":" + os.environ["PATH"], FAKE_LOG=os.path.join(d, "fake.log"))
        p = subprocess.run(["bash", INSTALL_ROOT, "--base", base, "--test-root", os.path.join(d, "root")]
                           + list(args), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, universal_newlines=True, timeout=120, env=env)
        return p.returncode, p.stdout

    def prepared(self, d):
        base = os.path.join(d, "w")
        run(["--defaults", "--apply", "--base", base, "--env-conf", "/dev/null"])
        subprocess.run(["bash", INSTALL_FMW, "--apply", "--no-user", "--base", base], stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
        pend = os.path.join(base, "etc", "pending")
        for n, v in (("reports_mon", "rep-pw"), ("gui_htpasswd", "wlsmon:$6$salt$hash")):
            with open(os.path.join(pend, n), "w") as fh:
                fh.write(v)
        os.makedirs(os.path.join(d, "root", "var", "log", "nginx"))
        return base

    def test_dry_run_changes_nothing(self):
        with TempDir() as d:
            base = self.prepared(d)
            before = sorted(os.listdir(os.path.join(base, "etc", "pending")))
            rc, out = self.run_root(d, base)
            self.assertIn("Dry-run", out)
            self.assertEqual(sorted(os.listdir(os.path.join(base, "etc", "pending"))), before)
            self.assertFalse(os.path.exists(os.path.join(d, "root", "etc", "nginx", "oracle-wls.d", "wlsmon.conf")))
            self.assertFalse(os.path.exists(os.path.join(d, "fake.log")), "dry-run ran a root command")

    def test_apply_rerun_remove(self):
        with TempDir() as d:
            base = self.prepared(d)
            rc, out = self.run_root(d, base, "--apply")
            self.assertNotIn("mFAIL\x1b", out, out)
            root = os.path.join(d, "root")
            # secrets: credentials written, clear text gone
            self.assertTrue(os.path.isfile(os.path.join(base, "etc", "creds", "wls_monitor.cred")))
            self.assertTrue(os.path.isfile(os.path.join(base, "etc", "creds", "reports_mon.cred")))
            pend = os.listdir(os.path.join(base, "etc", "pending"))
            for n in ("wls_monitor", "reports_mon", "gui_htpasswd"):
                self.assertNotIn(n, pend)
            ht = os.path.join(root, "etc", "nginx", "wlsmon", "htpasswd")
            self.assertEqual(mode(ht), 0o640)
            # nginx files, GUI role, test-root paths in the include
            inc = open(os.path.join(root, "etc", "nginx", "oracle-wls.d", "wlsmon.conf")).read()
            self.assertIn("location ^~ /wlsmon/", inc)
            self.assertIn(os.path.join(root, "etc", "nginx", "wlsmon", "headers.conf"), inc)
            self.assertIn("alias                %s/www/;" % base, inc)
            self.assertTrue(os.path.isfile(os.path.join(root, "etc", "nginx", "conf.d", "wlsmon_zone.conf")))
            # units: credentials only for what exists (no db_monitor -> no CRED_DB line)
            svc = open(os.path.join(root, "etc", "systemd", "system", "wlsmon-collect.service")).read()
            self.assertIn("LoadCredentialEncrypted=wls_monitor:", svc)
            self.assertIn("LoadCredentialEncrypted=reports_mon:", svc)
            self.assertNotIn("db_monitor", "\n".join(l for l in svc.splitlines() if not l.startswith("#")))
            self.assertTrue(os.path.isfile(os.path.join(root, "etc", "systemd", "system", "wlsmon-collect.timer")))
            self.assertFalse(os.path.exists(os.path.join(root, "etc", "systemd", "system", "wlsmon-pull.service")))
            log = open(os.path.join(d, "fake.log")).read()
            self.assertIn("groupadd -r wlsmon", log)
            self.assertIn("setfacl -d -m u:", log)                    # nginx log default ACL
            self.assertEqual(mode(os.path.join(base, "www")), 0o2750)
            # second run: nothing to change
            rc, out = self.run_root(d, base, "--apply")
            self.assertNotIn("mFAIL\x1b", out, out)
            self.assertIn("present (etc/creds)", out)
            self.assertNotRegex(out, r"(\.conf|\.service|\.timer)\s+installed")   # files unchanged
            # remove
            rc, out = self.run_root(d, base, "--remove", "--apply")
            self.assertFalse(os.path.exists(os.path.join(root, "etc", "nginx", "oracle-wls.d", "wlsmon.conf")))
            self.assertFalse(os.path.exists(os.path.join(root, "etc", "nginx", "wlsmon")))
            self.assertFalse(os.path.exists(os.path.join(root, "etc", "systemd", "system", "wlsmon-collect.service")))
            self.assertEqual(os.listdir(os.path.join(base, "etc", "creds")), [])
            self.assertIn("setfacl -x u:", open(os.path.join(d, "fake.log")).read())


if __name__ == "__main__":
    unittest.main()


SET_THR = os.path.join(BASE, "03-set-thresholds.sh")


@unittest.skipIf(os.geteuid() == 0, "the scripts refuse root")
class SetThresholdsTest(unittest.TestCase):
    """03-set-thresholds.sh in an isolated copy: dry-run, check, write + backup, reset, append"""

    def setUp(self):
        self.tmp = TempDir()
        d = self.tmp.__enter__()
        self.base = os.path.join(d, "w")
        os.makedirs(os.path.join(self.base, "etc"))
        self.conf = os.path.join(self.base, "etc", "wlsmon.conf")
        with open(self.conf, "w") as fh:
            fh.write("# test\nWLSMON_ROLE=both\nWLSMON_HEAP_PCT=80,90\nWLSMON_CERT_DAYS=30,7\n")
        os.chmod(self.conf, 0o600)

    def tearDown(self):
        self.tmp.__exit__(None, None, None)

    def run3(self, *args):
        p = subprocess.run(["bash", SET_THR, "--base", self.base] + list(args), stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, timeout=60)
        return p.returncode, p.stdout

    def text(self):
        with open(self.conf) as fh:
            return fh.read()

    def backups(self):
        return [f for f in os.listdir(os.path.dirname(self.conf)) if ".bak_" in f]

    def test_overview_and_dry_run_change_nothing(self):
        before = self.text()
        rc, out = self.run3()
        self.assertIn("WLSMON_HEAP_PCT", out)
        self.assertIn("WLSMON_SWAP_MB", out)
        rc, out = self.run3("--set", "HEAP_PCT=85,95")
        self.assertIn("80,90", out)
        self.assertIn("Dry-run", out)
        self.assertEqual(self.text(), before)
        self.assertEqual(self.backups(), [])

    def test_invalid_value_is_refused(self):
        before = self.text()
        rc, out = self.run3("--set", "HEAP_PCT=95,85", "--set", "CERT_DAYS=7,30", "--apply")
        self.assertEqual(rc, 2, out)
        self.assertIn("Nothing written", out)
        self.assertEqual(self.text(), before)
        self.assertEqual(self.backups(), [])

    def test_apply_writes_with_backup_and_appends(self):
        rc, out = self.run3("--set", "WLSMON_HEAP_PCT=85,95", "--set", "SWAP_MB=1024,4096", "--apply")
        self.assertIn(rc, (0, 1), out)
        t = self.text()
        self.assertIn("WLSMON_HEAP_PCT=85,95\n", t)
        self.assertNotIn("WLSMON_HEAP_PCT=80,90", t)
        self.assertIn("WLSMON_SWAP_MB=1024,4096\n", t)                # not in the file before: appended
        self.assertIn("# test\n", t)                                   # the rest stays
        self.assertEqual(len(self.backups()), 1)
        self.assertEqual(mode(self.conf), 0o600)
        rc, out = self.run3("--reset", "HEAP_PCT", "--apply")
        self.assertIn("WLSMON_HEAP_PCT=80,90\n", self.text())
