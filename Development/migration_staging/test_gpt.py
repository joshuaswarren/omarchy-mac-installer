from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
import uuid
import zlib

from Development.migration_staging.broker import Refused
from Development.migration_staging.gpt import HEADER, LINUX_FILESYSTEM, read_root_extent


class GptFixture:
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="migration-gpt-test-")
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "synthetic.raw"
        self.disk, self.root = uuid.uuid4(), uuid.uuid4()
        self.sectors = 4096

    def fixture(self, *, overlap=False, duplicate=False, backup_differs=False, root_start=256):
        entries = bytearray(128 * 128)
        first = uuid.uuid4()
        for index, identity, start, end in ((0, first, 64, 127),
                                            (1, first if duplicate else self.root, 100 if overlap else root_start, 2047)):
            record = LINUX_FILESYSTEM.bytes_le + identity.bytes_le + struct.pack("<QQQ", start, end, 0)
            entries[index * 128:index * 128 + len(record)] = record
        image = bytearray(self.sectors * 512)
        image[512 * 2:512 * 34] = entries
        image[512 * (self.sectors - 33):512 * (self.sectors - 1)] = entries
        for current, other, table in ((1, self.sectors - 1, 2), (self.sectors - 1, 1, self.sectors - 33)):
            disk = uuid.uuid4() if backup_differs and current != 1 else self.disk
            header = bytearray(HEADER.pack(b"EFI PART", 0x10000, HEADER.size, 0, 0,
                                          current, other, 34, self.sectors - 34, disk.bytes_le,
                                          table, 128, 128, zlib.crc32(entries)))
            struct.pack_into("<I", header, 16, zlib.crc32(header))
            image[current * 512:current * 512 + len(header)] = header
        self.path.write_bytes(image)
        self.path.chmod(0o600)


class GptTests(GptFixture, unittest.TestCase):
    def read(self):
        return read_root_extent(self.path, str(self.disk), str(self.root))

    def test_root_is_selected_by_uuid_and_both_tables_are_checked(self):
        self.fixture()
        extent = self.read()
        self.assertEqual((extent.offset, extent.length), (256 * 512, (2047 - 256 + 1) * 512))
        self.assertEqual(extent.partition_uuid, str(self.root))

    def test_wrong_disk_or_partition_identity_is_refused(self):
        self.fixture()
        for disk, root in ((uuid.uuid4(), self.root), (self.disk, uuid.uuid4())):
            with self.assertRaises(Refused):
                read_root_extent(self.path, str(disk), str(root))

    def test_checksum_damage_in_either_header_or_table_is_refused(self):
        for offset in (512 + 16, 1024 + 48, (self.sectors - 1) * 512 + 16, (self.sectors - 33) * 512 + 48):
            self.fixture()
            with self.path.open("r+b") as stream:
                stream.seek(offset)
                value = stream.read(1)
                stream.seek(offset)
                stream.write(bytes([value[0] ^ 1]))
            with self.subTest(offset=offset), self.assertRaises(Refused):
                self.read()

    def test_individually_valid_but_different_gpt_copies_are_refused(self):
        self.fixture(backup_differs=True)
        with self.assertRaisesRegex(Refused, "disagree"):
            self.read()

    def test_overlapping_or_duplicate_partitions_are_refused(self):
        for option in ("overlap", "duplicate"):
            self.fixture(**{option: True})
            with self.subTest(option=option), self.assertRaises(Refused):
                self.read()

    def test_truncated_image_fails_before_returning_an_extent(self):
        self.path.write_bytes(b"not a disk")
        self.path.chmod(0o600)
        with self.assertRaises(Refused):
            self.read()

    @unittest.skipUnless(shutil.which("sgdisk"), "sgdisk is optional for the independent GPT writer check")
    def test_reads_a_gpt_written_by_the_harness_partitioning_tool(self):
        self.path.write_bytes(b"\0" * (self.sectors * 512))
        self.path.chmod(0o600)
        subprocess.run([
            "sgdisk", "--clear", "--set-alignment=1", f"--disk-guid={self.disk}",
            "--new=1:64:127", "--new=2:256:2047", f"--partition-guid=2:{self.root}",
            str(self.path),
        ], check=True, capture_output=True)
        extent = self.read()
        self.assertEqual((extent.offset, extent.length), (256 * 512, (2047 - 256 + 1) * 512))


if __name__ == "__main__":
    unittest.main()
