"""Plans and reports describe the exact authenticated bundle and restore job."""

import ast
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid

from Development.migration_bundle_probe import fixture, probe, restore, review
from Development.migration_bundle_probe.dependency import configured_age
from Development.migration_contract import contract

COMMAND = [sys.executable, "-m", "Development.migration_bundle_probe.review"]


class ReasonTableTests(unittest.TestCase):
    def test_every_restorer_reason_has_a_stable_code(self):
        tree = ast.parse((Path(restore.__file__)).read_text())
        reasons = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and getattr(node.func, "id", getattr(node.func, "attr", "")) in ("Action", "_action"):
                literals = [arg.value for arg in node.args if isinstance(arg, ast.Constant) and isinstance(arg.value, str)]
                reasons.update(literal for literal in literals if " " in literal)
            if isinstance(node, ast.Assign) and isinstance(node.value, ast.Tuple):
                values = [element.value for element in node.value.elts if isinstance(element, ast.Constant)]
                if len(values) == 2 and all(isinstance(value, str) for value in values) and " " in values[1]:
                    reasons.add(values[1])
            if isinstance(node, ast.IfExp):
                for branch in (node.body, node.orelse):
                    if isinstance(branch, ast.Constant) and isinstance(branch.value, str) and " " in branch.value:
                        reasons.add(branch.value)
        self.assertGreaterEqual(len(reasons), 15)
        self.assertEqual(reasons - set(review.REASONS), set())
        self.assertTrue(all(contract.CODE.fullmatch(code) for code in review.REASONS.values()))

    def test_unknown_reason_is_refused(self):
        with self.assertRaises(review.ReviewError):
            review.reason_code(restore.Action("a", "conflict", "a brand new reason"))


class ReviewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.age = configured_age()
        if cls.age is None:
            raise unittest.SkipTest("set OMARCHY_TEST_AGE and OMARCHY_TEST_AGE_SHA256 for real age fixtures")

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="migration-review-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        policy = fixture.fixture_policy()
        files, links = fixture.examples(policy)
        self.request = {"schema": contract.EXPORT_REQUEST, "request_id": str(uuid.uuid4()),
                        "inventory_id": fixture.inventory_id(policy, files, links), "policy_revision": policy["revision"],
                        "selection": {"categories": ["files-and-projects", "configuration"], "credential_stores": []}}
        self.export = self.root / "export"
        self.receipt = fixture.export_fixture(self.request, self.export, self.age, lambda *_a, **_k: None, lambda: False)
        self.target, self.job = self.root / "target", self.root / "job"
        self.target.mkdir(mode=0o700)
        self.job.mkdir(mode=0o700)

    def plan(self):
        with restore.verified_bundle(self.age, fixture.SECRET, self.export / "bundle.age") as bundle:
            with restore.Restorer(bundle, self.target, self.job) as importer:
                return review.plan_document(bundle, importer.plan(), self.receipt, 1000, self.target), bundle.ciphertext_sha256

    def command(self, operation, *extra, secret=fixture.SECRET):
        read, write = os.pipe()
        os.write(write, secret + b"\n")
        os.close(write)
        try:
            result = subprocess.run(
                COMMAND + [operation, "--bundle", str(self.export / "bundle.age"), "--receipt", str(self.export / "receipt.json"),
                           "--target", str(self.target), "--job", str(self.job), "--passphrase-fd", str(read), *extra],
                pass_fds=(read,), capture_output=True, text=True, timeout=60)
        finally:
            os.close(read)
        return result

    def test_plan_binds_the_authenticated_ciphertext_and_counts_every_entry(self):
        plan, digest = self.plan()
        self.assertEqual(contract.validate(plan), contract.PLAN)
        self.assertEqual(digest, probe.digest_file(self.export / "bundle.age"))
        self.assertEqual((plan["bundle_sha256"], plan["export_id"]), (self.receipt["bundle"]["sha256"], self.receipt["export_id"]))
        self.assertEqual(plan["policy_revision"], self.receipt["policy_revision"])
        self.assertEqual(sum(plan["actions"].values()), self.receipt["estimates"]["entries"])
        self.assertEqual(plan["actions"]["conflict"], 0)
        self.assertEqual(plan["actions"]["inert"], 1)  # the Work link into /mnt/mac
        self.assertEqual(plan["required_bytes"], self.receipt["estimates"]["expanded_bytes"])

    def test_plan_id_is_stable_until_the_destination_changes(self):
        first, _ = self.plan()
        self.assertEqual(self.plan()[0]["plan_id"], first["plan_id"])
        (self.target / "Projects").mkdir(mode=0o700)
        (self.target / "Projects/demo").mkdir(mode=0o700)
        (self.target / "Projects/demo/changed.txt").write_bytes(b"edited on the destination\n")
        changed, _ = self.plan()
        self.assertNotEqual(changed["plan_id"], first["plan_id"])
        self.assertEqual(changed["actions"]["conflict"], 1)

    def test_plan_for_one_destination_cannot_be_applied_to_another(self):
        plan = contract.parse(self.command("plan").stdout.encode())
        other = self.root / "other-target"
        other.mkdir(mode=0o700)
        self.target = other
        self.job = self.root / "other-job"
        self.job.mkdir(mode=0o700)
        refused = self.command("apply", "--plan-id", plan["plan_id"])
        self.assertEqual((refused.returncode, json.loads(refused.stderr)["error"]), (1, "plan_changed"))
        self.assertEqual(list(other.iterdir()), [])

    def test_receipt_for_another_bundle_is_refused(self):
        with restore.verified_bundle(self.age, fixture.SECRET, self.export / "bundle.age") as bundle:
            with restore.Restorer(bundle, self.target, self.job) as importer:
                actions = importer.plan()
                for field, value in ((("export_id",), str(uuid.uuid4())), (("bundle", "sha256"), "0" * 64)):
                    receipt = json.loads(json.dumps(self.receipt))
                    target = receipt
                    for key in field[:-1]:
                        target = target[key]
                    target[field[-1]] = value
                    with self.subTest(field=field), self.assertRaises(review.ReviewError) as caught:
                        review.plan_document(bundle, actions, receipt, 1000, self.target)
                    self.assertEqual(str(caught.exception), "receipt_mismatch")

    def test_command_applies_only_the_reviewed_plan_and_reports_by_category(self):
        planned = self.command("plan")
        self.assertEqual(planned.returncode, 0, planned.stderr)
        plan = contract.parse(planned.stdout.encode())
        refused = self.command("apply", "--plan-id", str(uuid.uuid4()))
        self.assertEqual((refused.returncode, json.loads(refused.stderr)["error"]), (1, "plan_changed"))
        self.assertEqual(list(self.target.iterdir()), [])
        applied = self.command("apply", "--plan-id", plan["plan_id"])
        self.assertEqual(applied.returncode, 0, applied.stderr)
        report = contract.parse(applied.stdout.encode())
        self.assertEqual(report["plan_id"], plan["plan_id"])
        outcomes = {item["id"]: (item["outcome"], item["restored"], item["conflicts"]) for item in report["categories"]}
        self.assertEqual(outcomes["configuration"], ("restored", 5, 0))
        self.assertEqual(outcomes["files-and-projects"][0], "restored")
        work = next(item for item in report["categories"] if item["id"] == "files-and-projects")
        self.assertEqual((work["omitted"], work["reasons"]), (1, ["link_not_restorable"]))
        self.assertEqual((self.target / ".config/hypr/input.lua").read_bytes(), b"input {\n  kb_layout = us\n}\n")

    def test_conflicts_make_a_category_partial_and_retry_reports_the_same_job(self):
        (self.target / ".config").mkdir(mode=0o700)
        (self.target / ".config/chromium-flags.conf").write_bytes(b"--native-choice\n")
        plan = contract.parse(self.command("plan").stdout.encode())
        self.assertEqual(plan["actions"]["conflict"], 1)
        report = contract.parse(self.command("apply", "--plan-id", plan["plan_id"]).stdout.encode())
        configuration = next(item for item in report["categories"] if item["id"] == "configuration")
        self.assertEqual((configuration["outcome"], configuration["conflicts"], configuration["reasons"]),
                         ("partial", 1, ["destination_exists"]))
        self.assertEqual((self.target / ".config/chromium-flags.conf").read_bytes(), b"--native-choice\n")
        again = contract.parse(self.command("plan").stdout.encode())
        retried = contract.parse(self.command("apply", "--plan-id", again["plan_id"]).stdout.encode())
        self.assertEqual(retried["job_id"], report["job_id"])
        self.assertEqual(again["actions"]["create"], 0)

    def test_wrong_passphrase_and_bad_passphrase_input_write_nothing(self):
        for secret, error in ((b"not-the-transfer-passphrase", None), (b"", "passphrase_invalid")):
            result = self.command("plan", secret=secret)
            with self.subTest(error=error):
                self.assertEqual(result.returncode, 1)
                if error:
                    self.assertEqual(json.loads(result.stderr)["error"], error)
        self.assertEqual(list(self.target.iterdir()), [])
        self.assertNotIn(fixture.SECRET.decode(), " ".join(COMMAND))


if __name__ == "__main__":
    unittest.main()
