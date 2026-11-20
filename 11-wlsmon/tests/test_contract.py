"""Development step 1: the sample data pass the contract check, broken data fail."""
import contextlib
import io
import os
import unittest

from tests.helpers import TempDir, read_json, write_json
import check_contract
import gen_sample_data

SCENARIOS = ("normal", "warn", "crit", "nginxdown", "rcu", "stale")


class ContractTest(unittest.TestCase):

    def sample(self, d, scenario="warn"):
        with contextlib.redirect_stdout(io.StringIO()):
            gen_sample_data.build(scenario, d)
        return d

    def test_all_scenarios_pass(self):
        with TempDir() as d:
            for sc in SCENARIOS:
                out = os.path.join(d, sc)
                self.sample(out, sc)
                self.assertEqual(check_contract.check_dir(out), [], sc)

    def test_demo_hosts_pass(self):
        with TempDir() as d:
            for sc in SCENARIOS:
                self.sample(os.path.join(d, "demo", sc), sc)
            with contextlib.redirect_stdout(io.StringIO()):
                gen_sample_data.build_hosts(d)
            self.assertEqual(
                check_contract.check_hosts_file(os.path.join(d, "demo", "hosts.json")), [])

    def broken(self, fname, change):
        with TempDir() as d:
            self.sample(d)
            p = os.path.join(d, fname)
            obj = read_json(p)
            change(obj)
            write_json(p, obj)
            return check_contract.check_dir(d)

    def test_wrong_level(self):
        def ch(o):
            o["metrics"][0]["level"] = "yellow"
        self.assertTrue(any("level 'yellow'" in f for f in self.broken("now.json", ch)))

    def test_series_too_short(self):
        def ch(o):
            o["series"]["load1"].pop()
        self.assertTrue(any("series.load1" in f for f in self.broken("day.json", ch)))

    def test_formatted_value(self):
        def ch(o):
            o["metrics"][0]["value"] = "2,5"
        self.assertTrue(any("plain number" in f for f in self.broken("now.json", ch)))

    def test_unknown_requires(self):
        def ch(o):
            o["components"][1]["requires"] = ["nope"]
        self.assertTrue(any("unknown id 'nope'" in f for f in self.broken("now.json", ch)))

    def test_component_not_staged(self):
        def ch(o):
            o["layout"]["stages"] = o["layout"]["stages"][:-1]
        self.assertTrue(any("staged 0 times" in f for f in self.broken("now.json", ch)))

    def test_raw_log_line(self):
        def ch(o):
            o["events"][0]["line"] = "####<Nov 19, 2026> <Error> user=scott ..."
        self.assertTrue(any("raw log line" in f for f in self.broken("logs.json", ch)))

    def test_ignore_without_reason(self):
        def ch(o):
            o["rules"][-1]["reason"] = ""
        self.assertTrue(any("without a reason" in f for f in self.broken("logs.json", ch)))

    def test_missing_file(self):
        with TempDir() as d:
            self.sample(d)
            os.remove(os.path.join(d, "security.json"))
            self.assertIn("security.json: file: missing", check_contract.check_dir(d))

    def test_real_mode_rejects_demo_reference(self):
        with TempDir() as d:
            self.sample(d)
            self.assertEqual(check_contract.check_dir(d), [])
            self.assertTrue(check_contract.check_dir(d, real=True))


if __name__ == "__main__":
    unittest.main()
