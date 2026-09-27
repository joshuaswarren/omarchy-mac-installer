"""Compose GPT admission and the actual bounded server on synthetic images."""

import hashlib
import os
import subprocess
import unittest
from unittest.mock import patch
import uuid

from Development.migration_staging.broker import FixturePermit, Refused, RegionServer
from Development.migration_staging.test_broker import Client
from Development.migration_staging.test_gpt import GptFixture


class BindingFixture(GptFixture):
    def setUp(self):
        super().setUp()
        self.fixture()
        self.digest = hashlib.sha256(b"\0" * 4096).hexdigest()

    def inspect(self, **kwargs):
        return FixturePermit.inspect_gpt(
            self.path, str(self.disk), str(self.root), 4096, self.digest,
            completed=kwargs.get("completed", True),
        )


class BindingTests(BindingFixture, unittest.TestCase):
    def test_gpt_selection_and_restored_bytes_form_one_permit(self):
        permit = self.inspect()
        self.assertEqual(permit.gpt_binding, (str(self.disk), str(self.root)))
        self.assertEqual((permit.offset, permit.length), (256 * 512, 1792 * 512))
        self.assertEqual(permit.restored_sha256, self.digest)

    def test_completion_and_readback_are_required_for_gpt_admission(self):
        with self.assertRaisesRegex(Refused, "completed-install"):
            self.inspect(completed=False)
        self.digest = "0" * 64
        with self.assertRaisesRegex(Refused, "readback"):
            self.inspect()


@unittest.skipUnless(os.environ.get("OMARCHY_TEST_QEMU_NBD"), "set OMARCHY_TEST_QEMU_NBD for real QEMU socket tests")
class BoundQemuTests(BindingFixture, unittest.TestCase):
    def server(self, permit):
        return RegionServer(os.environ["OMARCHY_TEST_QEMU_NBD"], permit)

    def test_valid_gpt_exposes_only_the_selected_partition(self):
        permit = self.inspect()
        original = self.path.read_bytes()
        with self.server(permit) as server:
            client = Client(server.socket)
            self.addCleanup(client.close)
            self.assertEqual(client.size, permit.length)
            self.assertEqual(client.request(1, 0, 512, b"A" * 512, flags=1), (0, b""))
            self.assertNotEqual(client.request(1, permit.length, 512, b"X" * 512)[0], 0)
        updated = self.path.read_bytes()
        self.assertEqual(updated[:permit.offset], original[:permit.offset])
        self.assertEqual(updated[permit.offset:permit.offset + 512], b"A" * 512)
        self.assertEqual(updated[permit.offset + permit.length:], original[permit.offset + permit.length:])

    def test_valid_but_moved_root_is_refused_even_when_prefix_bytes_match(self):
        permit = self.inspect()
        self.fixture(root_start=512)
        changed = self.path.read_bytes()
        with self.assertRaisesRegex(Refused, "extent changed"):
            with self.server(permit):
                self.fail("a changed GPT was used for staging")
        self.assertEqual(self.path.read_bytes(), changed)

    def test_changed_disk_uuid_is_refused_even_when_extent_and_bytes_match(self):
        permit = self.inspect()
        self.disk = uuid.uuid4()
        self.fixture()
        with self.assertRaisesRegex(Refused, "disk UUID"):
            with self.server(permit):
                self.fail("another disk identity was used for staging")

    def test_gpt_is_rechecked_after_qemu_startup_before_socket_is_returned(self):
        permit = self.inspect()
        launch = subprocess.Popen
        launched = []

        def change_during_startup(*args, **kwargs):
            if "--list" in args[0]:
                return launch(*args, **kwargs)
            # Change after the broker's first check, before QEMU opens it.
            self.fixture(root_start=512)
            process = launch(*args, **kwargs)
            launched.append(process)
            return process

        server = self.server(permit)
        with patch("Development.migration_staging.broker.subprocess.Popen", side_effect=change_during_startup):
            with self.assertRaisesRegex(Refused, "extent changed"):
                server.start()
        self.assertEqual(len(launched), 1)
        self.assertIsNotNone(launched[0].poll())
        self.assertIsNone(server.fd)
        self.assertIsNone(server.directory)

    def test_new_inspection_cannot_race_an_active_writer(self):
        permit = self.inspect()
        with self.server(permit):
            with self.assertRaises(BlockingIOError):
                self.inspect()


if __name__ == "__main__":
    unittest.main()
