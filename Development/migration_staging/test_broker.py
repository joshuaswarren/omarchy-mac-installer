"""Synthetic-file tests; optional QEMU coverage uses Unix sockets, never /dev/nbd."""

from dataclasses import replace
import hashlib
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from Development.migration_staging.broker import FixturePermit, Refused, RegionServer, check_extent


class Client:
    """Small protocol test client so invalid requests reach the real server."""

    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(2)
        self.socket.connect(str(path))
        greeting = self.read(18)
        if greeting[:16] != b"NBDMAGICIHAVEOPT":
            raise AssertionError("not a newstyle NBD server")
        self.socket.sendall(struct.pack(">I", 3))  # Fixed newstyle, no zero padding.
        name = b"migration-root"
        self.socket.sendall(struct.pack(">QII", 0x49484156454F5054, 1, len(name)) + name)
        self.size, self.flags = struct.unpack(">QH", self.read(10))
        self.cookie = 0

    def read(self, length):
        result = bytearray()
        while len(result) < length:
            part = self.socket.recv(length - len(result))
            if not part:
                raise EOFError("server closed the connection")
            result.extend(part)
        return bytes(result)

    def request(self, command, offset=0, length=0, payload=b"", flags=0):
        self.cookie += 1
        self.socket.sendall(struct.pack(">IHHQQI", 0x25609513, flags, command,
                                        self.cookie, offset, length) + payload)
        magic, error, cookie = struct.unpack(">IIQ", self.read(16))
        if magic != 0x67446698 or cookie != self.cookie:
            raise AssertionError("reply identity differs from request")
        data = self.read(length) if command == 0 and error == 0 else b""
        return error, data

    def close(self):
        self.socket.close()


class FixtureSetup:
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="migration-range-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.image = self.root / "target.raw"
        self.prefix, self.payload, self.suffix = b"P" * 4096, b"R" * 16384, b"S" * 4096
        self.image.write_bytes(self.prefix + self.payload + self.suffix)
        self.image.chmod(0o600)
        self.original = self.image.read_bytes()
        self.permit = FixturePermit.inspect(
            self.image, 4096, 16384, 16384, hashlib.sha256(self.payload).hexdigest(), completed=True
        )


class FixtureTests(FixtureSetup, unittest.TestCase):
    def test_completed_gate_and_exact_restored_prefix_are_required(self):
        for completed, digest in ((False, self.permit.restored_sha256), (True, "0" * 64)):
            with self.assertRaises(Refused):
                FixturePermit.inspect(self.image, 4096, 16384, 16384, digest, completed=completed)
        self.assertEqual(self.image.read_bytes(), self.original)

    def test_extent_overflow_alignment_types_and_end_are_checked(self):
        for offset, length, size in ((-512, 512, 1024), (0, 0, 1024), (1, 512, 1024),
                                    (512, 1024, 1024), (2**63, 512, 2**64),
                                    (0, True, 1024), (0, 512.0, 1024)):
            with self.subTest(values=(offset, length, size)), self.assertRaises(Refused):
                check_extent(offset, length, size)
        check_extent(512, 512, 1024)

    def test_symlink_hardlink_and_nonprivate_file_are_refused(self):
        alias = self.root / "alias"
        alias.symlink_to(self.image)
        with self.assertRaises(OSError):
            FixturePermit.inspect(alias, 4096, 16384, 16384, self.permit.restored_sha256, completed=True)
        alias.unlink()
        os.link(self.image, alias)
        with self.assertRaises(Refused):
            FixturePermit.inspect(self.image, 4096, 16384, 16384, self.permit.restored_sha256, completed=True)
        alias.unlink()
        self.image.chmod(0o644)
        with self.assertRaises(Refused):
            FixturePermit.inspect(self.image, 4096, 16384, 16384, self.permit.restored_sha256, completed=True)

    def test_fifo_is_refused_without_blocking(self):
        fifo = self.root / "fifo"
        os.mkfifo(fifo, 0o600)
        with self.assertRaises(Refused):
            FixturePermit.inspect(fifo, 0, 512, 512, "0" * 64, completed=True)


@unittest.skipUnless(os.environ.get("OMARCHY_TEST_QEMU_NBD"), "set OMARCHY_TEST_QEMU_NBD for real QEMU socket tests")
class QemuTests(FixtureSetup, unittest.TestCase):
    def server(self, permit=None):
        return RegionServer(os.environ["OMARCHY_TEST_QEMU_NBD"], permit or self.permit)

    def client(self, server):
        client = Client(server.socket)
        self.addCleanup(client.close)
        return client

    def test_only_selected_region_is_exposed_and_flush_persists(self):
        with self.server() as server:
            client = self.client(server)
            self.assertEqual(client.size, len(self.payload))
            self.assertEqual(client.request(0, 0, 512), (0, b"R" * 512))
            self.assertEqual(client.request(1, 0, 512, b"A" * 512), (0, b""))
            self.assertEqual(client.request(1, len(self.payload) - 512, 512, b"Z" * 512, flags=1), (0, b""))
            self.assertEqual(client.request(3), (0, b""))
            self.assertEqual(self.image.read_bytes()[:4096], self.prefix)
            self.assertEqual(self.image.read_bytes()[-4096:], self.suffix)
        data = self.image.read_bytes()
        self.assertEqual(data[4096:4608], b"A" * 512)
        self.assertEqual(data[-4608:-4096], b"Z" * 512)

    def test_outside_and_integer_wrap_requests_cannot_modify_sentinels(self):
        with self.server() as server:
            client = self.client(server)
            for offset in (len(self.payload), len(self.payload) - 256, 2**64 - 512):
                with self.subTest(offset=offset):
                    error, _ = client.request(1, offset, 512, b"X" * 512)
                    self.assertNotEqual(error, 0)
            self.assertNotEqual(client.request(0, len(self.payload), 512)[0], 0)
        self.assertEqual(self.image.read_bytes(), self.original)

    def test_changed_path_identity_or_restored_bytes_refuse_start(self):
        self.image.rename(self.root / "original.raw")
        self.image.write_bytes(self.original)
        self.image.chmod(0o600)
        with self.assertRaisesRegex(Refused, "identity"):
            with self.server():
                self.fail("changed identity started")
        self.image.unlink()
        (self.root / "original.raw").rename(self.image)
        with self.image.open("r+b") as stream:
            stream.seek(4096)
            stream.write(b"changed")
        with self.assertRaisesRegex(Refused, "changed before"):
            with self.server():
                self.fail("changed source started")

    def test_same_fixture_has_only_one_writer(self):
        with self.server():
            with self.assertRaises(BlockingIOError):
                with self.server():
                    self.fail("second writer started")

    def test_path_replacement_cannot_redirect_an_open_server(self):
        with self.server() as server:
            old = self.root / "original.raw"
            self.image.rename(old)
            self.image.write_bytes(b"NEW" * (len(self.original) // 3))
            self.image.chmod(0o600)
            replacement = self.image.read_bytes()
            client = self.client(server)
            self.assertEqual(client.request(1, 0, 512, b"A" * 512), (0, b""))
            self.assertEqual(client.request(3), (0, b""))
        self.assertEqual(self.image.read_bytes(), replacement)
        self.assertEqual(old.read_bytes()[4096:4608], b"A" * 512)
        self.assertEqual(old.read_bytes()[:4096], self.prefix)
        self.assertEqual(old.read_bytes()[-4096:], self.suffix)

    def test_cancelled_server_releases_its_own_process_socket_and_lock(self):
        with self.server() as server:
            process, socket_path = server.process, server.socket
        self.assertIsNotNone(process.poll())
        self.assertFalse(socket_path.exists())
        with self.server() as server:
            self.assertEqual(self.client(server).size, len(self.payload))

    def test_forged_incomplete_permit_is_refused(self):
        with self.assertRaises(Refused):
            with self.server(replace(self.permit, completed=False)):
                self.fail("incomplete state started")

    def test_direct_start_failure_closes_resources(self):
        server = self.server(replace(self.permit, restored_sha256="0" * 64))
        with self.assertRaises(Refused):
            server.start()
        self.assertIsNone(server.fd)
        self.assertIsNone(server.process)
        with self.server():
            pass

    def test_listening_socket_without_a_ready_export_is_not_published(self):
        fake_qemu = self.root / "not-ready-qemu"
        fake_qemu.write_text(
            f"#!{sys.executable}\n"
            "import socket, sys\n"
            "path = sys.argv[sys.argv.index('--socket') + 1]\n"
            "sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n"
            "if '--list' in sys.argv:\n"
            "    sock.connect(path)\n"
            "    sock.close()\n"
            "    sys.exit(1)\n"
            "sock.bind(path)\n"
            "sock.listen(1)\n"
            "sock.accept()[0].close()\n"
            "sock.close()\n"
        )
        fake_qemu.chmod(0o700)
        server = RegionServer(fake_qemu, self.permit)
        with self.assertRaises(Refused):
            server.start()
        self.assertIsNone(server.fd)
        self.assertIsNone(server.process)
        self.assertIsNone(server.directory)
        self.assertEqual(self.image.read_bytes(), self.original)

    def test_early_readiness_refusal_is_retried_while_server_starts(self):
        run = subprocess.run
        attempts = []

        def delayed_probe(arguments, **kwargs):
            attempts.append(arguments)
            if len(attempts) == 1:
                return subprocess.CompletedProcess(arguments, 1)
            return run(arguments, **kwargs)

        with patch("Development.migration_staging.broker.subprocess.run", side_effect=delayed_probe):
            with self.server() as server:
                self.assertEqual(self.client(server).size, len(self.payload))
        self.assertGreaterEqual(len(attempts), 2)

    def test_mutated_target_needs_reconciliation_not_a_new_base_digest(self):
        with self.server() as server:
            client = self.client(server)
            self.assertEqual(client.request(1, 0, 512, b"A" * 512), (0, b""))
            self.assertEqual(client.request(3), (0, b""))
        with self.assertRaisesRegex(Refused, "changed before"):
            with self.server():
                self.fail("modified target was treated as a fresh restore")

    def test_other_advertised_writes_also_respect_the_export_end(self):
        with self.server() as server:
            client = self.client(server)
            for command, capability in ((4, 1 << 5), (6, 1 << 6)):
                if client.flags & capability:
                    self.assertNotEqual(client.request(command, len(self.payload), 512)[0], 0)
            self.assertNotEqual(client.request(1, 0, 512, b"A" * 512, flags=0x8000)[0], 0)
        self.assertEqual(self.image.read_bytes(), self.original)


if __name__ == "__main__":
    unittest.main()
