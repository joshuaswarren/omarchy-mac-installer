"""Read and cross-check both GPT copies on a private, 512-byte-sector fixture.

This deliberately does not inspect real disks or discover a target by its name.
The expected disk and Root partition UUIDs must come from the test controller.
"""

from dataclasses import dataclass
import os
import struct
import uuid
import zlib

from .broker import SECTOR, Refused, _open_fixture


HEADER = struct.Struct("<8sIIIIQQQQ16sQIII")
LINUX_FILESYSTEM = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4")


@dataclass(frozen=True)
class RootExtent:
    disk_uuid: str
    partition_uuid: str
    offset: int
    length: int


def _read(fd, offset, length):
    data = os.pread(fd, length, offset)
    if len(data) != length:
        raise Refused("truncated GPT")
    return data


def _header(fd, lba, sectors):
    sector = _read(fd, lba * SECTOR, SECTOR)
    values = HEADER.unpack_from(sector)
    signature, revision, size, checksum, reserved, current, backup, first, last, disk, table, count, width, crc = values
    if signature != b"EFI PART" or revision != 0x10000 or not HEADER.size <= size <= SECTOR or reserved:
        raise Refused("unsupported GPT header")
    check = bytearray(sector[:size])
    check[16:20] = b"\0" * 4
    if zlib.crc32(check) != checksum:
        raise Refused("GPT header checksum failed")
    if current != lba or backup != (sectors - 1 if lba == 1 else 1):
        raise Refused("GPT header location differs from fixture")
    if not 2 <= first <= last < sectors - 1 or disk == b"\0" * 16:
        raise Refused("invalid GPT usable range or identity")
    if not 1 <= count <= 4096 or not 128 <= width <= 1024 or width % 128 or count * width > 1024 * 1024:
        raise Refused("GPT entry table exceeds supported bounds")
    table_sectors = (count * width + SECTOR - 1) // SECTOR
    if lba == 1:
        valid_table = 2 <= table and table + table_sectors <= first
    else:
        valid_table = last < table and table + table_sectors <= lba
    if not valid_table:
        raise Refused("GPT entry table overlaps usable data")
    entries = _read(fd, table * SECTOR, count * width)
    if zlib.crc32(entries) != crc:
        raise Refused("GPT entry checksum failed")
    return (first, last, disk, count, width), entries


def read_root_extent_fd(fd, expected_disk_uuid, expected_partition_uuid):
    """Parse an already opened fixture; the caller owns its admission and lock."""
    try:
        expected_disk = uuid.UUID(expected_disk_uuid)
        expected_root = uuid.UUID(expected_partition_uuid)
    except (ValueError, AttributeError) as error:
        raise Refused("invalid expected target UUID") from error
    size = os.fstat(fd).st_size
    if size % SECTOR or size < 4 * SECTOR:
        raise Refused("fixture is not a sector-aligned GPT image")
    sectors = size // SECTOR
    primary, entries = _header(fd, 1, sectors)
    backup, backup_entries = _header(fd, sectors - 1, sectors)
    if primary != backup or entries != backup_entries:
        raise Refused("primary and backup GPT disagree")
    first, last, disk, count, width = primary
    if uuid.UUID(bytes_le=disk) != expected_disk:
        raise Refused("disk UUID differs from the approved fixture")
    root = None
    identities, extents = set(), []
    for index in range(count):
        entry = entries[index * width:(index + 1) * width]
        kind = uuid.UUID(bytes_le=entry[:16])
        if kind.int == 0:
            if any(entry):
                raise Refused("nonempty unused GPT entry")
            continue
        identity = uuid.UUID(bytes_le=entry[16:32])
        start, end, attributes = struct.unpack_from("<QQQ", entry, 32)
        if not identity.int or identity in identities or not first <= start <= end <= last:
            raise Refused("invalid partition identity or extent")
        identities.add(identity)
        extents.append((start, end))
        if identity == expected_root:
            if kind != LINUX_FILESYSTEM or attributes != 0:
                raise Refused("selected Root is not the expected Linux fixture partition")
            root = RootExtent(str(expected_disk), str(identity), start * SECTOR, (end - start + 1) * SECTOR)
    previous_end = -1
    for start, end in sorted(extents):
        if start <= previous_end:
            raise Refused("GPT partitions overlap")
        previous_end = end
    if root is None:
        raise Refused("approved Root UUID is absent")
    return root


def read_root_extent(path, expected_disk_uuid, expected_partition_uuid):
    fd = _open_fixture(path, os.O_RDONLY)
    try:
        return read_root_extent_fd(fd, expected_disk_uuid, expected_partition_uuid)
    finally:
        os.close(fd)
