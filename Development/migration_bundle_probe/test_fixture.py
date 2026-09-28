"""Exercise the runnable fixture's observable request/result boundaries."""

import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

from Development.migration_bundle_probe import fixture, probe
from Development.migration_bundle_probe.dependency import configured_age


COMMAND = [sys.executable, "-m", "Development.migration_bundle_probe.fixture"]


class RequestTests(unittest.TestCase):
    def test_malformed_duplicate_and_oversized_requests_fail_before_job_creation(self):
        request = {"schema": fixture.SCHEMA, "request_id": str(uuid.uuid4()), "include_credentials": False}
        duplicate = json.dumps(request)[:-1] + ', "include_credentials": true}'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, output = root / "request.json", root / "job"
            for raw, error in ((b"{", "fixture_operation_failed"),
                               (duplicate.encode(), "fixture_operation_failed"),
                               (b" " * 8193, "oversized_request")):
                source.write_bytes(raw)
                result = subprocess.run(COMMAND + ["export", "--request", str(source),
                                        "--output-directory", str(output)],
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(json.loads(result.stdout)["error"], error)
                self.assertFalse(output.exists())

    def test_capabilities_and_inventory_need_no_crypto_dependency(self):
        environment = dict(os.environ)
        environment.pop("OMARCHY_TEST_AGE", None)
        for operation in ("capabilities", "inventory"):
            result = subprocess.run(COMMAND + [operation], env=environment, capture_output=True,
                                    text=True, timeout=10, check=True)
            document = json.loads(result.stdout)
            self.assertTrue(document["synthetic"])
            self.assertEqual(document["schema"], fixture.SCHEMA)
        self.assertFalse(document["categories"]["credentials"]["default_selected"])

    def test_requests_require_explicit_boolean_selection_and_canonical_identity(self):
        valid = {"schema": fixture.SCHEMA, "request_id": str(uuid.uuid4()), "include_credentials": False}
        self.assertEqual(fixture.request_document(valid), valid)
        for key, value in (("schema", "future/999"), ("request_id", "../other"),
                           ("include_credentials", "false"), ("include_credentials", 1),
                           ("source_home", "/home/someone")):
            with self.subTest(key=key, value=value), self.assertRaises(fixture.FixtureError):
                fixture.request_document({**valid, key: value})


class ExportFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.age = configured_age()
        if cls.age is None:
            raise unittest.SkipTest("set OMARCHY_TEST_AGE and OMARCHY_TEST_AGE_SHA256 for real age fixtures")

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="migration-fixture-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.output = self.root / "job"
        self.request = {"schema": fixture.SCHEMA, "request_id": str(uuid.uuid4()), "include_credentials": False}
        self.request_path = self.root / "request.json"
        self.request_path.write_text(json.dumps(self.request))

    def command(self):
        return COMMAND + ["export", "--request", str(self.request_path),
                          "--output-directory", str(self.output)]

    def execute(self):
        result = subprocess.run(self.command(), capture_output=True, text=True, timeout=30)
        return result.returncode, [json.loads(line) for line in result.stdout.splitlines()]

    def test_real_command_encrypts_only_generated_selected_data_and_reuses_complete_job(self):
        code, events = self.execute()
        self.assertEqual(code, 0)
        self.assertEqual([event["phase"] for event in events], ["preparing", "capturing", "finalizing", "complete"])
        self.assertEqual([event["sequence"] for event in events], [1, 2, 3, 4])
        receipt = events[-1]["receipt"]
        self.assertEqual(receipt, json.loads((self.output / "receipt.json").read_text()))
        decoded = probe.decode(self.age, fixture.SECRET, self.output / receipt["filename"])
        self.assertEqual({entry["path"] for entry in decoded["entries"]}, set(probe.selected_files(fixture.EXAMPLES)))
        self.assertEqual(receipt["request"], self.request)
        before = (self.output / "bundle.age").stat()
        code, repeated = self.execute()
        self.assertEqual(code, 0)
        self.assertTrue(repeated[-1]["reused"])
        self.assertEqual(repeated[-1]["receipt"], receipt)
        self.assertEqual((self.output / "bundle.age").stat().st_mtime_ns, before.st_mtime_ns)

    def test_explicit_credential_selection_adds_only_fake_stores(self):
        self.request["include_credentials"] = True
        self.request_path.write_text(json.dumps(self.request))
        self.assertEqual(self.execute()[0], 0)
        decoded = probe.decode(self.age, fixture.SECRET, self.output / "bundle.age")
        self.assertEqual({entry["path"] for entry in decoded["entries"]}, set(fixture.EXAMPLES))

    def test_changed_request_or_ciphertext_cannot_reuse_success(self):
        self.assertEqual(self.execute()[0], 0)
        self.request_path.write_text(json.dumps({**self.request, "include_credentials": True}))
        code, events = self.execute()
        self.assertEqual((code, events[-1]["error"]), (1, "request_conflict"))
        self.request_path.write_text(json.dumps(self.request))
        with (self.output / "bundle.age").open("r+b") as stream:
            stream.seek(-1, 2)
            original = stream.read(1)
            stream.seek(-1, 2)
            stream.write(bytes([original[0] ^ 1]))
        code, events = self.execute()
        self.assertEqual((code, events[-1]["error"]), (1, "ciphertext_changed"))

    def test_existing_directory_and_symlink_are_not_repurposed(self):
        self.output.mkdir(mode=0o700)
        marker = self.output / "personal-marker"
        marker.write_bytes(b"keep me")
        self.assertEqual(self.execute()[0], 1)
        self.assertEqual(marker.read_bytes(), b"keep me")
        self.assertEqual(set(path.name for path in self.output.iterdir()), {"personal-marker"})
        alias = self.root / "alias"
        alias.symlink_to(self.output, target_is_directory=True)
        self.output = alias
        code, events = self.execute()
        self.assertEqual((code, events[-1]["error"]), (1, "unsafe_job_directory"))

    def test_cancel_at_finalization_keeps_ciphertext_incomplete_without_receipt(self):
        events = []

        def emit(phase, **_fields):
            events.append(phase)

        with self.assertRaises(fixture.Cancelled):
            fixture.export_fixture(self.request, self.output, self.age, emit,
                                   lambda: "finalizing" in events)
        self.assertTrue((self.output / "bundle.age").exists())
        self.assertFalse((self.output / "receipt.json").exists())
        self.assertNotIn("complete", events)
        code, repeated = self.execute()
        self.assertEqual((code, repeated[-1]["error"]), (1, "job_incomplete_use_new_directory"))

    def test_parent_sync_failure_cannot_report_a_durable_completed_job(self):
        events = []
        original = fixture.sync_directory

        def sync(directory):
            if directory == self.output.parent:
                raise OSError("injected parent-directory synchronization failure")
            original(directory)

        with patch.object(fixture, "sync_directory", side_effect=sync), self.assertRaises(OSError):
            fixture.export_fixture(self.request, self.output, self.age,
                                   lambda phase, **fields: events.append(phase), lambda: False)
        self.assertFalse((self.output / "receipt.json").exists())
        self.assertNotIn("complete", events)

    def test_sigterm_cancellation_never_publishes_receipt_and_duplicate_cannot_start_writer(self):
        with subprocess.Popen(self.command() + ["--pause-before-capture", "30"],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
            try:
                self.assertTrue(select.select([process.stdout], [], [], 10)[0])
                self.assertEqual(json.loads(process.stdout.readline())["phase"], "preparing")
                code, duplicate = self.execute()
                self.assertEqual((code, duplicate[-1]["error"]), (1, "job_incomplete_use_new_directory"))
                process.send_signal(signal.SIGTERM)
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 130, stderr)
                self.assertEqual(json.loads(stdout.splitlines()[-1])["phase"], "cancelled")
                self.assertFalse((self.output / "receipt.json").exists())
                self.assertFalse((self.output / "bundle.age").exists())
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
