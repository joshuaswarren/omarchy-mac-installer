"""Crash/retry experiment for ciphertext publication in private fixture directories.

No filesystem mounting, growth, encryption, source-home scanning or privilege is
performed here. The caller supplies already verified ciphertext and target IDs.
"""

from contextlib import contextmanager
from dataclasses import asdict, dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import uuid

from .broker import CHUNK, MAX_OFFSET, Refused


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode() + b"\n"


@dataclass(frozen=True)
class StageRequest:
    export_id: str
    target_uuid: str
    candidate_sha256: str
    install_plan_sha256: str
    worker_sha256: str
    ciphertext_sha256: str
    ciphertext_bytes: int

    def document(self):
        for identity in (self.export_id, self.target_uuid):
            if not isinstance(identity, str) or str(uuid.UUID(identity)) != identity:
                raise Refused("invalid opaque identity")
        for digest in (self.candidate_sha256, self.install_plan_sha256, self.worker_sha256, self.ciphertext_sha256):
            if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
                raise Refused("invalid binding digest")
        if type(self.ciphertext_bytes) is not int or not 0 < self.ciphertext_bytes <= MAX_OFFSET:
            raise Refused("invalid ciphertext size")
        return {"schema": "omarchy-staging-fixture/1", **asdict(self)}


@contextmanager
def _private_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(fd)
        if metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
            raise Refused("staging fixture directory must be owned and private")
        yield fd
    finally:
        os.close(fd)


@contextmanager
def _file(directory, name, flags):
    fd = os.open(name, flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=directory)
    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise Refused("staging entry is not a single owned file")
        if metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
            raise Refused("staging entry is not private")
        yield fd
    finally:
        os.close(fd)


def _exists(directory, name):
    try:
        os.stat(name, dir_fd=directory, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def _write_all(fd, data):
    view = memoryview(data)
    while view:
        count = os.write(fd, view)
        if not count:
            raise OSError("short write")
        view = view[count:]


def _publish_document(directory, name, document):
    data = canonical(document)
    if _exists(directory, name):
        with _file(directory, name, os.O_RDONLY) as fd:
            if os.fstat(fd).st_size != len(data) or os.read(fd, len(data) + 1) != data:
                raise Refused("staging request differs from existing binding")
            os.fsync(fd)
        os.fsync(directory)
        return
    temporary = f".{name}.{uuid.uuid4()}.partial"
    try:
        with _file(directory, temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL) as fd:
            _write_all(fd, data)
            os.fsync(fd)
        # The locked, private directory admits no other publisher. Rename has
        # no intermediate hardlink state to complicate crash recovery.
        os.rename(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
        os.fsync(directory)
    finally:
        if _exists(directory, temporary):
            os.unlink(temporary, dir_fd=directory)


def _digest(fd, length):
    result = hashlib.sha256()
    offset = 0
    while offset < length:
        piece = os.pread(fd, min(CHUNK, length - offset), offset)
        if not piece:
            raise Refused("ciphertext ended early")
        result.update(piece)
        offset += len(piece)
    return result.hexdigest()


def _verify(fd, request):
    if os.fstat(fd).st_size != request.ciphertext_bytes:
        raise Refused("ciphertext size changed")
    if _digest(fd, request.ciphertext_bytes) != request.ciphertext_sha256:
        raise Refused("ciphertext digest differs from approved export")


def publish(source, destination, request, *, checkpoint=lambda phase: None):
    """Bind intent, resume a verified prefix, read back, then publish readiness.

    Destination is an existing private directory on a disposable test target.
    Repeating the identical request reuses it; changing any binding is refused.
    Checkpoint injection exercises process exceptions, not power-loss durability.
    """
    document = request.document()
    copied = 0
    with _private_directory(destination) as directory:
        with _file(directory, "lock", os.O_CREAT | os.O_RDWR) as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            _publish_document(directory, "intent.json", document)
            checkpoint("intent")
            committed = _exists(directory, "bundle.age")
            name = "bundle.age" if committed else "bundle.partial"
            flags = os.O_RDONLY if committed else os.O_CREAT | os.O_RDWR
            with _file(directory, name, flags) as target:
                if committed:
                    _verify(target, request)
                else:
                    # The source is immutable ciphertext from the exporter. Its
                    # bytes are checked again; it is never opened writable.
                    source_fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                    try:
                        if not stat.S_ISREG(os.fstat(source_fd).st_mode):
                            raise Refused("source must be a regular ciphertext file")
                        _verify(source_fd, request)
                        offset = os.fstat(target).st_size
                        if offset > request.ciphertext_bytes or _digest(target, offset) != _digest(source_fd, offset):
                            raise Refused("partial ciphertext does not match this export")
                        os.lseek(target, offset, os.SEEK_SET)
                        while offset < request.ciphertext_bytes:
                            data = os.pread(source_fd, min(CHUNK, request.ciphertext_bytes - offset), offset)
                            if not data:
                                raise Refused("source changed during staging")
                            _write_all(target, data)
                            offset += len(data)
                            copied += len(data)
                            os.fsync(target)
                            checkpoint("copy")
                        _verify(target, request)
                        # A full partial can have survived a write-before-fsync
                        # interruption. Readback alone does not make it durable.
                        os.fsync(target)
                    finally:
                        os.close(source_fd)
                    os.rename("bundle.partial", "bundle.age", src_dir_fd=directory, dst_dir_fd=directory)
                    os.fsync(directory)
            checkpoint("ciphertext")
            # Re-open and read back the committed inode, not only the producer's
            # digest or a temporary descriptor, before declaring it ready.
            with _file(directory, "bundle.age", os.O_RDONLY) as target:
                _verify(target, request)
                os.fsync(target)
            _publish_document(directory, "ready.json", document)
            checkpoint("ready")
            return {"ready": True, "copied_bytes": copied, "request_sha256": hashlib.sha256(canonical(document)).hexdigest()}


def verify_ready(destination, request):
    """A ready filename alone is never evidence that a bundle can be consumed."""
    expected = canonical(request.document())
    with _private_directory(destination) as directory:
        with _file(directory, "lock", os.O_CREAT | os.O_RDWR) as lock:
            fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
            for name in ("intent.json", "ready.json"):
                with _file(directory, name, os.O_RDONLY) as fd:
                    if os.fstat(fd).st_size != len(expected) or os.read(fd, len(expected) + 1) != expected:
                        raise Refused("readiness binding differs from requested transfer")
            with _file(directory, "bundle.age", os.O_RDONLY) as fd:
                _verify(fd, request)
    return True
