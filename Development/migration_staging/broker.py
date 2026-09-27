"""Export a bounded region of an owned regular fixture through QEMU NBD.

The permit models an already-completed installation for disposable tests only.
It is not helper authorization, and this module rejects real block devices.
This is an INITIAL-OPEN experiment: a changed restored prefix requires later
stage-journal reconciliation, not replacement of the immutable base digest.
"""

from dataclasses import dataclass
import fcntl
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import threading
import time


SECTOR = 512
MAX_OFFSET = (1 << 63) - 1
CHUNK = 1024 * 1024


class Refused(ValueError):
    """The requested fixture or state is not safe for this experiment."""


def check_extent(offset, length, size):
    if any(type(value) is not int for value in (offset, length, size)):
        raise Refused("extent values must be integers")
    if not (0 <= offset <= MAX_OFFSET and 0 < length <= MAX_OFFSET and 0 < size <= MAX_OFFSET):
        raise Refused("extent is outside the supported integer range")
    if offset % SECTOR or length % SECTOR or length > size or offset > size - length:
        raise Refused("extent is unaligned or outside the fixture")


def _open_fixture(path, flags):
    """Pin the parent and leaf; do not follow a selected symlink or device."""
    path = Path(path)
    parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(parent)
        if metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
            raise Refused("fixture parent must be private and owned by this user")
        fd = os.open(path.name, flags | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    finally:
        os.close(parent)
    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise Refused("only owned regular fixture files are accepted")
        if metadata.st_nlink != 1 or metadata.st_mode & 0o077:
            raise Refused("fixture must be private and have exactly one link")
        return fd
    except BaseException:
        os.close(fd)
        raise


def _identity(fd):
    metadata = os.fstat(fd)
    return metadata.st_dev, metadata.st_ino, metadata.st_size


def _hash_region(fd, offset, length):
    result = hashlib.sha256()
    while length:
        data = os.pread(fd, min(CHUNK, length), offset)
        if not data:
            raise Refused("fixture changed size during readback")
        result.update(data)
        offset += len(data)
        length -= len(data)
    return result.hexdigest()


@dataclass(frozen=True)
class FixturePermit:
    path: Path
    identity: tuple[int, int, int]
    offset: int
    length: int
    restored_bytes: int
    restored_sha256: str
    completed: bool
    gpt_binding: tuple[str, str] | None = None

    @classmethod
    def inspect(cls, path, offset, length, restored_bytes, restored_sha256, *, completed):
        if completed is not True:
            raise Refused("staging requires the completed-install fixture gate")
        fd = _open_fixture(path, os.O_RDONLY)
        try:
            identity = _identity(fd)
            check_extent(offset, length, identity[2])
            if type(restored_bytes) is not int or not 0 < restored_bytes <= length:
                raise Refused("invalid restored image length")
            if _hash_region(fd, offset, restored_bytes) != restored_sha256:
                raise Refused("restored image readback failed")
            return cls(Path(path), identity, offset, length, restored_bytes, restored_sha256, True)
        finally:
            os.close(fd)

    @classmethod
    def inspect_gpt(cls, path, disk_uuid, partition_uuid, restored_bytes, restored_sha256, *, completed):
        """Bind GPT selection and prefix readback on one opened fixture."""
        from .gpt import read_root_extent_fd

        if completed is not True:
            raise Refused("staging requires the completed-install fixture gate")
        fd = _open_fixture(path, os.O_RDONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
            root = read_root_extent_fd(fd, disk_uuid, partition_uuid)
            identity = _identity(fd)
            check_extent(root.offset, root.length, identity[2])
            if type(restored_bytes) is not int or not 0 < restored_bytes <= root.length:
                raise Refused("invalid restored image length")
            if _hash_region(fd, root.offset, restored_bytes) != restored_sha256:
                raise Refused("restored image readback failed")
            return cls(
                Path(path), identity, root.offset, root.length, restored_bytes,
                restored_sha256, True, (root.disk_uuid, root.partition_uuid),
            )
        finally:
            os.close(fd)

    def check_gpt(self, fd):
        if self.gpt_binding is None:
            return
        from .gpt import read_root_extent_fd

        root = read_root_extent_fd(fd, *self.gpt_binding)
        if (root.offset, root.length) != (self.offset, self.length):
            raise Refused("approved Root extent changed before staging")


class RegionServer:
    """One QEMU process, one private Unix socket and one pinned fixture inode."""

    def __init__(self, qemu_nbd, permit):
        self.qemu_nbd = Path(qemu_nbd).resolve(strict=True)
        self.permit = permit
        self.fd = None
        self.process = None
        self.directory = None
        self.socket = None
        self.errors = bytearray()
        self.error_reader = None

    def __enter__(self):
        try:
            self.start()
            return self
        except BaseException:
            self.close()
            raise

    def __exit__(self, *_):
        self.close()

    def start(self):
        if self.fd is not None or self.process is not None:
            raise Refused("server already started")
        try:
            self._start()
        except BaseException:
            self.close()
            raise

    def _start(self):
        permit = self.permit
        if permit.completed is not True:
            raise Refused("completed-install fixture gate missing")
        self.fd = _open_fixture(permit.path, os.O_RDWR)
        fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if _identity(self.fd) != permit.identity:
            raise Refused("fixture identity changed")
        permit.check_gpt(self.fd)
        check_extent(permit.offset, permit.length, permit.identity[2])
        if type(permit.restored_bytes) is not int or not 0 < permit.restored_bytes <= permit.length:
            raise Refused("invalid restored image length")
        if _hash_region(self.fd, permit.offset, permit.restored_bytes) != permit.restored_sha256:
            raise Refused("restored image changed before staging")
        self.directory = tempfile.TemporaryDirectory(prefix="omarchy-stage-")
        self.socket = Path(self.directory.name) / "root.sock"
        # Linux experiment only: the child reopens the pinned inode, never a
        # client-selected path. QEMU's raw node enforces BOTH offset and length.
        options = (
            f"driver=raw,offset={permit.offset},size={permit.length},"
            f"file.driver=file,file.filename=/proc/self/fd/{self.fd},file.locking=on"
        )
        self.process = subprocess.Popen(
            [str(self.qemu_nbd), "--socket", str(self.socket),
             "--export-name", "migration-root", "--shared=1", "--persistent", "--handshake-limit=10",
             "--cache=writethrough", "--discard=ignore", "--detect-zeroes=off",
             "--image-opts", options],
            pass_fds=(self.fd,), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE, umask=0o077,
        )
        self.errors.clear()
        error_stream = self.process.stderr
        def drain_errors():
            while data := error_stream.read(1024):
                # Drain continuously but retain at most a small startup error.
                self.errors.extend(data[:max(0, 4096 - len(self.errors))])
        self.error_reader = threading.Thread(target=drain_errors, daemon=True)
        self.error_reader.start()
        deadline = time.monotonic() + 5
        while True:
            if self.process.poll() is not None:
                self.error_reader.join(timeout=1)
                detail = self.errors.decode(errors="replace")
                raise Refused(f"QEMU failed to start: {detail}")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Refused("QEMU export readiness timed out")
            # Socket creation precedes listen/image opening in QEMU. Complete
            # protocol negotiation; retry an early refusal within the deadline.
            # Persistence keeps this probe's disconnect from stopping QEMU.
            if self.socket.exists():
                try:
                    ready = subprocess.run(
                        [str(self.qemu_nbd), "--list", "--socket", str(self.socket)],
                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL, timeout=remaining,
                    )
                except subprocess.TimeoutExpired as error:
                    raise Refused("QEMU export readiness timed out") from error
                if ready.returncode == 0 and self.process.poll() is None:
                    break
            time.sleep(0.01)
        # QEMU has opened the export and holds its image lock. Recheck the
        # pinned inode before any staging client receives the socket path.
        if _identity(self.fd) != permit.identity or _hash_region(
            self.fd, permit.offset, permit.restored_bytes
        ) != permit.restored_sha256:
            raise Refused("fixture changed during server startup")
        permit.check_gpt(self.fd)

    def close(self):
        if self.process is not None:
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=5)
            if self.error_reader:
                self.error_reader.join(timeout=1)
                self.error_reader = None
            self.process.stderr.close()
            self.process = None
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
        if self.directory is not None:
            self.directory.cleanup()
            self.directory = None
