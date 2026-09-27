from dataclasses import replace
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import uuid

from Development.migration_staging.broker import CHUNK, Refused
from Development.migration_staging.publication import StageRequest, publish, verify_ready


class Interrupted(RuntimeError):
    pass


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="migration-publish-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "synthetic.age"
        self.data = b"synthetic opaque ciphertext\n" * 100000
        self.source.write_bytes(self.data)
        self.source.chmod(0o400)
        self.destination = self.root / "incoming"
        self.destination.mkdir(mode=0o700)
        self.request = StageRequest(str(uuid.uuid4()), str(uuid.uuid4()), "a" * 64, "b" * 64,
                                    "c" * 64, hashlib.sha256(self.data).hexdigest(), len(self.data))

    def stage(self, **kwargs):
        return publish(self.source, self.destination, self.request, **kwargs)

    def assert_complete(self):
        self.assertEqual((self.destination / "bundle.age").read_bytes(), self.data)
        self.assertEqual(json.loads((self.destination / "ready.json").read_bytes()), self.request.document())
        self.assertEqual(self.source.read_bytes(), self.data)
        self.assertFalse((self.destination / "bundle.partial").exists())

    def test_repeated_complete_request_is_readback_only(self):
        self.assertEqual(self.stage()["copied_bytes"], len(self.data))
        self.assert_complete()
        before = (self.destination / "bundle.age").stat()
        self.assertEqual(self.stage()["copied_bytes"], 0)
        after = (self.destination / "bundle.age").stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))

    def test_interruption_at_each_publication_boundary_resumes(self):
        for phase in ("intent", "copy", "ciphertext", "ready"):
            with self.subTest(phase=phase):
                destination = self.root / phase
                destination.mkdir(mode=0o700)
                def interrupt(current):
                    if current == phase:
                        raise Interrupted(current)
                with self.assertRaises(Interrupted):
                    publish(self.source, destination, self.request, checkpoint=interrupt)
                self.assertEqual((destination / "ready.json").exists(), phase == "ready")
                result = publish(self.source, destination, self.request)
                self.assertTrue(result["ready"])
                expected = len(self.data) if phase == "intent" else len(self.data) - CHUNK if phase == "copy" else 0
                self.assertEqual(result["copied_bytes"], expected)
                self.assertEqual((destination / "bundle.age").read_bytes(), self.data)

    def test_changed_target_candidate_or_export_cannot_resume(self):
        self.stage()
        original = (self.destination / "ready.json").read_bytes()
        for request in (replace(self.request, target_uuid=str(uuid.uuid4())),
                        replace(self.request, candidate_sha256="d" * 64),
                        replace(self.request, export_id=str(uuid.uuid4())),
                        replace(self.request, ciphertext_bytes=1)):
            with self.assertRaises(Refused):
                publish(self.source, self.destination, request)
        self.assertEqual((self.destination / "ready.json").read_bytes(), original)
        self.assert_complete()

    def test_symlink_cannot_redirect_partial_write(self):
        outside = self.root / "unselected"
        outside.write_bytes(b"untouched")
        (self.destination / "bundle.partial").symlink_to(outside)
        with self.assertRaises(OSError):
            self.stage()
        self.assertEqual(outside.read_bytes(), b"untouched")
        self.assertFalse((self.destination / "ready.json").exists())

    def test_corrupt_partial_is_not_accepted_or_silently_overwritten(self):
        partial = self.destination / "bundle.partial"
        partial.write_bytes(b"different export")
        partial.chmod(0o600)
        with self.assertRaises(Refused):
            self.stage()
        self.assertEqual(partial.read_bytes(), b"different export")
        self.assertFalse((self.destination / "ready.json").exists())

    def test_corrupt_committed_bytes_are_not_accepted_on_retry(self):
        self.stage()
        bundle = self.destination / "bundle.age"
        bundle.write_bytes(b"corruption")
        with self.assertRaises(Refused):
            self.stage()
        with self.assertRaises(Refused):
            verify_ready(self.destination, self.request)
        bundle.unlink()
        with self.assertRaises(FileNotFoundError):
            verify_ready(self.destination, self.request)

    def test_full_partial_is_synchronized_even_when_no_copy_is_needed(self):
        partial = self.destination / "bundle.partial"
        partial.write_bytes(self.data)
        partial.chmod(0o600)
        inode = partial.stat().st_ino
        synchronized = []
        real_fsync = os.fsync
        def fsync(fd):
            synchronized.append(os.fstat(fd).st_ino)
            real_fsync(fd)
        with patch("os.fsync", side_effect=fsync):
            self.assertEqual(self.stage()["copied_bytes"], 0)
        self.assertIn(inode, synchronized)
        self.assertTrue(verify_ready(self.destination, self.request))

    def test_existing_readiness_is_resynchronized_before_success(self):
        self.stage()
        synchronized = []
        real_fsync = os.fsync
        def fsync(fd):
            synchronized.append(os.fstat(fd).st_ino)
            real_fsync(fd)
        with patch("os.fsync", side_effect=fsync):
            self.stage()
        self.assertIn(self.destination.stat().st_ino, synchronized)
        self.assertIn((self.destination / "ready.json").stat().st_ino, synchronized)

    def test_wrong_source_digest_never_publishes_readiness(self):
        with self.assertRaises(Refused):
            publish(self.source, self.destination, replace(self.request, ciphertext_sha256="e" * 64))
        self.assertFalse((self.destination / "ready.json").exists())
        self.assertFalse((self.destination / "bundle.age").exists())

    def test_duplicate_active_request_cannot_start_another_copy(self):
        def nested(phase):
            if phase == "intent":
                with self.assertRaises(BlockingIOError):
                    self.stage()
        self.assertTrue(self.stage(checkpoint=nested)["ready"])
        self.assert_complete()


if __name__ == "__main__":
    unittest.main()
